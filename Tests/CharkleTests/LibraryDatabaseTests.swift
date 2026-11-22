import Foundation
import Testing
@testable import CharkleCore

@Suite("SQLite library")
struct LibraryDatabaseTests {
    @Test("FTS5 indexes all library fields, Mandarin syllables, and initials")
    func fullText() async throws {
        let db = try LibraryDatabase()
        let item = AssetRecord(title: "京都雨夜", fileName: "Street-17.png", sourceDomain: "example.org",
                               notes: "indigo reflections", tags: ["城市"], aiDescription: "雾气巷道",
                               ocrText: "North Lantern")
        let other = AssetRecord(title: "京都白昼", fileName: "Street-18.png")
        try await db.upsertAssets([item, other])
        for query in ["京都雨", "京都 城市", "jing du yu", "jingduyu", "jdyy", "street 17", "indigo",
                      "chengshi", "wqx", "north lan", "example org"] {
            let matches = try await db.fetchAssets(matching: FilterCriteria(searchQuery: query, sortBy: .relevance))
            #expect(matches.map(\.id) == [item.id], "query: \(query)")
        }
        #expect(try await db.fetchAssets(matching: FilterCriteria(searchQuery: #"京都" OR nonexistent*"#)).isEmpty)
        var updated = item
        updated.title = "东京夜景"
        try await db.upsertAssets([updated])
        #expect(try await db.fetchAssets(matching: FilterCriteria(searchQuery: "jdyy")).isEmpty)
        #expect(try await db.fetchAssets(matching: FilterCriteria(searchQuery: "dong jing")).map(\.id) == [item.id])
    }

    @Test("Quick Jump spans folders, boards, tags and assets in Chinese and Pinyin")
    func quickJump() async throws {
        let db = try LibraryDatabase()
        let folder = FolderRecord(name: "陶瓷")
        let board = MoodboardDocument(title: "陶瓷釉色")
        let asset = AssetRecord(title: "陶瓷摆件", fileName: "ceramic.png", folderID: folder.id, tags: ["陶瓷"])
        try await db.upsertFolder(folder)
        try await db.upsertBoard(board)
        try await db.upsertAssets([asset])
        for query in ["陶瓷", "tao ci", "taoci", "tc"] {
            let hits = try await db.quickJump(query: query, limit: 10)
            #expect(Set(hits.map(\.kind)) == [.moodboard, .folder, .tag, .asset], "query: \(query)")
        }
        #expect(try await db.quickJump(query: "", limit: 2).count == 2)
        #expect(try await db.fetchTagCounts() == [TagCount(name: "陶瓷", count: 1)])
        #expect(try await db.fetchFolders().first?.assetCount == 1)
    }

    @Test("Combined filters and ordering remain transactional")
    func combinedFilters() async throws {
        let db = try LibraryDatabase()
        let folder = FolderRecord(name: "Editorial")
        let terracotta = LabColor.fromHex("#B15438")
        let a = AssetRecord(title: "A", fileName: "a.png", folderID: folder.id, fileSizeBytes: 20,
                            pixelWidth: 1_100, pixelHeight: 1_600, tags: ["paper", "glaze"],
                            dominantColors: [terracotta], rating: 4, pinnedOffline: true)
        let b = AssetRecord(title: "B", fileName: "b.png", folderID: folder.id, fileSizeBytes: 120,
                            pixelWidth: 1_100, pixelHeight: 1_600, tags: ["paper"],
                            dominantColors: [.fromHex("#A34D36")], rating: 5)
        let c = AssetRecord(title: "C", fileName: "c.mov", mediaKind: .video, dominantColors: [.fromHex("#172AB5")],
                            rating: 5, isTrashed: true)
        let d = AssetRecord(title: "D", fileName: "d.md", mediaKind: .document, createdAt: .distantPast)
        try await db.upsertFolder(folder)
        try await db.upsertAssets([a, b, c, d])
        let exact = FilterCriteria(kinds: [.image], selectedColorHex: terracotta.hex, colorTolerance: 10,
                                   shape: .portrait, minRating: 4, tags: ["paper", "glaze"], folderID: folder.id,
                                   onlyRecentDays: 2, onlyPinnedOffline: true, sortBy: .fileSizeDesc)
        #expect(try await db.fetchAssets(matching: exact).map(\.id) == [a.id])
        #expect(try await db.fetchAssets(matching: FilterCriteria(folderID: folder.id, sortBy: .fileSizeDesc)).map(\.id)
                == [b.id, a.id])
        #expect(try await db.fetchAssets(matching: FilterCriteria(onlyInbox: true, onlyUntagged: true)).map(\.id) == [d.id])
        #expect(try await db.fetchAssets(matching: FilterCriteria(onlyTrashed: true)).map(\.id) == [c.id])
        #expect(try await db.fetchAssets(matching: FilterCriteria(includeTrashed: true, sortBy: .nameAsc)).map(\.id)
                == [a.id, b.id, c.id, d.id])
        #expect(try await db.fetchAssets(matching: FilterCriteria(sortBy: .oldest)).first?.id == d.id)

        struct Rollback: Error {}
        await #expect(throws: Rollback.self) {
            try await db.transaction { store in
                try store.removeAsset(a.id)
                throw Rollback()
            }
        }
        #expect(try await db.asset(id: a.id) != nil)
    }

    @Test("FTS and palette filters over 5,000 assets complete in under 100 ms")
    func queryPerformance() async throws {
        let db = try LibraryDatabase()
        let rows = (0..<5_000).map { index in
            AssetRecord(title: index.isMultiple(of: 100) ? "京都雨夜 \(index)" : "Reference \(index)",
                        fileName: "item-\(index).jpg", tags: ["reference"], dominantColors: [.fromHex("#AAC37A")])
        }
        try await db.upsertAssets(rows)
        let filter = FilterCriteria(searchQuery: "jdyy", selectedColorHex: "#ACC67D", colorTolerance: 8,
                                    tags: ["reference"], sortBy: .relevance)
        let start = ContinuousClock.now
        let result = try await db.fetchAssets(matching: filter)
        let elapsed = start.duration(to: .now)
        #expect(result.count == 50)
        #expect(elapsed < .milliseconds(100), "5,000-asset query took \(elapsed)")
    }

    @Test("Embedding BLOB round trip", arguments: [EmbeddingPrecision.float16, .float32])
    func vectors(_ precision: EmbeddingPrecision) async throws {
        let db = try LibraryDatabase()
        let asset = AssetRecord(title: "Test", fileName: "test.png")
        let values: [Float] = [0.5, -0.25, 0.03125, 1.625]
        try await db.upsertAssets([asset])
        try await db.saveVector(AssetVector(embedding: values, embeddingModel: "test", precision: precision), for: asset.id)
        try await db.saveVector(AssetVector(featurePrint: Data([8, 2])), for: asset.id)
        let vector = try #require(try await db.vector(for: asset.id))
        #expect(vector.featurePrint == Data([8, 2]))
        #expect(vector.embedding == values)
        #expect(vector.precision == precision)
        #expect(vector.embeddingModel == "test")
    }

    @Test("Disk persistence and schema migration retain library records")
    func reopen() async throws {
        let directory = try BackendFixture.directory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appending(path: "library.sqlite3")
        let id = UUID()
        do {
            let db = try LibraryDatabase(url: url)
            try await db.upsertAssets([AssetRecord(id: id, title: "Paper", fileName: "paper.png")])
            try await db.setState("roundTrip", 7)
        }
        let reopened = try LibraryDatabase(url: url)
        #expect(try await reopened.asset(id: id)?.title == "Paper")
        #expect(try await reopened.state("roundTrip", as: Int.self) == 7)
        #expect(try await reopened.fetchAssets(matching: FilterCriteria(searchQuery: "pap")).map(\.id) == [id])
    }
}
