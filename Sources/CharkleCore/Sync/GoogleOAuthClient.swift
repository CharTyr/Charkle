import CryptoKit
import Foundation
import Network
import Synchronization

/// Parsed Google Desktop OAuth client credentials from Google Cloud Console's `client_secret_*.json`.
public nonisolated struct GoogleOAuthClientConfig: Codable, Equatable, Sendable {
    public let clientID: String
    public let clientSecret: String
    public let authURI: String
    public let tokenURI: String

    public init(
        clientID: String,
        clientSecret: String = "",
        authURI: String = "https://accounts.google.com/o/oauth2/v2/auth",
        tokenURI: String = "https://oauth2.googleapis.com/token"
    ) {
        self.clientID = clientID
        self.clientSecret = clientSecret
        self.authURI = authURI
        self.tokenURI = tokenURI
    }

    /// Parse standard Google Cloud Console `client_secret_*.json` (`installed` or `web` root key).
    public static func parseClientSecretJSON(_ data: Data) throws -> GoogleOAuthClientConfig {
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw DriveTransportError.invalidResponse("JSON 格式无效")
        }
        let body = (root["installed"] as? [String: Any])
            ?? (root["web"] as? [String: Any])
            ?? root

        guard let clientID = body["client_id"] as? String, !clientID.isEmpty else {
            throw DriveTransportError.invalidResponse("未在 client_secret JSON 中找到 client_id")
        }
        let clientSecret = (body["client_secret"] as? String) ?? ""
        let authURI = (body["auth_uri"] as? String) ?? "https://accounts.google.com/o/oauth2/v2/auth"
        let tokenURI = (body["token_uri"] as? String) ?? "https://oauth2.googleapis.com/token"
        guard URLComponents(string: authURI)?.host == "accounts.google.com",
              URLComponents(string: tokenURI)?.host == "oauth2.googleapis.com",
              authURI.hasPrefix("https://"), tokenURI.hasPrefix("https://") else {
            throw DriveTransportError.invalidResponse("Expected Google Desktop OAuth endpoints.")
        }
        return GoogleOAuthClientConfig(
            clientID: clientID,
            clientSecret: clientSecret,
            authURI: authURI,
            tokenURI: tokenURI
        )
    }

    /// Resolves an app-bundled Google Desktop OAuth client for zero-configuration end-user sign-in:
    /// 1) `GoogleOAuthClient.json` in `Bundle.main` resources (embedded during release builds), or
    /// 2) `CharkleGoogleOAuthClientID` (+ optional `CharkleGoogleOAuthClientSecret`) in `Info.plist`.
    public static func bundledConfig() -> GoogleOAuthClientConfig? {
        if let url = Bundle.main.url(forResource: "GoogleOAuthClient", withExtension: "json"),
           let data = try? Data(contentsOf: url),
           let parsed = try? parseClientSecretJSON(data) {
            return parsed
        }
        if let clientID = Bundle.main.object(forInfoDictionaryKey: "CharkleGoogleOAuthClientID") as? String {
            let trimmedID = clientID.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmedID.isEmpty {
                let secret = (Bundle.main.object(forInfoDictionaryKey: "CharkleGoogleOAuthClientSecret") as? String ?? "")
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                return GoogleOAuthClientConfig(clientID: trimmedID, clientSecret: secret)
            }
        }
        return nil
    }
}

public nonisolated struct GoogleOAuthToken: Codable, Sendable {
    public let accessToken: String
    public let refreshToken: String?
    public let expiresAt: Date

    public var isExpiredOrExpiringSoon: Bool {
        Date().addingTimeInterval(90) >= expiresAt
    }

    public init(accessToken: String, refreshToken: String?, expiresAt: Date) {
        self.accessToken = accessToken
        self.refreshToken = refreshToken
        self.expiresAt = expiresAt
    }
}

/// RFC 8252 native desktop Google OAuth 2.0 client using PKCE (`S256`) and an ephemeral
/// localhost loopback server (`http://127.0.0.1:<port>/oauth2callback`).
public actor GoogleOAuthClient {
    private let keychain: KeychainStore
    private let session: URLSession
    private var cachedConfig: GoogleOAuthClientConfig?
    private var hasLoadedConfig = false
    private var cachedToken: GoogleOAuthToken?
    private var hasLoadedToken = false
    private var inFlightRefresh: Task<GoogleOAuthToken, Error>?
    private var sessionGeneration: UInt64 = 0

    public init(keychain: KeychainStore = KeychainStore(), session: URLSession = .shared) {
        self.keychain = keychain
        self.session = session
    }

    public func importClientSecret(from url: URL) throws {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        let config = try GoogleOAuthClientConfig.parseClientSecretJSON(Data(contentsOf: url))
        try saveClientConfig(config)
    }

    public func saveClientConfig(_ config: GoogleOAuthClientConfig) throws {
        let trimmedID = config.clientID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedID.isEmpty else {
            throw DriveTransportError.notConfigured("请输入有效的 Google OAuth Client ID。")
        }
        let normalized = GoogleOAuthClientConfig(
            clientID: trimmedID,
            clientSecret: config.clientSecret.trimmingCharacters(in: .whitespacesAndNewlines),
            authURI: config.authURI,
            tokenURI: config.tokenURI
        )
        if try storedConfig()?.clientID != normalized.clientID {
            sessionGeneration &+= 1
            inFlightRefresh?.cancel()
            inFlightRefresh = nil
            try keychain.delete("drive.oauth.token")
            cachedToken = nil
            hasLoadedToken = true
        }
        try keychain.save(JSONEncoder().encode(normalized), for: "drive.oauth.config")
        cachedConfig = normalized
        hasLoadedConfig = true
    }

    public func storedConfig() throws -> GoogleOAuthClientConfig? {
        if hasLoadedConfig { return cachedConfig }
        let loaded = try keychain.read("drive.oauth.config").map {
            try JSONDecoder().decode(GoogleOAuthClientConfig.self, from: $0)
        }
        cachedConfig = loaded
        hasLoadedConfig = true
        return loaded
    }

    /// Resolves OAuth client credentials in priority order:
    /// 1) Explicitly saved Keychain config, 2) App-bundled production OAuth client.
    public func resolvedConfig() throws -> GoogleOAuthClientConfig? {
        if let saved = try storedConfig(), !saved.clientID.isEmpty {
            return saved
        }
        return GoogleOAuthClientConfig.bundledConfig()
    }

    public func hasResolvedConfig() -> Bool {
        if hasLoadedConfig, let cachedConfig, !cachedConfig.clientID.isEmpty {
            return true
        }
        if keychain.exists("drive.oauth.config") {
            return true
        }
        return GoogleOAuthClientConfig.bundledConfig() != nil
    }

    /// Lightweight metadata-only presence check that avoids unlocking secret payload data.
    public func hasStoredToken() -> Bool {
        if hasLoadedToken {
            return cachedToken != nil
        }
        return keychain.exists("drive.oauth.token")
    }

    public func currentStoredToken() throws -> GoogleOAuthToken? {
        if hasLoadedToken { return cachedToken }
        let loaded = try keychain.read("drive.oauth.token").map {
            try JSONDecoder().decode(GoogleOAuthToken.self, from: $0)
        }
        cachedToken = loaded
        hasLoadedToken = true
        return loaded
    }

    public func saveToken(_ token: GoogleOAuthToken) throws {
        try keychain.save(JSONEncoder().encode(token), for: "drive.oauth.token")
        cachedToken = token
        hasLoadedToken = true
    }

    public func signOut() throws {
        sessionGeneration &+= 1
        inFlightRefresh?.cancel()
        inFlightRefresh = nil
        try keychain.delete("drive.oauth.token")
        cachedToken = nil
        hasLoadedToken = true
    }

    public func accessToken() async throws -> String {
        guard let config = try resolvedConfig() else {
            throw DriveTransportError.notConfigured("请先在设置中完成 Google 登录配置。")
        }
        return try await validAccessToken(config: config)
    }

    /// Return a valid access token, automatically refreshing via `refresh_token` if needed
    /// (with in-flight deduplication so parallel sync workers share a single refresh call).
    public func validAccessToken(config: GoogleOAuthClientConfig) async throws -> String {
        if let existing = inFlightRefresh {
            let waitGeneration = sessionGeneration
            let token = try await existing.value
            guard sessionGeneration == waitGeneration else {
                throw DriveTransportError.authenticationRequired("Google 登录状态已变更，请重新登录。")
            }
            return token.accessToken
        }
        guard let token = try currentStoredToken() else {
            throw DriveTransportError.authenticationRequired("尚未完成 Google Drive OAuth 登录")
        }
        if !token.isExpiredOrExpiringSoon {
            return token.accessToken
        }
        guard let refreshToken = token.refreshToken, !refreshToken.isEmpty else {
            throw DriveTransportError.authenticationRequired("访问令牌已过期且无 Refresh Token，请重新登录")
        }
        let generation = sessionGeneration
        let refreshTask = Task {
            try await self.refreshAccessToken(refreshToken: refreshToken, config: config)
        }
        inFlightRefresh = refreshTask
        defer {
            if self.sessionGeneration == generation {
                self.inFlightRefresh = nil
            }
        }
        do {
            let refreshed = try await refreshTask.value
            guard self.sessionGeneration == generation else {
                throw DriveTransportError.authenticationRequired("Google 登录状态已变更，请重新登录。")
            }
            try saveToken(refreshed)
            return refreshed.accessToken
        } catch let authError as DriveTransportError {
            if case .authenticationRequired = authError, self.sessionGeneration == generation {
                try? keychain.delete("drive.oauth.token")
                cachedToken = nil
                hasLoadedToken = true
            }
            throw authError
        }
    }

    /// Run full interactive PKCE OAuth 2.0 flow: starts local loopback callback listener,
    /// invokes `openBrowser` with the Google consent URL, exchanges authorization code for tokens.
    public func authorizeInteractive(
        config: GoogleOAuthClientConfig,
        fullDriveScope: Bool = true,
        openBrowser: @Sendable (URL) async -> Void
    ) async throws -> GoogleOAuthToken {
        guard !config.clientID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw DriveTransportError.notConfigured("请先填写 Google OAuth Client ID 或导入 client_secret.json")
        }

        let codeVerifier = Self.generateCodeVerifier()
        let codeChallenge = Self.codeChallengeS256(for: codeVerifier)
        let state = UUID().uuidString.replacingOccurrences(of: "-", with: "")

        let loopback = LoopbackOAuthServer(expectedState: state)
        let port = try await loopback.start()
        let redirectURI = "http://127.0.0.1:\(port)/oauth2callback"

        let scope = fullDriveScope
            ? "https://www.googleapis.com/auth/drive"
            : "https://www.googleapis.com/auth/drive.file"

        guard var components = URLComponents(string: config.authURI),
              components.scheme == "https", components.host == "accounts.google.com",
              components.user == nil, components.password == nil else {
            await loopback.stop()
            throw DriveTransportError.invalidResponse("Invalid Google authorization endpoint.")
        }
        components.queryItems = [
            URLQueryItem(name: "client_id", value: config.clientID),
            URLQueryItem(name: "redirect_uri", value: redirectURI),
            URLQueryItem(name: "response_type", value: "code"),
            URLQueryItem(name: "scope", value: scope),
            URLQueryItem(name: "code_challenge", value: codeChallenge),
            URLQueryItem(name: "code_challenge_method", value: "S256"),
            URLQueryItem(name: "access_type", value: "offline"),
            URLQueryItem(name: "prompt", value: "consent"),
            URLQueryItem(name: "state", value: state)
        ]

        guard let authURL = components.url else {
            await loopback.stop()
            throw DriveTransportError.invalidResponse("无法构建 OAuth 授权链接")
        }

        await openBrowser(authURL)

        let callback: (code: String, state: String?)
        do {
            callback = try await loopback.waitForCode(timeoutSeconds: 180)
        } catch {
            await loopback.stop()
            throw error
        }
        await loopback.stop()

        if callback.state != state {
            throw DriveTransportError.authenticationRequired("OAuth State 校验不匹配，请重试")
        }

        let token = try await exchangeAuthorizationCode(
            code: callback.code,
            codeVerifier: codeVerifier,
            redirectURI: redirectURI,
            config: config
        )
        sessionGeneration &+= 1
        inFlightRefresh?.cancel()
        inFlightRefresh = nil
        try saveToken(token)
        return token
    }

    private func exchangeAuthorizationCode(
        code: String,
        codeVerifier: String,
        redirectURI: String,
        config: GoogleOAuthClientConfig
    ) async throws -> GoogleOAuthToken {
        var params: [(String, String)] = [
            ("client_id", config.clientID),
            ("code", code),
            ("code_verifier", codeVerifier),
            ("grant_type", "authorization_code"),
            ("redirect_uri", redirectURI)
        ]
        if !config.clientSecret.isEmpty {
            params.append(("client_secret", config.clientSecret))
        }
        return try await postTokenRequest(params: params, tokenURI: config.tokenURI, fallbackRefreshToken: nil)
    }

    private func refreshAccessToken(
        refreshToken: String,
        config: GoogleOAuthClientConfig
    ) async throws -> GoogleOAuthToken {
        var params: [(String, String)] = [
            ("client_id", config.clientID),
            ("refresh_token", refreshToken),
            ("grant_type", "refresh_token")
        ]
        if !config.clientSecret.isEmpty {
            params.append(("client_secret", config.clientSecret))
        }
        return try await postTokenRequest(params: params, tokenURI: config.tokenURI, fallbackRefreshToken: refreshToken)
    }

    private func postTokenRequest(
        params: [(String, String)],
        tokenURI: String,
        fallbackRefreshToken: String?
    ) async throws -> GoogleOAuthToken {
        guard let url = URL(string: tokenURI), url.scheme == "https", url.host() == "oauth2.googleapis.com",
              url.user() == nil, url.password() == nil else {
            throw DriveTransportError.invalidResponse("无效的 Token URL: \(tokenURI)")
        }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")

        let formCharacters = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")
        let form = params.map { name, value in
            name + "=" + (value.addingPercentEncoding(withAllowedCharacters: formCharacters) ?? "")
        }.joined(separator: "&")
        request.httpBody = Data(form.utf8)

        let (data, response) = try await session.data(for: request)
        try Task.checkCancellation()
        if let http = response as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
            if let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let errCode = obj["error"] as? String,
               errCode == "invalid_grant" || errCode == "unauthorized_client" {
                throw DriveTransportError.authenticationRequired("Google 账号授权已失效或已撤销，请重新登录。")
            }
            let msg = String(data: data, encoding: .utf8) ?? ""
            throw DriveTransportError.httpError(statusCode: http.statusCode, message: String(msg.prefix(300)))
        }

        struct RawTokenResponse: Decodable {
            let access_token: String
            let refresh_token: String?
            let expires_in: Double?
        }

        let decoded = try JSONDecoder().decode(RawTokenResponse.self, from: data)
        let expiry = Date().addingTimeInterval(decoded.expires_in ?? 3600)
        return GoogleOAuthToken(
            accessToken: decoded.access_token,
            refreshToken: decoded.refresh_token ?? fallbackRefreshToken,
            expiresAt: expiry
        )
    }

    // MARK: - PKCE Utilities

    public static func generateCodeVerifier() -> String {
        Data((0..<48).map { _ in UInt8.random(in: .min ... .max) }).base64URLEncodedString()
    }

    public static func codeChallengeS256(for verifier: String) -> String {
        let digest = SHA256.hash(data: Data(verifier.utf8))
        return Data(digest).base64URLEncodedString()
    }
}

private extension Data {
    func base64URLEncodedString() -> String {
        base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}

/// Minimal localhost HTTP server (`127.0.0.1:<ephemeral>`) to receive Google's OAuth 2.0 callback.
private actor LoopbackOAuthServer {
    private let expectedState: String
    private var listener: NWListener?
    private var continuation: CheckedContinuation<(code: String, state: String?), Error>?
    private var capturedResult: Result<(code: String, state: String?), Error>?

    init(expectedState: String) { self.expectedState = expectedState }

    func start() async throws -> UInt16 {
        let params = NWParameters.tcp
        params.requiredLocalEndpoint = NWEndpoint.hostPort(host: .ipv4(.loopback), port: .any)
        let listener = try NWListener(using: params)
        self.listener = listener

        return try await withCheckedThrowingContinuation { cont in
            let resumed = Mutex(false)

            listener.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    let shouldResume = resumed.withLock { flag -> Bool in
                        guard !flag else { return false }
                        flag = true
                        return true
                    }
                    if shouldResume {
                        if let port = listener.port?.rawValue {
                            cont.resume(returning: port)
                        } else {
                            cont.resume(throwing: DriveTransportError.invalidResponse("无法绑定本机 OAuth 回调端口。"))
                        }
                    }
                case .failed(let error):
                    let shouldResume = resumed.withLock { flag -> Bool in
                        guard !flag else { return false }
                        flag = true
                        return true
                    }
                    if shouldResume {
                        cont.resume(throwing: error)
                    }
                case .cancelled:
                    let shouldResume = resumed.withLock { flag -> Bool in
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

            listener.newConnectionHandler = { [weak self] connection in
                Task { await self?.handle(connection: connection) }
            }
            listener.start(queue: DispatchQueue(label: "com.charkle.oauth.loopback"))
        }
    }

    func waitForCode(timeoutSeconds: TimeInterval) async throws -> (code: String, state: String?) {
        if let existing = capturedResult {
            return try existing.get()
        }
        let timeout = Task {
            do { try await Task.sleep(for: .seconds(timeoutSeconds)) } catch { return }
            finish(with: .failure(DriveTransportError.authenticationRequired("Google 登录已超时，请重试。")))
        }
        defer { timeout.cancel() }
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { cont in
                if let existing = capturedResult { cont.resume(with: existing) }
                else { self.continuation = cont }
            }
        } onCancel: {
            Task { await self.finish(with: .failure(CancellationError())) }
        }
    }

    func stop() {
        listener?.cancel()
        listener = nil
        finish(with: .failure(CancellationError()))
    }

    private func finish(with result: Result<(code: String, state: String?), Error>) {
        guard capturedResult == nil else { return }
        capturedResult = result
        let pending = continuation
        continuation = nil
        pending?.resume(with: result)
    }

    private func handle(connection: NWConnection) {
        let state = expectedState
        connection.start(queue: DispatchQueue(label: "com.charkle.oauth.connection"))
        Self.receiveHTTPHeaders(on: connection, accumulated: Data(), maxBytes: 16_384) { [weak self] data in
            guard let data, let line = String(data: data, encoding: .utf8)?.components(separatedBy: "\r\n").first else {
                connection.cancel()
                return
            }
            let request = line.split(separator: " ")
            let target = request.count >= 2 ? String(request[1]) : "/"
            let url = URLComponents(string: "http://127.0.0.1" + target)
            let result: Result<(code: String, state: String?), Error>?
            if request.first == "GET", url?.path == "/oauth2callback",
               url?.queryItems?.first(where: { $0.name == "state" })?.value == state {
                if let code = url?.queryItems?.first(where: { $0.name == "code" })?.value, !code.isEmpty {
                    result = .success((code, state))
                } else {
                    result = .failure(DriveTransportError.authenticationRequired("已取消 Google 账号授权。"))
                }
            } else {
                result = nil
            }
            if let result { Task { await self?.finish(with: result) } }
            let success = (try? result?.get()) != nil
            let title = success ? "已完成 Google 账号登录" : "未完成授权"
            let bodyText = success
                ? "你可以关闭此标签页，Charkle 将自动开始同步你的素材与情绪板。"
                : "授权未完成或已取消，请返回 Charkle 重试。"
            let accent = success ? "#22C55E" : "#EF4444"
            let icon = success ? "✓" : "!"
            let html = """
            <!doctype html><html lang="zh-CN"><head><meta charset="utf-8"><title>\(title) · Charkle</title>
            <style>
            :root{color-scheme:light dark}
            body{margin:0;min-height:100vh;display:flex;align-items:center;justify-content:center;font-family:-apple-system,BlinkMacSystemFont,"SF Pro Text",sans-serif;background:#F6F6F5;color:#1D1D1F}
            @media(prefers-color-scheme:dark){body{background:#141517;color:#F5F5F7}.card{background:#1E2024;border-color:rgba(255,255,255,.1)}}
            .card{max-width:380px;padding:32px 28px;border-radius:18px;background:#fff;border:1px solid rgba(0,0,0,.08);box-shadow:0 16px 40px rgba(0,0,0,.08);text-align:center}
            .badge{width:46px;height:46px;margin:0 auto 16px;border-radius:50%;background:\(accent);color:#fff;font-size:22px;font-weight:700;display:flex;align-items:center;justify-content:center}
            h1{margin:0 0 8px;font-size:18px;font-weight:600}
            p{margin:0;font-size:13.5px;line-height:1.55;opacity:.72}
            </style></head><body><div class="card"><div class="badge">\(icon)</div><h1>\(title)</h1><p>\(bodyText)</p></div></body></html>
            """
            let status = success ? "200 OK" : "400 Bad Request"
            let response = "HTTP/1.1 \(status)\r\nContent-Type: text/html; charset=utf-8\r\nContent-Length: \(html.utf8.count)\r\nConnection: close\r\n\r\n\(html)"
            connection.send(content: Data(response.utf8), completion: .contentProcessed { _ in connection.cancel() })
        }
    }

    private static let headerTerminator = Data("\r\n\r\n".utf8)

    private static func receiveHTTPHeaders(
        on connection: NWConnection,
        accumulated: Data,
        maxBytes: Int,
        completion: @escaping @Sendable (Data?) -> Void
    ) {
        let remaining = maxBytes - accumulated.count
        guard remaining > 0 else {
            completion(accumulated)
            return
        }
        connection.receive(minimumIncompleteLength: 1, maximumLength: remaining) { chunk, _, isComplete, error in
            var next = accumulated
            if let chunk, !chunk.isEmpty {
                next.append(chunk)
            }
            if next.range(of: headerTerminator) != nil || next.count >= maxBytes || isComplete || error != nil {
                completion(next.isEmpty ? nil : next)
                return
            }
            receiveHTTPHeaders(on: connection, accumulated: next, maxBytes: maxBytes, completion: completion)
        }
    }
}
