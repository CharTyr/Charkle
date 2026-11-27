import SwiftUI

public enum CharkleEmptyStateKind: Sendable {
    case emptyLibrary
    case emptyFolder
    case noFilterResults
    case emptyTrash
    case inboxZero
    case emptyMoodboard
    case emptyInspector
}

/// Miniature product-UI vector vignettes for empty states (DESIGN.md §5.2):
/// Each vignette draws a quiet, scaled-down schematic of the actual Charkle interface in
/// calibrated Light & Dark tokens (160×120 subtle hatched base plate, 2–3 real card/frame shapes,
/// at most one Studio Cobalt accent pointing to the next action, zero generic clipart or text).
public struct CharkleEmptyStateVignette: View {
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.charkleAccentSource) private var accentSource
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    public let kind: CharkleEmptyStateKind
    public let compact: Bool

    @State private var appeared: Bool = false

    public init(_ kind: CharkleEmptyStateKind, compact: Bool = false) {
        self.kind = kind
        self.compact = compact
    }

    private var width: CGFloat { compact ? 132 : 160 }
    private var height: CGFloat { compact ? 98 : 120 }
    private var scale: CGFloat { compact ? 0.825 : 1.0 }

    private var baseFill: Color {
        colorScheme == .dark ? Color(charkleHex: "#23252A") : Color(charkleHex: "#F9F9F8")
    }

    private var hatchStroke: Color {
        colorScheme == .dark ? Color.white.opacity(0.035) : Color(charkleHex: "#0F172A").opacity(0.045)
    }

    private var baseBorder: Color {
        colorScheme == .dark ? Color.white.opacity(0.08) : Color(charkleHex: "#0F172A").opacity(0.07)
    }

    private var cardFill: Color {
        colorScheme == .dark ? Color(charkleHex: "#2F3239") : Color.white
    }

    private var cardBackFill: Color {
        colorScheme == .dark ? Color(charkleHex: "#292C33") : Color(charkleHex: "#F2F2F0")
    }

    private var cardBorder: Color {
        colorScheme == .dark ? Color.white.opacity(0.11) : Color(charkleHex: "#2F2A22").opacity(0.09)
    }

    private var cardShadow: Color {
        colorScheme == .dark ? Color.black.opacity(0.38) : Color(charkleHex: "#2F2A22").opacity(0.11)
    }

    private var slotFill: Color {
        colorScheme == .dark ? Color.white.opacity(0.07) : Color(charkleHex: "#EFEFEF")
    }

    private var barStrong: Color {
        colorScheme == .dark ? Color(charkleHex: "#555B66") : Color(charkleHex: "#CFD5DF")
    }

    private var barMuted: Color {
        colorScheme == .dark ? Color(charkleHex: "#404550") : Color(charkleHex: "#E3E7EE")
    }

    private var accentColor: Color {
        CharkleTheme.accent(for: colorScheme, source: accentSource)
    }

    private var positiveColor: Color {
        colorScheme == .dark ? Color(charkleHex: "#4ADE80") : Color(charkleHex: "#249A4B")
    }

    public var body: some View {
        let plateShape = RoundedRectangle(cornerRadius: CharkleTheme.Radius.popoverOuter * scale, style: .continuous)
        ZStack {
            // Subtle 45° hatched plate
            plateShape
                .fill(baseFill)
                .overlay {
                    Canvas { ctx, size in
                        var path = Path()
                        let step: CGFloat = 7 * scale
                        var x: CGFloat = -size.height
                        while x < size.width + size.height {
                            path.move(to: CGPoint(x: x, y: size.height))
                            path.addLine(to: CGPoint(x: x + size.height, y: 0))
                            x += step
                        }
                        ctx.stroke(path, with: .color(hatchStroke), lineWidth: CharkleTheme.hairlineWidth)
                    }
                    .clipShape(plateShape)
                }
                .overlay(
                    plateShape
                        .strokeBorder(baseBorder, lineWidth: CharkleTheme.hairlineWidth)
                )

            sceneContent
                .scaleEffect(scale)
        }
        .frame(width: width, height: height)
        .accessibilityHidden(true)
        .onAppear {
            appeared = true
        }
    }

    @ViewBuilder
    private var sceneContent: some View {
        switch kind {
        case .emptyLibrary:
            emptyLibraryScene
        case .emptyFolder:
            emptyFolderScene
        case .noFilterResults:
            noFilterResultsScene
        case .emptyTrash:
            emptyTrashScene
        case .inboxZero:
            inboxZeroScene
        case .emptyMoodboard:
            emptyMoodboardScene
        case .emptyInspector:
            emptyInspectorScene
        }
    }

    // 1. Mini 3-column masonry frame with empty slots + 1 Studio Cobalt import slot
    private var emptyLibraryScene: some View {
        HStack(alignment: .top, spacing: 7) {
            VStack(spacing: 7) {
                miniCard(width: 36, height: 42, isBack: true)
                miniCard(width: 36, height: 26, isBack: false)
            }
            VStack(spacing: 7) {
                accentActionTile(width: 40, height: 34, systemImage: "plus")
                miniCard(width: 40, height: 34, isBack: false)
            }
            VStack(spacing: 7) {
                miniCard(width: 36, height: 28, isBack: false)
                miniCard(width: 36, height: 40, isBack: true)
            }
        }
        .padding(14)
    }

    // 2. Folder shell with top tab and clean empty interior slots
    private var emptyFolderScene: some View {
        let folderOuterRadius = CharkleTheme.Radius.cardOuter
        let folderPadding: CGFloat = 8
        let folderInnerRadius = CharkleTheme.Radius.concentricInner(outer: folderOuterRadius, padding: folderPadding)
        let folderCardShape = RoundedRectangle(cornerRadius: folderOuterRadius, style: .continuous)
        let tabShape = RoundedRectangle(cornerRadius: CharkleTheme.Radius.sm, style: .continuous)

        return ZStack(alignment: .topLeading) {
            // Folder back tab
            tabShape
                .fill(cardBackFill)
                .overlay(tabShape.strokeBorder(cardBorder, lineWidth: CharkleTheme.hairlineWidth))
                .frame(width: 42, height: 18)
                .offset(x: 0, y: -6)

            // Main folder card
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 6) {
                    RoundedRectangle(cornerRadius: folderInnerRadius, style: .continuous)
                        .fill(slotFill)
                        .frame(width: 34, height: 36)
                    RoundedRectangle(cornerRadius: folderInnerRadius, style: .continuous)
                        .fill(slotFill)
                        .frame(width: 34, height: 36)
                    accentActionTile(width: 24, height: 36, systemImage: "plus", cornerRadius: folderInnerRadius, iconSize: 10)
                }
                HStack(spacing: 6) {
                    Capsule().fill(barStrong).frame(width: 44, height: 4.5)
                    Capsule().fill(barMuted).frame(width: 26, height: 4.5)
                }
            }
            .padding(folderPadding)
            .background(cardFill, in: folderCardShape)
            .overlay(folderCardShape.strokeBorder(cardBorder, lineWidth: CharkleTheme.hairlineWidth))
            .shadow(color: cardShadow, radius: 5, y: 4)
        }
        .offset(y: 4)
    }

    // 3. Mini search capsule over quiet empty grid slots
    private var noFilterResultsScene: some View {
        VStack(spacing: 9) {
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(accentColor)
                Capsule().fill(barStrong).frame(width: 56, height: 4.5)
                Spacer(minLength: 0)
                Circle().fill(barMuted).frame(width: 7, height: 7)
            }
            .padding(.horizontal, 9)
            .frame(width: 114, height: 24)
            .background(cardFill, in: Capsule(style: .continuous))
            .overlay(Capsule(style: .continuous).strokeBorder(cardBorder, lineWidth: CharkleTheme.hairlineWidth))
            .shadow(color: cardShadow, radius: 4, y: 3)

            HStack(spacing: 7) {
                ForEach(0..<3, id: \.self) { _ in
                    RoundedRectangle(cornerRadius: CharkleTheme.Radius.sm, style: .continuous)
                        .strokeBorder(style: StrokeStyle(lineWidth: CharkleTheme.hairlineWidth, dash: [3, 3]))
                        .foregroundStyle(barStrong.opacity(0.65))
                        .frame(width: 33, height: 36)
                }
            }
        }
    }

    // 4. Calm monochrome empty tray (no accent needed)
    private var emptyTrashScene: some View {
        let backShape = RoundedRectangle(cornerRadius: CharkleTheme.Radius.popoverInner, style: .continuous)
        let frontShape = RoundedRectangle(cornerRadius: CharkleTheme.Radius.cardOuter, style: .continuous)

        return ZStack {
            backShape
                .fill(cardBackFill)
                .overlay(backShape.strokeBorder(cardBorder, lineWidth: CharkleTheme.hairlineWidth))
                .frame(width: 96, height: 58)
                .offset(y: -5)

            VStack(spacing: 7) {
                Image(systemName: "trash")
                    .font(.system(size: 16, weight: .regular))
                    .foregroundStyle(barStrong)
                Capsule().fill(barMuted).frame(width: 48, height: 4)
            }
            .frame(width: 104, height: 60)
            .background(cardFill, in: frontShape)
            .overlay(frontShape.strokeBorder(cardBorder, lineWidth: CharkleTheme.hairlineWidth))
            .shadow(color: cardShadow, radius: 5, y: 4)
            .offset(y: 4)
        }
    }

    // 5. Stacked triaged cards with clean completion badge
    private var inboxZeroScene: some View {
        let backShape = RoundedRectangle(cornerRadius: CharkleTheme.Radius.popoverInner, style: .continuous)
        let frontShape = RoundedRectangle(cornerRadius: CharkleTheme.Radius.cardOuter, style: .continuous)

        return ZStack {
            backShape
                .fill(cardBackFill)
                .overlay(backShape.strokeBorder(cardBorder, lineWidth: CharkleTheme.hairlineWidth))
                .frame(width: 92, height: 52)
                .offset(y: -10)

            HStack(spacing: 9) {
                ZStack {
                    RoundedRectangle(cornerRadius: CharkleTheme.Radius.cardInnerBadge, style: .continuous)
                        .fill(positiveColor.opacity(colorScheme == .dark ? 0.20 : 0.14))
                        .frame(width: 32, height: 32)
                    Image(systemName: "checkmark")
                        .font(.system(size: 13, weight: .bold))
                        .foregroundStyle(positiveColor)
                }
                .scaleEffect(appeared || reduceMotion ? 1.0 : 0.86)
                .animation(CharkleMotion.accessible(CharkleMotion.microOvershoot, reduced: reduceMotion), value: appeared)

                VStack(alignment: .leading, spacing: 6) {
                    Capsule().fill(barStrong).frame(width: 52, height: 5)
                    Capsule().fill(barMuted).frame(width: 36, height: 4)
                }
            }
            .padding(.horizontal, 12)
            .frame(width: 114, height: 56)
            .background(cardFill, in: frontShape)
            .overlay(frontShape.strokeBorder(cardBorder, lineWidth: CharkleTheme.hairlineWidth))
            .shadow(color: cardShadow, radius: 5, y: 4)
            .offset(y: 4)
        }
    }

    // 6. Infinite dotted canvas with blank collage frames + 1 cobalt node
    private var emptyMoodboardScene: some View {
        let frameOuterRadius = CharkleTheme.Radius.popoverInner
        let framePadding: CGFloat = 6
        let frameInnerRadius = CharkleTheme.Radius.concentricInner(outer: frameOuterRadius, padding: framePadding)
        let frameShape = RoundedRectangle(cornerRadius: frameOuterRadius, style: .continuous)

        return ZStack {
            frameShape
                .fill(cardFill)
                .overlay(frameShape.strokeBorder(cardBorder, lineWidth: CharkleTheme.hairlineWidth))
                .frame(width: 54, height: 64)
                .overlay(
                    RoundedRectangle(cornerRadius: frameInnerRadius, style: .continuous)
                        .fill(slotFill)
                        .padding(framePadding)
                )
                .shadow(color: cardShadow, radius: 4, y: 3)
                .offset(x: -26, y: -3)

            frameShape
                .fill(cardFill)
                .overlay(frameShape.strokeBorder(cardBorder, lineWidth: CharkleTheme.hairlineWidth))
                .frame(width: 50, height: 34)
                .overlay(
                    VStack(alignment: .leading, spacing: 4) {
                        Capsule().fill(barStrong).frame(width: 28, height: 4)
                        Capsule().fill(barMuted).frame(width: 20, height: 3.5)
                    }
                    .padding(7),
                    alignment: .leading
                )
                .shadow(color: cardShadow, radius: 4, y: 3)
                .offset(x: 31, y: -16)

            accentActionTile(width: 50, height: 28, systemImage: "plus", cornerRadius: CharkleTheme.Radius.chip, iconSize: 11)
                .offset(x: 31, y: 20)
        }
    }

    // 7. Mini gallery thumbnail paired with an inspector card
    private var emptyInspectorScene: some View {
        let cardRadius = CharkleTheme.Radius.popoverInner
        let thumbPadding: CGFloat = 6
        let thumbInnerRadius = CharkleTheme.Radius.concentricInner(outer: cardRadius, padding: thumbPadding)
        let cardShape = RoundedRectangle(cornerRadius: cardRadius, style: .continuous)

        return HStack(spacing: 8) {
            cardShape
                .fill(cardBackFill)
                .overlay(cardShape.strokeBorder(cardBorder, lineWidth: CharkleTheme.hairlineWidth))
                .frame(width: 44, height: 62)
                .overlay(
                    RoundedRectangle(cornerRadius: thumbInnerRadius, style: .continuous)
                        .fill(slotFill)
                        .padding(thumbPadding)
                )

            VStack(alignment: .leading, spacing: 6) {
                Capsule().fill(barStrong).frame(width: 42, height: 4.5)
                HStack(spacing: 4) {
                    Circle().fill(accentColor.opacity(0.85)).frame(width: 8, height: 8)
                    Circle().fill(barStrong).frame(width: 8, height: 8)
                    Circle().fill(barMuted).frame(width: 8, height: 8)
                }
                Capsule().fill(barMuted).frame(width: 48, height: 4)
                Capsule().fill(barMuted).frame(width: 32, height: 4)
            }
            .padding(9)
            .frame(width: 68, height: 62, alignment: .leading)
            .background(cardFill, in: cardShape)
            .overlay(cardShape.strokeBorder(cardBorder, lineWidth: CharkleTheme.hairlineWidth))
            .shadow(color: cardShadow, radius: 4, y: 3)
        }
    }

    private func miniCard(width: CGFloat, height: CGFloat, isBack: Bool) -> some View {
        let shape = RoundedRectangle(cornerRadius: CharkleTheme.Radius.chip, style: .continuous)
        return shape
            .fill(isBack ? cardBackFill : cardFill)
            .overlay(
                shape
                    .strokeBorder(cardBorder, lineWidth: CharkleTheme.hairlineWidth)
            )
            .shadow(color: isBack ? .clear : cardShadow, radius: 4, y: 3)
            .frame(width: width, height: height)
    }

    private func accentActionTile(
        width: CGFloat,
        height: CGFloat,
        systemImage: String,
        cornerRadius: CGFloat = CharkleTheme.Radius.chip,
        iconSize: CGFloat = 12
    ) -> some View {
        ZStack {
            RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                .fill(accentColor.opacity(colorScheme == .dark ? 0.22 : 0.12))
            RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                .strokeBorder(accentColor.opacity(colorScheme == .dark ? 0.45 : 0.30), lineWidth: CharkleTheme.hairlineWidth)
            Image(systemName: systemImage)
                .font(.system(size: iconSize, weight: .semibold))
                .foregroundStyle(accentColor)
        }
        .frame(width: width, height: height)
        .scaleEffect(appeared || reduceMotion ? 1.0 : 0.90)
        .animation(CharkleMotion.accessible(CharkleMotion.microOvershoot, reduced: reduceMotion), value: appeared)
    }
}
