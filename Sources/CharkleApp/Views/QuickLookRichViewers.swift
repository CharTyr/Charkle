import AppKit
import AVKit
import CharkleCanvas
import CharkleCore
import ModelIO
import SceneKit
import SceneKit.ModelIO
import SwiftUI
import Textual
import WebKit

// MARK: - 1. GitHub Repository + README Reader Card

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
        case "css": Color(charkleHex: "#264DE4")
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
    var onSetCoverFrame: (@MainActor (_ jpegData: Data, _ timestampSeconds: Double?) async -> Void)? = nil
    var isPlaybackSuspended: Bool = false

    @State private var extractingIndex: Int?
    @State private var isExtractingAll: Bool = false
    @State private var isRetrying: Bool = false
    @State private var inlineVideoCaptureBridge = StreamingFrameCaptureBridge()
    @State private var isCapturingInlineCover: Bool = false

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
                            if let handleLine = post.displayHandleLine {
                                Text(handleLine)
                                    .font(.system(size: 12.5))
                                    .foregroundStyle(.secondary)
                            }
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

                // Article / Video Headline
                if let article = post.articleTitle, !article.isEmpty {
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text(article)
                            .font(.system(size: 17, weight: .bold))
                            .textSelection(.enabled)
                        if let dur = post.formattedVideoDuration {
                            Text(dur)
                                .font(.system(size: 11.5, weight: .semibold).monospacedDigit())
                                .foregroundStyle(.secondary)
                                .padding(.horizontal, 7)
                                .padding(.vertical, 2)
                                .background(Color.primary.opacity(0.07), in: Capsule())
                        }
                    }
                }

                // Dedicated Video Summary & Timestamp Outline (Bilibili AI Summary / YouTube Chapters & Caption Digest)
                if post.hasVideoSummaryContent {
                    VStack(alignment: .leading, spacing: 8) {
                        HStack(spacing: 6) {
                            Image(systemName: "text.quote")
                                .font(.system(size: 12, weight: .semibold))
                                .foregroundStyle(Color.accentColor)
                            Text("视频摘要")
                                .font(.system(size: 12.5, weight: .semibold))
                                .foregroundStyle(.primary)
                        }
                        if let summary = post.videoSummary?.trimmingCharacters(in: .whitespacesAndNewlines), !summary.isEmpty {
                            Text(summary)
                                .font(.system(size: 13.5))
                                .foregroundStyle(.primary.opacity(0.90))
                                .textSelection(.enabled)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        if !post.videoOutline.isEmpty {
                            VStack(alignment: .leading, spacing: 4) {
                                ForEach(Array(post.videoOutline.enumerated()), id: \.offset) { _, line in
                                    Text(line)
                                        .font(.system(size: 12.5))
                                        .foregroundStyle(.secondary)
                                        .textSelection(.enabled)
                                        .fixedSize(horizontal: false, vertical: true)
                                }
                            }
                            .padding(.top, 2)
                        }
                    }
                    .padding(12)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color.accentColor.opacity(0.07), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                    .overlay(
                        RoundedRectangle(cornerRadius: 12, style: .continuous)
                            .strokeBorder(Color.accentColor.opacity(0.18), lineWidth: 0.75)
                    )
                }

                // Post Body Text (native Textual rich formatting & selection)
                if !post.bodyText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    QuickLookSocialRichTextView(
                        text: post.bodyText,
                        isArticle: post.articleTitle != nil,
                        fontSize: 15
                    )
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
                        QuickLookSocialRichTextView(
                            text: quotedText,
                            isArticle: false,
                            fontSize: 13.5
                        )
                        .foregroundStyle(.primary.opacity(0.86))
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
                            Text("\(post.platform.postNoun)内含 \(attachments.count) 个媒体")
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
                    VStack(alignment: .trailing, spacing: 6) {
                        SocialPostInlineVideoPlayer(
                            url: videoFile,
                            isPlaybackSuspended: isPlaybackSuspended,
                            captureBridge: inlineVideoCaptureBridge
                        )
                        .frame(height: 360)
                        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))

                        if let onSetCoverFrame {
                            HStack {
                                Spacer()
                                captureInlineCoverButton(onSetCoverFrame: onSetCoverFrame)
                            }
                        }
                    }
                }

                // Media Fetch Failed Banner + Retry CTA
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
        .frame(maxWidth: post.platform.isVideoPlatform ? 760 : 680, maxHeight: 720)
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
            if post.platform.isVideoPlatform && !isLocalVideoFile {
                // YouTube / Bilibili bookmark: zero-download inline streaming playback directly inside Quick Look
                // (Tier 1 native AVPlayer HTTP Range/HLS stream with required Referer/UA -> Tier 2 official WKWebView embed).
                // Video file is saved to disk ONLY when the user explicitly clicks "保存视频为独立素材".
                let thumbURL = (attachment.thumbnailURL ?? post.mediaThumbnailURLs.first).flatMap(URL.init(string:))
                QuickLookStreamingVideoView(
                    playbackKey: "\(asset.id.uuidString):\(post.originalURL)",
                    coverURL: thumbURL,
                    durationText: post.formattedVideoDuration,
                    watchURL: URL(string: post.originalURL),
                    openActionLabel: post.platform.openActionLabel,
                    isPlaybackSuspended: isPlaybackSuspended,
                    onSetCoverFrame: onSetCoverFrame,
                    resolvePlan: {
                        await VideoPlatformResolver.resolvePlaybackPlan(for: post)
                    }
                )
                .aspectRatio(16.0 / 9.0, contentMode: .fit)
                .frame(maxWidth: .infinity)
                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .strokeBorder(Color.primary.opacity(0.10), lineWidth: 0.6)
                )

                HStack {
                    Label("在线流式播放（不占用本地空间，可按需保存原视频）", systemImage: "play.tv")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(.secondary)
                    Spacer()
                    extractMediaButton(attachment: attachment, index: index, pillStyle: false)
                }
            } else if isVideoLike {
                let playbackURL: URL? = (index == 0 && isLocalVideoFile) ? originalURL : URL(string: attachment.url)
                if let playURL = playbackURL {
                    SocialPostInlineVideoPlayer(
                        url: playURL,
                        isPlaybackSuspended: isPlaybackSuspended,
                        captureBridge: index == 0 ? inlineVideoCaptureBridge : nil
                    )
                        .frame(height: 320)
                        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                        .overlay(
                            RoundedRectangle(cornerRadius: 12, style: .continuous)
                                .strokeBorder(Color.primary.opacity(0.10), lineWidth: 0.6)
                        )
                } else {
                    mediaFailedPlaceholder
                }

                HStack(spacing: 8) {
                    Label(attachment.kind == .gif ? "动图媒体" : "视频媒体", systemImage: "film")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(.secondary)
                    Spacer()
                    if index == 0, let onSetCoverFrame {
                        captureInlineCoverButton(onSetCoverFrame: onSetCoverFrame)
                    }
                    extractMediaButton(attachment: attachment, index: index, pillStyle: false)
                }
            } else {
                let previewStr = attachment.kind == .photo ? attachment.url : (attachment.thumbnailURL ?? attachment.url)
                let isXiaohongshuMultiGrid = post.platform == .xiaohongshu && attachments.count > 1
                ZStack(alignment: .bottomTrailing) {
                    if let imgURL = URL(string: previewStr) {
                        if isXiaohongshuMultiGrid {
                            Color.primary.opacity(0.05)
                                .aspectRatio(3.0 / 4.0, contentMode: .fit)
                                .overlay {
                                    RemoteCachedImageView(
                                        url: imgURL,
                                        contentMode: .fill
                                    ) {
                                        CharkleMediaPlaceholderSkeleton(height: 220, cornerRadius: 12)
                                    } failurePlaceholder: {
                                        mediaFailedPlaceholder
                                    }
                                }
                                .clipped()
                                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                        } else {
                            RemoteCachedImageView(
                                url: imgURL,
                                contentMode: .fit,
                                maxHeight: attachments.count == 1 ? (post.platform == .xiaohongshu ? 520 : 420) : 240
                            ) {
                                CharkleMediaPlaceholderSkeleton(height: 180, cornerRadius: 12)
                            } failurePlaceholder: {
                                mediaFailedPlaceholder
                            }
                            .frame(maxWidth: .infinity)
                            .background(Color.primary.opacity(0.05))
                            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                        }
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
        let title: String = {
            if post.platform.isVideoPlatform { return "保存视频为独立素材" }
            switch attachment.kind {
            case .photo: return "提取为单独图片"
            case .video: return "提取为单独视频"
            case .gif: return "提取为单独动图"
            }
        }()
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
        case .xiaohongshu: Color(charkleHex: "#FF2442")
        case .pixiv: Color(charkleHex: "#0096FA")
        case .instagram: Color(charkleHex: "#D93B58")
        case .youtube: Color(charkleHex: "#FF0000")
        case .bilibili: Color(charkleHex: "#FB7299")
        }
    }

    @ViewBuilder
    private func captureInlineCoverButton(
        onSetCoverFrame: @escaping @MainActor (Data, Double?) async -> Void
    ) -> some View {
        Button {
            guard !isCapturingInlineCover else { return }
            isCapturingInlineCover = true
            Task { @MainActor in
                defer { isCapturingInlineCover = false }
                if let captured = await inlineVideoCaptureBridge.captureCurrentFrame?() {
                    await onSetCoverFrame(captured.jpegData, captured.timestampSeconds)
                }
            }
        } label: {
            HStack(spacing: 4) {
                if isCapturingInlineCover {
                    ProgressView().controlSize(.mini)
                } else {
                    Image(systemName: "camera.viewfinder")
                        .font(.system(size: 10.5, weight: .semibold))
                }
                Text("设当前帧为封面")
                    .font(.system(size: 11, weight: .semibold))
            }
            .foregroundStyle(.primary)
            .padding(.horizontal, 9)
            .padding(.vertical, 4)
            .background(Color.primary.opacity(0.08), in: Capsule(style: .continuous))
        }
        .buttonStyle(.plain)
        .disabled(isCapturingInlineCover)
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

@MainActor
final class StreamingFrameCaptureBridge {
    var captureCurrentFrame: (@MainActor () async -> (jpegData: Data, timestampSeconds: Double?)?)?
}

private struct SocialPostInlineVideoPlayer: NSViewRepresentable {
    let url: URL
    var isPlaybackSuspended: Bool = false
    var captureBridge: StreamingFrameCaptureBridge? = nil

    @MainActor
    final class Coordinator {
        var currentURL: URL?
        var wasSuspended: Bool = false
        var loadTask: Task<Void, Never>?
        var videoOutput: AVPlayerItemVideoOutput?
        weak var captureBridge: StreamingFrameCaptureBridge?

        func attach(url: URL, to view: AVPlayerView, captureBridge: StreamingFrameCaptureBridge?) {
            teardown(view)
            currentURL = url
            self.captureBridge = captureBridge

            // Defer AVPlayer / VideoToolbox initialization slightly past the opening animation frame
            // and prepare AVURLAsset off-main-thread so opening X video posts stays 120fps smooth.
            loadTask = Task { @MainActor [weak view, weak self] in
                try? await Task.sleep(for: .milliseconds(90))
                guard !Task.isCancelled, let view, let self else { return }
                let asset = AVURLAsset(url: url)
                _ = try? await asset.load(.isPlayable)
                guard !Task.isCancelled else { return }
                let item = AVPlayerItem(asset: asset)
                let output = VideoFrameCapture.makeVideoOutput()
                item.add(output)
                self.videoOutput = output
                let player = AVPlayer(playerItem: item)
                view.player = player
                self.captureBridge?.captureCurrentFrame = { [weak player, weak output] in
                    guard let player,
                          let result = await VideoFrameCapture.captureCurrentFrameJPEG(from: player, videoOutput: output) else {
                        return nil
                    }
                    return (result.jpegData, result.timestampSeconds)
                }
            }
        }

        func teardown(_ view: AVPlayerView) {
            loadTask?.cancel()
            loadTask = nil
            captureBridge?.captureCurrentFrame = nil
            videoOutput = nil
            view.player?.pause()
            view.player?.replaceCurrentItem(with: nil)
            view.player = nil
        }
    }

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func makeNSView(context: Context) -> AVPlayerView {
        let view = AVPlayerView()
        view.controlsStyle = .floating
        context.coordinator.wasSuspended = isPlaybackSuspended
        context.coordinator.attach(url: url, to: view, captureBridge: captureBridge)
        return view
    }

    func updateNSView(_ nsView: AVPlayerView, context: Context) {
        if context.coordinator.currentURL != url {
            context.coordinator.wasSuspended = isPlaybackSuspended
            context.coordinator.attach(url: url, to: nsView, captureBridge: captureBridge)
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

// MARK: - 2.5 Zero-Download Streaming Video Player (macOS Quick Look: Native AVPlayer -> WKWebView Embed Fallback)

struct QuickLookStreamingVideoView: View {
    let playbackKey: String
    let coverURL: URL?
    var fallbackCoverImage: NSImage? = nil
    let durationText: String?
    let watchURL: URL?
    let openActionLabel: String
    var isPlaybackSuspended: Bool = false
    var onSetCoverFrame: (@MainActor (_ jpegData: Data, _ timestampSeconds: Double?) async -> Void)? = nil
    let resolvePlan: () async -> VideoStreamPlaybackPlan

    @State private var plan: VideoStreamPlaybackPlan?
    @State private var isResolving: Bool = true
    @State private var directStreamIndex: Int = 0
    @State private var useEmbedMode: Bool = false
    @State private var allDirectStreamsFailed: Bool = false
    @State private var captureBridge = StreamingFrameCaptureBridge()
    @State private var isCapturingCover: Bool = false

    private var activeDirectStream: VideoStreamPlaybackPlan.DirectStream? {
        guard !useEmbedMode,
              !allDirectStreamsFailed,
              let streams = plan?.directStreams,
              directStreamIndex >= 0,
              directStreamIndex < streams.count else {
            return nil
        }
        return streams[directStreamIndex]
    }

    private var canToggleModes: Bool {
        guard let plan else { return false }
        return !plan.directStreams.isEmpty && !allDirectStreamsFailed && plan.embedPlayer != nil
    }

    private var isPlayerMounted: Bool {
        activeDirectStream != nil
            || (plan?.embedPlayer != nil && (useEmbedMode || allDirectStreamsFailed || (plan?.directStreams.isEmpty == true)))
    }

    var body: some View {
        ZStack {
            Color.black

            if let stream = activeDirectStream {
                DirectStreamAVPlayerViewMac(
                    stream: stream,
                    isPlaybackSuspended: isPlaybackSuspended,
                    captureBridge: captureBridge,
                    onPlaybackFailed: handleDirectStreamFailure
                )
            } else if let embed = plan?.embedPlayer, (useEmbedMode || allDirectStreamsFailed || (plan?.directStreams.isEmpty == true)) {
                EmbedStreamWebPlayerViewMac(
                    embed: embed,
                    isPlaybackSuspended: isPlaybackSuspended,
                    captureBridge: captureBridge
                )
            } else {
                coverSurface
            }

            if isResolving {
                coverSurface
                    .overlay {
                        HStack(spacing: 8) {
                            ProgressView()
                                .controlSize(.small)
                                .tint(.white)
                            Text("正在连接流式播放…")
                                .font(.system(size: 12.5, weight: .semibold))
                                .foregroundStyle(.white)
                        }
                        .padding(.horizontal, 14)
                        .padding(.vertical, 8)
                        .background(.black.opacity(0.68), in: Capsule(style: .continuous))
                        .overlay(Capsule().strokeBorder(.white.opacity(0.22), lineWidth: 0.75))
                    }
            } else if plan?.hasPlayableSource == false {
                coverSurface
                    .overlay {
                        VStack(spacing: 10) {
                            Image(systemName: "play.slash")
                                .font(.system(size: 24, weight: .medium))
                                .foregroundStyle(.white.opacity(0.85))
                            Text("暂无法直接流式播放此视频")
                                .font(.system(size: 12.5, weight: .medium))
                                .foregroundStyle(.white.opacity(0.92))
                            if let watchURL {
                                Link(destination: watchURL) {
                                    Label(openActionLabel, systemImage: "arrow.up.right.square")
                                        .font(.system(size: 12, weight: .semibold))
                                        .foregroundStyle(.white)
                                        .padding(.horizontal, 12)
                                        .padding(.vertical, 6)
                                        .background(Color.accentColor, in: Capsule())
                                }
                                .buttonStyle(.plain)
                            }
                        }
                        .padding(18)
                        .background(.black.opacity(0.65), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                    }
            }

            if !isResolving && isPlayerMounted && (canToggleModes || onSetCoverFrame != nil) {
                VStack {
                    HStack(spacing: 6) {
                        Spacer()
                        if let onSetCoverFrame {
                            Button {
                                guard !isCapturingCover else { return }
                                isCapturingCover = true
                                Task { @MainActor in
                                    defer { isCapturingCover = false }
                                    if let captured = await captureBridge.captureCurrentFrame?() {
                                        await onSetCoverFrame(captured.jpegData, captured.timestampSeconds)
                                    }
                                }
                            } label: {
                                HStack(spacing: 5) {
                                    if isCapturingCover {
                                        ProgressView().controlSize(.mini).tint(.white)
                                    } else {
                                        Image(systemName: "camera.viewfinder")
                                            .font(.system(size: 11, weight: .semibold))
                                    }
                                    Text("设当前帧为封面")
                                        .font(.system(size: 11, weight: .semibold))
                                }
                                .foregroundStyle(.white)
                                .padding(.horizontal, 10)
                                .padding(.vertical, 5)
                                .background(.black.opacity(0.62), in: Capsule(style: .continuous))
                                .overlay(Capsule().strokeBorder(.white.opacity(0.22), lineWidth: 0.75))
                            }
                            .buttonStyle(.plain)
                            .disabled(isCapturingCover)
                            .help("截取当前播放画面作为此素材封面")
                        }
                        if canToggleModes {
                            Button {
                                useEmbedMode.toggle()
                            } label: {
                                Label(
                                    useEmbedMode ? "切换原生流式" : "切换网页播放器",
                                    systemImage: useEmbedMode ? "play.rectangle" : "globe"
                                )
                                .font(.system(size: 11, weight: .semibold))
                                .foregroundStyle(.white)
                                .padding(.horizontal, 10)
                                .padding(.vertical, 5)
                                .background(.black.opacity(0.62), in: Capsule(style: .continuous))
                                .overlay(Capsule().strokeBorder(.white.opacity(0.22), lineWidth: 0.75))
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(10)
                    Spacer()
                }
            }
        }
        .task(id: playbackKey) {
            plan = nil
            isResolving = true
            directStreamIndex = 0
            useEmbedMode = false
            allDirectStreamsFailed = false

            // Brief debounce so fast arrow-key scrubbing across gallery items avoids wasted stream lookups.
            try? await Task.sleep(for: .milliseconds(120))
            guard !Task.isCancelled else { return }

            let resolved = await resolvePlan()
            guard !Task.isCancelled else { return }

            plan = resolved
            if resolved.directStreams.isEmpty && resolved.embedPlayer != nil {
                useEmbedMode = true
            }
            isResolving = false
        }
    }

    @ViewBuilder
    private var coverSurface: some View {
        ZStack {
            if let coverURL {
                RemoteCachedImageView(url: coverURL, contentMode: .fill) {
                    fallbackCoverView
                } failurePlaceholder: {
                    fallbackCoverView
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .clipped()
            } else {
                fallbackCoverView
            }

            if let durationText {
                VStack {
                    Spacer()
                    HStack {
                        Spacer()
                        Text(durationText)
                            .font(.system(size: 11.5, weight: .semibold).monospacedDigit())
                            .foregroundStyle(.white)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 3.5)
                            .background(.black.opacity(0.75), in: RoundedRectangle(cornerRadius: 6, style: .continuous))
                            .padding(10)
                    }
                }
            }
        }
    }

    @ViewBuilder
    private var fallbackCoverView: some View {
        if let fallbackCoverImage {
            Image(nsImage: fallbackCoverImage)
                .resizable()
                .aspectRatio(contentMode: .fill)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .clipped()
        } else {
            Color.black
        }
    }

    private func handleDirectStreamFailure() {
        let count = plan?.directStreams.count ?? 0
        if directStreamIndex + 1 < count {
            directStreamIndex += 1
        } else {
            allDirectStreamsFailed = true
            if plan?.embedPlayer != nil {
                useEmbedMode = true
            }
        }
    }
}

private struct DirectStreamAVPlayerViewMac: NSViewRepresentable {
    let stream: VideoStreamPlaybackPlan.DirectStream
    var isPlaybackSuspended: Bool = false
    let captureBridge: StreamingFrameCaptureBridge
    let onPlaybackFailed: @MainActor () -> Void

    @MainActor
    final class Coordinator {
        var currentStream: VideoStreamPlaybackPlan.DirectStream?
        var wasSuspended: Bool = false
        var loadTask: Task<Void, Never>?
        var statusObservation: NSKeyValueObservation?
        var videoOutput: AVPlayerItemVideoOutput?
        weak var captureBridge: StreamingFrameCaptureBridge?
        var onPlaybackFailed: (@MainActor () -> Void)?
        var didReportFailure = false

        func attach(
            stream: VideoStreamPlaybackPlan.DirectStream,
            to view: AVPlayerView,
            suspended: Bool,
            captureBridge: StreamingFrameCaptureBridge,
            onPlaybackFailed: @escaping @MainActor () -> Void
        ) {
            teardown(view)
            currentStream = stream
            wasSuspended = suspended
            self.captureBridge = captureBridge
            self.onPlaybackFailed = onPlaybackFailed
            didReportFailure = false

            loadTask = Task { @MainActor [weak view, weak self] in
                guard !Task.isCancelled, let view, let self else { return }
                let options: [String: Any]? = stream.httpHeaders.isEmpty
                    ? nil
                    : ["AVURLAssetHTTPHeaderFieldsKey": stream.httpHeaders]
                let asset = AVURLAsset(url: stream.url, options: options)
                let playable = (try? await asset.load(.isPlayable)) ?? false
                guard !Task.isCancelled else { return }
                guard playable else {
                    self.reportFailureOnce()
                    return
                }

                let item = AVPlayerItem(asset: asset)
                item.preferredForwardBufferDuration = 12
                let output = VideoFrameCapture.makeVideoOutput()
                item.add(output)
                self.videoOutput = output

                self.statusObservation = item.observe(\.status, options: [.new]) { [weak self] observedItem, _ in
                    if observedItem.status == .failed {
                        Task { @MainActor [weak self] in
                            self?.reportFailureOnce()
                        }
                    }
                }
                let player = AVPlayer(playerItem: item)
                player.automaticallyWaitsToMinimizeStalling = true
                view.player = player
                self.captureBridge?.captureCurrentFrame = { [weak player, weak output] in
                    guard let player,
                          let result = await VideoFrameCapture.captureCurrentFrameJPEG(from: player, videoOutput: output) else {
                        return nil
                    }
                    return (result.jpegData, result.timestampSeconds)
                }
                if !self.wasSuspended {
                    player.play()
                }
            }
        }

        private func reportFailureOnce() {
            guard !didReportFailure else { return }
            didReportFailure = true
            onPlaybackFailed?()
        }

        func teardown(_ view: AVPlayerView) {
            loadTask?.cancel()
            loadTask = nil
            statusObservation?.invalidate()
            statusObservation = nil
            captureBridge?.captureCurrentFrame = nil
            videoOutput = nil
            view.player?.pause()
            view.player?.replaceCurrentItem(with: nil)
            view.player = nil
        }
    }

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func makeNSView(context: Context) -> AVPlayerView {
        let view = AVPlayerView()
        view.controlsStyle = .floating
        view.showsFullScreenToggleButton = true
        context.coordinator.attach(
            stream: stream,
            to: view,
            suspended: isPlaybackSuspended,
            captureBridge: captureBridge,
            onPlaybackFailed: onPlaybackFailed
        )
        return view
    }

    func updateNSView(_ nsView: AVPlayerView, context: Context) {
        if context.coordinator.currentStream != stream {
            context.coordinator.attach(
                stream: stream,
                to: nsView,
                suspended: isPlaybackSuspended,
                captureBridge: captureBridge,
                onPlaybackFailed: onPlaybackFailed
            )
            return
        }
        if context.coordinator.wasSuspended != isPlaybackSuspended {
            context.coordinator.wasSuspended = isPlaybackSuspended
            if isPlaybackSuspended {
                nsView.player?.pause()
            } else {
                nsView.player?.play()
            }
        }
    }

    static func dismantleNSView(_ nsView: AVPlayerView, coordinator: Coordinator) {
        coordinator.teardown(nsView)
    }
}

private struct EmbedStreamWebPlayerViewMac: NSViewRepresentable {
    let embed: VideoStreamPlaybackPlan.EmbedPlayer
    var isPlaybackSuspended: Bool = false
    let captureBridge: StreamingFrameCaptureBridge

    @MainActor
    final class Coordinator {
        var loadedEmbed: VideoStreamPlaybackPlan.EmbedPlayer?
        var wasSuspended: Bool = false
        weak var captureBridge: StreamingFrameCaptureBridge?
    }

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func makeNSView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        config.mediaTypesRequiringUserActionForPlayback = []
        config.allowsAirPlayForMediaPlayback = true
        config.preferences.isElementFullscreenEnabled = true
        let webView = WKWebView(frame: .zero, configuration: config)
        webView.setValue(false, forKey: "drawsBackground")
        if let ua = embed.userAgent {
            webView.customUserAgent = ua
        }
        context.coordinator.captureBridge = captureBridge
        registerSnapshotBridge(for: webView)
        loadEmbed(embed, into: webView, coordinator: context.coordinator)
        return webView
    }

    func updateNSView(_ nsView: WKWebView, context: Context) {
        context.coordinator.captureBridge = captureBridge
        registerSnapshotBridge(for: nsView)
        if context.coordinator.loadedEmbed != embed {
            loadEmbed(embed, into: nsView, coordinator: context.coordinator)
        }
        if context.coordinator.wasSuspended != isPlaybackSuspended {
            context.coordinator.wasSuspended = isPlaybackSuspended
            if isPlaybackSuspended {
                nsView.evaluateJavaScript("document.querySelectorAll('video,audio').forEach(e=>e.pause());", completionHandler: nil)
            }
        }
    }

    static func dismantleNSView(_ nsView: WKWebView, coordinator: Coordinator) {
        coordinator.captureBridge?.captureCurrentFrame = nil
        nsView.stopLoading()
        nsView.loadHTMLString("", baseURL: nil)
        coordinator.loadedEmbed = nil
    }

    private func registerSnapshotBridge(for webView: WKWebView) {
        captureBridge.captureCurrentFrame = { [weak webView] in
            guard let webView else { return nil }
            let config = WKSnapshotConfiguration()
            config.afterScreenUpdates = false
            guard let snapshot = try? await webView.takeSnapshot(configuration: config),
                  let cgImage = snapshot.cgImage(forProposedRect: nil, context: nil, hints: nil),
                  let jpeg = VideoFrameCapture.encodeJPEG(cgImage) else {
                return nil
            }
            return (jpeg, nil)
        }
    }

    private func loadEmbed(
        _ embed: VideoStreamPlaybackPlan.EmbedPlayer,
        into webView: WKWebView,
        coordinator: Coordinator
    ) {
        coordinator.loadedEmbed = embed
        coordinator.wasSuspended = isPlaybackSuspended
        let (html, baseURL) = VideoPlatformResolver.embedHTML(for: embed)
        webView.loadHTMLString(html, baseURL: baseURL)
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
                    .buttonStyle(.charkle(.standard, size: .xs))
                }

                Button {
                    let pb = NSPasteboard.general
                    pb.clearContents()
                    pb.setString(fullText, forType: .string)
                } label: {
                    Label("复制全文", systemImage: "doc.on.doc")
                }
                .buttonStyle(.charkle(.standard, size: .xs))
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
        .task(id: "\(asset.id.uuidString)-\(originalURL?.path ?? "")") {
            let fallbackText = asset.notes.isEmpty ? (asset.ocrText ?? asset.richMetadata?.textExcerpt ?? "") : asset.notes
            if let url = originalURL,
               let decoded = await Self.readTextOffMain(url: url),
               !decoded.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                guard !Task.isCancelled else { return }
                fullText = decoded
            } else {
                guard !Task.isCancelled else { return }
                fullText = fallbackText
            }
        }
    }

    @concurrent
    private static func readTextOffMain(url: URL) async -> String? {
        guard !Task.isCancelled, let data = try? Data(contentsOf: url) else { return nil }
        return CanvasFormatters.decodeUTF8Prefix(data, maxBytes: 262_144)
    }
}

// MARK: - Cached Remote Image Loader (Supports SVG, WebP, PNG, JPEG, GIF)

nonisolated final class RemoteImageBox: @unchecked Sendable {
    let image: NSImage
    init(_ image: NSImage) { self.image = image }
}

nonisolated final class RemoteImageMemoryCache: @unchecked Sendable {
    static let shared = RemoteImageMemoryCache()
    private let cache = NSCache<NSString, RemoteImageBox>()

    private init() {
        cache.countLimit = 64
        cache.totalCostLimit = 32 * 1024 * 1024
    }

    func box(for url: URL) -> RemoteImageBox? {
        cache.object(forKey: url.absoluteString as NSString)
    }

    func image(for url: URL) -> NSImage? {
        box(for: url)?.image
    }

    func store(_ box: RemoteImageBox, for url: URL) {
        let rep = box.image.representations.first
        let pixelW = max(rep?.pixelsWide ?? 0, Int(box.image.size.width * 2))
        let pixelH = max(rep?.pixelsHigh ?? 0, Int(box.image.size.height * 2))
        let byteCost = max(1, pixelW) * max(1, pixelH) * 4
        cache.setObject(box, forKey: url.absoluteString as NSString, cost: byteCost)
    }

    func store(_ image: NSImage, for url: URL) {
        store(RemoteImageBox(image), for: url)
    }

    func clearAll() {
        cache.removeAllObjects()
    }
}

private nonisolated enum RemoteImageFetcher {
    @concurrent
    static func fetchImageOffMain(url targetURL: URL) async -> RemoteImageBox? {
        guard !Task.isCancelled else { return nil }
        var request = URLRequest(url: targetURL, timeoutInterval: 10)
        if XiaohongshuURLParser.isXiaohongshuMediaHost(targetURL.host()) {
            request.setValue(
                "Mozilla/5.0 (Macintosh; Intel Mac OS X 15_0) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.2 Safari/605.1.15",
                forHTTPHeaderField: "User-Agent"
            )
            request.setValue("https://www.xiaohongshu.com/", forHTTPHeaderField: "Referer")
        } else if VideoPlatformURLParser.isBilibiliMediaHost(targetURL.host()) {
            request.setValue(
                "Mozilla/5.0 (Macintosh; Intel Mac OS X 15_0) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.2 Safari/605.1.15",
                forHTTPHeaderField: "User-Agent"
            )
            request.setValue("https://www.bilibili.com/", forHTTPHeaderField: "Referer")
        } else {
            request.setValue("Charkle/1.0 (+https://charkle.app)", forHTTPHeaderField: "User-Agent")
        }
        request.setValue("image/svg+xml,image/webp,image/png,image/jpeg,image/gif,image/*", forHTTPHeaderField: "Accept")
        guard let (data, response) = try? await URLSession.shared.data(for: request),
              !Task.isCancelled,
              let http = response as? HTTPURLResponse,
              (200..<300).contains(http.statusCode),
              !data.isEmpty,
              data.count <= 24 * 1024 * 1024 else {
            return nil
        }
        // `NSImage(data:)` natively renders SVG, WebP, PNG, JPEG, and GIF on macOS 15+.
        guard let image = NSImage(data: data), image.size.width > 0, image.size.height > 0 else {
            return nil
        }
        image.isTemplate = false
        return RemoteImageBox(image)
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
            // Clear stale image from any prior asset immediately so it never flashes or masks load failures.
            loadedImage = nil
            didFail = false
            let fetchedBox = await RemoteImageFetcher.fetchImageOffMain(url: url)
            guard !Task.isCancelled else { return }
            if let fetched = fetchedBox?.image {
                RemoteImageMemoryCache.shared.store(fetched, for: url)
                loadedImage = fetched
            } else {
                didFail = true
            }
        }
    }
}

// MARK: - Native Textual Rich Markdown Renderer (GitHub README, Documents & Social Posts)

private final class PreparedSocialTextBox {
    let markdown: String
    let useStructuredBlocks: Bool
    init(markdown: String, useStructuredBlocks: Bool) {
        self.markdown = markdown
        self.useStructuredBlocks = useStructuredBlocks
    }
}

private enum CharkleMarkdownNormalizer {
    private static let cache: NSCache<NSString, NSString> = {
        let c = NSCache<NSString, NSString>()
        c.countLimit = 64
        return c
    }()

    private static let socialCache: NSCache<NSString, PreparedSocialTextBox> = {
        let c = NSCache<NSString, PreparedSocialTextBox>()
        c.countLimit = 128
        return c
    }()

    // Pre-compiled static regular expressions (avoids compiling ~16 ICU regexes per normalization pass)
    private static let headingLineRegex = try? NSRegularExpression(pattern: #"^#{1,6}[ \t]+\S"#)
    private static let listLineRegex = try? NSRegularExpression(pattern: #"^([-*+]|[0-9]+\.)[ \t]+\S"#)
    private static let bareURLRegex = try? NSRegularExpression(pattern: #"(?<!\]\()(?<!<)(https?://[^\s<>\)\]]+)"#)
    private static let htmlCommentRegex = try? NSRegularExpression(pattern: #"<!--[\s\S]*?-->"#)
    private static let summaryTagRegex = try? NSRegularExpression(pattern: #"(?is)<summary\b[^>]*>([\s\S]*?)</summary>"#)
    private static let strongTagRegex = try? NSRegularExpression(pattern: #"(?is)<(?:strong|b)\b[^>]*>([\s\S]*?)</(?:strong|b)>"#)
    private static let emTagRegex = try? NSRegularExpression(pattern: #"(?is)<(?:em|i)\b[^>]*>([\s\S]*?)</(?:em|i)>"#)
    private static let codeTagRegex = try? NSRegularExpression(pattern: #"(?is)<(?:code|kbd)\b[^>]*>([\s\S]*?)</(?:code|kbd)>"#)
    private static let brTagRegex = try? NSRegularExpression(pattern: #"(?i)<br\s*/?>"#)
    private static let hrTagRegex = try? NSRegularExpression(pattern: #"(?i)<hr\s*/?>"#)
    private static let inlineSpanTagRegex = try? NSRegularExpression(pattern: #"(?i)</?(?:span|sub|sup)\b[^>]*>"#)
    private static let blockHTMLTagRegex = try? NSRegularExpression(pattern: #"(?i)</?(?:div|p|picture|source|details|center|section|article|header|footer|figure|figcaption|table|thead|tbody|tr|td|th)\b[^>]*>"#)
    private static let githubAlertRegex = try? NSRegularExpression(pattern: #"(?m)^([ \t]*>[ \t]*)\[!(NOTE|TIP|IMPORTANT|WARNING|CAUTION)\][ \t]*$"#)
    private static let linkedImageRegex = try? NSRegularExpression(pattern: #"(?is)<a\b[^>]*href\s*=\s*["']([^"']+)["'][^>]*>\s*(<img\b[^>]*>)\s*</a>"#)
    private static let standaloneImageRegex = try? NSRegularExpression(pattern: #"(?i)<img\b[^>]*>"#)
    private static let htmlHeadingRegex = try? NSRegularExpression(pattern: #"(?is)<h([1-6])\b[^>]*>([\s\S]*?)</h\1>"#)
    private static let htmlAnchorRegex = try? NSRegularExpression(pattern: #"(?is)<a\b[^>]*href\s*=\s*["']([^"']+)["'][^>]*>([\s\S]*?)</a>"#)
    private static let htmlTagStripRegex = try? NSRegularExpression(pattern: #"<[^>]+>"#)
    private static let srcAttrRegex = try? NSRegularExpression(pattern: #"(?i)\bsrc\s*=\s*(?:"([^"]*)"|'([^']*)')"#)
    private static let altAttrRegex = try? NSRegularExpression(pattern: #"(?i)\balt\s*=\s*(?:"([^"]*)"|'([^']*)')"#)
    private static let excessBlankLinesRegex = try? NSRegularExpression(pattern: #"\n{3,}"#)

    static func normalize(_ markdown: String, urlContext: MarkdownURLContext) -> String {
        var hasher = Hasher()
        hasher.combine(markdown)
        hasher.combine(urlContext)
        let cacheKey = "\(markdown.count)-\(hasher.finalize())" as NSString
        if let cached = cache.object(forKey: cacheKey) {
            return cached as String
        }
        let result = normalizeUncached(markdown, urlContext: urlContext)
        cache.setObject(result as NSString, forKey: cacheKey)
        return result
    }

    static func prepareSocialText(_ raw: String, forceBlockMode: Bool) -> (markdown: String, useStructuredBlocks: Bool) {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return ("", false) }
        var hasher = Hasher()
        hasher.combine(trimmed)
        hasher.combine(forceBlockMode)
        let key = "\(trimmed.count)-\(forceBlockMode ? 1 : 0)-\(hasher.finalize())" as NSString
        if let cached = socialCache.object(forKey: key) {
            return (cached.markdown, cached.useStructuredBlocks)
        }
        let useBlocks = forceBlockMode || containsBlockMarkdown(trimmed)
        let linked = autoLinkBareURLs(in: trimmed)
        socialCache.setObject(PreparedSocialTextBox(markdown: linked, useStructuredBlocks: useBlocks), forKey: key)
        return (linked, useBlocks)
    }

    private static func containsBlockMarkdown(_ text: String) -> Bool {
        if text.contains("```") || text.contains("~~~") { return true }
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false)
        var listLines = 0
        for rawLine in lines {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            let range = NSRange(location: 0, length: (line as NSString).length)
            if let headingLineRegex, headingLineRegex.firstMatch(in: line, range: range) != nil {
                return true
            }
            if line.hasPrefix("> ") {
                return true
            }
            if let listLineRegex, listLineRegex.firstMatch(in: line, range: range) != nil {
                listLines += 1
                if listLines >= 2 { return true }
            }
        }
        return false
    }

    private static func autoLinkBareURLs(in text: String) -> String {
        // Fast-path: skip regex scanning completely when no HTTP(S) URL exists in the post.
        guard text.contains("http://") || text.contains("https://") else { return text }
        guard let regex = bareURLRegex else { return text }
        let segments = splitFencedCodeBlocks(text)

        return segments.map { segment in
            guard !segment.isCode else { return segment.text }
            let ns = segment.text as NSString
            let matches = regex.matches(in: segment.text, range: NSRange(location: 0, length: ns.length))
            guard !matches.isEmpty else { return segment.text }

            var output = segment.text
            for match in matches.reversed() {
                guard let range = Range(match.range(at: 1), in: output) else { continue }
                var urlStr = String(output[range])
                var trailing = ""
                while let last = urlStr.last, ".,;:!?".contains(last) {
                    trailing.insert(urlStr.removeLast(), at: trailing.startIndex)
                }
                guard !urlStr.isEmpty else { continue }
                output.replaceSubrange(range, with: "[\(urlStr)](\(urlStr))\(trailing)")
            }
            return output
        }.joined()
    }

    private struct CodeSegment {
        let text: String
        let isCode: Bool
    }

    private static func splitFencedCodeBlocks(_ input: String) -> [CodeSegment] {
        let lines = input.components(separatedBy: "\n")
        var segments: [CodeSegment] = []
        var buffer: [String] = []
        var inCode = false
        var fenceChar: Character = "`"
        var fenceLength = 3

        func flush() {
            guard !buffer.isEmpty else { return }
            segments.append(CodeSegment(text: buffer.joined(separator: "\n"), isCode: inCode))
            buffer.removeAll(keepingCapacity: true)
        }

        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if !inCode {
                if let (ch, len) = openingFence(trimmed) {
                    if !buffer.isEmpty {
                        segments.append(CodeSegment(text: buffer.joined(separator: "\n") + "\n", isCode: false))
                        buffer.removeAll(keepingCapacity: true)
                    }
                    inCode = true
                    fenceChar = ch
                    fenceLength = len
                    buffer.append(line)
                } else {
                    buffer.append(line)
                }
            } else {
                buffer.append(line)
                if isClosingFence(trimmed, char: fenceChar, minLength: fenceLength) {
                    segments.append(CodeSegment(text: buffer.joined(separator: "\n") + "\n", isCode: true))
                    buffer.removeAll(keepingCapacity: true)
                    inCode = false
                }
            }
        }
        flush()
        return segments
    }

    private static func openingFence(_ trimmedLine: String) -> (Character, Int)? {
        guard let first = trimmedLine.first, first == "`" || first == "~" else { return nil }
        let count = trimmedLine.prefix(while: { $0 == first }).count
        return count >= 3 ? (first, count) : nil
    }

    private static func isClosingFence(_ trimmedLine: String, char: Character, minLength: Int) -> Bool {
        let count = trimmedLine.prefix(while: { $0 == char }).count
        guard count >= minLength else { return false }
        return trimmedLine.dropFirst(count).trimmingCharacters(in: .whitespaces).isEmpty
    }

    private static func normalizeUncached(_ markdown: String, urlContext: MarkdownURLContext) -> String {
        let unified = markdown
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
        let segments = splitFencedCodeBlocks(unified)
        let transformed = segments.map { segment in
            segment.isCode ? segment.text : normalizeProseSegment(segment.text, urlContext: urlContext)
        }.joined()
        return collapseExcessBlankLines(transformed).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func normalizeProseSegment(_ raw: String, urlContext: MarkdownURLContext) -> String {
        var s = raw
        // Fast-path skip HTML tag passes when segment contains no angle brackets
        if s.contains("<") {
            // Strip HTML comments
            s = replacingRegex(s, regex: htmlCommentRegex, with: "")

            // Convert linked HTML images: <a href="..."><img ...></a> -> [![alt](src)](href)
            s = replaceLinkedImages(in: s, urlContext: urlContext)

            // Convert standalone HTML images: <img ...> -> ![alt](src)
            s = replaceStandaloneImages(in: s, urlContext: urlContext)

            // Convert HTML headings <h1..h6> -> Markdown headings
            s = replaceHTMLHeadings(in: s)

            // Convert HTML links <a href="...">label</a> -> [label](url)
            s = replaceHTMLAnchors(in: s, urlContext: urlContext)

            // Convert HTML <summary>title</summary> into bold lead-in
            s = replacingRegex(s, regex: summaryTagRegex, with: "\n**$1**\n")

            // Convert inline emphasis & code tags
            s = replacingRegex(s, regex: strongTagRegex, with: "**$1**")
            s = replacingRegex(s, regex: emTagRegex, with: "*$1*")
            s = replacingRegex(s, regex: codeTagRegex, with: "`$1`")
            s = replacingRegex(s, regex: brTagRegex, with: "  \n")
            s = replacingRegex(s, regex: hrTagRegex, with: "\n---\n")

            // Remove inline formatting wrapper tags without injecting artificial line breaks
            s = replacingRegex(s, regex: inlineSpanTagRegex, with: "")

            // Remove purely structural block HTML tags so Markdown inside them renders cleanly
            s = replacingRegex(s, regex: blockHTMLTagRegex, with: "\n")
        }

        // Normalize GitHub alert blockquotes (> [!NOTE], > [!TIP], > [!IMPORTANT], > [!WARNING], > [!CAUTION])
        if s.contains("[!") {
            s = replacingRegex(s, regex: githubAlertRegex, with: "$1**$2**  ")
        }

        return decodeHTMLEntities(s)
    }

    private static func replaceLinkedImages(in input: String, urlContext: MarkdownURLContext) -> String {
        guard let regex = linkedImageRegex else { return input }
        let ns = input as NSString
        let matches = regex.matches(in: input, range: NSRange(location: 0, length: ns.length))
        guard !matches.isEmpty else { return input }

        var output = input
        for match in matches.reversed() {
            guard let fullRange = Range(match.range(at: 0), in: output),
                  let hrefRange = Range(match.range(at: 1), in: output),
                  let imgRange = Range(match.range(at: 2), in: output) else { continue }
            let href = urlContext.resolveLinkURL(decodeHTMLEntities(String(output[hrefRange])))
            let imgTag = String(output[imgRange])
            if let rawSrc = extractHTMLAttribute(regex: srcAttrRegex, from: imgTag), !rawSrc.isEmpty {
                let resolvedSrc = urlContext.resolveAssetURL(decodeHTMLEntities(rawSrc))
                let alt = extractHTMLAttribute(regex: altAttrRegex, from: imgTag).map(decodeHTMLEntities) ?? ""
                output.replaceSubrange(fullRange, with: "[![\(alt)](\(resolvedSrc))](\(href))")
            }
        }
        return output
    }

    private static func replaceStandaloneImages(in input: String, urlContext: MarkdownURLContext) -> String {
        guard let regex = standaloneImageRegex else { return input }
        let ns = input as NSString
        let matches = regex.matches(in: input, range: NSRange(location: 0, length: ns.length))
        guard !matches.isEmpty else { return input }

        var output = input
        for match in matches.reversed() {
            guard let fullRange = Range(match.range(at: 0), in: output) else { continue }
            let imgTag = String(output[fullRange])
            guard let rawSrc = extractHTMLAttribute(regex: srcAttrRegex, from: imgTag), !rawSrc.isEmpty else {
                output.replaceSubrange(fullRange, with: "")
                continue
            }
            let resolvedSrc = urlContext.resolveAssetURL(decodeHTMLEntities(rawSrc))
            let alt = extractHTMLAttribute(regex: altAttrRegex, from: imgTag).map(decodeHTMLEntities) ?? ""
            output.replaceSubrange(fullRange, with: "![\(alt)](\(resolvedSrc))")
        }
        return output
    }

    private static func replaceHTMLHeadings(in input: String) -> String {
        guard let regex = htmlHeadingRegex else { return input }
        let ns = input as NSString
        let matches = regex.matches(in: input, range: NSRange(location: 0, length: ns.length))
        guard !matches.isEmpty else { return input }

        var output = input
        for match in matches.reversed() {
            guard let fullRange = Range(match.range(at: 0), in: output),
                  let levelRange = Range(match.range(at: 1), in: output),
                  let bodyRange = Range(match.range(at: 2), in: output),
                  let level = Int(output[levelRange]) else { continue }
            let hashes = String(repeating: "#", count: max(1, min(6, level)))
            let text = replacingRegex(String(output[bodyRange]), regex: htmlTagStripRegex, with: "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            output.replaceSubrange(fullRange, with: "\n\(hashes) \(text)\n")
        }
        return output
    }

    private static func replaceHTMLAnchors(in input: String, urlContext: MarkdownURLContext) -> String {
        guard let regex = htmlAnchorRegex else { return input }
        let ns = input as NSString
        let matches = regex.matches(in: input, range: NSRange(location: 0, length: ns.length))
        guard !matches.isEmpty else { return input }

        var output = input
        for match in matches.reversed() {
            guard let fullRange = Range(match.range(at: 0), in: output),
                  let hrefRange = Range(match.range(at: 1), in: output),
                  let labelRange = Range(match.range(at: 2), in: output) else { continue }
            let href = urlContext.resolveLinkURL(decodeHTMLEntities(String(output[hrefRange])))
            let label = replacingRegex(String(output[labelRange]), regex: htmlTagStripRegex, with: "")
                .replacingOccurrences(of: "\n", with: " ")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let replacement = label.isEmpty ? "[\(href)](\(href))" : "[\(label)](\(href))"
            output.replaceSubrange(fullRange, with: replacement)
        }
        return output
    }

    private static func extractHTMLAttribute(regex: NSRegularExpression?, from tag: String) -> String? {
        guard let regex else { return nil }
        let ns = tag as NSString
        guard let match = regex.firstMatch(in: tag, range: NSRange(location: 0, length: ns.length)) else {
            return nil
        }
        if match.range(at: 1).location != NSNotFound, let r = Range(match.range(at: 1), in: tag) {
            return String(tag[r])
        }
        if match.range(at: 2).location != NSNotFound, let r = Range(match.range(at: 2), in: tag) {
            return String(tag[r])
        }
        return nil
    }

    private static func replacingRegex(_ input: String, regex: NSRegularExpression?, with template: String) -> String {
        guard let regex else { return input }
        let range = NSRange(location: 0, length: (input as NSString).length)
        return regex.stringByReplacingMatches(in: input, range: range, withTemplate: template)
    }

    private static func decodeHTMLEntities(_ input: String) -> String {
        guard input.contains("&") else { return input }
        var s = input
        let entities: [(String, String)] = [
            ("&amp;", "&"),
            ("&lt;", "<"),
            ("&gt;", ">"),
            ("&quot;", "\""),
            ("&#39;", "'"),
            ("&apos;", "'"),
            ("&nbsp;", " "),
            ("&middot;", "·"),
            ("&mdash;", "—"),
            ("&ndash;", "–"),
            ("&copy;", "©")
        ]
        for (entity, value) in entities {
            s = s.replacingOccurrences(of: entity, with: value)
        }
        return s
    }

    private static func collapseExcessBlankLines(_ input: String) -> String {
        replacingRegex(input, regex: excessBlankLinesRegex, with: "\n\n")
    }
}

private nonisolated struct CharkleMarkdownImageAttachment: Textual.Attachment {
    let url: URL
    let imageBox: RemoteImageBox
    let naturalSize: CGSize
    let altText: String

    var description: String { altText }

    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.url == rhs.url && lhs.altText == rhs.altText
    }

    func hash(into hasher: inout Hasher) {
        hasher.combine(url)
        hasher.combine(altText)
    }

    @MainActor
    var body: some View {
        let isBadge = naturalSize.height <= 36 && naturalSize.width <= 320
        Image(nsImage: imageBox.image)
            .renderingMode(.original)
            .resizable()
            .interpolation(.high)
            .aspectRatio(contentMode: .fit)
            .clipShape(RoundedRectangle(cornerRadius: isBadge ? 4 : 8, style: .continuous))
    }

    func sizeThatFits(_ proposal: ProposedViewSize, in _: TextEnvironmentValues) -> CGSize {
        let rawW = max(1, naturalSize.width)
        let rawH = max(1, naturalSize.height)
        let aspect = rawW / rawH
        let maxW = proposal.width ?? rawW
        var width = min(maxW, rawW)
        var height = width / aspect
        let maxH: CGFloat = (rawH <= 36 && rawW <= 320) ? 32 : 440
        if height > maxH {
            height = maxH
            width = height * aspect
        }
        return CGSize(width: max(1, width), height: max(1, height))
    }

    func pngData() -> Data? {
        guard let tiff = imageBox.image.tiffRepresentation,
              let rep = NSBitmapImageRep(data: tiff) else { return nil }
        return rep.representation(using: .png, properties: [:])
    }
}

private nonisolated struct CharkleMarkdownAttachmentLoader: AttachmentLoader {
    let urlContext: MarkdownURLContext

    func attachment(
        for url: URL,
        text: String,
        environment _: ColorEnvironmentValues
    ) async throws -> CharkleMarkdownImageAttachment {
        let resolvedString = urlContext.resolveAssetURL(url.absoluteString)
        guard let targetURL = URL(string: resolvedString) else {
            throw URLError(.badURL)
        }
        if let cached = RemoteImageMemoryCache.shared.box(for: targetURL) {
            return CharkleMarkdownImageAttachment(
                url: targetURL,
                imageBox: cached,
                naturalSize: cached.image.size,
                altText: text
            )
        }
        guard let box = await RemoteImageFetcher.fetchImageOffMain(url: targetURL) else {
            throw URLError(.cannotDecodeContentData)
        }
        RemoteImageMemoryCache.shared.store(box, for: targetURL)
        return CharkleMarkdownImageAttachment(
            url: targetURL,
            imageBox: box,
            naturalSize: box.image.size,
            altText: text
        )
    }
}

private enum CharkleTextualStyles {
    static let inlineStyle: InlineStyle = InlineStyle()
        .code(
            .monospaced,
            .fontScale(0.86),
            .backgroundColor(
                DynamicColor(
                    light: Color.black.opacity(0.055),
                    dark: Color.white.opacity(0.09)
                )
            )
        )
        .strong(.fontWeight(.semibold))
        .link(
            .foregroundColor(
                DynamicColor(
                    light: Color(charkleHex: "#2A60E0"),
                    dark: Color(charkleHex: "#5B8DEF")
                )
            )
        )

    /// Calibrated studio syntax-highlighting palette (Light/Dark contrast, strictly zero violet hues).
    static let highlighterTheme = StructuredText.HighlighterTheme(
        foregroundColor: DynamicColor(
            light: Color(charkleHex: "#1F2328"),
            dark: Color(charkleHex: "#E6EDF3")
        ),
        backgroundColor: DynamicColor(
            light: Color(charkleHex: "#F3F4F6"),
            dark: Color(charkleHex: "#1C1F26")
        ),
        tokenProperties: [
            .keyword: AnyTextProperty(
                .foregroundColor(DynamicColor(light: Color(charkleHex: "#2A60E0"), dark: Color(charkleHex: "#5B8DEF"))),
                .fontWeight(.semibold)
            ),
            .builtin: AnyTextProperty(
                .foregroundColor(DynamicColor(light: Color(charkleHex: "#0E7490"), dark: Color(charkleHex: "#38BDF8")))
            ),
            .literal: AnyTextProperty(
                .foregroundColor(DynamicColor(light: Color(charkleHex: "#2A60E0"), dark: Color(charkleHex: "#5B8DEF"))),
                .fontWeight(.semibold)
            ),
            .boolean: AnyTextProperty(
                .foregroundColor(DynamicColor(light: Color(charkleHex: "#B45309"), dark: Color(charkleHex: "#FBBF24"))),
                .fontWeight(.semibold)
            ),
            .string: AnyTextProperty(
                .foregroundColor(DynamicColor(light: Color(charkleHex: "#B91C1C"), dark: Color(charkleHex: "#F87171")))
            ),
            .char: AnyTextProperty(
                .foregroundColor(DynamicColor(light: Color(charkleHex: "#B45309"), dark: Color(charkleHex: "#FBBF24")))
            ),
            .regex: AnyTextProperty(
                .foregroundColor(DynamicColor(light: Color(charkleHex: "#B91C1C"), dark: Color(charkleHex: "#F87171")))
            ),
            .url: AnyTextProperty(
                .foregroundColor(DynamicColor(light: Color(charkleHex: "#2A60E0"), dark: Color(charkleHex: "#5B8DEF")))
            ),
            .number: AnyTextProperty(
                .foregroundColor(DynamicColor(light: Color(charkleHex: "#B45309"), dark: Color(charkleHex: "#FBBF24")))
            ),
            .className: AnyTextProperty(
                .foregroundColor(DynamicColor(light: Color(charkleHex: "#047857"), dark: Color(charkleHex: "#34D399")))
            ),
            .function: AnyTextProperty(
                .foregroundColor(DynamicColor(light: Color(charkleHex: "#0F766E"), dark: Color(charkleHex: "#2DD4BF")))
            ),
            .functionName: AnyTextProperty(
                .foregroundColor(DynamicColor(light: Color(charkleHex: "#0F766E"), dark: Color(charkleHex: "#2DD4BF")))
            ),
            .variable: AnyTextProperty(
                .foregroundColor(DynamicColor(light: Color(charkleHex: "#1D4ED8"), dark: Color(charkleHex: "#79C0FF")))
            ),
            .constant: AnyTextProperty(
                .foregroundColor(DynamicColor(light: Color(charkleHex: "#0369A1"), dark: Color(charkleHex: "#79C0FF")))
            ),
            .property: AnyTextProperty(
                .foregroundColor(DynamicColor(light: Color(charkleHex: "#0369A1"), dark: Color(charkleHex: "#79C0FF")))
            ),
            .comment: AnyTextProperty(
                .foregroundColor(DynamicColor(light: Color(charkleHex: "#6B7280"), dark: Color(charkleHex: "#8B949E")))
            ),
            .blockComment: AnyTextProperty(
                .foregroundColor(DynamicColor(light: Color(charkleHex: "#6B7280"), dark: Color(charkleHex: "#8B949E")))
            ),
            .docComment: AnyTextProperty(
                .foregroundColor(DynamicColor(light: Color(charkleHex: "#6B7280"), dark: Color(charkleHex: "#8B949E")))
            ),
            .preprocessor: AnyTextProperty(
                .foregroundColor(DynamicColor(light: Color(charkleHex: "#9A3412"), dark: Color(charkleHex: "#FB923C")))
            ),
            .directive: AnyTextProperty(
                .foregroundColor(DynamicColor(light: Color(charkleHex: "#9A3412"), dark: Color(charkleHex: "#FB923C")))
            ),
            .attribute: AnyTextProperty(
                .foregroundColor(DynamicColor(light: Color(charkleHex: "#92400E"), dark: Color(charkleHex: "#F59E0B")))
            ),
            .tag: AnyTextProperty(
                .foregroundColor(DynamicColor(light: Color(charkleHex: "#047857"), dark: Color(charkleHex: "#34D399")))
            ),
            .attributeName: AnyTextProperty(
                .foregroundColor(DynamicColor(light: Color(charkleHex: "#0369A1"), dark: Color(charkleHex: "#79C0FF")))
            ),
            .inserted: AnyTextProperty(
                .foregroundColor(DynamicColor(light: Color(charkleHex: "#15803D"), dark: Color(charkleHex: "#4ADE80")))
            ),
            .deleted: AnyTextProperty(
                .foregroundColor(DynamicColor(light: Color(charkleHex: "#DC2626"), dark: Color(charkleHex: "#F87171")))
            )
        ]
    )

    static var openURLAction: OpenURLAction {
        OpenURLAction { url in
            guard let scheme = url.scheme?.lowercased(),
                  scheme == "http" || scheme == "https" || scheme == "mailto" else {
                return .discarded
            }
            NSWorkspace.shared.open(url)
            return .handled
        }
    }
}

private struct CharkleCodeBlockStyle: StructuredText.CodeBlockStyle {
    func makeBody(configuration: Configuration) -> some View {
        CharkleCodeBlockBodyView(configuration: configuration)
    }
}

private struct CharkleCodeBlockBodyView: View {
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.charkleAccentSource) private var accentSource
    let configuration: StructuredText.CodeBlockStyleConfiguration
    @State private var copied: Bool = false

    var body: some View {
        let language = (configuration.languageHint ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let shape = RoundedRectangle(cornerRadius: 10, style: .continuous)
        let accent = CharkleTheme.accent(for: colorScheme, source: accentSource)

        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 6) {
                Text(language.isEmpty ? "CODE" : language.uppercased())
                    .font(.system(size: 10, weight: .semibold, design: .monospaced))
                    .foregroundStyle(.secondary)
                Spacer()
                Button {
                    configuration.codeBlock.copyToPasteboard()
                    copied = true
                    Task {
                        try? await Task.sleep(for: .seconds(1.2))
                        copied = false
                    }
                } label: {
                    HStack(spacing: 3.5) {
                        Image(systemName: copied ? "checkmark" : "doc.on.doc")
                            .font(.system(size: 9.5, weight: .semibold))
                        Text(copied ? "已复制" : "复制")
                            .font(.system(size: 10.5, weight: .medium))
                    }
                    .foregroundStyle(copied ? accent : .secondary)
                    .padding(.horizontal, 7)
                    .padding(.vertical, 3)
                    .background(
                        Color.primary.opacity(colorScheme == .dark ? 0.08 : 0.055),
                        in: RoundedRectangle(cornerRadius: 6, style: .continuous)
                    )
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 12)
            .padding(.top, 9)
            .padding(.bottom, 6)

            Rectangle()
                .fill(CharkleTheme.hairline(for: colorScheme))
                .frame(height: CharkleTheme.hairlineWidth)

            Overflow {
                configuration.label
                    .textual.lineSpacing(.fontScaled(0.24))
                    .textual.fontScale(0.88)
                    .fixedSize(horizontal: false, vertical: true)
                    .monospaced()
                    .padding(12)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            Color.primary.opacity(colorScheme == .dark ? 0.075 : 0.04),
            in: shape
        )
        .overlay(
            shape.strokeBorder(CharkleTheme.hairline(for: colorScheme), lineWidth: CharkleTheme.hairlineWidth)
        )
        .textual.blockSpacing(.init(top: 4, bottom: 12))
    }
}

/// Native SwiftUI Markdown renderer powered by `Textual`, supporting GitHub READMEs,
/// documents, GFM tables, syntax-highlighted copyable code blocks, remote/SVG images,
/// and native text selection with calibrated Light/Dark contrast.
struct QuickLookMarkdownContentView: View {
    let markdown: String
    let urlContext: MarkdownURLContext
    var fontSize: CGFloat = 13.5

    init(
        markdown: String,
        urlContext: MarkdownURLContext = MarkdownURLContext(),
        fontSize: CGFloat = 13.5
    ) {
        self.markdown = markdown
        self.urlContext = urlContext
        self.fontSize = fontSize
    }

    var body: some View {
        let normalized = CharkleMarkdownNormalizer.normalize(markdown, urlContext: urlContext)
        if normalized.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            Text("暂无可预览正文")
                .font(.system(size: fontSize))
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
        } else {
            StructuredText(markdown: normalized, baseURL: urlContext.webLinkBaseURL)
                .font(.system(size: fontSize))
                .textual.structuredTextStyle(.gitHub)
                .textual.inlineStyle(CharkleTextualStyles.inlineStyle)
                .textual.codeBlockStyle(CharkleCodeBlockStyle())
                .textual.highlighterTheme(CharkleTextualStyles.highlighterTheme)
                .textual.overflowMode(.scroll)
                .textual.imageAttachmentLoader(CharkleMarkdownAttachmentLoader(urlContext: urlContext))
                .textual.textSelection(.enabled)
                .environment(\.openURL, CharkleTextualStyles.openURLAction)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

/// Renders rich social post copy via `Textual` (`StructuredText` for articles & block Markdown;
/// `InlineText` preserving line breaks for standard posts and quotes).
private struct QuickLookSocialRichTextView: View {
    let text: String
    let isArticle: Bool
    let fontSize: CGFloat

    var body: some View {
        let prepared = CharkleMarkdownNormalizer.prepareSocialText(text, forceBlockMode: isArticle)
        if prepared.useStructuredBlocks {
            QuickLookMarkdownContentView(markdown: prepared.markdown, fontSize: fontSize)
        } else {
            InlineText(markdown: prepared.markdown)
                .font(.system(size: fontSize))
                .lineSpacing(5)
                .textual.inlineStyle(CharkleTextualStyles.inlineStyle)
                .textual.textSelection(.enabled)
                .environment(\.openURL, CharkleTextualStyles.openURLAction)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
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
                        .buttonStyle(.charkle(.accent, size: .sm))
                    }
                }
                .padding(32)
                .frame(maxWidth: 520, maxHeight: 380)
                .background(Color(charkleHex: "#181A20"), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
            }
        }
        .frame(maxWidth: 960, maxHeight: 640)
        .onChange(of: originalURL) { _, _ in
            loadFailed = false
        }
    }
}

private nonisolated final class LoadedSCNSceneBox: @unchecked Sendable {
    let scene: SCNScene
    let cameraNode: SCNNode
    let defaultCameraPosition: SCNVector3
    let defaultTarget: SCNVector3

    init(scene: SCNScene, cameraNode: SCNNode, defaultCameraPosition: SCNVector3, defaultTarget: SCNVector3) {
        self.scene = scene
        self.cameraNode = cameraNode
        self.defaultCameraPosition = defaultCameraPosition
        self.defaultTarget = defaultTarget
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
        var loadTask: Task<Void, Never>?

        func load(url: URL, resetTrigger: Int, into view: SCNView, onFailed: @escaping () -> Void) {
            loadTask?.cancel()
            lastURL = url
            lastReset = resetTrigger
            view.stop(nil)
            view.isPlaying = false
            view.scene = nil
            view.pointOfView = nil

            loadTask = Task { @MainActor [weak self, weak view] in
                let loaded = await SceneKitInteractiveView.buildSceneOffMain(url: url)
                guard !Task.isCancelled, let self, let view, self.lastURL == url else { return }
                guard let loaded else {
                    onFailed()
                    return
                }
                self.defaultCameraPosition = loaded.defaultCameraPosition
                self.defaultTarget = loaded.defaultTarget
                view.scene = loaded.scene
                view.pointOfView = loaded.cameraNode
            }
        }

        func teardown(_ view: SCNView) {
            loadTask?.cancel()
            loadTask = nil
            lastURL = nil
            view.stop(nil)
            view.isPlaying = false
            view.scene = nil
            view.pointOfView = nil
        }
    }

    @concurrent
    private static func buildSceneOffMain(url: URL) async -> LoadedSCNSceneBox? {
        guard !Task.isCancelled else { return nil }
        let scene: SCNScene?
        if let direct = try? SCNScene(url: url, options: nil) {
            scene = direct
        } else {
            let mdl = MDLAsset(url: url)
            scene = mdl.count > 0 ? SCNScene(mdlAsset: mdl) : nil
        }
        guard !Task.isCancelled, let scene else { return nil }

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
        return LoadedSCNSceneBox(scene: scene, cameraNode: camNode, defaultCameraPosition: pos, defaultTarget: center)
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> SCNView {
        let view = SCNView()
        view.rendersContinuously = false
        view.allowsCameraControl = true
        view.autoenablesDefaultLighting = true
        view.antialiasingMode = .multisampling4X
        view.backgroundColor = NSColor(calibratedRed: 0.10, green: 0.11, blue: 0.14, alpha: 1.0)
        context.coordinator.load(url: url, resetTrigger: resetTrigger, into: view, onFailed: onFailed)
        return view
    }

    func updateNSView(_ nsView: SCNView, context: Context) {
        if context.coordinator.lastURL != url {
            context.coordinator.load(url: url, resetTrigger: resetTrigger, into: nsView, onFailed: onFailed)
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

    static func dismantleNSView(_ nsView: SCNView, coordinator: Coordinator) {
        coordinator.teardown(nsView)
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
