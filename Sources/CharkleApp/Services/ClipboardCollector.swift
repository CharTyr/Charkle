import AppKit
import CharkleCore
import Foundation
import UniformTypeIdentifiers

/// Classification of a web URL currently sitting in the macOS clipboard.
public enum ClipboardDetectedLink: Equatable, Sendable {
    case social(URL)
    case github(URL)
    case web(URL, domain: String)

    public var url: URL {
        switch self {
        case .social(let url), .github(let url), .web(let url, _):
            url
        }
    }

    public var notchHintLabel: String {
        switch self {
        case .social(let url):
            if let ref = SocialPostURLParser.parse(url) {
                switch ref.platform {
                case .xiaohongshu:
                    return "检测到剪贴板小红书笔记链接 · 点击或按 ⌘V 立即保存"
                case .douyin:
                    return "检测到剪贴板抖音作品链接 · 点击或按 ⌘V 立即保存"
                case .youtube, .bilibili:
                    return "检测到剪贴板\(ref.platform.displayName)视频链接 · 点击或按 ⌘V 立即保存"
                default:
                    return "检测到剪贴板\(ref.platform.postTypeLabel)链接 · 点击或按 ⌘V 立即保存"
                }
            }
            return "检测到剪贴板推文链接 · 点击或按 ⌘V 立即保存"
        case .github:
            return "检测到剪贴板 GitHub 链接 · 点击或按 ⌘V 立即保存"
        case .web(_, let domain):
            return "检测到网页链接 (\(domain)) · 点击或按 ⌘V 立即保存"
        }
    }
}

/// Extracts typed `[CaptureInput]` payloads from any `NSPasteboard` (clipboard or AppKit drag pasteboard).
public enum ClipboardCollector {
    public static func extractInputs(from pasteboard: NSPasteboard = .general) -> [CaptureInput] {
        // 1. Local file URLs
        if let fileURLs = pasteboard.readObjects(
            forClasses: [NSURL.self],
            options: [.urlReadingFileURLsOnly: true]
        ) as? [URL], !fileURLs.isEmpty {
            return fileURLs.map { .fileURL($0) }
        }

        // Legacy Finder filenames fallback
        if let paths = pasteboard.propertyList(forType: NSPasteboard.PasteboardType("NSFilenamesPboardType")) as? [String],
           !paths.isEmpty {
            return paths.map { .fileURL(URL(fileURLWithPath: $0)) }
        }

        // 2. Direct image data (preserve animated GIF & WebP before static PNG / JPEG / TIFF fallbacks)
        let stamp = Int(Date().timeIntervalSince1970)
        let nonce = String(UUID().uuidString.prefix(6)).lowercased()
        let accompanyingURL = extractDirectPasteboardWebURL(from: pasteboard)?.absoluteString
        if let gifData = pasteboard.data(forType: NSPasteboard.PasteboardType(UTType.gif.identifier)) {
            return [.imageData(gifData, suggestedName: "Clip-\(stamp)-\(nonce).gif", sourceURL: accompanyingURL)]
        }
        if let webpData = pasteboard.data(forType: NSPasteboard.PasteboardType(UTType.webP.identifier)) {
            return [.imageData(webpData, suggestedName: "Clip-\(stamp)-\(nonce).webp", sourceURL: accompanyingURL)]
        }
        if let pngData = pasteboard.data(forType: .png) {
            return [.imageData(pngData, suggestedName: "Clip-\(stamp)-\(nonce).png", sourceURL: accompanyingURL)]
        }
        if let jpgData = pasteboard.data(forType: NSPasteboard.PasteboardType(UTType.jpeg.identifier)) {
            return [.imageData(jpgData, suggestedName: "Clip-\(stamp)-\(nonce).jpg", sourceURL: accompanyingURL)]
        }
        if let tiffData = pasteboard.data(forType: .tiff),
           let rep = NSBitmapImageRep(data: tiffData),
           let pngData = rep.representation(using: .png, properties: [:]) {
            return [.imageData(pngData, suggestedName: "Clip-\(stamp)-\(nonce).png", sourceURL: accompanyingURL)]
        }

        // 3. Web URLs (Safari / Chrome / Arc / Firefox / NSURL / public.url)
        if let webURL = extractDirectPasteboardWebURL(from: pasteboard) {
            return [.webURL(webURL, title: nil, notes: nil)]
        }

        // 4. Plain text, any web URL (including social posts, GitHub repos, or share copy with URL), or HEX swatch
        if let raw = pasteboard.string(forType: .string)?.trimmingCharacters(in: .whitespacesAndNewlines),
           !raw.isEmpty {
            if let hex = parseHexColor(raw) {
                return [.colorSwatch(hex: hex, title: hex)]
            }
            if let socialURL = SocialPostURLParser.extractPostURL(from: raw) {
                return [.webURL(socialURL, title: nil, notes: nil)]
            }
            if let githubURL = GitHubRepoURLParser.extractRepoURL(from: raw) {
                return [.webURL(githubURL, title: nil, notes: nil)]
            }
            if let webURL = WebURLParser.extractWebURL(from: raw) {
                return [.webURL(webURL, title: nil, notes: nil)]
            }
            let title = String(raw.prefix(40)).replacingOccurrences(of: "\n", with: " ")
            return [.textSnippet(title: title, text: raw, sourceURL: nil)]
        }

        return []
    }

    /// Returns a detected social post URL (X / Threads / Bluesky) if the pasteboard currently holds one.
    public static func detectedXPostURL(from pasteboard: NSPasteboard = .general) -> URL? {
        if case .social(let url) = detectedClipboardLink(from: pasteboard) {
            return url
        }
        return nil
    }

    /// Detects any web URL in the pasteboard (social post, GitHub repo, or arbitrary website link)
    /// for quick one-click capture hints. Inspects O(1) pasteboard type metadata rather than copying
    /// multi-megabyte bitmap payloads over XPC.
    public static func detectedClipboardLink(from pasteboard: NSPasteboard = .general) -> ClipboardDetectedLink? {
        let types = Set(pasteboard.types ?? [])
        guard !types.isEmpty else { return nil }

        // Never misclassify local files or copied images as web links (zero bitmap data transfer).
        let imageAndFileTypes: Set<NSPasteboard.PasteboardType> = [
            .fileURL,
            NSPasteboard.PasteboardType("NSFilenamesPboardType"),
            .png,
            .tiff,
            NSPasteboard.PasteboardType(UTType.jpeg.identifier),
            NSPasteboard.PasteboardType(UTType.gif.identifier),
            NSPasteboard.PasteboardType(UTType.webP.identifier),
            NSPasteboard.PasteboardType(UTType.image.identifier)
        ]
        if !types.isDisjoint(with: imageAndFileTypes) {
            return nil
        }

        if let direct = extractDirectPasteboardWebURL(from: pasteboard) {
            return classify(direct)
        }
        if let raw = pasteboard.string(forType: .string) {
            if let social = SocialPostURLParser.extractPostURL(from: raw) {
                return .social(social)
            }
            if let github = GitHubRepoURLParser.extractRepoURL(from: raw) {
                return .github(github)
            }
            if let web = WebURLParser.extractWebURL(from: raw) {
                return classify(web)
            }
        }
        return nil
    }

    private static func classify(_ url: URL) -> ClipboardDetectedLink {
        if SocialPostURLParser.parse(url) != nil {
            return .social(url)
        }
        if GitHubRepoURLParser.parse(url) != nil {
            return .github(url)
        }
        let domain = WebURLParser.cleanDomain(for: url) ?? url.host() ?? "网页"
        return .web(url, domain: domain)
    }

    private static func extractDirectPasteboardWebURL(from pasteboard: NSPasteboard) -> URL? {
        if let urls = pasteboard.readObjects(forClasses: [NSURL.self], options: nil) as? [URL],
           let webURL = urls.first(where: { WebBookmark.isWebURL($0) }) {
            return webURL
        }
        for type in [NSPasteboard.PasteboardType.URL, NSPasteboard.PasteboardType("public.url")] {
            if let raw = pasteboard.string(forType: type), let url = WebURLParser.parse(raw) {
                return url
            }
        }
        // Safari/Chrome browser drag pasteboard payload: `[[urlString], [titleString]]`
        if let plist = pasteboard.propertyList(forType: NSPasteboard.PasteboardType("WebURLsWithTitlesPboardType")) as? [[String]],
           let firstURL = plist.first?.first,
           let url = WebURLParser.parse(firstURL) {
            return url
        }
        return nil
    }

    private static func parseHexColor(_ text: String) -> String? {
        // Require leading `#` so 6-digit codes (`123456`) and English words (`coffee`, `decade`, `facade`)
        // are preserved as text snippets instead of silently turning into color swatches.
        guard text.hasPrefix("#") else { return nil }
        let cleaned = String(text.dropFirst())
        guard cleaned.count == 6,
              cleaned.allSatisfy({ $0.isASCII && $0.isHexDigit }) else { return nil }
        return "#\(cleaned.uppercased())"
    }
}
