import CryptoKit
import Foundation

public final actor InMemoryDriveTransport: DriveTransport {
    public nonisolated let displayName = "In-memory Drive"

    private struct Entry {
        var name: String
        var mimeType: String
        var parent: String
        var data: Data?
        var modifiedTime: Date
        var trashed = false

        func metadata(id: String) -> RemoteDriveFile {
            RemoteDriveFile(id: id, name: name, mimeType: mimeType, size: data.map { Int64($0.count) },
                            modifiedTime: modifiedTime, md5Checksum: data.map { MediaPipeline.hex(Insecure.MD5.hash(data: $0)) },
                            parents: [parent], trashed: trashed)
        }
    }

    private let email: String
    private let pageSize: Int
    private var entries: [String: Entry] = [:]
    private var history: [DriveChange] = []
    private var nextID = 0

    public init(email: String = "charkle@example.invalid", pageSize: Int = 100) {
        self.email = email
        self.pageSize = max(1, pageSize)
    }

    public func accountInfo() -> DriveAccountInfo { DriveAccountInfo(email: email, source: displayName) }

    public func fetchStartPageToken() -> String { String(history.count) }

    public func listChanges(pageToken: String) throws -> DriveChangePage {
        guard let start = Int(pageToken), (0...history.count).contains(start) else {
            throw DriveTransportError.httpError(statusCode: 410, message: "Expired change token")
        }
        let end = start + min(pageSize, history.count - start)
        return DriveChangePage(changes: Array(history[start..<end]), nextPageToken: end < history.count ? String(end) : nil,
                               newStartPageToken: end == history.count ? String(end) : nil)
    }

    public func findOrCreateFolder(named name: String, parentID: String) throws -> RemoteDriveFile {
        try DriveFiles.validateName(name)
        try requireParent(parentID)
        if let match = entries.first(where: {
            $0.value.name == name && $0.value.parent == parentID && !$0.value.trashed && $0.value.data == nil
        }) { return match.value.metadata(id: match.key) }
        let id = allocateID()
        let value = Entry(name: name, mimeType: RemoteDriveFile.folderMimeType, parent: parentID, data: nil, modifiedTime: now)
        return save(value, id: id)
    }

    public func listFiles(inFolderID folderID: String) throws -> [RemoteDriveFile] {
        try requireParent(folderID)
        return entries.compactMap { id, entry in
            entry.parent == folderID && !entry.trashed ? entry.metadata(id: id) : nil
        }.sorted { ($0.name, $0.id) < ($1.name, $1.id) }
    }

    public func downloadData(fileID: String) throws -> Data {
        guard let entry = entries[fileID], !entry.trashed, let data = entry.data else {
            throw DriveTransportError.fileNotFound(fileID)
        }
        return data
    }

    public func downloadFile(fileID: String, to destinationURL: URL) throws {
        try FileManager.default.createDirectory(at: destinationURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try downloadData(fileID: fileID).write(to: destinationURL, options: .atomic)
    }

    public func uploadData(_ data: Data, name: String, mimeType: String, parentID: String,
                           existingFileID: String?) throws -> RemoteDriveFile {
        try DriveFiles.validateName(name)
        try requireParent(parentID)
        if let existingFileID, entries[existingFileID]?.data == nil {
            throw DriveTransportError.fileNotFound(existingFileID)
        }
        let id = existingFileID ?? allocateID()
        return save(Entry(name: name, mimeType: mimeType, parent: parentID, data: data, modifiedTime: now), id: id)
    }

    public func uploadFile(from localURL: URL, name: String, mimeType: String, parentID: String,
                           existingFileID: String?) throws -> RemoteDriveFile {
        try uploadData(Data(contentsOf: localURL), name: name, mimeType: mimeType, parentID: parentID, existingFileID: existingFileID)
    }

    public func moveFile(fileID: String, fromParentID: String?, toParentID: String, newName: String?) throws -> RemoteDriveFile {
        try requireParent(toParentID)
        guard var entry = entries[fileID], !entry.trashed else { throw DriveTransportError.fileNotFound(fileID) }
        var parent = toParentID
        while parent != DriveFiles.rootID {
            guard parent != fileID, let ancestor = entries[parent] else {
                throw DriveTransportError.invalidResponse("Invalid folder move.")
            }
            parent = ancestor.parent
        }
        if let newName { try DriveFiles.validateName(newName); entry.name = newName }
        entry.parent = toParentID
        entry.modifiedTime = now
        return save(entry, id: fileID)
    }

    public func trashFile(fileID: String) throws {
        guard var entry = entries[fileID] else { throw DriveTransportError.fileNotFound(fileID) }
        entry.trashed = true
        entry.modifiedTime = now
        _ = save(entry, id: fileID)
    }

    private var now: Date { Date(timeIntervalSince1970: 1_700_000_000 + Double(history.count) / 10) }

    private func requireParent(_ id: String) throws {
        if id == DriveFiles.rootID { return }
        guard let entry = entries[id], entry.data == nil, !entry.trashed else {
            throw DriveTransportError.fileNotFound(id)
        }
    }

    private func allocateID() -> String {
        nextID += 1
        return "drive-\(nextID)"
    }

    private func save(_ entry: Entry, id: String) -> RemoteDriveFile {
        entries[id] = entry
        let file = entry.metadata(id: id)
        history.append(DriveChange(fileID: id, removed: false, file: file))
        return file
    }
}
