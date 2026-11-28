import AppKit
import CharkleCanvas
import CharkleCore
import SwiftUI
import UniformTypeIdentifiers

/// 5th Universal Gallery Mode (`GalleryLayoutMode.compactList`, shortcut `5`):
/// Precision 1-Column Hairline Table (`单列列表`) and 2-Column Non-Splitting Bento Grid (`双列网格`),
/// paired with crisp optical-rimmed miniature covers, smart-suppressed hairline dividers,
/// anchored vertical version-history popovers, Primary-Version file drag/copy, drop-to-stack merging,
/// rubber-band marquee selection, and 0ms keyboard navigation.
public struct CompactIndexGalleryView: View {
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.charkleAccentSource) private var accentSource
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    public let assets: [AssetRecord]
    public let coordinator: AppCoordinatorStore
    public let library: LibraryStore
    public let moodboards: MoodboardStore
    public let topContentInset: CGFloat
    public let bottomContentInset: CGFloat
    public let viewportWidth: CGFloat
    public let isOverlayPresented: Bool
    public let onOpenQuickLook: (AssetRecord) -> Void
    public let onOpenDiff: (AssetRecord, UUID?, UUID?) -> Void
    public let onDropExternalInputs: ([CaptureInput]) -> Void
    public let onDropFilesOntoAsset: ([URL], AssetRecord) -> Void
    public let onMergeIntoVersionStack: ([UUID], UUID?) -> Void
    public let onSetPrimaryVersion: (UUID) -> Void
    public let onUnstackVersion: (UUID) -> Void
    public let onRetagAssets: ([UUID]) -> Void
    public let onRequestPermanentDelete: ([UUID]) -> Void
    public let onPasteIntoCurrentFolder: () -> Void

    public enum QuickMediaScope: String, CaseIterable, Identifiable, Sendable {
        case all
        case docAndStacks
        case visualAndMedia

        public var id: String { rawValue }
    }

    private enum DisplayRow: Identifiable {
        case single(asset: AssetRecord, index: Int)
        case pair(left: AssetRecord, leftIndex: Int, right: AssetRecord?, rightIndex: Int?)

        var id: String {
            switch self {
            case .single(let asset, _):
                return "single-\(asset.id.uuidString)"
            case .pair(let left, _, let right, _):
                if let right {
                    return "pair-\(left.id.uuidString)-\(right.id.uuidString)"
                }
                return "half-\(left.id.uuidString)"
            }
        }
    }

    @State private var quickScope: QuickMediaScope = .all
    @State private var activePopoverGroupID: UUID? = nil
    @State private var hoveredAssetID: UUID? = nil
    @State private var lastClickedAssetID: UUID? = nil
    @State private var isStageDropTargeted: Bool = false
    @State private var dropTargetedCardID: UUID? = nil
    @State private var visibleCardRects: [UUID: CGRect] = [:]
    @State private var lastHandledRevealNonce: UUID? = nil

    // Rubber-Band Marquee Box Multi-Select geometry & state (`compactStage` + `compactScrollDoc` spaces)
    @State private var scrollDocOriginInStage: CGPoint = .zero
    @State private var headerInteractiveStageRects: [Int: CGRect] = [:]
    @State private var docCardRects: [UUID: CGRect] = [:]
    @State private var docDragHandleRects: [UUID: CGRect] = [:]
    @State private var docTrailingRects: [UUID: CGRect] = [:]
    @State private var marqueeBaseSelection: Set<UUID> = []
    @State private var activeMarqueeDocRect: CGRect? = nil

    public init(
        assets: [AssetRecord],
        coordinator: AppCoordinatorStore,
        library: LibraryStore,
        moodboards: MoodboardStore,
        topContentInset: CGFloat,
        bottomContentInset: CGFloat,
        viewportWidth: CGFloat,
        isOverlayPresented: Bool,
        onOpenQuickLook: @escaping (AssetRecord) -> Void,
        onOpenDiff: @escaping (AssetRecord, UUID?, UUID?) -> Void,
        onDropExternalInputs: @escaping ([CaptureInput]) -> Void,
        onDropFilesOntoAsset: @escaping ([URL], AssetRecord) -> Void,
        onMergeIntoVersionStack: @escaping ([UUID], UUID?) -> Void,
        onSetPrimaryVersion: @escaping (UUID) -> Void,
        onUnstackVersion: @escaping (UUID) -> Void,
        onRetagAssets: @escaping ([UUID]) -> Void,
        onRequestPermanentDelete: @escaping ([UUID]) -> Void,
        onPasteIntoCurrentFolder: @escaping () -> Void
    ) {
        self.assets = assets
        self.coordinator = coordinator
        self.library = library
        self.moodboards = moodboards
        self.topContentInset = topContentInset
        self.bottomContentInset = bottomContentInset
        self.viewportWidth = viewportWidth
        self.isOverlayPresented = isOverlayPresented
        self.onOpenQuickLook = onOpenQuickLook
        self.onOpenDiff = onOpenDiff
        self.onDropExternalInputs = onDropExternalInputs
        self.onDropFilesOntoAsset = onDropFilesOntoAsset
        self.onMergeIntoVersionStack = onMergeIntoVersionStack
        self.onSetPrimaryVersion = onSetPrimaryVersion
        self.onUnstackVersion = onUnstackVersion
        self.onRetagAssets = onRetagAssets
        self.onRequestPermanentDelete = onRequestPermanentDelete
        self.onPasteIntoCurrentFolder = onPasteIntoCurrentFolder
    }

    private var activeAccent: Color {
        CharkleTheme.accent(for: colorScheme, source: coordinator.accentSource)
    }

    private var effectiveColumns: Int {
        CompactIndexLayoutMetrics.effectiveColumnCount(
            viewportWidth: viewportWidth,
            preferredColumnMode: coordinator.compactViewColumnMode
        )
    }

    private var docAndStackCount: Int {
        assets.reduce(into: 0) { acc, item in
            if isDocOrStack(item) { acc += 1 }
        }
    }

    private var visualMediaCount: Int {
        assets.reduce(into: 0) { acc, item in
            if !isDocOrStack(item) { acc += 1 }
        }
    }

    private func isDocOrStack(_ asset: AssetRecord) -> Bool {
        if asset.mediaKind == .document { return true }
        return library.versionStackSiblings(for: asset.id).count > 1
    }

    private var scopedAssets: [AssetRecord] {
        switch quickScope {
        case .all:
            return assets
        case .docAndStacks:
            return assets.filter { isDocOrStack($0) }
        case .visualAndMedia:
            return assets.filter { !isDocOrStack($0) }
        }
    }

    /// Pairs items strictly 2-by-2 (`0,1`, `2,3`, ...) in 2-column mode and NEVER splits pairs into single rows.
    private var displayRows: [DisplayRow] {
        let items = scopedAssets
        guard effectiveColumns == 2 else {
            return items.enumerated().map { DisplayRow.single(asset: $0.element, index: $0.offset) }
        }
        var rows: [DisplayRow] = []
        rows.reserveCapacity((items.count + 1) / 2)
        for leftIndex in stride(from: 0, to: items.count, by: 2) {
            let left = items[leftIndex]
            let rightIndex = leftIndex + 1
            if rightIndex < items.count {
                rows.append(.pair(left: left, leftIndex: leftIndex, right: items[rightIndex], rightIndex: rightIndex))
            } else {
                rows.append(.pair(left: left, leftIndex: leftIndex, right: nil, rightIndex: nil))
            }
        }
        return rows
    }

    public var body: some View {
        ZStack(alignment: .top) {
            CharkleTheme.galleryGround(for: colorScheme)
                .ignoresSafeArea()

            ScrollViewReader { scrollProxy in
                ScrollView(.vertical) {
                    VStack(alignment: .leading, spacing: 8) {
                        compactStudioHeaderBar

                        if scopedAssets.isEmpty {
                            emptyFilteredScopePlaceholder
                        } else if effectiveColumns == 1 {
                            unifiedSingleColumnTable(scrollProxy: scrollProxy)
                        } else {
                            twoColumnBentoGrid(scrollProxy: scrollProxy)
                        }
                    }
                    .padding(.horizontal, viewportWidth < 560 ? 12 : 20)
                    .padding(.top, topContentInset + 4)
                    .padding(.bottom, bottomContentInset)
                    .coordinateSpace(name: "compactScrollDoc")
                    .onGeometryChange(for: CGPoint.self) { proxy in
                        proxy.frame(in: .named("compactStage")).origin
                    } action: { _, newOrigin in
                        scrollDocOriginInStage = newOrigin
                    }
                    .contentShape(Rectangle())
                    .onTapGesture {
                        if !library.selectedAssetIDs.isEmpty {
                            library.selectedAssetIDs.removeAll()
                        }
                    }
                }
                .charkleCleanScrollbars(hidden: false)
                .background {
                    CompactStageKeyboardBridge(
                        isSuspended: isOverlayPresented,
                        topContentInset: topContentInset,
                        canBeginMarqueeAtStagePoint: { stagePt in
                            canBeginMarqueeSelection(atStagePoint: stagePt)
                        },
                        stageToDocPoint: { stagePt in
                            CGPoint(
                                x: stagePt.x - scrollDocOriginInStage.x,
                                y: stagePt.y - scrollDocOriginInStage.y
                            )
                        },
                        onBeginMarquee: { modifiers in
                            beginMarqueeSelection(modifiers: modifiers)
                        },
                        onUpdateMarquee: { startDocPt, currentStagePt, modifiers in
                            updateMarqueeSelection(
                                startDocPoint: startDocPt,
                                currentStagePoint: currentStagePt,
                                modifiers: modifiers
                            )
                        },
                        onEndMarquee: {
                            endMarqueeSelection()
                        },
                        onKeyDown: { event in
                            handleCompactKeyDown(event, scrollProxy: scrollProxy)
                        }
                    )
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .allowsHitTesting(false)
                }
                .onChange(of: coordinator.pendingGalleryReveal) { _, req in
                    guard let req, req.nonce != lastHandledRevealNonce else { return }
                    lastHandledRevealNonce = req.nonce
                    let targetID = library.primaryVersionAssetID(for: req.assetID)
                    withAnimation(CharkleMotion.accessible(CharkleMotion.settleStrong, reduced: reduceMotion)) {
                        scrollProxy.scrollTo(targetID, anchor: .center)
                    }
                }
                .onChange(of: scopedAssets.map(\.id)) { _, validIDs in
                    let validSet = Set(validIDs)
                    docCardRects = docCardRects.filter { validSet.contains($0.key) }
                    docDragHandleRects = docDragHandleRects.filter { validSet.contains($0.key) }
                    docTrailingRects = docTrailingRects.filter { validSet.contains($0.key) }
                    if let hoveredAssetID, !validSet.contains(hoveredAssetID) {
                        self.hoveredAssetID = nil
                    }
                }
            }

            if let docRect = activeMarqueeDocRect,
               (docRect.width > 3 || docRect.height > 3) {
                let stageRect = docRect.offsetBy(dx: scrollDocOriginInStage.x, dy: scrollDocOriginInStage.y)
                let marqueeShape = RoundedRectangle(cornerRadius: CharkleTheme.Radius.xs, style: .continuous)
                marqueeShape
                    .fill(activeAccent.opacity(0.11))
                    .overlay(
                        marqueeShape.strokeBorder(activeAccent.opacity(0.68), lineWidth: 1)
                    )
                    .frame(width: stageRect.width, height: stageRect.height)
                    .position(x: stageRect.midX, y: stageRect.midY)
                    .allowsHitTesting(false)
            }

            CanvasDropRingOverlay(isTargeted: isStageDropTargeted && dropTargetedCardID == nil, padding: 12, fillOpacity: 0.05)
        }
        .coordinateSpace(name: "compactStage")
        .onDrop(of: [.fileURL, .url, .png, .tiff, .plainText], isTargeted: $isStageDropTargeted) { providers in
            handleStageBackgroundDrop(providers: providers)
        }
        .onAppear {
            MasonryCardGeometryRegistry.shared.externalCardRectProvider = { [visibleCardRects] id in
                let primaryID = library.primaryVersionAssetID(for: id)
                return visibleCardRects[id] ?? visibleCardRects[primaryID]
            }
            if let firstSelected = library.selectedAssetIDs.first {
                coordinator.focusedStageAssetID = firstSelected
            }
        }
        .onChange(of: visibleCardRects) { _, latest in
            MasonryCardGeometryRegistry.shared.externalCardRectProvider = { id in
                let primaryID = library.primaryVersionAssetID(for: id)
                return latest[id] ?? latest[primaryID]
            }
        }
        .onDisappear {
            MasonryCardGeometryRegistry.shared.externalCardRectProvider = nil
        }
    }

    // MARK: - 1. Minimal Sub-Toolbar (`CharkleSegmentedControl`)

    private var compactStudioHeaderBar: some View {
        let showScopeFilter = (docAndStackCount > 0 && visualMediaCount > 0) || quickScope != .all

        return HStack(spacing: 8) {
            if showScopeFilter {
                CharkleSegmentedControl(
                    selection: $quickScope,
                    items: [
                        .init(.all, title: "全部", badge: "\(assets.count)"),
                        .init(.docAndStacks, title: "文档", badge: "\(docAndStackCount)"),
                        .init(.visualAndMedia, title: "媒体", badge: "\(visualMediaCount)")
                    ],
                    size: .compact,
                    fullWidth: false,
                    useAccentForSelected: false
                )
                .onGeometryChange(for: CGRect.self) { proxy in
                    proxy.frame(in: .named("compactStage"))
                } action: { _, rect in
                    headerInteractiveStageRects[0] = rect
                }
            } else {
                Text("\(assets.count) 项")
                    .font(CharkleTheme.text(.caption))
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
                    .padding(.leading, 4)
                    .frame(minHeight: 26)
                    .onAppear { headerInteractiveStageRects.removeValue(forKey: 0) }
            }

            Spacer(minLength: 8)

            if viewportWidth >= CompactIndexLayoutMetrics.twoColumnMinViewportWidth {
                CharkleSegmentedControl(
                    selection: Binding(
                        get: { coordinator.compactViewColumnMode == 1 ? 1 : 2 },
                        set: { coordinator.compactViewColumnMode = $0 }
                    ),
                    items: [
                        .init(1, systemImage: "list.bullet", helpText: "单列列表"),
                        .init(2, systemImage: "square.grid.2x2", helpText: "双列网格")
                    ],
                    size: .compact,
                    fullWidth: false,
                    useAccentForSelected: false
                )
                .onGeometryChange(for: CGRect.self) { proxy in
                    proxy.frame(in: .named("compactStage"))
                } action: { _, rect in
                    headerInteractiveStageRects[1] = rect
                }
            } else {
                Color.clear
                    .frame(width: 0, height: 0)
                    .onAppear { headerInteractiveStageRects.removeValue(forKey: 1) }
            }
        }
        .padding(.horizontal, 2)
        .padding(.bottom, 2)
    }

    private var emptyFilteredScopePlaceholder: some View {
        VStack(spacing: 8) {
            Text(quickScope == .docAndStacks ? "当前范围暂无文档" : "当前范围暂无媒体素材")
                .font(CharkleTheme.text(.body, weight: .medium))
                .foregroundStyle(.secondary)
            Button("查看全部 \(assets.count) 项") {
                withAnimation(CharkleMotion.accessible(CharkleMotion.settleStrong, reduced: reduceMotion)) {
                    quickScope = .all
                }
            }
            .buttonStyle(.charkle(.standard, size: .xs))
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 48)
    }

    // MARK: - 2. 1-Column Unified Hairline Table & 2-Column Non-Splitting Bento Grid

    private func isRowVisuallyHighlighted(_ id: UUID) -> Bool {
        library.selectedAssetIDs.contains(id) || hoveredAssetID == id || dropTargetedCardID == id
    }

    private func unifiedSingleColumnTable(scrollProxy: ScrollViewProxy) -> some View {
        let items = scopedAssets
        let tableShape = RoundedRectangle(cornerRadius: CharkleTheme.Radius.cardOuter, style: .continuous)

        return LazyVStack(alignment: .leading, spacing: 0) {
            ForEach(Array(items.enumerated()), id: \.element.id) { index, asset in
                let suppressDivider = (index >= items.count - 1)
                    || isRowVisuallyHighlighted(asset.id)
                    || isRowVisuallyHighlighted(items[index + 1].id)

                compactItemCell(
                    asset: asset,
                    index: index,
                    isTwoColumnGrid: false,
                    showsBottomHairline: !suppressDivider
                )
                .id(asset.id)
            }
        }
        .padding(.vertical, 4)
        .background(CharkleTheme.surfaceElevated(for: colorScheme), in: tableShape)
        .clipShape(tableShape)
        .overlay(
            tableShape.strokeBorder(
                CharkleTheme.hairline(for: colorScheme),
                lineWidth: CharkleTheme.hairlineWidth
            )
        )
    }

    private func twoColumnBentoGrid(scrollProxy: ScrollViewProxy) -> some View {
        LazyVStack(alignment: .leading, spacing: 8) {
            ForEach(displayRows) { row in
                switch row {
                case .single(let asset, let idx):
                    compactItemCell(
                        asset: asset,
                        index: idx,
                        isTwoColumnGrid: true,
                        showsBottomHairline: false
                    )
                    .id(asset.id)
                case .pair(let left, let leftIdx, let right, let rightIdx):
                    HStack(alignment: .center, spacing: 8) {
                        compactItemCell(
                            asset: left,
                            index: leftIdx,
                            isTwoColumnGrid: true,
                            showsBottomHairline: false
                        )
                        .id(left.id)
                        .frame(maxWidth: .infinity)

                        if let right, let rightIdx {
                            compactItemCell(
                                asset: right,
                                index: rightIdx,
                                isTwoColumnGrid: true,
                                showsBottomHairline: false
                            )
                            .id(right.id)
                            .frame(maxWidth: .infinity)
                        } else {
                            Color.clear
                                .frame(maxWidth: .infinity, minHeight: 58)
                                .allowsHitTesting(false)
                        }
                    }
                }
            }
        }
    }

    // MARK: - Row / Tile Cell Wiring

    private func compactItemCell(
        asset: AssetRecord,
        index: Int,
        isTwoColumnGrid: Bool,
        showsBottomHairline: Bool
    ) -> some View {
        let siblings = library.versionStackSiblings(for: asset.id)
        let groupID = asset.richMetadata?.versionStack?.groupID
        let isSelected = library.selectedAssetIDs.contains(asset.id)
        let isCut = library.cutAssetIDs.contains(asset.id)
        let isCardDropTargeted = dropTargetedCardID == asset.id

        let popoverBinding = Binding<Bool>(
            get: {
                guard let gid = groupID, siblings.count > 1 else { return false }
                return activePopoverGroupID == gid
            },
            set: { presented in
                if presented, let gid = groupID, siblings.count > 1 {
                    activePopoverGroupID = gid
                } else if activePopoverGroupID == groupID {
                    activePopoverGroupID = nil
                }
            }
        )

        return CompactPrecisionItemCell(
            asset: asset,
            siblings: siblings,
            loader: library.thumbnailLoader,
            accentColor: activeAccent,
            accentSource: coordinator.accentSource,
            isTwoColumnGrid: isTwoColumnGrid,
            showsBottomHairline: showsBottomHairline,
            isSelected: isSelected,
            isCut: isCut,
            isDropTargeted: isCardDropTargeted,
            isPopoverPresented: popoverBinding,
            onHoverChanged: { hovering in
                if hovering {
                    hoveredAssetID = asset.id
                } else if hoveredAssetID == asset.id {
                    hoveredAssetID = nil
                }
            },
            onSelectCard: {
                handleCardClick(asset: asset, index: index)
            },
            onDoubleClickCard: {
                library.selectedAssetIDs = [asset.id]
                lastClickedAssetID = asset.id
                coordinator.focusedStageAssetID = asset.id
                onOpenQuickLook(asset)
            },
            onToggleVersionPopover: {
                guard let gid = groupID, siblings.count > 1 else { return }
                if !library.selectedAssetIDs.contains(asset.id) {
                    library.selectedAssetIDs = [asset.id]
                }
                lastClickedAssetID = asset.id
                coordinator.focusedStageAssetID = asset.id
                activePopoverGroupID = (activePopoverGroupID == gid) ? nil : gid
            },
            onCopyPrimaryFile: {
                copyPrimaryFileWithToast(for: asset, siblings: siblings)
            },
            onTrashAsset: {
                let targets = effectiveSelectionIDs(including: asset.id)
                let nextID = MasonryLayoutEngine.nextFocusAssetIDAfterDeleting(
                    deletedIDs: Set(targets),
                    in: scopedAssets.map(\.id)
                )
                trashCompactAssetsWithUndo(targets, nextFocusID: nextID)
            },
            onPermanentlyDeleteAsset: {
                onRequestPermanentDelete(effectiveSelectionIDs(including: asset.id))
            },
            onPinPrimaryVersion: { verAsset in
                onSetPrimaryVersion(verAsset.id)
            },
            onOpenVersionInQuickLook: { verAsset in
                onOpenQuickLook(verAsset)
            },
            onOpenDiffPair: { baseID, targetID in
                onOpenDiff(asset, baseID, targetID)
            },
            makeDragProvider: {
                makeDragItemProvider(for: effectiveSelectionIDs(including: asset.id))
            },
            onDragHandleDocRectChange: { rect in
                docDragHandleRects[asset.id] = rect
            },
            onTrailingControlsDocRectChange: { rect in
                if let rect, rect.width > 1, rect.height > 1 {
                    docTrailingRects[asset.id] = rect
                } else {
                    docTrailingRects.removeValue(forKey: asset.id)
                }
            }
        )
        .onGeometryChange(for: CGRect.self) { proxy in
            proxy.frame(in: .named("compactScrollDoc"))
        } action: { _, docRect in
            if docRect.width > 20, docRect.height > 20 {
                docCardRects[asset.id] = docRect
            } else {
                docCardRects.removeValue(forKey: asset.id)
            }
        }
        .onGeometryChange(for: CGRect.self) { proxy in
            let f = proxy.frame(in: .global)
            return CGRect(x: floor(f.origin.x), y: floor(f.origin.y), width: floor(f.width), height: floor(f.height))
        } action: { _, newRect in
            if newRect.width > 20, newRect.height > 20 {
                visibleCardRects[asset.id] = newRect
            } else {
                visibleCardRects.removeValue(forKey: asset.id)
            }
        }
        .onDrop(
            of: [.plainText, .fileURL],
            delegate: CompactCardStackDropDelegate(
                targetAsset: asset,
                library: library,
                dropTargetedCardID: $dropTargetedCardID,
                onMergeAssets: { draggedIDs, targetID in
                    onMergeIntoVersionStack(draggedIDs, targetID)
                },
                onDropExternalFiles: { urls, target in
                    onDropFilesOntoAsset(urls, target)
                }
            )
        )
        .contextMenu {
            compactCardContextMenu(for: asset, siblings: siblings)
        }
    }

    private func effectiveSelectionIDs(including clickedID: UUID) -> [UUID] {
        if library.selectedAssetIDs.contains(clickedID) {
            let ordered = scopedAssets.map(\.id).filter { library.selectedAssetIDs.contains($0) }
            return ordered.isEmpty ? Array(library.selectedAssetIDs) : ordered
        }
        return [clickedID]
    }

    private func handleCardClick(asset: AssetRecord, index: Int) {
        let flags = NSEvent.modifierFlags.intersection([.command, .option, .control, .shift])
        let items = scopedAssets
        if flags.contains(.command) {
            if library.selectedAssetIDs.contains(asset.id) {
                library.selectedAssetIDs.remove(asset.id)
            } else {
                library.selectedAssetIDs.insert(asset.id)
            }
        } else if flags.contains(.shift),
                  let anchorID = lastClickedAssetID,
                  let anchorIdx = items.firstIndex(where: { $0.id == anchorID }) {
            let lo = min(anchorIdx, index)
            let hi = max(anchorIdx, index)
            var next = library.selectedAssetIDs
            for idx in lo...hi where idx < items.count {
                next.insert(items[idx].id)
            }
            library.selectedAssetIDs = next
        } else {
            library.selectedAssetIDs = [asset.id]
        }
        lastClickedAssetID = asset.id
        coordinator.focusedStageAssetID = asset.id
    }

    private func copyPrimaryFileWithToast(for asset: AssetRecord, siblings: [AssetRecord]) {
        Task {
            let count = await library.copyAssetsToPasteboard([asset.id], preferStackPrimary: true)
            guard count > 0 else {
                coordinator.showToast("尚未找到本地原文件缓存", icon: "exclamationmark.triangle", tone: .warning)
                return
            }
            let primary = library.primaryVersionAsset(for: asset.id) ?? asset
            let vNum = primary.richMetadata?.versionStack?.versionNumber ?? 1
            let suffix = siblings.count > 1 ? " (v\(vNum))" : ""
            coordinator.showToast(
                "已拷贝「\(primary.title)\(suffix)」",
                icon: "doc.on.doc.fill",
                tone: .success
            )
        }
    }

    private func makeDragItemProvider(for ids: [UUID]) -> NSItemProvider {
        let provider = NSItemProvider()
        let encoded = CharkleDragIdentifiers.encode(assetIDs: ids)
        provider.registerDataRepresentation(
            forTypeIdentifier: CharkleDragIdentifiers.internalPasteboardType.rawValue,
            visibility: .ownProcess
        ) { completion in
            completion(Data(encoded.utf8), nil)
            return nil
        }
        provider.registerDataRepresentation(forTypeIdentifier: UTType.plainText.identifier, visibility: .all) { completion in
            completion(Data(encoded.utf8), nil)
            return nil
        }
        if let firstID = ids.first,
           let fileURL = library.cachedPrimaryDragFileURL(for: firstID),
           fileURL.isFileURL,
           FileManager.default.fileExists(atPath: fileURL.path) {
            provider.registerDataRepresentation(forTypeIdentifier: UTType.fileURL.identifier, visibility: .all) { completion in
                completion(fileURL.dataRepresentation, nil)
                return nil
            }
        }
        return provider
    }

    // MARK: - Context Menu

    @ViewBuilder
    private func compactCardContextMenu(for asset: AssetRecord, siblings: [AssetRecord]) -> some View {
        let targets = effectiveSelectionIDs(including: asset.id)

        Button {
            onOpenQuickLook(asset)
        } label: {
            Label(
                asset.isExternalWebLink ? "在默认浏览器中打开 (Space)" : "快速预览 (Space)",
                systemImage: asset.isExternalWebLink ? "safari" : "eye"
            )
        }

        Button {
            Task {
                let ok = await library.revealInFinder(assetID: asset.id)
                if !ok {
                    coordinator.showToast("无法定位该素材的本地文件", icon: "exclamationmark.triangle", tone: .warning)
                }
            }
        } label: {
            Label("在访达中显示", systemImage: "folder")
        }

        if asset.isTrashed {
            Divider()
            Button {
                Task {
                    await library.restoreAssets(targets)
                    coordinator.showToast("已放回原处 (\(targets.count) 项)", icon: "arrow.uturn.backward")
                }
            } label: {
                Label("放回原处", systemImage: "arrow.uturn.backward")
            }

            Button(role: .destructive) {
                onRequestPermanentDelete(targets)
            } label: {
                Label("彻底删除", systemImage: "trash.slash")
            }
        } else {
            Divider()

            Button {
                if targets.count == 1 {
                    copyPrimaryFileWithToast(for: asset, siblings: siblings)
                } else {
                    Task {
                        let count = await library.copyAssetsToPasteboard(targets, preferStackPrimary: true)
                        coordinator.showToast("已拷贝 \(count) 项原文件", icon: "doc.on.doc")
                    }
                }
            } label: {
                Label(siblings.count > 1 ? "拷贝主版本原文件 (⌘C)" : "拷贝原文件 (⌘C)", systemImage: "doc.on.doc")
            }

            Button {
                Task {
                    let count = await library.cutAssets(targets)
                    coordinator.showToast("已剪切 \(count) 项素材", icon: "scissors")
                }
            } label: {
                Label("剪切 (⌘X)", systemImage: "scissors")
            }

            if targets.count >= 2 {
                Divider()
                Button {
                    onMergeIntoVersionStack(targets, asset.id)
                } label: {
                    Label("合并版本（\(targets.count) 项）", systemImage: "square.stack.3d.up")
                }
            } else if siblings.count > 1 {
                Divider()
                Button {
                    if let gid = asset.richMetadata?.versionStack?.groupID {
                        activePopoverGroupID = gid
                    }
                } label: {
                    Label("历史版本（\(siblings.count)）", systemImage: "square.stack.3d.up")
                }

                Button {
                    let baseID = siblings.count >= 2 ? siblings[siblings.count - 2].id : siblings.first?.id
                    let targetID = siblings.last?.id
                    onOpenDiff(asset, baseID, targetID)
                } label: {
                    Label("对比差异", systemImage: "arrow.left.arrow.right")
                }

                Menu("设为主版本") {
                    ForEach(siblings.reversed()) { ver in
                        let vMeta = ver.richMetadata?.versionStack
                        let vNum = vMeta?.versionNumber ?? 1
                        let isPrimary = ver.id == asset.id
                        let descriptor = AssetVersionStackMetadata.cleanDisplayDescriptor(
                            changeNote: vMeta?.changeNote,
                            versionLabel: vMeta?.versionLabel,
                            editorName: nil
                        )
                        let itemTitle = descriptor.map { "v\(vNum)  \($0)" } ?? "v\(vNum)"
                        Button {
                            onSetPrimaryVersion(ver.id)
                        } label: {
                            if isPrimary {
                                Label(itemTitle, systemImage: "checkmark")
                            } else {
                                Text(itemTitle)
                            }
                        }
                    }
                }

                Button {
                    onUnstackVersion(asset.id)
                } label: {
                    Label("拆分为独立素材", systemImage: "rectangle.portrait.and.arrow.right")
                }
            }

            Divider()

            Menu {
                ForEach(moodboards.boards) { board in
                    Button(board.title) {
                        let resolved = targets.compactMap { library.allAssetsByID[$0] }
                        Task {
                            await moodboards.addAssetsToSpecificBoard(boardID: board.id, assets: resolved)
                            coordinator.showToast("已加入情绪板「\(board.title)」", icon: "rectangle.3.group")
                        }
                    }
                }
                Divider()
                Button("以此新建情绪板…") {
                    library.selectedAssetIDs = Set(targets)
                    coordinator.presentMoodboardGenerator(entry: .selection)
                }
            } label: {
                Label("加入情绪板", systemImage: "rectangle.3.group")
            }

            Menu {
                CharkleHierarchicalFolderMenuContent(
                    folders: library.folders,
                    includeInbox: true,
                    selectedFolderID: targets.count == 1 ? asset.folderID : nil,
                    highlightSelection: targets.count == 1,
                    parentSelfPrefix: "放入"
                ) { folderID in
                    Task {
                        await library.moveAssets(targets, toFolderID: folderID)
                        let destName = folderID.flatMap { library.folder(byID: $0)?.name } ?? "收件箱"
                        coordinator.showToast("已归档至「\(destName)」", icon: "folder")
                    }
                }
            } label: {
                Label("移动到文件夹", systemImage: "folder.badge.plus")
            }

            Button {
                let nextPinned = !asset.pinnedOffline
                Task {
                    await library.togglePinOffline(ids: targets, pinned: nextPinned)
                    coordinator.showToast(
                        nextPinned ? "已设为始终保留在本地" : "已取消始终保留，将按需管理空间",
                        icon: nextPinned ? "arrow.down.circle.fill" : "icloud"
                    )
                }
            } label: {
                Label(
                    asset.pinnedOffline ? "取消始终保留在本地" : "始终保留在本地",
                    systemImage: asset.pinnedOffline ? "icloud" : "arrow.down.circle"
                )
            }

            Button {
                onRetagAssets(targets)
            } label: {
                Label(targets.count > 1 ? "AI 批量重新打标（\(targets.count) 项）" : "AI 重新打标", systemImage: "sparkles")
            }

            Divider()

            Button(role: .destructive) {
                let nextID = MasonryLayoutEngine.nextFocusAssetIDAfterDeleting(
                    deletedIDs: Set(targets),
                    in: scopedAssets.map(\.id)
                )
                trashCompactAssetsWithUndo(targets, nextFocusID: nextID)
            } label: {
                Label("移至废纸篓", systemImage: "trash")
            }
        }
    }

    private func trashCompactAssetsWithUndo(_ targets: [UUID], nextFocusID: UUID?) {
        guard !targets.isEmpty else { return }
        let hadDeletedSelection = !library.selectedAssetIDs.isDisjoint(with: targets)
        Task {
            await library.trashAssets(targets)
            if hadDeletedSelection,
               library.selectedAssetIDs.isEmpty,
               let nextID = nextFocusID,
               scopedAssets.contains(where: { $0.id == nextID }) {
                var transaction = Transaction(animation: nil)
                transaction.disablesAnimations = true
                withTransaction(transaction) {
                    library.selectedAssetIDs = [nextID]
                    lastClickedAssetID = nextID
                    coordinator.focusedStageAssetID = nextID
                }
            }
            coordinator.showToast(
                "已移至废纸篓 (\(targets.count) 项)",
                icon: "trash",
                actionTitle: "撤销",
                onAction: {
                    Task {
                        await library.restoreAssets(targets)
                        coordinator.showToast(
                            targets.count == 1 ? "已放回原处" : "已放回原处 (\(targets.count) 项)",
                            icon: "arrow.uturn.backward",
                            tone: .success
                        )
                    }
                }
            )
        }
    }

    // MARK: - Rubber-Band Marquee Box Multi-Select

    private func canBeginMarqueeSelection(atStagePoint stagePt: CGPoint) -> Bool {
        guard !isOverlayPresented, !scopedAssets.isEmpty else { return false }
        for rect in headerInteractiveStageRects.values where rect.insetBy(dx: -2, dy: -2).contains(stagePt) {
            return false
        }
        let docPt = CGPoint(
            x: stagePt.x - scrollDocOriginInStage.x,
            y: stagePt.y - scrollDocOriginInStage.y
        )
        for rect in docDragHandleRects.values where rect.contains(docPt) {
            return false
        }
        for rect in docTrailingRects.values where rect.insetBy(dx: -2, dy: -2).contains(docPt) {
            return false
        }
        return true
    }

    private func beginMarqueeSelection(modifiers: NSEvent.ModifierFlags) {
        let keepBase = modifiers.contains(.command) || modifiers.contains(.shift)
        marqueeBaseSelection = keepBase ? library.selectedAssetIDs : []
    }

    private func updateMarqueeSelection(
        startDocPoint: CGPoint,
        currentStagePoint: CGPoint,
        modifiers: NSEvent.ModifierFlags
    ) {
        let currentDocPoint = CGPoint(
            x: currentStagePoint.x - scrollDocOriginInStage.x,
            y: currentStagePoint.y - scrollDocOriginInStage.y
        )
        let docRect = CGRect(
            x: min(startDocPoint.x, currentDocPoint.x),
            y: min(startDocPoint.y, currentDocPoint.y),
            width: abs(currentDocPoint.x - startDocPoint.x),
            height: abs(currentDocPoint.y - startDocPoint.y)
        )
        activeMarqueeDocRect = docRect

        guard docRect.width > 3 || docRect.height > 3 else { return }

        var hitIDs = Set<UUID>()
        for (id, cardRect) in docCardRects where cardRect.intersects(docRect) {
            hitIDs.insert(id)
        }

        let nextSelection: Set<UUID>
        if modifiers.contains(.command) {
            nextSelection = marqueeBaseSelection.symmetricDifference(hitIDs)
        } else if modifiers.contains(.shift) {
            nextSelection = marqueeBaseSelection.union(hitIDs)
        } else {
            nextSelection = hitIDs
        }

        if library.selectedAssetIDs != nextSelection {
            var transaction = Transaction(animation: nil)
            transaction.disablesAnimations = true
            withTransaction(transaction) {
                library.selectedAssetIDs = nextSelection
                if let firstHit = scopedAssets.first(where: { nextSelection.contains($0.id) }) {
                    coordinator.focusedStageAssetID = firstHit.id
                }
            }
        }
    }

    private func endMarqueeSelection() {
        activeMarqueeDocRect = nil
        marqueeBaseSelection = []
    }

    // MARK: - Stage Drop & Instant 0ms Keyboard Navigation

    private func handleStageBackgroundDrop(providers: [NSItemProvider]) -> Bool {
        let syncPayload = CharkleDragPasteboardResolver.resolveSynchronously { url in
            library.resolveInternalCachedAssetID(for: url)
        }
        if syncPayload.hasInternalPayload {
            return false
        }
        if !syncPayload.externalFileURLs.isEmpty {
            onDropExternalInputs(syncPayload.externalFileURLs.map { .fileURL($0) })
            return true
        }
        let inputs = ClipboardCollector.extractInputs(from: NSPasteboard(name: .drag))
        guard !inputs.isEmpty else { return false }
        onDropExternalInputs(inputs)
        return true
    }

    private func handleCompactKeyDown(_ event: NSEvent, scrollProxy: ScrollViewProxy) -> NSEvent? {
        guard !isOverlayPresented else { return event }
        if let responder = event.window?.firstResponder,
           responder is NSTextView || responder is NSTextField || responder is NSText {
            return event
        }

        if let textInput = event.window?.firstResponder as? any NSTextInputClient,
           textInput.hasMarkedText() {
            return event
        }

        let primaryModifiers = event.modifierFlags.intersection([.command, .option, .control, .shift])
        let items = scopedAssets

        if (primaryModifiers.isEmpty || primaryModifiers == [.command]),
           (event.keyCode == 51 || event.keyCode == 117) {
            guard !library.selectedAssetIDs.isEmpty else { return event }
            if event.isARepeat { return nil }
            let orderedTargets = items.compactMap { library.selectedAssetIDs.contains($0.id) ? $0.id : nil }
            let targets = orderedTargets.isEmpty ? Array(library.selectedAssetIDs) : orderedTargets
            guard !targets.isEmpty else { return event }
            let targetRecords = targets.compactMap { library.allAssetsByID[$0] }
            if coordinator.selectedDestination == .trash
                || (!targetRecords.isEmpty && targetRecords.allSatisfy(\.isTrashed)) {
                onRequestPermanentDelete(targets)
                return nil
            }
            let nextID = MasonryLayoutEngine.nextFocusAssetIDAfterDeleting(
                deletedIDs: Set(targets),
                in: items.map(\.id)
            )
            trashCompactAssetsWithUndo(targets, nextFocusID: nextID)
            return nil
        }

        if primaryModifiers == [.command], let chars = event.charactersIgnoringModifiers?.lowercased() {
            switch chars {
            case "a":
                library.selectedAssetIDs = Set(items.map(\.id))
                return nil
            case "c":
                guard !library.selectedAssetIDs.isEmpty else { return event }
                let ids = Array(library.selectedAssetIDs)
                if ids.count == 1, let single = library.allAssetsByID[ids[0]] {
                    copyPrimaryFileWithToast(for: single, siblings: library.versionStackSiblings(for: single.id))
                } else {
                    Task {
                        let count = await library.copyAssetsToPasteboard(ids, preferStackPrimary: true)
                        coordinator.showToast("已拷贝 \(count) 项原文件", icon: "doc.on.doc")
                    }
                }
                return nil
            case "x":
                guard !library.selectedAssetIDs.isEmpty else { return event }
                let ids = Array(library.selectedAssetIDs)
                Task {
                    let count = await library.cutAssets(ids)
                    coordinator.showToast("已剪切 \(count) 项素材", icon: "scissors")
                }
                return nil
            case "v":
                onPasteIntoCurrentFolder()
                return nil
            default:
                break
            }
        }

        let extend = primaryModifiers == [.shift]
        if (primaryModifiers.isEmpty || extend), !items.isEmpty {
            let stepDelta: Int? = switch event.keyCode {
            case 123: -1 // Left
            case 124: 1  // Right
            case 126: effectiveColumns == 2 ? -2 : -1 // Up
            case 125: effectiveColumns == 2 ? 2 : 1   // Down
            default: nil
            }
            if let delta = stepDelta {
                let currentIndex: Int = {
                    if let anchor = lastClickedAssetID,
                       library.selectedAssetIDs.contains(anchor),
                       let idx = items.firstIndex(where: { $0.id == anchor }) {
                        return idx
                    }
                    if let firstSel = items.firstIndex(where: { library.selectedAssetIDs.contains($0.id) }) {
                        return firstSel
                    }
                    return delta > 0 ? -delta : 0
                }()
                let nextIndex = max(0, min(items.count - 1, currentIndex + delta))
                let target = items[nextIndex]
                // 0ms instant keyboard selection transition per DESIGN.md motion contract
                var transaction = Transaction(animation: nil)
                transaction.disablesAnimations = true
                withTransaction(transaction) {
                    if extend {
                        library.selectedAssetIDs.insert(target.id)
                    } else {
                        library.selectedAssetIDs = [target.id]
                    }
                    lastClickedAssetID = target.id
                    coordinator.focusedStageAssetID = target.id
                    scrollProxy.scrollTo(target.id)
                }
                return nil
            }
        }

        if primaryModifiers.isEmpty {
            switch event.keyCode {
            case 36, 76: // Return / Enter -> Open Quick Look
                if event.isARepeat { return nil }
                if let target = items.first(where: { library.selectedAssetIDs.contains($0.id) }) {
                    onOpenQuickLook(target)
                    return nil
                }
            case 53: // Escape -> Cancel active marquee, dismiss popover, or clear selection
                if activeMarqueeDocRect != nil {
                    activeMarqueeDocRect = nil
                    return nil
                }
                if activePopoverGroupID != nil {
                    activePopoverGroupID = nil
                    return nil
                }
                if !library.selectedAssetIDs.isEmpty {
                    library.selectedAssetIDs.removeAll()
                    return nil
                }
            default:
                break
            }
        }
        return event
    }
}

// MARK: - Precision 1-Column Table Row & 2-Column Bento Tile

private struct CompactPrecisionItemCell: View {
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    let asset: AssetRecord
    let siblings: [AssetRecord]
    let loader: ThumbnailImageLoader
    let accentColor: Color
    let accentSource: CharkleAccentSource
    let isTwoColumnGrid: Bool
    let showsBottomHairline: Bool
    let isSelected: Bool
    let isCut: Bool
    let isDropTargeted: Bool
    @Binding var isPopoverPresented: Bool
    let onHoverChanged: (Bool) -> Void
    let onSelectCard: () -> Void
    let onDoubleClickCard: () -> Void
    let onToggleVersionPopover: () -> Void
    let onCopyPrimaryFile: () -> Void
    let onTrashAsset: () -> Void
    let onPermanentlyDeleteAsset: () -> Void
    let onPinPrimaryVersion: (AssetRecord) -> Void
    let onOpenVersionInQuickLook: (AssetRecord) -> Void
    let onOpenDiffPair: (UUID?, UUID?) -> Void
    let makeDragProvider: () -> NSItemProvider
    let onDragHandleDocRectChange: (CGRect) -> Void
    let onTrailingControlsDocRectChange: (CGRect?) -> Void

    @State private var isHovered: Bool = false
    @State private var isBadgeHovered: Bool = false

    private var hasStack: Bool {
        siblings.count > 1
    }

    private var primaryVersionNumber: Int {
        asset.richMetadata?.versionStack?.versionNumber
            ?? siblings.last?.richMetadata?.versionStack?.versionNumber
            ?? 1
    }

    private var newerThanPrimaryCount: Int {
        hasStack ? AssetVersionStackMetadata.newerThanPrimaryCount(in: siblings) : 0
    }

    private var sheetSize: CGSize {
        if asset.mediaKind == .document {
            return CGSize(width: 36, height: 46)
        }
        return CGSize(width: 38, height: 42)
    }

    var body: some View {
        Group {
            if isTwoColumnGrid {
                twoColumnBentoCellBody
            } else {
                singleColumnTableRowBody
            }
        }
        .opacity(isCut ? 0.54 : 1.0)
        .onHover { hovering in
            if isHovered != hovering {
                isHovered = hovering
                onHoverChanged(hovering)
            }
        }
        .onChange(of: isHovered) { _, hovering in
            if !hovering && !hasStack {
                onTrailingControlsDocRectChange(nil)
            }
        }
    }

    // MARK: - 1-Column Unified Hairline Table Row (`minHeight: 54`)

    private var singleColumnTableRowBody: some View {
        let highlightShape = RoundedRectangle(cornerRadius: CharkleTheme.Radius.chip, style: .continuous)
        let highlightFill: Color = if isDropTargeted {
            accentColor.opacity(0.10)
        } else if isSelected {
            CharkleTheme.accentSoft(for: colorScheme, source: accentSource)
        } else if isHovered {
            Color.primary.opacity(0.04)
        } else {
            .clear
        }

        return HStack(alignment: .center, spacing: 10) {
            // Col 1 + Col 2 tight drag & click handle
            HStack(alignment: .center, spacing: 10) {
                CompactMicroFolioArtifact(
                    asset: asset,
                    hasStack: hasStack,
                    isCardHovered: isHovered,
                    loader: loader,
                    accentColor: accentColor,
                    sheetSize: sheetSize,
                    outerSlotSize: CGSize(width: 40, height: 48)
                )

                HStack(alignment: .center, spacing: 6) {
                    Text(asset.title)
                        .font(CharkleTheme.text(.body, weight: .medium))
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                        .truncationMode(.middle)

                    if asset.rating > 0 {
                        Text("★\(asset.rating)")
                            .font(CharkleTheme.text(.caption, weight: .medium))
                            .monospacedDigit()
                            .foregroundStyle(CharkleTheme.warning(for: colorScheme))
                            .fixedSize()
                    }

                    if asset.pinnedOffline {
                        Image(systemName: "arrow.down.circle.fill")
                            .font(.system(size: 10, weight: .medium))
                            .foregroundStyle(.tertiary)
                            .help("已始终保留在本地")
                    }

                    ForEach(asset.tags.prefix(2), id: \.self) { tag in
                        Text("#\(tag)")
                            .font(CharkleTheme.text(.caption))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 1.5)
                            .background(Color.primary.opacity(0.055), in: Capsule(style: .continuous))
                            .fixedSize(horizontal: true, vertical: false)
                    }
                }
            }
            .layoutPriority(1)
            .contentShape(Rectangle())
            .onTapGesture(count: 2, perform: onDoubleClickCard)
            .onTapGesture(perform: onSelectCard)
            .onDrag(makeDragProvider)
            .onGeometryChange(for: CGRect.self) { proxy in
                proxy.frame(in: .named("compactScrollDoc"))
            } action: { _, rect in
                onDragHandleDocRectChange(rect)
            }

            // Open middle expanse outside `.onDrag` so rubber-band marquee works seamlessly
            Color.clear
                .frame(minWidth: 16, maxWidth: .infinity, minHeight: 38)
                .contentShape(Rectangle())
                .onTapGesture(count: 2, perform: onDoubleClickCard)
                .onTapGesture(perform: onSelectCard)

            // Col 3: Right-aligned tabular metadata & quiet actions
            HStack(alignment: .center, spacing: 10) {
                interactiveActionCluster

                if asset.mediaKind == .audio {
                    audioWaveformSparkbar
                        .contentShape(Rectangle())
                        .onTapGesture(count: 2, perform: onDoubleClickCard)
                        .onTapGesture(perform: onSelectCard)
                }

                Text(CompactMetadataFormatters.specSummary(for: asset))
                    .font(CharkleTheme.text(.caption))
                    .monospacedDigit()
                    .foregroundStyle(CharkleTheme.secondaryInk(for: colorScheme))
                    .lineLimit(1)
                    .contentShape(Rectangle())
                    .onTapGesture(count: 2, perform: onDoubleClickCard)
                    .onTapGesture(perform: onSelectCard)

                Text(CompactMetadataFormatters.relativeTimestamp(asset.updatedAt))
                    .font(CharkleTheme.text(.caption))
                    .monospacedDigit()
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
                    .frame(width: 68, alignment: .trailing)
                    .contentShape(Rectangle())
                    .onTapGesture(count: 2, perform: onDoubleClickCard)
                    .onTapGesture(perform: onSelectCard)
            }
            .fixedSize(horizontal: true, vertical: false)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 4)
        .frame(minHeight: 54)
        .background {
            highlightShape
                .fill(highlightFill)
                .padding(.horizontal, 4)
                .padding(.vertical, 1)
        }
        .overlay(alignment: .leading) {
            if isSelected {
                Capsule(style: .continuous)
                    .fill(accentColor)
                    .frame(width: 2.5, height: 22)
                    .padding(.leading, 4)
                    .allowsHitTesting(false)
            }
        }
        .overlay(alignment: .bottom) {
            if showsBottomHairline {
                Rectangle()
                    .fill(CharkleTheme.hairline(for: colorScheme))
                    .frame(height: CharkleTheme.hairlineWidth)
                    .padding(.leading, 60)
                    .padding(.trailing, 10)
                    .allowsHitTesting(false)
            }
        }
        .overlay {
            if isDropTargeted {
                highlightShape
                    .strokeBorder(accentColor, lineWidth: 1.5)
                    .padding(.horizontal, 4)
                    .padding(.vertical, 1)
                    .allowsHitTesting(false)
            }
        }
    }

    // MARK: - 2-Column Non-Splitting Bento Tile (`height: 60`)

    private var twoColumnBentoCellBody: some View {
        let tileShape = RoundedRectangle(cornerRadius: CharkleTheme.Radius.cardOuter, style: .continuous)
        let overlayFill: Color = if isDropTargeted {
            accentColor.opacity(0.10)
        } else if isSelected {
            CharkleTheme.accentSoft(for: colorScheme, source: accentSource)
        } else if isHovered {
            Color.primary.opacity(0.04)
        } else {
            .clear
        }
        let borderColor: Color = (isSelected || isDropTargeted)
            ? accentColor
            : CharkleTheme.hairline(for: colorScheme)
        let borderWidth: CGFloat = (isSelected || isDropTargeted) ? 1.5 : CharkleTheme.hairlineWidth

        return HStack(alignment: .center, spacing: 10) {
            HStack(alignment: .center, spacing: 10) {
                CompactMicroFolioArtifact(
                    asset: asset,
                    hasStack: hasStack,
                    isCardHovered: isHovered,
                    loader: loader,
                    accentColor: accentColor,
                    sheetSize: sheetSize,
                    outerSlotSize: CGSize(width: 40, height: 48)
                )

                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 5) {
                        Text(asset.title)
                            .font(CharkleTheme.text(.body, weight: .medium))
                            .foregroundStyle(.primary)
                            .lineLimit(1)
                            .truncationMode(.middle)

                        if asset.rating > 0 {
                            Text("★\(asset.rating)")
                                .font(CharkleTheme.text(.caption, weight: .medium))
                                .monospacedDigit()
                                .foregroundStyle(CharkleTheme.warning(for: colorScheme))
                                .fixedSize()
                        }
                    }

                    HStack(spacing: 6) {
                        Text(CompactMetadataFormatters.specSummary(for: asset))
                            .font(CharkleTheme.text(.caption))
                            .monospacedDigit()
                            .foregroundStyle(CharkleTheme.secondaryInk(for: colorScheme))
                            .lineLimit(1)

                        Text(CompactMetadataFormatters.relativeTimestamp(asset.updatedAt))
                            .font(CharkleTheme.text(.caption))
                            .monospacedDigit()
                            .foregroundStyle(.tertiary)
                            .lineLimit(1)
                            .fixedSize()
                    }
                }
            }
            .layoutPriority(1)
            .contentShape(Rectangle())
            .onTapGesture(count: 2, perform: onDoubleClickCard)
            .onTapGesture(perform: onSelectCard)
            .onDrag(makeDragProvider)
            .onGeometryChange(for: CGRect.self) { proxy in
                proxy.frame(in: .named("compactScrollDoc"))
            } action: { _, rect in
                onDragHandleDocRectChange(rect)
            }

            // Open middle space for rubber-band marquee selection
            Color.clear
                .frame(minWidth: 10, maxWidth: .infinity, minHeight: 42)
                .contentShape(Rectangle())
                .onTapGesture(count: 2, perform: onDoubleClickCard)
                .onTapGesture(perform: onSelectCard)

            interactiveActionCluster
                .fixedSize(horizontal: true, vertical: false)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .frame(height: 60)
        .background {
            tileShape
                .fill(CharkleTheme.surfaceElevated(for: colorScheme))
                .overlay(tileShape.fill(overlayFill))
        }
        .overlay {
            tileShape
                .strokeBorder(borderColor, lineWidth: borderWidth)
                .allowsHitTesting(false)
        }
    }

    // MARK: - Quiet Hover Copy + Trash + Anchored Version Trigger Badge

    @ViewBuilder
    private var interactiveActionCluster: some View {
        HStack(alignment: .center, spacing: 4) {
            if !asset.isTrashed {
                Button(action: onCopyPrimaryFile) {
                    Image(systemName: "doc.on.doc")
                        .font(.system(size: 11.5, weight: .medium))
                }
                .buttonStyle(.charkle(.subtle, size: .icon, iconDimension: 24))
                .help(hasStack ? "拷贝主版本原文件 (⌘C)" : "拷贝原文件 (⌘C)")
                .opacity(isHovered ? 1 : 0)
                .allowsHitTesting(isHovered)

                Button(role: .destructive, action: onTrashAsset) {
                    Image(systemName: "trash")
                        .font(.system(size: 11.5, weight: .medium))
                }
                .buttonStyle(.charkle(.subtle, size: .icon, iconDimension: 24))
                .help("移至废纸篓")
                .opacity(isHovered ? 1 : 0)
                .allowsHitTesting(isHovered)
            } else {
                Button(role: .destructive, action: onPermanentlyDeleteAsset) {
                    Image(systemName: "trash.slash")
                        .font(.system(size: 11.5, weight: .medium))
                }
                .buttonStyle(.charkle(.subtle, size: .icon, iconDimension: 24))
                .help("彻底删除")
                .opacity(isHovered ? 1 : 0)
                .allowsHitTesting(isHovered)
            }

            if hasStack {
                quietVersionTriggerBadge
            }
        }
        .onGeometryChange(for: CGRect.self) { proxy in
            proxy.frame(in: .named("compactScrollDoc"))
        } action: { _, rect in
            if hasStack || isHovered {
                onTrailingControlsDocRectChange(rect)
            } else {
                onTrailingControlsDocRectChange(nil)
            }
        }
    }

    private var quietVersionTriggerBadge: some View {
        let badgeFill = Color.primary.opacity((isBadgeHovered || isPopoverPresented) ? 0.09 : 0.055)

        return Button(action: onToggleVersionPopover) {
            HStack(spacing: 3.5) {
                Image(systemName: "square.stack.3d.up")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(isPopoverPresented ? Color.primary : CharkleTheme.secondaryInk(for: colorScheme))

                HStack(spacing: 0) {
                    Text("v\(primaryVersionNumber)")
                        .font(CharkleTheme.text(.caption, weight: .semibold))
                        .monospacedDigit()
                        .foregroundStyle(.primary)

                    Text("/\(siblings.count)")
                        .font(CharkleTheme.text(.caption))
                        .monospacedDigit()
                        .foregroundStyle(.tertiary)
                }

                if newerThanPrimaryCount > 0 {
                    Circle()
                        .fill(CharkleTheme.warning(for: colorScheme))
                        .frame(width: 5, height: 5)
                }

                CharkleDropdownChevron(size: 7.5)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 3.5)
            .background(badgeFill, in: Capsule(style: .continuous))
            .overlay {
                if isPopoverPresented {
                    Capsule(style: .continuous)
                        .strokeBorder(CharkleTheme.hairline(for: colorScheme), lineWidth: CharkleTheme.hairlineWidth)
                }
            }
            .contentShape(Capsule(style: .continuous))
        }
        .buttonStyle(CharkleTactileButtonStyle())
        .onHover { hovering in
            if isBadgeHovered != hovering {
                isBadgeHovered = hovering
            }
        }
        .help("查看历史版本")
        .popover(isPresented: $isPopoverPresented, arrowEdge: .bottom) {
            VersionTimelinePopoverView(
                primaryAsset: asset,
                siblings: siblings,
                accentColor: accentColor,
                accentSource: accentSource,
                onPinPrimaryVersion: onPinPrimaryVersion,
                onOpenVersionInQuickLook: onOpenVersionInQuickLook,
                onOpenDiffPair: onOpenDiffPair,
                onDismiss: { isPopoverPresented = false }
            )
            .environment(\.charkleAccentSource, accentSource)
            .tint(accentColor)
        }
    }

    private var audioWaveformSparkbar: some View {
        let peaks = asset.waveformPeaks.isEmpty
            ? [Float]([0.35, 0.70, 0.45, 0.88, 0.62, 0.78, 0.50, 0.84, 0.42, 0.68])
            : asset.waveformPeaks
        let barCount = 10

        return HStack(alignment: .center, spacing: 2) {
            ForEach(0..<barCount, id: \.self) { idx in
                let sample = peaks[idx * peaks.count / max(1, barCount)]
                let barHeight = max(4, min(14, CGFloat(sample) * 14))
                Capsule(style: .continuous)
                    .fill(CharkleTheme.secondaryInk(for: colorScheme))
                    .frame(width: 2, height: barHeight)
            }
        }
        .padding(.horizontal, 4)
        .frame(height: 20)
    }
}

// MARK: - 4. Universal Vertical Version History Popover (`VersionTimelinePopoverView`)

private struct VersionTimelinePopoverView: View {
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    let primaryAsset: AssetRecord
    let siblings: [AssetRecord]
    let accentColor: Color
    let accentSource: CharkleAccentSource
    let onPinPrimaryVersion: (AssetRecord) -> Void
    let onOpenVersionInQuickLook: (AssetRecord) -> Void
    let onOpenDiffPair: (UUID?, UUID?) -> Void
    let onDismiss: () -> Void

    private var primaryVersionNumber: Int {
        primaryAsset.richMetadata?.versionStack?.versionNumber
            ?? siblings.last?.richMetadata?.versionStack?.versionNumber
            ?? 1
    }

    var body: some View {
        let reversedSiblings = Array(siblings.reversed())

        VStack(alignment: .leading, spacing: 0) {
            // Header (`padding: 12 14 8 14`)
            HStack(alignment: .center, spacing: 6) {
                Text("历史版本")
                    .font(CharkleTheme.text(.caption, weight: .semibold))
                    .foregroundStyle(.primary)

                Text("\(siblings.count)")
                    .font(CharkleTheme.text(.caption))
                    .monospacedDigit()
                    .foregroundStyle(.tertiary)

                Spacer(minLength: 8)

                if siblings.count >= 2 {
                    Button {
                        let baseID = siblings[siblings.count - 2].id
                        let targetID = siblings[siblings.count - 1].id
                        onDismiss()
                        onOpenDiffPair(baseID, targetID)
                    } label: {
                        Label("对比差异", systemImage: "arrow.left.arrow.right")
                    }
                    .buttonStyle(.charkle(.subtle, size: .xs))
                }
            }
            .padding(.top, 12)
            .padding(.horizontal, 14)
            .padding(.bottom, 8)

            CharkleHairlineDivider()

            if reversedSiblings.count <= 5 {
                timelineRowsContent(reversedSiblings: reversedSiblings)
            } else {
                ScrollView(.vertical) {
                    timelineRowsContent(reversedSiblings: reversedSiblings)
                }
                .charkleCleanScrollbars(hidden: false)
                .frame(maxHeight: 280)
            }
        }
        .frame(width: 312)
        .background {
            if reduceTransparency {
                CharkleTheme.surfaceElevated(for: colorScheme)
            } else {
                Rectangle().fill(.ultraThinMaterial)
            }
        }
    }

    private func timelineRowsContent(reversedSiblings: [AssetRecord]) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(reversedSiblings.enumerated()), id: \.element.id) { revIdx, ver in
                let origIdx = siblings.count - 1 - revIdx
                let prevVer: AssetRecord? = origIdx > 0 ? siblings[origIdx - 1] : nil
                VersionTimelineRow(
                    versionAsset: ver,
                    previousAsset: prevVer,
                    fallbackVersionNumber: origIdx + 1,
                    isPrimary: ver.id == primaryAsset.id,
                    primaryVersionNumber: primaryVersionNumber,
                    isFirstInTimeline: revIdx == 0,
                    isLastInTimeline: revIdx == reversedSiblings.count - 1,
                    accentColor: accentColor,
                    accentSource: accentSource,
                    onPinPrimary: {
                        onPinPrimaryVersion(ver)
                    },
                    onOpenQuickLook: {
                        onDismiss()
                        onOpenVersionInQuickLook(ver)
                    },
                    onOpenDiffWithPrevious: {
                        guard let prevVer else { return }
                        onDismiss()
                        onOpenDiffPair(prevVer.id, ver.id)
                    }
                )
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
    }
}

private struct VersionTimelineRow: View {
    @Environment(\.colorScheme) private var colorScheme

    let versionAsset: AssetRecord
    let previousAsset: AssetRecord?
    let fallbackVersionNumber: Int
    let isPrimary: Bool
    let primaryVersionNumber: Int
    let isFirstInTimeline: Bool
    let isLastInTimeline: Bool
    let accentColor: Color
    let accentSource: CharkleAccentSource
    let onPinPrimary: () -> Void
    let onOpenQuickLook: () -> Void
    let onOpenDiffWithPrevious: () -> Void

    @State private var isHovered: Bool = false

    var body: some View {
        let vMeta = versionAsset.richMetadata?.versionStack
        let vNum = vMeta?.versionNumber ?? fallbackVersionNumber
        let isUnreviewed = vNum > primaryVersionNumber && !isPrimary
        let descriptor = AssetVersionStackMetadata.cleanDisplayDescriptor(
            changeNote: vMeta?.changeNote,
            versionLabel: vMeta?.versionLabel,
            editorName: vMeta?.editorName
        )
        let cleanEditor: String? = {
            guard let raw = vMeta?.editorName?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !raw.isEmpty,
                  raw != "本机" else {
                return nil
            }
            if let descriptor, descriptor.localizedCaseInsensitiveContains(raw) {
                return nil
            }
            return raw
        }()
        let changedCount = (previousAsset != nil)
            ? (versionAsset.richMetadata?.document?.diffSummary?.totalChangedBlocks ?? 0)
            : 0
        let hasHighRisk = (versionAsset.richMetadata?.document?.diffSummary?.totalHighRiskChanges ?? 0) > 0
        let rowShape = RoundedRectangle(cornerRadius: CharkleTheme.Radius.chip, style: .continuous)
        let rowBg: Color = if isPrimary {
            CharkleTheme.accentSoft(for: colorScheme, source: accentSource)
        } else if isHovered {
            Color.primary.opacity(0.045)
        } else {
            .clear
        }

        HStack(alignment: .center, spacing: 6) {
            // Left gutter (`width: 20`): continuous 1pt vertical spine connecting 8pt circular nodes
            ZStack {
                VStack(spacing: 0) {
                    Rectangle()
                        .fill(isFirstInTimeline ? Color.clear : CharkleTheme.hairline(for: colorScheme))
                        .frame(width: 1)
                        .frame(maxHeight: .infinity)
                    Rectangle()
                        .fill(isLastInTimeline ? Color.clear : CharkleTheme.hairline(for: colorScheme))
                        .frame(width: 1)
                        .frame(maxHeight: .infinity)
                }

                if isPrimary {
                    Circle()
                        .fill(accentColor)
                        .frame(width: 8, height: 8)
                } else {
                    Circle()
                        .fill(CharkleTheme.surfaceElevated(for: colorScheme))
                        .overlay(
                            Circle().strokeBorder(
                                isUnreviewed
                                    ? CharkleTheme.warning(for: colorScheme)
                                    : Color.secondary.opacity(0.45),
                                lineWidth: 1.5
                            )
                        )
                        .frame(width: 8, height: 8)
                }
            }
            .frame(width: 20)

            // Row body (`padding: 7 10`)
            HStack(alignment: .center, spacing: 6) {
                Button(action: onOpenQuickLook) {
                    VStack(alignment: .leading, spacing: 2.5) {
                        HStack(alignment: .center, spacing: 6) {
                            Text("v\(vNum)")
                                .font(CharkleTheme.text(.body, weight: .semibold))
                                .monospacedDigit()
                                .foregroundStyle(.primary)

                            if let descriptor {
                                Text(descriptor)
                                    .font(CharkleTheme.text(.caption, weight: .medium))
                                    .foregroundStyle(CharkleTheme.secondaryInk(for: colorScheme))
                                    .lineLimit(1)
                            }

                            if isPrimary {
                                Text("主版")
                                    .font(CharkleTheme.text(.caption, weight: .semibold))
                                    .foregroundStyle(accentColor)
                                    .padding(.horizontal, 5)
                                    .padding(.vertical, 1)
                                    .background(
                                        CharkleTheme.accentSoft(for: colorScheme, source: accentSource),
                                        in: RoundedRectangle(cornerRadius: CharkleTheme.Radius.xs, style: .continuous)
                                    )
                                    .fixedSize()
                            }
                        }

                        HStack(alignment: .center, spacing: 6) {
                            Text(CompactMetadataFormatters.relativeTimestamp(versionAsset.updatedAt))
                                .font(CharkleTheme.text(.caption))
                                .monospacedDigit()
                                .foregroundStyle(.tertiary)

                            if let cleanEditor {
                                Text(cleanEditor)
                                    .font(CharkleTheme.text(.caption))
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                            }
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("预览 v\(vNum)")

                if changedCount > 0 {
                    let deltaInk = hasHighRisk
                        ? CharkleTheme.warning(for: colorScheme)
                        : CharkleTheme.secondaryInk(for: colorScheme)
                    let deltaBg = hasHighRisk
                        ? CharkleTheme.warning(for: colorScheme).opacity(colorScheme == .dark ? 0.16 : 0.12)
                        : Color.primary.opacity(0.055)

                    Button(action: onOpenDiffWithPrevious) {
                        Text("Δ \(changedCount)")
                            .font(CharkleTheme.text(.caption, weight: .semibold))
                            .monospacedDigit()
                            .foregroundStyle(deltaInk)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(deltaBg, in: Capsule(style: .continuous))
                    }
                    .buttonStyle(CharkleTactileButtonStyle())
                    .fixedSize()
                    .help("对比此版本改动")
                }

                if !isPrimary {
                    Button(action: onPinPrimary) {
                        Image(systemName: "pin")
                            .font(.system(size: 11, weight: .medium))
                    }
                    .buttonStyle(.charkle(.subtle, size: .icon, iconDimension: 24))
                    .opacity(isHovered ? 1.0 : 0.45)
                    .help("设为主版本")
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .background(rowBg, in: rowShape)
        }
        .padding(.vertical, 1)
        .onHover { hovering in
            if isHovered != hovering {
                isHovered = hovering
            }
        }
    }
}

// MARK: - Crisp Miniature Artwork / Page Cover (`36 × 46pt` Docs / `38 × 42pt` Media)

private struct CompactMicroFolioArtifact: View {
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    let asset: AssetRecord
    let hasStack: Bool
    let isCardHovered: Bool
    let loader: ThumbnailImageLoader
    let accentColor: Color
    let sheetSize: CGSize
    let outerSlotSize: CGSize

    @State private var loadedDocImage: NSImage? = nil
    @State private var loadedDocAssetID: UUID? = nil

    private var extLabel: String {
        CanvasFormatters.fileExtensionBadge(for: asset.fileName)
    }

    private var expectsRealDocumentPageImage: Bool {
        guard asset.mediaKind == .document else { return false }
        let ext = (asset.fileName as NSString).pathExtension.lowercased()
        let isRichOrPDF = (ext == "pdf") || MediaPipeline.isRichLayoutDocumentExtension(ext)
        let isLegacyProcedural = (asset.pixelWidth == 900 && asset.pixelHeight == 1_240)
        return isRichOrPDF && !isLegacyProcedural
    }

    private var resolvedDocumentPageImage: NSImage? {
        guard expectsRealDocumentPageImage else { return nil }
        if loadedDocAssetID == asset.id, let loadedDocImage {
            return loadedDocImage
        }
        return loader.cachedImage(for: asset.id, tier: .grid520)
    }

    private var docFamily: DocumentFormatFamily {
        asset.richMetadata?.document?.parsedFormatFamily ?? DocumentFormatFamily.detect(fileExtension: extLabel)
    }

    var body: some View {
        let sheetShape = RoundedRectangle(cornerRadius: CharkleTheme.Radius.sm, style: .continuous)
        let opticalRim = Color.primary.opacity(0.08)
        let fanActive = hasStack && isCardHovered && !reduceMotion

        ZStack {
            if hasStack {
                sheetShape
                    .fill(CharkleTheme.surfaceSubtle(for: colorScheme))
                    .overlay(sheetShape.strokeBorder(opticalRim, lineWidth: CharkleTheme.hairlineWidth))
                    .frame(width: sheetSize.width, height: sheetSize.height)
                    .rotationEffect(.degrees(fanActive ? 3.5 : 0), anchor: .bottomLeading)
                    .offset(x: fanActive ? 3.5 : 2.5, y: fanActive ? -2.0 : -1.5)
                    .animation(
                        reduceMotion ? nil : CharkleMotion.hoverPress,
                        value: fanActive
                    )
            }

            coverContent
                .frame(width: sheetSize.width, height: sheetSize.height)
                .clipShape(sheetShape)
                .overlay(sheetShape.strokeBorder(opticalRim, lineWidth: CharkleTheme.hairlineWidth))
                .shadow(
                    color: .black.opacity(colorScheme == .dark ? 0.28 : 0.08),
                    radius: 3,
                    y: 1.5
                )
                .rotation3DEffect(
                    .degrees(fanActive ? -8 : 0),
                    axis: (x: 0, y: 1, z: 0),
                    anchor: .leading,
                    perspective: 0.4
                )
                .animation(
                    reduceMotion ? nil : CharkleMotion.hoverPress,
                    value: fanActive
                )
        }
        .frame(width: outerSlotSize.width, height: outerSlotSize.height)
        .task(id: "\(asset.id.uuidString)-\(loader.invalidationVersion)-\(expectsRealDocumentPageImage)") {
            guard expectsRealDocumentPageImage else {
                if loadedDocImage != nil {
                    loadedDocImage = nil
                    loadedDocAssetID = nil
                }
                return
            }
            let targetID = asset.id
            if let cached = loader.cachedImage(for: targetID, tier: .grid520) {
                loadedDocAssetID = targetID
                loadedDocImage = cached
                return
            }
            let fetched = await loader.loadImage(for: targetID, tier: .grid520)
            if !Task.isCancelled {
                loadedDocAssetID = targetID
                loadedDocImage = fetched
            }
        }
        .onDisappear {
            if loadedDocImage != nil {
                loadedDocImage = nil
                loadedDocAssetID = nil
            }
        }
    }

    @ViewBuilder
    private var coverContent: some View {
        switch asset.mediaKind {
        case .document:
            if let realPage = resolvedDocumentPageImage {
                Image(nsImage: realPage)
                    .resizable()
                    .interpolation(.high)
                    .scaledToFill()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .clipped()
                    .background(Color.white)
            } else {
                minimalPaperSheet
            }
        case .audio:
            minimalAudioSheet
        default:
            AssetThumbnailSurface(
                asset: asset,
                loader: loader,
                tier: .grid520,
                cornerRadius: CharkleTheme.Radius.sm,
                enableHoverPlayback: false
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    /// Clean minimal paper rectangle with only a subtle muted monospaced format tag near the bottom.
    private var minimalPaperSheet: some View {
        let paperFill = colorScheme == .dark
            ? CharkleTheme.surfaceSubtle(for: .dark)
            : CharkleTheme.surfaceElevated(for: .light)

        return VStack(spacing: 0) {
            Spacer(minLength: 0)
            Text(docFamily.badgeLabel)
                .font(CharkleTheme.text(.caption, weight: .medium, design: .monospaced))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .minimumScaleFactor(0.65)
                .fixedSize(horizontal: true, vertical: false)
                .scaleEffect(0.78)
                .padding(.bottom, 3)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(paperFill)
    }

    private var minimalAudioSheet: some View {
        VStack(spacing: 2) {
            Spacer(minLength: 2)
            Image(systemName: "waveform")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.secondary)
            Spacer(minLength: 0)
            Text(extLabel)
                .font(CharkleTheme.text(.caption, weight: .medium, design: .monospaced))
                .foregroundStyle(.tertiary)
                .lineLimit(1)
                .minimumScaleFactor(0.65)
                .fixedSize(horizontal: true, vertical: false)
                .scaleEffect(0.75)
                .padding(.bottom, 2)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(CharkleTheme.surfaceSubtle(for: colorScheme))
    }
}

// MARK: - Concise Tabular Metadata & Timestamp Formatters

private enum CompactMetadataFormatters {
    private static let sameYearDateFormatter: DateFormatter = {
        let fmt = DateFormatter()
        fmt.dateFormat = "MM-dd"
        return fmt
    }()

    private static let olderYearDateFormatter: DateFormatter = {
        let fmt = DateFormatter()
        fmt.dateFormat = "yy-MM-dd"
        return fmt
    }()

    static func specSummary(for asset: AssetRecord) -> String {
        let ext = CanvasFormatters.fileExtensionBadge(for: asset.fileName)
        switch asset.mediaKind {
        case .document:
            var parts: [String] = []
            if let doc = asset.richMetadata?.document {
                if !doc.sheetNames.isEmpty {
                    parts.append("\(doc.sheetNames.count) 工作表")
                } else if doc.pageCount > 0 {
                    parts.append("\(doc.pageCount) 页")
                }
                if doc.wordCount > 0 {
                    parts.append("\(doc.wordCount.formatted()) 字")
                }
                if !doc.hasTextLayer {
                    parts.append("扫描件")
                }
            }
            if parts.isEmpty {
                if asset.fileSizeBytes > 0 {
                    return ByteCountFormatter.string(fromByteCount: asset.fileSizeBytes, countStyle: .file)
                }
                return ext
            }
            return parts.joined(separator: " / ")

        case .image, .animatedImage, .designFile:
            if asset.pixelWidth > 0 && asset.pixelHeight > 0 {
                return "\(asset.pixelWidth) × \(asset.pixelHeight)"
            }
            if asset.fileSizeBytes > 0 {
                return ByteCountFormatter.string(fromByteCount: asset.fileSizeBytes, countStyle: .file)
            }
            return ext

        case .video, .audio:
            let dur = CanvasFormatters.durationString(asset.durationSeconds)
            if asset.pixelWidth > 0 && asset.pixelHeight > 0 {
                return "\(dur) / \(asset.pixelWidth) × \(asset.pixelHeight)"
            }
            return dur

        case .webBookmark:
            if let repo = asset.richMetadata?.githubRepo {
                return "\(repo.fullName) / ★\(repo.stars)"
            }
            if let post = asset.richMetadata?.socialPost {
                return post.platform.displayName
            }
            return asset.sourceDomain ?? "网页书签"

        case .model3D:
            if asset.fileSizeBytes > 0 {
                return ByteCountFormatter.string(fromByteCount: asset.fileSizeBytes, countStyle: .file)
            }
            return asset.richMetadata?.model3DFormat ?? ext
        }
    }

    static func relativeTimestamp(_ date: Date) -> String {
        let now = Date()
        let elapsed = max(0, now.timeIntervalSince(date))
        if elapsed < 60 { return "刚刚" }
        if elapsed < 3600 { return "\(Int(elapsed / 60)) 分钟前" }
        if elapsed < 86400 { return "\(Int(elapsed / 3600)) 小时前" }
        let cal = Calendar.current
        if cal.component(.year, from: date) == cal.component(.year, from: now) {
            return sameYearDateFormatter.string(from: date)
        }
        return olderYearDateFormatter.string(from: date)
    }
}

// MARK: - Drop-onto-Card Version Stack Merge Delegate

private struct CompactCardStackDropDelegate: DropDelegate {
    let targetAsset: AssetRecord
    let library: LibraryStore
    @Binding var dropTargetedCardID: UUID?
    let onMergeAssets: ([UUID], UUID) -> Void
    let onDropExternalFiles: ([URL], AssetRecord) -> Void

    func dropEntered(info: DropInfo) {
        let payload = CharkleDragPasteboardResolver.resolveSynchronously { url in
            library.resolveInternalCachedAssetID(for: url)
        }
        let otherInternal = payload.assetIDs.filter { $0 != targetAsset.id }
        if !otherInternal.isEmpty || !payload.externalFileURLs.isEmpty {
            dropTargetedCardID = targetAsset.id
        }
    }

    func dropExited(info: DropInfo) {
        if dropTargetedCardID == targetAsset.id {
            dropTargetedCardID = nil
        }
    }

    func performDrop(info: DropInfo) -> Bool {
        if dropTargetedCardID == targetAsset.id {
            dropTargetedCardID = nil
        }
        let payload = CharkleDragPasteboardResolver.resolveSynchronously { url in
            library.resolveInternalCachedAssetID(for: url)
        }
        let otherInternal = payload.assetIDs.filter { $0 != targetAsset.id }
        if !otherInternal.isEmpty {
            var combined = otherInternal
            combined.append(targetAsset.id)
            onMergeAssets(combined, targetAsset.id)
            return true
        }
        if !payload.externalFileURLs.isEmpty {
            onDropExternalFiles(payload.externalFileURLs, targetAsset)
            return true
        }
        return false
    }
}

// MARK: - Compact Stage Local Key & Rubber-Band Marquee Monitor

private struct CompactStageKeyboardBridge: NSViewRepresentable {
    let isSuspended: Bool
    let topContentInset: CGFloat
    let canBeginMarqueeAtStagePoint: (CGPoint) -> Bool
    let stageToDocPoint: (CGPoint) -> CGPoint
    let onBeginMarquee: (NSEvent.ModifierFlags) -> Void
    let onUpdateMarquee: (CGPoint, CGPoint, NSEvent.ModifierFlags) -> Void
    let onEndMarquee: () -> Void
    let onKeyDown: (NSEvent) -> NSEvent?

    func makeNSView(context: Context) -> BridgeView {
        let view = BridgeView()
        apply(to: view)
        return view
    }

    func updateNSView(_ nsView: BridgeView, context: Context) {
        apply(to: nsView)
    }

    private func apply(to nsView: BridgeView) {
        let wasSuspended = nsView.isSuspended
        nsView.isSuspended = isSuspended
        nsView.topContentInset = topContentInset
        nsView.canBeginMarqueeAtStagePoint = canBeginMarqueeAtStagePoint
        nsView.stageToDocPoint = stageToDocPoint
        nsView.onBeginMarquee = onBeginMarquee
        nsView.onUpdateMarquee = onUpdateMarquee
        nsView.onEndMarquee = onEndMarquee
        nsView.onKeyDown = onKeyDown
        if !wasSuspended && isSuspended {
            nsView.cancelActiveMarqueeIfNeeded()
        }
    }

    static func dismantleNSView(_ nsView: BridgeView, coordinator: ()) {
        nsView.teardown()
    }

    final class BridgeView: NSView {
        private struct MarqueeSession {
            let startStagePoint: CGPoint
            let startDocPoint: CGPoint
            let modifiers: NSEvent.ModifierFlags
            var isActive: Bool
        }

        override nonisolated var isFlipped: Bool { true }

        var isSuspended: Bool = false
        var topContentInset: CGFloat = 0
        var canBeginMarqueeAtStagePoint: ((CGPoint) -> Bool)?
        var stageToDocPoint: ((CGPoint) -> CGPoint)?
        var onBeginMarquee: ((NSEvent.ModifierFlags) -> Void)?
        var onUpdateMarquee: ((CGPoint, CGPoint, NSEvent.ModifierFlags) -> Void)?
        var onEndMarquee: (() -> Void)?
        var onKeyDown: ((NSEvent) -> NSEvent?)?

        private var keyMonitor: Any?
        private var mouseMonitor: Any?
        private var autoscrollTimer: Timer?
        private var marqueeSession: MarqueeSession?
        private weak var cachedScrollView: NSScrollView?

        override func hitTest(_ point: NSPoint) -> NSView? { nil }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if window != nil {
                installMonitorsIfNeeded()
            } else {
                teardown()
            }
        }

        private func installMonitorsIfNeeded() {
            if keyMonitor == nil {
                keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
                    guard let self,
                          !self.isSuspended,
                          let hostWindow = self.window,
                          event.window === hostWindow,
                          hostWindow.attachedSheet == nil,
                          NSApp?.modalWindow == nil,
                          !self.isHiddenOrHasHiddenAncestor else {
                        return event
                    }
                    if event.keyCode == 53, self.marqueeSession?.isActive == true {
                        self.cancelActiveMarqueeIfNeeded()
                        return nil
                    }
                    return self.onKeyDown?(event) ?? event
                }
            }

            if mouseMonitor == nil {
                mouseMonitor = NSEvent.addLocalMonitorForEvents(
                    matching: [.leftMouseDown, .leftMouseDragged, .leftMouseUp]
                ) { [weak self] event in
                    self?.handleMouseEvent(event) ?? event
                }
            }
        }

        private func resolveStageScrollView() -> NSScrollView? {
            if let sv = cachedScrollView, sv.window === self.window {
                return sv
            }
            var cursor: NSView? = self.superview
            for _ in 0..<3 {
                guard let container = cursor else { break }
                if let found = Self.firstScrollView(in: container) {
                    cachedScrollView = found
                    return found
                }
                cursor = container.superview
            }
            return nil
        }

        private static func firstScrollView(in root: NSView) -> NSScrollView? {
            if let sv = root as? NSScrollView { return sv }
            for sub in root.subviews {
                if let sv = sub as? NSScrollView { return sv }
            }
            for sub in root.subviews {
                if let nested = firstScrollView(in: sub) { return nested }
            }
            return nil
        }

        private func handleMouseEvent(_ event: NSEvent) -> NSEvent? {
            switch event.type {
            case .leftMouseDown:
                stopAutoscrollTimer()
                marqueeSession = nil
                guard !isSuspended,
                      !event.modifierFlags.contains(.control),
                      let hostWindow = self.window,
                      event.window === hostWindow,
                      hostWindow.attachedSheet == nil,
                      NSApp?.modalWindow == nil,
                      !self.isHiddenOrHasHiddenAncestor else {
                    return event
                }
                let stagePt = self.convert(event.locationInWindow, from: nil)
                guard self.bounds.contains(stagePt), stagePt.y >= topContentInset else {
                    return event
                }
                if let hitView = hostWindow.contentView?.hitTest(event.locationInWindow) {
                    if hitView is NSScroller || hitView is NSText || hitView is NSTextView || hitView is NSControl {
                        return event
                    }
                    if let stageSV = resolveStageScrollView() {
                        if hitView !== stageSV && !hitView.isDescendant(of: stageSV) {
                            return event
                        }
                        if let enclosingSV = hitView.enclosingScrollView, enclosingSV !== stageSV {
                            return event
                        }
                    }
                }
                guard canBeginMarqueeAtStagePoint?(stagePt) == true,
                      let docPt = stageToDocPoint?(stagePt) else {
                    return event
                }
                let mods = event.modifierFlags.intersection([.command, .shift])
                marqueeSession = MarqueeSession(
                    startStagePoint: stagePt,
                    startDocPoint: docPt,
                    modifiers: mods,
                    isActive: false
                )
                return event

            case .leftMouseDragged:
                guard var session = marqueeSession else { return event }
                guard !isSuspended, let hostWindow = self.window, event.window === hostWindow else {
                    cancelActiveMarqueeIfNeeded()
                    return event
                }
                let stagePt = self.convert(event.locationInWindow, from: nil)
                if !session.isActive {
                    let dx = stagePt.x - session.startStagePoint.x
                    let dy = stagePt.y - session.startStagePoint.y
                    guard (dx * dx + dy * dy) >= 16 else { return event }
                    session.isActive = true
                    marqueeSession = session
                    onBeginMarquee?(session.modifiers)
                }
                let liveMods = event.modifierFlags.intersection([.command, .shift]).union(session.modifiers)
                stepAutoscrollIfNeeded(atStagePoint: stagePt)
                onUpdateMarquee?(session.startDocPoint, stagePt, liveMods)
                updateAutoscrollTimerState(atStagePoint: stagePt)
                return nil

            case .leftMouseUp:
                stopAutoscrollTimer()
                guard let session = marqueeSession else { return event }
                marqueeSession = nil
                if session.isActive {
                    onEndMarquee?()
                    return nil
                }
                return event

            default:
                return event
            }
        }

        private func autoscrollDeltaY(forStageY y: CGFloat) -> CGFloat {
            let topZone = topContentInset + 28
            let bottomZone = max(topZone + 20, bounds.height - 32)
            if y < topZone {
                let depth = min(1.0, max(0.0, (topZone - y) / 48.0))
                return -(3.0 + depth * 12.0)
            }
            if y > bottomZone {
                let depth = min(1.0, max(0.0, (y - bottomZone) / 48.0))
                return 3.0 + depth * 12.0
            }
            return 0
        }

        @discardableResult
        private func stepAutoscrollIfNeeded(atStagePoint stagePt: CGPoint) -> Bool {
            let deltaY = autoscrollDeltaY(forStageY: stagePt.y)
            guard abs(deltaY) > 0.1,
                  let scrollView = resolveStageScrollView(),
                  let docView = scrollView.documentView else {
                return false
            }
            let clip = scrollView.contentView
            var origin = clip.bounds.origin
            let maxY = max(0, docView.bounds.height - clip.bounds.height)
            let nextY = max(0, min(maxY, origin.y + deltaY))
            guard abs(nextY - origin.y) > 0.25 else { return false }
            origin.y = nextY
            clip.scroll(to: origin)
            scrollView.reflectScrolledClipView(clip)
            return true
        }

        private func updateAutoscrollTimerState(atStagePoint stagePt: CGPoint) {
            if abs(autoscrollDeltaY(forStageY: stagePt.y)) > 0.1 {
                guard autoscrollTimer == nil else { return }
                autoscrollTimer = Timer.scheduledTimer(withTimeInterval: 0.016, repeats: true) { [weak self] _ in
                    Task { @MainActor [weak self] in
                        guard let self,
                              !self.isSuspended,
                              let session = self.marqueeSession,
                              session.isActive,
                              let hostWindow = self.window else {
                            self?.stopAutoscrollTimer()
                            return
                        }
                        let liveWinPt = hostWindow.mouseLocationOutsideOfEventStream
                        let liveStagePt = self.convert(liveWinPt, from: nil)
                        if self.stepAutoscrollIfNeeded(atStagePoint: liveStagePt) {
                            let liveMods = NSEvent.modifierFlags.intersection([.command, .shift]).union(session.modifiers)
                            self.onUpdateMarquee?(session.startDocPoint, liveStagePt, liveMods)
                        }
                    }
                }
            } else {
                stopAutoscrollTimer()
            }
        }

        private func stopAutoscrollTimer() {
            autoscrollTimer?.invalidate()
            autoscrollTimer = nil
        }

        func cancelActiveMarqueeIfNeeded() {
            stopAutoscrollTimer()
            let wasActive = marqueeSession?.isActive == true
            marqueeSession = nil
            if wasActive {
                onEndMarquee?()
            }
        }

        func teardown() {
            stopAutoscrollTimer()
            marqueeSession = nil
            if let keyMonitor {
                NSEvent.removeMonitor(keyMonitor)
                self.keyMonitor = nil
            }
            if let mouseMonitor {
                NSEvent.removeMonitor(mouseMonitor)
                self.mouseMonitor = nil
            }
        }

        isolated deinit {
            teardown()
        }
    }
}
