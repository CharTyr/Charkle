import Foundation
import ImageIO

/// Parsed identity of a supported social media or video post URL (X/Twitter, Threads, Bluesky, Xiaohongshu, Pixiv, Instagram, YouTube, Bilibili).
public nonisolated enum SocialPostReference: Equatable, Hashable, Sendable {
    case x(XPostReference)
    case threads(handle: String, postID: String, canonicalURL: URL)
    case bluesky(handle: String, rkey: String, canonicalURL: URL)
    case xiaohongshu(XiaohongshuNoteReference)
    case pixiv(illustID: String, canonicalURL: URL)
    case instagram(shortcode: String, canonicalURL: URL)
    case videoPlatform(VideoPlatformReference)

    public var platform: SocialPlatform {
        switch self {
        case .x: .x
        case .threads: .threads
        case .bluesky: .bluesky
        case .xiaohongshu: .xiaohongshu
        case .pixiv: .pixiv
        case .instagram: .instagram
        case .videoPlatform(let ref): ref.platform
        }
    }

    public var canonicalURL: URL {
        switch self {
        case .x(let ref): ref.canonicalURL
        case .threads(_, _, let url): url
        case .bluesky(_, _, let url): url
        case .xiaohongshu(let ref): ref.canonicalURL
        case .pixiv(_, let url): url
        case .instagram(_, let url): url
        case .videoPlatform(let ref): ref.canonicalURL
        }
    }

    /// Stable cross-platform deduplication key independent of query params (`xsec_token`, `s=20`, etc.).
    public var dedupKey: String {
        switch self {
        case .x(let ref): "x:\(ref.tweetID)"
        case .threads(_, let postID, _): "threads:\(postID)"
        case .bluesky(let handle, let rkey, _): "bsky:\(handle.lowercased()):\(rkey)"
        case .xiaohongshu(let ref): ref.dedupKey
        case .pixiv(let illustID, _): "pixiv:\(illustID)"
        case .instagram(let shortcode, _): "ig:\(shortcode)"
        case .videoPlatform(let ref): ref.dedupKey
        }
    }
}

/// Detects social post URLs across X/Twitter, Threads, Bluesky, Xiaohongshu, Pixiv, and Instagram.
public nonisolated enum SocialPostURLParser {
    private static let threadsHosts: Set<String> = [
        "threads.net", "www.threads.net",
        "threads.com", "www.threads.com"
    ]

    private static let blueskyHosts: Set<String> = [
        "bsky.app", "www.bsky.app"
    ]

    private static let pixivHosts: Set<String> = [
        "pixiv.net", "www.pixiv.net", "touch.pixiv.net"
    ]

    private static let instagramHosts: Set<String> = [
        "instagram.com", "www.instagram.com", "m.instagram.com"
    ]

    public static func parse(_ url: URL) -> SocialPostReference? {
        if let xRef = XPostURLParser.parse(url) {
            return .x(xRef)
        }
        if let xhsRef = XiaohongshuURLParser.parse(url) {
            return .xiaohongshu(xhsRef)
        }
        if let videoRef = VideoPlatformURLParser.parse(url) {
            return .videoPlatform(videoRef)
        }
        guard let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https",
              let host = url.host()?.lowercased() else {
            return nil
        }

        let segments = url.pathComponents.filter { $0 != "/" && !$0.isEmpty }

        if threadsHosts.contains(host) {
            // /@<handle>/post/<shortcode>  or  /t/<shortcode>
            if let postIdx = segments.firstIndex(where: { $0.lowercased() == "post" }),
               postIdx + 1 < segments.count {
                let rawHandle = postIdx >= 1 ? segments[postIdx - 1] : "threads"
                let cleanHandle = rawHandle.trimmingCharacters(in: CharacterSet(charactersIn: "@"))
                let code = segments[postIdx + 1]
                guard !cleanHandle.isEmpty, !code.isEmpty else { return nil }
                let canonical = URL(string: "https://www.threads.net/@\(cleanHandle)/post/\(code)") ?? url
                return .threads(handle: cleanHandle, postID: code, canonicalURL: canonical)
            }
            if segments.count >= 2 && segments[0].lowercased() == "t" {
                let code = segments[1]
                let canonical = URL(string: "https://www.threads.net/t/\(code)") ?? url
                return .threads(handle: "threads", postID: code, canonicalURL: canonical)
            }
        }

        if blueskyHosts.contains(host) {
            // /profile/<handle-or-did>/post/<rkey>
            if segments.count >= 4,
               segments[0].lowercased() == "profile",
               segments[2].lowercased() == "post" {
                let handle = segments[1]
                let rkey = segments[3]
                guard !handle.isEmpty, !rkey.isEmpty else { return nil }
                let canonical = URL(string: "https://bsky.app/profile/\(handle)/post/\(rkey)") ?? url
                return .bluesky(handle: handle, rkey: rkey, canonicalURL: canonical)
            }
        }

        if pixivHosts.contains(host) {
            // /artworks/<id>  or  /<locale>/artworks/<id>
            if let artIdx = segments.firstIndex(where: { $0.lowercased() == "artworks" }),
               artIdx + 1 < segments.count {
                let id = segments[artIdx + 1]
                if !id.isEmpty, id.count <= 20, id.allSatisfy({ $0.isASCII && $0.isNumber }) {
                    let canonical = URL(string: "https://www.pixiv.net/artworks/\(id)") ?? url
                    return .pixiv(illustID: id, canonicalURL: canonical)
                }
            }
            // Legacy: /member_illust.php?illust_id=<id>
            if segments.first?.lowercased() == "member_illust.php",
               let comps = URLComponents(url: url, resolvingAgainstBaseURL: false),
               let id = comps.queryItems?.first(where: { $0.name == "illust_id" })?.value,
               !id.isEmpty, id.count <= 20, id.allSatisfy({ $0.isASCII && $0.isNumber }) {
                let canonical = URL(string: "https://www.pixiv.net/artworks/\(id)") ?? url
                return .pixiv(illustID: id, canonicalURL: canonical)
            }
        }

        if instagramHosts.contains(host) {
            // /p/<shortcode>, /reel/<shortcode>, /tv/<shortcode>, or /<user>/p/<shortcode>, /<user>/reel/<shortcode>
            if let idx = segments.firstIndex(where: {
                let lower = $0.lowercased()
                return lower == "p" || lower == "reel" || lower == "reels" || lower == "tv"
            }), idx + 1 < segments.count {
                let code = segments[idx + 1]
                if !code.isEmpty, code.count <= 40,
                   code.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "_" || $0 == "-") }) {
                    let kindSegment = segments[idx].lowercased() == "reel" || segments[idx].lowercased() == "reels" ? "reel" : "p"
                    let canonical = URL(string: "https://www.instagram.com/\(kindSegment)/\(code)/") ?? url
                    return .instagram(shortcode: code, canonicalURL: canonical)
                }
            }
        }

        return nil
    }

    public static func extractPostURL(from text: String) -> URL? {
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
}

public nonisolated struct ResolvedSocialPost: Equatable, Sendable {
    public let metadata: SocialPostMetadata
    public let primaryMediaDownloadURL: URL?
    public let primaryMediaKind: XPostMedia.Kind?
    public let primaryThumbnailURL: URL?

    public var shortTitle: String {
        let candidate = metadata.articleTitle?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
            ?? metadata.bodyText
                .replacingOccurrences(of: "\n", with: " ")
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .nilIfEmpty
        let authorPrefix: String = {
            if metadata.platform == .xiaohongshu || metadata.platform.isVideoPlatform {
                return metadata.authorName.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
                    ?? metadata.platform.displayName
            }
            return "@\(metadata.authorHandle)"
        }()
        if metadata.platform.isVideoPlatform, let headline = candidate {
            return String(headline.prefix(64))
        }
        if let headline = candidate {
            let trimmed = String(headline.prefix(44))
            return "\(authorPrefix) · \(trimmed)"
        }
        return "\(authorPrefix) · \(metadata.platform.displayName)"
    }

    public var markdownDocument: String {
        var lines: [String] = []
        let display: String = {
            if let handleLine = metadata.displayHandleLine {
                return metadata.authorName.isEmpty
                    ? handleLine
                    : "\(metadata.authorName) (\(handleLine))"
            }
            return metadata.authorName.isEmpty ? metadata.platform.displayName : metadata.authorName
        }()
        lines.append("# \(display)")
        var sub: [String] = [metadata.platform.displayName]
        if let duration = metadata.formattedVideoDuration { sub.append(duration) }
        if let date = metadata.publishedAtText, !date.isEmpty { sub.append(date) }
        lines.append("_\(sub.joined(separator: " · "))_")
        if let articleTitle = metadata.articleTitle, !articleTitle.isEmpty {
            lines.append("")
            lines.append("## \(articleTitle)")
        }
        if let summary = metadata.videoSummary?.trimmingCharacters(in: .whitespacesAndNewlines), !summary.isEmpty {
            lines.append("")
            lines.append("### 视频摘要")
            lines.append(summary)
        }
        if !metadata.videoOutline.isEmpty {
            lines.append("")
            lines.append("### 章节要点")
            for item in metadata.videoOutline {
                lines.append("- \(item)")
            }
        }
        let body = metadata.bodyText.trimmingCharacters(in: .whitespacesAndNewlines)
        if !body.isEmpty {
            lines.append("")
            lines.append(body)
        }
        if let quotedText = metadata.quotedText, !quotedText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            lines.append("")
            if let quotedAuthor = metadata.quotedAuthor, !quotedAuthor.isEmpty {
                lines.append("> **\(quotedAuthor)**")
            }
            for line in quotedText.split(whereSeparator: \.isNewline) {
                lines.append("> \(line)")
            }
        }
        lines.append("")
        lines.append("原链接：\(metadata.originalURL)")
        return lines.joined(separator: "\n")
    }
}

/// Resolves full social post payloads across X, Bluesky, Threads, and Xiaohongshu.
public nonisolated enum SocialPostResolver {
    public static func resolve(_ ref: SocialPostReference) async -> ResolvedSocialPost? {
        switch ref {
        case .x(let xRef):
            return await resolveX(xRef)
        case .bluesky(let handle, let rkey, let canonicalURL):
            return await resolveBluesky(handle: handle, rkey: rkey, canonicalURL: canonicalURL)
        case .threads(let handle, _, let canonicalURL):
            return await resolveThreads(handle: handle, canonicalURL: canonicalURL)
        case .xiaohongshu(let xhsRef):
            return await XiaohongshuPostResolver.resolve(xhsRef)
        case .pixiv(let illustID, let canonicalURL):
            return await resolveOpenGraphFallback(platform: .pixiv, handle: illustID, canonicalURL: canonicalURL)
        case .instagram(let shortcode, let canonicalURL):
            return await resolveOpenGraphFallback(platform: .instagram, handle: shortcode, canonicalURL: canonicalURL)
        case .videoPlatform(let videoRef):
            return await VideoPlatformResolver.resolve(videoRef)
        }
    }

    /// Computes a stable cross-platform deduplication key for any social or generic URL string.
    public static func canonicalDedupKey(for rawURLString: String) -> String? {
        let trimmed = rawURLString.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let url = URL(string: trimmed) else { return nil }
        if let ref = SocialPostURLParser.parse(url) {
            return ref.dedupKey
        }
        return "url:\(trimmed.lowercased())"
    }

    private static let avatarSession: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.httpMaximumConnectionsPerHost = 6
        config.timeoutIntervalForRequest = 4
        config.timeoutIntervalForResource = 5
        config.urlCache = nil
        return URLSession(configuration: config)
    }()

    /// Downloads the author's profile avatar (upgrading tiny `_normal` X avatars to `_400x400` when applicable)
    /// for crisp circular compositing on social post gallery thumbnails.
    public static func fetchAvatarImage(from rawURL: String?) async -> CGImage? {
        guard let trimmed = rawURL?.trimmingCharacters(in: .whitespacesAndNewlines), !trimmed.isEmpty else {
            return nil
        }
        var candidates: [String] = []
        if trimmed.contains("pbs.twimg.com/profile_images/") && trimmed.contains("_normal.") {
            candidates.append(trimmed.replacingOccurrences(of: "_normal.", with: "_400x400."))
        }
        candidates.append(trimmed)

        for candidate in candidates {
            guard let url = URL(string: candidate), WebBookmark.isSafeRemoteFetchURL(url) else { continue }
            var req = URLRequest(url: url, timeoutInterval: 4)
            if XiaohongshuURLParser.isXiaohongshuMediaHost(url.host()) {
                req.setValue("Mozilla/5.0 (Macintosh; Intel Mac OS X 15_0) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.2 Safari/605.1.15", forHTTPHeaderField: "User-Agent")
                req.setValue("https://www.xiaohongshu.com/", forHTTPHeaderField: "Referer")
            } else if VideoPlatformURLParser.isBilibiliMediaHost(url.host()) {
                req.setValue("Mozilla/5.0 (Macintosh; Intel Mac OS X 15_0) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.2 Safari/605.1.15", forHTTPHeaderField: "User-Agent")
                req.setValue("https://www.bilibili.com/", forHTTPHeaderField: "Referer")
            } else {
                req.setValue("Charkle/1.0 (+https://charkle.app)", forHTTPHeaderField: "User-Agent")
            }
            req.setValue("image/webp,image/png,image/jpeg,image/*", forHTTPHeaderField: "Accept")
            guard let (data, response) = try? await avatarSession.data(for: req),
                  let http = response as? HTTPURLResponse,
                  (200..<300).contains(http.statusCode),
                  let finalURL = http.url, WebBookmark.isSafeRemoteFetchURL(finalURL),
                  data.count <= 4 * 1024 * 1024,
                  let src = CGImageSourceCreateWithData(data as CFData, nil),
                  let cg = MediaPipeline.raster(src)?.poster,
                  cg.width >= 16, cg.height >= 16 else {
                continue
            }
            return cg
        }
        return nil
    }

    private static func resolveX(_ ref: XPostReference) async -> ResolvedSocialPost? {
        guard let post = await XPostResolver.resolve(ref) else { return nil }
        let videoItem = post.media.first(where: { $0.kind == .video || $0.kind == .gif })
        let attachments: [SocialMediaAttachment] = post.media.map { item in
            let kind: SocialMediaAttachment.Kind = switch item.kind {
            case .photo: .photo
            case .video: .video
            case .gif: .gif
            }
            return SocialMediaAttachment(
                kind: kind,
                url: item.url.absoluteString,
                thumbnailURL: (item.thumbnailURL ?? (item.kind == .photo ? item.url : nil))?.absoluteString
            )
        }
        let mediaURLs = attachments.map(\.url)
        let thumbURLs = attachments.compactMap { $0.thumbnailURL ?? ($0.kind == .photo ? $0.url : nil) }
        // Prefer downloading video when present so inline playback works immediately offline.
        let primary = videoItem ?? post.media.first

        let meta = SocialPostMetadata(
            platform: .x,
            authorName: post.authorName,
            authorHandle: post.authorHandle,
            authorAvatarURL: post.authorAvatarURL,
            publishedAtText: post.createdAt,
            bodyText: post.text,
            quotedAuthor: post.quotedAuthor,
            quotedText: post.quotedText,
            articleTitle: post.articleTitle,
            mediaURLs: mediaURLs,
            mediaThumbnailURLs: thumbURLs,
            attachments: attachments,
            hasVideo: videoItem != nil,
            videoURL: videoItem?.url.absoluteString,
            replyCount: post.replyCount,
            repostCount: post.repostCount,
            likeCount: post.likeCount,
            viewCount: post.viewCount,
            originalURL: post.canonicalURL.absoluteString,
            mediaFetchFailed: false
        )
        return ResolvedSocialPost(
            metadata: meta,
            primaryMediaDownloadURL: primary?.url,
            primaryMediaKind: primary?.kind,
            primaryThumbnailURL: primary?.thumbnailURL ?? (primary?.kind == .photo ? primary?.url : nil)
        )
    }

    // MARK: - Bluesky Public AppView API

    private static func resolveBluesky(handle: String, rkey: String, canonicalURL: URL) async -> ResolvedSocialPost? {
        let did: String
        if handle.hasPrefix("did:") {
            did = handle
        } else if let resolved = await resolveBlueskyHandle(handle) {
            did = resolved
        } else {
            return await resolveOpenGraphFallback(platform: .bluesky, handle: handle, canonicalURL: canonicalURL)
        }

        let atURI = "at://\(did)/app.bsky.feed.post/\(rkey)"
        var comps = URLComponents(string: "https://public.api.bsky.app/xrpc/app.bsky.feed.getPostThread")
        comps?.queryItems = [
            URLQueryItem(name: "uri", value: atURI),
            URLQueryItem(name: "depth", value: "0")
        ]
        guard let url = comps?.url, let data = await fetchJSON(url) else {
            return await resolveOpenGraphFallback(platform: .bluesky, handle: handle, canonicalURL: canonicalURL)
        }

        struct ThreadResp: Decodable {
            let thread: ThreadNode?
        }
        struct ThreadNode: Decodable {
            let post: BskyPost?
        }
        struct BskyPost: Decodable {
            let author: BskyAuthor?
            let record: BskyRecord?
            let embed: BskyEmbed?
            let replyCount: Int?
            let repostCount: Int?
            let likeCount: Int?
            let indexedAt: String?
        }
        struct BskyAuthor: Decodable {
            let handle: String?
            let displayName: String?
            let avatar: String?
        }
        struct BskyRecord: Decodable {
            let text: String?
            let createdAt: String?
        }
        struct BskyEmbed: Decodable {
            let images: [BskyImage]?
            let thumbnail: String?
            let playlist: String?
            let media: NestedMedia?
            struct NestedMedia: Decodable {
                let images: [BskyImage]?
                let thumbnail: String?
            }
        }
        struct BskyImage: Decodable {
            let fullsize: String?
            let thumb: String?
        }

        guard let resp = try? JSONDecoder().decode(ThreadResp.self, from: data),
              let post = resp.thread?.post else {
            return await resolveOpenGraphFallback(platform: .bluesky, handle: handle, canonicalURL: canonicalURL)
        }

        let authorHandle = post.author?.handle?.nilIfEmpty ?? handle
        let authorName = post.author?.displayName?.nilIfEmpty ?? authorHandle
        let bodyText = post.record?.text ?? ""
        let images = post.embed?.images ?? post.embed?.media?.images ?? []
        let mediaURLs = images.compactMap { $0.fullsize ?? $0.thumb }
        let videoThumb = post.embed?.thumbnail ?? post.embed?.media?.thumbnail
        let hasVideo = post.embed?.playlist != nil || (mediaURLs.isEmpty && videoThumb != nil)
        let thumbURLs = images.compactMap { $0.thumb ?? $0.fullsize } + (videoThumb.map { [$0] } ?? [])

        let primaryURL = (mediaURLs.first ?? videoThumb).flatMap(URL.init(string:))
        let primaryThumb = (thumbURLs.first).flatMap(URL.init(string:))
        var attachments: [SocialMediaAttachment] = images.compactMap { img in
            guard let u = img.fullsize ?? img.thumb else { return nil }
            return SocialMediaAttachment(kind: .photo, url: u, thumbnailURL: img.thumb ?? img.fullsize)
        }
        if let playlist = post.embed?.playlist, !playlist.isEmpty {
            attachments.append(SocialMediaAttachment(kind: .video, url: playlist, thumbnailURL: videoThumb))
        }

        let meta = SocialPostMetadata(
            platform: .bluesky,
            authorName: authorName,
            authorHandle: authorHandle,
            authorAvatarURL: post.author?.avatar?.nilIfEmpty,
            publishedAtText: (post.record?.createdAt ?? post.indexedAt).map { String($0.prefix(16)).replacingOccurrences(of: "T", with: " ") },
            bodyText: bodyText,
            mediaURLs: mediaURLs,
            mediaThumbnailURLs: thumbURLs,
            attachments: attachments,
            hasVideo: hasVideo,
            videoURL: post.embed?.playlist,
            replyCount: post.replyCount,
            repostCount: post.repostCount,
            likeCount: post.likeCount,
            originalURL: canonicalURL.absoluteString,
            mediaFetchFailed: false
        )
        return ResolvedSocialPost(
            metadata: meta,
            primaryMediaDownloadURL: primaryURL,
            // Bluesky video embeds expose HLS `.m3u8` playlists and JPEG thumbnails; download `primaryURL` as a photo poster.
            primaryMediaKind: primaryURL != nil ? .photo : nil,
            primaryThumbnailURL: primaryThumb
        )
    }

    private static func resolveBlueskyHandle(_ handle: String) async -> String? {
        var comps = URLComponents(string: "https://public.api.bsky.app/xrpc/com.atproto.identity.resolveHandle")
        comps?.queryItems = [URLQueryItem(name: "handle", value: handle)]
        guard let url = comps?.url, let data = await fetchJSON(url) else { return nil }
        struct Resp: Decodable { let did: String? }
        return (try? JSONDecoder().decode(Resp.self, from: data))?.did
    }

    // MARK: - Threads / OpenGraph Fallback

    private static func resolveThreads(handle: String, canonicalURL: URL) async -> ResolvedSocialPost? {
        await resolveOpenGraphFallback(platform: .threads, handle: handle, canonicalURL: canonicalURL)
    }

    private static func resolveOpenGraphFallback(
        platform: SocialPlatform,
        handle: String,
        canonicalURL: URL
    ) async -> ResolvedSocialPost {
        let html = await fetchHTML(canonicalURL)
        let ogTitle = html.flatMap { extractMeta("og:title", in: $0) }
        let ogDesc = html.flatMap { extractMeta("og:description", in: $0) ?? extractMeta("description", in: $0) }
        let ogImage = html.flatMap { extractMeta("og:image", in: $0) }

        let authorName: String = {
            if let ogTitle, let range = ogTitle.range(of: " (@") {
                return String(ogTitle[..<range.lowerBound]).trimmingCharacters(in: .whitespacesAndNewlines)
            }
            if let ogTitle, let range = ogTitle.range(of: " on ") {
                return String(ogTitle[..<range.lowerBound]).trimmingCharacters(in: .whitespacesAndNewlines)
            }
            return handle
        }()

        let body = ogDesc?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let imageURL = ogImage.flatMap(URL.init(string:)).flatMap { WebBookmark.isWebURL($0) ? $0 : nil }

        let meta = SocialPostMetadata(
            platform: platform,
            authorName: authorName.isEmpty ? handle : authorName,
            authorHandle: handle,
            bodyText: body.isEmpty ? canonicalURL.absoluteString : body,
            mediaURLs: imageURL.map { [$0.absoluteString] } ?? [],
            mediaThumbnailURLs: imageURL.map { [$0.absoluteString] } ?? [],
            originalURL: canonicalURL.absoluteString,
            mediaFetchFailed: false
        )
        return ResolvedSocialPost(
            metadata: meta,
            primaryMediaDownloadURL: imageURL,
            primaryMediaKind: imageURL != nil ? .photo : nil,
            primaryThumbnailURL: imageURL
        )
    }

    // MARK: - Helpers

    private static func fetchJSON(_ url: URL) async -> Data? {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 8
        config.timeoutIntervalForResource = 10
        let session = URLSession(configuration: config)
        defer { session.invalidateAndCancel() }
        var req = URLRequest(url: url, timeoutInterval: 8)
        req.setValue("Charkle/1.0 (+https://charkle.app)", forHTTPHeaderField: "User-Agent")
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        guard let (data, response) = try? await session.data(for: req),
              let http = response as? HTTPURLResponse,
              (200..<300).contains(http.statusCode) else { return nil }
        return data
    }

    private static func fetchHTML(_ url: URL) async -> String? {
        let config = URLSessionConfiguration.ephemeral
        config.httpShouldSetCookies = false
        config.timeoutIntervalForRequest = 8
        config.timeoutIntervalForResource = 10
        let session = URLSession(configuration: config)
        defer { session.invalidateAndCancel() }
        var req = URLRequest(url: url, timeoutInterval: 8)
        req.setValue("Mozilla/5.0 (Macintosh; Intel Mac OS X 15_0) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.0 Safari/605.1.15", forHTTPHeaderField: "User-Agent")
        guard let (data, response) = try? await session.data(for: req),
              let http = response as? HTTPURLResponse,
              (200..<300).contains(http.statusCode) else { return nil }
        return String(decoding: data.prefix(524_288), as: UTF8.self)
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

private extension String {
    nonisolated var nilIfEmpty: String? {
        let trimmed = trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
