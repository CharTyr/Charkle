import Foundation

/// Parsed identity of a Douyin (抖音) video, photo-note (`图文`), or short share link (`v.douyin.com`).
public nonisolated struct DouyinPostReference: Equatable, Hashable, Sendable {
    public let awemeID: String?
    public let isNote: Bool
    public let sourceURL: URL
    public let isShortLink: Bool

    public init(
        awemeID: String?,
        isNote: Bool,
        sourceURL: URL,
        isShortLink: Bool
    ) {
        self.awemeID = awemeID
        self.isNote = isNote
        self.sourceURL = sourceURL
        self.isShortLink = isShortLink
    }

    /// Canonical `https://www.douyin.com/video/<aweme_id>` or `https://www.douyin.com/note/<aweme_id>` URL.
    public var canonicalURL: URL {
        if let awemeID, !awemeID.isEmpty {
            let kind = isNote ? "note" : "video"
            if let canonical = URL(string: "https://www.douyin.com/\(kind)/\(awemeID)") {
                return canonical
            }
        }
        return sourceURL
    }

    /// Stable cross-platform deduplication key independent of route or query parameters.
    public var dedupKey: String {
        if let awemeID, !awemeID.isEmpty {
            return "douyin:\(awemeID)"
        }
        return "url:\(sourceURL.absoluteString.lowercased())"
    }
}

/// Detects and normalizes Douyin video/photo-note URLs, `?modal_id=` views, and `v.douyin.com`
/// mobile share copy links, plus CDN host classification for Referer headers and magic-byte sniffing.
public nonisolated enum DouyinURLParser {
    public static let referer = "https://www.douyin.com/"
    public static let videoTag = "抖音视频"
    public static let photoNoteTag = "抖音图文"

    /// Canonical content-type classification tag for Douyin items (`抖音视频` vs `抖音图文`).
    public static func classificationTag(hasVideo: Bool) -> String {
        hasVideo ? videoTag : photoNoteTag
    }

    private static let postHosts: Set<String> = [
        "douyin.com",
        "www.douyin.com",
        "m.douyin.com",
        "iesdouyin.com",
        "www.iesdouyin.com"
    ]

    private static let shortHosts: Set<String> = [
        "v.douyin.com",
        "www.v.douyin.com"
    ]

    private static let imageHostSuffixes: [String] = [
        "douyinpic.com",
        "byteimg.com",
        "ibytedtos.com",
        "zjcdn.com",
        "snssdk.com",
        "amemv.com",
        "pstatp.com",
        "douyincdn.com",
        "bytegoofy.com"
    ]

    private static let videoHostSuffixes: [String] = [
        "douyinvod.com",
        "zjcdn.com",
        "snssdk.com",
        "bytevcloudapi.com",
        "amemv.com",
        "douyincdn.com",
        "iesdouyin.com",
        "douyin.com"
    ]

    public static func parse(_ rawString: String) -> DouyinPostReference? {
        let trimmed = rawString.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let normalized = trimmed.hasPrefix("//") ? "https:\(trimmed)" : trimmed
        guard let url = URL(string: normalized) else { return nil }
        return parse(url)
    }

    public static func parse(_ url: URL) -> DouyinPostReference? {
        guard let scheme = url.scheme?.lowercased(),
              scheme == "http" || scheme == "https" else {
            return nil
        }
        if url.user() != nil || url.password() != nil {
            return nil
        }
        guard let host = url.host()?.lowercased(), !host.isEmpty else {
            return nil
        }

        let segments = url.pathComponents.filter { $0 != "/" && !$0.isEmpty }

        if shortHosts.contains(host) {
            guard !segments.isEmpty else { return nil }
            return DouyinPostReference(
                awemeID: nil,
                isNote: false,
                sourceURL: url,
                isShortLink: true
            )
        }

        guard postHosts.contains(host) else {
            return nil
        }

        // Direct path patterns:
        // /video/<aweme_id>
        // /note/<aweme_id>
        // /slides/<aweme_id>
        // /share/video/<aweme_id>
        // /share/note/<aweme_id>
        // /share/slides/<aweme_id>
        if segments.count >= 2 {
            let first = segments[0].lowercased()
            let second = segments[1]
            if first == "video", isValidAwemeID(second) {
                return DouyinPostReference(
                    awemeID: second,
                    isNote: false,
                    sourceURL: url,
                    isShortLink: false
                )
            }
            if (first == "note" || first == "slides"), isValidAwemeID(second) {
                return DouyinPostReference(
                    awemeID: second,
                    isNote: true,
                    sourceURL: url,
                    isShortLink: false
                )
            }
        }

        if segments.count >= 3,
           segments[0].lowercased() == "share",
           isValidAwemeID(segments[2]) {
            let kind = segments[1].lowercased()
            if kind == "video" {
                return DouyinPostReference(
                    awemeID: segments[2],
                    isNote: false,
                    sourceURL: url,
                    isShortLink: false
                )
            }
            if kind == "note" || kind == "slides" {
                return DouyinPostReference(
                    awemeID: segments[2],
                    isNote: true,
                    sourceURL: url,
                    isShortLink: false
                )
            }
        }

        // Modal query parameter on profile/discover/search pages: ?modal_id=<aweme_id>
        if let comps = URLComponents(url: url, resolvingAgainstBaseURL: false),
           let items = comps.queryItems {
            for item in items where item.name.lowercased() == "modal_id" {
                let candidate = (item.value ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                if isValidAwemeID(candidate) {
                    let isNote = segments.contains {
                        let lower = $0.lowercased()
                        return lower == "note" || lower == "slides"
                    }
                    return DouyinPostReference(
                        awemeID: candidate,
                        isNote: isNote,
                        sourceURL: url,
                        isShortLink: false
                    )
                }
            }
        }

        return nil
    }

    /// Extracts a Douyin URL from raw pasted text or Chinese mobile share copy
    /// (e.g. `"7.48 复制打开抖音，看看【作者的作品】... https://v.douyin.com/iXXXX/ 03/12"`),
    /// supporting both space-separated and zero-space CJK-glued links.
    public static func extractPostURL(from text: String) -> URL? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        if let direct = parse(trimmed) {
            return direct.sourceURL
        }

        let trailingPunctuation = CharacterSet(charactersIn: ".,;!?)]，。！？")
        let boundaryChars: Set<Character> = ["<", ">", "\"", "'", "（", "）", "【", "】"]

        var cursor = trimmed.startIndex
        while cursor < trimmed.endIndex {
            let rest = trimmed[cursor...]
            let lowerPrefix = rest.prefix(8).lowercased()
            let hasHTTPS = lowerPrefix.hasPrefix("https://")
            let hasHTTP = !hasHTTPS && lowerPrefix.hasPrefix("http://")
            if hasHTTPS || hasHTTP {
                var end = rest.endIndex
                var scan = rest.startIndex
                while scan < rest.endIndex {
                    let ch = rest[scan]
                    let firstScalar = ch.unicodeScalars.first?.value ?? 0
                    if ch.isWhitespace || firstScalar >= 0x2E80 || boundaryChars.contains(ch) {
                        end = scan
                        break
                    }
                    scan = rest.index(after: scan)
                }
                let candidate = String(rest[..<end]).trimmingCharacters(in: trailingPunctuation)
                if let url = URL(string: candidate), parse(url) != nil {
                    return url
                }
            }
            cursor = trimmed.index(after: cursor)
        }
        return nil
    }

    public static func isValidAwemeID(_ candidate: String) -> Bool {
        (15...22).contains(candidate.count) && candidate.allSatisfy { $0.isASCII && $0.isNumber }
    }

    public static func isShortLink(_ url: URL) -> Bool {
        guard let host = url.host()?.lowercased() else { return false }
        return shortHosts.contains(host)
    }

    /// Allowlisted Douyin image & avatar CDN hosts for Referer injection.
    public static func isDouyinImageHost(_ host: String?) -> Bool {
        matchesDomainSuffix(host, suffixes: imageHostSuffixes)
    }

    /// Allowlisted Douyin video CDN & playback redirect hosts for streaming & Referer injection.
    public static func isDouyinVideoHost(_ host: String?) -> Bool {
        matchesDomainSuffix(host, suffixes: videoHostSuffixes)
    }

    /// Union of Douyin image and video CDN hosts.
    public static func isDouyinMediaHost(_ host: String?) -> Bool {
        isDouyinImageHost(host) || isDouyinVideoHost(host)
    }

    /// Returns `true` if a Douyin signed VOD URL carries an explicit Unix timestamp expiration
    /// (`x-expires` or `expires`, decimal or hex) that has already passed (with a 30-second safety margin).
    public static func isStreamURLExpired(_ url: URL, now: Date = Date()) -> Bool {
        guard let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems else {
            return false
        }
        let nowSecs = Int64(now.timeIntervalSince1970)
        for item in items {
            let name = item.name.lowercased()
            guard name == "x-expires" || name == "expires",
                  let raw = item.value?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !raw.isEmpty else {
                continue
            }
            let decimal = Int64(raw)
            let resolvedExp: Int64?
            if let decimal, decimal > 1_600_000_000 {
                resolvedExp = decimal
            } else if let hex = Int64(raw, radix: 16), hex > 1_600_000_000 {
                resolvedExp = hex
            } else {
                resolvedExp = nil
            }
            if let exp = resolvedExp, exp <= nowSecs &+ 30 {
                return true
            }
        }
        return false
    }

    /// Sniffs file extension from binary header magic bytes when CDNs serve `application/octet-stream`
    /// without a filename extension (handles PNG, JPEG, GIF, WebP, and ISO BMFF `ftyp` for AVIF/HEIC/MP4/MOV).
    public static func sniffMediaExtension(from headerBytes: Data) -> String? {
        let bytes = [UInt8](headerBytes.prefix(64))
        guard bytes.count >= 4 else { return nil }

        // PNG: 89 50 4E 47
        if bytes[0] == 0x89 && bytes[1] == 0x50 && bytes[2] == 0x4E && bytes[3] == 0x47 {
            return "png"
        }
        // JPEG: FF D8 FF
        if bytes[0] == 0xFF && bytes[1] == 0xD8 && bytes[2] == 0xFF {
            return "jpg"
        }
        // GIF8
        if bytes[0] == 0x47 && bytes[1] == 0x49 && bytes[2] == 0x46 && bytes[3] == 0x38 {
            return "gif"
        }
        // WebP: RIFF....WEBP
        if bytes.count >= 12,
           bytes[0] == 0x52 && bytes[1] == 0x49 && bytes[2] == 0x46 && bytes[3] == 0x46,
           bytes[8] == 0x57 && bytes[9] == 0x45 && bytes[10] == 0x42 && bytes[11] == 0x50 {
            return "webp"
        }
        // ISO BMFF box: ....ftyp<major_brand><minor_version><compatible_brands...>
        if bytes.count >= 12,
           bytes[4] == 0x66 && bytes[5] == 0x74 && bytes[6] == 0x79 && bytes[7] == 0x70 {
            let boxSize = Int(
                (UInt32(bytes[0]) << 24)
                | (UInt32(bytes[1]) << 16)
                | (UInt32(bytes[2]) << 8)
                | UInt32(bytes[3])
            )
            let scanLimit = min(bytes.count, max(12, min(boxSize > 0 ? boxSize : bytes.count, 64)))
            var brands: [String] = []
            if let major = String(bytes: bytes[8..<12], encoding: .ascii) {
                brands.append(major.lowercased())
            }
            var offset = 16
            while offset + 4 <= scanLimit {
                if let compat = String(bytes: bytes[offset..<(offset + 4)], encoding: .ascii) {
                    brands.append(compat.lowercased())
                }
                offset += 4
            }

            for b in brands {
                if b == "avif" || b == "avis" { return "avif" }
            }
            for b in brands {
                if b == "heic" || b == "heix" || b == "hevc" || b == "hevx" || b == "mif1" || b == "msf1" {
                    return "heic"
                }
            }
            if brands.first == "qt  " {
                return "mov"
            }
            for b in brands {
                if b == "isom" || b == "iso2" || b == "mp41" || b == "mp42"
                    || b == "avc1" || b == "hvc1" || b == "hev1" || b == "m4v " || b == "dash" {
                    return "mp4"
                }
            }
        }
        return nil
    }

    private static func matchesDomainSuffix(_ host: String?, suffixes: [String]) -> Bool {
        guard let raw = host?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(),
              !raw.isEmpty else {
            return false
        }
        return suffixes.contains { suffix in
            raw == suffix || raw.hasSuffix(".\(suffix)")
        }
    }
}

/// Best-effort resolver for directly pasted Douyin URLs and `v.douyin.com` short links.
/// Never synthesizes anti-bot signatures (`a_bogus` / `X-Bogus`) or attempts to bypass login
/// or verification gates: if public HTML returns a verification/JS shell, falls back gracefully
/// to a clean canonical Douyin bookmark preserving `aweme_id` and watch URL.
public nonisolated enum DouyinPostResolver {
    private static let browserUA = "Mozilla/5.0 (Macintosh; Intel Mac OS X 15_0) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.2 Safari/605.1.15"
    private static let maxHTMLBytes = 2 * 1024 * 1024

    private static let blockedTitles: [String] = [
        "验证码中间页",
        "安全验证",
        "验证中心",
        "登录 - 抖音",
        "抖音-记录美好生活",
        "抖音 - 记录美好生活"
    ]

    private final class SafeRedirectDelegate: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
        let maxHops: Int
        private var hopCount = 0

        init(maxHops: Int = 6) {
            self.maxHops = maxHops
        }

        func urlSession(
            _ session: URLSession,
            task: URLSessionTask,
            willPerformHTTPRedirection response: HTTPURLResponse,
            newRequest request: URLRequest,
            completionHandler: @escaping (URLRequest?) -> Void
        ) {
            hopCount += 1
            guard hopCount <= maxHops,
                  let target = request.url,
                  WebBookmark.isSafeRemoteFetchURL(target) else {
                completionHandler(nil)
                return
            }
            completionHandler(request)
        }
    }

    public static func resolve(_ reference: DouyinPostReference) async -> ResolvedSocialPost? {
        var workingRef = reference
        if reference.isShortLink {
            if let redirected = await resolveShortLink(reference.sourceURL),
               let parsed = DouyinURLParser.parse(redirected) {
                workingRef = parsed
            }
        }

        let fetchURL = workingRef.canonicalURL
        if let (html, finalURL) = await fetchHTML(fetchURL) {
            let effectiveRef: DouyinPostReference = DouyinURLParser.parse(finalURL) ?? {
                if workingRef.awemeID != nil {
                    return workingRef
                }
                return DouyinPostReference(
                    awemeID: workingRef.awemeID,
                    isNote: workingRef.isNote,
                    sourceURL: finalURL,
                    isShortLink: false
                )
            }()
            if let fromData = parseRouterOrRenderData(html: html, reference: effectiveRef) {
                return fromData
            }
            if let fromMeta = parseMetaFallback(html: html, reference: effectiveRef) {
                return fromMeta
            }
        }

        if let awemeID = workingRef.awemeID, !awemeID.isEmpty {
            return buildMinimalBookmark(reference: workingRef, awemeID: awemeID)
        }
        return nil
    }

    /// Follows redirects on `v.douyin.com/<code>` (capped at 6 hops, SSRF-guarded).
    public static func resolveShortLink(_ url: URL) async -> URL? {
        guard WebBookmark.isSafeRemoteFetchURL(url) else { return nil }
        let config = URLSessionConfiguration.ephemeral
        config.httpShouldSetCookies = false
        config.timeoutIntervalForRequest = 10
        config.timeoutIntervalForResource = 12
        let delegate = SafeRedirectDelegate(maxHops: 6)
        let session = URLSession(configuration: config, delegate: delegate, delegateQueue: nil)
        defer { session.invalidateAndCancel() }

        var req = URLRequest(url: url, timeoutInterval: 10)
        req.setValue(browserUA, forHTTPHeaderField: "User-Agent")
        req.setValue("text/html,application/xhtml+xml,*/*;q=0.8", forHTTPHeaderField: "Accept")

        guard let (_, resp) = try? await session.data(for: req),
              let finalURL = resp.url,
              WebBookmark.isSafeRemoteFetchURL(finalURL) else {
            return nil
        }
        return finalURL
    }

    private static func fetchHTML(_ url: URL) async -> (String, URL)? {
        guard WebBookmark.isSafeRemoteFetchURL(url) else { return nil }
        let config = URLSessionConfiguration.ephemeral
        config.httpShouldSetCookies = false
        config.timeoutIntervalForRequest = 10
        config.timeoutIntervalForResource = 12
        let delegate = SafeRedirectDelegate(maxHops: 5)
        let session = URLSession(configuration: config, delegate: delegate, delegateQueue: nil)
        defer { session.invalidateAndCancel() }

        var req = URLRequest(url: url, timeoutInterval: 10)
        req.setValue(browserUA, forHTTPHeaderField: "User-Agent")
        req.setValue("text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8", forHTTPHeaderField: "Accept")
        req.setValue("zh-CN,zh;q=0.9,en;q=0.7", forHTTPHeaderField: "Accept-Language")
        req.setValue(DouyinURLParser.referer, forHTTPHeaderField: "Referer")

        guard let (data, resp) = try? await session.data(for: req),
              let http = resp as? HTTPURLResponse,
              (200..<300).contains(http.statusCode),
              let finalURL = http.url,
              WebBookmark.isSafeRemoteFetchURL(finalURL),
              !data.isEmpty,
              data.count <= maxHTMLBytes else {
            return nil
        }
        return (String(decoding: data, as: UTF8.self), finalURL)
    }

    // MARK: - Pure Offline Parsers

    public static func parseRouterOrRenderData(
        html: String,
        reference: DouyinPostReference
    ) -> ResolvedSocialPost? {
        guard let root = extractEmbeddedDouyinJSON(from: html),
              let aweme = locateAwemeObject(in: root, targetID: reference.awemeID) else {
            return nil
        }
        return buildFromAwemeDictionary(aweme, reference: reference)
    }

    public static func parseMetaFallback(
        html: String,
        reference: DouyinPostReference
    ) -> ResolvedSocialPost? {
        let rawTitle = extractMeta("og:title", in: html) ?? extractTitle(in: html) ?? ""
        let cleanTitle = cleanDouyinPageTitle(rawTitle)
        let description = (extractMeta("og:description", in: html) ?? extractMeta("description", in: html) ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let coverStr = extractMeta("og:image", in: html).flatMap(upgradedHTTPSURLString)

        if isBlockedTitle(cleanTitle) && coverStr == nil && description.isEmpty {
            return nil
        }
        if cleanTitle.isEmpty && description.isEmpty && coverStr == nil {
            return nil
        }

        let canonicalStr = reference.canonicalURL.absoluteString
        let hasVideo = !reference.isNote
        var attachments: [SocialMediaAttachment] = []
        var mediaURLs: [String] = []
        var mediaThumbs: [String] = []
        if let coverStr {
            attachments.append(SocialMediaAttachment(kind: .photo, url: coverStr, thumbnailURL: coverStr))
            mediaURLs.append(coverStr)
            mediaThumbs.append(coverStr)
        }

        let bodyText = !description.isEmpty ? description : (!cleanTitle.isEmpty ? cleanTitle : canonicalStr)
        let meta = SocialPostMetadata(
            platform: .douyin,
            authorName: "抖音用户",
            authorHandle: "douyin",
            authorAvatarURL: nil,
            publishedAtText: nil,
            bodyText: bodyText,
            articleTitle: cleanTitle.isEmpty ? nil : cleanTitle,
            mediaURLs: mediaURLs,
            mediaThumbnailURLs: mediaThumbs,
            attachments: attachments,
            hasVideo: hasVideo,
            videoURL: nil,
            originalURL: canonicalStr,
            mediaFetchFailed: false,
            videoID: reference.awemeID
        )

        let coverURL = coverStr.flatMap(URL.init(string:))
        return ResolvedSocialPost(
            metadata: meta,
            primaryMediaDownloadURL: hasVideo ? nil : coverURL,
            primaryMediaKind: (!hasVideo && coverURL != nil) ? .photo : nil,
            primaryThumbnailURL: coverURL,
            extractedTags: [DouyinURLParser.classificationTag(hasVideo: hasVideo)]
        )
    }

    private static func buildFromAwemeDictionary(
        _ aweme: [String: Any],
        reference: DouyinPostReference
    ) -> ResolvedSocialPost {
        let awemeID = stringValue(aweme["aweme_id"] ?? aweme["awemeId"]) ?? reference.awemeID
        let desc = stringValue(aweme["desc"]) ?? ""
        let explicitTitle = stringValue(aweme["item_title"] ?? aweme["preview_title"])

        let images = aweme["images"] as? [[String: Any]]
        let awemeType = int64Value(aweme["aweme_type"])
        let isPhotoNote = reference.isNote || awemeType == 68 || (images?.isEmpty == false)

        let author = aweme["author"] as? [String: Any]
        let authorName = stringValue(author?["nickname"]) ?? "抖音用户"
        let authorHandle = stringValue(author?["unique_id"])
            ?? stringValue(author?["short_id"])
            ?? stringValue(author?["uid"])
            ?? "douyin"
        let authorAvatarURL = pickBestImageURL(from: author?["avatar_medium"])
            ?? pickBestImageURL(from: author?["avatar_thumb"])
            ?? pickBestImageURL(from: author?["avatar_larger"])

        let publishedAtText = formatEpochTimestamp(aweme["create_time"])

        let stats = aweme["statistics"] as? [String: Any]
        let likeCount = parseMetricCount(stats?["digg_count"])
        let replyCount = parseMetricCount(stats?["comment_count"])
        let repostCount = parseMetricCount(stats?["share_count"] ?? stats?["collect_count"])
        let viewCount = parseMetricCount(stats?["play_count"])

        var extractedTags: [String] = []
        var seenTags = Set<String>()
        if let extras = aweme["text_extra"] as? [[String: Any]] {
            for entry in extras {
                if let tag = stringValue(entry["hashtag_name"]) {
                    let clean = tag.trimmingCharacters(in: CharacterSet(charactersIn: "#").union(.whitespacesAndNewlines))
                    if !clean.isEmpty, seenTags.insert(clean.lowercased()).inserted {
                        extractedTags.append(clean)
                    }
                }
            }
        }

        var attachments: [SocialMediaAttachment] = []
        var mediaURLs: [String] = []
        var mediaThumbs: [String] = []
        var videoURLStr: String?
        var primaryThumbStr: String?
        var videoDurationSeconds: Double?

        if isPhotoNote {
            if let images {
                for img in images {
                    if let urlStr = pickBestImageURL(from: img) {
                        if primaryThumbStr == nil { primaryThumbStr = urlStr }
                        attachments.append(SocialMediaAttachment(kind: .photo, url: urlStr, thumbnailURL: urlStr))
                        mediaURLs.append(urlStr)
                        mediaThumbs.append(urlStr)
                    }
                }
            }
        } else if let video = aweme["video"] as? [String: Any] {
            if let durVal = doubleValue(video["duration"] ?? aweme["duration"]), durVal > 0 {
                videoDurationSeconds = durVal > 3600 ? durVal / 1000.0 : durVal
            }
            let cover = pickBestImageURL(from: video["origin_cover"])
                ?? pickBestImageURL(from: video["cover"])
                ?? pickBestImageURL(from: video["dynamic_cover"])
            primaryThumbStr = cover
            videoURLStr = pickBestVideoURL(from: video)
            if let vURL = videoURLStr {
                attachments.append(SocialMediaAttachment(kind: .video, url: vURL, thumbnailURL: cover))
                mediaURLs.append(vURL)
                if let cover { mediaThumbs.append(cover) }
            } else if let cover {
                attachments.append(SocialMediaAttachment(kind: .photo, url: cover, thumbnailURL: cover))
                mediaURLs.append(cover)
                mediaThumbs.append(cover)
            }
        }

        let canonicalStr: String = {
            if let awemeID, !awemeID.isEmpty {
                let kind = isPhotoNote ? "note" : "video"
                return "https://www.douyin.com/\(kind)/\(awemeID)"
            }
            return reference.canonicalURL.absoluteString
        }()

        let articleTitle = explicitTitle ?? deriveHeadline(from: desc)
        let bodyText = !desc.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? desc
            : (articleTitle ?? canonicalStr)

        let hasVideo = !isPhotoNote
        let classTag = DouyinURLParser.classificationTag(hasVideo: hasVideo)
        if seenTags.insert(classTag.lowercased()).inserted {
            extractedTags.append(classTag)
        }

        let meta = SocialPostMetadata(
            platform: .douyin,
            authorName: authorName,
            authorHandle: authorHandle,
            authorAvatarURL: authorAvatarURL,
            publishedAtText: publishedAtText,
            bodyText: bodyText,
            articleTitle: articleTitle,
            mediaURLs: mediaURLs,
            mediaThumbnailURLs: mediaThumbs,
            attachments: attachments,
            hasVideo: hasVideo,
            videoURL: videoURLStr,
            replyCount: replyCount,
            repostCount: repostCount,
            likeCount: likeCount,
            viewCount: viewCount,
            originalURL: canonicalStr,
            mediaFetchFailed: false,
            videoDurationSeconds: videoDurationSeconds,
            videoID: awemeID
        )

        let thumbURL = primaryThumbStr.flatMap(URL.init(string:))
        // Zero-download video bookmarking: Douyin videos NEVER eagerly download MP4;
        // Douyin photo-notes download the cover image for crisp 900x1440 card composition.
        return ResolvedSocialPost(
            metadata: meta,
            primaryMediaDownloadURL: hasVideo ? nil : thumbURL,
            primaryMediaKind: (!hasVideo && thumbURL != nil) ? .photo : nil,
            primaryThumbnailURL: thumbURL,
            extractedTags: extractedTags
        )
    }

    private static func buildMinimalBookmark(
        reference: DouyinPostReference,
        awemeID: String
    ) -> ResolvedSocialPost {
        let canonicalStr = reference.canonicalURL.absoluteString
        let hasVideo = !reference.isNote
        let label = reference.isNote ? "抖音图文 \(awemeID)" : "抖音作品 \(awemeID)"
        let meta = SocialPostMetadata(
            platform: .douyin,
            authorName: "抖音用户",
            authorHandle: "douyin",
            bodyText: canonicalStr,
            articleTitle: label,
            hasVideo: hasVideo,
            originalURL: canonicalStr,
            mediaFetchFailed: false,
            videoID: awemeID
        )
        return ResolvedSocialPost(
            metadata: meta,
            primaryMediaDownloadURL: nil,
            primaryMediaKind: nil,
            primaryThumbnailURL: nil,
            extractedTags: [DouyinURLParser.classificationTag(hasVideo: hasVideo)]
        )
    }

    // MARK: - Embedded JSON & HTML Helpers

    private static func extractEmbeddedDouyinJSON(from html: String) -> Any? {
        // Strategy 1: <script id="RENDER_DATA" type="application/json">percent-encoded-json</script>
        if let renderRange = html.range(of: "id=\"RENDER_DATA\"") {
            let afterAttr = html[renderRange.upperBound...]
            if let gt = afterAttr.firstIndex(of: ">") {
                let bodyStart = afterAttr.index(after: gt)
                let body = afterAttr[bodyStart...]
                if let closeRange = body.range(of: "</script>", options: .caseInsensitive) {
                    let raw = String(body[..<closeRange.lowerBound]).trimmingCharacters(in: .whitespacesAndNewlines)
                    if let decoded = raw.removingPercentEncoding,
                       let data = decoded.data(using: .utf8),
                       let obj = try? JSONSerialization.jsonObject(with: data) {
                        return obj
                    }
                    if let data = raw.data(using: .utf8),
                       let obj = try? JSONSerialization.jsonObject(with: data) {
                        return obj
                    }
                }
            }
        }

        // Strategy 2: window._ROUTER_DATA = {...}</script>
        if let markerRange = html.range(of: "window._ROUTER_DATA") {
            let afterMarker = html[markerRange.upperBound...]
            if let eq = afterMarker.firstIndex(of: "=") {
                let afterEq = afterMarker[afterMarker.index(after: eq)...]
                if let closeRange = afterEq.range(of: "</script>", options: .caseInsensitive) {
                    var candidate = String(afterEq[..<closeRange.lowerBound])
                        .trimmingCharacters(in: .whitespacesAndNewlines)
                    while candidate.hasSuffix(";") {
                        candidate.removeLast()
                        candidate = candidate.trimmingCharacters(in: .whitespacesAndNewlines)
                    }
                    if let data = candidate.data(using: .utf8),
                       let obj = try? JSONSerialization.jsonObject(with: data) {
                        return obj
                    }
                }
            }
        }

        return nil
    }

    private static func locateAwemeObject(in node: Any, targetID: String?, depth: Int = 0) -> [String: Any]? {
        guard depth <= 16 else { return nil }
        if let dict = node as? [String: Any] {
            if let idStr = stringValue(dict["aweme_id"] ?? dict["awemeId"]),
               (targetID == nil || targetID == idStr),
               (dict["desc"] != nil || dict["video"] != nil || dict["images"] != nil) {
                return dict
            }
            for key in ["aweme_detail", "awemeDetail", "detail", "itemInfo"] {
                if let child = dict[key],
                   let found = locateAwemeObject(in: child, targetID: targetID, depth: depth + 1) {
                    return found
                }
            }
            for value in dict.values {
                if let found = locateAwemeObject(in: value, targetID: targetID, depth: depth + 1) {
                    return found
                }
            }
            return nil
        }
        if let array = node as? [Any] {
            for item in array {
                if let found = locateAwemeObject(in: item, targetID: targetID, depth: depth + 1) {
                    return found
                }
            }
        }
        return nil
    }

    private static func upgradedHTTPSURLString(_ raw: String) -> String? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let normalized: String
        if trimmed.hasPrefix("//") {
            normalized = "https:\(trimmed)"
        } else if trimmed.lowercased().hasPrefix("http://") {
            normalized = "https://\(trimmed.dropFirst(7))"
        } else {
            normalized = trimmed
        }
        guard let url = URL(string: normalized), WebBookmark.isWebURL(url) else {
            return nil
        }
        return url.absoluteString
    }

    private static func pickBestImageURL(from node: Any?) -> String? {
        guard let dict = node as? [String: Any],
              let list = dict["url_list"] as? [String] else {
            return nil
        }
        var nonHEIC: [String] = []
        var fallback: [String] = []
        for raw in list {
            guard let url = upgradedHTTPSURLString(raw) else { continue }
            let lower = url.lowercased()
            let isHEIC = lower.contains(".heic")
                || lower.contains(".heif")
                || lower.contains("format=heic")
                || lower.contains("~tplv-dy-aweme-images-v2:3000:3000:q75.heic")
            if isHEIC {
                fallback.append(url)
            } else {
                nonHEIC.append(url)
            }
        }
        if let preferred = nonHEIC.first(where: {
            let l = $0.lowercased()
            return l.contains(".jpeg") || l.contains(".jpg") || l.contains(".png") || l.contains(".webp")
        }) {
            return preferred
        }
        return nonHEIC.first ?? fallback.first
    }

    private static func pickBestVideoURL(from video: [String: Any]) -> String? {
        if let bitRates = video["bit_rate"] as? [[String: Any]] {
            var candidates: [(isH264: Bool, rate: Int64, url: String)] = []
            for br in bitRates {
                let isH265 = (int64Value(br["is_h265"]) ?? 0) != 0
                let rate = int64Value(br["bit_rate"]) ?? 0
                if let playAddr = br["play_addr"] as? [String: Any],
                   let urlList = playAddr["url_list"] as? [String],
                   let best = urlList.compactMap(upgradedHTTPSURLString).first(where: { !$0.lowercased().contains("playwm") }) {
                    candidates.append((!isH265, rate, best))
                }
            }
            candidates.sort { lhs, rhs in
                if lhs.isH264 != rhs.isH264 { return lhs.isH264 }
                return lhs.rate > rhs.rate
            }
            if let best = candidates.first?.url {
                return best
            }
        }
        if let playAddr = video["play_addr"] as? [String: Any],
           let urlList = playAddr["url_list"] as? [String] {
            return urlList.compactMap(upgradedHTTPSURLString).first(where: { !$0.lowercased().contains("playwm") })
        }
        return nil
    }

    private static func stringValue(_ any: Any?) -> String? {
        if let s = any as? String {
            let trimmed = s.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : trimmed
        }
        if let n = any as? NSNumber {
            return n.stringValue
        }
        return nil
    }

    private static func int64Value(_ any: Any?) -> Int64? {
        if let i = any as? Int64 { return i }
        if let i = any as? Int { return Int64(i) }
        if let n = any as? NSNumber { return n.int64Value }
        if let s = any as? String { return Int64(s.trimmingCharacters(in: .whitespacesAndNewlines)) }
        return nil
    }

    private static func doubleValue(_ any: Any?) -> Double? {
        if let d = any as? Double { return d }
        if let i = any as? Int { return Double(i) }
        if let n = any as? NSNumber { return n.doubleValue }
        if let s = any as? String { return Double(s.trimmingCharacters(in: .whitespacesAndNewlines)) }
        return nil
    }

    private static func parseMetricCount(_ any: Any?) -> Int? {
        if let i = any as? Int { return i }
        if let n = any as? NSNumber { return n.intValue }
        if let s = any as? String { return XiaohongshuPostResolver.parseChineseMetricCount(s) }
        return nil
    }

    private static func formatEpochTimestamp(_ any: Any?) -> String? {
        guard let raw = int64Value(any), raw > 0 else { return nil }
        let secs = raw > 10_000_000_000 ? raw / 1000 : raw
        let date = Date(timeIntervalSince1970: TimeInterval(secs))
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyy-MM-dd HH:mm"
        return formatter.string(from: date)
    }

    private static func deriveHeadline(from desc: String) -> String? {
        let firstLine = desc
            .split(whereSeparator: \.isNewline)
            .map { String($0).trimmingCharacters(in: .whitespacesAndNewlines) }
            .first(where: { !$0.isEmpty }) ?? ""
        let stripped = firstLine
            .split(separator: "#", maxSplits: 1, omittingEmptySubsequences: false)
            .first
            .map { String($0).trimmingCharacters(in: .whitespacesAndNewlines) }
            .flatMap { $0.isEmpty ? nil : $0 } ?? firstLine
        guard !stripped.isEmpty else { return nil }
        return String(stripped.prefix(80))
    }

    private static func cleanDouyinPageTitle(_ raw: String) -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        for suffix in [" - 抖音", "- 抖音", " - Douyin", "-抖音"] {
            if trimmed.hasSuffix(suffix) {
                return String(trimmed.dropLast(suffix.count)).trimmingCharacters(in: .whitespacesAndNewlines)
            }
        }
        return trimmed
    }

    private static func isBlockedTitle(_ title: String) -> Bool {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty || blockedTitles.contains { trimmed.contains($0) }
    }

    private static func extractTitle(in html: String) -> String? {
        guard let regex = try? NSRegularExpression(pattern: #"(?is)<title\b[^>]*>(.*?)</title>"#) else {
            return nil
        }
        let range = NSRange(html.startIndex..., in: html)
        guard let match = regex.firstMatch(in: html, range: range),
              let inner = Range(match.range(at: 1), in: html) else {
            return nil
        }
        let decoded = decodeHTML(String(html[inner])).trimmingCharacters(in: .whitespacesAndNewlines)
        return decoded.isEmpty ? nil : decoded
    }

    private static func extractMeta(_ name: String, in html: String) -> String? {
        guard let tagRegex = try? NSRegularExpression(pattern: #"(?is)<meta\b[^>]*>"#),
              let attrRegex = try? NSRegularExpression(pattern: #"(?is)([a-z][\w:-]*)\s*=\s*(?:"([^"]*)"|'([^']*)'|([^\s>]+))"#) else {
            return nil
        }
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
                return decodeHTML(content)
            }
        }
        return nil
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
