@testable import CharkleCore
import Foundation
import ImageIO
import Testing

@Suite("External Agent Pure MCP v2 (stdio + HTTP, 10 Tools, Scoped Tokens, Rollback)")
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

    private func sendRPC(
        _ service: CharkleExternalAgentService,
        _ request: Any,
        context: ExternalAgentRequestContext = .localStdio
    ) async throws -> Any? {
        let reqData = try JSONSerialization.data(withJSONObject: request)
        guard let respData = await service.handleJSONRPC(reqData, context: context) else { return nil }
        return try JSONSerialization.jsonObject(with: respData)
    }

    private func decodeToolJSON(_ output: CharkleExternalAgentService.ToolOutput) throws -> [String: Any] {
        let text = output.content.compactMap { if case .text(let t) = $0 { return t } else { return nil } }.joined()
        let data = try #require(text.data(using: .utf8))
        return try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    @Test("Pure MCP v2 lifecycle negotiates protocol, lists 10 lean orthogonal tools (<12KB), 5+2 resources, 5 prompts, and handles batch JSON-RPC")
    func mcpProtocolLifecycleAndToolRegistry() async throws {
        let (dir, _, service, assets) = try await makeTestService()
        defer { try? FileManager.default.removeItem(at: dir) }
        let firstAsset = try #require(assets.first)

        // 1. initialize (known modern version & unknown fallback negotiation)
        let initResp = try #require(await sendRPC(service, [
            "jsonrpc": "2.0",
            "id": 1,
            "method": "initialize",
            "params": ["protocolVersion": "2025-11-25", "clientInfo": ["name": "claude-code", "version": "2.0"]]
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
        #expect(serverInfo["version"] as? String == "2.0.0")

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

        // 4. tools/list -> exactly 10 orthogonal safe tools, lean schema (< 12 KB), zero permanent/folder delete
        let toolsResp = try #require(await sendRPC(service, ["jsonrpc": "2.0", "id": 3, "method": "tools/list"]) as? [String: Any])
        let toolsData = try JSONSerialization.data(withJSONObject: toolsResp)
        #expect(toolsData.count < 12_000)

        let toolsResult = try #require(toolsResp["result"] as? [String: Any])
        let tools = try #require(toolsResult["tools"] as? [[String: Any]])
        let names = Set(tools.compactMap { $0["name"] as? String })
        #expect(names == [
            "library_overview",
            "query_assets",
            "inspect_assets",
            "get_board",
            "ingest_assets",
            "organize_assets",
            "manage_folder",
            "save_moodboard",
            "deduplicate_assets",
            "rollback_run"
        ])

        // Security invariants: NEVER expose permanent delete, folder delete, or disk output_path!
        #expect(!names.contains(where: { $0.contains("permanent") || $0.contains("delete_") }))
        for t in tools {
            let ann = try #require(t["annotations"] as? [String: Any])
            #expect(ann["destructiveHint"] as? Bool == false)
            #expect((ann["title"] as? String)?.isEmpty == false)
            let schemaProps = ((t["inputSchema"] as? [String: Any])?["properties"] as? [String: Any]) ?? [:]
            #expect(schemaProps["output_path"] == nil)
        }

        // 5. resources/list (5 incl. taxonomy), templates (2), static & dynamic reads
        let listRes = try #require(await sendRPC(service, ["jsonrpc": "2.0", "id": 4, "method": "resources/list"]) as? [String: Any])
        let resList = try #require((listRes["result"] as? [String: Any])?["resources"] as? [[String: Any]])
        #expect(resList.count == 5)
        #expect(resList.contains { ($0["uri"] as? String) == "charkle://library/taxonomy" })

        let taxRes = try #require(await sendRPC(service, [
            "jsonrpc": "2.0",
            "id": 41,
            "method": "resources/read",
            "params": ["uri": "charkle://library/taxonomy"]
        ]) as? [String: Any])
        let taxContents = try #require((taxRes["result"] as? [String: Any])?["contents"] as? [[String: Any]])
        #expect((taxContents.first?["text"] as? String)?.contains("preferredTagLanguage") == true)

        let tmplRes = try #require(await sendRPC(service, ["jsonrpc": "2.0", "id": 5, "method": "resources/templates/list"]) as? [String: Any])
        let tmpls = try #require((tmplRes["result"] as? [String: Any])?["resourceTemplates"] as? [[String: Any]])
        #expect(tmpls.count == 2)

        let assetRes = try #require(await sendRPC(service, [
            "jsonrpc": "2.0",
            "id": 6,
            "method": "resources/read",
            "params": ["uri": "charkle://assets/\(String(firstAsset.id.uuidString.prefix(8)))"]
        ]) as? [String: Any])
        let contents = try #require((assetRes["result"] as? [String: Any])?["contents"] as? [[String: Any]])
        #expect(contents.first?["mimeType"] as? String == "application/json")
        #expect((contents.first?["text"] as? String)?.contains(firstAsset.id.uuidString) == true)

        // 6. prompts/list (5) & prompts/get
        let promptsResp = try #require(await sendRPC(service, ["jsonrpc": "2.0", "id": 7, "method": "prompts/list"]) as? [String: Any])
        let prompts = try #require((promptsResp["result"] as? [String: Any])?["prompts"] as? [[String: Any]])
        #expect(prompts.count == 5)

        let promptGet = try #require(await sendRPC(service, [
            "jsonrpc": "2.0",
            "id": 8,
            "method": "prompts/get",
            "params": ["name": "deduplicate_library", "arguments": ["scope": "all"]]
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

        let bytes = Array(framed1.utf8)
        #expect(parser.append(Data(bytes[0..<18])).isEmpty)
        #expect(parser.append(Data(bytes[18..<68])).isEmpty)
        #expect(parser.append(Data(bytes[68..<84])).isEmpty)
        let ev1 = parser.append(Data(bytes[84..<bytes.count]))
        #expect(ev1 == [.message(Data(body1.utf8), framing: .contentLength)])

        let ndjson = #"{"jsonrpc":"2.0","id":2,"method":"ping"}"# + "\n"
        #expect(parser.append(Data(ndjson.utf8)) == [.message(Data(#"{"jsonrpc":"2.0","id":2,"method":"ping"}"#.utf8), framing: .ndjson)])

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
        #expect(parser.finishEOF() == [.message(Data(trailing.utf8), framing: .ndjson)])
    }

    @Test("3-tier permissions, heterogeneous organize_assets + dry_run + canonical tag folding, deduplicate_assets, save_moodboard, and compensating rollback_run work end-to-end")
    func permissionsBatchOrganizeDedupAndRollback() async throws {
        let (dir, engine, service, assets) = try await makeTestService()
        defer { try? FileManager.default.removeItem(at: dir) }

        let a1 = try #require(assets.first)
        let a2 = try #require(assets.last)
        let shortA1 = String(a1.id.uuidString.prefix(8))
        let shortA2 = String(a2.id.uuidString.prefix(8))

        // Policy 0: Disabled -> blocks even reads
        try ExternalAgentConfigStore.save(ExternalAgentConfig(enabled: false, accessLevel: .readOnly), in: service.configDirectory)
        #expect(await service.callTool(name: "library_overview", arguments: [:]).isError == true)

        // Policy 1: readOnly -> allows reads, scan, list runs; blocks mutations & output_path
        try ExternalAgentConfigStore.save(ExternalAgentConfig(enabled: true, accessLevel: .readOnly), in: service.configDirectory)
        let roSheet = await service.callTool(name: "query_assets", arguments: [
            "only_inbox": true,
            "contact_sheet": true,
            "include_folder_suggestions": true,
            "limit": 2
        ])
        #expect(roSheet.isError == false)
        #expect(roSheet.content.contains { if case .image(let mime, _) = $0 { return mime == "image/jpeg" } else { return false } })
        #expect(await service.callTool(name: "deduplicate_assets", arguments: ["action": "scan"]).isError == false)
        #expect(await service.callTool(name: "rollback_run", arguments: ["action": "list"]).isError == false)
        #expect(await service.callTool(name: "manage_folder", arguments: ["action": "create", "name": "Nope"]).isError == true)
        #expect(await service.callTool(name: "organize_assets", arguments: ["asset_ids": [shortA1], "rating": 5]).isError == true)
        #expect(await service.callTool(name: "query_assets", arguments: ["output_path": "/tmp/retired.jpg"]).isError == true)

        // Create two folders under readWriteOrganize so we can test `inboxAndEnrich` boundaries accurately
        try ExternalAgentConfigStore.save(ExternalAgentConfig(enabled: true, accessLevel: .readWriteOrganize), in: service.configDirectory)
        let fWarm = try decodeToolJSON(await service.callTool(name: "manage_folder", arguments: ["action": "create", "name": "暖色海报", "color_hex": "#C86D51"]))
        #expect(fWarm["reusedExisting"] as? Bool == false)
        let fWarmReuse = try decodeToolJSON(await service.callTool(name: "manage_folder", arguments: ["action": "create", "name": "暖色海报"]))
        #expect(fWarmReuse["reusedExisting"] as? Bool == true)
        _ = await service.callTool(name: "manage_folder", arguments: ["action": "create", "name": "海洋界面", "color_hex": "#2A6F97"])

        // Policy 2: inboxAndEnrich -> can triage Inbox into existing folders & enrich, CANNOT create folders, trash, or move already-filed assets
        try ExternalAgentConfigStore.save(ExternalAgentConfig(enabled: true, accessLevel: .inboxAndEnrich), in: service.configDirectory)
        #expect(await service.callTool(name: "manage_folder", arguments: ["action": "create", "name": "Blocked"]).isError == true)
        #expect(await service.callTool(name: "organize_assets", arguments: ["asset_ids": [shortA1], "trashed": true]).isError == true)

        // Dry-run heterogeneous triage of BOTH Inbox items to TWO DIFFERENT folders in 1 call!
        let dryOut = await service.callTool(name: "organize_assets", arguments: [
            "dry_run": true,
            "items": [
                ["asset_id": shortA1, "folder_path": "暖色海报", "add_tags": ["暖调", "海报"], "rating": 5, "ai_description": "暖陶土色极简海报"],
                ["asset_id": shortA2, "folder_path": "海洋界面", "add_tags": ["海洋", "UI"], "add_suggested_tags": ["冷色系"], "rating": 4]
            ]
        ])
        #expect(dryOut.isError == false)
        let dryJSON = try decodeToolJSON(dryOut)
        #expect(dryJSON["dryRun"] as? Bool == true)
        #expect(dryJSON["plannedCount"] as? Int == 2)
        #expect(dryJSON["folderMoveCount"] as? Int == 2)
        // Verify zero mutation happened during dry_run
        #expect((try await engine.fetchAsset(id: a1.id))?.folderID == nil)

        // Commit heterogeneous batch in 1 call!
        let commitOut = await service.callTool(name: "organize_assets", arguments: [
            "items": [
                ["asset_id": shortA1, "folder_path": "暖色海报", "add_tags": ["暖调", "海报"], "rating": 5, "ai_description": "暖陶土色极简海报"],
                ["asset_id": shortA2, "folder_path": "海洋界面", "add_tags": ["海洋", "UI"], "add_suggested_tags": ["冷色系"], "rating": 4]
            ]
        ])
        #expect(commitOut.isError == false)
        let commitJSON = try decodeToolJSON(commitOut)
        let orgRunID = try #require(commitJSON["runID"] as? String)
        #expect(commitJSON["updatedCount"] as? Int == 2)
        #expect(commitJSON["folderMoveCount"] as? Int == 2)

        // Now that a1 is filed in "暖色海报", `inboxAndEnrich` MUST block moving it out, while still allowing pure `ai_description` enrichment!
        let blockedCuratedMove = await service.callTool(name: "organize_assets", arguments: [
            "asset_ids": [shortA1],
            "folder_path": "海洋界面"
        ])
        #expect(blockedCuratedMove.isError == true)
        let allowedEnrich = await service.callTool(name: "organize_assets", arguments: [
            "asset_ids": [shortA1],
            "ai_description": "更新后的暖陶土平面海报"
        ])
        #expect(allowedEnrich.isError == false)
        #expect((try await engine.fetchAsset(id: a1.id))?.aiDescription == "更新后的暖陶土平面海报")

        // Rollback the heterogeneous organize run -> BOTH a1 & a2 return cleanly to Inbox with original tags & rating!
        try ExternalAgentConfigStore.save(ExternalAgentConfig(enabled: true, accessLevel: .readWriteOrganize), in: service.configDirectory)
        let rbOut = await service.callTool(name: "rollback_run", arguments: ["action": "rollback", "run_id": orgRunID])
        #expect(rbOut.isError == false)
        let rbJSON = try decodeToolJSON(rbOut)
        #expect(rbJSON["restoredAssetCount"] as? Int == 2)
        let a1Restored = try #require(await engine.fetchAsset(id: a1.id))
        let a2Restored = try #require(await engine.fetchAsset(id: a2.id))
        #expect(a1Restored.folderID == nil)
        #expect(a1Restored.rating == 0)
        #expect(a1Restored.tags.isEmpty)
        #expect(a2Restored.folderID == nil)

        // Taxonomy alias folding in organize_assets
        try await ExternalAgentStateStore.saveTaxonomy(
            LibraryTaxonomyPolicy(preferredTagLanguage: "zh", tagAliases: ["blue sky": "晴空"]),
            to: engine.database
        )
        let aliasOut = try decodeToolJSON(await service.callTool(name: "organize_assets", arguments: [
            "asset_ids": [shortA2],
            "add_tags": ["blue sky"]
        ]))
        let normalizedList = try #require(aliasOut["normalizedTags"] as? [[String: String]])
        #expect(normalizedList.contains { $0["from"] == "blue sky" && $0["to"] == "晴空" })
        #expect((try await engine.fetchAsset(id: a2.id))?.tags.contains("晴空") == true)

        // Deduplicate scan + side-by-side Contact Sheet + safe soft-Trash merge + rollback
        let dupPNG = try BackendFixture.artwork("#2A6F97")
        let extra = try await engine.ingest([.imageData(dupPNG, suggestedName: "Ocean Copy.png", sourceURL: nil)], targetFolderID: nil, targetBoardID: nil)
        let a3 = try #require(extra.first)

        let scanOut = await service.callTool(name: "deduplicate_assets", arguments: [
            "action": "scan",
            "scope": "all",
            "contact_sheet": true
        ])
        #expect(scanOut.isError == false)
        #expect(scanOut.content.contains { if case .image(let mime, _) = $0 { return mime == "image/jpeg" } else { return false } })
        let scanJSON = try decodeToolJSON(scanOut)
        #expect((scanJSON["totalGroups"] as? Int ?? 0) >= 1)

        let mergeOut = await service.callTool(name: "deduplicate_assets", arguments: [
            "action": "merge",
            "groups": [["keep_asset_id": shortA2, "discard_asset_ids": [String(a3.id.uuidString.prefix(8))]]]
        ])
        #expect(mergeOut.isError == false)
        let mergeJSON = try decodeToolJSON(mergeOut)
        let mergeRunID = try #require(mergeJSON["runID"] as? String)
        #expect((try await engine.fetchAsset(id: a3.id))?.isTrashed == true)

        // Rollback dedup merge -> a3 restored from soft Trash!
        let rbMerge = await service.callTool(name: "rollback_run", arguments: ["action": "rollback", "run_id": mergeRunID])
        #expect(rbMerge.isError == false)
        #expect((try await engine.fetchAsset(id: a3.id))?.isTrashed == false)

        // save_moodboard (create + locked-node-safe patch + get_board with inline PNG snapshot + rollback patch)
        let createBoard = try decodeToolJSON(await service.callTool(name: "save_moodboard", arguments: [
            "title": "MCP v2 情绪板",
            "use_freeform": true,
            "sections": [[
                "title": "主视觉",
                "tint": "terracotta",
                "asset_ids": [shortA1],
                "hero_asset_ids": [shortA1]
            ]]
        ]))
        let boardIDStr = try #require(createBoard["boardID"] as? String)
        let boardUUID = try #require(UUID(uuidString: boardIDStr))

        var loadedBoard = try #require(await engine.fetchBoard(id: boardUUID))
        for idx in loadedBoard.nodes.indices where loadedBoard.nodes[idx].referencedAssetID == a1.id {
            loadedBoard.nodes[idx].isLocked = true
        }
        _ = try await engine.saveBoard(loadedBoard)

        let patchBoard = try decodeToolJSON(await service.callTool(name: "save_moodboard", arguments: [
            "board_id": String(boardIDStr.prefix(8)),
            "remove_asset_ids": [shortA1],
            "add_section": "补充冷色",
            "add_asset_ids": [shortA2],
            "add_note": "验证非破坏修补与回滚"
        ]))
        let patchRunID = try #require(patchBoard["runID"] as? String)
        #expect(patchBoard["addedCount"] as? Int == 1)
        #expect(patchBoard["removedCount"] as? Int == 0)
        #expect((patchBoard["skippedLockedAssetIDs"] as? [String])?.contains(a1.id.uuidString) == true)

        let boardSnap = await service.callTool(name: "get_board", arguments: [
            "board_id": String(boardIDStr.prefix(8)),
            "include_snapshot": true,
            "snapshot_width": 960
        ])
        #expect(boardSnap.isError == false)
        #expect(boardSnap.content.contains { if case .image(let mime, _) = $0 { return mime == "image/png" } else { return false } })

        // Rollback board patch -> itemCount returns to 1!
        #expect(await service.callTool(name: "rollback_run", arguments: ["action": "rollback", "run_id": patchRunID]).isError == false)
        let revertedBoard = try #require(await engine.fetchBoard(id: boardUUID))
        #expect(revertedBoard.referencedAssetIDs.count == 1)
    }

    @Test("query_assets session_id working set, crop_box detail zoom, multi-intent queries[], CIELAB tone, and 0-match relaxationHints work")
    func querySessionCropZoomAndDiscovery() async throws {
        let (dir, engine, service, assets) = try await makeTestService()
        defer { try? FileManager.default.removeItem(at: dir) }
        try ExternalAgentConfigStore.save(ExternalAgentConfig(enabled: true, accessLevel: .readWriteOrganize), in: service.configDirectory)

        let a1 = try #require(assets.first)
        let a2 = try #require(assets.last)

        let folder = try await engine.createFolder(name: "插画", parentID: nil)
        let sub = try await engine.createFolder(name: "精选", parentID: folder.id)
        _ = try await engine.updateAssets(AssetBatchPatch(assetIDs: [a1.id], addTags: ["暖色", "海报"], folderAssignment: .folder(sub.id)))
        _ = try await engine.updateAssets(AssetBatchPatch(assetIDs: [a2.id], addTags: ["海洋", "蓝天"], folderAssignment: .folder(sub.id)))

        // 1. Session deduplication across rounds (`session_id`)
        let r1 = try decodeToolJSON(await service.callTool(name: "query_assets", arguments: [
            "folder_path": "插画",
            "session_id": "s-demo",
            "limit": 1
        ]))
        #expect(r1["returned"] as? Int == 1)
        let id1 = try #require(((r1["assets"] as? [[String: Any]])?.first)?["id"] as? String)

        let r2 = try decodeToolJSON(await service.callTool(name: "query_assets", arguments: [
            "folder_path": "插画",
            "session_id": "s-demo",
            "limit": 1
        ]))
        #expect(r2["returned"] as? Int == 1)
        let id2 = try #require(((r2["assets"] as? [[String: Any]])?.first)?["id"] as? String)
        #expect(id1 != id2)

        // Round 3 exhausts unseen items cleanly
        let r3 = try decodeToolJSON(await service.callTool(name: "query_assets", arguments: [
            "folder_path": "插画",
            "session_id": "s-demo",
            "limit": 1
        ]))
        #expect(r3["returned"] as? Int == 0)

        // 2. 0-match relaxationHints
        let zeroOut = try decodeToolJSON(await service.callTool(name: "query_assets", arguments: [
            "folder_path": "插画",
            "tone": "dark"
        ]))
        #expect(zeroOut["totalMatched"] as? Int == 0)
        #expect(!((zeroOut["relaxationHints"] as? [String]) ?? []).isEmpty)

        // 3. inspect_assets with normalized `crop_box` detail zoom returns valid cropped JPEG
        let cropOut = await service.callTool(name: "inspect_assets", arguments: [
            "asset_id": String(a1.id.uuidString.prefix(8)),
            "include_image": true,
            "image_max_side": 448,
            "crop_box": ["x": 0.1, "y": 0.1, "width": 0.5, "height": 0.5]
        ])
        #expect(cropOut.isError == false)
        var validCroppedJPEG = false
        for item in cropOut.content {
            if case .image(let mime, let data) = item {
                #expect(mime == "image/jpeg")
                let src = CGImageSourceCreateWithData(data as CFData, nil)
                validCroppedJPEG = src.flatMap { CGImageSourceCreateImageAtIndex($0, 0, nil) } != nil
            }
        }
        #expect(validCroppedJPEG == true)

        // 4. Multi-intent `queries[]` merges into ONE Contact Sheet
        let multiOut = await service.callTool(name: "query_assets", arguments: [
            "queries": ["暖色海报", "海洋蓝天"],
            "contact_sheet": true,
            "diversify": true,
            "limit": 4
        ])
        #expect(multiOut.isError == false)
        #expect(multiOut.content.contains { if case .image(let mime, _) = $0 { return mime == "image/jpeg" } else { return false } })
        let multiJSON = try decodeToolJSON(multiOut)
        #expect((multiJSON["queryGroups"] as? [[String: Any]])?.count == 2)
    }

    @Test("Streamable HTTP MCP (/api/v1/mcp) enforces Scoped Bearer Tokens, blocks extension token & server file_path, supports inline_files upload and signed /api/v1/mcp/download/<ticket>")
    func streamableHTTPMCPEndToEndAndCrossMachineTransfer() async throws {
        let (dir, engine, service, assets) = try await makeTestService()
        defer { try? FileManager.default.removeItem(at: dir) }
        let a1 = try #require(assets.first)

        let mintedRO = ExternalAgentToken.mint(name: "Cloud Reader", accessLevel: .readOnly)
        let mintedRW = ExternalAgentToken.mint(name: "Cloud Organizer", accessLevel: .readWriteOrganize)
        try ExternalAgentConfigStore.save(
            ExternalAgentConfig(
                mcpEnabled: true,
                httpMCPEnabled: true,
                allowRemoteHTTPMCP: false,
                accessLevel: .readOnly,
                tokens: [mintedRO.record, mintedRW.record]
            ),
            in: service.configDirectory
        )

        let extToken = LocalExtensionBridgeServer.generateToken()
        let server = LocalExtensionBridgeServer(
            engine: engine,
            token: extToken,
            allowLocalAutoPair: true,
            preferredPort: 0,
            allowEphemeralPort: true,
            mcpService: service,
            allowRemoteMCP: false
        )
        let snap = try await server.start()
        defer { Task { await server.stop() } }
        let mcpURL = try #require(URL(string: snap.mcpEndpointURL))

        // 1. GET /api/v1/mcp -> 405 Method Not Allowed
        var getReq = URLRequest(url: mcpURL)
        getReq.httpMethod = "GET"
        let (_, getResp) = try await URLSession.shared.data(for: getReq)
        #expect((getResp as? HTTPURLResponse)?.statusCode == 405)

        // 2. Browser extension token MUST NOT authorize /api/v1/mcp (401)
        func postMCP(token: String?, body: [String: Any]) async throws -> (Int, Data) {
            var req = URLRequest(url: mcpURL)
            req.httpMethod = "POST"
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
            if let token { req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization") }
            req.httpBody = try JSONSerialization.data(withJSONObject: body)
            let (data, resp) = try await URLSession.shared.data(for: req)
            return ((resp as? HTTPURLResponse)?.statusCode ?? 0, data)
        }

        let (extCode, _) = try await postMCP(token: extToken, body: ["jsonrpc": "2.0", "id": 1, "method": "tools/list"])
        #expect(extCode == 401)

        // 3. Read-only Scoped Token: can inspect + get signed download URL (and NO localOriginalPath leaked!), CANNOT write
        let (roInspectCode, roInspectData) = try await postMCP(token: mintedRO.plaintext, body: [
            "jsonrpc": "2.0",
            "id": 2,
            "method": "tools/call",
            "params": [
                "name": "inspect_assets",
                "arguments": [
                    "asset_id": String(a1.id.uuidString.prefix(8)),
                    "include_download_url": true
                ]
            ]
        ])
        #expect(roInspectCode == 200)
        let roRPC = try #require(try JSONSerialization.jsonObject(with: roInspectData) as? [String: Any])
        let roResult = try #require(roRPC["result"] as? [String: Any])
        #expect(roResult["isError"] as? Bool == false)
        let roContent = try #require((roResult["content"] as? [[String: Any]])?.first?["text"] as? String)
        let roAssetJSON = try #require(try JSONSerialization.jsonObject(with: Data(roContent.utf8)) as? [String: Any])
        #expect(roAssetJSON["localOriginalPath"] == nil)
        #expect(roAssetJSON["thumbnailPath"] == nil)
        let downloadURLStr = try #require(roAssetJSON["downloadURL"] as? String)
        #expect(downloadURLStr.contains("/api/v1/mcp/download/"))

        // Fetch the signed download URL across HTTP -> receives real PNG bytes!
        let dlURL = try #require(URL(string: downloadURLStr))
        let (dlData, dlResp) = try await URLSession.shared.data(from: dlURL)
        #expect((dlResp as? HTTPURLResponse)?.statusCode == 200)
        #expect(dlData.count > 100)

        // Read-only token blocked on write
        let (roWriteCode, roWriteData) = try await postMCP(token: mintedRO.plaintext, body: [
            "jsonrpc": "2.0",
            "id": 3,
            "method": "tools/call",
            "params": ["name": "manage_folder", "arguments": ["action": "create", "name": "Denied"]]
        ])
        #expect(roWriteCode == 200)
        let roWriteRPC = try #require(try JSONSerialization.jsonObject(with: roWriteData) as? [String: Any])
        #expect((roWriteRPC["result"] as? [String: Any])?["isError"] as? Bool == true)

        // 4. Read-Write Scoped Token over HTTP: local `file_path` is STRICTLY BLOCKED, while `inline_files` Base64 upload SUCCEEDS!
        let (pathBlockedCode, pathBlockedData) = try await postMCP(token: mintedRW.plaintext, body: [
            "jsonrpc": "2.0",
            "id": 4,
            "method": "tools/call",
            "params": ["name": "ingest_assets", "arguments": ["file_path": "/etc/hosts"]]
        ])
        #expect(pathBlockedCode == 200)
        let pathBlockedRPC = try #require(try JSONSerialization.jsonObject(with: pathBlockedData) as? [String: Any])
        #expect((pathBlockedRPC["result"] as? [String: Any])?["isError"] as? Bool == true)

        let uploadPNG = try BackendFixture.artwork("#2D6A4F")
        let (inlineCode, inlineData) = try await postMCP(token: mintedRW.plaintext, body: [
            "jsonrpc": "2.0",
            "id": 5,
            "method": "tools/call",
            "params": [
                "name": "ingest_assets",
                "arguments": [
                    "inline_files": [[
                        "filename": "remote-forest.png",
                        "data_base64": uploadPNG.base64EncodedString()
                    ]],
                    "tags": ["跨机器上传"]
                ]
            ]
        ])
        #expect(inlineCode == 200)
        let inlineRPC = try #require(try JSONSerialization.jsonObject(with: inlineData) as? [String: Any])
        let inlineRes = try #require(inlineRPC["result"] as? [String: Any])
        #expect(inlineRes["isError"] as? Bool == false)
        let inlineText = try #require((inlineRes["content"] as? [[String: Any]])?.first?["text"] as? String)
        let inlineJSON = try #require(try JSONSerialization.jsonObject(with: Data(inlineText.utf8)) as? [String: Any])
        #expect(inlineJSON["importedCount"] as? Int == 1)
        #expect((inlineJSON["runID"] as? String)?.hasPrefix("run-") == true)
    }
}
