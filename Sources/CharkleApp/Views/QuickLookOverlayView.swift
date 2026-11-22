import AppKit
import AVKit
import CharkleCanvas
import CharkleCore
import PDFKit
import SwiftUI

/// Full-Media Quick Look (`Space` to open/close) with Kubai Tip 015 continuous card-to-overlay hero zoom,
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
    @State private var zoomScale: CGFloat = 1.0
    @State private var gestureStartScale: CGFloat?
    @State private var panOffset: CGSize = .zero
    @State private var panStartOffset: CGSize = .zero
    @State private var showSecondaryControls: Bool = false

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
                // Top minimal title bar (fades in after 45% hero continuity per Kubai 015)
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

                    Button(action: onClose) {
                        Image(systemName: "xmark")
                            .font(.system(size: 11, weight: .bold))
                            .foregroundStyle(.white.opacity(0.86))
                            .frame(width: 28, height: 28)
                            .charkleLiquidGlass(.darkNotch, in: Circle(), interactive: true)
                    }
                    .buttonStyle(.plain)
                    .help("关闭预览 (Space / Esc)")
                }
                .padding(.horizontal, 24)
                .padding(.top, 18)
                .opacity(showSecondaryControls ? 1 : 0)

                Spacer(minLength: 12)

                // Center Media Surface (Continuous Hero Element)
                mediaStage
                    .matchedGeometryEffect(id: asset.id, in: heroNamespace)
                    .padding(.horizontal, 48)
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
            zoomScale = 1.0
            panOffset = .zero
            panStartOffset = .zero
            originalURL = nil
            highResImage = nil
            async let orig = library.resolveOriginalURL(for: asset.id)
            async let preview = library.thumbnailLoader.loadImage(for: asset.id, tier: .preview1400)
            let (resolvedURL, previewImg) = await (orig, preview)
            if !Task.isCancelled {
                originalURL = resolvedURL
                highResImage = previewImg
            }
        }
        .onAppear {
            if reduceMotion {
                showSecondaryControls = true
            } else {
                withAnimation(CharkleMotion.settleStrong.delay(0.11)) {
                    showSecondaryControls = true
                }
            }
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

    // MARK: - 7-MediaKind Stage

    @ViewBuilder
    private var mediaStage: some View {
        switch asset.mediaKind {
        case .image, .designFile:
            zoomableImageStage
        case .animatedImage:
            if let url = originalURL {
                AnimatedGIFPlayerView(url: url)
                    .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
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
                textDocumentReaderCard
            }
        case .webBookmark:
            webBookmarkDetailCard
        }
    }

    private var zoomableImageStage: some View {
        let shape = RoundedRectangle(cornerRadius: 16, style: .continuous)
        return ZStack {
            if let image = highResImage ?? library.thumbnailLoader.cachedImage(for: asset.id, tier: .grid520) {
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
        .scaleEffect(zoomScale)
        .offset(panOffset)
        .shadow(color: .black.opacity(0.42), radius: 28, y: 12)
        .gesture(
            MagnifyGesture()
                .onChanged { val in
                    if gestureStartScale == nil { gestureStartScale = zoomScale }
                    zoomScale = max(0.5, min(5.0, (gestureStartScale ?? 1.0) * val.magnification))
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

    private var textDocumentReaderCard: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text(CanvasFormatters.fileExtensionBadge(for: asset.fileName))
                    .font(.system(size: 11, weight: .bold, design: .monospaced))
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(Color.primary.opacity(0.08), in: RoundedRectangle(cornerRadius: 6, style: .continuous))
                Text(asset.title)
                    .font(.system(size: 17, weight: .semibold))
                Spacer()
            }
            Divider()
            ScrollView(.vertical) {
                Text(asset.notes.isEmpty ? (asset.ocrText ?? "暂无可预览正文，可点击底部使用默认应用打开。") : asset.notes)
                    .font(.system(size: 14))
                    .lineSpacing(6)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .padding(24)
        .frame(maxWidth: 680, maxHeight: 540)
        .background(CharkleTheme.surfaceElevated(for: colorScheme), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .shadow(color: .black.opacity(0.35), radius: 24, y: 10)
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
                if asset.mediaKind == .image || asset.mediaKind == .designFile {
                    HStack(spacing: 4) {
                        hudIconButton("minus.magnifyingglass", help: "缩小") {
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
                            withAnimation(CharkleMotion.accessible(CharkleMotion.uiSpring, reduced: reduceMotion)) {
                                zoomScale = min(5.0, zoomScale * 1.25)
                            }
                        }
                        hudIconButton("1.magnifyingglass", help: "重置 100%") {
                            withAnimation(CharkleMotion.accessible(CharkleMotion.uiSpring, reduced: reduceMotion)) {
                                zoomScale = 1.0
                                panOffset = .zero
                                panStartOffset = .zero
                            }
                        }
                    }

                    hudDivider
                }

                // Rating stars
                HStack(spacing: 3) {
                    ForEach(1...5, id: \.self) { star in
                        Button {
                            let target = asset.rating == star ? 0 : star
                            Task { await library.setRating(target, for: [asset.id]) }
                        } label: {
                            Image(systemName: star <= asset.rating ? "star.fill" : "star")
                                .font(.system(size: 12))
                                .foregroundStyle(star <= asset.rating ? Color(charkleHex: "#F2C14E") : .white.opacity(0.45))
                        }
                        .buttonStyle(.plain)
                    }
                }

                hudDivider

                hudIconButton(asset.pinnedOffline ? "pin.fill" : "pin", help: asset.pinnedOffline ? "取消离线钉选" : "钉选离线") {
                    Task {
                        await library.togglePinOffline(ids: [asset.id], pinned: !asset.pinnedOffline)
                        coordinator.showToast(asset.pinnedOffline ? "已取消离线钉选" : "已钉选离线", icon: "pin.fill")
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

                if let url = originalURL {
                    hudIconButton("arrow.up.forward.app", help: "使用默认应用打开") {
                        NSWorkspace.shared.open(url)
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

    private func hudIconButton(_ systemName: String, help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(.white.opacity(0.9))
                .frame(width: 28, height: 28)
        }
        .buttonStyle(.plain)
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

private struct AnimatedGIFPlayerView: NSViewRepresentable {
    let url: URL

    func makeNSView(context: Context) -> NSImageView {
        let view = NSImageView()
        view.animates = true
        view.imageScaling = .scaleProportionallyDown
        view.image = NSImage(contentsOf: url)
        return view
    }

    func updateNSView(_ nsView: NSImageView, context: Context) {
        nsView.image = NSImage(contentsOf: url)
        nsView.animates = true
    }
}

private struct QuickLookVideoPlayerView: NSViewRepresentable {
    let url: URL

    func makeNSView(context: Context) -> AVPlayerView {
        let view = AVPlayerView()
        view.controlsStyle = .floating
        let player = AVPlayer(url: url)
        view.player = player
        player.play()
        return view
    }

    func updateNSView(_ nsView: AVPlayerView, context: Context) {}

    static func dismantleNSView(_ nsView: AVPlayerView, coordinator: ()) {
        nsView.player?.pause()
        nsView.player = nil
    }
}

private struct QuickLookPDFView: NSViewRepresentable {
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

private struct QuickLookAudioStudioCard: View {
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
