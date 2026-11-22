import Foundation

/// Minimal in-memory stub so CharkleCanvas and CharkleApp compile & preview immediately
/// while the full SQLite/Media/DriveSync/Intelligence engine is built in parallel.
public actor PlaceholderCharkleEngine: CharkleEngineProtocol {
    private var assets: [UUID: AssetRecord] = [:]
    private var folders: [UUID: FolderRecord] = [:]
    private var boards: [UUID: MoodboardDocument] = [:]
    private var currentAIConfig = AIProviderConfig()
    private var currentSyncConfig = DriveSyncConfig()
    private var currentSyncStatus = SyncStatus()
    private var cacheBudgetBytes: Int64 = 10 * 1024 * 1024 * 1024

    public init() {}

    public func fetchAssets(matching criteria: FilterCriteria) async throws -> [AssetRecord] {
        var result = Array(assets.values).filter { asset in
            if criteria.onlyTrashed { return asset.isTrashed }
            if !criteria.includeTrashed && asset.isTrashed { return false }
            if criteria.onlyInbox && asset.folderID != nil { return false }
            if let folderID = criteria.folderID, asset.folderID != folderID { return false }
            if criteria.onlyUntagged && !asset.tags.isEmpty { return false }
            if !criteria.kinds.isEmpty && !criteria.kinds.contains(asset.mediaKind) { return false }
            if let shape = criteria.shape, asset.aspectShape != shape { return false }
            if criteria.minRating > 0 && asset.rating < criteria.minRating { return false }
            if criteria.onlyPinnedOffline && !asset.pinnedOffline { return false }
            if !criteria.tags.isEmpty && !criteria.tags.isSubset(of: Set(asset.tags)) { return false }
            if let hex = criteria.selectedColorHex {
                let target = LabColor.fromHex(hex)
                let matched = asset.dominantColors.contains { $0.deltaE(to: target) <= criteria.colorTolerance }
                if !matched { return false }
            }
            if !criteria.searchQuery.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                let q = criteria.searchQuery.lowercased()
                let hay = ([asset.title, asset.fileName, asset.notes, asset.aiDescription ?? "", asset.ocrText ?? ""] + asset.tags)
                    .joined(separator: " ")
                    .lowercased()
                if !hay.contains(q) { return false }
            }
            return true
        }
        switch criteria.sortBy {
        case .newest, .relevance:
            result.sort { $0.createdAt > $1.createdAt }
        case .oldest:
            result.sort { $0.createdAt < $1.createdAt }
        case .nameAsc:
            result.sort { $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending }
        case .ratingDesc:
            result.sort { $0.rating > $1.rating }
        case .fileSizeDesc:
            result.sort { $0.fileSizeBytes > $1.fileSizeBytes }
        }
        return result
    }

    public func fetchAsset(id: UUID) async throws -> AssetRecord? { assets[id] }

    public func fetchFolders() async throws -> [FolderRecord] {
        folders.values.map { folder in
            var copy = folder
            copy.assetCount = assets.values.filter { !$0.isTrashed && $0.folderID == folder.id }.count
            return copy
        }.sorted { $0.sortOrder < $1.sortOrder }
    }

    public func fetchTagCounts() async throws -> [TagCount] {
        var counts: [String: Int] = [:]
        for asset in assets.values where !asset.isTrashed {
            for tag in asset.tags { counts[tag, default: 0] += 1 }
        }
        return counts.map { TagCount(name: $0.key, count: $0.value) }.sorted { $0.count > $1.count }
    }

    public func inboxCount() async throws -> Int {
        assets.values.filter(\.isInInbox).count
    }

    public func createFolder(name: String, parentID: UUID?) async throws -> FolderRecord {
        let folder = FolderRecord(name: name, parentID: parentID, sortOrder: folders.count)
        folders[folder.id] = folder
        return folder
    }

    public func renameFolder(id: UUID, newName: String) async throws -> FolderRecord {
        guard var folder = folders[id] else { throw DriveTransportError.fileNotFound(id.uuidString) }
        folder.name = newName
        folder.updatedAt = Date()
        folders[id] = folder
        return folder
    }

    public func deleteFolder(id: UUID) async throws {
        folders.removeValue(forKey: id)
        for key in assets.keys where assets[key]?.folderID == id {
            assets[key]?.folderID = nil
        }
    }

    public func ingest(_ inputs: [CaptureInput], targetFolderID: UUID?, targetBoardID: UUID?) async throws -> [AssetRecord] {
        var created: [AssetRecord] = []
        for input in inputs {
            let record: AssetRecord
            switch input {
            case .fileURL(let url):
                let kind = MediaKind.detect(fileExtension: url.pathExtension)
                record = AssetRecord(
                    title: url.deletingPathExtension().lastPathComponent,
                    fileName: url.lastPathComponent,
                    folderID: targetFolderID,
                    mediaKind: kind,
                    dominantColors: [LabColor.fromHex("#4F6D7A"), LabColor.fromHex("#D4A373")]
                )
            case .imageData(let data, let suggestedName, let sourceURL):
                record = AssetRecord(
                    title: suggestedName,
                    fileName: suggestedName,
                    folderID: targetFolderID,
                    mediaKind: .image,
                    fileSizeBytes: Int64(data.count),
                    sourceURL: sourceURL,
                    dominantColors: [LabColor.fromHex("#3D5A80")]
                )
            case .webURL(let url, let title, let notes):
                record = AssetRecord(
                    title: title ?? url.host ?? url.absoluteString,
                    fileName: "\(url.host ?? "bookmark").webloc",
                    folderID: targetFolderID,
                    mediaKind: .webBookmark,
                    sourceURL: url.absoluteString,
                    sourceDomain: url.host,
                    notes: notes ?? "",
                    dominantColors: [LabColor.fromHex("#5C6B73")]
                )
            case .textSnippet(let title, let text, let sourceURL):
                record = AssetRecord(
                    title: title,
                    fileName: "\(title).md",
                    folderID: targetFolderID,
                    mediaKind: .document,
                    sourceURL: sourceURL,
                    notes: text
                )
            case .colorSwatch(let hex, let title):
                record = AssetRecord(
                    title: title ?? hex.uppercased(),
                    fileName: "\(hex).swatch",
                    folderID: targetFolderID,
                    mediaKind: .document,
                    dominantColors: [LabColor.fromHex(hex)]
                )
            }
            assets[record.id] = record
            created.append(record)
        }
        if let boardID = targetBoardID, var board = boards[boardID] {
            for item in created {
                let idx = board.nodes.count
                let node = BoardNode(
                    kind: .assetRef(assetID: item.id, crop: nil, weight: 1, autoplayLoop: item.mediaKind == .animatedImage || item.mediaKind == .video),
                    frame: BoardRect(x: Double((idx % 4) * 260), y: Double((idx / 4) * 240), width: 240, height: 210),
                    zIndex: idx,
                    editorialOrder: idx
                )
                board.nodes.append(node)
            }
            board.updatedAt = Date()
            boards[boardID] = board
        }
        return created
    }

    public func updateAssets(_ patch: AssetBatchPatch) async throws -> [AssetRecord] {
        var updated: [AssetRecord] = []
        for id in patch.assetIDs {
            guard var asset = assets[id] else { continue }
            if let title = patch.title { asset.title = title }
            if let notes = patch.notes { asset.notes = notes }
            if let rating = patch.rating { asset.rating = rating }
            if !patch.addTags.isEmpty {
                asset.tags = Array(Set(asset.tags + patch.addTags)).sorted()
            }
            if !patch.removeTags.isEmpty {
                let removals = Set(patch.removeTags)
                asset.tags.removeAll { removals.contains($0) }
            }
            if patch.acceptSuggestedTags {
                asset.tags = Array(Set(asset.tags + asset.suggestedTags)).sorted()
                asset.suggestedTags.removeAll()
            }
            if !patch.dismissSuggestedTags.isEmpty {
                let dismissed = Set(patch.dismissSuggestedTags)
                asset.suggestedTags.removeAll { dismissed.contains($0) }
            }
            switch patch.folderAssignment {
            case .unchanged: break
            case .inbox: asset.folderID = nil
            case .folder(let folderID): asset.folderID = folderID
            }
            if let pinned = patch.pinnedOffline { asset.pinnedOffline = pinned }
            if let trashed = patch.isTrashed { asset.isTrashed = trashed }
            asset.updatedAt = Date()
            assets[id] = asset
            updated.append(asset)
        }
        return updated
    }

    public func permanentlyDeleteAssets(ids: [UUID]) async throws {
        for id in ids { assets.removeValue(forKey: id) }
    }

    public func quickJump(query: String, limit: Int) async throws -> [QuickJumpMatch] {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        var matches: [QuickJumpMatch] = []
        for board in boards.values where q.isEmpty || board.title.lowercased().contains(q) {
            matches.append(QuickJumpMatch(id: "board-\(board.id)", kind: .moodboard, title: board.title, subtitle: "情绪板 · \(board.nodes.count) 项", targetUUID: board.id, score: 1.0))
        }
        for folder in folders.values where q.isEmpty || folder.name.lowercased().contains(q) {
            matches.append(QuickJumpMatch(id: "folder-\(folder.id)", kind: .folder, title: folder.name, subtitle: "文件夹", targetUUID: folder.id, score: 0.9))
        }
        for asset in assets.values where !asset.isTrashed && (q.isEmpty || asset.title.lowercased().contains(q)) {
            matches.append(QuickJumpMatch(id: "asset-\(asset.id)", kind: .asset, title: asset.title, subtitle: asset.mediaKind.localizedLabel, targetUUID: asset.id, score: 0.8))
        }
        return Array(matches.prefix(limit))
    }

    public func similarAssets(to assetID: UUID, limit: Int) async throws -> [ScoredAsset] {
        Array(assets.values.filter { $0.id != assetID && !$0.isTrashed }.prefix(limit)).map {
            ScoredAsset(asset: $0, score: 0.75, matchReasons: ["色彩接近"])
        }
    }

    public func suggestFolder(for assetID: UUID) async throws -> FolderSuggestion? {
        guard let first = folders.values.first else { return nil }
        return FolderSuggestion(folderID: first.id, folderName: first.name, confidence: 0.6, reason: "默认建议")
    }

    public func thumbnailURL(for assetID: UUID, tier: ThumbnailTier) async -> URL? { nil }

    public func originalURL(for assetID: UUID) async throws -> URL {
        throw DriveTransportError.fileNotFound(assetID.uuidString)
    }

    public func cacheStats() async -> CacheStats { CacheStats(budgetBytes: cacheBudgetBytes) }
    public func setCacheBudgetBytes(_ bytes: Int64) async { cacheBudgetBytes = bytes }
    public func evictCacheNow() async throws -> CacheStats { CacheStats(budgetBytes: cacheBudgetBytes) }

    public func fetchBoards() async throws -> [MoodboardSummary] {
        boards.values.map { board in
            MoodboardSummary(
                id: board.id,
                title: board.title,
                subtitle: board.subtitle,
                mode: board.mode,
                itemCount: board.nodes.count,
                previewAssetIDs: Array(board.referencedAssetIDs.prefix(4)),
                paletteHexes: board.extractedPalette.map(\.hex),
                pinnedOffline: board.pinnedOffline,
                updatedAt: board.updatedAt
            )
        }.sorted { $0.updatedAt > $1.updatedAt }
    }

    public func fetchBoard(id: UUID) async throws -> MoodboardDocument? { boards[id] }

    public func proposeMoodboard(seed: MoodboardSeed, primaryCount: Int, candidateCount: Int) async throws -> MoodboardProposal {
        let all = Array(assets.values.filter { !$0.isTrashed })
        let primary = Array(all.prefix(primaryCount))
        let candidates = Array(all.dropFirst(primary.count).prefix(candidateCount))
        let nodes = primary.enumerated().map { idx, item in
            BoardNode(
                kind: .assetRef(assetID: item.id, crop: nil, weight: idx == 0 ? 2 : 1, autoplayLoop: item.mediaKind == .animatedImage),
                frame: BoardRect(x: Double((idx % 4) * 260), y: Double((idx / 4) * 240), width: 240, height: 220),
                zIndex: idx,
                editorialOrder: idx
            )
        }
        let palette = Array(primary.flatMap(\.dominantColors).prefix(6))
        let doc = MoodboardDocument(
            title: "新灵感情绪板",
            nodes: nodes,
            extractedPalette: palette,
            candidateAssetIDs: candidates.map(\.id)
        )
        return MoodboardProposal(
            draftDocument: doc,
            primaryMatches: primary.map { ScoredAsset(asset: $0, score: 0.9, matchReasons: ["快速推荐"]) },
            candidatePool: candidates.map { ScoredAsset(asset: $0, score: 0.7, matchReasons: ["候选补位"]) },
            extractedPalette: palette,
            usedCloudAI: false
        )
    }

    public func saveBoard(_ document: MoodboardDocument) async throws -> MoodboardDocument {
        var copy = document
        copy.updatedAt = Date()
        boards[copy.id] = copy
        return copy
    }

    public func deleteBoard(id: UUID) async throws { boards.removeValue(forKey: id) }

    public func setBoardPinnedOffline(id: UUID, pinned: Bool) async throws {
        boards[id]?.pinnedOffline = pinned
    }

    public func extractBoardPalette(assetIDs: [UUID], count: Int) async throws -> [LabColor] {
        let colors = assetIDs.compactMap { assets[$0]?.dominantColors }.flatMap { $0 }
        return Array(colors.prefix(count))
    }

    public func replacementCandidates(for assetID: UUID, excluding: Set<UUID>, boardContext: [UUID], limit: Int) async throws -> [ScoredAsset] {
        Array(assets.values.filter { !excluding.contains($0.id) && $0.id != assetID && !$0.isTrashed }.prefix(limit)).map {
            ScoredAsset(asset: $0, score: 0.8, matchReasons: ["风格补位"])
        }
    }

    public func analyzeAssetsLocally(ids: [UUID]) async throws -> [AssetRecord] {
        ids.compactMap { assets[$0] }
    }

    public func enrichAssetsWithCloudAI(ids: [UUID]) async throws -> [AssetRecord] {
        ids.compactMap { assets[$0] }
    }

    public func aiConfig() async -> AIProviderConfig { currentAIConfig }
    public func saveAIConfig(_ config: AIProviderConfig, apiKey: String?) async throws { currentAIConfig = config }
    public func hasStoredAIKey(for provider: CloudAIProviderKind) async -> Bool { false }

    public func syncConfig() async -> DriveSyncConfig { currentSyncConfig }
    public func saveSyncConfig(_ config: DriveSyncConfig) async throws { currentSyncConfig = config }
    public func syncStatus() async -> SyncStatus { currentSyncStatus }
    public func probeGDirectEnvironment() async -> GDirectEnvironmentSnapshot { GDirectEnvironmentSnapshot() }
    public func runGDirectScan() async throws -> GDirectEnvironmentSnapshot { GDirectEnvironmentSnapshot() }
    public func runGDirectMount(path: String?) async throws -> GDirectEnvironmentSnapshot { GDirectEnvironmentSnapshot() }
    public func importGoogleOAuthSecret(from url: URL) async throws {}
    public func importGoogleOAuthFromGDirect() async throws {}
    public func hasGoogleOAuthClientConfig() async -> Bool { true }
    public func saveGoogleOAuthClientConfig(clientID: String, clientSecret: String) async throws {}
    public func signInGoogleDrive() async throws -> DriveAccountInfo { DriveAccountInfo(email: "demo@example.com") }
    public func signOutGoogleDrive() async throws { currentSyncStatus.account = nil }
    public func hasWebDAVPassword() async -> Bool { false }
    public func saveWebDAVPassword(_ password: String) async throws {}
    public func testWebDAVConnection(config: DriveSyncConfig, password: String?) async throws -> DriveAccountInfo {
        DriveAccountInfo(email: config.webDAVUsername, source: "WebDAV")
    }
    public func migrateLibraryStorage(to targetConfig: DriveSyncConfig, webDAVPassword: String?) async throws -> StorageMigrationReport {
        let oldMode = currentSyncConfig.mode
        currentSyncConfig = targetConfig
        return StorageMigrationReport(sourceMode: oldMode, targetMode: targetConfig.mode, targetLocation: targetConfig.activeStorageLocationSummary)
    }
    public func syncNow() async throws -> SyncReport { SyncReport() }

    public func seedSampleLibraryIfEmpty() async throws -> Bool { false }
}
