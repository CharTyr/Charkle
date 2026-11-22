import Foundation
import Testing
@testable import CharkleCore

@Suite("Moodboard curation")
struct MoodboardCuratorTests {
    enum SeedCase: CaseIterable {
        case prompt, image, palette, manual, combined
    }

    @Test("All seed cases produce balanced draft nodes, a palette, and distinct candidates", arguments: SeedCase.allCases)
    func draft(_ kind: SeedCase) async throws {
        let db = try LibraryDatabase()
        let tags = ["ceramic", "field", "light"]
        let warm = LabColor.fromHex("#CB7658")
        let palette = ["#CB7658", "#F1D3AD", "#203644", "#82945B", "#DE9748", "#CDBEC5"].map { LabColor.fromHex($0) }
        let assets = (0..<12).map { index in
            AssetRecord(title: index < 5 ? "陶瓷 ceramic \(index)" : "Study \(index)", fileName: "\(index).png",
                        contentHash: "image-\(index)", tags: [tags[index % tags.count]],
                        dominantColors: [palette[index % palette.count], palette[(index + 2) % palette.count]],
                        rating: 5 - index % 4)
        }
        try await db.upsertAssets(assets)
        let seed: MoodboardSeed = switch kind {
        case .prompt: .prompt("taoci")
        case .image: .seedAssets([assets[1].id])
        case .palette: .palette([warm], tolerance: 9)
        case .manual: .manualSelection([assets[3].id, assets[0].id, assets[2].id])
        case .combined: .combined(prompt: "ceramic", seedAssetIDs: [assets[0].id], palette: [warm])
        }
        let curator = MoodboardCurator(database: db)
        let result = try await curator.proposeMoodboard(seed: seed, primaryCount: 4, candidateCount: 5)
        #expect(result.primaryMatches.count == (kind == .manual ? 3 : 4))
        #expect(result.candidatePool.count == 5)
        #expect(Set(result.primaryMatches.map(\.id)).isDisjoint(with: result.candidatePool.map(\.id)))
        #expect(result.draftDocument.referencedAssetIDs == result.primaryMatches.map(\.id))
        #expect(result.draftDocument.candidateAssetIDs == result.candidatePool.map(\.id))
        #expect(!result.extractedPalette.isEmpty && result.extractedPalette.count <= 6)
        let frames = result.draftDocument.nodes.map(\.frame)
        #expect(frames.allSatisfy { $0.width > 0 && $0.height > 0 })
        for (index, lhs) in frames.enumerated() {
            for rhs in frames.dropFirst(index + 1) {
                #expect(lhs.maxX <= rhs.minX || rhs.maxX <= lhs.minX || lhs.maxY <= rhs.minY || rhs.maxY <= lhs.minY)
            }
        }
        if kind == .prompt { #expect(result.primaryMatches.first?.matchReasons.contains("关键词匹配") == true) }
        if kind == .image { #expect(result.primaryMatches.first?.id == assets[1].id) }
        if kind == .manual { #expect(result.primaryMatches.map(\.id) == [assets[3].id, assets[0].id, assets[2].id]) }
        if kind == .combined { #expect(result.primaryMatches.first?.id == assets[0].id) }
        let grouped = try await curator.extractBoardPalette(assetIDs: assets.map(\.id), count: 6)
        #expect(grouped.count == 6)
        #expect(abs(grouped.reduce(0) { $0 + $1.proportion } - 1) < 0.0001)
    }

    @Test("MMR delays exact duplicates and replacement excludes the board and caller's exclusions")
    func diversity() async throws {
        let db = try LibraryDatabase()
        let red = LabColor.fromHex("#A8453D")
        let blue = LabColor.fromHex("#1E2E70")
        let clones = (0..<4).map {
            AssetRecord(title: "Chair \($0)", fileName: "chair\($0).png", contentHash: "same-content",
                        dominantColors: [red], rating: 5)
        }
        let alternative = AssetRecord(title: "Chair in blue", fileName: "blue.png", contentHash: "unique",
                                      dominantColors: [blue], rating: 4)
        try await db.upsertAssets(clones + [alternative])
        let curator = MoodboardCurator(database: db)
        let proposal = try await curator.proposeMoodboard(seed: .prompt("chair"), primaryCount: 2, candidateCount: 3)
        #expect(proposal.primaryMatches.contains { $0.id == alternative.id })
        let replacements = try await curator.replacementCandidates(for: clones[0].id, excluding: [clones[1].id],
                                                                   boardContext: [clones[2].id], limit: 4)
        // Strict anti-padding: red clone #3 matches by dominant color, while unrelated blue asset is NOT padded in.
        #expect(Set(replacements.map(\.id)) == [clones[3].id])
        #expect(try await curator.similarAssets(to: clones[0].id, limit: 1).count == 1)
    }

    @Test("Vision FeaturePrint calibration and similarity search refuse to pad unrelated assets")
    func calibratedVisualSimilarityAndNoPadding() async throws {
        // Vision Revision 2 L2 distances: genuine matches (< 0.95) score above reason threshold; unrelated (>= 0.95) are 0.
        #expect(VisionAnalyzer.visualSimilarity(forDistance: 0.35) == 1.0)
        #expect(VisionAnalyzer.visualSimilarity(forDistance: 0.69) > 0.45)
        #expect(VisionAnalyzer.visualSimilarity(forDistance: 0.84) > 0.22)
        #expect(VisionAnalyzer.visualSimilarity(forDistance: 0.95) == 0.0)
        #expect(VisionAnalyzer.visualSimilarity(forDistance: 1.12) == 0.0)

        let db = try LibraryDatabase()
        let warm = AssetRecord(title: "Warm Terracotta", fileName: "warm.png", contentHash: "h-warm",
                               tags: ["ceramic"], dominantColors: [LabColor.fromHex("#C85A3A")], rating: 5)
        let unrelated = AssetRecord(title: "Neon Cyan Grid", fileName: "cyan.png", contentHash: "h-cyan",
                                    tags: ["cyber"], dominantColors: [LabColor.fromHex("#00E5FF")], rating: 5)
        try await db.upsertAssets([warm, unrelated])
        let curator = MoodboardCurator(database: db)

        let similar = try await curator.similarAssets(to: warm.id, limit: 6)
        #expect(similar.isEmpty)
        let replacements = try await curator.replacementCandidates(for: warm.id, excluding: [], boardContext: [], limit: 6)
        #expect(replacements.isEmpty)
    }

    @Test("Compatible semantic embeddings affect prompt ranking and folder recommendations")
    func cloudAndFolder() async throws {
        let db = try LibraryDatabase()
        let folder = FolderRecord(name: "Ceramic")
        let prompt = "interior in mineral blue"
        let a = AssetRecord(title: "One", fileName: "one.jpg", tags: ["ceramic"])
        let b = AssetRecord(title: "Two", fileName: "two.jpg", folderID: folder.id, tags: ["ceramic"])
        let c = AssetRecord(title: "Three", fileName: "three.jpg")
        try await db.upsertFolder(folder)
        try await db.upsertAssets([a, b, c])
        let provider = FakeCloudAIProvider(embeddings: [prompt: [1, 0]])
        try await db.saveVector(AssetVector(embedding: [1, 0], embeddingModel: provider.embeddingIdentity), for: b.id)
        try await db.saveVector(AssetVector(embedding: [0, 1], embeddingModel: provider.embeddingIdentity), for: c.id)
        let curator = MoodboardCurator(database: db)
        let result = try await curator.proposeMoodboard(seed: .prompt(prompt), primaryCount: 1, candidateCount: 1, provider: provider)
        #expect(result.usedCloudAI)
        #expect(result.primaryMatches.first?.id == b.id)
        #expect(try await curator.suggestFolder(for: a.id)?.folderID == folder.id)
    }

    @Test("CIEDE2000 matches the published reference pair")
    func deltaEReference() {
        let a = LabColor(hex: "#000000", l: 50, a: 2.6772, b: -79.7751)
        let b = LabColor(hex: "#000000", l: 50, a: 0, b: -82.7485)
        #expect(abs(a.deltaE2000(to: b) - 2.0425) < 0.0001)
        #expect(abs(a.deltaE2000(to: b) - b.deltaE2000(to: a)) < 0.000001)
    }
}
