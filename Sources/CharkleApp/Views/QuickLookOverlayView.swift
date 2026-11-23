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
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    public let asset: AssetRecord
    public let library: LibraryStore
    public let moodboards: MoodboardStore
    public let coordinator: AppCoordinatorStore
    public let heroNamespace: Namespace.ID
    public let onClose: () -> Void
    public let onStep: (Int) -> Void

    @State private var originalURL: URL?
    @State private var highResImage: NSImage?
    @State private var isLoadingOriginalImage: Bool = false
    @State private var isLongStripScrollMode: Bool = false
    @State private var stageAppeared: Bool = false
    @State private var zoomScale: CGFloat = 1.0
    @State private var gestureStartScale: CGFloat?
    @State private var panOffset: CGSize = .zero
    @State private var panStartOffset: CGSize = .zero
    @State private var rotationDegrees: Double = 0
    @State private var flipHorizontal: Bool = false
    @State private var flipVertical: Bool = false
    @State private var stageViewportSize: CGSize = CGSize(width: 960, height: 640)
    @State private var showSecondaryControls: Bool = false
    @State private var confirmPermanentDelete: Bool = false
    @State private var isSidePanelOpen: Bool = false
    @State private var sidePanelTab: SidePanelTab = .similar
    @Namespace private var qlSideTabNamespace

    private enum SidePanelTab: String, CaseIterable {
        case info = "信息"
        case similar = "类似项目"
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
        onStep: @escaping (Int) -> Void
    ) {
        self.asset = asset
        self.library = library
        self.moodboards = moodboards
        self.coordinator = coordinator
        self.heroNamespace = heroNamespace
        self.onClose = onClose
        self.onStep = onStep
    }

    public var body: some View {
        ZStack {
            // Soft blurred neutral ambient backdrop (zero visual color distortion)
            ZStack {
                (colorScheme == .dark ? Color.black.opacity(0.76) : Color(charkleHex: "#151619").opacity(0.68))
                CharkleTheme.ambientTint(from: asset.dominantColors.first?.hex, scheme: .dark)
            }
            .ignoresSafeArea()
            .onTapGesture { onClose() }

            // Hero Media Stage
            VStack(spacing: 0) {
                // Top minimal title bar (fades in after 45% hero continuity)
                HStack(spacing: 10) {
                    Text(asset.title)
                        .font(.system(size: 13.5, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.94))
                        .lineLimit(1)

                    Text("\(asset.pixelWidth) × \(asset.pixelHeight) · \(asset.mediaKind.localizedLabel)")
                        .font(.system(size: 11, weight: .medium, design: .monospaced))
                        .monospacedDigit()
                        .foregroundStyle(.white.opacity(0.62))

                    Spacer()

                    Button {
                        withAnimation(CharkleMotion.accessible(CharkleMotion.drawerEase, reduced: reduceMotion)) {
                            isSidePanelOpen.toggle()
                        }
                    } label: {
                        Image(systemName: "sidebar.right")
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(isSidePanelOpen ? Color.accentColor : .white.opacity(0.86))
                            .frame(width: 28, height: 28)
                            .charkleLiquidGlass(.darkNotch, in: Circle(), interactive: true)
                    }
                    .buttonStyle(CharkleTactileButtonStyle())
                    .help("显示 / 隐藏右侧信息与类似项目")

                    Button(action: onClose) {
                        Image(systemName: "xmark")
                            .font(.system(size: 11, weight: .bold))
                            .foregroundStyle(.white.opacity(0.86))
                            .frame(width: 28, height: 28)
                            .charkleLiquidGlass(.darkNotch, in: Circle(), interactive: true)
                    }
                    .buttonStyle(CharkleTactileButtonStyle())
                    .help("关闭预览 (Space / Esc)")
                }
                .padding(.horizontal, 24)
                .padding(.top, 18)
                .opacity(showSecondaryControls ? 1 : 0)

                Spacer(minLength: 12)

                // Center Media Surface + Optional Right Info|Similar Drawer (Img 2)
                HStack(spacing: 16) {
                    mediaStage
                        .scaleEffect(stageAppeared || reduceMotion ? 1.0 : 0.97)
                        .opacity(stageAppeared ? 1.0 : 0.0)
                        .animation(CharkleMotion.accessible(CharkleMotion.enterMd, reduced: reduceMotion), value: stageAppeared)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .background {
                            Color.clear
                                .onGeometryChange(for: CGSize.self) { proxy in
                                    CGSize(width: floor(max(0, proxy.size.width)), height: floor(proxy.size.height))
                                } action: { _, newSize in
                                    if newSize.width > 80, newSize.height > 80,
                                       (abs(newSize.width - stageViewportSize.width) >= 2 || abs(newSize.height - stageViewportSize.height) >= 2) {
                                        stageViewportSize = newSize
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

                    if isSidePanelOpen {
                        quickLookSidePanel
                            .frame(width: 292)
                            .frame(maxHeight: 680)
                            .transition(.move(edge: .trailing).combined(with: .opacity))
                    }
                }
                .padding(.horizontal, isSidePanelOpen ? 24 : 48)
                .frame(maxWidth: .infinity, maxHeight: .infinity)

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
            stageAppeared = true
            if reduceMotion {
                showSecondaryControls = true
            } else {
                withAnimation(CharkleMotion.enterSm.delay(0.04)) {
                    showSecondaryControls = true
                }
            }
        }
        .alert("彻底删除此素材？", isPresented: $confirmPermanentDelete) {
            Button("取消", role: .cancel) {}
            Button("彻底删除", role: .destructive) {
                let id = asset.id
                onClose()
                Task {
                    await library.permanentlyDeleteAssets([id])
                    coordinator.showToast("已彻底删除素材", icon: "trash.slash")
                }
            }
        } message: {
            Text("彻底删除后将无法恢复。")
        }
        .focusable()
        .focusEffectDisabled()
        .onKeyPress(.space) {
            onClose()
            return .handled
        }
        .onKeyPress(.escape) {
            onClose()
            return .handled
        }
        .onKeyPress(.leftArrow) {
            onStep(-1)
            return .handled
        }
        .onKeyPress(.rightArrow) {
            onStep(1)
            return .handled
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
                }
            )
        } else {
            switch asset.mediaKind {
            case .image, .designFile:
                zoomableImageStage
            case .animatedImage:
                if let url = originalURL {
                    AnimatedGIFPlayerView(url: url)
                        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                        .rotationEffect(.degrees(rotationDegrees))
                        .scaleEffect(x: flipHorizontal ? -1 : 1, y: flipVertical ? -1 : 1)
                        .scaleEffect(zoomScale * quarterTurnFitScale)
                        .offset(panOffset)
                        .shadow(color: .black.opacity(0.42), radius: 28, y: 12)
                } else {
                    zoomableImageStage
                }
            case .video:
                if let url = originalURL {
                    QuickLookVideoPlayerView(url: url)
                        .frame(maxWidth: 1020, maxHeight: 640)
                        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                        .shadow(color: .black.opacity(0.45), radius: 28, y: 12)
                } else {
                    zoomableImageStage
                }
            case .audio:
                QuickLookAudioStudioCard(asset: asset, fileURL: originalURL)
                    .frame(maxWidth: 580)
            case .model3D:
                QuickLookModel3DViewer(asset: asset, originalURL: originalURL)
            case .document:
                if let url = originalURL, url.pathExtension.lowercased() == "pdf" {
                    QuickLookPDFView(url: url)
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
                }
            case .webBookmark:
                webBookmarkDetailCard
            }
        }
    }

    // MARK: - QuickLook Side Info | Similar Drawer (Reference Img 2)

    private var quickLookSidePanel: some View {
        VStack(spacing: 0) {
            HStack(spacing: 2) {
                ForEach(SidePanelTab.allCases, id: \.self) { tab in
                    let active = sidePanelTab == tab
                    Button {
                        withAnimation(CharkleMotion.accessible(CharkleMotion.settleStrong, reduced: reduceMotion)) {
                            sidePanelTab = tab
                        }
                    } label: {
                        Text(tab.rawValue)
                            .font(.system(size: 12, weight: active ? .semibold : .medium))
                            .foregroundStyle(active ? .white : .white.opacity(0.65))
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 6)
                            .background {
                                if active {
                                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                                        .fill(Color.white.opacity(0.16))
                                        .matchedGeometryEffect(id: "ql-side-tab", in: qlSideTabNamespace)
                                }
                            }
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(3)
            .background(Color.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 9, style: .continuous))
            .padding(14)

            ScrollView(.vertical) {
                Group {
                    if sidePanelTab == .similar {
                        quickLookSideSimilarTab
                    } else {
                        quickLookSideInfoTab
                    }
                }
                .charkleCleanScrollbars(hidden: true)
            }
            .scrollIndicators(.hidden)
        }
        .background(Color(charkleHex: "#15161A").opacity(0.92), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .strokeBorder(Color.white.opacity(0.12), lineWidth: 0.75)
        )
    }

    private var quickLookSideSimilarTab: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("与「\(asset.title)」相似的素材")
                .font(.system(size: 11.5, weight: .medium))
                .foregroundStyle(.white.opacity(0.68))
                .lineLimit(1)

            if library.similarAssets.isEmpty {
                Text("暂无视觉或色彩相似素材")
                    .font(.system(size: 12))
                    .foregroundStyle(.white.opacity(0.5))
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 36)
            } else {
                LazyVGrid(columns: [GridItem(.flexible(), spacing: 8), GridItem(.flexible(), spacing: 8)], spacing: 8) {
                    ForEach(library.similarAssets) { scored in
                        let ratio = max(0.68, min(1.5, CGFloat(scored.asset.aspectRatio)))
                        AssetThumbnailSurface(
                            asset: scored.asset,
                            loader: library.thumbnailLoader,
                            tier: .grid520,
                            cornerRadius: 9
                        )
                        .frame(height: (126 / ratio).rounded())
                        .overlay(
                            RoundedRectangle(cornerRadius: 9, style: .continuous)
                                .strokeBorder(Color.white.opacity(0.12), lineWidth: 0.75)
                        )
                        .onTapGesture {
                            library.selectedAssetIDs = [scored.asset.id]
                            coordinator.openQuickLook(assetID: scored.asset.id, playlist: coordinator.quickLookPlaylist)
                        }
                        .help(scored.asset.title)
                    }
                }
            }
        }
        .padding(.horizontal, 14)
        .padding(.bottom, 14)
    }

    private var quickLookSideInfoTab: some View {
        let resolvedMeta = library.resolvedImageMetadata(for: asset)
        return VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 4) {
                Text(asset.title)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(.white)
                Text("\(asset.mediaKind.localizedLabel) · \(asset.pixelWidth) × \(asset.pixelHeight)")
                    .font(.system(size: 11.5, design: .monospaced))
                    .foregroundStyle(.white.opacity(0.62))
            }

            if !asset.dominantColors.isEmpty {
                HStack(spacing: 6) {
                    ForEach(asset.dominantColors.prefix(5), id: \.hex) { swatch in
                        RoundedRectangle(cornerRadius: 6, style: .continuous)
                            .fill(Color(charkleHex: swatch.hex))
                            .frame(height: 24)
                    }
                }
            }

            if !asset.tags.isEmpty {
                QuickLookFlowWrap(spacing: 6) {
                    ForEach(asset.tags, id: \.self) { tag in
                        Text("#\(tag)")
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(.white.opacity(0.86))
                            .padding(.horizontal, 8)
                            .padding(.vertical, 3.5)
                            .background(Color.white.opacity(0.12), in: Capsule(style: .continuous))
                    }
                }
            }

            if let urlStr = asset.sourceURL, let url = URL(string: urlStr) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("来源链接")
                        .font(.system(size: 10.5, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.52))
                    Link(urlStr, destination: url)
                        .font(.system(size: 11.5))
                        .lineLimit(2)
                }
            }

            if let aiGen = resolvedMeta.aiGeneration, !aiGen.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        Text(aiGen.generator ?? "AI 生图提示词")
                            .font(.system(size: 10.5, weight: .semibold))
                            .foregroundStyle(Color.accentColor)
                        Spacer()
                        if let prompt = aiGen.prompt, !prompt.isEmpty {
                            Button {
                                let pb = NSPasteboard.general
                                pb.clearContents()
                                pb.setString(prompt, forType: .string)
                                coordinator.showToast("已复制正向 Prompt", icon: "doc.on.doc")
                            } label: {
                                Text("复制 Prompt")
                                    .font(.system(size: 10, weight: .medium))
                                    .foregroundStyle(.white.opacity(0.85))
                                    .padding(.horizontal, 7)
                                    .padding(.vertical, 2.5)
                                    .background(Color.white.opacity(0.12), in: Capsule(style: .continuous))
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    if let prompt = aiGen.prompt, !prompt.isEmpty {
                        Text(prompt)
                            .font(.system(size: 11.5))
                            .foregroundStyle(.white.opacity(0.86))
                            .lineSpacing(3.5)
                            .textSelection(.enabled)
                    }
                    if let model = aiGen.modelName, !model.isEmpty {
                        Text("模型：\(model)")
                            .font(.system(size: 10.5, design: .monospaced))
                            .foregroundStyle(.white.opacity(0.62))
                    }
                }
                .padding(10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            }

            if let exif = resolvedMeta.photoExif, exif.hasMeaningfulCameraExif {
                VStack(alignment: .leading, spacing: 4) {
                    Text("拍摄参数 (EXIF)")
                        .font(.system(size: 10.5, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.52))
                    if let cam = exif.cameraDisplayName {
                        Text(cam)
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(.white.opacity(0.90))
                    }
                    if let lens = exif.lensModel {
                        Text(lens)
                            .font(.system(size: 11))
                            .foregroundStyle(.white.opacity(0.72))
                    }
                    if let summary = exif.exposureSummary {
                        Text(summary)
                            .font(.system(size: 11, weight: .medium, design: .monospaced))
                            .foregroundStyle(.white.opacity(0.82))
                    }
                    if let date = exif.capturedAt {
                        Text(date)
                            .font(.system(size: 10.5, design: .monospaced))
                            .foregroundStyle(.white.opacity(0.56))
                    }
                }
                .padding(10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            }

            if !asset.notes.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    Text("备注 / 来源详情")
                        .font(.system(size: 10.5, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.52))
                    Text(asset.notes)
                        .font(.system(size: 12))
                        .foregroundStyle(.white.opacity(0.84))
                        .lineSpacing(4)
                        .textSelection(.enabled)
                }
            }
        }
        .padding(.horizontal, 14)
        .padding(.bottom, 16)
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
            .rotationEffect(.degrees(rotationDegrees))
            .scaleEffect(x: flipHorizontal ? -1 : 1, y: flipVertical ? -1 : 1)
            .scaleEffect(zoomScale * quarterTurnFitScale)
            .offset(panOffset)
            .shadow(color: .black.opacity(0.38), radius: 24, y: 10)
            .gesture(
                MagnifyGesture()
                    .onChanged { val in
                        if gestureStartScale == nil { gestureStartScale = zoomScale }
                        zoomScale = max(0.5, min(maxZoomLimit, (gestureStartScale ?? 1.0) * val.magnification))
                    }
                    .onEnded { _ in
                        gestureStartScale = nil
                        if zoomScale < 1.02 {
                            withAnimation(CharkleMotion.accessible(CharkleMotion.uiSpring, reduced: reduceMotion)) {
                                zoomScale = 1.0
                                panOffset = .zero
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
    }

    private var webBookmarkDetailCard: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 10) {
                Circle()
                    .fill(Color(charkleHex: asset.dominantColors.first?.hex ?? "#5C6B73"))
                    .frame(width: 12, height: 12)
                Text(asset.sourceDomain ?? "网页书签")
                    .font(.system(size: 13, weight: .semibold, design: .monospaced))
                    .foregroundStyle(.secondary)
                Spacer()
                if let urlStr = asset.sourceURL, let url = URL(string: urlStr) {
                    Button {
                        NSWorkspace.shared.open(url)
                    } label: {
                        Label("在浏览器中打开", systemImage: "safari")
                            .font(.system(size: 12, weight: .semibold))
                    }
                    .buttonStyle(.borderedProminent)
                }
            }
            Text(asset.title)
                .font(.system(size: 20, weight: .semibold))
            if let urlStr = asset.sourceURL {
                Text(urlStr)
                    .font(.system(size: 12, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
            }
            if !asset.notes.isEmpty {
                Divider()
                Text(asset.notes)
                    .font(.system(size: 13.5))
                    .lineSpacing(5)
            }
        }
        .padding(26)
        .frame(maxWidth: 620)
        .background(CharkleTheme.surfaceElevated(for: colorScheme), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
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
                                isLongStripScrollMode ? Color.accentColor.opacity(0.78) : Color.white.opacity(0.14),
                                in: Capsule(style: .continuous)
                            )
                        }
                        .buttonStyle(CharkleTactileButtonStyle())
                        .help("切换长图按宽滚动阅读 / 适应窗口缩放查看")

                        hudDivider
                    }

                    HStack(spacing: 4) {
                        hudIconButton("minus.magnifyingglass", help: "缩小") {
                            isLongStripScrollMode = false
                            withAnimation(CharkleMotion.accessible(CharkleMotion.uiSpring, reduced: reduceMotion)) {
                                zoomScale = max(0.5, zoomScale * 0.8)
                            }
                        }
                        Text("\(Int((zoomScale * 100).rounded()))%")
                            .font(.system(size: 11, weight: .semibold, design: .monospaced))
                            .monospacedDigit()
                            .foregroundStyle(.white.opacity(0.88))
                            .frame(minWidth: 42)
                        hudIconButton("plus.magnifyingglass", help: "放大") {
                            isLongStripScrollMode = false
                            withAnimation(CharkleMotion.accessible(CharkleMotion.uiSpring, reduced: reduceMotion)) {
                                zoomScale = min(maxZoomLimit, zoomScale * 1.25)
                            }
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
                                .background(Color.accentColor.opacity(0.72), in: RoundedRectangle(cornerRadius: 7, style: .continuous))
                            }
                            .buttonStyle(CharkleTactileButtonStyle())
                            .help("还原旋转与翻转")
                            .transition(.opacity.combined(with: .scale(scale: 0.9)))
                        }
                    }
                    .animation(CharkleMotion.accessible(CharkleMotion.settleStrong, reduced: reduceMotion), value: hasActiveVisualTransform)

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
                    } label: {
                        Image(systemName: "rectangle.3.group.badge.plus")
                            .font(.system(size: 13, weight: .medium))
                            .foregroundStyle(.white.opacity(0.9))
                            .frame(width: 28, height: 28)
                    }
                    .menuStyle(.borderlessButton)
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

    private func handleQuickLookKeyDown(_ event: NSEvent) -> NSEvent? {
        if confirmPermanentDelete { return event }
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        let isUnmodified = flags.isEmpty || flags == .numericPad || flags == .function
        let isShiftOnly = flags == .shift

        if isUnmodified {
            switch event.keyCode {
            case 49, 53: // Space or Escape -> close Quick Look immediately
                if event.isARepeat { return nil }
                onClose()
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
                withAnimation(CharkleMotion.accessible(CharkleMotion.uiSpring, reduced: reduceMotion)) {
                    zoomScale = min(5.0, zoomScale * 1.25)
                }
                return nil
            }
            if isUnmodified && chars == "-" {
                withAnimation(CharkleMotion.accessible(CharkleMotion.uiSpring, reduced: reduceMotion)) {
                    let next = max(0.5, zoomScale * 0.8)
                    zoomScale = next
                    if next <= 1.01 {
                        panOffset = .zero
                        panStartOffset = .zero
                    }
                }
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
                    isActive ? Color.accentColor.opacity(0.78) : Color.clear,
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
    }

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func makeNSView(context: Context) -> NSImageView {
        let view = NSImageView()
        view.animates = true
        view.imageScaling = .scaleProportionallyDown
        view.image = NSImage(contentsOf: url)
        context.coordinator.currentURL = url
        return view
    }

    func updateNSView(_ nsView: NSImageView, context: Context) {
        guard context.coordinator.currentURL != url else { return }
        context.coordinator.currentURL = url
        nsView.image = NSImage(contentsOf: url)
        nsView.animates = true
    }
}

struct QuickLookVideoPlayerView: NSViewRepresentable {
    let url: URL
    var autoPlay: Bool = true

    final class Coordinator {
        var currentURL: URL?
    }

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func makeNSView(context: Context) -> AVPlayerView {
        let view = AVPlayerView()
        view.controlsStyle = .floating
        let player = AVPlayer(url: url)
        view.player = player
        context.coordinator.currentURL = url
        if autoPlay {
            player.play()
        }
        return view
    }

    func updateNSView(_ nsView: AVPlayerView, context: Context) {
        guard context.coordinator.currentURL != url else { return }
        context.coordinator.currentURL = url
        nsView.player?.pause()
        let player = AVPlayer(url: url)
        nsView.player = player
        if autoPlay {
            player.play()
        }
    }

    static func dismantleNSView(_ nsView: AVPlayerView, coordinator: Coordinator) {
        nsView.player?.pause()
        nsView.player = nil
        coordinator.currentURL = nil
    }
}

struct QuickLookPDFView: NSViewRepresentable {
    let url: URL

    func makeNSView(context: Context) -> PDFView {
        let view = PDFView()
        view.autoScales = true
        view.displayMode = .singlePageContinuous
        view.document = PDFDocument(url: url)
        return view
    }

    func updateNSView(_ nsView: PDFView, context: Context) {
        if nsView.document?.documentURL != url {
            nsView.document = PDFDocument(url: url)
        }
    }
}

struct QuickLookAudioStudioCard: View {
    @Environment(\.colorScheme) private var colorScheme

    let asset: AssetRecord
    let fileURL: URL?

    @State private var player: AVPlayer?
    @State private var isPlaying: Bool = false
    @State private var progress: Double = 0

    var body: some View {
        let peaks = asset.waveformPeaks.isEmpty
            ? (0..<48).map { i -> Float in Float(0.25 + 0.65 * abs(sin(Double(i) * 0.35))) }
            : asset.waveformPeaks
        let accent = Color(charkleHex: asset.dominantColors.first?.hex ?? "#3D5A80")

        VStack(alignment: .leading, spacing: 18) {
            HStack(spacing: 12) {
                Button {
                    togglePlayback()
                } label: {
                    Image(systemName: isPlaying ? "pause.fill" : "play.fill")
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
                            .fill(frac <= progress ? accent : Color.primary.opacity(0.18))
                            .frame(height: max(6, geo.size.height * CGFloat(max(0.15, min(1.0, peak)))))
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .contentShape(Rectangle())
                .gesture(
                    DragGesture(minimumDistance: 0)
                        .onChanged { value in
                            let ratio = max(0, min(1, Double(value.location.x / max(1, geo.size.width))))
                            progress = ratio
                            if let duration = asset.durationSeconds, let player {
                                let target = CMTime(seconds: duration * ratio, preferredTimescale: 600)
                                player.seek(to: target)
                            }
                        }
                )
            }
            .frame(height: 76)
        }
        .padding(24)
        .background(CharkleTheme.surfaceElevated(for: colorScheme), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .shadow(color: .black.opacity(0.36), radius: 24, y: 10)
        .onDisappear {
            player?.pause()
            player = nil
        }
    }

    private func togglePlayback() {
        guard let fileURL else { return }
        if player == nil {
            player = AVPlayer(url: fileURL)
        }
        if isPlaying {
            player?.pause()
            isPlaying = false
        } else {
            player?.play()
            isPlaying = true
        }
    }
}
