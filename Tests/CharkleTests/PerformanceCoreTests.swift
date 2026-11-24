import CoreGraphics
import Foundation
import Testing
@testable import CharkleCore

@Suite("CharkleCore Performance & Memory Regression Suite")
struct PerformanceCoreTests {
    private static func elapsedMilliseconds(_ duration: Duration) -> Double {
        Double(duration.components.seconds) * 1_000.0
            + Double(duration.components.attoseconds) / 1e15
    }

    private static func makeSyntheticLibrary(
        assetCount: Int = 2_000,
        folderCount: Int = 24
    ) -> (folders: [FolderRecord], assets: [AssetRecord]) {
        var folders: [FolderRecord] = []
        folders.reserveCapacity(folderCount)
        for idx in 0..<folderCount {
            let parentID: UUID? = idx < 6 ? nil : folders[idx % 6].id
            folders.append(FolderRecord(
                name: "Folder \(idx)",
                parentID: parentID,
                sortOrder: idx
            ))
        }

        let paletteHexes = [
            "#B15438", "#3B82F6", "#5F8F6D", "#D6A756",
            "#1E293B", "#E11D48", "#0F766E", "#64748B"
        ]
        let palette = paletteHexes.map { LabColor.fromHex($0, proportion: 0.25) }
        let tagPool = ["ui", "editorial", "lighting", "packaging", "ceramic", "motion", "typography", "architecture"]

        var assets: [AssetRecord] = []
        assets.reserveCapacity(assetCount)
        let baseDate = Date(timeIntervalSince1970: 1_750_000_000)

        for i in 0..<assetCount {
            let folderID: UUID? = (i % 7 == 0) ? nil : folders[i % folderCount].id
            let colors = [
                palette[i % palette.count],
                palette[(i + 3) % palette.count],
                palette[(i + 5) % palette.count]
            ]
            let tags = [tagPool[i % tagPool.count], tagPool[(i * 3 + 1) % tagPool.count]]
            let rich: AssetRichMetadata? = if i.isMultiple(of: 5) {
                AssetRichMetadata(photoExif: PhotoExifMetadata(
                    cameraMake: "Fujifilm",
                    cameraModel: "X100VI",
                    fNumber: 2.0,
                    iso: 400,
                    focalLengthMM: 23.0
                ))
            } else {
                nil
            }
            let title = i.isMultiple(of: 40) ? "京都雨夜参考 \(i)" : "Studio Reference \(i)"
            assets.append(AssetRecord(
                title: title,
                fileName: "asset-\(i).jpg",
                folderID: folderID,
                driveFileID: "drive-\(i)",
                contentHash: String(repeating: String(format: "%02x", i % 256), count: 32),
                mediaKind: i.isMultiple(of: 10) ? .video : .image,
                mimeType: i.isMultiple(of: 10) ? "video/mp4" : "image/jpeg",
                fileSizeBytes: Int64(120_000 + (i % 50) * 10_000),
                pixelWidth: 1600,
                pixelHeight: (i % 3 == 0) ? 2400 : 1200,
                notes: "Lighting study note \(i)",
                tags: tags,
                aiDescription: "Minimal studio composition \(i)",
                ocrText: i.isMultiple(of: 15) ? "CHAPTER \(i) STUDIO" : nil,
                dominantColors: colors,
                rating: i % 6,
                pinnedOffline: i < 20,
                isLocalOriginalCached: i % 2 == 0,
                isTrashed: i >= assetCount - 15,
                createdAt: baseDate.addingTimeInterval(Double(i) * 60.0),
                updatedAt: baseDate.addingTimeInterval(Double(i) * 60.0),
                richMetadata: rich
            ))
        }
        return (folders, assets)
    }

    @Test("Baseline & regression benchmark across CharkleCore memory layout, SQLite, MediaPipeline, SearchText, and Sync")
    func coreBenchmarks() async throws {
        // 1. Struct inline memory layout
        let assetStride = MemoryLayout<AssetRecord>.stride
        let richStride = MemoryLayout<AssetRichMetadata>.stride
        let optRichStride = MemoryLayout<AssetRichMetadata?>.stride
        print("[BENCH] MemoryLayout<AssetRecord>.stride = \(assetStride) B, AssetRichMetadata = \(richStride) B, Optional = \(optRichStride) B")

        // 2. Database setup (file-backed SQLite to reflect real WAL/mmap/statement behavior)
        let dir = try BackendFixture.directory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let dbURL = dir.appending(path: "bench.sqlite3")
        let db = try LibraryDatabase(url: dbURL)

        let (folders, assets) = Self.makeSyntheticLibrary(assetCount: 2_000, folderCount: 24)
        for folder in folders {
            try await db.upsertFolder(folder)
        }
        let tInsertStart = ContinuousClock.now
        try await db.upsertAssets(assets)
        let insertMs = Self.elapsedMilliseconds(tInsertStart.duration(to: .now))

        // Populate sync_state with realistic 2,000 clock entries + cleanup prefix test
        try await db.transaction { store in
            for asset in assets {
                try store.setState("clock.asset.\(asset.id.uuidString)", ["v": 1])
            }
            try store.setState("media.cleanup.\(UUID().uuidString)", true)
        }

        // 3. Repeated fetchAssets (simulating LibraryStore.refreshAll dual fetch + folder switches)
        let rootFolderID = folders[0].id
        let tColdFetch = ContinuousClock.now
        let allActive = try await db.fetchAssets(matching: FilterCriteria())
        let coldFetchMs = Self.elapsedMilliseconds(tColdFetch.duration(to: .now))
        #expect(allActive.count == 1_985)

        let tWarmFetch = ContinuousClock.now
        var fetchedTotal = 0
        for _ in 0..<10 {
            let full = try await db.fetchAssets(matching: FilterCriteria(includeTrashed: true))
            let subtree = try await db.fetchAssets(matching: FilterCriteria(folderID: rootFolderID, includeSubfolders: true))
            fetchedTotal &+= full.count + subtree.count
        }
        let warmFetch10xMs = Self.elapsedMilliseconds(tWarmFetch.duration(to: .now))
        #expect(fetchedTotal > 0)

        // 4. Color search query (10x)
        let tColor = ContinuousClock.now
        var colorHits = 0
        for _ in 0..<10 {
            let res = try await db.fetchAssets(matching: FilterCriteria(selectedColorHex: "#B15438", colorTolerance: 10))
            colorHits = res.count
        }
        let color10xMs = Self.elapsedMilliseconds(tColor.duration(to: .now))
        #expect(colorHits > 0)

        // 5. Folder fetch (20x) + states(withPrefix:) (50x) + quickJump (20x)
        let tFolders = ContinuousClock.now
        for _ in 0..<20 {
            let f = try await db.fetchFolders()
            #expect(f.count == 24)
        }
        let folders20xMs = Self.elapsedMilliseconds(tFolders.duration(to: .now))

        let tPrefix = ContinuousClock.now
        for _ in 0..<50 {
            let cleanups = try await db.states(withPrefix: "media.cleanup.", as: Bool.self)
            #expect(cleanups.count == 1)
        }
        let prefix50xMs = Self.elapsedMilliseconds(tPrefix.duration(to: .now))

        let tQuickJump = ContinuousClock.now
        for _ in 0..<20 {
            let hits = try await db.quickJump(query: "Folder 1", limit: 15)
            #expect(!hits.isEmpty)
        }
        let quickJump20xMs = Self.elapsedMilliseconds(tQuickJump.duration(to: .now))

        // 6. SmartFolderRule evaluation over 2,000 assets (20x)
        let rule = SmartFolderRule(
            matchMode: .all,
            tags: ["editorial"],
            descriptionQuery: "studio",
            colorHexes: ["#B15438"],
            colorTolerance: 18,
            mediaKinds: [.image],
            minRating: 4
        )
        let tSmart = ContinuousClock.now
        var smartCount = 0
        for _ in 0..<20 {
            smartCount = assets.reduce(into: 0) { acc, a in
                if rule.matches(a) { acc += 1 }
            }
        }
        let smart20xMs = Self.elapsedMilliseconds(tSmart.duration(to: .now))
        #expect(smartCount >= 0)

        // 7. MediaPipeline.cachedOriginal miss benchmark with 1,500 files in Originals/
        let media = try MediaPipeline(directory: dir.appending(path: "Media"))
        let dummyBytes = Data([0xFF, 0xD8, 0xFF, 0xD9])
        for i in 0..<1_500 {
            let fileURL = media.originals.appending(path: "\(UUID().uuidString).jpg")
            try dummyBytes.write(to: fileURL)
            if i == 0 { _ = fileURL }
        }
        let missingAssets = (0..<200).map { AssetRecord(title: "Cloud \($0)", fileName: "cloud-\($0).jpg") }
        let tOrigMiss = ContinuousClock.now
        var foundCount = 0
        for a in missingAssets {
            if media.cachedOriginal(for: a) != nil { foundCount += 1 }
        }
        let origMiss200xMs = Self.elapsedMilliseconds(tOrigMiss.duration(to: .now))
        #expect(foundCount == 0)

        // 8. EmbeddingPrecision float16 encode/decode (1,000 vectors x 768 dims)
        let vec = (0..<768).map { Float($0 % 97) / 97.0 - 0.5 }
        let tVec = ContinuousClock.now
        var vecChecksum: Float = 0
        for _ in 0..<500 {
            let encoded = EmbeddingPrecision.float16.encode(vec)
            let decoded = EmbeddingPrecision.float16.decode(encoded)
            vecChecksum += decoded[0]
        }
        let vec500xMs = Self.elapsedMilliseconds(tVec.duration(to: .now))
        #expect(vecChecksum.isFinite)

        // 9. ColorExtractor on 520x520 synthetic image (30x)
        let swatchImg = try #require(MediaArtwork.swatch(.fromHex("#B15438")))
        let tColorExt = ContinuousClock.now
        for _ in 0..<30 {
            let colors = ColorExtractor.extractDominantColors(from: swatchImg, count: 6)
            #expect(!colors.isEmpty)
        }
        let colorExt30xMs = Self.elapsedMilliseconds(tColorExt.duration(to: .now))

        // 10. SearchText.fuzzyScore across 2,000 mixed candidates
        let tFuzzy = ContinuousClock.now
        var fuzzyHits = 0
        for a in assets {
            if SearchText.fuzzyScore(query: "jdyy", candidate: a.title) != nil {
                fuzzyHits += 1
            }
        }
        let fuzzy2000Ms = Self.elapsedMilliseconds(tFuzzy.duration(to: .now))
        #expect(fuzzyHits == 50)

        print(String(
            format: "[BENCH] insert2000=%.1fms coldFetch=%.1fms warmFetch10x=%.1fms color10x=%.1fms folders20x=%.1fms prefix50x=%.1fms quickJump20x=%.1fms smartRule20x=%.1fms origMiss200x=%.1fms vec500x=%.1fms colorExt30x=%.1fms fuzzy2000=%.1fms",
            insertMs, coldFetchMs, warmFetch10xMs, color10xMs, folders20xMs, prefix50xMs, quickJump20xMs, smart20xMs, origMiss200xMs, vec500xMs, colorExt30xMs, fuzzy2000Ms
        ))

        // Regression guards (generous for Debug builds on contended CI hosts)
        #expect(assetStride <= 400)
        #expect(richStride == MemoryLayout<AnyObject>.stride)
        #expect(optRichStride == MemoryLayout<AnyObject>.stride)
        #expect(origMiss200xMs < 1_000)
        #expect(prefix50xMs < 200)
    }

    @Test("AssetRichMetadata keeps 8-byte inline footprint with value-type CoW and Codable/Hashable parity")
    func richMetadataCoWAndCodable() throws {
        #expect(MemoryLayout<AssetRichMetadata>.stride == 8)
        #expect(MemoryLayout<AssetRichMetadata?>.stride == 8)
        #expect(MemoryLayout<AssetRecord>.stride <= 400)

        var original = AssetRichMetadata(
            githubRepo: GitHubRepoMetadata(
                owner: "org",
                repo: "repo",
                fullName: "org/repo",
                description: "Reference library",
                stars: 420,
                forks: 30,
                language: "Swift",
                licenseName: "MIT",
                topics: ["macos", "graphics"],
                homepageURL: "https://example.com",
                fetchedAt: Date(timeIntervalSince1970: 1_750_000_000)
            ),
            socialPost: SocialPostMetadata(
                platform: .x,
                authorName: "Designer",
                authorHandle: "designer",
                bodyText: "Editorial lighting breakdown",
                originalURL: "https://x.com/user/status/1"
            ),
            photoExif: PhotoExifMetadata(
                cameraMake: "Fujifilm",
                cameraModel: "X100VI",
                lensModel: "23mm f/2",
                fNumber: 2.0,
                iso: 400,
                focalLengthMM: 23.0
            ),
            aiGeneration: AIGenerationMetadata(
                generator: "ComfyUI",
                prompt: "warm studio portrait",
                negativePrompt: "blurry",
                modelName: "flux-dev",
                sampler: "euler",
                steps: 28,
                cfgScale: 3.5,
                seed: "123456",
                loras: ["film_grain"]
            ),
            textExcerpt: "Design systems notes",
            isMarkdown: true,
            model3DFormat: "usdz"
        )

        var copy = original
        #expect(copy == original)
        #expect(copy.hashValue == original.hashValue)

        // Mutating copy must never mutate original (value semantics preserved)
        copy.photoExif?.iso = 1600
        copy.isMarkdown = false
        copy.textExcerpt = "Updated"
        copy.model3DFormat = "glb"
        #expect(original.photoExif?.iso == 400)
        #expect(original.isMarkdown == true)
        #expect(original.textExcerpt == "Design systems notes")
        #expect(original.model3DFormat == "usdz")
        #expect(copy != original)

        // Full Codable JSON round-trip
        let encoded = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(AssetRichMetadata.self, from: encoded)
        #expect(decoded == original)
        #expect(decoded.hashValue == original.hashValue)

        // Mutating original clears fields cleanly and matches empty metadata
        original.githubRepo = nil
        original.socialPost = nil
        original.photoExif = nil
        original.aiGeneration = nil
        original.textExcerpt = nil
        original.isMarkdown = false
        original.model3DFormat = nil
        #expect(original == AssetRichMetadata())
    }

    @Test("LibraryDatabase v3 indexes, rollback cache invalidation, external writer sync, and exact color/prefix queries")
    func databaseCacheCorrectnessAndIndexes() async throws {
        struct IntentionalRollback: Error {}

        let dir = try BackendFixture.directory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let dbURL = dir.appending(path: "cache-test.sqlite3")
        let db1 = try LibraryDatabase(url: dbURL)

        let root = FolderRecord(name: "Root")
        let child = FolderRecord(name: "Child", parentID: root.id)
        try await db1.upsertFolder(root)
        try await db1.upsertFolder(child)

        let terracotta = LabColor.fromHex("#B15438", proportion: 0.6)
        let slate = LabColor.fromHex("#1E293B", proportion: 0.7)
        let assetA = AssetRecord(
            title: "Original Title",
            fileName: "a.jpg",
            folderID: child.id,
            dominantColors: [terracotta]
        )
        let assetB = AssetRecord(
            title: "Second Asset",
            fileName: "b.jpg",
            folderID: root.id,
            dominantColors: [slate]
        )
        let trashed = AssetRecord(
            title: "Trashed Asset",
            fileName: "t.jpg",
            folderID: child.id,
            dominantColors: [terracotta],
            isTrashed: true
        )
        try await db1.upsertAssets([assetA, assetB, trashed])

        // Warm caches on db1
        let warm1 = try await db1.asset(id: assetA.id)
        #expect(warm1?.title == "Original Title")
        let subtreeBefore = try await db1.fetchAssets(matching: FilterCriteria(folderID: root.id, includeSubfolders: true))
        #expect(subtreeBefore.count == 2)

        // 1. Transaction rollback must invalidate mutated in-memory asset & folder caches
        do {
            try await db1.transaction { store in
                var mutated = assetA
                mutated.title = "Rolled Back Title"
                try store.put(mutated)
                let ghostFolder = FolderRecord(name: "Ghost", parentID: root.id)
                try store.put(ghostFolder)
                throw IntentionalRollback()
            }
            Issue.record("Expected rollback error")
        } catch is IntentionalRollback {
            // Expected
        }
        let afterRollback = try await db1.asset(id: assetA.id)
        #expect(afterRollback?.title == "Original Title")
        let foldersAfterRollback = try await db1.fetchFolders()
        #expect(foldersAfterRollback.count == 2)
        let countByID = Dictionary(uniqueKeysWithValues: foldersAfterRollback.map { ($0.id, $0.assetCount) })
        #expect(countByID[root.id] == 1)
        #expect(countByID[child.id] == 1) // trashed asset excluded

        // 2. External SQLite connection write must invalidate db1 caches via PRAGMA data_version
        let db2 = try LibraryDatabase(url: dbURL)
        var externalEdit = assetA
        externalEdit.title = "Updated Externally"
        try await db2.upsertAssets([externalEdit])

        let observedAfterExternal = try await db1.asset(id: assetA.id)
        #expect(observedAfterExternal?.title == "Updated Externally")
        let fetchedAfterExternal = try await db1.fetchAssets(matching: FilterCriteria())
        #expect(fetchedAfterExternal.first(where: { $0.id == assetA.id })?.title == "Updated Externally")

        // 3. Exact color bounding-box parity against brute-force CIELAB distance
        let targetHex = "#B15438"
        let targetLab = LabColor.fromHex(targetHex)
        let tolerance = 12.0
        let sqlMatches = Set(try await db1.fetchAssets(matching: FilterCriteria(
            selectedColorHex: targetHex,
            colorTolerance: tolerance
        )).map(\.id))
        let expectedMatches = Set([assetA, assetB].filter { asset in
            asset.dominantColors.contains { $0.deltaE(to: targetLab) <= tolerance }
        }.map(\.id))
        #expect(sqlMatches == expectedMatches)

        // 4. Prefix range scan boundary accuracy (ASCII + Unicode + adjacent keys + empty)
        try await db1.transaction { store in
            try store.setState("media.cleanup.1", true)
            try store.setState("media.cleanup.2", true)
            try store.setState("media.cleanup/", true) // ASCII '/' (0x2F) > '.' (0x2E) — must NOT match "media.cleanup."
            try store.setState("media.clean", true)
            try store.setState("前缀.a", true)
            try store.setState("前缀.b", true)
            try store.setState("前缀/c", true)
        }
        let dotPrefix = try await db1.states(withPrefix: "media.cleanup.", as: Bool.self).map(\.0).sorted()
        #expect(dotPrefix == ["media.cleanup.1", "media.cleanup.2"])
        let unicodePrefix = try await db1.states(withPrefix: "前缀.", as: Bool.self).map(\.0).sorted()
        #expect(unicodePrefix == ["前缀.a", "前缀.b"])

        // 5. Targeted payload substring helper & lightweight embeddings(forModel:)
        let payloadHits = try await db1.assetsWithPayloadContaining("Updated Externally")
        #expect(payloadHits.map(\.id) == [assetA.id])

        try await db1.saveVector(AssetVector(featurePrint: Data([1, 2, 3]), embedding: [0.25, -0.5, 0.75], embeddingModel: "clip-v1"), for: assetA.id)
        try await db1.saveVector(AssetVector(featurePrint: Data([4, 5, 6]), embedding: [0.1, 0.2, 0.3], embeddingModel: "other-v2"), for: assetB.id)
        let clipEmbeddings = try await db1.embeddings(forModel: "clip-v1")
        #expect(clipEmbeddings.count == 1)
        #expect(clipEmbeddings[assetA.id]?.count == 3)
        #expect(clipEmbeddings[assetB.id] == nil)

        // 6. Verify schema v3 indexes exist in sqlite_master
        let verifyConn = try SQLiteConnection(path: dbURL.path)
        let indexNames = Set(try verifyConn.query("SELECT name FROM sqlite_master WHERE type='index'") { $0.text(0) })
        #expect(indexNames.contains("assets_folder_recency"))
        #expect(indexNames.contains("assets_kind_recency"))
        #expect(indexNames.contains("assets_pinned"))
        #expect(indexNames.contains("asset_colors_lab"))
    }

    @Test("SmartFolderRule matches parity across .all/.any, multi-token search, tags, rating, and colors")
    func smartFolderRuleParity() {
        let asset = AssetRecord(
            title: "Warm Ceramic Bowl",
            fileName: "bowl-01.png",
            mediaKind: .image,
            sourceDomain: "studio.example",
            notes: "Natural side lighting",
            tags: ["Editorial", "Ceramic"],
            aiDescription: "Minimal terracotta table setup",
            ocrText: "EDITION 04",
            dominantColors: [LabColor.fromHex("#B15438", proportion: 0.7)],
            rating: 5
        )
        var trashed = asset
        trashed.isTrashed = true

        // Empty rule matches nothing (neither active nor trashed)
        #expect(SmartFolderRule().matches(asset) == false)
        #expect(SmartFolderRule().matches(trashed) == false)

        // Full `.all` match across every criterion
        let fullAll = SmartFolderRule(
            matchMode: .all,
            tags: ["ceramic", "EDITORIAL"],
            descriptionQuery: "bowl side terracotta edition",
            colorHexes: ["#B15438"],
            colorTolerance: 10,
            mediaKinds: [.image],
            minRating: 4
        )
        #expect(fullAll.matches(asset) == true)
        #expect(fullAll.matches(trashed) == false)

        // Failing any one criterion under `.all` returns false
        var wrongRating = fullAll
        wrongRating.minRating = 6
        #expect(wrongRating.matches(asset) == false)

        var wrongToken = fullAll
        wrongToken.descriptionQuery = "bowl nonexistent"
        #expect(wrongToken.matches(asset) == false)

        var wrongColor = fullAll
        wrongColor.colorHexes = ["#0000FF"]
        #expect(wrongColor.matches(asset) == false)

        // `.any` succeeds when just one criterion matches
        let anyRule = SmartFolderRule(
            matchMode: .any,
            tags: ["missing-tag"],
            descriptionQuery: "nope",
            colorHexes: ["#0000FF"],
            colorTolerance: 5,
            mediaKinds: [.video],
            minRating: 5
        )
        #expect(anyRule.matches(asset) == true)

        var anyFailing = anyRule
        anyFailing.minRating = 6
        #expect(anyFailing.matches(asset) == false)
    }

    @Test("MediaPipeline OriginalDirectoryIndex handles hits, misses, extension renames, and invalidation")
    func mediaPipelineOriginalIndexLifecycle() throws {
        let dir = try BackendFixture.directory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let media = try MediaPipeline(directory: dir.appending(path: "Media"))

        let source = dir.appending(path: "sample.jpg")
        try Data([0xFF, 0xD8, 0xFF, 0xD9]).write(to: source)
        let asset = AssetRecord(title: "Sample", fileName: "sample.jpg")

        // Cold miss populates index
        #expect(media.cachedOriginal(for: asset) == nil)

        // Install invalidates index and makes lookup hit immediately
        let installed = try media.installOriginal(source, for: asset)
        #expect(media.cachedOriginal(for: asset) == installed)

        // Renamed extension fallback (e.g. file saved as .webp while metadata still says .jpg)
        let webpAsset = AssetRecord(title: "Renamed", fileName: "renamed.jpg")
        let alternatePath = media.originals.appending(path: "\(webpAsset.id.uuidString).webp")
        try Data([0x52, 0x49, 0x46, 0x46]).write(to: alternatePath)
        #expect(media.cachedOriginal(for: webpAsset)?.lastPathComponent == "\(webpAsset.id.uuidString).webp")

        // Removing files invalidates index cleanly
        media.removeFiles(for: asset)
        #expect(media.cachedOriginal(for: asset) == nil)
    }

    @Test("EmbeddingPrecision float16/float32 round-trip accuracy and unaligned buffer decoding")
    func embeddingPrecisionRoundTrip() {
        #expect(EmbeddingPrecision.float16.encode([]).isEmpty)
        #expect(EmbeddingPrecision.float32.encode([]).isEmpty)
        #expect(EmbeddingPrecision.float16.decode(Data()).isEmpty)

        let values: [Float] = [-1.0, -0.375, 0.0, 0.125, 0.5, 1.0, 3.25]
        for precision in [EmbeddingPrecision.float16, .float32] {
            let encoded = precision.encode(values)
            let decoded = precision.decode(encoded)
            #expect(decoded.count == values.count)
            let tolerance: Float = precision == .float16 ? 0.002 : 0.000001
            for (lhs, rhs) in zip(values, decoded) {
                #expect(abs(lhs - rhs) <= tolerance)
            }

            // Force 1-byte unaligned Data slice to exercise unaligned decode fallback
            var padded = Data([0xAA])
            padded.append(encoded)
            let unalignedSlice = padded.dropFirst(1)
            let decodedUnaligned = precision.decode(unalignedSlice)
            #expect(decodedUnaligned == decoded)
        }
    }

    @Test("SearchText ASCII fast-path, Han pinyin matching, and ColorExtractor convergence")
    func searchTextAndColorExtractorCorrectness() throws {
        #expect(SearchText.normalize("  Studio REF 01 \n") == "studio ref 01")
        #expect(SearchText.normalize("already-clean") == "already-clean")
        #expect(SearchText.fuzzyScore(query: "studio", candidate: "Studio") == 1.0)
        #expect(SearchText.fuzzyScore(query: "stu", candidate: "Studio Reference") == 0.9)
        #expect(SearchText.fuzzyScore(query: "ref", candidate: "Studio Reference") == 0.8)
        #expect(SearchText.fuzzyScore(query: "jdyy", candidate: "京都雨夜参考") == 0.65)
        #expect(SearchText.fuzzyScore(query: "jingdu", candidate: "京都雨夜参考") == 0.75)
        #expect(SearchText.fuzzyScore(query: "京都", candidate: "Studio Reference") == nil)

        // Pure solid sRGB image convergence (1 cluster) + swatch card + two-tone image clustering
        let solidCtx = try #require(MediaArtwork.context(width: 64, height: 64))
        let sRGB = try #require(CGColorSpace(name: CGColorSpace.sRGB))
        let sRGBTerracotta = try #require(CGColor(colorSpace: sRGB, components: [0xB1 / 255.0, 0x54 / 255.0, 0x38 / 255.0, 1.0]))
        solidCtx.setFillColor(sRGBTerracotta)
        solidCtx.fill(CGRect(x: 0, y: 0, width: 64, height: 64))
        let pureSolid = try #require(solidCtx.makeImage())
        let solidColors = ColorExtractor.extractDominantColors(from: pureSolid, count: 6)
        #expect(solidColors.count == 1)
        #expect(solidColors[0].hex == "#B15438")
        #expect(solidColors[0].deltaE(to: .fromHex("#B15438")) < 0.01)

        let swatchCard = try #require(MediaArtwork.swatch(.fromHex("#B15438")))
        let swatchCardColors = ColorExtractor.extractDominantColors(from: swatchCard, count: 6)
        #expect(swatchCardColors.contains(where: { $0.deltaE(to: .fromHex("#B15438")) < 8.5 }))

        let ctx = try #require(MediaArtwork.context(width: 64, height: 64))
        ctx.setFillColor(CGColor(red: 0.9, green: 0.1, blue: 0.1, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: 32, height: 64))
        ctx.setFillColor(CGColor(red: 0.1, green: 0.3, blue: 0.9, alpha: 1))
        ctx.fill(CGRect(x: 32, y: 0, width: 32, height: 64))
        let splitImg = try #require(ctx.makeImage())
        let splitColors = ColorExtractor.extractDominantColors(from: splitImg, count: 4)
        #expect(splitColors.count == 2)
        let best = try #require(ColorExtractor.bestDeltaE(target: .fromHex("#E61A1A"), palette: splitColors))
        let expectedBest = splitColors.map { LabColor.fromHex("#E61A1A").deltaE(to: $0) }.min()!
        #expect(abs(best - expectedBest) < 1e-9)
    }
}
