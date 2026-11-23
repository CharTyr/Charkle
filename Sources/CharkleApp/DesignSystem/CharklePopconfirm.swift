import SwiftUI

/// Anchored non-modal Popconfirm for single-item destructive confirmation (`DESIGN.md` §7.5).
/// Keeps user focus anchored to the trigger button instead of interrupting the whole window
/// with a centered modal alert. Reserve centered `.alert` for batch/irreversible bulk actions.
public struct CharklePopconfirmCard: View {
    @Environment(\.colorScheme) private var colorScheme

    public let title: String
    public let message: String
    public let confirmTitle: String
    public let onCancel: () -> Void
    public let onConfirm: () -> Void

    public init(
        title: String,
        message: String,
        confirmTitle: String,
        onCancel: @escaping () -> Void,
        onConfirm: @escaping () -> Void
    ) {
        self.title = title
        self.message = message
        self.confirmTitle = confirmTitle
        self.onCancel = onCancel
        self.onConfirm = onConfirm
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top, spacing: 10) {
                ZStack {
                    Circle()
                        .fill(Color.red.opacity(colorScheme == .dark ? 0.22 : 0.12))
                        .frame(width: 26, height: 26)
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(.red)
                }

                VStack(alignment: .leading, spacing: 4) {
                    Text(title)
                        .font(.system(size: 12.5, weight: .semibold))
                        .foregroundStyle(.primary)
                        .fixedSize(horizontal: false, vertical: true)
                    Text(message)
                        .font(.system(size: 11.5))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            HStack(spacing: 8) {
                Spacer(minLength: 0)

                Button("取消") {
                    onCancel()
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .keyboardShortcut(.cancelAction)

                Button(role: .destructive) {
                    onConfirm()
                } label: {
                    Text(confirmTitle)
                        .font(.system(size: 11.5, weight: .semibold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 5)
                        .background(Color.red, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
                }
                .buttonStyle(CharkleTactileButtonStyle())
            }
        }
        .padding(14)
        .frame(width: 248)
    }
}

public extension View {
    /// Attaches an anchored destructive Popconfirm popover directly to a trigger control.
    func charklePopconfirm(
        isPresented: Binding<Bool>,
        title: String,
        message: String,
        confirmTitle: String,
        arrowEdge: Edge = .top,
        onConfirm: @escaping () -> Void
    ) -> some View {
        popover(isPresented: isPresented, arrowEdge: arrowEdge) {
            CharklePopconfirmCard(
                title: title,
                message: message,
                confirmTitle: confirmTitle,
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
