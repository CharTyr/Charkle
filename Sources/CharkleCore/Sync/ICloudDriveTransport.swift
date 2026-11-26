import Darwin
import Foundation
import UniformTypeIdentifiers

/// Native Apple iCloud Drive `DriveTransport` supporting BOTH macOS and iOS:
/// 1. User-selected iCloud Drive folder via persisted security-scoped bookmark (works seamlessly on iOS
///    including sideloaded builds AND macOS when sharing an exact `iCloud Drive/Charkle` folder).
/// 2. Official Apple iCloud Ubiquity Container (`FileManager.url(forUbiquityContainerIdentifier:)/Documents`).
/// 3. Direct macOS iCloud Drive root (`~/Library/Mobile Documents/com~apple~CloudDocs`).
///
/// Uses `NSFileCoordinator` and automatically triggers + awaits `startDownloadingUbiquitousItem(at:)`
/// whenever iCloud Drive has evicted a file to a `.icloud` placeholder stub.
public final actor ICloudDriveTransport: DriveTransport {
    public nonisolated let displayName: String = "iCloud Drive"
    public static let pathIDPrefix = "icloud-path:"

    private let baseDirectory: URL
    private let rootSegments: [String]
    private let accountLabel: String
    private let securityScopedURL: URL?
    private let didStartSecurityScope: Bool
    private var locations: [String: URL] = [:]

    public init(
        baseDirectory: URL,
        rootFolderName: String = "Charkle",
        accountLabel: String? = nil,
        securityScopedURL: URL? = nil
    ) {
        self.securityScopedURL = securityScopedURL
        if let securityScopedURL {
            self.didStartSecurityScope = securityScopedURL.startAccessingSecurityScopedResource()
        } else {
            self.didStartSecurityScope = false
        }
        self.baseDirectory = baseDirectory.standardizedFileURL
        let segments = rootFolderName
            .split(separator: "/")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty && $0 != "." && $0 != ".." }
        self.rootSegments = segments
        if let accountLabel, !accountLabel.isEmpty {
            self.accountLabel = accountLabel
        } else if segments.isEmpty {
            self.accountLabel = "iCloud Drive / \(baseDirectory.lastPathComponent)"
        } else {
            self.accountLabel = "iCloud Drive / \(segments.joined(separator: "/"))"
        }
    }

    deinit {
        if didStartSecurityScope, let url = securityScopedURL {
            url.stopAccessingSecurityScopedResource()
        }
    }

    // MARK: - Availability & Automatic Resolution (macOS + iOS)

    public nonisolated static func macOSCloudDocsURL() -> URL? {
        #if os(macOS)
        let url = FileManager.default.homeDirectoryForCurrentUser
            .appending(path: "Library/Mobile Documents/com~apple~CloudDocs", directoryHint: .isDirectory)
        var isDir: ObjCBool = false
        if FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir), isDir.boolValue {
            return url
        }
        return nil
        #else
        return nil
        #endif
    }

    public nonisolated static func probeAvailability(containerIdentifier: String? = nil) -> ICloudDriveAvailability {
        let normalizedID: String? = {
            let trimmed = containerIdentifier?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            return trimmed.isEmpty ? nil : trimmed
        }()

        var ubiquityDocsPath: String?
        if let containerURL = FileManager.default.url(forUbiquityContainerIdentifier: normalizedID) {
            let docs = containerURL.appending(path: "Documents", directoryHint: .isDirectory)
            ubiquityDocsPath = docs.path
        }

        let cloudDocsPath = macOSCloudDocsURL()?.path
        let display: String
        if cloudDocsPath != nil {
            display = "iCloud Drive / Charkle"
        } else if ubiquityDocsPath != nil {
            display = "iCloud Drive / Charkle (App 容器)"
        } else {
            display = "通过「文件」选择 iCloud Drive 文件夹"
        }

        return ICloudDriveAvailability(
            isUbiquityContainerAvailable: ubiquityDocsPath != nil,
            ubiquityDocumentsPath: ubiquityDocsPath,
            systemCloudDocsPath: cloudDocsPath,
            defaultDisplayLocation: display
        )
    }

    /// Resolves an `ICloudDriveTransport` from (1) security-scoped bookmark, (2) explicit custom path,
    /// (3) macOS CloudDocs / official Ubiquity container.
    public static func make(
        folderName: String = "Charkle",
        customFolderPath: String = "",
        containerIdentifier: String = "",
        bookmarkData: Data? = nil
    ) throws -> ICloudDriveTransport {
        let trimmedFolder = folderName.trimmingCharacters(in: CharacterSet(charactersIn: "/ "))
        let effectiveFolder = trimmedFolder.isEmpty ? "Charkle" : trimmedFolder

        // 1. Security-scoped bookmark (works identically across iOS Files picker & macOS Open Panel)
        if let bookmarkData {
            var isStale = false
            #if os(macOS)
            let options: URL.BookmarkResolutionOptions = [.withSecurityScope]
            #else
            let options: URL.BookmarkResolutionOptions = []
            #endif
            if let resolved = try? URL(
                resolvingBookmarkData: bookmarkData,
                options: options,
                relativeTo: nil,
                bookmarkDataIsStale: &isStale
            ) {
                let parent = resolved.deletingLastPathComponent()
                let leaf = resolved.lastPathComponent.isEmpty ? effectiveFolder : resolved.lastPathComponent
                return ICloudDriveTransport(
                    baseDirectory: parent,
                    rootFolderName: leaf,
                    accountLabel: "iCloud Drive / \(leaf)",
                    securityScopedURL: resolved
                )
            }
        }

        // 2. Explicit custom filesystem path (macOS direct path inside iCloud Drive)
        let trimmedCustom = customFolderPath.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmedCustom.isEmpty {
            let expanded = URL(fileURLWithPath: (trimmedCustom as NSString).expandingTildeInPath, isDirectory: true)
                .standardizedFileURL
            let parent = expanded.deletingLastPathComponent()
            let leaf = expanded.lastPathComponent.isEmpty ? effectiveFolder : expanded.lastPathComponent
            return ICloudDriveTransport(
                baseDirectory: parent,
                rootFolderName: leaf,
                accountLabel: "iCloud Drive / \(leaf)"
            )
        }

        // 3. macOS native iCloud Drive (`~/Library/Mobile Documents/com~apple~CloudDocs`) — shares exact
        //    visible `iCloud Drive/Charkle` folder with iOS Files picker AND Finder!
        if let cloudDocs = macOSCloudDocsURL() {
            return ICloudDriveTransport(
                baseDirectory: cloudDocs,
                rootFolderName: effectiveFolder,
                accountLabel: "iCloud Drive / \(effectiveFolder)"
            )
        }

        // 4. Official iCloud Ubiquity Container (`Documents/`)
        let trimmedContainer = containerIdentifier.trimmingCharacters(in: .whitespacesAndNewlines)
        if let ubiquity = FileManager.default.url(
            forUbiquityContainerIdentifier: trimmedContainer.isEmpty ? nil : trimmedContainer
        ) {
            let docs = ubiquity.appending(path: "Documents", directoryHint: .isDirectory)
            return ICloudDriveTransport(
                baseDirectory: docs,
                rootFolderName: effectiveFolder,
                accountLabel: "iCloud Drive / \(effectiveFolder)"
            )
        }

        throw DriveTransportError.notConfigured(
            "未检测到自动 iCloud 容器。请在设置中点击「选择 iCloud Drive 文件夹」，在系统「文件」App 中选择 iCloud Drive 内的 Charkle 目录即可与 Mac 双向同步。"
        )
    }

    // MARK: - DriveTransport Conformance

    public func accountInfo() async throws -> DriveAccountInfo {
        try verifyBaseDirectory()
        let values = try? baseDirectory.resourceValues(forKeys: [.volumeTotalCapacityKey, .volumeAvailableCapacityKey])
        let used: Int64? = if let total = values?.volumeTotalCapacity, let free = values?.volumeAvailableCapacity {
            Int64(max(0, total - free))
        } else { nil }
        return DriveAccountInfo(
            email: accountLabel,
            displayName: "iCloud Drive",
            storageUsedBytes: used,
            storageLimitBytes: values?.volumeTotalCapacity.map(Int64.init),
            source: displayName
        )
    }

    public func fetchStartPageToken() async throws -> String {
        try encode(snapshot())
    }

    public func listChanges(pageToken: String) async throws -> DriveChangePage {
        guard let data = Data(base64Encoded: pageToken),
              let previous = try? JSONDecoder().decode([String: RemoteDriveFile].self, from: data) else {
            throw DriveTransportError.httpError(statusCode: 410, message: "Invalid iCloud Drive cursor")
        }
        let current = try snapshot()
        let changes = Set(previous.keys).union(current.keys).sorted().compactMap { id -> DriveChange? in
            guard previous[id] != current[id] else { return nil }
            return DriveChange(fileID: id, removed: current[id] == nil, file: current[id])
        }
        return DriveChangePage(changes: changes, newStartPageToken: try encode(current))
    }

    public func findOrCreateFolder(named name: String, parentID: String) async throws -> RemoteDriveFile {
        try DriveFiles.validateName(name)
        try verifyBaseDirectory()
        let parentURL = try locate(parentID)
        let path = parentURL.appending(path: name, directoryHint: .isDirectory)
        var isDir: ObjCBool = false
        if !FileManager.default.fileExists(atPath: path.path, isDirectory: &isDir) {
            try coordinateWrite(at: path) { target in
                try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
            }
        }
        let file = try metadata(path, parentID: parentID)
        guard file.isFolder else {
            throw DriveTransportError.invalidResponse("iCloud Drive 同名路径已被文件占用：\(name)")
        }
        return file
    }

    public func listFiles(inFolderID folderID: String) async throws -> [RemoteDriveFile] {
        try verifyBaseDirectory()
        let folderURL = try locate(folderID)
        return try children(of: folderURL, parent: folderID)
    }

    public func downloadData(fileID: String) async throws -> Data {
        try verifyBaseDirectory()
        let url = try locate(fileID)
        try await ensureUbiquitousFileDownloaded(at: url)
        return try coordinateRead(at: url) { target in
            try Data(contentsOf: target)
        }
    }

    public func downloadFile(fileID: String, to destinationURL: URL) async throws {
        try verifyBaseDirectory()
        let url = try locate(fileID)
        try await ensureUbiquitousFileDownloaded(at: url)
        try coordinateRead(at: url) { target in
            try DriveFiles.writeFile(target, to: destinationURL)
        }
    }

    public func uploadData(
        _ data: Data,
        name: String,
        mimeType: String,
        parentID: String,
        existingFileID: String?
    ) async throws -> RemoteDriveFile {
        let destination = try uploadPath(name: name, parentID: parentID, existingFileID: existingFileID)
        try coordinateWrite(at: destination) { target in
            let fm = FileManager.default
            let temp = target.deletingLastPathComponent().appending(path: ".charkle-icloud-\(UUID().uuidString)")
            try DriveFiles.writeRawBytes(data, to: temp, removeOnFailure: true)
            defer { try? fm.removeItem(at: temp) }
            if fm.fileExists(atPath: target.path) {
                do {
                    _ = try fm.replaceItemAt(target, withItemAt: temp, options: .usingNewMetadataOnly)
                } catch {
                    try? fm.removeItem(at: target)
                    try fm.moveItem(at: temp, to: target)
                }
            } else {
                try fm.moveItem(at: temp, to: target)
            }
        }
        return try metadata(destination, parentID: parentID)
    }

    public func uploadFile(
        from localURL: URL,
        name: String,
        mimeType: String,
        parentID: String,
        existingFileID: String?
    ) async throws -> RemoteDriveFile {
        let destination = try uploadPath(name: name, parentID: parentID, existingFileID: existingFileID)
        try coordinateWrite(at: destination) { target in
            try DriveFiles.writeStream(from: localURL, to: target, removeOnFailure: existingFileID == nil)
        }
        return try metadata(destination, parentID: parentID)
    }

    public func moveFile(
        fileID: String,
        fromParentID: String?,
        toParentID: String,
        newName: String?
    ) async throws -> RemoteDriveFile {
        try verifyBaseDirectory()
        let source = try locate(fileID)
        let folder = try locate(toParentID)
        let name = newName ?? source.lastPathComponent
        try DriveFiles.validateName(name)
        let target = folder.appending(path: name)
        if source.standardizedFileURL.path != target.standardizedFileURL.path {
            try await ensureUbiquitousFileDownloaded(at: source)
            let coordinator = NSFileCoordinator(filePresenter: nil)
            var coordError: NSError?
            var opError: Error?
            coordinator.coordinate(
                writingItemAt: source,
                options: .forMoving,
                writingItemAt: target,
                options: .forReplacing,
                error: &coordError
            ) { src, dst in
                do {
                    if FileManager.default.fileExists(atPath: dst.path) {
                        try FileManager.default.removeItem(at: dst)
                    }
                    try FileManager.default.moveItem(at: src, to: dst)
                } catch {
                    opError = error
                }
            }
            if let coordError { throw coordError }
            if let opError { throw opError }
        }
        return try metadata(target, parentID: toParentID)
    }

    public func trashFile(fileID: String) async throws {
        try verifyBaseDirectory()
        let url = try locate(fileID)
        try coordinateWrite(at: url) { target in
            if FileManager.default.fileExists(atPath: target.path) {
                try FileManager.default.removeItem(at: target)
            } else if let stub = Self.evictedStubURL(for: target), FileManager.default.fileExists(atPath: stub.path) {
                try FileManager.default.removeItem(at: stub)
            }
        }
        locations.removeValue(forKey: fileID)
    }

    // MARK: - Internal Filesystem & Ubiquitous Item Coordination

    private func verifyBaseDirectory() throws {
        let fm = FileManager.default
        var isDir: ObjCBool = false
        if !fm.fileExists(atPath: baseDirectory.path, isDirectory: &isDir) {
            try fm.createDirectory(at: baseDirectory, withIntermediateDirectories: true)
            _ = fm.fileExists(atPath: baseDirectory.path, isDirectory: &isDir)
        }
        guard isDir.boolValue else {
            throw DriveTransportError.mountPathUnavailable(baseDirectory.path)
        }
    }

    private func uploadPath(name: String, parentID: String, existingFileID: String?) throws -> URL {
        try DriveFiles.validateName(name)
        try verifyBaseDirectory()
        let parent = try locate(parentID)
        let target = parent.appending(path: name)
        if let existingFileID {
            let existing = try locate(existingFileID)
            guard existing.standardizedFileURL.path == target.standardizedFileURL.path else {
                throw DriveTransportError.invalidResponse("iCloud Drive 目标文件路径已变化。")
            }
        } else if FileManager.default.fileExists(atPath: target.path) {
            throw DriveTransportError.fileAlreadyExists(name)
        }
        return target
    }

    private func locate(_ id: String) throws -> URL {
        if id == DriveFiles.rootID { return baseDirectory }
        if id.hasPrefix(Self.pathIDPrefix) {
            let rel = String(id.dropFirst(Self.pathIDPrefix.count))
            let segments = rel.split(separator: "/").map(String.init)
            guard !segments.isEmpty else { throw DriveTransportError.fileNotFound(id) }
            var candidate = baseDirectory
            for seg in segments {
                try DriveFiles.validateName(seg)
                candidate = candidate.appending(path: seg)
            }
            locations[id] = candidate
            return candidate
        }
        if let cached = locations[id] { return cached }
        _ = try snapshot(includeMetadata: false)
        if let found = locations[id] { return found }
        _ = try snapshot(includeMetadata: true)
        if let found = locations[id] { return found }
        throw DriveTransportError.fileNotFound(id)
    }

    private func relativeID(for url: URL) throws -> String {
        let baseStd = baseDirectory.standardizedFileURL.path
        let prefix = baseStd.hasSuffix("/") ? baseStd : baseStd + "/"
        let targetStd = url.standardizedFileURL.path
        guard targetStd.hasPrefix(prefix) else {
            throw DriveTransportError.invalidResponse("路径超出 iCloud Drive 根目录范围。")
        }
        let rel = String(targetStd.dropFirst(prefix.count))
        return Self.pathIDPrefix + rel
    }

    private func metadata(_ url: URL, parentID: String) throws -> RemoteDriveFile {
        let logicalURL = Self.logicalURL(fromPossibleStub: url)
        let id = try relativeID(for: logicalURL)
        let vals = try? url.resourceValues(forKeys: [
            .isDirectoryKey,
            .fileSizeKey,
            .contentModificationDateKey
        ])
        let isFolder = vals?.isDirectory ?? false
        let name = logicalURL.lastPathComponent
        let mime: String
        if isFolder {
            mime = RemoteDriveFile.folderMimeType
        } else if let ext = logicalURL.pathExtension.isEmpty ? nil : logicalURL.pathExtension,
                  let type = UTType(filenameExtension: ext)?.preferredMIMEType {
            mime = type
        } else {
            mime = "application/octet-stream"
        }
        locations[id] = logicalURL
        return RemoteDriveFile(
            id: id,
            name: name,
            mimeType: mime,
            size: isFolder ? nil : vals?.fileSize.map(Int64.init),
            modifiedTime: vals?.contentModificationDate,
            md5Checksum: nil,
            parents: parentID.isEmpty ? [] : [parentID],
            trashed: false
        )
    }

    private func children(of directory: URL, parent: String) throws -> [RemoteDriveFile] {
        guard FileManager.default.fileExists(atPath: directory.path) else { return [] }
        let items = try FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.isDirectoryKey, .fileSizeKey, .contentModificationDateKey],
            options: [.skipsPackageDescendants]
        )
        var seenIDs = Set<String>()
        var results: [RemoteDriveFile] = []
        results.reserveCapacity(items.count)
        for item in items {
            let rawName = item.lastPathComponent
            if rawName == ".DS_Store" || rawName.hasPrefix(".charkle-icloud-") || rawName.hasPrefix("._") {
                continue
            }
            // Allow `.charkle` metadata folder and `.name.icloud` evicted stubs; skip other hidden dotfiles
            let isEvictedStub = Self.isEvictedStubName(rawName)
            if rawName.hasPrefix(".") && rawName != ".charkle" && !isEvictedStub {
                continue
            }
            if let entry = try? metadata(item, parentID: parent), seenIDs.insert(entry.id).inserted {
                results.append(entry)
            }
        }
        return results.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    private func snapshot(includeMetadata: Bool = false) throws -> [String: RemoteDriveFile] {
        try verifyBaseDirectory()
        var url = baseDirectory
        var parentID = DriveFiles.rootID
        var result: [String: RemoteDriveFile] = [:]
        var rootEntry: RemoteDriveFile?
        locations.removeAll()

        let effectiveSegments = rootSegments.isEmpty ? [] : rootSegments
        if effectiveSegments.isEmpty {
            let rootMeta = RemoteDriveFile(
                id: DriveFiles.rootID,
                name: baseDirectory.lastPathComponent,
                mimeType: RemoteDriveFile.folderMimeType,
                parents: []
            )
            rootEntry = rootMeta
        } else {
            for segment in effectiveSegments {
                try DriveFiles.validateName(segment)
                url = url.appending(path: segment, directoryHint: .isDirectory)
                guard FileManager.default.fileExists(atPath: url.path) else { return result }
                let entry = try metadata(url, parentID: parentID)
                parentID = entry.id
                rootEntry = entry
            }
        }

        guard let root = rootEntry else { return result }
        var queue = [root]
        var index = 0
        while index < queue.count {
            let current = queue[index]
            index += 1
            let folderURL = current.id == DriveFiles.rootID ? baseDirectory : (locations[current.id] ?? url)
            for child in try children(of: folderURL, parent: current.id) {
                if !includeMetadata && child.name == ".charkle" { continue }
                result[child.id] = child
                if child.isFolder {
                    queue.append(child)
                }
            }
        }
        return result
    }

    private func encode(_ snapshot: [String: RemoteDriveFile]) throws -> String {
        try JSONEncoder().encode(snapshot).base64EncodedString()
    }

    private nonisolated static func isEvictedStubName(_ name: String) -> Bool {
        name.hasPrefix(".") && name.hasSuffix(".icloud") && name.count > 8
    }

    private nonisolated static func logicalURL(fromPossibleStub url: URL) -> URL {
        let name = url.lastPathComponent
        guard isEvictedStubName(name) else { return url }
        let start = name.index(after: name.startIndex)
        let end = name.index(name.endIndex, offsetBy: -".icloud".count)
        let realName = String(name[start..<end])
        return url.deletingLastPathComponent().appending(path: realName)
    }

    private nonisolated static func evictedStubURL(for logicalURL: URL) -> URL? {
        let name = logicalURL.lastPathComponent
        guard !name.isEmpty, !name.hasPrefix(".") else { return nil }
        return logicalURL.deletingLastPathComponent().appending(path: ".\(name).icloud")
    }

    /// Triggers iCloud Drive hydration when a file is evicted (`.icloud` stub or non-current ubiquitous status)
    /// and waits cleanly until materialized locally.
    private func ensureUbiquitousFileDownloaded(at url: URL) async throws {
        let fm = FileManager.default
        let stubURL = Self.evictedStubURL(for: url)
        let needsDownload: Bool = {
            if !fm.fileExists(atPath: url.path), let stubURL, fm.fileExists(atPath: stubURL.path) {
                return true
            }
            if let values = try? url.resourceValues(forKeys: [.isUbiquitousItemKey, .ubiquitousItemDownloadingStatusKey]),
               values.isUbiquitousItem == true,
               values.ubiquitousItemDownloadingStatus != .current {
                return true
            }
            return false
        }()

        guard needsDownload else { return }
        let downloadTarget = (fm.fileExists(atPath: url.path) ? url : (stubURL ?? url))
        try? fm.startDownloadingUbiquitousItem(at: downloadTarget)

        let deadline = ContinuousClock.now + .seconds(45)
        while ContinuousClock.now < deadline {
            try Task.checkCancellation()
            if fm.fileExists(atPath: url.path) {
                let status = (try? url.resourceValues(forKeys: [.ubiquitousItemDownloadingStatusKey]))?.ubiquitousItemDownloadingStatus
                if status == nil || status == .current {
                    return
                }
            }
            try await Task.sleep(for: .milliseconds(150))
        }
        guard fm.fileExists(atPath: url.path) else {
            throw DriveTransportError.fileNotFound("iCloud 文件暂未完成下载：\(url.lastPathComponent)")
        }
    }

    private func coordinateRead<T>(at url: URL, _ body: (URL) throws -> T) throws -> T {
        let coordinator = NSFileCoordinator(filePresenter: nil)
        var coordError: NSError?
        var result: Result<T, Error>?
        coordinator.coordinate(readingItemAt: url, options: [], error: &coordError) { actualURL in
            result = Result { try body(actualURL) }
        }
        if let coordError { throw coordError }
        guard let result else { throw DriveTransportError.fileNotFound(url.lastPathComponent) }
        return try result.get()
    }

    private func coordinateWrite<T>(at url: URL, _ body: (URL) throws -> T) throws -> T {
        let coordinator = NSFileCoordinator(filePresenter: nil)
        var coordError: NSError?
        var result: Result<T, Error>?
        coordinator.coordinate(writingItemAt: url, options: .forReplacing, error: &coordError) { actualURL in
            result = Result { try body(actualURL) }
        }
        if let coordError { throw coordError }
        guard let result else { throw DriveTransportError.invalidResponse("iCloud 写入协调失败：\(url.lastPathComponent)") }
        return try result.get()
    }
}
