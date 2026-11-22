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
}
