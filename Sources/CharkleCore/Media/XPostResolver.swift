import Foundation

/// Parsed identity of an X (Twitter) post URL.
public nonisolated struct XPostReference: Equatable, Hashable, Sendable {
    public let handle: String
    public let tweetID: String

    public var canonicalURL: URL {
        URL(string: "https://x.com/\(handle)/status/\(tweetID)")!
    }

    public init(handle: String, tweetID: String) {
        self.handle = handle
        self.tweetID = tweetID
    }
}

/// Detects and extracts X (Twitter) status links from URLs or copied share text.
public nonisolated enum XPostURLParser {
    private static let supportedHosts: Set<String> = [
        "x.com", "www.x.com", "mobile.x.com",
        "twitter.com", "www.twitter.com", "mobile.twitter.com",
        "fxtwitter.com", "www.fxtwitter.com",
        "vxtwitter.com", "www.vxtwitter.com",
        "fixupx.com", "www.fixupx.com",
        "fixvx.com", "www.fixvx.com"
    ]

    public static func parse(_ url: URL) -> XPostReference? {
        guard let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https",
              let host = url.host()?.lowercased(), supportedHosts.contains(host) else {
            return nil
        }

        let segments = url.pathComponents.filter { $0 != "/" && !$0.isEmpty }
        // Supported path shapes:
        // /<handle>/status/<id>[/photo/1]
        // /<handle>/statuses/<id>
        // /i/web/status/<id>
        // /i/status/<id>
        guard let statusIndex = segments.firstIndex(where: { $0.lowercased() == "status" || $0.lowercased() == "statuses" }),
              statusIndex + 1 < segments.count else {
            return nil
        }

        let rawID = segments[statusIndex + 1]
        guard !rawID.isEmpty, rawID.count <= 24, rawID.allSatisfy(\.isNumber) else {
            return nil
        }

        let rawHandle: String
        if statusIndex >= 1 {
            let candidate = segments[statusIndex - 1]
            if candidate.lowercased() == "web" && statusIndex >= 2 {
                rawHandle = segments[statusIndex - 2]
            } else {
                rawHandle = candidate
            }
        } else {
            rawHandle = "i"
        }

        let cleanHandle = rawHandle.trimmingCharacters(in: CharacterSet(charactersIn: "@"))
        guard !cleanHandle.isEmpty,
              cleanHandle.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "_") }) else {
            return XPostReference(handle: "i", tweetID: rawID)
        }

        return XPostReference(handle: cleanHandle, tweetID: rawID)
    }

    /// Extracts an X/Twitter status URL from raw clipboard text (including share strings with text + link).
    public static func extractStatusURL(from text: String) -> URL? {
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

public nonisolated struct XPostMedia: Equatable, Sendable {
    public enum Kind: String, Sendable {
        case photo
        case video
        case gif
    }

    public let kind: Kind
    public let url: URL
    public let thumbnailURL: URL?
    public let altText: String?

    public init(kind: Kind, url: URL, thumbnailURL: URL? = nil, altText: String? = nil) {
        self.kind = kind
        self.url = url
        self.thumbnailURL = thumbnailURL
        self.altText = altText
    }
}

public nonisolated struct ResolvedXPost: Equatable, Sendable {
    public let reference: XPostReference
    public let authorName: String
    public let authorHandle: String
    public let authorAvatarURL: String?
    public let text: String
    public let quotedAuthor: String?
    public let quotedText: String?
    public let articleTitle: String?
    public let createdAt: String?
    public let media: [XPostMedia]
    public let replyCount: Int?
    public let repostCount: Int?
    public let likeCount: Int?
    public let viewCount: Int?

    public init(
        reference: XPostReference,
        authorName: String,
        authorHandle: String,
        authorAvatarURL: String? = nil,
        text: String,
        quotedAuthor: String? = nil,
        quotedText: String? = nil,
        articleTitle: String? = nil,
        createdAt: String? = nil,
        media: [XPostMedia] = [],
        replyCount: Int? = nil,
        repostCount: Int? = nil,
        likeCount: Int? = nil,
        viewCount: Int? = nil
    ) {
        self.reference = reference
        self.authorName = authorName
        self.authorHandle = authorHandle
        self.authorAvatarURL = authorAvatarURL
        self.text = text
        self.quotedAuthor = quotedAuthor
        self.quotedText = quotedText
        self.articleTitle = articleTitle
        self.createdAt = createdAt
        self.media = media
        self.replyCount = replyCount
        self.repostCount = repostCount
        self.likeCount = likeCount
        self.viewCount = viewCount
    }

    public var canonicalURL: URL {
        URL(string: "https://x.com/\(authorHandle)/status/\(reference.tweetID)") ?? reference.canonicalURL
    }

    public var shortTitle: String {
        let headlineSource = articleTitle?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
            ?? text
                .replacingOccurrences(of: "\n", with: " ")
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .nilIfEmpty
        if let headline = headlineSource {
            let trimmed = String(headline.prefix(44))
            return "@\(authorHandle) · \(trimmed)"
        }
        return "@\(authorHandle) 的推文"
    }

    public var formattedNotes: String {
        var sections: [String] = []
        let header = authorName.isEmpty || authorName.caseInsensitiveCompare(authorHandle) == .orderedSame
            ? "@\(authorHandle)"
            : "\(authorName) (@\(authorHandle))"
        sections.append(header)
        if let articleTitle, !articleTitle.isEmpty {
            sections.append("【\(articleTitle)】")
        }
        if !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            sections.append(text.trimmingCharacters(in: .whitespacesAndNewlines))
        }
        if let quotedText, !quotedText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            let qPrefix = quotedAuthor.map { "引用 \($0)：" } ?? "引用推文："
            sections.append("\(qPrefix)\n\(quotedText.trimmingCharacters(in: .whitespacesAndNewlines))")
        }
        sections.append("原链接：\(canonicalURL.absoluteString)")
        return sections.joined(separator: "\n\n")
    }

    public var markdownDocument: String {
        var lines: [String] = []
        let display = authorName.isEmpty ? "@\(authorHandle)" : "\(authorName) (@\(authorHandle))"
        lines.append("# \(display)")
        if let createdAt, !createdAt.isEmpty {
            lines.append("_\(createdAt)_")
        }
        if let articleTitle, !articleTitle.isEmpty {
            lines.append("")
            lines.append("## \(articleTitle)")
        }
        let body = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if !body.isEmpty {
            lines.append("")
            lines.append(body)
        }
        if let quotedText, !quotedText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            lines.append("")
            if let quotedAuthor, !quotedAuthor.isEmpty {
                lines.append("> **\(quotedAuthor)**")
            }
            for line in quotedText.split(whereSeparator: \.isNewline) {
                lines.append("> \(line)")
            }
        }
        lines.append("")
        lines.append("原推文：\(canonicalURL.absoluteString)")
        return lines.joined(separator: "\n")
    }
}

/// Fetches full X/Twitter post metadata & media URLs via FxTwitter / VxTwitter public JSON APIs
/// and downloads attached high-resolution photos, GIFs, and MP4 videos locally.
public nonisolated enum XPostResolver {
    public static func resolve(_ ref: XPostReference) async -> ResolvedXPost? {
        if let fx = await fetchFxTwitter(ref) {
            return fx
        }
        return await fetchVxTwitter(ref)
    }

    @concurrent
    public static func downloadMedia(
        _ item: XPostMedia,
        to directory: URL,
        baseName: String
    ) async -> URL? {
        let candidateURLs: [URL] = {
            var list: [URL] = []
            if item.kind == .photo, let highRes = upgradedTwitterImageURL(item.url), highRes != item.url {
                list.append(highRes)
            }
            list.append(item.url)
            if let thumb = item.thumbnailURL, thumb != item.url {
                list.append(thumb)
            }
            return list
        }()

        let maxBytes: Int64 = item.kind == .photo ? 35_000_000 : 160_000_000

        for url in candidateURLs {
            if let saved = await downloadSingle(url: url, kind: item.kind, to: directory, baseName: baseName, maxBytes: maxBytes) {
                return saved
            }
        }
        return nil
    }

    // MARK: - FxTwitter Primary Resolver

    private nonisolated struct FxMediaItem: Decodable {
        let type: String?
        let url: String?
        let thumbnail_url: String?
        let altText: String?
    }

    private nonisolated struct FxMediaBlock: Decodable {
        let all: [FxMediaItem]?
        let photos: [FxMediaItem]?
        let videos: [FxMediaItem]?
    }

    private static func fetchFxTwitter(_ ref: XPostReference) async -> ResolvedXPost? {
        guard let apiURL = URL(string: "https://api.fxtwitter.com/\(ref.handle)/status/\(ref.tweetID)") else {
            return nil
        }
        guard let data = await fetchJSONData(from: apiURL) else { return nil }

        struct Response: Decodable {
            let tweet: Tweet?
        }
        struct Tweet: Decodable {
            let text: String?
            let raw_text: RawText?
            let author: Author?
            let created_at: String?
            let media: FxMediaBlock?
            let quote: QuotedTweet?
            let article: Article?
            let replies: Int?
            let retweets: Int?
            let likes: Int?
            let views: Int?
        }
        struct QuotedTweet: Decodable {
            let text: String?
            let raw_text: RawText?
            let author: Author?
            let media: FxMediaBlock?
        }
        struct RawText: Decodable {
            let text: String?
        }
        struct Author: Decodable {
            let name: String?
            let screen_name: String?
            let avatar_url: String?
        }
        struct Article: Decodable {
            let title: String?
            let preview_text: String?
            let cover_media: CoverMedia?
            struct CoverMedia: Decodable {
                let media_info: MediaInfo?
                struct MediaInfo: Decodable {
                    let original_img_url: String?
                }
            }
        }

        guard let decoded = try? JSONDecoder().decode(Response.self, from: data),
              let tweet = decoded.tweet else {
            return nil
        }

        let handle = tweet.author?.screen_name?.nilIfEmpty ?? ref.handle
        let name = tweet.author?.name?.nilIfEmpty ?? handle
        let mainText = tweet.raw_text?.text?.nilIfEmpty
            ?? tweet.text?.nilIfEmpty
            ?? tweet.article?.preview_text?.nilIfEmpty
            ?? ""

        var mediaItems = extractFxMedia(tweet.media)
        if mediaItems.isEmpty, let coverURLStr = tweet.article?.cover_media?.media_info?.original_img_url,
           let coverURL = URL(string: coverURLStr), WebBookmark.isWebURL(coverURL) {
            mediaItems.append(XPostMedia(kind: .photo, url: coverURL))
        }
        if mediaItems.isEmpty, let quoteMedia = tweet.quote?.media {
            mediaItems = extractFxMedia(quoteMedia)
        }

        let quotedAuthor: String? = tweet.quote?.author.flatMap { a in
            if let n = a.name?.nilIfEmpty, let h = a.screen_name?.nilIfEmpty { return "\(n) (@\(h))" }
            if let h = a.screen_name?.nilIfEmpty { return "@\(h)" }
            return a.name?.nilIfEmpty
        }
        let quotedText = tweet.quote?.raw_text?.text?.nilIfEmpty ?? tweet.quote?.text?.nilIfEmpty

        return ResolvedXPost(
            reference: ref,
            authorName: name,
            authorHandle: handle,
            authorAvatarURL: tweet.author?.avatar_url?.nilIfEmpty,
            text: mainText,
            quotedAuthor: quotedAuthor,
            quotedText: quotedText,
            articleTitle: tweet.article?.title?.nilIfEmpty,
            createdAt: tweet.created_at?.nilIfEmpty,
            media: mediaItems,
            replyCount: tweet.replies,
            repostCount: tweet.retweets,
            likeCount: tweet.likes,
            viewCount: tweet.views
        )
    }

    private static func extractFxMedia(_ block: FxMediaBlock?) -> [XPostMedia] {
        guard let block else { return [] }
        let rawList: [FxMediaItem]
        if let all = block.all, !all.isEmpty {
            rawList = all
        } else {
            rawList = (block.photos ?? []) + (block.videos ?? [])
        }
        var results: [XPostMedia] = []
        var seen = Set<String>()
        for item in rawList {
            guard let urlStr = item.url, let url = URL(string: urlStr), WebBookmark.isWebURL(url),
                  seen.insert(urlStr).inserted else { continue }
            let kind: XPostMedia.Kind = switch item.type?.lowercased() {
            case "video": .video
            case "gif", "animated_gif": .gif
            default: .photo
            }
            let thumb = item.thumbnail_url.flatMap(URL.init(string:)).flatMap { WebBookmark.isWebURL($0) ? $0 : nil }
            results.append(XPostMedia(kind: kind, url: url, thumbnailURL: thumb, altText: item.altText))
        }
        return results
    }

    // MARK: - VxTwitter Fallback Resolver

    private static func fetchVxTwitter(_ ref: XPostReference) async -> ResolvedXPost? {
        guard let apiURL = URL(string: "https://api.vxtwitter.com/\(ref.handle)/status/\(ref.tweetID)") else {
            return nil
        }
        guard let data = await fetchJSONData(from: apiURL) else { return nil }

        struct Response: Decodable {
            let text: String?
            let user_name: String?
            let user_screen_name: String?
            let user_profile_image_url: String?
            let date: String?
            let media_extended: [MediaItem]?
            let mediaURLs: [String]?
            let replies: Int?
            let retweets: Int?
            let likes: Int?
        }
        struct MediaItem: Decodable {
            let type: String?
            let url: String?
            let thumbnail_url: String?
            let altText: String?
        }

        guard let decoded = try? JSONDecoder().decode(Response.self, from: data) else {
            return nil
        }

        let handle = decoded.user_screen_name?.nilIfEmpty ?? ref.handle
        let name = decoded.user_name?.nilIfEmpty ?? handle
        let text = decoded.text ?? ""

        var media: [XPostMedia] = []
        var seen = Set<String>()
        for item in decoded.media_extended ?? [] {
            guard let urlStr = item.url, let url = URL(string: urlStr), WebBookmark.isWebURL(url),
                  seen.insert(urlStr).inserted else { continue }
            let kind: XPostMedia.Kind = switch item.type?.lowercased() {
            case "video": .video
            case "gif", "animated_gif": .gif
            default: .photo
            }
            let thumb = item.thumbnail_url.flatMap(URL.init(string:)).flatMap { WebBookmark.isWebURL($0) ? $0 : nil }
            media.append(XPostMedia(kind: kind, url: url, thumbnailURL: thumb, altText: item.altText))
        }
        if media.isEmpty {
            for urlStr in decoded.mediaURLs ?? [] {
                guard let url = URL(string: urlStr), WebBookmark.isWebURL(url), seen.insert(urlStr).inserted else { continue }
                let lower = url.pathExtension.lowercased()
                let kind: XPostMedia.Kind = (lower == "mp4" || lower == "mov") ? .video : .photo
                media.append(XPostMedia(kind: kind, url: url))
            }
        }

        return ResolvedXPost(
            reference: ref,
            authorName: name,
            authorHandle: handle,
            authorAvatarURL: decoded.user_profile_image_url?.nilIfEmpty,
            text: text,
            quotedAuthor: nil,
            quotedText: nil,
            articleTitle: nil,
            createdAt: decoded.date?.nilIfEmpty,
            media: media,
            replyCount: decoded.replies,
            repostCount: decoded.retweets,
            likeCount: decoded.likes,
            viewCount: nil
        )
    }

    // MARK: - Networking Helpers

    private static func fetchJSONData(from url: URL) async -> Data? {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 8
        config.timeoutIntervalForResource = 10
        let session = URLSession(configuration: config)
        defer { session.invalidateAndCancel() }

        var request = URLRequest(url: url, timeoutInterval: 8)
        request.setValue("Charkle/1.0 (+https://charkle.app)", forHTTPHeaderField: "User-Agent")
        request.setValue("application/json", forHTTPHeaderField: "Accept")

        guard let (data, response) = try? await session.data(for: request),
              let http = response as? HTTPURLResponse,
              (200..<300).contains(http.statusCode) else {
            return nil
        }
        return data
    }

    private static func downloadSingle(
        url: URL,
        kind: XPostMedia.Kind,
        to directory: URL,
        baseName: String,
        maxBytes: Int64
    ) async -> URL? {
        guard WebBookmark.isWebURL(url) else { return nil }
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 15
        config.timeoutIntervalForResource = 45
        let session = URLSession(configuration: config)
        defer { session.invalidateAndCancel() }

        var request = URLRequest(url: url, timeoutInterval: 15)
        if XiaohongshuURLParser.isXiaohongshuMediaHost(url.host()) {
            request.setValue(
                "Mozilla/5.0 (Macintosh; Intel Mac OS X 15_0) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.2 Safari/605.1.15",
                forHTTPHeaderField: "User-Agent"
            )
            request.setValue("https://www.xiaohongshu.com/", forHTTPHeaderField: "Referer")
            request.setValue("image/webp,image/avif,image/png,image/jpeg,*/*", forHTTPHeaderField: "Accept")
        } else {
            request.setValue("Charkle/1.0", forHTTPHeaderField: "User-Agent")
        }

        guard let (tempURL, response) = try? await session.download(for: request),
              let http = response as? HTTPURLResponse,
              (200..<300).contains(http.statusCode) else {
            return nil
        }
        defer { try? FileManager.default.removeItem(at: tempURL) }

        let size = Int64((try? tempURL.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
        guard size > 0, size <= maxBytes else { return nil }

        let ext = resolvedExtension(for: url, mimeType: http.mimeType, kind: kind)
        let destination = directory.appending(path: "\(baseName).\(ext)")
        try? FileManager.default.removeItem(at: destination)
        do {
            try FileManager.default.moveItem(at: tempURL, to: destination)
            return destination
        } catch {
            return nil
        }
    }

    private static func upgradedTwitterImageURL(_ url: URL) -> URL? {
        guard let host = url.host()?.lowercased(), host.contains("twimg.com"),
              var components = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
            return url
        }
        var items = components.queryItems ?? []
        if let idx = items.firstIndex(where: { $0.name == "name" }) {
            items[idx] = URLQueryItem(name: "name", value: "orig")
        } else {
            items.append(URLQueryItem(name: "name", value: "orig"))
        }
        components.queryItems = items
        return components.url
    }

    private static func resolvedExtension(for url: URL, mimeType: String?, kind: XPostMedia.Kind) -> String {
        if let mime = mimeType?.lowercased() {
            if mime.contains("mp4") { return "mp4" }
            if mime.contains("quicktime") { return "mov" }
            if mime.contains("webm") { return "webm" }
            if mime.contains("gif") { return "gif" }
            if mime.contains("png") { return "png" }
            if mime.contains("webp") { return "webp" }
            if mime.contains("jpeg") || mime.contains("jpg") { return "jpg" }
        }
        let pathExt = url.pathExtension.lowercased()
        if ["jpg", "jpeg", "png", "webp", "gif", "mp4", "mov", "webm"].contains(pathExt) {
            return pathExt == "jpeg" ? "jpg" : pathExt
        }
        if let format = URLComponents(url: url, resolvingAgainstBaseURL: false)?
            .queryItems?.first(where: { $0.name == "format" })?.value?.lowercased(),
           ["jpg", "jpeg", "png", "webp"].contains(format) {
            return format == "jpeg" ? "jpg" : format
        }
        return kind == .photo ? "jpg" : "mp4"
    }
}

private nonisolated extension String {
    var nilIfEmpty: String? {
        let trimmed = trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
