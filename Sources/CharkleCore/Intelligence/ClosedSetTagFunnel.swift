import Foundation
#if canImport(Vision)
import Vision
#endif

#if canImport(Vision)
/// Thread-safe lazy cache so each asset's `VNFeaturePrintObservation` is unarchived at most once
/// across an entire batch of thousands of assets (preventing O(N^2) `NSKeyedUnarchiver` churn).
private nonisolated final class FeaturePrintObservationCache: @unchecked Sendable {
    private let lock = NSLock()
    private let rawByID: [UUID: Data]
    private var decoded: [UUID: VNFeaturePrintObservation] = [:]
    private var failedIDs: Set<UUID> = []

    init(rawByID: [UUID: Data]) {
        self.rawByID = rawByID
    }

    func observation(for id: UUID) -> VNFeaturePrintObservation? {
        lock.lock()
        if let hit = decoded[id] {
            lock.unlock()
            return hit
        }
        if failedIDs.contains(id) {
            lock.unlock()
            return nil
        }
        lock.unlock()

        guard let data = rawByID[id] else { return nil }
        let obs = VisionAnalyzer.unarchiveFeaturePrint(data)

        lock.lock()
        if let obs {
            decoded[id] = obs
        } else {
            failedIDs.insert(id)
        }
        lock.unlock()
        return obs
    }
}
#endif

/// Builds a bounded, noise-filtered closed-set tag checklist (`<= 20` canonical tags by default) for any asset
/// using zero-cost local signals before sending a single TypeSafe System One (`Jev`) multi-`Noul` request:
///
/// 1. **Taxonomy & Singleton Hygiene**: Folds `LibraryTaxonomyPolicy.tagAliases` into canonical tags and
///    filters one-off singleton noise (`count == 1`) once a library has established `>= 12` repeated tags.
/// 2. **Visual Neighbor Funnel**: Uses cached local Apple Vision `FeaturePrint` similarity to surface tags from
///    visually similar assets (high recall even on completely untagged artwork).
/// 3. **Folder Prior + Global Backbone**: Combines current/parent folder tag distribution with top global
///    canonical tags, attaching co-occurring folder/tag context hints so abstract user tags stay grounded.
internal nonisolated struct ClosedSetTagFunnel: Sendable {
    private let aliasNormToCanonicalNorm: [String: String]
    private let canonicalSpelling: [String: String]
    private let aliasesByCanonicalNorm: [String: [String]]
    private let contextHintsByCanonicalNorm: [String: [String]]
    private let eligibleSortedByFrequency: [String]
    private let folderParentByID: [UUID: UUID]
    private let folderTagCounts: [UUID: [String: Int]]
    private let assetCanonicalEligibleTags: [UUID: [String]]
    #if canImport(Vision)
    private let featurePrintCache: FeaturePrintObservationCache
    #endif

    var eligibleTagCount: Int {
        eligibleSortedByFrequency.count
    }

    init(
        activeAssets: [AssetRecord],
        folders: [FolderRecord],
        featurePrints: [UUID: Data],
        taxonomy: LibraryTaxonomyPolicy = LibraryTaxonomyPolicy()
    ) {
        #if canImport(Vision)
        self.featurePrintCache = FeaturePrintObservationCache(rawByID: featurePrints)
        #endif

        var folderNameByID: [UUID: String] = [:]
        var parentByID: [UUID: UUID] = [:]
        for folder in folders {
            folderNameByID[folder.id] = folder.name
            if let pid = folder.parentID {
                parentByID[folder.id] = pid
            }
        }
        self.folderParentByID = parentByID

        // 1. Resolve taxonomy aliases -> canonical norm & spelling
        var aliasMap: [String: String] = [:]
        var preferredSpelling: [String: String] = [:]
        var reverseAliases: [String: [String]] = [:]
        var explicitCanonicalNorms = Set<String>()

        for (rawAlias, rawTarget) in taxonomy.tagAliases {
            let alias = rawAlias.trimmingCharacters(in: .whitespacesAndNewlines)
            let target = rawTarget.trimmingCharacters(in: .whitespacesAndNewlines)
            let aliasNorm = SearchText.normalize(alias)
            let targetNorm = SearchText.normalize(target)
            guard !aliasNorm.isEmpty, !targetNorm.isEmpty, aliasNorm != targetNorm else { continue }
            aliasMap[aliasNorm] = targetNorm
            preferredSpelling[targetNorm] = target
            explicitCanonicalNorms.insert(targetNorm)
            reverseAliases[targetNorm, default: []].append(alias)
        }
        self.aliasNormToCanonicalNorm = aliasMap
        self.aliasesByCanonicalNorm = reverseAliases.mapValues { Array(Set($0)).sorted() }

        func resolveNorm(_ raw: String) -> (norm: String, trimmed: String)? {
            let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            let rawNorm = SearchText.normalize(trimmed)
            guard !rawNorm.isEmpty else { return nil }
            let canonical = aliasMap[rawNorm] ?? rawNorm
            return (canonical, trimmed)
        }

        // 2. Single pass over active assets to gather canonical counts, spelling votes, folder & co-occurrence context
        var tagFreq: [String: Int] = [:]
        var spellingVotes: [String: [String: Int]] = [:]
        var perFolderTags: [UUID: [String: Int]] = [:]
        var tagFolderCooc: [String: [String: Int]] = [:]
        var tagTagCooc: [String: [String: Int]] = [:]
        var rawAssetCanonicalTags: [UUID: [String]] = [:]
        rawAssetCanonicalTags.reserveCapacity(activeAssets.count)

        for asset in activeAssets where !asset.isTrashed && !asset.tags.isEmpty {
            var assetNorms: [String] = []
            var seenOnAsset = Set<String>()
            for rawTag in asset.tags {
                guard let resolved = resolveNorm(rawTag) else { continue }
                guard seenOnAsset.insert(resolved.norm).inserted else { continue }
                assetNorms.append(resolved.norm)
                tagFreq[resolved.norm, default: 0] += 1
                if aliasMap[SearchText.normalize(resolved.trimmed)] == nil {
                    spellingVotes[resolved.norm, default: [:]][resolved.trimmed, default: 0] += 1
                }
                if let fid = asset.folderID {
                    perFolderTags[fid, default: [:]][resolved.norm, default: 0] += 1
                    if let folderName = folderNameByID[fid] {
                        tagFolderCooc[resolved.norm, default: [:]][folderName, default: 0] += 1
                    }
                }
            }
            if !assetNorms.isEmpty {
                rawAssetCanonicalTags[asset.id] = assetNorms
                if assetNorms.count <= 12 {
                    for i in assetNorms.indices {
                        let a = assetNorms[i]
                        for j in assetNorms.indices where i != j {
                            tagTagCooc[a, default: [:]][assetNorms[j], default: 0] += 1
                        }
                    }
                }
            }
        }

        var resolvedSpelling = preferredSpelling
        for (norm, votes) in spellingVotes where resolvedSpelling[norm] == nil {
            if let best = votes.max(by: { lhs, rhs in
                if lhs.value != rhs.value { return lhs.value < rhs.value }
                return lhs.key > rhs.key
            })?.key {
                resolvedSpelling[norm] = best
            }
        }
        self.canonicalSpelling = resolvedSpelling
        self.folderTagCounts = perFolderTags

        // 3. Anti-singleton noise hygiene: once a library has >= 12 repeated tags, exclude one-off singletons
        //    so legacy orphan tags never crowd out proven canonical vocabulary.
        let repeatedNorms = tagFreq.compactMap { $0.value >= 2 ? $0.key : nil }
        let eligibleSet: Set<String>
        if repeatedNorms.count >= 12 {
            eligibleSet = Set(repeatedNorms).union(explicitCanonicalNorms)
        } else {
            eligibleSet = Set(tagFreq.keys).union(explicitCanonicalNorms)
        }

        self.eligibleSortedByFrequency = eligibleSet
            .filter { resolvedSpelling[$0] != nil }
            .sorted { lhs, rhs in
                let lf = tagFreq[lhs] ?? 0
                let rf = tagFreq[rhs] ?? 0
                if lf != rf { return lf > rf }
                let ls = resolvedSpelling[lhs] ?? lhs
                let rs = resolvedSpelling[rhs] ?? rhs
                return ls.localizedStandardCompare(rs) == .orderedAscending
            }

        var filteredAssetTags: [UUID: [String]] = [:]
        filteredAssetTags.reserveCapacity(rawAssetCanonicalTags.count)
        for (id, norms) in rawAssetCanonicalTags {
            let kept = norms.filter { eligibleSet.contains($0) }
            if !kept.isEmpty {
                filteredAssetTags[id] = kept
            }
        }
        self.assetCanonicalEligibleTags = filteredAssetTags

        // 4. Synthesize compact semantic context hints (top 2 folders + top 2 co-occurring canonical tags)
        var hintsByNorm: [String: [String]] = [:]
        for norm in self.eligibleSortedByFrequency {
            var hints: [String] = []
            if let folderCounts = tagFolderCooc[norm] {
                let topFolders = folderCounts
                    .sorted { $0.value != $1.value ? $0.value > $1.value : $0.key < $1.key }
                    .prefix(2)
                    .map(\.key)
                hints.append(contentsOf: topFolders)
            }
            if let coTags = tagTagCooc[norm] {
                let topCo = coTags
                    .filter { eligibleSet.contains($0.key) && resolvedSpelling[$0.key] != nil }
                    .sorted { $0.value != $1.value ? $0.value > $1.value : $0.key < $1.key }
                    .prefix(2)
                    .compactMap { resolvedSpelling[$0.key] }
                hints.append(contentsOf: topCo)
            }
            if !hints.isEmpty {
                hintsByNorm[norm] = hints
            }
        }
        self.contextHintsByCanonicalNorm = hintsByNorm
    }

    func selectCandidates(for asset: AssetRecord, maxCandidates: Int = 20) -> [ClosedSetTagOption] {
        let cap = max(1, min(32, maxCandidates))
        var existingNorms = Set<String>()
        for rawTag in asset.tags {
            let rawNorm = SearchText.normalize(rawTag)
            if !rawNorm.isEmpty {
                existingNorms.insert(aliasNormToCanonicalNorm[rawNorm] ?? rawNorm)
            }
        }

        let available = eligibleSortedByFrequency.filter { !existingNorms.contains($0) }
        guard !available.isEmpty else { return [] }

        if available.count <= cap {
            return available.compactMap(makeOption(for:))
        }

        var pickedNorms: [String] = []
        pickedNorms.reserveCapacity(cap)
        var pickedSet = Set<String>()

        func appendIfNew(_ norm: String) {
            guard pickedNorms.count < cap,
                  !existingNorms.contains(norm),
                  canonicalSpelling[norm] != nil,
                  pickedSet.insert(norm).inserted else { return }
            pickedNorms.append(norm)
        }

        // Signal 1: Visual Neighbor Tags via cached local Apple Vision FeaturePrint (up to half of cap)
        #if canImport(Vision)
        if let targetObs = featurePrintCache.observation(for: asset.id) {
            var neighborSimilarities: [(id: UUID, similarity: Double)] = []
            for (otherID, otherTags) in assetCanonicalEligibleTags where otherID != asset.id && !otherTags.isEmpty {
                guard let otherObs = featurePrintCache.observation(for: otherID),
                      let dist = VisionAnalyzer.visualDistance(between: targetObs, and: otherObs) else {
                    continue
                }
                let sim = VisionAnalyzer.visualSimilarity(forDistance: dist)
                if sim >= 0.35 {
                    neighborSimilarities.append((otherID, sim))
                }
            }
            if !neighborSimilarities.isEmpty {
                let topNeighbors = neighborSimilarities
                    .sorted { $0.similarity > $1.similarity }
                    .prefix(12)
                var visualTagScores: [String: Double] = [:]
                for neighbor in topNeighbors {
                    for norm in assetCanonicalEligibleTags[neighbor.id] ?? [] where !existingNorms.contains(norm) {
                        visualTagScores[norm, default: 0] += neighbor.similarity
                    }
                }
                let visualBudget = min(max(6, cap / 2), cap)
                for (norm, _) in visualTagScores
                    .sorted(by: { lhs, rhs in
                        if abs(lhs.value - rhs.value) > 0.001 { return lhs.value > rhs.value }
                        return lhs.key < rhs.key
                    })
                    .prefix(visualBudget) {
                    appendIfNew(norm)
                }
            }
        }
        #endif

        // Signal 2: Same-folder & parent-folder tag prior (up to 35% of cap)
        if let fid = asset.folderID {
            var folderScores: [String: Double] = [:]
            for (norm, count) in folderTagCounts[fid] ?? [:] where !existingNorms.contains(norm) {
                folderScores[norm, default: 0] += Double(count)
            }
            if let parentID = folderParentByID[fid] {
                for (norm, count) in folderTagCounts[parentID] ?? [:] where !existingNorms.contains(norm) {
                    folderScores[norm, default: 0] += Double(count) * 0.45
                }
            }
            let folderBudget = max(4, Int((Double(cap) * 0.35).rounded()))
            let folderStartCount = pickedNorms.count
            for (norm, _) in folderScores.sorted(by: { lhs, rhs in
                if abs(lhs.value - rhs.value) > 0.001 { return lhs.value > rhs.value }
                return lhs.key < rhs.key
            }) {
                if pickedNorms.count - folderStartCount >= folderBudget || pickedNorms.count >= cap { break }
                appendIfNew(norm)
            }
        }

        // Signal 3: Global highest-frequency canonical backbone tags (fill remaining slots up to cap)
        for norm in available {
            if pickedNorms.count >= cap { break }
            appendIfNew(norm)
        }

        return pickedNorms.compactMap(makeOption(for:))
    }

    private func makeOption(for norm: String) -> ClosedSetTagOption? {
        guard let name = canonicalSpelling[norm] else { return nil }
        return ClosedSetTagOption(
            name: name,
            aliases: aliasesByCanonicalNorm[norm] ?? [],
            contextHints: contextHintsByCanonicalNorm[norm] ?? []
        )
    }
}
