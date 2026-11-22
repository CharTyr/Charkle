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
        didSet { assetsRevision &+= 1 }
    }
    public private(set) var assetsRevision: Int = 0
    public var allAssetsByID: [UUID: AssetRecord] = [:]
    public private(set) var cachedRecentActivityAssets: [AssetRecord] = []
    public var folders: [FolderRecord] = []
    public var smartFolders: [SmartFolderRecord] = []
    public var activeSmartFolderID: UUID?
    public var tagCounts: [TagCount] = []
    public var inboxCount: Int = 0

    public var filter: FilterCriteria = FilterCriteria()
    public var selectedAssetIDs: Set<UUID> = []
    public var cutAssetIDs: Set<UUID> = []
    public var copiedAssetIDs: [UUID] = []
    private var lastInternalPasteboardChangeCount: Int?

    public var similarAssets: [ScoredAsset] = []
    public var suggestedFolder: FolderSuggestion?

    // Phase 2: Hybrid Semantic Search & Inbox Smart Batch Triage
    public var semanticSearchEnabled: Bool = false
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
    public var enrichingAssetIDs: Set<UUID> = []
    public var enrichCompletedCount: Int = 0
    public var enrichTotalCount: Int = 0
    public var isEnrichingTags: Bool { !enrichingAssetIDs.isEmpty }
    public var lastError: String?

    private var inspectorContextTask: Task<Void, Never>?
    private var retagTask: Task<RetagBatchOutcome, Never>?
    @ObservationIgnored private var enrichmentObserver: NSObjectProtocol?
    private static let recentTagsDefaultsKey = "com.charkle.recentlyTouchedTags"
    private static let tagUsageFreqDefaultsKey = "com.charkle.tagUsageFrequency"
    private var recentlyTouchedTags: [String] = []
    private var tagUsageFrequency: [String: Int] = [:]

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
                await self?.refreshAll()
            }
        }
    }

    isolated deinit {
        if let observer = enrichmentObserver {
            NotificationCenter.default.removeObserver(observer)
        }
    }

    public var primarySelectedAsset: AssetRecord? {
        guard selectedAssetIDs.count == 1, let id = selectedAssetIDs.first else { return nil }
        return assets.first(where: { $0.id == id }) ?? allAssetsByID[id]
    }

    public var selectedAssets: [AssetRecord] {
        assets.filter { selectedAssetIDs.contains($0.id) }
    }

    public func bootstrap() async {
        isLoading = true
        defer { isLoading = false }
        do {
            _ = try await engine.seedSampleLibraryIfEmpty()
            await refreshAll()
        } catch {
            lastError = error.localizedDescription
            libraryStoreLogger.error("Bootstrap failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    public func applyDestination(_ destination: SidebarDestination) async {
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
        case .moodboardsHome, .moodboard:
            return
        }

        selectedAssetIDs.removeAll()
        await refreshAssets()
    }

    public func refreshAll() async {
        do {
            async let fetchedAssets = engine.fetchAssets(matching: filter)
            async let fetchedAll = engine.fetchAssets(matching: FilterCriteria(includeTrashed: true))
            async let fetchedFolders = engine.fetchFolders()
            async let fetchedSmartFolders = engine.fetchSmartFolders()
            async let fetchedTags = engine.fetchTagCounts()
            async let fetchedInbox = engine.inboxCount()

            let (visible, all, folderList, smartList, tags, inbox) = try await (
                fetchedAssets, fetchedAll, fetchedFolders, fetchedSmartFolders, fetchedTags, fetchedInbox
            )
            smartFolders = smartList
            allAssetsByID = Dictionary(uniqueKeysWithValues: all.map { ($0.id, $0) })
            rebuildRecentActivityCache()
            assets = applyActiveSmartFolderIfNeeded(visible)
            folders = folderList
            tagCounts = sortTagCounts(tags)
            inboxCount = inbox
        } catch {
            lastError = error.localizedDescription
            libraryStoreLogger.error("refreshAll failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    public func refreshAssets() async {
        do {
            let fetched = try await engine.fetchAssets(matching: filter)
            assets = applyActiveSmartFolderIfNeeded(fetched)
            for asset in assets {
                allAssetsByID[asset.id] = asset
            }
        } catch {
            lastError = error.localizedDescription
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
        allAssetsByID.values.reduce(into: 0) { count, asset in
            if smartFolder.rule.matches(asset) { count += 1 }
        }
    }

    public func matchingCount(for rule: SmartFolderRule) -> Int {
        allAssetsByID.values.reduce(into: 0) { count, asset in
            if rule.matches(asset) { count += 1 }
        }
    }

    /// Top 10 tags strictly by asset count for Sidebar quick access.
    public var topTenSidebarTags: [TagCount] {
        Array(tagCounts.sorted {
            if $0.count != $1.count { return $0.count > $1.count }
            return $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
        }.prefix(10))
    }

    /// Up to 5 recently & frequently used tags for Sidebar quick access.
    public var recentFrequentSidebarTags: [TagCount] {
        let byLower = Dictionary(uniqueKeysWithValues: tagCounts.map { ($0.name.lowercased(), $0) })
        let ranked = recentlyTouchedTags.enumerated().compactMap { index, name -> (TagCount, Double)? in
            guard let item = byLower[name.lowercased()] else { return nil }
            let recencyBonus = Double(max(0, 60 - index)) * 1.5
            let freqBonus = Double(tagUsageFrequency[name.lowercased()] ?? 1) * 4.0
            return (item, recencyBonus + freqBonus)
        }
        var seen = Set<String>()
        var result: [TagCount] = []
        for (item, _) in ranked.sorted(by: { $0.1 > $1.1 }) {
            if seen.insert(item.name.lowercased()).inserted {
                result.append(item)
                if result.count >= 5 { break }
            }
        }
        return result
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
        if var existing = allAssetsByID[id] {
            existing.lastOpenedAt = now
            allAssetsByID[id] = existing
        }
        if let idx = assets.firstIndex(where: { $0.id == id }) {
            assets[idx].lastOpenedAt = now
        }
        if let existing = allAssetsByID[id], !existing.isTrashed {
            cachedRecentActivityAssets.removeAll { $0.id == id }
            cachedRecentActivityAssets.insert(existing, at: 0)
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
            if let idx = assets.firstIndex(where: { $0.id == updated.id }) {
                assets[idx] = updated
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
        guard let post = postAsset.richMetadata?.socialPost,
              let mediaURL = URL(string: attachment.url) else { return nil }
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
            if attachment.kind == .video || attachment.kind == .gif {
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

            let attributionNotes = [
                "来源推文：\(post.authorName) (@\(post.authorHandle)) · \(post.platform.displayName)",
                post.bodyText.trimmingCharacters(in: .whitespacesAndNewlines),
                "原推文链接：\(post.originalURL)"
            ].filter { !$0.isEmpty }.joined(separator: "\n\n")

            let extractedTitle = "@\(post.authorHandle) \(attachment.kind.localizedLabel) #\(index + 1)"
            let patched = try await engine.updateAssets(
                AssetBatchPatch(
                    assetIDs: [standalone.id],
                    title: extractedTitle,
                    notes: attributionNotes,
                    addTags: [post.platform.displayName]
                )
            )
            var finalAsset = patched.first ?? standalone
            if finalAsset.sourceURL == nil {
                finalAsset.sourceURL = post.originalURL
                finalAsset.sourceDomain = URL(string: post.originalURL)?.host()
            }
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
            folders = folderList
            smartFolders = smartList
            tagCounts = sortTagCounts(tags)
            inboxCount = inbox
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
        let subtreeSet = Set(descendantFolderIDsPostOrder(rootID: folderID))
        let folderAssets = allAssetsByID.values.filter { !$0.isTrashed && $0.folderID.map { subtreeSet.contains($0) } == true }
        return !folderAssets.isEmpty && folderAssets.allSatisfy(\.pinnedOffline)
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
        await applyPatch(AssetBatchPatch(assetIDs: targetAssetIDs, pinnedOffline: pinned))
        if !pinned {
            _ = try? await engine.evictCacheNow()
            await refreshAll()
        }
        return targetAssetIDs.count
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
        let subtreeSet = Set(descendantFolderIDsPostOrder(rootID: folderID))
        return allAssetsByID.values.filter { !$0.isTrashed && $0.folderID.map { subtreeSet.contains($0) } == true }.count
    }

    private func descendantFolderIDsPostOrder(rootID: UUID) -> [UUID] {
        let byParent = Dictionary(grouping: folders) { $0.parentID }
        var result: [UUID] = []
        var visited = Set<UUID>()
        func visit(_ id: UUID) {
            guard visited.insert(id).inserted else { return }
            for child in byParent[id] ?? [] {
                visit(child.id)
            }
            result.append(id)
        }
        visit(rootID)
        return result
    }

    // MARK: - Finder Reveal, Copy, Cut & Paste Move

    /// Resolves the best local file URL to reveal in Finder: prefers the human-readable file in the user's
    /// configured local library folder if present, falling back to the cached original file.
    public func resolveFinderFileURL(for assetID: UUID) async -> URL? {
        if let asset = allAssetsByID[assetID] {
            let syncCfg = await engine.syncConfig()
            if syncCfg.mode == .localOnly {
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
        writeFilesToGeneralPasteboard(urls)
        copiedAssetIDs = ids
        cutAssetIDs.removeAll()
        lastInternalPasteboardChangeCount = NSPasteboard.general.changeCount
        return max(urls.count, ids.count)
    }

    @discardableResult
    public func cutAssets(_ ids: [UUID]) async -> Int {
        guard !ids.isEmpty else { return 0 }
        let urls = await resolveURLs(for: ids)
        writeFilesToGeneralPasteboard(urls)
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
        cutAssetIDs.removeAll()
        if copiedAssetIDs.isEmpty {
            lastInternalPasteboardChangeCount = nil
        }
        await moveAssets(ids, toFolderID: folderID)
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
        var objects: [any NSPasteboardWriting] = urls.map { $0 as NSURL }
        if urls.count == 1, let single = urls.first, let image = NSImage(contentsOf: single) {
            objects.append(image)
        }
        pb.writeObjects(objects)
    }

    public func childFolders(of parentID: UUID?) -> [FolderRecord] {
        folders
            .filter { $0.parentID == parentID }
            .sorted { lhs, rhs in
                if lhs.sortOrder != rhs.sortOrder { return lhs.sortOrder < rhs.sortOrder }
                let cmp = lhs.name.localizedCaseInsensitiveCompare(rhs.name)
                if cmp != .orderedSame { return cmp == .orderedAscending }
                return lhs.id.uuidString < rhs.id.uuidString
            }
    }

    public func folderBreadcrumbs(for folderID: UUID) -> [FolderRecord] {
        let byID = Dictionary(uniqueKeysWithValues: folders.map { ($0.id, $0) })
        var chain: [FolderRecord] = []
        var visited = Set<UUID>()
        var cursor: UUID? = folderID
        while let id = cursor, visited.insert(id).inserted, let folder = byID[id] {
            chain.append(folder)
            cursor = folder.parentID
        }
        return chain.reversed()
    }

    public func folderDisplayPath(for folderID: UUID) -> String {
        let crumbs = folderBreadcrumbs(for: folderID)
        return crumbs.isEmpty ? "文件夹" : crumbs.map(\.name).joined(separator: " / ")
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

    // MARK: - Asset Patching & Batch Operations

    public func applyPatch(_ patch: AssetBatchPatch) async {
        guard !patch.assetIDs.isEmpty else { return }
        do {
            let updated = try await engine.updateAssets(patch)
            for item in updated {
                allAssetsByID[item.id] = item
            }
            await refreshAll()
        } catch {
            lastError = error.localizedDescription
        }
    }

    public func moveAssets(_ ids: [UUID], toFolderID folderID: UUID?) async {
        let assignment: FolderAssignment = folderID.map { .folder($0) } ?? .inbox
        await applyPatch(AssetBatchPatch(assetIDs: ids, folderAssignment: assignment))
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
        await applyPatch(AssetBatchPatch(assetIDs: ids, isTrashed: true))
        selectedAssetIDs.subtract(ids)
    }

    public func restoreAssets(_ ids: [UUID]) async {
        await applyPatch(AssetBatchPatch(assetIDs: ids, isTrashed: false))
        selectedAssetIDs.subtract(ids)
    }

    public func permanentlyDeleteAssets(_ ids: [UUID]) async {
        guard !ids.isEmpty else { return }
        do {
            try await engine.permanentlyDeleteAssets(ids: ids)
            for id in ids {
                allAssetsByID.removeValue(forKey: id)
                thumbnailLoader.invalidate(assetID: id)
            }
            selectedAssetIDs.subtract(ids)
            await refreshAll()
        } catch {
            lastError = error.localizedDescription
        }
    }

    // MARK: - Inspector Intelligence & Quick Jump

    public func refreshInspectorContext(for assetID: UUID?) {
        inspectorContextTask?.cancel()
        guard let assetID else {
            similarAssets = []
            suggestedFolder = nil
            return
        }
        inspectorContextTask = Task { [weak self] in
            guard let self else { return }
            do {
                async let sim = self.engine.similarAssets(to: assetID, limit: 8)
                async let suggestion = self.engine.suggestFolder(for: assetID)
                let (simRes, folderRes) = try await (sim, suggestion)
                guard !Task.isCancelled else { return }
                self.similarAssets = simRes
                self.suggestedFolder = folderRes
            } catch {
                // Non-fatal in inspector context
            }
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
        let task = Task<RetagBatchOutcome, Never> { @MainActor in
            let total = targets.count
            enrichingAssetIDs = Set(targets)
            enrichCompletedCount = 0
            enrichTotalCount = total
            defer {
                enrichingAssetIDs.removeAll()
                enrichCompletedCount = 0
                enrichTotalCount = 0
                retagTask = nil
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
                    enrichingAssetIDs.remove(assetID)
                    enrichCompletedCount += 1
                    switch outcome {
                    case .success(let updated):
                        if !updated.isEmpty {
                            succeeded += updated.count
                            for item in updated {
                                allAssetsByID[item.id] = item
                                if let idx = assets.firstIndex(where: { $0.id == item.id }) {
                                    assets[idx] = item
                                }
                            }
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

    // MARK: - Hybrid Semantic Search

    @discardableResult
    public func runSemanticSearch(query: String? = nil) async -> SemanticSearchReport? {
        let resolvedQuery = (query ?? filter.searchQuery).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !resolvedQuery.isEmpty else {
            await clearSemanticSearch()
            return nil
        }
        isRunningSemanticSearch = true
        lastError = nil
        defer { isRunningSemanticSearch = false }
        do {
            let report = try await engine.semanticSearch(query: resolvedQuery, criteria: filter, limit: 60)
            semanticSearchReport = report
            assets = report.hits.map(\.asset)
            for asset in assets { allAssetsByID[asset.id] = asset }
            return report
        } catch {
            lastError = error.localizedDescription
            return nil
        }
    }

    public func clearSemanticSearch() async {
        semanticSearchReport = nil
        await refreshAssets()
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
        var byFolder: [UUID: [UUID]] = [:]
        for rec in selected {
            guard let fid = rec.recommendedFolderID else { continue }
            byFolder[fid, default: []].append(rec.assetID)
        }
        for (folderID, ids) in byFolder {
            await moveAssets(ids, toFolderID: folderID)
            moved += ids.count
        }
        inboxTriageRecommendations = []
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
}
