import AppKit
import CharkleCanvas
import CharkleCore
import SwiftUI

/// macOS Finder-inspired Gallery / Filmstrip View for fast visual culling:
/// large centered preview stage on top + scrollable horizontal filmstrip along the bottom
/// with keyboard ←/→ stepping, multi-select, drag-out, and double-click Quick Look.
public struct GalleryFilmstripView: View {
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    public let assets: [AssetRecord]
    public let loader: ThumbnailImageLoader
    @Binding public var selectedAssetIDs: Set<UUID>
    public let topContentInset: CGFloat
    public let resolveOriginalURL: (UUID) async -> URL?
    public let onOpenQuickLook: (AssetRecord) -> Void
    public let onMarkOpened: (UUID) -> Void
    public let onSetRating: ([UUID], Int) -> Void
    public let onExtractSocialMedia: (AssetRecord, SocialMediaAttachment, Int) -> Void
    public let onExtractAllSocialMedia: (AssetRecord) -> Void
    public let onRefreshRichAsset: (UUID) -> Void

    @State private var focusedAssetID: UUID?
    @State private var previewImage: NSImage?
    @State private var activeOriginalURL: URL?
    @State private var previewLoadTask: Task<Void, Never>?

    public init(
        assets: [AssetRecord],
        loader: ThumbnailImageLoader,
        selectedAssetIDs: Binding<Set<UUID>>,
        topContentInset: CGFloat = 76,
        resolveOriginalURL: @escaping (UUID) async -> URL? = { _ in nil },
        onOpenQuickLook: @escaping (AssetRecord) -> Void,
        onMarkOpened: @escaping (UUID) -> Void,
        onSetRating: @escaping ([UUID], Int) -> Void,
        onExtractSocialMedia: @escaping (AssetRecord, SocialMediaAttachment, Int) -> Void = { _, _, _ in },
        onExtractAllSocialMedia: @escaping (AssetRecord) -> Void = { _ in },
        onRefreshRichAsset: @escaping (UUID) -> Void = { _ in }
    ) {
        self.assets = assets
        self.loader = loader
        self._selectedAssetIDs = selectedAssetIDs
        self.topContentInset = topContentInset
        self.resolveOriginalURL = resolveOriginalURL
        self.onOpenQuickLook = onOpenQuickLook
        self.onMarkOpened = onMarkOpened
        self.onSetRating = onSetRating
        self.onExtractSocialMedia = onExtractSocialMedia
        self.onExtractAllSocialMedia = onExtractAllSocialMedia
        self.onRefreshRichAsset = onRefreshRichAsset
    }

    private var activeAsset: AssetRecord? {
        if let id = focusedAssetID, let match = assets.first(where: { $0.id == id }) {
            return match
        }
        if let firstSelected = selectedAssetIDs.first, let match = assets.first(where: { $0.id == firstSelected }) {
            return match
        }
        return assets.first
    }

    private var activeIndex: Int? {
        guard let active = activeAsset else { return nil }
        return assets.firstIndex(where: { $0.id == active.id })
    }

    public var body: some View {
        VStack(spacing: 0) {
            Spacer().frame(height: topContentInset)

            // Large Centered Preview Stage
            ZStack {
                if let asset = activeAsset {
                    VStack(spacing: 12) {
                        ZStack {
                            if let repo = asset.richMetadata?.githubRepo {
                                QuickLookGitHubRepoCard(asset: asset, repo: repo) {
                                    onRefreshRichAsset(asset.id)
                                }
                                .padding(.vertical, 6)
                            } else if let post = asset.richMetadata?.socialPost {
                                QuickLookSocialPostCard(
                                    asset: asset,
                                    post: post,
                                    originalURL: activeOriginalURL,
                                    onExtractMedia: { attachment, idx in
                                        onExtractSocialMedia(asset, attachment, idx)
                                    },
                                    onExtractAllMedia: {
                                        onExtractAllSocialMedia(asset)
                                    },
                                    onRetryFetch: {
                                        onRefreshRichAsset(asset.id)
                                    }
                                )
                                .padding(.vertical, 6)
                            } else if asset.isPlainTextDocument {
                                QuickLookMarkdownReaderCard(asset: asset, originalURL: activeOriginalURL)
                                    .padding(.vertical, 6)
                            } else if asset.mediaKind == .model3D {
                                QuickLookModel3DViewer(asset: asset, originalURL: activeOriginalURL)
                                    .padding(.vertical, 6)
                            } else if let img = previewImage {
                                Image(nsImage: img)
                                    .resizable()
                                    .interpolation(.high)
                                    .aspectRatio(contentMode: .fit)
                                    .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                                    .shadow(color: .black.opacity(colorScheme == .dark ? 0.42 : 0.12), radius: 20, y: 8)
                                    .contentShape(Rectangle())
                                    .onTapGesture(count: 2) {
                                        onOpenQuickLook(asset)
                                    }
                                    .onDrag {
                                        let ids = selectedAssetIDs.contains(asset.id) ? Array(selectedAssetIDs) : [asset.id]
                                        return NSItemProvider(object: CharkleDragIdentifiers.encode(assetIDs: ids) as NSString)
                                    }
                            } else {
                                AssetThumbnailSurface(asset: asset, loader: loader, tier: .preview1400, cornerRadius: 12, contentMode: .fit)
                                    .contentShape(Rectangle())
                                    .onTapGesture(count: 2) {
                                        onOpenQuickLook(asset)
                                    }
                                    .onDrag {
                                        let ids = selectedAssetIDs.contains(asset.id) ? Array(selectedAssetIDs) : [asset.id]
                                        return NSItemProvider(object: CharkleDragIdentifiers.encode(assetIDs: ids) as NSString)
                                    }
                            }
                        }
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .padding(.horizontal, 48)
                        .padding(.top, 12)

                        // Compact Metadata & Quick Rating Bar below hero image
                        HStack(spacing: 12) {
                            Text(asset.title)
                                .font(.system(size: 13, weight: .semibold))
                                .lineLimit(1)

                            if asset.pixelWidth > 0 && asset.pixelHeight > 0 {
                                Text("\(asset.pixelWidth) × \(asset.pixelHeight)")
                                    .font(.system(size: 11.5, design: .monospaced))
                                    .foregroundStyle(.secondary)
                            }

                            if let idx = activeIndex {
                                Text("\(idx + 1) / \(assets.count)")
                                    .font(.system(size: 11.5, weight: .medium, design: .rounded))
                                    .monospacedDigit()
                                    .foregroundStyle(.secondary)
                                    .padding(.horizontal, 8)
                                    .padding(.vertical, 2.5)
                                    .background(Color.primary.opacity(0.06), in: Capsule(style: .continuous))
                            }

                            // Quick 1-5 Star Rating
                            HStack(spacing: 2) {
                                ForEach(1...5, id: \.self) { star in
                                    Button {
                                        let next = asset.rating == star ? 0 : star
                                        onSetRating([asset.id], next)
                                    } label: {
                                        Image(systemName: star <= asset.rating ? "star.fill" : "star")
                                            .font(.system(size: 11))
                                            .foregroundStyle(star <= asset.rating ? Color.orange : Color.secondary.opacity(0.5))
                                    }
                                    .buttonStyle(.plain)
                                }
                            }

                            Button {
                                onOpenQuickLook(asset)
                            } label: {
                                HStack(spacing: 4) {
                                    CharkleIcon("quicklook", style: .duotone, size: 14)
                                    Text("沉浸预览")
                                        .font(.system(size: 11.5, weight: .medium))
                                }
                                .padding(.horizontal, 9)
                                .padding(.vertical, 4)
                                .background(Color.primary.opacity(0.06), in: Capsule(style: .continuous))
                            }
                            .buttonStyle(.plain)
                        }
                        .padding(.horizontal, 20)
                        .padding(.bottom, 10)
                    }

                    // Subtle Left / Right Stepping Chevrons
                    HStack {
                        Button {
                            step(by: -1)
                        } label: {
                            Image(systemName: "chevron.left")
                                .font(.system(size: 14, weight: .semibold))
                                .foregroundStyle(.primary.opacity(0.8))
                                .frame(width: 34, height: 34)
                                .charkleLiquidGlass(.regular, in: Circle(), interactive: true)
                        }
                        .buttonStyle(.plain)
                        .opacity((activeIndex ?? 0) > 0 ? 1 : 0.25)
                        .disabled((activeIndex ?? 0) == 0)

                        Spacer()

                        Button {
                            step(by: 1)
                        } label: {
                            Image(systemName: "chevron.right")
                                .font(.system(size: 14, weight: .semibold))
                                .foregroundStyle(.primary.opacity(0.8))
                                .frame(width: 34, height: 34)
                                .charkleLiquidGlass(.regular, in: Circle(), interactive: true)
                        }
                        .buttonStyle(.plain)
                        .opacity((activeIndex ?? assets.count) < assets.count - 1 ? 1 : 0.25)
                        .disabled((activeIndex ?? assets.count) >= assets.count - 1)
                    }
                    .padding(.horizontal, 14)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            Divider()

            // Bottom Horizontal Filmstrip Scrubber
            ScrollViewReader { proxy in
                ScrollView(.horizontal, showsIndicators: false) {
                    LazyHStack(spacing: 8) {
                        ForEach(assets) { item in
                            let isFocused = activeAsset?.id == item.id
                            let isSelected = selectedAssetIDs.contains(item.id)
                            let thumbW: CGFloat = max(46, min(116, 68 * CGFloat(max(0.6, min(1.75, item.aspectRatio)))))

                            AssetThumbnailSurface(asset: item, loader: loader, tier: .grid520, cornerRadius: 7, contentMode: .fill)
                                .frame(width: thumbW, height: 68)
                                .overlay(
                                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                                        .strokeBorder(
                                            isFocused ? Color.accentColor : (isSelected ? Color.accentColor.opacity(0.65) : Color.primary.opacity(0.12)),
                                            lineWidth: isFocused ? 2.5 : (isSelected ? 1.5 : 0.75)
                                        )
                                )
                                .scaleEffect(isFocused ? 1.04 : 1.0)
                                .animation(CharkleMotion.accessible(CharkleMotion.settleStrong, reduced: reduceMotion), value: isFocused)
                                .contentShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
                                .onTapGesture {
                                    selectFilmstripItem(item)
                                }
                                .id(item.id)
                                .onDrag {
                                    let ids = selectedAssetIDs.contains(item.id) ? Array(selectedAssetIDs) : [item.id]
                                    return NSItemProvider(object: CharkleDragIdentifiers.encode(assetIDs: ids) as NSString)
                                }
                        }
                    }
                    .padding(.horizontal, 18)
                    .padding(.vertical, 12)
                }
                .frame(height: 96)
                .background(CharkleTheme.surfaceElevated(for: colorScheme).opacity(0.86))
                .onChange(of: activeAsset?.id) { _, newID in
                    if let newID {
                        withAnimation(CharkleMotion.accessible(CharkleMotion.settleStrong, reduced: reduceMotion)) {
                            proxy.scrollTo(newID, anchor: .center)
                        }
                        loadPreview(for: newID)
                        onMarkOpened(newID)
                    }
                }
                .onAppear {
                    if let first = activeAsset {
                        focusedAssetID = first.id
                        if selectedAssetIDs.isEmpty {
                            selectedAssetIDs = [first.id]
                        }
                        loadPreview(for: first.id)
                    }
                }
            }
        }
        .background(CanvasSurface.ground(for: colorScheme))
        .focusable()
        .onKeyPress(.leftArrow) {
            step(by: -1)
            return .handled
        }
        .onKeyPress(.rightArrow) {
            step(by: 1)
            return .handled
        }
    }

    private func selectFilmstripItem(_ item: AssetRecord) {
        let mods = NSEvent.modifierFlags
        focusedAssetID = item.id
        if mods.contains(.command) {
            if selectedAssetIDs.contains(item.id) {
                selectedAssetIDs.remove(item.id)
            } else {
                selectedAssetIDs.insert(item.id)
            }
        } else if mods.contains(.shift), let anchor = activeIndex, let target = assets.firstIndex(where: { $0.id == item.id }) {
            let lo = min(anchor, target)
            let hi = max(anchor, target)
            for idx in lo...hi {
                selectedAssetIDs.insert(assets[idx].id)
            }
        } else {
            selectedAssetIDs = [item.id]
        }
    }

    private func step(by delta: Int) {
        guard let currentIdx = activeIndex, !assets.isEmpty else { return }
        let nextIdx = max(0, min(assets.count - 1, currentIdx + delta))
        guard nextIdx != currentIdx else { return }
        let target = assets[nextIdx]
        focusedAssetID = target.id
        selectedAssetIDs = [target.id]
    }

    private func loadPreview(for id: UUID) {
        previewLoadTask?.cancel()
        activeOriginalURL = nil
        if let cached = loader.cachedImage(for: id, tier: .preview1400) ?? loader.cachedImage(for: id, tier: .grid520) {
            previewImage = cached
        } else {
            previewImage = nil
        }
        previewLoadTask = Task {
            let orig = await resolveOriginalURL(id)
            guard !Task.isCancelled else { return }
            activeOriginalURL = orig
            if let img = await loader.loadImage(for: id, tier: .preview1400) {
                guard !Task.isCancelled else { return }
                previewImage = img
            }
        }
    }
}
