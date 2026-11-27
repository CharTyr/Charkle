import AppKit
import AVFoundation
import CharkleCore
import ImageIO
import QuartzCore
import SwiftUI

/// Pure GPU-composited, zero-jank muted hover preview controller for `.video` and `.animatedImage` assets.
///
/// Design invariants for 120Hz responsiveness and 0.0% idle CPU:
/// - **140ms dwell debounce**: sweeping the cursor rapidly across dozens of cards spawns zero decoders.
/// - **Local-cache only**: reads only already-cached local files off the main thread — never triggers network downloads.
/// - **Single active preview**: switching cards, scrolling, clicking, dragging, or exiting tears down players immediately.
/// - **Zero black-frame flash**: fades `containerLayer` from `0 -> 1` only after the first decoded frame or `AVPlayerLayer.isReadyForDisplay`.
/// - **Strictly muted**: `AVQueuePlayer.isMuted = true`, `volume = 0`, `preventsDisplaySleepDuringVideoPlayback = false`.
@MainActor
public final class HoverMediaPreviewLayerController {
    public let containerLayer: CALayer = {
        let layer = CALayer()
        layer.actions = HoverMediaPreviewLayerController.noImplicitActions
        layer.masksToBounds = true
        layer.cornerCurve = .continuous
        layer.zPosition = 450
        layer.opacity = 0
        layer.isHidden = true
        return layer
    }()

    private let mutedBadgeLayer: CALayer = {
        let layer = CALayer()
        layer.actions = HoverMediaPreviewLayerController.noImplicitActions
        layer.backgroundColor = NSColor.black.withAlphaComponent(0.56).cgColor
        layer.cornerRadius = 10
        layer.cornerCurve = .continuous
        layer.zPosition = 10
        layer.isHidden = true
        return layer
    }()

    private let mutedIconLayer: CALayer = {
        let layer = CALayer()
        layer.actions = HoverMediaPreviewLayerController.noImplicitActions
        layer.contentsGravity = .resizeAspect
        return layer
    }()

    private var activeAssetID: UUID?
    private var currentCornerRadius: CGFloat = 12
    private var currentFillMode: Bool = true
    private var currentScale: CGFloat = 2.0

    internal var isActiveForTesting: Bool { activeAssetID != nil }
    internal var activeAssetIDForTesting: UUID? { activeAssetID }
    internal var currentFillModeForTesting: Bool { currentFillMode }

    private var previewTask: Task<Void, Never>?
    private var queuePlayer: AVQueuePlayer?
    private var playerLooper: AVPlayerLooper?
    private var playerLayer: AVPlayerLayer?
    private var readyObservation: NSKeyValueObservation?
    private var gifFrameLayer: CALayer?

    private static let noImplicitActions: [String: CAAction] = [
        "bounds": NSNull(),
        "position": NSNull(),
        "frame": NSNull(),
        "contents": NSNull(),
        "opacity": NSNull(),
        "hidden": NSNull(),
        "cornerRadius": NSNull(),
        "transform": NSNull(),
        "sublayers": NSNull()
    ]

    private static let mutedIconCGImage: CGImage? = {
        let config = NSImage.SymbolConfiguration(pointSize: 10, weight: .semibold)
        guard let symbol = NSImage(systemSymbolName: "speaker.slash.fill", accessibilityDescription: "静音预览")?
            .withSymbolConfiguration(config) else {
            return nil
        }
        let size = NSSize(width: 14, height: 14)
        let rendered = NSImage(size: size, flipped: false) { rect in
            NSColor.white.withAlphaComponent(0.92).set()
            symbol.draw(in: rect.insetBy(dx: 1, dy: 1))
            return true
        }
        var proposed = CGRect(origin: .zero, size: size)
        return rendered.cgImage(forProposedRect: &proposed, context: nil, hints: nil)
    }()

    public init() {
        mutedIconLayer.contents = Self.mutedIconCGImage
        mutedBadgeLayer.addSublayer(mutedIconLayer)
        containerLayer.addSublayer(mutedBadgeLayer)
    }

    public static func supportsHoverPlayback(_ asset: AssetRecord) -> Bool {
        guard !asset.isSocialPost, !asset.isGitHubRepo else { return false }
        return asset.mediaKind == .video || asset.mediaKind == .animatedImage
    }

    /// Schedules muted hover playback for `asset` inside `frame`, or smoothly repositions an already-active preview.
    public func schedulePreview(
        for asset: AssetRecord,
        in frame: CGRect,
        cornerRadius: CGFloat = 12,
        fillMode: Bool = true,
        scale: CGFloat = 2.0,
        loader: ThumbnailImageLoader
    ) {
        guard Self.supportsHoverPlayback(asset), frame.width >= 32, frame.height >= 32 else {
            stop()
            return
        }

        let fillModeChanged = (currentFillMode != fillMode)
        currentCornerRadius = cornerRadius
        currentFillMode = fillMode
        currentScale = max(1.0, scale)

        if activeAssetID == asset.id {
            if fillModeChanged {
                CATransaction.begin()
                CATransaction.setDisableActions(true)
                playerLayer?.videoGravity = fillMode ? .resizeAspectFill : .resizeAspect
                gifFrameLayer?.contentsGravity = fillMode ? .resizeAspectFill : .resizeAspect
                CATransaction.commit()
            }
            updateGeometry(frame: frame, cornerRadius: cornerRadius, scale: currentScale)
            return
        }

        stop()
        activeAssetID = asset.id
        updateGeometry(frame: frame, cornerRadius: cornerRadius, scale: currentScale)

        let targetID = asset.id
        let mediaKind = asset.mediaKind

        previewTask = Task { @MainActor [weak self] in
            // 140ms dwell debounce so fast mouse sweeps across dozens of cards spawn zero decoders
            try? await Task.sleep(for: .milliseconds(140))
            guard let self, !Task.isCancelled, self.activeAssetID == targetID else { return }

            guard let localURL = await loader.resolveLocalCachedOriginalURL(for: asset) else {
                return
            }
            guard !Task.isCancelled, self.activeAssetID == targetID else { return }

            switch mediaKind {
            case .video:
                await self.startVideoPreview(assetID: targetID, url: localURL)
            case .animatedImage:
                await self.startAnimatedImagePreview(assetID: targetID, url: localURL)
            default:
                break
            }
        }
    }

    public func updateGeometry(frame: CGRect, cornerRadius: CGFloat? = nil, scale: CGFloat? = nil) {
        let nextRadius = cornerRadius ?? currentCornerRadius
        let nextScale = scale.map { max(1.0, $0) } ?? currentScale
        if containerLayer.frame == frame
            && abs(currentCornerRadius - nextRadius) < 0.01
            && abs(currentScale - nextScale) < 0.01 {
            return
        }
        currentCornerRadius = nextRadius
        currentScale = nextScale

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        containerLayer.frame = frame
        containerLayer.cornerRadius = currentCornerRadius
        containerLayer.contentsScale = currentScale

        let bounds = CGRect(origin: .zero, size: frame.size)
        playerLayer?.frame = bounds
        playerLayer?.contentsScale = currentScale
        gifFrameLayer?.frame = bounds
        gifFrameLayer?.contentsScale = currentScale

        let badgeSize: CGFloat = 20
        let inset: CGFloat = 7
        // Layout cleanly in both flipped (AppKit Masonry y-down) and unflipped (NSView y-up) coordinate systems
        mutedBadgeLayer.frame = CGRect(
            x: max(inset, bounds.width - badgeSize - inset),
            y: inset,
            width: badgeSize,
            height: badgeSize
        )
        mutedBadgeLayer.contentsScale = currentScale
        mutedIconLayer.frame = CGRect(x: 3, y: 3, width: 14, height: 14)
        mutedIconLayer.contentsScale = currentScale
        CATransaction.commit()
    }

    public func stop() {
        activeAssetID = nil
        previewTask?.cancel()
        previewTask = nil

        readyObservation?.invalidate()
        readyObservation = nil

        // Always disable AVPlayerLooper BEFORE pausing / clearing AVQueuePlayer so
        // the looper never re-inserts a replacement item during teardown.
        playerLooper?.disableLooping()
        playerLooper = nil
        queuePlayer?.pause()
        queuePlayer?.removeAllItems()
        queuePlayer = nil

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        playerLayer?.player = nil
        playerLayer?.removeFromSuperlayer()
        playerLayer = nil

        gifFrameLayer?.contents = nil
        gifFrameLayer?.removeFromSuperlayer()
        gifFrameLayer = nil

        mutedBadgeLayer.isHidden = true
        containerLayer.removeAllAnimations()
        containerLayer.opacity = 0
        containerLayer.isHidden = true
        CATransaction.commit()
    }

    isolated deinit {
        stop()
    }

    // MARK: - Muted Looping GPU Video Preview

    private func startVideoPreview(assetID: UUID, url: URL) async {
        let avAsset = AVURLAsset(url: url)
        let playable = (try? await avAsset.load(.isPlayable)) ?? false
        guard playable, !Task.isCancelled, activeAssetID == assetID else { return }

        let templateItem = AVPlayerItem(asset: avAsset)
        templateItem.preferredForwardBufferDuration = 1.5
        let player = AVQueuePlayer()
        player.isMuted = true
        player.volume = 0
        player.automaticallyWaitsToMinimizeStalling = false
        player.preventsDisplaySleepDuringVideoPlayback = false
        player.actionAtItemEnd = .none

        let looper = AVPlayerLooper(player: player, templateItem: templateItem)

        let layer = AVPlayerLayer(player: player)
        layer.actions = Self.noImplicitActions
        layer.videoGravity = currentFillMode ? .resizeAspectFill : .resizeAspect
        layer.frame = containerLayer.bounds
        layer.contentsScale = currentScale

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        containerLayer.insertSublayer(layer, below: mutedBadgeLayer)
        containerLayer.isHidden = false
        containerLayer.opacity = 0
        mutedBadgeLayer.isHidden = (containerLayer.bounds.width < 92 || containerLayer.bounds.height < 64)
        CATransaction.commit()

        queuePlayer = player
        playerLooper = looper
        playerLayer = layer

        let layerID = ObjectIdentifier(layer)
        readyObservation = layer.observe(\.isReadyForDisplay, options: [.initial, .new]) { [weak self] observedLayer, _ in
            guard observedLayer.isReadyForDisplay else { return }
            Task { @MainActor [weak self] in
                guard let self,
                      self.activeAssetID == assetID,
                      let current = self.playerLayer,
                      ObjectIdentifier(current) == layerID else { return }
                self.revealContainerSmoothly()
            }
        }

        player.play()
    }

    // MARK: - Off-Main-Thread Frame-Timed Animated GIF / WebP Preview

    private nonisolated final class AnimatedImageSourceBox: @unchecked Sendable {
        let source: CGImageSource
        init(_ source: CGImageSource) {
            self.source = source
        }
    }

    private nonisolated struct AnimatedImageSession: Sendable {
        let frameCount: Int
        let delays: [Double]
        let sourceBox: AnimatedImageSourceBox
    }

    private func startAnimatedImagePreview(assetID: UUID, url: URL) async {
        guard let session = await Self.openAnimatedImageSession(url: url),
              session.frameCount > 1,
              !Task.isCancelled,
              activeAssetID == assetID else {
            return
        }

        let maxPixel = min(480, max(240, Int(max(containerLayer.bounds.width, containerLayer.bounds.height) * currentScale)))
        let layer = CALayer()
        layer.actions = Self.noImplicitActions
        layer.contentsGravity = currentFillMode ? .resizeAspectFill : .resizeAspect
        layer.frame = containerLayer.bounds
        layer.contentsScale = currentScale

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        containerLayer.insertSublayer(layer, below: mutedBadgeLayer)
        containerLayer.isHidden = false
        containerLayer.opacity = 0
        mutedBadgeLayer.isHidden = true
        CATransaction.commit()
        gifFrameLayer = layer

        // Pre-decode compact frame cache off main thread for short GIFs (<= 24 frames AND <= 16 MB);
        // stream frames lazily from the single open CGImageSource for larger/longer GIFs so
        // CG Raster Data never spikes during hover playback.
        let estimatedMaxBytes = session.frameCount * maxPixel * maxPixel * 4
        if session.frameCount <= 24 && estimatedMaxBytes <= 16 * 1024 * 1024 {
            var decoded: [CGImage?] = Array(repeating: nil, count: session.frameCount)
            var frameIndex = 0
            var revealed = false

            while !Task.isCancelled && activeAssetID == assetID {
                let frame: CGImage?
                if let cached = decoded[frameIndex] {
                    frame = cached
                } else {
                    frame = await Self.decodeAnimatedFrame(
                        sourceBox: session.sourceBox,
                        index: frameIndex,
                        maxPixelSize: maxPixel
                    )
                    if let frame {
                        decoded[frameIndex] = frame
                    }
                }
                guard !Task.isCancelled, activeAssetID == assetID else { break }

                if let frame {
                    CATransaction.begin()
                    CATransaction.setDisableActions(true)
                    layer.contents = frame
                    CATransaction.commit()
                    if !revealed {
                        revealed = true
                        revealContainerSmoothly()
                    }
                }

                let delay = session.delays[frameIndex]
                try? await Task.sleep(for: .milliseconds(Int((delay * 1000.0).rounded())))
                frameIndex = (frameIndex + 1) % session.frameCount
            }
        } else {
            var frameIndex = 0
            var revealed = false
            while !Task.isCancelled && activeAssetID == assetID {
                let frame = await Self.decodeAnimatedFrame(
                    sourceBox: session.sourceBox,
                    index: frameIndex,
                    maxPixelSize: min(maxPixel, 440)
                )
                guard !Task.isCancelled, activeAssetID == assetID else { break }
                if let frame {
                    CATransaction.begin()
                    CATransaction.setDisableActions(true)
                    layer.contents = frame
                    CATransaction.commit()
                    if !revealed {
                        revealed = true
                        revealContainerSmoothly()
                    }
                }
                let delay = session.delays[frameIndex]
                try? await Task.sleep(for: .milliseconds(Int((delay * 1000.0).rounded())))
                frameIndex = (frameIndex + 1) % session.frameCount
            }
        }
    }

    private func revealContainerSmoothly() {
        guard containerLayer.opacity < 0.99 else { return }
        let anim = CABasicAnimation(keyPath: "opacity")
        anim.fromValue = containerLayer.opacity
        anim.toValue = 1.0
        anim.duration = 0.15
        anim.timingFunction = CAMediaTimingFunction(controlPoints: 0.23, 1.0, 0.32, 1.0)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        containerLayer.opacity = 1.0
        containerLayer.add(anim, forKey: "charkle.hoverPreviewReveal")
        CATransaction.commit()
    }

    @concurrent
    private static func openAnimatedImageSession(url: URL) async -> AnimatedImageSession? {
        guard !Task.isCancelled else { return nil }
        let options: [CFString: Any] = [kCGImageSourceShouldCache: false]
        guard let source = CGImageSourceCreateWithURL(url as CFURL, options as CFDictionary) else {
            return nil
        }
        let count = CGImageSourceGetCount(source)
        guard count > 1 else { return nil }
        var delays: [Double] = []
        delays.reserveCapacity(count)
        for idx in 0..<count {
            delays.append(frameDelaySeconds(source: source, index: idx))
        }
        return AnimatedImageSession(frameCount: count, delays: delays, sourceBox: AnimatedImageSourceBox(source))
    }

    @concurrent
    private static func decodeAnimatedFrame(sourceBox: AnimatedImageSourceBox, index: Int, maxPixelSize: Int) async -> CGImage? {
        guard !Task.isCancelled else { return nil }
        let thumbOptions: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixelSize,
            kCGImageSourceShouldCacheImmediately: true
        ]
        return CGImageSourceCreateThumbnailAtIndex(sourceBox.source, index, thumbOptions as CFDictionary)
            ?? CGImageSourceCreateImageAtIndex(sourceBox.source, index, nil)
    }

    private nonisolated static func frameDelaySeconds(source: CGImageSource, index: Int) -> Double {
        guard let props = CGImageSourceCopyPropertiesAtIndex(source, index, nil) as? [CFString: Any] else {
            return 0.08
        }
        if let gif = props[kCGImagePropertyGIFDictionary] as? [CFString: Any] {
            if let unclamped = gif[kCGImagePropertyGIFUnclampedDelayTime] as? Double, unclamped > 0.005 {
                return max(0.03, min(1.5, unclamped))
            }
            if let clamped = gif[kCGImagePropertyGIFDelayTime] as? Double, clamped > 0.005 {
                return max(0.03, min(1.5, clamped))
            }
        }
        if let webp = props[kCGImagePropertyWebPDictionary] as? [CFString: Any] {
            if let unclamped = webp[kCGImagePropertyWebPUnclampedDelayTime] as? Double, unclamped > 0.005 {
                return max(0.03, min(1.5, unclamped))
            }
            if let clamped = webp[kCGImagePropertyWebPDelayTime] as? Double, clamped > 0.005 {
                return max(0.03, min(1.5, clamped))
            }
        }
        if let png = props[kCGImagePropertyPNGDictionary] as? [CFString: Any] {
            if let unclamped = png[kCGImagePropertyAPNGUnclampedDelayTime] as? Double, unclamped > 0.005 {
                return max(0.03, min(1.5, unclamped))
            }
            if let clamped = png[kCGImagePropertyAPNGDelayTime] as? Double, clamped > 0.005 {
                return max(0.03, min(1.5, clamped))
            }
        }
        return 0.08
    }
}

/// Lightweight SwiftUI bridge mounting `HoverMediaPreviewLayerController` strictly while hovered,
/// giving Notch Shelf cards, Moodboard cards, Gallery filmstrip thumbnails, and Similar grids
/// muted looping video & GIF hover preview with zero idle overhead.
public struct HoverMediaPreviewOverlay: NSViewRepresentable {
    public let asset: AssetRecord
    public let loader: ThumbnailImageLoader
    public let cornerRadius: CGFloat
    public let fillMode: Bool

    public init(
        asset: AssetRecord,
        loader: ThumbnailImageLoader,
        cornerRadius: CGFloat = 12,
        fillMode: Bool = true
    ) {
        self.asset = asset
        self.loader = loader
        self.cornerRadius = cornerRadius
        self.fillMode = fillMode
    }

    public func makeNSView(context: Context) -> PreviewHostNSView {
        let view = PreviewHostNSView()
        view.configure(asset: asset, loader: loader, cornerRadius: cornerRadius, fillMode: fillMode)
        return view
    }

    public func updateNSView(_ nsView: PreviewHostNSView, context: Context) {
        nsView.configure(asset: asset, loader: loader, cornerRadius: cornerRadius, fillMode: fillMode)
    }

    public static func dismantleNSView(_ nsView: PreviewHostNSView, coordinator: ()) {
        nsView.stopPreview()
    }

    public final class PreviewHostNSView: NSView {
        private let controller = HoverMediaPreviewLayerController()
        private var currentAsset: AssetRecord?
        private var currentLoader: ThumbnailImageLoader?
        private var currentCornerRadius: CGFloat = 12
        private var currentFillMode: Bool = true
        private nonisolated(unsafe) var lifecycleObservers: [NSObjectProtocol] = []

        public override nonisolated var isFlipped: Bool { true }

        public override init(frame frameRect: NSRect) {
            super.init(frame: frameRect)
            wantsLayer = true
            layer?.masksToBounds = true
            layer?.addSublayer(controller.containerLayer)
        }

        @available(*, unavailable)
        required init?(coder: NSCoder) {
            fatalError("init(coder:) has not been implemented")
        }

        public override func hitTest(_ point: NSPoint) -> NSView? {
            nil
        }

        private var canHostActivePlayback: Bool {
            guard let hostWindow = window else { return false }
            guard !isHiddenOrHasHiddenAncestor, bounds.width >= 32, bounds.height >= 32 else { return false }
            guard NSApp?.isHidden != true, hostWindow.occlusionState.contains(.visible) else { return false }
            if let panel = hostWindow as? NSPanel, panel.isFloatingPanel {
                return true
            }
            return NSApp?.isActive == true && hostWindow.isKeyWindow
        }

        func configure(asset: AssetRecord, loader: ThumbnailImageLoader, cornerRadius: CGFloat, fillMode: Bool) {
            currentAsset = asset
            currentLoader = loader
            currentCornerRadius = cornerRadius
            currentFillMode = fillMode
            if canHostActivePlayback {
                controller.schedulePreview(
                    for: asset,
                    in: bounds,
                    cornerRadius: cornerRadius,
                    fillMode: fillMode,
                    scale: window?.backingScaleFactor ?? 2.0,
                    loader: loader
                )
            } else {
                controller.stop()
            }
        }

        public override func layout() {
            super.layout()
            guard canHostActivePlayback, let asset = currentAsset, let loader = currentLoader else {
                controller.stop()
                return
            }
            controller.schedulePreview(
                for: asset,
                in: bounds,
                cornerRadius: currentCornerRadius,
                fillMode: currentFillMode,
                scale: window?.backingScaleFactor ?? 2.0,
                loader: loader
            )
        }

        public override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            removeLifecycleObservers()
            guard let hostWindow = window else {
                controller.stop()
                return
            }
            installLifecycleObservers(for: hostWindow)
            if canHostActivePlayback, let asset = currentAsset, let loader = currentLoader {
                controller.schedulePreview(
                    for: asset,
                    in: bounds,
                    cornerRadius: currentCornerRadius,
                    fillMode: currentFillMode,
                    scale: hostWindow.backingScaleFactor,
                    loader: loader
                )
            } else {
                controller.stop()
            }
        }

        private func installLifecycleObservers(for hostWindow: NSWindow) {
            let nc = NotificationCenter.default
            lifecycleObservers.append(nc.addObserver(
                forName: NSWindow.didResignKeyNotification,
                object: hostWindow,
                queue: nil
            ) { [weak self] _ in
                Task { @MainActor [weak self] in
                    guard let self else { return }
                    if !self.canHostActivePlayback {
                        self.controller.stop()
                    }
                }
            })
            lifecycleObservers.append(nc.addObserver(
                forName: NSWindow.didChangeOcclusionStateNotification,
                object: hostWindow,
                queue: nil
            ) { [weak self] _ in
                Task { @MainActor [weak self] in
                    guard let self else { return }
                    if !self.canHostActivePlayback {
                        self.controller.stop()
                    }
                }
            })
            lifecycleObservers.append(nc.addObserver(
                forName: NSApplication.didHideNotification,
                object: NSApp,
                queue: nil
            ) { [weak self] _ in
                Task { @MainActor [weak self] in
                    self?.controller.stop()
                }
            })
            lifecycleObservers.append(nc.addObserver(
                forName: NSApplication.didResignActiveNotification,
                object: NSApp,
                queue: nil
            ) { [weak self] _ in
                Task { @MainActor [weak self] in
                    guard let self else { return }
                    if !self.canHostActivePlayback {
                        self.controller.stop()
                    }
                }
            })
        }

        private func removeLifecycleObservers() {
            for token in lifecycleObservers {
                NotificationCenter.default.removeObserver(token)
            }
            lifecycleObservers.removeAll()
        }

        func stopPreview() {
            removeLifecycleObservers()
            controller.stop()
        }

        isolated deinit {
            removeLifecycleObservers()
            controller.stop()
        }
    }
}
