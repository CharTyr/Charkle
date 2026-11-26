import AVKit
import CharkleCore
import PDFKit
import SwiftUI
import UIKit

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

    @State private var currentAssetID: UUID
    @State private var isInspectorVisible: Bool
    @State private var isCompactInspectorPresented: Bool
    @State private var selectedInspectorTab: DetailInspectorTab
    @State private var shareFileURL: URL?
    @State private var isPreparingShare = false
    @State private var previewTransform = PreviewTransformState()
    @State private var isChromeVisible: Bool = true
    @State private var activeUtilityDrawer: ActiveUtilityDrawer? = nil
    @State private var confirmPermanentDelete: Bool = false

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
        _currentAssetID = State(initialValue: initialAsset.id)
        _selectedInspectorTab = State(initialValue: initialInspectorTab)
        _isInspectorVisible = State(initialValue: true)
        _isCompactInspectorPresented = State(initialValue: openInspectorImmediately)
    }

    private var orderedAssets: [AssetRecord] {
        let live = store.assets
        if live.contains(where: { $0.id == currentAssetID }) {
            return live
        }
        if allAssets.contains(where: { $0.id == currentAssetID }) {
            return allAssets
        }
        return [initialAsset]
    }

    private var currentAsset: AssetRecord {
        store.assets.first(where: { $0.id == currentAssetID })
            ?? allAssets.first(where: { $0.id == currentAssetID })
            ?? initialAsset
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
                        onSelectAsset: { nextID in
                            currentAssetID = nextID
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
        .statusBarHidden(!isChromeVisible)
        .sheet(isPresented: $isCompactInspectorPresented) {
            NavigationStack {
                DetailInspectorPanel(
                    store: store,
                    asset: currentAsset,
                    selectedTab: $selectedInspectorTab,
                    onSelectAsset: { nextID in
                        isCompactInspectorPresented = false
                        currentAssetID = nextID
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
        .onChange(of: currentAssetID) { _, nextID in
            previewTransform.reset()
            onCurrentAssetChanged(nextID)
        }
        .task(id: currentAssetID) {
            _ = try? await store.engine.hydrateImageMetadataIfNeeded(id: currentAssetID)
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
                    Button("收件箱") {
                        Task {
                            await store.patchAssets(
                                AssetBatchPatch(assetIDs: [currentAsset.id], folderAssignment: .inbox),
                                successToast: "已移回收件箱"
                            )
                        }
                    }
                    ForEach(store.flattenedFolders) { node in
                        Button(String(repeating: "  ", count: min(node.depth, 3)) + node.folder.name) {
                            Task {
                                await store.patchAssets(
                                    AssetBatchPatch(assetIDs: [currentAsset.id], folderAssignment: .folder(node.folder.id)),
                                    successToast: "已归档到「\(node.folder.name)」"
                                )
                            }
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
                            successToast: "已移入回收站"
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
        TabView(selection: $currentAssetID) {
            ForEach(orderedAssets) { asset in
                AssetStageContentView(
                    store: store,
                    asset: asset,
                    transform: asset.id == currentAssetID ? previewTransform : PreviewTransformState(),
                    onSingleTap: {
                        withAnimation(MobileMotion.accessible(MobileMotion.enterSm, reduced: reduceMotion)) {
                            isChromeVisible.toggle()
                            if !isChromeVisible {
                                activeUtilityDrawer = nil
                            }
                        }
                    }
                )
                .tag(asset.id)
            }
        }
        .tabViewStyle(.page(indexDisplayMode: .never))
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
            .onChange(of: selectedID) { _, next in
                withAnimation(MobileMotion.settleStrong) {
                    proxy.scrollTo(next, anchor: .center)
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
        Color(.secondarySystemFill)
            .overlay {
                if let image {
                    Image(uiImage: image)
                        .resizable()
                        .scaledToFill()
                }
            }
            .clipped()
            .task(id: asset.id) {
                if let hit = thumbnails.cachedImage(for: asset.id, tier: .grid520) {
                    image = hit
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
    let onSingleTap: () -> Void

    @Environment(\.colorScheme) private var colorScheme
    @State private var image: UIImage?
    @State private var localOriginalURL: URL?

    var body: some View {
        Group {
            if asset.mediaKind == .video, let localOriginalURL {
                VideoPlayer(player: AVPlayer(url: localOriginalURL))
                    .clipShape(RoundedRectangle(cornerRadius: MobileTheme.Radius.cardOuter, style: .continuous))
                    .padding(12)
            } else if asset.mediaKind == .document,
                      (asset.fileName as NSString).pathExtension.lowercased() == "pdf",
                      let localOriginalURL {
                PDFDocumentPreview(url: localOriginalURL)
                    .clipShape(RoundedRectangle(cornerRadius: MobileTheme.Radius.cardOuter, style: .continuous))
                    .padding(12)
            } else if let post = asset.richMetadata?.socialPost {
                socialPostStage(post)
            } else if let repo = asset.richMetadata?.githubRepo {
                githubRepoStage(repo)
            } else {
                ZStack {
                    if let image {
                        ZoomableImageView(
                            image: image,
                            transform: transform,
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
        .task(id: asset.id) {
            if let preview = await store.thumbnails.loadImage(for: asset.id, tier: .preview1400) {
                image = preview
            } else if let grid = await store.thumbnails.loadImage(for: asset.id, tier: .grid520) {
                image = grid
            }
            if asset.mediaKind == .image || asset.mediaKind == .designFile {
                if let orig = await store.thumbnails.loadOriginalImage(for: asset) {
                    image = orig
                }
            } else if asset.mediaKind == .video || (asset.fileName as NSString).pathExtension.lowercased() == "pdf" {
                localOriginalURL = try? await store.engine.originalURL(for: asset.id)
            }
        }
    }

    private func socialPostStage(_ post: SocialPostMetadata) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                if let image {
                    Image(uiImage: image)
                        .resizable()
                        .scaledToFit()
                        .frame(maxWidth: 560)
                        .clipShape(RoundedRectangle(cornerRadius: MobileTheme.Radius.cardOuter, style: .continuous))
                        .frame(maxWidth: .infinity)
                }

                VStack(alignment: .leading, spacing: 10) {
                    HStack {
                        Text(post.platform.displayName)
                            .font(.system(size: 11.5, weight: .semibold))
                            .foregroundStyle(.white)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 3)
                            .background(
                                post.platform == .xiaohongshu ? Color(charkleHex: "#FF2442") : MobileTheme.accent(for: colorScheme),
                                in: Capsule()
                            )
                        Text(post.authorName)
                            .font(.system(size: 14, weight: .semibold))
                        if !post.authorHandle.isEmpty && post.platform != .xiaohongshu {
                            Text(post.authorHandle)
                                .font(.system(size: 12.5))
                                .foregroundStyle(MobileTheme.secondaryInk(for: colorScheme))
                        }
                        Spacer()
                    }

                    if !post.bodyText.isEmpty {
                        Text(post.bodyText)
                            .font(.system(size: 14))
                            .textSelection(.enabled)
                            .fixedSize(horizontal: false, vertical: true)
                    }

                    if let url = URL(string: post.originalURL) {
                        Button {
                            UIApplication.shared.open(url)
                        } label: {
                            Label(post.platform.openActionLabel, systemImage: "arrow.up.right.square")
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

    private func githubRepoStage(_ repo: GitHubRepoMetadata) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                if let image {
                    Image(uiImage: image)
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

// MARK: - Pinch, Double-Tap, Rotation & Mirror Zoomable Image Canvas

private struct ZoomableImageView: View {
    let image: UIImage
    let transform: PreviewTransformState
    let onSingleTap: () -> Void

    @State private var scale: CGFloat = 1.0
    @State private var lastScale: CGFloat = 1.0
    @State private var offset: CGSize = .zero
    @State private var lastOffset: CGSize = .zero

    var body: some View {
        GeometryReader { proxy in
            let fitScale = transform.quarterTurnFitScale(for: image.size, in: proxy.size)
            Image(uiImage: image)
                .resizable()
                .scaledToFit()
                .frame(width: proxy.size.width, height: proxy.size.height)
                .rotationEffect(.degrees(transform.rotationDegrees))
                .scaleEffect(
                    x: transform.flipHorizontal ? -1 : 1,
                    y: transform.flipVertical ? -1 : 1
                )
                .scaleEffect(scale * fitScale)
                .offset(offset)
                .contentShape(Rectangle())
                .gesture(
                    MagnificationGesture()
                        .onChanged { value in
                            scale = max(1.0, min(6.0, lastScale * value))
                        }
                        .onEnded { _ in
                            if scale <= 1.05 {
                                withAnimation(MobileMotion.gestureSpring) {
                                    scale = 1.0
                                    offset = .zero
                                    lastScale = 1.0
                                    lastOffset = .zero
                                }
                            } else {
                                lastScale = scale
                            }
                        }
                )
                .simultaneousGesture(
                    DragGesture()
                        .onChanged { value in
                            guard scale > 1.01 else { return }
                            offset = CGSize(
                                width: lastOffset.width + value.translation.width,
                                height: lastOffset.height + value.translation.height
                            )
                        }
                        .onEnded { _ in
                            guard scale > 1.01 else { return }
                            lastOffset = offset
                        },
                    including: scale > 1.01 ? .all : .subviews
                )
                .onTapGesture(count: 2) {
                    withAnimation(MobileMotion.gestureSpring) {
                        if scale > 1.2 {
                            scale = 1.0
                            lastScale = 1.0
                            offset = .zero
                            lastOffset = .zero
                        } else {
                            scale = 2.4
                            lastScale = 2.4
                        }
                    }
                }
                .onTapGesture(count: 1) {
                    onSingleTap()
                }
        }
    }
}

// MARK: - Full 2-Tab Detail Inspector (Info | Similar Assets)

private struct DetailInspectorPanel: View {
    @Bindable var store: MobileAppStore
    let asset: AssetRecord
    @Binding var selectedTab: AssetDetailView.DetailInspectorTab
    let onSelectAsset: (UUID) -> Void
    let onFilterByColor: (String) -> Void
    let onFilterByTag: (String) -> Void
    let onDismissDetail: () -> Void

    @Environment(\.colorScheme) private var colorScheme
    @State private var titleDraft: String = ""
    @State private var notesDraft: String = ""
    @State private var newTagText: String = ""

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
        .onChange(of: asset.id) { _, _ in syncDrafts() }
    }

    private func syncDrafts() {
        titleDraft = asset.title
        notesDraft = asset.notes
    }

    private var infoTabContent: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                inspectorCard("基本信息") {
                    TextField("标题", text: $titleDraft)
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
                            Button("收件箱") {
                                Task {
                                    await store.patchAssets(
                                        AssetBatchPatch(assetIDs: [asset.id], folderAssignment: .inbox),
                                        successToast: "已移回收件箱"
                                    )
                                }
                            }
                            ForEach(store.flattenedFolders) { node in
                                Button(String(repeating: "  ", count: min(node.depth, 3)) + node.folder.name) {
                                    Task {
                                        await store.patchAssets(
                                            AssetBatchPatch(assetIDs: [asset.id], folderAssignment: .folder(node.folder.id)),
                                            successToast: "已归档到「\(node.folder.name)」"
                                        )
                                    }
                                }
                            }
                        } label: {
                            HStack(spacing: 4) {
                                Text(folderName)
                                    .font(.system(size: 13, weight: .medium))
                                Image(systemName: "chevron.up.chevron.down")
                                    .font(.system(size: 10))
                            }
                            .foregroundStyle(MobileTheme.accent(for: colorScheme))
                        }
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
                        .lineLimit(3...6)
                        .font(.system(size: 13))
                        .padding(10)
                        .background(MobileTheme.inspectorFieldSurface(for: colorScheme), in: RoundedRectangle(cornerRadius: 8, style: .continuous))

                    if notesDraft != asset.notes {
                        Button("保存备注") {
                            Task {
                                await store.patchAssets(
                                    AssetBatchPatch(assetIDs: [asset.id], notes: notesDraft),
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

                if let exif = asset.richMetadata?.photoExif, !exif.isEmpty {
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
                        Task {
                            await store.patchAssets(
                                AssetBatchPatch(assetIDs: [asset.id], isTrashed: !asset.isTrashed),
                                successToast: asset.isTrashed ? "已恢复素材" : "已移入回收站"
                            )
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
        return store.folders.first(where: { $0.id == fid })?.name ?? "文件夹"
    }

    private func saveTitle() {
        let trimmed = titleDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed != asset.title else { return }
        Task {
            await store.patchAssets(AssetBatchPatch(assetIDs: [asset.id], title: trimmed), successToast: "标题已更新")
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

private struct PDFDocumentPreview: UIViewRepresentable {
    let url: URL

    func makeUIView(context: Context) -> PDFView {
        let view = PDFView()
        view.autoScales = true
        view.document = PDFDocument(url: url)
        return view
    }

    func updateUIView(_ uiView: PDFView, context: Context) {
        if uiView.document?.documentURL != url {
            uiView.document = PDFDocument(url: url)
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
