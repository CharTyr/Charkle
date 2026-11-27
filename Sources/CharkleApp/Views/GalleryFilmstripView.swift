import AppKit
import CharkleCanvas
import CharkleCore
import SwiftUI
import UniformTypeIdentifiers

/// macOS Finder-inspired Gallery / Filmstrip View with full Quick Look parity:
/// - Live preview for all media kinds (images, GIF, video, audio, PDF, 3D, Markdown, GitHub, Social Posts, bookmarks)
/// - Direct scroll-wheel zoom, trackpad pinch zoom, pan when zoomed, double-click 100%↔200%
/// - Always-visible preview transform controls (zoom ±/reset, ±90° rotate, horizontal/vertical flip, star rating)
/// - Complete right-click context menu on both the preview stage and every filmstrip thumbnail
/// - Normal vertical scroll wheel scrolls the bottom filmstrip horizontally (no Shift required)
public struct GalleryFilmstripView: View {
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    public let assets: [AssetRecord]
    public let folders: [FolderRecord]
    public let boards: [MoodboardSummary]
    public let activeMoodboardID: UUID?
    public let isQuickLookPresented: Bool
    public let loader: ThumbnailImageLoader
    @Binding public var selectedAssetIDs: Set<UUID>
    public let topContentInset: CGFloat
    public let resolveOriginalURL: (UUID) async -> URL?
    public let onOpenQuickLook: (AssetRecord) -> Void
    public let onMarkOpened: (UUID) -> Void
    public let onSetRating: ([UUID], Int) -> Void
    public let onCopyAssets: ([UUID]) -> Void
    public let onCutAssets: ([UUID]) -> Void
    public let onRevealInFinder: (UUID) -> Void
    public let onAddToMoodboard: ([UUID], UUID?) -> Void
    public let onMoveToFolder: ([UUID], UUID?) -> Void
    public let onTogglePinOffline: ([UUID], Bool) -> Void
    public let onRetagAssets: ([UUID]) -> Void
    public let onTrashAssets: ([UUID]) -> Void
    public let onRestoreAssets: ([UUID]) -> Void
    public let onPermanentlyDeleteAssets: ([UUID]) -> Void
    public let onExtractSocialMedia: (AssetRecord, SocialMediaAttachment, Int) -> Void
    public let onExtractAllSocialMedia: (AssetRecord) -> Void
    public let onRefreshRichAsset: (UUID) -> Void
    public let onFocusedAssetChanged: ((UUID?) -> Void)?

    @State private var focusedAssetID: UUID?
    @State private var previewImage: NSImage?
    @State private var previewImageAssetID: UUID?
    @State private var activeOriginalURL: URL?
    @State private var previewLoadTask: Task<Void, Never>?

    // Interactive Preview Transform State (1:1 parity with QuickLookOverlayView)
    @State private var zoomScale: CGFloat = 1.0
    @State private var gestureStartScale: CGFloat?
    @State private var panOffset: CGSize = .zero
    @State private var panStartOffset: CGSize = .zero
    @State private var rotationDegrees: Double = 0
    @State private var flipHorizontal: Bool = false
    @State private var flipVertical: Bool = false
    @State private var stageViewportSize: CGSize = CGSize(width: 900, height: 540)

    public init(
        assets: [AssetRecord],
        folders: [FolderRecord] = [],
        boards: [MoodboardSummary] = [],
        activeMoodboardID: UUID? = nil,
        isQuickLookPresented: Bool = false,
        loader: ThumbnailImageLoader,
        selectedAssetIDs: Binding<Set<UUID>>,
        topContentInset: CGFloat = 76,
        resolveOriginalURL: @escaping (UUID) async -> URL? = { _ in nil },
        onOpenQuickLook: @escaping (AssetRecord) -> Void,
        onMarkOpened: @escaping (UUID) -> Void,
        onSetRating: @escaping ([UUID], Int) -> Void,
        onCopyAssets: @escaping ([UUID]) -> Void = { _ in },
        onCutAssets: @escaping ([UUID]) -> Void = { _ in },
        onRevealInFinder: @escaping (UUID) -> Void = { _ in },
        onAddToMoodboard: @escaping ([UUID], UUID?) -> Void = { _, _ in },
        onMoveToFolder: @escaping ([UUID], UUID?) -> Void = { _, _ in },
        onTogglePinOffline: @escaping ([UUID], Bool) -> Void = { _, _ in },
        onRetagAssets: @escaping ([UUID]) -> Void = { _ in },
        onTrashAssets: @escaping ([UUID]) -> Void = { _ in },
        onRestoreAssets: @escaping ([UUID]) -> Void = { _ in },
        onPermanentlyDeleteAssets: @escaping ([UUID]) -> Void = { _ in },
        onExtractSocialMedia: @escaping (AssetRecord, SocialMediaAttachment, Int) -> Void = { _, _, _ in },
        onExtractAllSocialMedia: @escaping (AssetRecord) -> Void = { _ in },
        onRefreshRichAsset: @escaping (UUID) -> Void = { _ in },
        onFocusedAssetChanged: ((UUID?) -> Void)? = nil
    ) {
        self.assets = assets
        self.folders = folders
        self.boards = boards
        self.activeMoodboardID = activeMoodboardID
        self.isQuickLookPresented = isQuickLookPresented
        self.loader = loader
        self._selectedAssetIDs = selectedAssetIDs
        self.topContentInset = topContentInset
        self.resolveOriginalURL = resolveOriginalURL
        self.onOpenQuickLook = onOpenQuickLook
        self.onMarkOpened = onMarkOpened
        self.onSetRating = onSetRating
        self.onCopyAssets = onCopyAssets
        self.onCutAssets = onCutAssets
        self.onRevealInFinder = onRevealInFinder
        self.onAddToMoodboard = onAddToMoodboard
        self.onMoveToFolder = onMoveToFolder
        self.onTogglePinOffline = onTogglePinOffline
        self.onRetagAssets = onRetagAssets
        self.onTrashAssets = onTrashAssets
        self.onRestoreAssets = onRestoreAssets
        self.onPermanentlyDeleteAssets = onPermanentlyDeleteAssets
        self.onExtractSocialMedia = onExtractSocialMedia
        self.onExtractAllSocialMedia = onExtractAllSocialMedia
        self.onRefreshRichAsset = onRefreshRichAsset
        self.onFocusedAssetChanged = onFocusedAssetChanged
    }

    private func resolveActiveSelection() -> (asset: AssetRecord, index: Int)? {
        if let id = focusedAssetID, let idx = assets.firstIndex(where: { $0.id == id }) {
            return (assets[idx], idx)
        }
        if let firstSelected = selectedAssetIDs.first, let idx = assets.firstIndex(where: { $0.id == firstSelected }) {
            return (assets[idx], idx)
        }
        guard let first = assets.first else { return nil }
        return (first, 0)
    }

    private var activeAsset: AssetRecord? {
        resolveActiveSelection()?.asset
    }

    private var activeIndex: Int? {
        resolveActiveSelection()?.index
    }

    private func supportsVisualTransform(for asset: AssetRecord) -> Bool {
        !asset.isGitHubRepo && !asset.isSocialPost
            && (asset.mediaKind == .image || asset.mediaKind == .designFile || asset.mediaKind == .animatedImage)
    }

    private var supportsVisualTransform: Bool {
        guard let asset = activeAsset else { return false }
        return supportsVisualTransform(for: asset)
    }

    private var displayRotationDegrees: Int {
        let raw = Int(rotationDegrees.rounded()) % 360
        return raw < 0 ? raw + 360 : raw
    }

    private var hasActiveVisualTransform: Bool {
        displayRotationDegrees != 0 || flipHorizontal || flipVertical
    }

    private var hasAnyTransformOrZoom: Bool {
        hasActiveVisualTransform || abs(zoomScale - 1.0) > 0.01 || panOffset != .zero
    }

    /// Keeps ±90° rotated landscape/portrait media cleanly fitted inside the gallery preview stage.
    private var quarterTurnFitScale: CGFloat {
        guard let asset = activeAsset, displayRotationDegrees == 90 || displayRotationDegrees == 270 else {
            return 1.0
        }
        let availW = max(120, stageViewportSize.width)
        let availH = max(120, stageViewportSize.height)
        let naturalRatio: CGFloat = {
            if let img = previewImage ?? loader.cachedImage(for: asset.id, tier: .grid520), img.size.height > 0 {
                return img.size.width / img.size.height
            }
            return CGFloat(max(0.2, asset.aspectRatio))
        }()
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

    public var body: some View {
        let resolved = resolveActiveSelection()
        let currentAsset = resolved?.asset
        let currentIndex = resolved?.index
        let currentAssetID = currentAsset?.id
        let canTransformCurrent = currentAsset.map(supportsVisualTransform(for:)) ?? false

        VStack(spacing: 0) {
            Spacer().frame(height: topContentInset)

            // Large Centered Interactive Preview Stage
            ZStack {
                if let asset = currentAsset {
                    VStack(spacing: 10) {
                        ZStack {
                            stageMediaContent(for: asset)
                        }
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .clipped()
                        .background {
                            Color.clear
                                .onGeometryChange(for: CGSize.self) { proxy in
                                    CGSize(width: floor(max(0, proxy.size.width)), height: floor(max(0, proxy.size.height)))
                                } action: { _, newSize in
                                    if newSize.width > 80, newSize.height > 80,
                                       (abs(newSize.width - stageViewportSize.width) >= 2 || abs(newSize.height - stageViewportSize.height) >= 2) {
                                        stageViewportSize = newSize
                                    }
                                }
                        }
                        .overlay {
                            StageInteractiveBridge(
                                isWheelZoomEnabled: canTransformCurrent && !isQuickLookPresented,
                                onWheelZoom: { factor in
                                    applyWheelZoom(factor: factor)
                                },
                                onKeyDown: { event in
                                    handleStageKeyDown(event)
                                }
                            )
                            .allowsHitTesting(false)
                        }
                        .padding(.horizontal, 44)
                        .padding(.top, 10)
                        .contextMenu {
                            assetContextMenu(for: asset)
                        }

                        // Preview Controls Bar + Metadata Strip
                        previewControlAndMetadataBar(for: asset, activeIndex: currentIndex, supportsTransform: canTransformCurrent)
                            .padding(.horizontal, 18)
                            .padding(.bottom, 10)
                    }

                    // Subtle Left / Right Stepping Chevrons
                    if assets.count > 1 {
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
                            .buttonStyle(CharkleTactileButtonStyle())
                            .opacity((currentIndex ?? 0) > 0 ? 1 : 0.25)
                            .disabled((currentIndex ?? 0) == 0)

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
                            .buttonStyle(CharkleTactileButtonStyle())
                            .opacity((currentIndex ?? assets.count) < assets.count - 1 ? 1 : 0.25)
                            .disabled((currentIndex ?? assets.count) >= assets.count - 1)
                        }
                        .padding(.horizontal, 14)
                    }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            Divider()

            // Bottom Horizontal Filmstrip Scrubber (isolated from zoom/pan/rotation stage state)
            FilmstripScrubberBar(
                assets: assets,
                activeAssetID: currentAssetID,
                selectedAssetIDs: selectedAssetIDs,
                loader: loader,
                isQuickLookPresented: isQuickLookPresented,
                onSelectItem: { item in
                    selectFilmstripItem(item)
                },
                effectiveTargetIDs: { item in
                    effectiveTargetIDs(for: item)
                },
                contextMenuBuilder: { item in
                    assetContextMenu(for: item)
                }
            )
            .onChange(of: selectedAssetIDs) { _, newSelection in
                if newSelection.count == 1, let target = newSelection.first, focusedAssetID != target {
                    focusedAssetID = target
                }
            }
            .onChange(of: currentAssetID) { _, newID in
                resetViewTransform(animated: false)
                onFocusedAssetChanged?(newID)
                if let newID {
                    loadPreview(for: newID)
                    onMarkOpened(newID)
                } else {
                    previewLoadTask?.cancel()
                    previewLoadTask = nil
                    previewImage = nil
                    previewImageAssetID = nil
                    activeOriginalURL = nil
                }
            }
            .onAppear {
                if let first = currentAsset {
                    focusedAssetID = first.id
                    onFocusedAssetChanged?(first.id)
                    if selectedAssetIDs.isEmpty {
                        selectedAssetIDs = [first.id]
                    }
                    loadPreview(for: first.id)
                }
            }
            .onDisappear {
                previewLoadTask?.cancel()
                previewLoadTask = nil
                previewImage = nil
                previewImageAssetID = nil
                activeOriginalURL = nil
                onFocusedAssetChanged?(nil)
            }
        }
        .background(CanvasSurface.ground(for: colorScheme))
    }

    // MARK: - Rich Multi-Format Preview Stage

    @ViewBuilder
    private func stageMediaContent(for asset: AssetRecord) -> some View {
        if let repo = asset.richMetadata?.githubRepo {
            QuickLookGitHubRepoCard(asset: asset, repo: repo) {
                onRefreshRichAsset(asset.id)
            }
            .id(asset.id)
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
                },
                fallbackCoverImage: (previewImageAssetID == asset.id ? previewImage : nil)
                    ?? loader.cachedImage(for: asset.id, tier: .preview1400)
                    ?? loader.cachedImage(for: asset.id, tier: .grid520),
                isPlaybackSuspended: isQuickLookPresented
            )
            .id(asset.id)
            .padding(.vertical, 6)
        } else {
            switch asset.mediaKind {
            case .image, .designFile:
                zoomableVisualStage(for: asset)
            case .animatedImage:
                if let url = activeOriginalURL {
                    interactiveTransformContainer(for: asset) {
                        AnimatedGIFPlayerView(url: url)
                            .id(asset.id)
                            .clipShape(RoundedRectangle(cornerRadius: CharkleTheme.Radius.cardOuter, style: .continuous))
                    }
                } else {
                    zoomableVisualStage(for: asset)
                }
            case .video:
                if let url = activeOriginalURL {
                    QuickLookVideoPlayerView(
                        url: url,
                        autoPlay: !isQuickLookPresented,
                        isPlaybackSuspended: isQuickLookPresented
                    )
                        .id(asset.id)
                        .frame(maxWidth: 980, maxHeight: 560)
                        .clipShape(RoundedRectangle(cornerRadius: CharkleTheme.Radius.settingsOuter, style: .continuous))
                        .shadow(color: .black.opacity(colorScheme == .dark ? 0.42 : 0.14), radius: 22, y: 8)
                } else {
                    zoomableVisualStage(for: asset)
                }
            case .audio:
                QuickLookAudioStudioCard(
                    asset: asset,
                    fileURL: activeOriginalURL,
                    isPlaybackSuspended: isQuickLookPresented
                )
                    .id(asset.id)
                    .frame(maxWidth: 560)
            case .model3D:
                QuickLookModel3DViewer(asset: asset, originalURL: activeOriginalURL)
                    .id(asset.id)
                    .padding(.vertical, 6)
            case .document:
                if let url = activeOriginalURL, url.pathExtension.lowercased() == "pdf" {
                    QuickLookPDFView(url: url)
                        .id(asset.id)
                        .frame(maxWidth: 840, maxHeight: 620)
                        .clipShape(RoundedRectangle(cornerRadius: CharkleTheme.Radius.cardOuter, style: .continuous))
                        .shadow(color: .black.opacity(colorScheme == .dark ? 0.36 : 0.10), radius: 20, y: 8)
                } else if asset.fileName.lowercased().hasSuffix(".swatch") {
                    ProceduralMediaFallbackCard(asset: asset)
                        .frame(width: 380, height: 380)
                        .clipShape(RoundedRectangle(cornerRadius: CharkleTheme.Radius.popoverOuter, style: .continuous))
                        .shadow(color: .black.opacity(colorScheme == .dark ? 0.38 : 0.12), radius: 22, y: 8)
                } else {
                    QuickLookMarkdownReaderCard(asset: asset, originalURL: activeOriginalURL)
                        .id(asset.id)
                        .padding(.vertical, 6)
                }
            case .webBookmark:
                webBookmarkStageCard(for: asset)
            }
        }
    }

    @ViewBuilder
    private func zoomableVisualStage(for asset: AssetRecord) -> some View {
        let activePreview = (previewImageAssetID == asset.id) ? previewImage : nil
        interactiveTransformContainer(for: asset) {
            Group {
                if let img = activePreview {
                    Image(nsImage: img)
                        .resizable()
                        .interpolation(.high)
                        .aspectRatio(contentMode: .fit)
                        .clipShape(RoundedRectangle(cornerRadius: CharkleTheme.Radius.cardOuter, style: .continuous))
                } else {
                    AssetThumbnailSurface(
                        asset: asset,
                        loader: loader,
                        tier: .preview1400,
                        cornerRadius: CharkleTheme.Radius.cardOuter,
                        contentMode: .fit,
                        enableHoverPlayback: false
                    )
                }
            }
        }
    }

    private func interactiveTransformContainer<Content: View>(
        for asset: AssetRecord,
        @ViewBuilder content: () -> Content
    ) -> some View {
        content()
            .rotationEffect(.degrees(rotationDegrees))
            .scaleEffect(x: flipHorizontal ? -1 : 1, y: flipVertical ? -1 : 1)
            .scaleEffect(zoomScale * quarterTurnFitScale)
            .offset(panOffset)
            .shadow(color: .black.opacity(colorScheme == .dark ? 0.42 : 0.12), radius: 20, y: 8)
            .contentShape(Rectangle())
            .gesture(
                MagnifyGesture()
                    .onChanged { val in
                        if gestureStartScale == nil { gestureStartScale = zoomScale }
                        let next = max(0.5, min(maxZoomLimit, (gestureStartScale ?? 1.0) * val.magnification))
                        zoomScale = next
                        if next <= 1.01 {
                            panOffset = .zero
                            panStartOffset = .zero
                        }
                    }
                    .onEnded { _ in
                        gestureStartScale = nil
                        if zoomScale > 0.94 && zoomScale < 1.06 {
                            withAnimation(CharkleMotion.accessible(CharkleMotion.uiSpring, reduced: reduceMotion)) {
                                zoomScale = 1.0
                                panOffset = .zero
                                panStartOffset = .zero
                            }
                        }
                    }
            )
            .simultaneousGesture(
                DragGesture(minimumDistance: 2)
                    .onChanged { val in
                        guard zoomScale > 1.01 else { return }
                        panOffset = CGSize(
                            width: panStartOffset.width + val.translation.width,
                            height: panStartOffset.height + val.translation.height
                        )
                    }
                    .onEnded { _ in
                        guard zoomScale > 1.01 else { return }
                        panStartOffset = panOffset
                    }
            )
            .onTapGesture(count: 2) {
                withAnimation(CharkleMotion.accessible(CharkleMotion.uiSpring, reduced: reduceMotion)) {
                    if zoomScale > 1.1 {
                        zoomScale = 1.0
                        panOffset = .zero
                        panStartOffset = .zero
                    } else {
                        zoomScale = 2.0
                    }
                }
            }
    }

    private func webBookmarkStageCard(for asset: AssetRecord) -> some View {
        let activePreview = (previewImageAssetID == asset.id) ? previewImage : nil
        let webMeta = asset.richMetadata?.webPage
        let externalURL = asset.externalWebURL
        let hasStreamableVideo: Bool = {
            if let webMeta {
                if webMeta.hasVideo || webMeta.attachments.contains(where: { $0.kind == .video }) {
                    return true
                }
            }
            if let externalURL, VideoPlatformResolver.embedPlayer(for: externalURL) != nil {
                return true
            }
            return false
        }()

        return VStack(spacing: 0) {
            if hasStreamableVideo {
                let thumbURL = webMeta?.attachments.first(where: { $0.kind == .video })?.thumbnailURL.flatMap(URL.init(string:))
                    ?? webMeta?.attachments.first(where: { $0.kind == .photo }).flatMap { URL(string: $0.url) }
                let formattedDur: String? = {
                    guard let secs = webMeta?.durationSeconds ?? asset.durationSeconds, secs > 0 else { return nil }
                    let total = Int(secs.rounded())
                    let h = total / 3600
                    let m = (total % 3600) / 60
                    let s = total % 60
                    return h > 0 ? String(format: "%d:%02d:%02d", h, m, s) : String(format: "%d:%02d", m, s)
                }()
                QuickLookStreamingVideoView(
                    playbackKey: "filmstrip-web:\(asset.id.uuidString):\(asset.sourceURL ?? "")",
                    coverURL: thumbURL,
                    fallbackCoverImage: activePreview
                        ?? loader.cachedImage(for: asset.id, tier: .preview1400)
                        ?? loader.cachedImage(for: asset.id, tier: .grid520),
                    durationText: formattedDur,
                    watchURL: externalURL,
                    openActionLabel: "在默认浏览器中打开",
                    isPlaybackSuspended: isQuickLookPresented,
                    resolvePlan: {
                        if let webMeta {
                            return await VideoPlatformResolver.resolveWebPagePlaybackPlan(
                                for: webMeta,
                                fallbackURL: externalURL
                            )
                        }
                        let embed = externalURL.flatMap { VideoPlatformResolver.embedPlayer(for: $0) }
                        return VideoStreamPlaybackPlan(directStreams: [], embedPlayer: embed, watchURL: externalURL)
                    }
                )
                .aspectRatio(16.0 / 9.0, contentMode: .fit)
                .frame(maxWidth: 780)
            } else {
                ZStack(alignment: .bottomTrailing) {
                    Group {
                        if let img = activePreview {
                            Image(nsImage: img)
                                .resizable()
                                .interpolation(.high)
                                .aspectRatio(contentMode: .fit)
                        } else {
                            AssetThumbnailSurface(
                                asset: asset,
                                loader: loader,
                                tier: .preview1400,
                                cornerRadius: 0,
                                contentMode: .fit,
                                enableHoverPlayback: false
                            )
                        }
                    }
                    .frame(maxWidth: 780, maxHeight: 440)
                    .background(CharkleTheme.surfaceElevated(for: colorScheme))
                    .contentShape(Rectangle())
                    .onTapGesture {
                        onOpenQuickLook(asset)
                    }

                    if externalURL != nil {
                        Button {
                            onOpenQuickLook(asset)
                        } label: {
                            Label("在默认浏览器中打开", systemImage: "safari")
                                .font(CharkleTheme.text(.caption, weight: .semibold))
                                .padding(.horizontal, 12)
                                .padding(.vertical, 6)
                        }
                        .buttonStyle(.borderedProminent)
                        .padding(14)
                    }
                }
            }

            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 8) {
                    Circle()
                        .fill(Color(charkleHex: asset.dominantColors.first?.hex ?? "#5C6B73"))
                        .frame(width: 9, height: 9)
                    Text(asset.sourceDomain ?? "网页书签")
                        .font(CharkleTheme.text(.caption, weight: .semibold, design: .monospaced))
                        .foregroundStyle(.secondary)
                    Spacer()
                    if let urlStr = asset.sourceURL {
                        Text(urlStr)
                            .font(CharkleTheme.text(.caption, design: .monospaced))
                            .foregroundStyle(.tertiary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                }
                Text(asset.title)
                    .font(CharkleTheme.text(.headline, weight: .semibold))
                    .lineLimit(2)
                if !asset.notes.isEmpty {
                    Text(asset.notes)
                        .font(CharkleTheme.text(.body))
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 14)
            .frame(maxWidth: 780, alignment: .leading)
            .background(CharkleTheme.surfaceElevated(for: colorScheme))
        }
        .clipShape(RoundedRectangle(cornerRadius: CharkleTheme.Radius.popoverOuter, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: CharkleTheme.Radius.popoverOuter, style: .continuous)
                .strokeBorder(CharkleTheme.hairline(for: colorScheme), lineWidth: CharkleTheme.hairlineWidth)
        )
        .shadow(color: .black.opacity(colorScheme == .dark ? 0.34 : 0.10), radius: 20, y: 8)
    }

    // MARK: - Preview Controls & Metadata Bar

    private func previewControlAndMetadataBar(
        for asset: AssetRecord,
        activeIndex: Int?,
        supportsTransform: Bool
    ) -> some View {
        VStack(spacing: 8) {
            // Direct Preview Controls Pill (Zoom, Rotate, Flip, Reset, QuickLook)
            if supportsTransform {
                CharkleGlassContainer(spacing: 8) {
                    HStack(spacing: 6) {
                        // Zoom Controls
                        HStack(spacing: 2) {
                            controlIconButton("minus.magnifyingglass", help: "缩小 (-)") {
                                stepZoom(by: 0.8)
                            }
                            Button {
                                resetViewTransform(animated: true)
                            } label: {
                                Text("\(Int((zoomScale * 100).rounded()))%")
                                    .font(CharkleTheme.text(.caption, weight: .semibold, design: .monospaced))
                                    .monospacedDigit()
                                    .foregroundStyle(.primary.opacity(0.88))
                                    .frame(minWidth: 42)
                                    .padding(.vertical, 4)
                                    .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .help("点击复位到 100% (0)")

                            controlIconButton("plus.magnifyingglass", help: "放大 (+)") {
                                stepZoom(by: 1.25)
                            }
                            controlIconButton("1.magnifyingglass", help: "重置缩放与变换 (0)") {
                                resetViewTransform(animated: true)
                            }
                        }

                        controlDivider

                        // Rotate & Flip Controls
                        HStack(spacing: 2) {
                            controlIconButton("rotate.left", help: "逆时针旋转 90° (⇧R)") {
                                rotatePreview(by: -90)
                            }
                            controlIconButton("rotate.right", help: "顺时针旋转 90° (R)") {
                                rotatePreview(by: 90)
                            }
                            controlIconButton(
                                "arrow.left.and.right.righttriangle.left.righttriangle.right",
                                help: "水平翻转 (⇧H)",
                                isActive: flipHorizontal
                            ) {
                                toggleFlip(horizontal: true)
                            }
                            controlIconButton(
                                "arrow.up.and.down.righttriangle.up.righttriangle.down",
                                help: "上下翻转 (⇧V)",
                                isActive: flipVertical
                            ) {
                                toggleFlip(horizontal: false)
                            }

                            if hasAnyTransformOrZoom {
                                Button {
                                    resetViewTransform(animated: true)
                                } label: {
                                    HStack(spacing: 3) {
                                        if displayRotationDegrees != 0 {
                                            Text("\(displayRotationDegrees)°")
                                                .font(CharkleTheme.text(.caption, weight: .semibold, design: .monospaced))
                                                .monospacedDigit()
                                        }
                                        Image(systemName: "arrow.uturn.backward")
                                            .font(.system(size: 9.5, weight: .semibold))
                                    }
                                    .foregroundStyle(.white)
                                    .padding(.horizontal, 7)
                                    .padding(.vertical, 4)
                                    .background(Color.accentColor, in: RoundedRectangle(cornerRadius: CharkleTheme.Radius.chip, style: .continuous))
                                }
                                .buttonStyle(CharkleTactileButtonStyle())
                                .help("还原全部视图变换 (0)")
                                .transition(CharkleMotion.originTransition(anchor: .trailing, scale: 0.94, reduced: reduceMotion))
                            }
                        }
                        .animation(CharkleMotion.accessible(CharkleMotion.settleStrong, reduced: reduceMotion), value: hasAnyTransformOrZoom)

                        controlDivider

                        Button {
                            onOpenQuickLook(asset)
                        } label: {
                            HStack(spacing: 4) {
                                CharkleIcon("quicklook", style: .duotone, size: 13.5)
                                Text("沉浸预览")
                                    .font(CharkleTheme.text(.caption, weight: .medium))
                            }
                            .padding(.horizontal, 8)
                            .padding(.vertical, 4)
                            .contentShape(Capsule())
                        }
                        .buttonStyle(CharkleTactileButtonStyle())
                        .help("全屏沉浸预览 (Space)")
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 5)
                    .charkleLiquidGlass(.regular, in: Capsule(style: .continuous))
                }
            }

            // Compact Metadata & Star Rating Strip
            HStack(spacing: 12) {
                Text(asset.title)
                    .font(CharkleTheme.text(.body, weight: .semibold))
                    .lineLimit(1)

                if asset.pixelWidth > 0 && asset.pixelHeight > 0 {
                    Text("\(asset.pixelWidth) × \(asset.pixelHeight)")
                        .font(CharkleTheme.text(.caption, design: .monospaced))
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                }

                if let idx = activeIndex {
                    Text("\(idx + 1) / \(assets.count)")
                        .font(CharkleTheme.text(.caption, weight: .medium, design: .rounded))
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 7)
                        .padding(.vertical, 2)
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
                                .scaleEffect(star == asset.rating && !reduceMotion ? 1.08 : 1.0)
                                .animation(CharkleMotion.accessible(CharkleMotion.microOvershoot, reduced: reduceMotion), value: asset.rating)
                        }
                        .buttonStyle(.plain)
                    }
                }

                if !supportsVisualTransform {
                    Button {
                        onOpenQuickLook(asset)
                    } label: {
                        HStack(spacing: 4) {
                            CharkleIcon("quicklook", style: .duotone, size: 13.5)
                            Text("沉浸预览")
                                .font(CharkleTheme.text(.caption, weight: .medium))
                        }
                        .padding(.horizontal, 9)
                        .padding(.vertical, 4)
                        .background(Color.primary.opacity(0.06), in: Capsule(style: .continuous))
                    }
                    .buttonStyle(CharkleTactileButtonStyle())
                }
            }
        }
    }

    private func controlIconButton(
        _ systemName: String,
        help: String,
        isActive: Bool = false,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: 12.5, weight: .medium))
                .foregroundStyle(isActive ? Color.white : Color.primary.opacity(0.84))
                .frame(width: 26, height: 26)
                .background(
                    isActive ? Color.accentColor : Color.clear,
                    in: RoundedRectangle(cornerRadius: CharkleTheme.Radius.chip, style: .continuous)
                )
                .contentShape(RoundedRectangle(cornerRadius: CharkleTheme.Radius.chip, style: .continuous))
        }
        .buttonStyle(CharkleTactileButtonStyle())
        .help(help)
    }

    private var controlDivider: some View {
        Rectangle()
            .fill(Color.primary.opacity(0.14))
            .frame(width: 1, height: 15)
            .padding(.horizontal, 2)
    }

    // MARK: - Full Right-Click Context Menu

    private func effectiveTargetIDs(for item: AssetRecord) -> [UUID] {
        guard selectedAssetIDs.contains(item.id), !selectedAssetIDs.isEmpty else {
            return [item.id]
        }
        var ordered: [UUID] = [item.id]
        ordered.reserveCapacity(selectedAssetIDs.count)
        for asset in assets where asset.id != item.id && selectedAssetIDs.contains(asset.id) {
            ordered.append(asset.id)
        }
        return ordered
    }

    @ViewBuilder
    private func assetContextMenu(for item: AssetRecord) -> some View {
        let targetIDs = effectiveTargetIDs(for: item)
        let countSuffix = targetIDs.count > 1 ? " (\(targetIDs.count) 项)" : ""

        if item.isExternalWebLink {
            Button {
                onOpenQuickLook(item)
            } label: {
                Label("在默认浏览器中打开", systemImage: "safari")
            }
        } else {
            Button {
                onOpenQuickLook(item)
            } label: {
                Label("沉浸预览", systemImage: "eye")
            }

            if let urlStr = item.sourceURL, let webURL = URL(string: urlStr) {
                Button {
                    NSWorkspace.shared.open(webURL)
                } label: {
                    Label("打开来源网页", systemImage: "safari")
                }
            }
        }

        Divider()

        Button {
            onCopyAssets(targetIDs)
        } label: {
            Label("拷贝\(countSuffix)", systemImage: "doc.on.doc")
        }

        if !item.isTrashed {
            Button {
                onCutAssets(targetIDs)
            } label: {
                Label("剪切\(countSuffix)", systemImage: "scissors")
            }
        }

        Button {
            onRevealInFinder(item.id)
        } label: {
            Label("在访达中显示", systemImage: "folder")
        }

        Divider()

        if !item.isTrashed {
            if let activeID = activeMoodboardID ?? boards.first?.id {
                Button {
                    onAddToMoodboard(targetIDs, activeID)
                } label: {
                    Label("加入活跃情绪板\(countSuffix)", systemImage: "rectangle.stack.badge.plus")
                }
            }

            if !boards.isEmpty {
                Menu {
                    ForEach(boards) { board in
                        Button(board.title) {
                            onAddToMoodboard(targetIDs, board.id)
                        }
                    }
                } label: {
                    Label("加入指定情绪板", systemImage: "rectangle.3.group")
                }
            }

            Menu {
                CharkleHierarchicalFolderMenuContent(
                    folders: folders,
                    includeInbox: true,
                    selectedFolderID: targetIDs.count == 1 ? item.folderID : nil,
                    highlightSelection: targetIDs.count == 1,
                    parentSelfPrefix: "放入"
                ) { folderID in
                    onMoveToFolder(targetIDs, folderID)
                }
            } label: {
                Label("移动到文件夹\(countSuffix)", systemImage: "folder.badge.plus")
            }

            Button {
                onTogglePinOffline(targetIDs, !item.pinnedOffline)
            } label: {
                Label(
                    item.pinnedOffline ? "取消始终保留在本地\(countSuffix)" : "始终保留在本地\(countSuffix)",
                    systemImage: item.pinnedOffline ? "icloud" : "arrow.down.circle"
                )
            }

            Button {
                onRetagAssets(targetIDs)
            } label: {
                Label("AI 重新打标\(countSuffix)", systemImage: "sparkles")
            }

            Divider()

            Button(role: .destructive) {
                onTrashAssets(targetIDs)
            } label: {
                Label("移至废纸篓\(countSuffix)", systemImage: "trash")
            }
        } else {
            Button {
                onRestoreAssets(targetIDs)
            } label: {
                Label("放回原处\(countSuffix)", systemImage: "arrow.uturn.backward")
            }

            Button(role: .destructive) {
                onPermanentlyDeleteAssets(targetIDs)
            } label: {
                Label("彻底删除\(countSuffix)", systemImage: "trash.slash")
            }
        }
    }

    // MARK: - Transform, Zoom & Keyboard Actions

    private func applyWheelZoom(factor: CGFloat) {
        guard supportsVisualTransform else { return }
        let ceiling = maxZoomLimit
        let next = max(0.5, min(ceiling, zoomScale * factor))
        zoomScale = next
        if next <= 1.01 {
            panOffset = .zero
            panStartOffset = .zero
        }
    }

    private var maxZoomLimit: CGFloat {
        guard let asset = activeAsset else { return 6.0 }
        let longest = max(asset.pixelWidth, asset.pixelHeight)
        return max(6.0, min(16.0, CGFloat(longest) / 550.0))
    }

    private func stepZoom(by factor: CGFloat) {
        guard supportsVisualTransform else { return }
        let ceiling = maxZoomLimit
        withAnimation(CharkleMotion.accessible(CharkleMotion.uiSpring, reduced: reduceMotion)) {
            let next = max(0.5, min(ceiling, zoomScale * factor))
            zoomScale = next
            if next <= 1.01 {
                panOffset = .zero
                panStartOffset = .zero
            }
        }
    }

    private func rotatePreview(by screenDelta: Double) {
        guard supportsVisualTransform else { return }
        // Screen-space flip wraps inner rotation: R(Δ) * S * R(θ) = S * R(θ + sx*sy*Δ)
        let parity: Double = (flipHorizontal != flipVertical) ? -1.0 : 1.0
        withAnimation(CharkleMotion.accessible(CharkleMotion.settleStrong, reduced: reduceMotion)) {
            rotationDegrees += screenDelta * parity
        }
    }

    private func toggleFlip(horizontal: Bool) {
        guard supportsVisualTransform else { return }
        withAnimation(CharkleMotion.accessible(CharkleMotion.settleStrong, reduced: reduceMotion)) {
            if horizontal {
                flipHorizontal.toggle()
            } else {
                flipVertical.toggle()
            }
        }
    }

    private func resetViewTransform(animated: Bool) {
        let apply = {
            zoomScale = 1.0
            panOffset = .zero
            panStartOffset = .zero
            rotationDegrees = 0
            flipHorizontal = false
            flipVertical = false
        }
        if animated {
            withAnimation(CharkleMotion.accessible(CharkleMotion.uiSpring, reduced: reduceMotion)) {
                apply()
            }
        } else {
            apply()
        }
    }

    private func handleStageKeyDown(_ event: NSEvent) -> NSEvent? {
        guard !isQuickLookPresented else { return event }
        if let window = event.window {
            if window.attachedSheet != nil || NSApp.modalWindow != nil { return event }
            if let responder = window.firstResponder,
               responder is NSTextView || responder is NSTextField || responder is NSText {
                return event
            }
        }
        // Explicitly ignore Caps Lock, NumPad, and Function flags so arrows and Space always respond.
        let primaryModifiers = event.modifierFlags.intersection([.command, .option, .control, .shift])
        let isUnmodified = primaryModifiers.isEmpty
        let isShiftOnly = primaryModifiers == .shift

        if isUnmodified {
            switch event.keyCode {
            case 49: // Space -> open Quick Look for active filmstrip asset
                if event.isARepeat { return nil }
                if let asset = activeAsset {
                    onOpenQuickLook(asset)
                    return nil
                }
            case 123: // Left Arrow
                step(by: -1)
                return nil
            case 124: // Right Arrow
                step(by: 1)
                return nil
            default:
                break
            }
        }

        if supportsVisualTransform, let chars = event.charactersIgnoringModifiers?.lowercased() {
            if isUnmodified && chars == "r" {
                rotatePreview(by: 90)
                return nil
            }
            if isShiftOnly && chars == "r" {
                rotatePreview(by: -90)
                return nil
            }
            if isShiftOnly && chars == "h" {
                toggleFlip(horizontal: true)
                return nil
            }
            if isShiftOnly && chars == "v" {
                toggleFlip(horizontal: false)
                return nil
            }
            if isUnmodified && chars == "0" {
                resetViewTransform(animated: true)
                return nil
            }
            if (isUnmodified || isShiftOnly) && (chars == "+" || chars == "=") {
                stepZoom(by: 1.25)
                return nil
            }
            if isUnmodified && chars == "-" {
                stepZoom(by: 0.8)
                return nil
            }
        }
        return event
    }

    private func selectFilmstripItem(_ item: AssetRecord) {
        let mods = NSEvent.modifierFlags
        // Capture anchor BEFORE updating `focusedAssetID` (which `activeIndex` reads!)
        let previousAnchor = activeIndex
        focusedAssetID = item.id
        if mods.contains(.command) {
            if selectedAssetIDs.contains(item.id) {
                selectedAssetIDs.remove(item.id)
            } else {
                selectedAssetIDs.insert(item.id)
            }
        } else if mods.contains(.shift), let anchor = previousAnchor, let target = assets.firstIndex(where: { $0.id == item.id }) {
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
        if let cachedOrig = loader.cachedOriginalImage(for: id) {
            previewImageAssetID = id
            previewImage = cachedOrig
        } else if let cached = loader.cachedImage(for: id, tier: .preview1400) ?? loader.cachedImage(for: id, tier: .grid520) {
            previewImageAssetID = id
            previewImage = cached
        } else {
            previewImageAssetID = nil
            previewImage = nil
        }
        let targetIdx = assets.firstIndex(where: { $0.id == id })
        let targetAsset = targetIdx.map { assets[$0] }
        if let center = targetIdx {
            let lo = max(0, center - 6)
            let hi = min(assets.count - 1, center + 6)
            if lo <= hi {
                let neighborIDs = (lo...hi).compactMap { idx -> UUID? in
                    let candidate = assets[idx].id
                    return candidate == id ? nil : candidate
                }
                if !neighborIDs.isEmpty {
                    loader.prefetch(assetIDs: neighborIDs, tier: .grid520)
                }
            }
        }
        previewLoadTask = Task {
            let orig = await resolveOriginalURL(id)
            guard !Task.isCancelled else { return }
            activeOriginalURL = orig

            let wantsOriginalRaster = targetAsset.map {
                !$0.isGitHubRepo && !$0.isSocialPost && ($0.mediaKind == .image || $0.mediaKind == .designFile)
            } ?? true

            if wantsOriginalRaster, let orig,
               let fullImage = await loader.loadOriginalImage(for: id, url: orig) {
                guard !Task.isCancelled else { return }
                previewImageAssetID = id
                previewImage = fullImage
                return
            }

            if let img = await loader.loadImage(for: id, tier: .preview1400) {
                guard !Task.isCancelled else { return }
                previewImageAssetID = id
                previewImage = img
            }
        }
    }
}

/// Isolated bottom filmstrip scrubber so stage zoom/pan/rotation ticks never re-evaluate
/// the horizontal `LazyHStack` cells and each cell performs an O(1) `activeAssetID == item.id` check.
private struct FilmstripScrubberBar<ContextMenuContent: View>: View {
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    let assets: [AssetRecord]
    let activeAssetID: UUID?
    let selectedAssetIDs: Set<UUID>
    let loader: ThumbnailImageLoader
    let isQuickLookPresented: Bool
    let onSelectItem: (AssetRecord) -> Void
    let effectiveTargetIDs: (AssetRecord) -> [UUID]
    @ViewBuilder let contextMenuBuilder: (AssetRecord) -> ContextMenuContent

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(spacing: 8) {
                    ForEach(assets) { item in
                        cell(for: item)
                    }
                }
                .padding(.horizontal, 18)
                .padding(.vertical, 12)
            }
            .background(HorizontalWheelScrollRedirector())
            .frame(height: 96)
            .background(CharkleTheme.surfaceElevated(for: colorScheme).opacity(0.86))
            .onChange(of: activeAssetID) { _, newID in
                guard let newID else { return }
                withAnimation(CharkleMotion.accessible(CharkleMotion.settleStrong, reduced: reduceMotion)) {
                    proxy.scrollTo(newID, anchor: .center)
                }
            }
        }
    }

    private func cell(for item: AssetRecord) -> some View {
        let isFocused = activeAssetID == item.id
        let isSelected = selectedAssetIDs.contains(item.id)
        let thumbW: CGFloat = max(46, min(116, 68 * CGFloat(max(0.6, min(1.75, item.aspectRatio)))))
        let thumbRadius = CharkleTheme.Radius.concentricInner(outer: CharkleTheme.Radius.popoverOuter, padding: 8)

        return AssetThumbnailSurface(
            asset: item,
            loader: loader,
            tier: .grid520,
            cornerRadius: thumbRadius,
            contentMode: .fill,
            enableHoverPlayback: !isQuickLookPresented
        )
        .frame(width: thumbW, height: 68)
        .overlay(
            RoundedRectangle(cornerRadius: thumbRadius, style: .continuous)
                .strokeBorder(
                    isFocused ? Color.accentColor : (isSelected ? Color.accentColor.opacity(0.65) : Color.primary.opacity(0.12)),
                    lineWidth: isFocused ? 2.5 : (isSelected ? 1.5 : CharkleTheme.hairlineWidth)
                )
        )
        .scaleEffect(isFocused && !reduceMotion ? 1.04 : 1.0)
        .animation(CharkleMotion.accessible(CharkleMotion.settleStrong, reduced: reduceMotion), value: isFocused)
        .contentShape(RoundedRectangle(cornerRadius: thumbRadius, style: .continuous))
        .onTapGesture {
            onSelectItem(item)
        }
        .contextMenu {
            contextMenuBuilder(item)
        }
        .id(item.id)
        .onDrag {
            let ids = effectiveTargetIDs(item)
            let provider = NSItemProvider()
            let encoded = CharkleDragIdentifiers.encode(assetIDs: ids)
            provider.registerDataRepresentation(forTypeIdentifier: UTType.plainText.identifier, visibility: .all) { completion in
                completion(Data(encoded.utf8), nil)
                return nil
            }
            // Use data representation for UTType.fileURL (avoid registerFileRepresentation(.fileURL) which
            // triggers nil URL bridging SIGTRAP inside SwiftUI PasteboardUtility.loadFileSystemItem on macOS 26/27).
            if let fileURL = loader.cachedDragFileURL(for: item),
               fileURL.isFileURL,
               FileManager.default.fileExists(atPath: fileURL.path) {
                provider.registerDataRepresentation(forTypeIdentifier: UTType.fileURL.identifier, visibility: .all) { completion in
                    completion(fileURL.dataRepresentation, nil)
                    return nil
                }
            }
            return provider
        }
    }
}
