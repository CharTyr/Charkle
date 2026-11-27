import AppKit
import CharkleCore
import QuartzCore
import SwiftUI

/// Programmatic camera command sent from top-bar controls to `PinterestInfiniteCanvasMac`.
struct PinterestCameraCommandMac: Equatable {
    enum Action: Equatable {
        case none
        case resetCenter
        case zoomBy(CGFloat)
    }
    var id = UUID()
    var action: Action = .none
}

/// 120Hz silky infinite 2D omnidirectional Pinterest canvas for macOS.
///
/// Built directly on AppKit + Core Animation with recycled tile views so trackpad 2-finger pan
/// (native macOS momentum), mouse-drag inertial glide (`CADisplayLink`), trackpad pinch (`magnify`),
/// and Option/Command+scroll cursor-anchored continuous zoom run locked at display refresh rate
/// with zero SwiftUI diffing overhead and crisp screen-space cart badges at every zoom level.
struct PinterestInfiniteCanvasMac: NSViewRepresentable {
    let cards: [PinterestSpatialCard]
    let layoutRevision: Int
    let trayPinIDs: Set<String>
    let importedPinIDs: Set<String>
    let fastPickMode: Bool
    let isDark: Bool
    let accentColor: NSColor
    let isInteractionSuspended: Bool
    let excludedCanvasRects: [CGRect]
    let cameraCommand: PinterestCameraCommandMac
    let onOpenDetail: (PinterestPin) -> Void
    let onToggleTray: (PinterestPin) -> Void
    let onCameraChanged: (InfiniteSpatialCamera, CGRect) -> Void

    func makeNSView(context: Context) -> PinterestSpatialNSView {
        let view = PinterestSpatialNSView()
        view.onOpenDetail = onOpenDetail
        view.onToggleTray = onToggleTray
        view.onCameraChanged = onCameraChanged
        return view
    }

    func updateNSView(_ nsView: PinterestSpatialNSView, context: Context) {
        nsView.onOpenDetail = onOpenDetail
        nsView.onToggleTray = onToggleTray
        nsView.onCameraChanged = onCameraChanged
        nsView.fastPickMode = fastPickMode
        nsView.isInteractionSuspended = isInteractionSuspended
        nsView.excludedCanvasRects = excludedCanvasRects
        nsView.applyTheme(isDark: isDark, accent: accentColor)
        nsView.updateState(
            cards: cards,
            layoutRevision: layoutRevision,
            trayPinIDs: trayPinIDs,
            importedPinIDs: importedPinIDs
        )
        nsView.handleCameraCommand(cameraCommand)
    }
}

// MARK: - AppKit 120Hz Infinite 2D Canvas Host

final class PinterestSpatialNSView: NSView {
    var onOpenDetail: ((PinterestPin) -> Void)?
    var onToggleTray: ((PinterestPin) -> Void)?
    var onCameraChanged: ((InfiniteSpatialCamera, CGRect) -> Void)?

    var fastPickMode: Bool = false {
        didSet {
            if oldValue != fastPickMode {
                updateVisibleTileBadges()
            }
        }
    }
    var isInteractionSuspended: Bool = false {
        didSet {
            guard oldValue != isInteractionSuspended else { return }
            if isInteractionSuspended {
                resetDragCursorIfNeeded()
                dragStartPoint = nil
                lastDragPoint = nil
                isDraggingCanvas = false
                stopAnimationLoop()
                if hoveredPinID != nil {
                    hoveredPinID = nil
                    updateVisibleTileBadges()
                }
            }
            updateTrackingAreas()
        }
    }
    var excludedCanvasRects: [CGRect] = []

    private var cards: [PinterestSpatialCard] = []
    private var lastLayoutRevision: Int = -1
    private var trayPinIDs: Set<String> = []
    private var importedPinIDs: Set<String> = []
    private var isDark: Bool = false
    private var accentColor: NSColor = NSColor(srgbRed: 0.165, green: 0.376, blue: 0.878, alpha: 1)

    private var camera: InfiniteSpatialCamera = InfiniteSpatialCamera(translation: .zero, scale: 0.90)
    private var hasCenteredInitialCamera: Bool = false
    private var lastCommandID: UUID?

    // Recycled tile pool
    private var activeTiles: [String: PinterestSpatialTileView] = [:]
    private var recycledTiles: [PinterestSpatialTileView] = []
    private var hoveredPinID: String?

    // Mouse drag panning + inertial velocity glide
    private var dragStartPoint: CGPoint?
    private var lastDragPoint: CGPoint?
    private var lastDragTimestamp: TimeInterval = 0
    private var isDraggingCanvas: Bool = false
    private var didPushClosedHandCursor: Bool = false
    private var velocity: CGPoint = .zero
    private nonisolated(unsafe) var inertiaDisplayLink: CADisplayLink?
    private var lastInertiaTimestamp: CFTimeInterval = 0

    // Smooth animated programmatic camera transition
    private var cameraAnimStart: InfiniteSpatialCamera?
    private var cameraAnimTarget: InfiniteSpatialCamera?
    private var cameraAnimStartTime: CFTimeInterval = 0
    private let cameraAnimDuration: CFTimeInterval = 0.24

    // Subtle background dot grid layer
    private let dotPatternLayer = CALayer()
    private var trackingAreaRef: NSTrackingArea?

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }

    override func hitTest(_ point: NSPoint) -> NSView? {
        if isInteractionSuspended {
            return nil
        }
        let localPoint = convert(point, from: superview)
        for rect in excludedCanvasRects where rect.width > 0 && rect.height > 0 {
            if rect.insetBy(dx: -4, dy: -4).contains(localPoint) {
                return nil
            }
        }
        return super.hitTest(point)
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.masksToBounds = true
        dotPatternLayer.zPosition = -10
        layer?.addSublayer(dotPatternLayer)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func viewWillMove(toWindow newWindow: NSWindow?) {
        super.viewWillMove(toWindow: newWindow)
        if newWindow == nil {
            resetDragCursorIfNeeded()
            dragStartPoint = nil
            lastDragPoint = nil
            isDraggingCanvas = false
            inertiaDisplayLink?.invalidate()
            inertiaDisplayLink = nil
        }
    }

    private func resetDragCursorIfNeeded() {
        if didPushClosedHandCursor {
            NSCursor.pop()
            didPushClosedHandCursor = false
        }
    }

    deinit {
        inertiaDisplayLink?.invalidate()
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let existing = trackingAreaRef {
            removeTrackingArea(existing)
            trackingAreaRef = nil
        }
        guard !isInteractionSuspended else { return }
        let area = NSTrackingArea(
            rect: bounds,
            options: [.activeInKeyWindow, .mouseMoved, .mouseEnteredAndExited, .inVisibleRect],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(area)
        trackingAreaRef = area
    }

    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        dotPatternLayer.frame = bounds
        CATransaction.commit()

        if !hasCenteredInitialCamera, bounds.width > 40, bounds.height > 40 {
            hasCenteredInitialCamera = true
            camera = InfiniteSpatialCamera.centered(in: bounds.size, scale: 0.90)
            notifyCameraChanged()
        }
        syncVisibleTiles()
    }

    func applyTheme(isDark: Bool, accent: NSColor) {
        let changed = (self.isDark != isDark) || (self.accentColor != accent)
        self.isDark = isDark
        self.accentColor = accent
        guard changed else { return }
        layer?.backgroundColor = (isDark
            ? NSColor(srgbRed: 0.078, green: 0.082, blue: 0.090, alpha: 1)
            : NSColor(srgbRed: 0.965, green: 0.965, blue: 0.961, alpha: 1)).cgColor
        for tile in activeTiles.values {
            tile.applyTheme(isDark: isDark, accent: accent)
        }
    }

    func updateState(
        cards: [PinterestSpatialCard],
        layoutRevision: Int,
        trayPinIDs: Set<String>,
        importedPinIDs: Set<String>
    ) {
        let cardsChanged = (lastLayoutRevision != layoutRevision) || (self.cards.count != cards.count)
        let badgesChanged = (self.trayPinIDs != trayPinIDs) || (self.importedPinIDs != importedPinIDs)

        if cardsChanged {
            let wasReset = cards.count < self.cards.count || (cards.isEmpty && !self.cards.isEmpty)
            self.cards = cards
            self.lastLayoutRevision = layoutRevision
            if wasReset && bounds.width > 40 && bounds.height > 40 {
                stopAnimationLoop()
                camera = InfiniteSpatialCamera.centered(in: bounds.size, scale: 0.90)
                hasCenteredInitialCamera = true
                notifyCameraChanged()
            }
        }
        self.trayPinIDs = trayPinIDs
        self.importedPinIDs = importedPinIDs

        if cardsChanged {
            syncVisibleTiles()
        } else if badgesChanged {
            updateVisibleTileBadges()
        }
    }

    func handleCameraCommand(_ command: PinterestCameraCommandMac) {
        guard lastCommandID != command.id else { return }
        lastCommandID = command.id
        guard bounds.width > 40, bounds.height > 40 else { return }

        switch command.action {
        case .none:
            break
        case .resetCenter:
            let target = InfiniteSpatialCamera.centered(in: bounds.size, scale: 0.90)
            animateCamera(to: target)
        case .zoomBy(let factor):
            var target = camera
            let center = CGPoint(x: bounds.midX, y: bounds.midY)
            target.zoom(to: camera.scale * factor, anchoredAt: center)
            animateCamera(to: target)
        }
    }

    // MARK: - Core Viewport Culling & Recycled Tile Sync (Zero-Diff 120Hz)

    private func syncVisibleTiles() {
        guard bounds.width > 10, bounds.height > 10 else { return }

        let visibleWorld = camera.visibleWorldRect(viewportSize: bounds.size)
        let overscanWorld = max(240, 320 / max(0.25, camera.scale))
        let expandedWorld = visibleWorld.insetBy(dx: -overscanWorld, dy: -overscanWorld)

        var visibleSet = Set<String>()
        var visibleList: [PinterestSpatialCard] = []
        visibleList.reserveCapacity(80)

        for card in cards {
            if card.frame.intersects(expandedWorld) {
                visibleSet.insert(card.id)
                visibleList.append(card)
            }
        }

        CATransaction.begin()
        CATransaction.setDisableActions(true)

        // Recycle off-screen tiles
        var toRecycle: [String] = []
        for (pinID, tile) in activeTiles where !visibleSet.contains(pinID) {
            toRecycle.append(pinID)
            tile.removeFromSuperview()
            tile.prepareForReuse()
            recycledTiles.append(tile)
        }
        for key in toRecycle {
            activeTiles.removeValue(forKey: key)
        }

        let cornerRadius = max(6, min(16, 12 * sqrt(camera.scale)))

        for card in visibleList {
            let screenOrigin = camera.screenPoint(from: card.frame.origin)
            let screenSize = CGSize(
                width: card.frame.width * camera.scale,
                height: card.frame.height * camera.scale
            )
            let screenFrame = CGRect(origin: screenOrigin, size: screenSize)

            let tile: PinterestSpatialTileView
            if let existing = activeTiles[card.id] {
                tile = existing
            } else {
                tile = recycledTiles.popLast() ?? PinterestSpatialTileView()
                tile.applyTheme(isDark: isDark, accent: accentColor)
                tile.configure(pin: card.pin)
                addSubview(tile)
                activeTiles[card.id] = tile
            }

            tile.frame = screenFrame
            tile.updatePresentation(
                cornerRadius: cornerRadius,
                renderedWidth: screenSize.width,
                inTray: trayPinIDs.contains(card.id),
                isImported: importedPinIDs.contains(card.id),
                isHovered: hoveredPinID == card.id,
                fastPickMode: fastPickMode
            )
        }

        CATransaction.commit()
    }

    private func updateVisibleTileBadges() {
        let cornerRadius = max(6, min(16, 12 * sqrt(camera.scale)))
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for (pinID, tile) in activeTiles {
            tile.updatePresentation(
                cornerRadius: cornerRadius,
                renderedWidth: tile.bounds.width,
                inTray: trayPinIDs.contains(pinID),
                isImported: importedPinIDs.contains(pinID),
                isHovered: hoveredPinID == pinID,
                fastPickMode: fastPickMode
            )
        }
        CATransaction.commit()
    }

    // MARK: - Native Trackpad Pan, Pinch Zoom & Mouse Inertial Glide

    override func scrollWheel(with event: NSEvent) {
        guard !isInteractionSuspended else { return }
        stopAnimationLoop()

        let mods = event.modifierFlags.intersection([.command, .option, .control, .shift])
        let localPoint = convert(event.locationInWindow, from: nil)

        if mods.contains(.option) || mods.contains(.command) {
            let delta = event.hasPreciseScrollingDeltas ? event.scrollingDeltaY : event.scrollingDeltaY * 12
            guard abs(delta) > 0.001 else { return }
            let factor = exp(delta * 0.0075)
            camera.zoom(to: camera.scale * factor, anchoredAt: localPoint)
            syncVisibleTiles()
            notifyCameraChanged()
            return
        }

        let multiplier: CGFloat = event.hasPreciseScrollingDeltas ? 1.0 : 18.0
        let dx = event.scrollingDeltaX * multiplier
        let dy = event.scrollingDeltaY * multiplier
        guard abs(dx) > 0.01 || abs(dy) > 0.01 else { return }

        camera.pan(by: CGSize(width: dx, height: dy))
        syncVisibleTiles()
        notifyCameraChanged()
    }

    override func magnify(with event: NSEvent) {
        guard !isInteractionSuspended else { return }
        stopAnimationLoop()
        let localPoint = convert(event.locationInWindow, from: nil)
        let factor = max(0.5, min(2.0, 1.0 + event.magnification))
        camera.zoom(to: camera.scale * factor, anchoredAt: localPoint)
        syncVisibleTiles()
        notifyCameraChanged()
    }

    override func mouseMoved(with event: NSEvent) {
        guard !isInteractionSuspended else {
            if hoveredPinID != nil {
                hoveredPinID = nil
                updateVisibleTileBadges()
            }
            return
        }
        let pt = convert(event.locationInWindow, from: nil)
        let isInExcluded = excludedCanvasRects.contains { $0.width > 0 && $0.height > 0 && $0.insetBy(dx: -4, dy: -4).contains(pt) }
        let hitID = isInExcluded ? nil : hitTestTile(at: pt)?.pinID
        if hitID != hoveredPinID {
            hoveredPinID = hitID
            updateVisibleTileBadges()
        }
    }

    override func mouseExited(with event: NSEvent) {
        if hoveredPinID != nil {
            hoveredPinID = nil
            updateVisibleTileBadges()
        }
    }

    override func mouseDown(with event: NSEvent) {
        guard !isInteractionSuspended else { return }
        stopAnimationLoop()
        let pt = convert(event.locationInWindow, from: nil)
        dragStartPoint = pt
        lastDragPoint = pt
        lastDragTimestamp = event.timestamp
        isDraggingCanvas = false
        velocity = .zero
    }

    override func mouseDragged(with event: NSEvent) {
        guard !isInteractionSuspended, let start = dragStartPoint, let last = lastDragPoint else { return }
        let pt = convert(event.locationInWindow, from: nil)

        if !isDraggingCanvas {
            if hypot(pt.x - start.x, pt.y - start.y) < 4.5 {
                return
            }
            isDraggingCanvas = true
            if !didPushClosedHandCursor {
                NSCursor.closedHand.push()
                didPushClosedHandCursor = true
            }
        }

        let dx = pt.x - last.x
        let dy = pt.y - last.y
        let dt = max(0.004, event.timestamp - lastDragTimestamp)
        let instVx = dx / dt
        let instVy = dy / dt
        velocity = CGPoint(
            x: velocity.x * 0.45 + instVx * 0.55,
            y: velocity.y * 0.45 + instVy * 0.55
        )
        lastDragPoint = pt
        lastDragTimestamp = event.timestamp

        camera.pan(by: CGSize(width: dx, height: dy))
        syncVisibleTiles()
        notifyCameraChanged()
    }

    override func mouseUp(with event: NSEvent) {
        let wasDragging = isDraggingCanvas
        defer {
            resetDragCursorIfNeeded()
            dragStartPoint = nil
            lastDragPoint = nil
            isDraggingCanvas = false
        }
        guard !isInteractionSuspended else { return }

        if wasDragging {
            let speed = hypot(velocity.x, velocity.y)
            if speed > 90 {
                // Clamp max flick velocity for graceful atlas-like deceleration
                let maxSpeed: CGFloat = 3400
                if speed > maxSpeed {
                    let ratio = maxSpeed / speed
                    velocity.x *= ratio
                    velocity.y *= ratio
                }
                startInertiaGlide()
            }
            return
        }

        let pt = convert(event.locationInWindow, from: nil)
        guard let tile = hitTestTile(at: pt), let pin = tile.pin else { return }

        let mods = event.modifierFlags.intersection([.command, .option, .control, .shift])
        let clickedCartBadge = tile.isPointInCartButton(convert(pt, to: tile))

        if clickedCartBadge || fastPickMode || mods.contains(.shift) || mods.contains(.option) {
            tile.playPickPulse()
            onToggleTray?(pin)
        } else {
            onOpenDetail?(pin)
        }
    }

    private func hitTestTile(at point: CGPoint) -> PinterestSpatialTileView? {
        for subview in subviews.reversed() {
            guard let tile = subview as? PinterestSpatialTileView else { continue }
            if tile.frame.contains(point) {
                return tile
            }
        }
        return nil
    }

    // MARK: - 120Hz DisplayLink Inertia & Smooth Camera Transitions

    private func startInertiaGlide() {
        cameraAnimStart = nil
        cameraAnimTarget = nil
        lastInertiaTimestamp = CACurrentMediaTime()
        ensureDisplayLinkRunning()
    }

    private func animateCamera(to target: InfiniteSpatialCamera) {
        velocity = .zero
        cameraAnimStart = camera
        cameraAnimTarget = target
        cameraAnimStartTime = CACurrentMediaTime()
        ensureDisplayLinkRunning()
    }

    private func ensureDisplayLinkRunning() {
        if inertiaDisplayLink == nil {
            let link = displayLink(target: self, selector: #selector(handleDisplayLinkTick(_:)))
            link.add(to: .main, forMode: .common)
            inertiaDisplayLink = link
        }
        inertiaDisplayLink?.isPaused = false
    }

    private func stopAnimationLoop() {
        velocity = .zero
        cameraAnimStart = nil
        cameraAnimTarget = nil
        inertiaDisplayLink?.isPaused = true
    }

    @objc private func handleDisplayLinkTick(_ link: CADisplayLink) {
        let now = CACurrentMediaTime()

        if let start = cameraAnimStart, let target = cameraAnimTarget {
            let elapsed = now - cameraAnimStartTime
            let progress = min(1.0, max(0.0, elapsed / cameraAnimDuration))
            // Smooth cubic ease-out matching CharkleMotion.enterMd
            let eased = 1.0 - pow(1.0 - progress, 3.0)
            camera = InfiniteSpatialCamera(
                translation: CGPoint(
                    x: start.translation.x + (target.translation.x - start.translation.x) * eased,
                    y: start.translation.y + (target.translation.y - start.translation.y) * eased
                ),
                scale: start.scale + (target.scale - start.scale) * eased
            )
            syncVisibleTiles()
            notifyCameraChanged()
            if progress >= 1.0 {
                stopAnimationLoop()
            }
            return
        }

        let dt = min(0.05, max(0.001, now - lastInertiaTimestamp))
        lastInertiaTimestamp = now

        camera.pan(by: CGSize(width: velocity.x * dt, height: velocity.y * dt))
        let damping = pow(0.925, dt * 60.0)
        velocity.x *= damping
        velocity.y *= damping

        syncVisibleTiles()
        notifyCameraChanged()

        if hypot(velocity.x, velocity.y) < 12 {
            stopAnimationLoop()
        }
    }

    private func notifyCameraChanged() {
        guard bounds.width > 10, bounds.height > 10 else { return }
        onCameraChanged?(camera, camera.visibleWorldRect(viewportSize: bounds.size))
    }
}

// MARK: - Lightweight Core-Animation Spatial Card Tile

private final class PinterestSpatialTileView: NSView {
    private(set) var pin: PinterestPin?
    var pinID: String? { pin?.id }

    private let imageLayer = CALayer()
    private let borderLayer = CALayer()
    private let cartBadgeLayer = CALayer()
    private let cartSymbolLayer = CALayer()
    private let importedBadgeLayer = CATextLayer()
    private let videoBadgeLayer = CALayer()

    private var loadedURL: URL?
    private var loadingURL: URL?
    private var imageLoadTask: Task<Void, Never>?
    private var lastCartBadgeKey: String?
    private var isDark: Bool = false
    private var accentColor: NSColor = NSColor(srgbRed: 0.165, green: 0.376, blue: 0.878, alpha: 1)
    private var isInTray: Bool = false
    private var isHovered: Bool = false
    private var isImported: Bool = false

    override var isFlipped: Bool { true }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        guard let root = layer else { return }
        root.masksToBounds = true
        root.cornerCurve = .continuous

        imageLayer.contentsGravity = .resizeAspectFill
        imageLayer.masksToBounds = true
        root.addSublayer(imageLayer)

        borderLayer.borderWidth = 0.75
        borderLayer.cornerCurve = .continuous
        borderLayer.zPosition = 5
        root.addSublayer(borderLayer)

        cartBadgeLayer.cornerCurve = .continuous
        cartBadgeLayer.zPosition = 10
        cartBadgeLayer.shadowColor = NSColor.black.cgColor
        cartBadgeLayer.shadowOpacity = 0.24
        cartBadgeLayer.shadowRadius = 6
        cartBadgeLayer.shadowOffset = CGSize(width: 0, height: -2)
        root.addSublayer(cartBadgeLayer)

        cartSymbolLayer.contentsGravity = .center
        cartBadgeLayer.addSublayer(cartSymbolLayer)

        importedBadgeLayer.fontSize = 10
        importedBadgeLayer.alignmentMode = .center
        importedBadgeLayer.contentsScale = NSScreen.main?.backingScaleFactor ?? 2.0
        importedBadgeLayer.cornerRadius = 6
        importedBadgeLayer.cornerCurve = .continuous
        importedBadgeLayer.backgroundColor = NSColor.black.withAlphaComponent(0.62).cgColor
        importedBadgeLayer.foregroundColor = NSColor.white.cgColor
        importedBadgeLayer.string = "已入库"
        importedBadgeLayer.zPosition = 8
        importedBadgeLayer.isHidden = true
        root.addSublayer(importedBadgeLayer)

        videoBadgeLayer.cornerRadius = 11
        videoBadgeLayer.backgroundColor = NSColor.black.withAlphaComponent(0.56).cgColor
        videoBadgeLayer.zPosition = 8
        videoBadgeLayer.isHidden = true
        if let tinted = Self.cachedWhiteSymbolCGImage(name: "play.fill", pointSize: 9, weight: .bold) {
            videoBadgeLayer.contents = tinted
            videoBadgeLayer.contentsGravity = .center
        }
        root.addSublayer(videoBadgeLayer)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func applyTheme(isDark: Bool, accent: NSColor) {
        self.isDark = isDark
        self.accentColor = accent
    }

    override func prepareForReuse() {
        super.prepareForReuse()
        imageLoadTask?.cancel()
        imageLoadTask = nil
        pin = nil
        loadedURL = nil
        loadingURL = nil
        lastCartBadgeKey = nil
        imageLayer.contents = nil
        imageLayer.opacity = 0
        isInTray = false
        isHovered = false
        isImported = false
    }

    func configure(pin: PinterestPin) {
        self.pin = pin
        self.loadedURL = nil
        self.loadingURL = nil
        self.imageLoadTask?.cancel()
        self.imageLoadTask = nil

        if let hex = pin.dominantColorHex, let nsColor = Self.nsColor(fromHex: hex) {
            layer?.backgroundColor = nsColor.withAlphaComponent(isDark ? 0.35 : 0.24).cgColor
        } else {
            layer?.backgroundColor = (isDark
                ? NSColor(white: 0.14, alpha: 1)
                : NSColor(white: 0.91, alpha: 1)).cgColor
        }
        videoBadgeLayer.isHidden = !pin.isVideo
        imageLayer.contents = nil
        imageLayer.opacity = 0
    }

    func updatePresentation(
        cornerRadius: CGFloat,
        renderedWidth: CGFloat,
        inTray: Bool,
        isImported: Bool,
        isHovered: Bool,
        fastPickMode: Bool
    ) {
        guard let pin, let root = layer else { return }
        self.isInTray = inTray
        self.isHovered = isHovered
        self.isImported = isImported

        root.cornerRadius = cornerRadius
        imageLayer.frame = bounds
        borderLayer.frame = bounds
        borderLayer.cornerRadius = cornerRadius

        if inTray {
            borderLayer.borderColor = accentColor.cgColor
            borderLayer.borderWidth = 2.2
        } else if isHovered {
            borderLayer.borderColor = (isDark ? NSColor.white.withAlphaComponent(0.32) : NSColor.black.withAlphaComponent(0.22)).cgColor
            borderLayer.borderWidth = 1.1
        } else {
            borderLayer.borderColor = (isDark ? NSColor.white.withAlphaComponent(0.08) : NSColor.black.withAlphaComponent(0.06)).cgColor
            borderLayer.borderWidth = 0.6
        }

        // Browse mode keeps reference cards clean with no '+' badge; Fast-Pick mode shows '+' on every card.
        let showCartBadge = (inTray || fastPickMode) && bounds.width >= 58 && bounds.height >= 58
        cartBadgeLayer.isHidden = !showCartBadge
        if showCartBadge {
            let dim: CGFloat = bounds.width < 110 ? 22 : 28
            let inset: CGFloat = bounds.width < 110 ? 6 : 9
            cartBadgeLayer.frame = CGRect(x: bounds.width - dim - inset, y: inset, width: dim, height: dim)
            cartBadgeLayer.cornerRadius = dim * 0.5
            cartSymbolLayer.frame = cartBadgeLayer.bounds

            let symbolName = inTray ? "checkmark" : "plus"
            let pointSize = dim * (inTray ? 0.44 : 0.46)
            let badgeKey = "\(symbolName)-\(Int(pointSize.rounded()))"
            if inTray {
                cartBadgeLayer.backgroundColor = accentColor.cgColor
                cartBadgeLayer.borderColor = NSColor.white.withAlphaComponent(0.45).cgColor
                cartBadgeLayer.borderWidth = 1.0
            } else {
                cartBadgeLayer.backgroundColor = NSColor.black.withAlphaComponent(fastPickMode ? 0.52 : 0.62).cgColor
                cartBadgeLayer.borderColor = NSColor.white.withAlphaComponent(0.35).cgColor
                cartBadgeLayer.borderWidth = 0.8
            }
            if lastCartBadgeKey != badgeKey {
                lastCartBadgeKey = badgeKey
                cartSymbolLayer.contents = Self.cachedWhiteSymbolCGImage(name: symbolName, pointSize: pointSize, weight: .bold)
            }
        }

        // Imported pill bottom-left
        let showImported = isImported && bounds.width >= 90 && bounds.height >= 70
        importedBadgeLayer.isHidden = !showImported
        if showImported {
            importedBadgeLayer.frame = CGRect(x: 8, y: bounds.height - 25, width: 42, height: 17)
        }

        if pin.isVideo && bounds.width >= 76 {
            videoBadgeLayer.isHidden = false
            videoBadgeLayer.frame = CGRect(x: 8, y: 8, width: 22, height: 22)
        } else {
            videoBadgeLayer.isHidden = true
        }

        // Adaptive image resolution tier based on rendered screen width; avoid cancelling an
        // already in-flight download for the same URL on every 120Hz pan/zoom frame.
        let desiredURL = pin.imageURL(forRenderedWidth: renderedWidth)
        if desiredURL != loadedURL && desiredURL != loadingURL {
            loadImageIfNeeded(url: desiredURL, pinID: pin.id, maxPixels: renderedWidth > 420 ? 1440 : 760)
        }
    }

    func isPointInCartButton(_ localPoint: CGPoint) -> Bool {
        guard !cartBadgeLayer.isHidden else { return false }
        return cartBadgeLayer.frame.insetBy(dx: -6, dy: -6).contains(localPoint)
    }

    func playPickPulse() {
        guard let root = layer else { return }
        let anim = CAKeyframeAnimation(keyPath: "transform.scale")
        anim.values = [1.0, 0.955, 1.015, 1.0]
        anim.keyTimes = [0, 0.3, 0.72, 1.0]
        anim.duration = 0.22
        anim.timingFunction = CAMediaTimingFunction(name: .easeOut)
        root.add(anim, forKey: "pickPulse")
    }

    private func loadImageIfNeeded(url: URL, pinID: String, maxPixels: Int) {
        if let hit = PinterestImageCache.shared.cachedImage(for: url) {
            imageLoadTask?.cancel()
            imageLoadTask = nil
            loadingURL = nil
            loadedURL = url
            imageLayer.contents = hit
            imageLayer.opacity = 1
            return
        }

        // Keep showing any already-loaded lower-res tier while upgrading seamlessly
        imageLoadTask?.cancel()
        loadingURL = url
        imageLoadTask = Task { @MainActor [weak self] in
            let image = await PinterestImageCache.shared.image(for: url, maxPixelSize: maxPixels)
            guard let self, !Task.isCancelled, self.pin?.id == pinID, self.loadingURL == url else {
                return
            }
            self.loadingURL = nil
            guard let image else { return }
            self.loadedURL = url
            let wasHidden = self.imageLayer.opacity < 0.5
            self.imageLayer.contents = image
            if wasHidden {
                CATransaction.begin()
                CATransaction.setAnimationDuration(0.18)
                self.imageLayer.opacity = 1
                CATransaction.commit()
            } else {
                self.imageLayer.opacity = 1
            }
        }
    }

    private static var whiteSymbolCache: [String: CGImage] = [:]

    private static func cachedWhiteSymbolCGImage(name: String, pointSize: CGFloat, weight: NSFont.Weight) -> CGImage? {
        let roundedSize = Int(pointSize.rounded())
        let key = "\(name)-\(roundedSize)-\(weight.rawValue)"
        if let cached = whiteSymbolCache[key] {
            return cached
        }
        guard let img = NSImage(systemSymbolName: name, accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: CGFloat(roundedSize), weight: weight)) else {
            return nil
        }
        let size = img.size
        let scale: CGFloat = 2.0
        let pixelW = max(1, Int((size.width * scale).rounded(.up)))
        let pixelH = max(1, Int((size.height * scale).rounded(.up)))
        guard let ctx = CGContext(
            data: nil,
            width: pixelW,
            height: pixelH,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else {
            return nil
        }
        ctx.scaleBy(x: scale, y: scale)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: ctx, flipped: false)
        let rect = NSRect(origin: .zero, size: size)
        img.draw(in: rect, from: .zero, operation: .sourceOver, fraction: 1.0)
        NSColor.white.set()
        rect.fill(using: .sourceAtop)
        NSGraphicsContext.restoreGraphicsState()
        guard let cgImage = ctx.makeImage() else { return nil }
        whiteSymbolCache[key] = cgImage
        return cgImage
    }

    private static func nsColor(fromHex raw: String) -> NSColor? {
        let cleaned = raw.trimmingCharacters(in: .whitespacesAndNewlines).replacingOccurrences(of: "#", with: "")
        var hex: UInt64 = 0
        guard cleaned.count == 6, Scanner(string: cleaned).scanHexInt64(&hex) else { return nil }
        return NSColor(
            srgbRed: CGFloat((hex >> 16) & 0xFF) / 255.0,
            green: CGFloat((hex >> 8) & 0xFF) / 255.0,
            blue: CGFloat(hex & 0xFF) / 255.0,
            alpha: 1.0
        )
    }
}
