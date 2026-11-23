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
    @State private var showSkeleton: Bool = false

    public init() {}

    public var body: some View {
        ZStack {
            CharkleTheme.galleryGround(for: colorScheme)

            if showSkeleton {
                HStack(alignment: .top, spacing: 16) {
                    VStack(spacing: 16) {
                        CharkleSkeletonShape(cornerRadius: 12).frame(width: 210, height: 260)
                        CharkleSkeletonShape(cornerRadius: 12).frame(width: 210, height: 150)
                    }
                    VStack(spacing: 16) {
                        CharkleSkeletonShape(cornerRadius: 12).frame(width: 260, height: 170)
                        CharkleSkeletonShape(cornerRadius: 12).frame(width: 260, height: 240)
                    }
                    VStack(spacing: 16) {
                        CharkleSkeletonShape(cornerRadius: 12).frame(width: 200, height: 220)
                        CharkleSkeletonShape(cornerRadius: 12).frame(width: 200, height: 190)
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
            withAnimation(CharkleMotion.enterSm) {
                showSkeleton = true
            }
        }
    }
}
