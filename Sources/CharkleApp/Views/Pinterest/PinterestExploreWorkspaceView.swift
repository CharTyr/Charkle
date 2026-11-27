import AppKit
import CharkleCore
import SwiftUI

/// Full-bleed macOS Pinterest Infinite Space Workspace:
/// - Silky 120Hz omnidirectional 2D infinite canvas with anchor-locked continuous zoom
/// - Shopping-cart Collection Tray ("托盘") with click-to-jump-to-Pin-detail, selective remove, and batch import
/// - Floating Pinterest Pin Detail overlay with native Pinterest "类似素材 / More like this" grid underneath
/// - Batch Collection Import by Pinterest Board (automatically organizing into per-board Charkle folders)
public struct PinterestExploreWorkspaceView: View {
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.charkleAccentSource) private var accentSource

    @Bindable var controller: PinterestExploreController
    let library: LibraryStore
    let coordinator: AppCoordinatorStore
    let isSidebarVisible: Bool
    let onToggleSidebar: () -> Void

    @State private var cameraScale: CGFloat = 0.90
    @State private var cameraCommand = PinterestCameraCommandMac()
    @State private var excludedCanvasRects: [CGRect] = []
    @State private var trayTargetFolderID: UUID? = nil
    @State private var trayExtraTagsText: String = ""
    @State private var isSingleImporting: Bool = false

    private var activeAccent: Color {
        CharkleTheme.accent(for: colorScheme, source: accentSource)
    }

    private var activeNSAccent: NSColor {
        NSColor(activeAccent)
    }

    public init(
        controller: PinterestExploreController,
        library: LibraryStore,
        coordinator: AppCoordinatorStore,
        isSidebarVisible: Bool = true,
        onToggleSidebar: @escaping () -> Void = {}
    ) {
        self.controller = controller
        self.library = library
        self.coordinator = coordinator
        self.isSidebarVisible = isSidebarVisible
        self.onToggleSidebar = onToggleSidebar
    }

    public var body: some View {
        ZStack {
            CharkleTheme.galleryGround(for: colorScheme)
                .ignoresSafeArea(.all)

            if controller.isSignedIn {
                signedInWorkspace
            } else if controller.isCheckingSession {
                VStack(spacing: 12) {
                    ProgressView()
                        .controlSize(.regular)
                    Text("正在检查 Pinterest 登录状态…")
                        .font(CharkleTheme.text(.body))
                        .foregroundStyle(CharkleTheme.secondaryInk(for: colorScheme))
                }
            } else {
                signedOutWelcomeStage
            }

            // Floating Pin Detail Overlay (full Pin detail + Pinterest Similar Pins grid underneath)
            if let activePin = controller.activeDetailPin {
                PinterestPinDetailOverlayMac(
                    controller: controller,
                    pin: activePin,
                    isSingleImporting: isSingleImporting,
                    accent: activeAccent,
                    isImageExpanded: Binding(
                        get: { coordinator.isPinterestDetailImageExpanded },
                        set: { coordinator.isPinterestDetailImageExpanded = $0 }
                    ),
                    onClose: {
                        coordinator.isPinterestDetailImageExpanded = false
                        withAnimation(CharkleMotion.accessible(CharkleMotion.exitSm, reduced: reduceMotion)) {
                            controller.closePinDetail()
                        }
                    },
                    onToggleTray: { pin in
                        let added = controller.toggleTray(pin)
                        coordinator.showToast(
                            added ? "已加入采集托盘（共 \(controller.trayCount) 项）" : "已从托盘移出",
                            icon: added ? "cart.badge.plus" : "cart.badge.minus"
                        )
                    },
                    onImportSingle: { pin in
                        importSinglePin(pin)
                    },
                    onExploreSimilarInSpace: { pin in
                        Task { await controller.exploreSimilarInInfiniteSpace(pin) }
                    }
                )
                .ignoresSafeArea(.all)
                .zIndex(80)
                .transition(.opacity.combined(with: .scale(scale: 0.97)))
            }
        }
        .ignoresSafeArea(.container, edges: .top)
        .task {
            await controller.bootstrap(engine: library.engine)
        }
        .sheet(isPresented: $controller.isLoginSheetPresented) {
            PinterestLoginSheetMac(
                onVerifySession: {
                    let ok = await controller.handleLoginCompleted(engine: library.engine)
                    if ok, let account = controller.account {
                        coordinator.showToast("已登录 Pinterest（\(account.displayName)）", icon: "checkmark.circle.fill", tone: .success)
                    }
                    return ok
                },
                onDismiss: {
                    controller.isLoginSheetPresented = false
                }
            )
        }
        .sheet(isPresented: $controller.isBoardImportSheetPresented) {
            PinterestBoardImportSheetMac(
                controller: controller,
                engine: library.engine,
                folders: library.flattenedFolderHierarchy,
                accent: activeAccent,
                onImportCompleted: { report in
                    Task {
                        await library.refreshAll()
                    }
                    showBoardsImportToast(report)
                }
            )
        }
        .onExitCommand {
            if coordinator.isPinterestDetailImageExpanded {
                coordinator.isPinterestDetailImageExpanded = false
            } else if controller.activeDetailPin != nil {
                controller.closePinDetail()
            } else if controller.isTrayExpanded {
                controller.isTrayExpanded = false
            }
        }
    }

    // MARK: - Signed-In Infinite Spatial Workspace

    private var signedInWorkspace: some View {
        ZStack {
            // 1. 120Hz Infinite 2D Omnidirectional Canvas
            PinterestInfiniteCanvasMac(
                cards: controller.layout.cards,
                layoutRevision: controller.layoutRevision,
                trayPinIDs: Set(controller.trayPins.map(\.id)),
                importedPinIDs: controller.importedPinIDs,
                fastPickMode: controller.fastPickMode,
                isDark: colorScheme == .dark,
                accentColor: activeNSAccent,
                isInteractionSuspended: coordinator.isModalOverlayPresented || controller.activeDetailPin != nil || controller.isLoginSheetPresented || controller.isBoardImportSheetPresented,
                excludedCanvasRects: excludedCanvasRects,
                cameraCommand: cameraCommand,
                onOpenDetail: { pin in
                    withAnimation(CharkleMotion.accessible(CharkleMotion.enterMd, reduced: reduceMotion)) {
                        controller.openPinDetail(pin, resetStack: true)
                    }
                },
                onToggleTray: { pin in
                    let added = controller.toggleTray(pin)
                    coordinator.showToast(
                        added ? "已加入托盘（共 \(controller.trayCount) 项）" : "已移出托盘",
                        icon: added ? "cart.badge.plus" : "minus.circle"
                    )
                },
                onCameraChanged: { cam, visibleWorld in
                    if abs(cam.scale - cameraScale) > 0.008 {
                        cameraScale = cam.scale
                    }
                    controller.updateCameraViewport(visibleWorldRect: visibleWorld, scale: cam.scale)
                }
            )
            .ignoresSafeArea(.all)

            // Loading / Empty / Error centered feedback over infinite ground
            if controller.isLoadingFeed && controller.layout.cards.isEmpty {
                VStack(spacing: 12) {
                    ProgressView()
                        .controlSize(.regular)
                    Text("正在铺展 Pinterest 无限灵感空间…")
                        .font(CharkleTheme.text(.body, weight: .medium))
                        .foregroundStyle(CharkleTheme.secondaryInk(for: colorScheme))
                }
                .padding(.horizontal, 20)
                .padding(.vertical, 16)
                .charkleLiquidGlass(.regular, in: RoundedRectangle(cornerRadius: CharkleTheme.Radius.popoverOuter, style: .continuous))
            } else if let error = controller.errorMessage, controller.layout.cards.isEmpty {
                VStack(spacing: 12) {
                    Image(systemName: "exclamationmark.triangle")
                        .font(.system(size: 24, weight: .medium))
                        .foregroundStyle(CharkleTheme.warning(for: colorScheme))
                    Text(error)
                        .font(CharkleTheme.text(.body))
                        .foregroundStyle(CharkleTheme.secondaryInk(for: colorScheme))
                        .multilineTextAlignment(.center)
                        .frame(maxWidth: 340)
                    HStack(spacing: 10) {
                        Button("重试加载") {
                            Task { await controller.reloadFeed() }
                        }
                        .buttonStyle(CharkleButtonStyle(.subtle, size: .sm, cornerRadius: 999))

                        if controller.needsReauthentication {
                            Button("重新登录验证") {
                                controller.isLoginSheetPresented = true
                            }
                            .buttonStyle(CharkleButtonStyle(.accent, size: .sm, cornerRadius: 999))
                        }
                    }
                }
                .padding(22)
                .charkleLiquidGlass(.regular, in: RoundedRectangle(cornerRadius: CharkleTheme.Radius.popoverOuter, style: .continuous))
                .pinterestExcludeHitTestMac()
                .zIndex(15)
            }

            // 2. Top Floating Liquid Glass Toolbar (with window drag clearance)
            VStack(spacing: 0) {
                topFloatingHeader
                    .pinterestExcludeHitTestMac()
                Spacer(minLength: 0)
            }
            .zIndex(20)

            // 3. Bottom Chrome: Mode Pill (left) + Shopping-Cart Collection Tray (center/right)
            VStack(spacing: 10) {
                Spacer(minLength: 0)

                if controller.isTrayExpanded {
                    expandedTrayDrawer
                        .pinterestExcludeHitTestMac()
                        .padding(.horizontal, 18)
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                }

                HStack(alignment: .center, spacing: 12) {
                    bottomModePill
                        .pinterestExcludeHitTestMac()

                    if controller.isLoadingMore {
                        HStack(spacing: 6) {
                            ProgressView()
                                .controlSize(.mini)
                            Text("向外拓展更多灵感…")
                                .font(CharkleTheme.text(.caption, weight: .medium))
                                .foregroundStyle(CharkleTheme.secondaryInk(for: colorScheme))
                        }
                        .padding(.horizontal, 11)
                        .padding(.vertical, 6)
                        .charkleLiquidGlass(.regular, in: Capsule(style: .continuous))
                    }

                    Spacer(minLength: 8)

                    collapsedTrayCapsule
                        .pinterestExcludeHitTestMac()
                }
                .padding(.horizontal, 18)
                .padding(.bottom, 16)
            }
            .zIndex(20)
        }
        .ignoresSafeArea(.all)
        .coordinateSpace(name: "pinterestMacCanvas")
        .onPreferenceChange(PinterestMacHitExclusionKey.self) { rects in
            excludedCanvasRects = rects
        }
    }

    // MARK: - Top Floating Header

    private var topFloatingHeader: some View {
        ZStack {
            CharkleWindowDragArea()
                .frame(height: 58)

            HStack(spacing: 10) {
                if !isSidebarVisible {
                    Button(action: onToggleSidebar) {
                        Image(systemName: "sidebar.left")
                            .font(.system(size: 13.5, weight: .semibold))
                            .foregroundStyle(.primary)
                            .frame(width: 34, height: 34)
                            .contentShape(Circle())
                    }
                    .buttonStyle(.plain)
                    .charkleLiquidGlass(.regular, in: Circle(), interactive: true)
                    .help("展开左侧边栏")
                }

                // Feed Source & Boards Switcher
                HStack(spacing: 6) {
                    if case .similar = controller.feedSource {
                        Button {
                            Task { await controller.switchSource(.homeFeed) }
                        } label: {
                            HStack(spacing: 4) {
                                Image(systemName: "chevron.left")
                                    .font(.system(size: 11, weight: .semibold))
                                Text("返回推荐")
                                    .font(CharkleTheme.text(.caption, weight: .medium))
                            }
                            .padding(.horizontal, 9)
                            .frame(height: 28)
                        }
                        .buttonStyle(.plain)
                        .background(Color.primary.opacity(0.06), in: Capsule())
                    }

                    Menu {
                        Button {
                            Task { await controller.switchSource(.homeFeed) }
                        } label: {
                            Label("首页推荐灵感", systemImage: "sparkles")
                        }

                        if !controller.boards.isEmpty {
                            Divider()
                            Section("我的 Pinterest 画板") {
                                ForEach(controller.boards) { board in
                                    Button {
                                        Task { await controller.switchSource(.board(board)) }
                                    } label: {
                                        Text("\(board.name) (\(board.pinCount))")
                                    }
                                }
                            }
                        }

                        Divider()
                        Button {
                            controller.isBoardImportSheetPresented = true
                            Task { await controller.refreshBoards() }
                        } label: {
                            Label("批量导入收藏（按画板分目录）…", systemImage: "square.and.arrow.down.on.square")
                        }
                    } label: {
                        HStack(spacing: 5) {
                            Image(systemName: "sparkles")
                                .font(.system(size: 12, weight: .semibold))
                                .foregroundStyle(activeAccent)
                            Text(controller.feedSource.displayTitle)
                                .font(CharkleTheme.text(.body, weight: .semibold))
                                .foregroundStyle(.primary.opacity(0.92))
                                .lineLimit(1)
                                .truncationMode(.tail)
                                .frame(maxWidth: 160, alignment: .leading)
                            CharkleDropdownChevron(size: 8.5)
                        }
                        .padding(.horizontal, 11)
                        .frame(height: 30)
                    }
                    .menuStyle(.button)
                    .buttonStyle(CharkleMenuTriggerButtonStyle())
                    .menuIndicator(.hidden)
                    .fixedSize()
                }
                .padding(.horizontal, 4)
                .frame(height: 36)
                .charkleLiquidGlass(.regular, in: Capsule(style: .continuous), interactive: true)

                // Search Pinterest Input Capsule
                HStack(spacing: 6) {
                    Image(systemName: "magnifyingglass")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(CharkleTheme.secondaryInk(for: colorScheme))
                    TextField("搜索 Pinterest 灵感…", text: $controller.searchText)
                        .textFieldStyle(.plain)
                        .font(CharkleTheme.text(.body))
                        .frame(minWidth: 140, maxWidth: 260)
                        .onSubmit {
                            Task { await controller.submitSearch() }
                        }
                    if !controller.searchText.isEmpty {
                        Button {
                            controller.searchText = ""
                            Task { await controller.switchSource(.homeFeed) }
                        } label: {
                            Image(systemName: "xmark.circle.fill")
                                .font(.system(size: 12))
                                .foregroundStyle(CharkleTheme.secondaryInk(for: colorScheme).opacity(0.72))
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, 12)
                .frame(height: 36)
                .charkleLiquidGlass(.regular, in: Capsule(style: .continuous), interactive: true)

                Spacer(minLength: 8)

                // Batch Import Saved Pinterest Collections by Board
                Button {
                    controller.isBoardImportSheetPresented = true
                    Task { await controller.refreshBoards() }
                } label: {
                    HStack(spacing: 5) {
                        Image(systemName: "square.and.arrow.down.on.square")
                            .font(.system(size: 12, weight: .semibold))
                        Text("导入画板收藏")
                            .font(CharkleTheme.text(.caption, weight: .semibold))
                    }
                    .foregroundStyle(activeAccent)
                    .padding(.horizontal, 12)
                    .frame(height: 36)
                }
                .buttonStyle(.plain)
                .charkleLiquidGlass(.regular, in: Capsule(style: .continuous), interactive: true)
                .help("批量导入 Pinterest 收藏，自动按画板分目录存入素材库")

                // Zoom Controls & Reset Camera Capsule
                HStack(spacing: 2) {
                    Button {
                        cameraCommand = PinterestCameraCommandMac(action: .zoomBy(0.78))
                    } label: {
                        Image(systemName: "minus")
                            .font(.system(size: 11, weight: .semibold))
                            .frame(width: 26, height: 28)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .help("缩小视野")

                    Button {
                        cameraCommand = PinterestCameraCommandMac(action: .resetCenter)
                    } label: {
                        Text("\(Int((cameraScale * 100).rounded()))%")
                            .font(CharkleTheme.text(.caption, weight: .semibold).monospacedDigit())
                            .frame(minWidth: 42, minHeight: 28)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .help("回到中心并重置缩放")

                    Button {
                        cameraCommand = PinterestCameraCommandMac(action: .zoomBy(1.28))
                    } label: {
                        Image(systemName: "plus")
                            .font(.system(size: 11, weight: .semibold))
                            .frame(width: 26, height: 28)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .help("放大视野")
                }
                .padding(.horizontal, 4)
                .frame(height: 36)
                .charkleLiquidGlass(.regular, in: Capsule(style: .continuous), interactive: true)

                // Account Menu Capsule
                Menu {
                    if let account = controller.account {
                        Text("\(account.displayName) (@\(account.username))")
                        Divider()
                    }
                    Button {
                        Task { await controller.reloadFeed() }
                    } label: {
                        Label("刷新当前灵感空间", systemImage: "arrow.clockwise")
                    }
                    Button {
                        controller.isBoardImportSheetPresented = true
                        Task { await controller.refreshBoards() }
                    } label: {
                        Label("批量导入画板收藏…", systemImage: "square.and.arrow.down.on.square")
                    }
                    Button {
                        controller.isLoginSheetPresented = true
                    } label: {
                        Label("打开 Pinterest 登录 / 验证窗口", systemImage: "person.crop.circle")
                    }
                    Divider()
                    Button(role: .destructive) {
                        Task {
                            await controller.signOut()
                            coordinator.showToast("已退出 Pinterest 账号", icon: "rectangle.portrait.and.arrow.right")
                        }
                    } label: {
                        Label("退出 Pinterest 账号", systemImage: "rectangle.portrait.and.arrow.right")
                    }
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "person.crop.circle.fill")
                            .font(.system(size: 15))
                            .foregroundStyle(activeAccent)
                        if let account = controller.account {
                            Text(account.displayName)
                                .font(CharkleTheme.text(.caption, weight: .medium))
                                .foregroundStyle(.primary.opacity(0.92))
                                .lineLimit(1)
                                .frame(maxWidth: 96, alignment: .leading)
                        }
                    }
                    .padding(.horizontal, 10)
                    .frame(height: 36)
                }
                .menuStyle(.button)
                .buttonStyle(CharkleMenuTriggerButtonStyle())
                .menuIndicator(.hidden)
                .fixedSize()
                .charkleLiquidGlass(.regular, in: Capsule(style: .continuous), interactive: true)
            }
            .padding(.leading, isSidebarVisible ? 16 : 86)
            .padding(.trailing, 16)
            .padding(.top, 10)
        }
    }

    // MARK: - Bottom-Left Mode Switcher Pill (Icon-Only Browse vs. Rapid Cart Pick)

    private var bottomModePill: some View {
        HStack(spacing: 3) {
            modeToggleButton(
                symbol: "hand.draw",
                tooltip: "浏览模式（点击打开条目详情）",
                isActive: !controller.fastPickMode
            ) {
                withAnimation(CharkleMotion.accessible(CharkleMotion.hoverPress, reduced: reduceMotion)) {
                    controller.fastPickMode = false
                }
            }

            modeToggleButton(
                symbol: "cart.badge.plus",
                tooltip: "快选入托盘模式（点击素材直接加入/移出托盘）",
                isActive: controller.fastPickMode
            ) {
                withAnimation(CharkleMotion.accessible(CharkleMotion.hoverPress, reduced: reduceMotion)) {
                    controller.fastPickMode = true
                }
            }
        }
        .padding(4)
        .charkleLiquidGlass(.regular, in: Capsule(style: .continuous), interactive: true)
    }

    private func modeToggleButton(symbol: String, tooltip: String, isActive: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(isActive ? Color.white : CharkleTheme.secondaryInk(for: colorScheme))
                .frame(width: 34, height: 28)
                .background(
                    isActive ? CharkleTheme.accentButtonFill(for: colorScheme, source: accentSource) : Color.clear,
                    in: Capsule(style: .continuous)
                )
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .help(tooltip)
    }

    // MARK: - Floating Shopping-Cart Collection Tray ("托盘")

    private var collapsedTrayCapsule: some View {
        HStack(spacing: 10) {
            Button {
                withAnimation(CharkleMotion.accessible(CharkleMotion.drawerEase, reduced: reduceMotion)) {
                    controller.isTrayExpanded.toggle()
                }
            } label: {
                HStack(spacing: 9) {
                    if !controller.trayPins.isEmpty {
                        HStack(spacing: -8) {
                            ForEach(controller.trayPins.prefix(4)) { pin in
                                PinterestRemoteThumbMac(url: pin.thumbnailURL, dominantHex: pin.dominantColorHex, maxPixels: 160)
                                    .frame(width: 24, height: 24)
                                    .clipShape(RoundedRectangle(cornerRadius: CharkleTheme.Radius.sm, style: .continuous))
                                    .overlay(
                                        RoundedRectangle(cornerRadius: CharkleTheme.Radius.sm, style: .continuous)
                                            .strokeBorder(CharkleTheme.surfaceElevated(for: colorScheme), lineWidth: 1.5)
                                    )
                            }
                        }
                    } else {
                        Image(systemName: "cart")
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(CharkleTheme.secondaryInk(for: colorScheme))
                    }

                    Text(controller.trayCount > 0 ? "采集托盘 (\(controller.trayCount))" : "采集托盘")
                        .font(CharkleTheme.text(.body, weight: .semibold).monospacedDigit())

                    Image(systemName: controller.isTrayExpanded ? "chevron.down" : "chevron.up")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(CharkleTheme.secondaryInk(for: colorScheme))
                }
                .padding(.leading, 12)
                .padding(.trailing, controller.trayCount > 0 ? 6 : 12)
                .frame(height: 38)
                .contentShape(Capsule())
            }
            .buttonStyle(.plain)

            if controller.trayCount > 0 && !controller.isTrayExpanded {
                Button {
                    batchImportSelectedTray()
                } label: {
                    HStack(spacing: 5) {
                        if controller.isImportingTray {
                            ProgressView()
                                .controlSize(.mini)
                        } else {
                            Image(systemName: "square.and.arrow.down")
                                .font(.system(size: 11.5, weight: .semibold))
                        }
                        Text(controller.isImportingTray ? "入库中…" : "批量入库")
                            .font(CharkleTheme.text(.caption, weight: .semibold))
                    }
                    .foregroundStyle(.white)
                    .padding(.horizontal, 12)
                    .frame(height: 30)
                    .background(CharkleTheme.accentButtonFill(for: colorScheme, source: accentSource), in: Capsule())
                }
                .buttonStyle(.plain)
                .disabled(controller.isImportingTray)
                .padding(.trailing, 4)
            }
        }
        .charkleLiquidGlass(.regular, in: Capsule(style: .continuous), interactive: true)
    }

    private var expandedTrayDrawer: some View {
        VStack(spacing: 0) {
            // Drawer Header
            HStack(spacing: 10) {
                Image(systemName: "cart.fill")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(activeAccent)
                Text("Pinterest 采集托盘")
                    .font(CharkleTheme.text(.body, weight: .semibold))
                Text("已勾选 \(controller.selectedTrayCount) / \(controller.trayCount) 项，点击卡片查看详情")
                    .font(CharkleTheme.text(.caption))
                    .foregroundStyle(CharkleTheme.secondaryInk(for: colorScheme))

                Spacer()

                if !controller.trayPins.isEmpty {
                    let allSelected = controller.selectedTrayCount == controller.trayCount
                    Button(allSelected ? "取消全选" : "全选") {
                        if allSelected { controller.deselectAllTray() } else { controller.selectAllTray() }
                    }
                    .buttonStyle(CharkleButtonStyle(.subtle, size: .xs, cornerRadius: 999))

                    if controller.selectedTrayCount > 0 {
                        Button("移除已选 (\(controller.selectedTrayCount))") {
                            let removed = controller.removeSelectedFromTray()
                            coordinator.showToast("已从托盘移除 \(removed) 项", icon: "trash")
                        }
                        .buttonStyle(CharkleButtonStyle(.subtle, size: .xs, cornerRadius: 999))
                    }

                    Button("清空") {
                        controller.clearTray()
                    }
                    .buttonStyle(CharkleButtonStyle(.subtle, size: .xs, cornerRadius: 999))
                }

                Button {
                    withAnimation(CharkleMotion.accessible(CharkleMotion.drawerEase, reduced: reduceMotion)) {
                        controller.isTrayExpanded = false
                    }
                } label: {
                    Image(systemName: "chevron.down")
                        .font(.system(size: 12, weight: .semibold))
                }
                .buttonStyle(CharkleButtonStyle(.subtle, size: .icon, iconDimension: 26))
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 11)

            CharkleHairlineDivider()

            // Tray Items Strip / Grid
            if controller.trayPins.isEmpty {
                VStack(spacing: 8) {
                    Image(systemName: "cart")
                        .font(.system(size: 26, weight: .light))
                        .foregroundStyle(CharkleTheme.secondaryInk(for: colorScheme).opacity(0.72))
                    Text("托盘还是空的")
                        .font(CharkleTheme.text(.body, weight: .medium))
                    Text("悬停卡片点击右上角「+」，或切换到左下角「快选入托盘」模式批量点选加入")
                        .font(CharkleTheme.text(.caption))
                        .foregroundStyle(CharkleTheme.secondaryInk(for: colorScheme))
                }
                .frame(maxWidth: .infinity)
                .frame(height: 150)
            } else {
                ScrollView(.horizontal) {
                    LazyHStack(alignment: .top, spacing: 10) {
                        ForEach(controller.trayPins) { pin in
                            trayPinCard(pin)
                        }
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 12)
                }
                .scrollIndicators(.automatic)
                .frame(height: 196)
            }

            // Batch Import Footer Bar
            if !controller.trayPins.isEmpty {
                CharkleHairlineDivider()
                HStack(spacing: 10) {
                    // Target Charkle folder picker
                    Menu {
                        Button {
                            trayTargetFolderID = nil
                        } label: {
                            Label("收件箱（默认）", systemImage: "tray.and.arrow.down")
                        }
                        if !library.flattenedFolderHierarchy.isEmpty {
                            Divider()
                            ForEach(library.flattenedFolderHierarchy) { node in
                                Button {
                                    trayTargetFolderID = node.folder.id
                                } label: {
                                    Text(String(repeating: "  ", count: min(node.depth, 4)) + node.folder.name)
                                }
                            }
                        }
                    } label: {
                        HStack(spacing: 5) {
                            Image(systemName: trayTargetFolderID == nil ? "tray.and.arrow.down" : "folder")
                                .font(.system(size: 11.5, weight: .medium))
                                .foregroundStyle(activeAccent)
                            Text(selectedTrayFolderTitle)
                                .font(CharkleTheme.text(.caption, weight: .medium))
                                .foregroundStyle(.primary.opacity(0.92))
                                .lineLimit(1)
                            CharkleDropdownChevron(size: 8.5)
                        }
                        .padding(.horizontal, 10)
                        .frame(height: 30)
                        .background(CharkleTheme.surfaceSubtle(for: colorScheme), in: RoundedRectangle(cornerRadius: CharkleTheme.Radius.chip, style: .continuous))
                    }
                    .menuStyle(.button)
                    .buttonStyle(CharkleMenuTriggerButtonStyle())
                    .menuIndicator(.hidden)
                    .fixedSize()

                    HStack(spacing: 5) {
                        Image(systemName: "tag")
                            .font(.system(size: 11))
                            .foregroundStyle(CharkleTheme.secondaryInk(for: colorScheme).opacity(0.72))
                        TextField("附加标签（逗号分隔，可选）", text: $trayExtraTagsText)
                            .textFieldStyle(.plain)
                            .font(CharkleTheme.text(.caption))
                            .frame(width: 170)
                    }
                    .padding(.horizontal, 9)
                    .frame(height: 30)
                    .background(CharkleTheme.surfaceSubtle(for: colorScheme), in: RoundedRectangle(cornerRadius: CharkleTheme.Radius.chip, style: .continuous))

                    Spacer()

                    if let prog = controller.importProgress {
                        HStack(spacing: 8) {
                            ProgressView(value: Double(prog.completed), total: Double(max(1, prog.total)))
                                .frame(width: 100)
                            Text("\(prog.completed)/\(prog.total)")
                                .font(CharkleTheme.text(.caption, weight: .medium).monospacedDigit())
                                .foregroundStyle(CharkleTheme.secondaryInk(for: colorScheme))
                        }
                    }

                    Button {
                        batchImportSelectedTray()
                    } label: {
                        HStack(spacing: 6) {
                            Image(systemName: "square.and.arrow.down")
                                .font(.system(size: 12, weight: .semibold))
                            Text(controller.isImportingTray
                                 ? "正在导入…"
                                 : "批量导入已选 (\(controller.selectedTrayCount)) 到素材库")
                                .font(CharkleTheme.text(.body, weight: .semibold))
                        }
                    }
                    .buttonStyle(CharkleButtonStyle(.accent, size: .sm, cornerRadius: 999))
                    .disabled(controller.isImportingTray || controller.selectedTrayCount == 0)
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 10)
            }
        }
        .frame(maxWidth: 900)
        .charkleLiquidGlass(.regular, in: RoundedRectangle(cornerRadius: CharkleTheme.Radius.popoverOuter, style: .continuous))
        .shadow(color: Color.black.opacity(colorScheme == .dark ? 0.42 : 0.14), radius: 24, y: 8)
    }

    private func trayPinCard(_ pin: PinterestPin) -> some View {
        let isSelected = controller.selectedTrayPinIDs.contains(pin.id)
        let isImported = controller.importedPinIDs.contains(pin.id)
        let cardHeight: CGFloat = 146
        let cardWidth = max(76, min(260, (cardHeight * CGFloat(pin.aspectRatio)).rounded()))
        let trayCardRadius = CharkleTheme.Radius.concentricInner(outer: CharkleTheme.Radius.popoverOuter, padding: CharkleTheme.Radius.popoverPadding)

        return VStack(alignment: .leading, spacing: 5) {
            ZStack(alignment: .top) {
                // Clicking the card thumbnail opens that Pin's floating Pinterest detail page!
                Button {
                    withAnimation(CharkleMotion.accessible(CharkleMotion.enterMd, reduced: reduceMotion)) {
                        controller.openPinDetail(pin, resetStack: true)
                    }
                } label: {
                    PinterestRemoteThumbMac(
                        url: pin.previewURL,
                        dominantHex: pin.dominantColorHex,
                        maxPixels: cardWidth > 180 ? 520 : 380,
                        contentMode: .fill
                    )
                    .frame(width: cardWidth, height: cardHeight)
                    .clipShape(RoundedRectangle(cornerRadius: trayCardRadius, style: .continuous))
                    .overlay(
                        RoundedRectangle(cornerRadius: trayCardRadius, style: .continuous)
                            .strokeBorder(
                                isSelected ? activeAccent : Color.primary.opacity(0.10),
                                lineWidth: isSelected ? 2 : CharkleTheme.hairlineWidth
                            )
                    )
                }
                .buttonStyle(.plain)
                .help("点击打开此素材的 Pinterest 条目详情与相似灵感")

                HStack {
                    Button {
                        controller.toggleTraySelection(pin.id)
                    } label: {
                        Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                            .font(.system(size: 16, weight: .semibold))
                            .foregroundStyle(isSelected ? activeAccent : .white)
                            .background(Circle().fill(Color.black.opacity(isSelected ? 0.65 : 0.40)).padding(2))
                    }
                    .buttonStyle(.plain)
                    .help(isSelected ? "取消勾选此项" : "勾选此项以批量导入或移除")

                    Spacer()

                    Button {
                        controller.removeFromTray(pin.id)
                    } label: {
                        Image(systemName: "xmark")
                            .font(.system(size: 9.5, weight: .bold))
                            .foregroundStyle(.white)
                            .frame(width: 20, height: 20)
                            .background(Color.black.opacity(0.56), in: Circle())
                    }
                    .buttonStyle(.plain)
                    .help("从托盘移除")
                }
                .padding(6)

                if isImported {
                    VStack {
                        Spacer()
                        HStack {
                            Text("已入库")
                                .font(CharkleTheme.text(.caption, weight: .semibold))
                                .foregroundStyle(.white)
                                .padding(.horizontal, 6)
                                .padding(.vertical, 2)
                                .background(Color.black.opacity(0.62), in: Capsule())
                            Spacer()
                        }
                        .padding(6)
                    }
                    .allowsHitTesting(false)
                }
            }
            .frame(width: cardWidth, height: cardHeight)

            Button {
                withAnimation(CharkleMotion.accessible(CharkleMotion.enterMd, reduced: reduceMotion)) {
                    controller.openPinDetail(pin, resetStack: true)
                }
            } label: {
                Text(pin.displayTitle)
                    .font(CharkleTheme.text(.caption, weight: .medium))
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                    .frame(width: cardWidth, alignment: .leading)
            }
            .buttonStyle(.plain)
        }
    }

    // MARK: - Signed-Out Welcome Stage

    private var signedOutWelcomeStage: some View {
        VStack(spacing: 0) {
            ZStack(alignment: .leading) {
                CharkleWindowDragArea()
                    .frame(height: 50)
                if !isSidebarVisible {
                    Button(action: onToggleSidebar) {
                        Image(systemName: "sidebar.left")
                            .font(.system(size: 13.5, weight: .semibold))
                            .foregroundStyle(.primary)
                            .frame(width: 34, height: 34)
                            .contentShape(Circle())
                    }
                    .buttonStyle(.plain)
                    .charkleLiquidGlass(.regular, in: Circle(), interactive: true)
                    .padding(.leading, 86)
                    .padding(.top, 8)
                    .help("展开左侧边栏")
                }
            }
            Spacer()
            VStack(spacing: 18) {
                ZStack {
                    Circle()
                        .fill(activeAccent.opacity(colorScheme == .dark ? 0.20 : 0.12))
                        .frame(width: 68, height: 68)
                    Image(systemName: "sparkles.rectangle.stack")
                        .font(.system(size: 28, weight: .semibold))
                        .foregroundStyle(activeAccent)
                }

                VStack(spacing: 6) {
                    Text("在 Charkle 无限空间中浏览 Pinterest")
                        .font(CharkleTheme.text(.title, weight: .semibold))
                    Text("登录 Pinterest 后，可在无限画布中浏览灵感、批量加入托盘，或将画板按目录导入素材库。")
                        .font(CharkleTheme.text(.body))
                        .foregroundStyle(CharkleTheme.secondaryInk(for: colorScheme))
                        .multilineTextAlignment(.center)
                        .frame(maxWidth: 460)
                }

                HStack(spacing: 12) {
                    featureChip(icon: "hand.draw", text: "360° 无限空间 & 锚点缩放")
                    featureChip(icon: "cart.badge.plus", text: "批量加托盘挑选入库")
                    featureChip(icon: "folder.badge.plus", text: "画板收藏按目录整批导入")
                }

                Button {
                    controller.isLoginSheetPresented = true
                } label: {
                    HStack(spacing: 7) {
                        Image(systemName: "person.crop.circle.badge.plus")
                            .font(.system(size: 14, weight: .semibold))
                        Text("登录 Pinterest 账号")
                            .font(CharkleTheme.text(.body, weight: .semibold))
                    }
                    .padding(.horizontal, 10)
                }
                .buttonStyle(CharkleButtonStyle(.accent, size: .md, cornerRadius: 999))
                .padding(.top, 4)

                if !controller.trayPins.isEmpty {
                    Text("你的采集托盘中仍保留着上次挑选的 \(controller.trayPins.count) 项素材，登录后可继续管理与入库。")
                        .font(CharkleTheme.text(.caption))
                        .foregroundStyle(CharkleTheme.secondaryInk(for: colorScheme).opacity(0.72))
                }
            }
            .padding(32)
            .background(
                RoundedRectangle(cornerRadius: CharkleTheme.Radius.dockOuter, style: .continuous)
                    .fill(CharkleTheme.surfaceElevated(for: colorScheme))
                    .overlay(
                        RoundedRectangle(cornerRadius: CharkleTheme.Radius.dockOuter, style: .continuous)
                            .strokeBorder(CharkleTheme.hairline(for: colorScheme), lineWidth: CharkleTheme.hairlineWidth)
                    )
            )
            .shadow(color: Color.black.opacity(colorScheme == .dark ? 0.35 : 0.08), radius: 24, y: 10)
            Spacer()
        }
    }

    private func featureChip(icon: String, text: String) -> some View {
        HStack(spacing: 5) {
            Image(systemName: icon)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(activeAccent)
            Text(text)
                .font(CharkleTheme.text(.caption, weight: .medium))
                .foregroundStyle(CharkleTheme.secondaryInk(for: colorScheme))
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(CharkleTheme.surfaceSubtle(for: colorScheme), in: Capsule())
    }

    // MARK: - Helpers & Actions

    private var selectedTrayFolderTitle: String {
        guard let id = trayTargetFolderID else { return "导入到：收件箱" }
        let name = library.folders.first(where: { $0.id == id })?.name ?? "收件箱"
        return "导入到：\(name)"
    }

    private func parsedExtraTags(_ raw: String) -> [String] {
        raw.split { $0 == "," || $0 == "，" }
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }

    private func batchImportSelectedTray() {
        let extraTags = parsedExtraTags(trayExtraTagsText)
        let folderID = trayTargetFolderID
        Task {
            let report = await controller.importTrayPins(
                into: library.engine,
                targetFolderID: folderID,
                extraTags: extraTags,
                removeImportedFromTray: true
            )
            await library.refreshAll()
            let imported = report.importedAssets.count
            let skipped = report.skippedDuplicatePinIDs.count
            let failed = report.failedPinIDs.count
            if imported > 0 {
                var msg = "已将 \(imported) 项 Pinterest 素材收入素材库"
                if skipped > 0 { msg += "（跳过 \(skipped) 项已存在）" }
                if failed > 0 { msg += "，\(failed) 项失败保留在托盘" }
                coordinator.showToast(msg, icon: "checkmark.circle.fill", tone: .success)
            } else if skipped > 0 && failed == 0 {
                coordinator.showToast("所选 \(skipped) 项素材均已在素材库中", icon: "checkmark.circle", tone: .neutral)
            } else if failed > 0 {
                coordinator.showToast("有 \(failed) 项素材下载失败，已保留在托盘中", icon: "exclamationmark.triangle", tone: .warning)
            }
        }
    }

    private func importSinglePin(_ pin: PinterestPin) {
        guard !isSingleImporting else { return }
        isSingleImporting = true
        let folderID = trayTargetFolderID
        Task {
            defer { isSingleImporting = false }
            let report = await controller.importSinglePinImmediately(pin, into: library.engine, targetFolderID: folderID)
            await library.refreshAll()
            if !report.importedAssets.isEmpty {
                coordinator.showToast("已直接收入素材库", icon: "checkmark.circle.fill", tone: .success)
            } else if !report.skippedDuplicatePinIDs.isEmpty {
                coordinator.showToast("该 Pinterest 素材已在素材库中", icon: "checkmark.circle", tone: .neutral)
            } else {
                coordinator.showToast("导入失败，请稍后重试", icon: "exclamationmark.triangle", tone: .warning)
            }
        }
    }

    private func showBoardsImportToast(_ report: PinterestBoardsImportReport) {
        let imported = report.importedAssets.count
        let skipped = report.skippedDuplicatePinIDs.count
        let failed = report.failedPinIDs.count
        var parts: [String] = []
        if imported > 0 { parts.append("新增 \(imported) 项") }
        if skipped > 0 { parts.append("跳过重复 \(skipped) 项") }
        if failed > 0 { parts.append("失败 \(failed) 项") }
        let suffix = parts.isEmpty ? "未发现新素材" : parts.joined(separator: "，")
        let prefix = report.wasCancelled ? "已取消导入（已处理 \(report.boardsProcessed) 个画板）" : "画板收藏导入完成（\(report.boardsProcessed) 个画板）"
        coordinator.showToast("\(prefix)：\(suffix)", icon: imported > 0 ? "checkmark.circle.fill" : "info.circle", tone: imported > 0 ? .success : .neutral)
    }
}

// MARK: - Floating Pinterest Pin Detail Overlay + Similar Pins Grid

private struct PinterestPinDetailOverlayMac: View {
    @Environment(\.colorScheme) private var colorScheme
    @Bindable var controller: PinterestExploreController
    let pin: PinterestPin
    let isSingleImporting: Bool
    let accent: Color
    @Binding var isImageExpanded: Bool
    let onClose: () -> Void
    let onToggleTray: (PinterestPin) -> Void
    let onImportSingle: (PinterestPin) -> Void
    let onExploreSimilarInSpace: (PinterestPin) -> Void

    private var isInTray: Bool {
        controller.isInTray(pin.id)
    }

    private var isImported: Bool {
        controller.importedPinIDs.contains(pin.id)
    }

    var body: some View {
        GeometryReader { geo in
            let cardWidth = min(940, max(620, geo.size.width - 96))
            let cardHeight = min(760, max(500, geo.size.height - 80))

            ZStack {
                CharkleModalBackdrop(onTap: onClose)

                VStack(spacing: 0) {
                    // Floating Header
                    HStack(spacing: 10) {
                        if controller.detailStack.count > 1 {
                            Button {
                                controller.popPinDetail()
                            } label: {
                                HStack(spacing: 4) {
                                    Image(systemName: "chevron.left")
                                        .font(.system(size: 11.5, weight: .semibold))
                                    Text("返回上一个")
                                        .font(CharkleTheme.text(.caption, weight: .medium))
                                }
                            }
                            .buttonStyle(CharkleButtonStyle(.subtle, size: .sm, cornerRadius: 999))
                        }

                        VStack(alignment: .leading, spacing: 1) {
                            Text(pin.displayTitle)
                                .font(CharkleTheme.text(.body, weight: .semibold))
                                .lineLimit(1)
                            HStack(spacing: 8) {
                                Text("Pinterest 条目")
                                    .font(CharkleTheme.text(.caption, weight: .medium))
                                    .foregroundStyle(accent)
                                if let board = pin.boardName, !board.isEmpty {
                                    Text(board)
                                        .font(CharkleTheme.text(.caption))
                                        .foregroundStyle(CharkleTheme.secondaryInk(for: colorScheme))
                                        .lineLimit(1)
                                }
                                if let domain = pin.domain, !domain.isEmpty {
                                    Text(domain)
                                        .font(CharkleTheme.text(.caption))
                                        .foregroundStyle(CharkleTheme.secondaryInk(for: colorScheme).opacity(0.72))
                                        .lineLimit(1)
                                }
                            }
                        }

                        Spacer()

                        Button {
                            onExploreSimilarInSpace(pin)
                        } label: {
                            HStack(spacing: 5) {
                                Image(systemName: "sparkles.rectangle.stack")
                                    .font(.system(size: 11.5, weight: .semibold))
                                Text("在无限空间展开相似")
                                    .font(CharkleTheme.text(.caption, weight: .medium))
                            }
                        }
                        .buttonStyle(CharkleButtonStyle(.subtle, size: .sm, cornerRadius: 999))

                        Button {
                            NSWorkspace.shared.open(pin.pinPageURL)
                        } label: {
                            Image(systemName: "safari")
                                .font(.system(size: 12.5, weight: .medium))
                        }
                        .buttonStyle(CharkleButtonStyle(.subtle, size: .icon, iconDimension: 28))
                        .help("在浏览器打开 Pinterest 原条目页")

                        Button(action: onClose) {
                            Image(systemName: "xmark")
                                .font(.system(size: 12, weight: .semibold))
                        }
                        .buttonStyle(CharkleButtonStyle(.subtle, size: .icon, iconDimension: 28))
                        .help("关闭 (Esc)")
                    }
                    .padding(.horizontal, 18)
                    .padding(.vertical, 12)

                    CharkleHairlineDivider()

                    // Scrollable Content: Aspect-Adaptive Pin Detail Split + Pinterest Similar Pins Below
                    ScrollView {
                        VStack(alignment: .leading, spacing: 18) {
                            pinHeroSection(cardWidth: cardWidth, cardHeight: cardHeight)

                            CharkleHairlineDivider()

                            similarPinsSection
                        }
                        .padding(18)
                    }
                    .charkleCleanScrollbars(hidden: false)
                    .overlay {
                        if isImageExpanded {
                            ZStack(alignment: .topTrailing) {
                                Color.black.opacity(0.84)
                                    .onTapGesture {
                                        withAnimation(.easeOut(duration: 0.16)) { isImageExpanded = false }
                                    }
                                PinterestRemoteThumbMac(
                                    url: pin.originalURL,
                                    fallbackURL: pin.previewURL,
                                    dominantHex: pin.dominantColorHex,
                                    maxPixels: 2000,
                                    contentMode: .fit
                                )
                                .padding(24)
                                .onTapGesture {
                                    withAnimation(.easeOut(duration: 0.16)) { isImageExpanded = false }
                                }
                                Button {
                                    withAnimation(.easeOut(duration: 0.16)) { isImageExpanded = false }
                                } label: {
                                    Image(systemName: "xmark")
                                        .font(.system(size: 13, weight: .bold))
                                        .foregroundStyle(.white)
                                        .frame(width: 32, height: 32)
                                        .background(Color.white.opacity(0.18), in: Circle())
                                }
                                .buttonStyle(.plain)
                                .padding(16)
                            }
                            .transition(.opacity)
                        }
                    }
                }
                .frame(width: cardWidth, height: cardHeight)
                .background(
                    RoundedRectangle(cornerRadius: CharkleTheme.Radius.dockOuter, style: .continuous)
                        .fill(CharkleTheme.surfaceElevated(for: colorScheme))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: CharkleTheme.Radius.dockOuter, style: .continuous)
                        .strokeBorder(CharkleTheme.hairline(for: colorScheme), lineWidth: CharkleTheme.hairlineWidth)
                )
                .clipShape(RoundedRectangle(cornerRadius: CharkleTheme.Radius.dockOuter, style: .continuous))
                .shadow(color: Color.black.opacity(colorScheme == .dark ? 0.50 : 0.22), radius: 36, y: 14)
            }
        }
        .onChange(of: pin.id) { _, _ in
            isImageExpanded = false
        }
        .onDisappear {
            isImageExpanded = false
        }
    }

    private func pinHeroSection(cardWidth: CGFloat, cardHeight: CGFloat) -> some View {
        let ratio = CGFloat(pin.aspectRatio)
        let maxW = min((cardWidth - 56) * (ratio > 1.25 ? 0.50 : 0.42), 420)
        let maxH = min(cardHeight * 0.40, ratio > 1.25 ? 270 : 320)
        let safeRatio = max(0.35, min(2.6, ratio))
        let wByH = maxH * safeRatio
        let heroSize: CGSize = wByH <= maxW
            ? CGSize(width: max(120, wByH.rounded()), height: max(120, maxH.rounded()))
            : CGSize(width: max(120, maxW.rounded()), height: max(120, (maxW / safeRatio).rounded()))
        let heroCardRadius = CharkleTheme.Radius.concentricInner(outer: CharkleTheme.Radius.dockOuter, padding: CharkleTheme.Radius.dockPadding)

        return HStack(alignment: .top, spacing: 20) {
            // Left: Exact-aspect high-res Pin Visual (zero pillarbox dead space; click to expand)
            Button {
                withAnimation(.easeOut(duration: 0.16)) { isImageExpanded = true }
            } label: {
                ZStack(alignment: .topLeading) {
                    PinterestRemoteThumbMac(
                        url: pin.originalURL,
                        fallbackURL: pin.previewURL,
                        dominantHex: pin.dominantColorHex,
                        maxPixels: 1600,
                        contentMode: .fill
                    )
                    .frame(width: heroSize.width, height: heroSize.height)
                    .clipShape(RoundedRectangle(cornerRadius: heroCardRadius, style: .continuous))
                    .overlay(
                        RoundedRectangle(cornerRadius: heroCardRadius, style: .continuous)
                            .strokeBorder(CharkleTheme.hairline(for: colorScheme), lineWidth: CharkleTheme.hairlineWidth)
                    )

                    if pin.isVideo {
                        HStack(spacing: 4) {
                            Image(systemName: "video.fill")
                                .font(.system(size: 10, weight: .bold))
                            Text("视频 Pin")
                                .font(CharkleTheme.text(.caption, weight: .semibold))
                        }
                        .foregroundStyle(.white)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(Color.black.opacity(0.62), in: Capsule())
                        .padding(10)
                    }
                }
            }
            .buttonStyle(.plain)
            .help("点击查看大图预览")

            // Right: Metadata & Shopping-Cart / Import Actions
            VStack(alignment: .leading, spacing: 12) {
                Text(pin.displayTitle)
                    .font(CharkleTheme.text(.headline, weight: .semibold))
                    .lineLimit(3)
                    .textSelection(.enabled)

                if !pin.descriptionText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                   pin.descriptionText != pin.displayTitle {
                    Text(pin.descriptionText)
                        .font(CharkleTheme.text(.body))
                        .foregroundStyle(CharkleTheme.secondaryInk(for: colorScheme))
                        .lineLimit(4)
                        .textSelection(.enabled)
                }

                // Metadata Chips
                VStack(alignment: .leading, spacing: 6) {
                    if let pinner = pin.pinnerName, !pinner.isEmpty {
                        metaRow(icon: "person.crop.circle", label: "作者", value: pinner)
                    }
                    if let board = pin.boardName, !board.isEmpty {
                        metaRow(icon: "rectangle.3.group", label: "所属画板", value: board)
                    }
                    metaRow(icon: "aspectratio", label: "原始尺寸", value: "\(pin.width) × \(pin.height) px")
                    if let ext = pin.externalLinkURL {
                        Button {
                            NSWorkspace.shared.open(ext)
                        } label: {
                            HStack(spacing: 5) {
                                Image(systemName: "globe")
                                    .font(.system(size: 11.5))
                                Text(pin.domain ?? ext.host() ?? ext.absoluteString)
                                    .font(CharkleTheme.text(.caption, weight: .medium))
                                    .lineLimit(1)
                                Image(systemName: "arrow.up.right")
                                    .font(.system(size: 10, weight: .semibold))
                            }
                            .foregroundStyle(accent)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(CharkleTheme.surfaceSubtle(for: colorScheme), in: RoundedRectangle(cornerRadius: heroCardRadius, style: .continuous))

                // Primary Actions
                VStack(spacing: 8) {
                    Button {
                        onToggleTray(pin)
                    } label: {
                        HStack(spacing: 7) {
                            Image(systemName: isInTray ? "checkmark.circle.fill" : "cart.badge.plus")
                                .font(.system(size: 13, weight: .semibold))
                            Text(isInTray ? "已在采集托盘中（点击移出）" : "加入采集托盘")
                                .font(CharkleTheme.text(.body, weight: .semibold))
                        }
                        .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(CharkleButtonStyle(isInTray ? .subtle : .accent, size: .md, cornerRadius: CharkleTheme.Radius.popoverInner))

                    HStack(spacing: 8) {
                        Button {
                            onImportSingle(pin)
                        } label: {
                            HStack(spacing: 6) {
                                if isSingleImporting {
                                    ProgressView().controlSize(.mini)
                                } else {
                                    Image(systemName: isImported ? "checkmark.circle.fill" : "square.and.arrow.down")
                                        .font(.system(size: 12, weight: .semibold))
                                }
                                Text(isImported ? "已入库" : (isSingleImporting ? "入库中…" : "直接入库"))
                                    .font(CharkleTheme.text(.body, weight: .medium))
                            }
                            .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(CharkleButtonStyle(.subtle, size: .md, cornerRadius: CharkleTheme.Radius.popoverInner))
                        .disabled(isSingleImporting)

                        Button {
                            onExploreSimilarInSpace(pin)
                        } label: {
                            HStack(spacing: 5) {
                                Image(systemName: "sparkles")
                                    .font(.system(size: 12, weight: .semibold))
                                Text("无限空间看相似")
                                    .font(CharkleTheme.text(.body, weight: .medium))
                            }
                            .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(CharkleButtonStyle(.subtle, size: .md, cornerRadius: CharkleTheme.Radius.popoverInner))
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func metaRow(icon: String, label: String, value: String) -> some View {
        HStack(spacing: 7) {
            Image(systemName: icon)
                .font(.system(size: 11.5, weight: .medium))
                .foregroundStyle(CharkleTheme.secondaryInk(for: colorScheme).opacity(0.72))
                .frame(width: 15)
            Text(label)
                .font(CharkleTheme.text(.caption))
                .foregroundStyle(CharkleTheme.secondaryInk(for: colorScheme))
            Text(value)
                .font(CharkleTheme.text(.caption, weight: .medium))
                .lineLimit(1)
        }
    }

    private var similarPinsSection: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                HStack(spacing: 7) {
                    Image(systemName: "sparkles")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(accent)
                    Text("Pinterest 类似素材")
                        .font(CharkleTheme.text(.headline, weight: .semibold))
                    if !controller.detailSimilarPins.isEmpty {
                        Text("\(controller.detailSimilarPins.count)")
                            .font(CharkleTheme.text(.caption, weight: .medium).monospacedDigit())
                            .foregroundStyle(CharkleTheme.secondaryInk(for: colorScheme))
                    }
                }
                Spacer()
                if controller.isLoadingDetail {
                    HStack(spacing: 6) {
                        ProgressView().controlSize(.mini)
                        Text("正在获取相似灵感…")
                            .font(CharkleTheme.text(.caption))
                            .foregroundStyle(CharkleTheme.secondaryInk(for: colorScheme))
                    }
                }
            }

            if controller.detailSimilarPins.isEmpty && !controller.isLoadingDetail {
                Text("暂未获取到该条目的类似推荐，可点击右上角「在无限空间展开相似」或刷新重试。")
                    .font(CharkleTheme.text(.body))
                    .foregroundStyle(CharkleTheme.secondaryInk(for: colorScheme))
                    .padding(.vertical, 16)
            } else {
                let columns = distributeSimilarColumns(controller.detailSimilarPins, columnCount: 4)
                HStack(alignment: .top, spacing: 12) {
                    ForEach(0..<columns.count, id: \.self) { colIdx in
                        LazyVStack(spacing: 12) {
                            ForEach(columns[colIdx]) { simPin in
                                similarPinCard(simPin)
                            }
                        }
                    }
                }

                if controller.detailHasMoreSimilar {
                    HStack {
                        Spacer()
                        Button {
                            Task { await controller.loadMoreSimilarInDetail() }
                        } label: {
                            HStack(spacing: 6) {
                                if controller.isLoadingMoreSimilar {
                                    ProgressView().controlSize(.mini)
                                }
                                Text(controller.isLoadingMoreSimilar ? "正在加载…" : "加载更多类似素材")
                                    .font(CharkleTheme.text(.body, weight: .medium))
                            }
                            .padding(.horizontal, 16)
                        }
                        .buttonStyle(CharkleButtonStyle(.subtle, size: .md, cornerRadius: 999))
                        .disabled(controller.isLoadingMoreSimilar)
                        Spacer()
                    }
                    .padding(.top, 6)
                }
            }
        }
    }

    private func similarPinCard(_ simPin: PinterestPin) -> some View {
        let inTray = controller.isInTray(simPin.id)
        return ZStack(alignment: .topTrailing) {
            Button {
                controller.openPinDetail(simPin, resetStack: false)
            } label: {
                PinterestRemoteThumbMac(
                    url: simPin.previewURL,
                    dominantHex: simPin.dominantColorHex,
                    maxPixels: 520
                )
                .aspectRatio(simPin.aspectRatio, contentMode: .fit)
                .clipShape(RoundedRectangle(cornerRadius: CharkleTheme.Radius.cardOuter, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: CharkleTheme.Radius.cardOuter, style: .continuous)
                        .strokeBorder(
                            inTray ? accent : CharkleTheme.hairline(for: colorScheme),
                            lineWidth: inTray ? 2 : CharkleTheme.hairlineWidth
                        )
                )
            }
            .buttonStyle(.plain)

            Button {
                onToggleTray(simPin)
            } label: {
                Image(systemName: inTray ? "checkmark" : "plus")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(.white)
                    .frame(width: 26, height: 26)
                    .background(inTray ? accent : Color.black.opacity(0.60), in: Circle())
                    .overlay(Circle().strokeBorder(Color.white.opacity(0.35), lineWidth: CharkleTheme.hairlineWidth))
            }
            .buttonStyle(.plain)
            .padding(7)
            .help(inTray ? "移出采集托盘" : "加入采集托盘")
        }
    }

    private func distributeSimilarColumns(_ pins: [PinterestPin], columnCount: Int) -> [[PinterestPin]] {
        let count = max(1, columnCount)
        var buckets = Array(repeating: [PinterestPin](), count: count)
        var heights = Array(repeating: Double(0), count: count)
        for p in pins {
            let minIdx = heights.enumerated().min(by: { $0.element < $1.element })?.offset ?? 0
            buckets[minIdx].append(p)
            heights[minIdx] += 1.0 / max(0.45, p.aspectRatio)
        }
        return buckets
    }
}

// MARK: - Batch Import Pinterest Saved Collections by Board Sheet

private struct PinterestBoardImportSheetMac: View {
    @Environment(\.colorScheme) private var colorScheme
    @Bindable var controller: PinterestExploreController
    let engine: any CharkleEngineProtocol
    let folders: [FolderHierarchyNode]
    let accent: Color
    let onImportCompleted: (PinterestBoardsImportReport) -> Void

    @State private var selectedBoardIDs: Set<String> = []
    @State private var hasInitializedSelection: Bool = false
    @State private var destinationMode: DestinationChoice = .pinterestRoot
    @State private var customParentFolderID: UUID? = nil
    @State private var skipDuplicates: Bool = true
    @State private var extraTagsText: String = ""

    enum DestinationChoice: String, CaseIterable, Identifiable {
        case pinterestRoot
        case libraryRoot
        case existingFolder

        var id: String { rawValue }
        var label: String {
            switch self {
            case .pinterestRoot: "新建/复用「Pinterest」父文件夹，按画板分子目录（推荐）"
            case .libraryRoot: "直接在素材库根目录按画板名称建文件夹"
            case .existingFolder: "存放到指定的已有文件夹内（按画板分子目录）"
            }
        }
    }

    private var selectedBoards: [PinterestBoard] {
        controller.boards.filter { selectedBoardIDs.contains($0.id) }
    }

    private var totalEstimatedPins: Int {
        selectedBoards.reduce(0) { $0 + max(0, $1.pinCount) }
    }

    var body: some View {
        VStack(spacing: 0) {
            // Header
            HStack(spacing: 10) {
                Image(systemName: "square.and.arrow.down.on.square")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(accent)
                VStack(alignment: .leading, spacing: 2) {
                    Text("批量导入 Pinterest 收藏（按画板分目录）")
                        .font(CharkleTheme.text(.headline, weight: .semibold))
                    Text("勾选画板后，自动按画板名称建立或复用目录并去重。")
                        .font(CharkleTheme.text(.caption))
                        .foregroundStyle(CharkleTheme.secondaryInk(for: colorScheme))
                }
                Spacer()
                Button {
                    if !controller.isImportingBoards {
                        controller.isBoardImportSheetPresented = false
                    }
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 12, weight: .semibold))
                }
                .buttonStyle(CharkleButtonStyle(.subtle, size: .icon, iconDimension: 28))
                .disabled(controller.isImportingBoards)
            }
            .padding(.horizontal, 18)
            .padding(.vertical, 14)

            CharkleHairlineDivider()

            // Board Checklist
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Text("我的 Pinterest 画板（共 \(controller.boards.count) 个）")
                        .font(CharkleTheme.text(.body, weight: .semibold))
                    Spacer()
                    if controller.isLoadingBoards {
                        ProgressView().controlSize(.mini)
                    } else {
                        Button("刷新列表") {
                            Task {
                                await controller.refreshBoards()
                                syncDefaultSelectionIfNeeded()
                            }
                        }
                        .buttonStyle(CharkleButtonStyle(.subtle, size: .xs, cornerRadius: 999))
                        .disabled(controller.isImportingBoards)
                    }

                    if !controller.boards.isEmpty {
                        let allPicked = selectedBoardIDs.count == controller.boards.count
                        Button(allPicked ? "取消全选" : "全选") {
                            if allPicked {
                                selectedBoardIDs.removeAll()
                            } else {
                                selectedBoardIDs = Set(controller.boards.map(\.id))
                            }
                        }
                        .buttonStyle(CharkleButtonStyle(.subtle, size: .xs, cornerRadius: 999))
                        .disabled(controller.isImportingBoards)
                    }
                }

                if controller.boards.isEmpty && !controller.isLoadingBoards {
                    VStack(spacing: 8) {
                        Image(systemName: "rectangle.3.group")
                            .font(.system(size: 24, weight: .light))
                            .foregroundStyle(CharkleTheme.secondaryInk(for: colorScheme).opacity(0.72))
                        Text("未发现可导入的 Pinterest 画板")
                            .font(CharkleTheme.text(.body, weight: .medium))
                        Text("请确认你的 Pinterest 账号下已有保存的画板，或点击右上角「刷新列表」重试。")
                            .font(CharkleTheme.text(.caption))
                            .foregroundStyle(CharkleTheme.secondaryInk(for: colorScheme))
                    }
                    .frame(maxWidth: .infinity)
                    .frame(height: 170)
                    .background(CharkleTheme.surfaceSubtle(for: colorScheme), in: RoundedRectangle(cornerRadius: CharkleTheme.Radius.cardOuter, style: .continuous))
                } else {
                    ScrollView {
                        LazyVStack(spacing: 6) {
                            ForEach(controller.boards) { board in
                                boardRow(board)
                            }
                        }
                        .padding(8)
                    }
                    .frame(height: 220)
                    .background(CharkleTheme.surfaceSubtle(for: colorScheme), in: RoundedRectangle(cornerRadius: CharkleTheme.Radius.cardOuter, style: .continuous))
                }

                // Destination & Options
                VStack(alignment: .leading, spacing: 10) {
                    Text("素材库目录结构")
                        .font(CharkleTheme.text(.body, weight: .semibold))

                    Picker("", selection: $destinationMode) {
                        ForEach(DestinationChoice.allCases) { choice in
                            Text(choice.label).tag(choice)
                        }
                    }
                    .pickerStyle(.radioGroup)
                    .labelsHidden()
                    .disabled(controller.isImportingBoards)

                    if destinationMode == .existingFolder {
                        Menu {
                            ForEach(folders) { node in
                                Button {
                                    customParentFolderID = node.folder.id
                                } label: {
                                    Text(String(repeating: "  ", count: min(node.depth, 4)) + node.folder.name)
                                }
                            }
                        } label: {
                            HStack(spacing: 6) {
                                Image(systemName: "folder")
                                    .foregroundStyle(accent)
                                Text(selectedCustomParentName)
                                    .font(CharkleTheme.text(.caption, weight: .medium))
                                    .foregroundStyle(.primary.opacity(0.92))
                                CharkleDropdownChevron(size: 8.5)
                            }
                            .padding(.horizontal, 10)
                            .frame(height: 30)
                            .background(CharkleTheme.surfaceSubtle(for: colorScheme), in: RoundedRectangle(cornerRadius: CharkleTheme.Radius.chip, style: .continuous))
                        }
                        .menuStyle(.button)
                        .buttonStyle(CharkleMenuTriggerButtonStyle())
                        .menuIndicator(.hidden)
                        .fixedSize()
                        .disabled(controller.isImportingBoards || folders.isEmpty)
                    }

                    HStack(spacing: 14) {
                        Toggle("跳过素材库中已存在的 Pin（增量同步）", isOn: $skipDuplicates)
                            .toggleStyle(.checkbox)
                            .font(CharkleTheme.text(.caption))
                            .disabled(controller.isImportingBoards)

                        Spacer()

                        HStack(spacing: 5) {
                            Image(systemName: "tag")
                                .font(.system(size: 11))
                                .foregroundStyle(CharkleTheme.secondaryInk(for: colorScheme).opacity(0.72))
                            TextField("附加标签（可选）", text: $extraTagsText)
                                .textFieldStyle(.plain)
                                .font(CharkleTheme.text(.caption))
                                .frame(width: 140)
                                .disabled(controller.isImportingBoards)
                        }
                        .padding(.horizontal, 8)
                        .frame(height: 28)
                        .background(CharkleTheme.surfaceSubtle(for: colorScheme), in: RoundedRectangle(cornerRadius: CharkleTheme.Radius.chip, style: .continuous))
                    }
                }
                .padding(.top, 4)

                // Live Progress Section
                if let progress = controller.boardImportProgress {
                    VStack(alignment: .leading, spacing: 6) {
                        ProgressView(value: progress.fractionCompleted, total: 1.0)
                            .tint(accent)
                        HStack {
                            Text(progress.statusText)
                                .font(CharkleTheme.text(.caption, weight: .medium))
                                .lineLimit(1)
                            Spacer()
                            Text("已入库 \(progress.overallImported)，跳过 \(progress.overallSkipped)")
                                .font(CharkleTheme.text(.caption).monospacedDigit())
                                .foregroundStyle(CharkleTheme.secondaryInk(for: colorScheme))
                        }
                    }
                    .padding(12)
                    .background(accent.opacity(colorScheme == .dark ? 0.14 : 0.08), in: RoundedRectangle(cornerRadius: CharkleTheme.Radius.popoverInner, style: .continuous))
                }
            }
            .padding(18)

            CharkleHairlineDivider()

            // Footer CTA
            HStack(spacing: 10) {
                Text("已选 \(selectedBoards.count) 个画板（约 \(totalEstimatedPins) 项收藏）")
                    .font(CharkleTheme.text(.caption).monospacedDigit())
                    .foregroundStyle(CharkleTheme.secondaryInk(for: colorScheme))

                Spacer()

                if controller.isImportingBoards {
                    Button("取消导入") {
                        controller.cancelBoardImport()
                    }
                    .buttonStyle(CharkleButtonStyle(.subtle, size: .md, cornerRadius: 999))
                } else {
                    Button("关闭") {
                        controller.isBoardImportSheetPresented = false
                    }
                    .buttonStyle(CharkleButtonStyle(.subtle, size: .md, cornerRadius: 999))

                    Button {
                        startImport()
                    } label: {
                        HStack(spacing: 6) {
                            Image(systemName: "square.and.arrow.down.on.square")
                                .font(.system(size: 12, weight: .semibold))
                            Text("开始按画板导入")
                                .font(CharkleTheme.text(.body, weight: .semibold))
                        }
                    }
                    .buttonStyle(CharkleButtonStyle(.accent, size: .md, cornerRadius: 999))
                    .disabled(selectedBoards.isEmpty || (destinationMode == .existingFolder && customParentFolderID == nil))
                }
            }
            .padding(.horizontal, 18)
            .padding(.vertical, 12)
        }
        .frame(width: 590)
        .background(CharkleTheme.surfaceElevated(for: colorScheme))
        .onAppear {
            syncDefaultSelectionIfNeeded()
            if customParentFolderID == nil {
                customParentFolderID = folders.first?.folder.id
            }
        }
        .onChange(of: controller.boards) { _, _ in
            syncDefaultSelectionIfNeeded()
        }
    }

    private func boardRow(_ board: PinterestBoard) -> some View {
        let isSelected = selectedBoardIDs.contains(board.id)
        let rowRadius = CharkleTheme.Radius.concentricInner(outer: CharkleTheme.Radius.cardOuter, padding: 4)
        return Button {
            guard !controller.isImportingBoards else { return }
            if isSelected {
                selectedBoardIDs.remove(board.id)
            } else {
                selectedBoardIDs.insert(board.id)
            }
        } label: {
            HStack(spacing: 10) {
                Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(isSelected ? accent : CharkleTheme.secondaryInk(for: colorScheme).opacity(0.72))

                if let cover = board.coverURL {
                    PinterestRemoteThumbMac(url: cover, dominantHex: nil, maxPixels: 140)
                        .frame(width: 36, height: 36)
                        .clipShape(RoundedRectangle(cornerRadius: CharkleTheme.Radius.sm, style: .continuous))
                } else {
                    RoundedRectangle(cornerRadius: CharkleTheme.Radius.sm, style: .continuous)
                        .fill(Color.primary.opacity(0.08))
                        .frame(width: 36, height: 36)
                        .overlay(
                            Image(systemName: "rectangle.3.group")
                                .font(.system(size: 13))
                                .foregroundStyle(CharkleTheme.secondaryInk(for: colorScheme).opacity(0.72))
                        )
                }

                VStack(alignment: .leading, spacing: 2) {
                    Text(board.name)
                        .font(CharkleTheme.text(.body, weight: .medium))
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                    Text("将归档至子目录「\(PinterestImportService.sanitizedFolderName(board.name, fallback: "Pinterest"))」")
                        .font(CharkleTheme.text(.caption))
                        .foregroundStyle(CharkleTheme.secondaryInk(for: colorScheme))
                        .lineLimit(1)
                }

                Spacer()

                Text("\(board.pinCount) 项")
                    .font(CharkleTheme.text(.caption, weight: .medium).monospacedDigit())
                    .foregroundStyle(CharkleTheme.secondaryInk(for: colorScheme))
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .background(
                isSelected ? accent.opacity(colorScheme == .dark ? 0.14 : 0.08) : Color.clear,
                in: RoundedRectangle(cornerRadius: rowRadius, style: .continuous)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private var selectedCustomParentName: String {
        guard let id = customParentFolderID,
              let match = folders.first(where: { $0.folder.id == id }) else {
            return folders.isEmpty ? "暂无已有文件夹" : "选择父文件夹"
        }
        return match.folder.name
    }

    private func syncDefaultSelectionIfNeeded() {
        guard !hasInitializedSelection, !controller.boards.isEmpty else { return }
        hasInitializedSelection = true
        selectedBoardIDs = Set(controller.boards.map(\.id))
    }

    private func startImport() {
        let destination: PinterestBoardImportDestination
        switch destinationMode {
        case .pinterestRoot:
            destination = .pinterestRootFolder
        case .libraryRoot:
            destination = .libraryRoot
        case .existingFolder:
            destination = customParentFolderID.map { .existingFolder($0) } ?? .pinterestRootFolder
        }

        let tags = extraTagsText
            .split { $0 == "," || $0 == "，" }
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        let boardsToImport = selectedBoards

        Task {
            let report = await controller.importBoards(
                boardsToImport,
                into: engine,
                destination: destination,
                extraTags: tags,
                skipDuplicates: skipDuplicates
            )
            onImportCompleted(report)
            if !report.wasCancelled {
                controller.isBoardImportSheetPresented = false
            }
        }
    }
}

// MARK: - Floating Chrome Hit-Test Exclusion PreferenceKey (macOS)

private struct PinterestMacHitExclusionKey: PreferenceKey {
    static let defaultValue: [CGRect] = []
    static func reduce(value: inout [CGRect], nextValue: () -> [CGRect]) {
        value.append(contentsOf: nextValue())
    }
}

private extension View {
    func pinterestExcludeHitTestMac() -> some View {
        background(
            GeometryReader { proxy in
                Color.clear.preference(
                    key: PinterestMacHitExclusionKey.self,
                    value: [proxy.frame(in: .named("pinterestMacCanvas"))]
                )
            }
        )
    }
}

// MARK: - Cached Remote Thumbnail Helper (macOS)

private struct PinterestRemoteThumbMac: View {
    let url: URL
    var fallbackURL: URL? = nil
    let dominantHex: String?
    var maxPixels: Int = 640
    var contentMode: ContentMode = .fill

    @State private var image: NSImage?
    @State private var loadedURL: URL?

    var body: some View {
        ZStack {
            placeholderColor
            if let image, loadedURL == url || (fallbackURL != nil && loadedURL == fallbackURL) {
                Image(nsImage: image)
                    .resizable()
                    .aspectRatio(contentMode: contentMode)
                    .transition(.opacity)
            }
        }
        .task(id: url) {
            if let cached = PinterestImageCache.shared.cachedImage(for: url) {
                image = cached
                loadedURL = url
                return
            }
            if let fallbackURL, let cachedFallback = PinterestImageCache.shared.cachedImage(for: fallbackURL) {
                image = cachedFallback
                loadedURL = fallbackURL
            } else {
                image = nil
                loadedURL = nil
            }
            if let fetched = await PinterestImageCache.shared.image(for: url, maxPixelSize: maxPixels) {
                guard !Task.isCancelled else { return }
                withAnimation(.easeOut(duration: 0.16)) {
                    image = fetched
                    loadedURL = url
                }
            } else if let fallbackURL,
                      let fetchedFallback = await PinterestImageCache.shared.image(for: fallbackURL, maxPixelSize: maxPixels) {
                guard !Task.isCancelled else { return }
                withAnimation(.easeOut(duration: 0.16)) {
                    image = fetchedFallback
                    loadedURL = fallbackURL
                }
            }
        }
    }

    private var placeholderColor: Color {
        if let hex = dominantHex {
            return Color(charkleHex: hex).opacity(0.24)
        }
        return Color.primary.opacity(0.06)
    }
}
