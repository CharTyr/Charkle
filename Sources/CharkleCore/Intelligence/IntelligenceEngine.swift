import Foundation

public nonisolated struct IntelligenceEngine: Sendable {
    private static let visionQueue = DispatchQueue(label: "com.charkle.core.vision", qos: .userInitiated)

    let keychain: KeychainStore
    let chatGPT: ChatGPTSignInClient

    public init(keychain: KeychainStore = KeychainStore(), chatGPT: ChatGPTSignInClient? = nil) {
        self.keychain = keychain
        self.chatGPT = chatGPT ?? ChatGPTSignInClient(keychain: keychain)
    }

    public func analyze(thumbnailURL: URL, includeColors: Bool = true) async -> LocalAnalysisResult {
        await withCheckedContinuation { continuation in
            Self.visionQueue.async {
                guard let image = MediaPipeline.raster(thumbnailURL)?.poster else {
                    continuation.resume(returning: LocalAnalysisResult())
                    return
                }
                let text = VisionAnalyzer.recognizeTextSync(in: image)
                let colors = includeColors ? ColorExtractor.extractDominantColors(from: image) : []
                let featurePrint = VisionAnalyzer.generateFeaturePrint(for: image)
                continuation.resume(returning: LocalAnalysisResult(
                    dominantColors: colors,
                    ocrText: text.isEmpty ? nil : text,
                    featurePrintData: featurePrint
                ))
            }
        }
    }

    func provider(for config: AIProviderConfig) throws -> (any CloudAIProvider)? {
        guard config.provider != .disabled else { return nil }
        switch config.provider {
        case .disabled: return nil
        case .chatGPTSubscription:
            return ChatGPTSubscriptionProvider(client: chatGPT, model: config.chatModel)
        case .gemini:
            let key = try keychain.read(Self.key(config.provider)).flatMap { String(data: $0, encoding: .utf8) }
            guard let key, !key.isEmpty else { throw LibraryDatabaseError("请先在设置中填写 Gemini API 密钥。") }
            return try GeminiProvider(config: config, apiKey: key)
        case .openAICompatible:
            let key = try keychain.read(Self.key(config.provider)).flatMap { String(data: $0, encoding: .utf8) }
            switch config.customEndpointFormat {
            case .openAIChatCompletions:
                return try OpenAICompatibleProvider(config: config, apiKey: key)
            case .openAIResponses:
                return try OpenAIResponsesProvider(config: config, apiKey: key)
            case .anthropicMessages:
                guard let key, !key.isEmpty else { throw LibraryDatabaseError("请先在设置中填写 Anthropic API 密钥。") }
                return try AnthropicMessagesProvider(config: config, apiKey: key)
            }
        }
    }

    static func key(_ provider: CloudAIProviderKind) -> String { "ai.\(provider.rawValue)" }

    public func enrich(_ asset: AssetRecord, thumbnailURL: URL?, provider: any CloudAIProvider) async throws -> CloudEnrichmentResult {
        let fields = [asset.title, asset.notes, asset.tags.joined(separator: ", "), asset.sourceDomain ?? "", asset.ocrText ?? ""]
        return try await provider.enrich(text: String(fields.joined(separator: "\n").prefix(12_000)),
                                         thumbnailJPEG: try thumbnailURL.map { try Data(contentsOf: $0) })
    }
}
