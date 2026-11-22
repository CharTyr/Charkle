import CoreGraphics
import Foundation
import ImageIO
import Testing
import UniformTypeIdentifiers
@testable import CharkleCore

@Suite("Full-media pipeline")
struct MediaPipelineTests {
    @Test("Import produces an original, a valid 520px JPEG, and correct media metadata",
          arguments: ["jpg", "gif", "apng", "mp4", "webloc", "pdf", "md", "svg", "wav"])
    func mediaKinds(_ ext: String) async throws {
        let directory = try BackendFixture.directory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let pipeline = try MediaPipeline(directory: directory.appending(path: "Library"))
        let file = directory.appending(path: "reference." + ext)
        let expected: MediaKind
        switch ext {
        case "jpg":
            let image = try #require(MediaArtwork.swatch(.fromHex("#B55D48")))
            try encodeFrames([image], to: file, format: .jpeg, properties: [kCGImagePropertyOrientation: 6])
            expected = .image
        case "gif", "apng":
            let red = try #require(MediaArtwork.swatch(.fromHex("#B55D48")))
            let green = try #require(MediaArtwork.swatch(.fromHex("#5E8162")))
            let gif = ext == "gif"
            let properties: [CFString: Any] = gif
                ? [kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFDelayTime: 0.25]]
                : [kCGImagePropertyPNGDictionary: [kCGImagePropertyAPNGDelayTime: 0.2]]
            try encodeFrames([red, green], to: file, format: gif ? .gif : .png, properties: properties)
            expected = .animatedImage
        case "mp4":
            try #require(Data(base64Encoded: Self.videoFixture, options: .ignoreUnknownCharacters)).write(to: file)
            expected = .video
        case "webloc":
            let plist = try PropertyListSerialization.data(fromPropertyList: ["URL": "http://127.0.0.1:1/field-notes"],
                                                            format: .xml, options: 0)
            try plist.write(to: file)
            expected = .webBookmark
        case "pdf":
            var box = CGRect(x: 0, y: 0, width: 300, height: 450)
            let context = try #require(CGContext(file as CFURL, mediaBox: &box, nil))
            context.beginPDFPage(nil)
            context.setFillColor(MediaArtwork.color(0xDCC2B6))
            context.fill(box)
            MediaArtwork.draw("PLATE ONE", in: context, at: CGPoint(x: 32, y: 380), size: 22, ink: 0x201E1B, width: 230)
            context.endPDFPage()
            context.closePDF()
            expected = .document
        case "md":
            try Data("# Field notes\nLimestone colors and afternoon shadows".utf8).write(to: file)
            expected = .document
        case "svg":
            let svg = "<svg xmlns='http://www.w3.org/2000/svg' width='400' height='300'><rect width='400' height='300' fill='#b8c493'/><circle cx='200' cy='150' r='100' fill='#b35a43'/></svg>"
            try Data(svg.utf8).write(to: file)
            expected = .designFile
        default:
            try wave().write(to: file)
            expected = .audio
        }

        let result = try await pipeline.ingest(.fileURL(file), folderID: nil)
        #expect(result.asset.mediaKind == expected)
        #expect(result.asset.contentHash.count == 64)
        #expect(FileManager.default.fileExists(atPath: result.original.path))
        let poster = try #require(pipeline.thumbnailURL(for: result.asset.id, tier: .grid520))
        let source = try #require(CGImageSourceCreateWithURL(poster as CFURL, nil))
        #expect(CGImageSourceGetType(source) as String? == UTType.jpeg.identifier)
        let image = try #require(CGImageSourceCreateImageAtIndex(source, 0, nil))
        #expect(max(image.width, image.height) <= 520)
        if ext == "jpg" {
            #expect(result.asset.pixelWidth == 620)
            #expect(result.asset.pixelHeight == 720)
            #expect(pipeline.thumbnailURL(for: result.asset.id, tier: .preview1400) != nil)
        }
        if ["gif", "apng", "mp4", "wav"].contains(ext) {
            #expect((result.asset.durationSeconds ?? 0) > 0.2)
        }
        if ext == "mp4" { #expect(result.asset.pixelWidth == 32 && result.asset.pixelHeight == 24) }
        if ext == "wav" {
            #expect(result.asset.waveformPeaks.count == 48)
            #expect((result.asset.waveformPeaks.max() ?? 0) > 0.5)
        }
        if ext == "webloc" {
            #expect(result.asset.sourceURL == "http://127.0.0.1:1/field-notes")
            #expect(result.asset.sourceDomain == "127.0.0.1")
        }
        if ext == "md" { #expect(result.asset.ocrText?.contains("afternoon shadows") == true) }
        if ext == "pdf" {
            #expect(result.asset.ocrText?.contains("PLATE ONE") == true)
            #expect(result.asset.pixelWidth == 300 && result.asset.pixelHeight == 450)
        }
    }

    @Test("LRU evicts the least recently opened recoverable original and preserves both types of pin")
    func cacheEviction() async throws {
        let directory = try BackendFixture.directory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let transport = InMemoryDriveTransport()
        let engine = try BackendFixture.makeEngine(directory, transport: transport)
        try await engine.saveSyncConfig(BackendFixture.syncConfig())
        let assets = try await engine.ingest([
            .colorSwatch(hex: "#B47B56", title: "Asset pin"), .colorSwatch(hex: "#778261", title: "Board pin"),
            .colorSwatch(hex: "#365879", title: "Old"), .colorSwatch(hex: "#D69B41", title: "New")
        ], targetFolderID: nil, targetBoardID: nil)
        let board = MoodboardDocument(title: "Filed offline", nodes: MoodboardCurator.editorialNodes([assets[1]]), pinnedOffline: true)
        _ = try await engine.saveBoard(board)
        _ = try await engine.updateAssets(AssetBatchPatch(assetIDs: [assets[0].id], pinnedOffline: true))
        #expect(try await engine.syncNow().uploadedOps > 0)
        let paths = try await assetPaths(assets, engine: engine)
        let pinBytes = assets[0].fileSizeBytes + assets[1].fileSizeBytes
        await engine.setCacheBudgetBytes(pinBytes + assets[3].fileSizeBytes)
        #expect(FileManager.default.fileExists(atPath: paths[0].path))
        #expect(FileManager.default.fileExists(atPath: paths[1].path))
        #expect(!FileManager.default.fileExists(atPath: paths[2].path))
        #expect(FileManager.default.fileExists(atPath: paths[3].path))
        await engine.setCacheBudgetBytes(0)
        let stats = try await engine.evictCacheNow()
        #expect(stats.originalCacheBytes == pinBytes)
        #expect(stats.cachedOriginalCount == 2)
        #expect(stats.pinnedAssetCount == 2)
        #expect(await engine.thumbnailURL(for: assets[2].id, tier: .grid520) != nil)
        #expect(try await engine.fetchAsset(id: assets[2].id)?.isLocalOriginalCached == false)
        let restored = try await engine.originalURL(for: assets[2].id)
        #expect(FileManager.default.fileExists(atPath: restored.path))
        #expect(try await engine.fetchAsset(id: assets[2].id)?.isLocalOriginalCached == true)
    }

    @Test("Sample library creates persistent rendered artwork, Inbox entries, and a functional board exactly once")
    func seedLibrary() async throws {
        let directory = try BackendFixture.directory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let engine = try LiveCharkleEngine.make(appSupportDirectory: directory)
        try await engine.saveSyncConfig(DriveSyncConfig(mode: .localOnly, syncEmbeddings: false))
        #expect(try await engine.seedSampleLibraryIfEmpty())
        #expect(try await !engine.seedSampleLibraryIfEmpty())
        let assets = try await engine.fetchAssets(matching: FilterCriteria())
        #expect(assets.count >= 10)
        #expect(try await engine.inboxCount() >= 2)
        #expect(try await engine.fetchFolders().count >= 4)
        let boards = try await engine.fetchBoards()
        let board = try #require(boards.first)
        #expect(boards.count == 1 && board.itemCount >= 5 && board.paletteHexes.count >= 5)
        #expect(Set(assets.map(\.contentHash)).count == assets.count)
        for asset in assets {
            #expect(asset.fileSizeBytes > 2_000)
            #expect(await engine.thumbnailURL(for: asset.id, tier: .grid520) != nil)
        }
        let reopened = try LiveCharkleEngine.make(appSupportDirectory: directory)
        #expect(try await reopened.fetchBoards().first?.id == board.id)
        #expect(try await reopened.fetchAssets(matching: FilterCriteria()).count == assets.count)
    }

    private func assetPaths(_ assets: [AssetRecord], engine: LiveCharkleEngine) async throws -> [URL] {
        var paths: [URL] = []
        for asset in assets { paths.append(try await engine.originalURL(for: asset.id)) }
        return paths
    }

    private func encodeFrames(_ images: [CGImage], to file: URL, format: UTType, properties: [CFString: Any]) throws {
        let writer = try #require(CGImageDestinationCreateWithURL(file as CFURL, format.identifier as CFString, images.count, nil))
        if format == .gif {
            CGImageDestinationSetProperties(writer, [kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFLoopCount: 0]] as CFDictionary)
        } else if format == .png, images.count > 1 {
            CGImageDestinationSetProperties(writer, [kCGImagePropertyPNGDictionary: [kCGImagePropertyAPNGLoopCount: 0]] as CFDictionary)
        }
        for image in images { CGImageDestinationAddImage(writer, image, properties as CFDictionary) }
        try #require(CGImageDestinationFinalize(writer))
    }

    private func wave() -> Data {
        var out = Data()
        let samples = 8_000
        func append<T: FixedWidthInteger>(_ value: T) {
            var little = value.littleEndian
            withUnsafeBytes(of: &little) { out.append(contentsOf: $0) }
        }
        out.append(contentsOf: "RIFF".utf8)
        append(UInt32(36 + samples * 2))
        out.append(contentsOf: "WAVEfmt ".utf8)
        append(UInt32(16))
        append(UInt16(1))
        append(UInt16(1))
        append(UInt32(samples))
        append(UInt32(samples * 2))
        append(UInt16(2))
        append(UInt16(16))
        out.append(contentsOf: "data".utf8)
        append(UInt32(samples * 2))
        for sample in 0..<samples {
            append(Int16(sin(Double(sample) / 8) * 28_000))
        }
        return out
    }

    // 32×24 H.264 gradient clip, four frames over one second.
    private static let videoFixture = """
    AAAAHGZ0eXBtcDQyAAAAAWlzb21tcDQxbXA0MgAAAAFtZGF0AAAAAAAAARsAAAA1BgUtR1ZK3FxMQz+U78URPNFDqAEA
    AAMAAQMAAAMAAQIAAeYACwAAAwAAAwAAERwMA5ErAYAAAAB4JbggH9XZ5QP18hpMw+uchNXf+w3aOElqqn/y3Frk1gpO
    2rH+iqbp4QCuwZ/IjllQLjIgAAp5TPfOAyv0edvklrru6ZQMMLOmp+zWAtN8IYgR/cqvAIiIYlhXP0ZDGa9NjdPIbg+F
    YEaD/19ucAAABExHQEfwolTzAAAAGiHhDF9n79rg92/YP+FvODEw78CibCANKdX4AAAAGiGogoS/yhdAXwVoGsgrZmHR
    Lyo1vWsOo67eAAAAFgGowY//0FYkngPxdWj63/jPpjxifhYAAAL+bW9vdgAAAGxtdmhkAAAAAOcoLQPnKC0DAAACWAAA
    AlgAAQAAAQAAAAAAAAAAAAAAAAEAAAAAAAAAAAAAAAAAAAABAAAAAAAAAAAAAAAAAABAAAAAAAAAAAAAAAAAAAAAAAAA
    AAAAAAAAAAAAAAAAAgAAAop0cmFrAAAAXHRraGQAAAAB5ygtA+coLQMAAAABAAAAAAAAAlgAAAAAAAAAAAAAAAAAAAAA
    AAEAAAAAAAAAAAAAAAAAAAABAAAAAAAAAAAAAAAAAABAAAAAACAAAAAYAAAAAAAkZWR0cwAAABxlbHN0AAAAAAAAAAEA
    AAJYAAABLAABAAAAAAICbWRpYQAAACBtZGhkAAAAAOcoLQPnKC0DAAACWAAAAlhVxAAAAAAAMWhkbHIAAAAAAAAAAHZp
    ZGUAAAAAAAAAAAAAAABDb3JlIE1lZGlhIFZpZGVvAAAAAaltaW5mAAAAFHZtaGQAAAABAAAAAAAAAAAAAAAkZGluZgAA
    ABxkcmVmAAAAAAAAAAEAAAAMdXJsIAAAAAEAAAFpc3RibAAAAKFzdHNkAAAAAAAAAAEAAACRYXZjMQAAAAAAAAABAAAA
    AAAAAAAAAAAAAAAAAAAgABgASAAAAEgAAAAAAAAAAQAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAABj//wAA
    ACdhdmNDAWQAC//hAAwnZAALrFZQw3gUYJUBAAQo7jyw/fj4AAAAAApmaWVsAQAAAAAKY2hybQAAAAAAGHN0dHMAAAAA
    AAAAAQAAAAQAAACWAAAAMGN0dHMAAAAAAAAABAAAAAEAAAEsAAAAAQAAAlgAAAABAAABLAAAAAEAAAAAAAAAFHN0c3MA
    AAAAAAAAAQAAAAEAAAAQc2R0cAAAAAAgEBAYAAAAHHN0c2MAAAAAAAAAAQAAAAEAAAAEAAAAAQAAACRzdHN6AAAAAAAA
    AAAAAAAEAAAAtQAAAB4AAAAeAAAAGgAAABRzdGNvAAAAAAAAAAEAAAAs
    """
}
