import Foundation
import Synchronization

public nonisolated struct DirectAPITransport: DriveTransport {
    public let displayName = "Google Drive API v3"
    private let oauth: @Sendable () async throws -> String
    private let session: URLSession
    private let endpoints: [GDirectEndpoint]
    private let endpointBreaker = EndpointCircuitBreaker()
    private let transferDirectory: URL?
    private let multipartThresholdBytes: Int64

    private static let api = URL(string: "https://www.googleapis.com/drive/v3")!
    private static let uploadAPI = URL(string: "https://www.googleapis.com/upload/drive/v3")!
    private static let fileFields = "id,name,mimeType,size,modifiedTime,md5Checksum,parents,trashed,webViewLink,shortcutDetails(targetId,targetMimeType)"
    private static let shortcutMimeType = "application/vnd.google-apps.shortcut"
    private static let directDataMultipartLimit: Int = 5 * 1_048_576
    private static let singleShotDownloadLimit: Int64 = 16 * 1_048_576

    /// Shared-friendly pooled URLSession tuned for concurrent Google Drive HTTP/2 transfers.
    public static func makePooledSession() -> URLSession {
        let config = URLSessionConfiguration.default
        config.httpMaximumConnectionsPerHost = 8
        config.timeoutIntervalForRequest = 45
        config.timeoutIntervalForResource = 300
        config.urlCache = nil
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        return URLSession(configuration: config)
    }

    public init(oauth: GoogleOAuthClient, endpoints: [GDirectEndpoint] = [], session: URLSession = .shared,
                transferDirectory: URL? = nil, multipartThresholdBytes: Int64 = 0) {
        self.init(accessToken: { try await oauth.accessToken() }, endpoints: endpoints, session: session,
                  transferDirectory: transferDirectory, multipartThresholdBytes: multipartThresholdBytes)
    }

    public init(accessToken: @escaping @Sendable () async throws -> String, endpoints: [GDirectEndpoint] = [],
                session: URLSession = .shared, transferDirectory: URL? = nil, multipartThresholdBytes: Int64 = 0) {
        oauth = accessToken
        self.endpoints = endpoints.filter(\.healthy)
        self.session = session
        self.transferDirectory = transferDirectory
        self.multipartThresholdBytes = max(0, multipartThresholdBytes)
    }

    public func accountInfo() async throws -> DriveAccountInfo {
        struct About: Decodable {
            struct User: Decodable { let emailAddress: String; let displayName: String? }
            struct Quota: Decodable { let usage: String?; let limit: String? }
            let user: User
            let storageQuota: Quota?
        }
        let about: About = try await get("about", ["fields": "user(emailAddress,displayName),storageQuota(usage,limit)"])
        return DriveAccountInfo(email: about.user.emailAddress, displayName: about.user.displayName,
                                storageUsedBytes: about.storageQuota?.usage.flatMap(Int64.init),
                                storageLimitBytes: about.storageQuota?.limit.flatMap(Int64.init), source: displayName)
    }

    public func fetchStartPageToken() async throws -> String {
        struct Token: Decodable { let startPageToken: String }
        let result: Token = try await get("changes/startPageToken", ["supportsAllDrives": "true"])
        return result.startPageToken
    }

    public func listChanges(pageToken: String) async throws -> DriveChangePage {
        struct Page: Decodable {
            struct Change: Decodable { let fileId: String?; let removed: Bool?; let file: FileDTO? }
            let changes: [Change]
            let nextPageToken: String?
            let newStartPageToken: String?
        }
        let page: Page = try await get("changes", [
            "pageToken": pageToken, "includeRemoved": "true", "spaces": "drive", "pageSize": "1000",
            "supportsAllDrives": "true", "includeItemsFromAllDrives": "true",
            "fields": "nextPageToken,newStartPageToken,changes(fileId,removed,file(\(Self.fileFields)))"
        ])
        return DriveChangePage(changes: page.changes.compactMap {
            guard let id = $0.fileId else { return nil }
            return DriveChange(fileID: id, removed: $0.removed ?? false, file: $0.file?.record)
        }, nextPageToken: page.nextPageToken, newStartPageToken: page.newStartPageToken)
    }

    public func resolveFolder(id: String) async throws -> RemoteDriveFile {
        let dto: FileDTO = try await get("files/\(try segment(id))", [
            "supportsAllDrives": "true",
            "fields": Self.fileFields
        ])
        if dto.trashed == true {
            throw DriveTransportError.fileNotFound("共享目录已在回收站中：\(id)")
        }
        if dto.mimeType == Self.shortcutMimeType,
           let target = dto.shortcutDetails,
           target.targetMimeType == RemoteDriveFile.folderMimeType,
           let targetID = target.targetId, !targetID.isEmpty {
            return try await resolveFolder(id: targetID)
        }
        guard dto.mimeType == RemoteDriveFile.folderMimeType else {
            throw DriveTransportError.invalidResponse("指定的 Google Drive 链接不是文件夹（类型为 \(dto.mimeType)）。")
        }
        return dto.record
    }

    public func listSharedFolders() async throws -> [RemoteDriveFile] {
        let shared = try await list(
            query: "sharedWithMe = true and mimeType = '\(RemoteDriveFile.folderMimeType)' and trashed = false"
        )
        return shared.sorted { ($0.modifiedTime ?? .distantPast) > ($1.modifiedTime ?? .distantPast) }
    }

    public func findOrCreateFolder(named name: String, parentID: String) async throws -> RemoteDriveFile {
        try DriveFiles.validateName(name)
        let query = "'\(escape(parentID))' in parents and trashed=false and name='\(escape(name))' and mimeType='\(RemoteDriveFile.folderMimeType)'"
        if let folder = try await oldestFolder(query: query) { return folder }
        // Also follow an existing Google Drive folder shortcut (e.g. a Shared Folder added as shortcut into My Drive)
        let shortcutQuery = "'\(escape(parentID))' in parents and trashed=false and name='\(escape(name))' and mimeType='\(Self.shortcutMimeType)'"
        if let shortcut = try await oldestFolderShortcut(query: shortcutQuery),
           let targetID = shortcut.shortcutDetails?.targetId, !targetID.isEmpty {
            return try await resolveFolder(id: targetID)
        }
        let file: FileDTO = try await mutate("files", method: "POST", body: [
            "name": name, "mimeType": RemoteDriveFile.folderMimeType, "parents": [parentID]
        ])
        // If two devices create the same logical directory, creation order elects the shared one.
        return try await oldestFolder(query: query) ?? file.record
    }

    private func oldestFolder(query: String) async throws -> RemoteDriveFile? {
        struct Result: Decodable { let files: [FileDTO] }
        let result: Result = try await get("files", [
            "q": query,
            "supportsAllDrives": "true",
            "includeItemsFromAllDrives": "true",
            "fields": "files(\(Self.fileFields),createdTime)",
            "pageSize": "100",
            "orderBy": "createdTime"
        ])
        return result.files.min { ($0.createdTime ?? "", $0.id) < ($1.createdTime ?? "", $1.id) }?.record
    }

    private func oldestFolderShortcut(query: String) async throws -> FileDTO? {
        struct Result: Decodable { let files: [FileDTO] }
        let result: Result = try await get("files", [
            "q": query,
            "supportsAllDrives": "true",
            "includeItemsFromAllDrives": "true",
            "fields": "files(\(Self.fileFields),createdTime)",
            "pageSize": "20",
            "orderBy": "createdTime"
        ])
        return result.files
            .filter { $0.shortcutDetails?.targetMimeType == RemoteDriveFile.folderMimeType }
            .min { ($0.createdTime ?? "", $0.id) < ($1.createdTime ?? "", $1.id) }
    }

    public func listFiles(inFolderID folderID: String) async throws -> [RemoteDriveFile] {
        try await list(query: "'\(escape(folderID))' in parents and trashed=false")
    }

    private func list(query: String) async throws -> [RemoteDriveFile] {
        struct Page: Decodable { let files: [FileDTO]; let nextPageToken: String? }
        var token: String?
        var files: [RemoteDriveFile] = []
        repeat {
            var params = [
                "q": query,
                "supportsAllDrives": "true",
                "includeItemsFromAllDrives": "true",
                "fields": "nextPageToken,files(\(Self.fileFields))",
                "pageSize": "1000"
            ]
            params["pageToken"] = token
            let page: Page = try await get("files", params)
            token = page.nextPageToken
            files += page.files.map(\.record)
        } while token != nil
        return files
    }

    public func downloadData(fileID: String) async throws -> Data {
        let request = try await request(Self.api, "files/\(try segment(fileID))", ["alt": "media", "supportsAllDrives": "true"])
        return try await perform(request, accelerate: true)
    }

    public func downloadFile(fileID: String, to destinationURL: URL) async throws {
        let path = "files/\(try segment(fileID))"
        let file: FileDTO = try await get(path, ["fields": Self.fileFields, "supportsAllDrives": "true"])
        try await downloadKnownFile(
            fileID: fileID,
            mimeType: file.mimeType,
            expectedSize: file.size.flatMap(Int64.init),
            md5Checksum: file.md5Checksum,
            validator: file.md5Checksum ?? file.modifiedTime ?? "",
            to: destinationURL
        )
    }

    public func downloadFile(_ file: RemoteDriveFile, to destinationURL: URL) async throws {
        let validator = file.md5Checksum ?? file.modifiedTime.map { String($0.timeIntervalSince1970) } ?? ""
        try await downloadKnownFile(
            fileID: file.id,
            mimeType: file.mimeType,
            expectedSize: file.size,
            md5Checksum: file.md5Checksum,
            validator: validator,
            to: destinationURL
        )
    }

    private func downloadKnownFile(
        fileID: String,
        mimeType: String,
        expectedSize: Int64?,
        md5Checksum: String?,
        validator: String,
        to destinationURL: URL
    ) async throws {
        let path = "files/\(try segment(fileID))"
        let url = destinationURL
        let folder = url.deletingLastPathComponent()
        let fm = FileManager.default
        try fm.createDirectory(at: folder, withIntermediateDirectories: true)

        if mimeType.hasPrefix("application/vnd.google-apps."), mimeType != RemoteDriveFile.folderMimeType {
            let request = try await request(Self.api, path + "/export", ["mimeType": "application/pdf"])
            let (temporary, response) = try await downloadWithRetry(request)
            defer { try? fm.removeItem(at: temporary) }
            try validate(response, data: nil)
            try DriveFiles.writeFile(temporary, to: url)
            return
        }

        // Fast single-shot path for files <= 16 MB: avoids Range overhead, extra `.drive-download-*`
        // temp file copy, and double I/O while preserving atomic install & MD5 integrity check.
        if let expectedSize, expectedSize >= 0, expectedSize <= Self.singleShotDownloadLimit {
            let req = try await request(Self.api, path, ["alt": "media", "supportsAllDrives": "true"])
            let (temporary, response) = try await downloadWithRetry(req)
            defer { try? fm.removeItem(at: temporary) }
            try validate(response, data: nil)
            let received = Int64((try temporary.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
            if expectedSize != received {
                throw DriveTransportError.invalidResponse("Incomplete Drive download.")
            }
            if let checksum = md5Checksum, try MediaPipeline.digests(temporary).md5 != checksum {
                throw DriveTransportError.invalidResponse("Drive download checksum changed.")
            }
            if fm.fileExists(atPath: url.path) {
                _ = try fm.replaceItemAt(url, withItemAt: temporary)
            } else {
                do {
                    try fm.moveItem(at: temporary, to: url)
                } catch {
                    try DriveFiles.writeFile(temporary, to: url)
                }
            }
            return
        }

        let transferID = DriveFiles.stableUUID(fileID + ":" + validator + ":" + url.lastPathComponent).uuidString
        let partial = folder.appending(path: ".drive-download-" + transferID)
        var offset = Int64((try? partial.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
        if validator.isEmpty || expectedSize == nil || offset > expectedSize ?? 0 {
            try? fm.removeItem(at: partial)
            offset = 0
        }
        if !fm.fileExists(atPath: partial.path) { try Data().write(to: partial) }
        let chunkSize: Int64 = 16 * 1_024 * 1_024
        while expectedSize == nil || offset < expectedSize ?? 0 {
            var req = try await request(Self.api, path, ["alt": "media", "supportsAllDrives": "true"])
            let end = min((expectedSize ?? Int64.max) - 1, offset + chunkSize - 1)
            if expectedSize != nil { req.setValue("bytes=\(offset)-\(end)", forHTTPHeaderField: "Range") }
            let (temporary, response) = try await downloadWithRetry(req)
            defer { try? fm.removeItem(at: temporary) }
            try validate(response, data: nil)
            let received = Int64((try temporary.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
            let http = response as? HTTPURLResponse
            if http?.statusCode == 206 {
                guard http?.value(forHTTPHeaderField: "Content-Range")?.hasPrefix("bytes \(offset)-") == true,
                      received > 0, received <= end - offset + 1 else {
                    throw DriveTransportError.invalidResponse("Unexpected download range")
                }
            } else { offset = 0 }
            let target = try FileHandle(forWritingTo: partial)
            let source = try FileHandle(forReadingFrom: temporary)
            defer { try? target.close(); try? source.close() }
            try target.truncate(atOffset: UInt64(offset))
            try target.seek(toOffset: UInt64(offset))
            while let data = try source.read(upToCount: 1_048_576), !data.isEmpty { try target.write(contentsOf: data) }
            offset += received
            if http?.statusCode != 206 { break }
        }
        if let expectedSize, expectedSize != offset {
            throw DriveTransportError.invalidResponse("Incomplete Drive download.")
        }
        if let checksum = md5Checksum, try MediaPipeline.digests(partial).md5 != checksum {
            try? fm.removeItem(at: partial)
            throw DriveTransportError.invalidResponse("Drive download checksum changed.")
        }
        if fm.fileExists(atPath: url.path) {
            _ = try fm.replaceItemAt(url, withItemAt: partial)
        } else { try fm.moveItem(at: partial, to: url) }
    }

    public func uploadData(_ data: Data, name: String, mimeType: String, parentID: String,
                           existingFileID: String?) async throws -> RemoteDriveFile {
        if data.count <= Self.directDataMultipartLimit {
            try DriveFiles.validateName(name)
            let path = try existingFileID.map { "files/" + (try segment($0)) } ?? "files"
            var metadata: [String: Any] = ["name": name, "mimeType": mimeType]
            if existingFileID == nil { metadata["parents"] = [parentID] }
            let method = existingFileID == nil ? "POST" : "PATCH"
            let metadataJSON = try JSONSerialization.data(withJSONObject: metadata)
            return try await uploadMultipart(data: data, path: path, method: method, metadata: metadataJSON, mimeType: mimeType)
        }
        let temp = FileManager.default.temporaryDirectory.appending(path: "CharkleUpload-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: temp) }
        try data.write(to: temp)
        return try await uploadFile(from: temp, name: name, mimeType: mimeType, parentID: parentID, existingFileID: existingFileID)
    }

    public func uploadFile(from localURL: URL, name: String, mimeType: String, parentID: String,
                           existingFileID: String?) async throws -> RemoteDriveFile {
        try DriveFiles.validateName(name)
        let fileSize = Int64((try localURL.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
        let path = try existingFileID.map { "files/" + (try segment($0)) } ?? "files"
        var metadata: [String: Any] = ["name": name, "mimeType": mimeType]
        if existingFileID == nil { metadata["parents"] = [parentID] }
        let method = existingFileID == nil ? "POST" : "PATCH"
        let metadataJSON = try JSONSerialization.data(withJSONObject: metadata)
        if fileSize == 0 {
            return try await uploadMultipart(data: Data(), path: path, method: method, metadata: metadataJSON, mimeType: mimeType)
        }
        if multipartThresholdBytes > 0 && fileSize <= multipartThresholdBytes {
            let payload = try Data(contentsOf: localURL)
            return try await uploadMultipart(data: payload, path: path, method: method, metadata: metadataJSON, mimeType: mimeType)
        }
        let checkpoint = try uploadCheckpoint(file: localURL, parent: parentID, name: name, existingID: existingFileID)
        let remembered = checkpoint.flatMap { try? String(contentsOf: $0, encoding: .utf8) }.flatMap(Self.uploadURL)
        do {
            return try await runUpload(file: localURL, fileSize: fileSize, mimeType: mimeType, method: method,
                                       path: path, metadata: metadataJSON, checkpoint: checkpoint, previous: remembered)
        } catch DriveTransportError.httpError(let code, _) where remembered != nil && (code == 404 || code == 410) {
            return try await runUpload(file: localURL, fileSize: fileSize, mimeType: mimeType, method: method,
                                       path: path, metadata: metadataJSON, checkpoint: checkpoint, previous: nil)
        }
    }

    private func uploadMultipart(data: Data, path: String, method: String, metadata: Data, mimeType: String) async throws -> RemoteDriveFile {
        let boundary = "charkle-" + UUID().uuidString
        var request = try await request(
            Self.uploadAPI,
            path,
            ["uploadType": "multipart", "supportsAllDrives": "true", "fields": Self.fileFields],
            method: method
        )
        request.timeoutInterval = max(60, TimeInterval(data.count / 131_072) + 45)
        request.setValue("multipart/related; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        var body = Data()
        body.reserveCapacity(metadata.count + data.count + 256)
        body.append(Data("--\(boundary)\r\nContent-Type: application/json; charset=UTF-8\r\n\r\n".utf8))
        body.append(metadata)
        body.append(Data("\r\n--\(boundary)\r\nContent-Type: \(mimeType)\r\n\r\n".utf8))
        body.append(data)
        body.append(Data("\r\n--\(boundary)--\r\n".utf8))
        request.httpBody = body
        return try JSONDecoder().decode(FileDTO.self, from: try await perform(request, accelerate: false)).record
    }

    private func uploadCheckpoint(file: URL, parent: String, name: String, existingID: String?) throws -> URL? {
        guard let transferDirectory, parent != DriveFiles.rootID || existingID != nil else { return nil }
        let hash = try MediaPipeline.digests(file).sha256
        let key = DriveFiles.stableUUID([parent, name, existingID ?? "", hash].joined(separator: "\u{0}"))
        try FileManager.default.createDirectory(at: transferDirectory, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        return transferDirectory.appending(path: key.uuidString + ".upload")
    }

    private func runUpload(file: URL, fileSize: Int64, mimeType: String, method: String, path: String,
                           metadata: Data, checkpoint: URL?, previous: URL?) async throws -> RemoteDriveFile {
        let upload: URL
        if let previous { upload = previous }
        else {
            var initial = try await request(
                Self.uploadAPI,
                path,
                ["uploadType": "resumable", "supportsAllDrives": "true", "fields": Self.fileFields],
                method: method
            )
            initial.setValue(mimeType, forHTTPHeaderField: "X-Upload-Content-Type")
            initial.setValue(String(fileSize), forHTTPHeaderField: "X-Upload-Content-Length")
            initial.setValue("application/json", forHTTPHeaderField: "Content-Type")
            initial.httpBody = metadata
            let (body, response) = try await session.data(for: initial)
            try validate(response, data: body)
            guard let location = (response as? HTTPURLResponse)?.value(forHTTPHeaderField: "Location"),
                  let url = Self.uploadURL(location) else {
                throw DriveTransportError.invalidResponse("Missing resumable upload URL.")
            }
            upload = url
            if let checkpoint {
                try Data(url.absoluteString.utf8).write(to: checkpoint, options: .atomic)
            }
        }
        let uploaded = try await sendChunks(file: file, fileSize: fileSize, mimeType: mimeType, upload: upload, resume: previous != nil)
        if let checkpoint { try? FileManager.default.removeItem(at: checkpoint) }
        return uploaded
    }

    private static func uploadURL(_ location: String) -> URL? {
        guard let url = URL(string: location), url.scheme == "https", url.user() == nil, url.password() == nil,
              let host = url.host(), host == "googleapis.com" || host.hasSuffix(".googleapis.com") else { return nil }
        return url
    }

    private func sendChunks(file: URL, fileSize: Int64, mimeType: String, upload: URL, resume: Bool) async throws -> RemoteDriveFile {
        let handle = try FileHandle(forReadingFrom: file)
        defer { try? handle.close() }
        let chunkSize: Int64 = 8 * 1_024 * 1_024
        var offset: Int64 = 0
        var failures = 0
        var checking = resume
        repeat {
            try Task.checkCancellation()
            let data: Data
            var req = URLRequest(url: upload, timeoutInterval: 120)
            req.httpMethod = "PUT"
            req.setValue(mimeType, forHTTPHeaderField: "Content-Type")
            if checking {
                data = Data()
                req.setValue("bytes */\(fileSize)", forHTTPHeaderField: "Content-Range")
            } else {
                try handle.seek(toOffset: UInt64(offset))
                data = try handle.read(upToCount: Int(min(chunkSize, fileSize - offset))) ?? Data()
                guard !data.isEmpty else { throw DriveTransportError.invalidResponse("Upload source changed.") }
                let last = offset + Int64(data.count) - 1
                req.setValue("bytes \(offset)-\(last)/\(fileSize)", forHTTPHeaderField: "Content-Range")
            }
            req.setValue(String(data.count), forHTTPHeaderField: "Content-Length")
            req.httpBody = data
            do {
                let (body, response) = try await session.data(for: req)
                let http = response as? HTTPURLResponse
                if http?.statusCode == 308 {
                    let received = http?.value(forHTTPHeaderField: "Range")?.split(separator: "-").last.flatMap { Int64($0) }
                    let next = received.map { $0 + 1 } ?? 0
                    guard next >= 0, next <= fileSize else {
                        throw DriveTransportError.invalidResponse("Invalid resumable upload offset.")
                    }
                    if next > offset { failures = 0 }
                    else if !checking { failures += 1 }
                    guard failures <= 4 else { throw URLError(.cannotWriteToFile) }
                    offset = next
                    checking = offset == fileSize
                    if checking { failures += 1 }
                    continue
                }
                try validate(response, data: body)
                return try JSONDecoder().decode(FileDTO.self, from: body).record
            } catch {
                try Task.checkCancellation()
                guard Self.retryable(error), failures < 4 else { throw error }
                failures += 1
                checking = true
                try await Task.sleep(for: .milliseconds(250 * failures))
            }
        } while true
    }

    public func moveFile(fileID: String, fromParentID: String?, toParentID: String, newName: String?) async throws -> RemoteDriveFile {
        let path = "files/\(try segment(fileID))"
        let current: FileDTO = try await get(path, ["fields": Self.fileFields, "supportsAllDrives": "true"])
        let old = fromParentID ?? current.parents?.first
        var params: [String: String] = [:]
        if old != toParentID { params["addParents"] = toParentID; params["removeParents"] = old }
        var metadata: [String: Any] = [:]
        if let newName { try DriveFiles.validateName(newName); metadata["name"] = newName }
        if metadata.isEmpty && params.isEmpty { return current.record }
        let file: FileDTO = try await mutate(path, method: "PATCH", params: params, body: metadata)
        return file.record
    }

    public func trashFile(fileID: String) async throws {
        let _: FileDTO = try await mutate("files/\(try segment(fileID))", method: "PATCH", body: ["trashed": true])
    }

    private func get<T: Decodable>(_ path: String, _ params: [String: String] = [:]) async throws -> T {
        let request = try await request(Self.api, path, params)
        return try JSONDecoder().decode(T.self, from: try await perform(request, accelerate: true))
    }

    private func mutate<T: Decodable>(_ path: String, method: String, params: [String: String] = [:],
                                       body: [String: Any]) async throws -> T {
        var fields = params
        fields["fields"] = Self.fileFields
        fields["supportsAllDrives"] = "true"
        var req = try await request(Self.api, path, fields, method: method)
        req.httpBody = try JSONSerialization.data(withJSONObject: body)
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        return try JSONDecoder().decode(T.self, from: try await perform(req, accelerate: false))
    }

    private func request(_ base: URL, _ path: String, _ params: [String: String], method: String = "GET") async throws -> URLRequest {
        guard var components = URLComponents(url: base.appending(path: path), resolvingAgainstBaseURL: false) else {
            throw URLError(.badURL)
        }
        if !params.isEmpty { components.queryItems = params.sorted { $0.key < $1.key }.map { URLQueryItem(name: $0, value: $1) } }
        guard let url = components.url else { throw URLError(.badURL) }
        let token = try await oauth()
        guard !token.isEmpty, token.utf8.allSatisfy({ $0 > 32 && $0 < 127 }) else {
            throw DriveTransportError.authenticationRequired("Invalid Google access token.")
        }
        var request = URLRequest(url: url, timeoutInterval: 45)
        request.httpMethod = method
        request.setValue("Bearer " + token, forHTTPHeaderField: "Authorization")
        return request
    }

    private func downloadWithRetry(_ request: URLRequest) async throws -> (URL, URLResponse) {
        var attempt = 0
        while true {
            try Task.checkCancellation()
            do {
                let (temporary, response) = try await session.download(for: request)
                if let http = response as? HTTPURLResponse, (http.statusCode == 429 || http.statusCode >= 500), attempt < 3 {
                    try? FileManager.default.removeItem(at: temporary)
                    attempt += 1
                    try await Task.sleep(for: .milliseconds(300 * attempt * attempt))
                    continue
                }
                return (temporary, response)
            } catch {
                try Task.checkCancellation()
                guard Self.retryable(error), attempt < 3 else { throw error }
                attempt += 1
                try await Task.sleep(for: .milliseconds(300 * attempt * attempt))
            }
        }
    }

    private func perform(_ request: URLRequest, accelerate: Bool) async throws -> Data {
        let canUseGDirect = accelerate && !endpoints.isEmpty
            && request.url?.host() == "www.googleapis.com"
            && request.value(forHTTPHeaderField: "Authorization") != nil

        // If URLSession already failed with a connectivity error during this sync, use gdirect immediately.
        if canUseGDirect && endpointBreaker.prefersGDirect {
            if let data = try await performViaGDirect(request) {
                return data
            }
        }

        // Prefer pooled HTTP/2 URLSession first (~250ms multiplexed reuse vs ~2-4s cold curl subprocess handshakes).
        // If the system route cannot reach googleapis.com (e.g. GFW without proxy), automatically fall back to gdirect.
        var attempt = 0
        while true {
            try Task.checkCancellation()
            do {
                let (data, response) = try await session.data(for: request)
                if let http = response as? HTTPURLResponse, (http.statusCode == 429 || http.statusCode >= 500), attempt < 3 {
                    attempt += 1
                    try await Task.sleep(for: .milliseconds(300 * attempt * attempt))
                    continue
                }
                try validate(response, data: data)
                return data
            } catch {
                try Task.checkCancellation()
                if canUseGDirect && (error is URLError) {
                    if let data = try await performViaGDirect(request) {
                        endpointBreaker.markPreferGDirect()
                        return data
                    }
                }
                guard Self.retryable(error), attempt < 3 else { throw error }
                attempt += 1
                try await Task.sleep(for: .milliseconds(300 * attempt * attempt))
            }
        }
    }

    private func performViaGDirect(_ request: URLRequest) async throws -> Data? {
        guard let url = request.url, let host = url.host(),
              let header = request.value(forHTTPHeaderField: "Authorization") else {
            return nil
        }
        for endpoint in endpointBreaker.activeEndpoints(from: endpoints) {
            let ip = endpoint.ip.contains(":") ? "[\(endpoint.ip)]" : endpoint.ip
            let args = ["-q", "--silent", "--show-error", "--fail", "--noproxy", "*", "--connect-timeout", "2",
                        "--max-time", "6", "--resolve", "\(host):443:\(ip)", "--header", "@-", "--", url.absoluteString]
            if let result = try? await GDirectIntegration.run("/usr/bin/curl", args, timeout: 7,
                                                              input: Data("Authorization: \(header)\n".utf8)) {
                endpointBreaker.recordSuccess(ip: endpoint.ip)
                return result.output
            }
            endpointBreaker.recordFailure(ip: endpoint.ip)
            try Task.checkCancellation()
        }
        return nil
    }

    private final class EndpointCircuitBreaker: Sendable {
        private struct State {
            var failedIPs: Set<String> = []
            var preferredIP: String?
            var preferGDirect: Bool = false
        }

        private let state = Mutex(State())

        var prefersGDirect: Bool {
            state.withLock { $0.preferGDirect }
        }

        func markPreferGDirect() {
            state.withLock { $0.preferGDirect = true }
        }

        func activeEndpoints(from all: [GDirectEndpoint]) -> [GDirectEndpoint] {
            state.withLock { s in
                let available = all.filter { !s.failedIPs.contains($0.ip) }
                if let preferred = s.preferredIP,
                   let idx = available.firstIndex(where: { $0.ip == preferred }),
                   idx > 0 {
                    var reordered = available
                    let item = reordered.remove(at: idx)
                    reordered.insert(item, at: 0)
                    return Array(reordered.prefix(2))
                }
                return Array(available.prefix(2))
            }
        }

        func recordSuccess(ip: String) {
            state.withLock { s in
                s.preferredIP = ip
            }
        }

        func recordFailure(ip: String) {
            state.withLock { s in
                s.failedIPs.insert(ip)
                if s.preferredIP == ip {
                    s.preferredIP = nil
                }
            }
        }
    }

    private func validate(_ response: URLResponse, data: Data?) throws {
        guard let status = (response as? HTTPURLResponse)?.statusCode else { throw URLError(.badServerResponse) }
        if !(200..<300).contains(status) {
            let message = data.map { String(decoding: $0.prefix(512), as: UTF8.self) } ?? "Drive request failed."
            throw DriveTransportError.httpError(statusCode: status, message: message)
        }
    }

    private static func retryable(_ error: Error) -> Bool {
        if let error = error as? DriveTransportError, case let .httpError(status, _) = error {
            return status == 429 || status >= 500
        }
        return error is URLError
    }

    private func escape(_ value: String) -> String {
        value.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "'", with: "\\'")
    }

    private func segment(_ id: String) throws -> String {
        guard !id.isEmpty, id.utf8.allSatisfy({
            (48...57).contains($0) || (65...90).contains($0) || (97...122).contains($0) || $0 == 45 || $0 == 95
        }) else { throw DriveTransportError.invalidResponse("Invalid Drive identifier.") }
        return id
    }

    private nonisolated struct FileDTO: Decodable {
        struct ShortcutDetails: Decodable {
            let targetId: String?
            let targetMimeType: String?
        }

        let id: String
        let name: String
        let mimeType: String
        let size: String?
        let modifiedTime: String?
        let createdTime: String?
        let md5Checksum: String?
        let parents: [String]?
        let trashed: Bool?
        let webViewLink: String?
        let shortcutDetails: ShortcutDetails?

        var record: RemoteDriveFile {
            let fractional = Date.ISO8601FormatStyle(includingFractionalSeconds: true)
            let regular = Date.ISO8601FormatStyle()
            let date = modifiedTime.flatMap { (try? fractional.parse($0)) ?? (try? regular.parse($0)) }
            return RemoteDriveFile(id: id, name: name, mimeType: mimeType, size: size.flatMap(Int64.init),
                                   modifiedTime: date, md5Checksum: md5Checksum, parents: parents ?? [],
                                   trashed: trashed ?? false, webViewLink: webViewLink)
        }
    }
}
