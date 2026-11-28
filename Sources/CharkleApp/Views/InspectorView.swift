import AppKit
import CharkleCanvas
import CharkleCore
import SwiftUI
import UniformTypeIdentifiers

/// Adaptive Right Inspector (`300pt` Precision Studio Inspector) rendered directly on
/// `CharkleTheme.inspectorBackground` with `0.5pt` hairline-divided `CharkleInspectorSection` blocks,
/// switching seamlessly between:
/// 1. Moodboard Right Rail (Identity, AI Curator, Candidate Swap Pool, Board Palette, Quick Add, Export & Figma Bridge)
/// 2. Multi-Select Batch Inspector (Summary & CTA, Bulk Organize, Offline & Actions)
/// 3. Single Asset Inspector (Preview & Identity, Quick Actions, Colors & Tags, Notes & OCR, Media Specs, Similar Assets)
public struct InspectorView: View {
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.charkleAccentSource) private var accentSource
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    public let coordinator: AppCoordinatorStore
    public let library: LibraryStore
    public let moodboards: MoodboardStore
    public let pinnedAsset: AssetRecord?
    public let isQuickLookHosted: Bool
    public let isActive: Bool
    public let panelWidth: CGFloat
    public let onCopyHex: (String) -> Void
    public let onFilterByColor: (String) -> Void
    public let onOpenQuickLook: (AssetRecord) -> Void
    public let onCopyBoardImage: () -> Void
    public let onSaveBoardImage: (MoodboardExportFormat) -> Void
    public let onExportFigmaBundle: () -> Void
    public let onExportPureRef: () -> Void
    public let onOpenInPureRef: () -> Void
    public let onOpenFigmaPluginGuide: () -> Void
    public let onRequestCloseQuickLook: (() -> Void)?

    @State private var newTagInput: String = ""
    @State private var batchTagInput: String = ""
    @State private var quickAddQuery: String = ""
    @State private var notesDraft: String = ""
    @State private var titleDraft: String = ""
    @State private var notesSaveTask: Task<Void, Never>?
    @State private var pendingNotesAssetID: UUID?
    @State private var pendingNotesValue: String?
    @State private var boardTitleDraft: String = ""
    @State private var boardSubtitleDraft: String = ""
    @State private var editingBoardID: UUID? = nil
    @State private var editingBoardOriginalTitle: String = ""
    @State private var editingBoardOriginalSubtitle: String = ""
    @State private var boardRefinementDraft: String = ""
    @State private var showBoardAgentTrace: Bool = false
    @State private var pendingPermanentDeleteIDs: [UUID] = []
    @State private var confirmSinglePermanentDelete: Bool = false
    @State private var draggingInspectorSection: InspectorInfoSection? = nil
    @State private var dropTargetInspectorSection: InspectorInfoSection? = nil
    @State private var isVersionStackExpanded: Bool = true
    @State private var versionEditorDraft: String = ""
    @State private var versionNoteDraft: String = ""
    @State private var isTitleHovered: Bool = false
    @State private var isOCRExpanded: Bool = false

    @FocusState private var isTitleFocused: Bool
    @FocusState private var isNotesFocused: Bool
    @FocusState private var isBoardTitleFocused: Bool
    @FocusState private var isBoardSubtitleFocused: Bool
    @FocusState private var isBoardRefinementFocused: Bool

    private static let heroTitleFont: Font = .system(size: 13.5, weight: .semibold)

    private static let mediaTimestampFormatter: DateFormatter = {
        let fmt = DateFormatter()
        fmt.dateFormat = "yyyy-MM-dd HH:mm"
        return fmt
    }()

    private var accentColor: Color {
        CharkleTheme.accent(for: colorScheme, source: accentSource)
    }

    private var accentSoft: Color {
        CharkleTheme.accentSoft(for: colorScheme, source: accentSource)
    }

    private var accentBorder: Color {
        CharkleTheme.accentBorder(for: colorScheme, source: accentSource)
    }

    public init(
        coordinator: AppCoordinatorStore,
        library: LibraryStore,
        moodboards: MoodboardStore,
        pinnedAsset: AssetRecord? = nil,
        isQuickLookHosted: Bool = false,
        isActive: Bool = true,
        panelWidth: CGFloat = AppCoordinatorStore.defaultInspectorWidth,
        onCopyHex: @escaping (String) -> Void,
        onFilterByColor: @escaping (String) -> Void,
        onOpenQuickLook: @escaping (AssetRecord) -> Void,
        onCopyBoardImage: @escaping () -> Void = {},
        onSaveBoardImage: @escaping (MoodboardExportFormat) -> Void = { _ in },
        onExportFigmaBundle: @escaping () -> Void = {},
        onExportPureRef: @escaping () -> Void = {},
        onOpenInPureRef: @escaping () -> Void = {},
        onOpenFigmaPluginGuide: @escaping () -> Void = {},
        onRequestCloseQuickLook: (() -> Void)? = nil
    ) {
        self.coordinator = coordinator
        self.library = library
        self.moodboards = moodboards
        self.pinnedAsset = pinnedAsset
        self.isQuickLookHosted = isQuickLookHosted
        self.isActive = isActive
        self.panelWidth = panelWidth
        self.onCopyHex = onCopyHex
        self.onFilterByColor = onFilterByColor
        self.onOpenQuickLook = onOpenQuickLook
        self.onCopyBoardImage = onCopyBoardImage
        self.onSaveBoardImage = onSaveBoardImage
        self.onExportFigmaBundle = onExportFigmaBundle
        self.onExportPureRef = onExportPureRef
        self.onOpenInPureRef = onOpenInPureRef
        self.onOpenFigmaPluginGuide = onOpenFigmaPluginGuide
        self.onRequestCloseQuickLook = onRequestCloseQuickLook
    }

    public var body: some View {
        ZStack(alignment: .top) {
            CharkleTheme.inspectorBackground(for: colorScheme)
                .ignoresSafeArea()

            // When Quick Look is presenting its own hosted Inspector full-bleed above the window,
            // pause the underlying main-window Inspector body to avoid duplicate invalidation storms.
            if !isQuickLookHosted && coordinator.quickLookAssetID != nil {
                Color.clear
            } else {
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
        }
        .frame(width: panelWidth)
        .frame(maxHeight: .infinity)
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
            // Top Segmented Switcher (信息 | 相似)
            CharkleSegmentedControl(
                selection: Binding(
                    get: { coordinator.selectedInspectorTab },
                    set: { coordinator.selectedInspectorTab = $0 }
                ),
                options: InspectorDetailTab.allCases,
                size: .regular,
                fullWidth: true,
                title: { tab in
                    switch tab {
                    case .info: "信息"
                    case .similar: "相似"
                    }
                },
                badge: { tab in
                    tab == .similar && !library.similarAssets.isEmpty
                        ? "\(library.similarAssets.count)"
                        : nil
                },
                helpText: { tab in
                    switch tab {
                    case .info: "查看素材详情与元数据"
                    case .similar: "查看视觉或色彩相近的素材"
                    }
                }
            )
            .padding(.horizontal, 16)
            .padding(.top, 10)
            .padding(.bottom, 9)
            .background {
                if !isQuickLookHosted {
                    CharkleWindowDragArea()
                }
            }

            CharkleHairlineDivider()

            if coordinator.selectedInspectorTab == .similar {
                singleAssetSimilarTab(asset)
            } else {
                singleAssetInfoScroll(asset)
            }
        }
        .onAppear {
            titleDraft = asset.title
            notesDraft = asset.notes
            versionEditorDraft = Self.cleanVersionEditorName(
                asset.richMetadata?.versionStack?.editorName,
                alreadyShownNote: nil
            ) ?? ""
            versionNoteDraft = Self.cleanVersionTimelineNote(
                changeNote: asset.richMetadata?.versionStack?.changeNote,
                versionLabel: nil
            ) ?? ""
            if isActive, isQuickLookHosted || coordinator.isInspectorVisible || coordinator.selectedDestination == .inbox {
                library.refreshInspectorContext(for: asset.id)
            }
        }
        .onChange(of: asset.id) { oldID, newID in
            if let oldAsset = library.allAssetsByID[oldID] {
                commitSingleAssetTitle(oldAsset)
            }
            flushPendingNotesSave()
            titleDraft = asset.title
            notesDraft = asset.notes
            versionEditorDraft = Self.cleanVersionEditorName(
                asset.richMetadata?.versionStack?.editorName,
                alreadyShownNote: nil
            ) ?? ""
            versionNoteDraft = Self.cleanVersionTimelineNote(
                changeNote: asset.richMetadata?.versionStack?.changeNote,
                versionLabel: nil
            ) ?? ""
            if isActive, isQuickLookHosted || coordinator.isInspectorVisible || coordinator.selectedDestination == .inbox {
                library.refreshInspectorContext(for: newID)
            }
        }
        .onChange(of: coordinator.isInspectorVisible) { _, isVisible in
            if isVisible && isActive {
                library.refreshInspectorContext(for: asset.id)
            }
        }
        .onChange(of: asset.title) { _, newTitle in
            if !isTitleFocused && titleDraft != newTitle {
                titleDraft = newTitle
            }
        }
        .onChange(of: asset.notes) { _, newNotes in
            if !isNotesFocused && pendingNotesAssetID != asset.id && notesDraft != newNotes {
                notesDraft = newNotes
            }
        }
        .onChange(of: isTitleFocused) { wasFocused, nowFocused in
            if wasFocused && !nowFocused {
                commitSingleAssetTitle(asset)
            }
        }
        .onChange(of: isNotesFocused) { wasFocused, nowFocused in
            if wasFocused && !nowFocused {
                flushPendingNotesSave()
            }
        }
        .onChange(of: coordinator.quickLookAssetID) { oldQL, newQL in
            if !isQuickLookHosted && oldQL != nil && newQL == nil {
                library.refreshInspectorContext(for: asset.id)
            }
        }
        .onDisappear {
            commitSingleAssetTitle(asset)
            flushPendingNotesSave()
        }
    }

    private func singleAssetSimilarTab(_ asset: AssetRecord) -> some View {
        ScrollView(.vertical) {
            VStack(alignment: .leading, spacing: 10) {
                Text("与「\(asset.title)」相似的素材")
                    .font(CharkleTheme.text(.caption, weight: .medium))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)

                if library.isLoadingSimilarAssets && library.similarAssets.isEmpty {
                    CharkleSimilarGridSkeleton()
                } else if library.similarAssets.isEmpty {
                    VStack(spacing: 10) {
                        CharkleEmptyStateVignette(.noFilterResults, compact: true)
                        Text("暂无视觉或色彩相近的素材")
                            .font(CharkleTheme.text(.caption, weight: .medium))
                            .foregroundStyle(.secondary)
                        Text("导入更多素材或等待本地视觉特征索引完成后，这里会自动呈现同风格相似项目。")
                            .font(CharkleTheme.text(.caption))
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
                                    .strokeBorder(CharkleTheme.hairline(for: colorScheme), lineWidth: CharkleTheme.hairlineWidth)
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
                            .help(scored.matchReasons.isEmpty ? scored.asset.title : "\(scored.asset.title)（\(scored.matchReasons.joined(separator: " / "))）")
                        }
                    }
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
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
                return asset.hasExtractableLinkMedia || (asset.richMetadata?.webPage?.hasRichSummary == true)
            }
        }
    }

    private func singleAssetInfoScroll(_ asset: AssetRecord) -> some View {
        let resolvedMeta = library.resolvedImageMetadata(for: asset)
        let visibleSections = visibleInfoSections(for: asset, resolvedMeta: resolvedMeta)

        return ScrollView(.vertical) {
            let activeAnchorSection = dropTargetInspectorSection ?? draggingInspectorSection
            let activeAnchorIndex = activeAnchorSection.flatMap { visibleSections.firstIndex(of: $0) }

            VStack(alignment: .leading, spacing: 0) {
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

                    singleAssetSection(
                        section,
                        for: asset,
                        resolvedMeta: resolvedMeta,
                        visibleSections: visibleSections,
                        showsTopDivider: index > 0
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
                                    .fill(accentColor)
                                    .frame(width: 5, height: 5)
                                Rectangle()
                                    .fill(accentColor)
                                    .frame(height: 2)
                                Circle()
                                    .fill(accentColor)
                                    .frame(width: 5, height: 5)
                            }
                            .padding(.horizontal, 10)
                            .offset(y: -1)
                            .allowsHitTesting(false)
                            .transition(.opacity)
                        }
                    }
                    .overlay {
                        if isDragged {
                            RoundedRectangle(cornerRadius: CharkleTheme.Radius.chip, style: .continuous)
                                .strokeBorder(
                                    accentColor.opacity(0.45),
                                    style: StrokeStyle(lineWidth: 1.0, dash: [5, 4])
                                )
                                .padding(.horizontal, 6)
                                .padding(.vertical, 2)
                                .allowsHitTesting(false)
                        }
                    }
                    .onHover { _ in
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
                    CharkleHairlineDivider()
                    Button {
                        withAnimation(CharkleMotion.accessible(CharkleMotion.moveOnScreen, reduced: reduceMotion)) {
                            coordinator.resetInspectorSectionOrder()
                        }
                        coordinator.showToast("已恢复信息栏默认排序", icon: "arrow.counterclockwise")
                    } label: {
                        Label("恢复信息栏默认排序", systemImage: "arrow.counterclockwise")
                    }
                    .buttonStyle(.charkle(.subtle, size: .xs))
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 10)
                }
            }
            .padding(.bottom, 12)
            .animation(CharkleMotion.accessible(CharkleMotion.moveOnScreen, reduced: reduceMotion), value: coordinator.inspectorInfoSectionOrder)
            .charkleCleanScrollbars(hidden: true)
        }
        .scrollIndicators(.hidden)
        .task(id: "\(asset.id.uuidString)-\(isActive || isQuickLookHosted)") {
            guard isActive || isQuickLookHosted else { return }
            await library.hydrateImageMetadataIfNeeded(for: asset.id)
        }
    }

    private func reorderActions(
        for section: InspectorInfoSection,
        visibleSections: [InspectorInfoSection]
    ) -> CharkleSectionReorderActions {
        let visIdx = visibleSections.firstIndex(of: section)
        let isFirst = (visIdx == 0)
        let isLast = (visIdx != nil && visIdx == visibleSections.count - 1)
        return CharkleSectionReorderActions(
            canMoveUp: !isFirst,
            canMoveDown: !isLast,
            isCustomized: coordinator.isInspectorSectionOrderCustomized,
            onMoveToTop: { coordinator.moveInspectorSectionToTop(section) },
            onMoveUp: { coordinator.stepInspectorSection(section, delta: -1, visibleSections: visibleSections) },
            onMoveDown: { coordinator.stepInspectorSection(section, delta: 1, visibleSections: visibleSections) },
            onMoveToBottom: { coordinator.moveInspectorSectionToBottom(section) },
            onResetOrder: {
                coordinator.resetInspectorSectionOrder()
                coordinator.showToast("已恢复信息栏默认排序", icon: "arrow.counterclockwise")
            },
            onBeginDrag: {
                draggingInspectorSection = section
                return NSItemProvider(object: "charkle-inspector-card:\(section.rawValue)" as NSString)
            }
        )
    }

    private func isSectionHighlighted(_ section: InspectorInfoSection) -> Bool {
        draggingInspectorSection == section
    }

    @ViewBuilder
    private func singleAssetSection(
        _ section: InspectorInfoSection,
        for asset: AssetRecord,
        resolvedMeta: ExtractedImageMetadata,
        visibleSections: [InspectorInfoSection],
        showsTopDivider: Bool
    ) -> some View {
        switch section {
        case .previewIdentity:
            VStack(alignment: .leading, spacing: 0) {
                singleAssetPreviewIdentitySection(asset, visibleSections: visibleSections, showsTopDivider: showsTopDivider)
                let stackSiblings = library.versionStackSiblings(for: asset.id)
                if !asset.isTrashed && (stackSiblings.count > 1 || asset.richMetadata?.versionStack != nil) {
                    singleAssetVersionStackSection(asset, siblings: stackSiblings)
                }
            }
        case .quickActions:
            singleAssetQuickActionsSection(asset, visibleSections: visibleSections, showsTopDivider: showsTopDivider)
        case .colorsAndTags:
            singleAssetColorsAndTagsSection(asset, visibleSections: visibleSections, showsTopDivider: showsTopDivider)
        case .notesAndOCR:
            singleAssetNotesAndOCRSection(asset, visibleSections: visibleSections, showsTopDivider: showsTopDivider)
        case .aiGeneration:
            if let aiGen = resolvedMeta.aiGeneration, !aiGen.isEmpty {
                aiGenerationInspectorSection(aiGen, visibleSections: visibleSections, showsTopDivider: showsTopDivider)
            }
        case .photoExif:
            if let exif = resolvedMeta.photoExif, exif.hasMeaningfulCameraExif {
                photoExifInspectorSection(exif, visibleSections: visibleSections, showsTopDivider: showsTopDivider)
            }
        case .mediaSpecs:
            singleAssetMediaSpecsSection(asset, resolvedExif: resolvedMeta.photoExif, visibleSections: visibleSections, showsTopDivider: showsTopDivider)
        case .githubRepo:
            if let repo = asset.richMetadata?.githubRepo {
                singleAssetGitHubRepoSection(asset, repo: repo, visibleSections: visibleSections, showsTopDivider: showsTopDivider)
            }
        case .socialMediaExtract:
            if let post = asset.richMetadata?.socialPost, !post.effectiveAttachments.isEmpty {
                singleAssetSocialExtractSection(asset, post: post, visibleSections: visibleSections, showsTopDivider: showsTopDivider)
            } else if let web = asset.richMetadata?.webPage, !web.attachments.isEmpty || web.hasRichSummary {
                singleAssetWebPageExtractSection(asset, web: web, visibleSections: visibleSections, showsTopDivider: showsTopDivider)
            }
        }
    }

    private func singleAssetPreviewIdentitySection(
        _ asset: AssetRecord,
        visibleSections: [InspectorInfoSection],
        showsTopDivider: Bool
    ) -> some View {
        CharkleInspectorSection(
            "预览",
            systemImage: nil,
            showsTopDivider: showsTopDivider,
            isReorderHighlighted: isSectionHighlighted(.previewIdentity),
            reorderActions: reorderActions(for: .previewIdentity, visibleSections: visibleSections)
        ) {
            VStack(alignment: .leading, spacing: 10) {
                let naturalRatio = max(0.35, min(3.2, CGFloat(asset.aspectRatio)))
                let previewContentWidth = max(160, panelWidth - 44)
                let fittedHeight = min(264, max(104, (previewContentWidth / naturalRatio).rounded()))
                let fittedWidth = min(previewContentWidth, (fittedHeight * naturalRatio).rounded())
                let previewShape = RoundedRectangle(cornerRadius: CharkleTheme.Radius.chip, style: .continuous)

                AssetThumbnailSurface(
                    asset: asset,
                    loader: library.thumbnailLoader,
                    tier: .preview1400,
                    cornerRadius: CharkleTheme.Radius.chip,
                    contentMode: .fit
                )
                .frame(width: fittedWidth, height: fittedHeight)
                .overlay(
                    previewShape.strokeBorder(
                        Color.primary.opacity(0.08),
                        lineWidth: CharkleTheme.hairlineWidth
                    )
                )
                .shadow(
                    color: .black.opacity(colorScheme == .dark ? 0.30 : 0.09),
                    radius: 7,
                    y: 2.5
                )
                .frame(maxWidth: .infinity)
                .padding(.vertical, 4)
                .contentShape(Rectangle())
                .onTapGesture {
                    if !isQuickLookHosted {
                        onOpenQuickLook(asset)
                    }
                }
                .help(isQuickLookHosted ? asset.title : (asset.isExternalWebLink ? "点击在默认浏览器中打开" : "点击打开全屏预览"))

                VStack(alignment: .leading, spacing: 8) {
                    let titleShape = RoundedRectangle(cornerRadius: CharkleTheme.Radius.chip, style: .continuous)
                    TextField("素材标题", text: $titleDraft)
                        .textFieldStyle(.plain)
                        .font(Self.heroTitleFont)
                        .focused($isTitleFocused)
                        .onSubmit { commitSingleAssetTitle(asset) }
                        .padding(.horizontal, 8)
                        .padding(.vertical, 5)
                        .background(
                            (isTitleFocused || isTitleHovered)
                                ? CharkleTheme.inspectorFieldSurface(for: colorScheme)
                                : Color.clear,
                            in: titleShape
                        )
                        .overlay(
                            titleShape.strokeBorder(
                                isTitleFocused
                                    ? accentBorder
                                    : (isTitleHovered ? CharkleTheme.hairline(for: colorScheme) : Color.clear),
                                lineWidth: isTitleFocused ? 1.0 : CharkleTheme.hairlineWidth
                            )
                        )
                        .padding(.horizontal, -8)
                        .onHover { isTitleHovered = $0 }

                    HStack(spacing: 8) {
                        HStack(spacing: 3) {
                            ForEach(1...5, id: \.self) { star in
                                Button {
                                    let target = asset.rating == star ? 0 : star
                                    Task { await library.setRating(target, for: [asset.id]) }
                                } label: {
                                    Image(systemName: star <= asset.rating ? "star.fill" : "star")
                                        .font(.system(size: 12))
                                        .foregroundStyle(
                                            star <= asset.rating
                                                ? Color(charkleHex: "#E5B243")
                                                : Color.primary.opacity(0.24)
                                        )
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
                                    Image(systemName: "arrow.down.circle")
                                        .symbolVariant(asset.pinnedOffline ? .fill : .none)
                                        .font(.system(size: 11))
                                    Text(asset.pinnedOffline ? "已保留本地" : "保留本地")
                                        .font(CharkleTheme.text(.caption, weight: .medium))
                                }
                                .foregroundStyle(asset.pinnedOffline ? accentColor : CharkleTheme.secondaryInk(for: colorScheme))
                                .padding(.horizontal, 8)
                                .frame(height: 24)
                                .background(
                                    asset.pinnedOffline ? accentSoft : CharkleTheme.inspectorFieldSurface(for: colorScheme),
                                    in: RoundedRectangle(cornerRadius: CharkleTheme.Radius.chip, style: .continuous)
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

    private func singleAssetQuickActionsSection(
        _ asset: AssetRecord,
        visibleSections: [InspectorInfoSection],
        showsTopDivider: Bool
    ) -> some View {
        CharkleInspectorSection(
            asset.isTrashed ? "废纸篓操作" : "快捷操作",
            systemImage: nil,
            showsTopDivider: showsTopDivider,
            isReorderHighlighted: isSectionHighlighted(.quickActions),
            reorderActions: reorderActions(for: .quickActions, visibleSections: visibleSections)
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
                    }
                    .buttonStyle(.charkle(.accent, size: .sm, fullWidth: true))

                    Button(role: .destructive) {
                        confirmSinglePermanentDelete = true
                    } label: {
                        Label("彻底删除", systemImage: "trash.slash")
                    }
                    .buttonStyle(.charkle(.destructive, size: .sm, fullWidth: true))
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
                let row2ContainerShape = RoundedRectangle(cornerRadius: CharkleTheme.Radius.chip, style: .continuous)
                VStack(spacing: 6) {
                    HStack(spacing: 6) {
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
                            inspectorStandardMenuLabel(title: folderName(for: asset.folderID), systemImage: "folder", showsChevron: true)
                        }
                        .menuStyle(.button)
                        .buttonStyle(CharkleButtonStyle(.standard, size: .sm, fullWidth: true))
                        .menuIndicator(.hidden)
                        .help(asset.folderID.map { "当前所在：\(library.folderDisplayPath(for: $0))" } ?? "当前所在：收件箱")

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
                            Button("以此素材新建情绪板…") {
                                library.selectedAssetIDs = [asset.id]
                                if isQuickLookHosted {
                                    onRequestCloseQuickLook?()
                                }
                                coordinator.presentMoodboardGenerator(entry: .seedAssets)
                            }
                        } label: {
                            inspectorStandardMenuLabel(title: "情绪板", systemImage: "rectangle.3.group", showsChevron: true)
                        }
                        .menuStyle(.button)
                        .buttonStyle(CharkleButtonStyle(.standard, size: .sm, fullWidth: true))
                        .menuIndicator(.hidden)
                    }

                    HStack(spacing: 4) {
                        Button {
                            Task {
                                let ok = await library.revealInFinder(assetID: asset.id)
                                if !ok {
                                    coordinator.showToast("无法定位本地文件", icon: "exclamationmark.triangle", tone: .warning)
                                }
                            }
                        } label: {
                            Label("访达", systemImage: "folder")
                                .lineLimit(1)
                        }
                        .buttonStyle(.charkle(.subtle, size: .xs, fullWidth: true))

                        Button {
                            Task {
                                _ = await library.copyAssetsToPasteboard([asset.id])
                                coordinator.showToast("已拷贝到剪贴板", icon: "doc.on.doc")
                            }
                        } label: {
                            Label("拷贝", systemImage: "doc.on.doc")
                                .lineLimit(1)
                        }
                        .buttonStyle(.charkle(.subtle, size: .xs, fullWidth: true))

                        Button {
                            Task {
                                _ = await library.cutAssets([asset.id])
                                coordinator.showToast("已剪切，前往目标文件夹按 ⌘V 移动", icon: "scissors")
                            }
                        } label: {
                            Label("剪切", systemImage: "scissors")
                                .lineLimit(1)
                        }
                        .buttonStyle(.charkle(.subtle, size: .xs, fullWidth: true))

                        Button(role: .destructive) {
                            let id = asset.id
                            let nextGalleryFocusID = MasonryLayoutEngine.nextFocusAssetIDAfterDeleting(
                                deletedIDs: [id],
                                in: library.assets.map(\.id)
                            )
                            if isQuickLookHosted && coordinator.quickLookAssetID == id {
                                let playlist = coordinator.quickLookPlaylist
                                let remaining = playlist.filter { $0 != id }
                                if playlist.count > 1,
                                   let nextQLID = MasonryLayoutEngine.nextFocusAssetIDAfterDeleting(deletedIDs: [id], in: playlist),
                                   !remaining.isEmpty {
                                    coordinator.openQuickLook(assetID: nextQLID, playlist: remaining)
                                    library.selectedAssetIDs = [nextQLID]
                                    coordinator.focusedStageAssetID = nextQLID
                                } else if let onRequestCloseQuickLook {
                                    onRequestCloseQuickLook()
                                } else {
                                    coordinator.closeQuickLook()
                                }
                            }
                            Task {
                                await library.trashAssets([id])
                                if coordinator.quickLookAssetID == nil,
                                   library.selectedAssetIDs.isEmpty,
                                   let nextFocusID = nextGalleryFocusID,
                                   library.assets.contains(where: { $0.id == nextFocusID }) {
                                    var transaction = Transaction(animation: nil)
                                    transaction.disablesAnimations = true
                                    withTransaction(transaction) {
                                        library.selectedAssetIDs = [nextFocusID]
                                        coordinator.focusedStageAssetID = nextFocusID
                                    }
                                }
                                coordinator.showToast(
                                    "已移至废纸篓",
                                    icon: "trash",
                                    actionTitle: "撤销",
                                    onAction: {
                                        Task {
                                            await library.restoreAssets([id])
                                            coordinator.showToast("已放回原处", icon: "arrow.uturn.backward", tone: .success)
                                        }
                                    }
                                )
                            }
                        } label: {
                            Label("删除", systemImage: "trash")
                                .lineLimit(1)
                        }
                        .buttonStyle(.charkle(.subtle, size: .xs, fullWidth: true))
                        .help("移至废纸篓 (Delete)")
                    }
                    .padding(2)
                    .background(CharkleTheme.inspectorFieldSurface(for: colorScheme), in: row2ContainerShape)
                    .overlay(
                        row2ContainerShape.strokeBorder(
                            CharkleTheme.hairline(for: colorScheme),
                            lineWidth: CharkleTheme.hairlineWidth
                        )
                    )
                }
            }
        }
    }

    private func singleAssetColorsAndTagsSection(
        _ asset: AssetRecord,
        visibleSections: [InspectorInfoSection],
        showsTopDivider: Bool
    ) -> some View {
        let showsPalette = asset.mediaKind != .document
            && (!asset.dominantColors.isEmpty || asset.mediaKind == .image || asset.mediaKind == .webBookmark || asset.mediaKind == .designFile)

        return CharkleInspectorSection(
            showsPalette ? "色彩与标签" : "标签",
            systemImage: nil,
            showsTopDivider: showsTopDivider,
            isReorderHighlighted: isSectionHighlighted(.colorsAndTags),
            reorderActions: reorderActions(for: .colorsAndTags, visibleSections: visibleSections)
        ) {
            VStack(alignment: .leading, spacing: 10) {
                if showsPalette {
                    VStack(alignment: .leading, spacing: 7) {
                        HStack(spacing: 6) {
                            Text("主色")
                                .font(CharkleTheme.text(.caption, weight: .medium))
                                .foregroundStyle(CharkleTheme.secondaryInk(for: colorScheme))
                            Spacer()
                            if asset.mediaKind == .image || asset.mediaKind == .webBookmark || asset.mediaKind == .animatedImage {
                                Button {
                                    coordinator.showToast("正在定位主体并重新提取色板…", icon: "viewfinder")
                                    Task {
                                        switch await library.extractSubjectPalette(for: asset.id) {
                                        case .success(let res):
                                            coordinator.showToast(
                                                "主体色板已更新：\(res.subjectRegion.summary)",
                                                icon: "paintpalette.fill"
                                            )
                                        case .failure(let error):
                                            coordinator.showToast(error.localizedDescription, icon: "exclamationmark.triangle", tone: .warning)
                                        }
                                    }
                                } label: {
                                    Label("按主体重提", systemImage: "viewfinder")
                                        .font(CharkleTheme.text(.caption, weight: .medium))
                                        .foregroundStyle(accentColor)
                                }
                                .buttonStyle(.plain)
                                .help("先自动锁定画面主体再提取去背景色板")
                            }
                        }

                        if !asset.dominantColors.isEmpty {
                            CharkleColorSwatchStrip(
                                hexColors: asset.dominantColors.prefix(6).map(\.hex),
                                height: 24,
                                onCopyHex: onCopyHex,
                                onFilterByColor: onFilterByColor
                            )
                        }
                    }
                }

                VStack(alignment: .leading, spacing: 7) {
                    HStack(spacing: 6) {
                        if showsPalette {
                            Text("标签")
                                .font(CharkleTheme.text(.caption, weight: .medium))
                                .foregroundStyle(CharkleTheme.secondaryInk(for: colorScheme))
                        }
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
                                        Text(asset.suggestedTags.isEmpty ? "智能打标" : "重新打标")
                                    }
                                }
                                .font(CharkleTheme.text(.caption, weight: .medium))
                                .foregroundStyle(isRetaggingThis ? Color.secondary : accentColor)
                            }
                            .buttonStyle(.plain)
                            .disabled(isRetaggingThis)
                            .help("重新生成建议标签（保留已添加标签）")
                        }
                    }

                    if !asset.tags.isEmpty {
                        CharkleFlowLayout(spacing: 6, lineSpacing: 6) {
                            ForEach(asset.tags, id: \.self) { tag in
                                HStack(spacing: 4) {
                                    Text("#\(tag)")
                                        .font(CharkleTheme.text(.caption, weight: .medium))
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
                                .background(
                                    CharkleTheme.surfaceSubtle(for: colorScheme),
                                    in: Capsule(style: .continuous)
                                )
                            }
                        }
                    }

                    inspectorTextField(placeholder: "添加标签，回车确认…", text: $newTagInput, systemImage: "number") {
                        let val = newTagInput.trimmingCharacters(in: .whitespacesAndNewlines)
                        newTagInput = ""
                        guard !val.isEmpty else { return }
                        Task { await library.addTags([val], to: [asset.id]) }
                    }

                    if !asset.suggestedTags.isEmpty {
                        VStack(alignment: .leading, spacing: 5) {
                            HStack(spacing: 8) {
                                Text("建议标签")
                                    .font(CharkleTheme.text(.caption, weight: .medium))
                                    .foregroundStyle(CharkleTheme.secondaryInk(for: colorScheme))
                                Spacer()
                                Button("清空") {
                                    Task {
                                        await library.clearSuggestedTags(for: [asset.id])
                                        coordinator.showToast("已清空未采纳的建议标签", icon: "xmark.circle")
                                    }
                                }
                                .font(CharkleTheme.text(.caption, weight: .medium))
                                .buttonStyle(.plain)
                                .foregroundStyle(.secondary)

                                Button("全部采纳") {
                                    Task { await library.acceptAllSuggestedTags(for: [asset.id]) }
                                }
                                .font(CharkleTheme.text(.caption, weight: .medium))
                                .buttonStyle(.plain)
                                .foregroundStyle(accentColor)
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
                                                .font(CharkleTheme.text(.caption, weight: .medium))
                                        }
                                        .foregroundStyle(accentColor)
                                        .padding(.horizontal, 8)
                                        .padding(.vertical, 3.5)
                                        .background(accentSoft, in: Capsule(style: .continuous))
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

    private func singleAssetNotesAndOCRSection(
        _ asset: AssetRecord,
        visibleSections: [InspectorInfoSection],
        showsTopDivider: Bool
    ) -> some View {
        let notesShape = RoundedRectangle(cornerRadius: CharkleTheme.Radius.chip, style: .continuous)

        return CharkleInspectorSection(
            "备注",
            systemImage: nil,
            showsTopDivider: showsTopDivider,
            isReorderHighlighted: isSectionHighlighted(.notesAndOCR),
            reorderActions: reorderActions(for: .notesAndOCR, visibleSections: visibleSections)
        ) {
            VStack(alignment: .leading, spacing: 9) {
                ZStack(alignment: .topLeading) {
                    if notesDraft.isEmpty {
                        Text("添加备注或来源说明…")
                            .font(CharkleTheme.text(.caption))
                            .foregroundStyle(.tertiary)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 8)
                            .allowsHitTesting(false)
                    }
                    TextEditor(text: $notesDraft)
                        .font(CharkleTheme.text(.caption))
                        .scrollContentBackground(.hidden)
                        .scrollIndicators(.hidden)
                        .focused($isNotesFocused)
                        .frame(minHeight: 62, maxHeight: 112)
                        .padding(.horizontal, 5)
                        .padding(.vertical, 4)
                }
                .background(CharkleTheme.inspectorFieldSurface(for: colorScheme), in: notesShape)
                .overlay(
                    notesShape.strokeBorder(
                        isNotesFocused ? accentBorder : CharkleTheme.hairline(for: colorScheme),
                        lineWidth: isNotesFocused ? 1.0 : CharkleTheme.hairlineWidth
                    )
                )
                .onChange(of: notesDraft) { _, newValue in
                    if newValue != asset.notes {
                        scheduleNotesSave(assetID: asset.id, notes: newValue)
                    }
                }

                if let ocr = asset.ocrText, !ocr.isEmpty {
                    CharkleDisclosureGroup(
                        isExpanded: $isOCRExpanded,
                        showsTopDivider: true,
                        accentChevronWhenExpanded: true
                    ) {
                        Text(ocr)
                            .font(CharkleTheme.text(.caption))
                            .foregroundStyle(.secondary)
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.top, 4)
                    } label: {
                        Text("识别文本")
                            .font(CharkleTheme.text(.caption, weight: .medium))
                            .foregroundStyle(CharkleTheme.secondaryInk(for: colorScheme))
                    }
                }

                if let aiDesc = asset.aiDescription, !aiDesc.isEmpty {
                    CharkleHairlineDivider()
                    VStack(alignment: .leading, spacing: 4) {
                        Text("画面描述")
                            .font(CharkleTheme.text(.caption, weight: .medium))
                            .foregroundStyle(CharkleTheme.secondaryInk(for: colorScheme))
                        Text(aiDesc)
                            .font(CharkleTheme.text(.caption))
                            .foregroundStyle(.secondary)
                            .textSelection(.enabled)
                    }
                }
            }
        }
    }

    private func documentExtentSummary(for asset: AssetRecord) -> String? {
        guard let doc = asset.richMetadata?.document else { return nil }
        var parts: [String] = []
        if !doc.sheetNames.isEmpty {
            parts.append("\(doc.sheetNames.count) 工作表")
        } else if doc.pageCount > 0 {
            parts.append("\(doc.pageCount) 页")
        }
        if doc.wordCount > 0 {
            parts.append("\(doc.wordCount.formatted()) 字")
        }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    private func singleAssetMediaSpecsSection(
        _ asset: AssetRecord,
        resolvedExif: PhotoExifMetadata?,
        visibleSections: [InspectorInfoSection],
        showsTopDivider: Bool
    ) -> some View {
        CharkleInspectorSection(
            "信息",
            systemImage: nil,
            showsTopDivider: showsTopDivider,
            isReorderHighlighted: isSectionHighlighted(.mediaSpecs),
            reorderActions: reorderActions(for: .mediaSpecs, visibleSections: visibleSections)
        ) {
            VStack(spacing: 2) {
                CharkleSpecRow("格式", value: asset.displayTypeLabel)

                if asset.mediaKind == .document {
                    if let docExtent = documentExtentSummary(for: asset) {
                        CharkleSpecRow("篇幅", value: docExtent)
                    }
                } else {
                    CharkleSpecRow(
                        "尺寸",
                        value: "\(asset.pixelWidth) × \(asset.pixelHeight) (\(asset.aspectShape.localizedLabel))",
                        copyable: true,
                        copyValue: "\(asset.pixelWidth)×\(asset.pixelHeight)"
                    ) { _ in
                        coordinator.showToast("已复制尺寸 \(asset.pixelWidth)×\(asset.pixelHeight)", icon: "doc.on.doc")
                    }
                }

                CharkleSpecRow("大小", value: ByteCountFormatter.string(fromByteCount: asset.fileSizeBytes, countStyle: .file))

                if let duration = asset.durationSeconds {
                    CharkleSpecRow("时长", value: CanvasFormatters.durationString(duration))
                }
                if let exif = resolvedExif, !exif.hasMeaningfulCameraExif {
                    if let profile = exif.colorProfile {
                        CharkleSpecRow("色彩空间", value: profile)
                    }
                    if exif.bitDepth != nil || exif.dpiWidth != nil {
                        let depthDPI = [
                            exif.bitDepth.map { "\($0)-bit" },
                            exif.dpiWidth.map { "\($0) DPI" }
                        ].compactMap { $0 }.joined(separator: " / ")
                        if !depthDPI.isEmpty {
                            CharkleSpecRow("色深 / 分辨率", value: depthDPI)
                        }
                    }
                }
                CharkleSpecRow("添加时间", value: Self.mediaTimestampFormatter.string(from: asset.createdAt))
                CharkleSpecRow("原文件状态", value: asset.isLocalOriginalCached ? "已缓存本地" : "云端按需拉取")

                if let urlStr = asset.sourceURL, let url = URL(string: urlStr) {
                    HStack(alignment: .firstTextBaseline, spacing: 10) {
                        Text("来源")
                            .font(CharkleTheme.text(.caption))
                            .foregroundStyle(CharkleTheme.secondaryInk(for: colorScheme))
                        Spacer(minLength: 6)
                        Link(asset.sourceDomain ?? url.host ?? "打开链接", destination: url)
                            .font(CharkleTheme.text(.caption, weight: .medium))
                            .lineLimit(1)
                    }
                    .padding(.vertical, 4)

                    if asset.isExternalWebLink {
                        HStack(spacing: 6) {
                            Button {
                                library.markAssetOpened(asset.id)
                                NSWorkspace.shared.open(url)
                            } label: {
                                Label("默认浏览器打开", systemImage: "safari")
                            }
                            .buttonStyle(.charkle(.accent, size: .xs, fullWidth: true))

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
                            }
                            .buttonStyle(.charkle(.standard, size: .icon, iconDimension: 24))
                            .help("重新抓取网页标题与缩略图")
                        }
                        .padding(.top, 6)
                    }
                }
            }
        }
    }

    private func singleAssetGitHubRepoSection(
        _ asset: AssetRecord,
        repo: GitHubRepoMetadata,
        visibleSections: [InspectorInfoSection],
        showsTopDivider: Bool
    ) -> some View {
        CharkleInspectorSection(
            "仓库信息",
            systemImage: nil,
            showsTopDivider: showsTopDivider,
            isReorderHighlighted: isSectionHighlighted(.githubRepo),
            reorderActions: reorderActions(for: .githubRepo, visibleSections: visibleSections)
        ) {
            VStack(alignment: .leading, spacing: 8) {
                VStack(spacing: 2) {
                    CharkleSpecRow("Stars", value: "\(repo.stars)")
                    CharkleSpecRow("Forks", value: "\(repo.forks)")
                    if let lang = repo.language, !lang.isEmpty {
                        CharkleSpecRow("主要语言", value: lang)
                    }
                }

                Button {
                    onOpenQuickLook(asset)
                } label: {
                    Label("阅读完整 README", systemImage: "doc.richtext")
                }
                .buttonStyle(.charkle(.standard, size: .sm, fullWidth: true))
            }
        }
    }

    private func singleAssetSocialExtractSection(
        _ asset: AssetRecord,
        post: SocialPostMetadata,
        visibleSections: [InspectorInfoSection],
        showsTopDivider: Bool
    ) -> some View {
        let attachments = post.effectiveAttachments
        return CharkleInspectorSection(
            "媒体提取",
            systemImage: nil,
            showsTopDivider: showsTopDivider,
            isReorderHighlighted: isSectionHighlighted(.socialMediaExtract),
            reorderActions: reorderActions(for: .socialMediaExtract, visibleSections: visibleSections)
        ) {
            Text("\(attachments.count) 项")
                .font(CharkleTheme.text(.caption, weight: .medium))
                .monospacedDigit()
                .foregroundStyle(.tertiary)
        } content: {
            VStack(alignment: .leading, spacing: 7) {
                if post.hasVideoSummaryContent {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("视频摘要")
                            .font(CharkleTheme.text(.caption, weight: .semibold))
                            .foregroundStyle(.secondary)
                        if let summary = post.videoSummary?.trimmingCharacters(in: .whitespacesAndNewlines), !summary.isEmpty {
                            Text(summary)
                                .font(CharkleTheme.text(.caption))
                                .foregroundStyle(.primary.opacity(0.88))
                                .lineLimit(5)
                                .textSelection(.enabled)
                        }
                        if !post.videoOutline.isEmpty {
                            Text(post.videoOutline.prefix(4).joined(separator: "\n"))
                                .font(CharkleTheme.text(.caption))
                                .foregroundStyle(.secondary)
                                .lineLimit(4)
                        }
                    }
                    .padding(8)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(CharkleTheme.inspectorFieldSurface(for: colorScheme), in: RoundedRectangle(cornerRadius: CharkleTheme.Radius.chip, style: .continuous))
                }

                Text(
                    post.isZeroDownloadVideoBookmark
                        ? "默认仅保存封面、链接与摘要；点击下方按钮即可按需下载视频并存为独立素材。"
                        : "可将帖子里的图片或视频单独存为素材，并自动保留原作者、正文与链接。"
                )
                    .font(CharkleTheme.text(.caption))
                    .foregroundStyle(.secondary)
                if attachments.count > 1 && !post.isZeroDownloadVideoBookmark {
                    Button {
                        Task {
                            let extracted = await library.extractAllMediaFromSocialPost(postAsset: asset)
                            if !extracted.isEmpty {
                                coordinator.showToast("已全部提取 \(extracted.count) 项媒体为独立素材", icon: "square.and.arrow.down.on.square")
                            } else if let err = library.lastError {
                                coordinator.showToast(err, icon: "exclamationmark.triangle", tone: .warning)
                            }
                        }
                    } label: {
                        Label("全部提取为独立素材（\(attachments.count) 项）", systemImage: "square.and.arrow.down.on.square")
                    }
                    .buttonStyle(.charkle(.accent, size: .sm, fullWidth: true))
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
                                coordinator.showToast("已保存「\(extracted.title)」为独立素材", icon: isVideoLike ? "film" : "photo.badge.plus")
                            } else if let err = library.lastError {
                                coordinator.showToast(err, icon: "exclamationmark.triangle", tone: .warning)
                            }
                        }
                    } label: {
                        Label(
                            post.isZeroDownloadVideoBookmark
                                ? "保存视频为独立素材"
                                : "提取第 \(idx + 1) 个\(attachment.kind.localizedLabel)为独立素材",
                            systemImage: isVideoLike ? "film" : "photo.badge.plus"
                        )
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .buttonStyle(.charkle(post.isZeroDownloadVideoBookmark ? .accent : .standard, size: .xs, fullWidth: true))
                }
            }
        }
    }

    private func singleAssetWebPageExtractSection(
        _ asset: AssetRecord,
        web: WebPageRichMetadata,
        visibleSections: [InspectorInfoSection],
        showsTopDivider: Bool
    ) -> some View {
        let attachments = web.attachments
        return CharkleInspectorSection(
            "网页内容",
            systemImage: nil,
            showsTopDivider: showsTopDivider,
            isReorderHighlighted: isSectionHighlighted(.socialMediaExtract),
            reorderActions: reorderActions(for: .socialMediaExtract, visibleSections: visibleSections)
        ) {
            VStack(alignment: .leading, spacing: 7) {
                if let summary = web.summary?.trimmingCharacters(in: .whitespacesAndNewlines), !summary.isEmpty {
                    Text(summary)
                        .font(CharkleTheme.text(.caption))
                        .foregroundStyle(.primary.opacity(0.88))
                        .lineLimit(5)
                        .textSelection(.enabled)
                        .padding(8)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(CharkleTheme.inspectorFieldSurface(for: colorScheme), in: RoundedRectangle(cornerRadius: CharkleTheme.Radius.chip, style: .continuous))
                }

                if attachments.count > 1 {
                    Button {
                        Task {
                            let extracted = await library.extractAllMediaFromLinkAsset(asset)
                            if !extracted.isEmpty {
                                coordinator.showToast("已从网页提取 \(extracted.count) 项独立素材", icon: "square.and.arrow.down.on.square")
                            } else if let err = library.lastError {
                                coordinator.showToast(err, icon: "exclamationmark.triangle", tone: .warning)
                            }
                        }
                    } label: {
                        Label("全部提取网页媒体（\(attachments.count) 项）", systemImage: "square.and.arrow.down.on.square")
                    }
                    .buttonStyle(.charkle(.accent, size: .sm, fullWidth: true))
                }

                ForEach(Array(attachments.prefix(6).enumerated()), id: \.offset) { idx, attachment in
                    let isVideoLike = attachment.kind == .video || attachment.kind == .gif
                    Button {
                        Task {
                            if let extracted = await library.extractMediaFromWebPageAsset(
                                webAsset: asset,
                                attachment: attachment,
                                index: idx
                            ) {
                                coordinator.showToast("已保存「\(extracted.title)」为独立素材", icon: isVideoLike ? "film" : "photo.badge.plus")
                            } else if let err = library.lastError {
                                coordinator.showToast(err, icon: "exclamationmark.triangle", tone: .warning)
                            }
                        }
                    } label: {
                        Label(
                            isVideoLike ? "保存网页视频为独立素材" : "提取网页第 \(idx + 1) 张图片为独立素材",
                            systemImage: isVideoLike ? "film" : "photo.badge.plus"
                        )
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .buttonStyle(.charkle(isVideoLike ? .accent : .standard, size: .xs, fullWidth: true))
                }
            }
        }
    }

    // MARK: - AI Generation Prompt & Photo EXIF Inspector Sections

    private func aiGenerationInspectorSection(
        _ aiGen: AIGenerationMetadata,
        visibleSections: [InspectorInfoSection],
        showsTopDivider: Bool
    ) -> some View {
        CharkleInspectorSection(
            "生成参数",
            systemImage: nil,
            showsTopDivider: showsTopDivider,
            isReorderHighlighted: isSectionHighlighted(.aiGeneration),
            reorderActions: reorderActions(for: .aiGeneration, visibleSections: visibleSections)
        ) {
            if let generator = aiGen.generator, !generator.isEmpty {
                Text(generator)
                    .font(CharkleTheme.text(.caption, weight: .semibold))
                    .foregroundStyle(accentColor)
                    .padding(.horizontal, 6.5)
                    .padding(.vertical, 2)
                    .background(accentSoft, in: Capsule(style: .continuous))
                    .lineLimit(1)
            }
        } content: {
            VStack(alignment: .leading, spacing: 9) {
                if let prompt = aiGen.prompt, !prompt.isEmpty {
                    VStack(alignment: .leading, spacing: 5) {
                        HStack {
                            Text("正向提示词")
                                .font(CharkleTheme.text(.caption, weight: .medium))
                                .foregroundStyle(CharkleTheme.secondaryInk(for: colorScheme))
                            Spacer()
                            Button {
                                copyInspectorText(prompt, toast: "已复制正向 Prompt")
                            } label: {
                                Label("复制", systemImage: "doc.on.doc")
                                    .font(CharkleTheme.text(.caption, weight: .medium))
                                    .foregroundStyle(accentColor)
                            }
                            .buttonStyle(.plain)
                        }

                        Text(prompt)
                            .font(CharkleTheme.text(.caption))
                            .foregroundStyle(.primary.opacity(0.90))
                            .lineSpacing(3.5)
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(8)
                            .background(
                                CharkleTheme.inspectorFieldSurface(for: colorScheme),
                                in: RoundedRectangle(cornerRadius: CharkleTheme.Radius.chip, style: .continuous)
                            )
                    }
                }

                if let neg = aiGen.negativePrompt, !neg.isEmpty {
                    VStack(alignment: .leading, spacing: 5) {
                        HStack {
                            Text("负向提示词")
                                .font(CharkleTheme.text(.caption, weight: .medium))
                                .foregroundStyle(CharkleTheme.secondaryInk(for: colorScheme))
                            Spacer()
                            Button {
                                copyInspectorText(neg, toast: "已复制负向 Prompt")
                            } label: {
                                Label("复制", systemImage: "doc.on.doc")
                                    .font(CharkleTheme.text(.caption, weight: .medium))
                                    .foregroundStyle(.secondary)
                            }
                            .buttonStyle(.plain)
                        }

                        Text(neg)
                            .font(CharkleTheme.text(.caption))
                            .foregroundStyle(.secondary)
                            .lineSpacing(3)
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(8)
                            .background(
                                CharkleTheme.inspectorFieldSurface(for: colorScheme),
                                in: RoundedRectangle(cornerRadius: CharkleTheme.Radius.chip, style: .continuous)
                            )
                    }
                }

                let paramRows: [(label: String, value: String, monospaced: Bool, copyable: Bool)] = {
                    var list: [(String, String, Bool, Bool)] = []
                    if let model = aiGen.modelName, !model.isEmpty {
                        let modelLabel = aiGen.modelHash.map { "\(model) (\($0))" } ?? model
                        list.append(("模型", modelLabel, false, true))
                    }
                    if let sampler = aiGen.sampler, !sampler.isEmpty {
                        let samplerLabel = aiGen.scheduler.map { "\(sampler) / \($0)" } ?? sampler
                        list.append(("采样器", samplerLabel, false, false))
                    }
                    if aiGen.steps != nil || aiGen.cfgScale != nil {
                        let parts = [
                            aiGen.steps.map { "\($0) 步" },
                            aiGen.cfgScale.map { String(format: "CFG %.1f", $0).replacingOccurrences(of: ".0", with: "") }
                        ].compactMap { $0 }.joined(separator: " / ")
                        list.append(("步数 / CFG", parts, false, false))
                    }
                    if let seed = aiGen.seed, !seed.isEmpty {
                        list.append(("随机种子", seed, true, true))
                    }
                    if let sizeText = aiGen.sizeText, !sizeText.isEmpty {
                        list.append(("生成尺寸", sizeText, true, false))
                    }
                    if let clip = aiGen.clipSkip {
                        list.append(("Clip Skip", "\(clip)", true, false))
                    }
                    return list
                }()

                if !paramRows.isEmpty {
                    VStack(spacing: 2) {
                        ForEach(Array(paramRows.enumerated()), id: \.offset) { _, row in
                            CharkleSpecRow(
                                row.label,
                                value: row.value,
                                monospaced: row.monospaced,
                                copyable: row.copyable
                            ) { copied in
                                coordinator.showToast("已复制\(row.label)：\(copied)", icon: "doc.on.doc")
                            }
                        }
                    }
                }

                if !aiGen.loras.isEmpty {
                    VStack(alignment: .leading, spacing: 5) {
                        Text("LoRA")
                            .font(CharkleTheme.text(.caption, weight: .medium))
                            .foregroundStyle(CharkleTheme.secondaryInk(for: colorScheme))
                        CharkleFlowLayout(spacing: 5, lineSpacing: 5) {
                            ForEach(aiGen.loras, id: \.self) { lora in
                                Text(lora)
                                    .font(CharkleTheme.text(.caption, weight: .medium, design: .monospaced))
                                    .foregroundStyle(.primary.opacity(0.85))
                                    .padding(.horizontal, 7)
                                    .padding(.vertical, 3)
                                    .background(
                                        CharkleTheme.surfaceSubtle(for: colorScheme),
                                        in: RoundedRectangle(cornerRadius: CharkleTheme.Radius.sm, style: .continuous)
                                    )
                            }
                        }
                    }
                }

                if let raw = aiGen.rawParameters, !raw.isEmpty {
                    Button {
                        copyInspectorText(raw, toast: "已复制完整生图参数")
                    } label: {
                        Label("复制完整生图参数", systemImage: "square.on.square")
                    }
                    .buttonStyle(.charkle(.standard, size: .xs, fullWidth: true))
                }
            }
        }
    }

    private func photoExifInspectorSection(
        _ exif: PhotoExifMetadata,
        visibleSections: [InspectorInfoSection],
        showsTopDivider: Bool
    ) -> some View {
        CharkleInspectorSection(
            "拍摄参数",
            systemImage: nil,
            showsTopDivider: showsTopDivider,
            isReorderHighlighted: isSectionHighlighted(.photoExif),
            reorderActions: reorderActions(for: .photoExif, visibleSections: visibleSections)
        ) {
            VStack(alignment: .leading, spacing: 8) {
                if let summary = exif.exposureSummary {
                    Text(summary)
                        .font(CharkleTheme.text(.caption, weight: .semibold, design: .monospaced))
                        .monospacedDigit()
                        .foregroundStyle(.primary)
                        .frame(maxWidth: .infinity, alignment: .center)
                        .padding(.vertical, 6.5)
                        .padding(.horizontal, 8)
                        .background(
                            CharkleTheme.inspectorFieldSurface(for: colorScheme),
                            in: RoundedRectangle(cornerRadius: CharkleTheme.Radius.chip, style: .continuous)
                        )
                }

                VStack(spacing: 2) {
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
                            ].compactMap { $0 }.joined(separator: " / ")
                            list.append(("色深 / 分辨率", parts))
                        }
                        if let sw = exif.software { list.append(("软件", sw)) }
                        if let artist = exif.artist { list.append(("作者", artist)) }
                        if let copy = exif.copyright { list.append(("版权", copy)) }
                        return list
                    }()

                    ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
                        CharkleSpecRow(row.0, value: row.1)
                    }

                    if let lat = exif.latitude, let lon = exif.longitude {
                        let coordText = String(format: "%.5f, %.5f", lat, lon)
                        let mapsURL = URL(string: "https://maps.apple.com/?ll=\(lat),\(lon)")
                        HStack(alignment: .firstTextBaseline, spacing: 10) {
                            Text("拍摄位置")
                                .font(CharkleTheme.text(.caption))
                                .foregroundStyle(CharkleTheme.secondaryInk(for: colorScheme))
                            Spacer(minLength: 6)
                            if let mapsURL {
                                Link(destination: mapsURL) {
                                    HStack(spacing: 3) {
                                        Image(systemName: "mappin.and.ellipse")
                                            .font(.system(size: 10))
                                        Text(coordText)
                                            .font(CharkleTheme.text(.caption, weight: .medium, design: .monospaced))
                                            .monospacedDigit()
                                    }
                                }
                                .help("在 Apple 地图中查看拍摄位置")
                            } else {
                                Text(coordText)
                                    .font(CharkleTheme.text(.caption, design: .monospaced))
                                    .monospacedDigit()
                            }
                        }
                        .padding(.vertical, 4)
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
            VStack(alignment: .leading, spacing: 0) {
                // Section 1: Selection Overview + Primary Action
                VStack(alignment: .leading, spacing: 10) {
                    VStack(alignment: .leading, spacing: 3) {
                        Text("已选中 \(ids.count) 项素材")
                            .font(CharkleTheme.text(.headline, weight: .semibold))
                            .monospacedDigit()
                        Text(isTrashSelection ? "这些素材当前位于废纸篓，可恢复到原位置或彻底删除" : "批量归档、添加标签或加入情绪板")
                            .font(CharkleTheme.text(.caption))
                            .foregroundStyle(.secondary)
                    }

                    if isTrashSelection {
                        VStack(spacing: 7) {
                            Button {
                                Task {
                                    await library.restoreAssets(ids)
                                    coordinator.showToast("已将 \(ids.count) 项放回原处", icon: "arrow.uturn.backward")
                                }
                            } label: {
                                Label("全部放回原处", systemImage: "arrow.uturn.backward")
                            }
                            .buttonStyle(.charkle(.accent, size: .sm, fullWidth: true))

                            Button(role: .destructive) {
                                pendingPermanentDeleteIDs = ids
                            } label: {
                                Label("彻底删除所选 \(ids.count) 项", systemImage: "trash.slash")
                            }
                            .buttonStyle(.charkle(.destructive, size: .sm, fullWidth: true))
                        }
                    } else {
                        VStack(spacing: 7) {
                            Button {
                                Task {
                                    if let board = await moodboards.createBoardFromSelection(assetIDs: ids, title: "灵感合集 (\(ids.count))") {
                                        coordinator.openMoodboard(board.id)
                                        coordinator.showToast("已用 \(ids.count) 项素材生成情绪板", icon: "sparkles.rectangle.stack")
                                    }
                                }
                            } label: {
                                Label("从所选生成情绪板", systemImage: "sparkles.rectangle.stack")
                            }
                            .buttonStyle(.charkle(.accent, size: .sm, fullWidth: true))

                            Button {
                                let anchorID = selectedAssets.last?.id
                                Task {
                                    let merged = await library.mergeAssetsIntoVersionStack(ids, targetAssetID: anchorID)
                                    if !merged.isEmpty {
                                        coordinator.showToast("已将 \(ids.count) 项合并为历史版本", icon: "square.stack.3d.up.fill", tone: .success)
                                    }
                                }
                            } label: {
                                Label("合并版本（\(ids.count) 项）", systemImage: "square.stack.3d.up")
                            }
                            .buttonStyle(.charkle(.standard, size: .sm, fullWidth: true))
                        }
                    }
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 12)

                if !isTrashSelection {
                    // Section 2: Bulk Organize
                    CharkleInspectorSection("批量整理", systemImage: nil, showsTopDivider: true) {
                        VStack(alignment: .leading, spacing: 10) {
                            VStack(alignment: .leading, spacing: 5) {
                                Text("移动到文件夹")
                                    .font(CharkleTheme.text(.caption, weight: .medium))
                                    .foregroundStyle(CharkleTheme.secondaryInk(for: colorScheme))
                                Menu {
                                    CharkleHierarchicalFolderMenuContent(
                                        folders: library.folders,
                                        includeInbox: true,
                                        parentSelfPrefix: "放入"
                                    ) { folderID in
                                        Task { await library.moveAssets(ids, toFolderID: folderID) }
                                    }
                                } label: {
                                    inspectorStandardMenuLabel(
                                        title: "选择目标文件夹…",
                                        systemImage: "folder",
                                        showsChevron: true
                                    )
                                }
                                .menuStyle(.button)
                                .buttonStyle(CharkleButtonStyle(.standard, size: .sm, fullWidth: true))
                                .menuIndicator(.hidden)
                            }

                            CharkleHairlineDivider()

                            VStack(alignment: .leading, spacing: 6) {
                                Text("批量添加标签")
                                    .font(CharkleTheme.text(.caption, weight: .medium))
                                    .foregroundStyle(CharkleTheme.secondaryInk(for: colorScheme))
                                inspectorTextField(placeholder: "输入标签回车批量添加…", text: $batchTagInput, systemImage: "number") {
                                    let val = batchTagInput.trimmingCharacters(in: .whitespacesAndNewlines)
                                    batchTagInput = ""
                                    guard !val.isEmpty else { return }
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
                                        Text("\(library.enrichEngineLabel.isEmpty ? "正在重新打标" : library.enrichEngineLabel) (\(library.enrichCompletedCount)/\(max(1, library.enrichTotalCount)))…")
                                            .font(CharkleTheme.text(.caption, weight: .medium))
                                            .foregroundStyle(.secondary)
                                            .monospacedDigit()
                                            .lineLimit(1)
                                        Spacer()
                                        Button("停止") {
                                            library.cancelRetagging()
                                        }
                                        .font(CharkleTheme.text(.caption, weight: .medium))
                                        .buttonStyle(.plain)
                                        .foregroundStyle(CharkleTheme.destructive(for: colorScheme))
                                    }
                                    .padding(.horizontal, 10)
                                    .padding(.vertical, 7)
                                    .background(
                                        CharkleTheme.inspectorFieldSurface(for: colorScheme),
                                        in: RoundedRectangle(cornerRadius: CharkleTheme.Radius.chip, style: .continuous)
                                    )
                                } else {
                                    Button {
                                        runInspectorRetagging(for: ids)
                                    } label: {
                                        Label("AI 批量重新打标（\(ids.count) 项）", systemImage: "sparkles")
                                            .frame(maxWidth: .infinity, alignment: .leading)
                                    }
                                    .buttonStyle(.charkle(.standard, size: .sm, fullWidth: true))
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
                                        .font(CharkleTheme.text(.caption, weight: .medium))
                                        .buttonStyle(.plain)
                                        .foregroundStyle(accentColor)

                                        Spacer()

                                        Button("清空建议") {
                                            Task {
                                                await library.clearSuggestedTags(for: ids)
                                                coordinator.showToast("已清空所选素材的未采纳建议标签", icon: "xmark.circle")
                                            }
                                        }
                                        .font(CharkleTheme.text(.caption, weight: .medium))
                                        .buttonStyle(.plain)
                                        .foregroundStyle(.secondary)
                                    }
                                }
                            }

                            CharkleHairlineDivider()

                            VStack(alignment: .leading, spacing: 6) {
                                HStack {
                                    Text("批量评分")
                                        .font(CharkleTheme.text(.caption, weight: .medium))
                                        .foregroundStyle(CharkleTheme.secondaryInk(for: colorScheme))
                                    Spacer()
                                    Button("清除评分") {
                                        Task { await library.setRating(0, for: ids) }
                                    }
                                    .font(CharkleTheme.text(.caption))
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

                    // Section 3: Offline & Destructive Actions
                    CharkleInspectorSection("本地与操作", systemImage: nil, showsTopDivider: true) {
                        let allKeptLocally = !selectedAssets.isEmpty && selectedAssets.allSatisfy(\.pinnedOffline)
                        VStack(spacing: 7) {
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
                                .frame(maxWidth: .infinity, alignment: .leading)
                            }
                            .buttonStyle(.charkle(.standard, size: .sm, fullWidth: true))

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
                                    .frame(maxWidth: .infinity, alignment: .leading)
                            }
                            .buttonStyle(.charkle(.destructive, size: .sm, fullWidth: true))
                        }
                    }
                }
            }
            .padding(.bottom, 12)
            .charkleCleanScrollbars(hidden: true)
        }
        .scrollIndicators(.hidden)
    }

    // MARK: - 3. Moodboard Right Rail (De-Cardified Hairline Sections)

    private func moodboardRightRail(_ board: MoodboardDocument) -> some View {
        let isActiveNotchBoard = coordinator.activeMoodboardID == board.id
        let quickAddResults = quickAddFilteredAssets(excluding: Set(board.referencedAssetIDs))
        let isSwapping = moodboards.swappingNodeID != nil

        return ScrollView(.vertical) {
            VStack(alignment: .leading, spacing: 0) {
                // Section 1: Board Identity & Status Controls
                VStack(alignment: .leading, spacing: 8) {
                    TextField("情绪板名称", text: $boardTitleDraft)
                        .textFieldStyle(.plain)
                        .font(CharkleTheme.text(.headline, weight: .semibold))
                        .focused($isBoardTitleFocused)
                        .onSubmit { commitBoardHeader(board) }
                        .padding(.horizontal, 9)
                        .padding(.vertical, 6)
                        .background(
                            CharkleTheme.inspectorFieldSurface(for: colorScheme),
                            in: RoundedRectangle(cornerRadius: CharkleTheme.Radius.chip, style: .continuous)
                        )
                        .overlay(
                            RoundedRectangle(cornerRadius: CharkleTheme.Radius.chip, style: .continuous)
                                .strokeBorder(isBoardTitleFocused ? accentBorder : Color.clear, lineWidth: 1)
                        )

                    TextField("补充创作 Brief 或氛围备注…", text: $boardSubtitleDraft)
                        .textFieldStyle(.plain)
                        .font(CharkleTheme.text(.caption))
                        .foregroundStyle(.secondary)
                        .focused($isBoardSubtitleFocused)
                        .onSubmit { commitBoardHeader(board) }
                        .padding(.horizontal, 9)
                        .padding(.vertical, 5.5)
                        .background(
                            CharkleTheme.inspectorFieldSurface(for: colorScheme),
                            in: RoundedRectangle(cornerRadius: CharkleTheme.Radius.chip, style: .continuous)
                        )
                        .overlay(
                            RoundedRectangle(cornerRadius: CharkleTheme.Radius.chip, style: .continuous)
                                .strokeBorder(isBoardSubtitleFocused ? accentBorder : Color.clear, lineWidth: 1)
                        )

                    HStack(spacing: 6) {
                        Button {
                            coordinator.activeMoodboardID = board.id
                            coordinator.showToast("已设为刘海活跃情绪板", icon: "checkmark.circle.fill")
                        } label: {
                            HStack(spacing: 5) {
                                Circle()
                                    .fill(isActiveNotchBoard ? CharkleTheme.positive(for: colorScheme) : Color.secondary.opacity(0.4))
                                    .frame(width: 6, height: 6)
                                Text(isActiveNotchBoard ? "当前活跃板" : "设为活跃板")
                                    .font(CharkleTheme.text(.caption, weight: .medium))
                            }
                            .foregroundStyle(isActiveNotchBoard ? Color.primary : CharkleTheme.secondaryInk(for: colorScheme))
                            .padding(.horizontal, 8)
                            .frame(height: 24)
                            .background(
                                CharkleTheme.inspectorFieldSurface(for: colorScheme),
                                in: RoundedRectangle(cornerRadius: CharkleTheme.Radius.chip, style: .continuous)
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
                                Image(systemName: "arrow.down.circle")
                                    .symbolVariant(board.pinnedOffline ? .fill : .none)
                                    .font(.system(size: 11))
                                Text(board.pinnedOffline ? "已保留本地" : "始终保留本地")
                                    .font(CharkleTheme.text(.caption, weight: .medium))
                            }
                            .foregroundStyle(board.pinnedOffline ? accentColor : CharkleTheme.secondaryInk(for: colorScheme))
                            .padding(.horizontal, 8)
                            .frame(height: 24)
                            .background(
                                board.pinnedOffline ? accentSoft : CharkleTheme.inspectorFieldSurface(for: colorScheme),
                                in: RoundedRectangle(cornerRadius: CharkleTheme.Radius.chip, style: .continuous)
                            )
                        }
                        .buttonStyle(CharkleTactileButtonStyle())
                        .help(board.pinnedOffline ? "整板素材已始终保留在本机，离线可用" : "始终将此情绪板引用的素材保留在本机")
                    }
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 12)

                // Section 2: In-Canvas AI Curator Assistant
                moodboardCuratorSection(board)

                // Section 3: Candidate Swap Pool
                CharkleInspectorSection(
                    isSwapping ? "候选替换" : "候选素材",
                    systemImage: nil,
                    showsTopDivider: true
                ) {
                    if isSwapping {
                        Button("取消替换") {
                            moodboards.swappingNodeID = nil
                        }
                        .font(CharkleTheme.text(.caption, weight: .medium))
                        .foregroundStyle(accentColor)
                        .buttonStyle(.plain)
                    } else if !moodboards.candidatePool.isEmpty {
                        Text("\(min(24, moodboards.candidatePool.count)) 项")
                            .font(CharkleTheme.text(.caption, weight: .medium))
                            .monospacedDigit()
                            .foregroundStyle(.tertiary)
                    }
                } content: {
                    VStack(alignment: .leading, spacing: 8) {
                        if let swapNodeID = moodboards.swappingNodeID {
                            HStack(spacing: 6) {
                                Image(systemName: "arrow.triangle.2.circlepath")
                                    .font(.system(size: 10.5, weight: .semibold))
                                    .foregroundStyle(accentColor)
                                Text("点击下方任意候选图即可原地替换选中卡片")
                                    .font(CharkleTheme.text(.caption, weight: .medium))
                                    .foregroundStyle(.primary.opacity(0.86))
                            }
                            .padding(.horizontal, 9)
                            .padding(.vertical, 6)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(
                                accentSoft,
                                in: RoundedRectangle(cornerRadius: CharkleTheme.Radius.chip, style: .continuous)
                            )
                            .overlay(
                                RoundedRectangle(cornerRadius: CharkleTheme.Radius.chip, style: .continuous)
                                    .strokeBorder(accentBorder, lineWidth: CharkleTheme.hairlineWidth)
                            )
                            .id(swapNodeID)
                            .transition(CharkleMotion.originTransition(anchor: .top, scale: 0.97, reduced: reduceMotion))
                        }

                        if moodboards.candidatePool.isEmpty {
                            Text("暂无更多候选图，可从下方直接检索素材库添加。")
                                .font(CharkleTheme.text(.caption))
                                .foregroundStyle(.tertiary)
                        } else {
                            LazyVGrid(columns: [GridItem(.flexible(), spacing: 8), GridItem(.flexible(), spacing: 8)], spacing: 8) {
                                ForEach(moodboards.candidatePool.prefix(24)) { candidate in
                                    AssetThumbnailSurface(
                                        asset: candidate.asset,
                                        loader: library.thumbnailLoader,
                                        tier: .grid520,
                                        cornerRadius: CharkleTheme.Radius.chip
                                    )
                                    .frame(maxWidth: .infinity)
                                    .frame(height: 84)
                                    .clipShape(RoundedRectangle(cornerRadius: CharkleTheme.Radius.chip, style: .continuous))
                                    .overlay(
                                        RoundedRectangle(cornerRadius: CharkleTheme.Radius.chip, style: .continuous)
                                            .strokeBorder(CharkleTheme.hairline(for: colorScheme), lineWidth: CharkleTheme.hairlineWidth)
                                    )
                                    .contentShape(RoundedRectangle(cornerRadius: CharkleTheme.Radius.chip, style: .continuous))
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
                                            cornerRadius: CharkleTheme.Radius.chip
                                        )
                                        .frame(width: 96, height: 74)
                                        .clipShape(RoundedRectangle(cornerRadius: CharkleTheme.Radius.chip, style: .continuous))
                                    }
                                    .help(
                                        candidate.matchReasons.isEmpty
                                            ? "\(candidate.asset.title)（点击加入或直接拖入画布）"
                                            : "\(candidate.asset.title)（\(candidate.matchReasons.joined(separator: " / "))，点击加入或直接拖入画布）"
                                    )
                                }
                            }
                        }
                    }
                }

                // Section 4: Board Harmonious Palette Strip
                CharkleInspectorSection("全板色板", systemImage: nil, showsTopDivider: true) {
                    Button {
                        Task {
                            await moodboards.syncBoardPalette()
                            coordinator.showToast("已重新提取全板色板", icon: "paintpalette")
                        }
                    } label: {
                        HStack(spacing: 3) {
                            Image(systemName: "arrow.clockwise")
                                .font(.system(size: 9.5, weight: .semibold))
                            Text("重新提取")
                                .font(CharkleTheme.text(.caption, weight: .medium))
                        }
                        .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                    .help("重新分析板内素材并更新色板")
                } content: {
                    if board.extractedPalette.isEmpty {
                        Text("加入素材后将自动提取全板色板。")
                            .font(CharkleTheme.text(.caption))
                            .foregroundStyle(.tertiary)
                    } else {
                        CharkleColorSwatchStrip(
                            hexColors: board.extractedPalette.prefix(7).map(\.hex),
                            height: 24,
                            onCopyHex: onCopyHex
                        )
                    }
                }

                // Section 5: Quick Add from Library Search
                CharkleInspectorSection("添加素材", systemImage: nil, showsTopDivider: true) {
                    VStack(alignment: .leading, spacing: 8) {
                        inspectorTextField(placeholder: "搜索标题、标签或域名…", text: $quickAddQuery, systemImage: "magnifyingglass")

                        if !quickAddResults.isEmpty {
                            LazyVGrid(columns: [GridItem(.flexible(), spacing: 6), GridItem(.flexible(), spacing: 6), GridItem(.flexible(), spacing: 6)], spacing: 6) {
                                ForEach(quickAddResults.prefix(9)) { asset in
                                    AssetThumbnailSurface(
                                        asset: asset,
                                        loader: library.thumbnailLoader,
                                        tier: .grid520,
                                        cornerRadius: CharkleTheme.Radius.sm
                                    )
                                    .frame(maxWidth: .infinity)
                                    .frame(height: 56)
                                    .clipShape(RoundedRectangle(cornerRadius: CharkleTheme.Radius.sm, style: .continuous))
                                    .overlay(
                                        RoundedRectangle(cornerRadius: CharkleTheme.Radius.sm, style: .continuous)
                                            .strokeBorder(CharkleTheme.hairline(for: colorScheme), lineWidth: CharkleTheme.hairlineWidth)
                                    )
                                    .contentShape(RoundedRectangle(cornerRadius: CharkleTheme.Radius.sm, style: .continuous))
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
                                            cornerRadius: CharkleTheme.Radius.sm
                                        )
                                        .frame(width: 84, height: 64)
                                        .clipShape(RoundedRectangle(cornerRadius: CharkleTheme.Radius.sm, style: .continuous))
                                    }
                                    .help("点击加入或拖入画布：\(asset.title)")
                                }
                            }
                        } else if !quickAddQuery.isEmpty {
                            Text("未找到匹配的素材")
                                .font(CharkleTheme.text(.caption))
                                .foregroundStyle(.tertiary)
                        }
                    }
                }

                // Section 6: Export & Delivery (including Figma / FigJam Editable Bridge)
                CharkleInspectorSection("导出与交付", systemImage: nil, showsTopDivider: true) {
                    Button {
                        onOpenFigmaPluginGuide()
                    } label: {
                        HStack(spacing: 3) {
                            Image(systemName: "puzzlepiece.extension")
                                .font(.system(size: 9.5, weight: .semibold))
                            Text("插件指南")
                                .font(CharkleTheme.text(.caption, weight: .medium))
                        }
                        .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                    .help("查看 Figma / FigJam 本地插件安装说明")
                } content: {
                    VStack(spacing: 7) {
                        Button(action: onExportFigmaBundle) {
                            Label("导出到 Figma / FigJam（可编辑图层）", systemImage: "square.stack.3d.up")
                                .lineLimit(1)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        .buttonStyle(.charkle(.accent, size: .sm, fullWidth: true))
                        .help("导出 .charkleboard 离线迁移包，在 Figma / FigJam 中导入为独立可编辑图片、便签、连线和色卡")

                        HStack(spacing: 6) {
                            Button(action: onOpenInPureRef) {
                                Label("PureRef 打开", systemImage: "arrow.up.forward.app")
                                    .lineLimit(1)
                            }
                            .buttonStyle(.charkle(.standard, size: .xs, fullWidth: true))
                            .help("保留当前画布排版与便签，直接生成 .pur 并在 PureRef 中打开")

                            Button(action: onExportPureRef) {
                                Label("导出 .pur", systemImage: "square.grid.2x2")
                                    .lineLimit(1)
                            }
                            .buttonStyle(.charkle(.standard, size: .xs, fullWidth: true))
                            .help("导出标准 PureRef (.pur) 场景文件，保留图片位置、缩放、旋转、裁切与便签")
                        }

                        Button(action: onCopyBoardImage) {
                            Label("复制 2× 高清图（直接 ⌘V 粘贴）", systemImage: "doc.on.clipboard")
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        .buttonStyle(.charkle(.standard, size: .sm, fullWidth: true))

                        HStack(spacing: 6) {
                            Button("保存 PNG") {
                                onSaveBoardImage(.png)
                            }
                            .buttonStyle(.charkle(.standard, size: .xs, fullWidth: true))

                            Button("保存 JPG") {
                                onSaveBoardImage(.jpeg)
                            }
                            .buttonStyle(.charkle(.standard, size: .xs, fullWidth: true))
                        }
                    }
                }
            }
            .padding(.bottom, 12)
            .charkleCleanScrollbars(hidden: true)
            .animation(
                CharkleMotion.enterExit(moodboards.swappingNodeID != nil, reduced: reduceMotion),
                value: moodboards.swappingNodeID != nil
            )
        }
        .scrollIndicators(.hidden)
        .onAppear {
            editingBoardID = board.id
            editingBoardOriginalTitle = board.title
            editingBoardOriginalSubtitle = board.subtitle
            boardTitleDraft = board.title
            boardSubtitleDraft = board.subtitle
        }
        .onChange(of: board.id) { oldID, _ in
            if editingBoardID == oldID {
                flushBoardHeaderIfDirty(
                    boardID: oldID,
                    originalTitle: editingBoardOriginalTitle,
                    originalSubtitle: editingBoardOriginalSubtitle
                )
            }
            editingBoardID = board.id
            editingBoardOriginalTitle = board.title
            editingBoardOriginalSubtitle = board.subtitle
            boardTitleDraft = board.title
            boardSubtitleDraft = board.subtitle
            boardRefinementDraft = ""
            showBoardAgentTrace = false
        }
        .onChange(of: board.title) { _, newTitle in
            editingBoardOriginalTitle = newTitle
            if !isBoardTitleFocused && boardTitleDraft != newTitle {
                boardTitleDraft = newTitle
            }
        }
        .onChange(of: board.subtitle) { _, newSubtitle in
            editingBoardOriginalSubtitle = newSubtitle
            if !isBoardSubtitleFocused && boardSubtitleDraft != newSubtitle {
                boardSubtitleDraft = newSubtitle
            }
        }
        .onChange(of: isBoardTitleFocused) { wasFocused, nowFocused in
            if wasFocused && !nowFocused {
                commitBoardHeader(board)
            }
        }
        .onChange(of: isBoardSubtitleFocused) { wasFocused, nowFocused in
            if wasFocused && !nowFocused {
                commitBoardHeader(board)
            }
        }
        .onDisappear {
            commitBoardHeader(board)
        }
    }

    @ViewBuilder
    private func moodboardCuratorSection(_ board: MoodboardDocument) -> some View {
        CharkleInspectorSection("智能编排", systemImage: nil, showsTopDivider: true) {
            if moodboards.canUndo && !moodboards.isRefiningActiveBoard {
                Button {
                    moodboards.undo()
                    coordinator.showToast("已撤销上一步画布调整", icon: "arrow.uturn.backward")
                } label: {
                    Text("撤销")
                        .font(CharkleTheme.text(.caption, weight: .medium))
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
                        .font(CharkleTheme.text(.caption))
                        .focused($isBoardRefinementFocused)
                        .padding(.horizontal, 9)
                        .frame(height: 28)
                        .background(
                            CharkleTheme.inspectorFieldSurface(for: colorScheme),
                            in: RoundedRectangle(cornerRadius: CharkleTheme.Radius.chip, style: .continuous)
                        )
                        .overlay(
                            RoundedRectangle(cornerRadius: CharkleTheme.Radius.chip, style: .continuous)
                                .strokeBorder(isBoardRefinementFocused ? accentBorder : Color.clear, lineWidth: 1)
                        )
                        .disabled(moodboards.isRefiningActiveBoard)
                        .onSubmit {
                            runBoardRefinement(boardRefinementDraft)
                        }

                    Button {
                        runBoardRefinement(boardRefinementDraft)
                    } label: {
                        if moodboards.isRefiningActiveBoard {
                            ProgressView()
                                .controlSize(.mini)
                                .frame(width: 14, height: 14)
                        } else {
                            Image(systemName: "arrow.up")
                                .font(.system(size: 11.5, weight: .semibold))
                        }
                    }
                    .buttonStyle(.charkle(.accent, size: .icon, iconDimension: 28))
                    .disabled(boardRefinementDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || moodboards.isRefiningActiveBoard)
                    .help("执行 AI 策展微调")
                }

                CharkleFlowLayout(spacing: 5, lineSpacing: 5) {
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
                                .font(CharkleTheme.text(.caption, weight: .semibold))
                            if !activeStep.detail.isEmpty {
                                Text(activeStep.detail)
                                    .font(CharkleTheme.text(.caption))
                                    .foregroundStyle(.secondary)
                                    .lineLimit(2)
                            }
                        }
                    }
                    .padding(.top, 2)
                } else if let summary = moodboards.activeBoardLastSummary, !summary.isEmpty {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(summary)
                            .font(CharkleTheme.text(.caption))
                            .foregroundStyle(.secondary)
                            .lineLimit(3)
                            .fixedSize(horizontal: false, vertical: true)

                        if !moodboards.activeBoardAgentTrace.isEmpty {
                            CharkleDisclosureGroup(
                                isExpanded: $showBoardAgentTrace,
                                headerVerticalPadding: 4,
                                headerHorizontalPadding: 6,
                                negativeHorizontalBleed: 6
                            ) {
                                VStack(alignment: .leading, spacing: 4) {
                                    ForEach(moodboards.activeBoardAgentTrace) { step in
                                        HStack(alignment: .top, spacing: 5) {
                                            Image(systemName: stepIconName(step.status))
                                                .font(.system(size: 9.5))
                                                .foregroundStyle(stepColor(step.status))
                                                .padding(.top, 1.5)
                                            VStack(alignment: .leading, spacing: 1) {
                                                Text(step.title)
                                                    .font(CharkleTheme.text(.caption, weight: .medium))
                                                if !step.detail.isEmpty {
                                                    Text(step.detail)
                                                        .font(CharkleTheme.text(.caption))
                                                        .foregroundStyle(.secondary)
                                                }
                                            }
                                        }
                                    }
                                }
                                .padding(.top, 3)
                            } label: {
                                Text(showBoardAgentTrace ? "收起策展步骤" : "查看策展步骤（\(moodboards.activeBoardAgentTrace.count) 步）")
                                    .font(CharkleTheme.text(.caption, weight: .medium))
                                    .monospacedDigit()
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                    .padding(.top, 2)
                }

                HStack(spacing: 4) {
                    Text("已锁定卡片自动保留，支持 ⌘Z 撤销")
                        .font(CharkleTheme.text(.caption))
                        .foregroundStyle(.tertiary)
                    Spacer()
                    Text("\(board.referencedAssetIDs.count) 张素材")
                        .font(CharkleTheme.text(.caption, weight: .medium))
                        .foregroundStyle(.tertiary)
                        .monospacedDigit()
                        .fixedSize(horizontal: true, vertical: false)
                }
            }
        }
    }

    private func curatorQuickChip(_ title: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(CharkleTheme.text(.caption, weight: .medium))
                .lineLimit(1)
        }
        .buttonStyle(.charkle(.standard, size: .xs))
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
        case .running: return accentColor
        case .done: return CharkleTheme.positive(for: colorScheme)
        case .warning: return CharkleTheme.warning(for: colorScheme)
        }
    }

    private var emptyInspectorPlaceholder: some View {
        VStack(spacing: 12) {
            Spacer()
            CharkleEmptyStateVignette(.emptyInspector, compact: true)
            Text("选择素材查看详情")
                .font(CharkleTheme.text(.body, weight: .semibold))
                .foregroundStyle(.secondary)
            Text("单击卡片查看色板与元数据\n框选多张可生成情绪板")
                .font(CharkleTheme.text(.caption))
                .foregroundStyle(.tertiary)
                .multilineTextAlignment(.center)
            Spacer()
        }
        .padding(24)
    }

    // MARK: - Input & Menu Surface Primitives

    private func inspectorStandardMenuLabel(
        title: String,
        systemImage: String,
        showsChevron: Bool = false
    ) -> some View {
        HStack(spacing: 5) {
            Image(systemName: systemImage)
                .font(.system(size: 11.5, weight: .medium))
                .foregroundStyle(.secondary)
            Text(title)
                .font(CharkleTheme.text(.caption, weight: .medium))
                .foregroundStyle(Color.primary.opacity(0.92))
                .lineLimit(1)
            if showsChevron {
                CharkleDropdownChevron(size: 8.5)
            }
        }
    }

    private func inspectorTextField(
        placeholder: String,
        text: Binding<String>,
        systemImage: String? = nil,
        onSubmit: (() -> Void)? = nil
    ) -> some View {
        let shape = RoundedRectangle(cornerRadius: CharkleTheme.Radius.chip, style: .continuous)
        return HStack(spacing: 6) {
            if let systemImage {
                Image(systemName: systemImage)
                    .font(.system(size: 10.5, weight: .medium))
                    .foregroundStyle(.tertiary)
            }
            TextField(placeholder, text: text)
                .textFieldStyle(.plain)
                .font(CharkleTheme.text(.caption))
                .onSubmit { onSubmit?() }
        }
        .padding(.horizontal, 9)
        .frame(height: 28)
        .background(CharkleTheme.inspectorFieldSurface(for: colorScheme), in: shape)
        .overlay {
            shape.strokeBorder(
                CharkleTheme.hairline(for: colorScheme),
                lineWidth: reduceTransparency ? 1.0 : CharkleTheme.hairlineWidth
            )
        }
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
                coordinator.showToast("请先在「设置 → 智能与搜索」中开启云端增强智能或进阶视觉定位闭集打标", icon: "sparkles", tone: .warning)
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
        return library.folder(byID: folderID)?.name ?? "文件夹"
    }

    private func commitSingleAssetTitle(_ asset: AssetRecord) {
        let trimmed = titleDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed != asset.title else { return }
        Task {
            await library.applyPatch(AssetBatchPatch(assetIDs: [asset.id], title: trimmed))
        }
    }

    private func scheduleNotesSave(assetID: UUID, notes: String) {
        pendingNotesAssetID = assetID
        pendingNotesValue = notes
        notesSaveTask?.cancel()
        notesSaveTask = Task {
            try? await Task.sleep(for: .milliseconds(350))
            guard !Task.isCancelled else { return }
            if pendingNotesAssetID == assetID && pendingNotesValue == notes {
                pendingNotesAssetID = nil
                pendingNotesValue = nil
            }
            await library.applyPatch(AssetBatchPatch(assetIDs: [assetID], notes: notes))
        }
    }

    private func flushPendingNotesSave() {
        notesSaveTask?.cancel()
        notesSaveTask = nil
        guard let assetID = pendingNotesAssetID, let notes = pendingNotesValue else { return }
        pendingNotesAssetID = nil
        pendingNotesValue = nil
        if library.allAssetsByID[assetID]?.notes != notes {
            Task {
                await library.applyPatch(AssetBatchPatch(assetIDs: [assetID], notes: notes))
            }
        }
    }

    private func commitBoardHeader(_ board: MoodboardDocument) {
        flushBoardHeaderIfDirty(
            boardID: board.id,
            originalTitle: board.title,
            originalSubtitle: board.subtitle
        )
    }

    private func flushBoardHeaderIfDirty(boardID: UUID, originalTitle: String, originalSubtitle: String) {
        let trimmed = boardTitleDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        let nextTitle = trimmed.isEmpty ? originalTitle : trimmed
        let nextSubtitle = boardSubtitleDraft
        guard nextTitle != originalTitle || nextSubtitle != originalSubtitle else { return }
        if var active = moodboards.activeBoard, active.id == boardID {
            active.title = nextTitle
            active.subtitle = nextSubtitle
            moodboards.commitMutation(active)
        } else {
            Task {
                await moodboards.updateBoardHeader(id: boardID, title: nextTitle, subtitle: nextSubtitle)
            }
        }
    }

    private func quickAddFilteredAssets(excluding excluded: Set<UUID>) -> [AssetRecord] {
        let q = quickAddQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        let source = library.cachedRecentActivityAssets
        var results: [AssetRecord] = []
        results.reserveCapacity(9)
        for asset in source {
            guard !asset.isTrashed, !excluded.contains(asset.id) else { continue }
            if !q.isEmpty {
                let matches = asset.title.localizedCaseInsensitiveContains(q)
                    || (asset.sourceDomain?.localizedCaseInsensitiveContains(q) ?? false)
                    || asset.tags.contains(where: { $0.localizedCaseInsensitiveContains(q) })
                guard matches else { continue }
            }
            results.append(asset)
            if results.count >= 9 { break }
        }
        return results
    }

    // MARK: - Universal Version Stack Section (Shared 1:1 Between Main Workspace & Quick Look)

    private static let versionShortTimestampFormatter: DateFormatter = {
        let fmt = DateFormatter()
        fmt.dateFormat = "MM-dd HH:mm"
        return fmt
    }()

    private static let boilerplateVersionStrings: Set<String> = [
        "基于差异审阅合成",
        "本机",
        "初稿",
        "修订版"
    ]

    public static func cleanVersionTimelineNote(
        changeNote: String?,
        versionLabel: String?
    ) -> String? {
        for rawCandidate in [changeNote, versionLabel] {
            guard let raw = rawCandidate else { continue }
            var cleaned = AssetVersionStackMetadata.strippingRedundantVersionPrefix(raw)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if cleaned.hasPrefix("(") && cleaned.hasSuffix(")") && cleaned.count >= 2 {
                cleaned = String(cleaned.dropFirst().dropLast()).trimmingCharacters(in: .whitespacesAndNewlines)
            }
            if cleaned.hasPrefix("（") && cleaned.hasSuffix("）") && cleaned.count >= 2 {
                cleaned = String(cleaned.dropFirst().dropLast()).trimmingCharacters(in: .whitespacesAndNewlines)
            }
            guard !cleaned.isEmpty,
                  !cleaned.contains("净版"),
                  !boilerplateVersionStrings.contains(cleaned) else { continue }
            return cleaned
        }
        return nil
    }

    public static func cleanVersionEditorName(
        _ rawEditor: String?,
        alreadyShownNote: String?
    ) -> String? {
        guard let rawEditor else { return nil }
        let trimmed = rawEditor.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              !trimmed.contains("净版"),
              !boilerplateVersionStrings.contains(trimmed) else { return nil }
        if let alreadyShownNote,
           trimmed.compare(alreadyShownNote, options: [.caseInsensitive, .diacriticInsensitive]) == .orderedSame {
            return nil
        }
        return trimmed
    }

    private func singleAssetVersionStackSection(_ asset: AssetRecord, siblings: [AssetRecord]) -> some View {
        let resolvedPrimary = library.primaryVersionAsset(for: asset.id) ?? asset
        let primaryVer = resolvedPrimary.richMetadata?.versionStack?.versionNumber ?? 1
        let newerCount = library.newerThanPrimaryCount(for: asset.id)
        let warnInk = CharkleTheme.warning(for: colorScheme)
        let positiveInk = CharkleTheme.positive(for: colorScheme)
        let newestFirstEntries = Array(siblings.enumerated()).reversed()

        return CharkleInspectorSection("历史版本", systemImage: nil, showsTopDivider: true) {
            CharkleDisclosureGroup(isExpanded: $isVersionStackExpanded, accentChevronWhenExpanded: true) {
                VStack(alignment: .leading, spacing: 9) {
                    if siblings.count >= 2 {
                        HStack(spacing: 6) {
                            Button {
                                let baseID: UUID?
                                let targetID: UUID?
                                if asset.id != resolvedPrimary.id {
                                    baseID = resolvedPrimary.id
                                    targetID = asset.id
                                } else {
                                    baseID = siblings[siblings.count - 2].id
                                    targetID = siblings[siblings.count - 1].id
                                }
                                let playlist = coordinator.quickLookPlaylist.isEmpty ? library.assets.map(\.id) : coordinator.quickLookPlaylist
                                coordinator.openQuickLookInDiff(
                                    assetID: targetID ?? asset.id,
                                    baseAssetID: baseID,
                                    targetAssetID: targetID,
                                    playlist: playlist
                                )
                            } label: {
                                Label("对比差异", systemImage: "arrow.left.arrow.right")
                            }
                            .buttonStyle(.charkle(.standard, size: .xs, fullWidth: true))

                            if asset.id != resolvedPrimary.id {
                                Button {
                                    Task {
                                        _ = await library.setPrimaryVersion(asset.id)
                                        let vNum = asset.richMetadata?.versionStack?.versionNumber ?? 1
                                        coordinator.showToast("已将 v\(vNum) 设为主版本", icon: "pin.fill", tone: .success)
                                    }
                                } label: {
                                    Label("设为主版", systemImage: "pin.fill")
                                }
                                .buttonStyle(.charkle(.standard, size: .xs))
                                .fixedSize()
                            }
                        }
                    }

                    // Clean Newest-First Vertical Timeline Spine (vN at top -> v1 at bottom)
                    VStack(spacing: 0) {
                        ForEach(Array(newestFirstEntries.enumerated()), id: \.element.element.id) { timelineIdx, entry in
                            let ascIdx = entry.offset
                            let ver = entry.element
                            let vMeta = ver.richMetadata?.versionStack
                            let vNum = vMeta?.versionNumber ?? (ascIdx + 1)
                            let isPrimary = ver.id == resolvedPrimary.id
                            let isCurrent = ver.id == asset.id
                            let isFirst = timelineIdx == 0
                            let isLast = timelineIdx == siblings.count - 1
                            let cleanNote = Self.cleanVersionTimelineNote(
                                changeNote: vMeta?.changeNote,
                                versionLabel: vMeta?.versionLabel
                            )
                            let cleanEditor = Self.cleanVersionEditorName(
                                vMeta?.editorName,
                                alreadyShownNote: cleanNote
                            )
                            let changedBlocks = ver.richMetadata?.document?.diffSummary?.totalChangedBlocks ?? 0
                            let prevSibling: AssetRecord? = ascIdx > 0 ? siblings[ascIdx - 1] : nil

                            HStack(alignment: .center, spacing: 6) {
                                // Left 16pt vertical timeline spine + 7.5pt node
                                ZStack {
                                    VStack(spacing: 0) {
                                        Rectangle()
                                            .fill(isFirst ? Color.clear : CharkleTheme.hairline(for: colorScheme))
                                            .frame(width: 1)
                                            .frame(maxHeight: .infinity)
                                        Rectangle()
                                            .fill(isLast ? Color.clear : CharkleTheme.hairline(for: colorScheme))
                                            .frame(width: 1)
                                            .frame(maxHeight: .infinity)
                                    }

                                    if isPrimary {
                                        Circle()
                                            .fill(accentColor)
                                            .frame(width: 7.5, height: 7.5)
                                    } else {
                                        Circle()
                                            .fill(CharkleTheme.inspectorBackground(for: colorScheme))
                                            .frame(width: 7.5, height: 7.5)
                                            .overlay(
                                                Circle()
                                                    .strokeBorder(
                                                        isCurrent ? accentColor : Color.secondary.opacity(0.50),
                                                        lineWidth: 1.5
                                                    )
                                            )
                                    }
                                }
                                .frame(width: 16)

                                HStack(spacing: 5) {
                                    Button {
                                        if isQuickLookHosted {
                                            var playlist = coordinator.quickLookPlaylist
                                            if !playlist.contains(ver.id) {
                                                playlist.append(ver.id)
                                            }
                                            coordinator.openQuickLook(assetID: ver.id, playlist: playlist)
                                        } else {
                                            onOpenQuickLook(ver)
                                        }
                                    } label: {
                                        VStack(alignment: .leading, spacing: 2) {
                                            HStack(spacing: 5) {
                                                Text("v\(vNum)")
                                                    .font(CharkleTheme.text(.caption, weight: .bold))
                                                    .monospacedDigit()
                                                    .foregroundStyle(isCurrent ? accentColor : .primary)

                                                if let cleanNote {
                                                    Text(cleanNote)
                                                        .font(CharkleTheme.text(.caption, weight: isCurrent ? .semibold : .regular))
                                                        .foregroundStyle(.primary)
                                                        .lineLimit(1)
                                                }

                                                if isPrimary {
                                                    Text("主版")
                                                        .font(CharkleTheme.text(.caption, weight: .semibold))
                                                        .foregroundStyle(positiveInk)
                                                        .padding(.horizontal, 4.5)
                                                        .padding(.vertical, 1)
                                                        .background(
                                                            positiveInk.opacity(0.14),
                                                            in: RoundedRectangle(cornerRadius: CharkleTheme.Radius.xs, style: .continuous)
                                                        )
                                                }

                                                Spacer(minLength: 0)
                                            }

                                            HStack(spacing: 5) {
                                                if let cleanEditor {
                                                    Text(cleanEditor)
                                                        .lineLimit(1)
                                                }
                                                Text(Self.versionShortTimestampFormatter.string(from: ver.updatedAt))
                                                    .monospacedDigit()
                                            }
                                            .font(CharkleTheme.text(.caption))
                                            .foregroundStyle(.tertiary)
                                            .lineLimit(1)
                                        }
                                        .frame(maxWidth: .infinity, alignment: .leading)
                                        .contentShape(Rectangle())
                                    }
                                    .buttonStyle(.plain)

                                    if changedBlocks > 0 {
                                        Button {
                                            let baseID = prevSibling?.id ?? ver.richMetadata?.document?.diffSummary?.comparedToAssetID
                                            let playlist = coordinator.quickLookPlaylist.isEmpty ? library.assets.map(\.id) : coordinator.quickLookPlaylist
                                            coordinator.openQuickLookInDiff(
                                                assetID: ver.id,
                                                baseAssetID: baseID,
                                                targetAssetID: ver.id,
                                                playlist: playlist
                                            )
                                        } label: {
                                            Text("Δ \(changedBlocks)")
                                                .font(CharkleTheme.text(.caption, weight: .semibold))
                                                .monospacedDigit()
                                                .foregroundStyle(accentColor)
                                                .padding(.horizontal, 5.5)
                                                .padding(.vertical, 2)
                                                .background(
                                                    accentSoft,
                                                    in: RoundedRectangle(cornerRadius: CharkleTheme.Radius.xs, style: .continuous)
                                                )
                                        }
                                        .buttonStyle(.plain)
                                        .fixedSize()
                                        .help("查看与上一版本的 \(changedBlocks) 处差异")
                                    }

                                    if !isPrimary {
                                        Button {
                                            Task {
                                                _ = await library.setPrimaryVersion(ver.id)
                                                coordinator.showToast("已将 v\(vNum) 设为主版本", icon: "pin.fill", tone: .success)
                                            }
                                        } label: {
                                            Image(systemName: "pin")
                                                .font(.system(size: 10.5, weight: .medium))
                                        }
                                        .buttonStyle(.charkle(.subtle, size: .icon, iconDimension: 22))
                                        .help("设为主版本")
                                    }
                                }
                                .padding(.horizontal, 7)
                                .padding(.vertical, 5.5)
                                .background(
                                    isCurrent ? accentSoft : Color.clear,
                                    in: RoundedRectangle(cornerRadius: CharkleTheme.Radius.chip, style: .continuous)
                                )
                            }
                        }
                    }

                    // Compact quick metadata row without extra sub-headers
                    HStack(spacing: 6) {
                        TextField("修改人", text: $versionEditorDraft)
                            .textFieldStyle(.plain)
                            .font(CharkleTheme.text(.caption))
                            .padding(.horizontal, 8)
                            .frame(width: 78, height: 26)
                            .background(
                                CharkleTheme.inspectorFieldSurface(for: colorScheme),
                                in: RoundedRectangle(cornerRadius: CharkleTheme.Radius.sm, style: .continuous)
                            )
                            .onSubmit { commitVersionMeta(for: asset) }

                        TextField("备注（回车保存）", text: $versionNoteDraft)
                            .textFieldStyle(.plain)
                            .font(CharkleTheme.text(.caption))
                            .padding(.horizontal, 8)
                            .frame(height: 26)
                            .background(
                                CharkleTheme.inspectorFieldSurface(for: colorScheme),
                                in: RoundedRectangle(cornerRadius: CharkleTheme.Radius.sm, style: .continuous)
                            )
                            .onSubmit { commitVersionMeta(for: asset) }

                        Button {
                            commitVersionMeta(for: asset)
                        } label: {
                            Image(systemName: "checkmark")
                                .font(.system(size: 10.5, weight: .bold))
                        }
                        .buttonStyle(.charkle(.standard, size: .icon, iconDimension: 26))
                        .help("保存修改人与备注")
                    }

                    if siblings.count > 1 {
                        Button {
                            Task {
                                _ = await library.unstackVersion(asset.id)
                                coordinator.showToast("已拆分为独立素材", icon: "rectangle.portrait.and.arrow.right")
                            }
                        } label: {
                            Label("拆分为独立素材", systemImage: "rectangle.portrait.and.arrow.right")
                        }
                        .buttonStyle(.charkle(.subtle, size: .xs))
                    }
                }
                .padding(.top, 6)
            } label: {
                HStack(spacing: 6) {
                    Text("共 \(siblings.count) 版 · 主版 v\(primaryVer)")
                        .font(CharkleTheme.text(.caption, weight: .semibold))
                        .monospacedDigit()
                        .foregroundStyle(.primary)

                    if newerCount > 0 {
                        Text("+\(newerCount)")
                            .font(CharkleTheme.text(.caption, weight: .semibold))
                            .monospacedDigit()
                            .foregroundStyle(warnInk)
                            .padding(.horizontal, 5)
                            .padding(.vertical, 1)
                            .background(warnInk.opacity(0.15), in: Capsule(style: .continuous))
                    }
                    Spacer(minLength: 0)
                }
            }
        }
    }

    private func commitVersionMeta(for asset: AssetRecord) {
        let editor = versionEditorDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        let note = versionNoteDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        let label: String? = {
            let vNum = asset.richMetadata?.versionStack?.versionNumber ?? 1
            if !editor.isEmpty { return "v\(vNum) (\(editor))" }
            return nil
        }()
        Task {
            _ = await library.updateVersionMetadata(
                assetID: asset.id,
                versionLabel: label,
                editorName: editor.isEmpty ? nil : editor,
                changeNote: note.isEmpty ? nil : note
            )
            coordinator.showToast("已更新版本修订记录", icon: "checkmark.circle.fill", tone: .success)
        }
    }
}

// MARK: - Drag-to-Reorder Helper for Single-Asset Inspector Sections

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
