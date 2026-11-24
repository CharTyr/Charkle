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
    /// Optional Google Drive shared folder URL or folder ID (e.g. `https://drive.google.com/drive/folders/<id>` or raw `<id>`)
    /// so multiple collaborators can share and co-edit the same library folder.
    public var sharedFolderURLOrID: String
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
        sharedFolderURLOrID: String = "",
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
        self.sharedFolderURLOrID = sharedFolderURLOrID
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
        case mode, rootFolderName, sharedFolderURLOrID, mountPath, selectedGDirectAccount, useGDirectIPAcceleration
        case webDAVServerURL, webDAVUsername, webDAVRemotePath, localLibraryPath
        case autoSyncIntervalSeconds, syncThumbnails, syncEmbeddings
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        mode = try c.decodeIfPresent(DriveTransportMode.self, forKey: .mode) ?? .directAPIWithGDirect
        rootFolderName = try c.decodeIfPresent(String.self, forKey: .rootFolderName) ?? "Charkle"
        sharedFolderURLOrID = try c.decodeIfPresent(String.self, forKey: .sharedFolderURLOrID) ?? ""
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

    /// Parses a Google Drive folder URL (`.../folders/<id>`, `...open?id=<id>`) or raw folder ID.
    public nonisolated static func extractGoogleDriveFolderID(from raw: String) -> String? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        func isValidDriveID(_ candidate: String) -> Bool {
            candidate.count >= 4 && candidate.count <= 128 && candidate.utf8.allSatisfy {
                (48...57).contains($0) || (65...90).contains($0) || (97...122).contains($0) || $0 == 45 || $0 == 95
            }
        }

        if let url = URL(string: trimmed), let host = url.host()?.lowercased(), host.contains("google.com") {
            let parts = url.pathComponents
            if let idx = parts.firstIndex(of: "folders"), parts.indices.contains(idx + 1) {
                let candidate = parts[idx + 1]
                if isValidDriveID(candidate) { return candidate }
            }
            if let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems,
               let idVal = items.first(where: { $0.name == "id" })?.value,
               isValidDriveID(idVal) {
                return idVal
            }
            return nil
        }

        if !trimmed.contains("/"), !trimmed.contains(" "), isValidDriveID(trimmed) {
            return trimmed
        }
        return nil
    }

    public nonisolated var resolvedSharedFolderID: String? {
        Self.extractGoogleDriveFolderID(from: sharedFolderURLOrID)
    }

    /// Clean human-readable target path summary for the currently active storage backend.
    public var activeStorageLocationSummary: String {
        switch mode {
        case .directAPIWithGDirect:
            if let sharedID = resolvedSharedFolderID {
                let shortID = String(sharedID.prefix(10))
                return "Google Drive 共享目录 (\(shortID)…)"
            }
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
    /// Short live description of the active sync step or filename being transferred.
    public var currentDetail: String?
    /// Normalized overall progress in `0.0...1.0` while syncing (`nil` when idle or indeterminate).
    public var progressFraction: Double?

    public var isSyncing: Bool {
        switch phase {
        case .scanning, .uploading, .downloading, .merging:
            return true
        case .idle, .error:
            return false
        }
    }

    public var localizedPhaseTitle: String {
        switch phase {
        case .idle:
            return lastSyncedAt == nil ? "等待同步" : "已同步"
        case .scanning:
            return "正在扫描云端目录"
        case .uploading(let done, let total):
            return total > 0 ? "正在上传 (\(done)/\(total))" : "正在上传"
        case .downloading(let done, let total):
            return total > 0 ? "正在拉取 (\(done)/\(total))" : "正在拉取"
        case .merging:
            return "正在整理与写入索引"
        case .error:
            return "同步遇到异常"
        }
    }

    public init(
        phase: SyncPhase = .idle,
        lastSyncedAt: Date? = nil,
        pendingOpCount: Int = 0,
        account: DriveAccountInfo? = nil,
        activeMode: DriveTransportMode = .localOnly,
        lastError: String? = nil,
        currentDetail: String? = nil,
        progressFraction: Double? = nil
    ) {
        self.phase = phase
        self.lastSyncedAt = lastSyncedAt
        self.pendingOpCount = pendingOpCount
        self.account = account
        self.activeMode = activeMode
        self.lastError = lastError
        self.currentDetail = currentDetail
        self.progressFraction = progressFraction
    }

    private enum CodingKeys: String, CodingKey {
        case phase, lastSyncedAt, pendingOpCount, account, activeMode, lastError, currentDetail, progressFraction
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        phase = try c.decodeIfPresent(SyncPhase.self, forKey: .phase) ?? .idle
        lastSyncedAt = try c.decodeIfPresent(Date.self, forKey: .lastSyncedAt)
        pendingOpCount = try c.decodeIfPresent(Int.self, forKey: .pendingOpCount) ?? 0
        account = try c.decodeIfPresent(DriveAccountInfo.self, forKey: .account)
        activeMode = try c.decodeIfPresent(DriveTransportMode.self, forKey: .activeMode) ?? .localOnly
        lastError = try c.decodeIfPresent(String.self, forKey: .lastError)
        currentDetail = try c.decodeIfPresent(String.self, forKey: .currentDetail)
        progressFraction = try c.decodeIfPresent(Double.self, forKey: .progressFraction)
    }
}

public struct SyncReport: Codable, Hashable, Sendable {
    public var uploadedOps: Int
    public var downloadedOps: Int
    public var discoveredRemoteAssets: Int
    public var discoveredAssetIDs: [UUID]
    public var updatedBoards: Int
    public var reconciledRenames: Int
    public var durationSeconds: Double

    public var hasVisibleLibraryChanges: Bool {
        discoveredRemoteAssets > 0 || downloadedOps > 0 || reconciledRenames > 0 || updatedBoards > 0
    }

    public init(
        uploadedOps: Int = 0,
        downloadedOps: Int = 0,
        discoveredRemoteAssets: Int = 0,
        discoveredAssetIDs: [UUID] = [],
        updatedBoards: Int = 0,
        reconciledRenames: Int = 0,
        durationSeconds: Double = 0
    ) {
        self.uploadedOps = uploadedOps
        self.downloadedOps = downloadedOps
        self.discoveredRemoteAssets = discoveredRemoteAssets
        self.discoveredAssetIDs = discoveredAssetIDs
        self.updatedBoards = updatedBoards
        self.reconciledRenames = reconciledRenames
        self.durationSeconds = durationSeconds
    }

    private enum CodingKeys: String, CodingKey {
        case uploadedOps, downloadedOps, discoveredRemoteAssets, discoveredAssetIDs
        case updatedBoards, reconciledRenames, durationSeconds
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        uploadedOps = try c.decodeIfPresent(Int.self, forKey: .uploadedOps) ?? 0
        downloadedOps = try c.decodeIfPresent(Int.self, forKey: .downloadedOps) ?? 0
        discoveredRemoteAssets = try c.decodeIfPresent(Int.self, forKey: .discoveredRemoteAssets) ?? 0
        discoveredAssetIDs = try c.decodeIfPresent([UUID].self, forKey: .discoveredAssetIDs) ?? []
        updatedBoards = try c.decodeIfPresent(Int.self, forKey: .updatedBoards) ?? 0
        reconciledRenames = try c.decodeIfPresent(Int.self, forKey: .reconciledRenames) ?? 0
        durationSeconds = try c.decodeIfPresent(Double.self, forKey: .durationSeconds) ?? 0
    }
}

public nonisolated enum CharkleSyncNotifications {
    public static let didCompleteSync = Notification.Name("com.charkle.sync.didCompleteSync")
    public static let didUpdateSyncStatus = Notification.Name("com.charkle.sync.didUpdateSyncStatus")
    /// Posted during long syncs (especially fresh installs) as soon as metadata/folders/boards
    /// or batches of remote thumbnails land locally so the gallery renders progressively instead
    /// of waiting for full-resolution originals or the entire sync cycle to finish.
    public static let didSyncProgressively = Notification.Name("com.charkle.sync.didSyncProgressively")
    public static let statusDataKey = "statusData"
    public static let discoveredCountKey = "discoveredCount"
    public static let downloadedOpsKey = "downloadedOps"
    public static let reconciledRenamesKey = "reconciledRenames"
    public static let updatedBoardsKey = "updatedBoards"
    public static let progressKindKey = "progressKind"
    public static let progressKindMetadata = "metadata"
    public static let progressKindThumbnails = "thumbnails"
    public static let thumbnailAssetIDsKey = "thumbnailAssetIDs"
    public static let hasBoardsKey = "hasBoards"
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
    /// Transient server-generated thumbnail URL (e.g. Google Drive `thumbnailLink`).
    /// Intentionally excluded from `Codable`, `Equatable`, and `Hashable` because CDN tokens rotate across listings.
    public let thumbnailLink: String?

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
        webViewLink: String? = nil,
        thumbnailLink: String? = nil
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
        self.thumbnailLink = thumbnailLink
    }

    private enum CodingKeys: String, CodingKey {
        case id, name, mimeType, size, modifiedTime, md5Checksum, parents, trashed, webViewLink
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        name = try c.decode(String.self, forKey: .name)
        mimeType = try c.decode(String.self, forKey: .mimeType)
        size = try c.decodeIfPresent(Int64.self, forKey: .size)
        modifiedTime = try c.decodeIfPresent(Date.self, forKey: .modifiedTime)
        md5Checksum = try c.decodeIfPresent(String.self, forKey: .md5Checksum)
        parents = try c.decodeIfPresent([String].self, forKey: .parents) ?? []
        trashed = try c.decodeIfPresent(Bool.self, forKey: .trashed) ?? false
        webViewLink = try c.decodeIfPresent(String.self, forKey: .webViewLink)
        thumbnailLink = nil
    }

    public func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(name, forKey: .name)
        try c.encode(mimeType, forKey: .mimeType)
        try c.encodeIfPresent(size, forKey: .size)
        try c.encodeIfPresent(modifiedTime, forKey: .modifiedTime)
        try c.encodeIfPresent(md5Checksum, forKey: .md5Checksum)
        try c.encode(parents, forKey: .parents)
        try c.encode(trashed, forKey: .trashed)
        try c.encodeIfPresent(webViewLink, forKey: .webViewLink)
    }

    public static func == (lhs: RemoteDriveFile, rhs: RemoteDriveFile) -> Bool {
        lhs.id == rhs.id
            && lhs.name == rhs.name
            && lhs.mimeType == rhs.mimeType
            && lhs.size == rhs.size
            && lhs.modifiedTime == rhs.modifiedTime
            && lhs.md5Checksum == rhs.md5Checksum
            && lhs.parents == rhs.parents
            && lhs.trashed == rhs.trashed
            && lhs.webViewLink == rhs.webViewLink
    }

    public func hash(into hasher: inout Hasher) {
        hasher.combine(id)
        hasher.combine(name)
        hasher.combine(mimeType)
        hasher.combine(size)
        hasher.combine(modifiedTime)
        hasher.combine(md5Checksum)
        hasher.combine(parents)
        hasher.combine(trashed)
        hasher.combine(webViewLink)
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
    case fileAlreadyExists(String)
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
        case .fileAlreadyExists(let name): "远端已存在同名文件：\(name)"
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
    func downloadFile(_ file: RemoteDriveFile, to destinationURL: URL) async throws
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
    func resolveFolder(id: String) async throws -> RemoteDriveFile
    func listSharedFolders() async throws -> [RemoteDriveFile]
    func downloadThumbnailData(for file: RemoteDriveFile, maxPixelSize: Int) async throws -> Data?
}

public extension DriveTransport {
    func downloadFile(_ file: RemoteDriveFile, to destinationURL: URL) async throws {
        try await downloadFile(fileID: file.id, to: destinationURL)
    }

    func resolveFolder(id: String) async throws -> RemoteDriveFile {
        throw DriveTransportError.notConfigured(
            "\(displayName) 暂不支持通过共享目录链接/ID 直连，请先在设置中「独立登录 Google 账号」，或在 Google Drive 中将该共享目录「添加到云端硬盘快捷方式」后再填写快捷方式路径。"
        )
    }

    func listSharedFolders() async throws -> [RemoteDriveFile] {
        []
    }

    func downloadThumbnailData(for file: RemoteDriveFile, maxPixelSize: Int) async throws -> Data? {
        nil
    }
}
