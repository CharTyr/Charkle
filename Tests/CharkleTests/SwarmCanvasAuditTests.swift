import AppKit
@testable import CharkleCanvas
@testable import CharkleCore
import CoreGraphics
import Foundation
import os
import Testing

@Suite("Swarm macOS Canvas Audit Regressions", .serialized)
struct SwarmCanvasAuditTests {

    private static func makeSyntheticAssets(count: Int, mediaKind: MediaKind = .image) -> [AssetRecord] {
        var assets: [AssetRecord] = []
        assets.reserveCapacity(count)
        let palette = ["#2A60E0", "#D95D48", "#4D7C5F", "#C7933B", "#2C3038"]
        for i in 0..<count {
            let w = 800 + (i % 5) * 160
            let h = 600 + ((i * 3) % 7) * 140
            assets.append(AssetRecord(
                title: "Audit Ref \(i)",
                fileName: mediaKind == .video ? "clip-\(i).mp4" : "ref-\(i).png",
                mediaKind: mediaKind,
                pixelWidth: w,
                pixelHeight: h,
                durationSeconds: mediaKind == .video ? 12.0 : nil,
                dominantColors: [LabColor.fromHex(palette[i % palette.count])]
            ))
        }
        return assets
    }

    private static func makeSolidImage(red: UInt8, green: UInt8, blue: UInt8, width: Int = 64, height: Int = 64) -> NSImage? {
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        var pixels = [UInt8](repeating: 255, count: width * height * 4)
        for idx in stride(from: 0, to: pixels.count, by: 4) {
            pixels[idx] = red
            pixels[idx + 1] = green
            pixels[idx + 2] = blue
            pixels[idx + 3] = 255
        }
        let data = Data(pixels)
        guard let provider = CGDataProvider(data: data as CFData),
              let cg = CGImage(
                width: width,
                height: height,
                bitsPerComponent: 8,
                bitsPerPixel: 32,
                bytesPerRow: width * 4,
                space: colorSpace,
                bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
                provider: provider,
                decode: nil,
                shouldInterpolate: false,
                intent: .defaultIntent
              ) else {
            return nil
        }
        return NSImage(cgImage: cg, size: NSSize(width: width, height: height))
    }

    private static func firstPixelRGB(of image: NSImage) -> (r: UInt8, g: UInt8, b: UInt8)? {
        guard let cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return nil }
        var pixel = [UInt8](repeating: 0, count: 4)
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        guard let ctx = CGContext(
            data: &pixel,
            width: 1,
            height: 1,
            bitsPerComponent: 8,
            bytesPerRow: 4,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else {
            return nil
        }
        ctx.draw(cg, in: CGRect(x: 0, y: 0, width: 1, height: 1))
        return (pixel[0], pixel[1], pixel[2])
    }

    private static func isRunningOnMainThread() -> Bool {
        Thread.isMainThread
    }

    // MARK: - 1. ThumbnailImageLoader Targeted Invalidation & Cropped Cache ABA Safety

    @Test("ThumbnailImageLoader tracks targeted invalidation history and isolates cropped thumbnails by assetID + version")
    @MainActor
    func thumbnailLoaderTargetedInvalidationAndCroppedCacheSafety() throws {
        let loader = ThumbnailImageLoader(engine: PlaceholderCharkleEngine())
        let idA = UUID()
        let idB = UUID()
        let idC = UUID()

        let v0 = loader.invalidationVersion
        #expect(loader.invalidatedAssetIDs(since: v0) == [])
        #expect(loader.assetInvalidationVersion(for: idA) == 0)

        loader.invalidate(assetID: idA)
        let v1 = loader.invalidationVersion
        #expect(v1 == v0 + 1)
        #expect(loader.invalidatedAssetIDs(since: v0) == Set([idA]))
        #expect(loader.assetInvalidationVersion(for: idA) == 1)
        #expect(loader.assetInvalidationVersion(for: idB) == 0)

        loader.invalidate(assetIDs: [idB, idC])
        let v2 = loader.invalidationVersion
        #expect(v2 == v1 + 1)
        #expect(loader.invalidatedAssetIDs(since: v0) == Set([idA, idB, idC]))
        #expect(loader.invalidatedAssetIDs(since: v1) == Set([idB, idC]))
        #expect(loader.invalidatedAssetIDs(since: v2) == [])

        // Full memory cache clear invalidates the entire delta history (`nil` sentinel)
        loader.clearMemoryCache()
        let v3 = loader.invalidationVersion
        #expect(v3 == v2 + 1)
        #expect(loader.invalidatedAssetIDs(since: v0) == nil)
        #expect(loader.invalidatedAssetIDs(since: v2) == nil)
        #expect(loader.invalidatedAssetIDs(since: v3) == [])

        // Cropped image cache keys by `(assetID, tier, invalidationVersion, crop)` — never pointer address alone
        let redImg = try #require(Self.makeSolidImage(red: 220, green: 30, blue: 30))
        let blueImg = try #require(Self.makeSolidImage(red: 30, green: 80, blue: 230))
        let crop = NormalizedCropRect(x: 0.1, y: 0.1, width: 0.5, height: 0.5)

        let cropA = try #require(AssetThumbnailSurface.cachedCroppedImage(
            redImg,
            assetID: idA,
            tier: .grid520,
            invalidationVersion: 0,
            normalized: crop
        ))
        let cropB = try #require(AssetThumbnailSurface.cachedCroppedImage(
            blueImg,
            assetID: idB,
            tier: .grid520,
            invalidationVersion: 0,
            normalized: crop
        ))
        let cropAReplaced = try #require(AssetThumbnailSurface.cachedCroppedImage(
            blueImg,
            assetID: idA,
            tier: .grid520,
            invalidationVersion: 1,
            normalized: crop
        ))

        let rgbA = try #require(Self.firstPixelRGB(of: cropA))
        let rgbB = try #require(Self.firstPixelRGB(of: cropB))
        let rgbAReplaced = try #require(Self.firstPixelRGB(of: cropAReplaced))

        #expect(rgbA.r > 180 && rgbA.b < 80)
        #expect(rgbB.b > 180 && rgbB.r < 80)
        #expect(rgbAReplaced.b > 180 && rgbAReplaced.r < 80)
    }

    // MARK: - 2. Masonry Multi-Window Geometry Registry, Overlay Suspension & Targeted Cover Refresh

    @Test("MasonryCardGeometryRegistry isolates primary window from auxiliary panels and cleans up on unregister")
    @MainActor
    func masonryCardGeometryRegistryMultiWindowIsolation() {
        let assets = Self.makeSyntheticAssets(count: 12)
        let signature = MasonryAssetsSignature(
            revision: 1,
            count: assets.count,
            firstID: assets.first?.id,
            lastID: assets.last?.id
        )
        let loader = ThumbnailImageLoader(engine: PlaceholderCharkleEngine())

        let primaryWindow = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1000, height: 720),
            styleMask: [.titled, .resizable],
            backing: .buffered,
            defer: false
        )
        let primaryScroll = MasonryScrollView(frame: NSRect(x: 0, y: 0, width: 1000, height: 720))
        primaryWindow.contentView = primaryScroll
        primaryScroll.layoutSubtreeIfNeeded()
        primaryScroll.masonryDocument.loader = loader
        primaryScroll.masonryDocument.applyState(
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
            isOverlayPresented: false,
            revealRequest: nil,
            isDarkMode: false,
            reduceMotion: true,
            callbacks: MasonryCallbacks()
        )

        let panelWindow = NSPanel(
            contentRect: NSRect(x: 20, y: 20, width: 420, height: 320),
            styleMask: [.nonactivatingPanel, .borderless],
            backing: .buffered,
            defer: false
        )
        let panelScroll = MasonryScrollView(frame: NSRect(x: 0, y: 0, width: 420, height: 320))
        panelWindow.contentView = panelScroll
        panelScroll.layoutSubtreeIfNeeded()
        panelScroll.masonryDocument.loader = loader
        panelScroll.masonryDocument.applyState(
            assets: Array(assets.suffix(4)),
            signature: MasonryAssetsSignature(revision: 2, count: 4, firstID: assets[8].id, lastID: assets[11].id),
            folders: [],
            loaderInvalidationVersion: 0,
            selectedIDs: [],
            cutIDs: [],
            layoutMode: .verticalMasonry,
            targetColumnWidth: 180,
            topInset: 16,
            bottomInset: 16,
            sideChromeWidth: 0,
            activeQuickLookID: nil,
            isOverlayPresented: false,
            revealRequest: nil,
            isDarkMode: false,
            reduceMotion: true,
            callbacks: MasonryCallbacks()
        )

        // Primary window asset (absent from the panel) MUST remain resolvable despite secondary panel mount
        let primaryRect = MasonryCardGeometryRegistry.shared.visibleCardRectInWindow(for: assets[0].id)
        #expect(primaryRect != nil)
        #expect((primaryRect?.width ?? 0) > 100)

        primaryScroll.masonryDocument.releaseOffscreenResources()
        panelScroll.masonryDocument.releaseOffscreenResources()
        primaryWindow.contentView = nil
        panelWindow.contentView = nil
    }

    @Test("VirtualizedMasonryView suspends cleanly under isOverlayPresented and refreshes visible tiles on targeted loader invalidation")
    @MainActor
    func masonryOverlaySuspensionAndTargetedInvalidationRefresh() async throws {
        let dir = try BackendFixture.directory()
        defer { try? FileManager.default.removeItem(at: dir) }

        let engine = try BackendFixture.makeEngine(dir)
        let pngA = try BackendFixture.artwork("#D95D48")
        let pngB = try BackendFixture.artwork("#2A60E0")
        let urlA = dir.appending(path: "cover-a.png")
        let urlB = dir.appending(path: "cover-b.png")
        try pngA.write(to: urlA)
        try pngB.write(to: urlB)

        let assets = try await engine.ingest([.fileURL(urlA), .fileURL(urlB)], targetFolderID: nil, targetBoardID: nil)
        #expect(assets.count == 2)
        let assetA = assets[0]
        let assetB = assets[1]

        let loader = ThumbnailImageLoader(engine: engine)
        _ = await loader.loadCGImage(for: assetA.id, tier: .grid520)
        _ = await loader.loadCGImage(for: assetB.id, tier: .grid520)
        #expect(loader.cachedCGImage(for: assetA.id, tier: .grid520) != nil)
        #expect(loader.cachedCGImage(for: assetB.id, tier: .grid520) != nil)

        let scrollView = MasonryScrollView(frame: NSRect(x: 0, y: 0, width: 960, height: 640))
        scrollView.layoutSubtreeIfNeeded()
        let doc = scrollView.masonryDocument
        doc.loader = loader
        let sig = MasonryAssetsSignature(revision: 1, count: assets.count, firstID: assetA.id, lastID: assetB.id)

        doc.applyState(
            assets: assets,
            signature: sig,
            folders: [],
            loaderInvalidationVersion: loader.invalidationVersion,
            selectedIDs: [],
            cutIDs: [],
            layoutMode: .verticalMasonry,
            targetColumnWidth: 228,
            topInset: 76,
            bottomInset: 44,
            sideChromeWidth: 232,
            activeQuickLookID: nil,
            isOverlayPresented: false,
            revealRequest: nil,
            isDarkMode: false,
            reduceMotion: true,
            callbacks: MasonryCallbacks()
        )
        #expect(doc.activeTileHasImageContentsForTesting[assetA.id] == true)
        #expect(doc.activeTileHasImageContentsForTesting[assetB.id] == true)

        // Targeted invalidation of assetA MUST keep assetB cached and immediately reload visible tile A without scrolling
        loader.invalidate(assetID: assetA.id)
        #expect(loader.cachedCGImage(for: assetA.id, tier: .grid520) == nil)
        #expect(loader.cachedCGImage(for: assetB.id, tier: .grid520) != nil)

        let recomputesBefore = doc.layoutRecomputeCountForTesting
        doc.applyState(
            assets: assets,
            signature: sig,
            folders: [],
            loaderInvalidationVersion: loader.invalidationVersion,
            selectedIDs: [],
            cutIDs: [],
            layoutMode: .verticalMasonry,
            targetColumnWidth: 228,
            topInset: 76,
            bottomInset: 44,
            sideChromeWidth: 232,
            activeQuickLookID: nil,
            isOverlayPresented: false,
            revealRequest: nil,
            isDarkMode: false,
            reduceMotion: true,
            callbacks: MasonryCallbacks()
        )
        #expect(doc.layoutRecomputeCountForTesting == recomputesBefore)

        // Wait briefly for the async reload triggered by reloadTargetedActiveTiles to repopulate tile A
        for _ in 0..<40 {
            if doc.activeTileHasImageContentsForTesting[assetA.id] == true {
                break
            }
            try await Task.sleep(for: .milliseconds(25))
        }
        #expect(doc.activeTileHasImageContentsForTesting[assetA.id] == true)

        // Presenting an overlay suspends hover preview and marquee state cleanly
        doc.applyState(
            assets: assets,
            signature: sig,
            folders: [],
            loaderInvalidationVersion: loader.invalidationVersion,
            selectedIDs: [],
            cutIDs: [],
            layoutMode: .verticalMasonry,
            targetColumnWidth: 228,
            topInset: 76,
            bottomInset: 44,
            sideChromeWidth: 232,
            activeQuickLookID: nil,
            isOverlayPresented: true,
            revealRequest: nil,
            isDarkMode: false,
            reduceMotion: true,
            callbacks: MasonryCallbacks()
        )
        #expect(doc.isOverlayPresentedForTesting == true)
        #expect(doc.isHoverPreviewActiveForTesting == false)
        #expect(doc.isMarqueeHiddenForTesting == true)
        doc.releaseOffscreenResources()
    }

    // MARK: - 3. MasonryLayoutEngine Row-1/Row-2+ Anchor & 2D Spatial Arrow Navigation

    @Test("MasonryLayoutEngine keeps Row-1 flush at top, scrolls on Row-1->Row-2 wrap, and navigates 2D in both layout modes")
    func masonryAnchorWrapAndSpatialKeyboardNavigation() {
        let topInset: CGFloat = 76
        // Row-1 staying Row-1 remains pinned to scrollY == 0
        let stayTopY = MasonryLayoutEngine.anchoredScrollY(
            oldScrollY: 0,
            oldAnchorRect: CGRect(x: 20, y: 76, width: 200, height: 180),
            newAnchorRect: CGRect(x: 20, y: 76, width: 280, height: 252),
            anchorNormV: 0.5,
            anchorScreenY: 166,
            topInset: topInset,
            totalHeight: 2400,
            viewportHeight: 800
        )
        #expect(stayTopY == 0)

        // Row-1 wrapping down into Row-2 when columns narrow MUST scroll instead of clamping to 0
        let wrappedToRow2Y = MasonryLayoutEngine.anchoredScrollY(
            oldScrollY: 0,
            oldAnchorRect: CGRect(x: 680, y: 76, width: 200, height: 180),
            newAnchorRect: CGRect(x: 20, y: 420, width: 320, height: 288),
            anchorNormV: 0.5,
            anchorScreenY: 166,
            topInset: topInset,
            totalHeight: 3200,
            viewportHeight: 800
        )
        #expect(wrappedToRow2Y > 100)

        // 2D spatial navigation across Vertical Masonry & Horizontal Justified
        let assets = Self.makeSyntheticAssets(count: 24)
        for mode in [GalleryLayoutMode.verticalMasonry, GalleryLayoutMode.horizontalJustified] {
            let snapshot = MasonryLayoutEngine.compute(
                assets: assets,
                layoutMode: mode,
                containerWidth: 1000,
                targetColumnWidth: 228,
                spacing: 14,
                horizontalPadding: 20,
                topInset: 76,
                bottomInset: 44
            )
            #expect(snapshot.items.count == 24)

            let rightIdx = MasonryLayoutEngine.nextAssetIndex(from: 0, direction: .right, in: snapshot)
            #expect(rightIdx != nil && rightIdx != 0)
            if let r = rightIdx {
                #expect(snapshot.items[r].rect.midX > snapshot.items[0].rect.midX)
                let backLeft = MasonryLayoutEngine.nextAssetIndex(from: r, direction: .left, in: snapshot)
                #expect(backLeft == 0)
            }

            let downIdx = MasonryLayoutEngine.nextAssetIndex(from: 0, direction: .down, in: snapshot)
            #expect(downIdx != nil && downIdx != 0)
            if let d = downIdx {
                #expect(snapshot.items[d].rect.midY > snapshot.items[0].rect.midY)
                let backUp = MasonryLayoutEngine.nextAssetIndex(from: d, direction: .up, in: snapshot)
                #expect(backUp != nil && snapshot.items[backUp!].rect.midY < snapshot.items[d].rect.midY)
            }
        }
    }

    // MARK: - 4. RingGalleryMTKView presentsWithTransaction & Overlay Suspension

    @Test("RingGalleryMTKView keeps presentsWithTransaction disabled at rest, suspends on overlay, and handles targeted invalidation")
    @MainActor
    func ringGalleryIdleTransactionAndOverlaySuspension() {
        let assets = Self.makeSyntheticAssets(count: 16)
        let loader = ThumbnailImageLoader(engine: PlaceholderCharkleEngine())
        let view = RingGalleryMTKView(loader: loader)
        let callbacks = RingGalleryInteractionCallbacks(
            onFrontAssetChanged: { _ in },
            onOpenQuickLook: { _ in }
        )

        view.configure(
            assets: assets,
            selectedAssetID: assets[0].id,
            params: .default,
            isDarkMode: false,
            reduceMotion: false,
            isOverlayPresented: false,
            topSafeInset: 64,
            loaderInvalidationVersion: loader.invalidationVersion,
            callbacks: callbacks
        )
        #expect(view.presentsWithTransactionForTesting == false)
        #expect(view.isRenderSuspendedForTesting == false)
        let trackBuilds = view.trackRebuildCountForTesting

        // Targeted invalidation of one asset must NOT rebuild the ring geometry track
        loader.invalidate(assetID: assets[2].id)
        view.configure(
            assets: assets,
            selectedAssetID: assets[0].id,
            params: .default,
            isDarkMode: false,
            reduceMotion: false,
            isOverlayPresented: false,
            topSafeInset: 64,
            loaderInvalidationVersion: loader.invalidationVersion,
            callbacks: callbacks
        )
        #expect(view.trackRebuildCountForTesting == trackBuilds)
        #expect(view.presentsWithTransactionForTesting == false)

        // Overlay presentation suspends Metal rendering cleanly
        view.configure(
            assets: assets,
            selectedAssetID: assets[0].id,
            params: .default,
            isDarkMode: false,
            reduceMotion: false,
            isOverlayPresented: true,
            topSafeInset: 64,
            loaderInvalidationVersion: loader.invalidationVersion,
            callbacks: callbacks
        )
        #expect(view.isRenderSuspendedForTesting == true)
        #expect(view.isPaused == true)

        view.teardown()
        #expect(view.texturePoolEntryCountForTesting == 0)
    }

    // MARK: - 5. HoverMediaPreviewLayerController FillMode Sync & Stop Teardown

    @Test("HoverMediaPreviewLayerController updates fillMode live on active asset and tears down cleanly on stop")
    @MainActor
    func hoverMediaPreviewFillModeAndStopLifecycle() {
        let loader = ThumbnailImageLoader(engine: PlaceholderCharkleEngine())
        let controller = HoverMediaPreviewLayerController()
        let videoAsset = Self.makeSyntheticAssets(count: 1, mediaKind: .video)[0]
        let staticAsset = Self.makeSyntheticAssets(count: 1, mediaKind: .image)[0]

        // Static images and tiny collapsed frames never activate playback
        controller.schedulePreview(for: staticAsset, in: CGRect(x: 0, y: 0, width: 220, height: 160), fillMode: true, loader: loader)
        #expect(controller.isActiveForTesting == false)

        controller.schedulePreview(for: videoAsset, in: CGRect(x: 0, y: 0, width: 16, height: 16), fillMode: true, loader: loader)
        #expect(controller.isActiveForTesting == false)

        // Valid video frame activates and updates fillMode without dropping activeAssetID
        controller.schedulePreview(for: videoAsset, in: CGRect(x: 0, y: 0, width: 240, height: 180), fillMode: true, loader: loader)
        #expect(controller.isActiveForTesting == true)
        #expect(controller.activeAssetIDForTesting == videoAsset.id)
        #expect(controller.currentFillModeForTesting == true)

        controller.schedulePreview(for: videoAsset, in: CGRect(x: 0, y: 0, width: 260, height: 190), fillMode: false, loader: loader)
        #expect(controller.activeAssetIDForTesting == videoAsset.id)
        #expect(controller.currentFillModeForTesting == false)

        controller.stop()
        #expect(controller.isActiveForTesting == false)
        #expect(controller.activeAssetIDForTesting == nil)
    }

    // MARK: - 6. MoodboardCanvasView LiveDocRef, Isolated Reflow Gating, Nearest Snap & Rotated Marquee

    @Test("MoodboardCanvasView isolates group reflow frames, picks nearest snap match, and intersects rotated marquee bounds")
    @MainActor
    func moodboardLiveRefReflowGatingSnapAndRotatedMarquee() {
        let boardA = MoodboardDocument(title: "Board A", mode: .freeform)
        let boardB = MoodboardDocument(title: "Board B", mode: .freeform)
        let ref = LiveMoodboardDocumentRef()
        ref.update(boardA)
        #expect(ref.document?.id == boardA.id)
        ref.update(boardB)
        #expect(ref.document?.id == boardB.id)
        #expect(ref.document?.id != boardA.id)

        // Isolated group reflow frame gating
        let interaction = FreeformInteractionState()
        let groupID = UUID()
        let childInGroup = BoardNode(
            kind: .note(title: nil, text: "Inside", style: .paper, fontSize: 14),
            frame: BoardRect(x: 100, y: 100, width: 120, height: 90)
        )
        let stationaryNode = BoardNode(
            kind: .note(title: nil, text: "Outside", style: .warm, fontSize: 14),
            frame: BoardRect(x: 600, y: 600, width: 140, height: 100)
        )
        let reflowedRect = BoardRect(x: 110, y: 120, width: 96, height: 72)
        interaction.resizingNodeID = groupID
        interaction.liveGroupReflowChildIDs = [childInGroup.id]
        interaction.liveGroupReflowFrames = [childInGroup.id: reflowedRect]
        interaction.pendingConnectorHoverTargetID = stationaryNode.id

        #expect(interaction.effectiveFrame(for: childInGroup, selectedNodeIDs: []) == reflowedRect)
        #expect(interaction.effectiveFrame(for: stationaryNode, selectedNodeIDs: []) == stationaryNode.frame)

        interaction.resetAll()
        #expect(interaction.resizingNodeID == nil)
        #expect(interaction.liveGroupReflowChildIDs.isEmpty)
        #expect(interaction.pendingConnectorHoverTargetID == nil)

        // Nearest-match snap resolution chooses the closest edge rather than first-match within threshold
        let moving = BoardRect(x: 100, y: 100, width: 100, height: 80)
        let fartherRect = BoardRect(x: 116, y: 300, width: 100, height: 80) // minX delta = +6pt from candMinX=110
        let closerRect = BoardRect(x: 111, y: 450, width: 100, height: 80)  // minX delta = +1pt from candMinX=110
        let snap = MoodboardCanvasView.resolveBestSnapDelta(
            movingRect: moving,
            rawDX: 10,
            rawDY: 0,
            otherRects: [fartherRect, closerRect],
            threshold: 8
        )
        #expect(abs(snap.dx - 11.0) < 0.001)
        #expect(snap.guidesX.count == 1 && abs(snap.guidesX[0] - 111.0) < 0.001)

        // Rotated marquee hit test: a 200×40 bar centered at (200, 200) rotated 90° extends vertically to y in [100, 300]
        let rotatedBar = BoardNode(
            kind: .note(title: nil, text: "Rotated", style: .slate, fontSize: 14),
            frame: BoardRect(x: 100, y: 180, width: 200, height: 40),
            rotationDegrees: 90
        )
        let upperBox = BoardRect(x: 185, y: 105, width: 30, height: 30)
        #expect(!rotatedBar.frame.intersects(upperBox))
        #expect(MoodboardCanvasView.nodeIntersectsWorldBox(rotatedBar, worldBox: upperBox))
    }

    // MARK: - 7. EditorialLayoutSolver Shrunk GroupFrame Reflow Fit-Down Clamp

    @Test("EditorialLayoutSolver keeps 14 children strictly inside a tightly shrunk GroupFrame")
    func editorialGroupFrameReflowClampsInsideShrunkBounds() {
        let groupRect = BoardRect(x: 80, y: 120, width: 320, height: 220)
        var children: [BoardNode] = []
        for i in 0..<14 {
            children.append(BoardNode(
                kind: .note(title: "N\(i)", text: "Body \(i)", style: .paper, fontSize: 13),
                frame: BoardRect(x: 90 + Double((i % 4) * 70), y: 170 + Double((i / 4) * 50), width: 160, height: 120),
                editorialOrder: i
            ))
        }

        let reflowed = EditorialLayoutSolver.reflowNodesInsideGroupFrame(
            groupRect: groupRect,
            childNodes: children,
            assetsByID: [:]
        )
        #expect(reflowed.count == children.count)
        for (_, rect) in reflowed {
            #expect(rect.width.isFinite && rect.height.isFinite)
            #expect(rect.width > 0 && rect.height > 0)
            #expect(rect.minX >= groupRect.minX - 0.5)
            #expect(rect.minY >= groupRect.minY - 0.5)
            #expect(rect.maxX <= groupRect.maxX + 0.5)
            #expect(rect.maxY <= groupRect.maxY + 0.5)
        }
    }

    // MARK: - 8. MoodboardExporter autoSync Palette & FigmaBridgeExporter Off-Main Export

    @Test("MoodboardExporter honors autoSync palette strip and FigmaBridgeExporter runs off-main to produce a valid bundle")
    @MainActor
    func moodboardExporterAutoSyncAndOffMainFigmaBridgeExport() async throws {
        let dir = try BackendFixture.directory()
        defer { try? FileManager.default.removeItem(at: dir) }

        let imageURL = dir.appending(path: "board-hero.png")
        try BackendFixture.artwork("#4D7C5F").write(to: imageURL)

        let asset = AssetRecord(
            title: "Hero Swatch",
            fileName: "board-hero.png",
            mediaKind: .image,
            pixelWidth: 256,
            pixelHeight: 256,
            dominantColors: [LabColor.fromHex("#4D7C5F")]
        )
        let imageNode = BoardNode(
            kind: .assetRef(assetID: asset.id, crop: nil, weight: 1, autoplayLoop: false),
            frame: BoardRect(x: 40, y: 40, width: 240, height: 240)
        )
        let paletteNode = BoardNode(
            kind: .paletteStrip(colors: [], autoSyncWithBoard: true),
            frame: BoardRect(x: 40, y: 300, width: 240, height: 48)
        )
        let noteNode = BoardNode(
            kind: .note(title: "Direction", text: "Warm matte lighting", style: .warm, fontSize: 14),
            frame: BoardRect(x: 310, y: 40, width: 220, height: 150)
        )
        let doc = MoodboardDocument(
            title: "Audit Export Board",
            mode: .freeform,
            nodes: [imageNode, paletteNode, noteNode],
            extractedPalette: [LabColor.fromHex("#4D7C5F"), LabColor.fromHex("#C7933B")]
        )

        // 1. MoodboardExporter renders non-nil Retina image with autoSync palette strip
        let loader = ThumbnailImageLoader(engine: PlaceholderCharkleEngine())
        let rendered = MoodboardExporter.renderImage(
            document: doc,
            assetsByID: [asset.id: asset],
            loader: loader,
            options: MoodboardExportOptions(scale: 1.0, includeAnnotations: true, includePaletteStrip: true)
        )
        #expect(rendered != nil)
        #expect((rendered?.size.width ?? 0) > 200)
        #expect((rendered?.size.height ?? 0) > 200)

        // 2. FigmaBridgeExporter runs @concurrent off @MainActor and emits a valid .charkleboard archive
        let ranOffMainLock = OSAllocatedUnfairLock(initialState: false)
        let bundleURL = dir.appending(path: "audit-board.charkleboard")
        let report = try await FigmaBridgeExporter.exportBundle(
            document: doc,
            assetsByID: [asset.id: asset],
            options: MoodboardExportOptions(scale: 1.0, includeAnnotations: true, includePaletteStrip: true),
            resolveOriginalURL: { id in
                if !Self.isRunningOnMainThread() {
                    ranOffMainLock.withLock { $0 = true }
                }
                return id == asset.id ? imageURL : nil
            },
            resolveThumbnailURL: { _, _ in nil },
            to: bundleURL
        )

        #expect(ranOffMainLock.withLock { $0 } == true)
        #expect(FileManager.default.fileExists(atPath: bundleURL.path))
        #expect(report.imageCount == 1)
        #expect(report.noteCount == 1)
        #expect(report.paletteCount == 2) // Top board palette header + paletteStrip node
        #expect(report.objectCount == 4)
    }
}
