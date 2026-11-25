import CharkleCore
import Darwin
import Foundation

/// Dual-mode terminal renderer for `charkle`:
/// - Auto-JSON when piped (`!isTTY`) or when `--json` / `--compact` is specified
/// - Clean, aligned human-readable output when interactive (`isTTY`)
struct CLIFormatter: Sendable {
    enum Mode: Sendable {
        case human
        case prettyJSON
        case compactJSON
    }

    let mode: Mode
    let useColor: Bool

    init(explicitJSON: Bool, compactJSON: Bool, forceHuman: Bool = false, noColor: Bool) {
        let isTTY = isatty(STDOUT_FILENO) != 0
        if compactJSON {
            self.mode = .compactJSON
        } else if explicitJSON {
            self.mode = .prettyJSON
        } else if forceHuman {
            self.mode = .human
        } else if !isTTY {
            self.mode = .compactJSON
        } else {
            self.mode = .human
        }
        let envNoColor = ProcessInfo.processInfo.environment["NO_COLOR"] != nil
        self.useColor = isTTY && !noColor && !envNoColor
    }

    // MARK: - ANSI Helpers

    private func style(_ text: String, _ code: String) -> String {
        guard useColor else { return text }
        return "\u{001B}[\(code)m\(text)\u{001B}[0m"
    }

    private func bold(_ s: String) -> String { style(s, "1") }
    private func dim(_ s: String) -> String { style(s, "2") }
    private func cyan(_ s: String) -> String { style(s, "36") }
    private func green(_ s: String) -> String { style(s, "32") }
    private func yellow(_ s: String) -> String { style(s, "33") }
    private func red(_ s: String) -> String { style(s, "31") }

    // MARK: - Public Rendering Entry Points

    func emitError(_ message: String) {
        if mode == .prettyJSON || mode == .compactJSON {
            let payload: [String: Any] = ["error": message]
            let text = mode == .compactJSON
                ? CharkleExternalAgentService.encodeCompactJSON(payload)
                : CharkleExternalAgentService.encodePrettyJSON(payload)
            writeStderr(text + "\n")
        } else {
            writeStderr("\(red("Error:")) \(message)\n")
        }
    }

    func emitJSON(_ object: Any, humanRenderer: (([String: Any]) -> String)? = nil) {
        switch mode {
        case .prettyJSON:
            print(CharkleExternalAgentService.encodePrettyJSON(object))
        case .compactJSON:
            print(CharkleExternalAgentService.encodeCompactJSON(object))
        case .human:
            if let dict = object as? [String: Any], let renderer = humanRenderer {
                print(renderer(dict))
            } else {
                print(CharkleExternalAgentService.encodePrettyJSON(object))
            }
        }
    }

    func emitToolOutput(_ output: CharkleExternalAgentService.ToolOutput, command: String) {
        let textBlocks = output.content.compactMap { item -> String? in
            if case .text(let t) = item { return t }
            return nil
        }
        let rawText = textBlocks.joined(separator: "\n")

        if output.isError {
            emitError(rawText.isEmpty ? "Command failed." : rawText)
            exit(1)
        }

        switch mode {
        case .prettyJSON:
            if let data = rawText.data(using: .utf8),
               let parsed = try? JSONSerialization.jsonObject(with: data) {
                print(CharkleExternalAgentService.encodePrettyJSON(parsed))
            } else {
                print(rawText)
            }
        case .compactJSON:
            print(rawText)
        case .human:
            if let data = rawText.data(using: .utf8),
               let dict = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                print(renderHuman(command: command, data: dict))
            } else {
                print(rawText)
            }
        }
    }

    // MARK: - Human Renderers

    func renderDoctor(_ d: [String: Any]) -> String {
        var lines: [String] = []
        let ok = (d["ok"] as? Bool) ?? false
        let ver = (d["serverVersion"] as? String) ?? CharkleExternalAgentService.serverVersion
        lines.append("\(bold("Charkle Doctor")) \(dim("v\(ver)"))  \(ok ? green("● HEALTHY") : red("● ISSUE"))")
        lines.append("")

        if let db = d["database"] as? [String: Any] {
            let healthy = (db["healthy"] as? Bool) ?? false
            let size = Self.formatBytes((db["sizeBytes"] as? Int64) ?? Int64((db["sizeBytes"] as? Int) ?? 0))
            lines.append("  \(healthy ? green("✓") : red("✗")) Database       \(healthy ? "WAL SQLite OK" : "Error") \(dim("(\(size))"))")
        }
        if let lib = d["library"] as? [String: Any] {
            let a = (lib["totalAssets"] as? Int) ?? 0
            let inbox = (lib["inboxCount"] as? Int) ?? 0
            let f = (lib["folderCount"] as? Int) ?? 0
            let sf = (lib["smartFolderCount"] as? Int) ?? 0
            let b = (lib["boardCount"] as? Int) ?? 0
            lines.append("  \(green("✓")) Library        \(a) assets · \(inbox) inbox · \(f) folders · \(sf) smart · \(b) boards")
        }
        if let policy = d["policy"] as? [String: Any] {
            let mcp = (policy["mcpEnabled"] as? Bool) ?? false
            let cli = (policy["cliEnabled"] as? Bool) ?? false
            let level = (policy["accessLevel"] as? String) ?? "readOnly"
            let levelLabel = level == "readWriteOrganize" ? "Read + Organize (Soft Trash only)" : "Read-Only"
            lines.append("  \(mcp ? green("✓") : yellow("○")) MCP Channel    \(mcp ? "Enabled" : "Disabled")")
            lines.append("  \(cli ? green("✓") : yellow("○")) CLI Channel    \(cli ? "Enabled" : "Disabled")")
            lines.append("  \(cyan("•")) Access Level   \(levelLabel)")
        }
        if let cliLink = d["cliLink"] as? [String: Any] {
            let status = (cliLink["status"] as? String) ?? "notLinked"
            let path = (cliLink["linkPath"] as? String) ?? "~/.local/bin/charkle"
            let badge: String = switch status {
            case "linked": green("✓")
            case "stale": yellow("!")
            default: yellow("○")
            }
            lines.append("  \(badge) CLI Symlink    \(status) \(dim("(\(path))"))")
        }
        if let caps = d["capabilities"] as? [String: Any] {
            let tools = (caps["toolCount"] as? Int) ?? 0
            let res = (caps["resourceCount"] as? Int) ?? 0
            let tmpl = (caps["resourceTemplateCount"] as? Int) ?? 0
            let prompts = (caps["promptCount"] as? Int) ?? 0
            lines.append("  \(cyan("•")) MCP Surface    \(tools) safe tools · \(res)+\(tmpl) resources · \(prompts) prompts")
        }
        if let sync = d["syncMode"] as? String, let ai = d["aiProvider"] as? String {
            lines.append("  \(cyan("•")) Sync / AI      sync=\(sync) · ai=\(ai)")
        }
        if let err = d["error"] as? String, !err.isEmpty {
            lines.append("")
            lines.append("  \(red("Error:")) \(err)")
        }
        return lines.joined(separator: "\n")
    }

    private func renderHuman(command: String, data d: [String: Any]) -> String {
        switch command {
        case "library_overview":
            return renderOverview(d)
        case "search_assets", "list_inbox":
            return renderAssetList(d, isInbox: command == "list_inbox")
        case "find_similar_assets":
            return renderScoredAssetList(d, arrayKey: "matches", heading: "Similar Assets")
        case "semantic_search":
            return renderScoredAssetList(d, arrayKey: "hits", heading: "Semantic Search")
        case "get_asset":
            return renderAssetDetail(d)
        case "list_boards":
            return renderBoardList(d)
        case "get_board_context":
            return renderBoardDetail(d)
        case "render_contact_sheet":
            return renderContactSheet(d)
        case "export_board_image":
            return renderBoardExport(d)
        case "quick_jump":
            return renderQuickJump(d)
        case "suggest_folder":
            return renderSuggestions(d)
        default:
            return CharkleExternalAgentService.encodePrettyJSON(d)
        }
    }

    private func renderOverview(_ d: [String: Any]) -> String {
        var lines: [String] = []
        let total = (d["totalAssets"] as? Int) ?? 0
        let inbox = (d["inboxCount"] as? Int) ?? 0
        let untagged = (d["untaggedCount"] as? Int) ?? 0
        let trashed = (d["trashedCount"] as? Int) ?? 0
        let boards = (d["boardCount"] as? Int) ?? 0
        let level = (d["accessLevel"] as? String) ?? "readOnly"

        lines.append("\(bold("Charkle Library Overview"))  \(dim("[\(level)]"))")
        lines.append("  Assets: \(bold("\(total)"))  ·  Inbox: \(cyan("\(inbox)"))  ·  Untagged: \(untagged)  ·  Trash: \(trashed)  ·  Boards: \(bold("\(boards)"))")

        if let kinds = d["mediaKindCounts"] as? [String: Int], !kinds.isEmpty {
            let summary = kinds.sorted { $0.value > $1.value }.map { "\($0.key)=\($0.value)" }.joined(separator: "  ")
            lines.append("  Media:  \(dim(summary))")
        }
        if let shapes = d["aspectShapeCounts"] as? [String: Int], !shapes.isEmpty {
            let summary = shapes.sorted { $0.value > $1.value }.map { "\($0.key)=\($0.value)" }.joined(separator: "  ")
            lines.append("  Shapes: \(dim(summary))")
        }

        if let folders = d["folders"] as? [[String: Any]], !folders.isEmpty {
            lines.append("")
            lines.append(bold("Folders (\(folders.count))"))
            for f in folders.prefix(25) {
                let path = (f["path"] as? String) ?? ""
                let count = (f["assetCount"] as? Int) ?? 0
                let rec = (f["recursiveAssetCount"] as? Int) ?? count
                let countLabel = rec > count ? "(\(count)/\(rec) total)" : "(\(count))"
                let id = String(((f["id"] as? String) ?? "").prefix(8))
                let tags = ((f["topTags"] as? [String]) ?? []).prefix(4).map { "#\($0)" }.joined(separator: " ")
                let tagSuffix = tags.isEmpty ? "" : "  \(dim(tags))"
                lines.append("  \(cyan(id))  \(path) \(dim(countLabel))\(tagSuffix)")
            }
            if folders.count > 25 {
                lines.append("  \(dim("… and \(folders.count - 25) more (pass --json for full list)"))")
            }
        }

        if let smarts = d["smartFolders"] as? [[String: Any]], !smarts.isEmpty {
            lines.append("")
            lines.append(bold("Smart Folders (\(smarts.count))"))
            for sf in smarts {
                let name = (sf["name"] as? String) ?? ""
                let count = (sf["matchCount"] as? Int) ?? 0
                lines.append("  \(cyan("✦")) \(name) \(dim("(\(count))"))")
            }
        }

        if let tags = d["topTags"] as? [[String: Any]], !tags.isEmpty {
            let tagLine = tags.prefix(15).compactMap { t -> String? in
                guard let name = t["name"] as? String, let count = t["count"] as? Int else { return nil }
                return "#\(name)(\(count))"
            }.joined(separator: "  ")
            lines.append("")
            lines.append("\(bold("Top Tags"))  \(dim(tagLine))")
        }

        return lines.joined(separator: "\n")
    }

    private func renderAssetList(_ d: [String: Any], isInbox: Bool) -> String {
        let total = (d[isInbox ? "inboxTotal" : "totalMatched"] as? Int) ?? 0
        let offset = (d["offset"] as? Int) ?? 0
        let returned = (d["returned"] as? Int) ?? 0
        let hasMore = (d["hasMore"] as? Bool) ?? false
        let assets = (d["assets"] as? [[String: Any]]) ?? []

        var lines: [String] = []
        let heading = isInbox ? "Inbox Assets" : "Search Results"
        lines.append("\(bold(heading))  \(dim("showing \(returned) of \(total) (offset \(offset))"))")
        if assets.isEmpty {
            lines.append("  \(dim("(no matching assets)"))")
            return lines.joined(separator: "\n")
        }
        if let cs = d["contactSheet"] as? [String: Any], let saved = cs["savedPath"] as? String, !saved.isEmpty {
            lines.append("  \(green("✓")) Contact Sheet: \(saved)")
        }
        lines.append("")
        for a in assets {
            lines.append(formatAssetRow(a))
        }
        if let facets = d["facets"] as? [String: Any] {
            var hintParts: [String] = []
            if let fList = facets["topFolders"] as? [[String: Any]], !fList.isEmpty {
                let fStr = fList.prefix(4).compactMap { f -> String? in
                    guard let p = f["path"] as? String, let c = f["count"] as? Int else { return nil }
                    return "\(p)(\(c))"
                }.joined(separator: ", ")
                if !fStr.isEmpty { hintParts.append("Folders: \(fStr)") }
            }
            if let tList = facets["topTags"] as? [[String: Any]], !tList.isEmpty {
                let tStr = tList.prefix(5).compactMap { t -> String? in
                    guard let n = t["name"] as? String, let c = t["count"] as? Int else { return nil }
                    return "#\(n)(\(c))"
                }.joined(separator: " ")
                if !tStr.isEmpty { hintParts.append("Tags: \(tStr)") }
            }
            if !hintParts.isEmpty {
                lines.append("")
                lines.append(dim("Facets · " + hintParts.joined(separator: " | ")))
            }
        }
        if hasMore, let nextOffset = d["nextOffset"] as? Int {
            lines.append("")
            lines.append(dim("More results available — pass `--offset \(nextOffset)` for the next page."))
        }
        return lines.joined(separator: "\n")
    }

    private func renderScoredAssetList(_ d: [String: Any], arrayKey: String, heading: String) -> String {
        let items = (d[arrayKey] as? [[String: Any]]) ?? []
        var lines: [String] = []
        lines.append("\(bold(heading))  \(dim("(\(items.count) items)"))")
        if let summary = d["summary"] as? String, !summary.isEmpty {
            lines.append("  \(dim(summary))")
        }
        if let cs = d["contactSheet"] as? [String: Any], let saved = cs["savedPath"] as? String, !saved.isEmpty {
            lines.append("  \(green("✓")) Contact Sheet: \(saved)")
        }
        if items.isEmpty {
            lines.append("  \(dim("(no matches)"))")
            return lines.joined(separator: "\n")
        }
        lines.append("")
        for item in items {
            let score = (item["score"] as? Double).map { String(format: "%.2f", $0) } ?? ""
            let suffix = score.isEmpty ? "" : " \(green("[\(score)]"))"
            lines.append(formatAssetRow(item) + suffix)
        }
        return lines.joined(separator: "\n")
    }

    private func formatAssetRow(_ a: [String: Any]) -> String {
        let badge = (a["badge"] as? String).map { "\(yellow($0)) " } ?? ""
        let id = (a["id"] as? String) ?? ""
        let shortID = String(id.prefix(8))
        let title = (a["title"] as? String) ?? "(untitled)"
        let kind = (a["mediaKind"] as? String) ?? "image"
        let folder = (a["folderPath"] as? String) ?? "Inbox"
        let rating = (a["rating"] as? Int) ?? 0
        let stars = rating > 0 ? " " + yellow(String(repeating: "★", count: rating)) : ""
        let tags = ((a["tags"] as? [String]) ?? []).prefix(4).map { "#\($0)" }.joined(separator: " ")
        let tagStr = tags.isEmpty ? "" : "  \(dim(tags))"
        return "  \(badge)\(cyan(shortID))  \(bold(title))\(stars)  \(dim("[\(kind) · \(folder)]"))\(tagStr)"
    }

    private func renderAssetDetail(_ d: [String: Any]) -> String {
        if let batch = d["assets"] as? [[String: Any]] {
            return batch.map { renderSingleAssetDetail($0) }.joined(separator: "\n\n")
        }
        return renderSingleAssetDetail(d)
    }

    private func renderSingleAssetDetail(_ d: [String: Any]) -> String {
        var lines: [String] = []
        let title = (d["title"] as? String) ?? "(untitled)"
        let id = (d["id"] as? String) ?? ""
        let displayType = (d["displayType"] as? String) ?? (d["mediaKind"] as? String) ?? "asset"
        lines.append("\(bold(title))  \(dim("[\(displayType)]"))")
        lines.append("  ID:        \(cyan(id))")
        lines.append("  Folder:    \((d["folderPath"] as? String) ?? "Inbox")")
        if let w = d["pixelWidth"] as? Int, let h = d["pixelHeight"] as? Int, w > 0, h > 0 {
            let size = Self.formatBytes((d["fileSizeBytes"] as? Int64) ?? Int64((d["fileSizeBytes"] as? Int) ?? 0))
            lines.append("  Media:     \(w)×\(h) · \(size) · \((d["mimeType"] as? String) ?? "")")
        }
        if let colors = d["dominantColors"] as? [String], !colors.isEmpty {
            lines.append("  Palette:   \(colors.joined(separator: "  "))")
        }
        if let tags = d["tags"] as? [String], !tags.isEmpty {
            lines.append("  Tags:      \(tags.map { "#\($0)" }.joined(separator: " "))")
        }
        if let notes = d["notes"] as? String, !notes.isEmpty {
            lines.append("  Notes:     \(notes.replacingOccurrences(of: "\n", with: " "))")
        }
        if let desc = d["aiDescription"] as? String, !desc.isEmpty {
            lines.append("  AI Desc:   \(desc)")
        }
        if let url = d["sourceURL"] as? String, !url.isEmpty {
            lines.append("  Source:    \(url)")
        }
        if let rich = d["richMetadata"] as? [String: Any] {
            if let exif = rich["photoExif"] as? [String: Any], (exif["hasMeaningfulCameraExif"] as? Bool) == true {
                let parts = [exif["cameraDisplayName"] as? String, exif["lensModel"] as? String, exif["exposureSummary"] as? String]
                    .compactMap { $0 }.filter { !$0.isEmpty }
                if !parts.isEmpty {
                    lines.append("  EXIF:      \(parts.joined(separator: " · "))")
                }
            }
            if let ai = rich["aiGeneration"] as? [String: Any] {
                let header = [ai["generator"] as? String, ai["modelName"] as? String, ai["sampler"] as? String]
                    .compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " · ")
                if !header.isEmpty { lines.append("  AI Gen:    \(header)") }
                if let prompt = ai["prompt"] as? String, !prompt.isEmpty {
                    lines.append("  Prompt:    \(String(prompt.prefix(240)))")
                }
            }
            if let repo = rich["githubRepo"] as? [String: Any] {
                let stars = (repo["stars"] as? Int) ?? 0
                let lang = (repo["language"] as? String) ?? ""
                lines.append("  GitHub:    \((repo["fullName"] as? String) ?? "") ★\(stars) \(lang)")
            }
            if let post = rich["socialPost"] as? [String: Any] {
                let author = (post["authorName"] as? String) ?? ""
                let handle = (post["authorHandle"] as? String) ?? ""
                lines.append("  Social:    \(author) (\(handle))")
            }
        }
        if let orig = d["localOriginalPath"] as? String, !orig.isEmpty {
            lines.append("  Original:  \(dim(orig))")
        }
        return lines.joined(separator: "\n")
    }

    private func renderBoardList(_ d: [String: Any]) -> String {
        let boards = (d["boards"] as? [[String: Any]]) ?? []
        var lines: [String] = []
        lines.append("\(bold("Moodboards"))  \(dim("(\(boards.count))"))")
        if boards.isEmpty {
            lines.append("  \(dim("(no moodboards)"))")
            return lines.joined(separator: "\n")
        }
        lines.append("")
        for b in boards {
            let id = String(((b["id"] as? String) ?? "").prefix(8))
            let title = (b["title"] as? String) ?? "(untitled)"
            let count = (b["itemCount"] as? Int) ?? 0
            let mode = (b["mode"] as? String) ?? ""
            let palette = ((b["paletteHexes"] as? [String]) ?? []).prefix(5).joined(separator: " ")
            lines.append("  \(cyan(id))  \(bold(title))  \(dim("[\(count) items · \(mode)]"))  \(dim(palette))")
        }
        return lines.joined(separator: "\n")
    }

    private func renderBoardDetail(_ d: [String: Any]) -> String {
        var lines: [String] = []
        let title = (d["title"] as? String) ?? "(untitled)"
        let subtitle = (d["subtitle"] as? String) ?? ""
        let id = (d["id"] as? String) ?? ""
        lines.append("\(bold(title))  \(dim("[\((d["mode"] as? String) ?? "")]"))")
        if !subtitle.isEmpty { lines.append("  \(dim(subtitle))") }
        lines.append("  ID: \(cyan(id))  ·  Assets: \((d["itemCount"] as? Int) ?? 0)  ·  Connectors: \(((d["connectors"] as? [[String: Any]]) ?? []).count)")
        if let palette = d["palette"] as? [[String: Any]], !palette.isEmpty {
            let hexes = palette.compactMap { $0["hex"] as? String }.joined(separator: "  ")
            lines.append("  Palette: \(hexes)")
        }
        if let notes = d["notes"] as? [[String: Any]], !notes.isEmpty {
            lines.append("")
            lines.append(bold("Notes (\(notes.count))"))
            for n in notes {
                let nt = (n["title"] as? String) ?? ""
                let txt = ((n["text"] as? String) ?? "").replacingOccurrences(of: "\n", with: " ")
                lines.append("  • \(nt.isEmpty ? "" : "\(bold(nt)): ")\(txt)")
            }
        }
        if let assets = d["assets"] as? [[String: Any]], !assets.isEmpty {
            lines.append("")
            lines.append(bold("Referenced Assets (\(assets.count))"))
            for a in assets {
                let hero = (a["isHero"] as? Bool) == true ? " \(yellow("[HERO]"))" : ""
                lines.append(formatAssetRow(a) + hero)
            }
        }
        return lines.joined(separator: "\n")
    }

    private func renderContactSheet(_ d: [String: Any]) -> String {
        var lines: [String] = []
        let w = (d["sheetWidth"] as? Int) ?? 0
        let h = (d["sheetHeight"] as? Int) ?? 0
        let count = (d["slotCount"] as? Int) ?? 0
        let total = (d["totalMatched"] as? Int) ?? count
        lines.append("\(bold("Visual Contact Sheet"))  \(dim("\(w)×\(h) · \(count)/\(total) tiles"))")
        if let saved = d["savedPath"] as? String, !saved.isEmpty {
            lines.append("  \(green("✓")) Saved JPEG: \(saved)")
        } else {
            lines.append("  \(yellow("Tip:")) Pass `--out <file.jpg>` to save the rendered Contact Sheet image to disk.")
        }
        if let slots = d["slots"] as? [[String: Any]], !slots.isEmpty {
            lines.append("")
            for s in slots {
                let badge = (s["badge"] as? String) ?? ""
                let id = String(((s["assetID"] as? String) ?? "").prefix(8))
                let title = (s["title"] as? String) ?? ""
                let folder = (s["folderPath"] as? String) ?? "Inbox"
                lines.append("  \(cyan(badge))  \(dim(id))  \(title)  \(dim("[\(folder)]"))")
            }
        }
        if (d["hasMore"] as? Bool) == true, let nextOffset = d["nextOffset"] as? Int {
            lines.append("")
            lines.append(dim("More tiles available — pass `--offset \(nextOffset)` for the next sheet."))
        }
        return lines.joined(separator: "\n")
    }

    private func renderBoardExport(_ d: [String: Any]) -> String {
        var lines: [String] = []
        let title = (d["title"] as? String) ?? ""
        let bytes = Self.formatBytes((d["bytes"] as? Int64) ?? Int64((d["bytes"] as? Int) ?? 0))
        lines.append("\(bold("Moodboard Export"))  \(title) \(dim("(\(bytes))"))")
        if let saved = d["savedPath"] as? String, !saved.isEmpty {
            lines.append("  \(green("✓")) Saved PNG: \(saved)")
        } else {
            lines.append("  \(yellow("Tip:")) Pass `--out <file.png>` to write the rendered PNG to disk.")
        }
        return lines.joined(separator: "\n")
    }

    private func renderQuickJump(_ d: [String: Any]) -> String {
        let matches = (d["matches"] as? [[String: Any]]) ?? []
        var lines: [String] = []
        lines.append("\(bold("Quick Jump"))  \(dim("(\(matches.count) matches)"))")
        for m in matches {
            let kind = (m["kind"] as? String) ?? ""
            let title = (m["title"] as? String) ?? ""
            let sub = (m["subtitle"] as? String) ?? ""
            let id = (m["targetUUID"] as? String).map { " " + dim(String($0.prefix(8))) } ?? ""
            lines.append("  \(cyan("[\(kind)]")) \(bold(title))\(id)  \(dim(sub))")
        }
        return lines.joined(separator: "\n")
    }

    private func renderSuggestions(_ d: [String: Any]) -> String {
        let recs = (d["recommendations"] as? [[String: Any]]) ?? []
        var lines: [String] = []
        lines.append("\(bold("Folder Recommendations"))  \(dim("(\(recs.count) evaluated)"))")
        for r in recs {
            let aid = String(((r["assetID"] as? String) ?? "").prefix(8))
            let title = (r["assetTitle"] as? String) ?? ""
            let folderPath = (r["suggestedFolderPath"] as? String) ?? ""
            let reason = (r["reason"] as? String) ?? ""
            if folderPath.isEmpty {
                lines.append("  \(cyan(aid))  \(title)  → \(dim("(no confident match)"))")
            } else {
                let conf = (r["confidence"] as? Double).map { "\(Int(($0 * 100).rounded()))%" } ?? ""
                lines.append("  \(cyan(aid))  \(title)  → \(green(folderPath)) \(dim("(\(conf) · \(reason))"))")
            }
        }
        return lines.joined(separator: "\n")
    }

    private func writeStderr(_ msg: String) {
        FileHandle.standardError.write(Data(msg.utf8))
    }

    private static func formatBytes(_ bytes: Int64) -> String {
        let b = Double(max(0, bytes))
        if b < 1024 { return "\(bytes) B" }
        if b < 1024 * 1024 { return String(format: "%.1f KB", b / 1024) }
        if b < 1024 * 1024 * 1024 { return String(format: "%.1f MB", b / (1024 * 1024)) }
        return String(format: "%.2f GB", b / (1024 * 1024 * 1024))
    }
}
