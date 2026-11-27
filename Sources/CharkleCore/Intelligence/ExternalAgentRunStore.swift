import Foundation

/// Reversibility snapshot for a single asset modified by an external MCP agent run.
public nonisolated struct AgentAssetSnapshot: Codable, Hashable, Sendable {
    public let assetID: UUID
    public let title: String
    public let notes: String
    public let aiDescription: String?
    public let rating: Int
    public let tags: [String]
    public let suggestedTags: [String]
    public let folderID: UUID?
    public let pinnedOffline: Bool
    public let isTrashed: Bool

    public init(from asset: AssetRecord) {
        self.assetID = asset.id
        self.title = asset.title
        self.notes = asset.notes
        self.aiDescription = asset.aiDescription
        self.rating = asset.rating
        self.tags = asset.tags
        self.suggestedTags = asset.suggestedTags
        self.folderID = asset.folderID
        self.pinnedOffline = asset.pinnedOffline
        self.isTrashed = asset.isTrashed
    }
}

/// Reversibility snapshot for a single folder updated by an external MCP agent run.
public nonisolated struct AgentFolderSnapshot: Codable, Hashable, Sendable {
    public let folderID: UUID
    public let name: String
    public let parentID: UUID?
    public let colorHex: String?
    public let customSymbol: String?

    public init(from folder: FolderRecord) {
        self.folderID = folder.id
        self.name = folder.name
        self.parentID = folder.parentID
        self.colorHex = folder.colorHex
        self.customSymbol = folder.customSymbol
    }
}

/// Persisted audit & compensating-rollback journal entry stored inside SQLite `sync_state` (`agent.run.<id>`).
public nonisolated struct AgentRunRecord: Codable, Hashable, Identifiable, Sendable {
    public let id: String
    public let toolName: String
    public let actor: String
    public let transport: String
    public let summary: String
    public let createdAt: Date
    public var rolledBackAt: Date?

    /// Pre-mutation asset snapshots restored on rollback.
    public let assetSnapshots: [AgentAssetSnapshot]
    /// Newly ingested asset IDs soft-trashed on rollback (never permanently deleted).
    public let ingestedAssetIDs: [UUID]
    /// Pre-mutation folder snapshots restored on rollback.
    public let folderSnapshots: [AgentFolderSnapshot]
    /// Pre-mutation Moodboard documents restored on rollback (for patched boards or boards updated by dedup merge).
    public let boardSnapshots: [MoodboardDocument]
    /// Newly created Moodboard IDs (cannot be hard-deleted via agent; flagged in rollback report).
    public let createdBoardIDs: [UUID]

    public var isRolledBack: Bool { rolledBackAt != nil }

    public var affectedCount: Int {
        assetSnapshots.count + ingestedAssetIDs.count + folderSnapshots.count + boardSnapshots.count + createdBoardIDs.count
    }

    public init(
        id: String = Self.makeRunID(),
        toolName: String,
        actor: String,
        transport: String,
        summary: String,
        createdAt: Date = Date(),
        rolledBackAt: Date? = nil,
        assetSnapshots: [AgentAssetSnapshot] = [],
        ingestedAssetIDs: [UUID] = [],
        folderSnapshots: [AgentFolderSnapshot] = [],
        boardSnapshots: [MoodboardDocument] = [],
        createdBoardIDs: [UUID] = []
    ) {
        self.id = id
        self.toolName = toolName
        self.actor = actor
        self.transport = transport
        self.summary = summary
        self.createdAt = createdAt
        self.rolledBackAt = rolledBackAt
        self.assetSnapshots = assetSnapshots
        self.ingestedAssetIDs = ingestedAssetIDs
        self.folderSnapshots = folderSnapshots
        self.boardSnapshots = boardSnapshots
        self.createdBoardIDs = createdBoardIDs
    }

    public static func makeRunID() -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        let suffix = String(UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased().prefix(6))
        return "run-\(formatter.string(from: Date()))-\(suffix)"
    }
}

/// Lightweight persisted working set for `session_id` deduplication across multi-round visual discovery.
public nonisolated struct AgentCurationSession: Codable, Hashable, Sendable {
    public let id: String
    public var seenAssetIDs: [UUID]
    public var updatedAt: Date

    public init(id: String, seenAssetIDs: [UUID] = [], updatedAt: Date = Date()) {
        self.id = id
        self.seenAssetIDs = seenAssetIDs
        self.updatedAt = updatedAt
    }
}

/// Persists agent run rollback journals, curation sessions, and library taxonomy rules inside
/// `LibraryDatabase.sync_state` (zero schema migration required, WAL-safe across stdio & HTTP processes).
public nonisolated enum ExternalAgentStateStore {
    private static let runKeyPrefix = "agent.run."
    private static let sessionKeyPrefix = "agent.session."
    private static let taxonomyKey = "agent.taxonomy.v1"
    private static let maxStoredRuns = 30
    private static let maxStoredSessions = 24
    private static let maxSeenPerSession = 300

    // MARK: - Taxonomy Policy

    public static func loadTaxonomy(from database: LibraryDatabase) async -> LibraryTaxonomyPolicy {
        (try? await database.state(taxonomyKey, as: LibraryTaxonomyPolicy.self)) ?? LibraryTaxonomyPolicy()
    }

    public static func saveTaxonomy(_ policy: LibraryTaxonomyPolicy, to database: LibraryDatabase) async throws {
        try await database.setState(taxonomyKey, policy)
    }

    // MARK: - Run Journal & Rollback History

    public static func recordRun(_ run: AgentRunRecord, in database: LibraryDatabase) async {
        do {
            try await database.setState(runKeyPrefix + run.id, run)
            let existing = try await database.states(withPrefix: runKeyPrefix, as: AgentRunRecord.self)
            if existing.count > maxStoredRuns {
                let overflow = existing
                    .sorted { $0.1.createdAt > $1.1.createdAt }
                    .dropFirst(maxStoredRuns)
                for (key, _) in overflow {
                    try? await database.setState(key, nil as AgentRunRecord?)
                }
            }
        } catch {
            // Audit persistence failure should never corrupt the committed library state.
        }
    }

    public static func listRuns(in database: LibraryDatabase, limit: Int = 20) async -> [AgentRunRecord] {
        let rows = (try? await database.states(withPrefix: runKeyPrefix, as: AgentRunRecord.self)) ?? []
        return rows
            .map(\.1)
            .sorted { $0.createdAt > $1.createdAt }
            .prefix(max(1, min(50, limit)))
            .map { $0 }
    }

    public static func loadRun(id: String, in database: LibraryDatabase) async -> AgentRunRecord? {
        let clean = id.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty else { return nil }
        if let exact = try? await database.state(runKeyPrefix + clean, as: AgentRunRecord.self) {
            return exact
        }
        // Prefix fallback for ergonomic short run IDs
        let all = await listRuns(in: database, limit: 50)
        let lowered = clean.lowercased()
        let matches = all.filter { $0.id.lowercased().hasPrefix(lowered) }
        return matches.count == 1 ? matches[0] : nil
    }

    public static func markRunRolledBack(id: String, in database: LibraryDatabase) async {
        guard var run = await loadRun(id: id, in: database) else { return }
        run.rolledBackAt = Date()
        try? await database.setState(runKeyPrefix + run.id, run)
    }

    // MARK: - Curation Session Working Sets

    public static func loadSession(id: String, in database: LibraryDatabase) async -> AgentCurationSession {
        let safeID = sanitizeSessionID(id)
        if let existing = try? await database.state(sessionKeyPrefix + safeID, as: AgentCurationSession.self) {
            return existing
        }
        return AgentCurationSession(id: safeID)
    }

    public static func recordSeenAssets(
        sessionID: String,
        assetIDs: [UUID],
        reset: Bool = false,
        in database: LibraryDatabase
    ) async -> AgentCurationSession {
        let safeID = sanitizeSessionID(sessionID)
        var session = reset ? AgentCurationSession(id: safeID) : await loadSession(id: safeID, in: database)
        var existingSet = Set(session.seenAssetIDs)
        for id in assetIDs where existingSet.insert(id).inserted {
            session.seenAssetIDs.append(id)
        }
        if session.seenAssetIDs.count > maxSeenPerSession {
            session.seenAssetIDs = Array(session.seenAssetIDs.suffix(maxSeenPerSession))
        }
        session.updatedAt = Date()
        try? await database.setState(sessionKeyPrefix + safeID, session)

        // Evict stale sessions beyond cap
        if let all = try? await database.states(withPrefix: sessionKeyPrefix, as: AgentCurationSession.self),
           all.count > maxStoredSessions {
            let overflow = all.sorted { $0.1.updatedAt > $1.1.updatedAt }.dropFirst(maxStoredSessions)
            for (key, _) in overflow {
                try? await database.setState(key, nil as AgentCurationSession?)
            }
        }
        return session
    }

    private static func sanitizeSessionID(_ raw: String) -> String {
        let cleaned = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            .filter { $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" }
        return cleaned.isEmpty ? "default" : String(cleaned.prefix(48))
    }
}
