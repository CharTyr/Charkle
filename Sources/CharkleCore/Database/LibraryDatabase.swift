import Foundation

public final actor LibraryDatabase {
    private let connection: SQLiteConnection
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    public init(path: String = ":memory:") throws {
        let connection = try SQLiteConnection(path: path)
        try connection.script("PRAGMA foreign_keys = ON; PRAGMA synchronous = NORMAL;")
        let journalMode = (try? connection.query("PRAGMA journal_mode") { $0.text(0) }.first)?.lowercased()
        if path != ":memory:", journalMode != "wal" {
            try connection.script("PRAGMA journal_mode = WAL;")
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
                try connection.script("COMMIT")
            } catch {
                try? connection.script("ROLLBACK")
                throw error
            }
        }
        self.connection = connection
    }

    public init(url: URL) throws { try self.init(path: url.path) }

    private static let schemaVersion = 2

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

    func transaction<T: Sendable>(_ work: @Sendable (isolated LibraryDatabase) throws -> T) throws -> T {
        try connection.script("BEGIN IMMEDIATE")
        do {
            let result = try work(self)
            try connection.script("COMMIT")
            return result
        } catch {
            try? connection.script("ROLLBACK")
            throw error
        }
    }

    public func upsertAssets(_ assets: [AssetRecord]) throws {
        try transaction { db in
            for asset in assets { try db.put(asset) }
        }
    }

    func put(_ asset: AssetRecord) throws {
        let id = asset.id.uuidString
        let old = try self.asset(id: asset.id)
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
                  .integer(asset.isTrashed ? 1 : 0), .blob(try encoder.encode(asset))])

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
            let pinyin = fields.map(SearchText.pinyin)
            if old != nil { try connection.execute("DELETE FROM assets_fts WHERE rowid=?", [.integer(rowID)]) }
            let tokens = fields.map(SearchText.index) + [
                pinyin.map(\.full).joined(separator: " "), pinyin.map(\.initials).joined(separator: " ")
            ]
            try connection.execute(
                "INSERT INTO assets_fts(rowid,title,fileName,notes,tags,ocrText,aiDescription,sourceDomain,pinyin,initials) VALUES (?,?,?,?,?,?,?,?,?,?)",
                [.integer(rowID)] + tokens.map(SQLValue.text)
            )
        }
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

    public func asset(id: UUID) throws -> AssetRecord? { try asset(where: "id=?", equals: id.uuidString) }

    func asset(driveID: String) throws -> AssetRecord? { try asset(where: "drive_id=?", equals: driveID) }

    func assetDriveBindings() throws -> [(String, UUID)] {
        try connection.query("SELECT drive_id,id FROM assets WHERE drive_id IS NOT NULL") { row in
            (row.text(0), UUID(uuidString: row.text(1)))
        }.compactMap { driveID, id in id.map { (driveID, $0) } }
    }

    func assets(contentHash: String) throws -> [AssetRecord] {
        try connection.query("SELECT payload FROM assets WHERE content_hash=?", [.text(contentHash)]) {
            try decode(AssetRecord.self, $0)
        }
    }

    private func asset(where clause: String, equals value: String) throws -> AssetRecord? {
        try connection.query("SELECT payload FROM assets WHERE \(clause)", [.text(value)]) {
            try decode(AssetRecord.self, $0)
        }.first
    }

    func removeAsset(_ id: UUID) throws {
        let parameters: [SQLValue] = [.text(id.uuidString)]
        try connection.execute("DELETE FROM assets_fts WHERE rowid IN (SELECT rowid FROM assets WHERE id=?)", parameters)
        try connection.execute("DELETE FROM assets WHERE id=?", parameters)
    }

    public func fetchAssets(matching criteria: FilterCriteria, limit: Int? = nil) throws -> [AssetRecord] {
        try assetQuery(criteria, limit: limit) { try decode(AssetRecord.self, $0) }
    }

    func searchRanks(_ query: String) throws -> [UUID: Double] {
        guard !SearchText.ftsQuery(query).isEmpty else { return [:] }
        let criteria = FilterCriteria(searchQuery: query, sortBy: .relevance)
        let matches = try assetQuery(criteria, projection: "a.id") { UUID(uuidString: $0.text(0)) }.compactMap { $0 }
        return Dictionary(uniqueKeysWithValues: matches.enumerated().map {
            ($0.element, 1 / (1 + Double($0.offset) / Double(max(8, matches.count / 4))))
        })
    }

    private func folderSubtreeIDs(rootID: UUID) throws -> [UUID] {
        let all = try connection.query("SELECT payload FROM folders") { try decode(FolderRecord.self, $0) }
        var childrenByParent: [UUID: [UUID]] = [:]
        for f in all {
            if let pid = f.parentID {
                childrenByParent[pid, default: []].append(f.id)
            }
        }
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
                clauses.append("a.folder_id IN (\(Self.placeholders(subtreeIDs.count)))")
                args += subtreeIDs.map { SQLValue.text($0.uuidString) }
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
            clauses.append("a.kind IN (\(Self.placeholders(kinds.count)))")
            args += kinds.map(SQLValue.text)
        }
        if filters.onlyUntagged { constrain("NOT EXISTS (SELECT 1 FROM asset_tags WHERE asset_id=a.id)") }
        for tag in filters.tags.sorted() {
            constrain("EXISTS (SELECT 1 FROM asset_tags WHERE asset_id=a.id AND tag=?)", .text(tag))
        }
        if let hex = filters.selectedColorHex {
            let color = LabColor.fromHex(hex)
            let tolerance = max(0, filters.colorTolerance)
            clauses.append("""
                EXISTS (SELECT 1 FROM asset_colors c WHERE c.asset_id=a.id
                    AND (c.l-?1)*(c.l-?1)+(c.a-?2)*(c.a-?2)+(c.b-?3)*(c.b-?3)<=?4)
                """)
            args.insert(contentsOf: [.real(color.l), .real(color.a), .real(color.b), .real(tolerance * tolerance)], at: 0)
            // Numbered color parameters precede all ordinary filter parameters in the statement.
            clauses.insert(clauses.removeLast(), at: 0)
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
        let page = limit.map { " LIMIT \(max(0, $0))" } ?? ""
        return try connection.query("SELECT \(projection) FROM \(source)\(filter) ORDER BY \(order), a.id\(page)", args, read: read)
    }

    private static func placeholders(_ count: Int) -> String {
        Array(repeating: "?", count: count).joined(separator: ",")
    }

    public func fetchFolders() throws -> [FolderRecord] {
        try connection.query("""
            SELECT payload, (SELECT COUNT(*) FROM assets WHERE folder_id=f.id AND trashed=0)
            FROM folders f
            """) { row in
            var folder = try decode(FolderRecord.self, row)
            folder.assetCount = Int(row.integer(1))
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
        try connection.execute("""
            INSERT INTO folders VALUES (?,?,?) ON CONFLICT(id) DO UPDATE SET drive_id=excluded.drive_id, payload=excluded.payload
            """, [.text(folder.id.uuidString), SQLValue(folder.driveFolderID), .blob(try encoder.encode(folder))])
    }

    func removeFolder(_ id: UUID) throws {
        try connection.execute("DELETE FROM folders WHERE id=?", [.text(id.uuidString)])
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
        var matches: [QuickJumpMatch] = []
        func add(_ title: String, _ kind: QuickJumpKind, _ subtitle: String, _ uuid: UUID?, _ tag: String? = nil) {
            guard let score = SearchText.fuzzyScore(query: query, candidate: title) else { return }
            matches.append(QuickJumpMatch(id: kind.rawValue + "-" + (uuid?.uuidString ?? title), kind: kind,
                                          title: title, subtitle: subtitle, targetUUID: uuid, tagName: tag, score: score))
        }
        for board in try fetchBoards() { add(board.title, .moodboard, "情绪板 · \(board.nodes.count) 项", board.id) }
        for folder in try fetchFolders() { add(folder.name, .folder, "文件夹", folder.id) }
        for tag in try fetchTagCounts() { add(tag.name, .tag, "标签 · \(tag.count) 项", nil, tag.name) }
        let filters = FilterCriteria(searchQuery: query, sortBy: .relevance)
        for item in try fetchAssets(matching: filters, limit: max(60, limit)) {
            let score = SearchText.fuzzyScore(query: query, candidate: item.title) ?? 0.55
            matches.append(QuickJumpMatch(id: "asset-\(item.id)", kind: .asset, title: item.title,
                                          subtitle: item.mediaKind.localizedLabel, targetUUID: item.id, score: score))
        }
        return Array(matches.sorted {
            if $0.score != $1.score { return $0.score > $1.score }
            return ($0.title, $0.id) < ($1.title, $1.id)
        }.prefix(limit))
    }

    private func decode<T: Decodable>(_ type: T.Type, _ row: SQLRow, column: Int32 = 0) throws -> T {
        guard let data = row.blob(column) else { throw LibraryDatabaseError("Missing persisted \(type) payload.") }
        return try decoder.decode(type, from: data)
    }

    func state<T: Decodable>(_ key: String, as type: T.Type = T.self) throws -> T? {
        try connection.query("SELECT payload FROM sync_state WHERE key=?", [.text(key)]) { try decode(type, $0) }.first
    }

    func states<T: Decodable>(withPrefix prefix: String, as type: T.Type) throws -> [(String, T)] {
        try connection.query("SELECT key,payload FROM sync_state WHERE substr(key,1,length(?1))=?1", [.text(prefix)]) {
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

    private static func readVector(_ row: SQLRow) -> AssetVector {
        let precision = EmbeddingPrecision(rawValue: Int(row.integer(2))) ?? .float16
        let model = row.text(3)
        return AssetVector(featurePrint: row.blob(0), embedding: row.blob(1).map(precision.decode),
                           embeddingModel: model.isEmpty ? nil : model, precision: precision)
    }
}
