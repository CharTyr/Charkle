import CharkleCore
import CoreGraphics
import CryptoKit
import Foundation
import ImageIO
import Testing
import UniformTypeIdentifiers

@Suite("Bidirectional PureRef (.pur) Codec & Engine Integration")
struct PureRefCodecTests {

    private static var repoRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }

    private func makeTestImageData(
        width: Int,
        height: Int,
        r: CGFloat,
        g: CGFloat,
        b: CGFloat,
        type: UTType = .png
    ) throws -> Data {
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        let bitmapInfo = CGImageAlphaInfo.premultipliedLast.rawValue
        let ctx = try #require(CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: width * 4,
            space: colorSpace,
            bitmapInfo: bitmapInfo
        ))
        ctx.setFillColor(red: r, green: g, blue: b, alpha: 1.0)
        ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
        // Paint a distinct asymmetric quadrant so flips/crops are unambiguous
        ctx.setFillColor(red: 1.0 - r, green: 1.0 - g, blue: 1.0 - b, alpha: 1.0)
        ctx.fill(CGRect(x: 0, y: 0, width: width / 2, height: height / 2))

        let cgImage = try #require(ctx.makeImage())
        let out = NSMutableData()
        let dest = try #require(CGImageDestinationCreateWithData(
            out as CFMutableData,
            type.identifier as CFString,
            1,
            nil
        ))
        CGImageDestinationAddImage(dest, cgImage, nil)
        #expect(CGImageDestinationFinalize(dest))
        return out as Data
    }

    @Test("v1.10 .pur encode/decode preserves MD5 checksum, duplicate references, rotations, flips, crops, and notes")
    func binaryV1RoundTripAndChecksum() throws {
        let pngData = try makeTestImageData(width: 240, height: 160, r: 0.2, g: 0.5, b: 0.85, type: .png)
        let jpegData = try makeTestImageData(width: 180, height: 300, r: 0.85, g: 0.35, b: 0.25, type: .jpeg)

        let scene = PureRefScene(
            formatVersion: "1.10",
            folderLocation: "/References/Lighting",
            images: [
                PureRefImageBlob(index: 0, data: pngData, format: .png, pixelWidth: 240, pixelHeight: 160, sourcePath: "hero.png", displayName: "Hero Shot"),
                PureRefImageBlob(index: 1, data: jpegData, format: .jpeg, pixelWidth: 180, pixelHeight: 300, sourcePath: "portrait.jpg", displayName: "Portrait Ref")
            ],
            placements: [
                PureRefImagePlacement(
                    imageIndex: 0,
                    name: "Hero Shot",
                    sourcePath: "hero.png",
                    centerX: -180,
                    centerY: 40,
                    width: 360,
                    height: 240,
                    rotationDegrees: 24.5,
                    flipHorizontal: false,
                    flipVertical: false,
                    zLayer: 1.0,
                    crop: nil,
                    childNotes: [
                        PureRefTextNote(text: "主光方向", centerX: 0, centerY: 140, scale: 1.0, zLayer: 2.0)
                    ]
                ),
                // Duplicate instance of image 0 with crop + horizontal flip
                PureRefImagePlacement(
                    imageIndex: 0,
                    name: "Hero Crop",
                    sourcePath: "hero.png",
                    centerX: 260,
                    centerY: -30,
                    width: 180,
                    height: 120,
                    rotationDegrees: -12.0,
                    flipHorizontal: true,
                    flipVertical: false,
                    zLayer: 3.0,
                    crop: NormalizedCropRect(x: 0.15, y: 0.2, width: 0.6, height: 0.5)
                ),
                PureRefImagePlacement(
                    imageIndex: 1,
                    name: "Portrait Ref",
                    sourcePath: "portrait.jpg",
                    centerX: 520,
                    centerY: 90,
                    width: 210,
                    height: 350,
                    rotationDegrees: 0,
                    flipHorizontal: false,
                    flipVertical: true,
                    zLayer: 5.0
                )
            ],
            notes: [
                PureRefTextNote(
                    text: "冷暖对比参考板\n注意暗部饱和度",
                    centerX: 120,
                    centerY: -220,
                    scale: 1.2,
                    zLayer: 10.0,
                    foreground: PureRefColor.fromNoteStyle(.warm).foreground,
                    background: PureRefColor.fromNoteStyle(.warm).background
                )
            ]
        )

        let encoded = try PureRefCodec.encode(scene)
        #expect(encoded.count > 224)

        // Verify PureRef header magic & MD5 checksum at bytes [44..<108]
        let expectedMD5 = Insecure.MD5.hash(data: encoded.subdata(in: 108..<encoded.count))
            .map { String(format: "%02x", $0) }
            .joined()
        var expectedUTF16: [UInt8] = []
        for u in expectedMD5.utf16 {
            expectedUTF16.append(UInt8(u >> 8))
            expectedUTF16.append(UInt8(u & 0xFF))
        }
        #expect(Array(encoded[44..<108]) == expectedUTF16)

        // Decode back and verify lossless structure
        let decoded = try PureRefCodec.decode(data: encoded, sourceName: "Lighting")
        #expect(decoded.formatVersion == "1.10")
        #expect(!decoded.usedFallbackExtraction)
        #expect(decoded.images.count == 2)
        #expect(decoded.images.allSatisfy { $0.format == .png }) // JPEG normalized to PNG in v1.10
        #expect(decoded.placements.count == 3)
        #expect(decoded.notes.count == 1)

        // Verify duplicate instance shares imageIndex 0
        #expect(decoded.placements[0].imageIndex == 0)
        #expect(decoded.placements[1].imageIndex == 0)
        #expect(decoded.placements[2].imageIndex == 1)

        // Verify transform fidelity
        #expect(abs(decoded.placements[0].centerX - (-180)) < 0.01)
        #expect(abs(decoded.placements[0].width - 360) < 0.5)
        #expect(abs(decoded.placements[0].rotationDegrees - 24.5) < 0.1)
        #expect(decoded.placements[0].childNotes.count == 1)
        #expect(decoded.placements[0].childNotes[0].text == "主光方向")

        #expect(decoded.placements[1].flipHorizontal == true)
        #expect(abs(decoded.placements[1].rotationDegrees - (-12.0)) < 0.1)
        let crop = try #require(decoded.placements[1].crop)
        #expect(abs(crop.x - 0.15) < 0.01)
        #expect(abs(crop.y - 0.20) < 0.01)
        #expect(abs(crop.width - 0.60) < 0.01)
        #expect(abs(crop.height - 0.50) < 0.01)

        #expect(decoded.placements[2].flipVertical == true)
        #expect(abs(decoded.placements[2].rotationDegrees) < 0.1)
        #expect(decoded.notes[0].text == "冷暖对比参考板\n注意暗部饱和度")
        #expect(decoded.notes[0].background.inferredNoteStyle() == .warm)
    }

    @Test("PureRef 2.0+ resilient extractor carves native JPEG/PNG/GIF blobs, deduplicates, and recovers notes")
    func resilientV2NativeFormatExtraction() throws {
        let pngData = try makeTestImageData(width: 120, height: 90, r: 0.1, g: 0.7, b: 0.4, type: .png)
        let jpegData = try makeTestImageData(width: 160, height: 120, r: 0.9, g: 0.5, b: 0.1, type: .jpeg)
        let gifData = try makeTestImageData(width: 80, height: 80, r: 0.3, g: 0.2, b: 0.9, type: .gif)

        // Build synthetic PureRef 2.0 binary payload with native mixed image codecs
        var bytes = Array<UInt8>(repeating: 0, count: 224)
        // Version length 6 bytes ("2.0" in UTF-16BE)
        bytes[3] = 6
        let v2 = Array("2.0".utf16).flatMap { [UInt8($0 >> 8), UInt8($0 & 0xFF)] }
        bytes.replaceSubrange(4..<10, with: v2)

        // Interleave opaque v2 metadata padding + native PNG, JPEG, duplicate PNG, and GIF
        bytes.append(contentsOf: [0x00, 0x11, 0x22, 0x33, 0x44, 0x55])
        bytes.append(contentsOf: pngData)
        bytes.append(contentsOf: [0xDE, 0xAD, 0xBE, 0xEF])
        bytes.append(contentsOf: jpegData)
        bytes.append(contentsOf: [0x01, 0x02, 0x03, 0x04])
        bytes.append(contentsOf: pngData) // duplicate should be deduplicated
        bytes.append(contentsOf: gifData)

        // Append a UTF-16BE GraphicsTextItem note block
        let noteHeader = Array("GraphicsTextItem".utf16).flatMap { [UInt8($0 >> 8), UInt8($0 & 0xFF)] }
        bytes.append(contentsOf: noteHeader)
        let noteBody = Array("纯2.0场景备注".utf16).flatMap { [UInt8($0 >> 8), UInt8($0 & 0xFF)] }
        let len = UInt32(noteBody.count)
        bytes.append(contentsOf: [UInt8(len >> 24), UInt8((len >> 16) & 0xFF), UInt8((len >> 8) & 0xFF), UInt8(len & 0xFF)])
        bytes.append(contentsOf: noteBody)

        let decoded = try PureRefCodec.decode(data: Data(bytes), sourceName: "V2Scene")
        #expect(decoded.formatVersion == "2.0")
        #expect(decoded.usedFallbackExtraction)
        #expect(decoded.images.count == 3)
        #expect(Set(decoded.images.map(\.format)) == Set([.png, .jpeg, .gif]))
        #expect(decoded.placements.count == 3)
        #expect(decoded.notes.contains(where: { $0.text == "纯2.0场景备注" }))
    }

    @Test("LiveCharkleEngine exports Moodboard & selected assets to .pur and re-imports cleanly into Folder + Moodboard")
    func endToEndBidirectionalEngineFlow() async throws {
        let tmpRoot = FileManager.default.temporaryDirectory
            .appending(path: "charkle-pur-e2e-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: tmpRoot, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmpRoot) }

        let img1Data = try makeTestImageData(width: 320, height: 200, r: 0.15, g: 0.45, b: 0.80, type: .png)
        let img2Data = try makeTestImageData(width: 200, height: 320, r: 0.85, g: 0.30, b: 0.20, type: .jpeg)

        let sourceDir = tmpRoot.appending(path: "source-lib", directoryHint: .isDirectory)
        let sourceMedia = try MediaPipeline(directory: sourceDir)
        let sourceDB = try LibraryDatabase(url: sourceDir.appending(path: "Library.sqlite3"))
        let sourceEngine = LiveCharkleEngine(database: sourceDB, media: sourceMedia)
        let ingested = try await sourceEngine.ingest(
            [
                .imageData(img1Data, suggestedName: "CyberCity.png", sourceURL: nil),
                .imageData(img2Data, suggestedName: "PortraitNeon.jpg", sourceURL: nil)
            ],
            targetFolderID: nil,
            targetBoardID: nil
        )
        #expect(ingested.count == 2)

        // 1. Export selected assets as packed .pur reference board
        let selectionPurURL = tmpRoot.appending(path: "SelectionBoard.pur")
        let selectionReport = try await sourceEngine.exportAssetsToPureRef(
            assetIDs: ingested.map(\.id),
            title: "SelectionBoard",
            to: selectionPurURL
        )
        #expect(selectionReport.imageCount == 2)
        #expect(selectionReport.placementCount == 2)
        #expect(FileManager.default.fileExists(atPath: selectionPurURL.path))

        // 2. Export a full Moodboard (with rotation, crop, flip, note, and group frame) to .pur
        let board = MoodboardDocument(
            title: "Cyber Lighting",
            mode: .freeform,
            nodes: [
                BoardNode(
                    kind: .assetRef(assetID: ingested[0].id, crop: NormalizedCropRect(x: 0.1, y: 0.1, width: 0.7, height: 0.7), weight: 1, autoplayLoop: false),
                    frame: BoardRect(x: 100, y: 120, width: 320, height: 200),
                    zIndex: 1,
                    rotationDegrees: 15,
                    flipHorizontal: true
                ),
                BoardNode(
                    kind: .assetRef(assetID: ingested[1].id, crop: nil, weight: 1, autoplayLoop: false),
                    frame: BoardRect(x: 480, y: 100, width: 200, height: 320),
                    zIndex: 2
                ),
                BoardNode(
                    kind: .note(title: "灯光备注", text: "冷蓝主光 + 霓虹边缘光", style: .ink, fontSize: 16),
                    frame: BoardRect(x: 120, y: 380, width: 260, height: 110),
                    zIndex: 3
                ),
                BoardNode(
                    kind: .groupFrame(title: "主视觉分组", tint: .ocean),
                    frame: BoardRect(x: 60, y: 60, width: 660, height: 460),
                    zIndex: 0
                )
            ]
        )
        let savedBoard = try await sourceEngine.saveBoard(board)
        let boardPurURL = tmpRoot.appending(path: "Cyber Lighting.pur")
        let boardReport = try await sourceEngine.exportMoodboardToPureRef(board: savedBoard, to: boardPurURL)
        #expect(boardReport.imageCount == 2)
        #expect(boardReport.placementCount == 2)
        #expect(boardReport.noteCount == 2) // 1 note + 1 group header note

        // 3. Re-import the exported .pur into a completely fresh Charkle library
        let destDir = tmpRoot.appending(path: "dest-lib", directoryHint: .isDirectory)
        let destMedia = try MediaPipeline(directory: destDir)
        let destDB = try LibraryDatabase(url: destDir.appending(path: "Library.sqlite3"))
        let destEngine = LiveCharkleEngine(database: destDB, media: destMedia)
        let importResult = try await destEngine.importPureRefScene(at: boardPurURL, targetFolderID: nil, createMoodboard: true)
        #expect(importResult.sceneName == "Cyber Lighting")
        #expect(importResult.importedAssets.count == 2)
        #expect(importResult.rootFolderID != nil)
        #expect(importResult.importedNoteCount == 2)
        let importedBoardID = try #require(importResult.createdBoardID)
        let importedBoard = try #require(try await destEngine.fetchBoard(id: importedBoardID))

        let imageNodes = importedBoard.nodes.filter { $0.referencedAssetID != nil }
        let noteNodes = importedBoard.nodes.filter {
            if case .note = $0.kind { return true }
            return false
        }
        #expect(imageNodes.count == 2)
        #expect(noteNodes.count == 2)
        #expect(imageNodes.contains(where: { $0.flipHorizontal && abs($0.rotationDegrees - 15) < 0.2 }))
        #expect(noteNodes.contains(where: {
            if case .note(_, let text, _, _) = $0.kind { return text.contains("冷蓝主光") }
            return false
        }))
    }

    @Test("Single-image copy uses one NSPasteboardItem and drag-out prefers cached originals")
    func clipboardAndUIWiringContracts() throws {
        let libraryStore = try String(contentsOf: Self.repoRoot.appendingPathComponent("Sources/CharkleApp/Stores/LibraryStore.swift"), encoding: .utf8)
        let mainWindow = try String(contentsOf: Self.repoRoot.appendingPathComponent("Sources/CharkleApp/Views/MainWindowView.swift"), encoding: .utf8)
        let masonry = try String(contentsOf: Self.repoRoot.appendingPathComponent("Sources/CharkleCanvas/VirtualizedMasonryView.swift"), encoding: .utf8)
        let mobileCapture = try String(contentsOf: Self.repoRoot.appendingPathComponent("ios/CharkleMobile/Views/CaptureSheetView.swift"), encoding: .utf8)
        let mobileBoard = try String(contentsOf: Self.repoRoot.appendingPathComponent("ios/CharkleMobile/Views/MoodboardStudioView.swift"), encoding: .utf8)

        #expect(libraryStore.contains("let item = NSPasteboardItem()"))
        #expect(libraryStore.contains("pb.writeObjects([item])"))
        #expect(mainWindow.contains("cachedOriginalURL(for: asset)"))
        #expect(mainWindow.contains("exportAssetsToPureRef("))
        #expect(mainWindow.contains("exportCurrentBoardToPureRef("))
        #expect(masonry.contains("发送到 PureRef"))
        #expect(mobileCapture.contains("importPureRefScenes("))
        #expect(mobileBoard.contains("导出 PureRef (.pur)"))
    }
}
