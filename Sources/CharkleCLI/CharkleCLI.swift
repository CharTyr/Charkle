import CharkleCore
import Darwin
import Foundation

@main
struct CharkleCLI {
    static let version = "1.0.0"

    static func main() async {
        let rawArgs = Array(CommandLine.arguments.dropFirst())
        if rawArgs.isEmpty || rawArgs.contains("--help") || rawArgs.contains("-h") {
            printHelp()
            return
        }
        if rawArgs.first == "--version" || rawArgs.first == "-v" || rawArgs.first == "version" {
            print("charkle \(version)")
            return
        }

        // Optional global `--library-dir <path>` override for scripts & automated testing
        var libraryDir: URL?
        var args: [String] = []
        var idx = 0
        while idx < rawArgs.count {
            if rawArgs[idx] == "--library-dir", idx + 1 < rawArgs.count {
                libraryDir = URL(fileURLWithPath: (rawArgs[idx + 1] as NSString).expandingTildeInPath, isDirectory: true)
                idx += 2
            } else {
                args.append(rawArgs[idx])
                idx += 1
            }
        }

        guard let command = args.first else {
            printHelp()
            return
        }
        let subArgs = Array(args.dropFirst())

        do {
            let resolvedDir = libraryDir ?? ExternalAgentConfigStore.defaultDirectory()
            let engine = try LiveCharkleEngine.make(appSupportDirectory: resolvedDir, startAutoSync: false)
            let service = CharkleExternalAgentService(engine: engine, configDirectory: resolvedDir, notifyOnWrite: true)

            switch command {
            case "mcp":
                await runMCPStdioLoop(service: service)
            case "status":
                let policy = service.currentPolicy()
                let overview = await service.callTool(name: "library_overview", arguments: [:])
                if policy.allowsRead {
                    printToolOutput(overview)
                } else {
                    print(CharkleExternalAgentService.encodePrettyJSON([
                        "enabled": policy.enabled,
                        "accessLevel": policy.accessLevel.rawValue,
                        "libraryDir": resolvedDir.path
                    ]))
                }
            case "overview":
                printToolOutput(await service.callTool(name: "library_overview", arguments: [:]))
            case "inbox":
                let flags = parseFlags(subArgs)
                var params: [String: Any] = [:]
                if let limit = flags["limit"].flatMap(Int.init) { params["limit"] = limit }
                printToolOutput(await service.callTool(name: "list_inbox", arguments: params))
            case "search":
                let (positionals, flags) = parsePositionalsAndFlags(subArgs)
                var params: [String: Any] = [:]
                if let q = flags["query"] ?? positionals.first, !q.isEmpty { params["query"] = q }
                if let f = flags["folder"] { params["folder_path"] = f }
                if let tag = flags["tag"] { params["tags"] = splitCSV(tag) }
                if let color = flags["color"] { params["color_hex"] = color }
                if let limit = flags["limit"].flatMap(Int.init) { params["limit"] = limit }
                if flags["inbox"] == "true" { params["only_inbox"] = true }
                if flags["untagged"] == "true" { params["only_untagged"] = true }
                printToolOutput(await service.callTool(name: "search_assets", arguments: params))
            case "asset":
                let (positionals, flags) = parsePositionalsAndFlags(subArgs)
                let id = flags["id"] ?? positionals.first ?? ""
                printToolOutput(await service.callTool(name: "get_asset", arguments: ["asset_id": id]))
            case "contact-sheet":
                let (_, flags) = parsePositionalsAndFlags(subArgs)
                var params: [String: Any] = [:]
                if let q = flags["query"] { params["query"] = q }
                if let f = flags["folder"] { params["folder_path"] = f }
                if let ids = flags["ids"] { params["asset_ids"] = splitCSV(ids) }
                if flags["inbox"] == "true" { params["only_inbox"] = true }
                if flags["untagged"] == "true" { params["only_untagged"] = true }
                if let color = flags["color"] { params["color_hex"] = color }
                if let limit = flags["limit"].flatMap(Int.init) { params["limit"] = limit }
                if let out = flags["out"] ?? flags["output"] { params["output_path"] = out }
                printToolOutput(await service.callTool(name: "render_contact_sheet", arguments: params))
            case "board":
                await handleBoardCommand(subArgs, service: service)
            case "organize":
                let (_, flags) = parsePositionalsAndFlags(subArgs)
                var params: [String: Any] = [:]
                if let ids = flags["ids"] { params["asset_ids"] = splitCSV(ids) }
                if let f = flags["folder"] { params["folder_path"] = f }
                if flags["inbox"] == "true" { params["move_to_inbox"] = true }
                if let add = flags["add-tags"] { params["add_tags"] = splitCSV(add) }
                if let rem = flags["remove-tags"] { params["remove_tags"] = splitCSV(rem) }
                if let rating = flags["rating"].flatMap(Int.init) { params["rating"] = rating }
                if let notes = flags["notes"] { params["notes"] = notes }
                if let title = flags["title"] { params["title"] = title }
                if let desc = flags["ai-description"] { params["ai_description"] = desc }
                printToolOutput(await service.callTool(name: "organize_assets", arguments: params))
            case "folder":
                guard subArgs.first == "create" else {
                    writeStderr("Usage: charkle folder create <name> [--parent <path>]\n")
                    exit(2)
                }
                let (positionals, flags) = parsePositionalsAndFlags(Array(subArgs.dropFirst()))
                var params: [String: Any] = ["name": positionals.first ?? ""]
                if let parent = flags["parent"] { params["parent_path"] = parent }
                printToolOutput(await service.callTool(name: "create_folder", arguments: params))
            case "import":
                let (positionals, flags) = parsePositionalsAndFlags(subArgs)
                var params: [String: Any] = [:]
                if let target = positionals.first {
                    if target.hasPrefix("http://") || target.hasPrefix("https://") {
                        params["web_url"] = target
                    } else {
                        params["file_path"] = target
                    }
                }
                if let text = flags["text"] { params["text"] = text }
                if let title = flags["title"] { params["title"] = title }
                if let folder = flags["folder"] { params["folder_path"] = folder }
                if let tags = flags["tags"] { params["tags"] = splitCSV(tags) }
                printToolOutput(await service.callTool(name: "ingest_asset", arguments: params))
            case "trash":
                let (_, flags) = parsePositionalsAndFlags(subArgs)
                var params: [String: Any] = [
                    "trashed": flags["restore"] != "true"
                ]
                if let ids = flags["ids"] { params["asset_ids"] = splitCSV(ids) }
                printToolOutput(await service.callTool(name: "trash_assets", arguments: params))
            default:
                writeStderr("Unknown command: \(command)\nRun `charkle --help` for usage.\n")
                exit(2)
            }
        } catch {
            writeStderr("Error: \(error.localizedDescription)\n")
            exit(1)
        }
    }

    // MARK: - Board Subcommands

    private static func handleBoardCommand(_ subArgs: [String], service: CharkleExternalAgentService) async {
        guard let action = subArgs.first else {
            writeStderr("Usage: charkle board <list|get|export|compose> ...\n")
            exit(2)
        }
        let rest = Array(subArgs.dropFirst())
        let (positionals, flags) = parsePositionalsAndFlags(rest)

        switch action {
        case "list":
            printToolOutput(await service.callTool(name: "list_boards", arguments: [:]))
        case "get":
            var params: [String: Any] = [:]
            if let ref = positionals.first {
                if UUID(uuidString: ref) != nil { params["board_id"] = ref } else { params["title"] = ref }
            }
            printToolOutput(await service.callTool(name: "get_board_context", arguments: params))
        case "export":
            var params: [String: Any] = [:]
            if let ref = positionals.first {
                if UUID(uuidString: ref) != nil { params["board_id"] = ref } else { params["title"] = ref }
            }
            if let out = flags["out"] ?? flags["output"] { params["output_path"] = out }
            if let w = flags["width"].flatMap(Int.init) { params["width"] = w }
            if flags["dark"] == "true" { params["dark_appearance"] = true }
            printToolOutput(await service.callTool(name: "export_board_image", arguments: params))
        case "compose":
            var params: [String: Any] = [:]
            if let title = flags["title"] { params["title"] = title }
            if let subtitle = flags["subtitle"] { params["subtitle"] = subtitle }
            if let prompt = flags["prompt"] ?? positionals.first { params["prompt"] = prompt }
            if let ids = flags["ids"] { params["asset_ids"] = splitCSV(ids) }
            if let note = flags["note"] { params["curator_note"] = note }
            if let layout = flags["layout"] { params["layout_style"] = layout }
            if flags["freeform"] == "true" { params["use_freeform"] = true }
            printToolOutput(await service.callTool(name: "compose_moodboard", arguments: params))
        default:
            writeStderr("Unknown board subcommand: \(action)\n")
            exit(2)
        }
    }

    // MARK: - Stdio MCP Server Loop (NDJSON + Content-Length Framing)

    private static func runMCPStdioLoop(service: CharkleExternalAgentService) async {
        // Ensure unbuffered stdout for immediate JSON-RPC responses
        setvbuf(stdout, nil, _IONBF, 0)

        let stdinHandle = FileHandle.standardInput
        var buffer = Data()

        while true {
            let chunk = stdinHandle.availableData
            if chunk.isEmpty {
                // EOF — drain any trailing newline-free JSON line then exit cleanly
                let trimmed = buffer.trimmingWhitespaceAndNewlines()
                if !trimmed.isEmpty, let reply = await service.handleJSONRPC(trimmed) {
                    writeNDJSON(reply)
                }
                break
            }
            buffer.append(chunk)

            while true {
                // Mode 1: Content-Length LSP framing
                if let headerRange = buffer.range(of: Data("\r\n\r\n".utf8)),
                   let headerText = String(data: buffer.subdata(in: buffer.startIndex..<headerRange.lowerBound), encoding: .utf8),
                   headerText.lowercased().contains("content-length:") {
                    var contentLength: Int?
                    for line in headerText.components(separatedBy: "\r\n") {
                        let lower = line.lowercased()
                        if lower.hasPrefix("content-length:") {
                            contentLength = Int(line.dropFirst("content-length:".count).trimmingCharacters(in: .whitespaces))
                        }
                    }
                    guard let len = contentLength else {
                        buffer.removeSubrange(buffer.startIndex..<headerRange.upperBound)
                        continue
                    }
                    let bodyStart = headerRange.upperBound
                    let bodyEnd = bodyStart + len
                    guard buffer.count >= bodyEnd else { break } // wait for more bytes
                    let payload = buffer.subdata(in: bodyStart..<bodyEnd)
                    buffer.removeSubrange(buffer.startIndex..<bodyEnd)
                    if let reply = await service.handleJSONRPC(payload) {
                        writeContentLengthFramed(reply)
                    }
                    continue
                }

                // Mode 2: Standard MCP newline-delimited JSON-RPC
                guard let newlineIndex = buffer.firstIndex(of: 0x0A) else { break }
                let lineData = buffer.subdata(in: buffer.startIndex..<newlineIndex)
                buffer.removeSubrange(buffer.startIndex...newlineIndex)
                let trimmed = lineData.trimmingWhitespaceAndNewlines()
                guard !trimmed.isEmpty else { continue }
                // Skip stray header lines if a Content-Length stream is mid-arrival
                if let text = String(data: trimmed, encoding: .utf8),
                   text.lowercased().hasPrefix("content-length:") || text.lowercased().hasPrefix("content-type:") {
                    continue
                }
                if let reply = await service.handleJSONRPC(trimmed) {
                    writeNDJSON(reply)
                }
            }
        }
    }

    private static func writeNDJSON(_ data: Data) {
        var out = data
        out.append(0x0A)
        FileHandle.standardOutput.write(out)
    }

    private static func writeContentLengthFramed(_ data: Data) {
        let header = "Content-Length: \(data.count)\r\n\r\n"
        FileHandle.standardOutput.write(Data(header.utf8))
        FileHandle.standardOutput.write(data)
    }

    // MARK: - Output & Argument Parsing

    private static func printToolOutput(_ output: CharkleExternalAgentService.ToolOutput) {
        for item in output.content {
            if case .text(let text) = item {
                print(text)
            }
        }
        if output.isError {
            exit(1)
        }
    }

    private static func writeStderr(_ message: String) {
        FileHandle.standardError.write(Data(message.utf8))
    }

    private static func parseFlags(_ args: [String]) -> [String: String] {
        parsePositionalsAndFlags(args).1
    }

    private static func parsePositionalsAndFlags(_ args: [String]) -> ([String], [String: String]) {
        var positionals: [String] = []
        var flags: [String: String] = [:]
        var i = 0
        while i < args.count {
            let token = args[i]
            if token == "--json" {
                flags["json"] = "true"
                i += 1
            } else if token.hasPrefix("--") {
                let key = String(token.dropFirst(2))
                if i + 1 < args.count && !args[i + 1].hasPrefix("--") {
                    flags[key] = args[i + 1]
                    i += 2
                } else {
                    flags[key] = "true"
                    i += 1
                }
            } else {
                positionals.append(token)
                i += 1
            }
        }
        return (positionals, flags)
    }

    private static func splitCSV(_ raw: String) -> [String] {
        raw.split(separator: ",").map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
    }

    private static func printHelp() {
        print("""
        charkle \(version) — Charkle Visual Reference Library CLI & Native MCP Server

        USAGE:
          charkle mcp                                     Run stdio MCP server (for Claude Code, Cursor, Codex, etc.)
          charkle status [--json]                         Show library overview & external agent access status
          charkle overview [--json]                       Get folder tree, tags, counts, and media distribution
          charkle search <query> [--folder P] [--tag T] [--color #HEX] [--inbox] [--untagged] [--limit N] [--json]
          charkle inbox [--limit N] [--json]              List untriaged Inbox assets
          charkle asset <uuid> [--json]                   Inspect full asset metadata & local paths
          charkle contact-sheet [--query Q] [--inbox] [--folder P] [--ids A,B] --out <file.jpg> [--json]
          charkle board list [--json]                     List all moodboards
          charkle board get <id-or-title> [--json]        Read moodboard palette, notes, sections, and assets
          charkle board export <id-or-title> --out <file.png> [--width 1440] [--dark] [--json]
          charkle board compose --title T [--ids A,B | --prompt P] [--note N] [--freeform] [--json]
          charkle organize --ids A,B [--folder P | --inbox] [--add-tags x,y] [--remove-tags z] [--rating N] [--notes S]
          charkle folder create <name> [--parent P] [--json]
          charkle import <file-path-or-url> [--folder P] [--tags x,y] [--json]
          charkle trash --ids A,B [--restore] [--json]    Soft move to Trash only (permanent delete disabled)

        GLOBAL OPTIONS:
          --library-dir <path>                            Override Application Support directory
          --version                                       Print version
          --help                                          Show this help
        """)
    }
}

private extension Data {
    func trimmingWhitespaceAndNewlines() -> Data {
        var start = startIndex
        var end = endIndex
        while start < end && (self[start] == 0x20 || self[start] == 0x09 || self[start] == 0x0D || self[start] == 0x0A) {
            start += 1
        }
        while end > start && (self[end - 1] == 0x20 || self[end - 1] == 0x09 || self[end - 1] == 0x0D || self[end - 1] == 0x0A) {
            end -= 1
        }
        return subdata(in: start..<end)
    }
}
