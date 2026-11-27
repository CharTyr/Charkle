import AppKit
import CharkleCanvas
import CharkleCore
import SwiftUI

// MARK: - Unified macOS Native Button Family

public nonisolated enum CharkleButtonVariant: String, CaseIterable, Hashable, Sendable {
    case accent
    case standard
    case subtle
    case destructive
}

public nonisolated enum CharkleButtonSize: String, CaseIterable, Hashable, Sendable {
    /// Compact 24pt height control (inline chips, popconfirm actions, dense inspector actions).
    case xs
    /// Standard 28pt macOS control height (settings rows, inspector actions, toolbar controls).
    case sm
    /// Prominent 32pt primary CTA height (dialogs, onboarding, empty states).
    case md
    /// Square icon-only control (28x28 default, configurable to 30x30 via `iconDimension`).
    case icon
}

/// Unified macOS native button style converging all application buttons onto four clean variants
/// (`.accent`, `.standard`, `.subtle`, `.destructive`) and a deterministic height ladder
/// (`24pt`, `28pt`, `32pt`, `28x28 / 30x30`).
///
/// All `@Environment` reads live inside the returned body view so forwarding wrappers
/// (such as legacy aliases or settings styles) receive live theme, accent, and accessibility state.
public struct CharkleButtonStyle: ButtonStyle {
    public let variant: CharkleButtonVariant
    public let size: CharkleButtonSize
    public let fullWidth: Bool
    public let cornerRadius: CGFloat?
    public let iconDimension: CGFloat

    public init(
        _ variant: CharkleButtonVariant = .standard,
        size: CharkleButtonSize = .sm,
        fullWidth: Bool = false,
        cornerRadius: CGFloat? = nil,
        iconDimension: CGFloat = 28
    ) {
        self.variant = variant
        self.size = size
        self.fullWidth = fullWidth
        self.cornerRadius = cornerRadius
        self.iconDimension = iconDimension
    }

    public func makeBody(configuration: Configuration) -> some View {
        StyledButtonBody(
            configuration: configuration,
            variant: variant,
            size: size,
            fullWidth: fullWidth,
            cornerRadius: cornerRadius,
            iconDimension: iconDimension
        )
    }

    private struct StyledButtonBody: View {
        @Environment(\.colorScheme) private var colorScheme
        @Environment(\.charkleAccentSource) private var accentSource
        @Environment(\.accessibilityReduceMotion) private var reduceMotion
        @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
        @Environment(\.isEnabled) private var isEnabled

        let configuration: Configuration
        let variant: CharkleButtonVariant
        let size: CharkleButtonSize
        let fullWidth: Bool
        let cornerRadius: CGFloat?
        let iconDimension: CGFloat

        @State private var isHovered: Bool = false

        private var resolvedRadius: CGFloat {
            cornerRadius ?? CharkleTheme.Radius.chip
        }

        private var fontWeight: Font.Weight {
            switch variant {
            case .accent: .semibold
            case .standard, .subtle, .destructive: .medium
            }
        }

        private var font: Font {
            switch size {
            case .xs: CharkleTheme.text(.caption, weight: fontWeight)
            case .sm, .md: CharkleTheme.text(.body, weight: fontWeight)
            case .icon: CharkleTheme.text(.body, weight: .medium)
            }
        }

        private var controlHeight: CGFloat {
            switch size {
            case .xs: 24
            case .sm: 28
            case .md: 32
            case .icon: iconDimension
            }
        }

        private var horizontalPadding: CGFloat {
            switch size {
            case .xs: 9
            case .sm: 12
            case .md: 15
            case .icon: 0
            }
        }

        var body: some View {
            let pressed = configuration.isPressed && isEnabled
            let hovered = isHovered && isEnabled
            let shape = RoundedRectangle(cornerRadius: resolvedRadius, style: .continuous)

            configuration.label
                .font(font)
                .foregroundStyle(foregroundColor(hovered: hovered))
                .padding(.horizontal, horizontalPadding)
                .frame(
                    minWidth: size == .icon ? iconDimension : nil,
                    maxWidth: fullWidth ? .infinity : (size == .icon ? iconDimension : nil),
                    minHeight: controlHeight,
                    maxHeight: size == .icon ? iconDimension : nil
                )
                .background(backgroundFill(pressed: pressed, hovered: hovered), in: shape)
                .overlay {
                    if let overlayTint = interactionOverlay(pressed: pressed, hovered: hovered) {
                        shape.fill(overlayTint).allowsHitTesting(false)
                    }
                }
                .overlay {
                    if let stroke = borderStroke(hovered: hovered) {
                        shape
                            .strokeBorder(stroke.color, lineWidth: stroke.width)
                            .allowsHitTesting(false)
                    }
                }
                .shadow(
                    color: contactShadowColor(pressed: pressed),
                    radius: pressed ? 0.5 : 1.0,
                    y: pressed ? 0 : 0.5
                )
                .scaleEffect(pressed && !reduceMotion ? 0.975 : 1.0)
                .opacity(isEnabled ? 1.0 : 0.42)
                .contentShape(shape)
                .onHover { hovering in
                    isHovered = hovering
                }
                .animation(CharkleMotion.accessible(CharkleMotion.hoverPress, reduced: reduceMotion), value: pressed)
                .animation(CharkleMotion.accessible(CharkleMotion.hoverPress, reduced: reduceMotion), value: hovered)
        }

        private func foregroundColor(hovered: Bool) -> Color {
            switch variant {
            case .accent:
                CharkleTheme.accentButtonForeground(for: colorScheme, source: accentSource)
            case .standard:
                Color.primary.opacity(0.92)
            case .subtle:
                Color.primary.opacity(hovered ? 0.96 : 0.80)
            case .destructive:
                CharkleTheme.destructive(for: colorScheme)
            }
        }

        private func backgroundFill(pressed: Bool, hovered: Bool) -> Color {
            switch variant {
            case .accent:
                return CharkleTheme.accentButtonFill(for: colorScheme, source: accentSource)
            case .standard:
                if colorScheme == .dark {
                    if reduceTransparency {
                        return pressed
                            ? Color(charkleHex: "#323640")
                            : (hovered ? Color(charkleHex: "#2C3039") : Color(charkleHex: "#252830"))
                    }
                    return Color.white.opacity(pressed ? 0.15 : (hovered ? 0.11 : 0.075))
                } else {
                    if reduceTransparency {
                        return pressed
                            ? Color(charkleHex: "#EAE9E5")
                            : (hovered ? Color(charkleHex: "#F5F4F1") : CharkleTheme.surfaceElevated(for: .light))
                    }
                    return pressed
                        ? Color(charkleHex: "#ECEBE7")
                        : (hovered ? Color(charkleHex: "#F8F8F6") : CharkleTheme.surfaceElevated(for: .light))
                }
            case .subtle:
                guard pressed || hovered else { return .clear }
                if reduceTransparency {
                    return pressed
                        ? CharkleTheme.surfaceSubtle(for: colorScheme)
                        : CharkleTheme.surfaceElevated(for: colorScheme)
                }
                if colorScheme == .dark {
                    return Color.white.opacity(pressed ? 0.13 : 0.08)
                } else {
                    return Color.black.opacity(pressed ? 0.095 : 0.055)
                }
            case .destructive:
                let ink = CharkleTheme.destructive(for: colorScheme)
                if reduceTransparency {
                    return ink.opacity(pressed ? 0.24 : (hovered ? 0.18 : 0.13))
                }
                return ink.opacity(pressed ? 0.19 : (hovered ? 0.13 : 0.08))
            }
        }

        private func interactionOverlay(pressed: Bool, hovered: Bool) -> Color? {
            guard variant == .accent else { return nil }
            if pressed {
                return Color.black.opacity(0.14)
            }
            if hovered {
                return Color.white.opacity(colorScheme == .dark ? 0.08 : 0.07)
            }
            return nil
        }

        private func borderStroke(hovered: Bool) -> (color: Color, width: CGFloat)? {
            let hairline = CharkleTheme.hairlineWidth
            switch variant {
            case .accent:
                if reduceTransparency {
                    return (
                        colorScheme == .dark ? Color.white.opacity(0.24) : Color.black.opacity(0.20),
                        1.0
                    )
                }
                return (Color.white.opacity(colorScheme == .dark ? 0.14 : 0.10), hairline)
            case .standard:
                if reduceTransparency {
                    return (
                        colorScheme == .dark ? Color.white.opacity(0.22) : Color.black.opacity(0.18),
                        1.0
                    )
                }
                let opacity: Double = colorScheme == .dark
                    ? (hovered ? 0.16 : 0.12)
                    : (hovered ? 0.15 : 0.11)
                return (Color.primary.opacity(opacity), hairline)
            case .subtle:
                if reduceTransparency && hovered {
                    return (CharkleTheme.hairline(for: colorScheme), 1.0)
                }
                return nil
            case .destructive:
                let ink = CharkleTheme.destructive(for: colorScheme)
                let opacity: Double = reduceTransparency ? 0.45 : (hovered ? 0.34 : 0.22)
                return (ink.opacity(opacity), reduceTransparency ? 1.0 : hairline)
            }
        }

        private func contactShadowColor(pressed: Bool) -> Color {
            guard variant == .standard, colorScheme == .light, !reduceTransparency else { return .clear }
            return Color.black.opacity(pressed ? 0.02 : 0.05)
        }
    }
}

public extension ButtonStyle where Self == CharkleButtonStyle {
    static func charkle(
        _ variant: CharkleButtonVariant = .standard,
        size: CharkleButtonSize = .sm,
        fullWidth: Bool = false,
        cornerRadius: CGFloat? = nil,
        iconDimension: CGFloat = 28
    ) -> CharkleButtonStyle {
        CharkleButtonStyle(
            variant,
            size: size,
            fullWidth: fullWidth,
            cornerRadius: cornerRadius,
            iconDimension: iconDimension
        )
    }
}

// MARK: - Unified macOS Native Menu Trigger & Dropdown Indicator

/// Clean SwiftUI button style paired with `.menuStyle(.button)` + `.menuIndicator(.hidden)`
/// for icon-only, pill, capsule, and inline `Menu` triggers.
///
/// Using `.menuStyle(.button)` + `CharkleMenuTriggerButtonStyle()` avoids AppKit's legacy
/// `BorderlessButtonMenuStyle` (`NSPopUpButton`) hijack on macOS 15–27+, which otherwise
/// strips custom pill backgrounds, forces accent-blue tint onto neutral labels, and leaks a
/// dangling system downward chevron (`⌄`).
public struct CharkleMenuTriggerButtonStyle: ButtonStyle {
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
                .animation(CharkleMotion.accessible(CharkleMotion.hoverPress, reduced: reduceMotion), value: pressed)
        }
    }
}

/// Canonical macOS pop-up / dropdown selector indicator (`chevron.up.chevron.down`).
/// Sits snugly beside label text rather than floating across an empty wide button gap
/// or using a lone thin downward chevron (`chevron.down`).
public struct CharkleDropdownChevron: View {
    @Environment(\.colorScheme) private var colorScheme

    public let size: CGFloat
    public let color: Color?

    public init(size: CGFloat = 8.5, color: Color? = nil) {
        self.size = size
        self.color = color
    }

    public var body: some View {
        Image(systemName: "chevron.up.chevron.down")
            .font(.system(size: size, weight: .semibold))
            .foregroundStyle(color ?? CharkleTheme.secondaryInk(for: colorScheme))
            .accessibilityHidden(true)
    }
}

// MARK: - Segmented Control (Shared-Geometry Sliding Thumb, Zero Pill-in-Pill Clutter)

public nonisolated enum CharkleSegmentedSize: String, CaseIterable, Hashable, Sendable {
    /// 26pt outer track height (compact toolbar & dense controls).
    case compact
    /// 30pt outer track height (Inspector switcher & Settings controls).
    case regular
}

/// Crisp 2–4 option macOS segmented switcher with a shared-geometry sliding thumb
/// (`CharkleMotion.moveOnScreen`), SF Symbol dual-state (`.symbolVariant(.fill)`),
/// optional tabular count badges, and Light/Dark + Reduce Motion/Transparency calibration.
public struct CharkleSegmentedControl<Option: Hashable>: View {
    public struct Item: Identifiable {
        public let value: Option
        public let title: String?
        public let systemImage: String?
        public let badge: String?
        public let helpText: String?

        public var id: Option { value }

        public init(
            _ value: Option,
            title: String? = nil,
            systemImage: String? = nil,
            badge: String? = nil,
            helpText: String? = nil
        ) {
            self.value = value
            self.title = title
            self.systemImage = systemImage
            self.badge = badge
            self.helpText = helpText
        }
    }

    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.charkleAccentSource) private var accentSource
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    @Binding public var selection: Option
    public let items: [Item]
    public let size: CharkleSegmentedSize
    public let fullWidth: Bool
    public let useAccentForSelected: Bool
    public let onSelect: ((Option) -> Void)?

    @Namespace private var thumbNamespace
    @State private var hoveredOption: Option? = nil

    public init(
        selection: Binding<Option>,
        items: [Item],
        size: CharkleSegmentedSize = .regular,
        fullWidth: Bool = true,
        useAccentForSelected: Bool = false,
        onSelect: ((Option) -> Void)? = nil
    ) {
        self._selection = selection
        self.items = items
        self.size = size
        self.fullWidth = fullWidth
        self.useAccentForSelected = useAccentForSelected
        self.onSelect = onSelect
    }

    public init(
        selection: Binding<Option>,
        options: [Option],
        size: CharkleSegmentedSize = .regular,
        fullWidth: Bool = true,
        useAccentForSelected: Bool = false,
        title: (Option) -> String? = { _ in nil },
        systemImage: (Option) -> String? = { _ in nil },
        badge: (Option) -> String? = { _ in nil },
        helpText: (Option) -> String? = { _ in nil },
        onSelect: ((Option) -> Void)? = nil
    ) {
        self._selection = selection
        self.items = options.map { option in
            Item(
                option,
                title: title(option),
                systemImage: systemImage(option),
                badge: badge(option),
                helpText: helpText(option)
            )
        }
        self.size = size
        self.fullWidth = fullWidth
        self.useAccentForSelected = useAccentForSelected
        self.onSelect = onSelect
    }

    private var outerRadius: CGFloat {
        size == .compact ? CharkleTheme.Radius.chip : CharkleTheme.Radius.popoverInner
    }

    private var trackPadding: CGFloat { 2 }

    private var innerRadius: CGFloat {
        CharkleTheme.Radius.concentricInner(outer: outerRadius, padding: trackPadding)
    }

    private var segmentHeight: CGFloat {
        size == .compact ? 22 : 26
    }

    public var body: some View {
        let trackShape = RoundedRectangle(cornerRadius: outerRadius, style: .continuous)
        let accent = CharkleTheme.accent(for: colorScheme, source: accentSource)

        HStack(spacing: 2) {
            ForEach(items) { item in
                let isSelected = selection == item.value
                let isHovered = hoveredOption == item.value
                let isIconOnly = item.title == nil && item.badge == nil

                Button {
                    guard selection != item.value else { return }
                    withAnimation(CharkleMotion.accessible(CharkleMotion.moveOnScreen, reduced: reduceMotion)) {
                        selection = item.value
                    }
                    onSelect?(item.value)
                } label: {
                    HStack(spacing: 4) {
                        if let systemImage = item.systemImage {
                            Image(systemName: systemImage)
                                .font(.system(size: size == .compact ? 12 : 12.5, weight: isSelected ? .semibold : .medium))
                                .symbolVariant(isSelected ? .fill : .none)
                        }

                        if let title = item.title {
                            Text(title)
                                .font(CharkleTheme.text(.caption, weight: isSelected ? .semibold : .medium))
                                .lineLimit(1)
                        }

                        if let badge = item.badge, !badge.isEmpty {
                            Text(badge)
                                .font(CharkleTheme.text(.caption, weight: .semibold, design: .rounded))
                                .monospacedDigit()
                                .foregroundStyle(isSelected ? accent : CharkleTheme.secondaryInk(for: colorScheme))
                        }
                    }
                    .foregroundStyle(
                        isSelected
                            ? (useAccentForSelected ? accent : Color.primary)
                            : (isHovered ? Color.primary.opacity(0.86) : CharkleTheme.secondaryInk(for: colorScheme))
                    )
                    .padding(.horizontal, isIconOnly ? 8 : 10)
                    .frame(
                        minWidth: isIconOnly ? (size == .compact ? 26 : 30) : nil,
                        maxWidth: fullWidth ? .infinity : nil,
                        minHeight: segmentHeight,
                        maxHeight: segmentHeight
                    )
                    .background {
                        if isSelected {
                            let thumbShape = RoundedRectangle(cornerRadius: innerRadius, style: .continuous)
                            thumbShape
                                .fill(thumbFillColor)
                                .overlay(
                                    thumbShape.strokeBorder(thumbStrokeColor, lineWidth: CharkleTheme.hairlineWidth)
                                )
                                .shadow(
                                    color: Color.black.opacity(colorScheme == .dark ? 0.28 : 0.08),
                                    radius: colorScheme == .dark ? 2 : 1.5,
                                    y: colorScheme == .dark ? 1 : 0.5
                                )
                                .matchedGeometryEffect(id: "charkle-segmented-thumb", in: thumbNamespace)
                        } else if isHovered {
                            RoundedRectangle(cornerRadius: innerRadius, style: .continuous)
                                .fill(Color.primary.opacity(colorScheme == .dark ? 0.05 : 0.035))
                        }
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .modifier(OptionalHelpModifier(helpText: item.helpText))
                .accessibilityAddTraits(isSelected ? .isSelected : [])
                .onHover { hovering in
                    if hovering {
                        hoveredOption = item.value
                    } else if hoveredOption == item.value {
                        hoveredOption = nil
                    }
                }
            }
        }
        .padding(trackPadding)
        .background(trackFillColor, in: trackShape)
        .overlay {
            if reduceTransparency {
                trackShape
                    .strokeBorder(CharkleTheme.hairline(for: colorScheme), lineWidth: 1.0)
                    .allowsHitTesting(false)
            }
        }
        .fixedSize(horizontal: !fullWidth, vertical: true)
    }

    private var trackFillColor: Color {
        if reduceTransparency {
            return colorScheme == .dark ? Color(charkleHex: "#1A1C21") : CharkleTheme.surfaceSubtle(for: .light)
        }
        return colorScheme == .dark ? Color.white.opacity(0.07) : Color.black.opacity(0.055)
    }

    private var thumbFillColor: Color {
        colorScheme == .dark ? Color(charkleHex: "#2C2F37") : CharkleTheme.surfaceElevated(for: .light)
    }

    private var thumbStrokeColor: Color {
        if reduceTransparency {
            return colorScheme == .dark ? Color.white.opacity(0.22) : Color.black.opacity(0.16)
        }
        return colorScheme == .dark ? Color.white.opacity(0.10) : Color.black.opacity(0.06)
    }
}

// MARK: - Retina Hairline Divider & Drag Reorder Affordances

/// Standard `0.5pt` Retina interior hairline divider for Inspector sections and Settings rows.
public struct CharkleHairlineDivider: View {
    @Environment(\.colorScheme) private var colorScheme

    public let axis: Axis
    public let horizontalInset: CGFloat

    public init(axis: Axis = .horizontal, horizontalInset: CGFloat = 0) {
        self.axis = axis
        self.horizontalInset = horizontalInset
    }

    public var body: some View {
        switch axis {
        case .horizontal:
            Rectangle()
                .fill(CharkleTheme.hairline(for: colorScheme))
                .frame(height: CharkleTheme.hairlineWidth)
                .padding(.horizontal, horizontalInset)
        case .vertical:
            Rectangle()
                .fill(CharkleTheme.hairline(for: colorScheme))
                .frame(width: CharkleTheme.hairlineWidth)
        }
    }
}

/// Subtle 6-dot drag grip handle for reorderable Inspector sections.
public struct CharkleReorderGrip: View {
    public let isHighlighted: Bool

    public init(isHighlighted: Bool = false) {
        self.isHighlighted = isHighlighted
    }

    public var body: some View {
        VStack(spacing: 2.2) {
            ForEach(0..<3, id: \.self) { _ in
                HStack(spacing: 2.2) {
                    Circle().frame(width: 2.2, height: 2.2)
                    Circle().frame(width: 2.2, height: 2.2)
                }
            }
        }
        .foregroundStyle(Color.primary.opacity(isHighlighted ? 0.58 : 0.24))
        .padding(.horizontal, 3)
        .padding(.vertical, 2)
        .contentShape(Rectangle())
    }
}

/// Optional drag-and-context-menu reorder descriptor for `CharkleInspectorSection`.
/// Keeps `.onDrag` strictly off SwiftUI `Button` views to preserve native macOS click/drag reliability.
public struct CharkleSectionReorderActions {
    public let canMoveUp: Bool
    public let canMoveDown: Bool
    public let isCustomized: Bool
    public let onMoveToTop: () -> Void
    public let onMoveUp: () -> Void
    public let onMoveDown: () -> Void
    public let onMoveToBottom: () -> Void
    public let onResetOrder: () -> Void
    public let onBeginDrag: () -> NSItemProvider

    public init(
        canMoveUp: Bool,
        canMoveDown: Bool,
        isCustomized: Bool,
        onMoveToTop: @escaping () -> Void,
        onMoveUp: @escaping () -> Void,
        onMoveDown: @escaping () -> Void,
        onMoveToBottom: @escaping () -> Void,
        onResetOrder: @escaping () -> Void,
        onBeginDrag: @escaping () -> NSItemProvider
    ) {
        self.canMoveUp = canMoveUp
        self.canMoveDown = canMoveDown
        self.isCustomized = isCustomized
        self.onMoveToTop = onMoveToTop
        self.onMoveUp = onMoveUp
        self.onMoveDown = onMoveDown
        self.onMoveToBottom = onMoveToBottom
        self.onResetOrder = onResetOrder
        self.onBeginDrag = onBeginDrag
    }
}

// MARK: - De-Cardified Hairline Inspector Section (300pt Studio Inspector)

/// De-cardified `0.5pt` hairline-divided section built for the `300pt` Inspector rail.
/// Renders flush on `CharkleTheme.inspectorBackground` without outer white rounded cards or borders.
/// Supports optional SF Symbol icons, optional full-row clickable disclosure collapse, and optional
/// drag/context-menu reorder affordances.
public struct CharkleInspectorSection<HeaderTrailing: View, Content: View>: View {
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.charkleAccentSource) private var accentSource
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    public let title: String
    public let systemImage: String?
    public let iconColor: Color?
    public let isExpanded: Binding<Bool>?
    public let showsTopDivider: Bool
    public let showReorderGrip: Bool
    public let isReorderHighlighted: Bool
    public let reorderActions: CharkleSectionReorderActions?
    public let horizontalPadding: CGFloat
    public let verticalPadding: CGFloat
    public let contentSpacing: CGFloat
    private let headerTrailing: HeaderTrailing
    private let content: Content

    @State private var isHeaderHovered: Bool = false
    @State private var isSectionHovered: Bool = false

    public init(
        _ title: String,
        systemImage: String? = nil,
        iconColor: Color? = nil,
        isExpanded: Binding<Bool>? = nil,
        showsTopDivider: Bool = true,
        showReorderGrip: Bool = false,
        isReorderHighlighted: Bool = false,
        reorderActions: CharkleSectionReorderActions? = nil,
        horizontalPadding: CGFloat = 14,
        verticalPadding: CGFloat = 11,
        contentSpacing: CGFloat = 9,
        @ViewBuilder headerTrailing: () -> HeaderTrailing,
        @ViewBuilder content: () -> Content
    ) {
        self.title = title
        self.systemImage = systemImage
        self.iconColor = iconColor
        self.isExpanded = isExpanded
        self.showsTopDivider = showsTopDivider
        self.showReorderGrip = showReorderGrip
        self.isReorderHighlighted = isReorderHighlighted
        self.reorderActions = reorderActions
        self.horizontalPadding = horizontalPadding
        self.verticalPadding = verticalPadding
        self.contentSpacing = contentSpacing
        self.headerTrailing = headerTrailing()
        self.content = content()
    }

    private var effectivelyExpanded: Bool {
        isExpanded?.wrappedValue ?? true
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if showsTopDivider {
                CharkleHairlineDivider()
            }

            VStack(alignment: .leading, spacing: effectivelyExpanded ? contentSpacing : 0) {
                sectionHeader

                if effectivelyExpanded {
                    content
                        .transition(CharkleMotion.revealTransition(offsetY: -3, reduced: reduceMotion))
                }
            }
            .padding(.horizontal, horizontalPadding)
            .padding(.vertical, verticalPadding)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .onHover { hovering in
            guard showReorderGrip || reorderActions != nil else { return }
            if isSectionHovered != hovering {
                isSectionHovered = hovering
            }
        }
    }

    @ViewBuilder
    private var sectionHeader: some View {
        let shouldShowGrip = showReorderGrip || reorderActions != nil

        if let expansionBinding = isExpanded {
            // Full-row clickable disclosure button on the title side; trailing controls & drag grip stay siblings
            // so `.onDrag` is NEVER attached to a SwiftUI `Button`.
            HStack(spacing: 6) {
                Button {
                    withAnimation(CharkleMotion.accessible(CharkleMotion.settleStrong, reduced: reduceMotion)) {
                        expansionBinding.wrappedValue.toggle()
                    }
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "chevron.right")
                            .font(.system(size: 9, weight: .semibold))
                            .foregroundStyle(
                                isHeaderHovered || expansionBinding.wrappedValue
                                    ? Color.primary.opacity(0.76)
                                    : CharkleTheme.secondaryInk(for: colorScheme)
                            )
                            .rotationEffect(.degrees(expansionBinding.wrappedValue ? 90 : 0))
                            .frame(width: 10, height: 10)

                        headerIdentityLabel

                        Spacer(minLength: 4)
                    }
                    .padding(.horizontal, 6)
                    .padding(.vertical, 4)
                    .frame(maxWidth: .infinity, minHeight: 26, alignment: .leading)
                    .background(
                        headerHoverFill,
                        in: RoundedRectangle(cornerRadius: CharkleTheme.Radius.chip, style: .continuous)
                    )
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .padding(.leading, -6)
                .onHover { hovering in
                    withAnimation(CharkleMotion.accessible(CharkleMotion.hoverPress, reduced: reduceMotion)) {
                        isHeaderHovered = hovering
                    }
                }

                headerTrailing

                if shouldShowGrip {
                    if let reorderActions {
                        CharkleReorderGrip(isHighlighted: isReorderHighlighted || isHeaderHovered || isSectionHovered)
                            .help("按住拖拽排序，右键可置顶或恢复默认")
                            .onDrag(reorderActions.onBeginDrag, preview: {
                                dragPreviewPill
                            })
                    } else {
                        CharkleReorderGrip(isHighlighted: isReorderHighlighted || isHeaderHovered || isSectionHovered)
                    }
                }
            }
            .modifier(OptionalReorderContextMenuModifier(actions: reorderActions, reduceMotion: reduceMotion))
        } else {
            let staticHeader = HStack(spacing: 6) {
                headerIdentityLabel
                Spacer(minLength: 4)
                headerTrailing
                if shouldShowGrip {
                    CharkleReorderGrip(isHighlighted: isReorderHighlighted || isHeaderHovered || isSectionHovered)
                        .padding(.leading, 2)
                }
            }
            .padding(.horizontal, 6)
            .padding(.vertical, 3)
            .frame(maxWidth: .infinity, minHeight: 24, alignment: .leading)
            .background(
                reorderActions != nil ? headerHoverFill : Color.clear,
                in: RoundedRectangle(cornerRadius: CharkleTheme.Radius.chip, style: .continuous)
            )
            .contentShape(Rectangle())
            .padding(.horizontal, -6)
            .onHover { hovering in
                guard reorderActions != nil else { return }
                withAnimation(CharkleMotion.accessible(CharkleMotion.hoverPress, reduced: reduceMotion)) {
                    isHeaderHovered = hovering
                }
            }

            if let reorderActions {
                staticHeader
                    .help("按住标题栏拖拽排序，右键可置顶或恢复默认")
                    .onDrag(reorderActions.onBeginDrag, preview: {
                        dragPreviewPill
                    })
                    .modifier(OptionalReorderContextMenuModifier(actions: reorderActions, reduceMotion: reduceMotion))
            } else {
                staticHeader
            }
        }
    }

    private var headerIdentityLabel: some View {
        HStack(spacing: 5) {
            if let systemImage {
                Image(systemName: systemImage)
                    .font(.system(size: 10.5, weight: .semibold))
                    .foregroundStyle(iconColor ?? CharkleTheme.secondaryInk(for: colorScheme))
            }
            Text(title)
                .font(CharkleTheme.text(.caption, weight: .semibold))
                .foregroundStyle(
                    isHeaderHovered
                        ? Color.primary.opacity(0.92)
                        : Color.primary.opacity(0.80)
                )
                .lineLimit(1)
        }
    }

    private var headerHoverFill: Color {
        guard isHeaderHovered else { return .clear }
        if reduceTransparency {
            return CharkleTheme.surfaceSubtle(for: colorScheme)
        }
        return Color.primary.opacity(colorScheme == .dark ? 0.06 : 0.045)
    }

    private var dragPreviewPill: some View {
        let accent = CharkleTheme.accent(for: colorScheme, source: accentSource)
        return HStack(spacing: 6) {
            if let systemImage {
                Image(systemName: systemImage)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(accent)
            }
            Text(title)
                .font(CharkleTheme.text(.caption, weight: .semibold))
                .foregroundStyle(.primary)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
        .background(CharkleTheme.surfaceElevated(for: colorScheme), in: Capsule(style: .continuous))
        .overlay(
            Capsule(style: .continuous)
                .strokeBorder(
                    CharkleTheme.accentBorder(for: colorScheme, source: accentSource),
                    lineWidth: CharkleTheme.hairlineWidth
                )
        )
    }
}

public extension CharkleInspectorSection where HeaderTrailing == EmptyView {
    init(
        _ title: String,
        systemImage: String? = nil,
        iconColor: Color? = nil,
        isExpanded: Binding<Bool>? = nil,
        showsTopDivider: Bool = true,
        showReorderGrip: Bool = false,
        isReorderHighlighted: Bool = false,
        reorderActions: CharkleSectionReorderActions? = nil,
        horizontalPadding: CGFloat = 14,
        verticalPadding: CGFloat = 11,
        contentSpacing: CGFloat = 9,
        @ViewBuilder content: () -> Content
    ) {
        self.init(
            title,
            systemImage: systemImage,
            iconColor: iconColor,
            isExpanded: isExpanded,
            showsTopDivider: showsTopDivider,
            showReorderGrip: showReorderGrip,
            isReorderHighlighted: isReorderHighlighted,
            reorderActions: reorderActions,
            horizontalPadding: horizontalPadding,
            verticalPadding: verticalPadding,
            contentSpacing: contentSpacing,
            headerTrailing: { EmptyView() },
            content: content
        )
    }
}

// MARK: - Precision Spec Row (LabeledContent Metadata Pattern)

/// Clean `LabeledContent`-style metadata row (`12pt` secondary key, `13pt` primary value with
/// `.monospacedDigit()`, optional monospace font, and optional click-to-copy with transient feedback).
public struct CharkleSpecRow: View {
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    public let label: String
    public let value: String
    public let monospaced: Bool
    public let copyable: Bool
    public let copyValue: String?
    public let lineLimit: Int?
    public let valueColor: Color?
    public let onCopy: ((String) -> Void)?

    @State private var isHovered: Bool = false
    @State private var copyFeedbackToken: Int = 0
    @State private var showCopied: Bool = false

    public init(
        _ label: String,
        value: String,
        monospaced: Bool = false,
        copyable: Bool = false,
        copyValue: String? = nil,
        lineLimit: Int? = 1,
        valueColor: Color? = nil,
        onCopy: ((String) -> Void)? = nil
    ) {
        self.label = label
        self.value = value
        self.monospaced = monospaced
        self.copyable = copyable
        self.copyValue = copyValue
        self.lineLimit = lineLimit
        self.valueColor = valueColor
        self.onCopy = onCopy
    }

    public var body: some View {
        Group {
            if copyable {
                Button {
                    let payload = copyValue ?? value
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(payload, forType: .string)
                    onCopy?(payload)
                    copyFeedbackToken += 1
                    withAnimation(CharkleMotion.accessible(CharkleMotion.hoverPress, reduced: reduceMotion)) {
                        showCopied = true
                    }
                } label: {
                    rowContent
                        .padding(.horizontal, 6)
                        .padding(.vertical, 4)
                        .background(
                            isHovered
                                ? Color.primary.opacity(colorScheme == .dark ? 0.06 : 0.04)
                                : Color.clear,
                            in: RoundedRectangle(cornerRadius: CharkleTheme.Radius.sm, style: .continuous)
                        )
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .padding(.horizontal, -6)
                .onHover { hovering in
                    isHovered = hovering
                }
                .help("点击复制「\(label)」")
                .task(id: copyFeedbackToken) {
                    guard copyFeedbackToken > 0 else { return }
                    try? await Task.sleep(for: .seconds(1.2))
                    guard !Task.isCancelled else { return }
                    withAnimation(CharkleMotion.accessible(CharkleMotion.exitSm, reduced: reduceMotion)) {
                        showCopied = false
                    }
                }
            } else {
                rowContent
                    .padding(.vertical, 4)
            }
        }
    }

    private var rowContent: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Text(label)
                .font(CharkleTheme.text(.caption, weight: .regular))
                .foregroundStyle(CharkleTheme.secondaryInk(for: colorScheme))
                .lineLimit(1)
                .layoutPriority(1)

            Spacer(minLength: 6)

            HStack(spacing: 4) {
                Text(value)
                    .font(
                        monospaced
                            ? CharkleTheme.text(.caption, weight: .medium, design: .monospaced)
                            : CharkleTheme.text(.body, weight: .medium)
                    )
                    .monospacedDigit()
                    .foregroundStyle(valueColor ?? Color.primary.opacity(0.90))
                    .lineLimit(lineLimit)
                    .multilineTextAlignment(.trailing)
                    .truncationMode(.middle)

                if copyable && (showCopied || isHovered) {
                    Image(systemName: showCopied ? "checkmark" : "doc.on.doc")
                        .font(.system(size: 9.5, weight: .semibold))
                        .foregroundStyle(
                            showCopied
                                ? CharkleTheme.positive(for: colorScheme)
                                : CharkleTheme.secondaryInk(for: colorScheme)
                        )
                        .frame(width: 12, height: 12)
                        .transition(.opacity)
                }
            }
        }
    }
}

// MARK: - Search Filter Tokens & Inline Chip

/// Typed value representation of an active search/gallery filter token rendered inline
/// inside `CharkleTokenSearchField`.
public nonisolated struct CharkleFilterToken: Identifiable, Hashable, Sendable {
    public nonisolated enum Kind: Hashable, Sendable {
        case color(hex: String)
        case mediaKind(MediaKind)
        case minRating(Int)
        case tag(String)
        case orientation(AspectShape)
        case pinnedOffline
    }

    public let kind: Kind

    public init(_ kind: Kind) {
        self.kind = kind
    }

    public var id: String {
        switch kind {
        case .color(let hex): "color:\(hex.uppercased())"
        case .mediaKind(let kind): "media:\(kind.rawValue)"
        case .minRating(let stars): "rating:\(stars)"
        case .tag(let name): "tag:\(name)"
        case .orientation(let shape): "orientation:\(shape.rawValue)"
        case .pinnedOffline: "pinnedOffline"
        }
    }

    public var label: String {
        switch kind {
        case .color(let hex): hex.uppercased()
        case .mediaKind(let kind): kind.localizedLabel
        case .minRating(let stars): "\(stars)★+"
        case .tag(let name): "#\(name)"
        case .orientation(let shape): shape.localizedLabel
        case .pinnedOffline: "本地保留"
        }
    }

    public var systemImage: String? {
        switch kind {
        case .color:
            nil
        case .mediaKind(let kind):
            switch kind {
            case .image: "photo"
            case .animatedImage: "photo.stack"
            case .video: "video"
            case .webBookmark: "globe"
            case .document: "doc.text"
            case .designFile: "square.on.circle"
            case .audio: "waveform"
            case .model3D: "cube"
            }
        case .minRating:
            "star.fill"
        case .tag:
            "tag"
        case .orientation(let shape):
            switch shape {
            case .landscape: "rectangle"
            case .portrait: "rectangle.portrait"
            case .square: "square"
            case .ultrawide: "rectangle.ratio.16.to.9"
            }
        case .pinnedOffline:
            "arrow.down.circle.fill"
        }
    }

    public static func color(_ hex: String) -> Self { Self(.color(hex: hex)) }
    public static func mediaKind(_ kind: MediaKind) -> Self { Self(.mediaKind(kind)) }
    public static func minRating(_ stars: Int) -> Self { Self(.minRating(stars)) }
    public static func tag(_ name: String) -> Self { Self(.tag(name)) }
    public static func orientation(_ shape: AspectShape) -> Self { Self(.orientation(shape)) }
    public static let pinnedOffline = Self(.pinnedOffline)
}

/// Compact inline removable chip for a `CharkleFilterToken`.
public struct CharkleFilterTokenChip: View {
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.charkleAccentSource) private var accentSource
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    public let token: CharkleFilterToken
    public let onRemove: () -> Void

    @State private var isRemoveHovered: Bool = false

    public init(token: CharkleFilterToken, onRemove: @escaping () -> Void) {
        self.token = token
        self.onRemove = onRemove
    }

    public var body: some View {
        let chipShape = RoundedRectangle(cornerRadius: CharkleTheme.Radius.sm, style: .continuous)

        HStack(spacing: 4) {
            leadingGlyph

            Text(token.label)
                .font(
                    isColorToken
                        ? CharkleTheme.text(.caption, weight: .medium, design: .monospaced)
                        : CharkleTheme.text(.caption, weight: .medium)
                )
                .monospacedDigit()
                .foregroundStyle(.primary.opacity(0.90))
                .lineLimit(1)

            Button(action: onRemove) {
                Image(systemName: "xmark")
                    .font(.system(size: 8, weight: .bold))
                    .foregroundStyle(isRemoveHovered ? Color.primary : CharkleTheme.secondaryInk(for: colorScheme))
                    .frame(width: 14, height: 14)
                    .background(
                        isRemoveHovered ? Color.primary.opacity(colorScheme == .dark ? 0.14 : 0.09) : Color.clear,
                        in: Circle()
                    )
                    .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .onHover { isRemoveHovered = $0 }
            .help("移除筛选：\(token.label)")
        }
        .padding(.leading, 6)
        .padding(.trailing, 3)
        .frame(height: 22)
        .background(chipFill, in: chipShape)
        .overlay {
            if reduceTransparency {
                chipShape
                    .strokeBorder(CharkleTheme.hairline(for: colorScheme), lineWidth: CharkleTheme.hairlineWidth)
                    .allowsHitTesting(false)
            }
        }
    }

    private var isColorToken: Bool {
        if case .color = token.kind { return true }
        return false
    }

    private var chipFill: Color {
        if reduceTransparency {
            return CharkleTheme.surfaceSubtle(for: colorScheme)
        }
        return Color.primary.opacity(colorScheme == .dark ? 0.11 : 0.07)
    }

    @ViewBuilder
    private var leadingGlyph: some View {
        switch token.kind {
        case .color(let hex):
            Circle()
                .fill(Color(charkleHex: hex))
                .frame(width: 9, height: 9)
                .overlay(
                    Circle().strokeBorder(Color.primary.opacity(0.22), lineWidth: CharkleTheme.hairlineWidth)
                )
        case .minRating:
            Image(systemName: "star.fill")
                .font(.system(size: 9, weight: .semibold))
                .foregroundStyle(Color(charkleHex: "#E5B243"))
        case .pinnedOffline:
            Image(systemName: "arrow.down.circle.fill")
                .font(.system(size: 9.5, weight: .semibold))
                .foregroundStyle(CharkleTheme.accent(for: colorScheme, source: accentSource))
        default:
            if let systemImage = token.systemImage {
                Image(systemName: systemImage)
                    .font(.system(size: 9.5, weight: .medium))
                    .foregroundStyle(CharkleTheme.secondaryInk(for: colorScheme))
            }
        }
    }
}

// MARK: - Unified Token Search Field (Liquid Glass Island 1 Ready)

/// Single-line unified search input with inline removable `CharkleFilterToken` chips,
/// seamless background semantic refinement indicator, clear button, and trailing filter trigger slot.
/// Sits cleanly inside a single Liquid Glass island on macOS 26+ (and calibrated material/solid fallback on macOS 15 / Reduce Transparency).
public struct CharkleTokenSearchField<FilterTrigger: View>: View {
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    @Binding public var text: String
    public let tokens: [CharkleFilterToken]
    public let onRemoveToken: (CharkleFilterToken) -> Void
    public let placeholder: String
    public let isRefiningSearch: Bool
    public let compact: Bool
    public let wrapsInGlassIsland: Bool
    public let isFocused: FocusState<Bool>.Binding?
    public let onSubmit: (() -> Void)?
    public let onClearText: (() -> Void)?
    private let filterTrigger: FilterTrigger
    private let hasFilterTrigger: Bool

    public init(
        text: Binding<String>,
        tokens: [CharkleFilterToken] = [],
        onRemoveToken: @escaping (CharkleFilterToken) -> Void = { _ in },
        placeholder: String = "搜索素材、描述画面、标签或颜色…",
        isRefiningSearch: Bool = false,
        compact: Bool = false,
        wrapsInGlassIsland: Bool = true,
        isFocused: FocusState<Bool>.Binding? = nil,
        onSubmit: (() -> Void)? = nil,
        onClearText: (() -> Void)? = nil,
        @ViewBuilder filterTrigger: () -> FilterTrigger
    ) {
        self._text = text
        self.tokens = tokens
        self.onRemoveToken = onRemoveToken
        self.placeholder = placeholder
        self.isRefiningSearch = isRefiningSearch
        self.compact = compact
        self.wrapsInGlassIsland = wrapsInGlassIsland
        self.isFocused = isFocused
        self.onSubmit = onSubmit
        self.onClearText = onClearText
        self.filterTrigger = filterTrigger()
        self.hasFilterTrigger = FilterTrigger.self != EmptyView.self
    }

    public var body: some View {
        let row = HStack(spacing: 6) {
            Group {
                if isRefiningSearch {
                    ProgressView()
                        .controlSize(.mini)
                } else {
                    Image(systemName: "magnifyingglass")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(CharkleTheme.secondaryInk(for: colorScheme))
                }
            }
            .frame(width: 14, height: 14)

            if !tokens.isEmpty {
                let maxTokensWidth: CGFloat = compact ? 116 : 196
                let tokenRow = HStack(spacing: 4) {
                    ForEach(tokens) { token in
                        CharkleFilterTokenChip(token: token) {
                            withAnimation(CharkleMotion.accessible(CharkleMotion.exitSm, reduced: reduceMotion)) {
                                onRemoveToken(token)
                            }
                        }
                        .transition(CharkleMotion.originTransition(anchor: .leading, scale: 0.94, reduced: reduceMotion))
                    }
                }

                ViewThatFits(in: .horizontal) {
                    tokenRow
                        .fixedSize(horizontal: true, vertical: false)

                    ScrollView(.horizontal, showsIndicators: false) {
                        tokenRow
                            .charkleCleanScrollbars(hidden: true)
                    }
                    .scrollIndicators(.hidden)
                }
                .frame(maxWidth: maxTokensWidth, alignment: .leading)
            }

            TextField(placeholder, text: $text)
                .textFieldStyle(.plain)
                .font(CharkleTheme.text(.body))
                .frame(minWidth: compact ? 48 : 88, maxWidth: .infinity)
                .modifier(OptionalFocusBindingModifier(binding: isFocused))
                .onSubmit {
                    onSubmit?()
                }
                .onKeyPress(.delete) {
                    guard text.isEmpty,
                          let lastToken = tokens.last,
                          !Self.hasActiveMarkedText() else {
                        return .ignored
                    }
                    withAnimation(CharkleMotion.accessible(CharkleMotion.exitSm, reduced: reduceMotion)) {
                        onRemoveToken(lastToken)
                    }
                    return .handled
                }

            if !text.isEmpty {
                Button {
                    text = ""
                    onClearText?()
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 12))
                        .foregroundStyle(CharkleTheme.secondaryInk(for: colorScheme))
                        .frame(width: 18, height: 18)
                        .contentShape(Circle())
                }
                .buttonStyle(.plain)
                .help("清除搜索关键词")
            }

            if hasFilterTrigger {
                CharkleHairlineDivider(axis: .vertical)
                    .frame(height: 15)
                    .padding(.horizontal, 1)

                filterTrigger
            }
        }
        .padding(.leading, compact ? 10 : 11)
        .padding(.trailing, hasFilterTrigger ? 6 : (compact ? 8 : 10))
        .frame(height: 34)
        .animation(CharkleMotion.accessible(CharkleMotion.settleStrong, reduced: reduceMotion), value: tokens)

        if wrapsInGlassIsland {
            row.charkleLiquidGlass(.regular, in: Capsule(style: .continuous))
        } else {
            row
                .background(
                    CharkleTheme.inspectorFieldSurface(for: colorScheme),
                    in: RoundedRectangle(cornerRadius: CharkleTheme.Radius.chip, style: .continuous)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: CharkleTheme.Radius.chip, style: .continuous)
                        .strokeBorder(CharkleTheme.hairline(for: colorScheme), lineWidth: CharkleTheme.hairlineWidth)
                )
        }
    }

    /// Prevents deleting an inline filter token while an IME (such as Pinyin) has uncommitted marked text.
    private static func hasActiveMarkedText() -> Bool {
        if let textView = NSApp.keyWindow?.firstResponder as? NSTextView {
            return textView.hasMarkedText()
        }
        return false
    }
}

public extension CharkleTokenSearchField where FilterTrigger == EmptyView {
    init(
        text: Binding<String>,
        tokens: [CharkleFilterToken] = [],
        onRemoveToken: @escaping (CharkleFilterToken) -> Void = { _ in },
        placeholder: String = "搜索素材、描述画面、标签或颜色…",
        isRefiningSearch: Bool = false,
        compact: Bool = false,
        wrapsInGlassIsland: Bool = true,
        isFocused: FocusState<Bool>.Binding? = nil,
        onSubmit: (() -> Void)? = nil,
        onClearText: (() -> Void)? = nil
    ) {
        self.init(
            text: text,
            tokens: tokens,
            onRemoveToken: onRemoveToken,
            placeholder: placeholder,
            isRefiningSearch: isRefiningSearch,
            compact: compact,
            wrapsInGlassIsland: wrapsInGlassIsland,
            isFocused: isFocused,
            onSubmit: onSubmit,
            onClearText: onClearText,
            filterTrigger: { EmptyView() }
        )
    }
}

// MARK: - Color Filter Popover (10 Studio Swatches + Native NSColorSampler Screen Eyedropper)

/// Calibrated color filter control offering 10 low-saturation studio swatches,
/// native macOS `NSColorSampler` screen eyedropper, HEX entry, optional CIELAB tolerance slider,
/// and one-click clear. Use standalone (`embedded: false`) inside `.popover`, or embedded
/// (`embedded: true`) inside a combined filter popover.
public struct CharkleColorFilterPopover: View {
    public static let defaultStudioSwatches: [String] = [
        "#1E2024", "#5C6B73", "#3D5A80", "#4E7D96", "#6B8E76",
        "#D4A373", "#BA6B55", "#E5B243", "#C8B8A6", "#F0EEE9"
    ]

    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.charkleAccentSource) private var accentSource
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    @Binding public var selectedColorHex: String?
    public let colorTolerance: Binding<Double>?
    public let swatches: [String]
    public let title: String?
    public let embedded: Bool
    public let onSelectColor: ((String?) -> Void)?
    public let onToleranceChange: ((Double) -> Void)?

    @State private var hexDraft: String = ""
    @State private var hoveredSwatch: String? = nil

    public init(
        selectedColorHex: Binding<String?>,
        colorTolerance: Binding<Double>? = nil,
        swatches: [String] = CharkleColorFilterPopover.defaultStudioSwatches,
        title: String? = "按色彩筛选",
        embedded: Bool = false,
        onSelectColor: ((String?) -> Void)? = nil,
        onToleranceChange: ((Double) -> Void)? = nil
    ) {
        self._selectedColorHex = selectedColorHex
        self.colorTolerance = colorTolerance
        self.swatches = swatches
        self.title = title
        self.embedded = embedded
        self.onSelectColor = onSelectColor
        self.onToleranceChange = onToleranceChange
    }

    public var body: some View {
        let accent = CharkleTheme.accent(for: colorScheme, source: accentSource)

        let bodyStack = VStack(alignment: .leading, spacing: 10) {
            if title != nil || selectedColorHex != nil {
                HStack(spacing: 6) {
                    if let title {
                        Text(title)
                            .font(CharkleTheme.text(.caption, weight: .semibold))
                            .foregroundStyle(CharkleTheme.secondaryInk(for: colorScheme))
                    }

                    if let activeHex = selectedColorHex {
                        HStack(spacing: 4) {
                            Circle()
                                .fill(Color(charkleHex: activeHex))
                                .frame(width: 9, height: 9)
                                .overlay(
                                    Circle().strokeBorder(Color.primary.opacity(0.22), lineWidth: CharkleTheme.hairlineWidth)
                                )
                            Text(activeHex.uppercased())
                                .font(CharkleTheme.text(.caption, weight: .medium, design: .monospaced))
                                .foregroundStyle(.primary.opacity(0.86))
                        }
                    }

                    Spacer(minLength: 4)

                    if selectedColorHex != nil {
                        Button("清除色彩") {
                            applyColor(nil)
                        }
                        .buttonStyle(CharkleButtonStyle(.subtle, size: .xs))
                    }
                }
            }

            // 10 calibrated low-saturation studio swatches (5 x 2 grid)
            LazyVGrid(
                columns: Array(repeating: GridItem(.flexible(), spacing: 8), count: 5),
                spacing: 8
            ) {
                ForEach(swatches, id: \.self) { hex in
                    let isSelected = selectedColorHex?.uppercased() == hex.uppercased()
                    let isHovered = hoveredSwatch == hex

                    Button {
                        applyColor(isSelected ? nil : hex.uppercased())
                    } label: {
                        ZStack {
                            Circle()
                                .fill(Color(charkleHex: hex))
                                .frame(width: 24, height: 24)
                                .overlay(
                                    Circle().strokeBorder(
                                        isSelected ? accent : Color.primary.opacity(0.18),
                                        lineWidth: isSelected ? 2 : CharkleTheme.hairlineWidth
                                    )
                                )
                            if isSelected {
                                Circle()
                                    .strokeBorder(CharkleTheme.surfaceElevated(for: colorScheme), lineWidth: 1.5)
                                    .frame(width: 20, height: 20)
                            }
                        }
                        .frame(width: 28, height: 28)
                        .scaleEffect(isHovered && !reduceMotion ? 1.08 : 1.0)
                        .contentShape(Circle())
                    }
                    .buttonStyle(.plain)
                    .onHover { hovering in
                        withAnimation(CharkleMotion.accessible(CharkleMotion.hoverPress, reduced: reduceMotion)) {
                            hoveredSwatch = hovering ? hex : (hoveredSwatch == hex ? nil : hoveredSwatch)
                        }
                    }
                    .help("按主色调筛选 \(hex.uppercased())")
                }
            }

            // Native macOS NSColorSampler screen eyedropper + HEX entry
            HStack(spacing: 6) {
                Button {
                    launchScreenEyedropper()
                } label: {
                    HStack(spacing: 5) {
                        Image(systemName: "eyedropper")
                            .font(.system(size: 11.5, weight: .medium))
                        Text("屏幕吸管")
                            .lineLimit(1)
                    }
                }
                .buttonStyle(CharkleButtonStyle(.standard, size: .sm))
                .fixedSize(horizontal: true, vertical: false)
                .help("从画布或屏幕任意位置吸取颜色")

                HStack(spacing: 5) {
                    Circle()
                        .fill(
                            (CharkleTheme.normalizedHex(hexDraft) ?? selectedColorHex)
                                .map { Color(charkleHex: $0) }
                                ?? Color.primary.opacity(0.10)
                        )
                        .frame(width: 11, height: 11)
                        .overlay(
                            Circle().strokeBorder(Color.primary.opacity(0.20), lineWidth: CharkleTheme.hairlineWidth)
                        )

                    TextField("#RRGGBB", text: $hexDraft)
                        .textFieldStyle(.plain)
                        .font(CharkleTheme.text(.caption, weight: .medium, design: .monospaced))
                        .onSubmit {
                            commitHexDraft()
                        }

                    if let parsed = CharkleTheme.normalizedHex(hexDraft),
                       parsed != selectedColorHex?.uppercased() {
                        Button("应用") {
                            commitHexDraft()
                        }
                        .buttonStyle(CharkleButtonStyle(.subtle, size: .xs))
                    }
                }
                .padding(.horizontal, 8)
                .frame(height: 28)
                .background(
                    CharkleTheme.inspectorFieldSurface(for: colorScheme),
                    in: RoundedRectangle(cornerRadius: CharkleTheme.Radius.chip, style: .continuous)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: CharkleTheme.Radius.chip, style: .continuous)
                        .strokeBorder(CharkleTheme.hairline(for: colorScheme), lineWidth: CharkleTheme.hairlineWidth)
                )
            }

            // Optional CIELAB matching tolerance slider
            if let toleranceBinding = colorTolerance, selectedColorHex != nil {
                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Text("匹配范围")
                            .font(CharkleTheme.text(.caption, weight: .medium))
                            .foregroundStyle(CharkleTheme.secondaryInk(for: colorScheme))
                        Spacer(minLength: 4)
                        Text(Self.toleranceLabel(toleranceBinding.wrappedValue))
                            .font(CharkleTheme.text(.caption, weight: .semibold))
                            .monospacedDigit()
                            .foregroundStyle(accent)
                    }

                    HStack(spacing: 6) {
                        Text("精确")
                            .font(CharkleTheme.text(.caption))
                            .foregroundStyle(CharkleTheme.secondaryInk(for: colorScheme))
                        Slider(
                            value: Binding(
                                get: { toleranceBinding.wrappedValue },
                                set: { newVal in
                                    toleranceBinding.wrappedValue = newVal
                                    onToleranceChange?(newVal)
                                }
                            ),
                            in: 10...55
                        )
                        Text("宽松")
                            .font(CharkleTheme.text(.caption))
                            .foregroundStyle(CharkleTheme.secondaryInk(for: colorScheme))
                    }
                }
                .padding(.top, 2)
            }
        }
        .onAppear {
            hexDraft = selectedColorHex?.uppercased() ?? ""
        }
        .onChange(of: selectedColorHex) { _, newHex in
            let normalized = newHex?.uppercased() ?? ""
            if hexDraft.uppercased() != normalized {
                hexDraft = normalized
            }
        }

        if embedded {
            bodyStack
        } else {
            bodyStack
                .padding(14)
                .frame(width: 268)
        }
    }

    private func launchScreenEyedropper() {
        let sampler = NSColorSampler()
        sampler.show { pickedColor in
            MainActor.assumeIsolated {
                guard let pickedColor,
                      let hex = CharkleTheme.hexString(from: pickedColor) else {
                    return
                }
                applyColor(hex)
            }
        }
    }

    private func commitHexDraft() {
        let trimmed = hexDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            applyColor(nil)
            return
        }
        guard let normalized = CharkleTheme.normalizedHex(trimmed) else { return }
        applyColor(normalized)
    }

    private func applyColor(_ hex: String?) {
        selectedColorHex = hex
        hexDraft = hex ?? ""
        onSelectColor?(hex)
    }

    private static func toleranceLabel(_ value: Double) -> String {
        if value <= 20 { return "极近" }
        if value <= 34 { return "相近" }
        return "宽泛"
    }
}

// MARK: - Private ViewModifier Helpers

private struct OptionalHelpModifier: ViewModifier {
    let helpText: String?

    func body(content: Content) -> some View {
        if let helpText, !helpText.isEmpty {
            content.help(helpText)
        } else {
            content
        }
    }
}

private struct OptionalFocusBindingModifier: ViewModifier {
    let binding: FocusState<Bool>.Binding?

    func body(content: Content) -> some View {
        if let binding {
            content.focused(binding)
        } else {
            content
        }
    }
}

private struct OptionalReorderContextMenuModifier: ViewModifier {
    let actions: CharkleSectionReorderActions?
    let reduceMotion: Bool

    func body(content: Content) -> some View {
        if let actions {
            content.contextMenu {
                Button {
                    withAnimation(CharkleMotion.accessible(CharkleMotion.moveOnScreen, reduced: reduceMotion)) {
                        actions.onMoveToTop()
                    }
                } label: {
                    Label("移到最顶部", systemImage: "arrow.up.to.line")
                }
                .disabled(!actions.canMoveUp)

                Button {
                    withAnimation(CharkleMotion.accessible(CharkleMotion.moveOnScreen, reduced: reduceMotion)) {
                        actions.onMoveUp()
                    }
                } label: {
                    Label("上移一项", systemImage: "arrow.up")
                }
                .disabled(!actions.canMoveUp)

                Button {
                    withAnimation(CharkleMotion.accessible(CharkleMotion.moveOnScreen, reduced: reduceMotion)) {
                        actions.onMoveDown()
                    }
                } label: {
                    Label("下移一项", systemImage: "arrow.down")
                }
                .disabled(!actions.canMoveDown)

                Button {
                    withAnimation(CharkleMotion.accessible(CharkleMotion.moveOnScreen, reduced: reduceMotion)) {
                        actions.onMoveToBottom()
                    }
                } label: {
                    Label("移到最底部", systemImage: "arrow.down.to.line")
                }
                .disabled(!actions.canMoveDown)

                if actions.isCustomized {
                    Divider()
                    Button {
                        withAnimation(CharkleMotion.accessible(CharkleMotion.moveOnScreen, reduced: reduceMotion)) {
                            actions.onResetOrder()
                        }
                    } label: {
                        Label("恢复默认排序", systemImage: "arrow.counterclockwise")
                    }
                }
            }
        } else {
            content
        }
    }
}
