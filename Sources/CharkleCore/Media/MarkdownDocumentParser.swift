import Foundation

public nonisolated enum MarkdownAlignment: String, Hashable, Sendable {
    case leading
    case center
    case trailing
}

public nonisolated enum MarkdownAlertKind: String, Hashable, Sendable {
    case note
    case tip
    case important
    case warning
    case caution

    public var label: String {
        switch self {
        case .note: "Note"
        case .tip: "Tip"
        case .important: "Important"
        case .warning: "Warning"
        case .caution: "Caution"
        }
    }
}

public nonisolated enum MarkdownListMarker: Hashable, Sendable {
    case bullet
    case ordered(Int)
    case task(checked: Bool)
}

public nonisolated struct MarkdownImageItem: Hashable, Identifiable, Sendable {
    public let id: Int
    public let url: String
    public let alt: String
    public let width: Double?
    public let height: Double?
    public let linkURL: String?

    public init(
        id: Int,
        url: String,
        alt: String = "",
        width: Double? = nil,
        height: Double? = nil,
        linkURL: String? = nil
    ) {
        self.id = id
        self.url = url
        self.alt = alt
        self.width = width
        self.height = height
        self.linkURL = linkURL
    }
}

public nonisolated enum MarkdownBlock: Hashable, Identifiable, Sendable {
    case heading(id: Int, level: Int, text: String, alignment: MarkdownAlignment)
    case paragraph(id: Int, text: String, alignment: MarkdownAlignment)
    case image(id: Int, item: MarkdownImageItem, alignment: MarkdownAlignment)
    case imageRow(id: Int, items: [MarkdownImageItem], alignment: MarkdownAlignment)
    case code(id: Int, language: String, content: String)
    case quote(id: Int, alertKind: MarkdownAlertKind?, text: String)
    case listItem(id: Int, marker: MarkdownListMarker, indent: Int, text: String)
    case table(id: Int, headers: [String], alignments: [MarkdownAlignment], rows: [[String]])
    case details(id: Int, summary: String, children: [MarkdownBlock])
    case divider(id: Int)

    public var id: Int {
        switch self {
        case .heading(let id, _, _, _),
             .paragraph(let id, _, _),
             .image(let id, _, _),
             .imageRow(let id, _, _),
             .code(let id, _, _),
             .quote(let id, _, _),
             .listItem(let id, _, _, _),
             .table(let id, _, _, _),
             .details(let id, _, _),
             .divider(let id):
            return id
        }
    }
}

public nonisolated struct MarkdownURLContext: Hashable, Sendable {
    public let rawAssetBaseURL: URL?
    public let webLinkBaseURL: URL?
    public let repoHomeURL: URL?

    public init(
        rawAssetBaseURL: URL? = nil,
        webLinkBaseURL: URL? = nil,
        repoHomeURL: URL? = nil
    ) {
        self.rawAssetBaseURL = rawAssetBaseURL
        self.webLinkBaseURL = webLinkBaseURL
        self.repoHomeURL = repoHomeURL
    }

    public static func github(owner: String, repo: String, branch: String) -> MarkdownURLContext {
        let safeBranch = branch.isEmpty ? "main" : branch
        return MarkdownURLContext(
            rawAssetBaseURL: URL(string: "https://raw.githubusercontent.com/\(owner)/\(repo)/\(safeBranch)/"),
            webLinkBaseURL: URL(string: "https://github.com/\(owner)/\(repo)/blob/\(safeBranch)/"),
            repoHomeURL: URL(string: "https://github.com/\(owner)/\(repo)")
        )
    }

    public func resolveAssetURL(_ raw: String) -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return trimmed }
        if trimmed.hasPrefix("http://") || trimmed.hasPrefix("https://") || trimmed.hasPrefix("data:") {
            // Rewrite GitHub blob URLs used inside README <img> tags to raw URLs so image fetches return bytes, not HTML.
            if let url = URL(string: trimmed),
               let host = url.host()?.lowercased(),
               host == "github.com" || host == "www.github.com" {
                let parts = url.pathComponents.filter { $0 != "/" && !$0.isEmpty }
                if parts.count >= 5, parts[2] == "blob" {
                    let rest = parts.dropFirst(3).joined(separator: "/")
                    return "https://raw.githubusercontent.com/\(parts[0])/\(parts[1])/\(rest)"
                }
            }
            return trimmed
        }
        if trimmed.hasPrefix("//") {
            return "https:" + trimmed
        }
        guard let base = rawAssetBaseURL else { return trimmed }
        let cleanRel = trimmed.hasPrefix("/") ? String(trimmed.dropFirst()) : trimmed
        return URL(string: cleanRel, relativeTo: base)?.absoluteURL.absoluteString ?? trimmed
    }

    public func resolveLinkURL(_ raw: String) -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return trimmed }
        if trimmed.hasPrefix("http://") || trimmed.hasPrefix("https://") || trimmed.hasPrefix("mailto:") {
            return trimmed
        }
        if trimmed.hasPrefix("//") {
            return "https:" + trimmed
        }
        if trimmed.hasPrefix("#") {
            if let home = repoHomeURL {
                return home.absoluteString + trimmed
            }
            return trimmed
        }
        guard let base = webLinkBaseURL else { return trimmed }
        let cleanRel = trimmed.hasPrefix("/") ? String(trimmed.dropFirst()) : trimmed
        return URL(string: cleanRel, relativeTo: base)?.absoluteURL.absoluteString ?? trimmed
    }
}

/// Pure-Swift GitHub-Flavored Markdown + README HTML block parser.
/// Handles centered HTML hero blocks (`<p align="center">`, `<h1 align="center">`, `<picture>`, `<img ...>`),
/// inline HTML (`<strong>`, `<em>`, `<code>`, `<kbd>`, `<br>`, `<a href>`), GFM pipe tables with column alignment,
/// ordered & task lists, GitHub callout alerts (`> [!NOTE]`), `<details><summary>`, and relative GitHub URL resolution
/// while keeping fenced code blocks strictly untouched.
public nonisolated enum MarkdownDocumentParser {
    private static let maxDetailsNestingDepth = 8
    private static let summaryTagRegex = try? NSRegularExpression(pattern: #"<summary\b[^>]*>([\s\S]*?)<\/summary>"#, options: [.caseInsensitive])
    private static let nestedHeadingRegex = try? NSRegularExpression(pattern: #"<h([1-6])\b[^>]*>([\s\S]*?)<\/h\1>"#, options: [.caseInsensitive])
    private static let htmlImgPatternRegex = try? NSRegularExpression(
        pattern: #"(?:<a\b[^>]*href\s*=\s*["']([^"']+)["'][^>]*>\s*(<img\b[^>]*>)\s*<\/a>)|(<img\b[^>]*>)"#,
        options: [.caseInsensitive]
    )
    private static let standaloneMDImagesRegex = try? NSRegularExpression(
        pattern: #"(?:\[!\[([^\]]*)\]\(([^)\s]+)(?:\s+"[^"]*")?\)\]\(([^)\s]+)\))|(?:!\[([^\]]*)\]\(([^)\s]+)(?:\s+"[^"]*")?\))"#
    )
    private static let brTagRegex = try? NSRegularExpression(pattern: #"<br\s*\/?>"#, options: [.caseInsensitive])
    private static let htmlAnchorRegex = try? NSRegularExpression(pattern: #"<a\b[^>]*href\s*=\s*["']([^"']+)["'][^>]*>([\s\S]*?)<\/a>"#, options: [.caseInsensitive])
    private static let mdLinkRegex = try? NSRegularExpression(pattern: #"(?<!!)\[([^\]]+)\]\(([^)\s]+)\)"#)
    private static let htmlTagStripRegex = try? NSRegularExpression(pattern: #"<\/?[a-zA-Z][^>]*>"#, options: [.caseInsensitive])
    private static let numericEntityRegex = try? NSRegularExpression(pattern: #"&#(x?[0-9A-Fa-f]+);"#)
    private static let alignAttrRegex = try? NSRegularExpression(pattern: #"align\s*=\s*["']?(center|right|left)["']?"#, options: [.caseInsensitive])
    private static let sourceTagRegex = try? NSRegularExpression(pattern: #"<source\b[^>]*\/?>"#, options: [.caseInsensitive])
    private static let pictureFigureTagRegex = try? NSRegularExpression(pattern: #"<\/?(?:picture|figure)\b[^>]*>"#, options: [.caseInsensitive])
    private static let inlineTagRegexes: [String: NSRegularExpression] = {
        let tags = ["strong", "b", "em", "i", "code", "kbd", "del", "s"]
        var map: [String: NSRegularExpression] = [:]
        for tag in tags {
            if let r = try? NSRegularExpression(pattern: #"<\#(tag)\b[^>]*>([\s\S]*?)<\/\#(tag)>"#, options: [.caseInsensitive]) {
                map[tag] = r
            }
        }
        return map
    }()

    public static func parse(
        _ markdown: String,
        urlContext: MarkdownURLContext = MarkdownURLContext()
    ) -> [MarkdownBlock] {
        var nextID = 0
        return parseInternal(markdown, urlContext: urlContext, nextID: &nextID, depth: 0)
    }

    private static func parseInternal(
        _ markdown: String,
        urlContext: MarkdownURLContext,
        nextID: inout Int,
        depth: Int
    ) -> [MarkdownBlock] {
        let normalized = markdown
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
        let cleaned = stripHTMLCommentsOutsideCode(normalized)
        let lines = cleaned.components(separatedBy: "\n")

        var result: [MarkdownBlock] = []
        var i = 0

        func allocID() -> Int {
            defer { nextID += 1 }
            return nextID
        }

        while i < lines.count {
            let line = lines[i]
            let trimmed = line.trimmingCharacters(in: .whitespaces)

            if trimmed.isEmpty {
                i += 1
                continue
            }

            // 1. Fenced code block (``` or ~~~)
            if let fence = openingFence(trimmed) {
                let lang = String(trimmed.dropFirst(fence.count)).trimmingCharacters(in: .whitespaces)
                var codeLines: [String] = []
                i += 1
                while i < lines.count {
                    let curTrimmed = lines[i].trimmingCharacters(in: .whitespaces)
                    if curTrimmed.hasPrefix(fence.marker) && curTrimmed.allSatisfy({ $0 == fence.char }) && curTrimmed.count >= fence.count {
                        i += 1
                        break
                    }
                    codeLines.append(lines[i])
                    i += 1
                }
                result.append(.code(id: allocID(), language: lang, content: codeLines.joined(separator: "\n")))
                continue
            }

            // 2. HTML <details>...</details>
            if matchesOpeningTag(trimmed, tag: "details") {
                let collected = collectHTMLBlock(lines: lines, startIndex: i, tag: "details")
                i = collected.nextIndex
                let (summary, innerBody) = splitDetailsBlock(collected.html)
                let children: [MarkdownBlock] = if depth + 1 < maxDetailsNestingDepth {
                    parseInternal(innerBody, urlContext: urlContext, nextID: &nextID, depth: depth + 1)
                } else {
                    innerBody.isEmpty ? [] : [.paragraph(id: allocID(), text: convertInlineHTMLToMarkdown(innerBody, urlContext: urlContext), alignment: .leading)]
                }
                result.append(.details(id: allocID(), summary: summary, children: children))
                continue
            }

            // 3. HTML <pre>...</pre>
            if matchesOpeningTag(trimmed, tag: "pre") {
                let collected = collectHTMLBlock(lines: lines, startIndex: i, tag: "pre")
                i = collected.nextIndex
                let codeContent = extractPreCodeText(collected.html)
                result.append(.code(id: allocID(), language: "", content: codeContent))
                continue
            }

            // 4. HTML <hr> / <hr/>
            if isHTMLHorizontalRule(trimmed) {
                result.append(.divider(id: allocID()))
                i += 1
                continue
            }

            // 5. HTML Heading <h1..h6 ...>...</h1..h6>
            if let headingTag = detectHTMLHeadingTag(trimmed) {
                let collected = collectHTMLBlock(lines: lines, startIndex: i, tag: headingTag.tag)
                i = collected.nextIndex
                let align = extractAlignment(from: collected.html)
                let inner = stripOuterTag(collected.html, tag: headingTag.tag)
                let text = convertInlineHTMLToMarkdown(inner, urlContext: urlContext)
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                if !text.isEmpty {
                    result.append(.heading(id: allocID(), level: headingTag.level, text: text, alignment: align))
                }
                continue
            }

            // 6. HTML <p ...>, <div ...>, <center>, <picture>, <figure>, standalone <img> / <a><img></a>
            if let containerTag = detectHTMLContainerTag(trimmed) {
                let collected = collectHTMLBlock(lines: lines, startIndex: i, tag: containerTag)
                i = collected.nextIndex
                let align = containerTag == "center" ? .center : extractAlignment(from: collected.html)
                let inner = stripOuterTag(collected.html, tag: containerTag)
                appendHTMLContainerBlocks(
                    innerHTML: inner,
                    alignment: align,
                    urlContext: urlContext,
                    into: &result,
                    allocID: allocID
                )
                continue
            }

            if isStandaloneHTMLImageLine(trimmed) {
                appendHTMLContainerBlocks(
                    innerHTML: trimmed,
                    alignment: .leading,
                    urlContext: urlContext,
                    into: &result,
                    allocID: allocID
                )
                i += 1
                continue
            }

            // 7. Markdown Horizontal Rule (---, ***, ___)
            if isMarkdownHorizontalRule(trimmed) {
                result.append(.divider(id: allocID()))
                i += 1
                continue
            }

            // 8. Markdown Heading (# .. ######)
            if trimmed.hasPrefix("#") {
                let hashes = trimmed.prefix(while: { $0 == "#" }).count
                if hashes <= 6 && trimmed.dropFirst(hashes).first == " " {
                    var title = String(trimmed.dropFirst(hashes + 1)).trimmingCharacters(in: .whitespaces)
                    // Strip optional trailing closing hashes (`## Title ##`)
                    while title.hasSuffix("#") { title.removeLast() }
                    title = convertInlineHTMLToMarkdown(title, urlContext: urlContext)
                        .trimmingCharacters(in: .whitespaces)
                    result.append(.heading(id: allocID(), level: hashes, text: title, alignment: .leading))
                    i += 1
                    continue
                }
            }

            // 9. GFM Pipe Table
            if i + 1 < lines.count,
               let tableAlignments = parseTableDelimiterRow(lines[i + 1]),
               looksLikeTableRow(trimmed) {
                let rawHeaders = splitTableCells(trimmed)
                let colCount = max(rawHeaders.count, tableAlignments.count)
                let headers = padCells(rawHeaders, to: colCount).map {
                    convertInlineHTMLToMarkdown($0, urlContext: urlContext)
                }
                let normalizedAligns = (0..<colCount).map { idx in
                    idx < tableAlignments.count ? tableAlignments[idx] : .leading
                }
                i += 2
                var rows: [[String]] = []
                while i < lines.count {
                    let rowTrimmed = lines[i].trimmingCharacters(in: .whitespaces)
                    if rowTrimmed.isEmpty || !looksLikeTableRow(rowTrimmed) {
                        break
                    }
                    let cells = padCells(splitTableCells(rowTrimmed), to: colCount).map {
                        convertInlineHTMLToMarkdown($0, urlContext: urlContext)
                    }
                    rows.append(cells)
                    i += 1
                }
                result.append(.table(id: allocID(), headers: headers, alignments: normalizedAligns, rows: rows))
                continue
            }

            // 10. Blockquote (with GitHub Alert detection: > [!NOTE], > [!TIP], ...)
            if trimmed.hasPrefix(">") {
                var quoteLines: [String] = []
                while i < lines.count && lines[i].trimmingCharacters(in: .whitespaces).hasPrefix(">") {
                    var stripped = String(lines[i].trimmingCharacters(in: .whitespaces).dropFirst())
                    if stripped.hasPrefix(" ") { stripped.removeFirst() }
                    quoteLines.append(stripped)
                    i += 1
                }
                var alertKind: MarkdownAlertKind? = nil
                if let first = quoteLines.first?.trimmingCharacters(in: .whitespaces).uppercased() {
                    if first == "[!NOTE]" { alertKind = .note }
                    else if first == "[!TIP]" { alertKind = .tip }
                    else if first == "[!IMPORTANT]" { alertKind = .important }
                    else if first == "[!WARNING]" { alertKind = .warning }
                    else if first == "[!CAUTION]" { alertKind = .caution }
                    if alertKind != nil {
                        quoteLines.removeFirst()
                    }
                }
                let joined = convertInlineHTMLToMarkdown(quoteLines.joined(separator: "\n"), urlContext: urlContext)
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                if !joined.isEmpty || alertKind != nil {
                    result.append(.quote(id: allocID(), alertKind: alertKind, text: joined))
                }
                continue
            }

            // 11. List Item (Task list, Bullet list, Ordered list with indentation)
            if let listMatch = parseListItem(line) {
                let text = convertInlineHTMLToMarkdown(listMatch.content, urlContext: urlContext)
                result.append(.listItem(id: allocID(), marker: listMatch.marker, indent: listMatch.indent, text: text))
                i += 1
                continue
            }

            // 12. Standalone Markdown Image(s) / Linked Badge Row (`![alt](url)` or `[![alt](img)](link)`)
            if let mdImages = parseStandaloneMarkdownImages(trimmed, urlContext: urlContext, allocID: allocID) {
                if mdImages.count == 1 {
                    result.append(.image(id: allocID(), item: mdImages[0], alignment: .leading))
                } else {
                    result.append(.imageRow(id: allocID(), items: mdImages, alignment: .leading))
                }
                i += 1
                continue
            }

            // 13. Paragraph (stop before any block boundary)
            var paraLines: [String] = [trimmed]
            i += 1
            while i < lines.count {
                let rawNext = lines[i]
                let peek = rawNext.trimmingCharacters(in: .whitespaces)
                if peek.isEmpty
                    || openingFence(peek) != nil
                    || peek.hasPrefix("#")
                    || peek.hasPrefix(">")
                    || isMarkdownHorizontalRule(peek)
                    || isHTMLHorizontalRule(peek)
                    || parseListItem(rawNext) != nil
                    || matchesOpeningTag(peek, tag: "details")
                    || matchesOpeningTag(peek, tag: "pre")
                    || detectHTMLHeadingTag(peek) != nil
                    || detectHTMLContainerTag(peek) != nil
                    || isStandaloneHTMLImageLine(peek)
                    || (i + 1 < lines.count && looksLikeTableRow(peek) && parseTableDelimiterRow(lines[i + 1]) != nil) {
                    break
                }
                // Check Setext H1/H2 underline (`===` / `---`)
                if paraLines.count == 1 && (isSetextUnderline(peek, char: "=") || isSetextUnderline(peek, char: "-")) {
                    let level = peek.first == "=" ? 1 : 2
                    let headingText = convertInlineHTMLToMarkdown(paraLines[0], urlContext: urlContext)
                        .trimmingCharacters(in: .whitespaces)
                    result.append(.heading(id: allocID(), level: level, text: headingText, alignment: .leading))
                    paraLines.removeAll()
                    i += 1
                    break
                }
                paraLines.append(peek)
                i += 1
            }

            if !paraLines.isEmpty {
                let rawPara = paraLines.joined(separator: "\n")
                let converted = convertInlineHTMLToMarkdown(rawPara, urlContext: urlContext)
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                if !converted.isEmpty {
                    result.append(.paragraph(id: allocID(), text: converted, alignment: .leading))
                }
            }
        }

        return result
    }

    // MARK: - HTML Comment Stripping (Code-Fence Safe)

    private static func stripHTMLCommentsOutsideCode(_ input: String) -> String {
        let lines = input.components(separatedBy: "\n")
        var out: [String] = []
        var activeFenceChar: Character? = nil
        var activeFenceCount = 0
        var inComment = false

        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if let fenceChar = activeFenceChar {
                out.append(line)
                if trimmed.allSatisfy({ $0 == fenceChar }) && trimmed.count >= activeFenceCount {
                    activeFenceChar = nil
                    activeFenceCount = 0
                }
                continue
            }
            if !inComment, let fence = openingFence(trimmed) {
                activeFenceChar = fence.char
                activeFenceCount = fence.count
                out.append(line)
                continue
            }

            var current = line
            while true {
                if inComment {
                    if let endRange = current.range(of: "-->") {
                        current = String(current[endRange.upperBound...])
                        inComment = false
                    } else {
                        current = ""
                        break
                    }
                } else {
                    if let startRange = current.range(of: "<!--") {
                        let prefix = String(current[..<startRange.lowerBound])
                        let afterStart = current[startRange.upperBound...]
                        if let endRange = afterStart.range(of: "-->") {
                            current = prefix + String(afterStart[endRange.upperBound...])
                        } else {
                            current = prefix
                            inComment = true
                            break
                        }
                    } else {
                        break
                    }
                }
            }
            out.append(current)
        }
        return out.joined(separator: "\n")
    }

    // MARK: - Block Detection Helpers

    private struct FenceInfo {
        let char: Character
        let count: Int
        var marker: String { String(repeating: char, count: count) }
    }

    private static func openingFence(_ trimmed: String) -> FenceInfo? {
        guard let first = trimmed.first, first == "`" || first == "~" else { return nil }
        let count = trimmed.prefix(while: { $0 == first }).count
        guard count >= 3 else { return nil }
        return FenceInfo(char: first, count: count)
    }

    private static func isMarkdownHorizontalRule(_ trimmed: String) -> Bool {
        let compact = trimmed.filter { !$0.isWhitespace }
        guard compact.count >= 3, let first = compact.first, first == "-" || first == "*" || first == "_" else {
            return false
        }
        return compact.allSatisfy { $0 == first }
    }

    private static func isSetextUnderline(_ trimmed: String, char: Character) -> Bool {
        trimmed.count >= 3 && trimmed.allSatisfy { $0 == char }
    }

    private static func isHTMLHorizontalRule(_ trimmed: String) -> Bool {
        trimmed.range(of: #"^<hr\b[^>]*\/?>$"#, options: [.regularExpression, .caseInsensitive]) != nil
    }

    private static func matchesOpeningTag(_ trimmed: String, tag: String) -> Bool {
        trimmed.range(of: #"^<\#(tag)\b[^>]*>"#, options: [.regularExpression, .caseInsensitive]) != nil
    }

    private static func detectHTMLHeadingTag(_ trimmed: String) -> (tag: String, level: Int)? {
        for level in 1...6 {
            let tag = "h\(level)"
            if matchesOpeningTag(trimmed, tag: tag) {
                return (tag, level)
            }
        }
        return nil
    }

    private static func detectHTMLContainerTag(_ trimmed: String) -> String? {
        for tag in ["p", "div", "center", "picture", "figure"] {
            if matchesOpeningTag(trimmed, tag: tag) {
                return tag
            }
        }
        return nil
    }

    private static func isStandaloneHTMLImageLine(_ trimmed: String) -> Bool {
        trimmed.range(of: #"^<(?:a\b[^>]*>\s*)?<img\b[^>]*>(?:\s*<\/a>)?$"#, options: [.regularExpression, .caseInsensitive]) != nil
    }

    private static func collectHTMLBlock(lines: [String], startIndex: Int, tag: String) -> (html: String, nextIndex: Int) {
        let openRegex = try? NSRegularExpression(pattern: #"<\#(tag)\b[^>]*>"#, options: [.caseInsensitive])
        let closeRegex = try? NSRegularExpression(pattern: #"<\/\#(tag)\s*>"#, options: [.caseInsensitive])

        var depth = 0
        var collected: [String] = []
        var idx = startIndex
        while idx < lines.count {
            let line = lines[idx]
            collected.append(line)
            let ns = line as NSString
            let range = NSRange(location: 0, length: ns.length)
            let opens = openRegex?.numberOfMatches(in: line, range: range) ?? 0
            let closes = closeRegex?.numberOfMatches(in: line, range: range) ?? 0
            depth += (opens - closes)
            idx += 1
            if depth <= 0 {
                return (collected.joined(separator: "\n"), idx)
            }
        }
        // Unclosed block guard: for simple container tags like `<p>` / `<div>`, stop at the first blank line
        // instead of swallowing the rest of the entire Markdown document.
        if tag == "p" || tag == "div" {
            if let blankOffset = collected.dropFirst().firstIndex(where: { $0.trimmingCharacters(in: .whitespaces).isEmpty }) {
                let bounded = Array(collected[..<blankOffset])
                return (bounded.joined(separator: "\n"), startIndex + bounded.count)
            }
            if collected.count > 1 {
                return (lines[startIndex], startIndex + 1)
            }
        }
        return (collected.joined(separator: "\n"), idx)
    }

    private static func extractAlignment(from html: String) -> MarkdownAlignment {
        guard let regex = alignAttrRegex,
              let matchObj = regex.firstMatch(in: html, range: NSRange(html.startIndex..., in: html)),
              matchObj.numberOfRanges >= 2,
              let range = Range(matchObj.range(at: 1), in: html) else {
            return .leading
        }
        switch html[range].lowercased() {
        case "center": return .center
        case "right": return .trailing
        default: return .leading
        }
    }

    private static func stripOuterTag(_ html: String, tag: String) -> String {
        var s = html.trimmingCharacters(in: .whitespacesAndNewlines)
        if let openRange = s.range(of: #"^<\#(tag)\b[^>]*>"#, options: [.regularExpression, .caseInsensitive]) {
            s.removeSubrange(openRange)
        }
        if let closeRange = s.range(of: #"<\/\#(tag)\s*>$"#, options: [.regularExpression, .caseInsensitive]) {
            s.removeSubrange(closeRange)
        }
        return s.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func splitDetailsBlock(_ html: String) -> (summary: String, body: String) {
        var inner = stripOuterTag(html, tag: "details")
        var summary = "展开详情"
        if let regex = summaryTagRegex,
           let match = regex.firstMatch(in: inner, range: NSRange(inner.startIndex..., in: inner)),
           let fullRange = Range(match.range(at: 0), in: inner),
           let innerRange = Range(match.range(at: 1), in: inner) {
            let rawSummary = String(inner[innerRange])
            summary = decodeHTMLEntities(stripAllHTMLTags(rawSummary)).trimmingCharacters(in: .whitespacesAndNewlines)
            if summary.isEmpty { summary = "展开详情" }
            inner.removeSubrange(fullRange)
        }
        return (summary, inner.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    private static func extractPreCodeText(_ html: String) -> String {
        var inner = stripOuterTag(html, tag: "pre")
        if inner.range(of: #"^<code\b[^>]*>"#, options: [.regularExpression, .caseInsensitive]) != nil {
            inner = stripOuterTag(inner, tag: "code")
        }
        return decodeHTMLEntities(inner).trimmingCharacters(in: .newlines)
    }

    // MARK: - HTML Container Content (Images, Badge Rows, Nested Headings, Text)

    private static func appendHTMLContainerBlocks(
        innerHTML: String,
        alignment: MarkdownAlignment,
        urlContext: MarkdownURLContext,
        into result: inout [MarkdownBlock],
        allocID: () -> Int
    ) {
        // Strip <source ...> inside <picture> so only the real <img> renders
        var working = replaceCompiledRegex(in: innerHTML, regex: sourceTagRegex, with: "")
        working = replaceCompiledRegex(in: working, regex: pictureFigureTagRegex, with: "")

        // Extract any nested <h1..h6> inside a <div>/<center>
        if let headingRegex = nestedHeadingRegex {
            let matches = headingRegex.matches(in: working, range: NSRange(working.startIndex..., in: working))
            if !matches.isEmpty {
                var cursor = working.startIndex
                for m in matches {
                    guard let fullR = Range(m.range(at: 0), in: working),
                          let levelR = Range(m.range(at: 1), in: working),
                          let textR = Range(m.range(at: 2), in: working) else { continue }
                    let before = String(working[cursor..<fullR.lowerBound]).trimmingCharacters(in: .whitespacesAndNewlines)
                    if !before.isEmpty {
                        appendHTMLContainerBlocks(innerHTML: before, alignment: alignment, urlContext: urlContext, into: &result, allocID: allocID)
                    }
                    let level = Int(working[levelR]) ?? 2
                    let extractedAlign = extractAlignment(from: String(working[fullR]))
                    let headingAlign = extractedAlign == .leading ? alignment : extractedAlign
                    let text = convertInlineHTMLToMarkdown(String(working[textR]), urlContext: urlContext).trimmingCharacters(in: .whitespacesAndNewlines)
                    if !text.isEmpty {
                        result.append(.heading(id: allocID(), level: level, text: text, alignment: headingAlign))
                    }
                    cursor = fullR.upperBound
                }
                let tail = String(working[cursor...]).trimmingCharacters(in: .whitespacesAndNewlines)
                if !tail.isEmpty {
                    appendHTMLContainerBlocks(innerHTML: tail, alignment: alignment, urlContext: urlContext, into: &result, allocID: allocID)
                }
                return
            }
        }

        // Extract linked images (<a href="..."><img ...></a>) and standalone <img ...>
        var images: [MarkdownImageItem] = []
        var remainder = working

        if let regex = htmlImgPatternRegex {
            let matches = regex.matches(in: working, range: NSRange(working.startIndex..., in: working))
            if !matches.isEmpty {
                var mutable = working
                for m in matches.reversed() {
                    guard let fullR = Range(m.range(at: 0), in: mutable) else { continue }
                    let linkHref = Range(m.range(at: 1), in: mutable).map { String(mutable[$0]) }
                    let imgTagStr: String
                    if let r = Range(m.range(at: 2), in: mutable) {
                        imgTagStr = String(mutable[r])
                    } else if let r = Range(m.range(at: 3), in: mutable) {
                        imgTagStr = String(mutable[r])
                    } else {
                        continue
                    }
                    if let item = parseHTMLImageTag(imgTagStr, linkHref: linkHref, urlContext: urlContext, id: allocID()) {
                        images.insert(item, at: 0)
                    }
                    mutable.removeSubrange(fullR)
                }
                remainder = mutable
            }
        }

        if images.count == 1 {
            result.append(.image(id: allocID(), item: images[0], alignment: alignment))
        } else if images.count > 1 {
            result.append(.imageRow(id: allocID(), items: images, alignment: alignment))
        }

        // Convert any remaining inline text / links / formatting inside the container
        let text = convertInlineHTMLToMarkdown(remainder, urlContext: urlContext)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if !text.isEmpty {
            result.append(.paragraph(id: allocID(), text: text, alignment: alignment))
        }
    }

    private static func parseHTMLImageTag(
        _ tag: String,
        linkHref: String?,
        urlContext: MarkdownURLContext,
        id: Int
    ) -> MarkdownImageItem? {
        guard let rawSrc = extractHTMLAttribute("src", from: tag), !rawSrc.isEmpty else {
            return nil
        }
        let resolvedSrc = urlContext.resolveAssetURL(decodeHTMLEntities(rawSrc))
        let alt = extractHTMLAttribute("alt", from: tag).map(decodeHTMLEntities) ?? ""
        let width = extractHTMLAttribute("width", from: tag).flatMap(parseNumericDimension)
        let height = extractHTMLAttribute("height", from: tag).flatMap(parseNumericDimension)
        let resolvedLink = linkHref.map { urlContext.resolveLinkURL(decodeHTMLEntities($0)) }
        return MarkdownImageItem(
            id: id,
            url: resolvedSrc,
            alt: alt,
            width: width,
            height: height,
            linkURL: resolvedLink
        )
    }

    private static func parseNumericDimension(_ raw: String) -> Double? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if trimmed.hasSuffix("%") { return nil }
        let cleaned = trimmed.replacingOccurrences(of: "px", with: "")
        guard let val = Double(cleaned), val > 0, val <= 2000 else { return nil }
        return val
    }

    private static func extractHTMLAttribute(_ name: String, from tag: String) -> String? {
        // Double-quoted, single-quoted, or unquoted value
        if let val = firstRegexMatch(in: tag, pattern: #"\b\#(name)\s*=\s*"([^"]*)""#) {
            return val
        }
        if let val = firstRegexMatch(in: tag, pattern: #"\b\#(name)\s*=\s*'([^']*)'"#) {
            return val
        }
        if let val = firstRegexMatch(in: tag, pattern: #"\b\#(name)\s*=\s*([^\s>\/]+)"#) {
            return val
        }
        return nil
    }

    // MARK: - Standalone Markdown Images

    private static func parseStandaloneMarkdownImages(
        _ trimmed: String,
        urlContext: MarkdownURLContext,
        allocID: () -> Int
    ) -> [MarkdownImageItem]? {
        // Matches `[![alt](img)](link)` or `![alt](img)` repeated with only spaces between
        guard let regex = standaloneMDImagesRegex else { return nil }
        let matches = regex.matches(in: trimmed, range: NSRange(trimmed.startIndex..., in: trimmed))
        guard !matches.isEmpty else { return nil }

        // Ensure nothing substantial exists outside the image tokens
        var residual = trimmed
        for m in matches.reversed() {
            if let r = Range(m.range(at: 0), in: residual) {
                residual.removeSubrange(r)
            }
        }
        guard residual.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }

        var items: [MarkdownImageItem] = []
        for m in matches {
            if let imgR = Range(m.range(at: 2), in: trimmed),
               let linkR = Range(m.range(at: 3), in: trimmed) {
                let alt = Range(m.range(at: 1), in: trimmed).map { String(trimmed[$0]) } ?? ""
                items.append(MarkdownImageItem(
                    id: allocID(),
                    url: urlContext.resolveAssetURL(String(trimmed[imgR])),
                    alt: alt,
                    linkURL: urlContext.resolveLinkURL(String(trimmed[linkR]))
                ))
            } else if let imgR = Range(m.range(at: 5), in: trimmed) {
                let alt = Range(m.range(at: 4), in: trimmed).map { String(trimmed[$0]) } ?? ""
                items.append(MarkdownImageItem(
                    id: allocID(),
                    url: urlContext.resolveAssetURL(String(trimmed[imgR])),
                    alt: alt
                ))
            }
        }
        return items.isEmpty ? nil : items
    }

    // MARK: - GFM Pipe Tables

    private static func looksLikeTableRow(_ trimmed: String) -> Bool {
        trimmed.contains("|")
    }

    private static func parseTableDelimiterRow(_ rawLine: String) -> [MarkdownAlignment]? {
        let trimmed = rawLine.trimmingCharacters(in: .whitespaces)
        guard trimmed.contains("|") && trimmed.contains("-") else { return nil }
        let cells = splitTableCells(trimmed)
        guard !cells.isEmpty else { return nil }
        var alignments: [MarkdownAlignment] = []
        for cell in cells {
            let c = cell.trimmingCharacters(in: .whitespaces)
            guard !c.isEmpty else { return nil }
            let leftColon = c.hasPrefix(":")
            let rightColon = c.hasSuffix(":")
            let core = c.trimmingCharacters(in: CharacterSet(charactersIn: ":"))
            guard core.count >= 2 && core.allSatisfy({ $0 == "-" }) else { return nil }
            if leftColon && rightColon {
                alignments.append(.center)
            } else if rightColon {
                alignments.append(.trailing)
            } else {
                alignments.append(.leading)
            }
        }
        return alignments
    }

    private static func splitTableCells(_ rawLine: String) -> [String] {
        var s = rawLine.trimmingCharacters(in: .whitespaces)
        if s.hasPrefix("|") { s.removeFirst() }
        if s.hasSuffix("|") && !s.hasSuffix("\\|") { s.removeLast() }

        var cells: [String] = []
        var current = ""
        var escaped = false
        for ch in s {
            if escaped {
                current.append(ch)
                escaped = false
            } else if ch == "\\" {
                escaped = true
            } else if ch == "|" {
                cells.append(current.trimmingCharacters(in: .whitespaces))
                current = ""
            } else {
                current.append(ch)
            }
        }
        cells.append(current.trimmingCharacters(in: .whitespaces))
        return cells
    }

    private static func padCells(_ cells: [String], to count: Int) -> [String] {
        if cells.count >= count { return Array(cells.prefix(count)) }
        return cells + Array(repeating: "", count: count - cells.count)
    }

    // MARK: - List Items

    private struct ParsedListItem {
        let marker: MarkdownListMarker
        let indent: Int
        let content: String
    }

    private static func parseListItem(_ rawLine: String) -> ParsedListItem? {
        let leadingSpaces = rawLine.prefix(while: { $0 == " " || $0 == "\t" })
        let indent = leadingSpaces.reduce(0) { $0 + ($1 == "\t" ? 2 : 1) } / 2
        let rest = String(rawLine.dropFirst(leadingSpaces.count))

        // Task list: `- [x] ...` or `- [ ] ...`
        if rest.hasPrefix("- [x] ") || rest.hasPrefix("- [X] ") || rest.hasPrefix("* [x] ") || rest.hasPrefix("* [X] ") {
            return ParsedListItem(marker: .task(checked: true), indent: min(indent, 4), content: String(rest.dropFirst(6)))
        }
        if rest.hasPrefix("- [ ] ") || rest.hasPrefix("* [ ] ") {
            return ParsedListItem(marker: .task(checked: false), indent: min(indent, 4), content: String(rest.dropFirst(6)))
        }

        // Unordered bullet
        if rest.hasPrefix("- ") || rest.hasPrefix("* ") || rest.hasPrefix("+ ") {
            return ParsedListItem(marker: .bullet, indent: min(indent, 4), content: String(rest.dropFirst(2)))
        }

        // Ordered list (`1. ...`)
        let digits = rest.prefix(while: \.isNumber)
        if !digits.isEmpty, digits.count <= 4,
           let num = Int(digits),
           rest.dropFirst(digits.count).hasPrefix(". ") {
            let content = String(rest.dropFirst(digits.count + 2))
            return ParsedListItem(marker: .ordered(num), indent: min(indent, 4), content: content)
        }

        return nil
    }

    // MARK: - Inline HTML → Clean Markdown Conversion

    static func convertInlineHTMLToMarkdown(_ input: String, urlContext: MarkdownURLContext) -> String {
        var s = input

        // Convert <br> / <br/> / <br /> to newline
        if s.contains("<") {
            s = replaceCompiledRegex(in: s, regex: brTagRegex, with: "\n")

            // Convert <a href="...">label</a> -> [label](resolvedURL)
            if let anchorRegex = htmlAnchorRegex {
                let matches = anchorRegex.matches(in: s, range: NSRange(s.startIndex..., in: s))
                for m in matches.reversed() {
                    guard let fullR = Range(m.range(at: 0), in: s),
                          let hrefR = Range(m.range(at: 1), in: s),
                          let labelR = Range(m.range(at: 2), in: s) else { continue }
                    let href = urlContext.resolveLinkURL(decodeHTMLEntities(String(s[hrefR])))
                    let rawLabel = String(s[labelR]).trimmingCharacters(in: .whitespacesAndNewlines)
                    let label = stripAllHTMLTags(rawLabel).replacingOccurrences(of: "\n", with: " ")
                    let replacement = label.isEmpty ? href : "[\(label)](\(href))"
                    s.replaceSubrange(fullR, with: replacement)
                }
            }

            // Convert <strong> / <b> -> **...**
            s = replaceTagWrapping(in: s, tags: ["strong", "b"], prefix: "**", suffix: "**")
            // Convert <em> / <i> -> *...*
            s = replaceTagWrapping(in: s, tags: ["em", "i"], prefix: "*", suffix: "*")
            // Convert <code> / <kbd> -> `...`
            s = replaceTagWrapping(in: s, tags: ["code", "kbd"], prefix: "`", suffix: "`")
            // Convert <del> / <s> -> ~~...~~
            s = replaceTagWrapping(in: s, tags: ["del", "s"], prefix: "~~", suffix: "~~")
        }

        // Resolve relative Markdown links `[label](href)`
        if s.contains("]("), let mdLinkRegex {
            let matches = mdLinkRegex.matches(in: s, range: NSRange(s.startIndex..., in: s))
            for m in matches.reversed() {
                guard let fullR = Range(m.range(at: 0), in: s),
                      let labelR = Range(m.range(at: 1), in: s),
                      let hrefR = Range(m.range(at: 2), in: s) else { continue }
                let label = String(s[labelR])
                let href = urlContext.resolveLinkURL(String(s[hrefR]))
                s.replaceSubrange(fullR, with: "[\(label)](\(href))")
            }
        }

        // Strip any remaining inline wrapper tags (<span>, <sup>, <sub>, <p>, <div>, </img>, etc.)
        if s.contains("<") {
            s = stripRemainingNonCodeHTMLTags(s)
        }

        // Decode HTML entities (&amp;, &middot;, &nbsp;, &#39;, etc.)
        s = decodeHTMLEntities(s)

        // Clean excess spaces around newlines produced by indented HTML source lines
        let cleanedLines = s.components(separatedBy: "\n").map {
            $0.trimmingCharacters(in: .whitespaces)
        }
        return cleanedLines.joined(separator: "\n")
    }

    private static func replaceTagWrapping(in input: String, tags: [String], prefix: String, suffix: String) -> String {
        var s = input
        for tag in tags {
            guard let regex = inlineTagRegexes[tag] else { continue }
            let matches = regex.matches(in: s, range: NSRange(s.startIndex..., in: s))
            for m in matches.reversed() {
                guard let fullR = Range(m.range(at: 0), in: s),
                      let innerR = Range(m.range(at: 1), in: s) else { continue }
                let inner = String(s[innerR]).trimmingCharacters(in: .whitespacesAndNewlines)
                s.replaceSubrange(fullR, with: inner.isEmpty ? "" : "\(prefix)\(inner)\(suffix)")
            }
        }
        return s
    }

    private static func stripAllHTMLTags(_ input: String) -> String {
        replaceCompiledRegex(in: input, regex: htmlTagStripRegex, with: "")
    }

    /// Strips remaining HTML tags while preserving inline backtick code spans (e.g. `` `<div>` ``).
    private static func stripRemainingNonCodeHTMLTags(_ input: String) -> String {
        let parts = input.components(separatedBy: "`")
        guard parts.count >= 3 else {
            return stripAllHTMLTags(input)
        }
        return parts.enumerated().map { idx, segment in
            idx.isMultiple(of: 2) ? stripAllHTMLTags(segment) : segment
        }.joined(separator: "`")
    }

    static func decodeHTMLEntities(_ input: String) -> String {
        guard input.contains("&") else { return input }
        var s = input
        let named: [(String, String)] = [
            ("&amp;", "&"),
            ("&lt;", "<"),
            ("&gt;", ">"),
            ("&quot;", "\""),
            ("&#39;", "'"),
            ("&apos;", "'"),
            ("&nbsp;", " "),
            ("&middot;", "·"),
            ("&bull;", "•"),
            ("&mdash;", "—"),
            ("&ndash;", "–"),
            ("&hellip;", "…"),
            ("&copy;", "©"),
            ("&rarr;", "→"),
            ("&larr;", "←")
        ]
        for (entity, replacement) in named {
            if s.contains(entity) {
                s = s.replacingOccurrences(of: entity, with: replacement)
            }
        }
        // Numeric entities &#123; and &#x1F600;
        if s.contains("&#"), let regex = numericEntityRegex {
            let matches = regex.matches(in: s, range: NSRange(s.startIndex..., in: s))
            for m in matches.reversed() {
                guard let fullR = Range(m.range(at: 0), in: s),
                      let codeR = Range(m.range(at: 1), in: s) else { continue }
                let token = String(s[codeR])
                let scalarVal: UInt32?
                if token.lowercased().hasPrefix("x") {
                    scalarVal = UInt32(token.dropFirst(), radix: 16)
                } else {
                    scalarVal = UInt32(token, radix: 10)
                }
                if let scalarVal, let scalar = UnicodeScalar(scalarVal) {
                    s.replaceSubrange(fullR, with: String(scalar))
                }
            }
        }
        return s
    }

    // MARK: - Regex Helpers

    private static func firstRegexMatch(in text: String, pattern: String) -> String? {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]),
              let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
              match.numberOfRanges >= 2,
              let range = Range(match.range(at: 1), in: text) else {
            return nil
        }
        return String(text[range])
    }

    private static func replaceCompiledRegex(in text: String, regex: NSRegularExpression?, with template: String) -> String {
        guard let regex else { return text }
        return regex.stringByReplacingMatches(in: text, range: NSRange(text.startIndex..., in: text), withTemplate: template)
    }
}
