@testable import CharkleCore
import Foundation
import Security
import Testing

@Suite("Phase 2 Audit Fixes — Sync, AI, Auth & MCP")
struct AuditFixSyncAITests {

    // MARK: - 1. MCPStdioFrameParser Hardening

    @Test("MCPStdioFrameParser drops buffered oversized body, bounds NDJSON lines, recovers from bare ASCII lines, and handles mixed header newlines")
    func mcpStdioFrameParserHardening() throws {
        var parser = MCPStdioFrameParser(maxFrameBytes: 1024)

        // 1. Oversized Content-Length with body already in the same chunk must NOT execute body as NDJSON
        let fakeBody = String(repeating: "{", count: 1200)
        let nextValid = #"{"jsonrpc":"2.0","id":10,"method":"ping"}"# + "\n"
        let oversizedWithBody = "Content-Length: \(fakeBody.utf8.count)\r\n\r\n" + fakeBody + nextValid
        let ev1 = parser.append(Data(oversizedWithBody.utf8))
        #expect(ev1.count == 2)
        if case .invalidFrame(_, let framing) = ev1[0] {
            #expect(framing == .contentLength)
        } else {
            Issue.record("Expected invalidFrame for oversized Content-Length with buffered body")
        }
        #expect(ev1[1] == .message(Data(#"{"jsonrpc":"2.0","id":10,"method":"ping"}"#.utf8), framing: .ndjson))

        // 2. Oversized NDJSON line split across two chunks without newline must reject once and recover after newline
        let chunkA = Data(("{" + String(repeating: "a", count: 1100)).utf8)
        let chunkB = Data((String(repeating: "b", count: 200) + "}\n" + #"{"jsonrpc":"2.0","id":11,"method":"ping"}"# + "\n").utf8)
        let evA = parser.append(chunkA)
        #expect(evA.count == 1)
        if case .invalidFrame(_, let framing) = evA[0] {
            #expect(framing == .ndjson)
        } else {
            Issue.record("Expected invalidFrame for oversized NDJSON chunk")
        }
        let evB = parser.append(chunkB)
        #expect(evB == [.message(Data(#"{"jsonrpc":"2.0","id":11,"method":"ping"}"#.utf8), framing: .ndjson)])

        // 3. Bare ASCII token like `null\n` must NOT stall waiting for `\r\n\r\n`
        let bareASCII = "null\n" + #"{"jsonrpc":"2.0","id":12,"method":"ping"}"# + "\n"
        let evC = parser.append(Data(bareASCII.utf8))
        #expect(evC.count == 2)
        if case .invalidFrame(_, let framing) = evC[0] {
            #expect(framing == .ndjson)
        } else {
            Issue.record("Expected invalidFrame for bare ASCII line")
        }
        #expect(evC[1] == .message(Data(#"{"jsonrpc":"2.0","id":12,"method":"ping"}"#.utf8), framing: .ndjson))

        // 4. Mixed `\n` and `\r\n` header separators still parse Content-Length
        let body = #"{"jsonrpc":"2.0","id":13,"method":"ping"}"#
        let mixedHeader = "Content-Type: application/json\nContent-Length: \(body.utf8.count)\r\n\r\n\(body)"
        let evD = parser.append(Data(mixedHeader.utf8))
        #expect(evD == [.message(Data(body.utf8), framing: .contentLength)])
    }

    // MARK: - 2. ExternalAgentPolicy Fail-Closed & MCP Security / JSON-RPC Compliance

    @Test("ExternalAgentConfigStore fails closed on corrupt policy file while preserving defaults when absent")
    func externalAgentConfigFailsClosedWhenCorrupt() throws {
        let dir = try BackendFixture.directory()
        defer { try? FileManager.default.removeItem(at: dir) }

        // Absent file -> default config
        let absent = ExternalAgentConfigStore.load(in: dir)
        #expect(absent.mcpEnabled == true)
        #expect(absent.httpMCPEnabled == true)
        #expect(absent.allowRemoteHTTPMCP == false)
        #expect(absent.accessLevel == .readOnly)

        // Legacy v1 JSON migrates cleanly
        let legacyJSON = Data(#"{"enabled":false,"accessLevel":"readWriteOrganize"}"#.utf8)
        let legacyDecoded = try JSONDecoder().decode(ExternalAgentConfig.self, from: legacyJSON)
        #expect(legacyDecoded.mcpEnabled == false)
        #expect(legacyDecoded.httpMCPEnabled == false)
        #expect(legacyDecoded.accessLevel == .readWriteOrganize)

        // Corrupt existing file -> fail closed (both MCP transports disabled, readOnly, empty tokens)
        let url = ExternalAgentConfigStore.configURL(in: dir)
        try Data("{corrupt json".utf8).write(to: url)
        let corrupt = ExternalAgentConfigStore.load(in: dir)
        #expect(corrupt.mcpEnabled == false)
        #expect(corrupt.httpMCPEnabled == false)
        #expect(corrupt.allowRemoteHTTPMCP == false)
        #expect(corrupt.accessLevel == .readOnly)
        #expect(corrupt.tokens.isEmpty)
    }

    @Test("MCP v2 JSON-RPC suppresses replies to id-less notifications, returns -32602 for unknown tools, -32001 when disabled, and rejects retired output_path")
    func mcpJsonRpcComplianceAndOutputPathBoundary() async throws {
        let dir = try BackendFixture.directory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let appSupport = dir.appending(path: "AppSupport", directoryHint: .isDirectory)
        let engine = try LiveCharkleEngine.make(appSupportDirectory: appSupport, startAutoSync: false)
        let service = CharkleExternalAgentService(engine: engine, configDirectory: appSupport, notifyOnWrite: false)

        let png = try BackendFixture.artwork("#C86D51")
        let assets = try await engine.ingest([.imageData(png, suggestedName: "Warm.png", sourceURL: nil)], targetFolderID: nil, targetBoardID: nil)
        let firstAsset = try #require(assets.first)
        let board = try await engine.saveBoard(MoodboardDocument(title: "Audit Board", nodes: MoodboardCurator.editorialNodes([firstAsset])))

        func sendRPC(_ obj: Any) async throws -> [String: Any]? {
            let data = try JSONSerialization.data(withJSONObject: obj)
            guard let reply = await service.handleJSONRPC(data) else { return nil }
            return try JSONSerialization.jsonObject(with: reply) as? [String: Any]
        }

        // 1. Notifications without `id` MUST receive no reply (even for `ping` and `logging/setLevel`)
        #expect(try await sendRPC(["jsonrpc": "2.0", "method": "ping"]) == nil)
        #expect(try await sendRPC(["jsonrpc": "2.0", "method": "logging/setLevel", "params": ["level": "info"]]) == nil)

        // Explicit `"id": null` IS a request and receives a response
        let nullIDReply = try #require(try await sendRPC(["jsonrpc": "2.0", "id": NSNull(), "method": "ping"]))
        #expect(nullIDReply["result"] != nil)

        // 2. Unknown tool via JSON-RPC `tools/call` must return -32602
        let unknownResp = try #require(try await sendRPC([
            "jsonrpc": "2.0",
            "id": 2,
            "method": "tools/call",
            "params": ["name": "nonexistent_tool", "arguments": [:]]
        ]))
        let unknownErr = try #require(unknownResp["error"] as? [String: Any])
        #expect(unknownErr["code"] as? Int == -32602)

        // 3. Retired disk-write `output_path` MUST be rejected in EVERY access level (images are inline MCP blocks only)
        try ExternalAgentConfigStore.save(ExternalAgentConfig(enabled: true, accessLevel: .readWriteOrganize), in: appSupport)
        let blockedSheetPath = dir.appending(path: "sheet.jpg").path
        let roSheetOut = await service.callTool(name: "query_assets", arguments: ["only_inbox": true, "contact_sheet": true, "output_path": blockedSheetPath])
        #expect(roSheetOut.isError == true)
        #expect(!FileManager.default.fileExists(atPath: blockedSheetPath))

        let blockedBoardPath = dir.appending(path: "board.png").path
        let roBoardOut = await service.callTool(name: "get_board", arguments: ["board_id": board.id.uuidString, "include_snapshot": true, "output_path": blockedBoardPath])
        #expect(roBoardOut.isError == true)
        #expect(!FileManager.default.fileExists(atPath: blockedBoardPath))

        // 4. `ingest_assets` validates malformed `web_urls` cleanly
        let badURLOut = await service.callTool(name: "ingest_assets", arguments: ["web_urls": ["not-a-url"]])
        #expect(badURLOut.isError == true)

        // 5. Disabled stdio MCP returns JSON-RPC error -32001 on `tools/call`
        try ExternalAgentConfigStore.save(ExternalAgentConfig(mcpEnabled: false, httpMCPEnabled: true, accessLevel: .readOnly), in: appSupport)
        let disabledResp = try #require(try await sendRPC([
            "jsonrpc": "2.0",
            "id": 3,
            "method": "tools/call",
            "params": ["name": "library_overview", "arguments": [:]]
        ]))
        let disabledErr = try #require(disabledResp["error"] as? [String: Any])
        #expect(disabledErr["code"] as? Int == -32001)
    }

    // MARK: - 3. WebDAVTransport Hardening

    @Test("WebDAV PROPFIND parses fractional ISO-8601 dates and ignores trailing 404 propstats")
    func webdavPropfindFractionalDateAnd404Propstat() throws {
        let xml = """
        <?xml version="1.0" encoding="utf-8"?>
        <D:multistatus xmlns:D="DAV:">
          <D:response>
            <D:href>/dav/Charkle/shot.png</D:href>
            <D:propstat>
              <D:status>HTTP/1.1 200 OK</D:status>
              <D:prop>
                <D:resourcetype/>
                <D:getcontentlength>8192</D:getcontentlength>
                <D:getcontenttype>image/png</D:getcontenttype>
                <D:getlastmodified>2026-11-22T07:10:00.456Z</D:getlastmodified>
              </D:prop>
            </D:propstat>
            <D:propstat>
              <D:status>HTTP/1.1 404 Not Found</D:status>
              <D:prop>
                <D:getlastmodified/>
                <D:getcontentlength/>
                <D:getcontenttype/>
              </D:prop>
            </D:propstat>
          </D:response>
        </D:multistatus>
        """
        let baseURL = try #require(URL(string: "https://webdav-audit.test/dav/"))
        let files = try WebDAVTransport.parsePropfindResponse(
            Data(xml.utf8),
            baseURL: baseURL,
            directoryRelPath: "Charkle",
            parentID: "Charkle"
        )
        let file = try #require(files.first)
        #expect(file.name == "shot.png")
        #expect(file.size == 8192)
        #expect(file.mimeType == "image/png")
        let expected = try Date.ISO8601FormatStyle(includingFractionalSeconds: true).parse("2026-11-22T07:10:00.456Z")
        let modified = try #require(file.modifiedTime)
        #expect(abs(modified.timeIntervalSince(expected)) < 0.01)
    }

    @Test("WebDAVTransport enforces If-None-Match on new PUT, Overwrite: F + trailing slash on folder MOVE, and retries 429")
    func webdavTransportHeadersAndRetry() async throws {
        AuditWebDAVMockProtocol.reset()
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [AuditWebDAVMockProtocol.self]
        let session = URLSession(configuration: config)

        let transport = try WebDAVTransport(
            serverURL: "https://webdav-audit.test/dav/",
            username: "tester",
            password: "secret",
            remotePath: "/Charkle",
            session: session
        )

        // 1. New PUT sends `If-None-Match: *` and maps 412 -> `.fileAlreadyExists`
        let putConflict = await #expect(throws: DriveTransportError.self) {
            _ = try await transport.uploadData(
                Data("hello".utf8),
                name: "conflict.png",
                mimeType: "image/png",
                parentID: "Charkle/Inbox",
                existingFileID: nil
            )
        }
        if case .fileAlreadyExists(let name) = putConflict {
            #expect(name == "conflict.png")
        } else {
            Issue.record("Expected .fileAlreadyExists for HTTP 412 PUT")
        }
        #expect(AuditWebDAVMockProtocol.lastIfNoneMatch == "*")

        // 2. Folder creation registers folder ID, and folder MOVE sends trailing slashes + `Overwrite: F`
        let folder = try await transport.findOrCreateFolder(named: "OldName", parentID: "Charkle")
        let moved = try await transport.moveFile(
            fileID: folder.id,
            fromParentID: "Charkle",
            toParentID: "Charkle",
            newName: "NewName"
        )
        #expect(moved.mimeType == RemoteDriveFile.folderMimeType)
        #expect(moved.id == "Charkle/NewName")
        #expect(AuditWebDAVMockProtocol.lastMoveOverwrite == "F")
        #expect(AuditWebDAVMockProtocol.lastMoveSourceURL?.hasSuffix("/") == true)
        #expect(AuditWebDAVMockProtocol.lastMoveDestination?.hasSuffix("/") == true)

        // 3. Transient 429 retries and succeeds
        AuditWebDAVMockProtocol.fail429Count = 1
        let ok = try await transport.uploadData(
            Data("retry-ok".utf8),
            name: "retry.png",
            mimeType: "image/png",
            parentID: "Charkle/Inbox",
            existingFileID: nil
        )
        #expect(ok.name == "retry.png")
        #expect(AuditWebDAVMockProtocol.retryAttempts >= 2)
    }

    // MARK: - 4. MountedVolumeTransport Hardening

    @Test("MountedVolumeTransport allows symlinked parent root in local mode, rejects internal symlinks, overwrites atomically, and deletes directly")
    func mountedVolumeHardening() async throws {
        let dir = try BackendFixture.directory()
        defer { try? FileManager.default.removeItem(at: dir) }

        let realMount = dir.appending(path: "RealMount", directoryHint: .isDirectory)
        let realLibrary = realMount.appending(path: "Charkle", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: realLibrary, withIntermediateDirectories: true)

        let symlinkMount = dir.appending(path: "SymlinkMount")
        try FileManager.default.createSymbolicLink(at: symlinkMount, withDestinationURL: realMount)

        let transport = MountedVolumeTransport(
            mountPath: symlinkMount.path,
            rootFolderName: "Charkle",
            requireDedicatedMount: false
        )

        // 1. Symlinked parent root works for folder creation and upload
        let root = try await transport.findOrCreateFolder(named: "Charkle", parentID: DriveFiles.rootID)
        let inbox = try await transport.findOrCreateFolder(named: "Inbox", parentID: root.id)
        let uploaded = try await transport.uploadData(
            Data("v1".utf8),
            name: "sample.txt",
            mimeType: "text/plain",
            parentID: inbox.id,
            existingFileID: nil
        )

        // 2. Overwrite existing file atomically with no leftover temp scratch files
        let overwritten = try await transport.uploadData(
            Data("version-two".utf8),
            name: "sample.txt",
            mimeType: "text/plain",
            parentID: inbox.id,
            existingFileID: uploaded.id
        )
        let downloaded = try await transport.downloadData(fileID: overwritten.id)
        #expect(downloaded == Data("version-two".utf8))
        let inboxEntries = try FileManager.default.contentsOfDirectory(atPath: realLibrary.appending(path: "Inbox").path)
        #expect(!inboxEntries.contains(where: { $0.hasPrefix(".charkle-write-") }))

        // 3. Symlink INSIDE the library is still rejected
        let evilTarget = dir.appending(path: "outside.txt")
        try Data("secret".utf8).write(to: evilTarget)
        let internalLink = realLibrary.appending(path: "Inbox/escape.txt")
        try FileManager.default.createSymbolicLink(at: internalLink, withDestinationURL: evilTarget)
        await #expect(throws: DriveTransportError.self) {
            _ = try await transport.downloadData(fileID: MountedVolumeTransport.pathIDPrefix + "Charkle/Inbox/escape.txt")
        }

        // 4. `trashFile` in local-folder mode (`requireDedicatedMount == false`) deletes directly without filling `.charkle/trash`
        try await transport.trashFile(fileID: overwritten.id)
        #expect(!FileManager.default.fileExists(atPath: realLibrary.appending(path: "Inbox/sample.txt").path))
        let trashDir = realLibrary.appending(path: ".charkle/trash")
        #expect(!FileManager.default.fileExists(atPath: trashDir.path))
    }

    // MARK: - 5. DriveSyncEngine & SyncOperations Data Safety

    @Test("Migration requeue clears stale driveFileID on trashed assets, path-based folder rename rewrites child IDs, living remote thumbnails are preserved, and corrupt embedding shards recover")
    func syncEngineAndMigrationSafety() async throws {
        let dir = try BackendFixture.directory()
        defer { try? FileManager.default.removeItem(at: dir) }

        let mountRoot = dir.appending(path: "Mount", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: mountRoot, withIntermediateDirectories: true)
        let appSupport = dir.appending(path: "AppSupport", directoryHint: .isDirectory)
        let media = try MediaPipeline(directory: appSupport)
        let db = try LibraryDatabase(url: appSupport.appending(path: "Library.sqlite3"))
        let transport = MountedVolumeTransport(mountPath: mountRoot.path, rootFolderName: "Charkle", requireDedicatedMount: false)
        let engine = LiveCharkleEngine(database: db, media: media, transport: transport)
        let syncCfg = DriveSyncConfig(
            mode: .localOnly,
            rootFolderName: "Charkle",
            localLibraryPath: mountRoot.appending(path: "Charkle").path,
            syncThumbnails: true,
            syncEmbeddings: true
        )
        try await engine.saveSyncConfig(syncCfg)

        // 1. Create folder + asset and sync -> pendingOpCount drops to 0 on first sync
        let folder = try await engine.createFolder(name: "References", parentID: nil)
        let png = try BackendFixture.artwork("#2A6F97")
        let imported = try await engine.ingest([.imageData(png, suggestedName: "Blue.png", sourceURL: nil)], targetFolderID: folder.id, targetBoardID: nil)
        let asset = try #require(imported.first)
        _ = try await engine.syncNow()

        let statusAfterFirst = await engine.syncStatus()
        #expect(statusAfterFirst.pendingOpCount == 0)
        let syncedAsset = try #require(await engine.fetchAsset(id: asset.id))
        #expect(syncedAsset.driveFileID?.contains("Charkle/References/") == true)

        // 2. Rename folder on path-based transport -> child asset `driveFileID` rewrites cleanly without duplication
        _ = try await engine.renameFolder(id: folder.id, newName: "Archive")
        _ = try await engine.syncNow()
        let renamedAsset = try #require(await engine.fetchAsset(id: asset.id))
        #expect(renamedAsset.driveFileID?.contains("Charkle/Archive/") == true)
        let allAssetsAfterRename = try await engine.fetchAssets(matching: FilterCriteria(includeTrashed: false))
        #expect(allAssetsAfterRename.count == 1)

        // 3. Living asset missing local thumbnail must NOT delete remote thumbnail
        let remoteThumbFile = mountRoot.appending(path: "Charkle/.charkle/thumbnails/\(asset.id.uuidString.lowercased()).jpg")
        #expect(FileManager.default.fileExists(atPath: remoteThumbFile.path))
        let localThumb = media.thumbnailURL(for: asset.id, tier: .grid520)
        if let localThumb {
            try? FileManager.default.removeItem(at: localThumb)
        }
        try await db.transaction { store in
            try store.markProjection("thumbnails", id: asset.id)
        }
        _ = try await engine.syncNow()
        #expect(FileManager.default.fileExists(atPath: remoteThumbFile.path))

        // 4. Corrupt remote embedding shard recovers cleanly from local vectors
        try await db.transaction { store in
            try store.saveVector(
                AssetVector(featurePrint: nil, embedding: [0.1, 0.2, 0.3], embeddingModel: "test", precision: .float16),
                for: asset.id
            )
            try store.markProjection("embeddings", id: asset.id)
        }
        let embDir = mountRoot.appending(path: "Charkle/.charkle/embeddings", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: embDir, withIntermediateDirectories: true)
        let shardPrefix = String(asset.id.uuidString.lowercased().prefix(2))
        let corruptShardURL = embDir.appending(path: "shard-\(shardPrefix).bin")
        try Data("NOT-A-VALID-PLIST-CORRUPT".utf8).write(to: corruptShardURL)
        _ = try await engine.syncNow()
        let repairedData = try Data(contentsOf: corruptShardURL)
        let repairedPlist = try #require(
            try PropertyListSerialization.propertyList(from: repairedData, format: nil) as? [String: Any]
        )
        #expect(repairedPlist[asset.id.uuidString] != nil)

        // 5. Requeue for migration clears stale `driveFileID` on trashed assets too
        _ = try await engine.updateAssets(AssetBatchPatch(assetIDs: [asset.id], isTrashed: true))
        let trashedBefore = try #require(await engine.fetchAsset(id: asset.id))
        #expect(trashedBefore.driveFileID != nil)
        _ = try await db.transaction { store in
            try store.requeueLibraryForBackendMigration(syncThumbnails: true, syncEmbeddings: false)
        }
        let trashedAfter = try #require(await engine.fetchAsset(id: asset.id))
        #expect(trashedAfter.driveFileID == nil)
    }

    // MARK: - 6. CloudAIProvider Hardening

    @Test("CloudAIProvider trims baseURL, retries 429, surfaces provider error details, strips <think> & extracts balanced JSON, and filters Responses/Anthropic output")
    func cloudAIProviderHardening() async throws {
        // 1. Caption parser strips <think>, handles braces in prose, and allows missing `tags`
        let rawCaption = """
        <think>Let me analyze {some draft} before answering {"description": "ignored inside think"}.</think>
        Here is the structured output {note: clean}:
        {"description": "暖陶土色极简建筑海报"}
        """
        let parsed = try AIHTTPClient.caption(rawCaption)
        #expect(parsed.description == "暖陶土色极简建筑海报")
        #expect(parsed.tags.isEmpty)

        // 2. OpenAI Responses provider trims baseURL, retries 429, and ignores reasoning output items
        AuditAIMockProtocol.reset()
        AuditAIMockProtocol.fail429Count = 1
        let cfg = URLSessionConfiguration.ephemeral
        cfg.protocolClasses = [AuditAIMockProtocol.self]
        let session = URLSession(configuration: cfg)

        let responsesCfg = AIProviderConfig(
            provider: .openAICompatible,
            customEndpointFormat: .openAIResponses,
            baseURL: "  https://ai-audit.test  ",
            chatModel: "  gpt-4.1-mini  ",
            embeddingModel: ""
        )
        let responsesProvider = try OpenAIResponsesProvider(config: responsesCfg, apiKey: "sk-test", session: session)
        let resText = try await responsesProvider.completeJSON(instructions: "sys", prompt: "hello", imagesJPEG: [])
        #expect(resText == #"{"ok":true}"#)
        #expect(AuditAIMockProtocol.requestCount >= 2)

        // 3. Anthropic Messages provider ignores `thinking` blocks and keeps only `text` blocks
        let anthropicCfg = AIProviderConfig(
            provider: .openAICompatible,
            customEndpointFormat: .anthropicMessages,
            baseURL: "https://ai-audit.test",
            chatModel: "claude-sonnet-4-5",
            embeddingModel: ""
        )
        let anthropicProvider = try AnthropicMessagesProvider(config: anthropicCfg, apiKey: "sk-ant-test", session: session)
        let antText = try await anthropicProvider.completeJSON(instructions: "sys", prompt: "hello", imagesJPEG: [])
        #expect(antText == #"{"anthropic":true}"#)

        // 4. Provider 400 error surfaces JSON `error.message`
        AuditAIMockProtocol.forceStatus = 400
        let err = await #expect(throws: LibraryDatabaseError.self) {
            _ = try await responsesProvider.completeJSON(instructions: "", prompt: "boom", imagesJPEG: [])
        }
        #expect(err?.localizedDescription.contains("invalid model parameter") == true)
    }

    // MARK: - 7. ChatGPTSignInClient OIDC Clock Skew Tolerance

    @Test("ChatGPTSignInClient RS256 ID token verification tolerates 30s clock skew and rejects 120s skew")
    func chatGPTClockSkewTolerance() throws {
        let keyParams: [String: Any] = [
            kSecAttrKeyType as String: kSecAttrKeyTypeRSA,
            kSecAttrKeySizeInBits as String: 2048
        ]
        var cfError: Unmanaged<CFError>?
        let privateKey = try #require(SecKeyCreateRandomKey(keyParams as CFDictionary, &cfError))
        let publicKey = try #require(SecKeyCopyPublicKey(privateKey))
        let pkcs1DER = try #require(SecKeyCopyExternalRepresentation(publicKey, &cfError) as Data?)
        let (modulus, exponent) = try parsePKCS1RSAPublicKey(pkcs1DER)
        let jwk = ChatGPTSignInClient.JWKKey(
            kty: "RSA",
            kid: "skew-key",
            alg: "RS256",
            n: ChatGPTSignInClient.base64URLEncode(modulus),
            e: ChatGPTSignInClient.base64URLEncode(exponent)
        )

        func signToken(iatOffset: TimeInterval, now: Date) throws -> String {
            let headerB64 = ChatGPTSignInClient.base64URLEncode(
                try JSONSerialization.data(withJSONObject: ["alg": "RS256", "kid": "skew-key", "typ": "JWT"])
            )
            let payloadObj: [String: Any] = [
                "iss": ChatGPTSignInClient.issuer,
                "sub": "user-skew-1",
                "aud": "client_skew",
                "nonce": "nonce_skew",
                "iat": Int(now.timeIntervalSince1970 + iatOffset),
                "exp": Int(now.timeIntervalSince1970 + 3600)
            ]
            let payloadB64 = ChatGPTSignInClient.base64URLEncode(try JSONSerialization.data(withJSONObject: payloadObj))
            let signingInput = Data("\(headerB64).\(payloadB64)".utf8)
            let sig = try #require(
                SecKeyCreateSignature(privateKey, .rsaSignatureMessagePKCS1v15SHA256, signingInput as CFData, &cfError) as Data?
            )
            return "\(headerB64).\(payloadB64).\(ChatGPTSignInClient.base64URLEncode(sig))"
        }

        let now = Date()
        // +30s future `iat` is within the 60s tolerance -> succeeds
        let mildSkewJWT = try signToken(iatOffset: 30, now: now)
        let verified = try ChatGPTSignInClient.verifyRS256IDToken(
            mildSkewJWT,
            keys: [jwk],
            expectedIssuer: ChatGPTSignInClient.issuer,
            expectedClientID: "client_skew",
            expectedNonce: "nonce_skew",
            referenceDate: now
        )
        #expect(verified.subject == "user-skew-1")

        // +120s future `iat` exceeds 60s tolerance -> rejected
        let severeSkewJWT = try signToken(iatOffset: 120, now: now)
        #expect(throws: ChatGPTAuthError.self) {
            _ = try ChatGPTSignInClient.verifyRS256IDToken(
                severeSkewJWT,
                keys: [jwk],
                expectedIssuer: ChatGPTSignInClient.issuer,
                expectedClientID: "client_skew",
                expectedNonce: "nonce_skew",
                referenceDate: now
            )
        }
    }

    private func parsePKCS1RSAPublicKey(_ der: Data) throws -> (Data, Data) {
        let bytes = Array(der)
        var idx = 0
        func readLength() throws -> Int {
            guard idx < bytes.count else { throw LibraryDatabaseError("DER truncated") }
            let first = Int(bytes[idx]); idx += 1
            if first < 0x80 { return first }
            let count = first & 0x7F
            var val = 0
            for _ in 0..<count {
                guard idx < bytes.count else { throw LibraryDatabaseError("DER length truncated") }
                val = (val << 8) | Int(bytes[idx]); idx += 1
            }
            return val
        }
        guard bytes.first == 0x30 else { throw LibraryDatabaseError("Expected SEQUENCE") }
        idx += 1
        _ = try readLength()

        func readInteger() throws -> Data {
            guard idx < bytes.count, bytes[idx] == 0x02 else { throw LibraryDatabaseError("Expected INTEGER") }
            idx += 1
            let len = try readLength()
            var slice = Array(bytes[idx..<(idx + len)])
            idx += len
            while slice.count > 1 && slice.first == 0x00 { slice.removeFirst() }
            return Data(slice)
        }
        return (try readInteger(), try readInteger())
    }
}

// MARK: - Isolated URLProtocol Fixtures

private final class AuditWebDAVMockProtocol: URLProtocol, @unchecked Sendable {
    private final class State: @unchecked Sendable {
        let lock = NSLock()
        var lastIfNoneMatch: String?
        var lastMoveOverwrite: String?
        var lastMoveSourceURL: String?
        var lastMoveDestination: String?
        var fail429Count: Int = 0
        var retryAttempts: Int = 0
    }

    private static let state = State()

    static var lastIfNoneMatch: String? { state.lock.withLock { state.lastIfNoneMatch } }
    static var lastMoveOverwrite: String? { state.lock.withLock { state.lastMoveOverwrite } }
    static var lastMoveSourceURL: String? { state.lock.withLock { state.lastMoveSourceURL } }
    static var lastMoveDestination: String? { state.lock.withLock { state.lastMoveDestination } }
    static var fail429Count: Int {
        get { state.lock.withLock { state.fail429Count } }
        set { state.lock.withLock { state.fail429Count = newValue } }
    }
    static var retryAttempts: Int { state.lock.withLock { state.retryAttempts } }

    static func reset() {
        state.lock.withLock {
            state.lastIfNoneMatch = nil
            state.lastMoveOverwrite = nil
            state.lastMoveSourceURL = nil
            state.lastMoveDestination = nil
            state.fail429Count = 0
            state.retryAttempts = 0
        }
    }

    override class func canInit(with request: URLRequest) -> Bool {
        request.url?.host() == "webdav-audit.test"
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func stopLoading() {}

    override func startLoading() {
        guard let url = request.url else {
            client?.urlProtocol(self, didFailWithError: URLError(.badURL))
            return
        }
        let method = request.httpMethod ?? "GET"
        var status = 200
        var headers: [String: String] = [:]
        let body = Data()

        switch method {
        case "MKCOL":
            status = 201
        case "PUT":
            if url.lastPathComponent == "conflict.png" {
                Self.state.lock.withLock { Self.state.lastIfNoneMatch = request.value(forHTTPHeaderField: "If-None-Match") }
                status = 412
            } else if url.lastPathComponent == "retry.png" {
                let should429: Bool = Self.state.lock.withLock {
                    Self.state.retryAttempts += 1
                    if Self.state.fail429Count > 0 {
                        Self.state.fail429Count -= 1
                        return true
                    }
                    return false
                }
                if should429 {
                    status = 429
                    headers["Retry-After"] = "0.2"
                } else {
                    status = 201
                }
            } else {
                status = 201
            }
        case "MOVE":
            Self.state.lock.withLock {
                Self.state.lastMoveOverwrite = request.value(forHTTPHeaderField: "Overwrite")
                Self.state.lastMoveSourceURL = url.absoluteString
                Self.state.lastMoveDestination = request.value(forHTTPHeaderField: "Destination")
            }
            status = 201
        default:
            status = 200
        }

        guard let response = HTTPURLResponse(url: url, statusCode: status, httpVersion: "HTTP/1.1", headerFields: headers) else {
            client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
            return
        }
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        if !body.isEmpty {
            client?.urlProtocol(self, didLoad: body)
        }
        client?.urlProtocolDidFinishLoading(self)
    }
}

private final class AuditAIMockProtocol: URLProtocol, @unchecked Sendable {
    private final class State: @unchecked Sendable {
        let lock = NSLock()
        var fail429Count = 0
        var requestCount = 0
        var forceStatus: Int? = nil
    }

    private static let state = State()

    static var fail429Count: Int {
        get { state.lock.withLock { state.fail429Count } }
        set { state.lock.withLock { state.fail429Count = newValue } }
    }
    static var requestCount: Int { state.lock.withLock { state.requestCount } }
    static var forceStatus: Int? {
        get { state.lock.withLock { state.forceStatus } }
        set { state.lock.withLock { state.forceStatus = newValue } }
    }

    static func reset() {
        state.lock.withLock {
            state.fail429Count = 0
            state.requestCount = 0
            state.forceStatus = nil
        }
    }

    override class func canInit(with request: URLRequest) -> Bool {
        request.url?.host() == "ai-audit.test"
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func stopLoading() {}

    override func startLoading() {
        guard let url = request.url else {
            client?.urlProtocol(self, didFailWithError: URLError(.badURL))
            return
        }

        let (forced, should429): (Int?, Bool) = Self.state.lock.withLock {
            Self.state.requestCount += 1
            if let f = Self.state.forceStatus { return (f, false) }
            if Self.state.fail429Count > 0 {
                Self.state.fail429Count -= 1
                return (nil, true)
            }
            return (nil, false)
        }

        var status = 200
        var headers = ["Content-Type": "application/json"]
        let payload: String

        if let forced {
            status = forced
            payload = #"{"error":{"message":"invalid model parameter"}}"#
        } else if should429 {
            status = 429
            headers["Retry-After"] = "0.25"
            payload = #"{"error":{"message":"rate limit"}}"#
        } else if url.path.hasSuffix("/responses") {
            payload = """
            {
              "output": [
                {"type": "reasoning", "content": [{"type": "summary_text", "text": "internal thought"}]},
                {"type": "message", "content": [{"type": "output_text", "text": "{\\"ok\\":true}"}]}
              ],
              "usage": {"input_tokens": 10, "output_tokens": 5, "total_tokens": 15}
            }
            """
        } else if url.path.hasSuffix("/messages") {
            payload = """
            {
              "content": [
                {"type": "thinking", "text": "internal reasoning"},
                {"type": "text", "text": "{\\"anthropic\\":true}"}
              ],
              "usage": {"input_tokens": 12, "output_tokens": 6}
            }
            """
        } else {
            status = 404
            payload = #"{"error":{"message":"not found"}}"#
        }

        guard let response = HTTPURLResponse(url: url, statusCode: status, httpVersion: "HTTP/1.1", headerFields: headers) else {
            client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
            return
        }
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(payload.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }
}
