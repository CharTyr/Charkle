import Foundation

/// Parsed identity of a Xiaohongshu (小红书) note or short share link.
public nonisolated struct XiaohongshuNoteReference: Equatable, Hashable, Sendable {
    public let noteID: String?
    public let xsecToken: String?
    public let xsecSource: String?
    public let sourceURL: URL
    public let isShortLink: Bool

    public var canonicalURL: URL {
        if let noteID, !noteID.isEmpty {
            var comps = URLComponents(string: "https://www.xiaohongshu.com/explore/\(noteID)")
            var query: [URLQueryItem] = []
            if let xsecToken, !xsecToken.isEmpty {
                query.append(URLQueryItem(name: "xsec_token", value: xsecToken))
            }
            if let xsecSource, !xsecSource.isEmpty {
                query.append(URLQueryItem(name: "xsec_source", value: xsecSource))
            }
            if !query.isEmpty {
                comps?.queryItems = query
            }
            if let built = comps?.url {
                return built
            }
        }
        return sourceURL
    }

    /// Stable deduplication key independent of rotating `xsec_token` parameters.
    public var dedupKey: String {
        if let noteID, !noteID.isEmpty {
            return "xhs:\(noteID.lowercased())"
        }
        return "url:\(sourceURL.absoluteString)"
    }

    public init(
        noteID: String?,
        xsecToken: String? = nil,
        xsecSource: String? = nil,
        sourceURL: URL,
        isShortLink: Bool = false
    ) {
        self.noteID = noteID
        self.xsecToken = xsecToken
        self.xsecSource = xsecSource
        self.sourceURL = sourceURL
        self.isShortLink = isShortLink
    }
}

/// Detects and extracts Xiaohongshu note URLs and mobile app short links (`xhslink.com`).
public nonisolated enum XiaohongshuURLParser {
    private static let noteHosts: Set<String> = [
        "xiaohongshu.com",
        "www.xiaohongshu.com",
        "m.xiaohongshu.com"
    ]

    private static let shortHosts: Set<String> = [
        "xhslink.com",
        "www.xhslink.com"
    ]

    public static func parse(_ url: URL) -> XiaohongshuNoteReference? {
        guard let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https",
              let host = url.host()?.lowercased() else {
            return nil
        }

        let segments = url.pathComponents.filter { $0 != "/" && !$0.isEmpty }

        if shortHosts.contains(host) {
            guard !segments.isEmpty else { return nil }
            return XiaohongshuNoteReference(
                noteID: nil,
                sourceURL: url,
                isShortLink: true
            )
        }

        guard noteHosts.contains(host) else { return nil }

        let comps = URLComponents(url: url, resolvingAgainstBaseURL: false)
        let xsecToken = comps?.queryItems?.first(where: { $0.name == "xsec_token" })?.value?.trimmingCharacters(in: .whitespacesAndNewlines)
        let xsecSource = comps?.queryItems?.first(where: { $0.name == "xsec_source" })?.value?.trimmingCharacters(in: .whitespacesAndNewlines)

        // Supported paths:
        // /explore/<noteId>
        // /discovery/item/<noteId>
        // /user/profile/<userId>/<noteId>
        var noteID: String?
        if segments.count >= 2, segments[0].lowercased() == "explore", isValidNoteID(segments[1]) {
            noteID = segments[1]
        } else if segments.count >= 3,
                  segments[0].lowercased() == "discovery",
                  segments[1].lowercased() == "item",
                  isValidNoteID(segments[2]) {
            noteID = segments[2]
        } else if segments.count >= 4,
                  segments[0].lowercased() == "user",
                  segments[1].lowercased() == "profile",
                  isValidNoteID(segments[3]) {
            noteID = segments[3]
        }

        guard let noteID else { return nil }
        return XiaohongshuNoteReference(
            noteID: noteID,
            xsecToken: (xsecToken?.isEmpty == false) ? xsecToken : nil,
            xsecSource: (xsecSource?.isEmpty == false) ? xsecSource : nil,
            sourceURL: url,
            isShortLink: false
        )
    }

    /// Extracts a Xiaohongshu URL from raw pasted text or mobile share copy
    /// (e.g. `"67 某某发布了一篇小红书笔记... http://xhslink.com/a/xxxx 复制本条信息..."`).
    public static func extractNoteURL(from text: String) -> URL? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if let direct = URL(string: trimmed), parse(direct) != nil {
            return direct
        }
        guard let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue) else {
            return nil
        }
        let range = NSRange(trimmed.startIndex..., in: trimmed)
        for match in detector.matches(in: trimmed, options: [], range: range) {
            if let url = match.url, parse(url) != nil {
                return url
            }
        }
        return nil
    }

    public static func isValidNoteID(_ candidate: String) -> Bool {
        guard candidate.count >= 16, candidate.count <= 40 else { return false }
        return candidate.allSatisfy { $0.isASCII && ($0.isHexDigit || $0.isLetter || $0.isNumber) }
    }

    public static func isXiaohongshuMediaHost(_ host: String?) -> Bool {
        guard let h = host?.lowercased() else { return false }
        return h == "xhscdn.com" || h.hasSuffix(".xhscdn.com")
            || h == "xiaohongshu.com" || h.hasSuffix(".xiaohongshu.com")
    }
}

/// Resolves Xiaohongshu note metadata, full carousel image list, video stream, tags, and author info
/// from `window.__INITIAL_STATE__` (with resilient OpenGraph multi-image fallback).
public nonisolated enum XiaohongshuPostResolver {
    private static let desktopSafariUA =
        "Mozilla/5.0 (Macintosh; Intel Mac OS X 15_0) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.2 Safari/605.1.15"

    private static let blockedTitles: [String] = [
        "页面不见了",
        "你访问的页面不见了",
        "安全验证",
        "安全限制",
        "登录 - 小红书",
        "小红书 - 你的生活兴趣社区",
        "小红书 - 你的生活指南"
    ]

    public static func resolve(_ ref: XiaohongshuNoteReference) async -> ResolvedSocialPost? {
        var workingRef = ref
        var alreadyFetched: Set<String> = []
        if ref.isShortLink {
            if let (shortHTML, finalURL) = await fetchHTML(ref.sourceURL) {
                alreadyFetched.insert(ref.sourceURL.absoluteString)
                alreadyFetched.insert(finalURL.absoluteString)
                let effectiveRef = XiaohongshuURLParser.parse(finalURL) ?? workingRef
                workingRef = effectiveRef
                if let fromState = parseInitialState(html: shortHTML, ref: effectiveRef) {
                    return fromState
                }
                if let fromMeta = parseMetaFallback(html: shortHTML, ref: effectiveRef) {
                    return fromMeta
                }
            }
        }

        let candidateURLs = buildCandidateFetchURLs(for: workingRef)
        for fetchURL in candidateURLs where !alreadyFetched.contains(fetchURL.absoluteString) {
            guard let (html, finalURL) = await fetchHTML(fetchURL) else { continue }
            let effectiveRef = XiaohongshuURLParser.parse(finalURL) ?? workingRef
            if let fromState = parseInitialState(html: html, ref: effectiveRef) {
                return fromState
            }
            if let fromMeta = parseMetaFallback(html: html, ref: effectiveRef) {
                return fromMeta
            }
        }
        return nil
    }

    // MARK: - Initial State Parser (Pure & Unit-Testable)

    public static func parseInitialState(html: String, ref: XiaohongshuNoteReference) -> ResolvedSocialPost? {
        guard let jsonString = extractInitialStateJSON(from: html) else { return nil }
        let sanitized = sanitizeJSUndefined(in: jsonString)
        guard let data = sanitized.data(using: .utf8),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }

        guard let noteObj = locateNoteDictionary(in: root, expectedID: ref.noteID) else {
            return nil
        }

        let noteID = stringValue(noteObj["noteId"] ?? noteObj["id"]) ?? ref.noteID
        let rawTitle = stringValue(noteObj["title"]) ?? ""
        let rawDesc = cleanXiaohongshuBody(stringValue(noteObj["desc"]) ?? "")

        let userObj = noteObj["user"] as? [String: Any] ?? [:]
        let authorName = stringValue(userObj["nickname"] ?? userObj["nickName"]) ?? "小红书用户"
        let authorHandle = stringValue(userObj["redId"] ?? userObj["userId"] ?? userObj["id"]) ?? "xiaohongshu"
        let authorAvatar = upgradedHTTPSURL(stringValue(userObj["avatar"]))

        let publishedAtText = formatTimestamp(noteObj["time"] ?? noteObj["lastUpdateTime"])

        let interact = noteObj["interactInfo"] as? [String: Any] ?? [:]
        let likeCount = parseChineseMetricCount(interact["likedCount"])
        let commentCount = parseChineseMetricCount(interact["commentCount"])
        let shareCount = parseChineseMetricCount(interact["shareCount"] ?? interact["collectedCount"])

        var attachments: [SocialMediaAttachment] = []
        var seenURLs = Set<String>()

        // Video stream (if video note)
        let isVideoNote = (stringValue(noteObj["type"])?.lowercased() == "video")
        var videoURL: String?
        if let videoObj = noteObj["video"] as? [String: Any] {
            videoURL = extractVideoStreamURL(from: videoObj)
        }

        // Image list (for photo carousels and video cover poster)
        var coverPhotoURL: String?
        if let imageList = noteObj["imageList"] as? [[String: Any]] {
            for item in imageList {
                guard let photoURL = extractBestImageURL(from: item) else { continue }
                if coverPhotoURL == nil { coverPhotoURL = photoURL }
                if !isVideoNote, seenURLs.insert(photoURL).inserted {
                    let preview = extractPreviewImageURL(from: item) ?? photoURL
                    attachments.append(SocialMediaAttachment(kind: .photo, url: photoURL, thumbnailURL: preview))
                }
            }
        }

        if let videoURL, seenURLs.insert(videoURL).inserted {
            attachments.insert(
                SocialMediaAttachment(kind: .video, url: videoURL, thumbnailURL: coverPhotoURL),
                at: 0
            )
        } else if isVideoNote, let coverPhotoURL, attachments.isEmpty {
            attachments.append(SocialMediaAttachment(kind: .photo, url: coverPhotoURL, thumbnailURL: coverPhotoURL))
        }

        // Reject empty shells from unauthenticated redirects
        let hasSubstance = !rawTitle.isEmpty || !rawDesc.isEmpty || !attachments.isEmpty
        guard hasSubstance else { return nil }

        let finalRef = XiaohongshuNoteReference(
            noteID: noteID ?? ref.noteID,
            xsecToken: ref.xsecToken,
            xsecSource: ref.xsecSource,
            sourceURL: ref.sourceURL,
            isShortLink: false
        )

        let mediaURLs = attachments.map(\.url)
        let thumbURLs = attachments.compactMap { $0.thumbnailURL ?? ($0.kind == .photo ? $0.url : nil) }
        let primaryAttachment = attachments.first
        let primaryKind: XPostMedia.Kind? = primaryAttachment.map {
            switch $0.kind {
            case .photo: .photo
            case .video: .video
            case .gif: .gif
            }
        }

        let meta = SocialPostMetadata(
            platform: .xiaohongshu,
            authorName: authorName,
            authorHandle: authorHandle,
            authorAvatarURL: authorAvatar,
            publishedAtText: publishedAtText,
            bodyText: rawDesc.isEmpty ? rawTitle : rawDesc,
            articleTitle: rawTitle.isEmpty ? nil : rawTitle,
            mediaURLs: mediaURLs,
            mediaThumbnailURLs: thumbURLs,
            attachments: attachments,
            hasVideo: videoURL != nil || isVideoNote,
            videoURL: videoURL,
            replyCount: commentCount,
            repostCount: shareCount,
            likeCount: likeCount,
            originalURL: finalRef.canonicalURL.absoluteString,
            mediaFetchFailed: false
        )

        return ResolvedSocialPost(
            metadata: meta,
            primaryMediaDownloadURL: primaryAttachment.flatMap { URL(string: $0.url) },
            primaryMediaKind: primaryKind,
            primaryThumbnailURL: (primaryAttachment?.thumbnailURL ?? coverPhotoURL).flatMap(URL.init(string:))
        )
    }

    public static func parseMetaFallback(html: String, ref: XiaohongshuNoteReference) -> ResolvedSocialPost? {
        let ogTitle = extractMetaValues("og:title", in: html).first
            ?? extractHTMLTitle(in: html)
        let ogDesc = extractMetaValues("og:description", in: html).first
            ?? extractMetaValues("description", in: html).first
            ?? ""
        let ogImages = extractMetaValues("og:image", in: html)
            .compactMap(upgradedHTTPSURL)
            .filter { !isPlaceholderAsset($0) }
        let ogVideo = extractMetaValues("og:videourl", in: html).first
            .flatMap(upgradedHTTPSURL)

        let cleanedTitle = cleanPageTitle(ogTitle ?? "")
        if cleanedTitle.isEmpty && ogDesc.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && ogImages.isEmpty {
            return nil
        }
        if ogImages.isEmpty && ogVideo == nil && isBlockedInterstitialTitle(ogTitle ?? "") {
            return nil
        }

        var attachments: [SocialMediaAttachment] = []
        var seen = Set<String>()
        if let ogVideo, seen.insert(ogVideo).inserted {
            attachments.append(SocialMediaAttachment(kind: .video, url: ogVideo, thumbnailURL: ogImages.first))
        }
        for img in ogImages where seen.insert(img).inserted {
            attachments.append(SocialMediaAttachment(kind: .photo, url: img, thumbnailURL: img))
        }

        let cleanBody = cleanXiaohongshuBody(ogDesc)
        let meta = SocialPostMetadata(
            platform: .xiaohongshu,
            authorName: "小红书笔记",
            authorHandle: ref.noteID ?? "xiaohongshu",
            bodyText: cleanBody.isEmpty ? cleanedTitle : cleanBody,
            articleTitle: cleanedTitle.isEmpty ? nil : cleanedTitle,
            mediaURLs: attachments.map(\.url),
            mediaThumbnailURLs: attachments.compactMap { $0.thumbnailURL ?? $0.url },
            attachments: attachments,
            hasVideo: ogVideo != nil,
            videoURL: ogVideo,
            originalURL: ref.canonicalURL.absoluteString,
            mediaFetchFailed: false
        )

        let primary = attachments.first
        let primaryKind: XPostMedia.Kind? = primary.map { $0.kind == .video ? .video : .photo }
        return ResolvedSocialPost(
            metadata: meta,
            primaryMediaDownloadURL: primary.flatMap { URL(string: $0.url) },
            primaryMediaKind: primaryKind,
            primaryThumbnailURL: (primary?.thumbnailURL ?? ogImages.first).flatMap(URL.init(string:))
        )
    }

    /// Parses Xiaohongshu count strings like `"128"`, `"1.2万"`, `"3.4千"`, `"10万+"`, or numeric JSON values.
    public static func parseChineseMetricCount(_ raw: Any?) -> Int? {
        if let intVal = raw as? Int { return max(0, intVal) }
        if let numVal = raw as? NSNumber { return max(0, numVal.intValue) }
        guard var s = (raw as? String)?.trimmingCharacters(in: .whitespacesAndNewlines), !s.isEmpty else {
            return nil
        }
        s = s.replacingOccurrences(of: "+", with: "")
            .replacingOccurrences(of: ",", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if s.hasSuffix("万") || s.lowercased().hasSuffix("w") {
            let numStr = String(s.dropLast())
            if let v = Double(numStr), v.isFinite {
                let scaled = (v * 10_000).rounded()
                guard scaled.isFinite, scaled >= 0, scaled < Double(Int.max) else { return nil }
                return Int(scaled)
            }
        }
        if s.hasSuffix("千") || s.lowercased().hasSuffix("k") {
            let numStr = String(s.dropLast())
            if let v = Double(numStr), v.isFinite {
                let scaled = (v * 1_000).rounded()
                guard scaled.isFinite, scaled >= 0, scaled < Double(Int.max) else { return nil }
                return Int(scaled)
            }
        }
        if let v = Int(s) { return max(0, v) }
        return nil
    }

    /// Replaces bare JS `undefined` tokens outside JSON string literals with `null`.
    public static func sanitizeJSUndefined(in input: String) -> String {
        var out = String()
        out.reserveCapacity(input.count)
        var inString = false
        var escaped = false
        var idx = input.startIndex
        let end = input.endIndex

        while idx < end {
            let ch = input[idx]
            if inString {
                out.append(ch)
                if escaped {
                    escaped = false
                } else if ch == "\\" {
                    escaped = true
                } else if ch == "\"" {
                    inString = false
                }
                idx = input.index(after: idx)
                continue
            }

            if ch == "\"" {
                inString = true
                out.append(ch)
                idx = input.index(after: idx)
                continue
            }

            if ch == "u", input[idx...].hasPrefix("undefined") {
                let after = input.index(idx, offsetBy: 9)
                let prevIsIdent: Bool = {
                    guard idx > input.startIndex else { return false }
                    let p = input[input.index(before: idx)]
                    return p.isLetter || p.isNumber || p == "_" || p == "$"
                }()
                let nextIsIdent: Bool = {
                    guard after < end else { return false }
                    let n = input[after]
                    return n.isLetter || n.isNumber || n == "_" || n == "$"
                }()
                if !prevIsIdent && !nextIsIdent {
                    out.append("null")
                    idx = after
                    continue
                }
            }

            out.append(ch)
            idx = input.index(after: idx)
        }
        return out
    }

    public static func cleanXiaohongshuBody(_ text: String) -> String {
        // Xiaohongshu appends `[话题]#` to inline hashtag markers, e.g. `#插画[话题]#`.
        let cleaned = text.replacingOccurrences(of: "[话题]#", with: "")
        return cleaned.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: - JSON Structure Helpers

    private static func extractInitialStateJSON(from html: String) -> String? {
        let markers = [
            "window.__INITIAL_STATE__=",
            "window.__INITIAL_STATE__ ="
        ]
        for marker in markers {
            guard let range = html.range(of: marker) else { continue }
            var cursor = range.upperBound
            while cursor < html.endIndex && html[cursor].isWhitespace {
                cursor = html.index(after: cursor)
            }
            guard cursor < html.endIndex, html[cursor] == "{" else { continue }

            // Walk balanced JSON braces respecting strings & escapes.
            var depth = 0
            var inString = false
            var escaped = false
            var scan = cursor
            while scan < html.endIndex {
                let c = html[scan]
                if inString {
                    if escaped {
                        escaped = false
                    } else if c == "\\" {
                        escaped = true
                    } else if c == "\"" {
                        inString = false
                    }
                } else {
                    if c == "\"" {
                        inString = true
                    } else if c == "{" {
                        depth += 1
                    } else if c == "}" {
                        depth -= 1
                        if depth == 0 {
                            let endIdx = html.index(after: scan)
                            return String(html[cursor..<endIdx])
                        }
                    }
                }
                scan = html.index(after: scan)
            }
        }
        return nil
    }

    private static func locateNoteDictionary(in root: [String: Any], expectedID: String?) -> [String: Any]? {
        // Shape 1: desktop web `root.note.noteDetailMap[noteId].note`
        if let noteSection = root["note"] as? [String: Any] {
            if let detailMap = noteSection["noteDetailMap"] as? [String: Any] {
                if let expectedID,
                   let entry = detailMap[expectedID] as? [String: Any],
                   let note = entry["note"] as? [String: Any] {
                    return note
                }
                for value in detailMap.values {
                    if let entry = value as? [String: Any],
                       let note = entry["note"] as? [String: Any],
                       (note["title"] != nil || note["desc"] != nil || note["imageList"] != nil) {
                        return note
                    }
                }
            }
            if let direct = noteSection["note"] as? [String: Any] {
                return direct
            }
        }
        // Shape 2: mobile web `root.noteData.data.noteData`
        if let noteData = root["noteData"] as? [String: Any] {
            if let data = noteData["data"] as? [String: Any],
               let inner = data["noteData"] as? [String: Any] {
                return inner
            }
            if noteData["title"] != nil || noteData["imageList"] != nil {
                return noteData
            }
        }
        return nil
    }

    private static func extractBestImageURL(from item: [String: Any]) -> String? {
        if let infoList = item["infoList"] as? [[String: Any]] {
            if let dft = infoList.first(where: { stringValue($0["imageScene"]) == "WB_DFT" }),
               let url = upgradedHTTPSURL(stringValue(dft["url"])) {
                return url
            }
            for info in infoList {
                if let url = upgradedHTTPSURL(stringValue(info["url"])) {
                    return url
                }
            }
        }
        for key in ["urlDefault", "url", "urlPre", "originalUrl"] {
            if let url = upgradedHTTPSURL(stringValue(item[key])) {
                return url
            }
        }
        return nil
    }

    private static func extractPreviewImageURL(from item: [String: Any]) -> String? {
        if let infoList = item["infoList"] as? [[String: Any]],
           let prv = infoList.first(where: { stringValue($0["imageScene"]) == "WB_PRV" }),
           let url = upgradedHTTPSURL(stringValue(prv["url"])) {
            return url
        }
        return upgradedHTTPSURL(stringValue(item["urlPre"] ?? item["urlDefault"]))
    }

    private static func extractVideoStreamURL(from videoObj: [String: Any]) -> String? {
        if let media = videoObj["media"] as? [String: Any],
           let stream = media["stream"] as? [String: Any] {
            for codec in ["h264", "av1", "h265"] {
                if let variants = stream[codec] as? [[String: Any]] {
                    for v in variants {
                        if let master = upgradedHTTPSURL(stringValue(v["masterUrl"])) {
                            return master
                        }
                        if let backups = v["backupUrls"] as? [String],
                           let first = backups.compactMap(upgradedHTTPSURL).first {
                            return first
                        }
                    }
                }
            }
        }
        if let consumer = videoObj["consumer"] as? [String: Any],
           let originKey = stringValue(consumer["originVideoKey"]), !originKey.isEmpty {
            let trimmed = originKey.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            return "https://sns-video-bd.xhscdn.com/\(trimmed)"
        }
        return nil
    }

    private static func formatTimestamp(_ raw: Any?) -> String? {
        let numeric: Double?
        if let d = raw as? Double {
            numeric = d
        } else if let i = raw as? Int {
            numeric = Double(i)
        } else if let n = raw as? NSNumber {
            numeric = n.doubleValue
        } else {
            numeric = nil
        }
        guard let numeric, numeric > 1_000_000_000 else { return nil }
        let seconds = numeric > 10_000_000_000 ? (numeric / 1000.0) : numeric
        let date = Date(timeIntervalSince1970: seconds)
        let fmt = DateFormatter()
        fmt.locale = Locale(identifier: "en_US_POSIX")
        fmt.dateFormat = "yyyy-MM-dd HH:mm"
        return fmt.string(from: date)
    }

    // MARK: - Networking

    private static func buildCandidateFetchURLs(for ref: XiaohongshuNoteReference) -> [URL] {
        var list: [URL] = []
        var seen = Set<String>()
        func add(_ url: URL?) {
            guard let url, seen.insert(url.absoluteString).inserted else { return }
            list.append(url)
        }

        add(ref.canonicalURL)
        add(ref.sourceURL)
        if let noteID = ref.noteID {
            var comps = URLComponents(string: "https://www.xiaohongshu.com/discovery/item/\(noteID)")
            var query: [URLQueryItem] = []
            if let t = ref.xsecToken { query.append(URLQueryItem(name: "xsec_token", value: t)) }
            if let s = ref.xsecSource { query.append(URLQueryItem(name: "xsec_source", value: s)) }
            if !query.isEmpty { comps?.queryItems = query }
            add(comps?.url)
        }
        return list
    }

    private static func fetchHTML(_ url: URL) async -> (String, URL)? {
        guard WebBookmark.isSafeRemoteFetchURL(url) else { return nil }
        let config = URLSessionConfiguration.ephemeral
        config.httpShouldSetCookies = true
        config.timeoutIntervalForRequest = 10
        config.timeoutIntervalForResource = 14
        let session = URLSession(configuration: config)
        defer { session.invalidateAndCancel() }

        var req = URLRequest(url: url, timeoutInterval: 10)
        req.setValue(desktopSafariUA, forHTTPHeaderField: "User-Agent")
        req.setValue("text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8", forHTTPHeaderField: "Accept")
        req.setValue("zh-CN,zh;q=0.9,en;q=0.8", forHTTPHeaderField: "Accept-Language")
        req.setValue("https://www.xiaohongshu.com/", forHTTPHeaderField: "Referer")

        guard let (data, response) = try? await session.data(for: req),
              let http = response as? HTTPURLResponse,
              (200..<300).contains(http.statusCode),
              !data.isEmpty else {
            return nil
        }
        let html = String(decoding: data.prefix(1_572_864), as: UTF8.self)
        return (html, http.url ?? url)
    }

    // MARK: - String / HTML Utilities

    private static func stringValue(_ raw: Any?) -> String? {
        guard let s = raw as? String else { return nil }
        let trimmed = s.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private static func upgradedHTTPSURL(_ raw: String?) -> String? {
        guard var trimmed = raw?.trimmingCharacters(in: .whitespacesAndNewlines), !trimmed.isEmpty else {
            return nil
        }
        if trimmed.hasPrefix("//") {
            trimmed = "https:" + trimmed
        } else if trimmed.lowercased().hasPrefix("http://") {
            trimmed = "https://" + trimmed.dropFirst(7)
        }
        guard let url = URL(string: trimmed), WebBookmark.isWebURL(url) else { return nil }
        return url.absoluteString
    }

    private static func isPlaceholderAsset(_ urlString: String) -> Bool {
        let lower = urlString.lowercased()
        return lower.contains("favicon") || lower.contains("xhs-logo") || lower.contains("fe-platform/logo")
    }

    private static func cleanPageTitle(_ raw: String) -> String {
        var title = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        for suffix in [" - 小红书", " - 小红书网页版", " | 小红书"] {
            if title.hasSuffix(suffix) {
                title = String(title.dropLast(suffix.count)).trimmingCharacters(in: .whitespacesAndNewlines)
            }
        }
        return title
    }

    private static func isBlockedInterstitialTitle(_ title: String) -> Bool {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return true }
        return blockedTitles.contains { trimmed.contains($0) }
    }

    private static func extractHTMLTitle(in html: String) -> String? {
        guard let regex = try? NSRegularExpression(pattern: #"(?is)<title\b[^>]*>(.*?)</title>"#) else { return nil }
        let range = NSRange(html.startIndex..., in: html)
        guard let match = regex.firstMatch(in: html, range: range),
              let r = Range(match.range(at: 1), in: html) else {
            return nil
        }
        return decodeHTML(String(html[r])).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func extractMetaValues(_ name: String, in html: String) -> [String] {
        guard let tagRegex = try? NSRegularExpression(pattern: #"(?is)<meta\b[^>]*>"#),
              let attrRegex = try? NSRegularExpression(pattern: #"(?is)([a-z][\w:-]*)\s*=\s*(?:"([^"]*)"|'([^']*)'|([^\s>]+))"#) else {
            return []
        }
        var results: [String] = []
        let fullRange = NSRange(html.startIndex..., in: html)
        for match in tagRegex.matches(in: html, range: fullRange) {
            guard let r = Range(match.range, in: html) else { continue }
            let tag = String(html[r])
            var attrs: [String: String] = [:]
            for attr in attrRegex.matches(in: tag, range: NSRange(tag.startIndex..., in: tag)) {
                guard let keyR = Range(attr.range(at: 1), in: tag) else { continue }
                let key = String(tag[keyR]).lowercased()
                for group in 2...4 {
                    if let valR = Range(attr.range(at: group), in: tag), !tag[valR].isEmpty {
                        attrs[key] = String(tag[valR])
                        break
                    }
                }
            }
            if (attrs["property"] ?? attrs["name"])?.lowercased() == name,
               let content = attrs["content"], !content.isEmpty {
                results.append(decodeHTML(content))
            }
        }
        return results
    }

    private static func decodeHTML(_ input: String) -> String {
        input
            .replacingOccurrences(of: "&quot;", with: "\"")
            .replacingOccurrences(of: "&#39;", with: "'")
            .replacingOccurrences(of: "&apos;", with: "'")
            .replacingOccurrences(of: "&lt;", with: "<")
            .replacingOccurrences(of: "&gt;", with: ">")
            .replacingOccurrences(of: "&nbsp;", with: " ")
            .replacingOccurrences(of: "&amp;", with: "&")
    }
}
