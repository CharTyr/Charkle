import Foundation
import Vision

/// Grounded External Agent Service powering BOTH:
/// 1. Native Swift **MCP Server (`charkle mcp`)** over stdio JSON-RPC 2.0 (single + batch, tools, resources, templates, prompts)
/// 2. Native Swift **CLI (`charkle <command>`)** for scripts, skills, and terminal workflows
///
/// Built directly on `CharkleAgentTools` + `LiveCharkleEngine`, enforcing `ExternalAgentConfig`
/// dynamically on every invocation and posting live refresh notifications to `Charkle.app`.
public nonisolated struct CharkleExternalAgentService: Sendable {
    public enum ToolContent: Sendable {
        case text(String)
        case image(mimeType: String, data: Data)

        func mcpObject() -> [String: Any] {
            switch self {
            case .text(let value):
                return ["type": "text", "text": value]
            case .image(let mimeType, let data):
                return ["type": "image", "mimeType": mimeType, "data": data.base64EncodedString()]
            }
        }
    }

    public struct ToolOutput: Sendable {
        public let content: [ToolContent]
        public let isError: Bool

        public init(content: [ToolContent], isError: Bool = false) {
            self.content = content
            self.isError = isError
        }

        public static func json(_ object: Any, isError: Bool = false) -> ToolOutput {
            let text = CharkleExternalAgentService.encodeCompactJSON(object)
            return ToolOutput(content: [.text(text)], isError: isError)
        }

        public static func error(_ message: String) -> ToolOutput {
            ToolOutput(content: [.text(message)], isError: true)
        }
    }

    public let engine: LiveCharkleEngine
    public let tools: CharkleAgentTools
    public let configDirectory: URL
    public let notifyOnWrite: Bool

    public init(
        engine: LiveCharkleEngine,
        configDirectory: URL = ExternalAgentConfigStore.defaultDirectory(),
        notifyOnWrite: Bool = true
    ) {
        self.engine = engine
        self.tools = CharkleAgentTools(database: engine.database, media: engine.media)
        self.configDirectory = configDirectory
        self.notifyOnWrite = notifyOnWrite
    }

    public func currentPolicy() -> ExternalAgentConfig {
        ExternalAgentConfigStore.load(in: configDirectory)
    }

    // MARK: - Diagnostics (for `charkle doctor` & Settings Self-Check)

    public func runDiagnostics() async -> [String: Any] {
        let policy = currentPolicy()
        let dbURL = configDirectory.appending(path: "Library.sqlite3")
        let dbExists = FileManager.default.fileExists(atPath: dbURL.path)
        let dbSizeBytes = (try? FileManager.default.attributesOfItem(atPath: dbURL.path)[.size] as? Int64) ?? 0

        var dbHealthy = false
        var dbError: String?
        var totalAssets = 0
        var inboxCount = 0
        var folderCount = 0
        var smartFolderCount = 0
        var boardCount = 0
        var syncMode = DriveTransportMode.localOnly.rawValue
        var aiProvider = CloudAIProviderKind.disabled.rawValue
        var cacheStatsDict: [String: Any] = [:]

        do {
            let overview = try await tools.libraryOverview()
            let smartFolders = try await engine.fetchSmartFolders()
            let syncCfg = await engine.syncConfig()
            let aiCfg = await engine.aiConfig()
            let cache = await engine.cacheStats()

            dbHealthy = true
            totalAssets = overview.totalAssets
            inboxCount = overview.inboxCount
            folderCount = overview.folders.count
            smartFolderCount = smartFolders.count
            boardCount = overview.boardCount
            syncMode = syncCfg.mode.rawValue
            aiProvider = aiCfg.provider.rawValue
            cacheStatsDict = [
                "thumbnailBytes": cache.thumbnailBytes,
                "originalCacheBytes": cache.originalCacheBytes,
                "pinnedOfflineBytes": cache.pinnedOfflineBytes,
                "budgetBytes": cache.budgetBytes,
                "cachedOriginalCount": cache.cachedOriginalCount,
                "pinnedAssetCount": cache.pinnedAssetCount
            ]
        } catch {
            dbError = error.localizedDescription
        }

        let toolDefs = Self.mcpToolDefinitions()
        let readTools = toolDefs.filter { (($0["annotations"] as? [String: Any])?["readOnlyHint"] as? Bool) == true }.count
        let writeTools = toolDefs.count - readTools

        var report: [String: Any] = [
            "ok": dbHealthy,
            "serverVersion": Self.serverVersion,
            "supportedProtocolVersions": Self.supportedProtocolVersions,
            "policy": [
                "mcpEnabled": policy.mcpEnabled,
                "cliEnabled": policy.cliEnabled,
                "accessLevel": policy.accessLevel.rawValue,
                "mcpCanWrite": policy.allowsWrite(for: .mcp),
                "cliCanWrite": policy.allowsWrite(for: .cli)
            ],
            "capabilities": [
                "toolCount": toolDefs.count,
                "readToolCount": readTools,
                "writeToolCount": writeTools,
                "resourceCount": Self.mcpResourceDefinitions().count,
                "resourceTemplateCount": Self.mcpResourceTemplateDefinitions().count,
                "promptCount": Self.mcpPromptDefinitions().count,
                "permanentDeleteAllowed": false
            ],
            "database": [
                "healthy": dbHealthy,
                "exists": dbExists,
                "sizeBytes": dbSizeBytes
            ],
            "library": [
                "totalAssets": totalAssets,
                "inboxCount": inboxCount,
                "folderCount": folderCount,
                "smartFolderCount": smartFolderCount,
                "boardCount": boardCount
            ],
            "syncMode": syncMode,
            "aiProvider": aiProvider,
            "cache": cacheStatsDict
        ]
        if let dbError {
            report["error"] = dbError
        }
        return report
    }

    // MARK: - MCP JSON-RPC 2.0 Dispatcher (Single & Batch)

    /// Handles a single JSON-RPC 2.0 request/notification or batch array payload and returns
    /// serialized JSON response bytes, or `nil` when all items are notifications expecting no reply.
    public func handleJSONRPC(_ payload: Data) async -> Data? {
        guard let parsed = try? JSONSerialization.jsonObject(with: payload) else {
            return serializeJSON(makeErrorObject(id: nil, code: -32700, message: "Parse error: invalid JSON"))
        }

        if let batch = parsed as? [Any] {
            guard !batch.isEmpty else {
                return serializeJSON(makeErrorObject(id: nil, code: -32600, message: "Invalid Request: empty JSON-RPC batch"))
            }
            var responses: [[String: Any]] = []
            for item in batch {
                if let obj = item as? [String: Any] {
                    if let resp = await handleSingleJSONRPCObject(obj) {
                        responses.append(resp)
                    }
                } else {
                    responses.append(makeErrorObject(id: nil, code: -32600, message: "Invalid Request: batch element must be an object"))
                }
            }
            guard !responses.isEmpty else { return nil }
            return serializeJSON(responses)
        }

        guard let obj = parsed as? [String: Any] else {
            return serializeJSON(makeErrorObject(id: nil, code: -32600, message: "Invalid Request: expected JSON object or array"))
        }
        guard let resp = await handleSingleJSONRPCObject(obj) else { return nil }
        return serializeJSON(resp)
    }

    private func handleSingleJSONRPCObject(_ obj: [String: Any]) async -> [String: Any]? {
        let hasID = obj.keys.contains("id")
        let id = obj["id"]
        let isNotification = !hasID
        guard let method = obj["method"] as? String else {
            return isNotification ? nil : makeErrorObject(id: id, code: -32600, message: "Invalid Request: missing method")
        }
        let params = obj["params"] as? [String: Any] ?? [:]
        let response = await dispatchJSONRPCMethod(method, params: params, id: id)
        // JSON-RPC 2.0 Section 4.1: Servers MUST NOT reply to notifications (requests without `id`).
        return isNotification ? nil : response
    }

    private func dispatchJSONRPCMethod(_ method: String, params: [String: Any], id: Any?) async -> [String: Any]? {
        switch method {
        case "initialize":
            let policy = currentPolicy()
            guard policy.allowsRead(for: .mcp) else {
                return makeErrorObject(id: id, code: -32001, message: "Charkle MCP service is disabled in Settings.")
            }
            let negotiatedVersion = Self.negotiateProtocolVersion(params["protocolVersion"] as? String)
            let result: [String: Any] = [
                "protocolVersion": negotiatedVersion,
                "capabilities": [
                    "tools": ["listChanged": false],
                    "resources": ["subscribe": false, "listChanged": false],
                    "prompts": ["listChanged": false],
                    "logging": [:]
                ],
                "serverInfo": [
                    "name": "charkle",
                    "version": Self.serverVersion
                ],
                "instructions": "Charkle visual reference library & moodboard studio. Low-token workflow: (1) Call `library_overview` first to read compact folder semantic profiles (`recursiveAssetCount`, `topTags`, `palette`), aspect mix, and boards. (2) Recall + inspect visually in 1 call via `semantic_search` (bilingual EN↔ZH, CIELAB `tone`, multi-direction `queries[]`, `seed_asset_ids`, `unlike_asset_ids` repulsion) or `search_assets` with `diversify:true` and `render_contact_sheet:true` (auto ultra-lean `visual` manifest); use `facets` to narrow large result sets. (3) 8-char short ID prefixes work in all tools; batch-call `get_asset(asset_ids:[...])` only on finalists. Permanent deletion is never permitted."
            ]
            return makeResultObject(id: id, result: result)

        case "notifications/initialized", "notifications/cancelled", "notifications/roots/list_changed", "initialized":
            return nil

        case "ping":
            return makeResultObject(id: id, result: [:])

        case "logging/setLevel":
            return makeResultObject(id: id, result: [:])

        case "tools/list":
            let policy = currentPolicy()
            guard policy.allowsRead(for: .mcp) else {
                return makeErrorObject(id: id, code: -32001, message: "Charkle MCP service is disabled in Settings.")
            }
            return makeResultObject(id: id, result: ["tools": Self.mcpToolDefinitions()])

        case "tools/call":
            let policy = currentPolicy()
            guard policy.allowsRead(for: .mcp) else {
                return makeErrorObject(id: id, code: -32001, message: "Charkle MCP service is disabled in Settings.")
            }
            guard let name = params["name"] as? String, !name.isEmpty else {
                return makeErrorObject(id: id, code: -32602, message: "Invalid params: missing tool name")
            }
            guard Self.knownToolNames.contains(name) else {
                return makeErrorObject(id: id, code: -32602, message: "Unknown tool: \(name)")
            }
            let args = params["arguments"] as? [String: Any] ?? [:]
            let output = await callTool(name: name, arguments: args, channel: .mcp)
            let result: [String: Any] = [
                "content": output.content.map { $0.mcpObject() },
                "isError": output.isError
            ]
            return makeResultObject(id: id, result: result)

        case "resources/list":
            let policy = currentPolicy()
            guard policy.allowsRead(for: .mcp) else {
                return makeErrorObject(id: id, code: -32001, message: "Charkle MCP service is disabled in Settings.")
            }
            return makeResultObject(id: id, result: ["resources": Self.mcpResourceDefinitions()])

        case "resources/templates/list":
            let policy = currentPolicy()
            guard policy.allowsRead(for: .mcp) else {
                return makeErrorObject(id: id, code: -32001, message: "Charkle MCP service is disabled in Settings.")
            }
            return makeResultObject(id: id, result: ["resourceTemplates": Self.mcpResourceTemplateDefinitions()])

        case "resources/read":
            guard let uri = params["uri"] as? String else {
                return makeErrorObject(id: id, code: -32602, message: "Missing resource uri")
            }
            let policy = currentPolicy()
            guard policy.allowsRead(for: .mcp) else {
                return makeErrorObject(id: id, code: -32001, message: "Charkle MCP service is disabled in Settings.")
            }
            return await handleReadResource(uri: uri, id: id)

        case "prompts/list":
            let policy = currentPolicy()
            guard policy.allowsRead(for: .mcp) else {
                return makeErrorObject(id: id, code: -32001, message: "Charkle MCP service is disabled in Settings.")
            }
            return makeResultObject(id: id, result: ["prompts": Self.mcpPromptDefinitions()])

        case "prompts/get":
            let policy = currentPolicy()
            guard policy.allowsRead(for: .mcp) else {
                return makeErrorObject(id: id, code: -32001, message: "Charkle MCP service is disabled in Settings.")
            }
            guard let name = params["name"] as? String else {
                return makeErrorObject(id: id, code: -32602, message: "Invalid params: missing prompt name")
            }
            let promptArgs = params["arguments"] as? [String: Any] ?? [:]
            guard let rendered = Self.renderPrompt(name: name, arguments: promptArgs) else {
                return makeErrorObject(id: id, code: -32602, message: "Unknown prompt: \(name)")
            }
            return makeResultObject(id: id, result: rendered)

        default:
            return makeErrorObject(id: id, code: -32601, message: "Method not found: \(method)")
        }
    }

    private func handleReadResource(uri: String, id: Any?) async -> [String: Any] {
        func textOutput(_ out: ToolOutput) -> [String: Any] {
            if out.isError {
                let errText = out.content.compactMap { if case .text(let t) = $0 { return t } else { return nil } }.joined(separator: "\n")
                return makeErrorObject(id: id, code: -32002, message: errText.isEmpty ? "Failed to read resource: \(uri)" : errText)
            }
            let text = out.content.compactMap { if case .text(let t) = $0 { return t } else { return nil } }.joined(separator: "\n")
            return makeResultObject(id: id, result: [
                "contents": [["uri": uri, "mimeType": "application/json", "text": text]]
            ])
        }

        if uri == "charkle://library/overview" {
            return textOutput(await callTool(name: "library_overview", arguments: [:], channel: .mcp))
        }
        if uri == "charkle://boards" {
            return textOutput(await callTool(name: "list_boards", arguments: [:], channel: .mcp))
        }
        if uri == "charkle://folders" {
            do {
                let folders = try await engine.fetchFolders()
                let activeAssets = try await engine.fetchAssets(matching: FilterCriteria(includeTrashed: false))
                let paths = Self.buildFolderPaths(folders)
                let profiles = Self.buildFolderProfiles(folders: folders, assets: activeAssets)
                let items: [[String: Any]] = FolderHierarchyNode.flattened(from: folders).map { node in
                    var entry: [String: Any] = [
                        "id": node.folder.id.uuidString,
                        "name": node.folder.name,
                        "path": paths[node.folder.id] ?? node.folder.name,
                        "depth": node.depth,
                        "assetCount": profiles[node.folder.id]?.directCount ?? node.folder.assetCount
                    ]
                    if let pid = node.folder.parentID { entry["parentID"] = pid.uuidString }
                    if let p = profiles[node.folder.id] {
                        if p.recursiveCount > p.directCount { entry["recursiveAssetCount"] = p.recursiveCount }
                        if !p.topTags.isEmpty { entry["topTags"] = p.topTags }
                        if !p.palette.isEmpty { entry["palette"] = p.palette }
                        if let asp = p.dominantAspect { entry["dominantAspect"] = asp }
                    }
                    if let hex = node.folder.colorHex, !hex.isEmpty { entry["colorHex"] = hex }
                    if let sym = node.folder.customSymbol, !sym.isEmpty { entry["customSymbol"] = sym }
                    return entry
                }
                return textOutput(.json(["count": items.count, "folders": items]))
            } catch {
                return makeErrorObject(id: id, code: -32603, message: error.localizedDescription)
            }
        }
        if uri == "charkle://smart-folders" {
            do {
                let smartFolders = try await engine.fetchSmartFolders()
                let activeAssets = try await engine.fetchAssets(matching: FilterCriteria(includeTrashed: false))
                let items: [[String: Any]] = smartFolders.map { sf in
                    [
                        "id": sf.id.uuidString,
                        "name": sf.name,
                        "colorHex": sf.colorHex ?? "",
                        "matchMode": sf.rule.matchMode.rawValue,
                        "tags": sf.rule.tags,
                        "descriptionQuery": sf.rule.descriptionQuery,
                        "colorHexes": sf.rule.colorHexes,
                        "mediaKinds": sf.rule.mediaKinds.map(\.rawValue),
                        "minRating": sf.rule.minRating,
                        "matchCount": activeAssets.filter { sf.rule.matches($0) }.count
                    ]
                }
                return textOutput(.json(["count": items.count, "smartFolders": items]))
            } catch {
                return makeErrorObject(id: id, code: -32603, message: error.localizedDescription)
            }
        }
        if uri.hasPrefix("charkle://assets/") {
            let assetID = String(uri.dropFirst("charkle://assets/".count))
            return textOutput(await callTool(name: "get_asset", arguments: ["asset_id": assetID], channel: .mcp))
        }
        if uri.hasPrefix("charkle://boards/") {
            let boardID = String(uri.dropFirst("charkle://boards/".count))
            return textOutput(await callTool(name: "get_board_context", arguments: ["board_id": boardID], channel: .mcp))
        }
        return makeErrorObject(id: id, code: -32002, message: "Unknown resource URI: \(uri)")
    }

    // MARK: - Unified Grounded Tool Execution (MCP + CLI)

    private static let knownToolNames: Set<String> = Set(
        mcpToolDefinitions().compactMap { $0["name"] as? String }
    )

    private static let writeToolNames: Set<String> = [
        "organize_assets",
        "create_folder",
        "update_folder",
        "ingest_asset",
        "compose_moodboard",
        "patch_moodboard",
        "trash_assets",
        "analyze_assets"
    ]

    public func callTool(
        name: String,
        arguments args: [String: Any],
        channel: ExternalAgentChannel = .mcp
    ) async -> ToolOutput {
        let policy = currentPolicy()
        guard policy.allowsRead(for: channel) else {
            switch channel {
            case .mcp:
                return .error("MCP 服务已在 Charkle「设置 → 外部 Agent」中关闭，请先开启「启用 MCP 服务」后再试。")
            case .cli:
                return .error("CLI 命令行服务已在 Charkle「设置 → 外部 Agent」中关闭，请先开启「启用 CLI 命令行服务」后再试。")
            }
        }
        if Self.writeToolNames.contains(name) && !policy.allowsWrite(for: channel) {
            return .error("当前 Charkle 外部 Agent 权限为「仅只读检索与导出」，无法执行写入操作「\(name)」。请在 Charkle「设置 → 外部 Agent」中切换为「允许整理与生成情绪板」。")
        }

        do {
            switch name {
            // Read tools (12)
            case "library_overview":
                return try await handleLibraryOverview(args, policy: policy, channel: channel)
            case "search_assets":
                return try await handleSearchAssets(args, policy: policy, channel: channel)
            case "list_inbox":
                return try await handleListInbox(args, policy: policy, channel: channel)
            case "get_asset":
                return try await handleGetAsset(args)
            case "render_contact_sheet":
                return try await handleRenderContactSheet(args, policy: policy, channel: channel)
            case "find_similar_assets":
                return try await handleFindSimilarAssets(args, policy: policy, channel: channel)
            case "semantic_search":
                return try await handleSemanticSearch(args, policy: policy, channel: channel)
            case "quick_jump":
                return try await handleQuickJump(args)
            case "suggest_folder":
                return try await handleSuggestFolder(args)
            case "list_boards":
                return try await handleListBoards()
            case "get_board_context":
                return try await handleGetBoardContext(args)
            case "export_board_image":
                return try await handleExportBoardImage(args, policy: policy, channel: channel)

            // Safe write tools (8)
            case "organize_assets":
                return try await handleOrganizeAssets(args)
            case "create_folder":
                return try await handleCreateFolder(args)
            case "update_folder":
                return try await handleUpdateFolder(args)
            case "ingest_asset":
                return try await handleIngestAsset(args)
            case "compose_moodboard":
                return try await handleComposeMoodboard(args)
            case "patch_moodboard":
                return try await handlePatchMoodboard(args)
            case "trash_assets":
                return try await handleTrashAssets(args)
            case "analyze_assets":
                return try await handleAnalyzeAssets(args)

            default:
                return .error("Unknown Charkle tool: \(name)")
            }
        } catch {
            return .error("Tool \(name) failed: \(error.localizedDescription)")
        }
    }

    // MARK: - Read Tool Handlers

    private func handleLibraryOverview(
        _ args: [String: Any],
        policy: ExternalAgentConfig,
        channel: ExternalAgentChannel
    ) async throws -> ToolOutput {
        let compact = Self.boolArg(args["compact"]) ?? true
        let includeProfiles = Self.boolArg(args["include_folder_profiles"]) ?? true
        let includeBoards = Self.boolArg(args["include_boards"]) ?? true
        let topTagsLimit = max(5, min(80, Self.intArg(args["top_tags_limit"]) ?? 30))

        let activeAssets = try await engine.fetchAssets(matching: FilterCriteria(includeTrashed: false))
        let trashedAssets = try await engine.fetchAssets(matching: FilterCriteria(onlyTrashed: true))
        let foldersRaw = try await engine.fetchFolders()
        let smartFolders = try await engine.fetchSmartFolders()
        let boards = try await engine.fetchBoards()
        let syncCfg = await engine.syncConfig()
        let aiCfg = await engine.aiConfig()

        let folderPathByID = Self.buildFolderPaths(foldersRaw)
        let folderProfiles = Self.buildFolderProfiles(folders: foldersRaw, assets: activeAssets)

        var inboxCount = 0
        var untaggedCount = 0
        var ratedCount = 0
        var aiDescribedCount = 0
        var mediaKindCounts: [String: Int] = [:]
        var aspectShapeCounts: [String: Int] = [:]
        var globalTagCounts: [String: Int] = [:]

        for asset in activeAssets {
            if asset.folderID == nil { inboxCount += 1 }
            if asset.tags.isEmpty { untaggedCount += 1 }
            if asset.rating > 0 { ratedCount += 1 }
            if let d = asset.aiDescription, !d.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                aiDescribedCount += 1
            }
            mediaKindCounts[asset.mediaKind.rawValue, default: 0] += 1
            aspectShapeCounts[asset.aspectShape.rawValue, default: 0] += 1
            for tag in asset.tags {
                globalTagCounts[tag, default: 0] += 1
            }
        }

        let sortedFolders = foldersRaw.sorted {
            (folderPathByID[$0.id] ?? $0.name).localizedStandardCompare(folderPathByID[$1.id] ?? $1.name) == .orderedAscending
        }

        let folderPayloads: [[String: Any]] = sortedFolders.map { folder in
            let profile = folderProfiles[folder.id]
            let fullID = folder.id.uuidString
            var dict: [String: Any] = [
                "id": compact ? String(fullID.prefix(8)) : fullID,
                "path": folderPathByID[folder.id] ?? folder.name,
                "assetCount": profile?.directCount ?? folder.assetCount
            ]
            if !compact {
                dict["name"] = folder.name
                if let pid = folder.parentID { dict["parentID"] = pid.uuidString }
            }
            if let profile {
                if profile.recursiveCount > profile.directCount {
                    dict["recursiveAssetCount"] = profile.recursiveCount
                }
                if includeProfiles {
                    if !profile.topTags.isEmpty { dict["topTags"] = profile.topTags }
                    if !profile.palette.isEmpty { dict["palette"] = profile.palette }
                    if let asp = profile.dominantAspect { dict["dominantAspect"] = asp }
                }
            }
            if let hex = folder.colorHex, !hex.isEmpty { dict["colorHex"] = hex }
            if let sym = folder.customSymbol, !sym.isEmpty { dict["customSymbol"] = sym }
            return dict
        }

        let smartFolderPayloads: [[String: Any]] = smartFolders.map { sf in
            var dict: [String: Any] = [
                "id": compact ? String(sf.id.uuidString.prefix(8)) : sf.id.uuidString,
                "name": sf.name,
                "matchCount": activeAssets.filter { sf.rule.matches($0) }.count
            ]
            if let hex = sf.colorHex, !hex.isEmpty { dict["colorHex"] = hex }
            return dict
        }

        let topTags = globalTagCounts
            .sorted { lhs, rhs in
                if lhs.value != rhs.value { return lhs.value > rhs.value }
                return lhs.key.localizedStandardCompare(rhs.key) == .orderedAscending
            }
            .prefix(topTagsLimit)
            .map { ["name": $0.key, "count": $0.value] as [String: Any] }

        var payload: [String: Any] = [
            "totalAssets": activeAssets.count,
            "inboxCount": inboxCount,
            "untaggedCount": untaggedCount,
            "trashedCount": trashedAssets.count,
            "ratedCount": ratedCount,
            "aiDescribedCount": aiDescribedCount,
            "boardCount": boards.count,
            "mcpEnabled": policy.mcpEnabled,
            "cliEnabled": policy.cliEnabled,
            "accessLevel": policy.accessLevel.rawValue,
            "canWrite": policy.allowsWrite(for: channel),
            "syncMode": syncCfg.mode.rawValue,
            "aiConfigured": aiCfg.provider != .disabled,
            "mediaKindCounts": mediaKindCounts,
            "aspectShapeCounts": aspectShapeCounts,
            "folders": folderPayloads,
            "smartFolders": smartFolderPayloads,
            "topTags": topTags
        ]

        if !compact {
            let cache = await engine.cacheStats()
            payload["cache"] = [
                "thumbnailBytes": cache.thumbnailBytes,
                "originalCacheBytes": cache.originalCacheBytes,
                "pinnedOfflineBytes": cache.pinnedOfflineBytes,
                "budgetBytes": cache.budgetBytes,
                "cachedOriginalCount": cache.cachedOriginalCount,
                "pinnedAssetCount": cache.pinnedAssetCount
            ]
        }

        if includeBoards && !boards.isEmpty {
            payload["boards"] = boards.prefix(12).map { b -> [String: Any] in
                let bid = b.id.uuidString
                var entry: [String: Any] = [
                    "id": compact ? String(bid.prefix(8)) : bid,
                    "title": b.title,
                    "itemCount": b.itemCount
                ]
                if !b.paletteHexes.isEmpty {
                    entry["paletteHexes"] = Array(b.paletteHexes.prefix(4).map { $0.uppercased() })
                }
                return entry
            }
        }
        return .json(payload)
    }

    private func handleSearchAssets(
        _ args: [String: Any],
        policy: ExternalAgentConfig,
        channel: ExternalAgentChannel
    ) async throws -> ToolOutput {
        let wantSheet = Self.boolArg(args["render_contact_sheet"]) ?? false
        let includeImage = Self.boolArg(args["include_image"]) ?? true
        var validatedOutURL: URL?
        if wantSheet, let outPath = (args["output_path"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines), !outPath.isEmpty {
            switch validateExportOutputPath(outPath, allowedExtensions: ["jpg", "jpeg"], policy: policy, channel: channel) {
            case .allowed(let resolved):
                validatedOutURL = resolved
            case .rejected(let reason):
                return .error(reason)
            }
        }

        let folders = try await engine.fetchFolders()
        let folderPathByID = Self.buildFolderPaths(folders)
        let criteria = try buildFilterCriteria(from: args, folders: folders, folderPathByID: folderPathByID)
        let smartFolder = try await resolveOptionalSmartFolder(from: args)
        let offset = max(0, Self.intArg(args["offset"]) ?? 0)
        let defaultLimit = wantSheet ? 16 : 20
        let limit = max(1, min(100, Self.intArg(args["limit"]) ?? defaultLimit))
        let defaultDetail: AssetDetailLevel = (wantSheet && includeImage) ? .visual : .compact
        let detail = AssetDetailLevel.parse(args["detail"], fallback: defaultDetail)
        let diversify = Self.boolArg(args["diversify"]) ?? false

        var matches = try await engine.fetchAssets(matching: criteria)
        if let smartFolder {
            matches = matches.filter { smartFolder.rule.matches($0) }
        }
        matches = try await applyPostFilters(matches, args: args)
        let totalMatched = matches.count

        let sliced: [AssetRecord]
        if diversify && offset == 0 {
            sliced = await diversifyAssets(matches, limit: limit)
        } else {
            sliced = Self.paginate(matches, offset: offset, limit: limit)
        }
        let hasMore = offset + sliced.count < totalMatched

        var serializedAssets = sliced.map { serializeAssetSummary($0, folderPathByID: folderPathByID, detail: detail) }
        var payload: [String: Any] = [
            "totalMatched": totalMatched,
            "offset": offset,
            "returned": serializedAssets.count,
            "hasMore": hasMore
        ]
        if hasMore {
            payload["nextOffset"] = offset + serializedAssets.count
        }
        if diversify {
            payload["diversified"] = true
        }
        if let smartFolder {
            payload["smartFolder"] = ["id": smartFolder.id.uuidString, "name": smartFolder.name]
        }
        let includeFacets = Self.boolArg(args["include_facets"]) ?? (totalMatched > limit)
        if includeFacets && !matches.isEmpty {
            payload["facets"] = Self.computeResultFacets(matches, folderPathByID: folderPathByID)
        }

        if wantSheet && !sliced.isEmpty {
            let maxWidth = max(512, min(1920, Self.intArg(args["sheet_max_width"]) ?? 1024))
            if let attached = try renderAttachedContactSheet(
                for: Array(sliced.prefix(24)),
                maxWidth: maxWidth,
                outputURL: validatedOutURL
            ) {
                for idx in 0..<min(serializedAssets.count, attached.slotCount) {
                    serializedAssets[idx]["slot"] = idx + 1
                    serializedAssets[idx]["badge"] = String(format: "#%02d", idx + 1)
                }
                payload["contactSheet"] = attached.summary
                payload["assets"] = serializedAssets
                var content: [ToolContent] = []
                if includeImage {
                    content.append(.image(mimeType: "image/jpeg", data: attached.jpegData))
                }
                content.append(.text(Self.encodeCompactJSON(payload)))
                return ToolOutput(content: content)
            }
        }

        payload["assets"] = serializedAssets
        return .json(payload)
    }

    private func handleListInbox(
        _ args: [String: Any],
        policy: ExternalAgentConfig,
        channel: ExternalAgentChannel
    ) async throws -> ToolOutput {
        let wantSheet = Self.boolArg(args["render_contact_sheet"]) ?? false
        let includeImage = Self.boolArg(args["include_image"]) ?? true
        var validatedOutURL: URL?
        if wantSheet, let outPath = (args["output_path"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines), !outPath.isEmpty {
            switch validateExportOutputPath(outPath, allowedExtensions: ["jpg", "jpeg"], policy: policy, channel: channel) {
            case .allowed(let resolved):
                validatedOutURL = resolved
            case .rejected(let reason):
                return .error(reason)
            }
        }

        let offset = max(0, Self.intArg(args["offset"]) ?? 0)
        let limit = max(1, min(100, Self.intArg(args["limit"]) ?? (wantSheet ? 16 : 20)))
        let sortBy = Self.parseSortOrder(args["sort_by"], defaultOrder: .newest)
        let kinds = Self.parseMediaKinds(args["media_kinds"])
        let defaultDetail: AssetDetailLevel = (wantSheet && includeImage) ? .visual : .compact
        let detail = AssetDetailLevel.parse(args["detail"], fallback: defaultDetail)

        let matches = try await engine.fetchAssets(
            matching: FilterCriteria(kinds: kinds, onlyInbox: true, sortBy: sortBy)
        )
        let sliced = Self.paginate(matches, offset: offset, limit: limit)
        let hasMore = offset + sliced.count < matches.count

        var serializedAssets = sliced.map { serializeAssetSummary($0, folderPathByID: [:], detail: detail) }
        var payload: [String: Any] = [
            "inboxTotal": matches.count,
            "offset": offset,
            "returned": serializedAssets.count,
            "hasMore": hasMore
        ]
        if hasMore {
            payload["nextOffset"] = offset + serializedAssets.count
        }

        if wantSheet && !sliced.isEmpty {
            let maxWidth = max(512, min(1920, Self.intArg(args["sheet_max_width"]) ?? 1024))
            if let attached = try renderAttachedContactSheet(
                for: Array(sliced.prefix(24)),
                maxWidth: maxWidth,
                outputURL: validatedOutURL
            ) {
                for idx in 0..<min(serializedAssets.count, attached.slotCount) {
                    serializedAssets[idx]["slot"] = idx + 1
                    serializedAssets[idx]["badge"] = String(format: "#%02d", idx + 1)
                }
                payload["contactSheet"] = attached.summary
                payload["assets"] = serializedAssets
                var content: [ToolContent] = []
                if includeImage {
                    content.append(.image(mimeType: "image/jpeg", data: attached.jpegData))
                }
                content.append(.text(Self.encodeCompactJSON(payload)))
                return ToolOutput(content: content)
            }
        }

        payload["assets"] = serializedAssets
        return .json(payload)
    }

    private func handleGetAsset(_ args: [String: Any]) async throws -> ToolOutput {
        let includeImage = Self.boolArg(args["include_image"]) ?? false
        let maxSide = max(280, min(1568, Self.intArg(args["image_max_side"]) ?? 768))

        // Batch mode: inspect up to 12 finalists in ONE call when `asset_ids` is passed (supports 8+ char prefixes)
        if let rawBatch = Self.stringArrayArg(args["asset_ids"]), !rawBatch.isEmpty {
            let resolvedBatch = try await resolveAssetUUIDList(rawBatch)
            var uniqueUUIDs: [UUID] = []
            var seen = Set<UUID>()
            for uuid in resolvedBatch where seen.insert(uuid).inserted {
                uniqueUUIDs.append(uuid)
            }
            let capped = Array(uniqueUUIDs.prefix(12))
            guard !capped.isEmpty else {
                return .error("`asset_ids` contained no valid asset UUIDs or prefixes.")
            }

            let folders = try await engine.fetchFolders()
            let folderPathByID = Self.buildFolderPaths(folders)
            let iso = Self.makeISO8601Formatter()
            var resolvedAssets: [AssetRecord] = []
            var serialized: [[String: Any]] = []
            var missingIDs: [String] = []

            for uuid in capped {
                _ = try? await engine.hydrateImageMetadataIfNeeded(id: uuid)
                guard let asset = try await engine.fetchAsset(id: uuid) else {
                    missingIDs.append(uuid.uuidString)
                    continue
                }
                resolvedAssets.append(asset)
                serialized.append(await serializeAssetDetail(asset, folderPathByID: folderPathByID, iso: iso))
            }

            var payload: [String: Any] = [
                "requestedCount": capped.count,
                "returned": serialized.count
            ]
            if !missingIDs.isEmpty {
                payload["missingIDs"] = missingIDs
            }

            if includeImage && !resolvedAssets.isEmpty {
                if resolvedAssets.count == 1,
                   let jpegData = tools.preparedTypeSafeJPEG(for: resolvedAssets[0], targetLongSide: maxSide) {
                    payload["assets"] = serialized
                    return ToolOutput(content: [
                        .image(mimeType: "image/jpeg", data: jpegData),
                        .text(Self.encodeCompactJSON(payload))
                    ])
                } else {
                    let sheetWidth = max(960, min(1600, maxSide))
                    if let attached = try renderAttachedContactSheet(
                        for: resolvedAssets,
                        maxWidth: sheetWidth,
                        jpegQuality: 0.82,
                        outputURL: nil
                    ) {
                        for idx in 0..<min(serialized.count, attached.slotCount) {
                            serialized[idx]["slot"] = idx + 1
                            serialized[idx]["badge"] = String(format: "#%02d", idx + 1)
                        }
                        payload["contactSheet"] = attached.summary
                        payload["assets"] = serialized
                        return ToolOutput(content: [
                            .image(mimeType: "image/jpeg", data: attached.jpegData),
                            .text(Self.encodeCompactJSON(payload))
                        ])
                    }
                }
            }
            payload["assets"] = serialized
            return .json(payload)
        }

        // Single asset mode (supports full UUID or unique 8+ char prefix)
        guard let rawID = args["asset_id"] as? String ?? args["id"] as? String,
              let uuid = try await resolveAssetUUID(rawID) else {
            return .error("Missing or invalid UUID / prefix for `asset_id` (or pass `asset_ids` array).")
        }
        _ = try? await engine.hydrateImageMetadataIfNeeded(id: uuid)

        guard let asset = try await engine.fetchAsset(id: uuid) else {
            return .error("Asset not found: \(uuid.uuidString)")
        }
        let folders = try await engine.fetchFolders()
        let folderPathByID = Self.buildFolderPaths(folders)
        let dict = await serializeAssetDetail(asset, folderPathByID: folderPathByID, iso: Self.makeISO8601Formatter())

        if includeImage,
           let jpegData = tools.preparedTypeSafeJPEG(for: asset, targetLongSide: maxSide) {
            return ToolOutput(content: [
                .image(mimeType: "image/jpeg", data: jpegData),
                .text(Self.encodeCompactJSON(dict))
            ])
        }
        return .json(dict)
    }

    private func handleRenderContactSheet(
        _ args: [String: Any],
        policy: ExternalAgentConfig,
        channel: ExternalAgentChannel
    ) async throws -> ToolOutput {
        var validatedOutURL: URL?
        if let outPath = (args["output_path"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines), !outPath.isEmpty {
            switch validateExportOutputPath(outPath, allowedExtensions: ["jpg", "jpeg"], policy: policy, channel: channel) {
            case .allowed(let resolved):
                validatedOutURL = resolved
            case .rejected(let reason):
                return .error(reason)
            }
        }

        let folders = try await engine.fetchFolders()
        let folderPathByID = Self.buildFolderPaths(folders)
        let offset = max(0, Self.intArg(args["offset"]) ?? 0)
        let limit = max(1, min(24, Self.intArg(args["limit"]) ?? 16))
        let maxWidth = max(512, min(1920, Self.intArg(args["max_width"]) ?? 1024))
        let includeImage = Self.boolArg(args["include_image"]) ?? true
        let diversify = Self.boolArg(args["diversify"]) ?? false
        let defaultDetail: AssetDetailLevel = includeImage ? .visual : .compact
        let detail = AssetDetailLevel.parse(args["detail"], fallback: defaultDetail)

        var totalMatched = 0
        var selectedAssets: [AssetRecord] = []
        var queryGroupByAssetID: [UUID: String] = [:]
        var multiQueryGroups: [[String: Any]] = []

        let subQueries = (Self.stringArrayArg(args["queries"]) ?? [])
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }

        if let rawIDs = Self.stringArrayArg(args["asset_ids"]), !rawIDs.isEmpty {
            let resolvedUUIDs = try await resolveAssetUUIDList(rawIDs)
            var resolved: [AssetRecord] = []
            for uuid in resolvedUUIDs {
                if let asset = try await engine.fetchAsset(id: uuid) {
                    resolved.append(asset)
                }
            }
            resolved = try await applyPostFilters(resolved, args: args)
            totalMatched = resolved.count
            selectedAssets = (diversify && offset == 0)
                ? await diversifyAssets(resolved, limit: limit)
                : Self.paginate(resolved, offset: offset, limit: limit)
        } else if !subQueries.isEmpty {
            var criteria = try buildFilterCriteria(from: args, folders: folders, folderPathByID: folderPathByID)
            criteria.searchQuery = ""
            let multi = try await runMultiQueryRecall(
                queries: subQueries,
                criteria: criteria,
                args: args,
                seedIDs: [],
                unlikeIDs: [],
                limit: limit,
                diversify: diversify
            )
            selectedAssets = multi.hits.map(\.hit.asset)
            totalMatched = multi.totalUniqueMatched
            for pair in multi.hits {
                queryGroupByAssetID[pair.hit.asset.id] = pair.queryGroup
            }
            multiQueryGroups = multi.groupsSummary
        } else {
            let criteria = try buildFilterCriteria(from: args, folders: folders, folderPathByID: folderPathByID)
            let smartFolder = try await resolveOptionalSmartFolder(from: args)
            var matches = try await engine.fetchAssets(matching: criteria)
            if let smartFolder {
                matches = matches.filter { smartFolder.rule.matches($0) }
            }
            matches = try await applyPostFilters(matches, args: args)
            totalMatched = matches.count
            selectedAssets = (diversify && offset == 0)
                ? await diversifyAssets(matches, limit: limit)
                : Self.paginate(matches, offset: offset, limit: limit)
        }

        guard !selectedAssets.isEmpty else {
            return .json([
                "totalMatched": totalMatched,
                "offset": offset,
                "slotCount": 0,
                "hasMore": false,
                "slots": [],
                "message": "No assets matched the requested filter or asset_ids."
            ])
        }

        let entries: [ContactSheetRenderer.Entry] = selectedAssets.enumerated().map { idx, asset in
            let thumbURL = engine.media.thumbnailURL(for: asset.id, tier: .grid520)
                ?? engine.media.thumbnailURL(for: asset.id, tier: .preview1400)
            return ContactSheetRenderer.Entry(slot: idx + 1, asset: asset, thumbnailURL: thumbURL)
        }
        guard let sheet = ContactSheetRenderer.render(entries: entries, maxCanvasWidth: maxWidth, jpegQuality: 0.74) else {
            return .error("Failed to render Contact Sheet image.")
        }

        var savedPath: String?
        if let outURL = validatedOutURL {
            try FileManager.default.createDirectory(at: outURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try sheet.jpegData.write(to: outURL, options: .atomic)
            savedPath = outURL.path
        }

        let assetsByID = Dictionary(uniqueKeysWithValues: selectedAssets.map { ($0.id, $0) })
        let slotEntries: [[String: Any]] = sheet.orderedSlots.compactMap { pair in
            guard let asset = assetsByID[pair.assetID] else { return nil }
            let folderPath = asset.folderID.flatMap { folderPathByID[$0] } ?? "Inbox"
            if detail == .visual {
                var entry: [String: Any] = [
                    "slot": pair.slot,
                    "badge": String(format: "#%02d", pair.slot),
                    "assetID": String(asset.id.uuidString.prefix(8)),
                    "title": Self.truncateText(asset.title, maxChars: 42),
                    "folderPath": folderPath
                ]
                if asset.pixelWidth > 0 && asset.pixelHeight > 0 {
                    entry["dimensions"] = "\(asset.pixelWidth)x\(asset.pixelHeight)"
                } else {
                    entry["aspectShape"] = asset.aspectShape.rawValue
                }
                if asset.mediaKind != .image { entry["mediaKind"] = asset.mediaKind.rawValue }
                if asset.rating > 0 { entry["rating"] = asset.rating }
                if let qg = queryGroupByAssetID[asset.id] { entry["queryGroup"] = qg }
                return entry
            }

            var entry: [String: Any] = [
                "slot": pair.slot,
                "badge": String(format: "#%02d", pair.slot),
                "assetID": asset.id.uuidString,
                "title": asset.title,
                "mediaKind": asset.mediaKind.rawValue,
                "folderPath": folderPath,
                "aspectRatio": (asset.aspectRatio * 100).rounded() / 100
            ]
            if offset > 0 { entry["index"] = offset + pair.slot }
            if asset.pixelWidth > 0 && asset.pixelHeight > 0 {
                entry["dimensions"] = "\(asset.pixelWidth)x\(asset.pixelHeight)"
            }
            if asset.rating > 0 { entry["rating"] = asset.rating }
            if !asset.tags.isEmpty { entry["tags"] = asset.tags }
            let colors = asset.dominantColors.prefix(3).map { $0.hex.uppercased() }
            if !colors.isEmpty { entry["dominantColors"] = colors }
            if let desc = asset.aiDescription?.trimmingCharacters(in: .whitespacesAndNewlines), !desc.isEmpty {
                entry["aiDescription"] = Self.truncateText(desc, maxChars: 110)
            }
            if let qg = queryGroupByAssetID[asset.id] { entry["queryGroup"] = qg }
            return entry
        }

        let hasMore = offset + slotEntries.count < totalMatched
        var metadata: [String: Any] = [
            "sheetWidth": sheet.width,
            "sheetHeight": sheet.height,
            "totalMatched": totalMatched,
            "offset": offset,
            "slotCount": slotEntries.count,
            "hasMore": hasMore,
            "slots": slotEntries
        ]
        if diversify { metadata["diversified"] = true }
        if !multiQueryGroups.isEmpty { metadata["queryGroups"] = multiQueryGroups }
        if hasMore {
            metadata["nextOffset"] = offset + slotEntries.count
        }
        if let savedPath {
            metadata["savedPath"] = savedPath
        }

        var content: [ToolContent] = []
        if includeImage {
            content.append(.image(mimeType: "image/jpeg", data: sheet.jpegData))
        }
        content.append(.text(Self.encodeCompactJSON(metadata)))
        return ToolOutput(content: content)
    }

    private func handleFindSimilarAssets(
        _ args: [String: Any],
        policy: ExternalAgentConfig,
        channel: ExternalAgentChannel
    ) async throws -> ToolOutput {
        guard let rawID = args["asset_id"] as? String ?? args["id"] as? String,
              let uuid = try await resolveAssetUUID(rawID) else {
            return .error("Missing or invalid UUID / prefix for `asset_id`.")
        }
        guard (try await engine.fetchAsset(id: uuid)) != nil else {
            return .error("Asset not found: \(uuid.uuidString)")
        }
        let wantSheet = Self.boolArg(args["render_contact_sheet"]) ?? false
        let includeImage = Self.boolArg(args["include_image"]) ?? true
        var validatedOutURL: URL?
        if wantSheet, let outPath = (args["output_path"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines), !outPath.isEmpty {
            switch validateExportOutputPath(outPath, allowedExtensions: ["jpg", "jpeg"], policy: policy, channel: channel) {
            case .allowed(let resolved):
                validatedOutURL = resolved
            case .rejected(let reason):
                return .error(reason)
            }
        }

        let limit = max(1, min(32, Self.intArg(args["limit"]) ?? 12))
        let diversify = Self.boolArg(args["diversify"]) ?? false
        let defaultDetail: AssetDetailLevel = (wantSheet && includeImage) ? .visual : .compact
        let detail = AssetDetailLevel.parse(args["detail"], fallback: defaultDetail)
        let excludedIDs = Set(try await resolveAssetUUIDList(args["exclude_asset_ids"]))
        let unlikeIDs = try await resolveAssetUUIDList(args["unlike_asset_ids"])
        let unlikeSet = Set(unlikeIDs)
        let fetchLimit = (diversify || !excludedIDs.isEmpty || !unlikeSet.isEmpty) ? min(64, limit * 3) : limit
        var matches = try await engine.similarAssets(to: uuid, limit: fetchLimit)
        if !excludedIDs.isEmpty || !unlikeSet.isEmpty {
            matches.removeAll { excludedIDs.contains($0.asset.id) || unlikeSet.contains($0.asset.id) }
        }
        // Apply negative visual repulsion when `unlike_asset_ids` is provided
        if !unlikeIDs.isEmpty && !matches.isEmpty {
            let featurePrints = (try? await engine.database.featurePrints()) ?? [:]
            let unlikeObs = unlikeIDs.compactMap { featurePrints[$0].flatMap(VisionAnalyzer.unarchiveFeaturePrint) }
            if !unlikeObs.isEmpty {
                matches = matches.map { item -> ScoredAsset in
                    guard let fp = featurePrints[item.asset.id],
                          let candidateObs = VisionAnalyzer.unarchiveFeaturePrint(fp) else { return item }
                    let maxNeg = unlikeObs
                        .compactMap { VisionAnalyzer.visualDistance(between: candidateObs, and: $0) }
                        .map { VisionAnalyzer.visualSimilarity(forDistance: $0) }
                        .max() ?? 0.0
                    guard maxNeg >= 0.42 else { return item }
                    let penalty = max(0.15, 1.0 - (maxNeg - 0.35) * 1.15)
                    return ScoredAsset(asset: item.asset, score: item.score * penalty, matchReasons: item.matchReasons)
                }.sorted { $0.score > $1.score }
            }
        }
        if diversify && matches.count > 1 {
            let diversifiedAssets = await diversifyAssets(matches.map(\.asset), limit: limit)
            let scoredByID = Dictionary(uniqueKeysWithValues: matches.map { ($0.asset.id, $0) })
            matches = diversifiedAssets.compactMap { scoredByID[$0.id] }
        } else {
            matches = Array(matches.prefix(limit))
        }

        let folders = try await engine.fetchFolders()
        let folderPathByID = Self.buildFolderPaths(folders)

        var items: [[String: Any]] = matches.enumerated().map { idx, scored in
            var dict = serializeAssetSummary(scored.asset, folderPathByID: folderPathByID, detail: detail)
            dict["rank"] = idx + 1
            dict["score"] = (scored.score * 1000).rounded() / 1000
            if detail != .visual && !scored.matchReasons.isEmpty {
                dict["matchReasons"] = scored.matchReasons
            }
            return dict
        }

        var payload: [String: Any] = [
            "referenceAssetID": uuid.uuidString,
            "returned": items.count
        ]

        if wantSheet && !matches.isEmpty {
            let maxWidth = max(512, min(1920, Self.intArg(args["sheet_max_width"]) ?? 1024))
            if let attached = try renderAttachedContactSheet(
                for: Array(matches.prefix(24).map(\.asset)),
                maxWidth: maxWidth,
                outputURL: validatedOutURL
            ) {
                for idx in 0..<min(items.count, attached.slotCount) {
                    items[idx]["slot"] = idx + 1
                    items[idx]["badge"] = String(format: "#%02d", idx + 1)
                }
                payload["contactSheet"] = attached.summary
                payload["matches"] = items
                var content: [ToolContent] = []
                if includeImage {
                    content.append(.image(mimeType: "image/jpeg", data: attached.jpegData))
                }
                content.append(.text(Self.encodeCompactJSON(payload)))
                return ToolOutput(content: content)
            }
        }
        payload["matches"] = items
        return .json(payload)
    }

    private func handleSemanticSearch(
        _ args: [String: Any],
        policy: ExternalAgentConfig,
        channel: ExternalAgentChannel
    ) async throws -> ToolOutput {
        let query = ((args["query"] as? String) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let subQueries = (Self.stringArrayArg(args["queries"]) ?? [])
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        let seedIDs = try await resolveAssetUUIDList(args["seed_asset_ids"])
        let unlikeIDs = try await resolveAssetUUIDList(args["unlike_asset_ids"])
        guard !query.isEmpty || !subQueries.isEmpty || !seedIDs.isEmpty else {
            return .error("Provide `query`, `queries[]`, or `seed_asset_ids` for semantic_search.")
        }

        let wantSheet = Self.boolArg(args["render_contact_sheet"]) ?? false
        let includeImage = Self.boolArg(args["include_image"]) ?? true
        var validatedOutURL: URL?
        if wantSheet, let outPath = (args["output_path"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines), !outPath.isEmpty {
            switch validateExportOutputPath(outPath, allowedExtensions: ["jpg", "jpeg"], policy: policy, channel: channel) {
            case .allowed(let resolved):
                validatedOutURL = resolved
            case .rejected(let reason):
                return .error(reason)
            }
        }

        let folders = try await engine.fetchFolders()
        let folderPathByID = Self.buildFolderPaths(folders)
        var criteria = try buildFilterCriteria(from: args, folders: folders, folderPathByID: folderPathByID)
        criteria.searchQuery = ""
        let limit = max(1, min(50, Self.intArg(args["limit"]) ?? 16))
        let diversify = Self.boolArg(args["diversify"]) ?? false
        let defaultDetail: AssetDetailLevel = (wantSheet && includeImage) ? .visual : .compact
        let detail = AssetDetailLevel.parse(args["detail"], fallback: defaultDetail)

        // Multi-intent single-call recall (`queries: [...]`)
        if subQueries.count >= 2 {
            let multi = try await runMultiQueryRecall(
                queries: subQueries,
                criteria: criteria,
                args: args,
                seedIDs: seedIDs,
                unlikeIDs: unlikeIDs,
                limit: limit,
                diversify: diversify
            )
            var hits: [[String: Any]] = multi.hits.enumerated().map { idx, item in
                var dict = serializeAssetSummary(item.hit.asset, folderPathByID: folderPathByID, detail: detail)
                dict["rank"] = idx + 1
                dict["score"] = (item.hit.score * 1000).rounded() / 1000
                dict["queryGroup"] = item.queryGroup
                if detail != .visual && !item.hit.reason.isEmpty { dict["reason"] = item.hit.reason }
                return dict
            }
            var payload: [String: Any] = [
                "queries": subQueries,
                "queryGroups": multi.groupsSummary,
                "usedCloudEmbedding": false,
                "usedVisualRerank": false,
                "evaluatedVisualCount": 0,
                "returned": hits.count
            ]
            if diversify { payload["diversified"] = true }
            if wantSheet && !multi.hits.isEmpty {
                let maxWidth = max(512, min(1920, Self.intArg(args["sheet_max_width"]) ?? 1024))
                if let attached = try renderAttachedContactSheet(
                    for: Array(multi.hits.prefix(24).map(\.hit.asset)),
                    maxWidth: maxWidth,
                    outputURL: validatedOutURL
                ) {
                    for idx in 0..<min(hits.count, attached.slotCount) {
                        hits[idx]["slot"] = idx + 1
                        hits[idx]["badge"] = String(format: "#%02d", idx + 1)
                    }
                    payload["contactSheet"] = attached.summary
                    payload["hits"] = hits
                    var content: [ToolContent] = []
                    if includeImage {
                        content.append(.image(mimeType: "image/jpeg", data: attached.jpegData))
                    }
                    content.append(.text(Self.encodeCompactJSON(payload)))
                    return ToolOutput(content: content)
                }
            }
            payload["hits"] = hits
            return .json(payload)
        }

        let effectiveQuery = !query.isEmpty ? query : (subQueries.first ?? "")
        // Default to instant local recall when attaching a Contact Sheet (the multimodal agent inspects visually itself)
        let allowVisualRerank = Self.boolArg(args["visual_rerank"]) ?? !wantSheet

        let fetchLimit = diversify ? min(64, max(limit * 3, 36)) : min(64, max(limit, 24))
        let report = try await engine.semanticSearch(
            query: effectiveQuery,
            criteria: criteria,
            limit: fetchLimit,
            allowVisualRerank: allowVisualRerank,
            seedAssetIDs: seedIDs,
            unlikeAssetIDs: unlikeIDs
        )

        let postFilteredIDs = Set((try await applyPostFilters(report.hits.map(\.asset), args: args)).map(\.id))
        var filteredHits = report.hits.filter { postFilteredIDs.contains($0.asset.id) }
        let matchedTotal = filteredHits.count

        if diversify && filteredHits.count > 1 {
            let diversifiedAssets = await diversifyAssets(filteredHits.map(\.asset), limit: limit)
            let hitByID = Dictionary(uniqueKeysWithValues: filteredHits.map { ($0.asset.id, $0) })
            filteredHits = diversifiedAssets.compactMap { hitByID[$0.id] }
        } else {
            filteredHits = Array(filteredHits.prefix(limit))
        }

        var hits: [[String: Any]] = filteredHits.enumerated().map { idx, hit in
            var dict = serializeAssetSummary(hit.asset, folderPathByID: folderPathByID, detail: detail)
            dict["rank"] = idx + 1
            dict["score"] = (hit.score * 1000).rounded() / 1000
            if let conf = hit.confidence {
                dict["confidence"] = (conf * 1000).rounded() / 1000
            }
            if detail != .visual && !hit.reason.isEmpty { dict["reason"] = hit.reason }
            if detail != .visual { dict["source"] = hit.sourceLabel }
            return dict
        }

        var payload: [String: Any] = [
            "query": report.query,
            "summary": report.summary,
            "usedCloudEmbedding": report.usedCloudEmbedding,
            "usedVisualRerank": report.usedTypeSafeJev,
            "evaluatedVisualCount": report.evaluatedVisualCount,
            "returned": hits.count
        ]
        if diversify { payload["diversified"] = true }
        let includeFacets = Self.boolArg(args["include_facets"]) ?? false
        if includeFacets && matchedTotal > 0 {
            payload["facets"] = Self.computeResultFacets(report.hits.filter { postFilteredIDs.contains($0.asset.id) }.map(\.asset), folderPathByID: folderPathByID)
        }

        if wantSheet && !filteredHits.isEmpty {
            let maxWidth = max(512, min(1920, Self.intArg(args["sheet_max_width"]) ?? 1024))
            if let attached = try renderAttachedContactSheet(
                for: Array(filteredHits.prefix(24).map(\.asset)),
                maxWidth: maxWidth,
                outputURL: validatedOutURL
            ) {
                for idx in 0..<min(hits.count, attached.slotCount) {
                    hits[idx]["slot"] = idx + 1
                    hits[idx]["badge"] = String(format: "#%02d", idx + 1)
                }
                payload["contactSheet"] = attached.summary
                payload["hits"] = hits
                var content: [ToolContent] = []
                if includeImage {
                    content.append(.image(mimeType: "image/jpeg", data: attached.jpegData))
                }
                content.append(.text(Self.encodeCompactJSON(payload)))
                return ToolOutput(content: content)
            }
        }

        payload["hits"] = hits
        return .json(payload)
    }

    private func handleQuickJump(_ args: [String: Any]) async throws -> ToolOutput {
        let query = ((args["query"] as? String) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else {
            return .error("Missing non-empty `query` for quick_jump.")
        }
        let limit = max(1, min(50, Self.intArg(args["limit"]) ?? 20))
        let matches = try await engine.quickJump(query: query, limit: limit)
        let items: [[String: Any]] = matches.map { match in
            var dict: [String: Any] = [
                "kind": match.kind.rawValue,
                "title": match.title,
                "subtitle": match.subtitle,
                "score": (match.score * 1000).rounded() / 1000
            ]
            if let uuid = match.targetUUID {
                dict["targetUUID"] = uuid.uuidString
            }
            if let tag = match.tagName {
                dict["tagName"] = tag
            }
            return dict
        }
        return .json([
            "query": query,
            "returned": items.count,
            "matches": items
        ])
    }

    private func handleSuggestFolder(_ args: [String: Any]) async throws -> ToolOutput {
        var ids = try await resolveAssetUUIDList(args["asset_ids"])
        if let single = args["asset_id"] as? String ?? args["id"] as? String,
           let uuid = try await resolveAssetUUID(single),
           !ids.contains(uuid) {
            ids.insert(uuid, at: 0)
        }
        guard !ids.isEmpty else {
            return .error("Provide `asset_id` or a non-empty `asset_ids` array.")
        }

        let folders = try await engine.fetchFolders()
        let folderPathByID = Self.buildFolderPaths(folders)
        let targetIDs = Array(ids.prefix(20))
        let loadedAssets = try await engine.database.assets(ids: targetIDs)
        let assetsByID = Dictionary(uniqueKeysWithValues: loadedAssets.map { ($0.id, $0) })
        let suggestionsByID = try await engine.suggestFolders(for: targetIDs)
        var recommendations: [[String: Any]] = []
        recommendations.reserveCapacity(targetIDs.count)

        for uuid in targetIDs {
            guard let asset = assetsByID[uuid] else {
                recommendations.append([
                    "assetID": uuid.uuidString,
                    "found": false
                ])
                continue
            }
            if let suggestion = suggestionsByID[uuid] {
                recommendations.append([
                    "assetID": uuid.uuidString,
                    "assetTitle": asset.title,
                    "currentFolderPath": asset.folderID.flatMap { folderPathByID[$0] } ?? "Inbox",
                    "suggestedFolderID": suggestion.folderID.uuidString,
                    "suggestedFolderName": suggestion.folderName,
                    "suggestedFolderPath": folderPathByID[suggestion.folderID] ?? suggestion.folderName,
                    "confidence": (suggestion.confidence * 1000).rounded() / 1000,
                    "reason": suggestion.reason
                ])
            } else {
                recommendations.append([
                    "assetID": uuid.uuidString,
                    "assetTitle": asset.title,
                    "currentFolderPath": asset.folderID.flatMap { folderPathByID[$0] } ?? "Inbox",
                    "suggestedFolderID": "",
                    "reason": "No confident folder match found."
                ])
            }
        }

        return .json([
            "evaluatedCount": recommendations.count,
            "recommendations": recommendations
        ])
    }

    private func handleListBoards() async throws -> ToolOutput {
        let boards = try await engine.fetchBoards()
        let formatter = Self.makeISO8601Formatter()
        let payload: [String: Any] = [
            "count": boards.count,
            "boards": boards.map { b -> [String: Any] in
                [
                    "id": b.id.uuidString,
                    "title": b.title,
                    "subtitle": b.subtitle,
                    "mode": Self.layoutModeLabel(b.mode),
                    "itemCount": b.itemCount,
                    "paletteHexes": b.paletteHexes.map { $0.uppercased() },
                    "pinnedOffline": b.pinnedOffline,
                    "updatedAt": formatter.string(from: b.updatedAt)
                ]
            }
        ]
        return .json(payload)
    }

    private func handleGetBoardContext(_ args: [String: Any]) async throws -> ToolOutput {
        guard let doc = try await resolveBoard(from: args) else {
            return .error("Moodboard not found. Pass a valid `board_id` UUID or matching `title`.")
        }
        let detail = AssetDetailLevel.parse(args["detail"])
        let folders = try await engine.fetchFolders()
        let folderPathByID = Self.buildFolderPaths(folders)
        var assetsByID: [UUID: AssetRecord] = [:]
        for assetID in Set(doc.referencedAssetIDs + doc.candidateAssetIDs) {
            if let asset = try await engine.fetchAsset(id: assetID) {
                assetsByID[assetID] = asset
            }
        }

        var notes: [[String: Any]] = []
        var sections: [[String: Any]] = []
        var cardRefs: [[String: Any]] = []

        func frameDict(_ f: BoardRect) -> [String: Any] {
            [
                "x": f.x.rounded(),
                "y": f.y.rounded(),
                "width": f.width.rounded(),
                "height": f.height.rounded()
            ]
        }

        for node in doc.nodes.sorted(by: { $0.editorialOrder < $1.editorialOrder }) {
            switch node.kind {
            case .note(let title, let text, let style, _):
                var item: [String: Any] = [
                    "nodeID": node.id.uuidString,
                    "text": text,
                    "style": style.rawValue,
                    "frame": frameDict(node.frame)
                ]
                if let title, !title.isEmpty { item["title"] = title }
                if node.isLocked { item["isLocked"] = true }
                notes.append(item)
            case .groupFrame(let title, let tint):
                var item: [String: Any] = [
                    "nodeID": node.id.uuidString,
                    "title": title,
                    "tint": tint.rawValue,
                    "frame": frameDict(node.frame)
                ]
                if node.isLocked { item["isLocked"] = true }
                sections.append(item)
            case .assetRef(let assetID, let crop, let weight, _):
                if let asset = assetsByID[assetID] {
                    var summary = serializeAssetSummary(asset, folderPathByID: folderPathByID, detail: detail)
                    summary["nodeID"] = node.id.uuidString
                    summary["weight"] = weight
                    if weight >= 2 { summary["isHero"] = true }
                    if node.isLocked { summary["isLocked"] = true }
                    summary["frame"] = frameDict(node.frame)
                    if let crop, crop.isMeaningfulSubregion {
                        summary["crop"] = [
                            "x": (crop.x * 1000).rounded() / 1000,
                            "y": (crop.y * 1000).rounded() / 1000,
                            "width": (crop.width * 1000).rounded() / 1000,
                            "height": (crop.height * 1000).rounded() / 1000
                        ]
                    }
                    if detail != .compact {
                        let candidateOriginal = engine.media.originalPath(for: asset)
                        if FileManager.default.fileExists(atPath: candidateOriginal.path) {
                            summary["localOriginalPath"] = candidateOriginal.path
                        }
                    }
                    cardRefs.append(summary)
                }
            case .paletteStrip:
                break
            }
        }

        let connectors: [[String: Any]] = doc.connectors.map { c in
            var item: [String: Any] = [
                "id": c.id.uuidString,
                "fromNodeID": c.fromNodeID.uuidString,
                "toNodeID": c.toNodeID.uuidString,
                "style": c.style.rawValue,
                "colorHex": c.colorHex.uppercased()
            ]
            if let label = c.label, !label.isEmpty { item["label"] = label }
            if c.dashed { item["dashed"] = true }
            return item
        }

        let candidates: [[String: Any]] = doc.candidateAssetIDs.compactMap { cid in
            guard let asset = assetsByID[cid] else { return nil }
            return [
                "id": asset.id.uuidString,
                "title": asset.title,
                "folderPath": asset.folderID.flatMap { folderPathByID[$0] } ?? "Inbox"
            ]
        }

        let palette: [[String: Any]] = doc.extractedPalette.map { c in
            [
                "hex": c.hex.uppercased(),
                "proportion": (c.proportion * 1000).rounded() / 1000,
                "lab": ["l": c.l.rounded(), "a": c.a.rounded(), "b": c.b.rounded()]
            ]
        }

        let iso = Self.makeISO8601Formatter()
        var payload: [String: Any] = [
            "id": doc.id.uuidString,
            "title": doc.title,
            "mode": Self.layoutModeLabel(doc.mode),
            "pinnedOffline": doc.pinnedOffline,
            "updatedAt": iso.string(from: doc.updatedAt),
            "itemCount": cardRefs.count,
            "inkStrokeCount": doc.inkStrokes.count,
            "palette": palette,
            "notes": notes,
            "sections": sections,
            "connectors": connectors,
            "assets": cardRefs,
            "candidatePool": candidates
        ]
        if !doc.subtitle.isEmpty { payload["subtitle"] = doc.subtitle }
        return .json(payload)
    }

    private func handleExportBoardImage(
        _ args: [String: Any],
        policy: ExternalAgentConfig,
        channel: ExternalAgentChannel
    ) async throws -> ToolOutput {
        var validatedOutURL: URL?
        if let outPath = (args["output_path"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines), !outPath.isEmpty {
            switch validateExportOutputPath(outPath, allowedExtensions: ["png"], policy: policy, channel: channel) {
            case .allowed(let resolved):
                validatedOutURL = resolved
            case .rejected(let reason):
                return .error(reason)
            }
        }

        guard let doc = try await resolveBoard(from: args) else {
            return .error("Moodboard not found. Pass a valid `board_id` UUID or matching `title`.")
        }
        var assetsByID: [UUID: AssetRecord] = [:]
        var thumbByID: [UUID: URL] = [:]
        for assetID in doc.referencedAssetIDs {
            if let asset = try await engine.fetchAsset(id: assetID) {
                assetsByID[assetID] = asset
            }
            // Prefer high-resolution preview1400 for crisp board exports; fall back to grid520.
            if let preview = await engine.thumbnailURL(for: assetID, tier: .preview1400) {
                thumbByID[assetID] = preview
            } else if let grid = await engine.thumbnailURL(for: assetID, tier: .grid520) {
                thumbByID[assetID] = grid
            }
        }

        let dark = Self.boolArg(args["dark_appearance"]) ?? false
        let width = CGFloat(max(840, min(2800, Self.intArg(args["width"]) ?? 1440)))
        let includeImage = Self.boolArg(args["include_image"]) ?? true
        guard let pngData = BoardImageRenderer.renderPNG(
            document: doc,
            assetsByID: assetsByID,
            thumbnailURL: { thumbByID[$0] },
            options: BoardImageRenderer.RenderOptions(canvasWidth: width, darkAppearance: dark)
        ) else {
            return .error("Failed to render moodboard image.")
        }

        var metadata: [String: Any] = [
            "boardID": doc.id.uuidString,
            "title": doc.title,
            "itemCount": doc.referencedAssetIDs.count,
            "width": Int(width),
            "darkAppearance": dark,
            "bytes": pngData.count,
            "mimeType": "image/png"
        ]
        if let outURL = validatedOutURL {
            try FileManager.default.createDirectory(at: outURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try pngData.write(to: outURL, options: .atomic)
            metadata["savedPath"] = outURL.path
        }

        var content: [ToolContent] = []
        if includeImage {
            content.append(.image(mimeType: "image/png", data: pngData))
        }
        content.append(.text(Self.encodeCompactJSON(metadata)))
        return ToolOutput(content: content)
    }

    // MARK: - Safe Write / Organize Tool Handlers (Never Permanent Delete)

    private func handleOrganizeAssets(_ args: [String: Any]) async throws -> ToolOutput {
        let ids = try await resolveAssetUUIDList(args["asset_ids"])
        guard !ids.isEmpty else {
            return .error("`asset_ids` must be a non-empty array of asset UUID strings or prefixes.")
        }

        let folders = try await engine.fetchFolders()
        let folderPathByID = Self.buildFolderPaths(folders)
        var assignment: FolderAssignment = .unchanged
        if Self.boolArg(args["move_to_inbox"]) == true {
            assignment = .inbox
        } else if let resolvedFolderID = try resolveOptionalFolderID(from: args, folders: folders, folderPathByID: folderPathByID) {
            assignment = .folder(resolvedFolderID)
        }

        let addTags = Self.stringArrayArg(args["add_tags"]) ?? []
        let removeTags = Self.stringArrayArg(args["remove_tags"]) ?? []
        let dismissSuggested = Self.stringArrayArg(args["dismiss_suggested_tags"]) ?? []
        let rating = Self.intArg(args["rating"])
        let notes = args["notes"] as? String
        let title = args["title"] as? String
        let acceptSuggested = Self.boolArg(args["accept_suggested_tags"]) ?? false
        let pinnedOffline = Self.boolArg(args["pinned_offline"])

        let patch = AssetBatchPatch(
            assetIDs: ids,
            title: title,
            notes: notes,
            rating: rating,
            addTags: addTags,
            removeTags: removeTags,
            acceptSuggestedTags: acceptSuggested,
            dismissSuggestedTags: dismissSuggested,
            folderAssignment: assignment,
            pinnedOffline: pinnedOffline
        )
        let updated = try await engine.updateAssets(patch)
        let updatedSet = Set(updated.map(\.id))
        let skippedIDs = ids.filter { !updatedSet.contains($0) }.map(\.uuidString)

        // Explicit overwrite when external agent passes `ai_description`.
        if let aiDesc = (args["ai_description"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines), !aiDesc.isEmpty {
            let insights = updated.map { AgentVisualInsight(assetID: $0.id, description: aiDesc, tags: []) }
            _ = await tools.persistVisualInsights(insights, overwriteDescription: true)
        }

        if notifyOnWrite && !updated.isEmpty {
            ExternalAgentNotifier.postLibraryChanged(kind: "assets", summary: "外部 Agent 已整理 \(updated.count) 项素材")
        }
        var result: [String: Any] = [
            "updatedCount": updated.count,
            "assetIDs": updated.map { $0.id.uuidString }
        ]
        if !skippedIDs.isEmpty {
            result["skippedIDs"] = skippedIDs
        }
        return .json(result)
    }

    private func handleCreateFolder(_ args: [String: Any]) async throws -> ToolOutput {
        guard let name = (args["name"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines), !name.isEmpty else {
            return .error("Missing non-empty folder `name`.")
        }
        let folders = try await engine.fetchFolders()
        let folderPathByID = Self.buildFolderPaths(folders)
        let parentID = try resolveOptionalFolderID(
            from: ["folder_id": args["parent_id"] as Any, "folder_path": args["parent_path"] as Any],
            folders: folders,
            folderPathByID: folderPathByID
        )
        var created = try await engine.createFolder(name: name, parentID: parentID)
        let colorHex = args["color_hex"] as? String
        let customSymbol = args["custom_symbol"] as? String
        if colorHex != nil || customSymbol != nil {
            created = try await engine.updateFolderAppearance(id: created.id, colorHex: colorHex, customSymbol: customSymbol)
        }
        let refreshed = try await engine.fetchFolders()
        let refreshedPaths = Self.buildFolderPaths(refreshed)
        if notifyOnWrite {
            ExternalAgentNotifier.postLibraryChanged(kind: "folders", summary: "外部 Agent 已新建文件夹「\(created.name)」")
        }
        return .json([
            "id": created.id.uuidString,
            "name": created.name,
            "path": refreshedPaths[created.id] ?? created.name,
            "parentID": created.parentID?.uuidString ?? "",
            "colorHex": created.colorHex ?? "",
            "customSymbol": created.customSymbol ?? ""
        ])
    }

    private func handleUpdateFolder(_ args: [String: Any]) async throws -> ToolOutput {
        let folders = try await engine.fetchFolders()
        let folderPathByID = Self.buildFolderPaths(folders)
        guard let folderID = try resolveOptionalFolderID(from: args, folders: folders, folderPathByID: folderPathByID),
              var current = folders.first(where: { $0.id == folderID }) else {
            return .error("Folder not found. Pass a valid `folder_id` UUID or matching `folder_path`.")
        }

        if let newName = (args["new_name"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines), !newName.isEmpty {
            current = try await engine.renameFolder(id: folderID, newName: newName)
        }

        let moveToRoot = Self.boolArg(args["move_to_root"]) ?? false
        let hasParentArg = (args["parent_id"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
            || (args["parent_path"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
        if moveToRoot || hasParentArg {
            let latestFolders = try await engine.fetchFolders()
            let latestPaths = Self.buildFolderPaths(latestFolders)
            let newParentID: UUID? = moveToRoot
                ? nil
                : try resolveOptionalFolderID(
                    from: ["folder_id": args["parent_id"] as Any, "folder_path": args["parent_path"] as Any],
                    folders: latestFolders,
                    folderPathByID: latestPaths
                )
            _ = try await engine.moveFolder(id: folderID, newParentID: newParentID, insertAtIndex: nil)
        }

        if args["color_hex"] != nil || args["custom_symbol"] != nil {
            let colorHex = (args["color_hex"] as? String) ?? current.colorHex
            let customSymbol = (args["custom_symbol"] as? String) ?? current.customSymbol
            current = try await engine.updateFolderAppearance(id: folderID, colorHex: colorHex, customSymbol: customSymbol)
        }

        let finalFolders = try await engine.fetchFolders()
        let finalPaths = Self.buildFolderPaths(finalFolders)
        let finalFolder = finalFolders.first(where: { $0.id == folderID }) ?? current

        if notifyOnWrite {
            ExternalAgentNotifier.postLibraryChanged(kind: "folders", summary: "外部 Agent 已更新文件夹「\(finalFolder.name)」")
        }
        return .json([
            "id": finalFolder.id.uuidString,
            "name": finalFolder.name,
            "path": finalPaths[finalFolder.id] ?? finalFolder.name,
            "parentID": finalFolder.parentID?.uuidString ?? "",
            "colorHex": finalFolder.colorHex ?? "",
            "customSymbol": finalFolder.customSymbol ?? "",
            "assetCount": finalFolder.assetCount
        ])
    }

    private func handleIngestAsset(_ args: [String: Any]) async throws -> ToolOutput {
        let folders = try await engine.fetchFolders()
        let folderPathByID = Self.buildFolderPaths(folders)
        let targetFolderID = try resolveOptionalFolderID(from: args, folders: folders, folderPathByID: folderPathByID)

        var targetBoardID: UUID?
        if let rawBoard = (args["target_board_id"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines), !rawBoard.isEmpty {
            if let uuid = UUID(uuidString: rawBoard) {
                targetBoardID = uuid
            } else if let board = try await resolveBoard(from: ["board_id": rawBoard]) {
                targetBoardID = board.id
            } else {
                return .error("Invalid `target_board_id`: \(rawBoard)")
            }
        }

        var inputs: [CaptureInput] = []
        let singleTitle = (args["title"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
        let singleNotes = (args["notes"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)

        if let filePaths = Self.stringArrayArg(args["file_paths"]), !filePaths.isEmpty {
            for raw in filePaths {
                let clean = raw.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !clean.isEmpty else { continue }
                let url = URL(fileURLWithPath: (clean as NSString).expandingTildeInPath)
                guard FileManager.default.fileExists(atPath: url.path) else {
                    return .error("File not found at path: \(url.path)")
                }
                inputs.append(.fileURL(url))
            }
        } else if let filePath = (args["file_path"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines), !filePath.isEmpty {
            let url = URL(fileURLWithPath: (filePath as NSString).expandingTildeInPath)
            guard FileManager.default.fileExists(atPath: url.path) else {
                return .error("File not found at path: \(url.path)")
            }
            inputs.append(.fileURL(url))
        }

        if let webURLStrings = Self.stringArrayArg(args["web_urls"]), !webURLStrings.isEmpty {
            for raw in webURLStrings {
                let clean = raw.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !clean.isEmpty else { continue }
                guard let url = URL(string: clean), url.scheme != nil else {
                    return .error("Invalid URL in `web_urls`: \(clean)")
                }
                let titleForURL = (webURLStrings.count == 1 && inputs.isEmpty && singleTitle?.isEmpty == false) ? singleTitle : nil
                inputs.append(.webURL(url, title: titleForURL, notes: singleNotes?.isEmpty == false ? singleNotes : nil))
            }
        } else if let webURLString = (args["web_url"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines), !webURLString.isEmpty {
            guard let url = URL(string: webURLString), url.scheme != nil else {
                return .error("Invalid `web_url`: \(webURLString)")
            }
            let titleForURL = (inputs.isEmpty && singleTitle?.isEmpty == false) ? singleTitle : nil
            inputs.append(.webURL(url, title: titleForURL, notes: singleNotes?.isEmpty == false ? singleNotes : nil))
        }

        if inputs.isEmpty,
           let text = (args["text"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty {
            let title = (singleTitle?.isEmpty == false ? singleTitle : nil) ?? "Agent 笔记"
            inputs.append(.textSnippet(title: title, text: text, sourceURL: nil))
        }

        guard !inputs.isEmpty else {
            return .error("Provide one of `file_path`, `file_paths`, `web_url`, `web_urls`, or `text`.")
        }

        var finalAssets = try await engine.ingest(inputs, targetFolderID: targetFolderID, targetBoardID: targetBoardID)
        let tags = Self.stringArrayArg(args["tags"]) ?? []
        let notes = args["notes"] as? String
        let rating = Self.intArg(args["rating"])
        if !finalAssets.isEmpty && (!tags.isEmpty || notes != nil || rating != nil) {
            let updated = try await engine.updateAssets(AssetBatchPatch(
                assetIDs: finalAssets.map(\.id),
                notes: notes,
                rating: rating,
                addTags: tags
            ))
            if !updated.isEmpty {
                finalAssets = updated
            }
        }

        // Refresh folder path map in case directory import created nested folders.
        let latestPaths = Self.buildFolderPaths(try await engine.fetchFolders())

        if notifyOnWrite && !finalAssets.isEmpty {
            ExternalAgentNotifier.postLibraryChanged(
                kind: targetBoardID != nil ? "boards" : "assets",
                boardID: targetBoardID,
                summary: "外部 Agent 已导入 \(finalAssets.count) 项素材"
            )
        }
        return .json([
            "importedCount": finalAssets.count,
            "assets": finalAssets.map { serializeAssetSummary($0, folderPathByID: latestPaths) }
        ])
    }

    private func handleComposeMoodboard(_ args: [String: Any]) async throws -> ToolOutput {
        let title = ((args["title"] as? String) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let subtitle = ((args["subtitle"] as? String) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let layoutRaw = ((args["layout_style"] as? String) ?? "magazine").lowercased()
        let layoutStyle = EditorialStyle(rawValue: layoutRaw) ?? .magazine
        let useFreeform = Self.boolArg(args["use_freeform"]) ?? false

        // Mode A: External Agent acts directly as Art Director with explicit sections or asset_ids.
        let explicitSections = args["sections"] as? [[String: Any]]
        let flatAssetIDs = try await resolveAssetUUIDList(args["asset_ids"])

        if (explicitSections != nil && !(explicitSections ?? []).isEmpty) || !flatAssetIDs.isEmpty {
            var orderedAssets: [AssetRecord] = []
            var seen: Set<UUID> = []
            var slotByAssetID: [UUID: Int] = [:]
            var slotToAsset: [Int: AssetRecord] = [:]

            func registerAsset(_ id: UUID) async throws -> Int? {
                if let existing = slotByAssetID[id] { return existing }
                guard let asset = try await engine.fetchAsset(id: id) else { return nil }
                let slot = orderedAssets.count + 1
                orderedAssets.append(asset)
                seen.insert(id)
                slotByAssetID[id] = slot
                slotToAsset[slot] = asset
                return slot
            }

            var sectionSpecs: [AgentBoardPlan.SectionSpec] = []
            if let rawSections = explicitSections, !rawSections.isEmpty {
                for sec in rawSections {
                    let secTitle = (sec["title"] as? String) ?? "精选参考"
                    let tint = GroupTint(rawValue: (sec["tint"] as? String)?.lowercased() ?? "neutral") ?? .neutral
                    let rationale = (sec["rationale"] as? String) ?? ""
                    let heroSet = Set(try await resolveAssetUUIDList(sec["hero_asset_ids"]))
                    let secIDs = try await resolveAssetUUIDList(sec["asset_ids"])
                    var picks: [AgentBoardPlan.SlotPick] = []
                    for aid in secIDs {
                        if let slot = try await registerAsset(aid) {
                            picks.append(AgentBoardPlan.SlotPick(
                                slot: slot,
                                weight: heroSet.contains(aid) ? 2 : 1,
                                reason: rationale
                            ))
                        }
                    }
                    if !picks.isEmpty {
                        sectionSpecs.append(AgentBoardPlan.SectionSpec(
                            title: secTitle,
                            tint: tint,
                            rationale: rationale,
                            picks: picks
                        ))
                    }
                }
            } else {
                let heroSet = Set(try await resolveAssetUUIDList(args["hero_asset_ids"]))
                var picks: [AgentBoardPlan.SlotPick] = []
                for (idx, aid) in flatAssetIDs.enumerated() {
                    if let slot = try await registerAsset(aid) {
                        let weight = (heroSet.contains(aid) || (heroSet.isEmpty && idx == 0)) ? 2 : 1
                        picks.append(AgentBoardPlan.SlotPick(slot: slot, weight: weight, reason: ""))
                    }
                }
                if !picks.isEmpty {
                    sectionSpecs.append(AgentBoardPlan.SectionSpec(
                        title: "核心视觉参考",
                        tint: .neutral,
                        rationale: "",
                        picks: picks
                    ))
                }
            }

            guard !sectionSpecs.isEmpty else {
                return .error("None of the provided `asset_ids` were found in the Charkle library.")
            }

            let noteText = ((args["curator_note"] as? String) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            let noteSpec = noteText.isEmpty
                ? nil
                : AgentBoardPlan.NoteSpec(title: "策展说明", text: noteText, style: .paper)

            let plan = AgentBoardPlan(
                boardTitle: title.isEmpty ? "Agent 策展情绪板" : title,
                boardSubtitle: subtitle,
                curatorNote: noteSpec,
                recommendedLayout: layoutStyle,
                sections: sectionSpecs,
                candidatePicks: [],
                rejectedNote: nil,
                visualInsights: []
            )
            let req = MoodboardCurationRequest(
                prompt: title,
                preferredCount: max(orderedAssets.count, 12),
                layoutStyle: layoutStyle,
                useFreeformLayout: useFreeform,
                includeCuratorNotes: noteSpec != nil
            )
            let recall = AgentRecallResult(
                eligibleTotal: orderedAssets.count,
                candidates: orderedAssets,
                scoresByID: Dictionary(uniqueKeysWithValues: orderedAssets.map { ($0.id, ScoredAsset(asset: $0, score: 1.0, matchReasons: ["Agent 精选"])) }),
                folderPathByID: [:]
            )
            let compiled = try await tools.compileAndVerifyBoard(
                plan: plan,
                slotToAsset: slotToAsset,
                request: req,
                recall: recall
            )
            let saved = try await engine.saveBoard(compiled.document)
            if notifyOnWrite {
                ExternalAgentNotifier.postLibraryChanged(kind: "boards", boardID: saved.id, summary: "外部 Agent 已创建情绪板「\(saved.title)」")
            }
            return .json([
                "boardID": saved.id.uuidString,
                "title": saved.title,
                "subtitle": saved.subtitle,
                "mode": Self.layoutModeLabel(saved.mode),
                "itemCount": saved.referencedAssetIDs.count,
                "paletteHexes": saved.extractedPalette.map { $0.hex.uppercased() }
            ])
        }

        // Mode B: Prompt-driven curation invoking Charkle's built-in Moodboard Agent Harness.
        let prompt = ((args["prompt"] as? String) ?? title).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !prompt.isEmpty else {
            return .error("Provide either `sections` / `asset_ids` for direct curation, or `prompt` for automatic curation.")
        }
        let folders = try await engine.fetchFolders()
        let folderPathByID = Self.buildFolderPaths(folders)
        let scopeID = try resolveOptionalFolderID(from: args, folders: folders, folderPathByID: folderPathByID)
        let preferredCount = max(2, min(24, Self.intArg(args["preferred_count"]) ?? 12))
        let seedIDs = try await resolveAssetUUIDList(args["seed_asset_ids"])
        let requiredTags = Self.stringArrayArg(args["required_tags"]) ?? []
        let targetPalette = (Self.stringArrayArg(args["target_palette"]) ?? []).map { LabColor.fromHex($0) }

        let req = MoodboardCurationRequest(
            prompt: prompt,
            seedAssetIDs: seedIDs,
            scopeFolderIDs: scopeID.map { [$0] } ?? [],
            requiredTags: requiredTags,
            targetPalette: targetPalette,
            preferredCount: preferredCount,
            layoutStyle: layoutStyle,
            useFreeformLayout: useFreeform,
            includeCuratorNotes: true
        )
        let proposal = try await engine.curateMoodboard(req, onStep: nil)
        var doc = proposal.draftDocument
        if !title.isEmpty { doc.title = title }
        if !subtitle.isEmpty { doc.subtitle = subtitle }
        let saved = try await engine.saveBoard(doc)
        if notifyOnWrite {
            ExternalAgentNotifier.postLibraryChanged(kind: "boards", boardID: saved.id, summary: "外部 Agent 已生成情绪板「\(saved.title)」")
        }
        return .json([
            "boardID": saved.id.uuidString,
            "title": saved.title,
            "subtitle": saved.subtitle,
            "mode": Self.layoutModeLabel(saved.mode),
            "itemCount": saved.referencedAssetIDs.count,
            "usedCloudAI": proposal.usedCloudAI,
            "curatedSummary": proposal.curatedSummary,
            "paletteHexes": saved.extractedPalette.map { $0.hex.uppercased() }
        ])
    }

    private func handlePatchMoodboard(_ args: [String: Any]) async throws -> ToolOutput {
        guard var doc = try await resolveBoard(from: args) else {
            return .error("Moodboard not found. Pass a valid `board_id` UUID or matching `title`.")
        }
        if let newTitle = (args["new_title"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines), !newTitle.isEmpty {
            doc.title = newTitle
        }
        if let newSubtitle = args["subtitle"] as? String {
            doc.subtitle = newSubtitle.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        if let useFreeform = Self.boolArg(args["use_freeform"]) {
            if useFreeform {
                doc.mode = .freeform
            } else {
                let styleRaw = ((args["layout_style"] as? String) ?? "magazine").lowercased()
                let style = EditorialStyle(rawValue: styleRaw) ?? .magazine
                doc.mode = .autoEditorial(AutoLayoutConfig(style: style))
            }
        } else if let styleRaw = (args["layout_style"] as? String)?.lowercased(),
                  let style = EditorialStyle(rawValue: styleRaw),
                  case .autoEditorial(var cfg) = doc.mode {
            cfg.style = style
            doc.mode = .autoEditorial(cfg)
        }

        // Remove unlocked nodes by asset UUID/prefix or explicit node UUID.
        let removeAssetSet = Set(try await resolveAssetUUIDList(args["remove_asset_ids"]))
        let removeNodeSet = Set(parseUUIDList(args["remove_node_ids"]))
        var removedCount = 0
        var skippedLockedAssetIDs: [String] = []
        var skippedLockedNodeIDs: [String] = []

        if !removeAssetSet.isEmpty || !removeNodeSet.isEmpty {
            var remaining: [BoardNode] = []
            remaining.reserveCapacity(doc.nodes.count)
            for node in doc.nodes {
                let matchesAsset = node.referencedAssetID.map { removeAssetSet.contains($0) } ?? false
                let matchesNode = removeNodeSet.contains(node.id)
                if matchesAsset || matchesNode {
                    if node.isLocked {
                        if matchesAsset, let aid = node.referencedAssetID {
                            skippedLockedAssetIDs.append(aid.uuidString)
                        }
                        if matchesNode {
                            skippedLockedNodeIDs.append(node.id.uuidString)
                        }
                        remaining.append(node)
                    } else {
                        removedCount += 1
                    }
                } else {
                    remaining.append(node)
                }
            }
            doc.nodes = remaining
            let survivingNodeIDs = Set(doc.nodes.map(\.id))
            doc.connectors.removeAll { !survivingNodeIDs.contains($0.fromNodeID) || !survivingNodeIDs.contains($0.toNodeID) }
        }

        // Compute non-overlapping baseline Y below existing board content.
        var cursorY = (doc.nodes.map(\.frame.maxY).max() ?? 16.0) + 24.0
        var nextZ = (doc.nodes.map(\.zIndex).max() ?? 0) + 1
        var nextOrder = (doc.nodes.map(\.editorialOrder).max() ?? 0) + 1
        let leftMargin = 32.0
        let canvasWidth = 1108.0

        // Optional section header
        if let sectionTitle = (args["add_section"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines), !sectionTitle.isEmpty {
            let tint = GroupTint(rawValue: ((args["section_tint"] as? String) ?? "neutral").lowercased()) ?? .neutral
            doc.nodes.append(BoardNode(
                kind: .groupFrame(title: String(sectionTitle.prefix(72)), tint: tint),
                frame: BoardRect(x: leftMargin, y: cursorY, width: canvasWidth, height: 60),
                zIndex: nextZ,
                editorialOrder: nextOrder
            ))
            nextZ += 1
            nextOrder += 1
            cursorY += 76
        }

        // Append new asset cards in clean non-overlapping rows.
        let addIDs = try await resolveAssetUUIDList(args["add_asset_ids"])
        var addedCount = 0
        var skippedMissingAssetIDs: [String] = []
        if !addIDs.isEmpty {
            var existing = Set(doc.referencedAssetIDs)
            var toAppend: [AssetRecord] = []
            for aid in addIDs where !existing.contains(aid) {
                if let asset = try await engine.fetchAsset(id: aid) {
                    existing.insert(aid)
                    toAppend.append(asset)
                } else {
                    skippedMissingAssetIDs.append(aid.uuidString)
                }
            }

            let gap = 18.0
            let perRow = 4
            var rowStart = 0
            while rowStart < toAppend.count {
                let row = Array(toAppend[rowStart..<min(rowStart + perRow, toAppend.count)])
                let colWidth = (canvasWidth - gap * Double(perRow - 1)) / Double(perRow)
                var rowMaxHeight = 160.0
                for (col, asset) in row.enumerated() {
                    let ratio = max(0.6, min(1.9, asset.aspectRatio))
                    let h = min(360.0, max(140.0, colWidth / ratio))
                    rowMaxHeight = max(rowMaxHeight, h)
                    let x = leftMargin + Double(col) * (colWidth + gap)
                    doc.nodes.append(BoardNode(
                        kind: .assetRef(
                            assetID: asset.id,
                            crop: nil,
                            weight: 1,
                            autoplayLoop: asset.mediaKind == .animatedImage || asset.mediaKind == .video
                        ),
                        frame: BoardRect(x: x, y: cursorY, width: colWidth, height: h),
                        zIndex: nextZ,
                        editorialOrder: nextOrder
                    ))
                    nextZ += 1
                    nextOrder += 1
                    addedCount += 1
                }
                cursorY += rowMaxHeight + gap
                rowStart += perRow
            }
        }

        // Optional curator note placed cleanly below appended cards (never colliding at (40,40)).
        if let noteText = (args["add_note"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines), !noteText.isEmpty {
            let noteTitle = (args["note_title"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
            let noteStyle = NoteStyle(rawValue: ((args["note_style"] as? String) ?? "paper").lowercased()) ?? .paper
            doc.nodes.append(BoardNode(
                kind: .note(title: noteTitle?.isEmpty == false ? noteTitle : "Agent 批注", text: noteText, style: noteStyle, fontSize: 13.5),
                frame: BoardRect(x: leftMargin, y: cursorY, width: 360, height: 148),
                zIndex: nextZ,
                editorialOrder: nextOrder
            ))
        }

        let palette = try await engine.extractBoardPalette(assetIDs: doc.referencedAssetIDs, count: 6)
        if !palette.isEmpty {
            doc.extractedPalette = palette
            for idx in doc.nodes.indices {
                if case .paletteStrip(_, let autoSync) = doc.nodes[idx].kind, autoSync {
                    doc.nodes[idx].kind = .paletteStrip(colors: palette, autoSyncWithBoard: true)
                }
            }
        }
        doc.updatedAt = Date()
        let saved = try await engine.saveBoard(doc)
        if notifyOnWrite {
            ExternalAgentNotifier.postLibraryChanged(kind: "boards", boardID: saved.id, summary: "外部 Agent 已更新情绪板「\(saved.title)」")
        }

        var result: [String: Any] = [
            "boardID": saved.id.uuidString,
            "title": saved.title,
            "mode": Self.layoutModeLabel(saved.mode),
            "itemCount": saved.referencedAssetIDs.count,
            "addedCount": addedCount,
            "removedCount": removedCount,
            "paletteHexes": saved.extractedPalette.map { $0.hex.uppercased() }
        ]
        if !skippedLockedAssetIDs.isEmpty { result["skippedLockedAssetIDs"] = skippedLockedAssetIDs }
        if !skippedLockedNodeIDs.isEmpty { result["skippedLockedNodeIDs"] = skippedLockedNodeIDs }
        if !skippedMissingAssetIDs.isEmpty { result["skippedMissingAssetIDs"] = skippedMissingAssetIDs }
        return .json(result)
    }

    private func handleTrashAssets(_ args: [String: Any]) async throws -> ToolOutput {
        let ids = try await resolveAssetUUIDList(args["asset_ids"])
        guard !ids.isEmpty else {
            return .error("`asset_ids` must be a non-empty array of asset UUID strings or prefixes.")
        }
        let trashed = Self.boolArg(args["trashed"]) ?? true
        let updated = try await engine.updateAssets(AssetBatchPatch(assetIDs: ids, isTrashed: trashed))
        let updatedSet = Set(updated.map(\.id))
        let skippedIDs = ids.filter { !updatedSet.contains($0) }.map(\.uuidString)

        if notifyOnWrite && !updated.isEmpty {
            ExternalAgentNotifier.postLibraryChanged(
                kind: "assets",
                summary: trashed ? "外部 Agent 已将 \(updated.count) 项素材移入回收站" : "外部 Agent 已从回收站恢复 \(updated.count) 项素材"
            )
        }
        var result: [String: Any] = [
            "updatedCount": updated.count,
            "trashed": trashed,
            "assetIDs": updated.map { $0.id.uuidString },
            "note": "Soft Trash only; external agents can never permanently delete assets."
        ]
        if !skippedIDs.isEmpty {
            result["skippedIDs"] = skippedIDs
        }
        return .json(result)
    }

    private func handleAnalyzeAssets(_ args: [String: Any]) async throws -> ToolOutput {
        let ids = Array((try await resolveAssetUUIDList(args["asset_ids"])).prefix(20))
        guard !ids.isEmpty else {
            return .error("`asset_ids` must be a non-empty array of asset UUID strings or prefixes (max 20).")
        }
        let refreshRich = Self.boolArg(args["refresh_rich_metadata"]) ?? false
        var analyzed = try await engine.analyzeAssetsLocally(ids: ids)

        if refreshRich {
            var refreshedList: [AssetRecord] = []
            for asset in analyzed {
                if asset.mediaKind == .webBookmark, asset.sourceURL != nil,
                   let updated = try? await engine.refreshRichAsset(id: asset.id) {
                    refreshedList.append(updated)
                } else {
                    refreshedList.append(asset)
                }
            }
            analyzed = refreshedList
        }

        let folders = try await engine.fetchFolders()
        let folderPathByID = Self.buildFolderPaths(folders)
        if notifyOnWrite && !analyzed.isEmpty {
            ExternalAgentNotifier.postLibraryChanged(kind: "assets", summary: "外部 Agent 已重新分析 \(analyzed.count) 项素材")
        }
        return .json([
            "analyzedCount": analyzed.count,
            "refreshedRichMetadata": refreshRich,
            "assets": analyzed.map { serializeAssetSummary($0, folderPathByID: folderPathByID) }
        ])
    }

    // MARK: - Helpers

    private enum ExportPathCheck {
        case allowed(URL)
        case rejected(String)
    }

    /// Validates external-agent `output_path` disk writes against permission policy, file extension,
    /// dotfiles, symlink traversal, and protected system/application directories.
    private func validateExportOutputPath(
        _ rawPath: String,
        allowedExtensions: Set<String>,
        policy: ExternalAgentConfig,
        channel: ExternalAgentChannel
    ) -> ExportPathCheck {
        guard policy.allowsWrite(for: channel) else {
            return .rejected("当前 Charkle 外部 Agent 权限为「仅只读检索与导出」，不允许通过 output_path 写入本机文件。请移除 output_path 直接获取内联图像，或在 Charkle「设置 → 外部 Agent」中切换为「允许整理与生成情绪板」。")
        }
        guard !rawPath.contains("\0") else {
            return .rejected("Invalid output_path containing NUL character.")
        }

        let expanded = (rawPath as NSString).expandingTildeInPath
        let standardized = URL(fileURLWithPath: expanded).standardizedFileURL
        let fileName = standardized.lastPathComponent
        guard !fileName.isEmpty, fileName != ".", fileName != "..", !fileName.hasPrefix(".") else {
            return .rejected("Refusing to write to hidden or invalid filename: \(fileName)")
        }

        let ext = standardized.pathExtension.lowercased()
        guard allowedExtensions.contains(ext) else {
            let expected = allowedExtensions.sorted().map { ".\($0)" }.joined(separator: ", ")
            return .rejected("output_path extension must be one of \(expected), got '.\(ext)'.")
        }

        let fm = FileManager.default
        if let attrs = try? fm.attributesOfItem(atPath: standardized.path),
           let fileType = attrs[.type] as? FileAttributeType,
           fileType == .typeDirectory || fileType == .typeSymbolicLink {
            return .rejected("Refusing to overwrite an existing directory or symbolic link at output_path.")
        }

        var trailingComponents: [String] = [fileName]
        var probe = standardized.deletingLastPathComponent()
        while !fm.fileExists(atPath: probe.path) {
            let parent = probe.deletingLastPathComponent()
            if parent.path == probe.path { break }
            trailingComponents.insert(probe.lastPathComponent, at: 0)
            probe = parent
        }
        var resolved = probe.resolvingSymlinksInPath()
        for component in trailingComponents {
            resolved.appendPathComponent(component)
        }
        let resolvedURL = resolved.standardizedFileURL
        let resolvedPath = resolvedURL.path

        let blockedSegments: Set<String> = [".ssh", ".gnupg", ".aws", ".git", ".kube", ".config"]
        if resolvedURL.pathComponents.contains(where: { blockedSegments.contains($0) }) {
            return .rejected("Refusing to write inside a protected hidden directory.")
        }

        let protectedRoots: [String] = [
            configDirectory.resolvingSymlinksInPath().standardizedFileURL.path,
            URL(fileURLWithPath: NSHomeDirectory()).appending(path: "Library").resolvingSymlinksInPath().standardizedFileURL.path,
            "/System",
            "/Library",
            "/Applications",
            "/usr",
            "/bin",
            "/sbin",
            "/etc",
            "/private/etc"
        ]
        for root in protectedRoots {
            let prefix = root.hasSuffix("/") ? root : root + "/"
            if resolvedPath == root || resolvedPath.hasPrefix(prefix) {
                return .rejected("Refusing to write inside protected system or application directory.")
            }
        }

        return .allowed(resolvedURL)
    }

    private func resolveBoard(from args: [String: Any]) async throws -> MoodboardDocument? {
        if let rawID = (args["board_id"] as? String ?? args["id"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
           !rawID.isEmpty {
            if let uuid = UUID(uuidString: rawID) {
                return try await engine.fetchBoard(id: uuid)
            }
            let upper = rawID.uppercased()
            if upper.count >= 8 {
                let boards = try await engine.fetchBoards()
                let matches = boards.filter { $0.id.uuidString.hasPrefix(upper) }
                if matches.count == 1 {
                    return try await engine.fetchBoard(id: matches[0].id)
                }
                if matches.count > 1 {
                    throw LibraryDatabaseError("Ambiguous board_id prefix '\(rawID)' matched \(matches.count) boards; provide more characters.")
                }
            }
        }
        if let title = (args["title"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines), !title.isEmpty {
            let boards = try await engine.fetchBoards()
            if let exact = boards.first(where: { $0.title.caseInsensitiveCompare(title) == .orderedSame }) {
                return try await engine.fetchBoard(id: exact.id)
            }
            if let partial = boards.first(where: { $0.title.localizedCaseInsensitiveContains(title) }) {
                return try await engine.fetchBoard(id: partial.id)
            }
        }
        return nil
    }

    private func resolveOptionalSmartFolder(from args: [String: Any]) async throws -> SmartFolderRecord? {
        let rawID = (args["smart_folder_id"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let rawName = (args["smart_folder_name"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !rawID.isEmpty || !rawName.isEmpty else { return nil }

        let all = try await engine.fetchSmartFolders()
        if !rawID.isEmpty {
            if let uuid = UUID(uuidString: rawID) {
                guard let found = all.first(where: { $0.id == uuid }) else {
                    throw LibraryDatabaseError("Smart folder not found: \(rawID)")
                }
                return found
            }
            let upper = rawID.uppercased()
            if upper.count >= 8 {
                let matches = all.filter { $0.id.uuidString.hasPrefix(upper) }
                if matches.count == 1 { return matches[0] }
                if matches.count > 1 {
                    throw LibraryDatabaseError("Ambiguous smart_folder_id prefix '\(rawID)'.")
                }
            }
            throw LibraryDatabaseError("Invalid smart_folder_id UUID: \(rawID)")
        }
        if let exact = all.first(where: { $0.name.caseInsensitiveCompare(rawName) == .orderedSame }) {
            return exact
        }
        if let partial = all.first(where: { $0.name.localizedCaseInsensitiveContains(rawName) }) {
            return partial
        }
        throw LibraryDatabaseError("Smart folder not found: \(rawName)")
    }

    private func buildFilterCriteria(
        from args: [String: Any],
        folders: [FolderRecord],
        folderPathByID: [UUID: String]
    ) throws -> FilterCriteria {
        let query = ((args["query"] as? String) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let tags = Set(Self.stringArrayArg(args["tags"]) ?? [])
        let colorHex = (args["color_hex"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
        let colorTolerance = Self.doubleArg(args["color_tolerance"]) ?? 28.0
        let minRating = Self.intArg(args["min_rating"]) ?? 0
        let onlyInbox = Self.boolArg(args["only_inbox"]) ?? false
        let onlyUntagged = Self.boolArg(args["only_untagged"]) ?? false
        let includeSubfolders = Self.boolArg(args["include_subfolders"]) ?? true
        let onlyRecentDays = Self.intArg(args["only_recent_days"]).map { max(1, $0) }
        let onlyPinnedOffline = Self.boolArg(args["only_pinned_offline"]) ?? false
        let onlyTrashed = Self.boolArg(args["only_trashed"]) ?? false
        let includeTrashed = (Self.boolArg(args["include_trashed"]) ?? false) || onlyTrashed
        let folderID = try resolveOptionalFolderID(from: args, folders: folders, folderPathByID: folderPathByID)
        let kinds = Self.parseMediaKinds(args["media_kinds"])
        let shape = (args["aspect_shape"] as? String).flatMap { AspectShape(rawValue: $0.trimmingCharacters(in: .whitespacesAndNewlines)) }
        let defaultSort: SortOrder = query.isEmpty ? .newest : .relevance
        let sortBy = Self.parseSortOrder(args["sort_by"], defaultOrder: defaultSort)

        return FilterCriteria(
            searchQuery: query,
            kinds: kinds,
            selectedColorHex: colorHex?.isEmpty == false ? colorHex : nil,
            colorTolerance: colorTolerance,
            shape: shape,
            minRating: minRating,
            tags: tags,
            folderID: onlyInbox ? nil : folderID,
            includeSubfolders: includeSubfolders,
            onlyInbox: onlyInbox,
            onlyUntagged: onlyUntagged,
            onlyRecentDays: onlyRecentDays,
            onlyPinnedOffline: onlyPinnedOffline,
            includeTrashed: includeTrashed,
            onlyTrashed: onlyTrashed,
            sortBy: sortBy
        )
    }

    private func resolveOptionalFolderID(
        from args: [String: Any],
        folders: [FolderRecord],
        folderPathByID: [UUID: String]
    ) throws -> UUID? {
        if let rawID = (args["folder_id"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines), !rawID.isEmpty {
            if let uuid = UUID(uuidString: rawID) {
                return uuid
            }
            let upper = rawID.uppercased()
            if upper.count >= 8 {
                let matches = folders.filter { $0.id.uuidString.hasPrefix(upper) }
                if matches.count == 1 { return matches[0].id }
                if matches.count > 1 {
                    throw LibraryDatabaseError("Ambiguous folder_id prefix '\(rawID)' matched \(matches.count) folders.")
                }
            }
            throw LibraryDatabaseError("Invalid folder_id UUID or prefix: \(rawID)")
        }
        if let path = (args["folder_path"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines), !path.isEmpty {
            if let exact = folderPathByID.first(where: { $0.value.caseInsensitiveCompare(path) == .orderedSame }) {
                return exact.key
            }
            if let byName = folders.first(where: { $0.name.caseInsensitiveCompare(path) == .orderedSame }) {
                return byName.id
            }
            throw LibraryDatabaseError("Folder not found: \(path)")
        }
        return nil
    }

    private enum AssetDetailLevel: String, Sendable {
        case visual
        case compact
        case standard
        case full

        static func parse(_ raw: Any?, fallback: AssetDetailLevel = .compact) -> AssetDetailLevel {
            guard let str = (raw as? String)?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(),
                  let parsed = AssetDetailLevel(rawValue: str) else {
                return fallback
            }
            return parsed
        }
    }

    /// Resolves either a full 36-char RFC-4122 UUID or a unique 8+ char uppercase hex prefix against SQLite primary key.
    private func resolveAssetUUID(_ raw: String) async throws -> UUID? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        if let uuid = UUID(uuidString: trimmed) {
            return uuid
        }
        let upper = trimmed.uppercased()
        guard upper.count >= 8,
              upper.allSatisfy({ $0.isHexDigit || $0 == "-" }) else {
            return nil
        }
        let matches = try await engine.database.assetIDs(matchingPrefix: upper, limit: 5)
        if matches.count == 1 {
            return matches[0]
        }
        if matches.count > 1 {
            let preview = matches.prefix(3).map { String($0.uuidString.prefix(13)) }.joined(separator: ", ")
            throw LibraryDatabaseError("Ambiguous asset ID prefix '\(trimmed)' matched multiple assets (\(preview)); pass more characters.")
        }
        return nil
    }

    private func resolveAssetUUIDList(_ raw: Any?) async throws -> [UUID] {
        guard let list = Self.stringArrayArg(raw), !list.isEmpty else { return [] }
        var resolved: [UUID] = []
        resolved.reserveCapacity(list.count)
        for item in list {
            if let uuid = try await resolveAssetUUID(item) {
                resolved.append(uuid)
            }
        }
        return resolved
    }

    private struct MultiQueryRecallResult {
        let hits: [(hit: SemanticSearchHit, queryGroup: String)]
        let groupsSummary: [[String: Any]]
        let totalUniqueMatched: Int
    }

    /// Runs fast local multi-signal recall for 2..6 creative sub-queries and merges balanced non-duplicate slots
    /// so an agent can cover multiple moodboard roles in ONE call and ONE Contact Sheet image.
    private func runMultiQueryRecall(
        queries: [String],
        criteria: FilterCriteria,
        args: [String: Any],
        seedIDs: [UUID],
        unlikeIDs: [UUID],
        limit: Int,
        diversify: Bool
    ) async throws -> MultiQueryRecallResult {
        let cappedQueries = Array(queries.prefix(6))
        guard !cappedQueries.isEmpty else {
            return MultiQueryRecallResult(hits: [], groupsSummary: [], totalUniqueMatched: 0)
        }
        let perGroupQuota = max(1, Int(ceil(Double(limit) / Double(cappedQueries.count))))
        let fetchPerGroup = max(perGroupQuota * 3, 18)

        var seenIDs = Set<UUID>()
        var allUniqueMatched = Set<UUID>()
        var merged: [(hit: SemanticSearchHit, queryGroup: String)] = []
        var groupsSummary: [[String: Any]] = []

        for q in cappedQueries {
            let report = try await engine.semanticSearch(
                query: q,
                criteria: criteria,
                limit: fetchPerGroup,
                allowVisualRerank: false,
                seedAssetIDs: seedIDs,
                unlikeAssetIDs: unlikeIDs
            )
            let postFilteredIDs = Set((try await applyPostFilters(report.hits.map(\.asset), args: args)).map(\.id))
            var groupHits = report.hits.filter { postFilteredIDs.contains($0.asset.id) }
            for h in groupHits { allUniqueMatched.insert(h.asset.id) }
            groupHits.removeAll { seenIDs.contains($0.asset.id) }

            let chosenHits: [SemanticSearchHit]
            if diversify && groupHits.count > 1 {
                let divAssets = await diversifyAssets(groupHits.map(\.asset), limit: perGroupQuota)
                let byID = Dictionary(uniqueKeysWithValues: groupHits.map { ($0.asset.id, $0) })
                chosenHits = divAssets.compactMap { byID[$0.id] }
            } else {
                chosenHits = Array(groupHits.prefix(perGroupQuota))
            }

            let startSlot = merged.count + 1
            var badges: [String] = []
            for h in chosenHits where merged.count < limit {
                if seenIDs.insert(h.asset.id).inserted {
                    merged.append((h, q))
                    badges.append(String(format: "#%02d", merged.count))
                }
            }
            var summary: [String: Any] = [
                "query": q,
                "count": badges.count
            ]
            if !badges.isEmpty {
                summary["slotRange"] = badges.count == 1 ? badges[0] : "\(String(format: "#%02d", startSlot))..\(badges.last ?? "")"
            }
            groupsSummary.append(summary)
        }

        return MultiQueryRecallResult(
            hits: merged,
            groupsSummary: groupsSummary,
            totalUniqueMatched: allUniqueMatched.count
        )
    }

    private struct FolderProfile: Sendable {
        let directCount: Int
        let recursiveCount: Int
        let topTags: [String]
        let palette: [String]
        let dominantAspect: String?
    }

    private struct AttachedContactSheet: Sendable {
        let jpegData: Data
        let width: Int
        let height: Int
        let slotCount: Int
        let bytes: Int
        let savedPath: String?

        var summary: [String: Any] {
            var dict: [String: Any] = [
                "width": width,
                "height": height,
                "slotCount": slotCount,
                "bytes": bytes
            ]
            if let savedPath {
                dict["savedPath"] = savedPath
            }
            return dict
        }
    }

    private func renderAttachedContactSheet(
        for assets: [AssetRecord],
        maxWidth: Int,
        jpegQuality: Double = 0.74,
        outputURL: URL?
    ) throws -> AttachedContactSheet? {
        guard !assets.isEmpty else { return nil }
        let entries: [ContactSheetRenderer.Entry] = assets.enumerated().map { idx, asset in
            let thumbURL = engine.media.thumbnailURL(for: asset.id, tier: .grid520)
                ?? engine.media.thumbnailURL(for: asset.id, tier: .preview1400)
            return ContactSheetRenderer.Entry(slot: idx + 1, asset: asset, thumbnailURL: thumbURL)
        }
        guard let sheet = ContactSheetRenderer.render(entries: entries, maxCanvasWidth: maxWidth, jpegQuality: jpegQuality) else {
            return nil
        }
        var savedPath: String?
        if let outputURL {
            try FileManager.default.createDirectory(at: outputURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try sheet.jpegData.write(to: outputURL, options: .atomic)
            savedPath = outputURL.path
        }
        return AttachedContactSheet(
            jpegData: sheet.jpegData,
            width: sheet.width,
            height: sheet.height,
            slotCount: sheet.orderedSlots.count,
            bytes: sheet.jpegData.count,
            savedPath: savedPath
        )
    }

    private func applyPostFilters(_ assets: [AssetRecord], args: [String: Any]) async throws -> [AssetRecord] {
        let anyTags = Set((Self.stringArrayArg(args["any_tags"]) ?? []).map(SearchText.normalize).filter { !$0.isEmpty })
        let excludeTags = Set((Self.stringArrayArg(args["exclude_tags"]) ?? []).map(SearchText.normalize).filter { !$0.isEmpty })
        let excludeIDs = Set(try await resolveAssetUUIDList(args["exclude_asset_ids"]))
        let tones: [VisualTone] = {
            if let single = args["tone"] as? String {
                return single.split(separator: ",").compactMap { VisualTone.parse(String($0)) }
            }
            if let arr = Self.stringArrayArg(args["tone"]) {
                return arr.compactMap { VisualTone.parse($0) }
            }
            return []
        }()
        guard !anyTags.isEmpty || !excludeTags.isEmpty || !excludeIDs.isEmpty || !tones.isEmpty else {
            return assets
        }
        return assets.filter { asset in
            if excludeIDs.contains(asset.id) { return false }
            if !anyTags.isEmpty || !excludeTags.isEmpty {
                let assetTags = Set((asset.tags + asset.suggestedTags).map(SearchText.normalize))
                if !anyTags.isEmpty && assetTags.isDisjoint(with: anyTags) { return false }
                if !excludeTags.isEmpty && !assetTags.isDisjoint(with: excludeTags) { return false }
            }
            if !tones.isEmpty && !tones.allSatisfy({ $0.matches(asset) }) {
                return false
            }
            return true
        }
    }

    /// Suppresses visual near-duplicates (Apple Vision FeaturePrint distance < 0.22 + identical contentHash)
    /// and interleaves candidates across folders in round-robin passes (while preserving the #1 top match first)
    /// so even the top 5–16 tiles cover maximum visual and stylistic variety.
    private func diversifyAssets(_ assets: [AssetRecord], limit: Int) async -> [AssetRecord] {
        guard assets.count > 1, limit > 1 else {
            return Array(assets.prefix(limit))
        }
        let featurePrints = (try? await engine.database.featurePrints()) ?? [:]
        let probePool = Array(assets.prefix(max(limit * 6, 96)))

        // 1. First filter visual near-duplicates in relevance order using pre-unarchived Vision observations
        var deduped: [AssetRecord] = []
        deduped.reserveCapacity(min(probePool.count, limit * 3))
        var selectedHashes = Set<String>()
        var selectedPrints: [VNFeaturePrintObservation] = []
        for candidate in probePool {
            if !candidate.contentHash.isEmpty && selectedHashes.contains(candidate.contentHash) {
                continue
            }
            var duplicate = false
            let candidateObs = featurePrints[candidate.id].flatMap(VisionAnalyzer.unarchiveFeaturePrint)
            if let candidateObs {
                for chosenPrint in selectedPrints {
                    if let dist = VisionAnalyzer.visualDistance(between: candidateObs, and: chosenPrint), dist < 0.22 {
                        duplicate = true
                        break
                    }
                }
            }
            if duplicate { continue }
            deduped.append(candidate)
            if !candidate.contentHash.isEmpty { selectedHashes.insert(candidate.contentHash) }
            if let candidateObs { selectedPrints.append(candidateObs) }
            if deduped.count >= max(limit * 3, 48) { break }
        }

        // 2. Round-robin interleave across folders (ordered by each folder's best-ranked candidate)
        var folderOrder: [UUID?] = []
        var buckets: [UUID?: [AssetRecord]] = [:]
        for asset in deduped {
            if buckets[asset.folderID] == nil {
                folderOrder.append(asset.folderID)
            }
            buckets[asset.folderID, default: []].append(asset)
        }
        guard folderOrder.count >= 2 else {
            return Array(deduped.prefix(limit))
        }

        var selected: [AssetRecord] = []
        selected.reserveCapacity(min(limit, deduped.count))
        var cursorByFolder: [UUID?: Int] = [:]
        // Keep the top-ranked #1 item first, then interleave round-by-round across distinct folders
        let perFolderPerRound = folderOrder.count >= 4 ? 1 : 2
        while selected.count < limit {
            var progressed = false
            for fid in folderOrder where selected.count < limit {
                guard let list = buckets[fid] else { continue }
                var idx = cursorByFolder[fid] ?? 0
                let end = min(list.count, idx + perFolderPerRound)
                while idx < end && selected.count < limit {
                    selected.append(list[idx])
                    idx += 1
                    progressed = true
                }
                cursorByFolder[fid] = idx
            }
            if !progressed { break }
        }
        return selected
    }

    private static func computeResultFacets(
        _ assets: [AssetRecord],
        folderPathByID: [UUID: String]
    ) -> [String: Any] {
        var folderCounts: [String: Int] = [:]
        var tagCounts: [String: Int] = [:]
        var shapeCounts: [String: Int] = [:]
        var colorWeights: [String: Double] = [:]

        for asset in assets {
            let folder = asset.folderID.flatMap { folderPathByID[$0] } ?? "Inbox"
            folderCounts[folder, default: 0] += 1
            shapeCounts[asset.aspectShape.rawValue, default: 0] += 1
            for tag in asset.tags {
                tagCounts[tag, default: 0] += 1
            }
            if let primary = asset.dominantColors.first {
                colorWeights[quantizedHexBucket(primary.hex), default: 0] += max(0.1, primary.proportion)
            }
        }

        let topFolders = folderCounts
            .sorted { $0.value != $1.value ? $0.value > $1.value : $0.key < $1.key }
            .prefix(6)
            .map { ["path": $0.key, "count": $0.value] as [String: Any] }
        let topTags = tagCounts
            .sorted { $0.value != $1.value ? $0.value > $1.value : $0.key < $1.key }
            .prefix(10)
            .map { ["name": $0.key, "count": $0.value] as [String: Any] }
        let topColors = colorWeights
            .sorted { $0.value > $1.value }
            .prefix(5)
            .map(\.key)

        var facets: [String: Any] = [
            "topFolders": topFolders,
            "topTags": topTags,
            "aspectShapes": shapeCounts
        ]
        if !topColors.isEmpty {
            facets["topColors"] = topColors
        }
        return facets
    }

    private static func buildFolderProfiles(
        folders: [FolderRecord],
        assets: [AssetRecord]
    ) -> [UUID: FolderProfile] {
        let childrenByParent = Dictionary(grouping: folders) { $0.parentID }
        var directAssetsByFolder: [UUID: [AssetRecord]] = [:]
        for asset in assets {
            if let fid = asset.folderID {
                directAssetsByFolder[fid, default: []].append(asset)
            }
        }

        // Memoized subtree IDs per folder
        var subtreeCache: [UUID: [UUID]] = [:]
        func subtreeIDs(for root: UUID) -> [UUID] {
            if let cached = subtreeCache[root] { return cached }
            var result: [UUID] = [root]
            var seen: Set<UUID> = [root]
            var queue: [UUID] = [root]
            var idx = 0
            while idx < queue.count {
                let cur = queue[idx]
                idx += 1
                for child in childrenByParent[cur, default: []] where seen.insert(child.id).inserted {
                    result.append(child.id)
                    queue.append(child.id)
                }
            }
            subtreeCache[root] = result
            return result
        }

        var profiles: [UUID: FolderProfile] = [:]
        for folder in folders {
            let direct = directAssetsByFolder[folder.id] ?? []
            let subtree = subtreeIDs(for: folder.id)
            var recursiveCount = 0
            var tagCounts: [String: Int] = [:]
            var shapeCounts: [String: Int] = [:]
            var colorBuckets: [String: Double] = [:]
            var representativeHexByBucket: [String: String] = [:]

            for fid in subtree {
                guard let bucketAssets = directAssetsByFolder[fid] else { continue }
                recursiveCount += bucketAssets.count
                for asset in bucketAssets {
                    shapeCounts[asset.aspectShape.rawValue, default: 0] += 1
                    for tag in asset.tags {
                        tagCounts[tag, default: 0] += 1
                    }
                    if let c = asset.dominantColors.first {
                        let key = quantizedHexBucket(c.hex)
                        colorBuckets[key, default: 0] += max(0.15, c.proportion)
                        if representativeHexByBucket[key] == nil {
                            representativeHexByBucket[key] = c.hex.uppercased()
                        }
                    }
                }
            }

            let topTags = tagCounts
                .sorted { $0.value != $1.value ? $0.value > $1.value : $0.key < $1.key }
                .prefix(5)
                .map(\.key)
            let palette = colorBuckets
                .sorted { $0.value > $1.value }
                .prefix(3)
                .compactMap { representativeHexByBucket[$0.key] ?? $0.key }
            var dominantAspect: String?
            if recursiveCount >= 3, let topShape = shapeCounts.max(by: { $0.value < $1.value }) {
                if Double(topShape.value) / Double(recursiveCount) >= 0.60 {
                    dominantAspect = topShape.key
                }
            }

            profiles[folder.id] = FolderProfile(
                directCount: direct.count,
                recursiveCount: recursiveCount,
                topTags: topTags,
                palette: palette,
                dominantAspect: dominantAspect
            )
        }
        return profiles
    }

    /// Quantizes a 6-char hex color to a coarse 4-bit-per-channel bucket so similar hues aggregate cleanly.
    private static func quantizedHexBucket(_ hex: String) -> String {
        let cleaned = hex.trimmingCharacters(in: .whitespacesAndNewlines).replacingOccurrences(of: "#", with: "")
        guard cleaned.count == 6, let val = UInt32(cleaned, radix: 16) else { return hex.uppercased() }
        let r = ((val >> 16) & 0xFF) & 0xE0
        let g = ((val >> 8) & 0xFF) & 0xE0
        let b = (val & 0xFF) & 0xE0
        return String(format: "#%02X%02X%02X", r + 16, g + 16, b + 16)
    }

    private func serializeAssetSummary(
        _ asset: AssetRecord,
        folderPathByID: [UUID: String],
        detail: AssetDetailLevel = .compact
    ) -> [String: Any] {
        let folderPath = asset.folderID.flatMap { folderPathByID[$0] } ?? "Inbox"

        if detail == .visual {
            var dict: [String: Any] = [
                "id": String(asset.id.uuidString.prefix(8)),
                "title": Self.truncateText(asset.title, maxChars: 42),
                "folderPath": folderPath
            ]
            if asset.pixelWidth > 0 && asset.pixelHeight > 0 {
                dict["dimensions"] = "\(asset.pixelWidth)x\(asset.pixelHeight)"
            } else {
                dict["aspectShape"] = asset.aspectShape.rawValue
            }
            if asset.mediaKind != .image {
                dict["mediaKind"] = asset.mediaKind.rawValue
            }
            if asset.rating > 0 {
                dict["rating"] = asset.rating
            }
            return dict
        }

        let roundedRatio = (asset.aspectRatio * 100).rounded() / 100

        if detail == .full {
            var dict: [String: Any] = [
                "id": asset.id.uuidString,
                "title": asset.title,
                "fileName": asset.fileName,
                "mediaKind": asset.mediaKind.rawValue,
                "folderID": asset.folderID?.uuidString ?? "",
                "folderPath": folderPath,
                "tags": asset.tags,
                "rating": asset.rating,
                "aspectRatio": roundedRatio,
                "aspectShape": asset.aspectShape.rawValue,
                "dominantColors": asset.dominantColors.prefix(5).map { $0.hex.uppercased() },
                "aiDescription": asset.aiDescription ?? "",
                "notes": asset.notes,
                "sourceURL": asset.sourceURL ?? ""
            ]
            if asset.pixelWidth > 0 && asset.pixelHeight > 0 {
                dict["dimensions"] = "\(asset.pixelWidth)x\(asset.pixelHeight)"
            }
            return dict
        }

        var dict: [String: Any] = [
            "id": asset.id.uuidString,
            "title": asset.title,
            "mediaKind": asset.mediaKind.rawValue,
            "folderPath": folderPath,
            "aspectRatio": roundedRatio,
            "aspectShape": asset.aspectShape.rawValue
        ]
        if asset.pixelWidth > 0 && asset.pixelHeight > 0 {
            dict["dimensions"] = "\(asset.pixelWidth)x\(asset.pixelHeight)"
        }
        if asset.rating > 0 {
            dict["rating"] = asset.rating
        }
        if !asset.tags.isEmpty {
            dict["tags"] = asset.tags
        }
        let colorCap = detail == .compact ? 3 : 5
        let colors = asset.dominantColors.prefix(colorCap).map { $0.hex.uppercased() }
        if !colors.isEmpty {
            dict["dominantColors"] = colors
        }
        let desc = (asset.aiDescription ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        if !desc.isEmpty {
            dict["aiDescription"] = detail == .compact ? Self.truncateText(desc, maxChars: 160) : desc
        }

        if detail == .standard {
            if let fid = asset.folderID { dict["folderID"] = fid.uuidString }
            dict["fileName"] = asset.fileName
            let notesClean = Self.cleanNotesExcerpt(asset.notes, maxChars: 400)
            if !notesClean.isEmpty { dict["notes"] = notesClean }
            if let url = asset.sourceURL, !url.isEmpty { dict["sourceURL"] = url }
        } else {
            // Compact: omit redundant fileName, emit trimmed notesExcerpt only when it adds new signal
            let baseFileName = URL(fileURLWithPath: asset.fileName).deletingPathExtension().lastPathComponent
            if !asset.fileName.isEmpty && baseFileName.caseInsensitiveCompare(asset.title) != .orderedSame && !asset.title.hasPrefix(baseFileName) {
                dict["fileName"] = asset.fileName
            }
            let notesExcerpt = Self.cleanNotesExcerpt(asset.notes, maxChars: 100)
            if !notesExcerpt.isEmpty && (desc.isEmpty || !desc.contains(notesExcerpt.prefix(24))) {
                dict["notesExcerpt"] = notesExcerpt
            }
            if asset.mediaKind == .webBookmark, let url = asset.sourceURL, !url.isEmpty {
                dict["sourceURL"] = Self.cleanSummaryURL(url)
            }
        }
        return dict
    }

    private func serializeAssetDetail(
        _ asset: AssetRecord,
        folderPathByID: [UUID: String],
        iso: ISO8601DateFormatter
    ) async -> [String: Any] {
        let thumbURL = await engine.thumbnailURL(for: asset.id, tier: .grid520)
        let previewURL = await engine.thumbnailURL(for: asset.id, tier: .preview1400)
        let candidateOriginal = engine.media.originalPath(for: asset)
        let localOriginal = FileManager.default.fileExists(atPath: candidateOriginal.path) ? candidateOriginal.path : nil

        var dict = serializeAssetSummary(asset, folderPathByID: folderPathByID, detail: .standard)
        dict["mimeType"] = asset.mimeType
        dict["displayType"] = asset.displayTypeLabel
        dict["fileSizeBytes"] = asset.fileSizeBytes
        dict["pixelWidth"] = asset.pixelWidth
        dict["pixelHeight"] = asset.pixelHeight
        if let duration = asset.durationSeconds {
            dict["durationSeconds"] = (duration * 100).rounded() / 100
        }
        if !asset.notes.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            dict["notes"] = asset.notes
        }
        // Deduplicate OCR when byte-identical to notes or socialPost.bodyText
        let ocr = (asset.ocrText ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let socialBody = asset.richMetadata?.socialPost?.bodyText.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !ocr.isEmpty && ocr != asset.notes.trimmingCharacters(in: .whitespacesAndNewlines) && ocr != socialBody {
            dict["ocrText"] = ocr
        }
        if !asset.suggestedTags.isEmpty { dict["suggestedTags"] = asset.suggestedTags }
        if let domain = asset.sourceDomain, !domain.isEmpty { dict["sourceDomain"] = domain }
        dict["pinnedOffline"] = asset.pinnedOffline
        dict["isLocalOriginalCached"] = localOriginal != nil
        if let thumbPath = thumbURL?.path, !thumbPath.isEmpty { dict["thumbnailPath"] = thumbPath }
        if let previewPath = previewURL?.path, !previewPath.isEmpty { dict["previewPath"] = previewPath }
        if let localOriginal, !localOriginal.isEmpty { dict["localOriginalPath"] = localOriginal }
        if asset.isTrashed { dict["isTrashed"] = true }
        dict["createdAt"] = iso.string(from: asset.createdAt)
        dict["updatedAt"] = iso.string(from: asset.updatedAt)
        if let lastOpened = asset.lastOpenedAt {
            dict["lastOpenedAt"] = iso.string(from: lastOpened)
        }
        if let rich = serializeRichMetadata(asset.richMetadata) {
            dict["richMetadata"] = rich
        }
        return dict
    }

    private static func truncateText(_ text: String, maxChars: Int) -> String {
        guard text.count > maxChars else { return text }
        return String(text.prefix(max(1, maxChars - 1))) + "…"
    }

    private static func cleanNotesExcerpt(_ raw: String, maxChars: Int) -> String {
        let stripped = raw
            .replacingOccurrences(of: #"charkle-inspector-card:\S+"#, with: "", options: .regularExpression)
            .replacingOccurrences(of: #"https?://t\.co/\S+"#, with: "", options: .regularExpression)
            .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !stripped.isEmpty else { return "" }
        return truncateText(stripped, maxChars: maxChars)
    }

    private static func cleanSummaryURL(_ raw: String) -> String {
        guard var comps = URLComponents(string: raw), let items = comps.queryItems, !items.isEmpty else {
            return raw
        }
        let noisyParams: Set<String> = ["xsec_token", "xsec_source", "utm_source", "utm_medium", "utm_campaign", "utm_term", "utm_content", "fbclid", "gclid", "s", "t"]
        let filtered = items.filter { !noisyParams.contains($0.name.lowercased()) }
        comps.queryItems = filtered.isEmpty ? nil : filtered
        return comps.string ?? raw
    }

    private func serializeRichMetadata(_ rich: AssetRichMetadata?) -> [String: Any]? {
        guard let rich else { return nil }
        var out: [String: Any] = [:]

        if let exif = rich.photoExif, !exif.isEmpty {
            var e: [String: Any] = ["hasMeaningfulCameraExif": exif.hasMeaningfulCameraExif]
            if let v = exif.cameraMake { e["cameraMake"] = v }
            if let v = exif.cameraModel { e["cameraModel"] = v }
            if let v = exif.cameraDisplayName { e["cameraDisplayName"] = v }
            if let v = exif.lensModel { e["lensModel"] = v }
            if let v = exif.capturedAt { e["capturedAt"] = v }
            if let v = exif.exposureTime { e["exposureTime"] = v }
            if let v = exif.fNumber { e["fNumber"] = v }
            if let v = exif.formattedAperture { e["aperture"] = v }
            if let v = exif.iso { e["iso"] = v }
            if let v = exif.focalLengthMM { e["focalLengthMM"] = v }
            if let v = exif.focalLength35mm { e["focalLength35mm"] = v }
            if let v = exif.exposureSummary { e["exposureSummary"] = v }
            if let v = exif.exposureBiasEV { e["exposureBiasEV"] = v }
            if let v = exif.meteringMode { e["meteringMode"] = v }
            if let v = exif.flashFired { e["flashFired"] = v }
            if let v = exif.whiteBalance { e["whiteBalance"] = v }
            if let v = exif.colorProfile { e["colorProfile"] = v }
            if let v = exif.bitDepth { e["bitDepth"] = v }
            if let v = exif.dpiWidth { e["dpiWidth"] = v }
            if let v = exif.software { e["software"] = v }
            if let v = exif.artist { e["artist"] = v }
            if let v = exif.copyright { e["copyright"] = v }
            if let lat = exif.latitude, let lon = exif.longitude {
                var gps: [String: Any] = ["latitude": lat, "longitude": lon]
                if let alt = exif.altitudeMeters { gps["altitudeMeters"] = alt }
                e["gps"] = gps
            }
            out["photoExif"] = e
        }

        if let ai = rich.aiGeneration, !ai.isEmpty {
            var g: [String: Any] = [:]
            if let v = ai.generator { g["generator"] = v }
            if let v = ai.prompt { g["prompt"] = v }
            if let v = ai.negativePrompt { g["negativePrompt"] = v }
            if let v = ai.modelName { g["modelName"] = v }
            if let v = ai.modelHash { g["modelHash"] = v }
            if let v = ai.sampler { g["sampler"] = v }
            if let v = ai.scheduler { g["scheduler"] = v }
            if let v = ai.steps { g["steps"] = v }
            if let v = ai.cfgScale { g["cfgScale"] = v }
            if let v = ai.seed { g["seed"] = v }
            if let v = ai.sizeText { g["sizeText"] = v }
            if let v = ai.clipSkip { g["clipSkip"] = v }
            if !ai.loras.isEmpty { g["loras"] = ai.loras }
            if !ai.extraParameters.isEmpty { g["extraParameters"] = ai.extraParameters }
            out["aiGeneration"] = g
        }

        if let post = rich.socialPost {
            var s: [String: Any] = [
                "platform": post.platform.rawValue,
                "authorName": post.authorName,
                "authorHandle": post.authorHandle,
                "bodyText": post.bodyText,
                "originalURL": post.originalURL,
                "hasVideo": post.hasVideo,
                "attachments": post.effectiveAttachments.map { att -> [String: Any] in
                    [
                        "kind": att.kind.rawValue,
                        "url": att.url,
                        "thumbnailURL": att.thumbnailURL ?? ""
                    ]
                }
            ]
            if let v = post.publishedAtText { s["publishedAtText"] = v }
            if let v = post.quotedAuthor { s["quotedAuthor"] = v }
            if let v = post.quotedText { s["quotedText"] = v }
            if let v = post.articleTitle { s["articleTitle"] = v }
            if let v = post.likeCount { s["likeCount"] = v }
            if let v = post.repostCount { s["repostCount"] = v }
            if let v = post.replyCount { s["replyCount"] = v }
            if let v = post.viewCount { s["viewCount"] = v }
            out["socialPost"] = s
        }

        if let repo = rich.githubRepo {
            var r: [String: Any] = [
                "owner": repo.owner,
                "repo": repo.repo,
                "fullName": repo.fullName,
                "stars": repo.stars,
                "forks": repo.forks,
                "topics": repo.topics,
                "defaultBranch": repo.defaultBranch
            ]
            if let v = repo.description { r["description"] = v }
            if let v = repo.watchers { r["watchers"] = v }
            if let v = repo.language { r["language"] = v }
            if let v = repo.licenseName { r["licenseName"] = v }
            if let v = repo.homepageURL { r["homepageURL"] = v }
            if let readme = repo.readmeMarkdown, !readme.isEmpty {
                r["readmeExcerpt"] = String(readme.prefix(2000))
            }
            out["githubRepo"] = r
        }

        if let excerpt = rich.textExcerpt, !excerpt.isEmpty {
            out["textExcerpt"] = excerpt
        }
        if rich.isMarkdown {
            out["isMarkdown"] = true
        }
        if let modelFmt = rich.model3DFormat, !modelFmt.isEmpty {
            out["model3DFormat"] = modelFmt
        }

        return out.isEmpty ? nil : out
    }

    private static func buildFolderPaths(_ folders: [FolderRecord]) -> [UUID: String] {
        let byID = Dictionary(uniqueKeysWithValues: folders.map { ($0.id, $0) })
        var out: [UUID: String] = [:]
        for folder in folders {
            var parts: [String] = [folder.name]
            var parent = folder.parentID
            var visited: Set<UUID> = [folder.id]
            while let pid = parent, visited.insert(pid).inserted, let pf = byID[pid] {
                parts.insert(pf.name, at: 0)
                parent = pf.parentID
            }
            out[folder.id] = parts.joined(separator: "/")
        }
        return out
    }

    private static func paginate<T>(_ items: [T], offset: Int, limit: Int) -> [T] {
        guard offset < items.count else { return [] }
        let end = min(items.count, offset + limit)
        return Array(items[offset..<end])
    }

    private func parseUUIDList(_ raw: Any?) -> [UUID] {
        (Self.stringArrayArg(raw) ?? []).compactMap { UUID(uuidString: $0.trimmingCharacters(in: .whitespacesAndNewlines)) }
    }

    private static func parseMediaKinds(_ raw: Any?) -> Set<MediaKind> {
        var kinds: Set<MediaKind> = []
        if let list = stringArrayArg(raw) {
            for k in list {
                if let kind = MediaKind(rawValue: k.trimmingCharacters(in: .whitespacesAndNewlines)) {
                    kinds.insert(kind)
                }
            }
        }
        return kinds
    }

    private static func parseSortOrder(_ raw: Any?, defaultOrder: SortOrder) -> SortOrder {
        guard let str = (raw as? String)?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(), !str.isEmpty else {
            return defaultOrder
        }
        switch str {
        case "newest": return .newest
        case "oldest": return .oldest
        case "name_asc", "nameasc", "name": return .nameAsc
        case "rating_desc", "ratingdesc", "rating": return .ratingDesc
        case "file_size_desc", "filesizedesc", "size": return .fileSizeDesc
        case "relevance": return .relevance
        default: return defaultOrder
        }
    }

    private static func stringArrayArg(_ raw: Any?) -> [String]? {
        if let arr = raw as? [String] { return arr }
        if let anyArr = raw as? [Any] { return anyArr.compactMap { $0 as? String } }
        return nil
    }

    private static func intArg(_ raw: Any?) -> Int? {
        if let i = raw as? Int { return i }
        if let d = raw as? Double, d.isFinite { return Int(d) }
        if let s = raw as? String { return Int(s.trimmingCharacters(in: .whitespacesAndNewlines)) }
        return nil
    }

    private static func doubleArg(_ raw: Any?) -> Double? {
        if let d = raw as? Double, d.isFinite { return d }
        if let i = raw as? Int { return Double(i) }
        if let s = raw as? String, let d = Double(s.trimmingCharacters(in: .whitespacesAndNewlines)), d.isFinite { return d }
        return nil
    }

    private static func boolArg(_ raw: Any?) -> Bool? {
        if let b = raw as? Bool { return b }
        if let s = raw as? String {
            switch s.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
            case "true", "1", "yes": return true
            case "false", "0", "no": return false
            default: return nil
            }
        }
        return nil
    }

    private static func layoutModeLabel(_ mode: BoardLayoutMode) -> String {
        switch mode {
        case .autoEditorial(let cfg): return "autoEditorial(\(cfg.style.rawValue))"
        case .freeform: return "freeform"
        }
    }

    private static func makeISO8601Formatter() -> ISO8601DateFormatter {
        ISO8601DateFormatter()
    }

    private func makeResultObject(id: Any?, result: Any) -> [String: Any] {
        [
            "jsonrpc": "2.0",
            "id": id ?? NSNull(),
            "result": result
        ]
    }

    private func makeErrorObject(id: Any?, code: Int, message: String) -> [String: Any] {
        [
            "jsonrpc": "2.0",
            "id": id ?? NSNull(),
            "error": [
                "code": code,
                "message": message
            ]
        ]
    }

    private func serializeJSON(_ object: Any) -> Data {
        (try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])) ?? Data("{}".utf8)
    }

    public static func encodePrettyJSON(_ object: Any) -> String {
        guard JSONSerialization.isValidJSONObject(object),
              let data = try? JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys]),
              let str = String(data: data, encoding: .utf8) else {
            return "{}"
        }
        return str
    }

    public static func encodeCompactJSON(_ object: Any) -> String {
        guard JSONSerialization.isValidJSONObject(object),
              let data = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]),
              let str = String(data: data, encoding: .utf8) else {
            return "{}"
        }
        return str
    }
}
