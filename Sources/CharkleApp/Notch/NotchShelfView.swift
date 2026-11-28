import AppKit
import CharkleCanvas
import CharkleCore
import SwiftUI
import UniformTypeIdentifiers

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
        path.addCurve(
            to: CGPoint(x: topR, y: topR),
            control1: CGPoint(x: topR * k, y: 0),
            control2: CGPoint(x: topR, y: topR * (1 - k))
        )
        path.addLine(to: CGPoint(x: topR, y: h - botR))
        path.addCurve(
            to: CGPoint(x: topR + botR, y: h),
            control1: CGPoint(x: topR, y: h - botR * (1 - k)),
            control2: CGPoint(x: topR + botR * (1 - k), y: h)
        )
        path.addLine(to: CGPoint(x: w - topR - botR, y: h))
        path.addCurve(
            to: CGPoint(x: w - topR, y: h - botR),
            control1: CGPoint(x: w - topR - botR * (1 - k), y: h),
            control2: CGPoint(x: w - topR, y: h - botR * (1 - k))
        )
        path.addLine(to: CGPoint(x: w - topR, y: topR))
        path.addCurve(
            to: CGPoint(x: w, y: 0),
            control1: CGPoint(x: w - topR, y: topR * (1 - k)),
            control2: CGPoint(x: w - topR * k, y: 0)
        )
        path.closeSubpath()
        return path
    }
}

private nonisolated struct NotchShellRimPath: Shape {
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

/// Pure-black Hardware MacBook Notch Shelf:
/// - Compact mode (Img 5): quick capture toolbar + drop well + Recent Assets horizontal strip
///   (ranking both recently saved AND recently opened assets) with hover quick actions & drag-out.
/// - Expanded Full-Waterfall mode (Img 6): smooth multi-column infinite masonry of all recent assets
///   with rubber-band marquee multi-select and multi-item drag-out to external apps, Moodboard, or Folders.
public struct NotchShelfView: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    public let shelfState: NotchShelfState
    public let coordinator: AppCoordinatorStore
    public let library: LibraryStore
    public let moodboards: MoodboardStore
    public let onCaptureArea: () -> Void
    public let onCollectClipboard: () -> Void
    public let onOpenMainWindow: () -> Void
    public let onToggleFullGallery: (Bool) -> Void
    public let onToggleRecentStrip: (Bool) -> Void
    public let onOpenAssetInQuickLook: (AssetRecord) -> Void
    public let onResolveDragFileURL: (UUID) -> URL?
    public let onClose: () -> Void

    @Namespace private var targetPillNamespace
    @Namespace private var notchHeroNamespace

    @State private var notchSelectedIDs: Set<UUID> = []
    @State private var waterfallSearchQuery: String = ""

    private let activeBlue = Color(charkleHex: "#3B82F6")

    public init(
        shelfState: NotchShelfState,
        coordinator: AppCoordinatorStore,
        library: LibraryStore,
        moodboards: MoodboardStore,
        onCaptureArea: @escaping () -> Void,
        onCollectClipboard: @escaping () -> Void,
        onOpenMainWindow: @escaping () -> Void,
        onToggleFullGallery: @escaping (Bool) -> Void = { _ in },
        onToggleRecentStrip: @escaping (Bool) -> Void = { _ in },
        onOpenAssetInQuickLook: @escaping (AssetRecord) -> Void = { _ in },
        onResolveDragFileURL: @escaping (UUID) -> URL? = { _ in nil },
        onClose: @escaping () -> Void
    ) {
        self.shelfState = shelfState
        self.coordinator = coordinator
        self.library = library
        self.moodboards = moodboards
        self.onCaptureArea = onCaptureArea
        self.onCollectClipboard = onCollectClipboard
        self.onOpenMainWindow = onOpenMainWindow
        self.onToggleFullGallery = onToggleFullGallery
        self.onToggleRecentStrip = onToggleRecentStrip
        self.onOpenAssetInQuickLook = onOpenAssetInQuickLook
        self.onResolveDragFileURL = onResolveDragFileURL
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
           let folder = library.folder(byID: folderID) {
            return folder.name
        }
        return library.folderHierarchyRoots.first?.folder.name ?? library.folders.first?.name ?? "默认文件夹"
    }

    private var recentAssets: [AssetRecord] {
        let all = library.recentActivityAssets()
        let q = waterfallSearchQuery.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !q.isEmpty else { return all }
        return all.filter { asset in
            asset.title.lowercased().contains(q)
                || asset.tags.contains(where: { $0.lowercased().contains(q) })
                || (asset.sourceDomain?.lowercased().contains(q) ?? false)
        }
    }

    public var body: some View {
        let expanded = shelfState.isExpanded
        let isFullGallery = shelfState.isFullGalleryExpanded
        let topEar = NotchShelfState.topEarRadius
        let bottomRadius: CGFloat = expanded ? NotchShelfState.bottomCornerRadius : CharkleTheme.Radius.settingsOuter
        let collapsedWidth = shelfState.physicalNotchWidth + topEar * 2
        let collapsedHeight = max(36, shelfState.topNotchBandHeight)
        let targetWidth = shelfState.expandedShapeWidth
        let targetHeight = shelfState.expandedCardHeight
        let shape = NotchShellShape(topEarRadius: topEar, bottomCornerRadius: bottomRadius)

        VStack(spacing: 0) {
            ZStack(alignment: .top) {
                if expanded {
                    expandedContent
                        .padding(.horizontal, topEar + 16)
                        .padding(.bottom, 14)
                        .frame(width: targetWidth, height: targetHeight, alignment: .top)
                        .transition(.opacity)
                }
            }
            .frame(
                width: expanded ? targetWidth : collapsedWidth,
                height: expanded ? targetHeight : collapsedHeight,
                alignment: .top
            )
            .clipShape(shape)
            .background {
                // Shadow strictly on the pure-black vector capsule rather than the full clipped
                // subtree so CoreAnimation never re-rasterizes shadows over 50+ thumbnails per frame.
                shape
                    .fill(Color.black)
                    .shadow(color: Color.black.opacity(0.42), radius: 18, y: 8)
            }
            .overlay(
                NotchShellRimPath(topEarRadius: topEar, bottomCornerRadius: bottomRadius)
                    .stroke(
                        LinearGradient(
                            stops: [
                                .init(color: Color.white.opacity(0.0), location: 0.0),
                                .init(color: Color.white.opacity(0.08), location: 0.25),
                                .init(color: Color.white.opacity(0.14), location: 1.0)
                            ],
                            startPoint: .top,
                            endPoint: .bottom
                        ),
                        lineWidth: CharkleTheme.hairlineWidth
                    )
                    .allowsHitTesting(false)
            )
            .opacity(expanded ? 1.0 : 0.0)
            .animation(
                CharkleMotion.accessible(
                    expanded ? CharkleMotion.notchMorphSpring : CharkleMotion.uiSpring,
                    reduced: reduceMotion
                ),
                value: expanded
            )
            .animation(
                CharkleMotion.accessible(CharkleMotion.notchMorphSpring, reduced: reduceMotion),
                value: isFullGallery
            )
            .animation(
                CharkleMotion.accessible(CharkleMotion.notchMorphSpring, reduced: reduceMotion),
                value: shelfState.isRecentStripExpanded
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
            // Band 1: Physical MacBook Notch Wing Bar (Pin + Open + Close in right wing)
            HStack(spacing: 0) {
                HStack(spacing: 7) {
                    CharkleIcon("notch", style: .duotone, size: 17, color: .white.opacity(0.92), isActive: true)
                    Text("Charkle")
                        .font(CharkleTheme.text(.body, weight: .semibold))
                        .lineLimit(1)
                        .foregroundStyle(.white.opacity(0.94))
                    if shelfState.isMinimalCaptureOnly {
                        HStack(spacing: 4) {
                            Circle()
                                .fill(Color(charkleHex: "#34C769"))
                                .frame(width: 5, height: 5)
                            Text("极简采集")
                                .font(CharkleTheme.text(.caption, weight: .semibold))
                                .lineLimit(1)
                                .foregroundStyle(.white.opacity(0.84))
                        }
                        .padding(.horizontal, 7)
                        .padding(.vertical, 2.5)
                        .background(Color.white.opacity(0.11), in: Capsule(style: .continuous))
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                Color.clear
                    .frame(width: shelfState.notchCenterClearanceWidth, height: 1)
                    .accessibilityHidden(true)

                HStack(spacing: 6) {
                    Button {
                        shelfState.isPinnedOpen.toggle()
                    } label: {
                        Image(systemName: shelfState.isPinnedOpen ? "pin.fill" : "pin")
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(shelfState.isPinnedOpen ? activeBlue : .white.opacity(0.68))
                            .frame(width: 22, height: 22)
                            .background(Color.white.opacity(shelfState.isPinnedOpen ? 0.16 : 0.08), in: Circle())
                    }
                    .buttonStyle(.plain)
                    .help(shelfState.isPinnedOpen ? "取消固定展开" : "固定展开托盘")

                    Button(action: onOpenMainWindow) {
                        Image(systemName: "arrow.up.right.square")
                            .font(.system(size: 10.5, weight: .semibold))
                            .foregroundStyle(.white.opacity(0.68))
                            .frame(width: 22, height: 22)
                            .background(Color.white.opacity(0.08), in: Circle())
                    }
                    .buttonStyle(.plain)
                    .help("打开 Charkle 主窗口")

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

            // Pin each sub-mode to its own exact settled interior width/height so neither compact controls
            // nor the full masonry waterfall ever reflow mid-morph while the black capsule springs smoothly.
            let bodyTransition = CharkleMotion.originTransition(anchor: .top, scale: 0.985, reduced: reduceMotion)
            let compactInnerW = max(300, shelfState.compactBodyWidth - 32)
            let activeCompactHeight = shelfState.isRecentStripExpanded
                ? shelfState.compactCardHeight
                : shelfState.dropOnlyCardHeight
            let compactInnerH = max(96, activeCompactHeight - shelfState.topNotchBandHeight - 22)
            let fullInnerW = max(400, shelfState.fullGalleryBodyWidth - 32)
            let fullInnerH = max(240, shelfState.fullGalleryCardHeight - shelfState.topNotchBandHeight - 22)

            ZStack(alignment: .top) {
                if shelfState.isFullGalleryExpanded && !shelfState.isMinimalCaptureOnly {
                    fullWaterfallGalleryBody
                        .frame(width: fullInnerW, height: fullInnerH, alignment: .top)
                        .transition(bodyTransition)
                } else {
                    compactShelfBody
                        .frame(width: compactInnerW, height: compactInnerH, alignment: .top)
                        .transition(bodyTransition)
                }
            }
            .padding(.top, 8)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        }
    }

    // MARK: - Compact Shelf Mode (Capture Actions + Drop Well + Optional Recent Assets Filmstrip)

    private var compactShelfBody: some View {
        VStack(spacing: 10) {
            // Row 2: Quick Capture Actions + Target Destination Switcher
            HStack(spacing: 8) {
                HStack(spacing: 6) {
                    notchCompactToolButton(title: "区域截图", icon: "camera.viewfinder", action: onCaptureArea)
                    notchCompactToolButton(title: "剪贴板", icon: "doc.on.clipboard", action: onCollectClipboard)
                    notchCompactToolButton(
                        title: shelfState.isMinimalCaptureOnly ? "恢复主窗" : "主窗",
                        icon: "macwindow",
                        action: onOpenMainWindow
                    )
                }
                .fixedSize(horizontal: true, vertical: false)
                .layoutPriority(3)

                Spacer(minLength: 4)

                HStack(spacing: 6) {
                    HStack(spacing: 2) {
                        targetSegment(.inbox, label: "收件箱")
                        targetSegment(.folder, label: "文件夹")
                        targetSegment(.activeMoodboard, label: "活跃情绪板")
                    }
                    .padding(2)
                    .background(Color.white.opacity(0.08), in: RoundedRectangle(cornerRadius: CharkleTheme.Radius.chip, style: .continuous))
                    .fixedSize(horizontal: true, vertical: false)
                    .layoutPriority(2)

                    destinationDetailChip
                        .layoutPriority(0)
                }
            }

            // Row 3: Slim Drop Well / Status Banner
            dropWellRow
                .frame(height: shelfState.isRecentStripExpanded ? 52 : 60)

            // Row 4: Either full Recent Assets Filmstrip OR compact 1-click expand footer
            if shelfState.isRecentStripExpanded {
                VStack(alignment: .leading, spacing: 7) {
                    HStack(spacing: 8) {
                        Text("最近素材")
                            .font(CharkleTheme.text(.caption, weight: .semibold))
                            .lineLimit(1)
                            .foregroundStyle(.white)
                            .padding(.horizontal, 9)
                            .padding(.vertical, 3.5)
                            .background(Color.white.opacity(0.14), in: Capsule(style: .continuous))

                        Text("最近保存与查看，可拖入其他应用、情绪板或文件夹")
                            .font(CharkleTheme.text(.caption))
                            .foregroundStyle(.white.opacity(0.48))
                            .lineLimit(1)

                        Spacer()

                        Button {
                            onToggleRecentStrip(false)
                        } label: {
                            HStack(spacing: 3) {
                                Text("仅收集")
                                    .font(CharkleTheme.text(.caption, weight: .medium))
                                    .lineLimit(1)
                                Image(systemName: "chevron.up")
                                    .font(.system(size: 8.5, weight: .bold))
                            }
                            .foregroundStyle(.white.opacity(0.68))
                            .padding(.horizontal, 8)
                            .padding(.vertical, 3.5)
                            .background(Color.white.opacity(0.08), in: Capsule(style: .continuous))
                        }
                        .buttonStyle(.plain)
                        .help("收起最近素材，仅保留简洁收集窗")

                        if shelfState.isMinimalCaptureOnly {
                            Button {
                                onOpenMainWindow()
                            } label: {
                                HStack(spacing: 4) {
                                    Text("恢复主窗看全部")
                                        .font(CharkleTheme.text(.caption, weight: .semibold))
                                        .lineLimit(1)
                                    Image(systemName: "arrow.up.forward.app")
                                        .font(.system(size: 9.5, weight: .semibold))
                                }
                                .foregroundStyle(.white.opacity(0.78))
                                .padding(.horizontal, 9)
                                .padding(.vertical, 3.5)
                                .background(Color.white.opacity(0.09), in: Capsule(style: .continuous))
                            }
                            .buttonStyle(.plain)
                            .help("退出极简模式并打开主窗口浏览全部素材")
                        } else {
                            Button {
                                onToggleFullGallery(true)
                            } label: {
                                HStack(spacing: 4) {
                                    Text("全部 (\(recentAssets.count))")
                                        .font(CharkleTheme.text(.caption, weight: .semibold))
                                        .monospacedDigit()
                                        .lineLimit(1)
                                    Image(systemName: "chevron.down")
                                        .font(.system(size: 9, weight: .bold))
                                }
                                .foregroundStyle(.white.opacity(0.84))
                                .padding(.horizontal, 9)
                                .padding(.vertical, 3.5)
                                .background(Color.white.opacity(0.10), in: Capsule(style: .continuous))
                            }
                            .buttonStyle(.plain)
                            .help("展开全画面瀑布流浏览最近素材（支持框选多选）")
                        }
                    }

                    if recentAssets.isEmpty {
                        HStack {
                            Spacer()
                            Text("暂无最近素材，拖入文件或按 ⌥⇧V 粘贴收藏")
                                .font(CharkleTheme.text(.caption))
                                .foregroundStyle(.white.opacity(0.45))
                            Spacer()
                        }
                        .frame(height: 104)
                    } else {
                        ScrollView(.horizontal, showsIndicators: false) {
                            LazyHStack(spacing: 9) {
                                ForEach(recentAssets.prefix(shelfState.isMinimalCaptureOnly ? 16 : 24)) { asset in
                                    recentFilmstripCard(asset)
                                }
                            }
                            .padding(.vertical, 2)
                        }
                        .background(HorizontalWheelScrollRedirector())
                        .frame(height: 110)
                        .clipped()
                    }
                }
                .transition(.opacity)
            } else {
                HStack(spacing: 8) {
                    HStack(spacing: 5) {
                        Circle()
                            .fill(activeBlue.opacity(0.85))
                            .frame(width: 5, height: 5)
                        Text(targetDropHint)
                            .font(CharkleTheme.text(.caption, weight: .medium))
                            .foregroundStyle(.white.opacity(0.56))
                            .lineLimit(1)
                    }

                    Spacer(minLength: 8)

                    Button {
                        onToggleRecentStrip(true)
                    } label: {
                        HStack(spacing: 4) {
                            Image(systemName: "photo.on.rectangle.angled")
                                .font(.system(size: 9.5, weight: .semibold))
                            Text("展开最近素材 (\(library.recentActivityAssets().count))")
                                .font(CharkleTheme.text(.caption, weight: .semibold))
                                .monospacedDigit()
                                .lineLimit(1)
                            Image(systemName: "chevron.down")
                                .font(.system(size: 8.5, weight: .bold))
                        }
                        .foregroundStyle(.white.opacity(0.88))
                        .padding(.horizontal, 10)
                        .padding(.vertical, 4)
                        .background(Color.white.opacity(0.11), in: Capsule(style: .continuous))
                    }
                    .buttonStyle(.plain)
                    .help("展开最近素材横条，快速预览或拖出到其他应用")
                }
                .frame(height: 26)
                .transition(.opacity)
            }
        }
    }

    private func recentFilmstripCard(_ asset: AssetRecord) -> some View {
        NotchRecentFilmstripCard(
            asset: asset,
            loader: library.thumbnailLoader,
            isMinimalCaptureOnly: shelfState.isMinimalCaptureOnly,
            onCopyAsset: {
                Task {
                    _ = await library.copyAssetsToPasteboard([asset.id])
                }
            },
            onOpenAssetInQuickLook: {
                onOpenAssetInQuickLook(asset)
            },
            onToggleFullGallery: {
                onToggleFullGallery(true)
            },
            makeDragProvider: {
                makeDragItemProvider(for: [asset.id])
            }
        )
    }

    // MARK: - Expanded Full-Waterfall Gallery Mode (Img 6: Infinite Scroll + Marquee Multi-Select + Drag-Out)

    private var fullWaterfallGalleryBody: some View {
        VStack(spacing: 10) {
            HStack(spacing: 10) {
                Text("最近素材")
                    .font(CharkleTheme.text(.caption, weight: .semibold))
                    .lineLimit(1)
                    .foregroundStyle(.white)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 4)
                    .background(Color.white.opacity(0.16), in: Capsule(style: .continuous))

                HStack(spacing: 6) {
                    Image(systemName: "magnifyingglass")
                        .font(.system(size: 11))
                        .foregroundStyle(.white.opacity(0.55))
                    TextField("搜索最近素材…", text: $waterfallSearchQuery)
                        .textFieldStyle(.plain)
                        .font(CharkleTheme.text(.caption))
                        .foregroundStyle(.white)
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                .frame(width: 200)
                .background(Color.white.opacity(0.09), in: Capsule(style: .continuous))

                if !notchSelectedIDs.isEmpty {
                    Text("已框选 \(notchSelectedIDs.count) 项，可直接拖出")
                        .font(CharkleTheme.text(.caption, weight: .semibold))
                        .lineLimit(1)
                        .foregroundStyle(activeBlue)
                        .padding(.horizontal, 9)
                        .padding(.vertical, 4)
                        .background(activeBlue.opacity(0.18), in: Capsule(style: .continuous))
                } else {
                    Text("拖拽空白处可框选多张，支持拖入其他应用或画板")
                        .font(CharkleTheme.text(.caption))
                        .foregroundStyle(.white.opacity(0.48))
                        .lineLimit(1)
                }

                Spacer()

                Button {
                    notchSelectedIDs.removeAll()
                    waterfallSearchQuery = ""
                    onToggleFullGallery(false)
                } label: {
                    HStack(spacing: 4) {
                        Text("收起")
                            .font(CharkleTheme.text(.caption, weight: .semibold))
                            .lineLimit(1)
                        Image(systemName: "chevron.up")
                            .font(.system(size: 9, weight: .bold))
                    }
                    .foregroundStyle(.white.opacity(0.88))
                    .padding(.horizontal, 10)
                    .padding(.vertical, 4)
                    .background(Color.white.opacity(0.12), in: Capsule(style: .continuous))
                }
                .buttonStyle(.plain)
            }

            // Reuses our 120 FPS AppKit VirtualizedMasonryView for infinite scroll + marquee multi-select + multi-item drag-out!
            VirtualizedMasonryView(
                assets: recentAssets,
                assetsRevision: library.assetsRevision ^ waterfallSearchQuery.hashValue,
                folders: library.folders,
                loader: library.thumbnailLoader,
                selectedAssetIDs: $notchSelectedIDs,
                cutAssetIDs: library.cutAssetIDs,
                layoutMode: .verticalMasonry,
                targetColumnWidth: 158,
                topContentInset: 8,
                bottomContentInset: 18,
                heroNamespace: notchHeroNamespace,
                backgroundOverride: Color.black,
                callbacks: MasonryCallbacks(
                    onOpenQuickLook: { asset in
                        onOpenAssetInQuickLook(asset)
                    },
                    onDropExternalInputs: { inputs in
                        let folderID: UUID? = shelfState.targetMode == .folder
                            ? (shelfState.selectedFolderID ?? library.folders.first?.id)
                            : nil
                        let boardID: UUID? = shelfState.targetMode == .activeMoodboard
                            ? (coordinator.activeMoodboardID ?? moodboards.boards.first?.id)
                            : nil
                        Task {
                            let created = await library.ingest(inputs, targetFolderID: folderID, targetBoardID: boardID)
                            if let boardID {
                                await moodboards.reloadActiveBoardIfNeeded(id: boardID)
                                await moodboards.refreshBoards()
                            }
                            coordinator.showToast("已收入 \(max(created.count, inputs.count)) 项素材", icon: "arrow.down.circle.fill")
                        }
                    },
                    onAddToMoodboard: { ids in
                        if let activeID = coordinator.activeMoodboardID ?? moodboards.boards.first?.id {
                            let items = ids.compactMap { library.allAssetsByID[$0] }
                            Task {
                                await moodboards.addAssetsToSpecificBoard(boardID: activeID, assets: items)
                                let title = moodboards.boards.first(where: { $0.id == activeID })?.title ?? "情绪板"
                                coordinator.showToast("已加入「\(title)」(\(items.count) 项)", icon: "rectangle.3.group")
                            }
                        } else {
                            onOpenMainWindow()
                            library.selectedAssetIDs = Set(ids)
                            coordinator.presentMoodboardGenerator(entry: .selection)
                        }
                    },
                    onMoveToFolder: { ids, folderID in
                        Task {
                            await library.moveAssets(ids, toFolderID: folderID)
                            coordinator.showToast("已移动 \(ids.count) 项素材", icon: "folder")
                        }
                    },
                    onTogglePinOffline: { ids, pinned in
                        Task {
                            await library.togglePinOffline(ids: ids, pinned: pinned)
                            coordinator.showToast(
                                pinned ? "已设为始终保留在本地" : "已取消始终保留，将按需管理空间",
                                icon: pinned ? "arrow.down.circle.fill" : "icloud"
                            )
                        }
                    },
                    onCopyColorHex: { hex in
                        let pb = NSPasteboard.general
                        pb.clearContents()
                        pb.setString(hex, forType: .string)
                        coordinator.showToast("已复制色值 \(hex)", icon: "paintpalette")
                    },
                    onRevealInFinder: { assetID in
                        Task {
                            let ok = await library.revealInFinder(assetID: assetID)
                            if !ok {
                                coordinator.showToast("无法定位该素材的本地文件", icon: "exclamationmark.triangle", tone: .warning)
                            }
                        }
                    },
                    onCopyAssets: { ids in
                        Task {
                            let count = await library.copyAssetsToPasteboard(ids)
                            coordinator.showToast("已拷贝 \(count) 项素材到剪贴板", icon: "doc.on.doc")
                        }
                    },
                    onCutAssets: { ids in
                        Task {
                            let count = await library.cutAssets(ids)
                            coordinator.showToast("已剪切 \(count) 项素材", icon: "scissors")
                        }
                    },
                    onPasteIntoCurrentFolder: {
                        onCollectClipboard()
                    },
                    onRetagAssets: { ids in
                        Task {
                            _ = await library.retagAssetsWithCloudAI(ids: ids)
                            coordinator.showToast("已完成 AI 重新打标 (\(ids.count) 项)", icon: "sparkles")
                        }
                    },
                    onTrashAssets: { ids in
                        notchSelectedIDs.subtract(ids)
                        Task {
                            await library.trashAssets(ids)
                            coordinator.showToast("已移至废纸篓 (\(ids.count) 项)", icon: "trash")
                        }
                    },
                    onRestoreAssets: { ids in
                        Task {
                            await library.restoreAssets(ids)
                            coordinator.showToast("已放回原处 (\(ids.count) 项)", icon: "arrow.uturn.backward")
                        }
                    },
                    onPermanentlyDeleteAssets: { ids in
                        notchSelectedIDs.subtract(ids)
                        Task {
                            await library.permanentlyDeleteAssets(ids)
                            coordinator.showToast("已彻底删除 \(ids.count) 项素材", icon: "trash.slash")
                        }
                    },
                    onResolveDragFileURL: onResolveDragFileURL
                )
            )
            .clipShape(RoundedRectangle(cornerRadius: CharkleTheme.Radius.settingsOuter, style: .continuous))
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    // MARK: - Drop Well & Helpers

    private var dropWellRow: some View {
        ZStack {
            let wellShape = RoundedRectangle(cornerRadius: CharkleTheme.Radius.cardOuter, style: .continuous)
            wellShape
                .fill(shelfState.isDropTargeted ? activeBlue.opacity(0.24) : Color.white.opacity(0.06))
                .overlay(
                    wellShape.strokeBorder(
                        shelfState.isDropTargeted ? activeBlue.opacity(0.92) : Color.white.opacity(0.14),
                        style: StrokeStyle(
                            lineWidth: shelfState.isDropTargeted ? 1.5 : CharkleTheme.hairlineWidth,
                            dash: shelfState.isDropTargeted ? [] : [5, 4]
                        )
                    )
                )

            if let prompt = coordinator.pendingVersionStackPrompt, prompt.source == .notchShelf {
                notchVersionStackPromptBar(prompt)
            } else if let processing = shelfState.processingMessage {
                HStack(spacing: 10) {
                    ProgressView().controlSize(.small).tint(.white)
                    Text(processing)
                        .font(CharkleTheme.text(.caption, weight: .semibold))
                        .foregroundStyle(.white)
                }
            } else if let banner = shelfState.statusBanner {
                HStack(spacing: 8) {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: 15))
                        .foregroundStyle(Color.green)
                    Text(banner)
                        .font(CharkleTheme.text(.body, weight: .semibold))
                        .foregroundStyle(.white)
                }
            } else if shelfState.isDropTargeted {
                HStack(spacing: 10) {
                    Image(systemName: "arrow.down.circle.fill")
                        .font(.system(size: 18))
                        .foregroundStyle(activeBlue)
                    VStack(alignment: .leading, spacing: 1) {
                        Text("松开立即收藏 \(max(1, shelfState.dragItemCount)) 项素材")
                            .font(CharkleTheme.text(.body, weight: .semibold))
                            .foregroundStyle(.white)
                        Text(targetDropHint)
                            .font(CharkleTheme.text(.caption))
                            .foregroundStyle(.white.opacity(0.74))
                    }
                }
            } else if let detectedLink = shelfState.clipboardLink {
                Button(action: onCollectClipboard) {
                    HStack(spacing: 10) {
                        Image(systemName: "link.badge.plus")
                            .font(.system(size: 16, weight: .semibold))
                            .foregroundStyle(activeBlue)
                        Text(detectedLink.notchHintLabel)
                            .font(CharkleTheme.text(.caption, weight: .medium))
                            .foregroundStyle(.white)
                            .lineLimit(1)
                        Spacer()
                        Text("保存")
                            .font(CharkleTheme.text(.caption, weight: .semibold))
                            .foregroundStyle(.white)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 4)
                            .background(activeBlue, in: Capsule(style: .continuous))
                    }
                    .padding(.horizontal, 14)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            } else {
                Button(action: onCollectClipboard) {
                    HStack(spacing: 9) {
                        Image(systemName: "square.and.arrow.down.on.square")
                            .font(.system(size: 15, weight: .light))
                            .foregroundStyle(.white.opacity(0.72))
                        Text("拖入文件、整个文件夹或任意网页链接，或按 ⌘V 粘贴")
                            .font(CharkleTheme.text(.caption, weight: .medium))
                            .foregroundStyle(.white.opacity(0.84))
                            .lineLimit(1)
                        Spacer()
                    }
                    .padding(.horizontal, 14)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
    }

    private func notchVersionStackPromptBar(_ prompt: AppCoordinatorStore.PendingVersionStackPrompt) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "square.stack.3d.up.fill")
                .font(.system(size: 13.5, weight: .semibold))
                .foregroundStyle(activeBlue)

            Text("叠入《\(prompt.candidate.targetTitle)》v\(prompt.candidate.nextVersionNumber)？")
                .font(CharkleTheme.text(.caption, weight: .semibold))
                .monospacedDigit()
                .foregroundStyle(.white)
                .lineLimit(1)

            TextField(
                "修改人",
                text: Binding(
                    get: { coordinator.pendingVersionStackPrompt?.editorNameDraft ?? "" },
                    set: { coordinator.pendingVersionStackPrompt?.editorNameDraft = $0 }
                )
            )
            .textFieldStyle(.plain)
            .font(CharkleTheme.text(.caption))
            .foregroundStyle(.white)
            .padding(.horizontal, 7)
            .padding(.vertical, 4)
            .frame(width: 72)
            .background(Color.white.opacity(0.10), in: RoundedRectangle(cornerRadius: CharkleTheme.Radius.xs, style: .continuous))
            .onSubmit {
                Task { _ = await library.confirmPendingVersionStackPrompt(coordinator: coordinator) }
            }

            TextField(
                "备注（回车秒叠入）",
                text: Binding(
                    get: { coordinator.pendingVersionStackPrompt?.changeNoteDraft ?? "" },
                    set: { coordinator.pendingVersionStackPrompt?.changeNoteDraft = $0 }
                )
            )
            .textFieldStyle(.plain)
            .font(CharkleTheme.text(.caption))
            .foregroundStyle(.white)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .frame(maxWidth: .infinity)
            .background(Color.white.opacity(0.10), in: RoundedRectangle(cornerRadius: CharkleTheme.Radius.xs, style: .continuous))
            .onSubmit {
                Task { _ = await library.confirmPendingVersionStackPrompt(coordinator: coordinator) }
            }

            Button {
                Task { _ = await library.confirmPendingVersionStackPrompt(coordinator: coordinator) }
            } label: {
                Text("叠入 ↵")
                    .font(CharkleTheme.text(.caption, weight: .semibold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 9)
                    .padding(.vertical, 4)
                    .background(activeBlue, in: Capsule(style: .continuous))
            }
            .buttonStyle(.plain)

            Button {
                library.dismissPendingVersionStackPrompt(coordinator: coordinator, announce: true)
            } label: {
                Text("独立")
                    .font(CharkleTheme.text(.caption, weight: .medium))
                    .foregroundStyle(.white.opacity(0.75))
                    .padding(.horizontal, 7)
                    .padding(.vertical, 4)
                    .background(Color.white.opacity(0.10), in: Capsule(style: .continuous))
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 12)
    }

    private func makeDragItemProvider(for ids: [UUID]) -> NSItemProvider {
        let provider = NSItemProvider()
        let encoded = CharkleDragIdentifiers.encode(assetIDs: ids)
        provider.registerDataRepresentation(forTypeIdentifier: CharkleDragIdentifiers.internalPasteboardType.rawValue, visibility: .ownProcess) { completion in
            completion(Data(encoded.utf8), nil)
            return nil
        }
        provider.registerDataRepresentation(forTypeIdentifier: UTType.plainText.identifier, visibility: .all) { completion in
            completion(Data(encoded.utf8), nil)
            return nil
        }
        // Use data representation for UTType.fileURL (never registerFileRepresentation with empty options,
        // which causes Foundation's loadInPlaceFileRepresentation to return nil and crash SwiftUI's
        // PasteboardUtility.loadFileSystemItem with SIGTRAP on macOS 26/27).
        if let firstID = ids.first,
           let fileURL = onResolveDragFileURL(firstID),
           fileURL.isFileURL,
           FileManager.default.fileExists(atPath: fileURL.path) {
            provider.registerDataRepresentation(forTypeIdentifier: UTType.fileURL.identifier, visibility: .all) { completion in
                completion(fileURL.dataRepresentation, nil)
                return nil
            }
        }
        return provider
    }

    private func notchCompactToolButton(title: String, icon: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 5) {
                Image(systemName: icon)
                    .font(.system(size: 11.5, weight: .medium))
                Text(title)
                    .font(CharkleTheme.text(.caption, weight: .medium))
                    .lineLimit(1)
            }
            .foregroundStyle(.white.opacity(0.88))
            .padding(.horizontal, 9)
            .padding(.vertical, 5.5)
            .background(Color.white.opacity(0.09), in: RoundedRectangle(cornerRadius: CharkleTheme.Radius.chip, style: .continuous))
            .fixedSize(horizontal: true, vertical: false)
        }
        .buttonStyle(CharkleTactileButtonStyle())
    }

    @ViewBuilder
    private var destinationDetailChip: some View {
        switch shelfState.targetMode {
        case .inbox:
            Text("\(library.inboxCount) 项")
                .font(CharkleTheme.text(.caption, weight: .medium, design: .rounded))
                .monospacedDigit()
                .lineLimit(1)
                .foregroundStyle(.white.opacity(0.68))
                .padding(.horizontal, 7)
                .padding(.vertical, 4)
                .background(Color.white.opacity(0.06), in: RoundedRectangle(cornerRadius: CharkleTheme.Radius.sm, style: .continuous))
                .fixedSize(horizontal: true, vertical: true)
        case .folder:
            Menu {
                CharkleHierarchicalFolderMenuContent(
                    folders: library.folders,
                    includeInbox: false,
                    selectedFolderID: shelfState.selectedFolderID ?? library.folderHierarchyRoots.first?.id,
                    highlightSelection: true,
                    parentSelfPrefix: "选择"
                ) { folderID in
                    if let folderID {
                        shelfState.selectedFolderID = folderID
                    }
                }
            } label: {
                HStack(spacing: 3) {
                    Text(selectedFolderName)
                        .font(CharkleTheme.text(.caption, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.92))
                        .lineLimit(1)
                        .truncationMode(.tail)
                    CharkleDropdownChevron(size: 8, color: .white.opacity(0.62))
                }
                .padding(.horizontal, 7)
                .padding(.vertical, 4)
                .background(Color.white.opacity(0.11), in: RoundedRectangle(cornerRadius: CharkleTheme.Radius.sm, style: .continuous))
            }
            .menuStyle(.button)
            .buttonStyle(CharkleMenuTriggerButtonStyle())
            .menuIndicator(.hidden)
            .fixedSize(horizontal: false, vertical: true)
        case .activeMoodboard:
            if moodboards.boards.isEmpty {
                HStack(spacing: 4) {
                    Circle().fill(Color.white.opacity(0.38)).frame(width: 5, height: 5)
                    Text("未选择情绪板")
                        .font(CharkleTheme.text(.caption, weight: .medium))
                        .foregroundStyle(.white.opacity(0.68))
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
                .padding(.horizontal, 7)
                .padding(.vertical, 4)
                .background(Color.white.opacity(0.06), in: RoundedRectangle(cornerRadius: CharkleTheme.Radius.sm, style: .continuous))
                .fixedSize(horizontal: false, vertical: true)
            } else {
                Menu {
                    ForEach(moodboards.boards) { board in
                        Button {
                            coordinator.activeMoodboardID = board.id
                        } label: {
                            if (coordinator.activeMoodboardID ?? moodboards.boards.first?.id) == board.id {
                                Label(board.title, systemImage: "checkmark")
                            } else {
                                Text(board.title)
                            }
                        }
                    }
                } label: {
                    HStack(spacing: 4) {
                        Circle().fill(Color.green).frame(width: 5, height: 5)
                        Text(activeBoardTitle)
                            .font(CharkleTheme.text(.caption, weight: .semibold))
                            .foregroundStyle(.white.opacity(0.92))
                            .lineLimit(1)
                            .truncationMode(.tail)
                        CharkleDropdownChevron(size: 8, color: .white.opacity(0.62))
                    }
                    .padding(.horizontal, 7)
                    .padding(.vertical, 4)
                    .background(Color.white.opacity(0.11), in: RoundedRectangle(cornerRadius: CharkleTheme.Radius.sm, style: .continuous))
                }
                .menuStyle(.button)
                .buttonStyle(CharkleMenuTriggerButtonStyle())
                .menuIndicator(.hidden)
                .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func targetSegment(_ mode: NotchTargetMode, label: String) -> some View {
        let isSelected = shelfState.targetMode == mode
        let segmentRadius = CharkleTheme.Radius.concentricInner(outer: CharkleTheme.Radius.chip, padding: 2)
        return Button {
            withAnimation(CharkleMotion.accessible(CharkleMotion.settleStrong, reduced: reduceMotion)) {
                shelfState.targetMode = mode
                if mode == .folder && shelfState.selectedFolderID == nil {
                    shelfState.selectedFolderID = library.folderHierarchyRoots.first?.id ?? library.folders.first?.id
                }
                if mode == .activeMoodboard && coordinator.activeMoodboardID == nil {
                    coordinator.activeMoodboardID = moodboards.boards.first?.id
                }
            }
        } label: {
            Text(label)
                .font(CharkleTheme.text(.caption, weight: isSelected ? .semibold : .medium))
                .lineLimit(1)
                .foregroundStyle(isSelected ? .white : .white.opacity(0.62))
                .padding(.horizontal, 7)
                .padding(.vertical, 3.5)
                .background {
                    if isSelected {
                        RoundedRectangle(cornerRadius: segmentRadius, style: .continuous)
                            .fill(Color.white.opacity(0.18))
                            .matchedGeometryEffect(id: "notch-target-pill", in: targetPillNamespace)
                    }
                }
                .fixedSize(horizontal: true, vertical: false)
        }
        .buttonStyle(.plain)
    }

    private var targetDropHint: String {
        switch shelfState.targetMode {
        case .inbox: "将存入收件箱待整理"
        case .folder: "将直接存入「\(selectedFolderName)」"
        case .activeMoodboard: "将收录素材并直接加入「\(activeBoardTitle)」"
        }
    }
}

/// Isolates per-card hover state so hovering recent items inside the Notch Shelf
/// does not re-evaluate `NotchShelfView.body` or recompute `recentAssets`.
private struct NotchRecentFilmstripCard: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    let asset: AssetRecord
    let loader: ThumbnailImageLoader
    let isMinimalCaptureOnly: Bool
    let onCopyAsset: () -> Void
    let onOpenAssetInQuickLook: () -> Void
    let onToggleFullGallery: () -> Void
    let makeDragProvider: () -> NSItemProvider

    @State private var isHovered: Bool = false

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            ZStack(alignment: .topTrailing) {
                AssetThumbnailSurface(
                    asset: asset,
                    loader: loader,
                    tier: .grid520,
                    cornerRadius: CharkleTheme.Radius.popoverInner
                )
                .frame(width: 96, height: 82)
                .overlay(
                    RoundedRectangle(cornerRadius: CharkleTheme.Radius.popoverInner, style: .continuous)
                        .strokeBorder(
                            Color.white.opacity(isHovered ? 0.38 : 0.12),
                            lineWidth: isHovered ? 1.25 : CharkleTheme.hairlineWidth
                        )
                )

                if isHovered {
                    HStack(spacing: 4) {
                        Button(action: onCopyAsset) {
                            Image(systemName: "doc.on.doc")
                                .font(.system(size: 9.5, weight: .semibold))
                                .foregroundStyle(.white)
                                .frame(width: 22, height: 22)
                                .background(Color.black.opacity(0.72), in: Circle())
                        }
                        .buttonStyle(.plain)
                        .help("拷贝到剪贴板")

                        Button(action: onOpenAssetInQuickLook) {
                            Image(systemName: asset.isExternalWebLink ? "safari" : "eye")
                                .font(.system(size: 9.5, weight: .semibold))
                                .foregroundStyle(.white)
                                .frame(width: 22, height: 22)
                                .background(Color.black.opacity(0.72), in: Circle())
                        }
                        .buttonStyle(.plain)
                        .help(asset.isExternalWebLink ? "在默认浏览器中打开" : "在主窗中沉浸预览")
                    }
                    .padding(5)
                    .transition(.opacity)
                }
            }
            .contentShape(RoundedRectangle(cornerRadius: CharkleTheme.Radius.popoverInner, style: .continuous))
            .onTapGesture {
                if isMinimalCaptureOnly {
                    onOpenAssetInQuickLook()
                } else {
                    onToggleFullGallery()
                }
            }
            .onHover { hovering in
                withAnimation(CharkleMotion.accessible(CharkleMotion.hoverPress, reduced: reduceMotion)) {
                    if isHovered != hovering {
                        isHovered = hovering
                    }
                }
            }
            .onDrag(makeDragProvider)

            Text(asset.title)
                .font(CharkleTheme.text(.caption, weight: .medium))
                .foregroundStyle(.white.opacity(0.68))
                .lineLimit(1)
                .frame(width: 96, alignment: .leading)
        }
    }
}
