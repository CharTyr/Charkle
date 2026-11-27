import AVFoundation
import CoreImage
import CryptoKit
import Foundation
import ImageIO

/// Parsed identity of a YouTube or Bilibili video URL.
public nonisolated enum VideoPlatformReference: Equatable, Hashable, Sendable {
    case youtube(videoID: String, canonicalURL: URL)
    case bilibili(bvid: String?, aid: Int64?, shortURL: URL?, page: Int?, canonicalURL: URL)

    public var platform: SocialPlatform {
        switch self {
        case .youtube: .youtube
        case .bilibili: .bilibili
        }
    }

    public var canonicalURL: URL {
        switch self {
        case .youtube(_, let url): url
        case .bilibili(_, _, _, _, let url): url
        }
    }

    public var dedupKey: String {
        switch self {
        case .youtube(let id, _):
            return "yt:\(id)"
        case .bilibili(let bvid, let aid, let shortURL, let page, _):
            let pageSuffix = (page ?? 1) > 1 ? ":p\(page!)" : ""
            if let bvid, !bvid.isEmpty {
                return "bili:\(bvid)\(pageSuffix)"
            }
            if let aid {
                return "bili:av\(aid)\(pageSuffix)"
            }
            return "bili:short:\(shortURL?.lastPathComponent ?? canonicalURL.absoluteString)"
        }
    }
}

public nonisolated enum VideoPlatformDownloadError: LocalizedError, Sendable {
    case unsupportedURL
    case metadataUnavailable(String)
    case streamUnavailable(String)
    case downloadFailed(String)

    public var errorDescription: String? {
        switch self {
        case .unsupportedURL:
            "无法识别该视频链接。"
        case .metadataUnavailable(let detail):
            "无法获取视频信息：\(detail)"
        case .streamUnavailable(let detail):
            detail
        case .downloadFailed(let detail):
            "视频保存失败：\(detail)"
        }
    }
}

/// Zero-download streaming playback descriptor for bookmarked video-site items
/// (YouTube, Bilibili, Vimeo, Dailymotion, and generic rich webpages with discovered video streams).
public nonisolated struct VideoStreamPlaybackPlan: Equatable, Hashable, Sendable {
    public struct DirectStream: Equatable, Hashable, Sendable {
        public let url: URL
        public let httpHeaders: [String: String]
        public let isHLS: Bool
        public let overrideMIMEType: String?

        public init(
            url: URL,
            httpHeaders: [String: String] = [:],
            isHLS: Bool = false,
            overrideMIMEType: String? = nil
        ) {
            self.url = url
            self.httpHeaders = httpHeaders
            self.isHLS = isHLS
            self.overrideMIMEType = overrideMIMEType
        }
    }

    public struct EmbedPlayer: Equatable, Hashable, Sendable {
        public let url: URL
        public let referer: String
        public let userAgent: String?
        public let useIframeWrapper: Bool

        public init(
            url: URL,
            referer: String,
            userAgent: String? = nil,
            useIframeWrapper: Bool = true
        ) {
            self.url = url
            self.referer = referer
            self.userAgent = userAgent
            self.useIframeWrapper = useIframeWrapper
        }
    }

    /// Ordered native `AVPlayer` streaming candidates (HTTP Range MP4 or HLS `.m3u8`).
    public let directStreams: [DirectStream]
    /// Official embedded `WKWebView` streaming player fallback (zero disk download).
    public let embedPlayer: EmbedPlayer?
    /// Canonical watch URL for external browser fallback.
    public let watchURL: URL?

    public init(
        directStreams: [DirectStream] = [],
        embedPlayer: EmbedPlayer? = nil,
        watchURL: URL? = nil
    ) {
        self.directStreams = directStreams
        self.embedPlayer = embedPlayer
        self.watchURL = watchURL
    }

    public var hasPlayableSource: Bool {
        !directStreams.isEmpty || embedPlayer != nil
    }
}

/// Detects YouTube (`youtube.com`, `youtu.be`, `shorts`, `live`, `embed`) and Bilibili (`bilibili.com/video/BV...`, `av...`, `b23.tv/...`) URLs.
public nonisolated enum VideoPlatformURLParser {
    private static let youtubeHosts: Set<String> = [
        "youtube.com", "www.youtube.com", "m.youtube.com", "music.youtube.com",
        "youtu.be", "www.youtu.be", "youtube-nocookie.com", "www.youtube-nocookie.com"
    ]

    private static let bilibiliHosts: Set<String> = [
        "bilibili.com", "www.bilibili.com", "m.bilibili.com"
    ]

    private static let bilibiliShortHosts: Set<String> = [
        "b23.tv", "www.b23.tv", "bili2233.cn", "www.bili2233.cn"
    ]

    public static func isBilibiliMediaHost(_ host: String?) -> Bool {
        guard let h = host?.lowercased() else { return false }
        return h == "hdslb.com"
            || h.hasSuffix(".hdslb.com")
            || h == "bilivideo.com"
            || h.hasSuffix(".bilivideo.com")
            || h == "bilivideo.cn"
            || h.hasSuffix(".bilivideo.cn")
            || h == "bilibili.com"
            || h.hasSuffix(".bilibili.com")
    }

    public static func parse(_ url: URL) -> VideoPlatformReference? {
        guard let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https",
              let host = url.host()?.lowercased() else {
            return nil
        }

        let segments = url.pathComponents.filter { $0 != "/" && !$0.isEmpty }
        let comps = URLComponents(url: url, resolvingAgainstBaseURL: false)

        if youtubeHosts.contains(host) {
            if let videoID = extractYouTubeVideoID(host: host, segments: segments, queryItems: comps?.queryItems) {
                let canonical = URL(string: "https://www.youtube.com/watch?v=\(videoID)") ?? url
                return .youtube(videoID: videoID, canonicalURL: canonical)
            }
            return nil
        }

        if bilibiliHosts.contains(host) {
            let page = comps?.queryItems?.first(where: { $0.name.lowercased() == "p" })?.value.flatMap(Int.init)
            let normalizedPage = (page ?? 1) > 1 ? page : nil

            for seg in segments {
                if let bvid = extractBVID(from: seg) {
                    let suffix = normalizedPage.map { "?p=\($0)" } ?? ""
                    let canonical = URL(string: "https://www.bilibili.com/video/\(bvid)\(suffix)") ?? url
                    return .bilibili(bvid: bvid, aid: nil, shortURL: nil, page: normalizedPage, canonicalURL: canonical)
                }
                if let aid = extractAID(from: seg) {
                    let suffix = normalizedPage.map { "?p=\($0)" } ?? ""
                    let canonical = URL(string: "https://www.bilibili.com/video/av\(aid)\(suffix)") ?? url
                    return .bilibili(bvid: nil, aid: aid, shortURL: nil, page: normalizedPage, canonicalURL: canonical)
                }
            }
            return nil
        }

        if bilibiliShortHosts.contains(host), let code = segments.first, !code.isEmpty {
            if let bvid = extractBVID(from: code) {
                let canonical = URL(string: "https://www.bilibili.com/video/\(bvid)") ?? url
                return .bilibili(bvid: bvid, aid: nil, shortURL: url, page: nil, canonicalURL: canonical)
            }
            if let aid = extractAID(from: code) {
                let canonical = URL(string: "https://www.bilibili.com/video/av\(aid)") ?? url
                return .bilibili(bvid: nil, aid: aid, shortURL: url, page: nil, canonicalURL: canonical)
            }
            let canonical = URL(string: "https://b23.tv/\(code)") ?? url
            return .bilibili(bvid: nil, aid: nil, shortURL: canonical, page: nil, canonicalURL: canonical)
        }

        return nil
    }

    public static func isValidYouTubeID(_ raw: String) -> Bool {
        guard raw.count == 11 else { return false }
        return raw.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "_" || $0 == "-") }
    }

    private static func extractYouTubeVideoID(host: String, segments: [String], queryItems: [URLQueryItem]?) -> String? {
        if host == "youtu.be" || host == "www.youtu.be" {
            if let first = segments.first, isValidYouTubeID(first) {
                return first
            }
            return nil
        }
        if let v = queryItems?.first(where: { $0.name == "v" })?.value, isValidYouTubeID(v) {
            return v
        }
        if segments.count >= 2 {
            let prefix = segments[0].lowercased()
            if (prefix == "shorts" || prefix == "live" || prefix == "embed" || prefix == "v"),
               isValidYouTubeID(segments[1]) {
                return segments[1]
            }
        }
        return nil
    }

    public static func extractBVID(from segment: String) -> String? {
        let clean = segment.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        guard clean.hasPrefix("BV"), clean.count == 12 else { return nil }
        guard clean.dropFirst(2).allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber) }) else { return nil }
        return clean
    }

    public static func extractAID(from segment: String) -> Int64? {
        let lower = segment.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        guard lower.hasPrefix("av"), lower.count > 2 else { return nil }
        let digits = lower.dropFirst(2)
        guard digits.allSatisfy({ $0.isASCII && $0.isNumber }) else { return nil }
        return Int64(digits)
    }
}

// MARK: - Bilibili WBI Signer Cache

private actor BilibiliWBICache {
    static let shared = BilibiliWBICache()

    private var cachedImgKey: String?
    private var cachedSubKey: String?
    private var fetchedAt: Date = .distantPast

    func keys(session: URLSession, userAgent: String) async -> (imgKey: String, subKey: String)? {
        if let img = cachedImgKey, let sub = cachedSubKey, Date().timeIntervalSince(fetchedAt) < 1800 {
            return (img, sub)
        }
        guard let url = URL(string: "https://api.bilibili.com/x/web-interface/nav") else { return nil }
        var req = URLRequest(url: url, timeoutInterval: 8)
        req.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        req.setValue("https://www.bilibili.com/", forHTTPHeaderField: "Referer")
        guard let (data, resp) = try? await session.data(for: req),
              let http = resp as? HTTPURLResponse,
              (200..<300).contains(http.statusCode),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let dataObj = json["data"] as? [String: Any],
              let wbiImg = dataObj["wbi_img"] as? [String: Any],
              let imgURLStr = wbiImg["img_url"] as? String,
              let subURLStr = wbiImg["sub_url"] as? String else {
            return nil
        }
        let imgKey = URL(string: imgURLStr)?.deletingPathExtension().lastPathComponent ?? ""
        let subKey = URL(string: subURLStr)?.deletingPathExtension().lastPathComponent ?? ""
        guard !imgKey.isEmpty, !subKey.isEmpty else { return nil }
        cachedImgKey = imgKey
        cachedSubKey = subKey
        fetchedAt = Date()
        return (imgKey, subKey)
    }
}

/// Cross-platform (macOS + iOS) YouTube & Bilibili bookmark metadata/summary resolver and
/// explicit on-demand video saver:
/// - Default `resolve(...)` fetches ONLY link metadata, cover thumbnail URL, and video summary / chapters
///   (leaving `primaryMediaDownloadURL == nil` so zero video bytes are downloaded on bookmark).
/// - `downloadVideo(for:to:baseName:)` runs ONLY when the user explicitly requests saving the video as
///   a standalone library asset.
public nonisolated enum VideoPlatformResolver {
    private static let browserUA = "Mozilla/5.0 (Macintosh; Intel Mac OS X 15_0) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.2 Safari/605.1.15"
    private static let iosYouTubeUA = "com.google.ios.youtube/19.29.1 (iPhone16,2; U; CPU iOS 17_5_1 like Mac OS X;)"
    private static let androidYouTubeUA = "com.google.android.youtube/19.29.37 (Linux; U; Android 14) gzip"

    private static let mixinKeyEncTab: [Int] = [
        46, 47, 18, 2, 53, 8, 23, 32, 15, 50, 10, 31, 58, 3, 45, 35,
        27, 43, 5, 49, 33, 9, 42, 19, 29, 28, 14, 39, 12, 38, 41, 13,
        37, 48, 7, 16, 24, 55, 40, 61, 26, 17, 0, 1, 60, 51, 30, 4,
        22, 25, 54, 21, 56, 59, 6, 63, 57, 62, 11, 36, 20, 34, 44, 52
    ]

    private static let apiSession: URLSession = {
        let cfg = URLSessionConfiguration.ephemeral
        cfg.timeoutIntervalForRequest = 10
        cfg.timeoutIntervalForResource = 16
        cfg.httpMaximumConnectionsPerHost = 6
        return URLSession(configuration: cfg)
    }()

    private static let downloadSession: URLSession = {
        let cfg = URLSessionConfiguration.ephemeral
        cfg.timeoutIntervalForRequest = 25
        cfg.timeoutIntervalForResource = 300
        cfg.httpMaximumConnectionsPerHost = 4
        return URLSession(configuration: cfg)
    }()

    // MARK: - 1. Default Metadata + Cover + Video Summary Resolution (NO Video Download)

    public static func resolve(_ ref: VideoPlatformReference) async -> ResolvedSocialPost? {
        switch ref {
        case .bilibili(let bvid, let aid, let shortURL, let page, let canonicalURL):
            return await resolveBilibili(
                bvid: bvid,
                aid: aid,
                shortURL: shortURL,
                page: page,
                fallbackCanonicalURL: canonicalURL
            )
        case .youtube(let videoID, let canonicalURL):
            return await resolveYouTube(videoID: videoID, canonicalURL: canonicalURL)
        }
    }

    // MARK: - Bilibili Metadata + AI Summary (`x/web-interface/view` + `conclusion/get`)

    private static func resolveBilibili(
        bvid initialBVID: String?,
        aid initialAID: Int64?,
        shortURL: URL?,
        page initialPage: Int?,
        fallbackCanonicalURL: URL
    ) async -> ResolvedSocialPost? {
        var bvid = initialBVID
        var aid = initialAID
        var page = initialPage

        // Expand `b23.tv` short links if we don't have BV/AV yet
        if bvid == nil, aid == nil, let shortURL {
            if let expanded = await expandShortRedirect(shortURL),
               case .bilibili(let rbv, let raid, _, let rpage, _) = VideoPlatformURLParser.parse(expanded) {
                bvid = rbv
                aid = raid
                page = page ?? rpage
            }
        }

        guard bvid != nil || aid != nil else { return nil }

        guard let viewInfo = await fetchBilibiliViewInfo(bvid: bvid, aid: aid, page: page) else {
            return nil
        }

        let canonicalSuffix = (page ?? 1) > 1 ? "?p=\(page!)" : ""
        let canonicalURL = URL(string: "https://www.bilibili.com/video/\(viewInfo.bvid)\(canonicalSuffix)") ?? fallbackCanonicalURL

        // Fetch Bilibili official AI Video Summary (`x/web-interface/view/conclusion/get`) with WBI signature
        let aiSummaryResult = await fetchBilibiliAISummary(
            bvid: viewInfo.bvid,
            cid: viewInfo.cid,
            upMid: viewInfo.ownerMid
        )

        let descriptionChapters = extractTimestampChapters(from: viewInfo.desc)
        let finalOutline = !aiSummaryResult.outline.isEmpty ? aiSummaryResult.outline : descriptionChapters
        let finalSummary = aiSummaryResult.summary

        let coverURLString = viewInfo.coverURL?.absoluteString
        let attachment = SocialMediaAttachment(
            kind: .video,
            url: canonicalURL.absoluteString,
            thumbnailURL: coverURLString
        )

        let metadata = SocialPostMetadata(
            platform: .bilibili,
            authorName: viewInfo.ownerName,
            authorHandle: viewInfo.ownerMid > 0 ? "UP \(viewInfo.ownerMid)" : "bilibili",
            authorAvatarURL: viewInfo.ownerFaceURL?.absoluteString,
            publishedAtText: viewInfo.publishedDateText,
            bodyText: viewInfo.desc,
            articleTitle: viewInfo.title,
            mediaURLs: coverURLString.map { [$0] } ?? [],
            mediaThumbnailURLs: coverURLString.map { [$0] } ?? [],
            attachments: [attachment],
            hasVideo: true,
            videoURL: canonicalURL.absoluteString,
            replyCount: viewInfo.replyCount,
            repostCount: viewInfo.shareCount,
            likeCount: viewInfo.likeCount,
            viewCount: viewInfo.viewCount,
            originalURL: canonicalURL.absoluteString,
            mediaFetchFailed: false,
            videoDurationSeconds: viewInfo.durationSeconds,
            videoSummary: finalSummary,
            videoOutline: finalOutline,
            videoID: viewInfo.bvid,
            videoCID: viewInfo.cid
        )

        // IMPORTANT: `primaryMediaDownloadURL` and `primaryMediaKind` stay nil on default bookmark
        // so ONLY the cover thumbnail + metadata + AI summary are saved; video downloads ONLY on explicit action.
        return ResolvedSocialPost(
            metadata: metadata,
            primaryMediaDownloadURL: nil,
            primaryMediaKind: nil,
            primaryThumbnailURL: viewInfo.coverURL
        )
    }

    private struct BilibiliViewInfo: Sendable {
        let bvid: String
        let aid: Int64
        let cid: Int64
        let title: String
        let desc: String
        let coverURL: URL?
        let durationSeconds: Double
        let publishedDateText: String?
        let ownerName: String
        let ownerMid: Int64
        let ownerFaceURL: URL?
        let viewCount: Int?
        let likeCount: Int?
        let replyCount: Int?
        let shareCount: Int?
    }

    private static func fetchBilibiliViewInfo(bvid: String?, aid: Int64?, page: Int?) async -> BilibiliViewInfo? {
        var comps = URLComponents(string: "https://api.bilibili.com/x/web-interface/view")
        if let bvid, !bvid.isEmpty {
            comps?.queryItems = [URLQueryItem(name: "bvid", value: bvid)]
        } else if let aid {
            comps?.queryItems = [URLQueryItem(name: "aid", value: "\(aid)")]
        } else {
            return nil
        }
        guard let url = comps?.url else { return nil }

        var req = URLRequest(url: url, timeoutInterval: 10)
        req.setValue(browserUA, forHTTPHeaderField: "User-Agent")
        req.setValue("https://www.bilibili.com/", forHTTPHeaderField: "Referer")

        guard let (data, resp) = try? await apiSession.data(for: req),
              let http = resp as? HTTPURLResponse,
              (200..<300).contains(http.statusCode),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              (root["code"] as? Int) == 0,
              let info = root["data"] as? [String: Any] else {
            return nil
        }

        let resolvedBVID = (info["bvid"] as? String) ?? bvid ?? ""
        let resolvedAID = int64Value(info["aid"]) ?? aid ?? 0
        var resolvedCID = int64Value(info["cid"]) ?? 0
        var resolvedDuration = Double(int64Value(info["duration"]) ?? 0)

        if let targetPage = page, targetPage > 1,
           let pages = info["pages"] as? [[String: Any]],
           let match = pages.first(where: { (int64Value($0["page"]) ?? 0) == Int64(targetPage) }) {
            if let pageCID = int64Value(match["cid"]) { resolvedCID = pageCID }
            if let pageDur = int64Value(match["duration"]), pageDur > 0 { resolvedDuration = Double(pageDur) }
        }

        let title = ((info["title"] as? String) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let rawDesc = ((info["desc"] as? String) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let cleanDesc = rawDesc == "-" ? "" : rawDesc
        let coverURL = normalizedHTTPSURL(info["pic"] as? String)

        let owner = info["owner"] as? [String: Any]
        let ownerName = ((owner?["name"] as? String) ?? "B站 UP 主").trimmingCharacters(in: .whitespacesAndNewlines)
        let ownerMid = int64Value(owner?["mid"]) ?? 0
        let ownerFaceURL = normalizedHTTPSURL(owner?["face"] as? String)

        let stat = info["stat"] as? [String: Any]
        let pubDateText: String? = {
            guard let ts = int64Value(info["pubdate"]), ts > 0 else { return nil }
            return formatShortDate(Date(timeIntervalSince1970: TimeInterval(ts)))
        }()

        return BilibiliViewInfo(
            bvid: resolvedBVID.isEmpty ? "av\(resolvedAID)" : resolvedBVID,
            aid: resolvedAID,
            cid: resolvedCID,
            title: title.isEmpty ? resolvedBVID : title,
            desc: cleanDesc,
            coverURL: coverURL,
            durationSeconds: resolvedDuration,
            publishedDateText: pubDateText,
            ownerName: ownerName.isEmpty ? "B站 UP 主" : ownerName,
            ownerMid: ownerMid,
            ownerFaceURL: ownerFaceURL,
            viewCount: intValue(stat?["view"]),
            likeCount: intValue(stat?["like"]),
            replyCount: intValue(stat?["reply"]),
            shareCount: intValue(stat?["share"])
        )
    }

    /// Computes Bilibili WBI `wts` + `w_rid` (MD5) signature for protected endpoints like `conclusion/get` & `playurl`.
    public static func signBilibiliWBI(
        params: [String: String],
        imgKey: String,
        subKey: String,
        timestamp: Int = Int(Date().timeIntervalSince1970)
    ) -> [URLQueryItem] {
        let combined = Array(imgKey + subKey)
        var mixin = ""
        mixin.reserveCapacity(32)
        for idx in mixinKeyEncTab {
            if idx < combined.count {
                mixin.append(combined[idx])
                if mixin.count == 32 { break }
            }
        }

        var working = params
        working["wts"] = "\(timestamp)"

        let forbidden = CharacterSet(charactersIn: "!'()*")
        let sortedKeys = working.keys.sorted()
        var encodedPairs: [String] = []
        var items: [URLQueryItem] = []

        for key in sortedKeys {
            let rawValue = working[key] ?? ""
            let filtered = String(rawValue.unicodeScalars.filter { !forbidden.contains($0) })
            let encodedKey = wbiURLEncode(key)
            let encodedVal = wbiURLEncode(filtered)
            encodedPairs.append("\(encodedKey)=\(encodedVal)")
            items.append(URLQueryItem(name: key, value: filtered))
        }

        let queryString = encodedPairs.joined(separator: "&")
        let digest = Insecure.MD5.hash(data: Data((queryString + mixin).utf8))
        let wRid = digest.map { String(format: "%02x", $0) }.joined()
        items.append(URLQueryItem(name: "w_rid", value: wRid))
        return items
    }

    private static func wbiURLEncode(_ value: String) -> String {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-_.~")
        return value.addingPercentEncoding(withAllowedCharacters: allowed) ?? value
    }

    private static func fetchBilibiliAISummary(
        bvid: String,
        cid: Int64,
        upMid: Int64
    ) async -> (summary: String?, outline: [String]) {
        guard cid > 0,
              let keys = await BilibiliWBICache.shared.keys(session: apiSession, userAgent: browserUA) else {
            return (nil, [])
        }
        var params: [String: String] = [
            "bvid": bvid,
            "cid": "\(cid)"
        ]
        if upMid > 0 {
            params["up_mid"] = "\(upMid)"
        }
        let signedItems = signBilibiliWBI(params: params, imgKey: keys.imgKey, subKey: keys.subKey)
        var comps = URLComponents(string: "https://api.bilibili.com/x/web-interface/view/conclusion/get")
        comps?.queryItems = signedItems
        guard let url = comps?.url else { return (nil, []) }

        var req = URLRequest(url: url, timeoutInterval: 8)
        req.setValue(browserUA, forHTTPHeaderField: "User-Agent")
        req.setValue("https://www.bilibili.com/video/\(bvid)", forHTTPHeaderField: "Referer")

        guard let (data, resp) = try? await apiSession.data(for: req),
              let http = resp as? HTTPURLResponse,
              (200..<300).contains(http.statusCode),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              (root["code"] as? Int) == 0,
              let dataObj = root["data"] as? [String: Any],
              let modelResult = dataObj["model_result"] as? [String: Any] else {
            return (nil, [])
        }

        let summaryText = (modelResult["summary"] as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .nilIfEmpty

        var outlineLines: [String] = []
        if let outlines = modelResult["outline"] as? [[String: Any]] {
            for section in outlines {
                if let secTitle = (section["title"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
                   !secTitle.isEmpty {
                    let ts = intValue(section["timestamp"]).map(formatTimestamp)
                    outlineLines.append(ts.map { "\($0) \(secTitle)" } ?? secTitle)
                }
                if let parts = section["part_outline"] as? [[String: Any]] {
                    for part in parts.prefix(4) {
                        if let content = (part["content"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
                           !content.isEmpty {
                            let ts = intValue(part["timestamp"]).map(formatTimestamp)
                            outlineLines.append(ts.map { "  · \($0) \(content)" } ?? "  · \(content)")
                        }
                    }
                }
                if outlineLines.count >= 16 { break }
            }
        }

        return (summaryText, Array(outlineLines.prefix(16)))
    }

    // MARK: - YouTube Metadata + Chapters + Caption Digest (`youtubei/v1/player` + oEmbed Fallback)

    private static func resolveYouTube(videoID: String, canonicalURL: URL) async -> ResolvedSocialPost? {
        let playerPayload = await fetchYouTubePlayerResponse(videoID: videoID, client: .android)
        let oEmbed = playerPayload == nil ? await fetchYouTubeOEmbed(canonicalURL: canonicalURL) : nil

        let videoDetails = playerPayload?["videoDetails"] as? [String: Any]
        let microformat = (playerPayload?["microformat"] as? [String: Any])?["playerMicroformatRenderer"] as? [String: Any]

        let rawTitle = (videoDetails?["title"] as? String)
            ?? (oEmbed?["title"] as? String)
            ?? ""
        let title = rawTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty else { return nil }

        let authorName = ((videoDetails?["author"] as? String)
            ?? (oEmbed?["author_name"] as? String)
            ?? "YouTube 频道").trimmingCharacters(in: .whitespacesAndNewlines)
        let channelID = (videoDetails?["channelId"] as? String) ?? ""
        let shortDesc = ((videoDetails?["shortDescription"] as? String) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let durationSeconds = (videoDetails?["lengthSeconds"] as? String).flatMap(Double.init)
            ?? (videoDetails?["lengthSeconds"] as? Double)
        let viewCount = (videoDetails?["viewCount"] as? String).flatMap(Int.init)
            ?? intValue(videoDetails?["viewCount"])
        let publishDate = (microformat?["publishDate"] as? String)
            ?? (microformat?["uploadDate"] as? String)

        // Pick highest-resolution cover thumbnail URL
        let coverURL: URL? = {
            if let thumbObj = videoDetails?["thumbnail"] as? [String: Any],
               let thumbs = thumbObj["thumbnails"] as? [[String: Any]] {
                let best = thumbs
                    .compactMap { entry -> (URL, Int)? in
                        guard let uStr = entry["url"] as? String, let u = normalizedHTTPSURL(uStr) else { return nil }
                        let w = intValue(entry["width"]) ?? 0
                        return (u, w)
                    }
                    .max(by: { $0.1 < $1.1 })?.0
                if let best { return best }
            }
            if let oThumb = normalizedHTTPSURL(oEmbed?["thumbnail_url"] as? String) {
                return oThumb
            }
            return URL(string: "https://i.ytimg.com/vi/\(videoID)/hqdefault.jpg")
        }()

        // Parse chapters from description timestamps + caption transcript digest if captions exist
        let chapters = extractTimestampChapters(from: shortDesc)
        let captionDigest = await fetchYouTubeCaptionSummary(from: playerPayload)
        let descriptionDigest = extractConciseDescriptionLead(from: shortDesc)
        let summaryText = captionDigest ?? descriptionDigest

        let coverURLString = coverURL?.absoluteString
        let attachment = SocialMediaAttachment(
            kind: .video,
            url: canonicalURL.absoluteString,
            thumbnailURL: coverURLString
        )

        let metadata = SocialPostMetadata(
            platform: .youtube,
            authorName: authorName.isEmpty ? "YouTube 频道" : authorName,
            authorHandle: channelID.isEmpty ? authorName : channelID,
            authorAvatarURL: nil,
            publishedAtText: publishDate.map { String($0.prefix(10)) },
            bodyText: shortDesc,
            articleTitle: title,
            mediaURLs: coverURLString.map { [$0] } ?? [],
            mediaThumbnailURLs: coverURLString.map { [$0] } ?? [],
            attachments: [attachment],
            hasVideo: true,
            videoURL: canonicalURL.absoluteString,
            viewCount: viewCount,
            originalURL: canonicalURL.absoluteString,
            mediaFetchFailed: false,
            videoDurationSeconds: durationSeconds,
            videoSummary: summaryText,
            videoOutline: chapters,
            videoID: videoID,
            videoCID: nil
        )

        // Default collection downloads ONLY metadata + cover + summary/chapters — NEVER the video stream.
        return ResolvedSocialPost(
            metadata: metadata,
            primaryMediaDownloadURL: nil,
            primaryMediaKind: nil,
            primaryThumbnailURL: coverURL
        )
    }

    private enum YouTubeClientProfile {
        case ios
        case android
        case tvEmbedded

        var clientContext: [String: Any] {
            switch self {
            case .ios:
                return [
                    "clientName": "IOS",
                    "clientVersion": "19.29.1",
                    "deviceMake": "Apple",
                    "deviceModel": "iPhone16,2",
                    "osName": "iPhone",
                    "osVersion": "17.5.1.21F90",
                    "hl": "zh-CN",
                    "gl": "US"
                ]
            case .android:
                return [
                    "clientName": "ANDROID",
                    "clientVersion": "19.29.37",
                    "androidSdkVersion": 34,
                    "hl": "zh-CN",
                    "gl": "US"
                ]
            case .tvEmbedded:
                return [
                    "clientName": "TVHTML5_SIMPLY_EMBEDDED_PLAYER",
                    "clientVersion": "2.0",
                    "hl": "zh-CN",
                    "gl": "US"
                ]
            }
        }

        var userAgent: String {
            switch self {
            case .ios: VideoPlatformResolver.iosYouTubeUA
            case .android: VideoPlatformResolver.androidYouTubeUA
            case .tvEmbedded: VideoPlatformResolver.browserUA
            }
        }
    }

    private static func fetchYouTubePlayerResponse(
        videoID: String,
        client: YouTubeClientProfile
    ) async -> [String: Any]? {
        guard let url = URL(string: "https://www.youtube.com/youtubei/v1/player?prettyPrint=false") else { return nil }
        var body: [String: Any] = [
            "context": ["client": client.clientContext],
            "videoId": videoID,
            "contentCheckOk": true,
            "racyCheckOk": true
        ]
        if client == .tvEmbedded {
            body["context"] = [
                "client": client.clientContext,
                "thirdParty": ["embedUrl": "https://www.youtube.com/"]
            ]
        }
        guard let jsonData = try? JSONSerialization.data(withJSONObject: body) else { return nil }

        var req = URLRequest(url: url, timeoutInterval: 10)
        req.httpMethod = "POST"
        req.httpBody = jsonData
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue(client.userAgent, forHTTPHeaderField: "User-Agent")
        req.setValue("https://www.youtube.com", forHTTPHeaderField: "Origin")

        guard let (data, resp) = try? await apiSession.data(for: req),
              let http = resp as? HTTPURLResponse,
              (200..<300).contains(http.statusCode),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }
        return json
    }

    private static func fetchYouTubeOEmbed(canonicalURL: URL) async -> [String: Any]? {
        var comps = URLComponents(string: "https://www.youtube.com/oembed")
        comps?.queryItems = [
            URLQueryItem(name: "url", value: canonicalURL.absoluteString),
            URLQueryItem(name: "format", value: "json")
        ]
        guard let url = comps?.url else { return nil }
        var req = URLRequest(url: url, timeoutInterval: 8)
        req.setValue(browserUA, forHTTPHeaderField: "User-Agent")
        guard let (data, resp) = try? await apiSession.data(for: req),
              let http = resp as? HTTPURLResponse,
              (200..<300).contains(http.statusCode),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }
        return json
    }

    /// Fetches the best available YouTube caption track (preferring Chinese, then English) and builds a crisp summary excerpt.
    private static func fetchYouTubeCaptionSummary(from playerPayload: [String: Any]?) async -> String? {
        guard let captions = playerPayload?["captions"] as? [String: Any],
              let renderer = captions["playerCaptionsTracklistRenderer"] as? [String: Any],
              let tracks = renderer["captionTracks"] as? [[String: Any]],
              !tracks.isEmpty else {
            return nil
        }

        let preferredTrack: [String: Any]? =
            tracks.first(where: { (($0["languageCode"] as? String) ?? "").lowercased().hasPrefix("zh") && ($0["kind"] as? String) != "asr" })
            ?? tracks.first(where: { (($0["languageCode"] as? String) ?? "").lowercased().hasPrefix("zh") })
            ?? tracks.first(where: { (($0["languageCode"] as? String) ?? "").lowercased().hasPrefix("en") && ($0["kind"] as? String) != "asr" })
            ?? tracks.first(where: { (($0["languageCode"] as? String) ?? "").lowercased().hasPrefix("en") })
            ?? tracks.first

        guard let baseURLStr = preferredTrack?["baseUrl"] as? String,
              let baseURL = URL(string: baseURLStr),
              WebBookmark.isSafeRemoteFetchURL(baseURL) else {
            return nil
        }

        var comps = URLComponents(url: baseURL, resolvingAgainstBaseURL: false)
        var items = comps?.queryItems ?? []
        if !items.contains(where: { $0.name == "fmt" }) {
            items.append(URLQueryItem(name: "fmt", value: "json3"))
        }
        comps?.queryItems = items
        guard let captionURL = comps?.url else { return nil }

        var req = URLRequest(url: captionURL, timeoutInterval: 6)
        req.setValue(browserUA, forHTTPHeaderField: "User-Agent")

        guard let (data, resp) = try? await apiSession.data(for: req),
              let http = resp as? HTTPURLResponse,
              (200..<300).contains(http.statusCode),
              !data.isEmpty,
              data.count <= 2 * 1024 * 1024 else {
            return nil
        }

        var pieces: [String] = []
        if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let events = json["events"] as? [[String: Any]] {
            for ev in events {
                guard let segs = ev["segs"] as? [[String: Any]] else { continue }
                let line = segs.compactMap { $0["utf8"] as? String }.joined()
                    .replacingOccurrences(of: "\n", with: " ")
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                if !line.isEmpty && pieces.last != line {
                    pieces.append(line)
                }
                if pieces.count >= 48 { break }
            }
        }

        guard !pieces.isEmpty else { return nil }
        let joined = pieces.joined(separator: " ")
            .replacingOccurrences(of: "  ", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard joined.count >= 16 else { return nil }
        if joined.count > 360 {
            return String(joined.prefix(356)).trimmingCharacters(in: .whitespacesAndNewlines) + "…"
        }
        return joined
    }

    // MARK: - 1.5 Zero-Download Inline Streaming Playback Plan (Preview-Time Only)

    /// Resolves an inline zero-download streaming plan for a bookmarked social/video post:
    /// - Tier 1: Native `AVPlayer` HTTP Range MP4 / HLS `.m3u8` streams with required site headers (`Referer`, `User-Agent`).
    /// - Tier 2: Official embedded `WKWebView` streaming player (YouTube embed with valid origin/Referer to avoid Error 153,
    ///   Bilibili HTML5 player, Vimeo/Dailymotion embeds).
    public static func resolvePlaybackPlan(for post: SocialPostMetadata) async -> VideoStreamPlaybackPlan {
        let watchURL = URL(string: post.originalURL)
        switch post.platform {
        case .bilibili:
            return await resolveBilibiliPlaybackPlan(for: post, watchURL: watchURL)
        case .youtube:
            return await resolveYouTubePlaybackPlan(for: post, watchURL: watchURL)
        case .douyin:
            return await resolveDouyinPlaybackPlan(for: post, watchURL: watchURL)
        default:
            var streams: [VideoStreamPlaybackPlan.DirectStream] = []
            var seen = Set<String>()
            var headers: [String: String] = ["User-Agent": browserUA]
            if post.platform == .xiaohongshu {
                headers["Referer"] = "https://www.xiaohongshu.com/"
            } else if let watchURL {
                headers["Referer"] = watchURL.absoluteString
            }
            for att in post.effectiveAttachments where att.kind == .video || att.kind == .gif {
                guard let url = URL(string: att.url),
                      WebBookmark.isSafeRemoteFetchURL(url),
                      seen.insert(url.absoluteString).inserted else { continue }
                let isHLS = url.pathExtension.lowercased() == "m3u8" || url.absoluteString.lowercased().contains(".m3u8")
                streams.append(.init(url: url, httpHeaders: headers, isHLS: isHLS))
            }
            let embed = watchURL.flatMap { embedPlayer(for: $0) }
            return VideoStreamPlaybackPlan(directStreams: streams, embedPlayer: embed, watchURL: watchURL)
        }
    }

    /// Resolves an inline zero-download streaming plan for any generic rich webpage bookmark (`WebPageRichMetadata`).
    public static func resolveWebPagePlaybackPlan(
        for web: WebPageRichMetadata,
        fallbackURL: URL? = nil
    ) async -> VideoStreamPlaybackPlan {
        let canonicalURL = URL(string: web.canonicalURL) ?? fallbackURL
        var directStreams: [VideoStreamPlaybackPlan.DirectStream] = []
        var seen = Set<String>()
        var embedCandidate: VideoStreamPlaybackPlan.EmbedPlayer? = canonicalURL.flatMap { embedPlayer(for: $0) }

        var headers: [String: String] = ["User-Agent": browserUA]
        if let canonicalURL {
            headers["Referer"] = canonicalURL.absoluteString
        }

        for att in web.attachments where att.kind == .video {
            guard let url = URL(string: att.url),
                  WebBookmark.isSafeRemoteFetchURL(url) else { continue }
            if looksLikeDirectVideoStreamURL(url), seen.insert(url.absoluteString).inserted {
                let isHLS = url.pathExtension.lowercased() == "m3u8" || url.absoluteString.lowercased().contains(".m3u8")
                directStreams.append(.init(url: url, httpHeaders: headers, isHLS: isHLS))
            } else if embedCandidate == nil, let discoveredEmbed = embedPlayer(for: url) {
                embedCandidate = discoveredEmbed
            }
        }

        #if os(macOS)
        if directStreams.isEmpty, web.hasVideo, let pageStr = canonicalURL?.absoluteString,
           let ytdlpStream = await resolveDirectStreamURLViaYtDlpIfAvailable(pageURL: pageStr) {
            directStreams.append(ytdlpStream)
        }
        #endif

        return VideoStreamPlaybackPlan(
            directStreams: directStreams,
            embedPlayer: embedCandidate,
            watchURL: canonicalURL
        )
    }

    /// Pure URL recognizer returning a clean embed player descriptor for major video platforms
    /// (YouTube, Bilibili, Vimeo, Dailymotion, or explicit `/embed/` player URLs).
    public static func embedPlayer(
        for url: URL,
        bvidOverride: String? = nil,
        cidOverride: Int64? = nil
    ) -> VideoStreamPlaybackPlan.EmbedPlayer? {
        guard WebBookmark.isSafeRemoteFetchURL(url),
              let host = url.host()?.lowercased() else {
            return nil
        }

        if let parsed = VideoPlatformURLParser.parse(url) {
            switch parsed {
            case .youtube(let videoID, _):
                // Supply `origin=https://charkle.app` + matching Referer/baseURL to avoid YouTube Error 153 in WKWebView.
                let embedStr = "https://www.youtube.com/embed/\(videoID)?autoplay=1&playsinline=1&rel=0&modestbranding=1&origin=https://charkle.app"
                if let embedURL = URL(string: embedStr) {
                    return .init(
                        url: embedURL,
                        referer: "https://charkle.app",
                        userAgent: browserUA,
                        useIframeWrapper: true
                    )
                }
            case .bilibili(let parsedBV, let parsedAID, _, let page, _):
                var items: [URLQueryItem] = []
                if let bv = bvidOverride?.nilIfEmpty ?? parsedBV {
                    items.append(URLQueryItem(name: "bvid", value: bv))
                } else if let aid = parsedAID {
                    items.append(URLQueryItem(name: "aid", value: "\(aid)"))
                }
                if let cid = cidOverride, cid > 0 {
                    items.append(URLQueryItem(name: "cid", value: "\(cid)"))
                }
                if let page, page > 1 {
                    items.append(URLQueryItem(name: "page", value: "\(page)"))
                }
                if !items.isEmpty {
                    items.append(URLQueryItem(name: "autoplay", value: "1"))
                    items.append(URLQueryItem(name: "danmaku", value: "0"))
                    items.append(URLQueryItem(name: "high_quality", value: "1"))
                    var comps = URLComponents(string: "https://player.bilibili.com/player.html")
                    comps?.queryItems = items
                    if let embedURL = comps?.url {
                        return .init(
                            url: embedURL,
                            referer: "https://www.bilibili.com/",
                            userAgent: browserUA,
                            useIframeWrapper: true
                        )
                    }
                }
            }
        }

        let segments = url.pathComponents.filter { $0 != "/" && !$0.isEmpty }

        // Vimeo (`vimeo.com/<digits>` or `player.vimeo.com/video/<digits>`)
        if host == "vimeo.com" || host == "www.vimeo.com" || host == "player.vimeo.com" {
            let numericID = segments.reversed().first(where: { $0.count >= 5 && $0.allSatisfy(\.isNumber) })
            if let numericID,
               let embedURL = URL(string: "https://player.vimeo.com/video/\(numericID)?autoplay=1&playsinline=1") {
                return .init(
                    url: embedURL,
                    referer: "https://vimeo.com/",
                    userAgent: browserUA,
                    useIframeWrapper: true
                )
            }
        }

        // Dailymotion (`dailymotion.com/video/<id>` or `dai.ly/<id>`)
        if host == "dailymotion.com" || host == "www.dailymotion.com" || host == "dai.ly" || host == "geo.dailymotion.com" {
            let videoCode: String? = {
                if host == "dai.ly", let first = segments.first, !first.isEmpty { return first }
                if let idx = segments.firstIndex(of: "video"), idx + 1 < segments.count { return segments[idx + 1] }
                return URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first(where: { $0.name == "video" })?.value
            }()
            if let videoCode,
               videoCode.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "_" || $0 == "-") }),
               let embedURL = URL(string: "https://geo.dailymotion.com/player.html?video=\(videoCode)") {
                return .init(
                    url: embedURL,
                    referer: "https://www.dailymotion.com/",
                    userAgent: browserUA,
                    useIframeWrapper: true
                )
            }
        }

        // Explicit embed / player URLs discovered from `og:video` / JSON-LD `embedUrl`
        let lowerPath = url.path.lowercased()
        if (host.hasPrefix("player.") || lowerPath.contains("/embed/") || lowerPath.contains("player.html"))
            && !looksLikeDirectVideoStreamURL(url) {
            let origin = "\(url.scheme ?? "https")://\(host)/"
            return .init(
                url: url,
                referer: origin,
                userAgent: browserUA,
                useIframeWrapper: true
            )
        }

        return nil
    }

    /// Generates clean full-bleed responsive iframe HTML with explicit `strict-origin-when-cross-origin`
    /// Referer policy and non-nil `baseURL` (prevents YouTube Error 153 and Bilibili Referer rejection in `WKWebView`).
    public static func embedHTML(for embed: VideoStreamPlaybackPlan.EmbedPlayer) -> (html: String, baseURL: URL) {
        let escapedSrc = embed.url.absoluteString
            .replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "\"", with: "&quot;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
        let html = """
        <!DOCTYPE html>
        <html>
        <head>
          <meta charset="utf-8">
          <meta name="viewport" content="width=device-width, initial-scale=1.0, maximum-scale=1.0, user-scalable=no">
          <meta name="referrer" content="strict-origin-when-cross-origin">
          <style>
            html, body {
              margin: 0;
              padding: 0;
              width: 100%;
              height: 100%;
              background: #000;
              overflow: hidden;
            }
            iframe {
              position: fixed;
              inset: 0;
              width: 100%;
              height: 100%;
              border: 0;
              background: #000;
            }
          </style>
        </head>
        <body>
          <iframe
            src="\(escapedSrc)"
            referrerpolicy="strict-origin-when-cross-origin"
            allow="accelerometer; autoplay; clipboard-write; encrypted-media; gyroscope; picture-in-picture; web-share; fullscreen"
            allowfullscreen
            webkitallowfullscreen>
          </iframe>
        </body>
        </html>
        """
        let baseURL = URL(string: embed.referer) ?? URL(string: "https://charkle.app")!
        return (html, baseURL)
    }

    /// Returns `true` when `url` points directly to a playable media stream rather than an HTML watch/embed page.
    public static func looksLikeDirectVideoStreamURL(_ url: URL) -> Bool {
        let ext = url.pathExtension.lowercased()
        if ["mp4", "m4v", "mov", "m3u8", "webm"].contains(ext) {
            return true
        }
        let lower = url.absoluteString.lowercased()
        if DouyinURLParser.isDouyinVideoHost(url.host()) && DouyinURLParser.parse(url) == nil {
            return true
        }
        return lower.contains(".mp4?")
            || lower.contains(".m3u8?")
            || lower.contains(".mov?")
            || lower.contains("mime=video")
            || lower.contains("/videoplayback?")
    }

    private static func resolveBilibiliPlaybackPlan(
        for post: SocialPostMetadata,
        watchURL: URL?
    ) async -> VideoStreamPlaybackPlan {
        var bvid = post.videoID?.nilIfEmpty
        var aid: Int64? = nil
        var cid = post.videoCID
        var page: Int? = nil

        if let origURL = watchURL,
           case .bilibili(let parsedBV, let parsedAID, let shortURL, let parsedPage, _) = VideoPlatformURLParser.parse(origURL) {
            bvid = bvid ?? parsedBV
            aid = parsedAID
            page = parsedPage
            if bvid == nil, aid == nil, let shortURL,
               let expanded = await expandShortRedirect(shortURL),
               case .bilibili(let rbv, let raid, _, let rpage, _) = VideoPlatformURLParser.parse(expanded) {
                bvid = rbv
                aid = raid
                page = page ?? rpage
            }
        }

        if cid == nil || cid == 0 || bvid == nil {
            if let fresh = await fetchBilibiliViewInfo(bvid: bvid, aid: aid, page: page) {
                bvid = fresh.bvid
                aid = fresh.aid
                cid = fresh.cid
            }
        }

        var directStreams: [VideoStreamPlaybackPlan.DirectStream] = []
        if let resolvedBVID = bvid, let resolvedCID = cid, resolvedCID > 0 {
            let referer = "https://www.bilibili.com/video/\(resolvedBVID)"
            let headers = [
                "Referer": referer,
                "User-Agent": browserUA
            ]
            let urls = await fetchBilibiliProgressiveStreamURLs(bvid: resolvedBVID, cid: resolvedCID)
            directStreams = urls.map { .init(url: $0, httpHeaders: headers, isHLS: false) }
        }

        let canonicalForEmbed: URL? = {
            if let bvid {
                let suffix = (page ?? 1) > 1 ? "?p=\(page!)" : ""
                return URL(string: "https://www.bilibili.com/video/\(bvid)\(suffix)")
            }
            return watchURL
        }()
        let embed = canonicalForEmbed.flatMap { embedPlayer(for: $0, bvidOverride: bvid, cidOverride: cid) }

        return VideoStreamPlaybackPlan(
            directStreams: directStreams,
            embedPlayer: embed,
            watchURL: canonicalForEmbed ?? watchURL
        )
    }

    private static func resolveYouTubePlaybackPlan(
        for post: SocialPostMetadata,
        watchURL: URL?
    ) async -> VideoStreamPlaybackPlan {
        let videoID: String? = {
            if let id = post.videoID, VideoPlatformURLParser.isValidYouTubeID(id) {
                return id
            }
            if let url = watchURL,
               case .youtube(let parsedID, _) = VideoPlatformURLParser.parse(url) {
                return parsedID
            }
            return nil
        }()

        let canonicalURL = videoID.flatMap { URL(string: "https://www.youtube.com/watch?v=\($0)") } ?? watchURL
        let embed = canonicalURL.flatMap { embedPlayer(for: $0) }

        guard let videoID else {
            return VideoStreamPlaybackPlan(directStreams: [], embedPlayer: embed, watchURL: canonicalURL)
        }

        var directStreams: [VideoStreamPlaybackPlan.DirectStream] = []
        var seen = Set<String>()

        // Try native InnerTube streams (preferring adaptive HLS `.m3u8` up to 1080p, then progressive muxed MP4)
        for profile in [YouTubeClientProfile.ios, .android, .tvEmbedded] {
            if Task.isCancelled { break }
            guard let payload = await fetchYouTubePlayerResponse(videoID: videoID, client: profile),
                  let streamingData = payload["streamingData"] as? [String: Any] else {
                continue
            }

            let headers = [
                "User-Agent": profile.userAgent,
                "Referer": "https://www.youtube.com/"
            ]

            if let hlsStr = streamingData["hlsManifestUrl"] as? String,
               let hlsURL = URL(string: hlsStr),
               WebBookmark.isSafeRemoteFetchURL(hlsURL),
               seen.insert(hlsURL.absoluteString).inserted {
                directStreams.append(.init(url: hlsURL, httpHeaders: headers, isHLS: true))
            }

            if let formats = streamingData["formats"] as? [[String: Any]] {
                let progressiveMP4s: [(url: URL, qualityRank: Int)] = formats.compactMap { entry in
                    guard let urlStr = entry["url"] as? String,
                          let streamURL = URL(string: urlStr),
                          WebBookmark.isSafeRemoteFetchURL(streamURL) else {
                        return nil
                    }
                    let mime = ((entry["mimeType"] as? String) ?? "").lowercased()
                    guard mime.contains("video/mp4") else { return nil }
                    let height = intValue(entry["height"]) ?? 0
                    let bitrate = intValue(entry["bitrate"]) ?? 0
                    return (streamURL, height * 10_000 + bitrate / 1_000)
                }
                .sorted { $0.qualityRank > $1.qualityRank }

                for item in progressiveMP4s where seen.insert(item.url.absoluteString).inserted {
                    directStreams.append(.init(url: item.url, httpHeaders: headers, isHLS: false))
                }
            }

            if !directStreams.isEmpty { break }
        }

        return VideoStreamPlaybackPlan(
            directStreams: directStreams,
            embedPlayer: embed,
            watchURL: canonicalURL
        )
    }

    private static func resolveDouyinPlaybackPlan(
        for post: SocialPostMetadata,
        watchURL: URL?
    ) async -> VideoStreamPlaybackPlan {
        let headers: [String: String] = [
            "Referer": DouyinURLParser.referer,
            "User-Agent": browserUA
        ]
        var freshStreams: [VideoStreamPlaybackPlan.DirectStream] = []
        var expiredStreams: [VideoStreamPlaybackPlan.DirectStream] = []
        var seen = Set<String>()

        func appendCandidate(_ rawURLString: String?) {
            guard let raw = rawURLString?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !raw.isEmpty,
                  let url = URL(string: raw),
                  WebBookmark.isSafeRemoteFetchURL(url),
                  !raw.lowercased().contains("playwm"),
                  DouyinURLParser.parse(url) == nil,
                  seen.insert(url.absoluteString).inserted else {
                return
            }
            let isHLS = url.pathExtension.lowercased() == "m3u8" || raw.lowercased().contains(".m3u8")
            let stream = VideoStreamPlaybackPlan.DirectStream(
                url: url,
                httpHeaders: headers,
                isHLS: isHLS,
                overrideMIMEType: isHLS ? nil : "video/mp4"
            )
            if DouyinURLParser.isStreamURLExpired(url) {
                expiredStreams.append(stream)
            } else {
                freshStreams.append(stream)
            }
        }

        for att in post.effectiveAttachments where att.kind == .video || att.kind == .gif {
            appendCandidate(att.url)
        }
        appendCandidate(post.videoURL)

        if freshStreams.isEmpty, let watchURL, let ref = DouyinURLParser.parse(watchURL) {
            if let refreshed = await DouyinPostResolver.resolve(ref) {
                for att in refreshed.metadata.effectiveAttachments where att.kind == .video || att.kind == .gif {
                    appendCandidate(att.url)
                }
                appendCandidate(refreshed.metadata.videoURL)
            }
        }

        #if os(macOS)
        if freshStreams.isEmpty, let watchStr = watchURL?.absoluteString,
           let ytdlpStream = await resolveDirectStreamURLViaYtDlpIfAvailable(
                pageURL: watchStr,
                refererOverride: DouyinURLParser.referer,
                overrideMIMEType: "video/mp4"
           ) {
            freshStreams.append(ytdlpStream)
        }
        #endif

        return VideoStreamPlaybackPlan(
            directStreams: freshStreams + expiredStreams,
            embedPlayer: nil,
            watchURL: watchURL
        )
    }

    // MARK: - 2. Explicit On-Demand Video Download (Triggered ONLY When User Saves Video as Standalone Asset)

    public static func downloadVideo(
        for post: SocialPostMetadata,
        to directory: URL,
        baseName: String
    ) async throws -> URL {
        switch post.platform {
        case .bilibili:
            return try await downloadBilibiliVideo(for: post, to: directory, baseName: baseName)
        case .youtube:
            return try await downloadYouTubeVideo(for: post, to: directory, baseName: baseName)
        case .douyin:
            return try await downloadDouyinVideo(for: post, to: directory, baseName: baseName)
        default:
            throw VideoPlatformDownloadError.unsupportedURL
        }
    }

    private static func downloadDouyinVideo(
        for post: SocialPostMetadata,
        to directory: URL,
        baseName: String
    ) async throws -> URL {
        let plan = await resolveDouyinPlaybackPlan(for: post, watchURL: URL(string: post.originalURL))
        for candidate in plan.directStreams where !candidate.isHLS {
            try Task.checkCancellation()
            if let file = await downloadStreamFile(
                from: candidate.url,
                to: directory,
                baseName: baseName,
                userAgent: browserUA,
                referer: DouyinURLParser.referer
            ) {
                return file
            }
        }

        #if os(macOS)
        if let ytdlpFile = await downloadViaYtDlpIfAvailable(
            pageURL: post.originalURL,
            to: directory,
            baseName: baseName
        ) {
            return ytdlpFile
        }
        throw VideoPlatformDownloadError.streamUnavailable(
            "该抖音视频直链已过期或受访问限制。可在抖音重新同步后重试，或本机安装 yt-dlp（brew install yt-dlp），也可点击「在抖音打开」观看。"
        )
        #else
        throw VideoPlatformDownloadError.streamUnavailable(
            "该抖音视频直链已过期或受访问限制，可在抖音重新同步后重试，或点击「在抖音打开」观看。"
        )
        #endif
    }

    /// Universal on-demand video downloader for arbitrary webpage links (Vimeo, TikTok, Douyin, Weibo,
    /// Behance, Dribbble, news/blog embedded `<video>` / `og:video`, etc.):
    /// 1. Downloads direct MP4/WebM/MOV media stream URLs natively on both macOS and iOS.
    /// 2. Falls back to locally installed `yt-dlp` on macOS when the page requires site-specific extraction.
    public static func downloadGenericWebVideo(
        pageURL: String,
        directStreamURL: URL?,
        to directory: URL,
        baseName: String
    ) async throws -> URL {
        if let direct = directStreamURL,
           WebBookmark.isSafeRemoteFetchURL(direct) {
            let lower = direct.pathExtension.lowercased()
            let isDouyinCDN = DouyinURLParser.isDouyinVideoHost(direct.host()) && DouyinURLParser.parse(direct) == nil
            let looksDirect = ["mp4", "mov", "m4v", "webm"].contains(lower)
                || direct.absoluteString.lowercased().contains(".mp4")
                || direct.absoluteString.lowercased().contains("video")
                || isDouyinCDN
            let effectiveReferer = isDouyinCDN ? DouyinURLParser.referer : pageURL
            if looksDirect,
               let file = await downloadStreamFile(
                    from: direct,
                    to: directory,
                    baseName: baseName,
                    userAgent: browserUA,
                    referer: effectiveReferer
               ) {
                return file
            }
        }

        #if os(macOS)
        if let ytdlpFile = await downloadViaYtDlpIfAvailable(
            pageURL: pageURL,
            to: directory,
            baseName: baseName
        ) {
            return ytdlpFile
        }
        throw VideoPlatformDownloadError.streamUnavailable(
            "未能从该网页直接提取视频流。若本机安装了 yt-dlp（brew install yt-dlp），Charkle 可自动支持上千个主流视频网站。"
        )
        #else
        throw VideoPlatformDownloadError.streamUnavailable(
            "该网页未暴露可直接下载的 MP4 视频流，可在 Mac 端保存或点击在浏览器中打开。"
        )
        #endif
    }

    private static func downloadBilibiliVideo(
        for post: SocialPostMetadata,
        to directory: URL,
        baseName: String
    ) async throws -> URL {
        var bvid = post.videoID?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
        var aid: Int64? = nil
        var cid = post.videoCID
        var page: Int? = nil

        if let origURL = URL(string: post.originalURL),
           case .bilibili(let parsedBV, let parsedAID, let shortURL, let parsedPage, _) = VideoPlatformURLParser.parse(origURL) {
            bvid = bvid ?? parsedBV
            aid = parsedAID
            page = parsedPage
            if bvid == nil, aid == nil, let shortURL,
               let expanded = await expandShortRedirect(shortURL),
               case .bilibili(let rbv, let raid, _, let rpage, _) = VideoPlatformURLParser.parse(expanded) {
                bvid = rbv
                aid = raid
                page = page ?? rpage
            }
        }

        if cid == nil || cid == 0 || bvid == nil {
            if let fresh = await fetchBilibiliViewInfo(bvid: bvid, aid: aid, page: page) {
                bvid = fresh.bvid
                aid = fresh.aid
                cid = fresh.cid
            }
        }

        guard let resolvedBVID = bvid, let resolvedCID = cid, resolvedCID > 0 else {
            throw VideoPlatformDownloadError.metadataUnavailable("无法解析 B 站视频 BV 号或分 P CID")
        }

        // Try native progressive HTML5 MP4 stream first (works identically on both macOS and iOS!)
        let streamURLs = await fetchBilibiliProgressiveStreamURLs(bvid: resolvedBVID, cid: resolvedCID)
        let referer = "https://www.bilibili.com/video/\(resolvedBVID)"
        for streamURL in streamURLs {
            try Task.checkCancellation()
            if let file = await downloadStreamFile(
                from: streamURL,
                to: directory,
                baseName: baseName,
                userAgent: browserUA,
                referer: referer
            ) {
                return file
            }
        }

        #if os(macOS)
        if let ytdlpFile = await downloadViaYtDlpIfAvailable(
            pageURL: post.originalURL,
            to: directory,
            baseName: baseName
        ) {
            return ytdlpFile
        }
        #endif

        throw VideoPlatformDownloadError.streamUnavailable(
            "该 B 站视频暂无法直接获取 MP4 流（可能需要大会员/登录权限），可点击「在 B 站打开」观看。"
        )
    }

    private static func fetchBilibiliProgressiveStreamURLs(bvid: String, cid: Int64) async -> [URL] {
        let baseParamsList: [[String: String]] = [
            ["bvid": bvid, "cid": "\(cid)", "qn": "80", "fnval": "1", "platform": "html5", "high_quality": "1"],
            ["bvid": bvid, "cid": "\(cid)", "qn": "64", "fnval": "1", "platform": "html5", "high_quality": "1"],
            ["bvid": bvid, "cid": "\(cid)", "qn": "32", "fnval": "1"]
        ]

        let wbiKeys = await BilibiliWBICache.shared.keys(session: apiSession, userAgent: browserUA)
        var candidates: [URL] = []
        var seen = Set<String>()

        for params in baseParamsList {
            if Task.isCancelled { break }
            let endpoint = wbiKeys != nil
                ? "https://api.bilibili.com/x/player/wbi/playurl"
                : "https://api.bilibili.com/x/player/playurl"
            var comps = URLComponents(string: endpoint)
            if let keys = wbiKeys {
                comps?.queryItems = signBilibiliWBI(params: params, imgKey: keys.imgKey, subKey: keys.subKey)
            } else {
                comps?.queryItems = params.map { URLQueryItem(name: $0.key, value: $0.value) }
            }
            guard let url = comps?.url else { continue }

            var req = URLRequest(url: url, timeoutInterval: 10)
            req.setValue(browserUA, forHTTPHeaderField: "User-Agent")
            req.setValue("https://www.bilibili.com/video/\(bvid)", forHTTPHeaderField: "Referer")

            guard let (data, resp) = try? await apiSession.data(for: req),
                  let http = resp as? HTTPURLResponse,
                  (200..<300).contains(http.statusCode),
                  let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  (root["code"] as? Int) == 0,
                  let dataObj = root["data"] as? [String: Any],
                  let durl = dataObj["durl"] as? [[String: Any]],
                  let first = durl.first else {
                continue
            }

            if let primary = first["url"] as? String,
               let parsed = normalizedHTTPSURL(primary),
               seen.insert(parsed.absoluteString).inserted {
                candidates.append(parsed)
            }
            if let backups = first["backup_url"] as? [String] {
                for b in backups {
                    if let parsed = normalizedHTTPSURL(b), seen.insert(parsed.absoluteString).inserted {
                        candidates.append(parsed)
                    }
                }
            }
            if !candidates.isEmpty { break }
        }
        return candidates
    }

    private static func downloadYouTubeVideo(
        for post: SocialPostMetadata,
        to directory: URL,
        baseName: String
    ) async throws -> URL {
        let videoID: String? = {
            if let id = post.videoID, VideoPlatformURLParser.isValidYouTubeID(id) {
                return id
            }
            if let url = URL(string: post.originalURL),
               case .youtube(let parsedID, _) = VideoPlatformURLParser.parse(url) {
                return parsedID
            }
            return nil
        }()

        guard let videoID else {
            throw VideoPlatformDownloadError.metadataUnavailable("无法解析 YouTube 视频 ID")
        }

        // Try native InnerTube progressive muxed MP4 across mobile/TV client profiles (works on BOTH macOS & iOS!)
        for profile in [YouTubeClientProfile.ios, .android, .tvEmbedded] {
            try Task.checkCancellation()
            guard let payload = await fetchYouTubePlayerResponse(videoID: videoID, client: profile),
                  let streamingData = payload["streamingData"] as? [String: Any],
                  let formats = streamingData["formats"] as? [[String: Any]] else {
                continue
            }

            let progressiveMP4s: [(url: URL, qualityRank: Int)] = formats.compactMap { entry in
                guard let urlStr = entry["url"] as? String,
                      let streamURL = URL(string: urlStr),
                      WebBookmark.isSafeRemoteFetchURL(streamURL) else {
                    return nil
                }
                let mime = ((entry["mimeType"] as? String) ?? "").lowercased()
                guard mime.contains("video/mp4") else { return nil }
                let height = intValue(entry["height"]) ?? 0
                let bitrate = intValue(entry["bitrate"]) ?? 0
                return (streamURL, height * 10_000 + bitrate / 1_000)
            }
            .sorted { $0.qualityRank > $1.qualityRank }

            for candidate in progressiveMP4s {
                try Task.checkCancellation()
                if let file = await downloadStreamFile(
                    from: candidate.url,
                    to: directory,
                    baseName: baseName,
                    userAgent: profile.userAgent,
                    referer: "https://www.youtube.com/"
                ) {
                    return file
                }
            }
        }

        #if os(macOS)
        if let ytdlpFile = await downloadViaYtDlpIfAvailable(
            pageURL: post.originalURL,
            to: directory,
            baseName: baseName
        ) {
            return ytdlpFile
        }
        #endif

        #if os(macOS)
        throw VideoPlatformDownloadError.streamUnavailable(
            "YouTube 当前限制了该视频的直链获取。若本机安装 yt-dlp（brew install yt-dlp），Charkle 会自动调用其保存高清 MP4；也可点击「在 YouTube 打开」观看。"
        )
        #else
        throw VideoPlatformDownloadError.streamUnavailable(
            "YouTube 当前限制了该视频的直链下载（需签名/登录校验），可在 Mac 端保存或点击「在 YouTube 打开」观看。"
        )
        #endif
    }

    private static func downloadStreamFile(
        from url: URL,
        to directory: URL,
        baseName: String,
        userAgent: String,
        referer: String?
    ) async -> URL? {
        guard WebBookmark.isSafeRemoteFetchURL(url) else { return nil }
        var req = URLRequest(url: url, timeoutInterval: 25)
        req.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        req.setValue("*/*", forHTTPHeaderField: "Accept")
        if let referer {
            req.setValue(referer, forHTTPHeaderField: "Referer")
        }

        guard let (tempURL, resp) = try? await downloadSession.download(for: req) else {
            return nil
        }
        defer { try? FileManager.default.removeItem(at: tempURL) }
        guard let http = resp as? HTTPURLResponse,
              (200..<300).contains(http.statusCode) else {
            return nil
        }

        let size = Int64((try? tempURL.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
        // Reject tiny HTML error bodies or >600 MB oversized files
        guard size >= 8 * 1024, size <= 600 * 1024 * 1024 else { return nil }

        // Basic MP4/media magic verification (skip HTML error pages accidentally returned with 200)
        if let handle = try? FileHandle(forReadingFrom: tempURL) {
            let head = (try? handle.read(upToCount: 64)) ?? Data()
            try? handle.close()
            if let ascii = String(data: head, encoding: .utf8)?.lowercased(),
               ascii.contains("<html") || ascii.contains("<!doctype") {
                return nil
            }
        }

        let safeBase = sanitizedFileName(baseName)
        let dest = directory.appending(path: "\(safeBase).mp4")
        try? FileManager.default.removeItem(at: dest)
        do {
            try FileManager.default.moveItem(at: tempURL, to: dest)
            return dest
        } catch {
            return nil
        }
    }

    #if os(macOS)
    private static func runYtDlpProcess(
        binary: String,
        arguments: [String],
        captureStdout: Bool,
        timeoutSeconds: Double
    ) async -> (exitCode: Int32, stdout: Data)? {
        guard !Task.isCancelled else { return nil }
        final class ProcessState: @unchecked Sendable {
            let lock = NSLock()
            var process: Process?
            var timeoutWork: DispatchWorkItem?
            var cancelled = false
            var resumed = false
        }
        let state = ProcessState()

        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                let finishOnce: @Sendable ((exitCode: Int32, stdout: Data)?) -> Void = { result in
                    state.lock.lock()
                    let shouldResume = !state.resumed
                    state.resumed = true
                    state.lock.unlock()
                    if shouldResume {
                        continuation.resume(returning: result)
                    }
                }

                let proc = Process()
                proc.executableURL = URL(fileURLWithPath: binary)
                proc.arguments = arguments
                let outPipe: Pipe? = captureStdout ? Pipe() : nil
                proc.standardOutput = outPipe ?? FileHandle.nullDevice
                proc.standardError = FileHandle.nullDevice

                let timeoutWork = DispatchWorkItem {
                    state.lock.lock()
                    let p = state.process
                    state.timeoutWork = nil
                    state.lock.unlock()
                    if let p, p.isRunning {
                        p.terminate()
                    }
                    finishOnce(nil)
                }

                state.lock.lock()
                if state.cancelled {
                    state.lock.unlock()
                    finishOnce(nil)
                    return
                }
                state.process = proc
                state.timeoutWork = timeoutWork
                state.lock.unlock()

                let readGroup = DispatchGroup()
                final class DataBox: @unchecked Sendable { var data = Data() }
                let outBox = DataBox()

                proc.terminationHandler = { terminated in
                    state.lock.lock()
                    let work = state.timeoutWork
                    state.timeoutWork = nil
                    state.lock.unlock()
                    work?.cancel()

                    readGroup.notify(queue: DispatchQueue.global(qos: .userInitiated)) {
                        state.lock.lock()
                        let wasCancelled = state.cancelled
                        state.process = nil
                        state.lock.unlock()
                        if wasCancelled {
                            finishOnce(nil)
                        } else {
                            finishOnce((terminated.terminationStatus, outBox.data))
                        }
                    }
                }

                // Enter stdout drain group BEFORE proc.run() so fast termination cannot beat readGroup.enter().
                if outPipe != nil {
                    readGroup.enter()
                }
                do {
                    try proc.run()
                    if let outPipe {
                        DispatchQueue.global(qos: .userInitiated).async {
                            outBox.data = outPipe.fileHandleForReading.readDataToEndOfFile()
                            readGroup.leave()
                        }
                    }
                    DispatchQueue.global(qos: .userInitiated).asyncAfter(
                        deadline: .now() + timeoutSeconds,
                        execute: timeoutWork
                    )
                } catch {
                    if outPipe != nil {
                        readGroup.leave()
                    }
                    state.lock.lock()
                    let work = state.timeoutWork
                    state.timeoutWork = nil
                    state.process = nil
                    state.lock.unlock()
                    work?.cancel()
                    finishOnce(nil)
                }
            }
        } onCancel: {
            state.lock.lock()
            state.cancelled = true
            let p = state.process
            let work = state.timeoutWork
            state.timeoutWork = nil
            state.lock.unlock()
            work?.cancel()
            if let p, p.isRunning {
                p.terminate()
            }
        }
    }

    /// Optional macOS zero-download helper: resolves a direct streaming URL via `yt-dlp -g` for generic video sites.
    private static func resolveDirectStreamURLViaYtDlpIfAvailable(
        pageURL: String,
        refererOverride: String? = nil,
        overrideMIMEType: String? = nil
    ) async -> VideoStreamPlaybackPlan.DirectStream? {
        guard let parsedPageURL = URL(string: pageURL),
              WebBookmark.isSafeRemoteFetchURL(parsedPageURL) else {
            return nil
        }
        let candidates = [
            "/opt/homebrew/bin/yt-dlp",
            "/usr/local/bin/yt-dlp",
            "/usr/bin/yt-dlp"
        ]
        guard let binary = candidates.first(where: { FileManager.default.isExecutableFile(atPath: $0) }) else {
            return nil
        }

        let safePageURL = parsedPageURL.absoluteString
        guard let result = await runYtDlpProcess(
            binary: binary,
            arguments: [
                "--no-playlist",
                "--no-warnings",
                "-g",
                "-f", "best[ext=mp4]/best[protocol*=m3u8]/best",
                "--",
                safePageURL
            ],
            captureStdout: true,
            timeoutSeconds: 6.0
        ), result.exitCode == 0 else {
            return nil
        }

        let firstLine = String(data: result.stdout, encoding: .utf8)?
            .split(whereSeparator: \.isNewline)
            .map { String($0).trimmingCharacters(in: .whitespacesAndNewlines) }
            .first(where: { $0.hasPrefix("https://") || $0.hasPrefix("http://") })
        guard let firstLine,
              let streamURL = URL(string: firstLine),
              WebBookmark.isSafeRemoteFetchURL(streamURL) else {
            return nil
        }
        let isHLS = streamURL.pathExtension.lowercased() == "m3u8"
            || streamURL.absoluteString.lowercased().contains(".m3u8")
        return .init(
            url: streamURL,
            httpHeaders: ["Referer": refererOverride ?? safePageURL, "User-Agent": browserUA],
            isHLS: isHLS,
            overrideMIMEType: isHLS ? nil : overrideMIMEType
        )
    }

    /// Optional macOS fallback when a video platform enforces cipher/DASH-only streams and `yt-dlp` is installed locally.
    private static func downloadViaYtDlpIfAvailable(
        pageURL: String,
        to directory: URL,
        baseName: String
    ) async -> URL? {
        guard let parsedPageURL = URL(string: pageURL),
              WebBookmark.isSafeRemoteFetchURL(parsedPageURL) else {
            return nil
        }
        let candidates = [
            "/opt/homebrew/bin/yt-dlp",
            "/usr/local/bin/yt-dlp",
            "/usr/bin/yt-dlp"
        ]
        guard let binary = candidates.first(where: { FileManager.default.isExecutableFile(atPath: $0) }) else {
            return nil
        }

        let safeBase = sanitizedFileName(baseName)
        let outputTemplate = directory.appending(path: "\(safeBase).%(ext)s").path

        guard let result = await runYtDlpProcess(
            binary: binary,
            arguments: [
                "--no-playlist",
                "--no-warnings",
                "-f", "best[ext=mp4]/bestvideo[ext=mp4]+bestaudio[ext=m4a]/best",
                "--merge-output-format", "mp4",
                "-o", outputTemplate,
                "--",
                parsedPageURL.absoluteString
            ],
            captureStdout: false,
            timeoutSeconds: 180.0
        ), result.exitCode == 0 else {
            return nil
        }

        let files = (try? FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.fileSizeKey],
            options: [.skipsHiddenFiles]
        )) ?? []
        return files.first { url in
            let ext = url.pathExtension.lowercased()
            return ["mp4", "mov", "m4v", "webm", "mkv"].contains(ext)
                && url.deletingPathExtension().lastPathComponent.hasPrefix(safeBase)
        }
    }
    #endif

    // MARK: - Helpers (Chapters, Dates, URL Normalization)

    public static func extractTimestampChapters(from text: String) -> [String] {
        let lines = text.split(whereSeparator: \.isNewline).map {
            String($0).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        guard !lines.isEmpty else { return [] }
        let pattern = #"^(\d{1,2}:)?\d{1,2}:\d{2}\s*[-–—·|:]?\s*(.+)$"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }

        var chapters: [String] = []
        for line in lines {
            let range = NSRange(line.startIndex..., in: line)
            if regex.firstMatch(in: line, range: range) != nil, line.count <= 110 {
                chapters.append(line)
                if chapters.count >= 16 { break }
            }
        }
        return chapters.count >= 2 ? chapters : []
    }

    private static func extractConciseDescriptionLead(from text: String) -> String? {
        let lines = text.split(whereSeparator: \.isNewline).map {
            String($0).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        var kept: [String] = []
        for line in lines {
            if line.isEmpty { continue }
            let lower = line.lowercased()
            if lower.hasPrefix("http://") || lower.hasPrefix("https://") || line.hasPrefix("#") {
                continue
            }
            kept.append(line)
            if kept.joined(separator: " ").count >= 220 || kept.count >= 3 {
                break
            }
        }
        let joined = kept.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
        guard joined.count >= 18 else { return nil }
        if joined.count > 300 {
            return String(joined.prefix(296)).trimmingCharacters(in: .whitespacesAndNewlines) + "…"
        }
        return joined
    }

    private static func expandShortRedirect(_ shortURL: URL) async -> URL? {
        guard WebBookmark.isSafeRemoteFetchURL(shortURL) else { return nil }
        var req = URLRequest(url: shortURL, timeoutInterval: 8)
        req.setValue(browserUA, forHTTPHeaderField: "User-Agent")
        guard let (_, resp) = try? await apiSession.data(for: req),
              let finalURL = resp.url,
              WebBookmark.isSafeRemoteFetchURL(finalURL) else {
            return nil
        }
        return finalURL
    }

    private static func normalizedHTTPSURL(_ raw: String?) -> URL? {
        guard let trimmed = raw?.trimmingCharacters(in: .whitespacesAndNewlines), !trimmed.isEmpty else { return nil }
        if trimmed.hasPrefix("//") {
            return URL(string: "https:" + trimmed)
        }
        if trimmed.hasPrefix("http://") {
            return URL(string: "https://" + trimmed.dropFirst(7))
        }
        return URL(string: trimmed)
    }

    private static func intValue(_ any: Any?) -> Int? {
        if let i = any as? Int { return i }
        if let n = any as? NSNumber { return n.intValue }
        if let s = any as? String { return Int(s) }
        return nil
    }

    private static func int64Value(_ any: Any?) -> Int64? {
        if let i = any as? Int64 { return i }
        if let i = any as? Int { return Int64(i) }
        if let n = any as? NSNumber { return n.int64Value }
        if let s = any as? String { return Int64(s) }
        return nil
    }

    private static func formatTimestamp(_ seconds: Int) -> String {
        let clamped = max(0, seconds)
        let h = clamped / 3600
        let m = (clamped % 3600) / 60
        let s = clamped % 60
        if h > 0 {
            return String(format: "%d:%02d:%02d", h, m, s)
        }
        return String(format: "%02d:%02d", m, s)
    }

    private static func formatShortDate(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.string(from: date)
    }

    private static func sanitizedFileName(_ raw: String) -> String {
        let forbidden = CharacterSet(charactersIn: "/:\\?%*|\"<>")
        let cleaned = raw.components(separatedBy: forbidden).joined(separator: "_")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return cleaned.isEmpty ? "CharkleVideo" : String(cleaned.prefix(72))
    }
}

private extension String {
    var nilIfEmpty: String? {
        let trimmed = trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}

// MARK: - Cross-Platform Video Frame Capture Helper (Local MP4/MOV, Progressive HTTP MP4, HLS .m3u8)

/// Captures a crisp video frame at the active playhead for setting as a Charkle asset cover.
/// Works across local video files, progressive HTTP MP4 streams, and adaptive HLS (`.m3u8`) streams
/// without downloading the full video to disk.
public nonisolated enum VideoFrameCapture {
    private static let sharedCIContext = CIContext(options: [.useSoftwareRenderer: false])

    public static func makeVideoOutput() -> AVPlayerItemVideoOutput {
        AVPlayerItemVideoOutput(pixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: Int(kCVPixelFormatType_32BGRA)
        ])
    }

    public static func encodeJPEG(_ cgImage: CGImage) -> Data? {
        MediaArtwork.encode(cgImage, type: .jpeg)
    }

    public static func formattedTimestamp(_ seconds: Double) -> String {
        guard seconds.isFinite && seconds >= 0 else { return "00:00" }
        let total = Int(seconds.rounded())
        let h = total / 3600
        let m = (total % 3600) / 60
        let s = total % 60
        if h > 0 {
            return String(format: "%d:%02d:%02d", h, m, s)
        }
        return String(format: "%02d:%02d", m, s)
    }

    @MainActor
    public static func captureCurrentFrameJPEG(
        from player: AVPlayer,
        videoOutput: AVPlayerItemVideoOutput?
    ) async -> (jpegData: Data, timestampSeconds: Double)? {
        guard let item = player.currentItem else { return nil }
        let currentTime = player.currentTime()
        let seconds = currentTime.isNumeric ? max(0, currentTime.seconds) : 0
        let asset = item.asset

        // Determine if the video track has a non-identity rotation transform (e.g. vertical iPhone video);
        // for rotated non-HLS tracks, AVAssetImageGenerator applies the exact preferredTrackTransform.
        var preferredTransform: CGAffineTransform = .identity
        var hasTrackRotation = false
        if let tracks = try? await asset.loadTracks(withMediaType: .video),
           let firstTrack = tracks.first,
           let preferred = try? await firstTrack.load(.preferredTransform) {
            preferredTransform = preferred
            hasTrackRotation = abs(preferred.b) > 0.01 || abs(preferred.c) > 0.01 || preferred.a < 0 || preferred.d < 0
        }

        // 1. Instant zero-network CVPixelBuffer snapshot (works for HLS `.m3u8`, HTTP MP4, and local videos),
        //    with CIContext rendering & JPEG encoding offloaded off MainActor.
        if !hasTrackRotation,
           let videoOutput,
           let pixelBuffer = videoOutput.copyPixelBuffer(forItemTime: currentTime, itemTimeForDisplay: nil) {
            let bufferBox = UncheckedPixelBufferBox(pixelBuffer)
            if let jpeg = await encodePixelBufferJPEGOffMain(bufferBox, preferredTransform: .identity) {
                return (jpeg, seconds)
            }
        }

        // 2. Precision AVAssetImageGenerator fallback off-main (handles rotated portrait videos & freshly scrubbed frames).
        let targetTime = currentTime.isNumeric ? currentTime : CMTime(seconds: 0, preferredTimescale: 600)
        let assetBox = UncheckedAVAssetBox(asset)
        if let jpeg = await generateFrameJPEGOffMain(assetBox: assetBox, at: targetTime) {
            return (jpeg, seconds)
        }

        // 3. Final pixel-buffer fallback (e.g. rotated HLS stream where AVAssetImageGenerator isn't supported).
        if let videoOutput,
           let pixelBuffer = videoOutput.copyPixelBuffer(forItemTime: currentTime, itemTimeForDisplay: nil) {
            let bufferBox = UncheckedPixelBufferBox(pixelBuffer)
            if let jpeg = await encodePixelBufferJPEGOffMain(bufferBox, preferredTransform: preferredTransform) {
                return (jpeg, seconds)
            }
        }

        return nil
    }

    private nonisolated final class UncheckedAVAssetBox: @unchecked Sendable {
        let asset: AVAsset
        init(_ asset: AVAsset) { self.asset = asset }
    }

    private nonisolated final class UncheckedPixelBufferBox: @unchecked Sendable {
        let pixelBuffer: CVPixelBuffer
        init(_ pixelBuffer: CVPixelBuffer) { self.pixelBuffer = pixelBuffer }
    }

    private static func orientation(for transform: CGAffineTransform) -> CGImagePropertyOrientation {
        if abs(transform.b - 1) < 0.01 && abs(transform.c + 1) < 0.01 {
            return .right
        }
        if abs(transform.b + 1) < 0.01 && abs(transform.c - 1) < 0.01 {
            return .left
        }
        if abs(transform.a + 1) < 0.01 && abs(transform.d + 1) < 0.01 {
            return .down
        }
        return .up
    }

    @concurrent
    private static func encodePixelBufferJPEGOffMain(
        _ bufferBox: UncheckedPixelBufferBox,
        preferredTransform: CGAffineTransform
    ) async -> Data? {
        var ciImage = CIImage(cvPixelBuffer: bufferBox.pixelBuffer)
        let orient = orientation(for: preferredTransform)
        if orient != .up {
            ciImage = ciImage.oriented(orient)
        }
        let extent = ciImage.extent
        guard extent.width > 0, extent.height > 0,
              let cgImage = sharedCIContext.createCGImage(ciImage, from: extent) else {
            return nil
        }
        return encodeJPEG(cgImage)
    }

    @concurrent
    private static func generateFrameJPEGOffMain(assetBox: UncheckedAVAssetBox, at targetTime: CMTime) async -> Data? {
        let generator = AVAssetImageGenerator(asset: assetBox.asset)
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: 1_600, height: 1_600)
        generator.requestedTimeToleranceBefore = CMTime(seconds: 0.25, preferredTimescale: 600)
        generator.requestedTimeToleranceAfter = CMTime(seconds: 0.25, preferredTimescale: 600)
        guard let result = try? await generator.image(at: targetTime) else {
            return nil
        }
        return encodeJPEG(result.image)
    }
}
