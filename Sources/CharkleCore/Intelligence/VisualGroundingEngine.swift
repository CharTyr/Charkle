import AppKit
import CoreGraphics
import Foundation

/// Ensures every image sent to TypeSafe strictly obeys `280 <= width, height <= 1568`
/// and upright standard JPEG encoding (avoiding HTTP 400 dimension rejections).
public nonisolated enum TypeSafeImagePreparer: Sendable {
    public static let minSide = 280
    public static let maxSide = 1568

    public static func prepareJPEG(
        from cgImage: CGImage,
        targetLongSide: Int = 768,
        compression: Double = 0.86
    ) -> Data? {
        let srcW = cgImage.width
        let srcH = cgImage.height
        guard srcW > 0, srcH > 0 else { return nil }

        let desiredMax = max(minSide, min(maxSide, targetLongSide))
        var scale = Double(desiredMax) / Double(max(srcW, srcH))
        // Never shrink below minSide on the shorter edge if avoidable
        if Double(min(srcW, srcH)) * scale < Double(minSide) {
            scale = Double(minSide) / Double(min(srcW, srcH))
        }
        // Cap long side at maxSide
        if Double(max(srcW, srcH)) * scale > Double(maxSide) {
            scale = Double(maxSide) / Double(max(srcW, srcH))
        }

        let drawW = max(1, min(maxSide, Int((Double(srcW) * scale).rounded())))
        let drawH = max(1, min(maxSide, Int((Double(srcH) * scale).rounded())))
        // If aspect ratio is > 5.6:1, pad the short axis up to minSide cleanly
        let canvasW = max(minSide, drawW)
        let canvasH = max(minSide, drawH)

        let colorSpace = CGColorSpaceCreateDeviceRGB()
        guard let ctx = CGContext(
            data: nil,
            width: canvasW,
            height: canvasH,
            bitsPerComponent: 8,
            bytesPerRow: canvasW * 4,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }

        ctx.interpolationQuality = .high
        ctx.setFillColor(CGColor(red: 0.96, green: 0.96, blue: 0.96, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: canvasW, height: canvasH))
        let originX = (canvasW - drawW) / 2
        let originY = (canvasH - drawH) / 2
        ctx.draw(cgImage, in: CGRect(x: originX, y: originY, width: drawW, height: drawH))

        guard let normalized = ctx.makeImage() else { return nil }
        return NSBitmapImageRep(cgImage: normalized).representation(
            using: .jpeg,
            properties: [.compressionFactor: compression]
        )
    }
}

public nonisolated struct VisualCandidateInput: Sendable, Hashable {
    public let assetID: UUID
    public let title: String
    public let tags: [String]
    public let description: String?
    public let imageData: Data?
    public let imageFormat: String

    public init(
        assetID: UUID,
        title: String,
        tags: [String] = [],
        description: String? = nil,
        imageData: Data?,
        imageFormat: String = "jpg"
    ) {
        self.assetID = assetID
        self.title = title
        self.tags = tags
        self.description = description
        self.imageData = imageData
        self.imageFormat = imageFormat
    }
}

public nonisolated struct VisualScoreResult: Sendable, Hashable {
    public let assetID: UUID
    /// Normalized relevance score in `[0, 1]` derived from Jev's `0...3` calibrated Score.
    public let score: Double
    public let confidence: Double?
    public let rawScore: Double

    public init(assetID: UUID, score: Double, confidence: Double?, rawScore: Double) {
        self.assetID = assetID
        self.score = score
        self.confidence = confidence
        self.rawScore = rawScore
    }
}

public nonisolated struct FolderOptionInput: Sendable, Hashable {
    public let id: UUID
    public let name: String
    public let sampleTags: [String]

    public init(id: UUID, name: String, sampleTags: [String] = []) {
        self.id = id
        self.name = name
        self.sampleTags = sampleTags
    }
}

/// Deep module unifying **TypeSafe System One (`Jev`)** spatial grounding (`Noul` + `Box`)
/// and semantic decision primitives (`Choice` + `Score`) with offline **Apple Vision Saliency** fallback.
///
/// Covers Phase 1 experimental scenarios:
/// 1. Moodboard semantic & subject-focus non-destructive crop (`locateRegion` / `locateVisualMatch`)
/// 2. Screenshot / web / social capture chrome & margin noise cleanup (`detectCleanContentBounds`)
/// 3. Subject-aware CIELAB palette extraction (`extractSubjectPalette`) & pinpoint callouts (`locateRegion`)
public nonisolated struct VisualGroundingEngine: Sendable {
    private let session: URLSession

    public init(session: URLSession = .shared) {
        self.session = session
    }

    /// Locate either the primary visual subject (`query == nil` or empty) or a semantically described
    /// element (`query != nil`, e.g. "黄铜台灯" / "the glass pill button") in an image.
    ///
    /// When TypeSafe (`Jev`) is enabled and configured with an API key, executes a single System One
    /// fan-out request containing a companion `Noul` (presence check) + `Box` (coordinates + confidence),
    /// automatically padding outward if confidence is below `config.minConfidence`.
    /// When TypeSafe is disabled or no API key is configured, falls back to offline Apple Vision Saliency
    /// for primary subject framing.
    public func locateRegion(
        query: String?,
        imageData: Data,
        imageFormat: String = "jpg",
        cgImage: CGImage?,
        config: TypeSafeExperimentalConfig,
        apiKey: String?
    ) async throws -> VisualRegionResult {
        let trimmedQuery = query?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let isSemanticQuery = !trimmedQuery.isEmpty

        if config.enabled, let key = apiKey?.trimmingCharacters(in: .whitespacesAndNewlines), !key.isEmpty {
            let client = try TypeSafeSystemOneClient(baseURL: config.baseURL, apiKey: key, session: session)
            let photoRef = "img-\(UUID().uuidString.lowercased())"
            let attachment = TypeSafeImageAttachment(
                referenceKey: photoRef,
                partName: "photo",
                format: imageFormat,
                data: imageData
            )

            let targetPhrase = isSemanticQuery
                ? trimmedQuery
                : "the main visual subject, hero object, or focal artwork"

            let noulQuestion = TypeSafeQuestion.noul(
                instructions: "Is \(targetPhrase) clearly visible in `photo`?",
                trueCriteria: "The requested subject or visual element is visible in `photo`.",
                falseCriteria: "The requested subject or visual element does not appear in `photo`."
            )
            let boxQuestion = TypeSafeQuestion.box(
                instructions: "\(targetPhrase) in `photo`"
            )

            let response = try await client.systemOne(
                model: config.model,
                state: ["photo": photoRef],
                questions: [
                    "present": noulQuestion,
                    "region": boxQuestion
                ],
                images: [attachment]
            )

            let presence = response.answers["present"]?.noulProbability ?? 1.0
            guard let boxAnswer = response.answers["region"]?.boxValue else {
                throw LibraryDatabaseError("TypeSafe 未返回有效的 Box 定位结果。")
            }

            let rawBox = boxAnswer.coords.normalizedCropRect.clamped()
            let confidence = boxAnswer.confidence
            let minPresence = max(0.05, min(0.95, config.minPresenceProbability))
            let found = presence >= minPresence

            let shouldPad: Bool = {
                guard let confidence else { return config.lowConfidencePadding > 0 }
                return confidence < config.minConfidence && config.lowConfidencePadding > 0
            }()
            let finalCrop = shouldPad ? rawBox.padded(by: config.lowConfidencePadding) : rawBox

            let summary: String
            if !found {
                summary = isSemanticQuery
                    ? "画面中未检测到「\(trimmedQuery)」（存在概率 \(Int((presence * 100).rounded()))%）"
                    : "未检测到明确视觉主体（存在概率 \(Int((presence * 100).rounded()))%）"
            } else {
                let confText = confidence.map { "置信度 \(Int(($0 * 100).rounded()))%" } ?? "已定位"
                let padText = shouldPad ? " · 已自动外扩防切边" : ""
                summary = isSemanticQuery
                    ? "Jev Box 已定位「\(trimmedQuery)」（\(confText)\(padText)）"
                    : "Jev Box 已聚焦主体（\(confText)\(padText)）"
            }

            return VisualRegionResult(
                crop: finalCrop,
                rawBox: rawBox,
                presenceProbability: presence,
                confidence: confidence,
                didApplyPadding: shouldPad,
                found: found,
                source: .typeSafeJev,
                model: response.model,
                summary: summary
            )
        }

        // Offline fallback when TypeSafe is disabled or unconfigured
        if isSemanticQuery {
            throw LibraryDatabaseError("「一句话语义定位」需要开启 TypeSafe (Jev) 实验档并填写 API 密钥（可在 设置 → 智能与搜索 中开启）。")
        }

        guard let cgImage, let saliency = VisionAnalyzer.detectPrimarySubjectBox(in: cgImage) else {
            return VisualRegionResult(
                crop: .full,
                rawBox: .full,
                presenceProbability: 0,
                confidence: nil,
                didApplyPadding: false,
                found: false,
                source: .appleVisionSaliency,
                model: nil,
                summary: "本机 Vision 未检测到独立聚焦主体"
            )
        }

        let padded = saliency.padded(by: 0.04)
        return VisualRegionResult(
            crop: padded,
            rawBox: saliency,
            presenceProbability: 1.0,
            confidence: nil,
            didApplyPadding: true,
            found: true,
            source: .appleVisionSaliency,
            model: "Apple Vision Saliency",
            summary: "已通过本机 Apple Vision 自动聚焦主体"
        )
    }

    /// Locate where a reference visual snippet appears inside a target image (TypeSafe Visual-Target Box).
    public func locateVisualMatch(
        referenceImageData: Data,
        referenceFormat: String = "jpg",
        in targetImageData: Data,
        targetFormat: String = "jpg",
        config: TypeSafeExperimentalConfig,
        apiKey: String?
    ) async throws -> VisualRegionResult {
        guard config.enabled, let key = apiKey?.trimmingCharacters(in: .whitespacesAndNewlines), !key.isEmpty else {
            throw LibraryDatabaseError("「以图定位」需要开启 TypeSafe (Jev) 实验档并配置 API 密钥。")
        }

        let client = try TypeSafeSystemOneClient(baseURL: config.baseURL, apiKey: key, session: session)
        let targetRef = "target-\(UUID().uuidString.lowercased())"
        let snippetRef = "ref-\(UUID().uuidString.lowercased())"

        let response = try await client.systemOne(
            model: config.model,
            state: ["target": targetRef],
            questions: [
                "present": .noul(
                    instructions: "Does the object or visual element shown in \(snippetRef) appear in `target`?"
                ),
                "region": .box(
                    instructions: "the region in `target` that matches this reference: \(snippetRef)"
                )
            ],
            images: [
                TypeSafeImageAttachment(referenceKey: targetRef, partName: "target_image", format: targetFormat, data: targetImageData),
                TypeSafeImageAttachment(referenceKey: snippetRef, partName: "reference_image", format: referenceFormat, data: referenceImageData)
            ]
        )

        let presence = response.answers["present"]?.noulProbability ?? 1.0
        guard let boxAnswer = response.answers["region"]?.boxValue else {
            throw LibraryDatabaseError("TypeSafe 未返回有效的以图定位 Box 结果。")
        }
        let rawBox = boxAnswer.coords.normalizedCropRect.clamped()
        let confidence = boxAnswer.confidence
        let shouldPad = (confidence ?? 0) < config.minConfidence && config.lowConfidencePadding > 0
        let finalCrop = shouldPad ? rawBox.padded(by: config.lowConfidencePadding) : rawBox
        let found = presence >= max(0.05, min(0.95, config.minPresenceProbability))

        return VisualRegionResult(
            crop: finalCrop,
            rawBox: rawBox,
            presenceProbability: presence,
            confidence: confidence,
            didApplyPadding: shouldPad,
            found: found,
            source: .typeSafeJev,
            model: response.model,
            summary: found ? "Jev Box 已在目标图中找到匹配局部" : "目标图中未找到匹配该参考图的元素"
        )
    }

    /// Scenario 2: Detect whether an image contains screenshot/browser/social chrome or excessive margins,
    /// and return a clean non-destructive crop box around the core artwork/design card.
    public func detectCleanContentBounds(
        imageData: Data,
        imageFormat: String = "jpg",
        cgImage: CGImage?,
        config: TypeSafeExperimentalConfig,
        apiKey: String?
    ) async throws -> CleanBoundsResult {
        if config.enabled, let key = apiKey?.trimmingCharacters(in: .whitespacesAndNewlines), !key.isEmpty {
            let client = try TypeSafeSystemOneClient(baseURL: config.baseURL, apiKey: key, session: session)
            let photoRef = "capture-\(UUID().uuidString.lowercased())"
            let attachment = TypeSafeImageAttachment(
                referenceKey: photoRef,
                partName: "capture",
                format: imageFormat,
                data: imageData
            )

            let response = try await client.systemOne(
                model: config.model,
                state: ["capture": photoRef],
                questions: [
                    "has_noise": .noul(
                        instructions: "Does `capture` contain unwanted browser chrome, OS window frames, status bars, social media UI surrounding a design, letterbox bars, or excessive blank outer margins?",
                        trueCriteria: "There are surrounding UI bars, window chrome, black/white letterbox margins, or desktop background framing the real visual content.",
                        falseCriteria: "The image is already cleanly framed artwork or photography filling the canvas without unwanted borders or UI chrome."
                    ),
                    "core_content": .box(
                        instructions: "the core visual artwork, photograph, poster, or primary design card in `capture`, excluding browser toolbars, OS window chrome, social post framing, and empty surrounding borders"
                    )
                ],
                images: [attachment]
            )

            let noiseProb = response.answers["has_noise"]?.noulProbability ?? 0.0
            let boxAnswer = response.answers["core_content"]?.boxValue
            let confidence = boxAnswer?.confidence
            let hasNoise = noiseProb >= max(0.35, min(0.90, config.minPresenceProbability))

            guard hasNoise, let boxAnswer else {
                return CleanBoundsResult(
                    hasNoise: false,
                    noiseProbability: noiseProb,
                    recommendedCrop: nil,
                    confidence: confidence,
                    didApplyPadding: false,
                    source: .typeSafeJev,
                    model: response.model,
                    summary: "画面本身已很干净，无需额外去噪裁切"
                )
            }

            let rawBox = boxAnswer.coords.normalizedCropRect.clamped()
            let shouldPad = (confidence ?? 0) < config.minConfidence && config.lowConfidencePadding > 0
            let finalCrop = shouldPad ? rawBox.padded(by: min(0.03, config.lowConfidencePadding)) : rawBox
            let meaningful = finalCrop.isMeaningfulSubregion

            let confText = confidence.map { "置信度 \(Int(($0 * 100).rounded()))%" } ?? "已识别"
            return CleanBoundsResult(
                hasNoise: meaningful,
                noiseProbability: noiseProb,
                recommendedCrop: meaningful ? finalCrop : nil,
                confidence: confidence,
                didApplyPadding: shouldPad,
                source: .typeSafeJev,
                model: response.model,
                summary: meaningful
                    ? "Jev 已识别核心内容区域并去除外围噪边（\(confText)）"
                    : "核心内容几乎占满整图，保持原画幅更佳"
            )
        }

        // Offline Vision Saliency fallback
        guard let cgImage, let saliency = VisionAnalyzer.detectPrimarySubjectBox(in: cgImage) else {
            return CleanBoundsResult(
                hasNoise: false,
                noiseProbability: 0,
                recommendedCrop: nil,
                confidence: nil,
                didApplyPadding: false,
                source: .appleVisionSaliency,
                model: "Apple Vision Saliency",
                summary: "未检测到明显多余边距，保持完整画面"
            )
        }
        let padded = saliency.padded(by: 0.03)
        let meaningful = padded.isMeaningfulSubregion
        return CleanBoundsResult(
            hasNoise: meaningful,
            noiseProbability: meaningful ? 0.72 : 0.15,
            recommendedCrop: meaningful ? padded : nil,
            confidence: nil,
            didApplyPadding: true,
            source: .appleVisionSaliency,
            model: "Apple Vision Saliency",
            summary: meaningful
                ? "已通过本机 Apple Vision 裁去外围留白区域"
                : "画面已较为紧凑，无需裁切"
        )
    }

    /// Scenario 3a: Locate the primary visual subject (or queried target) first, then extract a
    /// background-free perceptual CIELAB palette from that region.
    public func extractSubjectPalette(
        query: String?,
        imageData: Data,
        imageFormat: String = "jpg",
        cgImage: CGImage,
        colorCount: Int = 6,
        config: TypeSafeExperimentalConfig,
        apiKey: String?
    ) async throws -> (colors: [LabColor], region: VisualRegionResult) {
        let region = try await locateRegion(
            query: query,
            imageData: imageData,
            imageFormat: imageFormat,
            cgImage: cgImage,
            config: config,
            apiKey: apiKey
        )
        let effectiveCrop: NormalizedCropRect? = region.found ? region.crop : nil
        let colors = ColorExtractor.extractDominantColors(from: cgImage, crop: effectiveCrop, count: colorCount)
        return (colors, region)
    }

    // MARK: - Phase 2: Visual Semantic Search & Multi-Dimensional Score Rerank

    /// Scores a pool of design reference candidates against a natural-language visual/conceptual query
    /// by fanning out batched TypeSafe `Score` (`0...3`) questions across concurrent chunks.
    /// Works even for completely untagged images because Jev directly inspects each candidate's image.
    public func scoreCandidatesForQuery(
        query: String,
        candidates: [VisualCandidateInput],
        config: TypeSafeExperimentalConfig,
        apiKey: String?,
        batchSize: Int = 4,
        maxConcurrency: Int = 3
    ) async throws -> [VisualScoreResult] {
        let trimmedQuery = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedQuery.isEmpty, !candidates.isEmpty else { return [] }
        guard config.enabled, let key = apiKey?.trimmingCharacters(in: .whitespacesAndNewlines), !key.isEmpty else {
            return []
        }

        let client = try TypeSafeSystemOneClient(baseURL: config.baseURL, apiKey: key, session: session)
        let effectiveBatch = max(1, min(6, batchSize))
        let chunks: [[VisualCandidateInput]] = stride(from: 0, to: candidates.count, by: effectiveBatch).map { start in
            Array(candidates[start..<min(start + effectiveBatch, candidates.count)])
        }

        var results: [VisualScoreResult] = []
        results.reserveCapacity(candidates.count)

        let workerLimit = max(1, min(maxConcurrency, chunks.count))
        var nextChunkIndex = 0

        try await withThrowingTaskGroup(of: [VisualScoreResult].self) { group in
            for _ in 0..<workerLimit {
                guard nextChunkIndex < chunks.count else { break }
                let batch = chunks[nextChunkIndex]
                nextChunkIndex += 1
                group.addTask {
                    try await Self.scoreSingleBatch(
                        query: trimmedQuery,
                        batch: batch,
                        model: config.model,
                        client: client
                    )
                }
            }

            while let batchScores = try await group.next() {
                results.append(contentsOf: batchScores)
                if nextChunkIndex < chunks.count {
                    let batch = chunks[nextChunkIndex]
                    nextChunkIndex += 1
                    group.addTask {
                        try await Self.scoreSingleBatch(
                            query: trimmedQuery,
                            batch: batch,
                            model: config.model,
                            client: client
                        )
                    }
                }
            }
        }

        return results.sorted { $0.score > $1.score }
    }

    private static func scoreSingleBatch(
        query: String,
        batch: [VisualCandidateInput],
        model: String,
        client: TypeSafeSystemOneClient
    ) async throws -> [VisualScoreResult] {
        var stateItems: [String: Any] = [:]
        var attachments: [TypeSafeImageAttachment] = []
        var questions: [String: TypeSafeQuestion] = [:]
        var keyToAssetID: [String: UUID] = [:]

        let scoreCriteria: [String] = [
            "Unrelated — subject, mood, color atmosphere, and design style do not match the query.",
            "Weakly related — only a tangential element or faint mood overlaps.",
            "Good match — clearly matches the query's visual subject, design language, or aesthetic mood.",
            "Strong exact match — directly depicts the requested subject, style, composition, or visual concept."
        ]

        for (index, item) in batch.enumerated() {
            let slotKey = "item_\(index)"
            keyToAssetID[slotKey] = item.assetID

            var entry: [String: Any] = [
                "title": String(item.title.prefix(120))
            ]
            if !item.tags.isEmpty {
                entry["tags"] = Array(item.tags.prefix(8))
            }
            if let desc = item.description?.trimmingCharacters(in: .whitespacesAndNewlines), !desc.isEmpty {
                entry["description"] = String(desc.prefix(240))
            }
            if let imgData = item.imageData, !imgData.isEmpty {
                let ref = "cand-\(index)-\(UUID().uuidString.lowercased())"
                entry["image"] = ref
                attachments.append(TypeSafeImageAttachment(
                    referenceKey: ref,
                    partName: "img_\(index)",
                    format: item.imageFormat,
                    data: imgData
                ))
            }
            stateItems[slotKey] = entry

            let hasImage = item.imageData != nil
            let instruction = hasImage
                ? "Rate how well the design reference in `items.\(slotKey).image` (with metadata in `items.\(slotKey)`) matches the user's visual search query: \"\(query)\"."
                : "Rate how well the design reference metadata in `items.\(slotKey)` matches the user's search query: \"\(query)\"."

            questions[slotKey] = .score(
                instructions: instruction,
                criteria: scoreCriteria
            )
        }

        let response = try await client.systemOne(
            model: model,
            state: ["query": query, "items": stateItems],
            questions: questions,
            images: attachments
        )

        var batchResults: [VisualScoreResult] = []
        batchResults.reserveCapacity(batch.count)
        for (slotKey, assetID) in keyToAssetID {
            if let scored = response.answers[slotKey]?.scoreValue {
                let normalized = max(0.0, min(1.0, scored.score / 3.0))
                batchResults.append(VisualScoreResult(
                    assetID: assetID,
                    score: normalized,
                    confidence: scored.confidence,
                    rawScore: scored.score
                ))
            }
        }
        return batchResults
    }

    // MARK: - Phase 2: Closed-Set Inbox Folder Classification (Choice + Companion Noul)

    /// Classifies an asset into the user's exact existing folders using TypeSafe `Choice` (zero hallucinated folder names)
    /// paired with a companion `Noul` that checks whether any folder truly fits (preventing forced misfiling).
    public func classifyIntoFolders(
        assetTitle: String,
        assetTags: [String],
        assetNotes: String,
        imageData: Data?,
        imageFormat: String = "jpg",
        folders: [FolderOptionInput],
        config: TypeSafeExperimentalConfig,
        apiKey: String?
    ) async throws -> (folderID: UUID?, confidence: Double, fitProbability: Double, reason: String) {
        guard !folders.isEmpty else {
            return (nil, 0, 0, "素材库暂无目标文件夹")
        }
        guard config.enabled, let key = apiKey?.trimmingCharacters(in: .whitespacesAndNewlines), !key.isEmpty else {
            throw LibraryDatabaseError("Inbox 智能分拣需要开启 TypeSafe (Jev) 实验档并配置 API 密钥。")
        }

        let client = try TypeSafeSystemOneClient(baseURL: config.baseURL, apiKey: key, session: session)
        let cappedFolders = Array(folders.prefix(32))

        var criteria: [String: String] = [:]
        var idByKey: [String: FolderOptionInput] = [:]
        for (idx, folder) in cappedFolders.enumerated() {
            let optionKey = "f_\(idx)"
            idByKey[optionKey] = folder
            let tagsHint = folder.sampleTags.isEmpty
                ? ""
                : " (typical themes/tags: \(folder.sampleTags.prefix(6).joined(separator: ", ")))"
            criteria[optionKey] = "Folder \"\(folder.name)\"\(tagsHint)"
        }

        var state: [String: Any] = [
            "title": String(assetTitle.prefix(120)),
            "tags": Array(assetTags.prefix(10)),
            "notes": String(assetNotes.prefix(240))
        ]
        var attachments: [TypeSafeImageAttachment] = []
        if let imageData, !imageData.isEmpty {
            let photoRef = "inbox-\(UUID().uuidString.lowercased())"
            state["photo"] = photoRef
            attachments.append(TypeSafeImageAttachment(
                referenceKey: photoRef,
                partName: "inbox_photo",
                format: imageFormat,
                data: imageData
            ))
        }

        let folderNamesList = cappedFolders.map(\.name).joined(separator: ", ")
        let targetDesc = imageData != nil ? "`photo` and its metadata" : "this design asset's metadata"

        let response = try await client.systemOne(
            model: config.model,
            state: state,
            questions: [
                "fits_any": .noul(
                    instructions: "Does \(targetDesc) clearly belong in one of these design reference folders (\(folderNamesList))?",
                    trueCriteria: "The visual subject, medium, or design style clearly matches at least one listed folder.",
                    falseCriteria: "None of the listed folders fit well; it should stay uncategorized in Inbox."
                ),
                "folder": .choice(
                    instructions: "Which folder best fits \(targetDesc)?",
                    criteria: criteria
                )
            ],
            images: attachments
        )

        let fitProb = response.answers["fits_any"]?.noulProbability ?? 0.5
        guard let choiceAnswer = response.answers["folder"]?.choiceValue,
              let chosen = idByKey[choiceAnswer.choice] else {
            return (nil, 0, fitProb, "未能确定合适目录，建议暂留收件箱")
        }

        let topProb = choiceAnswer.probabilities[choiceAnswer.choice] ?? fitProb
        let effectiveConfidence = choiceAnswer.confidence ?? topProb
        let minFit = max(0.35, min(0.85, config.minPresenceProbability))

        if fitProb < minFit {
            return (
                nil,
                effectiveConfidence,
                fitProb,
                "匹配度偏低（\(Int((fitProb * 100).rounded()))%），建议暂留收件箱（最接近：\(chosen.name)）"
            )
        }

        return (
            chosen.id,
            max(0.0, min(1.0, effectiveConfidence)),
            fitProb,
            "Jev 视觉归类（匹配度 \(Int((fitProb * 100).rounded()))% · 置信度 \(Int((effectiveConfidence * 100).rounded()))%）"
        )
    }
}
