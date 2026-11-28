import CharkleCore
import SwiftUI
import UIKit
import UniformTypeIdentifiers

// MARK: - 5th Universal Gallery Mode: Studio Compact View (1-Col Hairline Table & iPad 2-Col Bento Grid)

/// Native iOS & iPadOS implementation of `GalleryLayoutMode.compactList` (`紧凑视图`):
/// - Minimal sub-toolbar showing category pills (`全部 / 文档 / 媒体`) only on mixed collections, plus an icon-only
///   1-col / 2-col segmented switcher on iPad regular width.
/// - 1-Column Mode (`columns == 1`): unified `MobileTheme.surfaceElevated` rounded table surface separated by crisp
///   `0.5pt` hairlines inset from `leading: 58` (zero puffy per-row drop shadows, audio-only waveform sparkbar).
/// - 2-Column Mode on iPad (`columns == 2`): tight `8pt` non-splitting Bento grid of `58pt`-tall horizontal tiles.
/// - Universal Vertical Version Timeline Popover (`MobileVersionTimelinePopover`): anchored to the quiet `vN/M ▾` badge
///   in both 1-column and 2-column modes (`vN → v1` newest-first spine, `Δ N` diff trigger, 1-tap primary pin).
struct MobileCompactIndexGalleryView: View {
    private enum QuickCategoryFilter: String, CaseIterable, Identifiable {
        case all = "全部"
        case documents = "文档"
        case media = "媒体"

        var id: String { rawValue }
    }

    private enum CompactBentoRow: Identifiable {
        case pair(AssetRecord, AssetRecord)
        case single(AssetRecord)

        var id: String {
            switch self {
            case .pair(let a, let b):
                return "pair:\(a.id.uuidString):\(b.id.uuidString)"
            case .single(let a):
                return "single:\(a.id.uuidString)"
            }
        }
    }

    @Bindable var store: MobileAppStore
    let displayedAssets: [AssetRecord]
    let isCompact: Bool
    let topInset: CGFloat
    let bottomInset: CGFloat
    let zoomNamespace: Namespace.ID
    let zoomOrigin: PreviewZoomOrigin
    let onOpenAsset: (AssetRecord) -> Void
    let onOpenDiff: (AssetRecord, UUID, UUID) -> Void
    let onFindSimilar: (AssetRecord) -> Void
    let onSharePrimary: (AssetRecord) -> Void
    let onRequestMergeStack: (AssetRecord) -> Void
    let onRequestMoveFolder: (AssetRecord) -> Void
    let onRequestPermanentDelete: (UUID) -> Void
    let onHeaderScrollStep: (CGFloat) -> Void

    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    @State private var quickCategory: QuickCategoryFilter = .all
    @State private var popoverAnchorAssetID: UUID? = nil
    @State private var hoveredRowAssetID: UUID? = nil

    private func isAssetSelected(_ item: AssetRecord) -> Bool {
        store.isMultiSelectMode
            ? store.selectedAssetIDs.contains(item.id)
            : (store.selectedAssetID == item.id || store.highlightedAssetID == item.id)
    }

    private var documentCount: Int {
        displayedAssets.filter { $0.mediaKind == .document }.count
    }

    private var mediaCount: Int {
        displayedAssets.count - documentCount
    }

    private var shouldShowCategoryPills: Bool {
        (documentCount > 0 && mediaCount > 0) || quickCategory != .all
    }

    private var filteredItems: [AssetRecord] {
        switch quickCategory {
        case .all:
            return displayedAssets
        case .documents:
            return displayedAssets.filter { $0.mediaKind == .document }
        case .media:
            return displayedAssets.filter { $0.mediaKind != .document }
        }
    }

    private func resolvedColumnCount(for width: CGFloat) -> Int {
        if isCompact || width < 620 {
            return 1
        }
        if let override = store.compactBentoColumnOverride {
            return override == 1 ? 1 : 2
        }
        return 2
    }

    /// Pairs items strictly 2-by-2 in 2-column mode and NEVER splits `.pair` into `.single`.
    private func buildRows(items: [AssetRecord], columns: Int) -> [CompactBentoRow] {
        guard columns == 2 else {
            return items.map { .single($0) }
        }
        var rows: [CompactBentoRow] = []
        rows.reserveCapacity((items.count + 1) / 2)
        var index = 0
        while index < items.count {
            if index + 1 < items.count {
                rows.append(.pair(items[index], items[index + 1]))
                index += 2
            } else {
                rows.append(.single(items[index]))
                index += 1
            }
        }
        return rows
    }

    var body: some View {
        GeometryReader { proxy in
            let columns = resolvedColumnCount(for: proxy.size.width)
            let items = filteredItems
            let horizontalPad: CGFloat = isCompact ? 12 : 18
            let tableShape = RoundedRectangle(cornerRadius: MobileTheme.Radius.cardOuter, style: .continuous)

            ScrollView {
                VStack(alignment: .leading, spacing: 10) {
                    Color.clear
                        .frame(height: max(0, topInset - 6))

                    if store.syncStatus.isSyncing, let fraction = store.syncStatus.progressFraction {
                        compactSyncBanner(fraction: fraction)
                    }

                    studioSubToolbar(columns: columns, canToggleBento: !isCompact && proxy.size.width >= 620)

                    if items.isEmpty {
                        VStack(spacing: 8) {
                            Image(systemName: "doc.text.magnifyingglass")
                                .font(.system(size: 22, weight: .medium))
                                .foregroundStyle(MobileTheme.tertiaryInk(for: colorScheme))
                            Text("当前分类下暂无素材")
                                .font(.system(size: 13.5, weight: .medium))
                                .foregroundStyle(MobileTheme.secondaryInk(for: colorScheme))
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 48)
                    } else if columns == 1 {
                        // 1-Column Mode: Sleek Unified Hairline Tracklist Table with Smart Divider Suppression
                        let dividerLeading: CGFloat = store.isMultiSelectMode ? 88 : 60
                        LazyVStack(alignment: .leading, spacing: 0) {
                            ForEach(Array(items.enumerated()), id: \.element.id) { idx, item in
                                CompactItemCellView(
                                    store: store,
                                    asset: item,
                                    isBentoCell: false,
                                    isCompactWidth: isCompact,
                                    popoverAnchorAssetID: $popoverAnchorAssetID,
                                    hoveredRowAssetID: $hoveredRowAssetID,
                                    zoomNamespace: zoomNamespace,
                                    zoomOrigin: zoomOrigin,
                                    onOpenAsset: onOpenAsset,
                                    onOpenDiff: onOpenDiff,
                                    onFindSimilar: onFindSimilar,
                                    onSharePrimary: onSharePrimary,
                                    onRequestMergeStack: onRequestMergeStack,
                                    onRequestMoveFolder: onRequestMoveFolder,
                                    onRequestPermanentDelete: onRequestPermanentDelete
                                )

                                if idx < items.count - 1 {
                                    let nextItem = items[idx + 1]
                                    let suppressDivider = isAssetSelected(item)
                                        || isAssetSelected(nextItem)
                                        || hoveredRowAssetID == item.id
                                        || hoveredRowAssetID == nextItem.id
                                    if suppressDivider {
                                        Color.clear.frame(height: 0.5)
                                    } else {
                                        Rectangle()
                                            .fill(MobileTheme.hairline(for: colorScheme))
                                            .frame(height: 0.5)
                                            .padding(.leading, dividerLeading)
                                    }
                                }
                            }
                        }
                        .padding(.vertical, 4)
                        .background(MobileTheme.surfaceElevated(for: colorScheme), in: tableShape)
                        .clipShape(tableShape)
                        .overlay(
                            tableShape.strokeBorder(MobileTheme.hairline(for: colorScheme), lineWidth: 0.5)
                        )
                    } else {
                        // 2-Column Mode on iPad: Tight 8pt Non-Splitting Bento Grid
                        let bentoRows = buildRows(items: items, columns: 2)
                        LazyVStack(alignment: .leading, spacing: 8) {
                            ForEach(bentoRows) { row in
                                switch row {
                                case .pair(let left, let right):
                                    HStack(alignment: .center, spacing: 8) {
                                        CompactItemCellView(
                                            store: store,
                                            asset: left,
                                            isBentoCell: true,
                                            isCompactWidth: false,
                                            popoverAnchorAssetID: $popoverAnchorAssetID,
                                            hoveredRowAssetID: $hoveredRowAssetID,
                                            zoomNamespace: zoomNamespace,
                                            zoomOrigin: zoomOrigin,
                                            onOpenAsset: onOpenAsset,
                                            onOpenDiff: onOpenDiff,
                                            onFindSimilar: onFindSimilar,
                                            onSharePrimary: onSharePrimary,
                                            onRequestMergeStack: onRequestMergeStack,
                                            onRequestMoveFolder: onRequestMoveFolder,
                                            onRequestPermanentDelete: onRequestPermanentDelete
                                        )
                                        .frame(maxWidth: .infinity)

                                        CompactItemCellView(
                                            store: store,
                                            asset: right,
                                            isBentoCell: true,
                                            isCompactWidth: false,
                                            popoverAnchorAssetID: $popoverAnchorAssetID,
                                            hoveredRowAssetID: $hoveredRowAssetID,
                                            zoomNamespace: zoomNamespace,
                                            zoomOrigin: zoomOrigin,
                                            onOpenAsset: onOpenAsset,
                                            onOpenDiff: onOpenDiff,
                                            onFindSimilar: onFindSimilar,
                                            onSharePrimary: onSharePrimary,
                                            onRequestMergeStack: onRequestMergeStack,
                                            onRequestMoveFolder: onRequestMoveFolder,
                                            onRequestPermanentDelete: onRequestPermanentDelete
                                        )
                                        .frame(maxWidth: .infinity)
                                    }

                                case .single(let lone):
                                    HStack(alignment: .center, spacing: 8) {
                                        CompactItemCellView(
                                            store: store,
                                            asset: lone,
                                            isBentoCell: true,
                                            isCompactWidth: false,
                                            popoverAnchorAssetID: $popoverAnchorAssetID,
                                            hoveredRowAssetID: $hoveredRowAssetID,
                                            zoomNamespace: zoomNamespace,
                                            zoomOrigin: zoomOrigin,
                                            onOpenAsset: onOpenAsset,
                                            onOpenDiff: onOpenDiff,
                                            onFindSimilar: onFindSimilar,
                                            onSharePrimary: onSharePrimary,
                                            onRequestMergeStack: onRequestMergeStack,
                                            onRequestMoveFolder: onRequestMoveFolder,
                                            onRequestPermanentDelete: onRequestPermanentDelete
                                        )
                                        .frame(maxWidth: .infinity)

                                        Color.clear
                                            .frame(maxWidth: .infinity, minHeight: 58, maxHeight: 58)
                                    }
                                }
                            }
                        }
                    }

                    Color.clear
                        .frame(height: bottomInset)
                }
                .padding(.horizontal, horizontalPad)
            }
            .charkleDismissKeyboardOnScroll()
            .charkleScrollEdgeSoft(for: [.top, .bottom])
            .onScrollGeometryChange(for: Int.self) { geo in
                Int(floor(max(0, geo.visibleRect.minY) / 16.0))
            } action: { _, step in
                onHeaderScrollStep(CGFloat(step) * 16.0)
            }
            .refreshable {
                if store.hasConnectedCloudBackend {
                    await store.syncNow(quiet: false)
                } else {
                    await store.reloadAll()
                }
            }
            .dropDestination(for: URL.self) { urls, _ in
                guard !urls.isEmpty else { return false }
                Task { await store.importDroppedURLs(urls) }
                return true
            }
        }
    }

    // MARK: - Minimal Sub-Toolbar

    private func studioSubToolbar(columns: Int, canToggleBento: Bool) -> some View {
        HStack(spacing: 8) {
            if shouldShowCategoryPills {
                HStack(spacing: 2) {
                    categoryPill(.all, count: displayedAssets.count)
                    if documentCount > 0 || quickCategory == .documents {
                        categoryPill(.documents, count: documentCount)
                    }
                    if mediaCount > 0 || quickCategory == .media {
                        categoryPill(.media, count: mediaCount)
                    }
                }
                .padding(2.5)
                .background(
                    MobileTheme.surfaceSubtle(for: colorScheme),
                    in: RoundedRectangle(cornerRadius: 8, style: .continuous)
                )
            } else {
                Text("\(displayedAssets.count) 项")
                    .font(.system(size: 12, weight: .medium).monospacedDigit())
                    .foregroundStyle(MobileTheme.secondaryInk(for: colorScheme))
                    .padding(.leading, 2)
            }

            Spacer(minLength: 4)

            if canToggleBento {
                HStack(spacing: 2) {
                    bentoIconToggleButton(
                        icon: "list.bullet",
                        accessibilityTitle: "单列列表",
                        active: columns == 1
                    ) {
                        withAnimation(MobileMotion.accessible(MobileMotion.settleStrong, reduced: reduceMotion)) {
                            store.setCompactBentoColumnOverride(1)
                        }
                    }

                    bentoIconToggleButton(
                        icon: "square.grid.2x2",
                        accessibilityTitle: "双列网格",
                        active: columns == 2
                    ) {
                        withAnimation(MobileMotion.accessible(MobileMotion.settleStrong, reduced: reduceMotion)) {
                            store.setCompactBentoColumnOverride(2)
                        }
                    }
                }
                .padding(2.5)
                .background(
                    MobileTheme.surfaceSubtle(for: colorScheme),
                    in: RoundedRectangle(cornerRadius: 8, style: .continuous)
                )
            }
        }
    }

    private func categoryPill(_ cat: QuickCategoryFilter, count: Int) -> some View {
        let isOn = quickCategory == cat
        return Button {
            MobileHaptics.light()
            withAnimation(MobileMotion.accessible(MobileMotion.settleStrong, reduced: reduceMotion)) {
                quickCategory = cat
            }
        } label: {
            HStack(spacing: 4) {
                Text(cat.rawValue)
                    .font(.system(size: 12, weight: isOn ? .semibold : .medium))
                Text("\(count)")
                    .font(.system(size: 11, weight: .medium).monospacedDigit())
                    .foregroundStyle(isOn ? MobileTheme.secondaryInk(for: colorScheme) : MobileTheme.tertiaryInk(for: colorScheme))
            }
            .foregroundStyle(isOn ? .primary : MobileTheme.secondaryInk(for: colorScheme))
            .padding(.horizontal, 9)
            .padding(.vertical, 4.5)
            .background(
                isOn ? MobileTheme.surfaceElevated(for: colorScheme) : .clear,
                in: RoundedRectangle(cornerRadius: 6, style: .continuous)
            )
            .shadow(color: .black.opacity(isOn ? 0.06 : 0), radius: 2, y: 1)
        }
        .buttonStyle(.plain)
    }

    private func bentoIconToggleButton(
        icon: String,
        accessibilityTitle: String,
        active: Bool,
        action: @escaping () -> Void
    ) -> some View {
        Button {
            MobileHaptics.light()
            action()
        } label: {
            Image(systemName: icon)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(active ? .primary : MobileTheme.secondaryInk(for: colorScheme))
                .frame(width: 28, height: 24)
                .background(
                    active ? MobileTheme.surfaceElevated(for: colorScheme) : .clear,
                    in: RoundedRectangle(cornerRadius: 6, style: .continuous)
                )
                .shadow(color: .black.opacity(active ? 0.06 : 0), radius: 2, y: 1)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(accessibilityTitle)
    }

    private func compactSyncBanner(fraction: Double) -> some View {
        HStack(spacing: 10) {
            ProgressView(value: max(0, min(1, fraction)))
                .tint(MobileTheme.accent(for: colorScheme))
                .frame(maxWidth: 160)
            Text(store.syncStatus.localizedPhaseTitle)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(MobileTheme.secondaryInk(for: colorScheme))
                .lineLimit(1)
            Spacer()
            Text("\(Int((max(0, min(1, fraction)) * 100).rounded()))%")
                .font(.system(size: 11.5, weight: .semibold).monospacedDigit())
                .foregroundStyle(MobileTheme.secondaryInk(for: colorScheme))
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(
            MobileTheme.surfaceElevated(for: colorScheme),
            in: RoundedRectangle(cornerRadius: MobileTheme.Radius.cardOuter, style: .continuous)
        )
        .overlay(
            RoundedRectangle(cornerRadius: MobileTheme.Radius.cardOuter, style: .continuous)
                .strokeBorder(MobileTheme.hairline(for: colorScheme), lineWidth: 0.5)
        )
    }
}

// MARK: - Unified 1-Col Table Row & 2-Col Bento Cell

private struct CompactItemCellView: View {
    @Bindable var store: MobileAppStore
    let asset: AssetRecord
    let isBentoCell: Bool
    let isCompactWidth: Bool
    @Binding var popoverAnchorAssetID: UUID?
    @Binding var hoveredRowAssetID: UUID?
    let zoomNamespace: Namespace.ID
    let zoomOrigin: PreviewZoomOrigin
    let onOpenAsset: (AssetRecord) -> Void
    let onOpenDiff: (AssetRecord, UUID, UUID) -> Void
    let onFindSimilar: (AssetRecord) -> Void
    let onSharePrimary: (AssetRecord) -> Void
    let onRequestMergeStack: (AssetRecord) -> Void
    let onRequestMoveFolder: (AssetRecord) -> Void
    let onRequestPermanentDelete: (UUID) -> Void

    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    @State private var isHovered: Bool = false
    @State private var isBadgeHovered: Bool = false
    @State private var isDropTargeted: Bool = false
    @State private var thumbImage: UIImage? = nil

    private var siblings: [AssetRecord] {
        store.stackMembers(for: asset)
    }

    private var hasStack: Bool {
        siblings.count > 1
    }

    private var primaryAsset: AssetRecord {
        store.primaryVersionAsset(for: asset)
    }

    private var stackGroupID: UUID? {
        primaryAsset.richMetadata?.versionStack?.groupID ?? asset.richMetadata?.versionStack?.groupID
    }

    private var isPopoverOpen: Bool {
        hasStack && popoverAnchorAssetID == asset.id
    }

    private var isSelected: Bool {
        store.isMultiSelectMode
            ? store.selectedAssetIDs.contains(asset.id)
            : (store.selectedAssetID == asset.id || store.highlightedAssetID == asset.id)
    }

    private var pendingNewerCount: Int {
        store.newerThanPrimaryCount(for: asset)
    }

    private var primaryVersionNumber: Int {
        if let explicit = primaryAsset.richMetadata?.versionStack?.versionNumber {
            return explicit
        }
        if let idx = siblings.firstIndex(where: { $0.id == primaryAsset.id }) {
            return idx + 1
        }
        return 1
    }

    private var defaultComparePair: (baseID: UUID, targetID: UUID) {
        if siblings.count >= 2 {
            if pendingNewerCount > 0, let latest = siblings.last, latest.id != primaryAsset.id {
                return (primaryAsset.id, latest.id)
            }
            let lastTwo = Array(siblings.suffix(2))
            return (lastTwo[0].id, lastTwo[1].id)
        }
        return (primaryAsset.id, primaryAsset.id)
    }

    var body: some View {
        let accent = MobileTheme.accent(for: colorScheme)
        let cellShape = RoundedRectangle(cornerRadius: MobileTheme.Radius.cardOuter, style: .continuous)
        let rowHighlightShape = RoundedRectangle(cornerRadius: 9, style: .continuous)
        let thumbSize = primaryAsset.mediaKind == .document
            ? CGSize(width: 36, height: 46)
            : CGSize(width: 38, height: 44)

        HStack(alignment: .center, spacing: isBentoCell ? 10 : 12) {
            if store.isMultiSelectMode {
                Image(systemName: store.selectedAssetIDs.contains(asset.id) ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(store.selectedAssetIDs.contains(asset.id) ? accent : MobileTheme.tertiaryInk(for: colorScheme))
                    .frame(width: 16)
            }

            // 1. Tracklist Squircle Artwork / Page Cover (`36×46` docs / `38×44` media)
            CompactMiniatureSheetThumb(
                asset: primaryAsset,
                thumbnail: store.thumbnails.cachedImage(for: primaryAsset.id, tier: .grid520) ?? thumbImage,
                hasStack: hasStack,
                isFannedOpen: (isHovered || isPopoverOpen) && !reduceMotion,
                size: thumbSize
            )

            // 2. Title (1 line) + Concise Spec
            VStack(alignment: .leading, spacing: 2.5) {
                HStack(spacing: 5) {
                    Text(primaryAsset.title)
                        .font(.system(size: 13.5, weight: .medium))
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .layoutPriority(1)

                    if primaryAsset.rating > 0 {
                        HStack(spacing: 1.5) {
                            Image(systemName: "star.fill")
                                .font(.system(size: 9.5))
                                .foregroundStyle(Color(charkleHex: "#E5B243"))
                            Text("\(primaryAsset.rating)")
                                .font(.system(size: 10.5, weight: .medium).monospacedDigit())
                                .foregroundStyle(MobileTheme.secondaryInk(for: colorScheme))
                        }
                    }
                }

                HStack(spacing: 5) {
                    Text(isBentoCell ? bentoSpecAndDateLine : conciseSpecLine)
                        .font(.system(size: 11.5).monospacedDigit())
                        .foregroundStyle(MobileTheme.secondaryInk(for: colorScheme))
                        .lineLimit(1)

                    if !isBentoCell {
                        let maxTags = isCompactWidth ? 1 : 2
                        ForEach(primaryAsset.tags.prefix(maxTags), id: \.self) { tag in
                            Text("#\(tag)")
                                .font(.system(size: 10.5, weight: .medium))
                                .foregroundStyle(MobileTheme.secondaryInk(for: colorScheme))
                                .lineLimit(1)
                                .padding(.horizontal, 5.5)
                                .padding(.vertical, 1)
                                .background(
                                    Color.primary.opacity(0.055),
                                    in: Capsule()
                                )
                        }
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            Spacer(minLength: 6)

            // 3. Right Trailing: Quiet Hover Share + Quiet vN·M Popover Capsule + Audio-Only Sparkbar + Tabular Timestamp
            HStack(spacing: 8) {
                if !isCompactWidth && isHovered && !store.isMultiSelectMode {
                    Button {
                        MobileHaptics.light()
                        onSharePrimary(primaryAsset)
                    } label: {
                        Image(systemName: "square.and.arrow.up")
                            .font(.system(size: 11.5, weight: .semibold))
                            .foregroundStyle(MobileTheme.secondaryInk(for: colorScheme))
                            .frame(width: 26, height: 26)
                            .background(Color.primary.opacity(0.055), in: Circle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(hasStack ? "分享主版本" : "分享")
                }

                if hasStack {
                    versionTriggerBadge
                }

                if primaryAsset.mediaKind == .audio {
                    audioWaveformSparkbar
                }

                if !isBentoCell {
                    Text(MobileFormatters.relativeDate(primaryAsset.updatedAt))
                        .font(.system(size: 11.5).monospacedDigit())
                        .foregroundStyle(MobileTheme.tertiaryInk(for: colorScheme))
                        .lineLimit(1)
                        .frame(minWidth: 54, alignment: .trailing)
                }
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, isBentoCell ? 6 : 6.5)
        .frame(minHeight: isBentoCell ? 58 : 52, maxHeight: isBentoCell ? 58 : nil)
        .background {
            if isBentoCell {
                cellShape.fill(
                    isDropTargeted
                        ? accent.opacity(0.10)
                        : (isSelected
                            ? MobileTheme.accentSoft(for: colorScheme)
                            : (isHovered
                                ? Color.primary.opacity(0.04)
                                : MobileTheme.surfaceElevated(for: colorScheme)))
                )
            } else {
                rowHighlightShape
                    .fill(
                        isDropTargeted
                            ? accent.opacity(0.10)
                            : (isSelected
                                ? MobileTheme.accentSoft(for: colorScheme)
                                : (isHovered
                                    ? Color.primary.opacity(0.04)
                                    : .clear))
                    )
                    .padding(.horizontal, 6)
                    .padding(.vertical, 1.5)
            }
        }
        .overlay {
            if isBentoCell {
                cellShape.strokeBorder(
                    isDropTargeted
                        ? accent
                        : (isSelected
                            ? accent
                            : (isHovered ? MobileTheme.borderStrong(for: colorScheme) : MobileTheme.hairline(for: colorScheme))),
                    lineWidth: (isDropTargeted || isSelected) ? 1.5 : 0.5
                )
            } else if isDropTargeted {
                rowHighlightShape
                    .strokeBorder(accent, lineWidth: 1.5)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 1.5)
            }
        }
        .contentShape(Rectangle())
        .onTapGesture {
            MobileKeyboard.dismiss()
            if store.isMultiSelectMode {
                MobileHaptics.light()
                if store.selectedAssetIDs.contains(asset.id) {
                    store.selectedAssetIDs.remove(asset.id)
                } else {
                    store.selectedAssetIDs.insert(asset.id)
                }
            } else {
                store.selectedAssetID = primaryAsset.id
                onOpenAsset(primaryAsset)
            }
        }
        .onHover { hovering in
            withAnimation(MobileMotion.accessible(MobileMotion.hoverPress, reduced: reduceMotion)) {
                isHovered = hovering
                if hovering {
                    hoveredRowAssetID = asset.id
                } else if hoveredRowAssetID == asset.id {
                    hoveredRowAssetID = nil
                }
            }
        }
        .matchedTransitionSource(
            id: PreviewZoomSourceID(origin: zoomOrigin, assetID: primaryAsset.id),
            in: zoomNamespace
        ) { configuration in
            configuration.clipShape(RoundedRectangle(cornerRadius: MobileTheme.Radius.cardOuter, style: .continuous))
        }
        .onDrag {
            let target = primaryAsset
            if let cachedURL = store.engine.cachedOriginalURL(for: target),
               let staged = MobileAppStore.stageHumanReadableExportURL(sourceURL: cachedURL, desiredFileName: target.fileName),
               let provider = NSItemProvider(contentsOf: staged) {
                provider.suggestedName = target.fileName
                return provider
            }
            return NSItemProvider(object: target.title as NSString)
        }
        .dropDestination(for: URL.self) { urls, _ in
            guard !urls.isEmpty else { return false }
            let targetKey = stackGroupID ?? primaryAsset.id
            Task {
                await store.importDroppedURLs(urls, ontoStackTargetID: targetKey, targetFolderID: primaryAsset.folderID)
            }
            return true
        } isTargeted: { targeted in
            isDropTargeted = targeted
        }
        .contextMenu {
            compactCardContextMenu
        }
        .task(id: "\(primaryAsset.id.uuidString)-\(store.thumbnails.revision)") {
            if primaryAsset.mediaKind == .audio { return }
            if primaryAsset.mediaKind == .document {
                let ext = (primaryAsset.fileName as NSString).pathExtension.lowercased()
                let hasRealPagePoster = (ext == "pdf" || MediaPipeline.isRichLayoutDocumentExtension(ext))
                    && !(primaryAsset.pixelWidth == 900 && primaryAsset.pixelHeight == 1_240)
                guard hasRealPagePoster else { return }
            }
            if store.thumbnails.cachedImage(for: primaryAsset.id, tier: .grid520) != nil { return }
            thumbImage = await store.thumbnails.loadImage(for: primaryAsset.id, tier: .grid520)
        }
    }

    // MARK: - Quiet Version Trigger Badge + Anchored Vertical Timeline Popover

    private var versionTriggerBadge: some View {
        let warn = MobileTheme.warning(for: colorScheme)
        let popoverBinding = Binding<Bool>(
            get: { popoverAnchorAssetID == asset.id },
            set: { next in
                if next {
                    popoverAnchorAssetID = asset.id
                } else if popoverAnchorAssetID == asset.id {
                    popoverAnchorAssetID = nil
                }
            }
        )

        return Button {
            MobileHaptics.selection()
            popoverAnchorAssetID = (popoverAnchorAssetID == asset.id) ? nil : asset.id
        } label: {
            HStack(spacing: 3.5) {
                Image(systemName: "square.stack.3d.up")
                    .font(.system(size: 9.5, weight: .semibold))
                    .foregroundStyle(MobileTheme.secondaryInk(for: colorScheme))

                Text("v\(primaryVersionNumber) · \(siblings.count)")
                    .font(.system(size: 11.5, weight: .medium).monospacedDigit())
                    .foregroundStyle(.primary)

                if pendingNewerCount > 0 {
                    Circle()
                        .fill(warn)
                        .frame(width: 5, height: 5)
                }

                Image(systemName: "chevron.down")
                    .font(.system(size: 7.5, weight: .bold))
                    .foregroundStyle(MobileTheme.tertiaryInk(for: colorScheme))
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(
                isPopoverOpen
                    ? Color.primary.opacity(0.11)
                    : Color.primary.opacity(isBadgeHovered ? 0.09 : 0.055),
                in: Capsule()
            )
        }
        .buttonStyle(.plain)
        .onHover { hovering in
            isBadgeHovered = hovering
        }
        .popover(isPresented: popoverBinding, arrowEdge: .top) {
            MobileVersionTimelinePopover(
                store: store,
                siblings: siblings,
                primaryAsset: primaryAsset,
                defaultComparePair: defaultComparePair,
                onSelectVersion: { ver in
                    popoverAnchorAssetID = nil
                    store.selectedAssetID = ver.id
                    onOpenAsset(ver)
                },
                onOpenDiffPair: { targetVer, baseID, targetID in
                    popoverAnchorAssetID = nil
                    onOpenDiff(targetVer, baseID, targetID)
                },
                onPinPrimary: { ver in
                    MobileHaptics.success()
                    Task { await store.setPrimaryVersion(assetID: ver.id) }
                }
            )
            .frame(minWidth: 292, maxWidth: 320)
            .presentationCompactAdaptation(.popover)
        }
    }

    // MARK: - Concise Spec Lines (No Boilerplate / No Editor Suffixes)

    private var conciseSpecLine: String {
        switch primaryAsset.mediaKind {
        case .document:
            let ext = (primaryAsset.fileName as NSString).pathExtension
            let family = primaryAsset.richMetadata?.document?.parsedFormatFamily ?? DocumentFormatFamily.detect(fileExtension: ext)
            var parts: [String] = [family.badgeLabel]
            if let doc = primaryAsset.richMetadata?.document {
                if !doc.sheetNames.isEmpty {
                    parts.append("\(doc.sheetNames.count) 表")
                } else if doc.pageCount > 0 {
                    parts.append("\(doc.pageCount) 页")
                }
                if doc.wordCount > 0 && doc.sheetNames.isEmpty {
                    parts.append("\(doc.wordCount.formatted()) 字")
                } else if !doc.hasTextLayer && family == .pdf {
                    parts.append("扫描件")
                }
            } else if primaryAsset.fileSizeBytes > 0 {
                parts.append(MobileFormatters.byteCount(primaryAsset.fileSizeBytes))
            }
            return parts.joined(separator: " · ")

        case .image, .animatedImage, .designFile:
            var parts: [String] = []
            let ext = (primaryAsset.fileName as NSString).pathExtension.uppercased()
            if !ext.isEmpty { parts.append(ext) }
            if primaryAsset.pixelWidth > 0 && primaryAsset.pixelHeight > 0 {
                parts.append("\(primaryAsset.pixelWidth) × \(primaryAsset.pixelHeight)")
            } else if primaryAsset.fileSizeBytes > 0 {
                parts.append(MobileFormatters.byteCount(primaryAsset.fileSizeBytes))
            }
            return parts.isEmpty ? primaryAsset.displayTypeLabel : parts.joined(separator: " · ")

        case .video, .audio:
            var parts: [String] = []
            let ext = (primaryAsset.fileName as NSString).pathExtension.uppercased()
            if !ext.isEmpty { parts.append(ext) }
            if let dur = primaryAsset.durationSeconds, dur > 0 {
                let mins = Int(dur) / 60
                let secs = Int(dur) % 60
                parts.append(String(format: "%d:%02d", mins, secs))
            } else if primaryAsset.fileSizeBytes > 0 {
                parts.append(MobileFormatters.byteCount(primaryAsset.fileSizeBytes))
            }
            return parts.isEmpty ? primaryAsset.displayTypeLabel : parts.joined(separator: " · ")

        case .webBookmark:
            if let post = primaryAsset.richMetadata?.socialPost {
                return "\(post.platform.displayName) · \(post.displayAuthorName)"
            }
            if let repo = primaryAsset.richMetadata?.githubRepo {
                return "GitHub · ★ \(repo.stars)"
            }
            return primaryAsset.sourceDomain ?? "网页"

        case .model3D:
            let fmt = primaryAsset.richMetadata?.model3DFormat ?? (primaryAsset.fileName as NSString).pathExtension.uppercased()
            return [fmt.isEmpty ? "3D" : fmt, MobileFormatters.byteCount(primaryAsset.fileSizeBytes)].joined(separator: " · ")
        }
    }

    private var bentoSpecAndDateLine: String {
        let rel = MobileFormatters.relativeDate(primaryAsset.updatedAt)
        return "\(conciseSpecLine) · \(rel)"
    }

    // MARK: - Audio-Only Waveform Sparkbar

    private var audioWaveformSparkbar: some View {
        let peaks = audioSparkBars
        return HStack(alignment: .center, spacing: 2) {
            ForEach(0..<peaks.count, id: \.self) { idx in
                RoundedRectangle(cornerRadius: 1, style: .continuous)
                    .fill(MobileTheme.secondaryInk(for: colorScheme))
                    .frame(width: 2, height: peaks[idx])
            }
        }
        .padding(.horizontal, 5)
        .padding(.vertical, 3.5)
        .background(
            MobileTheme.surfaceSubtle(for: colorScheme),
            in: RoundedRectangle(cornerRadius: 5, style: .continuous)
        )
        .accessibilityLabel("音频波形")
    }

    private var audioSparkBars: [CGFloat] {
        if primaryAsset.waveformPeaks.count >= 10 {
            return primaryAsset.waveformPeaks.prefix(10).map { max(4, min(13, CGFloat($0) * 13)) }
        }
        return [5, 9, 7, 12, 13, 8, 11, 6, 10, 5]
    }

    // MARK: - Context Menu

    @ViewBuilder
    private var compactCardContextMenu: some View {
        Button {
            onOpenAsset(primaryAsset)
        } label: {
            Label(
                primaryAsset.isExternalWebLink ? "在浏览器打开" : (hasStack ? "打开主版本 (v\(primaryVersionNumber))" : "打开预览"),
                systemImage: primaryAsset.isExternalWebLink ? "safari" : "eye"
            )
        }

        if hasStack, siblings.count >= 2 {
            let pair = defaultComparePair
            Button {
                onOpenDiff(primaryAsset, pair.baseID, pair.targetID)
            } label: {
                Label("对比差异", systemImage: "arrow.left.arrow.right")
            }
        }

        Divider()

        Button {
            onSharePrimary(primaryAsset)
        } label: {
            Label(
                hasStack ? "分享主版本" : "分享原文件",
                systemImage: "square.and.arrow.up"
            )
        }

        Button {
            Task { await store.copyAssetToPasteboard(primaryAsset) }
        } label: {
            Label(hasStack ? "拷贝主版本" : "拷贝", systemImage: "doc.on.doc")
        }

        Divider()

        if hasStack {
            Menu {
                ForEach(Array(siblings.enumerated()).reversed(), id: \.element.id) { idx, member in
                    let v = member.richMetadata?.versionStack?.versionNumber ?? (idx + 1)
                    let isPrimary = member.id == primaryAsset.id
                    let verMeta = member.richMetadata?.versionStack
                    let desc = MobileVersionDisplayFormatting.cleanDescriptor(
                        changeNote: verMeta?.changeNote,
                        versionLabel: verMeta?.versionLabel,
                        editorName: verMeta?.editorName
                    )
                    Button {
                        Task { await store.setPrimaryVersion(assetID: member.id) }
                    } label: {
                        Label(
                            "v\(v)" + (desc.map { " · \($0)" } ?? "") + (isPrimary ? "（当前主版）" : ""),
                            systemImage: isPrimary ? "pin.fill" : "pin"
                        )
                    }
                }
            } label: {
                Label("切换主版本…", systemImage: "pin")
            }

            Button {
                onRequestMergeStack(primaryAsset)
            } label: {
                Label("归入历史版本…", systemImage: "arrow.triangle.merge")
            }

            Button {
                Task { await store.unstackAsset(assetID: primaryAsset.id) }
            } label: {
                Label("拆分为独立素材", systemImage: "square.stack.3d.up.slash")
            }
        } else {
            Button {
                onRequestMergeStack(primaryAsset)
            } label: {
                Label("合并版本…", systemImage: "square.stack.3d.up")
            }
        }

        Divider()

        Button {
            onRequestMoveFolder(primaryAsset)
        } label: {
            Label("移动到文件夹…", systemImage: "folder")
        }

        Button {
            onFindSimilar(primaryAsset)
        } label: {
            Label("查找相似素材", systemImage: "sparkle.magnifyingglass")
        }

        Button {
            store.isMultiSelectMode = true
            store.selectedAssetIDs.insert(asset.id)
        } label: {
            Label("多选批处理", systemImage: "checkmark.circle")
        }

        Divider()

        if primaryAsset.isTrashed {
            Button {
                Task {
                    await store.patchAssets(
                        AssetBatchPatch(assetIDs: [primaryAsset.id], isTrashed: false),
                        successToast: "已恢复素材"
                    )
                }
            } label: {
                Label("从回收站恢复", systemImage: "arrow.uturn.backward")
            }
            Button(role: .destructive) {
                onRequestPermanentDelete(primaryAsset.id)
            } label: {
                Label("彻底删除", systemImage: "trash.slash")
            }
        } else {
            Button(role: .destructive) {
                let ids = siblings.map(\.id)
                Task {
                    await store.patchAssets(
                        AssetBatchPatch(assetIDs: ids, isTrashed: true),
                        successToast: "已移入回收站",
                        actionTitle: "撤销",
                        onAction: {
                            Task {
                                await store.patchAssets(
                                    AssetBatchPatch(assetIDs: ids, isTrashed: false),
                                    successToast: "已撤销移入回收站"
                                )
                            }
                        }
                    )
                }
            } label: {
                Label(hasStack ? "移入回收站（全部版本）" : "移入回收站", systemImage: "trash")
            }
        }
    }
}

// MARK: - Universal Vertical Version History Popover (`MobileVersionTimelinePopover`)

private struct MobileVersionTimelinePopover: View {
    @Bindable var store: MobileAppStore
    let siblings: [AssetRecord]
    let primaryAsset: AssetRecord
    let defaultComparePair: (baseID: UUID, targetID: UUID)
    let onSelectVersion: (AssetRecord) -> Void
    let onOpenDiffPair: (AssetRecord, UUID, UUID) -> Void
    let onPinPrimary: (AssetRecord) -> Void

    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    private var primaryVersionNumber: Int {
        primaryAsset.richMetadata?.versionStack?.versionNumber ?? siblings.count
    }

    var body: some View {
        let accent = MobileTheme.accent(for: colorScheme)
        let pos = MobileTheme.positive(for: colorScheme)
        let warn = MobileTheme.warning(for: colorScheme)
        let danger = MobileTheme.destructive(for: colorScheme)
        let reversedItems = Array(siblings.enumerated().reversed())

        VStack(alignment: .leading, spacing: 0) {
            // Header
            HStack(spacing: 6) {
                Text("历史版本")
                    .font(.system(size: 12.5, weight: .semibold))
                    .foregroundStyle(.primary)

                Text("\(siblings.count)")
                    .font(.system(size: 12, weight: .medium).monospacedDigit())
                    .foregroundStyle(MobileTheme.tertiaryInk(for: colorScheme))

                Spacer()

                if siblings.count >= 2 {
                    Button {
                        MobileHaptics.light()
                        onOpenDiffPair(primaryAsset, defaultComparePair.baseID, defaultComparePair.targetID)
                    } label: {
                        HStack(spacing: 4) {
                            Image(systemName: "arrow.left.arrow.right")
                                .font(.system(size: 10.5, weight: .semibold))
                            Text("对比差异")
                                .font(.system(size: 11.5, weight: .semibold))
                        }
                        .foregroundStyle(.primary)
                        .padding(.horizontal, 8.5)
                        .padding(.vertical, 4)
                        .background(Color.primary.opacity(0.06), in: Capsule())
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 14)
            .padding(.top, 12)
            .padding(.bottom, 9)

            Rectangle()
                .fill(MobileTheme.hairline(for: colorScheme))
                .frame(height: 0.5)

            // Newest-First Vertical Timeline (`vN → v1`)
            ScrollView {
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(Array(reversedItems.enumerated()), id: \.element.element.id) { displayIdx, entry in
                        let ascIndex = entry.offset
                        let member = entry.element
                        let verMeta = member.richMetadata?.versionStack
                        let vNum = verMeta?.versionNumber ?? (ascIndex + 1)
                        let isPrimary = member.id == primaryAsset.id
                        let isUnreviewed = vNum > primaryVersionNumber
                        let prevMember: AssetRecord? = ascIndex > 0 ? siblings[ascIndex - 1] : nil
                        let descriptor = MobileVersionDisplayFormatting.cleanDescriptor(
                            changeNote: verMeta?.changeNote,
                            versionLabel: verMeta?.versionLabel,
                            editorName: verMeta?.editorName
                        )
                        let cleanEditor = MobileVersionDisplayFormatting.cleanEditor(
                            verMeta?.editorName,
                            excluding: descriptor
                        )
                        let diffSummary = member.richMetadata?.document?.diffSummary
                        let changedBlocks = diffSummary?.totalChangedBlocks ?? 0
                        let hasHighRisk = (diffSummary?.totalHighRiskChanges ?? 0) > 0

                        HStack(alignment: .center, spacing: 8) {
                            // Vertical Spine + Node
                            GeometryReader { geo in
                                let midX = geo.size.width * 0.5
                                let midY = geo.size.height * 0.5
                                ZStack {
                                    if displayIdx > 0 {
                                        Path { p in
                                            p.move(to: CGPoint(x: midX, y: 0))
                                            p.addLine(to: CGPoint(x: midX, y: midY))
                                        }
                                        .stroke(MobileTheme.hairline(for: colorScheme), lineWidth: 1)
                                    }
                                    if displayIdx < reversedItems.count - 1 {
                                        Path { p in
                                            p.move(to: CGPoint(x: midX, y: midY))
                                            p.addLine(to: CGPoint(x: midX, y: geo.size.height))
                                        }
                                        .stroke(MobileTheme.hairline(for: colorScheme), lineWidth: 1)
                                    }

                                    if isPrimary {
                                        Circle()
                                            .fill(accent)
                                            .frame(width: 8, height: 8)
                                            .position(x: midX, y: midY)
                                    } else {
                                        Circle()
                                            .fill(MobileTheme.surfaceElevated(for: colorScheme))
                                            .frame(width: 8, height: 8)
                                            .overlay(
                                                Circle().strokeBorder(
                                                    isUnreviewed ? warn : MobileTheme.secondaryInk(for: colorScheme).opacity(0.50),
                                                    lineWidth: 1.5
                                                )
                                            )
                                            .position(x: midX, y: midY)
                                    }
                                }
                            }
                            .frame(width: 18)

                            // Timeline Row Content
                            HStack(spacing: 6) {
                                Button {
                                    MobileHaptics.light()
                                    onSelectVersion(member)
                                } label: {
                                    VStack(alignment: .leading, spacing: 2) {
                                        HStack(spacing: 5) {
                                            Text("v\(vNum)")
                                                .font(.system(size: 12.5, weight: .semibold).monospacedDigit())
                                                .foregroundStyle(.primary)

                                            if let descriptor {
                                                Text(descriptor)
                                                    .font(.system(size: 12, weight: .regular))
                                                    .foregroundStyle(MobileTheme.secondaryInk(for: colorScheme))
                                                    .lineLimit(1)
                                            }

                                            if isPrimary {
                                                Text("主版")
                                                    .font(.system(size: 10, weight: .semibold))
                                                    .foregroundStyle(pos)
                                                    .padding(.horizontal, 5)
                                                    .padding(.vertical, 1)
                                                    .background(pos.opacity(0.14), in: RoundedRectangle(cornerRadius: 4, style: .continuous))
                                            }
                                        }

                                        HStack(spacing: 4) {
                                            Text(MobileFormatters.relativeDate(member.updatedAt))
                                                .font(.system(size: 11).monospacedDigit())
                                                .foregroundStyle(MobileTheme.tertiaryInk(for: colorScheme))

                                            if let cleanEditor {
                                                Text("· \(cleanEditor)")
                                                    .font(.system(size: 11))
                                                    .foregroundStyle(MobileTheme.secondaryInk(for: colorScheme))
                                                    .lineLimit(1)
                                            }
                                        }
                                    }
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .contentShape(Rectangle())
                                }
                                .buttonStyle(.plain)

                                if let prevMember, changedBlocks > 0 {
                                    Button {
                                        MobileHaptics.light()
                                        onOpenDiffPair(member, prevMember.id, member.id)
                                    } label: {
                                        Text("Δ \(changedBlocks)")
                                            .font(.system(size: 11, weight: .semibold).monospacedDigit())
                                            .foregroundStyle(hasHighRisk ? danger : MobileTheme.secondaryInk(for: colorScheme))
                                            .padding(.horizontal, 6.5)
                                            .padding(.vertical, 3)
                                            .background(
                                                hasHighRisk ? danger.opacity(0.12) : MobileTheme.surfaceSubtle(for: colorScheme),
                                                in: Capsule()
                                            )
                                    }
                                    .buttonStyle(.plain)
                                    .accessibilityLabel("对比 v\(prevMember.richMetadata?.versionStack?.versionNumber ?? ascIndex) 与 v\(vNum)")
                                }

                                if !isPrimary {
                                    Button {
                                        onPinPrimary(member)
                                    } label: {
                                        Image(systemName: "pin")
                                            .font(.system(size: 11, weight: .semibold))
                                            .foregroundStyle(MobileTheme.secondaryInk(for: colorScheme))
                                            .frame(width: 24, height: 24)
                                            .background(MobileTheme.surfaceSubtle(for: colorScheme), in: Circle())
                                    }
                                    .buttonStyle(.plain)
                                    .accessibilityLabel("设为主版本")
                                }
                            }
                            .padding(.horizontal, 9)
                            .padding(.vertical, 6.5)
                            .background(
                                isPrimary ? MobileTheme.accentSoft(for: colorScheme) : .clear,
                                in: RoundedRectangle(cornerRadius: 8, style: .continuous)
                            )
                        }
                    }
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 8)
            }
            .scrollBounceBehavior(.basedOnSize)
            .frame(maxHeight: 280)
        }
        .background {
            if reduceTransparency {
                MobileTheme.surfaceElevated(for: colorScheme)
            } else {
                Rectangle().fill(.ultraThinMaterial)
            }
        }
    }
}

// MARK: - Tracklist Squircle Artwork / Page Cover (`36×46` docs / `38×44` media)

private struct CompactMiniatureSheetThumb: View {
    let asset: AssetRecord
    let thumbnail: UIImage?
    let hasStack: Bool
    let isFannedOpen: Bool
    let size: CGSize

    @Environment(\.colorScheme) private var colorScheme

    private var paperSurface: Color {
        MobileTheme.surfaceElevated(for: colorScheme)
    }

    private var extText: String {
        let ext = (asset.fileName as NSString).pathExtension.uppercased()
        if !ext.isEmpty { return String(ext.prefix(4)) }
        switch asset.mediaKind {
        case .document: return "DOC"
        case .audio: return "M4A"
        case .video: return "MP4"
        case .webBookmark: return "WEB"
        case .model3D: return "3D"
        default: return "IMG"
        }
    }

    var body: some View {
        let sheetShape = RoundedRectangle(cornerRadius: 6, style: .continuous)

        ZStack {
            if hasStack {
                sheetShape
                    .fill(MobileTheme.surfaceSubtle(for: colorScheme))
                    .overlay(
                        sheetShape.strokeBorder(Color.primary.opacity(0.08), lineWidth: 0.5)
                    )
                    .padding(1)
                    .offset(x: isFannedOpen ? 3.5 : 2.5, y: isFannedOpen ? -2.5 : -1.5)
                    .rotationEffect(.degrees(isFannedOpen ? 4 : 0), anchor: .bottomLeading)
            }

            frontContent
                .clipShape(sheetShape)
                .overlay(
                    sheetShape.strokeBorder(Color.primary.opacity(0.08), lineWidth: 0.5)
                )
                .shadow(
                    color: .black.opacity(colorScheme == .dark ? 0.28 : 0.08),
                    radius: 3,
                    y: 1.5
                )
                .padding(1)
        }
        .frame(width: size.width, height: size.height)
        .animation(.spring(duration: 0.24, bounce: 0.10), value: isFannedOpen)
    }

    @ViewBuilder
    private var frontContent: some View {
        switch asset.mediaKind {
        case .document:
            let lowerExt = (asset.fileName as NSString).pathExtension.lowercased()
            let hasRealPagePoster = (lowerExt == "pdf" || MediaPipeline.isRichLayoutDocumentExtension(lowerExt))
                && !(asset.pixelWidth == 900 && asset.pixelHeight == 1_240)
            if hasRealPagePoster, let thumbnail {
                Image(uiImage: thumbnail)
                    .resizable()
                    .scaledToFill()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .clipped()
                    .background(paperSurface)
            } else {
                minimalPaperCover
            }

        case .audio:
            let bars: [CGFloat] = [4, 9, 6, 12, 10, 5]
            VStack(spacing: 3) {
                Spacer(minLength: 0)
                HStack(alignment: .center, spacing: 1.5) {
                    ForEach(0..<bars.count, id: \.self) { idx in
                        Capsule()
                            .fill(MobileTheme.secondaryInk(for: colorScheme))
                            .frame(width: 1.75, height: bars[idx])
                    }
                }
                Spacer(minLength: 0)
                Text(extText)
                    .font(.system(size: 7.5, weight: .semibold, design: .monospaced))
                    .foregroundStyle(MobileTheme.tertiaryInk(for: colorScheme))
                    .lineLimit(1)
            }
            .padding(3)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(paperSurface)

        default:
            if let thumbnail {
                Image(uiImage: thumbnail)
                    .resizable()
                    .scaledToFill()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .clipped()
                    .background(paperSurface)
            } else {
                let firstHex = asset.dominantColors.first?.hex
                ZStack {
                    (firstHex.map { Color(charkleHex: $0).opacity(0.22) } ?? MobileTheme.surfaceSubtle(for: colorScheme))
                    Image(systemName: MobileTheme.mediaKindSymbol(for: asset.mediaKind))
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(MobileTheme.secondaryInk(for: colorScheme))
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
    }

    /// Clean minimal paper rectangle with subtle format label — zero cartoon red/blue skeleton lines.
    private var minimalPaperCover: some View {
        VStack(spacing: 0) {
            Spacer(minLength: 0)
            Text(extText)
                .font(.system(size: 8.5, weight: .semibold, design: .monospaced))
                .foregroundStyle(MobileTheme.secondaryInk(for: colorScheme))
                .lineLimit(1)
                .minimumScaleFactor(0.7)
                .padding(.bottom, 5)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(paperSurface)
    }
}
