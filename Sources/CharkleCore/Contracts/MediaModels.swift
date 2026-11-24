import Foundation

public enum CaptureInput: Hashable, Sendable {
    case fileURL(URL)
    case imageData(Data, suggestedName: String, sourceURL: String?)
    case webURL(URL, title: String?, notes: String?)
    case textSnippet(title: String, text: String, sourceURL: String?)
    case colorSwatch(hex: String, title: String?)
    case socialBookmark(SocialPostMetadata, coverImageData: Data? = nil, tags: [String] = [])
}

public enum ThumbnailTier: String, Codable, Hashable, Sendable {
    case grid520
    case preview1400
}

public struct CacheStats: Codable, Hashable, Sendable {
    public var thumbnailBytes: Int64
    public var originalCacheBytes: Int64
    public var pinnedOfflineBytes: Int64
    public var budgetBytes: Int64
    public var cachedOriginalCount: Int
    public var pinnedAssetCount: Int

    public init(
        thumbnailBytes: Int64 = 0,
        originalCacheBytes: Int64 = 0,
        pinnedOfflineBytes: Int64 = 0,
        budgetBytes: Int64 = 10 * 1024 * 1024 * 1024,
        cachedOriginalCount: Int = 0,
        pinnedAssetCount: Int = 0
    ) {
        self.thumbnailBytes = thumbnailBytes
        self.originalCacheBytes = originalCacheBytes
        self.pinnedOfflineBytes = pinnedOfflineBytes
        self.budgetBytes = budgetBytes
        self.cachedOriginalCount = cachedOriginalCount
        self.pinnedAssetCount = pinnedAssetCount
    }
}

public enum CloudAIProviderKind: String, Codable, CaseIterable, Hashable, Sendable {
    case disabled
    case chatGPTSubscription
    case gemini
    case openAICompatible

    public var localizedLabel: String {
        switch self {
        case .disabled: "关闭（仅本机）"
        case .chatGPTSubscription: "ChatGPT 订阅账号"
        case .gemini: "Google Gemini"
        case .openAICompatible: "自定义兼容服务"
        }
    }
}

public enum ChatGPTConnectionStatus: String, Codable, Hashable, Sendable {
    case disconnected
    case connected
    case reauthRequired
}

public struct ChatGPTAccountSession: Codable, Hashable, Sendable {
    public var status: ChatGPTConnectionStatus
    public var sharingEnabled: Bool
    public var email: String?
    public var name: String?
    public var subject: String?
    public var lastUpdatedAt: Date?

    public init(
        status: ChatGPTConnectionStatus = .disconnected,
        sharingEnabled: Bool = false,
        email: String? = nil,
        name: String? = nil,
        subject: String? = nil,
        lastUpdatedAt: Date? = nil
    ) {
        self.status = status
        self.sharingEnabled = sharingEnabled
        self.email = email
        self.name = name
        self.subject = subject
        self.lastUpdatedAt = lastUpdatedAt
    }

    public var displayName: String {
        if let name = name?.trimmingCharacters(in: .whitespacesAndNewlines), !name.isEmpty {
            return name
        }
        if let email = email?.trimmingCharacters(in: .whitespacesAndNewlines), !email.isEmpty {
            return email
        }
        return "ChatGPT 账号"
    }
}

public struct ChatGPTModelInfo: Codable, Hashable, Identifiable, Sendable {
    public var id: String { slug }
    public let slug: String
    public let displayName: String

    public init(slug: String, displayName: String) {
        self.slug = slug
        self.displayName = displayName
    }
}

public enum CustomAIEndpointFormat: String, Codable, CaseIterable, Hashable, Sendable {
    case openAIChatCompletions
    case anthropicMessages
    case openAIResponses

    public var localizedLabel: String {
        switch self {
        case .openAIChatCompletions: "OpenAI 兼容 (Chat Completions)"
        case .anthropicMessages: "Anthropic Messages"
        case .openAIResponses: "OpenAI Responses"
        }
    }

    public var defaultBaseURL: String {
        switch self {
        case .openAIChatCompletions, .openAIResponses: "https://api.openai.com"
        case .anthropicMessages: "https://api.anthropic.com"
        }
    }

    public var defaultChatModel: String {
        switch self {
        case .openAIChatCompletions, .openAIResponses: "gpt-4.1-mini"
        case .anthropicMessages: "claude-sonnet-4-5"
        }
    }

    public var defaultEmbeddingModel: String {
        switch self {
        case .openAIChatCompletions, .openAIResponses: "text-embedding-3-small"
        case .anthropicMessages: ""
        }
    }

    public var supportsEmbeddings: Bool {
        self != .anthropicMessages
    }
}

public struct AIProviderConfig: Codable, Hashable, Sendable {
    public var provider: CloudAIProviderKind
    public var customEndpointFormat: CustomAIEndpointFormat
    public var baseURL: String
    public var chatModel: String
    public var embeddingModel: String
    public var autoAnalyzeOnImport: Bool
    public var sendThumbnailsToCloud: Bool

    public init(
        provider: CloudAIProviderKind = .disabled,
        customEndpointFormat: CustomAIEndpointFormat = .openAIChatCompletions,
        baseURL: String = "https://generativelanguage.googleapis.com",
        chatModel: String = "gemini-2.5-flash",
        embeddingModel: String = "gemini-embedding-001",
        autoAnalyzeOnImport: Bool = false,
        sendThumbnailsToCloud: Bool = true
    ) {
        self.provider = provider
        self.customEndpointFormat = customEndpointFormat
        self.baseURL = baseURL
        self.chatModel = chatModel
        self.embeddingModel = embeddingModel
        self.autoAnalyzeOnImport = autoAnalyzeOnImport
        self.sendThumbnailsToCloud = sendThumbnailsToCloud
    }

    private enum CodingKeys: String, CodingKey {
        case provider, customEndpointFormat, baseURL, chatModel, embeddingModel, autoAnalyzeOnImport, sendThumbnailsToCloud
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        provider = try c.decodeIfPresent(CloudAIProviderKind.self, forKey: .provider) ?? .disabled
        customEndpointFormat = try c.decodeIfPresent(CustomAIEndpointFormat.self, forKey: .customEndpointFormat) ?? .openAIChatCompletions
        baseURL = try c.decodeIfPresent(String.self, forKey: .baseURL) ?? "https://generativelanguage.googleapis.com"
        chatModel = try c.decodeIfPresent(String.self, forKey: .chatModel) ?? "gemini-2.5-flash"
        embeddingModel = try c.decodeIfPresent(String.self, forKey: .embeddingModel) ?? "gemini-embedding-001"
        autoAnalyzeOnImport = try c.decodeIfPresent(Bool.self, forKey: .autoAnalyzeOnImport) ?? false
        sendThumbnailsToCloud = try c.decodeIfPresent(Bool.self, forKey: .sendThumbnailsToCloud) ?? true
    }
}

public struct LocalAnalysisResult: Codable, Hashable, Sendable {
    public var dominantColors: [LabColor]
    public var ocrText: String?
    public var featurePrintData: Data?

    public init(
        dominantColors: [LabColor] = [],
        ocrText: String? = nil,
        featurePrintData: Data? = nil
    ) {
        self.dominantColors = dominantColors
        self.ocrText = ocrText
        self.featurePrintData = featurePrintData
    }
}

public struct CloudEnrichmentResult: Codable, Hashable, Sendable {
    public var description: String?
    public var suggestedTags: [String]
    public var embedding: [Float]?

    public init(
        description: String? = nil,
        suggestedTags: [String] = [],
        embedding: [Float]? = nil
    ) {
        self.description = description
        self.suggestedTags = suggestedTags
        self.embedding = embedding
    }
}

// MARK: - Experimental TypeSafe System One (Jev) Visual Grounding & Decision Sidecar

public struct TypeSafeExperimentalConfig: Codable, Hashable, Sendable {
    public var enabled: Bool
    public var baseURL: String
    public var model: String
    /// Boxes with confidence below this threshold are automatically padded outward to avoid clipping edges.
    public var minConfidence: Double
    /// Fraction of image width/height padded on each side when confidence is below `minConfidence`.
    public var lowConfidencePadding: Double
    /// Companion `Noul` threshold below which a target is treated as absent from the image.
    public var minPresenceProbability: Double
    /// Scenario 1: Semantic & subject-focus non-destructive crop on Moodboard cards.
    public var enableMoodboardFocusCrop: Bool
    /// Scenario 2: Automatic chrome/margin noise detection and clean-content crop.
    public var enableAutoCleanCrop: Bool
    /// Scenario 3a: Subject-aware CIELAB palette extraction.
    public var enableSubjectPalette: Bool
    /// Scenario 3b: Pinpoint callout annotations anchored to detected object boxes.
    public var enablePinpointAnnotations: Bool
    /// Phase 2: Visual + Hybrid semantic search across the library.
    public var enableSemanticSearch: Bool
    /// Phase 2: Closed-set Choice + Companion Noul inbox folder triage.
    public var enableInboxSmartTriage: Bool
    /// Phase 2: Multi-dimensional Score visual reranking in Moodboard curator & candidate pool.
    public var enableCuratorVisualRerank: Bool

    public init(
        enabled: Bool = false,
        baseURL: String = "https://api.typesafe.ai",
        model: String = "jev-latest",
        minConfidence: Double = 0.60,
        lowConfidencePadding: Double = 0.05,
        minPresenceProbability: Double = 0.45,
        enableMoodboardFocusCrop: Bool = true,
        enableAutoCleanCrop: Bool = true,
        enableSubjectPalette: Bool = true,
        enablePinpointAnnotations: Bool = true,
        enableSemanticSearch: Bool = true,
        enableInboxSmartTriage: Bool = true,
        enableCuratorVisualRerank: Bool = true
    ) {
        self.enabled = enabled
        self.baseURL = baseURL
        self.model = model
        self.minConfidence = minConfidence
        self.lowConfidencePadding = lowConfidencePadding
        self.minPresenceProbability = minPresenceProbability
        self.enableMoodboardFocusCrop = enableMoodboardFocusCrop
        self.enableAutoCleanCrop = enableAutoCleanCrop
        self.enableSubjectPalette = enableSubjectPalette
        self.enablePinpointAnnotations = enablePinpointAnnotations
        self.enableSemanticSearch = enableSemanticSearch
        self.enableInboxSmartTriage = enableInboxSmartTriage
        self.enableCuratorVisualRerank = enableCuratorVisualRerank
    }

    private enum CodingKeys: String, CodingKey {
        case enabled, baseURL, model, minConfidence, lowConfidencePadding, minPresenceProbability
        case enableMoodboardFocusCrop, enableAutoCleanCrop, enableSubjectPalette, enablePinpointAnnotations
        case enableSemanticSearch, enableInboxSmartTriage, enableCuratorVisualRerank
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        enabled = try c.decodeIfPresent(Bool.self, forKey: .enabled) ?? false
        baseURL = try c.decodeIfPresent(String.self, forKey: .baseURL) ?? "https://api.typesafe.ai"
        model = try c.decodeIfPresent(String.self, forKey: .model) ?? "jev-latest"
        minConfidence = try c.decodeIfPresent(Double.self, forKey: .minConfidence) ?? 0.60
        lowConfidencePadding = try c.decodeIfPresent(Double.self, forKey: .lowConfidencePadding) ?? 0.05
        minPresenceProbability = try c.decodeIfPresent(Double.self, forKey: .minPresenceProbability) ?? 0.45
        enableMoodboardFocusCrop = try c.decodeIfPresent(Bool.self, forKey: .enableMoodboardFocusCrop) ?? true
        enableAutoCleanCrop = try c.decodeIfPresent(Bool.self, forKey: .enableAutoCleanCrop) ?? true
        enableSubjectPalette = try c.decodeIfPresent(Bool.self, forKey: .enableSubjectPalette) ?? true
        enablePinpointAnnotations = try c.decodeIfPresent(Bool.self, forKey: .enablePinpointAnnotations) ?? true
        enableSemanticSearch = try c.decodeIfPresent(Bool.self, forKey: .enableSemanticSearch) ?? true
        enableInboxSmartTriage = try c.decodeIfPresent(Bool.self, forKey: .enableInboxSmartTriage) ?? true
        enableCuratorVisualRerank = try c.decodeIfPresent(Bool.self, forKey: .enableCuratorVisualRerank) ?? true
    }
}

public struct TypeSafeModelInfo: Codable, Hashable, Identifiable, Sendable {
    public var id: String { name }
    public let name: String
    public let description: String
    public let releaseDate: String

    public init(name: String, description: String = "", releaseDate: String = "") {
        self.name = name
        self.description = description
        self.releaseDate = releaseDate
    }

    private enum CodingKeys: String, CodingKey {
        case name
        case description
        case releaseDate = "release_date"
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        name = try c.decode(String.self, forKey: .name)
        description = try c.decodeIfPresent(String.self, forKey: .description) ?? ""
        releaseDate = try c.decodeIfPresent(String.self, forKey: .releaseDate) ?? ""
    }
}

public enum VisualRegionSource: String, Codable, Hashable, Sendable {
    case typeSafeJev
    case appleVisionSaliency

    public var localizedLabel: String {
        switch self {
        case .typeSafeJev: "TypeSafe Jev Box"
        case .appleVisionSaliency: "本机 Vision 主体识别"
        }
    }
}

public struct VisualRegionResult: Codable, Hashable, Sendable {
    public var crop: NormalizedCropRect
    public var rawBox: NormalizedCropRect
    public var presenceProbability: Double
    public var confidence: Double?
    public var didApplyPadding: Bool
    public var found: Bool
    public var source: VisualRegionSource
    public var model: String?
    public var summary: String

    public init(
        crop: NormalizedCropRect,
        rawBox: NormalizedCropRect,
        presenceProbability: Double,
        confidence: Double?,
        didApplyPadding: Bool,
        found: Bool,
        source: VisualRegionSource,
        model: String? = nil,
        summary: String = ""
    ) {
        self.crop = crop
        self.rawBox = rawBox
        self.presenceProbability = presenceProbability
        self.confidence = confidence
        self.didApplyPadding = didApplyPadding
        self.found = found
        self.source = source
        self.model = model
        self.summary = summary
    }
}

public struct CleanBoundsResult: Codable, Hashable, Sendable {
    public var hasNoise: Bool
    public var noiseProbability: Double
    public var recommendedCrop: NormalizedCropRect?
    public var confidence: Double?
    public var didApplyPadding: Bool
    public var source: VisualRegionSource
    public var model: String?
    public var summary: String

    public init(
        hasNoise: Bool,
        noiseProbability: Double,
        recommendedCrop: NormalizedCropRect?,
        confidence: Double?,
        didApplyPadding: Bool,
        source: VisualRegionSource,
        model: String? = nil,
        summary: String = ""
    ) {
        self.hasNoise = hasNoise
        self.noiseProbability = noiseProbability
        self.recommendedCrop = recommendedCrop
        self.confidence = confidence
        self.didApplyPadding = didApplyPadding
        self.source = source
        self.model = model
        self.summary = summary
    }
}

public struct SubjectPaletteResult: Codable, Hashable, Sendable {
    public var colors: [LabColor]
    public var subjectRegion: VisualRegionResult
    public var updatedAsset: AssetRecord

    public init(
        colors: [LabColor],
        subjectRegion: VisualRegionResult,
        updatedAsset: AssetRecord
    ) {
        self.colors = colors
        self.subjectRegion = subjectRegion
        self.updatedAsset = updatedAsset
    }
}

// MARK: - Phase 2: Hybrid Semantic Search & Inbox Smart Triage

public struct SemanticSearchHit: Codable, Hashable, Identifiable, Sendable {
    public var id: UUID { asset.id }
    public var asset: AssetRecord
    /// Combined calibrated relevance in `[0, 1]`.
    public var score: Double
    public var confidence: Double?
    public var reason: String
    public var sourceLabel: String

    public init(
        asset: AssetRecord,
        score: Double,
        confidence: Double? = nil,
        reason: String = "",
        sourceLabel: String = "混合语义"
    ) {
        self.asset = asset
        self.score = score
        self.confidence = confidence
        self.reason = reason
        self.sourceLabel = sourceLabel
    }
}

public struct SemanticSearchReport: Codable, Hashable, Sendable {
    public var query: String
    public var hits: [SemanticSearchHit]
    public var usedTypeSafeJev: Bool
    public var usedCloudEmbedding: Bool
    public var evaluatedVisualCount: Int
    public var summary: String

    public init(
        query: String,
        hits: [SemanticSearchHit],
        usedTypeSafeJev: Bool = false,
        usedCloudEmbedding: Bool = false,
        evaluatedVisualCount: Int = 0,
        summary: String = ""
    ) {
        self.query = query
        self.hits = hits
        self.usedTypeSafeJev = usedTypeSafeJev
        self.usedCloudEmbedding = usedCloudEmbedding
        self.evaluatedVisualCount = evaluatedVisualCount
        self.summary = summary
    }
}

public struct InboxTriageRecommendation: Codable, Hashable, Identifiable, Sendable {
    public var id: UUID { assetID }
    public var assetID: UUID
    public var assetTitle: String
    public var recommendedFolderID: UUID?
    public var recommendedFolderName: String?
    public var confidence: Double
    public var fitProbability: Double
    public var reason: String
    public var source: VisualRegionSource

    public init(
        assetID: UUID,
        assetTitle: String,
        recommendedFolderID: UUID?,
        recommendedFolderName: String?,
        confidence: Double,
        fitProbability: Double,
        reason: String,
        source: VisualRegionSource
    ) {
        self.assetID = assetID
        self.assetTitle = assetTitle
        self.recommendedFolderID = recommendedFolderID
        self.recommendedFolderName = recommendedFolderName
        self.confidence = confidence
        self.fitProbability = fitProbability
        self.reason = reason
        self.source = source
    }
}
