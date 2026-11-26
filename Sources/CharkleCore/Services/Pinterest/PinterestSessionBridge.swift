import Foundation
#if canImport(UIKit)
import UIKit
#endif
import WebKit

public enum PinterestSessionError: LocalizedError, Sendable {
    case notAuthenticated
    case sessionExpired
    case invalidResponse(String)
    case networkFailure(String)

    public var errorDescription: String? {
        switch self {
        case .notAuthenticated:
            return "请先登录你的 Pinterest 账号，再浏览个人推荐与相似灵感。"
        case .sessionExpired:
            return "Pinterest 登录状态已过期或需要重新验证，请在登录窗口中完成验证。"
        case .invalidResponse(let detail):
            return "未能解析 Pinterest 返回数据：\(detail)"
        case .networkFailure(let detail):
            return "连接 Pinterest 失败：\(detail)"
        }
    }
}

/// Cross-platform (macOS + iOS) WebKit-backed Pinterest session bridge.
///
/// Uses Apple's persistent `WKWebsiteDataStore.default()` so user login (Email, Google, Apple, 2FA,
/// or any human verification completed directly by the user inside the visible login WebView) persists
/// cleanly across launches, and executes same-origin `fetch()` calls inside the authenticated
/// `https://www.pinterest.com/` context to power Home Feed, Search, Boards, Pin Detail, and Similar Pins.
@MainActor
public final class PinterestSessionBridge: NSObject, WKNavigationDelegate {
    public static let shared = PinterestSessionBridge()

    private let dataStore: WKWebsiteDataStore = .default()
    private var backgroundWebView: WKWebView?
    private var isHomeContextReady: Bool = false
    private var pendingReadyContinuations: [CheckedContinuation<Void, Error>] = []

    private static let homeURL = URL(string: "https://www.pinterest.com/")!
    public static let loginURL = URL(string: "https://www.pinterest.com/login/")!

    override private init() {
        super.init()
    }

    /// Creates a `WKWebViewConfiguration` sharing the exact persistent cookie & session store,
    /// configured with Safari-compatible User-Agent and JavaScript popup support so Google / Apple
    /// OAuth popups preserve `window.opener.postMessage()` and close cleanly after sign-in.
    public func makeLoginWebViewConfiguration() -> WKWebViewConfiguration {
        let config = WKWebViewConfiguration()
        config.websiteDataStore = dataStore
        config.defaultWebpagePreferences.allowsContentJavaScript = true
        config.preferences.javaScriptCanOpenWindowsAutomatically = true
        #if os(iOS)
        config.allowsInlineMediaPlayback = true
        config.applicationNameForUserAgent = "Version/18.0 Mobile/15E148 Safari/604.1"
        #else
        config.applicationNameForUserAgent = "Version/18.0 Safari/605.1.15"
        #endif
        return config
    }

    private func makeBackgroundBridgeConfiguration() -> WKWebViewConfiguration {
        let config = makeLoginWebViewConfiguration()
        config.defaultWebpagePreferences.preferredContentMode = .desktop
        #if os(iOS)
        config.applicationNameForUserAgent = "Version/18.0 Safari/605.1.15"
        #endif
        return config
    }

    /// Checks whether the persistent WebKit cookie store currently contains an authenticated Pinterest session.
    public func hasSessionCookies() async -> Bool {
        let cookies = await allPinterestCookies()
        let hasAuthFlag = cookies.contains { $0.name == "_auth" && $0.value == "1" }
        let hasSess = cookies.contains { $0.name == "_pinterest_sess" && !$0.value.isEmpty }
        return hasAuthFlag || hasSess
    }

    /// Verifies the current session and returns the signed-in Pinterest account (or `nil` if logged out).
    public func checkSessionAccount() async -> PinterestAccount? {
        guard await hasSessionCookies() else { return nil }
        do {
            try await ensureHomeContextReady()

            // 1. Primary: UserSettingsResource returns the active signed-in viewer without requiring a username parameter.
            if let settingsData = try? await fetchResource(
                path: "/resource/UserSettingsResource/get/",
                sourceURL: "/settings/",
                options: [:]
            ), let account = PinterestJSONParser.parseAccount(from: settingsData) {
                return account
            }

            // 2. Live DOM inspection (__PWS_INITIAL_PROPS__, __PWS_DATA__, Relay payloads).
            if let account = await extractAccountFromLivePage() {
                return account
            }

            // 3. Fallback: UserResource/get/
            if let userData = try? await fetchResource(
                path: "/resource/UserResource/get/",
                sourceURL: "/",
                options: [:]
            ), let account = PinterestJSONParser.parseAccount(from: userData) {
                return account
            }

            // 4. Final verification: if authenticated cookies allow fetching personalized Home Feed pins,
            //    accept the signed-in session gracefully even if Pinterest rotates viewer profile payloads.
            let cookies = await allPinterestCookies()
            let hasExplicitAuth = cookies.contains { $0.name == "_auth" && $0.value == "1" }
            if hasExplicitAuth {
                if let feedPage = try? await fetchFeed(source: .homeFeed, bookmark: nil, pageSize: 8),
                   !feedPage.pins.isEmpty {
                    return PinterestAccount(username: "", fullName: "Pinterest 账号")
                }
            }
            return nil
        } catch {
            return nil
        }
    }

    /// Signs out of Pinterest by clearing Pinterest cookies and website data cleanly.
    public func signOut() async {
        let cookies = await allPinterestCookies()
        for cookie in cookies {
            await dataStore.httpCookieStore.deleteCookie(cookie)
        }
        let records = await dataStore.dataRecords(ofTypes: WKWebsiteDataStore.allWebsiteDataTypes())
        let pinterestRecords = records.filter { $0.displayName.lowercased().contains("pinterest") }
        if !pinterestRecords.isEmpty {
            await dataStore.removeData(ofTypes: WKWebsiteDataStore.allWebsiteDataTypes(), for: pinterestRecords)
        }
        backgroundWebView?.stopLoading()
        backgroundWebView?.navigationDelegate = nil
        #if canImport(UIKit)
        backgroundWebView?.removeFromSuperview()
        #endif
        backgroundWebView = nil
        isHomeContextReady = false
    }

    /// Resets the warm background context so freshly completed login cookies take effect immediately.
    public func resetWarmContext() {
        backgroundWebView?.stopLoading()
        backgroundWebView?.navigationDelegate = nil
        #if canImport(UIKit)
        backgroundWebView?.removeFromSuperview()
        #endif
        backgroundWebView = nil
        isHomeContextReady = false
    }

    // MARK: - Feeds, Search, Boards, Pin Detail & Similar Pins

    public func fetchFeed(
        source: PinterestFeedSource,
        bookmark: String? = nil,
        pageSize: Int = 30
    ) async throws -> PinterestFeedPage {
        try await ensureHomeContextReady()

        switch source {
        case .homeFeed:
            var options: [String: Any] = [
                "isPrefetch": false,
                "field_set_key": "hf_grid_partner",
                "in_nux": false,
                "prependPartner": false,
                "prependUserNews": false,
                "static_feed": false,
                "page_size": pageSize
            ]
            if let bookmark, !bookmark.isEmpty {
                options["bookmarks"] = [bookmark]
            }
            let data = try await fetchResource(
                path: "/resource/UserHomefeedResource/get/",
                sourceURL: "/",
                options: options
            )
            let page = PinterestJSONParser.parseFeedPage(from: data)
            if !page.pins.isEmpty { return page }

            // Retry once with standard field_set_key in case Pinterest rotates partner keys.
            var fallbackOptions: [String: Any] = ["page_size": pageSize]
            if let bookmark, !bookmark.isEmpty { fallbackOptions["bookmarks"] = [bookmark] }
            let fallbackData = try await fetchResource(
                path: "/resource/UserHomefeedResource/get/",
                sourceURL: "/",
                options: fallbackOptions
            )
            return PinterestJSONParser.parseFeedPage(from: fallbackData)

        case .search(let rawQuery):
            let query = rawQuery.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !query.isEmpty else { return PinterestFeedPage(pins: [], bookmark: nil, hasMore: false) }
            var options: [String: Any] = [
                "query": query,
                "scope": "pins",
                "rs": "typed",
                "auto_correction_disabled": false,
                "redux_normalize_feed": true,
                "page_size": pageSize
            ]
            if let bookmark, !bookmark.isEmpty {
                options["bookmarks"] = [bookmark]
            }
            let encodedQ = query.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? query
            let data = try await fetchResource(
                path: "/resource/BaseSearchResource/get/",
                sourceURL: "/search/pins/?q=\(encodedQ)",
                options: options
            )
            return PinterestJSONParser.parseFeedPage(from: data)

        case .board(let board):
            var options: [String: Any] = [
                "board_id": board.id,
                "board_url": board.urlPath,
                "currentFilter": -1,
                "field_set_key": "react_grid_pin",
                "filter_section_pins": true,
                "sort": "default",
                "layout": "default",
                "page_size": pageSize,
                "redux_normalize_feed": true
            ]
            if let bookmark, !bookmark.isEmpty {
                options["bookmarks"] = [bookmark]
            }
            let data = try await fetchResource(
                path: "/resource/BoardFeedResource/get/",
                sourceURL: board.urlPath,
                options: options
            )
            return PinterestJSONParser.parseFeedPage(from: data)

        case .similar(let anchorPin):
            return try await fetchSimilarPins(for: anchorPin, bookmark: bookmark, pageSize: pageSize)
        }
    }

    public func fetchUserBoards(username: String) async throws -> [PinterestBoard] {
        try await ensureHomeContextReady()
        var allBoards: [PinterestBoard] = []
        var seenIDs = Set<String>()
        var bookmark: String? = nil

        for _ in 0..<16 {
            if Task.isCancelled { break }
            var options: [String: Any] = [
                "isPrefetch": false,
                "privacy_filter": "all",
                "sort": "last_pinned_to",
                "field_set_key": "profile_grid_item",
                "username": username,
                "page_size": 50,
                "group_by": "visibility",
                "include_archived": false,
                "redux_normalize_feed": true
            ]
            if let bookmark, !bookmark.isEmpty {
                options["bookmarks"] = [bookmark]
            }
            let data = try await fetchResource(
                path: "/resource/BoardsResource/get/",
                sourceURL: "/\(username)/",
                options: options
            )
            let page = PinterestJSONParser.parseBoardsPage(from: data)
            let fresh = page.boards.filter { seenIDs.insert($0.id).inserted }
            allBoards.append(contentsOf: fresh)
            guard let next = page.bookmark, !next.isEmpty, !fresh.isEmpty else {
                break
            }
            bookmark = next
        }
        return allBoards
    }

    /// Paginates through every Pin saved inside a Pinterest Board (including sectioned pins)
    /// for batch collection import into board-organized Charkle folders.
    public func fetchAllPins(
        in board: PinterestBoard,
        maxPins: Int = 2000,
        onPageFetched: (@Sendable (Int) -> Void)? = nil
    ) async throws -> [PinterestPin] {
        try await ensureHomeContextReady()
        var collected: [PinterestPin] = []
        var seenIDs = Set<String>()
        var bookmark: String? = nil

        let maxPages = max(1, (maxPins / 50) + 4)
        for _ in 0..<maxPages {
            if Task.isCancelled || collected.count >= maxPins { break }
            var options: [String: Any] = [
                "board_id": board.id,
                "board_url": board.urlPath,
                "currentFilter": -1,
                "field_set_key": "react_grid_pin",
                "filter_section_pins": false,
                "sort": "default",
                "layout": "default",
                "page_size": 50,
                "redux_normalize_feed": true
            ]
            if let bookmark, !bookmark.isEmpty {
                options["bookmarks"] = [bookmark]
            }
            let data = try await fetchResource(
                path: "/resource/BoardFeedResource/get/",
                sourceURL: board.urlPath,
                options: options
            )
            let page = PinterestJSONParser.parseFeedPage(from: data)
            var freshCount = 0
            for pin in page.pins {
                guard seenIDs.insert(pin.id).inserted else { continue }
                // Guarantee board metadata is populated even if BoardFeedResource omits nested board dict.
                let enriched = pin.boardName == nil
                    ? PinterestPin(
                        id: pin.id,
                        title: pin.title,
                        descriptionText: pin.descriptionText,
                        dominantColorHex: pin.dominantColorHex,
                        width: pin.width,
                        height: pin.height,
                        thumbnailURL: pin.thumbnailURL,
                        previewURL: pin.previewURL,
                        originalURL: pin.originalURL,
                        videoURL: pin.videoURL,
                        pinPageURL: pin.pinPageURL,
                        externalLinkURL: pin.externalLinkURL,
                        domain: pin.domain,
                        pinnerName: pin.pinnerName,
                        pinnerUsername: pin.pinnerUsername,
                        pinnerAvatarURL: pin.pinnerAvatarURL,
                        boardName: board.name,
                        boardID: board.id,
                        saveCount: pin.saveCount
                    )
                    : pin
                collected.append(enriched)
                freshCount += 1
                if collected.count >= maxPins { break }
            }
            onPageFetched?(collected.count)
            guard page.hasMore, let next = page.bookmark, !next.isEmpty, freshCount > 0 else {
                break
            }
            bookmark = next
        }
        return collected
    }

    /// Fetches rich Pin details AND Pinterest's native "More like this" similar pins concurrently.
    public func fetchPinDetailAndSimilar(for pin: PinterestPin) async throws -> PinterestPinDetailResult {
        try await ensureHomeContextReady()
        async let detailedPinTask = fetchPinDetail(pinID: pin.id)
        async let similarPageTask = fetchSimilarPins(for: pin, bookmark: nil, pageSize: 28)

        let detailed = (try? await detailedPinTask) ?? pin
        let merged = pin.merged(with: detailed)
        let similarPage = (try? await similarPageTask) ?? PinterestFeedPage(pins: [], bookmark: nil, hasMore: false)
        let filteredSimilar = similarPage.pins.filter { $0.id != pin.id }
        return PinterestPinDetailResult(
            pin: merged,
            similarPins: filteredSimilar,
            similarBookmark: similarPage.bookmark
        )
    }

    public func fetchPinDetail(pinID: String) async throws -> PinterestPin? {
        try await ensureHomeContextReady()
        let options: [String: Any] = [
            "id": pinID,
            "field_set_key": "detailed"
        ]
        let data = try await fetchResource(
            path: "/resource/PinResource/get/",
            sourceURL: "/pin/\(pinID)/",
            options: options
        )
        return PinterestJSONParser.parseSinglePin(from: data)
    }

    public func fetchSimilarPins(
        for pin: PinterestPin,
        bookmark: String? = nil,
        pageSize: Int = 28
    ) async throws -> PinterestFeedPage {
        try await ensureHomeContextReady()

        // 1. Primary: Pinterest RelatedModulesResource (native "More like this" visual similarity)
        var relatedOptions: [String: Any] = [
            "pin_id": pin.id,
            "context_pin_ids": [],
            "page_size": pageSize,
            "search_query": "",
            "source": "deep_link",
            "top_level_source": "deep_link",
            "top_level_source_depth": 1,
            "is_pdp": false
        ]
        if let bookmark, !bookmark.isEmpty {
            relatedOptions["bookmarks"] = [bookmark]
        }
        if let data = try? await fetchResource(
            path: "/resource/RelatedModulesResource/get/",
            sourceURL: "/pin/\(pin.id)/",
            options: relatedOptions
        ) {
            let page = PinterestJSONParser.parseFeedPage(from: data)
            if !page.pins.isEmpty {
                return PinterestFeedPage(
                    pins: page.pins.filter { $0.id != pin.id },
                    bookmark: page.bookmark,
                    hasMore: page.hasMore
                )
            }
        }

        // 2. Secondary: RelatedPinFeedResource
        var feedOptions: [String: Any] = [
            "pin": pin.id,
            "field_set_key": "grid_item",
            "prepend": false,
            "page_size": pageSize
        ]
        if let bookmark, !bookmark.isEmpty {
            feedOptions["bookmarks"] = [bookmark]
        }
        if let data = try? await fetchResource(
            path: "/resource/RelatedPinFeedResource/get/",
            sourceURL: "/pin/\(pin.id)/",
            options: feedOptions
        ) {
            let page = PinterestJSONParser.parseFeedPage(from: data)
            if !page.pins.isEmpty {
                return PinterestFeedPage(
                    pins: page.pins.filter { $0.id != pin.id },
                    bookmark: page.bookmark,
                    hasMore: page.hasMore
                )
            }
        }

        // 3. Fallback: keyword search seeded by pin title/board so the detail sheet always offers discovery
        let fallbackKeyword = pin.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? (pin.boardName ?? "")
            : pin.title
        if !fallbackKeyword.isEmpty, bookmark == nil {
            let page = try await fetchFeed(source: .search(String(fallbackKeyword.prefix(48))), bookmark: nil, pageSize: pageSize)
            return PinterestFeedPage(
                pins: page.pins.filter { $0.id != pin.id },
                bookmark: page.bookmark,
                hasMore: page.hasMore
            )
        }
        return PinterestFeedPage(pins: [], bookmark: nil, hasMore: false)
    }

    // MARK: - Same-Origin WebKit Transport

    private func ensureHomeContextReady() async throws {
        if let webView = backgroundWebView,
           isHomeContextReady,
           let host = webView.url?.host()?.lowercased(),
           host.contains("pinterest.") {
            return
        }

        let webView: WKWebView
        if let existing = backgroundWebView {
            webView = existing
        } else {
            let config = makeBackgroundBridgeConfiguration()
            let created = WKWebView(frame: CGRect(x: 0, y: 0, width: 1280, height: 800), configuration: config)
            created.navigationDelegate = self
            #if canImport(UIKit)
            attachWarmWebViewToActiveWindowIfAvailable(created)
            #endif
            backgroundWebView = created
            webView = created
        }

        isHomeContextReady = false
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            pendingReadyContinuations.append(continuation)
            if pendingReadyContinuations.count == 1 {
                webView.load(URLRequest(url: Self.homeURL, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 20))
                Task { @MainActor [weak self] in
                    try? await Task.sleep(for: .seconds(18))
                    guard let self, !self.isHomeContextReady, !self.pendingReadyContinuations.isEmpty else { return }
                    let waiting = self.pendingReadyContinuations
                    self.pendingReadyContinuations.removeAll()
                    for cont in waiting {
                        cont.resume(throwing: PinterestSessionError.networkFailure("加载 Pinterest 会话超时，请检查网络连接。"))
                    }
                }
            }
        }
    }

    private func fetchResource(
        path: String,
        sourceURL: String,
        options: [String: Any]
    ) async throws -> Data {
        guard let webView = backgroundWebView else {
            throw PinterestSessionError.notAuthenticated
        }

        let payloadObject: [String: Any] = [
            "options": options,
            "context": [String: Any]()
        ]
        let payloadData = try JSONSerialization.data(withJSONObject: payloadObject)
        let payloadJSON = String(decoding: payloadData, as: UTF8.self)

        var comps = URLComponents()
        comps.path = path
        comps.queryItems = [
            URLQueryItem(name: "source_url", value: sourceURL),
            URLQueryItem(name: "data", value: payloadJSON),
            URLQueryItem(name: "_", value: String(Int64(Date().timeIntervalSince1970 * 1000)))
        ]
        guard let relativeURL = comps.string else {
            throw PinterestSessionError.invalidResponse("无法构造资源请求路径")
        }

        let script = """
        const csrfMatch = document.cookie.match(/(?:^|;\\s*)csrftoken=([^;]+)/);
        const headers = {
          'Accept': 'application/json, text/javascript, */*, q=0.01',
          'X-Requested-With': 'XMLHttpRequest',
          'X-Pinterest-AppState': 'active',
          'X-Pinterest-Source-Url': sourceUrl,
          'X-Pinterest-PWS-Handler': 'www/index.js'
        };
        if (csrfMatch && csrfMatch[1]) {
          headers['X-CSRFToken'] = decodeURIComponent(csrfMatch[1]);
        }
        const res = await fetch(endpoint, {
          method: 'GET',
          credentials: 'include',
          headers
        });
        const text = await res.text();
        return { status: res.status, body: text };
        """

        let rawResult: Any?
        do {
            rawResult = try await webView.callAsyncJavaScript(
                script,
                arguments: [
                    "endpoint": relativeURL,
                    "sourceUrl": sourceURL
                ],
                in: nil,
                contentWorld: .page
            )
        } catch {
            throw PinterestSessionError.networkFailure(error.localizedDescription)
        }

        guard let dict = rawResult as? [String: Any],
              let status = dict["status"] as? Int,
              let body = dict["body"] as? String else {
            throw PinterestSessionError.invalidResponse("空响应")
        }

        if status == 401 || status == 403 {
            throw PinterestSessionError.sessionExpired
        }
        guard (200..<300).contains(status) else {
            throw PinterestSessionError.networkFailure("HTTP \(status)")
        }
        return Data(body.utf8)
    }

    private func extractAccountFromLivePage() async -> PinterestAccount? {
        guard let webView = backgroundWebView else { return nil }
        let script = """
        try {
          const candidates = [
            document.getElementById('__PWS_INITIAL_PROPS__')?.textContent,
            document.getElementById('__PWS_DATA__')?.textContent
          ].filter(Boolean);
          for (const raw of candidates) {
            const parsed = JSON.parse(raw);
            const u = parsed?.initialReduxState?.viewer
              || parsed?.context?.user
              || parsed?.props?.context?.user;
            if (u && u.username && u.is_authenticated !== false) {
              return {
                username: String(u.username),
                full_name: String(u.full_name || u.first_name || u.username),
                image_medium_url: u.image_medium_url || u.image_small_url || null
              };
            }
          }
          const relayScripts = document.querySelectorAll('script[data-relay-response="true"]');
          for (const el of relayScripts) {
            if (!el.textContent || !el.textContent.includes('username')) continue;
            const obj = JSON.parse(el.textContent);
            const viewer = obj?.response?.data?.v3GetUserAccountQuery?.viewer
              || obj?.response?.data?.viewer;
            if (viewer && viewer.username) {
              return {
                username: String(viewer.username),
                full_name: String(viewer.fullName || viewer.full_name || viewer.username),
                image_medium_url: viewer.imageMediumUrl || viewer.image_medium_url || null
              };
            }
          }
        } catch (e) {}
        return null;
        """
        guard let raw = try? await webView.callAsyncJavaScript(script, arguments: [:], in: nil, contentWorld: .page),
              let dict = raw as? [String: Any],
              let data = try? JSONSerialization.data(withJSONObject: dict) else {
            return nil
        }
        return PinterestJSONParser.parseAccount(from: data)
    }

    #if canImport(UIKit)
    private func attachWarmWebViewToActiveWindowIfAvailable(_ webView: WKWebView) {
        let activeWindow = UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .flatMap(\.windows)
            .first(where: \.isKeyWindow)
            ?? UIApplication.shared.connectedScenes
                .compactMap { $0 as? UIWindowScene }
                .flatMap(\.windows)
                .first
        guard let activeWindow else { return }
        webView.frame = CGRect(x: 0, y: 0, width: 1, height: 1)
        webView.alpha = 0.01
        webView.isUserInteractionEnabled = false
        webView.accessibilityElementsHidden = true
        activeWindow.insertSubview(webView, at: 0)
    }
    #endif

    private func allPinterestCookies() async -> [HTTPCookie] {
        let all = await dataStore.httpCookieStore.allCookies()
        return all.filter { $0.domain.lowercased().contains("pinterest") }
    }

    // MARK: - WKNavigationDelegate

    public func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        guard webView === backgroundWebView else { return }
        isHomeContextReady = true
        let waiting = pendingReadyContinuations
        pendingReadyContinuations.removeAll()
        for cont in waiting {
            cont.resume()
        }
    }

    public func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        guard webView === backgroundWebView else { return }
        let nsError = error as NSError
        if nsError.domain == NSURLErrorDomain && nsError.code == NSURLErrorCancelled { return }
        let waiting = pendingReadyContinuations
        pendingReadyContinuations.removeAll()
        for cont in waiting {
            cont.resume(throwing: PinterestSessionError.networkFailure(error.localizedDescription))
        }
    }

    public func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        guard webView === backgroundWebView else { return }
        let nsError = error as NSError
        if nsError.domain == NSURLErrorDomain && nsError.code == NSURLErrorCancelled { return }
        let waiting = pendingReadyContinuations
        pendingReadyContinuations.removeAll()
        for cont in waiting {
            cont.resume(throwing: PinterestSessionError.networkFailure(error.localizedDescription))
        }
    }
}
