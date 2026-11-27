import CharkleCore
import QuartzCore
import SwiftUI
import UIKit

/// Programmatic camera command sent from top-bar controls to `PinterestInfiniteCanvasMobile`.
struct PinterestCameraCommandMobile: Equatable {
    enum Action: Equatable {
        case none
        case resetCenter
        case zoomBy(CGFloat)
    }
    var id = UUID()
    var action: Action = .none
}

/// 120Hz ProMotion infinite 2D omnidirectional Pinterest spatial canvas for iOS & iPadOS.
///
/// Uses UIKit `UIPanGestureRecognizer` + simultaneous `UIPinchGestureRecognizer` + `CADisplayLink`
/// inertial deceleration + recycled `UIView` tiles so users can glide freely in all 360° directions,
/// smoothly anchor-zoom around their exact two-finger pinch midpoint, and tap cards to open floating
/// Pinterest Pin details or fast-pick directly into the shopping-cart tray.
struct PinterestInfiniteCanvasMobile: UIViewRepresentable {
    let cards: [PinterestSpatialCard]
    let layoutRevision: Int
    let trayPinIDs: Set<String>
    let importedPinIDs: Set<String>
    let fastPickMode: Bool
    let isDark: Bool
    let accentColor: UIColor
    let isInteractionSuspended: Bool
    let excludedGlobalRects: [CGRect]
    let cameraCommand: PinterestCameraCommandMobile
    let onOpenDetail: (PinterestPin) -> Void
    let onToggleTray: (PinterestPin) -> Void
    let onCameraChanged: (InfiniteSpatialCamera, CGRect) -> Void

    func makeUIView(context: Context) -> PinterestSpatialUIView {
        let view = PinterestSpatialUIView()
        view.onOpenDetail = onOpenDetail
        view.onToggleTray = onToggleTray
        view.onCameraChanged = onCameraChanged
        return view
    }

    func updateUIView(_ uiView: PinterestSpatialUIView, context: Context) {
        uiView.onOpenDetail = onOpenDetail
        uiView.onToggleTray = onToggleTray
        uiView.onCameraChanged = onCameraChanged
        uiView.fastPickMode = fastPickMode
        uiView.isInteractionSuspended = isInteractionSuspended
        uiView.excludedGlobalRects = excludedGlobalRects
        uiView.applyTheme(isDark: isDark, accent: accentColor)
        uiView.updateState(
            cards: cards,
            layoutRevision: layoutRevision,
            trayPinIDs: trayPinIDs,
            importedPinIDs: importedPinIDs
        )
        uiView.handleCameraCommand(cameraCommand)
    }

    static func dismantleUIView(_ uiView: PinterestSpatialUIView, coordinator: ()) {
        uiView.teardown()
    }
}

private final class PinterestDisplayLinkProxy: NSObject {
    weak var target: PinterestSpatialUIView?

    init(target: PinterestSpatialUIView) {
        self.target = target
    }

    @objc func tick(_ link: CADisplayLink) {
        target?.handleDisplayLink(link)
    }
}

// MARK: - UIKit 120Hz Infinite 2D Canvas Host

final class PinterestSpatialUIView: UIView, UIGestureRecognizerDelegate {
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
            if isInteractionSuspended && !oldValue {
                stopAnimationLoop()
            }
        }
    }
    var excludedGlobalRects: [CGRect] = []

    private var cards: [PinterestSpatialCard] = []
    private var firstCardID: String?
    private var lastLayoutRevision: Int = -1
    private var trayPinIDs: Set<String> = []
    private var importedPinIDs: Set<String> = []
    private var isDark: Bool = false
    private var accentColor: UIColor = UIColor(red: 0.165, green: 0.376, blue: 0.878, alpha: 1)

    private var camera: InfiniteSpatialCamera = InfiniteSpatialCamera(translation: .zero, scale: 0.78)
    private var hasCenteredInitialCamera: Bool = false
    private var lastCommandID: UUID?

    // Recycled tile views
    private var activeTiles: [String: PinterestSpatialTileUIView] = [:]
    private var recycledTiles: [PinterestSpatialTileUIView] = []

    // Gesture state
    private var panGesture: UIPanGestureRecognizer!
    private var pinchGesture: UIPinchGestureRecognizer!
    private var tapGesture: UITapGestureRecognizer!
    private var lastPanTranslation: CGPoint = .zero
    private var lastPinchScale: CGFloat = 1.0
    private var lastPinchCentroid: CGPoint = .zero
    private var isPinching: Bool = false

    // 120Hz DisplayLink inertia & smooth camera transitions
    private var velocity: CGPoint = .zero
    private nonisolated(unsafe) var displayLink: CADisplayLink?
    private var lastFrameTimestamp: CFTimeInterval = 0
    private var cameraAnimStart: InfiniteSpatialCamera?
    private var cameraAnimTarget: InfiniteSpatialCamera?
    private var cameraAnimStartTime: CFTimeInterval = 0
    private let cameraAnimDuration: CFTimeInterval = 0.24

    override init(frame: CGRect) {
        super.init(frame: frame)
        clipsToBounds = true
        isMultipleTouchEnabled = true
        setupGestures()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func willMove(toWindow newWindow: UIWindow?) {
        super.willMove(toWindow: newWindow)
        if newWindow == nil {
            teardown()
        }
    }

    func teardown() {
        stopAnimationLoop()
        displayLink?.invalidate()
        displayLink = nil
    }

    deinit {
        displayLink?.invalidate()
    }

    private func setupGestures() {
        panGesture = UIPanGestureRecognizer(target: self, action: #selector(handlePan(_:)))
        panGesture.minimumNumberOfTouches = 1
        panGesture.maximumNumberOfTouches = 2
        panGesture.delegate = self
        addGestureRecognizer(panGesture)

        pinchGesture = UIPinchGestureRecognizer(target: self, action: #selector(handlePinch(_:)))
        pinchGesture.delegate = self
        addGestureRecognizer(pinchGesture)

        tapGesture = UITapGestureRecognizer(target: self, action: #selector(handleTap(_:)))
        tapGesture.delegate = self
        tapGesture.require(toFail: panGesture)
        addGestureRecognizer(tapGesture)
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        if !hasCenteredInitialCamera, bounds.width > 40, bounds.height > 40 {
            hasCenteredInitialCamera = true
            let initialScale: CGFloat = bounds.width < 520 ? 0.68 : 0.88
            camera = InfiniteSpatialCamera.centered(in: bounds.size, scale: initialScale)
            notifyCameraChanged()
        }
        syncVisibleTiles()
    }

    func applyTheme(isDark: Bool, accent: UIColor) {
        let changed = (self.isDark != isDark) || (self.accentColor != accent)
        self.isDark = isDark
        self.accentColor = accent
        guard changed else { return }
        backgroundColor = isDark
            ? UIColor(red: 0.078, green: 0.082, blue: 0.090, alpha: 1)
            : UIColor(red: 0.965, green: 0.965, blue: 0.961, alpha: 1)
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
            let nextFirstID = cards.first?.id
            let sourceSwitched = (firstCardID != nil && nextFirstID != nil && nextFirstID != firstCardID)
            let wasReset = cards.count < self.cards.count || (cards.isEmpty && !self.cards.isEmpty) || sourceSwitched
            self.cards = cards
            self.firstCardID = nextFirstID
            self.lastLayoutRevision = layoutRevision
            if wasReset && bounds.width > 40 && bounds.height > 40 {
                stopAnimationLoop()
                let initialScale: CGFloat = bounds.width < 520 ? 0.68 : 0.88
                camera = InfiniteSpatialCamera.centered(in: bounds.size, scale: initialScale)
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

    func handleCameraCommand(_ command: PinterestCameraCommandMobile) {
        guard lastCommandID != command.id else { return }
        lastCommandID = command.id
        guard bounds.width > 40, bounds.height > 40 else { return }

        switch command.action {
        case .none:
            break
        case .resetCenter:
            let initialScale: CGFloat = bounds.width < 520 ? 0.68 : 0.88
            animateCamera(to: InfiniteSpatialCamera.centered(in: bounds.size, scale: initialScale))
        case .zoomBy(let factor):
            var target = camera
            target.zoom(to: camera.scale * factor, anchoredAt: CGPoint(x: bounds.midX, y: bounds.midY))
            animateCamera(to: target)
        }
    }

    // MARK: - Hit-Testing Exclusion for Floating SwiftUI Controls

    override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? {
        if isInteractionSuspended {
            return nil
        }
        if !excludedGlobalRects.isEmpty {
            let pointInWindow = convert(point, to: window)
            for rect in excludedGlobalRects where rect.width > 0 && rect.height > 0 {
                if rect.insetBy(dx: -8, dy: -8).contains(pointInWindow) {
                    return nil
                }
            }
        }
        return super.hitTest(point, with: event)
    }

    // MARK: - Gesture Handlers (Simultaneous Anchor Pinch + 360° Inertial Pan)

    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldReceive touch: UITouch) -> Bool {
        if isInteractionSuspended {
            return false
        }
        if !excludedGlobalRects.isEmpty {
            let pointInWindow = touch.location(in: window)
            for rect in excludedGlobalRects where rect.width > 0 && rect.height > 0 {
                if rect.insetBy(dx: -8, dy: -8).contains(pointInWindow) {
                    return false
                }
            }
        }
        return true
    }

    func gestureRecognizer(
        _ gestureRecognizer: UIGestureRecognizer,
        shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer
    ) -> Bool {
        if (gestureRecognizer === panGesture && otherGestureRecognizer === pinchGesture)
            || (gestureRecognizer === pinchGesture && otherGestureRecognizer === panGesture) {
            return true
        }
        return false
    }

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
        super.touchesBegan(touches, with: event)
        if !isInteractionSuspended {
            stopAnimationLoop()
        }
    }

    @objc private func handlePan(_ recognizer: UIPanGestureRecognizer) {
        guard !isInteractionSuspended else { return }
        switch recognizer.state {
        case .began:
            stopAnimationLoop()
            lastPanTranslation = .zero
        case .changed:
            // When two-finger pinching is active, pinch handler already applies exact centroid tracking
            // so we don't double-pan.
            guard !isPinching else {
                lastPanTranslation = recognizer.translation(in: self)
                return
            }
            let current = recognizer.translation(in: self)
            let dx = current.x - lastPanTranslation.x
            let dy = current.y - lastPanTranslation.y
            lastPanTranslation = current

            camera.pan(by: CGSize(width: dx, height: dy))
            syncVisibleTiles()
            notifyCameraChanged()
        case .ended, .cancelled:
            guard !isPinching else { return }
            let rawVelocity = recognizer.velocity(in: self)
            let speed = hypot(rawVelocity.x, rawVelocity.y)
            if speed > 65 {
                let maxSpeed: CGFloat = 3600
                if speed > maxSpeed {
                    let ratio = maxSpeed / speed
                    velocity = CGPoint(x: rawVelocity.x * ratio, y: rawVelocity.y * ratio)
                } else {
                    velocity = rawVelocity
                }
                startInertiaGlide()
            }
        default:
            break
        }
    }

    @objc private func handlePinch(_ recognizer: UIPinchGestureRecognizer) {
        guard !isInteractionSuspended else { return }
        switch recognizer.state {
        case .began:
            stopAnimationLoop()
            isPinching = true
            lastPinchScale = recognizer.scale
            lastPinchCentroid = recognizer.location(in: self)
        case .changed:
            guard recognizer.numberOfTouches >= 2 else { return }
            let centroid = recognizer.location(in: self)
            let dx = centroid.x - lastPinchCentroid.x
            let dy = centroid.y - lastPinchCentroid.y
            lastPinchCentroid = centroid

            camera.pan(by: CGSize(width: dx, height: dy))

            let currentScale = max(0.01, recognizer.scale)
            let ratio = currentScale / max(0.01, lastPinchScale)
            lastPinchScale = currentScale

            camera.zoom(to: camera.scale * ratio, anchoredAt: centroid)
            syncVisibleTiles()
            notifyCameraChanged()
        case .ended, .cancelled, .failed:
            isPinching = false
            lastPinchScale = 1.0
        default:
            break
        }
    }

    @objc private func handleTap(_ recognizer: UITapGestureRecognizer) {
        guard !isInteractionSuspended else { return }
        stopAnimationLoop()
        let pt = recognizer.location(in: self)
        guard let tile = hitTestTile(at: pt), let pin = tile.pin else { return }

        let localPt = convert(pt, to: tile)
        if fastPickMode || tile.isPointInCartButton(localPt) {
            MobileHaptics.light()
            tile.playPickPulse()
            onToggleTray?(pin)
        } else {
            MobileHaptics.light()
            onOpenDetail?(pin)
        }
    }

    private func hitTestTile(at point: CGPoint) -> PinterestSpatialTileUIView? {
        for subview in subviews.reversed() {
            guard let tile = subview as? PinterestSpatialTileUIView else { continue }
            if tile.frame.contains(point) {
                return tile
            }
        }
        return nil
    }

    // MARK: - Viewport Culling & Recycled Tile Sync

    private func syncVisibleTiles() {
        guard bounds.width > 10, bounds.height > 10 else { return }

        let visibleWorld = camera.visibleWorldRect(viewportSize: bounds.size)
        let overscanWorld = max(240, 320 / max(0.25, camera.scale))
        let expandedWorld = visibleWorld.insetBy(dx: -overscanWorld, dy: -overscanWorld)

        var visibleSet = Set<String>()
        var visibleList: [PinterestSpatialCard] = []
        visibleList.reserveCapacity(72)

        for card in cards {
            if card.frame.intersects(expandedWorld) {
                visibleSet.insert(card.id)
                visibleList.append(card)
            }
        }

        CATransaction.begin()
        CATransaction.setDisableActions(true)

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

            let tile: PinterestSpatialTileUIView
            if let existing = activeTiles[card.id] {
                tile = existing
            } else {
                tile = recycledTiles.popLast() ?? PinterestSpatialTileUIView()
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
                fastPickMode: fastPickMode
            )
        }
        CATransaction.commit()
    }

    // MARK: - 120Hz DisplayLink Deceleration & Smooth Camera Animations

    private func startInertiaGlide() {
        cameraAnimStart = nil
        cameraAnimTarget = nil
        lastFrameTimestamp = CACurrentMediaTime()
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
        if displayLink == nil {
            let proxy = PinterestDisplayLinkProxy(target: self)
            let link = CADisplayLink(target: proxy, selector: #selector(PinterestDisplayLinkProxy.tick(_:)))
            if #available(iOS 15.0, *) {
                link.preferredFrameRateRange = CAFrameRateRange(minimum: 60, maximum: 120, preferred: 120)
            }
            link.add(to: .main, forMode: .common)
            displayLink = link
        }
        displayLink?.isPaused = false
    }

    private func stopAnimationLoop() {
        velocity = .zero
        cameraAnimStart = nil
        cameraAnimTarget = nil
        displayLink?.isPaused = true
    }

    fileprivate func handleDisplayLink(_ link: CADisplayLink) {
        let now = CACurrentMediaTime()

        if let start = cameraAnimStart, let target = cameraAnimTarget {
            let elapsed = now - cameraAnimStartTime
            let progress = min(1.0, max(0.0, elapsed / cameraAnimDuration))
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

        let dt = min(0.05, max(0.001, now - lastFrameTimestamp))
        lastFrameTimestamp = now

        camera.pan(by: CGSize(width: velocity.x * dt, height: velocity.y * dt))
        let damping = pow(0.935, dt * 60.0)
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

// MARK: - Lightweight Recycled Spatial Card Tile (UIKit)

private final class PinterestSpatialTileUIView: UIView {
    private(set) var pin: PinterestPin?

    private let imageView = UIImageView()
    private let cartBadge = UIView()
    private let cartIcon = UIImageView()
    private let importedLabel = UILabel()
    private let videoIcon = UIImageView()

    private var loadedURL: URL?
    private var inFlightURL: URL?
    private var imageLoadTask: Task<Void, Never>?
    private var isDark: Bool = false
    private var accentColor: UIColor = UIColor(red: 0.165, green: 0.376, blue: 0.878, alpha: 1)

    override init(frame: CGRect) {
        super.init(frame: frame)
        isUserInteractionEnabled = false
        clipsToBounds = true
        layer.cornerCurve = .continuous

        imageView.contentMode = .scaleAspectFill
        imageView.clipsToBounds = true
        imageView.alpha = 0
        addSubview(imageView)

        cartBadge.layer.shadowColor = UIColor.black.cgColor
        cartBadge.layer.shadowOpacity = 0.25
        cartBadge.layer.shadowRadius = 5
        cartBadge.layer.shadowOffset = CGSize(width: 0, height: 2)
        cartIcon.contentMode = .center
        cartIcon.tintColor = .white
        cartBadge.addSubview(cartIcon)
        addSubview(cartBadge)

        importedLabel.text = "已入库"
        importedLabel.font = .systemFont(ofSize: 9.5, weight: .semibold)
        importedLabel.textColor = .white
        importedLabel.textAlignment = .center
        importedLabel.backgroundColor = UIColor.black.withAlphaComponent(0.62)
        importedLabel.layer.cornerRadius = 6
        importedLabel.layer.cornerCurve = .continuous
        importedLabel.clipsToBounds = true
        importedLabel.isHidden = true
        addSubview(importedLabel)

        videoIcon.image = UIImage(systemName: "play.fill", withConfiguration: UIImage.SymbolConfiguration(pointSize: 9, weight: .bold))
        videoIcon.tintColor = .white
        videoIcon.contentMode = .center
        videoIcon.backgroundColor = UIColor.black.withAlphaComponent(0.56)
        videoIcon.layer.cornerRadius = 11
        videoIcon.clipsToBounds = true
        videoIcon.isHidden = true
        addSubview(videoIcon)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func applyTheme(isDark: Bool, accent: UIColor) {
        self.isDark = isDark
        self.accentColor = accent
    }

    func prepareForReuse() {
        imageLoadTask?.cancel()
        imageLoadTask = nil
        pin = nil
        loadedURL = nil
        inFlightURL = nil
        imageView.image = nil
        imageView.alpha = 0
    }

    func configure(pin: PinterestPin) {
        self.pin = pin
        self.loadedURL = nil
        self.inFlightURL = nil
        self.imageLoadTask?.cancel()
        self.imageLoadTask = nil
        imageView.image = nil
        imageView.alpha = 0

        if let hex = pin.dominantColorHex, let color = Self.uiColor(fromHex: hex) {
            backgroundColor = color.withAlphaComponent(isDark ? 0.34 : 0.22)
        } else {
            backgroundColor = isDark ? UIColor(white: 0.14, alpha: 1) : UIColor(white: 0.91, alpha: 1)
        }
    }

    func updatePresentation(
        cornerRadius: CGFloat,
        renderedWidth: CGFloat,
        inTray: Bool,
        isImported: Bool,
        fastPickMode: Bool
    ) {
        guard let pin else { return }

        layer.cornerRadius = cornerRadius
        imageView.frame = bounds

        if inTray {
            layer.borderColor = accentColor.cgColor
            layer.borderWidth = 2.2
        } else {
            layer.borderColor = (isDark ? UIColor.white.withAlphaComponent(0.09) : UIColor.black.withAlphaComponent(0.06)).cgColor
            layer.borderWidth = 0.6
        }

        // Browse mode stays completely clean (no '+' on images; only already-in-tray cards show '✓').
        // Fast-Pick mode reveals '+' on every card so batch picking into the tray is immediate.
        let showBadge = bounds.width >= 68 && bounds.height >= 68 && (inTray || fastPickMode)
        cartBadge.isHidden = !showBadge
        if showBadge {
            let dim: CGFloat = bounds.width < 115 ? 24 : 28
            let inset: CGFloat = bounds.width < 115 ? 6 : 8
            cartBadge.frame = CGRect(x: bounds.width - dim - inset, y: inset, width: dim, height: dim)
            cartBadge.layer.cornerRadius = dim * 0.5
            cartIcon.frame = cartBadge.bounds

            if inTray {
                cartBadge.backgroundColor = accentColor
                cartBadge.layer.borderColor = UIColor.white.withAlphaComponent(0.45).cgColor
                cartBadge.layer.borderWidth = 1.0
                cartIcon.image = UIImage(
                    systemName: "checkmark",
                    withConfiguration: UIImage.SymbolConfiguration(pointSize: dim * 0.44, weight: .bold)
                )
            } else {
                cartBadge.backgroundColor = UIColor.black.withAlphaComponent(fastPickMode ? 0.56 : 0.46)
                cartBadge.layer.borderColor = UIColor.white.withAlphaComponent(0.32).cgColor
                cartBadge.layer.borderWidth = 0.75
                cartIcon.image = UIImage(
                    systemName: "plus",
                    withConfiguration: UIImage.SymbolConfiguration(pointSize: dim * 0.46, weight: .bold)
                )
            }
        }

        let showImported = isImported && bounds.width >= 88 && bounds.height >= 68
        importedLabel.isHidden = !showImported
        if showImported {
            importedLabel.frame = CGRect(x: 7, y: bounds.height - 23, width: 40, height: 16)
        }

        if pin.isVideo && bounds.width >= 76 {
            videoIcon.isHidden = false
            videoIcon.frame = CGRect(x: 7, y: 7, width: 22, height: 22)
        } else {
            videoIcon.isHidden = true
        }

        let desiredURL = pin.imageURL(forRenderedWidth: renderedWidth)
        if desiredURL != loadedURL && desiredURL != inFlightURL {
            loadImageIfNeeded(url: desiredURL, pinID: pin.id, maxPixels: renderedWidth > 360 ? 1200 : 680)
        }
    }

    func isPointInCartButton(_ localPoint: CGPoint) -> Bool {
        guard !cartBadge.isHidden else { return false }
        return cartBadge.frame.insetBy(dx: -10, dy: -10).contains(localPoint)
    }

    func playPickPulse() {
        UIView.animate(withDuration: 0.09, delay: 0, options: [.curveEaseOut]) {
            self.transform = CGAffineTransform(scaleX: 0.94, y: 0.94)
        } completion: { _ in
            UIView.animate(withDuration: 0.20, delay: 0, usingSpringWithDamping: 0.65, initialSpringVelocity: 0.4) {
                self.transform = .identity
            }
        }
    }

    private func loadImageIfNeeded(url: URL, pinID: String, maxPixels: Int) {
        if let cached = PinterestImageCache.shared.cachedImage(for: url) {
            imageLoadTask?.cancel()
            imageLoadTask = nil
            inFlightURL = nil
            loadedURL = url
            imageView.image = cached
            imageView.alpha = 1
            return
        }

        imageLoadTask?.cancel()
        inFlightURL = url
        imageLoadTask = Task { @MainActor [weak self] in
            let img = await PinterestImageCache.shared.image(for: url, maxPixelSize: maxPixels)
            guard let self else { return }
            if self.inFlightURL == url {
                self.inFlightURL = nil
            }
            guard !Task.isCancelled, let img, self.pin?.id == pinID else {
                return
            }
            self.loadedURL = url
            let wasHidden = self.imageView.alpha < 0.5
            self.imageView.image = img
            if wasHidden {
                UIView.animate(withDuration: 0.16) {
                    self.imageView.alpha = 1
                }
            } else {
                self.imageView.alpha = 1
            }
        }
    }

    private static func uiColor(fromHex raw: String) -> UIColor? {
        let cleaned = raw.trimmingCharacters(in: .whitespacesAndNewlines).replacingOccurrences(of: "#", with: "")
        var hex: UInt64 = 0
        guard cleaned.count == 6, Scanner(string: cleaned).scanHexInt64(&hex) else { return nil }
        return UIColor(
            red: CGFloat((hex >> 16) & 0xFF) / 255.0,
            green: CGFloat((hex >> 8) & 0xFF) / 255.0,
            blue: CGFloat(hex & 0xFF) / 255.0,
            alpha: 1.0
        )
    }
}
