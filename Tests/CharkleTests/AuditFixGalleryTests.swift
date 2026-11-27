import AppKit
@testable import CharkleCanvas
@testable import CharkleCore
import Foundation
import Testing

@Suite("Gallery, Quick Look & Canvas Audit Fix Regressions")
struct AuditFixGalleryTests {

    @Test("ThumbnailImageLoader never retains originals in low-resource mode (prevents NSCache 0=unlimited leak)")
    @MainActor
    func thumbnailLoaderLowResourceOriginalCacheGuard() async throws {
        let loader = ThumbnailImageLoader(engine: PlaceholderCharkleEngine())

        // Write a tiny valid 8x8 PNG in temp dir
        let rep = try #require(NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: 8,
            pixelsHigh: 8,
            bitsPerSample: 8,
            samplesPerPixel: 4,
            hasAlpha: true,
            isPlanar: false,
            colorSpaceName: .deviceRGB,
            bytesPerRow: 0,
            bitsPerPixel: 0
        ))
        let pngData = try #require(rep.representation(using: .png, properties: [:]))
        let tempURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("charkle-audit-lowres-\(UUID().uuidString).png")
        try pngData.write(to: tempURL)
        defer { try? FileManager.default.removeItem(at: tempURL) }

        let assetID = UUID()

        // In low-resource mode, loading an original returns the image for immediate display
        // without retaining it inside `originalCache` (even across repeated loads).
        loader.setLowResourceMode(true)
        #expect(loader.currentOriginalCacheCountLimit == 0)
        let imgInLowRes = await loader.loadOriginalImage(for: assetID, url: tempURL)
        #expect(imgInLowRes != nil)
        #expect(loader.cachedOriginalImage(for: assetID) == nil)

        // Exiting low-resource mode restores normal bounded caching (4 items / 180 MB).
        loader.setLowResourceMode(false)
        #expect(loader.currentOriginalCacheCountLimit == 4)
        let imgNormal = await loader.loadOriginalImage(for: assetID, url: tempURL)
        #expect(imgNormal != nil)
        #expect(loader.cachedOriginalImage(for: assetID) != nil)

        // Re-entering low-resource mode immediately purges the cached original.
        loader.setLowResourceMode(true)
        #expect(loader.cachedOriginalImage(for: assetID) == nil)
    }

    @Test("MasonryLayoutEngine paneTransitionScrollY keeps scrollY=0 at top of library and anchors when scrolled down")
    func paneTransitionScrollYTopAndScrolledInvariants() {
        var assets: [AssetRecord] = []
        for i in 0..<60 {
            let h = i.isMultiple(of: 2) ? 900 : 1200
            assets.append(AssetRecord(
                title: "Item \(i)",
                fileName: "item-\(i).jpg",
                mediaKind: .image,
                pixelWidth: 800,
                pixelHeight: h
            ))
        }

        let wideLayout = MasonryLayoutEngine.compute(
            assets: assets,
            layoutMode: .verticalMasonry,
            containerWidth: 1123,
            targetColumnWidth: 228,
            spacing: 12,
            horizontalPadding: 20,
            topInset: 76,
            bottomInset: 44
        )
        let narrowLayout = MasonryLayoutEngine.compute(
            assets: assets,
            layoutMode: .verticalMasonry,
            containerWidth: 823,
            targetColumnWidth: 228,
            spacing: 12,
            horizontalPadding: 20,
            topInset: 76,
            bottomInset: 44
        )

        // Pick a Row-3+ card whose minY is well below topInset (simulating mid-viewport center anchor)
        let midCardIdx = min(14, wideLayout.items.count - 1)
        let oldRect = wideLayout.items[midCardIdx].rect
        let newRect = narrowLayout.items[midCardIdx].rect
        #expect(oldRect.minY > 120)

        // 1. At top of gallery (scrollY == 0), toggling Sidebar/Inspector MUST keep scrollY == 0
        //    so Row 1 never scrolls off-screen above the toolbar.
        let topResult = MasonryLayoutEngine.paneTransitionScrollY(
            oldScrollY: 0,
            oldAnchorRect: oldRect,
            newAnchorRect: newRect,
            anchorNormV: 0.5,
            anchorScreenY: oldRect.midY,
            topInset: 76,
            totalHeight: narrowLayout.totalHeight,
            viewportHeight: 720
        )
        #expect(topResult == 0)

        // 2. When scrolled down (oldScrollY == 480), pane transition anchors the visible card smoothly.
        let scrolledOldY: CGFloat = 480
        let anchorScreenY = oldRect.midY - scrolledOldY
        let scrolledResult = MasonryLayoutEngine.paneTransitionScrollY(
            oldScrollY: scrolledOldY,
            oldAnchorRect: oldRect,
            newAnchorRect: newRect,
            anchorNormV: 0.5,
            anchorScreenY: anchorScreenY,
            topInset: 76,
            totalHeight: narrowLayout.totalHeight,
            viewportHeight: 720
        )
        let expectedRaw = max(0, min(narrowLayout.totalHeight - 720, newRect.midY - anchorScreenY))
        #expect(abs(scrolledResult - expectedRaw) < 0.5)
    }

    @Test("CanvasFormatters.decodeUTF8Prefix never drops multi-byte CJK or emoji text on truncation boundaries")
    func utf8PrefixTruncationSafety() {
        // 3-byte Chinese characters: each char is 3 bytes
        let cjk = String(repeating: "设计素材库测试", count: 15_000) // ~315 KB > 262,144 bytes
        let cjkData = Data(cjk.utf8)
        #expect(cjkData.count > 262_144)

        // Byte 262,144 lands mid-character for 3-byte sequences (262144 % 3 == 1):
        // Naive `String(data: data.prefix(262_144), encoding: .utf8)` would return nil!
        #expect(String(data: cjkData.prefix(262_144), encoding: .utf8) == nil)
        let decoded = CanvasFormatters.decodeUTF8Prefix(cjkData, maxBytes: 262_144)
        #expect(!decoded.isEmpty)
        #expect(!decoded.contains("\u{FFFD}"))
        #expect(decoded.hasPrefix("设计素材库测试"))
        #expect(decoded.utf8.count == 262_143)

        // Exact boundary checks for 1-, 3-, and 4-byte scalars
        let mixed = Data("a你😀z".utf8) // 1 + 3 + 4 + 1 = 9 bytes
        #expect(CanvasFormatters.decodeUTF8Prefix(mixed, maxBytes: 1) == "a")
        #expect(CanvasFormatters.decodeUTF8Prefix(mixed, maxBytes: 2) == "a")
        #expect(CanvasFormatters.decodeUTF8Prefix(mixed, maxBytes: 3) == "a")
        #expect(CanvasFormatters.decodeUTF8Prefix(mixed, maxBytes: 4) == "a你")
        #expect(CanvasFormatters.decodeUTF8Prefix(mixed, maxBytes: 5) == "a你")
        #expect(CanvasFormatters.decodeUTF8Prefix(mixed, maxBytes: 7) == "a你")
        #expect(CanvasFormatters.decodeUTF8Prefix(mixed, maxBytes: 8) == "a你😀")
        #expect(CanvasFormatters.decodeUTF8Prefix(mixed, maxBytes: 9) == "a你😀z")
        #expect(CanvasFormatters.decodeUTF8Prefix(mixed, maxBytes: 32) == "a你😀z")
    }

    @Test("CharkleDragIdentifiers preserves explicit asset drag ordering")
    @MainActor
    func dragIdentifiersPreserveOrder() {
        let ids = (0..<5).map { _ in UUID() }
        let encoded = CharkleDragIdentifiers.encode(assetIDs: ids)
        let decoded = CharkleDragIdentifiers.decodeAssetIDs(from: encoded)
        #expect(decoded == ids)
    }

    @Test("RingGalleryMTKView blocks pointer hit testing while a modal overlay is presented")
    @MainActor
    func ringGalleryBlocksHitTestingDuringOverlay() {
        let loader = ThumbnailImageLoader(engine: PlaceholderCharkleEngine())
        let view = RingGalleryMTKView(loader: loader)
        view.frame = CGRect(x: 0, y: 0, width: 800, height: 600)
        let asset = AssetRecord(
            title: "Ring Card",
            fileName: "ring-card.jpg",
            mediaKind: .image,
            pixelWidth: 800,
            pixelHeight: 1000
        )
        let callbacks = RingGalleryInteractionCallbacks(
            onFrontAssetChanged: { _ in },
            onOpenQuickLook: { _ in }
        )

        view.configure(
            assets: [asset],
            selectedAssetID: asset.id,
            params: .default,
            isDarkMode: false,
            reduceMotion: false,
            isOverlayPresented: false,
            topSafeInset: 64,
            loaderInvalidationVersion: 0,
            callbacks: callbacks
        )
        #expect(view.hitTest(CGPoint(x: 400, y: 300)) != nil)

        view.configure(
            assets: [asset],
            selectedAssetID: asset.id,
            params: .default,
            isDarkMode: false,
            reduceMotion: false,
            isOverlayPresented: true,
            topSafeInset: 64,
            loaderInvalidationVersion: 0,
            callbacks: callbacks
        )
        #expect(view.hitTest(CGPoint(x: 400, y: 300)) == nil)
        view.teardown()
    }

    @Test("MasonryDocumentView clears hover, removes tracking areas, and ignores mouseMoved while a modal overlay is presented")
    @MainActor
    func masonryDocumentViewSuppressesHoverDuringOverlay() throws {
        let assets: [AssetRecord] = (0..<6).map { i in
            AssetRecord(
                title: "Inbox Item \(i)",
                fileName: "inbox-\(i).jpg",
                mediaKind: .image,
                pixelWidth: 800,
                pixelHeight: 900 + (i % 3) * 120
            )
        }
        let loader = ThumbnailImageLoader(engine: PlaceholderCharkleEngine())
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 900, height: 700),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        let scrollView = MasonryScrollView(frame: NSRect(x: 0, y: 0, width: 900, height: 700))
        window.contentView = scrollView
        scrollView.layoutSubtreeIfNeeded()

        let doc = scrollView.masonryDocument
        doc.loader = loader
        let signature = MasonryAssetsSignature(
            revision: 1,
            count: assets.count,
            firstID: assets.first?.id,
            lastID: assets.last?.id
        )

        func apply(overlayPresented: Bool) {
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
                sideChromeWidth: nil,
                isLivePaneResizing: false,
                activeQuickLookID: nil,
                isOverlayPresented: overlayPresented,
                revealRequest: nil,
                isDarkMode: false,
                reduceMotion: true,
                callbacks: MasonryCallbacks()
            )
        }

        apply(overlayPresented: false)
        scrollView.layoutSubtreeIfNeeded()
        doc.updateTrackingAreas()

        let expectedLayout = MasonryLayoutEngine.compute(
            assets: assets,
            layoutMode: .verticalMasonry,
            containerWidth: scrollView.contentView.bounds.width,
            targetColumnWidth: 228,
            spacing: 12,
            horizontalPadding: 20,
            topInset: 76,
            bottomInset: 44
        )
        let firstItem = try #require(expectedLayout.items.first)
        let secondItem = try #require(expectedLayout.items.dropFirst().first)

        func sendMouseMoved(toDocPoint docPoint: CGPoint) throws {
            let winPoint = doc.convert(docPoint, to: nil)
            let event = try #require(NSEvent.mouseEvent(
                with: .mouseMoved,
                location: winPoint,
                modifierFlags: [],
                timestamp: ProcessInfo.processInfo.systemUptime,
                windowNumber: window.windowNumber,
                context: nil,
                eventNumber: 1,
                clickCount: 0,
                pressure: 0
            ))
            doc.mouseMoved(with: event)
        }

        // 1. Normal state: tracking area active, hitTest succeeds, mouseMoved hovers Card 0
        #expect(!doc.trackingAreas.isEmpty)
        #expect(scrollView.hitTest(NSPoint(x: 150, y: 200)) != nil)
        try sendMouseMoved(toDocPoint: CGPoint(x: firstItem.rect.midX, y: firstItem.rect.midY))
        #expect(doc.hoveredAssetIDForTesting == firstItem.id)
        #expect(!doc.isHoverOverlayHiddenForTesting)

        // 2. Settings / modal overlay opens: existing hover clears immediately, tracking areas removed,
        //    hitTest returns nil, and subsequent mouseMoved over Card 1 produces zero hover response
        apply(overlayPresented: true)
        #expect(doc.hoveredAssetIDForTesting == nil)
        #expect(doc.isHoverOverlayHiddenForTesting)
        #expect(doc.trackingAreas.isEmpty)
        #expect(scrollView.hitTest(NSPoint(x: 150, y: 200)) == nil)
        #expect(doc.hitTest(NSPoint(x: firstItem.rect.midX, y: firstItem.rect.midY)) == nil)

        try sendMouseMoved(toDocPoint: CGPoint(x: secondItem.rect.midX, y: secondItem.rect.midY))
        #expect(doc.hoveredAssetIDForTesting == nil)
        #expect(doc.isHoverOverlayHiddenForTesting)

        // 3. Overlay closes: tracking areas & hover resume cleanly
        apply(overlayPresented: false)
        #expect(!doc.trackingAreas.isEmpty)
        #expect(scrollView.hitTest(NSPoint(x: 150, y: 200)) != nil)
        try sendMouseMoved(toDocPoint: CGPoint(x: secondItem.rect.midX, y: secondItem.rect.midY))
        #expect(doc.hoveredAssetIDForTesting == secondItem.id)
        #expect(!doc.isHoverOverlayHiddenForTesting)

        doc.releaseOffscreenResources()
    }

    @Test("FreeformHoverState clears active moodboard hover and ignores new hover events while overlay-suspended")
    @MainActor
    func moodboardHoverStateSuspendsDuringOverlay() {
        let hoverState = FreeformHoverState()
        let nodeA = UUID()
        let nodeB = UUID()

        hoverState.setNodeHovered(nodeA, hovering: true)
        hoverState.setPortHovered(nodeB, hovering: true)
        #expect(hoverState.effectiveHoveredNodeID == nodeB)

        hoverState.setSuspended(true)
        #expect(hoverState.hoveredNodeID == nil)
        #expect(hoverState.hoveredPortNodeID == nil)
        #expect(hoverState.effectiveHoveredNodeID == nil)

        hoverState.setNodeHovered(nodeA, hovering: true)
        hoverState.setPortHovered(nodeB, hovering: true)
        #expect(hoverState.hoveredNodeID == nil)
        #expect(hoverState.hoveredPortNodeID == nil)
        #expect(hoverState.effectiveHoveredNodeID == nil)

        hoverState.setSuspended(false)
        hoverState.setNodeHovered(nodeA, hovering: true)
        #expect(hoverState.effectiveHoveredNodeID == nodeA)
    }
}
