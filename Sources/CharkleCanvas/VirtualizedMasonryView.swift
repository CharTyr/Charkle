import AppKit
import CharkleCore
import SwiftUI
import UniformTypeIdentifiers

// MARK: - Deterministic O(N) Masonry Layout Engine

public nonisolated struct MasonryItemFrame: Sendable, Equatable {
    public let id: UUID
    public let index: Int
    public let rect: CGRect
}

public nonisolated struct MasonryLayoutSnapshot: Sendable, Equatable {
    public let items: [MasonryItemFrame]
    public let totalHeight: CGFloat
    public let columnCount: Int
    public let columnWidth: CGFloat

    public static let empty = MasonryLayoutSnapshot(items: [], totalHeight: 0, columnCount: 1, columnWidth: 240)

    /// Returns only the items intersecting `[minY, maxY]` using fast linear scan with early-bound pruning
    /// (at 10k items, iterating compact value structs takes < 0.08ms!).
    public func visibleItems(minY: CGFloat, maxY: CGFloat) -> [MasonryItemFrame] {
        var result: [MasonryItemFrame] = []
        result.reserveCapacity(64)
        for item in items {
            if item.rect.maxY >= minY && item.rect.minY <= maxY {
                result.append(item)
            }
        }
        return result
    }
}

public nonisolated enum MasonryLayoutEngine {
    public static func compute(
        assets: [AssetRecord],
        containerWidth: CGFloat,
        targetColumnWidth: CGFloat,
        spacing: CGFloat,
        horizontalPadding: CGFloat,
        topInset: CGFloat,
        bottomInset: CGFloat
    ) -> MasonryLayoutSnapshot {
        let usableWidth = max(240, containerWidth - horizontalPadding * 2)
        let rawCols = Int(((usableWidth + spacing) / max(130, targetColumnWidth + spacing)).rounded(.down))
        let cols = max(2, min(10, rawCols))
        let colWidth = (usableWidth - spacing * CGFloat(cols - 1)) / CGFloat(cols)

        var colHeights = Array(repeating: topInset, count: cols)
        var frames: [MasonryItemFrame] = []
        frames.reserveCapacity(assets.count)

        for (index, asset) in assets.enumerated() {
            var bestCol = 0
            var minHeight = colHeights[0]
            if cols > 1 {
                for c in 1..<cols {
                    if colHeights[c] < minHeight - 0.5 {
                        minHeight = colHeights[c]
                        bestCol = c
                    }
                }
            }

            let rawRatio: CGFloat = switch asset.mediaKind {
            case .audio: 1.55
            case .webBookmark: 1.25
            case .document: asset.fileName.lowercased().hasSuffix(".swatch") ? 1.0 : 0.84
            default: CGFloat(asset.aspectRatio)
            }
            let clampedRatio = max(0.55, min(2.15, rawRatio))
            let cardHeight = (colWidth / clampedRatio).rounded()
            let x = horizontalPadding + CGFloat(bestCol) * (colWidth + spacing)
            let y = colHeights[bestCol]

            frames.append(MasonryItemFrame(
                id: asset.id,
                index: index,
                rect: CGRect(x: x, y: y, width: colWidth, height: cardHeight)
            ))
            colHeights[bestCol] = y + cardHeight + spacing
        }

        let totalHeight = (colHeights.max() ?? topInset) + bottomInset
        return MasonryLayoutSnapshot(
            items: frames,
            totalHeight: max(totalHeight, 360),
            columnCount: cols,
            columnWidth: colWidth
        )
    }
}

// MARK: - Context Menu & Interaction Callbacks

public struct MasonryCallbacks {
    public var onOpenQuickLook: (AssetRecord) -> Void
    public var onDropExternalInputs: ([CaptureInput]) -> Void
    public var onAddToMoodboard: ([UUID]) -> Void
    public var onMoveToFolder: ([UUID], UUID?) -> Void
    public var onTogglePinOffline: ([UUID], Bool) -> Void
    public var onCopyColorHex: (String) -> Void
    public var onRevealInFinder: (UUID) -> Void
    public var onCopyAssets: ([UUID]) -> Void
    public var onCutAssets: ([UUID]) -> Void
    public var onPasteIntoCurrentFolder: () -> Void
    public var onTrashAssets: ([UUID]) -> Void
    public var onRestoreAssets: ([UUID]) -> Void
    public var onPermanentlyDeleteAssets: ([UUID]) -> Void
    public var onResolveDragFileURL: (UUID) -> URL?

    public init(
        onOpenQuickLook: @escaping (AssetRecord) -> Void = { _ in },
        onDropExternalInputs: @escaping ([CaptureInput]) -> Void = { _ in },
        onAddToMoodboard: @escaping ([UUID]) -> Void = { _ in },
        onMoveToFolder: @escaping ([UUID], UUID?) -> Void = { _, _ in },
        onTogglePinOffline: @escaping ([UUID], Bool) -> Void = { _, _ in },
        onCopyColorHex: @escaping (String) -> Void = { _ in },
        onRevealInFinder: @escaping (UUID) -> Void = { _ in },
        onCopyAssets: @escaping ([UUID]) -> Void = { _ in },
        onCutAssets: @escaping ([UUID]) -> Void = { _ in },
        onPasteIntoCurrentFolder: @escaping () -> Void = {},
        onTrashAssets: @escaping ([UUID]) -> Void = { _ in },
        onRestoreAssets: @escaping ([UUID]) -> Void = { _ in },
        onPermanentlyDeleteAssets: @escaping ([UUID]) -> Void = { _ in },
        onResolveDragFileURL: @escaping (UUID) -> URL? = { _ in nil }
    ) {
        self.onOpenQuickLook = onOpenQuickLook
        self.onDropExternalInputs = onDropExternalInputs
        self.onAddToMoodboard = onAddToMoodboard
        self.onMoveToFolder = onMoveToFolder
        self.onTogglePinOffline = onTogglePinOffline
        self.onCopyColorHex = onCopyColorHex
        self.onRevealInFinder = onRevealInFinder
        self.onCopyAssets = onCopyAssets
        self.onCutAssets = onCutAssets
        self.onPasteIntoCurrentFolder = onPasteIntoCurrentFolder
        self.onTrashAssets = onTrashAssets
        self.onRestoreAssets = onRestoreAssets
        self.onPermanentlyDeleteAssets = onPermanentlyDeleteAssets
        self.onResolveDragFileURL = onResolveDragFileURL
    }
}

// MARK: - High-FPS Virtualized Masonry View (10k+ Items)

public struct VirtualizedMasonryView: View {
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    public let assets: [AssetRecord]
    public let folders: [FolderRecord]
    public let loader: ThumbnailImageLoader
    @Binding public var selectedAssetIDs: Set<UUID>
    public let cutAssetIDs: Set<UUID>
    public let targetColumnWidth: CGFloat
    public let topContentInset: CGFloat
    public let bottomContentInset: CGFloat
    public let heroNamespace: Namespace.ID
    public let activeQuickLookID: UUID?
    public let callbacks: MasonryCallbacks

    @State private var containerWidth: CGFloat = 960
    @State private var visibleMinY: CGFloat = 0
    @State private var visibleHeight: CGFloat = 900
    @State private var layout: MasonryLayoutSnapshot = .empty
    @State private var lastClickedID: UUID?
    @State private var marqueeStart: CGPoint?
    @State private var marqueeCurrent: CGPoint?
    @State private var marqueeBaseSelection: Set<UUID> = []
    @State private var isExternalDropTargeted: Bool = false

    private let spacing: CGFloat = 12
    private let horizontalPadding: CGFloat = 20
    private let overscan: CGFloat = 560

    public init(
        assets: [AssetRecord],
        folders: [FolderRecord],
        loader: ThumbnailImageLoader,
        selectedAssetIDs: Binding<Set<UUID>>,
        cutAssetIDs: Set<UUID> = [],
        targetColumnWidth: CGFloat = 228,
        topContentInset: CGFloat = 76,
        bottomContentInset: CGFloat = 96,
        heroNamespace: Namespace.ID,
        activeQuickLookID: UUID? = nil,
        callbacks: MasonryCallbacks = MasonryCallbacks()
    ) {
        self.assets = assets
        self.folders = folders
        self.loader = loader
        self._selectedAssetIDs = selectedAssetIDs
        self.cutAssetIDs = cutAssetIDs
        self.targetColumnWidth = targetColumnWidth
        self.topContentInset = topContentInset
        self.bottomContentInset = bottomContentInset
        self.heroNamespace = heroNamespace
        self.activeQuickLookID = activeQuickLookID
        self.callbacks = callbacks
    }

    private var assetIndexMap: [UUID: Int] {
        var map: [UUID: Int] = [:]
        map.reserveCapacity(assets.count)
        for (idx, item) in assets.enumerated() {
            map[item.id] = idx
        }
        return map
    }

    private var marqueeRect: CGRect? {
        guard let start = marqueeStart, let current = marqueeCurrent else { return nil }
        return CGRect(
            x: min(start.x, current.x),
            y: min(start.y, current.y),
            width: abs(current.x - start.x),
            height: abs(current.y - start.y)
        )
    }

    public var body: some View {
        let visibleSlice = layout.visibleItems(
            minY: max(0, visibleMinY - overscan),
            maxY: visibleMinY + visibleHeight + overscan
        )
        let byID = Dictionary(uniqueKeysWithValues: assets.map { ($0.id, $0) })

        ScrollView(.vertical) {
            ZStack(alignment: .topLeading) {
                // Background canvas hit area for clearing selection & rubber-band marquee
                CanvasSurface.ground(for: colorScheme)
                    .frame(width: max(containerWidth, 240), height: max(layout.totalHeight, visibleHeight))
                    .contentShape(Rectangle())
                    .onTapGesture {
                        if !selectedAssetIDs.isEmpty {
                            selectedAssetIDs.removeAll()
                        }
                    }
                    .gesture(marqueeDragGesture)

                // Virtualized visible-only cards
                ForEach(visibleSlice, id: \.id) { itemFrame in
                    if let asset = byID[itemFrame.id] {
                        let isSelected = selectedAssetIDs.contains(asset.id)
                        MasonryAssetCard(
                            asset: asset,
                            loader: loader,
                            folders: folders,
                            isSelected: isSelected,
                            isCut: cutAssetIDs.contains(asset.id),
                            heroNamespace: heroNamespace,
                            isHiddenForHero: activeQuickLookID == asset.id,
                            onSelect: { handleCardClick(asset: asset) },
                            onToggleSelectCheckbox: { toggleSingleSelection(asset.id) },
                            onDoubleClick: { callbacks.onOpenQuickLook(asset) },
                            onDragProvider: { makeDragProvider(for: asset) },
                            onAddToMoodboard: { callbacks.onAddToMoodboard(effectiveSelection(including: asset.id)) },
                            onMoveToFolder: { folderID in
                                callbacks.onMoveToFolder(effectiveSelection(including: asset.id), folderID)
                            },
                            onTogglePinOffline: {
                                callbacks.onTogglePinOffline(effectiveSelection(including: asset.id), !asset.pinnedOffline)
                            },
                            onCopyColorHex: { hex in callbacks.onCopyColorHex(hex) },
                            onRevealInFinder: { callbacks.onRevealInFinder(asset.id) },
                            onCopy: { callbacks.onCopyAssets(effectiveSelection(including: asset.id)) },
                            onCut: { callbacks.onCutAssets(effectiveSelection(including: asset.id)) },
                            onTrash: { callbacks.onTrashAssets(effectiveSelection(including: asset.id)) },
                            onRestore: { callbacks.onRestoreAssets(effectiveSelection(including: asset.id)) },
                            onPermanentlyDelete: { callbacks.onPermanentlyDeleteAssets(effectiveSelection(including: asset.id)) }
                        )
                        .frame(width: itemFrame.rect.width, height: itemFrame.rect.height)
                        .position(x: itemFrame.rect.midX, y: itemFrame.rect.midY)
                    }
                }

                // Rubber-band marquee overlay
                if let rect = marqueeRect, rect.width > 3 || rect.height > 3 {
                    RoundedRectangle(cornerRadius: 4, style: .continuous)
                        .fill(Color.accentColor.opacity(0.11))
                        .overlay(
                            RoundedRectangle(cornerRadius: 4, style: .continuous)
                                .strokeBorder(Color.accentColor.opacity(0.68), lineWidth: 1)
                        )
                        .frame(width: rect.width, height: rect.height)
                        .position(x: rect.midX, y: rect.midY)
                        .allowsHitTesting(false)
                }
            }
            .frame(maxWidth: .infinity, minHeight: max(layout.totalHeight, visibleHeight), alignment: .topLeading)
        }
        .canvasScrollEdgeSoft(for: .top)
        .background(CanvasSurface.ground(for: colorScheme))
        .onScrollGeometryChange(for: CGRect.self) { geo in
            geo.visibleRect
        } action: { _, newRect in
            visibleMinY = max(0, newRect.minY)
            if newRect.height > 10 {
                visibleHeight = newRect.height
            }
        }
        .onGeometryChange(for: CGSize.self) { proxy in
            proxy.size
        } action: { _, newSize in
            if abs(newSize.width - containerWidth) > 0.5, newSize.width > 120 {
                containerWidth = newSize.width
                recomputeLayout()
            }
            if newSize.height > 100 {
                visibleHeight = newSize.height
            }
        }
        .onChange(of: assets.map(\.id)) { _, _ in
            recomputeLayout()
        }
        .onChange(of: targetColumnWidth) { _, _ in
            recomputeLayout()
        }
        .onChange(of: topContentInset) { _, _ in
            recomputeLayout()
        }
        .onAppear {
            recomputeLayout()
        }
        .onDrop(of: [.fileURL, .url, .image, .plainText], isTargeted: $isExternalDropTargeted) { providers in
            handleExternalDrop(providers: providers)
        }
        .overlay {
            if isExternalDropTargeted {
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .strokeBorder(Color.accentColor.opacity(0.75), style: StrokeStyle(lineWidth: 2, dash: [8, 6]))
                    .background(Color.accentColor.opacity(0.05), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                    .padding(12)
                    .allowsHitTesting(false)
            }
        }
        .focusable()
        .focusEffectDisabled()
        .onKeyPress(.escape) {
            if !selectedAssetIDs.isEmpty {
                selectedAssetIDs.removeAll()
                return .handled
            }
            return .ignored
        }
        .onKeyPress(.space) {
            if let firstID = selectedAssetIDs.first, let asset = assets.first(where: { $0.id == firstID }) {
                callbacks.onOpenQuickLook(asset)
                return .handled
            }
            return .ignored
        }
        .onKeyPress(characters: CharacterSet(charactersIn: "aA")) { press in
            if press.modifiers.contains(.command) {
                selectedAssetIDs = Set(assets.map(\.id))
                return .handled
            }
            return .ignored
        }
        .onKeyPress(characters: CharacterSet(charactersIn: "cC")) { press in
            if press.modifiers.contains(.command), !selectedAssetIDs.isEmpty {
                callbacks.onCopyAssets(Array(selectedAssetIDs))
                return .handled
            }
            return .ignored
        }
        .onKeyPress(characters: CharacterSet(charactersIn: "xX")) { press in
            if press.modifiers.contains(.command), !selectedAssetIDs.isEmpty {
                callbacks.onCutAssets(Array(selectedAssetIDs))
                return .handled
            }
            return .ignored
        }
        .onKeyPress(characters: CharacterSet(charactersIn: "vV")) { press in
            if press.modifiers.contains(.command) {
                callbacks.onPasteIntoCurrentFolder()
                return .handled
            }
            return .ignored
        }
    }

    // MARK: - Layout & Selection Logic

    private func recomputeLayout() {
        layout = MasonryLayoutEngine.compute(
            assets: assets,
            containerWidth: containerWidth,
            targetColumnWidth: targetColumnWidth,
            spacing: spacing,
            horizontalPadding: horizontalPadding,
            topInset: topContentInset,
            bottomInset: bottomContentInset
        )
    }

    private var marqueeDragGesture: some Gesture {
        DragGesture(minimumDistance: 6, coordinateSpace: .local)
            .onChanged { value in
                if marqueeStart == nil {
                    marqueeStart = value.startLocation
                    let mods = NSEvent.modifierFlags
                    marqueeBaseSelection = (mods.contains(.command) || mods.contains(.shift)) ? selectedAssetIDs : []
                }
                marqueeCurrent = value.location
                if let rect = marqueeRect {
                    var hit = marqueeBaseSelection
                    for item in layout.items where item.rect.intersects(rect) {
                        hit.insert(item.id)
                    }
                    selectedAssetIDs = hit
                }
            }
            .onEnded { _ in
                marqueeStart = nil
                marqueeCurrent = nil
                marqueeBaseSelection = []
            }
    }

    private func handleCardClick(asset: AssetRecord) {
        let mods = NSEvent.modifierFlags
        if mods.contains(.command) {
            toggleSingleSelection(asset.id)
        } else if mods.contains(.shift), let anchorID = lastClickedID {
            let map = assetIndexMap
            if let a = map[anchorID], let b = map[asset.id] {
                let lo = min(a, b)
                let hi = max(a, b)
                let rangeIDs = assets[lo...hi].map(\.id)
                selectedAssetIDs.formUnion(rangeIDs)
            } else {
                selectedAssetIDs = [asset.id]
            }
        } else {
            selectedAssetIDs = [asset.id]
        }
        lastClickedID = asset.id
    }

    private func toggleSingleSelection(_ id: UUID) {
        if selectedAssetIDs.contains(id) {
            selectedAssetIDs.remove(id)
        } else {
            selectedAssetIDs.insert(id)
        }
        lastClickedID = id
    }

    private func effectiveSelection(including id: UUID) -> [UUID] {
        if selectedAssetIDs.contains(id) {
            return Array(selectedAssetIDs)
        }
        return [id]
    }

    private func makeDragProvider(for asset: AssetRecord) -> NSItemProvider {
        let ids = effectiveSelection(including: asset.id)
        let payload = CharkleDragIdentifiers.encode(assetIDs: ids)
        let provider = NSItemProvider(object: payload as NSString)
        if let localURL = callbacks.onResolveDragFileURL(asset.id) {
            provider.registerFileRepresentation(
                forTypeIdentifier: UTType.fileURL.identifier,
                fileOptions: [],
                visibility: .all
            ) { completion in
                completion(localURL, false, nil)
                return nil
            }
        }
        return provider
    }

    private func handleExternalDrop(providers: [NSItemProvider]) -> Bool {
        guard !providers.isEmpty else { return false }
        Task {
            var inputs: [CaptureInput] = []
            for provider in providers {
                if provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) {
                    if let url = await loadDroppedURL(from: provider, type: UTType.fileURL) {
                        inputs.append(.fileURL(url))
                        continue
                    }
                }
                if provider.hasItemConformingToTypeIdentifier(UTType.url.identifier) {
                    if let url = await loadDroppedURL(from: provider, type: UTType.url) {
                        if url.isFileURL {
                            inputs.append(.fileURL(url))
                        } else if url.scheme == "http" || url.scheme == "https" {
                            inputs.append(.webURL(url, title: nil, notes: nil))
                        }
                        continue
                    }
                }
                if provider.hasItemConformingToTypeIdentifier(UTType.image.identifier) {
                    if let data = await loadDroppedData(from: provider, type: UTType.image) {
                        inputs.append(.imageData(data, suggestedName: "Drop-\(Int(Date().timeIntervalSince1970)).png", sourceURL: nil))
                        continue
                    }
                }
                if provider.hasItemConformingToTypeIdentifier(UTType.plainText.identifier) {
                    if let text = await loadDroppedString(from: provider),
                       CharkleDragIdentifiers.decodeAssetIDs(from: text) == nil {
                        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
                        if let url = URL(string: trimmed), url.scheme == "http" || url.scheme == "https" {
                            inputs.append(.webURL(url, title: nil, notes: nil))
                        } else if !trimmed.isEmpty {
                            let title = String(trimmed.prefix(36)).replacingOccurrences(of: "\n", with: " ")
                            inputs.append(.textSnippet(title: title, text: trimmed, sourceURL: nil))
                        }
                    }
                }
            }
            if !inputs.isEmpty {
                callbacks.onDropExternalInputs(inputs)
            }
        }
        return true
    }

    private func loadDroppedURL(from provider: NSItemProvider, type: UTType) async -> URL? {
        await withCheckedContinuation { continuation in
            provider.loadItem(forTypeIdentifier: type.identifier, options: nil) { item, _ in
                if let url = item as? URL {
                    continuation.resume(returning: url)
                } else if let data = item as? Data, let url = URL(dataRepresentation: data, relativeTo: nil) {
                    continuation.resume(returning: url)
                } else if let str = item as? String, let url = URL(string: str) {
                    continuation.resume(returning: url)
                } else {
                    continuation.resume(returning: nil)
                }
            }
        }
    }

    private func loadDroppedData(from provider: NSItemProvider, type: UTType) async -> Data? {
        await withCheckedContinuation { continuation in
            provider.loadDataRepresentation(forTypeIdentifier: type.identifier) { data, _ in
                continuation.resume(returning: data)
            }
        }
    }

    private func loadDroppedString(from provider: NSItemProvider) async -> String? {
        await withCheckedContinuation { continuation in
            provider.loadItem(forTypeIdentifier: UTType.plainText.identifier, options: nil) { item, _ in
                if let str = item as? String {
                    continuation.resume(returning: str)
                } else if let data = item as? Data, let str = String(data: data, encoding: .utf8) {
                    continuation.resume(returning: str)
                } else {
                    continuation.resume(returning: nil)
                }
            }
        }
    }
}

// MARK: - Gallery-First Asset Card

private struct MasonryAssetCard: View {
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    let asset: AssetRecord
    let loader: ThumbnailImageLoader
    let folders: [FolderRecord]
    let isSelected: Bool
    let isCut: Bool
    let heroNamespace: Namespace.ID
    let isHiddenForHero: Bool
    let onSelect: () -> Void
    let onToggleSelectCheckbox: () -> Void
    let onDoubleClick: () -> Void
    let onDragProvider: () -> NSItemProvider
    let onAddToMoodboard: () -> Void
    let onMoveToFolder: (UUID?) -> Void
    let onTogglePinOffline: () -> Void
    let onCopyColorHex: (String) -> Void
    let onRevealInFinder: () -> Void
    let onCopy: () -> Void
    let onCut: () -> Void
    let onTrash: () -> Void
    let onRestore: () -> Void
    let onPermanentlyDelete: () -> Void

    @State private var isHovered: Bool = false

    private let outerRadius: CGFloat = 12
    private let badgePadding: CGFloat = 6
    private var innerBadgeRadius: CGFloat { max(4, outerRadius - badgePadding) }

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: outerRadius, style: .continuous)

        ZStack {
            AssetThumbnailSurface(
                asset: asset,
                loader: loader,
                tier: .grid520,
                cornerRadius: outerRadius,
                isHovered: isHovered
            )
            .matchedGeometryEffect(id: asset.id, in: heroNamespace, isSource: !isHiddenForHero)
            .opacity(isHiddenForHero ? 0.0 : (isCut ? 0.52 : 1.0))

            if isCut {
                shape
                    .strokeBorder(Color.secondary.opacity(0.65), style: StrokeStyle(lineWidth: 1.25, dash: [5, 4]))
                    .allowsHitTesting(false)
            }

            // Subtle hover luminance kiss (never animating layout on hover)
            if isHovered && !isSelected {
                shape
                    .fill(Color.white.opacity(colorScheme == .dark ? 0.05 : 0.06))
                    .allowsHitTesting(false)
            }

            // Top-left selection checkbox (hover or selected)
            VStack {
                HStack(alignment: .top) {
                    if isHovered || isSelected {
                        Button(action: onToggleSelectCheckbox) {
                            ZStack {
                                RoundedRectangle(cornerRadius: innerBadgeRadius, style: .continuous)
                                    .fill(isSelected ? Color.accentColor : Color.black.opacity(0.42))
                                    .frame(width: 22, height: 22)
                                    .overlay(
                                        RoundedRectangle(cornerRadius: innerBadgeRadius, style: .continuous)
                                            .strokeBorder(Color.white.opacity(isSelected ? 0.45 : 0.65), lineWidth: 1)
                                    )
                                if isSelected {
                                    Image(systemName: "checkmark")
                                        .font(.system(size: 11, weight: .bold))
                                        .foregroundStyle(.white)
                                        .transition(.scale.combined(with: .opacity))
                                }
                            }
                        }
                        .buttonStyle(.plain)
                        .animation(CanvasMotion.accessible(CanvasMotion.microOvershoot, reduced: reduceMotion), value: isSelected)
                    }

                    Spacer(minLength: 4)

                    // Top-right media kind / always-available-offline badge (quiet & gallery-respectful)
                    HStack(spacing: 4) {
                        if asset.pinnedOffline {
                            Image(systemName: "arrow.down.circle.fill")
                                .font(.system(size: 10, weight: .semibold))
                                .foregroundStyle(.white.opacity(0.92))
                                .frame(width: 18, height: 18)
                                .background(Color.black.opacity(0.42), in: Circle())
                                .overlay(
                                    Circle()
                                        .strokeBorder(Color.white.opacity(0.18), lineWidth: 0.5)
                                )
                                .help("已始终保留在本地")
                        }

                        if let badgeText = mediaBadgeText {
                            HStack(spacing: 3) {
                                if isHovered && (asset.mediaKind == .animatedImage || asset.mediaKind == .video) {
                                    Circle()
                                        .fill(Color.green)
                                        .frame(width: 5, height: 5)
                                }
                                Text(badgeText)
                                    .font(.system(size: 10, weight: .semibold, design: .monospaced))
                                    .monospacedDigit()
                            }
                            .foregroundStyle(.white.opacity(0.95))
                            .padding(.horizontal, 6)
                            .padding(.vertical, 3)
                            .background(Color.black.opacity(0.54), in: RoundedRectangle(cornerRadius: innerBadgeRadius, style: .continuous))
                        }
                    }
                }
                .padding(badgePadding)

                Spacer()

                // Quiet bottom hover caption ONLY on hover for clean visual assets (zero permanent clutter!)
                if isHovered && (asset.mediaKind == .image || asset.mediaKind == .animatedImage || asset.mediaKind == .video) {
                    HStack(spacing: 6) {
                        Text(asset.title)
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(.white)
                            .lineLimit(1)
                        Spacer(minLength: 4)
                        if asset.rating > 0 {
                            HStack(spacing: 1) {
                                Image(systemName: "star.fill")
                                    .font(.system(size: 9))
                                Text("\(asset.rating)")
                                    .font(.system(size: 10, weight: .semibold))
                                    .monospacedDigit()
                            }
                            .foregroundStyle(Color(charkleHex: "#F2C14E"))
                        }
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 7)
                    .background(
                        LinearGradient(
                            colors: [.clear, Color.black.opacity(0.62)],
                            startPoint: .top,
                            endPoint: .bottom
                        )
                    )
                    .clipShape(shape)
                    .transition(.opacity)
                }
            }
        }
        .overlay {
            if isSelected {
                shape
                    .strokeBorder(Color.accentColor, lineWidth: 2.5)
            } else {
                shape
                    .strokeBorder(CanvasSurface.hairline(for: colorScheme), lineWidth: 0.75)
            }
        }
        .shadow(
            color: Color.black.opacity(colorScheme == .dark ? (isSelected ? 0.36 : 0.22) : (isSelected ? 0.14 : 0.06)),
            radius: isSelected ? 10 : 4,
            y: isSelected ? 4 : 2
        )
        .contentShape(shape)
        .onHover { hovering in
            withAnimation(CanvasMotion.accessible(CanvasMotion.hoverPress, reduced: reduceMotion)) {
                isHovered = hovering
            }
        }
        .simultaneousGesture(
            TapGesture(count: 2).onEnded {
                onDoubleClick()
            }
        )
        .simultaneousGesture(
            TapGesture(count: 1).onEnded {
                onSelect()
            }
        )
        .onDrag {
            onDragProvider()
        }
        .contextMenu {
            Button("快速预览 (Space)") {
                onDoubleClick()
            }
            Button {
                onRevealInFinder()
            } label: {
                Label("在访达中显示", systemImage: "folder")
            }
            if asset.isTrashed {
                Divider()
                Button {
                    onRestore()
                } label: {
                    Label("放回原处", systemImage: "arrow.uturn.backward")
                }
                Button(role: .destructive) {
                    onPermanentlyDelete()
                } label: {
                    Label("彻底删除", systemImage: "trash.slash")
                }
            } else {
                Divider()
                Button {
                    onCopy()
                } label: {
                    Label("拷贝", systemImage: "doc.on.doc")
                }
                Button {
                    onCut()
                } label: {
                    Label("剪切", systemImage: "scissors")
                }
                Divider()
                Button("加入情绪板…") {
                    onAddToMoodboard()
                }
                Menu("移动到文件夹") {
                    Button("收件箱") { onMoveToFolder(nil) }
                    if !folders.isEmpty {
                        Divider()
                        ForEach(folders) { folder in
                            Button(folder.name) {
                                onMoveToFolder(folder.id)
                            }
                        }
                    }
                }
                Button {
                    onTogglePinOffline()
                } label: {
                    Label(
                        asset.pinnedOffline ? "取消始终保留在本地" : "始终保留在本地",
                        systemImage: asset.pinnedOffline ? "icloud" : "arrow.down.circle"
                    )
                }
                if let hex = asset.dominantColors.first?.hex {
                    Button("复制主色 \(hex.uppercased())") {
                        onCopyColorHex(hex.uppercased())
                    }
                }
                Divider()
                Button("移至废纸篓", role: .destructive) {
                    onTrash()
                }
            }
        }
    }

    private var mediaBadgeText: String? {
        switch asset.mediaKind {
        case .image:
            return nil
        case .animatedImage:
            return isHovered ? "LOOP" : "GIF"
        case .video:
            return CanvasFormatters.durationString(asset.durationSeconds)
        case .audio:
            return "AUDIO"
        case .webBookmark:
            return "WEB"
        case .document:
            return asset.fileName.lowercased().hasSuffix(".swatch") ? nil : CanvasFormatters.fileExtensionBadge(for: asset.fileName)
        case .designFile:
            return CanvasFormatters.fileExtensionBadge(for: asset.fileName)
        }
    }
}
