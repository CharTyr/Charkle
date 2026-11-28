import CharkleCore
import Foundation
import SwiftUI
import UIKit

enum MobileScope: Hashable, Sendable {
    case allItems
    case inbox
    case moodboardsHome
    case moodboard(UUID)
    case pinterest
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
    let pinterestController = PinterestExploreController()
    private let authPresenter = GoogleAuthPresenter()

    // MARK: - Navigation & Library State
    var scope: MobileScope = .allItems
    var assets: [AssetRecord] = [] {
        didSet { assetsMutationVersion &+= 1 }
    }
    var inboxAssets: [AssetRecord] = [] {
        didSet { assetsMutationVersion &+= 1 }
    }
    private(set) var unfoldedAssets: [AssetRecord] = []
    private(set) var unfoldedInboxAssets: [AssetRecord] = []
    private(set) var stackMembersByGroupID: [UUID: [AssetRecord]] = [:]
    var pendingStackPrompts: [MobilePendingStackPrompt] = []
    var defaultGalleryLayoutMode: GalleryLayoutMode = .verticalMasonry
    var scopeLayoutOverrides: [String: GalleryLayoutMode] = [:]
    var compactBentoColumnOverride: Int? = nil
    var folders: [FolderRecord] = [] {
        didSet { rebuildFolderCaches() }
    }
    var smartFolders: [SmartFolderRecord] = []
    var boards: [MoodboardSummary] = []
    var tagCounts: [TagCount] = []
    var inboxCount: Int = 0
    var isLoadingLibrary: Bool = false
    var isReloadingAssets: Bool = false
    var hasCompletedInitialLoad: Bool = false
    var hasBootstrapped: Bool = false

    @ObservationIgnored
    var assetsMutationVersion: UInt64 = 0
    @ObservationIgnored
    private var cachedFolderTree: [FolderHierarchyNode] = []
    @ObservationIgnored
    private var cachedFlattenedFolders: [FolderHierarchyNode] = []
    @ObservationIgnored
    private var reloadAssetsGeneration: UInt64 = 0
    @ObservationIgnored
    private var lastHandledPasteboardEnvelopeID: UUID? = nil
    @ObservationIgnored
    private var dismissedStackPromptAssetIDs: Set<UUID> = []

    private static let defaultLayoutDefaultsKey = "com.charkle.mobile.defaultGalleryLayoutMode"
    private static let scopeLayoutDefaultsKey = "com.charkle.mobile.scopeGalleryLayoutOverrides"
    private static let compactColsDefaultsKey = "com.charkle.mobile.compactBentoColumnOverride"

    // MARK: - Search & Filter State
    var criteria: FilterCriteria = FilterCriteria(includeSubfolders: true)
    var searchDebounceTask: Task<Void, Never>?
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
    private var semanticEnhancementDelayTask: Task<Void, Never>?
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
    var isExtractingSocialMedia: Bool = false
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
        let defaults = UserDefaults.standard
        if let rawDefault = defaults.string(forKey: Self.defaultLayoutDefaultsKey),
           let parsed = GalleryLayoutMode(rawValue: rawDefault) {
            self.defaultGalleryLayoutMode = Self.normalizedMobileLayout(parsed)
        }
        if let rawDict = defaults.dictionary(forKey: Self.scopeLayoutDefaultsKey) as? [String: String] {
            var restored: [String: GalleryLayoutMode] = [:]
            for (k, v) in rawDict {
                if let parsed = GalleryLayoutMode(rawValue: v) {
                    restored[k] = Self.normalizedMobileLayout(parsed)
                }
            }
            self.scopeLayoutOverrides = restored
        }
        let savedCols = defaults.integer(forKey: Self.compactColsDefaultsKey)
        if savedCols == 1 || savedCols == 2 {
            self.compactBentoColumnOverride = savedCols
        }
        registerNotifications()
    }

    deinit {
        for observer in [syncStatusObserver, progressiveSyncObserver, completeSyncObserver, enrichObserver].compactMap({ $0 }) {
            NotificationCenter.default.removeObserver(observer)
        }
    }

    // MARK: - Derived Helpers

    var folderTree: [FolderHierarchyNode] {
        _ = folders
        return cachedFolderTree
    }

    var flattenedFolders: [FolderHierarchyNode] {
        _ = folders
        return cachedFlattenedFolders
    }

    private func rebuildFolderCaches() {
        let tree = FolderHierarchyNode.buildTree(from: folders)
        cachedFolderTree = tree
        var flat: [FolderHierarchyNode] = []
        flat.reserveCapacity(folders.count)
        func append(_ nodes: [FolderHierarchyNode]) {
            for node in nodes {
                flat.append(node)
                if !node.children.isEmpty {
                    append(node.children)
                }
            }
        }
        append(tree)
        cachedFlattenedFolders = flat
    }

    /// Instant live asset lookup across current library scope, Inbox, and all folded Version Stack siblings
    /// so Quick Look, Document Diff, and Inspector never display stale snapshots.
    func liveAsset(id: UUID) -> AssetRecord? {
        if let hit = assets.first(where: { $0.id == id }) {
            return hit
        }
        if let hit = unfoldedAssets.first(where: { $0.id == id }) {
            return hit
        }
        if let hit = inboxAssets.first(where: { $0.id == id }) {
            return hit
        }
        if let hit = unfoldedInboxAssets.first(where: { $0.id == id }) {
            return hit
        }
        for members in stackMembersByGroupID.values {
            if let hit = members.first(where: { $0.id == id }) {
                return hit
            }
        }
        return nil
    }

    func applyHydratedAsset(_ updated: AssetRecord) {
        var touchedUnfolded = false
        if let idx = unfoldedAssets.firstIndex(where: { $0.id == updated.id }) {
            unfoldedAssets[idx] = updated
            touchedUnfolded = true
        }
        if let idx = unfoldedInboxAssets.firstIndex(where: { $0.id == updated.id }) {
            unfoldedInboxAssets[idx] = updated
            touchedUnfolded = true
        }
        if let gid = updated.richMetadata?.versionStack?.groupID,
           var members = stackMembersByGroupID[gid],
           let mIdx = members.firstIndex(where: { $0.id == updated.id }) {
            members[mIdx] = updated
            stackMembersByGroupID[gid] = AssetVersionStackMetadata.sortedVersions(members)
        }
        if touchedUnfolded {
            recomputeFoldedLists()
        } else {
            if let idx = assets.firstIndex(where: { $0.id == updated.id }) {
                assets[idx] = updated
            }
            if let idx = inboxAssets.firstIndex(where: { $0.id == updated.id }) {
                inboxAssets[idx] = updated
            }
        }
    }

    // MARK: - Per-Destination Gallery Layout Memory & Version Stack Helpers

    static func normalizedMobileLayout(_ mode: GalleryLayoutMode) -> GalleryLayoutMode {
        mode == .compactList ? .compactList : .verticalMasonry
    }

    func scopeLayoutStorageKey(for targetScope: MobileScope) -> String? {
        switch targetScope {
        case .allItems: "allItems"
        case .inbox: "inbox"
        case .recent: "recent"
        case .untagged: "untagged"
        case .trash: "trash"
        case .folder(let id): "folder:\(id.uuidString)"
        case .smartFolder(let id): "smartFolder:\(id.uuidString)"
        case .tag(let tag): "tag:\(tag.lowercased())"
        case .moodboardsHome, .moodboard, .pinterest: nil
        }
    }

    var activeGalleryLayoutMode: GalleryLayoutMode {
        if let key = scopeLayoutStorageKey(for: scope),
           let override = scopeLayoutOverrides[key] {
            return Self.normalizedMobileLayout(override)
        }
        return Self.normalizedMobileLayout(defaultGalleryLayoutMode)
    }

    var hasScopeSpecificLayoutOverride: Bool {
        guard let key = scopeLayoutStorageKey(for: scope) else { return false }
        return scopeLayoutOverrides[key] != nil
    }

    func setGalleryLayoutMode(_ mode: GalleryLayoutMode, rememberForCurrentScope: Bool = true) {
        let normalized = Self.normalizedMobileLayout(mode)
        if rememberForCurrentScope, let key = scopeLayoutStorageKey(for: scope) {
            scopeLayoutOverrides[key] = normalized
            persistScopeLayoutOverrides()
        } else {
            defaultGalleryLayoutMode = normalized
            UserDefaults.standard.set(normalized.rawValue, forKey: Self.defaultLayoutDefaultsKey)
        }
    }

    func setDefaultGalleryLayoutMode(_ mode: GalleryLayoutMode) {
        let normalized = Self.normalizedMobileLayout(mode)
        defaultGalleryLayoutMode = normalized
        UserDefaults.standard.set(normalized.rawValue, forKey: Self.defaultLayoutDefaultsKey)
    }

    func resetPerFolderLayoutMemory() {
        scopeLayoutOverrides.removeAll()
        UserDefaults.standard.removeObject(forKey: Self.scopeLayoutDefaultsKey)
        MobileHaptics.light()
        showToast("已重置各文件夹的独立视图记忆", tone: .info)
    }

    func setCompactBentoColumnOverride(_ cols: Int?) {
        let valid = (cols == 1 || cols == 2) ? cols : nil
        compactBentoColumnOverride = valid
        if let valid {
            UserDefaults.standard.set(valid, forKey: Self.compactColsDefaultsKey)
        } else {
            UserDefaults.standard.removeObject(forKey: Self.compactColsDefaultsKey)
        }
    }

    private func persistScopeLayoutOverrides() {
        let raw = scopeLayoutOverrides.mapValues(\.rawValue)
        UserDefaults.standard.set(raw, forKey: Self.scopeLayoutDefaultsKey)
    }

    /// Collapses assets sharing `richMetadata.versionStack.groupID` into a single displayed representative
    /// (`AssetVersionStackMetadata.resolvePrimaryAsset`, preferring `isPinnedPrimary`), preserving list sort order.
    static func foldVersionStacks(_ raw: [AssetRecord]) -> (folded: [AssetRecord], groups: [UUID: [AssetRecord]]) {
        guard !raw.isEmpty else { return ([], [:]) }
        var membersByGroup: [UUID: [AssetRecord]] = [:]
        for item in raw {
            if let gid = item.richMetadata?.versionStack?.groupID {
                membersByGroup[gid, default: []].append(item)
            }
        }
        guard !membersByGroup.isEmpty else { return (raw, [:]) }

        var sortedGroups: [UUID: [AssetRecord]] = [:]
        var representativeByGroup: [UUID: AssetRecord] = [:]
        for (gid, list) in membersByGroup {
            let sorted = AssetVersionStackMetadata.sortedVersions(list)
            sortedGroups[gid] = sorted
            if let primary = AssetVersionStackMetadata.resolvePrimaryAsset(in: sorted) {
                representativeByGroup[gid] = primary
            }
        }

        var emittedGroups = Set<UUID>()
        var folded: [AssetRecord] = []
        folded.reserveCapacity(raw.count)
        for item in raw {
            if let gid = item.richMetadata?.versionStack?.groupID {
                if emittedGroups.insert(gid).inserted, let rep = representativeByGroup[gid] {
                    folded.append(rep)
                }
            } else {
                folded.append(item)
            }
        }
        return (folded, sortedGroups)
    }

    private func folderSubtreeIDSet(rootID: UUID) -> Set<UUID> {
        var byParent: [UUID: [UUID]] = [:]
        for folder in folders {
            if let pid = folder.parentID {
                byParent[pid, default: []].append(folder.id)
            }
        }
        var seen: Set<UUID> = [rootID]
        var queue: [UUID] = [rootID]
        while let current = queue.popLast() {
            for child in byParent[current] ?? [] where seen.insert(child).inserted {
                queue.append(child)
            }
        }
        return seen
    }

    private func isCompatibleWithActiveScope(_ candidate: AssetRecord) -> Bool {
        switch scope {
        case .trash:
            return candidate.isTrashed
        case .inbox:
            return !candidate.isTrashed && candidate.folderID == nil
        case .folder(let rootID):
            guard !candidate.isTrashed, let fid = candidate.folderID else { return false }
            return folderSubtreeIDSet(rootID: rootID).contains(fid)
        case .untagged:
            return !candidate.isTrashed && candidate.tags.allSatisfy(\.isEmpty)
        case .smartFolder(let smartID):
            guard !candidate.isTrashed,
                  let smart = smartFolders.first(where: { $0.id == smartID }) else { return false }
            return smart.rule.matches(candidate)
        case .allItems, .recent, .tag, .moodboardsHome, .moodboard, .pinterest:
            return !candidate.isTrashed
        }
    }

    private func applyUnfoldedAssets(_ raw: [AssetRecord], mergeIntoStackLookup: Bool = true) {
        unfoldedAssets = raw
        let (folded, groups) = Self.foldVersionStacks(raw)
        if mergeIntoStackLookup {
            for (gid, members) in groups {
                if let existing = stackMembersByGroupID[gid], existing.count > members.count {
                    var combinedByID = Dictionary(uniqueKeysWithValues: existing.map { ($0.id, $0) })
                    for m in members { combinedByID[m.id] = m }
                    let merged = AssetVersionStackMetadata.sortedVersions(Array(combinedByID.values.filter { !$0.isTrashed || scope == .trash }))
                    stackMembersByGroupID[gid] = merged
                } else {
                    stackMembersByGroupID[gid] = members
                }
            }
        }
        // Substitute global stack primary ONLY when compatible with active scope; otherwise preserve `item`
        // (resolved via `AssetVersionStackMetadata.resolvePrimaryAsset(in: inListGroupMembers)`).
        let resolvedFolded: [AssetRecord] = folded.map { item in
            guard !item.isTrashed,
                  let gid = item.richMetadata?.versionStack?.groupID,
                  let fullMembers = stackMembersByGroupID[gid],
                  let primary = AssetVersionStackMetadata.resolvePrimaryAsset(in: fullMembers),
                  isCompatibleWithActiveScope(primary) else {
                return item
            }
            return primary
        }
        if assets != resolvedFolded {
            assets = resolvedFolded
        }
    }

    private func applyUnfoldedInboxAssets(_ raw: [AssetRecord]) {
        unfoldedInboxAssets = raw
        let (folded, groups) = Self.foldVersionStacks(raw)
        for (gid, members) in groups {
            if let existing = stackMembersByGroupID[gid] {
                var combinedByID = Dictionary(uniqueKeysWithValues: existing.map { ($0.id, $0) })
                for m in members { combinedByID[m.id] = m }
                stackMembersByGroupID[gid] = AssetVersionStackMetadata.sortedVersions(
                    Array(combinedByID.values.filter { !$0.isTrashed })
                )
            } else {
                stackMembersByGroupID[gid] = members
            }
        }
        if inboxAssets != folded {
            inboxAssets = folded
        }
    }

    private func recomputeFoldedLists() {
        applyUnfoldedInboxAssets(unfoldedInboxAssets)
        applyUnfoldedAssets(unfoldedAssets)
    }

    func stackMembers(for asset: AssetRecord) -> [AssetRecord] {
        guard let gid = asset.richMetadata?.versionStack?.groupID else {
            return [asset]
        }
        if let members = stackMembersByGroupID[gid], !members.isEmpty {
            if members.contains(where: { $0.id == asset.id }) {
                return members
            }
            return AssetVersionStackMetadata.sortedVersions(members + [asset])
        }
        return [asset]
    }

    func stackMembers(groupID: UUID) -> [AssetRecord] {
        stackMembersByGroupID[groupID] ?? []
    }

    func primaryVersionAsset(for asset: AssetRecord) -> AssetRecord {
        let members = stackMembers(for: asset)
        return AssetVersionStackMetadata.resolvePrimaryAsset(in: members) ?? asset
    }

    func newerThanPrimaryCount(for asset: AssetRecord) -> Int {
        AssetVersionStackMetadata.newerThanPrimaryCount(in: stackMembers(for: asset))
    }

    /// Anti-Mis-Send Guarantee: resolves the canonical `isPinnedPrimary` version's original file URL
    /// (with clean human-readable `fileName` staging so sharing to WeChat iOS never sends an unreviewed draft
    /// or an opaque hash filename). Pass `preferExactAsset: true` ONLY when explicitly exporting a specific version.
    func shareableOriginalURL(for asset: AssetRecord, preferExactAsset: Bool = false) async -> URL? {
        let target = preferExactAsset ? asset : primaryVersionAsset(for: asset)
        let pendingNewer = preferExactAsset ? 0 : newerThanPrimaryCount(for: asset)

        let rawURL: URL?
        if let orig = try? await engine.originalURL(for: target.id) {
            rawURL = orig
        } else {
            rawURL = await engine.thumbnailURL(for: target.id, tier: .preview1400)
        }
        guard let sourceURL = rawURL else { return nil }

        let exportURL = Self.stageHumanReadableExportURL(sourceURL: sourceURL, desiredFileName: target.fileName) ?? sourceURL
        if pendingNewer > 0, let verTag = target.richMetadata?.versionStack?.displayVersionTag {
            showToast("已锁定发送主版本 \(verTag)（自动防误发未审草稿）", tone: .info)
        }
        return exportURL
    }

    nonisolated static func stageHumanReadableExportURL(sourceURL: URL, desiredFileName: String) -> URL? {
        let trimmed = desiredFileName
            .replacingOccurrences(of: "/", with: "-")
            .replacingOccurrences(of: ":", with: "-")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return sourceURL }
        let ext = sourceURL.pathExtension
        let finalName: String
        if (trimmed as NSString).pathExtension.isEmpty && !ext.isEmpty {
            finalName = "\(trimmed).\(ext)"
        } else {
            finalName = trimmed
        }
        if sourceURL.lastPathComponent == finalName {
            return sourceURL
        }
        let dir = FileManager.default.temporaryDirectory
            .appending(path: "CharkleShareExport", directoryHint: .isDirectory)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let dest = dir.appending(path: finalName, directoryHint: .notDirectory)
        try? FileManager.default.removeItem(at: dest)
        if (try? FileManager.default.linkItem(at: sourceURL, to: dest)) != nil {
            return dest
        }
        if (try? FileManager.default.copyItem(at: sourceURL, to: dest)) != nil {
            return dest
        }
        return sourceURL
    }

    var currentScopeTitle: String {
        switch scope {
        case .allItems: "全部素材"
        case .inbox: "收件箱"
        case .moodboardsHome: "情绪板"
        case .moodboard(let id): boards.first(where: { $0.id == id })?.title ?? "情绪板"
        case .pinterest: "Pinterest 空间"
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
        if url.isFileURL {
            if !hasBootstrapped {
                await bootstrap()
            }
            let scoped = url.startAccessingSecurityScopedResource()
            defer {
                if scoped { url.stopAccessingSecurityScopedResource() }
            }
            let tempDir = FileManager.default.temporaryDirectory
                .appending(path: "charkle-openin-\(UUID().uuidString)", directoryHint: .isDirectory)
            try? FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: tempDir) }

            let cleanName = url.lastPathComponent.isEmpty ? "导入文档.bin" : url.lastPathComponent
            let stagedURL = tempDir.appending(path: cleanName)
            if (try? FileManager.default.copyItem(at: url, to: stagedURL)) != nil {
                _ = await ingestInputs([.fileURL(stagedURL)], targetFolderID: activeFolderIDForCapture)
            } else if let data = try? Data(contentsOf: url),
                      (try? data.write(to: stagedURL, options: .atomic)) != nil {
                _ = await ingestInputs([.fileURL(stagedURL)], targetFolderID: activeFolderIDForCapture)
            } else {
                showToast("无法读取外部传入的文件", tone: .error)
            }
            return
        }

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
        // Inspect UTI metadata first without reading contents so resuming from other apps
        // never triggers a spurious iOS "Charkle would like to paste" permission banner.
        guard pb.contains(pasteboardTypes: [uti]),
              let rawData = pb.data(forPasteboardType: uti),
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

        var allImported: [AssetRecord] = []
        for entry in batchPayloads {
            let created = await ingestSingleSharePayload(
                entry.payload,
                stagedFilesDirectory: entry.dir,
                embeddedFiles: [:]
            )
            allImported.append(contentsOf: created)
            try? FileManager.default.removeItem(at: entry.fileURL)
            if let stagedName = entry.payload.stagedFileName {
                try? FileManager.default.removeItem(at: entry.dir.appending(path: stagedName))
            }
        }

        if !allImported.isEmpty {
            await reloadAll()
            await evaluateStackCandidates(for: allImported)
            MobileHaptics.success()
            showToast("已接收来自系统分享的 \(allImported.count) 项素材", tone: .success)
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

        var allImported: [AssetRecord] = []
        for payload in payloads {
            let created = await ingestSingleSharePayload(
                payload,
                stagedFilesDirectory: stagedFilesDirectory,
                embeddedFiles: embeddedFiles
            )
            allImported.append(contentsOf: created)
        }

        if !allImported.isEmpty {
            await reloadAll()
            await evaluateStackCandidates(for: allImported)
            MobileHaptics.success()
            showToast("已接收来自系统分享的 \(allImported.count) 项素材", tone: .success)
            if hasConnectedCloudBackend {
                Task { await self.syncNow(quiet: true) }
            }
        }
    }

    private func ingestSingleSharePayload(
        _ payload: PendingSharePayload,
        stagedFilesDirectory: URL?,
        embeddedFiles: [String: Data]
    ) async -> [AssetRecord] {
        var input: CaptureInput?
        var tempDirToCleanup: URL?
        defer {
            if let tempDirToCleanup {
                try? FileManager.default.removeItem(at: tempDirToCleanup)
            }
        }

        switch payload.kind {
        case .file:
            if let name = payload.stagedFileName {
                let desiredFileName: String = {
                    if let orig = payload.originalFileName?.trimmingCharacters(in: .whitespacesAndNewlines),
                       !orig.isEmpty {
                        return orig.replacingOccurrences(of: "/", with: "-")
                    }
                    return name
                }()
                let tempSubdir = FileManager.default.temporaryDirectory
                    .appending(path: "share-import-\(UUID().uuidString)", directoryHint: .isDirectory)
                try? FileManager.default.createDirectory(at: tempSubdir, withIntermediateDirectories: true)
                tempDirToCleanup = tempSubdir

                if let dir = stagedFilesDirectory {
                    let candidate = dir.appending(path: name)
                    if FileManager.default.fileExists(atPath: candidate.path) {
                        let namedCopy = tempSubdir.appending(path: desiredFileName)
                        if (try? FileManager.default.copyItem(at: candidate, to: namedCopy)) != nil {
                            input = .fileURL(namedCopy)
                        } else {
                            input = .fileURL(candidate)
                        }
                    }
                }
                if input == nil, let bytes = embeddedFiles[name] {
                    let namedTempURL = tempSubdir.appending(path: desiredFileName)
                    if (try? bytes.write(to: namedTempURL, options: .atomic)) != nil {
                        input = .fileURL(namedTempURL)
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

        guard let input else { return [] }
        do {
            var imported = try await engine.ingest([input], targetFolderID: payload.targetFolderID, targetBoardID: nil)
            if !payload.tags.isEmpty, !imported.isEmpty {
                if let patched = try? await engine.updateAssets(
                    AssetBatchPatch(assetIDs: imported.map(\.id), addTags: payload.tags)
                ) {
                    imported = patched
                }
            }
            return imported
        } catch {
            showToast("导入分享内容失败：\(error.localizedDescription)", tone: .error)
            return []
        }
    }

    // MARK: - Reload & Filtering

    func selectScope(_ next: MobileScope) {
        guard scope != next else { return }
        scope = next
        isReloadingAssets = true
        semanticSearchGeneration &+= 1
        semanticEnhancementDelayTask?.cancel()
        semanticEnhancementDelayTask = nil
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

        if trimmed.isEmpty {
            Task { await clearSemanticSearch() }
            return
        }

        // Stage 1: instant local FTS/tag/OCR/color results; Stage 2 automatically fuses hybrid semantic hits after a brief pause.
        searchDebounceTask = Task {
            try? await Task.sleep(for: .milliseconds(140))
            guard !Task.isCancelled else { return }
            await reloadAssets(semanticEnhancementDelayMs: 300)
        }
    }

    func submitSearch() {
        searchDebounceTask?.cancel()
        let trimmed = criteria.searchQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        Task {
            if trimmed.isEmpty {
                await clearSemanticSearch()
            } else {
                await reloadAssets(semanticEnhancementDelayMs: 0)
            }
        }
    }

    func clearFilters() {
        criteria.searchQuery = ""
        criteria.clearVisualFilters()
        criteria.tags.removeAll()
        searchDebounceTask?.cancel()
        searchDebounceTask = nil
        semanticSearchGeneration &+= 1
        semanticEnhancementDelayTask?.cancel()
        semanticEnhancementDelayTask = nil
        semanticSearchTask?.cancel()
        semanticSearchTask = nil
        semanticSearchReport = nil
        isRunningSemanticSearch = false
        quickJumpTask?.cancel()
        quickJumpMatches = []
        Task { await reloadAssets(semanticEnhancementDelayMs: nil) }
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
        Task { await reloadAssets() }
    }

    func updateColorTolerance(_ value: Double) {
        let clamped = max(10, min(55, value))
        criteria.colorTolerance = clamped
        colorToleranceDebounceTask?.cancel()
        colorToleranceDebounceTask = Task {
            try? await Task.sleep(for: .milliseconds(100))
            guard !Task.isCancelled else { return }
            await reloadAssets()
        }
    }

    private func scheduleUnifiedSemanticEnhancement(
        query: String,
        snapshotCriteria: FilterCriteria,
        requestedScope: MobileScope,
        reloadGen: UInt64,
        literalAssets: [AssetRecord],
        delayMilliseconds: Int
    ) {
        semanticEnhancementDelayTask?.cancel()
        semanticEnhancementDelayTask = nil
        semanticSearchTask?.cancel()
        semanticSearchTask = nil
        semanticSearchGeneration &+= 1
        let semGen = semanticSearchGeneration

        let runEnhancement: @MainActor () -> Void = { [weak self] in
            guard let self,
                  semGen == self.semanticSearchGeneration,
                  reloadGen == self.reloadAssetsGeneration,
                  self.scope == requestedScope else {
                return
            }
            let task = Task<SemanticSearchReport?, Never> { @MainActor [weak self] in
                guard let self else { return nil }
                // Avoid a 1-frame spinner blink on fast local-only bilingual/CIELAB fusion.
                let spinnerTask = Task<Void, Never> { @MainActor [weak self] in
                    try? await Task.sleep(for: .milliseconds(140))
                    guard !Task.isCancelled, let self, semGen == self.semanticSearchGeneration else { return }
                    self.isRunningSemanticSearch = true
                }
                defer {
                    spinnerTask.cancel()
                    if semGen == self.semanticSearchGeneration {
                        self.isRunningSemanticSearch = false
                        self.semanticSearchTask = nil
                    }
                }
                do {
                    let report = try await self.engine.semanticSearch(
                        query: query,
                        criteria: snapshotCriteria,
                        limit: 80
                    )
                    guard !Task.isCancelled,
                          semGen == self.semanticSearchGeneration,
                          reloadGen == self.reloadAssetsGeneration,
                          self.scope == requestedScope else {
                        return nil
                    }
                    self.semanticSearchReport = report
                    let scopedSemantic = self.applyScopeSmartFolderIfNeeded(
                        report.hits.map(\.asset),
                        scope: requestedScope
                    )
                    let merged = SemanticSearchReport.mergeUnifiedAssets(
                        literal: literalAssets,
                        semantic: scopedSemantic,
                        prioritizeSemantic: report.usedTypeSafeJev || report.usedCloudEmbedding
                    )
                    self.applyUnfoldedAssets(merged)
                    return report
                } catch {
                    return nil
                }
            }
            self.semanticSearchTask = task
        }

        if delayMilliseconds > 0 {
            semanticEnhancementDelayTask = Task<Void, Never> { @MainActor [weak self] in
                try? await Task.sleep(for: .milliseconds(delayMilliseconds))
                guard !Task.isCancelled, let self else { return }
                self.semanticEnhancementDelayTask = nil
                runEnhancement()
            }
        } else {
            runEnhancement()
        }
    }

    private func applyScopeSmartFolderIfNeeded(_ list: [AssetRecord], scope: MobileScope) -> [AssetRecord] {
        guard case .smartFolder(let smartID) = scope else { return list }
        guard let smart = smartFolders.first(where: { $0.id == smartID }) else { return [] }
        return list.filter { smart.rule.matches($0) }
    }

    @discardableResult
    func runSemanticSearch(query: String? = nil) async -> SemanticSearchReport? {
        let resolvedQuery = (query ?? criteria.searchQuery).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !resolvedQuery.isEmpty else {
            await clearSemanticSearch()
            return nil
        }
        semanticEnhancementDelayTask?.cancel()
        semanticEnhancementDelayTask = nil
        semanticSearchTask?.cancel()
        semanticSearchGeneration &+= 1
        let semGen = semanticSearchGeneration
        var draftCriteria = effectiveCriteria()
        draftCriteria.searchQuery = resolvedQuery
        let snapshotCriteria = draftCriteria
        let requestedScope = scope
        let engine = self.engine

        isRunningSemanticSearch = true
        let task = Task<SemanticSearchReport?, Never> { @MainActor [weak self] in
            guard let self else { return nil }
            defer {
                if semGen == self.semanticSearchGeneration {
                    self.isRunningSemanticSearch = false
                    self.semanticSearchTask = nil
                }
            }
            do {
                async let literalFetched = (try? engine.fetchAssets(matching: snapshotCriteria)) ?? []
                async let semanticReport = engine.semanticSearch(
                    query: resolvedQuery,
                    criteria: snapshotCriteria,
                    limit: 80
                )
                let (rawLiteral, report) = try await (literalFetched, semanticReport)
                guard !Task.isCancelled, semGen == self.semanticSearchGeneration, self.scope == requestedScope else {
                    return nil
                }
                self.semanticSearchReport = report
                let scopedLiteral = self.applyScopeSmartFolderIfNeeded(rawLiteral, scope: requestedScope)
                let scopedSemantic = self.applyScopeSmartFolderIfNeeded(report.hits.map(\.asset), scope: requestedScope)
                let merged = SemanticSearchReport.mergeUnifiedAssets(
                    literal: scopedLiteral,
                    semantic: scopedSemantic,
                    prioritizeSemantic: report.usedTypeSafeJev || report.usedCloudEmbedding
                )
                self.applyUnfoldedAssets(merged)
                return report
            } catch {
                return nil
            }
        }
        semanticSearchTask = task
        return await task.value
    }

    func clearSemanticSearch() async {
        semanticSearchGeneration &+= 1
        semanticEnhancementDelayTask?.cancel()
        semanticEnhancementDelayTask = nil
        semanticSearchTask?.cancel()
        semanticSearchTask = nil
        isRunningSemanticSearch = false
        semanticSearchReport = nil
        await reloadAssets(semanticEnhancementDelayMs: nil)
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
        async let fetchedInboxItems = (try? engine.fetchAssets(matching: FilterCriteria(onlyInbox: true))) ?? []
        async let fetchedAllForStacks = (try? engine.fetchAssets(matching: FilterCriteria(includeSubfolders: true))) ?? []
        async let fetchedStats = engine.cacheStats()

        folders = await fetchedFolders
        smartFolders = await fetchedSmart
        boards = await fetchedBoards
        tagCounts = await fetchedTags
        let allActive = await fetchedAllForStacks
        let (_, globalGroups) = Self.foldVersionStacks(allActive)
        stackMembersByGroupID = globalGroups
        let rawInbox = await fetchedInboxItems
        applyUnfoldedInboxAssets(rawInbox)
        inboxCount = (try? await engine.inboxCount()) ?? inboxAssets.count
        cacheStats = await fetchedStats
        publishSharedFoldersSnapshot()
        await reloadAssets()
    }

    func reloadAssets(semanticEnhancementDelayMs: Int? = 300) async {
        semanticEnhancementDelayTask?.cancel()
        semanticEnhancementDelayTask = nil
        semanticSearchTask?.cancel()
        semanticSearchTask = nil
        semanticSearchGeneration &+= 1
        isRunningSemanticSearch = false
        semanticSearchReport = nil

        reloadAssetsGeneration &+= 1
        let gen = reloadAssetsGeneration
        let requestedScope = scope
        isReloadingAssets = true
        defer {
            if gen == reloadAssetsGeneration {
                isReloadingAssets = false
            }
        }
        var query = effectiveCriteria()
        let loaded: [AssetRecord]
        if case .smartFolder = requestedScope {
            query.folderID = nil
            query.onlyInbox = false
            query.onlyTrashed = false
            query.includeTrashed = false
            let all = (try? await engine.fetchAssets(matching: query)) ?? []
            loaded = applyScopeSmartFolderIfNeeded(all, scope: requestedScope)
        } else {
            loaded = (try? await engine.fetchAssets(matching: query)) ?? []
        }
        guard gen == reloadAssetsGeneration else { return }
        applyUnfoldedAssets(loaded)

        let trimmedQuery = query.searchQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmedQuery.isEmpty, let delayMs = semanticEnhancementDelayMs {
            scheduleUnifiedSemanticEnhancement(
                query: trimmedQuery,
                snapshotCriteria: query,
                requestedScope: requestedScope,
                reloadGen: gen,
                literalAssets: loaded,
                delayMilliseconds: delayMs
            )
        }
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
        case .allItems, .moodboardsHome, .moodboard, .pinterest:
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
        Task(priority: .utility) {
            await Self.writeSharedFoldersSnapshotOffMain(summaries)
        }
    }

    @concurrent
    private static func writeSharedFoldersSnapshotOffMain(_ summaries: [SharedFolderSummary]) async {
        MobileLibraryContainer.saveSharedFoldersSnapshot(summaries)
    }

    // MARK: - Visual Similarity Search

    func loadSimilarAssets(for assetID: UUID) async {
        isLoadingSimilar = true
        defer { isLoadingSimilar = false }
        similarResults = (try? await engine.similarAssets(to: assetID, limit: 18)) ?? []
    }

    // MARK: - Capture (Photos / Files / URLs / Clipboard / Demo)

    func ingestInputs(
        _ inputs: [CaptureInput],
        targetFolderID: UUID? = nil,
        tags: [String] = [],
        autoExtractSocialMedia: Bool = false
    ) async -> [AssetRecord] {
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

            let socialPostsWithMedia = imported.filter { asset in
                guard let post = asset.richMetadata?.socialPost else { return false }
                return !post.effectiveAttachments.isEmpty
            }
            // Never auto-download YouTube/Bilibili/Douyin videos on default bookmark (strictly on-demand when user taps save video)
            let autoExtractablePosts = socialPostsWithMedia.filter {
                !($0.richMetadata?.socialPost?.isZeroDownloadVideoBookmark ?? false)
            }

            if autoExtractSocialMedia && !autoExtractablePosts.isEmpty {
                var extractedTotal = 0
                for postAsset in autoExtractablePosts {
                    let extracted = await extractAllMediaFromSocialPost(postAsset: postAsset, quiet: true)
                    extractedTotal += extracted.count
                }
                await reloadAll()
                MobileHaptics.success()
                if extractedTotal > 0 {
                    showToast("已收藏社媒帖子并拆出 \(extractedTotal) 项独立素材", tone: .success)
                } else {
                    showToast("已收藏 \(imported.count) 项素材", tone: .success)
                }
            } else {
                await reloadAll()
                MobileHaptics.success()
                if imported.count == 1,
                   let firstSocial = imported.first,
                   let post = firstSocial.richMetadata?.socialPost,
                   (!post.effectiveAttachments.isEmpty || post.isZeroDownloadVideoBookmark) {
                    if post.isZeroDownloadVideoBookmark {
                        let summarySuffix = post.hasVideoSummaryContent ? "与摘要" : ""
                        showToast(
                            "已收藏\(post.platform.displayName)视频（含封面\(summarySuffix)）",
                            tone: .success,
                            actionTitle: "保存视频",
                            onAction: { [weak self] in
                                guard let self else { return }
                                Task {
                                    _ = await self.extractAllMediaFromSocialPost(postAsset: firstSocial)
                                }
                            }
                        )
                    } else {
                        let count = post.effectiveAttachments.count
                        showToast(
                            "已解析\(post.platform.displayName)\(post.platform.postNoun)（含 \(count) 项媒体）",
                            tone: .success,
                            actionTitle: "拆为独立素材",
                            onAction: { [weak self] in
                                guard let self else { return }
                                Task {
                                    _ = await self.extractAllMediaFromSocialPost(postAsset: firstSocial)
                                }
                            }
                        )
                    }
                } else if imported.count == 1,
                          let firstWeb = imported.first,
                          let web = firstWeb.richMetadata?.webPage,
                          !web.attachments.isEmpty {
                    showToast(
                        "已解析网页（含 \(web.attachments.count) 项可提取媒体）",
                        tone: .success,
                        actionTitle: "提取媒体",
                        onAction: { [weak self] in
                            guard let self else { return }
                            Task {
                                _ = await self.extractAllMediaFromLinkAsset(firstWeb)
                            }
                        }
                    )
                } else {
                    showToast("已收藏 \(imported.count) 项素材", tone: .success)
                }
            }

            await evaluateStackCandidates(for: imported)

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

    func captureURLOrShareText(
        _ rawText: String,
        notes: String = "",
        tags: [String] = [],
        targetFolderID: UUID? = nil,
        autoExtractSocialMedia: Bool = false
    ) async -> Bool {
        let trimmed = rawText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            showToast("请先输入网页、小红书、抖音、X 或 GitHub 链接", tone: .warning)
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
        let imported = await ingestInputs(
            [input],
            targetFolderID: targetFolderID,
            tags: tags,
            autoExtractSocialMedia: autoExtractSocialMedia
        )
        return !imported.isEmpty
    }

    // MARK: - Social Post Media Extraction (1:1 macOS Parity)

    /// Extracts a single photo/video/GIF attachment from a saved social post into a standalone library asset,
    /// preserving full originating post provenance (author, handle, body excerpt, platform tag, and source URL).
    @discardableResult
    func extractMediaFromSocialPost(
        postAsset: AssetRecord,
        attachment: SocialMediaAttachment,
        index: Int,
        quiet: Bool = false
    ) async -> AssetRecord? {
        guard let post = postAsset.richMetadata?.socialPost else {
            if !quiet {
                showToast("该媒体缺少有效的来源信息", tone: .warning)
            }
            return nil
        }

        let startedStandalone = !isExtractingSocialMedia
        if startedStandalone {
            isExtractingSocialMedia = true
        }
        defer {
            if startedStandalone {
                isExtractingSocialMedia = false
            }
        }

        if !quiet {
            if post.isZeroDownloadVideoBookmark {
                showToast("正在从\(post.platform.displayName)保存视频原文件…", tone: .info)
            } else {
                showToast("正在提取第 \(index + 1) 项\(attachment.kind.localizedLabel)…", tone: .info)
            }
        }

        do {
            let tempDir = FileManager.default.temporaryDirectory
                .appending(path: "charkle-social-extract-\(UUID().uuidString)", directoryHint: .isDirectory)
            try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: tempDir) }

            let kindTag: String = switch attachment.kind {
            case .photo: "img"
            case .video: "video"
            case .gif: "gif"
            }
            let safeHandle = post.authorHandle.isEmpty ? "post" : post.authorHandle
            let baseName = "\(post.platform.displayName)-\(safeHandle)-\(kindTag)\(index + 1)"

            let created: [AssetRecord]
            if post.isZeroDownloadVideoBookmark {
                let videoFile = try await VideoPlatformResolver.downloadVideo(
                    for: post,
                    to: tempDir,
                    baseName: post.articleTitle ?? baseName
                )
                created = try await engine.ingest(
                    [.fileURL(videoFile)],
                    targetFolderID: postAsset.folderID,
                    targetBoardID: nil
                )
            } else if attachment.kind == .video || attachment.kind == .gif {
                guard let mediaURL = URL(string: attachment.url) else { return nil }
                var localVideoFile: URL?
                if index == 0,
                   let cached = try? await engine.originalURL(for: postAsset.id),
                   ["mp4", "mov", "m4v", "webm"].contains(cached.pathExtension.lowercased()) {
                    let copied = tempDir.appending(path: "\(baseName).\(cached.pathExtension.lowercased())")
                    try? FileManager.default.copyItem(at: cached, to: copied)
                    if FileManager.default.fileExists(atPath: copied.path) {
                        localVideoFile = copied
                    }
                }
                if localVideoFile == nil {
                    let xKind: XPostMedia.Kind = attachment.kind == .gif ? .gif : .video
                    let mediaItem = XPostMedia(
                        kind: xKind,
                        url: mediaURL,
                        thumbnailURL: attachment.thumbnailURL.flatMap(URL.init(string:))
                    )
                    localVideoFile = await XPostResolver.downloadMedia(mediaItem, to: tempDir, baseName: baseName)
                }
                guard let videoFile = localVideoFile else {
                    if !quiet {
                        MobileHaptics.error()
                        showToast("无法下载该社媒视频，请检查网络或打开原链接查看", tone: .error)
                    }
                    return nil
                }
                created = try await engine.ingest(
                    [.fileURL(videoFile)],
                    targetFolderID: postAsset.folderID,
                    targetBoardID: nil
                )
            } else {
                guard let mediaURL = URL(string: attachment.url) else { return nil }
                let mediaItem = XPostMedia(kind: .photo, url: mediaURL)
                guard let localFile = await XPostResolver.downloadMedia(mediaItem, to: tempDir, baseName: baseName),
                      let imageData = try? Data(contentsOf: localFile) else {
                    if !quiet {
                        MobileHaptics.error()
                        showToast("无法下载该社媒图片，请检查网络或打开原链接查看", tone: .error)
                    }
                    return nil
                }
                created = try await engine.ingest(
                    [.imageData(imageData, suggestedName: localFile.lastPathComponent, sourceURL: post.originalURL)],
                    targetFolderID: postAsset.folderID,
                    targetBoardID: nil
                )
            }

            guard let standalone = created.first else { return nil }

            let authorAttribution: String = {
                if let handleLine = post.displayHandleLine {
                    return "\(post.displayAuthorName) (\(handleLine))"
                }
                return post.displayAuthorName
            }()
            var noteParts: [String] = [
                "来源\(post.platform.postNoun)：\(authorAttribution) · \(post.platform.displayName)"
            ]
            if let summary = post.videoSummary?.trimmingCharacters(in: .whitespacesAndNewlines), !summary.isEmpty {
                noteParts.append("视频摘要：\n\(summary)")
            }
            if !post.videoOutline.isEmpty {
                noteParts.append("章节要点：\n" + post.videoOutline.joined(separator: "\n"))
            }
            let bodyTrimmed = post.bodyText.trimmingCharacters(in: .whitespacesAndNewlines)
            if !bodyTrimmed.isEmpty {
                noteParts.append(bodyTrimmed)
            }
            noteParts.append("原链接：\(post.originalURL)")
            let attributionNotes = noteParts.joined(separator: "\n\n")

            let extractedTitle: String = {
                if post.isZeroDownloadVideoBookmark,
                   let article = post.articleTitle?.trimmingCharacters(in: .whitespacesAndNewlines),
                   !article.isEmpty {
                    return article
                }
                let titleAuthor = (post.platform.isVerticalFeedPlatform || post.platform.isVideoPlatform)
                    ? post.displayAuthorName
                    : (post.authorHandle.hasPrefix("@") ? post.authorHandle : "@\(post.authorHandle)")
                return "\(titleAuthor) \(attachment.kind.localizedLabel) #\(index + 1)"
            }()

            var extractedTags = [post.platform.displayName]
            if post.platform == .douyin {
                extractedTags.append(DouyinURLParser.classificationTag(hasVideo: post.hasVideo))
            }
            let patched = try await engine.updateAssets(
                AssetBatchPatch(
                    assetIDs: [standalone.id],
                    title: extractedTitle,
                    notes: attributionNotes,
                    sourceURL: post.originalURL,
                    addTags: extractedTags
                )
            )
            let finalAsset = patched.first ?? standalone

            if !quiet {
                await reloadAll()
                MobileHaptics.success()
                showToast("已保存为独立素材「\(finalAsset.title)」", tone: .success)
                if hasConnectedCloudBackend {
                    Task { await self.syncNow(quiet: true) }
                }
            }
            return finalAsset
        } catch {
            if !quiet {
                MobileHaptics.error()
                showToast(error.localizedDescription, tone: .error)
            }
            return nil
        }
    }

    @discardableResult
    func extractMediaFromWebPageAsset(
        webAsset: AssetRecord,
        attachment: SocialMediaAttachment,
        index: Int,
        quiet: Bool = false
    ) async -> AssetRecord? {
        guard let web = webAsset.richMetadata?.webPage else { return nil }
        let startedStandalone = !isExtractingSocialMedia
        if startedStandalone { isExtractingSocialMedia = true }
        defer { if startedStandalone { isExtractingSocialMedia = false } }

        if !quiet {
            showToast(attachment.kind == .video ? "正在保存网页视频…" : "正在提取网页图片…", tone: .info)
        }
        do {
            let tempDir = FileManager.default.temporaryDirectory
                .appending(path: "charkle-web-extract-\(UUID().uuidString)", directoryHint: .isDirectory)
            try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: tempDir) }

            let pageURL = web.canonicalURL.isEmpty ? (webAsset.sourceURL ?? "") : web.canonicalURL
            let baseName = webAsset.title.isEmpty ? "WebMedia-\(index + 1)" : "\(webAsset.title)-\(index + 1)"
            let created: [AssetRecord]
            if attachment.kind == .video || attachment.kind == .gif {
                let videoFile = try await VideoPlatformResolver.downloadGenericWebVideo(
                    pageURL: pageURL,
                    directStreamURL: URL(string: attachment.url),
                    to: tempDir,
                    baseName: baseName
                )
                created = try await engine.ingest([.fileURL(videoFile)], targetFolderID: webAsset.folderID, targetBoardID: nil)
            } else {
                guard let mediaURL = URL(string: attachment.url) else { return nil }
                let mediaItem = XPostMedia(kind: .photo, url: mediaURL)
                guard let localFile = await XPostResolver.downloadMedia(
                    mediaItem,
                    to: tempDir,
                    baseName: baseName,
                    referer: URL(string: pageURL)
                ),
                let imageData = try? Data(contentsOf: localFile) else {
                    if !quiet {
                        MobileHaptics.error()
                        showToast("无法下载该网页图片", tone: .error)
                    }
                    return nil
                }
                created = try await engine.ingest(
                    [.imageData(imageData, suggestedName: localFile.lastPathComponent, sourceURL: pageURL)],
                    targetFolderID: webAsset.folderID,
                    targetBoardID: nil
                )
            }
            guard let standalone = created.first else { return nil }
            var notesParts: [String] = []
            if let site = web.siteName, !site.isEmpty { notesParts.append("来源网页：\(site)") }
            if let summary = web.summary, !summary.isEmpty { notesParts.append(summary) }
            if !pageURL.isEmpty { notesParts.append("原链接：\(pageURL)") }
            let title = attachment.kind == .video
                ? webAsset.title
                : "\(webAsset.title) \(attachment.kind.localizedLabel) #\(index + 1)"
            let patched = try await engine.updateAssets(
                AssetBatchPatch(
                    assetIDs: [standalone.id],
                    title: title,
                    notes: notesParts.joined(separator: "\n\n"),
                    sourceURL: pageURL.isEmpty ? nil : pageURL,
                    addTags: web.siteName.map { [$0] } ?? []
                )
            )
            let finalAsset = patched.first ?? standalone
            if !quiet {
                await reloadAll()
                MobileHaptics.success()
                showToast("已保存为独立素材「\(finalAsset.title)」", tone: .success)
                if hasConnectedCloudBackend {
                    Task { await self.syncNow(quiet: true) }
                }
            }
            return finalAsset
        } catch {
            if !quiet {
                MobileHaptics.error()
                showToast(error.localizedDescription, tone: .error)
            }
            return nil
        }
    }

    @discardableResult
    func updateAssetCoverImage(assetID: UUID, imageData: Data, timestampSeconds: Double? = nil) async -> AssetRecord? {
        do {
            let updated = try await engine.updateAssetCoverImage(id: assetID, imageData: imageData)
            if let idx = assets.firstIndex(where: { $0.id == updated.id }) {
                assets[idx] = updated
            }
            if let idx = inboxAssets.firstIndex(where: { $0.id == updated.id }) {
                inboxAssets[idx] = updated
            }
            thumbnails.invalidate(assetIDs: [updated.id])
            if let ts = timestampSeconds, ts > 0 {
                showToast("已将 \(VideoFrameCapture.formattedTimestamp(ts)) 画面设为素材封面", tone: .success)
            } else {
                showToast("已将当前画面设为素材封面", tone: .success)
            }
            if hasConnectedCloudBackend {
                Task { await self.syncNow(quiet: true) }
            }
            return updated
        } catch {
            showToast("更新封面失败：\(error.localizedDescription)", tone: .error)
            return nil
        }
    }

    @discardableResult
    func extractAllMediaFromLinkAsset(_ asset: AssetRecord, quiet: Bool = false) async -> [AssetRecord] {
        if asset.richMetadata?.socialPost != nil {
            return await extractAllMediaFromSocialPost(postAsset: asset, quiet: quiet)
        }
        guard let web = asset.richMetadata?.webPage, !web.attachments.isEmpty else { return [] }
        let targets: [SocialMediaAttachment] = {
            let vids = web.attachments.filter { $0.kind == .video || $0.kind == .gif }
            return !vids.isEmpty ? vids : Array(web.attachments.prefix(8))
        }()
        let startedStandalone = !isExtractingSocialMedia
        if startedStandalone { isExtractingSocialMedia = true }
        defer { if startedStandalone { isExtractingSocialMedia = false } }
        if !quiet {
            showToast("正在提取 \(targets.count) 项网页媒体…", tone: .info)
        }
        var extracted: [AssetRecord] = []
        for (idx, att) in targets.enumerated() {
            if let item = await extractMediaFromWebPageAsset(webAsset: asset, attachment: att, index: idx, quiet: true) {
                extracted.append(item)
            }
        }
        if !quiet {
            await reloadAll()
            if !extracted.isEmpty {
                MobileHaptics.success()
                showToast("已提取 \(extracted.count) 项网页媒体为独立素材", tone: .success)
                if hasConnectedCloudBackend {
                    Task { await self.syncNow(quiet: true) }
                }
            } else {
                MobileHaptics.error()
                showToast("未能从该网页提取到媒体文件", tone: .error)
            }
        }
        return extracted
    }

    /// Batch extracts media from multiple selected saved links (YouTube, Bilibili, X, Xiaohongshu, and rich webpages).
    @discardableResult
    func extractMediaFromSelectedLinks(_ ids: Set<UUID>) async -> Int {
        let lookup = Dictionary(uniqueKeysWithValues: (assets + inboxAssets).map { ($0.id, $0) })
        let targets = ids.compactMap { lookup[$0] }.filter(\.hasExtractableLinkMedia)
        guard !targets.isEmpty else {
            showToast("所选项目中没有可提取媒体的链接", tone: .warning)
            return 0
        }

        isExtractingSocialMedia = true
        defer { isExtractingSocialMedia = false }
        showToast("正在批量提取 \(targets.count) 个链接中的媒体…", tone: .info)

        var totalExtracted = 0
        var succeededLinks = 0
        for target in targets {
            let items = await extractAllMediaFromLinkAsset(target, quiet: true)
            if !items.isEmpty {
                totalExtracted += items.count
                succeededLinks += 1
            }
        }

        await reloadAll()
        if totalExtracted > 0 {
            MobileHaptics.success()
            showToast("已从 \(succeededLinks) 个链接批量保存 \(totalExtracted) 项独立素材", tone: .success)
            if hasConnectedCloudBackend {
                Task { await self.syncNow(quiet: true) }
            }
        } else {
            MobileHaptics.error()
            showToast("未能从所选链接提取到媒体，请检查网络或平台限制", tone: .error)
        }
        return totalExtracted
    }

    /// Extracts all photo & video attachments from a saved social post into standalone assets.
    @discardableResult
    func extractAllMediaFromSocialPost(postAsset: AssetRecord, quiet: Bool = false) async -> [AssetRecord] {
        guard let post = postAsset.richMetadata?.socialPost else { return [] }
        let items: [SocialMediaAttachment] = {
            let existing = post.effectiveAttachments
            if !existing.isEmpty { return existing }
            if post.isZeroDownloadVideoBookmark {
                return [SocialMediaAttachment(kind: .video, url: post.videoURL ?? post.originalURL, thumbnailURL: post.mediaThumbnailURLs.first)]
            }
            return []
        }()
        guard !items.isEmpty else {
            if !quiet {
                showToast("该社媒帖子没有可提取的图片或视频", tone: .warning)
            }
            return []
        }

        isExtractingSocialMedia = true
        defer { isExtractingSocialMedia = false }

        if !quiet {
            if post.isZeroDownloadVideoBookmark {
                showToast("正在从\(post.platform.displayName)保存视频原文件…", tone: .info)
            } else {
                showToast("正在提取 \(items.count) 项帖子媒体…", tone: .info)
            }
        }

        var extracted: [AssetRecord] = []
        for (idx, attachment) in items.enumerated() {
            if let asset = await extractMediaFromSocialPost(
                postAsset: postAsset,
                attachment: attachment,
                index: idx,
                quiet: true
            ) {
                extracted.append(asset)
            }
        }

        if !quiet {
            await reloadAll()
            if !extracted.isEmpty {
                MobileHaptics.success()
                showToast(
                    post.isZeroDownloadVideoBookmark
                        ? "已保存视频为独立素材"
                        : "已提取 \(extracted.count) 项帖子媒体为独立素材",
                    tone: .success
                )
                if hasConnectedCloudBackend {
                    Task { await self.syncNow(quiet: true) }
                }
            } else {
                MobileHaptics.error()
                showToast("未能下载帖子媒体，请检查网络或打开原链接", tone: .error)
            }
        }
        return extracted
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

    func patchAssets(
        _ patch: AssetBatchPatch,
        successToast: String? = nil,
        actionTitle: String? = nil,
        onAction: (() -> Void)? = nil
    ) async {
        do {
            let updated = try await engine.updateAssets(patch)
            let updatedByID = Dictionary(uniqueKeysWithValues: updated.map { ($0.id, $0) })
            if patch.isTrashed != nil {
                let affectedIDs = Set(updated.map(\.id)).union(patch.assetIDs)
                selectedAssetIDs.subtract(affectedIDs)
                if patch.isTrashed == true, let sel = selectedAssetID, affectedIDs.contains(sel) {
                    selectedAssetID = nil
                }
            }
            for idx in assets.indices {
                if let fresh = updatedByID[assets[idx].id] {
                    assets[idx] = fresh
                }
            }
            for idx in inboxAssets.indices {
                if let fresh = updatedByID[inboxAssets[idx].id] {
                    inboxAssets[idx] = fresh
                }
            }
            if requiresFullReload(for: patch) {
                await reloadAll()
            } else if patch.pinnedOffline != nil {
                cacheStats = await engine.cacheStats()
            }
            if let successToast {
                MobileHaptics.light()
                showToast(successToast, tone: .success, actionTitle: actionTitle, onAction: onAction)
            }
            if hasConnectedCloudBackend {
                Task { await self.syncNow(quiet: true) }
            }
        } catch {
            MobileHaptics.error()
            showToast("更新失败：\(error.localizedDescription)", tone: .error)
        }
    }

    private func requiresFullReload(for patch: AssetBatchPatch) -> Bool {
        if patch.folderAssignment != .unchanged { return true }
        if patch.isTrashed != nil { return true }
        if !patch.addTags.isEmpty || !patch.removeTags.isEmpty || patch.acceptSuggestedTags { return true }
        if case .smartFolder = scope { return true }
        if patch.rating != nil && (criteria.minRating > 0 || criteria.sortBy == .ratingDesc) { return true }
        if patch.pinnedOffline != nil && criteria.onlyPinnedOffline { return true }
        if patch.title != nil && (criteria.sortBy == .nameAsc || !criteria.searchQuery.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty) {
            return true
        }
        if patch.notes != nil && !criteria.searchQuery.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return true
        }
        return false
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
            if hasConnectedCloudBackend {
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
            if hasConnectedCloudBackend {
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
            if hasConnectedCloudBackend {
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
        let target = primaryVersionAsset(for: asset)
        if target.isExternalWebLink, let url = target.externalWebURL {
            UIPasteboard.general.url = url
            MobileHaptics.light()
            showToast("已拷贝网页链接", tone: .success)
            return
        }
        if target.mediaKind == .document,
           let fileURL = await shareableOriginalURL(for: target, preferExactAsset: true) {
            UIPasteboard.general.url = fileURL
            MobileHaptics.light()
            let verSuffix = target.richMetadata?.versionStack.map { "（主版 \($0.displayVersionTag)）" } ?? ""
            showToast("已拷贝文档「\(target.title)」\(verSuffix)", tone: .success)
            return
        }
        if let image = await thumbnails.loadOriginalImage(for: target) {
            UIPasteboard.general.image = image
            MobileHaptics.light()
            let verSuffix = target.richMetadata?.versionStack.map { "（主版 \($0.displayVersionTag)）" } ?? ""
            showToast("已拷贝图片\(verSuffix)到剪贴板", tone: .success)
        } else if let fileURL = await shareableOriginalURL(for: target, preferExactAsset: true) {
            UIPasteboard.general.url = fileURL
            MobileHaptics.light()
            showToast("已拷贝文件到剪贴板", tone: .success)
        } else if let urlStr = target.sourceURL, let url = URL(string: urlStr) {
            UIPasteboard.general.url = url
            MobileHaptics.light()
            showToast("已拷贝来源链接", tone: .success)
        } else {
            showToast("暂无法拷贝该素材", tone: .warning)
        }
    }

    // MARK: - Version Stack Candidate Detection & Mutations

    func evaluateStackCandidates(for importedAssets: [AssetRecord]) async {
        for item in importedAssets {
            guard item.richMetadata?.versionStack == nil,
                  !dismissedStackPromptAssetIDs.contains(item.id),
                  !pendingStackPrompts.contains(where: { $0.id == item.id }) else {
                continue
            }
            if let candidate = try? await engine.detectVersionStackCandidate(forAssetID: item.id) {
                withAnimation(MobileMotion.enterSm) {
                    if !pendingStackPrompts.contains(where: { $0.id == item.id }) {
                        pendingStackPrompts.append(
                            MobilePendingStackPrompt(importedAsset: item, candidate: candidate)
                        )
                    }
                }
                MobileHaptics.selection()
            }
        }
    }

    func dismissStackPrompt(_ promptID: UUID) {
        dismissedStackPromptAssetIDs.insert(promptID)
        withAnimation(MobileMotion.exitSm) {
            pendingStackPrompts.removeAll { $0.id == promptID }
        }
    }

    func confirmStackPrompt(
        _ prompt: MobilePendingStackPrompt,
        editorName: String?,
        changeNote: String?,
        pinAsPrimary: Bool = false
    ) async {
        withAnimation(MobileMotion.exitSm) {
            pendingStackPrompts.removeAll { $0.id == prompt.id }
        }
        await joinVersionStack(
            assetID: prompt.importedAsset.id,
            targetAssetOrGroupID: prompt.candidate.existingStackExists
                ? prompt.candidate.targetGroupID
                : prompt.candidate.targetAssetID,
            editorName: editorName,
            changeNote: changeNote,
            pinAsPrimary: pinAsPrimary,
            adoptTargetFolder: true
        )
    }

    func importDroppedURLs(
        _ urls: [URL],
        ontoStackTargetID: UUID? = nil,
        targetFolderID: UUID? = nil
    ) async {
        guard !urls.isEmpty else { return }
        var scopedURLs: [URL] = []
        for url in urls where url.isFileURL {
            if url.startAccessingSecurityScopedResource() {
                scopedURLs.append(url)
            }
        }
        defer {
            for url in scopedURLs {
                url.stopAccessingSecurityScopedResource()
            }
        }

        let tempDir = FileManager.default.temporaryDirectory
            .appending(path: "charkle-drop-\(UUID().uuidString)", directoryHint: .isDirectory)
        try? FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        var inputs: [CaptureInput] = []
        for url in urls {
            if url.isFileURL {
                let copyDest = tempDir.appending(path: url.lastPathComponent)
                if (try? FileManager.default.copyItem(at: url, to: copyDest)) != nil {
                    inputs.append(.fileURL(copyDest))
                } else {
                    inputs.append(.fileURL(url))
                }
            } else {
                inputs.append(.webURL(url, title: nil, notes: nil))
            }
        }
        guard !inputs.isEmpty else { return }

        let effectiveFolder = targetFolderID ?? activeFolderIDForCapture
        if let ontoStackTargetID {
            do {
                isIngesting = true
                defer { isIngesting = false }
                let created = try await engine.ingest(inputs, targetFolderID: effectiveFolder, targetBoardID: nil)
                for item in created {
                    dismissedStackPromptAssetIDs.insert(item.id)
                    _ = try await engine.manageVersionStack(
                        .join(
                            assetID: item.id,
                            targetAssetOrGroupID: ontoStackTargetID,
                            adoptTargetFolder: true
                        )
                    )
                }
                await reloadAll()
                MobileHaptics.success()
                showToast("已将 \(created.count) 项归入历史版本", tone: .success)
                if hasConnectedCloudBackend {
                    Task { await self.syncNow(quiet: true) }
                }
            } catch {
                MobileHaptics.error()
                showToast("归入历史版本失败：\(error.localizedDescription)", tone: .error)
            }
        } else {
            _ = await ingestInputs(inputs, targetFolderID: effectiveFolder)
        }
    }

    func joinVersionStack(
        assetID: UUID,
        targetAssetOrGroupID: UUID,
        editorName: String? = nil,
        changeNote: String? = nil,
        pinAsPrimary: Bool = false,
        adoptTargetFolder: Bool = true
    ) async {
        do {
            let updated = try await engine.manageVersionStack(
                .join(
                    assetID: assetID,
                    targetAssetOrGroupID: targetAssetOrGroupID,
                    editorName: editorName,
                    changeNote: changeNote,
                    pinAsPrimary: pinAsPrimary,
                    adoptTargetFolder: adoptTargetFolder
                )
            )
            await reloadAll()
            MobileHaptics.success()
            let joinedVer = updated.first(where: { $0.id == assetID })?.richMetadata?.versionStack?.displayVersionTag ?? "新版"
            showToast(
                pinAsPrimary
                    ? "已归入历史版本 (\(joinedVer)) 并设为主版本"
                    : "已归入历史版本 (\(joinedVer))（原主版本锁定不变）",
                tone: .success
            )
            if hasConnectedCloudBackend {
                Task { await self.syncNow(quiet: true) }
            }
        } catch {
            MobileHaptics.error()
            showToast("合并版本失败：\(error.localizedDescription)", tone: .error)
        }
    }

    func createVersionStack(
        assetIDs: [UUID],
        primaryAssetID: UUID? = nil,
        editorName: String? = nil,
        changeNote: String? = nil
    ) async {
        guard assetIDs.count >= 2 else { return }
        do {
            _ = try await engine.manageVersionStack(
                .create(
                    assetIDs: assetIDs,
                    primaryAssetID: primaryAssetID,
                    editorName: editorName,
                    changeNote: changeNote
                )
            )
            await reloadAll()
            MobileHaptics.success()
            showToast("已将 \(assetIDs.count) 项合并为历史版本", tone: .success)
            if hasConnectedCloudBackend {
                Task { await self.syncNow(quiet: true) }
            }
        } catch {
            MobileHaptics.error()
            showToast("合并版本失败：\(error.localizedDescription)", tone: .error)
        }
    }

    func setPrimaryVersion(assetID: UUID) async {
        do {
            let updated = try await engine.manageVersionStack(.setPrimary(assetID: assetID))
            await reloadAll()
            MobileHaptics.success()
            let verTag = updated.first(where: { $0.id == assetID })?.richMetadata?.versionStack?.displayVersionTag ?? "当前版"
            showToast("已将 \(verTag) 锁定为对外主版本（分享与导出均指向此版）", tone: .success)
            if hasConnectedCloudBackend {
                Task { await self.syncNow(quiet: true) }
            }
        } catch {
            MobileHaptics.error()
            showToast("设置主版本失败：\(error.localizedDescription)", tone: .error)
        }
    }

    func unstackAsset(assetID: UUID) async {
        do {
            _ = try await engine.manageVersionStack(.unstack(assetID: assetID))
            await reloadAll()
            MobileHaptics.light()
            showToast("已拆分为独立素材", tone: .info)
            if hasConnectedCloudBackend {
                Task { await self.syncNow(quiet: true) }
            }
        } catch {
            MobileHaptics.error()
            showToast("拆分为独立素材失败：\(error.localizedDescription)", tone: .error)
        }
    }

    func updateVersionStackMetadata(
        assetID: UUID,
        versionLabel: String?,
        editorName: String?,
        changeNote: String?
    ) async {
        do {
            _ = try await engine.manageVersionStack(
                .updateMeta(
                    assetID: assetID,
                    versionLabel: versionLabel,
                    editorName: editorName,
                    changeNote: changeNote
                )
            )
            await reloadAll()
            MobileHaptics.success()
            showToast("已更新版本信息", tone: .success)
            if hasConnectedCloudBackend {
                Task { await self.syncNow(quiet: true) }
            }
        } catch {
            MobileHaptics.error()
            showToast("更新版本信息失败：\(error.localizedDescription)", tone: .error)
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

        let targetGroupID = asset.richMetadata?.versionStack?.groupID
        let matchesTarget: (AssetRecord) -> Bool = { item in
            if item.id == assetID { return true }
            if let targetGroupID, item.richMetadata?.versionStack?.groupID == targetGroupID {
                return true
            }
            return false
        }

        if !assets.contains(where: matchesTarget) {
            criteria.searchQuery = ""
            criteria.clearVisualFilters()
            criteria.tags.removeAll()
            semanticSearchGeneration &+= 1
            semanticEnhancementDelayTask?.cancel()
            semanticEnhancementDelayTask = nil
            semanticSearchTask?.cancel()
            semanticSearchTask = nil
            isRunningSemanticSearch = false
            semanticSearchReport = nil
            await reloadAssets(semanticEnhancementDelayMs: nil)
        }

        if !assets.contains(where: matchesTarget), targetScope != .allItems {
            scope = .allItems
            label = "全部素材"
            await reloadAssets()
        }

        let visibleCardID = assets.first(where: matchesTarget)?.id ?? assetID
        selectedAssetID = visibleCardID
        pendingRevealAssetID = visibleCardID
        highlightedAssetID = visibleCardID
        highlightDismissTask?.cancel()
        highlightDismissTask = Task {
            try? await Task.sleep(for: .milliseconds(2600))
            guard !Task.isCancelled else { return }
            withAnimation(MobileMotion.exitSm) {
                if self.highlightedAssetID == visibleCardID {
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
            if hasConnectedCloudBackend {
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
            if hasConnectedCloudBackend {
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
            if hasConnectedCloudBackend {
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
            if hasConnectedCloudBackend {
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
        let safeTitle = document.title
            .replacingOccurrences(of: "/", with: "-")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let fileName = (safeTitle.isEmpty ? "Charkle-Moodboard" : safeTitle) + ".png"
        let outURL = FileManager.default.temporaryDirectory.appending(path: fileName)
        let result = await Self.renderBoardPNGOffMain(
            document: document,
            assetsByID: assetsByID,
            thumbMap: thumbMap,
            options: options,
            outURL: outURL
        )
        switch result {
        case .success(let url):
            return url
        case .failure(let error):
            showToast(error.localizedDescription, tone: .error)
            return nil
        }
    }

    @concurrent
    private static func renderBoardPNGOffMain(
        document: MoodboardDocument,
        assetsByID: [UUID: AssetRecord],
        thumbMap: [UUID: URL],
        options: BoardImageRenderer.RenderOptions,
        outURL: URL
    ) async -> Result<URL, Error> {
        guard let pngData = BoardImageRenderer.renderPNG(
            document: document,
            assetsByID: assetsByID,
            thumbnailURL: { thumbMap[$0] },
            options: options
        ) else {
            return .failure(NSError(
                domain: "com.charkle.mobile.board",
                code: 1,
                userInfo: [NSLocalizedDescriptionKey: "导出情绪板图片失败"]
            ))
        }
        do {
            try pngData.write(to: outURL, options: .atomic)
            return .success(outURL)
        } catch {
            return .failure(NSError(
                domain: "com.charkle.mobile.board",
                code: 2,
                userInfo: [NSLocalizedDescriptionKey: "写入导出文件失败：\(error.localizedDescription)"]
            ))
        }
    }

    // MARK: - Bidirectional PureRef (.pur) Import & Export

    @discardableResult
    func importPureRefScenes(urls: [URL], targetFolderID: UUID?) async -> [PureRefImportResult] {
        guard !urls.isEmpty else { return [] }
        isIngesting = true
        defer { isIngesting = false }

        var results: [PureRefImportResult] = []
        for url in urls {
            do {
                let res = try await engine.importPureRefScene(
                    at: url,
                    targetFolderID: targetFolderID,
                    createMoodboard: true
                )
                results.append(res)
            } catch {
                showToast("导入 PureRef 失败：\(error.localizedDescription)", tone: .error)
            }
        }
        guard !results.isEmpty else { return [] }
        await reloadAll()
        let totalImages = results.reduce(0) { $0 + $1.importedAssets.count }
        let totalNotes = results.reduce(0) { $0 + $1.importedNoteCount }
        MobileHaptics.success()
        if results.count == 1, let first = results.first {
            let notePart = first.importedNoteCount > 0 ? "、\(first.importedNoteCount) 条便签" : ""
            showToast("已导入 PureRef「\(first.sceneName)」：\(first.importedAssets.count) 张图\(notePart)并生成情绪板", tone: .success)
        } else {
            let notePart = totalNotes > 0 ? "、\(totalNotes) 条便签" : ""
            showToast("已导入 \(results.count) 个 PureRef 场景（\(totalImages) 张图\(notePart)）", tone: .success)
        }
        return results
    }

    func exportAssetsPureRefURL(assetIDs: [UUID], title: String) async -> URL? {
        guard !assetIDs.isEmpty else { return nil }
        let safeTitle = title
            .replacingOccurrences(of: "/", with: "-")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let fileName = (safeTitle.isEmpty ? "Charkle-References" : safeTitle) + ".pur"
        let outURL = FileManager.default.temporaryDirectory.appending(path: fileName)
        do {
            let report = try await engine.exportAssetsToPureRef(assetIDs: assetIDs, title: title, to: outURL)
            MobileHaptics.success()
            showToast("已打包 \(report.imageCount) 张素材为 PureRef (.pur)", tone: .success)
            return report.fileURL
        } catch {
            showToast("导出 PureRef 失败：\(error.localizedDescription)", tone: .error)
            return nil
        }
    }

    func exportBoardPureRefURL(document: MoodboardDocument) async -> URL? {
        let safeTitle = document.title
            .replacingOccurrences(of: "/", with: "-")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let fileName = (safeTitle.isEmpty ? "Charkle-Moodboard" : safeTitle) + ".pur"
        let outURL = FileManager.default.temporaryDirectory.appending(path: fileName)
        do {
            let report = try await engine.exportMoodboardToPureRef(board: document, to: outURL)
            MobileHaptics.success()
            showToast("已导出情绪板为 PureRef (.pur)", tone: .success)
            return report.fileURL
        } catch {
            showToast("导出 PureRef 失败：\(error.localizedDescription)", tone: .error)
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
        let durationSeconds: Double = actionTitle != nil ? 5.2 : 3.0
        toastDismissTask = Task {
            try? await Task.sleep(for: .seconds(durationSeconds))
            guard !Task.isCancelled else { return }
            withAnimation(MobileMotion.exitSm) {
                toast = nil
            }
        }
    }

    func dismissToast() {
        toastDismissTask?.cancel()
        toastDismissTask = nil
        withAnimation(MobileMotion.exitSm) {
            toast = nil
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
