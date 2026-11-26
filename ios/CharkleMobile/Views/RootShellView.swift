import CharkleCore
import SwiftUI

enum CompactTab: Hashable {
    case library
    case inbox
    case moodboards
    case search
    case sync
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
/// - Regular width (iPad): 2-column `NavigationSplitView` (Sidebar + Gallery / Inbox / Moodboards).
/// - Compact width (iPhone / Slide Over): 5-tab `TabView` (素材库 / 收件箱 / 情绪板 / 搜图 / 同步),
///   with full-bleed iOS Photos-style floating header on `素材库` and swipe-up/re-tap on the `素材库` tab
///   opening `目录与筛选`.
struct RootShellView: View {
    @Bindable var store: MobileAppStore
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @Environment(\.colorScheme) private var colorScheme
    @Namespace private var previewZoomNamespace

    @State private var compactTab: CompactTab = .library
    @State private var searchTabIsPinterest: Bool = false
    @State private var moodboardPath: [UUID] = []
    @State private var splitVisibility: NavigationSplitViewVisibility = .automatic
    @State private var isCapturePresented = false
    @State private var isSyncSheetPresented = false
    @State private var isFolderDrawerPresented = false
    @State private var isCreateBoardSheetPresented = false

    @State private var detailAsset: AssetRecord?
    @State private var detailOrigin: PreviewZoomOrigin = .library
    @State private var detailInitialTab: AssetDetailView.DetailInspectorTab = .info
    @State private var detailOpenInspectorImmediately: Bool = false
    @State private var activeDetailAssetID: UUID?

    @State private var showNewFolderAlert = false
    @State private var newFolderName = ""

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
                    .padding(.bottom, horizontalSizeClass == .regular ? 24 : 64)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
                    .zIndex(100)
            }
        }
        .sheet(isPresented: $isCapturePresented) {
            CaptureSheetView(store: store)
                .presentationDetents([.medium, .large])
                .presentationDragIndicator(.visible)
        }
        .sheet(isPresented: $isSyncSheetPresented) {
            NavigationStack {
                GoogleDriveSyncSettingsView(store: store, showDoneButton: true)
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
                    onSelectScope: { scope in
                        navigateToScope(scope)
                        isFolderDrawerPresented = false
                    },
                    onOpenSyncSettings: {
                        isFolderDrawerPresented = false
                        compactTab = .sync
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
            Text("新建文件夹将通过 Google Drive 双向同步到 Mac 与 Windows。")
        }
    }

    // MARK: - iPad Regular Layout

    private var regularIPadShell: some View {
        NavigationSplitView(columnVisibility: $splitVisibility) {
            SidebarNavigationView(
                store: store,
                onSelectScope: { store.selectScope($0) },
                onOpenSyncSettings: { isSyncSheetPresented = true },
                onCreateFolder: { showNewFolderAlert = true },
                onCreateMoodboard: { isCreateBoardSheetPresented = true }
            )
            .navigationTitle("Charkle")
            .navigationSplitViewColumnWidth(min: 230, ideal: 264, max: 320)
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
                            onOpenSyncSettings: { isSyncSheetPresented = true },
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
                                    isSyncSheetPresented = true
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
                                isSyncSheetPresented = true
                            } label: {
                                Label("同步与设置", systemImage: "gearshape")
                            }
                        }
                    }
                }
            }
        }
        .navigationSplitViewStyle(.balanced)
    }

    // MARK: - iPhone Compact Layout (5 Tabs: 素材库 / 收件箱 / 情绪板 / 搜图 / 同步)

    private var compactIPhoneShell: some View {
        TabView(selection: $compactTab) {
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
                    onOpenSyncSettings: { compactTab = .sync },
                    onOpenFolders: { isFolderDrawerPresented = true }
                )
                .toolbar(.hidden, for: .navigationBar)
                .background(
                    LibraryTabBarGestureBridge(
                        tabCount: 5,
                        isLibraryTabActive: compactTab == .library,
                        onOpenDirectoryAndFilters: {
                            if compactTab != .library {
                                compactTab = .library
                            }
                            if !isFolderDrawerPresented {
                                isFolderDrawerPresented = true
                            }
                        }
                    )
                )
            }
            .tabItem {
                Label("素材库", systemImage: "square.grid.2x2")
            }
            .tag(CompactTab.library)

            NavigationStack {
                InboxTriageView(
                    store: store,
                    zoomNamespace: previewZoomNamespace,
                    onOpenAsset: { asset, origin in openAsset(asset, from: origin) },
                    onFindSimilar: { asset, origin in openAsset(asset, from: origin, inspectorTab: .similar, openInspector: true) },
                    onOpenCapture: { isCapturePresented = true }
                )
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
            .tabItem {
                Label("收件箱", systemImage: "tray")
            }
            .badge(store.inboxCount > 0 ? store.inboxCount : 0)
            .tag(CompactTab.inbox)

            NavigationStack(path: $moodboardPath) {
                MoodboardsListView(
                    store: store,
                    onOpenBoard: { boardID in
                        moodboardPath.append(boardID)
                    }
                )
                .navigationDestination(for: UUID.self) { boardID in
                    MoodboardStudioView(
                        store: store,
                        boardID: boardID,
                        onOpenAsset: { openAsset($0, from: .moodboard) },
                        onRevealAssetInLibrary: { revealAssetInLibrary($0, sourceBoardID: boardID) }
                    )
                }
            }
            .tabItem {
                Label("情绪板", systemImage: "rectangle.3.group")
            }
            .tag(CompactTab.moodboards)

            NavigationStack {
                Group {
                    if searchTabIsPinterest {
                        PinterestExploreMobileView(
                            store: store,
                            controller: store.pinterestController,
                            onSwitchToLibrarySearch: {
                                searchTabIsPinterest = false
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
                                searchTabIsPinterest = true
                            }
                        )
                        .navigationTitle("搜图")
                        .navigationBarTitleDisplayMode(.inline)
                    }
                }
            }
            .tabItem {
                Label("搜图", systemImage: searchTabIsPinterest ? "sparkles" : "magnifyingglass")
            }
            .tag(CompactTab.search)

            NavigationStack {
                GoogleDriveSyncSettingsView(store: store, showDoneButton: false)
            }
            .tabItem {
                Label("同步", systemImage: store.hasConnectedCloudBackend ? "arrow.triangle.2.circlepath.circle" : "icloud")
            }
            .tag(CompactTab.sync)
        }
        .onChange(of: compactTab) { _, next in
            switch next {
            case .library:
                // Inbox uses its own dedicated `store.inboxAssets`, so returning to `素材库` keeps the
                // library scope and assets intact with zero empty-state flash.
                if store.scope == .inbox || isMoodboardScope(store.scope) {
                    store.selectScope(.allItems)
                }
            case .inbox:
                break
            case .moodboards:
                break
            case .search:
                if store.scope == .inbox || store.scope == .trash || isMoodboardScope(store.scope) {
                    store.selectScope(.allItems)
                }
            case .sync:
                Task { await store.loadSyncAndStorageState() }
            }
        }
    }

    // MARK: - Navigation & Asset Open Routing

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
            searchTabIsPinterest = true
            compactTab = .search
        default:
            store.selectScope(scope)
            compactTab = .library
        }
    }

    private func openBoard(_ id: UUID) {
        if horizontalSizeClass == .regular {
            store.selectScope(.moodboard(id))
        } else {
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
        if !openInspector, asset.isExternalWebLink, let url = asset.externalWebURL {
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
