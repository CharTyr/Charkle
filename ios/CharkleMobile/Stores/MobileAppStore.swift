import CharkleCore
import Foundation
import SwiftUI
import UIKit

enum MobileScope: Hashable, Sendable {
    case allItems
    case inbox
    case moodboardsHome
    case moodboard(UUID)
    case recent
    case untagged
    case trash
    case folder(UUID)
    case smartFolder(UUID)
    case tag(String)
}

struct MobileToast: Identifiable, Equatable {
    enum Tone {
        case info
        case success
        case warning
        case error
    }

    let id = UUID()
    let message: String
    let tone: Tone
    let actionTitle: String?
    let onAction: (() -> Void)?

    init(
        message: String,
        tone: Tone = .info,
        actionTitle: String? = nil,
        onAction: (() -> Void)? = nil
    ) {
        self.message = message
        self.tone = tone
        self.actionTitle = actionTitle
        self.onAction = onAction
    }

    static func == (lhs: MobileToast, rhs: MobileToast) -> Bool {
        lhs.id == rhs.id
            && lhs.message == rhs.message
            && lhs.tone == rhs.tone
            && lhs.actionTitle == rhs.actionTitle
    }
}

/// Unified `@MainActor` store powering both iPadOS (`NavigationSplitView`) and iOS (`TabView`)
/// for Charkle's Capture + Browse/Search + Google Drive Bidirectional Sync MVP.
@Observable
final class MobileAppStore {
    let engine: any CharkleEngineProtocol
    let thumbnails: MobileThumbnailCache
    private let authPresenter = GoogleAuthPresenter()

    // MARK: - Navigation & Library State
    var scope: MobileScope = .allItems
    var assets: [AssetRecord] = []
    var inboxAssets: [AssetRecord] = []
    var folders: [FolderRecord] = []
    var smartFolders: [SmartFolderRecord] = []
    var boards: [MoodboardSummary] = []
    var tagCounts: [TagCount] = []
    var inboxCount: Int = 0
    var isLoadingLibrary: Bool = false
    var isReloadingAssets: Bool = false
    var hasCompletedInitialLoad: Bool = false
    var hasBootstrapped: Bool = false

    @ObservationIgnored
    private var reloadAssetsGeneration: UInt64 = 0
    @ObservationIgnored
    private var lastHandledPasteboardEnvelopeID: UUID? = nil

    // MARK: - Search & Filter State
    var criteria: FilterCriteria = FilterCriteria(includeSubfolders: true)
    var searchDebounceTask: Task<Void, Never>?
    var semanticSearchEnabled: Bool = false
    var isRunningSemanticSearch: Bool = false
    var semanticSearchReport: SemanticSearchReport? = nil
    var quickJumpMatches: [QuickJumpMatch] = []
    var similarResults: [ScoredAsset] = []
    var isLoadingSimilar: Bool = false

    @ObservationIgnored
    private var colorToleranceDebounceTask: Task<Void, Never>?
    @ObservationIgnored
    private var semanticSearchGeneration: UInt64 = 0
    @ObservationIgnored
    private var semanticSearchTask: Task<SemanticSearchReport?, Never>?
    @ObservationIgnored
    private var quickJumpTask: Task<Void, Never>?

    // MARK: - Selection & Detail State
    var selectedAssetID: UUID?
    var pendingRevealAssetID: UUID?
    var highlightedAssetID: UUID?
    var isMultiSelectMode: Bool = false
    var selectedAssetIDs: Set<UUID> = []
    var columnCountOverride: Int? = nil

    @ObservationIgnored
    private var highlightDismissTask: Task<Void, Never>?

    // MARK: - Sync & Storage State
    var syncConfig: DriveSyncConfig = DriveSyncConfig(mode: .directAPIWithGDirect)
    var syncStatus: SyncStatus = SyncStatus()
    var iCloudAvailability: ICloudDriveAvailability = ICloudDriveAvailability()
    var hasGoogleOAuthClient: Bool = false
    var hasWebDAVPassword: Bool = false
    var sharedFolders: [RemoteDriveFile] = []
    var isLoadingSharedFolders: Bool = false
    var isSigningInGoogle: Bool = false
    var isSyncing: Bool = false
    var lastSyncReport: SyncReport?
    var cacheStats: CacheStats = CacheStats()

    // MARK: - Capture & UI Feedback
    var isIngesting: Bool = false
    var toast: MobileToast?
    @ObservationIgnored
    private var toastDismissTask: Task<Void, Never>?
    @ObservationIgnored
    private nonisolated(unsafe) var syncStatusObserver: NSObjectProtocol?
    @ObservationIgnored
    private nonisolated(unsafe) var progressiveSyncObserver: NSObjectProtocol?
    @ObservationIgnored
    private nonisolated(unsafe) var completeSyncObserver: NSObjectProtocol?
    @ObservationIgnored
    private nonisolated(unsafe) var enrichObserver: NSObjectProtocol?
    @ObservationIgnored
    private var progressiveRefreshTask: Task<Void, Never>?
    @ObservationIgnored
    private static let syncDecoder = JSONDecoder()

    init(engine: any CharkleEngineProtocol) {
        self.engine = engine
        self.thumbnails = MobileThumbnailCache(engine: engine)
        registerNotifications()
    }

    deinit {
        for observer in [syncStatusObserver, progressiveSyncObserver, completeSyncObserver, enrichObserver].compactMap({ $0 }) {
            NotificationCenter.default.removeObserver(observer)
        }
    }

    // MARK: - Derived Helpers

    var folderTree: [FolderHierarchyNode] {
        FolderHierarchyNode.buildTree(from: folders)
    }

    var flattenedFolders: [FolderHierarchyNode] {
        FolderHierarchyNode.flattened(from: folders)
    }

    var currentScopeTitle: String {
        switch scope {
        case .allItems: "全部素材"
        case .inbox: "收件箱"
        case .moodboardsHome: "情绪板"
        case .moodboard(let id): boards.first(where: { $0.id == id })?.title ?? "情绪板"
        case .recent: "最近"
        case .untagged: "未打标"
        case .trash: "回收站"
        case .folder(let id): folders.first(where: { $0.id == id })?.name ?? "文件夹"
        case .smartFolder(let id): smartFolders.first(where: { $0.id == id })?.name ?? "智能文件夹"
        case .tag(let tag): "#\(tag)"
        }
    }

    var activeFolderIDForCapture: UUID? {
        if case .folder(let id) = scope { return id }
        return nil
    }

    var isGoogleDriveSignedIn: Bool {
        if let acc = syncStatus.account,
           acc.source != "iCloud Drive",
           acc.source != "WebDAV",
           acc.source != "本地文件夹" {
            return true
        }
        return syncStatus.backendStatuses.contains {
            ($0.mode == .directAPIWithGDirect || $0.mode == .gdirectMount) && $0.account != nil
        }
    }

    var isGoogleDriveConnected: Bool {
        isGoogleDriveSignedIn && syncConfig.enabledBackends.contains {
            $0.mode == .directAPIWithGDirect || $0.mode == .gdirectMount
        }
    }

    var hasConnectedCloudBackend: Bool {
        for profile in syncConfig.enabledCloudBackends {
            switch profile.mode {
            case .directAPIWithGDirect, .gdirectMount:
                if isGoogleDriveSignedIn { return true }
            case .iCloudDrive:
                if !profile.iCloudCustomFolderPath.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                    || iCloudAvailability.hasAutomaticPath {
                    return true
                }
            case .webDAV:
                if !profile.webDAVServerURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    return true
                }
            case .localOnly:
                break
            }
        }
        return false
    }

    var hasActiveFilters: Bool {
        !criteria.searchQuery.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            || criteria.hasActiveVisualFilters
            || !criteria.tags.isEmpty
            || semanticSearchReport != nil
    }

    // MARK: - Lifecycle & Pending Share Queue

    func bootstrap() async {
        guard !hasBootstrapped else { return }
        hasBootstrapped = true
        await reloadAll()
        await loadSyncAndStorageState()
        await drainPendingShareCaptures()
        await drainPasteboardShareEnvelopeIfPresent()

        if hasConnectedCloudBackend {
            await syncNow(quiet: true)
        }
    }

    func handleBecameActive() async {
        await drainPendingShareCaptures()
        await drainPasteboardShareEnvelopeIfPresent()
        await refreshSyncStatus()
        if hasConnectedCloudBackend, !syncStatus.isSyncing {
            if let last = syncStatus.lastSyncedAt {
                if Date().timeIntervalSince(last) > 45 {
                    await syncNow(quiet: true)
                }
            } else {
                await syncNow(quiet: true)
            }
        }
    }

    func handleIncomingURL(_ url: URL) async {
        guard url.scheme?.lowercased() == MobileLibraryContainer.deepLinkScheme else { return }
        if !hasBootstrapped {
            await loadSyncAndStorageState()
        }
        if let directPayloads = MobileLibraryContainer.decodeDeepLinkImportPayloads(from: url), !directPayloads.isEmpty {
            await ingestSharePayloads(directPayloads, stagedFilesDirectory: nil, embeddedFiles: [:])
            return
        }
        if MobileLibraryContainer.deepLinkImportSource(from: url) == "pasteboard" {
            await drainPasteboardShareEnvelopeIfPresent()
        }
        await drainPendingShareCaptures()
        await reloadAll()
    }

    private func drainPasteboardShareEnvelopeIfPresent() async {
        let pb = UIPasteboard.general
        let uti = MobileLibraryContainer.pasteboardShareTypeIdentifier
        guard let rawData = pb.data(forPasteboardType: uti),
              let envelope = try? JSONDecoder().decode(PasteboardShareEnvelope.self, from: rawData) else {
            return
        }
        guard envelope.id != lastHandledPasteboardEnvelopeID else { return }
        lastHandledPasteboardEnvelopeID = envelope.id
        // Clear the short-lived handoff item immediately so it is never re-imported twice.
        pb.setItems([], options: [:])
        await ingestSharePayloads(envelope.payloads, stagedFilesDirectory: nil, embeddedFiles: envelope.files)
    }

    func drainPendingShareCaptures() async {
        let files = MobileLibraryContainer.listPendingCaptureFiles()
        guard !files.isEmpty else { return }

        var batchPayloads: [(payload: PendingSharePayload, fileURL: URL, dir: URL)] = []
        for fileURL in files {
            guard let data = try? Data(contentsOf: fileURL),
                  let payload = try? JSONDecoder().decode(PendingSharePayload.self, from: data) else {
                try? FileManager.default.removeItem(at: fileURL)
                continue
            }
            batchPayloads.append((payload, fileURL, fileURL.deletingLastPathComponent()))
        }
        guard !batchPayloads.isEmpty else { return }

        isIngesting = true
        showToast("正在导入系统分享内容…", tone: .info)
        defer { isIngesting = false }

        var importedTotal = 0
        for entry in batchPayloads {
            let count = await ingestSingleSharePayload(
                entry.payload,
                stagedFilesDirectory: entry.dir,
                embeddedFiles: [:]
            )
            importedTotal += count
            try? FileManager.default.removeItem(at: entry.fileURL)
            if let stagedName = entry.payload.stagedFileName {
                try? FileManager.default.removeItem(at: entry.dir.appending(path: stagedName))
            }
        }

        if importedTotal > 0 {
            await reloadAll()
            MobileHaptics.success()
            showToast("已接收来自系统分享的 \(importedTotal) 项素材", tone: .success)
            if hasConnectedCloudBackend {
                Task { await self.syncNow(quiet: true) }
            }
        }
    }

    private func ingestSharePayloads(
        _ payloads: [PendingSharePayload],
        stagedFilesDirectory: URL?,
        embeddedFiles: [String: Data]
    ) async {
        guard !payloads.isEmpty else { return }
        isIngesting = true
        showToast("正在解析并导入分享内容…", tone: .info)
        defer { isIngesting = false }

        var importedTotal = 0
        for payload in payloads {
            importedTotal += await ingestSingleSharePayload(
                payload,
                stagedFilesDirectory: stagedFilesDirectory,
                embeddedFiles: embeddedFiles
            )
        }

        if importedTotal > 0 {
            await reloadAll()
            MobileHaptics.success()
            showToast("已接收来自系统分享的 \(importedTotal) 项素材", tone: .success)
            if hasConnectedCloudBackend {
                Task { await self.syncNow(quiet: true) }
            }
        }
    }

    private func ingestSingleSharePayload(
        _ payload: PendingSharePayload,
        stagedFilesDirectory: URL?,
        embeddedFiles: [String: Data]
    ) async -> Int {
        var input: CaptureInput?
        var tempFileToCleanup: URL?
        defer {
            if let tempFileToCleanup {
                try? FileManager.default.removeItem(at: tempFileToCleanup)
            }
        }

        switch payload.kind {
        case .file:
            if let name = payload.stagedFileName {
                if let dir = stagedFilesDirectory {
                    let candidate = dir.appending(path: name)
                    if FileManager.default.fileExists(atPath: candidate.path) {
                        input = .fileURL(candidate)
                    }
                }
                if input == nil, let bytes = embeddedFiles[name] {
                    let tempURL = FileManager.default.temporaryDirectory.appending(path: "share-import-\(UUID().uuidString)-\(name)")
                    if (try? bytes.write(to: tempURL, options: .atomic)) != nil {
                        input = .fileURL(tempURL)
                        tempFileToCleanup = tempURL
                    }
                }
            }
        case .webURL:
            if let raw = payload.urlString, let parsed = WebURLParser.parse(raw) ?? URL(string: raw) {
                input = .webURL(parsed, title: payload.title, notes: payload.notes)
            }
        case .text:
            if let text = payload.text?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty {
                if let extracted = WebURLParser.extractWebURL(from: text) {
                    input = .webURL(extracted, title: payload.title, notes: payload.notes ?? text)
                } else {
                    input = .textSnippet(
                        title: payload.title ?? String(text.prefix(48)),
                        text: text,
                        sourceURL: payload.urlString
                    )
                }
            }
        }

        guard let input else { return 0 }
        do {
            let imported = try await engine.ingest([input], targetFolderID: payload.targetFolderID, targetBoardID: nil)
            if !payload.tags.isEmpty, !imported.isEmpty {
                _ = try? await engine.updateAssets(
                    AssetBatchPatch(assetIDs: imported.map(\.id), addTags: payload.tags)
                )
            }
            return imported.count
        } catch {
            showToast("导入分享内容失败：\(error.localizedDescription)", tone: .error)
            return 0
        }
    }

    // MARK: - Reload & Filtering

    func selectScope(_ next: MobileScope) {
        guard scope != next else { return }
        scope = next
        isReloadingAssets = true
        semanticSearchGeneration &+= 1
        semanticSearchTask?.cancel()
        semanticSearchTask = nil
        semanticSearchReport = nil
        isRunningSemanticSearch = false
        if isMultiSelectMode {
            isMultiSelectMode = false
            selectedAssetIDs.removeAll()
        }
        Task { await reloadAssets() }
    }

    func updateSearchQuery(_ query: String) {
        criteria.searchQuery = query
        searchDebounceTask?.cancel()
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        refreshQuickJump(for: trimmed)

        if trimmed.isEmpty, semanticSearchReport != nil {
            Task { await clearSemanticSearch() }
            return
        }

        // In semantic search mode, standard FTS stays live while typing; pressing Search/Enter runs full visual semantic ranking.
        searchDebounceTask = Task {
            try? await Task.sleep(for: .milliseconds(160))
            guard !Task.isCancelled else { return }
            if semanticSearchReport != nil {
                semanticSearchReport = nil
            }
            await reloadAssets()
        }
    }

    func clearFilters() {
        criteria.searchQuery = ""
        criteria.clearVisualFilters()
        criteria.tags.removeAll()
        semanticSearchGeneration &+= 1
        semanticSearchTask?.cancel()
        semanticSearchTask = nil
        semanticSearchReport = nil
        isRunningSemanticSearch = false
        quickJumpTask?.cancel()
        quickJumpMatches = []
        Task { await reloadAssets() }
    }

    func toggleColorFilter(_ hex: String) {
        let normalized = MobileTheme.normalizedHex(hex) ?? hex.uppercased()
        if criteria.selectedColorHex?.caseInsensitiveCompare(normalized) == .orderedSame {
            setColorFilter(nil)
        } else {
            setColorFilter(normalized)
        }
    }

    func setColorFilter(_ hex: String?) {
        let normalized = hex.flatMap { MobileTheme.normalizedHex($0) ?? $0.uppercased() }
        guard criteria.selectedColorHex?.caseInsensitiveCompare(normalized ?? "") != .orderedSame || (criteria.selectedColorHex == nil) != (normalized == nil) else {
            return
        }
        criteria.selectedColorHex = normalized
        MobileHaptics.light()
        Task {
            if semanticSearchReport != nil {
                _ = await runSemanticSearch()
            } else {
                await reloadAssets()
            }
        }
    }

    func updateColorTolerance(_ value: Double) {
        let clamped = max(10, min(55, value))
        criteria.colorTolerance = clamped
        colorToleranceDebounceTask?.cancel()
        colorToleranceDebounceTask = Task {
            try? await Task.sleep(for: .milliseconds(100))
            guard !Task.isCancelled else { return }
            if semanticSearchReport != nil {
                _ = await runSemanticSearch()
            } else {
                await reloadAssets()
            }
        }
    }

    func toggleSemanticSearchMode() {
        let trimmed = criteria.searchQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        if semanticSearchEnabled && trimmed.isEmpty {
            semanticSearchEnabled = false
            Task { await clearSemanticSearch() }
        } else if semanticSearchEnabled && semanticSearchReport != nil {
            semanticSearchEnabled = false
            Task { await clearSemanticSearch() }
        } else {
            semanticSearchEnabled = true
            MobileHaptics.light()
            if !trimmed.isEmpty {
                Task { _ = await runSemanticSearch(query: trimmed) }
            } else {
                showToast("已开启语义搜图：输入画面描述后点击搜索", tone: .info)
            }
        }
    }

    @discardableResult
    func runSemanticSearch(query: String? = nil) async -> SemanticSearchReport? {
        let resolvedQuery = (query ?? criteria.searchQuery).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !resolvedQuery.isEmpty else {
            await clearSemanticSearch()
            return nil
        }
        semanticSearchTask?.cancel()
        semanticSearchGeneration &+= 1
        let semGen = semanticSearchGeneration
        let snapshotCriteria = effectiveCriteria()

        isRunningSemanticSearch = true
        let task = Task<SemanticSearchReport?, Never> { @MainActor in
            defer {
                if semGen == self.semanticSearchGeneration {
                    self.isRunningSemanticSearch = false
                    self.semanticSearchTask = nil
                }
            }
            do {
                let report = try await self.engine.semanticSearch(
                    query: resolvedQuery,
                    criteria: snapshotCriteria,
                    limit: 60
                )
                guard !Task.isCancelled, semGen == self.semanticSearchGeneration else { return nil }
                self.semanticSearchReport = report
                self.assets = report.hits.map(\.asset)
                if !report.summary.isEmpty {
                    self.showToast(report.summary, tone: .info)
                }
                return report
            } catch {
                if !Task.isCancelled && semGen == self.semanticSearchGeneration {
                    self.showToast("语义搜图失败：\(error.localizedDescription)", tone: .warning)
                }
                return nil
            }
        }
        semanticSearchTask = task
        return await task.value
    }

    func clearSemanticSearch() async {
        semanticSearchGeneration &+= 1
        semanticSearchTask?.cancel()
        semanticSearchTask = nil
        isRunningSemanticSearch = false
        semanticSearchReport = nil
        await reloadAssets()
    }

    private func refreshQuickJump(for trimmedQuery: String) {
        quickJumpTask?.cancel()
        guard !trimmedQuery.isEmpty else {
            quickJumpMatches = []
            return
        }
        quickJumpTask = Task {
            try? await Task.sleep(for: .milliseconds(130))
            guard !Task.isCancelled else { return }
            let matches = (try? await engine.quickJump(query: trimmedQuery, limit: 12)) ?? []
            guard !Task.isCancelled else { return }
            // Keep folder, moodboard, and tag jump shortcuts (assets are already rendered in the masonry results)
            quickJumpMatches = matches.filter { $0.kind != .asset }
        }
    }

    func reloadAll() async {
        isLoadingLibrary = true
        defer {
            isLoadingLibrary = false
            hasCompletedInitialLoad = true
        }
        async let fetchedFolders = (try? engine.fetchFolders()) ?? []
        async let fetchedSmart = (try? engine.fetchSmartFolders()) ?? []
        async let fetchedBoards = (try? engine.fetchBoards()) ?? []
        async let fetchedTags = (try? engine.fetchTagCounts()) ?? []
        async let fetchedInbox = (try? engine.inboxCount()) ?? 0
        async let fetchedInboxItems = (try? engine.fetchAssets(matching: FilterCriteria(onlyInbox: true))) ?? []
        async let fetchedStats = engine.cacheStats()

        folders = await fetchedFolders
        smartFolders = await fetchedSmart
        boards = await fetchedBoards
        tagCounts = await fetchedTags
        inboxCount = await fetchedInbox
        inboxAssets = await fetchedInboxItems
        cacheStats = await fetchedStats
        publishSharedFoldersSnapshot()
        await reloadAssets()
    }

    func reloadAssets() async {
        reloadAssetsGeneration &+= 1
        let gen = reloadAssetsGeneration
        isReloadingAssets = true
        defer {
            if gen == reloadAssetsGeneration {
                isReloadingAssets = false
            }
        }
        var query = effectiveCriteria()
        let loaded: [AssetRecord]
        if case .smartFolder(let smartID) = scope {
            query.folderID = nil
            query.onlyInbox = false
            query.onlyTrashed = false
            query.includeTrashed = false
            let all = (try? await engine.fetchAssets(matching: query)) ?? []
            if let smart = smartFolders.first(where: { $0.id == smartID }) {
                loaded = all.filter { smart.rule.matches($0) }
            } else {
                loaded = []
            }
        } else {
            loaded = (try? await engine.fetchAssets(matching: query)) ?? []
        }
        guard gen == reloadAssetsGeneration else { return }
        assets = loaded
    }

    private func effectiveCriteria() -> FilterCriteria {
        var c = criteria
        c.folderID = nil
        c.onlyInbox = false
        c.onlyUntagged = false
        c.onlyRecentDays = nil
        c.onlyTrashed = false
        c.includeTrashed = false

        switch scope {
        case .allItems, .moodboardsHome, .moodboard:
            break
        case .inbox:
            c.onlyInbox = true
        case .recent:
            c.onlyRecentDays = 14
        case .untagged:
            c.onlyUntagged = true
        case .trash:
            c.onlyTrashed = true
            c.includeTrashed = true
        case .folder(let id):
            c.folderID = id
            c.includeSubfolders = true
        case .smartFolder:
            break
        case .tag(let tag):
            c.tags.insert(tag)
        }
        return c
    }

    private func publishSharedFoldersSnapshot() {
        let summaries = flattenedFolders.map { node in
            SharedFolderSummary(
                id: node.folder.id,
                name: node.folder.name,
                depth: node.depth,
                colorHex: node.folder.colorHex
            )
        }
        MobileLibraryContainer.saveSharedFoldersSnapshot(summaries)
    }

    // MARK: - Visual Similarity Search

    func loadSimilarAssets(for assetID: UUID) async {
        isLoadingSimilar = true
        defer { isLoadingSimilar = false }
        similarResults = (try? await engine.similarAssets(to: assetID, limit: 18)) ?? []
    }

    // MARK: - Capture (Photos / Files / URLs / Clipboard / Demo)

    func ingestInputs(_ inputs: [CaptureInput], targetFolderID: UUID? = nil, tags: [String] = []) async -> [AssetRecord] {
        guard !inputs.isEmpty else { return [] }
        isIngesting = true
        let hasWebInput = inputs.contains {
            if case .webURL = $0 { return true }
            return false
        }
        if hasWebInput {
            showToast("正在解析并收藏链接…", tone: .info)
        }
        defer { isIngesting = false }

        do {
            let folder = targetFolderID ?? activeFolderIDForCapture
            let imported = try await engine.ingest(inputs, targetFolderID: folder, targetBoardID: nil)
            if !tags.isEmpty, !imported.isEmpty {
                _ = try? await engine.updateAssets(AssetBatchPatch(assetIDs: imported.map(\.id), addTags: tags))
            }
            await reloadAll()
            MobileHaptics.success()
            showToast("已收藏 \(imported.count) 项素材", tone: .success)
            if hasConnectedCloudBackend {
                Task { await self.syncNow(quiet: true) }
            }
            return imported
        } catch {
            MobileHaptics.error()
            showToast("收藏失败：\(error.localizedDescription)", tone: .error)
            return []
        }
    }

    func captureFromPasteboard(targetFolderID: UUID? = nil) async -> Bool {
        let pb = UIPasteboard.general
        // Check non-prompting `has*` flags before reading values to avoid Universal Clipboard stalls
        // and duplicate iOS paste permission alerts when the clipboard holds only a URL/text string.
        if pb.hasImages, let image = pb.image, let data = image.jpegData(compressionQuality: 0.92) {
            let name = "剪贴板图片-\(Int(Date().timeIntervalSince1970)).jpg"
            let imported = await ingestInputs([.imageData(data, suggestedName: name, sourceURL: nil)], targetFolderID: targetFolderID)
            return !imported.isEmpty
        }
        if pb.hasURLs, let url = pb.url {
            let imported = await ingestInputs([.webURL(url, title: nil, notes: nil)], targetFolderID: targetFolderID)
            return !imported.isEmpty
        }
        if pb.hasStrings, let text = pb.string?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty {
            if let extracted = WebURLParser.extractWebURL(from: text) {
                let extraNotes = text == extracted.absoluteString ? nil : text
                let imported = await ingestInputs([.webURL(extracted, title: nil, notes: extraNotes)], targetFolderID: targetFolderID)
                return !imported.isEmpty
            }
            let title = String(text.prefix(48))
            let imported = await ingestInputs([.textSnippet(title: title, text: text, sourceURL: nil)], targetFolderID: targetFolderID)
            return !imported.isEmpty
        }
        showToast("剪贴板里暂时没有图片或链接", tone: .warning)
        return false
    }

    func captureURLOrShareText(_ rawText: String, notes: String = "", tags: [String] = [], targetFolderID: UUID? = nil) async -> Bool {
        let trimmed = rawText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            showToast("请先输入网页、小红书、X 或 GitHub 链接", tone: .warning)
            return false
        }
        let cleanedNotes = notes.trimmingCharacters(in: .whitespacesAndNewlines)
        let input: CaptureInput
        if let url = WebURLParser.parse(trimmed) ?? WebURLParser.extractWebURL(from: trimmed) {
            let extraNotes = cleanedNotes.isEmpty ? (trimmed == url.absoluteString ? nil : trimmed) : cleanedNotes
            input = .webURL(url, title: nil, notes: extraNotes)
        } else {
            input = .textSnippet(title: String(trimmed.prefix(48)), text: trimmed, sourceURL: nil)
        }
        let imported = await ingestInputs([input], targetFolderID: targetFolderID, tags: tags)
        return !imported.isEmpty
    }

    func seedSampleLibrary() async {
        do {
            let seeded = try await engine.seedSampleLibraryIfEmpty()
            await reloadAll()
            if seeded {
                MobileHaptics.success()
                showToast("已载入精选示例素材库", tone: .success)
            } else {
                showToast("当前素材库已有内容", tone: .info)
            }
        } catch {
            showToast("载入示例库失败：\(error.localizedDescription)", tone: .error)
        }
    }

    // MARK: - Organize & Edit

    func patchAssets(_ patch: AssetBatchPatch, successToast: String? = nil) async {
        do {
            let updated = try await engine.updateAssets(patch)
            let updatedByID = Dictionary(uniqueKeysWithValues: updated.map { ($0.id, $0) })
            for idx in assets.indices {
                if let fresh = updatedByID[assets[idx].id] {
                    assets[idx] = fresh
                }
            }
            await reloadAll()
            if let successToast {
                MobileHaptics.light()
                showToast(successToast, tone: .success)
            }
            if isGoogleDriveConnected {
                Task { await self.syncNow(quiet: true) }
            }
        } catch {
            MobileHaptics.error()
            showToast("更新失败：\(error.localizedDescription)", tone: .error)
        }
    }

    func permanentlyDelete(ids: [UUID]) async {
        guard !ids.isEmpty else { return }
        do {
            try await engine.permanentlyDeleteAssets(ids: ids)
            selectedAssetIDs.subtract(ids)
            if let sel = selectedAssetID, ids.contains(sel) {
                selectedAssetID = nil
            }
            await reloadAll()
            MobileHaptics.warning()
            showToast("已永久删除 \(ids.count) 项素材", tone: .info)
            if isGoogleDriveConnected || !syncConfig.enabledCloudBackends.isEmpty {
                Task { await self.syncNow(quiet: true) }
            }
        } catch {
            showToast("删除失败：\(error.localizedDescription)", tone: .error)
        }
    }

    func createFolder(name: String, parentID: UUID? = nil, colorHex: String? = nil) async {
        do {
            let folder = try await engine.createFolder(name: name, parentID: parentID)
            if let colorHex {
                _ = try? await engine.updateFolderAppearance(id: folder.id, colorHex: colorHex, customSymbol: nil)
            }
            await reloadAll()
            MobileHaptics.success()
            showToast("已创建文件夹「\(folder.name)」", tone: .success)
            if isGoogleDriveConnected || !syncConfig.enabledCloudBackends.isEmpty {
                Task { await self.syncNow(quiet: true) }
            }
        } catch {
            showToast("创建文件夹失败：\(error.localizedDescription)", tone: .error)
        }
    }

    func deleteFolder(id: UUID) async {
        do {
            try await engine.deleteFolder(id: id)
            if case .folder(let current) = scope, current == id {
                scope = .allItems
            }
            await reloadAll()
            showToast("已删除文件夹，素材已移回收件箱", tone: .info)
            if isGoogleDriveConnected || !syncConfig.enabledCloudBackends.isEmpty {
                Task { await self.syncNow(quiet: true) }
            }
        } catch {
            showToast("删除文件夹失败：\(error.localizedDescription)", tone: .error)
        }
    }

    func analyzeLocally(assetID: UUID) async {
        do {
            _ = try await engine.analyzeAssetsLocally(ids: [assetID])
            await reloadAll()
            await loadSimilarAssets(for: assetID)
            showToast("已完成本机视觉特征与文字提取", tone: .success)
        } catch {
            showToast("本地分析失败：\(error.localizedDescription)", tone: .error)
        }
    }

    func refreshRichMetadata(assetID: UUID) async {
        do {
            _ = try await engine.refreshRichAsset(id: assetID)
            thumbnails.invalidate(assetIDs: [assetID])
            await reloadAll()
            showToast("已刷新网页与社交卡片元数据", tone: .success)
        } catch {
            showToast("刷新失败：\(error.localizedDescription)", tone: .error)
        }
    }

    func copyAssetToPasteboard(_ asset: AssetRecord) async {
        if asset.isExternalWebLink, let url = asset.externalWebURL {
            UIPasteboard.general.url = url
            MobileHaptics.light()
            showToast("已拷贝网页链接", tone: .success)
            return
        }
        if let image = await thumbnails.loadOriginalImage(for: asset) {
            UIPasteboard.general.image = image
            MobileHaptics.light()
            showToast("已拷贝图片到剪贴板", tone: .success)
        } else if let urlStr = asset.sourceURL, let url = URL(string: urlStr) {
            UIPasteboard.general.url = url
            MobileHaptics.light()
            showToast("已拷贝来源链接", tone: .success)
        } else {
            showToast("暂无法拷贝该素材", tone: .warning)
        }
    }

    func retagAssets(_ ids: [UUID]) async {
        guard !ids.isEmpty else { return }
        showToast("正在重新提取视觉特征与标签…", tone: .info)
        do {
            _ = try await engine.analyzeAssetsLocally(ids: ids)
            let ai = await engine.aiConfig()
            if ai.provider != .disabled {
                _ = try? await engine.enrichAssetsWithCloudAI(ids: ids)
            }
            await reloadAll()
            MobileHaptics.success()
            showToast("已完成 \(ids.count) 项素材重新打标", tone: .success)
        } catch {
            showToast("重新打标失败：\(error.localizedDescription)", tone: .error)
        }
    }

    struct RevealResult {
        let asset: AssetRecord
        let scope: MobileScope
        let locationLabel: String
    }

    func revealAssetInLibrary(assetID: UUID) async -> RevealResult? {
        guard let asset = try? await engine.fetchAsset(id: assetID) else {
            showToast("该素材已不在素材库中", tone: .warning)
            return nil
        }

        let targetScope: MobileScope
        var label: String
        if asset.isTrashed {
            targetScope = .trash
            label = "回收站"
        } else if let fid = asset.folderID, let folder = folders.first(where: { $0.id == fid }) {
            targetScope = .folder(fid)
            label = folder.name
        } else {
            targetScope = .allItems
            label = "全部素材"
        }

        scope = targetScope
        await reloadAssets()

        if !assets.contains(where: { $0.id == assetID }) {
            criteria.searchQuery = ""
            criteria.clearVisualFilters()
            criteria.tags.removeAll()
            semanticSearchReport = nil
            semanticSearchEnabled = false
            await reloadAssets()
        }

        if !assets.contains(where: { $0.id == assetID }), targetScope != .allItems {
            scope = .allItems
            label = "全部素材"
            await reloadAssets()
        }

        selectedAssetID = assetID
        pendingRevealAssetID = assetID
        highlightedAssetID = assetID
        highlightDismissTask?.cancel()
        highlightDismissTask = Task {
            try? await Task.sleep(for: .milliseconds(2600))
            guard !Task.isCancelled else { return }
            withAnimation(MobileMotion.exitSm) {
                if self.highlightedAssetID == assetID {
                    self.highlightedAssetID = nil
                }
            }
        }
        return RevealResult(asset: asset, scope: scope, locationLabel: label)
    }

    // MARK: - Moodboards (1:1 Bidirectional /.charkle/boards/ Sync)

    func fetchBoardDocument(id: UUID) async -> MoodboardDocument? {
        try? await engine.fetchBoard(id: id)
    }

    func fetchAssetsByID(_ ids: [UUID]) async -> [UUID: AssetRecord] {
        var result: [UUID: AssetRecord] = [:]
        let localMap = Dictionary(uniqueKeysWithValues: assets.map { ($0.id, $0) })
        for id in ids {
            if let hit = localMap[id] {
                result[id] = hit
            } else if let fetched = try? await engine.fetchAsset(id: id) {
                result[id] = fetched
            }
        }
        return result
    }

    func createMoodboard(
        title: String,
        subtitle: String = "",
        seedAssetIDs: [UUID] = [],
        useFreeform: Bool = true
    ) async -> MoodboardDocument? {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        let finalTitle = trimmed.isEmpty ? "新建情绪板" : trimmed

        do {
            let doc: MoodboardDocument
            if !seedAssetIDs.isEmpty {
                let assetMap = await fetchAssetsByID(seedAssetIDs)
                var nodes: [BoardNode] = []
                var cursorX: Double = 40
                var cursorY: Double = 40
                var rowMaxH: Double = 0
                for (index, id) in seedAssetIDs.enumerated() {
                    let ratio = max(0.55, min(1.9, assetMap[id]?.aspectRatio ?? 1.2))
                    let w: Double = 260
                    let h: Double = w / ratio
                    if cursorX + w > 960 && index > 0 {
                        cursorX = 40
                        cursorY += rowMaxH + 24
                        rowMaxH = 0
                    }
                    nodes.append(BoardNode(
                        kind: .assetRef(assetID: id, crop: nil, weight: index == 0 ? 2 : 1, autoplayLoop: true),
                        frame: BoardRect(x: cursorX, y: cursorY, width: w, height: h),
                        zIndex: index,
                        editorialOrder: index
                    ))
                    cursorX += w + 24
                    rowMaxH = max(rowMaxH, h)
                }
                let palette = (try? await engine.extractBoardPalette(assetIDs: seedAssetIDs, count: 6)) ?? []
                doc = MoodboardDocument(
                    title: finalTitle,
                    subtitle: subtitle,
                    mode: useFreeform ? .freeform : .autoEditorial(AutoLayoutConfig()),
                    nodes: nodes,
                    extractedPalette: palette
                )
            } else {
                doc = MoodboardDocument(
                    title: finalTitle,
                    subtitle: subtitle,
                    mode: useFreeform ? .freeform : .autoEditorial(AutoLayoutConfig())
                )
            }
            let saved = try await engine.saveBoard(doc)
            await reloadAll()
            MobileHaptics.success()
            showToast("已创建情绪板「\(saved.title)」", tone: .success)
            if isGoogleDriveConnected {
                Task { await self.syncNow(quiet: true) }
            }
            return saved
        } catch {
            showToast("创建情绪板失败：\(error.localizedDescription)", tone: .error)
            return nil
        }
    }

    func proposeMoodboard(prompt: String, seedAssetIDs: [UUID] = []) async -> MoodboardDocument? {
        let trimmed = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        do {
            let seed: MoodboardSeed
            if !seedAssetIDs.isEmpty && !trimmed.isEmpty {
                seed = .combined(prompt: trimmed, seedAssetIDs: seedAssetIDs, palette: [])
            } else if !seedAssetIDs.isEmpty {
                seed = .seedAssets(seedAssetIDs)
            } else {
                seed = .prompt(trimmed.isEmpty ? "精选视觉灵感" : trimmed)
            }
            let proposal = try await engine.proposeMoodboard(seed: seed, primaryCount: 10, candidateCount: 18)
            var draft = proposal.draftDocument
            if !trimmed.isEmpty {
                draft.title = trimmed
            }
            let saved = try await engine.saveBoard(draft)
            await reloadAll()
            MobileHaptics.success()
            showToast("已智能生成情绪板「\(saved.title)」", tone: .success)
            if isGoogleDriveConnected {
                Task { await self.syncNow(quiet: true) }
            }
            return saved
        } catch {
            showToast("生成情绪板失败：\(error.localizedDescription)", tone: .error)
            return nil
        }
    }

    @discardableResult
    func saveBoardDocument(_ document: MoodboardDocument, quiet: Bool = true) async -> MoodboardDocument? {
        do {
            var next = document
            let ids = next.referencedAssetIDs
            if !ids.isEmpty, let palette = try? await engine.extractBoardPalette(assetIDs: ids, count: 6) {
                next.extractedPalette = palette
            }
            next.updatedAt = Date()
            let saved = try await engine.saveBoard(next)
            boards = (try? await engine.fetchBoards()) ?? boards
            if !quiet {
                showToast("情绪板已保存", tone: .success)
            }
            if isGoogleDriveConnected {
                Task { await self.syncNow(quiet: true) }
            }
            return saved
        } catch {
            showToast("保存情绪板失败：\(error.localizedDescription)", tone: .error)
            return nil
        }
    }

    func deleteBoard(id: UUID) async {
        do {
            try await engine.deleteBoard(id: id)
            if case .moodboard(let current) = scope, current == id {
                scope = .moodboardsHome
            }
            await reloadAll()
            MobileHaptics.warning()
            showToast("已删除情绪板", tone: .info)
            if isGoogleDriveConnected {
                Task { await self.syncNow(quiet: true) }
            }
        } catch {
            showToast("删除情绪板失败：\(error.localizedDescription)", tone: .error)
        }
    }

    func setBoardPinnedOffline(id: UUID, pinned: Bool) async {
        do {
            try await engine.setBoardPinnedOffline(id: id, pinned: pinned)
            await reloadAll()
            MobileHaptics.light()
            showToast(pinned ? "已将情绪板置顶离线" : "已取消情绪板离线置顶", tone: .success)
        } catch {
            showToast("更新离线状态失败：\(error.localizedDescription)", tone: .error)
        }
    }

    func addAssets(_ assetIDs: [UUID], toBoard boardID: UUID) async {
        guard !assetIDs.isEmpty else { return }
        guard var doc = try? await engine.fetchBoard(id: boardID) else {
            showToast("未找到目标情绪板", tone: .error)
            return
        }
        let existingIDs = Set(doc.referencedAssetIDs)
        let toAdd = assetIDs.filter { !existingIDs.contains($0) }
        guard !toAdd.isEmpty else {
            showToast("所选素材已在该情绪板中", tone: .info)
            return
        }

        let assetMap = await fetchAssetsByID(toAdd)
        let maxY = doc.nodes.map(\.frame.maxY).max() ?? 16
        let startZ = (doc.nodes.map(\.zIndex).max() ?? -1) + 1
        let startOrder = (doc.nodes.map(\.editorialOrder).max() ?? -1) + 1

        var cursorX: Double = 40
        var cursorY: Double = doc.nodes.isEmpty ? 40 : (maxY + 28)
        var rowMaxH: Double = 0

        for (idx, assetID) in toAdd.enumerated() {
            let ratio = max(0.55, min(1.9, assetMap[assetID]?.aspectRatio ?? 1.2))
            let w: Double = 260
            let h: Double = w / ratio
            if cursorX + w > 960 && idx > 0 {
                cursorX = 40
                cursorY += rowMaxH + 24
                rowMaxH = 0
            }
            doc.nodes.append(BoardNode(
                kind: .assetRef(assetID: assetID, crop: nil, weight: 1, autoplayLoop: true),
                frame: BoardRect(x: cursorX, y: cursorY, width: w, height: h),
                zIndex: startZ + idx,
                editorialOrder: startOrder + idx
            ))
            cursorX += w + 24
            rowMaxH = max(rowMaxH, h)
        }

        _ = await saveBoardDocument(doc, quiet: true)
        MobileHaptics.success()
        showToast("已加入情绪板「\(doc.title)」(\(toAdd.count) 项)", tone: .success)
    }

    func exportBoardPNGURL(document: MoodboardDocument, darkAppearance: Bool) async -> URL? {
        let ids = document.referencedAssetIDs
        let assetsByID = await fetchAssetsByID(ids)
        let engine = self.engine
        var thumbMap: [UUID: URL] = [:]
        for id in ids {
            if let preview = await engine.thumbnailURL(for: id, tier: .preview1400)
                ?? engine.cachedThumbnailURL(for: id, tier: .grid520) {
                thumbMap[id] = preview
            }
        }
        let options = BoardImageRenderer.RenderOptions(
            canvasWidth: 1680,
            padding: 44,
            darkAppearance: darkAppearance
        )
        guard let pngData = BoardImageRenderer.renderPNG(
            document: document,
            assetsByID: assetsByID,
            thumbnailURL: { thumbMap[$0] },
            options: options
        ) else {
            showToast("导出情绪板图片失败", tone: .error)
            return nil
        }
        let safeTitle = document.title
            .replacingOccurrences(of: "/", with: "-")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let fileName = (safeTitle.isEmpty ? "Charkle-Moodboard" : safeTitle) + ".png"
        let outURL = FileManager.default.temporaryDirectory.appending(path: fileName)
        do {
            try pngData.write(to: outURL, options: .atomic)
            return outURL
        } catch {
            showToast("写入导出文件失败：\(error.localizedDescription)", tone: .error)
            return nil
        }
    }

    // MARK: - Google Drive Bidirectional Sync

    func loadSyncAndStorageState() async {
        syncConfig = await engine.syncConfig()
        syncStatus = await engine.syncStatus()
        iCloudAvailability = await engine.probeICloudDriveAvailability()
        hasGoogleOAuthClient = await engine.hasGoogleOAuthClientConfig()
        hasWebDAVPassword = await engine.hasWebDAVPassword()
        cacheStats = await engine.cacheStats()
    }

    func refreshSyncStatus() async {
        syncStatus = await engine.syncStatus()
        hasGoogleOAuthClient = await engine.hasGoogleOAuthClientConfig()
    }

    func saveGoogleOAuthClientID(_ rawClientID: String) async {
        let trimmed = rawClientID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            showToast("请输入有效的 Google iOS OAuth Client ID", tone: .warning)
            return
        }
        do {
            try await engine.saveGoogleOAuthClientConfig(clientID: trimmed, clientSecret: "")
            hasGoogleOAuthClient = await engine.hasGoogleOAuthClientConfig()
            MobileHaptics.success()
            showToast("已保存 Google OAuth Client ID", tone: .success)
        } catch {
            showToast("保存失败：\(error.localizedDescription)", tone: .error)
        }
    }

    func importGoogleOAuthCredentialFile(from url: URL) async {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        do {
            let data = try Data(contentsOf: url)
            try await engine.importGoogleOAuthData(data)
            hasGoogleOAuthClient = await engine.hasGoogleOAuthClientConfig()
            MobileHaptics.success()
            showToast("已导入 Google OAuth 凭据", tone: .success)
        } catch {
            showToast("导入凭据失败：\(error.localizedDescription)", tone: .error)
        }
    }

    func signInGoogleDrive() async {
        guard !isSigningInGoogle else { return }
        isSigningInGoogle = true
        defer { isSigningInGoogle = false }

        do {
            let presenter = self.authPresenter
            let account = try await engine.signInGoogleDrive { authURL, callbackScheme in
                try await presenter.present(authURL: authURL, callbackScheme: callbackScheme)
            }
            await loadSyncAndStorageState()
            MobileHaptics.success()
            showToast("已连接 Google Drive（\(account.email)）", tone: .success)
            await syncNow(quiet: false)
        } catch {
            MobileHaptics.error()
            showToast(error.localizedDescription, tone: .error)
        }
    }

    func signOutGoogleDrive() async {
        do {
            try await engine.signOutGoogleDrive()
            sharedFolders = []
            await loadSyncAndStorageState()
            showToast("已断开 Google Drive 登录", tone: .info)
        } catch {
            showToast("退出登录失败：\(error.localizedDescription)", tone: .error)
        }
    }

    func saveSyncConfiguration(_ config: DriveSyncConfig, webDAVPassword: String? = nil) async {
        do {
            if let webDAVPassword, !webDAVPassword.isEmpty {
                try await engine.saveWebDAVPassword(webDAVPassword)
            }
            try await engine.saveSyncConfig(config)
            await loadSyncAndStorageState()
            MobileHaptics.success()
            showToast("同步设置已保存", tone: .success)
        } catch {
            showToast("保存同步设置失败：\(error.localizedDescription)", tone: .error)
        }
    }

    // MARK: - Simultaneous Multi-Backend & iCloud Drive Management

    @discardableResult
    func upsertBackend(
        _ profile: SyncBackendProfile,
        webDAVPassword: String? = nil,
        iCloudBookmarkData: Data? = nil
    ) async -> Bool {
        do {
            var next = syncConfig
            var list = next.resolvedBackends
            if let idx = list.firstIndex(where: { $0.id == profile.id }) {
                list[idx] = profile
            } else {
                var added = profile
                if list.isEmpty || (list.count == 1 && list[0].mode == .localOnly && profile.mode.isCloudBacked) {
                    added.isPrimary = true
                    for i in list.indices { list[i].isPrimary = false }
                }
                list.append(added)
            }
            next.backends = list
            next.synchronizePrimaryFields()
            if profile.mode == .webDAV, let webDAVPassword, !webDAVPassword.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                try await engine.saveBackendWebDAVPassword(webDAVPassword, for: profile.id)
            }
            if profile.mode == .iCloudDrive, let iCloudBookmarkData {
                try await engine.saveICloudBookmark(iCloudBookmarkData, displayPath: profile.iCloudCustomFolderPath, for: profile.id)
            }
            try await engine.saveSyncConfig(next)
            await loadSyncAndStorageState()
            MobileHaptics.success()
            showToast("已保存同步后端「\(profile.name)」", tone: .success)
            return true
        } catch {
            MobileHaptics.error()
            showToast("保存后端失败：\(error.localizedDescription)", tone: .error)
            return false
        }
    }

    func removeBackend(id: UUID) async {
        var next = syncConfig
        var list = next.resolvedBackends
        guard list.count > 1 else {
            showToast("至少需要保留一个存储后端", tone: .warning)
            return
        }
        list.removeAll { $0.id == id }
        next.backends = list
        next.synchronizePrimaryFields()
        await saveSyncConfiguration(next)
    }

    func setBackendEnabled(id: UUID, enabled: Bool) async {
        var next = syncConfig
        var list = next.resolvedBackends
        guard let idx = list.firstIndex(where: { $0.id == id }) else { return }
        list[idx].isEnabled = enabled
        next.backends = list
        next.synchronizePrimaryFields()
        do {
            try await engine.saveSyncConfig(next)
            await loadSyncAndStorageState()
        } catch {
            showToast("更新后端状态失败：\(error.localizedDescription)", tone: .error)
        }
    }

    func setPrimaryBackend(id: UUID) async {
        var next = syncConfig
        var list = next.resolvedBackends
        guard list.contains(where: { $0.id == id }) else { return }
        for idx in list.indices {
            list[idx].isPrimary = (list[idx].id == id)
            if list[idx].id == id { list[idx].isEnabled = true }
        }
        next.backends = list
        next.synchronizePrimaryFields()
        await saveSyncConfiguration(next)
    }

    func assignGoogleSharedFolder(_ folderID: String) async {
        var next = syncConfig
        var list = next.resolvedBackends
        if let idx = list.firstIndex(where: { $0.mode == .directAPIWithGDirect || $0.mode == .gdirectMount }) {
            list[idx].sharedFolderURLOrID = folderID
            next.backends = list
            next.synchronizePrimaryFields()
            await saveSyncConfiguration(next)
        }
    }

    @discardableResult
    func testBackendConnection(_ profile: SyncBackendProfile, webDAVPassword: String? = nil) async -> Bool {
        do {
            let info = try await engine.testBackendConnection(profile, webDAVPassword: webDAVPassword)
            MobileHaptics.success()
            showToast("连接正常：\(info.email)", tone: .success)
            return true
        } catch {
            MobileHaptics.error()
            showToast("连接失败：\(error.localizedDescription)", tone: .error)
            return false
        }
    }

    func syncBackend(id: UUID) async {
        guard !isSyncing else { return }
        isSyncing = true
        defer { isSyncing = false }
        do {
            let report = try await engine.syncBackend(id: id)
            lastSyncReport = report
            await loadSyncAndStorageState()
            if report.hasVisibleLibraryChanges {
                thumbnails.invalidate(assetIDs: report.discoveredAssetIDs)
                await reloadAll()
            }
            MobileHaptics.success()
            showToast("后端同步完成 · ↑ \(report.uploadedOps) / ↓ \(report.downloadedOps)", tone: .success)
        } catch {
            await refreshSyncStatus()
            MobileHaptics.error()
            showToast("同步失败：\(error.localizedDescription)", tone: .error)
        }
    }

    func loadSharedDriveFolders() async {
        guard !isLoadingSharedFolders else { return }
        isLoadingSharedFolders = true
        defer { isLoadingSharedFolders = false }
        do {
            sharedFolders = try await engine.listGoogleDriveSharedFolders()
        } catch {
            showToast("读取共享目录失败：\(error.localizedDescription)", tone: .error)
        }
    }

    func syncNow(quiet: Bool = false) async {
        guard !isSyncing else { return }
        isSyncing = true
        defer { isSyncing = false }

        do {
            let report = try await engine.syncNow()
            lastSyncReport = report
            await loadSyncAndStorageState()
            if report.hasVisibleLibraryChanges {
                thumbnails.invalidate(assetIDs: report.discoveredAssetIDs)
                await reloadAll()
            }
            if !quiet {
                MobileHaptics.success()
                let summary: String
                if report.discoveredRemoteAssets > 0 || report.uploadedOps > 0 || report.downloadedOps > 0 {
                    summary = "同步完成 · 拉取 \(report.discoveredRemoteAssets) 项，变更 \(report.uploadedOps + report.downloadedOps) 条"
                } else {
                    summary = "已是最新状态"
                }
                showToast(summary, tone: .success)
            }
        } catch {
            await refreshSyncStatus()
            if !quiet {
                MobileHaptics.error()
                showToast("同步失败：\(error.localizedDescription)", tone: .error)
            }
        }
    }

    func updateCacheBudget(gigabytes: Double) async {
        let bytes = Int64(max(0.5, gigabytes) * 1_073_741_824.0)
        await engine.setCacheBudgetBytes(bytes)
        cacheStats = await engine.cacheStats()
    }

    func evictCacheNow() async {
        do {
            cacheStats = try await engine.evictCacheNow()
            thumbnails.invalidate(assetIDs: [])
            MobileHaptics.success()
            showToast("已清理可回收缓存（保留已离线置顶原图）", tone: .success)
        } catch {
            showToast("清理缓存失败：\(error.localizedDescription)", tone: .error)
        }
    }

    // MARK: - Toast

    func showToast(
        _ message: String,
        tone: MobileToast.Tone = .info,
        actionTitle: String? = nil,
        onAction: (() -> Void)? = nil
    ) {
        toastDismissTask?.cancel()
        withAnimation(MobileMotion.enterSm) {
            toast = MobileToast(message: message, tone: tone, actionTitle: actionTitle, onAction: onAction)
        }
        let durationSeconds: Double = actionTitle != nil ? 4.5 : 3.0
        toastDismissTask = Task {
            try? await Task.sleep(for: .seconds(durationSeconds))
            guard !Task.isCancelled else { return }
            withAnimation(MobileMotion.exitSm) {
                toast = nil
            }
        }
    }

    // MARK: - Notifications

    private func registerNotifications() {
        let center = NotificationCenter.default

        syncStatusObserver = center.addObserver(
            forName: CharkleSyncNotifications.didUpdateSyncStatus,
            object: nil,
            queue: .main
        ) { [weak self] note in
            guard let data = note.userInfo?[CharkleSyncNotifications.statusDataKey] as? Data else { return }
            MainActor.assumeIsolated {
                guard let self,
                      let decoded = try? Self.syncDecoder.decode(SyncStatus.self, from: data) else { return }
                if self.syncStatus != decoded {
                    self.syncStatus = decoded
                }
            }
        }

        progressiveSyncObserver = center.addObserver(
            forName: CharkleSyncNotifications.didSyncProgressively,
            object: nil,
            queue: .main
        ) { [weak self] note in
            let ids = (note.userInfo?[CharkleSyncNotifications.thumbnailAssetIDsKey] as? [String] ?? [])
                .compactMap(UUID.init(uuidString:))
            MainActor.assumeIsolated {
                guard let self else { return }
                if !ids.isEmpty {
                    self.thumbnails.invalidate(assetIDs: ids)
                }
                self.scheduleProgressiveReload()
            }
        }

        completeSyncObserver = center.addObserver(
            forName: CharkleSyncNotifications.didCompleteSync,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.scheduleProgressiveReload()
            }
        }

        enrichObserver = center.addObserver(
            forName: CharkleCoreNotifications.libraryDidEnrichInBackground,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.scheduleProgressiveReload()
            }
        }
    }

    private func scheduleProgressiveReload() {
        progressiveRefreshTask?.cancel()
        progressiveRefreshTask = Task {
            try? await Task.sleep(for: .milliseconds(350))
            guard !Task.isCancelled else { return }
            await reloadAll()
        }
    }
}
