import CharkleCore
import Darwin
import Foundation

@main
struct CharkleCLI {
    static let version = CharkleExternalAgentService.serverVersion

    private static let knownCommands: Set<String> = [
        "mcp", "doctor", "status", "overview",
        "inbox", "search", "semantic", "similar", "jump",
        "asset", "contact-sheet", "board", "folder",
        "organize", "analyze", "import", "trash", "completions"
    ]

    static func main() async {
        let rawArgs = Array(CommandLine.arguments.dropFirst())
        if rawArgs.isEmpty {
            printGlobalHelp()
            return
        }

        let global = CLIArgParser.extractGlobalOptions(rawArgs)
        let formatter = CLIFormatter(
            explicitJSON: global.explicitJSON,
            compactJSON: global.compactJSON,
            noColor: global.noColor
        )

        guard let command = global.remaining.first else {
            printGlobalHelp()
            return
        }
        if command == "--help" || command == "-h" || command == "help" {
            if let topic = global.remaining.dropFirst().first {
                guard knownCommands.contains(topic) else {
                    formatter.emitError("Unknown command: \(topic). Run `charkle --help` for usage.")
                    exit(2)
                }
                printSubcommandHelp(topic)
            } else {
                printGlobalHelp()
            }
            return
        }
        if command == "--version" || command == "-v" || command == "version" {
            if formatter.mode == .prettyJSON || formatter.mode == .compactJSON {
                formatter.emitJSON([
                    "name": "charkle",
                    "version": version,
                    "protocolVersions": CharkleExternalAgentService.supportedProtocolVersions
                ])
            } else {
                print("charkle \(version)")
            }
            return
        }

        let subArgs = Array(global.remaining.dropFirst())

        if command == "completions" {
            let parsed = CLIArgParser.parse(subArgs)
            if parsed.wantsHelp || parsed.positionals.isEmpty {
                printSubcommandHelp("completions")
                return
            }
            guard let shell = parsed.positionals.first, let script = CLICompletions.script(for: shell) else {
                formatter.emitError("Unsupported shell. Expected one of: zsh, bash, fish.")
                exit(2)
            }
            print(script)
            return
        }

        guard knownCommands.contains(command) else {
            formatter.emitError("Unknown command: \(command). Run `charkle --help` for usage.")
            exit(2)
        }

        // Per-subcommand `--help` / `-h` before touching SQLite or policy.
        let quickParsed = CLIArgParser.parse(subArgs)
        if quickParsed.wantsHelp {
            printSubcommandHelp(command)
            return
        }

        do {
            let resolvedDir = global.libraryDir ?? ExternalAgentConfigStore.defaultDirectory()
            let engine = try LiveCharkleEngine.make(appSupportDirectory: resolvedDir, startAutoSync: false)
            let service = CharkleExternalAgentService(engine: engine, configDirectory: resolvedDir, notifyOnWrite: true)

            switch command {
            case "mcp":
                let policy = service.currentPolicy()
                if !policy.allowsRead(for: .mcp) && isatty(STDIN_FILENO) != 0 {
                    writeStderr("MCP 服务已在 Charkle「设置 → 外部 Agent」中关闭，请先开启「启用 MCP 服务」后再试。\n")
                    exit(1)
                }
                await runMCPStdioLoop(service: service)

            case "doctor":
                var report = await service.runDiagnostics()
                report["cliLink"] = inspectLocalBinSymlink()
                formatter.emitJSON(report, humanRenderer: formatter.renderDoctor)
                if (report["ok"] as? Bool) != true {
                    exit(1)
                }

            case "status":
                let policy = service.currentPolicy()
                if policy.allowsRead(for: .cli) {
                    let out = await service.callTool(name: "library_overview", arguments: [:], channel: .cli)
                    formatter.emitToolOutput(out, command: "library_overview")
                } else {
                    formatter.emitJSON([
                        "enabled": policy.enabled,
                        "mcpEnabled": policy.mcpEnabled,
                        "cliEnabled": policy.cliEnabled,
                        "accessLevel": policy.accessLevel.rawValue,
                        "libraryDir": resolvedDir.path
                    ])
                }

            case "overview":
                let out = await service.callTool(name: "library_overview", arguments: [:], channel: .cli)
                formatter.emitToolOutput(out, command: "library_overview")

            case "inbox":
                await handleInboxCommand(subArgs, service: service, formatter: formatter)

            case "search":
                await handleSearchCommand(subArgs, service: service, formatter: formatter)

            case "semantic":
                await handleSemanticCommand(subArgs, service: service, formatter: formatter)

            case "similar":
                await handleSimilarCommand(subArgs, service: service, formatter: formatter)

            case "jump":
                await handleJumpCommand(subArgs, service: service, formatter: formatter)

            case "asset":
                let parsed = CLIArgParser.parse(subArgs)
                guard let id = parsed.first("id") ?? parsed.positionals.first, !id.isEmpty else {
                    formatter.emitError("Missing asset UUID. Usage: charkle asset <uuid> [--json]")
                    exit(2)
                }
                let out = await service.callTool(name: "get_asset", arguments: ["asset_id": id], channel: .cli)
                formatter.emitToolOutput(out, command: "get_asset")

            case "contact-sheet":
                await handleContactSheetCommand(subArgs, service: service, formatter: formatter)

            case "board":
                await handleBoardCommand(subArgs, service: service, formatter: formatter)

            case "folder":
                await handleFolderCommand(subArgs, service: service, formatter: formatter)

            case "organize":
                await handleOrganizeCommand(subArgs, service: service, formatter: formatter)

            case "analyze":
                await handleAnalyzeCommand(subArgs, service: service, formatter: formatter)

            case "import":
                await handleImportCommand(subArgs, service: service, formatter: formatter)

            case "trash":
                await handleTrashCommand(subArgs, service: service, formatter: formatter)

            default:
                formatter.emitError("Unknown command: \(command). Run `charkle --help` for usage.")
                exit(2)
            }
        } catch {
            formatter.emitError(error.localizedDescription)
            exit(1)
        }
    }

    // MARK: - Command Handlers

    private static func handleInboxCommand(
        _ subArgs: [String],
        service: CharkleExternalAgentService,
        formatter: CLIFormatter
    ) async {
        let parsed = CLIArgParser.parse(subArgs)
        var params: [String: Any] = [:]
        if let limit = parsed.int("limit") { params["limit"] = limit }
        if let offset = parsed.int("offset") { params["offset"] = offset }
        if let sort = parsed.first("sort") { params["sort_by"] = sort }
        let kinds = parsed.csvValues("kind") + parsed.csvValues("kinds")
        if !kinds.isEmpty { params["media_kinds"] = kinds }

        let inboxOut = await service.callTool(name: "list_inbox", arguments: params, channel: .cli)
        guard parsed.flag("suggest"), !inboxOut.isError else {
            formatter.emitToolOutput(inboxOut, command: "list_inbox")
            return
        }

        // Optional `--suggest` chains `suggest_folder` onto the fetched Inbox batch for instant CLI triage.
        let rawText = inboxOut.content.compactMap { if case .text(let t) = $0 { return t } else { return nil } }.joined()
        if let data = rawText.data(using: .utf8),
           let dict = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let assets = dict["assets"] as? [[String: Any]] {
            let ids = assets.prefix(20).compactMap { $0["id"] as? String }
            if !ids.isEmpty {
                let sugOut = await service.callTool(name: "suggest_folder", arguments: ["asset_ids": ids], channel: .cli)
                formatter.emitToolOutput(sugOut, command: "suggest_folder")
                return
            }
        }
        formatter.emitToolOutput(inboxOut, command: "list_inbox")
    }

    private static func handleSearchCommand(
        _ subArgs: [String],
        service: CharkleExternalAgentService,
        formatter: CLIFormatter
    ) async {
        let parsed = CLIArgParser.parse(subArgs)
        var params: [String: Any] = [:]
        let queryFromPositionals = parsed.positionals.joined(separator: " ").trimmingCharacters(in: .whitespacesAndNewlines)
        if let q = parsed.first("query") ?? (queryFromPositionals.isEmpty ? nil : queryFromPositionals) {
            params["query"] = q
        }
        if let f = parsed.first("folder") {
            if UUID(uuidString: f) != nil { params["folder_id"] = f } else { params["folder_path"] = f }
        }
        if parsed.flag("subfolders") { params["include_subfolders"] = true }
        if let sf = parsed.first("smart-folder") {
            if UUID(uuidString: sf) != nil { params["smart_folder_id"] = sf } else { params["smart_folder_name"] = sf }
        }
        let tags = parsed.csvValues("tag") + parsed.csvValues("tags")
        if !tags.isEmpty { params["tags"] = tags }
        let kinds = parsed.csvValues("kind") + parsed.csvValues("kinds")
        if !kinds.isEmpty { params["media_kinds"] = kinds }
        if let shape = parsed.first("shape") { params["aspect_shape"] = shape }
        if let color = parsed.first("color") { params["color_hex"] = color }
        if let tol = parsed.double("color-tolerance") { params["color_tolerance"] = tol }
        if let rating = parsed.int("min-rating") { params["min_rating"] = rating }
        if let sort = parsed.first("sort") { params["sort_by"] = sort }
        if let days = parsed.int("recent-days") { params["only_recent_days"] = days }
        if let offset = parsed.int("offset") { params["offset"] = offset }
        if let limit = parsed.int("limit") { params["limit"] = limit }
        if parsed.flag("inbox") { params["only_inbox"] = true }
        if parsed.flag("untagged") { params["only_untagged"] = true }
        if parsed.flag("pinned") { params["only_pinned_offline"] = true }
        if parsed.flag("trashed") { params["only_trashed"] = true }
        if parsed.flag("include-trashed") { params["include_trashed"] = true }

        let out = await service.callTool(name: "search_assets", arguments: params, channel: .cli)
        formatter.emitToolOutput(out, command: "search_assets")
    }

    private static func handleSemanticCommand(
        _ subArgs: [String],
        service: CharkleExternalAgentService,
        formatter: CLIFormatter
    ) async {
        let parsed = CLIArgParser.parse(subArgs)
        let query = parsed.first("query") ?? parsed.positionals.joined(separator: " ").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else {
            formatter.emitError("Missing query. Usage: charkle semantic <query> [--folder P] [--limit N]")
            exit(2)
        }
        var params: [String: Any] = ["query": query]
        if let f = parsed.first("folder") {
            if UUID(uuidString: f) != nil { params["folder_id"] = f } else { params["folder_path"] = f }
        }
        if parsed.flag("subfolders") { params["include_subfolders"] = true }
        let tags = parsed.csvValues("tag") + parsed.csvValues("tags")
        if !tags.isEmpty { params["tags"] = tags }
        let kinds = parsed.csvValues("kind") + parsed.csvValues("kinds")
        if !kinds.isEmpty { params["media_kinds"] = kinds }
        if let color = parsed.first("color") { params["color_hex"] = color }
        if let rating = parsed.int("min-rating") { params["min_rating"] = rating }
        if let limit = parsed.int("limit") { params["limit"] = limit }

        let out = await service.callTool(name: "semantic_search", arguments: params, channel: .cli)
        formatter.emitToolOutput(out, command: "semantic_search")
    }

    private static func handleSimilarCommand(
        _ subArgs: [String],
        service: CharkleExternalAgentService,
        formatter: CLIFormatter
    ) async {
        let parsed = CLIArgParser.parse(subArgs)
        guard let id = parsed.first("id") ?? parsed.positionals.first, !id.isEmpty else {
            formatter.emitError("Missing asset UUID. Usage: charkle similar <asset-uuid> [--limit N]")
            exit(2)
        }
        var params: [String: Any] = ["asset_id": id]
        if let limit = parsed.int("limit") { params["limit"] = limit }
        if parsed.flag("contact-sheet") { params["render_contact_sheet"] = true }
        let out = await service.callTool(name: "find_similar_assets", arguments: params, channel: .cli)
        formatter.emitToolOutput(out, command: "find_similar_assets")
    }

    private static func handleJumpCommand(
        _ subArgs: [String],
        service: CharkleExternalAgentService,
        formatter: CLIFormatter
    ) async {
        let parsed = CLIArgParser.parse(subArgs)
        let query = parsed.first("query") ?? parsed.positionals.joined(separator: " ").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else {
            formatter.emitError("Missing query. Usage: charkle jump <query> [--limit N]")
            exit(2)
        }
        var params: [String: Any] = ["query": query]
        if let limit = parsed.int("limit") { params["limit"] = limit }
        let out = await service.callTool(name: "quick_jump", arguments: params, channel: .cli)
        formatter.emitToolOutput(out, command: "quick_jump")
    }

    private static func handleContactSheetCommand(
        _ subArgs: [String],
        service: CharkleExternalAgentService,
        formatter: CLIFormatter
    ) async {
        let parsed = CLIArgParser.parse(subArgs)
        var params: [String: Any] = ["include_image": false]
        let queryFromPos = parsed.positionals.joined(separator: " ").trimmingCharacters(in: .whitespacesAndNewlines)
        if let q = parsed.first("query") ?? (queryFromPos.isEmpty ? nil : queryFromPos) { params["query"] = q }
        if let f = parsed.first("folder") {
            if UUID(uuidString: f) != nil { params["folder_id"] = f } else { params["folder_path"] = f }
        }
        if parsed.flag("subfolders") { params["include_subfolders"] = true }
        let ids = parsed.csvValues("ids")
        if !ids.isEmpty { params["asset_ids"] = ids }
        let tags = parsed.csvValues("tag") + parsed.csvValues("tags")
        if !tags.isEmpty { params["tags"] = tags }
        let kinds = parsed.csvValues("kind") + parsed.csvValues("kinds")
        if !kinds.isEmpty { params["media_kinds"] = kinds }
        if let shape = parsed.first("shape") { params["aspect_shape"] = shape }
        if parsed.flag("inbox") { params["only_inbox"] = true }
        if parsed.flag("untagged") { params["only_untagged"] = true }
        if parsed.flag("trashed") { params["only_trashed"] = true }
        if let color = parsed.first("color") { params["color_hex"] = color }
        if let sort = parsed.first("sort") { params["sort_by"] = sort }
        if let offset = parsed.int("offset") { params["offset"] = offset }
        if let limit = parsed.int("limit") { params["limit"] = limit }
        if let width = parsed.int("width") { params["max_width"] = width }
        if let outPath = parsed.first("out") ?? parsed.first("output") { params["output_path"] = outPath }

        let out = await service.callTool(name: "render_contact_sheet", arguments: params, channel: .cli)
        formatter.emitToolOutput(out, command: "render_contact_sheet")
    }

    private static func handleBoardCommand(
        _ subArgs: [String],
        service: CharkleExternalAgentService,
        formatter: CLIFormatter
    ) async {
        guard let action = subArgs.first else {
            printSubcommandHelp("board")
            exit(2)
        }
        let rest = Array(subArgs.dropFirst())
        let parsed = CLIArgParser.parse(rest)
        if parsed.wantsHelp {
            printSubcommandHelp("board")
            return
        }

        switch action {
        case "list":
            let out = await service.callTool(name: "list_boards", arguments: [:], channel: .cli)
            formatter.emitToolOutput(out, command: "list_boards")

        case "get":
            var params: [String: Any] = [:]
            let positionalRef = parsed.positionals.joined(separator: " ").trimmingCharacters(in: .whitespacesAndNewlines)
            if let ref = parsed.first("id") ?? (positionalRef.isEmpty ? nil : positionalRef) {
                if UUID(uuidString: ref) != nil { params["board_id"] = ref } else { params["title"] = ref }
            }
            let out = await service.callTool(name: "get_board_context", arguments: params, channel: .cli)
            formatter.emitToolOutput(out, command: "get_board_context")

        case "export":
            var params: [String: Any] = ["include_image": false]
            let positionalRef = parsed.positionals.joined(separator: " ").trimmingCharacters(in: .whitespacesAndNewlines)
            if let ref = parsed.first("id") ?? (positionalRef.isEmpty ? nil : positionalRef) {
                if UUID(uuidString: ref) != nil { params["board_id"] = ref } else { params["title"] = ref }
            }
            if let outPath = parsed.first("out") ?? parsed.first("output") { params["output_path"] = outPath }
            if let w = parsed.int("width") { params["width"] = w }
            if parsed.flag("dark") { params["dark_appearance"] = true }
            let out = await service.callTool(name: "export_board_image", arguments: params, channel: .cli)
            formatter.emitToolOutput(out, command: "export_board_image")

        case "compose":
            var params: [String: Any] = [:]
            if let title = parsed.first("title") { params["title"] = title }
            if let subtitle = parsed.first("subtitle") { params["subtitle"] = subtitle }
            let positionalPrompt = parsed.positionals.joined(separator: " ").trimmingCharacters(in: .whitespacesAndNewlines)
            if let prompt = parsed.first("prompt") ?? (positionalPrompt.isEmpty ? nil : positionalPrompt) {
                params["prompt"] = prompt
            }
            let ids = parsed.csvValues("ids")
            if !ids.isEmpty { params["asset_ids"] = ids }
            let heroes = parsed.csvValues("hero-ids")
            if !heroes.isEmpty { params["hero_asset_ids"] = heroes }
            let seeds = parsed.csvValues("seed-ids")
            if !seeds.isEmpty { params["seed_asset_ids"] = seeds }
            let tags = parsed.csvValues("tag") + parsed.csvValues("tags")
            if !tags.isEmpty { params["required_tags"] = tags }
            let palette = parsed.csvValues("palette")
            if !palette.isEmpty { params["target_palette"] = palette }
            if let f = parsed.first("folder") {
                if UUID(uuidString: f) != nil { params["folder_id"] = f } else { params["folder_path"] = f }
            }
            if let count = parsed.int("count") ?? parsed.int("limit") { params["preferred_count"] = count }
            if let note = parsed.first("note") { params["curator_note"] = note }
            if let layout = parsed.first("layout") { params["layout_style"] = layout }
            if parsed.flag("freeform") { params["use_freeform"] = true }
            let out = await service.callTool(name: "compose_moodboard", arguments: params, channel: .cli)
            formatter.emitToolOutput(out, command: "compose_moodboard")

        case "patch":
            var params: [String: Any] = [:]
            let positionalRef = parsed.positionals.joined(separator: " ").trimmingCharacters(in: .whitespacesAndNewlines)
            if let ref = parsed.first("id") ?? (positionalRef.isEmpty ? nil : positionalRef) {
                if UUID(uuidString: ref) != nil { params["board_id"] = ref } else { params["title"] = ref }
            }
            if let newTitle = parsed.first("new-title") { params["new_title"] = newTitle }
            if let subtitle = parsed.first("subtitle") { params["subtitle"] = subtitle }
            if let freeform = parsed.optionalBool("freeform") { params["use_freeform"] = freeform }
            if let layout = parsed.first("layout") { params["layout_style"] = layout }
            let addIDs = parsed.csvValues("add-ids")
            if !addIDs.isEmpty { params["add_asset_ids"] = addIDs }
            let remIDs = parsed.csvValues("remove-ids")
            if !remIDs.isEmpty { params["remove_asset_ids"] = remIDs }
            let remNodeIDs = parsed.csvValues("remove-node-ids")
            if !remNodeIDs.isEmpty { params["remove_node_ids"] = remNodeIDs }
            if let section = parsed.first("add-section") { params["add_section"] = section }
            if let tint = parsed.first("tint") ?? parsed.first("section-tint") { params["section_tint"] = tint }
            if let note = parsed.first("add-note") { params["add_note"] = note }
            if let noteTitle = parsed.first("note-title") { params["note_title"] = noteTitle }
            if let noteStyle = parsed.first("note-style") { params["note_style"] = noteStyle }
            let out = await service.callTool(name: "patch_moodboard", arguments: params, channel: .cli)
            formatter.emitToolOutput(out, command: "patch_moodboard")

        default:
            formatter.emitError("Unknown board subcommand: \(action). Expected: list, get, export, compose, patch.")
            exit(2)
        }
    }

    private static func handleFolderCommand(
        _ subArgs: [String],
        service: CharkleExternalAgentService,
        formatter: CLIFormatter
    ) async {
        guard let action = subArgs.first else {
            printSubcommandHelp("folder")
            exit(2)
        }
        let rest = Array(subArgs.dropFirst())
        let parsed = CLIArgParser.parse(rest)
        if parsed.wantsHelp {
            printSubcommandHelp("folder")
            return
        }

        switch action {
        case "list":
            let out = await service.callTool(name: "library_overview", arguments: [:], channel: .cli)
            if out.isError {
                formatter.emitToolOutput(out, command: "library_overview")
                return
            }
            let rawText = out.content.compactMap { if case .text(let t) = $0 { return t } else { return nil } }.joined()
            if let data = rawText.data(using: .utf8),
               let dict = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let folders = dict["folders"] as? [[String: Any]] {
                formatter.emitJSON(["count": folders.count, "folders": folders]) { payload in
                    let items = (payload["folders"] as? [[String: Any]]) ?? []
                    if items.isEmpty { return "Folders (0)\n  (none)" }
                    var lines = ["Folders (\(items.count))"]
                    for f in items {
                        let id = String(((f["id"] as? String) ?? "").prefix(8))
                        let path = (f["path"] as? String) ?? ""
                        let cnt = (f["assetCount"] as? Int) ?? 0
                        lines.append("  \(id)  \(path) (\(cnt))")
                    }
                    return lines.joined(separator: "\n")
                }
            } else {
                formatter.emitToolOutput(out, command: "library_overview")
            }

        case "create":
            guard let name = parsed.first("name") ?? parsed.positionals.first, !name.isEmpty else {
                formatter.emitError("Usage: charkle folder create <name> [--parent <path-or-id>] [--color #HEX] [--symbol S]")
                exit(2)
            }
            var params: [String: Any] = ["name": name]
            if let parent = parsed.first("parent") {
                if UUID(uuidString: parent) != nil { params["parent_id"] = parent } else { params["parent_path"] = parent }
            }
            if let color = parsed.first("color") { params["color_hex"] = color }
            if let sym = parsed.first("symbol") { params["custom_symbol"] = sym }
            let out = await service.callTool(name: "create_folder", arguments: params, channel: .cli)
            formatter.emitToolOutput(out, command: "create_folder")

        case "rename":
            guard parsed.positionals.count >= 2 else {
                formatter.emitError("Usage: charkle folder rename <id-or-path> <new-name>")
                exit(2)
            }
            let target = parsed.positionals[0]
            let newName = parsed.positionals[1]
            var params: [String: Any] = ["new_name": newName]
            if UUID(uuidString: target) != nil { params["folder_id"] = target } else { params["folder_path"] = target }
            let out = await service.callTool(name: "update_folder", arguments: params, channel: .cli)
            formatter.emitToolOutput(out, command: "update_folder")

        case "move", "update":
            guard let target = parsed.first("id") ?? parsed.positionals.first, !target.isEmpty else {
                formatter.emitError("Usage: charkle folder \(action) <id-or-path> [--name N] [--parent P | --root] [--color #HEX] [--symbol S]")
                exit(2)
            }
            var params: [String: Any] = [:]
            if UUID(uuidString: target) != nil { params["folder_id"] = target } else { params["folder_path"] = target }
            if let newName = parsed.first("name") ?? parsed.first("new-name") { params["new_name"] = newName }
            if parsed.flag("root") {
                params["move_to_root"] = true
            } else if let parent = parsed.first("parent") {
                if UUID(uuidString: parent) != nil { params["parent_id"] = parent } else { params["parent_path"] = parent }
            }
            if let color = parsed.first("color") { params["color_hex"] = color }
            if let sym = parsed.first("symbol") { params["custom_symbol"] = sym }
            let out = await service.callTool(name: "update_folder", arguments: params, channel: .cli)
            formatter.emitToolOutput(out, command: "update_folder")

        default:
            formatter.emitError("Unknown folder subcommand: \(action). Expected: list, create, rename, move, update.")
            exit(2)
        }
    }

    private static func handleOrganizeCommand(
        _ subArgs: [String],
        service: CharkleExternalAgentService,
        formatter: CLIFormatter
    ) async {
        let parsed = CLIArgParser.parse(subArgs)
        var params: [String: Any] = [:]
        let ids = parsed.csvValues("ids") + parsed.positionals
        if !ids.isEmpty { params["asset_ids"] = ids }
        if let f = parsed.first("folder") {
            if UUID(uuidString: f) != nil { params["folder_id"] = f } else { params["folder_path"] = f }
        }
        if parsed.flag("inbox") { params["move_to_inbox"] = true }
        let addTags = parsed.csvValues("add-tags")
        if !addTags.isEmpty { params["add_tags"] = addTags }
        let remTags = parsed.csvValues("remove-tags")
        if !remTags.isEmpty { params["remove_tags"] = remTags }
        let dismissSuggested = parsed.csvValues("dismiss-suggested")
        if !dismissSuggested.isEmpty { params["dismiss_suggested_tags"] = dismissSuggested }
        if parsed.flag("accept-suggested") { params["accept_suggested_tags"] = true }
        if let rating = parsed.int("rating") { params["rating"] = rating }
        if let notes = parsed.first("notes") { params["notes"] = notes }
        if let title = parsed.first("title") { params["title"] = title }
        if let desc = parsed.first("ai-description") { params["ai_description"] = desc }
        if let pinned = parsed.optionalBool("pinned") { params["pinned_offline"] = pinned }

        let out = await service.callTool(name: "organize_assets", arguments: params, channel: .cli)
        formatter.emitToolOutput(out, command: "organize_assets")
    }

    private static func handleAnalyzeCommand(
        _ subArgs: [String],
        service: CharkleExternalAgentService,
        formatter: CLIFormatter
    ) async {
        let parsed = CLIArgParser.parse(subArgs)
        let ids = parsed.csvValues("ids") + parsed.positionals
        guard !ids.isEmpty else {
            formatter.emitError("Usage: charkle analyze --ids A,B [--refresh-rich]")
            exit(2)
        }
        var params: [String: Any] = ["asset_ids": ids]
        if parsed.flag("refresh-rich") { params["refresh_rich_metadata"] = true }
        let out = await service.callTool(name: "analyze_assets", arguments: params, channel: .cli)
        formatter.emitToolOutput(out, command: "analyze_assets")
    }

    private static func handleImportCommand(
        _ subArgs: [String],
        service: CharkleExternalAgentService,
        formatter: CLIFormatter
    ) async {
        let parsed = CLIArgParser.parse(subArgs)
        var params: [String: Any] = [:]
        var fileTargets: [String] = []
        var webTargets: [String] = []
        for target in parsed.positionals {
            let lower = target.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            if lower.hasPrefix("http://") || lower.hasPrefix("https://") {
                webTargets.append(target)
            } else {
                fileTargets.append(target)
            }
        }
        if fileTargets.count > 1 {
            params["file_paths"] = fileTargets
        } else if let singleFile = fileTargets.first {
            params["file_path"] = singleFile
        }
        if webTargets.count > 1 {
            params["web_urls"] = webTargets
        } else if let singleWeb = webTargets.first {
            params["web_url"] = singleWeb
        }
        if let text = parsed.first("text") { params["text"] = text }
        if let title = parsed.first("title") { params["title"] = title }
        if let notes = parsed.first("notes") { params["notes"] = notes }
        if let rating = parsed.int("rating") { params["rating"] = rating }
        if let board = parsed.first("board") { params["target_board_id"] = board }
        if let folder = parsed.first("folder") {
            if UUID(uuidString: folder) != nil { params["folder_id"] = folder } else { params["folder_path"] = folder }
        }
        let tags = parsed.csvValues("tag") + parsed.csvValues("tags")
        if !tags.isEmpty { params["tags"] = tags }

        let out = await service.callTool(name: "ingest_asset", arguments: params, channel: .cli)
        formatter.emitToolOutput(out, command: "ingest_asset")
    }

    private static func handleTrashCommand(
        _ subArgs: [String],
        service: CharkleExternalAgentService,
        formatter: CLIFormatter
    ) async {
        if subArgs.first == "list" {
            let parsed = CLIArgParser.parse(Array(subArgs.dropFirst()))
            var params: [String: Any] = ["only_trashed": true]
            if let limit = parsed.int("limit") { params["limit"] = limit }
            if let offset = parsed.int("offset") { params["offset"] = offset }
            let out = await service.callTool(name: "search_assets", arguments: params, channel: .cli)
            formatter.emitToolOutput(out, command: "search_assets")
            return
        }

        let parsed = CLIArgParser.parse(subArgs)
        let ids = parsed.csvValues("ids") + parsed.positionals
        var params: [String: Any] = [
            "trashed": !parsed.flag("restore")
        ]
        if !ids.isEmpty { params["asset_ids"] = ids }
        let out = await service.callTool(name: "trash_assets", arguments: params, channel: .cli)
        formatter.emitToolOutput(out, command: "trash_assets")
    }

    // MARK: - Non-Blocking Stdio MCP Server Loop (NDJSON + Content-Length Framing)

    private static func runMCPStdioLoop(service: CharkleExternalAgentService) async {
        setvbuf(stdout, nil, _IONBF, 0)
        // Prevent SIGPIPE from crashing if the MCP client disconnects mid-write.
        signal(SIGPIPE, SIG_IGN)

        let stdinStream = makeStdinChunkStream()
        var parser = MCPStdioFrameParser()

        for await chunk in stdinStream {
            for event in parser.append(chunk) {
                await dispatchMCPEvent(event, service: service)
            }
        }
        for event in parser.finishEOF() {
            await dispatchMCPEvent(event, service: service)
        }
    }

    private static func dispatchMCPEvent(
        _ event: MCPStdioFrameParser.Event,
        service: CharkleExternalAgentService
    ) async {
        switch event {
        case .message(let payload, let framing):
            if let reply = await service.handleJSONRPC(payload) {
                writeStdout(MCPStdioFrameParser.encode(reply, framing: framing))
            }
        case .invalidFrame(let reason, let framing):
            let errObj: [String: Any] = [
                "jsonrpc": "2.0",
                "id": NSNull(),
                "error": ["code": -32700, "message": "Parse error: \(reason)"]
            ]
            if let data = try? JSONSerialization.data(withJSONObject: errObj, options: [.sortedKeys]) {
                writeStdout(MCPStdioFrameParser.encode(data, framing: framing))
            }
        }
    }

    /// Reads blocking stdin off the Swift cooperative thread pool via a dedicated background DispatchQueue.
    private static func makeStdinChunkStream() -> AsyncStream<Data> {
        AsyncStream { continuation in
            let queue = DispatchQueue(label: "com.charkle.mcp.stdin", qos: .userInitiated)
            queue.async {
                var scratch = [UInt8](repeating: 0, count: 65_536)
                while true {
                    let n = Darwin.read(STDIN_FILENO, &scratch, scratch.count)
                    if n > 0 {
                        continuation.yield(Data(scratch[0..<n]))
                    } else if n == 0 {
                        break // EOF
                    } else if errno == EINTR {
                        continue
                    } else {
                        break
                    }
                }
                continuation.finish()
            }
        }
    }

    private static func writeStdout(_ data: Data) {
        data.withUnsafeBytes { raw in
            guard let base = raw.baseAddress else { return }
            var written = 0
            while written < data.count {
                let n = Darwin.write(STDOUT_FILENO, base.advanced(by: written), data.count - written)
                if n > 0 {
                    written += n
                } else if n < 0 && errno == EINTR {
                    continue
                } else {
                    break
                }
            }
        }
    }

    private static func writeStderr(_ message: String) {
        FileHandle.standardError.write(Data(message.utf8))
    }

    private static func inspectLocalBinSymlink() -> [String: Any] {
        let linkURL = URL(fileURLWithPath: NSHomeDirectory()).appending(path: ".local/bin/charkle")
        let fm = FileManager.default
        let currentExec = Bundle.main.executableURL?.resolvingSymlinksInPath().path
            ?? URL(fileURLWithPath: CommandLine.arguments[0]).resolvingSymlinksInPath().path
        if let dest = try? fm.destinationOfSymbolicLink(atPath: linkURL.path) {
            let destURL = dest.hasPrefix("/")
                ? URL(fileURLWithPath: dest)
                : URL(fileURLWithPath: dest, relativeTo: linkURL.deletingLastPathComponent())
            let resolvedDest = destURL.resolvingSymlinksInPath().path
            let executable = fm.isExecutableFile(atPath: linkURL.path)
            let status: String
            if !executable {
                status = "broken"
            } else if resolvedDest == currentExec {
                status = "linked"
            } else {
                status = "stale"
            }
            return [
                "status": status,
                "linkPath": linkURL.path,
                "targetPath": dest,
                "currentExecutable": currentExec
            ]
        }
        if fm.isExecutableFile(atPath: linkURL.path) {
            return ["status": "linked", "linkPath": linkURL.path, "currentExecutable": currentExec]
        }
        return ["status": "notLinked", "linkPath": linkURL.path, "currentExecutable": currentExec]
    }

    // MARK: - Help Documentation

    private static func printGlobalHelp() {
        print("""
        charkle \(version) — Charkle Visual Reference Library CLI & Native MCP Server

        USAGE:
          charkle <command> [options]

        CORE & DIAGNOSTICS:
          mcp                 Run stdio MCP JSON-RPC 2.0 server (20 safe tools, resources, prompts)
          doctor              Diagnose library DB, permissions, MCP surface, and CLI symlink
          status              Show library overview & external agent access status
          overview            Show folders, smart folders, tags, counts, and cache stats

        DISCOVERY & INSPECTION:
          search [query]      Search & paginate assets (folder/subfolders, tags, color, kind, shape, sort)
          semantic <query>    Run hybrid semantic + visual search
          similar <uuid>      Find visually similar assets (Vision FeaturePrint + CIELAB)
          jump <query>        Unified fuzzy lookup across folders, moodboards, tags, and assets
          inbox               List untriaged Inbox assets (pass --suggest for folder recommendations)
          asset <uuid>        Inspect full asset metadata (EXIF, AI prompts, social/GitHub, paths)
          contact-sheet       Render numbered visual Contact Sheet JPEG (#01..#16, supports --offset)

        MOODBOARDS & ORGANIZATION (Safe Write — Permanent Delete Always Disabled):
          board <subcmd>      list | get | export | compose | patch
          folder <subcmd>     list | create | rename | move | update
          organize            Batch-update assets (folder, tags, rating, notes, title, AI desc)
          analyze             Run local Vision colors/OCR/EXIF analysis (--refresh-rich for URLs)
          import <target>...  Import local files/folders, web/social/GitHub URLs, or --text
          trash               List Trash (`trash list`) or soft-move/restore (`trash --ids A,B [--restore]`)

        SHELL UTILITIES:
          completions <sh>    Output shell completion script for zsh, bash, or fish

        GLOBAL OPTIONS:
          --library-dir <dir> Override Charkle Application Support directory
          -j, --json          Force pretty JSON output (auto-enabled when piped)
          --compact           Force compact single-line JSON output (ideal for jq)
          --no-color          Disable ANSI colors (also honors NO_COLOR)
          -h, --help          Show help (run `charkle <command> --help` for subcommand details)
          -v, --version       Print version
        """)
    }

    private static func printSubcommandHelp(_ command: String) {
        let text: String = switch command {
        case "mcp":
            """
            USAGE:
              charkle mcp [--library-dir <dir>]

            Runs Charkle's native stdio MCP JSON-RPC 2.0 server (NDJSON & Content-Length framing).
            Exposes 20 safe tools (12 read + 8 write, never permanent delete), 4 static resources,
            2 dynamic resource templates, and 4 studio workflow prompts.
            """
        case "doctor":
            """
            USAGE:
              charkle doctor [--json] [--library-dir <dir>]

            Diagnoses library SQLite health, external agent permissions, MCP capabilities, and ~/.local/bin/charkle symlink status.
            """
        case "status":
            """
            USAGE:
              charkle status [--json]

            Shows active external agent permissions and, when CLI access is enabled, the full library overview.
            """
        case "overview":
            """
            USAGE:
              charkle overview [--json]

            Displays folder hierarchy, smart folders, top tags, asset counts, and local cache statistics.
            """
        case "semantic":
            """
            USAGE:
              charkle semantic <query> [--folder <path|id>] [--subfolders] [--tag <t1,t2>] [--kind <k1,k2>] [--color <#HEX>] [--min-rating <0-5>] [-n, --limit <1-50>]

            Runs hybrid semantic + visual + keyword search across the library.
            """
        case "similar":
            """
            USAGE:
              charkle similar <asset-uuid> [-n, --limit <1-32>] [--contact-sheet]

            Finds visually similar assets using Vision FeaturePrint, CIELAB palette proximity, and shared tags.
            """
        case "jump":
            """
            USAGE:
              charkle jump <query> [-n, --limit <1-50>]

            Runs unified fuzzy lookup across folders, moodboards, tags, and assets.
            """
        case "inbox":
            """
            USAGE:
              charkle inbox [--kind <k1,k2>] [--sort <order>] [--offset <N>] [-n, --limit <1-100>] [--suggest]

            Lists untriaged Inbox assets. Pass --suggest to chain folder recommendations onto the fetched batch.
            """
        case "asset":
            """
            USAGE:
              charkle asset <asset-uuid> [--json]

            Inspects full asset metadata including EXIF, AI generation prompts, social/GitHub details, and local file paths.
            """
        case "analyze":
            """
            USAGE:
              charkle analyze --ids <A,B> [--refresh-rich]

            Runs local Apple Vision analysis (colors, OCR, FeaturePrint) and EXIF extraction on up to 20 assets.
            """
        case "search":
            """
            USAGE:
              charkle search [query] [options]

            OPTIONS:
              -f, --folder <path|id>    Filter by folder path or UUID
              --subfolders              Include nested descendant folders
              --smart-folder <name|id>  Evaluate a saved Smart Folder rule
              -t, --tag <t1,t2>         Require tags (repeatable or comma-separated)
              --kind <k1,k2>            Media kinds: image,animatedImage,video,webBookmark,document,designFile,audio,model3D
              --shape <shape>           Aspect shape: landscape, portrait, square, ultrawide
              --color <#HEX>            Dominant CIELAB color filter
              --color-tolerance <N>     DeltaE tolerance (default 28)
              --min-rating <0-5>        Minimum star rating
              --sort <order>            newest, oldest, name_asc, rating_desc, file_size_desc, relevance
              --inbox                   Only Inbox assets
              --untagged                Only untagged assets
              --pinned                  Only offline-pinned assets
              --trashed                 Only Trash assets
              --include-trashed         Include trashed assets
              --recent-days <N>         Added in the last N days
              --offset <N>              Pagination offset (default 0)
              -n, --limit <1-100>       Max results (default 30)
            """
        case "board":
            """
            USAGE:
              charkle board list
              charkle board get <id-or-title>
              charkle board export <id-or-title> [--out <file.png>] [--width 1440] [--dark]
              charkle board compose [--title T] [--subtitle S] [--ids A,B | --prompt P] [--folder P] [--note N] [--layout magazine|balanced|compact] [--freeform]
              charkle board patch <id-or-title> [--new-title T] [--subtitle S] [--add-ids A,B] [--remove-ids C] [--remove-node-ids N] [--add-section S] [--tint T] [--add-note N] [--note-title NT] [--note-style paper|ink|warm|sage|slate] [--freeform[=true|false]] [--layout magazine|balanced|compact]
            """
        case "folder":
            """
            USAGE:
              charkle folder list
              charkle folder create <name> [--parent <path|id>] [--color #HEX] [--symbol <sf-symbol>]
              charkle folder rename <id-or-path> <new-name>
              charkle folder move <id-or-path> (--parent <path|id> | --root)
              charkle folder update <id-or-path> [--name N] [--parent P | --root] [--color #HEX] [--symbol S]
            """
        case "organize":
            """
            USAGE:
              charkle organize --ids A,B [options]

            OPTIONS:
              -f, --folder <path|id>    Move to folder
              --inbox                   Move back to Inbox
              --add-tags <x,y>          Add tags
              --remove-tags <z>         Remove tags
              --accept-suggested        Accept AI suggested tags
              --dismiss-suggested <x>   Dismiss AI suggested tags
              --rating <0-5>            Set star rating
              --title <text>            Set title
              --notes <text>            Set notes
              --ai-description <text>   Set/overwrite AI visual description
              --pinned[=true|false]     Pin or unpin originals offline
            """
        case "contact-sheet":
            """
            USAGE:
              charkle contact-sheet [query] [--folder P] [--subfolders] [--ids A,B] [--inbox] [--untagged] [--color #HEX] [--offset N] [--limit 16] [--width 1280] --out <file.jpg>
            """
        case "import":
            """
            USAGE:
              charkle import <file-or-dir-or-url>... [--folder P] [--tags x,y] [--title T] [--notes S] [--rating N] [--board <uuid>]
              charkle import --text "<snippet>" [--title T] [--folder P] [--tags x,y]
            """
        case "trash":
            """
            USAGE:
              charkle trash list [--limit N] [--offset N]
              charkle trash --ids A,B [--restore]
            """
        case "completions":
            """
            USAGE:
              charkle completions <zsh|bash|fish>

            Example (zsh):
              mkdir -p ~/.zsh/completions
              charkle completions zsh > ~/.zsh/completions/_charkle
            """
        default:
            "Run `charkle --help` for full usage of `\(command)`."
        }
        print(text)
    }
}
