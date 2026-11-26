import Foundation

public enum MediaKind: String, Codable, CaseIterable, Hashable, Sendable {
    case image
    case animatedImage
    case video
    case webBookmark
    case document
    case designFile
    case audio
    case model3D

    public var localizedLabel: String {
        switch self {
        case .image: "图片"
        case .animatedImage: "动图"
        case .video: "视频"
        case .webBookmark: "网页"
        case .document: "文档"
        case .designFile: "设计文件"
        case .audio: "音频"
        case .model3D: "3D 模型"
        }
    }

    public static func detect(fileExtension ext: String, mimeType: String? = nil) -> MediaKind {
        let lower = ext.lowercased()
        switch lower {
        case "gif", "apng":
            return .animatedImage
        case "jpg", "jpeg", "png", "heic", "heif", "webp", "tiff", "tif", "bmp", "avif", "jxl":
            return .image
        case "mp4", "mov", "m4v", "webm", "mkv", "avi":
            return .video
        case "pdf", "md", "markdown", "txt", "rtf", "docx", "pptx", "key", "pages", "json", "yaml", "yml", "toml", "csv":
            return .document
        case "svg", "psd", "psb", "sketch", "fig", "ai", "eps", "xd", "afdesign", "afphoto":
            return .designFile
        case "mp3", "wav", "m4a", "aac", "flac", "ogg", "aiff", "aif", "opus", "caf", "alac", "wma", "m4b", "mid", "midi":
            return .audio
        case "usdz", "usda", "usdc", "obj", "stl", "scn", "dae", "gltf", "glb", "fbx", "ply", "3ds", "blend":
            return .model3D
        case "webloc", "url":
            return .webBookmark
        default:
            if let mime = mimeType?.lowercased() {
                if mime.hasPrefix("image/gif") { return .animatedImage }
                if mime.hasPrefix("image/svg") { return .designFile }
                if mime.hasPrefix("image/") { return .image }
                if mime.hasPrefix("video/") { return .video }
                if mime.hasPrefix("audio/") { return .audio }
                if mime.hasPrefix("model/") { return .model3D }
                if mime == "application/pdf" || mime.hasPrefix("text/") { return .document }
            }
            return .document
        }
    }
}

public enum SocialPlatform: String, Codable, CaseIterable, Hashable, Sendable {
    case x
    case threads
    case bluesky
    case xiaohongshu
    case pixiv
    case instagram

    public var displayName: String {
        switch self {
        case .x: "X"
        case .threads: "Threads"
        case .bluesky: "Bluesky"
        case .xiaohongshu: "小红书"
        case .pixiv: "Pixiv"
        case .instagram: "Instagram"
        }
    }

    public var postNoun: String {
        switch self {
        case .x: "推文"
        case .xiaohongshu: "笔记"
        case .pixiv: "作品"
        case .threads, .bluesky, .instagram: "贴文"
        }
    }

    public var postTypeLabel: String {
        "\(displayName) \(postNoun)"
    }

    public var openActionLabel: String {
        switch self {
        case .x: "在 X 打开"
        case .threads: "在 Threads 打开"
        case .bluesky: "在 Bluesky 打开"
        case .xiaohongshu: "在小红书打开"
        case .pixiv: "在 Pixiv 打开"
        case .instagram: "在 Instagram 打开"
        }
    }
}

public struct GitHubRepoMetadata: Codable, Hashable, Sendable {
    public var owner: String
    public var repo: String
    public var fullName: String
    public var ownerAvatarURL: String?
    public var description: String?
    public var stars: Int
    public var forks: Int
    public var watchers: Int?
    public var language: String?
    public var licenseName: String?
    public var topics: [String]
    public var defaultBranch: String
    public var homepageURL: String?
    public var openGraphImageURL: String?
    public var readmeMarkdown: String?
    public var fetchedAt: Date

    public init(
        owner: String,
        repo: String,
        fullName: String? = nil,
        ownerAvatarURL: String? = nil,
        description: String? = nil,
        stars: Int = 0,
        forks: Int = 0,
        watchers: Int? = nil,
        language: String? = nil,
        licenseName: String? = nil,
        topics: [String] = [],
        defaultBranch: String = "main",
        homepageURL: String? = nil,
        openGraphImageURL: String? = nil,
        readmeMarkdown: String? = nil,
        fetchedAt: Date = Date()
    ) {
        self.owner = owner
        self.repo = repo
        self.fullName = fullName ?? "\(owner)/\(repo)"
        self.ownerAvatarURL = ownerAvatarURL
        self.description = description
        self.stars = stars
        self.forks = forks
        self.watchers = watchers
        self.language = language
        self.licenseName = licenseName
        self.topics = topics
        self.defaultBranch = defaultBranch
        self.homepageURL = homepageURL
        self.openGraphImageURL = openGraphImageURL ?? "https://opengraph.githubassets.com/1/\(owner)/\(repo)"
        self.readmeMarkdown = readmeMarkdown
        self.fetchedAt = fetchedAt
    }
}

public struct SocialMediaAttachment: Codable, Hashable, Sendable, Identifiable {
    public enum Kind: String, Codable, Hashable, Sendable {
        case photo
        case video
        case gif

        public var localizedLabel: String {
            switch self {
            case .photo: "图片"
            case .video: "视频"
            case .gif: "动图"
            }
        }
    }

    public let id: String
    public let kind: Kind
    public let url: String
    public let thumbnailURL: String?

    public init(id: String? = nil, kind: Kind, url: String, thumbnailURL: String? = nil) {
        self.id = id ?? "\(kind.rawValue):\(url)"
        self.kind = kind
        self.url = url
        self.thumbnailURL = thumbnailURL
    }
}

public struct SocialPostMetadata: Codable, Hashable, Sendable {
    public var platform: SocialPlatform
    public var authorName: String
    public var authorHandle: String
    public var authorAvatarURL: String?
    public var publishedAtText: String?
    public var bodyText: String
    public var quotedAuthor: String?
    public var quotedText: String?
    public var articleTitle: String?
    public var mediaURLs: [String]
    public var mediaThumbnailURLs: [String]
    public var attachments: [SocialMediaAttachment]
    public var hasVideo: Bool
    public var videoURL: String?
    public var replyCount: Int?
    public var repostCount: Int?
    public var likeCount: Int?
    public var viewCount: Int?
    public var originalURL: String
    public var mediaFetchFailed: Bool

    public init(
        platform: SocialPlatform,
        authorName: String,
        authorHandle: String,
        authorAvatarURL: String? = nil,
        publishedAtText: String? = nil,
        bodyText: String,
        quotedAuthor: String? = nil,
        quotedText: String? = nil,
        articleTitle: String? = nil,
        mediaURLs: [String] = [],
        mediaThumbnailURLs: [String] = [],
        attachments: [SocialMediaAttachment] = [],
        hasVideo: Bool = false,
        videoURL: String? = nil,
        replyCount: Int? = nil,
        repostCount: Int? = nil,
        likeCount: Int? = nil,
        viewCount: Int? = nil,
        originalURL: String,
        mediaFetchFailed: Bool = false
    ) {
        self.platform = platform
        self.authorName = authorName
        self.authorHandle = authorHandle
        self.authorAvatarURL = authorAvatarURL
        self.publishedAtText = publishedAtText
        self.bodyText = bodyText
        self.quotedAuthor = quotedAuthor
        self.quotedText = quotedText
        self.articleTitle = articleTitle
        self.mediaURLs = mediaURLs
        self.mediaThumbnailURLs = mediaThumbnailURLs
        self.attachments = attachments
        self.hasVideo = hasVideo
        self.videoURL = videoURL
        self.replyCount = replyCount
        self.repostCount = repostCount
        self.likeCount = likeCount
        self.viewCount = viewCount
        self.originalURL = originalURL
        self.mediaFetchFailed = mediaFetchFailed
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.platform = try c.decode(SocialPlatform.self, forKey: .platform)
        self.authorName = try c.decode(String.self, forKey: .authorName)
        self.authorHandle = try c.decode(String.self, forKey: .authorHandle)
        self.authorAvatarURL = try c.decodeIfPresent(String.self, forKey: .authorAvatarURL)
        self.publishedAtText = try c.decodeIfPresent(String.self, forKey: .publishedAtText)
        self.bodyText = try c.decode(String.self, forKey: .bodyText)
        self.quotedAuthor = try c.decodeIfPresent(String.self, forKey: .quotedAuthor)
        self.quotedText = try c.decodeIfPresent(String.self, forKey: .quotedText)
        self.articleTitle = try c.decodeIfPresent(String.self, forKey: .articleTitle)
        self.mediaURLs = try c.decodeIfPresent([String].self, forKey: .mediaURLs) ?? []
        self.mediaThumbnailURLs = try c.decodeIfPresent([String].self, forKey: .mediaThumbnailURLs) ?? []
        self.attachments = try c.decodeIfPresent([SocialMediaAttachment].self, forKey: .attachments) ?? []
        self.hasVideo = try c.decodeIfPresent(Bool.self, forKey: .hasVideo) ?? false
        self.videoURL = try c.decodeIfPresent(String.self, forKey: .videoURL)
        self.replyCount = try c.decodeIfPresent(Int.self, forKey: .replyCount)
        self.repostCount = try c.decodeIfPresent(Int.self, forKey: .repostCount)
        self.likeCount = try c.decodeIfPresent(Int.self, forKey: .likeCount)
        self.viewCount = try c.decodeIfPresent(Int.self, forKey: .viewCount)
        self.originalURL = try c.decode(String.self, forKey: .originalURL)
        self.mediaFetchFailed = try c.decodeIfPresent(Bool.self, forKey: .mediaFetchFailed) ?? false
    }

    /// Displayable handle subtitle (omits internal 24-hex Xiaohongshu user IDs for cleaner typography).
    public var displayHandleLine: String? {
        let trimmed = authorHandle.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        if platform == .xiaohongshu {
            let isInternalHex = trimmed.count == 24 && trimmed.allSatisfy(\.isHexDigit)
            if isInternalHex || trimmed.lowercased() == "xiaohongshu" || trimmed == authorName {
                return nil
            }
            return "小红书号 \(trimmed)"
        }
        return "@\(trimmed)"
    }

    /// Unified typed attachment list across both newly saved posts and legacy saved social posts.
    public var effectiveAttachments: [SocialMediaAttachment] {
        if !attachments.isEmpty { return attachments }
        var items: [SocialMediaAttachment] = []
        var seen = Set<String>()
        if let vURL = videoURL, !vURL.isEmpty, seen.insert(vURL).inserted {
            let thumb = mediaThumbnailURLs.first
            items.append(SocialMediaAttachment(kind: .video, url: vURL, thumbnailURL: thumb))
        }
        for (idx, urlStr) in mediaURLs.enumerated() where seen.insert(urlStr).inserted {
            let lower = urlStr.lowercased()
            let isVid = lower.contains(".mp4") || lower.contains(".m3u8") || lower.contains("/ext_tw_video/") || lower.contains("/amplify_video/") || lower.contains("video.twimg.com")
            let thumb = idx < mediaThumbnailURLs.count ? mediaThumbnailURLs[idx] : nil
            items.append(SocialMediaAttachment(kind: isVid ? .video : .photo, url: urlStr, thumbnailURL: thumb))
        }
        return items
    }
}

public struct PhotoExifMetadata: Codable, Hashable, Sendable {
    public var cameraMake: String?
    public var cameraModel: String?
    public var lensModel: String?
    public var capturedAt: String?
    public var exposureTime: String?
    public var fNumber: Double?
    public var iso: Int?
    public var focalLengthMM: Double?
    public var focalLength35mm: Int?
    public var exposureBiasEV: Double?
    public var meteringMode: String?
    public var flashFired: Bool?
    public var whiteBalance: String?
    public var colorProfile: String?
    public var bitDepth: Int?
    public var dpiWidth: Int?
    public var software: String?
    public var artist: String?
    public var copyright: String?
    public var latitude: Double?
    public var longitude: Double?
    public var altitudeMeters: Double?

    public init(
        cameraMake: String? = nil,
        cameraModel: String? = nil,
        lensModel: String? = nil,
        capturedAt: String? = nil,
        exposureTime: String? = nil,
        fNumber: Double? = nil,
        iso: Int? = nil,
        focalLengthMM: Double? = nil,
        focalLength35mm: Int? = nil,
        exposureBiasEV: Double? = nil,
        meteringMode: String? = nil,
        flashFired: Bool? = nil,
        whiteBalance: String? = nil,
        colorProfile: String? = nil,
        bitDepth: Int? = nil,
        dpiWidth: Int? = nil,
        software: String? = nil,
        artist: String? = nil,
        copyright: String? = nil,
        latitude: Double? = nil,
        longitude: Double? = nil,
        altitudeMeters: Double? = nil
    ) {
        self.cameraMake = cameraMake
        self.cameraModel = cameraModel
        self.lensModel = lensModel
        self.capturedAt = capturedAt
        self.exposureTime = exposureTime
        self.fNumber = fNumber
        self.iso = iso
        self.focalLengthMM = focalLengthMM
        self.focalLength35mm = focalLength35mm
        self.exposureBiasEV = exposureBiasEV
        self.meteringMode = meteringMode
        self.flashFired = flashFired
        self.whiteBalance = whiteBalance
        self.colorProfile = colorProfile
        self.bitDepth = bitDepth
        self.dpiWidth = dpiWidth
        self.software = software
        self.artist = artist
        self.copyright = copyright
        self.latitude = latitude
        self.longitude = longitude
        self.altitudeMeters = altitudeMeters
    }

    public var cameraDisplayName: String? {
        let make = cameraMake?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let model = cameraModel?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if make.isEmpty && model.isEmpty { return nil }
        if model.isEmpty { return make }
        if make.isEmpty { return model }
        if model.lowercased().hasPrefix(make.lowercased()) {
            return model
        }
        return "\(make) \(model)"
    }

    public var formattedAperture: String? {
        guard let fNumber, fNumber.isFinite, fNumber > 0, fNumber < 10_000 else { return nil }
        let rounded = (fNumber * 10).rounded() / 10
        if abs(rounded - rounded.rounded()) < 0.01 {
            return "f/\(Int(rounded.rounded()))"
        }
        return String(format: "f/%.1f", rounded)
    }

    public var formattedFocalLength: String? {
        guard let focalLengthMM, focalLengthMM.isFinite, focalLengthMM > 0, focalLengthMM < 1_000_000 else { return nil }
        let base: String
        if abs(focalLengthMM - focalLengthMM.rounded()) < 0.05 {
            base = "\(Int(focalLengthMM.rounded()))mm"
        } else {
            base = String(format: "%.1fmm", focalLengthMM)
        }
        if let eq = focalLength35mm, eq > 0, abs(Double(eq) - focalLengthMM) >= 1.5 {
            return "\(base)（等效 \(eq)mm）"
        }
        return base
    }

    public var exposureSummary: String? {
        var parts: [String] = []
        if let focal = focalLengthMM, focal.isFinite, focal > 0, focal < 1_000_000 {
            if abs(focal - focal.rounded()) < 0.05 {
                parts.append("\(Int(focal.rounded()))mm")
            } else {
                parts.append(String(format: "%.1fmm", focal))
            }
        }
        if let aperture = formattedAperture { parts.append(aperture) }
        if let exposureTime, !exposureTime.isEmpty { parts.append(exposureTime) }
        if let iso, iso > 0 { parts.append("ISO \(iso)") }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    public var hasMeaningfulCameraExif: Bool {
        cameraDisplayName != nil || lensModel != nil || capturedAt != nil || exposureTime != nil
            || fNumber != nil || iso != nil || focalLengthMM != nil || latitude != nil
            || software != nil || artist != nil || copyright != nil
    }

    public var isEmpty: Bool {
        !hasMeaningfulCameraExif && colorProfile == nil && bitDepth == nil && dpiWidth == nil
    }
}

public struct AIGenerationMetadata: Codable, Hashable, Sendable {
    public var generator: String?
    public var prompt: String?
    public var negativePrompt: String?
    public var modelName: String?
    public var modelHash: String?
    public var sampler: String?
    public var scheduler: String?
    public var steps: Int?
    public var cfgScale: Double?
    public var seed: String?
    public var sizeText: String?
    public var clipSkip: Int?
    public var loras: [String]
    public var extraParameters: [String: String]
    public var rawParameters: String?

    public init(
        generator: String? = nil,
        prompt: String? = nil,
        negativePrompt: String? = nil,
        modelName: String? = nil,
        modelHash: String? = nil,
        sampler: String? = nil,
        scheduler: String? = nil,
        steps: Int? = nil,
        cfgScale: Double? = nil,
        seed: String? = nil,
        sizeText: String? = nil,
        clipSkip: Int? = nil,
        loras: [String] = [],
        extraParameters: [String: String] = [:],
        rawParameters: String? = nil
    ) {
        self.generator = generator
        self.prompt = prompt
        self.negativePrompt = negativePrompt
        self.modelName = modelName
        self.modelHash = modelHash
        self.sampler = sampler
        self.scheduler = scheduler
        self.steps = steps
        self.cfgScale = cfgScale
        self.seed = seed
        self.sizeText = sizeText
        self.clipSkip = clipSkip
        self.loras = loras
        self.extraParameters = extraParameters
        self.rawParameters = rawParameters
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.generator = try c.decodeIfPresent(String.self, forKey: .generator)
        self.prompt = try c.decodeIfPresent(String.self, forKey: .prompt)
        self.negativePrompt = try c.decodeIfPresent(String.self, forKey: .negativePrompt)
        self.modelName = try c.decodeIfPresent(String.self, forKey: .modelName)
        self.modelHash = try c.decodeIfPresent(String.self, forKey: .modelHash)
        self.sampler = try c.decodeIfPresent(String.self, forKey: .sampler)
        self.scheduler = try c.decodeIfPresent(String.self, forKey: .scheduler)
        self.steps = try c.decodeIfPresent(Int.self, forKey: .steps)
        self.cfgScale = try c.decodeIfPresent(Double.self, forKey: .cfgScale)
        self.seed = try c.decodeIfPresent(String.self, forKey: .seed)
        self.sizeText = try c.decodeIfPresent(String.self, forKey: .sizeText)
        self.clipSkip = try c.decodeIfPresent(Int.self, forKey: .clipSkip)
        self.loras = try c.decodeIfPresent([String].self, forKey: .loras) ?? []
        self.extraParameters = try c.decodeIfPresent([String: String].self, forKey: .extraParameters) ?? [:]
        self.rawParameters = try c.decodeIfPresent(String.self, forKey: .rawParameters)
    }

    public var isEmpty: Bool {
        let hasPrompt = !(prompt?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true)
        let hasNeg = !(negativePrompt?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true)
        let hasRaw = !(rawParameters?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true)
        return !hasPrompt && !hasNeg && modelName == nil && sampler == nil && steps == nil && seed == nil && !hasRaw
    }
}

private final class ImmutableMetadataBox<Value: Hashable & Sendable>: Hashable, Sendable {
    let value: Value

    init(_ value: Value) {
        self.value = value
    }

    static func == (lhs: ImmutableMetadataBox<Value>, rhs: ImmutableMetadataBox<Value>) -> Bool {
        if lhs === rhs { return true }
        return lhs.value == rhs.value
    }

    func hash(into hasher: inout Hasher) {
        hasher.combine(value)
    }
}

public struct AssetRichMetadata: Codable, Hashable, Sendable {
    private final class Storage: Hashable, Sendable {
        static let empty = Storage(
            githubRepo: nil,
            socialPost: nil,
            photoExif: nil,
            aiGeneration: nil,
            textExcerpt: nil,
            isMarkdown: false,
            model3DFormat: nil
        )

        let githubRepo: ImmutableMetadataBox<GitHubRepoMetadata>?
        let socialPost: ImmutableMetadataBox<SocialPostMetadata>?
        let photoExif: ImmutableMetadataBox<PhotoExifMetadata>?
        let aiGeneration: ImmutableMetadataBox<AIGenerationMetadata>?
        let textExcerpt: String?
        let isMarkdown: Bool
        let model3DFormat: String?

        init(
            githubRepo: ImmutableMetadataBox<GitHubRepoMetadata>?,
            socialPost: ImmutableMetadataBox<SocialPostMetadata>?,
            photoExif: ImmutableMetadataBox<PhotoExifMetadata>?,
            aiGeneration: ImmutableMetadataBox<AIGenerationMetadata>?,
            textExcerpt: String?,
            isMarkdown: Bool,
            model3DFormat: String?
        ) {
            self.githubRepo = githubRepo
            self.socialPost = socialPost
            self.photoExif = photoExif
            self.aiGeneration = aiGeneration
            self.textExcerpt = textExcerpt
            self.isMarkdown = isMarkdown
            self.model3DFormat = model3DFormat
        }

        static func == (lhs: Storage, rhs: Storage) -> Bool {
            if lhs === rhs { return true }
            return lhs.isMarkdown == rhs.isMarkdown
                && lhs.textExcerpt == rhs.textExcerpt
                && lhs.model3DFormat == rhs.model3DFormat
                && lhs.githubRepo == rhs.githubRepo
                && lhs.socialPost == rhs.socialPost
                && lhs.photoExif == rhs.photoExif
                && lhs.aiGeneration == rhs.aiGeneration
        }

        func hash(into hasher: inout Hasher) {
            hasher.combine(githubRepo)
            hasher.combine(socialPost)
            hasher.combine(photoExif)
            hasher.combine(aiGeneration)
            hasher.combine(textExcerpt)
            hasher.combine(isMarkdown)
            hasher.combine(model3DFormat)
        }
    }

    private enum CodingKeys: String, CodingKey {
        case githubRepo
        case socialPost
        case photoExif
        case aiGeneration
        case textExcerpt
        case isMarkdown
        case model3DFormat
    }

    private var storage: Storage

    public var githubRepo: GitHubRepoMetadata? {
        get { storage.githubRepo?.value }
        set {
            storage = Storage(
                githubRepo: newValue.map(ImmutableMetadataBox.init),
                socialPost: storage.socialPost,
                photoExif: storage.photoExif,
                aiGeneration: storage.aiGeneration,
                textExcerpt: storage.textExcerpt,
                isMarkdown: storage.isMarkdown,
                model3DFormat: storage.model3DFormat
            )
        }
    }

    public var socialPost: SocialPostMetadata? {
        get { storage.socialPost?.value }
        set {
            storage = Storage(
                githubRepo: storage.githubRepo,
                socialPost: newValue.map(ImmutableMetadataBox.init),
                photoExif: storage.photoExif,
                aiGeneration: storage.aiGeneration,
                textExcerpt: storage.textExcerpt,
                isMarkdown: storage.isMarkdown,
                model3DFormat: storage.model3DFormat
            )
        }
    }

    public var photoExif: PhotoExifMetadata? {
        get { storage.photoExif?.value }
        set {
            storage = Storage(
                githubRepo: storage.githubRepo,
                socialPost: storage.socialPost,
                photoExif: newValue.map(ImmutableMetadataBox.init),
                aiGeneration: storage.aiGeneration,
                textExcerpt: storage.textExcerpt,
                isMarkdown: storage.isMarkdown,
                model3DFormat: storage.model3DFormat
            )
        }
    }

    public var aiGeneration: AIGenerationMetadata? {
        get { storage.aiGeneration?.value }
        set {
            storage = Storage(
                githubRepo: storage.githubRepo,
                socialPost: storage.socialPost,
                photoExif: storage.photoExif,
                aiGeneration: newValue.map(ImmutableMetadataBox.init),
                textExcerpt: storage.textExcerpt,
                isMarkdown: storage.isMarkdown,
                model3DFormat: storage.model3DFormat
            )
        }
    }

    public var textExcerpt: String? {
        get { storage.textExcerpt }
        set {
            storage = Storage(
                githubRepo: storage.githubRepo,
                socialPost: storage.socialPost,
                photoExif: storage.photoExif,
                aiGeneration: storage.aiGeneration,
                textExcerpt: newValue,
                isMarkdown: storage.isMarkdown,
                model3DFormat: storage.model3DFormat
            )
        }
    }

    public var isMarkdown: Bool {
        get { storage.isMarkdown }
        set {
            storage = Storage(
                githubRepo: storage.githubRepo,
                socialPost: storage.socialPost,
                photoExif: storage.photoExif,
                aiGeneration: storage.aiGeneration,
                textExcerpt: storage.textExcerpt,
                isMarkdown: newValue,
                model3DFormat: storage.model3DFormat
            )
        }
    }

    public var model3DFormat: String? {
        get { storage.model3DFormat }
        set {
            storage = Storage(
                githubRepo: storage.githubRepo,
                socialPost: storage.socialPost,
                photoExif: storage.photoExif,
                aiGeneration: storage.aiGeneration,
                textExcerpt: storage.textExcerpt,
                isMarkdown: storage.isMarkdown,
                model3DFormat: newValue
            )
        }
    }

    public init(
        githubRepo: GitHubRepoMetadata? = nil,
        socialPost: SocialPostMetadata? = nil,
        photoExif: PhotoExifMetadata? = nil,
        aiGeneration: AIGenerationMetadata? = nil,
        textExcerpt: String? = nil,
        isMarkdown: Bool = false,
        model3DFormat: String? = nil
    ) {
        if githubRepo == nil, socialPost == nil, photoExif == nil, aiGeneration == nil,
           textExcerpt == nil, !isMarkdown, model3DFormat == nil {
            self.storage = .empty
        } else {
            self.storage = Storage(
                githubRepo: githubRepo.map(ImmutableMetadataBox.init),
                socialPost: socialPost.map(ImmutableMetadataBox.init),
                photoExif: photoExif.map(ImmutableMetadataBox.init),
                aiGeneration: aiGeneration.map(ImmutableMetadataBox.init),
                textExcerpt: textExcerpt,
                isMarkdown: isMarkdown,
                model3DFormat: model3DFormat
            )
        }
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let githubRepo = try container.decodeIfPresent(GitHubRepoMetadata.self, forKey: .githubRepo)
        let socialPost = try container.decodeIfPresent(SocialPostMetadata.self, forKey: .socialPost)
        let photoExif = try container.decodeIfPresent(PhotoExifMetadata.self, forKey: .photoExif)
        let aiGeneration = try container.decodeIfPresent(AIGenerationMetadata.self, forKey: .aiGeneration)
        let textExcerpt = try container.decodeIfPresent(String.self, forKey: .textExcerpt)
        let isMarkdown = try container.decodeIfPresent(Bool.self, forKey: .isMarkdown) ?? false
        let model3DFormat = try container.decodeIfPresent(String.self, forKey: .model3DFormat)
        self.init(
            githubRepo: githubRepo,
            socialPost: socialPost,
            photoExif: photoExif,
            aiGeneration: aiGeneration,
            textExcerpt: textExcerpt,
            isMarkdown: isMarkdown,
            model3DFormat: model3DFormat
        )
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encodeIfPresent(storage.githubRepo?.value, forKey: .githubRepo)
        try container.encodeIfPresent(storage.socialPost?.value, forKey: .socialPost)
        try container.encodeIfPresent(storage.photoExif?.value, forKey: .photoExif)
        try container.encodeIfPresent(storage.aiGeneration?.value, forKey: .aiGeneration)
        try container.encodeIfPresent(storage.textExcerpt, forKey: .textExcerpt)
        try container.encode(storage.isMarkdown, forKey: .isMarkdown)
        try container.encodeIfPresent(storage.model3DFormat, forKey: .model3DFormat)
    }
}

public enum AspectShape: String, Codable, CaseIterable, Hashable, Sendable {
    case landscape
    case portrait
    case square
    case ultrawide

    public var localizedLabel: String {
        switch self {
        case .landscape: "横图"
        case .portrait: "竖图"
        case .square: "方图"
        case .ultrawide: "超宽"
        }
    }

    public static func classify(width: Int, height: Int) -> AspectShape {
        guard width > 0, height > 0 else { return .square }
        let ratio = Double(width) / Double(height)
        if ratio >= 2.0 { return .ultrawide }
        if ratio >= 1.15 { return .landscape }
        if ratio <= 0.87 { return .portrait }
        return .square
    }
}

/// Perceptually uniform CIELAB swatch paired with sRGB hex.
public struct LabColor: Codable, Hashable, Sendable {
    public var hex: String
    public var l: Double
    public var a: Double
    public var b: Double
    public var proportion: Double

    public init(hex: String, l: Double, a: Double, b: Double, proportion: Double = 1.0) {
        self.hex = hex
        self.l = l
        self.a = a
        self.b = b
        self.proportion = proportion
    }

    /// CIE76 Euclidean distance in CIELAB space (fast perceptual proximity).
    public func deltaE(to other: LabColor) -> Double {
        deltaESquared(to: other).squareRoot()
    }

    /// Squared CIE76 distance in CIELAB space (avoids `sqrt` in threshold comparisons).
    @inline(__always)
    func deltaESquared(to other: LabColor) -> Double {
        let dl = l - other.l
        let da = a - other.a
        let db = b - other.b
        return dl * dl + da * da + db * db
    }

    /// Construct a LabColor from an sRGB hex string such as "#3B82F6" or "3B82F6".
    public static func fromHex(_ hexString: String, proportion: Double = 1.0) -> LabColor {
        let trimmed = hexString.trimmingCharacters(in: .whitespacesAndNewlines)
        var value: UInt32 = 0
        var digits = 0
        var hexBytes: (UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8) = (0x23, 0, 0, 0, 0, 0, 0)
        var valid = true
        for byte in trimmed.utf8 {
            if byte == 0x23 {
                continue
            }
            let nibble: UInt32
            let upperByte: UInt8
            if byte >= 0x30 && byte <= 0x39 {
                nibble = UInt32(byte - 0x30)
                upperByte = byte
            } else if byte >= 0x41 && byte <= 0x46 {
                nibble = UInt32(byte - 0x37)
                upperByte = byte
            } else if byte >= 0x61 && byte <= 0x66 {
                nibble = UInt32(byte - 0x57)
                upperByte = byte - 32
            } else {
                valid = false
                break
            }
            if digits >= 6 {
                valid = false
                break
            }
            value = (value << 4) | nibble
            switch digits {
            case 0: hexBytes.1 = upperByte
            case 1: hexBytes.2 = upperByte
            case 2: hexBytes.3 = upperByte
            case 3: hexBytes.4 = upperByte
            case 4: hexBytes.5 = upperByte
            case 5: hexBytes.6 = upperByte
            default: break
            }
            digits += 1
        }
        guard valid && digits == 6 else {
            return LabColor(hex: "#808080", l: 53.59, a: 0, b: 0, proportion: proportion)
        }
        let r = Double((value >> 16) & 0xFF) / 255.0
        let g = Double((value >> 8) & 0xFF) / 255.0
        let b = Double(value & 0xFF) / 255.0
        let (lVal, aVal, bVal) = Self.sRGBToLab(r: r, g: g, b: b)
        let formattedHex = withUnsafeBytes(of: hexBytes) { raw in
            String(decoding: raw, as: UTF8.self)
        }
        return LabColor(hex: formattedHex, l: lVal, a: aVal, b: bVal, proportion: proportion)
    }

    public static func sRGBToLab(r: Double, g: Double, b: Double) -> (Double, Double, Double) {
        func linearize(_ c: Double) -> Double {
            c <= 0.04045 ? (c / 12.92) : pow((c + 0.055) / 1.055, 2.4)
        }
        let rl = linearize(r)
        let gl = linearize(g)
        let bl = linearize(b)

        let x = (rl * 0.4124564 + gl * 0.3575761 + bl * 0.1804375) / 0.95047
        let y = (rl * 0.2126729 + gl * 0.7151522 + bl * 0.0721750) / 1.00000
        let z = (rl * 0.0193339 + gl * 0.1191920 + bl * 0.9503041) / 1.08883

        func f(_ t: Double) -> Double {
            t > 0.008856 ? cbrt(t) : (7.787 * t + 16.0 / 116.0)
        }
        let fx = f(x)
        let fy = f(y)
        let fz = f(z)

        let lVal = (116.0 * fy) - 16.0
        let aVal = 500.0 * (fx - fy)
        let bVal = 200.0 * (fy - fz)
        return (lVal, aVal, bVal)
    }
}

public struct AssetRecord: Codable, Hashable, Identifiable, Sendable {
    public let id: UUID
    public var title: String
    public var fileName: String
    public var folderID: UUID?
    public var driveFileID: String?
    public var contentHash: String
    public var mediaKind: MediaKind
    public var mimeType: String
    public var fileSizeBytes: Int64
    public var pixelWidth: Int
    public var pixelHeight: Int
    public var durationSeconds: Double?
    public var waveformPeaks: [Float]
    public var sourceURL: String?
    public var sourceDomain: String?
    public var notes: String
    public var tags: [String]
    public var suggestedTags: [String]
    public var aiDescription: String?
    public var ocrText: String?
    public var dominantColors: [LabColor]
    public var rating: Int
    public var pinnedOffline: Bool
    public var isLocalOriginalCached: Bool
    public var isTrashed: Bool
    public var createdAt: Date
    public var updatedAt: Date
    public var updatedHLC: Int64
    public var lastOpenedAt: Date?
    public var richMetadata: AssetRichMetadata?

    public var aspectRatio: Double {
        guard pixelWidth > 0, pixelHeight > 0 else { return 1.0 }
        return Double(pixelWidth) / Double(pixelHeight)
    }

    public var aspectShape: AspectShape {
        AspectShape.classify(width: pixelWidth, height: pixelHeight)
    }

    public var isInInbox: Bool {
        folderID == nil && !isTrashed
    }

    public var recentActivityDate: Date {
        max(createdAt, lastOpenedAt ?? .distantPast)
    }

    public var isGitHubRepo: Bool {
        richMetadata?.githubRepo != nil
    }

    public var isSocialPost: Bool {
        richMetadata?.socialPost != nil
    }

    /// Validated `http`/`https` destination URL stored on a web bookmark asset.
    public var externalWebURL: URL? {
        guard let raw = sourceURL?.trimmingCharacters(in: .whitespacesAndNewlines),
              !raw.isEmpty,
              let url = URL(string: raw),
              let scheme = url.scheme?.lowercased(),
              scheme == "http" || scheme == "https",
              url.host() != nil else {
            return nil
        }
        return url
    }

    /// Generic web link bookmark (any URL outside in-app GitHub repository / social post rich viewers).
    /// Opening such assets launches the user's default web browser directly.
    public var isExternalWebLink: Bool {
        mediaKind == .webBookmark && !isGitHubRepo && !isSocialPost && externalWebURL != nil
    }

    public var displayTypeLabel: String {
        if let post = richMetadata?.socialPost {
            return post.platform.postTypeLabel
        }
        if isGitHubRepo {
            return "GitHub 仓库"
        }
        return mediaKind.localizedLabel
    }

    public var isMarkdownDocument: Bool {
        if richMetadata?.isMarkdown == true { return true }
        let ext = (fileName as NSString).pathExtension.lowercased()
        return mediaKind == .document && (ext == "md" || ext == "markdown")
    }

    public var isPlainTextDocument: Bool {
        let ext = (fileName as NSString).pathExtension.lowercased()
        return mediaKind == .document && ["txt", "md", "markdown", "json", "yaml", "yml", "toml", "csv", "rtf"].contains(ext)
    }

    public init(
        id: UUID = UUID(),
        title: String,
        fileName: String,
        folderID: UUID? = nil,
        driveFileID: String? = nil,
        contentHash: String = "",
        mediaKind: MediaKind = .image,
        mimeType: String = "image/jpeg",
        fileSizeBytes: Int64 = 0,
        pixelWidth: Int = 1200,
        pixelHeight: Int = 900,
        durationSeconds: Double? = nil,
        waveformPeaks: [Float] = [],
        sourceURL: String? = nil,
        sourceDomain: String? = nil,
        notes: String = "",
        tags: [String] = [],
        suggestedTags: [String] = [],
        aiDescription: String? = nil,
        ocrText: String? = nil,
        dominantColors: [LabColor] = [],
        rating: Int = 0,
        pinnedOffline: Bool = false,
        isLocalOriginalCached: Bool = false,
        isTrashed: Bool = false,
        createdAt: Date = Date(),
        updatedAt: Date = Date(),
        updatedHLC: Int64 = 0,
        lastOpenedAt: Date? = nil,
        richMetadata: AssetRichMetadata? = nil
    ) {
        self.id = id
        self.title = title
        self.fileName = fileName
        self.folderID = folderID
        self.driveFileID = driveFileID
        self.contentHash = contentHash
        self.mediaKind = mediaKind
        self.mimeType = mimeType
        self.fileSizeBytes = fileSizeBytes
        self.pixelWidth = pixelWidth
        self.pixelHeight = pixelHeight
        self.durationSeconds = durationSeconds
        self.waveformPeaks = waveformPeaks
        self.sourceURL = sourceURL
        self.sourceDomain = sourceDomain
        self.notes = notes
        self.tags = tags
        self.suggestedTags = suggestedTags
        self.aiDescription = aiDescription
        self.ocrText = ocrText
        self.dominantColors = dominantColors
        self.rating = rating
        self.pinnedOffline = pinnedOffline
        self.isLocalOriginalCached = isLocalOriginalCached
        self.isTrashed = isTrashed
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.updatedHLC = updatedHLC
        self.lastOpenedAt = lastOpenedAt
        self.richMetadata = richMetadata
    }
}

public struct FolderRecord: Codable, Hashable, Identifiable, Sendable {
    public let id: UUID
    public var name: String
    public var parentID: UUID?
    public var driveFolderID: String?
    public var colorHex: String?
    public var customSymbol: String?
    public var sortOrder: Int
    public var assetCount: Int
    public var createdAt: Date
    public var updatedAt: Date

    public init(
        id: UUID = UUID(),
        name: String,
        parentID: UUID? = nil,
        driveFolderID: String? = nil,
        colorHex: String? = nil,
        customSymbol: String? = nil,
        sortOrder: Int = 0,
        assetCount: Int = 0,
        createdAt: Date = Date(),
        updatedAt: Date = Date()
    ) {
        self.id = id
        self.name = name
        self.parentID = parentID
        self.driveFolderID = driveFolderID
        self.colorHex = colorHex
        self.customSymbol = customSymbol
        self.sortOrder = sortOrder
        self.assetCount = assetCount
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }
}

/// Cycle-safe, orphan-tolerant hierarchical tree node for `FolderRecord`,
/// shared across SwiftUI menus, AppKit `NSMenu`s, sidebar trees, and folder pickers.
public nonisolated struct FolderHierarchyNode: Hashable, Identifiable, Sendable {
    public let folder: FolderRecord
    public let depth: Int
    public let children: [FolderHierarchyNode]

    public var id: UUID { folder.id }
    public var hasChildren: Bool { !children.isEmpty }

    public init(folder: FolderRecord, depth: Int = 0, children: [FolderHierarchyNode] = []) {
        self.folder = folder
        self.depth = depth
        self.children = children
    }

    public static func sortedSiblings(_ items: [FolderRecord]) -> [FolderRecord] {
        items.sorted { lhs, rhs in
            if lhs.sortOrder != rhs.sortOrder { return lhs.sortOrder < rhs.sortOrder }
            let cmp = lhs.name.localizedCaseInsensitiveCompare(rhs.name)
            if cmp != .orderedSame { return cmp == .orderedAscending }
            return lhs.id.uuidString < rhs.id.uuidString
        }
    }

    public static func buildTree(from folders: [FolderRecord]) -> [FolderHierarchyNode] {
        let byParent = Dictionary(grouping: folders) { $0.parentID }
        let knownIDs = Set(folders.map(\.id))
        var visited = Set<UUID>()

        func makeNodes(for records: [FolderRecord], depth: Int) -> [FolderHierarchyNode] {
            var nodes: [FolderHierarchyNode] = []
            for folder in sortedSiblings(records) {
                guard visited.insert(folder.id).inserted else { continue }
                let childNodes = makeNodes(for: byParent[folder.id] ?? [], depth: depth + 1)
                nodes.append(FolderHierarchyNode(folder: folder, depth: depth, children: childNodes))
            }
            return nodes
        }

        let roots = folders.filter { folder in
            guard let pid = folder.parentID else { return true }
            return !knownIDs.contains(pid)
        }
        var forest = makeNodes(for: roots, depth: 0)

        let remaining = folders.filter { !visited.contains($0.id) }
        if !remaining.isEmpty {
            forest.append(contentsOf: makeNodes(for: remaining, depth: 0))
        }
        return forest
    }

    public static func flattened(from folders: [FolderRecord]) -> [FolderHierarchyNode] {
        func appendSubtree(_ nodes: [FolderHierarchyNode], into out: inout [FolderHierarchyNode]) {
            for node in nodes {
                out.append(node)
                appendSubtree(node.children, into: &out)
            }
        }
        var result: [FolderHierarchyNode] = []
        appendSubtree(buildTree(from: folders), into: &result)
        return result
    }

    public func contains(folderID: UUID?) -> Bool {
        guard let folderID else { return false }
        if folder.id == folderID { return true }
        return children.contains { $0.contains(folderID: folderID) }
    }
}

/// Ordered sections of the Single-Asset Inspector info tab, supporting persistent user drag-to-reorder.
public nonisolated enum InspectorInfoSection: String, CaseIterable, Codable, Hashable, Identifiable, Sendable {
    case previewIdentity
    case quickActions
    case colorsAndTags
    case notesAndOCR
    case aiGeneration
    case photoExif
    case mediaSpecs
    case githubRepo
    case socialMediaExtract

    public var id: String { rawValue }

    public var defaultTitle: String {
        switch self {
        case .previewIdentity: "素材预览"
        case .quickActions: "快捷操作"
        case .colorsAndTags: "色板与标签"
        case .notesAndOCR: "备注与识别文本"
        case .aiGeneration: "AI 生图信息"
        case .photoExif: "拍摄参数 (EXIF)"
        case .mediaSpecs: "媒体信息"
        case .githubRepo: "GitHub 仓库信息"
        case .socialMediaExtract: "推文媒体提取"
        }
    }

    public static let defaultOrder: [InspectorInfoSection] = [
        .previewIdentity,
        .quickActions,
        .colorsAndTags,
        .notesAndOCR,
        .aiGeneration,
        .photoExif,
        .mediaSpecs,
        .githubRepo,
        .socialMediaExtract
    ]

    /// Restores a persisted raw order while deduplicating and appending any newly introduced sections.
    public static func normalizedOrder(from rawValues: [String]) -> [InspectorInfoSection] {
        var result: [InspectorInfoSection] = []
        var seen = Set<InspectorInfoSection>()
        for raw in rawValues {
            if let section = InspectorInfoSection(rawValue: raw), seen.insert(section).inserted {
                result.append(section)
            }
        }
        for fallback in defaultOrder where seen.insert(fallback).inserted {
            result.append(fallback)
        }
        return result
    }

    public static func moving(
        _ dragged: InspectorInfoSection,
        toTarget target: InspectorInfoSection,
        in order: [InspectorInfoSection]
    ) -> [InspectorInfoSection] {
        var next = order
        guard dragged != target,
              let fromIdx = next.firstIndex(of: dragged),
              let toIdx = next.firstIndex(of: target) else {
            return order
        }
        let item = next.remove(at: fromIdx)
        next.insert(item, at: toIdx)
        return next
    }

    public static func movingToTop(
        _ section: InspectorInfoSection,
        in order: [InspectorInfoSection]
    ) -> [InspectorInfoSection] {
        var next = order
        guard let idx = next.firstIndex(of: section), idx != 0 else { return order }
        let item = next.remove(at: idx)
        next.insert(item, at: 0)
        return next
    }

    public static func movingToBottom(
        _ section: InspectorInfoSection,
        in order: [InspectorInfoSection]
    ) -> [InspectorInfoSection] {
        var next = order
        guard let idx = next.firstIndex(of: section), idx != next.count - 1 else { return order }
        let item = next.remove(at: idx)
        next.append(item)
        return next
    }

    /// Moves `section` up (`delta < 0`) or down (`delta > 0`) to swap past its nearest currently-visible neighbor,
    /// so hidden sections (e.g. EXIF on screenshots) never cause a no-op click.
    public static func stepping(
        _ section: InspectorInfoSection,
        delta: Int,
        visible: [InspectorInfoSection],
        in order: [InspectorInfoSection]
    ) -> [InspectorInfoSection] {
        guard delta != 0,
              let visIdx = visible.firstIndex(of: section) else { return order }
        let targetVisIdx = visIdx + (delta > 0 ? 1 : -1)
        guard visible.indices.contains(targetVisIdx) else { return order }
        return moving(section, toTarget: visible[targetVisIdx], in: order)
    }
}

public struct TagCount: Codable, Hashable, Identifiable, Sendable {
    public var id: String { name }
    public let name: String
    public let count: Int

    public init(name: String, count: Int) {
        self.name = name
        self.count = count
    }
}

public struct SmartFolderRule: Codable, Hashable, Sendable {
    public enum MatchMode: String, Codable, CaseIterable, Hashable, Sendable {
        case all
        case any

        public var localizedLabel: String {
            switch self {
            case .all: "满足全部条件"
            case .any: "满足任一条件"
            }
        }
    }

    public var matchMode: MatchMode
    public var tags: [String]
    public var descriptionQuery: String
    public var colorHexes: [String]
    public var colorTolerance: Double
    public var mediaKinds: [MediaKind]
    public var minRating: Int

    public init(
        matchMode: MatchMode = .all,
        tags: [String] = [],
        descriptionQuery: String = "",
        colorHexes: [String] = [],
        colorTolerance: Double = 24.0,
        mediaKinds: [MediaKind] = [],
        minRating: Int = 0
    ) {
        self.matchMode = matchMode
        self.tags = tags
        self.descriptionQuery = descriptionQuery
        self.colorHexes = colorHexes
        self.colorTolerance = colorTolerance
        self.mediaKinds = mediaKinds
        self.minRating = minRating
    }

    public var hasAnyCondition: Bool {
        !tags.isEmpty
            || !descriptionQuery.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            || !colorHexes.isEmpty
            || !mediaKinds.isEmpty
            || minRating > 0
    }

    /// Evaluates whether a non-trashed asset satisfies this smart folder rule.
    public func matches(_ asset: AssetRecord) -> Bool {
        guard !asset.isTrashed else { return false }
        var hasCondition = false

        // 1. Zero-allocation O(1) checks first so `.all` short-circuits immediately.
        if minRating > 0 {
            hasCondition = true
            let passed = asset.rating >= minRating
            if matchMode == .all {
                if !passed { return false }
            } else if passed {
                return true
            }
        }

        if !mediaKinds.isEmpty {
            hasCondition = true
            let passed = mediaKinds.contains(asset.mediaKind)
            if matchMode == .all {
                if !passed { return false }
            } else if passed {
                return true
            }
        }

        // 2. Tags check without allocating intermediate Sets or lowercased Arrays.
        if !tags.isEmpty {
            var activeTagCount = 0
            var allMatched = true
            var anyMatched = false
            for rawTag in tags {
                let cleanTag = rawTag.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !cleanTag.isEmpty else { continue }
                activeTagCount += 1
                let matched = !asset.tags.isEmpty && asset.tags.contains { candidate in
                    Self.trimmedCaseInsensitiveEquals(candidate, cleanTag)
                }
                if matched {
                    anyMatched = true
                    if matchMode == .any { break }
                } else {
                    allMatched = false
                    if matchMode == .all { break }
                }
            }
            if activeTagCount > 0 {
                hasCondition = true
                let passed = matchMode == .all ? allMatched : anyMatched
                if matchMode == .all {
                    if !passed { return false }
                } else if passed {
                    return true
                }
            }
        }

        // 3. Description / metadata text query without concatenating an 8-field haystack string.
        if !descriptionQuery.isEmpty {
            let trimmedQuery = descriptionQuery.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmedQuery.isEmpty {
                hasCondition = true
                let passed = Self.matchesDescriptionTokens(trimmedQuery, in: asset)
                if matchMode == .all {
                    if !passed { return false }
                } else if passed {
                    return true
                }
            }
        }

        // 4. CIELAB color proximity using squared Euclidean distance (skips `LabColor.fromHex` if asset has no colors).
        if !colorHexes.isEmpty {
            var hasActiveColor = false
            var matchedColor = false
            let tol = max(4.0, colorTolerance)
            let tolSq = tol * tol
            for rawHex in colorHexes {
                let cleanHex = rawHex.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !cleanHex.isEmpty else { continue }
                hasActiveColor = true
                if asset.dominantColors.isEmpty { break }
                let target = LabColor.fromHex(cleanHex)
                if asset.dominantColors.contains(where: { $0.deltaESquared(to: target) <= tolSq }) {
                    matchedColor = true
                    break
                }
            }
            if hasActiveColor {
                hasCondition = true
                if matchMode == .all {
                    if !matchedColor { return false }
                } else if matchedColor {
                    return true
                }
            }
        }

        return matchMode == .all ? hasCondition : false
    }

    private static func trimmedCaseInsensitiveEquals(_ lhs: String, _ rhsTrimmed: String) -> Bool {
        let lhsTrimmed = lhs.trimmingCharacters(in: .whitespacesAndNewlines)
        let lhsUTF8 = lhsTrimmed.utf8
        let rhsUTF8 = rhsTrimmed.utf8
        if lhsUTF8.count == rhsUTF8.count {
            var allASCII = true
            var eq = true
            var li = lhsUTF8.startIndex
            var ri = rhsUTF8.startIndex
            while li < lhsUTF8.endIndex {
                let lb = lhsUTF8[li]
                let rb = rhsUTF8[ri]
                if lb >= 0x80 || rb >= 0x80 {
                    allASCII = false
                    break
                }
                let lf = (lb >= 0x41 && lb <= 0x5A) ? (lb &+ 32) : lb
                let rf = (rb >= 0x41 && rb <= 0x5A) ? (rb &+ 32) : rb
                if lf != rf {
                    eq = false
                    break
                }
                li = lhsUTF8.index(after: li)
                ri = rhsUTF8.index(after: ri)
            }
            if allASCII { return eq }
        }
        return lhsTrimmed.lowercased() == rhsTrimmed.lowercased()
    }

    private static func fieldContainsCaseInsensitive(_ field: String?, token: Substring) -> Bool {
        guard let field, !field.isEmpty else { return false }
        return field.range(of: token, options: .caseInsensitive) != nil
    }

    private static func matchesDescriptionTokens(_ trimmedQuery: String, in asset: AssetRecord) -> Bool {
        let repo = asset.richMetadata?.githubRepo
        let post = asset.richMetadata?.socialPost
        func assetContains(_ token: Substring) -> Bool {
            fieldContainsCaseInsensitive(asset.title, token: token)
                || fieldContainsCaseInsensitive(asset.notes, token: token)
                || fieldContainsCaseInsensitive(asset.aiDescription, token: token)
                || fieldContainsCaseInsensitive(asset.ocrText, token: token)
                || fieldContainsCaseInsensitive(repo?.fullName, token: token)
                || fieldContainsCaseInsensitive(repo?.description, token: token)
                || fieldContainsCaseInsensitive(post?.authorName, token: token)
                || fieldContainsCaseInsensitive(post?.bodyText, token: token)
        }
        if !trimmedQuery.contains(where: \.isWhitespace) {
            return assetContains(trimmedQuery[...])
        }
        for token in trimmedQuery.split(whereSeparator: \.isWhitespace) {
            if !assetContains(token) { return false }
        }
        return true
    }
}

public struct SmartFolderRecord: Codable, Hashable, Identifiable, Sendable {
    public let id: UUID
    public var name: String
    public var colorHex: String?
    public var rule: SmartFolderRule
    public var sortOrder: Int
    public var createdAt: Date
    public var updatedAt: Date

    public init(
        id: UUID = UUID(),
        name: String,
        colorHex: String? = nil,
        rule: SmartFolderRule = SmartFolderRule(),
        sortOrder: Int = 0,
        createdAt: Date = Date(),
        updatedAt: Date = Date()
    ) {
        self.id = id
        self.name = name
        self.colorHex = colorHex
        self.rule = rule
        self.sortOrder = sortOrder
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }
}

public enum SortOrder: String, Codable, CaseIterable, Hashable, Sendable {
    case newest
    case oldest
    case nameAsc
    case ratingDesc
    case fileSizeDesc
    case relevance

    public var localizedLabel: String {
        switch self {
        case .newest: "最新添加"
        case .oldest: "最早添加"
        case .nameAsc: "名称 A→Z"
        case .ratingDesc: "评分最高"
        case .fileSizeDesc: "文件最大"
        case .relevance: "最相关"
        }
    }
}

public enum GalleryLayoutMode: String, Codable, CaseIterable, Hashable, Sendable {
    case verticalMasonry
    case horizontalJustified
    case galleryFilmstrip
    case ringGallery

    public var localizedLabel: String {
        switch self {
        case .verticalMasonry: "纵向瀑布流"
        case .horizontalJustified: "横向瀑布流"
        case .galleryFilmstrip: "画廊视图"
        case .ringGallery: "环形画廊"
        }
    }
}

public enum SidebarDestination: Hashable, Sendable {
    case allItems
    case inbox
    case pinterest
    case moodboardsHome
    case moodboard(UUID)
    case untagged
    case recent
    case trash
    case folder(UUID)
    case smartFolder(UUID)
    case tag(String)
}

public struct FilterCriteria: Codable, Hashable, Sendable {
    public var searchQuery: String
    public var kinds: Set<MediaKind>
    public var selectedColorHex: String?
    public var colorTolerance: Double
    public var shape: AspectShape?
    public var minRating: Int
    public var tags: Set<String>
    public var folderID: UUID?
    public var includeSubfolders: Bool
    public var onlyInbox: Bool
    public var onlyUntagged: Bool
    public var onlyRecentDays: Int?
    public var onlyPinnedOffline: Bool
    public var includeTrashed: Bool
    public var onlyTrashed: Bool
    public var sortBy: SortOrder

    public init(
        searchQuery: String = "",
        kinds: Set<MediaKind> = [],
        selectedColorHex: String? = nil,
        colorTolerance: Double = 28.0,
        shape: AspectShape? = nil,
        minRating: Int = 0,
        tags: Set<String> = [],
        folderID: UUID? = nil,
        includeSubfolders: Bool = false,
        onlyInbox: Bool = false,
        onlyUntagged: Bool = false,
        onlyRecentDays: Int? = nil,
        onlyPinnedOffline: Bool = false,
        includeTrashed: Bool = false,
        onlyTrashed: Bool = false,
        sortBy: SortOrder = .newest
    ) {
        self.searchQuery = searchQuery
        self.kinds = kinds
        self.selectedColorHex = selectedColorHex
        self.colorTolerance = colorTolerance
        self.shape = shape
        self.minRating = minRating
        self.tags = tags
        self.folderID = folderID
        self.includeSubfolders = includeSubfolders
        self.onlyInbox = onlyInbox
        self.onlyUntagged = onlyUntagged
        self.onlyRecentDays = onlyRecentDays
        self.onlyPinnedOffline = onlyPinnedOffline
        self.includeTrashed = includeTrashed
        self.onlyTrashed = onlyTrashed
        self.sortBy = sortBy
    }

    public var hasActiveVisualFilters: Bool {
        !kinds.isEmpty
            || selectedColorHex != nil
            || shape != nil
            || minRating > 0
            || !tags.isEmpty
            || onlyPinnedOffline
    }

    public mutating func clearVisualFilters() {
        kinds.removeAll()
        selectedColorHex = nil
        shape = nil
        minRating = 0
        tags.removeAll()
        onlyPinnedOffline = false
    }
}

public enum FolderAssignment: Codable, Hashable, Sendable {
    case unchanged
    case inbox
    case folder(UUID)
}

public struct AssetBatchPatch: Codable, Hashable, Sendable {
    public var assetIDs: [UUID]
    public var title: String?
    public var notes: String?
    public var sourceURL: String?
    public var rating: Int?
    public var addTags: [String]
    public var removeTags: [String]
    public var acceptSuggestedTags: Bool
    public var dismissSuggestedTags: [String]
    public var folderAssignment: FolderAssignment
    public var pinnedOffline: Bool?
    public var isTrashed: Bool?

    public init(
        assetIDs: [UUID],
        title: String? = nil,
        notes: String? = nil,
        sourceURL: String? = nil,
        rating: Int? = nil,
        addTags: [String] = [],
        removeTags: [String] = [],
        acceptSuggestedTags: Bool = false,
        dismissSuggestedTags: [String] = [],
        folderAssignment: FolderAssignment = .unchanged,
        pinnedOffline: Bool? = nil,
        isTrashed: Bool? = nil
    ) {
        self.assetIDs = assetIDs
        self.title = title
        self.notes = notes
        self.sourceURL = sourceURL
        self.rating = rating
        self.addTags = addTags
        self.removeTags = removeTags
        self.acceptSuggestedTags = acceptSuggestedTags
        self.dismissSuggestedTags = dismissSuggestedTags
        self.folderAssignment = folderAssignment
        self.pinnedOffline = pinnedOffline
        self.isTrashed = isTrashed
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        assetIDs = try c.decode([UUID].self, forKey: .assetIDs)
        title = try c.decodeIfPresent(String.self, forKey: .title)
        notes = try c.decodeIfPresent(String.self, forKey: .notes)
        sourceURL = try c.decodeIfPresent(String.self, forKey: .sourceURL)
        rating = try c.decodeIfPresent(Int.self, forKey: .rating)
        addTags = try c.decodeIfPresent([String].self, forKey: .addTags) ?? []
        removeTags = try c.decodeIfPresent([String].self, forKey: .removeTags) ?? []
        acceptSuggestedTags = try c.decodeIfPresent(Bool.self, forKey: .acceptSuggestedTags) ?? false
        dismissSuggestedTags = try c.decodeIfPresent([String].self, forKey: .dismissSuggestedTags) ?? []
        folderAssignment = try c.decodeIfPresent(FolderAssignment.self, forKey: .folderAssignment) ?? .unchanged
        pinnedOffline = try c.decodeIfPresent(Bool.self, forKey: .pinnedOffline)
        isTrashed = try c.decodeIfPresent(Bool.self, forKey: .isTrashed)
    }
}

public enum QuickJumpKind: String, Codable, Hashable, Sendable {
    case folder
    case moodboard
    case tag
    case asset
}

public struct QuickJumpMatch: Codable, Hashable, Identifiable, Sendable {
    public let id: String
    public let kind: QuickJumpKind
    public let title: String
    public let subtitle: String
    public let targetUUID: UUID?
    public let tagName: String?
    public let score: Double

    public init(
        id: String,
        kind: QuickJumpKind,
        title: String,
        subtitle: String,
        targetUUID: UUID? = nil,
        tagName: String? = nil,
        score: Double
    ) {
        self.id = id
        self.kind = kind
        self.title = title
        self.subtitle = subtitle
        self.targetUUID = targetUUID
        self.tagName = tagName
        self.score = score
    }
}

public struct ScoredAsset: Codable, Hashable, Identifiable, Sendable {
    public var id: UUID { asset.id }
    public let asset: AssetRecord
    public let score: Double
    public let matchReasons: [String]

    public init(asset: AssetRecord, score: Double, matchReasons: [String] = []) {
        self.asset = asset
        self.score = score
        self.matchReasons = matchReasons
    }
}

public struct FolderSuggestion: Codable, Hashable, Sendable {
    public let folderID: UUID
    public let folderName: String
    public let confidence: Double
    public let reason: String

    public init(folderID: UUID, folderName: String, confidence: Double, reason: String) {
        self.folderID = folderID
        self.folderName = folderName
        self.confidence = confidence
        self.reason = reason
    }
}
