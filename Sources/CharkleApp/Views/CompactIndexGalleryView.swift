import AppKit
import CharkleCanvas
import CharkleCore
import SwiftUI
import UniformTypeIdentifiers

/// 5th Universal Gallery Mode (`GalleryLayoutMode.compactList`, shortcut `5`):
/// Tactile Studio Compact View supporting both 2-Column Tactile Index Cards (`双列索引卡`)
/// and 1-Column Folio Strips (`单列折页条`), 3D hover-fanning Micro-Folio stacks,
/// 12-segment Diff Minimaps, inline expandable Revision Rails, Primary-Version drag-out,
/// drop-to-stack merging, and full keyboard/multi-select parity.
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

    @Namespace private var filterPillNamespace
    @Namespace private var columnModeNamespace

    @State private var quickScope: QuickMediaScope = .all
    @State private var expandedGroupID: UUID? = nil
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
    @State private var docExpandedRailRects: [UUID: CGRect] = [:]
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

    private var displayRows: [DisplayRow] {
        let items = scopedAssets
        guard effectiveColumns == 2 else {
            return items.enumerated().map { DisplayRow.single(asset: $0.element, index: $0.offset) }
        }

        var rows: [DisplayRow] = []
        rows.reserveCapacity((items.count + 1) / 2)
        var pendingLeft: (asset: AssetRecord, index: Int)? = nil

        for (index, item) in items.enumerated() {
            let siblings = library.versionStackSiblings(for: item.id)
            let isExpandedStack = siblings.count > 1
                && item.richMetadata?.versionStack?.groupID != nil
                && item.richMetadata?.versionStack?.groupID == expandedGroupID

            if isExpandedStack {
                if let left = pendingLeft {
                    rows.append(.pair(left: left.asset, leftIndex: left.index, right: nil, rightIndex: nil))
                    pendingLeft = nil
                }
                rows.append(.single(asset: item, index: index))
            } else if let left = pendingLeft {
                rows.append(.pair(left: left.asset, leftIndex: left.index, right: item, rightIndex: index))
                pendingLeft = nil
            } else {
                pendingLeft = (item, index)
            }
        }
        if let left = pendingLeft {
            rows.append(.pair(left: left.asset, leftIndex: left.index, right: nil, rightIndex: nil))
        }
        return rows
    }

    public var body: some View {
        ZStack(alignment: .top) {
            CharkleTheme.galleryGround(for: colorScheme)
                .ignoresSafeArea()

            ScrollViewReader { scrollProxy in
                ScrollView(.vertical) {
                    VStack(alignment: .leading, spacing: 10) {
                        compactStudioHeaderBar

                        if scopedAssets.isEmpty {
                            emptyFilteredScopePlaceholder
                        } else {
                            LazyVStack(alignment: .leading, spacing: 10) {
                                ForEach(displayRows) { row in
                                    switch row {
                                    case .single(let asset, let idx):
                                        compactCardCell(asset: asset, index: idx, scrollProxy: scrollProxy)
                                            .id(asset.id)
                                    case .pair(let left, let leftIdx, let right, let rightIdx):
                                        HStack(alignment: .top, spacing: 10) {
                                            compactCardCell(asset: left, index: leftIdx, scrollProxy: scrollProxy)
                                                .id(left.id)
                                                .frame(maxWidth: .infinity)
                                            if let right, let rightIdx {
                                                compactCardCell(asset: right, index: rightIdx, scrollProxy: scrollProxy)
                                                    .id(right.id)
                                                    .frame(maxWidth: .infinity)
                                            } else {
                                                Color.clear
                                                    .frame(maxWidth: .infinity, minHeight: 1)
                                                    .allowsHitTesting(false)
                                            }
                                        }
                                    }
                                }
                            }
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
                    docExpandedRailRects = docExpandedRailRects.filter { validSet.contains($0.key) }
                }
            }

            if let docRect = activeMarqueeDocRect,
               (docRect.width > 3 || docRect.height > 3) {
                let stageRect = docRect.offsetBy(dx: scrollDocOriginInStage.x, dy: scrollDocOriginInStage.y)
                let marqueeShape = RoundedRectangle(cornerRadius: 4, style: .continuous)
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

    // MARK: - Studio Sub-Bar (Media Scope Pills + Sort + 2-Col Index Grid ⇄ 1-Col Folio Strip)

    private var compactStudioHeaderBar: some View {
        let subtleBg = colorScheme == .dark ? Color(charkleHex: "#23262E") : Color(charkleHex: "#EAE9E4")
        let cardBg = CharkleTheme.surfaceElevated(for: colorScheme)

        return HStack(spacing: 8) {
            HStack(spacing: 2) {
                scopeCapsuleButton(.all, title: "全部 \(assets.count)", cardBg: cardBg)
                scopeCapsuleButton(.docAndStacks, title: "文档叠 \(docAndStackCount)", cardBg: cardBg)
                scopeCapsuleButton(.visualAndMedia, title: "视觉与媒体 \(visualMediaCount)", cardBg: cardBg)
            }
            .padding(2.5)
            .background(subtleBg, in: Capsule(style: .continuous))
            .onGeometryChange(for: CGRect.self) { proxy in
                proxy.frame(in: .named("compactStage"))
            } action: { _, rect in
                headerInteractiveStageRects[0] = rect
            }

            Spacer(minLength: 6)

            if viewportWidth >= 820 {
                HStack(spacing: 12) {
                    Text("悬停叠卡微翻纸层")
                    Text("点胶囊抽拉版本轨")
                }
                .font(CharkleTheme.text(.caption))
                .foregroundStyle(.tertiary)
                .lineLimit(1)
            }

            if viewportWidth >= 680 {
                HStack(spacing: 2) {
                    columnModeButton(columns: 2, title: "双列索引卡", icon: "rectangle.grid.2x2", cardBg: cardBg)
                    columnModeButton(columns: 1, title: "单列折页条", icon: "rectangle.grid.1x2", cardBg: cardBg)
                }
                .padding(2.5)
                .background(subtleBg, in: RoundedRectangle(cornerRadius: CharkleTheme.Radius.chip, style: .continuous))
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

    private func scopeCapsuleButton(_ scope: QuickMediaScope, title: String, cardBg: Color) -> some View {
        let selected = quickScope == scope
        return Button {
            withAnimation(CharkleMotion.accessible(CharkleMotion.settleStrong, reduced: reduceMotion)) {
                quickScope = scope
            }
        } label: {
            Text(title)
                .font(CharkleTheme.text(.caption, weight: selected ? .semibold : .medium))
                .monospacedDigit()
                .foregroundStyle(selected ? Color.primary : CharkleTheme.secondaryInk(for: colorScheme))
                .padding(.horizontal, 10)
                .padding(.vertical, 4)
                .background {
                    if selected {
                        Capsule(style: .continuous)
                            .fill(cardBg)
                            .shadow(color: Color.black.opacity(colorScheme == .dark ? 0.26 : 0.05), radius: 2, y: 1)
                            .matchedGeometryEffect(id: "compact-scope-pill", in: filterPillNamespace)
                    }
                }
                .contentShape(Capsule(style: .continuous))
        }
        .buttonStyle(CharkleTactileButtonStyle())
    }

    private func columnModeButton(columns: Int, title: String, icon: String, cardBg: Color) -> some View {
        let selected = coordinator.compactViewColumnMode == columns
        let innerRadius = CharkleTheme.Radius.concentricInner(outer: CharkleTheme.Radius.chip, padding: 2.5)
        return Button {
            withAnimation(CharkleMotion.accessible(CharkleMotion.settleStrong, reduced: reduceMotion)) {
                coordinator.compactViewColumnMode = columns
            }
        } label: {
            HStack(spacing: 4) {
                Image(systemName: icon)
                    .font(.system(size: 10.5, weight: .medium))
                Text(title)
                    .font(CharkleTheme.text(.caption, weight: selected ? .semibold : .medium))
                    .lineLimit(1)
            }
            .foregroundStyle(selected ? Color.primary : CharkleTheme.secondaryInk(for: colorScheme))
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background {
                if selected {
                    RoundedRectangle(cornerRadius: innerRadius, style: .continuous)
                        .fill(cardBg)
                        .shadow(color: Color.black.opacity(colorScheme == .dark ? 0.26 : 0.05), radius: 2, y: 1)
                        .matchedGeometryEffect(id: "compact-col-pill", in: columnModeNamespace)
                }
            }
            .contentShape(RoundedRectangle(cornerRadius: innerRadius, style: .continuous))
        }
        .buttonStyle(CharkleTactileButtonStyle())
    }

    private var emptyFilteredScopePlaceholder: some View {
        VStack(spacing: 8) {
            Text(quickScope == .docAndStacks ? "当前范围暂无文档或版本叠" : "当前范围暂无视觉与媒体素材")
                .font(CharkleTheme.text(.body, weight: .medium))
                .foregroundStyle(.secondary)
            Button("查看全部 \(assets.count) 项") {
                withAnimation(CharkleMotion.accessible(CharkleMotion.settleStrong, reduced: reduceMotion)) {
                    quickScope = .all
                }
            }
            .buttonStyle(CharkleButtonStyle(.standard, size: .xs))
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 48)
    }

    // MARK: - Card Cell Wiring

    private func compactCardCell(asset: AssetRecord, index: Int, scrollProxy: ScrollViewProxy) -> some View {
        let siblings = library.versionStackSiblings(for: asset.id)
        let groupID = asset.richMetadata?.versionStack?.groupID
        let isSelected = library.selectedAssetIDs.contains(asset.id)
        let isCut = library.cutAssetIDs.contains(asset.id)
        let isExpanded = siblings.count > 1 && groupID != nil && groupID == expandedGroupID
        let isCardDropTargeted = dropTargetedCardID == asset.id

        return CompactTactileIndexCard(
            asset: asset,
            siblings: siblings,
            loader: library.thumbnailLoader,
            accentColor: activeAccent,
            isSelected: isSelected,
            isCut: isCut,
            isExpanded: isExpanded,
            isDropTargeted: isCardDropTargeted,
            onSelectCard: {
                handleCardClick(asset: asset, index: index)
            },
            onDoubleClickCard: {
                library.selectedAssetIDs = [asset.id]
                lastClickedAssetID = asset.id
                coordinator.focusedStageAssetID = asset.id
                onOpenQuickLook(asset)
            },
            onToggleRevisionRail: {
                guard let gid = groupID, siblings.count > 1 else { return }
                library.selectedAssetIDs = [asset.id]
                lastClickedAssetID = asset.id
                coordinator.focusedStageAssetID = asset.id
                withAnimation(CharkleMotion.accessible(CharkleMotion.settleStrong, reduced: reduceMotion)) {
                    expandedGroupID = (expandedGroupID == gid) ? nil : gid
                }
            },
            onCopyPrimaryFile: {
                copyPrimaryFileWithToast(for: asset, siblings: siblings)
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
                docTrailingRects[asset.id] = rect
            },
            onExpandedRailDocRectChange: { rect in
                if let rect {
                    docExpandedRailRects[asset.id] = rect
                } else {
                    docExpandedRailRects.removeValue(forKey: asset.id)
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
            let suffix = siblings.count > 1 ? " (主版 v\(vNum))" : ""
            coordinator.showToast(
                "已拷贝「\(primary.title)\(suffix)」原文件实体，切微信直接 ⌘V 发送",
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
            Label(asset.isExternalWebLink ? "在默认浏览器中打开 (Space)" : "快速预览 (Space)", systemImage: asset.isExternalWebLink ? "safari" : "eye")
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
                        coordinator.showToast("已拷贝 \(count) 项主版本原文件到剪贴板", icon: "doc.on.doc")
                    }
                }
            } label: {
                Label(siblings.count > 1 ? "拷贝主版本原文件 (⌘C)" : "拷贝原文件 (⌘C)", systemImage: "doc.on.doc")
            }

            Button {
                Task {
                    let count = await library.cutAssets(targets)
                    coordinator.showToast("已剪切 \(count) 项素材，前往目标文件夹按 ⌘V 移动", icon: "scissors")
                }
            } label: {
                Label("剪切 (⌘X)", systemImage: "scissors")
            }

            if targets.count >= 2 {
                Divider()
                Button {
                    onMergeIntoVersionStack(targets, asset.id)
                } label: {
                    Label("合并为版本叠（\(targets.count) 项）", systemImage: "square.stack.3d.up")
                }
            } else if siblings.count > 1 {
                Divider()
                Button {
                    if let gid = asset.richMetadata?.versionStack?.groupID {
                        withAnimation(CharkleMotion.accessible(CharkleMotion.settleStrong, reduced: reduceMotion)) {
                            expandedGroupID = (expandedGroupID == gid) ? nil : gid
                        }
                    }
                } label: {
                    Label(expandedGroupID == asset.richMetadata?.versionStack?.groupID ? "收起版本演进轨" : "展开版本演进轨（共 \(siblings.count) 版）", systemImage: "point.3.connected.trianglepath.dotted")
                }

                Button {
                    let baseID = siblings.count >= 2 ? siblings[siblings.count - 2].id : siblings.first?.id
                    let targetID = siblings.last?.id
                    onOpenDiff(asset, baseID, targetID)
                } label: {
                    Label("进入精细对比与取舍", systemImage: "arrow.left.arrow.right")
                }

                Menu("切换锁定主版本") {
                    ForEach(siblings) { ver in
                        let vMeta = ver.richMetadata?.versionStack
                        let isPrimary = ver.id == asset.id && (vMeta?.isPinnedPrimary == true || siblings.last?.id == ver.id)
                        Button {
                            onSetPrimaryVersion(ver.id)
                        } label: {
                            if isPrimary {
                                Label("\(vMeta?.displayBadgeText ?? ver.title)（当前主版）", systemImage: "checkmark")
                            } else {
                                Text(vMeta?.displayBadgeText ?? ver.title)
                            }
                        }
                    }
                }

                Button {
                    onUnstackVersion(asset.id)
                } label: {
                    Label("将当前主版拆出为独立素材", systemImage: "rectangle.portrait.and.arrow.right")
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
                Label(asset.pinnedOffline ? "取消始终保留在本地" : "始终保留在本地", systemImage: asset.pinnedOffline ? "icloud" : "arrow.down.circle")
            }

            Button {
                onRetagAssets(targets)
            } label: {
                Label(targets.count > 1 ? "AI 批量重新打标（\(targets.count) 项）" : "AI 重新打标", systemImage: "sparkles")
            }

            Divider()

            Button(role: .destructive) {
                Task {
                    await library.trashAssets(targets)
                    coordinator.showToast(
                        "已移至废纸篓 (\(targets.count) 项)",
                        icon: "trash",
                        actionTitle: "撤销",
                        onAction: {
                            Task {
                                await library.restoreAssets(targets)
                                coordinator.showToast("已放回原处 (\(targets.count) 项)", icon: "arrow.uturn.backward", tone: .success)
                            }
                        }
                    )
                }
            } label: {
                Label("移至废纸篓", systemImage: "trash")
            }
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
        for rect in docExpandedRailRects.values where rect.insetBy(dx: -2, dy: -2).contains(docPt) {
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

        let primaryModifiers = event.modifierFlags.intersection([.command, .option, .control, .shift])
        let items = scopedAssets

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
                        coordinator.showToast("已拷贝 \(count) 项主版本原文件到剪贴板", icon: "doc.on.doc")
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
            case 53: // Escape -> Cancel active marquee, collapse expanded rail, or clear selection
                if activeMarqueeDocRect != nil {
                    activeMarqueeDocRect = nil
                    return nil
                }
                if expandedGroupID != nil {
                    withAnimation(CharkleMotion.accessible(CharkleMotion.exitSm, reduced: reduceMotion)) {
                        expandedGroupID = nil
                    }
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

// MARK: - Individual Tactile Index Card (3D Micro-Folio + 12-Seg Minimap + Inline Revision Rail)

private struct CompactTactileIndexCard: View {
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    let asset: AssetRecord
    let siblings: [AssetRecord]
    let loader: ThumbnailImageLoader
    let accentColor: Color
    let isSelected: Bool
    let isCut: Bool
    let isExpanded: Bool
    let isDropTargeted: Bool
    let onSelectCard: () -> Void
    let onDoubleClickCard: () -> Void
    let onToggleRevisionRail: () -> Void
    let onCopyPrimaryFile: () -> Void
    let onPinPrimaryVersion: (AssetRecord) -> Void
    let onOpenVersionInQuickLook: (AssetRecord) -> Void
    let onOpenDiffPair: (UUID?, UUID?) -> Void
    let makeDragProvider: () -> NSItemProvider
    let onDragHandleDocRectChange: (CGRect) -> Void
    let onTrailingControlsDocRectChange: (CGRect) -> Void
    let onExpandedRailDocRectChange: (CGRect?) -> Void

    @State private var isHovered: Bool = false

    private static let shortTimeFormatter: DateFormatter = {
        let fmt = DateFormatter()
        fmt.dateFormat = "MM-dd HH:mm"
        return fmt
    }()

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

    private var resolvedDiffSummary: DocumentDiffSummary? {
        if let direct = asset.richMetadata?.document?.diffSummary,
           direct.totalChangedBlocks > 0 || direct.minimapBuckets.contains(where: { $0 > 0 }) {
            return direct
        }
        for ver in siblings.reversed() {
            if let summary = ver.richMetadata?.document?.diffSummary,
               summary.totalChangedBlocks > 0 || summary.minimapBuckets.contains(where: { $0 > 0 }) {
                return summary
            }
        }
        return asset.richMetadata?.document?.diffSummary
    }

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: CharkleTheme.Radius.cardOuter, style: .continuous)
        let cardBg: Color = {
            if isHovered && !isSelected {
                return colorScheme == .dark ? Color(charkleHex: "#21242B") : Color(charkleHex: "#FCFBF9")
            }
            return colorScheme == .dark ? Color(charkleHex: "#1C1E23") : Color.white
        }()
        let borderStrong = colorScheme == .dark ? Color.white.opacity(0.16) : Color.black.opacity(0.14)
        let borderSubtle = colorScheme == .dark ? Color.white.opacity(0.08) : Color.black.opacity(0.075)
        let strokeColor: Color = if isDropTargeted {
            accentColor
        } else if isSelected {
            accentColor.opacity(colorScheme == .dark ? 0.62 : 0.48)
        } else if isHovered {
            borderStrong
        } else {
            borderSubtle
        }
        let strokeWidth: CGFloat = (isSelected || isDropTargeted) ? 1.5 : CharkleTheme.hairlineWidth

        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .center, spacing: 12) {
                // Tight drag & click hit region wrapping ONLY CompactMicroFolioArtifact + intrinsic VStack title/tags
                HStack(alignment: .center, spacing: 12) {
                    CompactMicroFolioArtifact(
                        asset: asset,
                        hasStack: hasStack,
                        isCardHovered: isHovered,
                        loader: loader,
                        accentColor: accentColor
                    )

                    VStack(alignment: .leading, spacing: 4) {
                        HStack(spacing: 6) {
                            Text(asset.title)
                                .font(CharkleTheme.text(.body, weight: .semibold))
                                .foregroundStyle(.primary)
                                .lineLimit(1)
                                .truncationMode(.tail)

                            if asset.rating > 0 {
                                Text("★\(asset.rating)")
                                    .font(CharkleTheme.text(.caption, weight: .semibold))
                                    .monospacedDigit()
                                    .foregroundStyle(Color(charkleHex: "#E5B243"))
                            }

                            if asset.pinnedOffline {
                                Image(systemName: "arrow.down.circle.fill")
                                    .font(.system(size: 10.5))
                                    .foregroundStyle(accentColor.opacity(0.85))
                                    .help("已始终保留在本地")
                            }
                        }

                        HStack(spacing: 6) {
                            Text(adaptiveMetadataSummary)
                                .font(CharkleTheme.text(.caption))
                                .monospacedDigit()
                                .foregroundStyle(CharkleTheme.secondaryInk(for: colorScheme))
                                .lineLimit(1)

                            ForEach(asset.tags.prefix(2), id: \.self) { tag in
                                Text("#\(tag)")
                                    .font(CharkleTheme.text(.caption, weight: .medium))
                                    .foregroundStyle(.tertiary)
                                    .padding(.horizontal, 5.5)
                                    .padding(.vertical, 1.5)
                                    .background(
                                        colorScheme == .dark ? Color.white.opacity(0.06) : Color(charkleHex: "#EAE9E4"),
                                        in: RoundedRectangle(cornerRadius: CharkleTheme.Radius.xs, style: .continuous)
                                    )
                                    .lineLimit(1)
                            }
                            if asset.tags.count > 2 {
                                Text("+\(asset.tags.count - 2)")
                                    .font(CharkleTheme.text(.caption, weight: .medium))
                                    .monospacedDigit()
                                    .foregroundStyle(.tertiary)
                            }
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

                // Open middle strip expanse (outside `.onDrag` so dragging starts rubber-band marquee, while clicking still selects row!)
                Color.clear
                    .frame(minWidth: 12, maxWidth: .infinity, minHeight: 44)
                    .contentShape(Rectangle())
                    .onTapGesture(count: 2, perform: onDoubleClickCard)
                    .onTapGesture(perform: onSelectCard)

                // Interactive Stack Pill + Hover Copy Button + 12-Segment Diff Minimap / Timestamp
                HStack(alignment: .center, spacing: 8) {
                    if hasStack {
                        stackCapsuleButton
                    }

                    if isHovered {
                        Button(action: onCopyPrimaryFile) {
                            Text("拷贝文件")
                                .font(CharkleTheme.text(.caption, weight: .medium))
                                .foregroundStyle(.primary)
                                .padding(.horizontal, 8)
                                .padding(.vertical, 4)
                                .background(
                                    colorScheme == .dark ? Color(charkleHex: "#282C35") : Color.white,
                                    in: RoundedRectangle(cornerRadius: CharkleTheme.Radius.sm, style: .continuous)
                                )
                                .overlay(
                                    RoundedRectangle(cornerRadius: CharkleTheme.Radius.sm, style: .continuous)
                                        .strokeBorder(borderStrong, lineWidth: CharkleTheme.hairlineWidth)
                                )
                        }
                        .buttonStyle(CharkleTactileButtonStyle())
                        .transition(.opacity.combined(with: .offset(x: reduceMotion ? 0 : 4)))
                        .help(hasStack ? "直接拷贝锁定的「主版本」原文件实体 (⌘C)" : "拷贝原文件实体到剪贴板 (⌘C)")
                    }

                    rightSpectrumAndTimestamp(borderStrong: borderStrong)
                }
                .fixedSize(horizontal: true, vertical: false)
                .onGeometryChange(for: CGRect.self) { proxy in
                    proxy.frame(in: .named("compactScrollDoc"))
                } action: { _, rect in
                    onTrailingControlsDocRectChange(rect)
                }
            }

            if isExpanded && hasStack {
                revisionRailSection(borderSubtle: borderSubtle)
                    .padding(.top, 10)
                    .transition(CharkleMotion.revealTransition(offsetY: -4, reduced: reduceMotion))
                    .onGeometryChange(for: CGRect.self) { proxy in
                        proxy.frame(in: .named("compactScrollDoc"))
                    } action: { _, rect in
                        onExpandedRailDocRectChange(rect)
                    }
            }
        }
        .onChange(of: isExpanded) { _, expanded in
            if !expanded {
                onExpandedRailDocRectChange(nil)
            }
        }
        .padding(10.5)
        .opacity(isCut ? 0.54 : 1.0)
        .background {
            shape
                .fill(isDropTargeted ? accentColor.opacity(0.08) : cardBg)
                .shadow(
                    color: Color.black.opacity(colorScheme == .dark ? 0.24 : 0.035),
                    radius: isHovered ? 6 : 3,
                    y: isHovered ? 2.5 : 1
                )
        }
        .overlay {
            shape.strokeBorder(strokeColor, lineWidth: strokeWidth)
        }
        .onHover { hovering in
            withAnimation(CharkleMotion.accessible(CharkleMotion.hoverPress, reduced: reduceMotion)) {
                isHovered = hovering
            }
        }
    }

    // MARK: - Stack Pill

    private var stackCapsuleButton: some View {
        let warnInk = colorScheme == .dark ? Color(charkleHex: "#FBBF24") : Color(charkleHex: "#B45309")
        let warnBg = colorScheme == .dark ? Color(charkleHex: "#F2B23E").opacity(0.18) : Color(charkleHex: "#C98212").opacity(0.14)
        let softAccent = CharkleTheme.accentSoft(for: colorScheme, source: .studio)

        return Button(action: onToggleRevisionRail) {
            HStack(spacing: 4) {
                Text("主版 v\(primaryVersionNumber)")
                    .monospacedDigit()

                if newerThanPrimaryCount > 0 {
                    Text("+\(newerThanPrimaryCount) 新版")
                        .font(CharkleTheme.text(.caption, weight: .semibold))
                        .monospacedDigit()
                        .foregroundStyle(isExpanded ? Color.white : warnInk)
                        .padding(.horizontal, 5)
                        .padding(.vertical, 1)
                        .background(
                            isExpanded ? Color.white.opacity(0.22) : warnBg,
                            in: Capsule(style: .continuous)
                        )
                } else {
                    Text("共\(siblings.count)版")
                        .monospacedDigit()
                        .opacity(0.76)
                }

                Image(systemName: isExpanded ? "chevron.up" : "chevron.down")
                    .font(.system(size: 8.5, weight: .bold))
            }
            .font(CharkleTheme.text(.caption, weight: .semibold))
            .foregroundStyle(isExpanded ? Color.white : accentColor)
            .padding(.horizontal, 8.5)
            .padding(.vertical, 3.5)
            .background(
                isExpanded ? accentColor : softAccent,
                in: Capsule(style: .continuous)
            )
            .contentShape(Capsule(style: .continuous))
        }
        .buttonStyle(CharkleTactileButtonStyle())
        .help("点击展开或收起版本演进脉络轨")
    }

    // MARK: - 12-Segment Diff Minimap / Audio Spectrum + Timestamp

    @ViewBuilder
    private func rightSpectrumAndTimestamp(borderStrong: Color) -> some View {
        let subtleWell = colorScheme == .dark ? Color(charkleHex: "#252830") : Color(charkleHex: "#EAE9E4")
        let positiveColor = CharkleTheme.positive(for: colorScheme)
        let dangerColor = CharkleTheme.destructive(for: colorScheme)

        if let diff = resolvedDiffSummary,
           (hasStack || diff.totalChangedBlocks > 0 || diff.minimapBuckets.contains(where: { $0 > 0 })) {
            let buckets = DocumentDiffSummary.normalizeBuckets(diff.minimapBuckets)
            VStack(alignment: .trailing, spacing: 4) {
                HStack(alignment: .center, spacing: 2) {
                    ForEach(Array(buckets.enumerated()), id: \.offset) { _, level in
                        let barColor: Color = switch level {
                        case 2: dangerColor
                        case 1: positiveColor
                        default: borderStrong
                        }
                        let barHeight: CGFloat = switch level {
                        case 2: 14
                        case 1: 11.5
                        default: 7.5
                        }
                        Capsule(style: .continuous)
                            .fill(barColor)
                            .frame(width: 3, height: barHeight)
                    }
                }
                .padding(.horizontal, 6)
                .padding(.vertical, 4)
                .background(subtleWell, in: RoundedRectangle(cornerRadius: CharkleTheme.Radius.sm, style: .continuous))
                .help(minimapTooltip(for: diff))

                Text(formattedTimestamp(asset.updatedAt))
                    .font(CharkleTheme.text(.caption))
                    .monospacedDigit()
                    .foregroundStyle(.tertiary)
            }
        } else if asset.mediaKind == .audio {
            let peaks = asset.waveformPeaks.isEmpty
                ? [Float](repeating: 0.45, count: 12)
                : asset.waveformPeaks
            VStack(alignment: .trailing, spacing: 4) {
                HStack(alignment: .center, spacing: 2) {
                    ForEach(0..<12, id: \.self) { idx in
                        let sample = peaks[idx * peaks.count / max(1, 12)]
                        let barH = max(4, min(14, CGFloat(sample) * 14))
                        Capsule(style: .continuous)
                            .fill(CharkleTheme.secondaryInk(for: colorScheme))
                            .frame(width: 2.5, height: barH)
                    }
                }
                .padding(.horizontal, 6)
                .padding(.vertical, 4)
                .background(subtleWell, in: RoundedRectangle(cornerRadius: CharkleTheme.Radius.sm, style: .continuous))

                Text(formattedTimestamp(asset.updatedAt))
                    .font(CharkleTheme.text(.caption))
                    .monospacedDigit()
                    .foregroundStyle(.tertiary)
            }
        } else {
            VStack(alignment: .trailing, spacing: 3) {
                if asset.fileSizeBytes > 0 {
                    Text(ByteCountFormatter.string(fromByteCount: asset.fileSizeBytes, countStyle: .file))
                        .font(CharkleTheme.text(.caption))
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                }
                Text(formattedTimestamp(asset.updatedAt))
                    .font(CharkleTheme.text(.caption))
                    .monospacedDigit()
                    .foregroundStyle(.tertiary)
            }
        }
    }

    private func minimapTooltip(for diff: DocumentDiffSummary) -> String {
        var parts = ["共 \(diff.totalChangedBlocks) 处改动"]
        if diff.highRiskNumberChanges > 0 {
            parts.append("数字变动 \(diff.highRiskNumberChanges) 处")
        }
        if diff.highRiskDateChanges > 0 {
            parts.append("日期时间 \(diff.highRiskDateChanges) 处")
        }
        return parts.joined(separator: "，")
    }

    // MARK: - Inline Expandable Revision Rail

    private func revisionRailSection(borderSubtle: Color) -> some View {
        let railBg = colorScheme == .dark ? Color(charkleHex: "#17191E") : Color(charkleHex: "#F1F0EC")
        let warnInk = colorScheme == .dark ? Color(charkleHex: "#FBBF24") : Color(charkleHex: "#B45309")
        let warnBg = colorScheme == .dark ? Color(charkleHex: "#F2B23E").opacity(0.16) : Color(charkleHex: "#C98212").opacity(0.13)
        let positiveInk = CharkleTheme.positive(for: colorScheme)
        let positiveBg = positiveInk.opacity(colorScheme == .dark ? 0.16 : 0.12)

        return VStack(alignment: .leading, spacing: 8) {
            Rectangle()
                .fill(borderSubtle)
                .frame(height: CharkleTheme.hairlineWidth)

            HStack(spacing: 8) {
                Text("版本演进脉络 — 点击任意版锁定对外「主版本」，点中间 Δ 直接对比挑拣")
                    .font(CharkleTheme.text(.caption, weight: .medium))
                    .foregroundStyle(CharkleTheme.secondaryInk(for: colorScheme))
                    .lineLimit(1)

                Spacer(minLength: 6)

                if siblings.count >= 2 {
                    Button {
                        let baseID = siblings[siblings.count - 2].id
                        let targetID = siblings[siblings.count - 1].id
                        onOpenDiffPair(baseID, targetID)
                    } label: {
                        HStack(spacing: 4) {
                            Text("进入精细对比与取舍")
                            Image(systemName: "arrow.right")
                                .font(.system(size: 9.5, weight: .bold))
                        }
                        .font(CharkleTheme.text(.caption, weight: .semibold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 9)
                        .padding(.vertical, 4)
                        .background(accentColor, in: RoundedRectangle(cornerRadius: CharkleTheme.Radius.sm, style: .continuous))
                    }
                    .buttonStyle(CharkleTactileButtonStyle())
                }
            }

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    ForEach(Array(siblings.enumerated()), id: \.element.id) { idx, ver in
                        if idx > 0 {
                            let prevVer = siblings[idx - 1]
                            let deltaLabel: String = {
                                if let summary = ver.richMetadata?.document?.diffSummary {
                                    return summary.compactBridgeLabel
                                }
                                return "Δ 对比"
                            }()
                            Button {
                                onOpenDiffPair(prevVer.id, ver.id)
                            } label: {
                                Text(deltaLabel)
                                    .font(CharkleTheme.text(.caption, weight: .semibold))
                                    .monospacedDigit()
                                    .foregroundStyle(warnInk)
                                    .padding(.horizontal, 8)
                                    .padding(.vertical, 3.5)
                                    .background(warnBg, in: Capsule(style: .continuous))
                            }
                            .buttonStyle(CharkleTactileButtonStyle())
                            .help("点击直接对比 \(prevVer.richMetadata?.versionStack?.displayVersionTag ?? "上一版") 与 \(ver.richMetadata?.versionStack?.displayVersionTag ?? "此版")")
                        }

                        let vMeta = ver.richMetadata?.versionStack
                        let vNum = vMeta?.versionNumber ?? (idx + 1)
                        let isPrimary = ver.id == asset.id
                        let isUnreviewed = vNum > primaryVersionNumber && !isPrimary
                        let noteTag: String = {
                            if let note = vMeta?.changeNote {
                                let cleaned = AssetVersionStackMetadata.strippingRedundantVersionPrefix(note)
                                if !cleaned.isEmpty { return cleaned }
                            }
                            if let label = vMeta?.versionLabel {
                                let cleaned = AssetVersionStackMetadata.strippingRedundantVersionPrefix(label)
                                if !cleaned.isEmpty { return cleaned }
                            }
                            return idx == 0 ? "初稿" : "修订版"
                        }()
                        let editor = (vMeta?.editorName?.trimmingCharacters(in: .whitespacesAndNewlines)).flatMap { $0.isEmpty ? nil : $0 } ?? "本机"

                        HStack(spacing: 8) {
                            Button {
                                if !isPrimary {
                                    onPinPrimaryVersion(ver)
                                } else {
                                    onOpenVersionInQuickLook(ver)
                                }
                            } label: {
                                VStack(alignment: .leading, spacing: 2.5) {
                                    HStack(spacing: 5) {
                                        Text("v\(vNum) \(noteTag)")
                                            .font(CharkleTheme.text(.caption, weight: .semibold))
                                            .monospacedDigit()
                                            .foregroundStyle(.primary)
                                            .lineLimit(1)

                                        if isPrimary {
                                            Text("主版")
                                                .font(CharkleTheme.text(.caption, weight: .bold))
                                                .foregroundStyle(positiveInk)
                                                .padding(.horizontal, 5)
                                                .padding(.vertical, 1)
                                                .background(positiveBg, in: RoundedRectangle(cornerRadius: CharkleTheme.Radius.xs, style: .continuous))
                                        } else if isUnreviewed {
                                            Circle()
                                                .fill(warnInk)
                                                .frame(width: 6, height: 6)
                                                .help("新叠入待审版本")
                                        }
                                    }

                                    Text("\(editor)  \(formattedTimestamp(ver.updatedAt))")
                                        .font(CharkleTheme.text(.caption))
                                        .monospacedDigit()
                                        .foregroundStyle(.tertiary)
                                        .lineLimit(1)
                                }
                            }
                            .buttonStyle(.plain)
                            .help(isPrimary ? "当前锁定的对外主版本（点击打开预览）" : "点击将 v\(vNum) 锁定为主版本")

                            if !isPrimary {
                                Button {
                                    onPinPrimaryVersion(ver)
                                } label: {
                                    Text("设为主版")
                                        .font(CharkleTheme.text(.caption, weight: .semibold))
                                        .foregroundStyle(accentColor)
                                        .padding(.horizontal, 6)
                                        .padding(.vertical, 2.5)
                                        .background(accentColor.opacity(0.12), in: Capsule(style: .continuous))
                                }
                                .buttonStyle(.plain)
                                .help("将 v\(vNum) 锁定为对外主版本")
                            }

                            Button {
                                onOpenVersionInQuickLook(ver)
                            } label: {
                                Image(systemName: "eye")
                                    .font(.system(size: 10.5, weight: .medium))
                                    .foregroundStyle(.secondary)
                                    .frame(width: 22, height: 22)
                                    .background(Color.primary.opacity(0.06), in: Circle())
                            }
                            .buttonStyle(.plain)
                            .help("预览 v\(vNum) 内容")
                        }
                        .padding(.horizontal, 10)
                        .padding(.vertical, 6.5)
                        .background(
                            isPrimary
                                ? accentColor.opacity(colorScheme == .dark ? 0.16 : 0.09)
                                : railBg,
                            in: RoundedRectangle(cornerRadius: CharkleTheme.Radius.chip, style: .continuous)
                        )
                        .overlay(
                            RoundedRectangle(cornerRadius: CharkleTheme.Radius.chip, style: .continuous)
                                .strokeBorder(
                                    isPrimary ? accentColor.opacity(0.45) : borderSubtle,
                                    lineWidth: CharkleTheme.hairlineWidth
                                )
                        )
                    }
                }
                .padding(.vertical, 1)
            }
            .background(HorizontalWheelScrollRedirector())
        }
    }

    // MARK: - Adaptive Metadata Summary & Relative Time

    private var adaptiveMetadataSummary: String {
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
                    parts.append("\(doc.wordCount) 字")
                }
                if !doc.hasTextLayer {
                    parts.append("扫描件")
                }
            } else {
                parts.append(ext)
            }
            if let editor = asset.richMetadata?.versionStack?.editorName?.trimmingCharacters(in: .whitespacesAndNewlines),
               !editor.isEmpty {
                parts.append("\(editor)核定")
            } else if let note = asset.richMetadata?.versionStack?.changeNote?.trimmingCharacters(in: .whitespacesAndNewlines),
                      !note.isEmpty {
                parts.append(note)
            }
            return parts.isEmpty ? ext : parts.joined(separator: " / ")

        case .image, .animatedImage, .designFile:
            if asset.pixelWidth > 0 && asset.pixelHeight > 0 {
                return "\(asset.pixelWidth) × \(asset.pixelHeight) / \(ext)"
            }
            return ext

        case .video, .audio:
            let dur = CanvasFormatters.durationString(asset.durationSeconds)
            if asset.pixelWidth > 0 && asset.pixelHeight > 0 {
                return "\(dur) / \(asset.pixelWidth)×\(asset.pixelHeight) / \(ext)"
            }
            return "\(dur) / \(ext)"

        case .webBookmark:
            if let repo = asset.richMetadata?.githubRepo {
                return "\(repo.fullName) / ★\(repo.stars)"
            }
            if let post = asset.richMetadata?.socialPost {
                return "\(post.platform.displayName) / \(post.displayAuthorName)"
            }
            return asset.sourceDomain ?? "网页书签"

        case .model3D:
            return "三维模型 / \(asset.richMetadata?.model3DFormat ?? ext)"
        }
    }

    private func formattedTimestamp(_ date: Date) -> String {
        let elapsed = max(0, Date().timeIntervalSince(date))
        if elapsed < 60 { return "刚刚" }
        if elapsed < 3600 { return "\(Int(elapsed / 60)) 分钟前" }
        if elapsed < 86400 { return "\(Int(elapsed / 3600)) 小时前" }
        return Self.shortTimeFormatter.string(from: date)
    }
}

// MARK: - 3D Miniature Physical Folio Artifact (44 × 52pt)

private struct CompactMicroFolioArtifact: View {
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    let asset: AssetRecord
    let hasStack: Bool
    let isCardHovered: Bool
    let loader: ThumbnailImageLoader
    let accentColor: Color

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

    private var formatAccent: Color {
        switch asset.mediaKind {
        case .document:
            switch docFamily {
            case .xlsx: return Color(charkleHex: "#1D7A46")
            case .pdf: return Color(charkleHex: "#C83E37")
            case .pptx: return Color(charkleHex: "#C96A1B")
            case .docx, .legacyOffice: return Color(charkleHex: "#2A60E0")
            default: return Color(charkleHex: "#4B5563")
            }
        case .audio:
            return Color(charkleHex: "#5C6B73")
        default:
            return accentColor
        }
    }

    var body: some View {
        let paperCover = colorScheme == .dark ? Color(charkleHex: "#282B33") : Color.white
        let paperBack1 = colorScheme == .dark ? Color(charkleHex: "#21242B") : Color(charkleHex: "#F3F2EE")
        let paperBack2 = colorScheme == .dark ? Color(charkleHex: "#1A1C22") : Color(charkleHex: "#E6E4DE")
        let borderStrong = colorScheme == .dark ? Color.white.opacity(0.16) : Color.black.opacity(0.14)
        let sheetShape = RoundedRectangle(cornerRadius: CharkleTheme.Radius.sm, style: .continuous)
        let fanActive = hasStack && isCardHovered && !reduceMotion
        let poses = CompactIndexLayoutMetrics.microFolioLayerPoses(
            isHovered: hasStack && isCardHovered,
            reduceMotion: reduceMotion
        )
        let pivot = UnitPoint(x: 0.0, y: 0.85)

        ZStack {
            if hasStack {
                sheetShape
                    .fill(paperBack2)
                    .overlay(sheetShape.strokeBorder(borderStrong, lineWidth: CharkleTheme.hairlineWidth))
                    .frame(width: 38, height: 48)
                    .rotationEffect(.degrees(poses.back.rotationZDegrees), anchor: pivot)
                    .offset(x: poses.back.offsetX, y: poses.back.offsetY)
                    .animation(
                        reduceMotion ? nil : CharkleMotion.microOvershoot.delay(fanActive ? 0.045 : 0),
                        value: fanActive
                    )

                sheetShape
                    .fill(paperBack1)
                    .overlay(sheetShape.strokeBorder(borderStrong, lineWidth: CharkleTheme.hairlineWidth))
                    .frame(width: 38, height: 48)
                    .rotation3DEffect(
                        .degrees(poses.mid.rotationYDegrees),
                        axis: (x: 0, y: 1, z: 0),
                        anchor: .leading,
                        perspective: 0.45
                    )
                    .rotationEffect(.degrees(poses.mid.rotationZDegrees), anchor: pivot)
                    .offset(x: poses.mid.offsetX, y: poses.mid.offsetY)
                    .animation(
                        reduceMotion ? nil : CharkleMotion.microOvershoot.delay(fanActive ? 0.022 : 0.022),
                        value: fanActive
                    )
            }

            coverContent(paperCover: paperCover, borderStrong: borderStrong, sheetShape: sheetShape)
                .frame(width: 38, height: 48)
                .clipShape(sheetShape)
                .overlay(sheetShape.strokeBorder(borderStrong, lineWidth: CharkleTheme.hairlineWidth))
                .shadow(color: Color.black.opacity(colorScheme == .dark ? 0.28 : 0.08), radius: 2.5, y: 1)
                .rotation3DEffect(
                    .degrees(poses.front.rotationYDegrees),
                    axis: (x: 0, y: 1, z: 0),
                    anchor: .leading,
                    perspective: 0.45
                )
                .offset(x: poses.front.offsetX, y: poses.front.offsetY)
                .animation(
                    reduceMotion ? nil : CharkleMotion.microOvershoot.delay(fanActive ? 0 : 0.044),
                    value: fanActive
                )
        }
        .frame(width: 44, height: 52)
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
    private func coverContent(paperCover: Color, borderStrong: Color, sheetShape: RoundedRectangle) -> some View {
        switch asset.mediaKind {
        case .document:
            if let realPage = resolvedDocumentPageImage {
                realDocumentPageMiniFolio(pageImage: realPage, paperCover: paperCover)
            } else {
                documentPageSkeleton(paperCover: paperCover)
            }
        case .audio:
            audioMiniFolio(paperCover: paperCover)
        case .webBookmark:
            webBookmarkMiniFolio(paperCover: paperCover)
        default:
            visualPaletteMiniFolio(paperCover: paperCover)
        }
    }

    private func realDocumentPageMiniFolio(pageImage: NSImage, paperCover: Color) -> some View {
        ZStack(alignment: .bottomLeading) {
            Image(nsImage: pageImage)
                .resizable()
                .interpolation(.high)
                .scaledToFill()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .clipped()

            Text(docFamily.badgeLabel)
                .font(CharkleTheme.text(.caption, weight: .bold))
                .foregroundStyle(.white)
                .lineLimit(1)
                .minimumScaleFactor(0.65)
                .fixedSize(horizontal: true, vertical: false)
                .padding(.horizontal, 3)
                .padding(.vertical, 1)
                .background(formatAccent.opacity(0.88), in: RoundedRectangle(cornerRadius: 2.5, style: .continuous))
                .scaleEffect(0.72, anchor: .bottomLeading)
                .padding(2)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(paperCover)
    }

    private func visualPaletteMiniFolio(paperCover: Color) -> some View {
        VStack(spacing: 0) {
            ZStack(alignment: .bottomLeading) {
                AssetThumbnailSurface(
                    asset: asset,
                    loader: loader,
                    tier: .grid520,
                    cornerRadius: 0
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)

                Text(extLabel)
                    .font(CharkleTheme.text(.caption, weight: .bold))
                    .foregroundStyle(.white)
                    .lineLimit(1)
                    .minimumScaleFactor(0.65)
                    .fixedSize(horizontal: true, vertical: false)
                    .padding(.horizontal, 3)
                    .padding(.vertical, 1)
                    .background(Color.black.opacity(0.52), in: RoundedRectangle(cornerRadius: 2.5, style: .continuous))
                    .scaleEffect(0.72, anchor: .bottomLeading)
                    .padding(2.5)
            }

            if !asset.dominantColors.isEmpty {
                HStack(spacing: 0) {
                    ForEach(asset.dominantColors.prefix(4), id: \.hex) { swatch in
                        Rectangle()
                            .fill(Color(charkleHex: swatch.hex))
                    }
                }
                .frame(height: 6)
            }
        }
        .background(paperCover)
    }

    private func audioMiniFolio(paperCover: Color) -> some View {
        let peaks = asset.waveformPeaks.isEmpty
            ? [Float]([0.35, 0.72, 0.48, 0.92, 0.85, 0.55, 0.76, 0.42])
            : Array(asset.waveformPeaks.prefix(8))
        return VStack(spacing: 3) {
            Spacer(minLength: 2)
            HStack(alignment: .center, spacing: 1.5) {
                ForEach(Array(peaks.enumerated()), id: \.offset) { _, p in
                    Capsule(style: .continuous)
                        .fill(accentColor)
                        .frame(width: 2, height: max(4, min(22, CGFloat(p) * 22)))
                }
            }
            Spacer(minLength: 1)
            Text(extLabel)
                .font(CharkleTheme.text(.caption, weight: .bold))
                .foregroundStyle(CharkleTheme.secondaryInk(for: colorScheme))
                .lineLimit(1)
                .minimumScaleFactor(0.65)
                .fixedSize(horizontal: true, vertical: false)
                .scaleEffect(0.72)
        }
        .padding(4)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(paperCover)
    }

    private func webBookmarkMiniFolio(paperCover: Color) -> some View {
        let badge = asset.isGitHubRepo ? "GH" : (asset.richMetadata?.socialPost?.platform.displayName.prefix(3).uppercased() ?? "WEB")
        return VStack(alignment: .leading, spacing: 4) {
            RoundedRectangle(cornerRadius: 1, style: .continuous)
                .fill(accentColor)
                .frame(height: 3)
            Spacer(minLength: 0)
            Image(systemName: asset.isGitHubRepo ? "chevron.left.forwardslash.chevron.right" : "globe")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(accentColor.opacity(0.85))
                .frame(maxWidth: .infinity)
            Spacer(minLength: 0)
            Text(badge)
                .font(CharkleTheme.text(.caption, weight: .bold))
                .foregroundStyle(CharkleTheme.secondaryInk(for: colorScheme))
                .lineLimit(1)
                .minimumScaleFactor(0.65)
                .fixedSize(horizontal: true, vertical: false)
                .scaleEffect(0.72, anchor: .bottomLeading)
        }
        .padding(5)
        .background(paperCover)
    }

    private func documentPageSkeleton(paperCover: Color) -> some View {
        let lineColor = colorScheme == .dark ? Color.white.opacity(0.16) : Color.black.opacity(0.12)
        let isSheet = docFamily == .xlsx
        let isRedHeader = docFamily == .pdf || asset.title.contains("红头") || asset.title.contains("通知") || asset.title.contains("汇报")
        let isStamped = (asset.richMetadata?.document?.hasTextLayer == false) || asset.title.contains("扫描") || asset.title.contains("签")

        return VStack(alignment: .leading, spacing: 3.5) {
            if isSheet {
                RoundedRectangle(cornerRadius: 1, style: .continuous)
                    .fill(formatAccent)
                    .frame(height: 4)

                VStack(spacing: 2) {
                    ForEach(0..<3, id: \.self) { r in
                        HStack(spacing: 2) {
                            ForEach(0..<3, id: \.self) { c in
                                let fill: Color = (r == 0 && c == 1)
                                    ? Color(charkleHex: "#249A4B").opacity(0.32)
                                    : ((r == 1 && c == 1)
                                        ? Color(charkleHex: "#D93B30").opacity(0.32)
                                        : lineColor)
                                RoundedRectangle(cornerRadius: 1, style: .continuous)
                                    .fill(fill)
                            }
                        }
                    }
                }
                .frame(maxHeight: .infinity)
            } else {
                RoundedRectangle(cornerRadius: 1.5, style: .continuous)
                    .fill(isRedHeader ? Color(charkleHex: "#D93B30") : formatAccent)
                    .frame(width: 22, height: 3)
                    .frame(maxWidth: .infinity)

                VStack(alignment: .leading, spacing: 2.5) {
                    Capsule().fill(lineColor).frame(height: 2)
                    Capsule().fill(lineColor).frame(width: 22, height: 2)
                    Capsule().fill(accentColor.opacity(0.38)).frame(height: 2)
                    Capsule().fill(lineColor).frame(width: 18, height: 2)
                }

                Spacer(minLength: 0)
            }

            HStack(spacing: 2) {
                Text(docFamily.badgeLabel)
                    .font(CharkleTheme.text(.caption, weight: .bold))
                    .foregroundStyle(formatAccent)
                    .lineLimit(1)
                    .minimumScaleFactor(0.65)
                    .fixedSize(horizontal: true, vertical: false)
                    .scaleEffect(0.72, anchor: .bottomLeading)
                Spacer(minLength: 0)
                if isStamped {
                    Circle()
                        .strokeBorder(Color(charkleHex: "#D93B30").opacity(0.75), lineWidth: 1)
                        .frame(width: 7.5, height: 7.5)
                }
            }
        }
        .padding(4.5)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(paperCover)
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
