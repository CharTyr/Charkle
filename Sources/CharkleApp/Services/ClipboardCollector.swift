import AppKit
import CharkleCore
import Foundation
import UniformTypeIdentifiers

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

        // 3. Web URLs
        if let urls = pasteboard.readObjects(forClasses: [NSURL.self], options: nil) as? [URL],
           let webURL = urls.first(where: { $0.scheme == "http" || $0.scheme == "https" }) {
            return [.webURL(webURL, title: nil, notes: nil)]
        }

        // 4. Plain text, URL string (including X/Twitter share links), or HEX color swatch
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
            if let url = URL(string: raw), url.scheme == "http" || url.scheme == "https" {
                return [.webURL(url, title: nil, notes: nil)]
            }
            let title = String(raw.prefix(40)).replacingOccurrences(of: "\n", with: " ")
            return [.textSnippet(title: title, text: raw, sourceURL: nil)]
        }

        return []
    }

    /// Returns a detected social post URL (X / Threads / Bluesky) if the pasteboard currently holds one.
    public static func detectedXPostURL(from pasteboard: NSPasteboard = .general) -> URL? {
        if let urls = pasteboard.readObjects(forClasses: [NSURL.self], options: nil) as? [URL],
           let match = urls.first(where: { SocialPostURLParser.parse($0) != nil }) {
            return match
        }
        if let raw = pasteboard.string(forType: .string),
           let match = SocialPostURLParser.extractPostURL(from: raw) {
            return match
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
