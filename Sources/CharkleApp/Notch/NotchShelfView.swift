import CharkleCanvas
import CharkleCore
import SwiftUI

/// Animation-ready MacBook Notch Shelf UI:
/// Renders inside a fixed oversized transparent `NSPanel` anchored flush to `screen.frame.maxY`.
/// Expanding/collapsing strictly drives internal SwiftUI spring geometry morphing from `UnitPoint.top`
/// (Kubai Tip 011 & 015), never mutating `NSWindow.frame`.
public struct NotchShelfView: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    public let shelfState: NotchShelfState
    public let coordinator: AppCoordinatorStore
    public let library: LibraryStore
    public let moodboards: MoodboardStore
    public let onCaptureArea: () -> Void
    public let onCollectClipboard: () -> Void
    public let onOpenMainWindow: () -> Void
    public let onClose: () -> Void

    @Namespace private var targetPillNamespace

    public init(
        shelfState: NotchShelfState,
        coordinator: AppCoordinatorStore,
        library: LibraryStore,
        moodboards: MoodboardStore,
        onCaptureArea: @escaping () -> Void,
        onCollectClipboard: @escaping () -> Void,
        onOpenMainWindow: @escaping () -> Void,
        onClose: @escaping () -> Void
    ) {
        self.shelfState = shelfState
        self.coordinator = coordinator
        self.library = library
        self.moodboards = moodboards
        self.onCaptureArea = onCaptureArea
        self.onCollectClipboard = onCollectClipboard
        self.onOpenMainWindow = onOpenMainWindow
        self.onClose = onClose
    }

    private var activeBoardTitle: String {
        if let activeID = coordinator.activeMoodboardID {
            if moodboards.activeBoard?.id == activeID {
                return moodboards.activeBoard?.title ?? "当前情绪板"
            }
            if let summary = moodboards.boards.first(where: { $0.id == activeID }) {
                return summary.title
            }
        }
        return moodboards.boards.first?.title ?? "未选择情绪板"
    }

    private var selectedFolderName: String {
        if let folderID = shelfState.selectedFolderID,
           let folder = library.folders.first(where: { $0.id == folderID }) {
            return folder.name
        }
        return library.folders.first?.name ?? "新建文件夹"
    }

    public var body: some View {
        let expanded = shelfState.isExpanded
        let outerShape = UnevenRoundedRectangle(
            topLeadingRadius: 8,
            bottomLeadingRadius: expanded ? 24 : 14,
            bottomTrailingRadius: expanded ? 24 : 14,
            topTrailingRadius: 8,
            style: .continuous
        )

        VStack(spacing: 0) {
            ZStack(alignment: .top) {
                if expanded {
                    expandedContent
                        .padding(.top, max(12, shelfState.notchTopInset + 8))
                        .padding(.horizontal, 16)
                        .padding(.bottom, 16)
                        .transition(.opacity.combined(with: .scale(scale: 0.94, anchor: .top)))
                } else {
                    // Sleek collapsed notch lip (invisible at rest unless subtly peeking)
                    Color.clear
                        .frame(width: 196, height: max(4, shelfState.notchTopInset))
                }
            }
            .frame(width: expanded ? 436 : 196)
            .charkleLiquidGlass(.darkNotch, in: outerShape)
            .scaleEffect(
                x: expanded ? 1.0 : (reduceMotion ? 1.0 : 0.84),
                y: expanded ? 1.0 : (reduceMotion ? 1.0 : 0.35),
                anchor: .top
            )
            .opacity(expanded ? 1.0 : 0.0)
            .animation(
                CharkleMotion.accessible(
                    expanded ? CharkleMotion.gestureSpring : CharkleMotion.uiSpring,
                    reduced: reduceMotion
                ),
                value: expanded
            )
            .animation(
                CharkleMotion.accessible(CharkleMotion.settleStrong, reduced: reduceMotion),
                value: shelfState.isDropTargeted
            )

            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .padding(.horizontal, 22)
        .padding(.bottom, 26)
        .preferredColorScheme(.dark)
    }

    private var expandedContent: some View {
        VStack(spacing: 12) {
            // Top bar: Brand + 3-way Target Mode Selector + Close
            HStack(spacing: 8) {
                HStack(spacing: 6) {
                    CharkleIcon("notch", style: .duotone, size: 15, color: .white.opacity(0.92))
                    Text("Charkle")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.94))
                }

                Spacer(minLength: 6)

                // 3-Way Target Selector: 收件箱 / 指定文件夹 / 当前活跃情绪板
                HStack(spacing: 2) {
                    targetSegment(.inbox, label: "收件箱")
                    targetSegment(.folder, label: "文件夹")
                    targetSegment(.activeMoodboard, label: "活跃情绪板")
                }
                .padding(3)
                .background(Color.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 10, style: .continuous))

                Button(action: onClose) {
                    Image(systemName: "xmark")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundStyle(.white.opacity(0.65))
                        .frame(width: 22, height: 22)
                        .background(Color.white.opacity(0.08), in: Circle())
                }
                .buttonStyle(.plain)
            }

            // Contextual target subtitle / folder picker
            HStack(spacing: 6) {
                switch shelfState.targetMode {
                case .inbox:
                    Image(systemName: "tray.and.arrow.down")
                        .font(.system(size: 11))
                        .foregroundStyle(.white.opacity(0.64))
                    Text("存入 /Charkle/Inbox/ 待整理（当前 \(library.inboxCount) 项）")
                        .font(.system(size: 11))
                        .foregroundStyle(.white.opacity(0.72))
                        .monospacedDigit()
                    Spacer()

                case .folder:
                    Image(systemName: "folder")
                        .font(.system(size: 11))
                        .foregroundStyle(.white.opacity(0.64))
                    Text("直投目标目录：")
                        .font(.system(size: 11))
                        .foregroundStyle(.white.opacity(0.68))
                    Menu {
                        ForEach(library.folders) { folder in
                            Button(folder.name) {
                                shelfState.selectedFolderID = folder.id
                            }
                        }
                    } label: {
                        HStack(spacing: 4) {
                            Text(selectedFolderName)
                                .font(.system(size: 11, weight: .semibold))
                                .foregroundStyle(.white.opacity(0.95))
                            Image(systemName: "chevron.up.chevron.down")
                                .font(.system(size: 9))
                                .foregroundStyle(.white.opacity(0.6))
                        }
                        .padding(.horizontal, 8)
                        .padding(.vertical, 3)
                        .background(Color.white.opacity(0.12), in: RoundedRectangle(cornerRadius: 6, style: .continuous))
                    }
                    .menuStyle(.borderlessButton)
                    Spacer()

                case .activeMoodboard:
                    Circle()
                        .fill(Color.green)
                        .frame(width: 6, height: 6)
                    Text("入收件箱并实时追加至「\(activeBoardTitle)」")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(.white.opacity(0.86))
                        .lineLimit(1)
                    Spacer()
                }
            }

            // Main Drag-and-Drop Well / Status Confirmation Banner
            ZStack {
                let wellShape = RoundedRectangle(cornerRadius: 14, style: .continuous)
                wellShape
                    .fill(
                        shelfState.isDropTargeted
                            ? Color.accentColor.opacity(0.22)
                            : Color.white.opacity(0.06)
                    )
                    .overlay(
                        wellShape.strokeBorder(
                            shelfState.isDropTargeted ? Color.accentColor.opacity(0.85) : Color.white.opacity(0.14),
                            style: StrokeStyle(lineWidth: shelfState.isDropTargeted ? 1.75 : 1, dash: shelfState.isDropTargeted ? [] : [5, 4])
                        )
                    )

                if let banner = shelfState.statusBanner {
                    HStack(spacing: 8) {
                        Image(systemName: "checkmark.circle.fill")
                            .font(.system(size: 16))
                            .foregroundStyle(Color.green)
                        Text(banner)
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(.white)
                    }
                    .transition(.scale(scale: 0.94).combined(with: .opacity))
                } else if shelfState.isDropTargeted {
                    HStack(spacing: 10) {
                        Image(systemName: "arrow.down.circle.fill")
                            .font(.system(size: 20))
                            .foregroundStyle(Color.accentColor)
                        VStack(alignment: .leading, spacing: 2) {
                            Text("松开立即收藏 \(max(1, shelfState.dragItemCount)) 项素材")
                                .font(.system(size: 13, weight: .semibold))
                                .foregroundStyle(.white)
                            Text(targetDropHint)
                                .font(.system(size: 11))
                                .foregroundStyle(.white.opacity(0.72))
                        }
                    }
                } else {
                    HStack(spacing: 10) {
                        Image(systemName: "square.and.arrow.down.on.square")
                            .font(.system(size: 17, weight: .light))
                            .foregroundStyle(.white.opacity(0.74))
                        VStack(alignment: .leading, spacing: 2) {
                            Text("拖入图片、视频、链接、PDF 或设计稿")
                                .font(.system(size: 12.5, weight: .medium))
                                .foregroundStyle(.white.opacity(0.92))
                            Text("跨 App 直接拖拽，不打断当前窗口焦点")
                                .font(.system(size: 10.5))
                                .foregroundStyle(.white.opacity(0.55))
                        }
                        Spacer()
                    }
                    .padding(.horizontal, 14)
                }
            }
            .frame(height: 66)

            // Quick Capture Action Row
            HStack(spacing: 8) {
                notchActionPill(title: "区域截图", shortcut: "⌥⇧A", icon: "camera.viewfinder", action: onCaptureArea)
                notchActionPill(title: "剪贴板收藏", shortcut: "⌥⇧V", icon: "doc.on.clipboard", action: onCollectClipboard)
                notchActionPill(title: "打开主窗", shortcut: nil, icon: "macwindow", action: onOpenMainWindow)
            }
        }
    }

    private func targetSegment(_ mode: NotchTargetMode, label: String) -> some View {
        let isSelected = shelfState.targetMode == mode
        return Button {
            withAnimation(CharkleMotion.accessible(CharkleMotion.settleStrong, reduced: reduceMotion)) {
                shelfState.targetMode = mode
                if mode == .folder && shelfState.selectedFolderID == nil {
                    shelfState.selectedFolderID = library.folders.first?.id
                }
            }
        } label: {
            Text(label)
                .font(.system(size: 10.5, weight: isSelected ? .semibold : .medium))
                .foregroundStyle(isSelected ? .white : .white.opacity(0.62))
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background {
                    if isSelected {
                        RoundedRectangle(cornerRadius: 7, style: .continuous)
                            .fill(Color.white.opacity(0.18))
                            .matchedGeometryEffect(id: "notch-target-pill", in: targetPillNamespace)
                    }
                }
        }
        .buttonStyle(.plain)
    }

    private func notchActionPill(title: String, shortcut: String?, icon: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 5) {
                Image(systemName: icon)
                    .font(.system(size: 11, weight: .medium))
                Text(title)
                    .font(.system(size: 11, weight: .medium))
                if let shortcut {
                    Text(shortcut)
                        .font(.system(size: 9.5, weight: .medium, design: .monospaced))
                        .foregroundStyle(.white.opacity(0.52))
                }
            }
            .foregroundStyle(.white.opacity(0.90))
            .frame(maxWidth: .infinity)
            .padding(.vertical, 7)
            .background(Color.white.opacity(0.09), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .strokeBorder(Color.white.opacity(0.10), lineWidth: 0.75)
            )
        }
        .buttonStyle(CharkleTactileButtonStyle())
    }

    private var targetDropHint: String {
        switch shelfState.targetMode {
        case .inbox: "将存入收件箱 /Charkle/Inbox/"
        case .folder: "将直接归档至「\(selectedFolderName)」"
        case .activeMoodboard: "将存入收件箱并上板「\(activeBoardTitle)」"
        }
    }
}
