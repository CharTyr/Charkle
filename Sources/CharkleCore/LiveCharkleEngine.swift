import AppKit
import Foundation

public final actor LiveCharkleEngine: CharkleEngineProtocol {
    let database: LibraryDatabase
    let media: MediaPipeline
    let intelligence: IntelligenceEngine
    let curator: MoodboardCurator
    let driveSync: DriveSyncEngine
    let oauth: GoogleOAuthClient
    let injectedTransport: (any DriveTransport)?
    private var syncTask: Task<SyncReport, Error>?
    private var autoSyncTask: Task<Void, Never>?
    private var seeding = false

    public init(database: LibraryDatabase, media: MediaPipeline, intelligence: IntelligenceEngine = IntelligenceEngine(),
                transport: (any DriveTransport)? = nil) {
        self.database = database
        self.media = media
        self.intelligence = intelligence
        self.curator = MoodboardCurator(database: database)
        self.driveSync = DriveSyncEngine(database: database, media: media, intelligence: intelligence)
        self.oauth = GoogleOAuthClient(keychain: intelligence.keychain)
        self.injectedTransport = transport
    }

    deinit {
        autoSyncTask?.cancel()
        syncTask?.cancel()
    }

    public func fetchAssets(matching criteria: FilterCriteria) async throws -> [AssetRecord] {
        try await database.fetchAssets(matching: criteria)
    }

    public func fetchAsset(id: UUID) async throws -> AssetRecord? { try await database.asset(id: id) }
    public func fetchFolders() async throws -> [FolderRecord] { try await database.fetchFolders() }
    public func fetchTagCounts() async throws -> [TagCount] { try await database.fetchTagCounts() }
    public func inboxCount() async throws -> Int { try await database.inboxCount() }

    public func createFolder(name: String, parentID: UUID?) async throws -> FolderRecord {
        let name = try Self.folderName(name, parent: parentID)
        return try await database.transaction { store in
            let folders = try store.fetchFolders()
            if let parentID, !folders.contains(where: { $0.id == parentID }) {
                throw DriveTransportError.fileNotFound(parentID.uuidString)
            }
            try Self.ensureUniqueFolder(name, parent: parentID, except: nil, folders: folders)
            let folder = FolderRecord(name: name, parentID: parentID, sortOrder: (folders.map(\.sortOrder).max() ?? -1) + 1)
            try store.record(.folder(folder))
            return folder
        }
    }

    public func renameFolder(id: UUID, newName: String) async throws -> FolderRecord {
        try await database.transaction { store in
            guard var folder = try store.folder(id: id) else { throw DriveTransportError.fileNotFound(id.uuidString) }
            let name = try Self.folderName(newName, parent: folder.parentID)
            try Self.ensureUniqueFolder(name, parent: folder.parentID, except: id, folders: store.fetchFolders())
            if name != folder.name {
                folder.name = name
                folder.updatedAt = .now
                try store.record(.folder(folder))
            }
            return folder
        }
    }

    public func deleteFolder(id: UUID) async throws {
        try await database.transaction { store in
            guard let folder = try store.folder(id: id) else { return }
            var children = try store.fetchFolders().filter { $0.parentID == id }
            var siblings = try store.fetchFolders().filter { $0.parentID == folder.parentID && $0.id != id }
            for index in children.indices {
                let originalName = children[index].name
                var name = originalName
                var suffix = 2
                while (folder.parentID == nil && name.caseInsensitiveCompare("Inbox") == .orderedSame)
                    || siblings.contains(where: { $0.name.caseInsensitiveCompare(name) == .orderedSame }) {
                    name = originalName + " \(suffix)"
                    suffix += 1
                }
                children[index].name = name
                children[index].parentID = folder.parentID
                children[index].updatedAt = .now
                try store.record(.folder(children[index]))
                siblings.append(children[index])
            }
            for var asset in try store.fetchAssets(matching: FilterCriteria(folderID: id, includeTrashed: true)) {
                asset.folderID = nil
                _ = try store.saveAssetLocally(asset)
            }
            let mounted = folder.driveFolderID?.hasPrefix("mounted-") == true
            if mounted, let remote = folder.driveFolderID {
                try store.setState("local.delete.folder." + id.uuidString, remote)
            }
            try store.record(.deleteFolder(id, driveID: mounted ? nil : folder.driveFolderID))
        }
    }

    public func ingest(_ inputs: [CaptureInput], targetFolderID: UUID?, targetBoardID: UUID?) async throws -> [AssetRecord] {
        if let targetFolderID, try await database.folder(id: targetFolderID) == nil {
            throw DriveTransportError.fileNotFound(targetFolderID.uuidString)
        }
        if let targetBoardID, try await database.board(id: targetBoardID) == nil {
            throw DriveTransportError.fileNotFound(targetBoardID.uuidString)
        }
        guard !inputs.isEmpty else { return [] }
        var prepared: [PreparedAsset] = []
        do {
            for input in inputs {
                try Task.checkCancellation()
                if case .webURL(let url, _, _) = input, let ref = XPostURLParser.parse(url) {
                    let xPrepared = try await prepareXPost(ref, fallbackInput: input, folderID: targetFolderID)
                    prepared.append(contentsOf: xPrepared)
                } else {
                    prepared.append(try await prepare(input, folderID: targetFolderID))
                }
            }
        } catch {
            for item in prepared { media.removeFiles(for: item.asset) }
            throw error
        }

        let config = await syncConfig()
        let incoming = prepared
        let committed: [AssetRecord]
        do {
            committed = try await database.transaction { store in
                if let targetFolderID, try store.folder(id: targetFolderID) == nil {
                    throw DriveTransportError.fileNotFound(targetFolderID.uuidString)
                }
                var board: MoodboardDocument?
                if let targetBoardID {
                    guard let current = try store.board(id: targetBoardID) else { throw DriveTransportError.fileNotFound(targetBoardID.uuidString) }
                    board = current
                }
                let assets = try incoming.map { try Self.commit($0, in: store, syncConfig: config) }
                if var board {
                    let lastOrder = board.nodes.map(\.editorialOrder).max() ?? -1
                    let top = (board.nodes.map(\.frame.maxY).max() ?? -16) + 16
                    let zStart = (board.nodes.map(\.zIndex).max() ?? -1) + 1
                    board.nodes += MoodboardCurator.editorialNodes(assets).enumerated().map { index, node in
                        var node = node
                        node.frame.y += top
                        node.editorialOrder = lastOrder + index + 1
                        node.zIndex = zStart + index
                        return node
                    }
                    _ = try store.saveBoardLocally(board)
                }
                return assets
            }
        } catch {
            for item in incoming { media.removeFiles(for: item.asset) }
            throw error
        }
        _ = try await evict(keeping: Set(committed.map(\.id)))
        let ai = await aiConfig()
        if ai.autoAnalyzeOnImport, ai.provider != .disabled,
           let enriched = try? await enrichAssetsWithCloudAI(ids: committed.map(\.id)) {
            return enriched
        }
        return committed
    }

    private struct PreparedAsset: Sendable {
        var asset: AssetRecord
        let feature: Data?
    }

    private func prepare(_ input: CaptureInput, folderID: UUID?) async throws -> PreparedAsset {
        let id = UUID()
        do {
            let source = try await media.ingest(input, folderID: folderID, id: id)
            var asset = source.asset
            var feature: Data?
            if asset.mediaKind != .audio, let thumbnail = media.thumbnailURL(for: id, tier: .grid520) {
                let analysis = await intelligence.analyze(thumbnailURL: thumbnail, includeColors: false)
                asset.ocrText = asset.ocrText ?? analysis.ocrText
                feature = analysis.featurePrintData
            }
            return PreparedAsset(asset: asset, feature: feature)
        } catch {
            media.removeFiles(for: AssetRecord(id: id, title: "", fileName: ""))
            throw error
        }
    }

    private func prepareXPost(_ ref: XPostReference, fallbackInput: CaptureInput, folderID: UUID?) async throws -> [PreparedAsset] {
        guard let post = await XPostResolver.resolve(ref) else {
            return [try await prepare(fallbackInput, folderID: folderID)]
        }

        let stagingDir = media.staging.appending(path: "xpost-\(UUID().uuidString)", directoryHint: .isDirectory)
        try? FileManager.default.createDirectory(at: stagingDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: stagingDir) }

        var downloadedFiles: [URL] = []
        for (idx, item) in post.media.enumerated() {
            try Task.checkCancellation()
            let baseName = "X-\(post.authorHandle)-\(ref.tweetID)-\(idx + 1)"
            if let localFile = await XPostResolver.downloadMedia(item, to: stagingDir, baseName: baseName) {
                downloadedFiles.append(localFile)
            }
        }

        var results: [PreparedAsset] = []
        let canonicalStr = post.canonicalURL.absoluteString
        let searchableTweetBody = [post.authorName, "@\(post.authorHandle)", post.articleTitle ?? "", post.text, post.quotedText ?? ""]
            .filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
            .joined(separator: "\n")

        if !downloadedFiles.isEmpty {
            let total = downloadedFiles.count
            for (idx, fileURL) in downloadedFiles.enumerated() {
                try Task.checkCancellation()
                var item = try await prepare(.fileURL(fileURL), folderID: folderID)
                let suffix = total > 1 ? " (\(idx + 1)/\(total))" : ""
                item.asset.title = post.shortTitle + suffix
                item.asset.notes = post.formattedNotes
                item.asset.sourceURL = canonicalStr
                item.asset.sourceDomain = "x.com"
                if !item.asset.tags.contains("X") {
                    item.asset.tags.append("X")
                }
                if let existingOCR = item.asset.ocrText, !existingOCR.isEmpty {
                    item.asset.ocrText = searchableTweetBody + "\n" + existingOCR
                } else {
                    item.asset.ocrText = searchableTweetBody
                }
                results.append(item)
            }
            return results
        }

        // Text-only tweet (or protected/unavailable media): archive full tweet text as searchable Markdown card
        var snippet = try await prepare(
            .textSnippet(title: post.shortTitle, text: post.markdownDocument, sourceURL: canonicalStr),
            folderID: folderID
        )
        snippet.asset.title = post.shortTitle
        snippet.asset.notes = post.formattedNotes
        snippet.asset.sourceURL = canonicalStr
        snippet.asset.sourceDomain = "x.com"
        if !snippet.asset.tags.contains("X") {
            snippet.asset.tags.append("X")
        }
        return [snippet]
    }

    private static func commit(_ prepared: PreparedAsset, in store: isolated LibraryDatabase,
                               syncConfig: DriveSyncConfig) throws -> AssetRecord {
        let asset = try store.saveAssetLocally(prepared.asset)
        try store.touchOriginal(asset.id)
        if let feature = prepared.feature {
            let vector = AssetVector(featurePrint: feature)
            if syncConfig.syncEmbeddings { try store.record(.vector(asset.id, vector)) }
            else { try store.saveVector(vector, for: asset.id) }
        }
        if syncConfig.syncThumbnails { try store.markProjection("thumbnails", id: asset.id) }
        return asset
    }

    public func updateAssets(_ patch: AssetBatchPatch) async throws -> [AssetRecord] {
        let result = try await database.transaction { store in
            if case .folder(let id) = patch.folderAssignment, try store.folder(id: id) == nil {
                throw DriveTransportError.fileNotFound(id.uuidString)
            }
            var seen = Set<UUID>()
            var changed: [AssetRecord] = []
            for id in patch.assetIDs where seen.insert(id).inserted {
                guard var asset = try store.asset(id: id) else { continue }
                if let title = patch.title { asset.title = title }
                if let notes = patch.notes { asset.notes = notes }
                if let rating = patch.rating { asset.rating = min(5, max(0, rating)) }
                var tags = tagMap(asset.tags + patch.addTags)
                let dismissed = Set(patch.dismissSuggestedTags.map(SearchText.normalize))
                asset.suggestedTags.removeAll { dismissed.contains(SearchText.normalize($0)) }
                if patch.acceptSuggestedTags {
                    tags.merge(tagMap(asset.suggestedTags)) { first, _ in first }
                    asset.suggestedTags.removeAll()
                }
                for tag in patch.removeTags { tags.removeValue(forKey: SearchText.normalize(tag)) }
                asset.tags = tags.values.sorted()
                switch patch.folderAssignment {
                case .unchanged: break
                case .inbox: asset.folderID = nil
                case .folder(let folder): asset.folderID = folder
                }
                if let pinned = patch.pinnedOffline { asset.pinnedOffline = pinned }
                if let trashed = patch.isTrashed { asset.isTrashed = trashed }
                changed.append(try store.saveAssetLocally(asset))
            }
            return changed
        }
        if patch.pinnedOffline == true {
            await warmOfflinePins(result.filter(\.pinnedOffline).map(\.id))
            return try await database.transaction { store in try result.compactMap { try store.asset(id: $0.id) } }
        }
        if patch.pinnedOffline == false { _ = try await evict(keeping: []) }
        return result
    }

    public func permanentlyDeleteAssets(ids: [UUID]) async throws {
        try await database.transaction { store in
            for id in Set(ids) {
                guard let asset = try store.asset(id: id) else { continue }
                let mounted = asset.driveFileID?.hasPrefix("mounted-") == true
                if mounted, let remote = asset.driveFileID {
                    try store.setState("local.delete.asset." + id.uuidString, remote)
                    try store.setState("deleted.drive." + remote, true)
                }
                try store.record(.deleteAsset(id, driveID: mounted ? nil : asset.driveFileID))
            }
        }
        try await database.removeDeletedMedia(using: media)
    }

    public func quickJump(query: String, limit: Int) async throws -> [QuickJumpMatch] {
        try await database.quickJump(query: query, limit: limit)
    }
    public func similarAssets(to assetID: UUID, limit: Int) async throws -> [ScoredAsset] {
        try await curator.similarAssets(to: assetID, limit: limit)
    }
    public func suggestFolder(for assetID: UUID) async throws -> FolderSuggestion? { try await curator.suggestFolder(for: assetID) }

    public func thumbnailURL(for assetID: UUID, tier: ThumbnailTier) async -> URL? {
        media.thumbnailURL(for: assetID, tier: tier) ?? media.thumbnailURL(for: assetID, tier: .grid520)
    }

    public func originalURL(for assetID: UUID) async throws -> URL {
        if let url = try await database.transaction({ [media] store -> URL? in
            guard var asset = try store.asset(id: assetID), let path = media.cachedOriginal(for: asset) else { return nil }
            if !asset.isLocalOriginalCached {
                asset.isLocalOriginalCached = true
                try store.put(asset)
            }
            try store.touchOriginal(assetID)
            return path
        }) { return url }
        let transport = try await transport(for: syncConfig())
        let result = try await driveSync.downloadOriginal(for: assetID, using: transport)
        _ = try await evict(keeping: [assetID])
        return result
    }

    public func cacheStats() async -> CacheStats {
        (try? await media.cache(in: database, evict: false, keeping: [])) ?? CacheStats(thumbnailBytes: media.thumbnailBytes())
    }

    public func setCacheBudgetBytes(_ bytes: Int64) async {
        try? await database.setState("cacheBudgetBytes", max(0, bytes))
        _ = try? await evict(keeping: [])
    }

    public func evictCacheNow() async throws -> CacheStats { try await evict(keeping: []) }

    private func evict(keeping: Set<UUID>) async throws -> CacheStats { try await media.cache(in: database, evict: true, keeping: keeping) }

    private func warmOfflinePins(_ ids: [UUID]) async {
        for id in Set(ids) {
            if let asset = try? await database.asset(id: id), asset.driveFileID != nil, media.cachedOriginal(for: asset) == nil {
                _ = try? await originalURL(for: id)
            }
        }
    }

    public func fetchBoards() async throws -> [MoodboardSummary] {
        try await database.fetchBoards().map {
            MoodboardSummary(id: $0.id, title: $0.title, subtitle: $0.subtitle, mode: $0.mode, itemCount: $0.nodes.count,
                             previewAssetIDs: Array($0.referencedAssetIDs.prefix(4)), paletteHexes: $0.extractedPalette.map(\.hex),
                             pinnedOffline: $0.pinnedOffline, updatedAt: $0.updatedAt)
        }
    }

    public func fetchBoard(id: UUID) async throws -> MoodboardDocument? { try await database.board(id: id) }

    public func proposeMoodboard(seed: MoodboardSeed, primaryCount: Int, candidateCount: Int) async throws -> MoodboardProposal {
        let config = await aiConfig()
        let provider = try? intelligence.provider(for: config)
        return try await curator.proposeMoodboard(seed: seed, primaryCount: primaryCount, candidateCount: candidateCount, provider: provider)
    }

    public func saveBoard(_ document: MoodboardDocument) async throws -> MoodboardDocument {
        let saved = try await database.transaction { store in try store.saveBoardLocally(document) }
        if saved.pinnedOffline { await warmOfflinePins(saved.referencedAssetIDs) }
        return saved
    }

    public func deleteBoard(id: UUID) async throws {
        try await database.transaction { store in
            guard try store.board(id: id) != nil else { return }
            try store.record(.deleteBoard(id))
        }
        _ = try await evict(keeping: [])
    }

    public func setBoardPinnedOffline(id: UUID, pinned: Bool) async throws {
        let board = try await database.transaction { store in
            guard var board = try store.board(id: id) else { throw DriveTransportError.fileNotFound(id.uuidString) }
            board.pinnedOffline = pinned
            return try store.saveBoardLocally(board)
        }
        if pinned { await warmOfflinePins(board.referencedAssetIDs) }
        else { _ = try await evict(keeping: []) }
    }

    public func extractBoardPalette(assetIDs: [UUID], count: Int) async throws -> [LabColor] {
        try await curator.extractBoardPalette(assetIDs: assetIDs, count: count)
    }

    public func replacementCandidates(for assetID: UUID, excluding: Set<UUID>, boardContext: [UUID],
                                      limit: Int) async throws -> [ScoredAsset] {
        try await curator.replacementCandidates(for: assetID, excluding: excluding, boardContext: boardContext, limit: limit)
    }

    public func analyzeAssetsLocally(ids: [UUID]) async throws -> [AssetRecord] {
        var result: [AssetRecord] = []
        var visited = Set<UUID>()
        let config = await syncConfig()
        for id in ids where visited.insert(id).inserted {
            guard let before = try await database.asset(id: id) else { continue }
            let thumbnail = media.thumbnailURL(for: id, tier: .grid520)
            let analysis = if let thumbnail { await intelligence.analyze(thumbnailURL: thumbnail) } else { LocalAnalysisResult() }
            let saved = try await database.transaction { store -> AssetRecord? in
                guard var current = try store.asset(id: id), current.contentHash == before.contentHash else { return nil }
                if !analysis.dominantColors.isEmpty, current.mediaKind != .audio { current.dominantColors = analysis.dominantColors }
                if current.ocrText == nil || current.mediaKind == .image || current.mediaKind == .animatedImage {
                    current.ocrText = analysis.ocrText ?? current.ocrText
                }
                if let feature = analysis.featurePrintData {
                    let vector = AssetVector(featurePrint: feature)
                    if config.syncEmbeddings { try store.record(.vector(id, vector)) }
                    else { try store.saveVector(vector, for: id) }
                }
                return try store.saveAssetLocally(current)
            }
            if let saved { result.append(saved) }
        }
        return result
    }

    public func enrichAssetsWithCloudAI(ids: [UUID]) async throws -> [AssetRecord] {
        let config = await aiConfig()
        guard let provider = try intelligence.provider(for: config) else { return [] }
        let sync = await syncConfig()
        var visited = Set<UUID>()
        var result: [AssetRecord] = []
        for id in ids where visited.insert(id).inserted {
            guard let before = try await database.asset(id: id) else { continue }
            let thumbnail = config.sendThumbnailsToCloud ? media.thumbnailURL(for: id, tier: .grid520) : nil
            let enrichment = try await intelligence.enrich(before, thumbnailURL: thumbnail, provider: provider)
            let persisted = try await database.transaction { store -> AssetRecord? in
                guard var asset = try store.asset(id: id), asset.contentHash == before.contentHash else { return nil }
                asset.aiDescription = enrichment.description
                let published = tagMap(asset.tags)
                asset.suggestedTags = tagMap(enrichment.suggestedTags).filter { published[$0.key] == nil }.values.sorted()
                if let embedding = enrichment.embedding {
                    let vector = AssetVector(embedding: embedding, embeddingModel: provider.embeddingIdentity)
                    if sync.syncEmbeddings { try store.record(.vector(id, vector)) }
                    else { try store.saveVector(vector, for: id) }
                }
                return try store.saveAssetLocally(asset)
            }
            if let persisted { result.append(persisted) }
        }
        return result
    }

    public func aiConfig() async -> AIProviderConfig {
        (try? await database.state("aiConfig", as: AIProviderConfig.self)) ?? AIProviderConfig()
    }

    public func saveAIConfig(_ config: AIProviderConfig, apiKey: String?) async throws {
        if let apiKey, config.provider != .disabled {
            let key = IntelligenceEngine.key(config.provider)
            let value = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
            if value.isEmpty { try intelligence.keychain.delete(key) }
            else { try intelligence.keychain.save(Data(value.utf8), for: key) }
        }
        try await database.setState("aiConfig", config)
    }

    public func hasStoredAIKey(for provider: CloudAIProviderKind) async -> Bool {
        provider != .disabled && (try? intelligence.keychain.read(IntelligenceEngine.key(provider)))?.isEmpty == false
    }

    public func syncConfig() async -> DriveSyncConfig {
        (try? await database.state("driveConfig", as: DriveSyncConfig.self)) ?? DriveSyncConfig()
    }

    public func saveSyncConfig(_ config: DriveSyncConfig) async throws {
        try DriveFiles.validateName(config.rootFolderName)
        var value = config
        value.autoSyncIntervalSeconds = max(0, config.autoSyncIntervalSeconds)
        try await database.setState("driveConfig", value)
        await refreshAutoSync(config: value)
    }

    public func syncStatus() async -> SyncStatus {
        let status = await driveSync.status()
        if status.lastSyncedAt == nil, case .idle = status.phase,
           let persisted = try? await database.state("lastSyncStatus", as: SyncStatus.self) {
            await driveSync.restoreStatus(persisted)
            return await driveSync.status()
        }
        var updated = status
        if case .idle = status.phase { updated.activeMode = await syncConfig().mode }
        return updated
    }

    public func probeGDirectEnvironment() async -> GDirectEnvironmentSnapshot {
        await GDirectIntegration.inspect(mountPath: syncConfig().mountPath)
    }

    public func runGDirectScan() async throws -> GDirectEnvironmentSnapshot {
        try await GDirectIntegration.scan(mountPath: syncConfig().mountPath)
    }

    public func runGDirectMount(path: String?) async throws -> GDirectEnvironmentSnapshot {
        var config = await syncConfig()
        let mount = path ?? config.mountPath
        try await GDirectIntegration.mount(path: mount, account: config.selectedGDirectAccount)
        if mount != config.mountPath {
            config.mountPath = mount
            try await saveSyncConfig(config)
        } else {
            await refreshAutoSync(config: config)
        }
        return await GDirectIntegration.inspect(mountPath: mount)
    }

    public func importGoogleOAuthSecret(from url: URL) async throws { try await oauth.importClientSecret(from: url) }

    public func hasGoogleOAuthClientConfig() async -> Bool {
        await oauth.hasResolvedConfig()
    }

    public func saveGoogleOAuthClientConfig(clientID: String, clientSecret: String) async throws {
        try await oauth.saveClientConfig(GoogleOAuthClientConfig(clientID: clientID, clientSecret: clientSecret))
    }

    public func signInGoogleDrive() async throws -> DriveAccountInfo {
        guard let config = try await oauth.resolvedConfig() else {
            throw DriveTransportError.notConfigured("当前开发版本尚未内置 Google 登录凭据，请先在设置中填写或导入凭据。")
        }
        _ = try await oauth.authorizeInteractive(config: config) { url in
            await MainActor.run { _ = NSWorkspace.shared.open(url) }
        }
        await MainActor.run {
            NSApp.activate(ignoringOtherApps: true)
        }
        var currentConfig = await syncConfig()
        if currentConfig.mode == .localOnly {
            currentConfig.mode = .directAPIWithGDirect
            try await saveSyncConfig(currentConfig)
        }
        let endpoints = currentConfig.useGDirectIPAcceleration
            ? await GDirectIntegration.inspect(mountPath: currentConfig.mountPath).endpoints
            : []
        let account = try await DirectAPITransport(oauth: oauth, endpoints: endpoints).accountInfo()
        await driveSync.updateSignedInAccount(account, activeMode: currentConfig.mode)
        await refreshAutoSync(config: currentConfig)
        return account
    }

    public func signOutGoogleDrive() async throws {
        try await oauth.signOut()
        autoSyncTask?.cancel()
        autoSyncTask = nil
        let currentConfig = await syncConfig()
        await driveSync.updateSignedInAccount(nil, activeMode: currentConfig.mode)
    }

    public func syncNow() async throws -> SyncReport {
        if let syncTask { return try await syncTask.value }
        let config = await syncConfig()
        guard config.mode != .localOnly else { return SyncReport() }
        // Another caller may have started while we waited for the configuration read.
        if let syncTask { return try await syncTask.value }
        let task = Task {
            let transport = try await self.transport(for: config)
            let report = try await driveSync.sync(using: transport, config: config)
            _ = try await self.evict(keeping: [])
            return report
        }
        syncTask = task
        defer { syncTask = nil }
        return try await task.value
    }

    private func transport(for config: DriveSyncConfig) async throws -> any DriveTransport {
        guard config.mode != .localOnly else { throw DriveTransportError.notConfigured("Drive sync is disabled.") }
        if let injectedTransport { return injectedTransport }
        switch config.mode {
        case .localOnly: throw DriveTransportError.notConfigured("Drive sync is disabled.")
        case .gdirectMount:
            let account = config.selectedGDirectAccount
            return MountedVolumeTransport(mountPath: config.mountPath, rootFolderName: config.rootFolderName, accountEmail: account)
        case .directAPIWithGDirect:
            let endpoints = config.useGDirectIPAcceleration ? await GDirectIntegration.inspect(mountPath: config.mountPath).endpoints : []
            let transferDirectory = media.staging.appending(path: "DriveTransfers", directoryHint: .isDirectory)
            return DirectAPITransport(oauth: oauth, endpoints: endpoints, transferDirectory: transferDirectory)
        }
    }

    private func refreshAutoSync(config: DriveSyncConfig) async {
        guard await syncConfig() == config else { return }
        autoSyncTask?.cancel()
        autoSyncTask = nil
        guard config.mode != .localOnly, config.autoSyncIntervalSeconds > 0 else { return }
        if injectedTransport == nil {
            switch config.mode {
            case .localOnly: return
            case .directAPIWithGDirect:
                guard (try? await oauth.currentStoredToken()) != nil else { return }
            case .gdirectMount:
                guard GDirectIntegration.isMountActive(at: config.mountPath) else { return }
            }
        }
        guard await syncConfig() == config, autoSyncTask == nil else { return }
        let interval = config.autoSyncIntervalSeconds
        autoSyncTask = Task { [weak self] in
            while !Task.isCancelled {
                do { try await Task.sleep(for: .seconds(interval)) } catch { return }
                guard let self else { return }
                _ = try? await self.syncNow()
            }
        }
    }

    public func seedSampleLibraryIfEmpty() async throws -> Bool {
        guard !seeding else { return false }
        seeding = true
        defer { seeding = false }
        guard try await database.isEmpty() else { return false }

        let names = Set(SampleLibrarySeeder.sampleSpecs.map(\.folderName)).subtracting([""]).sorted()
        let folders = names.enumerated().map { FolderRecord(name: $0.element, sortOrder: $0.offset) }
        let byName = Dictionary(uniqueKeysWithValues: folders.map { ($0.name, $0.id) })
        var assets: [PreparedAsset] = []
        var didCommit = false
        defer { if !didCommit { for asset in assets { media.removeFiles(for: asset.asset) } } }
        for spec in SampleLibrarySeeder.sampleSpecs {
            try Task.checkCancellation()
            guard let artwork = SampleLibrarySeeder.renderPNG(for: spec) else {
                throw LibraryDatabaseError("Could not render sample artwork \(spec.title).")
            }
            var item = try await prepare(.imageData(artwork, suggestedName: spec.fileName, sourceURL: nil),
                                         folderID: byName[spec.folderName])
            item.asset.title = spec.title
            item.asset.notes = spec.notes
            item.asset.tags = spec.tags
            item.asset.rating = spec.rating
            assets.append(item)
        }

        let config = await syncConfig()
        let prepared = assets
        didCommit = try await database.transaction { store in
            guard try store.isEmpty() else { return false }
            for folder in folders { try store.record(.folder(folder)) }
            let imported = try prepared.map { try Self.commit($0, in: store, syncConfig: config) }
            let display = [1, 2, 4, 7, 8, 9].compactMap { imported.indices.contains($0) ? imported[$0] : nil }
            let board = MoodboardDocument(title: "光、纸与泥 · Light, Paper & Clay", subtitle: "材质与构图参考",
                                          nodes: MoodboardCurator.editorialNodes(display),
                                          extractedPalette: MoodboardCurator.palette(display.flatMap(\.dominantColors), count: 6),
                                          candidateAssetIDs: imported.filter { !display.contains($0) }.map(\.id))
            _ = try store.saveBoardLocally(board)
            return true
        }
        return didCommit
    }

    private static func folderName(_ raw: String, parent: UUID?) throws -> String {
        let name = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        try DriveFiles.validateName(name)
        if name.hasPrefix(".") || (parent == nil && name.caseInsensitiveCompare("Inbox") == .orderedSame) {
            throw LibraryDatabaseError("This folder name is reserved.")
        }
        return name
    }

    private static func ensureUniqueFolder(_ name: String, parent: UUID?, except: UUID?,
                                           folders: [FolderRecord]) throws {
        if folders.contains(where: { $0.id != except && $0.parentID == parent && $0.name.caseInsensitiveCompare(name) == .orderedSame }) {
            throw LibraryDatabaseError("A folder named \(name) already exists here.")
        }
    }
}

public extension LiveCharkleEngine {
    static func make(appSupportDirectory: URL? = nil) throws -> LiveCharkleEngine {
        let directory = try appSupportDirectory ?? FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask,
                                                                           appropriateFor: nil, create: true)
            .appending(path: "Charkle", directoryHint: .isDirectory)
        let media = try MediaPipeline(directory: directory)
        let database = try LibraryDatabase(url: directory.appending(path: "Library.sqlite3"))
        let engine = LiveCharkleEngine(database: database, media: media)
        Task { [weak engine] in
            guard let engine else { return }
            await engine.refreshAutoSync(config: engine.syncConfig())
        }
        return engine
    }
}
