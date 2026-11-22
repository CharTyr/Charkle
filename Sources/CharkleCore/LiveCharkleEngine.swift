import AppKit
import Foundation

public final actor LiveCharkleEngine: CharkleEngineProtocol {
    let database: LibraryDatabase
    let media: MediaPipeline
    let intelligence: IntelligenceEngine
    let curator: MoodboardCurator
    let driveSync: DriveSyncEngine
    let oauth: GoogleOAuthClient
    let driveSession: URLSession
    let injectedTransport: (any DriveTransport)?
    private var syncTask: Task<SyncReport, Error>?
    private var autoSyncTask: Task<Void, Never>?
    private var backgroundEnrichmentTasks: [UUID: Task<Void, Never>] = [:]
    private var cachedGDirectEndpoints: (endpoints: [GDirectEndpoint], fetchedAt: ContinuousClock.Instant)?
    private var seeding = false

    public init(database: LibraryDatabase, media: MediaPipeline, intelligence: IntelligenceEngine = IntelligenceEngine(),
                transport: (any DriveTransport)? = nil) {
        self.database = database
        self.media = media
        self.intelligence = intelligence
        self.curator = MoodboardCurator(database: database)
        self.driveSync = DriveSyncEngine(database: database, media: media, intelligence: intelligence)
        self.driveSession = DirectAPITransport.makePooledSession()
        self.oauth = GoogleOAuthClient(keychain: intelligence.keychain, session: driveSession)
        self.injectedTransport = transport
    }

    deinit {
        autoSyncTask?.cancel()
        syncTask?.cancel()
        for task in backgroundEnrichmentTasks.values {
            task.cancel()
        }
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
        let config = await syncConfig()
        let rootSegments = config.rootFolderName
            .split(separator: "/")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty && $0 != "." && $0 != ".." }
        let rootPrefix = (rootSegments.isEmpty ? ["Charkle"] : rootSegments).joined(separator: "/")

        try await database.transaction { store in
            let allFolders = try store.fetchFolders()
            let folderByID = Dictionary(uniqueKeysWithValues: allFolders.map { ($0.id, $0) })
            guard let folder = folderByID[id] else { return }

            var pathParts: [String] = []
            var cursor: UUID? = id
            var visited = Set<UUID>()
            while let cid = cursor, visited.insert(cid).inserted, let f = folderByID[cid] {
                pathParts.append(f.name)
                cursor = f.parentID
            }
            let relFolderPath = pathParts.reversed().joined(separator: "/")

            var children = allFolders.filter { $0.parentID == id }
            var siblings = allFolders.filter { $0.parentID == folder.parentID && $0.id != id }
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
                let resolvedRemote = remote.hasPrefix(MountedVolumeTransport.pathIDPrefix)
                    ? remote
                    : "\(MountedVolumeTransport.pathIDPrefix)\(rootPrefix)/\(relFolderPath)"
                try store.setState("local.delete.folder." + id.uuidString, resolvedRemote)
            }
            try store.record(.deleteFolder(id, driveID: mounted ? nil : folder.driveFolderID))
        }
    }

    public func moveFolder(id: UUID, newParentID: UUID?, insertAtIndex: Int?) async throws -> [FolderRecord] {
        try await database.transaction { store in
            let allFolders = try store.fetchFolders()
            let byID = Dictionary(uniqueKeysWithValues: allFolders.map { ($0.id, $0) })
            guard var moving = byID[id] else {
                throw DriveTransportError.fileNotFound(id.uuidString)
            }
            if let newParentID {
                guard byID[newParentID] != nil else {
                    throw DriveTransportError.fileNotFound(newParentID.uuidString)
                }
                // Cycle guard: reject dropping a folder into itself or any descendant.
                var cursor: UUID? = newParentID
                var visited = Set<UUID>()
                while let cid = cursor, visited.insert(cid).inserted {
                    if cid == id {
                        throw LibraryDatabaseError("不能将文件夹移动到自身或其子目录中。")
                    }
                    cursor = byID[cid]?.parentID
                }
            }

            let parentChanged = moving.parentID != newParentID
            let targetSiblings = allFolders
                .filter { $0.parentID == newParentID && $0.id != id }
                .sorted { ($0.sortOrder, $0.name, $0.id.uuidString) < ($1.sortOrder, $1.name, $1.id.uuidString) }

            if parentChanged {
                let originalName = moving.name
                var candidate = originalName
                var suffix = 2
                while (newParentID == nil && candidate.caseInsensitiveCompare("Inbox") == .orderedSame)
                    || targetSiblings.contains(where: { $0.name.caseInsensitiveCompare(candidate) == .orderedSame }) {
                    candidate = "\(originalName) \(suffix)"
                    suffix += 1
                }
                moving.name = candidate
                moving.parentID = newParentID
            }

            var ordered = targetSiblings
            let clampIndex = insertAtIndex.map { max(0, min($0, ordered.count)) } ?? ordered.count
            ordered.insert(moving, at: clampIndex)

            let now = Date()
            for (index, var folder) in ordered.enumerated() {
                if folder.sortOrder != index || folder.id == id {
                    folder.sortOrder = index
                    folder.updatedAt = now
                    try store.record(.folder(folder))
                }
            }
            return try store.fetchFolders()
        }
    }

    public func updateFolderAppearance(id: UUID, colorHex: String?, customSymbol: String?) async throws -> FolderRecord {
        try await database.transaction { store in
            guard var folder = try store.folder(id: id) else {
                throw DriveTransportError.fileNotFound(id.uuidString)
            }
            folder.colorHex = colorHex?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false ? colorHex : nil
            folder.customSymbol = customSymbol?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false ? customSymbol : nil
            folder.updatedAt = Date()
            try store.record(.folder(folder))
            return folder
        }
    }

    private static let smartFoldersStateKey = "smart_folders.v1"

    public func fetchSmartFolders() async throws -> [SmartFolderRecord] {
        let list = try await database.state(Self.smartFoldersStateKey, as: [SmartFolderRecord].self) ?? []
        return list.sorted { ($0.sortOrder, $0.name, $0.id.uuidString) < ($1.sortOrder, $1.name, $1.id.uuidString) }
    }

    public func saveSmartFolder(_ folder: SmartFolderRecord) async throws -> [SmartFolderRecord] {
        try await database.transaction { store in
            var list = try store.state(Self.smartFoldersStateKey, as: [SmartFolderRecord].self) ?? []
            var item = folder
            item.name = item.name.trimmingCharacters(in: .whitespacesAndNewlines)
            if item.name.isEmpty { item.name = "未命名智能文件夹" }
            item.updatedAt = Date()
            if let idx = list.firstIndex(where: { $0.id == item.id }) {
                list[idx] = item
            } else {
                item.sortOrder = (list.map(\.sortOrder).max() ?? -1) + 1
                list.append(item)
            }
            try store.setState(Self.smartFoldersStateKey, list)
            return list.sorted { ($0.sortOrder, $0.name, $0.id.uuidString) < ($1.sortOrder, $1.name, $1.id.uuidString) }
        }
    }

    public func deleteSmartFolder(id: UUID) async throws -> [SmartFolderRecord] {
        try await database.transaction { store in
            var list = try store.state(Self.smartFoldersStateKey, as: [SmartFolderRecord].self) ?? []
            list.removeAll { $0.id == id }
            try store.setState(Self.smartFoldersStateKey, list)
            return list.sorted { ($0.sortOrder, $0.name, $0.id.uuidString) < ($1.sortOrder, $1.name, $1.id.uuidString) }
        }
    }

    public func markAssetOpened(id: UUID) async {
        try? await database.transaction { store in
            guard var asset = try store.asset(id: id) else { return }
            asset.lastOpenedAt = Date()
            // Local activity timestamp only; avoids emitting unnecessary remote sync operations.
            try store.put(asset)
        }
    }

    public func refreshRichAsset(id: UUID) async throws -> AssetRecord {
        guard var current = try await database.asset(id: id) else {
            throw DriveTransportError.fileNotFound(id.uuidString)
        }
        guard let urlStr = current.sourceURL, let url = URL(string: urlStr) else {
            return current
        }

        if let repoRef = GitHubRepoURLParser.parse(url) {
            let repo = await GitHubRepoResolver.resolve(repoRef)
            var rich = current.richMetadata ?? AssetRichMetadata()
            rich.githubRepo = repo
            current.richMetadata = rich
            current.title = repo.fullName
            if let desc = repo.description, !desc.isEmpty {
                current.notes = desc
            }
            if let card = MediaArtwork.githubRepoCard(repo) {
                try? media.writeCustomPoster(card, for: &current)
            }
            let updated = current
            return try await database.transaction { store in
                try store.saveAssetLocally(updated)
            }
        }

        if let socialRef = SocialPostURLParser.parse(url),
           let resolved = await SocialPostResolver.resolve(socialRef) {
            let stagingDir = media.staging.appending(path: "social-refresh-\(UUID().uuidString)", directoryHint: .isDirectory)
            try? FileManager.default.createDirectory(at: stagingDir, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: stagingDir) }

            var embeddedPoster: CGImage?
            var mediaFailed = false
            var downloadedFile: URL?
            if let mediaURL = resolved.primaryMediaDownloadURL, let kind = resolved.primaryMediaKind {
                let item = XPostMedia(kind: kind, url: mediaURL, thumbnailURL: resolved.primaryThumbnailURL)
                if let file = await XPostResolver.downloadMedia(item, to: stagingDir, baseName: "Social-\(id.uuidString.prefix(8))") {
                    downloadedFile = file
                    embeddedPoster = MediaPipeline.raster(file)?.poster
                } else {
                    mediaFailed = true
                }
            }
            if embeddedPoster == nil, let thumbURL = resolved.primaryThumbnailURL {
                let thumbItem = XPostMedia(kind: .photo, url: thumbURL)
                if let thumbFile = await XPostResolver.downloadMedia(thumbItem, to: stagingDir, baseName: "SocialThumb-\(id.uuidString.prefix(8))") {
                    embeddedPoster = MediaPipeline.raster(thumbFile)?.poster
                }
            }

            var meta = resolved.metadata
            meta.mediaFetchFailed = mediaFailed
            var rich = current.richMetadata ?? AssetRichMetadata()
            rich.socialPost = meta
            current.richMetadata = rich
            current.title = resolved.shortTitle
            if let file = downloadedFile {
                let ext = file.pathExtension.lowercased()
                if ["mp4", "mov", "m4v", "webm"].contains(ext) {
                    current.fileName = file.lastPathComponent
                    _ = try? media.installOriginal(file, for: current)
                }
            }
            current.mediaKind = .webBookmark
            current.ocrText = meta.bodyText.isEmpty ? current.ocrText : meta.bodyText
            if let card = MediaArtwork.socialPostCard(meta, embeddedMedia: embeddedPoster) {
                try? media.writeCustomPoster(card, for: &current)
            }
            let updated = current
            return try await database.transaction { store in
                try store.saveAssetLocally(updated)
            }
        }

        return current
    }

    public func ingest(_ inputs: [CaptureInput], targetFolderID: UUID?, targetBoardID: UUID?) async throws -> [AssetRecord] {
        if let targetFolderID, try await database.folder(id: targetFolderID) == nil {
            throw DriveTransportError.fileNotFound(targetFolderID.uuidString)
        }
        if let targetBoardID, try await database.board(id: targetBoardID) == nil {
            throw DriveTransportError.fileNotFound(targetBoardID.uuidString)
        }
        guard !inputs.isEmpty else { return [] }

        // 1. Expand any Finder directories recursively, creating mirrored FolderRecords on the fly.
        let expandedItems = try await expandInputsWithDirectories(inputs, defaultFolderID: targetFolderID)
        guard !expandedItems.isEmpty else { return [] }

        // 2. Prepare items with bounded concurrency (up to 4 workers) without blocking on Vision OCR or Cloud AI.
        var prepared: [PreparedAsset] = []
        do {
            let maxConcurrent = 4
            var orderedResults = [PreparedAsset?](repeating: nil, count: expandedItems.count)
            try await withThrowingTaskGroup(of: (Int, PreparedAsset).self) { group in
                var nextIndex = 0
                let initialBatch = min(maxConcurrent, expandedItems.count)
                for _ in 0..<initialBatch {
                    let index = nextIndex
                    nextIndex += 1
                    let work = expandedItems[index]
                    group.addTask {
                        try Task.checkCancellation()
                        return (index, try await self.prepareExpanded(work.input, folderID: work.folderID))
                    }
                }
                while let (index, item) = try await group.next() {
                    orderedResults[index] = item
                    if nextIndex < expandedItems.count {
                        let launchIndex = nextIndex
                        nextIndex += 1
                        let work = expandedItems[launchIndex]
                        group.addTask {
                            try Task.checkCancellation()
                            return (launchIndex, try await self.prepareExpanded(work.input, folderID: work.folderID))
                        }
                    }
                }
            }
            prepared = orderedResults.compactMap { $0 }
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

        // 3. Fire heavier Vision OCR + optional Cloud AI auto-tagging in a tracked background task
        // (cancelled cleanly on deinit) so dropped files appear in Inbox immediately while still having
        // fast FeaturePrint vectors ready synchronously for similarity search and sync shards.
        let committedIDs = committed.map(\.id)
        if !committedIDs.isEmpty {
            let jobID = UUID()
            let task = Task(priority: .utility) { [weak self] in
                guard let self else { return }
                defer {
                    Task { [weak self] in
                        await self?.finishBackgroundEnrichmentTask(jobID)
                    }
                }
                guard !Task.isCancelled else { return }
                var didChange = false
                if await self.runBackgroundOCRIfNeeded(ids: committedIDs) {
                    didChange = true
                }
                guard !Task.isCancelled else { return }
                let ai = await self.aiConfig()
                if ai.autoAnalyzeOnImport, ai.provider != .disabled, !Task.isCancelled,
                   let enriched = try? await self.enrichAssetsWithCloudAI(ids: committedIDs), !enriched.isEmpty {
                    didChange = true
                }
                if didChange && !Task.isCancelled {
                    NotificationCenter.default.post(name: CharkleCoreNotifications.libraryDidEnrichInBackground, object: nil)
                }
            }
            backgroundEnrichmentTasks[jobID] = task
        }
        return committed
    }

    private func finishBackgroundEnrichmentTask(_ jobID: UUID) {
        backgroundEnrichmentTasks.removeValue(forKey: jobID)
    }

    private func runBackgroundOCRIfNeeded(ids: [UUID]) async -> Bool {
        var didChange = false
        for id in ids {
            guard !Task.isCancelled else { break }
            guard let before = try? await database.asset(id: id) else { continue }
            guard before.mediaKind != .audio, before.mediaKind != .model3D else { continue }
            if let existing = before.ocrText, !existing.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                continue
            }
            guard let thumbnail = media.thumbnailURL(for: id, tier: .grid520) else { continue }
            let analysis = await intelligence.analyze(
                thumbnailURL: thumbnail,
                includeColors: false,
                includeOCR: true,
                includeFeaturePrint: false
            )
            guard !Task.isCancelled, let text = analysis.ocrText, !text.isEmpty else { continue }
            let saved = try? await database.transaction { store -> AssetRecord? in
                guard var current = try store.asset(id: id), current.contentHash == before.contentHash else { return nil }
                if current.ocrText == nil || current.mediaKind == .image || current.mediaKind == .animatedImage {
                    current.ocrText = text
                    return try store.saveAssetLocally(current)
                }
                return nil
            }
            if saved != nil { didChange = true }
        }
        return didChange
    }

    private struct ExpandedCaptureWork: Sendable {
        let input: CaptureInput
        let folderID: UUID?
    }

    private func expandInputsWithDirectories(
        _ inputs: [CaptureInput],
        defaultFolderID: UUID?
    ) async throws -> [ExpandedCaptureWork] {
        var queue: [ExpandedCaptureWork] = []
        for input in inputs {
            try Task.checkCancellation()
            guard case .fileURL(let url) = input else {
                queue.append(ExpandedCaptureWork(input: input, folderID: defaultFolderID))
                continue
            }
            let accessed = url.startAccessingSecurityScopedResource()
            defer { if accessed { url.stopAccessingSecurityScopedResource() } }
            let resolved = url.resolvingSymlinksInPath()
            let values = try? resolved.resourceValues(forKeys: [.isDirectoryKey, .isPackageKey])
            if values?.isDirectory == true && values?.isPackage != true {
                let collected = try await collectDirectoryFiles(
                    directoryURL: resolved,
                    parentFolderID: defaultFolderID,
                    depth: 0
                )
                queue.append(contentsOf: collected)
            } else {
                queue.append(ExpandedCaptureWork(input: input, folderID: defaultFolderID))
            }
        }
        return queue
    }

    private static let skippedDirectoryNames: Set<String> = [
        ".git", ".svn", ".hg", "node_modules", "__MACOSX", ".Trash", ".build", "DerivedData"
    ]

    private func collectDirectoryFiles(
        directoryURL: URL,
        parentFolderID: UUID?,
        depth: Int
    ) async throws -> [ExpandedCaptureWork] {
        guard depth < 16 else { return [] }
        let folderName = directoryURL.lastPathComponent.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !folderName.isEmpty, !folderName.hasPrefix("."), !Self.skippedDirectoryNames.contains(folderName) else {
            return []
        }

        let targetFolder = try await findOrCreateFolderForImport(named: folderName, parentID: parentFolderID)
        let keys: [URLResourceKey] = [.isDirectoryKey, .isRegularFileKey, .isPackageKey, .isHiddenKey, .isSymbolicLinkKey]
        let children = (try? FileManager.default.contentsOfDirectory(
            at: directoryURL,
            includingPropertiesForKeys: keys,
            options: [.skipsHiddenFiles]
        )) ?? []

        let sortedChildren = children.sorted {
            $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending
        }

        var result: [ExpandedCaptureWork] = []
        for child in sortedChildren {
            try Task.checkCancellation()
            let childName = child.lastPathComponent
            if childName.hasPrefix(".") || childName.hasPrefix("._") || Self.skippedDirectoryNames.contains(childName) {
                continue
            }
            let vals = try? child.resourceValues(forKeys: Set(keys))
            if vals?.isSymbolicLink == true { continue }
            if vals?.isDirectory == true && vals?.isPackage != true {
                let nested = try await collectDirectoryFiles(
                    directoryURL: child,
                    parentFolderID: targetFolder.id,
                    depth: depth + 1
                )
                result.append(contentsOf: nested)
            } else if vals?.isRegularFile == true {
                result.append(ExpandedCaptureWork(input: .fileURL(child), folderID: targetFolder.id))
            }
        }
        return result
    }

    private func findOrCreateFolderForImport(named rawName: String, parentID: UUID?) async throws -> FolderRecord {
        let safeName = (parentID == nil && rawName.caseInsensitiveCompare("Inbox") == .orderedSame) ? "Inbox 导入" : rawName
        let folders = try await database.fetchFolders()
        if let existing = folders.first(where: {
            $0.parentID == parentID && $0.name.caseInsensitiveCompare(safeName) == .orderedSame
        }) {
            return existing
        }
        return try await createFolder(name: safeName, parentID: parentID)
    }

    private struct PreparedAsset: Sendable {
        var asset: AssetRecord
        let feature: Data?
    }

    private func prepareExpanded(_ input: CaptureInput, folderID: UUID?) async throws -> PreparedAsset {
        if case .webURL(let url, _, _) = input {
            if let repoRef = GitHubRepoURLParser.parse(url) {
                return try await prepareGitHubRepo(repoRef, folderID: folderID)
            }
            if let socialRef = SocialPostURLParser.parse(url) {
                return try await prepareSocialPost(socialRef, fallbackInput: input, folderID: folderID)
            }
        }
        return try await prepare(input, folderID: folderID)
    }

    private func prepare(_ input: CaptureInput, folderID: UUID?) async throws -> PreparedAsset {
        let id = UUID()
        do {
            let source = try await media.ingest(input, folderID: folderID, id: id)
            var feature: Data?
            if source.asset.mediaKind != .audio,
               let thumbnail = media.thumbnailURL(for: id, tier: .grid520) {
                let analysis = await intelligence.analyze(
                    thumbnailURL: thumbnail,
                    includeColors: false,
                    includeOCR: false,
                    includeFeaturePrint: true
                )
                feature = analysis.featurePrintData
            }
            return PreparedAsset(asset: source.asset, feature: feature)
        } catch {
            media.removeFiles(for: AssetRecord(id: id, title: "", fileName: ""))
            throw error
        }
    }

    private func prepareGitHubRepo(_ ref: GitHubRepoReference, folderID: UUID?) async throws -> PreparedAsset {
        let repo = await GitHubRepoResolver.resolve(ref)
        let summaryText = [
            repo.description ?? "",
            repo.language.map { "Language: \($0)" } ?? "",
            "Stars: \(repo.stars) · Forks: \(repo.forks)",
            repo.topics.isEmpty ? "" : "Topics: \(repo.topics.joined(separator: ", "))"
        ].filter { !$0.isEmpty }.joined(separator: "\n")

        var item = try await prepare(
            .webURL(ref.canonicalURL, title: repo.fullName, notes: summaryText),
            folderID: folderID
        )
        item.asset.title = repo.fullName
        item.asset.notes = repo.description ?? ""
        item.asset.sourceURL = ref.canonicalURL.absoluteString
        item.asset.sourceDomain = "github.com"
        item.asset.richMetadata = AssetRichMetadata(githubRepo: repo)
        var tags = Set(item.asset.tags)
        tags.insert("GitHub")
        if let lang = repo.language, !lang.isEmpty { tags.insert(lang) }
        item.asset.tags = tags.sorted()
        if let card = MediaArtwork.githubRepoCard(repo) {
            try? media.writeCustomPoster(card, for: &item.asset)
        }
        return item
    }

    private func prepareSocialPost(_ ref: SocialPostReference, fallbackInput: CaptureInput, folderID: UUID?) async throws -> PreparedAsset {
        guard let resolved = await SocialPostResolver.resolve(ref) else {
            return try await prepare(fallbackInput, folderID: folderID)
        }

        let stagingDir = media.staging.appending(path: "social-\(UUID().uuidString)", directoryHint: .isDirectory)
        try? FileManager.default.createDirectory(at: stagingDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: stagingDir) }

        var downloadedVideoFile: URL?
        var embeddedPoster: CGImage?
        var mediaFailed = false

        if let mediaURL = resolved.primaryMediaDownloadURL, let kind = resolved.primaryMediaKind {
            let item = XPostMedia(kind: kind, url: mediaURL, thumbnailURL: resolved.primaryThumbnailURL)
            if let file = await XPostResolver.downloadMedia(item, to: stagingDir, baseName: "Social-\(resolved.metadata.authorHandle)") {
                if kind == .video || kind == .gif {
                    downloadedVideoFile = file
                } else {
                    embeddedPoster = MediaPipeline.raster(file)?.poster
                }
            } else {
                mediaFailed = true
            }
        }
        if embeddedPoster == nil, let thumbURL = resolved.primaryThumbnailURL {
            let thumbItem = XPostMedia(kind: .photo, url: thumbURL)
            if let thumbFile = await XPostResolver.downloadMedia(thumbItem, to: stagingDir, baseName: "SocialThumb-\(resolved.metadata.authorHandle)") {
                embeddedPoster = MediaPipeline.raster(thumbFile)?.poster
            }
        }

        var meta = resolved.metadata
        meta.mediaFetchFailed = mediaFailed

        // Always store a social post as ONE cohesive structured social-post asset (`.webBookmark`) combining
        // author + full text + media attachments — NEVER flatten it into an `.image` asset.
        // When a video/GIF is present, keep the downloaded `.mp4` as cached original for instant inline playback
        // while preserving `.webBookmark` + `richMetadata.socialPost`; otherwise store the structured Markdown archive.
        var prepared: PreparedAsset
        if let downloadedVideoFile {
            prepared = try await prepare(.fileURL(downloadedVideoFile), folderID: folderID)
        } else {
            prepared = try await prepare(
                .textSnippet(title: resolved.shortTitle, text: resolved.markdownDocument, sourceURL: meta.originalURL),
                folderID: folderID
            )
        }

        prepared.asset.mediaKind = .webBookmark
        prepared.asset.title = resolved.shortTitle
        prepared.asset.notes = meta.bodyText
        prepared.asset.ocrText = meta.bodyText.isEmpty ? prepared.asset.ocrText : meta.bodyText
        prepared.asset.sourceURL = meta.originalURL
        prepared.asset.sourceDomain = ref.canonicalURL.host() ?? (meta.platform == .x ? "x.com" : meta.platform == .bluesky ? "bsky.app" : "threads.net")
        prepared.asset.richMetadata = AssetRichMetadata(socialPost: meta)

        let platformTag = meta.platform.displayName
        if !prepared.asset.tags.contains(platformTag) {
            prepared.asset.tags.append(platformTag)
        }

        if let card = MediaArtwork.socialPostCard(meta, embeddedMedia: embeddedPoster) {
            try? media.writeCustomPoster(card, for: &prepared.asset)
        }
        return prepared
    }

    private static func commit(_ prepared: PreparedAsset, in store: isolated LibraryDatabase,
                               syncConfig: DriveSyncConfig) throws -> AssetRecord {
        let asset = try store.saveAssetLocally(prepared.asset)
        if !asset.contentHash.isEmpty {
            // Re-importing the same content intentionally clears prior deletion suppression fingerprints.
            if let oldFP = try store.state("deleted.content." + asset.contentHash, as: DeletedAssetFingerprint.self),
               let md5 = oldFP.md5, !md5.isEmpty {
                try store.setState("deleted.md5." + md5, Optional<DeletedAssetFingerprint>.none)
            }
            try store.setState("deleted.content." + asset.contentHash, Optional<DeletedAssetFingerprint>.none)
        }
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
        let config = await syncConfig()
        let rootSegments = config.rootFolderName
            .split(separator: "/")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty && $0 != "." && $0 != ".." }
        let rootPrefix = (rootSegments.isEmpty ? ["Charkle"] : rootSegments).joined(separator: "/")

        let uniqueIDs = Array(Set(ids))
        var precomputedMD5: [UUID: String] = [:]
        for id in uniqueIDs {
            if let asset = try? await database.asset(id: id),
               let cached = media.cachedOriginal(for: asset),
               let digest = try? MediaPipeline.digests(cached) {
                precomputedMD5[id] = digest.md5
            }
        }
        let md5Lookup = precomputedMD5

        try await database.transaction { store in
            let folders = try store.fetchFolders()
            let folderByID = Dictionary(uniqueKeysWithValues: folders.map { ($0.id, $0) })
            func mountedRelativeFolderPath(_ folderID: UUID?) -> String {
                guard let folderID else { return "Inbox" }
                var parts: [String] = []
                var cursor: UUID? = folderID
                var visited = Set<UUID>()
                while let cid = cursor, visited.insert(cid).inserted, let folder = folderByID[cid] {
                    parts.append(folder.name)
                    cursor = folder.parentID
                }
                return parts.isEmpty ? "Inbox" : parts.reversed().joined(separator: "/")
            }

            for id in uniqueIDs {
                guard let asset = try store.asset(id: id) else { continue }
                let mounted = asset.driveFileID?.hasPrefix("mounted-") == true
                if mounted, let remote = asset.driveFileID {
                    // Upgrade legacy inode-based `mounted-<ino>` IDs into stable mount-relative path IDs
                    // so deletion succeeds even after rclone rotates NFS inodes.
                    let resolvedRemote: String
                    if remote.hasPrefix(MountedVolumeTransport.pathIDPrefix) {
                        resolvedRemote = remote
                    } else {
                        let relDir = mountedRelativeFolderPath(asset.folderID)
                        resolvedRemote = "\(MountedVolumeTransport.pathIDPrefix)\(rootPrefix)/\(relDir)/\(asset.fileName)"
                    }
                    try store.setState("local.delete.asset." + id.uuidString, resolvedRemote)
                    try store.setState("deleted.drive." + resolvedRemote, true)
                    if resolvedRemote != remote {
                        try store.setState("deleted.drive." + remote, true)
                    }
                } else if let remote = asset.driveFileID, !remote.isEmpty {
                    try store.setState("deleted.drive." + remote, true)
                }
                if !asset.contentHash.isEmpty {
                    let md5 = md5Lookup[id]
                    let fp = DeletedAssetFingerprint(
                        assetID: id,
                        sha256: asset.contentHash,
                        md5: md5,
                        fileName: asset.fileName,
                        deletedAt: Date()
                    )
                    try store.setState("deleted.content." + asset.contentHash, fp)
                    if let md5, !md5.isEmpty {
                        try store.setState("deleted.md5." + md5, fp)
                    }
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
    public func suggestFolder(for assetID: UUID) async throws -> FolderSuggestion? {
        let tsConfig = await typeSafeConfig()
        if tsConfig.enabled, tsConfig.enableInboxSmartTriage,
           let apiKey = intelligence.storedTypeSafeAPIKey(),
           let asset = try await database.asset(id: assetID) {
            let folders = try await database.fetchFolders().filter { $0.id != asset.folderID }
            if !folders.isEmpty {
                let options = try await buildFolderOptions(folders: folders)
                let imgData = try? await loadVisualGroundingPayload(for: assetID, targetLongSide: 448).data
                if let res = try? await intelligence.grounding.classifyIntoFolders(
                    assetTitle: asset.title,
                    assetTags: asset.tags + asset.suggestedTags,
                    assetNotes: [asset.notes, asset.aiDescription ?? ""].joined(separator: " "),
                    imageData: imgData,
                    imageFormat: "jpg",
                    folders: options,
                    config: tsConfig,
                    apiKey: apiKey
                ) {
                    if let folderID = res.folderID,
                       let matched = folders.first(where: { $0.id == folderID }) {
                        return FolderSuggestion(
                            folderID: matched.id,
                            folderName: matched.name,
                            confidence: res.confidence,
                            reason: res.reason
                        )
                    }
                    // Jev explicitly evaluated fit and found none suitable — respect it instead of guessing!
                    return nil
                }
            }
        }
        return try await curator.suggestFolder(for: assetID)
    }

    public nonisolated func cachedThumbnailURL(for assetID: UUID, tier: ThumbnailTier) -> URL? {
        media.thumbnailURL(for: assetID, tier: tier) ?? media.thumbnailURL(for: assetID, tier: .grid520)
    }

    public nonisolated func cachedOriginalURL(for asset: AssetRecord) -> URL? {
        media.cachedOriginal(for: asset)
    }

    public func thumbnailURL(for assetID: UUID, tier: ThumbnailTier) async -> URL? {
        cachedThumbnailURL(for: assetID, tier: tier)
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

    public func curateMoodboard(
        _ request: MoodboardCurationRequest,
        onStep: (@Sendable (MoodboardAgentStep) async -> Void)?
    ) async throws -> MoodboardProposal {
        let config = await aiConfig()
        let provider = try? intelligence.provider(for: config)
        let tsConfig = await typeSafeConfig()
        let tsKey = intelligence.storedTypeSafeAPIKey()
        let harness = MoodboardAgentHarness(database: database, media: media)
        return try await harness.curate(
            request: request,
            provider: provider,
            typeSafeConfig: tsConfig,
            typeSafeAPIKey: tsKey,
            grounding: intelligence.grounding,
            onStep: onStep
        )
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
        let existingLibraryTags = ((try? await database.fetchTagCounts()) ?? []).map(\.name)
        var visited = Set<UUID>()
        var result: [AssetRecord] = []
        for id in ids where visited.insert(id).inserted {
            guard let before = try await database.asset(id: id) else { continue }
            let thumbnail = config.sendThumbnailsToCloud ? media.thumbnailURL(for: id, tier: .grid520) : nil
            let enrichment = try await intelligence.enrich(
                before,
                thumbnailURL: thumbnail,
                provider: provider,
                existingLibraryTags: existingLibraryTags
            )
            let persisted = try await database.transaction { store -> AssetRecord? in
                guard var asset = try store.asset(id: id), asset.contentHash == before.contentHash else { return nil }
                asset.aiDescription = enrichment.description
                let latestLibraryTags = ((try? store.fetchTagCounts()) ?? []).map(\.name)
                asset.suggestedTags = CloudTagNormalizer.canonicalizeSuggestedTags(
                    enrichment.suggestedTags,
                    existingLibraryTags: latestLibraryTags.isEmpty ? existingLibraryTags : latestLibraryTags,
                    existingAssetTags: asset.tags,
                    maxCount: 6
                )
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
        if let apiKey, config.provider != .disabled, config.provider != .chatGPTSubscription {
            let key = IntelligenceEngine.key(config.provider)
            let value = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
            if value.isEmpty { try intelligence.keychain.delete(key) }
            else { try intelligence.keychain.save(Data(value.utf8), for: key) }
        }
        try await database.setState("aiConfig", config)
    }

    public func hasStoredAIKey(for provider: CloudAIProviderKind) async -> Bool {
        switch provider {
        case .disabled:
            return false
        case .chatGPTSubscription:
            return await intelligence.chatGPT.hasUsableSession()
        case .gemini, .openAICompatible:
            return intelligence.keychain.exists(IntelligenceEngine.key(provider))
        }
    }

    public func chatGPTSession() async -> ChatGPTAccountSession {
        await intelligence.chatGPT.currentSession()
    }

    public func signInWithChatGPT(reconsent: Bool = false, switchAccount: Bool = false) async throws -> ChatGPTAccountSession {
        let session = try await intelligence.chatGPT.signIn(
            reconsent: reconsent,
            switchAccount: switchAccount,
            openBrowser: { url in
                await MainActor.run {
                    _ = NSWorkspace.shared.open(url)
                }
            }
        )
        var config = await aiConfig()
        config.provider = .chatGPTSubscription
        config.baseURL = ChatGPTSignInClient.resource
        if session.sharingEnabled, let models = try? await intelligence.chatGPT.listModels(), !models.isEmpty {
            if config.chatModel.isEmpty || !models.contains(where: { $0.slug == config.chatModel }) {
                config.chatModel = models.first?.slug ?? config.chatModel
            }
        } else if config.chatModel.isEmpty || config.chatModel.hasPrefix("gemini-") || config.chatModel.hasPrefix("claude-") {
            config.chatModel = "gpt-5.4-mini"
        }
        config.embeddingModel = ""
        try await database.setState("aiConfig", config)
        return session
    }

    public func disconnectChatGPT(resetRegistration: Bool = false) async throws {
        try await intelligence.chatGPT.disconnect(resetRegistration: resetRegistration)
    }

    public func listChatGPTModels() async throws -> [ChatGPTModelInfo] {
        try await intelligence.chatGPT.listModels()
    }

    // MARK: - Experimental TypeSafe System One (Jev) Visual Grounding

    public func typeSafeConfig() async -> TypeSafeExperimentalConfig {
        (try? await database.state("typeSafeConfig", as: TypeSafeExperimentalConfig.self)) ?? TypeSafeExperimentalConfig()
    }

    public func saveTypeSafeConfig(_ config: TypeSafeExperimentalConfig, apiKey: String?) async throws {
        var sanitized = config
        sanitized.baseURL = config.baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        if sanitized.baseURL.isEmpty { sanitized.baseURL = "https://api.typesafe.ai" }
        sanitized.model = config.model.trimmingCharacters(in: .whitespacesAndNewlines)
        if sanitized.model.isEmpty { sanitized.model = "jev-latest" }
        sanitized.minConfidence = max(0.05, min(0.95, config.minConfidence))
        sanitized.lowConfidencePadding = max(0.0, min(0.25, config.lowConfidencePadding))
        sanitized.minPresenceProbability = max(0.05, min(0.95, config.minPresenceProbability))

        if let apiKey {
            let trimmed = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.isEmpty {
                try intelligence.keychain.delete(IntelligenceEngine.typeSafeKey)
            } else {
                try intelligence.keychain.save(Data(trimmed.utf8), for: IntelligenceEngine.typeSafeKey)
            }
        }
        try await database.setState("typeSafeConfig", sanitized)
    }

    public func hasStoredTypeSafeKey() async -> Bool {
        intelligence.keychain.exists(IntelligenceEngine.typeSafeKey)
    }

    public func testTypeSafeConnection(
        config: TypeSafeExperimentalConfig,
        apiKey: String?
    ) async throws -> [TypeSafeModelInfo] {
        let resolvedKey: String? = {
            if let provided = apiKey?.trimmingCharacters(in: .whitespacesAndNewlines), !provided.isEmpty {
                return provided
            }
            return intelligence.storedTypeSafeAPIKey()
        }()
        guard let resolvedKey else {
            throw LibraryDatabaseError("请先填写 TypeSafe API 密钥后再测试连接。")
        }
        let client = try TypeSafeSystemOneClient(baseURL: config.baseURL, apiKey: resolvedKey)
        return try await client.listModels()
    }

    public func locateVisualRegion(assetID: UUID, query: String?) async throws -> VisualRegionResult {
        let payload = try await loadVisualGroundingPayload(for: assetID, targetLongSide: 768)
        let config = await typeSafeConfig()
        let apiKey = intelligence.storedTypeSafeAPIKey()
        return try await intelligence.grounding.locateRegion(
            query: query,
            imageData: payload.data,
            imageFormat: payload.format,
            cgImage: payload.cgImage,
            config: config,
            apiKey: apiKey
        )
    }

    public func locateVisualMatch(referenceAssetID: UUID, in targetAssetID: UUID) async throws -> VisualRegionResult {
        let refPayload = try await loadVisualGroundingPayload(for: referenceAssetID, targetLongSide: 512)
        let targetPayload = try await loadVisualGroundingPayload(for: targetAssetID, targetLongSide: 768)
        let config = await typeSafeConfig()
        let apiKey = intelligence.storedTypeSafeAPIKey()
        return try await intelligence.grounding.locateVisualMatch(
            referenceImageData: refPayload.data,
            referenceFormat: refPayload.format,
            in: targetPayload.data,
            targetFormat: targetPayload.format,
            config: config,
            apiKey: apiKey
        )
    }

    public func detectCleanContentBounds(assetID: UUID) async throws -> CleanBoundsResult {
        let payload = try await loadVisualGroundingPayload(for: assetID, targetLongSide: 768)
        let config = await typeSafeConfig()
        let apiKey = intelligence.storedTypeSafeAPIKey()
        return try await intelligence.grounding.detectCleanContentBounds(
            imageData: payload.data,
            imageFormat: payload.format,
            cgImage: payload.cgImage,
            config: config,
            apiKey: apiKey
        )
    }

    public func extractSubjectPalette(assetID: UUID, query: String?) async throws -> SubjectPaletteResult {
        guard let before = try await database.asset(id: assetID) else {
            throw DriveTransportError.fileNotFound(assetID.uuidString)
        }
        let payload = try await loadVisualGroundingPayload(for: assetID, targetLongSide: 768)
        guard let cgImage = payload.cgImage else {
            throw LibraryDatabaseError("该素材暂无可供提色的像素图像。")
        }
        let config = await typeSafeConfig()
        let apiKey = intelligence.storedTypeSafeAPIKey()
        let (colors, region) = try await intelligence.grounding.extractSubjectPalette(
            query: query,
            imageData: payload.data,
            imageFormat: payload.format,
            cgImage: cgImage,
            colorCount: 6,
            config: config,
            apiKey: apiKey
        )

        let updated = try await database.transaction { store -> AssetRecord in
            guard var current = try store.asset(id: assetID) else {
                return before
            }
            if !colors.isEmpty {
                current.dominantColors = colors
            }
            return try store.saveAssetLocally(current)
        }
        return SubjectPaletteResult(colors: colors, subjectRegion: region, updatedAsset: updated)
    }

    public func semanticSearch(
        query: String,
        criteria: FilterCriteria,
        limit: Int = 48
    ) async throws -> SemanticSearchReport {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return SemanticSearchReport(query: "", hits: [], summary: "请输入检索描述")
        }

        // 1. Respect current folder / visual / color / trash filters without text lock-out
        var scope = criteria
        scope.searchQuery = ""
        let scopedAssets = try await database.fetchAssets(matching: scope)
        guard !scopedAssets.isEmpty else {
            return SemanticSearchReport(query: trimmed, hits: [], summary: "当前筛选范围内没有可检索素材")
        }

        // 2. Signal A: Local FTS5 + Pinyin text ranks
        var textRanks = try await database.searchRanks(trimmed)
        let tokens = trimmed.split(whereSeparator: \.isWhitespace).map(String.init)
        if tokens.count > 1 {
            for token in tokens.prefix(8) {
                for (id, rank) in try await database.searchRanks(token) {
                    textRanks[id] = min(1.0, (textRanks[id] ?? 0) + rank / Double(tokens.count))
                }
            }
        }

        // 3. Signal B: Cloud AI Embedding cosine similarity (if active & indexed)
        var embeddingScores: [UUID: Double] = [:]
        var usedEmbedding = false
        let cloudCfg = await aiConfig()
        if let provider = try? intelligence.provider(for: cloudCfg) {
            let vectors = try await database.vectors()
            let hasCompatibleVectors = vectors.values.contains {
                $0.embeddingModel == provider.embeddingIdentity && $0.embedding != nil
            }
            if hasCompatibleVectors, let queryVec = try? await provider.embed(trimmed) {
                usedEmbedding = true
                for asset in scopedAssets {
                    if let vec = vectors[asset.id],
                       vec.embeddingModel == provider.embeddingIdentity,
                       let emb = vec.embedding,
                       let cos = Self.cosineSimilarity(queryVec, emb),
                       cos > 0.22 {
                        // Map cosine ~0.22...0.85 into 0...1
                        embeddingScores[asset.id] = max(0, min(1, (cos - 0.22) / 0.63))
                    }
                }
            }
        }

        // 4. Signal C: TypeSafe (Jev Score) direct visual semantic scoring on candidate images
        var jevScores: [UUID: VisualScoreResult] = [:]
        var usedJev = false
        var evaluatedVisualCount = 0
        let tsConfig = await typeSafeConfig()
        if tsConfig.enabled, tsConfig.enableSemanticSearch,
           let tsKey = intelligence.storedTypeSafeAPIKey() {
            // Prioritize FTS/embedding shortlist + untagged/recent visual assets so zero-tag photos are discovered!
            let maxVisualCandidates = 24
            let prioritized = scopedAssets.sorted { lhs, rhs in
                let ls = (textRanks[lhs.id] ?? 0) * 0.5 + (embeddingScores[lhs.id] ?? 0) * 0.5
                let rs = (textRanks[rhs.id] ?? 0) * 0.5 + (embeddingScores[rhs.id] ?? 0) * 0.5
                if abs(ls - rs) > 0.01 { return ls > rs }
                return lhs.updatedAt > rhs.updatedAt
            }
            var shortlist: [AssetRecord] = Array(prioritized.prefix(16))
            var seen = Set(shortlist.map(\.id))
            // Also include newest untagged/uncaptioned visual items in case FTS/embeddings missed them
            for asset in scopedAssets where shortlist.count < maxVisualCandidates && seen.insert(asset.id).inserted {
                if asset.tags.isEmpty || asset.aiDescription == nil {
                    shortlist.append(asset)
                }
            }
            for asset in prioritized where shortlist.count < maxVisualCandidates && seen.insert(asset.id).inserted {
                shortlist.append(asset)
            }

            var visualInputs: [VisualCandidateInput] = []
            visualInputs.reserveCapacity(shortlist.count)
            for asset in shortlist {
                let jpeg = try? await loadVisualGroundingPayload(for: asset.id, targetLongSide: 384).data
                visualInputs.append(VisualCandidateInput(
                    assetID: asset.id,
                    title: asset.title,
                    tags: asset.tags,
                    description: asset.aiDescription,
                    imageData: jpeg,
                    imageFormat: "jpg"
                ))
            }

            evaluatedVisualCount = visualInputs.count
            let scored = try await intelligence.grounding.scoreCandidatesForQuery(
                query: trimmed,
                candidates: visualInputs,
                config: tsConfig,
                apiKey: tsKey,
                batchSize: 4,
                maxConcurrency: 3
            )
            usedJev = !scored.isEmpty
            for item in scored {
                jevScores[item.assetID] = item
            }
        }

        // 5. Fuse signals into calibrated ranked hits
        var hits: [SemanticSearchHit] = []
        for asset in scopedAssets {
            let tScore = textRanks[asset.id] ?? 0
            let eScore = embeddingScores[asset.id] ?? 0
            let jResult = jevScores[asset.id]
            let jScore = jResult?.score ?? 0

            let combined: Double
            var reasons: [String] = []
            var sourceLabel = "全文匹配"

            if jResult != nil {
                // Jev actually inspected the visual asset
                if jScore >= 0.30 {
                    reasons.append("Jev 视觉语义 \(Int((jScore * 100).rounded()))%")
                }
                if eScore >= 0.30 {
                    reasons.append("向量相似度 \(Int((eScore * 100).rounded()))%")
                }
                if tScore > 0.05 {
                    reasons.append("标题/标签/OCR 命中")
                }
                let nonVisual = max(tScore, eScore)
                combined = max(jScore, jScore * 0.72 + nonVisual * 0.28)
                sourceLabel = eScore >= 0.30 ? "Jev 视觉 + 向量" : "Jev 视觉语义"
            } else if eScore >= 0.28 {
                reasons.append("语义向量 \(Int((eScore * 100).rounded()))%")
                if tScore > 0.05 { reasons.append("关键词命中") }
                combined = max(eScore, eScore * 0.75 + tScore * 0.25)
                sourceLabel = "语义向量"
            } else if tScore > 0.05 {
                reasons.append("全文/标签/拼音匹配")
                combined = tScore * 0.85
                sourceLabel = "本机全文"
            } else {
                continue
            }

            // Strict threshold so irrelevant items don't pollute semantic results
            let cutoff: Double = (usedJev || usedEmbedding) ? 0.32 : 0.05
            guard combined >= cutoff else { continue }

            hits.append(SemanticSearchHit(
                asset: asset,
                score: min(1.0, combined),
                confidence: jResult?.confidence,
                reason: reasons.joined(separator: " · "),
                sourceLabel: sourceLabel
            ))
        }

        hits.sort {
            if abs($0.score - $1.score) > 0.002 { return $0.score > $1.score }
            return $0.asset.rating > $1.asset.rating
        }
        let limited = Array(hits.prefix(max(1, limit)))

        var engines: [String] = []
        if usedJev { engines.append("Jev 视觉语义(\(evaluatedVisualCount)图)") }
        if usedEmbedding { engines.append("语义向量") }
        if engines.isEmpty { engines.append("本机全文/拼音") }

        let summary = limited.isEmpty
            ? "语义检索「\(trimmed)」未命中高度相关素材（\(engines.joined(separator: " + "))）"
            : "语义检索「\(trimmed)」命中 \(limited.count) 项（\(engines.joined(separator: " + "))）"

        return SemanticSearchReport(
            query: trimmed,
            hits: limited,
            usedTypeSafeJev: usedJev,
            usedCloudEmbedding: usedEmbedding,
            evaluatedVisualCount: evaluatedVisualCount,
            summary: summary
        )
    }

    public func batchTriageInbox(assetIDs: [UUID], maxCount: Int = 24) async throws -> [InboxTriageRecommendation] {
        let folders = try await database.fetchFolders()
        guard !folders.isEmpty else {
            throw LibraryDatabaseError("请先在左侧栏创建至少一个目标文件夹，再使用智能分拣。")
        }

        let targets: [AssetRecord]
        if assetIDs.isEmpty {
            targets = Array(try await database.fetchAssets(matching: FilterCriteria(onlyInbox: true)).prefix(max(1, maxCount)))
        } else {
            var loaded: [AssetRecord] = []
            for id in assetIDs.prefix(max(1, maxCount)) {
                if let asset = try await database.asset(id: id), !asset.isTrashed {
                    loaded.append(asset)
                }
            }
            targets = loaded
        }
        guard !targets.isEmpty else { return [] }

        let tsConfig = await typeSafeConfig()
        let tsKey = intelligence.storedTypeSafeAPIKey()
        let folderByID = Dictionary(uniqueKeysWithValues: folders.map { ($0.id, $0) })

        if tsConfig.enabled, tsConfig.enableInboxSmartTriage, let tsKey, !tsKey.isEmpty {
            let options = try await buildFolderOptions(folders: folders)
            let grounding = intelligence.grounding
            var prepared: [(asset: AssetRecord, jpeg: Data?)] = []
            for asset in targets {
                let jpeg = try? await loadVisualGroundingPayload(for: asset.id, targetLongSide: 384).data
                prepared.append((asset, jpeg))
            }

            var recommendations: [InboxTriageRecommendation] = []
            let workerCount = min(4, prepared.count)
            var nextIdx = 0

            try await withThrowingTaskGroup(of: InboxTriageRecommendation.self) { group in
                func enqueue(_ item: (asset: AssetRecord, jpeg: Data?)) {
                    group.addTask {
                        let res = try await grounding.classifyIntoFolders(
                            assetTitle: item.asset.title,
                            assetTags: item.asset.tags + item.asset.suggestedTags,
                            assetNotes: [item.asset.notes, item.asset.aiDescription ?? ""].joined(separator: " "),
                            imageData: item.jpeg,
                            imageFormat: "jpg",
                            folders: options,
                            config: tsConfig,
                            apiKey: tsKey
                        )
                        let folderName = res.folderID.flatMap { folderByID[$0]?.name }
                        return InboxTriageRecommendation(
                            assetID: item.asset.id,
                            assetTitle: item.asset.title,
                            recommendedFolderID: res.folderID,
                            recommendedFolderName: folderName,
                            confidence: res.confidence,
                            fitProbability: res.fitProbability,
                            reason: res.reason,
                            source: .typeSafeJev
                        )
                    }
                }

                for _ in 0..<workerCount {
                    enqueue(prepared[nextIdx])
                    nextIdx += 1
                }
                while let rec = try await group.next() {
                    recommendations.append(rec)
                    if nextIdx < prepared.count {
                        enqueue(prepared[nextIdx])
                        nextIdx += 1
                    }
                }
            }

            return recommendations.sorted {
                let lHas = $0.recommendedFolderID != nil
                let rHas = $1.recommendedFolderID != nil
                if lHas != rHas { return lHas }
                if abs($0.confidence - $1.confidence) > 0.005 { return $0.confidence > $1.confidence }
                return $0.fitProbability > $1.fitProbability
            }
        }

        // Offline heuristic fallback when TypeSafe is disabled
        var offlineRecs: [InboxTriageRecommendation] = []
        for asset in targets {
            if let suggestion = try await curator.suggestFolder(for: asset.id) {
                offlineRecs.append(InboxTriageRecommendation(
                    assetID: asset.id,
                    assetTitle: asset.title,
                    recommendedFolderID: suggestion.folderID,
                    recommendedFolderName: suggestion.folderName,
                    confidence: suggestion.confidence,
                    fitProbability: suggestion.confidence,
                    reason: suggestion.reason,
                    source: .appleVisionSaliency
                ))
            } else {
                offlineRecs.append(InboxTriageRecommendation(
                    assetID: asset.id,
                    assetTitle: asset.title,
                    recommendedFolderID: nil,
                    recommendedFolderName: nil,
                    confidence: 0,
                    fitProbability: 0,
                    reason: "离线未匹配到明确目录，建议暂留收件箱",
                    source: .appleVisionSaliency
                ))
            }
        }
        return offlineRecs.sorted { $0.confidence > $1.confidence }
    }

    private func buildFolderOptions(folders: [FolderRecord]) async throws -> [FolderOptionInput] {
        let allAssets = try await database.fetchAssets(matching: FilterCriteria(includeTrashed: false))
        var tagsByFolder: [UUID: [String: Int]] = [:]
        for asset in allAssets {
            guard let fid = asset.folderID else { continue }
            for tag in asset.tags {
                tagsByFolder[fid, default: [:]][tag, default: 0] += 1
            }
        }
        return folders.map { folder in
            let topTags = (tagsByFolder[folder.id] ?? [:])
                .sorted { $0.value > $1.value }
                .prefix(6)
                .map(\.key)
            return FolderOptionInput(id: folder.id, name: folder.name, sampleTags: topTags)
        }
    }

    private static func cosineSimilarity(_ lhs: [Float], _ rhs: [Float]) -> Double? {
        guard lhs.count == rhs.count, !lhs.isEmpty else { return nil }
        var dot: Double = 0
        var normA: Double = 0
        var normB: Double = 0
        for i in lhs.indices {
            let a = Double(lhs[i])
            let b = Double(rhs[i])
            dot += a * b
            normA += a * a
            normB += b * b
        }
        let denom = (normA * normB).squareRoot()
        guard denom > 1e-9 else { return nil }
        return dot / denom
    }

    private func loadVisualGroundingPayload(
        for assetID: UUID,
        targetLongSide: Int = 768
    ) async throws -> (data: Data, format: String, cgImage: CGImage?) {
        guard let asset = try await database.asset(id: assetID) else {
            throw DriveTransportError.fileNotFound(assetID.uuidString)
        }
        let originalURL = media.originalPath(for: asset)
        let candidateURLs: [URL] = [
            media.thumbnailURL(for: assetID, tier: targetLongSide > 520 ? .preview1400 : .grid520),
            media.thumbnailURL(for: assetID, tier: .grid520),
            FileManager.default.fileExists(atPath: originalURL.path) ? originalURL : nil
        ].compactMap { $0 }

        for url in candidateURLs {
            if let cgImage = MediaPipeline.raster(url)?.poster,
               let normalizedJPEG = TypeSafeImagePreparer.prepareJPEG(from: cgImage, targetLongSide: targetLongSide) {
                return (normalizedJPEG, "jpg", cgImage)
            }
            let ext = url.pathExtension.lowercased()
            if (ext == "jpg" || ext == "jpeg" || ext == "png"),
               let rawData = try? Data(contentsOf: url), !rawData.isEmpty {
                let format = ext == "png" ? "png" : "jpg"
                return (rawData, format, nil)
            }
        }
        throw LibraryDatabaseError("该素材缺少本地预览图，请先下载或生成缩略图后重试。")
    }

    private static let webDAVPasswordKey = "sync.webdav.password"

    private static func validatePathSegments(_ raw: String) throws {
        let segments = raw.split(separator: "/")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        for seg in segments {
            try DriveFiles.validateName(seg)
        }
    }

    public func syncConfig() async -> DriveSyncConfig {
        (try? await database.state("driveConfig", as: DriveSyncConfig.self)) ?? DriveSyncConfig()
    }

    public func saveSyncConfig(_ config: DriveSyncConfig) async throws {
        try Self.validatePathSegments(config.rootFolderName)
        if !config.webDAVRemotePath.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            try Self.validatePathSegments(config.webDAVRemotePath)
        }
        var value = config
        value.sharedFolderURLOrID = config.sharedFolderURLOrID.trimmingCharacters(in: .whitespacesAndNewlines)
        if !value.sharedFolderURLOrID.isEmpty, value.resolvedSharedFolderID == nil {
            throw DriveTransportError.invalidResponse("共享目录格式无效，请粘贴完整的 Google Drive 文件夹链接（含 /folders/…）或目录 ID。")
        }
        value.autoSyncIntervalSeconds = max(0, config.autoSyncIntervalSeconds)
        try await database.setState("driveConfig", value)
        await refreshAutoSync(config: value)
    }

    public func syncStatus() async -> SyncStatus {
        var status = await driveSync.status()
        if status.lastSyncedAt == nil, case .idle = status.phase,
           let persisted = try? await database.state("lastSyncStatus", as: SyncStatus.self) {
            await driveSync.restoreStatus(persisted)
            status = await driveSync.status()
        }
        let config = await syncConfig()
        if case .idle = status.phase { status.activeMode = config.mode }

        switch config.mode {
        case .directAPIWithGDirect:
            let hasDirectToken = await oauth.hasStoredToken()
            if hasDirectToken {
                let isCurrentDirect = status.account != nil
                    && status.account?.source != "gdirect"
                    && status.account?.source != "gdirect mount"
                    && status.account?.source != "WebDAV"
                    && status.account?.source != "本地文件夹"
                if !isCurrentDirect,
                   let storedDirect = try? await database.state("googleDirectAccount", as: DriveAccountInfo.self) {
                    status.account = storedDirect
                }
            } else {
                // Coexistence fallback: surface an existing local `gdirect` account when direct OAuth is not signed in yet
                let gd = await GDirectIntegration.signedInAccounts()
                if let email = config.selectedGDirectAccount ?? gd.defaultAccount ?? gd.accounts.first {
                    status.account = DriveAccountInfo(email: email, displayName: nil, source: "gdirect")
                } else if status.account?.source == "gdirect" || status.account?.source == "gdirect mount" {
                    status.account = nil
                }
            }
        case .gdirectMount:
            let gd = await GDirectIntegration.signedInAccounts()
            if let email = config.selectedGDirectAccount ?? gd.defaultAccount ?? gd.accounts.first {
                status.account = DriveAccountInfo(email: email, displayName: nil, source: "gdirect mount")
            } else if status.account?.source != "gdirect mount" {
                status.account = nil
            }
        case .webDAV, .localOnly:
            break
        }
        return status
    }

    public func probeGDirectEnvironment() async -> GDirectEnvironmentSnapshot {
        await GDirectIntegration.inspect(mountPath: syncConfig().mountPath)
    }

    public func runGDirectScan() async throws -> GDirectEnvironmentSnapshot {
        let snapshot = try await GDirectIntegration.scan(mountPath: syncConfig().mountPath)
        cachedGDirectEndpoints = (snapshot.endpoints, .now)
        return snapshot
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

    public func runGDirectUnmount() async throws -> GDirectEnvironmentSnapshot {
        let config = await syncConfig()
        try? await GDirectIntegration.unmount(account: config.selectedGDirectAccount)
        await refreshAutoSync(config: config)
        return await GDirectIntegration.inspect(mountPath: config.mountPath)
    }

    public func importGoogleOAuthSecret(from url: URL) async throws { try await oauth.importClientSecret(from: url) }

    public func importGoogleOAuthFromGDirect() async throws {
        let exported = try await GDirectIntegration.exportOAuthClient()
        try await oauth.saveClientConfig(exported)
    }

    public func hasGoogleOAuthClientConfig() async -> Bool {
        await oauth.hasResolvedConfig()
    }

    public func saveGoogleOAuthClientConfig(clientID: String, clientSecret: String) async throws {
        try await oauth.saveClientConfig(GoogleOAuthClientConfig(clientID: clientID, clientSecret: clientSecret))
    }

    public func signInGoogleDrive() async throws -> DriveAccountInfo {
        guard let config = try await oauth.resolvedConfig() else {
            throw DriveTransportError.notConfigured("请先按照 gdirect 教程配置 Google 登录凭据，或从本机 gdirect 一键导入。")
        }
        _ = try await oauth.authorizeInteractive(config: config) { url in
            await MainActor.run { _ = NSWorkspace.shared.open(url) }
        }
        await MainActor.run {
            NSApp.activate(ignoringOtherApps: true)
        }
        var currentConfig = await syncConfig()
        if currentConfig.mode == .localOnly || currentConfig.mode == .gdirectMount {
            currentConfig.mode = .directAPIWithGDirect
            try await saveSyncConfig(currentConfig)
        }
        let endpoints = await resolvedGDirectEndpoints(for: currentConfig)
        let account = try await DirectAPITransport(oauth: oauth, endpoints: endpoints, session: driveSession).accountInfo()
        try? await database.setState("googleDirectAccount", account)
        await driveSync.updateSignedInAccount(account, activeMode: currentConfig.mode)
        await refreshAutoSync(config: currentConfig)
        return account
    }

    public func signOutGoogleDrive() async throws {
        try await oauth.signOut()
        try? await database.setState("googleDirectAccount", Optional<DriveAccountInfo>.none)
        autoSyncTask?.cancel()
        autoSyncTask = nil
        let currentConfig = await syncConfig()
        await driveSync.updateSignedInAccount(nil, activeMode: currentConfig.mode)
    }

    public func hasWebDAVPassword() async -> Bool {
        intelligence.keychain.exists(Self.webDAVPasswordKey)
    }

    public func saveWebDAVPassword(_ password: String) async throws {
        let trimmed = password.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            try intelligence.keychain.delete(Self.webDAVPasswordKey)
        } else {
            try intelligence.keychain.save(Data(trimmed.utf8), for: Self.webDAVPasswordKey)
        }
    }

    public func testWebDAVConnection(config: DriveSyncConfig, password: String?) async throws -> DriveAccountInfo {
        let effectivePassword: String
        if let password, !password.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            effectivePassword = password.trimmingCharacters(in: .whitespacesAndNewlines)
        } else {
            effectivePassword = (try? intelligence.keychain.read(Self.webDAVPasswordKey))
                .flatMap { String(data: $0, encoding: .utf8) } ?? ""
        }
        let transport = try WebDAVTransport(
            serverURL: config.webDAVServerURL,
            username: config.webDAVUsername,
            password: effectivePassword,
            remotePath: config.webDAVRemotePath
        )
        let info = try await transport.accountInfo()
        if config.mode == .webDAV {
            await driveSync.updateSignedInAccount(info, activeMode: .webDAV)
        }
        return info
    }

    /// Losslessly migrates the entire library (folders, original files, tags, ratings, moodboards)
    /// between Pure Local Folder, Google Drive, and WebDAV, or to a new path.
    public func migrateLibraryStorage(
        to targetConfig: DriveSyncConfig,
        webDAVPassword: String?
    ) async throws -> StorageMigrationReport {
        guard syncTask == nil else {
            throw DriveTransportError.notConfigured("当前正在同步中，请等待同步完成后再执行迁移。")
        }
        let start = ContinuousClock.now
        let sourceConfig = await syncConfig()

        // 1. Persist incoming WebDAV password if provided and validate destination FIRST before mutating local DB
        if let webDAVPassword, !webDAVPassword.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            try await saveWebDAVPassword(webDAVPassword)
        }
        try Self.validatePathSegments(targetConfig.rootFolderName)
        if !targetConfig.webDAVRemotePath.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            try Self.validatePathSegments(targetConfig.webDAVRemotePath)
        }
        let targetTransport = try await transport(for: targetConfig, allowLocalFolder: true)
        _ = try await targetTransport.accountInfo()

        // 2. Ensure ALL non-trashed originals are locally downloaded before detaching from an old cloud backend
        var downloadedOriginals = 0
        if sourceConfig.mode != .localOnly {
            let activeAssets = try await database.fetchAssets(matching: FilterCriteria(includeTrashed: false))
            let uncached = activeAssets.filter { $0.driveFileID != nil && media.cachedOriginal(for: $0) == nil }
            if !uncached.isEmpty {
                let sourceTransport = try await transport(for: sourceConfig, allowLocalFolder: false)
                for asset in uncached {
                    try Task.checkCancellation()
                    _ = try await driveSync.downloadOriginal(for: asset.id, using: sourceTransport)
                    downloadedOriginals += 1
                }
            }
        }

        // 3. Re-queue the entire authoritative local library cleanly for the new backend & path
        let counts = try await database.transaction { store in
            try store.requeueLibraryForBackendMigration(
                syncThumbnails: targetConfig.syncThumbnails,
                syncEmbeddings: targetConfig.syncEmbeddings
            )
        }

        // 4. Switch active config and immediately sync all folders, originals & moodboards to the new destination
        try await saveSyncConfig(targetConfig)
        _ = try await driveSync.sync(using: targetTransport, config: targetConfig, allowLocalFolderSync: true)
        if targetConfig.mode != .localOnly {
            _ = try await evict(keeping: [])
        }

        let duration = start.duration(to: .now).components
        let seconds = Double(duration.seconds) + Double(duration.attoseconds) / 1e18
        return StorageMigrationReport(
            sourceMode: sourceConfig.mode,
            targetMode: targetConfig.mode,
            targetLocation: targetConfig.activeStorageLocationSummary,
            downloadedOriginals: downloadedOriginals,
            migratedAssets: counts.assets,
            migratedFolders: counts.folders,
            migratedBoards: counts.boards,
            durationSeconds: seconds
        )
    }

    private func resolvedGDirectEndpoints(for config: DriveSyncConfig) async -> [GDirectEndpoint] {
        guard config.useGDirectIPAcceleration else { return [] }
        let now = ContinuousClock.now
        if let cached = cachedGDirectEndpoints, cached.fetchedAt.duration(to: now) < .seconds(300) {
            return cached.endpoints
        }
        let endpoints = await GDirectIntegration.scannedEndpoints()
        cachedGDirectEndpoints = (endpoints, now)
        return endpoints
    }

    public func listGoogleDriveSharedFolders() async throws -> [RemoteDriveFile] {
        if let injectedTransport {
            return try await injectedTransport.listSharedFolders()
        }
        let config = await syncConfig()
        guard (try? await oauth.currentStoredToken()) != nil else {
            throw DriveTransportError.authenticationRequired("读取「与我共享」目录列表需要先在 Charkle 中独立登录 Google 账号。")
        }
        let endpoints = await resolvedGDirectEndpoints(for: config)
        let transferDirectory = media.staging.appending(path: "DriveTransfers", directoryHint: .isDirectory)
        let direct = DirectAPITransport(
            oauth: oauth,
            endpoints: endpoints,
            session: driveSession,
            transferDirectory: transferDirectory,
            multipartThresholdBytes: 5 * 1_048_576
        )
        return try await direct.listSharedFolders()
    }

    public func syncNow() async throws -> SyncReport {
        if let syncTask { return try await syncTask.value }
        let config = await syncConfig()
        if config.mode == .localOnly && config.localLibraryPath.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return SyncReport()
        }
        // Another caller may have started while we waited for the configuration read.
        if let syncTask { return try await syncTask.value }
        let task = Task {
            let transport = try await self.transport(for: config, allowLocalFolder: true)
            let report = try await driveSync.sync(using: transport, config: config, allowLocalFolderSync: config.mode == .localOnly)
            if transport is DirectAPITransport, let account = await driveSync.status().account {
                try? await database.setState("googleDirectAccount", account)
            }
            if config.mode != .localOnly {
                _ = try await self.evict(keeping: [])
            }
            if !report.discoveredAssetIDs.isEmpty {
                let ai = await self.aiConfig()
                if ai.autoAnalyzeOnImport, ai.provider != .disabled {
                    let discoveredIDs = report.discoveredAssetIDs
                    Task { [weak engine = self] in
                        guard let engine else { return }
                        if let enriched = try? await engine.enrichAssetsWithCloudAI(ids: discoveredIDs), !enriched.isEmpty {
                            NotificationCenter.default.post(
                                name: CharkleSyncNotifications.didCompleteSync,
                                object: nil,
                                userInfo: [
                                    CharkleSyncNotifications.discoveredCountKey: 0,
                                    CharkleSyncNotifications.downloadedOpsKey: 0,
                                    CharkleSyncNotifications.reconciledRenamesKey: enriched.count,
                                    CharkleSyncNotifications.updatedBoardsKey: 0
                                ]
                            )
                        }
                    }
                }
            }
            if report.hasVisibleLibraryChanges {
                NotificationCenter.default.post(
                    name: CharkleSyncNotifications.didCompleteSync,
                    object: nil,
                    userInfo: [
                        CharkleSyncNotifications.discoveredCountKey: report.discoveredRemoteAssets,
                        CharkleSyncNotifications.downloadedOpsKey: report.downloadedOps,
                        CharkleSyncNotifications.reconciledRenamesKey: report.reconciledRenames,
                        CharkleSyncNotifications.updatedBoardsKey: report.updatedBoards
                    ]
                )
            }
            return report
        }
        syncTask = task
        defer { syncTask = nil }
        return try await task.value
    }

    private func transport(for config: DriveSyncConfig, allowLocalFolder: Bool = false) async throws -> any DriveTransport {
        if let injectedTransport { return injectedTransport }
        switch config.mode {
        case .localOnly:
            guard allowLocalFolder else {
                throw DriveTransportError.notConfigured("当前为纯本地保存模式。")
            }
            let rawPath = config.localLibraryPath.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !rawPath.isEmpty else {
                throw DriveTransportError.notConfigured("请先选择一个本地文件夹作为素材库保存路径。")
            }
            let expanded = URL(fileURLWithPath: (rawPath as NSString).expandingTildeInPath, isDirectory: true).standardizedFileURL
            let parentDir = expanded.deletingLastPathComponent().path
            let leafName = expanded.lastPathComponent.isEmpty ? "Charkle" : expanded.lastPathComponent
            return MountedVolumeTransport(
                mountPath: parentDir,
                rootFolderName: leafName,
                accountEmail: expanded.path,
                requireDedicatedMount: false
            )
        case .webDAV:
            let password = (try? intelligence.keychain.read(Self.webDAVPasswordKey))
                .flatMap { String(data: $0, encoding: .utf8) } ?? ""
            return try WebDAVTransport(
                serverURL: config.webDAVServerURL,
                username: config.webDAVUsername,
                password: password,
                remotePath: config.webDAVRemotePath
            )
        case .gdirectMount:
            let gd = await GDirectIntegration.signedInAccounts()
            let account = config.selectedGDirectAccount ?? gd.defaultAccount ?? gd.accounts.first
            var activePath = config.mountPath
            if !GDirectIntegration.isMountActive(at: activePath) {
                if let liveMount = GDirectIntegration.activeLoopbackNFSMountPath() {
                    activePath = liveMount
                } else if account != nil {
                    activePath = try await GDirectIntegration.mount(path: activePath, account: account)
                }
            }
            return MountedVolumeTransport(
                mountPath: activePath,
                rootFolderName: config.rootFolderName,
                accountEmail: account,
                requireDedicatedMount: true
            )
        case .directAPIWithGDirect:
            // 1. Prefer Charkle's own OAuth token if the user signed in directly inside Charkle
            if (try? await oauth.currentStoredToken()) != nil {
                let endpoints = await resolvedGDirectEndpoints(for: config)
                let transferDirectory = media.staging.appending(path: "DriveTransfers", directoryHint: .isDirectory)
                return DirectAPITransport(
                    oauth: oauth,
                    endpoints: endpoints,
                    session: driveSession,
                    transferDirectory: transferDirectory,
                    multipartThresholdBytes: 5 * 1_048_576
                )
            }
            // 2. If user specified a Google Drive shared folder URL/ID directly, Direct API OAuth is required
            if config.resolvedSharedFolderID != nil {
                throw DriveTransportError.authenticationRequired(
                    "通过 Google Drive 共享目录链接/ID 协作需要先在设置中「改用 Charkle 独立登录 Google 账号」；若继续使用本机 gdirect 挂载，可在 Google Drive 网页端将共享目录「添加到云端硬盘快捷方式」后，直接把该快捷方式名填在「云端保存路径」。"
                )
            }
            // 3. Otherwise, if a local `gdirect` mount is already active, gracefully fall back to it
            //    without silently mounting NFS behind the user's back.
            let gd = await GDirectIntegration.signedInAccounts()
            if let gdirectAccount = config.selectedGDirectAccount ?? gd.defaultAccount ?? gd.accounts.first {
                if GDirectIntegration.isMountActive(at: config.mountPath) {
                    return MountedVolumeTransport(
                        mountPath: config.mountPath,
                        rootFolderName: config.rootFolderName,
                        accountEmail: gdirectAccount,
                        requireDedicatedMount: true
                    )
                }
                if let liveMount = GDirectIntegration.activeLoopbackNFSMountPath() {
                    return MountedVolumeTransport(
                        mountPath: liveMount,
                        rootFolderName: config.rootFolderName,
                        accountEmail: gdirectAccount,
                        requireDedicatedMount: true
                    )
                }
            }
            // 4. Direct API OAuth not signed in and no active gdirect fallback mount -> prompt clean Google sign-in
            let endpoints = await resolvedGDirectEndpoints(for: config)
            let transferDirectory = media.staging.appending(path: "DriveTransfers", directoryHint: .isDirectory)
            return DirectAPITransport(
                oauth: oauth,
                endpoints: endpoints,
                session: driveSession,
                transferDirectory: transferDirectory,
                multipartThresholdBytes: 5 * 1_048_576
            )
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
                let hasCharkleToken = await oauth.hasStoredToken()
                let hasActiveGDirectMount = GDirectIntegration.isMountActive(at: config.mountPath)
                    || GDirectIntegration.activeLoopbackNFSMountPath() != nil
                guard hasCharkleToken || hasActiveGDirectMount else { return }
            case .webDAV:
                guard !config.webDAVServerURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
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
    static func make(appSupportDirectory: URL? = nil, startAutoSync: Bool = true) throws -> LiveCharkleEngine {
        let directory = try appSupportDirectory ?? FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask,
                                                                           appropriateFor: nil, create: true)
            .appending(path: "Charkle", directoryHint: .isDirectory)
        let media = try MediaPipeline(directory: directory)
        let database = try LibraryDatabase(url: directory.appending(path: "Library.sqlite3"))
        let engine = LiveCharkleEngine(database: database, media: media)
        if startAutoSync {
            Task { [weak engine] in
                guard let engine else { return }
                await engine.refreshAutoSync(config: engine.syncConfig())
            }
        }
        return engine
    }
}
