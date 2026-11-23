import CharkleCanvas
import CharkleCore
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
}
