import CharkleCore
import SwiftUI
import UIKit

/// Full-bleed iOS / iPadOS Pinterest Infinite Space View:
/// - Silky 120Hz omnidirectional 2D infinite canvas with two-finger anchor-locked continuous zoom
/// - Shopping-Cart Collection Tray ("托盘") with click-to-jump-to-Pin-detail, selective remove, and batch import
/// - Floating Pinterest Pin Detail Overlay displaying Pinterest's similar pins underneath
/// - Batch Import Saved Collections by Board (organizing into per-board Charkle folders)
struct PinterestExploreMobileView: View {
    @Bindable var store: MobileAppStore
    @Bindable var controller: PinterestExploreController
    /// Optional leading pill injected on iPhone `搜图` tab to switch cleanly back to `库内搜图`.
    var onSwitchToLibrarySearch: (() -> Void)? = nil
    /// Optional sidebar toggle for iPad `NavigationSplitView` (since Pinterest hides the system nav bar).
    var onToggleSidebar: (() -> Void)? = nil

    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.openURL) private var openURL

    @State private var cameraScale: CGFloat = 0.78
    @State private var cameraCommand = PinterestCameraCommandMobile()
    @State private var isSearchExpanded: Bool = false
    @State private var isSingleImporting: Bool = false
    @State private var excludedGlobalRects: [CGRect] = []
    @FocusState private var isSearchFocused: Bool

    private var accent: Color {
        MobileTheme.accent(for: colorScheme)
    }

    var body: some View {
        ZStack {
            MobileTheme.galleryGround(for: colorScheme)
                .ignoresSafeArea()

            if controller.isSignedIn {
                signedInSpace
            } else if controller.isCheckingSession {
                VStack(spacing: 12) {
                    ProgressView()
                    Text("正在检查 Pinterest 登录状态…")
                        .font(.system(size: 13.5))
                        .foregroundStyle(MobileTheme.secondaryInk(for: colorScheme))
                }
            } else {
                signedOutWelcome
            }

            // Floating Pin Detail Overlay (Pin details + Pinterest Similar Pins right underneath)
            if let activePin = controller.activeDetailPin {
                PinterestPinDetailOverlayMobile(
                    controller: controller,
                    pin: activePin,
                    isCompact: horizontalSizeClass != .regular,
                    isSingleImporting: isSingleImporting,
                    accent: accent,
                    onClose: {
                        withAnimation(MobileMotion.accessible(MobileMotion.exitSm, reduced: reduceMotion)) {
                            controller.closePinDetail()
                        }
                    },
                    onToggleTray: { pin in
                        let added = controller.toggleTray(pin)
                        MobileHaptics.light()
                        store.showToast(
                            added ? "已加入托盘（共 \(controller.trayCount) 项）" : "已从托盘移出",
                            tone: .info
                        )
                    },
                    onImportSingle: { pin in
                        importSinglePin(pin)
                    },
                    onExploreSimilarInSpace: { pin in
                        Task { await controller.exploreSimilarInInfiniteSpace(pin) }
                    },
                    onOpenExternalURL: { url in
                        openURL(url)
                    }
                )
                .zIndex(80)
                .transition(.opacity.combined(with: .scale(scale: 0.96)))
            }
        }
        .task {
            await controller.bootstrap(engine: store.engine)
        }
        .sheet(isPresented: $controller.isLoginSheetPresented) {
            PinterestLoginSheetMobile(
                onVerifySession: {
                    let ok = await controller.handleLoginCompleted(engine: store.engine)
                    if ok, let account = controller.account {
                        MobileHaptics.success()
                        store.showToast("已登录 Pinterest（\(account.displayName)）", tone: .success)
                    }
                    return ok
                },
                onDismiss: {
                    controller.isLoginSheetPresented = false
                }
            )
            .presentationDetents([.large])
        }
        .sheet(isPresented: $controller.isTrayExpanded) {
            PinterestTraySheetMobile(
                store: store,
                controller: controller,
                accent: accent,
                onOpenPinDetail: { pin in
                    controller.isTrayExpanded = false
                    Task { @MainActor in
                        try? await Task.sleep(for: .milliseconds(160))
                        withAnimation(MobileMotion.accessible(MobileMotion.enterMd, reduced: reduceMotion)) {
                            controller.openPinDetail(pin, resetStack: true)
                        }
                    }
                }
            )
            .presentationDetents([.medium, .large])
            .presentationDragIndicator(.visible)
        }
        .sheet(isPresented: $controller.isBoardImportSheetPresented) {
            PinterestBoardImportSheetMobile(
                store: store,
                controller: controller,
                accent: accent
            )
            .presentationDetents([.large])
            .presentationDragIndicator(.visible)
        }
    }

    // MARK: - Signed-In Edge-to-Edge Infinite 2D Space

    private var signedInSpace: some View {
        ZStack {
            // 120Hz Infinite 2D Canvas
            PinterestInfiniteCanvasMobile(
                cards: controller.layout.cards,
                layoutRevision: controller.layoutRevision,
                trayPinIDs: Set(controller.trayPins.map(\.id)),
                importedPinIDs: controller.importedPinIDs,
                fastPickMode: controller.fastPickMode,
                isDark: colorScheme == .dark,
                accentColor: UIColor(accent),
                isInteractionSuspended: controller.activeDetailPin != nil || controller.isTrayExpanded || controller.isLoginSheetPresented || controller.isBoardImportSheetPresented,
                excludedGlobalRects: excludedGlobalRects,
                cameraCommand: cameraCommand,
                onOpenDetail: { pin in
                    withAnimation(MobileMotion.accessible(MobileMotion.enterMd, reduced: reduceMotion)) {
                        controller.openPinDetail(pin, resetStack: true)
                    }
                },
                onToggleTray: { pin in
                    let added = controller.toggleTray(pin)
                    store.showToast(
                        added ? "已加入托盘（共 \(controller.trayCount) 项）" : "已从托盘移出",
                        tone: .info
                    )
                },
                onCameraChanged: { cam, visibleWorld in
                    if abs(cam.scale - cameraScale) > 0.01 {
                        cameraScale = cam.scale
                    }
                    controller.updateCameraViewport(visibleWorldRect: visibleWorld, scale: cam.scale)
                }
            )
            .ignoresSafeArea()

            // Loading / Error centered feedback
            if controller.isLoadingFeed && controller.layout.cards.isEmpty {
                VStack(spacing: 10) {
                    ProgressView()
                    Text("正在铺展 Pinterest 无限灵感空间…")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(MobileTheme.secondaryInk(for: colorScheme))
                }
                .padding(.horizontal, 18)
                .padding(.vertical, 14)
                .charkleFloatingCard(cornerRadius: 16)
            } else if let error = controller.errorMessage, controller.layout.cards.isEmpty {
                VStack(spacing: 12) {
                    Image(systemName: "exclamationmark.triangle")
                        .font(.system(size: 24))
                        .foregroundStyle(MobileTheme.warning(for: colorScheme))
                    Text(error)
                        .font(.system(size: 13))
                        .foregroundStyle(MobileTheme.secondaryInk(for: colorScheme))
                        .multilineTextAlignment(.center)
                    HStack(spacing: 10) {
                        Button("重试") {
                            Task { await controller.reloadFeed() }
                        }
                        .buttonStyle(.bordered)
                        if controller.needsReauthentication {
                            Button("重新登录") {
                                controller.isLoginSheetPresented = true
                            }
                            .buttonStyle(.borderedProminent)
                        }
                    }
                }
                .padding(20)
                .frame(maxWidth: 320)
                .charkleFloatingCard(cornerRadius: 18)
                .pinterestExcludeHitTestMobile()
                .zIndex(15)
            }

            // Floating Top Chrome + Floating Bottom Mode Pill & Shopping-Cart Tray
            VStack(spacing: 0) {
                topFloatingBar
                    .padding(.horizontal, 12)
                    .padding(.top, 8)

                if isSearchExpanded {
                    inlineSearchBar
                        .pinterestExcludeHitTestMobile()
                        .padding(.horizontal, 12)
                        .padding(.top, 8)
                        .transition(.move(edge: .top).combined(with: .opacity))
                }

                Spacer(minLength: 0)

                HStack(alignment: .center, spacing: 10) {
                    bottomModePill
                        .pinterestExcludeHitTestMobile()

                    if controller.isLoadingMore {
                        ProgressView()
                            .controlSize(.small)
                            .padding(8)
                            .charkleFloatingCircle(interactive: false)
                    }

                    Spacer(minLength: 8)

                    bottomTrayCapsule
                        .pinterestExcludeHitTestMobile()
                }
                .padding(.horizontal, 14)
                .padding(.bottom, horizontalSizeClass == .regular ? 18 : 12)
            }
            .zIndex(20)
        }
        .onPreferenceChange(PinterestMobileHitExclusionKey.self) { rects in
            excludedGlobalRects = rects
        }
    }

    // MARK: - Top Floating Liquid Glass Chrome

    private var topFloatingBar: some View {
        HStack(spacing: 8) {
            if let onToggleSidebar {
                Button {
                    MobileHaptics.light()
                    onToggleSidebar()
                } label: {
                    Image(systemName: "sidebar.left")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(.primary)
                        .frame(width: 36, height: 36)
                        .contentShape(Circle())
                }
                .buttonStyle(.plain)
                .charkleFloatingCircle(interactive: true)
                .pinterestExcludeHitTestMobile()
                .accessibilityLabel("展开或收起侧边栏")
            }

            if let onSwitchToLibrarySearch {
                Button {
                    MobileHaptics.light()
                    onSwitchToLibrarySearch()
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "magnifyingglass")
                            .font(.system(size: 12, weight: .semibold))
                        Text("库内")
                            .font(.system(size: 12.5, weight: .semibold))
                    }
                    .foregroundStyle(.primary)
                    .padding(.horizontal, 11)
                    .frame(height: 36)
                    .contentShape(Capsule())
                }
                .buttonStyle(.plain)
                .charkleFloatingCapsule(interactive: true)
                .pinterestExcludeHitTestMobile()
            }

            // Feed / Boards Switcher Menu
            if case .similar = controller.feedSource {
                Button {
                    MobileHaptics.light()
                    Task { await controller.switchSource(.homeFeed) }
                } label: {
                    Image(systemName: "chevron.left")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(.primary)
                        .frame(width: 36, height: 36)
                        .contentShape(Circle())
                }
                .buttonStyle(.plain)
                .charkleFloatingCircle(interactive: true)
                .pinterestExcludeHitTestMobile()
            }

            Menu {
                Button {
                    Task { await controller.switchSource(.homeFeed) }
                } label: {
                    Label("推荐灵感", systemImage: "sparkles")
                }

                if !controller.boards.isEmpty {
                    Divider()
                    Section("我的画板") {
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
                    Label("批量导入收藏（按画板分目录）", systemImage: "square.and.arrow.down.on.square")
                }
            } label: {
                HStack(spacing: 5) {
                    Image(systemName: "sparkles")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(accent)
                    Text(controller.feedSource.displayTitle)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                    Image(systemName: "chevron.down")
                        .font(.system(size: 9.5, weight: .semibold))
                        .foregroundStyle(MobileTheme.secondaryInk(for: colorScheme))
                }
                .padding(.horizontal, 12)
                .frame(height: 36)
                .contentShape(Capsule())
            }
            .charkleFloatingCapsule(interactive: true)
            .pinterestExcludeHitTestMobile()

            Spacer(minLength: 4)

            // Search Toggle Button
            Button {
                withAnimation(MobileMotion.accessible(MobileMotion.enterSm, reduced: reduceMotion)) {
                    isSearchExpanded.toggle()
                }
                if isSearchExpanded {
                    isSearchFocused = true
                }
            } label: {
                Image(systemName: isSearchExpanded ? "xmark" : "magnifyingglass")
                    .font(.system(size: 13.5, weight: .semibold))
                    .foregroundStyle(isSearchExpanded ? accent : .primary)
                    .frame(width: 36, height: 36)
                    .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .charkleFloatingCircle(interactive: true)
            .pinterestExcludeHitTestMobile()

            // Reset Camera / Center Button
            Button {
                MobileHaptics.light()
                cameraCommand = PinterestCameraCommandMobile(action: .resetCenter)
            } label: {
                Image(systemName: "scope")
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(.primary)
                    .frame(width: 36, height: 36)
                    .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .charkleFloatingCircle(interactive: true)
            .pinterestExcludeHitTestMobile()

            // Account & Batch Collection Import Menu
            Menu {
                if let account = controller.account {
                    Text("\(account.displayName) (@\(account.username))")
                    Divider()
                }
                Button {
                    controller.isBoardImportSheetPresented = true
                    Task { await controller.refreshBoards() }
                } label: {
                    Label("批量导入画板收藏…", systemImage: "square.and.arrow.down.on.square")
                }
                Button {
                    Task { await controller.reloadFeed() }
                } label: {
                    Label("刷新无限空间", systemImage: "arrow.clockwise")
                }
                Button {
                    controller.isLoginSheetPresented = true
                } label: {
                    Label("重新登录 / 验证账号", systemImage: "person.crop.circle")
                }
                Divider()
                Button(role: .destructive) {
                    Task {
                        await controller.signOut()
                        store.showToast("已退出 Pinterest 账号", tone: .info)
                    }
                } label: {
                    Label("退出 Pinterest 账号", systemImage: "rectangle.portrait.and.arrow.right")
                }
            } label: {
                Image(systemName: "ellipsis")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(.primary)
                    .frame(width: 36, height: 36)
                    .contentShape(Circle())
            }
            .charkleFloatingCircle(interactive: true)
            .pinterestExcludeHitTestMobile()
        }
    }

    private var inlineSearchBar: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(MobileTheme.secondaryInk(for: colorScheme))
            TextField("搜索 Pinterest 灵感关键词…", text: $controller.searchText)
                .font(.system(size: 14))
                .focused($isSearchFocused)
                .submitLabel(.search)
                .onSubmit {
                    isSearchFocused = false
                    withAnimation { isSearchExpanded = false }
                    Task { await controller.submitSearch() }
                }
            if !controller.searchText.isEmpty {
                Button {
                    controller.searchText = ""
                    Task { await controller.switchSource(.homeFeed) }
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 15))
                        .foregroundStyle(MobileTheme.tertiaryInk(for: colorScheme))
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 14)
        .frame(height: 40)
        .charkleFloatingCapsule(interactive: true)
    }

    // MARK: - Bottom-Left Mode Switcher Pill (Icon-Only Browse vs. Fast-Pick)

    private var bottomModePill: some View {
        HStack(spacing: 3) {
            Button {
                MobileHaptics.light()
                withAnimation(MobileMotion.accessible(MobileMotion.hoverPress, reduced: reduceMotion)) {
                    controller.fastPickMode = false
                }
            } label: {
                Image(systemName: "hand.draw")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(!controller.fastPickMode ? .white : MobileTheme.secondaryInk(for: colorScheme))
                    .frame(width: 36, height: 32)
                    .background(!controller.fastPickMode ? MobileTheme.accentButtonFill(for: colorScheme) : .clear, in: Capsule())
                    .contentShape(Capsule())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("浏览模式")

            Button {
                MobileHaptics.light()
                withAnimation(MobileMotion.accessible(MobileMotion.hoverPress, reduced: reduceMotion)) {
                    controller.fastPickMode = true
                }
            } label: {
                Image(systemName: "cart.badge.plus")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(controller.fastPickMode ? .white : MobileTheme.secondaryInk(for: colorScheme))
                    .frame(width: 36, height: 32)
                    .background(controller.fastPickMode ? MobileTheme.accentButtonFill(for: colorScheme) : .clear, in: Capsule())
                    .contentShape(Capsule())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("快选入托盘模式")
        }
        .padding(4)
        .charkleFloatingCapsule(interactive: true)
    }

    // MARK: - Bottom-Right Shopping-Cart Collection Tray Capsule

    private var bottomTrayCapsule: some View {
        Button {
            MobileHaptics.light()
            controller.isTrayExpanded = true
        } label: {
            HStack(spacing: 8) {
                if !controller.trayPins.isEmpty {
                    HStack(spacing: -8) {
                        ForEach(controller.trayPins.prefix(3)) { pin in
                            PinterestRemoteThumbMobile(url: pin.thumbnailURL, dominantHex: pin.dominantColorHex, maxPixels: 140)
                                .frame(width: 24, height: 24)
                                .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                                .overlay(
                                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                                        .strokeBorder(MobileTheme.surfaceElevated(for: colorScheme), lineWidth: 1.5)
                                )
                        }
                    }
                } else {
                    Image(systemName: "cart")
                        .font(.system(size: 13.5, weight: .semibold))
                        .foregroundStyle(MobileTheme.secondaryInk(for: colorScheme))
                }

                Text(controller.trayCount > 0 ? "托盘 \(controller.trayCount)" : "托盘")
                    .font(.system(size: 13, weight: .semibold).monospacedDigit())
                    .foregroundStyle(.primary)

                Image(systemName: "chevron.up")
                    .font(.system(size: 10.5, weight: .semibold))
                    .foregroundStyle(MobileTheme.secondaryInk(for: colorScheme))
            }
            .padding(.horizontal, 13)
            .frame(height: 40)
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .charkleFloatingCapsule(interactive: true)
    }

    // MARK: - Signed-Out Welcome Stage

    private var signedOutWelcome: some View {
        VStack(spacing: 0) {
            if onToggleSidebar != nil || onSwitchToLibrarySearch != nil {
                HStack(spacing: 8) {
                    if let onToggleSidebar {
                        Button {
                            MobileHaptics.light()
                            onToggleSidebar()
                        } label: {
                            Image(systemName: "sidebar.left")
                                .font(.system(size: 14, weight: .semibold))
                                .foregroundStyle(.primary)
                                .frame(width: 36, height: 36)
                                .contentShape(Circle())
                        }
                        .buttonStyle(.plain)
                        .charkleFloatingCircle(interactive: true)
                    }
                    if let onSwitchToLibrarySearch {
                        Button {
                            MobileHaptics.light()
                            onSwitchToLibrarySearch()
                        } label: {
                            HStack(spacing: 4) {
                                Image(systemName: "chevron.left")
                                    .font(.system(size: 12, weight: .semibold))
                                Text("返回库内搜图")
                                    .font(.system(size: 13, weight: .medium))
                            }
                            .padding(.horizontal, 12)
                            .frame(height: 34)
                            .contentShape(Capsule())
                        }
                        .buttonStyle(.plain)
                        .charkleFloatingCapsule(interactive: true)
                    }
                    Spacer()
                }
                .padding(.horizontal, 16)
                .padding(.top, 10)
            }

            Spacer()

            VStack(spacing: 18) {
                ZStack {
                    Circle()
                        .fill(accent.opacity(colorScheme == .dark ? 0.22 : 0.12))
                        .frame(width: 68, height: 68)
                    Image(systemName: "sparkles.rectangle.stack")
                        .font(.system(size: 28, weight: .semibold))
                        .foregroundStyle(accent)
                }

                VStack(spacing: 8) {
                    Text("Pinterest 无限空间")
                        .font(.system(size: 20, weight: .semibold))
                    Text("登录你的 Pinterest 账号，在无边二维画布中自由滑动与锚点缩放，像购物车一样批量加入托盘挑选入库，也支持把画板收藏按目录一键导入素材库。")
                        .font(.system(size: 13.5))
                        .foregroundStyle(MobileTheme.secondaryInk(for: colorScheme))
                        .multilineTextAlignment(.center)
                }

                Button {
                    MobileHaptics.light()
                    controller.isLoginSheetPresented = true
                } label: {
                    HStack(spacing: 7) {
                        Image(systemName: "person.crop.circle.badge.plus")
                        Text("登录 Pinterest 账号")
                            .fontWeight(.semibold)
                    }
                    .foregroundStyle(.white)
                    .padding(.horizontal, 22)
                    .frame(height: 44)
                    .background(MobileTheme.accentButtonFill(for: colorScheme), in: Capsule())
                }
                .buttonStyle(MobileTactileButtonStyle())
            }
            .padding(24)
            .background(
                RoundedRectangle(cornerRadius: 22, style: .continuous)
                    .fill(MobileTheme.surfaceElevated(for: colorScheme))
                    .overlay(
                        RoundedRectangle(cornerRadius: 22, style: .continuous)
                            .strokeBorder(MobileTheme.hairline(for: colorScheme), lineWidth: 1)
                    )
            )
            .padding(.horizontal, 24)

            Spacer()
        }
    }

    // MARK: - Single Import Helper

    private func importSinglePin(_ pin: PinterestPin) {
        guard !isSingleImporting else { return }
        isSingleImporting = true
        Task {
            defer { isSingleImporting = false }
            let report = await controller.importSinglePinImmediately(pin, into: store.engine, targetFolderID: nil)
            await store.reloadAll()
            if !report.importedAssets.isEmpty {
                MobileHaptics.success()
                store.showToast("已直接收入素材库", tone: .success)
            } else if !report.skippedDuplicatePinIDs.isEmpty {
                store.showToast("该素材已在素材库中", tone: .info)
            } else {
                store.showToast("导入失败，请稍后重试", tone: .warning)
            }
        }
    }
}

// MARK: - Floating Pin Detail Overlay + Pinterest Similar Pins Grid (iOS & iPadOS)

private struct PinterestPinDetailOverlayMobile: View {
    @Environment(\.colorScheme) private var colorScheme
    @Bindable var controller: PinterestExploreController
    let pin: PinterestPin
    let isCompact: Bool
    let isSingleImporting: Bool
    let accent: Color
    let onClose: () -> Void
    let onToggleTray: (PinterestPin) -> Void
    let onImportSingle: (PinterestPin) -> Void
    let onExploreSimilarInSpace: (PinterestPin) -> Void
    let onOpenExternalURL: (URL) -> Void

    private var isInTray: Bool { controller.isInTray(pin.id) }
    private var isImported: Bool { controller.importedPinIDs.contains(pin.id) }
    @State private var isImageExpanded: Bool = false

    var body: some View {
        GeometryReader { geo in
            let horizontalInset: CGFloat = isCompact ? 12 : 44
            let verticalInset: CGFloat = isCompact ? 18 : 36
            let cardWidth = min(760, max(280, geo.size.width - horizontalInset * 2))
            let cardHeight = min(840, max(420, geo.size.height - verticalInset * 2))

            ZStack {
                Color.black.opacity(colorScheme == .dark ? 0.56 : 0.34)
                    .ignoresSafeArea()
                    .onTapGesture(perform: onClose)

                VStack(spacing: 0) {
                    // Floating Window Header
                    HStack(spacing: 8) {
                        if controller.detailStack.count > 1 {
                            Button {
                                MobileHaptics.light()
                                controller.popPinDetail()
                            } label: {
                                Image(systemName: "chevron.left")
                                    .font(.system(size: 13, weight: .semibold))
                                    .frame(width: 30, height: 30)
                                    .background(MobileTheme.surfaceSubtle(for: colorScheme), in: Circle())
                            }
                            .buttonStyle(.plain)
                        }

                        VStack(alignment: .leading, spacing: 1) {
                            Text(pin.displayTitle)
                                .font(.system(size: 14, weight: .semibold))
                                .lineLimit(1)
                            Text(subtitleText)
                                .font(.system(size: 11.5))
                                .foregroundStyle(MobileTheme.secondaryInk(for: colorScheme))
                                .lineLimit(1)
                        }

                        Spacer(minLength: 4)

                        Button {
                            onOpenExternalURL(pin.pinPageURL)
                        } label: {
                            Image(systemName: "safari")
                                .font(.system(size: 13, weight: .medium))
                                .frame(width: 30, height: 30)
                                .background(MobileTheme.surfaceSubtle(for: colorScheme), in: Circle())
                        }
                        .buttonStyle(.plain)

                        Button(action: onClose) {
                            Image(systemName: "xmark")
                                .font(.system(size: 12.5, weight: .bold))
                                .frame(width: 30, height: 30)
                                .background(MobileTheme.surfaceSubtle(for: colorScheme), in: Circle())
                        }
                        .buttonStyle(.plain)
                    }
                    .padding(.horizontal, 14)
                    .padding(.vertical, 11)

                    Divider()

                    // Scrollable Aspect-Adaptive Pin Hero + Pinterest Similar Pins Waterfall
                    ScrollView {
                        VStack(alignment: .leading, spacing: 14) {
                            adaptivePinHero(cardWidth: cardWidth, cardHeight: cardHeight)

                            Divider()

                            // Pinterest Similar Pins Section Underneath
                            VStack(alignment: .leading, spacing: 12) {
                                HStack {
                                    HStack(spacing: 6) {
                                        Image(systemName: "sparkles")
                                            .font(.system(size: 13, weight: .semibold))
                                            .foregroundStyle(accent)
                                        Text("Pinterest 类似素材")
                                            .font(.system(size: 15, weight: .semibold))
                                    }
                                    Spacer()
                                    if controller.isLoadingDetail {
                                        ProgressView().controlSize(.small)
                                    }
                                }

                                if controller.detailSimilarPins.isEmpty && !controller.isLoadingDetail {
                                    Text("暂未获取到类似推荐，可点击上方「看相似」在无限空间探索。")
                                        .font(.system(size: 12.5))
                                        .foregroundStyle(MobileTheme.secondaryInk(for: colorScheme))
                                        .padding(.vertical, 12)
                                } else {
                                    let cols = distributeColumns(controller.detailSimilarPins, count: cardWidth >= 560 ? 3 : 2)
                                    HStack(alignment: .top, spacing: 10) {
                                        ForEach(0..<cols.count, id: \.self) { idx in
                                            LazyVStack(spacing: 10) {
                                                ForEach(cols[idx]) { simPin in
                                                    similarCard(simPin)
                                                }
                                            }
                                        }
                                    }

                                    if controller.detailHasMoreSimilar {
                                        Button {
                                            Task { await controller.loadMoreSimilarInDetail() }
                                        } label: {
                                            HStack(spacing: 6) {
                                                if controller.isLoadingMoreSimilar {
                                                    ProgressView().controlSize(.small)
                                                }
                                                Text(controller.isLoadingMoreSimilar ? "加载中…" : "加载更多类似素材")
                                                    .font(.system(size: 13, weight: .medium))
                                            }
                                            .frame(maxWidth: .infinity)
                                            .frame(height: 38)
                                            .background(MobileTheme.surfaceSubtle(for: colorScheme), in: Capsule())
                                        }
                                        .buttonStyle(.plain)
                                        .disabled(controller.isLoadingMoreSimilar)
                                    }
                                }
                            }
                        }
                        .padding(14)
                    }
                    .overlay {
                        if isImageExpanded {
                            ZStack(alignment: .topTrailing) {
                                Color.black.opacity(0.86)
                                    .onTapGesture {
                                        withAnimation(.easeOut(duration: 0.18)) { isImageExpanded = false }
                                    }
                                PinterestRemoteThumbMobile(
                                    url: pin.originalURL,
                                    fallbackURL: pin.previewURL,
                                    dominantHex: pin.dominantColorHex,
                                    maxPixels: 1800,
                                    contentMode: .fit
                                )
                                .padding(18)
                                .onTapGesture {
                                    withAnimation(.easeOut(duration: 0.18)) { isImageExpanded = false }
                                }

                                Button {
                                    withAnimation(.easeOut(duration: 0.18)) { isImageExpanded = false }
                                } label: {
                                    Image(systemName: "xmark")
                                        .font(.system(size: 13, weight: .bold))
                                        .foregroundStyle(.white)
                                        .frame(width: 34, height: 34)
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
                .background(MobileTheme.surfaceElevated(for: colorScheme))
                .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 22, style: .continuous)
                        .strokeBorder(MobileTheme.borderStrong(for: colorScheme), lineWidth: 0.9)
                )
                .shadow(color: .black.opacity(colorScheme == .dark ? 0.52 : 0.24), radius: 28, y: 12)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    @ViewBuilder
    private func adaptivePinHero(cardWidth: CGFloat, cardHeight: CGFloat) -> some View {
        let contentWidth = max(240, cardWidth - 28)
        let ratio = CGFloat(pin.aspectRatio)
        let isWideContainer = contentWidth >= 480
        let useSideBySide = isWideContainer || ratio < 0.96

        if useSideBySide {
            let maxImgW = isWideContainer
                ? min(contentWidth * (ratio > 1.25 ? 0.50 : 0.43), 340)
                : min(contentWidth * 0.44, 162)
            let maxImgH = isWideContainer
                ? min(cardHeight * 0.39, ratio > 1.25 ? 245 : 310)
                : min(cardHeight * 0.33, 224)
            let imgSize = fittedAspectSize(ratio: ratio, maxWidth: maxImgW, maxHeight: maxImgH)

            HStack(alignment: .top, spacing: isWideContainer ? 16 : 12) {
                heroArtworkButton(size: imgSize)

                VStack(alignment: .leading, spacing: isWideContainer ? 10 : 8) {
                    heroMetadataBlock(compact: !isWideContainer)
                    heroActionsBlock(compact: !isWideContainer)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        } else {
            // Compact narrow container + wide landscape artwork: exact-aspect top banner + tight action strip
            let maxImgH = min(cardHeight * 0.28, 215)
            let imgSize = fittedAspectSize(ratio: ratio, maxWidth: contentWidth, maxHeight: maxImgH)

            VStack(alignment: .leading, spacing: 11) {
                HStack {
                    Spacer(minLength: 0)
                    heroArtworkButton(size: imgSize)
                    Spacer(minLength: 0)
                }

                heroMetadataBlock(compact: true)
                heroActionsBlock(compact: true)
            }
        }
    }

    private func fittedAspectSize(ratio: CGFloat, maxWidth: CGFloat, maxHeight: CGFloat) -> CGSize {
        let safeRatio = max(0.35, min(2.6, ratio))
        let wByH = maxHeight * safeRatio
        if wByH <= maxWidth {
            return CGSize(width: max(84, wByH.rounded()), height: max(84, maxHeight.rounded()))
        }
        let hByW = maxWidth / safeRatio
        return CGSize(width: max(84, maxWidth.rounded()), height: max(84, hByW.rounded()))
    }

    private func heroArtworkButton(size: CGSize) -> some View {
        Button {
            MobileHaptics.light()
            withAnimation(.easeOut(duration: 0.18)) {
                isImageExpanded = true
            }
        } label: {
            ZStack(alignment: .topLeading) {
                PinterestRemoteThumbMobile(
                    url: pin.originalURL,
                    fallbackURL: pin.previewURL,
                    dominantHex: pin.dominantColorHex,
                    maxPixels: 1400,
                    contentMode: .fill
                )
                .frame(width: size.width, height: size.height)
                .clipShape(RoundedRectangle(cornerRadius: 13, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 13, style: .continuous)
                        .strokeBorder(MobileTheme.hairline(for: colorScheme), lineWidth: 0.7)
                )

                if pin.isVideo {
                    HStack(spacing: 4) {
                        Image(systemName: "video.fill")
                            .font(.system(size: 9.5, weight: .bold))
                        Text("视频")
                            .font(.system(size: 10, weight: .semibold))
                    }
                    .foregroundStyle(.white)
                    .padding(.horizontal, 7)
                    .padding(.vertical, 3)
                    .background(Color.black.opacity(0.62), in: Capsule())
                    .padding(7)
                }
            }
        }
        .buttonStyle(.plain)
    }

    private func heroMetadataBlock(compact: Bool) -> some View {
        VStack(alignment: .leading, spacing: compact ? 4 : 6) {
            Text(pin.displayTitle)
                .font(.system(size: compact ? 15 : 17, weight: .semibold))
                .lineLimit(compact ? 2 : 3)

            if !pin.descriptionText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
               pin.descriptionText != pin.displayTitle {
                Text(pin.descriptionText)
                    .font(.system(size: compact ? 12 : 13))
                    .foregroundStyle(MobileTheme.secondaryInk(for: colorScheme))
                    .lineLimit(compact ? 3 : 4)
            }

            HStack(spacing: 8) {
                if let pinner = pin.pinnerName, !pinner.isEmpty {
                    Label(pinner, systemImage: "person.crop.circle")
                }
                if let board = pin.boardName, !board.isEmpty {
                    Label(board, systemImage: "rectangle.3.group")
                }
                Text("\(pin.width)×\(pin.height)")
            }
            .font(.system(size: 11))
            .foregroundStyle(MobileTheme.tertiaryInk(for: colorScheme))
            .lineLimit(1)
        }
    }

    private func heroActionsBlock(compact: Bool) -> some View {
        VStack(spacing: 7) {
            Button {
                onToggleTray(pin)
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: isInTray ? "checkmark.circle.fill" : "cart.badge.plus")
                        .font(.system(size: 13, weight: .semibold))
                    Text(isInTray ? (compact ? "已在托盘" : "已在采集托盘（点此移出）") : "加入采集托盘")
                        .font(.system(size: compact ? 13 : 13.5, weight: .semibold))
                        .lineLimit(1)
                }
                .foregroundStyle(isInTray ? Color.primary : Color.white)
                .frame(maxWidth: .infinity)
                .frame(height: compact ? 36 : 40)
                .background(
                    isInTray
                        ? MobileTheme.surfaceSubtle(for: colorScheme)
                        : MobileTheme.accentButtonFill(for: colorScheme),
                    in: RoundedRectangle(cornerRadius: 10, style: .continuous)
                )
            }
            .buttonStyle(.plain)

            HStack(spacing: 7) {
                Button {
                    onImportSingle(pin)
                } label: {
                    HStack(spacing: 4) {
                        if isSingleImporting {
                            ProgressView().controlSize(.small)
                        } else {
                            Image(systemName: isImported ? "checkmark.circle.fill" : "square.and.arrow.down")
                                .font(.system(size: 11.5, weight: .semibold))
                        }
                        Text(isImported ? "已入库" : (compact ? "入库" : "直接入库"))
                            .lineLimit(1)
                    }
                    .font(.system(size: compact ? 12 : 12.5, weight: .medium))
                    .foregroundStyle(.primary)
                    .frame(maxWidth: .infinity)
                    .frame(height: compact ? 34 : 36)
                    .background(MobileTheme.surfaceSubtle(for: colorScheme), in: RoundedRectangle(cornerRadius: 9, style: .continuous))
                }
                .buttonStyle(.plain)
                .disabled(isSingleImporting)

                Button {
                    onExploreSimilarInSpace(pin)
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "sparkles")
                            .font(.system(size: 11.5, weight: .semibold))
                            .foregroundStyle(accent)
                        Text(compact ? "看相似" : "空间看相似")
                            .lineLimit(1)
                    }
                    .font(.system(size: compact ? 12 : 12.5, weight: .medium))
                    .foregroundStyle(.primary)
                    .frame(maxWidth: .infinity)
                    .frame(height: compact ? 34 : 36)
                    .background(MobileTheme.surfaceSubtle(for: colorScheme), in: RoundedRectangle(cornerRadius: 9, style: .continuous))
                }
                .buttonStyle(.plain)
            }
        }
    }

    private var subtitleText: String {
        var parts: [String] = ["Pinterest 条目"]
        if let board = pin.boardName, !board.isEmpty { parts.append(board) }
        if let domain = pin.domain, !domain.isEmpty { parts.append(domain) }
        return parts.joined(separator: " · ")
    }

    private func similarCard(_ simPin: PinterestPin) -> some View {
        let inTray = controller.isInTray(simPin.id)
        return ZStack(alignment: .topTrailing) {
            Button {
                MobileHaptics.light()
                controller.openPinDetail(simPin, resetStack: false)
            } label: {
                PinterestRemoteThumbMobile(url: simPin.previewURL, dominantHex: simPin.dominantColorHex, maxPixels: 480)
                    .aspectRatio(simPin.aspectRatio, contentMode: .fit)
                    .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                    .overlay(
                        RoundedRectangle(cornerRadius: 12, style: .continuous)
                            .strokeBorder(inTray ? accent : MobileTheme.hairline(for: colorScheme), lineWidth: inTray ? 2 : 0.7)
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
                    .background(inTray ? accent : Color.black.opacity(0.58), in: Circle())
                    .overlay(Circle().strokeBorder(Color.white.opacity(0.32), lineWidth: 0.75))
            }
            .buttonStyle(.plain)
            .padding(6)
        }
    }

    private func distributeColumns(_ pins: [PinterestPin], count: Int) -> [[PinterestPin]] {
        let cols = max(1, count)
        var buckets = Array(repeating: [PinterestPin](), count: cols)
        var heights = Array(repeating: Double(0), count: cols)
        for p in pins {
            let minIdx = heights.enumerated().min(by: { $0.element < $1.element })?.offset ?? 0
            buckets[minIdx].append(p)
            heights[minIdx] += 1.0 / max(0.45, p.aspectRatio)
        }
        return buckets
    }
}

// MARK: - Shopping-Cart Collection Tray Sheet (iOS & iPadOS)

private struct PinterestTraySheetMobile: View {
    @Environment(\.colorScheme) private var colorScheme
    @Bindable var store: MobileAppStore
    @Bindable var controller: PinterestExploreController
    let accent: Color
    let onOpenPinDetail: (PinterestPin) -> Void

    @State private var targetFolderID: UUID? = nil
    @State private var extraTagsText: String = ""

    private struct JustifiedTrayRow: Identifiable {
        let id: String
        let height: CGFloat
        let items: [(pin: PinterestPin, width: CGFloat)]
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                if controller.trayPins.isEmpty {
                    ContentUnavailableView(
                        "采集托盘是空的",
                        systemImage: "cart",
                        description: Text("切换到左下角快选模式点击卡片即可批量加入托盘。")
                    )
                } else {
                    // Selection Controls Strip
                    HStack(spacing: 10) {
                        Text("已勾选 \(controller.selectedTrayCount)/\(controller.trayCount) · 点卡片跳转条目")
                            .font(.system(size: 12))
                            .foregroundStyle(MobileTheme.secondaryInk(for: colorScheme))
                        Spacer()
                        let allPicked = controller.selectedTrayCount == controller.trayCount
                        Button(allPicked ? "取消全选" : "全选") {
                            if allPicked { controller.deselectAllTray() } else { controller.selectAllTray() }
                        }
                        .font(.system(size: 12.5, weight: .semibold))
                        .foregroundStyle(accent)
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 8)

                    // Justified Horizontal Waterfall (横向等高瀑布流 — zero forced square cropping!)
                    GeometryReader { proxy in
                        let horizontalPadding: CGFloat = 14
                        let spacing: CGFloat = 8
                        let availableWidth = max(240, proxy.size.width - horizontalPadding * 2)
                        let targetRowHeight: CGFloat = availableWidth >= 560 ? 164 : 138
                        let rows = buildJustifiedRows(
                            pins: controller.trayPins,
                            availableWidth: availableWidth,
                            targetRowHeight: targetRowHeight,
                            spacing: spacing
                        )

                        ScrollView {
                            LazyVStack(alignment: .leading, spacing: spacing) {
                                ForEach(rows) { row in
                                    HStack(spacing: spacing) {
                                        ForEach(row.items, id: \.pin.id) { entry in
                                            trayCard(entry.pin, width: entry.width, height: row.height)
                                        }
                                    }
                                }
                            }
                            .padding(.horizontal, horizontalPadding)
                            .padding(.vertical, 8)
                        }
                    }

                    Divider()

                    // Target Folder & Batch Actions Bar
                    VStack(spacing: 10) {
                        HStack(spacing: 10) {
                            Menu {
                                Button {
                                    targetFolderID = nil
                                } label: {
                                    Label("收件箱（默认）", systemImage: "tray")
                                }
                                if !store.flattenedFolders.isEmpty {
                                    Divider()
                                    ForEach(store.flattenedFolders) { node in
                                        Button {
                                            targetFolderID = node.folder.id
                                        } label: {
                                            Text(String(repeating: "  ", count: min(node.depth, 4)) + node.folder.name)
                                        }
                                    }
                                }
                            } label: {
                                HStack(spacing: 5) {
                                    Image(systemName: targetFolderID == nil ? "tray" : "folder")
                                        .foregroundStyle(accent)
                                    Text(selectedFolderLabel)
                                        .font(.system(size: 12.5, weight: .medium))
                                        .lineLimit(1)
                                    Image(systemName: "chevron.up.chevron.down")
                                        .font(.system(size: 9.5))
                                        .foregroundStyle(MobileTheme.secondaryInk(for: colorScheme))
                                }
                                .padding(.horizontal, 10)
                                .frame(height: 34)
                                .background(MobileTheme.surfaceSubtle(for: colorScheme), in: RoundedRectangle(cornerRadius: 9, style: .continuous))
                            }

                            TextField("附加标签（逗号分隔）", text: $extraTagsText)
                                .font(.system(size: 12.5))
                                .padding(.horizontal, 10)
                                .frame(height: 34)
                                .background(MobileTheme.surfaceSubtle(for: colorScheme), in: RoundedRectangle(cornerRadius: 9, style: .continuous))
                        }

                        if let prog = controller.importProgress {
                            ProgressView(value: Double(prog.completed), total: Double(max(1, prog.total))) {
                                Text("正在导入素材库 \(prog.completed)/\(prog.total)…")
                                    .font(.system(size: 12))
                            }
                            .tint(accent)
                        }

                        HStack(spacing: 10) {
                            Button(role: .destructive) {
                                let removed = controller.removeSelectedFromTray()
                                MobileHaptics.light()
                                store.showToast("已从托盘移除 \(removed) 项", tone: .info)
                            } label: {
                                Text("移除已选 (\(controller.selectedTrayCount))")
                                    .font(.system(size: 13, weight: .semibold))
                                    .frame(height: 42)
                                    .padding(.horizontal, 14)
                                    .background(MobileTheme.surfaceSubtle(for: colorScheme), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                            }
                            .disabled(controller.isImportingTray || controller.selectedTrayCount == 0)

                            Button {
                                importSelected()
                            } label: {
                                HStack(spacing: 6) {
                                    Image(systemName: "square.and.arrow.down")
                                    Text(controller.isImportingTray ? "入库中…" : "批量导入素材库 (\(controller.selectedTrayCount))")
                                        .fontWeight(.semibold)
                                }
                                .font(.system(size: 13.5))
                                .foregroundStyle(.white)
                                .frame(maxWidth: .infinity)
                                .frame(height: 42)
                                .background(MobileTheme.accentButtonFill(for: colorScheme), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                            }
                            .buttonStyle(.plain)
                            .disabled(controller.isImportingTray || controller.selectedTrayCount == 0)
                        }
                    }
                    .padding(.horizontal, 14)
                    .padding(.vertical, 12)
                }
            }
            .navigationTitle("采集托盘 (\(controller.trayCount))")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    if !controller.trayPins.isEmpty {
                        Button("清空", role: .destructive) {
                            controller.clearTray()
                        }
                        .disabled(controller.isImportingTray)
                    }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("完成") {
                        controller.isTrayExpanded = false
                    }
                }
            }
        }
    }

    private func buildJustifiedRows(
        pins: [PinterestPin],
        availableWidth: CGFloat,
        targetRowHeight: CGFloat,
        spacing: CGFloat
    ) -> [JustifiedTrayRow] {
        guard !pins.isEmpty else { return [] }
        var rows: [JustifiedTrayRow] = []
        var currentPins: [PinterestPin] = []
        var aspectSum: CGFloat = 0

        for pin in pins {
            let ratio = CGFloat(pin.aspectRatio)
            let nextCount = currentPins.count + 1
            let nextAspectSum = aspectSum + ratio
            let projectedWidth = nextAspectSum * targetRowHeight + spacing * CGFloat(max(0, nextCount - 1))

            if !currentPins.isEmpty && projectedWidth > availableWidth * 1.06 {
                let gaps = spacing * CGFloat(max(0, currentPins.count - 1))
                let exactHeight = max(92, min(targetRowHeight * 1.45, (availableWidth - gaps) / max(0.2, aspectSum)))
                let rowItems = currentPins.map { p in
                    (pin: p, width: max(56, (exactHeight * CGFloat(p.aspectRatio)).rounded(.down)))
                }
                rows.append(JustifiedTrayRow(
                    id: currentPins.map(\.id).joined(separator: "-"),
                    height: exactHeight.rounded(.down),
                    items: rowItems
                ))
                currentPins = [pin]
                aspectSum = ratio
            } else {
                currentPins.append(pin)
                aspectSum = nextAspectSum
            }
        }

        if !currentPins.isEmpty {
            let gaps = spacing * CGFloat(max(0, currentPins.count - 1))
            let naturalWidth = aspectSum * targetRowHeight + gaps
            let finalHeight: CGFloat
            if naturalWidth >= availableWidth * 0.72 {
                finalHeight = max(92, min(targetRowHeight * 1.32, (availableWidth - gaps) / max(0.2, aspectSum)))
            } else {
                finalHeight = targetRowHeight
            }
            let rowItems = currentPins.map { p in
                (pin: p, width: max(56, min(availableWidth, (finalHeight * CGFloat(p.aspectRatio)).rounded(.down))))
            }
            rows.append(JustifiedTrayRow(
                id: currentPins.map(\.id).joined(separator: "-"),
                height: finalHeight.rounded(.down),
                items: rowItems
            ))
        }

        return rows
    }

    private func trayCard(_ pin: PinterestPin, width: CGFloat, height: CGFloat) -> some View {
        let isSelected = controller.selectedTrayPinIDs.contains(pin.id)
        let isImported = controller.importedPinIDs.contains(pin.id)

        return ZStack(alignment: .top) {
            // Tap card to jump straight to that Pin's floating Pinterest detail page!
            Button {
                MobileHaptics.light()
                onOpenPinDetail(pin)
            } label: {
                PinterestRemoteThumbMobile(
                    url: pin.previewURL,
                    dominantHex: pin.dominantColorHex,
                    maxPixels: width > 180 ? 520 : 380,
                    contentMode: .fill
                )
                .frame(width: width, height: height)
                .clipShape(RoundedRectangle(cornerRadius: 11, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 11, style: .continuous)
                        .strokeBorder(isSelected ? accent : MobileTheme.hairline(for: colorScheme), lineWidth: isSelected ? 2 : 0.7)
                )
            }
            .buttonStyle(.plain)

            HStack {
                Button {
                    MobileHaptics.light()
                    controller.toggleTraySelection(pin.id)
                } label: {
                    Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                        .font(.system(size: 18, weight: .semibold))
                        .foregroundStyle(isSelected ? accent : .white)
                        .background(Circle().fill(Color.black.opacity(0.45)).padding(2))
                }
                .buttonStyle(.plain)

                Spacer()

                Button {
                    MobileHaptics.light()
                    controller.removeFromTray(pin.id)
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 9.5, weight: .bold))
                        .foregroundStyle(.white)
                        .frame(width: 22, height: 22)
                        .background(Color.black.opacity(0.56), in: Circle())
                }
                .buttonStyle(.plain)
            }
            .padding(6)

            if isImported {
                VStack {
                    Spacer()
                    HStack {
                        Text("已入库")
                            .font(.system(size: 9.5, weight: .semibold))
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
        .frame(width: width, height: height)
    }

    private var selectedFolderLabel: String {
        guard let id = targetFolderID else { return "收件箱" }
        return store.folders.first(where: { $0.id == id })?.name ?? "收件箱"
    }

    private func importSelected() {
        let tags = extraTagsText
            .split { $0 == "," || $0 == "，" }
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        let folderID = targetFolderID

        Task {
            let report = await controller.importTrayPins(
                into: store.engine,
                targetFolderID: folderID,
                extraTags: tags,
                removeImportedFromTray: true
            )
            await store.reloadAll()
            let imported = report.importedAssets.count
            let skipped = report.skippedDuplicatePinIDs.count
            let failed = report.failedPinIDs.count
            if imported > 0 {
                MobileHaptics.success()
                var msg = "已导入 \(imported) 项 Pinterest 素材"
                if skipped > 0 { msg += "（跳过 \(skipped) 项已存在）" }
                if failed > 0 { msg += "，\(failed) 项失败" }
                store.showToast(msg, tone: .success)
            } else if skipped > 0 && failed == 0 {
                store.showToast("所选 \(skipped) 项素材均已在素材库中", tone: .info)
            } else if failed > 0 {
                store.showToast("有 \(failed) 项素材下载失败，已保留在托盘", tone: .warning)
            }
            if controller.trayPins.isEmpty {
                controller.isTrayExpanded = false
            }
        }
    }
}

// MARK: - Batch Import Pinterest Saved Collections by Board Sheet (iOS & iPadOS)

private struct PinterestBoardImportSheetMobile: View {
    @Environment(\.colorScheme) private var colorScheme
    @Bindable var store: MobileAppStore
    @Bindable var controller: PinterestExploreController
    let accent: Color

    @State private var selectedBoardIDs: Set<String> = []
    @State private var hasInitializedSelection: Bool = false
    @State private var destinationMode: Int = 0 // 0: Pinterest root, 1: library root, 2: existing folder
    @State private var customParentFolderID: UUID? = nil
    @State private var skipDuplicates: Bool = true
    @State private var extraTagsText: String = ""

    private var selectedBoards: [PinterestBoard] {
        controller.boards.filter { selectedBoardIDs.contains($0.id) }
    }

    private var totalPinsEstimate: Int {
        selectedBoards.reduce(0) { $0 + max(0, $1.pinCount) }
    }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    if controller.isLoadingBoards && controller.boards.isEmpty {
                        HStack(spacing: 10) {
                            ProgressView()
                            Text("正在读取 Pinterest 画板列表…")
                                .font(.system(size: 13.5))
                                .foregroundStyle(MobileTheme.secondaryInk(for: colorScheme))
                        }
                    } else if controller.boards.isEmpty {
                        VStack(alignment: .leading, spacing: 6) {
                            Text("未发现可导入的画板")
                                .font(.system(size: 14, weight: .semibold))
                            Text("请确认账号下已有保存的画板，或点右上角刷新。")
                                .font(.system(size: 12.5))
                                .foregroundStyle(MobileTheme.secondaryInk(for: colorScheme))
                        }
                        .padding(.vertical, 6)
                    } else {
                        ForEach(controller.boards) { board in
                            let isSelected = selectedBoardIDs.contains(board.id)
                            Button {
                                guard !controller.isImportingBoards else { return }
                                MobileHaptics.light()
                                if isSelected {
                                    selectedBoardIDs.remove(board.id)
                                } else {
                                    selectedBoardIDs.insert(board.id)
                                }
                            } label: {
                                HStack(spacing: 10) {
                                    Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                                        .font(.system(size: 18, weight: .semibold))
                                        .foregroundStyle(isSelected ? accent : MobileTheme.tertiaryInk(for: colorScheme))

                                    if let cover = board.coverURL {
                                        PinterestRemoteThumbMobile(url: cover, dominantHex: nil, maxPixels: 140)
                                            .frame(width: 38, height: 38)
                                            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                                    } else {
                                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                                            .fill(MobileTheme.surfaceSubtle(for: colorScheme))
                                            .frame(width: 38, height: 38)
                                            .overlay(
                                                Image(systemName: "rectangle.3.group")
                                                    .font(.system(size: 14))
                                                    .foregroundStyle(MobileTheme.tertiaryInk(for: colorScheme))
                                            )
                                    }

                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(board.name)
                                            .font(.system(size: 14, weight: .medium))
                                            .foregroundStyle(.primary)
                                            .lineLimit(1)
                                        Text("\(board.pinCount) 项收藏")
                                            .font(.system(size: 12).monospacedDigit())
                                            .foregroundStyle(MobileTheme.secondaryInk(for: colorScheme))
                                    }
                                    Spacer()
                                }
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                        }
                    }
                } header: {
                    HStack {
                        Text("选择要导入的画板（\(selectedBoards.count)/\(controller.boards.count)）")
                        Spacer()
                        if !controller.boards.isEmpty {
                            let allPicked = selectedBoardIDs.count == controller.boards.count
                            Button(allPicked ? "取消全选" : "全选") {
                                if allPicked {
                                    selectedBoardIDs.removeAll()
                                } else {
                                    selectedBoardIDs = Set(controller.boards.map(\.id))
                                }
                            }
                            .font(.system(size: 12, weight: .semibold))
                            .disabled(controller.isImportingBoards)
                        }
                    }
                }

                Section("目录结构") {
                    Picker("存入位置", selection: $destinationMode) {
                        Text("「Pinterest」父目录下按画板建子目录").tag(0)
                        Text("素材库根目录直接按画板建文件夹").tag(1)
                        Text("指定已有文件夹下按画板建子目录").tag(2)
                    }
                    .disabled(controller.isImportingBoards)

                    if destinationMode == 2 {
                        Picker("父文件夹", selection: $customParentFolderID) {
                            ForEach(store.flattenedFolders) { node in
                                Text(String(repeating: "  ", count: min(node.depth, 4)) + node.folder.name)
                                    .tag(Optional(node.folder.id))
                            }
                        }
                        .disabled(controller.isImportingBoards || store.flattenedFolders.isEmpty)
                    }

                    Toggle("跳过已存在的 Pin（增量同步）", isOn: $skipDuplicates)
                        .disabled(controller.isImportingBoards)

                    TextField("附加标签（逗号分隔，可选）", text: $extraTagsText)
                        .disabled(controller.isImportingBoards)
                }

                if let progress = controller.boardImportProgress {
                    Section("正在导入") {
                        VStack(alignment: .leading, spacing: 8) {
                            ProgressView(value: progress.fractionCompleted, total: 1.0)
                                .tint(accent)
                            Text(progress.statusText)
                                .font(.system(size: 13, weight: .medium))
                            Text("新增 \(progress.overallImported) · 跳过重复 \(progress.overallSkipped) · 失败 \(progress.overallFailed)")
                                .font(.system(size: 12).monospacedDigit())
                                .foregroundStyle(MobileTheme.secondaryInk(for: colorScheme))
                        }
                        .padding(.vertical, 4)
                    }
                }

                Section {
                    if controller.isImportingBoards {
                        Button("取消导入", role: .destructive) {
                            controller.cancelBoardImport()
                        }
                    } else {
                        Button {
                            startImport()
                        } label: {
                            HStack {
                                Spacer()
                                Image(systemName: "square.and.arrow.down.on.square")
                                Text("开始导入 \(selectedBoards.count) 个画板（约 \(totalPinsEstimate) 项）")
                                    .fontWeight(.semibold)
                                Spacer()
                            }
                        }
                        .disabled(selectedBoards.isEmpty || (destinationMode == 2 && customParentFolderID == nil))
                    }
                }
            }
            .navigationTitle("批量导入画板收藏")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("关闭") {
                        controller.isBoardImportSheetPresented = false
                    }
                    .disabled(controller.isImportingBoards)
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        Task {
                            await controller.refreshBoards()
                            syncSelectionIfNeeded()
                        }
                    } label: {
                        if controller.isLoadingBoards {
                            ProgressView().controlSize(.small)
                        } else {
                            Image(systemName: "arrow.clockwise")
                        }
                    }
                    .disabled(controller.isImportingBoards)
                }
            }
        }
        .onAppear {
            syncSelectionIfNeeded()
            if customParentFolderID == nil {
                customParentFolderID = store.flattenedFolders.first?.folder.id
            }
        }
        .onChange(of: controller.boards) { _, _ in
            syncSelectionIfNeeded()
        }
    }

    private func syncSelectionIfNeeded() {
        guard !hasInitializedSelection, !controller.boards.isEmpty else { return }
        hasInitializedSelection = true
        selectedBoardIDs = Set(controller.boards.map(\.id))
    }

    private func startImport() {
        let dest: PinterestBoardImportDestination
        switch destinationMode {
        case 1:
            dest = .libraryRoot
        case 2:
            dest = customParentFolderID.map { .existingFolder($0) } ?? .pinterestRootFolder
        default:
            dest = .pinterestRootFolder
        }

        let tags = extraTagsText
            .split { $0 == "," || $0 == "，" }
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        let boardsToImport = selectedBoards

        Task {
            let report = await controller.importBoards(
                boardsToImport,
                into: store.engine,
                destination: dest,
                extraTags: tags,
                skipDuplicates: skipDuplicates
            )
            await store.reloadAll()

            let imported = report.importedAssets.count
            let skipped = report.skippedDuplicatePinIDs.count
            let failed = report.failedPinIDs.count
            var parts: [String] = []
            if imported > 0 { parts.append("新增 \(imported) 项") }
            if skipped > 0 { parts.append("跳过 \(skipped) 项") }
            if failed > 0 { parts.append("失败 \(failed) 项") }
            let detail = parts.isEmpty ? "无新增素材" : parts.joined(separator: "，")
            let title = report.wasCancelled
                ? "已取消画板导入（已处理 \(report.boardsProcessed) 个）"
                : "画板导入完成（\(report.boardsProcessed) 个画板）"
            if imported > 0 { MobileHaptics.success() }
            store.showToast("\(title)：\(detail)", tone: imported > 0 ? .success : .info)

            if !report.wasCancelled {
                controller.isBoardImportSheetPresented = false
            }
        }
    }
}

// MARK: - Floating Chrome Hit-Test Exclusion PreferenceKey (iOS / iPadOS)

private struct PinterestMobileHitExclusionKey: PreferenceKey {
    static let defaultValue: [CGRect] = []
    static func reduce(value: inout [CGRect], nextValue: () -> [CGRect]) {
        value.append(contentsOf: nextValue())
    }
}

private extension View {
    func pinterestExcludeHitTestMobile() -> some View {
        background(
            GeometryReader { proxy in
                Color.clear.preference(
                    key: PinterestMobileHitExclusionKey.self,
                    value: [proxy.frame(in: .global)]
                )
            }
        )
    }
}

// MARK: - Cached Remote Thumbnail Helper (iOS & iPadOS)

private struct PinterestRemoteThumbMobile: View {
    let url: URL
    var fallbackURL: URL? = nil
    let dominantHex: String?
    var maxPixels: Int = 640
    var contentMode: ContentMode = .fill

    @State private var image: UIImage?

    var body: some View {
        ZStack {
            placeholderColor
            if let image {
                Image(uiImage: image)
                    .resizable()
                    .aspectRatio(contentMode: contentMode)
                    .transition(.opacity)
            }
        }
        .task(id: url) {
            if let cached = PinterestImageCache.shared.cachedImage(for: url) {
                image = cached
                return
            }
            if let fallbackURL, let cachedFallback = PinterestImageCache.shared.cachedImage(for: fallbackURL) {
                image = cachedFallback
            }
            if let fetched = await PinterestImageCache.shared.image(for: url, maxPixelSize: maxPixels) {
                withAnimation(.easeOut(duration: 0.16)) {
                    image = fetched
                }
            } else if let fallbackURL,
                      let fetchedFallback = await PinterestImageCache.shared.image(for: fallbackURL, maxPixelSize: maxPixels) {
                withAnimation(.easeOut(duration: 0.16)) {
                    image = fetchedFallback
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
