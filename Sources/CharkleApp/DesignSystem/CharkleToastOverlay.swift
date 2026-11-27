import CharkleCanvas
import SwiftUI

/// Interactive bottom-trailing Liquid Glass 2.5D toast stack (DESIGN.md §7.5):
/// - Anchored at the bottom-right corner and enters bottom-up so top bar & toolbar chrome stay unobstructed.
/// - Hugs content tightly with zero trailing dead space (`ToastWidthCapLayout`) up to 380pt max width.
/// - Handles rapid / unlimited toast bursts via a 2.5D receding depth deck (4 peeking layers, older cards
///   gracefully tucked behind) that fans upward on hover (capped at 5 visible rows + Clear All pill) while
///   pausing every live countdown ring.
/// - Click-through everywhere outside the active bottom-right toast deck.
public struct CharkleToastOverlay: View {
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.charkleAccentSource) private var accentSource
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    public let coordinator: AppCoordinatorStore

    @State private var isStackHovered: Bool = false
    @State private var measuredSizes: [UUID: CGSize] = [:]

    public init(coordinator: AppCoordinatorStore) {
        self.coordinator = coordinator
    }

    private var renderedToasts: [CharkleToast] {
        Array(coordinator.toasts.suffix(CharkleToastDeckLayout.maxRenderedCount))
    }

    private var isExpanded: Bool {
        isStackHovered && coordinator.toasts.count > 1
    }

    private var frontCardSize: CGSize {
        guard let front = renderedToasts.last else {
            return CGSize(width: 220, height: CharkleToastDeckLayout.defaultRowHeight)
        }
        return measuredSizes[front.id] ?? CGSize(width: 220, height: CharkleToastDeckLayout.defaultRowHeight)
    }

    private var heightsFromFront: [CGFloat] {
        renderedToasts.reversed().map { toast in
            measuredSizes[toast.id]?.height ?? CharkleToastDeckLayout.defaultRowHeight
        }
    }

    private var maxVisibleWidth: CGFloat {
        let visibleSlice = renderedToasts.reversed().prefix(
            isExpanded ? CharkleToastDeckLayout.maxVisibleExpanded : 1
        )
        let maxW = visibleSlice.compactMap { measuredSizes[$0.id]?.width }.max() ?? frontCardSize.width
        return max(120, min(380, maxW))
    }

    public var body: some View {
        let toasts = renderedToasts
        let totalCount = coordinator.toasts.count
        let expanded = isExpanded
        let frontWidth = frontCardSize.width
        let frontHeight = frontCardSize.height
        let heights = heightsFromFront
        let headerHeight: CGFloat = 24
        let expandedBodyHeight = CharkleToastDeckLayout.expandedContentHeight(heightsFromFront: heights)
        let activeBridgeHeight: CGFloat = expanded
            ? (expandedBodyHeight + headerHeight + CharkleToastDeckLayout.expandedSpacing)
            : CharkleToastDeckLayout.collapsedDeckHeight(frontHeight: frontHeight, toastCount: totalCount)
        let activeBridgeWidth: CGFloat = expanded ? maxVisibleWidth : max(120, frontWidth)
        let overflowCount = CharkleToastDeckLayout.hiddenOverflowCount(totalCount: totalCount, isExpanded: expanded)

        VStack(spacing: 0) {
            Spacer(minLength: 0)
            HStack(spacing: 0) {
                Spacer(minLength: 0)

                if !toasts.isEmpty {
                    ZStack(alignment: .bottomTrailing) {
                        // Invisible hover/hit bridge strictly scoped to the active deck footprint so
                        // moving across the 8pt gap between fanned pills never flickers or collapses,
                        // while the rest of the window remains 100% click-through.
                        Color.clear
                            .frame(width: activeBridgeWidth, height: max(32, activeBridgeHeight))
                            .contentShape(Rectangle())
                            .allowsHitTesting(expanded)

                        // Hover-expanded top utility pill ("全部关闭" / "另有 N 条 · 全部关闭")
                        if expanded {
                            expandedHeaderPill(totalCount: totalCount, hiddenCount: overflowCount)
                                .offset(y: -(expandedBodyHeight + CharkleToastDeckLayout.expandedSpacing))
                                .zIndex(1100)
                                .transition(
                                    reduceMotion
                                        ? .opacity
                                        : .opacity.combined(with: .scale(scale: 0.92, anchor: .bottomTrailing))
                                )
                        } else if overflowCount > 0 {
                            collapsedOverflowBadge(overflowCount: overflowCount)
                                .offset(
                                    x: -4,
                                    y: -(CharkleToastDeckLayout.collapsedDeckHeight(frontHeight: frontHeight, toastCount: totalCount) - 8)
                                )
                                .zIndex(1050)
                                .allowsHitTesting(false)
                                .transition(.opacity)
                        }

                        ForEach(Array(toasts.enumerated()), id: \.element.id) { index, toast in
                            let depth = (toasts.count - 1) - index
                            let style = expanded
                                ? CharkleToastDeckLayout.expandedCardStyle(
                                    depth: depth,
                                    heightsFromFront: heights,
                                    reduceMotion: reduceMotion
                                )
                                : CharkleToastDeckLayout.collapsedCardStyle(
                                    depth: depth,
                                    reduceMotion: reduceMotion
                                )
                            let isCollapsedBackCard = !expanded && depth > 0
                            let deckMatchWidth: CGFloat? = isCollapsedBackCard && frontWidth > 40 ? frontWidth : nil

                            CharkleToastRow(
                                toast: toast,
                                colorScheme: colorScheme,
                                accentSource: accentSource,
                                reduceMotion: reduceMotion,
                                reduceTransparency: reduceTransparency,
                                isCollapsedBackCard: isCollapsedBackCard,
                                isStackHovered: isStackHovered,
                                matchedBackWidth: deckMatchWidth,
                                onMeasuredSize: { size in
                                    guard !isCollapsedBackCard else { return }
                                    if let existing = measuredSizes[toast.id],
                                       abs(existing.width - size.width) < 0.5,
                                       abs(existing.height - size.height) < 0.5 {
                                        return
                                    }
                                    measuredSizes[toast.id] = size
                                },
                                onAction: {
                                    coordinator.triggerToastAction(toast.id)
                                },
                                onDismiss: {
                                    withAnimation(CharkleMotion.accessible(CharkleMotion.exitSm, reduced: reduceMotion)) {
                                        coordinator.dismissToast(toast.id)
                                    }
                                }
                            )
                            .scaleEffect(style.scale, anchor: .top)
                            .rotation3DEffect(
                                .degrees(style.tiltDegrees),
                                axis: (x: 1, y: 0, z: 0),
                                anchor: .bottom,
                                perspective: 0.45
                            )
                            .offset(y: style.yOffset)
                            .opacity(style.opacity)
                            .blur(radius: style.blurRadius)
                            .zIndex(style.zIndex)
                            .allowsHitTesting(style.allowsHitTesting)
                            .transition(
                                reduceMotion
                                    ? .opacity
                                    : .asymmetric(
                                        insertion: .move(edge: .bottom)
                                            .combined(with: .opacity)
                                            .combined(with: .scale(scale: 0.92, anchor: .bottom)),
                                        removal: .opacity
                                            .combined(with: .scale(scale: 0.94, anchor: .bottom))
                                            .combined(with: .offset(y: 6))
                                    )
                            )
                        }
                    }
                    .onHover { hovering in
                        guard isStackHovered != hovering else { return }
                        withAnimation(CharkleMotion.accessible(CharkleMotion.enterSm, reduced: reduceMotion)) {
                            isStackHovered = hovering
                        }
                        if hovering {
                            coordinator.pauseAllToasts()
                        } else {
                            coordinator.resumeAllToasts()
                        }
                    }
                    .padding(.trailing, 20)
                    .padding(.bottom, 18)
                }
            }
        }
        .animation(
            CharkleMotion.accessible(CharkleMotion.enterSm, reduced: reduceMotion),
            value: coordinator.toasts
        )
        .animation(
            CharkleMotion.accessible(CharkleMotion.enterSm, reduced: reduceMotion),
            value: isStackHovered
        )
        .onChange(of: coordinator.toasts) { _, latest in
            let validIDs = Set(latest.map(\.id))
            if measuredSizes.count > validIDs.count {
                measuredSizes = measuredSizes.filter { validIDs.contains($0.key) }
            }
            if latest.isEmpty && isStackHovered {
                isStackHovered = false
            }
        }
    }

    private func expandedHeaderPill(totalCount: Int, hiddenCount: Int) -> some View {
        let label = hiddenCount > 0
            ? "另有 \(hiddenCount) 条 · 全部关闭"
            : "全部关闭 (\(totalCount))"
        let pillShape = Capsule(style: .continuous)

        return Button {
            withAnimation(CharkleMotion.accessible(CharkleMotion.exitSm, reduced: reduceMotion)) {
                isStackHovered = false
                coordinator.dismissAllToasts()
            }
        } label: {
            HStack(spacing: 5) {
                Text(label)
                    .font(CharkleTheme.text(.caption, weight: .medium))
                    .foregroundStyle(CharkleTheme.secondaryInk(for: colorScheme))
                    .monospacedDigit()
                Image(systemName: "xmark")
                    .font(.system(size: 8.5, weight: .bold))
                    .foregroundStyle(CharkleTheme.secondaryInk(for: colorScheme))
            }
            .padding(.horizontal, 10)
            .frame(height: 24)
            .charkleLiquidGlass(.regular, in: pillShape, interactive: true)
            .contentShape(pillShape)
        }
        .buttonStyle(.plain)
        .help("清除全部提示")
    }

    private func collapsedOverflowBadge(overflowCount: Int) -> some View {
        let pillShape = Capsule(style: .continuous)
        return Text("+\(overflowCount)")
            .font(CharkleTheme.text(.caption, weight: .semibold, design: .rounded))
            .monospacedDigit()
            .foregroundStyle(CharkleTheme.secondaryInk(for: colorScheme))
            .padding(.horizontal, 6.5)
            .padding(.vertical, 2)
            .charkleLiquidGlass(.regular, in: pillShape)
    }
}

/// Custom width-capping layout that hugs its child's exact intrinsic width without ever expanding
/// greedily to `maxWidth` (unlike `.frame(maxWidth:)`), preventing trailing empty glass voids.
private struct ToastWidthCapLayout: Layout {
    let maxWidth: CGFloat

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        guard let subview = subviews.first else { return .zero }
        let proposed = proposal.width.map { min($0, maxWidth) } ?? maxWidth
        return subview.sizeThatFits(ProposedViewSize(width: proposed, height: proposal.height))
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        guard let subview = subviews.first else { return }
        let capped = min(bounds.width, maxWidth)
        let size = subview.sizeThatFits(ProposedViewSize(width: capped, height: bounds.height))
        subview.place(
            at: CGPoint(x: bounds.maxX, y: bounds.midY),
            anchor: .trailing,
            proposal: ProposedViewSize(width: size.width, height: size.height)
        )
    }
}

private struct CharkleToastRow: View {
    let toast: CharkleToast
    let colorScheme: ColorScheme
    let accentSource: CharkleAccentSource
    let reduceMotion: Bool
    let reduceTransparency: Bool
    let isCollapsedBackCard: Bool
    let isStackHovered: Bool
    let matchedBackWidth: CGFloat?
    let onMeasuredSize: (CGSize) -> Void
    let onAction: () -> Void
    let onDismiss: () -> Void

    @State private var isRowHovered: Bool = false
    @State private var isDismissHovered: Bool = false

    private var hasAction: Bool {
        toast.actionTitle != nil
    }

    private var showDismissButton: Bool {
        !isCollapsedBackCard && (hasAction || isRowHovered || isStackHovered)
    }

    private var outerShape: RoundedRectangle {
        RoundedRectangle(cornerRadius: CharkleTheme.Radius.popoverOuter, style: .continuous)
    }

    private var innerShape: RoundedRectangle {
        RoundedRectangle(
            cornerRadius: CharkleTheme.Radius.concentricInner(
                outer: CharkleTheme.Radius.popoverOuter,
                padding: 8
            ),
            style: .continuous
        )
    }

    var body: some View {
        rowContent
            .charkleLiquidGlass(.regular, in: outerShape)
            .contentShape(outerShape)
            .onGeometryChange(for: CGSize.self) { proxy in
                CGSize(width: ceil(proxy.size.width), height: ceil(proxy.size.height))
            } action: { _, newSize in
                guard newSize.width > 10, newSize.height > 10 else { return }
                onMeasuredSize(newSize)
            }
            .onHover { hovering in
                isRowHovered = hovering
            }
    }

    @ViewBuilder
    private var rowContent: some View {
        if let matchedBackWidth {
            // Back cards tucked behind the front card in the collapsed 2.5D stack mirror the front
            // card's width so the receding stack forms a crisp, symmetric silhouette.
            innerHStack
                .frame(width: matchedBackWidth, alignment: .leading)
                .clipped()
        } else {
            ToastWidthCapLayout(maxWidth: 380) {
                innerHStack
            }
        }
    }

    private var innerHStack: some View {
        HStack(spacing: 8) {
            if hasAction {
                ToastCountdownRing(
                    duration: toast.duration,
                    isPaused: toast.isPaused,
                    reduceMotion: reduceMotion,
                    tint: accentTint
                )
            } else {
                Image(systemName: toast.iconName)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(toneColor)
            }

            Text(toast.message)
                .font(CharkleTheme.text(.body, weight: .medium))
                .foregroundStyle(.primary)
                .lineLimit(isCollapsedBackCard ? 1 : 2)
                .truncationMode(.tail)
                .fixedSize(horizontal: false, vertical: !isCollapsedBackCard)

            if isCollapsedBackCard {
                Spacer(minLength: 0)
            }

            if !isCollapsedBackCard, let actionTitle = toast.actionTitle {
                Button(action: onAction) {
                    Text(actionTitle)
                        .font(CharkleTheme.text(.caption, weight: .semibold))
                        .foregroundStyle(accentTint)
                        .padding(.horizontal, 9)
                        .padding(.vertical, 4)
                        .background(
                            CharkleTheme.accentSoft(for: colorScheme, source: accentSource),
                            in: innerShape
                        )
                        .overlay {
                            if reduceTransparency {
                                innerShape
                                    .strokeBorder(
                                        CharkleTheme.accentBorder(for: colorScheme, source: accentSource),
                                        lineWidth: CharkleTheme.hairlineWidth
                                    )
                            }
                        }
                }
                .buttonStyle(CharkleTactileButtonStyle())
                .fixedSize()
            }

            if showDismissButton {
                Button(action: onDismiss) {
                    Image(systemName: "xmark")
                        .font(.system(size: 9.5, weight: .bold))
                        .foregroundStyle(isDismissHovered ? Color.primary : CharkleTheme.secondaryInk(for: colorScheme))
                        .frame(width: 22, height: 22)
                        .background(
                            isDismissHovered ? Color.primary.opacity(colorScheme == .dark ? 0.12 : 0.07) : .clear,
                            in: innerShape
                        )
                        .contentShape(innerShape)
                }
                .buttonStyle(.plain)
                .onHover { isDismissHovered = $0 }
                .help("关闭提示")
                .fixedSize()
            }
        }
        .padding(.leading, 13)
        .padding(.trailing, showDismissButton ? 8 : 13)
        .padding(.vertical, 8)
    }

    private var accentTint: Color {
        CharkleTheme.accent(for: colorScheme, source: accentSource)
    }

    private var toneColor: Color {
        switch toast.tone {
        case .neutral: accentTint
        case .success: CharkleTheme.positive(for: colorScheme)
        case .warning: CharkleTheme.warning(for: colorScheme)
        case .error: CharkleTheme.destructive(for: colorScheme)
        }
    }
}

private struct ToastCountdownRing: View {
    let duration: Double
    let isPaused: Bool
    let reduceMotion: Bool
    let tint: Color

    @State private var remainingFraction: CGFloat = 1.0
    @State private var elapsed: Double = 0
    @State private var lastTick: Date?

    var body: some View {
        ZStack {
            Circle()
                .stroke(Color.primary.opacity(0.12), lineWidth: 2)
            Circle()
                .trim(from: 0, to: max(0, min(1, remainingFraction)))
                .stroke(tint, style: StrokeStyle(lineWidth: 2, lineCap: .round))
                .rotationEffect(.degrees(-90))
        }
        .frame(width: 16, height: 16)
        .task(id: isPaused) {
            guard !reduceMotion, duration > 0 else {
                remainingFraction = 1.0
                return
            }
            if isPaused {
                if let last = lastTick {
                    elapsed += Date().timeIntervalSince(last)
                    lastTick = nil
                }
                remainingFraction = CGFloat(max(0, 1.0 - elapsed / duration))
                return
            }
            lastTick = Date()
            let remaining = max(0.05, duration - elapsed)
            withAnimation(.linear(duration: remaining)) {
                remainingFraction = 0
            }
        }
    }
}
