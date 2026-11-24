import Foundation
import Vision

public nonisolated struct MoodboardCurator: Sendable {
    private let database: LibraryDatabase

    public init(database: LibraryDatabase) { self.database = database }

    public func proposeMoodboard(seed: MoodboardSeed, primaryCount: Int, candidateCount: Int,
                                 provider: (any CloudAIProvider)? = nil) async throws -> MoodboardProposal {
        var prompt = ""
        var seedIDs: [UUID] = []
        var palette: [LabColor] = []
        var tolerance = 28.0
        var manual = false
        switch seed {
        case .prompt(let text): prompt = text
        case .seedAssets(let ids): seedIDs = ids
        case .palette(let colors, let distance): palette = colors; tolerance = max(0, distance)
        case .manualSelection(let ids): seedIDs = ids; manual = true
        case .combined(let text, let ids, let colors): prompt = text ?? ""; seedIDs = ids; palette = colors
        }

        let assets = try await database.fetchAssets(matching: FilterCriteria())
        let indexed = Dictionary(uniqueKeysWithValues: assets.map { ($0.id, $0) })
        let seeds = unique(seedIDs).compactMap { indexed[$0] }
        let seedSet = Set(seedIDs)
        let available = assets.filter { !seedSet.contains($0.id) }
        let vectors = try await database.vectors()
        let ranks = try await keywordRanks(prompt)
        var promptVector: [Float]?
        if let provider, !prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
           vectors.values.contains(where: { $0.embeddingModel == provider.embeddingIdentity && $0.embedding != nil }) {
            promptVector = try? await provider.embed(prompt)
        }
        let evidence = Evidence(seeds: seeds, colors: palette, tolerance: tolerance, ranks: ranks,
                                queryVector: promptVector, embeddingIdentity: provider?.embeddingIdentity, vectors: vectors)
        let explicitSeeds = seeds.map { ScoredAsset(asset: $0, score: 1, matchReasons: ["所选素材"]) }
        let primarySeeds = Array(explicitSeeds.prefix(max(0, primaryCount)))
        let needed = manual ? 0 : max(0, primaryCount - primarySeeds.count)
        let ordered = rerank(available.map { evidence.score($0) }, evidence: evidence, against: seeds,
                             limit: min(needed, available.count) + min(max(0, candidateCount), available.count))
        let primary = primarySeeds + ordered.prefix(needed)
        let candidates = Array((explicitSeeds.dropFirst(primarySeeds.count) + ordered.dropFirst(needed)).prefix(max(0, candidateCount)))
        let paletteSource = primary.flatMap(\.asset.dominantColors)
        let extracted = Self.palette(paletteSource.isEmpty ? palette : paletteSource, count: 6)
        let title = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        let document = MoodboardDocument(title: title.isEmpty ? "新情绪板" : String(title.prefix(120)),
                                         nodes: Self.editorialNodes(primary.map(\.asset)), extractedPalette: extracted,
                                         candidateAssetIDs: candidates.map(\.id))
        let usedCloud = (primary + candidates).contains { $0.matchReasons.contains(Evidence.cloudReason) }
        return MoodboardProposal(draftDocument: document, primaryMatches: primary, candidatePool: candidates,
                                 extractedPalette: extracted, usedCloudAI: usedCloud)
    }

    public func extractBoardPalette(assetIDs: [UUID], count: Int) async throws -> [LabColor] {
        var colors: [LabColor] = []
        for id in unique(assetIDs) { colors += try await database.asset(id: id)?.dominantColors ?? [] }
        return Self.palette(colors, count: count)
    }

    public func replacementCandidates(for assetID: UUID, excluding: Set<UUID>, boardContext: [UUID],
                                      limit: Int) async throws -> [ScoredAsset] {
        guard limit > 0, let anchor = try await database.asset(id: assetID) else { return [] }
        let assets = try await database.fetchAssets(matching: FilterCriteria())
        let existing = Set(boardContext).union(excluding).union([assetID])
        let context = Set(boardContext).subtracting([assetID])
        let neighbors = assets.filter { context.contains($0.id) }
        let evidence = Evidence(seeds: [anchor], colors: Self.palette(neighbors.flatMap(\.dominantColors), count: 6),
                                vectors: try await database.vectors())
        let matches = assets
            .filter { !existing.contains($0.id) }
            .map { evidence.score($0) }
            .filter { !$0.matchReasons.isEmpty && $0.score >= 0.24 }
        return rerank(matches, evidence: evidence, against: [], limit: limit)
    }

    public func similarAssets(to assetID: UUID, limit: Int) async throws -> [ScoredAsset] {
        guard limit > 0, let anchor = try await database.asset(id: assetID) else { return [] }
        let assets = try await database.fetchAssets(matching: FilterCriteria())
        let evidence = Evidence(seeds: [anchor], vectors: try await database.vectors())
        let matches = assets
            .filter { $0.id != assetID }
            .map { evidence.score($0) }
            .filter { !$0.matchReasons.isEmpty && $0.score >= 0.26 }
        return rerank(matches, evidence: evidence, against: [], limit: limit)
    }

    public func suggestFolder(for assetID: UUID) async throws -> FolderSuggestion? {
        guard let asset = try await database.asset(id: assetID) else { return nil }
        let folders = try await database.fetchFolders()
        let assets = try await database.fetchAssets(matching: FilterCriteria())
        let evidence = Evidence(seeds: [asset], vectors: try await database.vectors())
        let peers = assets.filter { $0.id != assetID && $0.folderID != nil }.map { evidence.score($0) }
        return folders.compactMap { folder -> FolderSuggestion? in
            guard folder.id != asset.folderID else { return nil }
            let keywords = unique(asset.tags + asset.suggestedTags)
            let nameMatch = keywords.contains { SearchText.fuzzyScore(query: $0, candidate: folder.name) != nil }
            let scores = peers.filter { $0.asset.folderID == folder.id && !$0.matchReasons.isEmpty }
                .map(\.score).sorted(by: >).prefix(3)
            guard nameMatch || !scores.isEmpty else { return nil }
            let affinity = scores.isEmpty ? 0 : scores.reduce(0, +) / Double(scores.count)
            let confidence = min(0.99, affinity * 0.8 + (nameMatch ? 0.45 : 0))
            return FolderSuggestion(folderID: folder.id, folderName: folder.name, confidence: confidence,
                                    reason: nameMatch ? "目录名与标签吻合" : "目录内有相近素材")
        }.sorted { ($0.confidence, $0.folderName) > ($1.confidence, $1.folderName) }.first
    }

    private func keywordRanks(_ prompt: String) async throws -> [UUID: Double] {
        var ranks = try await database.searchRanks(prompt)
        let terms = unique(prompt.split(whereSeparator: \.isWhitespace).map(String.init))
        if terms.count > 1 {
            for term in terms.prefix(12) {
                for (id, rank) in try await database.searchRanks(term) {
                    ranks[id] = min(1, (ranks[id] ?? 0) + rank / Double(terms.count))
                }
            }
        }
        return ranks
    }

    private func unique<T: Hashable>(_ values: [T]) -> [T] {
        var seen = Set<T>()
        return values.filter { seen.insert($0).inserted }
    }

    private func rerank(_ matches: [ScoredAsset], evidence: Evidence, against seeds: [AssetRecord], limit: Int) -> [ScoredAsset] {
        var pool = matches.sorted {
            ($0.score, $0.asset.rating, $0.id.uuidString) > ($1.score, $1.asset.rating, $1.id.uuidString)
        }
        let count = min(max(0, limit), pool.count)
        guard count > 0 else { return [] }
        let poolSize = max(200, count.multipliedReportingOverflow(by: 6).overflow ? pool.count : count * 6)
        if pool.count > poolSize { pool.removeLast(pool.count - poolSize) }

        // Pre-unarchive VNFeaturePrintObservation once for the bounded pool + seeds instead of
        // repeating NSKeyedUnarchiver inside the O(count * poolSize) diversity loop.
        var obsCache: [UUID: VNFeaturePrintObservation] = [:]
        obsCache.reserveCapacity(pool.count + seeds.count)
        for item in pool {
            if let data = evidence.vectors[item.id]?.featurePrint,
               let obs = VisionAnalyzer.unarchiveFeaturePrint(data) {
                obsCache[item.id] = obs
            }
        }
        for seed in seeds where obsCache[seed.id] == nil {
            if let data = evidence.vectors[seed.id]?.featurePrint,
               let obs = VisionAnalyzer.unarchiveFeaturePrint(data) {
                obsCache[seed.id] = obs
            }
        }

        var redundancy = pool.map { candidate in
            seeds.map { evidence.redundancy(candidate.asset, $0, featurePrints: obsCache) }.max() ?? 0
        }
        var available = Array(repeating: true, count: pool.count)
        var results: [ScoredAsset] = []
        for _ in 0..<count {
            var best: Int?
            var bestRank = -Double.infinity
            for index in pool.indices where available[index] {
                let rank = 0.64 * pool[index].score - 0.36 * redundancy[index]
                if rank > bestRank { best = index; bestRank = rank }
            }
            guard let best else { break }
            available[best] = false
            results.append(pool[best])
            if results.count < count {
                for index in pool.indices where available[index] {
                    redundancy[index] = max(
                        redundancy[index],
                        evidence.redundancy(pool[best].asset, pool[index].asset, featurePrints: obsCache)
                    )
                }
            }
        }
        return results
    }

    static func palette(_ input: [LabColor], count: Int) -> [LabColor] {
        guard count > 0 else { return [] }
        let finiteInput: [LabColor] = input.compactMap { swatch in
            guard swatch.l.isFinite, swatch.a.isFinite, swatch.b.isFinite else { return nil }
            var clean = swatch
            clean.proportion = (swatch.proportion.isFinite && swatch.proportion > 0) ? swatch.proportion : 0
            return clean
        }
        var groups: [LabColor] = []
        for swatch in finiteInput.sorted(by: { ($0.proportion, $0.hex) > ($1.proportion, $1.hex) }) {
            if let index = groups.indices.min(by: {
                groups[$0].deltaE(to: swatch) < groups[$1].deltaE(to: swatch)
            }), groups[index].deltaE2000(to: swatch) < 8 {
                groups[index].proportion += swatch.proportion
            } else { groups.append(swatch) }
        }
        let prominent = Array(groups.sorted { ($0.proportion, $0.hex) > ($1.proportion, $1.hex) }.prefix(count))
        let total = prominent.reduce(0) { $0 + $1.proportion }
        return prominent.sorted { $0.l > $1.l }.map {
            var swatch = $0
            if total > 0 { swatch.proportion /= total }
            return swatch
        }
    }

    static func editorialNodes(_ assets: [AssetRecord]) -> [BoardNode] {
        guard !assets.isEmpty else { return [] }
        var output: [BoardNode] = []
        var y = 0.0
        var lower = 0
        while lower < assets.count {
            let count = min(lower == 0 && assets.count <= 6 ? 3 : 4, assets.count - lower)
            let row = Array(assets[lower..<(lower + count)])
            let ratios = row.map { asset -> Double in
                let raw = asset.aspectRatio
                return (raw.isFinite && raw > 0) ? min(2.1, max(0.6, raw)) : 1.25
            }
            let weight = lower == 0 && count > 1 ? 1.25 : 1.0
            let weights = ratios.enumerated().map { $0.offset == 0 ? $0.element * weight : $0.element }
            let gap = 16.0
            let height = min(470, (1_180 - Double(count - 1) * gap) / weights.reduce(0, +))
            var x = 0.0
            for (index, asset) in row.enumerated() {
                let width = height * weights[index]
                let order = lower + index
                output.append(BoardNode(kind: .assetRef(assetID: asset.id, crop: nil, weight: order == 0 ? 2 : 1,
                                                        autoplayLoop: asset.mediaKind == .animatedImage || asset.mediaKind == .video),
                                        frame: BoardRect(x: x, y: y, width: width, height: height),
                                        zIndex: order, editorialOrder: order))
                x += width + gap
            }
            y += height + gap
            lower += count
        }
        return output
    }
}

private nonisolated struct Evidence {
    static let cloudReason = "语义接近"
    let seeds: [AssetRecord]
    let colors: [LabColor]
    let tolerance: Double
    let ranks: [UUID: Double]
    let queryVector: [Float]?
    let embeddingIdentity: String?
    let vectors: [UUID: AssetVector]
    private let seedFeaturePrints: [VNFeaturePrintObservation]
    private let seedEmbeddings: [(model: String?, values: [Float])]
    private let seedTagSets: [Set<String>]
    private let precomputedTargetColors: [LabColor]

    init(
        seeds: [AssetRecord],
        colors: [LabColor] = [],
        tolerance: Double = 28,
        ranks: [UUID: Double] = [:],
        queryVector: [Float]? = nil,
        embeddingIdentity: String? = nil,
        vectors: [UUID: AssetVector]
    ) {
        self.seeds = seeds
        self.colors = colors
        self.tolerance = tolerance
        self.ranks = ranks
        self.queryVector = queryVector
        self.embeddingIdentity = embeddingIdentity
        self.vectors = vectors
        self.seedFeaturePrints = seeds.compactMap { seed in
            vectors[seed.id]?.featurePrint.flatMap(VisionAnalyzer.unarchiveFeaturePrint)
        }
        self.seedEmbeddings = seeds.compactMap { seed in
            guard let vec = vectors[seed.id], let values = vec.embedding else { return nil }
            return (vec.embeddingModel, values)
        }
        self.seedTagSets = seeds.map { seed in
            Set((seed.tags + seed.suggestedTags).map(SearchText.normalize)).filter { !$0.isEmpty }
        }
        if colors.isEmpty {
            self.precomputedTargetColors = Self.significantSwatches(seeds.flatMap { $0.dominantColors.prefix(3) }, maxCount: 4)
        } else {
            self.precomputedTargetColors = colors.filter { $0.l.isFinite && $0.a.isFinite && $0.b.isFinite }
        }
    }

    func score(_ asset: AssetRecord) -> ScoredAsset {
        // Tuple: (signalValue, weight, minDisplayThreshold, label)
        var signals: [(value: Double, weight: Double, threshold: Double, reason: String)] = []
        signals.reserveCapacity(5)
        if !ranks.isEmpty {
            signals.append((ranks[asset.id] ?? 0, 0.48, 0.15, "关键词匹配"))
        }
        if let vector = vectors[asset.id], let embedding = vector.embedding {
            var bestCloud: Double?
            if let queryVector, vector.embeddingModel == embeddingIdentity {
                bestCloud = Self.cosine(embedding, queryVector)
            }
            for seedEmb in seedEmbeddings where seedEmb.model == vector.embeddingModel {
                let c = Self.cosine(embedding, seedEmb.values)
                if let current = bestCloud {
                    if c > current { bestCloud = c }
                } else {
                    bestCloud = c
                }
            }
            if let best = bestCloud {
                signals.append((best, 0.40, 0.45, Self.cloudReason))
            }
        }
        if !seedFeaturePrints.isEmpty, let printData = vectors[asset.id]?.featurePrint {
            let bestVisual: Double? = autoreleasepool {
                guard let candidateObs = VisionAnalyzer.unarchiveFeaturePrint(printData) else { return nil }
                var best: Double?
                for seedObs in seedFeaturePrints {
                    if let dist = VisionAnalyzer.visualDistance(between: candidateObs, and: seedObs) {
                        let sim = VisionAnalyzer.visualSimilarity(forDistance: dist)
                        if let current = best {
                            if sim > current { best = sim }
                        } else {
                            best = sim
                        }
                    }
                }
                return best
            }
            if let best = bestVisual {
                signals.append((best, 0.36, 0.22, "图像特征接近"))
            }
        }
        if !precomputedTargetColors.isEmpty {
            let similarity: Double
            if colors.isEmpty {
                // Asset-to-asset palette harmony: weighted average CIEDE2000 across dominant swatches
                // so tiny white/black margins don't falsely match unrelated images.
                if let avgDelta = Self.weightedPaletteDistancePrepared(asset.dominantColors, precomputedTargetColors) {
                    if avgDelta <= 6.0 {
                        similarity = 1.0
                    } else if avgDelta < 22.0 {
                        similarity = pow((22.0 - avgDelta) / 16.0, 1.1)
                    } else {
                        similarity = 0.0
                    }
                } else {
                    similarity = 0.0
                }
            } else {
                // Explicit target swatch query (palette seed / board palette): match significant swatches
                let distance = Self.significantSwatchDistancePrepared(asset.dominantColors, precomputedTargetColors)
                similarity = distance.map { d in
                    if d <= tolerance { return 1.0 - d / max(1.0, tolerance) * 0.35 }
                    let cutoff = max(tolerance * 1.6, tolerance + 14.0)
                    guard d < cutoff else { return 0.0 }
                    return 0.30 * ((cutoff - d) / max(1.0, cutoff - tolerance))
                } ?? 0.0
            }
            signals.append((similarity, colors.isEmpty ? 0.24 : 0.44, 0.35, "配色相近"))
        }
        if !seedTagSets.isEmpty {
            let overlap: Double
            if asset.tags.isEmpty && asset.suggestedTags.isEmpty {
                overlap = 0
            } else {
                let tags = Set((asset.tags + asset.suggestedTags).map(SearchText.normalize)).filter { !$0.isEmpty }
                var maxOverlap = 0.0
                if !tags.isEmpty {
                    for peers in seedTagSets where !peers.isEmpty {
                        let inter = peers.intersection(tags).count
                        if inter > 0 {
                            let unionCount = peers.count + tags.count - inter
                            let jaccard = Double(inter) / Double(max(1, unionCount))
                            if jaccard > maxOverlap { maxOverlap = jaccard }
                        }
                    }
                }
                overlap = maxOverlap
            }
            signals.append((overlap, 0.18, 0.20, "相同标签"))
        }
        let sum = signals.reduce(0) { $0 + $1.value * $1.weight }
        let signalCapacity = max(0.35, signals.reduce(0) { $0 + $1.weight })
        let rating = Double(min(5, max(0, asset.rating))) / 5
        let qualifiedReasons = signals
            .filter { $0.value >= $0.threshold }
            .sorted { $0.value * $0.weight > $1.value * $1.weight }
            .map(\.reason)
        // Only add rating nudge when at least one real similarity signal matched!
        let baseScore = sum / signalCapacity
        let finalScore = qualifiedReasons.isEmpty ? baseScore : min(1, 0.06 * rating + 0.94 * baseScore)
        return ScoredAsset(asset: asset, score: finalScore, matchReasons: qualifiedReasons)
    }

    func redundancy(
        _ lhs: AssetRecord,
        _ rhs: AssetRecord,
        featurePrints: [UUID: VNFeaturePrintObservation] = [:]
    ) -> Double {
        if !lhs.contentHash.isEmpty, lhs.contentHash == rhs.contentHash { return 1 }
        let l = vectors[lhs.id]
        let r = vectors[rhs.id]
        var result = 0.0
        if let a = l?.embedding, let b = r?.embedding, l?.embeddingModel == r?.embeddingModel {
            result = max(result, Self.cosine(a, b) * 0.92)
        }
        if let obsA = featurePrints[lhs.id], let obsB = featurePrints[rhs.id],
           let distance = VisionAnalyzer.visualDistance(between: obsA, and: obsB) {
            result = max(result, VisionAnalyzer.visualSimilarity(forDistance: distance))
        } else if featurePrints.isEmpty, let a = l?.featurePrint, let b = r?.featurePrint,
                  let distance = VisionAnalyzer.visualDistance(between: a, and: b) {
            result = max(result, VisionAnalyzer.visualSimilarity(forDistance: distance))
        }
        if let distance = Self.weightedPaletteDistance(Array(lhs.dominantColors.prefix(2)), Array(rhs.dominantColors.prefix(2))) {
            result = max(result, 0.55 * exp(-distance / 17))
        }
        return result
    }

    private static func significantSwatches(_ colors: [LabColor], maxCount: Int) -> [LabColor] {
        let valid = colors.filter { $0.l.isFinite && $0.a.isFinite && $0.b.isFinite }
        let hasProportions = valid.contains { $0.proportion > 0.001 }
        if hasProportions {
            let major = valid.filter { $0.proportion >= 0.08 }
            if !major.isEmpty { return Array(major.prefix(maxCount)) }
        }
        return Array(valid.prefix(maxCount))
    }

    /// Proportion-weighted average minimum CIEDE2000 from candidate's top dominant swatches to target palette.
    private static func weightedPaletteDistance(_ candidate: [LabColor], _ target: [LabColor]) -> Double? {
        let b = significantSwatches(target, maxCount: 4)
        return weightedPaletteDistancePrepared(candidate, b)
    }

    private static func weightedPaletteDistancePrepared(_ candidate: [LabColor], _ preparedTarget: [LabColor]) -> Double? {
        let a = significantSwatches(candidate, maxCount: 3)
        guard !a.isEmpty, !preparedTarget.isEmpty else { return nil }
        var weightedSum = 0.0
        var totalWeight = 0.0
        for swatch in a {
            var nearest = Double.infinity
            for targetSwatch in preparedTarget {
                let d = swatch.deltaE2000(to: targetSwatch)
                if d.isFinite && d < nearest { nearest = d }
            }
            guard nearest.isFinite else { continue }
            let w = swatch.proportion > 0.001 ? swatch.proportion : 1.0
            weightedSum += nearest * w
            totalWeight += w
        }
        guard totalWeight > 0 else { return nil }
        return weightedSum / totalWeight
    }

    private static func significantSwatchDistancePrepared(_ candidate: [LabColor], _ preparedTarget: [LabColor]) -> Double? {
        let a = significantSwatches(candidate, maxCount: 5)
        guard !a.isEmpty, !preparedTarget.isEmpty else { return nil }
        var best = Double.infinity
        for lhs in a {
            for rhs in preparedTarget {
                let d = lhs.deltaE2000(to: rhs)
                if d.isFinite && d < best { best = d }
            }
        }
        return best.isFinite ? best : nil
    }

    private static func cosine(_ a: [Float], _ b: [Float]) -> Double {
        guard a.count == b.count else { return 0 }
        var dot = 0.0, aa = 0.0, bb = 0.0
        for index in a.indices {
            let x = Double(a[index])
            let y = Double(b[index])
            dot += x * y
            aa += x * x
            bb += y * y
        }
        guard aa > 0, bb > 0, dot.isFinite else { return 0 }
        return min(1, max(0, dot / sqrt(aa * bb)))
    }
}
