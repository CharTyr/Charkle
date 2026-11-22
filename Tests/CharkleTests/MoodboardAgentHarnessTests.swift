@testable import CharkleCore
import Foundation
import ImageIO
import Testing

private actor InvocationCounter {
    var count: Int = 0
    var lastImageCount: Int = 0
    var lastPrompt: String = ""

    func record(imageCount: Int, prompt: String) -> Int {
        count += 1
        lastImageCount = imageCount
        lastPrompt = prompt
        return count
    }
}

@Suite("Moodboard Agent Harness & Visual Contact Sheets")
struct MoodboardAgentHarnessTests {
    private func makeSeededLibrary() async throws -> (root: URL, db: LibraryDatabase, media: MediaPipeline, assets: [AssetRecord]) {
        let dir = try BackendFixture.directory()
        let appSupport = dir.appending(path: "AppSupport", directoryHint: .isDirectory)
        let media = try MediaPipeline(directory: appSupport)
        let db = try LibraryDatabase(url: appSupport.appending(path: "Library.sqlite3"))
        let engine = LiveCharkleEngine(database: db, media: media)

        // Create 6 visually distinct images (3 warm editorial terracotta/sand, 3 cool neon/cyan UI)
        let specs: [(name: String, hex: String, tags: [String])] = [
            ("Warm Terracotta Poster.png", "#C86D51", ["editorial", "warm", "print"]),
            ("Sand Linen Editorial.png", "#DFC9B1", ["editorial", "warm"]),
            ("Amber Ceramic Vase.png", "#A95A3A", []), // Deliberately untagged — must still be discoverable via contact sheet!
            ("Cyberpunk Neon Grid.png", "#00E5FF", ["cyberpunk", "ui", "neon"]),
            ("Dark Crypto Dashboard.png", "#121726", ["ui", "fintech"]),
            ("Lime Acid Flyer.png", "#B7FF00", ["rave", "neon"])
        ]

        var imported: [AssetRecord] = []
        for spec in specs {
            let png = try BackendFixture.artwork(spec.hex)
            let created = try await engine.ingest(
                [.imageData(png, suggestedName: spec.name, sourceURL: nil)],
                targetFolderID: nil,
                targetBoardID: nil
            )
            let asset = try #require(created.first)
            if !spec.tags.isEmpty {
                _ = try await engine.updateAssets(AssetBatchPatch(assetIDs: [asset.id], addTags: spec.tags))
            }
            imported.append(try #require(await db.asset(id: asset.id)))
        }

        return (dir, db, media, imported)
    }

    @Test("ContactSheetRenderer produces valid multi-page JPEG sheets with deterministic integer slot grounding")
    func contactSheetRendersValidJPEGAndGrounding() async throws {
        let (dir, db, media, assets) = try await makeSeededLibrary()
        defer { try? FileManager.default.removeItem(at: dir) }

        let tools = CharkleAgentTools(database: db, media: media)
        let pkg = tools.buildContactSheets(
            for: assets,
            folderPathByID: [:],
            seedIDs: [],
            lockedIDs: [],
            existingBoardIDs: [],
            sheetCapacity: 4
        )

        #expect(pkg.sheets.count == 2)
        #expect(pkg.sheets[0].orderedSlots.map { $0.slot } == [1, 2, 3, 4])
        #expect(pkg.sheets[1].orderedSlots.map { $0.slot } == [5, 6])
        #expect(pkg.slotToAsset.count == 6)
        #expect(pkg.manifestText.contains("#01"))
        #expect(pkg.manifestText.contains("#06"))

        // Verify valid JPEG image bytes decode via ImageIO
        for sheet in pkg.sheets {
            #expect(sheet.jpegData.count > 1000)
            let source = try #require(CGImageSourceCreateWithData(sheet.jpegData as CFData, nil))
            let image = try #require(CGImageSourceCreateImageAtIndex(source, 0, nil))
            #expect(image.width == sheet.width)
            #expect(image.height == sheet.height)
        }
    }

    @Test("MoodboardAgentHarness inspects Contact Sheets, avoids padding, enforces locks/exclusions, and caches visual insights")
    func harnessCuratesWithAntiPaddingLocksAndInsightCaching() async throws {
        let (dir, db, media, assets) = try await makeSeededLibrary()
        defer { try? FileManager.default.removeItem(at: dir) }

        let counter = InvocationCounter()
        // Identify assets by title so our mock LLM picks deterministically regardless of recall order
        let harness = MoodboardAgentHarness(database: db, media: media)
        let tools = CharkleAgentTools(database: db, media: media)

        let terracotta = try #require(assets.first(where: { $0.title.contains("Terracotta") }))
        let ceramic = try #require(assets.first(where: { $0.title.contains("Ceramic") }))
        let neon = try #require(assets.first(where: { $0.title.contains("Neon") }))

        let provider = FakeCloudAIProvider { _, prompt, imageCount in
            _ = await counter.record(imageCount: imageCount, prompt: prompt)
            // Extract slot numbers directly from the grounded manifest text
            func slotFor(titleFragment: String) -> Int? {
                for line in prompt.components(separatedBy: .newlines) where line.contains(titleFragment) {
                    if let hashRange = line.range(of: "#"), line.distance(from: hashRange.upperBound, to: line.endIndex) >= 2 {
                        let digits = String(line[hashRange.upperBound...].prefix(2))
                        if let n = Int(digits) { return n }
                    }
                }
                return nil
            }

            let ceramicSlot = slotFor(titleFragment: "Ceramic") ?? 3
            let neonSlot = slotFor(titleFragment: "Neon") ?? 4
            // Deliberately:
            // 1. Pick ONLY ceramicSlot (untagged!) + hallucinate picking excluded neonSlot (must be stripped by verifier!)
            // 2. Omit locked terracotta (must be forcibly retained by verifier!)
            // 3. Emit visualInsights for the untagged Ceramic image so SQLite caches it lazily!
            return """
            {
              "boardTitle": "暖调陶土视觉方向",
              "boardSubtitle": "以哑光陶土与手工器皿为核心的温暖编辑视觉",
              "curatorNote": {
                "title": "视觉指导",
                "text": "控制饱和度在温润陶土区间，避免冷色霓虹干扰画面呼吸感。",
                "style": "paper"
              },
              "recommendedLayout": "magazine",
              "sections": [
                {
                  "title": "核心陶土与材质",
                  "tint": "terracotta",
                  "rationale": "哑光质感与暖棕主色调构成版面锚点",
                  "slots": [
                    { "slot": \(ceramicSlot), "weight": 2, "reason": "未打标但视觉呈暖陶土器皿质感" },
                    { "slot": \(neonSlot), "weight": 1, "reason": "尝试违规加入被排除的图" }
                  ]
                }
              ],
              "candidatePoolSlots": [],
              "rejectedNote": "已剔除冷色调界面与霓虹海报",
              "visualInsights": [
                {
                  "slot": \(ceramicSlot),
                  "description": "哑光琥珀陶土花器特写，柔和自然光",
                  "tags": ["ceramic", "warm-terracotta", "craft"]
                }
              ]
            }
            """
        }

        let request = MoodboardCurationRequest(
            prompt: "温暖哑光陶土手工艺编辑风",
            preferredCount: 8,
            layoutStyle: .magazine,
            useFreeformLayout: false,
            includeCuratorNotes: true,
            excludedAssetIDs: [neon.id],
            lockedAssetIDs: [terracotta.id]
        )

        let proposal = try await harness.curate(request: request, provider: provider)

        // 1. Contact Sheet JPEG was actually passed to the multimodal LLM
        #expect(await counter.lastImageCount >= 1)
        #expect(proposal.usedCloudAI == true)

        // 2. Anti-padding + Lock/Exclude Verification:
        //    Only ceramic (chosen) + terracotta (locked) should appear; excluded neon MUST NOT appear; unrelated cards MUST NOT pad!
        let primaryIDs = Set(proposal.primaryMatches.map(\.id))
        #expect(primaryIDs.contains(ceramic.id))
        #expect(primaryIDs.contains(terracotta.id))
        #expect(!primaryIDs.contains(neon.id))
        #expect(primaryIDs.count == 2)

        // 3. Board nodes contain note, groupFrame, hero weight 2 assetRef, and paletteStrip
        let nodes = proposal.draftDocument.nodes
        #expect(nodes.contains(where: { if case .note = $0.kind { return true } else { return false } }))
        #expect(nodes.contains(where: { if case .groupFrame = $0.kind { return true } else { return false } }))
        #expect(nodes.contains(where: { if case .paletteStrip = $0.kind { return true } else { return false } }))
        #expect(nodes.contains(where: {
            if case .assetRef(let id, _, let weight, _) = $0.kind { return id == ceramic.id && weight == 2 }
            return false
        }))

        // 4. Lazy visual insight caching persisted back into SQLite for the previously untagged Ceramic asset!
        #expect(proposal.cachedVisualInsightsCount == 1)
        let refreshedCeramic = try #require(await db.asset(id: ceramic.id))
        #expect((refreshedCeramic.aiDescription ?? "").contains("陶土"))
        #expect(refreshedCeramic.suggestedTags.contains("ceramic"))

        // Sanity-check libraryOverview tool also works cleanly
        let overview = try await tools.libraryOverview()
        #expect(overview.totalAssets == 6)
    }

    @Test("MoodboardAgentHarness automatically repairs malformed JSON in 1 repair turn and supports Freeform spatial layout")
    func harnessRepairsMalformedJSONAndBuildsFreeform() async throws {
        let (dir, db, media, assets) = try await makeSeededLibrary()
        defer { try? FileManager.default.removeItem(at: dir) }

        let counter = InvocationCounter()
        let harness = MoodboardAgentHarness(database: db, media: media)

        let provider = FakeCloudAIProvider { _, prompt, imageCount in
            let attempt = await counter.record(imageCount: imageCount, prompt: prompt)
            if attempt == 1 {
                return "Here is my thought process without valid JSON..."
            }
            return """
            ```json
            {
              "boardTitle": "自由画布排版",
              "boardSubtitle": "自动修复后的有效 JSON 策展方案",
              "curatorNote": { "title": "方向", "text": "高对比霓虹界面的自由拼贴。", "style": "accent" },
              "recommendedLayout": "compactGrid",
              "sections": [
                {
                  "title": "主视觉区",
                  "tint": "ocean",
                  "rationale": "聚焦高对比冷色 UI",
                  "slots": [
                    { "slot": 1, "weight": 2, "reason": "焦点卡片" },
                    { "slot": 2, "weight": 1, "reason": "辅助节奏" }
                  ]
                }
              ],
              "candidatePoolSlots": [{ "slot": 3, "weight": 1, "reason": "候选" }],
              "rejectedNote": null,
              "visualInsights": []
            }
            ```
            """
        }

        let req = MoodboardCurationRequest(
            prompt: "自由拼贴高对比界面",
            preferredCount: 6,
            useFreeformLayout: true,
            includeCuratorNotes: true
        )
        let proposal = try await harness.curate(request: req, provider: provider)

        #expect(await counter.count == 2)
        #expect(proposal.usedCloudAI == true)
        #expect(proposal.draftDocument.mode == .freeform)
        #expect(proposal.primaryMatches.count == 2)
        #expect(proposal.agentTrace.contains(where: { $0.phase == .repairing }))

        // Freeform nodes should have non-overlapping positive spatial dimensions inside groupFrame
        let assetNodes = proposal.draftDocument.nodes.filter { $0.referencedAssetID != nil }
        #expect(assetNodes.count == 2)
        for node in assetNodes {
            #expect(node.frame.width > 120)
            #expect(node.frame.height > 100)
        }
        _ = assets
    }

    @Test("Offline strict fallback never pads unrelated assets when a specific brief matches nothing")
    func offlineStrictFallbackAvoidsGarbagePadding() async throws {
        let (dir, db, media, _) = try await makeSeededLibrary()
        defer { try? FileManager.default.removeItem(at: dir) }

        let harness = MoodboardAgentHarness(database: db, media: media)
        let req = MoodboardCurationRequest(
            prompt: "完全不存在的中世纪蒸汽朋克飞艇机械蓝图",
            preferredCount: 12
        )

        let proposal = try await harness.curate(request: req, provider: nil)
        #expect(proposal.usedCloudAI == false)
        #expect(proposal.primaryMatches.isEmpty)
        #expect(proposal.draftDocument.referencedAssetIDs.isEmpty)
    }
}
