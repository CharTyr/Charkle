import Darwin
import Foundation

public final actor MountedVolumeTransport: DriveTransport {
    public nonisolated let displayName = "gdirect mount"
    private let mount: URL
    private let rootName: String
    private let accountEmail: String?
    private var locations: [String: URL] = [:]

    public init(mountPath: String, rootFolderName: String = "Charkle", accountEmail: String? = nil) {
        mount = URL(fileURLWithPath: (mountPath as NSString).expandingTildeInPath, isDirectory: true).standardizedFileURL
        rootName = rootFolderName
        self.accountEmail = accountEmail
    }

    public func accountInfo() throws -> DriveAccountInfo {
        try verifyMount()
        let values = try? mount.resourceValues(forKeys: [.volumeTotalCapacityKey, .volumeAvailableCapacityKey])
        let used: Int64? = if let total = values?.volumeTotalCapacity, let free = values?.volumeAvailableCapacity {
            Int64(max(0, total - free))
        } else { nil }
        return DriveAccountInfo(email: accountEmail ?? "Mounted Drive", storageUsedBytes: used,
                                storageLimitBytes: values?.volumeTotalCapacity.map(Int64.init), source: displayName)
    }

    public func fetchStartPageToken() throws -> String { try encode(snapshot()) }

    public func listChanges(pageToken: String) throws -> DriveChangePage {
        guard let data = Data(base64Encoded: pageToken),
              let previous = try? JSONDecoder().decode([String: RemoteDriveFile].self, from: data) else {
            throw DriveTransportError.httpError(statusCode: 410, message: "Invalid mounted-volume cursor")
        }
        let current = try snapshot()
        let changes = Set(previous.keys).union(current.keys).sorted().compactMap { id -> DriveChange? in
            guard previous[id] != current[id] else { return nil }
            return DriveChange(fileID: id, removed: current[id] == nil, file: current[id])
        }
        return DriveChangePage(changes: changes, newStartPageToken: try encode(current))
    }

    public func findOrCreateFolder(named name: String, parentID: String) throws -> RemoteDriveFile {
        try DriveFiles.validateName(name)
        let path = try locate(parentID).appending(path: name, directoryHint: .isDirectory)
        try verifyMount()
        if GDirectIntegration.statInfo(path, followLinks: false) == nil {
            do { try FileManager.default.createDirectory(at: path, withIntermediateDirectories: false) }
            catch where GDirectIntegration.statInfo(path, followLinks: false) != nil { /* another device created it */ }
        }
        let file = try metadata(path, parentID: parentID)
        guard file.isFolder else { throw DriveTransportError.invalidResponse("Drive name is already used by a file: \(name)") }
        return file
    }

    public func listFiles(inFolderID folderID: String) throws -> [RemoteDriveFile] {
        try children(of: locate(folderID), parent: folderID)
    }

    public func downloadData(fileID: String) throws -> Data { try Data(contentsOf: locate(fileID)) }

    public func downloadFile(fileID: String, to destinationURL: URL) throws {
        try DriveFiles.writeFile(locate(fileID), to: destinationURL)
    }

    public func uploadData(_ data: Data, name: String, mimeType: String, parentID: String,
                           existingFileID: String?) throws -> RemoteDriveFile {
        let destination = try uploadPath(name: name, parentID: parentID, existingFileID: existingFileID)
        try data.write(to: destination, options: existingFileID == nil ? .withoutOverwriting : .atomic)
        return try metadata(destination, parentID: parentID)
    }

    public func uploadFile(from localURL: URL, name: String, mimeType: String, parentID: String,
                           existingFileID: String?) throws -> RemoteDriveFile {
        let destination = try uploadPath(name: name, parentID: parentID, existingFileID: existingFileID)
        if existingFileID == nil {
            try FileManager.default.copyItem(at: localURL, to: destination)
        } else {
            try DriveFiles.writeFile(localURL, to: destination)
        }
        return try metadata(destination, parentID: parentID)
    }

    public func moveFile(fileID: String, fromParentID: String?, toParentID: String, newName: String?) throws -> RemoteDriveFile {
        let source = try locate(fileID)
        let folder = try locate(toParentID)
        let name = newName ?? source.lastPathComponent
        try DriveFiles.validateName(name)
        let target = folder.appending(path: name)
        try verifyMount()
        if source.path != target.path { try FileManager.default.moveItem(at: source, to: target) }
        return try metadata(target, parentID: toParentID)
    }

    public func trashFile(fileID: String) throws {
        let url = try locate(fileID)
        let root = try findOrCreateFolder(named: rootName, parentID: DriveFiles.rootID)
        let metadata = try findOrCreateFolder(named: ".charkle", parentID: root.id)
        let trash = try findOrCreateFolder(named: "trash", parentID: metadata.id)
        _ = try moveFile(fileID: fileID, fromParentID: nil, toParentID: trash.id,
                         newName: UUID().uuidString + "-" + url.lastPathComponent)
        locations.removeValue(forKey: fileID)
    }

    private func uploadPath(name: String, parentID: String, existingFileID: String?) throws -> URL {
        try DriveFiles.validateName(name)
        let parent = try locate(parentID)
        let target = parent.appending(path: name)
        try verifyMount()
        if let existingFileID {
            let existing = try locate(existingFileID)
            guard existing.path == target.path else { throw DriveTransportError.invalidResponse("Mounted upload target changed.") }
        } else if GDirectIntegration.statInfo(target, followLinks: false) != nil {
            throw DriveTransportError.invalidResponse("Mounted upload target already exists.")
        }
        return target
    }

    private func verifyMount() throws {
        guard GDirectIntegration.isMountActive(at: mount.path),
              let info = GDirectIntegration.statInfo(mount, followLinks: false), info.st_mode & S_IFMT == S_IFDIR else {
            throw DriveTransportError.mountPathUnavailable(mount.path)
        }
    }

    private func locate(_ id: String) throws -> URL {
        try verifyMount()
        if id == DriveFiles.rootID { return mount }
        if let cached = locations[id], (try? metadata(cached, parentID: "").id) == id { return cached }
        _ = try snapshot()
        if let url = locations[id] { return url }
        throw DriveTransportError.fileNotFound(id)
    }

    private func encode(_ snapshot: [String: RemoteDriveFile]) throws -> String {
        try JSONEncoder().encode(snapshot).base64EncodedString()
    }

    private func snapshot() throws -> [String: RemoteDriveFile] {
        try verifyMount()
        try DriveFiles.validateName(rootName)
        let url = mount.appending(path: rootName, directoryHint: .isDirectory)
        var result: [String: RemoteDriveFile] = [:]
        locations.removeAll()
        guard GDirectIntegration.statInfo(url, followLinks: false) != nil else { return result }
        let root = try metadata(url, parentID: DriveFiles.rootID)
        var queue = [root]
        var index = 0
        while index < queue.count {
            let file = queue[index]
            index += 1
            guard result[file.id] == nil else { continue }
            result[file.id] = file
            if file.isFolder, let folder = locations[file.id] { queue += try children(of: folder, parent: file.id) }
        }
        return result
    }

    private func children(of directory: URL, parent: String) throws -> [RemoteDriveFile] {
        try verifyMount()
        return try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
            .filter { $0.lastPathComponent != ".DS_Store" && !$0.lastPathComponent.hasPrefix(".charkle-write-") }
            .compactMap { url in
                guard let info = GDirectIntegration.statInfo(url, followLinks: false),
                      [S_IFDIR, S_IFREG].contains(info.st_mode & S_IFMT) else { return nil }
                return try metadata(url, parentID: parent)
            }.sorted { ($0.name, $0.id) < ($1.name, $1.id) }
    }

    private func metadata(_ url: URL, parentID: String) throws -> RemoteDriveFile {
        guard let attrs = GDirectIntegration.statInfo(url, followLinks: false),
              let mounted = GDirectIntegration.statInfo(mount), attrs.st_dev == mounted.st_dev,
              [S_IFDIR, S_IFREG].contains(attrs.st_mode & S_IFMT),
              url.resolvingSymlinksInPath().path.hasPrefix(mount.resolvingSymlinksInPath().path + "/") else {
            throw DriveTransportError.fileNotFound(url.lastPathComponent)
        }
        let folder = attrs.st_mode & S_IFMT == S_IFDIR
        let id = "mounted-\(attrs.st_ino)"
        locations[id] = url
        let modified = Date(timeIntervalSince1970: Double(attrs.st_mtimespec.tv_sec) + Double(attrs.st_mtimespec.tv_nsec) / 1e9)
        return RemoteDriveFile(id: id, name: url.lastPathComponent,
                               mimeType: folder ? RemoteDriveFile.folderMimeType : MediaPipeline.mimeType(fileName: url.lastPathComponent),
                               size: folder ? nil : attrs.st_size, modifiedTime: modified, parents: [parentID])
    }
}
