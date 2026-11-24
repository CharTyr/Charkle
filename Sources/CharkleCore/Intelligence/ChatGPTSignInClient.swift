import CryptoKit
import Foundation
import Network
import Security
import Synchronization

/// Native Swift implementation of OpenAI's Sign in with ChatGPT DevKit (`openai/sign-in-with-chatgpt-devkit`).
///
/// Follows the official `@siwc/local` protocol verbatim:
/// - OIDC discovery via `https://auth.openai.com/.well-known/openid-configuration`
/// - Dynamic client registration (`dynamic_agent_client` + `agent_name_hint: "Charkle"`)
/// - RFC 8252 IPv4 loopback (`http://127.0.0.1:<port>/auth/callback`) with PKCE S256 & constant-time state check
/// - Cryptographic RS256 ID token verification against OpenAI's live JWKS (`Security.framework`)
/// - Automatic refresh-token rotation persisted exclusively in the macOS Keychain
/// - Model discovery (`GET https://api.openai.com/v1/models`) & streaming Responses API (`POST /v1/responses`, `store: false`, `stream: true`)
public actor ChatGPTSignInClient {
    public static let issuer = "https://auth.openai.com"
    public static let resource = "https://api.openai.com/v1"
    public static let sharingScope = "chatgpt.tokens.use.direct"
    public static let scopes = "openid profile email offline_access resource.invoke chatgpt.tokens.use.direct"
    public static let callbackPath = "/auth/callback"
    public static let usageSettingsURL = URL(string: "https://chatgpt.com/settings/usage")!
    public static let appName = "Charkle"

    private static let keychainKey = "ai.chatgpt.connection.v1"
    private static let maxResponseBytes = 16 * 1024 * 1024

    private let keychain: KeychainStore
    private let session: URLSession
    private var cachedDiscovery: OIDCDiscovery?
    private var cachedJWKS: [JWKKey]?
    private var cachedJWKSFetchedAt: Date?
    private var cachedConnection: StoredConnection?
    private var hasLoadedConnection = false
    private var inFlightRefresh: Task<StoredConnection, Error>?
    private var sessionGeneration: UInt64 = 0

    public init(keychain: KeychainStore = KeychainStore(), session: URLSession? = nil) {
        self.keychain = keychain
        if let session {
            self.session = session
        } else {
            let config = URLSessionConfiguration.ephemeral
            config.httpShouldSetCookies = false
            config.httpCookieAcceptPolicy = .never
            config.urlCache = nil
            config.timeoutIntervalForRequest = 45
            config.timeoutIntervalForResource = 180
            self.session = URLSession(configuration: config, delegate: NoRedirectSessionDelegate(), delegateQueue: nil)
        }
    }

    // MARK: - Public Session & Auth API

    public func currentSession() -> ChatGPTAccountSession {
        guard let stored = try? loadStoredConnection() else {
            return ChatGPTAccountSession(status: .disconnected, sharingEnabled: false)
        }
        return stored.toPublicSession()
    }

    public func hasUsableSession() -> Bool {
        let s = currentSession()
        return s.status == .connected && s.sharingEnabled
    }

    /// Runs the full interactive Sign in with ChatGPT PKCE OAuth 2.0 + OIDC flow.
    public func signIn(
        reconsent: Bool = false,
        switchAccount: Bool = false,
        openBrowser: @Sendable (URL) async -> Void
    ) async throws -> ChatGPTAccountSession {
        let existing = switchAccount ? nil : (try? loadStoredConnection())
        let provider = try await fetchDiscovery()

        let state = Self.randomBase64URL(byteCount: 32)
        let nonce = Self.randomBase64URL(byteCount: 32)
        let verifier = Self.randomBase64URL(byteCount: 32)
        let challenge = Self.codeChallengeS256(for: verifier)

        let loopback = ChatGPTLoopbackServer(
            expectedState: state,
            savedClientID: existing?.clientID
        )
        let port = try await loopback.start()
        let redirectURI = "http://127.0.0.1:\(port)\(Self.callbackPath)"

        var components = URLComponents(string: provider.authorizationEndpoint)
        var queryItems: [URLQueryItem] = [
            URLQueryItem(name: "client_id", value: existing?.clientID ?? "dynamic_agent_client"),
            URLQueryItem(name: "response_type", value: "code"),
            URLQueryItem(name: "redirect_uri", value: redirectURI),
            URLQueryItem(name: "scope", value: Self.scopes),
            URLQueryItem(name: "resource", value: Self.resource),
            URLQueryItem(name: "state", value: state),
            URLQueryItem(name: "nonce", value: nonce),
            URLQueryItem(name: "code_challenge_method", value: "S256"),
            URLQueryItem(name: "code_challenge", value: challenge)
        ]
        if existing?.clientID == nil {
            queryItems.append(URLQueryItem(name: "agent_name_hint", value: Self.appName))
        }
        if let email = existing?.email, !email.isEmpty {
            queryItems.append(URLQueryItem(name: "login_hint", value: email))
        }
        if reconsent {
            queryItems.append(URLQueryItem(name: "prompt", value: "consent"))
        }
        components?.queryItems = queryItems

        guard let authURL = components?.url else {
            await loopback.stop()
            throw ChatGPTAuthError(code: "invalid_config", message: "无法构建 ChatGPT 登录授权链接。", retryable: false)
        }

        await openBrowser(authURL)

        let callback: (code: String, clientID: String)
        do {
            callback = try await loopback.waitForCallback(timeoutSeconds: 300)
        } catch {
            await loopback.stop()
            throw error
        }
        await loopback.stop()

        // Retain the issued client_id before redeeming the one-time code so retries reuse the same registration,
        // without clobbering an existing connected session when the user is attempting to switch accounts.
        let priorStored = try? loadStoredConnection()
        if !(switchAccount && priorStored?.status == .connected) {
            var registrationRecord = existing ?? StoredConnection(
                clientID: callback.clientID,
                status: .disconnected,
                scopes: [],
                savedAt: Date()
            )
            registrationRecord.clientID = callback.clientID
            registrationRecord.savedAt = Date()
            try saveStoredConnection(registrationRecord)
        }

        let tokenJSON = try await postTokenRequest(
            endpoint: provider.tokenEndpoint,
            params: [
                ("grant_type", "authorization_code"),
                ("client_id", callback.clientID),
                ("code", callback.code),
                ("code_verifier", verifier),
                ("redirect_uri", redirectURI),
                ("resource", Self.resource)
            ]
        )

        guard let idToken = tokenJSON["id_token"] as? String, !idToken.isEmpty else {
            throw ChatGPTAuthError(
                code: "invalid_id_token",
                message: "ChatGPT 未返回可验证的身份令牌，请重新登录。",
                retryable: false
            )
        }

        let identity = try await verifyIDToken(
            idToken,
            clientID: callback.clientID,
            expectedNonce: nonce,
            referenceDate: Date()
        )

        if let priorSubject = existing?.subject, !priorSubject.isEmpty, priorSubject != identity.subject {
            throw ChatGPTAuthError(
                code: "account_mismatch",
                message: "本次登录的 ChatGPT 账号与原账号不一致。请登录原账号，或点击「切换账号」重新绑定。",
                retryable: false
            )
        }

        let extracted = try Self.extractTokenFields(from: tokenJSON, requireRefresh: false)

        let connected = StoredConnection(
            clientID: callback.clientID,
            status: .connected,
            scopes: extracted.scopes,
            savedAt: Date(),
            subject: identity.subject,
            name: identity.name,
            email: identity.email,
            credentials: extracted.credentials,
            pendingRefresh: nil
        )
        sessionGeneration &+= 1
        inFlightRefresh?.cancel()
        inFlightRefresh = nil
        try saveStoredConnection(connected)
        return connected.toPublicSession()
    }

    /// Revokes the active refresh token remotely (best-effort) and clears local credentials from Keychain.
    public func disconnect(resetRegistration: Bool = false) async throws {
        sessionGeneration &+= 1
        inFlightRefresh?.cancel()
        inFlightRefresh = nil
        guard var stored = try? loadStoredConnection() else { return }
        let refreshToken = stored.pendingRefresh?.credentials.refreshToken ?? stored.credentials?.refreshToken

        if let refreshToken, !refreshToken.isEmpty,
           let provider = try? await fetchDiscovery(),
           let revokeEndpoint = provider.revocationEndpoint,
           let url = URL(string: revokeEndpoint) {
            for attempt in 0..<2 {
                var request = URLRequest(url: url, timeoutInterval: 10)
                request.httpMethod = "POST"
                request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
                request.httpBody = Self.formEncoded([
                    ("token", refreshToken),
                    ("token_type_hint", "refresh_token"),
                    ("client_id", stored.clientID)
                ])
                if let (_, response) = try? await session.data(for: request),
                   let http = response as? HTTPURLResponse,
                   http.statusCode == 200 {
                    break
                }
                if attempt == 0 {
                    try? await Task.sleep(for: .milliseconds(300))
                }
            }
        }

        if resetRegistration {
            try keychain.delete(Self.keychainKey)
            cachedConnection = nil
            hasLoadedConnection = true
        } else {
            stored.status = .disconnected
            stored.scopes = []
            stored.credentials = nil
            stored.pendingRefresh = nil
            stored.savedAt = Date()
            try saveStoredConnection(stored)
        }
    }

    /// Returns a fresh, valid Bearer access token (automatically refreshing via `refresh_token` if needed,
    /// with in-flight deduplication so concurrent requests never double-spend a single-use rotating refresh token).
    public func validAccessToken() async throws -> String {
        if let activeRefresh = inFlightRefresh {
            let waitGeneration = sessionGeneration
            let refreshed = try await activeRefresh.value
            guard sessionGeneration == waitGeneration else {
                throw ChatGPTAuthError(
                    code: "sign_in_required",
                    message: "ChatGPT 会话已变更，请重试。",
                    retryable: true
                )
            }
            return try Self.extractUsableAccessToken(from: refreshed)
        }

        guard var stored = try loadStoredConnection(), stored.status == .connected else {
            throw ChatGPTAuthError(
                code: "sign_in_required",
                message: "请先在「设置 → 智能与搜索」中登录 ChatGPT 订阅账号。",
                retryable: false
            )
        }
        guard stored.scopes.contains(Self.sharingScope) else {
            throw ChatGPTAuthError(
                code: "sharing_not_enabled",
                message: "已登录 ChatGPT，但尚未开启订阅额度共享权限。请点击「重新授权额度共享」。",
                retryable: false
            )
        }
        guard let creds = stored.credentials else {
            throw ChatGPTAuthError(
                code: "sign_in_required",
                message: "ChatGPT 登录凭证缺失，请重新登录。",
                retryable: false
            )
        }

        let now = Date()
        if stored.pendingRefresh != nil || creds.expiresAt <= now.addingTimeInterval(60) {
            let canRefreshNow: Bool
            if stored.pendingRefresh != nil {
                canRefreshNow = true
            } else if let earliest = creds.earliestRefreshAt {
                canRefreshNow = earliest <= now
            } else {
                canRefreshNow = true
            }

            if canRefreshNow {
                let generation = sessionGeneration
                let snapshot = stored
                let refreshTask = Task {
                    try await self.refreshStoredConnection(snapshot)
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
                        throw ChatGPTAuthError(
                            code: "sign_in_required",
                            message: "ChatGPT 会话已变更，请重试。",
                            retryable: true
                        )
                    }
                    try saveStoredConnection(refreshed)
                    stored = refreshed
                } catch let err as ChatGPTAuthError {
                    if self.sessionGeneration == generation && err.requiresReauthentication {
                        stored.status = .reauthRequired
                        stored.scopes = []
                        stored.credentials = nil
                        stored.pendingRefresh = nil
                        stored.savedAt = Date()
                        try? saveStoredConnection(stored)
                    }
                    throw err
                }
            } else if creds.expiresAt <= now {
                throw ChatGPTAuthError(
                    code: "refresh_not_ready",
                    message: "ChatGPT 令牌暂不可刷新，请稍候重试。",
                    retryable: true
                )
            }
        }

        return try Self.extractUsableAccessToken(from: stored)
    }

    private static func extractUsableAccessToken(from stored: StoredConnection) throws -> String {
        guard stored.status == .connected else {
            throw ChatGPTAuthError(
                code: "sign_in_required",
                message: "请先在「设置 → 智能与搜索」中登录 ChatGPT 订阅账号。",
                retryable: false
            )
        }
        guard let activeCreds = stored.credentials, activeCreds.expiresAt > Date() else {
            throw ChatGPTAuthError(
                code: "refresh_not_ready",
                message: "ChatGPT 会话已恢复，请重新发起请求。",
                retryable: true
            )
        }
        guard stored.scopes.contains(Self.sharingScope) else {
            throw ChatGPTAuthError(
                code: "sharing_not_enabled",
                message: "尚未开启 ChatGPT 订阅额度共享权限，请点击「重新授权额度共享」。",
                retryable: false
            )
        }
        return activeCreds.accessToken
    }

    // MARK: - Model Discovery & Streaming Responses API

    public func listModels() async throws -> [ChatGPTModelInfo] {
        let token = try await validAccessToken()
        guard let url = URL(string: "\(Self.resource)/models") else {
            throw ChatGPTAuthError(code: "invalid_config", message: "模型列表地址无效。", retryable: false)
        }
        var request = URLRequest(url: url, timeoutInterval: 30)
        request.httpMethod = "GET"
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")

        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw ChatGPTAuthError(code: "network_error", message: "无法连接 ChatGPT 服务，请检查网络后重试。", retryable: true)
        }
        guard (200...299).contains(http.statusCode) else {
            throw Self.parseAPIError(data: data, statusCode: http.statusCode, requestID: http.value(forHTTPHeaderField: "x-request-id"))
        }
        return try Self.parseModelCatalog(data)
    }

    /// Calls `POST https://api.openai.com/v1/responses` with `store: false, stream: true`
    /// using the user's ChatGPT subscription Bearer token (no org/project headers).
    public func streamResponse(
        model: String,
        instructions: String?,
        userText: String,
        thumbnailJPEG: Data?
    ) async throws -> String {
        try await streamResponse(
            model: model,
            instructions: instructions,
            userText: userText,
            imagesJPEG: thumbnailJPEG.map { [$0] } ?? []
        )
    }

    public func streamResponse(
        model: String,
        instructions: String?,
        userText: String,
        imagesJPEG: [Data]
    ) async throws -> String {
        let trimmedModel = model.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedModel.isEmpty else {
            throw ChatGPTAuthError(code: "invalid_request", message: "请先在设置中选择一个 ChatGPT 模型。", retryable: false)
        }
        let token = try await validAccessToken()

        // Try multimodal input first when images are provided; if the user's ChatGPT sharing route
        // restricts image inputs, fall back gracefully to text-only prompt automatically.
        if !imagesJPEG.isEmpty {
            var contentParts: [[String: Any]] = [["type": "input_text", "text": userText]]
            for jpeg in imagesJPEG {
                contentParts.append(["type": "input_image", "image_url": "data:image/jpeg;base64," + jpeg.base64EncodedString()])
            }
            do {
                return try await performResponsesStream(
                    token: token,
                    model: trimmedModel,
                    instructions: instructions,
                    input: [["role": "user", "content": contentParts]]
                )
            } catch let err as ChatGPTAuthError where err.shouldFallbackToTextOnly {
                // Retry with plain string content (supported universally by @siwc/local)
            }
        }

        return try await performResponsesStream(
            token: token,
            model: trimmedModel,
            instructions: instructions,
            input: [["role": "user", "content": userText]]
        )
    }

    private func performResponsesStream(
        token: String,
        model: String,
        instructions: String?,
        input: [[String: Any]]
    ) async throws -> String {
        guard let url = URL(string: "\(Self.resource)/responses") else {
            throw ChatGPTAuthError(code: "invalid_config", message: "Responses 服务地址无效。", retryable: false)
        }
        var body: [String: Any] = [
            "model": model,
            "input": input,
            "store": false,
            "stream": true
        ]
        if let instructions, !instructions.isEmpty {
            body["instructions"] = instructions
        }

        var request = URLRequest(url: url, timeoutInterval: 180)
        request.httpMethod = "POST"
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("text/event-stream", forHTTPHeaderField: "Accept")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (bytes, response) = try await session.bytes(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw ChatGPTAuthError(code: "network_error", message: "无法连接 ChatGPT 服务，请检查网络后重试。", retryable: true)
        }
        let requestID = http.value(forHTTPHeaderField: "x-request-id")

        guard (200...299).contains(http.statusCode) else {
            var errorData = Data()
            for try await chunk in bytes {
                errorData.append(chunk)
                if errorData.count > 131_072 { break }
            }
            throw Self.parseAPIError(data: errorData, statusCode: http.statusCode, requestID: requestID)
        }

        let contentType = http.value(forHTTPHeaderField: "Content-Type")?
            .split(separator: ";", maxSplits: 1).first?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()

        // If the server returned a direct non-streaming JSON payload, parse it cleanly.
        if contentType == "application/json" {
            var jsonData = Data()
            for try await byte in bytes {
                jsonData.append(byte)
                if jsonData.count > Self.maxResponseBytes {
                    throw ChatGPTAuthError(code: "response_too_large", message: "模型返回内容过大，请精简素材信息后重试。", retryable: false)
                }
            }
            let text = try Self.extractCompletedJSONText(jsonData)
            let usage = Self.extractUsageTokens(from: jsonData)
            CloudAIUsageStore.shared.record(
                providerLabel: "ChatGPT 订阅",
                model: model,
                inputTokens: usage.input,
                outputTokens: usage.output,
                totalTokens: usage.total
            )
            return text
        }

        // Standard SSE stream (`text/event-stream` or omitted content-type per @siwc/local)
        if let contentType, !contentType.isEmpty, contentType != "text/event-stream" {
            throw ChatGPTAuthError(
                code: "invalid_stream",
                message: "ChatGPT 未返回预期的流式响应，请稍后重试。",
                retryable: true,
                statusCode: http.statusCode
            )
        }

        var parser = SSEStreamAccumulator()
        for try await line in bytes.lines {
            try Task.checkCancellation()
            try parser.consume(line: line, statusCode: http.statusCode, requestID: requestID)
            if parser.isCompleted { break }
        }
        try parser.finish(statusCode: http.statusCode, requestID: requestID)
        CloudAIUsageStore.shared.record(
            providerLabel: "ChatGPT 订阅",
            model: model,
            inputTokens: parser.inputTokens,
            outputTokens: parser.outputTokens,
            totalTokens: parser.totalTokens
        )
        return parser.accumulatedText
    }

    // MARK: - Internal Refresh & Discovery Helpers

    private func refreshStoredConnection(_ previous: StoredConnection) async throws -> StoredConnection {
        let provider = try await fetchDiscovery()
        var rotation = previous.pendingRefresh
        let extracted: (scopes: [String], credentials: StoredCredentials?)

        if let existingRotation = rotation {
            extracted = (existingRotation.scopes, existingRotation.credentials)
        } else {
            guard let refreshToken = previous.credentials?.refreshToken, !refreshToken.isEmpty else {
                throw ChatGPTAuthError(
                    code: "invalid_grant",
                    message: "ChatGPT 登录状态已过期，请重新登录。",
                    retryable: false
                )
            }
            var data = try await postTokenRequest(
                endpoint: provider.tokenEndpoint,
                params: [
                    ("grant_type", "refresh_token"),
                    ("client_id", previous.clientID),
                    ("refresh_token", refreshToken),
                    ("resource", Self.resource)
                ]
            )
            if data["scope"] == nil {
                data["scope"] = previous.scopes.joined(separator: " ")
            }
            extracted = try Self.extractTokenFields(from: data, requireRefresh: true)
            if let idToken = data["id_token"] as? String {
                guard !idToken.isEmpty else {
                    throw ChatGPTAuthError(code: "invalid_id_token", message: "刷新后的身份令牌无效，请重新登录。", retryable: false)
                }
                if let creds = extracted.credentials {
                    let pending = PendingRefreshCheckpoint(
                        credentials: creds,
                        scopes: extracted.scopes,
                        idToken: idToken,
                        receivedAt: Date()
                    )
                    rotation = pending
                    var checkpointed = previous
                    checkpointed.pendingRefresh = pending
                    checkpointed.savedAt = Date()
                    try saveStoredConnection(checkpointed)
                }
            }
        }

        var updated = previous
        if let rotation {
            let verified = try await verifyIDToken(
                rotation.idToken,
                clientID: previous.clientID,
                expectedNonce: nil,
                referenceDate: rotation.receivedAt
            )
            if let priorSub = previous.subject, !priorSub.isEmpty, verified.subject != priorSub {
                throw ChatGPTAuthError(
                    code: "account_mismatch",
                    message: "刷新后的 ChatGPT 账号身份不匹配，请重新登录原账号。",
                    retryable: false
                )
            }
            updated.subject = verified.subject
            updated.name = verified.name ?? updated.name
            updated.email = verified.email ?? updated.email
        }

        updated.status = .connected
        updated.scopes = extracted.scopes
        updated.credentials = extracted.credentials
        updated.pendingRefresh = nil
        updated.savedAt = Date()
        return updated
    }

    private func fetchDiscovery() async throws -> OIDCDiscovery {
        if let cachedDiscovery { return cachedDiscovery }
        guard let url = URL(string: "\(Self.issuer)/.well-known/openid-configuration") else {
            throw ChatGPTAuthError(code: "discovery_failed", message: "无法验证 ChatGPT 登录配置。", retryable: true)
        }
        var request = URLRequest(url: url, timeoutInterval: 20)
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
            throw ChatGPTAuthError(code: "discovery_failed", message: "无法获取 ChatGPT 登录配置，请检查网络连接。", retryable: true)
        }
        let parsed = try Self.parseDiscovery(data)
        cachedDiscovery = parsed
        return parsed
    }

    private func postTokenRequest(endpoint: String, params: [(String, String)]) async throws -> [String: Any] {
        guard let url = URL(string: endpoint),
              url.scheme == "https",
              url.host()?.lowercased() == "auth.openai.com" else {
            throw ChatGPTAuthError(code: "discovery_failed", message: "ChatGPT 令牌端点校验失败。", retryable: false)
        }
        var request = URLRequest(url: url, timeoutInterval: 30)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.httpBody = Self.formEncoded(params)

        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw ChatGPTAuthError(code: "network_error", message: "无法连接 ChatGPT 认证服务，请检查网络。", retryable: true)
        }
        guard (200...299).contains(http.statusCode) else {
            throw Self.parseAPIError(data: data, statusCode: http.statusCode, requestID: http.value(forHTTPHeaderField: "x-request-id"))
        }
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw ChatGPTAuthError(code: "invalid_token_response", message: "ChatGPT 返回的令牌响应格式无效。", retryable: false)
        }
        return json
    }

    private func fetchJWKS(uri: String, forceRefresh: Bool = false) async throws -> [JWKKey] {
        if !forceRefresh,
           let cachedJWKS,
           let fetchedAt = cachedJWKSFetchedAt,
           Date().timeIntervalSince(fetchedAt) < 3600 {
            return cachedJWKS
        }
        guard let url = URL(string: uri),
              url.scheme == "https",
              url.host()?.lowercased() == "auth.openai.com" else {
            throw ChatGPTAuthError(code: "identity_verification_unavailable", message: "ChatGPT 身份验证服务暂时不可用，请稍后重试。", retryable: true)
        }
        var request = URLRequest(url: url, timeoutInterval: 15)
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        let (data, response): (Data, URLResponse)
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            throw ChatGPTAuthError(code: "identity_verification_unavailable", message: "ChatGPT 身份验证服务暂时不可用，请稍后重试。", retryable: true)
        }
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            throw ChatGPTAuthError(code: "identity_verification_unavailable", message: "ChatGPT 身份验证服务暂时不可用，请稍后重试。", retryable: true)
        }
        let decoded = try JSONDecoder().decode(JWKSResponse.self, from: data)
        guard !decoded.keys.isEmpty else {
            throw ChatGPTAuthError(code: "identity_verification_unavailable", message: "ChatGPT 身份公钥为空，请稍后重试。", retryable: true)
        }
        cachedJWKS = decoded.keys
        cachedJWKSFetchedAt = Date()
        return decoded.keys
    }

    private func verifyIDToken(
        _ idToken: String,
        clientID: String,
        expectedNonce: String?,
        referenceDate: Date
    ) async throws -> VerifiedIdentity {
        let provider = try await fetchDiscovery()
        let keys = try await fetchJWKS(uri: provider.jwksURI, forceRefresh: false)
        do {
            return try Self.verifyRS256IDToken(
                idToken,
                keys: keys,
                expectedIssuer: provider.issuer,
                expectedClientID: clientID,
                expectedNonce: expectedNonce,
                referenceDate: referenceDate
            )
        } catch let err as ChatGPTAuthError where err.code == "jwks_key_not_found" {
            // Key rotation: retry once with freshly fetched JWKS
            let refreshedKeys = try await fetchJWKS(uri: provider.jwksURI, forceRefresh: true)
            return try Self.verifyRS256IDToken(
                idToken,
                keys: refreshedKeys,
                expectedIssuer: provider.issuer,
                expectedClientID: clientID,
                expectedNonce: expectedNonce,
                referenceDate: referenceDate
            )
        }
    }

    private func loadStoredConnection() throws -> StoredConnection? {
        if hasLoadedConnection { return cachedConnection }
        guard let data = try keychain.read(Self.keychainKey) else {
            cachedConnection = nil
            hasLoadedConnection = true
            return nil
        }
        let decoded = try JSONDecoder().decode(StoredConnection.self, from: data)
        cachedConnection = decoded
        hasLoadedConnection = true
        return decoded
    }

    private func saveStoredConnection(_ connection: StoredConnection) throws {
        let data = try JSONEncoder().encode(connection)
        try keychain.save(data, for: Self.keychainKey)
        cachedConnection = connection
        hasLoadedConnection = true
    }

    // MARK: - Testable Static Protocol Parsers & Cryptography

    struct OIDCDiscovery: Sendable, Equatable {
        let issuer: String
        let authorizationEndpoint: String
        let tokenEndpoint: String
        let revocationEndpoint: String?
        let jwksURI: String
    }

    struct JWKKey: Decodable, Sendable {
        let kty: String
        let kid: String?
        let alg: String?
        let n: String?
        let e: String?
    }

    private struct JWKSResponse: Decodable {
        let keys: [JWKKey]
    }

    struct VerifiedIdentity: Sendable, Equatable {
        let subject: String
        let name: String?
        let email: String?
    }

    static func parseDiscovery(_ data: Data) throws -> OIDCDiscovery {
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let iss = json["issuer"] as? String, iss == Self.issuer,
              let authEndpoint = json["authorization_endpoint"] as? String,
              let tokenEndpoint = json["token_endpoint"] as? String,
              let jwksURI = json["jwks_uri"] as? String else {
            throw ChatGPTAuthError(code: "discovery_failed", message: "ChatGPT OIDC 配置校验失败。", retryable: true)
        }
        let revocationEndpoint = json["revocation_endpoint"] as? String
        for candidate in [authEndpoint, tokenEndpoint, jwksURI] + (revocationEndpoint.map { [$0] } ?? []) {
            guard let u = URL(string: candidate),
                  u.scheme == "https",
                  u.host()?.lowercased() == "auth.openai.com" else {
                throw ChatGPTAuthError(code: "discovery_failed", message: "ChatGPT 端点域名不在受信任的 auth.openai.com 域内。", retryable: false)
            }
        }
        return OIDCDiscovery(
            issuer: iss,
            authorizationEndpoint: authEndpoint,
            tokenEndpoint: tokenEndpoint,
            revocationEndpoint: revocationEndpoint,
            jwksURI: jwksURI
        )
    }

    static func parseModelCatalog(_ data: Data) throws -> [ChatGPTModelInfo] {
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw ChatGPTAuthError(code: "invalid_model_catalog", message: "ChatGPT 返回的模型列表格式异常。", retryable: true)
        }
        if let models = root["models"] as? [[String: Any]] {
            var list: [ChatGPTModelInfo] = []
            for entry in models {
                guard (entry["visibility"] as? String) == "list" else { continue }
                guard let slug = (entry["slug"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
                      !slug.isEmpty, slug.count <= 200,
                      let display = (entry["display_name"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
                      !display.isEmpty, display.count <= 200 else {
                    continue
                }
                list.append(ChatGPTModelInfo(slug: slug, displayName: display))
            }
            return list
        }
        if let items = root["data"] as? [[String: Any]] {
            return items.compactMap { entry in
                guard let id = (entry["id"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines), !id.isEmpty else { return nil }
                return ChatGPTModelInfo(slug: id, displayName: id)
            }
        }
        throw ChatGPTAuthError(code: "invalid_model_catalog", message: "ChatGPT 返回的模型列表格式异常。", retryable: true)
    }

    static func extractCompletedJSONText(_ data: Data) throws -> String {
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw ChatGPTAuthError(code: "invalid_response", message: "ChatGPT 返回了无效的 JSON 响应。", retryable: true)
        }
        if let direct = root["output_text"] as? String, !direct.isEmpty {
            return direct
        }
        if let output = root["output"] as? [[String: Any]] {
            let texts = output.flatMap { item -> [String] in
                (item["content"] as? [[String: Any]] ?? []).compactMap { $0["text"] as? String }
            }
            let joined = texts.joined(separator: "\n")
            if !joined.isEmpty { return joined }
        }
        throw ChatGPTAuthError(code: "invalid_response", message: "ChatGPT 未返回文本结果。", retryable: true)
    }

    static func verifyRS256IDToken(
        _ jwt: String,
        keys: [JWKKey],
        expectedIssuer: String,
        expectedClientID: String,
        expectedNonce: String?,
        referenceDate: Date = Date()
    ) throws -> VerifiedIdentity {
        let parts = jwt.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 3,
              let headerData = base64URLDecode(String(parts[0])),
              let payloadData = base64URLDecode(String(parts[1])),
              let signatureData = base64URLDecode(String(parts[2])),
              let header = try JSONSerialization.jsonObject(with: headerData) as? [String: Any],
              let payload = try JSONSerialization.jsonObject(with: payloadData) as? [String: Any] else {
            throw ChatGPTAuthError(code: "invalid_id_token", message: "无法解析 ChatGPT 身份令牌，请重新登录。", retryable: false)
        }

        guard (header["alg"] as? String) == "RS256" else {
            throw ChatGPTAuthError(code: "invalid_id_token", message: "不支持的身份令牌签名算法。", retryable: false)
        }

        let kid = header["kid"] as? String
        let candidateKeys = keys.filter { key in
            guard key.kty == "RSA", key.n != nil, key.e != nil else { return false }
            if let kid { return key.kid == kid }
            return true
        }
        guard !candidateKeys.isEmpty else {
            throw ChatGPTAuthError(code: "jwks_key_not_found", message: "未找到匹配的身份验证公钥。", retryable: true)
        }

        let signingInput = Data("\(parts[0]).\(parts[1])".utf8)
        var signatureVerified = false
        for key in candidateKeys {
            guard let nStr = key.n, let eStr = key.e,
                  let nBytes = base64URLDecode(nStr),
                  let eBytes = base64URLDecode(eStr) else { continue }
            if let secKey = try? makeRSAPublicKey(modulus: nBytes, exponent: eBytes),
               SecKeyVerifySignature(secKey, .rsaSignatureMessagePKCS1v15SHA256, signingInput as CFData, signatureData as CFData, nil) {
                signatureVerified = true
                break
            }
        }
        guard signatureVerified else {
            throw ChatGPTAuthError(code: "invalid_id_token", message: "ChatGPT 身份令牌签名验证失败，请重新登录。", retryable: false)
        }

        // Standard OIDC claims checks (matching @siwc/local oauth.ts lines 427-441)
        guard let iss = payload["iss"] as? String, iss == expectedIssuer,
              let sub = payload["sub"] as? String, !sub.isEmpty,
              let exp = numericClaim(payload["exp"]),
              let iat = numericClaim(payload["iat"]) else {
            throw ChatGPTAuthError(code: "invalid_id_token", message: "ChatGPT 身份令牌缺少必要声明，请重新登录。", retryable: false)
        }

        let nowSecs = referenceDate.timeIntervalSince1970
        let clockTolerance: TimeInterval = 60
        guard exp + clockTolerance >= nowSecs, iat - clockTolerance <= nowSecs else {
            throw ChatGPTAuthError(code: "invalid_id_token", message: "ChatGPT 身份令牌已过期或时间无效，请重新登录。", retryable: false)
        }

        let audList: [String]
        if let singleAud = payload["aud"] as? String {
            audList = [singleAud]
        } else if let multiAud = payload["aud"] as? [String] {
            audList = multiAud
        } else {
            audList = []
        }
        guard audList.contains(expectedClientID) else {
            throw ChatGPTAuthError(code: "invalid_id_token", message: "ChatGPT 身份令牌受众不匹配。", retryable: false)
        }
        if let azp = payload["azp"] as? String, azp != expectedClientID {
            throw ChatGPTAuthError(code: "invalid_id_token", message: "ChatGPT 身份令牌授权方不匹配。", retryable: false)
        }
        if audList.count > 1, (payload["azp"] as? String) != expectedClientID {
            throw ChatGPTAuthError(code: "invalid_id_token", message: "ChatGPT 身份令牌多受众校验失败。", retryable: false)
        }
        if let expectedNonce, (payload["nonce"] as? String) != expectedNonce {
            throw ChatGPTAuthError(code: "invalid_id_token", message: "ChatGPT 身份令牌 Nonce 校验失败，请重新登录。", retryable: false)
        }

        return VerifiedIdentity(
            subject: sub,
            name: payload["name"] as? String,
            email: payload["email"] as? String
        )
    }

    /// Encodes RSA `(n, e)` into ASN.1 DER PKCS#1 `RSAPublicKey` and constructs a `SecKey`.
    static func makeRSAPublicKey(modulus: Data, exponent: Data) throws -> SecKey {
        let der = asn1Sequence(asn1Integer(modulus) + asn1Integer(exponent))
        let attributes: [String: Any] = [
            kSecAttrKeyType as String: kSecAttrKeyTypeRSA,
            kSecAttrKeyClass as String: kSecAttrKeyClassPublic
        ]
        var error: Unmanaged<CFError>?
        guard let key = SecKeyCreateWithData(der as CFData, attributes as CFDictionary, &error) else {
            throw ChatGPTAuthError(code: "invalid_id_token", message: "无法解析 RSA 公钥。", retryable: false)
        }
        return key
    }

    private static func asn1Integer(_ raw: Data) -> Data {
        var bytes = Array(raw)
        while bytes.count > 1 && bytes.first == 0x00 {
            bytes.removeFirst()
        }
        if bytes.isEmpty {
            bytes = [0x00]
        } else if bytes[0] >= 0x80 {
            bytes.insert(0x00, at: 0)
        }
        return Data([0x02]) + asn1Length(bytes.count) + Data(bytes)
    }

    private static func asn1Sequence(_ contents: Data) -> Data {
        Data([0x30]) + asn1Length(contents.count) + contents
    }

    private static func asn1Length(_ length: Int) -> Data {
        if length < 0x80 {
            return Data([UInt8(length)])
        }
        var value = length
        var octets: [UInt8] = []
        while value > 0 {
            octets.insert(UInt8(value & 0xFF), at: 0)
            value >>= 8
        }
        return Data([0x80 | UInt8(octets.count)]) + Data(octets)
    }

    private static func numericClaim(_ raw: Any?) -> TimeInterval? {
        if let n = raw as? NSNumber { return n.doubleValue }
        if let d = raw as? Double { return d }
        if let i = raw as? Int { return Double(i) }
        return nil
    }

    static func extractTokenFields(
        from data: [String: Any],
        requireRefresh: Bool
    ) throws -> (scopes: [String], credentials: StoredCredentials?) {
        guard let scopeStr = data["scope"] as? String else {
            throw ChatGPTAuthError(code: "invalid_token_response", message: "ChatGPT 未确认授予的权限范围，请重新登录。", retryable: false)
        }
        let scopes = scopeStr.split(whereSeparator: \.isWhitespace).map(String.init)
        var credentials: StoredCredentials?
        if let accessToken = data["access_token"] as? String, !accessToken.isEmpty {
            let tokenType = (data["token_type"] as? String)?.lowercased()
            let expiresIn = numericClaim(data["expires_in"])
            let refreshToken = data["refresh_token"] as? String
            guard tokenType == "bearer",
                  let expiresIn, expiresIn.isFinite, expiresIn > 0 else {
                throw ChatGPTAuthError(code: "invalid_token_response", message: "ChatGPT 返回的登录凭据不完整，请重新登录。", retryable: false)
            }
            if (requireRefresh || scopes.contains("offline_access")) && (refreshToken?.isEmpty ?? true) {
                throw ChatGPTAuthError(code: "invalid_token_response", message: "ChatGPT 未返回刷新令牌，请重新登录。", retryable: false)
            }
            let earliestRefreshAt: Date?
            if let num = numericClaim(data["earliest_refresh_at"]) {
                earliestRefreshAt = Date(timeIntervalSince1970: num)
            } else if let str = data["earliest_refresh_at"] as? String {
                earliestRefreshAt = try? Date.ISO8601FormatStyle().parse(str)
            } else {
                earliestRefreshAt = nil
            }
            credentials = StoredCredentials(
                accessToken: accessToken,
                refreshToken: refreshToken,
                expiresAt: Date().addingTimeInterval(expiresIn),
                earliestRefreshAt: earliestRefreshAt
            )
        } else if requireRefresh || scopes.contains("offline_access") || scopes.contains(Self.sharingScope) {
            throw ChatGPTAuthError(code: "invalid_token_response", message: "ChatGPT 未返回所需访问令牌，请重新登录。", retryable: false)
        }
        return (scopes, credentials)
    }

    static func parseAPIError(data: Data?, statusCode: Int?, requestID: String?) -> ChatGPTAuthError {
        var root: [String: Any] = [:]
        if let data, let parsed = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            root = parsed
        }
        var detail = root
        for _ in 0..<4 {
            if let nested = detail["error"] as? [String: Any] {
                detail = nested
            } else if let nested = detail["detail"] as? [String: Any] {
                detail = nested
            } else {
                break
            }
        }
        let rawCode: String? = (detail["error"] as? String) ?? (detail["code"] as? String)
        let code = rawCode ?? "api_error"
        return Self.mapKnownError(code: code, statusCode: statusCode, requestID: requestID)
    }

    static func mapKnownError(code: String, statusCode: Int?, requestID: String? = nil) -> ChatGPTAuthError {
        let normalized: String = switch code {
        case "subscription_sharing_v2_user_not_eligible": "subscription_sharing_user_not_eligible"
        case "subscription_sharing_v2_route_not_supported": "subscription_sharing_route_not_supported"
        case "subscription_sharing_v2_invalid_user": "subscription_sharing_invalid_user"
        case "subscription_sharing_v2_user_unavailable": "subscription_sharing_user_unavailable"
        default: code
        }

        switch normalized {
        case "subscription_sharing_user_not_eligible":
            return ChatGPTAuthError(code: normalized, message: "当前 ChatGPT 账号或工作区暂不支持订阅额度共享（需符合条件的 Plus / Pro 等订阅）。", retryable: false, statusCode: statusCode, requestID: requestID)
        case "subscription_sharing_usage_limit_exceeded":
            return ChatGPTAuthError(code: normalized, message: "已达到 ChatGPT 订阅额度共享上限，可在 ChatGPT 设置中查看用量与限额。", retryable: false, statusCode: statusCode, requestID: requestID)
        case "subscription_sharing_usage_unavailable":
            return ChatGPTAuthError(code: normalized, message: "暂时无法查询 ChatGPT 用量，请稍后重试。", retryable: true, statusCode: statusCode, requestID: requestID)
        case "subscription_sharing_unsupported_capability":
            return ChatGPTAuthError(code: normalized, message: "该请求包含当前 ChatGPT 订阅共享暂不支持的能力。", retryable: false, statusCode: statusCode, requestID: requestID)
        case "subscription_sharing_route_not_supported":
            return ChatGPTAuthError(code: normalized, message: "当前接口不支持 ChatGPT 订阅额度共享。", retryable: false, statusCode: statusCode, requestID: requestID)
        case "subscription_sharing_invalid_user":
            return ChatGPTAuthError(code: normalized, message: "ChatGPT 无法校验该账号的订阅状态，请检查已连接的账号与授权。", retryable: false, statusCode: statusCode, requestID: requestID)
        case "subscription_sharing_user_unavailable":
            return ChatGPTAuthError(code: normalized, message: "你的 ChatGPT 账号或工作区暂时不可用，请稍后重试。", retryable: true, statusCode: statusCode, requestID: requestID)
        case "subscription_sharing_v2_client_not_enabled":
            return ChatGPTAuthError(code: normalized, message: "当前应用未启用 ChatGPT 订阅额度共享。", retryable: false, statusCode: statusCode, requestID: requestID)
        case "chatpass_v2_scope_not_authorized", "chatpass_v2_invalid_authorization_context":
            return ChatGPTAuthError(code: normalized, message: "已授予的 ChatGPT 权限不足以完成此请求，请点击「重新授权额度共享」。", retryable: false, statusCode: statusCode, requestID: requestID)
        case "invalid_grant", "invalid_refresh_token", "token_expired", "refresh_token_expired", "refresh_token_invalidated", "refresh_token_reused":
            return ChatGPTAuthError(code: normalized, message: "你的 ChatGPT 登录状态已失效，请重新登录。", retryable: false, statusCode: statusCode, requestID: requestID)
        case "access_denied":
            return ChatGPTAuthError(code: normalized, message: "已取消 ChatGPT 登录授权，随时可以重试。", retryable: false, statusCode: statusCode, requestID: requestID)
        case "model_not_found":
            return ChatGPTAuthError(code: normalized, message: "当前 ChatGPT 账号不可使用所选模型，请在设置中切换其他可用模型。", retryable: false, statusCode: statusCode, requestID: requestID)
        default:
            break
        }

        if statusCode == 400 || statusCode == 422 || normalized == "invalid_request_error" || normalized == "invalid_request" {
            return ChatGPTAuthError(code: normalized, message: "ChatGPT 拒绝了本次请求参数，请检查所选模型或重试。", retryable: false, statusCode: statusCode, requestID: requestID)
        }
        if statusCode == 401 {
            return ChatGPTAuthError(code: normalized, message: "ChatGPT 未接受当前登录凭证或权限，请检查连接状态或重新授权。", retryable: false, statusCode: statusCode, requestID: requestID)
        }
        if statusCode == 403 {
            return ChatGPTAuthError(code: normalized, message: "受 ChatGPT 权限或地区策略限制，当前无法完成该请求。", retryable: false, statusCode: statusCode, requestID: requestID)
        }
        if statusCode == 429 {
            return ChatGPTAuthError(code: normalized, message: "请求过于频繁或已达速率上限，请稍后再试。", retryable: true, statusCode: statusCode, requestID: requestID)
        }
        if let statusCode, statusCode >= 500 {
            return ChatGPTAuthError(code: normalized, message: "ChatGPT 服务暂时不可用，请稍后重试。", retryable: true, statusCode: statusCode, requestID: requestID)
        }
        return ChatGPTAuthError(code: normalized, message: "ChatGPT 请求未能完成（\(normalized)）。", retryable: false, statusCode: statusCode, requestID: requestID)
    }

    static func randomBase64URL(byteCount: Int) -> String {
        var bytes = [UInt8](repeating: 0, count: byteCount)
        _ = SecRandomCopyBytes(kSecRandomDefault, byteCount, &bytes)
        return base64URLEncode(Data(bytes))
    }

    static func codeChallengeS256(for verifier: String) -> String {
        base64URLEncode(Data(SHA256.hash(data: Data(verifier.utf8))))
    }

    static func base64URLEncode(_ data: Data) -> String {
        data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    static func base64URLDecode(_ string: String) -> Data? {
        var base64 = string
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        let remainder = base64.count % 4
        if remainder > 0 {
            base64 += String(repeating: "=", count: 4 - remainder)
        }
        return Data(base64Encoded: base64)
    }

    private static func formEncoded(_ params: [(String, String)]) -> Data {
        let allowed = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")
        let encoded = params.map { key, value in
            key + "=" + (value.addingPercentEncoding(withAllowedCharacters: allowed) ?? "")
        }.joined(separator: "&")
        return Data(encoded.utf8)
    }

    // MARK: - Internal Keychain Models

    struct StoredCredentials: Codable, Sendable {
        let accessToken: String
        let refreshToken: String?
        let expiresAt: Date
        let earliestRefreshAt: Date?
    }

    struct PendingRefreshCheckpoint: Codable, Sendable {
        let credentials: StoredCredentials
        let scopes: [String]
        let idToken: String
        let receivedAt: Date
    }

    struct StoredConnection: Codable, Sendable {
        var clientID: String
        var status: ChatGPTConnectionStatus
        var scopes: [String]
        var savedAt: Date
        var subject: String?
        var name: String?
        var email: String?
        var credentials: StoredCredentials?
        var pendingRefresh: PendingRefreshCheckpoint?

        func toPublicSession() -> ChatGPTAccountSession {
            ChatGPTAccountSession(
                status: status,
                sharingEnabled: status == .connected && credentials != nil && scopes.contains(ChatGPTSignInClient.sharingScope),
                email: email,
                name: name,
                subject: subject,
                lastUpdatedAt: savedAt
            )
        }
    }

    // MARK: - SSE Stream Parser

    struct SSEStreamAccumulator {
        private(set) var accumulatedText: String = ""
        private(set) var isCompleted: Bool = false
        private(set) var inputTokens: Int = 0
        private(set) var outputTokens: Int = 0
        private(set) var totalTokens: Int?
        private var dataLines: [String] = []

        mutating func consume(line: String, statusCode: Int, requestID: String?) throws {
            let trimmed = line.hasSuffix("\r") ? String(line.dropLast()) : line
            if trimmed.isEmpty {
                try flushEvent(statusCode: statusCode, requestID: requestID)
                return
            }
            if trimmed.hasPrefix(":") { return }
            if trimmed.hasPrefix("data:") {
                let payload = String(trimmed.dropFirst(5)).trimmingCharacters(in: .whitespaces)
                dataLines.append(payload)
                // If this single line is already complete JSON (standard OpenAI SSE format), process immediately.
                if payload.hasPrefix("{") && payload.hasSuffix("}") {
                    try flushEvent(statusCode: statusCode, requestID: requestID)
                }
            }
        }

        mutating func finish(statusCode: Int, requestID: String?) throws {
            try flushEvent(statusCode: statusCode, requestID: requestID)
            guard isCompleted else {
                throw ChatGPTAuthError(
                    code: "stream_interrupted",
                    message: "ChatGPT 响应在完成前中断，请稍后重试。",
                    retryable: true,
                    statusCode: statusCode,
                    requestID: requestID
                )
            }
        }

        private mutating func flushEvent(statusCode: Int, requestID: String?) throws {
            guard !dataLines.isEmpty else { return }
            let joined = dataLines.joined(separator: "\n")
            dataLines.removeAll(keepingCapacity: true)
            if joined == "[DONE]" || joined.isEmpty { return }
            guard let jsonData = joined.data(using: .utf8),
                  let event = try JSONSerialization.jsonObject(with: jsonData) as? [String: Any] else {
                throw ChatGPTAuthError(
                    code: "invalid_stream",
                    message: "ChatGPT 流式响应包含无法解析的事件，请重试。",
                    retryable: true,
                    statusCode: statusCode,
                    requestID: requestID
                )
            }
            guard let type = event["type"] as? String else { return }
            switch type {
            case "response.output_text.delta":
                if let delta = event["delta"] as? String {
                    accumulatedText += delta
                    if accumulatedText.utf8.count > ChatGPTSignInClient.maxResponseBytes {
                        throw ChatGPTAuthError(code: "response_too_large", message: "模型返回内容过大。", retryable: false)
                    }
                }
            case "response.failed":
                let detail = event["response"] as? [String: Any] ?? event
                let detailData = try? JSONSerialization.data(withJSONObject: detail)
                throw ChatGPTSignInClient.parseAPIError(data: detailData, statusCode: statusCode, requestID: requestID)
            case "error":
                let detailData = try? JSONSerialization.data(withJSONObject: event)
                throw ChatGPTSignInClient.parseAPIError(data: detailData, statusCode: statusCode, requestID: requestID)
            case "response.incomplete":
                throw ChatGPTAuthError(
                    code: "response_incomplete",
                    message: "ChatGPT 响应提前结束，请稍后重试。",
                    retryable: true,
                    statusCode: statusCode,
                    requestID: requestID
                )
            case "response.completed":
                if let responseObj = event["response"] as? [String: Any] {
                    if let usageObj = responseObj["usage"] as? [String: Any] {
                        inputTokens = (usageObj["input_tokens"] as? Int) ?? (usageObj["prompt_tokens"] as? Int) ?? inputTokens
                        outputTokens = (usageObj["output_tokens"] as? Int) ?? (usageObj["completion_tokens"] as? Int) ?? outputTokens
                        if let tot = usageObj["total_tokens"] as? Int {
                            totalTokens = tot
                        }
                    }
                    if accumulatedText.isEmpty,
                       let responseData = try? JSONSerialization.data(withJSONObject: responseObj),
                       let fallback = try? ChatGPTSignInClient.extractCompletedJSONText(responseData) {
                        accumulatedText = fallback
                    }
                }
                isCompleted = true
            default:
                break
            }
        }
    }

    private static func extractUsageTokens(from jsonData: Data) -> (input: Int, output: Int, total: Int?) {
        guard let root = try? JSONSerialization.jsonObject(with: jsonData) as? [String: Any] else {
            return (0, 0, nil)
        }
        let usage = (root["usage"] as? [String: Any])
            ?? ((root["response"] as? [String: Any])?["usage"] as? [String: Any])
        guard let usage else { return (0, 0, nil) }
        let input = (usage["input_tokens"] as? Int) ?? (usage["prompt_tokens"] as? Int) ?? 0
        let output = (usage["output_tokens"] as? Int) ?? (usage["completion_tokens"] as? Int) ?? 0
        let total = usage["total_tokens"] as? Int
        return (input, output, total)
    }
}

public struct ChatGPTAuthError: Error, LocalizedError, Sendable {
    public let code: String
    public let message: String
    public let retryable: Bool
    public let statusCode: Int?
    public let requestID: String?

    public init(code: String, message: String, retryable: Bool, statusCode: Int? = nil, requestID: String? = nil) {
        self.code = code
        self.message = message
        self.retryable = retryable
        self.statusCode = statusCode
        self.requestID = requestID
    }

    public var errorDescription: String? { message }

    public var requiresReauthentication: Bool {
        [
            "invalid_grant",
            "invalid_refresh_token",
            "token_expired",
            "refresh_token_expired",
            "refresh_token_invalidated",
            "refresh_token_reused",
            "invalid_id_token",
            "invalid_token_response",
            "account_mismatch"
        ].contains(code)
    }

    var shouldFallbackToTextOnly: Bool {
        code == "subscription_sharing_unsupported_capability"
            || code == "invalid_request"
            || code == "invalid_request_error"
            || statusCode == 400
            || statusCode == 422
    }
}

/// Refuses HTTP redirects so OAuth tokens and asset content are never forwarded to another origin.
private final class NoRedirectSessionDelegate: NSObject, URLSessionTaskDelegate, Sendable {
    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping (URLRequest?) -> Void
    ) {
        completionHandler(nil)
    }
}

/// Ephemeral IPv4 loopback server (`http://127.0.0.1:<port>/auth/callback`) matching `@siwc/local` oauth.ts.
private actor ChatGPTLoopbackServer {
    private let expectedState: String
    private let savedClientID: String?
    private var boundPort: UInt16 = 0
    private var listener: NWListener?
    private var continuation: CheckedContinuation<(code: String, clientID: String), Error>?
    private var capturedResult: Result<(code: String, clientID: String), Error>?

    init(expectedState: String, savedClientID: String?) {
        self.expectedState = expectedState
        self.savedClientID = savedClientID
    }

    func start() async throws -> UInt16 {
        let params = NWParameters.tcp
        params.requiredLocalEndpoint = NWEndpoint.hostPort(host: .ipv4(.loopback), port: .any)
        let listener = try NWListener(using: params)
        self.listener = listener

        let port: UInt16 = try await withCheckedThrowingContinuation { cont in
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
                            cont.resume(throwing: ChatGPTAuthError(
                                code: "loopback_failed",
                                message: "无法绑定本机回调端口，请重试。",
                                retryable: true
                            ))
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
                        cont.resume(throwing: ChatGPTAuthError(
                            code: "cancelled",
                            message: "已取消 ChatGPT 登录。",
                            retryable: false
                        ))
                    }
                default:
                    break
                }
            }
            listener.newConnectionHandler = { [weak self] connection in
                Task { await self?.handle(connection: connection) }
            }
            listener.start(queue: DispatchQueue(label: "com.charkle.chatgpt.oauth.loopback"))
        }
        boundPort = port
        return port
    }

    func waitForCallback(timeoutSeconds: TimeInterval) async throws -> (code: String, clientID: String) {
        if let existing = capturedResult {
            return try existing.get()
        }
        let timeout = Task {
            do { try await Task.sleep(for: .seconds(timeoutSeconds)) } catch { return }
            finish(with: .failure(ChatGPTAuthError(code: "cancelled", message: "ChatGPT 登录已超时，请重试。", retryable: true)))
        }
        defer { timeout.cancel() }
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { cont in
                if let existing = capturedResult { cont.resume(with: existing) }
                else { self.continuation = cont }
            }
        } onCancel: {
            Task { await self.finish(with: .failure(ChatGPTAuthError(code: "cancelled", message: "已取消 ChatGPT 登录。", retryable: false))) }
        }
    }

    func stop() {
        listener?.cancel()
        listener = nil
        finish(with: .failure(ChatGPTAuthError(code: "cancelled", message: "已取消 ChatGPT 登录。", retryable: false)))
    }

    private func finish(with result: Result<(code: String, clientID: String), Error>) {
        guard capturedResult == nil else { return }
        capturedResult = result
        let pending = continuation
        continuation = nil
        pending?.resume(with: result)
    }

    private func handle(connection: NWConnection) {
        let expectedState = self.expectedState
        let savedClientID = self.savedClientID
        let expectedHost = "127.0.0.1:\(self.boundPort)"
        let alreadySettled = self.capturedResult != nil

        connection.start(queue: DispatchQueue(label: "com.charkle.chatgpt.oauth.connection"))
        Self.receiveHTTPHeaders(on: connection, accumulated: Data(), maxBytes: 16_384) { [weak self] data in
            guard let data, let raw = String(data: data, encoding: .utf8) else {
                connection.cancel()
                return
            }
            let lines = raw.components(separatedBy: "\r\n")
            guard let requestLine = lines.first else {
                connection.cancel()
                return
            }
            let parts = requestLine.split(separator: " ")
            let method = parts.first.map(String.init) ?? ""
            let target = parts.count >= 2 ? String(parts[1]) : "/"

            var hostHeader: String?
            for headerLine in lines.dropFirst() {
                if headerLine.isEmpty { break }
                if let colon = headerLine.firstIndex(of: ":") {
                    let name = headerLine[..<colon].trimmingCharacters(in: .whitespaces).lowercased()
                    if name == "host" {
                        hostHeader = headerLine[headerLine.index(after: colon)...].trimmingCharacters(in: .whitespaces)
                        break
                    }
                }
            }

            let urlComponents = URLComponents(string: "http://\(expectedHost)\(target)")
            guard method == "GET",
                  hostHeader == expectedHost,
                  urlComponents?.path == ChatGPTSignInClient.callbackPath,
                  !alreadySettled else {
                Self.sendPlain(connection: connection, status: "404 Not Found", body: "Not found")
                return
            }

            let queryItems = urlComponents?.queryItems ?? []
            let states = queryItems.filter { $0.name == "state" }.compactMap(\.value)
            guard states.count == 1, Self.constantTimeEqual(states[0], expectedState) else {
                // Unrelated loopback requests must not consume the pending browser transaction.
                Self.sendPlain(connection: connection, status: "400 Bad Request", body: "Invalid sign-in state.")
                return
            }

            if let errorItem = queryItems.first(where: { $0.name == "error" }) {
                let errCode = errorItem.value ?? "access_denied"
                let mapped = ChatGPTSignInClient.mapKnownError(code: errCode, statusCode: nil)
                Self.sendCompletionHTML(connection: connection, success: false)
                Task { await self?.finish(with: .failure(mapped)) }
                return
            }

            let codes = queryItems.filter { $0.name == "code" }.compactMap(\.value).filter { !$0.isEmpty }
            let returnedClientIDs = queryItems.filter { $0.name == "client_id" }.compactMap(\.value)
            let returnedClientID = returnedClientIDs.first
            let resolvedClientID = returnedClientID ?? savedClientID

            let validClientIDPattern = #"^[a-zA-Z0-9_-]{1,200}$"#
            let clientIDValid = resolvedClientID.map { cid in
                cid != "dynamic_agent_client"
                    && cid.range(of: validClientIDPattern, options: .regularExpression) != nil
                    && (savedClientID == nil || returnedClientID == nil || savedClientID == returnedClientID)
            } ?? false

            guard codes.count == 1, returnedClientIDs.count <= 1, clientIDValid, let finalClientID = resolvedClientID else {
                let err = ChatGPTAuthError(
                    code: "registration_incomplete",
                    message: "ChatGPT 未完成应用注册，请重新尝试登录。",
                    retryable: true
                )
                Self.sendCompletionHTML(connection: connection, success: false)
                Task { await self?.finish(with: .failure(err)) }
                return
            }

            Self.sendCompletionHTML(connection: connection, success: true)
            Task { await self?.finish(with: .success((codes[0], finalClientID))) }
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

    private static func constantTimeEqual(_ lhs: String, _ rhs: String) -> Bool {
        let a = Array(lhs.utf8)
        let b = Array(rhs.utf8)
        guard a.count == b.count else { return false }
        var diff: UInt8 = 0
        for i in 0..<a.count { diff |= a[i] ^ b[i] }
        return diff == 0
    }

    private static func sendPlain(connection: NWConnection, status: String, body: String) {
        let response = "HTTP/1.1 \(status)\r\nCache-Control: no-store\r\nReferrer-Policy: no-referrer\r\nContent-Type: text/plain; charset=utf-8\r\nContent-Length: \(body.utf8.count)\r\nConnection: close\r\n\r\n\(body)"
        connection.send(content: Data(response.utf8), completion: .contentProcessed { _ in connection.cancel() })
    }

    private static func sendCompletionHTML(connection: NWConnection, success: Bool) {
        let script = #"history.replaceState(null, "", "/auth/complete");"#
        let scriptHash = Data(SHA256.hash(data: Data(script.utf8))).base64EncodedString()
        let title = success ? "请返回 Charkle" : "未完成 ChatGPT 授权"
        let detail = success
            ? "Charkle 正在完成你的 ChatGPT 订阅账号校验，你可以关闭此标签页。"
            : "本次授权未完成或已取消，请返回 Charkle 重试。"
        let accent = success ? "#10A37F" : "#EF4444"
        let symbol = success ? "✓" : "!"
        let html = """
        <!doctype html><html lang="zh-CN"><head><meta charset="utf-8"><title>\(title)</title>
        <style>
        :root{color-scheme:light dark}
        body{margin:0;min-height:100vh;display:flex;align-items:center;justify-content:center;font-family:-apple-system,BlinkMacSystemFont,"SF Pro Text",sans-serif;background:#F6F6F5;color:#1D1D1F}
        @media(prefers-color-scheme:dark){body{background:#141517;color:#F5F5F7}.card{background:#1E2024;border-color:rgba(255,255,255,.1)}}
        .card{max-width:390px;padding:32px 28px;border-radius:18px;background:#fff;border:1px solid rgba(0,0,0,.08);box-shadow:0 16px 40px rgba(0,0,0,.08);text-align:center}
        .badge{width:46px;height:46px;margin:0 auto 16px;border-radius:50%;background:\(accent);color:#fff;font-size:22px;font-weight:700;display:flex;align-items:center;justify-content:center}
        h1{margin:0 0 8px;font-size:18px;font-weight:600}
        p{margin:0;font-size:13.5px;line-height:1.55;opacity:.75}
        </style></head><body><div class="card"><div class="badge">\(symbol)</div><h1>\(title)</h1><p>\(detail)</p></div><script>\(script)</script></body></html>
        """
        let csp = "default-src 'none'; script-src 'sha256-\(scriptHash)'; style-src 'unsafe-inline'; frame-ancestors 'none'; base-uri 'none'"
        let response = "HTTP/1.1 200 OK\r\nCache-Control: no-store\r\nReferrer-Policy: no-referrer\r\nContent-Security-Policy: \(csp)\r\nContent-Type: text/html; charset=utf-8\r\nContent-Length: \(html.utf8.count)\r\nConnection: close\r\n\r\n\(html)"
        connection.send(content: Data(response.utf8), completion: .contentProcessed { _ in connection.cancel() })
    }
}
