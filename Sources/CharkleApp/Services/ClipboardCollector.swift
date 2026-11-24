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
            if let ref = SocialPostURLParser.parse(url), ref.platform == .xiaohongshu {
                return "检测到剪贴板小红书笔记链接 · 点击或按 ⌘V 立即保存"
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

        // 2. Direct image data (PNG / JPEG / TIFF)
        let stamp = Int(Date().timeIntervalSince1970)
        if let pngData = pasteboard.data(forType: .png) {
            return [.imageData(pngData, suggestedName: "Clip-\(stamp).png", sourceURL: nil)]
        }
        if let jpgData = pasteboard.data(forType: NSPasteboard.PasteboardType(UTType.jpeg.identifier)) {
            return [.imageData(jpgData, suggestedName: "Clip-\(stamp).jpg", sourceURL: nil)]
        }
        if let tiffData = pasteboard.data(forType: .tiff),
           let rep = NSBitmapImageRep(data: tiffData),
           let pngData = rep.representation(using: .png, properties: [:]) {
            return [.imageData(pngData, suggestedName: "Clip-\(stamp).png", sourceURL: nil)]
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
    /// for quick one-click capture hints.
    public static func detectedClipboardLink(from pasteboard: NSPasteboard = .general) -> ClipboardDetectedLink? {
        // Never misclassify local files or copied images as web links.
        if let fileURLs = pasteboard.readObjects(
            forClasses: [NSURL.self],
            options: [.urlReadingFileURLsOnly: true]
        ) as? [URL], !fileURLs.isEmpty {
            return nil
        }
        if pasteboard.data(forType: .png) != nil || pasteboard.data(forType: .tiff) != nil {
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
        let cleaned = text.hasPrefix("#") ? String(text.dropFirst()) : text
        guard cleaned.count == 6,
              cleaned.allSatisfy({ $0.isHexDigit }) else { return nil }
        return "#\(cleaned.uppercased())"
    }
}
