import CharkleCore
import SwiftUI

enum CompactTab: Hashable {
    case library
    case inbox
    case moodboards
    case search
    case settings
}

enum PreviewZoomOrigin: Hashable, Sendable {
    case library
    case inboxTriage
    case inboxGrid
    case visualSearch
    case moodboard
}

struct PreviewZoomSourceID: Hashable, Sendable {
    let origin: PreviewZoomOrigin
    let assetID: UUID
}

/// Universal iPadOS + iOS root shell:
/// - Regular width (iPad): 2-column `NavigationSplitView` (Redesigned Collapsible Sidebar + Detail).
/// - Compact width (iPhone / Slide Over): Custom Liquid Glass Morphing Bottom Bar (Scheme A):
///   Left 3-tab capsule (`素材库` / `收件箱` / `情绪板`) with real-time scrubbing lens & swipe-up/re-tap
///   Directory drawer; Right companion capsule (`⚙️` 1-tap unified Settings + `🔍` Liquid Search morph).
struct RootShellView: View {
    @Bindable var store: MobileAppStore
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Namespace private var previewZoomNamespace

    @State private var compactTab: CompactTab = .library
    @State private var visitedCompactTabs: Set<CompactTab> = [.library]
    @State private var lastPrimaryTab: MobilePrimaryTab = .library
    @State private var isBottomSearchExpanded: Bool = false
    @State private var searchScopeMode: MobileSearchScopeMode = .all
    @State private var rememberedFolderID: UUID? = nil

    @State private var searchTabIsPinterest: Bool = false
    @State private var moodboardPath: [UUID] = []
    @State private var settingsPath: [MobileSettingsRoute] = []
    @State private var settingsSheetPath: [MobileSettingsRoute] = []
    @State private var splitVisibility: NavigationSplitViewVisibility = .automatic
    @State private var isCapturePresented = false
    @State private var isSettingsSheetPresented = false
    @State private var isFolderDrawerPresented = false
    @State private var isCreateBoardSheetPresented = false

    @State private var detailAsset: AssetRecord?
    @State private var detailOrigin: PreviewZoomOrigin = .library
    @State private var detailInitialTab: AssetDetailView.DetailInspectorTab = .info
    @State private var detailOpenInspectorImmediately: Bool = false
    @State private var activeDetailAssetID: UUID?

    @State private var showNewFolderAlert = false
    @State private var newFolderName = ""

    private var showsCompactBottomBar: Bool {
        guard horizontalSizeClass != .regular else { return false }
        if store.isMultiSelectMode { return false }
        if compactTab == .moodboards && !moodboardPath.isEmpty { return false }
        if compactTab == .search && searchTabIsPinterest { return false }
        return true
    }

    private var activeFolderScopeTitle: String? {
        guard let id = rememberedFolderID ?? store.activeFolderIDForCapture else { return nil }
        return store.folders.first(where: { $0.id == id })?.name
    }

    var body: some View {
        ZStack(alignment: .bottom) {
            Group {
                if horizontalSizeClass == .regular {
                    regularIPadShell
                } else {
                    compactIPhoneShell
                }
            }

            if let toast = store.toast {
                toastBanner(toast)
                    .padding(.horizontal, MobileTheme.Space.lg)
                    .padding(.bottom, horizontalSizeClass == .regular ? 24 : (showsCompactBottomBar ? 82 : 24))
                    .transition(.move(edge: .bottom).combined(with: .opacity))
                    .zIndex(100)
            }
        }
        .sheet(isPresented: $isCapturePresented) {
            CaptureSheetView(store: store)
                .presentationDetents([.medium, .large])
                .presentationDragIndicator(.visible)
        }
        .sheet(isPresented: $isSettingsSheetPresented) {
            NavigationStack(path: $settingsSheetPath) {
                MobileSettingsView(store: store, showDoneButton: true)
            }
            .presentationDetents([.large])
        }
        .sheet(isPresented: $isCreateBoardSheetPresented) {
            NavigationStack {
                CreateMoodboardSheet(store: store) { createdID in
                    isCreateBoardSheetPresented = false
                    openBoard(createdID)
                }
            }
            .presentationDetents([.medium, .large])
        }
        .sheet(isPresented: $isFolderDrawerPresented) {
            NavigationStack {
                SidebarNavigationView(
                    store: store,
                    isCompactSheet: true,
                    onSelectScope: { scope in
                        navigateToScope(scope)
                        isFolderDrawerPresented = false
                    },
                    onOpenSyncSettings: {
                        isFolderDrawerPresented = false
                        openCompactSettings(jumpToSync: false)
                    },
                    onCreateFolder: {
                        showNewFolderAlert = true
                    },
                    onCreateMoodboard: {
                        isFolderDrawerPresented = false
                        isCreateBoardSheetPresented = true
                    }
                )
                .navigationTitle("目录与筛选")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .confirmationAction) {
                        Button("完成") { isFolderDrawerPresented = false }
                    }
                }
            }
            .presentationDetents([.medium, .large])
        }
        .fullScreenCover(item: $detailAsset) { asset in
            let contextAssets: [AssetRecord] = {
                if (detailOrigin == .inboxTriage || detailOrigin == .inboxGrid),
                   store.inboxAssets.contains(where: { $0.id == asset.id }) {
                    return store.inboxAssets
                }
                if store.assets.contains(where: { $0.id == asset.id }) {
                    return store.assets
                }
                return [asset]
            }()
            AssetDetailView(
                store: store,
                initialAsset: asset,
                allAssets: contextAssets,
                initialInspectorTab: detailInitialTab,
                openInspectorImmediately: detailOpenInspectorImmediately,
                onCurrentAssetChanged: { nextID in
                    activeDetailAssetID = nextID
                },
                onFilterByColor: { hex in
                    detailAsset = nil
                    store.setColorFilter(hex)
                },
                onFilterByTag: { tag in
                    detailAsset = nil
                    store.selectScope(.tag(tag))
                    if horizontalSizeClass != .regular {
                        isBottomSearchExpanded = false
                        compactTab = .library
                    }
                }
            )
            .navigationTransition(
                .zoom(
                    sourceID: PreviewZoomSourceID(
                        origin: detailOrigin,
                        assetID: activeDetailAssetID ?? asset.id
                    ),
                    in: previewZoomNamespace
                )
            )
        }
        .alert("新建文件夹", isPresented: $showNewFolderAlert) {
            TextField("文件夹名称", text: $newFolderName)
            Button("取消", role: .cancel) { newFolderName = "" }
            Button("创建") {
                let name = newFolderName.trimmingCharacters(in: .whitespacesAndNewlines)
                newFolderName = ""
                guard !name.isEmpty else { return }
                let parentID = store.activeFolderIDForCapture
                Task { await store.createFolder(name: name, parentID: parentID) }
            }
        } message: {
            Text("新建文件夹将通过已连接的云端后端双向同步到 Mac 与 Windows。")
        }
        .onChange(of: store.scope) { _, nextScope in
            if case .folder(let id) = nextScope {
                rememberedFolderID = id
            }
        }
    }

    // MARK: - iPad Regular Layout

    private var regularIPadShell: some View {
        NavigationSplitView(columnVisibility: $splitVisibility) {
            SidebarNavigationView(
                store: store,
                isCompactSheet: false,
                onSelectScope: { store.selectScope($0) },
                onOpenSyncSettings: { openIPadSettings(jumpToSync: false) },
                onCreateFolder: { showNewFolderAlert = true },
                onCreateMoodboard: { isCreateBoardSheetPresented = true }
            )
            .navigationTitle("Charkle")
            .navigationSplitViewColumnWidth(min: 248, ideal: 280, max: 340)
        } detail: {
            NavigationStack {
                Group {
                    switch store.scope {
                    case .inbox:
                        InboxTriageView(
                            store: store,
                            zoomNamespace: previewZoomNamespace,
                            onOpenAsset: { asset, origin in openAsset(asset, from: origin) },
                            onFindSimilar: { asset, origin in openAsset(asset, from: origin, inspectorTab: .similar, openInspector: true) },
                            onOpenCapture: { isCapturePresented = true }
                        )
                    case .moodboardsHome:
                        MoodboardsListView(
                            store: store,
                            onOpenBoard: { store.selectScope(.moodboard($0)) }
                        )
                    case .moodboard(let boardID):
                        MoodboardStudioView(
                            store: store,
                            boardID: boardID,
                            onOpenAsset: { openAsset($0, from: .moodboard) },
                            onRevealAssetInLibrary: { revealAssetInLibrary($0, sourceBoardID: boardID) }
                        )
                    case .pinterest:
                        PinterestExploreMobileView(
                            store: store,
                            controller: store.pinterestController,
                            onToggleSidebar: {
                                withAnimation(MobileMotion.drawerEase) {
                                    splitVisibility = (splitVisibility == .detailOnly) ? .all : .detailOnly
                                }
                            }
                        )
                        .toolbar(.hidden, for: .navigationBar)
                    default:
                        MasonryGalleryView(
                            store: store,
                            isCompact: false,
                            showPhotosFloatingHeader: false,
                            zoomNamespace: previewZoomNamespace,
                            zoomOrigin: .library,
                            onOpenAsset: { openAsset($0, from: .library) },
                            onFindSimilar: { openAsset($0, from: .library, inspectorTab: .similar, openInspector: true) },
                            onOpenCapture: { isCapturePresented = true },
                            onOpenSyncSettings: { openIPadSettings(jumpToSync: true) },
                            onOpenFolders: nil
                        )
                    }
                }
                .navigationTitle(store.currentScopeTitle)
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    if !isMoodboardScope(store.scope) && store.scope != .pinterest {
                        ToolbarItemGroup(placement: .topBarTrailing) {
                            Button {
                                Task { await store.captureFromPasteboard() }
                            } label: {
                                Label("粘贴收藏", systemImage: "doc.on.clipboard")
                            }
                            .keyboardShortcut("v", modifiers: [.command, .shift])

                            Button {
                                isCapturePresented = true
                            } label: {
                                Label("采集素材", systemImage: "plus")
                            }
                            .keyboardShortcut("n", modifiers: .command)

                            Button {
                                if store.hasConnectedCloudBackend {
                                    Task { await store.syncNow(quiet: false) }
                                } else {
                                    openIPadSettings(jumpToSync: true)
                                }
                            } label: {
                                if store.syncStatus.isSyncing || store.isSyncing {
                                    ProgressView()
                                        .controlSize(.small)
                                } else {
                                    Label(
                                        store.hasConnectedCloudBackend ? "同步" : "配置云同步",
                                        systemImage: store.hasConnectedCloudBackend ? "arrow.triangle.2.circlepath" : "icloud.slash"
                                    )
                                }
                            }
                            .keyboardShortcut("r", modifiers: .command)

                            Button {
                                openIPadSettings(jumpToSync: false)
                            } label: {
                                Label("设置", systemImage: "gearshape")
                            }
                        }
                    }
                }
            }
        }
        .navigationSplitViewStyle(.balanced)
    }

    // MARK: - iPhone Compact Layout (Liquid Glass Morphing Bottom Bar — Scheme A)

    private var compactIPhoneShell: some View {
        ZStack {
            compactTabSlot(.library) {
                NavigationStack {
                    MasonryGalleryView(
                        store: store,
                        isCompact: true,
                        showPhotosFloatingHeader: true,
                        zoomNamespace: previewZoomNamespace,
                        zoomOrigin: .library,
                        onOpenAsset: { openAsset($0, from: .library) },
                        onFindSimilar: { openAsset($0, from: .library, inspectorTab: .similar, openInspector: true) },
                        onOpenCapture: { isCapturePresented = true },
                        onOpenSyncSettings: { openCompactSettings(jumpToSync: true) },
                        onOpenFolders: { isFolderDrawerPresented = true }
                    )
                    .toolbar(.hidden, for: .navigationBar)
                }
            }

            if visitedCompactTabs.contains(.inbox) {
                compactTabSlot(.inbox) {
                    NavigationStack {
                        InboxTriageView(
                            store: store,
                            zoomNamespace: previewZoomNamespace,
                            onOpenAsset: { asset, origin in openAsset(asset, from: origin) },
                            onFindSimilar: { asset, origin in openAsset(asset, from: origin, inspectorTab: .similar, openInspector: true) },
                            onOpenCapture: { isCapturePresented = true }
                        )
                        .charkleScrollEdgeSoft(for: .bottom)
                        .navigationTitle("收件箱")
                        .navigationBarTitleDisplayMode(.inline)
                        .toolbar {
                            ToolbarItem(placement: .topBarTrailing) {
                                Button {
                                    isCapturePresented = true
                                } label: {
                                    Image(systemName: "plus")
                                }
                            }
                        }
                    }
                }
            }

            if visitedCompactTabs.contains(.moodboards) {
                compactTabSlot(.moodboards) {
                    NavigationStack(path: $moodboardPath) {
                        MoodboardsListView(
                            store: store,
                            onOpenBoard: { boardID in
                                moodboardPath.append(boardID)
                            }
                        )
                        .charkleScrollEdgeSoft(for: .bottom)
                        .navigationDestination(for: UUID.self) { boardID in
                            MoodboardStudioView(
                                store: store,
                                boardID: boardID,
                                onOpenAsset: { openAsset($0, from: .moodboard) },
                                onRevealAssetInLibrary: { revealAssetInLibrary($0, sourceBoardID: boardID) }
                            )
                        }
                    }
                }
            }

            if visitedCompactTabs.contains(.search) {
                compactTabSlot(.search) {
                    NavigationStack {
                        Group {
                            if searchTabIsPinterest {
                                PinterestExploreMobileView(
                                    store: store,
                                    controller: store.pinterestController,
                                    onSwitchToLibrarySearch: {
                                        searchTabIsPinterest = false
                                        searchScopeMode = .all
                                        isBottomSearchExpanded = true
                                    }
                                )
                                .toolbar(.hidden, for: .navigationBar)
                            } else {
                                VisualSearchTabView(
                                    store: store,
                                    zoomNamespace: previewZoomNamespace,
                                    onOpenAsset: { openAsset($0, from: .visualSearch) },
                                    onFindSimilar: { openAsset($0, from: .visualSearch, inspectorTab: .similar, openInspector: true) },
                                    onNavigateToScope: { scope in navigateToScope(scope) },
                                    onOpenBoard: { openBoard($0) },
                                    onOpenPinterestSpace: {
                                        searchScopeMode = .pinterest
                                        searchTabIsPinterest = true
                                    },
                                    externalSearchBarActive: isBottomSearchExpanded,
                                    searchScopeMode: searchScopeMode,
                                    activeFolderScopeTitle: activeFolderScopeTitle,
                                    onClearFolderScope: {
                                        applySearchScopeMode(.all)
                                    }
                                )
                                .navigationTitle("搜图")
                                .navigationBarTitleDisplayMode(.inline)
                            }
                        }
                    }
                }
            }

            if visitedCompactTabs.contains(.settings) {
                compactTabSlot(.settings) {
                    NavigationStack(path: $settingsPath) {
                        MobileSettingsView(store: store, showDoneButton: false)
                    }
                }
            }
        }
        // Full-bleed scroll behind floating glass with automatic bottom clearance for ScrollView / Form / List
        .safeAreaInset(edge: .bottom, spacing: 0) {
            Color.clear
                .frame(height: showsCompactBottomBar ? 74 : 0)
                .allowsHitTesting(false)
        }
        .overlay(alignment: .bottom) {
            if showsCompactBottomBar {
                LiquidGlassMorphingTabBar(
                    store: store,
                    activeTab: $compactTab,
                    lastPrimaryTab: $lastPrimaryTab,
                    isSearchExpanded: $isBottomSearchExpanded,
                    searchScopeMode: $searchScopeMode,
                    onOpenDirectoryAndFilters: {
                        isFolderDrawerPresented = true
                    },
                    onSelectSettings: {
                        openCompactSettings(jumpToSync: false)
                    },
                    onSelectSearchMode: { mode in
                        applySearchScopeMode(mode)
                    }
                )
                .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .animation(MobileMotion.accessible(MobileMotion.enterSm, reduced: reduceMotion), value: showsCompactBottomBar)
        .onChange(of: compactTab) { _, next in
            visitedCompactTabs.insert(next)
            switch next {
            case .library:
                lastPrimaryTab = .library
                isBottomSearchExpanded = false
                if store.scope == .inbox || isMoodboardScope(store.scope) {
                    store.selectScope(.allItems)
                }
            case .inbox:
                lastPrimaryTab = .inbox
                isBottomSearchExpanded = false
            case .moodboards:
                lastPrimaryTab = .moodboards
                isBottomSearchExpanded = false
            case .search:
                if searchScopeMode != .currentFolder,
                   (store.scope == .inbox || store.scope == .trash || isMoodboardScope(store.scope)) {
                    store.selectScope(.allItems)
                }
            case .settings:
                isBottomSearchExpanded = false
                Task { await store.loadSyncAndStorageState() }
            }
        }
    }

    @ViewBuilder
    private func compactTabSlot<Content: View>(_ tab: CompactTab, @ViewBuilder content: () -> Content) -> some View {
        let isActive = compactTab == tab
        content()
            .opacity(isActive ? 1 : 0)
            .allowsHitTesting(isActive)
            .accessibilityHidden(!isActive)
            .zIndex(isActive ? 1 : 0)
    }

    // MARK: - Navigation & Search Scope Routing

    private func openIPadSettings(jumpToSync: Bool) {
        settingsSheetPath = jumpToSync ? [.sync] : []
        isSettingsSheetPresented = true
    }

    private func openCompactSettings(jumpToSync: Bool) {
        visitedCompactTabs.insert(.settings)
        isBottomSearchExpanded = false
        settingsPath = jumpToSync ? [.sync] : []
        compactTab = .settings
    }

    private func applySearchScopeMode(_ mode: MobileSearchScopeMode) {
        searchScopeMode = mode
        switch mode {
        case .all:
            searchTabIsPinterest = false
            if store.scope != .allItems {
                store.selectScope(.allItems)
            }
        case .color:
            searchTabIsPinterest = false
            if store.scope == .inbox || store.scope == .trash || isMoodboardScope(store.scope) {
                store.selectScope(.allItems)
            }
        case .currentFolder:
            searchTabIsPinterest = false
            if let folderID = rememberedFolderID ?? store.activeFolderIDForCapture {
                store.selectScope(.folder(folderID))
            } else {
                store.showToast("请先在「目录与筛选」中选择一个文件夹，当前仍按全库搜图", tone: .info)
            }
        case .pinterest:
            searchTabIsPinterest = true
        }
    }

    private func isMoodboardScope(_ scope: MobileScope) -> Bool {
        switch scope {
        case .moodboardsHome, .moodboard: return true
        default: return false
        }
    }

    private func navigateToScope(_ scope: MobileScope) {
        if horizontalSizeClass == .regular {
            store.selectScope(scope)
            return
        }
        switch scope {
        case .inbox:
            compactTab = .inbox
        case .moodboardsHome:
            moodboardPath.removeAll()
            compactTab = .moodboards
        case .moodboard(let id):
            moodboardPath = [id]
            compactTab = .moodboards
        case .pinterest:
            searchScopeMode = .pinterest
            searchTabIsPinterest = true
            isBottomSearchExpanded = true
            compactTab = .search
        default:
            if case .folder(let id) = scope {
                rememberedFolderID = id
            }
            store.selectScope(scope)
            isBottomSearchExpanded = false
            compactTab = .library
        }
    }

    private func openBoard(_ id: UUID) {
        if horizontalSizeClass == .regular {
            store.selectScope(.moodboard(id))
        } else {
            isBottomSearchExpanded = false
            compactTab = .moodboards
            if moodboardPath.last != id {
                moodboardPath.append(id)
            }
        }
    }

    private func revealAssetInLibrary(_ assetID: UUID, sourceBoardID: UUID? = nil) {
        Task {
            guard let result = await store.revealAssetInLibrary(assetID: assetID) else { return }
            if horizontalSizeClass != .regular {
                isBottomSearchExpanded = false
                compactTab = .library
            }
            if let sourceBoardID {
                store.showToast(
                    "已定位到「\(result.locationLabel)」",
                    tone: .info,
                    actionTitle: "返回情绪板",
                    onAction: {
                        openBoard(sourceBoardID)
                    }
                )
            } else {
                store.showToast("已定位到「\(result.locationLabel)」", tone: .info)
            }
        }
    }

    private func openAsset(
        _ asset: AssetRecord,
        from origin: PreviewZoomOrigin,
        inspectorTab: AssetDetailView.DetailInspectorTab = .info,
        openInspector: Bool = false
    ) {
        Task { await store.engine.markAssetOpened(id: asset.id) }
        let hasRichWebPreview = asset.hasExtractableLinkMedia || (asset.richMetadata?.webPage?.hasRichSummary == true)
        if !openInspector, asset.isExternalWebLink, !hasRichWebPreview, let url = asset.externalWebURL {
            UIApplication.shared.open(url)
            return
        }
        detailOrigin = origin
        detailInitialTab = inspectorTab
        detailOpenInspectorImmediately = openInspector
        activeDetailAssetID = asset.id
        detailAsset = asset
    }

    // MARK: - Toast Overlay

    private func toastBanner(_ toast: MobileToast) -> some View {
        let iconName: String
        let iconColor: Color
        switch toast.tone {
        case .info:
            iconName = "info.circle.fill"
            iconColor = MobileTheme.accent(for: colorScheme)
        case .success:
            iconName = "checkmark.circle.fill"
            iconColor = MobileTheme.positive(for: colorScheme)
        case .warning:
            iconName = "exclamationmark.triangle.fill"
            iconColor = MobileTheme.warning(for: colorScheme)
        case .error:
            iconName = "xmark.octagon.fill"
            iconColor = MobileTheme.destructive(for: colorScheme)
        }

        return HStack(spacing: MobileTheme.Space.sm) {
            Image(systemName: iconName)
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(iconColor)
            Text(toast.message)
                .font(.system(size: 13.5, weight: .medium))
                .foregroundStyle(.primary)
                .lineLimit(2)
            if let actionTitle = toast.actionTitle, let onAction = toast.onAction {
                Button(actionTitle) {
                    MobileHaptics.light()
                    store.toast = nil
                    onAction()
                }
                .font(.system(size: 12.5, weight: .semibold))
                .foregroundStyle(.white)
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                .background(MobileTheme.accentButtonFill(for: colorScheme), in: Capsule())
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .charkleFloatingCapsule(interactive: toast.actionTitle != nil)
    }
}
