import CoreGraphics
import CryptoKit
import Foundation
import ImageIO
import Testing
import UniformTypeIdentifiers
@testable import CharkleCanvas
@testable import CharkleCore

@Suite("Figma / FigJam Bridge Exporter")
struct FigmaBridgeExporterTests {
    @Test("Exports editable .charkleboard bundle with >4096px lossless PNG tiles, notes, groups, palette, connectors, ink, and valid SHA-256")
    func exportFullBundleAndVerifyIntegrity() async throws {
        let workDir = try BackendFixture.directory()
        defer { try? FileManager.default.removeItem(at: workDir) }

        // Create a real 4300x64 PNG image (forces 2 lossless tiles: 4096x64 + 204x64)
        let wideImageURL = workDir.appending(path: "panorama.png")
        try makeSolidPNG(width: 4300, height: 64, to: wideImageURL)

        let asset = AssetRecord(
            title: "Ultra Wide Reference",
            fileName: "panorama.png",
            mediaKind: .image,
            mimeType: "image/png",
            pixelWidth: 4300,
            pixelHeight: 64,
            dominantColors: [LabColor.fromHex("#4D7E97"), LabColor.fromHex("#E6C470")]
        )

        let groupNode = BoardNode(
            kind: .groupFrame(title: "光影区", tint: .sand),
            frame: BoardRect(x: 0, y: 0, width: 900, height: 500),
            zIndex: -10
        )
        let assetNode = BoardNode(
            kind: .assetRef(assetID: asset.id, crop: nil, weight: 1, autoplayLoop: false),
            frame: BoardRect(x: 40, y: 60, width: 420, height: 180),
            zIndex: 1,
            rotationDegrees: 15,
            flipHorizontal: true
        )
        let noteNode = BoardNode(
            kind: .note(title: "设计备注", text: "高反差冷暖对比", style: .warm, fontSize: 14),
            frame: BoardRect(x: 520, y: 80, width: 260, height: 180),
            zIndex: 2
        )
        let paletteNode = BoardNode(
            kind: .paletteStrip(colors: [LabColor.fromHex("#4D7E97"), LabColor.fromHex("#E6C470")], autoSyncWithBoard: true),
            frame: BoardRect(x: 40, y: 300, width: 420, height: 72),
            zIndex: 3
        )
        let connector = BoardConnector(
            fromNodeID: assetNode.id,
            fromAnchor: .trailing,
            toNodeID: noteNode.id,
            toAnchor: .leading,
            label: "参考对应",
            style: .curved
        )
        let stroke = InkStroke(
            points: [InkStrokePoint(x: 60, y: 260), InkStrokePoint(x: 200, y: 290), InkStrokePoint(x: 340, y: 270)],
            colorHex: "#D95D48",
            lineWidth: 3.5
        )

        let board = MoodboardDocument(
            title: "Figma 协作情绪板",
            mode: .freeform,
            nodes: [groupNode, assetNode, noteNode, paletteNode],
            connectors: [connector],
            inkStrokes: [stroke],
            extractedPalette: [LabColor.fromHex("#4D7E97"), LabColor.fromHex("#E6C470")]
        )

        let outputURL = workDir.appending(path: "export.charkleboard")
        let report = try await FigmaBridgeExporter.exportBundle(
            document: board,
            assetsByID: [asset.id: asset],
            options: MoodboardExportOptions(includeAnnotations: true, includePaletteStrip: true, darkAppearance: false),
            resolveOriginalURL: { id in id == asset.id ? wideImageURL : nil },
            resolveThumbnailURL: { _, _ in nil },
            to: outputURL
        )

        #expect(FileManager.default.fileExists(atPath: outputURL.path))
        #expect(report.imageCount == 1)
        #expect(report.noteCount == 1)
        #expect(report.groupCount == 1)
        #expect(report.paletteCount == 2) // top palette header + on-canvas palette strip
        #expect(report.connectorCount == 1)
        #expect(report.strokeCount == 1)
        #expect(report.reviewCount == 0)

        // Unzip via `/usr/bin/ditto -x -k` and verify `board.json` + tile grid + SHA-256 digests
        let unpackDir = workDir.appending(path: "unpacked", directoryHint: .isDirectory)
        let unzip = Process()
        unzip.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        unzip.arguments = ["-x", "-k", outputURL.path, unpackDir.path]
        try unzip.run()
        unzip.waitUntilExit()
        #expect(unzip.terminationStatus == 0)

        let boardData = try Data(contentsOf: unpackDir.appending(path: "board.json"))
        let json = try #require(try JSONSerialization.jsonObject(with: boardData) as? [String: Any])
        #expect(json["format"] as? String == "charkle-figma-bridge")
        #expect(json["version"] as? Int == 1)

        let objects = try #require(json["objects"] as? [[String: Any]])
        let imageObj = try #require(objects.first { $0["kind"] as? String == "image" })
        let geom = try #require(imageObj["geometry"] as? [String: Any])
        #expect(geom["angle"] as? Double == 15)
        #expect(geom["flipX"] as? Bool == true)

        let imageInfo = try #require(imageObj["image"] as? [String: Any])
        #expect(imageInfo["pixelWidth"] as? Int == 4300)
        #expect(imageInfo["pixelHeight"] as? Int == 64)
        let tiles = try #require(imageInfo["tiles"] as? [[String: Any]])
        #expect(tiles.count == 2)
        #expect(tiles[0]["x"] as? Int == 0 && tiles[0]["width"] as? Int == 4096)
        #expect(tiles[1]["x"] as? Int == 4096 && tiles[1]["width"] as? Int == 204)

        for tile in tiles {
            let rel = try #require(tile["file"] as? String)
            let expectedHash = try #require(tile["sha256"] as? String)
            let bytes = try Data(contentsOf: unpackDir.appending(path: rel))
            let actualHash = SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
            #expect(actualHash == expectedHash)
        }
    }

    private func makeSolidPNG(width: Int, height: Int, to url: URL) throws {
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        guard let ctx = CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: width * 4,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else {
            throw FigmaBridgeExportError("Failed to create test bitmap context")
        }
        ctx.setFillColor(red: 0.30, green: 0.49, blue: 0.59, alpha: 1.0)
        ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
        let cg = try #require(ctx.makeImage())
        let dest = try #require(CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(dest, cg, nil)
        #expect(CGImageDestinationFinalize(dest))
    }
}
