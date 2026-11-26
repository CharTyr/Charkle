import CoreGraphics
import Foundation
import Testing
@testable import CharkleCore

@Suite("Pinterest Spatial Browser, Tray & Board Collection Import")
struct PinterestIntegrationTests {

    // MARK: - JSON Parser & Pin ID Extraction

    @Test("extractPinID parses standard, international, and query-bearing Pinterest URLs")
    func extractPinIDVariants() {
        #expect(PinterestJSONParser.extractPinID(from: "https://www.pinterest.com/pin/123456789012345/") == "123456789012345")
        #expect(PinterestJSONParser.extractPinID(from: "https://jp.pinterest.com/pin/987654321?nic_v3=1a") == "987654321")
        #expect(PinterestJSONParser.extractPinID(from: "https://www.pinterest.co.uk/pin/424242/sent/") == "424242")
        #expect(PinterestJSONParser.extractPinID(from: "https://example.com/pin/123456/") == nil)
        #expect(PinterestJSONParser.extractPinID(from: "https://www.pinterest.com/char/boards/") == nil)
    }

    @Test("parseFeedPage filters promoted ads and extracts multi-tier images, colors, boards, and bookmark")
    func parseHomeFeedFiltersPromotedAndExtractsMetadata() throws {
        let json = """
        {
          "resource_response": {
            "bookmark": "NEXT_CURSOR_PAGE_2",
            "data": [
              {
                "id": "111111111",
                "type": "pin",
                "is_promoted": true,
                "grid_title": "Sponsored Ad",
                "images": {
                  "orig": { "url": "https://i.pinimg.com/originals/ad.jpg", "width": 800, "height": 1000 }
                }
              },
              {
                "id": "222222222",
                "type": "pin",
                "is_promoted": false,
                "grid_title": "Minimal Editorial Poster",
                "description": "Swiss grid typography poster reference",
                "dominant_color": "#2A60E0",
                "link": "https://studio.example.org/poster",
                "domain": "studio.example.org",
                "pinner": {
                  "full_name": "Design Archive",
                  "username": "designarchive",
                  "image_medium_url": "https://i.pinimg.com/75x75_RS/avatar.jpg"
                },
                "board": {
                  "id": "9001",
                  "name": "Graphic Systems"
                },
                "images": {
                  "236x": { "url": "https://i.pinimg.com/236x/a.jpg", "width": 236, "height": 354 },
                  "736x": { "url": "https://i.pinimg.com/736x/a.jpg", "width": 736, "height": 1104 },
                  "orig": { "url": "https://i.pinimg.com/originals/a.jpg", "width": 1600, "height": 2400 }
                }
              }
            ]
          }
        }
        """
        let page = PinterestJSONParser.parseFeedPage(from: Data(json.utf8))
        #expect(page.pins.count == 1)
        #expect(page.bookmark == "NEXT_CURSOR_PAGE_2")
        #expect(page.hasMore == true)

        let pin = try #require(page.pins.first)
        #expect(pin.id == "222222222")
        #expect(pin.title == "Minimal Editorial Poster")
        #expect(pin.dominantColorHex == "#2A60E0")
        #expect(pin.width == 1600)
        #expect(pin.height == 2400)
        #expect(pin.boardName == "Graphic Systems")
        #expect(pin.pinnerName == "Design Archive")
        #expect(pin.originalURL.absoluteString == "https://i.pinimg.com/originals/a.jpg")
        #expect(pin.previewURL.absoluteString == "https://i.pinimg.com/736x/a.jpg")
        #expect(pin.thumbnailURL.absoluteString == "https://i.pinimg.com/236x/a.jpg")
    }

    @Test("parseFeedPage handles BaseSearchResource data.results and -end- bookmark sentinel")
    func parseSearchResultsAndEndSentinel() {
        let json = """
        {
          "resource_response": {
            "bookmark": "-end-",
            "data": {
              "results": [
                {
                  "id": "333333333",
                  "type": "pin",
                  "title": "Brutalist Architecture",
                  "images": {
                    "736x": { "url": "https://i.pinimg.com/736x/b.jpg", "width": 736, "height": 552 }
                  }
                }
              ]
            }
          }
        }
        """
        let page = PinterestJSONParser.parseFeedPage(from: Data(json.utf8))
        #expect(page.pins.count == 1)
        #expect(page.pins.first?.id == "333333333")
        #expect(page.hasMore == false)
        #expect(page.bookmark == nil)
    }

    @Test("parseBoardsPage extracts user boards and pagination bookmark")
    func parseBoardsPageExtractsBoardsAndBookmark() throws {
        let json = """
        {
          "resource_response": {
            "bookmark": "BOARD_PAGE_2",
            "data": [
              {
                "id": "8801",
                "name": "UI 灵感",
                "url": "/alice/ui-inspiration/",
                "pin_count": 42,
                "image_cover_hd_url": "https://i.pinimg.com/400x/cover1.jpg"
              },
              {
                "id": "8802",
                "name": "建筑光影",
                "url": "/alice/architecture/",
                "pin_count": 19
              }
            ]
          }
        }
        """
        let result = PinterestJSONParser.parseBoardsPage(from: Data(json.utf8))
        #expect(result.boards.count == 2)
        #expect(result.bookmark == "BOARD_PAGE_2")
        let first = try #require(result.boards.first)
        #expect(first.name == "UI 灵感")
        #expect(first.pinCount == 42)
        #expect(first.coverURL?.absoluteString == "https://i.pinimg.com/400x/cover1.jpg")
    }

    @Test("parsePinsFromHTML recovers embedded __PWS_INITIAL_PROPS__ pins")
    func parsePinsFromHTMLFallback() {
        let html = """
        <html><body>
        <script id="__PWS_INITIAL_PROPS__" type="application/json">
        {"initialReduxState":{"pins":{"555001":{"id":"555001","type":"pin","title":"Embedded Pin","images":{"736x":{"url":"https://i.pinimg.com/736x/e.jpg","width":736,"height":920}}}}}}
        </script>
        </body></html>
        """
        let pins = PinterestJSONParser.parsePinsFromHTML(html)
        #expect(pins.count == 1)
        #expect(pins.first?.id == "555001")
        #expect(pins.first?.title == "Embedded Pin")
    }

    // MARK: - Infinite 2D Omnidirectional Layout & Anchor-Locked Camera

    @Test("PinterestSpatialLayout places 120 mixed-aspect pins with zero overlaps and 0pt append shift")
    func spatialLayoutNonOverlappingAndAppendStable() {
        var layout = PinterestSpatialLayout(cardWidth: 224, gap: 16)
        let batch1 = (1...60).map { makeMockPin(id: "\($0)", width: 800, height: 600 + ($0 % 5) * 240) }
        let batch2 = (61...120).map { makeMockPin(id: "\($0)", width: 900, height: 500 + ($0 % 6) * 220) }

        layout.append(batch1)
        let snapshotFrames = Dictionary(uniqueKeysWithValues: layout.cards.map { ($0.id, $0.frame) })

        layout.append(batch2)
        #expect(layout.cards.count == 120)

        // Appending page 2 must NEVER move any previously placed card (0.0pt layout shift)
        for card in layout.cards {
            if let prior = snapshotFrames[card.id] {
                #expect(card.frame == prior)
            }
        }

        // Verify zero overlapping cards across all 120 items
        for i in 0..<layout.cards.count {
            for j in (i + 1)..<layout.cards.count {
                let a = layout.cards[i].frame
                let b = layout.cards[j].frame
                #expect(!a.intersects(b), "Cards \(layout.cards[i].id) and \(layout.cards[j].id) overlapped")
            }
        }

        // Verify bidirectional omnidirectional expansion across all 4 quadrants around (0, 0)
        #expect(layout.worldBounds.minX < -300)
        #expect(layout.worldBounds.maxX > 300)
        #expect(layout.worldBounds.minY < -300)
        #expect(layout.worldBounds.maxY > 300)

        // Verify viewport culling and edge detection
        let centerView = CGRect(x: -200, y: -200, width: 400, height: 400)
        let culled = layout.visibleCards(in: centerView, overscan: 60)
        #expect(!culled.isEmpty && culled.count < layout.cards.count)
        #expect(layout.isApproachingEdge(visibleWorldRect: centerView, threshold: 100) == false)

        let farEastView = CGRect(x: layout.worldBounds.maxX - 80, y: -100, width: 400, height: 400)
        #expect(layout.isApproachingEdge(visibleWorldRect: farEastView, threshold: 200) == true)

        // Verify predictive directional prefetch biases toward cards ahead of the swipe vector (+X)
        let eastPredicted = layout.predictivePrefetchCards(
            visibleWorldRect: centerView,
            lookaheadOffset: CGVector(dx: 700, dy: 0),
            halo: 500,
            limit: 12
        )
        #expect(!eastPredicted.isEmpty)
        let avgEastX = eastPredicted.reduce(CGFloat(0)) { $0 + $1.frame.midX } / CGFloat(eastPredicted.count)
        #expect(avgEastX > 250)
    }

    @Test("InfiniteSpatialCamera continuous zoom stays anchor-locked to <0.001pt")
    func cameraZoomAnchorLockedInvariant() {
        var cam = InfiniteSpatialCamera.centered(in: CGSize(width: 1200, height: 800), scale: 0.90)
        cam.pan(by: CGSize(width: -185, height: 142))

        let anchors: [CGPoint] = [
            CGPoint(x: 240, y: 190),
            CGPoint(x: 880, y: 610),
            CGPoint(x: 600, y: 400)
        ]
        let targetScales: [CGFloat] = [1.85, 0.35, 2.75, 0.62, 1.15]

        for (anchor, scale) in zip(anchors, targetScales) {
            let worldBefore = cam.worldPoint(from: anchor)
            cam.zoom(to: scale, anchoredAt: anchor)
            let screenAfter = cam.screenPoint(from: worldBefore)
            #expect(abs(screenAfter.x - anchor.x) < 0.001)
            #expect(abs(screenAfter.y - anchor.y) < 0.001)
        }
    }

    // MARK: - Shopping-Cart Tray & Floating Detail Navigation Stack

    @Test("PinterestExploreController supports tray cart pick, selective remove, and detail history stack")
    @MainActor
    func trayAndDetailStackBehavior() {
        let controller = PinterestExploreController(persistTray: false)
        let p1 = makeMockPin(id: "1001", width: 800, height: 1000)
        let p2 = makeMockPin(id: "1002", width: 800, height: 800)
        let p3 = makeMockPin(id: "1003", width: 1000, height: 700)

        #expect(controller.toggleTray(p1) == true)
        #expect(controller.toggleTray(p2) == true)
        #expect(controller.toggleTray(p3) == true)
        #expect(controller.trayCount == 3)
        #expect(controller.selectedTrayCount == 3)

        // Deselect p2, then selectively remove only checked items (p1 & p3)
        controller.toggleTraySelection(p2.id)
        #expect(controller.selectedTrayCount == 2)
        let removed = controller.removeSelectedFromTray()
        #expect(removed == 2)
        #expect(controller.trayPins.map(\.id) == [p2.id])

        // Floating detail stack: click tray pin -> push similar pin -> pop back
        controller.openPinDetail(p2, resetStack: true)
        #expect(controller.activeDetailPin?.id == p2.id)
        controller.openPinDetail(p3, resetStack: false)
        #expect(controller.detailStack.count == 2)
        #expect(controller.activeDetailPin?.id == p3.id)

        controller.popPinDetail()
        #expect(controller.activeDetailPin?.id == p2.id)
        controller.closePinDetail()
        #expect(controller.activeDetailPin == nil)
    }

    // MARK: - Batch Board Collection Import into Per-Board Charkle Folders

    @Test("importBoards creates per-board subfolders under Pinterest root and deduplicates incrementally on re-run")
    func importBoardsCreatesFoldersAndDeduplicatesIncrementally() async throws {
        let dir = try BackendFixture.directory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let engine = try BackendFixture.makeEngine(dir, transport: InMemoryDriveTransport())

        let boardUI = PinterestBoard(id: "b1", name: "UI 灵感", urlPath: "/u/ui/", pinCount: 2)
        let boardArch = PinterestBoard(id: "b2", name: "建筑/光影", urlPath: "/u/arch/", pinCount: 1)

        let pinA = makeMockPin(id: "70001", width: 800, height: 1000, boardName: "UI 灵感")
        let pinB = makeMockPin(id: "70002", width: 800, height: 900, boardName: "UI 灵感")
        let pinC = makeMockPin(id: "70003", width: 1000, height: 700, boardName: "建筑/光影")
        let pinD = makeMockPin(id: "70004", width: 900, height: 900, boardName: "UI 灵感")

        let stubImporter: @Sendable (PinterestPin, any CharkleEngineProtocol, UUID?, [String]) async -> AssetRecord? = { pin, eng, folderID, tags in
            guard let created = (try? await eng.ingest(
                [.colorSwatch(hex: pin.dominantColorHex ?? "#2A60E0", title: pin.displayTitle)],
                targetFolderID: folderID,
                targetBoardID: nil
            ))?.first else {
                return nil
            }
            let patch = AssetBatchPatch(
                assetIDs: [created.id],
                title: pin.displayTitle,
                sourceURL: pin.pinPageURL.absoluteString,
                addTags: ["Pinterest"] + tags
            )
            return (try? await eng.updateAssets(patch))?.first ?? created
        }

        // Run 1: Creates "Pinterest" parent folder + "UI 灵感" & "建筑·光影" child folders
        let report1 = await PinterestImportService.importBoards(
            [boardUI, boardArch],
            into: engine,
            destination: .pinterestRootFolder,
            skipDuplicates: true,
            pinProvider: { board, _ in
                board.id == "b1" ? [pinA, pinB] : [pinC]
            },
            singlePinImporter: stubImporter
        )

        #expect(report1.boardsProcessed == 2)
        #expect(report1.foldersCreated == 3) // Pinterest + UI 灵感 + 建筑·光影
        #expect(report1.importedAssets.count == 3)
        #expect(report1.skippedDuplicatePinIDs.isEmpty)

        let foldersAfterRun1 = try await engine.fetchFolders()
        let rootFolder = try #require(foldersAfterRun1.first(where: { $0.name == "Pinterest" && $0.parentID == nil }))
        let uiFolder = try #require(foldersAfterRun1.first(where: { $0.name == "UI 灵感" && $0.parentID == rootFolder.id }))
        let archFolder = try #require(foldersAfterRun1.first(where: { $0.name == "建筑·光影" && $0.parentID == rootFolder.id }))

        let uiAssets1 = try await engine.fetchAssets(matching: FilterCriteria(folderID: uiFolder.id))
        let archAssets1 = try await engine.fetchAssets(matching: FilterCriteria(folderID: archFolder.id))
        #expect(uiAssets1.count == 2)
        #expect(archAssets1.count == 1)

        // Run 2: Incremental sync — pinA & pinB already exist, pinD is new -> 0 new folders, 2 skipped, 1 imported!
        let report2 = await PinterestImportService.importBoards(
            [boardUI],
            into: engine,
            destination: .pinterestRootFolder,
            skipDuplicates: true,
            pinProvider: { _, _ in [pinA, pinB, pinD] },
            singlePinImporter: stubImporter
        )

        #expect(report2.foldersCreated == 0)
        #expect(report2.skippedDuplicatePinIDs == ["70001", "70002"])
        #expect(report2.importedPinIDs == ["70004"])

        let foldersAfterRun2 = try await engine.fetchFolders()
        #expect(foldersAfterRun2.count == foldersAfterRun1.count)
        let uiAssets2 = try await engine.fetchAssets(matching: FilterCriteria(folderID: uiFolder.id))
        #expect(uiAssets2.count == 3)
    }

    // MARK: - Helpers

    private func makeMockPin(
        id: String,
        width: Int,
        height: Int,
        boardName: String? = nil
    ) -> PinterestPin {
        PinterestPin(
            id: id,
            title: "Pin \(id)",
            descriptionText: "Description \(id)",
            dominantColorHex: "#3D5A80",
            width: width,
            height: height,
            thumbnailURL: URL(string: "https://i.pinimg.com/474x/\(id).jpg")!,
            previewURL: URL(string: "https://i.pinimg.com/736x/\(id).jpg")!,
            originalURL: URL(string: "https://i.pinimg.com/originals/\(id).jpg")!,
            pinPageURL: URL(string: "https://www.pinterest.com/pin/\(id)/")!,
            boardName: boardName
        )
    }
}
