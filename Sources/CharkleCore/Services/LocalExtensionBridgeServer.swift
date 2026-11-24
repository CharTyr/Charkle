import Foundation
import Network
import Security
import Synchronization

/// Local loopback HTTP bridge (`http://127.0.0.1:41937`) speaking the Charkle `/api/v1/*`
/// extension protocol so Chrome, Arc, Edge, Brave, and Safari extensions can connect directly
/// to Charkle macOS with zero idle CPU usage and constant-time Bearer token protection.
public actor LocalExtensionBridgeServer {
    public enum MutationKind: String, Sendable {
        case ingest
        case folderCreate
    }

    public struct StatusSnapshot: Equatable, Sendable {
        public let isRunning: Bool
        public let port: UInt16
        public let baseURL: String

        public init(isRunning: Bool, port: UInt16) {
            self.isRunning = isRunning
            self.port = port
            self.baseURL = port > 0 ? "http://127.0.0.1:\(port)" : ""
        }
    }

    public static let defaultPort: UInt16 = 41937
    public static let fallbackPortCount: UInt16 = 10
    private static let maxRequestBodyBytes = 48 * 1024 * 1024

    private let engine: any CharkleEngineProtocol
    private var token: String
    private var allowLocalAutoPair: Bool
    private var listener: NWListener?
    private var boundPort: UInt16 = 0
    private let preferredPort: UInt16
    private let allowEphemeralPort: Bool
    private let ioQueue = DispatchQueue(label: "com.charkle.extension.bridge.io", qos: .userInitiated)
    private let activeSessions = Mutex<[UUID: HTTPConnectionSession]>([:])
    private let onLibraryMutated: (@Sendable (MutationKind, Int, UUID?, UUID?) -> Void)?

    public init(
        engine: any CharkleEngineProtocol,
        token: String,
        allowLocalAutoPair: Bool = true,
        preferredPort: UInt16 = LocalExtensionBridgeServer.defaultPort,
        allowEphemeralPort: Bool = false,
        onLibraryMutated: (@Sendable (MutationKind, Int, UUID?, UUID?) -> Void)? = nil
    ) {
        self.engine = engine
        self.token = token
        self.allowLocalAutoPair = allowLocalAutoPair
        self.preferredPort = preferredPort
        self.allowEphemeralPort = allowEphemeralPort
        self.onLibraryMutated = onLibraryMutated
    }

    public static func generateToken() -> String {
        var bytes = [UInt8](repeating: 0, count: 24)
        let status = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        if status == errSecSuccess {
            return bytes.map { String(format: "%02x", $0) }.joined()
        }
        return UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased()
            + UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased().prefix(16)
    }

    public func updateToken(_ newToken: String) {
        self.token = newToken.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    public func updateAutoPairEnabled(_ enabled: Bool) {
        self.allowLocalAutoPair = enabled
    }

    public func status() -> StatusSnapshot {
        StatusSnapshot(isRunning: listener != nil && boundPort > 0, port: boundPort)
    }

    @discardableResult
    public func start() async throws -> StatusSnapshot {
        if listener != nil && boundPort > 0 {
            return StatusSnapshot(isRunning: true, port: boundPort)
        }

        let candidatePorts: [NWEndpoint.Port]
        if allowEphemeralPort && preferredPort == 0 {
            candidatePorts = [.any]
        } else {
            let startPort = preferredPort == 0 ? Self.defaultPort : preferredPort
            candidatePorts = (0..<Self.fallbackPortCount).compactMap { offset in
                NWEndpoint.Port(rawValue: startPort &+ offset)
            }
        }

        var lastError: Error?
        for candidatePort in candidatePorts {
            do {
                let (startedListener, actualPort) = try await bindListener(on: candidatePort)
                self.listener = startedListener
                self.boundPort = actualPort
                return StatusSnapshot(isRunning: true, port: actualPort)
            } catch {
                lastError = error
            }
        }

        throw lastError ?? NSError(
            domain: "com.charkle.extension.bridge",
            code: 1,
            userInfo: [NSLocalizedDescriptionKey: "无法在 127.0.0.1 绑定本地扩展桥接端口。"]
        )
    }

    public func stop() {
        listener?.cancel()
        listener = nil
        boundPort = 0
        let sessionsToCancel = activeSessions.withLock { map -> [HTTPConnectionSession] in
            let list = Array(map.values)
            map.removeAll()
            return list
        }
        for session in sessionsToCancel {
            session.cancel()
        }
    }

    private func bindListener(on port: NWEndpoint.Port) async throws -> (NWListener, UInt16) {
        let params = NWParameters.tcp
        params.allowLocalEndpointReuse = true
        params.requiredLocalEndpoint = NWEndpoint.hostPort(host: .ipv4(.loopback), port: port)
        let created = try NWListener(using: params)

        let actualPort: UInt16 = try await withCheckedThrowingContinuation { cont in
            let settled = Mutex(false)
            created.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    let shouldResume = settled.withLock { flag -> Bool in
                        guard !flag else { return false }
                        flag = true
                        return true
                    }
                    if shouldResume {
                        if let rawPort = created.port?.rawValue, rawPort > 0 {
                            cont.resume(returning: rawPort)
                        } else {
                            created.cancel()
                            cont.resume(throwing: NSError(
                                domain: "com.charkle.extension.bridge",
                                code: 2,
                                userInfo: [NSLocalizedDescriptionKey: "桥接服务未能分配端口。"]
                            ))
                        }
                    }
                case .failed(let error):
                    let shouldResume = settled.withLock { flag -> Bool in
                        guard !flag else { return false }
                        flag = true
                        return true
                    }
                    if shouldResume {
                        created.cancel()
                        cont.resume(throwing: error)
                    }
                case .cancelled:
                    let shouldResume = settled.withLock { flag -> Bool in
                        guard !flag else { return false }
                        flag = true
                        return true
                    }
                    if shouldResume {
                        cont.resume(throwing: CancellationError())
                    }
                default:
                    break
                }
            }
            created.newConnectionHandler = { [weak self] connection in
                guard let self else {
                    connection.cancel()
                    return
                }
                let sessionID = UUID()
                let session = HTTPConnectionSession(
                    connection: connection,
                    queue: self.ioQueue,
                    maxBodyBytes: Self.maxRequestBodyBytes,
                    onFinish: { [weak self] in
                        _ = self?.activeSessions.withLock { $0.removeValue(forKey: sessionID) }
                    }
                ) { [weak self] request in
                    guard let self else {
                        return HTTPResponse.json(status: 503, body: ["error": "服务已停止"])
                    }
                    return await self.handle(request: request)
                }
                self.activeSessions.withLock { $0[sessionID] = session }
                session.start()
            }
            created.start(queue: self.ioQueue)
        }

        // Clear startup handler once bound while keeping connection handler active.
        created.stateUpdateHandler = { [weak self] state in
            if case .failed = state {
                Task { await self?.handleListenerFailure() }
            }
        }
        return (created, actualPort)
    }

    private func handleListenerFailure() {
        listener?.cancel()
        listener = nil
        boundPort = 0
    }

    // MARK: - HTTP Router

    private func handle(request: HTTPRequest) async -> HTTPResponse {
        let corsHeaders = buildCORSHeaders(for: request.headers["origin"])

        if request.method == "OPTIONS" {
            return HTTPResponse(status: 204, headers: corsHeaders, body: Data())
        }

        let path = request.pathWithoutQuery

        // Public minimal liveness probe (no sensitive user or library data exposed).
        if request.method == "GET" && path == "/api/v1/health" {
            return HTTPResponse.json(
                status: 200,
                extraHeaders: corsHeaders,
                body: [
                    "ok": true,
                    "app": "charkle-macos",
                    "name": "Charkle macOS",
                    "port": Int(boundPort),
                    "autoPair": allowLocalAutoPair
                ]
            )
        }

        // Zero-config same-machine pairing for Charkle's Safari & Chrome browser extensions.
        // Strictly gated to browser-extension origins (`chrome-extension://`, `safari-web-extension://`,
        // `moz-extension://`) plus custom non-simple header `X-Charkle-Extension: 1`, so arbitrary
        // websites (including localhost web pages) can never pair or obtain the bridge token.
        if request.method == "POST" && path == "/api/v1/auth/local-pair" {
            return handleLocalAutoPair(request: request, corsHeaders: corsHeaders)
        }

        let isAuthorized = validateBearerToken(header: request.headers["authorization"])

        // Matches Charkle Web `GET /api/v1/auth/status` contract so the extension handles auth identically.
        if request.method == "GET" && path == "/api/v1/auth/status" {
            if isAuthorized {
                return HTTPResponse.json(
                    status: 200,
                    extraHeaders: corsHeaders,
                    body: [
                        "initialized": true,
                        "authenticated": true,
                        "app": "charkle-macos",
                        "user": [
                            "id": "local-macos",
                            "username": "desktop",
                            "displayName": "Charkle macOS",
                            "role": "owner"
                        ],
                        "sessionCount": 1
                    ]
                )
            } else {
                return HTTPResponse.json(
                    status: 200,
                    extraHeaders: corsHeaders,
                    body: [
                        "initialized": true,
                        "authenticated": false,
                        "app": "charkle-macos",
                        "user": NSNull(),
                        "sessionCount": 0
                    ]
                )
            }
        }

        guard isAuthorized else {
            return HTTPResponse.json(
                status: 401,
                extraHeaders: corsHeaders,
                body: [
                    "error": "访问令牌无效或已更新，请在 Charkle 桌面端「设置 → 插件与扩展」重新复制。",
                    "code": "UNAUTHORIZED"
                ]
            )
        }

        do {
            switch (request.method, path) {
            case ("GET", "/api/v1/folders"):
                return try await handleGetFolders(corsHeaders: corsHeaders)

            case ("POST", "/api/v1/folders"):
                return try await handleCreateFolder(request: request, corsHeaders: corsHeaders)

            case ("GET", "/api/v1/boards"):
                return try await handleGetBoards(corsHeaders: corsHeaders)

            case ("GET", "/api/v1/assets/existing-sources"):
                return try await handleGetExistingSources(corsHeaders: corsHeaders)

            case ("POST", "/api/v1/assets/ingest"):
                return try await handleIngest(request: request, corsHeaders: corsHeaders)

            case ("POST", "/api/v1/assets/upload"):
                return try await handleMultipartUpload(request: request, corsHeaders: corsHeaders)

            default:
                return HTTPResponse.json(
                    status: 404,
                    extraHeaders: corsHeaders,
                    body: ["error": "接口不存在。", "code": "NOT_FOUND"]
                )
            }
        } catch {
            return HTTPResponse.json(
                status: 500,
                extraHeaders: corsHeaders,
                body: ["error": error.localizedDescription, "code": "INTERNAL_ERROR"]
            )
        }
    }

    // MARK: - Route Handlers

    private func handleGetFolders(corsHeaders: [String: String]) async throws -> HTTPResponse {
        let folders = try await engine.fetchFolders()
        let serialized: [[String: Any]] = folders.map { f in
            var dict: [String: Any] = [
                "id": f.id.uuidString,
                "name": f.name,
                "sortOrder": f.sortOrder,
                "assetCount": f.assetCount
            ]
            dict["parentID"] = f.parentID?.uuidString ?? NSNull()
            return dict
        }
        return HTTPResponse.json(status: 200, extraHeaders: corsHeaders, body: ["folders": serialized])
    }

    private enum OptionalUUIDParse {
        case valid(UUID?)
        case invalid
    }

    private static func parseOptionalUUID(_ raw: Any?) -> OptionalUUIDParse {
        guard let raw, !(raw is NSNull) else { return .valid(nil) }
        guard let str = raw as? String else { return .invalid }
        let trimmed = str.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return .valid(nil) }
        guard let uuid = UUID(uuidString: trimmed) else { return .invalid }
        return .valid(uuid)
    }

    private func handleCreateFolder(request: HTTPRequest, corsHeaders: [String: String]) async throws -> HTTPResponse {
        guard let obj = try? JSONSerialization.jsonObject(with: request.body) as? [String: Any] else {
            return HTTPResponse.json(status: 400, extraHeaders: corsHeaders, body: ["error": "请求内容格式不正确。", "code": "INVALID_JSON"])
        }
        let rawName = (obj["name"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !rawName.isEmpty else {
            return HTTPResponse.json(status: 400, extraHeaders: corsHeaders, body: ["error": "请填写文件夹名称。", "code": "INVALID_NAME"])
        }
        let parentID: UUID?
        switch Self.parseOptionalUUID(obj["parentID"]) {
        case .valid(let id): parentID = id
        case .invalid:
            return HTTPResponse.json(status: 400, extraHeaders: corsHeaders, body: ["error": "父文件夹 ID 格式不正确。", "code": "INVALID_ID"])
        }
        let reuseExisting = (obj["reuseExisting"] as? Bool) ?? false

        if reuseExisting {
            let existing = try await engine.fetchFolders()
            if let matched = existing.first(where: {
                $0.parentID == parentID && $0.name.caseInsensitiveCompare(rawName) == .orderedSame
            }) {
                var dict: [String: Any] = [
                    "id": matched.id.uuidString,
                    "name": matched.name,
                    "sortOrder": matched.sortOrder,
                    "assetCount": matched.assetCount
                ]
                dict["parentID"] = matched.parentID?.uuidString ?? NSNull()
                return HTTPResponse.json(status: 200, extraHeaders: corsHeaders, body: ["folder": dict, "reused": true])
            }
        }

        let created = try await engine.createFolder(name: rawName, parentID: parentID)
        onLibraryMutated?(.folderCreate, 1, created.id, nil)
        var dict: [String: Any] = [
            "id": created.id.uuidString,
            "name": created.name,
            "sortOrder": created.sortOrder,
            "assetCount": 0
        ]
        dict["parentID"] = created.parentID?.uuidString ?? NSNull()
        return HTTPResponse.json(status: 201, extraHeaders: corsHeaders, body: ["folder": dict, "reused": false])
    }

    private func handleGetBoards(corsHeaders: [String: String]) async throws -> HTTPResponse {
        let boards = try await engine.fetchBoards()
        let serialized: [[String: Any]] = boards.map { b in
            [
                "id": b.id.uuidString,
                "title": b.title,
                "itemCount": b.itemCount
            ]
        }
        return HTTPResponse.json(status: 200, extraHeaders: corsHeaders, body: ["boards": serialized])
    }

    private func handleGetExistingSources(corsHeaders: [String: String]) async throws -> HTTPResponse {
        let (sources, keys) = try await fetchExistingSourceKeys()
        return HTTPResponse.json(
            status: 200,
            extraHeaders: corsHeaders,
            body: [
                "count": keys.count,
                "sources": Array(sources),
                "canonicalKeys": Array(keys)
            ]
        )
    }

    private func handleIngest(request: HTTPRequest, corsHeaders: [String: String]) async throws -> HTTPResponse {
        guard let body = try? JSONSerialization.jsonObject(with: request.body) as? [String: Any],
              let rawInputs = body["inputs"] as? [[String: Any]], !rawInputs.isEmpty else {
            return HTTPResponse.json(
                status: 400,
                extraHeaders: corsHeaders,
                body: ["error": "请提供至少一个待导入项。", "code": "INVALID_INPUT"]
            )
        }

        let targetFolderID: UUID?
        switch Self.parseOptionalUUID(body["targetFolderID"]) {
        case .valid(let id): targetFolderID = id
        case .invalid:
            return HTTPResponse.json(status: 400, extraHeaders: corsHeaders, body: ["error": "目标文件夹 ID 格式不正确。", "code": "INVALID_ID"])
        }
        let targetBoardID: UUID?
        switch Self.parseOptionalUUID(body["targetBoardID"]) {
        case .valid(let id): targetBoardID = id
        case .invalid:
            return HTTPResponse.json(status: 400, extraHeaders: corsHeaders, body: ["error": "目标情绪板 ID 格式不正确。", "code": "INVALID_ID"])
        }
        let skipDuplicates = (body["skipDuplicates"] as? Bool) ?? false

        var knownKeys: Set<String> = []
        if skipDuplicates {
            knownKeys = (try? await fetchExistingSourceKeys().keys) ?? []
        }

        var parsedInputs: [CaptureInput] = []
        var skipped = 0

        for item in rawInputs {
            guard let type = item["type"] as? String else { continue }
            switch type {
            case "webURL":
                guard let urlStr = (item["url"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
                      let url = URL(string: urlStr),
                      WebBookmark.isWebURL(url) else {
                    continue
                }
                if skipDuplicates, let key = SocialPostResolver.canonicalDedupKey(for: url.absoluteString) {
                    if !knownKeys.insert(key).inserted {
                        skipped += 1
                        continue
                    }
                }
                let title = (item["title"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
                let notes = (item["notes"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
                parsedInputs.append(.webURL(
                    url,
                    title: (title?.isEmpty == false) ? title : nil,
                    notes: (notes?.isEmpty == false) ? notes : nil
                ))

            case "imageData":
                guard let rawBase64 = item["base64Data"] as? String,
                      let imageData = Self.decodeBase64Payload(rawBase64),
                      !imageData.isEmpty else {
                    continue
                }
                let name = (item["suggestedName"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
                let sourceURL = (item["sourceURL"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
                parsedInputs.append(.imageData(
                    imageData,
                    suggestedName: (name?.isEmpty == false) ? name! : "Clip.png",
                    sourceURL: (sourceURL?.isEmpty == false) ? sourceURL : nil
                ))

            case "textSnippet":
                let text = (item["text"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                guard !text.isEmpty else { continue }
                let title = (item["title"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
                let sourceURL = (item["sourceURL"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
                parsedInputs.append(.textSnippet(
                    title: (title?.isEmpty == false) ? title! : "文字灵感",
                    text: text,
                    sourceURL: (sourceURL?.isEmpty == false) ? sourceURL : nil
                ))

            case "colorSwatch":
                guard let hex = (item["hex"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
                      !hex.isEmpty else {
                    continue
                }
                let title = (item["title"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
                parsedInputs.append(.colorSwatch(hex: hex, title: (title?.isEmpty == false) ? title : nil))

            case "socialBookmark":
                guard let (meta, coverData, tags) = Self.parseSocialBookmarkPayload(item) else { continue }
                if skipDuplicates, let key = SocialPostResolver.canonicalDedupKey(for: meta.originalURL) {
                    if !knownKeys.insert(key).inserted {
                        skipped += 1
                        continue
                    }
                }
                parsedInputs.append(.socialBookmark(meta, coverImageData: coverData, tags: tags))

            default:
                continue
            }
        }

        if parsedInputs.isEmpty && skipped > 0 {
            return HTTPResponse.json(
                status: 200,
                extraHeaders: corsHeaders,
                body: [
                    "assets": [],
                    "created": 0,
                    "skipped": skipped
                ]
            )
        }

        guard !parsedInputs.isEmpty else {
            return HTTPResponse.json(
                status: 400,
                extraHeaders: corsHeaders,
                body: ["error": "未找到有效的待导入素材。", "code": "INVALID_INPUT"]
            )
        }

        let created = try await engine.ingest(parsedInputs, targetFolderID: targetFolderID, targetBoardID: targetBoardID)
        if !created.isEmpty {
            onLibraryMutated?(.ingest, created.count, targetFolderID, targetBoardID)
        }

        let serializedAssets: [[String: Any]] = created.map { asset in
            var dict: [String: Any] = [
                "id": asset.id.uuidString,
                "title": asset.title,
                "mediaKind": asset.mediaKind.rawValue
            ]
            if let sourceURL = asset.sourceURL { dict["sourceURL"] = sourceURL }
            if let folderID = asset.folderID { dict["folderID"] = folderID.uuidString }
            return dict
        }

        return HTTPResponse.json(
            status: 201,
            extraHeaders: corsHeaders,
            body: [
                "assets": serializedAssets,
                "created": created.count,
                "skipped": skipped
            ]
        )
    }

    private func handleMultipartUpload(request: HTTPRequest, corsHeaders: [String: String]) async throws -> HTTPResponse {
        guard let contentType = request.headers["content-type"],
              let boundary = Self.extractMultipartBoundary(from: contentType) else {
            return HTTPResponse.json(
                status: 400,
                extraHeaders: corsHeaders,
                body: ["error": "上传内容格式不正确。", "code": "INVALID_MULTIPART"]
            )
        }

        let parts = Self.parseMultipartFormData(body: request.body, boundary: boundary)
        var targetFolderID: UUID?
        var targetBoardID: UUID?
        var sourceURL: String?
        var files: [(name: String, data: Data)] = []

        for part in parts {
            if let fileName = part.fileName, !part.data.isEmpty {
                files.append((fileName, part.data))
            } else {
                let textValue = String(decoding: part.data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
                switch part.name {
                case "targetFolderID":
                    if !textValue.isEmpty {
                        guard let parsed = UUID(uuidString: textValue) else {
                            return HTTPResponse.json(status: 400, extraHeaders: corsHeaders, body: ["error": "目标文件夹 ID 格式不正确。", "code": "INVALID_ID"])
                        }
                        targetFolderID = parsed
                    }
                case "targetBoardID":
                    if !textValue.isEmpty {
                        guard let parsed = UUID(uuidString: textValue) else {
                            return HTTPResponse.json(status: 400, extraHeaders: corsHeaders, body: ["error": "目标情绪板 ID 格式不正确。", "code": "INVALID_ID"])
                        }
                        targetBoardID = parsed
                    }
                case "sourceURL": sourceURL = textValue.isEmpty ? nil : textValue
                default: break
                }
            }
        }

        guard !files.isEmpty else {
            return HTTPResponse.json(
                status: 400,
                extraHeaders: corsHeaders,
                body: ["error": "未检测到上传文件。", "code": "NO_FILES"]
            )
        }

        let inputs = files.map { CaptureInput.imageData($0.data, suggestedName: $0.name, sourceURL: sourceURL) }
        let created = try await engine.ingest(inputs, targetFolderID: targetFolderID, targetBoardID: targetBoardID)
        if !created.isEmpty {
            onLibraryMutated?(.ingest, created.count, targetFolderID, targetBoardID)
        }
        let serializedAssets: [[String: Any]] = created.map { asset in
            [
                "id": asset.id.uuidString,
                "title": asset.title,
                "mediaKind": asset.mediaKind.rawValue
            ]
        }
        return HTTPResponse.json(status: 201, extraHeaders: corsHeaders, body: ["assets": serializedAssets])
    }

    // MARK: - Helpers

    private func fetchExistingSourceKeys() async throws -> (sources: Set<String>, keys: Set<String>) {
        let assets = try await engine.fetchAssets(matching: FilterCriteria())
        var sources = Set<String>()
        var keys = Set<String>()
        for asset in assets {
            if let src = asset.sourceURL?.trimmingCharacters(in: .whitespacesAndNewlines), !src.isEmpty {
                sources.insert(src)
                if let key = SocialPostResolver.canonicalDedupKey(for: src) {
                    keys.insert(key)
                }
            }
            if let orig = asset.richMetadata?.socialPost?.originalURL.trimmingCharacters(in: .whitespacesAndNewlines),
               !orig.isEmpty {
                sources.insert(orig)
                if let key = SocialPostResolver.canonicalDedupKey(for: orig) {
                    keys.insert(key)
                }
            }
        }
        return (sources, keys)
    }

    private func validateBearerToken(header: String?) -> Bool {
        guard !token.isEmpty, let header else { return false }
        let trimmed = header.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.lowercased().hasPrefix("bearer ") else { return false }
        let supplied = String(trimmed.dropFirst(7)).trimmingCharacters(in: .whitespacesAndNewlines)
        return Self.constantTimeEquals(supplied, token)
    }

    private static func constantTimeEquals(_ a: String, _ b: String) -> Bool {
        let lhs = Array(a.utf8)
        let rhs = Array(b.utf8)
        guard lhs.count == rhs.count, !lhs.isEmpty else { return false }
        var diff: UInt8 = 0
        for i in 0..<lhs.count {
            diff |= lhs[i] ^ rhs[i]
        }
        return diff == 0
    }

    private static func hasLineBreakOrControl(_ s: String) -> Bool {
        s.unicodeScalars.contains { scalar in
            scalar.value < 0x20 || scalar.value == 0x7F
        }
    }

    private static func isBrowserExtensionOrigin(_ origin: String?) -> Bool {
        guard let raw = origin?.trimmingCharacters(in: .whitespacesAndNewlines),
              !raw.isEmpty,
              !hasLineBreakOrControl(raw),
              let url = URL(string: raw),
              let scheme = url.scheme?.lowercased(),
              ["chrome-extension", "safari-web-extension", "moz-extension"].contains(scheme),
              let host = url.host(), !host.isEmpty,
              url.user() == nil, url.password() == nil,
              url.path.isEmpty || url.path == "/",
              url.query() == nil, url.fragment() == nil else {
            return false
        }
        return true
    }

    private static func isLoopbackWebOrigin(_ origin: String?) -> Bool {
        guard let raw = origin?.trimmingCharacters(in: .whitespacesAndNewlines),
              !raw.isEmpty,
              !hasLineBreakOrControl(raw),
              let url = URL(string: raw),
              let scheme = url.scheme?.lowercased(), scheme == "http",
              let host = url.host()?.lowercased(),
              host == "localhost" || host == "127.0.0.1",
              url.user() == nil, url.password() == nil,
              url.path.isEmpty || url.path == "/",
              url.query() == nil, url.fragment() == nil else {
            return false
        }
        return true
    }

    private func handleLocalAutoPair(request: HTTPRequest, corsHeaders: [String: String]) -> HTTPResponse {
        guard allowLocalAutoPair else {
            return HTTPResponse.json(
                status: 403,
                extraHeaders: corsHeaders,
                body: [
                    "error": "已在 Charkle 设置中关闭同机自动配对，请开启或手动粘贴访问令牌。",
                    "code": "AUTO_PAIR_DISABLED"
                ]
            )
        }

        let origin = request.headers["origin"]
        guard Self.isBrowserExtensionOrigin(origin) else {
            // Never echo CORS allow-origin for rejected non-extension origins.
            var strictHeaders = corsHeaders
            strictHeaders.removeValue(forKey: "Access-Control-Allow-Origin")
            return HTTPResponse.json(
                status: 403,
                extraHeaders: strictHeaders,
                body: [
                    "error": "仅允许本机已安装的浏览器扩展自动配对。",
                    "code": "INVALID_ORIGIN"
                ]
            )
        }

        let extMarker = (request.headers["x-charkle-extension"] ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard extMarker == "1" else {
            return HTTPResponse.json(
                status: 403,
                extraHeaders: corsHeaders,
                body: [
                    "error": "缺少扩展握手标识头。",
                    "code": "MISSING_EXTENSION_HEADER"
                ]
            )
        }

        return HTTPResponse.json(
            status: 200,
            extraHeaders: corsHeaders,
            body: [
                "ok": true,
                "app": "charkle-macos",
                "name": "Charkle macOS",
                "port": Int(boundPort),
                "serverUrl": "http://127.0.0.1:\(boundPort)",
                "token": token
            ]
        )
    }

    private func buildCORSHeaders(for origin: String?) -> [String: String] {
        var headers: [String: String] = [
            "Access-Control-Allow-Methods": "GET, POST, OPTIONS",
            "Access-Control-Allow-Headers": "Authorization, Content-Type, Accept, X-Charkle-Extension",
            "Access-Control-Allow-Private-Network": "true",
            "Access-Control-Max-Age": "600",
            "Vary": "Origin"
        ]
        if let origin = origin?.trimmingCharacters(in: .whitespacesAndNewlines),
           !origin.isEmpty,
           !Self.hasLineBreakOrControl(origin),
           Self.isBrowserExtensionOrigin(origin) || Self.isLoopbackWebOrigin(origin) {
            headers["Access-Control-Allow-Origin"] = origin
        }
        return headers
    }

    private static func decodeBase64Payload(_ raw: String) -> Data? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if let comma = trimmed.firstIndex(of: ","), trimmed.lowercased().hasPrefix("data:") {
            let payload = String(trimmed[trimmed.index(after: comma)...])
            return Data(base64Encoded: payload, options: .ignoreUnknownCharacters)
        }
        return Data(base64Encoded: trimmed, options: .ignoreUnknownCharacters)
    }

    private static func parseSocialBookmarkPayload(_ item: [String: Any]) -> (SocialPostMetadata, Data?, [String])? {
        guard let rawURL = (item["originalURL"] as? String ?? item["url"] as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines),
              let url = URL(string: rawURL),
              WebBookmark.isWebURL(url) else {
            return nil
        }

        let rawPlatform = (item["platform"] as? String ?? "").lowercased()
        let platform: SocialPlatform = {
            if let parsed = SocialPlatform(rawValue: rawPlatform) { return parsed }
            if let ref = SocialPostURLParser.parse(url) { return ref.platform }
            return .x
        }()

        let authorName = ((item["authorName"] as? String) ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let authorHandle = ((item["authorHandle"] as? String) ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let effectiveName = authorName.isEmpty ? (authorHandle.isEmpty ? platform.displayName : authorHandle) : authorName
        let effectiveHandle = authorHandle.isEmpty ? effectiveName : authorHandle

        let articleTitle = (item["articleTitle"] as? String ?? item["title"] as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let bodyText = (item["bodyText"] as? String ?? item["notes"] as? String ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)

        func validatedWebURLString(_ raw: String?) -> String? {
            guard let trimmed = raw?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !trimmed.isEmpty,
                  let parsed = URL(string: trimmed),
                  WebBookmark.isWebURL(parsed) else {
                return nil
            }
            return parsed.absoluteString
        }

        var attachments: [SocialMediaAttachment] = []
        if let rawAttachments = item["attachments"] as? [[String: Any]] {
            for att in rawAttachments {
                guard let u = validatedWebURLString(att["url"] as? String) else {
                    continue
                }
                let kindStr = (att["kind"] as? String ?? "photo").lowercased()
                let kind: SocialMediaAttachment.Kind = switch kindStr {
                case "video": .video
                case "gif": .gif
                default: .photo
                }
                let thumb = validatedWebURLString(att["thumbnailURL"] as? String)
                attachments.append(SocialMediaAttachment(kind: kind, url: u, thumbnailURL: thumb))
            }
        }

        let mediaURLs = (item["mediaURLs"] as? [String] ?? []).compactMap(validatedWebURLString)
        let mediaThumbs = (item["mediaThumbnailURLs"] as? [String] ?? []).compactMap(validatedWebURLString)

        if attachments.isEmpty && !mediaURLs.isEmpty {
            for (idx, u) in mediaURLs.enumerated() {
                let thumb = idx < mediaThumbs.count ? mediaThumbs[idx] : u
                attachments.append(SocialMediaAttachment(kind: .photo, url: u, thumbnailURL: thumb))
            }
        }

        let videoURL = validatedWebURLString(item["videoURL"] as? String)
        let hasVideo = (item["hasVideo"] as? Bool) ?? (videoURL != nil)
        let avatarURL = validatedWebURLString(item["authorAvatarURL"] as? String)
        let publishedAt = (item["publishedAtText"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
        let quotedAuthor = (item["quotedAuthor"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
        let quotedText = (item["quotedText"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)

        let meta = SocialPostMetadata(
            platform: platform,
            authorName: effectiveName,
            authorHandle: effectiveHandle,
            authorAvatarURL: (avatarURL?.isEmpty == false) ? avatarURL : nil,
            publishedAtText: (publishedAt?.isEmpty == false) ? publishedAt : nil,
            bodyText: bodyText.isEmpty ? (articleTitle ?? rawURL) : bodyText,
            quotedAuthor: (quotedAuthor?.isEmpty == false) ? quotedAuthor : nil,
            quotedText: (quotedText?.isEmpty == false) ? quotedText : nil,
            articleTitle: (articleTitle?.isEmpty == false) ? articleTitle : nil,
            mediaURLs: attachments.isEmpty ? mediaURLs : attachments.map(\.url),
            mediaThumbnailURLs: attachments.isEmpty ? mediaThumbs : attachments.compactMap { $0.thumbnailURL ?? $0.url },
            attachments: attachments,
            hasVideo: hasVideo,
            videoURL: (videoURL?.isEmpty == false) ? videoURL : nil,
            replyCount: intValue(item["replyCount"]),
            repostCount: intValue(item["repostCount"]),
            likeCount: intValue(item["likeCount"]),
            viewCount: intValue(item["viewCount"]),
            originalURL: rawURL,
            mediaFetchFailed: false
        )

        let coverData = (item["coverDataUrl"] as? String).flatMap(Self.decodeBase64Payload)
        let tags = (item["tags"] as? [String] ?? []).map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
        return (meta, coverData, tags)
    }

    private static func intValue(_ raw: Any?) -> Int? {
        if let i = raw as? Int { return i }
        if let n = raw as? NSNumber { return n.intValue }
        if let s = raw as? String { return XiaohongshuPostResolver.parseChineseMetricCount(s) }
        return nil
    }

    // MARK: - Minimal Multipart Form-Data Parser

    private struct MultipartPart {
        let name: String
        let fileName: String?
        let data: Data
    }

    private static func extractMultipartBoundary(from contentType: String) -> String? {
        for segment in contentType.split(separator: ";") {
            let trimmed = segment.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.lowercased().hasPrefix("boundary=") {
                var value = String(trimmed.dropFirst(9)).trimmingCharacters(in: .whitespacesAndNewlines)
                if value.hasPrefix("\"") && value.hasSuffix("\"") && value.count >= 2 {
                    value = String(value.dropFirst().dropLast())
                }
                return value.isEmpty ? nil : value
            }
        }
        return nil
    }

    private static func parseMultipartFormData(body: Data, boundary: String) -> [MultipartPart] {
        let delimiter = Data("--\(boundary)".utf8)
        let headerSep = Data("\r\n\r\n".utf8)
        var parts: [MultipartPart] = []

        var searchRange = body.startIndex..<body.endIndex
        guard let firstBoundary = body.range(of: delimiter, in: searchRange) else { return [] }
        var cursor = firstBoundary.upperBound

        while cursor < body.endIndex {
            // Check closing `--`
            if body.distance(from: cursor, to: body.endIndex) >= 2 {
                let nextTwo = body[cursor..<body.index(cursor, offsetBy: 2)]
                if nextTwo == Data("--".utf8) { break }
            }
            // Skip CRLF after boundary
            if body.distance(from: cursor, to: body.endIndex) >= 2,
               body[cursor..<body.index(cursor, offsetBy: 2)] == Data("\r\n".utf8) {
                cursor = body.index(cursor, offsetBy: 2)
            }
            searchRange = cursor..<body.endIndex
            guard let nextBoundary = body.range(of: delimiter, in: searchRange) else { break }
            let chunkEnd = nextBoundary.lowerBound
            let chunk = body[cursor..<chunkEnd]
            cursor = nextBoundary.upperBound

            guard let sep = chunk.range(of: headerSep) else { continue }
            let headerText = String(decoding: chunk[chunk.startIndex..<sep.lowerBound], as: UTF8.self)
            var payload = Data(chunk[sep.upperBound..<chunk.endIndex])
            if payload.count >= 2 && payload.suffix(2) == Data("\r\n".utf8) {
                payload.removeLast(2)
            }

            var partName = ""
            var fileName: String?
            for line in headerText.components(separatedBy: "\r\n") {
                if line.lowercased().hasPrefix("content-disposition:") {
                    if let nameMatch = extractQuotedParam("name", in: line) {
                        partName = nameMatch
                    }
                    fileName = extractQuotedParam("filename", in: line)
                }
            }
            if !partName.isEmpty {
                parts.append(MultipartPart(name: partName, fileName: fileName, data: payload))
            }
        }
        return parts
    }

    private static func extractQuotedParam(_ key: String, in headerLine: String) -> String? {
        let needle = "\(key)=\""
        var searchStart = headerLine.startIndex
        while let match = headerLine.range(of: needle, options: .caseInsensitive, range: searchStart..<headerLine.endIndex) {
            let atBoundary: Bool
            if match.lowerBound == headerLine.startIndex {
                atBoundary = true
            } else {
                let prev = headerLine[headerLine.index(before: match.lowerBound)]
                atBoundary = prev == ";" || prev.isWhitespace
            }
            if atBoundary {
                let rest = headerLine[match.upperBound...]
                guard let end = rest.firstIndex(of: "\"") else { return nil }
                return String(rest[..<end])
            }
            searchStart = match.upperBound
        }
        return nil
    }
}

// MARK: - HTTP Wire Primitives

private nonisolated struct HTTPRequest: Sendable {
    let method: String
    let rawTarget: String
    let headers: [String: String]
    let body: Data

    var pathWithoutQuery: String {
        if let q = rawTarget.firstIndex(of: "?") {
            return String(rawTarget[..<q])
        }
        return rawTarget
    }
}

private nonisolated struct HTTPResponse: Sendable {
    let status: Int
    let headers: [String: String]
    let body: Data

    static func json(status: Int, extraHeaders: [String: String] = [:], body: [String: Any]) -> HTTPResponse {
        let data = (try? JSONSerialization.data(withJSONObject: body, options: [])) ?? Data("{}".utf8)
        var headers = extraHeaders
        headers["Content-Type"] = "application/json; charset=utf-8"
        return HTTPResponse(status: status, headers: headers, body: data)
    }

    func serialize() -> Data {
        let reason: String = switch status {
        case 200: "OK"
        case 201: "Created"
        case 204: "No Content"
        case 400: "Bad Request"
        case 401: "Unauthorized"
        case 403: "Forbidden"
        case 404: "Not Found"
        case 411: "Length Required"
        case 413: "Payload Too Large"
        case 501: "Not Implemented"
        case 503: "Service Unavailable"
        default: "Internal Server Error"
        }
        var lines = ["HTTP/1.1 \(status) \(reason)"]
        lines.append("Content-Length: \(body.count)")
        lines.append("Connection: close")
        for (k, v) in headers {
            let cleanK = k.filter { $0 != "\r" && $0 != "\n" }
            let cleanV = v.filter { $0 != "\r" && $0 != "\n" }
            if !cleanK.isEmpty {
                lines.append("\(cleanK): \(cleanV)")
            }
        }
        lines.append("")
        lines.append("")
        var out = Data(lines.joined(separator: "\r\n").utf8)
        out.append(body)
        return out
    }
}

private nonisolated final class HTTPConnectionSession: @unchecked Sendable {
    private static let idleTimeoutSeconds: TimeInterval = 15.0

    private let connection: NWConnection
    private let queue: DispatchQueue
    private let maxBodyBytes: Int
    private let onFinish: @Sendable () -> Void
    private let handler: @Sendable (HTTPRequest) async -> HTTPResponse

    private var buffer = Data()
    private var parsedHeaderEnd: Int?
    private var expectedBodyLength: Int = 0
    private var isChunked = false
    private var method: String = ""
    private var rawTarget: String = ""
    private var headers: [String: String] = [:]
    private var completed = false
    private var timeoutWorkItem: DispatchWorkItem?

    init(
        connection: NWConnection,
        queue: DispatchQueue,
        maxBodyBytes: Int,
        onFinish: @escaping @Sendable () -> Void,
        handler: @escaping @Sendable (HTTPRequest) async -> HTTPResponse
    ) {
        self.connection = connection
        self.queue = queue
        self.maxBodyBytes = maxBodyBytes
        self.onFinish = onFinish
        self.handler = handler
    }

    func start() {
        connection.start(queue: queue)
        queue.async { [self] in
            resetReadTimeout()
            receiveNextChunk()
        }
    }

    func cancel() {
        queue.async { [self] in
            guard !completed else { return }
            completed = true
            cancelReadTimeout()
            buffer.removeAll(keepingCapacity: false)
            connection.cancel()
            onFinish()
        }
    }

    private func resetReadTimeout() {
        cancelReadTimeout()
        let work = DispatchWorkItem { [weak self] in
            guard let self, !self.completed else { return }
            self.completed = true
            self.buffer.removeAll(keepingCapacity: false)
            self.connection.cancel()
            self.onFinish()
        }
        timeoutWorkItem = work
        queue.asyncAfter(deadline: .now() + Self.idleTimeoutSeconds, execute: work)
    }

    private func cancelReadTimeout() {
        timeoutWorkItem?.cancel()
        timeoutWorkItem = nil
    }

    private enum ChunkDecodeStatus {
        case incomplete
        case malformed
        case payloadTooLarge
        case complete(Data)
    }

    private func decodeChunkedBody(from slice: Data) -> ChunkDecodeStatus {
        let crlf = Data("\r\n".utf8)
        var cursor = slice.startIndex
        var decoded = Data()

        while true {
            guard let sizeLineEnd = slice.range(of: crlf, in: cursor..<slice.endIndex) else {
                return .incomplete
            }
            let sizeLine = String(decoding: slice[cursor..<sizeLineEnd.lowerBound], as: UTF8.self)
            let sizeToken = sizeLine.split(separator: ";", maxSplits: 1).first?
                .trimmingCharacters(in: .whitespaces) ?? ""
            guard !sizeToken.isEmpty, let chunkSize = Int(sizeToken, radix: 16), chunkSize >= 0 else {
                return .malformed
            }
            cursor = sizeLineEnd.upperBound
            if chunkSize == 0 {
                // Consume final CRLF (or optional trailing headers ending with CRLFCRLF)
                if slice.distance(from: cursor, to: slice.endIndex) >= 2,
                   slice[cursor..<slice.index(cursor, offsetBy: 2)] == crlf {
                    return .complete(decoded)
                }
                let trailerEnd = Data("\r\n\r\n".utf8)
                if slice.range(of: trailerEnd, in: cursor..<slice.endIndex) != nil {
                    return .complete(decoded)
                }
                return .incomplete
            }
            if decoded.count + chunkSize > maxBodyBytes {
                return .payloadTooLarge
            }
            let needed = chunkSize + 2
            guard slice.distance(from: cursor, to: slice.endIndex) >= needed else {
                return .incomplete
            }
            let dataEnd = slice.index(cursor, offsetBy: chunkSize)
            let crlfEnd = slice.index(dataEnd, offsetBy: 2)
            guard slice[dataEnd..<crlfEnd] == crlf else {
                return .malformed
            }
            decoded.append(slice[cursor..<dataEnd])
            cursor = crlfEnd
        }
    }

    private func receiveNextChunk() {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65_536) { [self] data, _, isComplete, error in
            if completed { return }
            if let data, !data.isEmpty {
                buffer.append(data)
                resetReadTimeout()
            }

            if parsedHeaderEnd == nil {
                let sep = Data("\r\n\r\n".utf8)
                if let range = buffer.range(of: sep) {
                    let headerData = buffer[buffer.startIndex..<range.lowerBound]
                    let headerStr = String(decoding: headerData, as: UTF8.self)
                    let lines = headerStr.components(separatedBy: "\r\n")
                    guard let requestLine = lines.first else {
                        finishWithResponse(HTTPResponse.json(status: 400, body: ["error": "无效请求。"]))
                        return
                    }
                    let parts = requestLine.split(separator: " ", omittingEmptySubsequences: true)
                    guard parts.count >= 2 else {
                        finishWithResponse(HTTPResponse.json(status: 400, body: ["error": "无效请求行。"]))
                        return
                    }
                    method = String(parts[0]).uppercased()
                    rawTarget = String(parts[1])
                    for line in lines.dropFirst() {
                        if line.contains("\r") || line.contains("\n") {
                            finishWithResponse(HTTPResponse.json(status: 400, body: ["error": "请求头格式无效。"]))
                            return
                        }
                        if let colon = line.firstIndex(of: ":") {
                            let k = line[..<colon].trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
                            let v = line[line.index(after: colon)...].trimmingCharacters(in: .whitespacesAndNewlines)
                            if !k.isEmpty { headers[k] = v }
                        }
                    }
                    if let te = headers["transfer-encoding"]?.lowercased(), !te.isEmpty {
                        if te.contains("chunked") {
                            isChunked = true
                            expectedBodyLength = 0
                        } else {
                            finishWithResponse(HTTPResponse.json(status: 501, body: ["error": "不支持的传输编码。"]))
                            return
                        }
                    } else if let rawCL = headers["content-length"] {
                        guard let parsedCL = Int(rawCL), parsedCL >= 0 else {
                            finishWithResponse(HTTPResponse.json(status: 400, body: ["error": "无效的 Content-Length。"]))
                            return
                        }
                        if parsedCL > maxBodyBytes {
                            finishWithResponse(HTTPResponse.json(status: 413, body: ["error": "请求体积超出上限。"]))
                            return
                        }
                        expectedBodyLength = parsedCL
                    } else {
                        expectedBodyLength = 0
                    }
                    parsedHeaderEnd = range.upperBound
                } else if buffer.count > 65_536 {
                    finishWithResponse(HTTPResponse.json(status: 400, body: ["error": "请求头过长。"]))
                    return
                }
            }

            if let headerEnd = parsedHeaderEnd {
                if isChunked {
                    let rawSlice = buffer[headerEnd..<buffer.endIndex]
                    if rawSlice.count > maxBodyBytes + 1_048_576 {
                        finishWithResponse(HTTPResponse.json(status: 413, body: ["error": "请求体积超出上限。"]))
                        return
                    }
                    switch decodeChunkedBody(from: rawSlice) {
                    case .complete(let bodyData):
                        dispatchRequest(body: bodyData)
                        return
                    case .payloadTooLarge:
                        finishWithResponse(HTTPResponse.json(status: 413, body: ["error": "请求体积超出上限。"]))
                        return
                    case .malformed:
                        finishWithResponse(HTTPResponse.json(status: 400, body: ["error": "分块传输格式无效。"]))
                        return
                    case .incomplete:
                        break
                    }
                } else {
                    let currentBodyLen = buffer.count - headerEnd
                    if currentBodyLen >= expectedBodyLength {
                        let bodySlice = buffer[headerEnd..<min(buffer.count, headerEnd + expectedBodyLength)]
                        dispatchRequest(body: Data(bodySlice))
                        return
                    }
                }
            }

            if isComplete || error != nil {
                completed = true
                cancelReadTimeout()
                buffer.removeAll(keepingCapacity: false)
                connection.cancel()
                onFinish()
                return
            }

            receiveNextChunk()
        }
    }

    private func dispatchRequest(body: Data) {
        let req = HTTPRequest(
            method: method,
            rawTarget: rawTarget,
            headers: headers,
            body: body
        )
        completed = true
        cancelReadTimeout()
        buffer.removeAll(keepingCapacity: false)
        Task { [self] in
            let response = await self.handler(req)
            self.send(response)
        }
    }

    private func finishWithResponse(_ response: HTTPResponse) {
        completed = true
        cancelReadTimeout()
        buffer.removeAll(keepingCapacity: false)
        send(response)
    }

    private func send(_ response: HTTPResponse) {
        let payload = response.serialize()
        connection.send(content: payload, completion: .contentProcessed { [connection, onFinish] _ in
            connection.cancel()
            onFinish()
        })
    }
}
