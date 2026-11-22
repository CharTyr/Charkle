import Foundation

/// Permission boundary governing external AI Agents (MCP Server & CLI).
///
/// Security invariant: External agents are NEVER permitted to permanently delete user assets
/// or folders. Even `.readWriteOrganize` only permits soft Trash (`trashed = true`).
public nonisolated enum ExternalAgentAccessLevel: String, Codable, CaseIterable, Hashable, Sendable {
    case readOnly
    case readWriteOrganize

    public var displayTitle: String {
        switch self {
        case .readOnly: "仅只读检索与导出"
        case .readWriteOrganize: "允许整理与生成情绪板"
        }
    }

    public var summary: String {
        switch self {
        case .readOnly:
            "外部 Agent 可检索素材、查看视觉联系表、读取情绪板与导出高清图，无法修改或写入素材库。"
        case .readWriteOrganize:
            "外部 Agent 可整理文件夹与标签、导入素材、生成或更新情绪板，并仅可将素材移入回收站（永不允许彻底删除）。"
        }
    }
}

public nonisolated struct ExternalAgentConfig: Codable, Hashable, Sendable {
    public var enabled: Bool
    public var accessLevel: ExternalAgentAccessLevel

    public init(
        enabled: Bool = true,
        accessLevel: ExternalAgentAccessLevel = .readOnly
    ) {
        self.enabled = enabled
        self.accessLevel = accessLevel
    }

    public var allowsRead: Bool { enabled }
    public var allowsWrite: Bool { enabled && accessLevel == .readWriteOrganize }
}

/// Atomic file-backed store (`external-agent.json` inside Charkle's Application Support directory)
/// shared between `Charkle.app` and the headless `charkle` MCP/CLI helper with zero SQLite lock contention.
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
        guard let data = try? Data(contentsOf: url),
              let decoded = try? JSONDecoder().decode(ExternalAgentConfig.self, from: data) else {
            return ExternalAgentConfig()
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

/// Cross-process live-refresh bridge between headless `charkle` (MCP / CLI) and the running `Charkle.app` UI.
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
        DistributedNotificationCenter.default().postNotificationName(
            libraryChangedNotification,
            object: nil,
            userInfo: info,
            deliverImmediately: true
        )
    }
}
