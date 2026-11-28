import ImageIO
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
                model.cleanupStaging()
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
        case stagedFile(URL, originalFileName: String?)
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

    deinit {
        try? FileManager.default.removeItem(at: tempStagingDir)
    }

    func extractSharedItems() async {
        isExtracting = true
        defer { isExtracting = false }

        guard let extensionItems = extensionContext?.inputItems as? [NSExtensionItem] else {
            errorMessage = "未识别到可收藏的图片、链接或文件。"
            return
        }

        var rawCollected: [ExtractedShareItem] = []
        var hasPreviewImage = false
        for extItem in extensionItems {
            let itemTitle = extItem.attributedTitle?.string.trimmingCharacters(in: .whitespacesAndNewlines)
            let providers = extItem.attachments ?? []
            var extractedFromProviders = false

            for provider in providers {
                if let extracted = await loadItem(
                    from: provider,
                    fallbackTitle: itemTitle,
                    generatePreview: !hasPreviewImage
                ) {
                    if extracted.previewImage != nil {
                        hasPreviewImage = true
                    }
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
                    case .stagedFile(let sourceURL, let originalFileName):
                        let ext = sourceURL.pathExtension.isEmpty ? "bin" : sourceURL.pathExtension
                        let stagedName = "media-\(UUID().uuidString).\(ext)"
                        let dest = dir.appending(path: stagedName)
                        try FileManager.default.copyItem(at: sourceURL, to: dest)
                        let payload = PendingSharePayload(
                            kind: .file,
                            stagedFileName: stagedName,
                            originalFileName: originalFileName,
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
            // Bound total binary payload inside Share Extension's ~120 MB Jetsam ceiling.
            let maxPasteboardBinaryBytes = 12 * 1024 * 1024
            var totalBinaryBytes = 0
            var payloads: [PendingSharePayload] = []
            var embeddedFiles: [String: Data] = [:]
            var hasBinaryFiles = false

            for item in items {
                switch item.source {
                case .stagedFile(let sourceURL, let originalFileName):
                    let originalExt = sourceURL.pathExtension.isEmpty ? "bin" : sourceURL.pathExtension
                    let fileSize = (try? sourceURL.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
                    let data: Data
                    let finalExt: String
                    if fileSize > 2_500_000, let compactJPEG = Self.downscaledJPEGData(from: sourceURL, maxPixelSize: 2400) {
                        data = compactJPEG
                        finalExt = "jpg"
                    } else if fileSize > maxPasteboardBinaryBytes {
                        errorMessage = "文件体积过大（\(ByteCountFormatter.string(fromByteCount: Int64(fileSize), countStyle: .file))），无 App Group 环境下请直接在 Charkle 应用内「采集 → 相册 / 文件」导入。"
                        return false
                    } else {
                        data = try Data(contentsOf: sourceURL)
                        finalExt = originalExt
                    }
                    let stagedName = "media-\(UUID().uuidString).\(finalExt)"
                    totalBinaryBytes += data.count
                    if totalBinaryBytes > maxPasteboardBinaryBytes {
                        errorMessage = "本次批量分享体积超出分享面板内存上限，请分批分享或直接在 Charkle 内导入。"
                        return false
                    }
                    embeddedFiles[stagedName] = data
                    hasBinaryFiles = true
                    payloads.append(PendingSharePayload(
                        kind: .file,
                        stagedFileName: stagedName,
                        originalFileName: originalFileName,
                        title: item.explicitTitle,
                        notes: mergedNotes(embedded: nil),
                        tags: parsedTags,
                        targetFolderID: selectedFolderID
                    ))

                case .imageData(let rawData, let originalExt):
                    let data: Data
                    let finalExt: String
                    if rawData.count > 2_500_000, let compactJPEG = Self.downscaledJPEGData(from: rawData, maxPixelSize: 2400) {
                        data = compactJPEG
                        finalExt = "jpg"
                    } else {
                        data = rawData
                        finalExt = originalExt
                    }
                    let stagedName = "image-\(UUID().uuidString).\(finalExt)"
                    totalBinaryBytes += data.count
                    if totalBinaryBytes > maxPasteboardBinaryBytes {
                        errorMessage = "本次批量分享图片体积超出分享面板内存上限，请分批分享或直接在 Charkle 内导入。"
                        return false
                    }
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

    func cleanupStaging() {
        try? FileManager.default.removeItem(at: tempStagingDir)
    }

    // MARK: - Provider Extraction

    private func loadItem(
        from provider: NSItemProvider,
        fallbackTitle: String?,
        generatePreview: Bool
    ) async -> ExtractedShareItem? {
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
                            previewImage: generatePreview ? downsamplePreview(from: staged) : nil,
                            source: .stagedFile(staged, originalFileName: url.lastPathComponent)
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

        // 2. Images (`public.image`) — stage immediately to disk so multi-photo shares stay well within 120MB Jetsam cap.
        if provider.hasItemConformingToTypeIdentifier(UTType.image.identifier) {
            if let staged = await stageFileRepresentation(from: provider, typeIdentifier: UTType.image.identifier) {
                return ExtractedShareItem(
                    displayTitle: staged.originalFileName ?? staged.url.lastPathComponent,
                    subtitle: "图片素材",
                    explicitTitle: nil,
                    previewImage: generatePreview ? downsamplePreview(from: staged.url) : nil,
                    source: .stagedFile(staged.url, originalFileName: staged.originalFileName)
                )
            }
            if let loaded = await loadValue(from: provider, typeIdentifier: UTType.image.identifier) {
                switch loaded {
                case .url(let url):
                    if let staged = stageLocalFileCopy(from: url) {
                        return ExtractedShareItem(
                            displayTitle: url.lastPathComponent,
                            subtitle: "图片素材",
                            explicitTitle: nil,
                            previewImage: generatePreview ? downsamplePreview(from: staged) : nil,
                            source: .stagedFile(staged, originalFileName: url.lastPathComponent)
                        )
                    }
                case .imageJPEG(let data, let width, let height):
                    let preview = generatePreview ? downsamplePreview(from: data) : nil
                    if let staged = stageDataToTempFile(data, ext: "jpg") {
                        return ExtractedShareItem(
                            displayTitle: "分享图片",
                            subtitle: "\(width) × \(height)",
                            explicitTitle: nil,
                            previewImage: preview,
                            source: .stagedFile(staged, originalFileName: nil)
                        )
                    }
                    return ExtractedShareItem(
                        displayTitle: "分享图片",
                        subtitle: "\(width) × \(height)",
                        explicitTitle: nil,
                        previewImage: preview,
                        source: .imageData(data, ext: "jpg")
                    )
                case .data(let data):
                    let ext = Self.detectImageExtension(data)
                    let preview = generatePreview ? downsamplePreview(from: data) : nil
                    if let staged = stageDataToTempFile(data, ext: ext) {
                        return ExtractedShareItem(
                            displayTitle: "分享图片",
                            subtitle: ByteCountFormatter.string(fromByteCount: Int64(data.count), countStyle: .file),
                            explicitTitle: nil,
                            previewImage: preview,
                            source: .stagedFile(staged, originalFileName: nil)
                        )
                    }
                    return ExtractedShareItem(
                        displayTitle: "分享图片",
                        subtitle: ByteCountFormatter.string(fromByteCount: Int64(data.count), countStyle: .file),
                        explicitTitle: nil,
                        previewImage: preview,
                        source: .imageData(data, ext: ext)
                    )
                case .text:
                    break
                }
            }
        }

        // 3. Videos / Movies (`public.movie`)
        if provider.hasItemConformingToTypeIdentifier(UTType.movie.identifier) {
            if let staged = await stageFileRepresentation(from: provider, typeIdentifier: UTType.movie.identifier) {
                return ExtractedShareItem(
                    displayTitle: staged.originalFileName ?? staged.url.lastPathComponent,
                    subtitle: "视频素材",
                    explicitTitle: nil,
                    previewImage: nil,
                    source: .stagedFile(staged.url, originalFileName: staged.originalFileName)
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
                    source: .stagedFile(staged, originalFileName: url.lastPathComponent)
                )
            }
        }

        // 4. PDF & Office / Generic Files (`com.adobe.pdf`, `public.file-url`, `public.data`, `public.item`)
        // Placed before plain-text fallback for providers that attach a filename/document representation.
        if provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) {
            if let loaded = await loadValue(from: provider, typeIdentifier: UTType.fileURL.identifier),
               let url = Self.extractURL(from: loaded),
               url.isFileURL,
               let staged = stageLocalFileCopy(from: url) {
                return ExtractedShareItem(
                    displayTitle: url.lastPathComponent,
                    subtitle: "文件",
                    explicitTitle: nil,
                    previewImage: generatePreview ? downsamplePreview(from: staged) : nil,
                    source: .stagedFile(staged, originalFileName: url.lastPathComponent)
                )
            }
        }

        for docUTI in [UTType.pdf.identifier, UTType.data.identifier, UTType.item.identifier]
        where provider.hasItemConformingToTypeIdentifier(docUTI) && !provider.hasItemConformingToTypeIdentifier(UTType.plainText.identifier) {
            if let staged = await stageFileRepresentation(from: provider, typeIdentifier: docUTI) {
                let display = staged.originalFileName ?? fallbackTitle ?? staged.url.lastPathComponent
                return ExtractedShareItem(
                    displayTitle: display,
                    subtitle: "文档文件",
                    explicitTitle: nil,
                    previewImage: nil,
                    source: .stagedFile(staged.url, originalFileName: staged.originalFileName)
                )
            }
        }

        // 5. Plain Text (`public.plain-text`) — extract embedded X / Xiaohongshu / Web URLs cleanly!
        if provider.hasItemConformingToTypeIdentifier(UTType.plainText.identifier),
           let loaded = await loadValue(from: provider, typeIdentifier: UTType.plainText.identifier),
           let text = Self.extractText(from: loaded) {
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty {
                // Check if provider is actually a .md/.txt/.csv document file rather than bare snippet
                if let suggested = provider.suggestedName,
                   !suggested.isEmpty,
                   let staged = await stageFileRepresentation(from: provider, typeIdentifier: UTType.plainText.identifier),
                   ["md", "markdown", "txt", "csv"].contains(staged.url.pathExtension.lowercased()) {
                    return ExtractedShareItem(
                        displayTitle: staged.originalFileName ?? suggested,
                        subtitle: "文本文档",
                        explicitTitle: nil,
                        previewImage: nil,
                        source: .stagedFile(staged.url, originalFileName: staged.originalFileName ?? suggested)
                    )
                }
                return Self.classifyTextOrURL(trimmed, explicitTitle: fallbackTitle)
            }
        }

        // 6. Safari / Browser Property List (`com.apple.property-list`)
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

        return nil
    }

    private func stageDataToTempFile(_ data: Data, ext: String) -> URL? {
        let dest = tempStagingDir.appending(path: "\(UUID().uuidString).\(ext)")
        do {
            try data.write(to: dest, options: .atomic)
            return dest
        } catch {
            return nil
        }
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

    private func stageFileRepresentation(
        from provider: NSItemProvider,
        typeIdentifier: String
    ) async -> (url: URL, originalFileName: String?)? {
        let targetDir = tempStagingDir
        let suggested = provider.suggestedName?.trimmingCharacters(in: .whitespacesAndNewlines)
        return await withCheckedContinuation { continuation in
            provider.loadFileRepresentation(forTypeIdentifier: typeIdentifier) { url, _ in
                guard let url else {
                    continuation.resume(returning: nil)
                    return
                }
                let ext = url.pathExtension.isEmpty ? "bin" : url.pathExtension
                let rawOriginal = url.lastPathComponent
                let resolvedOriginal: String? = {
                    if let suggested, !suggested.isEmpty {
                        if (suggested as NSString).pathExtension.isEmpty {
                            return "\(suggested).\(ext)"
                        }
                        return suggested
                    }
                    return rawOriginal.isEmpty ? nil : rawOriginal
                }()
                let dest = targetDir.appending(path: "\(UUID().uuidString).\(ext)")
                do {
                    try FileManager.default.copyItem(at: url, to: dest)
                    continuation.resume(returning: (dest, resolvedOriginal))
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
        // Scan explicitly for http(s):// stopping at whitespace, CJK characters, or brackets
        // so Chinese mobile share copy (e.g. Douyin/Xiaohongshu zero-space glued links) always resolves.
        let trailingPunctuation = CharacterSet(charactersIn: ".,;!?)]，。！？")
        let boundaryChars: Set<Character> = ["<", ">", "\"", "'", "（", "）", "【", "】"]
        var scanIdx = trimmed.startIndex
        while scanIdx < trimmed.endIndex {
            let rest = trimmed[scanIdx...]
            let prefixLower = rest.prefix(8).lowercased()
            if prefixLower.hasPrefix("https://") || prefixLower.hasPrefix("http://") {
                var end = rest.endIndex
                var cursor = rest.startIndex
                while cursor < rest.endIndex {
                    let ch = rest[cursor]
                    let scalar = ch.unicodeScalars.first?.value ?? 0
                    if ch.isWhitespace || scalar >= 0x2E80 || boundaryChars.contains(ch) {
                        end = cursor
                        break
                    }
                    cursor = rest.index(after: cursor)
                }
                let candidate = String(rest[..<end]).trimmingCharacters(in: trailingPunctuation)
                if let url = URL(string: candidate),
                   let host = url.host(), host.contains(".") {
                    return url
                }
            }
            scanIdx = trimmed.index(after: scanIdx)
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
        if host.contains("douyin.com") || host.contains("iesdouyin.com") {
            return "抖音作品"
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

    private func downsamplePreview(from url: URL, maxPixelSize: CGFloat = 640) -> UIImage? {
        autoreleasepool {
            let sourceOptions: [CFString: Any] = [kCGImageSourceShouldCache: false]
            guard let source = CGImageSourceCreateWithURL(url as CFURL, sourceOptions as CFDictionary) else {
                return nil
            }
            let thumbOptions: [CFString: Any] = [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceShouldCacheImmediately: true,
                kCGImageSourceThumbnailMaxPixelSize: Int(maxPixelSize)
            ]
            guard let cgImage = CGImageSourceCreateThumbnailAtIndex(source, 0, thumbOptions as CFDictionary) else {
                return nil
            }
            return UIImage(cgImage: cgImage)
        }
    }

    private func downsamplePreview(from data: Data, maxPixelSize: CGFloat = 640) -> UIImage? {
        autoreleasepool {
            let sourceOptions: [CFString: Any] = [kCGImageSourceShouldCache: false]
            guard let source = CGImageSourceCreateWithData(data as CFData, sourceOptions as CFDictionary) else {
                return nil
            }
            let thumbOptions: [CFString: Any] = [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceShouldCacheImmediately: true,
                kCGImageSourceThumbnailMaxPixelSize: Int(maxPixelSize)
            ]
            guard let cgImage = CGImageSourceCreateThumbnailAtIndex(source, 0, thumbOptions as CFDictionary) else {
                return nil
            }
            return UIImage(cgImage: cgImage)
        }
    }

    private static func downscaledJPEGData(from url: URL, maxPixelSize: CGFloat) -> Data? {
        autoreleasepool {
            let sourceOptions: [CFString: Any] = [kCGImageSourceShouldCache: false]
            guard let source = CGImageSourceCreateWithURL(url as CFURL, sourceOptions as CFDictionary),
                  CGImageSourceGetCount(source) == 1 else {
                return nil
            }
            let thumbOptions: [CFString: Any] = [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceShouldCacheImmediately: true,
                kCGImageSourceThumbnailMaxPixelSize: Int(maxPixelSize)
            ]
            guard let cgImage = CGImageSourceCreateThumbnailAtIndex(source, 0, thumbOptions as CFDictionary) else {
                return nil
            }
            return UIImage(cgImage: cgImage).jpegData(compressionQuality: 0.82)
        }
    }

    private static func downscaledJPEGData(from data: Data, maxPixelSize: CGFloat) -> Data? {
        autoreleasepool {
            let sourceOptions: [CFString: Any] = [kCGImageSourceShouldCache: false]
            guard let source = CGImageSourceCreateWithData(data as CFData, sourceOptions as CFDictionary),
                  CGImageSourceGetCount(source) == 1 else {
                return nil
            }
            let thumbOptions: [CFString: Any] = [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceShouldCacheImmediately: true,
                kCGImageSourceThumbnailMaxPixelSize: Int(maxPixelSize)
            ]
            guard let cgImage = CGImageSourceCreateThumbnailAtIndex(source, 0, thumbOptions as CFDictionary) else {
                return nil
            }
            return UIImage(cgImage: cgImage).jpegData(compressionQuality: 0.82)
        }
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
                    folderChip(title: "收件箱", id: nil, depth: 0, colorHex: nil)
                    ForEach(model.folders) { folder in
                        folderChip(title: folder.name, id: folder.id, depth: folder.depth, colorHex: folder.colorHex)
                    }
                }
            }
        }
    }

    private func folderChip(title: String, id: UUID?, depth: Int, colorHex: String?) -> some View {
        let isSelected = model.selectedFolderID == id
        let accent = colorScheme == .dark
            ? Color(red: 0.357, green: 0.553, blue: 0.937)
            : Color(red: 0.165, green: 0.376, blue: 0.878)
        let prefix = depth > 0 ? String(repeating: "↳ ", count: min(depth, 2)) : ""
        return Button {
            model.selectedFolderID = id
        } label: {
            HStack(spacing: 5) {
                if let dot = Self.shareColor(fromHex: colorHex) {
                    Circle()
                        .fill(isSelected ? Color.white.opacity(0.92) : dot)
                        .frame(width: 7, height: 7)
                }
                Text("\(prefix)\(title)")
                    .font(.system(size: 13, weight: isSelected ? .semibold : .medium))
                    .foregroundStyle(isSelected ? .white : .primary)
            }
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

    private static func shareColor(fromHex raw: String?) -> Color? {
        guard let raw else { return nil }
        let cleaned = raw.trimmingCharacters(in: .whitespacesAndNewlines).replacingOccurrences(of: "#", with: "")
        var hex: UInt64 = 0
        guard cleaned.count == 6, Scanner(string: cleaned).scanHexInt64(&hex) else { return nil }
        return Color(
            red: Double((hex >> 16) & 0xFF) / 255.0,
            green: Double((hex >> 8) & 0xFF) / 255.0,
            blue: Double(hex & 0xFF) / 255.0
        )
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
