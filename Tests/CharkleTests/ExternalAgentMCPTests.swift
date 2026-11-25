@testable import CharkleCore
import Foundation
import ImageIO
import Testing

@Suite("External Agent MCP Server, Framing, Permissions & Headless Tools")
struct ExternalAgentMCPTests {
    private func makeTestService() async throws -> (dir: URL, engine: LiveCharkleEngine, service: CharkleExternalAgentService, assets: [AssetRecord]) {
        let dir = try BackendFixture.directory()
        let appSupport = dir.appending(path: "AppSupport", directoryHint: .isDirectory)
        let engine = try LiveCharkleEngine.make(appSupportDirectory: appSupport, startAutoSync: false)
        let service = CharkleExternalAgentService(engine: engine, configDirectory: appSupport, notifyOnWrite: false)

        let png1 = try BackendFixture.artwork("#C86D51")
        let png2 = try BackendFixture.artwork("#2A6F97")
        let imported = try await engine.ingest(
            [
                .imageData(png1, suggestedName: "Terracotta Poster.png", sourceURL: nil),
                .imageData(png2, suggestedName: "Ocean Grid UI.png", sourceURL: nil)
            ],
            targetFolderID: nil,
            targetBoardID: nil
        )
        return (dir, engine, service, imported)
    }

    private func sendRPC(_ service: CharkleExternalAgentService, _ request: Any) async throws -> Any? {
        let reqData = try JSONSerialization.data(withJSONObject: request)
        guard let respData = await service.handleJSONRPC(reqData) else { return nil }
        return try JSONSerialization.jsonObject(with: respData)
    }

    private func decodeToolJSON(_ output: CharkleExternalAgentService.ToolOutput) throws -> [String: Any] {
        let text = output.content.compactMap { if case .text(let t) = $0 { return t } else { return nil } }.joined()
        let data = try #require(text.data(using: .utf8))
        return try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    @Test("MCP JSON-RPC lifecycle negotiates protocol, lists 20 safe tools, resources, templates, prompts, and supports batch requests")
    func mcpProtocolLifecycleAndToolRegistry() async throws {
        let (dir, _, service, assets) = try await makeTestService()
        defer { try? FileManager.default.removeItem(at: dir) }
        let firstAsset = try #require(assets.first)

        // 1. initialize (known modern version & unknown fallback negotiation)
        let initResp = try #require(await sendRPC(service, [
            "jsonrpc": "2.0",
            "id": 1,
            "method": "initialize",
            "params": ["protocolVersion": "2025-11-25", "clientInfo": ["name": "claude-code", "version": "1.0"]]
        ]) as? [String: Any])
        let initResult = try #require(initResp["result"] as? [String: Any])
        #expect(initResult["protocolVersion"] as? String == "2025-11-25")
        let capabilities = try #require(initResult["capabilities"] as? [String: Any])
        #expect(capabilities["tools"] != nil)
        #expect(capabilities["resources"] != nil)
        #expect(capabilities["prompts"] != nil)
        #expect(capabilities["logging"] != nil)
        let serverInfo = try #require(initResult["serverInfo"] as? [String: Any])
        #expect(serverInfo["name"] as? String == "charkle")

        let fallbackInit = try #require(await sendRPC(service, [
            "jsonrpc": "2.0",
            "id": 100,
            "method": "initialize",
            "params": ["protocolVersion": "1999-01-01"]
        ]) as? [String: Any])
        let fallbackResult = try #require(fallbackInit["result"] as? [String: Any])
        #expect(fallbackResult["protocolVersion"] as? String == CharkleExternalAgentService.defaultProtocolVersion)

        // 2. notification returns nil (no JSON-RPC reply)
        let notifResp = try await sendRPC(service, ["jsonrpc": "2.0", "method": "notifications/initialized"])
        #expect(notifResp == nil)

        // 3. ping & logging/setLevel
        let pingResp = try #require(await sendRPC(service, ["jsonrpc": "2.0", "id": 2, "method": "ping"]) as? [String: Any])
        #expect(pingResp["result"] != nil)
        let logResp = try #require(await sendRPC(service, [
            "jsonrpc": "2.0",
            "id": 20,
            "method": "logging/setLevel",
            "params": ["level": "info"]
        ]) as? [String: Any])
        #expect(logResp["result"] != nil)

        // 4. tools/list -> 20 safe tools, full annotations, zero permanent/folder delete
        let toolsResp = try #require(await sendRPC(service, ["jsonrpc": "2.0", "id": 3, "method": "tools/list"]) as? [String: Any])
        let toolsResult = try #require(toolsResp["result"] as? [String: Any])
        let tools = try #require(toolsResult["tools"] as? [[String: Any]])
        let names = Set(tools.compactMap { $0["name"] as? String })
        #expect(names.count == 20)
        #expect(names.contains("library_overview"))
        #expect(names.contains("search_assets"))
        #expect(names.contains("render_contact_sheet"))
        #expect(names.contains("find_similar_assets"))
        #expect(names.contains("semantic_search"))
        #expect(names.contains("quick_jump"))
        #expect(names.contains("suggest_folder"))
        #expect(names.contains("update_folder"))
        #expect(names.contains("analyze_assets"))
        #expect(names.contains("compose_moodboard"))
        #expect(names.contains("patch_moodboard"))
        #expect(names.contains("trash_assets"))

        // Security invariant: NEVER expose permanent delete or folder delete!
        #expect(!names.contains(where: { $0.contains("permanent") || $0.contains("delete_") }))
        for t in tools {
            let ann = try #require(t["annotations"] as? [String: Any])
            #expect(ann["destructiveHint"] as? Bool == false)
            #expect((ann["title"] as? String)?.isEmpty == false)
        }

        // 5. resources/list, resources/templates/list, static & dynamic resources/read
        let listRes = try #require(await sendRPC(service, ["jsonrpc": "2.0", "id": 4, "method": "resources/list"]) as? [String: Any])
        let resList = try #require((listRes["result"] as? [String: Any])?["resources"] as? [[String: Any]])
        #expect(resList.count == 4)

        let tmplRes = try #require(await sendRPC(service, ["jsonrpc": "2.0", "id": 5, "method": "resources/templates/list"]) as? [String: Any])
        let tmpls = try #require((tmplRes["result"] as? [String: Any])?["resourceTemplates"] as? [[String: Any]])
        #expect(tmpls.count == 2)

        let assetRes = try #require(await sendRPC(service, [
            "jsonrpc": "2.0",
            "id": 6,
            "method": "resources/read",
            "params": ["uri": "charkle://assets/\(firstAsset.id.uuidString)"]
        ]) as? [String: Any])
        let contents = try #require((assetRes["result"] as? [String: Any])?["contents"] as? [[String: Any]])
        #expect(contents.first?["mimeType"] as? String == "application/json")
        #expect((contents.first?["text"] as? String)?.contains(firstAsset.id.uuidString) == true)

        // 6. prompts/list & prompts/get
        let promptsResp = try #require(await sendRPC(service, ["jsonrpc": "2.0", "id": 7, "method": "prompts/list"]) as? [String: Any])
        let prompts = try #require((promptsResp["result"] as? [String: Any])?["prompts"] as? [[String: Any]])
        #expect(prompts.count == 4)

        let promptGet = try #require(await sendRPC(service, [
            "jsonrpc": "2.0",
            "id": 8,
            "method": "prompts/get",
            "params": ["name": "curate_moodboard", "arguments": ["brief": "warm terracotta editorial", "count": "8"]]
        ]) as? [String: Any])
        let promptMsgs = try #require((promptGet["result"] as? [String: Any])?["messages"] as? [[String: Any]])
        #expect(promptMsgs.count == 1)

        // 7. JSON-RPC 2.0 batch request (2 requests + 1 notification -> 2 replies)
        let batchReply = try #require(await sendRPC(service, [
            ["jsonrpc": "2.0", "id": 31, "method": "ping"],
            ["jsonrpc": "2.0", "method": "notifications/initialized"],
            ["jsonrpc": "2.0", "id": 32, "method": "prompts/list"]
        ]) as? [[String: Any]])
        #expect(batchReply.count == 2)
        #expect(batchReply[0]["id"] as? Int == 31)
        #expect(batchReply[1]["id"] as? Int == 32)
    }

    @Test("MCPStdioFrameParser handles split Content-Length headers, mixed NDJSON, invalid limits, and EOF cleanly")
    func mcpStdioFrameParserChunkBoundaries() throws {
        var parser = MCPStdioFrameParser(maxFrameBytes: 4096)
        let body1 = #"{"jsonrpc":"2.0","id":1,"method":"ping"}"#
        let framed1 = "Content-Type: application/vscode-jsonrpc; charset=utf-8\r\nContent-Length: \(body1.utf8.count)\r\n\r\n\(body1)"

        // Split right through the middle of `Content-Length` header and body across 4 chunks.
        let bytes = Array(framed1.utf8)
        let c1 = Data(bytes[0..<18])
        let c2 = Data(bytes[18..<68])
        let c3 = Data(bytes[68..<84])
        let c4 = Data(bytes[84..<bytes.count])

        #expect(parser.append(c1).isEmpty)
        #expect(parser.append(c2).isEmpty)
        #expect(parser.append(c3).isEmpty)
        let ev1 = parser.append(c4)
        #expect(ev1 == [.message(Data(body1.utf8), framing: .contentLength)])

        // Mixed NDJSON + oversized Content-Length rejection + trailing EOF message
        let ndjson = #"{"jsonrpc":"2.0","id":2,"method":"ping"}"# + "\n"
        let ev2 = parser.append(Data(ndjson.utf8))
        #expect(ev2 == [.message(Data(#"{"jsonrpc":"2.0","id":2,"method":"ping"}"#.utf8), framing: .ndjson)])

        let hugeHeader = "Content-Length: 99999999\r\n\r\n"
        let ev3 = parser.append(Data(hugeHeader.utf8))
        #expect(ev3.count == 1)
        if case .invalidFrame(_, let framing) = ev3[0] {
            #expect(framing == .contentLength)
        } else {
            Issue.record("Expected invalidFrame for oversized Content-Length")
        }

        let trailing = #"{"jsonrpc":"2.0","id":3,"method":"ping"}"#
        #expect(parser.append(Data(trailing.utf8)).isEmpty)
        let evEOF = parser.finishEOF()
        #expect(evEOF == [.message(Data(trailing.utf8), framing: .ndjson)])
    }

    @Test("Permission boundaries, bug regressions, pagination, rich metadata, and all 20 safe tools work end-to-end")
    func permissionBoundariesAndEndToEndTools() async throws {
        let (dir, engine, service, assets) = try await makeTestService()
        defer { try? FileManager.default.removeItem(at: dir) }

        let a1 = try #require(assets.first)
        let a2 = try #require(assets.last)

        // Policy 1: Disabled -> blocks even reads
        try ExternalAgentConfigStore.save(ExternalAgentConfig(enabled: false, accessLevel: .readOnly), in: service.configDirectory)
        let blockedRead = await service.callTool(name: "library_overview", arguments: [:])
        #expect(blockedRead.isError == true)

        // Policy 2: Default readOnly -> allows reads, Contact Sheet, get_asset with inline image; blocks writes
        try ExternalAgentConfigStore.save(ExternalAgentConfig(enabled: true, accessLevel: .readOnly), in: service.configDirectory)
        let sheetOut = await service.callTool(name: "render_contact_sheet", arguments: ["only_inbox": true, "limit": 1, "offset": 0])
        #expect(sheetOut.isError == false)
        let sheetMeta = try decodeToolJSON(sheetOut)
        #expect(sheetMeta["totalMatched"] as? Int == 2)
        #expect(sheetMeta["slotCount"] as? Int == 1)
        #expect(sheetMeta["hasMore"] as? Bool == true)
        #expect(sheetMeta["nextOffset"] as? Int == 1)

        var hasValidJPEG = false
        for item in sheetOut.content {
            if case .image(let mime, let data) = item {
                #expect(mime == "image/jpeg")
                let src = CGImageSourceCreateWithData(data as CFData, nil)
                hasValidJPEG = src.flatMap { CGImageSourceCreateImageAtIndex($0, 0, nil) } != nil
            }
        }
        #expect(hasValidJPEG == true)

        // get_asset with inline JPEG preview
        let assetImgOut = await service.callTool(name: "get_asset", arguments: [
            "asset_id": a1.id.uuidString,
            "include_image": true,
            "image_max_side": 448
        ])
        #expect(assetImgOut.isError == false)
        #expect(assetImgOut.content.contains { if case .image(let mime, _) = $0 { return mime == "image/jpeg" } else { return false } })

        let blockedWrite = await service.callTool(name: "create_folder", arguments: ["name": "ShouldFail"])
        #expect(blockedWrite.isError == true)
        let blockedUpdateFolder = await service.callTool(name: "update_folder", arguments: ["folder_path": "None", "new_name": "X"])
        #expect(blockedUpdateFolder.isError == true)

        // Policy 3: Switch live to readWriteOrganize
        try ExternalAgentConfigStore.save(ExternalAgentConfig(enabled: true, accessLevel: .readWriteOrganize), in: service.configDirectory)

        // Create parent + child folders, then test `update_folder` (rename + color) and recursive search
        let parentOut = await service.callTool(name: "create_folder", arguments: ["name": "Design", "color_hex": "#2A60E0"])
        #expect(parentOut.isError == false)
        let childOut = await service.callTool(name: "create_folder", arguments: ["name": "Posters", "parent_path": "Design"])
        #expect(childOut.isError == false)
        let childJSON = try decodeToolJSON(childOut)
        #expect(childJSON["path"] as? String == "Design/Posters")

        let renamedOut = await service.callTool(name: "update_folder", arguments: [
            "folder_path": "Design/Posters",
            "new_name": "Editorial Posters",
            "color_hex": "#C86D51"
        ])
        #expect(renamedOut.isError == false)
        let renamedJSON = try decodeToolJSON(renamedOut)
        #expect(renamedJSON["path"] as? String == "Design/Editorial Posters")

        // Organize asset 1 + verify `ai_description` CAN BE OVERWRITTEN (regression test!)
        let orgOut1 = await service.callTool(name: "organize_assets", arguments: [
            "asset_ids": [a1.id.uuidString],
            "folder_path": "Design/Editorial Posters",
            "add_tags": ["terracotta", "editorial"],
            "rating": 5,
            "ai_description": "初版描述"
        ])
        #expect(orgOut1.isError == false)
        let orgOut2 = await service.callTool(name: "organize_assets", arguments: [
            "asset_ids": [a1.id.uuidString],
            "ai_description": "更新后的暖陶土色平面海报参考"
        ])
        #expect(orgOut2.isError == false)
        let updatedA1 = try #require(await engine.fetchAsset(id: a1.id))
        #expect(updatedA1.rating == 5)
        #expect(updatedA1.tags.contains("terracotta"))
        #expect(updatedA1.aiDescription == "更新后的暖陶土色平面海报参考")

        // Verify recursive subfolder search & pagination
        let recursiveSearch = await service.callTool(name: "search_assets", arguments: [
            "folder_path": "Design",
            "include_subfolders": true,
            "media_kinds": ["image"],
            "limit": 10
        ])
        #expect(recursiveSearch.isError == false)
        let recJSON = try decodeToolJSON(recursiveSearch)
        #expect(recJSON["totalMatched"] as? Int == 1)

        // Verify `ingest_asset` returns freshly tagged assets immediately (regression test!)
        let ingestOut = await service.callTool(name: "ingest_asset", arguments: [
            "text": "Design system color token notes",
            "title": "Token Spec",
            "folder_path": "Design",
            "tags": ["tokens", "spec"],
            "rating": 4
        ])
        #expect(ingestOut.isError == false)
        let ingestJSON = try decodeToolJSON(ingestOut)
        let importedAssets = try #require(ingestJSON["assets"] as? [[String: Any]])
        let importedTags = Set((importedAssets.first?["tags"] as? [String]) ?? [])
        #expect(importedTags.contains("tokens"))
        #expect(importedTags.contains("spec"))

        // Verify Smart Folder filtering in search_assets
        let sf = SmartFolderRecord(
            name: "High Rated",
            rule: SmartFolderRule(matchMode: .all, tags: ["editorial"], minRating: 4)
        )
        _ = try await engine.saveSmartFolder(sf)
        let sfSearch = await service.callTool(name: "search_assets", arguments: ["smart_folder_name": "High Rated"])
        #expect(sfSearch.isError == false)
        #expect(try decodeToolJSON(sfSearch)["totalMatched"] as? Int == 1)

        // Verify new discovery tools: find_similar_assets, semantic_search, quick_jump, suggest_folder, analyze_assets
        let simOut = await service.callTool(name: "find_similar_assets", arguments: ["asset_id": a1.id.uuidString, "limit": 5])
        #expect(simOut.isError == false)

        let semOut = await service.callTool(name: "semantic_search", arguments: ["query": "terracotta editorial", "limit": 5])
        #expect(semOut.isError == false)
        #expect((try decodeToolJSON(semOut)["returned"] as? Int ?? 0) >= 1)

        let jumpOut = await service.callTool(name: "quick_jump", arguments: ["query": "Editorial", "limit": 10])
        #expect(jumpOut.isError == false)
        #expect((try decodeToolJSON(jumpOut)["returned"] as? Int ?? 0) >= 1)

        let suggestOut = await service.callTool(name: "suggest_folder", arguments: ["asset_ids": [a2.id.uuidString]])
        #expect(suggestOut.isError == false)
        #expect((try decodeToolJSON(suggestOut)["evaluatedCount"] as? Int) == 1)

        let analyzeOut = await service.callTool(name: "analyze_assets", arguments: ["asset_ids": [a1.id.uuidString]])
        #expect(analyzeOut.isError == false)
        #expect((try decodeToolJSON(analyzeOut)["analyzedCount"] as? Int) == 1)

        // Compose structured moodboard, lock one node, then test non-overlapping `patch_moodboard`
        let composeOut = await service.callTool(name: "compose_moodboard", arguments: [
            "title": "MCP 联调情绪板",
            "subtitle": "由外部 Agent 直接策展并写入 Charkle",
            "curator_note": "聚焦暖陶土与海蓝的冷暖撞色对比。",
            "use_freeform": true,
            "sections": [
                [
                    "title": "主视觉对比",
                    "tint": "terracotta",
                    "rationale": "冷暖对照",
                    "asset_ids": [a1.id.uuidString],
                    "hero_asset_ids": [a1.id.uuidString]
                ]
            ]
        ])
        #expect(composeOut.isError == false)
        let boardIDStr = try #require(try decodeToolJSON(composeOut)["boardID"] as? String)
        let boardUUID = try #require(UUID(uuidString: boardIDStr))

        // Lock a1 on the board and inspect pre-patch maxY
        var loadedBoard = try #require(await engine.fetchBoard(id: boardUUID))
        let maxYBefore = loadedBoard.nodes.map(\.frame.maxY).max() ?? 0
        for idx in loadedBoard.nodes.indices where loadedBoard.nodes[idx].referencedAssetID == a1.id {
            loadedBoard.nodes[idx].isLocked = true
        }
        _ = try await engine.saveBoard(loadedBoard)

        // Patch: try removing locked a1 (must be skipped!), add section, add a2, add note (must not collide!)
        let patchOut = await service.callTool(name: "patch_moodboard", arguments: [
            "board_id": boardIDStr,
            "remove_asset_ids": [a1.id.uuidString],
            "add_section": "补充冷色参考",
            "section_tint": "ocean",
            "add_asset_ids": [a2.id.uuidString],
            "add_note": "确认底部追加卡片不重叠",
            "note_style": "warm"
        ])
        #expect(patchOut.isError == false)
        let patchJSON = try decodeToolJSON(patchOut)
        #expect(patchJSON["addedCount"] as? Int == 1)
        #expect(patchJSON["removedCount"] as? Int == 0)
        #expect((patchJSON["skippedLockedAssetIDs"] as? [String])?.contains(a1.id.uuidString) == true)

        let patchedBoard = try #require(await engine.fetchBoard(id: boardUUID))
        let addedCardNode = try #require(patchedBoard.nodes.first { $0.referencedAssetID == a2.id })
        #expect(addedCardNode.frame.minY > maxYBefore)

        // Inspect board context & headless high-res PNG export via MCP
        let ctxOut = await service.callTool(name: "get_board_context", arguments: ["title": "MCP 联调情绪板"])
        #expect(ctxOut.isError == false)
        let ctxJSON = try decodeToolJSON(ctxOut)
        #expect(ctxJSON["connectors"] != nil)

        let pngOutPath = dir.appending(path: "exported-board.png").path
        let exportOut = await service.callTool(name: "export_board_image", arguments: [
            "title": "MCP 联调情绪板",
            "output_path": pngOutPath
        ])
        #expect(exportOut.isError == false)
        #expect(FileManager.default.fileExists(atPath: pngOutPath))
        var hasValidPNG = false
        for item in exportOut.content {
            if case .image(let mime, let data) = item {
                #expect(mime == "image/png")
                let src = CGImageSourceCreateWithData(data as CFData, nil)
                hasValidPNG = src.flatMap { CGImageSourceCreateImageAtIndex($0, 0, nil) } != nil
            }
        }
        #expect(hasValidPNG == true)

        // Soft Trash ONLY — record still exists with isTrashed == true and is discoverable via only_trashed
        let trashOut = await service.callTool(name: "trash_assets", arguments: [
            "asset_ids": [a2.id.uuidString],
            "trashed": true
        ])
        #expect(trashOut.isError == false)
        let trashedA2 = try #require(await engine.fetchAsset(id: a2.id))
        #expect(trashedA2.isTrashed == true)

        let listTrash = await service.callTool(name: "search_assets", arguments: ["only_trashed": true])
        #expect(listTrash.isError == false)
        #expect(try decodeToolJSON(listTrash)["totalMatched"] as? Int == 1)
    }

    @Test("MCP and CLI services can be enabled or disabled independently with legacy config migration and diagnostics")
    func independentMCPAndCLIToggles() async throws {
        let (dir, _, service, _) = try await makeTestService()
        defer { try? FileManager.default.removeItem(at: dir) }

        // 1. Legacy v1.0.0 JSON (`enabled` only, no `mcpEnabled`/`cliEnabled`) migrates cleanly
        let legacyDisabledJSON = Data(#"{"enabled":false,"accessLevel":"readWriteOrganize"}"#.utf8)
        let decodedDisabled = try JSONDecoder().decode(ExternalAgentConfig.self, from: legacyDisabledJSON)
        #expect(decodedDisabled.mcpEnabled == false)
        #expect(decodedDisabled.cliEnabled == false)
        #expect(decodedDisabled.enabled == false)
        #expect(decodedDisabled.accessLevel == .readWriteOrganize)

        let legacyEnabledJSON = Data(#"{"enabled":true,"accessLevel":"readOnly"}"#.utf8)
        let decodedEnabled = try JSONDecoder().decode(ExternalAgentConfig.self, from: legacyEnabledJSON)
        #expect(decodedEnabled.mcpEnabled == true)
        #expect(decodedEnabled.cliEnabled == true)
        #expect(decodedEnabled.enabled == true)

        // 2. MCP OFF, CLI ON -> MCP JSON-RPC & MCP tool calls blocked; CLI read & write succeed
        try ExternalAgentConfigStore.save(
            ExternalAgentConfig(mcpEnabled: false, cliEnabled: true, accessLevel: .readWriteOrganize),
            in: service.configDirectory
        )
        let mcpInitBlocked = try #require(await sendRPC(service, [
            "jsonrpc": "2.0",
            "id": 10,
            "method": "initialize",
            "params": ["protocolVersion": "2025-03-26"]
        ]) as? [String: Any])
        #expect(mcpInitBlocked["error"] != nil)

        let mcpListBlocked = try #require(await sendRPC(service, [
            "jsonrpc": "2.0",
            "id": 11,
            "method": "tools/list"
        ]) as? [String: Any])
        #expect(mcpListBlocked["error"] != nil)

        let mcpPromptsBlocked = try #require(await sendRPC(service, [
            "jsonrpc": "2.0",
            "id": 12,
            "method": "prompts/list"
        ]) as? [String: Any])
        #expect(mcpPromptsBlocked["error"] != nil)

        let mcpToolBlocked = await service.callTool(name: "library_overview", arguments: [:], channel: .mcp)
        #expect(mcpToolBlocked.isError == true)

        let cliReadAllowed = await service.callTool(name: "library_overview", arguments: [:], channel: .cli)
        #expect(cliReadAllowed.isError == false)
        let cliWriteAllowed = await service.callTool(name: "create_folder", arguments: ["name": "CLI Only Folder"], channel: .cli)
        #expect(cliWriteAllowed.isError == false)

        // 3. MCP ON, CLI OFF -> CLI calls blocked; MCP JSON-RPC & MCP tools succeed
        try ExternalAgentConfigStore.save(
            ExternalAgentConfig(mcpEnabled: true, cliEnabled: false, accessLevel: .readWriteOrganize),
            in: service.configDirectory
        )
        let cliReadBlocked = await service.callTool(name: "library_overview", arguments: [:], channel: .cli)
        #expect(cliReadBlocked.isError == true)
        let cliWriteBlocked = await service.callTool(name: "create_folder", arguments: ["name": "ShouldBlock"], channel: .cli)
        #expect(cliWriteBlocked.isError == true)

        let mcpInitAllowed = try #require(await sendRPC(service, [
            "jsonrpc": "2.0",
            "id": 20,
            "method": "initialize",
            "params": ["protocolVersion": "2025-03-26"]
        ]) as? [String: Any])
        #expect(mcpInitAllowed["result"] != nil)

        let mcpToolAllowed = await service.callTool(name: "create_folder", arguments: ["name": "MCP Only Folder"], channel: .mcp)
        #expect(mcpToolAllowed.isError == false)

        // 4. Diagnostics report works cleanly without leaking secrets
        let diag = await service.runDiagnostics()
        #expect(diag["ok"] as? Bool == true)
        let caps = try #require(diag["capabilities"] as? [String: Any])
        #expect(caps["toolCount"] as? Int == 20)
        #expect(caps["permanentDeleteAllowed"] as? Bool == false)

        // 5. Persisted round-trip preserves independent channel flags
        let reloaded = ExternalAgentConfigStore.load(in: service.configDirectory)
        #expect(reloaded.mcpEnabled == true)
        #expect(reloaded.cliEnabled == false)
        #expect(reloaded.enabled == true)
    }

    @Test("Token-efficient compact JSON, folder semantic atlas, default subfolder recursion, CJK semantic recall, diversify, facets, one-shot Contact Sheet, and batch get_asset")
    func agentDiscoveryAccuracyAndTokenOptimizations() async throws {
        let (dir, engine, service, assets) = try await makeTestService()
        defer { try? FileManager.default.removeItem(at: dir) }
        try ExternalAgentConfigStore.save(ExternalAgentConfig(enabled: true, accessLevel: .readWriteOrganize), in: service.configDirectory)

        let a1 = try #require(assets.first)
        let a2 = try #require(assets.last)
        let png3 = try BackendFixture.artwork("#2A6F97") // duplicate visual color/content of a2
        let extra = try await engine.ingest([
            .imageData(png3, suggestedName: "Ocean Copy.png", sourceURL: nil),
            .textSnippet(title: "夏日海边参考", text: "海风与晴空下的角色配色笔记", sourceURL: nil)
        ], targetFolderID: nil, targetBoardID: nil)
        let a3 = try #require(extra.first)
        let a4 = try #require(extra.last)

        // Create container parent folder with 0 direct assets and 2 child folders
        let parent = try await engine.createFolder(name: "插画", parentID: nil)
        let childWarm = try await engine.createFolder(name: "暖调海报", parentID: parent.id)
        let childSummer = try await engine.createFolder(name: "夏日海边", parentID: parent.id)

        _ = try await engine.updateAssets(AssetBatchPatch(
            assetIDs: [a1.id],
            notes: "Terracotta studio editorial poster with warm shadows",
            rating: 5,
            addTags: ["暖色", "海报", "复古"],
            folderAssignment: .folder(childWarm.id)
        ))
        _ = try await engine.updateAssets(AssetBatchPatch(
            assetIDs: [a2.id, a3.id],
            rating: 3,
            addTags: ["海洋", "蓝天", "夏日"],
            folderAssignment: .folder(childSummer.id)
        ))
        _ = try await engine.updateAssets(AssetBatchPatch(
            assetIDs: [a4.id],
            rating: 4,
            addTags: ["女孩", "夏日", "晴空"],
            folderAssignment: .folder(childSummer.id)
        ))
        _ = try await engine.saveBoard(MoodboardDocument(title: "夏日视觉板", nodes: MoodboardCurator.editorialNodes([a1, a2])))

        // 1. Lean tools/list schema (< 17_000 chars) + compact JSON output (no pretty-print newlines)
        let toolsResp = try #require(await sendRPC(service, ["jsonrpc": "2.0", "id": 1, "method": "tools/list"]) as? [String: Any])
        let toolsData = try JSONSerialization.data(withJSONObject: toolsResp)
        #expect(toolsData.count < 17_000)

        let ovOut = await service.callTool(name: "library_overview", arguments: [:])
        #expect(ovOut.isError == false)
        let ovRaw = ovOut.content.compactMap { if case .text(let t) = $0 { return t } else { return nil } }.joined()
        #expect(!ovRaw.contains("\n  "))
        let ov = try decodeToolJSON(ovOut)
        #expect(ov["ratedCount"] as? Int == 4)
        #expect((ov["aspectShapeCounts"] as? [String: Int]) != nil)
        #expect((ov["boards"] as? [[String: Any]])?.count == 1)
        let ovFolders = try #require(ov["folders"] as? [[String: Any]])
        let parentEntry = try #require(ovFolders.first { ($0["path"] as? String) == "插画" })
        #expect(parentEntry["assetCount"] as? Int == 0)
        #expect(parentEntry["recursiveAssetCount"] as? Int == 4)
        #expect(((parentEntry["topTags"] as? [String]) ?? []).contains("夏日"))
        #expect(!((parentEntry["palette"] as? [String]) ?? []).isEmpty)

        // 2. Parent folder defaults to include_subfolders=true; explicit false returns 0 direct
        let parentSearch = try decodeToolJSON(await service.callTool(name: "search_assets", arguments: ["folder_path": "插画"]))
        #expect(parentSearch["totalMatched"] as? Int == 4)
        let directOnly = try decodeToolJSON(await service.callTool(name: "search_assets", arguments: ["folder_path": "插画", "include_subfolders": false]))
        #expect(directOnly["totalMatched"] as? Int == 0)

        // 3. any_tags (OR), exclude_tags, exclude_asset_ids, auto facets when totalMatched > limit, and compact omission
        let anySearch = try decodeToolJSON(await service.callTool(name: "search_assets", arguments: [
            "any_tags": ["复古", "女孩"],
            "exclude_tags": ["海洋"],
            "limit": 1
        ]))
        #expect(anySearch["totalMatched"] as? Int == 2)
        #expect(anySearch["facets"] != nil)
        let firstHit = try #require((anySearch["assets"] as? [[String: Any]])?.first)
        #expect(firstHit["folderID"] == nil) // omitted in compact detail
        #expect(firstHit["aspectShape"] as? String != nil)

        let exclSearch = try decodeToolJSON(await service.callTool(name: "search_assets", arguments: [
            "folder_path": "插画",
            "exclude_asset_ids": [a1.id.uuidString, a4.id.uuidString]
        ]))
        #expect(exclSearch["totalMatched"] as? Int == 2)

        // 4. Diversify suppresses exact contentHash near-duplicate (a2 vs a3)
        let divSearch = try decodeToolJSON(await service.callTool(name: "search_assets", arguments: [
            "folder_path": "插画/夏日海边",
            "diversify": true,
            "limit": 10
        ]))
        #expect(divSearch["diversified"] as? Bool == true)
        #expect((divSearch["returned"] as? Int) == 2) // a2/a3 deduplicated + a4

        // 5. One-shot search_assets with render_contact_sheet=true returns inline JPEG + slot/badge annotations
        let oneShotOut = await service.callTool(name: "search_assets", arguments: [
            "folder_path": "插画",
            "diversify": true,
            "render_contact_sheet": true,
            "sheet_max_width": 640,
            "limit": 4
        ])
        #expect(oneShotOut.isError == false)
        #expect(oneShotOut.content.contains { if case .image(let mime, _) = $0 { return mime == "image/jpeg" } else { return false } })
        let oneShotJSON = try decodeToolJSON(oneShotOut)
        let csMeta = try #require(oneShotJSON["contactSheet"] as? [String: Any])
        #expect((csMeta["slotCount"] as? Int ?? 0) >= 2)
        let oneShotAssets = try #require(oneShotJSON["assets"] as? [[String: Any]])
        #expect(oneShotAssets.first?["badge"] as? String == "#01")

        // Security check: output_path on search_assets(render_contact_sheet=true) still respects readOnly policy
        try ExternalAgentConfigStore.save(ExternalAgentConfig(enabled: true, accessLevel: .readOnly), in: service.configDirectory)
        let roBlocked = await service.callTool(name: "search_assets", arguments: [
            "folder_path": "插画",
            "render_contact_sheet": true,
            "output_path": dir.appending(path: "blocked.jpg").path
        ])
        #expect(roBlocked.isError == true)
        try ExternalAgentConfigStore.save(ExternalAgentConfig(enabled: true, accessLevel: .readWriteOrganize), in: service.configDirectory)

        // 6. Unspaced Chinese natural-language semantic_search + one-shot Contact Sheet (fast local recall)
        let cjkSemOut = await service.callTool(name: "semantic_search", arguments: [
            "query": "夏日海边蓝天女孩",
            "visual_rerank": false,
            "render_contact_sheet": true,
            "limit": 5
        ])
        #expect(cjkSemOut.isError == false)
        let cjkSemJSON = try decodeToolJSON(cjkSemOut)
        #expect((cjkSemJSON["returned"] as? Int ?? 0) >= 2)
        #expect(cjkSemJSON["usedVisualRerank"] as? Bool == false)
        #expect(cjkSemJSON["contactSheet"] != nil)

        // 7. Batch get_asset with asset_ids + include_image returns both assets + zoomed Contact Sheet in 1 call
        let batchOut = await service.callTool(name: "get_asset", arguments: [
            "asset_ids": [a1.id.uuidString, a2.id.uuidString],
            "include_image": true
        ])
        #expect(batchOut.isError == false)
        #expect(batchOut.content.contains { if case .image(let mime, _) = $0 { return mime == "image/jpeg" } else { return false } })
        let batchJSON = try decodeToolJSON(batchOut)
        #expect(batchJSON["returned"] as? Int == 2)
        let batchAssets = try #require(batchJSON["assets"] as? [[String: Any]])
        #expect(batchAssets[0]["badge"] as? String == "#01")
        #expect(batchAssets[1]["badge"] as? String == "#02")

        // 8. Compact overview omits redundant name/parentID/cache and uses 8-char folder IDs; compact=false restores full fields
        #expect((parentEntry["id"] as? String)?.count == 8)
        #expect(parentEntry["name"] == nil)
        #expect(ov["cache"] == nil)
        let fullOv = try decodeToolJSON(await service.callTool(name: "library_overview", arguments: ["compact": false]))
        #expect(fullOv["cache"] != nil)
        let fullFolders = try #require(fullOv["folders"] as? [[String: Any]])
        let fullParent = try #require(fullFolders.first { ($0["path"] as? String) == "插画" })
        #expect((fullParent["id"] as? String)?.count == 36)
        #expect(fullParent["name"] as? String == "插画")

        // 9. 8-char short UUID prefix resolution works across get_asset, organize_assets, find_similar_assets, and dynamic resources
        let shortA1 = String(a1.id.uuidString.prefix(8))
        let shortA2 = String(a2.id.uuidString.prefix(8))
        let shortGet = try decodeToolJSON(await service.callTool(name: "get_asset", arguments: ["asset_id": shortA1]))
        #expect(shortGet["id"] as? String == a1.id.uuidString)
        let shortOrg = await service.callTool(name: "organize_assets", arguments: ["asset_ids": [shortA1], "add_tags": ["短码测试"]])
        #expect(shortOrg.isError == false)
        let shortRes = try #require(await sendRPC(service, [
            "jsonrpc": "2.0",
            "id": 99,
            "method": "resources/read",
            "params": ["uri": "charkle://assets/\(shortA1)"]
        ]) as? [String: Any])
        #expect((shortRes["result"] as? [String: Any])?["contents"] != nil)

        // 10. Ultra-lean `detail: "visual"` auto-activates on inline Contact Sheets (8-char IDs, no tags/aiDescription bloat)
        #expect((oneShotAssets.first?["id"] as? String)?.count == 8)
        #expect(oneShotAssets.first?["aiDescription"] == nil)
        #expect(oneShotAssets.first?["tags"] == nil)

        // 11. Cross-lingual EN -> ZH semantic recall & CIELAB VisualTone filter (`warm` vs `cool`)
        let enRecall = try decodeToolJSON(await service.callTool(name: "semantic_search", arguments: [
            "query": "summer beach sky girl",
            "visual_rerank": false,
            "limit": 5
        ]))
        #expect((enRecall["returned"] as? Int ?? 0) >= 2)

        let warmSearch = try decodeToolJSON(await service.callTool(name: "search_assets", arguments: [
            "folder_path": "插画",
            "tone": "warm"
        ]))
        let warmIDs = Set(((warmSearch["assets"] as? [[String: Any]]) ?? []).compactMap { $0["id"] as? String })
        #expect(warmIDs.contains(a1.id.uuidString))
        #expect(!warmIDs.contains(a2.id.uuidString))

        let coolSearch = try decodeToolJSON(await service.callTool(name: "search_assets", arguments: [
            "folder_path": "插画",
            "tone": "cool"
        ]))
        let coolIDs = Set(((coolSearch["assets"] as? [[String: Any]]) ?? []).compactMap { $0["id"] as? String })
        #expect(coolIDs.contains(a2.id.uuidString))
        #expect(!coolIDs.contains(a1.id.uuidString))

        // 12. Negative visual repulsion (`unlike_asset_ids`) excludes & repels negative examples
        let unlikeSem = try decodeToolJSON(await service.callTool(name: "semantic_search", arguments: [
            "query": "夏日 海洋 暖色",
            "unlike_asset_ids": [shortA2],
            "visual_rerank": false,
            "limit": 5
        ]))
        let unlikeHitIDs = Set(((unlikeSem["hits"] as? [[String: Any]]) ?? []).compactMap { $0["id"] as? String })
        #expect(!unlikeHitIDs.contains(a2.id.uuidString))

        // 13. Multi-intent single-call `queries[]` merges multiple creative directions into ONE Contact Sheet
        let multiOut = await service.callTool(name: "semantic_search", arguments: [
            "queries": ["暖色复古海报", "夏日海洋蓝天"],
            "diversify": true,
            "render_contact_sheet": true,
            "limit": 4
        ])
        #expect(multiOut.isError == false)
        #expect(multiOut.content.contains { if case .image(let mime, _) = $0 { return mime == "image/jpeg" } else { return false } })
        let multiJSON = try decodeToolJSON(multiOut)
        let groups = try #require(multiJSON["queryGroups"] as? [[String: Any]])
        #expect(groups.count == 2)
        let multiHits = try #require(multiJSON["hits"] as? [[String: Any]])
        #expect(multiHits.contains { ($0["queryGroup"] as? String) == "暖色复古海报" })
        #expect(multiHits.contains { ($0["queryGroup"] as? String) == "夏日海洋蓝天" })
    }
}
