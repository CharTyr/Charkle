import Foundation

public nonisolated struct IntelligenceEngine: Sendable {
    let keychain: KeychainStore

    public init(keychain: KeychainStore = KeychainStore()) { self.keychain = keychain }

    @concurrent
    public func analyze(thumbnailURL: URL, includeColors: Bool = true) async -> LocalAnalysisResult {
        guard let image = MediaPipeline.raster(thumbnailURL)?.poster else { return LocalAnalysisResult() }
        let text = VisionAnalyzer.recognizeTextSync(in: image)
        return LocalAnalysisResult(dominantColors: includeColors ? ColorExtractor.extractDominantColors(from: image) : [],
                                   ocrText: text.isEmpty ? nil : text, featurePrintData: VisionAnalyzer.generateFeaturePrint(for: image))
    }

    func provider(for config: AIProviderConfig) throws -> (any CloudAIProvider)? {
        guard config.provider != .disabled else { return nil }
        let key = try keychain.read(Self.key(config.provider)).flatMap { String(data: $0, encoding: .utf8) }
        switch config.provider {
        case .disabled: return nil
        case .gemini:
            guard let key, !key.isEmpty else { throw LibraryDatabaseError("请先在设置中填写 Gemini API 密钥。") }
            return try GeminiProvider(config: config, apiKey: key)
        case .openAICompatible:
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
