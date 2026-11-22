import CharkleCanvas
import CharkleCore
import SwiftUI

/// Hardware-authentic MacBook Notch shape:
/// Top left/right concave ears flare seamlessly into the screen bezel at `y = 0`,
/// flowing down into smooth continuous bottom corners.
private nonisolated struct NotchShellShape: Shape {
    var topEarRadius: CGFloat
    var bottomCornerRadius: CGFloat

    var animatableData: AnimatablePair<CGFloat, CGFloat> {
        get { AnimatablePair(topEarRadius, bottomCornerRadius) }
        set {
            topEarRadius = newValue.first
            bottomCornerRadius = newValue.second
        }
    }

    func path(in rect: CGRect) -> Path {
        let w = rect.width
        let h = rect.height
        let topR = min(topEarRadius, w * 0.25, h * 0.45)
        let botR = min(bottomCornerRadius, max(0, (w - topR * 2) * 0.5), max(0, h - topR))
        let k: CGFloat = 0.55228475

        var path = Path()
        path.move(to: CGPoint(x: 0, y: 0))

        // Top-left concave ear: tangent horizontal at (0, 0), tangent vertical at (topR, topR)
        path.addCurve(
            to: CGPoint(x: topR, y: topR),
            control1: CGPoint(x: topR * k, y: 0),
            control2: CGPoint(x: topR, y: topR * (1 - k))
        )

        // Left wall
        path.addLine(to: CGPoint(x: topR, y: h - botR))

        // Bottom-left rounded corner
        path.addCurve(
            to: CGPoint(x: topR + botR, y: h),
            control1: CGPoint(x: topR, y: h - botR * (1 - k)),
            control2: CGPoint(x: topR + botR * (1 - k), y: h)
        )

        // Bottom edge
        path.addLine(to: CGPoint(x: w - topR - botR, y: h))

        // Bottom-right rounded corner
        path.addCurve(
            to: CGPoint(x: w - topR, y: h - botR),
            control1: CGPoint(x: w - topR - botR * (1 - k), y: h),
            control2: CGPoint(x: w - topR, y: h - botR * (1 - k))
        )

        // Right wall
        path.addLine(to: CGPoint(x: w - topR, y: topR))

        // Top-right concave ear: tangent vertical at (w - topR, topR), tangent horizontal at (w, 0)
        path.addCurve(
            to: CGPoint(x: w, y: 0),
            control1: CGPoint(x: w - topR, y: topR * (1 - k)),
            control2: CGPoint(x: w - topR * k, y: 0)
        )

        path.closeSubpath()
        return path
    }
}

/// Open perimeter path (left ear -> sides -> bottom -> right ear, omitting the top bezel edge)
/// so a whisper-thin specular rim defines the black shell against dark wallpapers without any top seam.
private nonisolated struct NotchShellRimPath: Shape {
    var topEarRadius: CGFloat
    var bottomCornerRadius: CGFloat

    func path(in rect: CGRect) -> Path {
        let w = rect.width
        let h = rect.height
        let topR = min(topEarRadius, w * 0.25, h * 0.45)
        let botR = min(bottomCornerRadius, max(0, (w - topR * 2) * 0.5), max(0, h - topR))
        let k: CGFloat = 0.55228475

        var path = Path()
        path.move(to: CGPoint(x: 0.5, y: 0))
        path.addCurve(
            to: CGPoint(x: topR, y: topR),
            control1: CGPoint(x: topR * k, y: 0),
            control2: CGPoint(x: topR, y: topR * (1 - k))
        )
        path.addLine(to: CGPoint(x: topR, y: h - botR))
        path.addCurve(
            to: CGPoint(x: topR + botR, y: h - 0.5),
            control1: CGPoint(x: topR, y: h - botR * (1 - k)),
            control2: CGPoint(x: topR + botR * (1 - k), y: h - 0.5)
        )
        path.addLine(to: CGPoint(x: w - topR - botR, y: h - 0.5))
        path.addCurve(
            to: CGPoint(x: w - topR, y: h - botR),
            control1: CGPoint(x: w - topR - botR * (1 - k), y: h - 0.5),
            control2: CGPoint(x: w - topR, y: h - botR * (1 - k))
        )
        path.addLine(to: CGPoint(x: w - topR, y: topR))
        path.addCurve(
            to: CGPoint(x: w - 0.5, y: 0),
            control1: CGPoint(x: w - topR, y: topR * (1 - k)),
            control2: CGPoint(x: w - topR * k, y: 0)
        )
        return path
    }
}

/// Pure-black hardware-native MacBook Notch Shelf UI:
/// - Always stays solid `#000000` whether hovered (unfocused), dragged over, or clicked,
///   matching the physical MacBook camera housing bezel without turning into translucent glass.
/// - Reserves an explicit physical-notch dead zone across the top center (`topNotchBandHeight` × `notchCenterClearanceWidth`),
///   flanking brand + close controls in the left/right wings and placing all primary controls safely below the camera cutout.
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

    // Explicit high-contrast accent that never desaturates when the non-activating NSPanel is unfocused
    private let activeBlue = Color(charkleHex: "#3B82F6")

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
        return library.folders.first?.name ?? "默认文件夹"
    }

    public var body: some View {
        let expanded = shelfState.isExpanded
        let topEar = NotchShelfState.topEarRadius
        let bottomRadius: CGFloat = expanded ? NotchShelfState.bottomCornerRadius : 14
        let collapsedWidth = shelfState.physicalNotchWidth + topEar * 2
        let shape = NotchShellShape(topEarRadius: topEar, bottomCornerRadius: bottomRadius)

        VStack(spacing: 0) {
            ZStack(alignment: .top) {
                if expanded {
                    expandedContent
                        .padding(.horizontal, topEar + 16)
                        .padding(.bottom, 14)
                        .transition(.opacity.combined(with: .scale(scale: 0.96, anchor: .top)))
                } else {
                    Color.clear
                        .frame(width: collapsedWidth, height: max(36, shelfState.topNotchBandHeight))
                }
            }
            .frame(width: expanded ? shelfState.expandedShapeWidth : collapsedWidth)
            .background(Color.black, in: shape)
            .overlay(
                NotchShellRimPath(topEarRadius: topEar, bottomCornerRadius: bottomRadius)
                    .stroke(
                        LinearGradient(
                            stops: [
                                .init(color: Color.white.opacity(0.0), location: 0.0),
                                .init(color: Color.white.opacity(0.07), location: 0.25),
                                .init(color: Color.white.opacity(0.12), location: 1.0)
                            ],
                            startPoint: .top,
                            endPoint: .bottom
                        ),
                        lineWidth: 0.75
                    )
                    .allowsHitTesting(false)
            )
            .shadow(color: Color.black.opacity(0.24), radius: 6, y: 2)
            .shadow(color: Color.black.opacity(0.38), radius: 20, y: 10)
            .scaleEffect(
                x: expanded ? 1.0 : (reduceMotion ? 1.0 : 0.86),
                y: expanded ? 1.0 : (reduceMotion ? 1.0 : 0.38),
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
        .preferredColorScheme(.dark)
    }

    private var expandedContent: some View {
        VStack(spacing: 0) {
            // Band 1: Physical MacBook Notch Wing Bar
            // Center zone (`notchCenterClearanceWidth`) stays 100% pure black & empty so the hardware
            // camera notch never occludes a single pixel of UI on any MacBook Pro/Air display.
            HStack(spacing: 0) {
                HStack(spacing: 6) {
                    CharkleIcon("notch", style: .duotone, size: 15, color: .white.opacity(0.92))
                    Text("Charkle")
                        .font(.system(size: 12.5, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.92))
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                Color.clear
                    .frame(width: shelfState.notchCenterClearanceWidth, height: 1)
                    .accessibilityHidden(true)

                HStack(spacing: 6) {
                    Button(action: onClose) {
                        Image(systemName: "xmark")
                            .font(.system(size: 10, weight: .bold))
                            .foregroundStyle(.white.opacity(0.68))
                            .frame(width: 22, height: 22)
                            .background(Color.white.opacity(0.10), in: Circle())
                    }
                    .buttonStyle(.plain)
                    .help("收起刘海收纳栏")
                }
                .frame(maxWidth: .infinity, alignment: .trailing)
            }
            .frame(height: shelfState.topNotchBandHeight)

            // All interactive full-width controls live strictly BELOW `topNotchBandHeight`
            VStack(spacing: 10) {
                // Row 2: 3-Way Destination Switcher + Contextual Target Indicator
                HStack(spacing: 8) {
                    HStack(spacing: 2) {
                        targetSegment(.inbox, label: "收件箱")
                        targetSegment(.folder, label: "文件夹")
                        targetSegment(.activeMoodboard, label: "活跃情绪板")
                    }
                    .padding(3)
                    .background(Color.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 10, style: .continuous))

                    Spacer(minLength: 4)

                    destinationDetailChip
                }

                // Row 3: Drag-and-Drop Well / Confirmation Banner
                ZStack {
                    let wellShape = RoundedRectangle(cornerRadius: 14, style: .continuous)
                    wellShape
                        .fill(
                            shelfState.isDropTargeted
                                ? activeBlue.opacity(0.24)
                                : Color.white.opacity(0.06)
                        )
                        .overlay(
                            wellShape.strokeBorder(
                                shelfState.isDropTargeted ? activeBlue.opacity(0.9) : Color.white.opacity(0.14),
                                style: StrokeStyle(
                                    lineWidth: shelfState.isDropTargeted ? 1.5 : 1,
                                    dash: shelfState.isDropTargeted ? [] : [5, 4]
                                )
                            )
                        )

                    if let processing = shelfState.processingMessage {
                        HStack(spacing: 10) {
                            ProgressView()
                                .controlSize(.small)
                                .tint(.white)
                            Text(processing)
                                .font(.system(size: 12.5, weight: .semibold))
                                .foregroundStyle(.white)
                        }
                        .transition(.opacity)
                    } else if let banner = shelfState.statusBanner {
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
                                .foregroundStyle(activeBlue)
                            VStack(alignment: .leading, spacing: 2) {
                                Text("松开立即收藏 \(max(1, shelfState.dragItemCount)) 项素材")
                                    .font(.system(size: 13, weight: .semibold))
                                    .foregroundStyle(.white)
                                Text(targetDropHint)
                                    .font(.system(size: 11))
                                    .foregroundStyle(.white.opacity(0.74))
                            }
                        }
                    } else if shelfState.clipboardXPostURL != nil {
                        Button(action: onCollectClipboard) {
                            HStack(spacing: 10) {
                                Image(systemName: "link.badge.plus")
                                    .font(.system(size: 17, weight: .semibold))
                                    .foregroundStyle(activeBlue)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text("检测到剪贴板中的 X 推文链接")
                                        .font(.system(size: 12.5, weight: .semibold))
                                        .foregroundStyle(.white)
                                    Text("点击此处或按 ⌘V / ⌥⇧V 直接保存推文正文与媒体")
                                        .font(.system(size: 10.5))
                                        .foregroundStyle(.white.opacity(0.68))
                                }
                                Spacer()
                                Text("立即保存")
                                    .font(.system(size: 11, weight: .semibold))
                                    .foregroundStyle(.white)
                                    .padding(.horizontal, 10)
                                    .padding(.vertical, 5)
                                    .background(activeBlue, in: Capsule(style: .continuous))
                            }
                            .padding(.horizontal, 14)
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    } else {
                        Button(action: onCollectClipboard) {
                            HStack(spacing: 10) {
                                Image(systemName: "square.and.arrow.down.on.square")
                                    .font(.system(size: 17, weight: .light))
                                    .foregroundStyle(.white.opacity(0.76))
                                VStack(alignment: .leading, spacing: 2) {
                                    Text("拖入图片、视频、链接、PDF 或设计稿")
                                        .font(.system(size: 12.5, weight: .medium))
                                        .foregroundStyle(.white.opacity(0.94))
                                    Text("支持直接拖拽，或点击 / 按 ⌘V 粘贴推文与剪贴板")
                                        .font(.system(size: 10.5))
                                        .foregroundStyle(.white.opacity(0.54))
                                }
                                Spacer()
                            }
                            .padding(.horizontal, 14)
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                }
                .frame(height: 68)

                // Row 4: Quick Capture Actions
                HStack(spacing: 8) {
                    notchActionPill(title: "区域截图", shortcut: "⌥⇧A", icon: "camera.viewfinder", action: onCaptureArea)
                    notchActionPill(title: "剪贴板收藏", shortcut: "⌥⇧V", icon: "doc.on.clipboard", action: onCollectClipboard)
                    notchActionPill(title: "打开主窗", shortcut: nil, icon: "macwindow", action: onOpenMainWindow)
                }
            }
            .padding(.top, 8)
        }
    }

    @ViewBuilder
    private var destinationDetailChip: some View {
        switch shelfState.targetMode {
        case .inbox:
            HStack(spacing: 5) {
                Image(systemName: "tray")
                    .font(.system(size: 10.5))
                    .foregroundStyle(.white.opacity(0.60))
                Text("待整理 \(library.inboxCount) 项")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.white.opacity(0.74))
                    .monospacedDigit()
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .background(Color.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 8, style: .continuous))

        case .folder:
            Menu {
                ForEach(library.folders) { folder in
                    Button(folder.name) {
                        shelfState.selectedFolderID = folder.id
                    }
                }
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: "folder.fill")
                        .font(.system(size: 10))
                        .foregroundStyle(activeBlue)
                    Text(selectedFolderName)
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.92))
                        .lineLimit(1)
                    Image(systemName: "chevron.up.chevron.down")
                        .font(.system(size: 8.5))
                        .foregroundStyle(.white.opacity(0.58))
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 5)
                .background(Color.white.opacity(0.11), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            }
            .menuStyle(.borderlessButton)
            .fixedSize(horizontal: true, vertical: false)

        case .activeMoodboard:
            HStack(spacing: 5) {
                Circle()
                    .fill(Color.green)
                    .frame(width: 6, height: 6)
                Text(activeBoardTitle)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.white.opacity(0.86))
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
            .frame(maxWidth: 165, alignment: .trailing)
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .background(Color.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
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
                        .foregroundStyle(.white.opacity(0.50))
                }
            }
            .foregroundStyle(.white.opacity(0.90))
            .frame(maxWidth: .infinity)
            .padding(.vertical, 7.5)
            .background(Color.white.opacity(0.09), in: RoundedRectangle(cornerRadius: 11, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 11, style: .continuous)
                    .strokeBorder(Color.white.opacity(0.09), lineWidth: 0.75)
            )
        }
        .buttonStyle(CharkleTactileButtonStyle())
    }

    private var targetDropHint: String {
        switch shelfState.targetMode {
        case .inbox: "将存入收件箱待整理"
        case .folder: "将直接存入「\(selectedFolderName)」"
        case .activeMoodboard: "将收录素材并直接加入「\(activeBoardTitle)」"
        }
    }
}
