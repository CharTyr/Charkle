import AppKit
import AVKit
import CharkleCanvas
import CharkleCore
import PDFKit
import SwiftUI

/// Full-Media Quick Look (`Space` to open/close) with continuous card-to-overlay hero zoom,
/// soft blurred low-saturation ambient backdrop, floating Apple Liquid Glass bottom HUD controls,
/// and dedicated playback/inspection for all 7 `MediaKind`s.
public struct QuickLookOverlayView: View {
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.charkleAccentSource) private var accentSource
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    public let asset: AssetRecord
    public let library: LibraryStore
    public let moodboards: MoodboardStore
    public let coordinator: AppCoordinatorStore
    public let heroNamespace: Namespace.ID
    public let onClose: () -> Void
    public let onStep: (Int) -> Void
    public let onCopyHex: (String) -> Void
    public let onFilterByColor: (String) -> Void

    @State private var originalURL: URL?
    @State private var highResImage: NSImage?
    @State private var isLoadingOriginalImage: Bool = false
    @State private var isLongStripScrollMode: Bool = false
    @State private var stageAppeared: Bool = false
    @State private var backdropVisible: Bool = false
    @State private var isDismissing: Bool = false
    @State private var connectedSourceRect: CGRect?
    @State private var dismissTargetRect: CGRect?
    @State private var dismissTask: Task<Void, Never>?
    @State private var zoomScale: CGFloat = 1.0
    @State private var gestureStartScale: CGFloat?
    @State private var panOffset: CGSize = .zero
    @State private var panStartOffset: CGSize = .zero
    @State private var rotationDegrees: Double = 0
    @State private var flipHorizontal: Bool = false
    @State private var flipVertical: Bool = false
    @State private var stageViewportSize: CGSize = CGSize(width: 960, height: 640)
    @State private var stageCenterInWindow: CGPoint = .zero
    @State private var showSecondaryControls: Bool = false
    @State private var confirmPermanentDelete: Bool = false
    @State private var overlayWidth: CGFloat = 1280
    @State private var liveDraggedInspectorWidth: CGFloat? = nil
    @State private var inspectorDragStartWidth: CGFloat = AppCoordinatorStore.defaultInspectorWidth
    @State private var isInspectorDividerHovered: Bool = false
    @State private var isDraggingInspectorDivider: Bool = false
    @State private var localVideoCaptureBridge = StreamingFrameCaptureBridge()
    @State private var isCapturingCoverFrame: Bool = false

    private var activeAccent: Color {
        CharkleTheme.accent(for: colorScheme, source: accentSource)
    }

    private var effectiveInspectorWidth: CGFloat {
        AppCoordinatorStore.clampedInspectorWidth(
            liveDraggedInspectorWidth ?? coordinator.inspectorWidth,
            windowWidth: overlayWidth,
            sidebarOccupiedWidth: 0
        )
    }

    private var supportsVisualTransform: Bool {
        !asset.isGitHubRepo && !asset.isSocialPost
            && (asset.mediaKind == .image || asset.mediaKind == .designFile || asset.mediaKind == .animatedImage)
    }

    private var isTallStripImage: Bool {
        guard !asset.isGitHubRepo && !asset.isSocialPost,
              asset.mediaKind == .image || asset.mediaKind == .designFile,
              asset.pixelWidth > 0, asset.pixelHeight >= 1600 else {
            return false
        }
        return Double(asset.pixelHeight) / Double(asset.pixelWidth) >= 2.2
    }

    private var maxZoomLimit: CGFloat {
        let longest = max(asset.pixelWidth, asset.pixelHeight)
        return max(6.0, min(16.0, CGFloat(longest) / 550.0))
    }

    private var displayRotationDegrees: Int {
        let raw = Int(rotationDegrees.rounded()) % 360
        return raw < 0 ? raw + 360 : raw
    }

    private var hasActiveVisualTransform: Bool {
        displayRotationDegrees != 0 || flipHorizontal || flipVertical
    }

    /// Ensures a landscape/portrait image rotated ±90° scales smoothly to stay within the stage bounds.
    private var quarterTurnFitScale: CGFloat {
        guard displayRotationDegrees == 90 || displayRotationDegrees == 270 else { return 1.0 }
        let availW = max(120, stageViewportSize.width)
        let availH = max(120, stageViewportSize.height)
        let naturalRatio: CGFloat = {
            if let img = highResImage ?? library.thumbnailLoader.cachedImage(for: asset.id, tier: .grid520),
               img.size.height > 0 {
                return img.size.width / img.size.height
            }
            return CGFloat(max(0.2, asset.aspectRatio))
        }()
        // Unrotated fitted size inside (availW, availH)
        let fittedW: CGFloat
        let fittedH: CGFloat
        if availW / availH > naturalRatio {
            fittedH = availH
            fittedW = fittedH * naturalRatio
        } else {
            fittedW = availW
            fittedH = fittedW / naturalRatio
        }
        // After 90° rotation, bounding box becomes (fittedH, fittedW)
        let scale = min(availW / max(1, fittedH), availH / max(1, fittedW))
        return max(0.25, min(1.0, scale))
    }

    public init(
        asset: AssetRecord,
        library: LibraryStore,
        moodboards: MoodboardStore,
        coordinator: AppCoordinatorStore,
        heroNamespace: Namespace.ID,
        onClose: @escaping () -> Void,
        onStep: @escaping (Int) -> Void,
        onCopyHex: @escaping (String) -> Void = { _ in },
        onFilterByColor: @escaping (String) -> Void = { _ in }
    ) {
        self.asset = asset
        self.library = library
        self.moodboards = moodboards
        self.coordinator = coordinator
        self.heroNamespace = heroNamespace
        self.onClose = onClose
        self.onStep = onStep
        self.onCopyHex = onCopyHex
        self.onFilterByColor = onFilterByColor
        _connectedSourceRect = State(
            initialValue: MasonryCardGeometryRegistry.shared.visibleCardRectInWindow(for: asset.id)
        )
    }

    private var quickLookInspectorResizeDivider: some View {
        ZStack {
            Rectangle()
                .fill(CharkleTheme.hairline(for: colorScheme))
                .frame(width: 1)

            if isDraggingInspectorDivider || isInspectorDividerHovered {
                Rectangle()
                    .fill(
                        isDraggingInspectorDivider
                            ? activeAccent.opacity(0.75)
                            : Color.primary.opacity(colorScheme == .dark ? 0.24 : 0.16)
                    )
                    .frame(width: 2)
                    .allowsHitTesting(false)
            }
        }
        .frame(width: 1)
        .frame(minHeight: 0, maxHeight: .infinity)
        .overlay {
            PaneResizeHandleView(
                onHoverChanged: { hovering in
                    if isInspectorDividerHovered != hovering {
                        isInspectorDividerHovered = hovering
                    }
                },
                onDragBegan: {
                    isDraggingInspectorDivider = true
                    inspectorDragStartWidth = effectiveInspectorWidth
                },
                onDragChanged: { deltaX in
                    let raw = inspectorDragStartWidth - deltaX
                    liveDraggedInspectorWidth = AppCoordinatorStore.clampedInspectorWidth(
                        raw,
                        windowWidth: overlayWidth,
                        sidebarOccupiedWidth: 0
                    )
                },
                onDragEnded: {
                    if let finalWidth = liveDraggedInspectorWidth {
                        coordinator.inspectorWidth = finalWidth
                    }
                    liveDraggedInspectorWidth = nil
                    isDraggingInspectorDivider = false
                },
                onDoubleClick: {
                    let target = AppCoordinatorStore.clampedInspectorWidth(
                        AppCoordinatorStore.defaultInspectorWidth,
                        windowWidth: overlayWidth,
                        sidebarOccupiedWidth: 0
                    )
                    withAnimation(CharkleMotion.accessible(CharkleMotion.drawerEase, reduced: reduceMotion)) {
                        liveDraggedInspectorWidth = nil
                        coordinator.inspectorWidth = target
                    }
                }
            )
            .frame(width: 9)
        }
        .animation(CharkleMotion.accessible(CharkleMotion.hoverPress, reduced: reduceMotion), value: isInspectorDividerHovered)
        .animation(CharkleMotion.accessible(CharkleMotion.hoverPress, reduced: reduceMotion), value: isDraggingInspectorDivider)
    }

    private var activeConnectedRect: CGRect? {
        isDismissing ? dismissTargetRect : connectedSourceRect
    }

    private func estimatedFittedStageSize() -> CGSize {
        let availW = max(160, stageViewportSize.width - (coordinator.isInspectorVisible ? 56 : 96))
        let availH = max(160, stageViewportSize.height)
        if asset.isGitHubRepo || asset.isSocialPost || asset.mediaKind == .document {
            return CGSize(width: min(740, availW), height: min(640, availH))
        }
        let ratio = CGFloat(max(0.25, min(4.0, asset.aspectRatio)))
        if availW / availH > ratio {
            return CGSize(width: availH * ratio, height: availH)
        } else {
            return CGSize(width: availW, height: availW / ratio)
        }
    }

    private func resolvedStageCenter() -> CGPoint {
        if stageCenterInWindow.x > 40, stageCenterInWindow.y > 40 {
            return stageCenterInWindow
        }
        if let bounds = NSApp.keyWindow?.contentView?.bounds, bounds.width > 0, bounds.height > 0 {
            let stageWidth = max(200, bounds.width - (coordinator.isInspectorVisible ? (effectiveInspectorWidth + 1) : 0))
            return CGPoint(x: stageWidth * 0.5, y: bounds.height * 0.5)
        }
        return CGPoint(x: stageViewportSize.width * 0.5, y: stageViewportSize.height * 0.5)
    }

    private var collapsedStageScale: CGFloat {
        guard !reduceMotion else { return 1.0 }
        guard let rect = activeConnectedRect, rect.width > 24, rect.height > 24 else {
            return 0.94
        }
        let fitted = estimatedFittedStageSize()
        let rawScale = min(rect.width / max(1, fitted.width), rect.height / max(1, fitted.height))
        return max(0.36, min(0.94, rawScale))
    }

    private var collapsedStageOffset: CGSize {
        guard !reduceMotion, let rect = activeConnectedRect, rect.width > 24, rect.height > 24 else {
            return .zero
        }
        let center = resolvedStageCenter()
        return CGSize(
            width: rect.midX - center.x,
            height: rect.midY - center.y
        )
    }

    private func performDismiss() {
        guard !isDismissing else { return }
        isDismissing = true
        dismissTask?.cancel()

        if reduceMotion {
            onClose()
            return
        }

        let canFlyBack = zoomScale <= 1.05 && !hasActiveVisualTransform && !isLongStripScrollMode
        dismissTargetRect = canFlyBack
            ? MasonryCardGeometryRegistry.shared.visibleCardRectInWindow(for: asset.id)
            : nil

        withAnimation(CharkleMotion.exitSm) {
            stageAppeared = false
            showSecondaryControls = false
            backdropVisible = false
        }

        dismissTask = Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(125))
            guard !Task.isCancelled else { return }
            onClose()
        }
    }

    public var body: some View {
        HStack(spacing: 0) {
            ZStack {
                // Soft blurred neutral ambient backdrop (zero visual color distortion)
                ZStack {
                    (colorScheme == .dark ? Color.black.opacity(0.76) : Color(charkleHex: "#151619").opacity(0.68))
                    CharkleTheme.ambientTint(from: asset.dominantColors.first?.hex, scheme: .dark)
                }
                .opacity(backdropVisible ? 1.0 : 0.0)
                .ignoresSafeArea()
                .onTapGesture { performDismiss() }

                // Hero Media Stage
                VStack(spacing: 0) {
                    // Top minimal title bar (clears macOS window traffic lights on the leading edge
                    // and aligns vertically with Quick Look's right-hand Inspector header)
                    HStack(spacing: 10) {
                        Text(asset.title)
                            .font(.system(size: 13.5, weight: .semibold))
                            .foregroundStyle(.white.opacity(0.94))
                            .lineLimit(1)
                            .truncationMode(.middle)

                        Text("\(asset.pixelWidth) × \(asset.pixelHeight) · \(asset.mediaKind.localizedLabel)")
                            .font(.system(size: 11, weight: .medium, design: .monospaced))
                            .monospacedDigit()
                            .foregroundStyle(.white.opacity(0.62))
                            .fixedSize(horizontal: true, vertical: false)

                        Spacer(minLength: 12)

                        Button {
                            withAnimation(CharkleMotion.accessible(CharkleMotion.drawerEase, reduced: reduceMotion)) {
                                coordinator.isInspectorVisible.toggle()
                            }
                        } label: {
                            Image(systemName: "sidebar.right")
                                .font(.system(size: 12, weight: .semibold))
                                .foregroundStyle(
                                    coordinator.isInspectorVisible
                                        ? CharkleTheme.accent(for: .dark, source: accentSource)
                                        : .white.opacity(0.86)
                                )
                                .frame(width: 28, height: 28)
                                .charkleLiquidGlass(.darkNotch, in: Circle(), interactive: true)
                        }
                        .buttonStyle(CharkleTactileButtonStyle())
                        .help("显示 / 隐藏右侧详情栏 (⌘⌥I)")

                        Button(action: performDismiss) {
                            Image(systemName: "xmark")
                                .font(.system(size: 11, weight: .bold))
                                .foregroundStyle(.white.opacity(0.86))
                                .frame(width: 28, height: 28)
                                .charkleLiquidGlass(.darkNotch, in: Circle(), interactive: true)
                        }
                        .buttonStyle(CharkleTactileButtonStyle())
                        .help("关闭预览 (Space / Esc)")
                    }
                    .padding(.leading, 88)
                    .padding(.trailing, 20)
                    .padding(.top, 10)
                    .frame(minHeight: 44)
                    .background {
                        CharkleWindowDragArea()
                    }
                    .opacity(showSecondaryControls ? 1 : 0)

                    Spacer(minLength: 12)

                    // Center Media Surface (connected physical spring entrance + fast ease-out exit)
                    mediaStage
                        .scaleEffect(stageAppeared ? 1.0 : collapsedStageScale)
                        .offset(stageAppeared ? .zero : collapsedStageOffset)
                        .opacity(stageAppeared ? 1.0 : 0.0)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .background {
                            Color.clear
                                .onGeometryChange(for: CGRect.self) { proxy in
                                    let f = proxy.frame(in: .global)
                                    return CGRect(
                                        x: floor(f.origin.x),
                                        y: floor(f.origin.y),
                                        width: floor(max(0, f.size.width)),
                                        height: floor(max(0, f.size.height))
                                    )
                                } action: { _, newFrame in
                                    if newFrame.width > 80, newFrame.height > 80 {
                                        if abs(newFrame.width - stageViewportSize.width) >= 2
                                            || abs(newFrame.height - stageViewportSize.height) >= 2 {
                                            stageViewportSize = newFrame.size
                                        }
                                        let newCenter = CGPoint(x: newFrame.midX, y: newFrame.midY)
                                        if abs(newCenter.x - stageCenterInWindow.x) >= 2
                                            || abs(newCenter.y - stageCenterInWindow.y) >= 2 {
                                            stageCenterInWindow = newCenter
                                        }
                                    }
                                }
                        }
                        .overlay {
                            StageInteractiveBridge(
                                isWheelZoomEnabled: supportsVisualTransform && !isLongStripScrollMode && !confirmPermanentDelete,
                                onWheelZoom: { factor in
                                    let next = max(0.5, min(maxZoomLimit, zoomScale * factor))
                                    zoomScale = next
                                    if next <= 1.01 {
                                        panOffset = .zero
                                        panStartOffset = .zero
                                    }
                                },
                                onKeyDown: { event in
                                    handleQuickLookKeyDown(event)
                                }
                            )
                            .allowsHitTesting(false)
                        }
                        .padding(.horizontal, coordinator.isInspectorVisible ? 28 : 48)

                    Spacer(minLength: 12)

                    // Floating Liquid Glass Bottom HUD Controls
                    floatingBottomHUD
                        .padding(.bottom, 22)
                        .opacity(showSecondaryControls ? 1 : 0)
                        .scaleEffect(showSecondaryControls ? 1.0 : (reduceMotion ? 1.0 : 0.96), anchor: .bottom)
                }

                // Left / Right gallery stepping chevrons
                if coordinator.quickLookPlaylist.count > 1 && showSecondaryControls {
                    HStack {
                        stepChevronButton(systemName: "chevron.left", delta: -1)
                        Spacer()
                        stepChevronButton(systemName: "chevron.right", delta: 1)
                    }
                    .padding(.horizontal, 18)
                    .transition(.opacity)
                }
            }
            .frame(minWidth: 0, maxWidth: .infinity, maxHeight: .infinity)
            .ignoresSafeArea(.container, edges: .top)
            .clipped()
            .layoutPriority(0)

            if coordinator.isInspectorVisible {
                quickLookInspectorResizeDivider
                    .ignoresSafeArea(.container, edges: .top)
                    .zIndex(20)
                    .layoutPriority(1)
            }

            // Full-Height Resizable Inspector (1:1 parity in width, top alignment, cards, editing, and Similar tab with main window InspectorView)
            InspectorView(
                coordinator: coordinator,
                library: library,
                moodboards: moodboards,
                pinnedAsset: asset,
                isQuickLookHosted: true,
                panelWidth: effectiveInspectorWidth,
                onCopyHex: onCopyHex,
                onFilterByColor: { hex in
                    onClose()
                    onFilterByColor(hex)
                },
                onOpenQuickLook: { target in
                    library.selectedAssetIDs = [target.id]
                    let playlist = coordinator.quickLookPlaylist.contains(target.id)
                        ? coordinator.quickLookPlaylist
                        : coordinator.quickLookPlaylist + [target.id]
                    coordinator.openQuickLook(assetID: target.id, playlist: playlist)
                },
                onRequestCloseQuickLook: performDismiss
            )
            .frame(width: effectiveInspectorWidth)
            .frame(maxHeight: .infinity)
            .opacity(coordinator.isInspectorVisible ? 1 : 0)
            .allowsHitTesting(coordinator.isInspectorVisible)
            .disabled(!coordinator.isInspectorVisible)
            .accessibilityHidden(!coordinator.isInspectorVisible)
            .frame(width: coordinator.isInspectorVisible ? effectiveInspectorWidth : 0, alignment: .leading)
            .ignoresSafeArea(.container, edges: .top)
            .clipped()
            .layoutPriority(1)
        }
        .onGeometryChange(for: CGFloat.self) { proxy in
            floor(max(640, proxy.size.width))
        } action: { _, newWidth in
            if abs(newWidth - overlayWidth) >= 2 {
                overlayWidth = newWidth
            }
        }
        .ignoresSafeArea(.container, edges: .top)
        .animation(CharkleMotion.accessible(CharkleMotion.drawerEase, reduced: reduceMotion), value: coordinator.isInspectorVisible)
        .task(id: asset.id) {
            let assetID = asset.id
            let isRichWebCard = asset.isGitHubRepo || asset.isSocialPost
            let wantsOriginalRaster = !isRichWebCard && (asset.mediaKind == .image || asset.mediaKind == .designFile)

            zoomScale = 1.0
            panOffset = .zero
            panStartOffset = .zero
            rotationDegrees = 0
            flipHorizontal = false
            flipVertical = false
            isLongStripScrollMode = isTallStripImage
            originalURL = nil

            if wantsOriginalRaster {
                highResImage = library.thumbnailLoader.cachedOriginalImage(for: assetID)
                    ?? library.thumbnailLoader.cachedImage(for: assetID, tier: .preview1400)
                    ?? library.thumbnailLoader.cachedImage(for: assetID, tier: .grid520)
                isLoadingOriginalImage = (library.thumbnailLoader.cachedOriginalImage(for: assetID) == nil)
            } else {
                highResImage = nil
                isLoadingOriginalImage = false
            }

            let resolvedURL = await library.resolveOriginalURL(for: assetID)
            guard !Task.isCancelled else { return }
            originalURL = resolvedURL

            if wantsOriginalRaster {
                if let resolvedURL,
                   let originalImg = await library.thumbnailLoader.loadOriginalImage(for: assetID, url: resolvedURL) {
                    guard !Task.isCancelled else { return }
                    highResImage = originalImg
                    isLoadingOriginalImage = false
                } else if let fallbackPreview = await library.thumbnailLoader.loadImage(for: assetID, tier: .preview1400) {
                    guard !Task.isCancelled else { return }
                    highResImage = fallbackPreview
                    isLoadingOriginalImage = false
                } else {
                    isLoadingOriginalImage = false
                }
            } else if !isRichWebCard && asset.mediaKind != .video && asset.mediaKind != .audio && asset.mediaKind != .model3D {
                if let previewImg = await library.thumbnailLoader.loadImage(for: assetID, tier: .preview1400) {
                    guard !Task.isCancelled else { return }
                    highResImage = previewImg
                }
            }

            // Defer non-critical background bookkeeping so opening animations never contend with DB/vector work.
            try? await Task.sleep(for: .milliseconds(180))
            guard !Task.isCancelled else { return }
            library.markAssetOpened(assetID)
            library.refreshInspectorContext(for: assetID)
        }
        .onAppear {
            // Prevent newly mounted Inspector TextFields from stealing firstResponder and blocking Spacebar dismiss.
            if let keyWindow = NSApp.keyWindow, isEditingText(in: keyWindow) {
                keyWindow.makeFirstResponder(nil)
            }
            if connectedSourceRect == nil {
                connectedSourceRect = MasonryCardGeometryRegistry.shared.visibleCardRectInWindow(for: asset.id)
            }
            withAnimation(CharkleMotion.accessible(CharkleMotion.enterSm, reduced: reduceMotion)) {
                backdropVisible = true
            }
            withAnimation(CharkleMotion.accessible(CharkleMotion.gestureSpring, reduced: reduceMotion)) {
                stageAppeared = true
            }
            if reduceMotion {
                showSecondaryControls = true
            } else {
                withAnimation(CharkleMotion.enterSm.delay(0.05)) {
                    showSecondaryControls = true
                }
            }
        }
        .onChange(of: coordinator.quickLookDismissRequestToken) { _, _ in
            guard coordinator.quickLookAssetID != nil else { return }
            if confirmPermanentDelete {
                confirmPermanentDelete = false
                return
            }
            performDismiss()
        }
        .onDisappear {
            dismissTask?.cancel()
            dismissTask = nil
            highResImage = nil
            originalURL = nil
            isLoadingOriginalImage = false
        }
    }

    // MARK: - Rich Multi-Format Media Stage

    @ViewBuilder
    private var mediaStage: some View {
        if let repo = asset.richMetadata?.githubRepo {
            QuickLookGitHubRepoCard(asset: asset, repo: repo) {
                Task {
                    if await library.refreshRichAsset(asset.id) != nil {
                        coordinator.showToast("已刷新 GitHub 仓库信息与 README", icon: "arrow.clockwise")
                    }
                }
            }
            .id(asset.id)
        } else if let post = asset.richMetadata?.socialPost {
            QuickLookSocialPostCard(
                asset: asset,
                post: post,
                originalURL: originalURL,
                onExtractMedia: { attachment, idx in
                    Task {
                        if let extracted = await library.extractMediaFromSocialPost(
                            postAsset: asset,
                            attachment: attachment,
                            index: idx
                        ) {
                            coordinator.showToast("已提取「\(extracted.title)」并保留推文来源", icon: "photo.badge.plus")
                        } else if let err = library.lastError {
                            coordinator.showToast(err, icon: "exclamationmark.triangle", tone: .warning)
                        }
                    }
                },
                onExtractAllMedia: {
                    Task {
                        let extracted = await library.extractAllMediaFromSocialPost(postAsset: asset)
                        if !extracted.isEmpty {
                            coordinator.showToast("已提取 \(extracted.count) 项推文媒体为独立素材", icon: "square.and.arrow.down.on.square")
                        } else if let err = library.lastError {
                            coordinator.showToast(err, icon: "exclamationmark.triangle", tone: .warning)
                        }
                    }
                },
                onRetryFetch: {
                    Task {
                        if await library.refreshRichAsset(asset.id) != nil {
                            coordinator.showToast("已重新获取推文媒体", icon: "arrow.clockwise")
                        }
                    }
                },
                onSetCoverFrame: { jpegData, timestampSeconds in
                    await applyCapturedCoverFrame(jpegData: jpegData, timestampSeconds: timestampSeconds)
                },
                onCaptureCoverFailed: {
                    coordinator.showToast("视频尚未就绪，请稍后再截取封面", icon: "exclamationmark.triangle", tone: .warning)
                },
                fallbackCoverImage: highResImage
                    ?? library.thumbnailLoader.cachedImage(for: asset.id, tier: .preview1400)
                    ?? library.thumbnailLoader.cachedImage(for: asset.id, tier: .grid520)
            )
            .id(asset.id)
        } else {
            switch asset.mediaKind {
            case .image, .designFile:
                zoomableImageStage
            case .animatedImage:
                if let url = originalURL {
                    interactiveTransformedSurface {
                        AnimatedGIFPlayerView(url: url)
                            .id(asset.id)
                            .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                    }
                } else {
                    zoomableImageStage
                }
            case .video:
                if let url = originalURL {
                    QuickLookVideoPlayerView(url: url, captureBridge: localVideoCaptureBridge)
                        .id(asset.id)
                        .frame(maxWidth: 1020, maxHeight: 640)
                        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                        .shadow(color: .black.opacity(0.45), radius: 28, y: 12)
                } else {
                    zoomableImageStage
                }
            case .audio:
                QuickLookAudioStudioCard(asset: asset, fileURL: originalURL)
                    .id(asset.id)
                    .frame(maxWidth: 580)
            case .model3D:
                QuickLookModel3DViewer(asset: asset, originalURL: originalURL)
                    .id(asset.id)
            case .document:
                if let url = originalURL, url.pathExtension.lowercased() == "pdf" {
                    QuickLookPDFView(url: url)
                        .id(asset.id)
                        .frame(maxWidth: 860, maxHeight: 680)
                        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                        .shadow(color: .black.opacity(0.40), radius: 24, y: 10)
                } else if asset.fileName.lowercased().hasSuffix(".swatch") {
                    ProceduralMediaFallbackCard(asset: asset)
                        .frame(width: 420, height: 420)
                        .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
                        .shadow(color: .black.opacity(0.40), radius: 28, y: 12)
                } else {
                    QuickLookMarkdownReaderCard(asset: asset, originalURL: originalURL)
                        .id(asset.id)
                }
            case .webBookmark:
                webBookmarkDetailCard
            }
        }
    }

    @ViewBuilder
    private var zoomableImageStage: some View {
        let shape = RoundedRectangle(cornerRadius: 14, style: .continuous)
        let activeImage = highResImage ?? library.thumbnailLoader.cachedImage(for: asset.id, tier: .grid520)

        if isLongStripScrollMode && !hasActiveVisualTransform && zoomScale <= 1.01, let image = activeImage {
            let backingScale = NSScreen.main?.backingScaleFactor ?? 2.0
            let naturalWidthPt = CGFloat(max(asset.pixelWidth, Int(image.size.width))) / max(1.0, backingScale)
            let targetWidth = min(
                max(520, naturalWidthPt),
                max(360, stageViewportSize.width * 0.84),
                1040
            )
            ScrollView(.vertical) {
                VStack(spacing: 0) {
                    Image(nsImage: image)
                        .resizable()
                        .interpolation(.high)
                        .aspectRatio(contentMode: .fit)
                        .frame(width: targetWidth)
                        .clipShape(shape)
                        .overlay(
                            shape.strokeBorder(Color.white.opacity(0.10), lineWidth: 0.75)
                        )
                }
                .padding(.vertical, 8)
                .frame(maxWidth: .infinity)
                .charkleCleanScrollbars(hidden: false)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            interactiveTransformedSurface {
                ZStack {
                    if let image = activeImage {
                        Image(nsImage: image)
                            .resizable()
                            .interpolation(.high)
                            .aspectRatio(contentMode: .fit)
                            .clipShape(shape)
                    } else {
                        ProceduralMediaFallbackCard(asset: asset)
                            .aspectRatio(max(0.65, min(1.85, asset.aspectRatio)), contentMode: .fit)
                            .frame(maxWidth: 720, maxHeight: 540)
                            .clipShape(shape)
                    }
                }
            }
        }
    }

    private func interactiveTransformedSurface<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        content()
            .rotationEffect(.degrees(rotationDegrees))
            .scaleEffect(x: flipHorizontal ? -1 : 1, y: flipVertical ? -1 : 1)
            .scaleEffect(zoomScale * quarterTurnFitScale)
            .offset(panOffset)
            .shadow(color: .black.opacity(0.38), radius: 24, y: 10)
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
                        if zoomScale < 1.02 {
                            withAnimation(CharkleMotion.accessible(CharkleMotion.uiSpring, reduced: reduceMotion)) {
                                zoomScale = 1.0
                                panOffset = .zero
                                panStartOffset = .zero
                            }
                        }
                    }
            )
            .simultaneousGesture(
                DragGesture()
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

    private var webBookmarkDetailCard: some View {
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
                    playbackKey: "web:\(asset.id.uuidString):\(asset.sourceURL ?? "")",
                    coverURL: thumbURL,
                    fallbackCoverImage: highResImage
                        ?? library.thumbnailLoader.cachedImage(for: asset.id, tier: .preview1400)
                        ?? library.thumbnailLoader.cachedImage(for: asset.id, tier: .grid520),
                    durationText: formattedDur,
                    watchURL: externalURL,
                    openActionLabel: "在默认浏览器中打开",
                    onSetCoverFrame: { jpegData, timestampSeconds in
                        await applyCapturedCoverFrame(jpegData: jpegData, timestampSeconds: timestampSeconds)
                    },
                    onCaptureCoverFailed: {
                        coordinator.showToast("视频尚未就绪，请稍后再截取封面", icon: "exclamationmark.triangle", tone: .warning)
                    },
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
                        if let img = highResImage ?? library.thumbnailLoader.cachedImage(for: asset.id, tier: .grid520) {
                            Image(nsImage: img)
                                .resizable()
                                .interpolation(.high)
                                .aspectRatio(contentMode: .fit)
                        } else {
                            AssetThumbnailSurface(
                                asset: asset,
                                loader: library.thumbnailLoader,
                                tier: .preview1400,
                                cornerRadius: 0,
                                contentMode: .fit,
                                enableHoverPlayback: false
                            )
                        }
                    }
                    .frame(maxWidth: 780, maxHeight: 460)
                    .contentShape(Rectangle())
                    .onTapGesture {
                        if let url = externalURL {
                            NSWorkspace.shared.open(url)
                        }
                    }

                    if let url = externalURL {
                        Button {
                            NSWorkspace.shared.open(url)
                        } label: {
                            Label("在默认浏览器中打开", systemImage: "safari")
                        }
                        .buttonStyle(.charkle(.accent, size: .sm))
                        .padding(16)
                    }
                }
            }

            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 8) {
                    Circle()
                        .fill(Color(charkleHex: asset.dominantColors.first?.hex ?? "#5C6B73"))
                        .frame(width: 10, height: 10)
                    Text(webMeta?.siteName ?? asset.sourceDomain ?? "网页书签")
                        .font(.system(size: 12, weight: .semibold, design: .monospaced))
                        .foregroundStyle(.secondary)
                    if let author = webMeta?.authorName, !author.isEmpty {
                        Text("· \(author)")
                            .font(.system(size: 12))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                    Spacer()
                    if hasStreamableVideo, let webMeta, !webMeta.attachments.isEmpty {
                        Button {
                            let target = asset
                            Task {
                                let extracted = await library.extractAllMediaFromLinkAsset(target)
                                if !extracted.isEmpty {
                                    coordinator.showToast("已保存网页视频为独立素材", icon: "film.stack")
                                } else if let err = library.lastError {
                                    coordinator.showToast(err, icon: "exclamationmark.triangle", tone: .warning)
                                }
                            }
                        } label: {
                            Label("保存视频为独立素材", systemImage: "film.stack")
                        }
                        .buttonStyle(.charkle(.accent, size: .sm))
                    }
                    if hasStreamableVideo, let url = externalURL {
                        Button {
                            NSWorkspace.shared.open(url)
                        } label: {
                            Label("在浏览器中打开", systemImage: "safari")
                        }
                        .buttonStyle(.charkle(.standard, size: .sm))
                    }
                }
                Text(asset.title)
                    .font(.system(size: 18, weight: .semibold))
                if let summary = webMeta?.summary, !summary.isEmpty {
                    Text(summary)
                        .font(.system(size: 13))
                        .foregroundStyle(.secondary)
                        .lineSpacing(4)
                        .lineLimit(4)
                        .textSelection(.enabled)
                } else if !asset.notes.isEmpty {
                    Text(asset.notes)
                        .font(.system(size: 13))
                        .foregroundStyle(.secondary)
                        .lineSpacing(4)
                        .lineLimit(4)
                }
                if let urlStr = asset.sourceURL {
                    Text(urlStr)
                        .font(.system(size: 11.5, design: .monospaced))
                        .foregroundStyle(.tertiary)
                        .lineLimit(2)
                        .textSelection(.enabled)
                }
            }
            .padding(22)
            .frame(maxWidth: 780, alignment: .leading)
            .background(CharkleTheme.surfaceElevated(for: colorScheme))
        }
        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
        .shadow(color: .black.opacity(0.38), radius: 26, y: 12)
    }

    // MARK: - Floating Liquid Glass Bottom HUD

    private var floatingBottomHUD: some View {
        CharkleGlassContainer(spacing: 10) {
            HStack(spacing: 10) {
                if supportsVisualTransform {
                    if isTallStripImage {
                        Button {
                            withAnimation(CharkleMotion.accessible(CharkleMotion.settleStrong, reduced: reduceMotion)) {
                                isLongStripScrollMode.toggle()
                                if isLongStripScrollMode {
                                    zoomScale = 1.0
                                    panOffset = .zero
                                    panStartOffset = .zero
                                    rotationDegrees = 0
                                    flipHorizontal = false
                                    flipVertical = false
                                }
                            }
                        } label: {
                            HStack(spacing: 4) {
                                Image(systemName: isLongStripScrollMode ? "arrow.up.and.down.text.horizontal" : "rectangle.arrowtriangle.2.inward")
                                    .font(.system(size: 11, weight: .semibold))
                                Text(isLongStripScrollMode ? "长图滚动" : "适应窗口")
                                    .font(.system(size: 11, weight: .semibold))
                            }
                            .foregroundStyle(.white)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 4)
                            .background(
                                isLongStripScrollMode
                                    ? CharkleTheme.accent(for: .dark, source: accentSource).opacity(0.82)
                                    : Color.white.opacity(0.14),
                                in: Capsule(style: .continuous)
                            )
                        }
                        .buttonStyle(CharkleTactileButtonStyle())
                        .help("切换长图按宽滚动阅读 / 适应窗口缩放查看")

                        hudDivider
                    }

                    HStack(spacing: 4) {
                        hudIconButton("minus.magnifyingglass", help: "缩小") {
                            stepZoom(by: 0.8)
                        }
                        Text("\(Int((zoomScale * 100).rounded()))%")
                            .font(.system(size: 11, weight: .semibold, design: .monospaced))
                            .monospacedDigit()
                            .foregroundStyle(.white.opacity(0.88))
                            .frame(minWidth: 42)
                        hudIconButton("plus.magnifyingglass", help: "放大") {
                            stepZoom(by: 1.25)
                        }
                        hudIconButton("1.magnifyingglass", help: "重置缩放与变换 (0)") {
                            resetViewTransform()
                        }
                    }

                    hudDivider

                    HStack(spacing: 2) {
                        hudIconButton("rotate.left", help: "逆时针旋转 90° (⇧R)") {
                            rotatePreview(by: -90)
                        }
                        hudIconButton("rotate.right", help: "顺时针旋转 90° (R)") {
                            rotatePreview(by: 90)
                        }
                        hudIconButton(
                            "arrow.left.and.right.righttriangle.left.righttriangle.right",
                            help: "水平翻转 (⇧H)",
                            isActive: flipHorizontal
                        ) {
                            toggleFlip(horizontal: true)
                        }
                        hudIconButton(
                            "arrow.up.and.down.righttriangle.up.righttriangle.down",
                            help: "上下翻转 (⇧V)",
                            isActive: flipVertical
                        ) {
                            toggleFlip(horizontal: false)
                        }

                        if hasActiveVisualTransform {
                            Button {
                                resetViewTransform(resetZoom: false)
                            } label: {
                                HStack(spacing: 3) {
                                    if displayRotationDegrees != 0 {
                                        Text("\(displayRotationDegrees)°")
                                            .font(.system(size: 10.5, weight: .semibold, design: .monospaced))
                                            .monospacedDigit()
                                    }
                                    Image(systemName: "arrow.uturn.backward")
                                        .font(.system(size: 9.5, weight: .semibold))
                                }
                                .foregroundStyle(.white)
                                .padding(.horizontal, 7)
                                .padding(.vertical, 4)
                                .background(
                                    CharkleTheme.accent(for: .dark, source: accentSource).opacity(0.78),
                                    in: RoundedRectangle(cornerRadius: CharkleTheme.Radius.chip, style: .continuous)
                                )
                            }
                            .buttonStyle(CharkleTactileButtonStyle())
                            .help("还原旋转与翻转")
                            .transition(CharkleMotion.originTransition(anchor: .trailing, scale: 0.94, reduced: reduceMotion))
                        }
                    }
                    .animation(CharkleMotion.accessible(CharkleMotion.settleStrong, reduced: reduceMotion), value: hasActiveVisualTransform)

                    hudDivider
                }

                if asset.mediaKind == .video && !asset.isSocialPost {
                    Button {
                        guard !isCapturingCoverFrame else { return }
                        isCapturingCoverFrame = true
                        Task { @MainActor in
                            defer { isCapturingCoverFrame = false }
                            if let captured = await localVideoCaptureBridge.captureCurrentFrame() {
                                await applyCapturedCoverFrame(
                                    jpegData: captured.jpegData,
                                    timestampSeconds: captured.timestampSeconds
                                )
                            } else {
                                coordinator.showToast("视频尚未就绪，请稍后再截取封面", icon: "exclamationmark.triangle", tone: .warning)
                            }
                        }
                    } label: {
                        HStack(spacing: 5) {
                            if isCapturingCoverFrame {
                                ProgressView().controlSize(.mini).tint(.white)
                            } else {
                                Image(systemName: "camera.viewfinder")
                                    .font(.system(size: 11.5, weight: .semibold))
                            }
                            Text("设当前帧为封面")
                                .font(.system(size: 11.5, weight: .semibold))
                        }
                        .foregroundStyle(.white)
                        .padding(.horizontal, 9)
                        .padding(.vertical, 4.5)
                        .background(Color.white.opacity(0.14), in: Capsule(style: .continuous))
                    }
                    .buttonStyle(CharkleTactileButtonStyle())
                    .disabled(isCapturingCoverFrame)
                    .help("将当前播放位置的视频画面设为素材封面")

                    hudDivider
                }

                // Rating stars (matching InspectorView microOvershoot)
                HStack(spacing: 3) {
                    ForEach(1...5, id: \.self) { star in
                        Button {
                            let target = asset.rating == star ? 0 : star
                            Task { await library.setRating(target, for: [asset.id]) }
                        } label: {
                            Image(systemName: star <= asset.rating ? "star.fill" : "star")
                                .font(.system(size: 12))
                                .foregroundStyle(star <= asset.rating ? Color(charkleHex: "#F2C14E") : .white.opacity(0.45))
                                .scaleEffect(star == asset.rating && !reduceMotion ? 1.08 : 1.0)
                                .animation(CharkleMotion.accessible(CharkleMotion.microOvershoot, reduced: reduceMotion), value: asset.rating)
                        }
                        .buttonStyle(CharkleTactileButtonStyle())
                    }
                }

                hudDivider

                if asset.isTrashed {
                    Button {
                        let id = asset.id
                        onClose()
                        Task {
                            await library.restoreAssets([id])
                            coordinator.showToast("已放回原处", icon: "arrow.uturn.backward")
                        }
                    } label: {
                        Label("放回原处", systemImage: "arrow.uturn.backward")
                            .font(.system(size: 11.5, weight: .semibold))
                            .foregroundStyle(.white)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 4)
                    }
                    .buttonStyle(CharkleTactileButtonStyle())

                    Button(role: .destructive) {
                        confirmPermanentDelete = true
                    } label: {
                        Label("彻底删除", systemImage: "trash.slash")
                            .font(.system(size: 11.5, weight: .semibold))
                            .foregroundStyle(Color(charkleHex: "#FF6B6B"))
                            .padding(.horizontal, 8)
                            .padding(.vertical, 4)
                    }
                    .buttonStyle(CharkleTactileButtonStyle())
                    .charklePopconfirm(
                        isPresented: $confirmPermanentDelete,
                        title: "彻底删除此素材？",
                        message: "彻底删除后将无法从废纸篓恢复。",
                        confirmTitle: "彻底删除",
                        arrowEdge: .top
                    ) {
                        let id = asset.id
                        onClose()
                        Task {
                            await library.permanentlyDeleteAssets([id])
                            coordinator.showToast("已彻底删除素材", icon: "trash.slash")
                        }
                    }
                } else {
                    hudIconButton(
                        asset.pinnedOffline ? "arrow.down.circle.fill" : "arrow.down.circle",
                        help: asset.pinnedOffline ? "取消始终保留在本地" : "始终保留在本地"
                    ) {
                        let nextPinned = !asset.pinnedOffline
                        Task {
                            await library.togglePinOffline(ids: [asset.id], pinned: nextPinned)
                            coordinator.showToast(
                                nextPinned ? "已设为始终保留在本地" : "已取消始终保留在本地",
                                icon: nextPinned ? "arrow.down.circle.fill" : "icloud"
                            )
                        }
                    }

                    Menu {
                        ForEach(moodboards.boards) { board in
                            Button(board.title) {
                                Task {
                                    await moodboards.addAssetsToSpecificBoard(boardID: board.id, assets: [asset])
                                    coordinator.showToast("已加入情绪板「\(board.title)」", icon: "rectangle.3.group")
                                }
                            }
                        }
                        if moodboards.boards.isEmpty {
                            Button("新建情绪板并加入…") {
                                library.selectedAssetIDs = [asset.id]
                                onClose()
                                coordinator.presentMoodboardGenerator(entry: .selection)
                            }
                        }
                    } label: {
                        Image(systemName: "rectangle.3.group")
                            .font(.system(size: 13, weight: .medium))
                            .foregroundStyle(.white.opacity(0.9))
                            .frame(width: 28, height: 28)
                            .contentShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                    }
                    .menuStyle(.borderlessButton)
                    .menuIndicator(.hidden)
                    .fixedSize()
                    .help("加入情绪板")
                }

                if originalURL != nil {
                    hudIconButton("folder", help: "在访达中显示") {
                        Task { _ = await library.revealInFinder(assetID: asset.id) }
                    }
                    if !asset.isTrashed {
                        hudIconButton("doc.on.doc", help: "拷贝文件") {
                            Task {
                                _ = await library.copyAssetsToPasteboard([asset.id])
                                coordinator.showToast("已拷贝到剪贴板", icon: "doc.on.doc")
                            }
                        }
                    }
                    hudIconButton("arrow.up.forward.app", help: "使用默认应用打开") {
                        if let url = originalURL { NSWorkspace.shared.open(url) }
                    }
                } else if let urlStr = asset.sourceURL, let webURL = URL(string: urlStr) {
                    hudIconButton("safari", help: "打开来源网页") {
                        NSWorkspace.shared.open(webURL)
                    }
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            .charkleLiquidGlass(.darkNotch, in: Capsule(style: .continuous))
        }
    }

    private func stepZoom(by factor: CGFloat) {
        guard supportsVisualTransform else { return }
        isLongStripScrollMode = false
        withAnimation(CharkleMotion.accessible(CharkleMotion.uiSpring, reduced: reduceMotion)) {
            let next = max(0.5, min(maxZoomLimit, zoomScale * factor))
            zoomScale = next
            if next <= 1.01 {
                panOffset = .zero
                panStartOffset = .zero
            }
        }
    }

    private func rotatePreview(by screenDelta: Double) {
        guard supportsVisualTransform else { return }
        // Because screen-space flip wraps inner rotation: R(Δ) * S * R(θ) = S * R(θ + sx*sy*Δ)
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

    private func resetViewTransform(resetZoom: Bool = true) {
        withAnimation(CharkleMotion.accessible(CharkleMotion.uiSpring, reduced: reduceMotion)) {
            if resetZoom {
                zoomScale = 1.0
                panOffset = .zero
                panStartOffset = .zero
            }
            rotationDegrees = 0
            flipHorizontal = false
            flipVertical = false
        }
    }

    private func isEditingText(in window: NSWindow?) -> Bool {
        guard let responder = window?.firstResponder else { return false }
        return responder is NSTextView || responder is NSTextField || responder is NSText
    }

    private func handleQuickLookKeyDown(_ event: NSEvent) -> NSEvent? {
        if isDismissing { return nil }
        if confirmPermanentDelete { return event }
        if event.window?.attachedSheet != nil || NSApp.modalWindow != nil { return event }

        // Explicitly ignore Caps Lock, NumPad, and Function flags so Space, Esc, and Arrow keys never fail.
        let primaryModifiers = event.modifierFlags.intersection([.command, .option, .control, .shift])
        let isUnmodified = primaryModifiers.isEmpty
        let isShiftOnly = primaryModifiers == .shift

        // ⌘⌥I toggles the docked 300pt Inspector synchronously with main library view
        if primaryModifiers == [.command, .option],
           event.charactersIgnoringModifiers?.lowercased() == "i" {
            withAnimation(CharkleMotion.accessible(CharkleMotion.drawerEase, reduced: reduceMotion)) {
                coordinator.isInspectorVisible.toggle()
            }
            return nil
        }

        // Respect active text editing inside Quick Look's docked InspectorView (title, tags, notes)
        if isEditingText(in: event.window) {
            if isUnmodified && event.keyCode == 53 { // Escape exits field focus first
                event.window?.makeFirstResponder(nil)
                return nil
            }
            return event
        }

        if isUnmodified {
            switch event.keyCode {
            case 49, 53: // Space or Escape -> close Quick Look immediately
                if event.isARepeat { return nil }
                performDismiss()
                return nil
            case 123: // Left Arrow
                onStep(-1)
                return nil
            case 124: // Right Arrow
                onStep(1)
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
                resetViewTransform()
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

    private func hudIconButton(_ systemName: String, help: String, isActive: Bool = false, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(isActive ? Color.white : .white.opacity(0.9))
                .frame(width: 28, height: 28)
                .background(
                    isActive ? CharkleTheme.accent(for: .dark, source: accentSource).opacity(0.82) : Color.clear,
                    in: RoundedRectangle(cornerRadius: 8, style: .continuous)
                )
        }
        .buttonStyle(CharkleTactileButtonStyle())
        .help(help)
    }

    private var hudDivider: some View {
        Rectangle()
            .fill(Color.white.opacity(0.16))
            .frame(width: 1, height: 16)
    }

    @MainActor
    private func applyCapturedCoverFrame(jpegData: Data, timestampSeconds: Double?) async {
        let targetAssetID = asset.id
        if await library.updateAssetCoverImage(assetID: targetAssetID, imageData: jpegData) != nil {
            if coordinator.quickLookAssetID == targetAssetID,
               asset.id == targetAssetID,
               let fresh = NSImage(data: jpegData) {
                highResImage = fresh
            }
            if let ts = timestampSeconds, ts > 0 {
                coordinator.showToast(
                    "已将 \(VideoFrameCapture.formattedTimestamp(ts)) 画面设为素材封面",
                    icon: "photo.badge.checkmark"
                )
            } else {
                coordinator.showToast("已将当前画面设为素材封面", icon: "photo.badge.checkmark")
            }
        } else if let err = library.lastError {
            coordinator.showToast(err, icon: "exclamationmark.triangle", tone: .warning)
        }
    }

    private func stepChevronButton(systemName: String, delta: Int) -> some View {
        Button {
            onStep(delta)
        } label: {
            Image(systemName: systemName)
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(.white.opacity(0.9))
                .frame(width: 36, height: 36)
                .charkleLiquidGlass(.darkNotch, in: Circle(), interactive: true)
        }
        .buttonStyle(CharkleTactileButtonStyle())
    }
}

// MARK: - Native AppKit / AVKit / PDFKit Quick Look Media Bridges

struct AnimatedGIFPlayerView: NSViewRepresentable {
    let url: URL

    final class Coordinator {
        var currentURL: URL?
        var loadTask: Task<Void, Never>?

        func load(url: URL, into view: NSImageView) {
            loadTask?.cancel()
            currentURL = url
            loadTask = Task { @MainActor [weak view] in
                let data = await AnimatedGIFPlayerView.readDataOffMain(url: url)
                guard !Task.isCancelled, let view, let data, let image = NSImage(data: data) else { return }
                view.image = image
                view.animates = true
            }
        }

        func teardown(_ view: NSImageView) {
            loadTask?.cancel()
            loadTask = nil
            currentURL = nil
            view.animates = false
            view.image = nil
        }
    }

    @concurrent
    private static func readDataOffMain(url: URL) async -> Data? {
        guard !Task.isCancelled else { return nil }
        return try? Data(contentsOf: url)
    }

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func makeNSView(context: Context) -> NSImageView {
        let view = NSImageView()
        view.animates = true
        view.imageScaling = .scaleProportionallyDown
        context.coordinator.load(url: url, into: view)
        return view
    }

    func updateNSView(_ nsView: NSImageView, context: Context) {
        guard context.coordinator.currentURL != url else { return }
        context.coordinator.load(url: url, into: nsView)
    }

    static func dismantleNSView(_ nsView: NSImageView, coordinator: Coordinator) {
        coordinator.teardown(nsView)
    }
}

struct QuickLookVideoPlayerView: NSViewRepresentable {
    let url: URL
    var autoPlay: Bool = true
    var isPlaybackSuspended: Bool = false
    var captureBridge: StreamingFrameCaptureBridge? = nil

    @MainActor
    final class Coordinator {
        let bridgeOwnerID = UUID()
        var currentURL: URL?
        var wasSuspended: Bool = false
        var videoOutput: AVPlayerItemVideoOutput?
        weak var captureBridge: StreamingFrameCaptureBridge?

        func attach(url: URL, to view: AVPlayerView, autoPlay: Bool, isSuspended: Bool, captureBridge: StreamingFrameCaptureBridge?) {
            teardown(view)
            currentURL = url
            wasSuspended = isSuspended
            self.captureBridge = captureBridge

            let item = AVPlayerItem(url: url)
            let output = VideoFrameCapture.makeVideoOutput()
            item.add(output)
            videoOutput = output

            let player = AVPlayer(playerItem: item)
            view.player = player
            self.captureBridge?.register(ownerID: bridgeOwnerID) { [weak player, weak output] in
                guard let player,
                      let result = await VideoFrameCapture.captureCurrentFrameJPEG(from: player, videoOutput: output) else {
                    return nil
                }
                return (result.jpegData, result.timestampSeconds)
            }
            if autoPlay && !isSuspended {
                player.play()
            }
        }

        func teardown(_ view: AVPlayerView) {
            captureBridge?.unregister(ownerID: bridgeOwnerID)
            videoOutput = nil
            view.player?.pause()
            view.player?.replaceCurrentItem(with: nil)
            view.player = nil
            currentURL = nil
        }
    }

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func makeNSView(context: Context) -> AVPlayerView {
        let view = AVPlayerView()
        view.controlsStyle = .floating
        context.coordinator.attach(
            url: url,
            to: view,
            autoPlay: autoPlay,
            isSuspended: isPlaybackSuspended,
            captureBridge: captureBridge
        )
        return view
    }

    func updateNSView(_ nsView: AVPlayerView, context: Context) {
        if context.coordinator.currentURL != url {
            context.coordinator.attach(
                url: url,
                to: nsView,
                autoPlay: autoPlay,
                isSuspended: isPlaybackSuspended,
                captureBridge: captureBridge
            )
            return
        }
        if context.coordinator.wasSuspended != isPlaybackSuspended {
            context.coordinator.wasSuspended = isPlaybackSuspended
            if isPlaybackSuspended {
                nsView.player?.pause()
            }
        }
    }

    static func dismantleNSView(_ nsView: AVPlayerView, coordinator: Coordinator) {
        coordinator.teardown(nsView)
    }
}

private nonisolated final class PDFDocumentBox: @unchecked Sendable {
    let document: PDFDocument
    init(_ document: PDFDocument) { self.document = document }
}

struct QuickLookPDFView: NSViewRepresentable {
    let url: URL

    final class Coordinator {
        var currentURL: URL?
        var loadTask: Task<Void, Never>?

        func load(url: URL, into view: PDFView) {
            loadTask?.cancel()
            currentURL = url
            loadTask = Task { @MainActor [weak view] in
                let box = await QuickLookPDFView.loadDocumentOffMain(url: url)
                guard !Task.isCancelled, let view else { return }
                view.document = box?.document
            }
        }

        func teardown(_ view: PDFView) {
            loadTask?.cancel()
            loadTask = nil
            currentURL = nil
            view.document = nil
        }
    }

    @concurrent
    private static func loadDocumentOffMain(url: URL) async -> PDFDocumentBox? {
        guard !Task.isCancelled, let doc = PDFDocument(url: url) else { return nil }
        return PDFDocumentBox(doc)
    }

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func makeNSView(context: Context) -> PDFView {
        let view = PDFView()
        view.autoScales = true
        view.displayMode = .singlePageContinuous
        context.coordinator.load(url: url, into: view)
        return view
    }

    func updateNSView(_ nsView: PDFView, context: Context) {
        if context.coordinator.currentURL != url {
            context.coordinator.load(url: url, into: nsView)
        }
    }

    static func dismantleNSView(_ nsView: PDFView, coordinator: Coordinator) {
        coordinator.teardown(nsView)
    }
}

@Observable
private final class QuickLookAudioPlaybackController {
    var isPlaying: Bool = false
    var progress: Double = 0
    var isScrubbing: Bool = false

    @ObservationIgnored private var player: AVPlayer?
    @ObservationIgnored private var currentURL: URL?
    @ObservationIgnored private var timeObserver: Any?
    @ObservationIgnored private var endObserver: NSObjectProtocol?
    @ObservationIgnored private var fallbackDuration: Double?

    func configure(fileURL: URL?, fallbackDuration: Double?) {
        self.fallbackDuration = fallbackDuration
        if currentURL != fileURL {
            stop()
            currentURL = fileURL
        }
    }

    func suspendIfNeeded(_ suspended: Bool) {
        guard suspended, isPlaying else { return }
        player?.pause()
        isPlaying = false
    }

    func togglePlayback(fileURL: URL?) {
        guard let fileURL else { return }
        if currentURL != fileURL {
            stop()
            currentURL = fileURL
        }
        if player == nil {
            let item = AVPlayerItem(url: fileURL)
            let newPlayer = AVPlayer(playerItem: item)
            player = newPlayer

            let interval = CMTime(seconds: 0.1, preferredTimescale: 600)
            timeObserver = newPlayer.addPeriodicTimeObserver(forInterval: interval, queue: .main) { [weak self] time in
                MainActor.assumeIsolated {
                    guard let self, !self.isScrubbing else { return }
                    let duration = self.effectiveDuration()
                    guard duration > 0 else { return }
                    let current = time.seconds
                    if current.isFinite && current >= 0 {
                        self.progress = max(0, min(1, current / duration))
                    }
                }
            }
            endObserver = NotificationCenter.default.addObserver(
                forName: .AVPlayerItemDidPlayToEndTime,
                object: item,
                queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated {
                    guard let self else { return }
                    self.isPlaying = false
                    self.progress = 1.0
                }
            }

            if progress > 0 && progress < 0.99 {
                let dur = effectiveDuration()
                if dur > 0 {
                    newPlayer.seek(to: CMTime(seconds: dur * progress, preferredTimescale: 600))
                }
            }
        }

        if isPlaying {
            player?.pause()
            isPlaying = false
        } else {
            if progress >= 0.99 {
                progress = 0
                player?.seek(to: .zero)
            }
            player?.play()
            isPlaying = true
        }
    }

    func seek(to ratio: Double) {
        let clamped = max(0, min(1, ratio))
        progress = clamped
        let duration = effectiveDuration()
        if duration > 0, let player {
            let target = CMTime(seconds: duration * clamped, preferredTimescale: 600)
            player.seek(to: target)
        }
    }

    func stop() {
        if let token = timeObserver, let player {
            player.removeTimeObserver(token)
        }
        timeObserver = nil
        if let obs = endObserver {
            NotificationCenter.default.removeObserver(obs)
        }
        endObserver = nil
        player?.pause()
        player?.replaceCurrentItem(with: nil)
        player = nil
        isPlaying = false
        progress = 0
        isScrubbing = false
    }

    private func effectiveDuration() -> Double {
        if let itemDur = player?.currentItem?.duration.seconds, itemDur.isFinite, itemDur > 0 {
            return itemDur
        }
        if let fallback = fallbackDuration, fallback.isFinite, fallback > 0 {
            return fallback
        }
        return 0
    }

    isolated deinit {
        stop()
    }
}

struct QuickLookAudioStudioCard: View {
    @Environment(\.colorScheme) private var colorScheme

    let asset: AssetRecord
    let fileURL: URL?
    var isPlaybackSuspended: Bool = false

    @State private var playback = QuickLookAudioPlaybackController()

    var body: some View {
        let peaks = asset.waveformPeaks.isEmpty
            ? (0..<48).map { i -> Float in Float(0.25 + 0.65 * abs(sin(Double(i) * 0.35))) }
            : asset.waveformPeaks
        let accent = Color(charkleHex: asset.dominantColors.first?.hex ?? "#3D5A80")

        VStack(alignment: .leading, spacing: 18) {
            HStack(spacing: 12) {
                Button {
                    playback.togglePlayback(fileURL: fileURL)
                } label: {
                    Image(systemName: playback.isPlaying ? "pause.fill" : "play.fill")
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(.white)
                        .frame(width: 44, height: 44)
                        .background(accent, in: Circle())
                }
                .buttonStyle(CharkleTactileButtonStyle())
                .disabled(fileURL == nil)

                VStack(alignment: .leading, spacing: 3) {
                    Text(asset.title)
                        .font(.system(size: 16, weight: .semibold))
                    Text(fileURL != nil ? "音频原文件就绪 · 点击波形可跳转" : "音频波形预览（原文件按需下载后可播放）")
                        .font(.system(size: 11.5))
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Text(CanvasFormatters.durationString(asset.durationSeconds))
                    .font(.system(size: 12, weight: .semibold, design: .monospaced))
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            }

            GeometryReader { geo in
                HStack(alignment: .center, spacing: 3) {
                    ForEach(Array(peaks.prefix(64).enumerated()), id: \.offset) { idx, peak in
                        let frac = Double(idx) / Double(max(1, min(peaks.count, 64) - 1))
                        Capsule(style: .continuous)
                            .fill(frac <= playback.progress ? accent : Color.primary.opacity(0.18))
                            .frame(height: max(6, geo.size.height * CGFloat(max(0.15, min(1.0, peak)))))
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .contentShape(Rectangle())
                .gesture(
                    DragGesture(minimumDistance: 0)
                        .onChanged { value in
                            playback.isScrubbing = true
                            let ratio = max(0, min(1, Double(value.location.x / max(1, geo.size.width))))
                            playback.seek(to: ratio)
                        }
                        .onEnded { _ in
                            playback.isScrubbing = false
                        }
                )
            }
            .frame(height: 76)
        }
        .padding(24)
        .background(CharkleTheme.surfaceElevated(for: colorScheme), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .shadow(color: .black.opacity(0.36), radius: 24, y: 10)
        .onAppear {
            playback.configure(fileURL: fileURL, fallbackDuration: asset.durationSeconds)
        }
        .onChange(of: fileURL) { _, newURL in
            playback.configure(fileURL: newURL, fallbackDuration: asset.durationSeconds)
        }
        .onChange(of: isPlaybackSuspended) { _, suspended in
            playback.suspendIfNeeded(suspended)
        }
        .onDisappear {
            playback.stop()
        }
    }
}
