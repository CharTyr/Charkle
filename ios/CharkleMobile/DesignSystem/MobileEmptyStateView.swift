import SwiftUI

/// Miniature UI Vignettes per `DESIGN.md` §5.2: crisp product-surface vector vignettes
/// with subtle 45° diagonal hatch backing, zero emoji, and at most one Studio Cobalt accent cue.
struct MobileEmptyStateView: View {
    enum Kind {
        case emptyLibrary
        case inboxZero
        case emptyFolder
        case noSearchResults
        case emptyTrash
    }

    let kind: Kind
    let title: String
    let subtitle: String
    var primaryActionTitle: String? = nil
    var primaryAction: (() -> Void)? = nil
    var secondaryActionTitle: String? = nil
    var secondaryAction: (() -> Void)? = nil

    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        VStack(spacing: MobileTheme.Space.lg) {
            vignetteCanvas
                .frame(width: 160, height: 120)
                .accessibilityHidden(true)

            VStack(spacing: 6) {
                Text(title)
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(.primary)
                    .multilineTextAlignment(.center)
                Text(subtitle)
                    .font(.system(size: 13))
                    .foregroundStyle(MobileTheme.secondaryInk(for: colorScheme))
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 300)
            }

            if primaryActionTitle != nil || secondaryActionTitle != nil {
                HStack(spacing: MobileTheme.Space.sm) {
                    if let primaryActionTitle, let primaryAction {
                        Button(action: primaryAction) {
                            Text(primaryActionTitle)
                                .font(.system(size: 14, weight: .semibold))
                                .foregroundStyle(.white)
                                .padding(.horizontal, 18)
                                .padding(.vertical, 10)
                                .background(
                                    MobileTheme.accentButtonFill(for: colorScheme),
                                    in: RoundedRectangle(cornerRadius: MobileTheme.Radius.chip + 2, style: .continuous)
                                )
                        }
                        .buttonStyle(MobileTactileButtonStyle())
                    }
                    if let secondaryActionTitle, let secondaryAction {
                        Button(action: secondaryAction) {
                            Text(secondaryActionTitle)
                                .font(.system(size: 14, weight: .medium))
                                .foregroundStyle(.primary)
                                .padding(.horizontal, 16)
                                .padding(.vertical, 10)
                                .background(
                                    MobileTheme.surfaceSubtle(for: colorScheme),
                                    in: RoundedRectangle(cornerRadius: MobileTheme.Radius.chip + 2, style: .continuous)
                                )
                        }
                        .buttonStyle(MobileTactileButtonStyle())
                    }
                }
                .padding(.top, 2)
            }
        }
        .padding(MobileTheme.Space.xxl)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var vignetteCanvas: some View {
        let isDark = colorScheme == .dark
        let plateFill = isDark ? Color(charkleHex: "#23252A") : Color(charkleHex: "#FAFAFA")
        let hatchColor = isDark ? Color.white.opacity(0.038) : Color.black.opacity(0.045)
        let cardFill = MobileTheme.surfaceElevated(for: colorScheme)
        let strokeColor = MobileTheme.borderStrong(for: colorScheme)
        let mutedBlock = MobileTheme.surfaceSubtle(for: colorScheme)
        let accent = MobileTheme.accent(for: colorScheme)
        let positive = MobileTheme.positive(for: colorScheme)

        return Canvas { context, size in
            let bounds = CGRect(origin: .zero, size: size)
            let plate = Path(roundedRect: bounds, cornerRadius: 18, style: .continuous)
            context.fill(plate, with: .color(plateFill))

            context.drawLayer { layer in
                layer.clip(to: plate)
                var hatch = Path()
                let step: CGFloat = 10
                var x: CGFloat = -size.height
                while x < size.width + size.height {
                    hatch.move(to: CGPoint(x: x, y: size.height))
                    hatch.addLine(to: CGPoint(x: x + size.height, y: 0))
                    x += step
                }
                layer.stroke(hatch, with: .color(hatchColor), lineWidth: 1)
            }
            context.stroke(plate, with: .color(strokeColor.opacity(0.55)), lineWidth: 0.75)

            switch kind {
            case .emptyLibrary:
                let cards: [(CGRect, Bool)] = [
                    (CGRect(x: 22, y: 20, width: 34, height: 48), false),
                    (CGRect(x: 63, y: 20, width: 34, height: 32), false),
                    (CGRect(x: 104, y: 20, width: 34, height: 54), false),
                    (CGRect(x: 22, y: 74, width: 34, height: 26), false),
                    (CGRect(x: 63, y: 58, width: 34, height: 42), true),
                    (CGRect(x: 104, y: 80, width: 34, height: 20), false)
                ]
                for (rect, isAccent) in cards {
                    let path = Path(roundedRect: rect, cornerRadius: 7, style: .continuous)
                    context.fill(path, with: .color(isAccent ? accent.opacity(0.14) : cardFill))
                    context.stroke(path, with: .color(isAccent ? accent.opacity(0.75) : strokeColor), lineWidth: isAccent ? 1.2 : 0.8)
                    if isAccent {
                        var plus = Path()
                        plus.move(to: CGPoint(x: rect.midX - 5, y: rect.midY))
                        plus.addLine(to: CGPoint(x: rect.midX + 5, y: rect.midY))
                        plus.move(to: CGPoint(x: rect.midX, y: rect.midY - 5))
                        plus.addLine(to: CGPoint(x: rect.midX, y: rect.midY + 5))
                        context.stroke(plus, with: .color(accent), style: StrokeStyle(lineWidth: 1.8, lineCap: .round))
                    }
                }

            case .inboxZero:
                let tray = Path(roundedRect: CGRect(x: 34, y: 28, width: 92, height: 64), cornerRadius: 12, style: .continuous)
                context.fill(tray, with: .color(cardFill))
                context.stroke(tray, with: .color(strokeColor), lineWidth: 0.9)
                let bar = Path(roundedRect: CGRect(x: 46, y: 40, width: 42, height: 6), cornerRadius: 3)
                context.fill(bar, with: .color(mutedBlock))
                let badge = Path(ellipseIn: CGRect(x: 68, y: 54, width: 24, height: 24))
                context.fill(badge, with: .color(positive.opacity(0.16)))
                context.stroke(badge, with: .color(positive.opacity(0.75)), lineWidth: 1.2)
                var check = Path()
                check.move(to: CGPoint(x: 75, y: 66))
                check.addLine(to: CGPoint(x: 78.8, y: 70))
                check.addLine(to: CGPoint(x: 86, y: 61.5))
                context.stroke(check, with: .color(positive), style: StrokeStyle(lineWidth: 2, lineCap: .round, lineJoin: .round))

            case .emptyFolder:
                let tab = Path(roundedRect: CGRect(x: 34, y: 26, width: 38, height: 14), cornerRadius: 5, style: .continuous)
                let body = Path(roundedRect: CGRect(x: 34, y: 34, width: 92, height: 60), cornerRadius: 11, style: .continuous)
                context.fill(tab, with: .color(mutedBlock))
                context.fill(body, with: .color(cardFill))
                context.stroke(body, with: .color(strokeColor), lineWidth: 0.9)
                let slot = Path(roundedRect: CGRect(x: 48, y: 48, width: 64, height: 32), cornerRadius: 7, style: .continuous)
                context.stroke(slot, with: .color(accent.opacity(0.65)), style: StrokeStyle(lineWidth: 1.1, dash: [4, 3]))

            case .noSearchResults:
                let searchPill = Path(roundedRect: CGRect(x: 28, y: 22, width: 104, height: 22), cornerRadius: 11)
                context.fill(searchPill, with: .color(cardFill))
                context.stroke(searchPill, with: .color(strokeColor), lineWidth: 0.9)
                let lens = Path(ellipseIn: CGRect(x: 37, y: 28, width: 9, height: 9))
                context.stroke(lens, with: .color(accent), lineWidth: 1.4)
                let slots = [
                    CGRect(x: 28, y: 54, width: 48, height: 42),
                    CGRect(x: 84, y: 54, width: 48, height: 42)
                ]
                for rect in slots {
                    let path = Path(roundedRect: rect, cornerRadius: 8, style: .continuous)
                    context.stroke(path, with: .color(strokeColor), style: StrokeStyle(lineWidth: 1, dash: [4, 3]))
                }

            case .emptyTrash:
                let frame = Path(roundedRect: CGRect(x: 46, y: 26, width: 68, height: 68), cornerRadius: 14, style: .continuous)
                context.fill(frame, with: .color(cardFill))
                context.stroke(frame, with: .color(strokeColor), lineWidth: 0.9)
                let lines = [
                    CGRect(x: 62, y: 44, width: 36, height: 5),
                    CGRect(x: 62, y: 56, width: 26, height: 5),
                    CGRect(x: 62, y: 68, width: 32, height: 5)
                ]
                for rect in lines {
                    context.fill(Path(roundedRect: rect, cornerRadius: 2.5), with: .color(mutedBlock))
                }
            }
        }
    }
}
