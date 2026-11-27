#if canImport(AppKit)
import AppKit
#elseif canImport(UIKit)
import UIKit
#endif
import CoreFoundation
import CoreGraphics
import Darwin
import Foundation
import ImageIO
import Synchronization
import WebKit

/// Parses and extracts arbitrary `http` / `https` web URLs from raw strings or short share text.
public nonisolated enum WebURLParser {
    /// Parses a standalone web URL string (supporting case-insensitive schemes, Unicode paths,
    /// surrounding brackets/quotes, and standalone `www.<host>` URLs).
    public static func parse(_ raw: String) -> URL? {
        let trimmed = stripWrappersAndTrailingPunctuation(raw.trimmingCharacters(in: .whitespacesAndNewlines))
        guard !trimmed.isEmpty, !trimmed.contains(where: \.isWhitespace) else { return nil }

        let lower = trimmed.lowercased()
        let normalized: String
        if lower.hasPrefix("http://") {
            normalized = "http://" + trimmed.dropFirst(7)
        } else if lower.hasPrefix("https://") {
            normalized = "https://" + trimmed.dropFirst(8)
        } else if lower.hasPrefix("www.") {
            let remainder = String(trimmed.dropFirst(4))
            guard remainder.contains("."), !remainder.hasPrefix(".") else { return nil }
            normalized = "https://" + trimmed
        } else {
            return nil
        }

        let candidate = URL(string: normalized) ?? URL(string: normalized, encodingInvalidCharacters: true)
        guard let url = candidate, isValidWebDestination(url) else { return nil }
        return url
    }

    /// Extracts the first web URL from either a standalone URL string or short share copy
    /// (e.g. `"推荐设计站 https://example.com/page 看看"`). Long multi-paragraph notes are
    /// deliberately ignored when `allowEmbeddedInShortText` is true so prose stays a text snippet.
    public static func extractWebURL(from text: String, allowEmbeddedInShortText: Bool = true) -> URL? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        if let direct = parse(trimmed) {
            return direct
        }

        guard allowEmbeddedInShortText else { return nil }
        let lineCount = trimmed.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline).count
        guard trimmed.count <= 320, lineCount <= 5 else { return nil }

        guard let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue) else {
            return nil
        }
        let range = NSRange(trimmed.startIndex..., in: trimmed)
        for match in detector.matches(in: trimmed, options: [], range: range) {
            guard let swiftRange = Range(match.range, in: trimmed) else { continue }
            let matchedSlice = String(trimmed[swiftRange])
            let lowerSlice = matchedSlice.lowercased()
            // Require explicit web prefix so filenames like `README.md` or `photo.png` never match.
            guard lowerSlice.hasPrefix("http://") || lowerSlice.hasPrefix("https://") || lowerSlice.hasPrefix("www.") else {
                continue
            }
            if let parsed = parse(matchedSlice) {
                return parsed
            }
            if let url = match.url, isValidWebDestination(url) {
                return url
            }
        }
        return nil
    }

    /// Returns a clean display domain (lowercased host without a leading `www.`).
    public static func cleanDomain(for url: URL) -> String? {
        guard let host = url.host()?.lowercased(), !host.isEmpty else { return nil }
        if host.hasPrefix("www."), host.count > 4 {
            return String(host.dropFirst(4))
        }
        return host
    }

    private static func isValidWebDestination(_ url: URL) -> Bool {
        guard WebBookmark.isWebURL(url), let host = url.host()?.lowercased(), !host.isEmpty else {
            return false
        }
        if host == "localhost" || host.contains(":") { return true }
        // Accept standard dotted domains and IPv4 addresses; reject single bare tokens like `https://abc`.
        let parts = host.split(separator: ".")
        return parts.count >= 2 && parts.allSatisfy { !$0.isEmpty }
    }

    private static func stripWrappersAndTrailingPunctuation(_ input: String) -> String {
        var s = input
        let pairs: [(Character, Character)] = [
            ("<", ">"), ("\"", "\""), ("'", "'"), ("(", ")"), ("[", "]"), ("「", "」"), ("《", "》"), ("“", "”")
        ]
        let trailingStopChars: Set<Character> = [
            ".", ",", ";", "!", "?", "。", "，", "；", "！", "？", "、", "”", "’", "）", "】", "」", "》", ">", "\""
        ]
        let leadingStopChars: Set<Character> = ["<", "\"", "'", "「", "《", "“", "‘"]

        var changed = true
        while changed && !s.isEmpty {
            changed = false
            while s.count >= 2 {
                var unwrapped = false
                for (open, close) in pairs {
                    if s.first == open && s.last == close {
                        s = String(s.dropFirst().dropLast()).trimmingCharacters(in: .whitespacesAndNewlines)
                        unwrapped = true
                        changed = true
                        break
                    }
                }
                if !unwrapped { break }
            }

            while let last = s.last {
                if trailingStopChars.contains(last) {
                    s.removeLast()
                    changed = true
                } else if last == ")" {
                    let openCount = s.filter { $0 == "(" }.count
                    let closeCount = s.filter { $0 == ")" }.count
                    if closeCount > openCount {
                        s.removeLast()
                        changed = true
                    } else {
                        break
                    }
                } else if last == "]" {
                    let openCount = s.filter { $0 == "[" }.count
                    let closeCount = s.filter { $0 == "]" }.count
                    if closeCount > openCount {
                        s.removeLast()
                        changed = true
                    } else {
                        break
                    }
                } else {
                    break
                }
            }

            while let first = s.first, leadingStopChars.contains(first) {
                s.removeFirst()
                changed = true
            }
        }
        return s
    }
}

/// Deterministic HTML metadata extracted from a webpage document across OpenGraph, Twitter Cards,
/// JSON-LD Schema.org, oEmbed auto-discovery, embedded `<video>` tags, hero `<img>`s, and readable lead text.
public nonisolated struct WebPageParsedHTML: Equatable, Sendable {
    public var title: String?
    public var description: String?
    public var siteName: String?
    public var authorName: String?
    public var publishedAtText: String?
    public var themeColorHex: String?
    public var imageURLs: [URL]
    public var videoURLs: [URL]
    public var iconURLs: [URL]
    public var oEmbedURL: URL?
    public var canonicalURL: URL?
    public var isVideoPage: Bool
    public var durationSeconds: Double?

    public init(
        title: String? = nil,
        description: String? = nil,
        siteName: String? = nil,
        authorName: String? = nil,
        publishedAtText: String? = nil,
        themeColorHex: String? = nil,
        imageURLs: [URL] = [],
        videoURLs: [URL] = [],
        iconURLs: [URL] = [],
        oEmbedURL: URL? = nil,
        canonicalURL: URL? = nil,
        isVideoPage: Bool = false,
        durationSeconds: Double? = nil
    ) {
        self.title = title
        self.description = description
        self.siteName = siteName
        self.authorName = authorName
        self.publishedAtText = publishedAtText
        self.themeColorHex = themeColorHex
        self.imageURLs = imageURLs
        self.videoURLs = videoURLs
        self.iconURLs = iconURLs
        self.oEmbedURL = oEmbedURL
        self.canonicalURL = canonicalURL
        self.isVideoPage = isVideoPage
        self.durationSeconds = durationSeconds
    }
}

/// Resolves arbitrary website URLs into clean titles, readable descriptions/summaries, authors, domains,
/// extractable media attachments, and visual thumbnails across almost any modern website or SPA.
public nonisolated struct WebBookmark: Sendable {
    public var title: String?
    public var description: String?
    public var siteName: String?
    public var authorName: String?
    public var publishedAtText: String?
    public var finalURL: URL?
    public var themeColorHex: String?
    public var poster: CGImage?
    public var favicon: CGImage?
    public var attachments: [SocialMediaAttachment]
    public var isVideoPage: Bool
    public var durationSeconds: Double?

    private static let safariUserAgent =
        "Mozilla/5.0 (Macintosh; Intel Mac OS X 15_0) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.0 Safari/605.1.15"

    public init(
        title: String? = nil,
        description: String? = nil,
        siteName: String? = nil,
        authorName: String? = nil,
        publishedAtText: String? = nil,
        finalURL: URL? = nil,
        themeColorHex: String? = nil,
        poster: CGImage? = nil,
        favicon: CGImage? = nil,
        attachments: [SocialMediaAttachment] = [],
        isVideoPage: Bool = false,
        durationSeconds: Double? = nil
    ) {
        self.title = title
        self.description = description
        self.siteName = siteName
        self.authorName = authorName
        self.publishedAtText = publishedAtText
        self.finalURL = finalURL
        self.themeColorHex = themeColorHex
        self.poster = poster
        self.favicon = favicon
        self.attachments = attachments
        self.isVideoPage = isVideoPage
        self.durationSeconds = durationSeconds
    }

    public static func isWebURL(_ url: URL) -> Bool {
        ["http", "https"].contains(url.scheme?.lowercased() ?? "")
            && url.host() != nil
            && url.user() == nil
            && url.password() == nil
    }

    /// Validates that a remote fetch destination is a public `http`/`https` host (blocking loopback,
    /// link-local, RFC 1918 private networks, CGNAT, ULA, and local mDNS/internal names to prevent SSRF).
    public static func isSafeRemoteFetchURL(_ url: URL) -> Bool {
        guard isWebURL(url), let rawHost = url.host()?.lowercased(), !rawHost.isEmpty else {
            return false
        }
        let host = rawHost.trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
        if host == "localhost"
            || host.hasSuffix(".localhost")
            || host.hasSuffix(".local")
            || host.hasSuffix(".internal")
            || host.hasSuffix(".home.arpa") {
            return false
        }
        // Check IPv4 literal (including dotted-quad and integer/hex/octal obfuscations via inet_aton/inet_pton)
        var addr4 = in_addr()
        if inet_pton(AF_INET, host, &addr4) == 1 || (host.allSatisfy({ $0.isASCII && ($0.isHexDigit || $0 == "." || $0 == "x" || $0 == "X") }) && inet_aton(host, &addr4) != 0) {
            return !isPrivateIPv4(UInt32(bigEndian: addr4.s_addr))
        }
        // Check IPv6 literal (including IPv4-mapped ::ffff:a.b.c.d)
        var addr6 = in6_addr()
        if inet_pton(AF_INET6, host, &addr6) == 1 {
            return !isPrivateIPv6(addr6)
        }
        return true
    }

    private static func isPrivateIPv4(_ ip: UInt32) -> Bool {
        let a = (ip >> 24) & 0xFF
        let b = (ip >> 16) & 0xFF
        if a == 0 { return true }                         // 0.0.0.0/8
        if a == 10 { return true }                        // 10.0.0.0/8
        if a == 100 && (b >= 64 && b <= 127) { return true } // 100.64.0.0/10 (CGNAT)
        if a == 127 { return true }                       // 127.0.0.0/8 (loopback)
        if a == 169 && b == 254 { return true }           // 169.254.0.0/16 (link-local / cloud metadata)
        if a == 172 && (b >= 16 && b <= 31) { return true } // 172.16.0.0/12
        if a == 192 && b == 168 { return true }           // 192.168.0.0/16
        if a >= 224 { return true }                       // multicast / reserved
        return false
    }

    private static func isPrivateIPv6(_ addr: in6_addr) -> Bool {
        var copy = addr
        let bytes: [UInt8] = withUnsafeBytes(of: &copy) { Array($0) }
        guard bytes.count == 16 else { return true }
        // :: (unspecified) and ::1 (loopback)
        if bytes[0..<15].allSatisfy({ $0 == 0 }) && (bytes[15] == 0 || bytes[15] == 1) {
            return true
        }
        // IPv4-mapped ::ffff:0:0/96
        if bytes[0..<10].allSatisfy({ $0 == 0 }) && bytes[10] == 0xFF && bytes[11] == 0xFF {
            let v4 = (UInt32(bytes[12]) << 24) | (UInt32(bytes[13]) << 16) | (UInt32(bytes[14]) << 8) | UInt32(bytes[15])
            return isPrivateIPv4(v4)
        }
        // fc00::/7 (Unique Local Address)
        if (bytes[0] & 0xFE) == 0xFC { return true }
        // fe80::/10 (Link-Local)
        if bytes[0] == 0xFE && (bytes[1] & 0xC0) == 0x80 { return true }
        // ff00::/8 (Multicast)
        if bytes[0] == 0xFF { return true }
        return false
    }

    public static func url(in file: URL) -> URL? {
        guard let data = try? Data(contentsOf: file), data.count < 256_000 else { return nil }
        if let plist = try? PropertyListSerialization.propertyList(from: data, options: [], format: nil),
           let fields = plist as? [String: Any], let value = fields["URL"] as? String {
            return URL(string: value.trimmingCharacters(in: .whitespacesAndNewlines))
        }
        return String(decoding: data, as: UTF8.self).split(whereSeparator: \.isNewline)
            .first(where: { $0.lowercased().hasPrefix("url=") })
            .flatMap { URL(string: String($0.dropFirst(4)).trimmingCharacters(in: .whitespacesAndNewlines)) }
    }

    /// Fetches webpage metadata and thumbnail image with optional headless `WKWebView` screenshot fallback.
    public static func fetch(_ url: URL?, allowWebViewSnapshot: Bool = false) async -> Self {
        guard let url, isWebURL(url) else { return Self() }
        // Never issue network requests or headless WebKit navigation to loopback/private/LAN targets (SSRF guard).
        guard isSafeRemoteFetchURL(url) else {
            return Self(
                title: fallbackTitle(for: url),
                description: nil,
                siteName: WebURLParser.cleanDomain(for: url),
                finalURL: url,
                themeColorHex: nil,
                poster: nil,
                favicon: nil
            )
        }

        var title: String?
        var description: String?
        var siteName: String?
        var authorName: String?
        var publishedAtText: String?
        var finalURL: URL = url
        var themeColorHex: String?
        var poster: CGImage?
        var favicon: CGImage?
        var iconCandidates: [URL] = []
        var discoveredImageURLs: [URL] = []
        var discoveredVideoURLs: [URL] = []
        var isVideoPage = false
        var durationSeconds: Double?
        var networkUnreachable = false

        switch await fetchResponse(
            url,
            referer: nil,
            accept: "text/html,application/xhtml+xml,application/xml;q=0.9,image/avif,image/webp,image/*;q=0.8,*/*;q=0.5",
            limit: 1_048_576,
            imageLimit: 8_388_608
        ) {
        case .success(let responseData, let responseURL, let responseContentType):
            finalURL = responseURL
            let contentType = responseContentType?.lowercased() ?? ""

            // Direct image URL (e.g. pasted direct .png / .jpg / .webp link)
            if contentType.hasPrefix("image/") {
                if let source = CGImageSourceCreateWithData(responseData as CFData, nil),
                   let raster = MediaPipeline.raster(source)?.poster {
                    let filename = responseURL.lastPathComponent.trimmingCharacters(in: .whitespacesAndNewlines)
                    let displayTitle = filename.isEmpty || filename == "/" ? (WebURLParser.cleanDomain(for: responseURL) ?? responseURL.absoluteString) : filename
                    return Self(
                        title: String(displayTitle.prefix(220)),
                        description: nil,
                        siteName: WebURLParser.cleanDomain(for: responseURL),
                        finalURL: responseURL,
                        themeColorHex: nil,
                        poster: raster,
                        favicon: nil,
                        attachments: [SocialMediaAttachment(kind: .photo, url: responseURL.absoluteString, thumbnailURL: responseURL.absoluteString)]
                    )
                }
            }

            let html = decodeHTML(responseData, contentType: responseContentType)
            let parsed = parseHTML(html, baseURL: responseURL)
            title = parsed.title
            description = parsed.description
            siteName = parsed.siteName
            authorName = parsed.authorName
            publishedAtText = parsed.publishedAtText
            themeColorHex = parsed.themeColorHex
            iconCandidates = parsed.iconURLs
            discoveredImageURLs = parsed.imageURLs
            discoveredVideoURLs = parsed.videoURLs
            isVideoPage = parsed.isVideoPage || !parsed.videoURLs.isEmpty
            durationSeconds = parsed.durationSeconds
            if let canonical = parsed.canonicalURL, isSafeRemoteFetchURL(canonical), canonical.host() == responseURL.host() {
                finalURL = canonical
            }

            // Tier 1.5: Universal oEmbed Auto-Discovery (Vimeo, Behance, Dribbble, TikTok, Reddit, Flickr, SoundCloud, etc.)
            if let oEmbedURL = parsed.oEmbedURL,
               let oEmbed = await fetchOEmbed(oEmbedURL, referer: responseURL) {
                if title == nil || title?.isEmpty == true {
                    title = oEmbed.title
                }
                if authorName == nil || authorName?.isEmpty == true {
                    authorName = oEmbed.authorName
                }
                if siteName == nil || siteName?.isEmpty == true {
                    siteName = oEmbed.providerName
                }
                if oEmbed.isVideo {
                    isVideoPage = true
                }
                if let thumb = oEmbed.thumbnailURL,
                   !discoveredImageURLs.contains(thumb) {
                    discoveredImageURLs.insert(thumb, at: 0)
                }
            }

            // Tier 1: Download best OpenGraph / Twitter / oEmbed / JSON-LD / Hero image preview
            for imageURL in discoveredImageURLs.prefix(6) {
                if let fetched = await fetchImage(imageURL, referer: responseURL, minWidth: 160, minHeight: 100) {
                    poster = fetched
                    break
                }
            }

        case .httpError:
            // Site reached but returned non-2xx (e.g. 403/503 to raw URLSession); still allow WebKit snapshot below.
            break

        case .unreachable:
            networkUnreachable = true
        }

        // Tier 2: Real headless WKWebView DOM hydration + snapshot when preview image is missing OR SPA shell gave sparse metadata
        let needsHydratedSnapshot = poster == nil
            || (usablePageTitle(title, fallbackURL: nil) == nil)
            || ((description?.count ?? 0) < 16 && discoveredImageURLs.isEmpty)
        if needsHydratedSnapshot, allowWebViewSnapshot, !networkUnreachable {
            if let snap = await WebPageSnapshotter.capture(url: finalURL) {
                if poster == nil {
                    poster = snap.image
                }
                if usablePageTitle(title, fallbackURL: nil) == nil, let st = snap.title, !st.isEmpty {
                    title = st
                }
                if (description?.isEmpty ?? true), let sd = snap.description, !sd.isEmpty {
                    description = sd
                }
                if (siteName?.isEmpty ?? true), let ss = snap.siteName, !ss.isEmpty {
                    siteName = ss
                }
                if (authorName?.isEmpty ?? true), let sa = snap.authorName, !sa.isEmpty {
                    authorName = sa
                }
                for rawImg in snap.heroImageURLs {
                    if let resolved = resolveRelativeURL(rawImg, baseURL: snap.finalURL ?? finalURL),
                       isWebURL(resolved),
                       !discoveredImageURLs.contains(resolved) {
                        discoveredImageURLs.append(resolved)
                    }
                }
                for rawVid in snap.videoURLs {
                    if let resolved = resolveRelativeURL(rawVid, baseURL: snap.finalURL ?? finalURL),
                       isWebURL(resolved),
                       !discoveredVideoURLs.contains(resolved) {
                        discoveredVideoURLs.append(resolved)
                        isVideoPage = true
                    }
                }
                if let resolvedURL = snap.finalURL, isWebURL(resolvedURL) {
                    finalURL = resolvedURL
                }
            }
        }

        // Tier 3 enrichment: fetch site favicon when falling back to editorial card
        if poster == nil, !networkUnreachable {
            if iconCandidates.isEmpty, let rootFavicon = defaultFaviconURL(for: finalURL) {
                iconCandidates = [rootFavicon]
            }
            for iconURL in iconCandidates.prefix(3) {
                if let icon = await fetchImage(iconURL, referer: finalURL, minWidth: 16, minHeight: 16, limit: 524_288, timeout: 3.0) {
                    favicon = icon
                    break
                }
            }
        }

        // Build clean deduplicated extractable media attachments (videos first, then up to 8 hero/article images)
        var attachments: [SocialMediaAttachment] = []
        var seenAttachmentURLs = Set<String>()
        let firstCoverStr = discoveredImageURLs.first?.absoluteString
        for vidURL in discoveredVideoURLs.prefix(3) {
            let s = vidURL.absoluteString
            if seenAttachmentURLs.insert(s).inserted {
                attachments.append(SocialMediaAttachment(kind: .video, url: s, thumbnailURL: firstCoverStr))
            }
        }
        if isVideoPage && discoveredVideoURLs.isEmpty {
            let pageStr = finalURL.absoluteString
            if seenAttachmentURLs.insert(pageStr).inserted {
                attachments.append(SocialMediaAttachment(kind: .video, url: pageStr, thumbnailURL: firstCoverStr))
            }
        }
        for imgURL in discoveredImageURLs.prefix(8) {
            let s = imgURL.absoluteString
            if seenAttachmentURLs.insert(s).inserted {
                attachments.append(SocialMediaAttachment(kind: .photo, url: s, thumbnailURL: s))
            }
        }

        return Self(
            title: usablePageTitle(title, fallbackURL: url),
            description: description,
            siteName: siteName ?? WebURLParser.cleanDomain(for: finalURL),
            authorName: authorName,
            publishedAtText: publishedAtText,
            finalURL: finalURL,
            themeColorHex: themeColorHex,
            poster: poster,
            favicon: favicon,
            attachments: attachments,
            isVideoPage: isVideoPage,
            durationSeconds: durationSeconds
        )
    }

    /// Returns a clean webpage title, rejecting generic bot/interstitial/error titles.
    public static func usablePageTitle(_ raw: String?, fallbackURL: URL? = nil) -> String? {
        if let candidate = raw?.trimmingCharacters(in: .whitespacesAndNewlines), !candidate.isEmpty {
            let lower = candidate.lowercased()
            let blockedExact: Set<String> = [
                "just a moment...", "just a moment", "attention required!",
                "attention required! | cloudflare", "access denied", "403 forbidden",
                "404 not found", "checking your browser", "verify you are human",
                "please wait...", "loading...", "redirecting..."
            ]
            if !blockedExact.contains(lower),
               !lower.hasPrefix("just a moment"),
               !lower.hasPrefix("attention required") {
                return String(candidate.prefix(220))
            }
        }
        guard let fallbackURL else { return nil }
        return fallbackTitle(for: fallbackURL)
    }

    /// Derives a readable fallback title from a URL's domain and last path segment.
    public static func fallbackTitle(for url: URL) -> String {
        let domain = WebURLParser.cleanDomain(for: url) ?? url.host() ?? "网页书签"
        let segments = url.pathComponents.filter { $0 != "/" && !$0.isEmpty }
        if let last = segments.last?.removingPercentEncoding,
           !last.isEmpty,
           last.count <= 60,
           last.lowercased() != "index.html",
           last.lowercased() != "index.htm" {
            let readable = last.replacingOccurrences(of: "-", with: " ").replacingOccurrences(of: "_", with: " ")
            return "\(readable) — \(domain)"
        }
        return domain
    }

    /// Decodes HTML bytes honoring HTTP `Content-Type` charset, `<meta charset>`, and common CJK/Latin encodings.
    public static func decodeHTML(_ data: Data, contentType: String?) -> String {
        if let charset = extractCharset(fromContentType: contentType),
           let encoding = stringEncoding(forCharset: charset),
           let decoded = String(data: data, encoding: encoding) {
            return decoded
        }

        let headBytes = data.prefix(4_096)
        let asciiHead = String(decoding: headBytes, as: UTF8.self)
        if let metaCharset = extractCharset(fromHTMLHead: asciiHead),
           let encoding = stringEncoding(forCharset: metaCharset),
           let decoded = String(data: data, encoding: encoding) {
            return decoded
        }

        if let utf8 = String(data: data, encoding: .utf8) {
            return utf8
        }
        let gb18030 = String.Encoding(
            rawValue: CFStringConvertEncodingToNSStringEncoding(CFStringEncoding(CFStringEncodings.GB_18030_2000.rawValue))
        )
        if let gb = String(data: data, encoding: gb18030) {
            return gb
        }
        return String(decoding: data, as: UTF8.self)
    }

    /// Parses titles, readable descriptions/summaries, authors, theme colors, oEmbed links,
    /// embedded video URLs, hero/social preview image URLs, and icons from HTML.
    public static func parseHTML(_ html: String, baseURL: URL) -> WebPageParsedHTML {
        let metaMap = extractMetaTags(from: html)
        let jsonLD = extractJSONLDMetadata(from: html)

        let rawTitle = metaMap["og:title"]
            ?? metaMap["twitter:title"]
            ?? jsonLD.headline
            ?? matches(#"(?is)<title\b[^>]*>(.*?)</title\s*>"#, html).first?[1]
            ?? matches(#"(?is)<h1\b[^>]*>(.*?)</h1\s*>"#, html).first?[1]

        let metaDescription = cleanText(
            metaMap["og:description"]
                ?? metaMap["twitter:description"]
                ?? metaMap["description"]
                ?? jsonLD.description,
            maxLength: 520
        )
        let leadParagraph = (metaDescription?.count ?? 0) < 28
            ? extractReadableLeadSummary(from: html)
            : nil
        let finalDescription: String? = {
            if let metaDescription, let leadParagraph, !leadParagraph.isEmpty,
               metaDescription.count < 28, leadParagraph.count > metaDescription.count {
                return leadParagraph
            }
            return metaDescription ?? leadParagraph
        }()

        let rawSiteName = metaMap["og:site_name"]
            ?? metaMap["application-name"]
            ?? jsonLD.publisherName
        let rawAuthor = metaMap["author"]
            ?? metaMap["article:author"]
            ?? metaMap["twitter:creator"]
            ?? metaMap["parsely-author"]
            ?? jsonLD.authorName
        let rawPublished = metaMap["article:published_time"]
            ?? metaMap["og:updated_time"]
            ?? metaMap["pubdate"]
            ?? jsonLD.datePublished
        let themeHex = metaMap["theme-color"].flatMap(normalizeHexColor)

        var seenImages: Set<String> = []
        var imageURLs: [URL] = []
        func appendImage(_ raw: String?) {
            guard let resolved = resolveRelativeURL(raw, baseURL: baseURL),
                  isWebURL(resolved),
                  !isLikelyDecorativeOrTrackingImage(resolved),
                  seenImages.insert(resolved.absoluteString).inserted else { return }
            imageURLs.append(resolved)
        }

        for key in ["og:image:secure_url", "og:image", "og:image:url", "twitter:image", "twitter:image:src", "msapplication-tileimage"] {
            appendImage(metaMap[key])
        }

        var seenVideos: Set<String> = []
        var videoURLs: [URL] = []
        func appendVideo(_ raw: String?) {
            guard let resolved = resolveRelativeURL(raw, baseURL: baseURL),
                  isWebURL(resolved),
                  seenVideos.insert(resolved.absoluteString).inserted else { return }
            videoURLs.append(resolved)
        }

        for key in ["og:video:secure_url", "og:video:url", "og:video", "twitter:player:stream"] {
            if let raw = metaMap[key], looksLikeDirectVideoURL(raw) {
                appendVideo(raw)
            }
        }
        for v in jsonLD.videoURLs {
            appendVideo(v)
        }

        var seenIcons: Set<String> = []
        var iconURLs: [URL] = []
        var appleTouchIcons: [URL] = []
        var standardIcons: [URL] = []
        var oEmbedURL: URL?
        var canonicalURL: URL?
        for link in extractLinkTags(from: html) {
            let rel = (link["rel"] ?? "").lowercased()
            let relTokens = Set(rel.split(whereSeparator: \.isWhitespace).map(String.init))
            guard let href = link["href"], let resolved = resolveRelativeURL(href, baseURL: baseURL), isWebURL(resolved) else {
                continue
            }
            if relTokens.contains("alternate"),
               let type = link["type"]?.lowercased(),
               type.contains("json+oembed"),
               oEmbedURL == nil {
                oEmbedURL = resolved
            } else if relTokens.contains("canonical"), canonicalURL == nil {
                canonicalURL = resolved
            } else if relTokens.contains("image_src") {
                appendImage(resolved.absoluteString)
            } else if relTokens.contains("apple-touch-icon") || relTokens.contains("apple-touch-icon-precomposed") {
                if seenIcons.insert(resolved.absoluteString).inserted {
                    appleTouchIcons.append(resolved)
                }
            } else if relTokens.contains("icon") {
                if seenIcons.insert(resolved.absoluteString).inserted {
                    standardIcons.append(resolved)
                }
            }
        }
        iconURLs.append(contentsOf: appleTouchIcons)
        iconURLs.append(contentsOf: standardIcons)
        if let fallbackFavicon = defaultFaviconURL(for: baseURL),
           seenIcons.insert(fallbackFavicon.absoluteString).inserted {
            iconURLs.append(fallbackFavicon)
        }

        // JSON-LD images & VideoObject thumbnails
        for ldImage in jsonLD.imageURLs {
            appendImage(ldImage)
        }

        // HTML `<video>` / `<source>` extraction (poster + direct MP4/WebM sources)
        for videoTag in matches(#"(?is)<video\b[^>]*>"#, html).prefix(6) {
            let attrs = parseTagAttributes(videoTag[0])
            appendImage(attrs["poster"])
            if let src = attrs["src"], looksLikeDirectVideoURL(src) {
                appendVideo(src)
            }
        }
        for sourceTag in matches(#"(?is)<source\b[^>]*>"#, html).prefix(12) {
            let attrs = parseTagAttributes(sourceTag[0])
            let type = (attrs["type"] ?? "").lowercased()
            if let src = attrs["src"], (type.hasPrefix("video/") || looksLikeDirectVideoURL(src)) {
                appendVideo(src)
            }
        }

        // Hero / article `<img>` extraction (including lazy-loaded `data-src`, `data-original`, `srcset`)
        for imgCandidate in extractHeroBodyImageURLs(from: html, limit: 10) {
            appendImage(imgCandidate)
        }

        let ogType = (metaMap["og:type"] ?? "").lowercased()
        let isVideoPage = ogType.hasPrefix("video")
            || jsonLD.isVideoObject
            || !videoURLs.isEmpty
            || metaMap["og:video"] != nil
            || metaMap["og:video:url"] != nil

        return WebPageParsedHTML(
            title: cleanText(rawTitle, maxLength: 220),
            description: finalDescription,
            siteName: cleanText(rawSiteName, maxLength: 80),
            authorName: cleanText(rawAuthor, maxLength: 80),
            publishedAtText: cleanText(rawPublished, maxLength: 32).map { String($0.prefix(16)) },
            themeColorHex: themeHex,
            imageURLs: imageURLs,
            videoURLs: videoURLs,
            iconURLs: iconURLs,
            oEmbedURL: oEmbedURL,
            canonicalURL: canonicalURL,
            isVideoPage: isVideoPage,
            durationSeconds: jsonLD.durationSeconds
        )
    }

    // MARK: - Networking

    private enum FetchOutcome: Sendable {
        case success(data: Data, url: URL, contentType: String?)
        case httpError(statusCode: Int)
        case unreachable
    }

    private static func fetchResponse(
        _ url: URL,
        referer: URL?,
        accept: String,
        limit: Int,
        imageLimit: Int? = nil,
        timeout: TimeInterval = 7.0
    ) async -> FetchOutcome {
        guard isSafeRemoteFetchURL(url) else { return .unreachable }
        let config = URLSessionConfiguration.ephemeral
        config.httpShouldSetCookies = false
        config.timeoutIntervalForRequest = timeout
        config.timeoutIntervalForResource = timeout + 2.0
        let delegate = BoundedFetchDelegate(limit: limit, imageLimit: imageLimit)
        let session = URLSession(configuration: config, delegate: delegate, delegateQueue: nil)
        defer { session.invalidateAndCancel() }

        var request = URLRequest(url: url, timeoutInterval: timeout)
        request.setValue(safariUserAgent, forHTTPHeaderField: "User-Agent")
        request.setValue(accept, forHTTPHeaderField: "Accept")
        request.setValue("zh-CN,zh;q=0.9,en-US;q=0.8,en;q=0.7", forHTTPHeaderField: "Accept-Language")
        if let referer {
            request.setValue(referer.absoluteString, forHTTPHeaderField: "Referer")
        }

        let task = session.dataTask(with: request)
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                delegate.start(task: task, continuation: continuation)
            }
        } onCancel: {
            task.cancel()
        }
    }

    private final class BoundedFetchDelegate: NSObject, URLSessionDataDelegate, @unchecked Sendable {
        private struct State {
            var data = Data()
            var effectiveLimit: Int
            var contentType: String?
            var finalURL: URL?
            var statusCode: Int = 0
            var reachedLimit = false
            var unsafeRedirect = false
            var continuation: CheckedContinuation<FetchOutcome, Never>?
            var finishedOutcome: FetchOutcome?
        }

        private let limit: Int
        private let imageLimit: Int?
        private let state: Mutex<State>

        init(limit: Int, imageLimit: Int?) {
            self.limit = limit
            self.imageLimit = imageLimit
            self.state = Mutex(State(effectiveLimit: limit))
        }

        func start(task: URLSessionDataTask, continuation: CheckedContinuation<FetchOutcome, Never>) {
            let earlyOutcome: FetchOutcome? = state.withLock { st in
                if let already = st.finishedOutcome {
                    st.finishedOutcome = nil
                    return already
                }
                st.continuation = continuation
                return nil
            }
            if let earlyOutcome {
                continuation.resume(returning: earlyOutcome)
                return
            }
            task.resume()
        }

        func urlSession(
            _ session: URLSession,
            task: URLSessionTask,
            willPerformHTTPRedirection response: HTTPURLResponse,
            newRequest request: URLRequest,
            completionHandler: @escaping (URLRequest?) -> Void
        ) {
            guard let target = request.url, WebBookmark.isSafeRemoteFetchURL(target) else {
                state.withLock { $0.unsafeRedirect = true }
                completionHandler(nil)
                task.cancel()
                return
            }
            completionHandler(request)
        }

        func urlSession(
            _ session: URLSession,
            dataTask: URLSessionDataTask,
            didReceive response: URLResponse,
            completionHandler: @escaping (URLSession.ResponseDisposition) -> Void
        ) {
            guard let http = response as? HTTPURLResponse,
                  let final = http.url,
                  WebBookmark.isSafeRemoteFetchURL(final) else {
                state.withLock { $0.unsafeRedirect = true }
                completionHandler(.cancel)
                return
            }
            let contentType = http.value(forHTTPHeaderField: "Content-Type")
            let effective = (contentType?.lowercased().hasPrefix("image/") == true)
                ? (imageLimit ?? limit)
                : limit
            state.withLock { st in
                st.statusCode = http.statusCode
                st.finalURL = final
                st.contentType = contentType
                st.effectiveLimit = effective
                if http.expectedContentLength > 0 {
                    st.data.reserveCapacity(min(effective, Int(min(http.expectedContentLength, Int64(effective)))))
                }
            }
            guard (200..<300).contains(http.statusCode) else {
                completionHandler(.cancel)
                return
            }
            completionHandler(.allow)
        }

        func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
            let shouldStop = state.withLock { st -> Bool in
                let remaining = st.effectiveLimit - st.data.count
                guard remaining > 0 else {
                    st.reachedLimit = true
                    return true
                }
                if data.count >= remaining {
                    st.data.append(data.prefix(remaining))
                    st.reachedLimit = true
                    return true
                }
                st.data.append(data)
                return false
            }
            if shouldStop {
                dataTask.cancel()
            }
        }

        func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: (any Error)?) {
            let snapshot = state.withLock { ($0.data, $0.finalURL, $0.contentType, $0.statusCode, $0.reachedLimit, $0.unsafeRedirect) }
            let outcome: FetchOutcome
            if snapshot.5 {
                outcome = .unreachable
            } else if snapshot.4, let final = snapshot.1, (200..<300).contains(snapshot.3) {
                outcome = .success(data: snapshot.0, url: final, contentType: snapshot.2)
            } else if let error {
                if snapshot.3 > 0 && !(200..<300).contains(snapshot.3) {
                    outcome = .httpError(statusCode: snapshot.3)
                } else if let urlError = error as? URLError {
                    switch urlError.code {
                    case .cannotFindHost, .cannotConnectToHost, .notConnectedToInternet,
                         .networkConnectionLost, .dnsLookupFailed, .internationalRoamingOff,
                         .dataNotAllowed, .unsupportedURL, .badURL:
                        outcome = .unreachable
                    default:
                        outcome = .httpError(statusCode: 0)
                    }
                } else {
                    outcome = .unreachable
                }
            } else if let final = snapshot.1, (200..<300).contains(snapshot.3) {
                outcome = .success(data: snapshot.0, url: final, contentType: snapshot.2)
            } else {
                outcome = .httpError(statusCode: snapshot.3)
            }

            let continuation: CheckedContinuation<FetchOutcome, Never>? = state.withLock { st in
                if let cont = st.continuation {
                    st.continuation = nil
                    return cont
                }
                st.finishedOutcome = outcome
                return nil
            }
            continuation?.resume(returning: outcome)
        }
    }

    private static func fetchImage(
        _ url: URL,
        referer: URL?,
        minWidth: Int,
        minHeight: Int,
        limit: Int = 6_291_456,
        timeout: TimeInterval = 6.0
    ) async -> CGImage? {
        guard isWebURL(url) else { return nil }
        guard case .success(let data, _, _) = await fetchResponse(
            url,
            referer: referer,
            accept: "image/avif,image/webp,image/png,image/jpeg,image/*;q=0.8",
            limit: limit,
            imageLimit: limit,
            timeout: timeout
        ) else {
            return nil
        }
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let image = MediaPipeline.raster(source)?.poster,
              image.width >= minWidth,
              image.height >= minHeight else {
            return nil
        }
        let ratio = Double(image.width) / Double(max(1, image.height))
        // Guard against extreme 1px tracking banners
        if minWidth >= 100 && (ratio > 6.5 || ratio < 0.15) {
            return nil
        }
        return image
    }

    // MARK: - HTML & Charset Helpers

    private static func defaultFaviconURL(for url: URL) -> URL? {
        guard let scheme = url.scheme, let host = url.host() else { return nil }
        var comps = URLComponents()
        comps.scheme = scheme
        comps.host = host
        comps.port = url.port
        comps.path = "/favicon.ico"
        return comps.url
    }

    private static func resolveRelativeURL(_ raw: String?, baseURL: URL) -> URL? {
        guard let raw else { return nil }
        let decoded = decodeEntities(raw).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !decoded.isEmpty else { return nil }
        if decoded.hasPrefix("//") {
            let scheme = baseURL.scheme ?? "https"
            let full = "\(scheme):\(decoded)"
            return URL(string: full) ?? URL(string: full, encodingInvalidCharacters: true)
        }
        if let direct = URL(string: decoded, relativeTo: baseURL)?.absoluteURL {
            return direct
        }
        return URL(string: decoded, encodingInvalidCharacters: true)
    }

    private static func extractMetaTags(from html: String) -> [String: String] {
        var result: [String: String] = [:]
        for tag in matches(#"(?is)<meta\b[^>]*>"#, html) {
            let attrs = parseTagAttributes(tag[0])
            guard let key = (attrs["property"] ?? attrs["name"])?.lowercased(),
                  let content = attrs["content"],
                  !content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                continue
            }
            if result[key] == nil {
                result[key] = content
            }
        }
        return result
    }

    private static func extractLinkTags(from html: String) -> [[String: String]] {
        matches(#"(?is)<link\b[^>]*>"#, html).map { parseTagAttributes($0[0]) }
    }

    private static func parseTagAttributes(_ tag: String) -> [String: String] {
        let fields = matches(#"(?is)([a-z][\w:-]*)\s*=\s*(?:"([^"]*)"|'([^']*)'|([^\s>]+))"#, tag)
        var attributes: [String: String] = [:]
        for field in fields {
            if let value = field.dropFirst(2).first(where: { !$0.isEmpty }) {
                attributes[field[1].lowercased()] = value
            }
        }
        return attributes
    }

    private struct OEmbedPayload: Sendable {
        let title: String?
        let authorName: String?
        let providerName: String?
        let thumbnailURL: URL?
        let isVideo: Bool
    }

    private static func fetchOEmbed(_ url: URL, referer: URL) async -> OEmbedPayload? {
        guard isSafeRemoteFetchURL(url) else { return nil }
        guard case .success(let data, _, _) = await fetchResponse(
            url,
            referer: referer,
            accept: "application/json,text/json,*/*;q=0.5",
            limit: 131_072,
            timeout: 4.5
        ),
        let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }
        let title = cleanText(json["title"] as? String, maxLength: 220)
        let author = cleanText(json["author_name"] as? String, maxLength: 80)
        let provider = cleanText(json["provider_name"] as? String, maxLength: 80)
        let thumb = resolveRelativeURL(json["thumbnail_url"] as? String, baseURL: referer)
        let isVideo = ((json["type"] as? String)?.lowercased() == "video")
        return OEmbedPayload(
            title: title,
            authorName: author,
            providerName: provider,
            thumbnailURL: thumb,
            isVideo: isVideo
        )
    }

    private struct JSONLDExtracted {
        var headline: String?
        var description: String?
        var authorName: String?
        var publisherName: String?
        var datePublished: String?
        var imageURLs: [String] = []
        var videoURLs: [String] = []
        var isVideoObject: Bool = false
        var durationSeconds: Double?
    }

    private static func extractJSONLDMetadata(from html: String) -> JSONLDExtracted {
        var out = JSONLDExtracted()
        let scripts = matches(#"(?is)<script\b[^>]*type\s*=\s*["']application/ld\+json["'][^>]*>(.*?)</script\s*>"#, html)
        for script in scripts.prefix(6) {
            let trimmed = script[1].trimmingCharacters(in: .whitespacesAndNewlines)
            guard let data = trimmed.data(using: .utf8),
                  let obj = try? JSONSerialization.jsonObject(with: data) else { continue }
            collectJSONLDFields(from: obj, into: &out)
        }
        return out
    }

    private static func collectJSONLDFields(from value: Any, into out: inout JSONLDExtracted) {
        if let dict = value as? [String: Any] {
            let typeVal: String = {
                if let s = dict["@type"] as? String { return s.lowercased() }
                if let arr = dict["@type"] as? [String] { return arr.joined(separator: " ").lowercased() }
                return ""
            }()
            if typeVal.contains("videoobject") {
                out.isVideoObject = true
            }
            if out.headline == nil {
                out.headline = (dict["headline"] as? String) ?? (dict["name"] as? String)
            }
            if out.description == nil {
                out.description = dict["description"] as? String
            }
            if out.datePublished == nil {
                out.datePublished = (dict["datePublished"] as? String) ?? (dict["uploadDate"] as? String)
            }
            if out.authorName == nil {
                if let s = dict["author"] as? String {
                    out.authorName = s
                } else if let aDict = dict["author"] as? [String: Any] {
                    out.authorName = aDict["name"] as? String
                } else if let aArr = dict["author"] as? [[String: Any]] {
                    out.authorName = aArr.first?["name"] as? String
                }
            }
            if out.publisherName == nil, let pub = dict["publisher"] as? [String: Any] {
                out.publisherName = pub["name"] as? String
            }
            if out.durationSeconds == nil, let isoDur = dict["duration"] as? String {
                out.durationSeconds = parseISO8601Duration(isoDur)
            }
            if out.videoURLs.count < 4, let contentURL = dict["contentUrl"] as? String, looksLikeDirectVideoURL(contentURL) {
                out.videoURLs.append(contentURL)
            }
            for imgKey in ["thumbnailUrl", "image"] where out.imageURLs.count < 6 {
                if let img = dict[imgKey] {
                    if let str = img as? String {
                        out.imageURLs.append(str)
                    } else if let arr = img as? [Any] {
                        for elem in arr.prefix(3) where out.imageURLs.count < 6 {
                            if let str = elem as? String {
                                out.imageURLs.append(str)
                            } else if let obj = elem as? [String: Any], let u = obj["url"] as? String {
                                out.imageURLs.append(u)
                            }
                        }
                    } else if let imgDict = img as? [String: Any], let u = imgDict["url"] as? String {
                        out.imageURLs.append(u)
                    }
                }
            }
            if let graph = dict["@graph"] as? [Any] {
                for node in graph {
                    collectJSONLDFields(from: node, into: &out)
                }
            }
        } else if let arr = value as? [Any] {
            for elem in arr {
                collectJSONLDFields(from: elem, into: &out)
            }
        }
    }

    private static func parseISO8601Duration(_ raw: String) -> Double? {
        let upper = raw.uppercased()
        guard upper.hasPrefix("PT") else { return nil }
        let pattern = #"^PT(?:(\d+)H)?(?:(\d+)M)?(?:(\d+(?:\.\d+)?)S)?$"#
        guard let hit = matches(pattern, upper).first else { return nil }
        let h = Double(hit[1]) ?? 0
        let m = Double(hit[2]) ?? 0
        let s = Double(hit[3]) ?? 0
        let total = h * 3600 + m * 60 + s
        return total > 0 ? total : nil
    }

    private static func looksLikeDirectVideoURL(_ raw: String) -> Bool {
        let lower = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard lower.hasPrefix("http://") || lower.hasPrefix("https://") || lower.hasPrefix("//") || lower.hasPrefix("/") else {
            return false
        }
        return lower.contains(".mp4") || lower.contains(".mov") || lower.contains(".m4v") || lower.contains(".webm")
    }

    private static func isLikelyDecorativeOrTrackingImage(_ url: URL) -> Bool {
        let lower = url.absoluteString.lowercased()
        if lower.hasPrefix("data:") || lower.hasSuffix(".svg") || lower.contains(".svg?") || lower.hasSuffix(".ico") {
            return true
        }
        let noisyTokens = [
            "favicon", "apple-touch-icon", "sprite", "spacer", "pixel.", "1x1",
            "tracking", "analytics", "badge", "emoji", "gravatar", "avatar_default"
        ]
        return noisyTokens.contains(where: { lower.contains($0) })
    }

    private static func extractHeroBodyImageURLs(from html: String, limit: Int) -> [String] {
        // Focus on `<article>` or `<main>` when available so nav logos/sidebar thumbnails don't pollute candidates
        let scopedHTML: String = {
            if let article = matches(#"(?is)<article\b[^>]*>(.*?)</article\s*>"#, html).first?[1], article.count >= 120 {
                return article
            }
            if let main = matches(#"(?is)<main\b[^>]*>(.*?)</main\s*>"#, html).first?[1], main.count >= 120 {
                return main
            }
            return html
        }()

        var found: [String] = []
        for tag in matches(#"(?is)<img\b[^>]*>"#, scopedHTML).prefix(40) {
            let attrs = parseTagAttributes(tag[0])
            // Skip tiny explicit icons/avatars
            if let wStr = attrs["width"], let w = Int(wStr.filter(\.isNumber)), w > 0, w < 140 { continue }
            if let hStr = attrs["height"], let h = Int(hStr.filter(\.isNumber)), h > 0, h < 90 { continue }
            let candidate = attrs["data-original"]
                ?? attrs["data-src"]
                ?? attrs["data-lazy-src"]
                ?? attrs["data-actualsrc"]
                ?? largestURLFromSrcSet(attrs["srcset"] ?? attrs["data-srcset"])
                ?? attrs["src"]
            if let candidate, !candidate.isEmpty, !candidate.lowercased().hasPrefix("data:") {
                found.append(candidate)
                if found.count >= limit { break }
            }
        }
        return found
    }

    private static func largestURLFromSrcSet(_ srcset: String?) -> String? {
        guard let srcset, !srcset.isEmpty else { return nil }
        var bestURL: String?
        var bestScore = -1
        for entry in srcset.split(separator: ",") {
            let parts = entry.trimmingCharacters(in: .whitespacesAndNewlines).split(whereSeparator: \.isWhitespace)
            guard let urlPart = parts.first else { continue }
            let descriptor = parts.count > 1 ? String(parts[1]).lowercased() : ""
            let score: Int = {
                if descriptor.hasSuffix("w"), let w = Int(descriptor.dropLast()) { return w }
                if descriptor.hasSuffix("x"), let d = Double(descriptor.dropLast()) { return Int(d * 1000) }
                return 500
            }()
            if score >= bestScore {
                bestScore = score
                bestURL = String(urlPart)
            }
        }
        return bestURL
    }

    private static func extractReadableLeadSummary(from html: String) -> String? {
        var stripped = html
        for noisy in [
            #"(?is)<script\b[^>]*>.*?</script\s*>"#,
            #"(?is)<style\b[^>]*>.*?</style\s*>"#,
            #"(?is)<noscript\b[^>]*>.*?</noscript\s*>"#,
            #"(?is)<nav\b[^>]*>.*?</nav\s*>"#,
            #"(?is)<header\b[^>]*>.*?</header\s*>"#,
            #"(?is)<footer\b[^>]*>.*?</footer\s*>"#
        ] {
            stripped = stripped.replacingOccurrences(of: noisy, with: " ", options: .regularExpression)
        }
        let scope: String = {
            if let article = matches(#"(?is)<article\b[^>]*>(.*?)</article\s*>"#, stripped).first?[1], article.count >= 80 {
                return article
            }
            if let main = matches(#"(?is)<main\b[^>]*>(.*?)</main\s*>"#, stripped).first?[1], main.count >= 80 {
                return main
            }
            return stripped
        }()

        var paragraphs: [String] = []
        for match in matches(#"(?is)<p\b[^>]*>(.*?)</p\s*>"#, scope).prefix(16) {
            guard let text = cleanText(match[1], maxLength: 360), text.count >= 24 else { continue }
            let lower = text.lowercased()
            if lower.contains("cookie") && lower.contains("privacy") { continue }
            paragraphs.append(text)
            if paragraphs.joined(separator: "\n").count >= 280 || paragraphs.count >= 2 {
                break
            }
        }
        let joined = paragraphs.joined(separator: "\n\n").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !joined.isEmpty else { return nil }
        return String(joined.prefix(460))
    }

    private static func extractCharset(fromContentType contentType: String?) -> String? {
        guard let contentType else { return nil }
        return matches(#"(?i)charset\s*=\s*["']?([a-z0-9._-]+)"#, contentType).first?[1].lowercased()
    }

    private static func extractCharset(fromHTMLHead head: String) -> String? {
        if let hit = matches(#"(?is)<meta\b[^>]*charset\s*=\s*["']?\s*([a-z0-9._-]+)"#, head).first?[1] {
            return hit.lowercased()
        }
        return nil
    }

    private static func stringEncoding(forCharset charset: String) -> String.Encoding? {
        switch charset.lowercased() {
        case "utf-8", "utf8":
            return .utf8
        case "gbk", "gb2312", "gb18030", "gb_2312-80":
            return String.Encoding(
                rawValue: CFStringConvertEncodingToNSStringEncoding(CFStringEncoding(CFStringEncodings.GB_18030_2000.rawValue))
            )
        case "big5", "big5-hkscs":
            return String.Encoding(
                rawValue: CFStringConvertEncodingToNSStringEncoding(CFStringEncoding(CFStringEncodings.big5.rawValue))
            )
        case "shift_jis", "shift-jis", "sjis", "cp932", "windows-31j":
            return .shiftJIS
        case "euc-jp":
            return .japaneseEUC
        case "iso-8859-1", "latin1", "latin-1":
            return .isoLatin1
        case "windows-1252":
            return .windowsCP1252
        default:
            return nil
        }
    }

    private static func normalizeHexColor(_ raw: String) -> String? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasPrefix("#") else { return nil }
        let body = String(trimmed.dropFirst())
        if body.count == 6, body.allSatisfy(\.isHexDigit) {
            return "#\(body.uppercased())"
        }
        if body.count == 3, body.allSatisfy(\.isHexDigit) {
            let expanded = body.map { "\($0)\($0)" }.joined()
            return "#\(expanded.uppercased())"
        }
        return nil
    }

    private static func cleanText(_ raw: String?, maxLength: Int) -> String? {
        guard let raw else { return nil }
        let stripped = raw.replacingOccurrences(of: #"(?is)<[^>]+>"#, with: " ", options: .regularExpression)
        let decoded = decodeEntities(stripped)
        let compact = decoded.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        guard !compact.isEmpty else { return nil }
        return String(compact.prefix(maxLength))
    }

    private static func matches(_ pattern: String, _ input: String) -> [[String]] {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }
        return regex.matches(in: input, range: NSRange(input.startIndex..., in: input)).map { hit in
            (0..<hit.numberOfRanges).map { index in
                Range(hit.range(at: index), in: input).map { String(input[$0]) } ?? ""
            }
        }
    }

    private static func decodeEntities(_ input: String) -> String {
        let entities = [
            "&amp;": "&", "&quot;": "\"", "&apos;": "'", "&#39;": "'",
            "&lt;": "<", "&gt;": ">", "&nbsp;": " ", "&mdash;": "—", "&ndash;": "–"
        ]
        var output = input
        for code in matches(#"&#(x[0-9A-Fa-f]+|[0-9]+);"#, input) {
            let hex = code[1].lowercased().hasPrefix("x")
            if let number = UInt32(hex ? String(code[1].dropFirst()) : code[1], radix: hex ? 16 : 10),
               let scalar = UnicodeScalar(number) {
                output = output.replacingOccurrences(of: code[0], with: String(scalar))
            }
        }
        // Decode ampersands last so a double-escaped character is only unescaped once.
        for (key, value) in entities where key != "&amp;" {
            output = output.replacingOccurrences(of: key, with: value)
        }
        return output.replacingOccurrences(of: "&amp;", with: "&")
    }
}

// MARK: - Ephemeral Offscreen WKWebView Webpage Snapshotter (Tier 2 Fallback)

private struct WebPageSnapshotResult: Sendable {
    let image: CGImage
    let title: String?
    let description: String?
    let siteName: String?
    let authorName: String?
    let heroImageURLs: [String]
    let videoURLs: [String]
    let finalURL: URL?
}

/// Captures a crisp `1280×800` visual thumbnail of webpages that lack an OpenGraph/Twitter preview image
/// or require client-side rendering. Uses a non-persistent `WKWebsiteDataStore`, disables media autoplay,
/// enforces a strict timeout, and tears down immediately after snapshot capture.
@MainActor
private final class WebPageSnapshotter: NSObject, WKNavigationDelegate {
    private var webView: WKWebView?
    private var continuation: CheckedContinuation<WebPageSnapshotResult?, Never>?
    private var timeoutTask: Task<Void, Never>?
    private var settleTask: Task<Void, Never>?
    private var isCompleted = false
    private var isCapturing = false

    static func canCaptureInCurrentProcess() -> Bool {
        guard ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] == nil else { return false }
        #if canImport(AppKit)
        guard let app = NSApp else { return false }
        return app.activationPolicy() != .prohibited
        #else
        return !Bundle.main.bundlePath.hasSuffix(".appex")
        #endif
    }

    static func capture(url: URL, timeoutSeconds: Double = 6.5) async -> WebPageSnapshotResult? {
        guard canCaptureInCurrentProcess(), WebBookmark.isSafeRemoteFetchURL(url) else { return nil }
        let runner = WebPageSnapshotter()
        return await withTaskCancellationHandler {
            await runner.run(url: url, timeoutSeconds: timeoutSeconds)
        } onCancel: {
            Task { @MainActor in
                runner.finish(with: nil)
            }
        }
    }

    private func run(url: URL, timeoutSeconds: Double) async -> WebPageSnapshotResult? {
        guard !Task.isCancelled else { return nil }
        return await withCheckedContinuation { continuation in
            if Task.isCancelled {
                continuation.resume(returning: nil)
                return
            }
            self.continuation = continuation

            let config = WKWebViewConfiguration()
            config.websiteDataStore = .nonPersistent()
            config.mediaTypesRequiringUserActionForPlayback = .all
            config.suppressesIncrementalRendering = true
            let prefs = WKWebpagePreferences()
            prefs.allowsContentJavaScript = true
            config.defaultWebpagePreferences = prefs

            let frame = CGRect(x: 0, y: 0, width: 1280, height: 800)
            let wv = WKWebView(frame: frame, configuration: config)
            wv.navigationDelegate = self
            wv.customUserAgent =
                "Mozilla/5.0 (Macintosh; Intel Mac OS X 15_0) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.0 Safari/605.1.15"
            self.webView = wv

            var request = URLRequest(url: url, timeoutInterval: timeoutSeconds)
            request.setValue("zh-CN,zh;q=0.9,en-US;q=0.8,en;q=0.7", forHTTPHeaderField: "Accept-Language")
            wv.load(request)

            timeoutTask = Task { [weak self] in
                try? await Task.sleep(for: .seconds(timeoutSeconds))
                guard !Task.isCancelled, let self, !self.isCompleted, !self.isCapturing else { return }
                // If main document already painted (e.g. third-party trackers stalled didFinish), still take snapshot.
                if let active = self.webView, active.estimatedProgress >= 0.45 {
                    await self.captureAndFinish()
                } else {
                    self.finish(with: nil)
                }
            }
        }
    }

    func webView(
        _ webView: WKWebView,
        decidePolicyFor navigationAction: WKNavigationAction
    ) async -> WKNavigationActionPolicy {
        guard let target = navigationAction.request.url else {
            return .cancel
        }
        if target.scheme?.lowercased() == "about" {
            return .allow
        }
        guard WebBookmark.isSafeRemoteFetchURL(target) else {
            if navigationAction.targetFrame?.isMainFrame == true {
                finish(with: nil)
            }
            return .cancel
        }
        return .allow
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        guard !isCompleted, !isCapturing else { return }
        settleTask?.cancel()
        settleTask = Task { [weak self] in
            // Allow webfonts and hero images a brief paint window before snapshotting.
            try? await Task.sleep(for: .milliseconds(420))
            guard !Task.isCancelled, let self, !self.isCompleted, !self.isCapturing else { return }
            await self.captureAndFinish()
        }
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: any Error) {
        if (error as NSError).code == NSURLErrorCancelled { return }
        finish(with: nil)
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: any Error) {
        if (error as NSError).code == NSURLErrorCancelled { return }
        finish(with: nil)
    }

    private func captureAndFinish() async {
        guard !isCompleted, !isCapturing, let wv = webView else { return }
        isCapturing = true

        let probeJS = """
        (() => {
          const meta = (s) => document.querySelector(s)?.content?.trim() || '';
          const title = meta('meta[property="og:title"]') || document.title?.trim() || document.querySelector('h1')?.innerText?.trim() || '';
          let desc = meta('meta[property="og:description"]') || meta('meta[name="description"]') || '';
          if (desc.length < 24) {
            const root = document.querySelector('article, main') || document.body;
            const ps = Array.from(root?.querySelectorAll('p') || [])
              .map(p => (p.innerText || '').replace(/\\s+/g, ' ').trim())
              .filter(t => t.length >= 24 && !(t.toLowerCase().includes('cookie') && t.toLowerCase().includes('privacy')));
            if (ps.length > 0) desc = ps.slice(0, 2).join('\\n\\n').slice(0, 460);
          }
          const siteName = meta('meta[property="og:site_name"]') || '';
          const authorName = meta('meta[name="author"]') || meta('meta[property="article:author"]') || '';
          const imgs = Array.from(document.querySelectorAll('article img, main img, img'))
            .filter(img => {
              const w = img.naturalWidth || img.clientWidth || 0;
              const h = img.naturalHeight || img.clientHeight || 0;
              const src = img.currentSrc || img.src || '';
              return w >= 240 && h >= 160 && src.startsWith('http');
            })
            .sort((a, b) => ((b.naturalWidth * b.naturalHeight) - (a.naturalWidth * a.naturalHeight)))
            .map(img => img.currentSrc || img.src);
          const uniqueImgs = Array.from(new Set(imgs)).slice(0, 6);
          const vids = Array.from(document.querySelectorAll('video, video source'))
            .map(el => el.currentSrc || el.src || '')
            .filter(u => u.startsWith('http') && /\\.(mp4|mov|m4v|webm)(\\?|$)/i.test(u));
          const uniqueVids = Array.from(new Set(vids)).slice(0, 3);
          return { title, desc, siteName, authorName, heroImages: uniqueImgs, videos: uniqueVids };
        })();
        """
        let probed = (try? await wv.evaluateJavaScript(probeJS)) as? [String: Any]
        let domTitle = probed?["title"] as? String
        let domDesc = probed?["desc"] as? String
        let domSite = probed?["siteName"] as? String
        let domAuthor = probed?["authorName"] as? String
        let domHeroImages = (probed?["heroImages"] as? [String]) ?? []
        let domVideos = (probed?["videos"] as? [String]) ?? []
        let resolvedURL = wv.url

        let snapConfig = WKSnapshotConfiguration()
        snapConfig.rect = CGRect(x: 0, y: 0, width: 1280, height: 800)
        snapConfig.snapshotWidth = 1280

        do {
            let platformImage = try await wv.takeSnapshot(configuration: snapConfig)
            #if canImport(AppKit)
            let snapshotCGImage = platformImage.cgImage(forProposedRect: nil, context: nil, hints: nil)
            #elseif canImport(UIKit)
            let snapshotCGImage = platformImage.cgImage
            #else
            let snapshotCGImage: CGImage? = nil
            #endif
            guard let cgImage = snapshotCGImage,
                  !Self.isVisuallyBlank(cgImage) else {
                finish(with: nil)
                return
            }
            let cleanTitle = domTitle?.trimmingCharacters(in: .whitespacesAndNewlines)
            let cleanDesc = domDesc?.trimmingCharacters(in: .whitespacesAndNewlines)
            let cleanSite = domSite?.trimmingCharacters(in: .whitespacesAndNewlines)
            let cleanAuthor = domAuthor?.trimmingCharacters(in: .whitespacesAndNewlines)
            finish(with: WebPageSnapshotResult(
                image: cgImage,
                title: (cleanTitle?.isEmpty == false) ? String(cleanTitle!.prefix(220)) : nil,
                description: (cleanDesc?.isEmpty == false) ? String(cleanDesc!.prefix(460)) : nil,
                siteName: (cleanSite?.isEmpty == false) ? String(cleanSite!.prefix(80)) : nil,
                authorName: (cleanAuthor?.isEmpty == false) ? String(cleanAuthor!.prefix(80)) : nil,
                heroImageURLs: domHeroImages,
                videoURLs: domVideos,
                finalURL: resolvedURL
            ))
        } catch {
            finish(with: nil)
        }
    }

    private func finish(with result: WebPageSnapshotResult?) {
        guard !isCompleted else { return }
        isCompleted = true
        timeoutTask?.cancel()
        timeoutTask = nil
        settleTask?.cancel()
        settleTask = nil

        if let wv = webView {
            wv.stopLoading()
            wv.navigationDelegate = nil
            webView = nil
        }
        let cont = continuation
        continuation = nil
        cont?.resume(returning: result)
    }

    /// Rejects solid blank white/black canvases produced when a blocked or empty page fails silently.
    private static func isVisuallyBlank(_ image: CGImage) -> Bool {
        let sampleW = 32
        let sampleH = 20
        guard let space = CGColorSpace(name: CGColorSpace.sRGB),
              let ctx = CGContext(
                data: nil,
                width: sampleW,
                height: sampleH,
                bitsPerComponent: 8,
                bytesPerRow: sampleW * 4,
                space: space,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
              ) else {
            return false
        }
        ctx.interpolationQuality = .low
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: sampleW, height: sampleH))
        guard let ptr = ctx.data?.assumingMemoryBound(to: UInt8.self) else { return false }

        var minLum: Int = 255
        var maxLum: Int = 0
        var maxChannelSpread: Int = 0
        let count = sampleW * sampleH
        for i in 0..<count {
            let r = Int(ptr[i * 4])
            let g = Int(ptr[i * 4 + 1])
            let b = Int(ptr[i * 4 + 2])
            let lum = (r * 299 + g * 587 + b * 114) / 1000
            if lum < minLum { minLum = lum }
            if lum > maxLum { maxLum = lum }
            let spread = max(r, max(g, b)) - min(r, min(g, b))
            if spread > maxChannelSpread { maxChannelSpread = spread }
        }
        return (maxLum - minLum) < 8 && maxChannelSpread < 8
    }
}
