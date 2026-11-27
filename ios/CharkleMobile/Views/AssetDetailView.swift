import AVFoundation
import AVKit
import CharkleCore
import PDFKit
import SwiftUI
import UIKit
import WebKit

/// Transient non-destructive preview transform state (rotation & mirroring), matching macOS Quick Look.
struct PreviewTransformState: Equatable {
    var rotationDegrees: Double = 0
    var flipHorizontal: Bool = false
    var flipVertical: Bool = false

    var displayRotationDegrees: Int {
        let raw = Int(rotationDegrees.rounded()) % 360
        return raw < 0 ? raw + 360 : raw
    }

    var hasActiveTransform: Bool {
        displayRotationDegrees != 0 || flipHorizontal || flipVertical
    }

    mutating func rotate(by delta: Double) {
        rotationDegrees += delta
    }

    mutating func reset() {
        rotationDegrees = 0
        flipHorizontal = false
        flipVertical = false
    }

    /// Keeps 90°/270° rotated images comfortably inside the stage bounds without edge clipping.
    func quarterTurnFitScale(for imageSize: CGSize, in viewport: CGSize) -> CGFloat {
        guard displayRotationDegrees == 90 || displayRotationDegrees == 270 else { return 1.0 }
        let availW = max(120, viewport.width)
        let availH = max(120, viewport.height)
        let naturalRatio = imageSize.height > 0 ? (imageSize.width / imageSize.height) : 1.0
        let fittedW: CGFloat
        let fittedH: CGFloat
        if availW / availH > naturalRatio {
            fittedH = availH
            fittedW = fittedH * naturalRatio
        } else {
            fittedW = availW
            fittedH = fittedW / naturalRatio
        }
        let scale = min(availW / max(1, fittedH), availH / max(1, fittedW))
        return max(0.25, min(1.0, scale))
    }
}

/// iOS Photos-inspired full-screen Quick Look viewer:
/// - Non-overlapping vertical layout (`top bar` -> `unobstructed media stage` -> `filmstrip scrubber` -> `3-part floating bottom bar`),
///   so controls NEVER cover the bottom of portrait/vertical artwork.
/// - Single-tap toggles immersive edge-to-edge full-screen viewing.
/// - Expandable inline mini-bars for Rating (`★`) and Rotation/Mirroring (`左旋 / 右旋 / 水平翻转 / 上下翻转 / 还原`).
struct AssetDetailView: View {
    enum DetailInspectorTab: String, CaseIterable {
        case info = "信息"
        case similar = "相似素材"
    }

    private enum ActiveUtilityDrawer: Equatable {
        case rating
        case transform
    }

    @Bindable var store: MobileAppStore
    let initialAsset: AssetRecord
    let allAssets: [AssetRecord]
    let initialInspectorTab: DetailInspectorTab
    let openInspectorImmediately: Bool
    let onCurrentAssetChanged: (UUID) -> Void
    let onFilterByColor: (String) -> Void
    let onFilterByTag: (String) -> Void

    @Environment(\.dismiss) private var dismiss
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    @State private var pageAssets: [AssetRecord]
    @State private var pageIndexByID: [UUID: Int]
    @State private var localHydratedAssets: [UUID: AssetRecord] = [:]
    @State private var currentAssetID: UUID
    @State private var pagedAssetID: UUID?
    @State private var isInspectorVisible: Bool
    @State private var isCompactInspectorPresented: Bool
    @State private var selectedInspectorTab: DetailInspectorTab
    @State private var shareFileURL: URL?
    @State private var isPreparingShare = false
    @State private var previewTransform = PreviewTransformState()
    @State private var isChromeVisible: Bool = true
    @State private var activeUtilityDrawer: ActiveUtilityDrawer? = nil
    @State private var confirmPermanentDelete: Bool = false
    @State private var isCurrentAssetZoomed: Bool = false
    @State private var isMoveFolderSheetPresented: Bool = false
    @State private var preferLongStripFitWidth: Bool = true
    @State private var isInspectorTextFocused: Bool = false

    init(
        store: MobileAppStore,
        initialAsset: AssetRecord,
        allAssets: [AssetRecord],
        initialInspectorTab: DetailInspectorTab = .info,
        openInspectorImmediately: Bool = false,
        onCurrentAssetChanged: @escaping (UUID) -> Void = { _ in },
        onFilterByColor: @escaping (String) -> Void,
        onFilterByTag: @escaping (String) -> Void
    ) {
        self.store = store
        self.initialAsset = initialAsset
        self.allAssets = allAssets
        self.initialInspectorTab = initialInspectorTab
        self.openInspectorImmediately = openInspectorImmediately
        self.onCurrentAssetChanged = onCurrentAssetChanged
        self.onFilterByColor = onFilterByColor
        self.onFilterByTag = onFilterByTag
        let seeded = allAssets.isEmpty ? [initialAsset] : allAssets
        var lookup: [UUID: Int] = Dictionary(minimumCapacity: seeded.count)
        for (idx, item) in seeded.enumerated() {
            lookup[item.id] = idx
        }
        _pageAssets = State(initialValue: seeded)
        _pageIndexByID = State(initialValue: lookup)
        _currentAssetID = State(initialValue: initialAsset.id)
        _pagedAssetID = State(initialValue: initialAsset.id)
        _selectedInspectorTab = State(initialValue: initialInspectorTab)
        _isInspectorVisible = State(initialValue: true)
        _isCompactInspectorPresented = State(initialValue: openInspectorImmediately)
    }

    private var orderedAssets: [AssetRecord] {
        pageAssets
    }

    private var currentAssetIndex: Int? {
        pageIndexByID[currentAssetID]
    }

    private var currentAsset: AssetRecord {
        if let live = store.liveAsset(id: currentAssetID) {
            return live
        }
        if let hydrated = localHydratedAssets[currentAssetID] {
            return hydrated
        }
        if let idx = currentAssetIndex, idx < orderedAssets.count {
            return orderedAssets[idx]
        }
        return initialAsset
    }

    private var isCurrentAssetLongStrip: Bool {
        guard !currentAsset.isGitHubRepo,
              !currentAsset.isSocialPost,
              currentAsset.mediaKind == .image || currentAsset.mediaKind == .designFile,
              currentAsset.pixelWidth > 0,
              currentAsset.pixelHeight >= 1_600 else {
            return false
        }
        return Double(currentAsset.pixelHeight) / Double(currentAsset.pixelWidth) >= 2.2
    }

    private var supportsVisualTransform: Bool {
        !currentAsset.isGitHubRepo
            && !currentAsset.isSocialPost
            && (currentAsset.mediaKind == .image
                || currentAsset.mediaKind == .designFile
                || currentAsset.mediaKind == .animatedImage)
    }

    var body: some View {
        ZStack {
            (isChromeVisible ? MobileTheme.galleryGround(for: colorScheme) : Color.black)
                .ignoresSafeArea()
                .animation(MobileMotion.accessible(MobileMotion.enterSm, reduced: reduceMotion), value: isChromeVisible)

            if isChromeVisible {
                MobileTheme.ambientTint(from: currentAsset.dominantColors.first?.hex, scheme: colorScheme)
                    .ignoresSafeArea()
            }

            HStack(spacing: 0) {
                // Unobstructed iOS Photos-style vertical stack: top bar -> pure media stage -> filmstrip -> bottom 3-part bar
                VStack(spacing: 0) {
                    if isChromeVisible {
                        topBar
                            .transition(.opacity.combined(with: .move(edge: .top)))
                    }

                    mediaPager
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .clipped()

                    if isChromeVisible {
                        VStack(spacing: 8) {
                            if let drawer = activeUtilityDrawer {
                                utilitySubBar(for: drawer)
                                    .padding(.horizontal, 14)
                                    .transition(.opacity.combined(with: .move(edge: .bottom)))
                            }

                            if orderedAssets.count > 1 {
                                AssetFilmstripScrubber(
                                    assets: orderedAssets,
                                    selectedID: $currentAssetID,
                                    thumbnails: store.thumbnails
                                )
                            }

                            photosBottomBar
                                .padding(.horizontal, 16)
                                .padding(.bottom, 6)
                        }
                        .padding(.top, 6)
                        .transition(.opacity.combined(with: .move(edge: .bottom)))
                    }
                }
                .animation(MobileMotion.accessible(MobileMotion.enterSm, reduced: reduceMotion), value: isChromeVisible)
                .animation(MobileMotion.accessible(MobileMotion.settleStrong, reduced: reduceMotion), value: activeUtilityDrawer)
                .frame(maxWidth: .infinity, maxHeight: .infinity)

                // iPad side-by-side 320pt Inspector
                if horizontalSizeClass == .regular && isInspectorVisible && isChromeVisible {
                    Divider()
                    DetailInspectorPanel(
                        store: store,
                        asset: currentAsset,
                        selectedTab: $selectedInspectorTab,
                        isTextFieldFocused: $isInspectorTextFocused,
                        onSelectAsset: { nextID in
                            navigateToAsset(id: nextID)
                        },
                        onFilterByColor: onFilterByColor,
                        onFilterByTag: onFilterByTag,
                        onDismissDetail: { dismiss() }
                    )
                    .frame(width: 320)
                    .background(MobileTheme.inspectorBackground(for: colorScheme))
                    .transition(.move(edge: .trailing).combined(with: .opacity))
                }
            }
        }
        .background(keyboardShortcutsBridge)
        .statusBarHidden(!isChromeVisible)
        .interactiveDismissDisabled(isCurrentAssetZoomed)
        .background(ZoomDismissCoordinatorBridge(isZoomedOrZooming: isCurrentAssetZoomed))
        .sheet(isPresented: $isMoveFolderSheetPresented) {
            NavigationStack {
                HierarchicalFolderPickerSheet(
                    title: "移动到文件夹",
                    folderTree: store.folderTree,
                    currentFolderID: currentAsset.folderID,
                    onPick: { folderID, folderName in
                        let id = currentAsset.id
                        isMoveFolderSheetPresented = false
                        Task {
                            await store.patchAssets(
                                AssetBatchPatch(
                                    assetIDs: [id],
                                    folderAssignment: folderID.map { .folder($0) } ?? .inbox
                                ),
                                successToast: folderID == nil ? "已移回收件箱" : "已归档到「\(folderName)」"
                            )
                        }
                    }
                )
            }
            .presentationDetents([.medium, .large])
        }
        .sheet(isPresented: $isCompactInspectorPresented) {
            NavigationStack {
                DetailInspectorPanel(
                    store: store,
                    asset: currentAsset,
                    selectedTab: $selectedInspectorTab,
                    isTextFieldFocused: $isInspectorTextFocused,
                    onSelectAsset: { nextID in
                        isCompactInspectorPresented = false
                        navigateToAsset(id: nextID)
                    },
                    onFilterByColor: { hex in
                        isCompactInspectorPresented = false
                        onFilterByColor(hex)
                    },
                    onFilterByTag: { tag in
                        isCompactInspectorPresented = false
                        onFilterByTag(tag)
                    },
                    onDismissDetail: {
                        isCompactInspectorPresented = false
                        dismiss()
                    }
                )
                .navigationTitle("素材信息")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .confirmationAction) {
                        Button("完成") { isCompactInspectorPresented = false }
                    }
                }
            }
            .presentationDetents([.medium, .large])
        }
        .sheet(isPresented: Binding(
            get: { shareFileURL != nil },
            set: { if !$0 { shareFileURL = nil } }
        )) {
            if let shareFileURL {
                ActivityShareSheet(items: [shareFileURL])
            }
        }
        .confirmationDialog(
            "永久删除此素材？",
            isPresented: $confirmPermanentDelete,
            titleVisibility: .visible
        ) {
            Button("永久删除", role: .destructive) {
                let id = currentAsset.id
                dismiss()
                Task { await store.permanentlyDelete(ids: [id]) }
            }
            Button("取消", role: .cancel) {}
        } message: {
            Text("彻底删除后将无法从回收站恢复。")
        }
        .onChange(of: pagedAssetID) { _, nextID in
            if let nextID, nextID != currentAssetID {
                currentAssetID = nextID
            }
        }
        .onChange(of: currentAssetID) { _, nextID in
            if pagedAssetID != nextID {
                pagedAssetID = nextID
            }
            if previewTransform.hasActiveTransform {
                previewTransform.reset()
            }
            if isCurrentAssetZoomed {
                isCurrentAssetZoomed = false
            }
            preferLongStripFitWidth = true
            onCurrentAssetChanged(nextID)
            prefetchAdjacentPreviews(around: nextID)
        }
        .onAppear {
            prefetchAdjacentPreviews(around: currentAssetID)
        }
        .task(id: currentAssetID) {
            // Defer disk/SQLite metadata hydration & similar queries slightly so rapid
            // horizontal swiping stays locked at 120Hz without main-thread contention.
            try? await Task.sleep(for: .milliseconds(160))
            guard !Task.isCancelled else { return }
            if let hydrated = try? await store.engine.hydrateImageMetadataIfNeeded(id: currentAssetID) {
                localHydratedAssets[hydrated.id] = hydrated
                store.applyHydratedAsset(hydrated)
            }
            if selectedInspectorTab == .similar {
                await store.loadSimilarAssets(for: currentAssetID)
            }
        }
        .onChange(of: selectedInspectorTab) { _, next in
            if next == .similar {
                Task { await store.loadSimilarAssets(for: currentAssetID) }
            }
        }
    }

    // MARK: - Top Bar (iOS Photos Geometry: Back Circle · Title Pill · More Circle)

    private var topBar: some View {
        HStack(spacing: 10) {
            Button {
                dismiss()
            } label: {
                Image(systemName: "chevron.backward")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(.primary)
                    .frame(width: 40, height: 40)
                    .charkleFloatingCapsule()
            }
            .buttonStyle(MobileTactileButtonStyle())
            .accessibilityLabel("返回素材库")

            Spacer(minLength: 4)

            VStack(spacing: 1) {
                Text(currentAsset.title)
                    .font(.system(size: 13.5, weight: .semibold))
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                Text(subtitleText)
                    .font(.system(size: 11).monospacedDigit())
                    .foregroundStyle(MobileTheme.secondaryInk(for: colorScheme))
                    .lineLimit(1)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 6)
            .frame(maxWidth: horizontalSizeClass == .regular ? 380 : 220)
            .charkleFloatingCapsule()

            Spacer(minLength: 4)

            Menu {
                Menu("加入情绪板", systemImage: "rectangle.3.group") {
                    ForEach(store.boards) { board in
                        Button(board.title) {
                            Task { await store.addAssets([currentAsset.id], toBoard: board.id) }
                        }
                    }
                    if !store.boards.isEmpty { Divider() }
                    Button("新建情绪板并加入", systemImage: "plus") {
                        let id = currentAsset.id
                        let title = currentAsset.title
                        Task { _ = await store.createMoodboard(title: title, seedAssetIDs: [id]) }
                    }
                }

                Menu("移动到文件夹", systemImage: "folder.badge.plus") {
                    Button {
                        Task {
                            await store.patchAssets(
                                AssetBatchPatch(assetIDs: [currentAsset.id], folderAssignment: .inbox),
                                successToast: "已移回收件箱"
                            )
                        }
                    } label: {
                        Label(
                            currentAsset.folderID == nil ? "收件箱  ✓" : "收件箱",
                            systemImage: "tray"
                        )
                    }
                    if !store.folderTree.isEmpty {
                        Divider()
                        HierarchicalFolderMenuContent(
                            nodes: store.folderTree,
                            currentFolderID: currentAsset.folderID
                        ) { folderID, folderName in
                            Task {
                                await store.patchAssets(
                                    AssetBatchPatch(assetIDs: [currentAsset.id], folderAssignment: .folder(folderID)),
                                    successToast: "已归档到「\(folderName)」"
                                )
                            }
                        }
                        Divider()
                        Button {
                            isMoveFolderSheetPresented = true
                        } label: {
                            Label("按层级浏览并搜索…", systemImage: "list.bullet.indent")
                        }
                    }
                }

                Button("拷贝原图", systemImage: "doc.on.doc") {
                    Task { await store.copyAssetToPasteboard(currentAsset) }
                }

                Button(
                    currentAsset.pinnedOffline ? "取消始终保留在本地" : "始终保留在本地",
                    systemImage: currentAsset.pinnedOffline ? "icloud" : "arrow.down.circle"
                ) {
                    let next = !currentAsset.pinnedOffline
                    Task {
                        await store.patchAssets(
                            AssetBatchPatch(assetIDs: [currentAsset.id], pinnedOffline: next),
                            successToast: next ? "已置顶离线原图" : "已取消离线置顶"
                        )
                    }
                }

                Button("查找相似素材", systemImage: "sparkle.magnifyingglass") {
                    selectedInspectorTab = .similar
                    if horizontalSizeClass == .regular {
                        isInspectorVisible = true
                    } else {
                        isCompactInspectorPresented = true
                    }
                }

                Button("AI 重新打标", systemImage: "sparkles") {
                    Task { await store.retagAssets([currentAsset.id]) }
                }

                if let post = currentAsset.richMetadata?.socialPost, (!post.effectiveAttachments.isEmpty || post.isZeroDownloadVideoBookmark) {
                    let attachments = post.effectiveAttachments
                    Divider()
                    Button {
                        let target = currentAsset
                        Task { _ = await store.extractAllMediaFromSocialPost(postAsset: target) }
                    } label: {
                        Label(
                            post.isZeroDownloadVideoBookmark
                                ? "保存视频为独立素材"
                                : "全部提取为独立素材（\(attachments.count) 项）",
                            systemImage: post.isZeroDownloadVideoBookmark ? "film.stack" : "square.and.arrow.down.on.square"
                        )
                    }
                    .disabled(store.isExtractingSocialMedia)

                    if !post.isZeroDownloadVideoBookmark && attachments.count > 1 {
                        Menu("逐项提取帖子媒体", systemImage: "photo.on.rectangle") {
                            ForEach(Array(attachments.enumerated()), id: \.offset) { idx, attachment in
                                Button {
                                    let target = currentAsset
                                    Task {
                                        _ = await store.extractMediaFromSocialPost(
                                            postAsset: target,
                                            attachment: attachment,
                                            index: idx
                                        )
                                    }
                                } label: {
                                    Label(
                                        "提取第 \(idx + 1) 个\(attachment.kind.localizedLabel)为独立素材",
                                        systemImage: attachment.kind == .photo ? "photo" : "film"
                                    )
                                }
                            }
                        }
                        .disabled(store.isExtractingSocialMedia)
                    }
                } else if let web = currentAsset.richMetadata?.webPage, !web.attachments.isEmpty {
                    Divider()
                    Button {
                        let target = currentAsset
                        Task { _ = await store.extractAllMediaFromLinkAsset(target) }
                    } label: {
                        Label(
                            web.hasVideo ? "保存网页视频为独立素材" : "提取网页媒体为独立素材（\(web.attachments.count) 项）",
                            systemImage: web.hasVideo ? "film.stack" : "square.and.arrow.down.on.square"
                        )
                    }
                    .disabled(store.isExtractingSocialMedia)
                }

                if let externalURL = currentAsset.externalWebURL {
                    Button("在浏览器打开", systemImage: "safari") {
                        UIApplication.shared.open(externalURL)
                    }
                }
            } label: {
                Image(systemName: "ellipsis")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(.primary)
                    .frame(width: 40, height: 40)
                    .charkleFloatingCapsule()
            }
            .accessibilityLabel("更多操作")
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
    }

    // MARK: - iOS Photos-Style 3-Part Bottom Bar (Share Circle · Center Pill · Trash Circle)

    private var photosBottomBar: some View {
        HStack(spacing: 14) {
            // Left circle: Share
            Button {
                Task { await prepareAndShareOriginal() }
            } label: {
                Group {
                    if isPreparingShare {
                        ProgressView().controlSize(.small)
                    } else {
                        Image(systemName: "square.and.arrow.up")
                            .font(.system(size: 17, weight: .medium))
                            .foregroundStyle(.primary)
                    }
                }
                .frame(width: 46, height: 46)
                .charkleFloatingCapsule()
            }
            .buttonStyle(MobileTactileButtonStyle())
            .disabled(isPreparingShare)
            .accessibilityLabel("分享原图")

            Spacer(minLength: 4)

            // Center floating capsule: Rating · Info · Rotate/Flip Transform
            HStack(spacing: 6) {
                Button {
                    MobileHaptics.light()
                    withAnimation(MobileMotion.accessible(MobileMotion.settleStrong, reduced: reduceMotion)) {
                        activeUtilityDrawer = (activeUtilityDrawer == .rating) ? nil : .rating
                    }
                } label: {
                    HStack(spacing: 3) {
                        Image(systemName: currentAsset.rating > 0 ? "star.fill" : "star")
                            .font(.system(size: 17, weight: .medium))
                            .foregroundStyle(
                                currentAsset.rating > 0
                                    ? Color(charkleHex: "#F2C14E")
                                    : (activeUtilityDrawer == .rating ? MobileTheme.accent(for: colorScheme) : .primary)
                            )
                        if currentAsset.rating > 0 {
                            Text("\(currentAsset.rating)")
                                .font(.system(size: 11.5, weight: .bold).monospacedDigit())
                                .foregroundStyle(Color(charkleHex: "#F2C14E"))
                        }
                    }
                    .frame(minWidth: 44, minHeight: 38)
                    .padding(.horizontal, currentAsset.rating > 0 ? 4 : 0)
                    .background(
                        activeUtilityDrawer == .rating ? MobileTheme.accentSoft(for: colorScheme) : .clear,
                        in: Capsule()
                    )
                }
                .buttonStyle(MobileTactileButtonStyle())
                .accessibilityLabel("评分")

                Button {
                    MobileHaptics.light()
                    if horizontalSizeClass == .regular {
                        withAnimation(MobileMotion.accessible(MobileMotion.drawerEase, reduced: reduceMotion)) {
                            isInspectorVisible.toggle()
                        }
                    } else {
                        isCompactInspectorPresented = true
                    }
                } label: {
                    Image(systemName: "info.circle")
                        .font(.system(size: 17, weight: .medium))
                        .foregroundStyle(
                            (horizontalSizeClass == .regular && isInspectorVisible)
                                ? MobileTheme.accent(for: colorScheme)
                                : .primary
                        )
                        .frame(width: 44, height: 38)
                        .background(
                            (horizontalSizeClass == .regular && isInspectorVisible)
                                ? MobileTheme.accentSoft(for: colorScheme)
                                : .clear,
                            in: Capsule()
                        )
                }
                .buttonStyle(MobileTactileButtonStyle())
                .accessibilityLabel("素材信息与相似")

                if supportsVisualTransform {
                    Button {
                        MobileHaptics.light()
                        withAnimation(MobileMotion.accessible(MobileMotion.settleStrong, reduced: reduceMotion)) {
                            activeUtilityDrawer = (activeUtilityDrawer == .transform) ? nil : .transform
                        }
                    } label: {
                        Image(systemName: "slider.horizontal.3")
                            .font(.system(size: 17, weight: .medium))
                            .foregroundStyle(
                                previewTransform.hasActiveTransform || activeUtilityDrawer == .transform
                                    ? MobileTheme.accent(for: colorScheme)
                                    : .primary
                            )
                            .frame(width: 44, height: 38)
                            .background(
                                (previewTransform.hasActiveTransform || activeUtilityDrawer == .transform)
                                    ? MobileTheme.accentSoft(for: colorScheme)
                                    : .clear,
                                in: Capsule()
                            )
                    }
                    .buttonStyle(MobileTactileButtonStyle())
                    .accessibilityLabel("旋转与翻转")
                }

                if isCurrentAssetLongStrip {
                    Button {
                        MobileHaptics.light()
                        preferLongStripFitWidth.toggle()
                    } label: {
                        Image(systemName: preferLongStripFitWidth ? "arrow.down.right.and.arrow.up.left" : "arrow.up.left.and.arrow.down.right")
                            .font(.system(size: 15.5, weight: .medium))
                            .foregroundStyle(
                                preferLongStripFitWidth ? MobileTheme.accent(for: colorScheme) : .primary
                            )
                            .frame(width: 44, height: 38)
                            .background(
                                preferLongStripFitWidth ? MobileTheme.accentSoft(for: colorScheme) : .clear,
                                in: Capsule()
                            )
                    }
                    .buttonStyle(MobileTactileButtonStyle())
                    .accessibilityLabel(preferLongStripFitWidth ? "切回适配全屏" : "切回长图全宽滚动")
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 4)
            .charkleFloatingCapsule()

            Spacer(minLength: 4)

            // Right circle: Trash or Restore
            if currentAsset.isTrashed {
                Button {
                    let id = currentAsset.id
                    Task {
                        await store.patchAssets(
                            AssetBatchPatch(assetIDs: [id], isTrashed: false),
                            successToast: "已放回原处"
                        )
                    }
                } label: {
                    Image(systemName: "arrow.uturn.backward")
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(MobileTheme.accent(for: colorScheme))
                        .frame(width: 46, height: 46)
                        .charkleFloatingCapsule()
                }
                .buttonStyle(MobileTactileButtonStyle())
                .accessibilityLabel("从回收站恢复")
            } else {
                Button {
                    let id = currentAsset.id
                    dismiss()
                    Task {
                        await store.patchAssets(
                            AssetBatchPatch(assetIDs: [id], isTrashed: true),
                            successToast: "已移入回收站",
                            actionTitle: "撤销",
                            onAction: {
                                Task {
                                    await store.patchAssets(
                                        AssetBatchPatch(assetIDs: [id], isTrashed: false),
                                        successToast: "已恢复素材"
                                    )
                                }
                            }
                        )
                    }
                } label: {
                    Image(systemName: "trash")
                        .font(.system(size: 16, weight: .medium))
                        .foregroundStyle(.primary)
                        .frame(width: 46, height: 46)
                        .charkleFloatingCapsule()
                }
                .buttonStyle(MobileTactileButtonStyle())
                .accessibilityLabel("移至回收站")
            }
        }
    }

    // MARK: - Inline Expandable Rating / Rotate & Flip Mini-Bar (Never Overlaps Image!)

    @ViewBuilder
    private func utilitySubBar(for drawer: ActiveUtilityDrawer) -> some View {
        switch drawer {
        case .rating:
            HStack(spacing: 10) {
                ForEach(1...5, id: \.self) { star in
                    let filled = star <= currentAsset.rating
                    Button {
                        let target = currentAsset.rating == star ? 0 : star
                        MobileHaptics.light()
                        Task {
                            await store.patchAssets(AssetBatchPatch(assetIDs: [currentAsset.id], rating: target))
                        }
                    } label: {
                        Image(systemName: filled ? "star.fill" : "star")
                            .font(.system(size: 20, weight: .medium))
                            .foregroundStyle(filled ? Color(charkleHex: "#F2C14E") : MobileTheme.tertiaryInk(for: colorScheme))
                            .frame(width: 34, height: 34)
                            .scaleEffect(star == currentAsset.rating && !reduceMotion ? 1.12 : 1.0)
                    }
                    .buttonStyle(MobileTactileButtonStyle())
                }
                if currentAsset.rating > 0 {
                    Button("清除") {
                        MobileHaptics.light()
                        Task {
                            await store.patchAssets(AssetBatchPatch(assetIDs: [currentAsset.id], rating: 0))
                        }
                    }
                    .font(.system(size: 12.5, weight: .medium))
                    .foregroundStyle(MobileTheme.secondaryInk(for: colorScheme))
                    .padding(.leading, 4)
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 6)
            .charkleFloatingCapsule()

        case .transform:
            HStack(spacing: 6) {
                hudTransformButton("rotate.left", label: "逆时针旋转 90°", isActive: false) {
                    rotatePreview(by: -90)
                }
                .keyboardShortcut("r", modifiers: [.shift])

                hudTransformButton("rotate.right", label: "顺时针旋转 90°", isActive: false) {
                    rotatePreview(by: 90)
                }
                .keyboardShortcut("r", modifiers: [])

                hudTransformButton(
                    "arrow.left.and.right.righttriangle.left.righttriangle.right",
                    label: "水平翻转",
                    isActive: previewTransform.flipHorizontal
                ) {
                    toggleFlip(horizontal: true)
                }
                .keyboardShortcut("h", modifiers: [.shift])

                hudTransformButton(
                    "arrow.up.and.down.righttriangle.up.righttriangle.down",
                    label: "上下翻转",
                    isActive: previewTransform.flipVertical
                ) {
                    toggleFlip(horizontal: false)
                }
                .keyboardShortcut("v", modifiers: [.shift])

                if previewTransform.hasActiveTransform {
                    Button {
                        resetTransform()
                    } label: {
                        HStack(spacing: 4) {
                            if previewTransform.displayRotationDegrees != 0 {
                                Text("\(previewTransform.displayRotationDegrees)°")
                                    .font(.system(size: 11, weight: .semibold, design: .monospaced))
                                    .monospacedDigit()
                            }
                            Image(systemName: "arrow.uturn.backward")
                                .font(.system(size: 10.5, weight: .semibold))
                        }
                        .foregroundStyle(.white)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 7)
                        .background(MobileTheme.accentButtonFill(for: colorScheme), in: Capsule())
                    }
                    .buttonStyle(MobileTactileButtonStyle())
                    .keyboardShortcut("0", modifiers: [])
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .charkleFloatingCapsule()
        }
    }

    private func hudTransformButton(
        _ systemName: String,
        label: String,
        isActive: Bool,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: 16, weight: .medium))
                .foregroundStyle(isActive ? .white : .primary)
                .frame(width: 40, height: 34)
                .background(
                    isActive ? MobileTheme.accentButtonFill(for: colorScheme) : .clear,
                    in: Capsule()
                )
        }
        .buttonStyle(MobileTactileButtonStyle())
        .accessibilityLabel(label)
    }

    private func rotatePreview(by delta: Double) {
        MobileHaptics.light()
        withAnimation(MobileMotion.accessible(MobileMotion.settleStrong, reduced: reduceMotion)) {
            previewTransform.rotate(by: delta)
        }
    }

    private func toggleFlip(horizontal: Bool) {
        MobileHaptics.light()
        withAnimation(MobileMotion.accessible(MobileMotion.settleStrong, reduced: reduceMotion)) {
            if horizontal {
                previewTransform.flipHorizontal.toggle()
            } else {
                previewTransform.flipVertical.toggle()
            }
        }
    }

    private func resetTransform() {
        MobileHaptics.light()
        withAnimation(MobileMotion.accessible(MobileMotion.settleStrong, reduced: reduceMotion)) {
            previewTransform.reset()
        }
    }

    private var subtitleText: String {
        var parts: [String] = [currentAsset.displayTypeLabel]
        if currentAsset.pixelWidth > 0 && currentAsset.pixelHeight > 0 {
            parts.append("\(currentAsset.pixelWidth) × \(currentAsset.pixelHeight)")
        }
        if currentAsset.fileSizeBytes > 0 {
            parts.append(MobileFormatters.byteCount(currentAsset.fileSizeBytes))
        }
        return parts.joined(separator: " · ")
    }

    private var mediaPager: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            LazyHStack(spacing: 0) {
                ForEach(orderedAssets) { asset in
                    let isActive = asset.id == currentAssetID
                    let liveAsset = isActive ? currentAsset : (store.liveAsset(id: asset.id) ?? asset)
                    AssetStageContentView(
                        store: store,
                        asset: liveAsset,
                        transform: isActive ? previewTransform : PreviewTransformState(),
                        isActivePage: isActive,
                        preferLongStripFitWidth: isActive ? preferLongStripFitWidth : true,
                        onZoomInteractionChanged: { zoomed in
                            if asset.id == currentAssetID {
                                isCurrentAssetZoomed = zoomed
                            }
                        },
                        onSingleTap: {
                            withAnimation(MobileMotion.accessible(MobileMotion.enterSm, reduced: reduceMotion)) {
                                isChromeVisible.toggle()
                                if !isChromeVisible {
                                    activeUtilityDrawer = nil
                                }
                            }
                        }
                    )
                    .containerRelativeFrame([.horizontal, .vertical])
                    .id(asset.id)
                }
            }
            .scrollTargetLayout()
        }
        .scrollTargetBehavior(.paging)
        .scrollPosition(id: $pagedAssetID)
    }

    private var keyboardShortcutsBridge: some View {
        Group {
            Button("") {
                if isInspectorTextFocused {
                    MobileKeyboard.dismiss()
                } else {
                    dismiss()
                }
            }
            .keyboardShortcut(.escape, modifiers: [])

            if !isInspectorTextFocused && !isCompactInspectorPresented && !isMoveFolderSheetPresented {
                Button("") { dismiss() }
                    .keyboardShortcut(.space, modifiers: [])
                Button("") { stepCurrentAsset(by: -1) }
                    .keyboardShortcut(.leftArrow, modifiers: [])
                Button("") { stepCurrentAsset(by: 1) }
                    .keyboardShortcut(.rightArrow, modifiers: [])
            }
            Button("") {
                if horizontalSizeClass == .regular {
                    withAnimation(MobileMotion.accessible(MobileMotion.drawerEase, reduced: reduceMotion)) {
                        isInspectorVisible.toggle()
                    }
                } else {
                    isCompactInspectorPresented.toggle()
                }
            }
            .keyboardShortcut("i", modifiers: .command)

            if supportsVisualTransform {
                Button("") { rotatePreview(by: 90) }
                    .keyboardShortcut("r", modifiers: .command)
                Button("") { rotatePreview(by: -90) }
                    .keyboardShortcut("r", modifiers: [.command, .shift])
                Button("") { toggleFlip(horizontal: true) }
                    .keyboardShortcut("h", modifiers: [.command, .shift])
                Button("") { toggleFlip(horizontal: false) }
                    .keyboardShortcut("v", modifiers: [.command, .shift])
                Button("") { resetTransform() }
                    .keyboardShortcut("0", modifiers: .command)
            }

            ForEach(1...5, id: \.self) { star in
                Button("") {
                    let id = currentAsset.id
                    let target = currentAsset.rating == star ? 0 : star
                    MobileHaptics.light()
                    Task {
                        await store.patchAssets(AssetBatchPatch(assetIDs: [id], rating: target))
                    }
                }
                .keyboardShortcut(KeyEquivalent(Character("\(star)")), modifiers: .command)
            }
        }
        .labelsHidden()
        .frame(width: 0, height: 0)
        .opacity(0.001)
        .accessibilityHidden(true)
    }

    private func stepCurrentAsset(by delta: Int) {
        guard let idx = currentAssetIndex else { return }
        let next = idx + delta
        guard next >= 0, next < orderedAssets.count else { return }
        currentAssetID = orderedAssets[next].id
    }

    private func navigateToAsset(id nextID: UUID) {
        if pageIndexByID[nextID] != nil {
            currentAssetID = nextID
            return
        }
        if let found = store.similarResults.first(where: { $0.asset.id == nextID })?.asset
            ?? store.liveAsset(id: nextID) {
            pageIndexByID[found.id] = pageAssets.count
            pageAssets.append(found)
            currentAssetID = found.id
            pagedAssetID = found.id
        } else {
            Task {
                if let fetched = try? await store.engine.fetchAsset(id: nextID) {
                    if pageIndexByID[fetched.id] == nil {
                        pageIndexByID[fetched.id] = pageAssets.count
                        pageAssets.append(fetched)
                    }
                    currentAssetID = fetched.id
                    pagedAssetID = fetched.id
                }
            }
        }
    }

    private func prefetchAdjacentPreviews(around assetID: UUID) {
        guard let idx = pageIndexByID[assetID] else { return }
        let assets = orderedAssets
        var ids: [UUID] = []
        ids.reserveCapacity(5)
        for offset in [1, -1, 2, -2] {
            let target = idx + offset
            if target >= 0 && target < assets.count {
                ids.append(assets[target].id)
            }
        }
        if !ids.isEmpty {
            store.thumbnails.prefetch(assetIDs: ids, tier: .preview1400)
        }
    }

    private func prepareAndShareOriginal() async {
        isPreparingShare = true
        defer { isPreparingShare = false }
        if let url = try? await store.engine.originalURL(for: currentAsset.id) {
            shareFileURL = url
        } else if let thumb = await store.engine.thumbnailURL(for: currentAsset.id, tier: .preview1400) {
            shareFileURL = thumb
        } else {
            store.showToast("暂无法获取可分享的文件", tone: .warning)
        }
    }
}

// MARK: - iOS Photos-Style Bottom Filmstrip Scrubber

private struct AssetFilmstripScrubber: View {
    let assets: [AssetRecord]
    @Binding var selectedID: UUID
    let thumbnails: MobileThumbnailCache

    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(spacing: 4) {
                    ForEach(assets) { item in
                        let isSelected = item.id == selectedID
                        Button {
                            MobileHaptics.light()
                            selectedID = item.id
                        } label: {
                            FilmstripThumbCell(
                                asset: item,
                                thumbnails: thumbnails,
                                isSelected: isSelected
                            )
                            .frame(width: isSelected ? 40 : 24, height: 38)
                            .clipShape(RoundedRectangle(cornerRadius: isSelected ? 6 : 3, style: .continuous))
                            .overlay(
                                RoundedRectangle(cornerRadius: isSelected ? 6 : 3, style: .continuous)
                                    .strokeBorder(
                                        isSelected ? MobileTheme.accent(for: colorScheme) : .clear,
                                        lineWidth: 2
                                    )
                            )
                            .padding(.horizontal, isSelected ? 4 : 0)
                        }
                        .buttonStyle(.plain)
                        .id(item.id)
                    }
                }
                .padding(.horizontal, 16)
            }
            .frame(height: 40)
            .onAppear {
                proxy.scrollTo(selectedID, anchor: .center)
            }
            .task(id: selectedID) {
                // Brief coalesce so rapid horizontal swiping doesn't queue conflicting
                // ScrollViewReader animations against the main 120Hz pager deceleration.
                try? await Task.sleep(for: .milliseconds(35))
                guard !Task.isCancelled else { return }
                withAnimation(MobileMotion.settleStrong) {
                    proxy.scrollTo(selectedID, anchor: .center)
                }
            }
        }
    }
}

private struct FilmstripThumbCell: View {
    let asset: AssetRecord
    let thumbnails: MobileThumbnailCache
    let isSelected: Bool
    @State private var image: UIImage?

    var body: some View {
        let displayImage = thumbnails.cachedImage(for: asset.id, tier: .grid520) ?? image
        Color(.secondarySystemFill)
            .overlay {
                if let displayImage {
                    Image(uiImage: displayImage)
                        .resizable()
                        .scaledToFill()
                }
            }
            .clipped()
            .task(id: "\(asset.id.uuidString)-\(thumbnails.revision)") {
                if thumbnails.cachedImage(for: asset.id, tier: .grid520) != nil {
                    return
                }
                image = await thumbnails.loadImage(for: asset.id, tier: .grid520)
            }
    }
}

// MARK: - Media Stage Renderer (Image / Video / PDF / Social / GitHub)

private struct AssetStageContentView: View {
    @Bindable var store: MobileAppStore
    let asset: AssetRecord
    let transform: PreviewTransformState
    let isActivePage: Bool
    var preferLongStripFitWidth: Bool = true
    let onZoomInteractionChanged: (Bool) -> Void
    let onSingleTap: () -> Void

    @Environment(\.colorScheme) private var colorScheme
    @State private var image: UIImage?
    @State private var localOriginalURL: URL?

    private var resolvedStageImage: UIImage? {
        image ?? store.thumbnails.bestCachedPreviewImage(for: asset.id)
    }

    private var shouldUseLongStripFitWidth: Bool {
        guard preferLongStripFitWidth,
              !asset.isGitHubRepo,
              !asset.isSocialPost,
              asset.mediaKind == .image || asset.mediaKind == .designFile else {
            return false
        }
        if asset.pixelWidth > 0 && asset.pixelHeight >= 1_600 {
            return Double(asset.pixelHeight) / Double(asset.pixelWidth) >= 2.2
        }
        if let display = resolvedStageImage, display.size.width > 0 {
            let pxH = display.size.height * display.scale
            let pxW = display.size.width * display.scale
            return pxH >= 1_600 && (pxH / pxW) >= 2.2
        }
        return false
    }

    var body: some View {
        let displayImage = resolvedStageImage
        Group {
            if asset.mediaKind == .video, let localOriginalURL, isActivePage {
                MobileLocalVideoStageView(
                    assetID: asset.id,
                    videoURL: localOriginalURL,
                    isActivePage: isActivePage,
                    onSetCoverFrame: { jpegData, ts in
                        _ = await store.updateAssetCoverImage(
                            assetID: asset.id,
                            imageData: jpegData,
                            timestampSeconds: ts
                        )
                    },
                    onCaptureFailed: {
                        MobileHaptics.warning()
                        store.showToast("当前视频画面尚未就绪，请播放或定位画面后再试", tone: .warning)
                    }
                )
                .padding(12)
            } else if asset.mediaKind == .video {
                ZStack {
                    if let displayImage {
                        Image(uiImage: displayImage)
                            .resizable()
                            .scaledToFit()
                            .clipShape(RoundedRectangle(cornerRadius: MobileTheme.Radius.cardOuter, style: .continuous))
                            .padding(12)
                    } else {
                        ProgressView("正在加载视频…")
                            .font(.system(size: 13))
                            .foregroundStyle(MobileTheme.secondaryInk(for: colorScheme))
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if asset.mediaKind == .document,
                      (asset.fileName as NSString).pathExtension.lowercased() == "pdf",
                      let localOriginalURL {
                PDFDocumentPreview(url: localOriginalURL)
                    .clipShape(RoundedRectangle(cornerRadius: MobileTheme.Radius.cardOuter, style: .continuous))
                    .padding(12)
            } else if let post = asset.richMetadata?.socialPost {
                socialPostStage(post, coverImage: displayImage)
            } else if let web = asset.richMetadata?.webPage, web.hasRichSummary || !web.attachments.isEmpty {
                webPageStage(web, coverImage: displayImage)
            } else if let repo = asset.richMetadata?.githubRepo {
                githubRepoStage(repo, coverImage: displayImage)
            } else {
                ZStack {
                    if let displayImage {
                        ZoomableImageView(
                            image: displayImage,
                            transform: transform,
                            isActivePage: isActivePage,
                            fitWidthMode: shouldUseLongStripFitWidth,
                            onZoomInteractionChanged: onZoomInteractionChanged,
                            onSingleTap: onSingleTap
                        )
                    } else {
                        ProgressView("正在加载高清预览…")
                            .font(.system(size: 13))
                            .foregroundStyle(MobileTheme.secondaryInk(for: colorScheme))
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .task(id: "\(asset.id.uuidString)-\(store.thumbnails.revision)") {
            // Fast path: load lightweight preview1400 (or grid520 fallback) for immediate display
            if let cachedOrig = store.thumbnails.cachedOriginalImage(for: asset.id) {
                image = cachedOrig
            } else if let preview = await store.thumbnails.loadImage(for: asset.id, tier: .preview1400) {
                image = preview
            } else if let grid = await store.thumbnails.loadImage(for: asset.id, tier: .grid520) {
                image = grid
            }
        }
        .task(id: "\(asset.id.uuidString)-active-\(isActivePage)-\(store.thumbnails.revision)") {
            guard isActivePage else { return }
            if asset.mediaKind == .image || asset.mediaKind == .designFile {
                if let cachedOrig = store.thumbnails.cachedOriginalImage(for: asset.id) {
                    image = cachedOrig
                    return
                }
                // Wait briefly for horizontal swipe momentum to settle before decoding 2600px original
                try? await Task.sleep(for: .milliseconds(180))
                guard !Task.isCancelled else { return }
                if let orig = await store.thumbnails.loadOriginalImage(for: asset) {
                    image = orig
                }
            } else if asset.mediaKind == .video || (asset.fileName as NSString).pathExtension.lowercased() == "pdf" {
                if localOriginalURL == nil {
                    localOriginalURL = try? await store.engine.originalURL(for: asset.id)
                }
            }
        }
    }

    private func socialBadgeColor(for platform: SocialPlatform) -> Color {
        switch platform {
        case .xiaohongshu: Color(charkleHex: "#FF2442")
        case .douyin: Color(charkleHex: "#161823")
        case .youtube: Color(charkleHex: "#FF0000")
        case .bilibili: Color(charkleHex: "#FB7299")
        case .pixiv: Color(charkleHex: "#0096FA")
        case .instagram: Color(charkleHex: "#D93B58")
        case .unknown: Color(charkleHex: "#52525B")
        default: MobileTheme.accent(for: colorScheme)
        }
    }

    private func socialPostStage(_ post: SocialPostMetadata, coverImage: UIImage?) -> some View {
        let attachments = post.effectiveAttachments
        let hasInlineStreamVideo = post.isZeroDownloadVideoBookmark
            || (post.hasVideo && attachments.contains(where: { $0.kind == .video || $0.kind == .gif }))
        let canExtractPrimary = !attachments.isEmpty || post.isZeroDownloadVideoBookmark
        return ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                if hasInlineStreamVideo {
                    let playerView = MobileStreamingVideoPlayerView(
                        playbackKey: "\(asset.id.uuidString):\(post.originalURL)",
                        coverImage: coverImage,
                        durationText: post.formattedVideoDuration,
                        watchURL: URL(string: post.originalURL),
                        openActionLabel: post.platform.openActionLabel,
                        isActivePage: isActivePage,
                        onSetCoverFrame: { jpegData, ts in
                            _ = await store.updateAssetCoverImage(
                                assetID: asset.id,
                                imageData: jpegData,
                                timestampSeconds: ts
                            )
                        },
                        onCaptureFailed: {
                            MobileHaptics.warning()
                            store.showToast("当前视频画面尚未就绪，请播放或定位画面后再试", tone: .warning)
                        },
                        resolvePlan: {
                            await VideoPlatformResolver.resolvePlaybackPlan(for: post)
                        }
                    )
                    Group {
                        if post.platform == .douyin {
                            playerView
                                .aspectRatio(3.0 / 4.0, contentMode: .fit)
                                .frame(maxWidth: 460, maxHeight: 520)
                        } else {
                            playerView
                                .aspectRatio(16.0 / 9.0, contentMode: .fit)
                                .frame(maxWidth: 680)
                        }
                    }
                    .clipShape(RoundedRectangle(cornerRadius: MobileTheme.Radius.cardOuter, style: .continuous))
                    .frame(maxWidth: .infinity)
                } else if let coverImage {
                    Image(uiImage: coverImage)
                        .resizable()
                        .scaledToFit()
                        .frame(maxWidth: 560)
                        .clipShape(RoundedRectangle(cornerRadius: MobileTheme.Radius.cardOuter, style: .continuous))
                        .frame(maxWidth: .infinity)
                }

                VStack(alignment: .leading, spacing: 10) {
                    HStack(spacing: 8) {
                        Text(post.platform.displayName)
                            .font(.system(size: 11.5, weight: .semibold))
                            .foregroundStyle(.white)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 3)
                            .background(socialBadgeColor(for: post.platform), in: Capsule())
                        Text(post.displayAuthorName)
                            .font(.system(size: 14, weight: .semibold))
                            .lineLimit(1)
                        if let handleLine = post.displayHandleLine {
                            Text(handleLine)
                                .font(.system(size: 12))
                                .foregroundStyle(MobileTheme.secondaryInk(for: colorScheme))
                                .lineLimit(1)
                        }
                        Spacer()
                        if let dur = post.formattedVideoDuration {
                            Text(dur)
                                .font(.system(size: 11.5, weight: .semibold).monospacedDigit())
                                .foregroundStyle(MobileTheme.secondaryInk(for: colorScheme))
                                .padding(.horizontal, 7)
                                .padding(.vertical, 3)
                                .background(MobileTheme.surfaceSubtle(for: colorScheme), in: Capsule())
                        }
                    }

                    if let headline = post.articleTitle, !headline.isEmpty {
                        Text(headline)
                            .font(.system(size: 16, weight: .bold))
                            .textSelection(.enabled)
                            .fixedSize(horizontal: false, vertical: true)
                    }

                    if post.hasVideoSummaryContent {
                        VStack(alignment: .leading, spacing: 6) {
                            Label("视频摘要", systemImage: "text.quote")
                                .font(.system(size: 12.5, weight: .semibold))
                                .foregroundStyle(MobileTheme.accent(for: colorScheme))

                            if let summary = post.videoSummary?.trimmingCharacters(in: .whitespacesAndNewlines), !summary.isEmpty {
                                Text(summary)
                                    .font(.system(size: 13.5))
                                    .textSelection(.enabled)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                            if !post.videoOutline.isEmpty {
                                VStack(alignment: .leading, spacing: 3) {
                                    ForEach(Array(post.videoOutline.enumerated()), id: \.offset) { _, line in
                                        Text(line)
                                            .font(.system(size: 12))
                                            .foregroundStyle(MobileTheme.secondaryInk(for: colorScheme))
                                            .textSelection(.enabled)
                                            .fixedSize(horizontal: false, vertical: true)
                                    }
                                }
                                .padding(.top, 2)
                            }
                        }
                        .padding(12)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(
                            MobileTheme.accentSoft(for: colorScheme),
                            in: RoundedRectangle(cornerRadius: 11, style: .continuous)
                        )
                    }

                    if !post.bodyText.isEmpty {
                        Text(post.bodyText)
                            .font(.system(size: 13.5))
                            .foregroundStyle(post.hasVideoSummaryContent ? MobileTheme.secondaryInk(for: colorScheme) : .primary)
                            .textSelection(.enabled)
                            .fixedSize(horizontal: false, vertical: true)
                    }

                    HStack(spacing: 10) {
                        if canExtractPrimary {
                            Button {
                                MobileHaptics.light()
                                let target = asset
                                Task { _ = await store.extractAllMediaFromSocialPost(postAsset: target) }
                            } label: {
                                HStack(spacing: 6) {
                                    if store.isExtractingSocialMedia {
                                        ProgressView()
                                            .controlSize(.mini)
                                            .tint(.white)
                                    } else {
                                        Image(systemName: post.isZeroDownloadVideoBookmark ? "film.stack" : "square.and.arrow.down.on.square")
                                    }
                                    Text(
                                        store.isExtractingSocialMedia
                                            ? (post.isZeroDownloadVideoBookmark ? "正在保存视频…" : "正在提取…")
                                            : (post.isZeroDownloadVideoBookmark
                                                ? "保存视频为独立素材"
                                                : "全部提取为独立素材（\(attachments.count)）")
                                    )
                                    .font(.system(size: 13, weight: .semibold))
                                }
                                .foregroundStyle(.white)
                                .padding(.horizontal, 14)
                                .padding(.vertical, 9)
                                .background(MobileTheme.accentButtonFill(for: colorScheme), in: Capsule())
                            }
                            .buttonStyle(MobileTactileButtonStyle())
                            .disabled(store.isExtractingSocialMedia)
                        }

                        if let url = URL(string: post.originalURL) {
                            Button {
                                UIApplication.shared.open(url)
                            } label: {
                                Label(post.platform.openActionLabel, systemImage: "arrow.up.right.square")
                                    .font(.system(size: 13, weight: .semibold))
                                    .foregroundStyle(!canExtractPrimary ? .white : .primary)
                                    .padding(.horizontal, 13)
                                    .padding(.vertical, 9)
                                    .background(
                                        !canExtractPrimary
                                            ? MobileTheme.accentButtonFill(for: colorScheme)
                                            : MobileTheme.surfaceSubtle(for: colorScheme),
                                        in: Capsule()
                                    )
                            }
                            .buttonStyle(MobileTactileButtonStyle())
                        }
                    }
                }
                .padding(16)
                .background(
                    MobileTheme.surfaceElevated(for: colorScheme),
                    in: RoundedRectangle(cornerRadius: MobileTheme.Radius.settingsOuter, style: .continuous)
                )

                // Individual Social Post Media Attachments (for photo-notes & non-video multi-media posts)
                if !post.isZeroDownloadVideoBookmark && !attachments.isEmpty {
                    VStack(alignment: .leading, spacing: 10) {
                        HStack {
                            Text("\(post.platform.postNoun)内媒体（\(attachments.count) 项）")
                                .font(.system(size: 13, weight: .semibold))
                                .foregroundStyle(MobileTheme.secondaryInk(for: colorScheme))
                            Spacer()
                            Text("提取后自动保留原帖作者与链接")
                                .font(.system(size: 11))
                                .foregroundStyle(MobileTheme.tertiaryInk(for: colorScheme))
                        }

                        if post.platform.isVerticalFeedPlatform && attachments.count > 1 {
                            LazyVGrid(
                                columns: [GridItem(.flexible(), spacing: 10), GridItem(.flexible(), spacing: 10)],
                                spacing: 10
                            ) {
                                ForEach(Array(attachments.enumerated()), id: \.offset) { idx, attachment in
                                    let previewURLString = attachment.kind == .photo ? attachment.url : (attachment.thumbnailURL ?? attachment.url)
                                    ZStack(alignment: .bottomTrailing) {
                                        Color.clear
                                            .aspectRatio(3.0 / 4.0, contentMode: .fit)
                                            .overlay {
                                                if let previewURL = URL(string: previewURLString) {
                                                    MobileSocialRemoteImageView(
                                                        url: previewURL,
                                                        fallbackSymbol: attachment.kind == .photo ? "photo" : "film"
                                                    )
                                                } else {
                                                    MobileTheme.surfaceSubtle(for: colorScheme)
                                                }
                                            }
                                            .clipped()
                                            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                                            .overlay(
                                                RoundedRectangle(cornerRadius: 12, style: .continuous)
                                                    .strokeBorder(MobileTheme.hairline(for: colorScheme), lineWidth: 0.75)
                                            )

                                        Button {
                                            MobileHaptics.light()
                                            let target = asset
                                            Task {
                                                _ = await store.extractMediaFromSocialPost(
                                                    postAsset: target,
                                                    attachment: attachment,
                                                    index: idx
                                                )
                                            }
                                        } label: {
                                            Label("提取 #\(idx + 1)", systemImage: "photo.badge.plus")
                                                .font(.system(size: 11, weight: .semibold))
                                                .foregroundStyle(.white)
                                                .padding(.horizontal, 9)
                                                .padding(.vertical, 5)
                                                .background(.black.opacity(0.72), in: Capsule())
                                        }
                                        .buttonStyle(.plain)
                                        .disabled(store.isExtractingSocialMedia)
                                        .padding(8)
                                    }
                                }
                            }
                        } else {
                            ForEach(Array(attachments.enumerated()), id: \.offset) { idx, attachment in
                                let previewURLString = attachment.thumbnailURL ?? attachment.url
                                HStack(spacing: 12) {
                                    ZStack(alignment: .bottomLeading) {
                                        if let previewURL = URL(string: previewURLString) {
                                            MobileSocialRemoteImageView(
                                                url: previewURL,
                                                fallbackSymbol: attachment.kind == .photo ? "photo" : "film"
                                            )
                                        } else {
                                            MobileTheme.surfaceSubtle(for: colorScheme)
                                        }

                                        if attachment.kind != .photo {
                                            Text(attachment.kind == .gif ? "GIF" : "视频")
                                                .font(.system(size: 9.5, weight: .bold))
                                                .foregroundStyle(.white)
                                                .padding(.horizontal, 5)
                                                .padding(.vertical, 2)
                                                .background(.black.opacity(0.68), in: Capsule())
                                                .padding(4)
                                        }
                                    }
                                    .frame(width: 68, height: 68)
                                    .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                                    .overlay(
                                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                                            .strokeBorder(MobileTheme.hairline(for: colorScheme), lineWidth: 0.75)
                                    )

                                    VStack(alignment: .leading, spacing: 3) {
                                        Text("第 \(idx + 1) 项 · \(attachment.kind.localizedLabel)")
                                            .font(.system(size: 13.5, weight: .semibold))
                                            .foregroundStyle(.primary)
                                        Text("转为独立素材存入当前目录")
                                            .font(.system(size: 11.5))
                                            .foregroundStyle(MobileTheme.secondaryInk(for: colorScheme))
                                    }

                                    Spacer(minLength: 4)

                                    Button {
                                        MobileHaptics.light()
                                        let target = asset
                                        Task {
                                            _ = await store.extractMediaFromSocialPost(
                                                postAsset: target,
                                                attachment: attachment,
                                                index: idx
                                            )
                                        }
                                    } label: {
                                        Label("转为独立素材", systemImage: "square.and.arrow.down")
                                            .font(.system(size: 12, weight: .semibold))
                                            .foregroundStyle(MobileTheme.accent(for: colorScheme))
                                            .padding(.horizontal, 10)
                                            .padding(.vertical, 7)
                                            .background(MobileTheme.accentSoft(for: colorScheme), in: Capsule())
                                    }
                                    .buttonStyle(MobileTactileButtonStyle())
                                    .disabled(store.isExtractingSocialMedia)
                                }
                                .padding(10)
                                .background(
                                    MobileTheme.surfaceElevated(for: colorScheme),
                                    in: RoundedRectangle(cornerRadius: MobileTheme.Radius.cardOuter, style: .continuous)
                                )
                                .overlay(
                                    RoundedRectangle(cornerRadius: MobileTheme.Radius.cardOuter, style: .continuous)
                                        .strokeBorder(MobileTheme.hairline(for: colorScheme), lineWidth: 0.75)
                                )
                            }
                        }
                    }
                }
            }
            .padding(16)
        }
    }

    private func webPageStage(_ web: WebPageRichMetadata, coverImage: UIImage?) -> some View {
        let attachments = web.attachments
        let externalURL = URL(string: web.canonicalURL) ?? asset.externalWebURL
        let hasStreamableVideo = web.hasVideo
            || attachments.contains(where: { $0.kind == .video })
            || (externalURL.flatMap { VideoPlatformResolver.embedPlayer(for: $0) } != nil)
        let formattedDur: String? = {
            guard let secs = web.durationSeconds ?? asset.durationSeconds, secs > 0 else { return nil }
            let total = Int(secs.rounded())
            let h = total / 3600
            let m = (total % 3600) / 60
            let s = total % 60
            return h > 0 ? String(format: "%d:%02d:%02d", h, m, s) : String(format: "%d:%02d", m, s)
        }()

        return ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                if hasStreamableVideo {
                    MobileStreamingVideoPlayerView(
                        playbackKey: "web:\(asset.id.uuidString):\(web.canonicalURL)",
                        coverImage: coverImage,
                        durationText: formattedDur,
                        watchURL: externalURL,
                        openActionLabel: "在浏览器打开",
                        isActivePage: isActivePage,
                        onSetCoverFrame: { jpegData, ts in
                            _ = await store.updateAssetCoverImage(
                                assetID: asset.id,
                                imageData: jpegData,
                                timestampSeconds: ts
                            )
                        },
                        onCaptureFailed: {
                            MobileHaptics.warning()
                            store.showToast("当前视频画面尚未就绪，请播放或定位画面后再试", tone: .warning)
                        },
                        resolvePlan: {
                            await VideoPlatformResolver.resolveWebPagePlaybackPlan(
                                for: web,
                                fallbackURL: externalURL
                            )
                        }
                    )
                    .aspectRatio(16.0 / 9.0, contentMode: .fit)
                    .frame(maxWidth: 680)
                    .clipShape(RoundedRectangle(cornerRadius: MobileTheme.Radius.cardOuter, style: .continuous))
                    .frame(maxWidth: .infinity)
                } else if let coverImage {
                    Image(uiImage: coverImage)
                        .resizable()
                        .scaledToFit()
                        .frame(maxWidth: 560)
                        .clipShape(RoundedRectangle(cornerRadius: MobileTheme.Radius.cardOuter, style: .continuous))
                        .frame(maxWidth: .infinity)
                }

                VStack(alignment: .leading, spacing: 10) {
                    HStack(spacing: 8) {
                        Text(web.siteName ?? asset.sourceDomain ?? "网页")
                            .font(.system(size: 11.5, weight: .semibold))
                            .foregroundStyle(.white)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 3)
                            .background(MobileTheme.accent(for: colorScheme), in: Capsule())
                        if let author = web.authorName, !author.isEmpty {
                            Text(author)
                                .font(.system(size: 13, weight: .medium))
                                .foregroundStyle(MobileTheme.secondaryInk(for: colorScheme))
                                .lineLimit(1)
                        }
                        Spacer()
                    }

                    Text(asset.title)
                        .font(.system(size: 16, weight: .bold))
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)

                    if let summary = web.summary, !summary.isEmpty {
                        Text(summary)
                            .font(.system(size: 13.5))
                            .foregroundStyle(MobileTheme.secondaryInk(for: colorScheme))
                            .textSelection(.enabled)
                            .fixedSize(horizontal: false, vertical: true)
                    }

                    HStack(spacing: 10) {
                        if !attachments.isEmpty {
                            Button {
                                MobileHaptics.light()
                                let target = asset
                                Task { _ = await store.extractAllMediaFromLinkAsset(target) }
                            } label: {
                                HStack(spacing: 6) {
                                    if store.isExtractingSocialMedia {
                                        ProgressView().controlSize(.mini).tint(.white)
                                    } else {
                                        Image(systemName: web.hasVideo ? "film.stack" : "square.and.arrow.down.on.square")
                                    }
                                    Text(
                                        store.isExtractingSocialMedia
                                            ? "正在提取…"
                                            : (web.hasVideo ? "保存网页视频为独立素材" : "提取网页媒体（\(attachments.count)）")
                                    )
                                    .font(.system(size: 13, weight: .semibold))
                                }
                                .foregroundStyle(.white)
                                .padding(.horizontal, 14)
                                .padding(.vertical, 9)
                                .background(MobileTheme.accentButtonFill(for: colorScheme), in: Capsule())
                            }
                            .buttonStyle(MobileTactileButtonStyle())
                            .disabled(store.isExtractingSocialMedia)
                        }

                        if let url = URL(string: web.canonicalURL) ?? asset.externalWebURL {
                            Button {
                                UIApplication.shared.open(url)
                            } label: {
                                Label("在浏览器打开", systemImage: "safari")
                                    .font(.system(size: 13, weight: .semibold))
                                    .foregroundStyle(attachments.isEmpty ? .white : .primary)
                                    .padding(.horizontal, 13)
                                    .padding(.vertical, 9)
                                    .background(
                                        attachments.isEmpty
                                            ? MobileTheme.accentButtonFill(for: colorScheme)
                                            : MobileTheme.surfaceSubtle(for: colorScheme),
                                        in: Capsule()
                                    )
                            }
                            .buttonStyle(MobileTactileButtonStyle())
                        }
                    }
                }
                .padding(16)
                .background(
                    MobileTheme.surfaceElevated(for: colorScheme),
                    in: RoundedRectangle(cornerRadius: MobileTheme.Radius.settingsOuter, style: .continuous)
                )

                if !attachments.isEmpty {
                    VStack(alignment: .leading, spacing: 10) {
                        Text("发现的网页媒体（\(attachments.count) 项）")
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(MobileTheme.secondaryInk(for: colorScheme))

                        ForEach(Array(attachments.prefix(8).enumerated()), id: \.offset) { idx, attachment in
                            HStack(spacing: 12) {
                                Image(systemName: attachment.kind == .photo ? "photo" : "film")
                                    .font(.system(size: 16, weight: .medium))
                                    .foregroundStyle(MobileTheme.accent(for: colorScheme))
                                    .frame(width: 36, height: 36)
                                    .background(MobileTheme.accentSoft(for: colorScheme), in: RoundedRectangle(cornerRadius: 8, style: .continuous))

                                VStack(alignment: .leading, spacing: 2) {
                                    Text("第 \(idx + 1) 项 · \(attachment.kind.localizedLabel)")
                                        .font(.system(size: 13.5, weight: .semibold))
                                    Text(attachment.kind == .video ? "按需保存为独立视频素材" : "提取为独立图片素材")
                                        .font(.system(size: 11.5))
                                        .foregroundStyle(MobileTheme.secondaryInk(for: colorScheme))
                                }

                                Spacer()

                                Button {
                                    MobileHaptics.light()
                                    let target = asset
                                    Task {
                                        _ = await store.extractMediaFromWebPageAsset(
                                            webAsset: target,
                                            attachment: attachment,
                                            index: idx
                                        )
                                    }
                                } label: {
                                    Text("转为独立素材")
                                        .font(.system(size: 12, weight: .semibold))
                                        .foregroundStyle(MobileTheme.accent(for: colorScheme))
                                        .padding(.horizontal, 10)
                                        .padding(.vertical, 6)
                                        .background(MobileTheme.accentSoft(for: colorScheme), in: Capsule())
                                }
                                .buttonStyle(MobileTactileButtonStyle())
                                .disabled(store.isExtractingSocialMedia)
                            }
                            .padding(10)
                            .background(
                                MobileTheme.surfaceElevated(for: colorScheme),
                                in: RoundedRectangle(cornerRadius: MobileTheme.Radius.cardOuter, style: .continuous)
                            )
                        }
                    }
                }
            }
            .padding(16)
        }
    }

    private func githubRepoStage(_ repo: GitHubRepoMetadata, coverImage: UIImage?) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                if let coverImage {
                    Image(uiImage: coverImage)
                        .resizable()
                        .scaledToFit()
                        .clipShape(RoundedRectangle(cornerRadius: MobileTheme.Radius.cardOuter, style: .continuous))
                }
                VStack(alignment: .leading, spacing: 10) {
                    Text(repo.fullName)
                        .font(.system(size: 18, weight: .bold))
                    if let desc = repo.description, !desc.isEmpty {
                        Text(desc)
                            .font(.system(size: 14))
                            .foregroundStyle(MobileTheme.secondaryInk(for: colorScheme))
                    }
                    HStack(spacing: 14) {
                        Label("\(repo.stars)", systemImage: "star")
                        Label("\(repo.forks)", systemImage: "tuningfork")
                        if let lang = repo.language {
                            Label(lang, systemImage: "chevron.left.forwardslash.chevron.right")
                        }
                    }
                    .font(.system(size: 12.5, weight: .medium).monospacedDigit())
                    .foregroundStyle(MobileTheme.secondaryInk(for: colorScheme))

                    if let url = asset.externalWebURL {
                        Button {
                            UIApplication.shared.open(url)
                        } label: {
                            Label("在 GitHub 打开", systemImage: "arrow.up.right.square")
                                .font(.system(size: 13.5, weight: .semibold))
                                .foregroundStyle(.white)
                                .padding(.horizontal, 14)
                                .padding(.vertical, 9)
                                .background(MobileTheme.accentButtonFill(for: colorScheme), in: Capsule())
                        }
                        .buttonStyle(MobileTactileButtonStyle())
                    }
                }
                .padding(16)
                .background(
                    MobileTheme.surfaceElevated(for: colorScheme),
                    in: RoundedRectangle(cornerRadius: MobileTheme.Radius.settingsOuter, style: .continuous)
                )
            }
            .padding(16)
        }
    }
}

// MARK: - Zero-Download Streaming & Local Video Players (iOS Preview + Frame-to-Cover Capture)

@MainActor
private final class MobileVideoFrameCaptureBridge {
    var captureCurrentFrame: (@MainActor () async -> (jpegData: Data, timestampSeconds: Double?)?)?
}

private struct MobileLocalVideoStageView: View {
    let assetID: UUID
    let videoURL: URL
    let isActivePage: Bool
    let onSetCoverFrame: @MainActor (Data, Double?) async -> Void
    var onCaptureFailed: (() -> Void)? = nil

    @Environment(\.colorScheme) private var colorScheme
    @State private var captureBridge = MobileVideoFrameCaptureBridge()
    @State private var isCapturingCover = false

    var body: some View {
        VStack(spacing: 10) {
            MobileDirectStreamPlayerController(
                stream: VideoStreamPlaybackPlan.DirectStream(url: videoURL),
                isActive: isActivePage,
                captureBridge: captureBridge,
                onPlaybackFailed: {}
            )
            .clipShape(RoundedRectangle(cornerRadius: MobileTheme.Radius.cardOuter, style: .continuous))
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            HStack {
                Spacer()
                Button {
                    guard !isCapturingCover else { return }
                    MobileHaptics.light()
                    isCapturingCover = true
                    Task { @MainActor in
                        defer { isCapturingCover = false }
                        if let captured = await captureBridge.captureCurrentFrame?() {
                            await onSetCoverFrame(captured.jpegData, captured.timestampSeconds)
                        } else {
                            onCaptureFailed?()
                        }
                    }
                } label: {
                    HStack(spacing: 6) {
                        if isCapturingCover {
                            ProgressView().controlSize(.mini)
                        } else {
                            Image(systemName: "camera.viewfinder")
                                .font(.system(size: 13, weight: .semibold))
                        }
                        Text("设当前帧为封面")
                            .font(.system(size: 13, weight: .semibold))
                    }
                    .foregroundStyle(.primary)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 8)
                    .background(MobileTheme.surfaceElevated(for: colorScheme), in: Capsule())
                    .overlay(Capsule().strokeBorder(MobileTheme.hairline(for: colorScheme), lineWidth: 0.75))
                }
                .buttonStyle(MobileTactileButtonStyle())
                .disabled(isCapturingCover)
                Spacer()
            }
        }
    }
}

private struct MobileStreamingVideoPlayerView: View {
    let playbackKey: String
    let coverImage: UIImage?
    let durationText: String?
    let watchURL: URL?
    let openActionLabel: String
    let isActivePage: Bool
    var onSetCoverFrame: (@MainActor (_ jpegData: Data, _ timestampSeconds: Double?) async -> Void)? = nil
    var onCaptureFailed: (() -> Void)? = nil
    let resolvePlan: () async -> VideoStreamPlaybackPlan

    @State private var plan: VideoStreamPlaybackPlan?
    @State private var resolvedPlaybackKey: String?
    @State private var isResolving: Bool = true
    @State private var directStreamIndex: Int = 0
    @State private var useEmbedMode: Bool = false
    @State private var allDirectStreamsFailed: Bool = false
    @State private var captureBridge = MobileVideoFrameCaptureBridge()
    @State private var isCapturingCover: Bool = false

    private var activeDirectStream: VideoStreamPlaybackPlan.DirectStream? {
        guard isActivePage,
              !useEmbedMode,
              !allDirectStreamsFailed,
              let streams = plan?.directStreams,
              directStreamIndex >= 0,
              directStreamIndex < streams.count else {
            return nil
        }
        return streams[directStreamIndex]
    }

    private var canToggleModes: Bool {
        guard let plan else { return false }
        return !plan.directStreams.isEmpty && !allDirectStreamsFailed && plan.embedPlayer != nil
    }

    private var isPlayerMounted: Bool {
        activeDirectStream != nil
            || (plan?.embedPlayer != nil && (useEmbedMode || allDirectStreamsFailed || (plan?.directStreams.isEmpty == true)))
    }

    var body: some View {
        ZStack {
            Color.black

            if !isActivePage {
                coverSurface
            } else if let stream = activeDirectStream {
                MobileDirectStreamPlayerController(
                    stream: stream,
                    isActive: isActivePage,
                    captureBridge: captureBridge,
                    onPlaybackFailed: handleDirectStreamFailure
                )
            } else if let embed = plan?.embedPlayer, (useEmbedMode || allDirectStreamsFailed || (plan?.directStreams.isEmpty == true)) {
                MobileEmbedStreamWebView(
                    embed: embed,
                    isActive: isActivePage,
                    captureBridge: captureBridge
                )
            } else {
                coverSurface
            }

            if isActivePage && isResolving {
                coverSurface
                    .overlay {
                        HStack(spacing: 8) {
                            ProgressView()
                                .controlSize(.small)
                                .tint(.white)
                            Text("正在连接流式播放…")
                                .font(.system(size: 12.5, weight: .semibold))
                                .foregroundStyle(.white)
                        }
                        .padding(.horizontal, 14)
                        .padding(.vertical, 8)
                        .background(.black.opacity(0.68), in: Capsule(style: .continuous))
                        .overlay(Capsule().strokeBorder(.white.opacity(0.22), lineWidth: 0.75))
                    }
            } else if isActivePage && plan?.hasPlayableSource == false {
                coverSurface
                    .overlay {
                        VStack(spacing: 10) {
                            Image(systemName: "play.slash")
                                .font(.system(size: 22, weight: .medium))
                                .foregroundStyle(.white.opacity(0.85))
                            Text("暂无法直接流式播放此视频")
                                .font(.system(size: 12.5, weight: .medium))
                                .foregroundStyle(.white.opacity(0.92))
                            if let watchURL {
                                Button {
                                    UIApplication.shared.open(watchURL)
                                } label: {
                                    Label(openActionLabel, systemImage: "arrow.up.right.square")
                                        .font(.system(size: 12, weight: .semibold))
                                        .foregroundStyle(.white)
                                        .padding(.horizontal, 12)
                                        .padding(.vertical, 6)
                                        .background(Color.accentColor, in: Capsule())
                                }
                                .buttonStyle(.plain)
                            }
                        }
                        .padding(16)
                        .background(.black.opacity(0.65), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                    }
            }

            if isActivePage && !isResolving && isPlayerMounted && (canToggleModes || onSetCoverFrame != nil) {
                VStack {
                    HStack(spacing: 6) {
                        Spacer()
                        if let onSetCoverFrame {
                            Button {
                                guard !isCapturingCover else { return }
                                MobileHaptics.light()
                                isCapturingCover = true
                                Task { @MainActor in
                                    defer { isCapturingCover = false }
                                    if let captured = await captureBridge.captureCurrentFrame?() {
                                        await onSetCoverFrame(captured.jpegData, captured.timestampSeconds)
                                    } else {
                                        onCaptureFailed?()
                                    }
                                }
                            } label: {
                                HStack(spacing: 4) {
                                    if isCapturingCover {
                                        ProgressView().controlSize(.mini).tint(.white)
                                    } else {
                                        Image(systemName: "camera.viewfinder")
                                            .font(.system(size: 11, weight: .semibold))
                                    }
                                    Text("设当前帧为封面")
                                        .font(.system(size: 11, weight: .semibold))
                                }
                                .foregroundStyle(.white)
                                .padding(.horizontal, 10)
                                .padding(.vertical, 5)
                                .background(.black.opacity(0.62), in: Capsule(style: .continuous))
                                .overlay(Capsule().strokeBorder(.white.opacity(0.22), lineWidth: 0.75))
                            }
                            .buttonStyle(.plain)
                            .disabled(isCapturingCover)
                        }
                        if canToggleModes {
                            Button {
                                MobileHaptics.light()
                                useEmbedMode.toggle()
                            } label: {
                                Label(
                                    useEmbedMode ? "原生流式" : "网页播放器",
                                    systemImage: useEmbedMode ? "play.rectangle" : "globe"
                                )
                                .font(.system(size: 11, weight: .semibold))
                                .foregroundStyle(.white)
                                .padding(.horizontal, 10)
                                .padding(.vertical, 5)
                                .background(.black.opacity(0.62), in: Capsule(style: .continuous))
                                .overlay(Capsule().strokeBorder(.white.opacity(0.22), lineWidth: 0.75))
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(10)
                    Spacer()
                }
            }
        }
        .task(id: "\(playbackKey):\(isActivePage)") {
            guard isActivePage else {
                isResolving = false
                return
            }
            if plan != nil && resolvedPlaybackKey == playbackKey {
                isResolving = false
                return
            }
            plan = nil
            resolvedPlaybackKey = nil
            isResolving = true
            directStreamIndex = 0
            useEmbedMode = false
            allDirectStreamsFailed = false

            try? await Task.sleep(for: .milliseconds(120))
            guard !Task.isCancelled else { return }

            let resolved = await resolvePlan()
            guard !Task.isCancelled else { return }

            plan = resolved
            resolvedPlaybackKey = playbackKey
            if resolved.directStreams.isEmpty && resolved.embedPlayer != nil {
                useEmbedMode = true
            }
            isResolving = false
        }
    }

    @ViewBuilder
    private var coverSurface: some View {
        ZStack {
            if let coverImage {
                Image(uiImage: coverImage)
                    .resizable()
                    .scaledToFill()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .clipped()
            } else {
                Color.black
            }

            if let durationText {
                VStack {
                    Spacer()
                    HStack {
                        Spacer()
                        Text(durationText)
                            .font(.system(size: 11.5, weight: .semibold).monospacedDigit())
                            .foregroundStyle(.white)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 3.5)
                            .background(.black.opacity(0.75), in: RoundedRectangle(cornerRadius: 6, style: .continuous))
                            .padding(10)
                    }
                }
            }
        }
    }

    private func handleDirectStreamFailure() {
        let count = plan?.directStreams.count ?? 0
        if directStreamIndex + 1 < count {
            directStreamIndex += 1
        } else {
            allDirectStreamsFailed = true
            if plan?.embedPlayer != nil {
                useEmbedMode = true
            }
        }
    }
}

private struct MobileDirectStreamPlayerController: UIViewControllerRepresentable {
    let stream: VideoStreamPlaybackPlan.DirectStream
    let isActive: Bool
    let captureBridge: MobileVideoFrameCaptureBridge
    let onPlaybackFailed: @MainActor () -> Void

    @MainActor
    final class Coordinator {
        var currentStream: VideoStreamPlaybackPlan.DirectStream?
        var isActive: Bool = false
        var loadTask: Task<Void, Never>?
        var statusObservation: NSKeyValueObservation?
        var videoOutput: AVPlayerItemVideoOutput?
        weak var captureBridge: MobileVideoFrameCaptureBridge?
        var onPlaybackFailed: (@MainActor () -> Void)?
        var didReportFailure = false

        func attach(
            stream: VideoStreamPlaybackPlan.DirectStream,
            to controller: AVPlayerViewController,
            isActive: Bool,
            captureBridge: MobileVideoFrameCaptureBridge,
            onPlaybackFailed: @escaping @MainActor () -> Void
        ) {
            teardown(controller)
            currentStream = stream
            self.isActive = isActive
            self.captureBridge = captureBridge
            self.onPlaybackFailed = onPlaybackFailed
            didReportFailure = false

            loadTask = Task { @MainActor [weak controller, weak self] in
                guard !Task.isCancelled, let controller, let self else { return }
                try? AVAudioSession.sharedInstance().setCategory(.playback, mode: .moviePlayback)
                try? AVAudioSession.sharedInstance().setActive(true)

                var assetOptions: [String: Any] = [:]
                if !stream.httpHeaders.isEmpty {
                    assetOptions["AVURLAssetHTTPHeaderFieldsKey"] = stream.httpHeaders
                }
                if let overrideMIME = stream.overrideMIMEType, !overrideMIME.isEmpty {
                    assetOptions[AVURLAssetOverrideMIMETypeKey] = overrideMIME
                }
                let asset = AVURLAsset(url: stream.url, options: assetOptions.isEmpty ? nil : assetOptions)
                let playable = (try? await asset.load(.isPlayable)) ?? false
                guard !Task.isCancelled else { return }
                guard playable else {
                    self.reportFailureOnce()
                    return
                }

                let item = AVPlayerItem(asset: asset)
                item.preferredForwardBufferDuration = 12
                let output = VideoFrameCapture.makeVideoOutput()
                item.add(output)
                self.videoOutput = output

                self.statusObservation = item.observe(\.status, options: [.new]) { [weak self] observedItem, _ in
                    if observedItem.status == .failed {
                        Task { @MainActor [weak self] in
                            self?.reportFailureOnce()
                        }
                    }
                }
                let player = AVPlayer(playerItem: item)
                player.automaticallyWaitsToMinimizeStalling = true
                controller.player = player
                self.captureBridge?.captureCurrentFrame = { [weak player, weak output] in
                    guard let player,
                          let result = await VideoFrameCapture.captureCurrentFrameJPEG(from: player, videoOutput: output) else {
                        return nil
                    }
                    return (result.jpegData, result.timestampSeconds)
                }
                if self.isActive {
                    player.play()
                }
            }
        }

        private func reportFailureOnce() {
            guard !didReportFailure else { return }
            didReportFailure = true
            onPlaybackFailed?()
        }

        func teardown(_ controller: AVPlayerViewController) {
            isActive = false
            loadTask?.cancel()
            loadTask = nil
            statusObservation?.invalidate()
            statusObservation = nil
            captureBridge?.captureCurrentFrame = nil
            videoOutput = nil
            controller.player?.pause()
            controller.player?.replaceCurrentItem(with: nil)
            controller.player = nil
            try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        }
    }

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func makeUIViewController(context: Context) -> AVPlayerViewController {
        let vc = AVPlayerViewController()
        vc.showsPlaybackControls = true
        vc.entersFullScreenWhenPlaybackBegins = false
        vc.allowsPictureInPicturePlayback = true
        vc.view.backgroundColor = .black
        context.coordinator.attach(
            stream: stream,
            to: vc,
            isActive: isActive,
            captureBridge: captureBridge,
            onPlaybackFailed: onPlaybackFailed
        )
        return vc
    }

    func updateUIViewController(_ uiViewController: AVPlayerViewController, context: Context) {
        context.coordinator.isActive = isActive
        context.coordinator.captureBridge = captureBridge
        context.coordinator.onPlaybackFailed = onPlaybackFailed
        if context.coordinator.currentStream != stream {
            context.coordinator.attach(
                stream: stream,
                to: uiViewController,
                isActive: isActive,
                captureBridge: captureBridge,
                onPlaybackFailed: onPlaybackFailed
            )
            return
        }
        if !isActive {
            uiViewController.player?.pause()
        }
    }

    static func dismantleUIViewController(_ uiViewController: AVPlayerViewController, coordinator: Coordinator) {
        coordinator.teardown(uiViewController)
    }
}

private struct MobileEmbedStreamWebView: UIViewRepresentable {
    let embed: VideoStreamPlaybackPlan.EmbedPlayer
    let isActive: Bool
    let captureBridge: MobileVideoFrameCaptureBridge

    @MainActor
    final class Coordinator {
        var loadedEmbed: VideoStreamPlaybackPlan.EmbedPlayer?
        weak var captureBridge: MobileVideoFrameCaptureBridge?
    }

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func makeUIView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        config.allowsInlineMediaPlayback = true
        config.allowsPictureInPictureMediaPlayback = true
        config.mediaTypesRequiringUserActionForPlayback = []
        let webView = WKWebView(frame: .zero, configuration: config)
        webView.isOpaque = false
        webView.backgroundColor = .black
        webView.scrollView.isScrollEnabled = false
        webView.scrollView.contentInsetAdjustmentBehavior = .never
        if let ua = embed.userAgent {
            webView.customUserAgent = ua
        }
        try? AVAudioSession.sharedInstance().setCategory(.playback, mode: .moviePlayback)
        try? AVAudioSession.sharedInstance().setActive(true)
        context.coordinator.captureBridge = captureBridge
        registerSnapshotBridge(for: webView)
        loadEmbed(embed, into: webView, coordinator: context.coordinator)
        return webView
    }

    func updateUIView(_ uiView: WKWebView, context: Context) {
        context.coordinator.captureBridge = captureBridge
        registerSnapshotBridge(for: uiView)
        if context.coordinator.loadedEmbed != embed {
            loadEmbed(embed, into: uiView, coordinator: context.coordinator)
        }
        if !isActive {
            uiView.pauseAllMediaPlayback(completionHandler: nil)
            uiView.evaluateJavaScript("document.querySelectorAll('video,audio').forEach(e=>e.pause());", completionHandler: nil)
        }
    }

    static func dismantleUIView(_ uiView: WKWebView, coordinator: Coordinator) {
        coordinator.captureBridge?.captureCurrentFrame = nil
        uiView.pauseAllMediaPlayback(completionHandler: nil)
        uiView.closeAllMediaPresentations(completionHandler: nil)
        uiView.stopLoading()
        uiView.loadHTMLString("<html></html>", baseURL: nil)
        coordinator.loadedEmbed = nil
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }

    private func registerSnapshotBridge(for webView: WKWebView) {
        captureBridge.captureCurrentFrame = { [weak webView] in
            guard let webView else { return nil }
            let config = WKSnapshotConfiguration()
            config.afterScreenUpdates = false
            guard let snapshot = try? await webView.takeSnapshot(configuration: config),
                  let cgImage = snapshot.cgImage,
                  let jpeg = VideoFrameCapture.encodeJPEG(cgImage) else {
                return nil
            }
            return (jpeg, nil)
        }
    }

    private func loadEmbed(
        _ embed: VideoStreamPlaybackPlan.EmbedPlayer,
        into webView: WKWebView,
        coordinator: Coordinator
    ) {
        coordinator.loadedEmbed = embed
        let (html, baseURL) = VideoPlatformResolver.embedHTML(for: embed)
        webView.loadHTMLString(html, baseURL: baseURL)
    }
}

// MARK: - Native UIScrollView Pinch, Double-Tap, Rotation & Mirror Zoomable Image Canvas

/// Uses a native `UIScrollView` (matching Apple Photos) instead of SwiftUI `MagnificationGesture`
/// so pinch-to-zoom-in / pinch-to-zoom-out, finger-anchored scaling, bounded inertial panning,
/// and `TabView(.page)` horizontal swipes cooperate cleanly without triggering `.navigationTransition(.zoom)`
/// interactive dismissal while shrinking a zoomed-in photo back down to 1.0x.
private struct ZoomableImageView: UIViewRepresentable {
    let image: UIImage
    let transform: PreviewTransformState
    let isActivePage: Bool
    var fitWidthMode: Bool = false
    let onZoomInteractionChanged: (Bool) -> Void
    let onSingleTap: () -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(
            onZoomInteractionChanged: onZoomInteractionChanged,
            onSingleTap: onSingleTap
        )
    }

    func makeUIView(context: Context) -> ZoomablePhotoScrollView {
        let scrollView = ZoomablePhotoScrollView()
        scrollView.delegate = context.coordinator
        scrollView.minimumZoomScale = 1.0
        scrollView.maximumZoomScale = 6.0
        scrollView.bouncesZoom = true
        scrollView.alwaysBounceHorizontal = false
        scrollView.alwaysBounceVertical = false
        scrollView.showsHorizontalScrollIndicator = false
        scrollView.showsVerticalScrollIndicator = false
        scrollView.contentInsetAdjustmentBehavior = .never
        scrollView.decelerationRate = .fast
        scrollView.backgroundColor = .clear

        let doubleTap = UITapGestureRecognizer(
            target: context.coordinator,
            action: #selector(Coordinator.handleDoubleTap(_:))
        )
        doubleTap.numberOfTapsRequired = 2
        scrollView.addGestureRecognizer(doubleTap)

        let singleTap = UITapGestureRecognizer(
            target: context.coordinator,
            action: #selector(Coordinator.handleSingleTap(_:))
        )
        singleTap.numberOfTapsRequired = 1
        singleTap.require(toFail: doubleTap)
        scrollView.addGestureRecognizer(singleTap)

        context.coordinator.scrollView = scrollView
        scrollView.configure(image: image, transform: transform, fitWidthMode: fitWidthMode)
        scrollView.syncPanEnabledForCurrentZoom()
        return scrollView
    }

    func updateUIView(_ scrollView: ZoomablePhotoScrollView, context: Context) {
        context.coordinator.onZoomInteractionChanged = onZoomInteractionChanged
        context.coordinator.onSingleTap = onSingleTap
        scrollView.configure(image: image, transform: transform, fitWidthMode: fitWidthMode)
        scrollView.attachPinchPriorityToModalTransitionIfNeeded()

        if !isActivePage && scrollView.zoomScale > 1.01 {
            scrollView.setZoomScale(1.0, animated: false)
            scrollView.centerContent()
            context.coordinator.reportZoomState(false)
        }
        scrollView.syncPanEnabledForCurrentZoom()
        if isActivePage {
            context.coordinator.reportZoomState(scrollView.shouldBlockModalDismiss)
        }
    }

    @MainActor
    final class Coordinator: NSObject, UIScrollViewDelegate {
        weak var scrollView: ZoomablePhotoScrollView?
        var onZoomInteractionChanged: (Bool) -> Void
        var onSingleTap: () -> Void
        private var lastReportedZoomActive = false

        init(
            onZoomInteractionChanged: @escaping (Bool) -> Void,
            onSingleTap: @escaping () -> Void
        ) {
            self.onZoomInteractionChanged = onZoomInteractionChanged
            self.onSingleTap = onSingleTap
        }

        func reportZoomState(_ active: Bool) {
            guard active != lastReportedZoomActive else { return }
            lastReportedZoomActive = active
            onZoomInteractionChanged(active)
        }

        func viewForZooming(in scrollView: UIScrollView) -> UIView? {
            (scrollView as? ZoomablePhotoScrollView)?.contentContainerView
        }

        func scrollViewDidScroll(_ scrollView: UIScrollView) {
            guard let photoScroll = scrollView as? ZoomablePhotoScrollView else { return }
            reportZoomState(photoScroll.shouldBlockModalDismiss)
        }

        func scrollViewWillBeginZooming(_ scrollView: UIScrollView, with view: UIView?) {
            scrollView.panGestureRecognizer.isEnabled = true
            reportZoomState(true)
        }

        func scrollViewDidZoom(_ scrollView: UIScrollView) {
            guard let photoScroll = scrollView as? ZoomablePhotoScrollView else { return }
            photoScroll.centerContent()
            photoScroll.syncPanEnabledForCurrentZoom()
            reportZoomState(photoScroll.shouldBlockModalDismiss)
        }

        func scrollViewDidEndZooming(_ scrollView: UIScrollView, with view: UIView?, atScale scale: CGFloat) {
            guard let photoScroll = scrollView as? ZoomablePhotoScrollView else { return }
            photoScroll.centerContent()
            if scale <= 1.03 {
                if abs(scrollView.zoomScale - 1.0) > 0.001 {
                    scrollView.setZoomScale(1.0, animated: true)
                }
            }
            photoScroll.syncPanEnabledForCurrentZoom()
            reportZoomState(photoScroll.shouldBlockModalDismiss)
        }

        @objc func handleDoubleTap(_ gesture: UITapGestureRecognizer) {
            guard let scrollView else { return }
            if scrollView.zoomScale > 1.05 {
                scrollView.setZoomScale(1.0, animated: true)
                scrollView.syncPanEnabledForCurrentZoom()
                reportZoomState(scrollView.isFitWidthActive && scrollView.contentOffset.y > 6)
            } else {
                let targetScale: CGFloat = min(scrollView.maximumZoomScale, 2.5)
                let tapPoint = gesture.location(in: scrollView.contentContainerView)
                let width = scrollView.bounds.width / targetScale
                let height = scrollView.bounds.height / targetScale
                let rect = CGRect(
                    x: tapPoint.x - width / 2,
                    y: tapPoint.y - height / 2,
                    width: width,
                    height: height
                )
                scrollView.panGestureRecognizer.isEnabled = true
                reportZoomState(true)
                scrollView.zoom(to: rect, animated: true)
            }
        }

        @objc func handleSingleTap(_ gesture: UITapGestureRecognizer) {
            onSingleTap()
        }
    }
}

/// Native `UIScrollView` container that computes pixel-accurate aspect-fit (or long-strip fit-width)
/// layout (including 90°/270° rotation and horizontal/vertical mirror transforms) and ensures modal
/// zoom-transition pinch recognizers defer to photo zooming.
private final class ZoomablePhotoScrollView: UIScrollView {
    let contentContainerView = UIView()
    private let imageView = UIImageView()

    private var lastBoundsSize: CGSize = .zero
    private var lastImageSize: CGSize = .zero
    private var currentTransform = PreviewTransformState()
    private var requestedFitWidthMode = false
    private(set) var isFitWidthActive = false
    private var configuredTransitionGestures = NSHashTable<UIGestureRecognizer>.weakObjects()
    private var didAttachModalPinchPriority = false

    var shouldBlockModalDismiss: Bool {
        if zoomScale > 1.01 || isZooming || isZoomBouncing {
            return true
        }
        return isFitWidthActive && contentContainerView.frame.height > bounds.height + 1 && contentOffset.y > 6
    }

    override init(frame: CGRect) {
        super.init(frame: frame)
        contentContainerView.backgroundColor = .clear
        imageView.contentMode = .scaleAspectFit
        imageView.clipsToBounds = false
        contentContainerView.addSubview(imageView)
        addSubview(contentContainerView)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        if window != nil {
            attachPinchPriorityToModalTransitionIfNeeded()
        } else {
            didAttachModalPinchPriority = false
        }
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        guard bounds.width > 1, bounds.height > 1 else { return }
        if lastBoundsSize != bounds.size {
            lastBoundsSize = bounds.size
            if zoomScale <= 1.01 {
                updateFittedLayout()
            } else {
                centerContent()
            }
        } else {
            centerContent()
        }
    }

    func configure(image: UIImage, transform: PreviewTransformState, fitWidthMode: Bool = false) {
        let imageChanged = imageView.image !== image
        let imageSizeChanged = lastImageSize != image.size
        let transformChanged = currentTransform != transform
        let fitModeChanged = requestedFitWidthMode != fitWidthMode

        if imageChanged {
            imageView.image = image
            lastImageSize = image.size
        }
        currentTransform = transform
        requestedFitWidthMode = fitWidthMode

        if imageSizeChanged || transformChanged || fitModeChanged || contentContainerView.bounds.size == .zero {
            if zoomScale > 1.01 && (transformChanged || fitModeChanged) {
                setZoomScale(1.0, animated: false)
            }
            if zoomScale <= 1.01 {
                updateFittedLayout()
            } else {
                applyImageTransformOnly()
                centerContent()
            }
        }
    }

    func updateFittedLayout() {
        guard bounds.width > 1, bounds.height > 1 else { return }
        let rawSize = imageView.image?.size ?? CGSize(width: 1, height: 1)
        let isQuarterTurn = currentTransform.displayRotationDegrees == 90 || currentTransform.displayRotationDegrees == 270
        let visualAspect = isQuarterTurn
            ? (rawSize.width > 0 ? rawSize.height / rawSize.width : 1.0)
            : (rawSize.height > 0 ? rawSize.width / rawSize.height : 1.0)

        let availW = bounds.width
        let availH = bounds.height
        let useFitWidth = requestedFitWidthMode && !isQuarterTurn && (availW / availH > visualAspect)
        isFitWidthActive = useFitWidth

        let fittedSize: CGSize
        if useFitWidth {
            fittedSize = CGSize(width: availW, height: availW / max(0.0001, visualAspect))
        } else if availW / availH > visualAspect {
            fittedSize = CGSize(width: availH * visualAspect, height: availH)
        } else {
            fittedSize = CGSize(width: availW, height: availW / max(0.0001, visualAspect))
        }

        let imageScale = imageView.image?.scale ?? 1.0
        let pixelLong = max(rawSize.width * imageScale, rawSize.height * imageScale)
        let fitLong = max(1, max(fittedSize.width, fittedSize.height))
        maximumZoomScale = min(16.0, max(6.0, (pixelLong / fitLong) * 3.0))

        contentContainerView.transform = .identity
        contentContainerView.frame = CGRect(origin: .zero, size: fittedSize)
        contentSize = fittedSize
        applyImageTransformOnly()
        centerContent()
        if useFitWidth {
            contentOffset = CGPoint(x: -contentInset.left, y: -contentInset.top)
        }
        syncPanEnabledForCurrentZoom()
    }

    private func applyImageTransformOnly() {
        let baseSize = contentContainerView.bounds.size
        let isQuarterTurn = currentTransform.displayRotationDegrees == 90 || currentTransform.displayRotationDegrees == 270
        let imageBoundsSize = isQuarterTurn
            ? CGSize(width: baseSize.height, height: baseSize.width)
            : baseSize

        imageView.transform = .identity
        imageView.bounds = CGRect(origin: .zero, size: imageBoundsSize)
        imageView.center = CGPoint(x: baseSize.width / 2, y: baseSize.height / 2)

        let radians = CGFloat(currentTransform.rotationDegrees) * .pi / 180.0
        let flipX: CGFloat = currentTransform.flipHorizontal ? -1 : 1
        let flipY: CGFloat = currentTransform.flipVertical ? -1 : 1
        imageView.transform = CGAffineTransform(rotationAngle: radians)
            .concatenating(CGAffineTransform(scaleX: flipX, y: flipY))
    }

    func syncPanEnabledForCurrentZoom() {
        let canScrollLongStrip = isFitWidthActive && contentContainerView.frame.height > bounds.height + 1
        let shouldPan = zoomScale > 1.01 || isZooming || isZoomBouncing || canScrollLongStrip
        if panGestureRecognizer.isEnabled != shouldPan {
            panGestureRecognizer.isEnabled = shouldPan
        }
    }

    func centerContent() {
        let boundsSize = bounds.size
        let contentFrame = contentContainerView.frame
        let horizontalInset = max(0, (boundsSize.width - contentFrame.width) * 0.5)
        let verticalInset = max(0, (boundsSize.height - contentFrame.height) * 0.5)
        let targetInset = UIEdgeInsets(
            top: verticalInset,
            left: horizontalInset,
            bottom: verticalInset,
            right: horizontalInset
        )
        if contentInset != targetInset {
            contentInset = targetInset
        }
    }

    /// Ensures any pinch-to-dismiss gesture attached to the presented `.navigationTransition(.zoom)`
    /// modal defers to `UIScrollView.pinchGestureRecognizer` whenever two fingers are pinching a photo.
    func attachPinchPriorityToModalTransitionIfNeeded() {
        guard !didAttachModalPinchPriority,
              let scrollPinch = pinchGestureRecognizer,
              let modalVC = ZoomDismissTransitionLookup.presentedModalViewController(from: self) else {
            return
        }
        let recognizers = ZoomDismissTransitionLookup.modalTransitionDismissRecognizers(for: modalVC)
        for recognizer in recognizers {
            guard !configuredTransitionGestures.contains(recognizer) else { continue }
            let typeName = String(describing: type(of: recognizer))
            if recognizer is UIPinchGestureRecognizer
                || typeName.localizedCaseInsensitiveContains("Pinch")
                || (typeName.localizedCaseInsensitiveContains("Zoom") && !(recognizer is UIPanGestureRecognizer)) {
                recognizer.require(toFail: scrollPinch)
                configuredTransitionGestures.add(recognizer)
            }
        }
        if !recognizers.isEmpty {
            didAttachModalPinchPriority = true
        }
    }
}

/// Shared modal zoom-transition recognizer discovery helper. Strictly scopes to the presented
/// `fullScreenCover` view controller and its own presentation container, never touching
/// SwiftUI's internal button/hosting recognizers or child `UIScrollView`s.
@MainActor
private enum ZoomDismissTransitionLookup {
    static func presentedModalViewController(from responder: UIResponder) -> UIViewController? {
        var current: UIResponder? = responder
        var foundVC: UIViewController?
        while let next = current {
            if let vc = next as? UIViewController {
                foundVC = vc
                break
            }
            current = next.next
        }
        guard var vc = foundVC else { return nil }
        while let parent = vc.parent, vc.presentingViewController == nil {
            vc = parent
        }
        return vc.presentingViewController != nil ? vc : nil
    }

    static func modalTransitionDismissRecognizers(for modalVC: UIViewController) -> [UIGestureRecognizer] {
        let excludedView = modalVC.presentingViewController?.view
        var hostViews: [UIView] = []
        var seenViews = Set<ObjectIdentifier>()

        for candidate in [modalVC.view, modalVC.view?.superview, modalVC.presentationController?.containerView] {
            guard let view = candidate, view !== excludedView else { continue }
            if seenViews.insert(ObjectIdentifier(view)).inserted {
                hostViews.append(view)
            }
        }

        var matches: [UIGestureRecognizer] = []
        var seenRecognizers = Set<ObjectIdentifier>()
        for view in hostViews {
            for recognizer in view.gestureRecognizers ?? [] {
                guard seenRecognizers.insert(ObjectIdentifier(recognizer)).inserted else { continue }
                if isZoomTransitionDismissRecognizer(recognizer) {
                    matches.append(recognizer)
                }
            }
        }
        return matches
    }

    private static func isZoomTransitionDismissRecognizer(_ recognizer: UIGestureRecognizer) -> Bool {
        if recognizer.view is UIScrollView { return false }
        if recognizer is UITapGestureRecognizer || recognizer is UILongPressGestureRecognizer {
            return false
        }
        let typeName = String(describing: type(of: recognizer))
        // Never disable SwiftUI's own hosting gesture recognizers (buttons, menus, taps).
        if typeName.contains("SwiftUI") { return false }
        if recognizer is UIPinchGestureRecognizer || recognizer is UIPanGestureRecognizer {
            return true
        }
        return typeName.localizedCaseInsensitiveContains("Zoom")
            || typeName.localizedCaseInsensitiveContains("Dismiss")
            || typeName.localizedCaseInsensitiveContains("Transition")
    }
}

/// Temporarily disables `.navigationTransition(.zoom)`'s interactive dismiss recognizers while the
/// currently displayed photo is zoomed in (`zoomScale > 1.01`) or actively pinching/bouncing back
/// to `1.0x`, restoring them immediately once settled back at `1.0x` so swipe-down-to-dismiss
/// remains effortless at resting scale.
private struct ZoomDismissCoordinatorBridge: UIViewControllerRepresentable {
    let isZoomedOrZooming: Bool

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func makeUIViewController(context: Context) -> UIViewController {
        let vc = UIViewController()
        vc.view.isUserInteractionEnabled = false
        vc.view.backgroundColor = .clear
        return vc
    }

    func updateUIViewController(_ uiViewController: UIViewController, context: Context) {
        context.coordinator.apply(isZoomedOrZooming: isZoomedOrZooming, from: uiViewController)
    }

    static func dismantleUIViewController(_ uiViewController: UIViewController, coordinator: Coordinator) {
        coordinator.restoreAll()
    }

    @MainActor
    final class Coordinator {
        private var disabledRecognizers: [WeakGestureBox] = []

        private final class WeakGestureBox {
            weak var recognizer: UIGestureRecognizer?
            init(_ recognizer: UIGestureRecognizer) {
                self.recognizer = recognizer
            }
        }

        func apply(isZoomedOrZooming: Bool, from viewController: UIViewController) {
            if isZoomedOrZooming {
                guard let modalVC = ZoomDismissTransitionLookup.presentedModalViewController(from: viewController) else {
                    return
                }
                for recognizer in ZoomDismissTransitionLookup.modalTransitionDismissRecognizers(for: modalVC) {
                    guard recognizer.isEnabled else { continue }
                    recognizer.isEnabled = false
                    disabledRecognizers.append(WeakGestureBox(recognizer))
                }
            } else {
                restoreAll()
            }
        }

        func restoreAll() {
            for box in disabledRecognizers {
                box.recognizer?.isEnabled = true
            }
            disabledRecognizers.removeAll()
        }
    }
}

// MARK: - Full 2-Tab Detail Inspector (Info | Similar Assets)

private struct DetailInspectorPanel: View {
    private enum FocusField: Hashable {
        case title
        case tag
        case notes
    }

    @Bindable var store: MobileAppStore
    let asset: AssetRecord
    @Binding var selectedTab: AssetDetailView.DetailInspectorTab
    @Binding var isTextFieldFocused: Bool
    let onSelectAsset: (UUID) -> Void
    let onFilterByColor: (String) -> Void
    let onFilterByTag: (String) -> Void
    let onDismissDetail: () -> Void

    @Environment(\.colorScheme) private var colorScheme
    @FocusState private var focusedField: FocusField?
    @State private var titleDraft: String = ""
    @State private var notesDraft: String = ""
    @State private var loadedAssetID: UUID? = nil
    @State private var loadedTitleBaseline: String = ""
    @State private var loadedNotesBaseline: String = ""
    @State private var newTagText: String = ""
    @State private var isInspectorFolderPickerPresented: Bool = false

    var body: some View {
        VStack(spacing: 0) {
            Picker("检查器", selection: $selectedTab) {
                ForEach(AssetDetailView.DetailInspectorTab.allCases, id: \.self) { tab in
                    Text(tab.rawValue).tag(tab)
                }
            }
            .pickerStyle(.segmented)
            .padding(12)

            Divider()

            if selectedTab == .info {
                infoTabContent
            } else {
                similarTabContent
            }
        }
        .onAppear { syncDrafts() }
        .onChange(of: focusedField) { _, newValue in
            isTextFieldFocused = (newValue != nil)
        }
        .onChange(of: asset.id) { _, _ in
            flushPendingDrafts()
            syncDrafts()
        }
        .onChange(of: asset.title) { _, newValue in
            if loadedAssetID == asset.id && titleDraft == loadedTitleBaseline {
                titleDraft = newValue
                loadedTitleBaseline = newValue
            }
        }
        .onChange(of: asset.notes) { _, newValue in
            if loadedAssetID == asset.id && notesDraft == loadedNotesBaseline {
                notesDraft = newValue
                loadedNotesBaseline = newValue
            }
        }
        .onDisappear {
            isTextFieldFocused = false
            flushPendingDrafts()
        }
    }

    private func syncDrafts() {
        loadedAssetID = asset.id
        titleDraft = asset.title
        notesDraft = asset.notes
        loadedTitleBaseline = asset.title
        loadedNotesBaseline = asset.notes
    }

    private func flushPendingDrafts() {
        guard let targetID = loadedAssetID else { return }
        let trimmedTitle = titleDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        let titleChanged = !trimmedTitle.isEmpty && trimmedTitle != loadedTitleBaseline
        let notesChanged = notesDraft != loadedNotesBaseline
        guard titleChanged || notesChanged else { return }

        let nextTitle: String? = titleChanged ? trimmedTitle : nil
        let nextNotes: String? = notesChanged ? notesDraft : nil
        if titleChanged { loadedTitleBaseline = trimmedTitle }
        if notesChanged { loadedNotesBaseline = notesDraft }
        Task {
            await store.patchAssets(
                AssetBatchPatch(assetIDs: [targetID], title: nextTitle, notes: nextNotes)
            )
        }
    }

    private var infoTabContent: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                inspectorCard("基本信息") {
                    TextField("标题", text: $titleDraft)
                        .focused($focusedField, equals: .title)
                        .font(.system(size: 14, weight: .semibold))
                        .onSubmit { saveTitle() }
                        .padding(10)
                        .background(MobileTheme.inspectorFieldSurface(for: colorScheme), in: RoundedRectangle(cornerRadius: 8, style: .continuous))

                    HStack {
                        Text("评分")
                            .font(.system(size: 13))
                            .foregroundStyle(MobileTheme.secondaryInk(for: colorScheme))
                        Spacer()
                        HStack(spacing: 4) {
                            ForEach(1...5, id: \.self) { star in
                                Button {
                                    let next = asset.rating == star ? 0 : star
                                    Task {
                                        await store.patchAssets(AssetBatchPatch(assetIDs: [asset.id], rating: next))
                                    }
                                } label: {
                                    Image(systemName: star <= asset.rating ? "star.fill" : "star")
                                        .font(.system(size: 15))
                                        .foregroundStyle(
                                            star <= asset.rating
                                                ? Color(charkleHex: "#F2C14E")
                                                : MobileTheme.tertiaryInk(for: colorScheme)
                                        )
                                }
                                .buttonStyle(.plain)
                            }
                        }
                    }

                    HStack {
                        Text("文件夹")
                            .font(.system(size: 13))
                            .foregroundStyle(MobileTheme.secondaryInk(for: colorScheme))
                        Spacer()
                        Menu {
                            Button {
                                Task {
                                    await store.patchAssets(
                                        AssetBatchPatch(assetIDs: [asset.id], folderAssignment: .inbox),
                                        successToast: "已移回收件箱"
                                    )
                                }
                            } label: {
                                Label(
                                    asset.folderID == nil ? "收件箱  ✓" : "收件箱",
                                    systemImage: "tray"
                                )
                            }
                            if !store.folderTree.isEmpty {
                                Divider()
                                HierarchicalFolderMenuContent(
                                    nodes: store.folderTree,
                                    currentFolderID: asset.folderID
                                ) { folderID, folderName in
                                    Task {
                                        await store.patchAssets(
                                            AssetBatchPatch(assetIDs: [asset.id], folderAssignment: .folder(folderID)),
                                            successToast: "已归档到「\(folderName)」"
                                        )
                                    }
                                }
                                Divider()
                                Button {
                                    isInspectorFolderPickerPresented = true
                                } label: {
                                    Label("按层级浏览并搜索…", systemImage: "list.bullet.indent")
                                }
                            }
                        } label: {
                            HStack(spacing: 4) {
                                Text(folderName)
                                    .font(.system(size: 13, weight: .medium))
                                    .lineLimit(1)
                                Image(systemName: "chevron.up.chevron.down")
                                    .font(.system(size: 10))
                            }
                            .foregroundStyle(MobileTheme.accent(for: colorScheme))
                        }
                    }
                    .sheet(isPresented: $isInspectorFolderPickerPresented) {
                        NavigationStack {
                            HierarchicalFolderPickerSheet(
                                title: "选择文件夹",
                                folderTree: store.folderTree,
                                currentFolderID: asset.folderID,
                                onPick: { folderID, pickedName in
                                    let id = asset.id
                                    isInspectorFolderPickerPresented = false
                                    Task {
                                        await store.patchAssets(
                                            AssetBatchPatch(
                                                assetIDs: [id],
                                                folderAssignment: folderID.map { .folder($0) } ?? .inbox
                                            ),
                                            successToast: folderID == nil ? "已移回收件箱" : "已归档到「\(pickedName)」"
                                        )
                                    }
                                }
                            )
                        }
                        .presentationDetents([.medium, .large])
                    }

                    Toggle("离线置顶原图", isOn: Binding(
                        get: { asset.pinnedOffline },
                        set: { next in
                            Task {
                                await store.patchAssets(
                                    AssetBatchPatch(assetIDs: [asset.id], pinnedOffline: next),
                                    successToast: next ? "已置顶离线原图" : "已取消离线置顶"
                                )
                            }
                        }
                    ))
                    .font(.system(size: 13))
                }

                if let post = asset.richMetadata?.socialPost, (!post.effectiveAttachments.isEmpty || post.isZeroDownloadVideoBookmark) {
                    let attachments = post.effectiveAttachments
                    inspectorCard(post.isZeroDownloadVideoBookmark ? "视频保存" : "帖子内媒体（\(attachments.count) 项）") {
                        Button {
                            MobileHaptics.light()
                            let target = asset
                            Task { _ = await store.extractAllMediaFromSocialPost(postAsset: target) }
                        } label: {
                            HStack(spacing: 6) {
                                if store.isExtractingSocialMedia {
                                    ProgressView().controlSize(.mini).tint(.white)
                                } else {
                                    Image(systemName: post.isZeroDownloadVideoBookmark ? "film.stack" : "square.and.arrow.down.on.square")
                                }
                                Text(
                                    store.isExtractingSocialMedia
                                        ? (post.isZeroDownloadVideoBookmark ? "正在保存视频…" : "正在提取…")
                                        : (post.isZeroDownloadVideoBookmark
                                            ? "保存视频为独立素材"
                                            : "全部提取为独立素材（\(attachments.count) 项）")
                                )
                                .font(.system(size: 13, weight: .semibold))
                            }
                            .foregroundStyle(.white)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 9)
                            .background(MobileTheme.accentButtonFill(for: colorScheme), in: RoundedRectangle(cornerRadius: 9, style: .continuous))
                        }
                        .buttonStyle(MobileTactileButtonStyle())
                        .disabled(store.isExtractingSocialMedia)

                        if !post.isZeroDownloadVideoBookmark {
                            ForEach(Array(attachments.enumerated()), id: \.offset) { idx, attachment in
                                Button {
                                    MobileHaptics.light()
                                    let target = asset
                                    Task {
                                        _ = await store.extractMediaFromSocialPost(
                                            postAsset: target,
                                            attachment: attachment,
                                            index: idx
                                        )
                                    }
                                } label: {
                                    HStack(spacing: 8) {
                                        Image(systemName: attachment.kind == .photo ? "photo" : "film")
                                            .font(.system(size: 12.5, weight: .medium))
                                            .foregroundStyle(MobileTheme.accent(for: colorScheme))
                                        Text("提取第 \(idx + 1) 个\(attachment.kind.localizedLabel)为独立素材")
                                            .font(.system(size: 12.5, weight: .medium))
                                            .foregroundStyle(.primary)
                                            .lineLimit(1)
                                        Spacer()
                                        Image(systemName: "square.and.arrow.down")
                                            .font(.system(size: 12, weight: .semibold))
                                            .foregroundStyle(MobileTheme.secondaryInk(for: colorScheme))
                                    }
                                    .padding(.vertical, 4)
                                    .contentShape(Rectangle())
                                }
                                .buttonStyle(.plain)
                                .disabled(store.isExtractingSocialMedia)
                            }
                        }
                    }
                }

                if !asset.dominantColors.isEmpty {
                    inspectorCard("主色板（点击复制 / 长按搜同色）") {
                        HStack(spacing: 8) {
                            ForEach(asset.dominantColors.prefix(6), id: \.hex) { swatch in
                                VStack(spacing: 4) {
                                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                                        .fill(Color(charkleHex: swatch.hex))
                                        .frame(height: 36)
                                        .overlay(
                                            RoundedRectangle(cornerRadius: 8, style: .continuous)
                                                .strokeBorder(MobileTheme.hairline(for: colorScheme), lineWidth: 0.75)
                                        )
                                        .onTapGesture {
                                            UIPasteboard.general.string = swatch.hex
                                            MobileHaptics.light()
                                            store.showToast("已复制色值 \(swatch.hex)", tone: .info)
                                        }
                                        .contextMenu {
                                            Button("复制色值 \(swatch.hex)", systemImage: "doc.on.doc") {
                                                UIPasteboard.general.string = swatch.hex
                                            }
                                            Button("按此颜色筛图", systemImage: "paintpalette") {
                                                onFilterByColor(swatch.hex)
                                            }
                                        }
                                    Text(swatch.hex.replacingOccurrences(of: "#", with: ""))
                                        .font(.system(size: 9.5, design: .monospaced))
                                        .foregroundStyle(MobileTheme.tertiaryInk(for: colorScheme))
                                }
                            }
                        }
                    }
                }

                inspectorCard("标签") {
                    if !asset.tags.isEmpty {
                        FlowTagGrid(tags: asset.tags) { tag in
                            HStack(spacing: 4) {
                                Button("#\(tag)") {
                                    onFilterByTag(tag)
                                }
                                .font(.system(size: 12, weight: .medium))
                                .buttonStyle(.plain)
                                Button {
                                    Task {
                                        await store.patchAssets(AssetBatchPatch(assetIDs: [asset.id], removeTags: [tag]))
                                    }
                                } label: {
                                    Image(systemName: "xmark")
                                        .font(.system(size: 9, weight: .bold))
                                        .foregroundStyle(MobileTheme.tertiaryInk(for: colorScheme))
                                }
                                .buttonStyle(.plain)
                            }
                            .padding(.horizontal, 9)
                            .padding(.vertical, 5)
                            .background(MobileTheme.surfaceSubtle(for: colorScheme), in: Capsule())
                        }
                    }

                    if !asset.suggestedTags.isEmpty {
                        VStack(alignment: .leading, spacing: 6) {
                            HStack {
                                Text("推荐标签")
                                    .font(.system(size: 11.5, weight: .medium))
                                    .foregroundStyle(MobileTheme.secondaryInk(for: colorScheme))
                                Spacer()
                                Button("全部采纳") {
                                    Task {
                                        await store.patchAssets(
                                            AssetBatchPatch(assetIDs: [asset.id], acceptSuggestedTags: true),
                                            successToast: "已采纳推荐标签"
                                        )
                                    }
                                }
                                .font(.system(size: 11.5, weight: .semibold))
                            }
                            FlowTagGrid(tags: asset.suggestedTags) { tag in
                                Button {
                                    Task {
                                        await store.patchAssets(AssetBatchPatch(assetIDs: [asset.id], addTags: [tag]))
                                    }
                                } label: {
                                    Text("+ \(tag)")
                                        .font(.system(size: 11.5, weight: .medium))
                                        .foregroundStyle(MobileTheme.accent(for: colorScheme))
                                        .padding(.horizontal, 8)
                                        .padding(.vertical, 4)
                                        .background(MobileTheme.accentSoft(for: colorScheme), in: Capsule())
                                }
                                .buttonStyle(.plain)
                            }
                        }
                    }

                    HStack(spacing: 8) {
                        TextField("添加标签…", text: $newTagText)
                            .focused($focusedField, equals: .tag)
                            .font(.system(size: 13))
                            .textInputAutocapitalization(.never)
                            .onSubmit { addNewTag() }
                            .padding(8)
                            .background(MobileTheme.inspectorFieldSurface(for: colorScheme), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                        Button("添加", action: addNewTag)
                            .font(.system(size: 13, weight: .semibold))
                            .disabled(newTagText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    }
                }

                inspectorCard("备注与识别文本") {
                    TextField("写下灵感说明或用途备注…", text: $notesDraft, axis: .vertical)
                        .focused($focusedField, equals: .notes)
                        .lineLimit(3...6)
                        .font(.system(size: 13))
                        .padding(10)
                        .background(MobileTheme.inspectorFieldSurface(for: colorScheme), in: RoundedRectangle(cornerRadius: 8, style: .continuous))

                    if notesDraft != asset.notes {
                        Button("保存备注") {
                            let targetID = asset.id
                            let draft = notesDraft
                            loadedNotesBaseline = draft
                            Task {
                                await store.patchAssets(
                                    AssetBatchPatch(assetIDs: [targetID], notes: draft),
                                    successToast: "备注已保存"
                                )
                            }
                        }
                        .font(.system(size: 12.5, weight: .semibold))
                    }

                    if let ocr = asset.ocrText, !ocr.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("画面识别文字")
                                .font(.system(size: 11.5, weight: .semibold))
                                .foregroundStyle(MobileTheme.secondaryInk(for: colorScheme))
                            Text(ocr)
                                .font(.system(size: 12))
                                .foregroundStyle(MobileTheme.secondaryInk(for: colorScheme))
                                .textSelection(.enabled)
                        }
                    }
                }

                if let ai = asset.richMetadata?.aiGeneration, !ai.isEmpty {
                    inspectorCard("AI 生图参数") {
                        if let prompt = ai.prompt, !prompt.isEmpty {
                            Text(prompt)
                                .font(.system(size: 12))
                                .textSelection(.enabled)
                            Button("复制提示词") {
                                UIPasteboard.general.string = prompt
                                store.showToast("已复制提示词", tone: .info)
                            }
                            .font(.system(size: 12, weight: .semibold))
                        }
                        if let model = ai.modelName { specRow("模型", model) }
                        if let sampler = ai.sampler { specRow("采样器", sampler) }
                        if let steps = ai.steps { specRow("步数", "\(steps)") }
                        if let seed = ai.seed { specRow("种子", seed) }
                    }
                }

                if let exif = asset.richMetadata?.photoExif, exif.hasMeaningfulCameraExif {
                    inspectorCard("拍摄参数") {
                        if let camera = exif.cameraDisplayName { specRow("相机", camera) }
                        if let lens = exif.lensModel { specRow("镜头", lens) }
                        if let exposure = exif.exposureSummary { specRow("曝光", exposure) }
                    }
                }

                inspectorCard("文件与维护") {
                    specRow("文件名", asset.fileName)
                    if asset.pixelWidth > 0 && asset.pixelHeight > 0 {
                        specRow("尺寸", "\(asset.pixelWidth) × \(asset.pixelHeight)")
                    }
                    if asset.fileSizeBytes > 0 {
                        specRow("大小", MobileFormatters.byteCount(asset.fileSizeBytes))
                    }
                    if let domain = asset.sourceDomain, !domain.isEmpty {
                        specRow("来源", domain)
                    }
                    HStack(spacing: 8) {
                        Button("重提视觉特征") {
                            Task { await store.analyzeLocally(assetID: asset.id) }
                        }
                        .font(.system(size: 12, weight: .medium))
                        .padding(.horizontal, 10)
                        .padding(.vertical, 6)
                        .background(MobileTheme.surfaceSubtle(for: colorScheme), in: Capsule())

                        if asset.sourceURL != nil {
                            Button("刷新来源") {
                                Task { await store.refreshRichMetadata(assetID: asset.id) }
                            }
                            .font(.system(size: 12, weight: .medium))
                            .padding(.horizontal, 10)
                            .padding(.vertical, 6)
                            .background(MobileTheme.surfaceSubtle(for: colorScheme), in: Capsule())
                        }
                    }
                    .buttonStyle(.plain)

                    Button(role: .destructive) {
                        let targetID = asset.id
                        let wasTrashed = asset.isTrashed
                        Task {
                            if wasTrashed {
                                await store.patchAssets(
                                    AssetBatchPatch(assetIDs: [targetID], isTrashed: false),
                                    successToast: "已恢复素材"
                                )
                            } else {
                                await store.patchAssets(
                                    AssetBatchPatch(assetIDs: [targetID], isTrashed: true),
                                    successToast: "已移入回收站",
                                    actionTitle: "撤销",
                                    onAction: {
                                        Task {
                                            await store.patchAssets(
                                                AssetBatchPatch(assetIDs: [targetID], isTrashed: false),
                                                successToast: "已撤销移入回收站"
                                            )
                                        }
                                    }
                                )
                            }
                            onDismissDetail()
                        }
                    } label: {
                        Label(asset.isTrashed ? "从回收站恢复" : "移至回收站", systemImage: asset.isTrashed ? "arrow.uturn.backward" : "trash")
                            .font(.system(size: 13, weight: .medium))
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 8)
                    }
                }
            }
            .padding(14)
        }
        .charkleDismissKeyboardOnScroll()
    }

    private var similarTabContent: some View {
        ScrollView {
            if store.isLoadingSimilar {
                ProgressView("正在按本机视觉特征匹配…")
                    .font(.system(size: 13))
                    .padding(.top, 48)
            } else if store.similarResults.isEmpty {
                VStack(spacing: 12) {
                    Text("暂未找到视觉相似素材")
                        .font(.system(size: 14, weight: .semibold))
                    Text("可先对当前素材执行本机视觉特征提取，或同步更多素材后再试。")
                        .font(.system(size: 12.5))
                        .foregroundStyle(MobileTheme.secondaryInk(for: colorScheme))
                        .multilineTextAlignment(.center)
                    Button("立即提取视觉特征") {
                        Task { await store.analyzeLocally(assetID: asset.id) }
                    }
                    .font(.system(size: 13, weight: .semibold))
                }
                .padding(28)
            } else {
                LazyVGrid(columns: [GridItem(.flexible(), spacing: 8), GridItem(.flexible(), spacing: 8)], spacing: 8) {
                    ForEach(store.similarResults) { scored in
                        Button {
                            onSelectAsset(scored.asset.id)
                        } label: {
                            ZStack(alignment: .bottomLeading) {
                                SimilarThumbTile(asset: scored.asset, thumbnails: store.thumbnails)
                                Text("\(Int((scored.score * 100).rounded()))%")
                                    .font(.system(size: 10, weight: .semibold).monospacedDigit())
                                    .foregroundStyle(.white)
                                    .padding(.horizontal, 6)
                                    .padding(.vertical, 2.5)
                                    .background(.black.opacity(0.60), in: Capsule())
                                    .padding(6)
                            }
                            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                        }
                        .buttonStyle(MobileTactileButtonStyle())
                    }
                }
                .padding(12)
            }
        }
    }

    private var folderName: String {
        guard let fid = asset.folderID else { return "收件箱" }
        return FolderHierarchyNode.breadcrumbPath(for: fid, in: store.folderTree)
            ?? store.folders.first(where: { $0.id == fid })?.name
            ?? "文件夹"
    }

    private func saveTitle() {
        let trimmed = titleDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed != asset.title else { return }
        loadedTitleBaseline = trimmed
        let targetID = asset.id
        Task {
            await store.patchAssets(AssetBatchPatch(assetIDs: [targetID], title: trimmed), successToast: "标题已更新")
        }
    }

    private func addNewTag() {
        let parsed = newTagText
            .split(whereSeparator: { $0 == "," || $0 == "，" || $0 == " " })
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        newTagText = ""
        guard !parsed.isEmpty else { return }
        Task {
            await store.patchAssets(AssetBatchPatch(assetIDs: [asset.id], addTags: parsed))
        }
    }

    private func inspectorCard<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title)
                .font(.system(size: 11.5, weight: .semibold))
                .foregroundStyle(MobileTheme.secondaryInk(for: colorScheme))
            content()
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            MobileTheme.surfaceElevated(for: colorScheme),
            in: RoundedRectangle(cornerRadius: MobileTheme.Radius.cardOuter, style: .continuous)
        )
        .overlay(
            RoundedRectangle(cornerRadius: MobileTheme.Radius.cardOuter, style: .continuous)
                .strokeBorder(MobileTheme.hairline(for: colorScheme), lineWidth: 0.75)
        )
    }

    private func specRow(_ label: String, _ value: String) -> some View {
        HStack(alignment: .top) {
            Text(label)
                .font(.system(size: 12))
                .foregroundStyle(MobileTheme.secondaryInk(for: colorScheme))
            Spacer(minLength: 10)
            Text(value)
                .font(.system(size: 12).monospacedDigit())
                .multilineTextAlignment(.trailing)
                .textSelection(.enabled)
        }
    }
}

private struct SimilarThumbTile: View {
    let asset: AssetRecord
    let thumbnails: MobileThumbnailCache
    @State private var image: UIImage?

    var body: some View {
        Color(.secondarySystemFill)
            .aspectRatio(1, contentMode: .fit)
            .overlay {
                if let image {
                    Image(uiImage: image)
                        .resizable()
                        .scaledToFill()
                }
            }
            .clipped()
            .task(id: asset.id) {
                image = await thumbnails.loadImage(for: asset.id, tier: .grid520)
            }
    }
}

private struct FlowTagGrid<Item: Hashable, Content: View>: View {
    let tags: [Item]
    let content: (Item) -> Content

    var body: some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 72), spacing: 6)], alignment: .leading, spacing: 6) {
            ForEach(tags, id: \.self) { tag in
                content(tag)
            }
        }
    }
}

private nonisolated struct UncheckedPDFDocumentBox: @unchecked Sendable {
    let document: PDFDocument?
}

private struct PDFDocumentPreview: View {
    let url: URL
    @State private var document: PDFDocument?
    @State private var isLoading = true

    var body: some View {
        ZStack {
            if let document {
                PDFKitRepresentable(document: document)
            } else if isLoading {
                ProgressView("正在解析 PDF…")
                    .font(.system(size: 13))
            } else {
                Text("无法打开此 PDF 文档")
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
            }
        }
        .task(id: url) {
            isLoading = true
            let box = await Self.loadDocumentOffMain(url: url)
            guard !Task.isCancelled else { return }
            document = box.document
            isLoading = false
        }
    }

    @concurrent
    private static func loadDocumentOffMain(url: URL) async -> UncheckedPDFDocumentBox {
        UncheckedPDFDocumentBox(document: PDFDocument(url: url))
    }
}

private struct PDFKitRepresentable: UIViewRepresentable {
    let document: PDFDocument

    func makeUIView(context: Context) -> PDFView {
        let view = PDFView()
        view.autoScales = true
        view.document = document
        return view
    }

    func updateUIView(_ uiView: PDFView, context: Context) {
        if uiView.document !== document {
            uiView.document = document
        }
    }
}

struct ActivityShareSheet: UIViewControllerRepresentable {
    let items: [Any]

    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: items, applicationActivities: nil)
    }

    func updateUIViewController(_ uiViewController: UIActivityViewController, context: Context) {}
}

/// Referer-aware remote image loader for social post attachments (Douyin, Xiaohongshu, Bilibili CDNs).
private struct MobileSocialRemoteImageView: View {
    let url: URL
    let fallbackSymbol: String

    @Environment(\.colorScheme) private var colorScheme
    @State private var loadedImage: UIImage?
    @State private var loadedURL: URL?

    var body: some View {
        Group {
            if let img = (loadedURL == url ? loadedImage : nil) {
                Image(uiImage: img)
                    .resizable()
                    .scaledToFill()
            } else {
                MobileTheme.surfaceSubtle(for: colorScheme)
                    .overlay {
                        Image(systemName: fallbackSymbol)
                            .foregroundStyle(MobileTheme.tertiaryInk(for: colorScheme))
                    }
            }
        }
        .task(id: url) {
            if loadedURL == url, loadedImage != nil { return }
            let target = url
            if let data = await Self.fetchImageDataOffMain(url: target),
               !Task.isCancelled,
               let image = UIImage(data: data) {
                loadedImage = image
                loadedURL = target
            }
        }
    }

    @concurrent
    private static func fetchImageDataOffMain(url targetURL: URL) async -> Data? {
        guard !Task.isCancelled, WebBookmark.isSafeRemoteFetchURL(targetURL) else { return nil }
        var req = URLRequest(url: targetURL, timeoutInterval: 10)
        let ua = "Mozilla/5.0 (iPhone; CPU iPhone OS 18_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.0 Mobile/15E148 Safari/604.1"
        if DouyinURLParser.isDouyinMediaHost(targetURL.host()) {
            req.setValue(ua, forHTTPHeaderField: "User-Agent")
            req.setValue(DouyinURLParser.referer, forHTTPHeaderField: "Referer")
        } else if XiaohongshuURLParser.isXiaohongshuMediaHost(targetURL.host()) {
            req.setValue(ua, forHTTPHeaderField: "User-Agent")
            req.setValue("https://www.xiaohongshu.com/", forHTTPHeaderField: "Referer")
        } else if VideoPlatformURLParser.isBilibiliMediaHost(targetURL.host()) {
            req.setValue(ua, forHTTPHeaderField: "User-Agent")
            req.setValue("https://www.bilibili.com/", forHTTPHeaderField: "Referer")
        } else {
            req.setValue("Charkle/1.0 (+https://charkle.app)", forHTTPHeaderField: "User-Agent")
        }
        req.setValue("image/avif,image/webp,image/png,image/jpeg,image/*", forHTTPHeaderField: "Accept")
        guard let (data, resp) = try? await URLSession.shared.data(for: req),
              !Task.isCancelled,
              let http = resp as? HTTPURLResponse,
              (200..<300).contains(http.statusCode),
              !data.isEmpty,
              data.count <= 20 * 1024 * 1024 else {
            return nil
        }
        return data
    }
}
