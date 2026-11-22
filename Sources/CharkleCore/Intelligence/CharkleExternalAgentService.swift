import Foundation

/// Grounded External Agent Service powering BOTH:
/// 1. Native Swift **MCP Server (`charkle mcp`)** over stdio JSON-RPC 2.0
/// 2. Native Swift **CLI (`charkle <command> --json`)** for scripts, skills, and terminal workflows
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

    // MARK: - MCP JSON-RPC 2.0 Dispatcher

    /// Handles a single JSON-RPC 2.0 message payload and returns the serialized JSON response,
    /// or `nil` for JSON-RPC notifications that expect no reply.
    public func handleJSONRPC(_ payload: Data) async -> Data? {
        guard let obj = try? JSONSerialization.jsonObject(with: payload) as? [String: Any] else {
            return makeErrorResponse(id: nil, code: -32700, message: "Parse error: invalid JSON")
        }

        let id = obj["id"]
        let isNotification = (id == nil || id is NSNull)
        guard let method = obj["method"] as? String else {
            return isNotification ? nil : makeErrorResponse(id: id, code: -32600, message: "Invalid Request: missing method")
        }
        let params = obj["params"] as? [String: Any] ?? [:]

        switch method {
        case "initialize":
            let requestedVersion = (params["protocolVersion"] as? String) ?? "2025-03-26"
            let result: [String: Any] = [
                "protocolVersion": requestedVersion,
                "capabilities": [
                    "tools": ["listChanged": false],
                    "resources": ["subscribe": false, "listChanged": false]
                ],
                "serverInfo": [
                    "name": "charkle",
                    "version": "1.0.0"
                ],
                "instructions": "Charkle is a macOS visual reference library and moodboard studio. Use `library_overview` to inspect folders and tags, `search_assets` / `list_inbox` to find candidates, `render_contact_sheet` to visually inspect up to 16 numbered thumbnails in one image, `get_board_context` / `export_board_image` to inspect moodboards, and write tools (`organize_assets`, `compose_moodboard`, `patch_moodboard`, `ingest_asset`, `trash_assets`) when write access is enabled in Charkle Settings."
            ]
            return makeResultResponse(id: id, result: result)

        case "notifications/initialized", "notifications/cancelled", "initialized":
            return nil

        case "ping":
            return makeResultResponse(id: id, result: [:])

        case "tools/list":
            return makeResultResponse(id: id, result: ["tools": Self.mcpToolDefinitions()])

        case "tools/call":
            guard let name = params["name"] as? String else {
                return makeErrorResponse(id: id, code: -32602, message: "Invalid params: missing tool name")
            }
            let args = params["arguments"] as? [String: Any] ?? [:]
            let output = await callTool(name: name, arguments: args)
            let result: [String: Any] = [
                "content": output.content.map { $0.mcpObject() },
                "isError": output.isError
            ]
            return makeResultResponse(id: id, result: result)

        case "resources/list":
            let resources: [[String: Any]] = [
                [
                    "uri": "charkle://library/overview",
                    "name": "Charkle Library Overview",
                    "description": "Folders, top tags, media distribution, and counts for the local Charkle library.",
                    "mimeType": "application/json"
                ],
                [
                    "uri": "charkle://boards",
                    "name": "Charkle Moodboards",
                    "description": "Summary list of all moodboards in Charkle.",
                    "mimeType": "application/json"
                ]
            ]
            return makeResultResponse(id: id, result: ["resources": resources])

        case "resources/read":
            guard let uri = params["uri"] as? String else {
                return makeErrorResponse(id: id, code: -32602, message: "Missing resource uri")
            }
            let policy = currentPolicy()
            guard policy.allowsRead else {
                return makeErrorResponse(id: id, code: -32001, message: "Charkle external agent access is disabled in Settings.")
            }
            if uri == "charkle://library/overview" {
                let out = await callTool(name: "library_overview", arguments: [:])
                let text = out.content.compactMap { if case .text(let t) = $0 { return t } else { return nil } }.joined(separator: "\n")
                return makeResultResponse(id: id, result: [
                    "contents": [["uri": uri, "mimeType": "application/json", "text": text]]
                ])
            } else if uri == "charkle://boards" {
                let out = await callTool(name: "list_boards", arguments: [:])
                let text = out.content.compactMap { if case .text(let t) = $0 { return t } else { return nil } }.joined(separator: "\n")
                return makeResultResponse(id: id, result: [
                    "contents": [["uri": uri, "mimeType": "application/json", "text": text]]
                ])
            } else {
                return makeErrorResponse(id: id, code: -32002, message: "Unknown resource URI: \(uri)")
            }

        default:
            if isNotification { return nil }
            return makeErrorResponse(id: id, code: -32601, message: "Method not found: \(method)")
        }
    }

    // MARK: - Unified Grounded Tool Execution (MCP + CLI)

    private static let writeToolNames: Set<String> = [
        "organize_assets",
        "create_folder",
        "ingest_asset",
        "compose_moodboard",
        "patch_moodboard",
        "trash_assets"
    ]

    public func callTool(name: String, arguments args: [String: Any]) async -> ToolOutput {
        let policy = currentPolicy()
        guard policy.allowsRead else {
            return .error("外部 Agent 接入已在 Charkle「设置 → 外部 Agent 与 MCP」中关闭，请先开启后再试。")
        }
        if Self.writeToolNames.contains(name) && !policy.allowsWrite {
            return .error("当前 Charkle 外部 Agent 权限为「仅只读检索与导出」，无法执行写入操作「\(name)」。请在 Charkle「设置 → 外部 Agent 与 MCP」中切换为「允许整理与生成情绪板」。")
        }

        do {
            switch name {
            case "library_overview":
                return try await handleLibraryOverview(policy: policy)
            case "search_assets":
                return try await handleSearchAssets(args)
            case "list_inbox":
                return try await handleListInbox(args)
            case "get_asset":
                return try await handleGetAsset(args)
            case "render_contact_sheet":
                return try await handleRenderContactSheet(args)
            case "list_boards":
                return try await handleListBoards()
            case "get_board_context":
                return try await handleGetBoardContext(args)
            case "export_board_image":
                return try await handleExportBoardImage(args)
            case "organize_assets":
                return try await handleOrganizeAssets(args)
            case "create_folder":
                return try await handleCreateFolder(args)
            case "ingest_asset":
                return try await handleIngestAsset(args)
            case "compose_moodboard":
                return try await handleComposeMoodboard(args)
            case "patch_moodboard":
                return try await handlePatchMoodboard(args)
            case "trash_assets":
                return try await handleTrashAssets(args)
            default:
                return .error("Unknown Charkle tool: \(name)")
            }
        } catch {
            return .error("Tool \(name) failed: \(error.localizedDescription)")
        }
    }

    // MARK: - Read Tool Handlers

    private func handleLibraryOverview(policy: ExternalAgentConfig) async throws -> ToolOutput {
        let overview = try await tools.libraryOverview()
        let payload: [String: Any] = [
            "totalAssets": overview.totalAssets,
            "inboxCount": overview.inboxCount,
            "boardCount": overview.boardCount,
            "accessLevel": policy.accessLevel.rawValue,
            "canWrite": policy.allowsWrite,
            "mediaKindCounts": overview.mediaKindCounts,
            "folders": overview.folders.map { folder -> [String: Any] in
                [
                    "id": folder.id.uuidString,
                    "name": folder.name,
                    "path": folder.path,
                    "assetCount": folder.assetCount
                ]
            },
            "topTags": overview.topTags.prefix(40).map { tag -> [String: Any] in
                ["name": tag.name, "count": tag.count]
            }
        ]
        return .json(payload)
    }

    private func handleSearchAssets(_ args: [String: Any]) async throws -> ToolOutput {
        let folders = try await engine.fetchFolders()
        let folderPathByID = Self.buildFolderPaths(folders)
        let criteria = try buildFilterCriteria(from: args, folders: folders, folderPathByID: folderPathByID)
        let limit = max(1, min(100, Self.intArg(args["limit"]) ?? 30))

        let matches = try await engine.fetchAssets(matching: criteria)
        let sliced = Array(matches.prefix(limit))
        let payload: [String: Any] = [
            "totalMatched": matches.count,
            "returned": sliced.count,
            "assets": sliced.map { serializeAssetSummary($0, folderPathByID: folderPathByID) }
        ]
        return .json(payload)
    }

    private func handleListInbox(_ args: [String: Any]) async throws -> ToolOutput {
        let limit = max(1, min(100, Self.intArg(args["limit"]) ?? 40))
        let matches = try await engine.fetchAssets(matching: FilterCriteria(onlyInbox: true, sortBy: .newest))
        let sliced = Array(matches.prefix(limit))
        let payload: [String: Any] = [
            "inboxTotal": matches.count,
            "returned": sliced.count,
            "assets": sliced.map { serializeAssetSummary($0, folderPathByID: [:]) }
        ]
        return .json(payload)
    }

    private func handleGetAsset(_ args: [String: Any]) async throws -> ToolOutput {
        guard let rawID = args["asset_id"] as? String ?? args["id"] as? String,
              let uuid = UUID(uuidString: rawID.trimmingCharacters(in: .whitespacesAndNewlines)) else {
            return .error("Missing or invalid UUID for `asset_id`.")
        }
        guard let asset = try await engine.fetchAsset(id: uuid) else {
            return .error("Asset not found: \(uuid.uuidString)")
        }
        let folders = try await engine.fetchFolders()
        let folderPathByID = Self.buildFolderPaths(folders)
        let thumbURL = await engine.thumbnailURL(for: uuid, tier: .grid520)
        let candidateOriginal = engine.media.originalPath(for: asset)
        let localOriginal = FileManager.default.fileExists(atPath: candidateOriginal.path) ? candidateOriginal.path : nil
        var dict = serializeAssetSummary(asset, folderPathByID: folderPathByID)
        dict["ocrText"] = asset.ocrText ?? ""
        dict["suggestedTags"] = asset.suggestedTags
        dict["sourceDomain"] = asset.sourceDomain ?? ""
        dict["fileSizeBytes"] = asset.fileSizeBytes
        dict["pixelWidth"] = asset.pixelWidth
        dict["pixelHeight"] = asset.pixelHeight
        dict["thumbnailPath"] = thumbURL?.path ?? ""
        dict["localOriginalPath"] = localOriginal ?? ""
        dict["isTrashed"] = asset.isTrashed
        return .json(dict)
    }

    private func handleRenderContactSheet(_ args: [String: Any]) async throws -> ToolOutput {
        let folders = try await engine.fetchFolders()
        let folderPathByID = Self.buildFolderPaths(folders)

        var selectedAssets: [AssetRecord] = []
        if let rawIDs = Self.stringArrayArg(args["asset_ids"]), !rawIDs.isEmpty {
            for raw in rawIDs.prefix(16) {
                if let uuid = UUID(uuidString: raw), let asset = try await engine.fetchAsset(id: uuid) {
                    selectedAssets.append(asset)
                }
            }
        } else {
            let criteria = try buildFilterCriteria(from: args, folders: folders, folderPathByID: folderPathByID)
            let limit = max(1, min(16, Self.intArg(args["limit"]) ?? 16))
            selectedAssets = Array((try await engine.fetchAssets(matching: criteria)).prefix(limit))
        }

        guard !selectedAssets.isEmpty else {
            return .json(["slots": [], "message": "No assets matched the requested filter or asset_ids."])
        }

        let pkg = tools.buildContactSheets(
            for: selectedAssets,
            folderPathByID: folderPathByID,
            seedIDs: [],
            lockedIDs: [],
            existingBoardIDs: [],
            sheetCapacity: 16
        )
        guard let sheet = pkg.sheets.first else {
            return .error("Failed to render Contact Sheet image.")
        }

        // Optional save to disk for CLI / file-based agents
        var savedPath: String?
        if let outPath = (args["output_path"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines), !outPath.isEmpty {
            let outURL = URL(fileURLWithPath: (outPath as NSString).expandingTildeInPath)
            try FileManager.default.createDirectory(at: outURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try sheet.jpegData.write(to: outURL, options: .atomic)
            savedPath = outURL.path
        }

        let slotEntries: [[String: Any]] = sheet.orderedSlots.compactMap { pair in
            guard let asset = pkg.slotToAsset[pair.slot] else { return nil }
            let folderPath = asset.folderID.flatMap { folderPathByID[$0] } ?? "Inbox"
            return [
                "slot": pair.slot,
                "badge": String(format: "#%02d", pair.slot),
                "assetID": asset.id.uuidString,
                "title": asset.title,
                "folderPath": folderPath,
                "tags": asset.tags,
                "dominantColors": asset.dominantColors.prefix(4).map(\.hex),
                "aiDescription": asset.aiDescription ?? ""
            ]
        }

        var metadata: [String: Any] = [
            "sheetWidth": sheet.width,
            "sheetHeight": sheet.height,
            "slotCount": slotEntries.count,
            "slots": slotEntries
        ]
        if let savedPath {
            metadata["savedPath"] = savedPath
        }

        return ToolOutput(content: [
            .image(mimeType: "image/jpeg", data: sheet.jpegData),
            .text(Self.encodePrettyJSON(metadata))
        ])
    }

    private func handleListBoards() async throws -> ToolOutput {
        let boards = try await engine.fetchBoards()
        let formatter = ISO8601DateFormatter()
        let payload: [String: Any] = [
            "count": boards.count,
            "boards": boards.map { b -> [String: Any] in
                [
                    "id": b.id.uuidString,
                    "title": b.title,
                    "subtitle": b.subtitle,
                    "mode": Self.layoutModeLabel(b.mode),
                    "itemCount": b.itemCount,
                    "paletteHexes": b.paletteHexes,
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
        for assetID in doc.referencedAssetIDs {
            if let asset = try await engine.fetchAsset(id: assetID) {
                assetsByID[assetID] = asset
            }
        }

        var notes: [[String: Any]] = []
        var sections: [[String: Any]] = []
        var cardRefs: [[String: Any]] = []

        for node in doc.nodes.sorted(by: { $0.editorialOrder < $1.editorialOrder }) {
            switch node.kind {
            case .note(let title, let text, let style, _):
                notes.append([
                    "nodeID": node.id.uuidString,
                    "title": title ?? "",
                    "text": text,
                    "style": style.rawValue
                ])
            case .groupFrame(let title, let tint):
                sections.append([
                    "nodeID": node.id.uuidString,
                    "title": title,
                    "tint": tint.rawValue
                ])
            case .assetRef(let assetID, _, let weight, _):
                if let asset = assetsByID[assetID] {
                    var summary = serializeAssetSummary(asset, folderPathByID: folderPathByID)
                    summary["nodeID"] = node.id.uuidString
                    summary["weight"] = weight
                    summary["isHero"] = weight >= 2
                    summary["isLocked"] = node.isLocked
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

        let palette: [[String: Any]] = doc.extractedPalette.map { c in
            [
                "hex": c.hex.uppercased(),
                "proportion": (c.proportion * 1000).rounded() / 1000,
                "lab": ["l": c.l.rounded(), "a": c.a.rounded(), "b": c.b.rounded()]
            ]
        }

        let payload: [String: Any] = [
            "id": doc.id.uuidString,
            "title": doc.title,
            "subtitle": doc.subtitle,
            "mode": Self.layoutModeLabel(doc.mode),
            "itemCount": cardRefs.count,
            "palette": palette,
            "notes": notes,
            "sections": sections,
            "assets": cardRefs
        ]
        return .json(payload)
    }

    private func handleExportBoardImage(_ args: [String: Any]) async throws -> ToolOutput {
        guard let doc = try await resolveBoard(from: args) else {
            return .error("Moodboard not found. Pass a valid `board_id` UUID or matching `title`.")
        }
        var assetsByID: [UUID: AssetRecord] = [:]
        var thumbByID: [UUID: URL] = [:]
        for assetID in doc.referencedAssetIDs {
            if let asset = try await engine.fetchAsset(id: assetID) {
                assetsByID[assetID] = asset
            }
            if let thumb = await engine.thumbnailURL(for: assetID, tier: .grid520) {
                thumbByID[assetID] = thumb
            }
        }

        let dark = (args["dark_appearance"] as? Bool) ?? false
        let width = CGFloat(Self.intArg(args["width"]) ?? 1440)
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
            "bytes": pngData.count,
            "mimeType": "image/png"
        ]
        if let outPath = (args["output_path"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines), !outPath.isEmpty {
            let outURL = URL(fileURLWithPath: (outPath as NSString).expandingTildeInPath)
            try FileManager.default.createDirectory(at: outURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try pngData.write(to: outURL, options: .atomic)
            metadata["savedPath"] = outURL.path
        }

        return ToolOutput(content: [
            .image(mimeType: "image/png", data: pngData),
            .text(Self.encodePrettyJSON(metadata))
        ])
    }

    // MARK: - Write / Organize Tool Handlers (Never Permanent Delete)

    private func handleOrganizeAssets(_ args: [String: Any]) async throws -> ToolOutput {
        let ids = parseUUIDList(args["asset_ids"])
        guard !ids.isEmpty else {
            return .error("`asset_ids` must be a non-empty array of asset UUID strings.")
        }

        let folders = try await engine.fetchFolders()
        let folderPathByID = Self.buildFolderPaths(folders)
        var assignment: FolderAssignment = .unchanged
        if let moveToInbox = args["move_to_inbox"] as? Bool, moveToInbox {
            assignment = .inbox
        } else if let resolvedFolderID = try resolveOptionalFolderID(from: args, folders: folders, folderPathByID: folderPathByID) {
            assignment = .folder(resolvedFolderID)
        }

        let addTags = Self.stringArrayArg(args["add_tags"]) ?? []
        let removeTags = Self.stringArrayArg(args["remove_tags"]) ?? []
        let rating = Self.intArg(args["rating"])
        let notes = args["notes"] as? String
        let title = args["title"] as? String
        let acceptSuggested = (args["accept_suggested_tags"] as? Bool) ?? false

        let patch = AssetBatchPatch(
            assetIDs: ids,
            title: title,
            notes: notes,
            rating: rating,
            addTags: addTags,
            removeTags: removeTags,
            acceptSuggestedTags: acceptSuggested,
            folderAssignment: assignment
        )
        let updated = try await engine.updateAssets(patch)

        // Optional AI description update (persisted lazily through CharkleAgentTools)
        if let aiDesc = (args["ai_description"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines), !aiDesc.isEmpty {
            let insights = ids.map { AgentVisualInsight(assetID: $0, description: aiDesc, tags: []) }
            _ = await tools.persistVisualInsights(insights)
        }

        if notifyOnWrite {
            ExternalAgentNotifier.postLibraryChanged(kind: "assets", summary: "外部 Agent 已整理 \(updated.count) 项素材")
        }
        return .json([
            "updatedCount": updated.count,
            "assetIDs": updated.map { $0.id.uuidString }
        ])
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
        let created = try await engine.createFolder(name: name, parentID: parentID)
        if notifyOnWrite {
            ExternalAgentNotifier.postLibraryChanged(kind: "folders", summary: "外部 Agent 已新建文件夹「\(created.name)」")
        }
        return .json([
            "id": created.id.uuidString,
            "name": created.name,
            "parentID": created.parentID?.uuidString ?? ""
        ])
    }

    private func handleIngestAsset(_ args: [String: Any]) async throws -> ToolOutput {
        let folders = try await engine.fetchFolders()
        let folderPathByID = Self.buildFolderPaths(folders)
        let targetFolderID = try resolveOptionalFolderID(from: args, folders: folders, folderPathByID: folderPathByID)

        let input: CaptureInput
        if let filePath = (args["file_path"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines), !filePath.isEmpty {
            let url = URL(fileURLWithPath: (filePath as NSString).expandingTildeInPath)
            guard FileManager.default.fileExists(atPath: url.path) else {
                return .error("File not found at path: \(url.path)")
            }
            input = .fileURL(url)
        } else if let webURLString = (args["web_url"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
                  let url = URL(string: webURLString), url.scheme != nil {
            let title = (args["title"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
            input = .webURL(url, title: title?.isEmpty == false ? title : nil, notes: nil)
        } else if let text = (args["text"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty {
            let title = (args["title"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "Agent 笔记"
            input = .textSnippet(title: title, text: text, sourceURL: nil)
        } else {
            return .error("Provide one of `file_path`, `web_url`, or `text`.")
        }

        let created = try await engine.ingest([input], targetFolderID: targetFolderID, targetBoardID: nil)
        if let tags = Self.stringArrayArg(args["tags"]), !tags.isEmpty, !created.isEmpty {
            _ = try await engine.updateAssets(AssetBatchPatch(assetIDs: created.map(\.id), addTags: tags))
        }
        if notifyOnWrite {
            ExternalAgentNotifier.postLibraryChanged(kind: "assets", summary: "外部 Agent 已导入 \(created.count) 项素材")
        }
        return .json([
            "importedCount": created.count,
            "assets": created.map { serializeAssetSummary($0, folderPathByID: folderPathByID) }
        ])
    }

    private func handleComposeMoodboard(_ args: [String: Any]) async throws -> ToolOutput {
        let title = ((args["title"] as? String) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let subtitle = ((args["subtitle"] as? String) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let layoutRaw = ((args["layout_style"] as? String) ?? "magazine").lowercased()
        let layoutStyle = EditorialStyle(rawValue: layoutRaw) ?? .magazine
        let useFreeform = (args["use_freeform"] as? Bool) ?? false

        // Mode A: External Agent acts directly as Art Director with explicit sections or asset_ids!
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
                "itemCount": saved.referencedAssetIDs.count,
                "paletteHexes": saved.extractedPalette.map { $0.hex.uppercased() }
            ])
        }

        // Mode B: Prompt-driven curation invoking Charkle's built-in Moodboard Agent Harness!
        let prompt = ((args["prompt"] as? String) ?? title).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !prompt.isEmpty else {
            return .error("Provide either `sections` / `asset_ids` for direct curation, or `prompt` for automatic curation.")
        }
        let folders = try await engine.fetchFolders()
        let folderPathByID = Self.buildFolderPaths(folders)
        let scopeID = try resolveOptionalFolderID(from: args, folders: folders, folderPathByID: folderPathByID)
        let preferredCount = max(2, min(24, Self.intArg(args["preferred_count"]) ?? 12))

        let req = MoodboardCurationRequest(
            prompt: prompt,
            scopeFolderIDs: scopeID.map { [$0] } ?? [],
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

        let removeSet = Set(parseUUIDList(args["remove_asset_ids"]))
        if !removeSet.isEmpty {
            doc.nodes.removeAll { node in
                guard let ref = node.referencedAssetID else { return false }
                return removeSet.contains(ref) && !node.isLocked
            }
        }

        let addIDs = parseUUIDList(args["add_asset_ids"])
        if !addIDs.isEmpty {
            let existing = Set(doc.referencedAssetIDs)
            var nextZ = (doc.nodes.map(\.zIndex).max() ?? 0) + 1
            var nextOrder = (doc.nodes.map(\.editorialOrder).max() ?? 0) + 1
            for aid in addIDs where !existing.contains(aid) {
                guard let asset = try await engine.fetchAsset(id: aid) else { continue }
                let ratio = max(0.6, min(1.9, asset.aspectRatio))
                let w = 240.0
                let h = w / ratio
                let idx = doc.nodes.count
                let node = BoardNode(
                    kind: .assetRef(
                        assetID: aid,
                        crop: nil,
                        weight: 1,
                        autoplayLoop: asset.mediaKind == .animatedImage || asset.mediaKind == .video
                    ),
                    frame: BoardRect(x: Double((idx % 4) * 260) + 40, y: Double((idx / 4) * 240) + 40, width: w, height: h),
                    zIndex: nextZ,
                    editorialOrder: nextOrder
                )
                doc.nodes.append(node)
                nextZ += 1
                nextOrder += 1
            }
        }

        if let noteText = (args["add_note"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines), !noteText.isEmpty {
            let noteTitle = (args["note_title"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
            let nextZ = (doc.nodes.map(\.zIndex).max() ?? 0) + 1
            let nextOrder = (doc.nodes.map(\.editorialOrder).max() ?? 0) + 1
            doc.nodes.append(BoardNode(
                kind: .note(title: noteTitle?.isEmpty == false ? noteTitle : "Agent 批注", text: noteText, style: .paper, fontSize: 13.5),
                frame: BoardRect(x: 40, y: 40, width: 320, height: 148),
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
        return .json([
            "boardID": saved.id.uuidString,
            "title": saved.title,
            "itemCount": saved.referencedAssetIDs.count,
            "paletteHexes": saved.extractedPalette.map { $0.hex.uppercased() }
        ])
    }

    private func handleTrashAssets(_ args: [String: Any]) async throws -> ToolOutput {
        let ids = parseUUIDList(args["asset_ids"])
        guard !ids.isEmpty else {
            return .error("`asset_ids` must be a non-empty array of asset UUID strings.")
        }
        let trashed = (args["trashed"] as? Bool) ?? true
        let updated = try await engine.updateAssets(AssetBatchPatch(assetIDs: ids, isTrashed: trashed))
        if notifyOnWrite {
            ExternalAgentNotifier.postLibraryChanged(
                kind: "assets",
                summary: trashed ? "外部 Agent 已将 \(updated.count) 项素材移入回收站" : "外部 Agent 已从回收站恢复 \(updated.count) 项素材"
            )
        }
        return .json([
            "updatedCount": updated.count,
            "trashed": trashed,
            "note": "Soft Trash only; external agents can never permanently delete assets."
        ])
    }

    // MARK: - Helpers

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

    private func buildFilterCriteria(
        from args: [String: Any],
        folders: [FolderRecord],
        folderPathByID: [UUID: String]
    ) throws -> FilterCriteria {
        let query = ((args["query"] as? String) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let tags = Set(Self.stringArrayArg(args["tags"]) ?? [])
        let colorHex = (args["color_hex"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
        let colorTolerance = (args["color_tolerance"] as? Double) ?? 28.0
        let minRating = Self.intArg(args["min_rating"]) ?? 0
        let onlyInbox = (args["only_inbox"] as? Bool) ?? false
        let onlyUntagged = (args["only_untagged"] as? Bool) ?? false
        let folderID = try resolveOptionalFolderID(from: args, folders: folders, folderPathByID: folderPathByID)

        var kinds: Set<MediaKind> = []
        if let rawKinds = Self.stringArrayArg(args["media_kinds"]) {
            for k in rawKinds {
                if let kind = MediaKind(rawValue: k) { kinds.insert(kind) }
            }
        }

        return FilterCriteria(
            searchQuery: query,
            kinds: kinds,
            selectedColorHex: colorHex?.isEmpty == false ? colorHex : nil,
            colorTolerance: colorTolerance,
            minRating: minRating,
            tags: tags,
            folderID: onlyInbox ? nil : folderID,
            onlyInbox: onlyInbox,
            onlyUntagged: onlyUntagged,
            sortBy: .newest
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

    private static func buildFolderPaths(_ folders: [FolderRecord]) -> [UUID: String] {
        let byID = Dictionary(uniqueKeysWithValues: folders.map { ($0.id, $0) })
        var out: [UUID: String] = [:]
        for folder in folders {
            var parts: [String] = [folder.name]
            var parent = folder.parentID
            var depth = 0
            while let pid = parent, let pf = byID[pid], depth < 12 {
                parts.insert(pf.name, at: 0)
                parent = pf.parentID
                depth += 1
            }
            out[folder.id] = parts.joined(separator: "/")
        }
        return out
    }

    private func parseUUIDList(_ raw: Any?) -> [UUID] {
        (Self.stringArrayArg(raw) ?? []).compactMap { UUID(uuidString: $0.trimmingCharacters(in: .whitespacesAndNewlines)) }
    }

    private static func stringArrayArg(_ raw: Any?) -> [String]? {
        if let arr = raw as? [String] { return arr }
        if let anyArr = raw as? [Any] { return anyArr.compactMap { $0 as? String } }
        return nil
    }

    private static func intArg(_ raw: Any?) -> Int? {
        if let i = raw as? Int { return i }
        if let d = raw as? Double { return Int(d) }
        if let s = raw as? String { return Int(s) }
        return nil
    }

    private static func layoutModeLabel(_ mode: BoardLayoutMode) -> String {
        switch mode {
        case .autoEditorial(let cfg): return "autoEditorial(\(cfg.style.rawValue))"
        case .freeform: return "freeform"
        }
    }

    private func makeResultResponse(id: Any?, result: Any) -> Data {
        let obj: [String: Any] = [
            "jsonrpc": "2.0",
            "id": id ?? NSNull(),
            "result": result
        ]
        return (try? JSONSerialization.data(withJSONObject: obj, options: [.sortedKeys])) ?? Data("{}".utf8)
    }

    private func makeErrorResponse(id: Any?, code: Int, message: String) -> Data {
        let obj: [String: Any] = [
            "jsonrpc": "2.0",
            "id": id ?? NSNull(),
            "error": [
                "code": code,
                "message": message
            ]
        ]
        return (try? JSONSerialization.data(withJSONObject: obj, options: [.sortedKeys])) ?? Data("{}".utf8)
    }

    public static func encodePrettyJSON(_ object: Any) -> String {
        guard JSONSerialization.isValidJSONObject(object),
              let data = try? JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys]),
              let str = String(data: data, encoding: .utf8) else {
            return "{}"
        }
        return str
    }

    // MARK: - MCP Tool Schema Registry

    public static func mcpToolDefinitions() -> [[String: Any]] {
        func tool(
            name: String,
            description: String,
            properties: [String: Any],
            required: [String] = [],
            readOnly: Bool
        ) -> [String: Any] {
            var schema: [String: Any] = [
                "type": "object",
                "properties": properties
            ]
            if !required.isEmpty {
                schema["required"] = required
            }
            return [
                "name": name,
                "description": description,
                "inputSchema": schema,
                "annotations": [
                    "readOnlyHint": readOnly,
                    "destructiveHint": false
                ]
            ]
        }

        return [
            tool(
                name: "library_overview",
                description: "Get an overview of the Charkle visual reference library: total assets, inbox count, folder tree with IDs/paths, top tags, media distribution, board count, and active external agent permission level.",
                properties: [:],
                readOnly: true
            ),
            tool(
                name: "search_assets",
                description: "Search assets in Charkle by text query (supports Chinese, Pinyin, tags, OCR, AI descriptions), folder path/ID, tags, CIELAB dominant color hex, media kind, or rating.",
                properties: [
                    "query": ["type": "string", "description": "Full-text search query across titles, notes, tags, OCR, and AI descriptions."],
                    "folder_id": ["type": "string", "description": "Optional folder UUID."],
                    "folder_path": ["type": "string", "description": "Optional folder path or name, e.g. 'UI Inspiration' or '插画/常夏'."],
                    "tags": ["type": "array", "items": ["type": "string"], "description": "Filter assets having all given tags."],
                    "color_hex": ["type": "string", "description": "Dominant color hex filter such as '#C86D51'."],
                    "color_tolerance": ["type": "number", "description": "CIELAB DeltaE tolerance (default 28)."],
                    "min_rating": ["type": "integer", "description": "Minimum star rating (0-5)."],
                    "only_inbox": ["type": "boolean", "description": "Only return untriaged Inbox assets."],
                    "only_untagged": ["type": "boolean", "description": "Only return assets with no tags."],
                    "limit": ["type": "integer", "description": "Max items to return (1-100, default 30)."]
                ],
                readOnly: true
            ),
            tool(
                name: "list_inbox",
                description: "List untriaged assets currently in Charkle's Inbox.",
                properties: [
                    "limit": ["type": "integer", "description": "Max items to return (default 40)."]
                ],
                readOnly: true
            ),
            tool(
                name: "get_asset",
                description: "Get complete metadata, OCR text, palette, tags, notes, thumbnail path, and local original path for a single asset UUID.",
                properties: [
                    "asset_id": ["type": "string", "description": "Asset UUID."]
                ],
                required: ["asset_id"],
                readOnly: true
            ),
            tool(
                name: "render_contact_sheet",
                description: "Render up to 16 candidate assets into a numbered Visual Contact Sheet JPEG (#01..#16) returned as an image plus grounded slot-to-assetID JSON manifest. Use this to visually inspect the library before curating or organizing.",
                properties: [
                    "asset_ids": ["type": "array", "items": ["type": "string"], "description": "Explicit asset UUIDs to render (up to 16)."],
                    "query": ["type": "string", "description": "Search query when asset_ids is omitted."],
                    "folder_path": ["type": "string", "description": "Optional folder path filter."],
                    "only_inbox": ["type": "boolean", "description": "Render current Inbox assets."],
                    "only_untagged": ["type": "boolean", "description": "Render untagged assets."],
                    "color_hex": ["type": "string", "description": "Optional color hex filter."],
                    "limit": ["type": "integer", "description": "Number of tiles (1-16, default 16)."],
                    "output_path": ["type": "string", "description": "Optional local path to also write the JPEG file."]
                ],
                readOnly: true
            ),
            tool(
                name: "list_boards",
                description: "List all Moodboards in Charkle with ID, title, subtitle, layout mode, item count, and extracted palette HEX codes.",
                properties: [:],
                readOnly: true
            ),
            tool(
                name: "get_board_context",
                description: "Read full structured design context of a Moodboard (title, subtitle, curator notes, section groups, harmonized HEX/CIELAB palette, and referenced assets with paths). Ideal for turning a moodboard into design tokens or code.",
                properties: [
                    "board_id": ["type": "string", "description": "Moodboard UUID."],
                    "title": ["type": "string", "description": "Moodboard title lookup when board_id is omitted."]
                ],
                readOnly: true
            ),
            tool(
                name: "export_board_image",
                description: "Render a Moodboard headlessly to PNG and return the image directly (optionally saving to output_path).",
                properties: [
                    "board_id": ["type": "string", "description": "Moodboard UUID."],
                    "title": ["type": "string", "description": "Moodboard title lookup when board_id is omitted."],
                    "width": ["type": "integer", "description": "Canvas width in pixels (default 1440)."],
                    "dark_appearance": ["type": "boolean", "description": "Render in dark studio theme (default false)."],
                    "output_path": ["type": "string", "description": "Optional path to write the PNG file."]
                ],
                readOnly: true
            ),
            tool(
                name: "organize_assets",
                description: "Batch-organize assets: move to a folder or Inbox, add/remove tags, set rating, notes, title, or AI description. Requires write permission in Charkle Settings.",
                properties: [
                    "asset_ids": ["type": "array", "items": ["type": "string"], "description": "Asset UUIDs to update."],
                    "folder_id": ["type": "string", "description": "Move assets to this folder UUID."],
                    "folder_path": ["type": "string", "description": "Move assets to this folder path/name."],
                    "move_to_inbox": ["type": "boolean", "description": "Move assets back to Inbox."],
                    "add_tags": ["type": "array", "items": ["type": "string"], "description": "Tags to add."],
                    "remove_tags": ["type": "array", "items": ["type": "string"], "description": "Tags to remove."],
                    "rating": ["type": "integer", "description": "Star rating 0-5."],
                    "title": ["type": "string", "description": "Set title."],
                    "notes": ["type": "string", "description": "Set notes."],
                    "ai_description": ["type": "string", "description": "Save a visual description for these assets."],
                    "accept_suggested_tags": ["type": "boolean", "description": "Accept AI suggested tags."]
                ],
                required: ["asset_ids"],
                readOnly: false
            ),
            tool(
                name: "create_folder",
                description: "Create a new folder in Charkle (optionally nested under parent_id or parent_path). Requires write permission.",
                properties: [
                    "name": ["type": "string", "description": "New folder name."],
                    "parent_id": ["type": "string", "description": "Optional parent folder UUID."],
                    "parent_path": ["type": "string", "description": "Optional parent folder path."]
                ],
                required: ["name"],
                readOnly: false
            ),
            tool(
                name: "ingest_asset",
                description: "Import a local image/media file, a web URL (including X/Twitter posts), or a text snippet into Charkle. Requires write permission.",
                properties: [
                    "file_path": ["type": "string", "description": "Local file path to import."],
                    "web_url": ["type": "string", "description": "Web or X/Twitter URL to bookmark/capture."],
                    "text": ["type": "string", "description": "Text snippet to save as a reference card."],
                    "title": ["type": "string", "description": "Optional title for web_url or text."],
                    "folder_path": ["type": "string", "description": "Optional destination folder path (defaults to Inbox)."],
                    "tags": ["type": "array", "items": ["type": "string"], "description": "Optional initial tags."]
                ],
                readOnly: false
            ),
            tool(
                name: "compose_moodboard",
                description: "Create and save a new Moodboard in Charkle. Either pass explicit `sections` / `asset_ids` (after inspecting contact sheets) for direct art direction, or pass `prompt` to invoke Charkle's built-in Moodboard Agent Harness. Requires write permission.",
                properties: [
                    "title": ["type": "string", "description": "Moodboard title."],
                    "subtitle": ["type": "string", "description": "Short subtitle."],
                    "curator_note": ["type": "string", "description": "Art direction note card shown on the moodboard."],
                    "layout_style": ["type": "string", "enum": ["magazine", "balanced", "compact"], "description": "Editorial layout rhythm."],
                    "use_freeform": ["type": "boolean", "description": "Use freeform spatial canvas instead of Auto Editorial."],
                    "sections": [
                        "type": "array",
                        "description": "Explicit curated sections with asset_ids and optional hero_asset_ids.",
                        "items": [
                            "type": "object",
                            "properties": [
                                "title": ["type": "string"],
                                "tint": ["type": "string", "enum": ["neutral", "sand", "sage", "slate", "terracotta", "ocean"]],
                                "rationale": ["type": "string"],
                                "asset_ids": ["type": "array", "items": ["type": "string"]],
                                "hero_asset_ids": ["type": "array", "items": ["type": "string"]]
                            ],
                            "required": ["title", "asset_ids"]
                        ]
                    ],
                    "asset_ids": ["type": "array", "items": ["type": "string"], "description": "Flat list of asset UUIDs if not specifying sections."],
                    "hero_asset_ids": ["type": "array", "items": ["type": "string"], "description": "Optional hero asset UUIDs (weight=2)."],
                    "prompt": ["type": "string", "description": "Natural-language brief when delegating curation to Charkle's built-in harness."],
                    "folder_path": ["type": "string", "description": "Optional scope folder when using prompt mode."],
                    "preferred_count": ["type": "integer", "description": "Max assets when using prompt mode (default 12)."]
                ],
                readOnly: false
            ),
            tool(
                name: "patch_moodboard",
                description: "Modify an existing Moodboard (rename, add/remove asset cards while respecting locked cards, or append a curator note). Requires write permission.",
                properties: [
                    "board_id": ["type": "string", "description": "Target Moodboard UUID."],
                    "title": ["type": "string", "description": "Existing board title lookup if board_id is omitted."],
                    "new_title": ["type": "string", "description": "Optional new title."],
                    "subtitle": ["type": "string", "description": "Optional updated subtitle."],
                    "add_asset_ids": ["type": "array", "items": ["type": "string"], "description": "Asset UUIDs to append."],
                    "remove_asset_ids": ["type": "array", "items": ["type": "string"], "description": "Unlocked asset UUIDs to remove."],
                    "add_note": ["type": "string", "description": "Append a note card to the board."],
                    "note_title": ["type": "string", "description": "Title for the appended note card."]
                ],
                readOnly: false
            ),
            tool(
                name: "trash_assets",
                description: "Soft-move assets to Trash (or restore with trashed=false). External agents are NEVER allowed to permanently delete user assets. Requires write permission.",
                properties: [
                    "asset_ids": ["type": "array", "items": ["type": "string"], "description": "Asset UUIDs to move to or restore from Trash."],
                    "trashed": ["type": "boolean", "description": "true to move to Trash (default), false to restore."]
                ],
                required: ["asset_ids"],
                readOnly: false
            )
        ]
    }
}
