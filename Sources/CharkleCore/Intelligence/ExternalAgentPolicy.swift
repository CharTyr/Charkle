import CryptoKit
import Foundation
import Security

/// Permission boundary governing External AI Agents across both local `stdio` MCP and remote/local HTTP MCP.
///
/// Security invariant: External agents are NEVER permitted to permanently delete user assets
/// or delete folders under any access level.
public nonisolated enum ExternalAgentAccessLevel: String, Codable, CaseIterable, Hashable, Sendable {
    case readOnly
    case inboxAndEnrich
    case readWriteOrganize

    public var displayTitle: String {
        switch self {
        case .readOnly: "仅只读"
        case .inboxAndEnrich: "仅收件箱与打标"
        case .readWriteOrganize: "全局整理与生板"
        }
    }

    public var summary: String {
        switch self {
        case .readOnly:
            "外部 Agent 可检索素材、查看视觉联系表、读取情绪板与拉取所选原图，无法写入素材库。"
        case .inboxAndEnrich:
            "外部 Agent 可向收件箱入库、补全 AI 描述与建议标签，并将收件箱素材归入已有文件夹（不可改动已整理目录或移入废纸篓）。"
        case .readWriteOrganize:
            "外部 Agent 可批量整理素材、管理文件夹、生成或修补情绪板、去重合并与回滚操作（永不允许彻底删除素材或删文件夹）。"
        }
    }

    public var allowsInboxAndEnrichWrites: Bool {
        self == .inboxAndEnrich || self == .readWriteOrganize
    }

    public var allowsGlobalOrganizeWrites: Bool {
        self == .readWriteOrganize
    }
}

/// Transport channel over which an MCP request arrived.
public nonisolated enum ExternalAgentTransport: String, Codable, CaseIterable, Hashable, Sendable {
    case stdio
    case http

    public var displayTitle: String {
        switch self {
        case .stdio: "本机 MCP（stdio）"
        case .http: "远程 / 本地 HTTP MCP"
        }
    }
}

/// Scoped Bearer token persisted as SHA-256 hash + display prefix (zero plaintext tokens stored on disk).
public nonisolated struct ExternalAgentToken: Codable, Hashable, Identifiable, Sendable {
    public let id: UUID
    public var name: String
    public let tokenPrefix: String
    public let tokenHash: String
    public var accessLevel: ExternalAgentAccessLevel
    public var isEnabled: Bool
    public let createdAt: Date

    public init(
        id: UUID = UUID(),
        name: String,
        tokenPrefix: String,
        tokenHash: String,
        accessLevel: ExternalAgentAccessLevel,
        isEnabled: Bool = true,
        createdAt: Date = Date()
    ) {
        self.id = id
        self.name = name
        self.tokenPrefix = tokenPrefix
        self.tokenHash = tokenHash
        self.accessLevel = accessLevel
        self.isEnabled = isEnabled
        self.createdAt = createdAt
    }

    /// Generates a new cryptographically random scoped MCP token (`ck_mcp_<48 hex>`), returning
    /// both the persistable hash record and the one-time plaintext secret to show to the user.
    public static func mint(
        name: String,
        accessLevel: ExternalAgentAccessLevel
    ) -> (record: ExternalAgentToken, plaintext: String) {
        var bytes = [UInt8](repeating: 0, count: 24)
        let status = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        let randomHex: String
        if status == errSecSuccess {
            randomHex = bytes.map { String(format: "%02x", $0) }.joined()
        } else {
            randomHex = (UUID().uuidString + UUID().uuidString)
                .replacingOccurrences(of: "-", with: "")
                .lowercased()
                .prefix(48)
                .description
        }
        let plaintext = "ck_mcp_\(randomHex)"
        let prefix = String(plaintext.prefix(15))
        let hash = sha256Hex(plaintext)
        let cleanName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let record = ExternalAgentToken(
            name: cleanName.isEmpty ? "远程 Agent 密钥" : cleanName,
            tokenPrefix: prefix,
            tokenHash: hash,
            accessLevel: accessLevel,
            isEnabled: true,
            createdAt: Date()
        )
        return (record, plaintext)
    }

    public static func sha256Hex(_ raw: String) -> String {
        let digest = SHA256.hash(data: Data(raw.utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    /// Constant-time verification of a presented Bearer token string against `tokenHash`.
    public func matches(plaintext candidate: String) -> Bool {
        guard isEnabled, !candidate.isEmpty else { return false }
        let candidateHash = Self.sha256Hex(candidate)
        return Self.constantTimeEquals(candidateHash, tokenHash)
    }

    private static func constantTimeEquals(_ a: String, _ b: String) -> Bool {
        let aBytes = Array(a.utf8)
        let bBytes = Array(b.utf8)
        guard aBytes.count == bBytes.count, !aBytes.isEmpty else { return false }
        var diff: UInt8 = 0
        for i in 0..<aBytes.count {
            diff |= aBytes[i] ^ bBytes[i]
        }
        return diff == 0
    }
}

/// Unified pure-MCP external agent configuration shared between `Charkle.app` (HTTP MCP + Settings UI)
/// and the bundled headless `charkle` stdio MCP helper.
public nonisolated struct ExternalAgentConfig: Codable, Hashable, Sendable {
    /// Controls local headless `stdio` MCP (`charkle mcp`).
    public var mcpEnabled: Bool
    /// Controls embedded HTTP MCP endpoint (`POST /api/v1/mcp`) hosted by `Charkle.app`.
    public var httpMCPEnabled: Bool
    /// When `true`, binds HTTP server on all interfaces (`0.0.0.0`) for LAN / Tailscale / remote MCP access
    /// while strictly keeping browser-extension endpoints restricted to loopback (`127.0.0.1`).
    public var allowRemoteHTTPMCP: Bool
    /// Default access level for local `stdio` MCP sessions.
    public var accessLevel: ExternalAgentAccessLevel
    /// Scoped Bearer tokens governing HTTP `/api/v1/mcp` access.
    public var tokens: [ExternalAgentToken]

    /// Convenience aggregate toggle reflecting whether any MCP transport is enabled.
    public var enabled: Bool {
        get { mcpEnabled || httpMCPEnabled }
        set {
            mcpEnabled = newValue
            httpMCPEnabled = newValue
        }
    }

    public init(
        mcpEnabled: Bool = true,
        httpMCPEnabled: Bool = true,
        allowRemoteHTTPMCP: Bool = false,
        accessLevel: ExternalAgentAccessLevel = .readOnly,
        tokens: [ExternalAgentToken] = []
    ) {
        self.mcpEnabled = mcpEnabled
        self.httpMCPEnabled = httpMCPEnabled
        self.allowRemoteHTTPMCP = allowRemoteHTTPMCP
        self.accessLevel = accessLevel
        self.tokens = tokens
    }

    public init(
        enabled: Bool,
        accessLevel: ExternalAgentAccessLevel = .readOnly
    ) {
        self.mcpEnabled = enabled
        self.httpMCPEnabled = enabled
        self.allowRemoteHTTPMCP = false
        self.accessLevel = accessLevel
        self.tokens = []
    }

    private enum CodingKeys: String, CodingKey {
        case enabled
        case mcpEnabled
        case httpMCPEnabled
        case allowRemoteHTTPMCP
        case accessLevel
        case tokens
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let legacyEnabled = try container.decodeIfPresent(Bool.self, forKey: .enabled) ?? true
        let decodedStdio = try container.decodeIfPresent(Bool.self, forKey: .mcpEnabled) ?? legacyEnabled
        self.mcpEnabled = decodedStdio
        self.httpMCPEnabled = try container.decodeIfPresent(Bool.self, forKey: .httpMCPEnabled) ?? decodedStdio
        self.allowRemoteHTTPMCP = try container.decodeIfPresent(Bool.self, forKey: .allowRemoteHTTPMCP) ?? false
        self.accessLevel = try container.decodeIfPresent(ExternalAgentAccessLevel.self, forKey: .accessLevel) ?? .readOnly
        self.tokens = try container.decodeIfPresent([ExternalAgentToken].self, forKey: .tokens) ?? []
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(enabled, forKey: .enabled)
        try container.encode(mcpEnabled, forKey: .mcpEnabled)
        try container.encode(httpMCPEnabled, forKey: .httpMCPEnabled)
        try container.encode(allowRemoteHTTPMCP, forKey: .allowRemoteHTTPMCP)
        try container.encode(accessLevel, forKey: .accessLevel)
        try container.encode(tokens, forKey: .tokens)
    }

    public func isEnabled(for transport: ExternalAgentTransport) -> Bool {
        switch transport {
        case .stdio: mcpEnabled
        case .http: httpMCPEnabled
        }
    }

    public func matchingToken(for plaintext: String) -> ExternalAgentToken? {
        guard httpMCPEnabled else { return nil }
        return tokens.first { $0.matches(plaintext: plaintext) }
    }
}

/// Per-request execution context injected by either `stdio` MCP or HTTP `/api/v1/mcp`.
public nonisolated struct ExternalAgentRequestContext: Sendable {
    public let transport: ExternalAgentTransport
    /// Optional token-scoped override for HTTP requests. When `nil`, falls back to `ExternalAgentConfig.accessLevel`.
    public let scopedAccessLevel: ExternalAgentAccessLevel?
    /// Human-readable caller label recorded in `AgentRunRecord` audit logs.
    public let actorLabel: String
    /// Optional callback supplied by HTTP MCP host to mint short-lived signed download URLs for cross-machine asset fetches.
    public let issueDownloadURL: (@Sendable (UUID) async -> String?)?

    public init(
        transport: ExternalAgentTransport = .stdio,
        scopedAccessLevel: ExternalAgentAccessLevel? = nil,
        actorLabel: String = "local-stdio",
        issueDownloadURL: (@Sendable (UUID) async -> String?)? = nil
    ) {
        self.transport = transport
        self.scopedAccessLevel = scopedAccessLevel
        self.actorLabel = actorLabel
        self.issueDownloadURL = issueDownloadURL
    }

    public static let localStdio = ExternalAgentRequestContext(
        transport: .stdio,
        scopedAccessLevel: nil,
        actorLabel: "local-stdio",
        issueDownloadURL: nil
    )

    public func effectiveAccessLevel(using policy: ExternalAgentConfig) -> ExternalAgentAccessLevel {
        scopedAccessLevel ?? policy.accessLevel
    }

    public var isRemoteHTTP: Bool {
        transport == .http
    }
}

/// User-editable personal library organization rules exposed via `library_overview` and `charkle://library/taxonomy`
/// so any connected external agent aligns immediately with the user's taxonomy conventions.
public nonisolated struct LibraryTaxonomyPolicy: Codable, Hashable, Sendable {
    public var preferredTagLanguage: String
    public var tagAliases: [String: String]
    public var folderGuidelines: [String: String]
    public var ratingMeanings: [String: String]
    public var notes: String

    public init(
        preferredTagLanguage: String = "zh",
        tagAliases: [String: String] = [:],
        folderGuidelines: [String: String] = [:],
        ratingMeanings: [String: String] = [:],
        notes: String = ""
    ) {
        self.preferredTagLanguage = preferredTagLanguage
        self.tagAliases = tagAliases
        self.folderGuidelines = folderGuidelines
        self.ratingMeanings = ratingMeanings
        self.notes = notes
    }

    public var isEmpty: Bool {
        tagAliases.isEmpty && folderGuidelines.isEmpty && ratingMeanings.isEmpty
            && notes.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
}

/// Atomic file-backed store (`external-agent.json` inside Charkle's Application Support directory)
/// shared between `Charkle.app` and the headless `charkle` stdio MCP helper with zero SQLite lock contention.
public nonisolated enum ExternalAgentConfigStore {
    public static let fileName = "external-agent.json"

    public static func defaultDirectory() -> URL {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appending(path: "Library/Application Support", directoryHint: .isDirectory)
        return support.appending(path: "Charkle", directoryHint: .isDirectory)
    }

    public static func configURL(in directory: URL = defaultDirectory()) -> URL {
        directory.appending(path: fileName)
    }

    public static func load(in directory: URL = defaultDirectory()) -> ExternalAgentConfig {
        let url = configURL(in: directory)
        guard (try? FileManager.default.attributesOfItem(atPath: url.path)) != nil else {
            return ExternalAgentConfig()
        }
        guard let data = try? Data(contentsOf: url),
              let decoded = try? JSONDecoder().decode(ExternalAgentConfig.self, from: data) else {
            // Fail closed when an existing policy file is unreadable or corrupt so a damaged
            // config cannot silently re-enable MCP after the user disabled it.
            return ExternalAgentConfig(
                mcpEnabled: false,
                httpMCPEnabled: false,
                allowRemoteHTTPMCP: false,
                accessLevel: .readOnly,
                tokens: []
            )
        }
        return decoded
    }

    public static func save(_ config: ExternalAgentConfig, in directory: URL = defaultDirectory()) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(config)
        let url = configURL(in: directory)
        try data.write(to: url, options: .atomic)
    }
}

/// Cross-process live-refresh bridge between headless `charkle` (`stdio` MCP) and the running `Charkle.app` UI.
public nonisolated enum ExternalAgentNotifier {
    public static let libraryChangedNotification = Notification.Name("com.charkle.externalLibraryChanged")

    public static func postLibraryChanged(kind: String, boardID: UUID? = nil, summary: String? = nil) {
        var info: [String: String] = ["kind": kind]
        if let boardID {
            info["boardID"] = boardID.uuidString
        }
        if let summary, !summary.isEmpty {
            info["summary"] = summary
        }
        #if os(macOS)
        DistributedNotificationCenter.default().postNotificationName(
            libraryChangedNotification,
            object: nil,
            userInfo: info,
            deliverImmediately: true
        )
        #else
        NotificationCenter.default.post(
            name: libraryChangedNotification,
            object: nil,
            userInfo: info
        )
        #endif
    }
}
