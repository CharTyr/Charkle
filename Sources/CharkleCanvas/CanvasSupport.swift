import AppKit
import CharkleCore
import SwiftUI

/// Module metadata for CharkleCanvas.
public struct CharkleCanvasModuleInfo: Sendable {
    public static let version = "1.5.1"
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

/// Pure, testable geometry bounds for the main workspace's resizable sidebar and right inspector drawers.
public nonisolated enum SidebarResizeGeometry {
    public static let collapsedWidth: CGFloat = 76
    public static let defaultWidth: CGFloat = 232
    public static let minWidth: CGFloat = 188
    public static let maxWidth: CGFloat = 420
    public static let defaultInspectorWidth: CGFloat = 300
    public static let minInspectorWidth: CGFloat = 260
    public static let maxInspectorWidth: CGFloat = 480
    public static let minCenterWorkspaceWidth: CGFloat = 360

    /// Clamps a requested expanded sidebar width to safe visual bounds (`188...420pt`) while guaranteeing
    /// the center workspace retains at least `minCenterWorkspaceWidth` when the window narrows.
    public static func clampedWidth(
        _ rawWidth: CGFloat,
        windowWidth: CGFloat? = nil,
        isInspectorVisible: Bool = false,
        inspectorWidth: CGFloat = defaultInspectorWidth
    ) -> CGFloat {
        guard rawWidth.isFinite else { return defaultWidth }
        let upperBound: CGFloat
        if let windowWidth, windowWidth.isFinite, windowWidth > 0 {
            let safeInspector = inspectorWidth.isFinite ? min(maxInspectorWidth, max(minInspectorWidth, inspectorWidth)) : defaultInspectorWidth
            let inspectorReserve: CGFloat = isInspectorVisible ? (safeInspector + 1) : 0
            let availableForSidebar = windowWidth - inspectorReserve - minCenterWorkspaceWidth - 1
            upperBound = max(minWidth, min(maxWidth, availableForSidebar))
        } else {
            upperBound = maxWidth
        }
        return round(min(upperBound, max(minWidth, rawWidth)))
    }

    /// Clamps a requested right Inspector width to safe visual bounds (`260...480pt`) while guaranteeing
    /// the center workspace or Quick Look stage retains at least `minCenterWorkspaceWidth`.
    public static func clampedInspectorWidth(
        _ rawWidth: CGFloat,
        windowWidth: CGFloat? = nil,
        sidebarOccupiedWidth: CGFloat = 0
    ) -> CGFloat {
        guard rawWidth.isFinite else { return defaultInspectorWidth }
        let upperBound: CGFloat
        if let windowWidth, windowWidth.isFinite, windowWidth > 0 {
            let safeSidebar = sidebarOccupiedWidth.isFinite ? max(0, sidebarOccupiedWidth) : 0
            let availableForInspector = windowWidth - safeSidebar - minCenterWorkspaceWidth - 1
            upperBound = max(minInspectorWidth, min(maxInspectorWidth, availableForInspector))
        } else {
            upperBound = maxInspectorWidth
        }
        return round(min(upperBound, max(minInspectorWidth, rawWidth)))
    }
}

/// Timestamped global pointer sample recorded during an active drag session
/// to estimate upward approach velocity toward the top-center Notch Shelf.
public nonisolated struct NotchDragMotionSample: Equatable, Sendable {
    public let location: NSPoint
    public let timestamp: TimeInterval

    public init(location: NSPoint, timestamp: TimeInterval) {
        self.location = location
        self.timestamp = timestamp
    }
}

/// Minimal window-server descriptor used to detect active macOS Mission Control overlays
/// independently of system UI localization.
public nonisolated struct NotchDockWindowSnapshot: Equatable, Sendable {
    public let layer: Int
    public let sharingState: Int
    public let bounds: CGRect

    public init(layer: Int, sharingState: Int, bounds: CGRect) {
        self.layer = layer
        self.sharingState = sharingState
        self.bounds = bounds
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
    /// while dragging an external payload. Extends comfortably below the menu bar so users never collide with
    /// macOS Mission Control / Spaces top-edge triggers, while actual drop acceptance stays strictly inside
    /// `strictCardRect` (never leaking into underlying apps).
    public static func isPointInDragTriggerZone(
        _ screenPoint: NSPoint,
        screenFrame: NSRect,
        hasPhysicalNotch: Bool,
        notchWidth: CGFloat,
        notchHeight: CGFloat
    ) -> Bool {
        let triggerHeight: CGFloat = hasPhysicalNotch ? (max(notchHeight, 34) + 52) : 76
        let halfSpan: CGFloat = hasPhysicalNotch ? (notchWidth / 2.0 + 76) : 176
        return screenPoint.y >= screenFrame.maxY - triggerHeight
            && screenPoint.y <= screenFrame.maxY
            && abs(screenPoint.x - screenFrame.midX) <= halfSpan
    }

    /// Estimates recent `(vx, vy)` pointer velocity in points/second from recent drag motion samples.
    /// Returns `.zero` when fewer than two valid samples exist or after a pause.
    public static func recentDragVelocity(from samples: [NotchDragMotionSample]) -> CGVector {
        guard let latest = samples.last, samples.count >= 2 else { return .zero }
        let targetLookback = latest.timestamp - 0.14
        let minDeltaT: TimeInterval = 0.008
        let maxDeltaT: TimeInterval = 0.35

        var anchor: NotchDragMotionSample?
        for sample in samples.dropLast().reversed() {
            let dt = latest.timestamp - sample.timestamp
            if dt < minDeltaT { continue }
            if dt > maxDeltaT { break }
            anchor = sample
            if sample.timestamp <= targetLookback {
                break
            }
        }
        guard let anchor else { return .zero }
        let dt = latest.timestamp - anchor.timestamp
        guard dt >= minDeltaT else { return .zero }
        return CGVector(
            dx: (latest.location.x - anchor.location.x) / dt,
            dy: (latest.location.y - anchor.location.y) / dt
        )
    }

    /// Predicts whether an active external drag is intentionally heading upward toward the top-center
    /// Notch Shelf so the shelf unfurls early well below the menu bar — giving natural visual braking
    /// room and preventing the pointer from colliding with macOS top-edge Mission Control triggers.
    ///
    /// Three layered tiers ensure zero false opens during normal Finder/browser/canvas work:
    /// 1. Direct top-center arrival band (`~89pt` notch / `76pt` non-notch), suppressed if dragging steeply downward from start.
    /// 2. Slow upward arrival band (`~151pt` notch / `136pt` non-notch) once the pointer climbs deliberately upward from below.
    /// 3. Fast upward ballistic intercept (`~314-350pt` upper corridor) when sustained upward velocity projects directly
    ///    into the top-center notch zone within human reaction + spring unfurl lead time (`~260ms`).
    public static func shouldTriggerUpwardDragApproach(
        currentLocation: NSPoint,
        dragStartLocation: NSPoint,
        recentSamples: [NotchDragMotionSample],
        screenFrame: NSRect,
        hasPhysicalNotch: Bool,
        notchWidth: CGFloat,
        notchHeight: CGFloat
    ) -> Bool {
        guard screenFrame.width > 0, screenFrame.height > 0 else { return false }
        guard currentLocation.y <= screenFrame.maxY else { return false }

        let staticTriggerHeight: CGFloat = hasPhysicalNotch ? (max(notchHeight, 34) + 52) : 76
        let staticHalfSpan: CGFloat = hasPhysicalNotch ? (notchWidth / 2.0 + 76) : 176
        let totalUpwardTravel = currentLocation.y - dragStartLocation.y

        // Tier 1: Direct top-center arrival band (suppressed if clearly dragging downward away from the top bar).
        if isPointInDragTriggerZone(
            currentLocation,
            screenFrame: screenFrame,
            hasPhysicalNotch: hasPhysicalNotch,
            notchWidth: notchWidth,
            notchHeight: notchHeight
        ) {
            return totalUpwardTravel > -14
        }

        // Remaining tiers strictly require genuine upward travel from where the drag started.
        guard totalUpwardTravel >= 24 else { return false }

        let fastCorridorHeight = min(max(screenFrame.height * 0.32, 260), 350)
        let fastCorridorHalfSpan = min(max(notchWidth / 2.0 + 220, 320), screenFrame.width * 0.34)
        guard currentLocation.y >= screenFrame.maxY - fastCorridorHeight,
              abs(currentLocation.x - screenFrame.midX) <= fastCorridorHalfSpan else {
            return false
        }

        let velocity = recentDragVelocity(from: recentSamples)
        guard velocity.dy > 0 else { return false }

        // Tier 2: Deliberate slow-to-medium upward approach well below the menu bar (~110pt clearance).
        let slowUpwardHeight: CGFloat = hasPhysicalNotch ? (max(notchHeight, 34) + 114) : 136
        let slowUpwardHalfSpan: CGFloat = max(staticHalfSpan + 42, 220)
        if currentLocation.y >= screenFrame.maxY - slowUpwardHeight,
           abs(currentLocation.x - screenFrame.midX) <= slowUpwardHalfSpan,
           velocity.dy >= 25,
           velocity.dy >= abs(velocity.dx) * 0.50 {
            return true
        }

        // Tier 3: Brisk/fast upward trajectory projecting into the notch zone within reaction + spring lead time.
        guard totalUpwardTravel >= 36,
              velocity.dy >= 240,
              velocity.dy >= abs(velocity.dx) * 0.65 else {
            return false
        }

        let leadTime: CGFloat = 0.26
        let projectedY = currentLocation.y + velocity.dy * leadTime
        let projectedX = currentLocation.x + velocity.dx * leadTime
        let projectedHalfSpan = max(staticHalfSpan + 110, 290)
        return projectedY >= screenFrame.maxY - staticTriggerHeight
            && abs(projectedX - screenFrame.midX) <= projectedHalfSpan
    }

    /// Detects whether any on-screen `com.apple.dock` window matches the macOS Mission Control overlay
    /// (`layer == 18`, non-shared, substantial screen-sized bounds; normal idle Dock windows live on `layer == 20`).
    public static func containsMissionControlOverlay(
        dockWindows: [NotchDockWindowSnapshot]
    ) -> Bool {
        dockWindows.contains { window in
            window.layer == 18
                && window.sharingState == 0
                && window.bounds.width >= 200
                && window.bounds.height >= 200
        }
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

/// Zero-allocation 6-digit RGB hex parser operating directly on UTF-8 bytes
/// (avoids Foundation `CharacterSet` bridging and intermediate `String` copies in 120Hz hot paths).
internal nonisolated enum CanvasHexParser {
    @inline(__always)
    private static func hexNibble(_ byte: UInt8) -> UInt8? {
        switch byte {
        case 48...57: return byte - 48        // '0'...'9'
        case 65...70: return byte - 55        // 'A'...'F'
        case 97...102: return byte - 87       // 'a'...'f'
        default: return nil
        }
    }

    static func parseRGB(_ hex: String) -> (r: UInt8, g: UInt8, b: UInt8)? {
        var value: UInt32 = 0
        var digits = 0
        var started = false
        var trailingWhitespace = false
        for byte in hex.utf8 {
            if byte == 35 { // '#'
                if trailingWhitespace { return nil }
                continue
            }
            if byte == 32 || byte == 9 || byte == 10 || byte == 13 {
                if started { trailingWhitespace = true }
                continue
            }
            if trailingWhitespace { return nil }
            guard let nibble = hexNibble(byte), digits < 6 else { return nil }
            started = true
            value = (value << 4) | UInt32(nibble)
            digits += 1
        }
        guard digits == 6 else { return nil }
        return (
            r: UInt8((value >> 16) & 0xFF),
            g: UInt8((value >> 8) & 0xFF),
            b: UInt8(value & 0xFF)
        )
    }
}

public extension NSColor {
    nonisolated static func charkleHex(_ hex: String, fallback: NSColor = .systemGray) -> NSColor {
        guard let rgb = CanvasHexParser.parseRGB(hex) else {
            return fallback
        }
        return NSColor(
            srgbRed: CGFloat(rgb.r) / 255.0,
            green: CGFloat(rgb.g) / 255.0,
            blue: CGFloat(rgb.b) / 255.0,
            alpha: 1.0
        )
    }
}

public extension Color {
    nonisolated init(charkleHex hex: String) {
        guard let rgb = CanvasHexParser.parseRGB(hex) else {
            self.init(red: 0.52, green: 0.54, blue: 0.56)
            return
        }
        self.init(
            .sRGB,
            red: Double(rgb.r) / 255.0,
            green: Double(rgb.g) / 255.0,
            blue: Double(rgb.b) / 255.0,
            opacity: 1.0
        )
    }

    /// Relative luminance for picking crisp contrasting ink over swatches.
    nonisolated static func charkleIsLightHex(_ hex: String) -> Bool {
        guard let rgb = CanvasHexParser.parseRGB(hex) else { return false }
        let r = Double(rgb.r) / 255.0
        let g = Double(rgb.g) / 255.0
        let b = Double(rgb.b) / 255.0
        let luminance = 0.299 * r + 0.587 * g + 0.114 * b
        return luminance > 0.62
    }
}

// MARK: - Gallery-First Neutral Canvas Surfaces & Restrained Liquid Glass

/// Canonical 4-step studio typography scale inside `CharkleCanvas`, mirroring `CharkleTextStyle`.
public nonisolated enum CanvasTextStyle: CGFloat, CaseIterable, Hashable, Sendable {
    case caption = 12
    case body = 13
    case headline = 16
    case title = 20
}

public enum CanvasSurface {
    /// Standard Retina 1px hairline border/divider thickness (`0.5pt`), mirroring `CharkleTheme.hairlineWidth`.
    public nonisolated static let hairlineWidth: CGFloat = 0.5

    /// Canonical 4-step studio typography helper (`12 / 13 / 16 / 20pt`).
    public nonisolated static func text(
        _ style: CanvasTextStyle,
        weight: Font.Weight = .regular,
        design: Font.Design = .default
    ) -> Font {
        .system(size: style.rawValue, weight: weight, design: design)
    }

    /// Continuous concentric corner tokens matching `CharkleTheme.Radius`.
    public nonisolated enum Radius {
        public static let xs: CGFloat = 4
        public static let sm: CGFloat = 6
        public static let chip: CGFloat = 8
        public static let popoverInner: CGFloat = 10
        public static let cardOuter: CGFloat = 12
        public static let settingsOuter: CGFloat = 14
        public static let popoverOuter: CGFloat = 16
        public static let dockOuter: CGFloat = 20

        public static func concentricInner(outer: CGFloat, padding: CGFloat) -> CGFloat {
            max(4, outer - padding)
        }
    }

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

/// Clean SwiftUI trigger button style paired with `.menuStyle(.button)` + `.menuIndicator(.hidden)`
/// inside `CharkleCanvas` so floating canvas menus preserve their custom capsule styling without
/// AppKit borderless popup tinting or dangling chevrons.
public struct CanvasMenuTriggerButtonStyle: ButtonStyle {
    public init() {}

    public func makeBody(configuration: Configuration) -> some View {
        TriggerBody(configuration: configuration)
    }

    private struct TriggerBody: View {
        @Environment(\.accessibilityReduceMotion) private var reduceMotion
        @Environment(\.isEnabled) private var isEnabled

        let configuration: Configuration

        var body: some View {
            let pressed = configuration.isPressed && isEnabled
            configuration.label
                .opacity(isEnabled ? (pressed ? 0.76 : 1.0) : 0.42)
                .scaleEffect(pressed && !reduceMotion ? 0.98 : 1.0)
                .contentShape(Rectangle())
                .animation(CanvasMotion.accessible(CanvasMotion.hoverPress, reduced: reduceMotion), value: pressed)
        }
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
                        lineWidth: CanvasSurface.hairlineWidth
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
            guard let hostWindow = self.window,
                  event.window === hostWindow,
                  hostWindow.attachedSheet == nil,
                  NSApp?.modalWindow == nil,
                  !isHiddenOrHasHiddenAncestor else {
                return event
            }
            // Respect Cmd-zoom shortcuts and native horizontal trackpad swipes / Shift-scroll
            let flags = event.modifierFlags.intersection([.command, .option, .control, .shift])
            if flags.contains(.command) || flags.contains(.control) {
                return event
            }
            let dy = event.scrollingDeltaY
            let dx = event.scrollingDeltaX
            guard abs(dy) > abs(dx), abs(dy) > 0.01 else {
                return event
            }

            guard bounds.width > 0, bounds.height > 0 else {
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
                return event
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
            guard let hitView = window?.contentView?.hitTest(eventLocationInWindow) else {
                return nil
            }
            if let enclosing = enclosingScrollView {
                return hitView.isDescendant(of: enclosing) ? enclosing : nil
            }

            // Walk upward from the actual topmost hit-tested view so overlays (Quick Look, modals,
            // sheets, popovers) covering this horizontal strip never have their scroll events stolen.
            let selfRectInWindow = convert(bounds, to: nil)
            var cursor: NSView? = hitView
            while let view = cursor {
                if let sv = view as? NSScrollView {
                    let svRect = sv.convert(sv.bounds, to: nil)
                    let matchesStripHeight = abs(svRect.height - selfRectInWindow.height) <= 16
                        && abs(svRect.minY - selfRectInWindow.minY) <= 16
                    return matchesStripHeight ? sv : nil
                }
                cursor = view.superview
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
                    guard let self,
                          let hostWindow = self.window,
                          !self.isHiddenOrHasHiddenAncestor,
                          hostWindow.attachedSheet == nil,
                          NSApp?.modalWindow == nil else {
                        return event
                    }
                    let sameWindow = (event.window === hostWindow) || (event.window?.parent === hostWindow)
                    guard sameWindow else { return event }
                    // IMPORTANT: Unwrap `onKeyDown` explicitly rather than using `onKeyDown?(event) ?? event` —
                    // Swift optional chaining flattens `((NSEvent) -> NSEvent?)?`, which would silently turn
                    // an intentional `nil` return (event consumed!) back into `event`.
                    if let onKeyDown = self.onKeyDown {
                        return onKeyDown(event)
                    }
                    return event
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
                  NSApp?.modalWindow == nil,
                  !isHiddenOrHasHiddenAncestor else {
                return event
            }
            guard bounds.width > 0, bounds.height > 0 else {
                return event
            }
            let localPoint = convert(event.locationInWindow, from: nil)
            guard bounds.contains(localPoint) else {
                return event
            }
            let dy = event.scrollingDeltaY
            let dx = event.scrollingDeltaX
            // Let horizontal trackpad swipes pass through instead of accidentally zooming on slight vertical wobble
            guard abs(dy) > 0.01, abs(dy) >= abs(dx) else { return event }
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
                // IMPORTANT: Unwrap `onKeyDown` explicitly; `onKeyDown?(...) ?? event` would turn a
                // consumed `nil` result back into `event`, causing Spacebar Quick Look to immediately re-open.
                if let onKeyDown = self.onKeyDown {
                    return onKeyDown(event, hostWindow)
                }
                return event
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
        return secs < 10 ? "\(mins):0\(secs)" : "\(mins):\(secs)"
    }

    public static func fileExtensionBadge(for fileName: String) -> String {
        // Direct last-path-component substring scan avoids allocating a Foundation `URL` per card
        var trimmed = fileName[...]
        while trimmed.last == "/" {
            trimmed = trimmed.dropLast()
        }
        let baseName: Substring
        if let slash = trimmed.lastIndex(of: "/") {
            baseName = trimmed[trimmed.index(after: slash)...]
        } else {
            baseName = trimmed
        }
        guard let dot = baseName.lastIndex(of: "."), dot > baseName.startIndex else {
            return "FILE"
        }
        let extSlice = baseName[baseName.index(after: dot)...]
        guard !extSlice.isEmpty else { return "FILE" }
        return String(extSlice.prefix(6)).uppercased()
    }

    /// Safely decodes up to `maxBytes` of UTF-8 text without returning `nil` or emitting a trailing
    /// replacement glyph when the byte budget lands mid-sequence in multi-byte CJK/emoji text.
    public nonisolated static func decodeUTF8Prefix(_ data: Data, maxBytes: Int = 262_144) -> String {
        guard maxBytes > 0, !data.isEmpty else { return "" }
        if data.count <= maxBytes {
            return String(decoding: data, as: UTF8.self)
        }
        var end = maxBytes
        var back = 0
        while end > 0 && back < 4 && (data[data.index(data.startIndex, offsetBy: end - 1)] & 0xC0) == 0x80 {
            end -= 1
            back += 1
        }
        var cutEnd = maxBytes
        if end > 0 {
            let lead = data[data.index(data.startIndex, offsetBy: end - 1)]
            let expectedLen: Int
            if (lead & 0x80) == 0 {
                expectedLen = 1
            } else if (lead & 0xE0) == 0xC0 {
                expectedLen = 2
            } else if (lead & 0xF0) == 0xE0 {
                expectedLen = 3
            } else if (lead & 0xF8) == 0xF0 {
                expectedLen = 4
            } else {
                expectedLen = 1
            }
            if (end - 1) + expectedLen > maxBytes {
                cutEnd = end - 1
            }
        }
        return String(decoding: data.prefix(cutEnd), as: UTF8.self)
    }
}
