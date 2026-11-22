import Foundation
import ImageIO

nonisolated struct WebBookmark: Sendable {
    var title: String?
    var poster: CGImage?

    static func isWebURL(_ url: URL) -> Bool {
        ["http", "https"].contains(url.scheme?.lowercased() ?? "") && url.host() != nil
            && url.user() == nil && url.password() == nil
    }

    static func url(in file: URL) -> URL? {
        guard let data = try? Data(contentsOf: file), data.count < 256_000 else { return nil }
        if let plist = try? PropertyListSerialization.propertyList(from: data, options: [], format: nil),
           let fields = plist as? [String: Any], let value = fields["URL"] as? String {
            return URL(string: value)
        }
        return String(decoding: data, as: UTF8.self).split(whereSeparator: \.isNewline)
            .first(where: { $0.lowercased().hasPrefix("url=") })
            .flatMap { URL(string: String($0.dropFirst(4))) }
    }

    static func fetch(_ url: URL?) async -> Self {
        guard let url, isWebURL(url), let page = try? await fetchBytes(url, limit: 524_288) else { return Self() }
        let html = String(decoding: page.data, as: UTF8.self)
        let title = meta("og:title", html) ?? matches(#"(?is)<title\b[^>]*>(.*?)</title\s*>"#, html).first?[1]
        let imageURL = meta("og:image", html).map(decodeEntities).flatMap {
            URL(string: $0, relativeTo: page.url)?.absoluteURL
        }
        var poster: CGImage?
        if let imageURL, isWebURL(imageURL), let bytes = try? await fetchBytes(imageURL, limit: 5_242_880),
           let source = CGImageSourceCreateWithData(bytes.data as CFData, nil) {
            poster = MediaPipeline.raster(source)?.poster
        }
        let cleaned = title.map {
            String(decodeEntities($0).split(whereSeparator: \.isWhitespace).joined(separator: " ").prefix(250))
        }
        return Self(title: cleaned.flatMap { $0.isEmpty ? nil : $0 }, poster: poster)
    }

    private static func fetchBytes(_ url: URL, limit: Int) async throws -> (data: Data, url: URL) {
        let config = URLSessionConfiguration.ephemeral
        config.httpShouldSetCookies = false
        config.timeoutIntervalForResource = 7
        let session = URLSession(configuration: config)
        defer { session.invalidateAndCancel() }
        let (bytes, response) = try await session.bytes(for: URLRequest(url: url, timeoutInterval: 5))
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode),
              let final = http.url, isWebURL(final) else {
            throw URLError(.badServerResponse)
        }
        var data = Data()
        for try await byte in bytes {
            if data.count >= limit { break }
            data.append(byte)
        }
        return (data, final)
    }

    private static func meta(_ name: String, _ html: String) -> String? {
        for tag in matches(#"(?is)<meta\b[^>]*>"#, html) {
            let fields = matches(#"(?is)([a-z][\w:-]*)\s*=\s*(?:"([^"]*)"|'([^']*)'|([^\s>]+))"#, tag[0])
            var attributes: [String: String] = [:]
            for field in fields {
                attributes[field[1].lowercased()] = field.dropFirst(2).first(where: { !$0.isEmpty })
            }
            if (attributes["property"] ?? attributes["name"])?.lowercased() == name {
                return attributes["content"]
            }
        }
        return nil
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
        let entities = ["&amp;": "&", "&quot;": "\"", "&apos;": "'", "&#39;": "'", "&lt;": "<", "&gt;": ">", "&nbsp;": " "]
        var output = input
        for code in matches(#"&#(x[0-9A-Fa-f]+|[0-9]+);"#, input) {
            let hex = code[1].hasPrefix("x")
            if let number = UInt32(hex ? String(code[1].dropFirst()) : code[1], radix: hex ? 16 : 10),
               let scalar = UnicodeScalar(number) {
                output = output.replacingOccurrences(of: code[0], with: String(scalar))
            }
        }
        // Decode ampersands last so a double-escaped character is only unescaped once.
        for (key, value) in entities where key != "&amp;" { output = output.replacingOccurrences(of: key, with: value) }
        return output.replacingOccurrences(of: "&amp;", with: "&")
    }
}
