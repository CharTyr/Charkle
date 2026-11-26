import CryptoKit
import Foundation
import ImageIO
import UniformTypeIdentifiers

public struct SyncExecutionOptions: Sendable {
    public var backendID: UUID?
    public var isPrimaryBackend: Bool
    public var deferOpPruning: Bool
    public var progressPrefix: String?

    public init(
        backendID: UUID? = nil,
        isPrimaryBackend: Bool = true,
        deferOpPruning: Bool = false,
        progressPrefix: String? = nil
    ) {
        self.backendID = backendID
        self.isPrimaryBackend = isPrimaryBackend
        self.deferOpPruning = deferOpPruning
        self.progressPrefix = progressPrefix
    }
}

public final actor DriveSyncEngine {
    private let database: LibraryDatabase
    private let media: MediaPipeline
    private let intelligence: IntelligenceEngine
    private let statusEncoder = JSONEncoder()
    private let canonicalEncoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return encoder
    }()
    private var currentStatus = SyncStatus()
    private var activeProgressPrefix: String? = nil
    private var running = false
    private var originalDownloads: [UUID: Task<URL, Error>] = [:]
    private var lastStatusBroadcastAt: ContinuousClock.Instant?

    public init(database: LibraryDatabase, media: MediaPipeline, intelligence: IntelligenceEngine = IntelligenceEngine()) {
        self.database = database
        self.media = media
        self.intelligence = intelligence
    }

    private func updateProgress(
        phase: SyncPhase? = nil,
        detail: String? = nil,
        progress: Double? = nil,
        forceBroadcast: Bool = false
    ) {
        let phaseChanged = phase.map { $0 != currentStatus.phase } ?? false
        if let phase { currentStatus.phase = phase }
        if let prefix = activeProgressPrefix, let detail, !detail.isEmpty {
            currentStatus.currentDetail = "\(prefix) \(detail)"
        } else {
            currentStatus.currentDetail = detail
        }
        currentStatus.progressFraction = progress.map { min(1.0, max(0.0, $0)) }

        let now = ContinuousClock.now
        let elapsedEnough = lastStatusBroadcastAt.map { $0.duration(to: now) >= .milliseconds(50) } ?? true
        guard forceBroadcast || phaseChanged || elapsedEnough else { return }
        lastStatusBroadcastAt = now
        broadcastCurrentStatus()
    }

    private func broadcastCurrentStatus() {
        guard let data = try? statusEncoder.encode(currentStatus) else { return }
        NotificationCenter.default.post(
            name: CharkleSyncNotifications.didUpdateSyncStatus,
            object: nil,
            userInfo: [CharkleSyncNotifications.statusDataKey: data]
        )
    }

    private func notifyProgressiveMetadata(hasBoards: Bool) {
        NotificationCenter.default.post(
            name: CharkleSyncNotifications.didSyncProgressively,
            object: nil,
            userInfo: [
                CharkleSyncNotifications.progressKindKey: CharkleSyncNotifications.progressKindMetadata,
                CharkleSyncNotifications.hasBoardsKey: hasBoards
            ]
        )
    }

    private func notifyProgressiveThumbnails(_ assetIDs: [UUID]) {
        guard !assetIDs.isEmpty else { return }
        NotificationCenter.default.post(
            name: CharkleSyncNotifications.didSyncProgressively,
            object: nil,
            userInfo: [
                CharkleSyncNotifications.progressKindKey: CharkleSyncNotifications.progressKindThumbnails,
                CharkleSyncNotifications.thumbnailAssetIDsKey: assetIDs
            ]
        )
    }

    public func status() async -> SyncStatus {
        var status = currentStatus
        status.pendingOpCount = (try? await database.pendingOpCount()) ?? status.pendingOpCount
        return status
    }

    func restoreStatus(_ status: SyncStatus) {
        if !running { currentStatus = status }
    }

    func updateSignedInAccount(_ account: DriveAccountInfo?, activeMode: DriveTransportMode) async {
        currentStatus.account = account
        currentStatus.activeMode = activeMode
        if account != nil {
            currentStatus.lastError = nil
            if case .error = currentStatus.phase {
                currentStatus.phase = .idle
            }
        } else {
            currentStatus.lastSyncedAt = nil
            currentStatus.phase = .idle
        }
        try? await database.setState("lastSyncStatus", currentStatus)
    }

    func updateBackendStatuses(
        _ statuses: [SyncBackendStatus],
        activeMode: DriveTransportMode? = nil,
        phase: SyncPhase? = nil,
        detail: String? = nil,
        progress: Double? = nil,
        lastError: String?? = nil,
        markSyncedNow: Bool = false
    ) async {
        currentStatus.backendStatuses = statuses
        if let activeMode { currentStatus.activeMode = activeMode }
        if let phase { currentStatus.phase = phase }
        if let detail { currentStatus.currentDetail = detail }
        if let progress { currentStatus.progressFraction = min(1.0, max(0.0, progress)) }
        if let lastError { currentStatus.lastError = lastError }
        if markSyncedNow { currentStatus.lastSyncedAt = Date() }
        currentStatus.pendingOpCount = (try? await database.pendingOpCount()) ?? currentStatus.pendingOpCount
        try? await database.setState("lastSyncStatus", currentStatus)
        broadcastCurrentStatus()
    }

    public func sync(
        using transport: any DriveTransport,
        config: DriveSyncConfig,
        allowLocalFolderSync: Bool = false,
        quietErrors: Bool = false,
        options: SyncExecutionOptions = .init()
    ) async throws -> SyncReport {
        if config.mode == .localOnly && !allowLocalFolderSync { return SyncReport() }
        guard !running else { throw DriveTransportError.notConfigured("当前已有同步任务正在运行，请稍候。") }
        running = true
        activeProgressPrefix = options.progressPrefix
        defer {
            running = false
            activeProgressPrefix = nil
        }

        if !options.isPrimaryBackend {
            return try await syncSecondaryBackend(
                using: transport,
                config: config,
                options: options,
                quietErrors: quietErrors
            )
        }

        currentStatus.activeMode = config.mode
        currentStatus.lastError = nil
        updateProgress(phase: .scanning, detail: "正在连接\(config.mode.localizedLabel)…", progress: 0.04, forceBroadcast: true)
        let start = ContinuousClock.now
        let opCursorKey = options.backendID.map { "backend.opCursor.\($0.uuidString)" }
        do {
            let sharedRootID = config.mode == .directAPIWithGDirect ? config.resolvedSharedFolderID : nil
            let rootPath = Self.resolvedRootPath(for: config)
            updateProgress(phase: .scanning, detail: "正在连接\(config.mode.localizedLabel)并检查目录…", progress: 0.06, forceBroadcast: true)
            async let accountTask = transport.accountInfo()
            async let layoutTask = makeLayout(using: transport, rootPath: rootPath, sharedRootID: sharedRootID)
            let (account, layoutResult) = try await (accountTask, layoutTask)
            currentStatus.account = account
            let layout = layoutResult.layout
            let scopePrefix: String = {
                if let bid = options.backendID, bid != SyncBackendProfile.legacyPrimaryID {
                    return "remote.backend.\(bid.uuidString)."
                }
                return "remote."
            }()
            let scope = scopePrefix + DriveFiles.stableUUID("\(transport.displayName):\(account.email):\(layout.root)").uuidString

            var report = SyncReport()
            updateProgress(phase: .downloading(completed: 0, total: 0), detail: "正在并行拉取元数据与目录结构…", progress: 0.12, forceBroadcast: true)

            async let manifestTask: Void = updateManifest(layout, existingManifest: layoutResult.manifestFile, scope: scope, transport: transport)
            async let remoteThumbnailsTask: [String: RemoteDriveFile] = {
                guard config.syncThumbnails else { return [:] }
                return Self.keyedByNameStatic(try await transport.listFiles(inFolderID: layout.thumbnails))
            }()
            async let inventoryTask = fetchInventory(
                layout,
                transport: transport,
                scope: scope,
                forceFullCrawl: sharedRootID != nil
            )

            var pulled = try await pullOps(layout, from: transport, scope: scope, syncEmbeddings: config.syncEmbeddings)
            report.downloadedOps += pulled.count
            var changedBoards = pulled.boards
            if pulled.count > 0 {
                notifyProgressiveMetadata(hasBoards: !changedBoards.isEmpty)
            }

            try await manifestTask
            let remoteThumbnails = try await remoteThumbnailsTask

            var prefetchedThumbnailStamps: [String: String]?
            if config.syncThumbnails && !remoteThumbnails.isEmpty {
                prefetchedThumbnailStamps = try await downloadMissingRemoteThumbnails(
                    files: remoteThumbnails,
                    dirty: nil,
                    scope: scope,
                    transport: transport,
                    progressStart: 0.22,
                    progressSpan: 0.22
                )
            }

            let cursorSeq: Int64 = if options.deferOpPruning, let opCursorKey {
                (try? await database.state(opCursorKey, as: Int64.self)) ?? 0
            } else {
                0
            }
            let pending = options.deferOpPruning
                ? try await database.pendingOps(afterSeq: cursorSeq, as: SyncOperation.self, limit: 10_000)
                : try await database.pendingOps(as: SyncOperation.self, limit: 10_000)
            currentStatus.pendingOpCount = pending.count
            updateProgress(phase: .scanning, detail: "正在比对云端与本地目录…", progress: 0.46, forceBroadcast: true)
            let inventory = try await inventoryTask
            let reconciled = try await reconcile(
                inventory,
                layout: layout,
                transport: transport,
                config: config,
                pending: pending,
                remoteThumbnails: remoteThumbnails
            )
            report.discoveredRemoteAssets = reconciled.discovered
            report.discoveredAssetIDs = reconciled.discoveredIDs
            report.reconciledRenames = reconciled.renames
            var savedFiles = inventory.current.files
            for deferredID in reconciled.deferredFileIDs {
                savedFiles.removeValue(forKey: deferredID)
            }
            for removedID in reconciled.removedFileIDs {
                savedFiles.removeValue(forKey: removedID)
            }
            var state = SavedInventory(files: savedFiles, startPageToken: inventory.current.startPageToken)
            let inventoryUnchanged = inventory.previousStartPageToken == inventory.current.startPageToken
                && savedFiles == inventory.previous
            if !inventoryUnchanged {
                try await database.setState(scope + ".inventory", state)
            }

            if !pending.isEmpty {
                updateProgress(phase: .uploading(completed: 0, total: pending.count), detail: "准备上传本地新增与变更…", progress: 0.68, forceBroadcast: true)
                let uploadResult = try await uploadPhysical(for: pending.map { $0.1 }, layout: layout, transport: transport, scope: scope)
                var inventoryMutated = false
                if !uploadResult.removedFiles.isEmpty {
                    for removedID in uploadResult.removedFiles {
                        savedFiles.removeValue(forKey: removedID)
                    }
                    inventoryMutated = true
                }
                if !uploadResult.removedFolders.isEmpty {
                    for removedFolderID in uploadResult.removedFolders {
                        savedFiles.removeValue(forKey: removedFolderID)
                    }
                    inventoryMutated = true
                }
                if !uploadResult.renamedPrefixes.isEmpty {
                    savedFiles = Self.applyingRenamedPrefixes(uploadResult.renamedPrefixes, to: savedFiles)
                    inventoryMutated = true
                }
                if inventoryMutated {
                    state = SavedInventory(files: savedFiles, startPageToken: inventory.current.startPageToken)
                    try await database.setState(scope + ".inventory", state)
                }
            }
            let ready = options.deferOpPruning
                ? try await database.pendingOps(afterSeq: cursorSeq, as: SyncOperation.self, limit: 10_000)
                : try await database.pendingOps(as: SyncOperation.self, limit: 10_000)
            var publishable: [(Int64, SyncOperation)] = []
            let cutoff = pending.last?.0 ?? 0
            for row in ready {
                if row.0 > cutoff {
                    let isUploadBinding: Bool
                    switch row.1.change {
                    case .asset(let delta):
                        isUploadBinding = row.1.projectLocation == false
                            && !delta.fields.isEmpty
                            && delta.fields["driveFileID"] != nil
                            && delta.fields.keys.allSatisfy { $0 == "driveFileID" || $0 == "fileName" }
                            && delta.tagsAdded.isEmpty
                            && delta.tagsRemoved.isEmpty
                    case .folder:
                        isUploadBinding = row.1.projectLocation == false
                    default:
                        isUploadBinding = false
                    }
                    guard isUploadBinding else { break }
                }
                publishable.append(row)
                switch row.1.change {
                case .board(let delta): changedBoards.insert(delta.id)
                case .deleteBoard(let id): changedBoards.insert(id)
                default: break
                }
            }
            if !publishable.isEmpty {
                updateProgress(phase: .uploading(completed: 0, total: publishable.count), detail: "正在上传同步日志…", progress: 0.82, forceBroadcast: true)
                report.uploadedOps = try await pushOps(
                    publishable,
                    to: transport,
                    layout: layout,
                    syncEmbeddings: config.syncEmbeddings,
                    deferOpPruning: options.deferOpPruning,
                    cursorKey: opCursorKey
                )
                pulled = try await pullOps(layout, from: transport, scope: scope, syncEmbeddings: config.syncEmbeddings)
                report.downloadedOps += pulled.count
                changedBoards.formUnion(pulled.boards)
            } else if options.deferOpPruning, let opCursorKey {
                let latestSeq = (try? await database.maxPendingOpSeq()) ?? cursorSeq
                if latestSeq > cursorSeq {
                    try? await database.setState(opCursorKey, latestSeq)
                }
            }

            updateProgress(phase: .merging, detail: "正在同步情绪板与缩略图…", progress: 0.88, forceBroadcast: true)
            try await writeBoards(layout, transport: transport, scope: scope, changedBoards: changedBoards)
            if config.syncThumbnails {
                try await syncThumbnails(
                    layout,
                    transport: transport,
                    scope: scope,
                    prefetchedRemoteFiles: remoteThumbnails,
                    knownStamps: prefetchedThumbnailStamps
                )
            }
            if config.syncEmbeddings {
                updateProgress(phase: .merging, detail: "正在同步智能搜索索引…", progress: 0.94)
                try await writeEmbeddings(layout, transport: transport)
            }
            if report.discoveredRemoteAssets > 0 || report.reconciledRenames > 0 || !changedBoards.isEmpty {
                notifyProgressiveMetadata(hasBoards: !changedBoards.isEmpty)
            }
            try await fetchPinnedOriginals(using: transport)
            try await database.removeDeletedMedia(using: media)
            report.updatedBoards = changedBoards.count
            let duration = start.duration(to: .now).components
            report.durationSeconds = Double(duration.seconds) + Double(duration.attoseconds) / 1e18
            currentStatus.lastSyncedAt = Date()
            currentStatus.lastError = nil
            currentStatus.pendingOpCount = (try? await database.pendingOpCount()) ?? 0
            currentStatus.phase = .idle
            currentStatus.currentDetail = nil
            currentStatus.progressFraction = nil
            try await database.setState("lastSyncStatus", currentStatus)
            broadcastCurrentStatus()
            return report
        } catch {
            if error is CancellationError || quietErrors {
                currentStatus.phase = .idle
                currentStatus.currentDetail = nil
                currentStatus.progressFraction = nil
            } else {
                currentStatus.phase = .error(error.localizedDescription)
                currentStatus.lastError = error.localizedDescription
                currentStatus.currentDetail = error.localizedDescription
                currentStatus.progressFraction = nil
            }
            broadcastCurrentStatus()
            throw error
        }
    }

    /// Non-clobbering bidirectional mirror sync for simultaneously connected secondary backends
    /// (e.g. iCloud Drive or WebDAV running alongside primary Google Drive).
    /// Keeps its own per-backend remote folder/asset ID maps and op cursor so primary `driveFileID` bindings
    /// are never overwritten and local changes fan out cleanly across all enabled backends.
    private func syncSecondaryBackend(
        using transport: any DriveTransport,
        config: DriveSyncConfig,
        options: SyncExecutionOptions,
        quietErrors: Bool
    ) async throws -> SyncReport {
        let backendID = options.backendID ?? UUID()
        let start = ContinuousClock.now
        let opCursorKey = "backend.opCursor.\(backendID.uuidString)"
        let remoteAssetsKey = "backend.remoteAssets.\(backendID.uuidString)"
        let remoteFoldersKey = "backend.remoteFolders.\(backendID.uuidString)"

        updateProgress(phase: .scanning, detail: "正在连接\(config.mode.localizedLabel)…", progress: 0.08, forceBroadcast: true)
        do {
            let sharedRootID = config.mode == .directAPIWithGDirect ? config.resolvedSharedFolderID : nil
            let rootPath = Self.resolvedRootPath(for: config)
            async let accountTask = transport.accountInfo()
            async let layoutTask = makeLayout(using: transport, rootPath: rootPath, sharedRootID: sharedRootID)
            let (account, layoutResult) = try await (accountTask, layoutTask)
            let layout = layoutResult.layout
            let scope = "remote.backend.\(backendID.uuidString)." + DriveFiles.stableUUID("\(transport.displayName):\(account.email):\(layout.root)").uuidString

            var report = SyncReport()
            try await updateManifest(layout, existingManifest: layoutResult.manifestFile, scope: scope, transport: transport)

            // 1. Pull remote metadata ops & missing thumbnails from this secondary backend
            updateProgress(phase: .downloading(completed: 0, total: 0), detail: "拉取增量元数据与缩略图…", progress: 0.20, forceBroadcast: true)
            var pulled = try await pullOps(layout, from: transport, scope: scope, syncEmbeddings: config.syncEmbeddings)
            report.downloadedOps += pulled.count
            var changedBoards = pulled.boards
            if pulled.count > 0 {
                notifyProgressiveMetadata(hasBoards: !changedBoards.isEmpty)
            }

            let remoteThumbnails: [String: RemoteDriveFile] = if config.syncThumbnails {
                Self.keyedByNameStatic(try await transport.listFiles(inFolderID: layout.thumbnails))
            } else { [:] }
            var prefetchedThumbnailStamps: [String: String]?
            if config.syncThumbnails && !remoteThumbnails.isEmpty {
                prefetchedThumbnailStamps = try await downloadMissingRemoteThumbnails(
                    files: remoteThumbnails,
                    dirty: nil,
                    scope: scope,
                    transport: transport,
                    progressStart: 0.25,
                    progressSpan: 0.15
                )
            }

            // 2. Mirror active folder hierarchy into this secondary backend using isolated remote folder IDs
            var remoteFolders: [String: String] = (try? await database.state(remoteFoldersKey)) ?? [:]
            var remoteAssets: [String: String] = (try? await database.state(remoteAssetsKey)) ?? [:]

            let allFolders = try await database.fetchFolders()
            let foldersByID = Dictionary(uniqueKeysWithValues: allFolders.map { ($0.id, $0) })
            let existingAssetIDs = try await database.existingAssetIDs()

            // 2a. Propagate permanent asset deletions to this secondary backend so deleted files never linger or resurrect
            var staleSecondaryAssetKeys: [(key: String, remoteID: String)] = []
            for (assetIDStr, remoteFileID) in remoteAssets {
                guard let uuid = UUID(uuidString: assetIDStr) else {
                    staleSecondaryAssetKeys.append((assetIDStr, remoteFileID))
                    continue
                }
                if !existingAssetIDs.contains(uuid) {
                    staleSecondaryAssetKeys.append((assetIDStr, remoteFileID))
                }
            }
            if !staleSecondaryAssetKeys.isEmpty {
                let trashConcurrency = Self.concurrencyLimit(for: transport, directDefault: 4)
                _ = try await Self.runBounded(items: staleSecondaryAssetKeys, maxConcurrent: trashConcurrency) { item in
                    if Self.isRemoteIDCompatible(item.remoteID, with: transport) {
                        try await Self.trashIfPresentStatic(item.remoteID, transport: transport)
                    }
                }
                for item in staleSecondaryAssetKeys {
                    remoteAssets.removeValue(forKey: item.key)
                }
            }

            // 2b. Propagate deleted folders to this secondary backend (deepest-first, only when empty)
            var staleSecondaryFolderKeys: [(key: String, remoteID: String)] = []
            for (folderIDStr, remoteFolderID) in remoteFolders {
                guard let uuid = UUID(uuidString: folderIDStr), foldersByID[uuid] != nil else {
                    staleSecondaryFolderKeys.append((folderIDStr, remoteFolderID))
                    continue
                }
            }
            if !staleSecondaryFolderKeys.isEmpty {
                let compatibleFolderIDs = staleSecondaryFolderKeys
                    .map(\.remoteID)
                    .filter { Self.isRemoteIDCompatible($0, with: transport) }
                _ = try await Self.trashEmptyFoldersDeepestFirst(
                    compatibleFolderIDs,
                    inventoryFiles: [:],
                    transport: transport
                )
                for item in staleSecondaryFolderKeys {
                    remoteFolders.removeValue(forKey: item.key)
                }
            }

            updateProgress(phase: .uploading(completed: 0, total: allFolders.count), detail: "同步目录结构…", progress: 0.45, forceBroadcast: true)
            for folder in allFolders {
                _ = try await ensureSecondaryFolder(
                    folder.id,
                    foldersByID: foldersByID,
                    layoutRoot: layout.root,
                    transport: transport,
                    remoteFolders: &remoteFolders
                )
            }

            // 3. Mirror locally cached active assets onto this secondary backend without clobbering primary driveFileID
            let activeAssets = try await database.fetchAssets(matching: FilterCriteria(includeTrashed: false))
            var parentListingCache: [String: [RemoteDriveFile]] = [:]
            let unmappedCached = activeAssets.filter { asset in
                remoteAssets[asset.id.uuidString] == nil && media.cachedOriginal(for: asset) != nil
            }
            if !unmappedCached.isEmpty {
                let total = unmappedCached.count
                for (index, asset) in unmappedCached.enumerated() {
                    guard let localURL = media.cachedOriginal(for: asset) else { continue }
                    let targetParentID: String = if let fid = asset.folderID {
                        try await ensureSecondaryFolder(
                            fid,
                            foldersByID: foldersByID,
                            layoutRoot: layout.root,
                            transport: transport,
                            remoteFolders: &remoteFolders
                        )
                    } else {
                        layout.inbox
                    }
                    let existingFiles: [RemoteDriveFile]
                    if let cached = parentListingCache[targetParentID] {
                        existingFiles = cached
                    } else {
                        let listed = (try? await transport.listFiles(inFolderID: targetParentID)) ?? []
                        parentListingCache[targetParentID] = listed
                        existingFiles = listed
                    }

                    let safeName = DriveFiles.sanitizedFileName(asset.fileName)
                    let shortID = String(asset.id.uuidString.lowercased().prefix(8))
                    if let match = existingFiles.first(where: { !$0.isFolder && ($0.name == safeName || $0.name.lowercased().contains(shortID)) }) {
                        remoteAssets[asset.id.uuidString] = match.id
                        continue
                    }

                    let uploadedName: String
                    if existingFiles.contains(where: { $0.name.caseInsensitiveCompare(safeName) == .orderedSame }) {
                        let base = (safeName as NSString).deletingPathExtension
                        let ext = (safeName as NSString).pathExtension
                        uploadedName = ext.isEmpty ? "\(base) (\(shortID))" : "\(base) (\(shortID)).\(ext)"
                    } else {
                        uploadedName = safeName
                    }

                    let mime = DriveFiles.mimeType(for: localURL)
                    let uploaded = try await transport.uploadFile(
                        from: localURL,
                        name: uploadedName,
                        mimeType: mime,
                        parentID: targetParentID,
                        existingFileID: nil
                    )
                    remoteAssets[asset.id.uuidString] = uploaded.id
                    parentListingCache[targetParentID, default: []].append(uploaded)

                    let frac = 0.50 + 0.25 * (Double(index + 1) / Double(max(1, total)))
                    updateProgress(
                        phase: .uploading(completed: index + 1, total: total),
                        detail: "镜像素材 (\(index + 1)/\(total))",
                        progress: frac
                    )
                }
            }

            try await database.setState(remoteFoldersKey, remoteFolders)
            try await database.setState(remoteAssetsKey, remoteAssets)

            // 4. Push local metadata/board ops after this backend's cursor (excluding primary-only driveFileID bindings)
            let cursorSeq: Int64 = (try? await database.state(opCursorKey, as: Int64.self)) ?? 0
            let pendingAfterCursor = try await database.pendingOps(afterSeq: cursorSeq, as: SyncOperation.self, limit: 10_000)
            let secondaryOps = pendingAfterCursor.filter { row in
                switch row.1.change {
                case .asset(let delta):
                    let isPrimaryBindingOnly = row.1.projectLocation == false
                        && delta.fields["driveFileID"] != nil
                        && delta.fields.keys.allSatisfy { $0 == "driveFileID" || $0 == "fileName" }
                        && delta.tagsAdded.isEmpty
                        && delta.tagsRemoved.isEmpty
                    return !isPrimaryBindingOnly
                case .folder:
                    return row.1.projectLocation != false
                default:
                    return true
                }
            }
            if !secondaryOps.isEmpty {
                updateProgress(phase: .uploading(completed: 0, total: secondaryOps.count), detail: "上传同步日志…", progress: 0.78, forceBroadcast: true)
                report.uploadedOps = try await pushOps(
                    secondaryOps,
                    to: transport,
                    layout: layout,
                    syncEmbeddings: config.syncEmbeddings,
                    deferOpPruning: true,
                    cursorKey: opCursorKey
                )
                pulled = try await pullOps(layout, from: transport, scope: scope, syncEmbeddings: config.syncEmbeddings)
                report.downloadedOps += pulled.count
                changedBoards.formUnion(pulled.boards)
            }
            if let lastSeq = pendingAfterCursor.last?.0, lastSeq > cursorSeq {
                try await database.setState(opCursorKey, lastSeq)
            }

            // 5. Mirror boards, thumbnails, and search embeddings
            updateProgress(phase: .merging, detail: "同步情绪板与缩略图…", progress: 0.88, forceBroadcast: true)
            try await writeBoards(layout, transport: transport, scope: scope, changedBoards: changedBoards)
            if config.syncThumbnails {
                try await syncThumbnails(
                    layout,
                    transport: transport,
                    scope: scope,
                    prefetchedRemoteFiles: remoteThumbnails,
                    knownStamps: prefetchedThumbnailStamps
                )
            }
            if config.syncEmbeddings {
                try await writeEmbeddings(layout, transport: transport)
            }

            report.updatedBoards = changedBoards.count
            let duration = start.duration(to: .now).components
            report.durationSeconds = Double(duration.seconds) + Double(duration.attoseconds) / 1e18
            return report
        } catch {
            if !quietErrors, !(error is CancellationError) {
                updateProgress(phase: .error(error.localizedDescription), detail: error.localizedDescription, progress: nil, forceBroadcast: true)
            }
            throw error
        }
    }

    private func ensureSecondaryFolder(
        _ folderID: UUID,
        foldersByID: [UUID: FolderRecord],
        layoutRoot: String,
        transport: any DriveTransport,
        remoteFolders: inout [String: String],
        visited: Set<UUID> = []
    ) async throws -> String {
        if let cached = remoteFolders[folderID.uuidString] {
            return cached
        }
        guard !visited.contains(folderID), let folder = foldersByID[folderID] else {
            return layoutRoot
        }
        var nextVisited = visited
        nextVisited.insert(folderID)
        let parentRemoteID: String = if let parentID = folder.parentID {
            try await ensureSecondaryFolder(
                parentID,
                foldersByID: foldersByID,
                layoutRoot: layoutRoot,
                transport: transport,
                remoteFolders: &remoteFolders,
                visited: nextVisited
            )
        } else {
            layoutRoot
        }
        let safeName = DriveFiles.sanitizedFileName(folder.name)
        let remote = try await transport.findOrCreateFolder(named: safeName, parentID: parentRemoteID)
        remoteFolders[folderID.uuidString] = remote.id
        return remote.id
    }

    public func downloadOriginal(
        for assetID: UUID,
        using transport: any DriveTransport,
        remoteFileIDOverride: String? = nil
    ) async throws -> URL {
        if let inFlight = originalDownloads[assetID] { return try await inFlight.value }
        let task = Task { try await copyOriginal(for: assetID, using: transport, remoteFileIDOverride: remoteFileIDOverride) }
        originalDownloads[assetID] = task
        defer { originalDownloads.removeValue(forKey: assetID) }
        return try await task.value
    }

    private func copyOriginal(
        for assetID: UUID,
        using transport: any DriveTransport,
        remoteFileIDOverride: String? = nil
    ) async throws -> URL {
        guard let asset = try await database.asset(id: assetID),
              let remote = remoteFileIDOverride ?? asset.driveFileID else {
            throw DriveTransportError.fileNotFound(assetID.uuidString)
        }
        let target = media.staging.appending(path: "original-" + assetID.uuidString)
        try await transport.downloadFile(fileID: remote, to: target)
        defer { try? FileManager.default.removeItem(at: target) }
        return try await database.transaction { [media] store in
            guard var current = try store.asset(id: assetID),
                  (remoteFileIDOverride != nil || current.driveFileID == remote) else {
                throw DriveTransportError.fileNotFound(assetID.uuidString)
            }
            let url = try media.installOriginal(target, for: current)
            current.isLocalOriginalCached = true
            try store.put(current)
            try store.touchOriginal(assetID)
            return url
        }
    }

    private func fetchPinnedOriginals(using transport: any DriveTransport) async throws {
        var missing: [UUID] = []
        for id in try await database.protectedAssetIDs() {
            guard let asset = try await database.asset(id: id), asset.driveFileID != nil,
                  media.cachedOriginal(for: asset) == nil else { continue }
            missing.append(id)
        }
        guard !missing.isEmpty else { return }
        let limit = Self.concurrencyLimit(for: transport, directDefault: 4)
        let total = missing.count
        var done = 0
        updateProgress(
            phase: .downloading(completed: 0, total: total),
            detail: "下载常驻本地原图 (0/\(total))",
            progress: 0.97,
            forceBroadcast: true
        )
        try await withThrowingTaskGroup(of: Void.self) { group in
            var nextIndex = 0
            while nextIndex < min(limit, missing.count) {
                let id = missing[nextIndex]
                nextIndex += 1
                group.addTask { _ = try await self.downloadOriginal(for: id, using: transport) }
            }
            while try await group.next() != nil {
                done += 1
                updateProgress(
                    phase: .downloading(completed: done, total: total),
                    detail: "下载常驻本地原图 (\(done)/\(total))",
                    progress: 0.97 + 0.02 * (Double(done) / Double(max(1, total)))
                )
                if nextIndex < missing.count {
                    let id = missing[nextIndex]
                    nextIndex += 1
                    group.addTask { _ = try await self.downloadOriginal(for: id, using: transport) }
                }
            }
        }
    }

    private struct Layout: Sendable {
        let root: String
        let inbox: String
        let metadata: String
        let ops: String
        let boards: String
        let embeddings: String
        let thumbnails: String
    }

    private struct Manifest: Codable {
        let version: Int
        let rootFolderID: String?
        let directories: [String: String]?
    }

    private static func resolvedRootPath(for config: DriveSyncConfig) -> String {
        switch config.mode {
        case .webDAV:
            return config.webDAVRemotePath
        case .iCloudDrive:
            let custom = config.iCloudCustomFolderPath.trimmingCharacters(in: .whitespacesAndNewlines)
            if !custom.isEmpty {
                let url = URL(fileURLWithPath: (custom as NSString).expandingTildeInPath, isDirectory: true).standardizedFileURL
                return url.lastPathComponent.isEmpty ? "Charkle" : url.lastPathComponent
            }
            let cleaned = config.iCloudFolderName.trimmingCharacters(in: .whitespacesAndNewlines)
            return cleaned.isEmpty ? "Charkle" : cleaned
        case .localOnly:
            let url = URL(fileURLWithPath: (config.localLibraryPath as NSString).expandingTildeInPath, isDirectory: true).standardizedFileURL
            return url.lastPathComponent.isEmpty ? "Charkle" : url.lastPathComponent
        case .directAPIWithGDirect, .gdirectMount:
            return config.rootFolderName
        }
    }

    private func makeLayout(
        using transport: any DriveTransport,
        rootPath: String,
        sharedRootID: String? = nil
    ) async throws -> (layout: Layout, manifestFile: RemoteDriveFile?) {
        let root: RemoteDriveFile
        if let sharedRootID, !sharedRootID.isEmpty {
            root = try await transport.resolveFolder(id: sharedRootID)
        } else {
            let segments = rootPath
                .split(separator: "/")
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty && $0 != "." && $0 != ".." }
            let finalSegments = segments.isEmpty ? ["Charkle"] : segments
            var currentParentID = DriveFiles.rootID
            var rootFile: RemoteDriveFile?
            for segment in finalSegments {
                try DriveFiles.validateName(segment)
                let created = try await transport.findOrCreateFolder(named: segment, parentID: currentParentID)
                currentParentID = created.id
                rootFile = created
            }
            guard let resolvedRoot = rootFile else {
                throw DriveTransportError.notConfigured("请指定有效的素材库保存路径。")
            }
            root = resolvedRoot
        }

        // Single directory listing for root resolves both `Inbox` and `.charkle` without 2 separate queries
        let rootChildren = try await transport.listFiles(inFolderID: root.id)
        let existingInbox = Self.oldestSubfolder(named: "Inbox", in: rootChildren)
        let existingMeta = Self.oldestSubfolder(named: ".charkle", in: rootChildren)

        async let inboxFolder: RemoteDriveFile = {
            if let existingInbox { return existingInbox }
            return try await transport.findOrCreateFolder(named: "Inbox", parentID: root.id)
        }()
        let metadata: RemoteDriveFile = if let existingMeta {
            existingMeta
        } else {
            try await transport.findOrCreateFolder(named: ".charkle", parentID: root.id)
        }

        // Single directory listing for `.charkle` resolves all 4 system subfolders AND `manifest.json`
        let metaChildren = try await transport.listFiles(inFolderID: metadata.id)
        let existingOps = Self.oldestSubfolder(named: "ops", in: metaChildren)
        let existingBoards = Self.oldestSubfolder(named: "boards", in: metaChildren)
        let existingEmbeddings = Self.oldestSubfolder(named: "embeddings", in: metaChildren)
        let existingThumbnails = Self.oldestSubfolder(named: "thumbnails", in: metaChildren)
        let manifestFile = metaChildren.first(where: { !$0.isFolder && $0.name == "manifest.json" })

        async let ops: RemoteDriveFile = {
            if let existingOps { return existingOps }
            return try await transport.findOrCreateFolder(named: "ops", parentID: metadata.id)
        }()
        async let boards: RemoteDriveFile = {
            if let existingBoards { return existingBoards }
            return try await transport.findOrCreateFolder(named: "boards", parentID: metadata.id)
        }()
        async let embeddings: RemoteDriveFile = {
            if let existingEmbeddings { return existingEmbeddings }
            return try await transport.findOrCreateFolder(named: "embeddings", parentID: metadata.id)
        }()
        async let thumbnails: RemoteDriveFile = {
            if let existingThumbnails { return existingThumbnails }
            return try await transport.findOrCreateFolder(named: "thumbnails", parentID: metadata.id)
        }()
        let layout = try await Layout(
            root: root.id,
            inbox: inboxFolder.id,
            metadata: metadata.id,
            ops: ops.id,
            boards: boards.id,
            embeddings: embeddings.id,
            thumbnails: thumbnails.id
        )
        return (layout, manifestFile)
    }

    private static func oldestSubfolder(named name: String, in files: [RemoteDriveFile]) -> RemoteDriveFile? {
        files
            .filter { $0.isFolder && $0.name == name }
            .min { ($0.modifiedTime ?? .distantPast, $0.id) < ($1.modifiedTime ?? .distantPast, $1.id) }
    }

    private func updateManifest(
        _ layout: Layout,
        existingManifest: RemoteDriveFile?,
        scope: String,
        transport: any DriveTransport
    ) async throws {
        if let known = existingManifest {
            let stamp = known.id + ":" + (known.md5Checksum ?? String(known.modifiedTime?.timeIntervalSince1970 ?? 0))
            if try await database.state(scope + ".manifestVerified", as: String.self) == stamp {
                return
            }
            let data = try await transport.downloadData(fileID: known.id)
            let manifest = try JSONDecoder().decode(Manifest.self, from: data)
            guard manifest.version == 1 else {
                throw DriveTransportError.invalidResponse("Unsupported Charkle sync protocol \(manifest.version).")
            }
            try await database.setState(scope + ".manifestVerified", stamp)
            return
        }
        let mounted = transport is MountedVolumeTransport
        let manifest = Manifest(version: 1, rootFolderID: mounted ? nil : layout.root, directories: mounted ? nil : [
            "Inbox": layout.inbox, "ops": layout.ops, "boards": layout.boards,
            "embeddings": layout.embeddings, "thumbnails": layout.thumbnails
        ])
        let data = try encoded(manifest)
        let uploaded = try await write(data, name: "manifest.json", mime: "application/json", parent: layout.metadata,
                                       existing: nil, transport: transport)
        let stamp = uploaded.id + ":" + (uploaded.md5Checksum ?? String(uploaded.modifiedTime?.timeIntervalSince1970 ?? 0))
        try await database.setState(scope + ".manifestVerified", stamp)
    }

    private struct LogLine: Codable, Sendable {
        let seq: Int64
        let operation: SyncOperation
    }

    private struct LogFile: Sendable {
        let file: RemoteDriveFile
        let device: String
        let end: Int64

        init?(_ file: RemoteDriveFile) {
            guard !file.isFolder, file.name.hasPrefix("ops-"), file.name.hasSuffix(".jsonl") else { return nil }
            let parts = file.name.dropFirst(4).dropLast(6).split(separator: "-")
            guard parts.count == 2, let sequence = Int64(parts[1]), sequence > 0,
                  parts[0].count == 32, parts[0].allSatisfy(\.isHexDigit) else { return nil }
            self.file = file
            device = String(parts[0])
            end = sequence
        }
    }

    private func pullOps(_ layout: Layout, from transport: any DriveTransport, scope: String,
                         syncEmbeddings: Bool) async throws -> (count: Int, boards: Set<UUID>) {
        let device = try await database.deviceID()
        let rawFiles = try await transport.listFiles(inFolderID: layout.ops).compactMap(LogFile.init)
            .filter { $0.device != device }
        var cursors: [String: Int64] = try await database.state(scope + ".deviceCursors") ?? [:]

        // Keep each device's shards strictly ascending by `end`, while interleaving across devices
        // in chronological `modifiedTime` order so multi-device create/delete logs replay causally.
        let groupedByDevice = Dictionary(grouping: rawFiles.filter { $0.end > (cursors[$0.device] ?? 0) }, by: \.device)
        let queues: [[LogFile]] = groupedByDevice.keys.sorted().map { dev in
            groupedByDevice[dev, default: []].sorted { ($0.end, $0.file.id) < ($1.end, $1.file.id) }
        }
        var queueOffsets = Array(repeating: 0, count: queues.count)
        var pendingEntries: [LogFile] = []
        pendingEntries.reserveCapacity(rawFiles.count)
        while true {
            var bestQueue: Int?
            var bestKey: (Date, String, Int64, String)?
            for i in queues.indices {
                let offset = queueOffsets[i]
                guard offset < queues[i].count else { continue }
                let candidate = queues[i][offset]
                let key = (candidate.file.modifiedTime ?? .distantPast, candidate.device, candidate.end, candidate.file.id)
                if let currentBest = bestKey {
                    if key < currentBest {
                        bestKey = key
                        bestQueue = i
                    }
                } else {
                    bestKey = key
                    bestQueue = i
                }
            }
            guard let chosen = bestQueue else { break }
            pendingEntries.append(queues[chosen][queueOffsets[chosen]])
            queueOffsets[chosen] += 1
        }

        var downloaded = 0
        var boards = Set<UUID>()

        if !pendingEntries.isEmpty {
            let concurrency = Self.concurrencyLimit(for: transport, directDefault: 10)
            let totalShards = pendingEntries.count
            var completedShards = 0
            // Download unseen op shards in bounded parallel chunks, then sort operations by global
            // HLC `(stamp.time, stamp.device, seq)` and commit each chunk + cursor update atomically.
            let chunkSize = 40
            for chunkStart in stride(from: 0, to: totalShards, by: chunkSize) {
                try Task.checkCancellation()
                let chunkEnd = min(totalShards, chunkStart + chunkSize)
                let indexedSlice = (chunkStart..<chunkEnd).map { (index: $0, entry: pendingEntries[$0]) }

                struct DownloadedShard: Sendable {
                    let index: Int
                    let entry: LogFile
                    let lines: [LogLine]
                }

                let downloadedChunk = try await Self.runBounded(items: indexedSlice, maxConcurrent: concurrency) { item -> DownloadedShard in
                    try Task.checkCancellation()
                    let data = try await transport.downloadData(fileID: item.entry.file.id)
                    let decoder = JSONDecoder()
                    let lines = try data.split(separator: 0x0A).map { try decoder.decode(LogLine.self, from: Data($0)) }
                    guard !lines.isEmpty,
                          lines.last?.seq == item.entry.end,
                          lines.allSatisfy({ $0.operation.stamp.device == item.entry.device }),
                          zip(lines, lines.dropFirst()).allSatisfy({ $0.seq < $1.seq }) else {
                        throw DriveTransportError.invalidResponse("Malformed sync operation shard \(item.entry.file.name).")
                    }
                    return DownloadedShard(index: item.index, entry: item.entry, lines: lines)
                }.sorted { $0.index < $1.index }

                var pendingBatch: [(device: String, line: LogLine)] = []
                pendingBatch.reserveCapacity(512)
                var chunkBoards = Set<UUID>()

                for shard in downloadedChunk {
                    let previous = cursors[shard.entry.device] ?? 0
                    let unseen = shard.lines.filter { $0.seq > previous }
                    cursors[shard.entry.device] = max(previous, shard.entry.end)
                    for line in unseen {
                        pendingBatch.append((device: shard.entry.device, line: line))
                        switch line.operation.change {
                        case .board(let delta):
                            boards.insert(delta.id)
                            chunkBoards.insert(delta.id)
                        case .deleteBoard(let id):
                            boards.insert(id)
                            chunkBoards.insert(id)
                        default: break
                        }
                    }
                    downloaded += unseen.count
                    completedShards += 1
                }

                // Apply cross-device ops in global causal HLC order inside ONE atomic transaction
                // together with the chunk's updated cursors so a crash never skips unapplied ops.
                pendingBatch.sort { lhs, rhs in
                    let lStamp = lhs.line.operation.stamp
                    let rStamp = rhs.line.operation.stamp
                    if lStamp != rStamp { return lStamp < rStamp }
                    return (lhs.device, lhs.line.seq) < (rhs.device, rhs.line.seq)
                }

                if pendingBatch.isEmpty {
                    let updatedCursors = cursors
                    try await database.setState(scope + ".deviceCursors", updatedCursors)
                } else {
                    let batch = pendingBatch
                    let updatedCursors = cursors
                    try await database.transaction { store in
                        for item in batch {
                            if case .vector = item.line.operation.change, !syncEmbeddings {
                                try store.setState("disabled.vector.\(item.device).\(item.line.seq)", item.line.operation)
                            } else {
                                try store.apply(item.line.operation)
                            }
                        }
                        try store.setState(scope + ".deviceCursors", updatedCursors)
                    }
                }
                let ratio = 0.12 + 0.10 * (Double(completedShards) / Double(max(1, totalShards)))
                updateProgress(
                    phase: .downloading(completed: completedShards, total: totalShards),
                    detail: "拉取素材元数据 (\(completedShards)/\(totalShards))",
                    progress: ratio
                )
                if totalShards > chunkSize && chunkEnd < totalShards {
                    notifyProgressiveMetadata(hasBoards: !chunkBoards.isEmpty)
                }
            }
        }
        if syncEmbeddings {
            try await database.transaction { store in
                for (key, operation) in try store.states(withPrefix: "disabled.vector.", as: SyncOperation.self) {
                    try store.apply(operation)
                    try store.setState(key, Optional<SyncOperation>.none)
                }
            }
        }
        return (downloaded, boards)
    }

    private func pushOps(
        _ operations: [(Int64, SyncOperation)],
        to transport: any DriveTransport,
        layout: Layout,
        syncEmbeddings: Bool,
        deferOpPruning: Bool = false,
        cursorKey: String? = nil
    ) async throws -> Int {
        guard !operations.isEmpty else { return 0 }
        let device = try await database.deviceID()
        let known = keyedByName(try await transport.listFiles(inFolderID: layout.ops))
        var uploaded = 0
        for start in stride(from: 0, to: operations.count, by: 200) {
            let rows = operations[start..<min(operations.count, start + 200)]
            guard let end = rows.last?.0 else { continue }
            var bytes = Data()
            for (seq, op) in rows {
                if case .vector = op.change, !syncEmbeddings { continue }
                bytes.append(try encoded(LogLine(seq: seq, operation: op)))
                bytes.append(0x0A)
            }
            let lastIncluded = rows.last { row in
                if case .vector = row.1.change { return syncEmbeddings }
                return true
            }?.0
            if let lastIncluded {
                let name = "ops-\(device)-\(lastIncluded).jsonl"
                if let file = known[name] {
                    let remote = try await transport.downloadData(fileID: file.id)
                    guard remote == bytes else { throw DriveTransportError.invalidResponse("Conflicting operation shard \(name).") }
                } else {
                    do {
                        _ = try await transport.uploadData(bytes, name: name, mimeType: "application/x-ndjson",
                                                           parentID: layout.ops, existingFileID: nil)
                    } catch DriveTransportError.fileAlreadyExists {
                        if let existing = try await transport.listFiles(inFolderID: layout.ops).first(where: { $0.name == name }) {
                            let remote = try await transport.downloadData(fileID: existing.id)
                            guard remote == bytes else {
                                throw DriveTransportError.invalidResponse("Conflicting operation shard \(name).")
                            }
                        } else {
                            throw DriveTransportError.fileAlreadyExists(name)
                        }
                    }
                }
                uploaded += bytes.split(separator: 0x0A).count
            }
            if deferOpPruning, let cursorKey {
                try await database.setState(cursorKey, end)
            } else {
                try await database.acknowledgeOps(through: end)
            }
            let doneOps = min(operations.count, start + 200)
            let opRatio = 0.82 + 0.05 * (Double(doneOps) / Double(max(1, operations.count)))
            updateProgress(
                phase: .uploading(completed: doneOps, total: operations.count),
                detail: "同步变更日志 (\(doneOps)/\(operations.count))",
                progress: opRatio
            )
        }
        return uploaded
    }

    private func writeBoards(
        _ layout: Layout,
        transport: any DriveTransport,
        scope: String,
        changedBoards: Set<UUID>
    ) async throws {
        let dirty: [String: String] = try await database.state("projection.boards") ?? [:]
        let initialized = try await database.state(scope + ".boardsSynced", as: Bool.self) ?? false
        guard !dirty.isEmpty || !changedBoards.isEmpty || !initialized else { return }

        let files = keyedByName(try await transport.listFiles(inFolderID: layout.boards))
        let documents = try await database.fetchBoards()
        // Check the full file checksum so another device's last write cannot leave a stale board projection.
        let concurrency = Self.concurrencyLimit(for: transport, directDefault: 4)
        var writeJobs: [(id: String, name: String, data: Data, existing: RemoteDriveFile?, mark: String?)] = []
        writeJobs.reserveCapacity(documents.count)
        for document in documents {
            let id = document.id.uuidString
            let name = id.lowercased() + ".json"
            let data = try encoded(document)
            writeJobs.append((id: id, name: name, data: data, existing: files[name], mark: dirty[id]))
        }

        let clearedMarks = try await Self.runBounded(items: writeJobs, maxConcurrent: concurrency) { job -> (String, String)? in
            _ = try await Self.writeBlob(
                job.data,
                name: job.name,
                mime: "application/json",
                parent: layout.boards,
                existing: job.existing,
                transport: transport,
                allowOverwriteExisting: true
            )
            return job.mark.map { (job.id, $0) }
        }
        let active = Set(documents.map { $0.id.uuidString })
        var deletions: [(id: String, version: String, remoteID: String?)] = []
        for (id, version) in dirty where !active.contains(id) {
            deletions.append((id: id, version: version, remoteID: files[id.lowercased() + ".json"]?.id))
        }
        if !deletions.isEmpty {
            _ = try await Self.runBounded(items: deletions, maxConcurrent: concurrency) { item in
                if let remoteID = item.remoteID {
                    try await Self.trashIfPresentStatic(remoteID, transport: transport)
                }
            }
        }
        let deletionsToClear = deletions
        try await database.transaction { store in
            for pair in clearedMarks.compactMap({ $0 }) {
                try store.clearProjection("boards", id: pair.0, ifVersion: pair.1)
            }
            for item in deletionsToClear {
                try store.clearProjection("boards", id: item.id, ifVersion: item.version)
            }
            try store.setState(scope + ".boardsSynced", true)
        }
    }

    private struct EmbeddingBlob: Codable {
        let feature: Data?
        let semantic: Data?
        let precision: EmbeddingPrecision
        let model: String?
    }

    private func writeEmbeddings(_ layout: Layout, transport: any DriveTransport) async throws {
        let dirty: [String: String] = try await database.state("projection.embeddings") ?? [:]
        guard !dirty.isEmpty else { return }
        let files = keyedByName(try await transport.listFiles(inFolderID: layout.embeddings))
        let vectors = try await database.vectors()
        let grouped = Dictionary(grouping: dirty.keys) { String($0.lowercased().prefix(2)) }
        let shards = Dictionary(grouping: vectors.keys) { String($0.uuidString.lowercased().prefix(2)) }
        let concurrency = Self.concurrencyLimit(for: transport, directDefault: 6)

        struct ShardJob: Sendable {
            let name: String
            let existing: RemoteDriveFile?
            let touched: [(id: String, version: String)]
            let removedIDs: [String]
            let entries: [String: EmbeddingBlob]
        }

        var jobs: [ShardJob] = []
        jobs.reserveCapacity(grouped.count)
        for (prefix, touchedKeys) in grouped.sorted(by: { $0.key < $1.key }) {
            let name = "shard-\(prefix).bin"
            var entries: [String: EmbeddingBlob] = [:]
            for id in shards[prefix, default: []] {
                if let vector = vectors[id] {
                    entries[id.uuidString] = EmbeddingBlob(
                        feature: vector.featurePrint,
                        semantic: vector.embedding.map { vector.precision.encode($0) },
                        precision: vector.precision,
                        model: vector.embeddingModel
                    )
                }
            }
            let removed = touchedKeys.filter { UUID(uuidString: $0).map { vectors[$0] == nil } == true }
            let touchedPairs = touchedKeys.compactMap { id -> (String, String)? in
                dirty[id].map { (id, $0) }
            }
            jobs.append(ShardJob(
                name: name,
                existing: files[name],
                touched: touchedPairs,
                removedIDs: removed,
                entries: entries
            ))
        }

        let total = jobs.count
        var completed = 0
        var clearedBatch: [(String, String)] = []
        updateProgress(
            phase: .merging,
            detail: "同步智能搜索索引 (0/\(total))",
            progress: 0.94,
            forceBroadcast: true
        )
        try await withThrowingTaskGroup(of: [(String, String)].self) { group in
            var nextIndex = 0
            let enqueue: (inout ThrowingTaskGroup<[(String, String)], Error>) -> Void = { grp in
                guard nextIndex < total else { return }
                let job = jobs[nextIndex]
                nextIndex += 1
                grp.addTask {
                    var shard: [String: EmbeddingBlob] = [:]
                    if let existing = job.existing {
                        let data = try await transport.downloadData(fileID: existing.id)
                        if !data.isEmpty,
                           let decoded = try? PropertyListDecoder().decode([String: EmbeddingBlob].self, from: data) {
                            shard = decoded
                        }
                    }
                    for (key, value) in job.entries {
                        shard[key] = value
                    }
                    for id in job.removedIDs {
                        shard.removeValue(forKey: id)
                    }
                    let encoder = PropertyListEncoder()
                    encoder.outputFormat = .binary
                    _ = try await Self.writeBlob(
                        encoder.encode(shard),
                        name: job.name,
                        mime: "application/octet-stream",
                        parent: layout.embeddings,
                        existing: job.existing,
                        transport: transport,
                        allowOverwriteExisting: true
                    )
                    return job.touched
                }
            }
            for _ in 0..<min(concurrency, total) { enqueue(&group) }
            while let touched = try await group.next() {
                enqueue(&group)
                clearedBatch.append(contentsOf: touched)
                completed += 1
                if clearedBatch.count >= 25 {
                    let flush = clearedBatch
                    clearedBatch.removeAll(keepingCapacity: true)
                    try await database.transaction { store in
                        for (id, version) in flush {
                            try store.clearProjection("embeddings", id: id, ifVersion: version)
                        }
                    }
                }
                updateProgress(
                    phase: .merging,
                    detail: "同步智能搜索索引 (\(completed)/\(total))",
                    progress: 0.94 + 0.03 * (Double(completed) / Double(max(1, total)))
                )
            }
        }
        if !clearedBatch.isEmpty {
            let flush = clearedBatch
            try await database.transaction { store in
                for (id, version) in flush {
                    try store.clearProjection("embeddings", id: id, ifVersion: version)
                }
            }
        }
    }

    private func syncThumbnails(
        _ layout: Layout,
        transport: any DriveTransport,
        scope: String,
        prefetchedRemoteFiles: [String: RemoteDriveFile]? = nil,
        knownStamps: [String: String]? = nil
    ) async throws {
        let files: [String: RemoteDriveFile]
        if let prefetchedRemoteFiles {
            files = prefetchedRemoteFiles
        } else {
            files = keyedByName(try await transport.listFiles(inFolderID: layout.thumbnails))
        }
        let dirty: [String: String] = try await database.state("projection.thumbnails") ?? [:]
        let concurrency = Self.concurrencyLimit(for: transport, directDefault: 8)

        let existingAssetIDs = try await database.existingAssetIDs()

        // 1. Upload or delete dirty local thumbnails in bounded parallel (with live progress)
        struct ThumbUploadJob: Sendable {
            let id: String
            let version: String
            let name: String
            let assetExists: Bool
            let localURL: URL?
            let existing: RemoteDriveFile?
        }
        var uploadJobs: [ThumbUploadJob] = []
        uploadJobs.reserveCapacity(dirty.count)
        for (id, version) in dirty {
            guard let uuid = UUID(uuidString: id) else { continue }
            let name = id.lowercased() + ".jpg"
            let assetExists = existingAssetIDs.contains(uuid)
            let localURL = assetExists ? media.thumbnailURL(for: uuid, tier: .grid520) : nil
            uploadJobs.append(ThumbUploadJob(
                id: id,
                version: version,
                name: name,
                assetExists: assetExists,
                localURL: localURL,
                existing: files[name]
            ))
        }
        if !uploadJobs.isEmpty {
            let totalUploads = uploadJobs.count
            var completedUploads = 0
            var clearedBatch: [(String, String)] = []
            clearedBatch.reserveCapacity(32)
            updateProgress(
                phase: .uploading(completed: 0, total: totalUploads),
                detail: "同步缩略图 (0/\(totalUploads))",
                progress: 0.88,
                forceBroadcast: true
            )
            try await withThrowingTaskGroup(of: (String, String).self) { group in
                var nextIndex = 0
                let enqueue: (inout ThrowingTaskGroup<(String, String), Error>) -> Void = { grp in
                    guard nextIndex < totalUploads else { return }
                    let job = uploadJobs[nextIndex]
                    nextIndex += 1
                    grp.addTask {
                        if let localURL = job.localURL {
                            let data = try Data(contentsOf: localURL)
                            _ = try await Self.writeBlob(
                                data,
                                name: job.name,
                                mime: "image/jpeg",
                                parent: layout.thumbnails,
                                existing: job.existing,
                                transport: transport,
                                allowOverwriteExisting: true
                            )
                        } else if !job.assetExists, let existing = job.existing {
                            try await Self.trashIfPresentStatic(existing.id, transport: transport)
                        }
                        return (job.id, job.version)
                    }
                }
                for _ in 0..<min(concurrency, totalUploads) { enqueue(&group) }
                while let done = try await group.next() {
                    enqueue(&group)
                    clearedBatch.append(done)
                    completedUploads += 1
                    if clearedBatch.count >= 25 {
                        let flush = clearedBatch
                        clearedBatch.removeAll(keepingCapacity: true)
                        try await database.transaction { store in
                            for (id, version) in flush {
                                try store.clearProjection("thumbnails", id: id, ifVersion: version)
                            }
                        }
                    }
                    let ratio = 0.88 + 0.03 * (Double(completedUploads) / Double(max(1, totalUploads)))
                    updateProgress(
                        phase: .uploading(completed: completedUploads, total: totalUploads),
                        detail: "上传缩略图 (\(completedUploads)/\(totalUploads))",
                        progress: ratio
                    )
                }
            }
            if !clearedBatch.isEmpty {
                let flush = clearedBatch
                try await database.transaction { store in
                    for (id, version) in flush {
                        try store.clearProjection("thumbnails", id: id, ifVersion: version)
                    }
                }
            }
        }

        // 2. Download any remaining missing or updated remote thumbnails (stragglers discovered after Stage 2)
        _ = try await downloadMissingRemoteThumbnails(
            files: files,
            dirty: dirty,
            scope: scope,
            transport: transport,
            progressStart: 0.91,
            progressSpan: 0.03,
            initialStamps: knownStamps
        )
    }

    /// Downloads missing or updated `.grid520` remote thumbnails in newest-first (`created_at DESC`)
    /// priority order with high HTTP/2 concurrency and progressive UI painting notifications so a fresh
    /// install displays crisp top-of-gallery thumbnails within seconds.
    @discardableResult
    private func downloadMissingRemoteThumbnails(
        files: [String: RemoteDriveFile],
        dirty: [String: String]?,
        scope: String,
        transport: any DriveTransport,
        progressStart: Double,
        progressSpan: Double,
        initialStamps: [String: String]? = nil
    ) async throws -> [String: String] {
        let dirtyMap: [String: String]
        if let dirty {
            dirtyMap = dirty
        } else {
            dirtyMap = try await database.state("projection.thumbnails") ?? [:]
        }
        let createdAtByID = try await database.assetCreatedAtByID()
        var stamps: [String: String]
        if let initialStamps {
            stamps = initialStamps
        } else {
            stamps = try await database.state(scope + ".thumbnails") ?? [:]
        }
        var stampsDirty = false

        struct ThumbDownloadJob: Sendable {
            let id: UUID
            let key: String
            let stamp: String
            let remoteID: String
            let destination: URL
            let createdAt: Double
        }

        var downloadJobs: [ThumbDownloadJob] = []
        downloadJobs.reserveCapacity(min(files.count, createdAtByID.count))
        for (name, file) in files where name.hasSuffix(".jpg") && !file.isFolder {
            guard let id = UUID(uuidString: String(name.dropLast(4))) else { continue }
            guard let createdAt = createdAtByID[id] else { continue }
            let key = id.uuidString
            guard dirtyMap[key] == nil else { continue }
            let stamp = file.md5Checksum ?? (file.id + String(file.modifiedTime?.timeIntervalSince1970 ?? 0))
            if let existingLocal = media.thumbnailURL(for: id, tier: .grid520) {
                if stamps[key] == stamp { continue }
                if let remoteMD5 = file.md5Checksum,
                   let localData = try? Data(contentsOf: existingLocal),
                   MediaPipeline.hex(Insecure.MD5.hash(data: localData)) == remoteMD5 {
                    stamps[key] = stamp
                    stampsDirty = true
                    continue
                }
            }
            downloadJobs.append(ThumbDownloadJob(
                id: id,
                key: key,
                stamp: stamp,
                remoteID: file.id,
                destination: media.thumbnailPath(id),
                createdAt: createdAt
            ))
        }

        // Prioritize newest / first-screen assets first so the top viewport becomes visually complete immediately.
        downloadJobs.sort {
            if $0.createdAt != $1.createdAt { return $0.createdAt > $1.createdAt }
            return $0.key < $1.key
        }

        if !downloadJobs.isEmpty {
            let concurrency = Self.concurrencyLimit(for: transport, directDefault: 12)
            let totalDownloads = downloadJobs.count
            var completedDownloads = 0
            var unsavedCount = 0
            var pendingNotifyIDs: [UUID] = []
            pendingNotifyIDs.reserveCapacity(32)
            var didInitialPaintFlush = false
            var lastNotifyAt = ContinuousClock.now

            updateProgress(
                phase: .downloading(completed: 0, total: totalDownloads),
                detail: "优先拉取缩略图 (0/\(totalDownloads))",
                progress: progressStart,
                forceBroadcast: true
            )
            try await withThrowingTaskGroup(of: (UUID, String, String).self) { group in
                var nextIndex = 0
                let enqueue: (inout ThrowingTaskGroup<(UUID, String, String), Error>) -> Void = { grp in
                    guard nextIndex < totalDownloads else { return }
                    let job = downloadJobs[nextIndex]
                    nextIndex += 1
                    grp.addTask {
                        let data = try await transport.downloadData(fileID: job.remoteID)
                        try data.write(to: job.destination, options: .atomic)
                        return (job.id, job.key, job.stamp)
                    }
                }
                for _ in 0..<min(concurrency, totalDownloads) { enqueue(&group) }
                while let (assetID, key, stamp) = try await group.next() {
                    enqueue(&group)
                    stamps[key] = stamp
                    stampsDirty = true
                    completedDownloads += 1
                    unsavedCount += 1
                    pendingNotifyIDs.append(assetID)

                    let now = ContinuousClock.now
                    let flushThreshold = didInitialPaintFlush ? 32 : 12
                    let elapsedEnough = lastNotifyAt.duration(to: now) >= .milliseconds(500)
                    if pendingNotifyIDs.count >= flushThreshold || (elapsedEnough && !pendingNotifyIDs.isEmpty) {
                        let batch = pendingNotifyIDs
                        pendingNotifyIDs.removeAll(keepingCapacity: true)
                        didInitialPaintFlush = true
                        lastNotifyAt = now
                        notifyProgressiveThumbnails(batch)
                    }

                    if unsavedCount >= 150 {
                        unsavedCount = 0
                        try await database.setState(scope + ".thumbnails", stamps)
                    }
                    let ratio = progressStart + progressSpan * (Double(completedDownloads) / Double(max(1, totalDownloads)))
                    updateProgress(
                        phase: .downloading(completed: completedDownloads, total: totalDownloads),
                        detail: "拉取缩略图 (\(completedDownloads)/\(totalDownloads))",
                        progress: ratio
                    )
                }
            }
            if !pendingNotifyIDs.isEmpty {
                notifyProgressiveThumbnails(pendingNotifyIDs)
            }
        }
        if stampsDirty {
            try await database.setState(scope + ".thumbnails", stamps)
        }
        return stamps
    }

    private func write(_ data: Data, name: String, mime: String, parent: String, existing: RemoteDriveFile?,
                       transport: any DriveTransport, allowOverwriteExisting: Bool = false) async throws -> RemoteDriveFile {
        try await Self.writeBlob(
            data,
            name: name,
            mime: mime,
            parent: parent,
            existing: existing,
            transport: transport,
            allowOverwriteExisting: allowOverwriteExisting
        )
    }

    private nonisolated static func writeBlob(
        _ data: Data,
        name: String,
        mime: String,
        parent: String,
        existing: RemoteDriveFile?,
        transport: any DriveTransport,
        allowOverwriteExisting: Bool = false
    ) async throws -> RemoteDriveFile {
        if let existing {
            if let checksum = existing.md5Checksum {
                if MediaPipeline.hex(Insecure.MD5.hash(data: data)) == checksum { return existing }
            } else if try await transport.downloadData(fileID: existing.id) == data {
                return existing
            }
        }
        do {
            return try await transport.uploadData(data, name: name, mimeType: mime, parentID: parent, existingFileID: existing?.id)
        } catch {
            // Mounted volumes enforce unique names and may have a stale directory listing cache.
            if existing == nil,
               let concurrent = try? await transport.listFiles(inFolderID: parent).first(where: {
                   $0.name == name || $0.name.caseInsensitiveCompare(name) == .orderedSame
               }) {
                if let current = try? await transport.downloadData(fileID: concurrent.id), current == data {
                    return concurrent
                }
                if allowOverwriteExisting {
                    return try await transport.uploadData(
                        data,
                        name: concurrent.name,
                        mimeType: mime,
                        parentID: parent,
                        existingFileID: concurrent.id
                    )
                }
            }
            throw error
        }
    }

    private nonisolated static func trashIfPresentStatic(_ id: String, transport: any DriveTransport) async throws {
        do { try await transport.trashFile(fileID: id) }
        catch DriveTransportError.fileNotFound { }
        catch DriveTransportError.httpError(statusCode: 404, message: _) { }
        catch DriveTransportError.httpError(statusCode: 403, message: _) { }
    }

    /// Ensures a remote file/folder identifier belongs to the active transport before issuing
    /// remote move/trash API calls (prevents cross-backend path IDs from hitting Google Drive API v3).
    private nonisolated static func isRemoteIDCompatible(_ id: String, with transport: any DriveTransport) -> Bool {
        guard !id.isEmpty else { return false }
        if transport is MountedVolumeTransport {
            return id.hasPrefix("mounted-")
        }
        if transport is ICloudDriveTransport {
            return id.hasPrefix(ICloudDriveTransport.pathIDPrefix)
        }
        if transport is WebDAVTransport {
            return !id.hasPrefix("mounted-") && !id.hasPrefix(ICloudDriveTransport.pathIDPrefix)
        }
        return !id.hasPrefix("mounted-")
            && !id.hasPrefix(ICloudDriveTransport.pathIDPrefix)
            && !id.contains("/")
    }

    /// Trashes empty remote folders deepest-child-first across multiple passes so deleting nested
    /// folder trees cleanly removes children before their parents without ever deleting non-empty folders.
    private nonisolated static func trashEmptyFoldersDeepestFirst(
        _ folderIDs: [String],
        inventoryFiles: [String: RemoteDriveFile],
        transport: any DriveTransport
    ) async throws -> Set<String> {
        let unique = Array(Set(folderIDs)).filter { isRemoteIDCompatible($0, with: transport) }
        guard !unique.isEmpty else { return [] }

        func depth(of id: String) -> Int {
            var count = 0
            var cursor = id
            var visited = Set<String>()
            while visited.insert(cursor).inserted,
                  let parent = inventoryFiles[cursor]?.parents.first,
                  !parent.isEmpty {
                count += 1
                cursor = parent
            }
            if count == 0 {
                count = id.split(separator: "/").count
            }
            return count
        }

        var remaining = unique.sorted { lhs, rhs in
            let ld = depth(of: lhs)
            let rd = depth(of: rhs)
            if ld != rd { return ld > rd }
            return lhs > rhs
        }

        var trashed = Set<String>()
        let maxPasses = min(12, max(1, remaining.count))
        for _ in 0..<maxPasses where !remaining.isEmpty {
            var nextRemaining: [String] = []
            var progress = false
            for id in remaining {
                try Task.checkCancellation()
                do {
                    let children = try await transport.listFiles(inFolderID: id)
                    if children.isEmpty {
                        try await trashIfPresentStatic(id, transport: transport)
                        trashed.insert(id)
                        progress = true
                    } else {
                        nextRemaining.append(id)
                    }
                } catch DriveTransportError.fileNotFound {
                    trashed.insert(id)
                    progress = true
                } catch DriveTransportError.httpError(statusCode: 404, message: _) {
                    trashed.insert(id)
                    progress = true
                } catch DriveTransportError.httpError(statusCode: 403, message: _) {
                    // Shared folder without delete permission: skip cleanly without aborting sync.
                }
            }
            remaining = nextRemaining
            if !progress { break }
        }
        return trashed
    }

    private nonisolated static func concurrencyLimit(for transport: any DriveTransport, directDefault: Int) -> Int {
        if transport is MountedVolumeTransport || transport is ICloudDriveTransport { return 2 }
        if transport is WebDAVTransport { return min(3, directDefault) }
        return directDefault
    }

    private nonisolated static func applyingRenamedPrefixes(
        _ prefixes: [(old: String, new: String)],
        to files: [String: RemoteDriveFile]
    ) -> [String: RemoteDriveFile] {
        guard !prefixes.isEmpty else { return files }
        func rewrite(_ value: String) -> String {
            var current = value
            for (old, new) in prefixes where old != new {
                if current == old {
                    current = new
                } else if current.hasPrefix(old + "/") {
                    current = new + "/" + current.dropFirst(old.count + 1)
                }
            }
            return current
        }
        var updated: [String: RemoteDriveFile] = [:]
        updated.reserveCapacity(files.count)
        for (_, file) in files {
            let newID = rewrite(file.id)
            let newParents = file.parents.map(rewrite)
            let newName = newID == file.id ? file.name : (newID as NSString).lastPathComponent
            updated[newID] = RemoteDriveFile(
                id: newID,
                name: newName,
                mimeType: file.mimeType,
                size: file.size,
                modifiedTime: file.modifiedTime,
                md5Checksum: file.md5Checksum,
                parents: newParents,
                trashed: file.trashed,
                webViewLink: file.webViewLink
            )
        }
        return updated
    }

    /// Executes `work` over `items` with a bounded sliding window of concurrent child tasks.
    private nonisolated static func runBounded<Item: Sendable, Output: Sendable>(
        items: [Item],
        maxConcurrent: Int,
        work: @escaping @Sendable (Item) async throws -> Output
    ) async throws -> [Output] {
        guard !items.isEmpty else { return [] }
        let limit = max(1, min(maxConcurrent, items.count))
        var results: [Output] = []
        results.reserveCapacity(items.count)
        try await withThrowingTaskGroup(of: Output.self) { group in
            var nextIndex = 0
            while nextIndex < limit {
                let item = items[nextIndex]
                nextIndex += 1
                group.addTask { try await work(item) }
            }
            while let value = try await group.next() {
                results.append(value)
                if nextIndex < items.count {
                    let item = items[nextIndex]
                    nextIndex += 1
                    group.addTask { try await work(item) }
                }
            }
        }
        return results
    }

    private func encoded<T: Encodable>(_ value: T) throws -> Data {
        try canonicalEncoder.encode(value)
    }

    private func keyedByName(_ files: [RemoteDriveFile]) -> [String: RemoteDriveFile] {
        Self.keyedByNameStatic(files)
    }

    private nonisolated static func keyedByNameStatic(_ files: [RemoteDriveFile]) -> [String: RemoteDriveFile] {
        Dictionary(files.filter { !$0.isFolder }.sorted {
            ($0.modifiedTime ?? .distantPast, $0.id) > ($1.modifiedTime ?? .distantPast, $1.id)
        }.map { ($0.name, $0) }, uniquingKeysWith: { first, _ in first })
    }

    /// Validates raw image bytes returned by a server-side thumbnail endpoint and normalizes them
    /// into a compact `<= 520px` JPEG suitable for `.grid520` caching without touching the full original.
    private nonisolated static func normalizedThumbnailJPEG(from data: Data, maxPixel: Int = 520) -> Data? {
        autoreleasepool {
            let sourceOptions: [CFString: Any] = [kCGImageSourceShouldCache: false]
            guard let source = CGImageSourceCreateWithData(data as CFData, sourceOptions as CFDictionary),
                  CGImageSourceGetCount(source) > 0 else {
                return nil
            }
            let thumbOptions: [CFString: Any] = [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceShouldCacheImmediately: false,
                kCGImageSourceThumbnailMaxPixelSize: max(200, maxPixel)
            ]
            guard let cgImage = CGImageSourceCreateThumbnailAtIndex(source, 0, thumbOptions as CFDictionary) else {
                return nil
            }
            let output = NSMutableData()
            guard let destination = CGImageDestinationCreateWithData(output, UTType.jpeg.identifier as CFString, 1, nil) else {
                return nil
            }
            CGImageDestinationAddImage(
                destination,
                cgImage,
                [kCGImageDestinationLossyCompressionQuality: 0.84] as CFDictionary
            )
            guard CGImageDestinationFinalize(destination), output.length > 0 else {
                return nil
            }
            return output as Data
        }
    }

}

extension DriveSyncEngine {
    private struct Inventory: Sendable {
        var files: [String: RemoteDriveFile] = [:]
        var startPageToken: String
    }

    private struct InventoryUpdate: Sendable {
        let previous: [String: RemoteDriveFile]
        let previousStartPageToken: String?
        let current: SavedInventory
        let orderedFolders: [RemoteDriveFile]
    }

    private struct SavedInventory: Codable, Sendable {
        let files: [String: RemoteDriveFile]
        let startPageToken: String
    }

    private func fetchInventory(
        _ layout: Layout,
        transport: any DriveTransport,
        scope: String,
        forceFullCrawl: Bool = false
    ) async throws -> InventoryUpdate {
        let previous: SavedInventory? = try await database.state(scope + ".inventory")
        var inventory: Inventory
        if forceFullCrawl {
            // Shared folders & Team Drives can receive writes from other collaborators that My-Drive-scoped
            // `changes.list` omits; walking the shared root directly guarantees 100% collaborator visibility.
            inventory = try await crawl(layout: layout, transport: transport)
        } else if let previous {
            do {
                inventory = try await readChanges(previous, transport: transport)
            } catch DriveTransportError.httpError(statusCode: 410, message: _) {
                inventory = try await crawl(layout: layout, transport: transport)
            }
        } else {
            inventory = try await crawl(layout: layout, transport: transport)
        }
        let known = previous?.files ?? [:]
        var visible = reachable(inventory.files, layout: layout)
        let newFolders = visible.folders.filter { known[$0.id] == nil }
        if !forceFullCrawl && previous != nil {
            // Drive changes can report only the ancestor when a whole folder is moved into Charkle.
            for folder in newFolders where folder.id != layout.inbox {
                try await collectChildren(of: folder.id, into: &inventory.files, layout: layout, transport: transport)
            }
            visible = reachable(inventory.files, layout: layout)
        }
        let current = SavedInventory(files: visible.files, startPageToken: inventory.startPageToken)
        return InventoryUpdate(
            previous: known,
            previousStartPageToken: previous?.startPageToken,
            current: current,
            orderedFolders: visible.folders
        )
    }

    private func crawl(layout: Layout, transport: any DriveTransport) async throws -> Inventory {
        if let webdav = transport as? WebDAVTransport {
            let (snapshot, token) = try await webdav.crawlSnapshotWithToken()
            let visible = snapshot.filter { isVisible($0.value, layout: layout) }
            return Inventory(files: visible, startPageToken: token)
        }
        let token = try await transport.fetchStartPageToken()
        var files: [String: RemoteDriveFile] = [:]
        try await collectChildren(of: layout.root, into: &files, layout: layout, transport: transport)
        return Inventory(files: files, startPageToken: token)
    }

    private func collectChildren(of root: String, into files: inout [String: RemoteDriveFile], layout: Layout,
                                 transport: any DriveTransport) async throws {
        let concurrency = Self.concurrencyLimit(for: transport, directDefault: 6)
        var frontier = [root]
        var seen = Set<String>()
        while !frontier.isEmpty {
            let wave = frontier.filter { seen.insert($0).inserted }
            frontier.removeAll(keepingCapacity: true)
            guard !wave.isEmpty else { break }

            let listedBatches = try await Self.runBounded(items: wave, maxConcurrent: concurrency) { folder in
                try await transport.listFiles(inFolderID: folder)
            }
            for batch in listedBatches {
                for file in batch where isVisible(file, layout: layout) {
                    files[file.id] = file
                    if file.isFolder {
                        frontier.append(file.id)
                    }
                }
            }
        }
    }

    private func readChanges(_ previous: SavedInventory, transport: any DriveTransport) async throws -> Inventory {
        var files = previous.files
        var token = previous.startPageToken
        var visited = Set<String>()
        while visited.insert(token).inserted {
            try Task.checkCancellation()
            let page = try await transport.listChanges(pageToken: token)
            for change in page.changes {
                if change.removed || change.file?.trashed == true { files.removeValue(forKey: change.fileID) }
                else if let file = change.file { files[file.id] = file }
            }
            if let next = page.nextPageToken {
                token = next
            } else if let final = page.newStartPageToken {
                return Inventory(files: files, startPageToken: final)
            } else { break }
        }
        throw DriveTransportError.invalidResponse("Incomplete Drive change cursor chain.")
    }

    private func reachable(_ files: [String: RemoteDriveFile], layout: Layout) -> (files: [String: RemoteDriveFile], folders: [RemoteDriveFile]) {
        let children = Dictionary(grouping: files.values.filter { isVisible($0, layout: layout) }) { $0.parents.first ?? "" }
        var reachable: [String: RemoteDriveFile] = [:]
        var folders: [RemoteDriveFile] = []
        var queue = [layout.root]
        var index = 0
        while index < queue.count {
            let parent = queue[index]
            index += 1
            let entries = children[parent, default: []].sorted { ($0.name, $0.id) < ($1.name, $1.id) }
            for file in entries where reachable[file.id] == nil && file.id != layout.root {
                reachable[file.id] = file
                if file.isFolder { queue.append(file.id); folders.append(file) }
            }
        }
        return (reachable, folders)
    }

    private static let nonExportableGoogleMimeTypes: Set<String> = [
        "application/vnd.google-apps.shortcut",
        "application/vnd.google-apps.form",
        "application/vnd.google-apps.site",
        "application/vnd.google-apps.map",
        "application/vnd.google-apps.script",
        "application/vnd.google-apps.jam",
        "application/vnd.google-apps.fusiontable",
        "application/vnd.google-apps.drive-sdk"
    ]

    private static let ignoredJunkFileNames: Set<String> = [
        "thumbs.db", "desktop.ini", "icon\r"
    ]

    private static let ignoredTempExtensions: Set<String> = [
        "crdownload", "part", "download", "tmp", "partial"
    ]

    private static let binaryMediaExtensions: Set<String> = [
        "png", "jpg", "jpeg", "webp", "gif", "heic", "heif", "avif", "tif", "tiff", "bmp",
        "mp4", "mov", "m4v", "webm", "mkv", "avi",
        "mp3", "m4a", "wav", "flac", "aac", "ogg",
        "pdf", "psd", "psb", "ai", "eps", "fig", "sketch", "xd", "blend", "zip"
    ]

    private func isVisible(_ file: RemoteDriveFile, layout: Layout) -> Bool {
        guard !file.trashed, file.id != layout.metadata, !file.name.hasPrefix(".") else { return false }
        if Self.nonExportableGoogleMimeTypes.contains(file.mimeType) { return false }
        let lowerName = file.name.lowercased()
        if Self.ignoredJunkFileNames.contains(lowerName) { return false }
        if !file.isFolder {
            let ext = (lowerName as NSString).pathExtension
            if Self.ignoredTempExtensions.contains(ext) { return false }
        }
        return true
    }

    private static func isLikelyIncompleteZeroByteMedia(_ file: RemoteDriveFile) -> Bool {
        guard !file.isFolder, let size = file.size, size == 0 else { return false }
        let ext = (file.name.lowercased() as NSString).pathExtension
        return binaryMediaExtensions.contains(ext)
    }

    private static func isFatalSyncError(_ error: Error) -> Bool {
        if error is CancellationError { return true }
        if error is URLError { return true }
        if let transportError = error as? DriveTransportError {
            switch transportError {
            case .authenticationRequired, .mountPathUnavailable, .gdirectNotFound, .notConfigured:
                return true
            default:
                return false
            }
        }
        return false
    }

    private struct RemoteDownloadJob: Sendable {
        let file: RemoteDriveFile
        let folderID: UUID?
        let existing: AssetRecord?
    }

    private struct PreparedRemoteAsset: Sendable {
        let file: RemoteDriveFile
        let existing: AssetRecord?
        let matching: AssetRecord?
        let folderURL: URL
        let temporaryURL: URL
        let rendered: AssetRecord
        let analysis: LocalAnalysisResult
    }

    private enum RemoteDownloadOutcome: Sendable {
        case prepared(PreparedRemoteAsset)
        case skipped(fileName: String)
        case deferred(fileID: String, fileName: String)
        case deletedLocally(fileID: String, fileName: String)
    }

    private func reconcile(
        _ update: InventoryUpdate,
        layout: Layout,
        transport: any DriveTransport,
        config: DriveSyncConfig,
        pending: [(Int64, SyncOperation)],
        remoteThumbnails: [String: RemoteDriveFile]? = nil
    ) async throws -> (discovered: Int, discoveredIDs: [UUID], renames: Int, deferredFileIDs: Set<String>, removedFileIDs: Set<String>) {
        let isMountedTransport = transport is MountedVolumeTransport
        var pendingMoves = Set<UUID>()
        var pendingFolders = Set<UUID>()
        var pendingDeletedDriveIDs = Set<String>()
        var pendingDeletedFolderDriveIDs = Set<String>()
        for (_, op) in pending {
            switch op.change {
            case .asset(let delta) where delta.touchesLocation && op.projectLocation != false:
                pendingMoves.insert(delta.id)
            case .folder(let folder) where op.projectLocation != false:
                pendingFolders.insert(folder.id)
            case .deleteAsset(let id, let driveID):
                if let driveID, !driveID.isEmpty {
                    pendingDeletedDriveIDs.insert(driveID)
                }
                if isMountedTransport,
                   let local = try? await database.state("local.delete.asset." + id.uuidString, as: String.self) {
                    pendingDeletedDriveIDs.insert(local)
                }
            case .deleteFolder(let id, let driveID):
                if let driveID, !driveID.isEmpty {
                    pendingDeletedFolderDriveIDs.insert(driveID)
                }
                if isMountedTransport,
                   let local = try? await database.state("local.delete.folder." + id.uuidString, as: String.self) {
                    pendingDeletedFolderDriveIDs.insert(local)
                }
            default: break
            }
        }

        // Only clear stale mounted-path deletion markers when actively syncing MountedVolumeTransport
        // and the item is confirmed absent from the mounted filesystem (and not pending deletion).
        if isMountedTransport {
            let activeFileIDs = Set(update.current.files.keys)
            let deletedMarkers: [(String, Bool)] = (try? await database.states(withPrefix: "deleted.drive." + MountedVolumeTransport.pathIDPrefix, as: Bool.self)) ?? []
            let deletedFolderMarkers: [(String, Bool)] = (try? await database.states(withPrefix: "deleted.folder.drive." + MountedVolumeTransport.pathIDPrefix, as: Bool.self)) ?? []
            var markersToClear: [String] = []
            for (key, _) in deletedMarkers {
                let remoteID = String(key.dropFirst("deleted.drive.".count))
                if !activeFileIDs.contains(remoteID), !pendingDeletedDriveIDs.contains(remoteID) {
                    markersToClear.append(key)
                }
            }
            for (key, _) in deletedFolderMarkers {
                let remoteID = String(key.dropFirst("deleted.folder.drive.".count))
                if !activeFileIDs.contains(remoteID), !pendingDeletedFolderDriveIDs.contains(remoteID) {
                    markersToClear.append(key)
                }
            }
            if !markersToClear.isEmpty {
                let toClear = markersToClear
                try? await database.transaction { store in
                    for key in toClear {
                        try store.setState(key, Optional<Bool>.none)
                    }
                }
            }
        }

        let deletedFolderDriveEntries: [(String, Bool)] = (try? await database.states(withPrefix: "deleted.folder.drive.", as: Bool.self)) ?? []
        var deletedFolderDriveIDs = Set<String>()
        for (key, value) in deletedFolderDriveEntries where value {
            deletedFolderDriveIDs.insert(String(key.dropFirst("deleted.folder.drive.".count)))
        }
        let deletedFolderPathEntries: [(String, DeletedFolderFingerprint)] = (try? await database.states(withPrefix: "deleted.folder.path.", as: DeletedFolderFingerprint.self)) ?? []
        var deletedFolderPaths: [String: DeletedFolderFingerprint] = [:]
        deletedFolderPaths.reserveCapacity(deletedFolderPathEntries.count)
        for (key, fp) in deletedFolderPathEntries {
            deletedFolderPaths[String(key.dropFirst("deleted.folder.path.".count))] = fp
        }

        var removedFileIDs = Set<String>()
        var deletedRemoteFoldersToClean: [(id: String, persistMarker: Bool)] = []

        // Batch all remote folder reconciliations into a single SQLite transaction (instead of 1 transaction per folder),
        // skipping any folder previously deleted in Charkle so a fresh install never resurrects deleted folders.
        let folderReconcileResult: (map: [String: UUID], skippedPending: [String], skippedDeleted: [(id: String, persistMarker: Bool)]) = try await database.transaction { [pendingFolders, pendingDeletedFolderDriveIDs, deletedFolderDriveIDs, deletedFolderPaths, layout] store in
            var map: [String: UUID] = [:]
            var remotePathByID: [String: String] = [:]
            var skippedPending: [String] = []
            var skippedDeleted: [(id: String, persistMarker: Bool)] = []
            var folders = try store.fetchFolders()
            map.reserveCapacity(update.orderedFolders.count)
            for file in update.orderedFolders where file.id != layout.inbox {
                let parentRemoteID = file.parents.first
                let normalizedName = file.name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
                let remoteNormPath: String = {
                    if let pid = parentRemoteID, let parentPath = remotePathByID[pid], !parentPath.isEmpty {
                        return parentPath + "/" + normalizedName
                    }
                    return normalizedName
                }()
                remotePathByID[file.id] = remoteNormPath

                if pendingDeletedFolderDriveIDs.contains(file.id) {
                    skippedPending.append(file.id)
                    continue
                }
                if deletedFolderDriveIDs.contains(file.id) {
                    skippedDeleted.append((file.id, false))
                    continue
                }
                let parent = parentRemoteID.flatMap { map[$0] }
                let found = folders.firstIndex(where: { $0.driveFolderID == file.id })
                    ?? folders.firstIndex(where: { $0.parentID == parent && $0.name == file.name })
                if found == nil,
                   let deletedPathFP = deletedFolderPaths[remoteNormPath],
                   deletedPathFP.deletedAt >= (file.modifiedTime ?? .distantPast).addingTimeInterval(-5) {
                    skippedDeleted.append((file.id, true))
                    continue
                }
                let id = found.map { folders[$0].id } ?? DriveFiles.stableUUID("folder:" + file.id)
                if try store.isTombstoned("folder", id: id) {
                    skippedDeleted.append((file.id, true))
                    continue
                }
                let sortOrder = folders.count
                var folder = try store.folder(id: id) ?? FolderRecord(id: id, name: file.name, parentID: parent, sortOrder: sortOrder)
                let before = folder
                let prev = update.previous[file.id]
                let changedMetadata = prev?.name != file.name || prev?.parents != file.parents
                if !pendingFolders.contains(id), changedMetadata {
                    folder.name = file.name
                    folder.parentID = parent
                }
                let driveBindingChanged = folder.driveFolderID != file.id
                folder.driveFolderID = file.id
                let needsRecord = before.name != folder.name || before.parentID != folder.parentID || found == nil
                if needsRecord {
                    folder.updatedAt = file.modifiedTime ?? .now
                    try store.record(.folder(folder), projectLocation: false)
                    if let stored = try store.folder(id: id) {
                        folder = stored
                        folder.driveFolderID = file.id
                    }
                    try store.put(folder)
                } else if driveBindingChanged {
                    try store.put(folder)
                }
                map[file.id] = folder.id
                if let found { folders[found] = folder } else { folders.append(folder) }
            }
            return (map, skippedPending, skippedDeleted)
        }
        let folderIDs = folderReconcileResult.map
        for id in folderReconcileResult.skippedPending {
            removedFileIDs.insert(id)
        }
        for item in folderReconcileResult.skippedDeleted {
            removedFileIDs.insert(item.id)
            if Self.isRemoteIDCompatible(item.id, with: transport) {
                deletedRemoteFoldersToClean.append(item)
            }
        }

        let thumbnails: [String: RemoteDriveFile]
        if let remoteThumbnails {
            thumbnails = remoteThumbnails
        } else {
            thumbnails = config.syncThumbnails ? keyedByName(try await transport.listFiles(inFolderID: layout.thumbnails)) : [:]
        }
        var discovered = 0
        var discoveredIDs: [UUID] = []
        var renames = 0
        var deferredFileIDs = Set<String>()

        // Preload bindings, assets, and deletion/hidden marker prefixes in 4 bulk reads
        // instead of issuing O(N) individual SQLite queries during fresh-install reconciliation.
        let bindings = try await database.assetDriveBindings()
        var linked = Dictionary(uniqueKeysWithValues: bindings)
        let visible = update.current.files.values.filter { file in
            guard !file.isFolder else { return false }
            if update.previous[file.id] != file { return true }
            guard let id = linked[file.id] else { return true }
            return media.thumbnailURL(for: id, tier: .grid520) == nil
        }.sorted { $0.id < $1.id }

        let allLocalAssets = try await database.fetchAssets(matching: FilterCriteria(includeTrashed: true))
        var assetsByID: [UUID: AssetRecord] = [:]
        assetsByID.reserveCapacity(allLocalAssets.count)
        for asset in allLocalAssets { assetsByID[asset.id] = asset }

        let deletedDriveEntries: [(String, Bool)] = (try? await database.states(withPrefix: "deleted.drive.", as: Bool.self)) ?? []
        var deletedDriveIDs = Set<String>()
        for (key, value) in deletedDriveEntries where value {
            deletedDriveIDs.insert(String(key.dropFirst("deleted.drive.".count)))
        }
        let deletedMD5Entries: [(String, DeletedAssetFingerprint)] = (try? await database.states(withPrefix: "deleted.md5.", as: DeletedAssetFingerprint.self)) ?? []
        var deletedMD5s: [String: DeletedAssetFingerprint] = [:]
        deletedMD5s.reserveCapacity(deletedMD5Entries.count)
        for (key, fp) in deletedMD5Entries {
            deletedMD5s[String(key.dropFirst("deleted.md5.".count))] = fp
        }
        let remoteHiddenEntries: [(String, Bool)] = (try? await database.states(withPrefix: "remote.hidden.", as: Bool.self)) ?? []
        var remoteHiddenIDs = Set<String>()
        for (key, value) in remoteHiddenEntries where value {
            remoteHiddenIDs.insert(String(key.dropFirst("remote.hidden.".count)))
        }

        struct PendingLocationUpdate: Sendable {
            let assetID: UUID
            let file: RemoteDriveFile
            let previous: RemoteDriveFile?
            let folderID: UUID?
        }
        struct ThumbnailLinkFallbackJob: Sendable {
            let file: RemoteDriveFile
            let existing: AssetRecord
            let folderID: UUID?
        }

        // Phase 1: fast local metadata reconciliation & filter out assets that don't require remote bytes
        var downloadJobs: [RemoteDownloadJob] = []
        downloadJobs.reserveCapacity(visible.count)
        var locationUpdates: [PendingLocationUpdate] = []
        var thumbnailLinkJobs: [ThumbnailLinkFallbackJob] = []
        var remoteTrashFromDeleted: [(fileID: String, persistDeletedMarker: Bool)] = []

        for file in visible {
            try Task.checkCancellation()
            if pendingDeletedDriveIDs.contains(file.id) {
                removedFileIDs.insert(file.id)
                continue
            }
            if deletedDriveIDs.contains(file.id) {
                if Self.isRemoteIDCompatible(file.id, with: transport) {
                    remoteTrashFromDeleted.append((file.id, false))
                }
                removedFileIDs.insert(file.id)
                continue
            }
            if Self.isLikelyIncompleteZeroByteMedia(file) {
                deferredFileIDs.insert(file.id)
                continue
            }
            let previous = update.previous[file.id]
            let folderID = file.parents.first.flatMap { folderIDs[$0] }
            let existing = linked[file.id].flatMap { assetsByID[$0] }
            if existing == nil,
               let md5 = file.md5Checksum, !md5.isEmpty,
               let deleted = deletedMD5s[md5],
               (try await database.assets(contentHash: deleted.sha256)).isEmpty {
                remoteTrashFromDeleted.append((file.id, true))
                removedFileIDs.insert(file.id)
                continue
            }
            let changedContent = Self.contentChanged(before: previous, after: file)
            if let existing, !changedContent || previous == nil {
                // Only enqueue a SQLite location update if a genuinely newer Drive-side rename/move
                // or hidden-trash restoration occurred. On a fresh install (`previous == nil`), trust
                // authoritative `.charkle/ops/` metadata instead of reverting trashed/moved items.
                if !pendingMoves.contains(existing.id) {
                    let remoteName = Self.originalName(file)
                    let unhideNeedsUpdate = remoteHiddenIDs.contains(file.id)
                    let nameNeedsUpdate: Bool
                    let folderNeedsUpdate: Bool
                    if let previous {
                        nameNeedsUpdate = previous.name != file.name && existing.fileName != remoteName
                        folderNeedsUpdate = previous.parents != file.parents && existing.folderID != folderID
                    } else if !existing.isTrashed,
                              let remoteModified = file.modifiedTime,
                              remoteModified > existing.updatedAt.addingTimeInterval(2) {
                        nameNeedsUpdate = existing.fileName != remoteName
                        folderNeedsUpdate = existing.folderID != folderID && (folderID != nil || existing.folderID == nil)
                    } else {
                        nameNeedsUpdate = false
                        folderNeedsUpdate = false
                    }
                    if nameNeedsUpdate || folderNeedsUpdate || unhideNeedsUpdate {
                        locationUpdates.append(PendingLocationUpdate(
                            assetID: existing.id,
                            file: file,
                            previous: previous,
                            folderID: folderID
                        ))
                    }
                }
                // Trashed records keep their metadata and permanent thumbnail without fetching bytes.
                if existing.isTrashed || media.thumbnailURL(for: existing.id, tier: .grid520) != nil
                    || thumbnails[existing.id.uuidString.lowercased() + ".jpg"] != nil { continue }
                if let cached = media.cachedOriginal(for: existing) {
                    let rendered = try await media.refreshed(existing, from: cached)
                    let analysis: LocalAnalysisResult
                    if rendered.mediaKind != .audio, let thumbnail = media.thumbnailURL(for: rendered.id, tier: .grid520) {
                        analysis = await intelligence.analyze(thumbnailURL: thumbnail, includeColors: false)
                    } else {
                        analysis = LocalAnalysisResult()
                    }
                    _ = try await persistRemoteMedia(rendered, matching: existing, temporary: nil, analysis: analysis, config: config)
                    continue
                }
                // Fast-path for already-synced Charkle assets missing `.charkle/thumbnails/<uuid>.jpg`:
                // fetch Google Drive's server-generated thumbnail (~40ms) instead of pulling the multi-MB original.
                if file.thumbnailLink != nil {
                    thumbnailLinkJobs.append(ThumbnailLinkFallbackJob(file: file, existing: existing, folderID: folderID))
                    continue
                }
            }
            downloadJobs.append(RemoteDownloadJob(file: file, folderID: folderID, existing: existing))
        }

        if !remoteTrashFromDeleted.isEmpty {
            let trashConcurrency = Self.concurrencyLimit(for: transport, directDefault: 6)
            let markerIDsToSave = try await Self.runBounded(items: remoteTrashFromDeleted, maxConcurrent: trashConcurrency) { item -> String? in
                try await Self.trashIfPresentStatic(item.fileID, transport: transport)
                return item.persistDeletedMarker ? item.fileID : nil
            }.compactMap { $0 }
            if !markerIDsToSave.isEmpty {
                try? await database.transaction { store in
                    for fileID in markerIDsToSave {
                        try store.setState("deleted.drive." + fileID, true)
                    }
                }
            }
        }

        // Apply all genuine location/rename reconciliations in ONE batched SQLite transaction.
        if !locationUpdates.isEmpty {
            let updates = locationUpdates
            let appliedRenames = try await database.transaction { store -> Int in
                var count = 0
                for item in updates {
                    guard var current = try store.asset(id: item.assetID), current.driveFileID == item.file.id else { continue }
                    let before = current
                    let filename = Self.originalName(item.file)
                    if item.previous?.name != item.file.name, current.fileName != filename {
                        if current.title == (current.fileName as NSString).deletingPathExtension {
                            current.title = (filename as NSString).deletingPathExtension
                        }
                        current.fileName = filename
                    }
                    if item.previous?.parents != item.file.parents {
                        current.folderID = item.folderID
                    }
                    let hiddenKey = "remote.hidden." + item.file.id
                    if try store.state(hiddenKey, as: Bool.self) == true {
                        current.isTrashed = false
                        try store.setState(hiddenKey, Optional<Bool>.none)
                    }
                    if current != before {
                        _ = try store.saveAssetLocally(current, projectLocation: false)
                        count += 1
                    }
                }
                return count
            }
            renames += appliedRenames
        }

        // Phase 1.5: fast parallel Google Drive `thumbnailLink` hydration for synced assets lacking `.charkle/thumbnails/<uuid>.jpg`.
        if !thumbnailLinkJobs.isEmpty {
            let thumbConcurrency = Self.concurrencyLimit(for: transport, directDefault: 12)
            let media = self.media
            let fallbackResults = try await Self.runBounded(items: thumbnailLinkJobs, maxConcurrent: thumbConcurrency) { job -> (ThumbnailLinkFallbackJob, Bool) in
                if let rawData = try? await transport.downloadThumbnailData(for: job.file, maxPixelSize: 640),
                   let jpeg = Self.normalizedThumbnailJPEG(from: rawData, maxPixel: 520) {
                    try jpeg.write(to: media.thumbnailPath(job.existing.id), options: .atomic)
                    return (job, true)
                }
                return (job, false)
            }
            var hydratedIDs: [UUID] = []
            hydratedIDs.reserveCapacity(fallbackResults.count)
            for (job, ok) in fallbackResults {
                if ok {
                    hydratedIDs.append(job.existing.id)
                } else {
                    downloadJobs.append(RemoteDownloadJob(file: job.file, folderID: job.folderID, existing: job.existing))
                }
            }
            if !hydratedIDs.isEmpty {
                notifyProgressiveThumbnails(hydratedIDs)
            }
        }

        // Phase 2: bounded parallel remote download + thumbnail rendering + Apple Vision analysis
        if !downloadJobs.isEmpty {
            let concurrency = Self.concurrencyLimit(for: transport, directDefault: 6)
            let totalDownloads = downloadJobs.count
            var completedDownloads = 0
            var sinceLastProgressiveNotify = 0
            var lastProgressiveNotifyAt = ContinuousClock.now
            let database = self.database
            let media = self.media
            let intelligence = self.intelligence
            let currentInventory = update.current

            updateProgress(
                phase: .downloading(completed: 0, total: totalDownloads),
                detail: "并行拉取 \(totalDownloads) 项素材…",
                progress: 0.48,
                forceBroadcast: true
            )

            try await withThrowingTaskGroup(of: RemoteDownloadOutcome.self) { group in
                var nextIndex = 0
                let launchNext: (inout ThrowingTaskGroup<RemoteDownloadOutcome, Error>) -> Void = { grp in
                    guard nextIndex < totalDownloads else { return }
                    let job = downloadJobs[nextIndex]
                    nextIndex += 1
                    grp.addTask {
                        try await Self.downloadAndPrepareRemoteAsset(
                            job: job,
                            current: currentInventory,
                            transport: transport,
                            database: database,
                            media: media,
                            intelligence: intelligence
                        )
                    }
                }

                for _ in 0..<min(concurrency, totalDownloads) {
                    launchNext(&group)
                }

                while let outcome = try await group.next() {
                    launchNext(&group)
                    completedDownloads += 1
                    let ratio = 0.48 + 0.18 * (Double(completedDownloads) / Double(max(1, totalDownloads)))
                    switch outcome {
                    case .prepared(let prepared):
                        defer { try? FileManager.default.removeItem(at: prepared.folderURL) }
                        let saved = try await persistRemoteMedia(
                            prepared.rendered,
                            matching: prepared.matching,
                            temporary: prepared.temporaryURL,
                            analysis: prepared.analysis,
                            config: config,
                            moveTemporary: true
                        )
                        if let saved {
                            linked[prepared.file.id] = saved.id
                            if prepared.existing == nil && (saved.id == DriveFiles.stableUUID("asset:" + prepared.file.id) || prepared.file.id.hasPrefix(MountedVolumeTransport.pathIDPrefix)) {
                                discovered += 1
                                discoveredIDs.append(saved.id)
                            }
                            if let existing = prepared.existing, existing.fileName != saved.fileName || existing.folderID != saved.folderID {
                                renames += 1
                            }
                            sinceLastProgressiveNotify += 1
                            let now = ContinuousClock.now
                            if sinceLastProgressiveNotify >= 12 || lastProgressiveNotifyAt.duration(to: now) >= .milliseconds(800) {
                                sinceLastProgressiveNotify = 0
                                lastProgressiveNotifyAt = now
                                notifyProgressiveMetadata(hasBoards: false)
                            }
                        }
                        updateProgress(
                            phase: .downloading(completed: completedDownloads, total: totalDownloads),
                            detail: "拉取：\(prepared.file.name)",
                            progress: ratio
                        )
                    case .skipped(let fileName):
                        updateProgress(
                            phase: .downloading(completed: completedDownloads, total: totalDownloads),
                            detail: "跳过：\(fileName)",
                            progress: ratio
                        )
                    case .deferred(let fileID, let fileName):
                        deferredFileIDs.insert(fileID)
                        updateProgress(
                            phase: .downloading(completed: completedDownloads, total: totalDownloads),
                            detail: "延后处理：\(fileName)",
                            progress: ratio
                        )
                    case .deletedLocally(let fileID, let fileName):
                        try await Self.trashIfPresentStatic(fileID, transport: transport)
                        try? await database.setState("deleted.drive." + fileID, true)
                        removedFileIDs.insert(fileID)
                        updateProgress(
                            phase: .downloading(completed: completedDownloads, total: totalDownloads),
                            detail: "同步删除：\(fileName)",
                            progress: ratio
                        )
                    }
                }
            }
            if sinceLastProgressiveNotify > 0 {
                notifyProgressiveMetadata(hasBoards: false)
            }
        }

        // After both Phase 1 and Phase 2 have trashed any deleted remote files, safely clean up
        // leftover deleted remote folders (deepest-first, strictly only when empty).
        if !deletedRemoteFoldersToClean.isEmpty {
            let trashedFolderIDs = try await Self.trashEmptyFoldersDeepestFirst(
                deletedRemoteFoldersToClean.map(\.id),
                inventoryFiles: update.current.files,
                transport: transport
            )
            let persistIDs = deletedRemoteFoldersToClean
                .filter { $0.persistMarker && trashedFolderIDs.contains($0.id) }
                .map(\.id)
            if !persistIDs.isEmpty {
                try? await database.transaction { store in
                    for folderID in persistIDs {
                        try store.setState("deleted.folder.drive." + folderID, true)
                    }
                }
            }
            for folderID in trashedFolderIDs {
                removedFileIDs.insert(folderID)
            }
        }

        for (id, gone) in update.previous where update.current.files[id] == nil && !gone.isFolder {
            guard let assetID = linked[id], !pendingMoves.contains(assetID) else { continue }
            try await database.transaction { store in
                guard var asset = try store.asset(id: assetID), asset.driveFileID == id, !asset.isTrashed else { return }
                asset.isTrashed = true
                try store.setState("remote.hidden." + id, true)
                _ = try store.saveAssetLocally(asset, projectLocation: false)
            }
        }
        return (discovered, discoveredIDs, renames, deferredFileIDs, removedFileIDs)
    }

    private static func contentChanged(before: RemoteDriveFile?, after: RemoteDriveFile) -> Bool {
        guard let before, before != after else { return false }
        if let a = before.md5Checksum, let b = after.md5Checksum { return a != b }
        if let a = before.size, let b = after.size, a != b { return true }
        return before.name == after.name && before.parents == after.parents && before.modifiedTime != after.modifiedTime
    }

    private static func originalName(_ file: RemoteDriveFile) -> String {
        if file.mimeType.hasPrefix("application/vnd.google-apps."), !file.name.lowercased().hasSuffix(".pdf") {
            return file.name + ".pdf"
        }
        return file.name
    }

    /// Runs off-actor so multiple workers execute network download, digesting, thumbnail generation,
    /// and Apple Vision analysis concurrently across network sockets, CPU cores, and Neural Engine.
    private nonisolated static func downloadAndPrepareRemoteAsset(
        job: RemoteDownloadJob,
        current: SavedInventory,
        transport: any DriveTransport,
        database: LibraryDatabase,
        media: MediaPipeline,
        intelligence: IntelligenceEngine
    ) async throws -> RemoteDownloadOutcome {
        let file = job.file
        let folder = media.staging.appending(
            path: "remote-" + DriveFiles.stableUUID(file.id).uuidString + "-" + UUID().uuidString.prefix(8),
            directoryHint: .isDirectory
        )
        do {
            try Task.checkCancellation()
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            let isGoogleDocument = file.mimeType.hasPrefix("application/vnd.google-apps.")
            let filename = Self.originalName(file)
            let ext = (filename as NSString).pathExtension.filter { $0.isASCII && ($0.isLetter || $0.isNumber) }
            let temporary = folder.appending(path: ext.isEmpty ? "content" : "content." + ext)

            try await transport.downloadFile(file, to: temporary)
            let hash = try MediaPipeline.digests(temporary)
            let matching: AssetRecord?
            if let existing = job.existing {
                matching = existing
            } else {
                let sameHashAssets = try await database.assets(contentHash: hash.sha256)
                let primaryMatches = sameHashAssets.filter {
                    ($0.driveFileID == nil && $0.fileName == filename && $0.folderID == job.folderID)
                        || ($0.driveFileID.map { current.files[$0] == nil } == true)
                }
                if primaryMatches.count == 1 {
                    matching = primaryMatches.first
                } else {
                    let exactLocation = primaryMatches.filter { $0.fileName == filename && $0.folderID == job.folderID }
                    if exactLocation.count == 1 {
                        matching = exactLocation.first
                    } else {
                        // Also bind unbound local records (e.g., synced via gdirectMount or soft-trashed when a
                        // folder was deleted) whose fileName or conflict-suffixed name matches, so a fresh install
                        // never resurrects a soft-trashed asset as a brand-new live copy.
                        let unbound = sameHashAssets.filter { $0.driveFileID == nil }
                        let byNameOrConflict = unbound.filter { candidate in
                            if candidate.fileName.caseInsensitiveCompare(filename) == .orderedSame { return true }
                            let short = String(candidate.id.uuidString.prefix(8)).lowercased()
                            let stem = (candidate.fileName as NSString).deletingPathExtension
                            let candidateExt = (candidate.fileName as NSString).pathExtension
                            let alt = candidateExt.isEmpty ? "\(stem)-\(short)" : "\(stem)-\(short).\(candidateExt)"
                            return alt.caseInsensitiveCompare(filename) == .orderedSame
                        }
                        if byNameOrConflict.count == 1 {
                            matching = byNameOrConflict.first
                        } else {
                            let unboundTrashed = unbound.filter(\.isTrashed)
                            matching = unboundTrashed.count == 1 ? unboundTrashed.first : nil
                        }
                    }
                }
            }
            if matching == nil,
               try await database.state("deleted.content." + hash.sha256, as: DeletedAssetFingerprint.self) != nil,
               (try await database.assets(contentHash: hash.sha256)).isEmpty {
                try? FileManager.default.removeItem(at: folder)
                return .deletedLocally(fileID: file.id, fileName: file.name)
            }
            var id = matching?.id ?? DriveFiles.stableUUID("asset:" + file.id)
            if try await database.isTombstoned("asset", id: id) {
                if matching == nil, file.id.hasPrefix(MountedVolumeTransport.pathIDPrefix) {
                    id = UUID()
                } else {
                    try? FileManager.default.removeItem(at: folder)
                    return .skipped(fileName: file.name)
                }
            }

            let mime = isGoogleDocument ? "application/pdf" : file.mimeType
            let naturalTitle = (filename as NSString).deletingPathExtension
            var asset = matching ?? AssetRecord(id: id, title: naturalTitle, fileName: filename,
                                                createdAt: file.modifiedTime ?? .now)
            if asset.title == (asset.fileName as NSString).deletingPathExtension { asset.title = naturalTitle }
            asset.fileName = filename
            asset.foldRemote(fileID: file.id, folderID: job.folderID, kind: MediaKind.detect(fileExtension: ext, mimeType: mime),
                             mime: mime, hash: hash.sha256, size: hash.bytes)
            let rendered = try await media.refreshed(asset, from: temporary)
            let analysis: LocalAnalysisResult
            if rendered.mediaKind != .audio, let thumbnail = media.thumbnailURL(for: rendered.id, tier: .grid520) {
                analysis = await intelligence.analyze(thumbnailURL: thumbnail, includeColors: false)
            } else {
                analysis = LocalAnalysisResult()
            }
            return .prepared(PreparedRemoteAsset(
                file: file,
                existing: job.existing,
                matching: matching,
                folderURL: folder,
                temporaryURL: temporary,
                rendered: rendered,
                analysis: analysis
            ))
        } catch {
            try? FileManager.default.removeItem(at: folder)
            if Self.isFatalSyncError(error) { throw error }
            return .deferred(fileID: file.id, fileName: file.name)
        }
    }

    private func persistRemoteMedia(
        _ rendered: AssetRecord,
        matching: AssetRecord?,
        temporary: URL?,
        analysis: LocalAnalysisResult,
        config: DriveSyncConfig,
        moveTemporary: Bool = false
    ) async throws -> AssetRecord? {
        try await database.transaction { [media] store in
            guard try !store.isTombstoned("asset", id: rendered.id) else { return nil }
            var result = rendered
            if let current = try store.asset(id: rendered.id), let matching {
                // Guard against two parallel identical-content remote files claiming the same local record,
                // while still allowing legitimate re-binding from nil or an obsolete/old-transport driveFileID.
                if current.driveFileID != matching.driveFileID {
                    return nil
                }
                result.notes = current.notes
                result.tags = current.tags
                result.suggestedTags = current.suggestedTags
                result.aiDescription = current.aiDescription
                result.rating = current.rating
                result.isTrashed = current.isTrashed
                result.pinnedOffline = current.pinnedOffline
                if current.title != matching.title { result.title = current.title }
                if current.fileName != matching.fileName { result.fileName = current.fileName }
                if current.folderID != matching.folderID || current.isTrashed { result.folderID = current.folderID }
            }
            result.ocrText = result.ocrText ?? analysis.ocrText
            if let temporary {
                _ = try media.installOriginal(temporary, for: result, moveSource: moveTemporary)
                result.isLocalOriginalCached = true
            }
            let saved = try store.saveAssetLocally(result, projectLocation: false)
            if result.isLocalOriginalCached { try store.touchOriginal(result.id) }
            if let print = analysis.featurePrintData {
                let vector = AssetVector(featurePrint: print)
                if config.syncEmbeddings { try store.record(.vector(result.id, vector)) }
                else { try store.saveVector(vector, for: result.id) }
            }
            if config.syncThumbnails { try store.markProjection("thumbnails", id: result.id) }
            return saved
        }
    }

    private func uploadPhysical(for operations: [SyncOperation], layout: Layout, transport: any DriveTransport,
                                scope: String) async throws -> (removedFiles: Set<String>, removedFolders: Set<String>, renamedPrefixes: [(old: String, new: String)]) {
        var changedFolders = Set<UUID>()
        var movedAssets = Set<UUID>()
        var visitedAssets = Set<UUID>()
        var removedFiles = Set<String>()
        var removedFolders = Set<String>()
        var renamedPrefixes: [(old: String, new: String)] = []
        for operation in operations where operation.projectLocation != false {
            switch operation.change {
            case .folder(let value): changedFolders.insert(value.id)
            case .asset(let delta):
                visitedAssets.insert(delta.id)
                if delta.touchesLocation { movedAssets.insert(delta.id) }
            case .deleteAsset(let id, let driveID):
                if let driveID { removedFiles.insert(driveID) }
                else if transport is MountedVolumeTransport,
                        let local = try await database.state("local.delete.asset." + id.uuidString, as: String.self) {
                    removedFiles.insert(local)
                }
            case .deleteFolder(let id, let driveID):
                if let driveID { removedFolders.insert(driveID) }
                else if transport is MountedVolumeTransport,
                        let local = try await database.state("local.delete.folder." + id.uuidString, as: String.self) {
                    removedFolders.insert(local)
                }
            default: break
            }
        }
        var parents: [UUID: String] = [:]
        for id in changedFolders.sorted(by: { $0.uuidString < $1.uuidString }) {
            if try await database.folder(id: id) != nil {
                _ = try await resolveFolder(id, layout: layout, transport: transport, path: [], resolved: &parents, renamedPrefixes: &renamedPrefixes)
            }
        }
        let inventory: SavedInventory? = try await database.state(scope + ".inventory")
        let effectiveInventoryFiles = Self.applyingRenamedPrefixes(renamedPrefixes, to: inventory?.files ?? [:])
        let orderedAssets = visitedAssets.sorted(by: { $0.uuidString < $1.uuidString })

        struct MoveJob: Sendable {
            let assetID: UUID
            let remoteID: String
            let oldParent: String?
            let newParent: String
            let newName: String?
        }
        struct PendingUploadAsset: Sendable {
            let asset: AssetRecord
            let parent: String
            let localURL: URL
        }

        var moveJobs: [MoveJob] = []
        var pendingUploads: [PendingUploadAsset] = []
        var parentsToList = Set<String>()

        for id in orderedAssets {
            guard let asset = try await database.asset(id: id) else { continue }
            let remote = asset.driveFileID.flatMap { effectiveInventoryFiles[$0] }
            if remote != nil, !movedAssets.contains(id) { continue }
            let parent = if let folder = asset.folderID {
                try await resolveFolder(folder, layout: layout, transport: transport, path: [], resolved: &parents, renamedPrefixes: &renamedPrefixes)
            } else { layout.inbox }
            if let remote {
                let rename = Self.originalName(remote) == asset.fileName ? nil : asset.fileName
                if remote.parents.first != parent || rename != nil {
                    moveJobs.append(MoveJob(
                        assetID: id,
                        remoteID: remote.id,
                        oldParent: remote.parents.first,
                        newParent: parent,
                        newName: rename
                    ))
                }
                continue
            }
            if movedAssets.contains(id),
               let remoteID = asset.driveFileID,
               Self.isRemoteIDCompatible(remoteID, with: transport) {
                moveJobs.append(MoveJob(
                    assetID: id,
                    remoteID: remoteID,
                    oldParent: nil,
                    newParent: parent,
                    newName: asset.fileName
                ))
                continue
            }
            guard asset.driveFileID == nil
                    || asset.driveFileID?.hasPrefix("mounted-") == true
                    || asset.driveFileID?.hasPrefix(ICloudDriveTransport.pathIDPrefix) == true,
                  let url = media.cachedOriginal(for: asset) else { continue }
            pendingUploads.append(PendingUploadAsset(asset: asset, parent: parent, localURL: url))
            parentsToList.insert(parent)
        }

        let apiConcurrency = Self.concurrencyLimit(for: transport, directDefault: 6)

        // 1. Execute remote renames/moves in bounded parallel
        if !moveJobs.isEmpty {
            let movedResults = try await Self.runBounded(items: moveJobs, maxConcurrent: apiConcurrency) { job -> (UUID, String)? in
                do {
                    let moved = try await transport.moveFile(
                        fileID: job.remoteID,
                        fromParentID: job.oldParent,
                        toParentID: job.newParent,
                        newName: job.newName
                    )
                    return moved.id != job.remoteID ? (job.assetID, moved.id) : nil
                } catch DriveTransportError.fileNotFound {
                    return nil
                } catch DriveTransportError.httpError(statusCode: 404, message: _) {
                    return nil
                }
            }
            let updatedIDs = movedResults.compactMap { $0 }
            if !updatedIDs.isEmpty {
                try await database.transaction { store in
                    for (assetID, newRemoteID) in updatedIDs {
                        guard var current = try store.asset(id: assetID) else { continue }
                        current.driveFileID = newRemoteID
                        _ = try store.saveAssetLocally(current, projectLocation: false)
                    }
                }
            }
        }

        // 2. Fetch distinct parent listings + hash local files in parallel, then upload concurrently
        if !pendingUploads.isEmpty {
            let listingPairs = try await Self.runBounded(items: Array(parentsToList), maxConcurrent: apiConcurrency) { parentID -> (String, [RemoteDriveFile]) in
                (parentID, try await transport.listFiles(inFolderID: parentID))
            }
            var listings = Dictionary(uniqueKeysWithValues: listingPairs)
            var takenNamesByParent: [String: Set<String>] = listings.mapValues { Set($0.map { $0.name.lowercased() }) }

            struct UploadWork: Sendable {
                let asset: AssetRecord
                let parent: String
                let localURL: URL
                let shortID: String
                let reservedName: String
                let initialTaken: Set<String>
            }

            let hashedItems = try await Self.runBounded(items: pendingUploads, maxConcurrent: 6) { item -> (PendingUploadAsset, (sha256: String, md5: String, bytes: Int64)) in
                (item, try MediaPipeline.digests(item.localURL))
            }
            let digestsByAssetID = Dictionary(uniqueKeysWithValues: hashedItems.map { ($0.0.asset.id, $0.1) })

            var uploadQueue: [UploadWork] = []
            uploadQueue.reserveCapacity(pendingUploads.count)
            var alreadyBoundCount = 0
            let totalWork = pendingUploads.count

            for item in pendingUploads {
                let asset = item.asset
                let parent = item.parent
                let choices = listings[parent] ?? []
                guard let hash = digestsByAssetID[asset.id] else { continue }
                let short = String(asset.id.uuidString.prefix(8)).lowercased()
                let name = asset.fileName
                let ext = (name as NSString).pathExtension
                let suffix = ext.isEmpty ? "" : "." + ext
                let alternative = (name as NSString).deletingPathExtension + "-" + short + suffix
                var candidate = choices.first {
                    ($0.name.caseInsensitiveCompare(name) == .orderedSame
                        || $0.name.caseInsensitiveCompare(alternative) == .orderedSame)
                        && $0.md5Checksum == hash.md5
                }
                var unbound = try await candidate.mapAsync { try await database.asset(driveID: $0.id) == nil } ?? false
                if candidate == nil || !unbound {
                    for entry in choices where !entry.isFolder && entry.md5Checksum == nil && entry.size == hash.bytes && hash.bytes > 0 {
                        guard entry.name.caseInsensitiveCompare(name) == .orderedSame
                            || entry.name.caseInsensitiveCompare(alternative) == .orderedSame else { continue }
                        guard try await database.asset(driveID: entry.id) == nil else { continue }
                        if try await remoteFileMatchesHash(fileID: entry.id, expectedSHA256: hash.sha256, transport: transport) {
                            candidate = entry
                            unbound = true
                            break
                        }
                    }
                }
                if let candidate, unbound {
                    _ = try await bindUploadedAsset(asset: asset, uploaded: candidate, transport: transport)
                    alreadyBoundCount += 1
                    continue
                }

                // Pre-reserve unique filename per parent folder so parallel uploads never collide
                var taken = takenNamesByParent[parent] ?? []
                let reservedName = Self.nextAvailableFileName(
                    preferred: name,
                    shortID: short,
                    takenLowercasedNames: taken,
                    startIndex: 0
                )
                taken.insert(reservedName.lowercased())
                takenNamesByParent[parent] = taken
                uploadQueue.append(UploadWork(
                    asset: asset,
                    parent: parent,
                    localURL: item.localURL,
                    shortID: short,
                    reservedName: reservedName,
                    initialTaken: taken
                ))
            }

            if !uploadQueue.isEmpty {
                let uploadConcurrency = Self.concurrencyLimit(for: transport, directDefault: 5)
                var completed = alreadyBoundCount
                try await withThrowingTaskGroup(of: (AssetRecord, RemoteDriveFile).self) { group in
                    var nextIndex = 0
                    let enqueue: (inout ThrowingTaskGroup<(AssetRecord, RemoteDriveFile), Error>) -> Void = { grp in
                        guard nextIndex < uploadQueue.count else { return }
                        let work = uploadQueue[nextIndex]
                        nextIndex += 1
                        grp.addTask {
                            let uploaded = try await Self.uploadWithConflictRetry(
                                localURL: work.localURL,
                                preferredName: work.asset.fileName,
                                reservedName: work.reservedName,
                                shortID: work.shortID,
                                mimeType: work.asset.mimeType,
                                parentID: work.parent,
                                initialTaken: work.initialTaken,
                                transport: transport
                            )
                            return (work.asset, uploaded)
                        }
                    }

                    for _ in 0..<min(uploadConcurrency, uploadQueue.count) {
                        enqueue(&group)
                    }

                    while let (asset, uploaded) = try await group.next() {
                        enqueue(&group)
                        let deletedInFlight = try await bindUploadedAsset(asset: asset, uploaded: uploaded, transport: transport)
                        if !deletedInFlight {
                            listings[uploaded.parents.first ?? layout.inbox, default: []].append(uploaded)
                        }
                        completed += 1
                        let uploadRatio = 0.62 + 0.19 * (Double(completed) / Double(max(1, totalWork)))
                        updateProgress(
                            phase: .uploading(completed: completed, total: totalWork),
                            detail: "上传：\(asset.fileName)",
                            progress: uploadRatio
                        )
                    }
                }
            }
        }

        let compatibleRemovedFiles = removedFiles.filter { Self.isRemoteIDCompatible($0, with: transport) }
        if !compatibleRemovedFiles.isEmpty {
            _ = try await Self.runBounded(items: Array(compatibleRemovedFiles), maxConcurrent: apiConcurrency) { id -> String in
                try await Self.trashIfPresentStatic(id, transport: transport)
                return id
            }
        }
        let trashedFolders = try await Self.trashEmptyFoldersDeepestFirst(
            Array(removedFolders),
            inventoryFiles: effectiveInventoryFiles,
            transport: transport
        )
        return (compatibleRemovedFiles, trashedFolders, renamedPrefixes)
    }

    @discardableResult
    private func bindUploadedAsset(
        asset: AssetRecord,
        uploaded: RemoteDriveFile,
        transport: any DriveTransport
    ) async throws -> Bool {
        let deletedInFlight: Bool = try await database.transaction { store in
            guard var current = try store.asset(id: asset.id) else {
                // An in-flight deletion must trash the uploaded original and prevent resurrection.
                try store.setState("deleted.drive." + uploaded.id, true)
                try store.record(.deleteAsset(asset.id, driveID: uploaded.id))
                return true
            }
            current.driveFileID = uploaded.id
            if current.fileName == asset.fileName { current.fileName = uploaded.name }
            _ = try store.saveAssetLocally(current, projectLocation: false)
            return false
        }
        if deletedInFlight, Self.isRemoteIDCompatible(uploaded.id, with: transport) {
            try? await Self.trashIfPresentStatic(uploaded.id, transport: transport)
        }
        return deletedInFlight
    }

    private nonisolated static func uploadWithConflictRetry(
        localURL: URL,
        preferredName: String,
        reservedName: String,
        shortID: String,
        mimeType: String,
        parentID: String,
        initialTaken: Set<String>,
        transport: any DriveTransport
    ) async throws -> RemoteDriveFile {
        var takenNames = initialTaken
        for attempt in 0..<8 {
            let remoteName = attempt == 0
                ? reservedName
                : Self.nextAvailableFileName(
                    preferred: preferredName,
                    shortID: shortID,
                    takenLowercasedNames: takenNames,
                    startIndex: attempt
                )
            do {
                return try await transport.uploadFile(
                    from: localURL,
                    name: remoteName,
                    mimeType: mimeType,
                    parentID: parentID,
                    existingFileID: nil
                )
            } catch DriveTransportError.fileAlreadyExists {
                takenNames.insert(remoteName.lowercased())
                let fresh = try await transport.listFiles(inFolderID: parentID)
                for item in fresh { takenNames.insert(item.name.lowercased()) }
            }
        }
        throw DriveTransportError.fileAlreadyExists(preferredName)
    }

    private func resolveFolder(
        _ id: UUID,
        layout: Layout,
        transport: any DriveTransport,
        path: Set<UUID>,
        resolved: inout [UUID: String],
        renamedPrefixes: inout [(old: String, new: String)]
    ) async throws -> String {
        if let result = resolved[id] { return result }
        guard !path.contains(id) else { throw DriveTransportError.invalidResponse("Folder hierarchy contains a cycle.") }
        guard let folder = try await database.folder(id: id) else { return layout.inbox }
        let parent = if let parentID = folder.parentID {
            try await resolveFolder(parentID, layout: layout, transport: transport, path: path.union([id]), resolved: &resolved, renamedPrefixes: &renamedPrefixes)
        } else { layout.root }
        let result: RemoteDriveFile
        var movedFromKnown: String?
        if let known = folder.driveFolderID {
            do {
                result = try await transport.moveFile(fileID: known, fromParentID: nil, toParentID: parent, newName: folder.name)
                if result.id != known {
                    movedFromKnown = known
                }
            } catch DriveTransportError.fileNotFound {
                result = try await transport.findOrCreateFolder(named: folder.name, parentID: parent)
            } catch DriveTransportError.httpError(statusCode: 404, message: _) {
                result = try await transport.findOrCreateFolder(named: folder.name, parentID: parent)
            }
        } else {
            result = try await transport.findOrCreateFolder(named: folder.name, parentID: parent)
        }
        let isPathBasedTransport = (transport is WebDAVTransport) || (transport is MountedVolumeTransport) || (transport is ICloudDriveTransport)
        let renamedPrefix: (old: String, new: String)? = isPathBasedTransport ? movedFromKnown.map { ($0, result.id) } : nil
        try await database.transaction { store in
            if var current = try store.folder(id: id), current.driveFolderID != result.id {
                current.driveFolderID = result.id
                if !result.id.hasPrefix("mounted-") { try store.record(.folder(current), projectLocation: false) }
                try store.put(current)
            }
            if let prefix = renamedPrefix {
                let oldSlash = prefix.old + "/"
                let newSlash = prefix.new + "/"
                for var descendant in try store.fetchFolders() where descendant.id != id {
                    guard let existingID = descendant.driveFolderID, existingID.hasPrefix(oldSlash) else { continue }
                    let newDescendantID = newSlash + existingID.dropFirst(oldSlash.count)
                    descendant.driveFolderID = newDescendantID
                    if !newDescendantID.hasPrefix("mounted-") {
                        try store.record(.folder(descendant), projectLocation: false)
                    }
                    try store.put(descendant)
                }
                for var childAsset in try store.fetchAssets(matching: FilterCriteria(includeTrashed: true)) {
                    guard let existingID = childAsset.driveFileID, existingID.hasPrefix(oldSlash) else { continue }
                    let newAssetRemoteID = newSlash + existingID.dropFirst(oldSlash.count)
                    childAsset.driveFileID = newAssetRemoteID
                    if newAssetRemoteID.hasPrefix("mounted-") {
                        try store.put(childAsset)
                    } else if try !store.isTombstoned("asset", id: childAsset.id) {
                        _ = try store.saveAssetLocally(childAsset, projectLocation: false)
                    }
                }
            }
        }
        if let renamedPrefix {
            renamedPrefixes.append(renamedPrefix)
        }
        resolved[id] = result.id
        return result.id
    }

    private func remoteFileMatchesHash(
        fileID: String,
        expectedSHA256: String,
        transport: any DriveTransport
    ) async throws -> Bool {
        let probe = media.staging.appending(path: "verify-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: probe) }
        try await transport.downloadFile(fileID: fileID, to: probe)
        return try MediaPipeline.digests(probe).sha256 == expectedSHA256
    }

    private static func nextAvailableFileName(
        preferred: String,
        shortID: String,
        takenLowercasedNames: Set<String>,
        startIndex: Int
    ) -> String {
        let stem = (preferred as NSString).deletingPathExtension
        let ext = (preferred as NSString).pathExtension
        let suffix = ext.isEmpty ? "" : "." + ext
        if startIndex == 0 && !takenLowercasedNames.contains(preferred.lowercased()) {
            return preferred
        }
        let firstAlt = "\(stem)-\(shortID)\(suffix)"
        if startIndex <= 1 && !takenLowercasedNames.contains(firstAlt.lowercased()) {
            return firstAlt
        }
        var counter = max(2, startIndex)
        while counter < 10_000 {
            let candidate = "\(stem)-\(shortID)-\(counter)\(suffix)"
            if !takenLowercasedNames.contains(candidate.lowercased()) {
                return candidate
            }
            counter += 1
        }
        return "\(stem)-\(UUID().uuidString.prefix(8).lowercased())\(suffix)"
    }
}

private extension AssetRecord {
    mutating func foldRemote(fileID: String, folderID: UUID?, kind: MediaKind, mime: String, hash: String, size: Int64) {
        driveFileID = fileID
        self.folderID = folderID
        mediaKind = kind
        mimeType = mime
        contentHash = hash
        fileSizeBytes = size
    }
}

private extension Optional {
    func mapAsync<T>(_ transform: (Wrapped) async throws -> T) async rethrows -> T? {
        guard let value = self else { return nil }
        return try await transform(value)
    }
}
