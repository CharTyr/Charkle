import Foundation

public final actor LibraryDatabase {
    private final class CachedAssetBox: NSObject {
        let record: AssetRecord
        init(_ record: AssetRecord) { self.record = record }
    }

    private let connection: SQLiteConnection
    private let isMemoryDatabase: Bool
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()
    private let assetCache: NSCache<NSString, CachedAssetBox>
    private var hasWarmAssetCache = false
    private var cachedFolderChildren: [UUID: [UUID]]?
    private var lastDataVersion: Int64 = 0
    private var transactionDepth = 0

    public init(path: String = ":memory:") throws {
        let connection = try SQLiteConnection(path: path)
        let isMemory = (path == ":memory:")
        try connection.script("PRAGMA foreign_keys = ON; PRAGMA synchronous = NORMAL; PRAGMA temp_store = MEMORY; PRAGMA journal_size_limit = 16777216;")
        if !isMemory {
            let journalMode = (try? connection.query("PRAGMA journal_mode") { $0.text(0) }.first)?.lowercased()
            if journalMode != "wal" {
                try connection.script("PRAGMA journal_mode = WAL;")
            }
            try? connection.script("PRAGMA mmap_size = 33554432; PRAGMA cache_size = -2000;")
        }
        let initialVersion = try connection.query("PRAGMA user_version") { $0.integer(0) }.first ?? 0
        guard initialVersion <= Self.schemaVersion else {
            throw LibraryDatabaseError("Library schema \(initialVersion) requires a newer version of Charkle.")
        }
        if initialVersion < Self.schemaVersion {
            try connection.script("BEGIN IMMEDIATE")
            do {
                let version = try connection.query("PRAGMA user_version") { $0.integer(0) }.first ?? 0
                guard version <= Self.schemaVersion else {
                    throw LibraryDatabaseError("Library schema \(version) requires a newer version of Charkle.")
                }
                if version == 0 { try connection.script(Self.initialSchema) }
                if version < 2 {
                    try connection.script("""
                        CREATE INDEX IF NOT EXISTS assets_hash ON assets(content_hash) WHERE content_hash <> '';
                        PRAGMA user_version = 2;
                        """)
                }
                if version < 3 {
                    try connection.script("""
                        CREATE INDEX IF NOT EXISTS assets_folder_recency ON assets(trashed, folder_id, created DESC);
                        CREATE INDEX IF NOT EXISTS assets_kind_recency ON assets(trashed, kind, created DESC);
                        CREATE INDEX IF NOT EXISTS assets_pinned ON assets(id) WHERE pinned = 1;
                        CREATE INDEX IF NOT EXISTS asset_colors_lab ON asset_colors(l, a, b, asset_id);
                        PRAGMA user_version = 3;
                        """)
                }
                try connection.script("COMMIT")
            } catch {
                try? connection.script("ROLLBACK")
                throw error
            }
            connection.clearStatementCache()
        }
        let cache = NSCache<NSString, CachedAssetBox>()
        cache.countLimit = 4_000
        cache.totalCostLimit = 8 * 1024 * 1024
        self.assetCache = cache
        self.isMemoryDatabase = isMemory
        self.connection = connection
        if !isMemory {
            self.lastDataVersion = (try? connection.query("PRAGMA data_version") { $0.integer(0) }.first) ?? 0
        }
    }

    public init(url: URL) throws { try self.init(path: url.path) }

    private static let schemaVersion = 3

    private static let initialSchema = """
        CREATE TABLE assets (
            id TEXT PRIMARY KEY, drive_id TEXT UNIQUE, content_hash TEXT NOT NULL,
            folder_id TEXT, kind TEXT NOT NULL, shape TEXT NOT NULL, title TEXT NOT NULL,
            rating INTEGER NOT NULL, size INTEGER NOT NULL, created REAL NOT NULL,
            pinned INTEGER NOT NULL, trashed INTEGER NOT NULL, payload BLOB NOT NULL
        );
        CREATE INDEX assets_folder ON assets(folder_id, trashed);
        CREATE INDEX assets_recency ON assets(trashed, created DESC);
        CREATE VIRTUAL TABLE assets_fts USING fts5(
            title, fileName, notes, tags, ocrText, aiDescription, sourceDomain, pinyin, initials,
            tokenize='unicode61 remove_diacritics 2', prefix='2 3 4'
        );
        CREATE TABLE asset_tags (
            asset_id TEXT REFERENCES assets(id) ON DELETE CASCADE,
            tag TEXT NOT NULL COLLATE NOCASE, PRIMARY KEY(asset_id, tag)
        );
        CREATE INDEX asset_tags_lookup ON asset_tags(tag, asset_id);
        CREATE TABLE asset_colors (
            asset_id TEXT REFERENCES assets(id) ON DELETE CASCADE,
            l REAL NOT NULL, a REAL NOT NULL, b REAL NOT NULL
        );
        CREATE INDEX asset_colors_asset ON asset_colors(asset_id);
        CREATE TABLE asset_vectors (
            asset_id TEXT PRIMARY KEY REFERENCES assets(id) ON DELETE CASCADE,
            feature_print BLOB, embedding BLOB, precision INTEGER, embedding_model TEXT
        );
        CREATE TABLE folders (id TEXT PRIMARY KEY, drive_id TEXT, payload BLOB NOT NULL);
        CREATE TABLE boards (id TEXT PRIMARY KEY, pinned INTEGER NOT NULL, payload BLOB NOT NULL);
        CREATE TABLE board_assets (
            board_id TEXT REFERENCES boards(id) ON DELETE CASCADE,
            asset_id TEXT NOT NULL, PRIMARY KEY(board_id, asset_id)
        );
        CREATE TABLE sync_ops (seq INTEGER PRIMARY KEY AUTOINCREMENT, payload BLOB NOT NULL);
        CREATE TABLE sync_state (key TEXT PRIMARY KEY, payload BLOB NOT NULL);
        CREATE TABLE original_cache (
            asset_id TEXT PRIMARY KEY REFERENCES assets(id) ON DELETE CASCADE,
            accessed_at REAL NOT NULL
        );
        PRAGMA user_version = 1;
        """

    private func invalidateCaches() {
        assetCache.removeAllObjects()
        hasWarmAssetCache = false
        cachedFolderChildren = nil
    }

    private func syncExternalDataVersionIfNeeded() {
        guard !isMemoryDatabase, transactionDepth == 0 else { return }
        if let current = try? connection.query("PRAGMA data_version", read: { $0.integer(0) }).first,
           current != lastDataVersion {
            invalidateCaches()
            lastDataVersion = current
        }
    }

    func transaction<T: Sendable>(_ work: @Sendable (isolated LibraryDatabase) throws -> T) throws -> T {
        try connection.script("BEGIN IMMEDIATE")
        syncExternalDataVersionIfNeeded()
        transactionDepth += 1
        do {
            let result = try work(self)
            try connection.script("COMMIT")
            transactionDepth -= 1
            return result
        } catch {
            try? connection.script("ROLLBACK")
            transactionDepth -= 1
            invalidateCaches()
            throw error
        }
    }

    public func upsertAssets(_ assets: [AssetRecord]) throws {
        try transaction { db in
            for asset in assets { try db.put(asset) }
        }
    }

    func put(_ asset: AssetRecord) throws {
        syncExternalDataVersionIfNeeded()
        let id = asset.id.uuidString
        let old = try self.asset(id: asset.id)
        let encodedPayload: Data = try autoreleasepool { try encoder.encode(asset) }
        try connection.execute("""
            INSERT INTO assets VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
            ON CONFLICT(id) DO UPDATE SET drive_id=excluded.drive_id, content_hash=excluded.content_hash,
                folder_id=excluded.folder_id, kind=excluded.kind, shape=excluded.shape, title=excluded.title,
                rating=excluded.rating, size=excluded.size, created=excluded.created, pinned=excluded.pinned,
                trashed=excluded.trashed, payload=excluded.payload
            """, [.text(id), SQLValue(asset.driveFileID), .text(asset.contentHash),
                  SQLValue(asset.folderID?.uuidString), .text(asset.mediaKind.rawValue), .text(asset.aspectShape.rawValue),
                  .text(asset.title), .integer(Int64(asset.rating)), .integer(asset.fileSizeBytes),
                  .real(asset.createdAt.timeIntervalSince1970), .integer(asset.pinnedOffline ? 1 : 0),
                  .integer(asset.isTrashed ? 1 : 0), .blob(encodedPayload)])

        if old?.tags != asset.tags {
            try connection.execute("DELETE FROM asset_tags WHERE asset_id=?", [.text(id)])
            for tag in asset.tags where !tag.isEmpty {
                try connection.execute("INSERT OR IGNORE INTO asset_tags VALUES (?, ?)", [.text(id), .text(tag)])
            }
        }
        if old?.dominantColors != asset.dominantColors {
            try connection.execute("DELETE FROM asset_colors WHERE asset_id=?", [.text(id)])
            for color in asset.dominantColors where color.l.isFinite && color.a.isFinite && color.b.isFinite {
                try connection.execute("INSERT INTO asset_colors VALUES (?, ?, ?, ?)", [.text(id), .real(color.l), .real(color.a), .real(color.b)])
            }
        }
        let fields = Self.searchFields(asset)
        if old.map(Self.searchFields) != fields {
            let rowID = try connection.query("SELECT rowid FROM assets WHERE id=?", [.text(id)]) { $0.integer(0) }[0]
            let tokens: [String] = autoreleasepool {
                let pinyin = fields.map(SearchText.pinyin)
                return fields.map(SearchText.index) + [
                    pinyin.map(\.full).joined(separator: " "), pinyin.map(\.initials).joined(separator: " ")
                ]
            }
            if old != nil { try connection.execute("DELETE FROM assets_fts WHERE rowid=?", [.integer(rowID)]) }
            try connection.execute(
                "INSERT INTO assets_fts(rowid,title,fileName,notes,tags,ocrText,aiDescription,sourceDomain,pinyin,initials) VALUES (?,?,?,?,?,?,?,?,?,?)",
                [.integer(rowID)] + tokens.map(SQLValue.text)
            )
        }
        assetCache.setObject(CachedAssetBox(asset), forKey: id as NSString, cost: max(256, encodedPayload.count))
        hasWarmAssetCache = true
    }

    private static func searchFields(_ asset: AssetRecord) -> [String] {
        var extraOCR = asset.ocrText ?? ""
        if let repo = asset.richMetadata?.githubRepo {
            let repoText = [
                repo.fullName,
                repo.description ?? "",
                repo.language ?? "",
                repo.topics.joined(separator: " "),
                String((repo.readmeMarkdown ?? "").prefix(4000))
            ].filter { !$0.isEmpty }.joined(separator: "\n")
            if !repoText.isEmpty {
                extraOCR = extraOCR.isEmpty ? repoText : (extraOCR + "\n" + repoText)
            }
        }
        if let post = asset.richMetadata?.socialPost {
            let postText = [
                post.platform.displayName,
                post.authorName,
                "@\(post.authorHandle)",
                post.articleTitle ?? "",
                post.bodyText,
                post.quotedText ?? ""
            ].filter { !$0.isEmpty }.joined(separator: "\n")
            if !postText.isEmpty {
                extraOCR = extraOCR.isEmpty ? postText : (extraOCR + "\n" + postText)
            }
        }
        if let exif = asset.richMetadata?.photoExif {
            let exifText = [
                exif.cameraDisplayName ?? "",
                exif.lensModel ?? "",
                exif.exposureSummary ?? "",
                exif.software ?? "",
                exif.artist ?? ""
            ].filter { !$0.isEmpty }.joined(separator: " ")
            if !exifText.isEmpty {
                extraOCR = extraOCR.isEmpty ? exifText : (extraOCR + "\n" + exifText)
            }
        }
        if let ai = asset.richMetadata?.aiGeneration {
            let aiText = [
                ai.generator ?? "",
                ai.modelName ?? "",
                ai.sampler ?? "",
                ai.loras.joined(separator: " "),
                String((ai.prompt ?? "").prefix(2000)),
                String((ai.negativePrompt ?? "").prefix(600))
            ].filter { !$0.isEmpty }.joined(separator: "\n")
            if !aiText.isEmpty {
                extraOCR = extraOCR.isEmpty ? aiText : (extraOCR + "\n" + aiText)
            }
        }
        return [asset.title, asset.fileName, asset.notes, asset.tags.joined(separator: " "),
                extraOCR, asset.aiDescription ?? "", asset.sourceDomain ?? ""]
    }

    public func asset(id: UUID) throws -> AssetRecord? {
        syncExternalDataVersionIfNeeded()
        let key = id.uuidString
        if let hit = assetCache.object(forKey: key as NSString) {
            return hit.record
        }
        let rows = try connection.query("SELECT payload FROM assets WHERE id=?", [.text(key)]) { row -> (AssetRecord, Int) in
            try decodeWithSize(AssetRecord.self, row)
        }
        guard let (record, size) = rows.first else { return nil }
        assetCache.setObject(CachedAssetBox(record), forKey: key as NSString, cost: max(256, size))
        hasWarmAssetCache = true
        return record
    }

    func assetExists(id: UUID) throws -> Bool {
        syncExternalDataVersionIfNeeded()
        let key = id.uuidString
        if assetCache.object(forKey: key as NSString) != nil {
            return true
        }
        return try !connection.query("SELECT 1 FROM assets WHERE id=? LIMIT 1", [.text(key)]) { $0.integer(0) }.isEmpty
    }

    func existingAssetIDs() throws -> Set<UUID> {
        let ids = try connection.query("SELECT id FROM assets") { UUID(uuidString: $0.text(0)) }
        var set = Set<UUID>()
        set.reserveCapacity(ids.count)
        for id in ids {
            if let id { set.insert(id) }
        }
        return set
    }

    /// Sub-millisecond primary-key range scan resolving an uppercase UUID prefix (8+ chars) to matching asset UUIDs.
    public func assetIDs(matchingPrefix prefix: String, limit: Int = 5) throws -> [UUID] {
        syncExternalDataVersionIfNeeded()
        let upper = prefix.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        guard upper.count >= 8 else { return [] }
        return try connection.query(
            "SELECT id FROM assets WHERE id >= ? AND id < ? LIMIT ?",
            [.text(upper), .text(upper + "\u{FFFF}"), .integer(Int64(max(1, limit)))]
        ) { UUID(uuidString: $0.text(0)) }.compactMap { $0 }
    }

    /// Lightweight SQLite projection returning `(assetID -> created)` without decoding JSON payloads,
    /// enabling thumbnail sync to prioritize newest / first-screen gallery cards first.
    func assetCreatedAtByID() throws -> [UUID: Double] {
        let rows = try connection.query("SELECT id, created FROM assets") { row in
            (UUID(uuidString: row.text(0)), row.real(1))
        }
        var map: [UUID: Double] = [:]
        map.reserveCapacity(rows.count)
        for (id, createdAt) in rows {
            if let id { map[id] = createdAt }
        }
        return map
    }

    func assetsWithPayloadContaining(_ literal: String, includeTrashed: Bool = true) throws -> [AssetRecord] {
        syncExternalDataVersionIfNeeded()
        let sql = includeTrashed
            ? "SELECT id FROM assets WHERE instr(CAST(payload AS TEXT), ?) > 0"
            : "SELECT id FROM assets WHERE trashed=0 AND instr(CAST(payload AS TEXT), ?) > 0"
        let ids = try connection.query(sql, [.text(literal)]) { $0.text(0) }
        return try hydrateAssets(forOrderedIDs: ids)
    }

    func asset(driveID: String) throws -> AssetRecord? {
        syncExternalDataVersionIfNeeded()
        return try asset(where: "drive_id=?", equals: driveID)
    }

    func assetDriveBindings() throws -> [(String, UUID)] {
        try connection.query("SELECT drive_id,id FROM assets WHERE drive_id IS NOT NULL") { row in
            (row.text(0), UUID(uuidString: row.text(1)))
        }.compactMap { driveID, id in id.map { (driveID, $0) } }
    }

    func assets(contentHash: String) throws -> [AssetRecord] {
        syncExternalDataVersionIfNeeded()
        let ids = try connection.query("SELECT id FROM assets WHERE content_hash=?", [.text(contentHash)]) { $0.text(0) }
        return try hydrateAssets(forOrderedIDs: ids)
    }

    private func asset(where clause: String, equals value: String) throws -> AssetRecord? {
        try connection.query("SELECT id, payload FROM assets WHERE \(clause)", [.text(value)]) { row -> AssetRecord in
            let id = row.text(0)
            if let hit = assetCache.object(forKey: id as NSString) {
                return hit.record
            }
            let (record, size) = try decodeWithSize(AssetRecord.self, row, column: 1)
            assetCache.setObject(CachedAssetBox(record), forKey: id as NSString, cost: max(256, size))
            hasWarmAssetCache = true
            return record
        }.first
    }

    func removeAsset(_ id: UUID) throws {
        syncExternalDataVersionIfNeeded()
        let key = id.uuidString
        let parameters: [SQLValue] = [.text(key)]
        try connection.execute("DELETE FROM assets_fts WHERE rowid IN (SELECT rowid FROM assets WHERE id=?)", parameters)
        try connection.execute("DELETE FROM assets WHERE id=?", parameters)
        assetCache.removeObject(forKey: key as NSString)
    }

    public func fetchAssets(matching criteria: FilterCriteria, limit: Int? = nil) throws -> [AssetRecord] {
        syncExternalDataVersionIfNeeded()
        if hasWarmAssetCache {
            let ids = try assetQuery(criteria, limit: limit, projection: "a.id") { $0.text(0) }
            return try hydrateAssets(forOrderedIDs: ids)
        }
        let decoded = try assetQuery(criteria, limit: limit, projection: "a.id, a.payload") { row -> AssetRecord in
            let id = row.text(0)
            let (record, size) = try decodeWithSize(AssetRecord.self, row, column: 1)
            assetCache.setObject(CachedAssetBox(record), forKey: id as NSString, cost: max(256, size))
            return record
        }
        if !decoded.isEmpty {
            hasWarmAssetCache = true
        }
        return decoded
    }

    private func hydrateAssets(forOrderedIDs ids: [String]) throws -> [AssetRecord] {
        guard !ids.isEmpty else { return [] }
        var resolved: [AssetRecord?] = Array(repeating: nil, count: ids.count)
        var missingIndicesByID: [String: [Int]] = [:]
        var missingUniqueIDs: [String] = []
        for (idx, id) in ids.enumerated() {
            if let hit = assetCache.object(forKey: id as NSString) {
                resolved[idx] = hit.record
            } else {
                if missingIndicesByID[id] == nil {
                    missingUniqueIDs.append(id)
                }
                missingIndicesByID[id, default: []].append(idx)
            }
        }
        if !missingUniqueIDs.isEmpty {
            let chunkSize = 400
            for start in stride(from: 0, to: missingUniqueIDs.count, by: chunkSize) {
                let slice = missingUniqueIDs[start..<min(missingUniqueIDs.count, start + chunkSize)]
                let sql = "SELECT id, payload FROM assets WHERE id IN (\(Self.placeholders(slice.count)))"
                let args = slice.map(SQLValue.text)
                let rows = try connection.query(sql, args, cacheStatement: slice.count <= 4) { row -> (String, AssetRecord, Int) in
                    let id = row.text(0)
                    let (record, size) = try decodeWithSize(AssetRecord.self, row, column: 1)
                    return (id, record, size)
                }
                for (id, record, size) in rows {
                    assetCache.setObject(CachedAssetBox(record), forKey: id as NSString, cost: max(256, size))
                    if let positions = missingIndicesByID[id] {
                        for pos in positions {
                            resolved[pos] = record
                        }
                    }
                }
            }
            hasWarmAssetCache = true
        }
        var out: [AssetRecord] = []
        out.reserveCapacity(ids.count)
        for item in resolved {
            if let item { out.append(item) }
        }
        return out
    }

    func searchRanks(_ query: String) throws -> [UUID: Double] {
        guard !SearchText.ftsQuery(query).isEmpty else { return [:] }
        let criteria = FilterCriteria(searchQuery: query, sortBy: .relevance)
        let matches = try assetQuery(criteria, projection: "a.id") { UUID(uuidString: $0.text(0)) }.compactMap { $0 }
        return Dictionary(uniqueKeysWithValues: matches.enumerated().map {
            ($0.element, 1 / (1 + Double($0.offset) / Double(max(8, matches.count / 4))))
        })
    }

    private func folderChildrenMap() throws -> [UUID: [UUID]] {
        syncExternalDataVersionIfNeeded()
        if let cached = cachedFolderChildren {
            return cached
        }
        let rows = try connection.query(
            "SELECT id, json_extract(CAST(payload AS TEXT), '$.parentID') FROM folders"
        ) { row -> (UUID?, UUID?) in
            let id = UUID(uuidString: row.text(0))
            let parentText = row.text(1)
            let parentID = parentText.isEmpty ? nil : UUID(uuidString: parentText)
            return (id, parentID)
        }
        var childrenByParent: [UUID: [UUID]] = [:]
        for (id, parentID) in rows {
            if let id, let parentID {
                childrenByParent[parentID, default: []].append(id)
            }
        }
        cachedFolderChildren = childrenByParent
        return childrenByParent
    }

    private func folderSubtreeIDs(rootID: UUID) throws -> [UUID] {
        let childrenByParent = try folderChildrenMap()
        var result: [UUID] = [rootID]
        var seen: Set<UUID> = [rootID]
        var queue: [UUID] = [rootID]
        while let current = queue.popLast() {
            for childID in childrenByParent[current] ?? [] where seen.insert(childID).inserted {
                result.append(childID)
                queue.append(childID)
            }
        }
        return result
    }

    private func assetQuery<T>(
        _ filters: FilterCriteria, limit: Int? = nil, projection: String = "a.payload", read: (SQLRow) throws -> T
    ) throws -> [T] {
        var clauses: [String] = []
        var args: [SQLValue] = []
        var hasDynamicList = false
        func constrain(_ predicate: String, _ values: SQLValue...) {
            clauses.append(predicate)
            args.append(contentsOf: values)
        }

        if filters.onlyTrashed { constrain("a.trashed=1") }
        else if !filters.includeTrashed { constrain("a.trashed=0") }
        if filters.onlyInbox { constrain("a.folder_id IS NULL AND a.trashed=0") }
        if let folder = filters.folderID {
            if filters.includeSubfolders {
                let subtreeIDs = try folderSubtreeIDs(rootID: folder)
                if subtreeIDs.count == 1 {
                    constrain("a.folder_id=?", .text(subtreeIDs[0].uuidString))
                } else {
                    if subtreeIDs.count > 4 { hasDynamicList = true }
                    clauses.append("a.folder_id IN (\(Self.placeholders(subtreeIDs.count)))")
                    args += subtreeIDs.map { SQLValue.text($0.uuidString) }
                }
            } else {
                constrain("a.folder_id=?", .text(folder.uuidString))
            }
        }
        if let shape = filters.shape { constrain("a.shape=?", .text(shape.rawValue)) }
        if filters.minRating > 0 { constrain("a.rating>=?", .integer(Int64(filters.minRating))) }
        if filters.onlyPinnedOffline { constrain("a.pinned=1") }
        if let days = filters.onlyRecentDays {
            constrain("a.created>=?", .real(Date().timeIntervalSince1970 - Double(max(0, days)) * 86_400))
        }
        if !filters.kinds.isEmpty {
            let kinds = filters.kinds.map(\.rawValue).sorted()
            if kinds.count == 1 {
                constrain("a.kind=?", .text(kinds[0]))
            } else {
                if kinds.count > 4 { hasDynamicList = true }
                clauses.append("a.kind IN (\(Self.placeholders(kinds.count)))")
                args += kinds.map(SQLValue.text)
            }
        }
        if filters.onlyUntagged { constrain("NOT EXISTS (SELECT 1 FROM asset_tags WHERE asset_id=a.id)") }
        for tag in filters.tags.sorted() {
            constrain("EXISTS (SELECT 1 FROM asset_tags WHERE asset_id=a.id AND tag=?)", .text(tag))
        }
        if let hex = filters.selectedColorHex {
            let color = LabColor.fromHex(hex)
            let tolerance = max(0, filters.colorTolerance)
            let tolSq = tolerance * tolerance
            constrain("""
                a.id IN (SELECT c.asset_id FROM asset_colors c
                    WHERE c.l BETWEEN ? AND ? AND c.a BETWEEN ? AND ? AND c.b BETWEEN ? AND ?
                      AND (c.l-?)*(c.l-?)+(c.a-?)*(c.a-?)+(c.b-?)*(c.b-?)<=?)
                """,
                .real(color.l - tolerance), .real(color.l + tolerance),
                .real(color.a - tolerance), .real(color.a + tolerance),
                .real(color.b - tolerance), .real(color.b + tolerance),
                .real(color.l), .real(color.l),
                .real(color.a), .real(color.a),
                .real(color.b), .real(color.b),
                .real(tolSq)
            )
        }
        let trimmedSearch = filters.searchQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        let query = SearchText.ftsQuery(trimmedSearch)
        if !query.isEmpty {
            constrain("assets_fts MATCH ?", .text(query))
        } else if !trimmedSearch.isEmpty {
            // Emoji / punctuation / symbol-only search terms have no FTS5 tokens; fall back to
            // literal substring matching against user-facing fields instead of returning every asset.
            let escaped = trimmedSearch
                .replacingOccurrences(of: "\\", with: "\\\\")
                .replacingOccurrences(of: "%", with: "\\%")
                .replacingOccurrences(of: "_", with: "\\_")
            let pattern = SQLValue.text("%\(escaped)%")
            constrain("""
                (a.title LIKE ? ESCAPE '\\'
                 OR COALESCE(json_extract(CAST(a.payload AS TEXT), '$.notes'), '') LIKE ? ESCAPE '\\'
                 OR COALESCE(json_extract(CAST(a.payload AS TEXT), '$.fileName'), '') LIKE ? ESCAPE '\\'
                 OR COALESCE(json_extract(CAST(a.payload AS TEXT), '$.ocrText'), '') LIKE ? ESCAPE '\\'
                 OR COALESCE(json_extract(CAST(a.payload AS TEXT), '$.aiDescription'), '') LIKE ? ESCAPE '\\'
                 OR EXISTS (SELECT 1 FROM asset_tags t WHERE t.asset_id=a.id AND t.tag LIKE ? ESCAPE '\\'))
                """, pattern, pattern, pattern, pattern, pattern, pattern)
        }
        let source = query.isEmpty ? "assets a" : "assets_fts JOIN assets a ON a.rowid=assets_fts.rowid"
        let order = switch filters.sortBy {
        case .newest: "a.created DESC"
        case .oldest: "a.created"
        case .nameAsc: "a.title COLLATE NOCASE"
        case .ratingDesc: "a.rating DESC, a.created DESC"
        case .fileSizeDesc: "a.size DESC, a.created DESC"
        case .relevance:
            query.isEmpty ? "a.created DESC" : "bm25(assets_fts, 8, 3, 1, 5, 2, 2, 1, 3, 2), a.created DESC"
        }
        let filter = clauses.isEmpty ? "" : " WHERE " + clauses.joined(separator: " AND ")
        let page: String
        if let limit {
            page = " LIMIT ?"
            args.append(.integer(Int64(max(0, limit))))
        } else {
            page = ""
        }
        return try connection.query(
            "SELECT \(projection) FROM \(source)\(filter) ORDER BY \(order), a.id\(page)",
            args,
            cacheStatement: !hasDynamicList,
            read: read
        )
    }

    private static func placeholders(_ count: Int) -> String {
        Array(repeating: "?", count: count).joined(separator: ",")
    }

    public func fetchFolders() throws -> [FolderRecord] {
        var countsByFolderID: [String: Int] = [:]
        _ = try connection.query("""
            SELECT folder_id, COUNT(*)
            FROM assets
            WHERE trashed = 0 AND folder_id IS NOT NULL
            GROUP BY folder_id
            """) { row in
            countsByFolderID[row.text(0)] = Int(row.integer(1))
        }
        return try connection.query("SELECT id, payload FROM folders") { row in
            let id = row.text(0)
            var folder = try decode(FolderRecord.self, row, column: 1)
            folder.assetCount = countsByFolderID[id] ?? 0
            return folder
        }.sorted { ($0.sortOrder, $0.name, $0.id.uuidString) < ($1.sortOrder, $1.name, $1.id.uuidString) }
    }

    public func folder(id: UUID) throws -> FolderRecord? {
        try connection.query("SELECT payload FROM folders WHERE id=?", [.text(id.uuidString)]) {
            try decode(FolderRecord.self, $0)
        }.first
    }

    public func upsertFolder(_ folder: FolderRecord) throws { try put(folder) }

    func put(_ folder: FolderRecord) throws {
        syncExternalDataVersionIfNeeded()
        try connection.execute("""
            INSERT INTO folders VALUES (?,?,?) ON CONFLICT(id) DO UPDATE SET drive_id=excluded.drive_id, payload=excluded.payload
            """, [.text(folder.id.uuidString), SQLValue(folder.driveFolderID), .blob(try encoder.encode(folder))])
        cachedFolderChildren = nil
    }

    func removeFolder(_ id: UUID) throws {
        syncExternalDataVersionIfNeeded()
        try connection.execute("DELETE FROM folders WHERE id=?", [.text(id.uuidString)])
        cachedFolderChildren = nil
    }

    public func fetchTagCounts() throws -> [TagCount] {
        let rows = try connection.query("""
            SELECT tag, COUNT(*) n FROM asset_tags t JOIN assets a ON t.asset_id=a.id
            WHERE a.trashed=0 GROUP BY tag ORDER BY n DESC, tag
            """) { TagCount(name: $0.text(0), count: Int($0.integer(1))) }
        // SQLite COLLATE NOCASE only folds ASCII A-Z; merge non-ASCII case variants (e.g. "Über"/"über")
        // so downstream lowercased dictionaries never collide on duplicate keys.
        var merged: [String: (name: String, bestCount: Int, total: Int)] = [:]
        var keyOrder: [String] = []
        for row in rows {
            let key = row.name.lowercased()
            if var existing = merged[key] {
                existing.total += row.count
                if row.count > existing.bestCount {
                    existing.name = row.name
                    existing.bestCount = row.count
                }
                merged[key] = existing
            } else {
                merged[key] = (row.name, row.count, row.count)
                keyOrder.append(key)
            }
        }
        return keyOrder.compactMap { merged[$0] }
            .map { TagCount(name: $0.name, count: $0.total) }
            .sorted { lhs, rhs in
                if lhs.count != rhs.count { return lhs.count > rhs.count }
                return lhs.name.localizedCaseInsensitiveCompare(rhs.name) == .orderedAscending
            }
    }

    public func inboxCount() throws -> Int {
        Int(try connection.query("SELECT COUNT(*) FROM assets WHERE folder_id IS NULL AND trashed=0") {
            $0.integer(0)
        }.first ?? 0)
    }

    func isEmpty() throws -> Bool {
        try connection.query("SELECT 1 FROM assets UNION ALL SELECT 1 FROM boards UNION ALL SELECT 1 FROM folders LIMIT 1") {
            $0.integer(0)
        }.isEmpty
    }

    public func fetchBoards() throws -> [MoodboardDocument] {
        try connection.query("SELECT payload FROM boards") { try decode(MoodboardDocument.self, $0) }
            .sorted { ($0.updatedAt, $0.id.uuidString) > ($1.updatedAt, $1.id.uuidString) }
    }

    public func board(id: UUID) throws -> MoodboardDocument? {
        try connection.query("SELECT payload FROM boards WHERE id=?", [.text(id.uuidString)]) {
            try decode(MoodboardDocument.self, $0)
        }.first
    }

    public func upsertBoard(_ board: MoodboardDocument) throws {
        try transaction { db in try db.put(board) }
    }

    func put(_ board: MoodboardDocument) throws {
        let id = SQLValue.text(board.id.uuidString)
        try connection.execute("""
            INSERT INTO boards VALUES (?,?,?) ON CONFLICT(id) DO UPDATE SET pinned=excluded.pinned, payload=excluded.payload
            """, [id, .integer(board.pinnedOffline ? 1 : 0), .blob(try encoder.encode(board))])
        try connection.execute("DELETE FROM board_assets WHERE board_id=?", [id])
        for asset in Set(board.referencedAssetIDs) {
            try connection.execute("INSERT INTO board_assets VALUES (?,?)", [id, .text(asset.uuidString)])
        }
    }

    func removeBoard(_ id: UUID) throws {
        try connection.execute("DELETE FROM boards WHERE id=?", [.text(id.uuidString)])
    }

    func protectedAssetIDs() throws -> Set<UUID> {
        try Set(connection.query("""
            SELECT id FROM assets WHERE pinned=1
            UNION SELECT asset_id FROM board_assets a JOIN boards b ON a.board_id=b.id WHERE b.pinned=1
            """) { UUID(uuidString: $0.text(0)) }.compactMap { $0 })
    }

    public func quickJump(query: String, limit: Int) throws -> [QuickJumpMatch] {
        guard limit > 0 else { return [] }
        let normalizedQuery = SearchText.normalize(query)
        var matches: [QuickJumpMatch] = []
        func add(_ title: String, _ kind: QuickJumpKind, _ subtitle: String, _ uuid: UUID?, _ tag: String? = nil) {
            guard let score = SearchText.fuzzyScore(normalizedQuery: normalizedQuery, candidate: title) else { return }
            matches.append(QuickJumpMatch(id: kind.rawValue + "-" + (uuid?.uuidString ?? title), kind: kind,
                                          title: title, subtitle: subtitle, targetUUID: uuid, tagName: tag, score: score))
        }
        let boardRows = try connection.query("""
            SELECT id,
                   COALESCE(json_extract(CAST(payload AS TEXT), '$.title'), ''),
                   COALESCE(json_array_length(CAST(payload AS TEXT), '$.nodes'), 0)
            FROM boards
            """) { row in
            (UUID(uuidString: row.text(0)), row.text(1), Int(row.integer(2)))
        }
        for (id, title, nodeCount) in boardRows {
            if let id { add(title, .moodboard, "情绪板 · \(nodeCount) 项", id) }
        }
        let folderRows = try connection.query(
            "SELECT id, COALESCE(json_extract(CAST(payload AS TEXT), '$.name'), '') FROM folders"
        ) { row in
            (UUID(uuidString: row.text(0)), row.text(1))
        }
        for (id, name) in folderRows {
            if let id { add(name, .folder, "文件夹", id) }
        }
        for tag in try fetchTagCounts() { add(tag.name, .tag, "标签 · \(tag.count) 项", nil, tag.name) }
        let filters = FilterCriteria(searchQuery: query, sortBy: .relevance)
        let assetHits = try assetQuery(
            filters,
            limit: max(60, limit),
            projection: "a.id, a.title, a.kind"
        ) { row -> (UUID?, String, MediaKind) in
            (UUID(uuidString: row.text(0)), row.text(1), MediaKind(rawValue: row.text(2)) ?? .image)
        }
        for (id, title, kind) in assetHits {
            guard let id else { continue }
            let score = SearchText.fuzzyScore(normalizedQuery: normalizedQuery, candidate: title) ?? 0.55
            matches.append(QuickJumpMatch(id: "asset-\(id)", kind: .asset, title: title,
                                          subtitle: kind.localizedLabel, targetUUID: id, score: score))
        }
        return Array(matches.sorted {
            if $0.score != $1.score { return $0.score > $1.score }
            return ($0.title, $0.id) < ($1.title, $1.id)
        }.prefix(limit))
    }

    private func decode<T: Decodable>(_ type: T.Type, _ row: SQLRow, column: Int32 = 0) throws -> T {
        try row.withBlobBytes(column) { data in
            guard let data else { throw LibraryDatabaseError("Missing persisted \(type) payload.") }
            return try decoder.decode(type, from: data)
        }
    }

    private func decodeWithSize<T: Decodable>(_ type: T.Type, _ row: SQLRow, column: Int32 = 0) throws -> (T, Int) {
        try row.withBlobBytes(column) { data in
            guard let data else { throw LibraryDatabaseError("Missing persisted \(type) payload.") }
            return (try decoder.decode(type, from: data), data.count)
        }
    }

    func state<T: Decodable>(_ key: String, as type: T.Type = T.self) throws -> T? {
        try connection.query("SELECT payload FROM sync_state WHERE key=?", [.text(key)]) { try decode(type, $0) }.first
    }

    private static func binaryPrefixUpperBound(_ prefix: String) -> String? {
        var bytes = Array(prefix.utf8)
        while let last = bytes.last {
            if last < 0xFF {
                bytes[bytes.count - 1] = last &+ 1
                return String(bytes: bytes, encoding: .utf8)
            }
            bytes.removeLast()
        }
        return nil
    }

    func states<T: Decodable>(withPrefix prefix: String, as type: T.Type) throws -> [(String, T)] {
        if prefix.isEmpty {
            return try connection.query("SELECT key,payload FROM sync_state") {
                try ($0.text(0), decode(type, $0, column: 1))
            }
        }
        if let upperBound = Self.binaryPrefixUpperBound(prefix) {
            return try connection.query(
                "SELECT key,payload FROM sync_state WHERE key >= ? AND key < ?",
                [.text(prefix), .text(upperBound)]
            ) {
                try ($0.text(0), decode(type, $0, column: 1))
            }
        }
        return try connection.query("SELECT key,payload FROM sync_state WHERE substr(key,1,length(?1))=?1", [.text(prefix)]) {
            try ($0.text(0), decode(type, $0, column: 1))
        }
    }

    func setState<T: Encodable>(_ key: String, _ value: T?) throws {
        if let value {
            try connection.execute("INSERT OR REPLACE INTO sync_state VALUES (?,?)", [.text(key), .blob(try encoder.encode(value))])
        } else {
            try connection.execute("DELETE FROM sync_state WHERE key=?", [.text(key)])
        }
    }

    func appendOp<T: Encodable>(_ value: T) throws {
        try connection.execute("INSERT INTO sync_ops(payload) VALUES (?)", [.blob(try encoder.encode(value))])
    }

    func pendingOps<T: Decodable>(as type: T.Type, limit: Int) throws -> [(Int64, T)] {
        try connection.query("SELECT seq,payload FROM sync_ops ORDER BY seq LIMIT ?", [.integer(Int64(limit))]) {
            try ($0.integer(0), decode(type, $0, column: 1))
        }
    }

    func acknowledgeOps(through seq: Int64) throws {
        try connection.execute("DELETE FROM sync_ops WHERE seq<=?", [.integer(seq)])
    }

    func pendingOpCount() throws -> Int {
        Int(try connection.query("SELECT COUNT(*) FROM sync_ops") { $0.integer(0) }.first ?? 0)
    }

    func clearMigrationSyncState() throws {
        try connection.execute("DELETE FROM sync_ops")
        try connection.execute("""
            DELETE FROM sync_state
            WHERE key LIKE 'remote.%'
               OR key LIKE 'local.delete.%'
               OR key LIKE 'deleted.drive.%'
               OR key LIKE 'clock.%'
               OR key LIKE 'projection.%'
            """)
        // Ensure trashed assets also drop stale old-backend drive bindings during backend migration.
        for var trashed in try fetchAssets(matching: FilterCriteria(onlyTrashed: true)) where trashed.driveFileID != nil {
            trashed.driveFileID = nil
            try put(trashed)
        }
    }

    func removeOriginalCacheEntries(_ ids: [UUID]) throws {
        for id in ids {
            try connection.execute("DELETE FROM original_cache WHERE asset_id=?", [.text(id.uuidString)])
        }
    }

    func touchOriginal(_ id: UUID, now: Date = Date()) throws {
        try connection.execute("INSERT OR REPLACE INTO original_cache VALUES (?,?)", [
            .text(id.uuidString), .real(now.timeIntervalSince1970)
        ])
    }

    func originalAccessTimes() throws -> [UUID: Date] {
        let entries = try connection.query("SELECT asset_id,accessed_at FROM original_cache") {
            (UUID(uuidString: $0.text(0)), Date(timeIntervalSince1970: $0.real(1)))
        }
        return Dictionary(uniqueKeysWithValues: entries.compactMap { id, date in id.map { ($0, date) } })
    }

    public func saveVector(_ vector: AssetVector, for id: UUID) throws {
        let current = try self.vector(for: id)
        let feature = vector.featurePrint ?? current?.featurePrint
        let embedding = vector.embedding ?? current?.embedding
        let model = vector.embedding == nil ? current?.embeddingModel : vector.embeddingModel
        let precision = vector.embedding == nil ? current?.precision ?? .float16 : vector.precision
        try connection.execute(
            "INSERT OR REPLACE INTO asset_vectors VALUES (?,?,?,?,?)",
            [.text(id.uuidString), SQLValue(feature), SQLValue(embedding.map { precision.encode($0) }),
             .integer(Int64(precision.rawValue)), SQLValue(model)]
        )
    }

    public func vector(for id: UUID) throws -> AssetVector? {
        try connection.query("SELECT feature_print,embedding,precision,embedding_model FROM asset_vectors WHERE asset_id=?", [
            .text(id.uuidString)
        ], read: Self.readVector).first
    }

    func vectors() throws -> [UUID: AssetVector] {
        let values = try connection.query("SELECT feature_print,embedding,precision,embedding_model,asset_id FROM asset_vectors") {
            (UUID(uuidString: $0.text(4)), Self.readVector($0))
        }
        return Dictionary(uniqueKeysWithValues: values.compactMap { id, vector in id.map { ($0, vector) } })
    }

    func embeddings(forModel model: String) throws -> [UUID: [Float]] {
        let rows = try connection.query(
            "SELECT asset_id, embedding, precision FROM asset_vectors WHERE embedding_model=? AND embedding IS NOT NULL",
            [.text(model)]
        ) { row -> (UUID, [Float])? in
            guard let id = UUID(uuidString: row.text(0)) else { return nil }
            let precision = EmbeddingPrecision(rawValue: Int(row.integer(2))) ?? .float16
            guard let values = row.withBlobBytes(1, { $0.map(precision.decode) }) else { return nil }
            return (id, values)
        }
        var out: [UUID: [Float]] = [:]
        out.reserveCapacity(rows.count)
        for item in rows {
            if let (id, vec) = item { out[id] = vec }
        }
        return out
    }

    private static func readVector(_ row: SQLRow) -> AssetVector {
        let precision = EmbeddingPrecision(rawValue: Int(row.integer(2))) ?? .float16
        let model = row.text(3)
        let embedding = row.withBlobBytes(1) { $0.map(precision.decode) }
        return AssetVector(featurePrint: row.blob(0), embedding: embedding,
                           embeddingModel: model.isEmpty ? nil : model, precision: precision)
    }
}
