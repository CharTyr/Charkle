import CharkleCore
import SwiftUI
import UniformTypeIdentifiers

// MARK: - Deterministic Virtualized Masonry Layout Snapshot

private struct VirtualizedMasonryItem: Identifiable {
    let id: UUID
    let asset: AssetRecord
    let rect: CGRect
}

private struct VirtualizedMasonrySnapshot {
    let colCount: Int
    let contentHeight: CGFloat
    let items: [VirtualizedMasonryItem]
    let rectByID: [UUID: CGRect]

    static func build(
        assets: [AssetRecord],
        containerWidth: CGFloat,
        colCount: Int,
        spacing: CGFloat,
        horizontalPadding: CGFloat,
        topInset: CGFloat,
        bottomInset: CGFloat
    ) -> VirtualizedMasonrySnapshot {
        let safeCols = max(1, colCount)
        let usableWidth = max(120, containerWidth - horizontalPadding * 2)
        let colWidth = (usableWidth - spacing * CGFloat(safeCols - 1)) / CGFloat(safeCols)
        var colHeights = Array(repeating: topInset, count: safeCols)
        var items: [VirtualizedMasonryItem] = []
        items.reserveCapacity(assets.count)
        var rectByID: [UUID: CGRect] = Dictionary(minimumCapacity: assets.count)

        for asset in assets {
            var bestCol = 0
            var minH = colHeights[0]
            if safeCols > 1 {
                for c in 1..<safeCols where colHeights[c] < minH - 0.5 {
                    minH = colHeights[c]
                    bestCol = c
                }
            }
            let ratio = MobileMasonryLayout.effectiveAspectRatio(for: asset)
            let cardHeight = max(44, (colWidth / ratio).rounded())
            let x = horizontalPadding + CGFloat(bestCol) * (colWidth + spacing)
            let y = colHeights[bestCol]
            let rect = CGRect(x: x, y: y, width: colWidth, height: cardHeight)
            items.append(VirtualizedMasonryItem(id: asset.id, asset: asset, rect: rect))
            rectByID[asset.id] = rect
            colHeights[bestCol] = y + cardHeight + spacing
        }

        let totalHeight = max(topInset + bottomInset, (colHeights.max() ?? topInset) + bottomInset)
        return VirtualizedMasonrySnapshot(
            colCount: safeCols,
            contentHeight: totalHeight,
            items: items,
            rectByID: rectByID
        )
    }

    func visibleItems(in viewportRect: CGRect, overscan: CGFloat = 520) -> [VirtualizedMasonryItem] {
        let minY = viewportRect.minY - overscan
        let maxY = viewportRect.maxY + overscan
        return items.filter { $0.rect.maxY >= minY && $0.rect.minY <= maxY }
    }

    func hitAssetID(at contentPoint: CGPoint, tolerance: CGFloat = 6) -> UUID? {
        for item in items where item.rect.insetBy(dx: -tolerance, dy: -tolerance).contains(contentPoint) {
            return item.id
        }
        return nil
    }

    func closestAssetID(to contentPoint: CGPoint) -> UUID? {
        if let exact = hitAssetID(at: contentPoint, tolerance: 8) {
            return exact
        }
        var bestID: UUID?
        var bestDist = CGFloat.greatestFiniteMagnitude
        for item in items {
            let dx = item.rect.midX - contentPoint.x
            let dy = item.rect.midY - contentPoint.y
            let d = dx * dx + dy * dy
            if d < bestDist {
                bestDist = d
                bestID = item.id
            }
        }
        return bestID
    }
}

/// High-density Gallery-First vertical masonry waterfall modeled on iOS Photos & `DESIGN.md`:
/// - Deterministic frame-positioned virtualization (`ScrollPosition` + `.onScrollGeometryChange`) so
///   1,900+ assets scroll smoothly at 120Hz with zero column-collapse glitches.
/// - True Apple Photos-style pinch-to-zoom anchored directly on the card under the user's two fingers,
///   with exact scroll-offset compensation and zero flicker/blank screens across `1...5` (iPhone) / `2...7` (iPad) columns.
/// - Native iOS 26+ Liquid Glass (`GlassEffectContainer` + `.glassEffect`) on top-right controls & floating docks.
/// - Continuous horizontal/diagonal drag-to-multi-select sweep in `选取` mode.
/// - Exact reveal-in-library scroll & cobalt spotlight pulse when locating an asset from a Moodboard.
/// - 1:1 desktop-parity long-press context menu.
struct MasonryGalleryView: View {
    @Bindable var store: MobileAppStore
    var assetsOverride: [AssetRecord]? = nil
    let isCompact: Bool
    let showPhotosFloatingHeader: Bool
    let zoomNamespace: Namespace.ID
    let zoomOrigin: PreviewZoomOrigin
    let onOpenAsset: (AssetRecord) -> Void
    let onFindSimilar: (AssetRecord) -> Void
    let onOpenCapture: () -> Void
    let onOpenSyncSettings: () -> Void
    let onOpenFolders: (() -> Void)?

    private var displayedAssets: [AssetRecord] {
        assetsOverride ?? store.assets
    }

    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    @State private var isFilterSheetPresented = false
    @State private var isBatchFolderSheetPresented = false
    @State private var isBatchBoardSheetPresented = false
    @State private var confirmPermanentDelete = false
    @State private var singleDeleteAssetID: UUID?
    @State private var shareAssetURL: URL?

    // Deterministic Scroll + Viewport tracking
    @State private var scrollPosition = ScrollPosition(edge: .top)
    @State private var viewportRect: CGRect = CGRect(x: 0, y: 0, width: 390, height: 844)
    @State private var lastKnownWidth: CGFloat = 390

    // Two-finger Photos-style anchor-locked pinch-to-zoom state
    @State private var isPinching = false
    @State private var pinchBaselineScale: CGFloat = 1.0
    @State private var livePinchRubberScale: CGFloat = 1.0
    @State private var pinchUnitAnchor: UnitPoint = .center
    @State private var pinchAnchorAssetID: UUID? = nil
    @State private var pinchAnchorViewportY: CGFloat = 0
    @State private var activePinchLabel: String?
    @State private var pinchBadgeDismissTask: Task<Void, Never>?

    // Apple Photos-style drag-to-multi-select state
    private enum DragDecision {
        case scroll
        case sweepSelect
    }
    @State private var dragDecision: DragDecision? = nil
    @State private var dragStartAssetID: UUID? = nil
    @State private var dragAddsSelection: Bool = true
    @State private var preDragSelection: Set<UUID> = []
    @State private var lastSweptAssetID: UUID? = nil

    private var isActivelySweepingSelection: Bool {
        store.isMultiSelectMode && dragDecision == .sweepSelect
    }

    var body: some View {
        ZStack(alignment: .top) {
            MobileTheme.galleryGround(for: colorScheme)
                .ignoresSafeArea()

            if displayedAssets.isEmpty && store.hasCompletedInitialLoad && !store.isLoadingLibrary && !store.isReloadingAssets {
                VStack(spacing: 0) {
                    if showPhotosFloatingHeader {
                        photosFloatingHeader
                    } else {
                        FilterBarView(
                            store: store,
                            isCompact: isCompact,
                            onOpenFilterSheet: { isFilterSheetPresented = true }
                        )
                    }
                    emptyStateView
                }
            } else {
                GeometryReader { proxy in
                    let colCount = MobileMasonryLayout.resolvedColumnCount(
                        for: proxy.size.width,
                        isCompact: isCompact,
                        override: store.columnCountOverride
                    )
                    let spacing = MobileMasonryLayout.adaptiveSpacing(for: colCount, isCompact: isCompact)
                    let cardCornerRadius = MobileMasonryLayout.adaptiveCornerRadius(for: colCount)
                    let horizontalPadding: CGFloat = colCount >= 4 ? (colCount >= 5 ? 2 : 5) : (isCompact ? 8 : 16)
                    let topClearance: CGFloat = showPhotosFloatingHeader
                        ? (store.hasActiveFilters ? 116 : 74)
                        : (colCount >= 5 ? 4 : 8)
                    let bannerExtra: CGFloat = (store.semanticSearchReport != nil ? 48 : 0)
                        + (store.syncStatus.isSyncing && store.syncStatus.progressFraction != nil ? 62 : 0)
                    let snapshot = VirtualizedMasonrySnapshot.build(
                        assets: displayedAssets,
                        containerWidth: proxy.size.width,
                        colCount: colCount,
                        spacing: spacing,
                        horizontalPadding: horizontalPadding,
                        topInset: topClearance + bannerExtra,
                        bottomInset: store.isMultiSelectMode ? 120 : 54
                    )
                    let visibleItems = snapshot.visibleItems(
                        in: CGRect(
                            x: 0,
                            y: max(0, viewportRect.minY),
                            width: proxy.size.width,
                            height: max(proxy.size.height, viewportRect.height)
                        )
                    )

                    ZStack(alignment: .top) {
                        VStack(spacing: 0) {
                            if !showPhotosFloatingHeader {
                                FilterBarView(
                                    store: store,
                                    isCompact: isCompact,
                                    onOpenFilterSheet: { isFilterSheetPresented = true }
                                )
                            }

                            ScrollView {
                                ZStack(alignment: .topLeading) {
                                    // Full virtualized content height anchor
                                    Color.clear
                                        .frame(
                                            width: proxy.size.width,
                                            height: max(proxy.size.height, snapshot.contentHeight)
                                        )

                                    // Optional top status banners (semantic search / sync progress)
                                    if bannerExtra > 0 {
                                        VStack(spacing: 8) {
                                            if let report = store.semanticSearchReport {
                                                MobileSemanticSearchStatusBar(report: report) {
                                                    store.semanticSearchEnabled = false
                                                    Task { await store.clearSemanticSearch() }
                                                }
                                            }
                                            if store.syncStatus.isSyncing, let fraction = store.syncStatus.progressFraction {
                                                syncProgressBanner(fraction: fraction)
                                            }
                                        }
                                        .padding(.horizontal, max(10, horizontalPadding))
                                        .offset(y: topClearance)
                                    }

                                    // Visible masonry cards only — unified identity across column changes!
                                    ForEach(visibleItems) { item in
                                        GalleryCardView(
                                            asset: item.asset,
                                            store: store,
                                            zoomNamespace: zoomNamespace,
                                            zoomOrigin: zoomOrigin,
                                            cornerRadius: cardCornerRadius,
                                            isDenseOverview: colCount >= 4,
                                            isMultiSelect: store.isMultiSelectMode,
                                            isSelected: store.selectedAssetIDs.contains(item.id),
                                            isHighlighted: store.highlightedAssetID == item.id,
                                            onTap: {
                                                if store.isMultiSelectMode {
                                                    toggleSelection(item.id)
                                                } else {
                                                    onOpenAsset(item.asset)
                                                }
                                            },
                                            onFindSimilar: { onFindSimilar(item.asset) },
                                            onShareOriginal: {
                                                Task { await shareAsset(item.asset) }
                                            },
                                            onRequestPermanentDelete: {
                                                singleDeleteAssetID = item.id
                                            },
                                            onSelectMultiple: {
                                                store.isMultiSelectMode = true
                                                store.selectedAssetIDs.insert(item.id)
                                            }
                                        )
                                        .frame(width: item.rect.width, height: item.rect.height)
                                        .position(x: item.rect.midX, y: item.rect.midY)
                                    }
                                }
                                .scaleEffect(livePinchRubberScale, anchor: pinchUnitAnchor)
                            }
                            .scrollPosition($scrollPosition)
                            .onScrollGeometryChange(for: CGRect.self) { geo in
                                CGRect(origin: geo.contentOffset, size: geo.containerSize)
                            } action: { _, newRect in
                                if !isPinching {
                                    viewportRect = newRect
                                }
                            }
                            .charkleScrollEdgeSoft(for: showPhotosFloatingHeader ? [.top, .bottom] : .bottom)
                            .coordinateSpace(name: "galleryViewport")
                            .scrollDisabled(isActivelySweepingSelection || isPinching)
                            .refreshable {
                                if store.hasConnectedCloudBackend {
                                    await store.syncNow(quiet: false)
                                } else {
                                    await store.reloadAll()
                                }
                            }
                            .simultaneousGesture(
                                pinchColumnZoomGesture(
                                    viewportSize: proxy.size,
                                    currentSnapshot: snapshot,
                                    topInset: topClearance + bannerExtra,
                                    bottomInset: store.isMultiSelectMode ? 120 : 54
                                )
                            )
                            .simultaneousGesture(
                                dragMultiSelectGesture(snapshot: snapshot),
                                including: store.isMultiSelectMode ? .all : .subviews
                            )
                        }

                        if showPhotosFloatingHeader {
                            photosFloatingHeader
                        }

                        if let activePinchLabel {
                            Text(activePinchLabel)
                                .font(.system(size: 12.5, weight: .semibold).monospacedDigit())
                                .foregroundStyle(.primary)
                                .padding(.horizontal, 12)
                                .padding(.vertical, 6)
                                .charkleFloatingCapsule(interactive: false)
                                .padding(.top, showPhotosFloatingHeader ? 84 : 12)
                                .transition(.opacity.combined(with: .scale(scale: 0.94)))
                                .allowsHitTesting(false)
                        }
                    }
                    .onAppear {
                        lastKnownWidth = proxy.size.width
                        performPendingRevealIfNeeded(snapshot: snapshot, viewportHeight: proxy.size.height)
                    }
                    .onChange(of: proxy.size.width) { _, w in
                        lastKnownWidth = w
                    }
                    .onChange(of: store.pendingRevealAssetID) { _, _ in
                        performPendingRevealIfNeeded(snapshot: snapshot, viewportHeight: proxy.size.height)
                    }
                    .onChange(of: displayedAssets.count) { _, _ in
                        performPendingRevealIfNeeded(snapshot: snapshot, viewportHeight: proxy.size.height)
                    }
                }
            }

            if store.isMultiSelectMode {
                VStack {
                    Spacer()
                    multiSelectFloatingDock
                        .padding(.horizontal, MobileTheme.Space.lg)
                        .padding(.bottom, 12)
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                }
            }
        }
        .sheet(isPresented: $isFilterSheetPresented) {
            NavigationStack {
                FilterOptionsSheet(store: store)
            }
            .presentationDetents([.medium, .large])
        }
        .sheet(isPresented: $isBatchFolderSheetPresented) {
            NavigationStack {
                BatchFolderPickerSheet(
                    folders: store.flattenedFolders,
                    onPick: { folderID in
                        let ids = Array(store.selectedAssetIDs)
                        isBatchFolderSheetPresented = false
                        store.isMultiSelectMode = false
                        store.selectedAssetIDs.removeAll()
                        Task {
                            await store.patchAssets(
                                AssetBatchPatch(
                                    assetIDs: ids,
                                    folderAssignment: folderID.map { .folder($0) } ?? .inbox
                                ),
                                successToast: "已移动 \(ids.count) 项素材"
                            )
                        }
                    }
                )
            }
            .presentationDetents([.medium, .large])
        }
        .sheet(isPresented: $isBatchBoardSheetPresented) {
            NavigationStack {
                BatchBoardPickerSheet(
                    store: store,
                    assetIDs: Array(store.selectedAssetIDs),
                    onDone: {
                        isBatchBoardSheetPresented = false
                        store.isMultiSelectMode = false
                        store.selectedAssetIDs.removeAll()
                    }
                )
            }
            .presentationDetents([.medium, .large])
        }
        .sheet(isPresented: Binding(
            get: { shareAssetURL != nil },
            set: { if !$0 { shareAssetURL = nil } }
        )) {
            if let shareAssetURL {
                ActivityShareSheet(items: [shareAssetURL])
            }
        }
        .confirmationDialog(
            "永久删除选中的 \(store.selectedAssetIDs.count) 项素材？",
            isPresented: $confirmPermanentDelete,
            titleVisibility: .visible
        ) {
            Button("永久删除", role: .destructive) {
                let ids = Array(store.selectedAssetIDs)
                store.isMultiSelectMode = false
                store.selectedAssetIDs.removeAll()
                Task { await store.permanentlyDelete(ids: ids) }
            }
            Button("取消", role: .cancel) {}
        } message: {
            Text("此操作不可撤销，云端同步记录也会同步移除这些素材。")
        }
        .confirmationDialog(
            "永久删除此素材？",
            isPresented: Binding(
                get: { singleDeleteAssetID != nil },
                set: { if !$0 { singleDeleteAssetID = nil } }
            ),
            titleVisibility: .visible
        ) {
            Button("永久删除", role: .destructive) {
                if let id = singleDeleteAssetID {
                    singleDeleteAssetID = nil
                    Task { await store.permanentlyDelete(ids: [id]) }
                }
            }
            Button("取消", role: .cancel) { singleDeleteAssetID = nil }
        } message: {
            Text("彻底删除后将无法从回收站恢复。")
        }
    }

    // MARK: - Exact Reveal-in-Library Scroll Compensation

    private func performPendingRevealIfNeeded(snapshot: VirtualizedMasonrySnapshot, viewportHeight: CGFloat) {
        guard let revealID = store.pendingRevealAssetID,
              let rect = snapshot.rectByID[revealID] else {
            return
        }
        store.pendingRevealAssetID = nil
        let maxScrollY = max(0, snapshot.contentHeight - max(200, viewportHeight))
        let targetY = max(0, min(maxScrollY, rect.midY - viewportHeight * 0.42))
        DispatchQueue.main.async {
            viewportRect.origin.y = targetY
            withAnimation(MobileMotion.accessible(MobileMotion.drawerEase, reduced: reduceMotion)) {
                scrollPosition.scrollTo(y: targetY)
            }
        }
    }

    // MARK: - iOS Photos-Style Floating Header (Real iOS 26+ Liquid Glass Cluster)

    private var photosFloatingHeader: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .center, spacing: 8) {
                // Leading bold scope title + item count (tapping opens 目录与筛选)
                Button {
                    if let onOpenFolders {
                        MobileHaptics.light()
                        onOpenFolders()
                    }
                } label: {
                    VStack(alignment: .leading, spacing: 1) {
                        HStack(spacing: 4) {
                            Text(store.currentScopeTitle)
                                .font(.system(size: 27, weight: .bold))
                                .foregroundStyle(.primary)
                                .lineLimit(1)
                            if onOpenFolders != nil {
                                Image(systemName: "chevron.down")
                                    .font(.system(size: 12, weight: .bold))
                                    .foregroundStyle(.secondary)
                                    .offset(y: 1)
                            }
                        }
                        Text(headerSubtitle)
                            .font(.system(size: 12.5, weight: .semibold).monospacedDigit())
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                    .shadow(color: MobileTheme.galleryGround(for: colorScheme).opacity(0.65), radius: 6, y: 1)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)

                Spacer(minLength: 8)

                // Trailing floating controls using native iOS 26+ Liquid Glass cluster
                CharkleGlassCluster(spacing: 8) {
                    HStack(spacing: 8) {
                        Button {
                            MobileHaptics.light()
                            isFilterSheetPresented = true
                        } label: {
                            Image(systemName: "line.3.horizontal.decrease")
                                .font(.system(size: 15.5, weight: .semibold))
                                .foregroundStyle(
                                    store.hasActiveFilters ? MobileTheme.accent(for: colorScheme) : .primary
                                )
                                .frame(width: 40, height: 40)
                                .contentShape(Circle())
                        }
                        .buttonStyle(.plain)
                        .charkleFloatingCircle(interactive: true)
                        .accessibilityLabel("筛选与排序")

                        Button {
                            MobileHaptics.light()
                            withAnimation(MobileMotion.accessible(MobileMotion.settleStrong, reduced: reduceMotion)) {
                                store.isMultiSelectMode.toggle()
                                if !store.isMultiSelectMode {
                                    store.selectedAssetIDs.removeAll()
                                }
                            }
                        } label: {
                            Text(store.isMultiSelectMode ? "取消" : "选取")
                                .font(.system(size: 14.5, weight: .semibold))
                                .foregroundStyle(
                                    store.isMultiSelectMode ? MobileTheme.accent(for: colorScheme) : .primary
                                )
                                .padding(.horizontal, 15)
                                .frame(height: 40)
                                .contentShape(Capsule())
                        }
                        .buttonStyle(.plain)
                        .charkleFloatingCapsule(interactive: true)

                        Button(action: onOpenCapture) {
                            Image(systemName: "plus")
                                .font(.system(size: 17, weight: .semibold))
                                .foregroundStyle(.primary)
                                .frame(width: 40, height: 40)
                                .contentShape(Circle())
                        }
                        .buttonStyle(.plain)
                        .charkleFloatingCircle(interactive: true)
                        .accessibilityLabel("新增素材")
                    }
                }
            }
            .padding(.horizontal, 14)
            .padding(.top, 6)

            if store.hasActiveFilters {
                activeFilterChipsStrip
                    .padding(.horizontal, 14)
            }
        }
        .padding(.bottom, 8)
        .background(
            // Subtle progressive top readability scrim so full-bleed artwork still refracts cleanly through Liquid Glass
            LinearGradient(
                colors: [
                    MobileTheme.galleryGround(for: colorScheme).opacity(0.68),
                    MobileTheme.galleryGround(for: colorScheme).opacity(0.26),
                    MobileTheme.galleryGround(for: colorScheme).opacity(0.0)
                ],
                startPoint: .top,
                endPoint: .bottom
            )
            .ignoresSafeArea(edges: .top)
            .allowsHitTesting(false)
        )
    }

    private var headerSubtitle: String {
        if store.isMultiSelectMode {
            return store.selectedAssetIDs.isEmpty
                ? "横划可连续多选素材"
                : "已选取 \(store.selectedAssetIDs.count) 个项目"
        }
        if store.syncStatus.isSyncing {
            return store.syncStatus.localizedPhaseTitle
        }
        return "\(displayedAssets.count) 个项目"
    }

    private var activeFilterChipsStrip: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                if !store.criteria.searchQuery.isEmpty {
                    filterChip("“\(store.criteria.searchQuery)”") {
                        store.updateSearchQuery("")
                    }
                }
                if let hex = store.criteria.selectedColorHex {
                    filterChip(hex.uppercased(), dotHex: hex) {
                        store.setColorFilter(nil)
                    }
                }
                ForEach(Array(store.criteria.kinds).sorted(by: { $0.rawValue < $1.rawValue }), id: \.self) { kind in
                    filterChip(kind.localizedLabel) {
                        store.criteria.kinds.remove(kind)
                        Task { await store.reloadAssets() }
                    }
                }
                if let shape = store.criteria.shape {
                    filterChip(shape.localizedLabel) {
                        store.criteria.shape = nil
                        Task { await store.reloadAssets() }
                    }
                }
                if store.criteria.minRating > 0 {
                    filterChip("\(store.criteria.minRating)★+") {
                        store.criteria.minRating = 0
                        Task { await store.reloadAssets() }
                    }
                }
                ForEach(store.criteria.tags.sorted(by: { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }), id: \.self) { tag in
                    filterChip("#\(tag)") {
                        store.criteria.tags.remove(tag)
                        Task { await store.reloadAssets() }
                    }
                }
                if store.criteria.onlyPinnedOffline {
                    filterChip("本地保留") {
                        store.criteria.onlyPinnedOffline = false
                        Task { await store.reloadAssets() }
                    }
                }
                Button("清除") {
                    store.clearFilters()
                }
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(MobileTheme.accent(for: colorScheme))
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                .charkleFloatingCapsule(interactive: true)
            }
        }
    }

    private func filterChip(_ text: String, dotHex: String? = nil, onRemove: @escaping () -> Void) -> some View {
        Button(action: onRemove) {
            HStack(spacing: 5) {
                if let dotHex {
                    Circle()
                        .fill(Color(charkleHex: dotHex))
                        .frame(width: 10, height: 10)
                }
                Text(text)
                    .font(.system(size: 11.5, weight: .medium))
                Image(systemName: "xmark")
                    .font(.system(size: 9, weight: .bold))
            }
            .foregroundStyle(.primary)
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .charkleFloatingCapsule(interactive: true)
        }
        .buttonStyle(.plain)
    }

    // MARK: - Apple Photos-Style Drag-to-Multi-Select Sweep

    private func dragMultiSelectGesture(snapshot: VirtualizedMasonrySnapshot) -> some Gesture {
        DragGesture(minimumDistance: 10, coordinateSpace: .named("galleryViewport"))
            .onChanged { value in
                guard store.isMultiSelectMode, !isPinching else { return }
                let scrollY = max(0, viewportRect.minY)
                let startContent = CGPoint(x: value.startLocation.x, y: value.startLocation.y + scrollY)
                let currentContent = CGPoint(x: value.location.x, y: value.location.y + scrollY)

                if dragDecision == nil {
                    let dx = abs(value.translation.width)
                    let dy = abs(value.translation.height)
                    if dx >= dy * 0.78, let startID = snapshot.hitAssetID(at: startContent) {
                        dragDecision = .sweepSelect
                        dragStartAssetID = startID
                        preDragSelection = store.selectedAssetIDs
                        dragAddsSelection = !store.selectedAssetIDs.contains(startID)
                        lastSweptAssetID = startID
                        applyRangeSelection(from: startID, to: startID)
                        MobileHaptics.light()
                    } else {
                        dragDecision = .scroll
                    }
                }

                guard dragDecision == .sweepSelect,
                      let anchorID = dragStartAssetID,
                      let hitID = snapshot.hitAssetID(at: currentContent) else {
                    return
                }
                if hitID != lastSweptAssetID {
                    lastSweptAssetID = hitID
                    applyRangeSelection(from: anchorID, to: hitID)
                    MobileHaptics.light()
                }
            }
            .onEnded { _ in
                dragDecision = nil
                dragStartAssetID = nil
                lastSweptAssetID = nil
                preDragSelection = []
            }
    }

    private func applyRangeSelection(from startID: UUID, to endID: UUID) {
        guard let startIdx = displayedAssets.firstIndex(where: { $0.id == startID }),
              let endIdx = displayedAssets.firstIndex(where: { $0.id == endID }) else {
            return
        }
        let lower = min(startIdx, endIdx)
        let upper = max(startIdx, endIdx)
        let rangeIDs = Set(displayedAssets[lower...upper].map(\.id))
        if dragAddsSelection {
            store.selectedAssetIDs = preDragSelection.union(rangeIDs)
        } else {
            store.selectedAssetIDs = preDragSelection.subtracting(rangeIDs)
        }
    }

    // MARK: - Photos-Style Anchor-Locked Two-Finger Pinch Zoom (Zero Jump / Zero Flicker)

    private func pinchColumnZoomGesture(
        viewportSize: CGSize,
        currentSnapshot: VirtualizedMasonrySnapshot,
        topInset: CGFloat,
        bottomInset: CGFloat
    ) -> some Gesture {
        MagnifyGesture()
            .onChanged { value in
                let minCols = isCompact ? 1 : 2
                let maxCols = isCompact ? 5 : 7

                // Lock onto the exact card under the user's two fingers once when pinch starts
                if !isPinching {
                    isPinching = true
                    pinchBaselineScale = max(0.01, value.magnification)
                    let anchorX = max(0, min(viewportSize.width, value.startLocation.x))
                    let anchorY = max(0, min(viewportSize.height, value.startLocation.y))
                    pinchUnitAnchor = UnitPoint(
                        x: anchorX / max(1, viewportSize.width),
                        y: anchorY / max(1, viewportSize.height)
                    )
                    let contentPoint = CGPoint(x: anchorX, y: anchorY + max(0, viewportRect.minY))
                    if let anchorID = currentSnapshot.closestAssetID(to: contentPoint),
                       let anchorRect = currentSnapshot.rectByID[anchorID] {
                        pinchAnchorAssetID = anchorID
                        pinchAnchorViewportY = anchorRect.midY - max(0, viewportRect.minY)
                    } else {
                        pinchAnchorAssetID = nil
                        pinchAnchorViewportY = anchorY
                    }
                }

                let relative = value.magnification / max(0.01, pinchBaselineScale)
                // Gentle rubber-band feedback anchored right at the pinch centroid
                let rubber = 1.0 + (relative - 1.0) * 0.16
                livePinchRubberScale = max(0.90, min(1.12, rubber))

                let currentCols = currentSnapshot.colCount
                var nextCols: Int? = nil
                if relative <= 0.74, currentCols < maxCols {
                    nextCols = currentCols + 1
                } else if relative >= 1.30, currentCols > minCols {
                    nextCols = currentCols - 1
                }

                if let nextCols {
                    let nextSpacing = MobileMasonryLayout.adaptiveSpacing(for: nextCols, isCompact: isCompact)
                    let nextHPadding: CGFloat = nextCols >= 4 ? (nextCols >= 5 ? 2 : 5) : (isCompact ? 8 : 16)
                    let nextSnapshot = VirtualizedMasonrySnapshot.build(
                        assets: displayedAssets,
                        containerWidth: viewportSize.width,
                        colCount: nextCols,
                        spacing: nextSpacing,
                        horizontalPadding: nextHPadding,
                        topInset: topInset,
                        bottomInset: bottomInset
                    )

                    let maxScrollY = max(0, nextSnapshot.contentHeight - max(200, viewportSize.height))
                    let compensatedScrollY: CGFloat
                    if let anchorID = pinchAnchorAssetID, let newRect = nextSnapshot.rectByID[anchorID] {
                        // Keep the exact anchored card pinned at the exact same vertical screen Y under user's fingers
                        compensatedScrollY = max(0, min(maxScrollY, newRect.midY - pinchAnchorViewportY))
                    } else {
                        let oldMax = max(1, currentSnapshot.contentHeight - viewportSize.height)
                        let progress = max(0, min(1, viewportRect.minY / oldMax))
                        compensatedScrollY = progress * maxScrollY
                    }

                    // Apply column switch + exact scroll compensation atomically without broken implicit column animation
                    var tx = Transaction()
                    tx.disablesAnimations = true
                    withTransaction(tx) {
                        store.columnCountOverride = nextCols
                        viewportRect = CGRect(x: 0, y: compensatedScrollY, width: viewportSize.width, height: viewportSize.height)
                        scrollPosition.scrollTo(y: compensatedScrollY)
                        livePinchRubberScale = 1.0
                    }

                    pinchBaselineScale = value.magnification
                    MobileHaptics.light()
                    flashPinchBadge("\(nextCols) 列")
                }
            }
            .onEnded { _ in
                isPinching = false
                pinchBaselineScale = 1.0
                pinchAnchorAssetID = nil
                withAnimation(MobileMotion.accessible(MobileMotion.gestureSpring, reduced: reduceMotion)) {
                    livePinchRubberScale = 1.0
                }
            }
    }

    private func flashPinchBadge(_ text: String) {
        pinchBadgeDismissTask?.cancel()
        withAnimation(MobileMotion.enterSm) {
            activePinchLabel = text
        }
        pinchBadgeDismissTask = Task {
            try? await Task.sleep(for: .milliseconds(850))
            guard !Task.isCancelled else { return }
            withAnimation(MobileMotion.exitSm) {
                activePinchLabel = nil
            }
        }
    }

    private func toggleSelection(_ id: UUID) {
        MobileHaptics.light()
        if store.selectedAssetIDs.contains(id) {
            store.selectedAssetIDs.remove(id)
        } else {
            store.selectedAssetIDs.insert(id)
        }
    }

    private func shareAsset(_ asset: AssetRecord) async {
        if let url = try? await store.engine.originalURL(for: asset.id) {
            shareAssetURL = url
        } else if let thumb = await store.engine.thumbnailURL(for: asset.id, tier: .preview1400) {
            shareAssetURL = thumb
        } else {
            store.showToast("暂无法获取可分享的原图", tone: .warning)
        }
    }

    // MARK: - Sync Progress Banner

    private func syncProgressBanner(fraction: Double) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(store.syncStatus.localizedPhaseTitle)
                    .font(.system(size: 12.5, weight: .semibold))
                Spacer()
                Text("\(Int((max(0, min(1, fraction)) * 100).rounded()))%")
                    .font(.system(size: 12, weight: .medium).monospacedDigit())
                    .foregroundStyle(MobileTheme.secondaryInk(for: colorScheme))
            }
            ProgressView(value: max(0, min(1, fraction)))
                .tint(MobileTheme.accent(for: colorScheme))
            if let detail = store.syncStatus.currentDetail, !detail.isEmpty {
                Text(detail)
                    .font(.system(size: 11.5))
                    .foregroundStyle(MobileTheme.secondaryInk(for: colorScheme))
                    .lineLimit(1)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(
            MobileTheme.surfaceElevated(for: colorScheme),
            in: RoundedRectangle(cornerRadius: MobileTheme.Radius.cardOuter, style: .continuous)
        )
        .overlay(
            RoundedRectangle(cornerRadius: MobileTheme.Radius.cardOuter, style: .continuous)
                .strokeBorder(MobileTheme.hairline(for: colorScheme), lineWidth: 0.75)
        )
    }

    // MARK: - Multi-Select Floating Dock

    private var multiSelectFloatingDock: some View {
        HStack(spacing: MobileTheme.Space.md) {
            Button {
                if store.selectedAssetIDs.count == displayedAssets.count {
                    store.selectedAssetIDs.removeAll()
                } else {
                    store.selectedAssetIDs = Set(displayedAssets.map(\.id))
                }
                MobileHaptics.light()
            } label: {
                Text(store.selectedAssetIDs.count == displayedAssets.count ? "全不选" : "全选")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(MobileTheme.accent(for: colorScheme))
            }
            .buttonStyle(.plain)

            Text("已选 \(store.selectedAssetIDs.count)")
                .font(.system(size: 13.5, weight: .semibold).monospacedDigit())

            Spacer(minLength: 4)

            Button {
                isBatchBoardSheetPresented = true
            } label: {
                Label("情绪板", systemImage: "rectangle.3.group")
                    .font(.system(size: 13, weight: .medium))
            }
            .disabled(store.selectedAssetIDs.isEmpty)

            Button {
                isBatchFolderSheetPresented = true
            } label: {
                Label("移动", systemImage: "folder")
                    .font(.system(size: 13, weight: .medium))
            }
            .disabled(store.selectedAssetIDs.isEmpty)

            if store.scope == .trash {
                Button {
                    let ids = Array(store.selectedAssetIDs)
                    store.isMultiSelectMode = false
                    store.selectedAssetIDs.removeAll()
                    Task {
                        await store.patchAssets(
                            AssetBatchPatch(assetIDs: ids, isTrashed: false),
                            successToast: "已恢复 \(ids.count) 项素材"
                        )
                    }
                } label: {
                    Label("恢复", systemImage: "arrow.uturn.backward")
                        .font(.system(size: 13, weight: .medium))
                }
                .disabled(store.selectedAssetIDs.isEmpty)

                Button(role: .destructive) {
                    confirmPermanentDelete = true
                } label: {
                    Image(systemName: "trash.slash")
                        .font(.system(size: 14, weight: .medium))
                }
                .disabled(store.selectedAssetIDs.isEmpty)
            } else {
                Button(role: .destructive) {
                    let ids = Array(store.selectedAssetIDs)
                    store.isMultiSelectMode = false
                    store.selectedAssetIDs.removeAll()
                    Task {
                        await store.patchAssets(
                            AssetBatchPatch(assetIDs: ids, isTrashed: true),
                            successToast: "已移入回收站"
                        )
                    }
                } label: {
                    Image(systemName: "trash")
                        .font(.system(size: 14, weight: .medium))
                }
                .disabled(store.selectedAssetIDs.isEmpty)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .charkleFloatingCapsule(interactive: true)
    }

    // MARK: - Empty States (DESIGN.md §5.2 Miniature UI Vignettes)

    @ViewBuilder
    private var emptyStateView: some View {
        if store.hasActiveFilters {
            MobileEmptyStateView(
                kind: .noSearchResults,
                title: "没有匹配的素材",
                subtitle: "放宽关键词、颜色或格式筛选条件后再试试。",
                primaryActionTitle: "清除筛选",
                primaryAction: { store.clearFilters() }
            )
        } else {
            switch store.scope {
            case .trash:
                MobileEmptyStateView(
                    kind: .emptyTrash,
                    title: "回收站是空的",
                    subtitle: "软删除的素材会暂存在这里，支持随时恢复。"
                )
            case .folder:
                MobileEmptyStateView(
                    kind: .emptyFolder,
                    title: "这个文件夹还是空的",
                    subtitle: "从相册、链接或系统分享面板收藏素材到此处。",
                    primaryActionTitle: "立即采集",
                    primaryAction: onOpenCapture
                )
            default:
                MobileEmptyStateView(
                    kind: .emptyLibrary,
                    title: "开始建立你的随身视觉库",
                    subtitle: "连接 Google Drive 或 iCloud 同步已有桌面库，或直接采集图片与灵感链接。",
                    primaryActionTitle: store.hasConnectedCloudBackend ? "立即采集" : "配置云同步",
                    primaryAction: store.hasConnectedCloudBackend ? onOpenCapture : onOpenSyncSettings,
                    secondaryActionTitle: "载入示例库",
                    secondaryAction: {
                        Task { await store.seedSampleLibrary() }
                    }
                )
            }
        }
    }
}

// MARK: - Pure-Image Waterfall Card + 1:1 Desktop-Matched Long-Press Menu

struct GalleryCardView: View {
    let asset: AssetRecord
    @Bindable var store: MobileAppStore
    let zoomNamespace: Namespace.ID
    let zoomOrigin: PreviewZoomOrigin
    var cornerRadius: CGFloat = MobileTheme.Radius.cardOuter
    var isDenseOverview: Bool = false
    let isMultiSelect: Bool
    let isSelected: Bool
    var isHighlighted: Bool = false
    let onTap: () -> Void
    let onFindSimilar: () -> Void
    let onShareOriginal: () -> Void
    let onRequestPermanentDelete: () -> Void
    let onSelectMultiple: () -> Void

    @Environment(\.colorScheme) private var colorScheme
    @State private var image: UIImage?

    private var resolvedAspectRatio: CGFloat {
        MobileMasonryLayout.effectiveAspectRatio(for: asset, loadedImage: image)
    }

    private var placeholderColor: Color {
        if let hex = asset.dominantColors.first?.hex {
            return Color(charkleHex: hex).opacity(colorScheme == .dark ? 0.32 : 0.20)
        }
        return MobileTheme.surfaceSubtle(for: colorScheme)
    }

    var body: some View {
        Button(action: onTap) {
            Color.clear
                .aspectRatio(resolvedAspectRatio, contentMode: .fit)
                .overlay {
                    if let image {
                        Image(uiImage: image)
                            .resizable()
                            .scaledToFill()
                            .transition(.opacity.animation(MobileMotion.enterSm))
                    } else {
                        placeholderColor
                            .overlay {
                                if !isDenseOverview && (asset.mediaKind == .audio || asset.mediaKind == .document) {
                                    VStack(spacing: 6) {
                                        Image(systemName: iconForKind(asset.mediaKind))
                                            .font(.system(size: 20, weight: .medium))
                                            .foregroundStyle(MobileTheme.secondaryInk(for: colorScheme))
                                        Text(asset.title)
                                            .font(.system(size: 11.5, weight: .medium))
                                            .foregroundStyle(MobileTheme.secondaryInk(for: colorScheme))
                                            .lineLimit(2)
                                            .multilineTextAlignment(.center)
                                            .padding(.horizontal, 8)
                                    }
                                }
                            }
                    }
                }
                .clipped()
                .overlay(alignment: .bottom) {
                    if !isDenseOverview && (mediaBadgeText != nil || asset.pinnedOffline) {
                        HStack(spacing: 4) {
                            if let badge = mediaBadgeText {
                                Text(badge)
                                    .font(.system(size: 10.5, weight: .semibold).monospacedDigit())
                                    .foregroundStyle(.white)
                                    .padding(.horizontal, 6)
                                    .padding(.vertical, 3)
                                    .background(
                                        .black.opacity(0.58),
                                        in: RoundedRectangle(cornerRadius: MobileTheme.Radius.cardInnerBadge, style: .continuous)
                                    )
                            }
                            Spacer(minLength: 0)
                            if asset.pinnedOffline {
                                Image(systemName: "pin.fill")
                                    .font(.system(size: 9.5, weight: .bold))
                                    .foregroundStyle(.white)
                                    .padding(4.5)
                                    .background(
                                        .black.opacity(0.55),
                                        in: RoundedRectangle(cornerRadius: MobileTheme.Radius.cardInnerBadge, style: .continuous)
                                    )
                            }
                        }
                        .padding(6)
                    }
                }
                .overlay(alignment: .topTrailing) {
                    if isMultiSelect {
                        Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                            .font(.system(size: 20, weight: .semibold))
                            .foregroundStyle(isSelected ? MobileTheme.accent(for: colorScheme) : .white)
                            .shadow(color: .black.opacity(0.35), radius: 3, y: 1)
                            .padding(6)
                    }
                }
                .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                        .strokeBorder(
                            (isSelected || isHighlighted)
                                ? MobileTheme.accent(for: colorScheme)
                                : MobileTheme.hairline(for: colorScheme),
                            lineWidth: isHighlighted ? 3.2 : (isSelected ? 2.5 : 0.5)
                        )
                )
                .shadow(
                    color: isHighlighted ? MobileTheme.accent(for: colorScheme).opacity(0.42) : .clear,
                    radius: isHighlighted ? 14 : 0
                )
                .scaleEffect(isHighlighted ? 1.025 : 1.0)
                .animation(MobileMotion.settleStrong, value: isHighlighted)
                .contentShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
        }
        .buttonStyle(MobileTactileButtonStyle())
        .matchedTransitionSource(
            id: PreviewZoomSourceID(origin: zoomOrigin, assetID: asset.id),
            in: zoomNamespace
        ) { configuration in
            configuration
                .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
        }
        .contextMenu {
            desktopParityContextMenu
        }
        .task(id: "\(asset.id.uuidString)-\(store.thumbnails.revision)") {
            if let cached = store.thumbnails.cachedImage(for: asset.id, tier: .grid520) {
                image = cached
                return
            }
            let loaded = await store.thumbnails.loadImage(for: asset.id, tier: .grid520)
            if let loaded {
                image = loaded
            }
        }
    }

    // MARK: - 1:1 Desktop Right-Click Context Menu Parity

    @ViewBuilder
    private var desktopParityContextMenu: some View {
        Button {
            onTap()
        } label: {
            Label(
                asset.isExternalWebLink ? "在浏览器中打开" : "快速预览",
                systemImage: asset.isExternalWebLink ? "safari" : "eye"
            )
        }

        if asset.isTrashed {
            Divider()
            Button {
                Task {
                    await store.patchAssets(
                        AssetBatchPatch(assetIDs: [asset.id], isTrashed: false),
                        successToast: "已放回原处"
                    )
                }
            } label: {
                Label("放回原处", systemImage: "arrow.uturn.backward")
            }

            Button(role: .destructive) {
                onRequestPermanentDelete()
            } label: {
                Label("彻底删除", systemImage: "trash.slash")
            }
        } else {
            Divider()

            Button {
                Task { await store.copyAssetToPasteboard(asset) }
            } label: {
                Label("拷贝", systemImage: "doc.on.doc")
            }

            Button(action: onShareOriginal) {
                Label("分享原图", systemImage: "square.and.arrow.up")
            }

            Divider()

            Menu {
                ForEach(store.boards) { board in
                    Button(board.title) {
                        Task { await store.addAssets([asset.id], toBoard: board.id) }
                    }
                }
                if !store.boards.isEmpty {
                    Divider()
                }
                Button {
                    let id = asset.id
                    let title = asset.title
                    Task { _ = await store.createMoodboard(title: title, seedAssetIDs: [id]) }
                } label: {
                    Label("新建情绪板并加入", systemImage: "plus")
                }
            } label: {
                Label("加入情绪板…", systemImage: "rectangle.3.group")
            }

            Menu {
                ForEach((1...5).reversed(), id: \.self) { stars in
                    Button {
                        Task {
                            await store.patchAssets(
                                AssetBatchPatch(assetIDs: [asset.id], rating: stars),
                                successToast: "已评为 \(stars) 星"
                            )
                        }
                    } label: {
                        Label(
                            String(repeating: "★", count: stars) + (asset.rating == stars ? "  ✓" : ""),
                            systemImage: asset.rating == stars ? "star.fill" : "star"
                        )
                    }
                }
                if asset.rating > 0 {
                    Divider()
                    Button("清除评分") {
                        Task {
                            await store.patchAssets(AssetBatchPatch(assetIDs: [asset.id], rating: 0))
                        }
                    }
                }
            } label: {
                Label(
                    asset.rating > 0 ? "评分（\(asset.rating)★）" : "评分",
                    systemImage: asset.rating > 0 ? "star.fill" : "star"
                )
            }

            Button {
                Task { await store.retagAssets([asset.id]) }
            } label: {
                Label("AI 重新打标", systemImage: "sparkles")
            }

            Button(action: onFindSimilar) {
                Label("查找相似素材", systemImage: "sparkle.magnifyingglass")
            }

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
                if !store.flattenedFolders.isEmpty {
                    Divider()
                    ForEach(store.flattenedFolders) { node in
                        let isCurrent = asset.folderID == node.folder.id
                        Button {
                            Task {
                                await store.patchAssets(
                                    AssetBatchPatch(assetIDs: [asset.id], folderAssignment: .folder(node.folder.id)),
                                    successToast: "已归档到「\(node.folder.name)」"
                                )
                            }
                        } label: {
                            Label(
                                String(repeating: "  ", count: min(node.depth, 3)) + node.folder.name + (isCurrent ? "  ✓" : ""),
                                systemImage: isCurrent ? "folder.fill" : "folder"
                            )
                        }
                    }
                }
            } label: {
                Label("移动到文件夹", systemImage: "folder.badge.plus")
            }

            Button {
                let next = !asset.pinnedOffline
                Task {
                    await store.patchAssets(
                        AssetBatchPatch(assetIDs: [asset.id], pinnedOffline: next),
                        successToast: next ? "已始终保留在本地" : "已取消始终保留在本地"
                    )
                }
            } label: {
                Label(
                    asset.pinnedOffline ? "取消始终保留在本地" : "始终保留在本地",
                    systemImage: asset.pinnedOffline ? "icloud" : "arrow.down.circle"
                )
            }

            if let hex = asset.dominantColors.first?.hex.uppercased() {
                Button {
                    UIPasteboard.general.string = hex
                    MobileHaptics.light()
                    store.showToast("已复制主色 \(hex)", tone: .info)
                } label: {
                    Label("复制主色 \(hex)", systemImage: "paintpalette")
                }

                Button {
                    store.setColorFilter(hex)
                } label: {
                    Label("按主色筛图", systemImage: "eyedropper")
                }
            }

            Button(action: onSelectMultiple) {
                Label("多选批处理", systemImage: "checkmark.circle")
            }

            Divider()

            Button(role: .destructive) {
                Task {
                    await store.patchAssets(
                        AssetBatchPatch(assetIDs: [asset.id], isTrashed: true),
                        successToast: "已移至回收站"
                    )
                }
            } label: {
                Label("移至回收站", systemImage: "trash")
            }
        }
    }

    private var mediaBadgeText: String? {
        if let post = asset.richMetadata?.socialPost {
            return post.platform.displayName
        }
        if asset.isGitHubRepo {
            return "GitHub"
        }
        switch asset.mediaKind {
        case .animatedImage:
            return "GIF"
        case .video:
            if let dur = asset.durationSeconds, dur > 0 {
                let mins = Int(dur) / 60
                let secs = Int(dur) % 60
                return String(format: "%d:%02d", mins, secs)
            }
            return "视频"
        case .webBookmark:
            return asset.sourceDomain ?? "网页"
        case .audio:
            return "音频"
        case .model3D:
            return "3D"
        case .document:
            return (asset.fileName as NSString).pathExtension.uppercased()
        case .image, .designFile:
            return nil
        }
    }

    private func iconForKind(_ kind: MediaKind) -> String {
        switch kind {
        case .audio: "waveform"
        case .document: "doc.text"
        case .video: "play.rectangle"
        case .model3D: "cube"
        case .webBookmark: "globe"
        default: "photo"
        }
    }
}

// MARK: - Batch Folder & Moodboard Pickers

private struct BatchFolderPickerSheet: View {
    let folders: [FolderHierarchyNode]
    let onPick: (UUID?) -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        List {
            Button {
                onPick(nil)
            } label: {
                Label("收件箱", systemImage: "tray")
            }
            Section("文件夹") {
                ForEach(folders) { node in
                    Button {
                        onPick(node.folder.id)
                    } label: {
                        HStack(spacing: 10) {
                            Image(systemName: "folder.fill")
                                .foregroundStyle(node.folder.colorHex.map { Color(charkleHex: $0) } ?? .accentColor)
                            Text(node.folder.name)
                        }
                        .padding(.leading, CGFloat(min(node.depth, 4)) * 14)
                    }
                }
            }
        }
        .navigationTitle("移动到")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("取消") { dismiss() }
            }
        }
    }
}

private struct BatchBoardPickerSheet: View {
    @Bindable var store: MobileAppStore
    let assetIDs: [UUID]
    let onDone: () -> Void
    @State private var newBoardTitle = ""

    var body: some View {
        List {
            Section("加入已有情绪板") {
                if store.boards.isEmpty {
                    Text("尚无情绪板，可在下方直接新建")
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(store.boards) { board in
                        Button {
                            Task {
                                await store.addAssets(assetIDs, toBoard: board.id)
                                onDone()
                            }
                        } label: {
                            HStack {
                                Label(board.title, systemImage: "rectangle.3.group")
                                Spacer()
                                Text("\(board.itemCount) 项")
                                    .font(.system(size: 12).monospacedDigit())
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                }
            }

            Section("新建情绪板并加入（\(assetIDs.count) 项）") {
                TextField("输入新情绪板名称…", text: $newBoardTitle)
                Button("创建并加入") {
                    let title = newBoardTitle.trimmingCharacters(in: .whitespacesAndNewlines)
                    Task {
                        _ = await store.createMoodboard(
                            title: title.isEmpty ? "新建情绪板" : title,
                            seedAssetIDs: assetIDs
                        )
                        onDone()
                    }
                }
                .fontWeight(.semibold)
            }
        }
        .navigationTitle("加入情绪板")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("取消", action: onDone)
            }
        }
    }
}
