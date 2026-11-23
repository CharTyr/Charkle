import SwiftUI

/// Interactive top-trailing Liquid Glass toast stack (DESIGN.md §7.5):
/// - Click-through everywhere outside each toast pill so the gallery/canvas stays unobstructed.
/// - Supports status toasts (2.6s) and action/Undo toasts (4.8s) with a live circular countdown ring.
/// - Hovering a toast pauses auto-dismiss immediately and resumes the remaining time on hover exit.
public struct CharkleToastOverlay: View {
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    public let coordinator: AppCoordinatorStore

    public init(coordinator: AppCoordinatorStore) {
        self.coordinator = coordinator
    }

    public var body: some View {
        VStack {
            HStack {
                Spacer(minLength: 0)
                VStack(alignment: .trailing, spacing: 8) {
                    ForEach(coordinator.toasts) { toast in
                        CharkleToastRow(
                            toast: toast,
                            colorScheme: colorScheme,
                            reduceMotion: reduceMotion,
                            onHoverChange: { hovering in
                                if hovering {
                                    coordinator.pauseToast(toast.id)
                                } else {
                                    coordinator.resumeToast(toast.id)
                                }
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
                        .transition(
                            reduceMotion
                                ? .opacity
                                : .asymmetric(
                                    insertion: .move(edge: .top)
                                        .combined(with: .opacity)
                                        .combined(with: .scale(scale: 0.96, anchor: .topTrailing)),
                                    removal: .opacity
                                        .combined(with: .scale(scale: 0.96, anchor: .topTrailing))
                                )
                        )
                    }
                }
                .padding(.top, 16)
                .padding(.trailing, 20)
            }
            Spacer(minLength: 0)
        }
        .animation(
            CharkleMotion.accessible(CharkleMotion.enterSm, reduced: reduceMotion),
            value: coordinator.toasts
        )
    }
}

private struct CharkleToastRow: View {
    let toast: CharkleToast
    let colorScheme: ColorScheme
    let reduceMotion: Bool
    let onHoverChange: (Bool) -> Void
    let onAction: () -> Void
    let onDismiss: () -> Void

    @State private var isHovered: Bool = false

    private var hasAction: Bool {
        toast.actionTitle != nil
    }

    private var outerShape: RoundedRectangle {
        RoundedRectangle(cornerRadius: CharkleTheme.Radius.popoverOuter, style: .continuous)
    }

    private var innerShape: RoundedRectangle {
        RoundedRectangle(cornerRadius: CharkleTheme.Radius.popoverInner, style: .continuous)
    }

    var body: some View {
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
                .font(.system(size: 12.5, weight: .medium))
                .foregroundStyle(.primary)
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)

            if let actionTitle = toast.actionTitle {
                Button(action: onAction) {
                    Text(actionTitle)
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(accentTint)
                        .padding(.horizontal, 9)
                        .padding(.vertical, 4)
                        .background(accentTint.opacity(colorScheme == .dark ? 0.18 : 0.11), in: innerShape)
                }
                .buttonStyle(CharkleTactileButtonStyle())
            }

            if hasAction || isHovered {
                Button(action: onDismiss) {
                    Image(systemName: "xmark")
                        .font(.system(size: 9.5, weight: .bold))
                        .foregroundStyle(.secondary)
                        .frame(width: 22, height: 22)
                        .background(
                            isHovered ? Color.primary.opacity(colorScheme == .dark ? 0.10 : 0.06) : .clear,
                            in: innerShape
                        )
                }
                .buttonStyle(.plain)
                .help("关闭提示")
            }
        }
        .padding(.leading, 13)
        .padding(.trailing, (hasAction || isHovered) ? 8 : 13)
        .padding(.vertical, 8)
        .frame(maxWidth: 380, alignment: .leading)
        .charkleLiquidGlass(.regular, in: outerShape)
        .contentShape(outerShape)
        .onHover { hovering in
            isHovered = hovering
            onHoverChange(hovering)
        }
    }

    private var accentTint: Color {
        colorScheme == .dark ? Color(charkleHex: "#5B8DEF") : Color(charkleHex: "#2A60E0")
    }

    private var toneColor: Color {
        switch toast.tone {
        case .neutral: return accentTint
        case .success: return colorScheme == .dark ? Color(charkleHex: "#34C769") : Color(charkleHex: "#249A4B")
        case .warning: return colorScheme == .dark ? Color(charkleHex: "#F2B23E") : Color(charkleHex: "#C98212")
        case .error: return colorScheme == .dark ? Color(charkleHex: "#F2584D") : Color(charkleHex: "#D93B30")
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
