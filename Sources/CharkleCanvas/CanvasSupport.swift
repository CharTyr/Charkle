import AppKit
import CharkleCore
import SwiftUI

/// Module metadata for CharkleCanvas.
public struct CharkleCanvasModuleInfo: Sendable {
    public static let version = "1.0.1"
}

/// Canonical pasteboard/drag prefixes so NotchShelfController can distinguish
/// Charkle's internal card drags from external Finder/Browser drags.
public enum CharkleDragIdentifiers {
    public static let singleAssetPrefix = "charkle-asset:"
    public static let multipleAssetsPrefix = "charkle-assets:"
    public static let folderPrefix = "charkle-folder:"
    public static let multipleFoldersPrefix = "charkle-folders:"

    public static func encode(assetIDs: [UUID]) -> String {
        if assetIDs.count == 1, let first = assetIDs.first {
            return singleAssetPrefix + first.uuidString
        }
        return multipleAssetsPrefix + assetIDs.map(\.uuidString).joined(separator: ",")
    }

    public static func encode(folderID: UUID) -> String {
        folderPrefix + folderID.uuidString
    }

    public static func encode(folderIDs: [UUID]) -> String {
        if folderIDs.count == 1, let first = folderIDs.first {
            return folderPrefix + first.uuidString
        }
        return multipleFoldersPrefix + folderIDs.map(\.uuidString).joined(separator: ",")
    }

    public static func decodeAssetIDs(from raw: String) -> [UUID]? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.hasPrefix(singleAssetPrefix) {
            let idStr = String(trimmed.dropFirst(singleAssetPrefix.count))
            return UUID(uuidString: idStr).map { [$0] }
        }
        if trimmed.hasPrefix(multipleAssetsPrefix) {
            let rest = String(trimmed.dropFirst(multipleAssetsPrefix.count))
            let ids = rest.split(separator: ",").compactMap { UUID(uuidString: String($0)) }
            return ids.isEmpty ? nil : ids
        }
        return nil
    }

    public static func decodeFolderID(from raw: String) -> UUID? {
        decodeFolderIDs(from: raw)?.first
    }

    public static func decodeFolderIDs(from raw: String) -> [UUID]? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.hasPrefix(folderPrefix) {
            return UUID(uuidString: String(trimmed.dropFirst(folderPrefix.count))).map { [$0] }
        }
        if trimmed.hasPrefix(multipleFoldersPrefix) {
            let rest = String(trimmed.dropFirst(multipleFoldersPrefix.count))
            let ids = rest.split(separator: ",").compactMap { UUID(uuidString: String($0)) }
            return ids.isEmpty ? nil : ids
        }
        return nil
    }

    public static func isInternalDrag(_ raw: String) -> Bool {
        decodeAssetIDs(from: raw) != nil || decodeFolderIDs(from: raw) != nil
    }
}

/// Pure, testable geometry & drag-gating rules for the Notch Shelf's drag-expand trigger strip
/// and strict drop acceptance bounds (zero transparent shadow-margin bleed, zero stale-pasteboard false triggers).
public nonisolated enum NotchDropGeometry {
    /// Strict hit-test & drop acceptance rect in unflipped AppKit **window coordinates**
    /// (`y = 0` at bottom of panel, `y = panelBounds.maxY` at top screen bezel),
    /// matching ONLY the visible pure-black notch capsule body (excluding transparent shadow margins).
    /// Always compare against AppKit window coordinates (`sender.draggingLocation` or
    /// `superview?.convert(point, to: nil)`), never against `NSHostingView`'s flipped local coordinates.
    public static func strictCardRect(
        panelBounds: NSRect,
        bodyWidth: CGFloat,
        cardHeight: CGFloat
    ) -> NSRect {
        guard panelBounds.width > 0, panelBounds.height > 0, bodyWidth > 0, cardHeight > 0 else {
            return .zero
        }
        return NSRect(
            x: panelBounds.midX - bodyWidth / 2.0,
            y: panelBounds.maxY - cardHeight,
            width: bodyWidth,
            height: cardHeight
        )
    }

    /// Guards proactive drag-open against macOS's persistent `NSPasteboard(.drag)` contents:
    /// macOS never clears the drag pasteboard after a previous drag ends, so only a live `changeCount`
    /// transition away from the idle baseline counts as an active external drag.
    public static func shouldTriggerProactiveDragExpand(
        currentDragChangeCount: Int,
        baselineDragChangeCount: Int,
        isInternalDrag: Bool,
        hasDroppablePayload: Bool
    ) -> Bool {
        currentDragChangeCount != baselineDragChangeCount && !isInternalDrag && hasDroppablePayload
    }

    /// Strict visible pure-black notch capsule rect in global screen coordinates.
    public static func strictScreenCardRect(
        panelFrame: NSRect,
        bodyWidth: CGFloat,
        cardHeight: CGFloat
    ) -> NSRect {
        guard panelFrame.width > 0, panelFrame.height > 0, bodyWidth > 0, cardHeight > 0 else {
            return .zero
        }
        return NSRect(
            x: panelFrame.midX - bodyWidth / 2.0,
            y: panelFrame.maxY - cardHeight,
            width: bodyWidth,
            height: cardHeight
        )
    }

    /// Comfortable top-center arrival band below the menu bar / physical notch for opening the Notch Shelf
    /// while dragging an external payload. Stops well below `screenFrame.maxY` so users never collide with
    /// macOS Mission Control / Spaces top-edge triggers, while actual drop acceptance stays strictly inside
    /// `strictCardRect` (never leaking into underlying apps).
    public static func isPointInDragTriggerZone(
        _ screenPoint: NSPoint,
        screenFrame: NSRect,
        hasPhysicalNotch: Bool,
        notchWidth: CGFloat,
        notchHeight: CGFloat
    ) -> Bool {
        let triggerHeight: CGFloat = hasPhysicalNotch ? (max(notchHeight, 34) + 32) : 48
        let halfSpan: CGFloat = hasPhysicalNotch ? (notchWidth / 2.0 + 64) : 164
        return screenPoint.y >= screenFrame.maxY - triggerHeight
            && screenPoint.y <= screenFrame.maxY
            && abs(screenPoint.x - screenFrame.midX) <= halfSpan
    }

    /// Tight top-center trigger strip for hover-to-open (when hover trigger is enabled).
    public static func isPointInHoverTriggerZone(
        _ screenPoint: NSPoint,
        screenFrame: NSRect,
        hasPhysicalNotch: Bool,
        notchWidth: CGFloat,
        notchHeight: CGFloat
    ) -> Bool {
        let triggerHeight: CGFloat = hasPhysicalNotch ? max(notchHeight, 34) : 8
        let halfSpan: CGFloat = hasPhysicalNotch ? (notchWidth / 2.0 + 10) : 108
        return screenPoint.y >= screenFrame.maxY - triggerHeight
            && screenPoint.y <= screenFrame.maxY
            && abs(screenPoint.x - screenFrame.midX) <= halfSpan
    }
}

// MARK: - Motion Tokens (Canvas Layer)

public enum CanvasMotion {
    public static let enterSm = Animation.timingCurve(0.23, 1, 0.32, 1, duration: 0.18)
    public static let enterMd = Animation.timingCurve(0.23, 1, 0.32, 1, duration: 0.24)
    public static let settleStrong = Animation.timingCurve(0.22, 1, 0.36, 1, duration: 0.22)
    public static let exitSm = Animation.timingCurve(0.23, 1, 0.32, 1, duration: 0.13)
    public static let moveOnScreen = Animation.timingCurve(0.77, 0, 0.175, 1, duration: 0.24)
    public static let drawerEase = Animation.timingCurve(0.32, 0.72, 0, 1, duration: 0.30)
    public static let microOvershoot = Animation.timingCurve(0.34, 1.56, 0.64, 1, duration: 0.26)
    public static let notchMorphSpring = Animation.spring(duration: 0.42, bounce: 0.08)
    public static let gestureSpring = Animation.spring(duration: 0.36, bounce: 0.10)
    public static let uiSpring = Animation.spring(duration: 0.28, bounce: 0.0)
    public static let densityResizeSpring = Animation.spring(duration: 0.28, bounce: 0.06)
    public static let hoverPress = Animation.timingCurve(0.23, 1, 0.32, 1, duration: 0.12)
    public static let reducedFade = Animation.easeOut(duration: 0.15)

    public static func accessible(_ animation: Animation, reduced: Bool) -> Animation {
        reduced ? reducedFade : animation
    }

    /// Drag-ripple neighbor displacement offset: `A * pow(0.7, n)`.
    public static func rippleOffset(distance: Int, amplitude: CGFloat = 8) -> CGFloat {
        guard distance >= 0 else { return 0 }
        return amplitude * pow(0.7, CGFloat(distance))
    }

    /// Drag-ripple outward stagger delay: `24ms * n`.
    public static func rippleDelay(distance: Int) -> Double {
        guard distance > 0 else { return 0 }
        return 0.024 * Double(min(distance, 8))
    }
}

/// Shared interruptible drop-target ring overlay for Gallery Masonry and Moodboard Canvas.
/// Pure GPU transform (`scaleEffect`) + `opacity` only, with asymmetric `enterSm`/`exitSm`
/// timing and automatic Reduce Motion degradation.
public struct CanvasDropRingOverlay: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    public let isTargeted: Bool
    public let padding: CGFloat
    public let fillOpacity: Double

    public init(isTargeted: Bool, padding: CGFloat = 12, fillOpacity: Double = 0.05) {
        self.isTargeted = isTargeted
        self.padding = padding
        self.fillOpacity = fillOpacity
    }

    public var body: some View {
        RoundedRectangle(cornerRadius: 16, style: .continuous)
            .strokeBorder(Color.accentColor.opacity(0.75), style: StrokeStyle(lineWidth: 2, dash: [8, 6]))
            .background(Color.accentColor.opacity(fillOpacity), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            .padding(padding)
            .scaleEffect(isTargeted ? 1.0 : (reduceMotion ? 1.0 : 0.985))
            .opacity(isTargeted ? 1.0 : 0.0)
            .allowsHitTesting(false)
            .animation(
                CanvasMotion.accessible(isTargeted ? CanvasMotion.enterSm : CanvasMotion.exitSm, reduced: reduceMotion),
                value: isTargeted
            )
    }
}

// MARK: - Geometry Conversions

public extension BoardRect {
    nonisolated var cgRect: CGRect {
        CGRect(x: x, y: y, width: width, height: height)
    }

    nonisolated init(_ rect: CGRect) {
        self.init(x: rect.origin.x, y: rect.origin.y, width: rect.size.width, height: rect.size.height)
    }

    nonisolated func contains(_ point: BoardPoint) -> Bool {
        point.x >= minX && point.x <= maxX && point.y >= minY && point.y <= maxY
    }

    nonisolated func intersects(_ other: BoardRect) -> Bool {
        minX < other.maxX && maxX > other.minX && minY < other.maxY && maxY > other.minY
    }
}

public extension BoardPoint {
    nonisolated var cgPoint: CGPoint {
        CGPoint(x: x, y: y)
    }

    nonisolated init(_ point: CGPoint) {
        self.init(x: point.x, y: point.y)
    }
}

// MARK: - Color & Palette Helpers

public extension NSColor {
    nonisolated static func charkleHex(_ hex: String, fallback: NSColor = .systemGray) -> NSColor {
        let cleaned = hex.trimmingCharacters(in: .whitespacesAndNewlines).replacingOccurrences(of: "#", with: "")
        guard cleaned.count == 6, let value = UInt32(cleaned, radix: 16) else {
            return fallback
        }
        let r = CGFloat((value >> 16) & 0xFF) / 255.0
        let g = CGFloat((value >> 8) & 0xFF) / 255.0
        let b = CGFloat(value & 0xFF) / 255.0
        return NSColor(srgbRed: r, green: g, blue: b, alpha: 1.0)
    }
}

public extension Color {
    nonisolated init(charkleHex hex: String) {
        let cleaned = hex.trimmingCharacters(in: .whitespacesAndNewlines).replacingOccurrences(of: "#", with: "")
        guard cleaned.count == 6, let value = UInt32(cleaned, radix: 16) else {
            self.init(red: 0.52, green: 0.54, blue: 0.56)
            return
        }
        let r = Double((value >> 16) & 0xFF) / 255.0
        let g = Double((value >> 8) & 0xFF) / 255.0
        let b = Double(value & 0xFF) / 255.0
        self.init(.sRGB, red: r, green: g, blue: b, opacity: 1.0)
    }

    /// Relative luminance for picking crisp contrasting ink over swatches.
    nonisolated static func charkleIsLightHex(_ hex: String) -> Bool {
        let cleaned = hex.trimmingCharacters(in: .whitespacesAndNewlines).replacingOccurrences(of: "#", with: "")
        guard cleaned.count == 6, let value = UInt32(cleaned, radix: 16) else { return false }
        let r = Double((value >> 16) & 0xFF) / 255.0
        let g = Double((value >> 8) & 0xFF) / 255.0
        let b = Double(value & 0xFF) / 255.0
        let luminance = 0.299 * r + 0.587 * g + 0.114 * b
        return luminance > 0.62
    }
}

// MARK: - Gallery-First Neutral Canvas Surfaces & Restrained Liquid Glass

public enum CanvasSurface {
    public static func ground(for scheme: ColorScheme) -> Color {
        scheme == .dark ? Color(charkleHex: "#141517") : Color(charkleHex: "#F6F6F5")
    }

    public static func elevated(for scheme: ColorScheme) -> Color {
        scheme == .dark ? Color(charkleHex: "#1E2024") : Color(charkleHex: "#FFFFFF")
    }

    public static func subtleCard(for scheme: ColorScheme) -> Color {
        scheme == .dark ? Color(charkleHex: "#202227") : Color(charkleHex: "#ECECE9")
    }

    public static func hairline(for scheme: ColorScheme) -> Color {
        scheme == .dark ? Color.white.opacity(0.09) : Color.black.opacity(0.08)
    }
}

public struct CanvasGlassContainer<Content: View>: View {
    private let spacing: CGFloat?
    private let content: Content

    public init(spacing: CGFloat? = nil, @ViewBuilder content: () -> Content) {
        self.spacing = spacing
        self.content = content()
    }

    public var body: some View {
        if #available(macOS 26, *) {
            GlassEffectContainer(spacing: spacing) {
                content
            }
        } else {
            content
        }
    }
}

public struct CanvasLiquidGlassModifier<S: InsettableShape>: ViewModifier {
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.colorScheme) private var colorScheme

    private let shape: S
    private let interactive: Bool

    public init(shape: S, interactive: Bool = false) {
        self.shape = shape
        self.interactive = interactive
    }

    public func body(content: Content) -> some View {
        if reduceTransparency {
            content
                .background(CanvasSurface.elevated(for: colorScheme), in: shape)
                .overlay(shape.strokeBorder(CanvasSurface.hairline(for: colorScheme), lineWidth: 1))
                .shadow(color: Color.black.opacity(colorScheme == .dark ? 0.32 : 0.08), radius: 14, y: 6)
        } else if #available(macOS 26, *) {
            let glass: Glass = interactive ? .regular.interactive() : .regular
            content
                .glassEffect(glass, in: shape)
        } else {
            content
                .background(.ultraThinMaterial, in: shape)
                .overlay {
                    shape.strokeBorder(
                        LinearGradient(
                            colors: [
                                Color.white.opacity(colorScheme == .dark ? 0.24 : 0.80),
                                Color.white.opacity(colorScheme == .dark ? 0.06 : 0.25)
                            ],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        ),
                        lineWidth: 0.75
                    )
                }
                .shadow(color: Color.black.opacity(colorScheme == .dark ? 0.36 : 0.10), radius: 16, y: 6)
        }
    }
}

public extension View {
    func canvasLiquidGlass<S: InsettableShape>(in shape: S, interactive: Bool = false) -> some View {
        modifier(CanvasLiquidGlassModifier(shape: shape, interactive: interactive))
    }

    @ViewBuilder
    func canvasScrollEdgeSoft(for edges: Edge.Set = .top) -> some View {
        if #available(macOS 26, *) {
            self.scrollEdgeEffectStyle(.soft, for: edges)
        } else {
            self
        }
    }
}

// MARK: - Horizontal Wheel Scroll Redirector (Normal Vertical Wheel Scrolls Horizontal Strips)

/// Lightweight AppKit event monitor attached to horizontal `ScrollView`s (e.g. Notch recent strip,
/// Gallery filmstrip) so standard vertical mouse wheel / trackpad vertical scroll effortlessly scrolls
/// horizontally without requiring the user to hold `Shift`. Native horizontal trackpad swipes pass through untouched.
public struct HorizontalWheelScrollRedirector: NSViewRepresentable {
    public init() {}

    public func makeNSView(context: Context) -> RedirectorNSView {
        RedirectorNSView()
    }

    public func updateNSView(_ nsView: RedirectorNSView, context: Context) {}

    public static func dismantleNSView(_ nsView: RedirectorNSView, coordinator: ()) {
        nsView.teardown()
    }

    public final class RedirectorNSView: NSView {
        private var scrollMonitor: Any?

        public override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if window != nil {
                installMonitorIfNeeded()
            } else {
                teardown()
            }
        }

        private func installMonitorIfNeeded() {
            guard scrollMonitor == nil else { return }
            scrollMonitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { [weak self] event in
                guard let self else { return event }
                return self.handleScrollWheel(event)
            }
        }

        func teardown() {
            if let monitor = scrollMonitor {
                NSEvent.removeMonitor(monitor)
                scrollMonitor = nil
            }
        }

        isolated deinit {
            teardown()
        }

        private func handleScrollWheel(_ event: NSEvent) -> NSEvent? {
            guard let hostWindow = self.window, event.window === hostWindow, !isHiddenOrHasHiddenAncestor else {
                return event
            }
            // Respect Cmd-zoom shortcuts and native horizontal trackpad swipes / Shift-scroll
            let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
            if flags.contains(.command) || flags.contains(.control) {
                return event
            }
            let dy = event.scrollingDeltaY
            let dx = event.scrollingDeltaX
            guard abs(dy) > abs(dx), abs(dy) > 0.01 else {
                return event
            }

            let localPoint = convert(event.locationInWindow, from: nil)
            guard bounds.contains(localPoint) else {
                return event
            }

            guard let scrollView = findAssociatedHorizontalScrollView(eventLocationInWindow: event.locationInWindow) else {
                return event
            }

            let clipView = scrollView.contentView
            let docWidth = scrollView.documentView?.frame.width ?? 0
            let maxX = max(0, docWidth - clipView.bounds.width)
            guard maxX > 0.5 else {
                return nil
            }

            let step = event.hasPreciseScrollingDeltas ? dy : dy * 18.0
            let currentOrigin = clipView.bounds.origin
            let nextX = max(0, min(maxX, currentOrigin.x - step))
            if abs(nextX - currentOrigin.x) > 0.01 {
                clipView.scroll(to: NSPoint(x: nextX, y: currentOrigin.y))
                scrollView.reflectScrolledClipView(clipView)
            }
            return nil
        }

        private func findAssociatedHorizontalScrollView(eventLocationInWindow: NSPoint) -> NSScrollView? {
            if let enclosing = enclosingScrollView {
                return enclosing
            }
            if let hitView = window?.contentView?.hitTest(eventLocationInWindow) {
                var cursor: NSView? = hitView
                while let view = cursor {
                    if let sv = view as? NSScrollView {
                        return sv
                    }
                    cursor = view.superview
                }
            }
            // Fallback: inspect superview subtree (when mounted via `.background(...)` on SwiftUI ScrollView)
            guard let parent = superview else { return nil }
            var queue: [NSView] = parent.subviews
            var idx = 0
            while idx < queue.count {
                let candidate = queue[idx]
                idx += 1
                if candidate === self { continue }
                if let sv = candidate as? NSScrollView {
                    return sv
                }
                queue.append(contentsOf: candidate.subviews)
            }
            return nil
        }
    }
}

// MARK: - Interactive Stage Bridge (Direct Scroll-Wheel Zoom + Always-Fresh Keyboard Monitor)

/// Reusable AppKit event bridge for visual preview stages (`GalleryFilmstripView`, `QuickLookOverlayView`).
/// Updates its closures in `updateNSView` so SwiftUI value-type state (`assets`, `isQuickLookPresented`,
/// `supportsVisualTransform`) is NEVER captured stale, and cleans up deterministically in `dismantleNSView`/`deinit`.
public struct StageInteractiveBridge: NSViewRepresentable {
    public let isWheelZoomEnabled: Bool
    public let onWheelZoom: (CGFloat) -> Void
    public let onKeyDown: (NSEvent) -> NSEvent?

    public init(
        isWheelZoomEnabled: Bool,
        onWheelZoom: @escaping (CGFloat) -> Void,
        onKeyDown: @escaping (NSEvent) -> NSEvent?
    ) {
        self.isWheelZoomEnabled = isWheelZoomEnabled
        self.onWheelZoom = onWheelZoom
        self.onKeyDown = onKeyDown
    }

    public func makeNSView(context: Context) -> BridgeNSView {
        let view = BridgeNSView()
        view.isWheelZoomEnabled = isWheelZoomEnabled
        view.onWheelZoom = onWheelZoom
        view.onKeyDown = onKeyDown
        return view
    }

    public func updateNSView(_ nsView: BridgeNSView, context: Context) {
        nsView.isWheelZoomEnabled = isWheelZoomEnabled
        nsView.onWheelZoom = onWheelZoom
        nsView.onKeyDown = onKeyDown
    }

    public static func dismantleNSView(_ nsView: BridgeNSView, coordinator: ()) {
        nsView.teardown()
    }

    public final class BridgeNSView: NSView {
        var isWheelZoomEnabled: Bool = false
        var onWheelZoom: ((CGFloat) -> Void)?
        var onKeyDown: ((NSEvent) -> NSEvent?)?

        private var scrollMonitor: Any?
        private var keyMonitor: Any?

        public override func hitTest(_ point: NSPoint) -> NSView? {
            nil
        }

        public override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if window != nil {
                installMonitorsIfNeeded()
            } else {
                teardown()
            }
        }

        private func installMonitorsIfNeeded() {
            if scrollMonitor == nil {
                scrollMonitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { [weak self] event in
                    guard let self else { return event }
                    return self.handleScrollWheel(event)
                }
            }
            if keyMonitor == nil {
                keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
                    guard let self, let hostWindow = self.window else {
                        return event
                    }
                    let sameWindow = (event.window === hostWindow) || (event.window?.parent === hostWindow)
                    guard sameWindow else { return event }
                    return self.onKeyDown?(event) ?? event
                }
            }
        }

        func teardown() {
            if let monitor = scrollMonitor {
                NSEvent.removeMonitor(monitor)
                scrollMonitor = nil
            }
            if let monitor = keyMonitor {
                NSEvent.removeMonitor(monitor)
                keyMonitor = nil
            }
        }

        isolated deinit {
            teardown()
        }

        private func handleScrollWheel(_ event: NSEvent) -> NSEvent? {
            guard isWheelZoomEnabled,
                  let hostWindow = self.window,
                  event.window === hostWindow,
                  hostWindow.attachedSheet == nil,
                  !isHiddenOrHasHiddenAncestor else {
                return event
            }
            let localPoint = convert(event.locationInWindow, from: nil)
            guard bounds.contains(localPoint) else {
                return event
            }
            let dy = event.scrollingDeltaY
            guard abs(dy) > 0.01 else { return event }
            // Ignore trailing trackpad momentum deceleration so zooming stops crisply where the user lifts fingers
            if !event.momentumPhase.isEmpty {
                return nil
            }
            let sensitivity: CGFloat = event.hasPreciseScrollingDeltas ? 0.0042 : 0.055
            let clampedDelta = max(-60, min(60, dy))
            let factor = exp(clampedDelta * sensitivity)
            onWheelZoom?(factor)
            return nil
        }
    }
}

// MARK: - Window-Scoped KeyDown Event Bridge (Top-Priority Spacebar & Global Stage Shortcuts)

/// Lightweight AppKit `.keyDown` monitor attached at the root of a window so top-priority shortcuts
/// (such as Quick Look `Space` open/close) run deterministically before nested views and regardless of
/// SwiftUI/AppKit focus drift. Updates its closure on every `updateNSView` and cleans up in `dismantleNSView`/`deinit`.
public struct WindowKeyEventBridge: NSViewRepresentable {
    public let onKeyDown: (NSEvent, NSWindow) -> NSEvent?

    public init(onKeyDown: @escaping (NSEvent, NSWindow) -> NSEvent?) {
        self.onKeyDown = onKeyDown
    }

    public func makeNSView(context: Context) -> KeyBridgeNSView {
        let view = KeyBridgeNSView()
        view.onKeyDown = onKeyDown
        return view
    }

    public func updateNSView(_ nsView: KeyBridgeNSView, context: Context) {
        nsView.onKeyDown = onKeyDown
    }

    public static func dismantleNSView(_ nsView: KeyBridgeNSView, coordinator: ()) {
        nsView.teardown()
    }

    public final class KeyBridgeNSView: NSView {
        var onKeyDown: ((NSEvent, NSWindow) -> NSEvent?)?
        private var keyMonitor: Any?

        public override func hitTest(_ point: NSPoint) -> NSView? {
            nil
        }

        public override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if window != nil {
                installMonitorIfNeeded()
            } else {
                teardown()
            }
        }

        private func installMonitorIfNeeded() {
            guard keyMonitor == nil else { return }
            keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
                guard let self, let hostWindow = self.window else { return event }
                let belongsToWindow = (event.window === hostWindow) || (event.window?.parent === hostWindow)
                guard belongsToWindow else { return event }
                return self.onKeyDown?(event, hostWindow) ?? event
            }
        }

        func teardown() {
            if let monitor = keyMonitor {
                NSEvent.removeMonitor(monitor)
                keyMonitor = nil
            }
        }

        isolated deinit {
            teardown()
        }
    }
}

// MARK: - Formatting Helpers

public enum CanvasFormatters {
    public static func durationString(_ seconds: Double?) -> String {
        guard let seconds, seconds.isFinite, seconds >= 0 else { return "0:00" }
        let total = Int(seconds.rounded())
        let mins = total / 60
        let secs = total % 60
        return String(format: "%d:%02d", mins, secs)
    }

    public static func fileExtensionBadge(for fileName: String) -> String {
        let ext = URL(fileURLWithPath: fileName).pathExtension.uppercased()
        return ext.isEmpty ? "FILE" : String(ext.prefix(6))
    }
}
