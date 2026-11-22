@testable import CharkleCore
import Foundation
import Testing

@Suite("WebDAV, Multi-Format AI Endpoints, and Storage Migration")
struct MultiBackendAndAITests {
    @Test("WebDAV PROPFIND XML parser handles Nextcloud / Jianguoyun namespace prefixes and skips self")
    func parsesPropfindXML() throws {
        let xml = """
        <?xml version="1.0" encoding="utf-8"?>
        <D:multistatus xmlns:D="DAV:">
          <D:response>
            <D:href>/dav/Charkle/</D:href>
            <D:propstat>
              <D:prop>
                <D:resourcetype><D:collection/></D:resourcetype>
              </D:prop>
            </D:propstat>
          </D:response>
          <D:response>
            <D:href>/dav/Charkle/Inbox/</D:href>
            <D:propstat>
              <D:prop>
                <D:resourcetype><D:collection/></D:resourcetype>
                <D:getlastmodified>Sun, 22 Nov 2026 07:00:00 GMT</D:getlastmodified>
              </D:prop>
            </D:propstat>
          </D:response>
          <D:response>
            <D:href>/dav/Charkle/poster%2001.png</D:href>
            <D:propstat>
              <D:prop>
                <D:resourcetype/>
                <D:getcontentlength>4096</D:getcontentlength>
                <D:getcontenttype>image/png</D:getcontenttype>
                <D:getlastmodified>Sun, 22 Nov 2026 07:10:00 GMT</D:getlastmodified>
              </D:prop>
            </D:propstat>
          </D:response>
        </D:multistatus>
        """
        let baseURL = try #require(URL(string: "https://dav.jianguoyun.com/dav/"))
        let files = try WebDAVTransport.parsePropfindResponse(
            Data(xml.utf8),
            baseURL: baseURL,
            directoryRelPath: "Charkle",
            parentID: "Charkle"
        )
        #expect(files.count == 2)
        let inbox = try #require(files.first(where: { $0.name == "Inbox" }))
        #expect(inbox.isFolder == true)
        #expect(inbox.id == "Charkle/Inbox")
        let poster = try #require(files.first(where: { $0.name == "poster 01.png" }))
        #expect(poster.isFolder == false)
        #expect(poster.size == 4096)
        #expect(poster.mimeType == "image/png")
    }

    @Test("Lossless storage migration transfers folders, assets, and moodboards between Local Folder and Cloud")
    func migratesBetweenLocalFolderAndCloud() async throws {
        let fm = FileManager.default
        let tempRoot = fm.temporaryDirectory.appending(path: "charkle-migration-\(UUID().uuidString)", directoryHint: .isDirectory)
        try fm.createDirectory(at: tempRoot, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: tempRoot) }

        let appSupport = tempRoot.appending(path: "AppSupport", directoryHint: .isDirectory)
        let localLibDir = tempRoot.appending(path: "MyLocalCharkle", directoryHint: .isDirectory)
        let cloud = InMemoryDriveTransport()

        let media = try MediaPipeline(directory: appSupport)
        let db = try LibraryDatabase(url: appSupport.appending(path: "Library.sqlite3"))
        let engine = LiveCharkleEngine(database: db, media: media)

        // Seed sample library locally (assets, folders, moodboard)
        _ = try await engine.seedSampleLibraryIfEmpty()

        // 1. Migrate to Pure Local Folder at custom path
        let localConfig = DriveSyncConfig(
            mode: .localOnly,
            localLibraryPath: localLibDir.path,
            syncThumbnails: true,
            syncEmbeddings: false
        )
        let toLocalReport = try await engine.migrateLibraryStorage(to: localConfig, webDAVPassword: nil)
        #expect(toLocalReport.targetMode == .localOnly)
        #expect(toLocalReport.migratedAssets >= 10)
        #expect(toLocalReport.migratedFolders >= 4)
        #expect(toLocalReport.migratedBoards >= 1)
        #expect(fm.fileExists(atPath: localLibDir.appending(path: "Inbox").path))
        #expect(fm.fileExists(atPath: localLibDir.appending(path: "Typography").path))
        #expect(fm.fileExists(atPath: localLibDir.appending(path: ".charkle/boards").path))

        // 2. Migrate from Local Folder to Cloud transport (using injected InMemoryDriveTransport)
        let cloudEngine = LiveCharkleEngine(database: db, media: media, transport: cloud)
        let cloudConfig = DriveSyncConfig(
            mode: .directAPIWithGDirect,
            rootFolderName: "Design/Charkle",
            syncThumbnails: true,
            syncEmbeddings: false
        )
        let toCloudReport = try await cloudEngine.migrateLibraryStorage(to: cloudConfig, webDAVPassword: nil)
        #expect(toCloudReport.sourceMode == .localOnly)
        #expect(toCloudReport.targetMode == .directAPIWithGDirect)
        #expect(toCloudReport.migratedAssets >= 10)

        // Verify nested cloud path "Design/Charkle" was created cleanly on cloud transport
        let rootFolders = try await cloud.listFiles(inFolderID: DriveFiles.rootID)
        let design = try #require(rootFolders.first(where: { $0.name == "Design" && $0.isFolder }))
        let charkleChildren = try await cloud.listFiles(inFolderID: design.id)
        let charkleRoot = try #require(charkleChildren.first(where: { $0.name == "Charkle" && $0.isFolder }))
        let subItems = try await cloud.listFiles(inFolderID: charkleRoot.id)
        #expect(subItems.contains(where: { $0.name == "Inbox" && $0.isFolder }))
        #expect(subItems.contains(where: { $0.name == "Typography" && $0.isFolder }))
    }

    @Test("Custom AI config defaults cleanly and supports OpenAI Chat, Anthropic Messages, and OpenAI Responses")
    func customAIEndpointFormatsDecodeAndConstruct() throws {
        // Backward compatibility: decoding legacy JSON without customEndpointFormat
        let legacyJSON = """
        {"provider":"openAICompatible","baseURL":"https://api.openai.com","chatModel":"gpt-4o-mini","embeddingModel":"text-embedding-3-small","autoAnalyzeOnImport":false,"sendThumbnailsToCloud":true}
        """
        let decoded = try JSONDecoder().decode(AIProviderConfig.self, from: Data(legacyJSON.utf8))
        #expect(decoded.customEndpointFormat == .openAIChatCompletions)

        let anthropicCfg = AIProviderConfig(
            provider: .openAICompatible,
            customEndpointFormat: .anthropicMessages,
            baseURL: "https://api.anthropic.com",
            chatModel: "claude-sonnet-4-5",
            embeddingModel: ""
        )
        let anthropic = try AnthropicMessagesProvider(config: anthropicCfg, apiKey: "sk-ant-test")
        #expect(anthropic.embeddingIdentity.contains("anthropic:"))

        let responsesCfg = AIProviderConfig(
            provider: .openAICompatible,
            customEndpointFormat: .openAIResponses,
            baseURL: "https://api.openai.com",
            chatModel: "gpt-4.1-mini",
            embeddingModel: "text-embedding-3-small"
        )
        let responses = try OpenAIResponsesProvider(config: responsesCfg, apiKey: "sk-test")
        #expect(responses.embeddingIdentity.contains("openai-responses:"))
    }

    @Test("Mounted volume upload resolves multi-level filename collisions and skips AppleDouble files")
    func mountedVolumeCollisionAndStreaming() async throws {
        let dir = try BackendFixture.directory()
        defer { try? FileManager.default.removeItem(at: dir) }

        let mountRoot = dir.appending(path: "Mount", directoryHint: .isDirectory)
        let inboxDir = mountRoot.appending(path: "Charkle/Inbox", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: inboxDir, withIntermediateDirectories: true)

        // Create a real local asset in the engine
        let engine = try LiveCharkleEngine.make(appSupportDirectory: dir.appending(path: "AppSupport", directoryHint: .isDirectory))
        let png = try BackendFixture.artwork("#1478DC")
        let imported = try await engine.ingest([.imageData(png, suggestedName: "Poster.png", sourceURL: nil)], targetFolderID: nil, targetBoardID: nil)
        let asset = try #require(imported.first)
        let short = String(asset.id.uuidString.prefix(8)).lowercased()

        // Pre-populate BOTH `Poster.png` AND `Poster-<short>.png` with different contents (plus an AppleDouble file)
        try Data("different-1".utf8).write(to: inboxDir.appending(path: "Poster.png"))
        try Data("different-2".utf8).write(to: inboxDir.appending(path: "Poster-\(short).png"))
        try Data("appledouble".utf8).write(to: inboxDir.appending(path: "._Poster.png"))

        let transport = MountedVolumeTransport(mountPath: mountRoot.path, rootFolderName: "Charkle", requireDedicatedMount: false)
        let listed = try await transport.listFiles(inFolderID: try await transport.findOrCreateFolder(named: "Inbox", parentID: try await transport.findOrCreateFolder(named: "Charkle", parentID: DriveFiles.rootID).id).id)
        #expect(!listed.contains(where: { $0.name.hasPrefix("._") }))

        let config = DriveSyncConfig(
            mode: .localOnly,
            localLibraryPath: mountRoot.appending(path: "Charkle").path
        )
        try await engine.saveSyncConfig(config)
        _ = try await engine.syncNow()

        let expectedFallback = inboxDir.appending(path: "Poster-\(short)-2.png")
        #expect(FileManager.default.fileExists(atPath: expectedFallback.path))
        let uploadedData = try Data(contentsOf: expectedFallback)
        #expect(uploadedData == png)
    }

    @Test("POSIX stream writer writes exact bytes and never leaves partial files")
    func posixStreamWriter() throws {
        let dir = try BackendFixture.directory()
        defer { try? FileManager.default.removeItem(at: dir) }

        let payload = Data((0..<700_000).map { UInt8($0 & 0xFF) })
        let src = dir.appending(path: "source.bin")
        let dst = dir.appending(path: "dest.bin")
        try payload.write(to: src)

        try DriveFiles.writeStream(from: src, to: dst, removeOnFailure: true)
        #expect(try Data(contentsOf: dst) == payload)

        let rawDst = dir.appending(path: "raw.bin")
        try DriveFiles.writeRawBytes(payload, to: rawDst, removeOnFailure: true)
        #expect(try Data(contentsOf: rawDst) == payload)
    }

    @Test("MountedVolumeTransport uses stable path IDs and permanently deleted Inbox files never respawn across syncs")
    func mountedVolumePermanentDeleteNeverRespawnsInInbox() async throws {
        let dir = try BackendFixture.directory()
        defer { try? FileManager.default.removeItem(at: dir) }

        let mountRoot = dir.appending(path: "Mount", directoryHint: .isDirectory)
        let inboxDir = mountRoot.appending(path: "Charkle/Inbox", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: inboxDir, withIntermediateDirectories: true)

        // Drop a brand-new image directly into Mounted Inbox (simulating remote cloud discovery)
        let png = try BackendFixture.artwork("#E85D75")
        let remoteFileURL = inboxDir.appending(path: "EphemeralTest.png")
        try png.write(to: remoteFileURL)

        let transport = MountedVolumeTransport(mountPath: mountRoot.path, rootFolderName: "Charkle", requireDedicatedMount: false)
        let appSupport = dir.appending(path: "AppSupport", directoryHint: .isDirectory)
        let media = try MediaPipeline(directory: appSupport)
        let db = try LibraryDatabase(url: appSupport.appending(path: "Library.sqlite3"))
        let engine = LiveCharkleEngine(database: db, media: media, transport: transport)
        try await engine.saveSyncConfig(DriveSyncConfig(
            mode: .localOnly,
            rootFolderName: "Charkle",
            localLibraryPath: mountRoot.appending(path: "Charkle").path
        ))

        // Sync #1: discovers remote Inbox file with stable mounted-path ID
        let firstSync = try await engine.syncNow()
        #expect(firstSync.discoveredRemoteAssets >= 1)
        let inboxAssets = try await engine.fetchAssets(matching: FilterCriteria(onlyInbox: true))
        let discovered = try #require(inboxAssets.first(where: { $0.fileName == "EphemeralTest.png" }))
        let driveID = try #require(discovered.driveFileID)
        #expect(driveID.hasPrefix(MountedVolumeTransport.pathIDPrefix))

        // Simulate a legacy ephemeral `mounted-<inode>` record (as existed before the fix) to verify automatic migration on permanent delete!
        var legacyAsset = discovered
        legacyAsset.driveFileID = "mounted-99999999"
        try await db.upsertAssets([legacyAsset])

        // Permanently delete the asset locally, then run TWO consecutive syncs
        try await engine.permanentlyDeleteAssets(ids: [discovered.id])
        _ = try await engine.syncNow()
        #expect(!FileManager.default.fileExists(atPath: remoteFileURL.path))

        let thirdSync = try await engine.syncNow()
        #expect(thirdSync.discoveredRemoteAssets == 0)
        let remainingInbox = try await engine.fetchAssets(matching: FilterCriteria(onlyInbox: true))
        #expect(!remainingInbox.contains(where: { $0.fileName == "EphemeralTest.png" }))
    }
}
