import SwiftUI

public nonisolated enum CharklePopconfirmTone: String, CaseIterable, Hashable, Sendable {
    case destructive
    case accent
}

/// Anchored non-modal Popconfirm for single-item confirmations (`DESIGN.md` §7.5).
/// Keeps user focus anchored to the trigger button instead of interrupting the whole window
/// with a centered modal alert. Reserve centered `.alert` for batch/irreversible bulk actions.
public struct CharklePopconfirmCard: View {
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.charkleAccentSource) private var accentSource

    public let title: String
    public let message: String
    public let confirmTitle: String
    public let tone: CharklePopconfirmTone
    public let onCancel: () -> Void
    public let onConfirm: () -> Void

    public init(
        title: String,
        message: String,
        confirmTitle: String,
        tone: CharklePopconfirmTone = .destructive,
        onCancel: @escaping () -> Void,
        onConfirm: @escaping () -> Void
    ) {
        self.title = title
        self.message = message
        self.confirmTitle = confirmTitle
        self.tone = tone
        self.onCancel = onCancel
        self.onConfirm = onConfirm
    }

    private var toneColor: Color {
        switch tone {
        case .destructive:
            CharkleTheme.destructive(for: colorScheme)
        case .accent:
            CharkleTheme.accent(for: colorScheme, source: accentSource)
        }
    }

    private var iconName: String {
        switch tone {
        case .destructive: "exclamationmark.triangle.fill"
        case .accent: "questionmark.circle.fill"
        }
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top, spacing: 10) {
                ZStack {
                    RoundedRectangle(cornerRadius: CharkleTheme.Radius.chip, style: .continuous)
                        .fill(toneColor.opacity(colorScheme == .dark ? 0.18 : 0.11))
                        .frame(width: 26, height: 26)
                    Image(systemName: iconName)
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(toneColor)
                }

                VStack(alignment: .leading, spacing: 4) {
                    Text(title)
                        .font(.system(size: 12.5, weight: .semibold))
                        .foregroundStyle(.primary)
                        .fixedSize(horizontal: false, vertical: true)
                    Text(message)
                        .font(.system(size: 11.5))
                        .foregroundStyle(CharkleTheme.secondaryInk(for: colorScheme))
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            CharkleHairlineDivider()

            HStack(spacing: 8) {
                Spacer(minLength: 0)

                Button("取消") {
                    onCancel()
                }
                .buttonStyle(CharkleButtonStyle(.standard, size: .xs))
                .keyboardShortcut(.cancelAction)

                Button(role: tone == .destructive ? .destructive : nil) {
                    onConfirm()
                } label: {
                    Text(confirmTitle)
                        .fontWeight(.semibold)
                }
                .buttonStyle(CharkleButtonStyle(tone == .destructive ? .destructive : .accent, size: .xs))
            }
        }
        .padding(14)
        .frame(width: 256)
    }
}

public extension View {
    /// Attaches an anchored Popconfirm popover directly to a trigger control.
    func charklePopconfirm(
        isPresented: Binding<Bool>,
        title: String,
        message: String,
        confirmTitle: String,
        tone: CharklePopconfirmTone = .destructive,
        arrowEdge: Edge = .top,
        onConfirm: @escaping () -> Void
    ) -> some View {
        popover(isPresented: isPresented, arrowEdge: arrowEdge) {
            CharklePopconfirmCard(
                title: title,
                message: message,
                confirmTitle: confirmTitle,
                tone: tone,
                onCancel: {
                    isPresented.wrappedValue = false
                },
                onConfirm: {
                    isPresented.wrappedValue = false
                    onConfirm()
                }
            )
        }
    }
}
