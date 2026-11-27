# Windows & Web Parity Handoff: Jev Zero-Hallucination Closed-Set Auto-Tagging & Visual Grounding Hardening

- **Canonical macOS Reference**:
  - `Sources/CharkleCore/Contracts/MediaModels.swift` (`TypeSafeExperimentalConfig`, `ClosedSetTagOption`, `ClosedSetTagMatch`, `ClosedSetTaggingResult`)
  - `Sources/CharkleCore/Intelligence/VisualGroundingEngine.swift` (`classifyClosedSetTags`)
  - `Sources/CharkleCore/Intelligence/ClosedSetTagFunnel.swift` (`ClosedSetTagFunnel`, `FeaturePrintObservationCache`)
  - `Sources/CharkleCore/LiveCharkleEngine.swift` (`resolveClosedSetFunnel`, `enrichAssetsWithCloudAI`, `suggestFolders(for:)`, Phase 1 flag gating in `locateVisualRegion` / `locateVisualMatch` / `detectCleanContentBounds` / `extractSubjectPalette`)
  - `Sources/CharkleCore/Intelligence/MoodboardAgentHarness.swift` (`enableMoodboardFocusCrop` gate in `applyAutoDetailCropsIfRequested`)
  - `Sources/CharkleApp/Stores/LibraryStore.swift` (`enrichEngineLabel`, pure-Jev unlock, `concurrency = 6`)
  - `Sources/CharkleApp/Views/Settings/AISettingsPane.swift`, `Sources/CharkleApp/Views/InspectorView.swift`, `Sources/CharkleApp/Views/MainWindowView.swift`
  - `Tests/CharkleTests/TypeSafeVisualGroundingTests.swift`
- **Shared Cross-Platform Contract**: `.trellis/spec/cross-platform/index.md` §6.5

---

## 1. Goal & Why This Matters

Open-set VLM auto-tagging suffers from three structural flaws on real 2,000+ asset libraries:
1. **Vocabulary drift & singleton bloat** (e.g. synonymous splits like `手绘风` vs `手绘插画` and hundreds of one-off tags).
2. **Uncalibrated confidence**, causing hundreds of unaccepted `suggestedTags` to pile up because users cannot trust auto-promotion into formal `tags`.
3. **Slow, redundant LLM cost** when batch-retagging assets that already have `aiDescription`.

TypeSafe System One (`Jev`) solves this natively by evaluating up to **20 canonical library tags in a single multi-`Noul` HTTP request** (1 image upload, calibrated `[0, 1]` probabilities, physically impossible to invent non-canonical tags).

---

## 2. Wire, Config & Algorithm Parity Requirements

### 2.1 `TypeSafeExperimentalConfig` Schema Extension (Backward-Compatible)
Add 4 fields with serde/JSON defaults so legacy configs decode without migration:
- `enableClosedSetTagging: bool` (default `true`)
- `autoApplyHighConfidenceTags: bool` (default `false` — opt-in safety)
- `highConfidenceTagThreshold: f64 / number` (default `0.82`, clamped `0.60...0.98`)
- `suggestedTagThreshold: f64 / number` (default `0.52`, clamped `0.30...highConfidenceTagThreshold`)

### 2.2 Single-Request Multi-`Noul` Closed-Set Classifier (`classifyClosedSetTags`)
- Input: asset title (max 80 chars), existing tags (max 8), notes/description (max 140 chars), single JPEG (`targetLongSide = 320`, strictly normalized inside `280...1568`), and `candidateTags` (already excluding tags present on the asset, capped at `20`).
- Build one `POST /v1/systemone` multipart request with `TypeSafe-Danger-Zone-Images: true` and `questions["t_0" ... "t_k"]`:
  - **Lean prompt (critical for latency & token budget)**:
    `instructions: "Does \`photo\` fit tag \"<name>\" (<up to 2 aliases / 2 context hints>)?"`
    Do **NOT** attach verbose per-question `true`/`false` `criteria` boilerplate (keeps per-asset total tokens ~1.2–1.8k instead of ~4.6k).
- Strict closed-set filter:
  - Only map keys present in `keyToTagName`; discard unknown keys and non-finite probabilities.
  - Sort descending by probability (tie-break lexicographically).
  - Split into `confirmedTags` (`p >= highConfidenceTagThreshold`, max 5) and `suggestedTags` (`suggestedTagThreshold <= p < highConfidenceTagThreshold`, max 6).

### 2.3 Two-Stage Local Candidate Funnel (`ClosedSetTagFunnel`)
- **Vocabulary Hygiene**:
  - Fold `LibraryTaxonomyPolicy.tagAliases` -> canonical target (preserving canonical spelling + passing aliases as hints).
  - **Anti-singleton filter**: If `>= 12` canonical tags occur `>= 2` times across active non-trashed assets, exclude one-off singleton tags (`count == 1`) from the closed-set pool unless explicitly targeted by `taxonomy.tagAliases`. On small/bootstrapping libraries (`< 12` repeated tags), include all existing tags.
  - Synthesize compact context hints per tag: top 2 co-occurring folder names + top 2 co-occurring canonical tags.
- **Per-Asset 20-Tag Selection** (excluding tags already on target asset):
  - If `<= 20` eligible tags remain -> return all of them (100% coverage in 1 request).
  - Otherwise fill up to `20` from 3 ranked signals:
    1. **Visual Neighbor Tags (up to 50% / 10 slots)**: Top 12 visually similar active assets using local visual embeddings/perceptual descriptors (Windows: existing local visual feature vectors / pHash + color histogram; Web: stored asset vectors / dominant color + folder similarity), accumulating similarity weights onto neighbor tags.
    2. **Folder & Parent-Folder Prior (up to 35% / 7 slots)**: Tag frequencies in `asset.folderID` (`1.0x`) + parent folder (`0.45x`).
    3. **Global Backbone (remaining slots)**: Highest-frequency canonical tags across the library.
- **Caching & Invalidation**:
  - Cache the built funnel in memory (~45s TTL) and cache decoded visual descriptors so batch retagging thousands of assets stays `O(N)` instead of `O(N^2)`.
  - Invalidate the cached funnel immediately whenever manual tag edits (`addTags` / `removeTags` / `acceptSuggestedTags`) commit.

### 2.4 Enrichment Routing, Concurrency & HLC Sync
- **Unlock Pure-Jev Tagging**: Both manual "AI 打标 / 重新打标" and `autoAnalyzeOnImport` MUST work when `aiConfig.provider == disabled` as long as `typeSafeConfig.enabled && enableClosedSetTagging` and a TypeSafe API key is stored.
- **Skip Redundant Generative VLM**: When Jev closed-set tagging runs AND `asset.aiDescription` is already non-empty, **do NOT call the slow generative VLM** (zero wasted ChatGPT/Gemini/OpenAI calls; run pure Jev only). When `asset.aiDescription` is empty and a generative VLM is also configured, run VLM (description + embedding) and Jev (closed-set tags) in parallel.
- **Merge & HLC Sync**:
  - `autoApplyHighConfidenceTags == true`: merge `confirmedTags` into formal `asset.tags` (sorted, normalized-deduped) AND emit standard HLC field sync ops (`/.charkle/ops/`), keeping `suggestedTags` for borderline hits.
  - `autoApplyHighConfidenceTags == false`: leave `asset.tags` untouched and write `(confirmedTags + suggestedTags)` (max 6) into `asset.suggestedTags`.
  - Cold-start fallback: only fall back to VLM open-set tags if `evaluatedTagCount < 3` AND Jev matched 0 tags.
- **Batch Concurrency & Engine Visibility**:
  - Increase batch retagging concurrency to **`6`** when Jev closed-set is active (keep `3` for pure generative VLM).
  - Surface live `enrichEngineLabel` (`"Jev 闭集打标"` / `"Jev 闭集 + 云端描述"` / `"云端 AI 打标"`) in the Inspector progress bar and multi-select toolbar pill.

### 2.5 Runtime Phase 1 Flag Gating & Concurrent `suggestFolders`
- Enforce every Phase 1 toggle at runtime (fallback cleanly to offline saliency/heuristics when disabled):
  - `locateVisualRegion` -> `enabled && (enableMoodboardFocusCrop || enablePinpointAnnotations)`
  - `locateVisualMatch` & Moodboard auto detail crop -> `enabled && enableMoodboardFocusCrop`
  - `detectCleanContentBounds` -> `enabled && enableAutoCleanCrop`
  - `extractSubjectPalette` -> `enabled && enableSubjectPalette`
- Make multi-asset `suggestFolders(for assetIDs)` build folder options **once** and fan out up to **4 concurrent** Jev `Choice + Noul` requests instead of serial N× full-library scans.

---

## 3. Target Files Per Platform

### Windows (`windows/`)
1. `windows/crates/charkle-core/src/models/media.rs`: extend `TypeSafeExperimentalConfig` with the 4 `#[serde(default = "...")]` fields + `ClosedSetTagOption` / `ClosedSetTagMatch` / `ClosedSetTaggingResult`.
2. `windows/crates/charkle-core/src/intelligence/visual_grounding.rs`: add `classify_closed_set_tags` + `ClosedSetTagFunnel` (with cached descriptor similarity, alias folding, singleton suppression, and 45s TTL cache); enforce Phase 1 feature flags in `locate_region` / `detect_clean_bounds` / `extract_subject_palette`; also close existing Phase 2 gap (`score_candidates_for_query` & `locate_visual_match`) if touching the file.
3. `windows/crates/charkle-core/src/engine.rs` & `windows/src-tauri/src/commands/settings.rs`: wire pure-Jev + VLM-skipping enrichment, HLC sync op emission on auto-applied tags, concurrent `suggest_folders`, and threshold clamping on save.
4. `windows/ui/src/features/settings/SettingsPanesIntelligence.tsx`, `windows/ui/src/stores/syncAIStore.ts`, `windows/ui/src/stores/libraryStore.ts`, Inspector & batch action bar: add the 7th scenario toggle (`零幻觉闭集自动打标`), nested auto-apply toggle + `70%–95%` slider, pure-Jev retag enablement, `concurrency = 6`, and `enrichEngineLabel`.

### Web (`web/`)
1. `web/packages/shared/src/models/media.ts`: extend `TypeSafeExperimentalConfig` and add closed-set result interfaces.
2. `web/packages/server/src/intelligence/visual-grounding-engine.ts`: add `classifyClosedSetTags` + `ClosedSetTagFunnel` (45s TTL cache, alias folding, singleton filter) and enforce Phase 1 flags in `locateVisualRegion` / `locateVisualMatch` / `detectCleanContentBounds` / `extractSubjectPalette`.
3. `web/packages/server/src/api/routes-ai.ts` & `web/packages/server/src/storage/config-store.ts`: wire pure-Jev + VLM-skipping enrichment, HLC sync ops on auto-applied tags, concurrent `suggestFolders`, and threshold clamping.
4. `web/packages/client/src/features/settings/AISettingsPane.tsx` & Inspector/library store: add the 7th scenario toggle, nested auto-apply toggle + `70%–95%` slider, pure-Jev retag unlock, and live engine progress label.

---

## 4. Verification Checklist
- Legacy `TypeSafeExperimentalConfig` JSON without the 4 new fields decodes with exact defaults (`enableClosedSetTagging = true`, `autoApplyHighConfidenceTags = false`, `0.82`, `0.52`).
- Single-request multi-`Noul` wire test verifies 1 image upload, lean instructions (no `"criteria"` block), strict zero-hallucination filtering, and dual-threshold split.
- Funnel test verifies singleton suppression (`>= 12` repeated tags), taxonomy alias folding, folder/parent-folder prior ordering, and `<= 20` cap.
- Integration test verifies: (a) pure-Jev enrichment works with ordinary VLM disabled; (b) assets with existing `aiDescription` skip slow VLM completely; (c) `autoApplyHighConfidenceTags = true` writes formal tags + HLC sync ops; (d) Phase 1 flags disabled -> 0 TypeSafe HTTP calls + offline fallback.
