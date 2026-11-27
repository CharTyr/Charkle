import CoreGraphics
import Foundation
import ImageIO
import Vision

/// Pure MCP v2 Grounded External Agent Service powering BOTH:
/// 1. Local headless `stdio` MCP (`charkle mcp`) — works even when `Charkle.app` is closed
/// 2. Remote / local Streamable HTTP MCP (`POST /api/v1/mcp`) — cross-machine & Web parity
///
/// Built directly on `CharkleAgentTools` + `LiveCharkleEngine`, enforcing 3-tier `ExternalAgentAccessLevel`,
/// 10 orthogonal safe tools (zero permanent delete, zero folder delete, zero arbitrary disk `output_path`),
/// heterogeneous batch organization with `dry_run`, cross-machine file transfer, and HLC-safe `rollback_run`.
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

    // MARK: - Diagnostics (for Settings Self-Check & internal `charkle doctor`)

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
        let recentRuns = await ExternalAgentStateStore.listRuns(in: engine.database, limit: 10)

        var report: [String: Any] = [
            "ok": dbHealthy,
            "serverVersion": Self.serverVersion,
            "schemaVersion": "2.0",
            "supportedProtocolVersions": Self.supportedProtocolVersions,
            "policy": [
                "mcpEnabled": policy.mcpEnabled,
                "httpMCPEnabled": policy.httpMCPEnabled,
                "allowRemoteHTTPMCP": policy.allowRemoteHTTPMCP,
                "accessLevel": policy.accessLevel.rawValue,
                "scopedTokenCount": policy.tokens.filter(\.isEnabled).count
            ],
            "capabilities": [
                "toolCount": toolDefs.count,
                "readToolCount": readTools,
                "writeToolCount": writeTools,
                "resourceCount": Self.mcpResourceDefinitions().count,
                "resourceTemplateCount": Self.mcpResourceTemplateDefinitions().count,
                "promptCount": Self.mcpPromptDefinitions().count,
                "permanentDeleteAllowed": false,
                "rollbackRunCount": recentRuns.count
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

    // MARK: - MCP JSON-RPC 2.0 Dispatcher (Single & Batch, stdio + HTTP)

    public func handleJSONRPC(
        _ payload: Data,
        context: ExternalAgentRequestContext = .localStdio
    ) async -> Data? {
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
                    if let resp = await handleSingleJSONRPCObject(obj, context: context) {
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
        guard let resp = await handleSingleJSONRPCObject(obj, context: context) else { return nil }
        return serializeJSON(resp)
    }

    private func handleSingleJSONRPCObject(
        _ obj: [String: Any],
        context: ExternalAgentRequestContext
    ) async -> [String: Any]? {
        let hasID = obj.keys.contains("id")
        let id = obj["id"]
        let isNotification = !hasID
        guard let method = obj["method"] as? String else {
            return isNotification ? nil : makeErrorObject(id: id, code: -32600, message: "Invalid Request: missing method")
        }
        let params = obj["params"] as? [String: Any] ?? [:]
        let response = await dispatchJSONRPCMethod(method, params: params, id: id, context: context)
        // JSON-RPC 2.0 Section 4.1: Servers MUST NOT reply to notifications (requests without `id`).
        return isNotification ? nil : response
    }

    private func dispatchJSONRPCMethod(
        _ method: String,
        params: [String: Any],
        id: Any?,
        context: ExternalAgentRequestContext
    ) async -> [String: Any]? {
        let policy = currentPolicy()
        let transportEnabled = policy.isEnabled(for: context.transport)

        switch method {
        case "initialize":
            guard transportEnabled else {
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
                "instructions": "Charkle visual reference library & moodboard studio (Pure MCP v2, 10 safe tools). Funnel: (1) Call `library_overview` first to inspect folder profiles, canonical tags, taxonomy, and permissions. (2) Recall + inspect visually in 1 call via `query_assets(..., contact_sheet:true, diversify:true, session_id:...)` (supports `only_inbox`, multi-direction `queries[]`, `seed_asset_ids`, `unlike_asset_ids`, `include_folder_suggestions`, and auto-skips seen items per session). (3) Call `inspect_assets` only on finalists (supports `crop_box` zoom and `include_download_url` over HTTP). (4) Batch heterogeneous edits in 1 call via `organize_assets(items:[...], dry_run:...)`; every write emits `run_id` reversible via `rollback_run`. Permanent deletion is never permitted."
            ]
            return makeResultObject(id: id, result: result)

        case "notifications/initialized", "notifications/cancelled", "notifications/roots/list_changed", "initialized":
            return nil

        case "ping":
            return makeResultObject(id: id, result: [:])

        case "logging/setLevel":
            return makeResultObject(id: id, result: [:])

        case "tools/list":
            guard transportEnabled else {
                return makeErrorObject(id: id, code: -32001, message: "Charkle MCP service is disabled in Settings.")
            }
            return makeResultObject(id: id, result: ["tools": Self.mcpToolDefinitions()])

        case "tools/call":
            guard transportEnabled else {
                return makeErrorObject(id: id, code: -32001, message: "Charkle MCP service is disabled in Settings.")
            }
            guard let name = params["name"] as? String, !name.isEmpty else {
                return makeErrorObject(id: id, code: -32602, message: "Invalid params: missing tool name")
            }
            guard Self.knownToolNames.contains(name) else {
                return makeErrorObject(id: id, code: -32602, message: "Unknown tool: \(name)")
            }
            let args = params["arguments"] as? [String: Any] ?? [:]
            let output = await callTool(name: name, arguments: args, context: context)
            let result: [String: Any] = [
                "content": output.content.map { $0.mcpObject() },
                "isError": output.isError
            ]
            return makeResultObject(id: id, result: result)

        case "resources/list":
            guard transportEnabled else {
                return makeErrorObject(id: id, code: -32001, message: "Charkle MCP service is disabled in Settings.")
            }
            return makeResultObject(id: id, result: ["resources": Self.mcpResourceDefinitions()])

        case "resources/templates/list":
            guard transportEnabled else {
                return makeErrorObject(id: id, code: -32001, message: "Charkle MCP service is disabled in Settings.")
            }
            return makeResultObject(id: id, result: ["resourceTemplates": Self.mcpResourceTemplateDefinitions()])

        case "resources/read":
            guard let uri = params["uri"] as? String else {
                return makeErrorObject(id: id, code: -32602, message: "Missing resource uri")
            }
            guard transportEnabled else {
                return makeErrorObject(id: id, code: -32001, message: "Charkle MCP service is disabled in Settings.")
            }
            return await handleReadResource(uri: uri, id: id, context: context)

        case "prompts/list":
            guard transportEnabled else {
                return makeErrorObject(id: id, code: -32001, message: "Charkle MCP service is disabled in Settings.")
            }
            return makeResultObject(id: id, result: ["prompts": Self.mcpPromptDefinitions()])

        case "prompts/get":
            guard transportEnabled else {
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

    private func handleReadResource(
        uri: String,
        id: Any?,
        context: ExternalAgentRequestContext
    ) async -> [String: Any] {
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
            return textOutput(await callTool(name: "library_overview", arguments: [:], context: context))
        }
        if uri == "charkle://library/taxonomy" {
            do {
                let taxonomy = await ExternalAgentStateStore.loadTaxonomy(from: engine.database)
                let tagCounts = try await engine.fetchTagCounts()
                let folders = try await engine.fetchFolders()
                let paths = Self.buildFolderPaths(folders)
                let payload: [String: Any] = [
                    "preferredTagLanguage": taxonomy.preferredTagLanguage,
                    "tagAliases": taxonomy.tagAliases,
                    "folderGuidelines": taxonomy.folderGuidelines,
                    "ratingMeanings": taxonomy.ratingMeanings,
                    "notes": taxonomy.notes,
                    "canonicalFolders": folders.map { paths[$0.id] ?? $0.name }.sorted(),
                    "canonicalTopTags": tagCounts.prefix(60).map { ["name": $0.name, "count": $0.count] as [String: Any] }
                ]
                return textOutput(.json(payload))
            } catch {
                return makeErrorObject(id: id, code: -32603, message: error.localizedDescription)
            }
        }
        if uri == "charkle://boards" {
            return textOutput(await callTool(name: "get_board", arguments: [:], context: context))
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
            return textOutput(await callTool(name: "inspect_assets", arguments: ["asset_id": assetID], context: context))
        }
        if uri.hasPrefix("charkle://boards/") {
            let boardID = String(uri.dropFirst("charkle://boards/".count))
            return textOutput(await callTool(name: "get_board", arguments: ["board_id": boardID], context: context))
        }
        return makeErrorObject(id: id, code: -32002, message: "Unknown resource URI: \(uri)")
    }

    // MARK: - Unified Grounded Tool Execution (10 Pure MCP v2 Tools)

    private static let knownToolNames: Set<String> = Set(
        mcpToolDefinitions().compactMap { $0["name"] as? String }
    )

    public func callTool(
        name: String,
        arguments args: [String: Any],
        context: ExternalAgentRequestContext = .localStdio
    ) async -> ToolOutput {
        let policy = currentPolicy()
        guard policy.isEnabled(for: context.transport) else {
            return .error(
                context.transport == .http
                    ? "Charkle 远程 / 本地 HTTP MCP 服务已在「设置 → 外部 Agent」中关闭。"
                    : "Charkle 本机 MCP 服务已在「设置 → 外部 Agent」中关闭，请先开启后再试。"
            )
        }

        // Retired disk-write `output_path` is explicitly rejected across all MCP v2 tools.
        if let outPath = (args["output_path"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines), !outPath.isEmpty {
            return .error("MCP v2 已移除 `output_path` 写盘参数；请直接使用工具返回的内联图片或 `inspect_assets(include_download_url: true)`。")
        }

        let effectiveAccess = context.effectiveAccessLevel(using: policy)

        do {
            switch name {
            // Read Tools (4)
            case "library_overview":
                return try await handleLibraryOverview(args, policy: policy, effectiveAccess: effectiveAccess, context: context)
            case "query_assets":
                return try await handleQueryAssets(args, context: context)
            case "inspect_assets":
                return try await handleInspectAssets(args, context: context)
            case "get_board":
                return try await handleGetBoard(args, context: context)

            // Safe Write Tools (6)
            case "ingest_assets":
                return try await handleIngestAssets(args, effectiveAccess: effectiveAccess, context: context)
            case "organize_assets":
                return try await handleOrganizeAssets(args, effectiveAccess: effectiveAccess, context: context)
            case "manage_folder":
                return try await handleManageFolder(args, effectiveAccess: effectiveAccess, context: context)
            case "save_moodboard":
                return try await handleSaveMoodboard(args, effectiveAccess: effectiveAccess, context: context)
            case "deduplicate_assets":
                return try await handleDeduplicateAssets(args, effectiveAccess: effectiveAccess, context: context)
            case "rollback_run":
                return try await handleRollbackRun(args, effectiveAccess: effectiveAccess, context: context)

            default:
                return .error("Unknown Charkle MCP tool: \(name)")
            }
        } catch {
            return .error("Tool \(name) failed: \(error.localizedDescription)")
        }
    }

    // MARK: - Tool 1: library_overview

    private func handleLibraryOverview(
        _ args: [String: Any],
        policy: ExternalAgentConfig,
        effectiveAccess: ExternalAgentAccessLevel,
        context: ExternalAgentRequestContext
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
        let taxonomy = await ExternalAgentStateStore.loadTaxonomy(from: engine.database)

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
            "transport": context.transport.rawValue,
            "mcpEnabled": policy.mcpEnabled,
            "httpMCPEnabled": policy.httpMCPEnabled,
            "accessLevel": effectiveAccess.rawValue,
            "canWriteInbox": effectiveAccess.allowsInboxAndEnrichWrites,
            "canWriteGlobal": effectiveAccess.allowsGlobalOrganizeWrites,
            "syncMode": syncCfg.mode.rawValue,
            "aiConfigured": aiCfg.provider != .disabled,
            "mediaKindCounts": mediaKindCounts,
            "aspectShapeCounts": aspectShapeCounts,
            "folders": folderPayloads,
            "smartFolders": smartFolderPayloads,
            "topTags": topTags
        ]

        if !taxonomy.isEmpty {
            var taxDict: [String: Any] = [
                "preferredTagLanguage": taxonomy.preferredTagLanguage
            ]
            if !taxonomy.tagAliases.isEmpty { taxDict["tagAliases"] = taxonomy.tagAliases }
            if !taxonomy.folderGuidelines.isEmpty { taxDict["folderGuidelines"] = taxonomy.folderGuidelines }
            if !taxonomy.ratingMeanings.isEmpty { taxDict["ratingMeanings"] = taxonomy.ratingMeanings }
            if !taxonomy.notes.isEmpty { taxDict["notes"] = taxonomy.notes }
            payload["taxonomy"] = taxDict
        }

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

    // MARK: - Tool 2: query_assets (Unified Search / Semantic / Inbox / Similar / Contact Sheet / Folder Suggestions)

    private func handleQueryAssets(
        _ args: [String: Any],
        context: ExternalAgentRequestContext
    ) async throws -> ToolOutput {
        _ = context
        let wantSheet = Self.boolArg(args["contact_sheet"]) ?? false
        let wantFolderSuggestions = Self.boolArg(args["include_folder_suggestions"]) ?? false
        let diversify = Self.boolArg(args["diversify"]) ?? false
        let offset = max(0, Self.intArg(args["offset"]) ?? 0)
        let defaultLimit = wantSheet ? 16 : 20
        let limit = max(1, min(100, Self.intArg(args["limit"]) ?? defaultLimit))
        let defaultDetail: AssetDetailLevel = wantSheet ? .visual : .compact
        let detail = AssetDetailLevel.parse(args["detail"], fallback: defaultDetail)

        let query = ((args["query"] as? String) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let subQueries = (Self.stringArrayArg(args["queries"]) ?? [])
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        let explicitAssetIDs = try await resolveAssetUUIDList(args["asset_ids"])
        let seedIDs = try await resolveAssetUUIDList(args["seed_asset_ids"])
        let unlikeIDs = try await resolveAssetUUIDList(args["unlike_asset_ids"])

        let sessionIDRaw = (args["session_id"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let resetSession = Self.boolArg(args["reset_session"]) ?? false
        var sessionExcluded: Set<UUID> = []
        if !sessionIDRaw.isEmpty && !resetSession && explicitAssetIDs.isEmpty {
            let loaded = await ExternalAgentStateStore.loadSession(id: sessionIDRaw, in: engine.database)
            sessionExcluded = Set(loaded.seenAssetIDs)
        }

        let folders = try await engine.fetchFolders()
        let folderPathByID = Self.buildFolderPaths(folders)
        let smartFolder = try await resolveOptionalSmartFolder(from: args)

        var selectedAssets: [AssetRecord] = []
        var totalMatched = 0
        var allMatchedForFacets: [AssetRecord] = []
        var scoreByID: [UUID: Double] = [:]
        var reasonByID: [UUID: String] = [:]
        var queryGroupByID: [UUID: String] = [:]
        var multiQueryGroups: [[String: Any]] = []
        var usedCloudEmbedding = false
        var usedVisualRerank = false
        var modeLabel = "filter"

        if !explicitAssetIDs.isEmpty {
            modeLabel = "explicit_ids"
            var resolved: [AssetRecord] = []
            for uuid in explicitAssetIDs {
                if let asset = try await engine.fetchAsset(id: uuid) {
                    resolved.append(asset)
                }
            }
            resolved = try await applyPostFilters(resolved, args: args, extraExcludedIDs: [])
            totalMatched = resolved.count
            allMatchedForFacets = resolved
            selectedAssets = (diversify && offset == 0)
                ? await diversifyAssets(resolved, limit: limit)
                : Self.paginate(resolved, offset: offset, limit: limit)
        } else if subQueries.count >= 2 {
            modeLabel = "multi_query"
            var criteria = try buildFilterCriteria(from: args, folders: folders, folderPathByID: folderPathByID)
            criteria.searchQuery = ""
            let multi = try await runMultiQueryRecall(
                queries: subQueries,
                criteria: criteria,
                args: args,
                extraExcludedIDs: sessionExcluded,
                seedIDs: seedIDs,
                unlikeIDs: unlikeIDs,
                smartFolder: smartFolder,
                limit: limit,
                diversify: diversify
            )
            selectedAssets = multi.hits.map(\.hit.asset)
            totalMatched = multi.totalUniqueMatched
            allMatchedForFacets = selectedAssets
            for pair in multi.hits {
                scoreByID[pair.hit.asset.id] = pair.hit.score
                reasonByID[pair.hit.asset.id] = pair.hit.reason
                queryGroupByID[pair.hit.asset.id] = pair.queryGroup
            }
            multiQueryGroups = multi.groupsSummary
        } else if (!query.isEmpty || !subQueries.isEmpty || !seedIDs.isEmpty) && (Self.boolArg(args["only_trashed"]) != true) {
            modeLabel = seedIDs.isEmpty ? "semantic" : "visual_steering"
            let effectiveQuery = !query.isEmpty ? query : (subQueries.first ?? "")
            var criteria = try buildFilterCriteria(from: args, folders: folders, folderPathByID: folderPathByID)
            criteria.searchQuery = ""
            let allowVisualRerank = Self.boolArg(args["visual_rerank"]) ?? !wantSheet
            let fetchLimit = min(100, max((diversify ? limit * 3 : limit) + sessionExcluded.count, 36))

            if effectiveQuery.isEmpty && seedIDs.count == 1 && criteria.folderID == nil && !criteria.onlyInbox && criteria.tags.isEmpty && smartFolder == nil {
                // Fast direct similar-assets path
                var simMatches = try await engine.similarAssets(to: seedIDs[0], limit: fetchLimit)
                let unlikeSet = Set(unlikeIDs)
                let baseExcl = sessionExcluded.union(unlikeSet)
                simMatches.removeAll { baseExcl.contains($0.asset.id) }
                if !unlikeIDs.isEmpty && !simMatches.isEmpty {
                    simMatches = await applyUnlikeRepulsion(simMatches, unlikeIDs: unlikeIDs)
                }
                let postFilteredIDs = Set((try await applyPostFilters(simMatches.map(\.asset), args: args, extraExcludedIDs: sessionExcluded)).map(\.id))
                var filtered = simMatches.filter { postFilteredIDs.contains($0.asset.id) }
                totalMatched = filtered.count
                allMatchedForFacets = filtered.map(\.asset)
                if diversify && filtered.count > 1 && offset == 0 {
                    let divAssets = await diversifyAssets(filtered.map(\.asset), limit: limit)
                    let byID = Dictionary(uniqueKeysWithValues: filtered.map { ($0.asset.id, $0) })
                    filtered = divAssets.compactMap { byID[$0.id] }
                } else {
                    filtered = Self.paginate(filtered, offset: offset, limit: limit)
                }
                selectedAssets = filtered.map(\.asset)
                for item in filtered {
                    scoreByID[item.asset.id] = item.score
                    if let firstReason = item.matchReasons.first { reasonByID[item.asset.id] = firstReason }
                }
            } else {
                let report = try await engine.semanticSearch(
                    query: effectiveQuery,
                    criteria: criteria,
                    limit: fetchLimit,
                    allowVisualRerank: allowVisualRerank,
                    seedAssetIDs: seedIDs,
                    unlikeAssetIDs: unlikeIDs
                )
                usedCloudEmbedding = report.usedCloudEmbedding
                usedVisualRerank = report.usedTypeSafeJev
                var candidateHits = report.hits
                if let smartFolder {
                    candidateHits = candidateHits.filter { smartFolder.rule.matches($0.asset) }
                }
                let postFilteredIDs = Set((try await applyPostFilters(candidateHits.map(\.asset), args: args, extraExcludedIDs: sessionExcluded)).map(\.id))
                var filteredHits = candidateHits.filter { postFilteredIDs.contains($0.asset.id) }
                totalMatched = filteredHits.count
                allMatchedForFacets = filteredHits.map(\.asset)
                if diversify && filteredHits.count > 1 && offset == 0 {
                    let divAssets = await diversifyAssets(filteredHits.map(\.asset), limit: limit)
                    let byID = Dictionary(uniqueKeysWithValues: filteredHits.map { ($0.asset.id, $0) })
                    filteredHits = divAssets.compactMap { byID[$0.id] }
                } else {
                    filteredHits = Self.paginate(filteredHits, offset: offset, limit: limit)
                }
                selectedAssets = filteredHits.map(\.asset)
                for hit in filteredHits {
                    scoreByID[hit.asset.id] = hit.score
                    reasonByID[hit.asset.id] = hit.reason
                }
            }
        } else {
            modeLabel = (Self.boolArg(args["only_inbox"]) == true) ? "inbox" : "filter"
            let criteria = try buildFilterCriteria(from: args, folders: folders, folderPathByID: folderPathByID)
            var matches = try await engine.fetchAssets(matching: criteria)
            if let smartFolder {
                matches = matches.filter { smartFolder.rule.matches($0) }
            }
            matches = try await applyPostFilters(matches, args: args, extraExcludedIDs: sessionExcluded)
            totalMatched = matches.count
            allMatchedForFacets = matches
            selectedAssets = (diversify && offset == 0)
                ? await diversifyAssets(matches, limit: limit)
                : Self.paginate(matches, offset: offset, limit: limit)
        }

        // Optional folder suggestions for 1-call Inbox triage
        var suggestionsByID: [UUID: FolderSuggestion] = [:]
        if wantFolderSuggestions && !selectedAssets.isEmpty {
            let idsForSuggestion = Array(selectedAssets.prefix(20).map(\.id))
            suggestionsByID = (try? await engine.suggestFolders(for: idsForSuggestion)) ?? [:]
        }

        var serializedAssets: [[String: Any]] = selectedAssets.enumerated().map { idx, asset in
            var dict = serializeAssetSummary(asset, folderPathByID: folderPathByID, detail: detail)
            if let score = scoreByID[asset.id] {
                dict["rank"] = idx + 1
                dict["score"] = (score * 1000).rounded() / 1000
            }
            if detail != .visual, let reason = reasonByID[asset.id], !reason.isEmpty {
                dict["reason"] = reason
            }
            if let qg = queryGroupByID[asset.id] {
                dict["queryGroup"] = qg
            }
            if let sug = suggestionsByID[asset.id] {
                dict["suggestedFolder"] = [
                    "id": String(sug.folderID.uuidString.prefix(8)),
                    "path": folderPathByID[sug.folderID] ?? sug.folderName,
                    "confidence": (sug.confidence * 1000).rounded() / 1000,
                    "reason": sug.reason
                ] as [String: Any]
            }
            return dict
        }

        let hasMore = offset + serializedAssets.count < totalMatched
        var payload: [String: Any] = [
            "mode": modeLabel,
            "totalMatched": totalMatched,
            "offset": offset,
            "returned": serializedAssets.count,
            "hasMore": hasMore
        ]
        if hasMore { payload["nextOffset"] = offset + serializedAssets.count }
        if diversify { payload["diversified"] = true }
        if usedCloudEmbedding { payload["usedCloudEmbedding"] = true }
        if usedVisualRerank { payload["usedVisualRerank"] = true }
        if !multiQueryGroups.isEmpty { payload["queryGroups"] = multiQueryGroups }
        if let smartFolder {
            payload["smartFolder"] = ["id": String(smartFolder.id.uuidString.prefix(8)), "name": smartFolder.name]
        }

        // Update session working set if requested
        if !sessionIDRaw.isEmpty {
            let updatedSession = await ExternalAgentStateStore.recordSeenAssets(
                sessionID: sessionIDRaw,
                assetIDs: selectedAssets.map(\.id),
                reset: resetSession,
                in: engine.database
            )
            payload["session"] = [
                "id": updatedSession.id,
                "seenTotal": updatedSession.seenAssetIDs.count,
                "skippedSeenCount": sessionExcluded.count
            ] as [String: Any]
        }

        let includeFacets = Self.boolArg(args["include_facets"]) ?? (totalMatched > limit)
        if includeFacets && !allMatchedForFacets.isEmpty {
            payload["facets"] = Self.computeResultFacets(allMatchedForFacets, folderPathByID: folderPathByID)
        }

        // Self-steering relaxation hints on 0 matches
        if totalMatched == 0 {
            let hints = await computeRelaxationHints(args: args, folders: folders, folderPathByID: folderPathByID)
            if !hints.isEmpty {
                payload["relaxationHints"] = hints
            }
        }

        if wantSheet && !selectedAssets.isEmpty {
            let maxWidth = max(512, min(1920, Self.intArg(args["sheet_max_width"]) ?? 1024))
            if let attached = try renderAttachedContactSheet(
                for: Array(selectedAssets.prefix(24)),
                maxWidth: maxWidth
            ) {
                for idx in 0..<min(serializedAssets.count, attached.slotCount) {
                    serializedAssets[idx]["slot"] = idx + 1
                    serializedAssets[idx]["badge"] = String(format: "#%02d", idx + 1)
                }
                payload["contactSheet"] = attached.summary
                payload["assets"] = serializedAssets
                return ToolOutput(content: [
                    .image(mimeType: "image/jpeg", data: attached.jpegData),
                    .text(Self.encodeCompactJSON(payload))
                ])
            }
        }

        payload["assets"] = serializedAssets
        return .json(payload)
    }

    // MARK: - Tool 3: inspect_assets (Finalist Hydration + Crop Zoom + Cross-Machine Download URL)

    private func handleInspectAssets(
        _ args: [String: Any],
        context: ExternalAgentRequestContext
    ) async throws -> ToolOutput {
        let includeImage = Self.boolArg(args["include_image"]) ?? false
        let includeDownloadURL = Self.boolArg(args["include_download_url"]) ?? false
        let maxSide = max(280, min(1568, Self.intArg(args["image_max_side"]) ?? 768))
        let cropBox = Self.parseCropBox(args["crop_box"])

        // Batch mode (1–12 finalists)
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
                serialized.append(await serializeAssetDetail(
                    asset,
                    folderPathByID: folderPathByID,
                    iso: iso,
                    context: context,
                    includeDownloadURL: includeDownloadURL
                ))
            }

            var payload: [String: Any] = [
                "requestedCount": capped.count,
                "returned": serialized.count
            ]
            if !missingIDs.isEmpty { payload["missingIDs"] = missingIDs }

            if includeImage && !resolvedAssets.isEmpty {
                if resolvedAssets.count == 1,
                   let jpegData = preparedInspectionJPEG(for: resolvedAssets[0], targetLongSide: maxSide, cropBox: cropBox) {
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
                        jpegQuality: 0.82
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

        // Single asset mode
        guard let rawID = args["asset_id"] as? String ?? args["id"] as? String,
              let uuid = try await resolveAssetUUID(rawID) else {
            return .error("Missing or invalid UUID / 8-char prefix for `asset_id` (or pass `asset_ids` array).")
        }
        _ = try? await engine.hydrateImageMetadataIfNeeded(id: uuid)

        guard let asset = try await engine.fetchAsset(id: uuid) else {
            return .error("Asset not found: \(uuid.uuidString)")
        }
        let folders = try await engine.fetchFolders()
        let folderPathByID = Self.buildFolderPaths(folders)
        var dict = await serializeAssetDetail(
            asset,
            folderPathByID: folderPathByID,
            iso: Self.makeISO8601Formatter(),
            context: context,
            includeDownloadURL: includeDownloadURL
        )
        if let cropBox {
            dict["appliedCropBox"] = [
                "x": (cropBox.x * 1000).rounded() / 1000,
                "y": (cropBox.y * 1000).rounded() / 1000,
                "width": (cropBox.width * 1000).rounded() / 1000,
                "height": (cropBox.height * 1000).rounded() / 1000
            ]
        }

        if includeImage,
           let jpegData = preparedInspectionJPEG(for: asset, targetLongSide: maxSide, cropBox: cropBox) {
            return ToolOutput(content: [
                .image(mimeType: "image/jpeg", data: jpegData),
                .text(Self.encodeCompactJSON(dict))
            ])
        }
        return .json(dict)
    }

    // MARK: - Tool 4: get_board (List All Boards OR Read Context + Optional Inline Snapshot PNG)

    private func handleGetBoard(
        _ args: [String: Any],
        context: ExternalAgentRequestContext
    ) async throws -> ToolOutput {
        let rawBoardID = ((args["board_id"] as? String) ?? (args["id"] as? String) ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let rawTitle = ((args["title"] as? String) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)

        // List all boards when no selector is provided
        if rawBoardID.isEmpty && rawTitle.isEmpty {
            let boards = try await engine.fetchBoards()
            let formatter = Self.makeISO8601Formatter()
            let payload: [String: Any] = [
                "count": boards.count,
                "boards": boards.map { b -> [String: Any] in
                    [
                        "id": b.id.uuidString,
                        "shortID": String(b.id.uuidString.prefix(8)),
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

        guard let doc = try await resolveBoard(from: args) else {
            let existing = (try? await engine.fetchBoards()) ?? []
            let titles = existing.prefix(5).map { "\"\($0.title)\" (\(String($0.id.uuidString.prefix(8))))" }.joined(separator: ", ")
            let hint = titles.isEmpty ? "No moodboards exist yet." : "Available boards: [\(titles)]."
            return .error("Moodboard not found. \(hint)")
        }

        let detail = AssetDetailLevel.parse(args["detail"])
        let includeSnapshot = Self.boolArg(args["include_snapshot"]) ?? false
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
            ["x": f.x.rounded(), "y": f.y.rounded(), "width": f.width.rounded(), "height": f.height.rounded()]
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
                    if !context.isRemoteHTTP && detail != .compact {
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

        if includeSnapshot {
            var thumbByID: [UUID: URL] = [:]
            for assetID in doc.referencedAssetIDs {
                if let preview = await engine.thumbnailURL(for: assetID, tier: .preview1400) {
                    thumbByID[assetID] = preview
                } else if let grid = await engine.thumbnailURL(for: assetID, tier: .grid520) {
                    thumbByID[assetID] = grid
                }
            }
            let dark = Self.boolArg(args["dark_appearance"]) ?? false
            let width = CGFloat(max(840, min(2800, Self.intArg(args["snapshot_width"]) ?? 1440)))
            if let pngData = BoardImageRenderer.renderPNG(
                document: doc,
                assetsByID: assetsByID,
                thumbnailURL: { thumbByID[$0] },
                options: BoardImageRenderer.RenderOptions(canvasWidth: width, darkAppearance: dark)
            ) {
                payload["snapshot"] = [
                    "width": Int(width),
                    "darkAppearance": dark,
                    "bytes": pngData.count,
                    "mimeType": "image/png"
                ] as [String: Any]
                return ToolOutput(content: [
                    .image(mimeType: "image/png", data: pngData),
                    .text(Self.encodeCompactJSON(payload))
                ])
            }
        }

        return .json(payload)
    }

    // MARK: - Tool 5: ingest_assets (Cross-Machine `inline_files` + `web_urls` + `text` + stdio `file_paths`)

    private func handleIngestAssets(
        _ args: [String: Any],
        effectiveAccess: ExternalAgentAccessLevel,
        context: ExternalAgentRequestContext
    ) async throws -> ToolOutput {
        guard effectiveAccess.allowsInboxAndEnrichWrites else {
            return .error("当前权限为「\(effectiveAccess.displayTitle)」，无法导入素材。需要「仅收件箱与打标」或「全局整理与生板」权限。")
        }

        let folders = try await engine.fetchFolders()
        let folderPathByID = Self.buildFolderPaths(folders)
        let targetFolderID = try resolveOptionalFolderID(from: args, folders: folders, folderPathByID: folderPathByID)

        var targetBoardID: UUID?
        if let rawBoard = (args["target_board_id"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines), !rawBoard.isEmpty {
            guard effectiveAccess.allowsGlobalOrganizeWrites else {
                return .error("当前权限为「仅收件箱与打标」，不允许直接写入情绪板（`target_board_id` 需要「全局整理与生板」权限）。")
            }
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

        // Security invariant: local disk `file_path(s)` are strictly forbidden over remote HTTP MCP!
        let hasLocalFilePaths = (Self.stringArrayArg(args["file_paths"])?.isEmpty == false)
            || ((args["file_path"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false)
        if hasLocalFilePaths {
            guard !context.isRemoteHTTP else {
                return .error("远程 HTTP MCP 禁止读取服务端本机路径（`file_path`/`file_paths`）。请改用 `inline_files: [{filename, data_base64}]` 或 `web_urls`。")
            }
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
        }

        // Cross-machine inline binary uploads (`inline_files: [{filename, data_base64}]`)
        var tempUploadDir: URL?
        defer {
            if let tempUploadDir {
                try? FileManager.default.removeItem(at: tempUploadDir)
            }
        }
        if let inlineFiles = args["inline_files"] as? [[String: Any]], !inlineFiles.isEmpty {
            let maxSingleFileBytes = 16 * 1024 * 1024
            let maxTotalBytes = 32 * 1024 * 1024
            var totalDecodedBytes = 0

            let scratch = FileManager.default.temporaryDirectory
                .appending(path: "charkle-mcp-ingest-\(UUID().uuidString)", directoryHint: .isDirectory)
            try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            tempUploadDir = scratch

            for (idx, fileObj) in inlineFiles.prefix(20).enumerated() {
                let rawName = ((fileObj["filename"] as? String) ?? "upload-\(idx + 1).bin")
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                let cleanName = Self.sanitizeUploadFilename(rawName, fallbackIndex: idx + 1)
                guard let rawB64 = fileObj["data_base64"] as? String, !rawB64.isEmpty else {
                    return .error("inline_files[\(idx)] is missing non-empty `data_base64`.")
                }
                let cleanedB64: String
                if let comma = rawB64.firstIndex(of: ","), rawB64.hasPrefix("data:") {
                    cleanedB64 = String(rawB64[rawB64.index(after: comma)...])
                } else {
                    cleanedB64 = rawB64
                }
                guard let decoded = Data(base64Encoded: cleanedB64, options: [.ignoreUnknownCharacters]), !decoded.isEmpty else {
                    return .error("inline_files[\(idx)] (`\(cleanName)`) contains invalid base64 data.")
                }
                guard decoded.count <= maxSingleFileBytes else {
                    return .error("inline_files[\(idx)] (`\(cleanName)`) exceeds 16 MB per-file limit.")
                }
                totalDecodedBytes += decoded.count
                guard totalDecodedBytes <= maxTotalBytes else {
                    return .error("Total `inline_files` upload size exceeds 32 MB per-call limit.")
                }

                let fileDir = scratch.appending(path: "item-\(idx)", directoryHint: .isDirectory)
                try FileManager.default.createDirectory(at: fileDir, withIntermediateDirectories: true)
                let fileURL = fileDir.appending(path: cleanName)
                try decoded.write(to: fileURL, options: .atomic)
                inputs.append(.fileURL(fileURL))
            }
        }

        if let webURLStrings = Self.stringArrayArg(args["web_urls"]), !webURLStrings.isEmpty {
            for raw in webURLStrings {
                let clean = raw.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !clean.isEmpty else { continue }
                guard let url = URL(string: clean), let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https" else {
                    return .error("Invalid HTTP(S) URL in `web_urls`: \(clean)")
                }
                let titleForURL = (webURLStrings.count == 1 && inputs.isEmpty && singleTitle?.isEmpty == false) ? singleTitle : nil
                inputs.append(.webURL(url, title: titleForURL, notes: singleNotes?.isEmpty == false ? singleNotes : nil))
            }
        } else if let webURLString = (args["web_url"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines), !webURLString.isEmpty {
            guard let url = URL(string: webURLString), let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https" else {
                return .error("Invalid HTTP(S) `web_url`: \(webURLString)")
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
            return .error("Provide `web_url(s)`, `inline_files`, `text`, or (local stdio only) `file_path(s)`.")
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

        let run = AgentRunRecord(
            toolName: "ingest_assets",
            actor: context.actorLabel,
            transport: context.transport.rawValue,
            summary: "导入 \(finalAssets.count) 项素材",
            ingestedAssetIDs: finalAssets.map(\.id)
        )
        await ExternalAgentStateStore.recordRun(run, in: engine.database)

        let latestPaths = Self.buildFolderPaths(try await engine.fetchFolders())
        if notifyOnWrite && !finalAssets.isEmpty {
            ExternalAgentNotifier.postLibraryChanged(
                kind: targetBoardID != nil ? "boards" : "assets",
                boardID: targetBoardID,
                summary: "外部 Agent 已导入 \(finalAssets.count) 项素材"
            )
        }
        return .json([
            "runID": run.id,
            "importedCount": finalAssets.count,
            "assets": finalAssets.map { serializeAssetSummary($0, folderPathByID: latestPaths) }
        ])
    }

    // MARK: - Tool 6: organize_assets (Heterogeneous Batch + Dry-Run + Canonical Tag Folding + Run Rollback)

    private struct NormalizedOrganizeItem {
        let assetID: UUID
        let folderAssignment: FolderAssignment
        let folderTargetLabel: String?
        let addTags: [String]
        let removeTags: [String]
        let addSuggestedTags: [String]
        let acceptSuggestedTags: Bool
        let dismissSuggestedTags: [String]
        let rating: Int?
        let title: String?
        let notes: String?
        let aiDescription: String?
        let pinnedOffline: Bool?
        let isTrashed: Bool?
        let analyze: Bool
        let refreshRichMetadata: Bool

        var touchesCuratedFields: Bool {
            switch folderAssignment {
            case .unchanged: break
            case .inbox, .folder: return true
            }
            return !addTags.isEmpty || !removeTags.isEmpty || acceptSuggestedTags
                || !dismissSuggestedTags.isEmpty || rating != nil || title != nil
                || notes != nil
        }

        var hasBatchPatchFields: Bool {
            touchesCuratedFields || pinnedOffline != nil || isTrashed != nil
        }
    }

    private func handleOrganizeAssets(
        _ args: [String: Any],
        effectiveAccess: ExternalAgentAccessLevel,
        context: ExternalAgentRequestContext
    ) async throws -> ToolOutput {
        guard effectiveAccess.allowsInboxAndEnrichWrites else {
            return .error("当前权限为「仅只读」，无法整理素材。请在 Charkle「设置 → 外部 Agent」升级权限或更换密钥。")
        }

        let dryRun = Self.boolArg(args["dry_run"]) ?? false
        let folders = try await engine.fetchFolders()
        let folderPathByID = Self.buildFolderPaths(folders)
        let taxonomy = await ExternalAgentStateStore.loadTaxonomy(from: engine.database)
        let existingLibraryTags = ((try? await engine.fetchTagCounts()) ?? []).map(\.name)
        var canonicalTagLookup: [String: String] = [:]
        for existingTag in existingLibraryTags {
            canonicalTagLookup[SearchText.normalize(existingTag)] = existingTag
        }
        for (alias, canonical) in taxonomy.tagAliases {
            canonicalTagLookup[SearchText.normalize(alias)] = canonical
        }

        var normalizedTagPairs: [[String: String]] = []
        var seenNormPairs = Set<String>()
        var proposedNewTags = Set<String>()

        func canonicalizeTags(_ rawTags: [String]) -> [String] {
            var out: [String] = []
            var seen = Set<String>()
            for raw in rawTags {
                let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !trimmed.isEmpty else { continue }
                let key = SearchText.normalize(trimmed)
                let resolved: String
                if let canonical = canonicalTagLookup[key] {
                    resolved = canonical
                    if canonical != trimmed && seenNormPairs.insert("\(trimmed)->\(canonical)").inserted {
                        normalizedTagPairs.append(["from": trimmed, "to": canonical])
                    }
                } else {
                    resolved = trimmed
                    proposedNewTags.insert(trimmed)
                }
                if seen.insert(SearchText.normalize(resolved)).inserted {
                    out.append(resolved)
                }
            }
            return out
        }

        func parseOrganizeItem(from dict: [String: Any], assetID: UUID) throws -> NormalizedOrganizeItem {
            var assignment: FolderAssignment = .unchanged
            var targetLabel: String?
            if Self.boolArg(dict["move_to_inbox"]) == true {
                assignment = .inbox
                targetLabel = "Inbox"
            } else if let resolvedFolderID = try resolveOptionalFolderID(from: dict, folders: folders, folderPathByID: folderPathByID) {
                assignment = .folder(resolvedFolderID)
                targetLabel = folderPathByID[resolvedFolderID]
            }
            return NormalizedOrganizeItem(
                assetID: assetID,
                folderAssignment: assignment,
                folderTargetLabel: targetLabel,
                addTags: canonicalizeTags(Self.stringArrayArg(dict["add_tags"]) ?? []),
                removeTags: Self.stringArrayArg(dict["remove_tags"]) ?? [],
                addSuggestedTags: Self.stringArrayArg(dict["add_suggested_tags"]) ?? [],
                acceptSuggestedTags: Self.boolArg(dict["accept_suggested_tags"]) ?? false,
                dismissSuggestedTags: Self.stringArrayArg(dict["dismiss_suggested_tags"]) ?? [],
                rating: Self.intArg(dict["rating"]),
                title: dict["title"] as? String,
                notes: dict["notes"] as? String,
                aiDescription: (dict["ai_description"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
                pinnedOffline: Self.boolArg(dict["pinned_offline"]),
                isTrashed: Self.boolArg(dict["trashed"]),
                analyze: Self.boolArg(dict["analyze"]) ?? false,
                refreshRichMetadata: Self.boolArg(dict["refresh_rich_metadata"]) ?? false
            )
        }

        var items: [NormalizedOrganizeItem] = []
        if let rawItems = args["items"] as? [[String: Any]], !rawItems.isEmpty {
            guard rawItems.count <= 50 else {
                return .error("`organize_assets` accepts at most 50 heterogeneous `items` per call.")
            }
            for (idx, itemDict) in rawItems.enumerated() {
                guard let rawID = (itemDict["asset_id"] as? String) ?? (itemDict["id"] as? String),
                      let uuid = try await resolveAssetUUID(rawID) else {
                    return .error("items[\(idx)] has missing or unresolved `asset_id`.")
                }
                items.append(try parseOrganizeItem(from: itemDict, assetID: uuid))
            }
        } else {
            let ids = try await resolveAssetUUIDList(args["asset_ids"])
            guard !ids.isEmpty else {
                return .error("Provide either heterogeneous `items: [{asset_id, ...}]` or uniform `asset_ids: [...]`.")
            }
            guard ids.count <= 50 else {
                return .error("`organize_assets` accepts at most 50 assets per call.")
            }
            for uuid in ids {
                items.append(try parseOrganizeItem(from: args, assetID: uuid))
            }
        }

        // Load pre-mutation assets for scope checks, diffing, and rollback snapshots
        let uniqueIDs = Array(Set(items.map(\.assetID)))
        let loadedAssets = try await engine.database.assets(ids: uniqueIDs)
        let beforeByID = Dictionary(uniqueKeysWithValues: loadedAssets.map { ($0.id, $0) })

        var missingIDs: [String] = []
        var scopeViolations: [String] = []
        var validItems: [NormalizedOrganizeItem] = []

        for item in items {
            guard let before = beforeByID[item.assetID] else {
                missingIDs.append(item.assetID.uuidString)
                continue
            }
            if effectiveAccess == .inboxAndEnrich {
                if item.isTrashed != nil {
                    scopeViolations.append("\(String(before.id.uuidString.prefix(8)))（仅收件箱与打标权限不允许移入/恢复废纸篓）")
                    continue
                }
                if item.pinnedOffline != nil {
                    scopeViolations.append("\(String(before.id.uuidString.prefix(8)))（仅收件箱与打标权限不允许修改离线置顶）")
                    continue
                }
                if item.touchesCuratedFields && before.folderID != nil {
                    let currentPath = before.folderID.flatMap { folderPathByID[$0] } ?? "已归档目录"
                    scopeViolations.append("\(String(before.id.uuidString.prefix(8))) 位于「\(currentPath)」（仅收件箱与打标权限仅可移动/编辑收件箱素材，或对已归档素材补写 `ai_description`/`add_suggested_tags`）")
                    continue
                }
            }
            validItems.append(item)
        }

        if !scopeViolations.isEmpty {
            return .error("权限范围拦截：\(scopeViolations.prefix(5).joined(separator: "；"))")
        }

        var folderMoveCount = 0
        var trashCount = 0
        var restoreCount = 0
        var previewItems: [[String: Any]] = []
        for item in validItems {
            guard let before = beforeByID[item.assetID] else { continue }
            let fromFolder = before.folderID.flatMap { folderPathByID[$0] } ?? "Inbox"
            if let toFolder = item.folderTargetLabel, toFolder != fromFolder {
                folderMoveCount += 1
            }
            if item.isTrashed == true && !before.isTrashed { trashCount += 1 }
            if item.isTrashed == false && before.isTrashed { restoreCount += 1 }
            if dryRun {
                var diff: [String: Any] = [
                    "id": String(before.id.uuidString.prefix(8)),
                    "title": before.title,
                    "fromFolder": fromFolder
                ]
                if let toFolder = item.folderTargetLabel { diff["toFolder"] = toFolder }
                if !item.addTags.isEmpty { diff["addTags"] = item.addTags }
                if !item.removeTags.isEmpty { diff["removeTags"] = item.removeTags }
                if !item.addSuggestedTags.isEmpty { diff["addSuggestedTags"] = item.addSuggestedTags }
                if let r = item.rating { diff["rating"] = r }
                if let t = item.isTrashed { diff["trashed"] = t }
                previewItems.append(diff)
            }
        }

        if dryRun {
            var resp: [String: Any] = [
                "dryRun": true,
                "plannedCount": validItems.count,
                "folderMoveCount": folderMoveCount,
                "trashCount": trashCount,
                "restoreCount": restoreCount,
                "items": previewItems
            ]
            if !proposedNewTags.isEmpty { resp["newTags"] = proposedNewTags.sorted() }
            if !normalizedTagPairs.isEmpty { resp["normalizedTags"] = normalizedTagPairs }
            if !missingIDs.isEmpty { resp["missingIDs"] = missingIDs }
            return .json(resp)
        }

        // Capture full before-snapshots for compensating rollback
        var snapshotSet = Set<UUID>()
        var snapshots: [AgentAssetSnapshot] = []
        for item in validItems where snapshotSet.insert(item.assetID).inserted {
            if let before = beforeByID[item.assetID] {
                snapshots.append(AgentAssetSnapshot(from: before))
            }
        }

        // 1. Atomic batch patch commit
        let patches: [AssetBatchPatch] = validItems.compactMap { item in
            guard item.hasBatchPatchFields else { return nil }
            return AssetBatchPatch(
                assetIDs: [item.assetID],
                title: item.title,
                notes: item.notes,
                rating: item.rating,
                addTags: item.addTags,
                removeTags: item.removeTags,
                acceptSuggestedTags: item.acceptSuggestedTags,
                dismissSuggestedTags: item.dismissSuggestedTags,
                folderAssignment: item.folderAssignment,
                pinnedOffline: item.pinnedOffline,
                isTrashed: item.isTrashed
            )
        }
        var touchedIDs = Set<UUID>()
        if !patches.isEmpty {
            let updated = try await engine.updateAssetsBatch(patches)
            for a in updated { touchedIDs.insert(a.id) }
        }

        // 2. Apply explicit `ai_description` & `add_suggested_tags`
        let insightItems: [AgentVisualInsight] = validItems.compactMap { item in
            let desc = item.aiDescription ?? ""
            guard !desc.isEmpty || !item.addSuggestedTags.isEmpty else { return nil }
            return AgentVisualInsight(assetID: item.assetID, description: desc, tags: item.addSuggestedTags)
        }
        if !insightItems.isEmpty {
            _ = await tools.persistVisualInsights(insightItems, overwriteDescription: true)
            for item in insightItems { touchedIDs.insert(item.assetID) }
        }

        // 3. Optional local analysis & live rich metadata refresh
        let analyzeIDs = Array(Set(validItems.filter { $0.analyze || $0.refreshRichMetadata }.map(\.assetID)).prefix(20))
        if !analyzeIDs.isEmpty {
            let analyzed = try await engine.analyzeAssetsLocally(ids: analyzeIDs)
            for a in analyzed { touchedIDs.insert(a.id) }
            let refreshIDs = Set(validItems.filter(\.refreshRichMetadata).map(\.assetID))
            for asset in analyzed where refreshIDs.contains(asset.id) {
                if asset.mediaKind == .webBookmark, asset.sourceURL != nil {
                    _ = try? await engine.refreshRichAsset(id: asset.id)
                }
            }
        }

        let run = AgentRunRecord(
            toolName: "organize_assets",
            actor: context.actorLabel,
            transport: context.transport.rawValue,
            summary: "整理 \(touchedIDs.count) 项素材（移动 \(folderMoveCount) · 移至废纸篓 \(trashCount)）",
            assetSnapshots: snapshots
        )
        if !snapshots.isEmpty {
            await ExternalAgentStateStore.recordRun(run, in: engine.database)
        }

        if notifyOnWrite && !touchedIDs.isEmpty {
            ExternalAgentNotifier.postLibraryChanged(kind: "assets", summary: "外部 Agent 已整理 \(touchedIDs.count) 项素材")
        }

        var result: [String: Any] = [
            "runID": run.id,
            "updatedCount": touchedIDs.count,
            "folderMoveCount": folderMoveCount,
            "trashCount": trashCount,
            "assetIDs": Array(touchedIDs).map(\.uuidString).sorted()
        ]
        if !proposedNewTags.isEmpty { result["newTags"] = proposedNewTags.sorted() }
        if !normalizedTagPairs.isEmpty { result["normalizedTags"] = normalizedTagPairs }
        if !missingIDs.isEmpty { result["skippedIDs"] = missingIDs }
        return .json(result)
    }

    // MARK: - Tool 7: manage_folder (Create or Update — Delete Strictly Forbidden)

    private func handleManageFolder(
        _ args: [String: Any],
        effectiveAccess: ExternalAgentAccessLevel,
        context: ExternalAgentRequestContext
    ) async throws -> ToolOutput {
        guard effectiveAccess.allowsGlobalOrganizeWrites else {
            return .error("当前权限为「\(effectiveAccess.displayTitle)」，管理文件夹需要「全局整理与生板」权限。")
        }

        let action = ((args["action"] as? String) ?? "").trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let folders = try await engine.fetchFolders()
        let folderPathByID = Self.buildFolderPaths(folders)

        switch action {
        case "create":
            guard let name = (args["name"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines), !name.isEmpty else {
                return .error("Missing non-empty folder `name` for manage_folder(action:'create').")
            }
            let parentID = try resolveOptionalFolderID(
                from: ["folder_id": args["parent_id"] as Any, "folder_path": args["parent_path"] as Any],
                folders: folders,
                folderPathByID: folderPathByID
            )
            let reuseExisting = Self.boolArg(args["reuse_existing"]) ?? true
            if reuseExisting,
               let existing = folders.first(where: { $0.parentID == parentID && $0.name.caseInsensitiveCompare(name) == .orderedSame }) {
                return .json([
                    "id": existing.id.uuidString,
                    "name": existing.name,
                    "path": folderPathByID[existing.id] ?? existing.name,
                    "parentID": existing.parentID?.uuidString ?? "",
                    "reusedExisting": true
                ])
            }
            var created = try await engine.createFolder(name: name, parentID: parentID)
            let colorHex = args["color_hex"] as? String
            let customSymbol = args["custom_symbol"] as? String
            if colorHex != nil || customSymbol != nil {
                created = try await engine.updateFolderAppearance(id: created.id, colorHex: colorHex, customSymbol: customSymbol)
            }
            let refreshedPaths = Self.buildFolderPaths(try await engine.fetchFolders())
            if notifyOnWrite {
                ExternalAgentNotifier.postLibraryChanged(kind: "folders", summary: "外部 Agent 已新建文件夹「\(created.name)」")
            }
            return .json([
                "id": created.id.uuidString,
                "name": created.name,
                "path": refreshedPaths[created.id] ?? created.name,
                "parentID": created.parentID?.uuidString ?? "",
                "colorHex": created.colorHex ?? "",
                "customSymbol": created.customSymbol ?? "",
                "reusedExisting": false
            ])

        case "update":
            guard let folderID = try resolveOptionalFolderID(from: args, folders: folders, folderPathByID: folderPathByID),
                  var current = folders.first(where: { $0.id == folderID }) else {
                return .error("Folder not found. Pass a valid `folder_id` UUID/prefix or matching `folder_path`.")
            }
            let beforeSnapshot = AgentFolderSnapshot(from: current)

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

            let run = AgentRunRecord(
                toolName: "manage_folder",
                actor: context.actorLabel,
                transport: context.transport.rawValue,
                summary: "更新文件夹「\(finalFolder.name)」",
                folderSnapshots: [beforeSnapshot]
            )
            await ExternalAgentStateStore.recordRun(run, in: engine.database)

            if notifyOnWrite {
                ExternalAgentNotifier.postLibraryChanged(kind: "folders", summary: "外部 Agent 已更新文件夹「\(finalFolder.name)」")
            }
            return .json([
                "runID": run.id,
                "id": finalFolder.id.uuidString,
                "name": finalFolder.name,
                "path": finalPaths[finalFolder.id] ?? finalFolder.name,
                "parentID": finalFolder.parentID?.uuidString ?? "",
                "colorHex": finalFolder.colorHex ?? "",
                "customSymbol": finalFolder.customSymbol ?? "",
                "assetCount": finalFolder.assetCount
            ])

        default:
            return .error("Invalid `action` for manage_folder. Expected 'create' or 'update' (deleting folders is strictly forbidden).")
        }
    }

    // MARK: - Tool 8: save_moodboard (Create OR Non-Destructive Patch + Rollback Snapshot)

    private func handleSaveMoodboard(
        _ args: [String: Any],
        effectiveAccess: ExternalAgentAccessLevel,
        context: ExternalAgentRequestContext
    ) async throws -> ToolOutput {
        guard effectiveAccess.allowsGlobalOrganizeWrites else {
            return .error("当前权限为「\(effectiveAccess.displayTitle)」，创建或更新情绪板需要「全局整理与生板」权限。")
        }

        let hasBoardID = ((args["board_id"] as? String) ?? (args["id"] as? String) ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
        let hasPatchOnlyArgs = args["new_title"] != nil
            || args["add_asset_ids"] != nil
            || args["remove_asset_ids"] != nil
            || args["remove_node_ids"] != nil
            || args["add_section"] != nil
            || args["add_note"] != nil

        if hasBoardID || hasPatchOnlyArgs {
            return try await patchExistingMoodboard(args, context: context)
        }
        return try await createNewMoodboard(args, context: context)
    }

    private func createNewMoodboard(
        _ args: [String: Any],
        context: ExternalAgentRequestContext
    ) async throws -> ToolOutput {
        let title = ((args["title"] as? String) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let subtitle = ((args["subtitle"] as? String) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let layoutRaw = ((args["layout_style"] as? String) ?? "magazine").lowercased()
        let layoutStyle = EditorialStyle(rawValue: layoutRaw) ?? .magazine
        let useFreeform = Self.boolArg(args["use_freeform"]) ?? false

        let explicitSections = args["sections"] as? [[String: Any]]
        let flatAssetIDs = try await resolveAssetUUIDList(args["asset_ids"])

        if (explicitSections != nil && !(explicitSections ?? []).isEmpty) || !flatAssetIDs.isEmpty {
            var orderedAssets: [AssetRecord] = []
            var slotByAssetID: [UUID: Int] = [:]
            var slotToAsset: [Int: AssetRecord] = [:]

            func registerAsset(_ id: UUID) async throws -> Int? {
                if let existing = slotByAssetID[id] { return existing }
                guard let asset = try await engine.fetchAsset(id: id) else { return nil }
                let slot = orderedAssets.count + 1
                orderedAssets.append(asset)
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
                            picks.append(AgentBoardPlan.SlotPick(slot: slot, weight: heroSet.contains(aid) ? 2 : 1, reason: rationale))
                        }
                    }
                    if !picks.isEmpty {
                        sectionSpecs.append(AgentBoardPlan.SectionSpec(title: secTitle, tint: tint, rationale: rationale, picks: picks))
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
                    sectionSpecs.append(AgentBoardPlan.SectionSpec(title: "核心视觉参考", tint: .neutral, rationale: "", picks: picks))
                }
            }

            guard !sectionSpecs.isEmpty else {
                return .error("None of the provided `asset_ids` were found in the Charkle library.")
            }

            let noteText = ((args["curator_note"] as? String) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            let noteSpec = noteText.isEmpty ? nil : AgentBoardPlan.NoteSpec(title: "策展说明", text: noteText, style: .paper)

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
            let compiled = try await tools.compileAndVerifyBoard(plan: plan, slotToAsset: slotToAsset, request: req, recall: recall)
            let saved = try await engine.saveBoard(compiled.document)

            let run = AgentRunRecord(
                toolName: "save_moodboard",
                actor: context.actorLabel,
                transport: context.transport.rawValue,
                summary: "创建情绪板「\(saved.title)」",
                createdBoardIDs: [saved.id]
            )
            await ExternalAgentStateStore.recordRun(run, in: engine.database)

            if notifyOnWrite {
                ExternalAgentNotifier.postLibraryChanged(kind: "boards", boardID: saved.id, summary: "外部 Agent 已创建情绪板「\(saved.title)」")
            }
            return .json([
                "runID": run.id,
                "boardID": saved.id.uuidString,
                "title": saved.title,
                "subtitle": saved.subtitle,
                "mode": Self.layoutModeLabel(saved.mode),
                "itemCount": saved.referencedAssetIDs.count,
                "paletteHexes": saved.extractedPalette.map { $0.hex.uppercased() }
            ])
        }

        // Prompt-driven curation mode
        let prompt = ((args["prompt"] as? String) ?? title).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !prompt.isEmpty else {
            return .error("Provide `sections`/`asset_ids`, `prompt` (create), or `board_id` (patch).")
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

        let run = AgentRunRecord(
            toolName: "save_moodboard",
            actor: context.actorLabel,
            transport: context.transport.rawValue,
            summary: "生成情绪板「\(saved.title)」",
            createdBoardIDs: [saved.id]
        )
        await ExternalAgentStateStore.recordRun(run, in: engine.database)

        if notifyOnWrite {
            ExternalAgentNotifier.postLibraryChanged(kind: "boards", boardID: saved.id, summary: "外部 Agent 已生成情绪板「\(saved.title)」")
        }
        return .json([
            "runID": run.id,
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

    private func patchExistingMoodboard(
        _ args: [String: Any],
        context: ExternalAgentRequestContext
    ) async throws -> ToolOutput {
        guard var doc = try await resolveBoard(from: args) else {
            return .error("Moodboard not found. Pass a valid `board_id` UUID/prefix or matching `title`.")
        }
        let beforeBoard = doc

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
                        if matchesAsset, let aid = node.referencedAssetID { skippedLockedAssetIDs.append(aid.uuidString) }
                        if matchesNode { skippedLockedNodeIDs.append(node.id.uuidString) }
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

        var cursorY = (doc.nodes.map(\.frame.maxY).max() ?? 16.0) + 24.0
        var nextZ = (doc.nodes.map(\.zIndex).max() ?? 0) + 1
        var nextOrder = (doc.nodes.map(\.editorialOrder).max() ?? 0) + 1
        let leftMargin = 32.0
        let canvasWidth = 1108.0

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

        let run = AgentRunRecord(
            toolName: "save_moodboard",
            actor: context.actorLabel,
            transport: context.transport.rawValue,
            summary: "修补情绪板「\(saved.title)」（+\(addedCount) / -\(removedCount)）",
            boardSnapshots: [beforeBoard]
        )
        await ExternalAgentStateStore.recordRun(run, in: engine.database)

        if notifyOnWrite {
            ExternalAgentNotifier.postLibraryChanged(kind: "boards", boardID: saved.id, summary: "外部 Agent 已更新情绪板「\(saved.title)」")
        }

        var result: [String: Any] = [
            "runID": run.id,
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

    // MARK: - Tool 9: deduplicate_assets (Deterministic Scan + Comparison Sheet + Safe Soft-Trash Merge)

    private func handleDeduplicateAssets(
        _ args: [String: Any],
        effectiveAccess: ExternalAgentAccessLevel,
        context: ExternalAgentRequestContext
    ) async throws -> ToolOutput {
        let action = ((args["action"] as? String) ?? "scan").trimmingCharacters(in: .whitespacesAndNewlines).lowercased()

        switch action {
        case "scan":
            let folders = try await engine.fetchFolders()
            let folderPathByID = Self.buildFolderPaths(folders)
            let scopeRaw = ((args["scope"] as? String) ?? "all").trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            let scope: DeduplicationScanScope
            if scopeRaw == "inbox" {
                scope = .inbox
            } else if scopeRaw == "folder" {
                guard let fid = try resolveOptionalFolderID(from: args, folders: folders, folderPathByID: folderPathByID) else {
                    return .error("scope:'folder' requires a valid `folder_id` or `folder_path`.")
                }
                let incSub = Self.boolArg(args["include_subfolders"]) ?? true
                scope = .folder(fid, includeSubfolders: incSub)
            } else {
                scope = .allActive
            }
            let sensitivity = DeduplicationSensitivity(rawValue: ((args["sensitivity"] as? String) ?? "balanced").lowercased()) ?? .balanced
            let kinds = Self.parseMediaKinds(args["media_kinds"])
            let limit = max(1, min(20, Self.intArg(args["limit"]) ?? 6))
            let wantSheet = Self.boolArg(args["contact_sheet"]) ?? false

            let report = try await engine.scanDuplicateImages(
                scope: scope,
                sensitivity: sensitivity,
                mediaKinds: kinds.isEmpty ? nil : kinds,
                onProgress: nil
            )

            let topGroups = Array(report.groups.prefix(limit))
            var sheetAssets: [AssetRecord] = []
            var slotByAssetID: [UUID: Int] = [:]
            if wantSheet {
                for group in topGroups {
                    for cand in group.candidates where sheetAssets.count < 24 {
                        if slotByAssetID[cand.asset.id] == nil {
                            sheetAssets.append(cand.asset)
                            slotByAssetID[cand.asset.id] = sheetAssets.count
                        }
                    }
                }
            }

            let serializedGroups: [[String: Any]] = topGroups.enumerated().map { idx, group in
                let candidates: [[String: Any]] = group.candidates.map { cand in
                    var c: [String: Any] = [
                        "id": String(cand.asset.id.uuidString.prefix(8)),
                        "fullID": cand.asset.id.uuidString,
                        "title": cand.asset.title,
                        "folderPath": cand.asset.folderID.flatMap { folderPathByID[$0] } ?? "Inbox",
                        "format": cand.formatLabel,
                        "fileSizeBytes": cand.asset.fileSizeBytes,
                        "qualityScore": (cand.qualityScore * 100).rounded() / 100,
                        "isRecommendedKeep": cand.isRecommendedKeep,
                        "isReferencedByBoard": cand.isReferencedByBoard,
                        "qualityReasons": cand.qualityReasons
                    ]
                    if cand.asset.pixelWidth > 0 && cand.asset.pixelHeight > 0 {
                        c["dimensions"] = "\(cand.asset.pixelWidth)x\(cand.asset.pixelHeight)"
                    }
                    if let slot = slotByAssetID[cand.asset.id] {
                        c["slot"] = slot
                        c["badge"] = String(format: "#%02d", slot)
                    }
                    return c
                }
                return [
                    "groupIndex": idx + 1,
                    "matchKind": group.matchKind.rawValue,
                    "similarity": (group.similarityScore * 1000).rounded() / 1000,
                    "recommendedKeepID": String(group.recommendedKeepAssetID.uuidString.prefix(8)),
                    "reclaimableBytes": group.reclaimableBytes,
                    "candidates": candidates
                ]
            }

            var payload: [String: Any] = [
                "scannedAssetCount": report.scannedAssetCount,
                "totalGroups": report.groups.count,
                "returnedGroups": serializedGroups.count,
                "totalDuplicateItems": report.totalDuplicateItems,
                "totalReclaimableBytes": report.totalReclaimableBytes,
                "groups": serializedGroups
            ]

            if wantSheet && !sheetAssets.isEmpty {
                let maxWidth = max(512, min(1920, Self.intArg(args["sheet_max_width"]) ?? 1024))
                if let attached = try renderAttachedContactSheet(for: sheetAssets, maxWidth: maxWidth) {
                    payload["contactSheet"] = attached.summary
                    return ToolOutput(content: [
                        .image(mimeType: "image/jpeg", data: attached.jpegData),
                        .text(Self.encodeCompactJSON(payload))
                    ])
                }
            }
            return .json(payload)

        case "merge":
            guard effectiveAccess.allowsGlobalOrganizeWrites else {
                return .error("当前权限为「\(effectiveAccess.displayTitle)」，合并去重需要「全局整理与生板」权限。")
            }
            guard let rawGroups = args["groups"] as? [[String: Any]], !rawGroups.isEmpty else {
                return .error("Provide non-empty `groups: [{keep_asset_id, discard_asset_ids}]` for deduplicate_assets(action:'merge').")
            }
            let dryRun = Self.boolArg(args["dry_run"]) ?? false

            var plans: [DeduplicationResolutionPlan] = []
            var allTouchedAssetIDs = Set<UUID>()
            var allDiscardedIDs = Set<UUID>()
            for (idx, g) in rawGroups.prefix(20).enumerated() {
                guard let keepRaw = g["keep_asset_id"] as? String,
                      let keepUUID = try await resolveAssetUUID(keepRaw) else {
                    return .error("groups[\(idx)] has invalid `keep_asset_id`.")
                }
                let discardUUIDs = try await resolveAssetUUIDList(g["discard_asset_ids"]).filter { $0 != keepUUID }
                guard !discardUUIDs.isEmpty else {
                    return .error("groups[\(idx)] has no valid `discard_asset_ids` distinct from `keep_asset_id`.")
                }
                plans.append(DeduplicationResolutionPlan(keepAssetID: keepUUID, removeAssetIDs: discardUUIDs))
                allTouchedAssetIDs.insert(keepUUID)
                for did in discardUUIDs {
                    allTouchedAssetIDs.insert(did)
                    allDiscardedIDs.insert(did)
                }
            }

            if dryRun {
                return .json([
                    "dryRun": true,
                    "plannedGroups": plans.count,
                    "discardToTrashCount": allDiscardedIDs.count,
                    "disposal": "moveToTrash",
                    "mergeMetadata": true
                ])
            }

            // Capture before-snapshots of all assets and affected boards for compensating rollback
            let beforeAssets = try await engine.database.assets(ids: Array(allTouchedAssetIDs))
            let assetSnapshots = beforeAssets.map(AgentAssetSnapshot.init(from:))
            let allBoards = try await engine.database.fetchBoards()
            let affectedBoards = allBoards.filter { board in
                let refs = Set(board.referencedAssetIDs + board.candidateAssetIDs)
                return !refs.isDisjoint(with: allDiscardedIDs)
            }

            // Non-negotiable safety invariant: ALWAYS `.moveToTrash` (never `.permanentlyDelete`)!
            let cleanup = try await engine.resolveDuplicateGroups(
                plans,
                disposal: .moveToTrash,
                mergeMetadata: true
            )

            let run = AgentRunRecord(
                toolName: "deduplicate_assets",
                actor: context.actorLabel,
                transport: context.transport.rawValue,
                summary: "去重合并 \(cleanup.resolvedGroupCount) 组（\(cleanup.removedAssetCount) 项移入废纸篓）",
                assetSnapshots: assetSnapshots,
                boardSnapshots: affectedBoards
            )
            await ExternalAgentStateStore.recordRun(run, in: engine.database)

            if notifyOnWrite {
                ExternalAgentNotifier.postLibraryChanged(kind: "assets", summary: "外部 Agent 已完成 \(cleanup.resolvedGroupCount) 组智能去重合并")
            }

            return .json([
                "runID": run.id,
                "resolvedGroupCount": cleanup.resolvedGroupCount,
                "movedToTrashCount": cleanup.removedAssetCount,
                "reclaimedBytes": cleanup.reclaimedBytes,
                "mergedMetadataCount": cleanup.mergedMetadataCount,
                "updatedBoardCount": cleanup.updatedBoardCount,
                "note": "Discarded duplicates moved to reversible soft Trash; metadata and Moodboard references preserved."
            ])

        default:
            return .error("Invalid `action` for deduplicate_assets. Expected 'scan' or 'merge'.")
        }
    }

    // MARK: - Tool 10: rollback_run (Audit Listing + Atomic Compensating HLC Rollback)

    private func handleRollbackRun(
        _ args: [String: Any],
        effectiveAccess: ExternalAgentAccessLevel,
        context: ExternalAgentRequestContext
    ) async throws -> ToolOutput {
        _ = context
        let action = ((args["action"] as? String) ?? "list").trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let iso = Self.makeISO8601Formatter()

        switch action {
        case "list":
            let limit = max(1, min(30, Self.intArg(args["limit"]) ?? 15))
            let runs = await ExternalAgentStateStore.listRuns(in: engine.database, limit: limit)
            let items: [[String: Any]] = runs.map { r in
                var entry: [String: Any] = [
                    "runID": r.id,
                    "toolName": r.toolName,
                    "actor": r.actor,
                    "transport": r.transport,
                    "summary": r.summary,
                    "affectedCount": r.affectedCount,
                    "createdAt": iso.string(from: r.createdAt),
                    "isRolledBack": r.isRolledBack
                ]
                if let rolled = r.rolledBackAt {
                    entry["rolledBackAt"] = iso.string(from: rolled)
                }
                return entry
            }
            return .json([
                "count": items.count,
                "runs": items
            ])

        case "rollback":
            guard effectiveAccess.allowsInboxAndEnrichWrites else {
                return .error("当前权限为「仅只读」，无法执行回滚操作。")
            }
            guard let runID = (args["run_id"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines), !runID.isEmpty else {
                return .error("Missing `run_id` for rollback_run(action:'rollback'). Call rollback_run(action:'list') first.")
            }
            guard let run = await ExternalAgentStateStore.loadRun(id: runID, in: engine.database) else {
                return .error("Agent run not found: \(runID)")
            }
            if run.isRolledBack {
                return .error("Run \(run.id) has already been rolled back.")
            }
            // Rolling back folders, moodboards, or non-inbox asset edits requires global write permission.
            let requiresGlobal = !run.folderSnapshots.isEmpty
                || !run.boardSnapshots.isEmpty
                || run.assetSnapshots.contains(where: { $0.folderID != nil || $0.isTrashed })
            if requiresGlobal && !effectiveAccess.allowsGlobalOrganizeWrites {
                return .error("回滚批次 \(run.id) 涉及已归档目录、文件夹或情绪板，需要「全局整理与生板」权限。")
            }

            // 1. Restore modified assets in one atomic SQLite transaction (emitting compensating HLC ops)
            var restoredAssetCount = 0
            if !run.assetSnapshots.isEmpty {
                restoredAssetCount = try await engine.database.transaction { store in
                    var count = 0
                    for snap in run.assetSnapshots {
                        guard var asset = try store.asset(id: snap.assetID) else { continue }
                        asset.title = snap.title
                        asset.notes = snap.notes
                        asset.aiDescription = snap.aiDescription
                        asset.rating = snap.rating
                        asset.tags = snap.tags
                        asset.suggestedTags = snap.suggestedTags
                        asset.folderID = snap.folderID
                        asset.pinnedOffline = snap.pinnedOffline
                        asset.isTrashed = snap.isTrashed
                        _ = try store.saveAssetLocally(asset, projectLocation: true)
                        count += 1
                    }
                    return count
                }
            }

            // 2. Soft-trash newly ingested assets (never permanent delete)
            var softTrashedIngestedCount = 0
            if !run.ingestedAssetIDs.isEmpty {
                let trashed = try await engine.updateAssets(AssetBatchPatch(assetIDs: run.ingestedAssetIDs, isTrashed: true))
                softTrashedIngestedCount = trashed.count
            }

            // 3. Restore updated folders
            var restoredFolderCount = 0
            for fSnap in run.folderSnapshots {
                _ = try? await engine.renameFolder(id: fSnap.folderID, newName: fSnap.name)
                _ = try? await engine.moveFolder(id: fSnap.folderID, newParentID: fSnap.parentID, insertAtIndex: nil)
                _ = try? await engine.updateFolderAppearance(id: fSnap.folderID, colorHex: fSnap.colorHex, customSymbol: fSnap.customSymbol)
                restoredFolderCount += 1
            }

            // 4. Restore patched boards
            var restoredBoardCount = 0
            for var boardSnap in run.boardSnapshots {
                boardSnap.updatedAt = Date()
                _ = try await engine.saveBoard(boardSnap)
                restoredBoardCount += 1
            }

            await ExternalAgentStateStore.markRunRolledBack(id: run.id, in: engine.database)
            if notifyOnWrite {
                ExternalAgentNotifier.postLibraryChanged(kind: "assets", summary: "已回滚外部 Agent 批次 \(run.id)")
            }

            var result: [String: Any] = [
                "rolledBackRunID": run.id,
                "originalTool": run.toolName,
                "restoredAssetCount": restoredAssetCount,
                "softTrashedIngestedCount": softTrashedIngestedCount,
                "restoredFolderCount": restoredFolderCount,
                "restoredBoardCount": restoredBoardCount
            ]
            if !run.createdBoardIDs.isEmpty {
                result["unremovedCreatedBoardIDs"] = run.createdBoardIDs.map(\.uuidString)
                result["note"] = "Newly created Moodboards are preserved (hard delete disabled via MCP); delete manually in Charkle if unwanted."
            }
            return .json(result)

        default:
            return .error("Invalid `action` for rollback_run. Expected 'list' or 'rollback'.")
        }
    }

    // MARK: - Helpers

    private func preparedInspectionJPEG(
        for asset: AssetRecord,
        targetLongSide: Int,
        cropBox: NormalizedCropRect?
    ) -> Data? {
        guard let cropBox, cropBox.isMeaningfulSubregion else {
            return tools.preparedTypeSafeJPEG(for: asset, targetLongSide: targetLongSide)
        }
        let originalURL = engine.media.originalPath(for: asset)
        let candidateURLs: [URL] = [
            (asset.mediaKind == .image && FileManager.default.fileExists(atPath: originalURL.path)) ? originalURL : nil,
            engine.media.thumbnailURL(for: asset.id, tier: .preview1400),
            engine.media.thumbnailURL(for: asset.id, tier: .grid520)
        ].compactMap { $0 }

        for url in candidateURLs {
            guard let cg = MediaPipeline.raster(url)?.poster else { continue }
            let w = Double(cg.width)
            let h = Double(cg.height)
            let safe = cropBox.clamped()
            let rect = CGRect(
                x: max(0, (safe.x * w).rounded(.down)),
                y: max(0, (safe.y * h).rounded(.down)),
                width: max(16, min(w, (safe.width * w).rounded())),
                height: max(16, min(h, (safe.height * h).rounded()))
            ).intersection(CGRect(x: 0, y: 0, width: w, height: h))
            guard rect.width >= 16, rect.height >= 16, let cropped = cg.cropping(to: rect) else { continue }
            if let jpeg = TypeSafeImagePreparer.prepareJPEG(from: cropped, targetLongSide: targetLongSide) {
                return jpeg
            }
        }
        return tools.preparedTypeSafeJPEG(for: asset, targetLongSide: targetLongSide)
    }

    private static func parseCropBox(_ raw: Any?) -> NormalizedCropRect? {
        guard let dict = raw as? [String: Any],
              let x = doubleArg(dict["x"]),
              let y = doubleArg(dict["y"]),
              let w = doubleArg(dict["width"]),
              let h = doubleArg(dict["height"]),
              x.isFinite, y.isFinite, w.isFinite, h.isFinite,
              w >= 0.02, h >= 0.02 else {
            return nil
        }
        return NormalizedCropRect(x: x, y: y, width: w, height: h).clamped()
    }

    private static func sanitizeUploadFilename(_ raw: String, fallbackIndex: Int) -> String {
        let base = URL(fileURLWithPath: raw).lastPathComponent
        let cleaned = base.filter { ch in
            ch != "/" && ch != "\\" && ch != "\0" && ch != ":" && !ch.isNewline
        }.trimmingCharacters(in: .whitespacesAndNewlines)
        if cleaned.isEmpty || cleaned == "." || cleaned == ".." || cleaned.hasPrefix(".") {
            return "agent-upload-\(fallbackIndex).bin"
        }
        return String(cleaned.prefix(120))
    }

    private func computeRelaxationHints(
        args: [String: Any],
        folders: [FolderRecord],
        folderPathByID: [UUID: String]
    ) async -> [String] {
        var hints: [String] = []
        if args["tone"] != nil {
            var relaxed = args
            relaxed.removeValue(forKey: "tone")
            if let criteria = try? buildFilterCriteria(from: relaxed, folders: folders, folderPathByID: folderPathByID),
               let raw = try? await engine.fetchAssets(matching: criteria),
               let post = try? await applyPostFilters(raw, args: relaxed, extraExcludedIDs: []),
               !post.isEmpty {
                hints.append("Removing `tone` filter yields \(post.count) matching assets.")
            }
        }
        if args["folder_path"] != nil || args["folder_id"] != nil {
            var relaxed = args
            relaxed.removeValue(forKey: "folder_path")
            relaxed.removeValue(forKey: "folder_id")
            if let criteria = try? buildFilterCriteria(from: relaxed, folders: folders, folderPathByID: folderPathByID),
               let raw = try? await engine.fetchAssets(matching: criteria),
               let post = try? await applyPostFilters(raw, args: relaxed, extraExcludedIDs: []),
               !post.isEmpty {
                hints.append("Searching across all folders yields \(post.count) matching assets.")
            }
        }
        return hints
    }

    private func applyUnlikeRepulsion(_ matches: [ScoredAsset], unlikeIDs: [UUID]) async -> [ScoredAsset] {
        let featurePrints = (try? await engine.database.featurePrints()) ?? [:]
        let unlikeObs = unlikeIDs.compactMap { featurePrints[$0].flatMap(VisionAnalyzer.unarchiveFeaturePrint) }
        guard !unlikeObs.isEmpty else { return matches }
        return matches.map { item -> ScoredAsset in
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
                    let preview = matches.prefix(3).map { "\(String($0.id.uuidString.prefix(13))) (\(folderPathByID[$0.id] ?? $0.name))" }.joined(separator: ", ")
                    throw LibraryDatabaseError("Ambiguous folder_id prefix '\(rawID)' matched multiple folders: [\(preview)].")
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
            let closest = folders
                .map { (path: folderPathByID[$0.id] ?? $0.name, id: String($0.id.uuidString.prefix(8))) }
                .filter { $0.path.localizedCaseInsensitiveContains(path) || path.localizedCaseInsensitiveContains($0.path) }
                .prefix(3)
            let suggestionList: String
            if !closest.isEmpty {
                suggestionList = closest.map { "\"\($0.path)\" (\($0.id))" }.joined(separator: ", ")
            } else {
                suggestionList = folders.prefix(4).map { "\"\(folderPathByID[$0.id] ?? $0.name)\" (\(String($0.id.uuidString.prefix(8))))" }.joined(separator: ", ")
            }
            let hint = suggestionList.isEmpty ? "No folders exist yet." : "Existing folders: [\(suggestionList)]."
            throw LibraryDatabaseError("Folder not found: '\(path)'. \(hint)")
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

    private func runMultiQueryRecall(
        queries: [String],
        criteria: FilterCriteria,
        args: [String: Any],
        extraExcludedIDs: Set<UUID>,
        seedIDs: [UUID],
        unlikeIDs: [UUID],
        smartFolder: SmartFolderRecord?,
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
            var candidates = report.hits
            if let smartFolder {
                candidates = candidates.filter { smartFolder.rule.matches($0.asset) }
            }
            let postFilteredIDs = Set((try await applyPostFilters(candidates.map(\.asset), args: args, extraExcludedIDs: extraExcludedIDs)).map(\.id))
            var groupHits = candidates.filter { postFilteredIDs.contains($0.asset.id) }
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
            var summary: [String: Any] = ["query": q, "count": badges.count]
            if !badges.isEmpty {
                summary["slotRange"] = badges.count == 1 ? badges[0] : "\(String(format: "#%02d", startSlot))..\(badges.last ?? "")"
            }
            groupsSummary.append(summary)
        }

        return MultiQueryRecallResult(hits: merged, groupsSummary: groupsSummary, totalUniqueMatched: allUniqueMatched.count)
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

        var summary: [String: Any] {
            [
                "width": width,
                "height": height,
                "slotCount": slotCount,
                "bytes": bytes
            ]
        }
    }

    private func renderAttachedContactSheet(
        for assets: [AssetRecord],
        maxWidth: Int,
        jpegQuality: Double = 0.74
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
        return AttachedContactSheet(
            jpegData: sheet.jpegData,
            width: sheet.width,
            height: sheet.height,
            slotCount: sheet.orderedSlots.count,
            bytes: sheet.jpegData.count
        )
    }

    private func applyPostFilters(
        _ assets: [AssetRecord],
        args: [String: Any],
        extraExcludedIDs: Set<UUID>
    ) async throws -> [AssetRecord] {
        let anyTags = Set((Self.stringArrayArg(args["any_tags"]) ?? []).map(SearchText.normalize).filter { !$0.isEmpty })
        let excludeTags = Set((Self.stringArrayArg(args["exclude_tags"]) ?? []).map(SearchText.normalize).filter { !$0.isEmpty })
        let explicitExcludeIDs = Set(try await resolveAssetUUIDList(args["exclude_asset_ids"]))
        let excludeIDs = explicitExcludeIDs.union(extraExcludedIDs)
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

    private func diversifyAssets(_ assets: [AssetRecord], limit: Int) async -> [AssetRecord] {
        guard assets.count > 1, limit > 1 else {
            return Array(assets.prefix(limit))
        }
        let featurePrints = (try? await engine.database.featurePrints()) ?? [:]
        let probePool = Array(assets.prefix(max(limit * 6, 96)))

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

        var folderOrder: [UUID?] = []
        var buckets: [UUID?: [AssetRecord]] = [:]
        for asset in deduped {
            if buckets[asset.folderID] == nil { folderOrder.append(asset.folderID) }
            buckets[asset.folderID, default: []].append(asset)
        }
        guard folderOrder.count >= 2 else {
            return Array(deduped.prefix(limit))
        }

        var selected: [AssetRecord] = []
        selected.reserveCapacity(min(limit, deduped.count))
        var cursorByFolder: [UUID?: Int] = [:]
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
            for tag in asset.tags { tagCounts[tag, default: 0] += 1 }
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
        let topColors = colorWeights.sorted { $0.value > $1.value }.prefix(5).map(\.key)

        var facets: [String: Any] = [
            "topFolders": topFolders,
            "topTags": topTags,
            "aspectShapes": shapeCounts
        ]
        if !topColors.isEmpty { facets["topColors"] = topColors }
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
                    for tag in asset.tags { tagCounts[tag, default: 0] += 1 }
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
            if asset.mediaKind != .image { dict["mediaKind"] = asset.mediaKind.rawValue }
            if asset.rating > 0 { dict["rating"] = asset.rating }
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
        if asset.rating > 0 { dict["rating"] = asset.rating }
        if !asset.tags.isEmpty { dict["tags"] = asset.tags }
        let colorCap = detail == .compact ? 3 : 5
        let colors = asset.dominantColors.prefix(colorCap).map { $0.hex.uppercased() }
        if !colors.isEmpty { dict["dominantColors"] = colors }
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
        iso: ISO8601DateFormatter,
        context: ExternalAgentRequestContext,
        includeDownloadURL: Bool
    ) async -> [String: Any] {
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
        let ocr = (asset.ocrText ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let socialBody = asset.richMetadata?.socialPost?.bodyText.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !ocr.isEmpty && ocr != asset.notes.trimmingCharacters(in: .whitespacesAndNewlines) && ocr != socialBody {
            dict["ocrText"] = Self.truncateText(ocr, maxChars: 2400)
        }
        if !asset.suggestedTags.isEmpty { dict["suggestedTags"] = asset.suggestedTags }
        if let domain = asset.sourceDomain, !domain.isEmpty { dict["sourceDomain"] = domain }
        dict["pinnedOffline"] = asset.pinnedOffline
        dict["isLocalOriginalCached"] = localOriginal != nil

        // Expose local filesystem paths ONLY on local stdio transport; over remote HTTP issue signed download URLs instead.
        if !context.isRemoteHTTP {
            let thumbURL = await engine.thumbnailURL(for: asset.id, tier: .grid520)
            let previewURL = await engine.thumbnailURL(for: asset.id, tier: .preview1400)
            if let thumbPath = thumbURL?.path, !thumbPath.isEmpty { dict["thumbnailPath"] = thumbPath }
            if let previewPath = previewURL?.path, !previewPath.isEmpty { dict["previewPath"] = previewPath }
            if let localOriginal, !localOriginal.isEmpty { dict["localOriginalPath"] = localOriginal }
        }
        if includeDownloadURL, let issuer = context.issueDownloadURL, let dlURL = await issuer(asset.id) {
            dict["downloadURL"] = dlURL
        }

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
                    ["kind": att.kind.rawValue, "url": att.url, "thumbnailURL": att.thumbnailURL ?? ""]
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

        if let excerpt = rich.textExcerpt, !excerpt.isEmpty { out["textExcerpt"] = excerpt }
        if rich.isMarkdown { out["isMarkdown"] = true }
        if let modelFmt = rich.model3DFormat, !modelFmt.isEmpty { out["model3DFormat"] = modelFmt }

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
