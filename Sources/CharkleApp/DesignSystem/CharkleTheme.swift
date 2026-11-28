import AppKit
import CharkleCanvas
import SwiftUI

// MARK: - Dual Accent Source (Studio Cobalt vs. Live macOS System Accent)

public nonisolated enum CharkleAccentSource: String, CaseIterable, Identifiable, Hashable, Sendable {
    case studio
    case system

    public var id: String { rawValue }

    public var displayTitle: String {
        switch self {
        case .studio: "工作室钴蓝"
        case .system: "跟随 macOS 系统"
        }
    }

    public var shortTitle: String {
        switch self {
        case .studio: "工作室钴蓝"
        case .system: "跟随系统"
        }
    }

    public var subtitle: String {
        switch self {
        case .studio: "校准工作室钴蓝，保持画布中性专注"
        case .system: "实时同步 macOS 系统设置中的强调色"
        }
    }
}

extension EnvironmentValues {
    @Entry public var charkleAccentSource: CharkleAccentSource = .studio
}

/// Canonical 4-step macOS studio typography scale (`>= 12pt` floor for all UI copy).
/// Hierarchy is built with weight, ink opacity, and `.monospacedDigit()` rather than
/// fragmented half-point sizes.
public nonisolated enum CharkleTextStyle: CGFloat, CaseIterable, Hashable, Sendable {
    /// `12pt` — Metadata, secondary subtitles, inspector specs, badges, pills, keycaps.
    case caption = 12
    /// `13pt` — Standard macOS body text, buttons, inputs, sidebar items, settings row titles.
    case body = 13
    /// `16pt` — Section & sheet headers, empty-state headlines, modal card headings.
    case headline = 16
    /// `20pt` — Top-level page, onboarding, and hero dialog titles.
    case title = 20
}

/// Gallery-First neutral surfaces, continuous concentric radii, dual accent tokens,
/// and Restrained Apple Liquid Glass tokens (macOS 26+ native with calibrated macOS 15
/// and Reduce Transparency fallbacks).
public enum CharkleTheme {
    // MARK: - Canonical 4-Step Studio Typography (`>= 12pt` Floor)

    public nonisolated static func text(
        _ style: CharkleTextStyle,
        weight: Font.Weight = .regular,
        design: Font.Design = .default
    ) -> Font {
        .system(size: style.rawValue, weight: weight, design: design)
    }

    // MARK: - Retina Hairline Geometry

    /// Standard Retina 1px interior divider thickness (`0.5pt`).
    public static let hairlineWidth: CGFloat = 0.5

    // MARK: - Studio Accent Palette (Zero Violet / Lavender Hues)

    public static let studioAccentLightHex: String = "#2A60E0"
    public static let studioAccentDarkHex: String = "#5B8DEF"
    private static let studioAccentDarkButtonFillHex: String = "#3A70E4"

    /// Primary semantic accent color respecting the chosen accent source (`studio` cobalt vs. live macOS `system`).
    public static func accent(for scheme: ColorScheme, source: CharkleAccentSource = .studio) -> Color {
        switch source {
        case .studio:
            scheme == .dark ? Color(charkleHex: studioAccentDarkHex) : Color(charkleHex: studioAccentLightHex)
        case .system:
            Color.accentColor
        }
    }

    /// Low-saturation translucent accent wash for subtle active badges, chips, and focus rings.
    public static func accentSoft(for scheme: ColorScheme, source: CharkleAccentSource = .studio) -> Color {
        accent(for: scheme, source: source).opacity(scheme == .dark ? 0.18 : 0.11)
    }

    /// Calibrated accent border stroke for selected outlines and interactive affordances.
    public static func accentBorder(for scheme: ColorScheme, source: CharkleAccentSource = .studio) -> Color {
        accent(for: scheme, source: source).opacity(scheme == .dark ? 0.38 : 0.26)
    }

    /// Solid accent button fill calibrated to maintain >= 4.5:1 foreground contrast in both Light and Dark modes.
    public static func accentButtonFill(for scheme: ColorScheme, source: CharkleAccentSource = .studio) -> Color {
        switch source {
        case .studio:
            scheme == .dark ? Color(charkleHex: studioAccentDarkButtonFillHex) : Color(charkleHex: studioAccentLightHex)
        case .system:
            Color.accentColor
        }
    }

    /// High-contrast foreground color on top of `accentButtonFill(for:source:)`,
    /// adapting automatically when macOS system accent is light (e.g. Yellow).
    public static func accentButtonForeground(for scheme: ColorScheme, source: CharkleAccentSource = .studio) -> Color {
        switch source {
        case .studio:
            return .white
        case .system:
            let appearance = NSAppearance(named: scheme == .dark ? .darkAqua : .aqua)
            var luminance: Double = 0.25
            appearance?.performAsCurrentDrawingAppearance {
                if let rgb = NSColor.controlAccentColor.usingColorSpace(.sRGB) {
                    luminance = relativeLuminance(
                        r: Double(rgb.redComponent),
                        g: Double(rgb.greenComponent),
                        b: Double(rgb.blueComponent)
                    )
                }
            }
            return luminance > 0.52 ? Color(charkleHex: "#141517") : .white
        }
    }

    // MARK: - Calibrated Semantic Status Colors

    public static func positive(for scheme: ColorScheme) -> Color {
        scheme == .dark ? Color(charkleHex: "#34C769") : Color(charkleHex: "#249A4B")
    }

    public static func warning(for scheme: ColorScheme) -> Color {
        scheme == .dark ? Color(charkleHex: "#F2B23E") : Color(charkleHex: "#C98212")
    }

    public static func destructive(for scheme: ColorScheme) -> Color {
        scheme == .dark ? Color(charkleHex: "#F2584D") : Color(charkleHex: "#D93B30")
    }

    // MARK: - Color Formatting Helpers

    /// Converts an `NSColor` cleanly into an uppercase sRGB `#RRGGBB` hex string.
    public nonisolated static func hexString(from nsColor: NSColor) -> String? {
        guard let srgb = nsColor.usingColorSpace(.sRGB) else { return nil }
        let r = Int((max(0, min(1, srgb.redComponent)) * 255).rounded())
        let g = Int((max(0, min(1, srgb.greenComponent)) * 255).rounded())
        let b = Int((max(0, min(1, srgb.blueComponent)) * 255).rounded())
        return String(format: "#%02X%02X%02X", r, g, b)
    }

    /// Converts a SwiftUI `Color` cleanly into an uppercase sRGB `#RRGGBB` hex string.
    public static func hexString(from color: Color) -> String? {
        hexString(from: NSColor(color))
    }

    /// Normalizes a user-entered hex string (`#RGB`, `RGB`, `#RRGGBB`, or `RRGGBB`) into uppercase `#RRGGBB`.
    public nonisolated static func normalizedHex(_ raw: String) -> String? {
        let cleaned = raw
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "#", with: "")
            .uppercased()
        guard cleaned.allSatisfy({ $0.isHexDigit }) else { return nil }
        if cleaned.count == 6 {
            return "#\(cleaned)"
        }
        if cleaned.count == 3 {
            let expanded = cleaned.map { "\($0)\($0)" }.joined()
            return "#\(expanded)"
        }
        return nil
    }

    private nonisolated static func relativeLuminance(r: Double, g: Double, b: Double) -> Double {
        func linearize(_ c: Double) -> Double {
            c <= 0.03928 ? (c / 12.92) : pow((c + 0.055) / 1.055, 2.4)
        }
        return 0.2126 * linearize(r) + 0.7152 * linearize(g) + 0.0722 * linearize(b)
    }

    // MARK: - Gallery-First Pure Neutral Studio Surfaces (Zero Yellow / Beige / Violet)

    public static func galleryGround(for scheme: ColorScheme) -> Color {
        scheme == .dark ? Color(charkleHex: "#141518") : Color(charkleHex: "#F5F5F6")
    }

    public static func surfaceElevated(for scheme: ColorScheme) -> Color {
        scheme == .dark ? Color(charkleHex: "#1C1D20") : Color(charkleHex: "#FFFFFF")
    }

    public static func surfaceSubtle(for scheme: ColorScheme) -> Color {
        scheme == .dark ? Color(charkleHex: "#25262B") : Color(charkleHex: "#F4F4F5")
    }

    public static func surfaceSubtleHover(for scheme: ColorScheme) -> Color {
        scheme == .dark ? Color(charkleHex: "#2E3036") : Color(charkleHex: "#EAEBEC")
    }

    public static func sidebarFallback(for scheme: ColorScheme) -> Color {
        scheme == .dark ? Color(charkleHex: "#16171A") : Color(charkleHex: "#F2F2F3")
    }

    public static func inspectorBackground(for scheme: ColorScheme) -> Color {
        scheme == .dark ? Color(charkleHex: "#1C1D20") : Color(charkleHex: "#FFFFFF")
    }

    public static func inspectorFieldSurface(for scheme: ColorScheme) -> Color {
        scheme == .dark ? Color(charkleHex: "#25262B") : Color(charkleHex: "#F4F4F5")
    }

    public static func hairline(for scheme: ColorScheme) -> Color {
        scheme == .dark ? Color.white.opacity(0.075) : Color.black.opacity(0.065)
    }

    public static func secondaryInk(for scheme: ColorScheme) -> Color {
        scheme == .dark ? Color.white.opacity(0.64) : Color(red: 60 / 255, green: 60 / 255, blue: 67 / 255).opacity(0.72)
    }

    /// Ultra-subtle low-saturation ambient tint for Quick Look & Single Asset Inspector (never pollutes artwork color).
    public static func ambientTint(from hex: String?, scheme: ColorScheme) -> Color {
        guard let hex else { return .clear }
        return Color(charkleHex: hex).opacity(scheme == .dark ? 0.10 : 0.06)
    }

    // MARK: - Continuous Concentric Corner Tokens (4pt Grid)

    public nonisolated enum Radius {
        /// Micro keycaps, inline color swatches, and compact inner thumbnails (`4pt`).
        public static let xs: CGFloat = 4
        /// Compact nested badges and pills inside cards or bars (`6pt`).
        public static let sm: CGFloat = 6
        /// Standard controls, buttons, text fields, menu triggers, and chips (`8pt`).
        public static let chip: CGFloat = 8
        /// Media cards, floating action bars, and compact sheets (`12pt`).
        public static let cardOuter: CGFloat = 12
        /// Settings cards, option panels, and inspector drawers (`14pt`).
        public static let settingsOuter: CGFloat = 14
        /// Popovers, trays, floating toolbars, and detail sheets (`16pt`).
        public static let popoverOuter: CGFloat = 16
        /// Large modal shells, onboarding container, and docks (`20pt`).
        public static let dockOuter: CGFloat = 20

        public static let dockPadding: CGFloat = 8
        public static let dockInner: CGFloat = concentricInner(outer: dockOuter, padding: dockPadding) // 12

        public static let cardBadgePadding: CGFloat = 6
        public static let cardInnerBadge: CGFloat = concentricInner(outer: cardOuter, padding: cardBadgePadding) // 6

        public static let settingsPadding: CGFloat = 6
        public static let settingsInner: CGFloat = concentricInner(outer: settingsOuter, padding: settingsPadding) // 8

        public static let popoverPadding: CGFloat = 6
        public static let popoverInner: CGFloat = concentricInner(outer: popoverOuter, padding: popoverPadding) // 10

        public static func concentricInner(outer: CGFloat, padding: CGFloat) -> CGFloat {
            max(4, outer - padding)
        }
    }

    // MARK: - Spacing Grid (4pt increments)

    public enum Space {
        public static let xs: CGFloat = 4
        public static let sm: CGFloat = 8
        public static let md: CGFloat = 12
        public static let lg: CGFloat = 16
        public static let xl: CGFloat = 20
        public static let xxl: CGFloat = 24
    }
}

// MARK: - Restrained Apple Liquid Glass System

public enum CharkleGlassVariant: Sendable {
    case regular
    case clear
    case darkNotch
}

public struct CharkleGlassContainer<Content: View>: View {
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

public struct CharkleLiquidGlassModifier<S: InsettableShape>: ViewModifier {
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.colorScheme) private var colorScheme

    private let variant: CharkleGlassVariant
    private let shape: S
    private let tint: Color?
    private let interactive: Bool

    public init(
        variant: CharkleGlassVariant = .regular,
        shape: S,
        tint: Color? = nil,
        interactive: Bool = false
    ) {
        self.variant = variant
        self.shape = shape
        self.tint = tint
        self.interactive = interactive
    }

    public func body(content: Content) -> some View {
        if reduceTransparency {
            // Accessibility Reduce Transparency: crisp high-contrast solid surface
            let solidBg: Color = switch variant {
            case .darkNotch: Color(charkleHex: "#121316")
            case .regular, .clear: CharkleTheme.surfaceElevated(for: colorScheme)
            }
            let stroke: Color = variant == .darkNotch
                ? Color.white.opacity(0.16)
                : CharkleTheme.hairline(for: colorScheme)
            content
                .background(solidBg, in: shape)
                .overlay(shape.strokeBorder(stroke, lineWidth: 1))
                .shadow(color: Color.black.opacity(colorScheme == .dark ? 0.34 : 0.10), radius: 14, y: 6)
        } else if variant == .darkNotch {
            // Notch Shelf dark glass expansion capsule (calibrated against physical MacBook bezel;
            // gentle dual-layer shadow fully contained inside the oversized transparent NSPanel so it never clips).
            if #available(macOS 26, *) {
                let glass = Glass.regular.tint(Color(charkleHex: "#0B0C0F").opacity(0.88))
                content
                    .glassEffect(interactive ? glass.interactive() : glass, in: shape)
                    .overlay(
                        shape.strokeBorder(
                            LinearGradient(
                                colors: [Color.white.opacity(0.0), Color.white.opacity(0.14), Color.white.opacity(0.08)],
                                startPoint: .top,
                                endPoint: .bottom
                            ),
                            lineWidth: CharkleTheme.hairlineWidth
                        )
                    )
                    .shadow(color: Color.black.opacity(0.18), radius: 6, y: 2)
                    .shadow(color: Color.black.opacity(0.24), radius: 22, y: 10)
            } else {
                content
                    .background(Color(charkleHex: "#0E1014").opacity(0.92), in: shape)
                    .background(.ultraThinMaterial, in: shape)
                    .overlay(
                        shape.strokeBorder(
                            LinearGradient(
                                colors: [Color.white.opacity(0.02), Color.white.opacity(0.14), Color.white.opacity(0.08)],
                                startPoint: .top,
                                endPoint: .bottom
                            ),
                            lineWidth: CharkleTheme.hairlineWidth
                        )
                    )
                    .shadow(color: Color.black.opacity(0.22), radius: 6, y: 2)
                    .shadow(color: Color.black.opacity(0.28), radius: 22, y: 10)
            }
        } else if #available(macOS 26, *) {
            let base: Glass = variant == .clear ? .clear : .regular
            let tinted: Glass = tint != nil ? base.tint(tint) : base
            let finalGlass: Glass = interactive ? tinted.interactive() : tinted
            content
                .glassEffect(finalGlass, in: shape)
        } else {
            // Calibrated macOS 15 fallback with crisp specular rim highlight
            content
                .background(.ultraThinMaterial, in: shape)
                .overlay {
                    if let tint {
                        shape.fill(tint.opacity(0.08)).allowsHitTesting(false)
                    }
                }
                .overlay {
                    shape.strokeBorder(
                        LinearGradient(
                            colors: [
                                Color.white.opacity(colorScheme == .dark ? 0.24 : 0.85),
                                Color.white.opacity(colorScheme == .dark ? 0.05 : 0.24)
                            ],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        ),
                        lineWidth: CharkleTheme.hairlineWidth
                    )
                }
                .shadow(color: Color.black.opacity(colorScheme == .dark ? 0.36 : 0.10), radius: 16, y: 6)
        }
    }
}

public struct CharkleScrollEdgeModifier: ViewModifier {
    private let edges: Edge.Set

    public init(edges: Edge.Set = .top) {
        self.edges = edges
    }

    public func body(content: Content) -> some View {
        if #available(macOS 26, *) {
            content.scrollEdgeEffectStyle(.soft, for: edges)
        } else {
            content
        }
    }
}

public extension View {
    func charkleLiquidGlass<S: InsettableShape>(
        _ variant: CharkleGlassVariant = .regular,
        in shape: S,
        tint: Color? = nil,
        interactive: Bool = false
    ) -> some View {
        modifier(CharkleLiquidGlassModifier(variant: variant, shape: shape, tint: tint, interactive: interactive))
    }

    func charkleScrollEdgeSoft(for edges: Edge.Set = .top) -> some View {
        modifier(CharkleScrollEdgeModifier(edges: edges))
    }

    /// Forces the enclosing macOS `NSScrollView` into borderless `.overlay` scroller style
    /// (and optionally hides scrollers completely) so plugging in an external mouse or tablet
    /// never injects a legacy 15pt white rectangular scrollbar track into translucent surfaces.
    /// Apply directly to the inner content inside a SwiftUI `ScrollView`.
    func charkleCleanScrollbars(hidden: Bool = false) -> some View {
        background(CharkleOverlayScrollbarBridge(hideScrollers: hidden))
    }
}

// MARK: - Soft Edge-to-Edge Modal Backdrop

/// Calibrated full-window modal backdrop covering the hidden titlebar seamlessly without a top seam.
/// Uses a pure GPU-composited soft radial veil (avoiding full-window `NSVisualEffectView` opacity-fade stutter
/// while keeping light-mode gallery artwork luminous instead of muddy gray).
public struct CharkleModalBackdrop: View {
    @Environment(\.colorScheme) private var colorScheme
    private let onTap: (() -> Void)?

    public init(onTap: (() -> Void)? = nil) {
        self.onTap = onTap
    }

    public var body: some View {
        let centerAlpha: Double = colorScheme == .dark ? 0.34 : 0.075
        let edgeAlpha: Double = colorScheme == .dark ? 0.50 : 0.165
        let tint = Color(charkleHex: "#101216")

        RadialGradient(
            colors: [tint.opacity(centerAlpha), tint.opacity(edgeAlpha)],
            center: .center,
            startRadius: 80,
            endRadius: 900
        )
        .ignoresSafeArea(.all)
        .contentShape(Rectangle())
        .onTapGesture {
            onTap?()
        }
    }
}

// MARK: - Full-Bleed Native Window Chrome & Drag Area

/// Configures the host `NSWindow` for seamless edge-to-edge full-bleed content:
/// transparent titlebar, zero titlebar separator hairline, and `.fullSizeContentView`
/// so Sidebar, Center Workspace, and Inspector surfaces extend cleanly behind the traffic lights.
public struct CharkleWindowChromeBridge: NSViewRepresentable {
    public init() {}

    public func makeNSView(context: Context) -> ChromeBridgeNSView {
        ChromeBridgeNSView()
    }

    public func updateNSView(_ nsView: ChromeBridgeNSView, context: Context) {
        nsView.applyWindowChrome()
    }

    public final class ChromeBridgeNSView: NSView {
        public override func hitTest(_ point: NSPoint) -> NSView? {
            nil
        }

        public override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            applyWindowChrome()
        }

        func applyWindowChrome() {
            guard let window else { return }
            if window.titleVisibility != .hidden {
                window.titleVisibility = .hidden
            }
            if !window.titlebarAppearsTransparent {
                window.titlebarAppearsTransparent = true
            }
            if window.titlebarSeparatorStyle != .none {
                window.titlebarSeparatorStyle = .none
            }
            if !window.styleMask.contains(.fullSizeContentView) {
                window.styleMask.insert(.fullSizeContentView)
            }
        }
    }
}

/// Interactive empty top-bar drag handle allowing native window dragging and double-click zoom
/// inside full-bleed hidden-titlebar headers without enabling global `isMovableByWindowBackground`.
public struct CharkleWindowDragArea: NSViewRepresentable {
    public init() {}

    public func makeNSView(context: Context) -> WindowDragNSView {
        WindowDragNSView()
    }

    public func updateNSView(_ nsView: WindowDragNSView, context: Context) {}

    public final class WindowDragNSView: NSView {
        public override var mouseDownCanMoveWindow: Bool { true }

        public override func mouseDown(with event: NSEvent) {
            if event.clickCount == 2 {
                window?.performZoom(nil)
            } else {
                window?.performDrag(with: event)
            }
        }
    }
}

// MARK: - AppKit Overlay Scrollbar Enforcer (Zero Legacy Rectangular Track Box)

private struct CharkleOverlayScrollbarBridge: NSViewRepresentable {
    let hideScrollers: Bool

    func makeNSView(context: Context) -> ScrollbarEnforcerView {
        let view = ScrollbarEnforcerView()
        view.hideScrollers = hideScrollers
        return view
    }

    func updateNSView(_ nsView: ScrollbarEnforcerView, context: Context) {
        nsView.hideScrollers = hideScrollers
        nsView.applyToEnclosingScrollView()
    }

    final class ScrollbarEnforcerView: NSView {
        var hideScrollers: Bool = false
        private nonisolated(unsafe) var styleObserver: NSObjectProtocol?
        private weak var observedScrollView: NSScrollView?
        private var scrollerStyleKVO: NSKeyValueObservation?
        private var verticalScrollerKVO: NSKeyValueObservation?
        private var horizontalScrollerKVO: NSKeyValueObservation?

        override init(frame frameRect: NSRect) {
            super.init(frame: frameRect)
            styleObserver = NotificationCenter.default.addObserver(
                forName: NSScroller.preferredScrollerStyleDidChangeNotification,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                Task { @MainActor [weak self] in
                    self?.applyToEnclosingScrollView()
                }
            }
        }

        required init?(coder: NSCoder) {
            super.init(coder: coder)
        }

        deinit {
            if let styleObserver {
                NotificationCenter.default.removeObserver(styleObserver)
            }
        }

        override func hitTest(_ point: NSPoint) -> NSView? {
            nil
        }

        override func viewDidMoveToSuperview() {
            super.viewDidMoveToSuperview()
            scheduleApply()
        }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            scheduleApply()
        }

        private func scheduleApply() {
            applyToEnclosingScrollView()
            DispatchQueue.main.async { [weak self] in
                self?.applyToEnclosingScrollView()
            }
        }

        private func attachKVOIfNeeded(to scrollView: NSScrollView) {
            guard observedScrollView !== scrollView else { return }
            observedScrollView = scrollView

            scrollerStyleKVO = scrollView.observe(\.scrollerStyle, options: [.new]) { [weak self] sv, _ in
                MainActor.assumeIsolated {
                    guard self != nil else { return }
                    if sv.scrollerStyle != .overlay {
                        sv.scrollerStyle = .overlay
                    }
                    if !sv.autohidesScrollers {
                        sv.autohidesScrollers = true
                    }
                }
            }
            verticalScrollerKVO = scrollView.observe(\.hasVerticalScroller, options: [.new]) { [weak self] sv, _ in
                MainActor.assumeIsolated {
                    guard let self, self.hideScrollers else { return }
                    if sv.hasVerticalScroller {
                        sv.hasVerticalScroller = false
                    }
                    sv.verticalScroller?.isHidden = true
                    sv.verticalScroller?.alphaValue = 0
                }
            }
            horizontalScrollerKVO = scrollView.observe(\.hasHorizontalScroller, options: [.new]) { [weak self] sv, _ in
                MainActor.assumeIsolated {
                    guard let self, self.hideScrollers else { return }
                    if sv.hasHorizontalScroller {
                        sv.hasHorizontalScroller = false
                    }
                    sv.horizontalScroller?.isHidden = true
                    sv.horizontalScroller?.alphaValue = 0
                }
            }
        }

        func applyToEnclosingScrollView() {
            guard let scrollView = resolveScrollView() else { return }
            attachKVOIfNeeded(to: scrollView)
            if scrollView.scrollerStyle != .overlay {
                scrollView.scrollerStyle = .overlay
            }
            if !scrollView.autohidesScrollers {
                scrollView.autohidesScrollers = true
            }
            if scrollView.drawsBackground {
                scrollView.drawsBackground = false
            }
            if scrollView.borderType != .noBorder {
                scrollView.borderType = .noBorder
            }
            if hideScrollers {
                if scrollView.hasVerticalScroller {
                    scrollView.hasVerticalScroller = false
                }
                if scrollView.hasHorizontalScroller {
                    scrollView.hasHorizontalScroller = false
                }
                scrollView.verticalScroller?.isHidden = true
                scrollView.horizontalScroller?.isHidden = true
                scrollView.verticalScroller?.alphaValue = 0
                scrollView.horizontalScroller?.alphaValue = 0
            } else {
                if scrollView.verticalScroller?.scrollerStyle != .overlay {
                    scrollView.verticalScroller?.scrollerStyle = .overlay
                }
                if scrollView.horizontalScroller?.scrollerStyle != .overlay {
                    scrollView.horizontalScroller?.scrollerStyle = .overlay
                }
                scrollView.verticalScroller?.controlSize = .small
                scrollView.horizontalScroller?.controlSize = .small
            }
        }

        private func resolveScrollView() -> NSScrollView? {
            if let direct = enclosingScrollView {
                return direct
            }
            var cursor = superview
            while let current = cursor {
                if let sv = current as? NSScrollView {
                    return sv
                }
                cursor = current.superview
            }
            return nil
        }
    }
}

// MARK: - Wrapping Flow Layout (for Tags, AI Suggestions, gdirect Account & Endpoint Chips)

public nonisolated struct CharkleFlowLayout: Layout {
    public var spacing: CGFloat
    public var lineSpacing: CGFloat

    public init(spacing: CGFloat = 6, lineSpacing: CGFloat = 6) {
        self.spacing = spacing
        self.lineSpacing = lineSpacing
    }

    public func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let maxWidth = max(1, proposal.width ?? 600)
        var cursorX: CGFloat = 0
        var cursorY: CGFloat = 0
        var rowHeight: CGFloat = 0

        for view in subviews {
            let raw = view.sizeThatFits(ProposedViewSize(width: maxWidth, height: nil))
            let size = CGSize(width: min(raw.width, maxWidth), height: raw.height)
            if cursorX > 0 && cursorX + size.width > maxWidth {
                cursorX = 0
                cursorY += rowHeight + lineSpacing
                rowHeight = 0
            }
            cursorX += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
        return CGSize(width: maxWidth, height: cursorY + rowHeight)
    }

    public func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let maxWidth = max(1, bounds.width)
        var cursorX = bounds.minX
        var cursorY = bounds.minY
        var rowHeight: CGFloat = 0

        for view in subviews {
            let raw = view.sizeThatFits(ProposedViewSize(width: maxWidth, height: nil))
            let size = CGSize(width: min(raw.width, maxWidth), height: raw.height)
            if cursorX > bounds.minX && cursorX + size.width > bounds.maxX {
                cursorX = bounds.minX
                cursorY += rowHeight + lineSpacing
                rowHeight = 0
            }
            view.place(at: CGPoint(x: cursorX, y: cursorY), proposal: ProposedViewSize(size))
            cursorX += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
    }
}
