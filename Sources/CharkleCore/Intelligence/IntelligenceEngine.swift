import Foundation

private actor VisionConcurrencyGate {
    private let limit: Int
    private var active = 0
    private var waiters: [(id: UUID, continuation: CheckedContinuation<Bool, Never>)] = []

    init(limit: Int) {
        self.limit = max(1, limit)
    }

    func acquire() async -> Bool {
        if Task.isCancelled { return false }
        if active < limit {
            active += 1
            return true
        }
        let waiterID = UUID()
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                if Task.isCancelled {
                    continuation.resume(returning: false)
                    return
                }
                if active < limit {
                    active += 1
                    continuation.resume(returning: true)
                    return
                }
                waiters.append((waiterID, continuation))
            }
        } onCancel: {
            Task { await self.cancelWaiter(id: waiterID) }
        }
    }

    private func cancelWaiter(id: UUID) {
        if let idx = waiters.firstIndex(where: { $0.id == id }) {
            let waiter = waiters.remove(at: idx)
            waiter.continuation.resume(returning: false)
        }
    }

    func release() {
        if !waiters.isEmpty {
            let next = waiters.removeFirst()
            next.continuation.resume(returning: true)
        } else {
            active = max(0, active - 1)
        }
    }
}

public nonisolated struct IntelligenceEngine: Sendable {
    #if os(iOS)
    private static let visionGate = VisionConcurrencyGate(limit: 2)
    #else
    private static let visionGate = VisionConcurrencyGate(limit: 3)
    #endif
    private static let visionQueue = DispatchQueue(
        label: "com.charkle.core.vision",
        qos: .userInitiated,
        attributes: .concurrent
    )

    let keychain: KeychainStore
    let chatGPT: ChatGPTSignInClient
    let grounding: VisualGroundingEngine

    public init(
        keychain: KeychainStore = KeychainStore(),
        chatGPT: ChatGPTSignInClient? = nil,
        grounding: VisualGroundingEngine = VisualGroundingEngine()
    ) {
        self.keychain = keychain
        self.chatGPT = chatGPT ?? ChatGPTSignInClient(keychain: keychain)
        self.grounding = grounding
    }

    public func analyze(
        thumbnailURL: URL,
        includeColors: Bool = true,
        includeOCR: Bool = true,
        includeFeaturePrint: Bool = true
    ) async -> LocalAnalysisResult {
        guard await Self.visionGate.acquire() else {
            return LocalAnalysisResult()
        }
        if Task.isCancelled {
            await Self.visionGate.release()
            return LocalAnalysisResult()
        }
        let result: LocalAnalysisResult = await withCheckedContinuation { continuation in
            Self.visionQueue.async {
                guard let image = MediaPipeline.raster(thumbnailURL)?.poster else {
                    continuation.resume(returning: LocalAnalysisResult())
                    return
                }
                let text: String
                let featurePrint: Data?
                if includeOCR && includeFeaturePrint {
                    (text, featurePrint) = VisionAnalyzer.analyzeSync(in: image)
                } else if includeOCR {
                    text = VisionAnalyzer.recognizeTextSync(in: image)
                    featurePrint = nil
                } else if includeFeaturePrint {
                    text = ""
                    featurePrint = VisionAnalyzer.generateFeaturePrint(for: image)
                } else {
                    text = ""
                    featurePrint = nil
                }
                let colors = includeColors ? ColorExtractor.extractDominantColors(from: image) : []
                continuation.resume(returning: LocalAnalysisResult(
                    dominantColors: colors,
                    ocrText: text.isEmpty ? nil : text,
                    featurePrintData: featurePrint
                ))
            }
        }
        await Self.visionGate.release()
        return result
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
    static let typeSafeKey = "ai.typesafe.systemone"

    func storedTypeSafeAPIKey() -> String? {
        guard let data = try? keychain.read(Self.typeSafeKey),
              let value = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines),
              !value.isEmpty else {
            return nil
        }
        return value
    }

    public func enrich(
        _ asset: AssetRecord,
        thumbnailURL: URL?,
        provider: any CloudAIProvider,
        existingLibraryTags: [String] = []
    ) async throws -> CloudEnrichmentResult {
        var fields = [asset.title, asset.notes, asset.tags.joined(separator: ", "), asset.sourceDomain ?? "", asset.ocrText ?? ""]
            .filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        if !existingLibraryTags.isEmpty {
            let tagCatalog = existingLibraryTags.prefix(120).joined(separator: ", ")
            fields.append("[Existing Library Tags]: \(tagCatalog)")
        }
        return try await provider.enrich(
            text: String(fields.joined(separator: "\n").prefix(12_000)),
            thumbnailJPEG: try thumbnailURL.map { try Data(contentsOf: $0) }
        )
    }
}
