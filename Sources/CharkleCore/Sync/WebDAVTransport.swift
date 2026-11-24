import Foundation

/// RFC 4918 WebDAV `DriveTransport` compatible with Jianguoyun (坚果云), Nextcloud,
/// Synology NAS, Alist, OwnCloud, and standard Apache/Nginx/Caddy WebDAV servers.
public final actor WebDAVTransport: DriveTransport {
    public nonisolated let displayName = "WebDAV"

    private static let defaultSession: URLSession = makePooledSession()

    private let baseURL: URL
    private let username: String
    private let authHeader: String?
    private let rootPathSegments: [String]
    private let session: URLSession
    private var knownFolderIDs: Set<String> = []

    /// Pooled URLSession tuned for WebDAV servers (bounded per-host concurrency, no stale HTTP cache).
    public nonisolated static func makePooledSession() -> URLSession {
        let config = URLSessionConfiguration.default
        config.httpMaximumConnectionsPerHost = 4
        config.timeoutIntervalForRequest = 45
        config.timeoutIntervalForResource = 300
        config.urlCache = nil
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        return URLSession(configuration: config)
    }

    public init(
        serverURL: String,
        username: String,
        password: String,
        remotePath: String = "/Charkle",
        session: URLSession? = nil
    ) throws {
        let trimmedURL = serverURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let rawURL = URL(string: trimmedURL),
              let scheme = rawURL.scheme?.lowercased(),
              let host = rawURL.host()?.lowercased(),
              !host.isEmpty else {
            throw DriveTransportError.notConfigured("请输入有效的 WebDAV 服务器地址（例如 https://dav.jianguoyun.com/dav/）。")
        }
        guard scheme == "https" || (scheme == "http" && Self.isLocalOrLANHost(host)) else {
            throw DriveTransportError.notConfigured("远程 WebDAV 服务器请使用 HTTPS 地址（局域网或本机可使用 HTTP）。")
        }

        let normalized = trimmedURL.hasSuffix("/") ? rawURL : rawURL.appending(path: "")
        self.baseURL = normalized
        self.username = username.trimmingCharacters(in: .whitespacesAndNewlines)
        if !self.username.isEmpty || !password.isEmpty {
            let credentials = Data("\(self.username):\(password)".utf8).base64EncodedString()
            self.authHeader = "Basic \(credentials)"
        } else {
            self.authHeader = nil
        }

        let segments = Self.normalizePathSegments(remotePath)
        for seg in segments {
            try DriveFiles.validateName(seg)
        }
        self.rootPathSegments = segments.isEmpty ? ["Charkle"] : segments
        self.session = session ?? Self.defaultSession
    }

    // MARK: - DriveTransport Protocol

    public func accountInfo() async throws -> DriveAccountInfo {
        var req = makeRequest(for: url(forRelativePath: "", isDirectory: true), method: "PROPFIND")
        req.setValue("0", forHTTPHeaderField: "Depth")
        req.setValue("application/xml; charset=utf-8", forHTTPHeaderField: "Content-Type")
        req.httpBody = Data(Self.propfindBody.utf8)

        let (data, response) = try await dataWithRetry(for: req)
        try validate(response, data: data, allowed: [200, 204, 207])

        let host = baseURL.host() ?? baseURL.absoluteString
        let label = username.isEmpty ? host : "\(username)@\(host)"
        return DriveAccountInfo(
            email: label,
            displayName: host,
            storageUsedBytes: nil,
            storageLimitBytes: nil,
            source: displayName
        )
    }

    public func fetchStartPageToken() async throws -> String {
        let snap = try await snapshot()
        return try JSONEncoder().encode(snap).base64EncodedString()
    }

    /// Single-pass full crawl returning both file dictionary and matching change token so initial sync
    /// does not crawl the WebDAV tree twice.
    func crawlSnapshotWithToken() async throws -> (files: [String: RemoteDriveFile], token: String) {
        let snap = try await snapshot()
        let token = try JSONEncoder().encode(snap).base64EncodedString()
        return (snap, token)
    }

    public func listChanges(pageToken: String) async throws -> DriveChangePage {
        guard let data = Data(base64Encoded: pageToken),
              let previous = try? JSONDecoder().decode([String: RemoteDriveFile].self, from: data) else {
            throw DriveTransportError.httpError(statusCode: 410, message: "WebDAV 变更游标已失效，将重新扫描。")
        }
        let current = try await snapshot()
        let changes = Set(previous.keys).union(current.keys).sorted().compactMap { id -> DriveChange? in
            guard previous[id] != current[id] else { return nil }
            return DriveChange(fileID: id, removed: current[id] == nil, file: current[id])
        }
        let nextToken = try JSONEncoder().encode(current).base64EncodedString()
        return DriveChangePage(changes: changes, newStartPageToken: nextToken)
    }

    public func findOrCreateFolder(named name: String, parentID: String) async throws -> RemoteDriveFile {
        try DriveFiles.validateName(name)
        let relPath = joinRelative(parent: parentID, name: name)
        let targetURL = url(forRelativePath: relPath, isDirectory: true)

        var req = makeRequest(for: targetURL, method: "MKCOL")
        req.timeoutInterval = 30
        let (data, response) = try await dataWithRetry(for: req)
        guard let http = response as? HTTPURLResponse else {
            throw URLError(.badServerResponse)
        }
        // 201 Created, 405 Method Not Allowed (collection already exists), 200/204 OK
        if ![200, 201, 204, 405].contains(http.statusCode) {
            try validate(response, data: data, allowed: [200, 201, 204, 405])
        }

        knownFolderIDs.insert(relPath)
        return RemoteDriveFile(
            id: relPath,
            name: name,
            mimeType: RemoteDriveFile.folderMimeType,
            size: nil,
            modifiedTime: Date(),
            md5Checksum: nil,
            parents: [parentID],
            trashed: false
        )
    }

    public func listFiles(inFolderID folderID: String) async throws -> [RemoteDriveFile] {
        let rel = folderID == DriveFiles.rootID ? "" : folderID
        let targetURL = url(forRelativePath: rel, isDirectory: true)
        var req = makeRequest(for: targetURL, method: "PROPFIND")
        req.setValue("1", forHTTPHeaderField: "Depth")
        req.setValue("application/xml; charset=utf-8", forHTTPHeaderField: "Content-Type")
        req.httpBody = Data(Self.propfindBody.utf8)

        let (data, response) = try await dataWithRetry(for: req)
        if let http = response as? HTTPURLResponse, http.statusCode == 404 {
            return []
        }
        try validate(response, data: data, allowed: [200, 207])
        let files = try Self.parsePropfindResponse(data, baseURL: baseURL, directoryRelPath: rel, parentID: folderID)
        if !rel.isEmpty { knownFolderIDs.insert(rel) }
        for item in files where item.isFolder {
            knownFolderIDs.insert(item.id)
        }
        return files
    }

    public func downloadData(fileID: String) async throws -> Data {
        let req = makeRequest(for: url(forRelativePath: fileID, isDirectory: false), method: "GET")
        let (data, response) = try await dataWithRetry(for: req)
        if let http = response as? HTTPURLResponse, http.statusCode == 404 {
            throw DriveTransportError.fileNotFound(fileID)
        }
        try validate(response, data: data, allowed: [200, 206])
        return data
    }

    public func downloadFile(fileID: String, to destinationURL: URL) async throws {
        let req = makeRequest(for: url(forRelativePath: fileID, isDirectory: false), method: "GET")
        let (tempURL, response) = try await downloadWithRetry(for: req)
        defer { try? FileManager.default.removeItem(at: tempURL) }
        if let http = response as? HTTPURLResponse, http.statusCode == 404 {
            throw DriveTransportError.fileNotFound(fileID)
        }
        try validate(response, data: nil, allowed: [200, 206])
        try DriveFiles.writeFile(tempURL, to: destinationURL)
    }

    public func uploadData(
        _ data: Data,
        name: String,
        mimeType: String,
        parentID: String,
        existingFileID: String?
    ) async throws -> RemoteDriveFile {
        try DriveFiles.validateName(name)
        let relPath = existingFileID ?? joinRelative(parent: parentID, name: name)
        var req = makeRequest(for: url(forRelativePath: relPath, isDirectory: false), method: "PUT")
        req.setValue(mimeType, forHTTPHeaderField: "Content-Type")
        if existingFileID == nil {
            req.setValue("*", forHTTPHeaderField: "If-None-Match")
        }
        req.httpBody = data

        let (respData, response) = try await dataWithRetry(for: req)
        if existingFileID == nil, let http = response as? HTTPURLResponse, http.statusCode == 412 {
            throw DriveTransportError.fileAlreadyExists(name)
        }
        try validate(response, data: respData, allowed: [200, 201, 204])
        return RemoteDriveFile(
            id: relPath,
            name: name,
            mimeType: mimeType,
            size: Int64(data.count),
            modifiedTime: Date(),
            md5Checksum: nil,
            parents: [parentID],
            trashed: false
        )
    }

    public func uploadFile(
        from localURL: URL,
        name: String,
        mimeType: String,
        parentID: String,
        existingFileID: String?
    ) async throws -> RemoteDriveFile {
        try DriveFiles.validateName(name)
        let relPath = existingFileID ?? joinRelative(parent: parentID, name: name)
        var req = makeRequest(for: url(forRelativePath: relPath, isDirectory: false), method: "PUT")
        req.timeoutInterval = 300
        req.setValue(mimeType, forHTTPHeaderField: "Content-Type")
        if existingFileID == nil {
            req.setValue("*", forHTTPHeaderField: "If-None-Match")
        }

        let (respData, response) = try await uploadWithRetry(for: req, fromFile: localURL)
        if existingFileID == nil, let http = response as? HTTPURLResponse, http.statusCode == 412 {
            throw DriveTransportError.fileAlreadyExists(name)
        }
        try validate(response, data: respData, allowed: [200, 201, 204])
        let size = Int64((try? localURL.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
        return RemoteDriveFile(
            id: relPath,
            name: name,
            mimeType: mimeType,
            size: size,
            modifiedTime: Date(),
            md5Checksum: nil,
            parents: [parentID],
            trashed: false
        )
    }

    public func moveFile(
        fileID: String,
        fromParentID: String?,
        toParentID: String,
        newName: String?
    ) async throws -> RemoteDriveFile {
        let currentName = (fileID as NSString).lastPathComponent
        let finalName = newName ?? currentName
        try DriveFiles.validateName(finalName)
        let targetRel = joinRelative(parent: toParentID, name: finalName)
        var isCollection = knownFolderIDs.contains(fileID)

        if targetRel != fileID {
            func sendMove(asDirectory: Bool) async throws -> (Data, URLResponse) {
                var req = makeRequest(for: url(forRelativePath: fileID, isDirectory: asDirectory), method: "MOVE")
                req.setValue(url(forRelativePath: targetRel, isDirectory: asDirectory).absoluteString, forHTTPHeaderField: "Destination")
                req.setValue("F", forHTTPHeaderField: "Overwrite")
                return try await dataWithRetry(for: req)
            }

            var (data, response) = try await sendMove(asDirectory: isCollection)
            if !isCollection, let http = response as? HTTPURLResponse, (http.statusCode == 301 || http.statusCode == 308) {
                isCollection = true
                (data, response) = try await sendMove(asDirectory: true)
            }
            if let http = response as? HTTPURLResponse, http.statusCode == 412 {
                throw DriveTransportError.fileAlreadyExists(finalName)
            }
            try validate(response, data: data, allowed: [200, 201, 204])

            if isCollection {
                knownFolderIDs.remove(fileID)
                knownFolderIDs.insert(targetRel)
                let oldPrefix = fileID + "/"
                let newPrefix = targetRel + "/"
                let updated = knownFolderIDs.map { id in
                    id.hasPrefix(oldPrefix) ? newPrefix + id.dropFirst(oldPrefix.count) : id
                }
                knownFolderIDs = Set(updated)
            }
        }

        return RemoteDriveFile(
            id: targetRel,
            name: finalName,
            mimeType: isCollection ? RemoteDriveFile.folderMimeType : MediaPipeline.mimeType(fileName: finalName),
            size: nil,
            modifiedTime: Date(),
            md5Checksum: nil,
            parents: [toParentID],
            trashed: false
        )
    }

    public func trashFile(fileID: String) async throws {
        let isCollection = knownFolderIDs.contains(fileID)
        let req = makeRequest(for: url(forRelativePath: fileID, isDirectory: isCollection), method: "DELETE")
        let (data, response) = try await dataWithRetry(for: req)
        if let http = response as? HTTPURLResponse, http.statusCode == 404 {
            knownFolderIDs.remove(fileID)
            return
        }
        try validate(response, data: data, allowed: [200, 204])
        knownFolderIDs.remove(fileID)
    }

    // MARK: - Snapshot & Helpers

    private func snapshot() async throws -> [String: RemoteDriveFile] {
        let rootRel = rootPathSegments.joined(separator: "/")
        var result: [String: RemoteDriveFile] = [:]
        var queue = [rootRel]
        var visited = Set<String>()
        var idx = 0

        while idx < queue.count {
            let folderID = queue[idx]
            idx += 1
            guard visited.insert(folderID).inserted else { continue }
            let entries = try await listFiles(inFolderID: folderID)
            for item in entries {
                result[item.id] = item
                if item.isFolder && !item.name.hasPrefix(".") {
                    queue.append(item.id)
                }
            }
        }
        return result
    }

    private func makeRequest(for url: URL, method: String) -> URLRequest {
        var req = URLRequest(url: url, timeoutInterval: 45)
        req.httpMethod = method
        if let authHeader {
            req.setValue(authHeader, forHTTPHeaderField: "Authorization")
        }
        return req
    }

    private func dataWithRetry(for request: URLRequest) async throws -> (Data, URLResponse) {
        var attempt = 0
        while true {
            try Task.checkCancellation()
            do {
                let (data, response) = try await session.data(for: request)
                if let http = response as? HTTPURLResponse, Self.isRetryableStatus(http.statusCode), attempt < 3 {
                    attempt += 1
                    try await Task.sleep(for: Self.retryDelay(for: http, attempt: attempt))
                    continue
                }
                return (data, response)
            } catch {
                try Task.checkCancellation()
                guard Self.isRetryableError(error), attempt < 3 else { throw error }
                attempt += 1
                try await Task.sleep(for: .milliseconds(350 * attempt * attempt))
            }
        }
    }

    private func downloadWithRetry(for request: URLRequest) async throws -> (URL, URLResponse) {
        var attempt = 0
        while true {
            try Task.checkCancellation()
            do {
                let (tempURL, response) = try await session.download(for: request)
                if let http = response as? HTTPURLResponse, Self.isRetryableStatus(http.statusCode), attempt < 3 {
                    try? FileManager.default.removeItem(at: tempURL)
                    attempt += 1
                    try await Task.sleep(for: Self.retryDelay(for: http, attempt: attempt))
                    continue
                }
                return (tempURL, response)
            } catch {
                try Task.checkCancellation()
                guard Self.isRetryableError(error), attempt < 3 else { throw error }
                attempt += 1
                try await Task.sleep(for: .milliseconds(350 * attempt * attempt))
            }
        }
    }

    private func uploadWithRetry(for request: URLRequest, fromFile localURL: URL) async throws -> (Data, URLResponse) {
        var attempt = 0
        while true {
            try Task.checkCancellation()
            do {
                let (data, response) = try await session.upload(for: request, fromFile: localURL)
                if let http = response as? HTTPURLResponse, Self.isRetryableStatus(http.statusCode), attempt < 3 {
                    attempt += 1
                    try await Task.sleep(for: Self.retryDelay(for: http, attempt: attempt))
                    continue
                }
                return (data, response)
            } catch {
                try Task.checkCancellation()
                guard Self.isRetryableError(error), attempt < 3 else { throw error }
                attempt += 1
                try await Task.sleep(for: .milliseconds(350 * attempt * attempt))
            }
        }
    }

    private static func isRetryableStatus(_ code: Int) -> Bool {
        code == 429 || code == 500 || code == 502 || code == 503 || code == 504
    }

    private static func isRetryableError(_ error: Error) -> Bool {
        guard let urlError = error as? URLError else { return false }
        switch urlError.code {
        case .timedOut, .networkConnectionLost, .notConnectedToInternet, .cannotConnectToHost, .dnsLookupFailed, .cannotFindHost:
            return true
        default:
            return false
        }
    }

    private static func retryDelay(for response: HTTPURLResponse, attempt: Int) -> Duration {
        if let retryAfter = response.value(forHTTPHeaderField: "Retry-After")?.trimmingCharacters(in: .whitespacesAndNewlines),
           let seconds = Double(retryAfter), seconds.isFinite, seconds > 0 {
            let clamped = min(10.0, max(0.2, seconds))
            return .milliseconds(Int(clamped * 1000))
        }
        return .milliseconds(350 * attempt * attempt)
    }

    private func joinRelative(parent: String, name: String) -> String {
        if parent == DriveFiles.rootID || parent.isEmpty {
            return name
        }
        return parent + "/" + name
    }

    private func url(forRelativePath relPath: String, isDirectory: Bool) -> URL {
        let segments = relPath.split(separator: "/").map(String.init).filter { !$0.isEmpty }
        var current = baseURL
        for (i, segment) in segments.enumerated() {
            let last = i == segments.count - 1
            current = current.appending(path: segment, directoryHint: (last && isDirectory) || !last ? .isDirectory : .notDirectory)
        }
        return current
    }

    private func validate(_ response: URLResponse, data: Data?, allowed: Set<Int>) throws {
        guard let http = response as? HTTPURLResponse else {
            throw URLError(.badServerResponse)
        }
        if allowed.contains(http.statusCode) { return }
        if http.statusCode == 401 || http.statusCode == 403 {
            throw DriveTransportError.authenticationRequired("WebDAV 账号或应用密码无效，请检查后重试。")
        }
        if http.statusCode == 404 {
            throw DriveTransportError.fileNotFound(http.url?.path ?? "")
        }
        let body = data.map { String(decoding: $0.prefix(300), as: UTF8.self) } ?? ""
        throw DriveTransportError.httpError(statusCode: http.statusCode, message: body.isEmpty ? "HTTP \(http.statusCode)" : body)
    }

    public static func normalizePathSegments(_ raw: String) -> [String] {
        raw.split(separator: "/")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty && $0 != "." && $0 != ".." }
    }

    private static func isLocalOrLANHost(_ host: String) -> Bool {
        if host == "localhost" || host == "127.0.0.1" || host == "::1" || host.hasSuffix(".local") {
            return true
        }
        if host.hasPrefix("192.168.") || host.hasPrefix("10.") { return true }
        if host.hasPrefix("172.") {
            let parts = host.split(separator: ".")
            if parts.count >= 2, let second = Int(parts[1]), (16...31).contains(second) {
                return true
            }
        }
        return false
    }

    private static let propfindBody = """
    <?xml version="1.0" encoding="utf-8" ?>
    <D:propfind xmlns:D="DAV:">
      <D:prop>
        <D:displayname/>
        <D:resourcetype/>
        <D:getcontentlength/>
        <D:getlastmodified/>
        <D:getcontenttype/>
      </D:prop>
    </D:propfind>
    """

    // MARK: - Namespace-Agnostic WebDAV XML PROPFIND Parser

    public static func parsePropfindResponse(
        _ data: Data,
        baseURL: URL,
        directoryRelPath: String,
        parentID: String
    ) throws -> [RemoteDriveFile] {
        let delegate = PropfindXMLDelegate()
        let parser = XMLParser(data: data)
        parser.delegate = delegate
        guard parser.parse() else {
            throw DriveTransportError.invalidResponse("无法解析 WebDAV 目录列表。")
        }

        let basePath = normalizeSlashPath(baseURL.path)
        let selfRel = normalizeRelative(directoryRelPath)
        var results: [RemoteDriveFile] = []

        for entry in delegate.entries {
            guard let resolved = URL(string: entry.href, relativeTo: baseURL)?.standardized else { continue }
            let itemPath = normalizeSlashPath(resolved.path)
            let rel: String
            if basePath == "/" {
                rel = normalizeRelative(itemPath)
            } else if itemPath.hasPrefix(basePath + "/") {
                rel = normalizeRelative(String(itemPath.dropFirst(basePath.count + 1)))
            } else if itemPath == basePath {
                rel = ""
            } else {
                continue
            }

            // Skip self directory entry returned by PROPFIND Depth: 1
            if rel == selfRel || rel.isEmpty { continue }
            let name = (rel as NSString).lastPathComponent
            if name == ".DS_Store" || name.hasPrefix(".charkle-write-") { continue }

            let mime: String
            if entry.isCollection {
                mime = RemoteDriveFile.folderMimeType
            } else if let ct = entry.contentType, !ct.isEmpty {
                mime = ct.split(separator: ";").first.map { String($0).trimmingCharacters(in: .whitespaces) } ?? ct
            } else {
                mime = MediaPipeline.mimeType(fileName: name)
            }

            results.append(RemoteDriveFile(
                id: rel,
                name: name,
                mimeType: mime,
                size: entry.isCollection ? nil : entry.contentLength,
                modifiedTime: entry.lastModified,
                md5Checksum: nil,
                parents: [parentID],
                trashed: false
            ))
        }

        return results.sorted { ($0.name, $0.id) < ($1.name, $1.id) }
    }

    private static func normalizeSlashPath(_ path: String) -> String {
        let trimmed = path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        return trimmed.isEmpty ? "/" : "/" + trimmed
    }

    private static func normalizeRelative(_ path: String) -> String {
        path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
    }
}

private nonisolated final class PropfindXMLDelegate: NSObject, XMLParserDelegate {
    struct Entry {
        var href: String = ""
        var isCollection: Bool = false
        var contentLength: Int64?
        var lastModified: Date?
        var contentType: String?
    }

    var entries: [Entry] = []
    private var current: Entry?
    private var inPropstat = false
    private var inResourceType = false
    private var propstatStatus: String?
    private var propstatIsCollection = false
    private var propstatContentLength: Int64?
    private var propstatLastModified: Date?
    private var propstatContentType: String?
    private var buffer = ""

    private let rfc1123Formatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(secondsFromGMT: 0)
        f.dateFormat = "EEE, dd MMM yyyy HH:mm:ss zzz"
        return f
    }()

    private func parseWebDAVDate(_ text: String) -> Date? {
        if let rfc = rfc1123Formatter.date(from: text) { return rfc }
        if let frac = try? Date.ISO8601FormatStyle(includingFractionalSeconds: true).parse(text) { return frac }
        return try? Date.ISO8601FormatStyle().parse(text)
    }

    private func localName(_ elementName: String) -> String {
        if let idx = elementName.lastIndex(of: ":") {
            return String(elementName[elementName.index(after: idx)...]).lowercased()
        }
        return elementName.lowercased()
    }

    func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?,
                qualifiedName qName: String?, attributes attributeDict: [String: String] = [:]) {
        let name = localName(elementName)
        buffer = ""
        switch name {
        case "response":
            current = Entry()
        case "propstat":
            inPropstat = true
            propstatStatus = nil
            propstatIsCollection = false
            propstatContentLength = nil
            propstatLastModified = nil
            propstatContentType = nil
        case "resourcetype":
            inResourceType = true
        case "collection":
            if inResourceType {
                if inPropstat {
                    propstatIsCollection = true
                } else {
                    current?.isCollection = true
                }
            }
        default:
            break
        }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        buffer.append(string)
    }

    func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?, qualifiedName qName: String?) {
        let name = localName(elementName)
        let text = buffer.trimmingCharacters(in: .whitespacesAndNewlines)
        switch name {
        case "href":
            if current?.href.isEmpty == true { current?.href = text }
        case "status":
            if inPropstat && !text.isEmpty { propstatStatus = text }
        case "resourcetype":
            inResourceType = false
        case "getcontentlength":
            if let len = Int64(text) {
                if inPropstat { propstatContentLength = len } else { current?.contentLength = len }
            }
        case "getlastmodified":
            if let parsed = parseWebDAVDate(text) {
                if inPropstat { propstatLastModified = parsed } else { current?.lastModified = parsed }
            }
        case "getcontenttype":
            if !text.isEmpty {
                if inPropstat { propstatContentType = text } else { current?.contentType = text }
            }
        case "propstat":
            let statusOK: Bool = {
                guard let status = propstatStatus else { return true }
                return status.contains(" 200 ") || status.contains(" 201 ") || status.contains(" 204 ")
            }()
            if statusOK {
                if propstatIsCollection { current?.isCollection = true }
                if let len = propstatContentLength { current?.contentLength = len }
                if let mod = propstatLastModified { current?.lastModified = mod }
                if let ct = propstatContentType { current?.contentType = ct }
            }
            inPropstat = false
        case "response":
            if let entry = current, !entry.href.isEmpty {
                entries.append(entry)
            }
            current = nil
        default:
            break
        }
        buffer = ""
    }
}
