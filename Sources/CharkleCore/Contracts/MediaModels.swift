import Foundation

public enum CaptureInput: Hashable, Sendable {
    case fileURL(URL)
    case imageData(Data, suggestedName: String, sourceURL: String?)
    case webURL(URL, title: String?, notes: String?)
    case textSnippet(title: String, text: String, sourceURL: String?)
    case colorSwatch(hex: String, title: String?)
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
