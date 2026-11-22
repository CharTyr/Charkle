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
        ScrollView(.vertical) {
            VStack(alignment: .leading, spacing: 18) {
                // Header: Owner Avatar + owner / repo + Actions
                HStack(alignment: .center, spacing: 12) {
                    if let avatarStr = repo.ownerAvatarURL, let avatarURL = URL(string: avatarStr) {
                        AsyncImage(url: avatarURL) { phase in
                            switch phase {
                            case .success(let image):
                                image.resizable().aspectRatio(contentMode: .fill)
                            default:
                                ownerMonogram
                            }
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
                    AsyncImage(url: ogURL) { phase in
                        if case .success(let image) = phase {
                            image
                                .resizable()
                                .aspectRatio(contentMode: .fit)
                                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                                .overlay(
                                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                                        .strokeBorder(Color.primary.opacity(0.08), lineWidth: 0.75)
                                )
                        }
                    }
                }

                Divider()

                // README Section
                VStack(alignment: .leading, spacing: 12) {
                    Text("README")
                        .font(.system(size: 11, weight: .bold, design: .monospaced))
                        .tracking(0.8)
                        .foregroundStyle(.secondary)

                    if let readme = repo.readmeMarkdown, !readme.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        QuickLookMarkdownContentView(markdown: readme)
                    } else {
                        Text("暂未拉取到 README 内容，可点击右上角刷新重试或前往 GitHub 查看。")
                            .font(.system(size: 13))
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .padding(26)
        }
        .frame(maxWidth: 740, maxHeight: 680)
        .background(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(colorScheme == .dark ? Color(charkleHex: "#18191D") : Color(charkleHex: "#FAFAFB"))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .strokeBorder(Color.white.opacity(colorScheme == .dark ? 0.10 : 0.45), lineWidth: 0.75)
        )
        .shadow(color: .black.opacity(0.45), radius: 32, y: 14)
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
        ScrollView(.vertical) {
            VStack(alignment: .leading, spacing: 16) {
                // Author Header
                HStack(spacing: 11) {
                    if let avatarStr = post.authorAvatarURL, let url = URL(string: avatarStr) {
                        AsyncImage(url: url) { phase in
                            if case .success(let img) = phase {
                                img.resizable().aspectRatio(contentMode: .fill)
                            } else {
                                authorFallbackAvatar
                            }
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
        }
        .frame(maxWidth: 680, maxHeight: 680)
        .background(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(colorScheme == .dark ? Color(charkleHex: "#1B1C20") : Color.white)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.10), lineWidth: 0.75)
        )
        .shadow(color: .black.opacity(colorScheme == .dark ? 0.42 : 0.14), radius: 24, y: 10)
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
                        AsyncImage(url: imgURL) { phase in
                            switch phase {
                            case .success(let image):
                                image
                                    .resizable()
                                    .aspectRatio(contentMode: .fit)
                                    .frame(maxHeight: attachments.count == 1 ? 420 : 240)
                            case .failure:
                                mediaFailedPlaceholder
                            default:
                                ProgressView().frame(height: 180)
                            }
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
    }

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func makeNSView(context: Context) -> AVPlayerView {
        let view = AVPlayerView()
        view.controlsStyle = .floating
        view.player = AVPlayer(url: url)
        context.coordinator.currentURL = url
        return view
    }

    func updateNSView(_ nsView: AVPlayerView, context: Context) {
        if context.coordinator.currentURL != url {
            nsView.player?.pause()
            nsView.player = AVPlayer(url: url)
            context.coordinator.currentURL = url
        }
    }

    static func dismantleNSView(_ nsView: AVPlayerView, coordinator: ()) {
        nsView.player?.pause()
        nsView.player = nil
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
        }
        .frame(maxWidth: 740, maxHeight: 620)
        .background(CharkleTheme.surfaceElevated(for: colorScheme), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .shadow(color: .black.opacity(0.38), radius: 26, y: 12)
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

/// Lightweight native Markdown block renderer (headings, fenced code blocks, blockquotes, lists, inline markdown).
struct QuickLookMarkdownContentView: View {
    @Environment(\.colorScheme) private var colorScheme
    let markdown: String

    private enum Block: Identifiable {
        case heading(id: Int, level: Int, text: String)
        case code(id: Int, language: String, content: String)
        case quote(id: Int, text: String)
        case bullet(id: Int, text: String)
        case divider(id: Int)
        case paragraph(id: Int, text: String)

        var id: Int {
            switch self {
            case .heading(let id, _, _),
                 .code(let id, _, _),
                 .quote(let id, _),
                 .bullet(let id, _),
                 .divider(let id),
                 .paragraph(let id, _):
                return id
            }
        }
    }

    private var blocks: [Block] {
        var result: [Block] = []
        let lines = markdown.components(separatedBy: .newlines)
        var i = 0
        var nextID = 0

        while i < lines.count {
            let line = lines[i]
            let trimmed = line.trimmingCharacters(in: .whitespaces)

            if trimmed.isEmpty {
                i += 1
                continue
            }

            // Fenced code block
            if trimmed.hasPrefix("```") {
                let lang = String(trimmed.dropFirst(3)).trimmingCharacters(in: .whitespaces)
                var codeLines: [String] = []
                i += 1
                while i < lines.count && !lines[i].trimmingCharacters(in: .whitespaces).hasPrefix("```") {
                    codeLines.append(lines[i])
                    i += 1
                }
                i += 1
                result.append(.code(id: nextID, language: lang, content: codeLines.joined(separator: "\n")))
                nextID += 1
                continue
            }

            // Horizontal rule
            if trimmed == "---" || trimmed == "***" || trimmed == "___" {
                result.append(.divider(id: nextID))
                nextID += 1
                i += 1
                continue
            }

            // Heading
            if trimmed.hasPrefix("#") {
                let hashes = trimmed.prefix(while: { $0 == "#" }).count
                if hashes <= 6 && trimmed.dropFirst(hashes).first == " " {
                    let title = String(trimmed.dropFirst(hashes + 1)).trimmingCharacters(in: .whitespaces)
                    result.append(.heading(id: nextID, level: hashes, text: title))
                    nextID += 1
                    i += 1
                    continue
                }
            }

            // Blockquote
            if trimmed.hasPrefix(">") {
                var quoteLines: [String] = []
                while i < lines.count && lines[i].trimmingCharacters(in: .whitespaces).hasPrefix(">") {
                    let stripped = lines[i].trimmingCharacters(in: .whitespaces).dropFirst().trimmingCharacters(in: .whitespaces)
                    quoteLines.append(stripped)
                    i += 1
                }
                result.append(.quote(id: nextID, text: quoteLines.joined(separator: "\n")))
                nextID += 1
                continue
            }

            // Bullet list item
            if trimmed.hasPrefix("- ") || trimmed.hasPrefix("* ") || trimmed.hasPrefix("+ ") {
                result.append(.bullet(id: nextID, text: String(trimmed.dropFirst(2))))
                nextID += 1
                i += 1
                continue
            }

            // Paragraph
            var paraLines: [String] = [line]
            i += 1
            while i < lines.count {
                let peek = lines[i].trimmingCharacters(in: .whitespaces)
                if peek.isEmpty || peek.hasPrefix("#") || peek.hasPrefix("```") || peek.hasPrefix(">")
                    || peek.hasPrefix("- ") || peek.hasPrefix("* ") || peek == "---" {
                    break
                }
                paraLines.append(lines[i])
                i += 1
            }
            result.append(.paragraph(id: nextID, text: paraLines.joined(separator: "\n")))
            nextID += 1
        }
        return result
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 11) {
            ForEach(blocks) { block in
                switch block {
                case .heading(_, let level, let text):
                    inlineMarkdownText(text)
                        .font(.system(size: level == 1 ? 20 : (level == 2 ? 17 : 15), weight: .bold))
                        .padding(.top, level <= 2 ? 8 : 4)
                case .code(_, let lang, let content):
                    VStack(alignment: .leading, spacing: 4) {
                        if !lang.isEmpty {
                            Text(lang.uppercased())
                                .font(.system(size: 9.5, weight: .semibold, design: .monospaced))
                                .foregroundStyle(.tertiary)
                        }
                        ScrollView(.horizontal, showsIndicators: false) {
                            Text(content)
                                .font(.system(size: 12, design: .monospaced))
                                .textSelection(.enabled)
                        }
                    }
                    .padding(12)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color.primary.opacity(colorScheme == .dark ? 0.08 : 0.05), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                case .quote(_, let text):
                    HStack(spacing: 10) {
                        RoundedRectangle(cornerRadius: 2)
                            .fill(Color.accentColor.opacity(0.6))
                            .frame(width: 3)
                        inlineMarkdownText(text)
                            .font(.system(size: 13.5))
                            .foregroundStyle(.secondary)
                    }
                    .padding(.vertical, 2)
                case .bullet(_, let text):
                    HStack(alignment: .top, spacing: 8) {
                        Text("•")
                            .font(.system(size: 14, weight: .bold))
                            .foregroundStyle(.secondary)
                        inlineMarkdownText(text)
                            .font(.system(size: 13.5))
                            .lineSpacing(4)
                    }
                case .divider:
                    Divider().padding(.vertical, 4)
                case .paragraph(_, let text):
                    inlineMarkdownText(text)
                        .font(.system(size: 13.5))
                        .lineSpacing(5)
                }
            }
        }
        .textSelection(.enabled)
        .frame(maxWidth: .infinity, alignment: .leading)
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
