import AppKit
import CharkleCanvas
import CharkleCore
import SwiftUI
import UniformTypeIdentifiers

/// Adaptive Right Inspector cleanly organized into distinct surface cards, switching between:
/// 1. Moodboard Right Rail (Identity, AI Curator, Candidate Swap Pool, Board Palette, Quick Add, Export & Figma Bridge)
/// 2. Multi-Select Batch Inspector (Summary & CTA, Bulk Organize, Offline & Actions)
/// 3. Single Asset Inspector (Preview & Identity, Quick Actions, Colors & Tags, Notes & OCR, Media Specs, Similar Assets)
public struct InspectorView: View {
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    public let coordinator: AppCoordinatorStore
    public let library: LibraryStore
    public let moodboards: MoodboardStore
    public let pinnedAsset: AssetRecord?
    public let isQuickLookHosted: Bool
    public let onCopyHex: (String) -> Void
    public let onFilterByColor: (String) -> Void
    public let onOpenQuickLook: (AssetRecord) -> Void
    public let onCopyBoardImage: () -> Void
    public let onSaveBoardImage: (MoodboardExportFormat) -> Void
    public let onExportFigmaBundle: () -> Void
    public let onOpenFigmaPluginGuide: () -> Void
    public let onRequestCloseQuickLook: (() -> Void)?

    @State private var newTagInput: String = ""
    @State private var batchTagInput: String = ""
    @State private var quickAddQuery: String = ""
    @State private var notesDraft: String = ""
    @State private var titleDraft: String = ""
    @State private var boardTitleDraft: String = ""
    @State private var boardSubtitleDraft: String = ""
    @State private var boardRefinementDraft: String = ""
    @State private var showBoardAgentTrace: Bool = false
    @State private var pendingPermanentDeleteIDs: [UUID] = []
    @State private var confirmSinglePermanentDelete: Bool = false
    @State private var draggingInspectorSection: InspectorInfoSection? = nil
    @State private var dropTargetInspectorSection: InspectorInfoSection? = nil
    @State private var hoveredInspectorSection: InspectorInfoSection? = nil

    @Namespace private var inspectorTabNamespace

    public init(
        coordinator: AppCoordinatorStore,
        library: LibraryStore,
        moodboards: MoodboardStore,
        pinnedAsset: AssetRecord? = nil,
        isQuickLookHosted: Bool = false,
        onCopyHex: @escaping (String) -> Void,
        onFilterByColor: @escaping (String) -> Void,
        onOpenQuickLook: @escaping (AssetRecord) -> Void,
        onCopyBoardImage: @escaping () -> Void = {},
        onSaveBoardImage: @escaping (MoodboardExportFormat) -> Void = { _ in },
        onExportFigmaBundle: @escaping () -> Void = {},
        onOpenFigmaPluginGuide: @escaping () -> Void = {},
        onRequestCloseQuickLook: (() -> Void)? = nil
    ) {
        self.coordinator = coordinator
        self.library = library
        self.moodboards = moodboards
        self.pinnedAsset = pinnedAsset
        self.isQuickLookHosted = isQuickLookHosted
        self.onCopyHex = onCopyHex
        self.onFilterByColor = onFilterByColor
        self.onOpenQuickLook = onOpenQuickLook
        self.onCopyBoardImage = onCopyBoardImage
        self.onSaveBoardImage = onSaveBoardImage
        self.onExportFigmaBundle = onExportFigmaBundle
        self.onOpenFigmaPluginGuide = onOpenFigmaPluginGuide
        self.onRequestCloseQuickLook = onRequestCloseQuickLook
    }

    public var body: some View {
        ZStack(alignment: .top) {
            CharkleTheme.inspectorBackground(for: colorScheme)
                .ignoresSafeArea()

            // Subtle low-saturation ambient tint ONLY for Single Asset Inspector
            let ambientAsset: AssetRecord? = pinnedAsset ?? (!coordinator.isViewingMoodboard ? library.primarySelectedAsset : nil)
            if let asset = ambientAsset {
                LinearGradient(
                    colors: [
                        CharkleTheme.ambientTint(from: asset.dominantColors.first?.hex, scheme: colorScheme),
                        .clear
                    ],
                    startPoint: .top,
                    endPoint: .center
                )
                .frame(height: 200)
                .allowsHitTesting(false)
            }

            if let pinnedAsset {
                singleAssetInspector(pinnedAsset)
            } else if coordinator.isViewingMoodboard, let board = moodboards.activeBoard {
                moodboardRightRail(board)
            } else if library.selectedAssetIDs.count >= 2 {
                multiSelectBatchInspector
            } else if let asset = library.primarySelectedAsset {
                singleAssetInspector(asset)
            } else {
                emptyInspectorPlaceholder
            }
        }
        .frame(width: 300)
        .frame(maxHeight: .infinity)
        .overlay(alignment: .leading) {
            Rectangle()
                .fill(CharkleTheme.hairline(for: colorScheme))
                .frame(width: 1)
                .ignoresSafeArea(.container, edges: .top)
        }
        .alert(
            "彻底删除 \(pendingPermanentDeleteIDs.count) 项素材？",
            isPresented: Binding(
                get: { !pendingPermanentDeleteIDs.isEmpty },
                set: { if !$0 { pendingPermanentDeleteIDs = [] } }
            )
        ) {
            Button("取消", role: .cancel) {
                pendingPermanentDeleteIDs = []
            }
            Button("彻底删除", role: .destructive) {
                let ids = pendingPermanentDeleteIDs
                pendingPermanentDeleteIDs = []
                if let qlID = coordinator.quickLookAssetID, ids.contains(qlID) {
                    onRequestCloseQuickLook?()
                    coordinator.closeQuickLook()
                }
                Task {
                    await library.permanentlyDeleteAssets(ids)
                    coordinator.showToast("已彻底删除 \(ids.count) 项素材", icon: "trash.slash")
                }
            }
        } message: {
            Text("彻底删除后将无法从废纸篓恢复。")
        }
    }

    // MARK: - 1. Single Asset Inspector (Top Info | Similar Tab Switcher)

    private func singleAssetInspector(_ asset: AssetRecord) -> some View {
        VStack(spacing: 0) {
            // Top Segmented Switcher (Info | Similar)
            HStack(spacing: 2) {
                ForEach(InspectorDetailTab.allCases, id: \.self) { tab in
                    let active = coordinator.selectedInspectorTab == tab
                    Button {
                        withAnimation(CharkleMotion.accessible(CharkleMotion.settleStrong, reduced: reduceMotion)) {
                            coordinator.selectedInspectorTab = tab
                        }
                    } label: {
                        HStack(spacing: 5) {
                            Text(tab.rawValue)
                                .font(.system(size: 12, weight: active ? .semibold : .medium))
                            if tab == .similar && !library.similarAssets.isEmpty {
                                Text("\(library.similarAssets.count)")
                                    .font(.system(size: 10, weight: .semibold, design: .rounded))
                                    .monospacedDigit()
                                    .foregroundStyle(active ? Color.accentColor : .secondary)
                            }
                        }
                        .foregroundStyle(active ? Color.primary : Color.secondary)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 6)
                        .background {
                            if active {
                                RoundedRectangle(cornerRadius: 8, style: .continuous)
                                    .fill(CharkleTheme.surfaceElevated(for: colorScheme))
                                    .shadow(color: .black.opacity(colorScheme == .dark ? 0.3 : 0.08), radius: 2, y: 1)
                                    .matchedGeometryEffect(id: "inspector-top-tab-pill", in: inspectorTabNamespace)
                            }
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(2)
            .background(Color.primary.opacity(colorScheme == .dark ? 0.08 : 0.06), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            .padding(.horizontal, 12)
            .padding(.top, 10)
            .padding(.bottom, 8)
            .background {
                if !isQuickLookHosted {
                    CharkleWindowDragArea()
                }
            }

            if coordinator.selectedInspectorTab == .similar {
                singleAssetSimilarTab(asset)
            } else {
                singleAssetInfoScroll(asset)
            }
        }
        .onAppear {
            titleDraft = asset.title
            notesDraft = asset.notes
            library.refreshInspectorContext(for: asset.id)
        }
        .onChange(of: asset.id) { _, newID in
            titleDraft = asset.title
            notesDraft = asset.notes
            library.refreshInspectorContext(for: newID)
        }
    }

    private func singleAssetSimilarTab(_ asset: AssetRecord) -> some View {
        ScrollView(.vertical) {
            VStack(alignment: .leading, spacing: 10) {
                Text("与「\(asset.title)」相似的素材")
                    .font(.system(size: 11.5, weight: .medium))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)

                if library.isLoadingSimilarAssets && library.similarAssets.isEmpty {
                    CharkleSimilarGridSkeleton()
                } else if library.similarAssets.isEmpty {
                    VStack(spacing: 10) {
                        CharkleEmptyStateVignette(.noFilterResults, compact: true)
                        Text("暂无视觉或色彩相近的素材")
                            .font(.system(size: 12, weight: .medium))
                            .foregroundStyle(.secondary)
                        Text("导入更多素材或等待本地视觉特征索引完成后，这里会自动呈现同风格相似项目。")
                            .font(.system(size: 11))
                            .foregroundStyle(.tertiary)
                            .multilineTextAlignment(.center)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 36)
                    .padding(.horizontal, 16)
                } else {
                    LazyVGrid(
                        columns: [GridItem(.flexible(), spacing: 8), GridItem(.flexible(), spacing: 8)],
                        spacing: 8
                    ) {
                        ForEach(library.similarAssets) { scored in
                            let ratio = max(0.68, min(1.5, CGFloat(scored.asset.aspectRatio)))
                            AssetThumbnailSurface(
                                asset: scored.asset,
                                loader: library.thumbnailLoader,
                                tier: .grid520,
                                cornerRadius: CharkleTheme.Radius.settingsInner
                            )
                            .frame(height: (132 / ratio).rounded())
                            .overlay(
                                RoundedRectangle(cornerRadius: CharkleTheme.Radius.settingsInner, style: .continuous)
                                    .strokeBorder(CharkleTheme.hairline(for: colorScheme), lineWidth: 0.6)
                            )
                            .contentShape(RoundedRectangle(cornerRadius: CharkleTheme.Radius.settingsInner, style: .continuous))
                            .onTapGesture(count: 2) {
                                library.selectedAssetIDs = [scored.asset.id]
                                onOpenQuickLook(scored.asset)
                            }
                            .onTapGesture {
                                library.selectedAssetIDs = [scored.asset.id]
                                if isQuickLookHosted {
                                    onOpenQuickLook(scored.asset)
                                }
                            }
                            .onDrag {
                                NSItemProvider(object: CharkleDragIdentifiers.encode(assetIDs: [scored.asset.id]) as NSString)
                            }
                            .help(scored.matchReasons.isEmpty ? scored.asset.title : "\(scored.asset.title) · \(scored.matchReasons.joined(separator: " / "))")
                        }
                    }
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .charkleCleanScrollbars(hidden: true)
        }
        .scrollIndicators(.hidden)
    }

    private func visibleInfoSections(
        for asset: AssetRecord,
        resolvedMeta: ExtractedImageMetadata
    ) -> [InspectorInfoSection] {
        coordinator.inspectorInfoSectionOrder.filter { section in
            switch section {
            case .previewIdentity, .quickActions, .colorsAndTags, .notesAndOCR, .mediaSpecs:
                return true
            case .aiGeneration:
                return resolvedMeta.aiGeneration?.isEmpty == false
            case .photoExif:
                return resolvedMeta.photoExif?.hasMeaningfulCameraExif == true
            case .githubRepo:
                return asset.richMetadata?.githubRepo != nil
            case .socialMediaExtract:
                return !(asset.richMetadata?.socialPost?.effectiveAttachments.isEmpty ?? true)
            }
        }
    }

    private func singleAssetInfoScroll(_ asset: AssetRecord) -> some View {
        let resolvedMeta = library.resolvedImageMetadata(for: asset)
        let visibleSections = visibleInfoSections(for: asset, resolvedMeta: resolvedMeta)

        return ScrollView(.vertical) {
            let activeAnchorSection = dropTargetInspectorSection ?? draggingInspectorSection
            let activeAnchorIndex = activeAnchorSection.flatMap { visibleSections.firstIndex(of: $0) }

            VStack(alignment: .leading, spacing: 10) {
                ForEach(Array(visibleSections.enumerated()), id: \.element.id) { index, section in
                    let isDragged = draggingInspectorSection == section
                    let rippleMetrics: (offset: CGFloat, delay: Double) = {
                        guard draggingInspectorSection != nil,
                              !isDragged,
                              !reduceMotion,
                              let anchorIdx = activeAnchorIndex,
                              index != anchorIdx else {
                            return (0, 0)
                        }
                        let dist = abs(index - anchorIdx) - 1
                        let direction: CGFloat = index < anchorIdx ? -1 : 1
                        return (
                            direction * CharkleMotion.rippleOffset(distance: dist, amplitude: 5),
                            CharkleMotion.rippleDelay(distance: dist)
                        )
                    }()

                    singleAssetSectionCard(
                        section,
                        for: asset,
                        resolvedMeta: resolvedMeta,
                        visibleSections: visibleSections
                    )
                        .opacity(isDragged ? 0.36 : 1.0)
                        .offset(y: rippleMetrics.offset)
                        .animation(
                            CharkleMotion.accessible(CharkleMotion.uiSpring, reduced: reduceMotion)
                                .delay(rippleMetrics.delay),
                            value: activeAnchorSection
                        )
                        .overlay(alignment: .top) {
                            if isDragged {
                                HStack(spacing: 0) {
                                    Circle()
                                        .fill(Color.accentColor)
                                        .frame(width: 5, height: 5)
                                    Rectangle()
                                        .fill(Color.accentColor)
                                        .frame(height: 2)
                                    Circle()
                                        .fill(Color.accentColor)
                                        .frame(width: 5, height: 5)
                                }
                                .padding(.horizontal, 6)
                                .offset(y: -6)
                                .allowsHitTesting(false)
                                .transition(.opacity)
                            }
                        }
                        .overlay {
                            if isDragged {
                                RoundedRectangle(cornerRadius: 12, style: .continuous)
                                    .strokeBorder(
                                        Color.accentColor.opacity(0.50),
                                        style: StrokeStyle(lineWidth: 1.25, dash: [5, 4])
                                    )
                                    .allowsHitTesting(false)
                            }
                        }
                        .onHover { hovering in
                            if hovering {
                                hoveredInspectorSection = section
                            } else if hoveredInspectorSection == section {
                                hoveredInspectorSection = nil
                            }
                            if draggingInspectorSection != nil && NSEvent.pressedMouseButtons == 0 {
                                draggingInspectorSection = nil
                                dropTargetInspectorSection = nil
                            }
                        }
                        .onDrop(
                            of: [.plainText],
                            delegate: InspectorSectionDropDelegate(
                                targetSection: section,
                                draggingSection: $draggingInspectorSection,
                                dropTargetSection: $dropTargetInspectorSection,
                                reduceMotion: reduceMotion,
                                onMove: { dragged, target in
                                    coordinator.moveInspectorSection(dragged, toTarget: target)
                                }
                            )
                        )
                }

                if coordinator.isInspectorSectionOrderCustomized {
                    Button {
                        withAnimation(CharkleMotion.accessible(CharkleMotion.moveOnScreen, reduced: reduceMotion)) {
                            coordinator.resetInspectorSectionOrder()
                        }
                        coordinator.showToast("已恢复信息栏默认排序", icon: "arrow.counterclockwise")
                    } label: {
                        HStack(spacing: 4) {
                            Image(systemName: "arrow.counterclockwise")
                                .font(.system(size: 10, weight: .medium))
                            Text("恢复信息栏默认排序")
                                .font(.system(size: 10.5, weight: .medium))
                        }
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 5)
                        .background(Color.primary.opacity(0.04), in: Capsule(style: .continuous))
                    }
                    .buttonStyle(CharkleTactileButtonStyle())
                    .frame(maxWidth: .infinity)
                    .padding(.top, 2)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .animation(CharkleMotion.accessible(CharkleMotion.moveOnScreen, reduced: reduceMotion), value: coordinator.inspectorInfoSectionOrder)
            .charkleCleanScrollbars(hidden: true)
        }
        .scrollIndicators(.hidden)
        .task(id: asset.id) {
            await library.hydrateImageMetadataIfNeeded(for: asset.id)
        }
    }

    @ViewBuilder
    private func singleAssetSectionCard(
        _ section: InspectorInfoSection,
        for asset: AssetRecord,
        resolvedMeta: ExtractedImageMetadata,
        visibleSections: [InspectorInfoSection]
    ) -> some View {
        switch section {
        case .previewIdentity:
            singleAssetPreviewIdentityCard(asset, visibleSections: visibleSections)
        case .quickActions:
            singleAssetQuickActionsCard(asset, visibleSections: visibleSections)
        case .colorsAndTags:
            singleAssetColorsAndTagsCard(asset, visibleSections: visibleSections)
        case .notesAndOCR:
            singleAssetNotesAndOCRCard(asset, visibleSections: visibleSections)
        case .aiGeneration:
            if let aiGen = resolvedMeta.aiGeneration, !aiGen.isEmpty {
                aiGenerationInspectorCard(aiGen, visibleSections: visibleSections)
            }
        case .photoExif:
            if let exif = resolvedMeta.photoExif, exif.hasMeaningfulCameraExif {
                photoExifInspectorCard(exif, visibleSections: visibleSections)
            }
        case .mediaSpecs:
            singleAssetMediaSpecsCard(asset, resolvedExif: resolvedMeta.photoExif, visibleSections: visibleSections)
        case .githubRepo:
            if let repo = asset.richMetadata?.githubRepo {
                singleAssetGitHubRepoCard(asset, repo: repo, visibleSections: visibleSections)
            }
        case .socialMediaExtract:
            if let post = asset.richMetadata?.socialPost, !post.effectiveAttachments.isEmpty {
                singleAssetSocialExtractCard(asset, post: post, visibleSections: visibleSections)
            }
        }
    }

    private func singleAssetPreviewIdentityCard(
        _ asset: AssetRecord,
        visibleSections: [InspectorInfoSection]
    ) -> some View {
        inspectorSectionCard(
            "素材预览",
            systemImage: "photo",
            reorderSection: .previewIdentity,
            visibleSections: visibleSections
        ) {
            VStack(alignment: .leading, spacing: 10) {
                let naturalRatio = max(0.35, min(3.2, CGFloat(asset.aspectRatio)))
                let previewContentWidth: CGFloat = 252
                let fittedHeight = min(280, max(108, (previewContentWidth / naturalRatio).rounded()))
                let fittedWidth = min(previewContentWidth, (fittedHeight * naturalRatio).rounded())

                ZStack {
                    AssetThumbnailSurface(
                        asset: asset,
                        loader: library.thumbnailLoader,
                        tier: .preview1400,
                        cornerRadius: 8,
                        contentMode: .fit
                    )
                    .frame(width: fittedWidth, height: fittedHeight)
                    .overlay(
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .strokeBorder(CharkleTheme.hairline(for: colorScheme), lineWidth: 0.75)
                    )
                }
                .frame(maxWidth: .infinity)
                .contentShape(Rectangle())
                .onTapGesture {
                    if !isQuickLookHosted {
                        onOpenQuickLook(asset)
                    }
                }
                .help(isQuickLookHosted ? asset.title : (asset.isExternalWebLink ? "点击在默认浏览器中打开" : "点击打开 Quick Look 全屏预览"))

                inspectorInnerDivider

                VStack(alignment: .leading, spacing: 8) {
                    TextField("素材标题", text: $titleDraft)
                        .textFieldStyle(.plain)
                        .font(.system(size: 13.5, weight: .semibold))
                        .onSubmit { commitSingleAssetTitle(asset) }

                    HStack(spacing: 8) {
                        HStack(spacing: 3) {
                            ForEach(1...5, id: \.self) { star in
                                Button {
                                    let target = asset.rating == star ? 0 : star
                                    Task { await library.setRating(target, for: [asset.id]) }
                                } label: {
                                    Image(systemName: star <= asset.rating ? "star.fill" : "star")
                                        .font(.system(size: 12))
                                        .foregroundStyle(star <= asset.rating ? Color(charkleHex: "#E5B243") : .secondary.opacity(0.42))
                                        .scaleEffect(star == asset.rating && !reduceMotion ? 1.08 : 1.0)
                                        .animation(CharkleMotion.accessible(CharkleMotion.microOvershoot, reduced: reduceMotion), value: asset.rating)
                                }
                                .buttonStyle(CharkleTactileButtonStyle())
                            }
                        }

                        Spacer()

                        if !asset.isTrashed {
                            Button {
                                let nextPinned = !asset.pinnedOffline
                                Task {
                                    await library.togglePinOffline(ids: [asset.id], pinned: nextPinned)
                                    coordinator.showToast(
                                        nextPinned ? "已设为始终保留在本地" : "已取消始终保留，将按需管理空间",
                                        icon: nextPinned ? "arrow.down.circle.fill" : "icloud"
                                    )
                                }
                            } label: {
                                HStack(spacing: 4) {
                                    Image(systemName: asset.pinnedOffline ? "arrow.down.circle.fill" : "arrow.down.circle")
                                        .font(.system(size: 10.5))
                                    Text(asset.pinnedOffline ? "已保留本地" : "保留在本地")
                                        .font(.system(size: 10.5, weight: .medium))
                                }
                                .foregroundStyle(asset.pinnedOffline ? Color.accentColor : .secondary)
                                .padding(.horizontal, 8)
                                .padding(.vertical, 4)
                                .background(
                                    asset.pinnedOffline ? Color.accentColor.opacity(0.12) : CharkleTheme.inspectorFieldSurface(for: colorScheme),
                                    in: Capsule(style: .continuous)
                                )
                                .overlay(
                                    Capsule(style: .continuous)
                                        .strokeBorder(
                                            asset.pinnedOffline ? Color.accentColor.opacity(0.25) : CharkleTheme.hairline(for: colorScheme),
                                            lineWidth: 0.75
                                        )
                                )
                            }
                            .buttonStyle(CharkleTactileButtonStyle())
                            .help(asset.pinnedOffline ? "已始终保留在本机，离线可用；点击取消" : "始终将原文件保留在本机，不会被缓存自动清理")
                        }
                    }
                }
            }
        }
    }

    private func singleAssetQuickActionsCard(
        _ asset: AssetRecord,
        visibleSections: [InspectorInfoSection]
    ) -> some View {
        inspectorSectionCard(
            asset.isTrashed ? "废纸篓操作" : "快捷操作",
            systemImage: asset.isTrashed ? "trash" : "bolt",
            reorderSection: .quickActions,
            visibleSections: visibleSections
        ) {
                    if asset.isTrashed {
                        HStack(spacing: 8) {
                            Button {
                                Task {
                                    await library.restoreAssets([asset.id])
                                    coordinator.showToast("已放回原处", icon: "arrow.uturn.backward")
                                }
                            } label: {
                                Label("放回原处", systemImage: "arrow.uturn.backward")
                                    .font(.system(size: 11.5, weight: .semibold))
                                    .foregroundStyle(.white)
                                    .frame(maxWidth: .infinity)
                                    .padding(.vertical, 7)
                                    .background(Color.accentColor, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                            }
                            .buttonStyle(CharkleTactileButtonStyle())

                            Button(role: .destructive) {
                                confirmSinglePermanentDelete = true
                            } label: {
                                Label("彻底删除", systemImage: "trash.slash")
                                    .font(.system(size: 11.5, weight: .medium))
                                    .foregroundStyle(.red)
                                    .frame(maxWidth: .infinity)
                                    .padding(.vertical, 7)
                                    .background(Color.red.opacity(0.10), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                            }
                            .buttonStyle(CharkleTactileButtonStyle())
                            .charklePopconfirm(
                                isPresented: $confirmSinglePermanentDelete,
                                title: "彻底删除此素材？",
                                message: "彻底删除后将无法从废纸篓恢复。",
                                confirmTitle: "彻底删除",
                                arrowEdge: .bottom
                            ) {
                                let id = asset.id
                                if coordinator.quickLookAssetID == id {
                                    onRequestCloseQuickLook?()
                                    coordinator.closeQuickLook()
                                }
                                Task {
                                    await library.permanentlyDeleteAssets([id])
                                    coordinator.showToast("已彻底删除素材", icon: "trash.slash")
                                }
                            }
                        }
                    } else {
                        VStack(spacing: 8) {
                            HStack(spacing: 8) {
                                Menu {
                                    ForEach(moodboards.boards) { board in
                                        Button(board.title) {
                                            Task {
                                                await moodboards.addAssetsToSpecificBoard(boardID: board.id, assets: [asset])
                                                coordinator.showToast("已加入情绪板「\(board.title)」", icon: "rectangle.3.group")
                                            }
                                        }
                                    }
                                    Divider()
                                    Button("以此图快速生成新情绪板…") {
                                        library.selectedAssetIDs = [asset.id]
                                        if isQuickLookHosted {
                                            onRequestCloseQuickLook?()
                                        }
                                        coordinator.presentMoodboardGenerator(entry: .seedAssets)
                                    }
                                } label: {
                                    HStack(spacing: 5) {
                                        CharkleIcon("sparkle-board", style: .duotone, size: 16)
                                        Text("加入情绪板")
                                            .font(.system(size: 11.5, weight: .medium))
                                            .lineLimit(1)
                                    }
                                    .frame(maxWidth: .infinity, minHeight: 28)
                                    .padding(.horizontal, 6)
                                    .background(CharkleTheme.inspectorFieldSurface(for: colorScheme), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                                    .overlay(
                                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                                            .strokeBorder(CharkleTheme.hairline(for: colorScheme), lineWidth: 0.75)
                                    )
                                }
                                .menuStyle(.borderlessButton)

                                Menu {
                                    CharkleHierarchicalFolderMenuContent(
                                        folders: library.folders,
                                        includeInbox: true,
                                        selectedFolderID: asset.folderID,
                                        highlightSelection: true,
                                        parentSelfPrefix: "放入"
                                    ) { folderID in
                                        Task { await library.moveAssets([asset.id], toFolderID: folderID) }
                                    }
                                } label: {
                                    HStack(spacing: 4) {
                                        Image(systemName: "folder")
                                            .font(.system(size: 11))
                                        Text(folderName(for: asset.folderID))
                                            .font(.system(size: 11.5, weight: .medium))
                                            .lineLimit(1)
                                    }
                                    .frame(maxWidth: .infinity, minHeight: 28)
                                    .padding(.horizontal, 6)
                                    .background(CharkleTheme.inspectorFieldSurface(for: colorScheme), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                                    .overlay(
                                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                                            .strokeBorder(CharkleTheme.hairline(for: colorScheme), lineWidth: 0.75)
                                    )
                                }
                                .menuStyle(.borderlessButton)
                                .help(asset.folderID.map { "当前所在：\(library.folderDisplayPath(for: $0))" } ?? "当前所在：收件箱")
                            }

                            HStack(spacing: 6) {
                                Button {
                                    Task {
                                        let ok = await library.revealInFinder(assetID: asset.id)
                                        if !ok {
                                            coordinator.showToast("无法定位本地文件", icon: "exclamationmark.triangle", tone: .warning)
                                        }
                                    }
                                } label: {
                                    Label("在访达中显示", systemImage: "folder")
                                        .font(.system(size: 11, weight: .medium))
                                        .frame(maxWidth: .infinity)
                                        .padding(.vertical, 5.5)
                                        .background(CharkleTheme.inspectorFieldSurface(for: colorScheme), in: RoundedRectangle(cornerRadius: CharkleTheme.Radius.chip, style: .continuous))
                                        .overlay(
                                            RoundedRectangle(cornerRadius: CharkleTheme.Radius.chip, style: .continuous)
                                                .strokeBorder(CharkleTheme.hairline(for: colorScheme), lineWidth: 0.6)
                                        )
                                }
                                .buttonStyle(CharkleTactileButtonStyle())

                                Button {
                                    Task {
                                        _ = await library.copyAssetsToPasteboard([asset.id])
                                        coordinator.showToast("已拷贝到剪贴板", icon: "doc.on.doc")
                                    }
                                } label: {
                                    Label("拷贝", systemImage: "doc.on.doc")
                                        .font(.system(size: 11, weight: .medium))
                                        .padding(.horizontal, 9)
                                        .padding(.vertical, 5.5)
                                        .background(CharkleTheme.inspectorFieldSurface(for: colorScheme), in: RoundedRectangle(cornerRadius: CharkleTheme.Radius.chip, style: .continuous))
                                        .overlay(
                                            RoundedRectangle(cornerRadius: CharkleTheme.Radius.chip, style: .continuous)
                                                .strokeBorder(CharkleTheme.hairline(for: colorScheme), lineWidth: 0.6)
                                        )
                                }
                                .buttonStyle(CharkleTactileButtonStyle())

                                Button {
                                    Task {
                                        _ = await library.cutAssets([asset.id])
                                        coordinator.showToast("已剪切，前往目标文件夹按 ⌘V 移动", icon: "scissors")
                                    }
                                } label: {
                                    Label("剪切", systemImage: "scissors")
                                        .font(.system(size: 11, weight: .medium))
                                        .padding(.horizontal, 9)
                                        .padding(.vertical, 5.5)
                                        .background(CharkleTheme.inspectorFieldSurface(for: colorScheme), in: RoundedRectangle(cornerRadius: CharkleTheme.Radius.chip, style: .continuous))
                                        .overlay(
                                            RoundedRectangle(cornerRadius: CharkleTheme.Radius.chip, style: .continuous)
                                                .strokeBorder(CharkleTheme.hairline(for: colorScheme), lineWidth: 0.6)
                                        )
                                }
                                .buttonStyle(CharkleTactileButtonStyle())
                            }
                        }
                    }
                }
    }

    private func singleAssetColorsAndTagsCard(
        _ asset: AssetRecord,
        visibleSections: [InspectorInfoSection]
    ) -> some View {
        inspectorSectionCard(
            "色板与标签",
            systemImage: "swatchpalette",
            reorderSection: .colorsAndTags,
            visibleSections: visibleSections
        ) {
                    VStack(alignment: .leading, spacing: 10) {
                        if !asset.dominantColors.isEmpty || asset.mediaKind == .image || asset.mediaKind == .webBookmark {
                            VStack(alignment: .leading, spacing: 6) {
                                HStack(spacing: 6) {
                                    Text("提取色板")
                                        .font(.system(size: 10.5, weight: .medium))
                                        .foregroundStyle(.secondary)
                                    Spacer()
                                    if asset.mediaKind == .image || asset.mediaKind == .webBookmark || asset.mediaKind == .animatedImage {
                                        Button {
                                            coordinator.showToast("正在定位主体并重新提取色板…", icon: "viewfinder")
                                            Task {
                                                switch await library.extractSubjectPalette(for: asset.id) {
                                                case .success(let res):
                                                    coordinator.showToast(
                                                        "主体色板已更新 · \(res.subjectRegion.summary)",
                                                        icon: "paintpalette.fill"
                                                    )
                                                case .failure(let error):
                                                    coordinator.showToast(error.localizedDescription, icon: "exclamationmark.triangle", tone: .warning)
                                                }
                                            }
                                        } label: {
                                            Label("按主体重提", systemImage: "viewfinder")
                                                .font(.system(size: 10.5, weight: .medium))
                                                .foregroundStyle(Color.accentColor)
                                        }
                                        .buttonStyle(.plain)
                                        .help("先自动锁定画面主体再提取去背景色板（优先使用已配置的视觉定位增强，否则使用本机 Apple Vision）")
                                    }
                                }
                                CharkleFlowLayout(spacing: 6, lineSpacing: 6) {
                                    ForEach(asset.dominantColors.prefix(6), id: \.hex) { swatch in
                                        let hex = swatch.hex.uppercased()
                                        Button {
                                            onCopyHex(hex)
                                        } label: {
                                            HStack(spacing: 5) {
                                                RoundedRectangle(cornerRadius: 4, style: .continuous)
                                                    .fill(Color(charkleHex: hex))
                                                    .frame(width: 13, height: 13)
                                                    .overlay(
                                                        RoundedRectangle(cornerRadius: 4, style: .continuous)
                                                            .strokeBorder(Color.primary.opacity(0.14), lineWidth: 0.5)
                                                    )
                                                Text(hex)
                                                    .font(.system(size: 10, weight: .medium, design: .monospaced))
                                            }
                                            .padding(.horizontal, 7)
                                            .padding(.vertical, 4)
                                            .background(CharkleTheme.inspectorFieldSurface(for: colorScheme), in: RoundedRectangle(cornerRadius: 6, style: .continuous))
                                            .overlay(
                                                RoundedRectangle(cornerRadius: 6, style: .continuous)
                                                    .strokeBorder(CharkleTheme.hairline(for: colorScheme), lineWidth: 0.65)
                                            )
                                        }
                                        .buttonStyle(CharkleTactileButtonStyle())
                                        .contextMenu {
                                            Button("复制 \(hex)") { onCopyHex(hex) }
                                            Button("以此色筛选素材库") { onFilterByColor(hex) }
                                        }
                                        .help("点击复制 HEX，右键按色彩筛选")
                                    }
                                }
                            }

                            inspectorInnerDivider
                        }

                        VStack(alignment: .leading, spacing: 7) {
                            HStack(spacing: 6) {
                                Text("标签")
                                    .font(.system(size: 10.5, weight: .medium))
                                    .foregroundStyle(.secondary)
                                Spacer()
                                if !asset.isTrashed {
                                    let isRetaggingThis = library.enrichingAssetIDs.contains(asset.id)
                                    Button {
                                        runInspectorRetagging(for: [asset.id])
                                    } label: {
                                        HStack(spacing: 3.5) {
                                            if isRetaggingThis {
                                                ProgressView()
                                                    .controlSize(.mini)
                                                Text("打标中…")
                                            } else {
                                                Image(systemName: asset.suggestedTags.isEmpty ? "sparkles" : "arrow.clockwise")
                                                    .font(.system(size: 9.5, weight: .semibold))
                                                Text(asset.suggestedTags.isEmpty ? "AI 打标" : "重新打标")
                                            }
                                        }
                                        .font(.system(size: 10.5, weight: .medium))
                                        .foregroundStyle(isRetaggingThis ? Color.secondary : Color.accentColor)
                                    }
                                    .buttonStyle(.plain)
                                    .disabled(isRetaggingThis)
                                    .help("使用云端 AI 按当前语言格式重新生成建议标签，并优先合并已有标签（保留已采纳标签）")
                                }
                            }

                            if !asset.tags.isEmpty {
                                CharkleFlowLayout(spacing: 6, lineSpacing: 6) {
                                    ForEach(asset.tags, id: \.self) { tag in
                                        HStack(spacing: 4) {
                                            Text("#\(tag)")
                                                .font(.system(size: 11, weight: .medium))
                                            Button {
                                                Task { await library.removeTag(tag, from: [asset.id]) }
                                            } label: {
                                                Image(systemName: "xmark")
                                                    .font(.system(size: 8.5, weight: .bold))
                                                    .foregroundStyle(.secondary)
                                            }
                                            .buttonStyle(.plain)
                                        }
                                        .padding(.horizontal, 8)
                                        .padding(.vertical, 3.5)
                                        .background(CharkleTheme.inspectorFieldSurface(for: colorScheme), in: Capsule(style: .continuous))
                                        .overlay(
                                            Capsule(style: .continuous)
                                                .strokeBorder(CharkleTheme.hairline(for: colorScheme), lineWidth: 0.65)
                                        )
                                    }
                                }
                            }

                            inspectorTextField(placeholder: "添加标签，回车确认…", text: $newTagInput, systemImage: "number") {
                                let val = newTagInput
                                newTagInput = ""
                                Task { await library.addTags([val], to: [asset.id]) }
                            }

                            if !asset.suggestedTags.isEmpty {
                                VStack(alignment: .leading, spacing: 5) {
                                    HStack(spacing: 8) {
                                        Text("AI 建议标签")
                                            .font(.system(size: 10.5, weight: .semibold))
                                            .foregroundStyle(.secondary)
                                        Spacer()
                                        Button("清空") {
                                            Task {
                                                await library.clearSuggestedTags(for: [asset.id])
                                                coordinator.showToast("已清空未采纳的建议标签", icon: "xmark.circle")
                                            }
                                        }
                                        .font(.system(size: 10.5, weight: .medium))
                                        .buttonStyle(.plain)
                                        .foregroundStyle(.secondary)
                                        .help("忽略并清空当前未采纳的建议标签")

                                        Button("全部采纳") {
                                            Task { await library.acceptAllSuggestedTags(for: [asset.id]) }
                                        }
                                        .font(.system(size: 10.5, weight: .medium))
                                        .buttonStyle(.plain)
                                        .foregroundStyle(Color.accentColor)
                                    }
                                    CharkleFlowLayout(spacing: 5, lineSpacing: 5) {
                                        ForEach(asset.suggestedTags, id: \.self) { tag in
                                            Button {
                                                Task { await library.acceptSuggestedTag(tag, for: asset.id) }
                                            } label: {
                                                HStack(spacing: 3) {
                                                    Image(systemName: "plus")
                                                        .font(.system(size: 8.5, weight: .bold))
                                                    Text(tag)
                                                        .font(.system(size: 11, weight: .medium))
                                                }
                                                .foregroundStyle(Color.accentColor)
                                                .padding(.horizontal, 8)
                                                .padding(.vertical, 3.5)
                                                .background(Color.accentColor.opacity(0.10), in: Capsule(style: .continuous))
                                            }
                                            .buttonStyle(CharkleTactileButtonStyle())
                                            .contextMenu {
                                                Button("采纳「\(tag)」") {
                                                    Task { await library.acceptSuggestedTag(tag, for: asset.id) }
                                                }
                                                Button("忽略此建议", role: .destructive) {
                                                    Task { await library.dismissSuggestedTag(tag, for: asset.id) }
                                                }
                                            }
                                            .help("点击采纳标签，右键可忽略此建议")
                                        }
                                    }
                                }
                                .padding(.top, 2)
                            }
                        }
                    }
                }
    }

    private func singleAssetNotesAndOCRCard(
        _ asset: AssetRecord,
        visibleSections: [InspectorInfoSection]
    ) -> some View {
        inspectorSectionCard(
            "备注与识别文本",
            systemImage: "note.text",
            reorderSection: .notesAndOCR,
            visibleSections: visibleSections
        ) {
                    VStack(alignment: .leading, spacing: 8) {
                        ZStack(alignment: .topLeading) {
                            if notesDraft.isEmpty {
                                Text("添加灵感备注、构图笔记或来源说明…")
                                    .font(.system(size: 11.5))
                                    .foregroundStyle(.tertiary)
                                    .padding(.horizontal, 11)
                                    .padding(.vertical, 9)
                                    .allowsHitTesting(false)
                            }
                            TextEditor(text: $notesDraft)
                                .font(.system(size: 11.5))
                                .scrollContentBackground(.hidden)
                                .scrollIndicators(.hidden)
                                .frame(minHeight: 62, maxHeight: 112)
                                .padding(.horizontal, 6)
                                .padding(.vertical, 5)
                        }
                        .background(CharkleTheme.inspectorFieldSurface(for: colorScheme), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                        .overlay(
                            RoundedRectangle(cornerRadius: 8, style: .continuous)
                                .strokeBorder(CharkleTheme.hairline(for: colorScheme), lineWidth: 0.75)
                        )
                        .onChange(of: notesDraft) { _, newValue in
                            if newValue != asset.notes {
                                Task {
                                    await library.applyPatch(AssetBatchPatch(assetIDs: [asset.id], notes: newValue))
                                }
                            }
                        }

                        if let ocr = asset.ocrText, !ocr.isEmpty {
                            VStack(alignment: .leading, spacing: 4) {
                                Text("OCR 识别文字")
                                    .font(.system(size: 10.5, weight: .semibold))
                                    .foregroundStyle(.secondary)
                                Text(ocr)
                                    .font(.system(size: 11))
                                    .foregroundStyle(.secondary)
                                    .textSelection(.enabled)
                                    .lineLimit(4)
                            }
                            .padding(8)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(CharkleTheme.inspectorFieldSurface(for: colorScheme), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                        }

                        if let aiDesc = asset.aiDescription, !aiDesc.isEmpty {
                            Text(aiDesc)
                                .font(.system(size: 11))
                                .foregroundStyle(.secondary)
                                .padding(8)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .background(CharkleTheme.inspectorFieldSurface(for: colorScheme), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                        }
                    }
                }
    }

    private func singleAssetMediaSpecsCard(
        _ asset: AssetRecord,
        resolvedExif: PhotoExifMetadata?,
        visibleSections: [InspectorInfoSection]
    ) -> some View {
        inspectorSectionCard(
            "媒体信息",
            systemImage: "info.circle",
            reorderSection: .mediaSpecs,
            visibleSections: visibleSections
        ) {
            VStack(spacing: 0) {
                specRow("类型", asset.displayTypeLabel)
                inspectorRowDivider
                specRow("尺寸", "\(asset.pixelWidth) × \(asset.pixelHeight) (\(asset.aspectShape.localizedLabel))")
                inspectorRowDivider
                specRow("大小", ByteCountFormatter.string(fromByteCount: asset.fileSizeBytes, countStyle: .file))
                if let duration = asset.durationSeconds {
                    inspectorRowDivider
                    specRow("时长", CanvasFormatters.durationString(duration))
                }
                if let exif = resolvedExif, !exif.hasMeaningfulCameraExif {
                    if let profile = exif.colorProfile {
                        inspectorRowDivider
                        specRow("色彩空间", profile)
                    }
                    if exif.bitDepth != nil || exif.dpiWidth != nil {
                        let depthDPI = [
                            exif.bitDepth.map { "\($0)-bit" },
                            exif.dpiWidth.map { "\($0) DPI" }
                        ].compactMap { $0 }.joined(separator: " · ")
                        if !depthDPI.isEmpty {
                            inspectorRowDivider
                            specRow("色深 / 分辨率", depthDPI)
                        }
                    }
                }
                inspectorRowDivider
                specRow("原文件状态", asset.isLocalOriginalCached ? "已缓存本地" : "云端按需拉取")
                if let urlStr = asset.sourceURL, let url = URL(string: urlStr) {
                    inspectorRowDivider
                    HStack {
                        Text("来源")
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                        Spacer()
                        Link(asset.sourceDomain ?? url.host ?? "打开链接", destination: url)
                            .font(.system(size: 11, weight: .medium))
                            .lineLimit(1)
                    }
                    .padding(.vertical, 5)

                    if asset.isExternalWebLink {
                        HStack(spacing: 6) {
                            Button {
                                library.markAssetOpened(asset.id)
                                NSWorkspace.shared.open(url)
                            } label: {
                                Label("默认浏览器打开", systemImage: "safari")
                                    .font(.system(size: 11, weight: .semibold))
                                    .frame(maxWidth: .infinity)
                                    .padding(.vertical, 5.5)
                                    .background(Color.accentColor.opacity(0.14), in: RoundedRectangle(cornerRadius: 7, style: .continuous))
                                    .foregroundStyle(Color.accentColor)
                            }
                            .buttonStyle(.plain)

                            Button {
                                coordinator.showToast("正在刷新网页缩略图…", icon: "arrow.clockwise")
                                Task {
                                    if await library.refreshRichAsset(asset.id) != nil {
                                        coordinator.showToast("已刷新网页缩略图", icon: "checkmark.circle.fill", tone: .success)
                                    } else {
                                        coordinator.showToast("网页缩略图刷新失败", icon: "exclamationmark.triangle", tone: .warning)
                                    }
                                }
                            } label: {
                                Image(systemName: "arrow.clockwise")
                                    .font(.system(size: 11, weight: .semibold))
                                    .frame(width: 28, height: 26)
                                    .background(CharkleTheme.inspectorFieldSurface(for: colorScheme), in: RoundedRectangle(cornerRadius: 7, style: .continuous))
                                    .foregroundStyle(.secondary)
                            }
                            .buttonStyle(.plain)
                            .help("重新抓取网页标题与缩略图")
                        }
                        .padding(.top, 4)
                    }
                }
            }
        }
    }

    private func singleAssetGitHubRepoCard(
        _ asset: AssetRecord,
        repo: GitHubRepoMetadata,
        visibleSections: [InspectorInfoSection]
    ) -> some View {
        inspectorSectionCard(
            "GitHub 仓库信息",
            systemImage: "chevron.left.forwardslash.chevron.right",
            reorderSection: .githubRepo,
            visibleSections: visibleSections
        ) {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 10) {
                    Text("★ \(repo.stars)")
                        .font(.system(size: 11.5, weight: .semibold, design: .rounded))
                    Text("⑂ \(repo.forks)")
                        .font(.system(size: 11.5, weight: .medium, design: .rounded))
                        .foregroundStyle(.secondary)
                    if let lang = repo.language, !lang.isEmpty {
                        Text(lang)
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                }
                Button {
                    onOpenQuickLook(asset)
                } label: {
                    Label("在应用内阅读完整 README", systemImage: "doc.richtext")
                        .font(.system(size: 11.5, weight: .semibold))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 6)
                        .background(Color.accentColor.opacity(0.14), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                        .foregroundStyle(Color.accentColor)
                }
                .buttonStyle(.plain)
            }
        }
    }

    private func singleAssetSocialExtractCard(
        _ asset: AssetRecord,
        post: SocialPostMetadata,
        visibleSections: [InspectorInfoSection]
    ) -> some View {
        let attachments = post.effectiveAttachments
        return inspectorSectionCard(
            "推文媒体提取",
            systemImage: "photo.on.rectangle.angled",
            reorderSection: .socialMediaExtract,
            visibleSections: visibleSections
        ) {
            Text("\(attachments.count) 项")
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(.tertiary)
        } content: {
            VStack(alignment: .leading, spacing: 8) {
                Text("可将推文里的图片或视频单独存为素材，并自动保留原推文作者、正文与链接。")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                if attachments.count > 1 {
                    Button {
                        Task {
                            let extracted = await library.extractAllMediaFromSocialPost(postAsset: asset)
                            if !extracted.isEmpty {
                                coordinator.showToast("已全部提取 \(extracted.count) 项推文媒体", icon: "square.and.arrow.down.on.square")
                            } else if let err = library.lastError {
                                coordinator.showToast(err, icon: "exclamationmark.triangle", tone: .warning)
                            }
                        }
                    } label: {
                        HStack(spacing: 6) {
                            Image(systemName: "square.and.arrow.down.on.square")
                                .font(.system(size: 11, weight: .semibold))
                            Text("全部提取为独立素材（\(attachments.count) 项）")
                                .font(.system(size: 11.5, weight: .semibold))
                            Spacer()
                        }
                        .foregroundStyle(.white)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 6.5)
                        .background(Color.accentColor, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                    }
                    .buttonStyle(.plain)
                }
                ForEach(Array(attachments.enumerated()), id: \.offset) { idx, attachment in
                    let isVideoLike = attachment.kind == .video || attachment.kind == .gif
                    Button {
                        Task {
                            if let extracted = await library.extractMediaFromSocialPost(
                                postAsset: asset,
                                attachment: attachment,
                                index: idx
                            ) {
                                coordinator.showToast("已单独提取「\(extracted.title)」并保留推文来源", icon: isVideoLike ? "film" : "photo.badge.plus")
                            } else if let err = library.lastError {
                                coordinator.showToast(err, icon: "exclamationmark.triangle", tone: .warning)
                            }
                        }
                    } label: {
                        HStack(spacing: 6) {
                            Image(systemName: isVideoLike ? "film" : "photo.badge.plus")
                                .font(.system(size: 11))
                            Text("提取第 \(idx + 1) 个\(attachment.kind.localizedLabel)为独立素材")
                                .font(.system(size: 11.5, weight: .medium))
                            Spacer()
                        }
                        .foregroundStyle(Color.accentColor)
                        .padding(.horizontal, 9)
                        .padding(.vertical, 6)
                        .background(Color.accentColor.opacity(0.10), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    // MARK: - AI Generation Prompt & Photo EXIF Inspector Cards

    private func aiGenerationInspectorCard(
        _ aiGen: AIGenerationMetadata,
        visibleSections: [InspectorInfoSection]
    ) -> some View {
        inspectorSectionCard(
            "AI 生图信息",
            systemImage: "sparkles.rectangle.stack",
            reorderSection: .aiGeneration,
            visibleSections: visibleSections
        ) {
            if let generator = aiGen.generator, !generator.isEmpty {
                Text(generator)
                    .font(.system(size: 9.5, weight: .semibold))
                    .foregroundStyle(Color.accentColor)
                    .padding(.horizontal, 6.5)
                    .padding(.vertical, 2)
                    .background(Color.accentColor.opacity(0.11), in: Capsule(style: .continuous))
                    .lineLimit(1)
            }
        } content: {
            VStack(alignment: .leading, spacing: 9) {
                if let prompt = aiGen.prompt, !prompt.isEmpty {
                    VStack(alignment: .leading, spacing: 5) {
                        HStack {
                            Text("正向提示词 (Prompt)")
                                .font(.system(size: 10.5, weight: .semibold))
                                .foregroundStyle(.secondary)
                            Spacer()
                            Button {
                                copyInspectorText(prompt, toast: "已复制正向 Prompt")
                            } label: {
                                Label("复制", systemImage: "doc.on.doc")
                                    .font(.system(size: 10, weight: .medium))
                                    .foregroundStyle(Color.accentColor)
                            }
                            .buttonStyle(.plain)
                        }

                        Text(prompt)
                            .font(.system(size: 11))
                            .foregroundStyle(.primary.opacity(0.90))
                            .lineSpacing(3.5)
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(8)
                            .background(CharkleTheme.inspectorFieldSurface(for: colorScheme), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                    }
                }

                if let neg = aiGen.negativePrompt, !neg.isEmpty {
                    VStack(alignment: .leading, spacing: 5) {
                        HStack {
                            Text("负向提示词 (Negative)")
                                .font(.system(size: 10.5, weight: .semibold))
                                .foregroundStyle(.secondary)
                            Spacer()
                            Button {
                                copyInspectorText(neg, toast: "已复制负向 Prompt")
                            } label: {
                                Label("复制", systemImage: "doc.on.doc")
                                    .font(.system(size: 10, weight: .medium))
                                    .foregroundStyle(.secondary)
                            }
                            .buttonStyle(.plain)
                        }

                        Text(neg)
                            .font(.system(size: 10.5))
                            .foregroundStyle(.secondary)
                            .lineSpacing(3)
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(8)
                            .background(CharkleTheme.inspectorFieldSurface(for: colorScheme), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                    }
                }

                VStack(spacing: 0) {
                    if let model = aiGen.modelName, !model.isEmpty {
                        let modelLabel = aiGen.modelHash.map { "\(model) (\($0))" } ?? model
                        specRow("模型", modelLabel)
                    }
                    if let sampler = aiGen.sampler, !sampler.isEmpty {
                        if aiGen.modelName != nil { inspectorRowDivider }
                        let samplerLabel = aiGen.scheduler.map { "\(sampler) / \($0)" } ?? sampler
                        specRow("采样器", samplerLabel)
                    }
                    if aiGen.steps != nil || aiGen.cfgScale != nil {
                        inspectorRowDivider
                        let parts = [
                            aiGen.steps.map { "\($0) 步" },
                            aiGen.cfgScale.map { String(format: "CFG %.1f", $0).replacingOccurrences(of: ".0", with: "") }
                        ].compactMap { $0 }.joined(separator: " · ")
                        specRow("步数 / CFG", parts)
                    }
                    if let seed = aiGen.seed, !seed.isEmpty {
                        inspectorRowDivider
                        HStack {
                            Text("随机种子")
                                .font(.system(size: 11))
                                .foregroundStyle(.secondary)
                            Spacer()
                            Button {
                                copyInspectorText(seed, toast: "已复制 Seed：\(seed)")
                            } label: {
                                HStack(spacing: 4) {
                                    Text(seed)
                                        .font(.system(size: 11, weight: .medium, design: .monospaced))
                                        .monospacedDigit()
                                    Image(systemName: "doc.on.doc")
                                        .font(.system(size: 9.5))
                                        .foregroundStyle(.tertiary)
                                }
                            }
                            .buttonStyle(.plain)
                            .help("点击复制 Seed")
                        }
                        .padding(.vertical, 5)
                    }
                    if let sizeText = aiGen.sizeText, !sizeText.isEmpty {
                        inspectorRowDivider
                        specRow("生成尺寸", sizeText)
                    }
                    if let clip = aiGen.clipSkip {
                        inspectorRowDivider
                        specRow("Clip Skip", "\(clip)")
                    }
                }

                if !aiGen.loras.isEmpty {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("LoRA")
                            .font(.system(size: 10.5, weight: .medium))
                            .foregroundStyle(.secondary)
                        CharkleFlowLayout(spacing: 5, lineSpacing: 5) {
                            ForEach(aiGen.loras, id: \.self) { lora in
                                Text(lora)
                                    .font(.system(size: 10.5, weight: .medium, design: .monospaced))
                                    .foregroundStyle(.primary.opacity(0.85))
                                    .padding(.horizontal, 7)
                                    .padding(.vertical, 3)
                                    .background(Color.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 6, style: .continuous))
                            }
                        }
                    }
                }

                if let raw = aiGen.rawParameters, !raw.isEmpty {
                    Button {
                        copyInspectorText(raw, toast: "已复制完整生图参数")
                    } label: {
                        Label("复制完整生图参数", systemImage: "square.on.square")
                            .font(.system(size: 11, weight: .medium))
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 5.5)
                            .background(CharkleTheme.inspectorFieldSurface(for: colorScheme), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                            .overlay(
                                RoundedRectangle(cornerRadius: 8, style: .continuous)
                                    .strokeBorder(CharkleTheme.hairline(for: colorScheme), lineWidth: 0.65)
                            )
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    private func photoExifInspectorCard(
        _ exif: PhotoExifMetadata,
        visibleSections: [InspectorInfoSection]
    ) -> some View {
        inspectorSectionCard(
            "拍摄参数 (EXIF)",
            systemImage: "camera.aperture",
            reorderSection: .photoExif,
            visibleSections: visibleSections
        ) {
            VStack(alignment: .leading, spacing: 8) {
                if let summary = exif.exposureSummary {
                    Text(summary)
                        .font(.system(size: 11.5, weight: .semibold, design: .monospaced))
                        .monospacedDigit()
                        .foregroundStyle(.primary)
                        .frame(maxWidth: .infinity, alignment: .center)
                        .padding(.vertical, 6.5)
                        .padding(.horizontal, 8)
                        .background(CharkleTheme.inspectorFieldSurface(for: colorScheme), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                }

                VStack(spacing: 0) {
                    let rows: [(String, String)] = {
                        var list: [(String, String)] = []
                        if let cam = exif.cameraDisplayName { list.append(("相机", cam)) }
                        if let lens = exif.lensModel { list.append(("镜头", lens)) }
                        if let date = exif.capturedAt { list.append(("拍摄时间", date)) }
                        if let focal = exif.formattedFocalLength { list.append(("焦距", focal)) }
                        if let ap = exif.formattedAperture { list.append(("光圈", ap)) }
                        if let exp = exif.exposureTime { list.append(("快门", exp)) }
                        if let iso = exif.iso { list.append(("ISO", "\(iso)")) }
                        if let ev = exif.exposureBiasEV, abs(ev) > 0.01 {
                            list.append(("曝光补偿", String(format: "%+.1f EV", ev)))
                        }
                        if let metering = exif.meteringMode { list.append(("测光模式", metering)) }
                        if let wb = exif.whiteBalance { list.append(("白平衡", wb)) }
                        if let flash = exif.flashFired { list.append(("闪光灯", flash ? "已闪光" : "未闪光")) }
                        if let profile = exif.colorProfile { list.append(("色彩空间", profile)) }
                        if exif.bitDepth != nil || exif.dpiWidth != nil {
                            let parts = [
                                exif.bitDepth.map { "\($0)-bit" },
                                exif.dpiWidth.map { "\($0) DPI" }
                            ].compactMap { $0 }.joined(separator: " · ")
                            list.append(("色深 / 分辨率", parts))
                        }
                        if let sw = exif.software { list.append(("软件", sw)) }
                        if let artist = exif.artist { list.append(("作者", artist)) }
                        if let copy = exif.copyright { list.append(("版权", copy)) }
                        return list
                    }()

                    ForEach(Array(rows.enumerated()), id: \.offset) { idx, row in
                        if idx > 0 { inspectorRowDivider }
                        specRow(row.0, row.1)
                    }

                    if let lat = exif.latitude, let lon = exif.longitude {
                        if !rows.isEmpty { inspectorRowDivider }
                        let coordText = String(format: "%.5f, %.5f", lat, lon)
                        let mapsURL = URL(string: "https://maps.apple.com/?ll=\(lat),\(lon)")
                        HStack {
                            Text("拍摄位置")
                                .font(.system(size: 11))
                                .foregroundStyle(.secondary)
                            Spacer()
                            if let mapsURL {
                                Link(destination: mapsURL) {
                                    HStack(spacing: 3) {
                                        Image(systemName: "mappin.and.ellipse")
                                            .font(.system(size: 10))
                                        Text(coordText)
                                            .font(.system(size: 10.5, weight: .medium, design: .monospaced))
                                    }
                                }
                                .help("在 Apple 地图中查看拍摄位置")
                            } else {
                                Text(coordText)
                                    .font(.system(size: 10.5, design: .monospaced))
                            }
                        }
                        .padding(.vertical, 5)
                    }
                }
            }
        }
    }

    private func copyInspectorText(_ text: String, toast: String) {
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(text, forType: .string)
        coordinator.showToast(toast, icon: "doc.on.doc")
    }

    // MARK: - 2. Multi-Select Batch Inspector

    private var multiSelectBatchInspector: some View {
        let ids = Array(library.selectedAssetIDs)
        let selectedAssets = library.selectedAssets
        let isTrashSelection = coordinator.selectedDestination == .trash
            || (!selectedAssets.isEmpty && selectedAssets.allSatisfy(\.isTrashed))

        return ScrollView(.vertical) {
            VStack(alignment: .leading, spacing: 10) {
                // Card 1: Selection Overview + Primary Action
                inspectorCard(padding: 12) {
                    VStack(alignment: .leading, spacing: 10) {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("已选中 \(ids.count) 项素材")
                                .font(.system(size: 14.5, weight: .semibold))
                                .monospacedDigit()
                            Text(isTrashSelection ? "这些素材当前位于废纸篓，可恢复到原位置或彻底删除" : "批量归档、打标签或一键进入情绪板排版")
                                .font(.system(size: 11))
                                .foregroundStyle(.secondary)
                        }

                        if isTrashSelection {
                            VStack(spacing: 8) {
                                Button {
                                    Task {
                                        await library.restoreAssets(ids)
                                        coordinator.showToast("已将 \(ids.count) 项放回原处", icon: "arrow.uturn.backward")
                                    }
                                } label: {
                                    Label("全部放回原处", systemImage: "arrow.uturn.backward")
                                        .font(.system(size: 12, weight: .semibold))
                                        .foregroundStyle(.white)
                                        .frame(maxWidth: .infinity, alignment: .leading)
                                        .padding(.horizontal, 10)
                                        .padding(.vertical, 8)
                                        .background(Color.accentColor, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                                }
                                .buttonStyle(CharkleTactileButtonStyle())

                                Button(role: .destructive) {
                                    pendingPermanentDeleteIDs = ids
                                } label: {
                                    Label("彻底删除所选 \(ids.count) 项", systemImage: "trash.slash")
                                        .font(.system(size: 12, weight: .medium))
                                        .foregroundStyle(.red)
                                        .frame(maxWidth: .infinity, alignment: .leading)
                                        .padding(.horizontal, 10)
                                        .padding(.vertical, 8)
                                        .background(Color.red.opacity(0.09), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                                }
                                .buttonStyle(CharkleTactileButtonStyle())
                            }
                        } else {
                            Button {
                                Task {
                                    if let board = await moodboards.createBoardFromSelection(assetIDs: ids, title: "灵感合集 (\(ids.count))") {
                                        coordinator.openMoodboard(board.id)
                                        coordinator.showToast("已用 \(ids.count) 项素材生成情绪板", icon: "sparkles.rectangle.stack")
                                    }
                                }
                            } label: {
                                HStack(spacing: 6) {
                                    CharkleIcon("sparkle-board", style: .duotone, size: 15, color: .white)
                                    Text("从所选生成情绪板")
                                        .font(.system(size: 12, weight: .semibold))
                                }
                                .foregroundStyle(.white)
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 8.5)
                                .background(Color.accentColor, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                            }
                            .buttonStyle(CharkleTactileButtonStyle())
                        }
                    }
                }

                if !isTrashSelection {
                    // Card 2: Bulk Organize
                    inspectorSectionCard("批量整理", systemImage: "tray.full") {
                        VStack(alignment: .leading, spacing: 10) {
                            VStack(alignment: .leading, spacing: 5) {
                                Text("移动到文件夹")
                                    .font(.system(size: 10.5, weight: .medium))
                                    .foregroundStyle(.secondary)
                                Menu {
                                    CharkleHierarchicalFolderMenuContent(
                                        folders: library.folders,
                                        includeInbox: true,
                                        parentSelfPrefix: "放入"
                                    ) { folderID in
                                        Task { await library.moveAssets(ids, toFolderID: folderID) }
                                    }
                                } label: {
                                    HStack {
                                        Image(systemName: "folder")
                                            .font(.system(size: 11))
                                        Text("选择目标文件夹…")
                                        Spacer()
                                        Image(systemName: "chevron.up.chevron.down")
                                            .font(.system(size: 9.5))
                                            .foregroundStyle(.secondary)
                                    }
                                    .font(.system(size: 11.5, weight: .medium))
                                    .padding(.horizontal, 10)
                                    .padding(.vertical, 7)
                                    .background(CharkleTheme.inspectorFieldSurface(for: colorScheme), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                                    .overlay(
                                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                                            .strokeBorder(CharkleTheme.hairline(for: colorScheme), lineWidth: 0.75)
                                    )
                                }
                                .menuStyle(.borderlessButton)
                            }

                            inspectorInnerDivider

                            VStack(alignment: .leading, spacing: 5) {
                                Text("批量添加标签")
                                    .font(.system(size: 10.5, weight: .medium))
                                    .foregroundStyle(.secondary)
                                inspectorTextField(placeholder: "输入标签回车批量添加…", text: $batchTagInput, systemImage: "number") {
                                    let val = batchTagInput
                                    batchTagInput = ""
                                    Task {
                                        await library.addTags([val], to: ids)
                                        coordinator.showToast("已为 \(ids.count) 项添加标签 #\(val)")
                                    }
                                }
                            }

                            VStack(alignment: .leading, spacing: 6) {
                                if library.isEnrichingTags {
                                    HStack(spacing: 8) {
                                        ProgressView().controlSize(.mini)
                                        Text("正在重新打标 (\(library.enrichCompletedCount)/\(max(1, library.enrichTotalCount)))…")
                                            .font(.system(size: 11, weight: .medium))
                                            .foregroundStyle(.secondary)
                                            .monospacedDigit()
                                        Spacer()
                                        Button("停止") {
                                            library.cancelRetagging()
                                        }
                                        .font(.system(size: 10.5, weight: .medium))
                                        .buttonStyle(.plain)
                                        .foregroundStyle(.red)
                                    }
                                    .padding(.horizontal, 10)
                                    .padding(.vertical, 7)
                                    .background(CharkleTheme.inspectorFieldSurface(for: colorScheme), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                                } else {
                                    Button {
                                        runInspectorRetagging(for: ids)
                                    } label: {
                                        HStack(spacing: 5) {
                                            Image(systemName: "sparkles")
                                                .font(.system(size: 11))
                                            Text("AI 批量重新打标（\(ids.count) 项）")
                                                .font(.system(size: 11.5, weight: .medium))
                                            Spacer()
                                        }
                                        .padding(.horizontal, 10)
                                        .padding(.vertical, 7)
                                        .background(CharkleTheme.inspectorFieldSurface(for: colorScheme), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                                        .overlay(
                                            RoundedRectangle(cornerRadius: 8, style: .continuous)
                                                .strokeBorder(CharkleTheme.hairline(for: colorScheme), lineWidth: 0.75)
                                        )
                                    }
                                    .buttonStyle(CharkleTactileButtonStyle())
                                    .help("按当前语言格式重新生成建议标签并优先合并已有标签（保留已采纳标签）")
                                }

                                let assetsWithSuggestions = selectedAssets.filter { !$0.suggestedTags.isEmpty }
                                if !assetsWithSuggestions.isEmpty {
                                    HStack(spacing: 6) {
                                        Button("采纳全部建议（\(assetsWithSuggestions.count) 项）") {
                                            Task {
                                                await library.acceptAllSuggestedTags(for: ids)
                                                coordinator.showToast("已批量采纳 AI 建议标签", icon: "checkmark.circle")
                                            }
                                        }
                                        .font(.system(size: 10.5, weight: .medium))
                                        .buttonStyle(.plain)
                                        .foregroundStyle(Color.accentColor)

                                        Spacer()

                                        Button("清空建议") {
                                            Task {
                                                await library.clearSuggestedTags(for: ids)
                                                coordinator.showToast("已清空所选素材的未采纳建议标签", icon: "xmark.circle")
                                            }
                                        }
                                        .font(.system(size: 10.5, weight: .medium))
                                        .buttonStyle(.plain)
                                        .foregroundStyle(.secondary)
                                    }
                                }
                            }

                            inspectorInnerDivider

                            VStack(alignment: .leading, spacing: 5) {
                                HStack {
                                    Text("批量评分")
                                        .font(.system(size: 10.5, weight: .medium))
                                        .foregroundStyle(.secondary)
                                    Spacer()
                                    Button("清除评分") {
                                        Task { await library.setRating(0, for: ids) }
                                    }
                                    .font(.system(size: 10.5))
                                    .buttonStyle(.plain)
                                    .foregroundStyle(.secondary)
                                }
                                HStack(spacing: 6) {
                                    ForEach(1...5, id: \.self) { star in
                                        Button {
                                            Task { await library.setRating(star, for: ids) }
                                        } label: {
                                            Image(systemName: "star.fill")
                                                .font(.system(size: 14))
                                                .foregroundStyle(Color(charkleHex: "#E5B243"))
                                        }
                                        .buttonStyle(CharkleTactileButtonStyle())
                                    }
                                }
                            }
                        }
                    }

                    // Card 3: Offline & Destructive Actions
                    inspectorSectionCard("本地与操作", systemImage: "slider.horizontal.3") {
                        let allKeptLocally = !selectedAssets.isEmpty && selectedAssets.allSatisfy(\.pinnedOffline)
                        VStack(spacing: 8) {
                            Button {
                                let nextPinned = !allKeptLocally
                                Task {
                                    await library.togglePinOffline(ids: ids, pinned: nextPinned)
                                    coordinator.showToast(
                                        nextPinned ? "已将 \(ids.count) 项设为始终保留在本地" : "已取消 \(ids.count) 项的始终保留",
                                        icon: nextPinned ? "arrow.down.circle.fill" : "icloud"
                                    )
                                }
                            } label: {
                                Label(
                                    allKeptLocally ? "取消全部保留在本地" : "全部始终保留在本地",
                                    systemImage: allKeptLocally ? "icloud" : "arrow.down.circle"
                                )
                                .font(.system(size: 11.5, weight: .medium))
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(.horizontal, 10)
                                .padding(.vertical, 7)
                                .background(CharkleTheme.inspectorFieldSurface(for: colorScheme), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                                .overlay(
                                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                                        .strokeBorder(CharkleTheme.hairline(for: colorScheme), lineWidth: 0.75)
                                )
                            }
                            .buttonStyle(CharkleTactileButtonStyle())

                            Button(role: .destructive) {
                                Task {
                                    await library.trashAssets(ids)
                                    coordinator.showToast(
                                        "已将 \(ids.count) 项移至废纸篓",
                                        icon: "trash",
                                        actionTitle: "撤销",
                                        onAction: {
                                            Task {
                                                await library.restoreAssets(ids)
                                                coordinator.showToast("已放回原处 (\(ids.count) 项)", icon: "arrow.uturn.backward", tone: .success)
                                            }
                                        }
                                    )
                                }
                            } label: {
                                Label("移至废纸篓", systemImage: "trash")
                                    .font(.system(size: 11.5, weight: .medium))
                                    .foregroundStyle(.red)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .padding(.horizontal, 10)
                                    .padding(.vertical, 7)
                                    .background(Color.red.opacity(0.08), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                            }
                            .buttonStyle(CharkleTactileButtonStyle())
                        }
                    }
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 12)
            .charkleCleanScrollbars(hidden: true)
        }
        .scrollIndicators(.hidden)
    }

    // MARK: - 3. Moodboard Right Rail (Uniform Surface Cards)

    private func moodboardRightRail(_ board: MoodboardDocument) -> some View {
        let isActiveNotchBoard = coordinator.activeMoodboardID == board.id
        let quickAddResults = quickAddFilteredAssets(excluding: Set(board.referencedAssetIDs))
        let isSwapping = moodboards.swappingNodeID != nil

        return ScrollView(.vertical) {
            VStack(alignment: .leading, spacing: 10) {
                // Card 1: Board Identity & Status Controls
                inspectorCard(padding: 12) {
                    VStack(alignment: .leading, spacing: 8) {
                        TextField("情绪板名称", text: $boardTitleDraft)
                            .textFieldStyle(.plain)
                            .font(.system(size: 14.5, weight: .semibold))
                            .onSubmit { commitBoardHeader(board) }

                        TextField("补充创作 Brief 或氛围备注…", text: $boardSubtitleDraft)
                            .textFieldStyle(.plain)
                            .font(.system(size: 11.5))
                            .foregroundStyle(.secondary)
                            .onSubmit { commitBoardHeader(board) }

                        inspectorInnerDivider
                            .padding(.vertical, 1)

                        HStack(spacing: 6) {
                            Button {
                                coordinator.activeMoodboardID = board.id
                                coordinator.showToast("已设为刘海活跃情绪板", icon: "checkmark.circle.fill")
                            } label: {
                                HStack(spacing: 4) {
                                    Circle()
                                        .fill(isActiveNotchBoard ? Color.green : Color.secondary.opacity(0.4))
                                        .frame(width: 6, height: 6)
                                    Text(isActiveNotchBoard ? "当前活跃板" : "设为活跃板")
                                        .font(.system(size: 10.5, weight: .medium))
                                }
                                .padding(.horizontal, 8)
                                .padding(.vertical, 4.5)
                                .background(CharkleTheme.inspectorFieldSurface(for: colorScheme), in: Capsule(style: .continuous))
                                .overlay(
                                    Capsule(style: .continuous)
                                        .strokeBorder(CharkleTheme.hairline(for: colorScheme), lineWidth: 0.7)
                                )
                            }
                            .buttonStyle(CharkleTactileButtonStyle())

                            Button {
                                let nextPinned = !board.pinnedOffline
                                Task {
                                    await moodboards.togglePinnedOffline(id: board.id)
                                    coordinator.showToast(
                                        nextPinned ? "整板素材将始终保留在本地" : "已取消整板始终保留在本地",
                                        icon: nextPinned ? "arrow.down.circle.fill" : "icloud"
                                    )
                                }
                            } label: {
                                HStack(spacing: 4) {
                                    Image(systemName: board.pinnedOffline ? "arrow.down.circle.fill" : "arrow.down.circle")
                                        .font(.system(size: 10.5))
                                    Text(board.pinnedOffline ? "已保留本地" : "始终保留本地")
                                        .font(.system(size: 10.5, weight: .medium))
                                }
                                .foregroundStyle(board.pinnedOffline ? Color.accentColor : .primary.opacity(0.85))
                                .padding(.horizontal, 8)
                                .padding(.vertical, 4.5)
                                .background(
                                    board.pinnedOffline ? Color.accentColor.opacity(0.12) : CharkleTheme.inspectorFieldSurface(for: colorScheme),
                                    in: Capsule(style: .continuous)
                                )
                                .overlay(
                                    Capsule(style: .continuous)
                                        .strokeBorder(
                                            board.pinnedOffline ? Color.accentColor.opacity(0.28) : CharkleTheme.hairline(for: colorScheme),
                                            lineWidth: 0.7
                                        )
                                )
                            }
                            .buttonStyle(CharkleTactileButtonStyle())
                            .help(board.pinnedOffline ? "整板素材已始终保留在本机，离线可用" : "始终将此情绪板引用的素材保留在本机")
                        }
                    }
                }

                // Card 2: In-Canvas AI Curator Assistant
                moodboardCuratorCard(board)

                // Card 3: Candidate Swap Pool
                inspectorSectionCard(
                    isSwapping ? "候选替换池" : "同方向候选池",
                    systemImage: isSwapping ? "arrow.triangle.2.circlepath" : "photo.stack",
                    iconColor: isSwapping ? Color.accentColor : nil
                ) {
                    if isSwapping {
                        Button("取消替换") {
                            moodboards.swappingNodeID = nil
                        }
                        .font(.system(size: 10.5, weight: .medium))
                        .foregroundStyle(Color.accentColor)
                        .buttonStyle(.plain)
                    } else if !moodboards.candidatePool.isEmpty {
                        Text("点击或拖入画布 · \(min(24, moodboards.candidatePool.count)) 项")
                            .font(.system(size: 10, weight: .medium))
                            .monospacedDigit()
                            .foregroundStyle(.tertiary)
                    }
                } content: {
                    VStack(alignment: .leading, spacing: 8) {
                        if let swapNodeID = moodboards.swappingNodeID {
                            HStack(spacing: 6) {
                                Image(systemName: "arrow.triangle.2.circlepath")
                                    .font(.system(size: 10.5, weight: .semibold))
                                    .foregroundStyle(Color.accentColor)
                                Text("点击下方任意候选图即可原地替换选中卡片")
                                    .font(.system(size: 10.5, weight: .medium))
                                    .foregroundStyle(.primary.opacity(0.86))
                            }
                            .padding(.horizontal, 8)
                            .padding(.vertical, 6)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(Color.accentColor.opacity(0.11), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                            .overlay(
                                RoundedRectangle(cornerRadius: 8, style: .continuous)
                                    .strokeBorder(Color.accentColor.opacity(0.32), lineWidth: 0.75)
                            )
                            .id(swapNodeID)
                            .transition(CharkleMotion.originTransition(anchor: .top, scale: 0.97, reduced: reduceMotion))
                        }

                        if moodboards.candidatePool.isEmpty {
                            Text("暂无更多候选图，可从下方直接检索素材库添加。")
                                .font(.system(size: 11))
                                .foregroundStyle(.tertiary)
                        } else {
                            LazyVGrid(columns: [GridItem(.flexible(), spacing: 8), GridItem(.flexible(), spacing: 8)], spacing: 8) {
                                ForEach(moodboards.candidatePool.prefix(24)) { candidate in
                                    AssetThumbnailSurface(
                                        asset: candidate.asset,
                                        loader: library.thumbnailLoader,
                                        tier: .grid520,
                                        cornerRadius: 8
                                    )
                                    .frame(maxWidth: .infinity)
                                    .frame(height: 84)
                                    .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                                    .overlay(
                                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                                            .strokeBorder(CharkleTheme.hairline(for: colorScheme), lineWidth: 0.75)
                                    )
                                    .contentShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                                    .onTapGesture {
                                        Task {
                                            if let swapID = moodboards.swappingNodeID {
                                                await moodboards.swapNode(nodeID: swapID, with: candidate.asset)
                                                coordinator.showToast("已原地替换为「\(candidate.asset.title)」", icon: "arrow.triangle.2.circlepath")
                                            } else {
                                                await moodboards.appendAssets([candidate.asset])
                                                coordinator.showToast("已追加到情绪板", icon: "plus.circle.fill")
                                            }
                                        }
                                    }
                                    .onDrag {
                                        NSItemProvider(object: CharkleDragIdentifiers.encode(assetIDs: [candidate.asset.id]) as NSString)
                                    } preview: {
                                        AssetThumbnailSurface(
                                            asset: candidate.asset,
                                            loader: library.thumbnailLoader,
                                            tier: .grid520,
                                            cornerRadius: 8
                                        )
                                        .frame(width: 96, height: 74)
                                        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                                    }
                                    .help(
                                        candidate.matchReasons.isEmpty
                                            ? "\(candidate.asset.title)（点击加入或直接拖入画布）"
                                            : "\(candidate.asset.title) · \(candidate.matchReasons.joined(separator: " / "))（点击加入或直接拖入画布）"
                                    )
                                }
                            }
                        }
                    }
                }

                // Card 4: Board Harmonious Palette Strip
                inspectorSectionCard("全板和谐色板", systemImage: "paintpalette") {
                    Button {
                        Task {
                            await moodboards.syncBoardPalette()
                            coordinator.showToast("已重新提取全板和谐色卡", icon: "paintpalette")
                        }
                    } label: {
                        HStack(spacing: 3) {
                            Image(systemName: "arrow.clockwise")
                                .font(.system(size: 9.5, weight: .semibold))
                            Text("重新提取")
                                .font(.system(size: 10.5, weight: .medium))
                        }
                        .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                    .help("重新分析板内素材并更新和谐色板")
                } content: {
                    if board.extractedPalette.isEmpty {
                        Text("加入素材后将自动提取全板和谐色卡。")
                            .font(.system(size: 11))
                            .foregroundStyle(.tertiary)
                    } else {
                        HStack(spacing: 5) {
                            ForEach(board.extractedPalette.prefix(7), id: \.hex) { swatch in
                                Button {
                                    onCopyHex(swatch.hex.uppercased())
                                } label: {
                                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                                        .fill(Color(charkleHex: swatch.hex))
                                        .frame(height: 30)
                                        .overlay(
                                            RoundedRectangle(cornerRadius: 6, style: .continuous)
                                                .strokeBorder(Color.primary.opacity(0.12), lineWidth: 0.5)
                                        )
                                }
                                .buttonStyle(CharkleTactileButtonStyle())
                                .help("点击复制 \(swatch.hex.uppercased())")
                            }
                        }
                    }
                }

                // Card 5: Quick Add from Library Search
                inspectorSectionCard("从素材库快速拉图", systemImage: "plus.square.on.square") {
                    VStack(alignment: .leading, spacing: 8) {
                        inspectorTextField(placeholder: "搜索标题、标签或域名…", text: $quickAddQuery, systemImage: "magnifyingglass")

                        if !quickAddResults.isEmpty {
                            LazyVGrid(columns: [GridItem(.flexible(), spacing: 6), GridItem(.flexible(), spacing: 6), GridItem(.flexible(), spacing: 6)], spacing: 6) {
                                ForEach(quickAddResults.prefix(9)) { asset in
                                    AssetThumbnailSurface(
                                        asset: asset,
                                        loader: library.thumbnailLoader,
                                        tier: .grid520,
                                        cornerRadius: 6
                                    )
                                    .frame(maxWidth: .infinity)
                                    .frame(height: 56)
                                    .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                                    .overlay(
                                        RoundedRectangle(cornerRadius: 6, style: .continuous)
                                            .strokeBorder(CharkleTheme.hairline(for: colorScheme), lineWidth: 0.5)
                                    )
                                    .contentShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                                    .onTapGesture {
                                        Task {
                                            await moodboards.appendAssets([asset])
                                            coordinator.showToast("已将「\(asset.title)」加入情绪板")
                                        }
                                    }
                                    .onDrag {
                                        NSItemProvider(object: CharkleDragIdentifiers.encode(assetIDs: [asset.id]) as NSString)
                                    } preview: {
                                        AssetThumbnailSurface(
                                            asset: asset,
                                            loader: library.thumbnailLoader,
                                            tier: .grid520,
                                            cornerRadius: 6
                                        )
                                        .frame(width: 84, height: 64)
                                        .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                                    }
                                    .help("点击加入或拖入画布：\(asset.title)")
                                }
                            }
                        } else if !quickAddQuery.isEmpty {
                            Text("未找到匹配的素材")
                                .font(.system(size: 11))
                                .foregroundStyle(.tertiary)
                        }
                    }
                }

                // Card 6: Export & Delivery (including Figma / FigJam Editable Bridge)
                inspectorSectionCard("导出与交付", systemImage: "square.and.arrow.up") {
                    Button {
                        onOpenFigmaPluginGuide()
                    } label: {
                        HStack(spacing: 3) {
                            Image(systemName: "puzzlepiece.extension")
                                .font(.system(size: 9.5, weight: .semibold))
                            Text("插件指南")
                                .font(.system(size: 10.5, weight: .medium))
                        }
                        .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                    .help("查看 Figma / FigJam 本地插件安装说明")
                } content: {
                    VStack(spacing: 7) {
                        Button(action: onExportFigmaBundle) {
                            HStack(spacing: 6) {
                                Image(systemName: "square.stack.3d.up")
                                    .font(.system(size: 12, weight: .semibold))
                                Text("导出到 Figma / FigJam（可编辑图层）")
                                    .font(.system(size: 11.5, weight: .semibold))
                                    .lineLimit(1)
                            }
                            .foregroundStyle(.white)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 8)
                            .background(Color.accentColor, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                        }
                        .buttonStyle(CharkleTactileButtonStyle())
                        .help("导出 .charkleboard 离线迁移包，在 Figma / FigJam 中导入为独立可编辑图片、便签、连线和色卡")

                        Button(action: onCopyBoardImage) {
                            Label("复制 2× 高清图（直接 ⌘V 粘贴）", systemImage: "doc.on.clipboard")
                                .font(.system(size: 11.5, weight: .medium))
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(.horizontal, 10)
                                .padding(.vertical, 7.5)
                                .background(Color.accentColor.opacity(0.11), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                                .foregroundStyle(Color.accentColor)
                        }
                        .buttonStyle(CharkleTactileButtonStyle())

                        HStack(spacing: 6) {
                            Button {
                                onSaveBoardImage(.png)
                            } label: {
                                Text("保存 PNG")
                                    .font(.system(size: 11.5, weight: .medium))
                                    .frame(maxWidth: .infinity)
                                    .padding(.vertical, 6)
                                    .background(CharkleTheme.inspectorFieldSurface(for: colorScheme), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                                    .overlay(
                                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                                            .strokeBorder(CharkleTheme.hairline(for: colorScheme), lineWidth: 0.75)
                                    )
                            }
                            .buttonStyle(CharkleTactileButtonStyle())

                            Button {
                                onSaveBoardImage(.jpeg)
                            } label: {
                                Text("保存 JPG")
                                    .font(.system(size: 11.5, weight: .medium))
                                    .frame(maxWidth: .infinity)
                                    .padding(.vertical, 6)
                                    .background(CharkleTheme.inspectorFieldSurface(for: colorScheme), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                                    .overlay(
                                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                                            .strokeBorder(CharkleTheme.hairline(for: colorScheme), lineWidth: 0.75)
                                    )
                            }
                            .buttonStyle(CharkleTactileButtonStyle())
                        }
                    }
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 12)
            .charkleCleanScrollbars(hidden: true)
            .animation(
                CharkleMotion.enterExit(moodboards.swappingNodeID != nil, reduced: reduceMotion),
                value: moodboards.swappingNodeID != nil
            )
        }
        .scrollIndicators(.hidden)
        .onAppear {
            boardTitleDraft = board.title
            boardSubtitleDraft = board.subtitle
        }
        .onChange(of: board.id) { _, _ in
            boardTitleDraft = board.title
            boardSubtitleDraft = board.subtitle
            boardRefinementDraft = ""
            showBoardAgentTrace = false
        }
        .onChange(of: board.title) { _, newTitle in
            if boardTitleDraft != newTitle {
                boardTitleDraft = newTitle
            }
        }
        .onChange(of: board.subtitle) { _, newSubtitle in
            if boardSubtitleDraft != newSubtitle {
                boardSubtitleDraft = newSubtitle
            }
        }
    }

    @ViewBuilder
    private func moodboardCuratorCard(_ board: MoodboardDocument) -> some View {
        inspectorSectionCard("AI 策展助手", systemImage: "sparkles", iconColor: Color.accentColor) {
            if moodboards.canUndo && !moodboards.isRefiningActiveBoard {
                Button {
                    moodboards.undo()
                    coordinator.showToast("已撤销上一步画布调整", icon: "arrow.uturn.backward")
                } label: {
                    Text("撤销")
                        .font(.system(size: 10.5, weight: .medium))
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .help("撤销上一步（⌘Z）")
            }
        } content: {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 6) {
                    TextField("输入指令微调当前情绪板…", text: $boardRefinementDraft)
                        .textFieldStyle(.plain)
                        .font(.system(size: 11.5))
                        .padding(.horizontal, 8)
                        .padding(.vertical, 6)
                        .background(CharkleTheme.inspectorFieldSurface(for: colorScheme), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                        .overlay(
                            RoundedRectangle(cornerRadius: 8, style: .continuous)
                                .strokeBorder(CharkleTheme.hairline(for: colorScheme), lineWidth: 0.75)
                        )
                        .disabled(moodboards.isRefiningActiveBoard)
                        .onSubmit {
                            runBoardRefinement(boardRefinementDraft)
                        }

                    Button {
                        runBoardRefinement(boardRefinementDraft)
                    } label: {
                        Group {
                            if moodboards.isRefiningActiveBoard {
                                ProgressView()
                                    .controlSize(.mini)
                                    .frame(width: 14, height: 14)
                            } else {
                                Image(systemName: "arrow.up")
                                    .font(.system(size: 11, weight: .semibold))
                            }
                        }
                        .foregroundStyle(.white)
                        .frame(width: 26, height: 26)
                        .background(
                            (boardRefinementDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || moodboards.isRefiningActiveBoard)
                                ? Color.accentColor.opacity(0.42)
                                : Color.accentColor,
                            in: RoundedRectangle(cornerRadius: 8, style: .continuous)
                        )
                    }
                    .buttonStyle(.plain)
                    .disabled(boardRefinementDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || moodboards.isRefiningActiveBoard)
                    .help("执行 AI 策展微调")
                }

                HStack(spacing: 5) {
                    curatorQuickChip("重新分区编排") {
                        runBoardRefinement("按视觉层次重新划分为清晰分区，突出主视觉并补充简短美术指导批注")
                    }
                    curatorQuickChip("补充同氛围图") {
                        runBoardRefinement("保留当前核心素材，从素材库补充 4 到 6 张色调与气质一致的高质量参考图")
                    }
                    curatorQuickChip("精简不协调") {
                        runBoardRefinement("严格审视当前画布，剔除风格、构图或色温不协调的素材，宁缺毋滥")
                    }
                }
                .disabled(moodboards.isRefiningActiveBoard)

                if moodboards.isRefiningActiveBoard, let activeStep = moodboards.activeBoardAgentTrace.last {
                    HStack(spacing: 6) {
                        CharkleDelayedSpinner(isActive: moodboards.isRefiningActiveBoard, controlSize: .mini)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(activeStep.title)
                                .font(.system(size: 10.5, weight: .semibold))
                            if !activeStep.detail.isEmpty {
                                Text(activeStep.detail)
                                    .font(.system(size: 10))
                                    .foregroundStyle(.secondary)
                                    .lineLimit(2)
                            }
                        }
                    }
                    .padding(.top, 2)
                } else if let summary = moodboards.activeBoardLastSummary, !summary.isEmpty {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(summary)
                            .font(.system(size: 10.5))
                            .foregroundStyle(.secondary)
                            .lineLimit(3)
                            .fixedSize(horizontal: false, vertical: true)

                        if !moodboards.activeBoardAgentTrace.isEmpty {
                            Button {
                                let willExpand = !showBoardAgentTrace
                                withAnimation(
                                    CharkleMotion.enterExit(
                                        willExpand,
                                        enter: CharkleMotion.popoverEnter,
                                        exit: CharkleMotion.popoverExit,
                                        reduced: reduceMotion
                                    )
                                ) {
                                    showBoardAgentTrace = willExpand
                                }
                            } label: {
                                HStack(spacing: 5) {
                                    Text(showBoardAgentTrace ? "收起策展步骤" : "查看策展步骤（\(moodboards.activeBoardAgentTrace.count) 步）")
                                        .font(.system(size: 10.5, weight: .medium))
                                    Spacer(minLength: 4)
                                    Image(systemName: "chevron.right")
                                        .font(.system(size: 8.5, weight: .semibold))
                                        .rotationEffect(.degrees(showBoardAgentTrace ? 90 : 0))
                                }
                                .foregroundStyle(.secondary)
                                .padding(.horizontal, 8)
                                .padding(.vertical, 5)
                                .frame(maxWidth: .infinity, minHeight: 26, alignment: .leading)
                                .background(
                                    Color.primary.opacity(colorScheme == .dark ? 0.05 : 0.035),
                                    in: RoundedRectangle(cornerRadius: CharkleTheme.Radius.chip, style: .continuous)
                                )
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)

                            if showBoardAgentTrace {
                                VStack(alignment: .leading, spacing: 4) {
                                    ForEach(moodboards.activeBoardAgentTrace) { step in
                                        HStack(alignment: .top, spacing: 5) {
                                            Image(systemName: stepIconName(step.status))
                                                .font(.system(size: 9.5))
                                                .foregroundStyle(stepColor(step.status))
                                                .padding(.top, 1.5)
                                            VStack(alignment: .leading, spacing: 1) {
                                                Text(step.title)
                                                    .font(.system(size: 10, weight: .medium))
                                                if !step.detail.isEmpty {
                                                    Text(step.detail)
                                                        .font(.system(size: 9.5))
                                                        .foregroundStyle(.secondary)
                                                }
                                            }
                                        }
                                    }
                                }
                                .padding(.top, 2)
                            }
                        }
                    }
                    .padding(.top, 2)
                }

                HStack(spacing: 4) {
                    Text("已锁定卡片会自动保留 · 支持 ⌘Z 撤销")
                        .font(.system(size: 10))
                        .foregroundStyle(.tertiary)
                    Spacer()
                    Text("\(board.referencedAssetIDs.count) 张素材")
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(.tertiary)
                        .monospacedDigit()
                }
            }
        }
    }

    private func curatorQuickChip(_ title: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 10, weight: .medium))
                .lineLimit(1)
                .frame(maxWidth: .infinity)
                .padding(.horizontal, 5)
                .padding(.vertical, 5)
                .background(CharkleTheme.inspectorFieldSurface(for: colorScheme), in: RoundedRectangle(cornerRadius: 6, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .strokeBorder(CharkleTheme.hairline(for: colorScheme), lineWidth: 0.6)
                )
                .foregroundStyle(.primary.opacity(0.84))
        }
        .buttonStyle(CharkleTactileButtonStyle())
    }

    private func runBoardRefinement(_ instruction: String) {
        let trimmed = instruction.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !moodboards.isRefiningActiveBoard else { return }
        boardRefinementDraft = ""
        Task {
            let result = await moodboards.refineActiveBoard(instruction: trimmed)
            if let result {
                if let updated = moodboards.activeBoard {
                    boardTitleDraft = updated.title
                    boardSubtitleDraft = updated.subtitle
                }
                if result.cachedVisualInsightsCount > 0 {
                    await library.refreshAssets()
                }
                let count = result.primaryMatches.count
                if count > 0 {
                    coordinator.showToast("已完成策展微调（\(count) 张），可按 ⌘Z 撤销", icon: "sparkles")
                } else {
                    coordinator.showToast("未找到符合该条件的素材，已保持当前画布", icon: "info.circle")
                }
            } else if let err = moodboards.lastError {
                coordinator.showToast("策展调整未完成：\(err)", icon: "exclamationmark.triangle")
            }
        }
    }

    private func stepIconName(_ status: MoodboardAgentStepStatus) -> String {
        switch status {
        case .running: return "circle.dotted"
        case .done: return "checkmark.circle.fill"
        case .warning: return "exclamationmark.triangle.fill"
        }
    }

    private func stepColor(_ status: MoodboardAgentStepStatus) -> Color {
        switch status {
        case .running: return .accentColor
        case .done: return .green
        case .warning: return .orange
        }
    }

    private var emptyInspectorPlaceholder: some View {
        VStack(spacing: 12) {
            Spacer()
            CharkleEmptyStateVignette(.emptyInspector, compact: true)
            Text("选择素材查看详情")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.secondary)
            Text("单击卡片检视色板与元数据\n框选多张可一键生成情绪板")
                .font(.system(size: 11.5))
                .foregroundStyle(.tertiary)
                .multilineTextAlignment(.center)
            Spacer()
        }
        .padding(24)
    }

    // MARK: - Surface Card & Input Primitives

    private func inspectorCard<Content: View>(
        padding: CGFloat = 12,
        @ViewBuilder content: () -> Content
    ) -> some View {
        let shape = RoundedRectangle(cornerRadius: 12, style: .continuous)
        return content()
            .padding(padding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background {
                shape
                    .fill(CharkleTheme.surfaceElevated(for: colorScheme))
                    .shadow(
                        color: Color.black.opacity(colorScheme == .dark ? 0.22 : 0.035),
                        radius: 3,
                        y: 1
                    )
            }
            .overlay(
                shape.strokeBorder(CharkleTheme.hairline(for: colorScheme), lineWidth: 0.75)
            )
    }

    private func inspectorSectionCard<Content: View, Trailing: View>(
        _ title: String,
        systemImage: String,
        iconColor: Color? = nil,
        reorderSection: InspectorInfoSection? = nil,
        visibleSections: [InspectorInfoSection] = [],
        @ViewBuilder trailing: () -> Trailing,
        @ViewBuilder content: () -> Content
    ) -> some View {
        inspectorCard(padding: 12) {
            VStack(alignment: .leading, spacing: 9) {
                let headerRow = HStack(spacing: 5) {
                    Image(systemName: systemImage)
                        .font(.system(size: 10.5, weight: .semibold))
                        .foregroundStyle(iconColor ?? .secondary)
                    Text(title)
                        .font(.system(size: 11.5, weight: .semibold))
                        .foregroundStyle(.primary.opacity(0.84))
                    Spacer(minLength: 4)
                    trailing()
                    if let section = reorderSection {
                        InspectorDragGripDots(
                            isHighlighted: hoveredInspectorSection == section || draggingInspectorSection == section
                        )
                        .padding(.leading, 2)
                    }
                }
                .contentShape(Rectangle())

                if let section = reorderSection {
                    let visIdx = visibleSections.firstIndex(of: section)
                    let isFirst = (visIdx == 0)
                    let isLast = (visIdx != nil && visIdx == visibleSections.count - 1)

                    headerRow
                        .help("按住标题栏拖拽可自由调整排序 · 右键可快速置顶或恢复默认")
                        .onDrag {
                            draggingInspectorSection = section
                            return NSItemProvider(object: "charkle-inspector-card:\(section.rawValue)" as NSString)
                        } preview: {
                            HStack(spacing: 6) {
                                Image(systemName: systemImage)
                                    .font(.system(size: 11, weight: .semibold))
                                    .foregroundStyle(Color.accentColor)
                                Text(title)
                                    .font(.system(size: 12, weight: .semibold))
                            }
                            .padding(.horizontal, 12)
                            .padding(.vertical, 7)
                            .background(CharkleTheme.surfaceElevated(for: colorScheme), in: Capsule(style: .continuous))
                            .overlay(
                                Capsule(style: .continuous)
                                    .strokeBorder(Color.accentColor.opacity(0.35), lineWidth: 0.75)
                            )
                        }
                        .contextMenu {
                            Button {
                                withAnimation(CharkleMotion.accessible(CharkleMotion.moveOnScreen, reduced: reduceMotion)) {
                                    coordinator.moveInspectorSectionToTop(section)
                                }
                            } label: {
                                Label("移到最顶部", systemImage: "arrow.up.to.line")
                            }
                            .disabled(isFirst)

                            Button {
                                withAnimation(CharkleMotion.accessible(CharkleMotion.moveOnScreen, reduced: reduceMotion)) {
                                    coordinator.stepInspectorSection(section, delta: -1, visibleSections: visibleSections)
                                }
                            } label: {
                                Label("上移一项", systemImage: "arrow.up")
                            }
                            .disabled(isFirst)

                            Button {
                                withAnimation(CharkleMotion.accessible(CharkleMotion.moveOnScreen, reduced: reduceMotion)) {
                                    coordinator.stepInspectorSection(section, delta: 1, visibleSections: visibleSections)
                                }
                            } label: {
                                Label("下移一项", systemImage: "arrow.down")
                            }
                            .disabled(isLast)

                            Button {
                                withAnimation(CharkleMotion.accessible(CharkleMotion.moveOnScreen, reduced: reduceMotion)) {
                                    coordinator.moveInspectorSectionToBottom(section)
                                }
                            } label: {
                                Label("移到最底部", systemImage: "arrow.down.to.line")
                            }
                            .disabled(isLast)

                            if coordinator.isInspectorSectionOrderCustomized {
                                Divider()
                                Button {
                                    withAnimation(CharkleMotion.accessible(CharkleMotion.moveOnScreen, reduced: reduceMotion)) {
                                        coordinator.resetInspectorSectionOrder()
                                    }
                                    coordinator.showToast("已恢复信息栏默认排序", icon: "arrow.counterclockwise")
                                } label: {
                                    Label("恢复默认排序", systemImage: "arrow.counterclockwise")
                                }
                            }
                        }
                } else {
                    headerRow
                }

                content()
            }
        }
    }

    private func inspectorSectionCard<Content: View>(
        _ title: String,
        systemImage: String,
        iconColor: Color? = nil,
        reorderSection: InspectorInfoSection? = nil,
        visibleSections: [InspectorInfoSection] = [],
        @ViewBuilder content: () -> Content
    ) -> some View {
        inspectorSectionCard(
            title,
            systemImage: systemImage,
            iconColor: iconColor,
            reorderSection: reorderSection,
            visibleSections: visibleSections
        ) {
            EmptyView()
        } content: {
            content()
        }
    }

    private func inspectorTextField(
        placeholder: String,
        text: Binding<String>,
        systemImage: String? = nil,
        onSubmit: (() -> Void)? = nil
    ) -> some View {
        HStack(spacing: 6) {
            if let systemImage {
                Image(systemName: systemImage)
                    .font(.system(size: 10.5, weight: .medium))
                    .foregroundStyle(.tertiary)
            }
            TextField(placeholder, text: text)
                .textFieldStyle(.plain)
                .font(.system(size: 11.5))
                .onSubmit { onSubmit?() }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .background(CharkleTheme.inspectorFieldSurface(for: colorScheme), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .strokeBorder(CharkleTheme.hairline(for: colorScheme), lineWidth: 0.75)
        )
    }

    private var inspectorInnerDivider: some View {
        Rectangle()
            .fill(CharkleTheme.hairline(for: colorScheme).opacity(0.75))
            .frame(height: 0.5)
    }

    private var inspectorRowDivider: some View {
        Rectangle()
            .fill(CharkleTheme.hairline(for: colorScheme).opacity(0.5))
            .frame(height: 0.5)
    }

    private func specRow(_ label: String, _ value: String) -> some View {
        HStack {
            Text(label)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
            Spacer()
            Text(value)
                .font(.system(size: 11, weight: .medium))
                .monospacedDigit()
                .foregroundStyle(.primary.opacity(0.88))
        }
        .padding(.vertical, 5)
    }

    // MARK: - Helpers

    private func runInspectorRetagging(for ids: [UUID]) {
        guard !ids.isEmpty else { return }
        if ids.count > 1 {
            coordinator.showToast("正在为 \(ids.count) 项素材重新生成标签…", icon: "sparkles")
        }
        Task {
            let outcome = await library.retagAssetsWithCloudAI(ids: ids)
            switch outcome {
            case .aiDisabled:
                coordinator.showToast("请先在「设置 → 智能与搜索」中开启云端增强智能", icon: "sparkles", tone: .warning)
            case .cancelled(let completed, let total):
                coordinator.showToast("已停止重新打标（已完成 \(completed)/\(total) 项）", icon: "stop.circle")
            case .finished(let succeeded, let failed, let total, let firstError):
                if succeeded > 0 && failed == 0 {
                    coordinator.showToast(
                        total == 1 ? "已按当前格式重新生成建议标签" : "已完成 \(succeeded) 项 AI 重新打标",
                        icon: "sparkles"
                    )
                } else if succeeded > 0 && failed > 0 {
                    coordinator.showToast(
                        "已完成 \(succeeded)/\(total) 项重新打标（\(failed) 项失败）",
                        icon: "exclamationmark.triangle",
                        tone: .warning
                    )
                } else {
                    coordinator.showToast(
                        firstError ?? "重新打标失败，请检查云端增强智能配置",
                        icon: "exclamationmark.triangle",
                        tone: .warning
                    )
                }
            }
        }
    }

    private func folderName(for folderID: UUID?) -> String {
        guard let folderID else { return "收件箱" }
        return library.folders.first(where: { $0.id == folderID })?.name ?? "文件夹"
    }

    private func commitSingleAssetTitle(_ asset: AssetRecord) {
        let trimmed = titleDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed != asset.title else { return }
        Task {
            await library.applyPatch(AssetBatchPatch(assetIDs: [asset.id], title: trimmed))
        }
    }

    private func commitBoardHeader(_ board: MoodboardDocument) {
        var next = board
        let trimmed = boardTitleDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty { next.title = trimmed }
        next.subtitle = boardSubtitleDraft
        moodboards.commitMutation(next)
    }

    private func quickAddFilteredAssets(excluding excluded: Set<UUID>) -> [AssetRecord] {
        let q = quickAddQuery.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return library.allAssetsByID.values
            .filter { asset in
                guard !asset.isTrashed, !excluded.contains(asset.id) else { return false }
                if q.isEmpty { return true }
                let hay = ([asset.title, asset.sourceDomain ?? ""] + asset.tags).joined(separator: " ").lowercased()
                return hay.contains(q)
            }
            .sorted { $0.createdAt > $1.createdAt }
    }
}

// MARK: - Drag-to-Reorder Helpers for Single-Asset Inspector Cards

private struct InspectorDragGripDots: View {
    let isHighlighted: Bool

    var body: some View {
        VStack(spacing: 2.2) {
            ForEach(0..<3, id: \.self) { _ in
                HStack(spacing: 2.2) {
                    Circle().frame(width: 2.2, height: 2.2)
                    Circle().frame(width: 2.2, height: 2.2)
                }
            }
        }
        .foregroundStyle(Color.primary.opacity(isHighlighted ? 0.56 : 0.22))
        .padding(.horizontal, 3)
        .padding(.vertical, 2)
        .contentShape(Rectangle())
    }
}

private struct InspectorSectionDropDelegate: DropDelegate {
    let targetSection: InspectorInfoSection
    @Binding var draggingSection: InspectorInfoSection?
    @Binding var dropTargetSection: InspectorInfoSection?
    let reduceMotion: Bool
    let onMove: (InspectorInfoSection, InspectorInfoSection) -> Void

    func validateDrop(info: DropInfo) -> Bool {
        draggingSection != nil
    }

    func dropEntered(info: DropInfo) {
        guard let dragged = draggingSection else { return }
        dropTargetSection = targetSection
        guard dragged != targetSection else { return }
        withAnimation(CharkleMotion.accessible(CharkleMotion.moveOnScreen, reduced: reduceMotion)) {
            onMove(dragged, targetSection)
        }
    }

    func dropUpdated(info: DropInfo) -> DropProposal? {
        draggingSection != nil ? DropProposal(operation: .move) : DropProposal(operation: .cancel)
    }

    func performDrop(info: DropInfo) -> Bool {
        draggingSection = nil
        dropTargetSection = nil
        return true
    }

    func dropExited(info: DropInfo) {
        // Guard against drags cancelled outside the window so the source card never remains dimmed.
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(120))
            if draggingSection != nil && NSEvent.pressedMouseButtons == 0 {
                draggingSection = nil
                dropTargetSection = nil
            }
        }
    }
}
