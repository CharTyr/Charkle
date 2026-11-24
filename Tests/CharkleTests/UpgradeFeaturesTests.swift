import CharkleCanvas
@testable import CharkleCore
import Foundation
import Testing

@Suite("Major Feature Upgrade: Justified Masonry, Rich Importers, Smart Folders, Folder Move/Dir Import & Moodboard Frames")
struct UpgradeFeaturesTests {

    @Test("Horizontal Justified Masonry preserves aspect ratios, aligns rows flush, and keeps O(log N) visibility parity")
    func horizontalJustifiedMasonry() {
        var assets: [AssetRecord] = []
        let shapes: [(Int, Int)] = [(600, 1200), (1600, 900), (1000, 1000), (800, 1200), (1920, 1080), (900, 1400)]
        for i in 0..<240 {
            let (w, h) = shapes[i % shapes.count]
            assets.append(AssetRecord(title: "J\(i)", fileName: "j\(i).jpg", mediaKind: .image, pixelWidth: w, pixelHeight: h))
        }

        let containerW: CGFloat = 1240
        let pad: CGFloat = 20
        let snap = MasonryLayoutEngine.computeJustified(
            assets: assets,
            containerWidth: containerW,
            targetRowHeight: 210,
            spacing: 12,
            horizontalPadding: pad,
            topInset: 76,
            bottomInset: 64
        )
        #expect(snap.items.count == 240)

        // Check minY non-decreasing invariant
        for i in 1..<snap.items.count {
            #expect(snap.items[i].rect.minY >= snap.items[i - 1].rect.minY - 0.001)
        }

        // Group into rows by minY; verify every full row has equal heights and flush left/right edges
        let grouped = Dictionary(grouping: snap.items, by: { Int($0.rect.minY.rounded()) })
        let sortedRows = grouped.keys.sorted().map { grouped[$0]! }
        #expect(sortedRows.count >= 10)
        for row in sortedRows.dropLast() {
            let firstH = row[0].rect.height
            for item in row {
                #expect(abs(item.rect.height - firstH) <= 1.0)
            }
            let minX = row.map(\.rect.minX).min() ?? 0
            let maxX = row.map(\.rect.maxX).max() ?? 0
            #expect(abs(minX - pad) <= 1.0)
            #expect(abs(maxX - (containerW - pad)) <= 2.0)
        }

        // O(log N) visibleItems matches brute force
        let fast = snap.visibleItems(minY: 600, maxY: 1600)
        let brute = snap.items.filter { $0.rect.maxY >= 600 && $0.rect.minY <= 1600 }
        #expect(fast == brute)
    }

    @Test("MasonryLayoutEngine Photos-style zoom stepping moves cleanly by exact 1 density level across viewport widths")
    func masonryZoomSteppingPrecision() {
        for containerW: CGFloat in [720, 960, 1240, 1540] {
            let minCols = MasonryLayoutEngine.minReachableVerticalColumns(containerWidth: containerW)
            let maxCols = MasonryLayoutEngine.maxReachableVerticalColumns(containerWidth: containerW)
            #expect(minCols <= maxCols)

            // Walk every reachable column count from densest to widest, verifying exact 1-column steps
            var width = MasonryLayoutEngine.canonicalTargetWidth(forVerticalColumns: maxCols, containerWidth: containerW)
            #expect(MasonryLayoutEngine.verticalColumnCount(containerWidth: containerW, targetColumnWidth: width) == maxCols)

            for expectedCols in stride(from: maxCols - 1, through: minCols, by: -1) {
                width = MasonryLayoutEngine.steppedColumnWidth(
                    currentWidth: width,
                    direction: 1,
                    layoutMode: .verticalMasonry,
                    containerWidth: containerW
                )
                let resolvedCols = MasonryLayoutEngine.verticalColumnCount(containerWidth: containerW, targetColumnWidth: width)
                #expect(resolvedCols == expectedCols)
            }

            // Walk back out from widest to densest
            for expectedCols in (minCols + 1)...maxCols {
                width = MasonryLayoutEngine.steppedColumnWidth(
                    currentWidth: width,
                    direction: -1,
                    layoutMode: .verticalMasonry,
                    containerWidth: containerW
                )
                let resolvedCols = MasonryLayoutEngine.verticalColumnCount(containerWidth: containerW, targetColumnWidth: width)
                #expect(resolvedCols == expectedCols)
            }
        }

        // Horizontal Justified stops walk monotonically across all quantized stops
        var jWidth = MasonryLayoutEngine.justifiedZoomStops.first!
        for expected in MasonryLayoutEngine.justifiedZoomStops.dropFirst() {
            jWidth = MasonryLayoutEngine.steppedColumnWidth(
                currentWidth: jWidth,
                direction: 1,
                layoutMode: .horizontalJustified,
                containerWidth: 1200
            )
            #expect(jWidth == expected)
        }
        #expect(MasonryLayoutEngine.snappedJustifiedTargetWidth(210) == 214)
    }

    @Test("MasonryLayoutEngine exact-asset zoom anchoring pins Row-2+ cards even from scrollY=0, preserves Row-1 top inset, and compensates optical rebase with zero jump")
    func masonryExactAssetAnchorMath() {
        var assets: [AssetRecord] = []
        for i in 0..<80 {
            assets.append(AssetRecord(
                title: "A\(i)",
                fileName: "a\(i).jpg",
                mediaKind: .image,
                pixelWidth: (i % 3 == 0) ? 1200 : 900,
                pixelHeight: (i % 3 == 0) ? 900 : 1200
            ))
        }

        let containerW: CGFloat = 1200
        let viewportH: CGFloat = 760
        let topInset: CGFloat = 76

        let layout6 = MasonryLayoutEngine.compute(
            assets: assets,
            layoutMode: .verticalMasonry,
            containerWidth: containerW,
            targetColumnWidth: MasonryLayoutEngine.canonicalTargetWidth(forVerticalColumns: 6, containerWidth: containerW),
            spacing: 12,
            horizontalPadding: 20,
            topInset: topInset,
            bottomInset: 64
        )
        let layout3 = MasonryLayoutEngine.compute(
            assets: assets,
            layoutMode: .verticalMasonry,
            containerWidth: containerW,
            targetColumnWidth: MasonryLayoutEngine.canonicalTargetWidth(forVerticalColumns: 3, containerWidth: containerW),
            spacing: 12,
            horizontalPadding: 20,
            topInset: topInset,
            bottomInset: 64
        )

        // 1. Row-1 card at scrollY = 0 keeps scrollY = 0 so it never clips under the floating top bar
        let row1Old = layout6.items[0].rect
        let row1New = layout3.items[0].rect
        let row1Scroll = MasonryLayoutEngine.anchoredScrollY(
            oldScrollY: 0,
            oldAnchorRect: row1Old,
            newAnchorRect: row1New,
            anchorNormV: 0.5,
            anchorScreenY: row1Old.midY,
            topInset: topInset,
            totalHeight: layout3.totalHeight,
            viewportHeight: viewportH
        )
        #expect(row1Scroll == 0)

        // 2. Row-2+ card (index 10) zoomed IN from scrollY = 0 scrolls automatically to keep THAT exact card pinned
        let row2Old = layout6.items[10].rect
        let row2New = layout3.items[10].rect
        let targetScreenY = row2Old.minY + 0.35 * row2Old.height
        let row2Scroll = MasonryLayoutEngine.anchoredScrollY(
            oldScrollY: 0,
            oldAnchorRect: row2Old,
            newAnchorRect: row2New,
            anchorNormV: 0.35,
            anchorScreenY: targetScreenY,
            topInset: topInset,
            totalHeight: layout3.totalHeight,
            viewportHeight: viewportH
        )
        #expect(row2Scroll > 0)
        let actualAnchoredScreenY = (row2New.minY + 0.35 * row2New.height) - row2Scroll
        #expect(abs(actualAnchoredScreenY - targetScreenY) < 0.01)

        // 3. Optical pinch rebase compensation projects frame 0 to the exact pre-handoff screen rect (0.0pt jump)
        let oldScreenRect = CGRect(x: 412, y: 288, width: 210, height: 274)
        let newScale: CGFloat = 0.91
        let newPivot = CGPoint(x: 340, y: 390)
        let fromDoc = MasonryLayoutEngine.compensatedFromRect(
            oldScreenRect: oldScreenRect,
            newScrollY: row2Scroll,
            newOpticalScale: newScale,
            newOpticalAnchorScreen: newPivot
        )
        // Re-project fromDoc through (newScrollY, newScale, newPivot) and confirm machine-precision match
        let projMidX = newPivot.x + (fromDoc.midX - newPivot.x) * newScale
        let projMidY = newPivot.y + ((fromDoc.midY - row2Scroll) - newPivot.y) * newScale
        let projW = fromDoc.width * newScale
        let projH = fromDoc.height * newScale
        #expect(abs(projMidX - oldScreenRect.midX) < 0.001)
        #expect(abs(projMidY - oldScreenRect.midY) < 0.001)
        #expect(abs(projW - oldScreenRect.width) < 0.001)
        #expect(abs(projH - oldScreenRect.height) < 0.001)

        // 4. Reveal-in-library scroll centering clamps top/bottom cleanly and centers mid-list items below topInset
        let topReveal = MasonryLayoutEngine.revealScrollY(
            for: CGRect(x: 20, y: 76, width: 200, height: 180),
            topInset: 76,
            bottomInset: 44,
            totalHeight: 4000,
            viewportHeight: 800
        )
        #expect(topReveal == 0)

        let midRect = CGRect(x: 20, y: 1800, width: 200, height: 200)
        let midReveal = MasonryLayoutEngine.revealScrollY(
            for: midRect,
            topInset: 76,
            bottomInset: 44,
            totalHeight: 4000,
            viewportHeight: 800
        )
        let expectedCenterY: CGFloat = 76 + (800 - 76 - 44) * 0.5
        #expect(abs((midRect.midY - midReveal) - expectedCenterY) < 0.01)

        let bottomReveal = MasonryLayoutEngine.revealScrollY(
            for: CGRect(x: 20, y: 3820, width: 200, height: 160),
            topInset: 76,
            bottomInset: 44,
            totalHeight: 4000,
            viewportHeight: 800
        )
        #expect(bottomReveal == 3200)
    }

    @Test("GitHubRepoURLParser and SocialPostURLParser parse valid URLs and reject non-post/non-repo links")
    func richURLParsers() throws {
        let u1 = try #require(URL(string: "https://github.com/apple/swift.git"))
        let repo1 = try #require(GitHubRepoURLParser.parse(u1))
        #expect(repo1.owner == "apple" && repo1.repo == "swift" && repo1.fullName == "apple/swift")

        let uBranch = try #require(URL(string: "https://github.com/Illyism/seo-skills/tree/main"))
        let repoBranch = try #require(GitHubRepoURLParser.parse(uBranch))
        #expect(repoBranch.owner == "Illyism" && repoBranch.repo == "seo-skills" && repoBranch.branch == "main")

        // Non-repo paths rejected
        let uSettings = try #require(URL(string: "https://github.com/settings/tokens"))
        let uIssue = try #require(URL(string: "https://github.com/apple/swift/issues/42"))
        #expect(GitHubRepoURLParser.parse(uSettings) == nil)
        #expect(GitHubRepoURLParser.parse(uIssue) == nil)

        // Base64 README decode
        let sampleMD = "# Hello Charkle\n\n- Fast\n"
        let b64 = Data(sampleMD.utf8).base64EncodedString()
        #expect(GitHubRepoResolver.decodeBase64Markdown(b64) == sampleMD)

        // Social posts across X, Threads, Bluesky
        let uX = try #require(URL(string: "https://x.com/lucass0x/status/1234567890"))
        let xParsed = try #require(SocialPostURLParser.parse(uX))
        #expect(xParsed.platform == .x)

        let uThreads = try #require(URL(string: "https://www.threads.net/@zuck/post/C8abc123"))
        let threadsParsed = try #require(SocialPostURLParser.parse(uThreads))
        #expect(threadsParsed.platform == .threads)

        let uBsky = try #require(URL(string: "https://bsky.app/profile/jay.bsky.team/post/3k2abc"))
        let bskyParsed = try #require(SocialPostURLParser.parse(uBsky))
        #expect(bskyParsed.platform == .bluesky)
    }

    @Test("SmartFolderRule matches tags, description keywords, CIELAB colors, and media kinds")
    func smartFolderMatching() {
        let blueSkyArt = AssetRecord(
            title: "夏日海滩插画",
            fileName: "beach.png",
            mediaKind: .image,
            notes: "清透海风与蓝天白云",
            tags: ["插画", "夏日"],
            dominantColors: [LabColor.fromHex("#3B82F6")],
            rating: 4
        )
        let darkModel = AssetRecord(
            title: "Cyber Helmet",
            fileName: "helmet.usdz",
            mediaKind: .model3D,
            tags: ["科幻"],
            dominantColors: [LabColor.fromHex("#18181B")],
            rating: 5
        )

        let strictRule = SmartFolderRule(
            matchMode: .all,
            tags: ["夏日"],
            descriptionQuery: "海滩 蓝天",
            colorHexes: ["#2563EB"],
            colorTolerance: 24,
            mediaKinds: [.image],
            minRating: 3
        )
        #expect(strictRule.matches(blueSkyArt))
        #expect(!strictRule.matches(darkModel))

        let anyRule = SmartFolderRule(
            matchMode: .any,
            tags: ["插画"],
            mediaKinds: [.model3D]
        )
        #expect(anyRule.matches(blueSkyArt))
        #expect(anyRule.matches(darkModel))
    }

    @Test("LiveCharkleEngine supports recursive directory drop import and folder move/reorder with cycle protection")
    func directoryImportAndFolderMove() async throws {
        let dir = try BackendFixture.directory()
        defer { try? FileManager.default.removeItem(at: dir) }

        let engine = try LiveCharkleEngine.make(appSupportDirectory: dir.appending(path: "AppSupport", directoryHint: .isDirectory))

        // Build a nested Finder folder on disk
        let dropRoot = dir.appending(path: "IllustrationPack", directoryHint: .isDirectory)
        let subDir = dropRoot.appending(path: "SubWatercolors", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: subDir, withIntermediateDirectories: true)
        let png1 = try BackendFixture.artwork("#3B82F6")
        let png2 = try BackendFixture.artwork("#F97316")
        try png1.write(to: dropRoot.appending(path: "cover.png"))
        try png2.write(to: subDir.appending(path: "detail.png"))

        let imported = try await engine.ingest([.fileURL(dropRoot)], targetFolderID: nil, targetBoardID: nil)
        #expect(imported.count == 2)

        let folders = try await engine.fetchFolders()
        let parentFolder = try #require(folders.first(where: { $0.name == "IllustrationPack" && $0.parentID == nil }))
        let childFolder = try #require(folders.first(where: { $0.name == "SubWatercolors" && $0.parentID == parentFolder.id }))

        // Cycle protection: cannot move parent into its own descendant
        var threwCycleError = false
        do {
            _ = try await engine.moveFolder(id: parentFolder.id, newParentID: childFolder.id, insertAtIndex: nil)
        } catch {
            threwCycleError = true
        }
        #expect(threwCycleError)

        // Move childFolder to top level at index 0
        let afterMove = try await engine.moveFolder(id: childFolder.id, newParentID: nil, insertAtIndex: 0)
        let topLevel = afterMove.filter { $0.parentID == nil }.sorted { $0.sortOrder < $1.sortOrder }
        #expect(topLevel.first?.id == childFolder.id)

        // Update folder custom color & symbol
        let styled = try await engine.updateFolderAppearance(id: parentFolder.id, colorHex: "#FF9F0A", customSymbol: "sf:paintbrush.fill")
        #expect(styled.colorHex == "#FF9F0A")
        #expect(styled.customSymbol == "sf:paintbrush.fill")
    }

    @Test("Moodboard 3 editorial styles have clearly distinct geometry and Smart Group Frame reflow stays inside bounds")
    func moodboardStylesAndSmartFrameReflow() {
        var assets: [AssetRecord] = []
        var assetsByID: [UUID: AssetRecord] = [:]
        var nodes: [BoardNode] = []
        for i in 0..<12 {
            let a = AssetRecord(title: "M\(i)", fileName: "m\(i).jpg", mediaKind: .image, pixelWidth: 1200, pixelHeight: 900)
            assets.append(a)
            assetsByID[a.id] = a
            nodes.append(BoardNode(
                kind: .assetRef(assetID: a.id, crop: nil, weight: i == 0 ? 2 : 1, autoplayLoop: false),
                frame: BoardRect(x: Double(i * 40), y: 40, width: 200, height: 150),
                editorialOrder: i
            ))
        }

        let mag = EditorialLayoutSolver.solve(nodes: nodes, config: AutoLayoutConfig(style: .magazine), containerWidth: 1100, assetsByID: assetsByID)
        let bal = EditorialLayoutSolver.solve(nodes: nodes, config: AutoLayoutConfig(style: .balanced), containerWidth: 1100, assetsByID: assetsByID)
        let cmp = EditorialLayoutSolver.solve(nodes: nodes, config: AutoLayoutConfig(style: .compact), containerWidth: 1100, assetsByID: assetsByID)

        // Magazine has fewest/widest columns (3), Balanced has 4, Compact has densest (5+)
        #expect(mag.columnCount < bal.columnCount)
        #expect(bal.columnCount < cmp.columnCount)
        #expect(mag.columnWidth > bal.columnWidth)
        #expect(bal.columnWidth > cmp.columnWidth)

        // Smart Group Frame reflow keeps all 6 child nodes strictly inside resized frame bounds
        let groupRect = BoardRect(x: 100, y: 100, width: 640, height: 340)
        let children = Array(nodes.prefix(6))
        let reflowed = EditorialLayoutSolver.reflowNodesInsideGroupFrame(
            groupRect: groupRect,
            childNodes: children,
            assetsByID: assetsByID
        )
        #expect(reflowed.count == 6)
        for (_, r) in reflowed {
            #expect(r.minX >= groupRect.minX)
            #expect(r.minY >= groupRect.minY)
            #expect(r.maxX <= groupRect.maxX + 1.0)
            #expect(r.maxY <= groupRect.maxY + 1.0)
            #expect(r.width > 20 && r.height > 20)
        }
    }

    @Test("Recursive parent folder query aggregates nested subfolder assets and SocialPostMetadata synthesizes video + photo attachments")
    func recursiveFolderQueryAndSocialAttachments() async throws {
        let rootDir = FileManager.default.temporaryDirectory
            .appending(path: "charkle-subtree-test-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: rootDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: rootDir) }

        let engine = LiveCharkleEngine(
            database: try LibraryDatabase(path: rootDir.appending(path: "library.sqlite").path),
            media: try MediaPipeline(directory: rootDir.appending(path: "media", directoryHint: .isDirectory))
        )

        let parent = try await engine.createFolder(name: "插画", parentID: nil)
        let child = try await engine.createFolder(name: "mashiroka", parentID: parent.id)
        let grandChild = try await engine.createFolder(name: "草稿", parentID: child.id)

        _ = try await engine.ingest([.colorSwatch(hex: "#3B82F6", title: "ChildArt")], targetFolderID: child.id, targetBoardID: nil)
        _ = try await engine.ingest([.colorSwatch(hex: "#E11D48", title: "GrandChildArt")], targetFolderID: grandChild.id, targetBoardID: nil)

        let directOnly = try await engine.fetchAssets(matching: FilterCriteria(folderID: parent.id, includeSubfolders: false))
        #expect(directOnly.isEmpty)

        let recursive = try await engine.fetchAssets(matching: FilterCriteria(folderID: parent.id, includeSubfolders: true))
        #expect(recursive.count == 2)
        #expect(Set(recursive.map(\.title)) == ["ChildArt", "GrandChildArt"])

        // Legacy social post metadata synthesizes typed video + photo attachments cleanly
        let legacyPost = SocialPostMetadata(
            platform: .x,
            authorName: "Tester",
            authorHandle: "tester",
            bodyText: "Hello",
            mediaURLs: ["https://pbs.twimg.com/media/abc.jpg"],
            mediaThumbnailURLs: ["https://pbs.twimg.com/ext_tw_video_thumb/1/img.jpg"],
            hasVideo: true,
            videoURL: "https://video.twimg.com/ext_tw_video/1/vid.mp4",
            originalURL: "https://x.com/tester/status/123"
        )
        let attachments = legacyPost.effectiveAttachments
        #expect(attachments.count == 2)
        #expect(attachments[0].kind == .video)
        #expect(attachments[1].kind == .photo)
    }

    @Test("ThumbnailImageLoader low-resource mode purges decoded buffers and restores full budget on exit")
    @MainActor
    func thumbnailLoaderLowResourceModeBudget() {
        let loader = ThumbnailImageLoader(engine: PlaceholderCharkleEngine())
        #expect(loader.isLowResourceMode == false)
        #expect(loader.currentCacheCountLimit == 1_500)
        #expect(loader.currentCacheCostLimit == 320 * 1024 * 1024)
        #expect(loader.currentOriginalCacheCountLimit == 4)

        let versionBefore = loader.invalidationVersion
        loader.setLowResourceMode(true)
        #expect(loader.isLowResourceMode == true)
        #expect(loader.invalidationVersion == versionBefore &+ 1)
        #expect(loader.currentCacheCountLimit == 20)
        #expect(loader.currentCacheCostLimit == 12 * 1024 * 1024)
        #expect(loader.currentOriginalCacheCountLimit == 0)

        loader.setLowResourceMode(false)
        #expect(loader.isLowResourceMode == false)
        #expect(loader.currentCacheCountLimit == 1_500)
        #expect(loader.currentCacheCostLimit == 320 * 1024 * 1024)
        #expect(loader.currentOriginalCacheCountLimit == 4)
    }

    @Test("Ring Gallery Outside math satisfies default circumference, perspective projection, DoF blur, far fade, and painter's order")
    @MainActor
    func ringGalleryOutsideMathAndProjection() {
        let params = RingGalleryParameters.default
        #expect(params.slotCount == 22)
        #expect(params.step == 198)
        #expect(abs(params.radius - 693.2789) < 0.01)
        #expect(params.perspective == 1500)
        #expect(params.depthBlur == 2)
        #expect(params.farFade == 0.96)
        #expect(params.cornerRadius == 32)
        #expect(GalleryLayoutMode(rawValue: "ringGallery") == .ringGallery)

        // Front card sits cleanly at (x=0, z=0) with zero DoF blur and zero far fade
        let front = RingGalleryMath.placePoint(arcS: 0, curvature: params.curvature)
        #expect(abs(front.x) < 1e-6)
        #expect(abs(front.z) < 1e-6)
        #expect(RingGalleryMath.depthOfFieldBlur(screenX: 0, halfViewportWidth: 640, z: 0, radius: params.radius, maxBlur: 14) == 0)
        #expect(RingGalleryMath.farFadeAmount(z: 0, radius: params.radius, fade: 0.5) == 0)

        // Far-side card at s = half circumference sits at z = -2R with full depth blur and 50% far fade
        let far = RingGalleryMath.placePoint(arcS: params.circumference * 0.5, curvature: params.curvature)
        #expect(abs(far.x) < 1e-4)
        #expect(abs(far.z + 2.0 * params.radius) < 1e-4)
        let farBlur = RingGalleryMath.depthOfFieldBlur(screenX: 0, halfViewportWidth: 640, z: far.z, radius: params.radius, maxBlur: 14)
        #expect(abs(farBlur - 14.0) < 1e-6)
        let farFade = RingGalleryMath.farFadeAmount(z: far.z, radius: params.radius, fade: 0.5)
        #expect(abs(farFade - 0.5) < 1e-6)

        // Near-plane culling rejects points closer than 140pt in front of the eye
        #expect(RingGalleryMath.project(x: 0, y: 0, z: params.perspective - 100, perspective: params.perspective) == nil)
        #expect(RingGalleryMath.project(x: 0, y: 0, z: 0, perspective: params.perspective) != nil)

        // Visible Outside cards across a 500-asset library sort strictly farthest-first (painter's order)
        let cards = RingGalleryMath.visibleOutsideCards(
            assetCount: 500,
            offset: params.step * 42.0,
            params: params,
            viewportSize: CGSize(width: 1280, height: 760)
        )
        #expect(cards.count >= 20 && cards.count <= 22)
        for i in 1..<cards.count {
            #expect(cards[i].centerZ >= cards[i - 1].centerZ - 0.02)
        }
        // Last drawn (front-most) card is virtualIndex 42 -> assetIndex 42
        #expect(cards.last?.virtualIndex == 42)
        #expect(cards.last?.assetIndex == 42)

        // Viewport-adaptive scaling fills wide windows horizontally and shrinks cleanly on narrow/short windows
        let halfW1x = RingGalleryMath.outsideProjectedHalfWidth(radius: params.radius, perspective: params.perspective)
        #expect(abs(halfW1x - 499.76) < 0.5)
        let wideScale = RingGalleryMath.adaptiveCardScale(
            viewportSize: CGSize(width: 1600, height: 960),
            topSafeInset: 118,
            params: params
        )
        #expect(wideScale > 1.4 && wideScale < 1.7)
        let narrowScale = RingGalleryMath.adaptiveCardScale(
            viewportSize: CGSize(width: 560, height: 700),
            topSafeInset: 118,
            params: params
        )
        #expect(narrowScale > 0.45 && narrowScale < 0.62)
        let shortScale = RingGalleryMath.adaptiveCardScale(
            viewportSize: CGSize(width: 1600, height: 480),
            topSafeInset: 118,
            params: params
        )
        #expect(shortScale < wideScale)

        // Variable-width track preserves landscape aspect ratios (zero horizontal crop) with exact cardGap spacing
        let mixedAssets = [
            AssetRecord(title: "Portrait", fileName: "p.jpg", mediaKind: .image, pixelWidth: 900, pixelHeight: 1500),
            AssetRecord(title: "Landscape16x9", fileName: "l.jpg", mediaKind: .image, pixelWidth: 1920, pixelHeight: 1080),
            AssetRecord(title: "Square", fileName: "s.jpg", mediaKind: .image, pixelWidth: 1000, pixelHeight: 1000),
            AssetRecord(title: "Classic4x3", fileName: "c.jpg", mediaKind: .image, pixelWidth: 1600, pixelHeight: 1200)
        ]
        let mixedTrack = RingCardTrack.build(from: mixedAssets, params: params)
        #expect(mixedTrack.cardWidths[0] == 180)
        #expect(abs(mixedTrack.cardWidths[1] - 533) <= 1)
        #expect(mixedTrack.cardWidths[2] == 300)
        #expect(mixedTrack.cardWidths[3] == 400)
        // Gap between every adjacent pair along the arc equals exact params.cardGap (18pt)
        for i in 1..<mixedTrack.count {
            let actualGap = (mixedTrack.centerArcs[i] - mixedTrack.centerArcs[i - 1])
                - 0.5 * (mixedTrack.cardWidths[i - 1] + mixedTrack.cardWidths[i])
            #expect(abs(actualGap - params.cardGap) < 1e-6)
        }
        // Binary-search nearest card lookup hits exact landscape card center even across negative/positive laps
        let landscapeCenter = mixedTrack.centerArc(forVirtualIndex: 5) // lap 1, index 1
        #expect(mixedTrack.nearestVirtualIndex(to: landscapeCenter + 12) == 5)
        let negPortraitCenter = mixedTrack.centerArc(forVirtualIndex: -4) // lap -1, index 0
        #expect(mixedTrack.nearestVirtualIndex(to: negPortraitCenter - 5) == -4)

        // Cubic-bezier drag glide and Reduce Motion duration cap (<= 200ms)
        #expect(RingCubicBezier.dragGlide.evaluate(0) == 0)
        #expect(RingCubicBezier.dragGlide.evaluate(1) == 1)
        #expect(RingCubicBezier.dragGlide.evaluate(0.5) > 0.5)

        let normalGlide = RingGalleryMath.releaseGlide(offset: 40, velocity: -900, step: 198, reducedMotion: false)
        #expect(normalGlide.duration >= 0.42 && normalGlide.duration <= 1.10)
        let reducedGlide = RingGalleryMath.releaseGlide(offset: 40, velocity: -900, step: 198, reducedMotion: true)
        #expect(reducedGlide.duration <= 0.20)
    }

    @Test("Universal WebURLParser, HTML metadata/charset parsing, and external web link ingestion")
    func universalWebURLParsingAndExternalBrowserLink() async throws {
        // 1. Standalone URLs (case-insensitive, Unicode, balanced parens, www., wrapped punctuation)
        #expect(WebURLParser.parse("HTTPS://Example.COM/path")?.absoluteString == "https://Example.COM/path")
        #expect(WebURLParser.parse("www.apple.com/mac")?.absoluteString == "https://www.apple.com/mac")
        #expect(WebURLParser.parse("<https://en.wikipedia.org/wiki/Swift_(programming_language)>。")?
            .absoluteString == "https://en.wikipedia.org/wiki/Swift_(programming_language)")
        #expect(WebURLParser.parse("https://zh.wikipedia.org/wiki/设计系统") != nil)
        #expect(WebURLParser.parse("javascript:alert(1)") == nil)
        #expect(WebURLParser.parse("https://user:pass@example.com/") == nil)
        #expect(WebURLParser.parse("README.md") == nil)

        // 2. Short share-copy extraction vs long prose preservation
        let shareCopy = "【灵感收藏】很棒的字体站 https://fonts.example.org/specimen/inter?ref=1 强烈推荐！"
        #expect(WebURLParser.extractWebURL(from: shareCopy)?.absoluteString == "https://fonts.example.org/specimen/inter?ref=1")
        let longProse = String(repeating: "这是一段很长的笔记正文内容，包含很多段落和参考说明。", count: 16) + " https://example.org/ref"
        #expect(WebURLParser.extractWebURL(from: longProse) == nil)
        #expect(WebURLParser.cleanDomain(for: try #require(URL(string: "https://www.Figma.com/community"))) == "figma.com")

        // 3. HTML metadata, relative image resolution, JSON-LD image fallback, theme-color, icon discovery & GBK decoding
        let baseURL = try #require(URL(string: "https://studio.example.org/articles/color"))
        let sampleHTML = """
        <!doctype html>
        <html>
        <head>
          <meta property="og:title" content="Color &amp; Contrast Guide" />
          <meta name="description" content="Practical studio palette notes." />
          <meta property="og:site_name" content="Studio Journal" />
          <meta name="theme-color" content="#3a7" />
          <meta name="twitter:image" content="//cdn.example.org/cards/color.jpg" />
          <link rel="apple-touch-icon" href="/icons/apple-touch.png" />
          <script type="application/ld+json">{"@type":"Article","image":{"url":"/fallback-ld.png"}}</script>
        </head>
        <body><h1>Heading</h1></body>
        </html>
        """
        let parsed = WebBookmark.parseHTML(sampleHTML, baseURL: baseURL)
        #expect(parsed.title == "Color & Contrast Guide")
        #expect(parsed.description == "Practical studio palette notes.")
        #expect(parsed.siteName == "Studio Journal")
        #expect(parsed.themeColorHex == "#33AA77")
        #expect(parsed.imageURLs.map(\.absoluteString) == [
            "https://cdn.example.org/cards/color.jpg",
            "https://studio.example.org/fallback-ld.png"
        ])
        #expect(parsed.iconURLs.first?.absoluteString == "https://studio.example.org/icons/apple-touch.png")
        #expect(WebBookmark.usablePageTitle("Just a moment...", fallbackURL: baseURL) == "color — studio.example.org")

        // 4. AssetRecord.isExternalWebLink classification (true ONLY for generic web bookmarks)
        let genericWeb = AssetRecord(
            title: "Example",
            fileName: "example.webloc",
            mediaKind: .webBookmark,
            sourceURL: "https://example.org/page",
            sourceDomain: "example.org"
        )
        #expect(genericWeb.isExternalWebLink)

        let githubAsset = AssetRecord(
            title: "apple/swift",
            fileName: "swift.webloc",
            mediaKind: .webBookmark,
            sourceURL: "https://github.com/apple/swift",
            sourceDomain: "github.com",
            richMetadata: AssetRichMetadata(githubRepo: GitHubRepoMetadata(owner: "apple", repo: "swift", fullName: "apple/swift"))
        )
        #expect(!githubAsset.isExternalWebLink)

        let imageAsset = AssetRecord(
            title: "Photo",
            fileName: "photo.jpg",
            mediaKind: .image,
            sourceURL: "https://example.org/photo.jpg"
        )
        #expect(!imageAsset.isExternalWebLink)

        // 5. End-to-end generic URL ingestion generates editorial thumbnail & preserves exact source URL
        let dir = try BackendFixture.directory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let engine = try BackendFixture.makeEngine(dir)
        let offlineURL = try #require(URL(string: "http://127.0.0.1:1/design-system/tokens"))
        let created = try await engine.ingest([.webURL(offlineURL, title: nil, notes: nil)], targetFolderID: nil, targetBoardID: nil)
        let saved = try #require(created.first)
        #expect(saved.mediaKind == .webBookmark)
        #expect(saved.isExternalWebLink)
        #expect(saved.sourceURL == offlineURL.absoluteString)
        #expect(saved.sourceDomain == "127.0.0.1")
        #expect(await engine.thumbnailURL(for: saved.id, tier: .grid520) != nil)
        #expect(await engine.thumbnailURL(for: saved.id, tier: .preview1400) != nil)

        // 6. Moodboard responsive dock layout tiers adapt cleanly across wide, medium, and narrow widths
        #expect(MoodboardDockLayoutTier.resolve(forWidth: 1100) == .wide)
        #expect(MoodboardDockLayoutTier.resolve(forWidth: 820) == .wide)
        #expect(MoodboardDockLayoutTier.resolve(forWidth: 680) == .medium)
        #expect(MoodboardDockLayoutTier.resolve(forWidth: 560) == .medium)
        #expect(MoodboardDockLayoutTier.resolve(forWidth: 440) == .compact)
    }

    @Test("Xiaohongshu URL parsing, __INITIAL_STATE__ resolution, OG fallback, and canonical dedup keys")
    func xiaohongshuLinkAndResolverParsing() async throws {
        // 1. Standard explore / discovery / profile note URLs preserve xsec_token & share token-independent dedupKey
        let exploreURL = try #require(URL(string: "https://www.xiaohongshu.com/explore/66a1b2c3d4e5f60718293a4b?xsec_token=TOKEN_A&xsec_source=pc_collect"))
        let exploreRef = try #require(XiaohongshuURLParser.parse(exploreURL))
        #expect(exploreRef.noteID == "66a1b2c3d4e5f60718293a4b")
        #expect(exploreRef.xsecToken == "TOKEN_A")
        #expect(exploreRef.xsecSource == "pc_collect")
        #expect(exploreRef.canonicalURL.absoluteString.contains("xsec_token=TOKEN_A"))
        #expect(exploreRef.dedupKey == "xhs:66a1b2c3d4e5f60718293a4b")

        let profileNoteURL = try #require(URL(string: "https://www.xiaohongshu.com/user/profile/5f00112233445566778899aa/66a1b2c3d4e5f60718293a4b?xsec_token=TOKEN_B"))
        let profileRef = try #require(XiaohongshuURLParser.parse(profileNoteURL))
        #expect(profileRef.dedupKey == exploreRef.dedupKey)
        #expect(SocialPostResolver.canonicalDedupKey(for: exploreURL.absoluteString) == SocialPostResolver.canonicalDedupKey(for: profileNoteURL.absoluteString))

        // Short share link & raw mobile app share copy extraction
        let shareCopy = "67 某某发布了一篇小红书笔记，快来看吧！ http://xhslink.com/a/K8xYz123 复制本条信息，打开【小红书】App查看精彩内容！"
        let extractedShort = try #require(SocialPostURLParser.extractPostURL(from: shareCopy))
        #expect(extractedShort.host()?.lowercased() == "xhslink.com")
        if case .xiaohongshu(let shortRef) = SocialPostURLParser.parse(extractedShort) {
            #expect(shortRef.isShortLink)
        } else {
            Issue.record("Expected xhslink.com to parse as .xiaohongshu")
        }

        // Profile page without noteID should NOT parse as a note
        let profileRoot = try #require(URL(string: "https://www.xiaohongshu.com/user/profile/5f00112233445566778899aa?tab=collect"))
        #expect(XiaohongshuURLParser.parse(profileRoot) == nil)

        // 2. JS `undefined` sanitization & Chinese metric counts
        let sanitized = XiaohongshuPostResolver.sanitizeJSUndefined(in: #"{"a":undefined,"b":"keep undefined","c":[undefined,1]}"#)
        #expect(sanitized == #"{"a":null,"b":"keep undefined","c":[null,1]}"#)
        #expect(XiaohongshuPostResolver.parseChineseMetricCount("1.2万") == 12_000)
        #expect(XiaohongshuPostResolver.parseChineseMetricCount("3.5千") == 3_500)
        #expect(XiaohongshuPostResolver.parseChineseMetricCount("10万+") == 100_000)
        #expect(XiaohongshuPostResolver.parseChineseMetricCount("456") == 456)

        // 3. __INITIAL_STATE__ multi-image note parsing
        let ssrHTML = """
        <html><body><script>
        window.__INITIAL_STATE__={"note":{"noteDetailMap":{"66a1b2c3d4e5f60718293a4b":{"note":{
          "noteId":"66a1b2c3d4e5f60718293a4b",
          "type":"normal",
          "title":"工作台光影构图参考",
          "desc":"自然窗光与低饱和木质桌面 #摄影[话题]# #光影[话题]#",
          "time":1730000000000,
          "ignored":undefined,
          "user":{"nickname":"安禾","userId":"5f00112233445566778899aa","avatar":"http://sns-avatar-qc.xhscdn.com/a.jpg"},
          "interactInfo":{"likedCount":"2.4万","commentCount":"120","collectedCount":"5.1千"},
          "imageList":[
            {"infoList":[{"imageScene":"WB_PRV","url":"http://sns-webpic-qc.xhscdn.com/img1_prv"},{"imageScene":"WB_DFT","url":"http://sns-webpic-qc.xhscdn.com/img1_dft"}]},
            {"urlDefault":"http://sns-webpic-qc.xhscdn.com/img2_dft"}
          ]
        }}}}}
        </script></body></html>
        """
        let resolved = try #require(XiaohongshuPostResolver.parseInitialState(html: ssrHTML, ref: exploreRef))
        #expect(resolved.metadata.platform == .xiaohongshu)
        #expect(resolved.metadata.authorName == "安禾")
        #expect(resolved.metadata.displayHandleLine == nil) // hides internal 24-hex userId
        #expect(resolved.metadata.articleTitle == "工作台光影构图参考")
        #expect(resolved.metadata.bodyText == "自然窗光与低饱和木质桌面 #摄影 #光影")
        #expect(resolved.metadata.likeCount == 24_000)
        #expect(resolved.metadata.replyCount == 120)
        #expect(resolved.metadata.repostCount == 5_100)
        #expect(resolved.metadata.attachments.count == 2)
        #expect(resolved.metadata.attachments[0].url == "https://sns-webpic-qc.xhscdn.com/img1_dft")
        #expect(resolved.shortTitle == "安禾 · 工作台光影构图参考")

        // 4. Multi-og:image fallback & interstitial rejection
        let ogHTML = """
        <html><head>
          <meta name="og:title" content="色彩搭配笔记 - 小红书" />
          <meta name="og:description" content="暖灰与钴蓝配色方案" />
          <meta name="og:image" content="http://sns-webpic-qc.xhscdn.com/c1.jpg" />
          <meta name="og:image" content="http://sns-webpic-qc.xhscdn.com/c2.jpg" />
        </head><body></body></html>
        """
        let ogResolved = try #require(XiaohongshuPostResolver.parseMetaFallback(html: ogHTML, ref: exploreRef))
        #expect(ogResolved.metadata.articleTitle == "色彩搭配笔记")
        #expect(ogResolved.metadata.attachments.count == 2)

        let blockedHTML = "<html><head><title>你访问的页面不见了 - 小红书</title></head><body></body></html>"
        #expect(XiaohongshuPostResolver.parseMetaFallback(html: blockedHTML, ref: exploreRef) == nil)
    }

    @Test("LocalExtensionBridgeServer serves auth, folders, socialBookmark ingest, and incremental deduplication over 127.0.0.1")
    func localExtensionBridgeServerRoundTripAndDedup() async throws {
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
        #expect(status.isRunning)
        #expect(status.port > 0)

        let baseURL = status.baseURL
        let session = URLSession(configuration: .ephemeral)
        defer { session.invalidateAndCancel() }

        // 1. Public health probe exposes autoPair capability without leaking token
        let (healthData, healthResp) = try await session.data(from: try #require(URL(string: "\(baseURL)/api/v1/health")))
        #expect((healthResp as? HTTPURLResponse)?.statusCode == 200)
        let healthJSON = try #require(JSONSerialization.jsonObject(with: healthData) as? [String: Any])
        #expect(healthJSON["ok"] as? Bool == true)
        #expect(healthJSON["app"] as? String == "charkle-macos")
        #expect(healthJSON["autoPair"] as? Bool == true)
        #expect(healthJSON["token"] == nil)

        // 1b. Zero-config local auto-pair enforces strict extension Origin + X-Charkle-Extension header
        func sendLocalPair(origin: String?, includeHeader: Bool) async throws -> (Int, [String: Any]) {
            var req = URLRequest(url: try #require(URL(string: "\(baseURL)/api/v1/auth/local-pair")))
            req.httpMethod = "POST"
            if let origin { req.setValue(origin, forHTTPHeaderField: "Origin") }
            if includeHeader { req.setValue("1", forHTTPHeaderField: "X-Charkle-Extension") }
            let (data, resp) = try await session.data(for: req)
            let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
            let json = (try? JSONSerialization.jsonObject(with: data) as? [String: Any]) ?? [:]
            return (code, json)
        }

        // Rejects external website, localhost webpage, missing origin, and missing custom header
        let (webRejectCode, _) = try await sendLocalPair(origin: "https://evil.example", includeHeader: true)
        #expect(webRejectCode == 403)
        let (localhostRejectCode, _) = try await sendLocalPair(origin: "http://127.0.0.1:3000", includeHeader: true)
        #expect(localhostRejectCode == 403)
        let (noOriginCode, _) = try await sendLocalPair(origin: nil, includeHeader: true)
        #expect(noOriginCode == 403)
        let (noHeaderCode, _) = try await sendLocalPair(origin: "safari-web-extension://TEST-UUID", includeHeader: false)
        #expect(noHeaderCode == 403)

        // Accepts Safari & Chrome browser extension origins with custom handshake header
        let (safariPairCode, safariPairJSON) = try await sendLocalPair(origin: "safari-web-extension://TEST-UUID", includeHeader: true)
        #expect(safariPairCode == 200)
        #expect(safariPairJSON["ok"] as? Bool == true)
        #expect(safariPairJSON["token"] as? String == token)

        let (chromePairCode, chromePairJSON) = try await sendLocalPair(origin: "chrome-extension://abcdefghijklmnopabcdefghijklmnop", includeHeader: true)
        #expect(chromePairCode == 200)
        #expect(chromePairJSON["token"] as? String == token)

        // Respects disabling auto-pair in Settings
        await server.updateAutoPairEnabled(false)
        let (disabledPairCode, disabledPairJSON) = try await sendLocalPair(origin: "safari-web-extension://TEST-UUID", includeHeader: true)
        #expect(disabledPairCode == 403)
        #expect(disabledPairJSON["code"] as? String == "AUTO_PAIR_DISABLED")
        await server.updateAutoPairEnabled(true)

        // 2. Auth enforcement (wrong token rejected with 401 on protected routes, authenticated: false on /auth/status)
        var unauthFoldersReq = URLRequest(url: try #require(URL(string: "\(baseURL)/api/v1/folders")))
        unauthFoldersReq.setValue("Bearer wrong-token", forHTTPHeaderField: "Authorization")
        let (_, unauthResp) = try await session.data(for: unauthFoldersReq)
        #expect((unauthResp as? HTTPURLResponse)?.statusCode == 401)

        var authStatusReq = URLRequest(url: try #require(URL(string: "\(baseURL)/api/v1/auth/status")))
        authStatusReq.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        let (authData, authResp) = try await session.data(for: authStatusReq)
        #expect((authResp as? HTTPURLResponse)?.statusCode == 200)
        let authJSON = try #require(JSONSerialization.jsonObject(with: authData) as? [String: Any])
        #expect(authJSON["authenticated"] as? Bool == true)

        // 3. Create + reuse folder idempotently
        func postJSON(_ path: String, payload: [String: Any]) async throws -> (Int, [String: Any]) {
            var req = URLRequest(url: try #require(URL(string: "\(baseURL)\(path)")))
            req.httpMethod = "POST"
            req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
            req.httpBody = try JSONSerialization.data(withJSONObject: payload)
            let (data, resp) = try await session.data(for: req)
            let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
            let json = (try? JSONSerialization.jsonObject(with: data) as? [String: Any]) ?? [:]
            return (code, json)
        }

        let (fCode1, fJson1) = try await postJSON("/api/v1/folders", payload: ["name": "小红书收藏", "reuseExisting": true])
        #expect(fCode1 == 201)
        let folderID = try #require((fJson1["folder"] as? [String: Any])?["id"] as? String)

        let (fCode2, fJson2) = try await postJSON("/api/v1/folders", payload: ["name": "小红书收藏", "reuseExisting": true])
        #expect(fCode2 == 200)
        #expect(((fJson2["folder"] as? [String: Any])?["id"] as? String) == folderID)

        // 4. Ingest pre-extracted Xiaohongshu socialBookmark with inline cover image (zero external network needed)
        let coverDataURL = "data:image/png;base64,iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8BQDwAEhQGAhKmMIQAAAABJRU5ErkJggg=="
        let xhsPayload: [String: Any] = [
            "type": "socialBookmark",
            "platform": "xiaohongshu",
            "originalURL": "https://www.xiaohongshu.com/explore/66a1b2c3d4e5f60718293a4b?xsec_token=FIRST_TOKEN",
            "authorName": "林清",
            "authorHandle": "5f00112233445566778899aa",
            "articleTitle": "工作室灵感配色",
            "bodyText": "低饱和暖灰与钴蓝的组合非常耐看",
            "attachments": [
                ["kind": "photo", "url": "https://sns-webpic-qc.xhscdn.com/p1.webp"],
                ["kind": "photo", "url": "https://sns-webpic-qc.xhscdn.com/p2.webp"]
            ],
            "coverDataUrl": coverDataURL,
            "tags": ["小红书", "配色"]
        ]

        let (ingestCode, ingestJson) = try await postJSON(
            "/api/v1/assets/ingest",
            payload: [
                "inputs": [xhsPayload],
                "targetFolderID": folderID,
                "skipDuplicates": true
            ]
        )
        #expect(ingestCode == 201)
        #expect(ingestJson["created"] as? Int == 1)
        #expect(ingestJson["skipped"] as? Int == 0)

        // 5. Existing sources endpoint returns token-independent canonical key & second import skips duplicate cleanly
        var existReq = URLRequest(url: try #require(URL(string: "\(baseURL)/api/v1/assets/existing-sources")))
        existReq.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        let (existData, existResp) = try await session.data(for: existReq)
        #expect((existResp as? HTTPURLResponse)?.statusCode == 200)
        let existJSON = try #require(JSONSerialization.jsonObject(with: existData) as? [String: Any])
        let canonicalKeys = existJSON["canonicalKeys"] as? [String] ?? []
        #expect(canonicalKeys.contains("xhs:66a1b2c3d4e5f60718293a4b"))

        var rotatedTokenPayload = xhsPayload
        rotatedTokenPayload["originalURL"] = "https://www.xiaohongshu.com/explore/66a1b2c3d4e5f60718293a4b?xsec_token=ROTATED_TOKEN"
        let (dupCode, dupJson) = try await postJSON(
            "/api/v1/assets/ingest",
            payload: [
                "inputs": [rotatedTokenPayload],
                "targetFolderID": folderID,
                "skipDuplicates": true
            ]
        )
        #expect(dupCode == 200)
        #expect(dupJson["created"] as? Int == 0)
        #expect(dupJson["skipped"] as? Int == 1)

        // Verify persisted AssetRecord metadata & native Xiaohongshu card (3:4 900x1200 cover + 240px title footer = 900x1440)
        let assets = try await engine.fetchAssets(matching: FilterCriteria())
        let savedXHS = try #require(assets.first(where: { $0.richMetadata?.socialPost?.platform == .xiaohongshu }))
        #expect(savedXHS.folderID == UUID(uuidString: folderID))
        #expect(savedXHS.displayTypeLabel == "小红书 笔记")
        #expect(savedXHS.richMetadata?.socialPost?.attachments.count == 2)
        #expect(!savedXHS.isExternalWebLink)
        #expect(savedXHS.pixelWidth == 900)
        #expect(savedXHS.pixelHeight == 1_440)
        #expect(abs(savedXHS.aspectRatio - 0.625) < 0.001)

        // 6. Verify automatic legacy Xiaohongshu cover migration upgrades old 800x920 records to 900x1440 idempotently
        let localCoverFile = dir.appending(path: "legacy-xhs-cover.png")
        let pngBytes = try #require(Data(base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8BQDwAEhQGAhKmMIQAAAABJRU5ErkJggg=="))
        try pngBytes.write(to: localCoverFile)
        var legacy = savedXHS
        legacy.pixelWidth = 800
        legacy.pixelHeight = 920
        if var post = legacy.richMetadata?.socialPost {
            post.attachments = [SocialMediaAttachment(kind: .photo, url: localCoverFile.absoluteString)]
            post.mediaURLs = [localCoverFile.absoluteString]
            legacy.richMetadata?.socialPost = post
        }
        let legacySnapshot = legacy
        _ = try await engine.database.transaction { store in
            try store.saveAssetLocally(legacySnapshot)
        }

        let upgradedFirst = await engine.upgradeLegacyXiaohongshuCoversIfNeeded()
        #expect(upgradedFirst == [savedXHS.id])
        let migratedXHS = try #require(try await engine.fetchAsset(id: savedXHS.id))
        #expect(migratedXHS.pixelWidth == 900)
        #expect(migratedXHS.pixelHeight == 1_440)
        #expect(abs(migratedXHS.aspectRatio - 0.625) < 0.001)

        // Second pass is an instant no-op
        let upgradedSecond = await engine.upgradeLegacyXiaohongshuCoversIfNeeded()
        #expect(upgradedSecond.isEmpty)
    }
}
