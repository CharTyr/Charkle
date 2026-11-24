import Foundation

nonisolated struct SyncStamp: Codable, Hashable, Comparable, Sendable {
    let time: Int64
    let device: String

    static func < (lhs: Self, rhs: Self) -> Bool {
        (lhs.time, lhs.device) < (rhs.time, rhs.device)
    }
}

nonisolated struct SyncOperation: Codable, Sendable {
    enum Change: Codable, Sendable {
        case asset(AssetChanges)
        case board(BoardChanges)
        case folder(FolderRecord)
        case deleteAsset(UUID, driveID: String?)
        case deleteBoard(UUID)
        case deleteFolder(UUID, driveID: String?)
        case vector(UUID, AssetVector)
    }

    let stamp: SyncStamp
    let change: Change
    var projectLocation: Bool? = nil
}

nonisolated struct AssetChanges: Codable, Sendable {
    let id: UUID
    let fields: [String: Data]
    let tagsAdded: [String]
    let tagsRemoved: [String]

    init(_ value: AssetRecord, diff previous: AssetRecord?) throws {
        id = value.id
        fields = try SyncFields.diff(value, previous, excluding: Self.excluded)
        let old = tagMap(previous?.tags ?? [])
        let new = tagMap(value.tags)
        tagsAdded = new.keys.sorted().compactMap { old[$0] == new[$0] ? nil : new[$0] }
        tagsRemoved = old.keys.sorted().filter { new[$0] == nil }
    }

    static let excluded: Set<String> = ["id", "tags", "isLocalOriginalCached", "updatedAt", "updatedHLC"]
    var isEmpty: Bool { fields.isEmpty && tagsAdded.isEmpty && tagsRemoved.isEmpty }
    var touchesLocation: Bool { fields.keys.contains("folderID") || fields.keys.contains("fileName") }
}

nonisolated struct BoardChanges: Codable, Sendable {
    let id: UUID
    let fields: [String: Data]
    let nodes: CollectionChanges<BoardNode>
    let connectors: CollectionChanges<BoardConnector>
    let strokes: CollectionChanges<InkStroke>

    init(_ value: MoodboardDocument, diff previous: MoodboardDocument?) throws {
        id = value.id
        fields = try SyncFields.diff(value, previous, excluding: Self.excluded)
        nodes = CollectionChanges(value.nodes, diff: previous?.nodes ?? [])
        connectors = CollectionChanges(value.connectors, diff: previous?.connectors ?? [])
        strokes = CollectionChanges(value.inkStrokes, diff: previous?.inkStrokes ?? [])
    }

    static let excluded: Set<String> = ["id", "nodes", "connectors", "inkStrokes", "updatedAt", "updatedHLC"]
    var isEmpty: Bool { fields.isEmpty && nodes.isEmpty && connectors.isEmpty && strokes.isEmpty }
}

nonisolated struct CollectionChanges<Element: Codable & Hashable & Identifiable & Sendable>: Codable, Sendable where Element.ID == UUID {
    let updated: [Element]
    let removed: [UUID]

    init(_ values: [Element], diff previous: [Element]) {
        let before = Dictionary(previous.map { ($0.id, $0) }, uniquingKeysWith: { _, last in last })
        let after = Dictionary(values.map { ($0.id, $0) }, uniquingKeysWith: { _, last in last })
        updated = after.values.filter { before[$0.id] != $0 }.sorted { $0.id.uuidString < $1.id.uuidString }
        removed = before.keys.filter { after[$0] == nil }.sorted { $0.uuidString < $1.uuidString }
    }

    var isEmpty: Bool { updated.isEmpty && removed.isEmpty }

    func apply(to values: [Element], component: String, stamp: SyncStamp, clocks: inout SyncClocks) -> [Element] {
        var indexed = Dictionary(values.map { ($0.id, $0) }, uniquingKeysWith: { _, last in last })
        for id in removed where clocks.accept(stamp, key: component + id.uuidString) { indexed.removeValue(forKey: id) }
        for item in updated where clocks.accept(stamp, key: component + item.id.uuidString) { indexed[item.id] = item }
        return indexed.values.sorted { $0.id.uuidString < $1.id.uuidString }
    }
}

struct DeletedAssetFingerprint: Codable, Hashable, Sendable {
    let assetID: UUID
    let sha256: String
    let md5: String?
    let fileName: String
    let deletedAt: Date
}

nonisolated struct SyncClocks: Codable, Sendable {
    private var clocks: [String: SyncStamp] = [:]

    mutating func accept(_ stamp: SyncStamp, key: String) -> Bool {
        if let current = clocks[key], current >= stamp { return false }
        clocks[key] = stamp
        return true
    }

    var deleted: Bool { clocks["deleted"] != nil }
}

nonisolated enum SyncFields {
    private static let jsonOptions: JSONSerialization.WritingOptions = [.fragmentsAllowed, .sortedKeys]

    static func diff<T: Encodable>(_ value: T, _ previous: T?, excluding: Set<String>) throws -> [String: Data] {
        let fields = try object(value)
        let old: [String: Any] = if let previous { try object(previous) } else { [:] }
        var changes: [String: Data] = [:]
        for key in Set(fields.keys).union(old.keys).subtracting(excluding) {
            let newValue = try JSONSerialization.data(withJSONObject: fields[key] ?? NSNull(), options: jsonOptions)
            let oldValue = try old[key].map { try JSONSerialization.data(withJSONObject: $0, options: jsonOptions) }
            if newValue != oldValue { changes[key] = newValue }
        }
        return changes
    }

    static func merge<T: Codable>(_ delta: [String: Data], into original: T, excluding: Set<String>,
                                   stamp: SyncStamp, clocks: inout SyncClocks) throws -> T {
        var fields = try object(original)
        for (field, data) in delta where !excluding.contains(field) && clocks.accept(stamp, key: "field:" + field) {
            let value = try JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed])
            fields[field] = value is NSNull ? nil : value
        }
        return try JSONDecoder().decode(T.self, from: JSONSerialization.data(withJSONObject: fields))
    }

    private static func object<T: Encodable>(_ value: T) throws -> [String: Any] {
        let data = try JSONEncoder().encode(value)
        guard let fields = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw DriveTransportError.invalidResponse("Invalid sync payload.")
        }
        return fields
    }
}

nonisolated func tagMap(_ tags: [String]) -> [String: String] {
    var result: [String: String] = [:]
    for tag in tags {
        let clean = tag.trimmingCharacters(in: .whitespacesAndNewlines)
        let key = SearchText.normalize(clean)
        if !key.isEmpty { result[key] = clean }
    }
    return result
}

extension LibraryDatabase {
    func deviceID() throws -> String {
        if let id: String = try state("deviceID") { return id }
        let id = UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased()
        try setState("deviceID", id)
        return id
    }

    func record(_ change: SyncOperation.Change, projectLocation: Bool = true) throws {
        let previous: Int64 = try state("hlc") ?? 0
        let now = Int64(Date().timeIntervalSince1970 * 1_000) * 1_024
        let stamp = SyncStamp(time: max(now, previous + 1), device: try deviceID())
        let op = SyncOperation(stamp: stamp, change: change, projectLocation: projectLocation ? nil : false)
        try apply(op)
        try appendOp(op)
    }

    func saveAssetLocally(_ value: AssetRecord, projectLocation: Bool = true) throws -> AssetRecord {
        guard try !isTombstoned("asset", id: value.id) else {
            throw DriveTransportError.fileNotFound(value.id.uuidString)
        }
        let existing = try asset(id: value.id)
        var asset = value
        var prior = existing
        // Inodes identify files within one mounted filesystem view.
        if asset.driveFileID?.hasPrefix("mounted-") == true { asset.driveFileID = prior?.driveFileID }
        if prior?.driveFileID?.hasPrefix("mounted-") == true {
            prior?.driveFileID = nil
            if asset.driveFileID?.hasPrefix("mounted-") == true { asset.driveFileID = nil }
        }
        let delta = try AssetChanges(asset, diff: prior)
        if !delta.isEmpty { try record(.asset(delta), projectLocation: projectLocation) }
        var saved = try self.asset(id: value.id) ?? value
        let needsLocalMetadataWrite = (delta.isEmpty && existing == nil)
            || saved.isLocalOriginalCached != value.isLocalOriginalCached
            || saved.driveFileID != value.driveFileID
        if needsLocalMetadataWrite {
            saved.isLocalOriginalCached = value.isLocalOriginalCached
            saved.driveFileID = value.driveFileID
            try put(saved)
        }
        return saved
    }

    func saveBoardLocally(_ board: MoodboardDocument) throws -> MoodboardDocument {
        guard try !isTombstoned("board", id: board.id) else {
            throw DriveTransportError.fileNotFound(board.id.uuidString)
        }
        let delta = try BoardChanges(board, diff: self.board(id: board.id))
        if !delta.isEmpty { try record(.board(delta)) }
        return try self.board(id: board.id) ?? board
    }

    /// Rebuilds the sync operation queue cleanly from the authoritative local library state when
    /// migrating between storage backends (e.g. Local Folder <-> Google Drive <-> WebDAV) or changing root path.
    func requeueLibraryForBackendMigration(
        syncThumbnails: Bool,
        syncEmbeddings: Bool
    ) throws -> (assets: Int, folders: Int, boards: Int) {
        // Clear old backend sync state and stale remote bindings
        try clearMigrationSyncState()

        // Re-queue folders in parent-before-child topological order
        let existingFolders = try fetchFolders()
        let folderByID = Dictionary(uniqueKeysWithValues: existingFolders.map { ($0.id, $0) })
        var orderedFolders: [FolderRecord] = []
        var visited = Set<UUID>()
        func visitFolder(_ f: FolderRecord) {
            guard visited.insert(f.id).inserted else { return }
            if let parentID = f.parentID, let parent = folderByID[parentID] {
                visitFolder(parent)
            }
            orderedFolders.append(f)
        }
        for f in existingFolders { visitFolder(f) }

        for var folder in orderedFolders {
            folder.driveFolderID = nil
            try put(folder)
            try record(.folder(folder))
        }

        // Clear stale old-backend remote IDs on trashed assets too so restoring from Trash later
        // never attempts to fetch an ID belonging to the retired storage backend.
        let trashedAssets = try fetchAssets(matching: FilterCriteria(onlyTrashed: true))
        for var trashed in trashedAssets where trashed.driveFileID != nil {
            trashed.driveFileID = nil
            try put(trashed)
        }

        // Re-queue all non-trashed assets with clean unbound remote IDs
        let allAssets = try fetchAssets(matching: FilterCriteria(includeTrashed: false))
        let allVectors = try vectors()
        for var asset in allAssets {
            asset.driveFileID = nil
            try put(asset)
            let delta = try AssetChanges(asset, diff: nil)
            if !delta.isEmpty {
                try record(.asset(delta))
            }
            if syncThumbnails {
                try markProjection("thumbnails", id: asset.id)
            }
            if syncEmbeddings, let vector = allVectors[asset.id] {
                try record(.vector(asset.id, vector))
            }
        }

        // Re-queue all moodboards
        let allBoards = try fetchBoards()
        for board in allBoards {
            let delta = try BoardChanges(board, diff: nil)
            if !delta.isEmpty {
                try record(.board(delta))
            }
            try markProjection("boards", id: board.id)
        }

        return (allAssets.count, orderedFolders.count, allBoards.count)
    }

    func apply(_ op: SyncOperation) throws {
        let stamp = op.stamp
        guard stamp.time > 0, stamp.time < Int64.max - 1 else {
            throw DriveTransportError.invalidResponse("Invalid sync clock.")
        }
        let observed: Int64 = try state("hlc") ?? 0
        if observed < stamp.time { try setState("hlc", stamp.time) }
        let date = Date(timeIntervalSince1970: Double(stamp.time / 1_024) / 1_000)
        switch op.change {
        case .asset(let delta):
            let key = "clock.asset." + delta.id.uuidString
            var clocks: SyncClocks = try state(key) ?? SyncClocks()
            guard !clocks.deleted else { return }
            let current = try asset(id: delta.id) ?? AssetRecord(
                id: delta.id, title: "", fileName: "", isLocalOriginalCached: false, createdAt: date, updatedAt: date
            )
            let excluded = current.driveFileID?.hasPrefix("mounted-") == true
                ? AssetChanges.excluded.union(["driveFileID"]) : AssetChanges.excluded
            var merged = try SyncFields.merge(delta.fields, into: current, excluding: excluded,
                                              stamp: stamp, clocks: &clocks)
            var tags = tagMap(current.tags)
            for tag in delta.tagsRemoved where clocks.accept(stamp, key: "tag:" + tag) {
                tags.removeValue(forKey: tag)
            }
            for tag in delta.tagsAdded {
                let normalized = SearchText.normalize(tag)
                if !normalized.isEmpty, clocks.accept(stamp, key: "tag:" + normalized) { tags[normalized] = tag }
            }
            merged.tags = tags.values.sorted()
            if current.updatedHLC <= stamp.time {
                merged.updatedHLC = stamp.time
                merged.updatedAt = date
            }
            if let driveID = merged.driveFileID, let duplicate = try asset(driveID: driveID), duplicate.id != delta.id {
                // The original can become visible on Drive just before its creation operation.
                if duplicate.id == DriveFiles.stableUUID("asset:" + driveID) {
                    try remapDiscoveredAsset(duplicate, to: delta.id)
                } else {
                    merged.driveFileID = current.driveFileID
                }
            }
            try put(merged)
            try setState(key, clocks)
        case .board(let delta):
            let key = "clock.board." + delta.id.uuidString
            var clocks: SyncClocks = try state(key) ?? SyncClocks()
            guard !clocks.deleted else { return }
            let current = try board(id: delta.id) ?? MoodboardDocument(id: delta.id, title: "", createdAt: date, updatedAt: date)
            var merged = try SyncFields.merge(delta.fields, into: current, excluding: BoardChanges.excluded,
                                              stamp: stamp, clocks: &clocks)
            merged.nodes = delta.nodes.apply(to: current.nodes, component: "node:", stamp: stamp, clocks: &clocks)
                .sorted { ($0.editorialOrder, $0.zIndex, $0.id.uuidString) < ($1.editorialOrder, $1.zIndex, $1.id.uuidString) }
            merged.connectors = delta.connectors.apply(to: current.connectors, component: "connector:", stamp: stamp, clocks: &clocks)
            merged.inkStrokes = delta.strokes.apply(to: current.inkStrokes, component: "stroke:", stamp: stamp, clocks: &clocks)
                .sorted { ($0.zIndex, $0.createdAt, $0.id.uuidString) < ($1.zIndex, $1.createdAt, $1.id.uuidString) }
            if current.updatedHLC <= stamp.time {
                merged.updatedHLC = stamp.time
                merged.updatedAt = date
            }
            merged = try resolvingAssetAliases(in: merged)
            try put(merged)
            try setState(key, clocks)
            try markProjection("boards", id: delta.id)
        case .folder(var folder):
            let key = "clock.folder." + folder.id.uuidString
            var clocks: SyncClocks = try state(key) ?? SyncClocks()
            guard !clocks.deleted, clocks.accept(stamp, key: "value") else { return }
            let current = try self.folder(id: folder.id)
            if folder.driveFolderID?.hasPrefix("mounted-") == true { folder.driveFolderID = current?.driveFolderID }
            if folder.driveFolderID == nil { folder.driveFolderID = current?.driveFolderID }
            folder.assetCount = 0
            try put(folder)
            try setState(key, clocks)
        case .deleteAsset(let id, let driveID):
            let existingAsset = try asset(id: id)
            let knownID = existingAsset?.driveFileID ?? driveID
            if let knownID { try setState("deleted.drive." + knownID, true) }
            if let existingAsset, !existingAsset.contentHash.isEmpty {
                let fp = DeletedAssetFingerprint(
                    assetID: id,
                    sha256: existingAsset.contentHash,
                    md5: nil,
                    fileName: existingAsset.fileName,
                    deletedAt: Date()
                )
                try setState("deleted.content." + existingAsset.contentHash, fp)
            }
            try tombstone("asset", id: id, stamp: stamp)
            try removeAsset(id)
            try setState("media.cleanup." + id.uuidString, true)
            try setState("deferred.vector." + id.uuidString, Optional<[SyncOperation]>.none)
            try markProjection("thumbnails", id: id)
            try markProjection("embeddings", id: id)
        case .deleteBoard(let id):
            try tombstone("board", id: id, stamp: stamp)
            try removeBoard(id)
            try markProjection("boards", id: id)
        case .deleteFolder(let id, _):
            try tombstone("folder", id: id, stamp: stamp)
            try removeFolder(id)
        case .vector(let id, let vector):
            let key = "clock.vector." + id.uuidString
            var clocks: SyncClocks = try state(key) ?? SyncClocks()
            guard try asset(id: id) != nil else {
                if try !isTombstoned("asset", id: id) { try storeDeferredVector(vector, id: id, stamp: stamp) }
                return
            }
            let feature = vector.featurePrint.flatMap { clocks.accept(stamp, key: "feature") ? $0 : nil }
            let embedding = vector.embedding.flatMap { clocks.accept(stamp, key: "embedding") ? $0 : nil }
            if feature != nil || embedding != nil {
                try saveVector(AssetVector(featurePrint: feature, embedding: embedding, embeddingModel: vector.embeddingModel,
                                           precision: vector.precision), for: id)
                try setState(key, clocks)
                try markProjection("embeddings", id: id)
            }
        }
        if case .asset(let delta) = op.change {
            let key = "deferred.vector." + delta.id.uuidString
            if let operations: [SyncOperation] = try state(key) {
                for operation in operations { try apply(operation) }
                try setState(key, Optional<[SyncOperation]>.none)
            }
        }
    }

    private func storeDeferredVector(_ vector: AssetVector, id: UUID, stamp: SyncStamp) throws {
        let key = "deferred.vector." + id.uuidString
        var pending: [SyncOperation] = try state(key) ?? []
        pending.removeAll {
            guard $0.stamp <= stamp, case .vector(_, let prior) = $0.change else { return false }
            return (prior.embedding == nil || vector.embedding != nil) && (prior.featurePrint == nil || vector.featurePrint != nil)
        }
        pending.append(SyncOperation(stamp: stamp, change: .vector(id, vector)))
        try setState(key, pending)
    }

    func markProjection(_ name: String, id: UUID) throws {
        var dirty: [String: String] = try state("projection." + name) ?? [:]
        dirty[id.uuidString] = UUID().uuidString
        try setState("projection." + name, dirty)
    }

    func clearProjection(_ name: String, id: String, ifVersion version: String) throws {
        var dirty: [String: String] = try state("projection." + name) ?? [:]
        if dirty[id] == version { dirty.removeValue(forKey: id); try setState("projection." + name, dirty) }
    }

    func isTombstoned(_ entity: String, id: UUID) throws -> Bool {
        try state("clock." + entity + "." + id.uuidString, as: SyncClocks.self)?.deleted == true
    }

    private func tombstone(_ entity: String, id: UUID, stamp: SyncStamp) throws {
        let key = "clock." + entity + "." + id.uuidString
        var clocks: SyncClocks = try state(key) ?? SyncClocks()
        if clocks.accept(stamp, key: "deleted") { try setState(key, clocks) }
    }

    private func remapDiscoveredAsset(_ asset: AssetRecord, to id: UUID) throws {
        try setState("alias.asset." + asset.id.uuidString, id)
        for board in try fetchBoards() where board.referencedAssetIDs.contains(asset.id) || board.candidateAssetIDs.contains(asset.id) {
            try put(resolvingAssetAliases(in: board))
            try markProjection("boards", id: board.id)
        }
        try removeAsset(asset.id)
        try setState("media.cleanup." + asset.id.uuidString, true)
    }

    private func resolvingAssetAliases(in document: MoodboardDocument) throws -> MoodboardDocument {
        var board = document
        for index in board.nodes.indices {
            if case .assetRef(let id, let crop, let weight, let loop) = board.nodes[index].kind,
               let canonical: UUID = try state("alias.asset." + id.uuidString) {
                board.nodes[index].kind = .assetRef(assetID: canonical, crop: crop, weight: weight, autoplayLoop: loop)
            }
        }
        board.candidateAssetIDs = try board.candidateAssetIDs.map { id in
            try state("alias.asset." + id.uuidString, as: UUID.self) ?? id
        }
        return board
    }

    func removeDeletedMedia(using media: MediaPipeline) throws {
        let removals = try states(withPrefix: "media.cleanup.", as: Bool.self)
        guard !removals.isEmpty else { return }
        let ids = Set(removals.compactMap { key, _ in UUID(uuidString: String(key.dropFirst("media.cleanup.".count))) })
        try media.removeFiles(forIDs: ids)
        for (key, _) in removals { try setState(key, Optional<Bool>.none) }
    }
}
