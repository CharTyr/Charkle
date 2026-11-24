import SwiftUI

/// Full-row clickable disclosure control for macOS.
/// Unlike SwiftUI's native `DisclosureGroup` (which only accepts clicks on its tiny leading chevron on macOS),
/// clicking anywhere across the header row — chevron, title, middle gap, or trailing badge — smoothly toggles
/// expansion with a quiet hover affordance and `accessibilityReduceMotion` support.
public struct CharkleDisclosureGroup<Label: View, Content: View>: View {
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.charkleAccentSource) private var accentSource
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    @Binding public var isExpanded: Bool
    private let headerVerticalPadding: CGFloat
    private let headerHorizontalPadding: CGFloat
    private let negativeHorizontalBleed: CGFloat
    private let headerCornerRadius: CGFloat
    private let showHoverHighlight: Bool
    private let showsTopDivider: Bool
    private let accentChevronWhenExpanded: Bool
    private let content: () -> Content
    private let label: () -> Label

    @State private var isHovered: Bool = false

    public init(
        isExpanded: Binding<Bool>,
        headerVerticalPadding: CGFloat = 6,
        headerHorizontalPadding: CGFloat = 6,
        negativeHorizontalBleed: CGFloat = 6,
        headerCornerRadius: CGFloat = CharkleTheme.Radius.chip,
        showHoverHighlight: Bool = true,
        showsTopDivider: Bool = false,
        accentChevronWhenExpanded: Bool = false,
        @ViewBuilder content: @escaping () -> Content,
        @ViewBuilder label: @escaping () -> Label
    ) {
        self._isExpanded = isExpanded
        self.headerVerticalPadding = headerVerticalPadding
        self.headerHorizontalPadding = headerHorizontalPadding
        self.negativeHorizontalBleed = negativeHorizontalBleed
        self.headerCornerRadius = headerCornerRadius
        self.showHoverHighlight = showHoverHighlight
        self.showsTopDivider = showsTopDivider
        self.accentChevronWhenExpanded = accentChevronWhenExpanded
        self.content = content
        self.label = label
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if showsTopDivider {
                CharkleHairlineDivider()
                    .padding(.bottom, 4)
            }

            Button {
                withAnimation(CharkleMotion.accessible(CharkleMotion.settleStrong, reduced: reduceMotion)) {
                    isExpanded.toggle()
                }
            } label: {
                HStack(spacing: 7) {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 9.5, weight: .semibold))
                        .foregroundStyle(chevronColor)
                        .rotationEffect(.degrees(isExpanded ? 90 : 0))
                        .frame(width: 12, height: 12)

                    label()
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .padding(.horizontal, headerHorizontalPadding)
                .padding(.vertical, headerVerticalPadding)
                .frame(maxWidth: .infinity, minHeight: 30, alignment: .leading)
                .background(
                    hoverFillColor,
                    in: RoundedRectangle(cornerRadius: headerCornerRadius, style: .continuous)
                )
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .padding(.horizontal, -negativeHorizontalBleed)
            .onHover { hovering in
                withAnimation(CharkleMotion.accessible(CharkleMotion.hoverPress, reduced: reduceMotion)) {
                    isHovered = hovering
                }
            }

            if isExpanded {
                content()
                    .transition(CharkleMotion.revealTransition(offsetY: -3, reduced: reduceMotion))
            }
        }
    }

    private var chevronColor: Color {
        if isExpanded && accentChevronWhenExpanded {
            return CharkleTheme.accent(for: colorScheme, source: accentSource)
        }
        return (isHovered || isExpanded)
            ? Color.primary.opacity(0.80)
            : CharkleTheme.secondaryInk(for: colorScheme)
    }

    private var hoverFillColor: Color {
        guard showHoverHighlight && isHovered else { return .clear }
        if reduceTransparency {
            return CharkleTheme.surfaceSubtle(for: colorScheme)
        }
        return Color.primary.opacity(colorScheme == .dark ? 0.065 : 0.045)
    }
}
