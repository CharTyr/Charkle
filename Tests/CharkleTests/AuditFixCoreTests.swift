import Darwin
import Foundation
import Testing
@testable import CharkleCore

@Suite("Core Audit Regression Fixes")
struct AuditFixCoreTests {

    @Test("Cache eviction never deletes originals in localOnly mode even with prior driveFileID")
    func cacheEvictionRefusesLocalOnlyDataLoss() async throws {
        let dir = try BackendFixture.directory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let transport = InMemoryDriveTransport()
        let engine = try BackendFixture.makeEngine(dir, transport: transport)
        try await engine.saveSyncConfig(BackendFixture.syncConfig())

        let assets = try await engine.ingest([
            .colorSwatch(hex: "#336699", title: "Local Safe")
        ], targetFolderID: nil, targetBoardID: nil)
        let assetID = try #require(assets.first?.id)
        _ = try await engine.syncNow()

        let synced = try #require(try await engine.fetchAsset(id: assetID))
        #expect(synced.driveFileID != nil)
        let originalPath = try await engine.originalURL(for: assetID)
        #expect(FileManager.default.fileExists(atPath: originalPath.path))

        // Switch to local-only mode without migrating; eviction must never delete the only local copy.
        try await engine.saveSyncConfig(DriveSyncConfig(mode: .localOnly, syncEmbeddings: false))
        await engine.setCacheBudgetBytes(0)
        _ = try await engine.evictCacheNow()

        #expect(FileManager.default.fileExists(atPath: originalPath.path))
        #expect(try await engine.fetchAsset(id: assetID)?.isLocalOriginalCached == true)
    }

    @Test("Non-ASCII case-variant tags merge cleanly and emoji/symbol search filters strictly")
    func unicodeTagFoldingAndSymbolSearch() async throws {
        let db = try LibraryDatabase()
        let fire = AssetRecord(title: "Sunset 🔥", fileName: "fire.png", notes: "warm glow", tags: ["Über"])
        let grid = AssetRecord(title: "Minimal Grid", fileName: "grid.png", notes: "divider --- line", tags: ["über"])
        try await db.upsertAssets([fire, grid])

        let counts = try await db.fetchTagCounts()
        #expect(counts.count == 1)
        #expect(counts.first?.count == 2)
        // Must never trap on duplicate lowercased keys.
        let lowerMap = Dictionary(uniqueKeysWithValues: counts.map { ($0.name.lowercased(), $0) })
        #expect(lowerMap["über"]?.count == 2)

        let fireMatches = try await db.fetchAssets(matching: FilterCriteria(searchQuery: "🔥"))
        #expect(fireMatches.map(\.id) == [fire.id])

        let dashMatches = try await db.fetchAssets(matching: FilterCriteria(searchQuery: "---"))
        #expect(dashMatches.map(\.id) == [grid.id])

        let missingMatches = try await db.fetchAssets(matching: FilterCriteria(searchQuery: "🎨🎨🎨"))
        #expect(missingMatches.isEmpty)

        let jumpMatches = try await db.quickJump(query: "🔥", limit: 10)
        #expect(jumpMatches.map(\.targetUUID) == [fire.id])
    }

    @Test("clearMigrationSyncState clears stale driveFileID on trashed assets")
    func migrationClearsTrashedDriveFileID() async throws {
        let db = try LibraryDatabase()
        let trashed = AssetRecord(
            title: "Trashed Cloud File",
            fileName: "old.png",
            driveFileID: "remote-old-id",
            isTrashed: true
        )
        try await db.upsertAssets([trashed])
        try await db.clearMigrationSyncState()
        let reloaded = try #require(try await db.asset(id: trashed.id))
        #expect(reloaded.driveFileID == nil)
    }

    @Test("Long filenames preserve extension and extensionless files named after formats do not misparse")
    func longFilenamePreservesExtensionAndExtensionlessSafe() async throws {
        let longName = String(repeating: "a", count: 160) + ".png"
        let cleaned = MediaPipeline.cleanFileName(longName)
        #expect(cleaned.count <= 140)
        #expect(cleaned.hasSuffix(".png"))

        let dir = try BackendFixture.directory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let engine = try BackendFixture.makeEngine(dir)

        let pngData = try BackendFixture.artwork("#225588")
        let longFile = dir.appending(path: String(repeating: "b", count: 150) + ".png")
        try pngData.write(to: longFile)
        let longImported = try await engine.ingest([.fileURL(longFile)], targetFolderID: nil, targetBoardID: nil)
        let longAsset = try #require(longImported.first)
        #expect(longAsset.mediaKind == .image)
        #expect(longAsset.fileName.hasSuffix(".png"))

        let extensionless = dir.appending(path: "pdf")
        try Data("plain notes without pdf header".utf8).write(to: extensionless)
        let extlessImported = try await engine.ingest([.fileURL(extensionless)], targetFolderID: nil, targetBoardID: nil)
        #expect(extlessImported.first?.fileName == "pdf")
    }

    @Test("Numeric parsers, SVGPreview, and canonicalURL resist malformed/extreme inputs without crashing")
    func numericBoundsAndSafeParsers() async throws {
        #expect(XiaohongshuPostResolver.parseChineseMetricCount("infk") == nil)
        #expect(XiaohongshuPostResolver.parseChineseMetricCount("nan万") == nil)
        #expect(XiaohongshuPostResolver.parseChineseMetricCount("1e30w") == nil)
        #expect(XiaohongshuPostResolver.parseChineseMetricCount("-5万") == nil)
        #expect(XiaohongshuPostResolver.parseChineseMetricCount("1.5万") == 15_000)

        #expect(ImageMetadataExtractor.formatExposureTime(1e-30) == nil)
        #expect(ImageMetadataExtractor.formatExposureTime(1e20) == nil)
        #expect(ImageMetadataExtractor.formatExposureTime(0.004) == "1/250s")

        #expect(XPostURLParser.parse(try #require(URL(string: "https://x.com/user/status/１２３４５"))) == nil)
        #expect(XPostURLParser.parse(try #require(URL(string: "https://x.com/user/status/1234567890")))?.tweetID == "1234567890")

        let ghURL = GitHubRepoReference(owner: "bad owner", repo: "bad repo").canonicalURL
        #expect(ghURL.host() == "github.com")
        let xURL = XPostReference(handle: "bad handle", tweetID: "123").canonicalURL
        #expect(xURL.host() == "x.com")

        let dir = try BackendFixture.directory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let badSVG = dir.appending(path: "subnormal.svg")
        try Data(#"<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 1e-320 1"><rect width="1" height="1"/></svg>"#.utf8).write(to: badSVG)
        #expect(SVGPreview.render(badSVG) == nil)
        let badSVG2 = dir.appending(path: "subnormal-both.svg")
        try Data(#"<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 1e-320 1e-320"><rect width="1" height="1"/></svg>"#.utf8).write(to: badSVG2)
        #expect(SVGPreview.render(badSVG2) == nil)
    }

    @Test("ImageMetadataExtractor streams past >2MB IDAT to read trailing PNG tEXt AI parameters")
    func trailingPNGChunkBeyondTwoMegabytes() async throws {
        let dir = try BackendFixture.directory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let fileURL = dir.appending(path: "large-trailing.png")

        func makeChunk(type: String, payload: Data) -> Data {
            var out = Data()
            var len = UInt32(payload.count).bigEndian
            withUnsafeBytes(of: &len) { out.append(contentsOf: $0) }
            out.append(contentsOf: type.utf8)
            out.append(payload)
            out.append(contentsOf: [0, 0, 0, 0]) // dummy CRC (not checked by chunk scanner)
            return out
        }

        var png = Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A])
        png.append(makeChunk(type: "IHDR", payload: Data(repeating: 0, count: 13)))
        png.append(makeChunk(type: "IDAT", payload: Data(repeating: 0xAA, count: 2_200_000)))
        var textPayload = Data("parameters".utf8)
        textPayload.append(0)
        textPayload.append(Data("masterpiece, cyber cat\nSteps: 28, Sampler: Euler a, CFG scale: 7, Seed: 42".utf8))
        png.append(makeChunk(type: "tEXt", payload: textPayload))
        png.append(makeChunk(type: "IEND", payload: Data()))
        try png.write(to: fileURL)

        let extracted = ImageMetadataExtractor.extract(from: fileURL)
        #expect(extracted.aiGeneration?.steps == 28)
        #expect(extracted.aiGeneration?.prompt == "masterpiece, cyber cat")
        #expect(extracted.aiGeneration?.seed == "42")
    }

    @Test("WebBookmark SSRF guard blocks loopback, link-local, RFC1918, and IPv4-mapped IPv6 targets")
    func webBookmarkSSRFGuard() throws {
        let blocked = [
            "http://127.0.0.1:41937/api/v1/health",
            "http://localhost:3000/",
            "http://sub.localhost/test",
            "http://169.254.169.254/latest/meta-data/",
            "http://10.0.0.1/admin",
            "http://172.16.0.5/",
            "http://192.168.1.1/",
            "http://[::1]:41937/",
            "http://[::ffff:127.0.0.1]/",
            "http://nas.local/webdav"
        ]
        for raw in blocked {
            let url = try #require(URL(string: raw))
            #expect(!WebBookmark.isSafeRemoteFetchURL(url), "Expected SSRF guard to block \(raw)")
        }
        let allowed = [
            "https://example.com/article",
            "https://github.com/apple/swift"
        ]
        for raw in allowed {
            let url = try #require(URL(string: raw))
            #expect(WebBookmark.isSafeRemoteFetchURL(url), "Expected SSRF guard to allow \(raw)")
        }
    }

    @Test("LocalExtensionBridgeServer enforces strict CORS, 403 Forbidden, chunked framing, UUID validation, and safe payloads")
    func bridgeSecurityAndHTTPFraming() async throws {
        let dir = try BackendFixture.directory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let engine = try BackendFixture.makeEngine(dir)

        let token = LocalExtensionBridgeServer.generateToken()
        let server = LocalExtensionBridgeServer(
            engine: engine,
            token: token,
            preferredPort: 0,
            allowEphemeralPort: true
        )
        let status = try await server.start()
        defer { Task { await server.stop() } }

        // 1. CORS prefix bypass rejected (`localhost.evil.com`, `127.0.0.1.nip.io`) while exact `localhost` allowed
        let evilCORS = try sendRawLoopbackHTTP(
            port: status.port,
            rawRequest: "OPTIONS /api/v1/health HTTP/1.1\r\nHost: 127.0.0.1\r\nOrigin: http://localhost.evil.com\r\n\r\n"
        )
        #expect(evilCORS.contains("HTTP/1.1 204 No Content"))
        #expect(!evilCORS.contains("Access-Control-Allow-Origin:"))

        let goodCORS = try sendRawLoopbackHTTP(
            port: status.port,
            rawRequest: "OPTIONS /api/v1/health HTTP/1.1\r\nHost: 127.0.0.1\r\nOrigin: http://localhost:3000\r\n\r\n"
        )
        #expect(goodCORS.contains("Access-Control-Allow-Origin: http://localhost:3000"))

        // 2. 403 returns proper "Forbidden" reason phrase
        let forbiddenResp = try sendRawLoopbackHTTP(
            port: status.port,
            rawRequest: "POST /api/v1/auth/local-pair HTTP/1.1\r\nHost: 127.0.0.1\r\nOrigin: https://evil.example\r\nX-Charkle-Extension: 1\r\nContent-Length: 0\r\n\r\n"
        )
        #expect(forbiddenResp.hasPrefix("HTTP/1.1 403 Forbidden\r\n"))

        // 3. Malformed negative Content-Length rejected with 400
        let badCL = try sendRawLoopbackHTTP(
            port: status.port,
            rawRequest: "POST /api/v1/folders HTTP/1.1\r\nHost: 127.0.0.1\r\nAuthorization: Bearer \(token)\r\nContent-Length: -5\r\n\r\n"
        )
        #expect(badCL.hasPrefix("HTTP/1.1 400 Bad Request\r\n"))

        // 4. Transfer-Encoding: chunked decodes cleanly and creates folder
        let chunkBody = #"{"name":"ChunkedFolder"}"#
        let hexLen = String(chunkBody.utf8.count, radix: 16)
        let chunkedReq = "POST /api/v1/folders HTTP/1.1\r\nHost: 127.0.0.1\r\nAuthorization: Bearer \(token)\r\nContent-Type: application/json\r\nTransfer-Encoding: chunked\r\n\r\n\(hexLen)\r\n\(chunkBody)\r\n0\r\n\r\n"
        let chunkedResp = try sendRawLoopbackHTTP(port: status.port, rawRequest: chunkedReq)
        #expect(chunkedResp.hasPrefix("HTTP/1.1 201 Created\r\n"))
        #expect(chunkedResp.contains("ChunkedFolder"))

        // 5. Malformed targetFolderID returns 400 instead of silently falling back to Inbox
        let session = URLSession(configuration: .ephemeral)
        defer { session.invalidateAndCancel() }
        var badFolderReq = URLRequest(url: try #require(URL(string: "\(status.baseURL)/api/v1/assets/ingest")))
        badFolderReq.httpMethod = "POST"
        badFolderReq.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        badFolderReq.setValue("application/json", forHTTPHeaderField: "Content-Type")
        badFolderReq.httpBody = try JSONSerialization.data(withJSONObject: [
            "targetFolderID": "not-a-valid-uuid",
            "inputs": [["type": "textSnippet", "title": "Test", "text": "Hello"]]
        ])
        let (_, badFolderResp) = try await session.data(for: badFolderReq)
        #expect((badFolderResp as? HTTPURLResponse)?.statusCode == 400)

        // 6. socialBookmark filters out `file://` attachments and resists `"infk"` metric counts without crashing
        let coverDataURL = "data:image/png;base64,iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8BQDwAEhQGAhKmMIQAAAABJRU5ErkJggg=="
        var safeSocialReq = URLRequest(url: try #require(URL(string: "\(status.baseURL)/api/v1/assets/ingest")))
        safeSocialReq.httpMethod = "POST"
        safeSocialReq.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        safeSocialReq.setValue("application/json", forHTTPHeaderField: "Content-Type")
        safeSocialReq.httpBody = try JSONSerialization.data(withJSONObject: [
            "inputs": [[
                "type": "socialBookmark",
                "platform": "xiaohongshu",
                "originalURL": "https://www.xiaohongshu.com/explore/77a1b2c3d4e5f60718293a4b",
                "authorName": "测试作者",
                "articleTitle": "安全校验笔记",
                "bodyText": "正文内容",
                "likeCount": "infk",
                "attachments": [
                    ["kind": "photo", "url": "file:///etc/passwd"]
                ],
                "coverDataUrl": coverDataURL
            ]]
        ])
        let (_, safeSocialResp) = try await session.data(for: safeSocialReq)
        #expect((safeSocialResp as? HTTPURLResponse)?.statusCode == 201)
        let savedAssets = try await engine.fetchAssets(matching: FilterCriteria())
        let savedPost = try #require(savedAssets.first?.richMetadata?.socialPost)
        #expect(savedPost.attachments.isEmpty)
        #expect(savedPost.likeCount == nil)

        // 7. AssetBatchPatch persists sourceURL & sourceDomain
        let targetID = try #require(savedAssets.first?.id)
        let patched = try await engine.updateAssets(AssetBatchPatch(
            assetIDs: [targetID],
            sourceURL: "https://www.example.org/post/1"
        ))
        #expect(patched.first?.sourceURL == "https://www.example.org/post/1")
        #expect(patched.first?.sourceDomain == "example.org")
    }

    private func sendRawLoopbackHTTP(port: UInt16, rawRequest: String) throws -> String {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        #expect(fd >= 0)
        defer { close(fd) }

        var tv = timeval(tv_sec: 5, tv_usec: 0)
        _ = setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
        _ = setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))

        var addr = sockaddr_in()
        addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = port.bigEndian
        _ = inet_pton(AF_INET, "127.0.0.1", &addr.sin_addr)

        let connectRC: Int32 = withUnsafePointer(to: &addr) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
                connect(fd, sa, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        #expect(connectRC == 0)

        let reqBytes = Array(rawRequest.utf8)
        var sent = 0
        while sent < reqBytes.count {
            let n = reqBytes.withUnsafeBytes { raw -> Int in
                guard let base = raw.baseAddress else { return -1 }
                return send(fd, base.advanced(by: sent), reqBytes.count - sent, 0)
            }
            if n <= 0 { break }
            sent += n
        }

        var responseData = Data()
        var chunk = [UInt8](repeating: 0, count: 4096)
        while true {
            let n = recv(fd, &chunk, chunk.count, 0)
            if n <= 0 { break }
            responseData.append(contentsOf: chunk[0..<n])
        }
        return String(decoding: responseData, as: UTF8.self)
    }
}
