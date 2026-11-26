import SwiftUI
import UIKit
import UniformTypeIdentifiers

/// System Share Extension host controller.
///
/// Works reliably across BOTH App Store / provisioned builds (shared App Group queue) AND
/// unsigned / sideloaded builds where App Groups are stripped (direct `charkle-mobile://import`
/// deep-link handoff for URLs/text and local-only pasteboard envelopes for images/files).
@objc(ShareViewController)
final class ShareViewController: UIViewController {
    private var hostingController: UIHostingController<ShareSheetRootView>?

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .clear

        let model = ShareExtensionViewModel(
            extensionContext: extensionContext,
            openURLHandler: { [weak self] url in
                guard let self else { return false }
                return await self.openHostApp(url)
            }
        )
        let rootView = ShareSheetRootView(
            model: model,
            onDismiss: { [weak self] in
                self?.extensionContext?.completeRequest(returningItems: nil)
            },
            onCancel: { [weak self] in
                self?.extensionContext?.cancelRequest(
                    withError: NSError(domain: "com.charkle.mobile.share", code: 0)
                )
            }
        )

        let host = UIHostingController(rootView: rootView)
        host.view.backgroundColor = .clear
        addChild(host)
        view.addSubview(host.view)
        host.view.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            host.view.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            host.view.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            host.view.topAnchor.constraint(equalTo: view.topAnchor),
            host.view.bottomAnchor.constraint(equalTo: view.bottomAnchor)
        ])
        host.didMove(toParent: self)
        hostingController = host

        Task { await model.extractSharedItems() }
    }

    @MainActor
    private func openHostApp(_ url: URL) async -> Bool {
        var responder: UIResponder? = self
        while let current = responder {
            if let application = current as? UIApplication {
                return await application.open(url, options: [:])
            }
            responder = current.next
        }
        return await withCheckedContinuation { continuation in
            if let context = extensionContext {
                context.open(url) { ok in
                    continuation.resume(returning: ok)
                }
            } else {
                continuation.resume(returning: false)
            }
        }
    }
}

private enum LoadedProviderValue: Sendable {
    case url(URL)
    case data(Data)
    case imageJPEG(Data, width: Int, height: Int)
    case text(String)
}

private struct ExtractedShareItem: Identifiable {
    enum Source {
        case stagedFile(URL)
        case imageData(Data, ext: String)
        case webURL(URL, embeddedNotes: String?)
        case text(String)
    }

    let id = UUID()
    let displayTitle: String
    let subtitle: String
    let explicitTitle: String?
    let previewImage: UIImage?
    let source: Source
}

@Observable
@MainActor
private final class ShareExtensionViewModel {
    private weak var extensionContext: NSExtensionContext?
    private let openURLHandler: @MainActor (URL) async -> Bool
    private let tempStagingDir: URL

    var items: [ExtractedShareItem] = []
    var folders: [SharedFolderSummary] = []
    var selectedFolderID: UUID? = nil
    var notes: String = ""
    var tagInput: String = ""
    var isExtracting: Bool = true
    var isSaving: Bool = false
    var errorMessage: String?
    var statusNotice: String?

    let usesSharedAppGroup: Bool

    init(
        extensionContext: NSExtensionContext?,
        openURLHandler: @escaping @MainActor (URL) async -> Bool
    ) {
        self.extensionContext = extensionContext
        self.openURLHandler = openURLHandler
        self.usesSharedAppGroup = MobileLibraryContainer.isAppGroupAvailable
        self.folders = MobileLibraryContainer.loadSharedFoldersSnapshot()
        let staging = FileManager.default.temporaryDirectory
            .appending(path: "CharkleShareStaging-\(UUID().uuidString)", directoryHint: .isDirectory)
        try? FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
        self.tempStagingDir = staging
    }

    func extractSharedItems() async {
        isExtracting = true
        defer { isExtracting = false }

        guard let extensionItems = extensionContext?.inputItems as? [NSExtensionItem] else {
            errorMessage = "未识别到可收藏的图片、链接或文件。"
            return
        }

        var rawCollected: [ExtractedShareItem] = []
        for extItem in extensionItems {
            let itemTitle = extItem.attributedTitle?.string.trimmingCharacters(in: .whitespacesAndNewlines)
            let providers = extItem.attachments ?? []
            var extractedFromProviders = false

            for provider in providers {
                if let extracted = await loadItem(from: provider, fallbackTitle: itemTitle) {
                    rawCollected.append(extracted)
                    extractedFromProviders = true
                }
            }

            // Fallback: some apps (e.g. X / Xiaohongshu / News) place URL or share copy in attributedContentText.
            if !extractedFromProviders,
               let content = extItem.attributedContentText?.string.trimmingCharacters(in: .whitespacesAndNewlines),
               !content.isEmpty {
                rawCollected.append(Self.classifyTextOrURL(content, explicitTitle: itemTitle))
            }
        }

        items = Self.deduplicateExtractedItems(rawCollected)
        if items.isEmpty {
            errorMessage = "未识别到可收藏的图片、链接或文件。"
        }
    }

    func saveToQueue() async -> Bool {
        guard !items.isEmpty, !isSaving else { return false }
        isSaving = true
        errorMessage = nil
        statusNotice = nil
        defer { isSaving = false }

        let parsedTags = tagInput
            .split(whereSeparator: { $0 == "," || $0 == "，" || $0 == " " })
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        let userNotes = notes.trimmingCharacters(in: .whitespacesAndNewlines)

        func mergedNotes(embedded: String?) -> String? {
            let parts = [userNotes, embedded?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""]
                .filter { !$0.isEmpty }
            return parts.isEmpty ? nil : parts.joined(separator: "\n")
        }

        do {
            // Path A: Genuine OS-granted App Group container is available -> queue safely into shared App Group.
            if usesSharedAppGroup {
                let dir = MobileLibraryContainer.pendingCapturesDirectory()
                for item in items {
                    switch item.source {
                    case .stagedFile(let sourceURL):
                        let ext = sourceURL.pathExtension.isEmpty ? "bin" : sourceURL.pathExtension
                        let stagedName = "media-\(UUID().uuidString).\(ext)"
                        let dest = dir.appending(path: stagedName)
                        try FileManager.default.copyItem(at: sourceURL, to: dest)
                        let payload = PendingSharePayload(
                            kind: .file,
                            stagedFileName: stagedName,
                            title: item.explicitTitle,
                            notes: mergedNotes(embedded: nil),
                            tags: parsedTags,
                            targetFolderID: selectedFolderID
                        )
                        try MobileLibraryContainer.enqueuePendingCapture(payload)

                    case .imageData(let data, let ext):
                        let stagedName = "image-\(UUID().uuidString).\(ext)"
                        let dest = dir.appending(path: stagedName)
                        try data.write(to: dest, options: .atomic)
                        let payload = PendingSharePayload(
                            kind: .file,
                            stagedFileName: stagedName,
                            title: item.explicitTitle,
                            notes: mergedNotes(embedded: nil),
                            tags: parsedTags,
                            targetFolderID: selectedFolderID
                        )
                        try MobileLibraryContainer.enqueuePendingCapture(payload)

                    case .webURL(let url, let embeddedNotes):
                        let payload = PendingSharePayload(
                            kind: .webURL,
                            urlString: url.absoluteString,
                            title: item.explicitTitle,
                            notes: mergedNotes(embedded: embeddedNotes),
                            tags: parsedTags,
                            targetFolderID: selectedFolderID
                        )
                        try MobileLibraryContainer.enqueuePendingCapture(payload)

                    case .text(let text):
                        let payload = PendingSharePayload(
                            kind: .text,
                            text: text,
                            title: item.explicitTitle,
                            notes: mergedNotes(embedded: nil),
                            tags: parsedTags,
                            targetFolderID: selectedFolderID
                        )
                        try MobileLibraryContainer.enqueuePendingCapture(payload)
                    }
                }
                cleanupStaging()
                return true
            }

            // Path B: Sideloaded / re-signed IPA without active App Group -> NEVER drop into private extension sandbox.
            // Hand off directly to CharkleMobile via `charkle-mobile://import` (inline URL for links/text, or
            // local-only short-lived pasteboard envelope for images/files/large batches).
            var payloads: [PendingSharePayload] = []
            var embeddedFiles: [String: Data] = [:]
            var hasBinaryFiles = false

            for item in items {
                switch item.source {
                case .stagedFile(let sourceURL):
                    let ext = sourceURL.pathExtension.isEmpty ? "bin" : sourceURL.pathExtension
                    let stagedName = "media-\(UUID().uuidString).\(ext)"
                    let data = try Data(contentsOf: sourceURL)
                    embeddedFiles[stagedName] = data
                    hasBinaryFiles = true
                    payloads.append(PendingSharePayload(
                        kind: .file,
                        stagedFileName: stagedName,
                        title: item.explicitTitle,
                        notes: mergedNotes(embedded: nil),
                        tags: parsedTags,
                        targetFolderID: selectedFolderID
                    ))

                case .imageData(let data, let ext):
                    let stagedName = "image-\(UUID().uuidString).\(ext)"
                    embeddedFiles[stagedName] = data
                    hasBinaryFiles = true
                    payloads.append(PendingSharePayload(
                        kind: .file,
                        stagedFileName: stagedName,
                        title: item.explicitTitle,
                        notes: mergedNotes(embedded: nil),
                        tags: parsedTags,
                        targetFolderID: selectedFolderID
                    ))

                case .webURL(let url, let embeddedNotes):
                    payloads.append(PendingSharePayload(
                        kind: .webURL,
                        urlString: url.absoluteString,
                        title: item.explicitTitle,
                        notes: mergedNotes(embedded: embeddedNotes),
                        tags: parsedTags,
                        targetFolderID: selectedFolderID
                    ))

                case .text(let text):
                    payloads.append(PendingSharePayload(
                        kind: .text,
                        text: text,
                        title: item.explicitTitle,
                        notes: mergedNotes(embedded: nil),
                        tags: parsedTags,
                        targetFolderID: selectedFolderID
                    ))
                }
            }

            // Always stage a local-only expiring pasteboard envelope as secondary safety net when files exist
            // or if deep-link launch is blocked by the host app; for pure URL/text, prefer direct deep-link URL!
            let targetURL: URL
            if !hasBinaryFiles, let directURL = MobileLibraryContainer.deepLinkImportURL(for: payloads) {
                targetURL = directURL
            } else {
                let envelope = PasteboardShareEnvelope(payloads: payloads, files: embeddedFiles)
                let encoded = try JSONEncoder().encode(envelope)
                UIPasteboard.general.setItems(
                    [[MobileLibraryContainer.pasteboardShareTypeIdentifier: encoded]],
                    options: [
                        .localOnly: true,
                        .expirationDate: Date().addingTimeInterval(600)
                    ]
                )
                targetURL = MobileLibraryContainer.deepLinkPasteboardImportURL()
            }

            let opened = await openURLHandler(targetURL)
            if opened {
                cleanupStaging()
                return true
            }

            // If host app blocked opening URL directly, write pasteboard envelope (if not already written) so
            // switching back to Charkle automatically ingests the shared items on foreground activation.
            if !hasBinaryFiles {
                let envelope = PasteboardShareEnvelope(payloads: payloads, files: [:])
                if let encoded = try? JSONEncoder().encode(envelope) {
                    UIPasteboard.general.setItems(
                        [[MobileLibraryContainer.pasteboardShareTypeIdentifier: encoded]],
                        options: [
                            .localOnly: true,
                            .expirationDate: Date().addingTimeInterval(600)
                        ]
                    )
                }
            }
            cleanupStaging()
            statusNotice = "已暂存分享内容，请切回 Charkle App 即可自动导入。"
            try? await Task.sleep(for: .milliseconds(900))
            return true
        } catch {
            errorMessage = "保存失败：\(error.localizedDescription)"
            return false
        }
    }

    private func cleanupStaging() {
        try? FileManager.default.removeItem(at: tempStagingDir)
    }

    // MARK: - Provider Extraction

    private func loadItem(from provider: NSItemProvider, fallbackTitle: String?) async -> ExtractedShareItem? {
        // 1. Web URLs & File URLs (`public.url`) — X, Safari, Xiaohongshu, Threads, Bluesky, etc.
        if provider.hasItemConformingToTypeIdentifier(UTType.url.identifier) {
            if let loaded = await loadValue(from: provider, typeIdentifier: UTType.url.identifier),
               let url = Self.extractURL(from: loaded) {
                if url.isFileURL {
                    if let staged = stageLocalFileCopy(from: url) {
                        return ExtractedShareItem(
                            displayTitle: url.lastPathComponent,
                            subtitle: "本地文件",
                            explicitTitle: nil,
                            previewImage: previewIfImage(staged),
                            source: .stagedFile(staged)
                        )
                    }
                } else {
                    return ExtractedShareItem(
                        displayTitle: Self.displayTitleForWebURL(url, fallback: fallbackTitle),
                        subtitle: url.absoluteString,
                        explicitTitle: Self.cleanedExplicitTitle(fallbackTitle, url: url),
                        previewImage: nil,
                        source: .webURL(url, embeddedNotes: nil)
                    )
                }
            }
        }

        // 2. Images (`public.image`) — stage immediately so security-scoped URLs never expire before Save.
        if provider.hasItemConformingToTypeIdentifier(UTType.image.identifier) {
            if let loaded = await loadValue(from: provider, typeIdentifier: UTType.image.identifier) {
                switch loaded {
                case .url(let url):
                    if let staged = stageLocalFileCopy(from: url) {
                        return ExtractedShareItem(
                            displayTitle: url.lastPathComponent,
                            subtitle: "图片素材",
                            explicitTitle: nil,
                            previewImage: previewIfImage(staged),
                            source: .stagedFile(staged)
                        )
                    }
                case .imageJPEG(let data, let width, let height):
                    return ExtractedShareItem(
                        displayTitle: "分享图片",
                        subtitle: "\(width) × \(height)",
                        explicitTitle: nil,
                        previewImage: UIImage(data: data),
                        source: .imageData(data, ext: "jpg")
                    )
                case .data(let data):
                    let ext = Self.detectImageExtension(data)
                    return ExtractedShareItem(
                        displayTitle: "分享图片",
                        subtitle: ByteCountFormatter.string(fromByteCount: Int64(data.count), countStyle: .file),
                        explicitTitle: nil,
                        previewImage: UIImage(data: data),
                        source: .imageData(data, ext: ext)
                    )
                case .text:
                    break
                }
            }
            if let staged = await stageFileRepresentation(from: provider, typeIdentifier: UTType.image.identifier) {
                return ExtractedShareItem(
                    displayTitle: staged.lastPathComponent,
                    subtitle: "图片素材",
                    explicitTitle: nil,
                    previewImage: previewIfImage(staged),
                    source: .stagedFile(staged)
                )
            }
        }

        // 3. Videos / Movies (`public.movie`)
        if provider.hasItemConformingToTypeIdentifier(UTType.movie.identifier) {
            if let staged = await stageFileRepresentation(from: provider, typeIdentifier: UTType.movie.identifier) {
                return ExtractedShareItem(
                    displayTitle: staged.lastPathComponent,
                    subtitle: "视频素材",
                    explicitTitle: nil,
                    previewImage: nil,
                    source: .stagedFile(staged)
                )
            }
            if let loaded = await loadValue(from: provider, typeIdentifier: UTType.movie.identifier),
               case .url(let url) = loaded,
               let staged = stageLocalFileCopy(from: url) {
                return ExtractedShareItem(
                    displayTitle: url.lastPathComponent,
                    subtitle: "视频素材",
                    explicitTitle: nil,
                    previewImage: nil,
                    source: .stagedFile(staged)
                )
            }
        }

        // 4. Plain Text (`public.plain-text`) — extract embedded X / Xiaohongshu / Web URLs cleanly!
        if provider.hasItemConformingToTypeIdentifier(UTType.plainText.identifier),
           let loaded = await loadValue(from: provider, typeIdentifier: UTType.plainText.identifier),
           let text = Self.extractText(from: loaded) {
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty {
                return Self.classifyTextOrURL(trimmed, explicitTitle: fallbackTitle)
            }
        }

        // 5. Safari / Browser Property List (`com.apple.property-list`)
        if provider.hasItemConformingToTypeIdentifier(UTType.propertyList.identifier),
           let plistURL = await loadWebURLFromPropertyList(provider) {
            return ExtractedShareItem(
                displayTitle: Self.displayTitleForWebURL(plistURL.url, fallback: plistURL.title ?? fallbackTitle),
                subtitle: plistURL.url.absoluteString,
                explicitTitle: Self.cleanedExplicitTitle(plistURL.title ?? fallbackTitle, url: plistURL.url),
                previewImage: nil,
                source: .webURL(plistURL.url, embeddedNotes: nil)
            )
        }

        // 6. Generic Files (`public.file-url` / `public.item`)
        if provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) {
            if let loaded = await loadValue(from: provider, typeIdentifier: UTType.fileURL.identifier),
               let url = Self.extractURL(from: loaded),
               url.isFileURL,
               let staged = stageLocalFileCopy(from: url) {
                return ExtractedShareItem(
                    displayTitle: url.lastPathComponent,
                    subtitle: "文件",
                    explicitTitle: nil,
                    previewImage: previewIfImage(staged),
                    source: .stagedFile(staged)
                )
            }
        }
        return nil
    }

    private func stageLocalFileCopy(from sourceURL: URL) -> URL? {
        let didAccess = sourceURL.startAccessingSecurityScopedResource()
        defer {
            if didAccess { sourceURL.stopAccessingSecurityScopedResource() }
        }
        let ext = sourceURL.pathExtension.isEmpty ? "bin" : sourceURL.pathExtension
        let safeName = "\(UUID().uuidString).\(ext)"
        let dest = tempStagingDir.appending(path: safeName)
        do {
            try FileManager.default.copyItem(at: sourceURL, to: dest)
            return dest
        } catch {
            if let data = try? Data(contentsOf: sourceURL) {
                do {
                    try data.write(to: dest, options: .atomic)
                    return dest
                } catch {
                    return nil
                }
            }
            return nil
        }
    }

    private func stageFileRepresentation(from provider: NSItemProvider, typeIdentifier: String) async -> URL? {
        let targetDir = tempStagingDir
        return await withCheckedContinuation { continuation in
            provider.loadFileRepresentation(forTypeIdentifier: typeIdentifier) { url, _ in
                guard let url else {
                    continuation.resume(returning: nil)
                    return
                }
                let ext = url.pathExtension.isEmpty ? "bin" : url.pathExtension
                let dest = targetDir.appending(path: "\(UUID().uuidString).\(ext)")
                do {
                    try FileManager.default.copyItem(at: url, to: dest)
                    continuation.resume(returning: dest)
                } catch {
                    continuation.resume(returning: nil)
                }
            }
        }
    }

    private func loadWebURLFromPropertyList(_ provider: NSItemProvider) async -> (url: URL, title: String?)? {
        await withCheckedContinuation { continuation in
            provider.loadItem(forTypeIdentifier: UTType.propertyList.identifier, options: nil) { item, _ in
                guard let dict = item as? NSDictionary,
                      let results = dict[NSExtensionJavaScriptPreprocessingResultsKey] as? NSDictionary,
                      let urlStr = results["URL"] as? String ?? results["url"] as? String,
                      let url = URL(string: urlStr) else {
                    continuation.resume(returning: nil)
                    return
                }
                let title = results["title"] as? String
                continuation.resume(returning: (url, title))
            }
        }
    }

    private func loadValue(from provider: NSItemProvider, typeIdentifier: String) async -> LoadedProviderValue? {
        await withCheckedContinuation { continuation in
            provider.loadItem(forTypeIdentifier: typeIdentifier, options: nil) { item, _ in
                let converted: LoadedProviderValue?
                if let url = item as? URL {
                    converted = .url(url)
                } else if let nsURL = item as? NSURL, let url = nsURL as URL? {
                    converted = .url(url)
                } else if let image = item as? UIImage, let data = image.jpegData(compressionQuality: 0.92) {
                    converted = .imageJPEG(data, width: Int(image.size.width), height: Int(image.size.height))
                } else if let data = item as? Data {
                    converted = .data(data)
                } else if let text = item as? String {
                    converted = .text(text)
                } else if let attr = item as? NSAttributedString {
                    converted = .text(attr.string)
                } else {
                    converted = nil
                }
                continuation.resume(returning: converted)
            }
        }
    }

    private static func extractURL(from loaded: LoadedProviderValue) -> URL? {
        switch loaded {
        case .url(let url):
            return url
        case .text(let raw):
            return firstWebOrFileURL(in: raw)
        case .data(let data):
            if let direct = URL(dataRepresentation: data, relativeTo: nil),
               let scheme = direct.scheme?.lowercased(),
               scheme == "http" || scheme == "https" || scheme == "file" {
                return direct
            }
            if let str = String(data: data, encoding: .utf8), let url = firstWebOrFileURL(in: str) {
                return url
            }
            if let plist = try? PropertyListSerialization.propertyList(from: data, options: [], format: nil) as? [Any] {
                for element in plist {
                    if let str = element as? String, let url = firstWebOrFileURL(in: str) {
                        return url
                    }
                }
            }
            return nil
        case .imageJPEG:
            return nil
        }
    }

    private static func extractText(from loaded: LoadedProviderValue) -> String? {
        switch loaded {
        case .text(let str): return str
        case .data(let data): return String(data: data, encoding: .utf8)
        case .url(let url): return url.absoluteString
        case .imageJPEG: return nil
        }
    }

    private static func firstWebOrFileURL(in raw: String) -> URL? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if let direct = URL(string: trimmed),
           let scheme = direct.scheme?.lowercased(),
           scheme == "http" || scheme == "https" || scheme == "file" {
            return direct
        }
        guard let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue) else {
            return nil
        }
        let range = NSRange(trimmed.startIndex..., in: trimmed)
        for match in detector.matches(in: trimmed, options: [], range: range) {
            if let url = match.url,
               let scheme = url.scheme?.lowercased(),
               scheme == "http" || scheme == "https" {
                return url
            }
        }
        return nil
    }

    private static func classifyTextOrURL(_ trimmed: String, explicitTitle: String?) -> ExtractedShareItem {
        if let url = firstWebOrFileURL(in: trimmed), !url.isFileURL {
            let embeddedNotes: String? = (trimmed == url.absoluteString) ? nil : trimmed
            return ExtractedShareItem(
                displayTitle: displayTitleForWebURL(url, fallback: explicitTitle),
                subtitle: url.absoluteString,
                explicitTitle: cleanedExplicitTitle(explicitTitle, url: url),
                previewImage: nil,
                source: .webURL(url, embeddedNotes: embeddedNotes)
            )
        }
        return ExtractedShareItem(
            displayTitle: String(trimmed.prefix(40)),
            subtitle: trimmed,
            explicitTitle: explicitTitle?.isEmpty == false ? explicitTitle : nil,
            previewImage: nil,
            source: .text(trimmed)
        )
    }

    private static func displayTitleForWebURL(_ url: URL, fallback: String?) -> String {
        if let fallback, !fallback.isEmpty, fallback != url.absoluteString {
            return fallback
        }
        let host = (url.host() ?? "").lowercased()
        if host.contains("x.com") || host.contains("twitter.com") {
            return "X 推文链接"
        }
        if host.contains("xiaohongshu.com") || host.contains("xhslink.com") {
            return "小红书笔记"
        }
        if host.contains("github.com") {
            return "GitHub 仓库"
        }
        return url.host() ?? url.absoluteString
    }

    private static func cleanedExplicitTitle(_ raw: String?, url: URL) -> String? {
        guard let trimmed = raw?.trimmingCharacters(in: .whitespacesAndNewlines),
              !trimmed.isEmpty,
              trimmed != url.absoluteString,
              trimmed.caseInsensitiveCompare(url.host() ?? "") != .orderedSame else {
            return nil
        }
        return trimmed
    }

    /// Deduplicates when host apps (such as X or Safari) attach BOTH a `URL` provider and a
    /// `plainText` provider referencing the exact same URL, merging any extra caption text into notes.
    private static func deduplicateExtractedItems(_ items: [ExtractedShareItem]) -> [ExtractedShareItem] {
        var result: [ExtractedShareItem] = []
        var webURLIndexByKey: [String: Int] = [:]

        for item in items {
            if case .webURL(let url, let embeddedNotes) = item.source {
                let key = url.absoluteString.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
                if let existingIdx = webURLIndexByKey[key] {
                    if case .webURL(let existingURL, let existingNotes) = result[existingIdx].source {
                        let merged = [existingNotes, embeddedNotes]
                            .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
                            .filter { !$0.isEmpty }
                            .joined(separator: "\n")
                        let bestTitle = result[existingIdx].explicitTitle ?? item.explicitTitle
                        result[existingIdx] = ExtractedShareItem(
                            displayTitle: result[existingIdx].displayTitle,
                            subtitle: result[existingIdx].subtitle,
                            explicitTitle: bestTitle,
                            previewImage: result[existingIdx].previewImage,
                            source: .webURL(existingURL, embeddedNotes: merged.isEmpty ? nil : merged)
                        )
                    }
                    continue
                }
                webURLIndexByKey[key] = result.count
                result.append(item)
            } else {
                result.append(item)
            }
        }
        return result
    }

    private static func detectImageExtension(_ data: Data) -> String {
        if data.starts(with: [0x89, 0x50, 0x4E, 0x47]) { return "png" }
        if data.starts(with: [0x47, 0x49, 0x46, 0x38]) { return "gif" }
        if data.count >= 12,
           String(decoding: data[0..<4], as: UTF8.self) == "RIFF",
           String(decoding: data[8..<12], as: UTF8.self) == "WEBP" {
            return "webp"
        }
        return "jpg"
    }

    private func previewIfImage(_ url: URL) -> UIImage? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return UIImage(data: data)
    }
}

private struct ShareSheetRootView: View {
    @Bindable var model: ShareExtensionViewModel
    let onDismiss: () -> Void
    let onCancel: () -> Void

    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    if model.isExtracting {
                        HStack(spacing: 10) {
                            ProgressView()
                            Text("正在读取分享内容…")
                                .font(.system(size: 14))
                                .foregroundStyle(.secondary)
                        }
                        .frame(maxWidth: .infinity, alignment: .center)
                        .padding(.vertical, 28)
                    } else if let error = model.errorMessage {
                        Text(error)
                            .font(.system(size: 14))
                            .foregroundStyle(.red)
                            .padding()
                    } else {
                        if let notice = model.statusNotice {
                            HStack(spacing: 8) {
                                Image(systemName: "checkmark.circle.fill")
                                    .foregroundStyle(.green)
                                Text(notice)
                                    .font(.system(size: 13, weight: .medium))
                            }
                            .padding(12)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(Color.green.opacity(0.12), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                        }

                        previewCard
                        if !model.folders.isEmpty || model.usesSharedAppGroup {
                            destinationSection
                        }
                        metadataSection

                        if !model.usesSharedAppGroup {
                            Label(
                                "点击「存入并打开」将自动唤起 Charkle 完成解析与入库。",
                                systemImage: "arrow.up.forward.app"
                            )
                            .font(.system(size: 12))
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, 4)
                        }
                    }
                }
                .padding(16)
            }
            .background(colorScheme == .dark ? Color(red: 0.08, green: 0.082, blue: 0.09) : Color(red: 0.965, green: 0.965, blue: 0.961))
            .navigationTitle("存到 Charkle")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消", action: onCancel)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button {
                        Task {
                            if await model.saveToQueue() {
                                onDismiss()
                            }
                        }
                    } label: {
                        if model.isSaving {
                            ProgressView()
                        } else {
                            Text(model.usesSharedAppGroup ? "存入 (\(model.items.count))" : "存入并打开")
                                .fontWeight(.semibold)
                        }
                    }
                    .disabled(model.items.isEmpty || model.isSaving)
                }
            }
        }
    }

    private var previewCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let firstImage = model.items.compactMap(\.previewImage).first {
                Image(uiImage: firstImage)
                    .resizable()
                    .scaledToFill()
                    .frame(maxWidth: .infinity)
                    .frame(height: 160)
                    .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            }
            ForEach(model.items.prefix(4)) { item in
                VStack(alignment: .leading, spacing: 2) {
                    Text(item.displayTitle)
                        .font(.system(size: 14, weight: .semibold))
                        .lineLimit(1)
                    Text(item.subtitle)
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
            }
            if model.items.count > 4 {
                Text("以及另外 \(model.items.count - 4) 项内容")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.secondary)
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            colorScheme == .dark ? Color(red: 0.118, green: 0.125, blue: 0.145) : Color.white,
            in: RoundedRectangle(cornerRadius: 14, style: .continuous)
        )
    }

    private var destinationSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("存放位置")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.secondary)
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    folderChip(title: "收件箱", id: nil)
                    ForEach(model.folders) { folder in
                        folderChip(title: folder.name, id: folder.id)
                    }
                }
            }
        }
    }

    private func folderChip(title: String, id: UUID?) -> some View {
        let isSelected = model.selectedFolderID == id
        let accent = colorScheme == .dark
            ? Color(red: 0.357, green: 0.553, blue: 0.937)
            : Color(red: 0.165, green: 0.376, blue: 0.878)
        return Button {
            model.selectedFolderID = id
        } label: {
            Text(title)
                .font(.system(size: 13, weight: isSelected ? .semibold : .medium))
                .foregroundStyle(isSelected ? .white : .primary)
                .padding(.horizontal, 12)
                .padding(.vertical, 7)
                .background(
                    isSelected
                        ? accent
                        : (colorScheme == .dark ? Color(red: 0.14, green: 0.15, blue: 0.17) : Color(red: 0.93, green: 0.93, blue: 0.91)),
                    in: Capsule()
                )
        }
        .buttonStyle(.plain)
    }

    private var metadataSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            TextField("标签（用逗号或空格分隔）", text: $model.tagInput)
                .textFieldStyle(.plain)
                .padding(12)
                .background(
                    colorScheme == .dark ? Color(red: 0.118, green: 0.125, blue: 0.145) : Color.white,
                    in: RoundedRectangle(cornerRadius: 12, style: .continuous)
                )
            TextField("备注（可选）", text: $model.notes, axis: .vertical)
                .lineLimit(2...4)
                .textFieldStyle(.plain)
                .padding(12)
                .background(
                    colorScheme == .dark ? Color(red: 0.118, green: 0.125, blue: 0.145) : Color.white,
                    in: RoundedRectangle(cornerRadius: 12, style: .continuous)
                )
        }
    }
}
