import AppKit
@testable import CharkleCanvas
@testable import CharkleCore
import Foundation
import QuartzCore
import Testing

@Suite("macOS Gallery Zoom Zero-Flicker Continuity Tests", .serialized)
struct GalleryZoomContinuityTests {

    private static func makeSyntheticAssets(count: Int) -> [AssetRecord] {
        var assets: [AssetRecord] = []
        assets.reserveCapacity(count)
        let palette = ["#2A60E0", "#D95D48", "#4D7C5F", "#C7933B", "#2C3038"]
        for i in 0..<count {
            let w = 800 + (i % 5) * 160
            let h = 600 + ((i * 3) % 7) * 140
            assets.append(AssetRecord(
                title: "Zoom Ref \(i)",
                fileName: "zoom-ref-\(i).png",
                mediaKind: .image,
                pixelWidth: w,
                pixelHeight: h,
                dominantColors: [LabColor.fromHex(palette[i % palette.count])]
            ))
        }
        return assets
    }

    @MainActor
    private static func makeMountedScrollView(
        assets: [AssetRecord],
        initialWidth: CGFloat = 228,
        onZoomColumnWidth: ((CGFloat) -> Void)? = nil
    ) -> (NSWindow, MasonryScrollView, MasonryAssetsSignature, MasonryCallbacks) {
        let scrollView = MasonryScrollView(frame: NSRect(x: 0, y: 0, width: 1120, height: 820))
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1120, height: 820),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.contentView = scrollView
        scrollView.layoutSubtreeIfNeeded()

        let signature = MasonryAssetsSignature(
            revision: 1,
            count: assets.count,
            firstID: assets.first?.id,
            lastID: assets.last?.id
        )
        let callbacks = MasonryCallbacks(onZoomColumnWidth: onZoomColumnWidth)
        scrollView.masonryDocument.applyState(
            assets: assets,
            signature: signature,
            folders: [],
            loaderInvalidationVersion: 0,
            selectedIDs: [],
            cutIDs: [],
            layoutMode: .verticalMasonry,
            targetColumnWidth: initialWidth,
            topInset: 76,
            bottomInset: 44,
            sideChromeWidth: 232,
            activeQuickLookID: nil,
            isOverlayPresented: false,
            revealRequest: nil,
            isDarkMode: false,
            reduceMotion: false,
            callbacks: callbacks
        )
        return (window, scrollView, signature, callbacks)
    }

    @Test("Zooming across column steps never flashes mounted or newly entering cards to opacity 0.0")
    @MainActor
    func zoomStepNeverDropsTilesToZeroOpacity() {
        let assets = Self.makeSyntheticAssets(count: 80)
        let (window, scrollView, signature, callbacks) = Self.makeMountedScrollView(assets: assets, initialWidth: 260)
        defer {
            scrollView.masonryDocument.releaseOffscreenResources()
            window.orderOut(nil)
        }

        let doc = scrollView.masonryDocument
        #expect(doc.activeTileCountForTesting > 8)

        // Zoom OUT by 2 column steps (e.g., 4 cols -> 6 cols) with animation enabled
        doc.applyState(
            assets: assets,
            signature: signature,
            folders: [],
            loaderInvalidationVersion: 0,
            selectedIDs: [],
            cutIDs: [],
            layoutMode: .verticalMasonry,
            targetColumnWidth: 168,
            topInset: 76,
            bottomInset: 44,
            sideChromeWidth: 232,
            activeQuickLookID: nil,
            isOverlayPresented: false,
            revealRequest: nil,
            isDarkMode: false,
            reduceMotion: false,
            callbacks: callbacks
        )

        let tilesRoot = doc.layer?.sublayers?.first
        let tileLayers = tilesRoot?.sublayers ?? []
        #expect(!tileLayers.isEmpty)

        var zeroOpacityFlashCount = 0
        var minimumAnimatedOpacity: Float = 1.0
        for layer in tileLayers {
            if let opAnim = layer.animation(forKey: "charkle.enterOpacity") as? CABasicAnimation,
               let fromVal = opAnim.fromValue as? NSNumber {
                let from = fromVal.floatValue
                minimumAnimatedOpacity = min(minimumAnimatedOpacity, from)
                if from < 0.50 {
                    zeroOpacityFlashCount += 1
                }
            }
            if let keyAnim = layer.animation(forKey: "charkle.wrapOpacity") as? CAKeyframeAnimation,
               let values = keyAnim.values as? [NSNumber] {
                for v in values {
                    minimumAnimatedOpacity = min(minimumAnimatedOpacity, v.floatValue)
                    if v.floatValue < 0.50 {
                        zeroOpacityFlashCount += 1
                    }
                }
            }
        }

        #expect(zeroOpacityFlashCount == 0, "Found \(zeroOpacityFlashCount) tiles flashing below 0.50 opacity during zoom (min=\(minimumAnimatedOpacity))")
        #expect(minimumAnimatedOpacity >= 0.60)
    }

    @Test("Already-mounted tiles glide via position/bounds animations instead of teleport-fading during zoom")
    @MainActor
    func alreadyMountedTilesGlideContinuouslyInsteadOfTeleporting() {
        let assets = Self.makeSyntheticAssets(count: 80)
        let (window, scrollView, signature, callbacks) = Self.makeMountedScrollView(assets: assets, initialWidth: 260)
        defer {
            scrollView.masonryDocument.releaseOffscreenResources()
            window.orderOut(nil)
        }

        let doc = scrollView.masonryDocument
        let initialTiles = Set((doc.layer?.sublayers?.first?.sublayers ?? []).map(ObjectIdentifier.init))
        #expect(initialTiles.count >= 8)

        // Zoom from 4 columns -> 6 columns
        doc.applyState(
            assets: assets,
            signature: signature,
            folders: [],
            loaderInvalidationVersion: 0,
            selectedIDs: [],
            cutIDs: [],
            layoutMode: .verticalMasonry,
            targetColumnWidth: 168,
            topInset: 76,
            bottomInset: 44,
            sideChromeWidth: 232,
            activeQuickLookID: nil,
            isOverlayPresented: false,
            revealRequest: nil,
            isDarkMode: false,
            reduceMotion: false,
            callbacks: callbacks
        )

        var glidingExistingTiles = 0
        var teleportedExistingTiles = 0
        for layer in doc.layer?.sublayers?.first?.sublayers ?? [] {
            guard initialTiles.contains(ObjectIdentifier(layer)) else { continue }
            if layer.animation(forKey: "charkle.enterScale") != nil || layer.animation(forKey: "charkle.enterOpacity") != nil {
                teleportedExistingTiles += 1
            }
            if layer.animation(forKey: "charkle.pos") != nil || layer.animation(forKey: "charkle.bounds") != nil {
                glidingExistingTiles += 1
            }
        }

        #expect(teleportedExistingTiles == 0)
        #expect(glidingExistingTiles >= 8)
    }

    @Test("Rapid multi-step interactive zoom ignores stale SwiftUI echo from an earlier step without snapping back")
    @MainActor
    func rapidMultiStepZoomIgnoresStaleEarlierEcho() {
        let assets = Self.makeSyntheticAssets(count: 60)
        var publishedWidths: [CGFloat] = []
        let (window, scrollView, signature, callbacks) = Self.makeMountedScrollView(
            assets: assets,
            initialWidth: 260,
            onZoomColumnWidth: { publishedWidths.append($0) }
        )
        defer {
            scrollView.masonryDocument.releaseOffscreenResources()
            window.orderOut(nil)
        }

        let doc = scrollView.masonryDocument
        // Step 1 via discrete ⌘+Scroll zoom out
        doc.handleCommandScrollZoom(
            delta: -1.0,
            isDiscreteWheel: true,
            anchorDocPoint: NSPoint(x: 400, y: 300),
            cursorWindowPoint: NSPoint(x: 400, y: 500)
        )
        // Allow discrete cooldown (0.12s) and trigger Step 2 before SwiftUI echoes Step 1
        Thread.sleep(forTimeInterval: 0.14)
        doc.handleCommandScrollZoom(
            delta: -1.0,
            isDiscreteWheel: true,
            anchorDocPoint: NSPoint(x: 400, y: 300),
            cursorWindowPoint: NSPoint(x: 400, y: 500)
        )

        #expect(publishedWidths.count == 2)
        let firstWidth = publishedWidths[0]
        let secondWidth = publishedWidths[1]
        #expect(abs(firstWidth - secondWidth) >= 1.0)

        let recomputesAfterTwoSteps = doc.layoutRecomputeCountForTesting

        // Simulate SwiftUI delivering the stale Step-1 width while view is already at Step-2
        doc.applyState(
            assets: assets,
            signature: signature,
            folders: [],
            loaderInvalidationVersion: 0,
            selectedIDs: [],
            cutIDs: [],
            layoutMode: .verticalMasonry,
            targetColumnWidth: firstWidth,
            topInset: 76,
            bottomInset: 44,
            sideChromeWidth: 232,
            activeQuickLookID: nil,
            isOverlayPresented: false,
            revealRequest: nil,
            isDarkMode: false,
            reduceMotion: false,
            callbacks: callbacks
        )

        // Must ignore stale Step-1 echo (no backwards recompute or snap-back!)
        #expect(doc.layoutRecomputeCountForTesting == recomputesAfterTwoSteps)
    }
}
