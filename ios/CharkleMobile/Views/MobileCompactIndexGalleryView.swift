import CharkleCore
import SwiftUI
import UIKit
import UniformTypeIdentifiers

// MARK: - 5th Universal Gallery Mode: Tactile Studio Compact View (iOS 1-Col Folio / iPad 2-Col Bento)

/// Native iOS & iPadOS implementation of `GalleryLayoutMode.compactList` (`紧凑视图`):
/// - Adaptive 1-column Folio Strip on iPhone compact width; toggleable 2-column Bento Index Grid ⇄ 1-column Strip on iPad regular width.
/// - 3D Micro-Folio layered stack artwork (pointer-hover fan-out on iPad, pure transform, Reduce Motion safe).
/// - 12-Segment Diff Minimap on versioned documents + `.monospacedDigit()` timestamps.
/// - Tap-to-expand inline horizontal Revision Rail (`v3` ── `Δ 6处 · ¥1` ── `v4 主版` ── `Δ 3处 · ¥2` ── `v5`)
///   with 1-tap `设为主版` (`isPinnedPrimary`) and 1-tap `Δ` bridge to launch Document Diff!
struct MobileCompactIndexGalleryView: View {
    private enum QuickCategoryFilter: String, CaseIterable, Identifiable {
        case all = "全部"
        case documents = "文档叠"
        case visualAndAudio = "视觉·音视频"

        var id: String { rawValue }
    }

    private enum CompactGridRow: Identifiable {
        case single(AssetRecord)
        case pair(AssetRecord, AssetRecord)

        var id: String {
            switch self {
            case .single(let a):
                return "single:\(a.id.uuidString)"
            case .pair(let a, let b):
                return "pair:\(a.id.uuidString):\(b.id.uuidString)"
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
    @State private var expandedStackGroupID: UUID? = nil

    private var documentCount: Int {
        displayedAssets.filter { $0.mediaKind == .document }.count
    }

    private var mediaCount: Int {
        displayedAssets.count - documentCount
    }

    private var filteredItems: [AssetRecord] {
        switch quickCategory {
        case .all:
            return displayedAssets
        case .documents:
            return displayedAssets.filter { $0.mediaKind == .document }
        case .visualAndAudio:
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

    private func buildRows(items: [AssetRecord], columns: Int) -> [CompactGridRow] {
        guard columns == 2 else {
            return items.map { .single($0) }
        }
        var rows: [CompactGridRow] = []
        rows.reserveCapacity((items.count + 1) / 2)
        var pendingLeft: AssetRecord? = nil

        for item in items {
            let siblings = store.stackMembers(for: item)
            let isExpanded = siblings.count > 1
                && item.richMetadata?.versionStack?.groupID != nil
                && item.richMetadata?.versionStack?.groupID == expandedStackGroupID

            if isExpanded {
                if let left = pendingLeft {
                    rows.append(.single(left))
                    pendingLeft = nil
                }
                rows.append(.single(item))
            } else if let left = pendingLeft {
                rows.append(.pair(left, item))
                pendingLeft = nil
            } else {
                pendingLeft = item
            }
        }
        if let leftover = pendingLeft {
            rows.append(.single(leftover))
        }
        return rows
    }

    var body: some View {
        GeometryReader { proxy in
            let columns = resolvedColumnCount(for: proxy.size.width)
            let rows = buildRows(items: filteredItems, columns: columns)
            let horizontalPad: CGFloat = isCompact ? 12 : 18

            ScrollView {
                LazyVStack(alignment: .leading, spacing: 10) {
                    Color.clear
                        .frame(height: max(0, topInset - 6))

                    if store.syncStatus.isSyncing, let fraction = store.syncStatus.progressFraction {
                        compactSyncBanner(fraction: fraction)
                    }

                    studioSubToolbar(columns: columns, canToggleBento: !isCompact && proxy.size.width >= 620)

                    if rows.isEmpty {
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
                    } else {
                        ForEach(rows) { row in
                            switch row {
                            case .single(let item):
                                CompactFolioIndexCard(
                                    store: store,
                                    asset: item,
                                    isCompactWidth: isCompact,
                                    expandedStackGroupID: $expandedStackGroupID,
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
                            case .pair(let left, let right):
                                HStack(alignment: .top, spacing: 10) {
                                    CompactFolioIndexCard(
                                        store: store,
                                        asset: left,
                                        isCompactWidth: false,
                                        expandedStackGroupID: $expandedStackGroupID,
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

                                    CompactFolioIndexCard(
                                        store: store,
                                        asset: right,
                                        isCompactWidth: false,
                                        expandedStackGroupID: $expandedStackGroupID,
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

    private func studioSubToolbar(columns: Int, canToggleBento: Bool) -> some View {
        HStack(spacing: 8) {
            // Quick category pills matching compact_view_preview.html
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 4) {
                    categoryPill(.all, count: displayedAssets.count)
                    if documentCount > 0 {
                        categoryPill(.documents, count: documentCount)
                    }
                    if mediaCount > 0 && documentCount > 0 {
                        categoryPill(.visualAndAudio, count: mediaCount)
                    }
                }
                .padding(3)
                .background(MobileTheme.surfaceSubtle(for: colorScheme), in: Capsule())
            }

            Spacer(minLength: 4)

            if canToggleBento {
                HStack(spacing: 2) {
                    bentoToggleButton(title: "双列索引卡", icon: "rectangle.grid.2x2", active: columns == 2) {
                        withAnimation(MobileMotion.accessible(MobileMotion.settleStrong, reduced: reduceMotion)) {
                            store.setCompactBentoColumnOverride(2)
                        }
                    }
                    bentoToggleButton(title: "单列折页条", icon: "rectangle.grid.1x2", active: columns == 1) {
                        withAnimation(MobileMotion.accessible(MobileMotion.settleStrong, reduced: reduceMotion)) {
                            store.setCompactBentoColumnOverride(1)
                        }
                    }
                }
                .padding(3)
                .background(
                    MobileTheme.surfaceSubtle(for: colorScheme),
                    in: RoundedRectangle(cornerRadius: 9, style: .continuous)
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
            Text("\(cat.rawValue) \(count)")
                .font(.system(size: 12, weight: isOn ? .semibold : .medium).monospacedDigit())
                .foregroundStyle(isOn ? .primary : MobileTheme.secondaryInk(for: colorScheme))
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                .background(
                    isOn ? MobileTheme.surfaceElevated(for: colorScheme) : .clear,
                    in: Capsule()
                )
        }
        .buttonStyle(.plain)
    }

    private func bentoToggleButton(title: String, icon: String, active: Bool, action: @escaping () -> Void) -> some View {
        Button(action: {
            MobileHaptics.light()
            action()
        }) {
            HStack(spacing: 4) {
                Image(systemName: icon)
                    .font(.system(size: 11, weight: .semibold))
                Text(title)
                    .font(.system(size: 11.5, weight: active ? .semibold : .medium))
            }
            .foregroundStyle(active ? .primary : MobileTheme.secondaryInk(for: colorScheme))
            .padding(.horizontal, 8)
            .padding(.vertical, 4.5)
            .background(
                active ? MobileTheme.surfaceElevated(for: colorScheme) : .clear,
                in: RoundedRectangle(cornerRadius: 6, style: .continuous)
            )
        }
        .buttonStyle(.plain)
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
                .strokeBorder(MobileTheme.hairline(for: colorScheme), lineWidth: 0.75)
        )
    }
}

// MARK: - Tactile Studio Folio Card + 3D Micro-Folio + 12-Seg Minimap + Inline Revision Rail

private struct CompactFolioIndexCard: View {
    @Bindable var store: MobileAppStore
    let asset: AssetRecord
    let isCompactWidth: Bool
    @Binding var expandedStackGroupID: UUID?
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

    private var isRailExpanded: Bool {
        guard hasStack, let gid = stackGroupID else { return false }
        return expandedStackGroupID == gid
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

    private var latestDiffSummary: DocumentDiffSummary? {
        if let latestDocDiff = siblings.last?.richMetadata?.document?.diffSummary,
           latestDocDiff.totalChangedBlocks > 0 {
            return latestDocDiff
        }
        return primaryAsset.richMetadata?.document?.diffSummary
    }

    var body: some View {
        let accent = MobileTheme.accent(for: colorScheme)
        let cardShape = RoundedRectangle(cornerRadius: MobileTheme.Radius.cardOuter, style: .continuous)

        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .center, spacing: 11) {
                if store.isMultiSelectMode {
                    Image(systemName: store.selectedAssetIDs.contains(asset.id) ? "checkmark.circle.fill" : "circle")
                        .font(.system(size: 19, weight: .semibold))
                        .foregroundStyle(store.selectedAssetIDs.contains(asset.id) ? accent : MobileTheme.tertiaryInk(for: colorScheme))
                }

                // 1. 3D Micro-Folio Artifact Stage (44 x 52pt)
                MicroFolioArtifactStage(
                    asset: primaryAsset,
                    thumbnail: store.thumbnails.cachedImage(for: primaryAsset.id, tier: .grid520) ?? thumbImage,
                    hasStack: hasStack,
                    isFannedOpen: (isHovered || isRailExpanded) && !reduceMotion
                )

                // 2. Primary Title + Stack Pill + Adaptive Media Feature Line
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 6) {
                        Text(primaryAsset.title)
                            .font(.system(size: 13.5, weight: .semibold))
                            .foregroundStyle(.primary)
                            .lineLimit(1)
                            .layoutPriority(1)

                        if hasStack {
                            stackToggleCapsule
                        }
                    }

                    HStack(spacing: 6) {
                        Text(adaptiveFeatureLine)
                            .font(.system(size: 11.5).monospacedDigit())
                            .foregroundStyle(MobileTheme.secondaryInk(for: colorScheme))
                            .lineLimit(1)

                        ForEach(primaryAsset.tags.prefix(isCompactWidth ? 1 : 2), id: \.self) { tag in
                            Text("#\(tag)")
                                .font(.system(size: 10.5, weight: .medium))
                                .foregroundStyle(MobileTheme.tertiaryInk(for: colorScheme))
                                .lineLimit(1)
                                .padding(.horizontal, 5.5)
                                .padding(.vertical, 1.5)
                                .background(
                                    MobileTheme.surfaceSubtle(for: colorScheme),
                                    in: RoundedRectangle(cornerRadius: 4, style: .continuous)
                                )
                        }

                        let hiddenTagCount = primaryAsset.tags.count - (isCompactWidth ? 1 : 2)
                        if hiddenTagCount > 0 {
                            Text("+\(hiddenTagCount)")
                                .font(.system(size: 10, weight: .semibold).monospacedDigit())
                                .foregroundStyle(MobileTheme.tertiaryInk(for: colorScheme))
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                // 3. Right Trailing: Quick Share/Copy (on hover/iPad) + 12-Segment Diff Minimap / Sparkbar + Timestamp
                HStack(spacing: 8) {
                    if !isCompactWidth && isHovered && !store.isMultiSelectMode {
                        Button {
                            MobileHaptics.light()
                            onSharePrimary(primaryAsset)
                        } label: {
                            Label("发主版", systemImage: "square.and.arrow.up")
                                .font(.system(size: 11, weight: .semibold))
                                .foregroundStyle(.primary)
                                .padding(.horizontal, 8)
                                .padding(.vertical, 5)
                                .background(
                                    MobileTheme.surfaceElevated(for: colorScheme),
                                    in: RoundedRectangle(cornerRadius: 7, style: .continuous)
                                )
                                .overlay(
                                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                                        .strokeBorder(MobileTheme.borderStrong(for: colorScheme), lineWidth: 0.75)
                                )
                        }
                        .buttonStyle(MobileTactileButtonStyle())
                        .transition(.opacity)
                    }

                    trailingSpectrumAndTimestamp
                }
            }

            // 4. Inline Expandable Horizontal Revision Rail
            if isRailExpanded {
                inlineRevisionRail
                    .padding(.top, 10)
                    .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .padding(10)
        .background(
            MobileTheme.surfaceElevated(for: colorScheme),
            in: cardShape
        )
        .overlay(
            cardShape.strokeBorder(
                isDropTargeted
                    ? accent
                    : (isSelected ? accent.opacity(0.65) : (isHovered ? MobileTheme.borderStrong(for: colorScheme) : MobileTheme.hairline(for: colorScheme))),
                lineWidth: isDropTargeted ? 2.0 : (isSelected ? 1.5 : 0.75)
            )
        )
        .shadow(
            color: .black.opacity(colorScheme == .dark ? 0.22 : 0.035),
            radius: 6,
            y: 2
        )
        .contentShape(cardShape)
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
            }
        }
        .matchedTransitionSource(
            id: PreviewZoomSourceID(origin: zoomOrigin, assetID: primaryAsset.id),
            in: zoomNamespace
        ) { configuration in
            configuration.clipShape(cardShape)
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
            guard primaryAsset.mediaKind != .document && primaryAsset.mediaKind != .audio else { return }
            if store.thumbnails.cachedImage(for: primaryAsset.id, tier: .grid520) != nil { return }
            thumbImage = await store.thumbnails.loadImage(for: primaryAsset.id, tier: .grid520)
        }
    }

    // MARK: - Stack Capsule Button

    private var stackToggleCapsule: some View {
        let accent = MobileTheme.accent(for: colorScheme)
        let warn = MobileTheme.warning(for: colorScheme)

        return Button {
            guard let gid = stackGroupID else { return }
            MobileHaptics.selection()
            withAnimation(MobileMotion.accessible(MobileMotion.settleStrong, reduced: reduceMotion)) {
                expandedStackGroupID = (expandedStackGroupID == gid) ? nil : gid
            }
        } label: {
            HStack(spacing: 4) {
                Text("主版 v\(primaryVersionNumber)")
                    .font(.system(size: 11, weight: .semibold).monospacedDigit())

                if pendingNewerCount > 0 {
                    Text("+\(pendingNewerCount) 新版")
                        .font(.system(size: 10, weight: .bold).monospacedDigit())
                        .foregroundStyle(isRailExpanded ? .white : warn)
                        .padding(.horizontal, 5)
                        .padding(.vertical, 1)
                        .background(
                            isRailExpanded ? Color.white.opacity(0.22) : warn.opacity(0.16),
                            in: Capsule()
                        )
                } else {
                    Text("· 共\(siblings.count)版")
                        .font(.system(size: 10.5, weight: .medium).monospacedDigit())
                        .opacity(0.78)
                }

                Image(systemName: isRailExpanded ? "chevron.up" : "chevron.down")
                    .font(.system(size: 8.5, weight: .bold))
            }
            .foregroundStyle(isRailExpanded ? .white : accent)
            .padding(.horizontal, 8)
            .padding(.vertical, 3.5)
            .background(
                isRailExpanded ? accent : MobileTheme.accentSoft(for: colorScheme),
                in: Capsule()
            )
        }
        .buttonStyle(MobileTactileButtonStyle())
    }

    // MARK: - Media-Adaptive Feature Subtitle

    private var adaptiveFeatureLine: String {
        switch primaryAsset.mediaKind {
        case .document:
            let ext = (primaryAsset.fileName as NSString).pathExtension
            let family = primaryAsset.richMetadata?.document?.parsedFormatFamily ?? DocumentFormatFamily.detect(fileExtension: ext)
            var parts: [String] = [family.badgeLabel]
            if let doc = primaryAsset.richMetadata?.document {
                if !doc.sheetNames.isEmpty {
                    parts.append("\(doc.sheetNames.count) 工作表")
                } else if doc.pageCount > 0 {
                    parts.append("\(doc.pageCount) 页")
                }
                if doc.wordCount > 0 && doc.sheetNames.isEmpty {
                    parts.append("\(doc.wordCount) 字")
                }
                if !doc.hasTextLayer && family == .pdf {
                    parts.append("扫描签批")
                }
            } else if primaryAsset.fileSizeBytes > 0 {
                parts.append(MobileFormatters.byteCount(primaryAsset.fileSizeBytes))
            }
            if let editor = primaryAsset.richMetadata?.versionStack?.editorName, !editor.isEmpty {
                parts.append("\(editor)核定")
            }
            return parts.joined(separator: " · ")

        case .image, .animatedImage, .designFile:
            var parts: [String] = []
            let ext = (primaryAsset.fileName as NSString).pathExtension.uppercased()
            if !ext.isEmpty { parts.append(ext) }
            if primaryAsset.pixelWidth > 0 && primaryAsset.pixelHeight > 0 {
                parts.append("\(primaryAsset.pixelWidth) × \(primaryAsset.pixelHeight)")
            }
            if primaryAsset.fileSizeBytes > 0 {
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
            }
            if primaryAsset.fileSizeBytes > 0 {
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
            return primaryAsset.sourceDomain ?? "网页收藏"

        case .model3D:
            let fmt = primaryAsset.richMetadata?.model3DFormat ?? (primaryAsset.fileName as NSString).pathExtension.uppercased()
            return [fmt.isEmpty ? "3D" : fmt, MobileFormatters.byteCount(primaryAsset.fileSizeBytes)].joined(separator: " · ")
        }
    }

    // MARK: - 12-Segment Diff Minimap & Waveform Sparkbar

    @ViewBuilder
    private var trailingSpectrumAndTimestamp: some View {
        VStack(alignment: .trailing, spacing: 4) {
            if let diff = latestDiffSummary {
                let buckets = DocumentDiffSummary.normalizeBuckets(diff.minimapBuckets)
                HStack(alignment: .center, spacing: 2) {
                    ForEach(0..<buckets.count, id: \.self) { idx in
                        let level = buckets[idx]
                        RoundedRectangle(cornerRadius: 1.5, style: .continuous)
                            .fill(minimapColor(for: level))
                            .frame(width: 3, height: minimapBarHeight(for: level))
                    }
                }
                .padding(.horizontal, 6)
                .padding(.vertical, 4)
                .background(
                    MobileTheme.surfaceSubtle(for: colorScheme),
                    in: RoundedRectangle(cornerRadius: 6, style: .continuous)
                )
                .accessibilityLabel("全文 12 段改动分布微缩谱")
            } else if primaryAsset.mediaKind == .audio {
                let peaks = audioSparkBars
                HStack(alignment: .center, spacing: 2) {
                    ForEach(0..<peaks.count, id: \.self) { idx in
                        RoundedRectangle(cornerRadius: 1.25, style: .continuous)
                            .fill(MobileTheme.secondaryInk(for: colorScheme))
                            .frame(width: 2.5, height: peaks[idx])
                    }
                }
                .padding(.horizontal, 6)
                .padding(.vertical, 4)
                .background(
                    MobileTheme.surfaceSubtle(for: colorScheme),
                    in: RoundedRectangle(cornerRadius: 6, style: .continuous)
                )
            } else if primaryAsset.rating > 0 {
                HStack(spacing: 2) {
                    Image(systemName: "star.fill")
                        .font(.system(size: 10))
                        .foregroundStyle(Color(charkleHex: "#E5B243"))
                    Text("\(primaryAsset.rating)")
                        .font(.system(size: 11, weight: .semibold).monospacedDigit())
                        .foregroundStyle(MobileTheme.secondaryInk(for: colorScheme))
                }
            }

            Text(MobileFormatters.relativeDate(primaryAsset.updatedAt))
                .font(.system(size: 11).monospacedDigit())
                .foregroundStyle(MobileTheme.tertiaryInk(for: colorScheme))
                .lineLimit(1)
        }
        .fixedSize(horizontal: true, vertical: false)
    }

    private func minimapColor(for level: Int) -> Color {
        switch level {
        case 2: MobileTheme.destructive(for: colorScheme)
        case 1: MobileTheme.positive(for: colorScheme)
        default: MobileTheme.borderStrong(for: colorScheme)
        }
    }

    private func minimapBarHeight(for level: Int) -> CGFloat {
        switch level {
        case 2: 14
        case 1: 11.5
        default: 7.5
        }
    }

    private var audioSparkBars: [CGFloat] {
        if primaryAsset.waveformPeaks.count >= 12 {
            return primaryAsset.waveformPeaks.prefix(12).map { max(4, min(14, CGFloat($0) * 14)) }
        }
        return [5, 10, 7, 13, 14, 8, 11, 6, 12, 9, 7, 5]
    }

    // MARK: - Inline Horizontal Revision Rail

    private var inlineRevisionRail: some View {
        let accent = MobileTheme.accent(for: colorScheme)
        let warn = MobileTheme.warning(for: colorScheme)
        let pos = MobileTheme.positive(for: colorScheme)

        return VStack(alignment: .leading, spacing: 8) {
            Divider()

            HStack(spacing: 8) {
                Text(isCompactWidth ? "点选版本锁定「主版」，点 Δ 直接对比差异" : "版本演进脉络 · 点选任意版锁定对外「主版本」，点中间 Δ 直接对比挑拣")
                    .font(.system(size: 11.5, weight: .medium))
                    .foregroundStyle(MobileTheme.secondaryInk(for: colorScheme))
                    .lineLimit(1)

                Spacer(minLength: 4)

                if siblings.count >= 2 {
                    let comparePair = defaultComparePair
                    Button {
                        MobileHaptics.light()
                        onOpenDiff(primaryAsset, comparePair.baseID, comparePair.targetID)
                    } label: {
                        Text(primaryAsset.mediaKind == .document ? "精细对比与取舍 →" : "对比两版 →")
                            .font(.system(size: 11.5, weight: .semibold))
                            .foregroundStyle(.white)
                            .padding(.horizontal, 9)
                            .padding(.vertical, 4)
                            .background(MobileTheme.accentButtonFill(for: colorScheme), in: Capsule())
                    }
                    .buttonStyle(MobileTactileButtonStyle())
                }
            }

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    ForEach(Array(siblings.enumerated()), id: \.element.id) { index, verAsset in
                        let verMeta = verAsset.richMetadata?.versionStack
                        let vNum = verMeta?.versionNumber ?? (index + 1)
                        let isPrimary = verAsset.id == primaryAsset.id
                        let isUnreviewed = vNum > primaryVersionNumber

                        if index > 0 {
                            let prevAsset = siblings[index - 1]
                            let deltaLabel = verAsset.richMetadata?.document?.diffSummary?.compactBridgeLabel ?? "Δ 对比"
                            Button {
                                MobileHaptics.light()
                                onOpenDiff(verAsset, prevAsset.id, verAsset.id)
                            } label: {
                                Text(deltaLabel)
                                    .font(.system(size: 11, weight: .semibold).monospacedDigit())
                                    .foregroundStyle(warn)
                                    .padding(.horizontal, 7.5)
                                    .padding(.vertical, 4)
                                    .background(warn.opacity(0.14), in: Capsule())
                            }
                            .buttonStyle(MobileTactileButtonStyle())
                            .accessibilityLabel("对比 v\(prevAsset.richMetadata?.versionStack?.versionNumber ?? index) 与 v\(vNum)")
                        }

                        Button {
                            if !isPrimary {
                                MobileHaptics.success()
                                Task { await store.setPrimaryVersion(assetID: verAsset.id) }
                            } else {
                                MobileHaptics.light()
                                onOpenAsset(verAsset)
                            }
                        } label: {
                            VStack(alignment: .leading, spacing: 2.5) {
                                HStack(spacing: 5) {
                                    Text(versionNodeHeadline(verAsset, vNum: vNum))
                                        .font(.system(size: 12, weight: .semibold).monospacedDigit())
                                        .foregroundStyle(.primary)
                                        .lineLimit(1)

                                    if isPrimary {
                                        Text("主版")
                                            .font(.system(size: 10, weight: .bold))
                                            .foregroundStyle(pos)
                                            .padding(.horizontal, 5)
                                            .padding(.vertical, 1)
                                            .background(pos.opacity(0.15), in: RoundedRectangle(cornerRadius: 4, style: .continuous))
                                    } else if isUnreviewed {
                                        Circle()
                                            .fill(warn)
                                            .frame(width: 6, height: 6)
                                    }
                                }

                                Text(versionNodeSubline(verAsset))
                                    .font(.system(size: 10.5).monospacedDigit())
                                    .foregroundStyle(MobileTheme.tertiaryInk(for: colorScheme))
                                    .lineLimit(1)
                            }
                            .padding(.horizontal, 10)
                            .padding(.vertical, 6)
                            .background(
                                isPrimary
                                    ? MobileTheme.accentSoft(for: colorScheme)
                                    : MobileTheme.inspectorBackground(for: colorScheme),
                                in: RoundedRectangle(cornerRadius: 8, style: .continuous)
                            )
                            .overlay(
                                RoundedRectangle(cornerRadius: 8, style: .continuous)
                                    .strokeBorder(
                                        isPrimary ? accent.opacity(0.50) : MobileTheme.hairline(for: colorScheme),
                                        lineWidth: isPrimary ? 1.2 : 0.75
                                    )
                            )
                        }
                        .buttonStyle(MobileTactileButtonStyle())
                        .contextMenu {
                            Button {
                                onOpenAsset(verAsset)
                            } label: {
                                Label("打开阅读 v\(vNum)", systemImage: "eye")
                            }
                            if !isPrimary {
                                Button {
                                    Task { await store.setPrimaryVersion(assetID: verAsset.id) }
                                } label: {
                                    Label("设为主版本（对外默认发出）", systemImage: "checkmark.seal.fill")
                                }
                            }
                            if index > 0 {
                                Button {
                                    onOpenDiff(verAsset, siblings[index - 1].id, verAsset.id)
                                } label: {
                                    Label("与上一版对比差异", systemImage: "arrow.left.arrow.right")
                                }
                            }
                            Divider()
                            Button(role: .destructive) {
                                Task { await store.unstackAsset(assetID: verAsset.id) }
                            } label: {
                                Label("从版本叠拆出为独立素材", systemImage: "square.stack.3d.up.slash")
                            }
                        }
                    }
                }
                .padding(.vertical, 1)
            }
        }
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

    private func versionNodeHeadline(_ item: AssetRecord, vNum: Int) -> String {
        if let note = item.richMetadata?.versionStack?.changeNote?.trimmingCharacters(in: .whitespacesAndNewlines),
           !note.isEmpty {
            return "v\(vNum) · \(String(note.prefix(10)))"
        }
        if let label = item.richMetadata?.versionStack?.versionLabel?.trimmingCharacters(in: .whitespacesAndNewlines),
           !label.isEmpty {
            return label
        }
        return "v\(vNum)"
    }

    private func versionNodeSubline(_ item: AssetRecord) -> String {
        let who = item.richMetadata?.versionStack?.editorName?.trimmingCharacters(in: .whitespacesAndNewlines)
        let rel = MobileFormatters.relativeDate(item.updatedAt)
        if let who, !who.isEmpty {
            return "\(who) · \(rel)"
        }
        return rel
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
                Label("对比版本差异与合成", systemImage: "arrow.left.arrow.right")
            }
        }

        Divider()

        Button {
            onSharePrimary(primaryAsset)
        } label: {
            Label(
                hasStack ? "分享主版本到微信 / 文件（防误发）" : "分享原文件",
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
                ForEach(Array(siblings.enumerated()), id: \.element.id) { idx, member in
                    let v = member.richMetadata?.versionStack?.versionNumber ?? (idx + 1)
                    let isPrimary = member.id == primaryAsset.id
                    Button {
                        Task { await store.setPrimaryVersion(assetID: member.id) }
                    } label: {
                        Label(
                            "v\(v) · \(member.title)" + (isPrimary ? "（当前主版 ✓）" : ""),
                            systemImage: isPrimary ? "checkmark.seal.fill" : "circle"
                        )
                    }
                }
            } label: {
                Label("切换对外主版本…", systemImage: "checkmark.seal")
            }

            Button {
                onRequestMergeStack(primaryAsset)
            } label: {
                Label("合并其他版本到此叠…", systemImage: "arrow.triangle.merge")
            }

            Button {
                Task { await store.unstackAsset(assetID: primaryAsset.id) }
            } label: {
                Label("拆出当前主版为独立素材", systemImage: "square.stack.3d.up.slash")
            }
        } else {
            Button {
                onRequestMergeStack(primaryAsset)
            } label: {
                Label("合并入版本叠…", systemImage: "square.stack.3d.up")
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
                        successToast: hasStack ? "已将版本叠移入回收站" : "已移入回收站",
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
                Label(hasStack ? "移入回收站（整叠）" : "移入回收站", systemImage: "trash")
            }
        }
    }
}

// MARK: - 3D Miniature Physical Folio Stack & Media Skeleton (44 x 52pt)

private struct MicroFolioArtifactStage: View {
    let asset: AssetRecord
    let thumbnail: UIImage?
    let hasStack: Bool
    let isFannedOpen: Bool

    @Environment(\.colorScheme) private var colorScheme

    private var paperFront: Color {
        colorScheme == .dark ? Color(charkleHex: "#282B33") : Color.white
    }

    private var paperBack1: Color {
        colorScheme == .dark ? Color(charkleHex: "#21242B") : Color(charkleHex: "#F3F2EE")
    }

    private var paperBack2: Color {
        colorScheme == .dark ? Color(charkleHex: "#1A1C22") : Color(charkleHex: "#E6E4DE")
    }

    private var paperLine: Color {
        colorScheme == .dark ? Color.white.opacity(0.16) : Color.black.opacity(0.12)
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

    private var formatAccent: Color {
        let lowerExt = (asset.fileName as NSString).pathExtension.lowercased()
        switch lowerExt {
        case "xlsx", "xls", "csv", "ods", "et":
            return Color(charkleHex: "#1D7A46")
        case "pdf", "ofd":
            return Color(charkleHex: "#C83E37")
        case "pptx", "ppt", "dps", "key":
            return Color(charkleHex: "#C96A1B")
        case "md", "markdown", "txt":
            return Color(charkleHex: "#4E7D96")
        default:
            return MobileTheme.accent(for: colorScheme)
        }
    }

    var body: some View {
        ZStack {
            if hasStack {
                RoundedRectangle(cornerRadius: 5, style: .continuous)
                    .fill(paperBack2)
                    .overlay(
                        RoundedRectangle(cornerRadius: 5, style: .continuous)
                            .strokeBorder(MobileTheme.borderStrong(for: colorScheme), lineWidth: 0.75)
                    )
                    .padding(.horizontal, 3)
                    .padding(.vertical, 2)
                    .offset(x: isFannedOpen ? 7.5 : 4, y: isFannedOpen ? -3.5 : -2.5)
                    .rotationEffect(.degrees(isFannedOpen ? 8 : 3), anchor: .bottomLeading)

                RoundedRectangle(cornerRadius: 5, style: .continuous)
                    .fill(paperBack1)
                    .overlay(
                        RoundedRectangle(cornerRadius: 5, style: .continuous)
                            .strokeBorder(MobileTheme.borderStrong(for: colorScheme), lineWidth: 0.75)
                    )
                    .padding(.horizontal, 3)
                    .padding(.vertical, 2)
                    .offset(x: isFannedOpen ? 4 : 2, y: isFannedOpen ? -2 : -1.2)
                    .rotationEffect(.degrees(isFannedOpen ? 4 : 1.5), anchor: .bottomLeading)
            }

            frontSheetContent
                .clipShape(RoundedRectangle(cornerRadius: 5, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 5, style: .continuous)
                        .strokeBorder(MobileTheme.borderStrong(for: colorScheme), lineWidth: 0.75)
                )
                .shadow(color: .black.opacity(0.08), radius: 2.5, y: 1)
                .padding(.horizontal, 3)
                .padding(.vertical, 2)
                .rotation3DEffect(
                    .degrees(isFannedOpen ? -22 : 0),
                    axis: (x: 0, y: 1, z: 0),
                    anchor: .leading,
                    perspective: 0.45
                )
                .offset(x: isFannedOpen ? -1 : 0)
        }
        .frame(width: 44, height: 52)
        .animation(.spring(duration: 0.28, bounce: 0.14), value: isFannedOpen)
    }

    @ViewBuilder
    private var frontSheetContent: some View {
        switch asset.mediaKind {
        case .document:
            documentSkeletonCover
        case .audio:
            audioCover
        default:
            visualMediaCover
        }
    }

    private var documentSkeletonCover: some View {
        let lowerExt = (asset.fileName as NSString).pathExtension.lowercased()
        let isSheet = ["xlsx", "xls", "csv", "ods", "et"].contains(lowerExt)
        let isRedHeader = lowerExt == "pdf"
            || asset.title.contains("红头")
            || asset.title.contains("通知")
            || asset.title.contains("汇报")
            || asset.title.contains("方案")
        let isStamped = lowerExt == "pdf" && (asset.richMetadata?.document?.hasTextLayer == false || asset.title.contains("扫描") || asset.title.contains("签"))

        return VStack(alignment: .leading, spacing: 3) {
            if isSheet {
                RoundedRectangle(cornerRadius: 1, style: .continuous)
                    .fill(formatAccent)
                    .frame(height: 4)
                VStack(spacing: 2) {
                    ForEach(0..<3, id: \.self) { row in
                        HStack(spacing: 2) {
                            ForEach(0..<3, id: \.self) { col in
                                RoundedRectangle(cornerRadius: 1, style: .continuous)
                                    .fill(sheetCellTint(row: row, col: col))
                                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                            }
                        }
                    }
                }
                .frame(maxHeight: .infinity)
            } else {
                RoundedRectangle(cornerRadius: 1.5, style: .continuous)
                    .fill(isRedHeader ? Color(charkleHex: "#D93B30") : formatAccent)
                    .frame(width: 24, height: 3)
                    .frame(maxWidth: .infinity)

                VStack(alignment: .leading, spacing: 2.5) {
                    Capsule().fill(paperLine).frame(height: 2)
                    Capsule().fill(paperLine).frame(width: 22, height: 2)
                    Capsule().fill(MobileTheme.accent(for: colorScheme).opacity(0.35)).frame(height: 2)
                    Capsule().fill(paperLine).frame(width: 19, height: 2)
                }
                .padding(.top, 1)

                Spacer(minLength: 0)
            }

            HStack(spacing: 2) {
                Text(extText)
                    .font(.system(size: 8, weight: .bold, design: .rounded))
                    .foregroundStyle(formatAccent)
                    .lineLimit(1)
                Spacer(minLength: 0)
                if isStamped {
                    Circle()
                        .strokeBorder(Color(charkleHex: "#D93B30").opacity(0.75), lineWidth: 1)
                        .frame(width: 8, height: 8)
                }
            }
        }
        .padding(5)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(paperFront)
    }

    private func sheetCellTint(row: Int, col: Int) -> Color {
        if row == 0 && col == 1 { return MobileTheme.positive(for: colorScheme).opacity(0.32) }
        if row == 1 && col == 1 { return MobileTheme.destructive(for: colorScheme).opacity(0.35) }
        return paperLine
    }

    private var audioCover: some View {
        let bars: [CGFloat] = [5, 11, 8, 15, 16, 9, 13, 6]
        return VStack(spacing: 3) {
            Spacer(minLength: 0)
            HStack(alignment: .center, spacing: 1.5) {
                ForEach(0..<bars.count, id: \.self) { idx in
                    Capsule()
                        .fill(MobileTheme.accent(for: colorScheme))
                        .frame(width: 2, height: bars[idx])
                }
            }
            Spacer(minLength: 0)
            Text(extText)
                .font(.system(size: 8, weight: .bold))
                .foregroundStyle(MobileTheme.secondaryInk(for: colorScheme))
        }
        .padding(4)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(paperFront)
    }

    private var visualMediaCover: some View {
        let swatches = asset.dominantColors.prefix(4).map(\.hex)
        return VStack(spacing: 0) {
            ZStack(alignment: .bottomLeading) {
                if let thumbnail {
                    Image(uiImage: thumbnail)
                        .resizable()
                        .scaledToFill()
                } else {
                    LinearGradient(
                        colors: [
                            Color(charkleHex: swatches.first ?? "#3D5A80"),
                            Color(charkleHex: swatches.dropFirst().first ?? "#5C6B73")
                        ],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                }

                Text(extText)
                    .font(.system(size: 7.5, weight: .bold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 3.5)
                    .padding(.vertical, 1)
                    .background(.black.opacity(0.52), in: RoundedRectangle(cornerRadius: 3, style: .continuous))
                    .padding(3)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .clipped()

            if !swatches.isEmpty {
                HStack(spacing: 0) {
                    ForEach(Array(swatches.enumerated()), id: \.offset) { _, hex in
                        Rectangle()
                            .fill(Color(charkleHex: hex))
                    }
                }
                .frame(height: 5)
            }
        }
        .background(paperFront)
    }
}
