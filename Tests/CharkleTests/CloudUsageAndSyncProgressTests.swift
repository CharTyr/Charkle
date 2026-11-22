import CharkleCore
import Foundation
import Testing

@Suite("Cloud AI Usage & Live Sync Progress")
struct CloudUsageAndSyncProgressTests {
    @Test("CloudAIUsageStore tracks today & total usage, rolls over daily, and resets cleanly")
    func cloudUsageTrackingAndDailyRollover() {
        let suiteName = "com.charkle.tests.aiusage.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let store = CloudAIUsageStore(userDefaults: defaults, storageKey: "usage", postsNotifications: false)
        let day1 = Date(timeIntervalSince1970: 1_760_000_000)
        let day2 = day1.addingTimeInterval(86_400 * 2)

        store.record(providerLabel: "Google Gemini", model: "gemini-2.5-flash", inputTokens: 800, outputTokens: 250, now: day1)
        store.record(providerLabel: "ChatGPT 订阅", model: "gpt-5.4-mini", inputTokens: 1_200, outputTokens: 400, now: day1)

        let snap1 = store.snapshot(now: day1)
        #expect(snap1.todayRequests == 2)
        #expect(snap1.totalRequests == 2)
        #expect(snap1.todayInputTokens == 2_000)
        #expect(snap1.todayOutputTokens == 650)
        #expect(snap1.todayTotalTokens == 2_650)
        #expect(snap1.totalTokens == 2_650)
        #expect(snap1.lastProviderLabel == "ChatGPT 订阅")
        #expect(snap1.lastModel == "gpt-5.4-mini")
        #expect(snap1.lastCallTokens == 1_600)

        // Next day should roll over today counters while preserving all-time totals
        let snap2 = store.snapshot(now: day2)
        #expect(snap2.todayRequests == 0)
        #expect(snap2.todayTotalTokens == 0)
        #expect(snap2.totalRequests == 2)
        #expect(snap2.totalTokens == 2_650)

        // Token formatting
        #expect(CloudAIUsageSummary.formatTokenCount(842) == "842")
        #expect(CloudAIUsageSummary.formatTokenCount(1_250) == "1.25K")
        #expect(CloudAIUsageSummary.formatTokenCount(12_400) == "12.4K")
        #expect(CloudAIUsageSummary.formatTokenCount(1_250_000) == "1.25M")

        // Reset clears both today and total
        store.reset(now: day2)
        let afterReset = store.snapshot(now: day2)
        #expect(afterReset.todayRequests == 0)
        #expect(afterReset.totalRequests == 0)
        #expect(afterReset.totalTokens == 0)
    }

    @Test("CloudAIUsageStore tracks ordinary Cloud AI models and Jev judgment model independently")
    func separateStandardAndJevUsageBuckets() throws {
        let suiteName = "com.charkle.tests.aiusage.split.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let store = CloudAIUsageStore(userDefaults: defaults, storageKey: "usage", postsNotifications: false)
        let day1 = Date(timeIntervalSince1970: 1_760_100_000)
        let day2 = day1.addingTimeInterval(86_400 * 2)

        store.record(category: .standard, providerLabel: "Google Gemini", model: "gemini-2.5-flash", inputTokens: 1_000, outputTokens: 200, now: day1)
        store.record(category: .jev, providerLabel: "TypeSafe (Jev)", model: "jev-latest", inputTokens: 300, outputTokens: 50, now: day1.addingTimeInterval(10))
        store.record(category: .jev, providerLabel: "TypeSafe (Jev)", model: "jev-1.14.0", inputTokens: 450, outputTokens: 80, now: day1.addingTimeInterval(20))

        let snap = store.snapshot(now: day1)
        #expect(snap.standard.todayRequests == 1)
        #expect(snap.standard.totalTokens == 1_200)
        #expect(snap.standard.lastProviderLabel == "Google Gemini")
        #expect(snap.standard.lastModel == "gemini-2.5-flash")

        #expect(snap.jev.todayRequests == 2)
        #expect(snap.jev.totalRequests == 2)
        #expect(snap.jev.totalInputTokens == 750)
        #expect(snap.jev.totalOutputTokens == 130)
        #expect(snap.jev.totalTokens == 880)
        #expect(snap.jev.lastProviderLabel == "TypeSafe (Jev)")
        #expect(snap.jev.lastModel == "jev-1.14.0")

        // Combined totals still equal standard + jev
        #expect(snap.totalRequests == 3)
        #expect(snap.totalTokens == 2_080)

        // Daily rollover resets today counters for BOTH buckets while retaining cumulative totals
        let rolled = store.snapshot(now: day2)
        #expect(rolled.standard.todayRequests == 0)
        #expect(rolled.jev.todayRequests == 0)
        #expect(rolled.standard.totalRequests == 1)
        #expect(rolled.jev.totalRequests == 2)

        // Resetting ONLY Jev preserves ordinary model usage
        store.reset(category: .jev, now: day2)
        let afterJevReset = store.snapshot(now: day2)
        #expect(afterJevReset.jev.totalRequests == 0)
        #expect(afterJevReset.jev.totalTokens == 0)
        #expect(afterJevReset.standard.totalRequests == 1)
        #expect(afterJevReset.standard.totalTokens == 1_200)
        #expect(afterJevReset.totalRequests == 1)

        // Legacy persisted JSON without standard/jev keys migrates cleanly
        let legacyJSON = """
        {
            "dayKey": "2026-11-22",
            "todayRequests": 4,
            "todayInputTokens": 900,
            "todayOutputTokens": 100,
            "todayTotalTokens": 1000,
            "totalRequests": 9,
            "totalInputTokens": 2000,
            "totalOutputTokens": 500,
            "totalTokens": 2500,
            "lastProviderLabel": "TypeSafe (Jev)",
            "lastModel": "jev-latest",
            "lastCallTokens": 250
        }
        """
        let migrated = try JSONDecoder().decode(CloudAIUsageSummary.self, from: Data(legacyJSON.utf8))
        #expect(migrated.jev.totalRequests == 9)
        #expect(migrated.jev.totalTokens == 2_500)
        #expect(migrated.standard.totalRequests == 0)
    }

    @Test("CloudTagNormalizer enforces monolingual format and merges into existing library tags first")
    func tagNormalizationAndExistingTagMerging() {
        #expect(CloudTagNormalizer.preferredLanguage(for: ["zh-Hans-CN", "en-US"]) == .simplifiedChinese)
        #expect(CloudTagNormalizer.preferredLanguage(for: ["zh-Hant-TW", "en-US"]) == .traditionalChinese)
        #expect(CloudTagNormalizer.preferredLanguage(for: ["en-US", "zh-Hans-CN"]) == .english)

        let existingLibrary = ["极简", "插画", "海报", "字体", "暗黑"]
        let rawSuggested = [
            "#极简主义 (Minimalism)",
            "插画 / Illustration",
            "Poster | 海报",
            "Minimalist",
            "Typography",
            "赛博朋克 (Cyberpunk)",
            "Watercolor",
            "3D",
            "暗黑风"
        ]

        let normalized = CloudTagNormalizer.canonicalizeSuggestedTags(
            rawSuggested,
            existingLibraryTags: existingLibrary,
            existingAssetTags: ["海报"],
            language: .simplifiedChinese,
            maxCount: 6
        )

        // "海报" is already applied on the asset so it must not be suggested again
        #expect(!normalized.contains("海报"))
        // Existing library tags must be reused verbatim and placed first without near-duplicates
        #expect(normalized.prefix(4) == ["极简", "插画", "字体", "暗黑"])
        // Novel tags must be monolingual Simplified Chinese (no bilingual wrappers or raw English equivalents)
        #expect(normalized.contains("赛博朋克"))
        #expect(normalized.contains("水彩"))
        #expect(normalized.count == 6)
        #expect(normalized.allSatisfy { !$0.contains("/") && !$0.contains("(") && !$0.hasPrefix("#") })
    }

    @Test("IntelligenceEngine.enrich passes Existing Library Tags and dismissing old suggestions preserves confirmed tags")
    func retagPromptIncludesLibraryTagsAndDismissWorks() async throws {
        struct CapturingProvider: CloudAIProvider {
            let embeddingIdentity = "capture"
            let onEnrich: @Sendable (String) -> CloudEnrichmentResult

            func embed(_ text: String) async throws -> [Float] { [1, 0] }
            func enrich(text: String, thumbnailJPEG: Data?) async throws -> CloudEnrichmentResult {
                onEnrich(text)
            }
            func completeJSON(instructions: String, prompt: String, imagesJPEG: [Data]) async throws -> String { "{}" }
        }

        let directory = try BackendFixture.directory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let engine = try BackendFixture.makeEngine(directory.appending(path: "Retag"))
        let png = try BackendFixture.artwork("#4E7D96")
        let created = try await engine.ingest(
            [.imageData(png, suggestedName: "retag-sample.png", sourceURL: nil)],
            targetFolderID: nil,
            targetBoardID: nil
        )
        let assetID = try #require(created.first?.id)
        _ = try await engine.updateAssets(AssetBatchPatch(assetIDs: [assetID], addTags: ["海报"]))

        let box = SendablePromptBox()
        let provider = CapturingProvider { text in
            box.set(text)
            return CloudEnrichmentResult(
                description: "极简风格版式设计海报",
                suggestedTags: ["极简主义 (Minimalism)", "Typography", "海报"]
            )
        }

        let fetched = try #require(try await engine.fetchAsset(id: assetID))
        let intelligence = IntelligenceEngine()
        let result = try await intelligence.enrich(
            fetched,
            thumbnailURL: nil,
            provider: provider,
            existingLibraryTags: ["极简", "字体", "海报"]
        )
        #expect(box.get().contains("[Existing Library Tags]: 极简, 字体, 海报"))

        let canonical = CloudTagNormalizer.canonicalizeSuggestedTags(
            result.suggestedTags,
            existingLibraryTags: ["极简", "字体", "海报"],
            existingAssetTags: fetched.tags,
            language: .simplifiedChinese
        )
        #expect(canonical == ["极简", "字体"])
        #expect(!canonical.contains("海报"))

        // Verify dismissing old unaccepted suggestions preserves confirmed tags
        _ = try await engine.updateAssets(AssetBatchPatch(assetIDs: [assetID], dismissSuggestedTags: ["极简", "字体"]))
        let afterClear = try #require(try await engine.fetchAsset(id: assetID))
        #expect(afterClear.tags == ["海报"])
        #expect(afterClear.suggestedTags.isEmpty)
    }

    @Test("SyncStatus decodes legacy JSON backward-compatibly and exposes progress titles")
    func syncStatusBackwardCompatibleDecoding() throws {
        let legacyJSON = """
        {
            "phase": { "idle": {} },
            "pendingOpCount": 3,
            "activeMode": "directAPIWithGDirect"
        }
        """
        let decoded = try JSONDecoder().decode(SyncStatus.self, from: Data(legacyJSON.utf8))
        #expect(decoded.pendingOpCount == 3)
        #expect(decoded.activeMode == .directAPIWithGDirect)
        #expect(decoded.currentDetail == nil)
        #expect(decoded.progressFraction == nil)
        #expect(!decoded.isSyncing)

        let uploading = SyncStatus(
            phase: .uploading(completed: 2, total: 5),
            activeMode: .directAPIWithGDirect,
            currentDetail: "上传：poster.png",
            progressFraction: 0.68
        )
        #expect(uploading.isSyncing)
        #expect(uploading.localizedPhaseTitle == "正在上传 (2/5)")
    }
}

private final class SendablePromptBox: @unchecked Sendable {
    private let lock = NSLock()
    private var value: String = ""

    func set(_ newValue: String) {
        lock.lock()
        value = newValue
        lock.unlock()
    }

    func get() -> String {
        lock.lock()
        defer { lock.unlock() }
        return value
    }
}
