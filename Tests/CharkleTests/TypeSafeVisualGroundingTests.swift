import AppKit
@testable import CharkleCanvas
@testable import CharkleCore
import CoreGraphics
import Foundation
import Testing

private final class TypeSafeMockURLProtocol: URLProtocol, @unchecked Sendable {
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

private func makeMockSession() -> URLSession {
    let config = URLSessionConfiguration.ephemeral
    config.protocolClasses = [TypeSafeMockURLProtocol.self]
    return URLSession(configuration: config)
}

private func makeSyntheticSubjectImage(width: Int = 200, height: Int = 200) throws -> CGImage {
    let colorSpace = CGColorSpaceCreateDeviceRGB()
    let bitmapInfo = CGImageAlphaInfo.premultipliedLast.rawValue
    guard let ctx = CGContext(
        data: nil,
        width: width,
        height: height,
        bitsPerComponent: 8,
        bytesPerRow: width * 4,
        space: colorSpace,
        bitmapInfo: bitmapInfo
    ) else {
        throw LibraryDatabaseError("Failed to create synthetic CGContext")
    }
    // White background filling 84% of pixels
    ctx.setFillColor(CGColor(red: 0.98, green: 0.98, blue: 0.98, alpha: 1))
    ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))

    // Vivid crimson subject centered in [0.30..0.70] x [0.30..0.70]
    ctx.setFillColor(CGColor(red: 0.86, green: 0.14, blue: 0.18, alpha: 1))
    ctx.fill(CGRect(x: width * 3 / 10, y: height * 3 / 10, width: width * 4 / 10, height: height * 4 / 10))

    guard let image = ctx.makeImage() else {
        throw LibraryDatabaseError("Failed to create synthetic CGImage")
    }
    return image
}

private func readHTTPBody(_ request: URLRequest) -> Data {
    if let body = request.httpBody { return body }
    guard let stream = request.httpBodyStream else { return Data() }
    stream.open()
    defer { stream.close() }
    var data = Data()
    var buffer = [UInt8](repeating: 0, count: 4096)
    while stream.hasBytesAvailable {
        let count = stream.read(&buffer, maxLength: buffer.count)
        if count > 0 { data.append(buffer, count: count) }
        else { break }
    }
    return data
}

@Suite("TypeSafe System One (Jev) Visual Grounding & Pinpoint Canvas", .serialized)
struct TypeSafeVisualGroundingTests {

    @Test("Multipart request follows TypeSafe wire contract and sends Danger-Zone header")
    func sendsCompliantMultipartRequest() async throws {
        var capturedAuth: String?
        var capturedDangerHeader: String?
        var capturedContentType: String?
        var capturedBodyString: String = ""

        TypeSafeMockURLProtocol.handler = { req in
            capturedAuth = req.value(forHTTPHeaderField: "Authorization")
            capturedDangerHeader = req.value(forHTTPHeaderField: TypeSafeSystemOneClient.imagesDangerZoneHeader)
            capturedContentType = req.value(forHTTPHeaderField: "Content-Type")
            let body = readHTTPBody(req)
            capturedBodyString = String(decoding: body, as: UTF8.self)

            let json = """
            {
              "model": "jev-1.14.0",
              "answers": {
                "present": {"type": "noul", "noul": 0.96},
                "region": {
                  "type": "box",
                  "box": {"top": 0.25, "bottom": 0.80, "left": 0.40, "right": 0.85},
                  "confidence": 0.91
                }
              },
              "usage": {"input_tokens": 290, "output_tokens": 21}
            }
            """
            let resp = HTTPURLResponse(url: req.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
            return (resp, Data(json.utf8))
        }

        let engine = VisualGroundingEngine(session: makeMockSession())
        let config = TypeSafeExperimentalConfig(enabled: true, minConfidence: 0.60, lowConfidencePadding: 0.05)
        let result = try await engine.locateRegion(
            query: "the brass lamp",
            imageData: Data([0xFF, 0xD8, 0xFF, 0xE0]),
            imageFormat: "jpg",
            cgImage: nil,
            config: config,
            apiKey: "test-secret-key"
        )

        #expect(capturedAuth == "Bearer test-secret-key")
        #expect(capturedDangerHeader == "true")
        #expect(capturedContentType?.hasPrefix("multipart/form-data; boundary=") == true)
        #expect(capturedBodyString.contains("name=\"request\""))
        #expect(capturedBodyString.contains("Content-Type: application/json"))
        #expect(capturedBodyString.contains("name=\"photo\"; filename=\"photo.jpg\""))
        #expect(capturedBodyString.contains("Content-Type: image/jpeg"))

        #expect(result.found == true)
        #expect(result.source == .typeSafeJev)
        #expect(result.model == "jev-1.14.0")
        #expect(result.didApplyPadding == false)
        #expect(abs(result.crop.x - 0.40) < 0.001)
        #expect(abs(result.crop.y - 0.25) < 0.001)
        #expect(abs(result.crop.width - 0.45) < 0.001)
        #expect(abs(result.crop.height - 0.55) < 0.001)
    }

    @Test("Low confidence Box automatically pads outward and companion Noul gates absent objects")
    func appliesLowConfidencePaddingAndNoulGating() async throws {
        // Case 1: Low confidence -> padded outward & clamped inside [0, 1]
        TypeSafeMockURLProtocol.handler = { req in
            let json = """
            {
              "model": "jev-1.14.0",
              "answers": {
                "present": {"type": "noul", "noul": 0.88},
                "region": {
                  "type": "box",
                  "box": {"top": 0.02, "bottom": 0.50, "left": 0.60, "right": 0.98},
                  "confidence": 0.42
                }
              }
            }
            """
            let resp = HTTPURLResponse(url: req.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
            return (resp, Data(json.utf8))
        }

        let engine = VisualGroundingEngine(session: makeMockSession())
        let config = TypeSafeExperimentalConfig(enabled: true, minConfidence: 0.60, lowConfidencePadding: 0.05)
        let padded = try await engine.locateRegion(
            query: "logo badge",
            imageData: Data([0xFF, 0xD8, 0xFF]),
            cgImage: nil,
            config: config,
            apiKey: "key"
        )
        #expect(padded.found == true)
        #expect(padded.didApplyPadding == true)
        #expect(abs(padded.crop.y - 0.0) < 0.001)
        #expect(abs(padded.crop.maxX - 1.0) < 0.001)
        #expect(abs(padded.crop.x - 0.55) < 0.001)
        #expect(abs(padded.crop.maxY - 0.55) < 0.001)

        // Case 2: Low companion Noul probability -> marked not found even though Box always returns coordinates
        TypeSafeMockURLProtocol.handler = { req in
            let json = """
            {
              "model": "jev-1.14.0",
              "answers": {
                "present": {"type": "noul", "noul": 0.12},
                "region": {
                  "type": "box",
                  "box": {"top": 0.1, "bottom": 0.3, "left": 0.1, "right": 0.3},
                  "confidence": 0.25
                }
              }
            }
            """
            let resp = HTTPURLResponse(url: req.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
            return (resp, Data(json.utf8))
        }

        let absent = try await engine.locateRegion(
            query: "unicorn",
            imageData: Data([0xFF, 0xD8, 0xFF]),
            cgImage: nil,
            config: config,
            apiKey: "key"
        )
        #expect(absent.found == false)
        #expect(absent.presenceProbability < 0.2)
    }

    @Test("Clean content bounds detects noisy chrome vs clean artwork")
    func detectsCleanBounds() async throws {
        TypeSafeMockURLProtocol.handler = { req in
            let json = """
            {
              "model": "jev-1.14.0",
              "answers": {
                "has_noise": {"type": "noul", "noul": 0.91},
                "core_content": {
                  "type": "box",
                  "box": {"top": 0.14, "bottom": 0.92, "left": 0.08, "right": 0.92},
                  "confidence": 0.87
                }
              }
            }
            """
            let resp = HTTPURLResponse(url: req.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
            return (resp, Data(json.utf8))
        }

        let engine = VisualGroundingEngine(session: makeMockSession())
        let config = TypeSafeExperimentalConfig(enabled: true)
        let noisy = try await engine.detectCleanContentBounds(
            imageData: Data([0xFF, 0xD8, 0xFF]),
            cgImage: nil,
            config: config,
            apiKey: "key"
        )
        #expect(noisy.hasNoise == true)
        let crop = try #require(noisy.recommendedCrop)
        #expect(abs(crop.y - 0.14) < 0.001)
        #expect(abs(crop.width - 0.84) < 0.001)
    }

    @Test("Subject-aware palette extraction isolates crimson subject from dominant white background")
    func extractsSubjectPaletteWithoutBackgroundPollution() async throws {
        let synthetic = try makeSyntheticSubjectImage()

        // Full image is 84% white -> top swatch is bright white
        let fullPalette = ColorExtractor.extractDominantColors(from: synthetic, crop: nil, count: 3)
        let fullTop = try #require(fullPalette.first)
        #expect(fullTop.l > 85.0)

        // With Jev Box around [0.30..0.70] x [0.30..0.70] -> top swatch becomes vivid crimson (high positive a*)
        TypeSafeMockURLProtocol.handler = { req in
            let json = """
            {
              "model": "jev-1.14.0",
              "answers": {
                "present": {"type": "noul", "noul": 0.99},
                "region": {
                  "type": "box",
                  "box": {"top": 0.30, "bottom": 0.70, "left": 0.30, "right": 0.70},
                  "confidence": 0.95
                }
              }
            }
            """
            let resp = HTTPURLResponse(url: req.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
            return (resp, Data(json.utf8))
        }

        let engine = VisualGroundingEngine(session: makeMockSession())
        let config = TypeSafeExperimentalConfig(enabled: true)
        let (colors, region) = try await engine.extractSubjectPalette(
            query: nil,
            imageData: Data([0xFF, 0xD8, 0xFF]),
            cgImage: synthetic,
            colorCount: 3,
            config: config,
            apiKey: "key"
        )
        #expect(region.found == true)
        let subjectTop = try #require(colors.first)
        #expect(subjectTop.a > 40.0) // Crimson sits strongly on +a* axis in CIELAB
        #expect(subjectTop.l < 70.0)
    }

    @Test("BoardConnector backward-compatible decoding and ConnectorGeometry pinpoint target math")
    func pinpointConnectorGeometryAndCompatibility() throws {
        // Legacy JSON without normalized points decodes cleanly
        let legacyJSON = """
        {
          "id": "11111111-1111-1111-1111-111111111111",
          "fromNodeID": "22222222-2222-2222-2222-222222222222",
          "fromAnchor": "trailing",
          "toNodeID": "33333333-3333-3333-3333-333333333333",
          "toAnchor": "auto",
          "colorHex": "#5C6672",
          "style": "curved",
          "dashed": false,
          "updatedAt": 0
        }
        """
        let decoded = try JSONDecoder().decode(BoardConnector.self, from: Data(legacyJSON.utf8))
        #expect(decoded.fromNormalizedPoint == nil)
        #expect(decoded.toNormalizedPoint == nil)

        // Pinpoint connector lands precisely at normalized point inside target rect
        let fromRect = CGRect(x: 400, y: 100, width: 200, height: 120)
        let toRect = CGRect(x: 100, y: 50, width: 200, height: 200)
        let (_, end, _, _) = ConnectorGeometry.resolvePathPoints(
            fromRect: fromRect,
            fromAnchor: .leading,
            toRect: toRect,
            toAnchor: .auto,
            toNormalizedPoint: BoardPoint(x: 0.75, y: 0.25),
            style: .curved
        )
        #expect(abs(end.x - 250.0) < 0.01)
        #expect(abs(end.y - 100.0) < 0.01)

        // Mapping full-image point through an active crop rect
        let crop = NormalizedCropRect(x: 0.25, y: 0.25, width: 0.5, height: 0.5)
        let mapped = crop.mappingImagePointToVisible(BoardPoint(x: 0.50, y: 0.50))
        #expect(abs(mapped.x - 0.50) < 0.001)
        #expect(abs(mapped.y - 0.50) < 0.001)
    }

    @Test("TypeSafe config persists in LiveCharkleEngine and offline Vision fallback works without API key")
    func liveEngineConfigAndOfflineFallback() async throws {
        let tempDir = FileManager.default.temporaryDirectory
            .appending(path: "charkle-ts-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let media = try MediaPipeline(directory: tempDir)
        let db = try LibraryDatabase(url: tempDir.appending(path: "Library.sqlite3"))
        let engine = LiveCharkleEngine(database: db, media: media)

        let custom = TypeSafeExperimentalConfig(
            enabled: true,
            baseURL: "https://api.typesafe.ai",
            model: "jev-1.14.0",
            minConfidence: 0.70,
            lowConfidencePadding: 0.06
        )
        try await engine.saveTypeSafeConfig(custom, apiKey: nil)
        let reloaded = await engine.typeSafeConfig()
        #expect(reloaded.enabled == true)
        #expect(reloaded.model == "jev-1.14.0")
        #expect(abs(reloaded.minConfidence - 0.70) < 0.001)

        // Offline Vision saliency fallback works when disabled
        let synthetic = try makeSyntheticSubjectImage()
        let grounding = VisualGroundingEngine()
        let offline = try await grounding.locateRegion(
            query: nil,
            imageData: Data(),
            cgImage: synthetic,
            config: TypeSafeExperimentalConfig(enabled: false),
            apiKey: nil
        )
        #expect(offline.source == .appleVisionSaliency)
    }

    @Test("TypeSafeImagePreparer normalizes tiny and panoramic images strictly inside 280...1568 px")
    func normalizesImagesToTypeSafeBounds() throws {
        let tiny = try makeSyntheticSubjectImage(width: 64, height: 64)
        let tinyJPEG = try #require(TypeSafeImagePreparer.prepareJPEG(from: tiny, targetLongSide: 512))
        let tinyRep = try #require(NSBitmapImageRep(data: tinyJPEG))
        #expect(tinyRep.pixelsWide >= 280 && tinyRep.pixelsWide <= 1568)
        #expect(tinyRep.pixelsHigh >= 280 && tinyRep.pixelsHigh <= 1568)

        let pano = try makeSyntheticSubjectImage(width: 2400, height: 180)
        let panoJPEG = try #require(TypeSafeImagePreparer.prepareJPEG(from: pano, targetLongSide: 1200))
        let panoRep = try #require(NSBitmapImageRep(data: panoJPEG))
        #expect(panoRep.pixelsWide >= 280 && panoRep.pixelsWide <= 1568)
        #expect(panoRep.pixelsHigh >= 280 && panoRep.pixelsHigh <= 1568)
    }

    @Test("Visual semantic search batches Score fan-out and ranks matching untagged assets first")
    func visualSemanticSearchScoresBatch() async throws {
        let idA = UUID()
        let idB = UUID()

        TypeSafeMockURLProtocol.handler = { req in
            let json = """
            {
              "model": "jev-1.14.0",
              "answers": {
                "item_0": {
                  "type": "score",
                  "score": 0.25,
                  "confidence": 0.90,
                  "probabilities": {"0": 0.8, "1": 0.15, "2": 0.05, "3": 0.0},
                  "legend": {"0": "Unrelated", "3": "Strong"}
                },
                "item_1": {
                  "type": "score",
                  "score": 2.85,
                  "confidence": 0.94,
                  "probabilities": {"0": 0.0, "1": 0.0, "2": 0.15, "3": 0.85},
                  "legend": {"0": "Unrelated", "3": "Strong"}
                }
              }
            }
            """
            let resp = HTTPURLResponse(url: req.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
            return (resp, Data(json.utf8))
        }

        let engine = VisualGroundingEngine(session: makeMockSession())
        let config = TypeSafeExperimentalConfig(enabled: true)
        let scores = try await engine.scoreCandidatesForQuery(
            query: "京都雨夜霓虹",
            candidates: [
                VisualCandidateInput(assetID: idA, title: "IMG_001", imageData: Data([0xFF, 0xD8, 0xFF])),
                VisualCandidateInput(assetID: idB, title: "IMG_002", imageData: Data([0xFF, 0xD8, 0xFF]))
            ],
            config: config,
            apiKey: "key"
        )
        #expect(scores.count == 2)
        #expect(scores[0].assetID == idB)
        #expect(scores[0].score > 0.9)
        #expect(scores[1].assetID == idA)
        #expect(scores[1].score < 0.2)
    }

    @Test("Inbox closed-set Choice + Companion Noul classifies matching folder and rejects unfit assets")
    func inboxClosedSetChoiceWithCompanionNoul() async throws {
        let fUI = UUID()
        let fType = UUID()
        let options = [
            FolderOptionInput(id: fUI, name: "UI Interfaces", sampleTags: ["glass", "button", "dashboard"]),
            FolderOptionInput(id: fType, name: "Typography", sampleTags: ["serif", "poster", "editorial"])
        ]

        // Case 1: Strong fit -> returns exact folder UUID
        TypeSafeMockURLProtocol.handler = { req in
            let json = """
            {
              "model": "jev-1.14.0",
              "answers": {
                "fits_any": {"type": "noul", "noul": 0.94},
                "folder": {
                  "type": "choice",
                  "choice": "f_0",
                  "confidence": 0.89,
                  "probabilities": {"f_0": 0.93, "f_1": 0.07}
                }
              }
            }
            """
            let resp = HTTPURLResponse(url: req.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
            return (resp, Data(json.utf8))
        }

        let engine = VisualGroundingEngine(session: makeMockSession())
        let config = TypeSafeExperimentalConfig(enabled: true)
        let matched = try await engine.classifyIntoFolders(
            assetTitle: "macOS Liquid Glass toolbar",
            assetTags: [],
            assetNotes: "",
            imageData: Data([0xFF, 0xD8, 0xFF]),
            folders: options,
            config: config,
            apiKey: "key"
        )
        #expect(matched.folderID == fUI)
        #expect(matched.confidence > 0.85)

        // Case 2: Companion Noul says none fit -> stays in Inbox (nil folderID)
        TypeSafeMockURLProtocol.handler = { req in
            let json = """
            {
              "model": "jev-1.14.0",
              "answers": {
                "fits_any": {"type": "noul", "noul": 0.14},
                "folder": {
                  "type": "choice",
                  "choice": "f_1",
                  "confidence": 0.32,
                  "probabilities": {"f_0": 0.45, "f_1": 0.55}
                }
              }
            }
            """
            let resp = HTTPURLResponse(url: req.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
            return (resp, Data(json.utf8))
        }

        let unfit = try await engine.classifyIntoFolders(
            assetTitle: "random receipt scan",
            assetTags: [],
            assetNotes: "",
            imageData: Data([0xFF, 0xD8, 0xFF]),
            folders: options,
            config: config,
            apiKey: "key"
        )
        #expect(unfit.folderID == nil)
        #expect(unfit.fitProbability < 0.2)
    }

    @Test(
        "Live TypeSafe API end-to-end verification (models, Box+Noul, clean bounds, subject palette)",
        .enabled(if: ProcessInfo.processInfo.environment["CHARKLE_LIVE_TYPESAFE_KEY"]?.isEmpty == false)
    )
    func liveTypeSafeEndToEnd() async throws {
        let apiKey = try #require(ProcessInfo.processInfo.environment["CHARKLE_LIVE_TYPESAFE_KEY"])
        let config = TypeSafeExperimentalConfig(
            enabled: true,
            baseURL: "https://api.typesafe.ai",
            model: "jev-latest",
            minConfidence: 0.60,
            lowConfidencePadding: 0.05
        )

        // 1. Verify GET /v1/models
        let client = try TypeSafeSystemOneClient(baseURL: config.baseURL, apiKey: apiKey)
        let models = try await client.listModels()
        #expect(!models.isEmpty)
        print("[LIVE] Models: \(models.map(\.name).joined(separator: ", "))")

        // Build a 640x480 synthetic design screenshot:
        // - Top dark browser bar (y: 0..64)
        // - Light gray desktop margins
        // - Centered cream poster card (x: 110..530, y: 90..430) containing:
        //   * A vivid red circle on the left side of the card (x: 150..270, y: 180..300 -> normalized x: 0.23..0.42, y: 0.375..0.625)
        //   * A deep cobalt square on the right side (x: 360..480, y: 200..320 -> normalized x: 0.56..0.75, y: 0.417..0.667)
        let width = 640
        let height = 480
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        let ctx = try #require(CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: width * 4,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ))
        // Note: CGContext has bottom-left origin; flip vertically so drawing uses top-left coordinates!
        ctx.translateBy(x: 0, y: CGFloat(height))
        ctx.scaleBy(x: 1, y: -1)

        // Outer desktop / browser background
        ctx.setFillColor(CGColor(red: 0.90, green: 0.91, blue: 0.93, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))

        // Browser toolbar chrome at top
        ctx.setFillColor(CGColor(red: 0.16, green: 0.17, blue: 0.20, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: width, height: 58))
        // Traffic light dots
        ctx.setFillColor(CGColor(red: 0.95, green: 0.36, blue: 0.33, alpha: 1))
        ctx.fillEllipse(in: CGRect(x: 16, y: 22, width: 12, height: 12))
        ctx.setFillColor(CGColor(red: 0.98, green: 0.74, blue: 0.24, alpha: 1))
        ctx.fillEllipse(in: CGRect(x: 36, y: 22, width: 12, height: 12))
        ctx.setFillColor(CGColor(red: 0.32, green: 0.78, blue: 0.36, alpha: 1))
        ctx.fillEllipse(in: CGRect(x: 56, y: 22, width: 12, height: 12))
        // Address bar pill
        ctx.setFillColor(CGColor(red: 0.26, green: 0.27, blue: 0.31, alpha: 1))
        ctx.fill(CGRect(x: 120, y: 14, width: 400, height: 28))

        // Inner cream artwork card
        ctx.setFillColor(CGColor(red: 0.98, green: 0.96, blue: 0.92, alpha: 1))
        ctx.fill(CGRect(x: 110, y: 90, width: 420, height: 340))

        // Vivid red circle (left inside card)
        ctx.setFillColor(CGColor(red: 0.88, green: 0.14, blue: 0.18, alpha: 1))
        ctx.fillEllipse(in: CGRect(x: 150, y: 180, width: 120, height: 120))

        // Deep cobalt square (right inside card)
        ctx.setFillColor(CGColor(red: 0.12, green: 0.32, blue: 0.78, alpha: 1))
        ctx.fill(CGRect(x: 360, y: 200, width: 120, height: 120))

        let cgImage = try #require(ctx.makeImage())
        let jpegData = try #require(
            NSBitmapImageRep(cgImage: cgImage).representation(using: .jpeg, properties: [.compressionFactor: 0.90])
        )

        let grounding = VisualGroundingEngine()

        // 2. Scenario 1 & 3b: Semantic locate the red circle (ground truth center ~ x=0.328, y=0.50)
        let redCircle = try await grounding.locateRegion(
            query: "the large red circle",
            imageData: jpegData,
            imageFormat: "jpg",
            cgImage: cgImage,
            config: config,
            apiKey: apiKey
        )
        print("[LIVE] Red circle: found=\(redCircle.found) prob=\(redCircle.presenceProbability) conf=\(String(describing: redCircle.confidence)) raw=(\(redCircle.rawBox.x), \(redCircle.rawBox.y), \(redCircle.rawBox.width), \(redCircle.rawBox.height)) model=\(redCircle.model ?? "nil")")
        #expect(redCircle.found == true)
        #expect(redCircle.rawBox.centerPoint.x < 0.50)
        #expect(redCircle.rawBox.centerPoint.y > 0.25 && redCircle.rawBox.centerPoint.y < 0.75)

        // 3. Companion Noul gating: absent target ("golden retriever dog")
        let absent = try await grounding.locateRegion(
            query: "a golden retriever dog",
            imageData: jpegData,
            imageFormat: "jpg",
            cgImage: cgImage,
            config: config,
            apiKey: apiKey
        )
        print("[LIVE] Absent target: found=\(absent.found) prob=\(absent.presenceProbability)")
        #expect(absent.found == false)

        // 4. Scenario 2: Clean content bounds (exclude browser top bar & outer margins)
        let clean = try await grounding.detectCleanContentBounds(
            imageData: jpegData,
            imageFormat: "jpg",
            cgImage: cgImage,
            config: config,
            apiKey: apiKey
        )
        print("[LIVE] Clean bounds: hasNoise=\(clean.hasNoise) prob=\(clean.noiseProbability) conf=\(String(describing: clean.confidence)) crop=\(String(describing: clean.recommendedCrop))")
        #expect(clean.hasNoise == true)
        let cleanCrop = try #require(clean.recommendedCrop)
        #expect(cleanCrop.y >= 0.08) // Trims the top browser bar!

        // 5. Scenario 3a: Subject-aware palette for the cobalt blue square on the right
        let (blueColors, blueRegion) = try await grounding.extractSubjectPalette(
            query: "the blue square on the right side",
            imageData: jpegData,
            imageFormat: "jpg",
            cgImage: cgImage,
            colorCount: 4,
            config: config,
            apiKey: apiKey
        )
        print("[LIVE] Blue square palette: colors=\(blueColors.map(\.hex).joined(separator: ",")) conf=\(String(describing: blueRegion.confidence)) box=(\(blueRegion.rawBox.x), \(blueRegion.rawBox.y), \(blueRegion.rawBox.width), \(blueRegion.rawBox.height))")
        #expect(blueRegion.found == true)
        #expect(blueRegion.rawBox.maxX > 0.65)
        #expect(blueColors.contains(where: { $0.b < -20.0 })) // Deep cobalt blue detected in subject palette!

        // 6. Phase 2 Live: Visual Semantic Search (Score fan-out on untagged images)
        let darkCardCG = try makeSyntheticSubjectImage(width: 320, height: 320)
        let darkCardJPEG = try #require(TypeSafeImagePreparer.prepareJPEG(from: darkCardCG, targetLongSide: 384))
        let idScreenshot = UUID()
        let idRedBlock = UUID()
        let semanticScores = try await grounding.scoreCandidatesForQuery(
            query: "macOS browser window screenshot with traffic light buttons and dark toolbar",
            candidates: [
                VisualCandidateInput(assetID: idRedBlock, title: "untitled_1", imageData: darkCardJPEG),
                VisualCandidateInput(assetID: idScreenshot, title: "untitled_2", imageData: jpegData)
            ],
            config: config,
            apiKey: apiKey,
            batchSize: 2,
            maxConcurrency: 1
        )
        print("[LIVE] Semantic Search scores: \(semanticScores.map { "\($0.assetID == idScreenshot ? "screenshot" : "redSquare")=\(String(format: "%.2f", $0.score))" }.joined(separator: ", "))")
        #expect(semanticScores.first?.assetID == idScreenshot)

        // 7. Phase 2 Live: Closed-Set Inbox Classification (Choice + Companion Noul)
        let fBrowser = UUID()
        let fFood = UUID()
        let triage = try await grounding.classifyIntoFolders(
            assetTitle: "capture_2026",
            assetTags: [],
            assetNotes: "",
            imageData: jpegData,
            folders: [
                FolderOptionInput(id: fBrowser, name: "Web & UI Screenshots", sampleTags: ["browser", "toolbar", "window"]),
                FolderOptionInput(id: fFood, name: "Food & Recipes", sampleTags: ["cooking", "dessert", "coffee"])
            ],
            config: config,
            apiKey: apiKey
        )
        print("[LIVE] Inbox Triage: folder=\(triage.folderID == fBrowser ? "Web & UI Screenshots" : (triage.folderID == nil ? "Inbox" : "Food")) fit=\(triage.fitProbability) conf=\(triage.confidence)")
        #expect(triage.folderID == fBrowser)
    }
}
