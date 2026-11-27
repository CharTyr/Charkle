import AppKit
import CharkleCanvas
import CharkleCore
import Foundation
import os

private let libraryStoreLogger = Logger(subsystem: "com.charkle.app", category: "LibraryStore")

/// Domain store for the visual reference library, inbox triage, folders, tags, filtering,
/// multi-selection, batch editing, and asset ingestion.
@Observable
public final class LibraryStore {
    public let engine: any CharkleEngineProtocol
    public let thumbnailLoader: ThumbnailImageLoader

    public var assets: [AssetRecord] = [] {
        didSet {
            if !isUpdatingAssetsInPlace {
                rebuildVisibleAssetIndex()
            }
            if !suppressAssetsRevisionIncrement {
                assetsRevision &+= 1
            }
        }
    }
    public private(set) var assetsRevision: Int = 0
    public var allAssetsByID: [UUID: AssetRecord] = [:] {
        didSet {
            if !isBatchUpdating && !suppressDerivedAssetRebuild {
                rebuildAssetDerivedCaches()
            }
        }
    }
    public private(set) var cachedRecentActivityAssets: [AssetRecord] = []
    public private(set) var activeAssetCount: Int = 0
    public private(set) var untaggedAssetCount: Int = 0
    public var folders: [FolderRecord] = [] {
        didSet {
            if !isBatchUpdating {
                rebuildFolderDerivedCaches()
                rebuildFolderAssetRollupCaches()
            }
        }
    }
    public var smartFolders: [SmartFolderRecord] = [] {
        didSet {
            if !isBatchUpdating {
                rebuildSmartFolderCountCaches()
            }
        }
    }
    public var activeSmartFolderID: UUID?
    public var tagCounts: [TagCount] = [] {
        didSet {
            if !isBatchUpdating {
                rebuildSidebarTagCaches()
            }
        }
    }
    public var inboxCount: Int = 0

    // Precomputed observable derived caches (O(1) reads during SwiftUI view body passes)
    private var cachedSubtreeAssetCounts: [UUID: Int] = [:]
    private var cachedSubtreePinnedOffline: [UUID: Bool] = [:]
    private var cachedSmartFolderCounts: [UUID: Int] = [:]
    private var cachedFolderByID: [UUID: FolderRecord] = [:]
    private var cachedChildFoldersByParent: [UUID?: [FolderRecord]] = [:]
    private var cachedFolderHierarchyRoots: [FolderHierarchyNode] = []
    private var cachedFlattenedFolderHierarchy: [FolderHierarchyNode] = []
    private var cachedFolderBreadcrumbs: [UUID: [FolderRecord]] = [:]
    private var cachedFolderDisplayPaths: [UUID: String] = [:]
    private var cachedTopTenSidebarTags: [TagCount] = []
    private var cachedRecentFrequentSidebarTags: [TagCount] = []

    public var filter: FilterCriteria = FilterCriteria()
    public var selectedAssetIDs: Set<UUID> = []
    public var cutAssetIDs: Set<UUID> = []
    public var copiedAssetIDs: [UUID] = []
    private var lastInternalPasteboardChangeCount: Int?

    public var similarAssets: [ScoredAsset] = []
    public var isLoadingSimilarAssets: Bool = false
    public var suggestedFolder: FolderSuggestion?

    // Phase 2: Unified Hybrid Semantic Search & Inbox Smart Batch Triage
    public var isRunningSemanticSearch: Bool = false
    public var semanticSearchReport: SemanticSearchReport?
    public var isRunningInboxTriage: Bool = false
    public var inboxTriageRecommendations: [InboxTriageRecommendation] = []

    public enum RetagBatchOutcome: Sendable {
        case aiDisabled
        case cancelled(completed: Int, total: Int)
        case finished(succeeded: Int, failed: Int, total: Int, firstError: String?)
    }

    public var isLoading: Bool = false
    public private(set) var isMinimalCaptureMode: Bool = false
    public var enrichingAssetIDs: Set<UUID> = []
    public var enrichCompletedCount: Int = 0
    public var enrichTotalCount: Int = 0
    public var isEnrichingTags: Bool { !enrichingAssetIDs.isEmpty }
    public var lastError: String?

    private var inspectorContextTask: Task<Void, Never>?
    @ObservationIgnored private var inspectorContextAssetID: UUID?
    @ObservationIgnored private var inspectorContextLoaded: Bool = false
    @ObservationIgnored private var metadataHydrationAttemptedIDs: Set<UUID> = []
    @ObservationIgnored private var imageMetadataCache: [UUID: ExtractedImageMetadata] = [:]
    private var retagTask: Task<RetagBatchOutcome, Never>?
    @ObservationIgnored private var activeRetagBatchID: UUID?
    @ObservationIgnored private var assetsRequestGeneration: UInt64 = 0
    @ObservationIgnored private var fullRefreshGeneration: UInt64 = 0
    @ObservationIgnored private var minimalRefreshGeneration: UInt64 = 0
    @ObservationIgnored private var semanticSearchGeneration: UInt64 = 0
    @ObservationIgnored private var semanticEnhancementDelayTask: Task<Void, Never>?
    private var semanticSearchTask: Task<SemanticSearchReport?, Never>?
    @ObservationIgnored private var activeRefreshAllTask: Task<Void, Never>?
    @ObservationIgnored private var activeRefreshAssetsTask: Task<Void, Never>?
    @ObservationIgnored private var enrichmentDebounceTask: Task<Void, Never>?
    @ObservationIgnored private var enrichmentObserver: NSObjectProtocol?
    @ObservationIgnored private var visibleAssetIndexByID: [UUID: Int] = [:]
    @ObservationIgnored private var cachedDirectActiveCountByFolder: [UUID: Int] = [:]
    @ObservationIgnored private var cachedDirectUnpinnedCountByFolder: [UUID: Int] = [:]
    @ObservationIgnored private var cachedDescendantFolderIDsPostOrder: [UUID: [UUID]] = [:]
    @ObservationIgnored private var cachedSmartFolderRulesByID: [UUID: SmartFolderRule] = [:]
    @ObservationIgnored private var isBatchUpdating: Bool = false
    @ObservationIgnored private var isUpdatingAssetsInPlace: Bool = false
    @ObservationIgnored private var suppressAssetsRevisionIncrement: Bool = false
    @ObservationIgnored private var suppressDerivedAssetRebuild: Bool = false
    private static let recentTagsDefaultsKey = "com.charkle.recentlyTouchedTags"
    private static let tagUsageFreqDefaultsKey = "com.charkle.tagUsageFrequency"
    @ObservationIgnored private var recentlyTouchedTags: [String] = []
    @ObservationIgnored private var tagUsageFrequency: [String: Int] = [:]

    public init(engine: any CharkleEngineProtocol) {
        self.engine = engine
        self.thumbnailLoader = ThumbnailImageLoader(engine: engine)
        self.recentlyTouchedTags = UserDefaults.standard.stringArray(forKey: Self.recentTagsDefaultsKey) ?? []
        self.tagUsageFrequency = UserDefaults.standard.dictionary(forKey: Self.tagUsageFreqDefaultsKey) as? [String: Int] ?? [:]
        self.enrichmentObserver = NotificationCenter.default.addObserver(
            forName: CharkleCoreNotifications.libraryDidEnrichInBackground,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self, !self.isMinimalCaptureMode else { return }
                self.scheduleCoalescedEnrichmentRefresh()
            }
        }
    }

    isolated deinit {
        inspectorContextTask?.cancel()
        retagTask?.cancel()
        semanticEnhancementDelayTask?.cancel()
        semanticSearchTask?.cancel()
        activeRefreshAllTask?.cancel()
        activeRefreshAssetsTask?.cancel()
        enrichmentDebounceTask?.cancel()
        if let observer = enrichmentObserver {
            NotificationCenter.default.removeObserver(observer)
        }
    }

    private func scheduleCoalescedEnrichmentRefresh() {
        enrichmentDebounceTask?.cancel()
        enrichmentDebounceTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(250))
            guard !Task.isCancelled, let self, !self.isMinimalCaptureMode else { return }
            self.enrichmentDebounceTask = nil
            await self.refreshAll()
        }
    }

    public var primarySelectedAsset: AssetRecord? {
        guard selectedAssetIDs.count == 1, let id = selectedAssetIDs.first else { return nil }
        let list = assets
        if let idx = visibleAssetIndexByID[id], idx < list.count, list[idx].id == id {
            return list[idx]
        }
        return allAssetsByID[id]
    }

    public var selectedAssets: [AssetRecord] {
        guard !selectedAssetIDs.isEmpty else { return [] }
        let list = assets
        if selectedAssetIDs.count < list.count / 4 {
            var indexed: [(Int, AssetRecord)] = []
            indexed.reserveCapacity(selectedAssetIDs.count)
            for id in selectedAssetIDs {
                if let idx = visibleAssetIndexByID[id], idx < list.count, list[idx].id == id {
                    indexed.append((idx, list[idx]))
                }
            }
            indexed.sort { $0.0 < $1.0 }
            return indexed.map(\.1)
        }
        return list.filter { selectedAssetIDs.contains($0.id) }
    }

    public func bootstrap() async {
        guard !isMinimalCaptureMode else {
            // Minimal Capture Mode only needs tiny folder metadata for the Notch target picker.
            await refreshMinimalMetadataOnly()
            return
        }
        isLoading = true
        defer { isLoading = false }
        do {
            _ = try await engine.seedSampleLibraryIfEmpty()
            await refreshAll()
            Task { [weak self] in
                guard let self else { return }
                let upgradedIDs = await self.engine.upgradeLegacyXiaohongshuCoversIfNeeded()
                guard !upgradedIDs.isEmpty else { return }
                for id in upgradedIDs {
                    self.thumbnailLoader.invalidate(assetID: id)
                }
                await self.refreshAll()
            }
        } catch {
            lastError = error.localizedDescription
            libraryStoreLogger.error("Bootstrap failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    private static let minimalRecentLimit: Int = 16

    /// Drops heavy in-memory full-library asset lists, search results, metadata caches, and decoded image buffers
    /// while keeping only the latest 16 recent items + folder titles so Notch Shelf capture & quick drag-out
    /// remain instant at minimal RAM.
    public func enterMinimalCaptureMode() {
        isMinimalCaptureMode = true
        assetsRequestGeneration &+= 1
        fullRefreshGeneration &+= 1
        semanticSearchGeneration &+= 1
        activeRefreshAllTask?.cancel()
        activeRefreshAllTask = nil
        activeRefreshAssetsTask?.cancel()
        activeRefreshAssetsTask = nil
        enrichmentDebounceTask?.cancel()
        enrichmentDebounceTask = nil
        semanticEnhancementDelayTask?.cancel()
        semanticEnhancementDelayTask = nil
        semanticSearchTask?.cancel()
        semanticSearchTask = nil
        isRunningSemanticSearch = false
        inspectorContextTask?.cancel()
        inspectorContextTask = nil
        inspectorContextAssetID = nil
        inspectorContextLoaded = false
        retagTask?.cancel()
        retagTask = nil
        activeRetagBatchID = nil

        let recentSnapshot = Array(recentActivityAssets(limit: Self.minimalRecentLimit))
        isBatchUpdating = true
        assets = []
        allAssetsByID = Dictionary(uniqueKeysWithValues: recentSnapshot.map { ($0.id, $0) })
        cachedRecentActivityAssets = recentSnapshot
        smartFolders = []
        tagCounts = []
        isBatchUpdating = false
        rebuildAssetDerivedCaches()
        rebuildSidebarTagCaches()

        selectedAssetIDs = []
        cutAssetIDs = []
        copiedAssetIDs = []
        similarAssets = []
        isLoadingSimilarAssets = false
        suggestedFolder = nil
        semanticSearchReport = nil
        inboxTriageRecommendations = []
        imageMetadataCache.removeAll()
        metadataHydrationAttemptedIDs.removeAll()
        thumbnailLoader.setLowResourceMode(true)
    }

    /// Restores full cache budget synchronously when returning to the main studio window.
    /// Call `await refreshAll()` right after to repopulate in-memory asset collections.
    public func exitMinimalCaptureMode() {
        isMinimalCaptureMode = false
        minimalRefreshGeneration &+= 1
        thumbnailLoader.setLowResourceMode(false)
    }

    /// Selects the top `limit` non-trashed assets ordered by `recentActivityDate` in O(N × limit)
    /// without allocating or sorting a full copy of the library.
    private static func selectTopRecentAssets(_ source: [AssetRecord], limit: Int) -> [AssetRecord] {
        guard limit > 0 else { return [] }
        var top: [AssetRecord] = []
        top.reserveCapacity(limit + 1)
        func comesBefore(_ lhs: AssetRecord, _ rhs: AssetRecord) -> Bool {
            let ld = lhs.recentActivityDate
            let rd = rhs.recentActivityDate
            if ld != rd { return ld > rd }
            return lhs.id.uuidString < rhs.id.uuidString
        }
        for asset in source where !asset.isTrashed {
            if top.count == limit, let last = top.last, !comesBefore(asset, last) {
                continue
            }
            var insertIdx = top.count
            while insertIdx > 0 && comesBefore(asset, top[insertIdx - 1]) {
                insertIdx -= 1
            }
            top.insert(asset, at: insertIdx)
            if top.count > limit {
                top.removeLast()
            }
        }
        return top
    }

    /// Lightweight metadata refresh used in Minimal Capture Mode (folders, inbox count, and latest 16 recent items only).
    public func refreshMinimalMetadataOnly() async {
        minimalRefreshGeneration &+= 1
        let gen = minimalRefreshGeneration
        do {
            async let folderList = engine.fetchFolders()
            async let inbox = engine.inboxCount()
            async let fetchedActive = engine.fetchAssets(matching: FilterCriteria(includeTrashed: false, sortBy: .newest))
            let (f, i, active) = try await (folderList, inbox, fetchedActive)
            guard gen == minimalRefreshGeneration, isMinimalCaptureMode else { return }
            let topRecent = Self.selectTopRecentAssets(active, limit: Self.minimalRecentLimit)
            isBatchUpdating = true
            folders = f
            inboxCount = i
            cachedRecentActivityAssets = topRecent
            allAssetsByID = Dictionary(uniqueKeysWithValues: topRecent.map { ($0.id, $0) })
            isBatchUpdating = false
            rebuildFolderDerivedCaches()
            rebuildAssetDerivedCaches()
        } catch {
            if gen == minimalRefreshGeneration {
                lastError = error.localizedDescription
            }
        }
    }

    public func applyDestination(_ destination: SidebarDestination) async {
        semanticSearchGeneration &+= 1
        semanticEnhancementDelayTask?.cancel()
        semanticEnhancementDelayTask = nil
        semanticSearchTask?.cancel()
        semanticSearchTask = nil
        semanticSearchReport = nil
        isRunningSemanticSearch = false

        filter.folderID = nil
        filter.includeSubfolders = false
        filter.onlyInbox = false
        filter.onlyUntagged = false
        filter.onlyRecentDays = nil
        filter.onlyTrashed = false
        filter.includeTrashed = false
        filter.tags.removeAll()
        activeSmartFolderID = nil

        switch destination {
        case .allItems:
            break
        case .inbox:
            filter.onlyInbox = true
        case .untagged:
            filter.onlyUntagged = true
        case .recent:
            filter.onlyRecentDays = 14
            filter.sortBy = .newest
        case .trash:
            filter.onlyTrashed = true
            filter.includeTrashed = true
        case .folder(let folderID):
            filter.folderID = folderID
            filter.includeSubfolders = true
        case .smartFolder(let smartFolderID):
            activeSmartFolderID = smartFolderID
        case .tag(let tagName):
            filter.tags = [tagName]
            recordRecentlyTouchedTags([tagName])
            tagCounts = sortTagCounts(tagCounts)
        case .moodboardsHome, .moodboard, .pinterest:
            assetsRequestGeneration &+= 1
            return
        }

        selectedAssetIDs.removeAll()
        await refreshAssets()
    }

    private static func canDeriveVisibleAssetsInMemory(for criteria: FilterCriteria) -> Bool {
        criteria.searchQuery.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && criteria.selectedColorHex == nil
    }

    private static func filterAssetsInMemory(
        _ all: [AssetRecord],
        matching criteria: FilterCriteria,
        folders: [FolderRecord]
    ) -> [AssetRecord] {
        let folderSubtreeSet: Set<UUID>? = {
            guard let folderID = criteria.folderID else { return nil }
            if !criteria.includeSubfolders { return [folderID] }
            var byParent: [UUID: [UUID]] = [:]
            for folder in folders {
                if let parentID = folder.parentID {
                    byParent[parentID, default: []].append(folder.id)
                }
            }
            var seen: Set<UUID> = [folderID]
            var stack: [UUID] = [folderID]
            while let current = stack.popLast() {
                for childID in byParent[current] ?? [] where seen.insert(childID).inserted {
                    stack.append(childID)
                }
            }
            return seen
        }()
        let recentCutoff: TimeInterval? = criteria.onlyRecentDays.map { days in
            Date().timeIntervalSince1970 - Double(max(0, days)) * 86_400
        }
        return all.filter { asset in
            if criteria.onlyTrashed {
                if !asset.isTrashed { return false }
            } else if !criteria.includeTrashed {
                if asset.isTrashed { return false }
            }
            if criteria.onlyInbox && (asset.folderID != nil || asset.isTrashed) {
                return false
            }
            if let allowedFolders = folderSubtreeSet {
                guard let fid = asset.folderID, allowedFolders.contains(fid) else { return false }
            }
            if let shape = criteria.shape, asset.aspectShape != shape {
                return false
            }
            if criteria.minRating > 0 && asset.rating < criteria.minRating {
                return false
            }
            if criteria.onlyPinnedOffline && !asset.pinnedOffline {
                return false
            }
            if let cutoff = recentCutoff, asset.createdAt.timeIntervalSince1970 < cutoff {
                return false
            }
            if !criteria.kinds.isEmpty && !criteria.kinds.contains(asset.mediaKind) {
                return false
            }
            if criteria.onlyUntagged && asset.tags.contains(where: { !$0.isEmpty }) {
                return false
            }
            if !criteria.tags.isEmpty {
                for tag in criteria.tags where !asset.tags.contains(tag) {
                    return false
                }
            }
            return true
        }
    }

    public func refreshAll() async {
        activeRefreshAllTask?.cancel()
        activeRefreshAssetsTask?.cancel()
        fullRefreshGeneration &+= 1
        let fullGen = fullRefreshGeneration
        assetsRequestGeneration &+= 1
        let assetsGen = assetsRequestGeneration
        let requestedFilter = filter
        let requestedSmartID = activeSmartFolderID
        let deriveInMemory = Self.canDeriveVisibleAssetsInMemory(for: requestedFilter)
        let engine = self.engine

        let task = Task<Void, Never> { @MainActor [weak self] in
            guard let self else { return }
            do {
                let visible: [AssetRecord]
                let all: [AssetRecord]
                let folderList: [FolderRecord]
                let smartList: [SmartFolderRecord]
                let tags: [TagCount]
                let inbox: Int

                if deriveInMemory {
                    async let fetchedAll = engine.fetchAssets(matching: FilterCriteria(includeTrashed: true, sortBy: requestedFilter.sortBy))
                    async let fetchedFolders = engine.fetchFolders()
                    async let fetchedSmartFolders = engine.fetchSmartFolders()
                    async let fetchedTags = engine.fetchTagCounts()
                    async let fetchedInbox = engine.inboxCount()

                    (all, folderList, smartList, tags, inbox) = try await (
                        fetchedAll, fetchedFolders, fetchedSmartFolders, fetchedTags, fetchedInbox
                    )
                    visible = Self.filterAssetsInMemory(all, matching: requestedFilter, folders: folderList)
                } else {
                    async let fetchedAssets = engine.fetchAssets(matching: requestedFilter)
                    async let fetchedAll = engine.fetchAssets(matching: FilterCriteria(includeTrashed: true))
                    async let fetchedFolders = engine.fetchFolders()
                    async let fetchedSmartFolders = engine.fetchSmartFolders()
                    async let fetchedTags = engine.fetchTagCounts()
                    async let fetchedInbox = engine.inboxCount()

                    (visible, all, folderList, smartList, tags, inbox) = try await (
                        fetchedAssets, fetchedAll, fetchedFolders, fetchedSmartFolders, fetchedTags, fetchedInbox
                    )
                }

                guard !Task.isCancelled, !self.isMinimalCaptureMode else { return }
                if fullGen == self.fullRefreshGeneration {
                    let prevAll = self.allAssetsByID
                    var nextAllByID: [UUID: AssetRecord] = Dictionary(minimumCapacity: all.count)
                    for item in all {
                        if let existing = prevAll[item.id], existing == item {
                            nextAllByID[item.id] = existing
                        } else {
                            nextAllByID[item.id] = item
                        }
                    }

                    self.isBatchUpdating = true
                    if self.smartFolders != smartList { self.smartFolders = smartList }
                    self.allAssetsByID = nextAllByID
                    if self.folders != folderList { self.folders = folderList }
                    let sortedTags = self.sortTagCounts(tags)
                    if self.tagCounts != sortedTags { self.tagCounts = sortedTags }
                    if self.inboxCount != inbox { self.inboxCount = inbox }
                    self.isBatchUpdating = false

                    self.rebuildFolderDerivedCaches()
                    self.rebuildAssetDerivedCaches()
                    self.rebuildSidebarTagCaches()
                    self.rebuildRecentActivityCache()
                    self.invalidateInspectorContext()
                }
                if assetsGen == self.assetsRequestGeneration,
                   self.filter == requestedFilter,
                   self.activeSmartFolderID == requestedSmartID {
                    let filtered = self.applyActiveSmartFolderIfNeeded(visible)
                    let canonical = self.canonicalizeAssetsAgainstCache(filtered)
                    self.assets = canonical
                    let trimmedQuery = requestedFilter.searchQuery.trimmingCharacters(in: .whitespacesAndNewlines)
                    if !trimmedQuery.isEmpty {
                        self.scheduleUnifiedSemanticEnhancement(
                            query: trimmedQuery,
                            requestedFilter: requestedFilter,
                            requestedSmartID: requestedSmartID,
                            assetsGen: assetsGen,
                            literalAssets: canonical,
                            delayMilliseconds: 250
                        )
                    }
                }
            } catch {
                if !(error is CancellationError) && fullGen == self.fullRefreshGeneration {
                    self.lastError = error.localizedDescription
                    libraryStoreLogger.error("refreshAll failed: \(error.localizedDescription, privacy: .public)")
                }
            }
        }
        activeRefreshAllTask = task
        await task.value
    }

    public func refreshAssets(semanticEnhancementDelayMs: Int? = 300) async {
        activeRefreshAssetsTask?.cancel()
        semanticEnhancementDelayTask?.cancel()
        semanticEnhancementDelayTask = nil
        semanticSearchTask?.cancel()
        semanticSearchTask = nil
        semanticSearchGeneration &+= 1
        isRunningSemanticSearch = false
        semanticSearchReport = nil

        assetsRequestGeneration &+= 1
        let gen = assetsRequestGeneration
        let requestedFilter = filter
        let requestedSmartID = activeSmartFolderID
        let engine = self.engine

        let task = Task<Void, Never> { @MainActor [weak self] in
            guard let self else { return }
            do {
                let fetched = try await engine.fetchAssets(matching: requestedFilter)
                guard !Task.isCancelled,
                      gen == self.assetsRequestGeneration,
                      !self.isMinimalCaptureMode,
                      self.filter == requestedFilter,
                      self.activeSmartFolderID == requestedSmartID else {
                    return
                }
                let filtered = self.applyActiveSmartFolderIfNeeded(fetched)
                var nextByID = self.allAssetsByID
                var changedAny = false
                var canonical: [AssetRecord] = []
                canonical.reserveCapacity(filtered.count)
                for asset in filtered {
                    if let existing = nextByID[asset.id], existing == asset {
                        canonical.append(existing)
                    } else {
                        nextByID[asset.id] = asset
                        canonical.append(asset)
                        changedAny = true
                    }
                }
                self.assets = canonical
                if changedAny {
                    self.allAssetsByID = nextByID
                }

                let trimmedQuery = requestedFilter.searchQuery.trimmingCharacters(in: .whitespacesAndNewlines)
                if !trimmedQuery.isEmpty, let delayMs = semanticEnhancementDelayMs {
                    self.scheduleUnifiedSemanticEnhancement(
                        query: trimmedQuery,
                        requestedFilter: requestedFilter,
                        requestedSmartID: requestedSmartID,
                        assetsGen: gen,
                        literalAssets: canonical,
                        delayMilliseconds: delayMs
                    )
                }
            } catch {
                if !(error is CancellationError) && gen == self.assetsRequestGeneration {
                    self.lastError = error.localizedDescription
                }
            }
        }
        activeRefreshAssetsTask = task
        await task.value
    }

    private func canonicalizeAssetsAgainstCache(_ list: [AssetRecord]) -> [AssetRecord] {
        list.map { item in
            if let existing = allAssetsByID[item.id], existing == item {
                return existing
            }
            return item
        }
    }

    private func applyActiveSmartFolderIfNeeded(_ list: [AssetRecord]) -> [AssetRecord] {
        guard let smartID = activeSmartFolderID,
              let smart = smartFolders.first(where: { $0.id == smartID }) else {
            return list
        }
        return list.filter { smart.rule.matches($0) }
    }

    public func matchingCount(for smartFolder: SmartFolderRecord) -> Int {
        if let cachedRule = cachedSmartFolderRulesByID[smartFolder.id], cachedRule == smartFolder.rule {
            return cachedSmartFolderCounts[smartFolder.id] ?? 0
        }
        return matchingCount(for: smartFolder.rule)
    }

    public func matchingCount(for rule: SmartFolderRule) -> Int {
        allAssetsByID.values.reduce(into: 0) { count, asset in
            if rule.matches(asset) { count += 1 }
        }
    }

    /// Top 10 tags strictly by asset count for Sidebar quick access (O(1) cached read).
    public var topTenSidebarTags: [TagCount] {
        cachedTopTenSidebarTags
    }

    /// Up to 5 recently & frequently used tags for Sidebar quick access (O(1) cached read).
    public var recentFrequentSidebarTags: [TagCount] {
        cachedRecentFrequentSidebarTags
    }

    /// Rebuilds the cached recent-activity list (called on data mutations, never inside SwiftUI view body).
    private func rebuildRecentActivityCache() {
        cachedRecentActivityAssets = allAssetsByID.values
            .filter { !$0.isTrashed }
            .sorted { lhs, rhs in
                let ld = lhs.recentActivityDate
                let rd = rhs.recentActivityDate
                if ld != rd { return ld > rd }
                return lhs.id.uuidString < rhs.id.uuidString
            }
    }

    /// Recent assets ranked by most recent save or open activity (for the Notch Shelf filmstrip & waterfall).
    public func recentActivityAssets(limit: Int? = nil) -> [AssetRecord] {
        let source = cachedRecentActivityAssets.isEmpty && !allAssetsByID.isEmpty
            ? allAssetsByID.values.filter { !$0.isTrashed }.sorted {
                let ld = $0.recentActivityDate
                let rd = $1.recentActivityDate
                if ld != rd { return ld > rd }
                return $0.id.uuidString < $1.id.uuidString
            }
            : cachedRecentActivityAssets
        if let limit {
            return Array(source.prefix(max(0, limit)))
        }
        return source
    }

    public func markAssetOpened(_ id: UUID) {
        let now = Date()
        var openedAsset: AssetRecord?
        if var existing = allAssetsByID[id] {
            existing.lastOpenedAt = now
            openedAsset = existing
            suppressDerivedAssetRebuild = true
            allAssetsByID[id] = existing
            suppressDerivedAssetRebuild = false
        }
        if let idx = visibleAssetIndexByID[id], idx < assets.count, assets[idx].id == id {
            isUpdatingAssetsInPlace = true
            suppressAssetsRevisionIncrement = true
            assets[idx].lastOpenedAt = now
            suppressAssetsRevisionIncrement = false
            isUpdatingAssetsInPlace = false
            if openedAsset == nil {
                openedAsset = assets[idx]
            }
        }
        if let existing = openedAsset, !existing.isTrashed {
            var nextRecent = cachedRecentActivityAssets
            if let existingIdx = nextRecent.firstIndex(where: { $0.id == id }) {
                nextRecent.remove(at: existingIdx)
            }
            nextRecent.insert(existing, at: 0)
            cachedRecentActivityAssets = nextRecent
        }
        Task {
            await engine.markAssetOpened(id: id)
        }
    }

    @discardableResult
    public func refreshRichAsset(_ id: UUID) async -> AssetRecord? {
        do {
            let updated = try await engine.refreshRichAsset(id: id)
            allAssetsByID[updated.id] = updated
            if let idx = visibleAssetIndexByID[updated.id], idx < assets.count, assets[idx].id == updated.id {
                isUpdatingAssetsInPlace = true
                assets[idx] = updated
                isUpdatingAssetsInPlace = false
            }
            rebuildRecentActivityCache()
            thumbnailLoader.invalidate(assetID: updated.id)
            return updated
        } catch {
            lastError = error.localizedDescription
            return nil
        }
    }

    @discardableResult
    public func updateAssetCoverImage(assetID: UUID, imageData: Data) async -> AssetRecord? {
        do {
            let updated = try await engine.updateAssetCoverImage(id: assetID, imageData: imageData)
            allAssetsByID[updated.id] = updated
            if let idx = visibleAssetIndexByID[updated.id], idx < assets.count, assets[idx].id == updated.id {
                isUpdatingAssetsInPlace = true
                assets[idx] = updated
                isUpdatingAssetsInPlace = false
            }
            rebuildRecentActivityCache()
            thumbnailLoader.invalidate(assetID: updated.id)
            return updated
        } catch {
            lastError = error.localizedDescription
            return nil
        }
    }

    /// Extracts a single photo, video, or GIF from a saved social post (X / Threads / Bluesky)
    /// into a standalone media asset while preserving full originating post author, text, and link.
    @discardableResult
    public func extractMediaFromSocialPost(
        postAsset: AssetRecord,
        attachment: SocialMediaAttachment,
        index: Int
    ) async -> AssetRecord? {
        guard let post = postAsset.richMetadata?.socialPost else { return nil }
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
            let baseName = "\(post.platform.displayName)-\(post.authorHandle)-\(kindTag)\(index + 1)"

            let created: [AssetRecord]
            if post.platform.isVideoPlatform {
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
                    lastError = "无法下载该推文视频，请检查网络或点击原链接观看。"
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
                    lastError = "无法下载该推文图片，请检查网络或点击原链接查看。"
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
                    return "\(post.authorName) (\(handleLine))"
                }
                return post.authorName
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
                if post.platform.isVideoPlatform,
                   let article = post.articleTitle?.trimmingCharacters(in: .whitespacesAndNewlines),
                   !article.isEmpty {
                    return article
                }
                let titleAuthor = (post.platform == .xiaohongshu || post.platform.isVideoPlatform)
                    ? post.authorName
                    : "@\(post.authorHandle)"
                return "\(titleAuthor) \(attachment.kind.localizedLabel) #\(index + 1)"
            }()
            let patched = try await engine.updateAssets(
                AssetBatchPatch(
                    assetIDs: [standalone.id],
                    title: extractedTitle,
                    notes: attributionNotes,
                    sourceURL: post.originalURL,
                    addTags: [post.platform.displayName]
                )
            )
            let finalAsset = patched.first ?? standalone
            allAssetsByID[finalAsset.id] = finalAsset
            await refreshAll()
            return finalAsset
        } catch {
            lastError = error.localizedDescription
            return nil
        }
    }

    /// Extracts all photo & video attachments from a social post into standalone assets with tweet provenance.
    @discardableResult
    public func extractAllMediaFromSocialPost(postAsset: AssetRecord) async -> [AssetRecord] {
        guard let post = postAsset.richMetadata?.socialPost else { return [] }
        let items = post.effectiveAttachments
        guard !items.isEmpty else { return [] }
        var extracted: [AssetRecord] = []
        for (idx, attachment) in items.enumerated() {
            if let asset = await extractMediaFromSocialPost(postAsset: postAsset, attachment: attachment, index: idx) {
                extracted.append(asset)
            }
        }
        return extracted
    }

    /// Extracts a single embedded attachment from a saved webpage bookmark (`WebPageRichMetadata`) into a standalone asset.
    @discardableResult
    public func extractMediaFromWebPageAsset(
        webAsset: AssetRecord,
        attachment: SocialMediaAttachment,
        index: Int
    ) async -> AssetRecord? {
        guard let web = webAsset.richMetadata?.webPage else { return nil }
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
                created = try await engine.ingest(
                    [.fileURL(videoFile)],
                    targetFolderID: webAsset.folderID,
                    targetBoardID: nil
                )
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
                    lastError = "无法下载该网页图片，请检查网络或打开原网页查看。"
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
            if let site = web.siteName, !site.isEmpty {
                notesParts.append("来源网页：\(site)")
            }
            if let summary = web.summary, !summary.isEmpty {
                notesParts.append(summary)
            }
            if !pageURL.isEmpty {
                notesParts.append("原链接：\(pageURL)")
            }
            let title = attachment.kind == .video
                ? webAsset.title
                : "\(webAsset.title) \(attachment.kind.localizedLabel) #\(index + 1)"
            let tags = web.siteName.map { [$0] } ?? []
            let patched = try await engine.updateAssets(
                AssetBatchPatch(
                    assetIDs: [standalone.id],
                    title: title,
                    notes: notesParts.joined(separator: "\n\n"),
                    sourceURL: pageURL.isEmpty ? nil : pageURL,
                    addTags: tags
                )
            )
            let finalAsset = patched.first ?? standalone
            allAssetsByID[finalAsset.id] = finalAsset
            await refreshAll()
            return finalAsset
        } catch {
            lastError = error.localizedDescription
            return nil
        }
    }

    /// Extracts all attachments from any saved social post, YouTube/Bilibili video, or rich webpage bookmark.
    @discardableResult
    public func extractAllMediaFromLinkAsset(_ asset: AssetRecord) async -> [AssetRecord] {
        if asset.richMetadata?.socialPost != nil {
            return await extractAllMediaFromSocialPost(postAsset: asset)
        }
        guard let web = asset.richMetadata?.webPage, !web.attachments.isEmpty else { return [] }
        // For generic webpages, prioritize videos if present; otherwise extract up to 8 hero images
        let targets: [SocialMediaAttachment] = {
            let vids = web.attachments.filter { $0.kind == .video || $0.kind == .gif }
            return !vids.isEmpty ? vids : Array(web.attachments.prefix(8))
        }()
        var extracted: [AssetRecord] = []
        for (idx, att) in targets.enumerated() {
            if let item = await extractMediaFromWebPageAsset(webAsset: asset, attachment: att, index: idx) {
                extracted.append(item)
            }
        }
        return extracted
    }

    /// Batch extracts media from multiple selected links (YouTube, Bilibili, X, Xiaohongshu, Threads, Bluesky, Pixiv, Instagram, or rich webpages).
    @discardableResult
    public func extractMediaFromSelectedLinks(_ targetAssets: [AssetRecord]) async -> (extractedCount: Int, processedLinkCount: Int) {
        let candidates = targetAssets.filter(\.hasExtractableLinkMedia)
        guard !candidates.isEmpty else { return (0, 0) }
        var totalExtracted = 0
        var processed = 0
        for asset in candidates {
            let items = await extractAllMediaFromLinkAsset(asset)
            if !items.isEmpty {
                totalExtracted += items.count
                processed += 1
            }
        }
        return (totalExtracted, processed)
    }

    /// Extracts a single embedded image from a saved social post into a standalone image asset,
    /// preserving full originating post attribution (author, handle, post excerpt, and original post URL).
    @discardableResult
    public func extractImageFromSocialPost(
        postAsset: AssetRecord,
        mediaURLString: String,
        index: Int
    ) async -> AssetRecord? {
        let attachment = SocialMediaAttachment(kind: .photo, url: mediaURLString, thumbnailURL: mediaURLString)
        return await extractMediaFromSocialPost(postAsset: postAsset, attachment: attachment, index: index)
    }

    public func refreshSidebarMetadata() async {
        do {
            async let fetchedFolders = engine.fetchFolders()
            async let fetchedSmartFolders = engine.fetchSmartFolders()
            async let fetchedTags = engine.fetchTagCounts()
            async let fetchedInbox = engine.inboxCount()
            let (folderList, smartList, tags, inbox) = try await (fetchedFolders, fetchedSmartFolders, fetchedTags, fetchedInbox)
            let sortedTags = sortTagCounts(tags)
            isBatchUpdating = true
            if folders != folderList { folders = folderList }
            if smartFolders != smartList { smartFolders = smartList }
            if tagCounts != sortedTags { tagCounts = sortedTags }
            if inboxCount != inbox { inboxCount = inbox }
            isBatchUpdating = false
            rebuildFolderDerivedCaches()
            rebuildFolderAssetRollupCaches()
            rebuildSmartFolderCountCaches()
            rebuildSidebarTagCaches()
        } catch {
            lastError = error.localizedDescription
        }
    }

    // MARK: - Smart Folders CRUD

    public func saveSmartFolder(_ folder: SmartFolderRecord) async {
        do {
            smartFolders = try await engine.saveSmartFolder(folder)
            if activeSmartFolderID == folder.id {
                await refreshAssets()
            }
        } catch {
            lastError = error.localizedDescription
        }
    }

    public func deleteSmartFolder(id: UUID) async {
        do {
            smartFolders = try await engine.deleteSmartFolder(id: id)
            if activeSmartFolderID == id {
                activeSmartFolderID = nil
                await refreshAssets()
            }
        } catch {
            lastError = error.localizedDescription
        }
    }

    public func moveFolder(id: UUID, newParentID: UUID?, insertAtIndex: Int? = nil) async -> Bool {
        do {
            folders = try await engine.moveFolder(id: id, newParentID: newParentID, insertAtIndex: insertAtIndex)
            return true
        } catch {
            lastError = error.localizedDescription
            return false
        }
    }

    public func updateFolderAppearance(id: UUID, colorHex: String?, customSymbol: String?) async {
        do {
            _ = try await engine.updateFolderAppearance(id: id, colorHex: colorHex, customSymbol: customSymbol)
            await refreshSidebarMetadata()
        } catch {
            lastError = error.localizedDescription
        }
    }

    public func isFolderSubtreePinnedOffline(_ folderID: UUID) -> Bool {
        cachedSubtreePinnedOffline[folderID] ?? false
    }

    @discardableResult
    public func setFoldersPinnedOffline(_ folderIDs: [UUID], pinned: Bool) async -> Int {
        var subtreeSet = Set<UUID>()
        for fid in folderIDs {
            subtreeSet.formUnion(descendantFolderIDsPostOrder(rootID: fid))
        }
        let targetAssetIDs = allAssetsByID.values
            .filter { !$0.isTrashed && $0.folderID.map { subtreeSet.contains($0) } == true }
            .map(\.id)
        guard !targetAssetIDs.isEmpty else { return 0 }
        let ok = await applyPatch(AssetBatchPatch(assetIDs: targetAssetIDs, pinnedOffline: pinned))
        return ok ? targetAssetIDs.count : 0
    }

    // MARK: - Folder CRUD

    @discardableResult
    public func createFolder(name: String, parentID: UUID? = nil) async -> FolderRecord? {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        do {
            let folder = try await engine.createFolder(name: trimmed, parentID: parentID)
            await refreshSidebarMetadata()
            return folder
        } catch {
            lastError = error.localizedDescription
            return nil
        }
    }

    public func renameFolder(id: UUID, newName: String) async {
        let trimmed = newName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        do {
            _ = try await engine.renameFolder(id: id, newName: trimmed)
            await refreshSidebarMetadata()
        } catch {
            lastError = error.localizedDescription
        }
    }

    @discardableResult
    public func deleteFolder(id: UUID, trashContents: Bool = false) async -> Int {
        do {
            if !trashContents {
                try await engine.deleteFolder(id: id)
                await refreshAll()
                return 0
            }

            // Collect this folder and all descendant subfolders (children before parents)
            let subtreeIDs = descendantFolderIDsPostOrder(rootID: id)
            let subtreeSet = Set(subtreeIDs)
            let assetIDsToTrash = allAssetsByID.values
                .filter { !$0.isTrashed && $0.folderID.map { subtreeSet.contains($0) } == true }
                .map(\.id)

            if !assetIDsToTrash.isEmpty {
                _ = try await engine.updateAssets(AssetBatchPatch(
                    assetIDs: assetIDsToTrash,
                    folderAssignment: .inbox,
                    isTrashed: true
                ))
                selectedAssetIDs.subtract(assetIDsToTrash)
            }
            for folderID in subtreeIDs {
                try await engine.deleteFolder(id: folderID)
            }
            await refreshAll()
            return assetIDsToTrash.count
        } catch {
            lastError = error.localizedDescription
            return 0
        }
    }

    public func subtreeAssetCount(for folderID: UUID) -> Int {
        cachedSubtreeAssetCounts[folderID] ?? 0
    }

    private func descendantFolderIDsPostOrder(rootID: UUID) -> [UUID] {
        if let cached = cachedDescendantFolderIDsPostOrder[rootID] {
            return cached
        }
        return [rootID]
    }

    // MARK: - Finder Reveal, Copy, Cut & Paste Move

    /// Resolves the best local file URL to reveal in Finder: prefers the human-readable file in the user's
    /// configured local library folder if present, falling back to the cached original file.
    public func resolveFinderFileURL(for assetID: UUID) async -> URL? {
        if let asset = allAssetsByID[assetID] {
            let syncCfg = await engine.syncConfig()
            if syncCfg.mode == .iCloudDrive {
                let custom = syncCfg.iCloudCustomFolderPath.trimmingCharacters(in: .whitespacesAndNewlines)
                let baseDir: URL? = if !custom.isEmpty {
                    URL(fileURLWithPath: (custom as NSString).expandingTildeInPath, isDirectory: true)
                } else if let cloudDocs = ICloudDriveTransport.macOSCloudDocsURL() {
                    cloudDocs.appending(
                        path: syncCfg.iCloudFolderName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "Charkle" : syncCfg.iCloudFolderName,
                        directoryHint: .isDirectory
                    )
                } else {
                    nil
                }
                if var candidate = baseDir {
                    if let folderID = asset.folderID {
                        for crumb in folderBreadcrumbs(for: folderID) {
                            candidate = candidate.appending(path: crumb.name, directoryHint: .isDirectory)
                        }
                    } else {
                        candidate = candidate.appending(path: "Inbox", directoryHint: .isDirectory)
                    }
                    candidate = candidate.appending(path: asset.fileName)
                    if FileManager.default.fileExists(atPath: candidate.path) {
                        return candidate
                    }
                }
            } else if syncCfg.mode == .localOnly {
                let rawRoot = syncCfg.localLibraryPath.trimmingCharacters(in: .whitespacesAndNewlines)
                if !rawRoot.isEmpty {
                    var candidate = URL(fileURLWithPath: (rawRoot as NSString).expandingTildeInPath, isDirectory: true)
                    if let folderID = asset.folderID {
                        for crumb in folderBreadcrumbs(for: folderID) {
                            candidate = candidate.appending(path: crumb.name, directoryHint: .isDirectory)
                        }
                    } else {
                        candidate = candidate.appending(path: "Inbox", directoryHint: .isDirectory)
                    }
                    candidate = candidate.appending(path: asset.fileName)
                    if FileManager.default.fileExists(atPath: candidate.path) {
                        return candidate
                    }
                }
            } else if syncCfg.mode == .gdirectMount || syncCfg.mode == .directAPIWithGDirect {
                let mountRoot = (syncCfg.mountPath as NSString).expandingTildeInPath
                if GDirectIntegration.isMountActive(at: mountRoot) {
                    if let driveID = asset.driveFileID, driveID.hasPrefix("mounted-path:") {
                        let rel = String(driveID.dropFirst("mounted-path:".count))
                        let mountedCandidate = URL(fileURLWithPath: mountRoot, isDirectory: true).appending(path: rel)
                        if FileManager.default.fileExists(atPath: mountedCandidate.path) {
                            return mountedCandidate
                        }
                    }
                    let rootSegments = syncCfg.rootFolderName
                        .split(separator: "/")
                        .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                        .filter { !$0.isEmpty && $0 != "." && $0 != ".." }
                    var candidate = URL(fileURLWithPath: mountRoot, isDirectory: true)
                    for seg in (rootSegments.isEmpty ? ["Charkle"] : rootSegments) {
                        candidate = candidate.appending(path: seg, directoryHint: .isDirectory)
                    }
                    if let folderID = asset.folderID {
                        for crumb in folderBreadcrumbs(for: folderID) {
                            candidate = candidate.appending(path: crumb.name, directoryHint: .isDirectory)
                        }
                    } else {
                        candidate = candidate.appending(path: "Inbox", directoryHint: .isDirectory)
                    }
                    candidate = candidate.appending(path: asset.fileName)
                    if FileManager.default.fileExists(atPath: candidate.path) {
                        return candidate
                    }
                }
            }
        }
        return await resolveOriginalURL(for: assetID)
    }

    @discardableResult
    public func revealInFinder(assetID: UUID) async -> Bool {
        guard let url = await resolveFinderFileURL(for: assetID) else { return false }
        NSWorkspace.shared.activateFileViewerSelecting([url])
        return true
    }

    @discardableResult
    public func copyAssetsToPasteboard(_ ids: [UUID]) async -> Int {
        guard !ids.isEmpty else { return 0 }
        let urls = await resolveURLs(for: ids)
        guard !urls.isEmpty else { return 0 }
        writeFilesToGeneralPasteboard(urls)
        copiedAssetIDs = ids
        cutAssetIDs.removeAll()
        lastInternalPasteboardChangeCount = NSPasteboard.general.changeCount
        return urls.count
    }

    @discardableResult
    public func cutAssets(_ ids: [UUID]) async -> Int {
        guard !ids.isEmpty else { return 0 }
        let urls = await resolveURLs(for: ids)
        if !urls.isEmpty {
            writeFilesToGeneralPasteboard(urls)
        }
        cutAssetIDs = Set(ids)
        copiedAssetIDs.removeAll()
        lastInternalPasteboardChangeCount = NSPasteboard.general.changeCount
        return ids.count
    }

    /// Returns internally copied/cut Charkle asset IDs if the system pasteboard has not been overwritten
    /// externally since the last copy/cut inside Charkle.
    public func internalPasteboardAssets() -> (ids: [UUID], isCut: Bool)? {
        guard let expectedCount = lastInternalPasteboardChangeCount,
              NSPasteboard.general.changeCount == expectedCount else {
            return nil
        }
        if !cutAssetIDs.isEmpty {
            return (Array(cutAssetIDs), true)
        }
        if !copiedAssetIDs.isEmpty {
            return (copiedAssetIDs, false)
        }
        return nil
    }

    @discardableResult
    public func pasteCutAssets(toFolderID folderID: UUID?) async -> Int {
        let ids = Array(cutAssetIDs)
        guard !ids.isEmpty else { return 0 }
        let ok = await moveAssets(ids, toFolderID: folderID)
        guard ok else { return 0 }
        cutAssetIDs.subtract(ids)
        if cutAssetIDs.isEmpty && copiedAssetIDs.isEmpty {
            lastInternalPasteboardChangeCount = nil
        }
        return ids.count
    }

    public func clearCutSelection() {
        cutAssetIDs.removeAll()
        if copiedAssetIDs.isEmpty {
            lastInternalPasteboardChangeCount = nil
        }
    }

    private func resolveURLs(for ids: [UUID]) async -> [URL] {
        var urls: [URL] = []
        for id in ids {
            if let url = await resolveFinderFileURL(for: id) {
                urls.append(url)
            }
        }
        return urls
    }

    private func writeFilesToGeneralPasteboard(_ urls: [URL]) {
        guard !urls.isEmpty else { return }
        let pb = NSPasteboard.general
        pb.clearContents()
        if urls.count == 1, let single = urls.first {
            // Keep fileURL and image pixels on a SINGLE NSPasteboardItem so apps that read
            // pasteboardItems (such as PureRef) never paste duplicate copies of one image,
            // while chat/document apps that read TIFF/PNG data still paste cleanly.
            let item = NSPasteboardItem()
            item.setString(single.absoluteString, forType: .fileURL)
            if let image = NSImage(contentsOf: single) {
                if single.pathExtension.lowercased() == "png",
                   let rawPNG = try? Data(contentsOf: single) {
                    item.setData(rawPNG, forType: .png)
                } else if let tiff = image.tiffRepresentation {
                    item.setData(tiff, forType: .tiff)
                }
            }
            pb.writeObjects([item])
        } else {
            pb.writeObjects(urls.map { $0 as NSURL })
        }
    }

    public func folder(byID folderID: UUID) -> FolderRecord? {
        cachedFolderByID[folderID]
    }

    public func childFolders(of parentID: UUID?) -> [FolderRecord] {
        cachedChildFoldersByParent[parentID] ?? []
    }

    public var folderHierarchyRoots: [FolderHierarchyNode] {
        cachedFolderHierarchyRoots
    }

    public var flattenedFolderHierarchy: [FolderHierarchyNode] {
        cachedFlattenedFolderHierarchy
    }

    public func folderBreadcrumbs(for folderID: UUID) -> [FolderRecord] {
        cachedFolderBreadcrumbs[folderID] ?? []
    }

    public func folderDisplayPath(for folderID: UUID) -> String {
        cachedFolderDisplayPaths[folderID] ?? "文件夹"
    }

    // MARK: - Derived Index Builders

    private func rebuildVisibleAssetIndex() {
        var index: [UUID: Int] = Dictionary(minimumCapacity: assets.count)
        for (idx, asset) in assets.enumerated() {
            index[asset.id] = idx
        }
        visibleAssetIndexByID = index
    }

    private static func flattenHierarchyNodes(_ roots: [FolderHierarchyNode]) -> [FolderHierarchyNode] {
        var result: [FolderHierarchyNode] = []
        func visit(_ list: [FolderHierarchyNode]) {
            for node in list {
                result.append(node)
                visit(node.children)
            }
        }
        visit(roots)
        return result
    }

    private func rebuildFolderDerivedCaches() {
        var byID: [UUID: FolderRecord] = Dictionary(minimumCapacity: folders.count)
        var byParentRaw: [UUID?: [FolderRecord]] = [:]
        for folder in folders {
            byID[folder.id] = folder
            byParentRaw[folder.parentID, default: []].append(folder)
        }
        var byParentSorted: [UUID?: [FolderRecord]] = Dictionary(minimumCapacity: byParentRaw.count)
        for (parentID, children) in byParentRaw {
            byParentSorted[parentID] = FolderHierarchyNode.sortedSiblings(children)
        }
        let roots = FolderHierarchyNode.buildTree(from: folders)
        let flattened = Self.flattenHierarchyNodes(roots)

        var breadcrumbs: [UUID: [FolderRecord]] = Dictionary(minimumCapacity: folders.count)
        var displayPaths: [UUID: String] = Dictionary(minimumCapacity: folders.count)
        var descendants: [UUID: [UUID]] = Dictionary(minimumCapacity: folders.count)

        for folder in folders {
            var chain: [FolderRecord] = []
            var visited = Set<UUID>()
            var cursor: UUID? = folder.id
            while let id = cursor, visited.insert(id).inserted, let node = byID[id] {
                chain.append(node)
                cursor = node.parentID
            }
            let ordered = Array(chain.reversed())
            breadcrumbs[folder.id] = ordered
            displayPaths[folder.id] = ordered.isEmpty ? "文件夹" : ordered.map(\.name).joined(separator: " / ")

            var postOrder: [UUID] = []
            var subVisited = Set<UUID>()
            func visitSubtree(_ id: UUID) {
                guard subVisited.insert(id).inserted else { return }
                for child in byParentSorted[id] ?? [] {
                    visitSubtree(child.id)
                }
                postOrder.append(id)
            }
            visitSubtree(folder.id)
            descendants[folder.id] = postOrder
        }

        cachedDescendantFolderIDsPostOrder = descendants
        if cachedFolderByID != byID { cachedFolderByID = byID }
        if cachedChildFoldersByParent != byParentSorted { cachedChildFoldersByParent = byParentSorted }
        if cachedFolderHierarchyRoots != roots { cachedFolderHierarchyRoots = roots }
        if cachedFlattenedFolderHierarchy != flattened { cachedFlattenedFolderHierarchy = flattened }
        if cachedFolderBreadcrumbs != breadcrumbs { cachedFolderBreadcrumbs = breadcrumbs }
        if cachedFolderDisplayPaths != displayPaths { cachedFolderDisplayPaths = displayPaths }
    }

    private func rebuildAssetDerivedCaches() {
        var nextActive = 0
        var nextUntagged = 0
        var directActive: [UUID: Int] = [:]
        var directUnpinned: [UUID: Int] = [:]
        let currentSmartFolders = smartFolders
        var smartCounts: [UUID: Int] = Dictionary(minimumCapacity: currentSmartFolders.count)
        var smartRules: [UUID: SmartFolderRule] = Dictionary(minimumCapacity: currentSmartFolders.count)
        for sf in currentSmartFolders {
            smartCounts[sf.id] = 0
            smartRules[sf.id] = sf.rule
        }

        for asset in allAssetsByID.values {
            if !asset.isTrashed {
                nextActive += 1
                if asset.tags.isEmpty {
                    nextUntagged += 1
                }
                if let fid = asset.folderID {
                    directActive[fid, default: 0] += 1
                    if !asset.pinnedOffline {
                        directUnpinned[fid, default: 0] += 1
                    }
                }
            }
            if !currentSmartFolders.isEmpty {
                for sf in currentSmartFolders where sf.rule.matches(asset) {
                    smartCounts[sf.id, default: 0] += 1
                }
            }
        }

        cachedDirectActiveCountByFolder = directActive
        cachedDirectUnpinnedCountByFolder = directUnpinned
        cachedSmartFolderRulesByID = smartRules

        if activeAssetCount != nextActive { activeAssetCount = nextActive }
        if untaggedAssetCount != nextUntagged { untaggedAssetCount = nextUntagged }
        if cachedSmartFolderCounts != smartCounts { cachedSmartFolderCounts = smartCounts }
        rebuildFolderAssetRollupCaches()
    }

    private func rebuildFolderAssetRollupCaches() {
        var nextCounts: [UUID: Int] = Dictionary(minimumCapacity: folders.count)
        var nextPinned: [UUID: Bool] = Dictionary(minimumCapacity: folders.count)
        var memoCount: [UUID: Int] = Dictionary(minimumCapacity: folders.count)
        var memoUnpinned: [UUID: Int] = Dictionary(minimumCapacity: folders.count)
        var visiting = Set<UUID>()

        func compute(_ id: UUID) -> (count: Int, unpinned: Int) {
            if let c = memoCount[id], let u = memoUnpinned[id] {
                return (c, u)
            }
            guard visiting.insert(id).inserted else {
                return (0, 0)
            }
            var totalCount = cachedDirectActiveCountByFolder[id] ?? 0
            var totalUnpinned = cachedDirectUnpinnedCountByFolder[id] ?? 0
            if let children = cachedChildFoldersByParent[id] {
                for child in children {
                    let sub = compute(child.id)
                    totalCount += sub.count
                    totalUnpinned += sub.unpinned
                }
            }
            visiting.remove(id)
            memoCount[id] = totalCount
            memoUnpinned[id] = totalUnpinned
            return (totalCount, totalUnpinned)
        }

        for folder in folders {
            let (count, unpinned) = compute(folder.id)
            nextCounts[folder.id] = count
            nextPinned[folder.id] = count > 0 && unpinned == 0
        }
        for (fid, count) in cachedDirectActiveCountByFolder where nextCounts[fid] == nil {
            let unpinned = cachedDirectUnpinnedCountByFolder[fid] ?? 0
            nextCounts[fid] = count
            nextPinned[fid] = count > 0 && unpinned == 0
        }

        if cachedSubtreeAssetCounts != nextCounts { cachedSubtreeAssetCounts = nextCounts }
        if cachedSubtreePinnedOffline != nextPinned { cachedSubtreePinnedOffline = nextPinned }
    }

    private func rebuildSmartFolderCountCaches() {
        let currentSmartFolders = smartFolders
        var smartCounts: [UUID: Int] = Dictionary(minimumCapacity: currentSmartFolders.count)
        var smartRules: [UUID: SmartFolderRule] = Dictionary(minimumCapacity: currentSmartFolders.count)
        for sf in currentSmartFolders {
            smartCounts[sf.id] = 0
            smartRules[sf.id] = sf.rule
        }
        if !currentSmartFolders.isEmpty {
            for asset in allAssetsByID.values {
                for sf in currentSmartFolders where sf.rule.matches(asset) {
                    smartCounts[sf.id, default: 0] += 1
                }
            }
        }
        cachedSmartFolderRulesByID = smartRules
        if cachedSmartFolderCounts != smartCounts { cachedSmartFolderCounts = smartCounts }
    }

    private func rebuildSidebarTagCaches() {
        let nextTopTen = Array(tagCounts.sorted {
            if $0.count != $1.count { return $0.count > $1.count }
            return $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
        }.prefix(10))

        let byLower = Dictionary(
            tagCounts.map { ($0.name.lowercased(), $0) },
            uniquingKeysWith: { lhs, rhs in lhs.count >= rhs.count ? lhs : rhs }
        )
        let ranked = recentlyTouchedTags.enumerated().compactMap { index, name -> (TagCount, Double)? in
            guard let item = byLower[name.lowercased()] else { return nil }
            let recencyBonus = Double(max(0, 60 - index)) * 1.5
            let freqBonus = Double(tagUsageFrequency[name.lowercased()] ?? 1) * 4.0
            return (item, recencyBonus + freqBonus)
        }
        var seen = Set<String>()
        var nextRecentFrequent: [TagCount] = []
        for (item, _) in ranked.sorted(by: { $0.1 > $1.1 }) {
            if seen.insert(item.name.lowercased()).inserted {
                nextRecentFrequent.append(item)
                if nextRecentFrequent.count >= 5 { break }
            }
        }

        if cachedTopTenSidebarTags != nextTopTen { cachedTopTenSidebarTags = nextTopTen }
        if cachedRecentFrequentSidebarTags != nextRecentFrequent { cachedRecentFrequentSidebarTags = nextRecentFrequent }
    }

    // MARK: - Ingestion (Single Source of Truth)

    @discardableResult
    public func ingest(
        _ inputs: [CaptureInput],
        targetFolderID: UUID?,
        targetBoardID: UUID? = nil
    ) async -> [AssetRecord] {
        guard !inputs.isEmpty else { return [] }
        do {
            let created = try await engine.ingest(inputs, targetFolderID: targetFolderID, targetBoardID: targetBoardID)
            if isMinimalCaptureMode {
                // Stay strictly lightweight: prepend newly captured items into the bounded 16-item recent cache
                // and refresh inbox count without hydrating the full library into RAM.
                var nextRecent = created.filter { !$0.isTrashed }
                let createdIDs = Set(nextRecent.map(\.id))
                nextRecent.append(contentsOf: cachedRecentActivityAssets.filter { !createdIDs.contains($0.id) })
                let trimmed = Array(nextRecent.prefix(Self.minimalRecentLimit))
                cachedRecentActivityAssets = trimmed
                allAssetsByID = Dictionary(uniqueKeysWithValues: trimmed.map { ($0.id, $0) })
                inboxCount = (try? await engine.inboxCount()) ?? inboxCount
                return created
            }
            for item in created {
                allAssetsByID[item.id] = item
            }
            await refreshAll()
            return created
        } catch {
            lastError = error.localizedDescription
            libraryStoreLogger.error("Ingest failed: \(error.localizedDescription, privacy: .public)")
            return []
        }
    }

    @discardableResult
    public func importMaterialPackages(
        urls: [URL],
        targetFolderID: UUID? = nil,
        targetBoardID: UUID? = nil
    ) async -> [MaterialPackageImportResult] {
        guard !urls.isEmpty else { return [] }
        lastError = nil
        var results: [MaterialPackageImportResult] = []
        results.reserveCapacity(urls.count)
        var anyImported = false

        for url in urls {
            do {
                let result = try await engine.importMaterialPackage(
                    at: url,
                    targetFolderID: targetFolderID,
                    targetBoardID: targetBoardID
                )
                results.append(result)
                anyImported = anyImported || !result.importedAssets.isEmpty || result.createdFolderCount > 0
                if !isMinimalCaptureMode {
                    for item in result.importedAssets {
                        allAssetsByID[item.id] = item
                    }
                }
            } catch {
                lastError = error.localizedDescription
                libraryStoreLogger.error("Material package import failed for \(url.lastPathComponent, privacy: .public): \(error.localizedDescription, privacy: .public)")
            }
        }

        if anyImported {
            if isMinimalCaptureMode {
                await refreshMinimalMetadataOnly()
            } else {
                await refreshAll()
            }
        }
        return results
    }

    // MARK: - Bidirectional PureRef (.pur) Import & Export

    @discardableResult
    public func importPureRefScenes(
        urls: [URL],
        targetFolderID: UUID? = nil,
        createMoodboard: Bool = true
    ) async -> [PureRefImportResult] {
        guard !urls.isEmpty else { return [] }
        lastError = nil
        var results: [PureRefImportResult] = []
        results.reserveCapacity(urls.count)
        var anyImported = false

        for url in urls {
            do {
                let result = try await engine.importPureRefScene(
                    at: url,
                    targetFolderID: targetFolderID,
                    createMoodboard: createMoodboard
                )
                results.append(result)
                anyImported = anyImported || !result.importedAssets.isEmpty || result.createdBoardID != nil
                if !isMinimalCaptureMode {
                    for item in result.importedAssets {
                        allAssetsByID[item.id] = item
                    }
                }
            } catch {
                lastError = error.localizedDescription
                libraryStoreLogger.error("PureRef import failed for \(url.lastPathComponent, privacy: .public): \(error.localizedDescription, privacy: .public)")
            }
        }

        if anyImported {
            if isMinimalCaptureMode {
                await refreshMinimalMetadataOnly()
            } else {
                await refreshAll()
            }
        }
        return results
    }

    public func exportAssetsToPureRef(
        assetIDs: [UUID],
        title: String,
        to destinationURL: URL
    ) async throws -> PureRefExportReport {
        try await engine.exportAssetsToPureRef(assetIDs: assetIDs, title: title, to: destinationURL)
    }

    public func exportMoodboardToPureRef(
        board: MoodboardDocument,
        to destinationURL: URL
    ) async throws -> PureRefExportReport {
        try await engine.exportMoodboardToPureRef(board: board, to: destinationURL)
    }

    /// Resolves installed PureRef.app on macOS if available (checks bundle ID, `.pur` handler, and standard Applications folders).
    public static func installedPureRefAppURL() -> URL? {
        let standardPaths = [
            "/Applications/PureRef.app",
            (NSHomeDirectory() as NSString).appendingPathComponent("Applications/PureRef.app")
        ]
        for path in standardPaths where FileManager.default.fileExists(atPath: path) {
            return URL(fileURLWithPath: path, isDirectory: true)
        }
        for bundleID in ["com.pureref.PureRef", "com.idyllicpixel.PureRef", "com.pureref.app"] {
            if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) {
                return url
            }
        }
        let probeURL = FileManager.default.temporaryDirectory.appending(path: "charkle-pur-probe.pur")
        if let appURL = NSWorkspace.shared.urlForApplication(toOpen: probeURL),
           appURL.deletingPathExtension().lastPathComponent.localizedCaseInsensitiveContains("pureref") {
            return appURL
        }
        return nil
    }

    /// Returns a clean temporary export URL inside Charkle's cache directory for one-click "Open in PureRef".
    public static func stagedPureRefExportURL(title: String) throws -> URL {
        let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        let dir = caches.appending(path: "Charkle/PureRefExports", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let sanitized = title
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "/", with: "-")
            .replacingOccurrences(of: ":", with: "-")
        let stem = sanitized.isEmpty ? "Charkle-References" : String(sanitized.prefix(64))
        let stamp = Int(Date().timeIntervalSince1970)
        return dir.appending(path: "\(stem)-\(stamp).pur")
    }

    // MARK: - Asset Patching & Batch Operations

    private func canApplyPatchInMemory(_ patch: AssetBatchPatch) -> Bool {
        guard !isMinimalCaptureMode else { return false }
        guard patch.folderAssignment == .unchanged else { return false }
        guard patch.isTrashed == nil else { return false }
        guard patch.addTags.isEmpty && patch.removeTags.isEmpty && !patch.acceptSuggestedTags else { return false }
        if patch.pinnedOffline != nil && filter.onlyPinnedOffline { return false }
        if !filter.searchQuery.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return false }
        if activeSmartFolderID != nil { return false }
        if patch.rating != nil && (filter.minRating > 0 || filter.sortBy == .ratingDesc) { return false }
        if patch.title != nil && filter.sortBy == .nameAsc { return false }
        return true
    }

    @discardableResult
    public func applyPatch(_ patch: AssetBatchPatch) async -> Bool {
        guard !patch.assetIDs.isEmpty else { return false }
        do {
            let updated = try await engine.updateAssets(patch)
            guard !updated.isEmpty else { return true }

            if canApplyPatchInMemory(patch) {
                let updatedByID = Dictionary(uniqueKeysWithValues: updated.map { ($0.id, $0) })
                let needsDerivedAssetRebuild = patch.pinnedOffline != nil || !smartFolders.isEmpty
                var nextAll = allAssetsByID
                for item in updated {
                    nextAll[item.id] = item
                }
                if !needsDerivedAssetRebuild {
                    suppressDerivedAssetRebuild = true
                }
                allAssetsByID = nextAll
                if !needsDerivedAssetRebuild {
                    suppressDerivedAssetRebuild = false
                }

                let affectsGalleryCardVisuals = patch.title != nil
                    || patch.rating != nil
                    || patch.pinnedOffline != nil
                    || patch.sourceURL != nil
                var nextAssets = assets
                var visibleChanged = false
                for item in updated {
                    if let idx = visibleAssetIndexByID[item.id], idx < nextAssets.count, nextAssets[idx].id == item.id {
                        if nextAssets[idx] != item {
                            nextAssets[idx] = item
                            visibleChanged = true
                        }
                    }
                }
                if visibleChanged {
                    isUpdatingAssetsInPlace = true
                    if !affectsGalleryCardVisuals {
                        suppressAssetsRevisionIncrement = true
                    }
                    assets = nextAssets
                    if !affectsGalleryCardVisuals {
                        suppressAssetsRevisionIncrement = false
                    }
                    isUpdatingAssetsInPlace = false
                }

                if !cachedRecentActivityAssets.isEmpty {
                    var nextRecent = cachedRecentActivityAssets
                    var recentChanged = false
                    for idx in nextRecent.indices {
                        if let replacement = updatedByID[nextRecent[idx].id], nextRecent[idx] != replacement {
                            nextRecent[idx] = replacement
                            recentChanged = true
                        }
                    }
                    if recentChanged {
                        cachedRecentActivityAssets = nextRecent
                    }
                }

                if let activeID = inspectorContextAssetID, updatedByID[activeID] != nil {
                    invalidateInspectorContext()
                }
                return true
            }

            if isMinimalCaptureMode {
                var nextAll = allAssetsByID
                let updatedByID = Dictionary(uniqueKeysWithValues: updated.map { ($0.id, $0) })
                for item in updated {
                    if nextAll[item.id] != nil {
                        nextAll[item.id] = item
                    }
                }
                allAssetsByID = nextAll
                var nextRecent = cachedRecentActivityAssets
                for idx in nextRecent.indices {
                    if let replacement = updatedByID[nextRecent[idx].id] {
                        nextRecent[idx] = replacement
                    }
                }
                cachedRecentActivityAssets = nextRecent.filter { !$0.isTrashed }
                return true
            }

            var nextAll = allAssetsByID
            for item in updated {
                nextAll[item.id] = item
            }
            suppressDerivedAssetRebuild = true
            allAssetsByID = nextAll
            suppressDerivedAssetRebuild = false
            await refreshAll()
            return true
        } catch {
            lastError = error.localizedDescription
            return false
        }
    }

    @discardableResult
    public func moveAssets(_ ids: [UUID], toFolderID folderID: UUID?) async -> Bool {
        let assignment: FolderAssignment = folderID.map { .folder($0) } ?? .inbox
        return await applyPatch(AssetBatchPatch(assetIDs: ids, folderAssignment: assignment))
    }

    public func setRating(_ rating: Int, for ids: [UUID]) async {
        await applyPatch(AssetBatchPatch(assetIDs: ids, rating: max(0, min(5, rating))))
    }

    public func addTags(_ tags: [String], to ids: [UUID]) async {
        let splitSeparators = CharacterSet(charactersIn: ",，")
        let trimSet = CharacterSet(charactersIn: "#＃").union(.whitespacesAndNewlines)
        let cleaned = tags
            .flatMap { $0.components(separatedBy: splitSeparators) }
            .map { $0.trimmingCharacters(in: trimSet) }
            .filter { !$0.isEmpty }
        guard !cleaned.isEmpty else { return }
        recordRecentlyTouchedTags(cleaned)
        await applyPatch(AssetBatchPatch(assetIDs: ids, addTags: cleaned))
    }

    public func removeTag(_ tag: String, from ids: [UUID]) async {
        await applyPatch(AssetBatchPatch(assetIDs: ids, removeTags: [tag]))
    }

    public func acceptSuggestedTag(_ tag: String, for assetID: UUID) async {
        recordRecentlyTouchedTags([tag])
        await applyPatch(AssetBatchPatch(assetIDs: [assetID], addTags: [tag], dismissSuggestedTags: [tag]))
    }

    public func dismissSuggestedTag(_ tag: String, for assetID: UUID) async {
        await applyPatch(AssetBatchPatch(assetIDs: [assetID], dismissSuggestedTags: [tag]))
    }

    public func clearSuggestedTags(for ids: [UUID]) async {
        let allSuggestions = Array(Set(ids.compactMap { allAssetsByID[$0] }.flatMap(\.suggestedTags)))
        guard !allSuggestions.isEmpty else { return }
        await applyPatch(AssetBatchPatch(assetIDs: ids, dismissSuggestedTags: allSuggestions))
    }

    public func acceptAllSuggestedTags(for ids: [UUID]) async {
        let accepted = ids.compactMap { allAssetsByID[$0] }.flatMap(\.suggestedTags)
        if !accepted.isEmpty {
            recordRecentlyTouchedTags(accepted)
        }
        await applyPatch(AssetBatchPatch(assetIDs: ids, acceptSuggestedTags: true))
    }

    private func recordRecentlyTouchedTags(_ tags: [String]) {
        var next = recentlyTouchedTags
        var freq = tagUsageFrequency
        for raw in tags.reversed() {
            let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { continue }
            next.removeAll { $0.caseInsensitiveCompare(trimmed) == .orderedSame }
            next.insert(trimmed, at: 0)
            freq[trimmed.lowercased(), default: 0] += 1
        }
        if next.count > 60 {
            next = Array(next.prefix(60))
        }
        recentlyTouchedTags = next
        tagUsageFrequency = freq
        UserDefaults.standard.set(next, forKey: Self.recentTagsDefaultsKey)
        UserDefaults.standard.set(freq, forKey: Self.tagUsageFreqDefaultsKey)
        rebuildSidebarTagCaches()
    }

    private func sortTagCounts(_ tags: [TagCount]) -> [TagCount] {
        var recentRank: [String: Int] = [:]
        for (idx, tag) in recentlyTouchedTags.enumerated() {
            let key = tag.lowercased()
            if recentRank[key] == nil {
                recentRank[key] = idx
            }
        }
        return tags.sorted { lhs, rhs in
            if lhs.count != rhs.count { return lhs.count > rhs.count }
            let lr = recentRank[lhs.name.lowercased()]
            let rr = recentRank[rhs.name.lowercased()]
            switch (lr, rr) {
            case (let a?, let b?) where a != b:
                return a < b
            case (_?, nil):
                return true
            case (nil, _?):
                return false
            default:
                return lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
            }
        }
    }

    public func togglePinOffline(ids: [UUID], pinned: Bool) async {
        await applyPatch(AssetBatchPatch(assetIDs: ids, pinnedOffline: pinned))
    }

    public func trashAssets(_ ids: [UUID]) async {
        guard await applyPatch(AssetBatchPatch(assetIDs: ids, isTrashed: true)) else { return }
        let idSet = Set(ids)
        selectedAssetIDs.subtract(idSet)
        cutAssetIDs.subtract(idSet)
        copiedAssetIDs.removeAll { idSet.contains($0) }
    }

    public func restoreAssets(_ ids: [UUID]) async {
        guard await applyPatch(AssetBatchPatch(assetIDs: ids, isTrashed: false)) else { return }
        selectedAssetIDs.subtract(ids)
    }

    public func permanentlyDeleteAssets(_ ids: [UUID]) async {
        guard !ids.isEmpty else { return }
        do {
            try await engine.permanentlyDeleteAssets(ids: ids)
            let idSet = Set(ids)
            for id in idSet {
                allAssetsByID.removeValue(forKey: id)
                thumbnailLoader.invalidate(assetID: id)
            }
            selectedAssetIDs.subtract(idSet)
            cutAssetIDs.subtract(idSet)
            copiedAssetIDs.removeAll { idSet.contains($0) }
            await refreshAll()
        } catch {
            lastError = error.localizedDescription
        }
    }

    // MARK: - Inspector Intelligence & Quick Jump

    public func invalidateInspectorContext() {
        inspectorContextLoaded = false
    }

    public func refreshInspectorContext(for assetID: UUID?) {
        guard let assetID else {
            inspectorContextTask?.cancel()
            inspectorContextTask = nil
            inspectorContextAssetID = nil
            inspectorContextLoaded = false
            if !similarAssets.isEmpty { similarAssets = [] }
            if isLoadingSimilarAssets { isLoadingSimilarAssets = false }
            if suggestedFolder != nil { suggestedFolder = nil }
            return
        }
        if inspectorContextAssetID == assetID && (inspectorContextLoaded || isLoadingSimilarAssets) {
            return
        }
        inspectorContextTask?.cancel()
        inspectorContextAssetID = assetID
        inspectorContextLoaded = false
        isLoadingSimilarAssets = true
        inspectorContextTask = Task { [weak self] in
            guard let self else { return }
            defer {
                if !Task.isCancelled && self.inspectorContextAssetID == assetID {
                    self.isLoadingSimilarAssets = false
                }
            }
            do {
                async let sim = self.engine.similarAssets(to: assetID, limit: 8)
                async let suggestion = self.engine.suggestFolder(for: assetID)
                let (simRes, folderRes) = try await (sim, suggestion)
                guard !Task.isCancelled, self.inspectorContextAssetID == assetID else { return }
                if self.similarAssets != simRes {
                    self.similarAssets = simRes
                }
                if self.suggestedFolder != folderRes {
                    self.suggestedFolder = folderRes
                }
                self.inspectorContextLoaded = true
            } catch {
                // Non-fatal in inspector context
            }
        }
    }

    /// Synchronously resolves EXIF & AI generation metadata on Frame 0 (from DB, memory cache,
    /// or fast local file header read) so switching assets in the Inspector NEVER flashes or shifts cards.
    public func resolvedImageMetadata(for asset: AssetRecord) -> ExtractedImageMetadata {
        if asset.richMetadata?.photoExif != nil || asset.richMetadata?.aiGeneration != nil {
            return ExtractedImageMetadata(
                photoExif: asset.richMetadata?.photoExif,
                aiGeneration: asset.richMetadata?.aiGeneration
            )
        }
        if let cached = imageMetadataCache[asset.id] {
            return cached
        }
        guard asset.mediaKind == .image || asset.mediaKind == .animatedImage || asset.mediaKind == .designFile,
              asset.isLocalOriginalCached,
              let orig = engine.cachedOriginalURL(for: asset) else {
            return ExtractedImageMetadata()
        }
        let extracted = ImageMetadataExtractor.extract(from: orig)
        if imageMetadataCache.count >= 512 {
            imageMetadataCache.removeAll(keepingCapacity: true)
        }
        imageMetadataCache[asset.id] = extracted
        return extracted
    }

    /// Quietly persists already-extracted EXIF & AI prompt metadata into SQLite + FTS in the background
    /// without mutating visible UI arrays or causing layout shifts.
    public func hydrateImageMetadataIfNeeded(for assetID: UUID) async {
        guard metadataHydrationAttemptedIDs.insert(assetID).inserted else { return }
        guard let asset = allAssetsByID[assetID],
              asset.mediaKind == .image || asset.mediaKind == .animatedImage || asset.mediaKind == .designFile,
              asset.richMetadata?.photoExif == nil && asset.richMetadata?.aiGeneration == nil,
              asset.isLocalOriginalCached else {
            return
        }
        if let updated = try? await engine.hydrateImageMetadataIfNeeded(id: assetID) {
            imageMetadataCache[updated.id] = ExtractedImageMetadata(
                photoExif: updated.richMetadata?.photoExif,
                aiGeneration: updated.richMetadata?.aiGeneration
            )
            allAssetsByID[updated.id] = updated
        }
    }

    public func analyzeLocally(ids: [UUID]) async {
        guard !ids.isEmpty else { return }
        do {
            let updated = try await engine.analyzeAssetsLocally(ids: ids)
            for item in updated { allAssetsByID[item.id] = item }
            await refreshAll()
        } catch {
            lastError = error.localizedDescription
        }
    }

    public func enrichWithCloudAI(ids: [UUID]) async {
        _ = await retagAssetsWithCloudAI(ids: ids)
    }

    public func cancelRetagging() {
        retagTask?.cancel()
        retagTask = nil
    }

    /// Re-runs Cloud AI tagging for the selected assets using the current monolingual language format
    /// and existing-tag merging rules, replacing old unaccepted `suggestedTags` while preserving confirmed `tags`.
    @discardableResult
    public func retagAssetsWithCloudAI(ids: [UUID]) async -> RetagBatchOutcome {
        var seen = Set<UUID>()
        let targets = ids.filter { id in
            guard seen.insert(id).inserted else { return false }
            return allAssetsByID[id]?.isTrashed != true
        }
        guard !targets.isEmpty else {
            return .finished(succeeded: 0, failed: 0, total: 0, firstError: nil)
        }

        let aiConfig = await engine.aiConfig()
        guard aiConfig.provider != .disabled else {
            return .aiDisabled
        }

        retagTask?.cancel()
        let batchID = UUID()
        activeRetagBatchID = batchID
        let task = Task<RetagBatchOutcome, Never> { @MainActor in
            let total = targets.count
            enrichingAssetIDs = Set(targets)
            enrichCompletedCount = 0
            enrichTotalCount = total
            defer {
                if activeRetagBatchID == batchID {
                    enrichingAssetIDs.removeAll()
                    enrichCompletedCount = 0
                    enrichTotalCount = 0
                    retagTask = nil
                    activeRetagBatchID = nil
                }
            }

            let engine = self.engine
            let concurrency = min(3, total)
            var succeeded = 0
            var failed = 0
            var firstError: String?

            await withTaskGroup(of: (UUID, Result<[AssetRecord], Error>).self) { group in
                var nextIndex = 0
                func enqueueNext() {
                    guard !Task.isCancelled, nextIndex < total else { return }
                    let assetID = targets[nextIndex]
                    nextIndex += 1
                    group.addTask {
                        do {
                            let updated = try await engine.enrichAssetsWithCloudAI(ids: [assetID])
                            return (assetID, .success(updated))
                        } catch {
                            return (assetID, .failure(error))
                        }
                    }
                }

                for _ in 0..<concurrency {
                    enqueueNext()
                }

                while let (assetID, outcome) = await group.next() {
                    if activeRetagBatchID == batchID {
                        enrichingAssetIDs.remove(assetID)
                        enrichCompletedCount += 1
                    }
                    switch outcome {
                    case .success(let updated):
                        if !updated.isEmpty {
                            succeeded += updated.count
                            var nextAll = allAssetsByID
                            for item in updated {
                                nextAll[item.id] = item
                                if let idx = visibleAssetIndexByID[item.id], idx < assets.count, assets[idx].id == item.id {
                                    isUpdatingAssetsInPlace = true
                                    assets[idx] = item
                                    isUpdatingAssetsInPlace = false
                                }
                            }
                            suppressDerivedAssetRebuild = true
                            allAssetsByID = nextAll
                            suppressDerivedAssetRebuild = false
                        } else {
                            failed += 1
                        }
                    case .failure(let error):
                        if !(error is CancellationError) {
                            failed += 1
                            if firstError == nil {
                                firstError = error.localizedDescription
                            }
                            lastError = error.localizedDescription
                        }
                    }
                    enqueueNext()
                }
            }

            await refreshAll()

            if Task.isCancelled {
                return .cancelled(completed: succeeded, total: total)
            }
            return .finished(succeeded: succeeded, failed: failed, total: total, firstError: firstError)
        }
        retagTask = task
        return await task.value
    }

    public func extractSubjectPalette(for assetID: UUID, query: String? = nil) async -> Result<SubjectPaletteResult, Error> {
        do {
            let result = try await engine.extractSubjectPalette(assetID: assetID, query: query)
            allAssetsByID[result.updatedAsset.id] = result.updatedAsset
            await refreshAssets()
            return .success(result)
        } catch {
            lastError = error.localizedDescription
            return .failure(error)
        }
    }

    public func detectCleanContentBounds(for assetID: UUID) async -> Result<CleanBoundsResult, Error> {
        do {
            let result = try await engine.detectCleanContentBounds(assetID: assetID)
            return .success(result)
        } catch {
            lastError = error.localizedDescription
            return .failure(error)
        }
    }

    // MARK: - Unified Hybrid Semantic Search

    private func scheduleUnifiedSemanticEnhancement(
        query: String,
        requestedFilter: FilterCriteria,
        requestedSmartID: UUID?,
        assetsGen: UInt64,
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
                  assetsGen == self.assetsRequestGeneration,
                  !self.isMinimalCaptureMode,
                  self.filter == requestedFilter,
                  self.activeSmartFolderID == requestedSmartID else {
                return
            }
            let task = Task<SemanticSearchReport?, Never> { @MainActor [weak self] in
                guard let self else { return nil }
                // Delay indicator slightly so fast local-only semantic fusion (~5ms) never flashes a 1-frame spinner.
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
                    let report = try await self.engine.semanticSearch(query: query, criteria: requestedFilter, limit: 80)
                    guard !Task.isCancelled,
                          semGen == self.semanticSearchGeneration,
                          assetsGen == self.assetsRequestGeneration,
                          !self.isMinimalCaptureMode,
                          self.filter == requestedFilter,
                          self.activeSmartFolderID == requestedSmartID else {
                        return nil
                    }
                    self.semanticSearchReport = report
                    let scopedSemantic = self.applyActiveSmartFolderIfNeeded(report.hits.map(\.asset))
                    let merged = SemanticSearchReport.mergeUnifiedAssets(
                        literal: literalAssets,
                        semantic: scopedSemantic,
                        prioritizeSemantic: report.usedTypeSafeJev || report.usedCloudEmbedding
                    )
                    self.applyCanonicalAssetsIfChanged(merged)
                    return report
                } catch {
                    if !Task.isCancelled && semGen == self.semanticSearchGeneration {
                        libraryStoreLogger.debug("Background semantic fusion skipped: \(error.localizedDescription, privacy: .public)")
                    }
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

    private func applyCanonicalAssetsIfChanged(_ list: [AssetRecord]) {
        var nextByID = allAssetsByID
        var changedAny = false
        var canonical: [AssetRecord] = []
        canonical.reserveCapacity(list.count)
        for asset in list {
            if let existing = nextByID[asset.id], existing == asset {
                canonical.append(existing)
            } else {
                nextByID[asset.id] = asset
                canonical.append(asset)
                changedAny = true
            }
        }
        if assets != canonical {
            assets = canonical
        }
        if changedAny {
            allAssetsByID = nextByID
        }
    }

    @discardableResult
    public func runSemanticSearch(query: String? = nil) async -> SemanticSearchReport? {
        let resolvedQuery = (query ?? filter.searchQuery).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !resolvedQuery.isEmpty else {
            await clearSemanticSearch()
            return nil
        }
        semanticEnhancementDelayTask?.cancel()
        semanticEnhancementDelayTask = nil
        semanticSearchTask?.cancel()
        semanticSearchGeneration &+= 1
        assetsRequestGeneration &+= 1
        let semGen = semanticSearchGeneration
        let assetsGen = assetsRequestGeneration
        var draftFilter = filter
        draftFilter.searchQuery = resolvedQuery
        let snapshotFilter = draftFilter
        let requestedSmartID = activeSmartFolderID
        let engine = self.engine

        isRunningSemanticSearch = true
        lastError = nil

        let task = Task<SemanticSearchReport?, Never> { @MainActor [weak self] in
            guard let self else { return nil }
            defer {
                if semGen == self.semanticSearchGeneration {
                    self.isRunningSemanticSearch = false
                    self.semanticSearchTask = nil
                }
            }
            do {
                async let literalFetched = (try? engine.fetchAssets(matching: snapshotFilter)) ?? []
                async let semanticReport = engine.semanticSearch(query: resolvedQuery, criteria: snapshotFilter, limit: 80)
                let (rawLiteral, report) = try await (literalFetched, semanticReport)
                guard !Task.isCancelled,
                      semGen == self.semanticSearchGeneration,
                      assetsGen == self.assetsRequestGeneration,
                      !self.isMinimalCaptureMode,
                      self.activeSmartFolderID == requestedSmartID else {
                    return nil
                }
                self.semanticSearchReport = report
                let scopedLiteral = self.applyActiveSmartFolderIfNeeded(rawLiteral)
                let scopedSemantic = self.applyActiveSmartFolderIfNeeded(report.hits.map(\.asset))
                let merged = SemanticSearchReport.mergeUnifiedAssets(
                    literal: scopedLiteral,
                    semantic: scopedSemantic,
                    prioritizeSemantic: report.usedTypeSafeJev || report.usedCloudEmbedding
                )
                self.applyCanonicalAssetsIfChanged(merged)
                return report
            } catch {
                if !Task.isCancelled && semGen == self.semanticSearchGeneration {
                    self.lastError = error.localizedDescription
                }
                return nil
            }
        }
        semanticSearchTask = task
        return await task.value
    }

    public func clearSemanticSearch() async {
        semanticSearchGeneration &+= 1
        semanticEnhancementDelayTask?.cancel()
        semanticEnhancementDelayTask = nil
        semanticSearchTask?.cancel()
        semanticSearchTask = nil
        isRunningSemanticSearch = false
        semanticSearchReport = nil
        await refreshAssets(semanticEnhancementDelayMs: nil)
    }

    // MARK: - Inbox Smart Batch Triage

    @discardableResult
    public func runInboxBatchTriage(assetIDs: [UUID] = [], maxCount: Int = 24) async -> [InboxTriageRecommendation]? {
        isRunningInboxTriage = true
        lastError = nil
        defer { isRunningInboxTriage = false }
        do {
            let recs = try await engine.batchTriageInbox(assetIDs: assetIDs, maxCount: maxCount)
            inboxTriageRecommendations = recs
            return recs
        } catch {
            lastError = error.localizedDescription
            return nil
        }
    }

    public func applyInboxTriageRecommendations(_ selected: [InboxTriageRecommendation]) async -> Int {
        var moved = 0
        var succeededIDs = Set<UUID>()
        var byFolder: [UUID: [UUID]] = [:]
        for rec in selected {
            guard let fid = rec.recommendedFolderID else { continue }
            byFolder[fid, default: []].append(rec.assetID)
        }
        for (folderID, ids) in byFolder {
            if await moveAssets(ids, toFolderID: folderID) {
                moved += ids.count
                succeededIDs.formUnion(ids)
            }
        }
        if !succeededIDs.isEmpty {
            inboxTriageRecommendations.removeAll { succeededIDs.contains($0.assetID) }
        }
        return moved
    }

    public func quickJump(query: String, limit: Int = 24) async -> [QuickJumpMatch] {
        (try? await engine.quickJump(query: query, limit: limit)) ?? []
    }

    public func resolveOriginalURL(for assetID: UUID) async -> URL? {
        try? await engine.originalURL(for: assetID)
    }

    public func filterByColorHex(_ hex: String) async {
        filter.selectedColorHex = hex.uppercased()
        await refreshAssets()
    }

    // MARK: - Non-AI Multi-Media Smart Deduplication

    public func scanDuplicateAssets(
        scope: DeduplicationScanScope = .allActive,
        sensitivity: DeduplicationSensitivity = .balanced,
        mediaKinds: Set<MediaKind>? = nil,
        onProgress: (@Sendable (DeduplicationScanProgress) async -> Void)? = nil
    ) async -> DeduplicationScanReport? {
        lastError = nil
        do {
            return try await engine.scanDuplicateImages(
                scope: scope,
                sensitivity: sensitivity,
                mediaKinds: mediaKinds,
                onProgress: onProgress
            )
        } catch {
            lastError = error.localizedDescription
            libraryStoreLogger.error("Smart deduplication scan failed: \(error.localizedDescription, privacy: .public)")
            return nil
        }
    }

    public func resolveDuplicateGroups(
        _ plans: [DeduplicationResolutionPlan],
        disposal: DuplicateDisposalMode = .moveToTrash,
        mergeMetadata: Bool = true
    ) async -> DeduplicationCleanupResult? {
        guard !plans.isEmpty else { return nil }
        lastError = nil
        do {
            let result = try await engine.resolveDuplicateGroups(
                plans,
                disposal: disposal,
                mergeMetadata: mergeMetadata
            )
            let removedIDs = Set(plans.flatMap(\.removeAssetIDs))
            selectedAssetIDs.subtract(removedIDs)
            cutAssetIDs.subtract(removedIDs)
            if disposal == .permanentlyDelete {
                for id in removedIDs {
                    thumbnailLoader.invalidate(assetID: id)
                }
            }
            await refreshAll()
            return result
        } catch {
            lastError = error.localizedDescription
            libraryStoreLogger.error("Smart deduplication cleanup failed: \(error.localizedDescription, privacy: .public)")
            return nil
        }
    }
}
