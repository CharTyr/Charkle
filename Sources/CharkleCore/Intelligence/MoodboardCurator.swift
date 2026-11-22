import Foundation

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
        let available = assets.filter { !seedIDs.contains($0.id) }
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
        let matches = assets.filter { !existing.contains($0.id) }.map { evidence.score($0) }
        return rerank(matches, evidence: evidence, against: [], limit: limit)
    }

    public func similarAssets(to assetID: UUID, limit: Int) async throws -> [ScoredAsset] {
        try await replacementCandidates(for: assetID, excluding: [], boardContext: [], limit: limit)
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
        var redundancy = pool.map { candidate in seeds.map { evidence.redundancy(candidate.asset, $0) }.max() ?? 0 }
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
                    redundancy[index] = max(redundancy[index], evidence.redundancy(pool[best].asset, pool[index].asset))
                }
            }
        }
        return results
    }

    static func palette(_ input: [LabColor], count: Int) -> [LabColor] {
        guard count > 0 else { return [] }
        var groups: [LabColor] = []
        for swatch in input.sorted(by: { ($0.proportion, $0.hex) > ($1.proportion, $1.hex) }) {
            guard swatch.l.isFinite, swatch.a.isFinite, swatch.b.isFinite else { continue }
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
            let ratios = row.map { min(2.1, max(0.6, $0.aspectRatio)) }
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
    var colors: [LabColor] = []
    var tolerance: Double = 28
    var ranks: [UUID: Double] = [:]
    var queryVector: [Float]?
    var embeddingIdentity: String?
    let vectors: [UUID: AssetVector]

    func score(_ asset: AssetRecord) -> ScoredAsset {
        var signals: [(Double, Double, String)] = []
        if !ranks.isEmpty {
            signals.append((ranks[asset.id] ?? 0, 0.48, "关键词匹配"))
        }
        if let vector = vectors[asset.id], let embedding = vector.embedding {
            var cloud: [Double] = []
            if let queryVector, vector.embeddingModel == embeddingIdentity {
                cloud.append(Self.cosine(embedding, queryVector))
            }
            for seed in seeds {
                if let other = vectors[seed.id], other.embeddingModel == vector.embeddingModel, let values = other.embedding {
                    cloud.append(Self.cosine(embedding, values))
                }
            }
            if let best = cloud.max() { signals.append((best, 0.40, Self.cloudReason)) }
        }
        if let print = vectors[asset.id]?.featurePrint {
            let similarities = seeds.compactMap { vectors[$0.id]?.featurePrint }
                .compactMap { VisionAnalyzer.visualDistance(between: print, and: $0) }
                .map { exp(-Double($0) * 1.4) }
            if let best = similarities.max() { signals.append((best, 0.30, "图像特征接近")) }
        }
        let targetColors = colors.isEmpty ? seeds.flatMap { $0.dominantColors.prefix(3) } : colors
        if !targetColors.isEmpty {
            let distance = Self.colorDistance(asset.dominantColors, targetColors)
            let similarity = distance.map {
                if colors.isEmpty { return exp(-$0 / 22) }
                if $0 <= tolerance { return 1 - $0 / max(1, tolerance) * 0.35 }
                return 0.28 * exp(-($0 - tolerance) / 22)
            } ?? 0
            signals.append((similarity, colors.isEmpty ? 0.22 : 0.44, "配色相近"))
        }
        if !seeds.isEmpty {
            let tags = Set(asset.tags.map(SearchText.normalize))
            let overlap = seeds.map { seed -> Double in
                let peers = Set(seed.tags.map(SearchText.normalize))
                return Double(peers.intersection(tags).count) / Double(max(1, peers.union(tags).count))
            }.max() ?? 0
            signals.append((overlap, 0.18, "相同标签"))
        }
        let sum = signals.reduce(0) { $0 + $1.0 * $1.1 }
        let signalCapacity = max(0.35, signals.reduce(0) { $0 + $1.1 })
        let rating = Double(min(5, max(0, asset.rating))) / 5
        return ScoredAsset(asset: asset, score: min(1, 0.08 * rating + 0.92 * sum / signalCapacity),
                           matchReasons: signals.filter { $0.0 > 0.18 }.map { $0.2 })
    }

    func redundancy(_ lhs: AssetRecord, _ rhs: AssetRecord) -> Double {
        if !lhs.contentHash.isEmpty, lhs.contentHash == rhs.contentHash { return 1 }
        let l = vectors[lhs.id]
        let r = vectors[rhs.id]
        var result = 0.0
        if let a = l?.embedding, let b = r?.embedding, l?.embeddingModel == r?.embeddingModel {
            result = max(result, Self.cosine(a, b) * 0.92)
        }
        if let a = l?.featurePrint, let b = r?.featurePrint,
           let distance = VisionAnalyzer.visualDistance(between: a, and: b) {
            result = max(result, exp(-Double(distance) * 1.6))
        }
        if let distance = Self.colorDistance(Array(lhs.dominantColors.prefix(2)), Array(rhs.dominantColors.prefix(2))) {
            result = max(result, 0.55 * exp(-distance / 17))
        }
        return result
    }

    private static func colorDistance(_ a: [LabColor], _ b: [LabColor]) -> Double? {
        a.prefix(8).flatMap { lhs in b.map { lhs.deltaE2000(to: $0) } }.filter(\.isFinite).min()
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
