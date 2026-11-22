@testable import CharkleCore
import Foundation
import ImageIO
import Testing

@Suite("External Agent MCP Server, Permissions & Headless Board Export")
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

    private func sendRPC(_ service: CharkleExternalAgentService, _ request: [String: Any]) async throws -> [String: Any]? {
        let reqData = try JSONSerialization.data(withJSONObject: request)
        guard let respData = await service.handleJSONRPC(reqData) else { return nil }
        return try JSONSerialization.jsonObject(with: respData) as? [String: Any]
    }

    @Test("MCP JSON-RPC lifecycle negotiates protocol, lists all 14 safe tools, and never exposes permanent delete")
    func mcpProtocolLifecycleAndToolRegistry() async throws {
        let (dir, _, service, _) = try await makeTestService()
        defer { try? FileManager.default.removeItem(at: dir) }

        // 1. initialize
        let initResp = try #require(await sendRPC(service, [
            "jsonrpc": "2.0",
            "id": 1,
            "method": "initialize",
            "params": ["protocolVersion": "2025-03-26", "clientInfo": ["name": "claude-code", "version": "1.0"]]
        ]))
        let initResult = try #require(initResp["result"] as? [String: Any])
        #expect(initResult["protocolVersion"] as? String == "2025-03-26")
        let serverInfo = try #require(initResult["serverInfo"] as? [String: Any])
        #expect(serverInfo["name"] as? String == "charkle")

        // 2. notification returns nil (no JSON-RPC reply)
        let notifResp = try await sendRPC(service, ["jsonrpc": "2.0", "method": "notifications/initialized"])
        #expect(notifResp == nil)

        // 3. ping
        let pingResp = try #require(await sendRPC(service, ["jsonrpc": "2.0", "id": 2, "method": "ping"]))
        #expect(pingResp["result"] != nil)

        // 4. tools/list
        let toolsResp = try #require(await sendRPC(service, ["jsonrpc": "2.0", "id": 3, "method": "tools/list"]))
        let toolsResult = try #require(toolsResp["result"] as? [String: Any])
        let tools = try #require(toolsResult["tools"] as? [[String: Any]])
        let names = Set(tools.compactMap { $0["name"] as? String })
        #expect(names.count == 14)
        #expect(names.contains("library_overview"))
        #expect(names.contains("render_contact_sheet"))
        #expect(names.contains("get_board_context"))
        #expect(names.contains("export_board_image"))
        #expect(names.contains("compose_moodboard"))
        #expect(names.contains("trash_assets"))
        // Security invariant: NEVER expose permanent delete!
        #expect(!names.contains(where: { $0.contains("permanent") || $0.contains("delete_asset") }))

        // 5. resources/list & resources/read
        let resResp = try #require(await sendRPC(service, [
            "jsonrpc": "2.0",
            "id": 4,
            "method": "resources/read",
            "params": ["uri": "charkle://library/overview"]
        ]))
        let resResult = try #require(resResp["result"] as? [String: Any])
        let contents = try #require(resResult["contents"] as? [[String: Any]])
        #expect(contents.first?["mimeType"] as? String == "application/json")
    }

    @Test("Permission boundaries dynamically enforce disabled, readOnly, and readWriteOrganize (soft Trash only)")
    func permissionBoundariesAndEndToEndTools() async throws {
        let (dir, engine, service, assets) = try await makeTestService()
        defer { try? FileManager.default.removeItem(at: dir) }

        let a1 = try #require(assets.first)
        let a2 = try #require(assets.last)

        // Policy 1: Disabled -> blocks even reads
        try ExternalAgentConfigStore.save(ExternalAgentConfig(enabled: false, accessLevel: .readOnly), in: service.configDirectory)
        let blockedRead = await service.callTool(name: "library_overview", arguments: [:])
        #expect(blockedRead.isError == true)

        // Policy 2: Default readOnly -> allows reads & Contact Sheet image, blocks writes
        try ExternalAgentConfigStore.save(ExternalAgentConfig(enabled: true, accessLevel: .readOnly), in: service.configDirectory)
        let sheetOut = await service.callTool(name: "render_contact_sheet", arguments: ["only_inbox": true])
        #expect(sheetOut.isError == false)
        var hasValidJPEG = false
        for item in sheetOut.content {
            if case .image(let mime, let data) = item {
                #expect(mime == "image/jpeg")
                let src = CGImageSourceCreateWithData(data as CFData, nil)
                hasValidJPEG = src.flatMap { CGImageSourceCreateImageAtIndex($0, 0, nil) } != nil
            }
        }
        #expect(hasValidJPEG == true)

        let blockedWrite = await service.callTool(name: "create_folder", arguments: ["name": "ShouldFail"])
        #expect(blockedWrite.isError == true)

        // Policy 3: Switch live to readWriteOrganize -> allows folder creation, organizing, board compose + PNG export, and soft Trash
        try ExternalAgentConfigStore.save(ExternalAgentConfig(enabled: true, accessLevel: .readWriteOrganize), in: service.configDirectory)

        let folderOut = await service.callTool(name: "create_folder", arguments: ["name": "Agent Curated"])
        #expect(folderOut.isError == false)

        let orgOut = await service.callTool(name: "organize_assets", arguments: [
            "asset_ids": [a1.id.uuidString],
            "folder_path": "Agent Curated",
            "add_tags": ["terracotta", "editorial"],
            "rating": 5,
            "ai_description": "暖陶土色平面海报参考"
        ])
        #expect(orgOut.isError == false)
        let updatedA1 = try #require(await engine.fetchAsset(id: a1.id))
        #expect(updatedA1.rating == 5)
        #expect(updatedA1.tags.contains("terracotta"))
        #expect((updatedA1.aiDescription ?? "").contains("陶土"))

        // Compose structured moodboard via MCP `compose_moodboard`
        let composeOut = await service.callTool(name: "compose_moodboard", arguments: [
            "title": "MCP 联调情绪板",
            "subtitle": "由外部 Agent 直接策展并写入 Charkle",
            "curator_note": "聚焦暖陶土与海蓝的冷暖撞色对比。",
            "sections": [
                [
                    "title": "主视觉对比",
                    "tint": "terracotta",
                    "rationale": "冷暖对照",
                    "asset_ids": [a1.id.uuidString, a2.id.uuidString],
                    "hero_asset_ids": [a1.id.uuidString]
                ]
            ]
        ])
        #expect(composeOut.isError == false)

        // Inspect board context & headless PNG export via MCP
        let ctxOut = await service.callTool(name: "get_board_context", arguments: ["title": "MCP 联调情绪板"])
        #expect(ctxOut.isError == false)

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

        // Soft Trash ONLY — record still exists with isTrashed == true so user can always recover
        let trashOut = await service.callTool(name: "trash_assets", arguments: [
            "asset_ids": [a2.id.uuidString],
            "trashed": true
        ])
        #expect(trashOut.isError == false)
        let trashedA2 = try #require(await engine.fetchAsset(id: a2.id))
        #expect(trashedA2.isTrashed == true)
    }
}
