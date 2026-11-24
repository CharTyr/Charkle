import AppKit
@testable import CharkleCanvas
@testable import CharkleCore
import Foundation
import SwiftUI
import Testing

@Suite("CharkleCanvas GPU, Virtualization & Memory Performance", .serialized)
struct PerformanceCanvasTests {

    private static func durationMs(_ duration: Duration) -> Double {
        Double(duration.components.seconds) * 1_000.0
            + Double(duration.components.attoseconds) / 1e15
    }

    private static func makeSyntheticAssets(count: Int, allImages: Bool = false) -> [AssetRecord] {
        var assets: [AssetRecord] = []
        assets.reserveCapacity(count)
        let palette = ["#2A60E0", "#D95D48", "#4D7C5F", "#C7933B", "#2C3038"]
        for i in 0..<count {
            let w = 800 + (i % 7) * 120
            let h = 600 + ((i * 5) % 9) * 140
            let isVideo = !allImages && (i % 19 == 0)
            assets.append(AssetRecord(
                title: "Canvas Ref \(i)",
                fileName: isVideo ? "ref-\(i).mp4" : "ref-\(i).jpg",
                mediaKind: isVideo ? .video : .image,
                pixelWidth: w,
                pixelHeight: h,
                durationSeconds: isVideo ? Double((i % 240) + 5) : nil,
                dominantColors: [LabColor.fromHex(palette[i % palette.count])]
            ))
        }
        return assets
    }

    // MARK: - Benchmarks (Reproducible Before/After Microbenchmarks)

    @Test("Benchmark: ThumbnailImageLoader cache lookup & sliding-window prefetch throughput")
    @MainActor
    func benchmarkThumbnailLoaderLookupAndPrefetch() {
        let loader = ThumbnailImageLoader(engine: PlaceholderCharkleEngine())
        let ids = (0..<256).map { _ in UUID() }

        let lookupStart = ContinuousClock.now
        var hits = 0
        for iter in 0..<50_000 {
            let id = ids[iter & 255]
            if loader.cachedCGImage(for: id, tier: .grid520) != nil {
                hits &+= 1
            }
        }
        let lookupMs = Self.durationMs(lookupStart.duration(to: .now))

        let prefetchStart = ContinuousClock.now
        for step in 0..<400 {
            let offset = (step / 4) % 200
            let window = Array(ids[offset..<(offset + 16)])
            loader.prefetch(assetIDs: window, tier: .grid520)
        }
        let prefetchMs = Self.durationMs(prefetchStart.duration(to: .now))
        loader.clearMemoryCache()

        print(String(format: "[BENCH][ThumbnailLoader] 50k cachedCGImage lookups: %.2f ms | 400 sliding prefetch calls: %.2f ms (hits=%d)", lookupMs, prefetchMs, hits))
        #expect(lookupMs < 5_000)
        #expect(prefetchMs < 5_000)
    }

    @Test("Benchmark: RingGalleryMTKView.configure diffing over 2,000 assets (200 SwiftUI updateNSView ticks)")
    @MainActor
    func benchmarkRingGalleryConfigureDiffing() {
        let assets = Self.makeSyntheticAssets(count: 2_000)
        let loader = ThumbnailImageLoader(engine: PlaceholderCharkleEngine())
        let view = RingGalleryMTKView(loader: loader)
        let callbacks = RingGalleryInteractionCallbacks(
            onFrontAssetChanged: { _ in },
            onOpenQuickLook: { _ in }
        )

        // Warm initial configuration
        view.configure(
            assets: assets,
            selectedAssetID: assets.first?.id,
            params: .default,
            isDarkMode: false,
            reduceMotion: false,
            isOverlayPresented: false,
            topSafeInset: 64,
            loaderInvalidationVersion: 0,
            callbacks: callbacks
        )

        let start = ContinuousClock.now
        for tick in 0..<200 {
            view.configure(
                assets: assets,
                selectedAssetID: assets[tick % 20].id,
                params: .default,
                isDarkMode: false,
                reduceMotion: false,
                isOverlayPresented: false,
                topSafeInset: 64,
                loaderInvalidationVersion: 0,
                callbacks: callbacks
            )
        }
        let elapsedMs = Self.durationMs(start.duration(to: .now))
        view.teardown()

        print(String(format: "[BENCH][RingConfigure] 200 configure() updates x 2,000 assets: %.2f ms", elapsedMs))
        #expect(elapsedMs < 10_000)
    }

    @Test("Benchmark: RingGalleryMath 1,000 frames of 3D projection over 2,000 assets")
    @MainActor
    func benchmarkRingGalleryProjection() {
        let assets = Self.makeSyntheticAssets(count: 2_000)
        let params = RingGalleryParameters.default
        let track = RingCardTrack.build(from: assets, params: params)
        let viewport = CGSize(width: 1440, height: 900)

        let start = ContinuousClock.now
        var drawnCards = 0
        for frame in 0..<1_000 {
            let offset = Double(frame) * 14.5
            let cards = RingGalleryMath.visibleOutsideCards(
                track: track,
                offset: offset,
                params: params,
                viewportSize: viewport,
                cardScale: 1.2
            )
            drawnCards &+= cards.count
        }
        let elapsedMs = Self.durationMs(start.duration(to: .now))
        print(String(format: "[BENCH][RingProjection] 1,000 frames x 2,000 assets: %.2f ms (cards=%d)", elapsedMs, drawnCards))
        #expect(drawnCards > 0)
    }

    @Test("Benchmark: CanvasSupport hex color parsing and CanvasFormatters hot paths")
    @MainActor
    func benchmarkCanvasSupportHotPaths() {
        let hexes = ["#1E2024", "#F6F6F5", "#2A60E0", "#D95D48", " #4D7C5F ", "#C7933B"]
        let fileNames = ["studio-shot.png", "animation.webp", "reference-clip.mp4", "vector-icon.svg", "archive.pdf", "README"]

        let start = ContinuousClock.now
        var lightCount = 0
        var badgeChars = 0
        for i in 0..<50_000 {
            let hex = hexes[i % hexes.count]
            _ = NSColor.charkleHex(hex)
            if Color.charkleIsLightHex(hex) { lightCount &+= 1 }
            badgeChars &+= CanvasFormatters.durationString(Double(i % 600)).count
            badgeChars &+= CanvasFormatters.fileExtensionBadge(for: fileNames[i % fileNames.count]).count
        }
        let elapsedMs = Self.durationMs(start.duration(to: .now))
        print(String(format: "[BENCH][CanvasSupport] 50k hex+formatter ops: %.2f ms (light=%d, chars=%d)", elapsedMs, lightCount, badgeChars))
        #expect(badgeChars > 0)
    }

    @Test("Benchmark: MasonryLayoutEngine 10,000 items compute + 1,000 viewport queries")
    func benchmarkMasonryLayoutAndQueries() {
        let assets = Self.makeSyntheticAssets(count: 10_000)

        let computeStart = ContinuousClock.now
        let snapshot = MasonryLayoutEngine.compute(
            assets: assets,
            layoutMode: .verticalMasonry,
            containerWidth: 1440,
            targetColumnWidth: 228,
            spacing: 12,
            horizontalPadding: 20,
            topInset: 76,
            bottomInset: 44
        )
        let computeMs = Self.durationMs(computeStart.duration(to: .now))

        let queryStart = ContinuousClock.now
        var totalVisible = 0
        for step in 0..<1_000 {
            let y = CGFloat(step) * (snapshot.totalHeight / 1_000.0)
            totalVisible &+= snapshot.visibleItems(minY: y, maxY: y + 1_400).count
        }
        let queryMs = Self.durationMs(queryStart.duration(to: .now))

        print(String(format: "[BENCH][Masonry] 10k compute: %.2f ms | 1,000 viewport queries: %.2f ms (totalVisible=%d)", computeMs, queryMs, totalVisible))
        #expect(totalVisible > 0)
    }

    // MARK: - Regression Tests for Memory, Layer, GPU & Diffing Optimizations

    @Test("Masonry virtualization collapses default tile layers, caps reuse pool, avoids bottomInset reflows, and releases offscreen resources")
    @MainActor
    func masonryVirtualizationLayerCollapsePoolCapAndInsetFastPath() {
        let assets = Self.makeSyntheticAssets(count: 500, allImages: true)
        let signature = MasonryAssetsSignature(
            revision: 1,
            count: assets.count,
            firstID: assets.first?.id,
            lastID: assets.last?.id
        )
        let loader = ThumbnailImageLoader(engine: PlaceholderCharkleEngine())
        let scrollView = MasonryScrollView(frame: NSRect(x: 0, y: 0, width: 1200, height: 800))
        scrollView.layoutSubtreeIfNeeded()
        let doc = scrollView.masonryDocument
        doc.loader = loader
        let callbacks = MasonryCallbacks()

        doc.applyState(
            assets: assets,
            signature: signature,
            folders: [],
            loaderInvalidationVersion: 0,
            selectedIDs: [],
            cutIDs: [],
            layoutMode: .verticalMasonry,
            targetColumnWidth: 228,
            topInset: 76,
            bottomInset: 44,
            sideChromeWidth: 232,
            activeQuickLookID: nil,
            revealRequest: nil,
            isDarkMode: false,
            reduceMotion: true,
            callbacks: callbacks
        )

        #expect(doc.activeTileCountForTesting > 0)
        #expect(doc.activeTileCountForTesting < 45)
        // Normal image tile only allocates 2 sublayers (imageLayer + borderLayer);
        // clipLayer is merged into imageLayer and cut/selection/pin/media overlays stay lazy.
        #expect(doc.maxActiveTileSublayerCountForTesting == 2)

        // Selecting a visible asset lazily attaches only the checkmark badge (+1 sublayer).
        let firstID = assets[0].id
        doc.applyState(
            assets: assets,
            signature: signature,
            folders: [],
            loaderInvalidationVersion: 0,
            selectedIDs: [firstID],
            cutIDs: [],
            layoutMode: .verticalMasonry,
            targetColumnWidth: 228,
            topInset: 76,
            bottomInset: 44,
            sideChromeWidth: 232,
            activeQuickLookID: nil,
            revealRequest: nil,
            isDarkMode: false,
            reduceMotion: true,
            callbacks: callbacks
        )
        #expect(doc.maxActiveTileSublayerCountForTesting == 3)

        // Toggling bottomInset (e.g. floating multi-select action bar 44pt <-> 104pt) MUST adjust
        // totalHeight in O(1) with ZERO full layout recomputations.
        let recomputesBeforeInset = doc.layoutRecomputeCountForTesting
        let heightAt44 = doc.currentLayoutTotalHeightForTesting
        doc.applyState(
            assets: assets,
            signature: signature,
            folders: [],
            loaderInvalidationVersion: 0,
            selectedIDs: [firstID],
            cutIDs: [],
            layoutMode: .verticalMasonry,
            targetColumnWidth: 228,
            topInset: 76,
            bottomInset: 104,
            sideChromeWidth: 232,
            activeQuickLookID: nil,
            revealRequest: nil,
            isDarkMode: false,
            reduceMotion: true,
            callbacks: callbacks
        )
        #expect(doc.layoutRecomputeCountForTesting == recomputesBeforeInset)
        #expect(abs(doc.currentLayoutTotalHeightForTesting - (heightAt44 + 60)) < 0.01)

        // Scrolling deep recycles tiles with reusePool capped <= 32 and ZERO lingering CALayer.contents.
        for offsetY in [CGFloat(2400), CGFloat(5200), CGFloat(8400), CGFloat(0)] {
            scrollView.contentView.scroll(to: NSPoint(x: 0, y: offsetY))
            doc.handleScrollBoundsChanged()
            #expect(doc.reusePoolCountForTesting <= 32)
            #expect(doc.pooledTilesHoldingImageCountForTesting == 0)
        }

        // Dismantling / leaving window releases all active & pooled tiles immediately.
        doc.releaseOffscreenResources()
        #expect(doc.activeTileCountForTesting == 0)
        #expect(doc.reusePoolCountForTesting == 0)
    }

    @Test("ThumbnailImageLoader keeps NSImage lazy for CGImage callers and honors memory-pressure trimming without mutating budgets")
    @MainActor
    func thumbnailLoaderLazyNSImageAndMemoryPressure() async throws {
        let dir = try BackendFixture.directory()
        defer { try? FileManager.default.removeItem(at: dir) }

        let engine = try BackendFixture.makeEngine(dir)
        let pngData = try BackendFixture.artwork("#2A60E0")
        let sourceURL = dir.appendingPathComponent("lazy-thumb-sample.png")
        try pngData.write(to: sourceURL)

        let ingested = try await engine.ingest([.fileURL(sourceURL)], targetFolderID: nil, targetBoardID: nil)
        let asset = try #require(ingested.first)
        let loader = ThumbnailImageLoader(engine: engine)

        // 1. Decoding via loadCGImage populates the CGImage cache WITHOUT eagerly allocating an NSImage wrapper.
        let cgImage = await loader.loadCGImage(for: asset.id, tier: .grid520)
        #expect(cgImage != nil)
        #expect(loader.cachedCGImage(for: asset.id, tier: .grid520) != nil)
        #expect(loader.hasMaterializedNSImage(for: asset.id, tier: .grid520) == false)

        // 2. Requesting cachedImage lazily materializes NSImage on demand.
        let nsImage = loader.cachedImage(for: asset.id, tier: .grid520)
        #expect(nsImage != nil)
        #expect(loader.hasMaterializedNSImage(for: asset.id, tier: .grid520) == true)

        // 3. Loading original populates originalCache; warning pressure evicts originals while preserving grid thumbnails & limits.
        let orig = await loader.loadOriginalImage(for: asset.id, url: sourceURL)
        #expect(orig != nil)
        #expect(loader.cachedOriginalImage(for: asset.id) != nil)

        loader.handleMemoryPressure(critical: false)
        #expect(loader.cachedOriginalImage(for: asset.id) == nil)
        #expect(loader.cachedCGImage(for: asset.id, tier: .grid520) != nil)
        #expect(loader.currentCacheCountLimit == 1_500)
        #expect(loader.currentCacheCostLimit == 320 * 1024 * 1024)
        #expect(loader.currentOriginalCacheCountLimit == 4)

        // 4. Critical pressure evicts thumbnail cache too while preserving configured budgets.
        loader.handleMemoryPressure(critical: true)
        #expect(loader.cachedCGImage(for: asset.id, tier: .grid520) == nil)
        #expect(loader.currentCacheCountLimit == 1_500)
        #expect(loader.currentCacheCostLimit == 320 * 1024 * 1024)
        #expect(loader.currentOriginalCacheCountLimit == 4)

        // 5. Low-resource mode skips background prefetch completely.
        loader.setLowResourceMode(true)
        loader.prefetch(assetIDs: [asset.id], tier: .grid520)
        try await Task.sleep(for: .milliseconds(30))
        #expect(loader.cachedCGImage(for: asset.id, tier: .grid520) == nil)
    }

    @Test("RingGalleryMTKView avoids redundant RingCardTrack rebuilds and suspends Metal loop when overlay covers gallery")
    @MainActor
    func ringGalleryConfigureZeroRebuildAndOverlaySuspension() {
        let assets = Self.makeSyntheticAssets(count: 2_000)
        let loader = ThumbnailImageLoader(engine: PlaceholderCharkleEngine())
        let view = RingGalleryMTKView(loader: loader)
        let callbacks = RingGalleryInteractionCallbacks(
            onFrontAssetChanged: { _ in },
            onOpenQuickLook: { _ in }
        )

        view.configure(
            assets: assets,
            selectedAssetID: assets.first?.id,
            params: .default,
            isDarkMode: false,
            reduceMotion: false,
            isOverlayPresented: false,
            topSafeInset: 64,
            loaderInvalidationVersion: 0,
            callbacks: callbacks
        )
        #expect(view.trackRebuildCountForTesting == 1)

        // 50 SwiftUI updateNSView ticks with unchanged asset list must NOT rebuild RingCardTrack.
        for tick in 0..<50 {
            view.configure(
                assets: assets,
                selectedAssetID: assets[tick % 10].id,
                params: .default,
                isDarkMode: false,
                reduceMotion: false,
                isOverlayPresented: false,
                topSafeInset: 64,
                loaderInvalidationVersion: 0,
                callbacks: callbacks
            )
        }
        #expect(view.trackRebuildCountForTesting == 1)

        // Presenting Quick Look / Settings overlay suspends the render loop cleanly.
        view.configure(
            assets: assets,
            selectedAssetID: assets.first?.id,
            params: .default,
            isDarkMode: false,
            reduceMotion: false,
            isOverlayPresented: true,
            topSafeInset: 64,
            loaderInvalidationVersion: 0,
            callbacks: callbacks
        )
        #expect(view.isRenderSuspendedForTesting == true)
        #expect(view.isPaused == true)

        // Stepping while overlay-suspended must not wake the Metal loop.
        view.step(by: 1)
        #expect(view.isPaused == true)

        // Teardown purges textures and active decode tasks.
        view.teardown()
        #expect(view.texturePoolEntryCountForTesting == 0)
        #expect(view.texturePoolActiveTasksForTesting == 0)
    }

    @Test("Moodboard FreeformCameraState coarse culling buckets and FreeformInteractionState effectiveFrame avoid churn")
    @MainActor
    func freeformCameraBucketsAndInteractionEffectiveFrame() {
        let camera = FreeformCameraState()
        camera.center = CGPoint(x: 100, y: 120)
        camera.zoom = 1.0
        let viewport = CGSize(width: 1200, height: 800)

        let bucketRect1 = camera.bucketedVisibleWorldRect(viewportSize: viewport, overscan: 600)
        // Small intra-bucket pan (< 240pt) keeps the coarse culling rect identical.
        camera.center = CGPoint(x: 180, y: 190)
        let bucketRect2 = camera.bucketedVisibleWorldRect(viewportSize: viewport, overscan: 600)
        #expect(bucketRect1 == bucketRect2)
        // Nearby node intersects visible bucket; far off-screen node is culled.
        #expect(bucketRect2.intersects(CGRect(x: 50, y: 50, width: 260, height: 220)) == true)
        #expect(bucketRect2.intersects(CGRect(x: 9_000, y: 9_000, width: 260, height: 220)) == false)

        let interaction = FreeformInteractionState()
        let baseFrame = BoardRect(x: 100, y: 200, width: 300, height: 240)
        let dragged = BoardNode(kind: .note(title: nil, text: "A", style: .paper, fontSize: 14), frame: baseFrame)
        let locked = BoardNode(kind: .note(title: nil, text: "B", style: .paper, fontSize: 14), frame: baseFrame, isLocked: true)
        let groupChild = BoardNode(kind: .note(title: nil, text: "C", style: .paper, fontSize: 14), frame: baseFrame)
        let stationary = BoardNode(kind: .note(title: nil, text: "D", style: .paper, fontSize: 14), frame: baseFrame)

        interaction.activeNodeDragID = dragged.id
        interaction.activeNodeDragDelta = CGSize(width: 45, height: -20)
        interaction.activeGroupChildIDs = [groupChild.id]
        let selected: Set<UUID> = [dragged.id]

        let draggedFrame = interaction.effectiveFrame(for: dragged, selectedNodeIDs: selected)
        #expect(draggedFrame.x == 145 && draggedFrame.y == 180)
        let childFrame = interaction.effectiveFrame(for: groupChild, selectedNodeIDs: selected)
        #expect(childFrame.x == 145 && childFrame.y == 180)
        #expect(interaction.effectiveFrame(for: locked, selectedNodeIDs: [locked.id]) == baseFrame)
        #expect(interaction.effectiveFrame(for: stationary, selectedNodeIDs: selected) == baseFrame)

        let liveResize = BoardRect(x: 100, y: 200, width: 420, height: 310)
        interaction.resizingNodeID = stationary.id
        interaction.liveResizeFrame = liveResize
        #expect(interaction.effectiveFrame(for: stationary, selectedNodeIDs: selected) == liveResize)
    }

    @Test("CanvasSupport zero-allocation hex parser and formatters preserve exact output parity")
    @MainActor
    func canvasSupportZeroAllocHexAndFormattersParity() {
        let rgb = CanvasHexParser.parseRGB("  #2a60E0 \n")
        #expect(rgb != nil)
        if let rgb {
            #expect(rgb.r == 0x2A)
            #expect(rgb.g == 0x60)
            #expect(rgb.b == 0xE0)
        }
        #expect(CanvasHexParser.parseRGB("1E2024") != nil)
        #expect(CanvasHexParser.parseRGB("#FFF") == nil)
        #expect(CanvasHexParser.parseRGB("#GGGGGG") == nil)
        #expect(CanvasHexParser.parseRGB("") == nil)

        #expect(Color.charkleIsLightHex("#F6F6F5") == true)
        #expect(Color.charkleIsLightHex("#1E2024") == false)
        #expect(Color.charkleIsLightHex("invalid") == false)

        #expect(CanvasFormatters.durationString(-5) == "0:00")
        #expect(CanvasFormatters.durationString(0) == "0:00")
        #expect(CanvasFormatters.durationString(65) == "1:05")
        #expect(CanvasFormatters.durationString(3661) == "61:01")

        #expect(CanvasFormatters.fileExtensionBadge(for: "studio-shot.png") == "PNG")
        #expect(CanvasFormatters.fileExtensionBadge(for: "archive.tar.gz") == "GZ")
        #expect(CanvasFormatters.fileExtensionBadge(for: "README") == "FILE")
        #expect(CanvasFormatters.fileExtensionBadge(for: ".hidden") == "FILE")
        #expect(CanvasFormatters.fileExtensionBadge(for: "clip.mp4/") == "MP4")
    }
}
