import CryptoKit
import Foundation
import UniformTypeIdentifiers

public final actor DriveSyncEngine {
    private let database: LibraryDatabase
    private let media: MediaPipeline
    private let intelligence: IntelligenceEngine
    private var currentStatus = SyncStatus()
    private var running = false
    private var originalDownloads: [UUID: Task<URL, Error>] = [:]

    public init(database: LibraryDatabase, media: MediaPipeline, intelligence: IntelligenceEngine = IntelligenceEngine()) {
        self.database = database
        self.media = media
        self.intelligence = intelligence
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

    public func sync(using transport: any DriveTransport, config: DriveSyncConfig, allowLocalFolderSync: Bool = false) async throws -> SyncReport {
        if config.mode == .localOnly && !allowLocalFolderSync { return SyncReport() }
        guard !running else { throw DriveTransportError.notConfigured("当前已有同步任务正在运行，请稍候。") }
        running = true
        defer { running = false }
        currentStatus.phase = .scanning
        currentStatus.activeMode = config.mode
        let start = ContinuousClock.now
        do {
            let account = try await transport.accountInfo()
            currentStatus.account = account
            let rootPath = Self.resolvedRootPath(for: config)
            let layout = try await makeLayout(using: transport, rootPath: rootPath)
            let scope = "remote." + DriveFiles.stableUUID("\(transport.displayName):\(account.email):\(layout.root)").uuidString
            try await updateManifest(layout, transport: transport)

            var report = SyncReport()
            var pulled = try await pullOps(layout, from: transport, scope: scope, syncEmbeddings: config.syncEmbeddings)
            report.downloadedOps += pulled.count
            var changedBoards = pulled.boards

            let pending = try await database.pendingOps(as: SyncOperation.self, limit: 10_000)
            let inventory = try await fetchInventory(layout, transport: transport, scope: scope)
            currentStatus.phase = .merging
            let reconciled = try await reconcile(inventory, layout: layout, transport: transport, config: config, pending: pending)
            report.discoveredRemoteAssets = reconciled.discovered
            report.reconciledRenames = reconciled.renames
            let state = inventory.current
            try await database.setState(scope + ".inventory", state)

            if !pending.isEmpty {
                currentStatus.phase = .uploading(completed: 0, total: pending.count)
                try await uploadPhysical(for: pending.map { $0.1 }, layout: layout, transport: transport, scope: scope)
            }
            // Physical uploads can enqueue Drive identity bindings. Each shard has an immutable name.
            let ready = try await database.pendingOps(as: SyncOperation.self, limit: 10_000)
            let preparedIDs = Set(pending.compactMap { row -> UUID? in
                if case .asset(let delta) = row.1.change { return delta.id }
                return nil
            })
            var publishable: [(Int64, SyncOperation)] = []
            let cutoff = pending.last?.0 ?? 0
            for row in ready {
                if row.0 > cutoff {
                    guard case .asset(let delta) = row.1.change, preparedIDs.contains(delta.id),
                          delta.fields.count == 1, delta.fields["driveFileID"] != nil, delta.tagsAdded.isEmpty,
                          delta.tagsRemoved.isEmpty else { break }
                }
                publishable.append(row)
                switch row.1.change {
                case .board(let delta): changedBoards.insert(delta.id)
                case .deleteBoard(let id): changedBoards.insert(id)
                default: break
                }
            }
            report.uploadedOps = try await pushOps(publishable, to: transport, layout: layout, syncEmbeddings: config.syncEmbeddings)
            pulled = try await pullOps(layout, from: transport, scope: scope, syncEmbeddings: config.syncEmbeddings)
            report.downloadedOps += pulled.count
            changedBoards.formUnion(pulled.boards)
            try await writeBoards(layout, transport: transport)
            if config.syncThumbnails { try await syncThumbnails(layout, transport: transport, scope: scope) }
            if config.syncEmbeddings { try await writeEmbeddings(layout, transport: transport) }
            try await fetchPinnedOriginals(using: transport)
            try await database.removeDeletedMedia(using: media)
            report.updatedBoards = changedBoards.count
            let duration = start.duration(to: .now).components
            report.durationSeconds = Double(duration.seconds) + Double(duration.attoseconds) / 1e18
            currentStatus.lastSyncedAt = Date()
            currentStatus.lastError = nil
            currentStatus.phase = .idle
            try await database.setState("lastSyncStatus", currentStatus)
            return report
        } catch {
            currentStatus.phase = .error(error.localizedDescription)
            currentStatus.lastError = error.localizedDescription
            throw error
        }
    }

    public func downloadOriginal(for assetID: UUID, using transport: any DriveTransport) async throws -> URL {
        if let inFlight = originalDownloads[assetID] { return try await inFlight.value }
        let task = Task { try await copyOriginal(for: assetID, using: transport) }
        originalDownloads[assetID] = task
        defer { originalDownloads.removeValue(forKey: assetID) }
        return try await task.value
    }

    private func copyOriginal(for assetID: UUID, using transport: any DriveTransport) async throws -> URL {
        guard let asset = try await database.asset(id: assetID), let remote = asset.driveFileID else {
            throw DriveTransportError.fileNotFound(assetID.uuidString)
        }
        let target = media.staging.appending(path: "original-" + assetID.uuidString)
        try await transport.downloadFile(fileID: remote, to: target)
        defer { try? FileManager.default.removeItem(at: target) }
        return try await database.transaction { [media] store in
            guard var current = try store.asset(id: assetID), current.driveFileID == remote else {
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
        for id in try await database.protectedAssetIDs() {
            guard let asset = try await database.asset(id: id), asset.driveFileID != nil,
                  media.cachedOriginal(for: asset) == nil else { continue }
            _ = try await downloadOriginal(for: id, using: transport)
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
        case .localOnly:
            let url = URL(fileURLWithPath: (config.localLibraryPath as NSString).expandingTildeInPath, isDirectory: true).standardizedFileURL
            return url.lastPathComponent.isEmpty ? "Charkle" : url.lastPathComponent
        case .directAPIWithGDirect, .gdirectMount:
            return config.rootFolderName
        }
    }

    private func makeLayout(using transport: any DriveTransport, rootPath: String) async throws -> Layout {
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
        guard let root = rootFile else {
            throw DriveTransportError.notConfigured("请指定有效的素材库保存路径。")
        }
        async let inbox = transport.findOrCreateFolder(named: "Inbox", parentID: root.id)
        let metadata = try await transport.findOrCreateFolder(named: ".charkle", parentID: root.id)
        async let ops = transport.findOrCreateFolder(named: "ops", parentID: metadata.id)
        async let boards = transport.findOrCreateFolder(named: "boards", parentID: metadata.id)
        async let embeddings = transport.findOrCreateFolder(named: "embeddings", parentID: metadata.id)
        async let thumbnails = transport.findOrCreateFolder(named: "thumbnails", parentID: metadata.id)
        return try await Layout(root: root.id, inbox: inbox.id, metadata: metadata.id, ops: ops.id,
                                boards: boards.id, embeddings: embeddings.id, thumbnails: thumbnails.id)
    }

    private func updateManifest(_ layout: Layout, transport: any DriveTransport) async throws {
        if let known = try await transport.listFiles(inFolderID: layout.metadata).first(where: { $0.name == "manifest.json" }) {
            let data = try await transport.downloadData(fileID: known.id)
            let manifest = try JSONDecoder().decode(Manifest.self, from: data)
            guard manifest.version == 1 else {
                throw DriveTransportError.invalidResponse("Unsupported Charkle sync protocol \(manifest.version).")
            }
            return
        }
        let mounted = transport is MountedVolumeTransport
        let manifest = Manifest(version: 1, rootFolderID: mounted ? nil : layout.root, directories: mounted ? nil : [
            "Inbox": layout.inbox, "ops": layout.ops, "boards": layout.boards,
            "embeddings": layout.embeddings, "thumbnails": layout.thumbnails
        ])
        let data = try encoded(manifest)
        _ = try await write(data, name: "manifest.json", mime: "application/json", parent: layout.metadata,
                            existing: nil, transport: transport)
    }

    private struct LogLine: Codable, Sendable {
        let seq: Int64
        let operation: SyncOperation
    }

    private struct LogFile {
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
        let files = try await transport.listFiles(inFolderID: layout.ops).compactMap(LogFile.init)
            .filter { $0.device != device }.sorted { ($0.device, $0.end, $0.file.id) < ($1.device, $1.end, $1.file.id) }
        var cursors: [String: Int64] = try await database.state(scope + ".deviceCursors") ?? [:]
        var downloaded = 0
        var boards = Set<UUID>()
        for entry in files where entry.end > (cursors[entry.device] ?? 0) {
            try Task.checkCancellation()
            let data = try await transport.downloadData(fileID: entry.file.id)
            let lines = try data.split(separator: 0x0A).map { try JSONDecoder().decode(LogLine.self, from: Data($0)) }
            let previous = cursors[entry.device] ?? 0
            guard !lines.isEmpty, lines.last?.seq == entry.end, lines.allSatisfy({ $0.operation.stamp.device == entry.device }),
                  zip(lines, lines.dropFirst()).allSatisfy({ $0.seq < $1.seq }) else {
                throw DriveTransportError.invalidResponse("Malformed sync operation shard \(entry.file.name).")
            }
            let unseen = lines.filter { $0.seq > previous }
            cursors[entry.device] = entry.end
            let updated = cursors
            try await database.transaction { store in
                for line in unseen {
                    if case .vector = line.operation.change, !syncEmbeddings {
                        try store.setState("disabled.vector.\(entry.device).\(line.seq)", line.operation)
                    } else {
                        try store.apply(line.operation)
                    }
                }
                try store.setState(scope + ".deviceCursors", updated)
            }
            downloaded += unseen.count
            for line in unseen {
                switch line.operation.change {
                case .board(let delta): boards.insert(delta.id)
                case .deleteBoard(let id): boards.insert(id)
                default: break
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

    private func pushOps(_ operations: [(Int64, SyncOperation)], to transport: any DriveTransport,
                         layout: Layout, syncEmbeddings: Bool) async throws -> Int {
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
                    _ = try await transport.uploadData(bytes, name: name, mimeType: "application/x-ndjson",
                                                       parentID: layout.ops, existingFileID: nil)
                }
                uploaded += bytes.split(separator: 0x0A).count
            }
            try await database.acknowledgeOps(through: end)
            currentStatus.phase = .uploading(completed: min(operations.count, start + 200), total: operations.count)
        }
        return uploaded
    }

    private func writeBoards(_ layout: Layout, transport: any DriveTransport) async throws {
        let dirty: [String: String] = try await database.state("projection.boards") ?? [:]
        let files = keyedByName(try await transport.listFiles(inFolderID: layout.boards))
        let documents = try await database.fetchBoards()
        // Check the full file checksum so another device's last write cannot leave a stale board projection.
        for document in documents {
            let id = document.id.uuidString
            let name = id.lowercased() + ".json"
            let data = try encoded(document)
            _ = try await write(data, name: name, mime: "application/json", parent: layout.boards, existing: files[name],
                                transport: transport)
            if let mark = dirty[id] { try await database.clearProjection("boards", id: id, ifVersion: mark) }
        }
        let active = Set(documents.map { $0.id.uuidString })
        for (id, version) in dirty where !active.contains(id) {
            if let file = files[id.lowercased() + ".json"] { try await trashIfPresent(file.id, transport: transport) }
            try await database.clearProjection("boards", id: id, ifVersion: version)
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
        for (prefix, touched) in grouped {
            let name = "shard-\(prefix).bin"
            let existing = files[name]
            var shard: [String: EmbeddingBlob] = [:]
            if let existing {
                let data = try await transport.downloadData(fileID: existing.id)
                shard = try PropertyListDecoder().decode([String: EmbeddingBlob].self, from: data)
            }
            for id in shards[prefix, default: []] {
                if let vector = vectors[id] {
                    shard[id.uuidString] = EmbeddingBlob(feature: vector.featurePrint,
                                                        semantic: vector.embedding.map { vector.precision.encode($0) },
                                                        precision: vector.precision, model: vector.embeddingModel)
                }
            }
            for id in touched where UUID(uuidString: id).map({ vectors[$0] == nil }) == true { shard.removeValue(forKey: id) }
            let encoder = PropertyListEncoder()
            encoder.outputFormat = .binary
            _ = try await write(encoder.encode(shard), name: name, mime: "application/octet-stream",
                                parent: layout.embeddings, existing: existing, transport: transport)
            for id in touched {
                if let version = dirty[id] { try await database.clearProjection("embeddings", id: id, ifVersion: version) }
            }
        }
    }

    private func syncThumbnails(_ layout: Layout, transport: any DriveTransport, scope: String) async throws {
        let files = keyedByName(try await transport.listFiles(inFolderID: layout.thumbnails))
        let dirty: [String: String] = try await database.state("projection.thumbnails") ?? [:]
        for (id, version) in dirty {
            guard let uuid = UUID(uuidString: id) else { continue }
            let name = id.lowercased() + ".jpg"
            if let thumbnail = media.thumbnailURL(for: uuid, tier: .grid520), try await database.asset(id: uuid) != nil {
                _ = try await write(Data(contentsOf: thumbnail), name: name, mime: "image/jpeg", parent: layout.thumbnails,
                                    existing: files[name], transport: transport)
            } else if try await database.asset(id: uuid) == nil, let existing = files[name] {
                try await trashIfPresent(existing.id, transport: transport)
            }
            try await database.clearProjection("thumbnails", id: id, ifVersion: version)
        }
        var stamps: [String: String] = try await database.state(scope + ".thumbnails") ?? [:]
        for (name, file) in files where name.hasSuffix(".jpg") && !file.isFolder {
            guard let id = UUID(uuidString: String(name.dropLast(4))), dirty[id.uuidString] == nil,
                  try await database.asset(id: id) != nil else { continue }
            let key = id.uuidString
            let stamp = file.md5Checksum ?? (file.id + String(file.modifiedTime?.timeIntervalSince1970 ?? 0))
            if stamps[key] == stamp, media.thumbnailURL(for: id, tier: .grid520) != nil { continue }
            let data = try await transport.downloadData(fileID: file.id)
            try data.write(to: media.thumbnailPath(id), options: .atomic)
            stamps[key] = stamp
        }
        try await database.setState(scope + ".thumbnails", stamps)
    }

    private func write(_ data: Data, name: String, mime: String, parent: String, existing: RemoteDriveFile?,
                       transport: any DriveTransport) async throws -> RemoteDriveFile {
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
            // Mounted volumes enforce unique names. A simultaneous create is safe to adopt only
            // when it wrote the same bytes.
            if existing == nil, let concurrent = try? await transport.listFiles(inFolderID: parent).first(where: { $0.name == name }),
               let current = try? await transport.downloadData(fileID: concurrent.id), current == data {
                return concurrent
            }
            throw error
        }
    }

    private func encoded<T: Encodable>(_ value: T) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(value)
    }

    private func keyedByName(_ files: [RemoteDriveFile]) -> [String: RemoteDriveFile] {
        Dictionary(files.filter { !$0.isFolder }.sorted {
            ($0.modifiedTime ?? .distantPast, $0.id) > ($1.modifiedTime ?? .distantPast, $1.id)
        }.map { ($0.name, $0) }, uniquingKeysWith: { first, _ in first })
    }

    private func trashIfPresent(_ id: String, transport: any DriveTransport) async throws {
        do { try await transport.trashFile(fileID: id) }
        catch DriveTransportError.fileNotFound { }
        catch DriveTransportError.httpError(statusCode: 404, message: _) { }
    }
}

extension DriveSyncEngine {
    private struct Inventory: Sendable {
        var files: [String: RemoteDriveFile] = [:]
        var startPageToken: String
    }

    private struct InventoryUpdate: Sendable {
        let previous: [String: RemoteDriveFile]
        let current: SavedInventory
        let orderedFolders: [RemoteDriveFile]
    }

    private struct SavedInventory: Codable, Sendable {
        let files: [String: RemoteDriveFile]
        let startPageToken: String
    }

    private func fetchInventory(_ layout: Layout, transport: any DriveTransport, scope: String) async throws -> InventoryUpdate {
        let previous: SavedInventory? = try await database.state(scope + ".inventory")
        var inventory: Inventory
        if let previous {
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
        if previous != nil {
            // Drive changes can report only the ancestor when a whole folder is moved into Charkle.
            for folder in newFolders where folder.id != layout.inbox {
                try await collectChildren(of: folder.id, into: &inventory.files, layout: layout, transport: transport)
            }
            visible = reachable(inventory.files, layout: layout)
        }
        let current = SavedInventory(files: visible.files, startPageToken: inventory.startPageToken)
        return InventoryUpdate(previous: known, current: current, orderedFolders: visible.folders)
    }

    private func crawl(layout: Layout, transport: any DriveTransport) async throws -> Inventory {
        let token = try await transport.fetchStartPageToken()
        var files: [String: RemoteDriveFile] = [:]
        try await collectChildren(of: layout.root, into: &files, layout: layout, transport: transport)
        return Inventory(files: files, startPageToken: token)
    }

    private func collectChildren(of root: String, into files: inout [String: RemoteDriveFile], layout: Layout,
                                 transport: any DriveTransport) async throws {
        var folders = [root]
        var seen = Set<String>()
        var index = 0
        while index < folders.count {
            let folder = folders[index]
            index += 1
            guard seen.insert(folder).inserted else { continue }
            for file in try await transport.listFiles(inFolderID: folder) where isVisible(file, layout: layout) {
                files[file.id] = file
                if file.isFolder { folders.append(file.id) }
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

    private func isVisible(_ file: RemoteDriveFile, layout: Layout) -> Bool {
        !file.trashed && file.id != layout.metadata && !file.name.hasPrefix(".")
            && file.mimeType != "application/vnd.google-apps.shortcut"
    }

    private func reconcile(_ update: InventoryUpdate, layout: Layout, transport: any DriveTransport,
                           config: DriveSyncConfig, pending: [(Int64, SyncOperation)]) async throws -> (discovered: Int, renames: Int) {
        var folderIDs: [String: UUID] = [:]
        var pendingMoves = Set<UUID>()
        var pendingFolders = Set<UUID>()
        for (_, op) in pending {
            switch op.change {
            case .asset(let delta) where delta.touchesLocation && op.projectLocation != false: pendingMoves.insert(delta.id)
            case .folder(let folder) where op.projectLocation != false: pendingFolders.insert(folder.id)
            default: break
            }
        }
        var folders = try await database.fetchFolders()
        for file in update.orderedFolders where file.id != layout.inbox {
            let parent = file.parents.first.flatMap { folderIDs[$0] }
            let found = folders.firstIndex(where: { $0.driveFolderID == file.id })
                ?? folders.firstIndex(where: { $0.parentID == parent && $0.name == file.name })
            let id = found.map { folders[$0].id } ?? DriveFiles.stableUUID("folder:" + file.id)
            let sortOrder = folders.count
            let record = try await database.transaction { [pendingFolders] store -> FolderRecord? in
                if try store.isTombstoned("folder", id: id) { return nil }
                var folder = try store.folder(id: id) ?? FolderRecord(id: id, name: file.name, parentID: parent, sortOrder: sortOrder)
                let before = folder
                if !pendingFolders.contains(id), update.previous[file.id]?.name != file.name || update.previous[file.id]?.parents != file.parents {
                    folder.name = file.name
                    folder.parentID = parent
                }
                folder.driveFolderID = file.id
                if before.name != folder.name || before.parentID != folder.parentID || found == nil {
                    folder.updatedAt = file.modifiedTime ?? .now
                    try store.record(.folder(folder), projectLocation: false)
                }
                if let stored = try store.folder(id: id) {
                    folder = stored
                    folder.driveFolderID = file.id
                }
                try store.put(folder)
                return folder
            }
            guard let record else { continue }
            folderIDs[file.id] = record.id
            if let found { folders[found] = record } else { folders.append(record) }
        }
        let thumbnails = config.syncThumbnails ? keyedByName(try await transport.listFiles(inFolderID: layout.thumbnails)) : [:]
        var discovered = 0
        var renames = 0
        let bindings = try await database.assetDriveBindings()
        var linked = Dictionary(uniqueKeysWithValues: bindings)
        let visible = update.current.files.values.filter { file in
            guard !file.isFolder else { return false }
            if update.previous[file.id] != file { return true }
            guard let id = linked[file.id] else { return true }
            return media.thumbnailURL(for: id, tier: .grid520) == nil
        }.sorted { $0.id < $1.id }
        for file in visible {
            try Task.checkCancellation()
            if try await database.state("deleted.drive." + file.id, as: Bool.self) == true { continue }
            let previous = update.previous[file.id]
            let folderID = file.parents.first.flatMap { folderIDs[$0] }
            let existing = try await linked[file.id].mapAsync { try await database.asset(id: $0) } ?? nil
            let changedContent = Self.contentChanged(before: previous, after: file)
            if let existing, !changedContent || previous == nil {
                if previous != file || existing.folderID == nil && folderID != nil {
                    let outcome = try await reconcileLocation(file, previous: previous, existing: existing, folderID: folderID,
                                                              pendingMove: pendingMoves.contains(existing.id))
                    renames += outcome ? 1 : 0
                }
                // Trashed records keep their metadata and permanent thumbnail without fetching bytes.
                if existing.isTrashed || media.thumbnailURL(for: existing.id, tier: .grid520) != nil
                    || thumbnails[existing.id.uuidString.lowercased() + ".jpg"] != nil { continue }
                if let cached = media.cachedOriginal(for: existing) {
                    let rendered = try await media.refreshed(existing, from: cached)
                    _ = try await persistRemoteMedia(rendered, matching: existing, temporary: nil, config: config)
                    continue
                }
            }
            let result = try await fetchRemoteAsset(file, folderID: folderID, existing: existing,
                                                    current: update.current, config: config, transport: transport)
            if let result {
                linked[file.id] = result.id
                if existing == nil && result.id == DriveFiles.stableUUID("asset:" + file.id) { discovered += 1 }
                if let existing, existing.fileName != result.fileName || existing.folderID != result.folderID { renames += 1 }
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
        return (discovered, renames)
    }

    private static func contentChanged(before: RemoteDriveFile?, after: RemoteDriveFile) -> Bool {
        guard let before, before != after else { return false }
        if let a = before.md5Checksum, let b = after.md5Checksum { return a != b }
        if let a = before.size, let b = after.size, a != b { return true }
        return before.name == after.name && before.parents == after.parents && before.modifiedTime != after.modifiedTime
    }

    private func reconcileLocation(_ file: RemoteDriveFile, previous: RemoteDriveFile?, existing asset: AssetRecord,
                                   folderID: UUID?, pendingMove: Bool) async throws -> Bool {
        guard !pendingMove else { return false }
        let filename = Self.originalName(file)
        return try await database.transaction { store in
            guard var current = try store.asset(id: asset.id), current.driveFileID == file.id else { return false }
            let before = current
            if previous?.name != file.name, current.fileName != filename {
                if current.title == (current.fileName as NSString).deletingPathExtension {
                    current.title = (filename as NSString).deletingPathExtension
                }
                current.fileName = filename
            }
            if previous?.parents != file.parents { current.folderID = folderID }
            let hiddenKey = "remote.hidden." + file.id
            if try store.state(hiddenKey, as: Bool.self) == true {
                current.isTrashed = false
                try store.setState(hiddenKey, Optional<Bool>.none)
            }
            if current != before { _ = try store.saveAssetLocally(current, projectLocation: false) }
            return current != before
        }
    }

    private static func originalName(_ file: RemoteDriveFile) -> String {
        if file.mimeType.hasPrefix("application/vnd.google-apps."), !file.name.lowercased().hasSuffix(".pdf") {
            return file.name + ".pdf"
        }
        return file.name
    }

    private func fetchRemoteAsset(_ file: RemoteDriveFile, folderID: UUID?, existing: AssetRecord?, current: SavedInventory,
                                  config: DriveSyncConfig, transport: any DriveTransport) async throws -> AssetRecord? {
        let folder = media.staging.appending(path: "remote-" + DriveFiles.stableUUID(file.id).uuidString, directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let isGoogleDocument = file.mimeType.hasPrefix("application/vnd.google-apps.")
        let filename = Self.originalName(file)
        let ext = (filename as NSString).pathExtension.filter { $0.isASCII && ($0.isLetter || $0.isNumber) }
        let temporary = folder.appending(path: ext.isEmpty ? "content" : "content." + ext)
        try await transport.downloadFile(fileID: file.id, to: temporary)
        defer { try? FileManager.default.removeItem(at: folder) }
        let hash = try MediaPipeline.digests(temporary)
        let matching: AssetRecord?
        if let existing {
            matching = existing
        } else {
            let matches = try await database.assets(contentHash: hash.sha256).filter {
                ($0.driveFileID == nil && $0.fileName == filename && $0.folderID == folderID)
                    || ($0.driveFileID.map { current.files[$0] == nil } == true && !$0.isTrashed)
            }
            matching = matches.count == 1 ? matches.first : nil
        }
        let id = matching?.id ?? DriveFiles.stableUUID("asset:" + file.id)
        if try await database.isTombstoned("asset", id: id) { return nil }

        let mime = isGoogleDocument ? "application/pdf" : file.mimeType
        let naturalTitle = (filename as NSString).deletingPathExtension
        var asset = matching ?? AssetRecord(id: id, title: naturalTitle, fileName: filename,
                                            createdAt: file.modifiedTime ?? .now)
        if asset.title == (asset.fileName as NSString).deletingPathExtension { asset.title = naturalTitle }
        asset.fileName = filename
        asset.foldRemote(fileID: file.id, folderID: folderID, kind: MediaKind.detect(fileExtension: ext, mimeType: mime),
                         mime: mime, hash: hash.sha256, size: hash.bytes)
        let rendered = try await media.refreshed(asset, from: temporary)
        return try await persistRemoteMedia(rendered, matching: matching, temporary: temporary, config: config)
    }

    private func persistRemoteMedia(_ rendered: AssetRecord, matching: AssetRecord?, temporary: URL?,
                                    config: DriveSyncConfig) async throws -> AssetRecord? {
        let analysis: LocalAnalysisResult
        if rendered.mediaKind != .audio, let thumbnail = media.thumbnailURL(for: rendered.id, tier: .grid520) {
            analysis = await intelligence.analyze(thumbnailURL: thumbnail, includeColors: false)
        } else { analysis = LocalAnalysisResult() }
        return try await database.transaction { [media] store in
            guard try !store.isTombstoned("asset", id: rendered.id) else { return nil }
            var result = rendered
            if let current = try store.asset(id: rendered.id), let matching {
                result.notes = current.notes
                result.tags = current.tags
                result.suggestedTags = current.suggestedTags
                result.aiDescription = current.aiDescription
                result.rating = current.rating
                result.isTrashed = current.isTrashed
                result.pinnedOffline = current.pinnedOffline
                if current.title != matching.title { result.title = current.title }
                if current.fileName != matching.fileName { result.fileName = current.fileName }
                if current.folderID != matching.folderID { result.folderID = current.folderID }
            }
            result.ocrText = result.ocrText ?? analysis.ocrText
            if let temporary {
                _ = try media.installOriginal(temporary, for: result)
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
                                scope: String) async throws {
        var changedFolders = Set<UUID>()
        var movedAssets = Set<UUID>()
        var visitedAssets = Set<UUID>()
        var removedFiles = Set<String>()
        var removedFolders = Set<String>()
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
                _ = try await resolveFolder(id, layout: layout, transport: transport, path: [], resolved: &parents)
            }
        }
        let inventory: SavedInventory? = try await database.state(scope + ".inventory")
        var listings: [String: [RemoteDriveFile]] = [:]
        for id in visitedAssets.sorted(by: { $0.uuidString < $1.uuidString }) {
            guard let asset = try await database.asset(id: id) else { continue }
            let remote = asset.driveFileID.flatMap { inventory?.files[$0] }
            if remote != nil, !movedAssets.contains(id) { continue }
            let parent = if let folder = asset.folderID {
                try await resolveFolder(folder, layout: layout, transport: transport, path: [], resolved: &parents)
            } else { layout.inbox }
            if let remote {
                let rename = Self.originalName(remote) == asset.fileName ? nil : asset.fileName
                if remote.parents.first != parent || rename != nil {
                    _ = try await transport.moveFile(fileID: remote.id, fromParentID: remote.parents.first,
                                                     toParentID: parent, newName: rename)
                }
                continue
            }
            guard asset.driveFileID == nil || asset.driveFileID?.hasPrefix("mounted-") == true,
                  let url = media.cachedOriginal(for: asset) else { continue }
            var choices: [RemoteDriveFile]
            if let known = listings[parent] { choices = known }
            else { choices = try await transport.listFiles(inFolderID: parent) }
            let hash = try MediaPipeline.digests(url)
            let short = String(asset.id.uuidString.prefix(8)).lowercased()
            let name = asset.fileName
            let ext = (name as NSString).pathExtension
            let suffix = ext.isEmpty ? "" : "." + ext
            let alternative = (name as NSString).deletingPathExtension + "-" + short + suffix
            let candidate = choices.first { ($0.name == name || $0.name == alternative) && $0.md5Checksum == hash.md5 }
            let unbound = try await candidate.mapAsync { try await database.asset(driveID: $0.id) == nil } ?? false
            let uploaded: RemoteDriveFile
            if let candidate, unbound { uploaded = candidate }
            else {
                let remoteName = choices.contains { $0.name == name } ? alternative : name
                uploaded = try await transport.uploadFile(from: url, name: remoteName, mimeType: asset.mimeType,
                                                          parentID: parent, existingFileID: nil)
                choices.append(uploaded)
            }
            listings[parent] = choices
            try await database.transaction { store in
                guard var current = try store.asset(id: id) else {
                    // An in-flight deletion must be able to finish trashing the uploaded original.
                    try store.record(.deleteAsset(id, driveID: uploaded.id))
                    return
                }
                current.driveFileID = uploaded.id
                let localName = current.fileName
                if localName == asset.fileName { current.fileName = uploaded.name }
                _ = try store.saveAssetLocally(current, projectLocation: false)
            }
        }

        for id in removedFiles { try await trashIfPresent(id, transport: transport) }
        for id in removedFolders {
            do {
                if try await transport.listFiles(inFolderID: id).isEmpty { try await trashIfPresent(id, transport: transport) }
            } catch DriveTransportError.fileNotFound { }
            catch DriveTransportError.httpError(statusCode: 404, message: _) { }
        }
    }

    private func resolveFolder(_ id: UUID, layout: Layout, transport: any DriveTransport, path: Set<UUID>,
                               resolved: inout [UUID: String]) async throws -> String {
        if let result = resolved[id] { return result }
        guard !path.contains(id) else { throw DriveTransportError.invalidResponse("Folder hierarchy contains a cycle.") }
        guard let folder = try await database.folder(id: id) else { return layout.inbox }
        let parent = if let parentID = folder.parentID {
            try await resolveFolder(parentID, layout: layout, transport: transport, path: path.union([id]), resolved: &resolved)
        } else { layout.root }
        let result: RemoteDriveFile
        if let known = folder.driveFolderID {
            do {
                result = try await transport.moveFile(fileID: known, fromParentID: nil, toParentID: parent, newName: folder.name)
            } catch DriveTransportError.fileNotFound {
                result = try await transport.findOrCreateFolder(named: folder.name, parentID: parent)
            } catch DriveTransportError.httpError(statusCode: 404, message: _) {
                result = try await transport.findOrCreateFolder(named: folder.name, parentID: parent)
            }
        } else {
            result = try await transport.findOrCreateFolder(named: folder.name, parentID: parent)
        }
        try await database.transaction { store in
            if var current = try store.folder(id: id), current.driveFolderID != result.id {
                current.driveFolderID = result.id
                if !result.id.hasPrefix("mounted-") { try store.record(.folder(current), projectLocation: false) }
                try store.put(current)
            }
        }
        resolved[id] = result.id
        return result.id
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
