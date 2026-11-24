import Darwin
import Foundation

public final actor MountedVolumeTransport: DriveTransport {
    public nonisolated let displayName: String
    private let mount: URL
    private let rootSegments: [String]
    private let accountEmail: String?
    private let requireDedicatedMount: Bool
    private var locations: [String: URL] = [:]
    private var lastTrashPrunedAt: Date?

    private var libraryRootURL: URL {
        rootSegments.reduce(mount) { $0.appending(path: $1, directoryHint: .isDirectory) }
    }

    public init(
        mountPath: String,
        rootFolderName: String = "Charkle",
        accountEmail: String? = nil,
        requireDedicatedMount: Bool = true
    ) {
        mount = URL(fileURLWithPath: (mountPath as NSString).expandingTildeInPath, isDirectory: true).standardizedFileURL
        let segments = rootFolderName
            .split(separator: "/")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty && $0 != "." && $0 != ".." }
        rootSegments = segments.isEmpty ? ["Charkle"] : segments
        self.accountEmail = accountEmail
        self.requireDedicatedMount = requireDedicatedMount
        self.displayName = requireDedicatedMount ? "gdirect mount" : "本地文件夹"
    }

    public func accountInfo() throws -> DriveAccountInfo {
        try verifyMount()
        let values = try? mount.resourceValues(forKeys: [.volumeTotalCapacityKey, .volumeAvailableCapacityKey])
        let used: Int64? = if let total = values?.volumeTotalCapacity, let free = values?.volumeAvailableCapacity {
            Int64(max(0, total - free))
        } else { nil }
        let label = accountEmail ?? (requireDedicatedMount ? "Mounted Drive" : mount.appending(path: rootSegments.joined(separator: "/")).path)
        return DriveAccountInfo(email: label, storageUsedBytes: used,
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
        let followRootLink = !requireDedicatedMount && isRootSegmentPath(path)
        if GDirectIntegration.statInfo(path, followLinks: followRootLink) == nil {
            do { try FileManager.default.createDirectory(at: path, withIntermediateDirectories: false) }
            catch where GDirectIntegration.statInfo(path, followLinks: followRootLink) != nil { /* another device created it */ }
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
        if existingFileID == nil {
            try DriveFiles.writeRawBytes(data, to: destination, removeOnFailure: true)
        } else {
            // Write to a sibling temp file first so mid-write NFS/disk failures never truncate live metadata blobs.
            let fm = FileManager.default
            let temporary = destination.deletingLastPathComponent().appending(path: ".charkle-write-" + UUID().uuidString)
            try DriveFiles.writeRawBytes(data, to: temporary, removeOnFailure: true)
            defer { try? fm.removeItem(at: temporary) }
            if fm.fileExists(atPath: destination.path) {
                do {
                    _ = try fm.replaceItemAt(destination, withItemAt: temporary, options: .usingNewMetadataOnly)
                } catch {
                    try? fm.removeItem(at: destination)
                    try fm.moveItem(at: temporary, to: destination)
                }
            } else {
                try fm.moveItem(at: temporary, to: destination)
            }
        }
        return try metadata(destination, parentID: parentID)
    }

    public func uploadFile(from localURL: URL, name: String, mimeType: String, parentID: String,
                           existingFileID: String?) throws -> RemoteDriveFile {
        let destination = try uploadPath(name: name, parentID: parentID, existingFileID: existingFileID)
        try DriveFiles.writeStream(from: localURL, to: destination, removeOnFailure: existingFileID == nil)
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
        if !requireDedicatedMount {
            try FileManager.default.removeItem(at: url)
            locations.removeValue(forKey: fileID)
            return
        }
        var parentID = DriveFiles.rootID
        for segment in rootSegments {
            parentID = try findOrCreateFolder(named: segment, parentID: parentID).id
        }
        let metadata = try findOrCreateFolder(named: ".charkle", parentID: parentID)
        let trash = try findOrCreateFolder(named: "trash", parentID: metadata.id)
        do {
            _ = try moveFile(fileID: fileID, fromParentID: nil, toParentID: trash.id,
                             newName: UUID().uuidString + "-" + url.lastPathComponent)
        } catch {
            try FileManager.default.removeItem(at: url)
        }
        locations.removeValue(forKey: fileID)
        if let trashURL = locations[trash.id] {
            pruneOldTrashEntriesIfNeeded(in: trashURL)
        }
    }

    private func pruneOldTrashEntriesIfNeeded(in trashURL: URL) {
        let now = Date()
        if let last = lastTrashPrunedAt, now.timeIntervalSince(last) < 3600 { return }
        lastTrashPrunedAt = now
        let cutoff = now.addingTimeInterval(-7 * 86_400)
        guard let items = try? FileManager.default.contentsOfDirectory(
            at: trashURL,
            includingPropertiesForKeys: [.contentModificationDateKey]
        ) else { return }
        for item in items {
            let modified = (try? item.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantFuture
            if modified < cutoff {
                try? FileManager.default.removeItem(at: item)
            }
        }
    }

    private func uploadPath(name: String, parentID: String, existingFileID: String?) throws -> URL {
        try DriveFiles.validateName(name)
        let parent = try locate(parentID)
        let target = parent.appending(path: name)
        try verifyMount()
        if let existingFileID {
            let existing = try locate(existingFileID)
            guard existing.standardizedFileURL.path == target.standardizedFileURL.path else {
                throw DriveTransportError.invalidResponse("Mounted upload target changed.")
            }
        } else if GDirectIntegration.statInfo(target, followLinks: false) != nil {
            throw DriveTransportError.fileAlreadyExists(name)
        }
        return target
    }

    private func verifyMount() throws {
        if requireDedicatedMount {
            guard GDirectIntegration.isMountActive(at: mount.path),
                  let info = GDirectIntegration.statInfo(mount, followLinks: false), info.st_mode & S_IFMT == S_IFDIR else {
                throw DriveTransportError.mountPathUnavailable(mount.path)
            }
        } else {
            if GDirectIntegration.statInfo(mount, followLinks: true) == nil {
                try FileManager.default.createDirectory(at: mount, withIntermediateDirectories: true)
            }
            guard let info = GDirectIntegration.statInfo(mount, followLinks: true), info.st_mode & S_IFMT == S_IFDIR else {
                throw DriveTransportError.mountPathUnavailable(mount.path)
            }
        }
    }

    static let pathIDPrefix = "mounted-path:"

    private func isRootSegmentPath(_ url: URL) -> Bool {
        let targetPath = url.standardizedFileURL.path
        var cursor = mount
        for seg in rootSegments {
            cursor = cursor.appending(path: seg, directoryHint: .isDirectory)
            if cursor.standardizedFileURL.path == targetPath {
                return true
            }
        }
        return false
    }

    private func validatedRelativePath(for url: URL) -> (attrs: stat, relativePath: String)? {
        let followLink = !requireDedicatedMount && isRootSegmentPath(url)
        guard let attrs = GDirectIntegration.statInfo(url, followLinks: followLink),
              [S_IFDIR, S_IFREG].contains(attrs.st_mode & S_IFMT) else {
            return nil
        }

        if requireDedicatedMount {
            guard let mounted = GDirectIntegration.statInfo(mount),
                  attrs.st_dev == mounted.st_dev else {
                return nil
            }
            let resolvedMount = mount.resolvingSymlinksInPath().path
            let resolvedURL = url.resolvingSymlinksInPath().path
            let prefix = resolvedMount.hasSuffix("/") ? resolvedMount : resolvedMount + "/"
            guard resolvedURL.hasPrefix(prefix) else { return nil }
            return (attrs, String(resolvedURL.dropFirst(prefix.count)))
        }

        // Pure local folder mode: allow external volume roots (e.g. `/Volumes/MySSD` where `/Volumes`
        // and `/Volumes/MySSD` have different `st_dev`) and symlinked parent/root directories, while
        // still rejecting symlinks inside the library root.
        let stdMount = mount.standardizedFileURL.path
        let stdPrefix = stdMount.hasSuffix("/") ? stdMount : stdMount + "/"
        let stdURL = url.standardizedFileURL.path
        guard stdURL.hasPrefix(stdPrefix) else { return nil }

        let resolvedMount = mount.resolvingSymlinksInPath().path
        let resolvedMountPrefix = resolvedMount.hasSuffix("/") ? resolvedMount : resolvedMount + "/"
        let resolvedRoot = libraryRootURL.resolvingSymlinksInPath().path
        let resolvedRootPrefix = resolvedRoot.hasSuffix("/") ? resolvedRoot : resolvedRoot + "/"
        let resolvedURL = url.resolvingSymlinksInPath().path

        if followLink {
            guard resolvedURL == resolvedRoot
                || resolvedURL.hasPrefix(resolvedMountPrefix)
                || resolvedRoot.hasPrefix(resolvedURL + "/") else {
                return nil
            }
            return (attrs, String(stdURL.dropFirst(stdPrefix.count)))
        }

        guard let rootInfo = GDirectIntegration.statInfo(libraryRootURL, followLinks: true)
            ?? GDirectIntegration.statInfo(mount, followLinks: true),
              attrs.st_dev == rootInfo.st_dev else {
            return nil
        }
        guard resolvedURL.hasPrefix(resolvedRootPrefix) || resolvedURL.hasPrefix(resolvedMountPrefix) else {
            return nil
        }
        let relative = resolvedURL.hasPrefix(resolvedMountPrefix)
            ? String(resolvedURL.dropFirst(resolvedMountPrefix.count))
            : String(stdURL.dropFirst(stdPrefix.count))
        return (attrs, relative)
    }

    private func locate(_ id: String) throws -> URL {
        try verifyMount()
        if id == DriveFiles.rootID { return mount }
        if id.hasPrefix(Self.pathIDPrefix) {
            let relPath = String(id.dropFirst(Self.pathIDPrefix.count))
            let segments = relPath.split(separator: "/").map(String.init)
            guard !segments.isEmpty else { throw DriveTransportError.fileNotFound(id) }
            var candidate = mount
            for seg in segments {
                try DriveFiles.validateName(seg)
                candidate = candidate.appending(path: seg)
            }
            guard validatedRelativePath(for: candidate) != nil else {
                throw DriveTransportError.fileNotFound(id)
            }
            locations[id] = candidate
            return candidate
        }
        if let cached = locations[id], (try? metadata(cached, parentID: "").id) == id { return cached }
        _ = try snapshot(includeMetadata: false)
        if let url = locations[id] { return url }
        _ = try snapshot(includeMetadata: true)
        if let url = locations[id] { return url }
        throw DriveTransportError.fileNotFound(id)
    }

    private func encode(_ snapshot: [String: RemoteDriveFile]) throws -> String {
        try JSONEncoder().encode(snapshot).base64EncodedString()
    }

    private func snapshot(includeMetadata: Bool = false) throws -> [String: RemoteDriveFile] {
        try verifyMount()
        var url = mount
        var parentID = DriveFiles.rootID
        var result: [String: RemoteDriveFile] = [:]
        var rootEntry: RemoteDriveFile?
        locations.removeAll()
        for segment in rootSegments {
            try DriveFiles.validateName(segment)
            url = url.appending(path: segment, directoryHint: .isDirectory)
            guard GDirectIntegration.statInfo(url, followLinks: !requireDedicatedMount) != nil else { return result }
            let entry = try metadata(url, parentID: parentID)
            parentID = entry.id
            rootEntry = entry
        }
        guard let root = rootEntry else {
            return result
        }
        var queue = [root]
        var index = 0
        while index < queue.count {
            let file = queue[index]
            index += 1
            guard result[file.id] == nil else { continue }
            result[file.id] = file
            if file.isFolder, let folder = locations[file.id] {
                if !includeMetadata && file.id != root.id && file.name.hasPrefix(".") {
                    continue
                }
                queue += try children(of: folder, parent: file.id)
            }
        }
        return result
    }

    private func children(of directory: URL, parent: String) throws -> [RemoteDriveFile] {
        try verifyMount()
        return try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
            .filter { url in
                let name = url.lastPathComponent
                return name != ".DS_Store" && !name.hasPrefix("._") && !name.hasPrefix(".charkle-write-")
            }
            .compactMap { url in
                guard let info = GDirectIntegration.statInfo(url, followLinks: false),
                      [S_IFDIR, S_IFREG].contains(info.st_mode & S_IFMT) else { return nil }
                return try metadata(url, parentID: parent)
            }.sorted { ($0.name, $0.id) < ($1.name, $1.id) }
    }

    private func metadata(_ url: URL, parentID: String) throws -> RemoteDriveFile {
        guard let (attrs, relativePath) = validatedRelativePath(for: url) else {
            throw DriveTransportError.fileNotFound(url.lastPathComponent)
        }
        let folder = attrs.st_mode & S_IFMT == S_IFDIR
        // Use normalized mount-relative path instead of ephemeral `st_ino` (which rclone nfsmount
        // rotates whenever its 1-minute dir-cache expires or the drive remounts).
        let id = Self.pathIDPrefix + relativePath
        locations[id] = url
        let modified = Date(timeIntervalSince1970: Double(attrs.st_mtimespec.tv_sec) + Double(attrs.st_mtimespec.tv_nsec) / 1e9)
        return RemoteDriveFile(id: id, name: url.lastPathComponent,
                               mimeType: folder ? RemoteDriveFile.folderMimeType : MediaPipeline.mimeType(fileName: url.lastPathComponent),
                               size: folder ? nil : attrs.st_size, modifiedTime: modified, parents: [parentID])
    }
}
