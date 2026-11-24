import AppKit
@testable import CharkleCanvas
@testable import CharkleCore
import CoreGraphics
import Foundation
import ImageIO
import Testing

// MARK: - Private Test Helpers

private final class AuditMoodboardMockURLProtocol: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) static var handler: ((URLRequest) throws -> (HTTPURLResponse, Data))?

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let handler = Self.handler else {
            client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
            return
        }
        do {
            let (response, data) = try handler(request)
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        } catch {
            client?.urlProtocol(self, didFailWithError: error)
        }
    }

    override func stopLoading() {}
}

private func makeAuditMockSession() -> URLSession {
    let config = URLSessionConfiguration.ephemeral
    config.protocolClasses = [AuditMoodboardMockURLProtocol.self]
    return URLSession(configuration: config)
}

private func makeSolidCGImage(
    width: Int,
    height: Int,
    red: CGFloat,
    green: CGFloat,
    blue: CGFloat
) throws -> CGImage {
    let cs = CGColorSpaceCreateDeviceRGB()
    guard let ctx = CGContext(
        data: nil,
        width: width,
        height: height,
        bitsPerComponent: 8,
        bytesPerRow: width * 4,
        space: cs,
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    ) else {
        throw LibraryDatabaseError("Failed to create test CGContext")
    }
    ctx.setFillColor(CGColor(red: red, green: green, blue: blue, alpha: 1))
    ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
    guard let img = ctx.makeImage() else {
        throw LibraryDatabaseError("Failed to create test CGImage")
    }
    return img
}

private func writeJPEGImage(
    width: Int,
    height: Int,
    red: CGFloat,
    green: CGFloat,
    blue: CGFloat,
    to url: URL
) throws {
    let cg = try makeSolidCGImage(width: width, height: height, red: red, green: green, blue: blue)
    guard let data = NSBitmapImageRep(cgImage: cg).representation(using: .jpeg, properties: [.compressionFactor: 0.9]) else {
        throw LibraryDatabaseError("Failed to encode JPEG")
    }
    try data.write(to: url, options: .atomic)
}

private func makeTinyLibrary() async throws -> (root: URL, db: LibraryDatabase, media: MediaPipeline, assets: [AssetRecord]) {
    let dir = try BackendFixture.directory()
    let appSupport = dir.appending(path: "AppSupport", directoryHint: .isDirectory)
    let media = try MediaPipeline(directory: appSupport)
    let db = try LibraryDatabase(url: appSupport.appending(path: "Library.sqlite3"))
    let engine = LiveCharkleEngine(database: db, media: media)

    let specs: [(String, String, [String])] = [
        ("Warm Terracotta.png", "#C86D51", ["editorial", "warm"]),
        ("Sand Linen.png", "#DFC9B1", ["editorial", "minimal"]),
        ("Cobalt Studio.png", "#2F5B88", ["studio", "cool"])
    ]
    var imported: [AssetRecord] = []
    for (name, hex, tags) in specs {
        let png = try BackendFixture.artwork(hex)
        let created = try await engine.ingest(
            [.imageData(png, suggestedName: name, sourceURL: nil)],
            targetFolderID: nil,
            targetBoardID: nil
        )
        let asset = try #require(created.first)
        _ = try await engine.updateAssets(AssetBatchPatch(assetIDs: [asset.id], addTags: tags))
        imported.append(try #require(await db.asset(id: asset.id)))
    }
    return (dir, db, media, imported)
}

// MARK: - Moodboard, Canvas, Exporter & AI Grounding Audit Fixes

@Suite("Moodboard Canvas, Exporter & AI Grounding Audit Fixes", .serialized)
struct AuditFixMoodboardTests {

    @MainActor
    @Test("MoodboardExporter renders upright text, scales wide boards without clipping, and honors resolveImage")
    func exporterRendersUprightTextAndScalesWideBoards() throws {
        let loader = ThumbnailImageLoader(engine: PlaceholderCharkleEngine())

        // 1. Verify upright glyph orientation: "LLLLLL" has its horizontal stroke in the bottom half of the glyph box
        let textBoard = MoodboardDocument(
            title: "LLLLLL",
            mode: .freeform,
            nodes: [
                BoardNode(
                    kind: .note(title: nil, text: "", style: .paper, fontSize: 13),
                    frame: BoardRect(x: 0, y: 120, width: 320, height: 120),
                    zIndex: 1
                )
            ]
        )
        let rendered = try #require(
            MoodboardExporter.renderImage(
                document: textBoard,
                assetsByID: [:],
                loader: loader,
                options: MoodboardExportOptions(includeAnnotations: false, includePaletteStrip: false, darkAppearance: false)
            )
        )
        let rep = try #require(rendered.representations.compactMap { $0 as? NSBitmapImageRep }.first)
        // Header band lives near the top of the image (first 160 px at 2x Retina)
        let scanH = min(rep.pixelsHigh, 180)
        let scanW = min(rep.pixelsWide, 420)
        var minY = scanH
        var maxY = 0
        var rowDarkCounts = [Int](repeating: 0, count: scanH)
        for y in 0..<scanH {
            for x in 0..<scanW {
                if let c = rep.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB),
                   c.brightnessComponent < 0.55 {
                    rowDarkCounts[y] += 1
                    if y < minY { minY = y }
                    if y > maxY { maxY = y }
                }
            }
        }
        #expect(maxY > minY + 8)
        let midY = (minY + maxY) / 2
        let topHalfInk = rowDarkCounts[minY...midY].reduce(0, +)
        let bottomHalfInk = rowDarkCounts[(midY + 1)...maxY].reduce(0, +)
        #expect(bottomHalfInk > topHalfInk)

        // 2. Verify wide >5200pt board downscales cleanly instead of clipping right-edge card, and uses resolveImage
        let crimsonAsset = AssetRecord(
            title: "Far Right Card",
            fileName: "far-right.png",
            mediaKind: .image,
            mimeType: "image/png",
            pixelWidth: 400,
            pixelHeight: 400
        )
        let crimsonCG = try makeSolidCGImage(width: 120, height: 120, red: 0.90, green: 0.12, blue: 0.14)
        let wideBoard = MoodboardDocument(
            title: "Wide Board",
            mode: .freeform,
            nodes: [
                BoardNode(
                    kind: .note(title: "Start", text: "Left", style: .paper, fontSize: 13),
                    frame: BoardRect(x: 0, y: 0, width: 300, height: 220),
                    zIndex: 1
                ),
                BoardNode(
                    kind: .assetRef(assetID: crimsonAsset.id, crop: nil, weight: 1, autoplayLoop: false),
                    frame: BoardRect(x: 5600, y: 0, width: 400, height: 400),
                    zIndex: 2
                )
            ]
        )
        let wideRendered = try #require(
            MoodboardExporter.renderImage(
                document: wideBoard,
                assetsByID: [crimsonAsset.id: crimsonAsset],
                loader: loader,
                options: MoodboardExportOptions(scale: 2.0, includeAnnotations: false, includePaletteStrip: false, darkAppearance: false),
                resolveImage: { id in id == crimsonAsset.id ? crimsonCG : nil }
            )
        )
        let wideRep = try #require(wideRendered.representations.compactMap { $0 as? NSBitmapImageRep }.first)
        #expect(wideRep.pixelsWide * wideRep.pixelsHigh <= 36_000_000)

        var foundCrimsonOnRight = false
        let startX = Int(Double(wideRep.pixelsWide) * 0.80)
        for y in stride(from: 0, to: wideRep.pixelsHigh, by: 4) {
            for x in stride(from: startX, to: wideRep.pixelsWide, by: 4) {
                if let c = wideRep.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB),
                   c.redComponent > 0.72 && c.greenComponent < 0.30 && c.blueComponent < 0.30 {
                    foundCrimsonOnRight = true
                    break
                }
            }
            if foundCrimsonOnRight { break }
        }
        #expect(foundCrimsonOnRight)
    }

    @Test("MoodboardDocument decodes legacy minimal JSON and NormalizedCropRect sanitizes NaN/Inf bounds")
    func resilientCodableAndCropSanitization() throws {
        let boardID = UUID()
        let nodeID = UUID()
        let assetID = UUID()
        let legacyJSON = """
        {
          "id": "\(boardID.uuidString)",
          "title": "Legacy Board",
          "nodes": [
            {
              "id": "\(nodeID.uuidString)",
              "kind": {
                "assetRef": {
                  "assetID": "\(assetID.uuidString)",
                  "weight": 1,
                  "autoplayLoop": false
                }
              },
              "frame": { "x": 10, "y": 20, "width": 300, "height": 200 }
            }
          ]
        }
        """
        let decoded = try JSONDecoder().decode(MoodboardDocument.self, from: Data(legacyJSON.utf8))
        #expect(decoded.id == boardID)
        #expect(decoded.title == "Legacy Board")
        #expect(decoded.subtitle == "")
        #expect(decoded.mode == .freeform)
        #expect(decoded.viewportZoom == 1.0)
        #expect(decoded.nodes.count == 1)
        #expect(decoded.nodes[0].rotationDegrees == 0)

        let nanBox = NormalizedCropRect(boxTop: .nan, bottom: 0.8, left: .infinity, right: 0.9)
        #expect(nanBox == .full)

        let overflow = NormalizedCropRect(x: 0.99, y: 0.99, width: 0.5, height: 0.5).clamped()
        #expect(overflow.x.isFinite && overflow.y.isFinite && overflow.width.isFinite && overflow.height.isFinite)
        #expect(overflow.x + overflow.width <= 1.0001)
        #expect(overflow.y + overflow.height <= 1.0001)

        let crop = NormalizedCropRect(x: 0.2, y: 0.2, width: 0.6, height: 0.6)
        let mapped = crop.mappingImagePointToVisible(BoardPoint(x: .nan, y: 0.5))
        #expect(mapped.x.isFinite && mapped.y.isFinite)
        #expect(mapped.x >= 0.0 && mapped.x <= 1.0)
        #expect(mapped.y >= 0.0 && mapped.y <= 1.0)
    }

    @Test("EditorialLayoutSolver reflow has strict weak ordering and Tidy preserves locked nodes with zero drift")
    func layoutSolverOrderingAndZeroDriftTidy() {
        // 18 staggered nodes with 22pt vertical steps (previously triggered non-transitive epsilon sort cycles)
        var staggered: [BoardNode] = []
        for idx in 0..<18 {
            staggered.append(
                BoardNode(
                    kind: .note(title: "N\(idx)", text: "Item \(idx)", style: .paper, fontSize: 13),
                    frame: BoardRect(x: Double((idx % 5) * 140), y: Double(idx * 22), width: 160, height: 120),
                    zIndex: idx
                )
            )
        }
        let groupFrame = BoardRect(x: 0, y: 0, width: 640, height: 520)
        let reflowed = EditorialLayoutSolver.reflowNodesInsideGroupFrame(
            groupRect: groupFrame,
            childNodes: staggered,
            assetsByID: [:]
        )
        #expect(reflowed.count == staggered.count)
        for rect in reflowed.values {
            #expect(rect.x.isFinite && rect.y.isFinite && rect.width > 0 && rect.height > 0)
        }

        // Zero cumulative drift across repeated Tidy clicks + locked node stays untouched
        let lockedOrigin = BoardRect(x: 780, y: 420, width: 200, height: 160)
        let lockedNode = BoardNode(
            kind: .note(title: "Locked", text: "Stay put", style: .warm, fontSize: 13),
            frame: lockedOrigin,
            zIndex: 10,
            isLocked: true
        )
        let freeNodes: [BoardNode] = (0..<4).map { idx in
            BoardNode(
                kind: .note(title: "Card \(idx)", text: "Body", style: .paper, fontSize: 13),
                frame: BoardRect(x: 120 + Double(idx) * 210, y: 90 + Double(idx % 2) * 55, width: 180, height: 140),
                zIndex: idx
            )
        }
        let doc = MoodboardDocument(
            title: "Tidy Drift Check",
            mode: .freeform,
            nodes: freeNodes + [lockedNode]
        )

        let pass1 = EditorialLayoutSolver.tidyNodesInFreeform(document: doc, selectedNodeIDs: [], assetsByID: [:])
        let pass2 = EditorialLayoutSolver.tidyNodesInFreeform(document: pass1, selectedNodeIDs: [], assetsByID: [:])
        let pass3 = EditorialLayoutSolver.tidyNodesInFreeform(document: pass2, selectedNodeIDs: [], assetsByID: [:])

        let lockedAfter = pass3.nodes.first { $0.id == lockedNode.id }
        #expect(lockedAfter?.frame == lockedOrigin)

        func unlockedOrigin(_ board: MoodboardDocument) -> (Double, Double) {
            let unlocked = board.nodes.filter { !$0.isLocked }
            return (unlocked.map(\.frame.x).min() ?? 0, unlocked.map(\.frame.y).min() ?? 0)
        }
        let (x1, y1) = unlockedOrigin(pass1)
        let (x2, y2) = unlockedOrigin(pass2)
        let (x3, y3) = unlockedOrigin(pass3)
        #expect(abs(x2 - x1) < 0.01 && abs(y2 - y1) < 0.01)
        #expect(abs(x3 - x1) < 0.01 && abs(y3 - y1) < 0.01)
    }

    @Test("ConnectorGeometry handles rotation, flips, rotated hit-testing, and path distances")
    func connectorGeometryRotationFlipAndDistance() {
        let rect = CGRect(x: 100, y: 200, width: 100, height: 200) // center (150, 300)
        // Rotating top midpoint (150, 200) clockwise by 90° around (150, 300) lands on (250, 300)
        let rotatedTop = ConnectorGeometry.anchorPoint(
            for: rect,
            anchor: .top,
            towards: rect,
            rotationDegrees: 90
        )
        #expect(abs(rotatedTop.x - 250) < 0.5)
        #expect(abs(rotatedTop.y - 300) < 0.5)

        // Flip horizontal/vertical mirrors normalized pinpoint coords
        let flippedPin = ConnectorGeometry.anchorPoint(
            for: rect,
            anchor: .auto,
            normalizedPoint: BoardPoint(x: 0.2, y: 0.25),
            towards: rect,
            rotationDegrees: 0,
            flipHorizontal: true,
            flipVertical: true
        )
        #expect(abs(flippedPin.x - (100 + 0.8 * 100)) < 0.5)
        #expect(abs(flippedPin.y - (200 + 0.75 * 200)) < 0.5)

        // Rotated containsPoint: 100x200 rotated 90° becomes 200x100 around (150, 300)
        #expect(ConnectorGeometry.containsPoint(CGPoint(x: 235, y: 300), in: rect, rotationDegrees: 90))
        #expect(!ConnectorGeometry.containsPoint(CGPoint(x: 150, y: 215), in: rect, rotationDegrees: 90))

        // Distance to straight, elbow, and curved connector paths
        let s = CGPoint(x: 0, y: 0)
        let e = CGPoint(x: 200, y: 100)
        let c1 = CGPoint(x: 80, y: 0)
        let c2 = CGPoint(x: 120, y: 100)
        #expect(ConnectorGeometry.distanceToConnector(point: CGPoint(x: 100, y: 50), start: s, end: e, c1: c1, c2: c2, style: .straight) < 0.5)
        #expect(ConnectorGeometry.distanceToConnector(point: CGPoint(x: 100, y: 50), start: s, end: e, c1: c1, c2: c2, style: .elbow) < 0.5)
        let curvedMid = ConnectorGeometry.midpoint(start: s, end: e, c1: c1, c2: c2, style: .curved)
        #expect(ConnectorGeometry.distanceToConnector(point: curvedMid, start: s, end: e, c1: c1, c2: c2, style: .curved) < 1.5)
        #expect(ConnectorGeometry.distanceToConnector(point: CGPoint(x: 0, y: 200), start: s, end: e, c1: c1, c2: c2, style: .curved) > 50)
    }

    @Test("FigmaBridgeExporter sanitizes NaN geometry, avoids crop tile collisions, uses thumbnail extension, and preserves pinpoint connectors")
    func figmaBridgeExportHardening() async throws {
        let workDir = try BackendFixture.directory()
        defer { try? FileManager.default.removeItem(at: workDir) }

        let thumbURL = workDir.appending(path: "fallback-thumb.jpg")
        try writeJPEGImage(width: 400, height: 300, red: 0.25, green: 0.55, blue: 0.80, to: thumbURL)

        let asset = AssetRecord(
            title: "Animated Reference",
            fileName: "sample.gif",
            mediaKind: .animatedImage,
            mimeType: "image/gif",
            pixelWidth: 400,
            pixelHeight: 300
        )

        let cropA = NormalizedCropRect(x: 0.0, y: 0.0, width: 0.5, height: 0.5)
        let cropB = NormalizedCropRect(x: 0.5, y: 0.5, width: 0.5, height: 0.5)

        let nodeA = BoardNode(
            kind: .assetRef(assetID: asset.id, crop: cropA, weight: 1, autoplayLoop: false),
            frame: BoardRect(x: 0, y: 0, width: 200, height: 150),
            zIndex: 1,
            rotationDegrees: .nan
        )
        let nodeB = BoardNode(
            kind: .assetRef(assetID: asset.id, crop: cropB, weight: 1, autoplayLoop: false),
            frame: BoardRect(x: 240, y: 0, width: 200, height: 150),
            zIndex: 2
        )
        let connector = BoardConnector(
            fromNodeID: nodeA.id,
            fromAnchor: .auto,
            fromNormalizedPoint: BoardPoint(x: 0.75, y: 0.5),
            toNodeID: nodeB.id,
            toAnchor: .auto,
            toNormalizedPoint: BoardPoint(x: 0.25, y: 0.4),
            label: "Detail Pin",
            style: .curved
        )
        let board = MoodboardDocument(
            title: "Bridge Hardening",
            mode: .freeform,
            nodes: [nodeA, nodeB],
            connectors: [connector]
        )

        let outURL = workDir.appending(path: "nested/dir/hardened.charkleboard")
        let report = try await FigmaBridgeExporter.exportBundle(
            document: board,
            assetsByID: [asset.id: asset],
            options: MoodboardExportOptions(includeAnnotations: true, includePaletteStrip: false, darkAppearance: false),
            resolveOriginalURL: { _ in nil },
            resolveThumbnailURL: { id, _ in id == asset.id ? thumbURL : nil },
            to: outURL
        )
        #expect(report.imageCount == 2)
        #expect(report.connectorCount == 1)

        let unpackDir = workDir.appending(path: "unpacked", directoryHint: .isDirectory)
        let unzip = Process()
        unzip.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        unzip.arguments = ["-x", "-k", outURL.path, unpackDir.path]
        try unzip.run()
        unzip.waitUntilExit()
        #expect(unzip.terminationStatus == 0)
        #expect(!FileManager.default.fileExists(atPath: unpackDir.appending(path: "__MACOSX").path))

        let jsonData = try Data(contentsOf: unpackDir.appending(path: "board.json"))
        let root = try #require(try JSONSerialization.jsonObject(with: jsonData) as? [String: Any])

        // 1. Originals entry must preserve fallback thumbnail's .jpg extension (never .gif)
        let originals = try #require(root["originals"] as? [[String: Any]])
        let firstOrigFile = try #require(originals.first?["file"] as? String)
        #expect(firstOrigFile.hasSuffix(".jpg"))
        #expect(!firstOrigFile.hasSuffix(".gif"))

        // 2. Both cropped nodes have distinct, non-colliding tile files & NaN rotation sanitized to 0
        let objects = try #require(root["objects"] as? [[String: Any]])
        let images = objects.filter { $0["kind"] as? String == "image" }
        #expect(images.count == 2)
        let nodeAObj = try #require(images.first { $0["id"] as? String == nodeA.id.uuidString })
        let geomA = try #require(nodeAObj["geometry"] as? [String: Any])
        #expect(geomA["angle"] as? Double == 0)

        let tileFiles: [String] = images.compactMap { obj in
            ((obj["image"] as? [String: Any])?["tiles"] as? [[String: Any]])?.first?["file"] as? String
        }
        #expect(tileFiles.count == 2)
        #expect(Set(tileFiles).count == 2)
        for rel in tileFiles {
            #expect(FileManager.default.fileExists(atPath: unpackDir.appending(path: rel).path))
        }

        // 3. Pinpoint connector endpoints exported
        let connectors = try #require(root["connectors"] as? [[String: Any]])
        let firstConn = try #require(connectors.first)
        let fromPin = try #require(firstConn["fromNormalizedPoint"] as? [String: Any])
        let toPin = try #require(firstConn["toNormalizedPoint"] as? [String: Any])
        #expect(abs((fromPin["x"] as? Double ?? -1) - 0.75) < 0.001)
        #expect(abs((toPin["y"] as? Double ?? -1) - 0.40) < 0.001)
    }

    @Test("VisualGroundingEngine unmaps letterboxed >5.6:1 images and accepts negative matches without region box")
    func visualGroundingLetterboxUnmapAndNegativeMatch() async throws {
        // 1. Extreme 1:8 vertical image (160x1280) gets horizontally padded to 280px width
        let tallImage = try makeSolidCGImage(width: 160, height: 1280, red: 0.15, green: 0.25, blue: 0.45)
        let prepared = try #require(TypeSafeImagePreparer.prepare(from: tallImage, targetLongSide: 768))
        #expect(prepared.canvasWidth == TypeSafeImagePreparer.minSide)
        #expect(prepared.contentRect.width < 0.9)

        let unmappedFull = TypeSafeImagePreparer.unmapBox(prepared.contentRect, fromContentRect: prepared.contentRect)
        #expect(abs(unmappedFull.x) < 0.02)
        #expect(abs(unmappedFull.y) < 0.02)
        #expect(abs(unmappedFull.width - 1.0) < 0.03)
        #expect(abs(unmappedFull.height - 1.0) < 0.03)

        // 2. Negative match (`present = 0.04`, no `"region"` key) returns `found == false` cleanly instead of throwing
        AuditMoodboardMockURLProtocol.handler = { req in
            let json = """
            {
              "model": "jev-1.14.0",
              "answers": {
                "present": { "type": "noul", "noul": 0.04 }
              }
            }
            """
            let resp = HTTPURLResponse(url: req.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
            return (resp, Data(json.utf8))
        }
        defer { AuditMoodboardMockURLProtocol.handler = nil }

        let engine = VisualGroundingEngine(session: makeAuditMockSession())
        let config = TypeSafeExperimentalConfig(enabled: true, minConfidence: 0.60, lowConfidencePadding: 0.05)
        let res = try await engine.locateRegion(
            query: "absent object",
            imageData: prepared.jpegData,
            cgImage: nil,
            config: config,
            apiKey: "test-key"
        )
        #expect(res.found == false)
        #expect(res.crop == .full)
        #expect(res.presenceProbability.isFinite)
    }

    @Test("MoodboardAgentHarness propagates CancellationError and falls back to offline curator after failed repair")
    func harnessCancellationAndFailedRepairFallback() async throws {
        let (dir, db, media, _) = try await makeTinyLibrary()
        defer { try? FileManager.default.removeItem(at: dir) }

        let harness = MoodboardAgentHarness(database: db, media: media)
        let request = MoodboardCurationRequest(prompt: "warm editorial", preferredCount: 2, candidateCount: 2)

        // 1. Cancellation must propagate instead of silently falling back
        let cancellingProvider = FakeCloudAIProvider { _, _, _ in
            throw CancellationError()
        }
        var didThrowCancellation = false
        do {
            _ = try await harness.curate(request: request, provider: cancellingProvider)
        } catch is CancellationError {
            didThrowCancellation = true
        }
        #expect(didThrowCancellation)

        // 2. Two consecutive invalid JSON responses must fall back cleanly to offline curator (non-empty board)
        let brokenProvider = FakeCloudAIProvider { _, _, _ in
            "not valid json at all"
        }
        let proposal = try await harness.curate(request: request, provider: brokenProvider)
        #expect(proposal.usedCloudAI == false)
        #expect(!proposal.draftDocument.nodes.isEmpty)
        #expect(!proposal.primaryMatches.isEmpty)
    }

    @Test("CharkleAgentTools preserves locked node transforms, user notes, and valid connectors while pruning orphans on refinement")
    func agentToolsRefinementPreservationAndOrphanPruning() async throws {
        let (dir, db, media, assets) = try await makeTinyLibrary()
        defer { try? FileManager.default.removeItem(at: dir) }

        let tools = CharkleAgentTools(database: db, media: media)
        let assetA = assets[0]
        let assetB = assets[1]
        let customCrop = NormalizedCropRect(x: 0.15, y: 0.2, width: 0.5, height: 0.5)

        let existingAssetANode = BoardNode(
            kind: .assetRef(assetID: assetA.id, crop: customCrop, weight: 2, autoplayLoop: false),
            frame: BoardRect(x: 40, y: 60, width: 320, height: 240),
            zIndex: 1,
            rotationDegrees: 18,
            flipHorizontal: true,
            isLocked: true
        )
        let existingAssetBNode = BoardNode(
            kind: .assetRef(assetID: assetB.id, crop: nil, weight: 1, autoplayLoop: false),
            frame: BoardRect(x: 400, y: 60, width: 240, height: 200),
            zIndex: 2
        )
        let userNoteNode = BoardNode(
            kind: .note(title: "My Custom Note", text: "Keep this memo", style: .warm, fontSize: 14),
            frame: BoardRect(x: 40, y: 340, width: 220, height: 140),
            zIndex: 3
        )
        let validConnector = BoardConnector(
            fromNodeID: userNoteNode.id,
            toNodeID: existingAssetANode.id,
            label: "Still Valid"
        )
        let orphanConnector = BoardConnector(
            fromNodeID: existingAssetANode.id,
            toNodeID: existingAssetBNode.id,
            label: "Dropped Target"
        )

        let existingBoard = MoodboardDocument(
            title: "Original Board",
            mode: .freeform,
            nodes: [existingAssetANode, existingAssetBNode, userNoteNode],
            connectors: [validConnector, orphanConnector]
        )

        let request = MoodboardCurationRequest(
            prompt: "keep only terracotta",
            preferredCount: 2,
            candidateCount: 2,
            useFreeformLayout: true,
            includeCuratorNotes: false,
            lockedAssetIDs: [assetA.id],
            existingBoard: existingBoard,
            refinementInstruction: "keep asset A"
        )
        let plan = AgentBoardPlan(
            boardTitle: "Refined Board",
            boardSubtitle: "Focused",
            curatorNote: nil,
            recommendedLayout: .magazine,
            sections: [
                AgentBoardPlan.SectionSpec(
                    title: "Hero",
                    tint: .sand,
                    rationale: "",
                    picks: [AgentBoardPlan.SlotPick(slot: 1, weight: 2, reason: "Keep A")]
                )
            ],
            candidatePicks: [],
            rejectedNote: nil,
            visualInsights: []
        )
        let recall = AgentRecallResult(
            eligibleTotal: assets.count,
            candidates: assets,
            scoresByID: Dictionary(uniqueKeysWithValues: assets.map { ($0.id, ScoredAsset(asset: $0, score: 0.9, matchReasons: ["test"])) }),
            folderPathByID: [:]
        )

        let compiled = try await tools.compileAndVerifyBoard(
            plan: plan,
            slotToAsset: [1: assetA, 2: assetB],
            request: request,
            recall: recall
        )

        let retainedA = try #require(compiled.document.nodes.first { $0.referencedAssetID == assetA.id })
        #expect(retainedA.id == existingAssetANode.id)
        #expect(retainedA.isLocked == true)
        #expect(retainedA.rotationDegrees == 18)
        #expect(retainedA.flipHorizontal == true)
        if case .assetRef(_, let crop, _, _) = retainedA.kind {
            #expect(crop == customCrop)
        } else {
            Issue.record("Expected assetRef node")
        }

        // User note survives refinement
        #expect(compiled.document.nodes.contains { $0.id == userNoteNode.id })
        // Valid connector survives; connector pointing to removed assetB is pruned
        #expect(compiled.document.connectors.contains { $0.id == validConnector.id })
        #expect(!compiled.document.connectors.contains { $0.id == orphanConnector.id })
    }

    @Test("BoardImageRenderer and ContactSheetRenderer bound extreme dimensions safely")
    func boardAndContactSheetRendererBounds() throws {
        let workDir = try BackendFixture.directory()
        defer { try? FileManager.default.removeItem(at: workDir) }

        let thumbURL = workDir.appending(path: "tile.jpg")
        try writeJPEGImage(width: 240, height: 180, red: 0.72, green: 0.42, blue: 0.28, to: thumbURL)

        let asset = AssetRecord(
            title: "Tile",
            fileName: "tile.jpg",
            mediaKind: .image,
            mimeType: "image/jpeg",
            pixelWidth: 240,
            pixelHeight: 180
        )

        // 1. Tall board (>7500pt vertical span) scales cleanly within 4600px cap with crop, rotation, connector & ink
        let topNode = BoardNode(
            kind: .assetRef(assetID: asset.id, crop: NormalizedCropRect(x: 0.1, y: 0.1, width: 0.8, height: 0.8), weight: 1, autoplayLoop: false),
            frame: BoardRect(x: 0, y: 0, width: 300, height: 240),
            zIndex: 1,
            rotationDegrees: 12,
            flipHorizontal: true
        )
        let bottomNode = BoardNode(
            kind: .note(title: "Bottom", text: "Deep card", style: .sage, fontSize: 14),
            frame: BoardRect(x: 0, y: 7600, width: 320, height: 240),
            zIndex: 2
        )
        let tallBoard = MoodboardDocument(
            title: "Tall Board",
            mode: .freeform,
            nodes: [topNode, bottomNode],
            connectors: [BoardConnector(fromNodeID: topNode.id, toNodeID: bottomNode.id, toNormalizedPoint: BoardPoint(x: 0.5, y: 0.2))],
            inkStrokes: [InkStroke(points: [InkStrokePoint(x: 20, y: 20), InkStrokePoint(x: 200, y: 120)], colorHex: "#C85A32", lineWidth: 3)]
        )
        let pngData = try #require(
            BoardImageRenderer.renderPNG(
                document: tallBoard,
                assetsByID: [asset.id: asset],
                thumbnailURL: { id in id == asset.id ? thumbURL : nil },
                options: BoardImageRenderer.RenderOptions(canvasWidth: 1200, darkAppearance: true)
            )
        )
        let pngSource = try #require(CGImageSourceCreateWithData(pngData as CFData, nil))
        let pngImage = try #require(CGImageSourceCreateImageAtIndex(pngSource, 0, nil))
        #expect(pngImage.width == 1200)
        #expect(pngImage.height <= 4600)

        // 2. ContactSheetRenderer clamps extreme maxCanvasWidth without OOM
        let entries = (1...8).map { slot in
            ContactSheetRenderer.Entry(slot: slot, asset: asset, thumbnailURL: thumbURL)
        }
        let sheet = try #require(ContactSheetRenderer.render(entries: entries, maxCanvasWidth: 99_999))
        #expect(sheet.width <= 2560)
        #expect(sheet.height <= 4096)
        let jpegSource = try #require(CGImageSourceCreateWithData(sheet.jpegData as CFData, nil))
        let jpegImage = try #require(CGImageSourceCreateImageAtIndex(jpegSource, 0, nil))
        #expect(jpegImage.width == sheet.width)
        #expect(jpegImage.height == sheet.height)
    }
}
