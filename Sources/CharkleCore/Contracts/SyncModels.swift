import Foundation

public enum DriveTransportMode: String, Codable, CaseIterable, Hashable, Sendable {
    case directAPIWithGDirect
    case webDAV
    case gdirectMount
    case localOnly

    public var localizedLabel: String {
        switch self {
        case .directAPIWithGDirect: "Google Drive"
        case .webDAV: "WebDAV 云盘"
        case .gdirectMount: "gdirect 本地挂载"
        case .localOnly: "纯本地文件夹"
        }
    }
}

public struct DriveAccountInfo: Codable, Hashable, Sendable {
    public var email: String
    public var displayName: String?
    public var storageUsedBytes: Int64?
    public var storageLimitBytes: Int64?
    public var source: String

    public init(
        email: String,
        displayName: String? = nil,
        storageUsedBytes: Int64? = nil,
        storageLimitBytes: Int64? = nil,
        source: String = "Google Drive"
    ) {
        self.email = email
        self.displayName = displayName
        self.storageUsedBytes = storageUsedBytes
        self.storageLimitBytes = storageLimitBytes
        self.source = source
    }
}

public struct GDirectEndpoint: Codable, Hashable, Identifiable, Sendable {
    public var id: String { ip }
    public let ip: String
    public let latencyMs: Int
    public let healthy: Bool

    public init(ip: String, latencyMs: Int, healthy: Bool = true) {
        self.ip = ip
        self.latencyMs = latencyMs
        self.healthy = healthy
    }
}

public struct GDirectEnvironmentSnapshot: Codable, Hashable, Sendable {
    public var cliPath: String?
    public var cliVersion: String?
    public var appVersion: String?
    public var hasVersionMismatch: Bool
    public var rclonePath: String?
    public var accounts: [String]
    public var defaultAccount: String?
    public var endpoints: [GDirectEndpoint]
    public var mountPath: String
    public var isMountActive: Bool
    public var bypassTunEnabled: Bool

    public init(
        cliPath: String? = nil,
        cliVersion: String? = nil,
        appVersion: String? = nil,
        hasVersionMismatch: Bool = false,
        rclonePath: String? = nil,
        accounts: [String] = [],
        defaultAccount: String? = nil,
        endpoints: [GDirectEndpoint] = [],
        mountPath: String = NSHomeDirectory() + "/GoogleDrive",
        isMountActive: Bool = false,
        bypassTunEnabled: Bool = true
    ) {
        self.cliPath = cliPath
        self.cliVersion = cliVersion
        self.appVersion = appVersion
        self.hasVersionMismatch = hasVersionMismatch
        self.rclonePath = rclonePath
        self.accounts = accounts
        self.defaultAccount = defaultAccount
        self.endpoints = endpoints
        self.mountPath = mountPath
        self.isMountActive = isMountActive
        self.bypassTunEnabled = bypassTunEnabled
    }
}

public struct DriveSyncConfig: Codable, Hashable, Sendable {
    public var mode: DriveTransportMode
    /// Cloud root folder path for Google Drive (supports single folder `"Charkle"` or nested `"Design/Charkle"`).
    public var rootFolderName: String
    public var mountPath: String
    public var selectedGDirectAccount: String?
    public var useGDirectIPAcceleration: Bool
    /// WebDAV server endpoint (e.g. `https://dav.jianguoyun.com/dav/` or `https://nas.example.com:5006`).
    public var webDAVServerURL: String
    public var webDAVUsername: String
    /// Remote library folder path inside WebDAV server (e.g. `/Charkle` or `/Design/Charkle`).
    public var webDAVRemotePath: String
    /// Human-readable local folder path when saving purely locally (e.g. `~/Pictures/Charkle`).
    public var localLibraryPath: String
    public var autoSyncIntervalSeconds: Int
    public var syncThumbnails: Bool
    public var syncEmbeddings: Bool

    public init(
        mode: DriveTransportMode = .directAPIWithGDirect,
        rootFolderName: String = "Charkle",
        mountPath: String = NSHomeDirectory() + "/GoogleDrive",
        selectedGDirectAccount: String? = nil,
        useGDirectIPAcceleration: Bool = true,
        webDAVServerURL: String = "",
        webDAVUsername: String = "",
        webDAVRemotePath: String = "/Charkle",
        localLibraryPath: String = NSHomeDirectory() + "/Pictures/Charkle",
        autoSyncIntervalSeconds: Int = 120,
        syncThumbnails: Bool = true,
        syncEmbeddings: Bool = true
    ) {
        self.mode = mode
        self.rootFolderName = rootFolderName
        self.mountPath = mountPath
        self.selectedGDirectAccount = selectedGDirectAccount
        self.useGDirectIPAcceleration = useGDirectIPAcceleration
        self.webDAVServerURL = webDAVServerURL
        self.webDAVUsername = webDAVUsername
        self.webDAVRemotePath = webDAVRemotePath
        self.localLibraryPath = localLibraryPath
        self.autoSyncIntervalSeconds = autoSyncIntervalSeconds
        self.syncThumbnails = syncThumbnails
        self.syncEmbeddings = syncEmbeddings
    }

    private enum CodingKeys: String, CodingKey {
        case mode, rootFolderName, mountPath, selectedGDirectAccount, useGDirectIPAcceleration
        case webDAVServerURL, webDAVUsername, webDAVRemotePath, localLibraryPath
        case autoSyncIntervalSeconds, syncThumbnails, syncEmbeddings
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        mode = try c.decodeIfPresent(DriveTransportMode.self, forKey: .mode) ?? .directAPIWithGDirect
        rootFolderName = try c.decodeIfPresent(String.self, forKey: .rootFolderName) ?? "Charkle"
        mountPath = try c.decodeIfPresent(String.self, forKey: .mountPath) ?? (NSHomeDirectory() + "/GoogleDrive")
        selectedGDirectAccount = try c.decodeIfPresent(String.self, forKey: .selectedGDirectAccount)
        useGDirectIPAcceleration = try c.decodeIfPresent(Bool.self, forKey: .useGDirectIPAcceleration) ?? true
        webDAVServerURL = try c.decodeIfPresent(String.self, forKey: .webDAVServerURL) ?? ""
        webDAVUsername = try c.decodeIfPresent(String.self, forKey: .webDAVUsername) ?? ""
        webDAVRemotePath = try c.decodeIfPresent(String.self, forKey: .webDAVRemotePath) ?? "/Charkle"
        localLibraryPath = try c.decodeIfPresent(String.self, forKey: .localLibraryPath) ?? (NSHomeDirectory() + "/Pictures/Charkle")
        autoSyncIntervalSeconds = try c.decodeIfPresent(Int.self, forKey: .autoSyncIntervalSeconds) ?? 120
        syncThumbnails = try c.decodeIfPresent(Bool.self, forKey: .syncThumbnails) ?? true
        syncEmbeddings = try c.decodeIfPresent(Bool.self, forKey: .syncEmbeddings) ?? true
    }

    /// Clean human-readable target path summary for the currently active storage backend.
    public var activeStorageLocationSummary: String {
        switch mode {
        case .directAPIWithGDirect:
            let cleaned = rootFolderName.trimmingCharacters(in: CharacterSet(charactersIn: "/ "))
            return "Google Drive / \(cleaned.isEmpty ? "Charkle" : cleaned)"
        case .webDAV:
            let host = URL(string: webDAVServerURL)?.host() ?? webDAVServerURL
            let cleaned = webDAVRemotePath.trimmingCharacters(in: CharacterSet(charactersIn: "/ "))
            return "WebDAV (\(host.isEmpty ? "未配置" : host)) / \(cleaned.isEmpty ? "Charkle" : cleaned)"
        case .gdirectMount:
            let cleaned = rootFolderName.trimmingCharacters(in: CharacterSet(charactersIn: "/ "))
            return "\(mountPath)/\(cleaned.isEmpty ? "Charkle" : cleaned)"
        case .localOnly:
            return localLibraryPath
        }
    }
}

public struct StorageMigrationReport: Codable, Hashable, Sendable {
    public var sourceMode: DriveTransportMode
    public var targetMode: DriveTransportMode
    public var targetLocation: String
    public var downloadedOriginals: Int
    public var migratedAssets: Int
    public var migratedFolders: Int
    public var migratedBoards: Int
    public var durationSeconds: Double

    public init(
        sourceMode: DriveTransportMode,
        targetMode: DriveTransportMode,
        targetLocation: String,
        downloadedOriginals: Int = 0,
        migratedAssets: Int = 0,
        migratedFolders: Int = 0,
        migratedBoards: Int = 0,
        durationSeconds: Double = 0
    ) {
        self.sourceMode = sourceMode
        self.targetMode = targetMode
        self.targetLocation = targetLocation
        self.downloadedOriginals = downloadedOriginals
        self.migratedAssets = migratedAssets
        self.migratedFolders = migratedFolders
        self.migratedBoards = migratedBoards
        self.durationSeconds = durationSeconds
    }
}

public enum SyncPhase: Codable, Hashable, Sendable {
    case idle
    case scanning
    case uploading(completed: Int, total: Int)
    case downloading(completed: Int, total: Int)
    case merging
    case error(String)
}

public struct SyncStatus: Codable, Hashable, Sendable {
    public var phase: SyncPhase
    public var lastSyncedAt: Date?
    public var pendingOpCount: Int
    public var account: DriveAccountInfo?
    public var activeMode: DriveTransportMode
    public var lastError: String?

    public init(
        phase: SyncPhase = .idle,
        lastSyncedAt: Date? = nil,
        pendingOpCount: Int = 0,
        account: DriveAccountInfo? = nil,
        activeMode: DriveTransportMode = .localOnly,
        lastError: String? = nil
    ) {
        self.phase = phase
        self.lastSyncedAt = lastSyncedAt
        self.pendingOpCount = pendingOpCount
        self.account = account
        self.activeMode = activeMode
        self.lastError = lastError
    }
}

public struct SyncReport: Codable, Hashable, Sendable {
    public var uploadedOps: Int
    public var downloadedOps: Int
    public var discoveredRemoteAssets: Int
    public var updatedBoards: Int
    public var reconciledRenames: Int
    public var durationSeconds: Double

    public init(
        uploadedOps: Int = 0,
        downloadedOps: Int = 0,
        discoveredRemoteAssets: Int = 0,
        updatedBoards: Int = 0,
        reconciledRenames: Int = 0,
        durationSeconds: Double = 0
    ) {
        self.uploadedOps = uploadedOps
        self.downloadedOps = downloadedOps
        self.discoveredRemoteAssets = discoveredRemoteAssets
        self.updatedBoards = updatedBoards
        self.reconciledRenames = reconciledRenames
        self.durationSeconds = durationSeconds
    }
}

public struct RemoteDriveFile: Codable, Hashable, Sendable {
    public static let folderMimeType = "application/vnd.google-apps.folder"

    public let id: String
    public let name: String
    public let mimeType: String
    public let size: Int64?
    public let modifiedTime: Date?
    public let md5Checksum: String?
    public let parents: [String]
    public let trashed: Bool
    public let webViewLink: String?

    public var isFolder: Bool { mimeType == Self.folderMimeType }

    public init(
        id: String,
        name: String,
        mimeType: String,
        size: Int64? = nil,
        modifiedTime: Date? = nil,
        md5Checksum: String? = nil,
        parents: [String] = [],
        trashed: Bool = false,
        webViewLink: String? = nil
    ) {
        self.id = id
        self.name = name
        self.mimeType = mimeType
        self.size = size
        self.modifiedTime = modifiedTime
        self.md5Checksum = md5Checksum
        self.parents = parents
        self.trashed = trashed
        self.webViewLink = webViewLink
    }
}

public struct DriveChange: Codable, Hashable, Sendable {
    public let fileID: String
    public let removed: Bool
    public let file: RemoteDriveFile?

    public init(fileID: String, removed: Bool, file: RemoteDriveFile?) {
        self.fileID = fileID
        self.removed = removed
        self.file = file
    }
}

public struct DriveChangePage: Codable, Hashable, Sendable {
    public let changes: [DriveChange]
    public let nextPageToken: String?
    public let newStartPageToken: String?

    public init(changes: [DriveChange], nextPageToken: String? = nil, newStartPageToken: String? = nil) {
        self.changes = changes
        self.nextPageToken = nextPageToken
        self.newStartPageToken = newStartPageToken
    }
}

public enum DriveTransportError: Error, LocalizedError, Sendable {
    case notConfigured(String)
    case authenticationRequired(String)
    case mountPathUnavailable(String)
    case gdirectNotFound
    case commandFailed(command: String, stderr: String, exitCode: Int32)
    case httpError(statusCode: Int, message: String)
    case fileNotFound(String)
    case invalidResponse(String)

    public var errorDescription: String? {
        switch self {
        case .notConfigured(let msg): "存储或同步尚未配置：\(msg)"
        case .authenticationRequired(let msg): "需要登录授权：\(msg)"
        case .mountPathUnavailable(let msg): "目标目录不可用：\(msg)"
        case .gdirectNotFound: "未找到本机 gdirect 可执行文件。"
        case .commandFailed(let cmd, let stderr, let code): "命令 `\(cmd)` 失败 (exit \(code))：\(stderr)"
        case .httpError(let code, let msg): "云端请求失败 (HTTP \(code))：\(msg)"
        case .fileNotFound(let id): "远端文件不存在：\(id)"
        case .invalidResponse(let detail): "响应解析失败：\(detail)"
        }
    }
}

/// Primary transport seam implemented by DirectAPITransport, MountedVolumeTransport, and InMemoryDriveTransport.
public protocol DriveTransport: Sendable {
    var displayName: String { get }

    func accountInfo() async throws -> DriveAccountInfo
    func fetchStartPageToken() async throws -> String
    func listChanges(pageToken: String) async throws -> DriveChangePage
    func findOrCreateFolder(named name: String, parentID: String) async throws -> RemoteDriveFile
    func listFiles(inFolderID folderID: String) async throws -> [RemoteDriveFile]
    func downloadData(fileID: String) async throws -> Data
    func downloadFile(fileID: String, to destinationURL: URL) async throws
    func uploadData(
        _ data: Data,
        name: String,
        mimeType: String,
        parentID: String,
        existingFileID: String?
    ) async throws -> RemoteDriveFile
    func uploadFile(
        from localURL: URL,
        name: String,
        mimeType: String,
        parentID: String,
        existingFileID: String?
    ) async throws -> RemoteDriveFile
    func moveFile(
        fileID: String,
        fromParentID: String?,
        toParentID: String,
        newName: String?
    ) async throws -> RemoteDriveFile
    func trashFile(fileID: String) async throws
}
