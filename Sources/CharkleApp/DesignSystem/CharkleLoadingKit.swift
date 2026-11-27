import SwiftUI

/// Structural skeleton block calibrated for Charkle's Light & Dark neutral palette (DESIGN.md §7.6).
/// Uses pure GPU opacity pulse only when visible and collapses to a static tint under Reduce Motion,
/// ensuring zero idle CPU usage when unmounted.
public struct CharkleSkeletonShape: View {
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    public let cornerRadius: CGFloat
    @State private var pulsing: Bool = false

    public init(cornerRadius: CGFloat = CharkleTheme.Radius.cardOuter) {
        self.cornerRadius = cornerRadius
    }

    public var body: some View {
        let base = colorScheme == .dark ? Color.white.opacity(0.08) : Color(charkleHex: "#E8E8E5")
        RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
            .fill(base)
            .opacity(reduceMotion ? 1.0 : (pulsing ? 0.58 : 1.0))
            .onAppear {
                guard !reduceMotion else { return }
                withAnimation(.easeInOut(duration: 0.95).repeatForever(autoreverses: true)) {
                    pulsing = true
                }
            }
            .onDisappear {
                pulsing = false
            }
    }
}

/// Structural moodboard canvas skeleton replacing bare centered spinners during board load.
public struct CharkleBoardLoadingSkeleton: View {
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var showSkeleton: Bool = false

    public init() {}

    public var body: some View {
        ZStack {
            CharkleTheme.galleryGround(for: colorScheme)

            if showSkeleton {
                HStack(alignment: .top, spacing: 16) {
                    VStack(spacing: 16) {
                        CharkleSkeletonShape(cornerRadius: CharkleTheme.Radius.cardOuter).frame(width: 210, height: 260)
                        CharkleSkeletonShape(cornerRadius: CharkleTheme.Radius.cardOuter).frame(width: 210, height: 150)
                    }
                    VStack(spacing: 16) {
                        CharkleSkeletonShape(cornerRadius: CharkleTheme.Radius.cardOuter).frame(width: 260, height: 170)
                        CharkleSkeletonShape(cornerRadius: CharkleTheme.Radius.cardOuter).frame(width: 260, height: 240)
                    }
                    VStack(spacing: 16) {
                        CharkleSkeletonShape(cornerRadius: CharkleTheme.Radius.cardOuter).frame(width: 200, height: 220)
                        CharkleSkeletonShape(cornerRadius: CharkleTheme.Radius.cardOuter).frame(width: 200, height: 190)
                    }
                }
                .padding(36)
                .transition(.opacity)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .task {
            // Wait 300ms before showing skeleton so fast local board loads never flash (DESIGN.md §7.6).
            try? await Task.sleep(for: .milliseconds(300))
            guard !Task.isCancelled else { return }
            withAnimation(CharkleMotion.accessible(CharkleMotion.enterSm, reduced: reduceMotion)) {
                showSkeleton = true
            }
        }
    }
}

/// Anti-flicker delayed spinner (`DESIGN.md` §7.6):
/// - Waits `delayMs` (default 300ms) before appearing so fast operations never flash a spinner.
/// - Once shown, stays visible for at least `minDisplayMs` (default 500ms) before dismissing.
public struct CharkleDelayedSpinner: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    public let isActive: Bool
    public let delayMs: Int
    public let minDisplayMs: Int
    public let controlSize: ControlSize
    public let label: String?

    @State private var isVisible: Bool = false
    @State private var shownAt: Date?

    public init(
        isActive: Bool,
        delayMs: Int = 300,
        minDisplayMs: Int = 500,
        controlSize: ControlSize = .small,
        label: String? = nil
    ) {
        self.isActive = isActive
        self.delayMs = delayMs
        self.minDisplayMs = minDisplayMs
        self.controlSize = controlSize
        self.label = label
    }

    public var body: some View {
        Group {
            if isVisible {
                HStack(spacing: 6) {
                    ProgressView()
                        .controlSize(controlSize)
                    if let label, !label.isEmpty {
                        Text(label)
                            .font(CharkleTheme.text(.caption, weight: .medium))
                            .foregroundStyle(.secondary)
                    }
                }
                .transition(.opacity)
            }
        }
        .task(id: isActive) {
            if isActive {
                guard !isVisible else { return }
                try? await Task.sleep(for: .milliseconds(max(0, delayMs)))
                guard !Task.isCancelled, isActive else { return }
                shownAt = Date()
                withAnimation(CharkleMotion.accessible(CharkleMotion.enterSm, reduced: reduceMotion)) {
                    isVisible = true
                }
            } else {
                guard isVisible else { return }
                if let shownAt {
                    let elapsedMs = Int(Date().timeIntervalSince(shownAt) * 1000)
                    let remainingMs = max(0, minDisplayMs - elapsedMs)
                    if remainingMs > 0 {
                        try? await Task.sleep(for: .milliseconds(remainingMs))
                        guard !Task.isCancelled, !isActive else { return }
                    }
                }
                withAnimation(CharkleMotion.accessible(CharkleMotion.exitSm, reduced: reduceMotion)) {
                    isVisible = false
                }
                shownAt = nil
            }
        }
    }
}

/// Structural delayed media placeholder replacing bare centered spinners in remote image frames.
public struct CharkleMediaPlaceholderSkeleton: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    public let height: CGFloat
    public let cornerRadius: CGFloat

    @State private var showSkeleton: Bool = false

    public init(height: CGFloat = 180, cornerRadius: CGFloat = CharkleTheme.Radius.cardOuter) {
        self.height = height
        self.cornerRadius = cornerRadius
    }

    public var body: some View {
        ZStack {
            Color.clear
            if showSkeleton {
                CharkleSkeletonShape(cornerRadius: cornerRadius)
                    .transition(.opacity)
            }
        }
        .frame(maxWidth: .infinity)
        .frame(height: height)
        .task {
            try? await Task.sleep(for: .milliseconds(300))
            guard !Task.isCancelled else { return }
            withAnimation(CharkleMotion.accessible(CharkleMotion.enterSm, reduced: reduceMotion)) {
                showSkeleton = true
            }
        }
    }
}

/// Structural 2-column skeleton mirroring Inspector Similar Assets cards during visual lookup.
public struct CharkleSimilarGridSkeleton: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var showSkeleton: Bool = false

    public init() {}

    public var body: some View {
        Group {
            if showSkeleton {
                HStack(alignment: .top, spacing: 8) {
                    VStack(spacing: 8) {
                        CharkleSkeletonShape(cornerRadius: CharkleTheme.Radius.settingsInner).frame(height: 148)
                        CharkleSkeletonShape(cornerRadius: CharkleTheme.Radius.settingsInner).frame(height: 112)
                    }
                    VStack(spacing: 8) {
                        CharkleSkeletonShape(cornerRadius: CharkleTheme.Radius.settingsInner).frame(height: 108)
                        CharkleSkeletonShape(cornerRadius: CharkleTheme.Radius.settingsInner).frame(height: 152)
                    }
                }
                .transition(.opacity)
            } else {
                Color.clear.frame(height: 120)
            }
        }
        .task {
            try? await Task.sleep(for: .milliseconds(300))
            guard !Task.isCancelled else { return }
            withAnimation(CharkleMotion.accessible(CharkleMotion.enterSm, reduced: reduceMotion)) {
                showSkeleton = true
            }
        }
    }
}
