import AppKit
import AVKit
import CharkleCanvas
import CharkleCore
import ModelIO
import SceneKit
import SceneKit.ModelIO
import SwiftUI

// MARK: - 1. GitHub Repository + README Reader Card (Reference Screenshot Style)

struct QuickLookGitHubRepoCard: View {
    @Environment(\.colorScheme) private var colorScheme

    let asset: AssetRecord
    let repo: GitHubRepoMetadata
    let onRefresh: () -> Void
    @State private var isRefreshing: Bool = false

    private var repoURL: URL? {
        asset.sourceURL.flatMap(URL.init(string:)) ?? URL(string: "https://github.com/\(repo.fullName)")
    }

    var body: some View {
        let cardShape = RoundedRectangle(cornerRadius: 18, style: .continuous)
        let cardFill = colorScheme == .dark ? Color(charkleHex: "#18191D") : Color(charkleHex: "#FAFAFB")

        ScrollView(.vertical) {
            VStack(alignment: .leading, spacing: 18) {
                // Header: Owner Avatar + owner / repo + Actions
                HStack(alignment: .center, spacing: 12) {
                    if let avatarStr = repo.ownerAvatarURL, let avatarURL = URL(string: avatarStr) {
                        RemoteCachedImageView(url: avatarURL, contentMode: .fill) {
                            ownerMonogram
                        }
                        .frame(width: 36, height: 36)
                        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                    } else {
                        ownerMonogram
                    }

                    HStack(spacing: 4) {
                        Text(repo.owner)
                            .foregroundStyle(.secondary)
                        Text("/")
                            .foregroundStyle(.tertiary)
                        Text(repo.repo)
                            .foregroundStyle(.primary)
                    }
                    .font(.system(size: 18, weight: .bold))
                    .lineLimit(1)

                    Spacer(minLength: 8)

                    Button {
                        isRefreshing = true
                        onRefresh()
                        Task {
                            try? await Task.sleep(for: .seconds(1.2))
                            isRefreshing = false
                        }
                    } label: {
                        Image(systemName: "arrow.clockwise")
                            .font(.system(size: 12, weight: .semibold))
                            .rotationEffect(.degrees(isRefreshing ? 360 : 0))
                            .frame(width: 28, height: 28)
                            .background(Color.primary.opacity(0.08), in: Circle())
                    }
                    .buttonStyle(.plain)
                    .help("重新同步仓库星标与 README")

                    if let url = repoURL {
                        Button {
                            NSWorkspace.shared.open(url)
                        } label: {
                            HStack(spacing: 5) {
                                Image(systemName: "arrow.up.right.square")
                                    .font(.system(size: 11.5, weight: .semibold))
                                Text("GitHub")
                                    .font(.system(size: 12, weight: .semibold))
                            }
                            .padding(.horizontal, 11)
                            .padding(.vertical, 6)
                            .background(Color.primary.opacity(0.09), in: Capsule(style: .continuous))
                        }
                        .buttonStyle(.plain)
                    }
                }

                // Description
                if let desc = repo.description, !desc.isEmpty {
                    Text(desc)
                        .font(.system(size: 14))
                        .foregroundStyle(.primary.opacity(0.86))
                        .lineSpacing(4)
                        .textSelection(.enabled)
                }

                // Language + Homepage
                HStack(spacing: 10) {
                    if let lang = repo.language, !lang.isEmpty {
                        HStack(spacing: 5) {
                            Circle()
                                .fill(languageColor(lang))
                                .frame(width: 9, height: 9)
                            Text(lang)
                                .font(.system(size: 12.5, weight: .medium))
                                .foregroundStyle(.secondary)
                        }
                    }
                    if let hp = repo.homepageURL, let hpURL = URL(string: hp.hasPrefix("http") ? hp : "https://\(hp)") {
                        Text("·").foregroundStyle(.tertiary)
                        Link(hp.replacingOccurrences(of: "https://", with: "").replacingOccurrences(of: "http://", with: ""), destination: hpURL)
                            .font(.system(size: 12.5, weight: .medium))
                            .lineLimit(1)
                    }
                    if let license = repo.licenseName, !license.isEmpty {
                        Text("·").foregroundStyle(.tertiary)
                        Text(license)
                            .font(.system(size: 12, design: .monospaced))
                            .foregroundStyle(.secondary)
                    }
                }

                // Stars / Forks / Watching tabular metrics
                HStack(spacing: 16) {
                    metricPair(value: repo.stars, label: "stars")
                    metricPair(value: repo.forks, label: "forks")
                    if let w = repo.watchers, w > 0 {
                        metricPair(value: w, label: "watching")
                    }
                }

                // Topic pills
                if !repo.topics.isEmpty {
                    QuickLookFlowWrap(spacing: 6) {
                        ForEach(repo.topics, id: \.self) { topic in
                            Text(topic)
                                .font(.system(size: 11.5, weight: .medium))
                                .foregroundStyle(Color(charkleHex: colorScheme == .dark ? "#93C5FD" : "#2563EB"))
                                .padding(.horizontal, 9)
                                .padding(.vertical, 4)
                                .background(
                                    Color(charkleHex: "#3B82F6").opacity(colorScheme == .dark ? 0.18 : 0.11),
                                    in: Capsule(style: .continuous)
                                )
                        }
                    }
                }

                // GitHub Social OpenGraph Preview Card
                let ogStr = repo.openGraphImageURL ?? "https://opengraph.githubassets.com/1/\(repo.owner)/\(repo.repo)"
                if let ogURL = URL(string: ogStr) {
                    RemoteCachedImageView(url: ogURL, contentMode: .fit) {
                        EmptyView()
                    }
                    .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                    .overlay(
                        RoundedRectangle(cornerRadius: 12, style: .continuous)
                            .strokeBorder(Color.primary.opacity(0.08), lineWidth: 0.75)
                    )
                }

                Divider()

                // README Section
                VStack(alignment: .leading, spacing: 12) {
                    Text("README")
                        .font(.system(size: 11, weight: .bold, design: .monospaced))
                        .tracking(0.8)
                        .foregroundStyle(.secondary)

                    if let readme = repo.readmeMarkdown, !readme.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        QuickLookMarkdownContentView(
                            markdown: readme,
                            urlContext: .github(owner: repo.owner, repo: repo.repo, branch: repo.defaultBranch)
                        )
                    } else {
                        Text("暂未拉取到 README 内容，可点击右上角刷新重试或前往 GitHub 查看。")
                            .font(.system(size: 13))
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .padding(26)
            .charkleCleanScrollbars(hidden: false)
        }
        .frame(maxWidth: 760, maxHeight: 680)
        .clipShape(cardShape)
        .background {
            cardShape
                .fill(cardFill)
                .shadow(color: .black.opacity(0.42), radius: 28, y: 12)
        }
        .overlay(
            cardShape
                .strokeBorder(Color.white.opacity(colorScheme == .dark ? 0.10 : 0.45), lineWidth: 0.75)
        )
    }

    private var ownerMonogram: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Color.accentColor.opacity(0.18))
            Text(String(repo.owner.prefix(1)).uppercased())
                .font(.system(size: 16, weight: .bold))
                .foregroundStyle(Color.accentColor)
        }
        .frame(width: 36, height: 36)
    }

    private func metricPair(value: Int, label: String) -> some View {
        HStack(spacing: 4) {
            Text("\(value)")
                .font(.system(size: 13.5, weight: .bold, design: .rounded))
                .monospacedDigit()
            Text(label)
                .font(.system(size: 12.5))
                .foregroundStyle(.secondary)
        }
    }

    private func languageColor(_ lang: String) -> Color {
        switch lang.lowercased() {
        case "swift": Color(charkleHex: "#F05138")
        case "typescript": Color(charkleHex: "#3178C6")
        case "javascript": Color(charkleHex: "#F1E05A")
        case "python": Color(charkleHex: "#3572A5")
        case "rust": Color(charkleHex: "#DEA584")
        case "go": Color(charkleHex: "#00ADD8")
        case "html": Color(charkleHex: "#E34C26")
        case "css": Color(charkleHex: "#563D7C")
        default: Color(charkleHex: "#60A5FA")
        }
    }
}

// MARK: - 2. Social Post Reader Card (X / Threads / Bluesky + Standalone Image Extraction)

struct QuickLookSocialPostCard: View {
    @Environment(\.colorScheme) private var colorScheme

    let asset: AssetRecord
    let post: SocialPostMetadata
    let originalURL: URL?
    let onExtractMedia: (_ attachment: SocialMediaAttachment, _ index: Int) -> Void
    let onExtractAllMedia: (() -> Void)?
    let onRetryFetch: () -> Void

    @State private var extractingIndex: Int?
    @State private var isExtractingAll: Bool = false
    @State private var isRetrying: Bool = false

    private var isLocalVideoFile: Bool {
        guard let ext = originalURL?.pathExtension.lowercased() else { return false }
        return ["mp4", "mov", "m4v", "webm"].contains(ext)
    }

    private var attachments: [SocialMediaAttachment] {
        post.effectiveAttachments
    }

    var body: some View {
        let cardShape = RoundedRectangle(cornerRadius: 18, style: .continuous)
        let cardFill = colorScheme == .dark ? Color(charkleHex: "#1B1C20") : Color.white

        ScrollView(.vertical) {
            VStack(alignment: .leading, spacing: 16) {
                // Author Header
                HStack(spacing: 11) {
                    if let avatarStr = post.authorAvatarURL, let url = URL(string: avatarStr) {
                        RemoteCachedImageView(url: url, contentMode: .fill) {
                            authorFallbackAvatar
                        }
                        .frame(width: 40, height: 40)
                        .clipShape(Circle())
                    } else {
                        authorFallbackAvatar
                    }

                    VStack(alignment: .leading, spacing: 2) {
                        HStack(spacing: 6) {
                            Text(post.authorName)
                                .font(.system(size: 14.5, weight: .bold))
                            Text("@\(post.authorHandle)")
                                .font(.system(size: 12.5))
                                .foregroundStyle(.secondary)
                        }
                        if let published = post.publishedAtText, !published.isEmpty {
                            Text(published)
                                .font(.system(size: 11.5))
                                .foregroundStyle(.tertiary)
                        }
                    }

                    Spacer()

                    Text(post.platform.displayName)
                        .font(.system(size: 11, weight: .bold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 4)
                        .background(platformBadgeColor, in: Capsule(style: .continuous))
                }

                // Article Headline (if X Article)
                if let article = post.articleTitle, !article.isEmpty {
                    Text(article)
                        .font(.system(size: 17, weight: .bold))
                        .textSelection(.enabled)
                }

                // Post Body Text (always live, crisp & selectable)
                if !post.bodyText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    Text(post.bodyText)
                        .font(.system(size: 15))
                        .lineSpacing(5)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }

                // Quoted Post
                if let quotedText = post.quotedText, !quotedText.isEmpty {
                    VStack(alignment: .leading, spacing: 6) {
                        if let qAuthor = post.quotedAuthor, !qAuthor.isEmpty {
                            Text(qAuthor)
                                .font(.system(size: 12, weight: .semibold))
                                .foregroundStyle(.secondary)
                        }
                        Text(quotedText)
                            .font(.system(size: 13.5))
                            .foregroundStyle(.primary.opacity(0.85))
                            .lineSpacing(4)
                            .textSelection(.enabled)
                    }
                    .padding(12)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                    .overlay(
                        RoundedRectangle(cornerRadius: 12, style: .continuous)
                            .strokeBorder(Color.primary.opacity(0.10), lineWidth: 0.75)
                    )
                }

                // Embedded Media Attachments (Playable Videos/GIFs + High-Res Photos + Independent Extraction)
                if !attachments.isEmpty {
                    if attachments.count > 1, let onExtractAllMedia {
                        HStack(spacing: 8) {
                            Text("推文内含 \(attachments.count) 个媒体")
                                .font(.system(size: 11.5, weight: .medium))
                                .foregroundStyle(.secondary)
                            Spacer()
                            Button {
                                isExtractingAll = true
                                onExtractAllMedia()
                                Task {
                                    try? await Task.sleep(for: .seconds(1.6))
                                    isExtractingAll = false
                                }
                            } label: {
                                HStack(spacing: 5) {
                                    if isExtractingAll {
                                        ProgressView().controlSize(.mini)
                                    } else {
                                        Image(systemName: "square.and.arrow.down.on.square")
                                            .font(.system(size: 10.5, weight: .semibold))
                                    }
                                    Text("全部提取为独立素材")
                                        .font(.system(size: 11, weight: .semibold))
                                }
                                .foregroundStyle(Color.accentColor)
                                .padding(.horizontal, 10)
                                .padding(.vertical, 4.5)
                                .background(Color.accentColor.opacity(0.12), in: Capsule(style: .continuous))
                            }
                            .buttonStyle(.plain)
                        }
                    }

                    let useSingleColumn = attachments.count == 1 || attachments.contains(where: { $0.kind == .video || $0.kind == .gif })
                    let cols = useSingleColumn
                        ? [GridItem(.flexible())]
                        : [GridItem(.flexible(), spacing: 8), GridItem(.flexible(), spacing: 8)]

                    LazyVGrid(columns: cols, spacing: 10) {
                        ForEach(Array(attachments.enumerated()), id: \.offset) { idx, attachment in
                            socialAttachmentView(attachment: attachment, index: idx)
                        }
                    }
                } else if isLocalVideoFile, let videoFile = originalURL {
                    SocialPostInlineVideoPlayer(url: videoFile)
                        .frame(height: 360)
                        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                }

                // Media Fetch Failed Banner + Try Again CTA (matching Img 3)
                if post.mediaFetchFailed {
                    VStack(alignment: .leading, spacing: 8) {
                        HStack(spacing: 6) {
                            Text("媒体暂未保存到本地：未能连接目标服务器 ·")
                                .font(.system(size: 12))
                                .foregroundStyle(.secondary)
                            if let url = URL(string: post.originalURL) {
                                Link("前往 \(post.platform.displayName) 观看", destination: url)
                                    .font(.system(size: 12, weight: .medium))
                            }
                        }
                        Button {
                            isRetrying = true
                            onRetryFetch()
                            Task {
                                try? await Task.sleep(for: .seconds(1.5))
                                isRetrying = false
                            }
                        } label: {
                            HStack(spacing: 6) {
                                if isRetrying {
                                    ProgressView().controlSize(.mini)
                                }
                                Text("重试获取")
                                    .font(.system(size: 12.5, weight: .semibold))
                            }
                            .foregroundStyle(.white)
                            .padding(.horizontal, 14)
                            .padding(.vertical, 6)
                            .background(Color.accentColor, in: Capsule(style: .continuous))
                        }
                        .buttonStyle(.plain)
                    }
                }

                Divider()

                // Engagement Counts + Open on Platform
                HStack(spacing: 16) {
                    if let r = post.replyCount { engagementMetric(r, "replies") }
                    if let rt = post.repostCount { engagementMetric(rt, "reposts") }
                    if let l = post.likeCount { engagementMetric(l, "likes") }
                    if let v = post.viewCount { engagementMetric(v, "views") }

                    Spacer()

                    if let url = URL(string: post.originalURL) {
                        Link(post.platform.openActionLabel, destination: url)
                            .font(.system(size: 12.5, weight: .semibold))
                    }
                }
            }
            .padding(24)
            .charkleCleanScrollbars(hidden: false)
        }
        .frame(maxWidth: 680, maxHeight: 680)
        .clipShape(cardShape)
        .background {
            cardShape
                .fill(cardFill)
                .shadow(color: .black.opacity(colorScheme == .dark ? 0.40 : 0.14), radius: 24, y: 10)
        }
        .overlay(
            cardShape
                .strokeBorder(Color.primary.opacity(0.10), lineWidth: 0.75)
        )
    }

    @ViewBuilder
    private func socialAttachmentView(attachment: SocialMediaAttachment, index: Int) -> some View {
        let isVideoLike = attachment.kind == .video || attachment.kind == .gif
        VStack(alignment: .trailing, spacing: 6) {
            if isVideoLike {
                let playbackURL: URL? = (index == 0 && isLocalVideoFile) ? originalURL : URL(string: attachment.url)
                if let playURL = playbackURL {
                    SocialPostInlineVideoPlayer(url: playURL)
                        .frame(height: 320)
                        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                        .overlay(
                            RoundedRectangle(cornerRadius: 12, style: .continuous)
                                .strokeBorder(Color.primary.opacity(0.10), lineWidth: 0.6)
                        )
                } else {
                    mediaFailedPlaceholder
                }

                HStack {
                    Label(attachment.kind == .gif ? "动图媒体" : "视频媒体", systemImage: "film")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(.secondary)
                    Spacer()
                    extractMediaButton(attachment: attachment, index: index, pillStyle: false)
                }
            } else {
                let previewStr = attachment.thumbnailURL ?? attachment.url
                ZStack(alignment: .bottomTrailing) {
                    if let imgURL = URL(string: previewStr) {
                        RemoteCachedImageView(
                            url: imgURL,
                            contentMode: .fit,
                            maxHeight: attachments.count == 1 ? 420 : 240
                        ) {
                            ProgressView().frame(height: 180)
                        } failurePlaceholder: {
                            mediaFailedPlaceholder
                        }
                        .frame(maxWidth: .infinity)
                        .background(Color.primary.opacity(0.05))
                        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                    } else {
                        mediaFailedPlaceholder
                    }

                    extractMediaButton(attachment: attachment, index: index, pillStyle: true)
                        .padding(10)
                }
            }
        }
    }

    private func extractMediaButton(attachment: SocialMediaAttachment, index: Int, pillStyle: Bool) -> some View {
        let iconName = (attachment.kind == .video || attachment.kind == .gif) ? "film.stack" : "photo.badge.plus"
        let title = switch attachment.kind {
        case .photo: "提取为单独图片"
        case .video: "提取为单独视频"
        case .gif: "提取为单独动图"
        }
        return Button {
            extractingIndex = index
            onExtractMedia(attachment, index)
            Task {
                try? await Task.sleep(for: .seconds(1.5))
                if extractingIndex == index { extractingIndex = nil }
            }
        } label: {
            HStack(spacing: 5) {
                if extractingIndex == index {
                    ProgressView().controlSize(.mini).tint(pillStyle ? .white : .accentColor)
                } else {
                    Image(systemName: iconName)
                        .font(.system(size: 11, weight: .semibold))
                }
                Text(title)
                    .font(.system(size: 11, weight: .semibold))
            }
            .foregroundStyle(pillStyle ? Color.white : Color.accentColor)
            .padding(.horizontal, 10)
            .padding(.vertical, 5.5)
            .background(
                pillStyle ? Color.black.opacity(0.74) : Color.accentColor.opacity(0.12),
                in: Capsule(style: .continuous)
            )
        }
        .buttonStyle(.plain)
        .help("将此媒体提取为独立素材，并自动在备注和来源链接中保留原推文出处")
    }

    private var authorFallbackAvatar: some View {
        ZStack {
            Circle().fill(platformBadgeColor.opacity(0.85))
            Text(String((post.authorName.first ?? post.authorHandle.first ?? "X")).uppercased())
                .font(.system(size: 15, weight: .bold))
                .foregroundStyle(.white)
        }
        .frame(width: 40, height: 40)
    }

    private var mediaFailedPlaceholder: some View {
        VStack(spacing: 8) {
            Image(systemName: "photo.badge.exclamationmark")
                .font(.system(size: 26))
                .foregroundStyle(.secondary)
            Text("图片加载失败")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, minHeight: 160)
    }

    private var platformBadgeColor: Color {
        switch post.platform {
        case .x: Color(charkleHex: "#18181B")
        case .threads: Color(charkleHex: "#27272A")
        case .bluesky: Color(charkleHex: "#0284C7")
        }
    }

    private func engagementMetric(_ count: Int, _ label: String) -> some View {
        HStack(spacing: 4) {
            Text("\(count)")
                .font(.system(size: 12.5, weight: .bold, design: .rounded))
                .monospacedDigit()
            Text(label)
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
        }
    }
}

private struct SocialPostInlineVideoPlayer: NSViewRepresentable {
    let url: URL

    final class Coordinator {
        var currentURL: URL?
        var loadTask: Task<Void, Never>?

        func attach(url: URL, to view: AVPlayerView) {
            loadTask?.cancel()
            currentURL = url
            view.player?.pause()
            view.player = nil

            // Defer AVPlayer / VideoToolbox initialization slightly past the opening animation frame
            // and prepare AVURLAsset off-main-thread so opening X video posts stays 120fps smooth.
            loadTask = Task { @MainActor [weak view] in
                try? await Task.sleep(for: .milliseconds(90))
                guard !Task.isCancelled, let view else { return }
                let asset = AVURLAsset(url: url)
                _ = try? await asset.load(.isPlayable)
                guard !Task.isCancelled else { return }
                let item = AVPlayerItem(asset: asset)
                view.player = AVPlayer(playerItem: item)
            }
        }

        func teardown(_ view: AVPlayerView) {
            loadTask?.cancel()
            loadTask = nil
            view.player?.pause()
            view.player = nil
        }
    }

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func makeNSView(context: Context) -> AVPlayerView {
        let view = AVPlayerView()
        view.controlsStyle = .floating
        context.coordinator.attach(url: url, to: view)
        return view
    }

    func updateNSView(_ nsView: AVPlayerView, context: Context) {
        if context.coordinator.currentURL != url {
            context.coordinator.attach(url: url, to: nsView)
        }
    }

    static func dismantleNSView(_ nsView: AVPlayerView, coordinator: Coordinator) {
        coordinator.teardown(nsView)
    }
}

// MARK: - 3. Markdown & Plain Text Reader Card

struct QuickLookMarkdownReaderCard: View {
    @Environment(\.colorScheme) private var colorScheme

    let asset: AssetRecord
    let originalURL: URL?

    @State private var fullText: String = ""
    @State private var showRawSource: Bool = false

    private var isMarkdown: Bool {
        asset.isMarkdownDocument
    }

    var body: some View {
        let cardShape = RoundedRectangle(cornerRadius: 18, style: .continuous)

        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 10) {
                Text(CanvasFormatters.fileExtensionBadge(for: asset.fileName))
                    .font(.system(size: 11, weight: .bold, design: .monospaced))
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(Color.primary.opacity(0.08), in: RoundedRectangle(cornerRadius: 6, style: .continuous))

                Text(asset.title)
                    .font(.system(size: 16, weight: .semibold))
                    .lineLimit(1)

                Spacer()

                if isMarkdown {
                    Button(showRawSource ? "渲染视图" : "查看原文") {
                        showRawSource.toggle()
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                }

                Button {
                    let pb = NSPasteboard.general
                    pb.clearContents()
                    pb.setString(fullText, forType: .string)
                } label: {
                    Label("复制全文", systemImage: "doc.on.doc")
                        .font(.system(size: 11.5, weight: .medium))
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            }
            .padding(.horizontal, 24)
            .padding(.vertical, 16)

            Divider()

            ScrollView(.vertical) {
                Group {
                    if isMarkdown && !showRawSource {
                        QuickLookMarkdownContentView(markdown: fullText)
                            .padding(24)
                    } else {
                        Text(fullText.isEmpty ? "暂无可预览正文" : fullText)
                            .font(showRawSource ? .system(size: 12.5, design: .monospaced) : .system(size: 14))
                            .lineSpacing(6)
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(24)
                    }
                }
                .charkleCleanScrollbars(hidden: false)
            }
        }
        .frame(maxWidth: 740, maxHeight: 620)
        .clipShape(cardShape)
        .background {
            cardShape
                .fill(CharkleTheme.surfaceElevated(for: colorScheme))
                .shadow(color: .black.opacity(0.36), radius: 24, y: 10)
        }
        .task(id: originalURL) {
            if let url = originalURL,
               let data = try? Data(contentsOf: url),
               let decoded = String(data: data.prefix(262_144), encoding: .utf8),
               !decoded.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                fullText = decoded
            } else {
                fullText = asset.notes.isEmpty ? (asset.ocrText ?? asset.richMetadata?.textExcerpt ?? "") : asset.notes
            }
        }
    }
}

// MARK: - Cached Remote Image Loader (Supports SVG, WebP, PNG, JPEG, GIF)

private final class RemoteImageMemoryCache: @unchecked Sendable {
    static let shared = RemoteImageMemoryCache()
    private let cache = NSCache<NSString, NSImage>()

    private init() {
        cache.countLimit = 120
        cache.totalCostLimit = 96 * 1024 * 1024
    }

    func image(for url: URL) -> NSImage? {
        cache.object(forKey: url.absoluteString as NSString)
    }

    func store(_ image: NSImage, for url: URL) {
        let w = max(1, Int(image.size.width))
        let h = max(1, Int(image.size.height))
        cache.setObject(image, forKey: url.absoluteString as NSString, cost: w * h * 4)
    }
}

private struct RemoteCachedImageView<Placeholder: View, Failure: View>: View {
    let url: URL
    let contentMode: ContentMode
    let fixedWidth: CGFloat?
    let fixedHeight: CGFloat?
    let maxHeight: CGFloat?
    let placeholder: () -> Placeholder
    let failurePlaceholder: () -> Failure

    @State private var loadedImage: NSImage?
    @State private var didFail: Bool = false

    init(
        url: URL,
        contentMode: ContentMode = .fit,
        fixedWidth: CGFloat? = nil,
        fixedHeight: CGFloat? = nil,
        maxHeight: CGFloat? = nil,
        @ViewBuilder placeholder: @escaping () -> Placeholder,
        @ViewBuilder failurePlaceholder: @escaping () -> Failure
    ) {
        self.url = url
        self.contentMode = contentMode
        self.fixedWidth = fixedWidth
        self.fixedHeight = fixedHeight
        self.maxHeight = maxHeight
        self.placeholder = placeholder
        self.failurePlaceholder = failurePlaceholder
        _loadedImage = State(initialValue: RemoteImageMemoryCache.shared.image(for: url))
    }

    init(
        url: URL,
        contentMode: ContentMode = .fit,
        fixedWidth: CGFloat? = nil,
        fixedHeight: CGFloat? = nil,
        maxHeight: CGFloat? = nil,
        @ViewBuilder placeholder: @escaping () -> Placeholder
    ) where Failure == Placeholder {
        self.init(
            url: url,
            contentMode: contentMode,
            fixedWidth: fixedWidth,
            fixedHeight: fixedHeight,
            maxHeight: maxHeight,
            placeholder: placeholder,
            failurePlaceholder: placeholder
        )
    }

    var body: some View {
        Group {
            if let img = loadedImage {
                let base = Image(nsImage: img)
                    .renderingMode(.original)
                    .resizable()
                    .interpolation(.high)
                    .aspectRatio(contentMode: contentMode)
                if let fixedWidth, let fixedHeight {
                    base.frame(width: fixedWidth, height: fixedHeight)
                } else if let fixedWidth {
                    base.frame(width: fixedWidth)
                } else if let fixedHeight {
                    base.frame(height: fixedHeight)
                } else if let maxHeight {
                    base.frame(maxHeight: maxHeight)
                } else {
                    base
                }
            } else if didFail {
                failurePlaceholder()
            } else {
                placeholder()
            }
        }
        .task(id: url) {
            if let cached = RemoteImageMemoryCache.shared.image(for: url) {
                loadedImage = cached
                didFail = false
                return
            }
            didFail = false
            let targetURL = url
            let fetched: NSImage? = await Task.detached(priority: .utility) {
                var request = URLRequest(url: targetURL, timeoutInterval: 10)
                request.setValue("Charkle/1.0 (+https://charkle.app)", forHTTPHeaderField: "User-Agent")
                request.setValue("image/svg+xml,image/webp,image/png,image/jpeg,image/gif,image/*", forHTTPHeaderField: "Accept")
                guard let (data, response) = try? await URLSession.shared.data(for: request),
                      let http = response as? HTTPURLResponse,
                      (200..<300).contains(http.statusCode),
                      !data.isEmpty else {
                    return nil
                }
                // `NSImage(data:)` natively renders SVG, WebP, PNG, JPEG, and GIF on macOS 15+.
                guard let image = NSImage(data: data), image.size.width > 0, image.size.height > 0 else {
                    return nil
                }
                image.isTemplate = false
                return image
            }.value

            guard !Task.isCancelled else { return }
            if let fetched {
                RemoteImageMemoryCache.shared.store(fetched, for: url)
                loadedImage = fetched
            } else {
                didFail = true
            }
        }
    }
}

// MARK: - Parsed Markdown Block Cache (Zero Main-Thread Re-Parsing)

private final class ParsedMarkdownCache: @unchecked Sendable {
    static let shared = ParsedMarkdownCache()

    private final class Box: @unchecked Sendable {
        let blocks: [MarkdownBlock]
        init(_ blocks: [MarkdownBlock]) { self.blocks = blocks }
    }

    private let cache = NSCache<NSString, Box>()

    private init() {
        cache.countLimit = 48
    }

    func key(markdown: String, urlContext: MarkdownURLContext) -> NSString {
        var hasher = Hasher()
        hasher.combine(markdown)
        hasher.combine(urlContext)
        return "\(markdown.count)-\(hasher.finalize())" as NSString
    }

    func blocks(for key: NSString) -> [MarkdownBlock]? {
        cache.object(forKey: key)?.blocks
    }

    func store(_ blocks: [MarkdownBlock], for key: NSString) {
        cache.setObject(Box(blocks), forKey: key)
    }
}

/// High-performance GitHub-Flavored Markdown & README HTML renderer.
/// Parses off-main-thread once with `NSCache` memoization and virtualizes blocks via `LazyVStack`,
/// supporting centered HTML hero headers, SVG/WebP/PNG/GIF images, GFM tables, alerts, `<details>`,
/// ordered/task lists, inline links, and code blocks.
struct QuickLookMarkdownContentView: View {
    @Environment(\.colorScheme) private var colorScheme
    let markdown: String
    let urlContext: MarkdownURLContext

    @State private var blocks: [MarkdownBlock]

    init(markdown: String, urlContext: MarkdownURLContext = MarkdownURLContext()) {
        self.markdown = markdown
        self.urlContext = urlContext
        let key = ParsedMarkdownCache.shared.key(markdown: markdown, urlContext: urlContext)
        if let cached = ParsedMarkdownCache.shared.blocks(for: key) {
            _blocks = State(initialValue: cached)
        } else if markdown.count <= 3_500 {
            let parsed = MarkdownDocumentParser.parse(markdown, urlContext: urlContext)
            ParsedMarkdownCache.shared.store(parsed, for: key)
            _blocks = State(initialValue: parsed)
        } else {
            _blocks = State(initialValue: [])
        }
    }

    private var cacheKey: NSString {
        ParsedMarkdownCache.shared.key(markdown: markdown, urlContext: urlContext)
    }

    var body: some View {
        LazyVStack(alignment: .leading, spacing: 11) {
            ForEach(blocks) { block in
                MarkdownBlockRowView(block: block, colorScheme: colorScheme)
            }
        }
        .textSelection(.enabled)
        .frame(maxWidth: .infinity, alignment: .leading)
        .task(id: cacheKey) {
            let key = cacheKey
            if let cached = ParsedMarkdownCache.shared.blocks(for: key) {
                if blocks != cached { blocks = cached }
                return
            }
            let src = markdown
            let ctx = urlContext
            let parsed = await Task.detached(priority: .userInitiated) {
                MarkdownDocumentParser.parse(src, urlContext: ctx)
            }.value
            guard !Task.isCancelled else { return }
            ParsedMarkdownCache.shared.store(parsed, for: key)
            blocks = parsed
        }
    }
}

private struct MarkdownBlockRowView: View {
    let block: MarkdownBlock
    let colorScheme: ColorScheme

    var body: some View {
        switch block {
        case .heading(_, let level, let text, let alignment):
            VStack(alignment: horizontalAlignment(for: alignment), spacing: 6) {
                inlineMarkdownText(text)
                    .font(.system(
                        size: level == 1 ? 22 : (level == 2 ? 17.5 : (level == 3 ? 15 : 13.5)),
                        weight: .bold
                    ))
                    .multilineTextAlignment(textAlignment(for: alignment))
                    .frame(maxWidth: .infinity, alignment: frameAlignment(for: alignment))

                if level <= 2 && alignment == .leading {
                    Rectangle()
                        .fill(Color.primary.opacity(colorScheme == .dark ? 0.09 : 0.08))
                        .frame(height: 0.75)
                }
            }
            .padding(.top, level <= 2 ? 8 : 4)

        case .paragraph(_, let text, let alignment):
            inlineMarkdownText(text)
                .font(.system(size: 13.5))
                .lineSpacing(5)
                .multilineTextAlignment(textAlignment(for: alignment))
                .frame(maxWidth: .infinity, alignment: frameAlignment(for: alignment))

        case .image(_, let item, let alignment):
            markdownImageElement(item, isInlineBadge: false)
                .frame(maxWidth: .infinity, alignment: frameAlignment(for: alignment))
                .padding(.vertical, 2)

        case .imageRow(_, let items, let alignment):
            QuickLookFlowWrap(spacing: 6) {
                ForEach(items) { item in
                    markdownImageElement(item, isInlineBadge: true)
                }
            }
            .frame(maxWidth: .infinity, alignment: frameAlignment(for: alignment))
            .padding(.vertical, 2)

        case .code(_, let lang, let content):
            MarkdownCodeBlockView(language: lang, content: content, colorScheme: colorScheme)

        case .quote(_, let alertKind, let text):
            let accent = alertAccentColor(for: alertKind)
            HStack(alignment: .top, spacing: 10) {
                RoundedRectangle(cornerRadius: 2)
                    .fill(accent)
                    .frame(width: 3)
                VStack(alignment: .leading, spacing: 4) {
                    if let alertKind {
                        Text(alertKind.label.uppercased())
                            .font(.system(size: 10.5, weight: .bold, design: .monospaced))
                            .foregroundStyle(accent)
                    }
                    if !text.isEmpty {
                        inlineMarkdownText(text)
                            .font(.system(size: 13))
                            .foregroundStyle(alertKind == nil ? Color.secondary : Color.primary.opacity(0.88))
                            .lineSpacing(4)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(.horizontal, alertKind == nil ? 0 : 10)
            .padding(.vertical, alertKind == nil ? 2 : 8)
            .background(
                alertKind == nil ? Color.clear : accent.opacity(colorScheme == .dark ? 0.12 : 0.08),
                in: RoundedRectangle(cornerRadius: 9, style: .continuous)
            )

        case .listItem(_, let marker, let indent, let text):
            HStack(alignment: .top, spacing: 8) {
                switch marker {
                case .bullet:
                    Text("•")
                        .font(.system(size: 14, weight: .bold))
                        .foregroundStyle(.secondary)
                        .frame(width: 14, alignment: .center)
                case .ordered(let num):
                    Text("\(num).")
                        .font(.system(size: 12.5, weight: .semibold, design: .monospaced))
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                        .frame(minWidth: 20, alignment: .trailing)
                case .task(let checked):
                    Image(systemName: checked ? "checkmark.square.fill" : "square")
                        .font(.system(size: 12.5, weight: .medium))
                        .foregroundStyle(checked ? Color.accentColor : .secondary)
                        .padding(.top, 2)
                }
                inlineMarkdownText(text)
                    .font(.system(size: 13.5))
                    .lineSpacing(4)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(.leading, CGFloat(indent) * 16)

        case .table(_, let headers, let alignments, let rows):
            MarkdownTableView(
                headers: headers,
                alignments: alignments,
                rows: rows,
                colorScheme: colorScheme
            )

        case .details(_, let summary, let children):
            MarkdownDetailsDisclosureView(summary: summary, children: children, colorScheme: colorScheme)

        case .divider:
            Divider().padding(.vertical, 4)
        }
    }

    @ViewBuilder
    private func markdownImageElement(_ item: MarkdownImageItem, isInlineBadge: Bool) -> some View {
        if let url = URL(string: item.url) {
            let fixedW = item.width.map { CGFloat(min($0, 680)) }
            let fixedH = item.height.map { CGFloat(min($0, 480)) }
            let maxH: CGFloat? = isInlineBadge ? 28 : (fixedH == nil ? 420 : nil)

            let imageBody = RemoteCachedImageView(
                url: url,
                contentMode: .fit,
                fixedWidth: fixedW,
                fixedHeight: fixedH,
                maxHeight: maxH
            ) {
                if fixedW != nil || fixedH != nil {
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(Color.primary.opacity(0.05))
                        .frame(width: fixedW ?? 72, height: fixedH ?? 72)
                } else if !isInlineBadge {
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .fill(Color.primary.opacity(0.04))
                        .frame(maxWidth: .infinity)
                        .frame(height: 120)
                }
            } failurePlaceholder: {
                if !item.alt.isEmpty {
                    Text(item.alt)
                        .font(.system(size: 11.5))
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 6, style: .continuous))
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: isInlineBadge ? 4 : 10, style: .continuous))

            if let linkStr = item.linkURL, let linkURL = URL(string: linkStr) {
                Button {
                    NSWorkspace.shared.open(linkURL)
                } label: {
                    imageBody
                }
                .buttonStyle(.plain)
            } else {
                imageBody
            }
        }
    }

    private func inlineMarkdownText(_ raw: String) -> Text {
        if let attributed = try? AttributedString(
            markdown: raw,
            options: AttributedString.MarkdownParsingOptions(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        ) {
            return Text(attributed)
        }
        return Text(raw)
    }

    private func horizontalAlignment(for alignment: MarkdownAlignment) -> HorizontalAlignment {
        switch alignment {
        case .leading: .leading
        case .center: .center
        case .trailing: .trailing
        }
    }

    private func frameAlignment(for alignment: MarkdownAlignment) -> Alignment {
        switch alignment {
        case .leading: .leading
        case .center: .center
        case .trailing: .trailing
        }
    }

    private func textAlignment(for alignment: MarkdownAlignment) -> TextAlignment {
        switch alignment {
        case .leading: .leading
        case .center: .center
        case .trailing: .trailing
        }
    }

    private func alertAccentColor(for kind: MarkdownAlertKind?) -> Color {
        switch kind {
        case .none: Color.accentColor.opacity(0.55)
        case .note: Color(charkleHex: "#3B82F6")
        case .tip: Color(charkleHex: "#16A34A")
        case .important: Color(charkleHex: "#2A60E0")
        case .warning: Color(charkleHex: "#D97706")
        case .caution: Color(charkleHex: "#DC2626")
        }
    }
}

private struct MarkdownCodeBlockView: View {
    let language: String
    let content: String
    let colorScheme: ColorScheme
    @State private var copied: Bool = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Text(language.isEmpty ? "CODE" : language.uppercased())
                    .font(.system(size: 9.5, weight: .semibold, design: .monospaced))
                    .foregroundStyle(.tertiary)
                Spacer()
                Button {
                    let pb = NSPasteboard.general
                    pb.clearContents()
                    pb.setString(content, forType: .string)
                    copied = true
                    Task {
                        try? await Task.sleep(for: .seconds(1.2))
                        copied = false
                    }
                } label: {
                    HStack(spacing: 3) {
                        Image(systemName: copied ? "checkmark" : "doc.on.doc")
                            .font(.system(size: 9.5, weight: .semibold))
                        Text(copied ? "已复制" : "复制")
                            .font(.system(size: 10, weight: .medium))
                    }
                    .foregroundStyle(copied ? Color.accentColor : .secondary)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2.5)
                    .background(Color.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 5, style: .continuous))
                }
                .buttonStyle(.plain)
            }

            ScrollView(.horizontal, showsIndicators: false) {
                Text(content)
                    .font(.system(size: 12, design: .monospaced))
                    .lineSpacing(3.5)
                    .textSelection(.enabled)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.primary.opacity(colorScheme == .dark ? 0.08 : 0.045), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(Color.primary.opacity(colorScheme == .dark ? 0.08 : 0.06), lineWidth: 0.5)
        )
    }
}

private struct MarkdownTableView: View {
    let headers: [String]
    let alignments: [MarkdownAlignment]
    let rows: [[String]]
    let colorScheme: ColorScheme

    var body: some View {
        let colCount = max(1, headers.count)
        let borderColor = Color.primary.opacity(colorScheme == .dark ? 0.11 : 0.09)
        let headerBg = Color.primary.opacity(colorScheme == .dark ? 0.075 : 0.045)
        let stripeBg = Color.primary.opacity(colorScheme == .dark ? 0.035 : 0.02)
        let tableContent = Grid(alignment: .topLeading, horizontalSpacing: 0, verticalSpacing: 0) {
            GridRow {
                ForEach(0..<colCount, id: \.self) { col in
                    let align = col < alignments.count ? alignments[col] : .leading
                    inlineCellText(col < headers.count ? headers[col] : "", isHeader: true)
                        .multilineTextAlignment(textAlignment(align))
                        .frame(maxWidth: .infinity, alignment: frameAlignment(align))
                        .padding(.horizontal, 11)
                        .padding(.vertical, 8)
                }
            }
            .background(headerBg)

            ForEach(Array(rows.enumerated()), id: \.offset) { rowIdx, row in
                Divider().overlay(borderColor)
                GridRow {
                    ForEach(0..<colCount, id: \.self) { col in
                        let align = col < alignments.count ? alignments[col] : .leading
                        let rawCell = col < row.count ? row[col] : ""
                        inlineCellText(rawCell, isHeader: false)
                            .multilineTextAlignment(textAlignment(align))
                            .frame(maxWidth: .infinity, alignment: frameAlignment(align))
                            .padding(.horizontal, 11)
                            .padding(.vertical, 8)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .background(rowIdx.isMultiple(of: 2) ? Color.clear : stripeBg)
            }
        }
        .background(Color.primary.opacity(colorScheme == .dark ? 0.03 : 0.015))
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(borderColor, lineWidth: 0.75)
        )

        if colCount > 4 {
            ScrollView(.horizontal, showsIndicators: false) {
                tableContent.frame(minWidth: CGFloat(colCount) * 140)
            }
        } else {
            tableContent
        }
    }

    private func inlineCellText(_ raw: String, isHeader: Bool) -> Text {
        let baseFont: Font = isHeader ? .system(size: 12, weight: .semibold) : .system(size: 12.5)
        if let attributed = try? AttributedString(
            markdown: raw,
            options: AttributedString.MarkdownParsingOptions(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        ) {
            return Text(attributed).font(baseFont)
        }
        return Text(raw).font(baseFont)
    }

    private func frameAlignment(_ align: MarkdownAlignment) -> Alignment {
        switch align {
        case .leading: .topLeading
        case .center: .top
        case .trailing: .topTrailing
        }
    }

    private func textAlignment(_ align: MarkdownAlignment) -> TextAlignment {
        switch align {
        case .leading: .leading
        case .center: .center
        case .trailing: .trailing
        }
    }
}

private struct MarkdownDetailsDisclosureView: View {
    let summary: String
    let children: [MarkdownBlock]
    let colorScheme: ColorScheme
    @State private var isExpanded: Bool = false

    var body: some View {
        CharkleDisclosureGroup(
            isExpanded: $isExpanded,
            headerVerticalPadding: 4,
            headerHorizontalPadding: 6,
            negativeHorizontalBleed: 6
        ) {
            VStack(alignment: .leading, spacing: 10) {
                ForEach(children) { child in
                    MarkdownBlockRowView(block: child, colorScheme: colorScheme)
                }
            }
            .padding(.top, 8)
            .frame(maxWidth: .infinity, alignment: .leading)
        } label: {
            Text(summary)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.primary)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
        .background(Color.primary.opacity(colorScheme == .dark ? 0.06 : 0.035), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(Color.primary.opacity(colorScheme == .dark ? 0.09 : 0.07), lineWidth: 0.5)
        )
    }
}

// MARK: - 4. Interactive 3D Model Viewer (SceneKit + ModelIO)

struct QuickLookModel3DViewer: View {
    let asset: AssetRecord
    let originalURL: URL?
    @State private var loadFailed: Bool = false
    @State private var resetTrigger: Int = 0

    var body: some View {
        ZStack(alignment: .topTrailing) {
            if let url = originalURL, !loadFailed {
                SceneKitInteractiveView(url: url, resetTrigger: resetTrigger) {
                    loadFailed = true
                }
                .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
                .shadow(color: .black.opacity(0.45), radius: 28, y: 12)

                HStack(spacing: 8) {
                    Text("3D · \(asset.richMetadata?.model3DFormat ?? url.pathExtension.uppercased())")
                        .font(.system(size: 11, weight: .bold, design: .monospaced))
                        .foregroundStyle(.white.opacity(0.9))
                        .padding(.horizontal, 10)
                        .padding(.vertical, 5)
                        .background(Color.black.opacity(0.55), in: Capsule(style: .continuous))

                    Button {
                        resetTrigger += 1
                    } label: {
                        Label("重置视角", systemImage: "arrow.counterclockwise")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(.white)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 5)
                            .background(Color.black.opacity(0.55), in: Capsule(style: .continuous))
                    }
                    .buttonStyle(.plain)
                }
                .padding(14)
            } else {
                VStack(spacing: 14) {
                    CharkleIcon("model3d", style: .duotone, size: 52)
                    Text(asset.title)
                        .font(.system(size: 17, weight: .semibold))
                        .foregroundStyle(.white)
                    Text("该 3D 格式（\(asset.richMetadata?.model3DFormat ?? "3D")）暂不支持 SceneKit 直接渲染，可使用默认 3D 软件打开。")
                        .font(.system(size: 12.5))
                        .foregroundStyle(.white.opacity(0.7))
                        .multilineTextAlignment(.center)
                        .frame(maxWidth: 360)
                    if let url = originalURL {
                        Button("使用默认软件打开") {
                            NSWorkspace.shared.open(url)
                        }
                        .buttonStyle(.borderedProminent)
                    }
                }
                .padding(32)
                .frame(maxWidth: 520, maxHeight: 380)
                .background(Color(charkleHex: "#181A20"), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
            }
        }
        .frame(maxWidth: 960, maxHeight: 640)
    }
}

private struct SceneKitInteractiveView: NSViewRepresentable {
    let url: URL
    let resetTrigger: Int
    let onFailed: () -> Void

    final class Coordinator {
        var lastURL: URL?
        var lastReset: Int = 0
        var defaultCameraPosition: SCNVector3 = SCNVector3(0, 1, 3)
        var defaultTarget: SCNVector3 = SCNVector3(0, 0, 0)
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> SCNView {
        let view = SCNView()
        view.allowsCameraControl = true
        view.autoenablesDefaultLighting = true
        view.antialiasingMode = .multisampling4X
        view.backgroundColor = NSColor(calibratedRed: 0.10, green: 0.11, blue: 0.14, alpha: 1.0)
        loadScene(into: view, coordinator: context.coordinator)
        return view
    }

    func updateNSView(_ nsView: SCNView, context: Context) {
        if context.coordinator.lastURL != url {
            loadScene(into: nsView, coordinator: context.coordinator)
        } else if context.coordinator.lastReset != resetTrigger {
            context.coordinator.lastReset = resetTrigger
            if let cam = nsView.pointOfView {
                SCNTransaction.begin()
                SCNTransaction.animationDuration = 0.28
                cam.position = context.coordinator.defaultCameraPosition
                cam.look(at: context.coordinator.defaultTarget)
                SCNTransaction.commit()
            }
        }
    }

    private func loadScene(into view: SCNView, coordinator: Coordinator) {
        coordinator.lastURL = url
        coordinator.lastReset = resetTrigger
        let scene: SCNScene?
        if let direct = try? SCNScene(url: url, options: nil) {
            scene = direct
        } else {
            let mdl = MDLAsset(url: url)
            scene = mdl.count > 0 ? SCNScene(mdlAsset: mdl) : nil
        }

        guard let scene else {
            DispatchQueue.main.async { onFailed() }
            return
        }

        let (center, radius) = scene.rootNode.boundingSphere
        let camNode = SCNNode()
        camNode.camera = SCNCamera()
        camNode.camera?.automaticallyAdjustsZRange = true
        let dist = max(CGFloat(radius) * 2.5, 2.2)
        let pos = SCNVector3(
            CGFloat(center.x) + dist * 0.55,
            CGFloat(center.y) + dist * 0.42,
            CGFloat(center.z) + dist * 0.85
        )
        camNode.position = pos
        camNode.look(at: center)
        scene.rootNode.addChildNode(camNode)

        coordinator.defaultCameraPosition = pos
        coordinator.defaultTarget = center
        view.scene = scene
        view.pointOfView = camNode
    }
}

// MARK: - Wrap Layout Helper

struct QuickLookFlowWrap: Layout {
    var spacing: CGFloat = 6

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let maxW = proposal.width ?? 640
        var x: CGFloat = 0
        var y: CGFloat = 0
        var rowH: CGFloat = 0
        for v in subviews {
            let s = v.sizeThatFits(.unspecified)
            if x + s.width > maxW, x > 0 {
                x = 0
                y += rowH + spacing
                rowH = 0
            }
            rowH = max(rowH, s.height)
            x += s.width + spacing
        }
        return CGSize(width: maxW, height: y + rowH)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX
        var y = bounds.minY
        var rowH: CGFloat = 0
        for v in subviews {
            let s = v.sizeThatFits(.unspecified)
            if x + s.width > bounds.maxX, x > bounds.minX {
                x = bounds.minX
                y += rowH + spacing
                rowH = 0
            }
            v.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(s))
            rowH = max(rowH, s.height)
            x += s.width + spacing
        }
    }
}
