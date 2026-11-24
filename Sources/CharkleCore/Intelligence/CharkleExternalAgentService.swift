import Foundation

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
            let text = CharkleExternalAgentService.encodePrettyJSON(object)
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
                "instructions": "Charkle is a macOS visual reference library and moodboard studio. Start with `library_overview` to inspect folders, smart folders, and tags. Use `search_assets` (with pagination, subfolder recursion, color, media kind, and smart folder filters), `semantic_search`, `find_similar_assets`, `quick_jump`, or `list_inbox` to locate references. Use `render_contact_sheet` to visually inspect up to 16 numbered thumbnails in one image, `get_asset` (with optional `include_image: true`) for full EXIF, AI generation prompts, social post, and GitHub metadata, and `get_board_context` / `export_board_image` to inspect moodboards. Safe write tools (`organize_assets`, `create_folder`, `update_folder`, `ingest_asset`, `compose_moodboard`, `patch_moodboard`, `trash_assets`, `analyze_assets`) are available when write access is enabled in Charkle Settings; permanent deletion is never permitted."
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
                let paths = Self.buildFolderPaths(folders)
                let items: [[String: Any]] = FolderHierarchyNode.flattened(from: folders).map { node in
                    [
                        "id": node.folder.id.uuidString,
                        "name": node.folder.name,
                        "path": paths[node.folder.id] ?? node.folder.name,
                        "parentID": node.folder.parentID?.uuidString ?? "",
                        "depth": node.depth,
                        "assetCount": node.folder.assetCount,
                        "colorHex": node.folder.colorHex ?? "",
                        "customSymbol": node.folder.customSymbol ?? ""
                    ]
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
                return try await handleLibraryOverview(policy: policy, channel: channel)
            case "search_assets":
                return try await handleSearchAssets(args)
            case "list_inbox":
                return try await handleListInbox(args)
            case "get_asset":
                return try await handleGetAsset(args)
            case "render_contact_sheet":
                return try await handleRenderContactSheet(args, policy: policy, channel: channel)
            case "find_similar_assets":
                return try await handleFindSimilarAssets(args)
            case "semantic_search":
                return try await handleSemanticSearch(args)
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

    private func handleLibraryOverview(policy: ExternalAgentConfig, channel: ExternalAgentChannel) async throws -> ToolOutput {
        let overview = try await tools.libraryOverview()
        let trashedAssets = try await engine.fetchAssets(matching: FilterCriteria(onlyTrashed: true))
        let smartFolders = try await engine.fetchSmartFolders()
        let untaggedCount: Int
        let smartFolderPayloads: [[String: Any]]
        if smartFolders.isEmpty {
            untaggedCount = try await engine.fetchAssets(matching: FilterCriteria(onlyUntagged: true)).count
            smartFolderPayloads = []
        } else {
            let activeAssets = try await engine.fetchAssets(matching: FilterCriteria(includeTrashed: false))
            untaggedCount = activeAssets.filter { $0.tags.isEmpty }.count
            smartFolderPayloads = smartFolders.map { sf in
                [
                    "id": sf.id.uuidString,
                    "name": sf.name,
                    "colorHex": sf.colorHex ?? "",
                    "matchCount": activeAssets.filter { sf.rule.matches($0) }.count
                ]
            }
        }
        let foldersRaw = try await engine.fetchFolders()
        let folderByID = Dictionary(uniqueKeysWithValues: foldersRaw.map { ($0.id, $0) })
        let syncCfg = await engine.syncConfig()
        let aiCfg = await engine.aiConfig()
        let cache = await engine.cacheStats()

        let payload: [String: Any] = [
            "totalAssets": overview.totalAssets,
            "inboxCount": overview.inboxCount,
            "untaggedCount": untaggedCount,
            "trashedCount": trashedAssets.count,
            "boardCount": overview.boardCount,
            "mcpEnabled": policy.mcpEnabled,
            "cliEnabled": policy.cliEnabled,
            "accessLevel": policy.accessLevel.rawValue,
            "canWrite": policy.allowsWrite(for: channel),
            "syncMode": syncCfg.mode.rawValue,
            "aiConfigured": aiCfg.provider != .disabled,
            "mediaKindCounts": overview.mediaKindCounts,
            "folders": overview.folders.map { folder -> [String: Any] in
                [
                    "id": folder.id.uuidString,
                    "name": folder.name,
                    "path": folder.path,
                    "parentID": folderByID[folder.id]?.parentID?.uuidString ?? "",
                    "assetCount": folder.assetCount,
                    "colorHex": folderByID[folder.id]?.colorHex ?? "",
                    "customSymbol": folderByID[folder.id]?.customSymbol ?? ""
                ]
            },
            "smartFolders": smartFolderPayloads,
            "topTags": overview.topTags.prefix(40).map { tag -> [String: Any] in
                ["name": tag.name, "count": tag.count]
            },
            "cache": [
                "thumbnailBytes": cache.thumbnailBytes,
                "originalCacheBytes": cache.originalCacheBytes,
                "pinnedOfflineBytes": cache.pinnedOfflineBytes,
                "budgetBytes": cache.budgetBytes,
                "cachedOriginalCount": cache.cachedOriginalCount,
                "pinnedAssetCount": cache.pinnedAssetCount
            ]
        ]
        return .json(payload)
    }

    private func handleSearchAssets(_ args: [String: Any]) async throws -> ToolOutput {
        let folders = try await engine.fetchFolders()
        let folderPathByID = Self.buildFolderPaths(folders)
        let criteria = try buildFilterCriteria(from: args, folders: folders, folderPathByID: folderPathByID)
        let smartFolder = try await resolveOptionalSmartFolder(from: args)
        let offset = max(0, Self.intArg(args["offset"]) ?? 0)
        let limit = max(1, min(100, Self.intArg(args["limit"]) ?? 30))

        var matches = try await engine.fetchAssets(matching: criteria)
        if let smartFolder {
            matches = matches.filter { smartFolder.rule.matches($0) }
        }
        let sliced = Self.paginate(matches, offset: offset, limit: limit)
        let hasMore = offset + sliced.count < matches.count

        var payload: [String: Any] = [
            "totalMatched": matches.count,
            "offset": offset,
            "returned": sliced.count,
            "hasMore": hasMore,
            "assets": sliced.map { serializeAssetSummary($0, folderPathByID: folderPathByID) }
        ]
        if hasMore {
            payload["nextOffset"] = offset + sliced.count
        }
        if let smartFolder {
            payload["smartFolder"] = ["id": smartFolder.id.uuidString, "name": smartFolder.name]
        }
        return .json(payload)
    }

    private func handleListInbox(_ args: [String: Any]) async throws -> ToolOutput {
        let offset = max(0, Self.intArg(args["offset"]) ?? 0)
        let limit = max(1, min(100, Self.intArg(args["limit"]) ?? 40))
        let sortBy = Self.parseSortOrder(args["sort_by"], defaultOrder: .newest)
        let kinds = Self.parseMediaKinds(args["media_kinds"])

        let matches = try await engine.fetchAssets(
            matching: FilterCriteria(kinds: kinds, onlyInbox: true, sortBy: sortBy)
        )
        let sliced = Self.paginate(matches, offset: offset, limit: limit)
        let hasMore = offset + sliced.count < matches.count

        var payload: [String: Any] = [
            "inboxTotal": matches.count,
            "offset": offset,
            "returned": sliced.count,
            "hasMore": hasMore,
            "assets": sliced.map { serializeAssetSummary($0, folderPathByID: [:]) }
        ]
        if hasMore {
            payload["nextOffset"] = offset + sliced.count
        }
        return .json(payload)
    }

    private func handleGetAsset(_ args: [String: Any]) async throws -> ToolOutput {
        guard let rawID = args["asset_id"] as? String ?? args["id"] as? String,
              let uuid = UUID(uuidString: rawID.trimmingCharacters(in: .whitespacesAndNewlines)) else {
            return .error("Missing or invalid UUID for `asset_id`.")
        }
        // Lazily hydrate camera EXIF / AI generation prompt metadata if not yet populated
        _ = try? await engine.hydrateImageMetadataIfNeeded(id: uuid)

        guard let asset = try await engine.fetchAsset(id: uuid) else {
            return .error("Asset not found: \(uuid.uuidString)")
        }
        let folders = try await engine.fetchFolders()
        let folderPathByID = Self.buildFolderPaths(folders)
        let thumbURL = await engine.thumbnailURL(for: uuid, tier: .grid520)
        let previewURL = await engine.thumbnailURL(for: uuid, tier: .preview1400)
        let candidateOriginal = engine.media.originalPath(for: asset)
        let localOriginal = FileManager.default.fileExists(atPath: candidateOriginal.path) ? candidateOriginal.path : nil
        let iso = Self.makeISO8601Formatter()

        var dict = serializeAssetSummary(asset, folderPathByID: folderPathByID)
        dict["mimeType"] = asset.mimeType
        dict["displayType"] = asset.displayTypeLabel
        dict["aspectShape"] = asset.aspectShape.rawValue
        dict["ocrText"] = asset.ocrText ?? ""
        dict["suggestedTags"] = asset.suggestedTags
        dict["sourceDomain"] = asset.sourceDomain ?? ""
        dict["fileSizeBytes"] = asset.fileSizeBytes
        dict["pixelWidth"] = asset.pixelWidth
        dict["pixelHeight"] = asset.pixelHeight
        if let duration = asset.durationSeconds {
            dict["durationSeconds"] = (duration * 100).rounded() / 100
        }
        dict["pinnedOffline"] = asset.pinnedOffline
        dict["isLocalOriginalCached"] = localOriginal != nil
        dict["thumbnailPath"] = thumbURL?.path ?? ""
        dict["previewPath"] = previewURL?.path ?? ""
        dict["localOriginalPath"] = localOriginal ?? ""
        dict["isTrashed"] = asset.isTrashed
        dict["createdAt"] = iso.string(from: asset.createdAt)
        dict["updatedAt"] = iso.string(from: asset.updatedAt)
        if let lastOpened = asset.lastOpenedAt {
            dict["lastOpenedAt"] = iso.string(from: lastOpened)
        }
        if let rich = serializeRichMetadata(asset.richMetadata) {
            dict["richMetadata"] = rich
        }

        let includeImage = Self.boolArg(args["include_image"]) ?? false
        if includeImage {
            let maxSide = max(280, min(1568, Self.intArg(args["image_max_side"]) ?? 800))
            if let jpegData = tools.preparedTypeSafeJPEG(for: asset, targetLongSide: maxSide) {
                return ToolOutput(content: [
                    .image(mimeType: "image/jpeg", data: jpegData),
                    .text(Self.encodePrettyJSON(dict))
                ])
            }
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
        let limit = max(1, min(16, Self.intArg(args["limit"]) ?? 16))
        let maxWidth = max(640, min(1920, Self.intArg(args["max_width"]) ?? 1280))
        let includeImage = Self.boolArg(args["include_image"]) ?? true

        var totalMatched = 0
        var selectedAssets: [AssetRecord] = []
        if let rawIDs = Self.stringArrayArg(args["asset_ids"]), !rawIDs.isEmpty {
            var resolved: [AssetRecord] = []
            for raw in rawIDs {
                if let uuid = UUID(uuidString: raw.trimmingCharacters(in: .whitespacesAndNewlines)),
                   let asset = try await engine.fetchAsset(id: uuid) {
                    resolved.append(asset)
                }
            }
            totalMatched = resolved.count
            selectedAssets = Self.paginate(resolved, offset: offset, limit: limit)
        } else {
            let criteria = try buildFilterCriteria(from: args, folders: folders, folderPathByID: folderPathByID)
            let smartFolder = try await resolveOptionalSmartFolder(from: args)
            var matches = try await engine.fetchAssets(matching: criteria)
            if let smartFolder {
                matches = matches.filter { smartFolder.rule.matches($0) }
            }
            totalMatched = matches.count
            selectedAssets = Self.paginate(matches, offset: offset, limit: limit)
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
        guard let sheet = ContactSheetRenderer.render(entries: entries, maxCanvasWidth: maxWidth) else {
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
            return [
                "slot": pair.slot,
                "index": offset + pair.slot,
                "badge": String(format: "#%02d", pair.slot),
                "assetID": asset.id.uuidString,
                "title": asset.title,
                "mediaKind": asset.mediaKind.rawValue,
                "folderPath": folderPath,
                "tags": asset.tags,
                "dominantColors": asset.dominantColors.prefix(4).map { $0.hex.uppercased() },
                "aiDescription": asset.aiDescription ?? ""
            ]
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
        content.append(.text(Self.encodePrettyJSON(metadata)))
        return ToolOutput(content: content)
    }

    private func handleFindSimilarAssets(_ args: [String: Any]) async throws -> ToolOutput {
        guard let rawID = args["asset_id"] as? String ?? args["id"] as? String,
              let uuid = UUID(uuidString: rawID.trimmingCharacters(in: .whitespacesAndNewlines)) else {
            return .error("Missing or invalid UUID for `asset_id`.")
        }
        guard (try await engine.fetchAsset(id: uuid)) != nil else {
            return .error("Asset not found: \(uuid.uuidString)")
        }
        let limit = max(1, min(32, Self.intArg(args["limit"]) ?? 12))
        let matches = try await engine.similarAssets(to: uuid, limit: limit)
        let folders = try await engine.fetchFolders()
        let folderPathByID = Self.buildFolderPaths(folders)

        let items: [[String: Any]] = matches.enumerated().map { idx, scored in
            var dict = serializeAssetSummary(scored.asset, folderPathByID: folderPathByID)
            dict["rank"] = idx + 1
            dict["score"] = (scored.score * 1000).rounded() / 1000
            dict["matchReasons"] = scored.matchReasons
            return dict
        }

        let payload: [String: Any] = [
            "referenceAssetID": uuid.uuidString,
            "returned": items.count,
            "matches": items
        ]

        let wantSheet = Self.boolArg(args["render_contact_sheet"]) ?? false
        if wantSheet && !matches.isEmpty {
            let entries: [ContactSheetRenderer.Entry] = matches.prefix(16).enumerated().map { idx, scored in
                let thumbURL = engine.media.thumbnailURL(for: scored.asset.id, tier: .grid520)
                    ?? engine.media.thumbnailURL(for: scored.asset.id, tier: .preview1400)
                return ContactSheetRenderer.Entry(slot: idx + 1, asset: scored.asset, thumbnailURL: thumbURL)
            }
            if let sheet = ContactSheetRenderer.render(entries: entries) {
                return ToolOutput(content: [
                    .image(mimeType: "image/jpeg", data: sheet.jpegData),
                    .text(Self.encodePrettyJSON(payload))
                ])
            }
        }
        return .json(payload)
    }

    private func handleSemanticSearch(_ args: [String: Any]) async throws -> ToolOutput {
        let query = ((args["query"] as? String) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else {
            return .error("Missing non-empty `query` for semantic_search.")
        }
        let folders = try await engine.fetchFolders()
        let folderPathByID = Self.buildFolderPaths(folders)
        var criteria = try buildFilterCriteria(from: args, folders: folders, folderPathByID: folderPathByID)
        criteria.searchQuery = ""
        let limit = max(1, min(50, Self.intArg(args["limit"]) ?? 20))

        let report = try await engine.semanticSearch(query: query, criteria: criteria, limit: limit)
        let hits: [[String: Any]] = report.hits.enumerated().map { idx, hit in
            var dict = serializeAssetSummary(hit.asset, folderPathByID: folderPathByID)
            dict["rank"] = idx + 1
            dict["score"] = (hit.score * 1000).rounded() / 1000
            if let conf = hit.confidence {
                dict["confidence"] = (conf * 1000).rounded() / 1000
            }
            dict["reason"] = hit.reason
            dict["source"] = hit.sourceLabel
            return dict
        }

        return .json([
            "query": report.query,
            "summary": report.summary,
            "usedCloudEmbedding": report.usedCloudEmbedding,
            "usedVisualRerank": report.usedTypeSafeJev,
            "evaluatedVisualCount": report.evaluatedVisualCount,
            "returned": hits.count,
            "hits": hits
        ])
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
        var ids = parseUUIDList(args["asset_ids"])
        if let single = (args["asset_id"] as? String ?? args["id"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
           let uuid = UUID(uuidString: single),
           !ids.contains(uuid) {
            ids.insert(uuid, at: 0)
        }
        guard !ids.isEmpty else {
            return .error("Provide `asset_id` or a non-empty `asset_ids` array.")
        }

        let folders = try await engine.fetchFolders()
        let folderPathByID = Self.buildFolderPaths(folders)
        var recommendations: [[String: Any]] = []

        for uuid in ids.prefix(20) {
            guard let asset = try await engine.fetchAsset(id: uuid) else {
                recommendations.append([
                    "assetID": uuid.uuidString,
                    "found": false
                ])
                continue
            }
            if let suggestion = try await engine.suggestFolder(for: uuid) {
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
                notes.append([
                    "nodeID": node.id.uuidString,
                    "title": title ?? "",
                    "text": text,
                    "style": style.rawValue,
                    "isLocked": node.isLocked,
                    "frame": frameDict(node.frame)
                ])
            case .groupFrame(let title, let tint):
                sections.append([
                    "nodeID": node.id.uuidString,
                    "title": title,
                    "tint": tint.rawValue,
                    "isLocked": node.isLocked,
                    "frame": frameDict(node.frame)
                ])
            case .assetRef(let assetID, let crop, let weight, _):
                if let asset = assetsByID[assetID] {
                    var summary = serializeAssetSummary(asset, folderPathByID: folderPathByID)
                    summary["nodeID"] = node.id.uuidString
                    summary["weight"] = weight
                    summary["isHero"] = weight >= 2
                    summary["isLocked"] = node.isLocked
                    summary["frame"] = frameDict(node.frame)
                    if let crop, crop.isMeaningfulSubregion {
                        summary["crop"] = [
                            "x": (crop.x * 1000).rounded() / 1000,
                            "y": (crop.y * 1000).rounded() / 1000,
                            "width": (crop.width * 1000).rounded() / 1000,
                            "height": (crop.height * 1000).rounded() / 1000
                        ]
                    }
                    let candidateOriginal = engine.media.originalPath(for: asset)
                    if FileManager.default.fileExists(atPath: candidateOriginal.path) {
                        summary["localOriginalPath"] = candidateOriginal.path
                    }
                    cardRefs.append(summary)
                }
            case .paletteStrip:
                break
            }
        }

        let connectors: [[String: Any]] = doc.connectors.map { c in
            [
                "id": c.id.uuidString,
                "fromNodeID": c.fromNodeID.uuidString,
                "toNodeID": c.toNodeID.uuidString,
                "label": c.label ?? "",
                "style": c.style.rawValue,
                "colorHex": c.colorHex.uppercased(),
                "dashed": c.dashed
            ]
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
        let payload: [String: Any] = [
            "id": doc.id.uuidString,
            "title": doc.title,
            "subtitle": doc.subtitle,
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
        content.append(.text(Self.encodePrettyJSON(metadata)))
        return ToolOutput(content: content)
    }

    // MARK: - Safe Write / Organize Tool Handlers (Never Permanent Delete)

    private func handleOrganizeAssets(_ args: [String: Any]) async throws -> ToolOutput {
        let ids = parseUUIDList(args["asset_ids"])
        guard !ids.isEmpty else {
            return .error("`asset_ids` must be a non-empty array of asset UUID strings.")
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
            guard let uuid = UUID(uuidString: rawBoard) else {
                return .error("Invalid `target_board_id` UUID: \(rawBoard)")
            }
            targetBoardID = uuid
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
        let flatAssetIDs = parseUUIDList(args["asset_ids"])

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
                    let heroSet = Set(parseUUIDList(sec["hero_asset_ids"]))
                    let secIDs = parseUUIDList(sec["asset_ids"])
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
                let heroSet = Set(parseUUIDList(args["hero_asset_ids"]))
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
        let seedIDs = parseUUIDList(args["seed_asset_ids"])
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

        // Remove unlocked nodes by asset UUID or explicit node UUID.
        let removeAssetSet = Set(parseUUIDList(args["remove_asset_ids"]))
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
        let addIDs = parseUUIDList(args["add_asset_ids"])
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
        let ids = parseUUIDList(args["asset_ids"])
        guard !ids.isEmpty else {
            return .error("`asset_ids` must be a non-empty array of asset UUID strings.")
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
        let ids = Array(parseUUIDList(args["asset_ids"]).prefix(20))
        guard !ids.isEmpty else {
            return .error("`asset_ids` must be a non-empty array of asset UUID strings (max 20).")
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
           let uuid = UUID(uuidString: rawID) {
            return try await engine.fetchBoard(id: uuid)
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
            guard let uuid = UUID(uuidString: rawID) else {
                throw LibraryDatabaseError("Invalid smart_folder_id UUID: \(rawID)")
            }
            guard let found = all.first(where: { $0.id == uuid }) else {
                throw LibraryDatabaseError("Smart folder not found: \(rawID)")
            }
            return found
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
        let includeSubfolders = Self.boolArg(args["include_subfolders"]) ?? false
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
            guard let uuid = UUID(uuidString: rawID) else {
                throw LibraryDatabaseError("Invalid folder_id UUID: \(rawID)")
            }
            return uuid
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

    private func serializeAssetSummary(_ asset: AssetRecord, folderPathByID: [UUID: String]) -> [String: Any] {
        [
            "id": asset.id.uuidString,
            "title": asset.title,
            "fileName": asset.fileName,
            "mediaKind": asset.mediaKind.rawValue,
            "folderID": asset.folderID?.uuidString ?? "",
            "folderPath": asset.folderID.flatMap { folderPathByID[$0] } ?? "Inbox",
            "tags": asset.tags,
            "rating": asset.rating,
            "aspectRatio": (asset.aspectRatio * 100).rounded() / 100,
            "dominantColors": asset.dominantColors.prefix(5).map { $0.hex.uppercased() },
            "aiDescription": asset.aiDescription ?? "",
            "notes": asset.notes,
            "sourceURL": asset.sourceURL ?? ""
        ]
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
