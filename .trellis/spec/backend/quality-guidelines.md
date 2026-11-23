# Backend Quality Guidelines

> Concurrency contracts, Vision throttling, rich-media storage invariants, test standards, and Release signing rules.

---

## Scenario 1: Bounded Vision Concurrency & Actor-Tracked Background Enrichment

### 1. Scope / Trigger
- Trigger: Running 70+ parallel Swift Testing tests OR importing large batches of images simultaneously deadlocked Apple Vision's Espresso/CoreML runtime when `IntelligenceEngine` dispatched onto an unbounded `.concurrent` `DispatchQueue`, and untracked `Task.detached` calls leaked past `LiveCharkleEngine.deinit` and broke synchronous `featurePrint` availability (`DriveSyncTests.swift:150`).

### 2. Signatures
- `Sources/CharkleCore/Intelligence/IntelligenceEngine.swift`:
  ```swift
  private actor VisionConcurrencyGate { init(limit: Int); func acquire() async; func release() }
  public func analyze(
      thumbnailURL: URL,
      includeColors: Bool = true,
      includeOCR: Bool = true,
      includeFeaturePrint: Bool = true
  ) async -> LocalAnalysisResult
  ```
- `Sources/CharkleCore/LiveCharkleEngine.swift`:
  - `private var backgroundEnrichmentTasks: [UUID: Task<Void, Never>] = [:]` (cancelled in `deinit`)
  - `private func runBackgroundOCRIfNeeded(ids: [UUID]) async -> Bool`

### 3. Contracts
- **Concurrency cap**: At most `3` concurrent Apple Vision evaluations (`VisionConcurrencyGate(limit: 3)`) process-wide, using non-blocking `CheckedContinuation` queuing (never `DispatchSemaphore.wait()` on cooperative threads!).
- **Fast synchronous FeaturePrint**: `LiveCharkleEngine.prepare(...)` extracts `featurePrint` synchronously (`includeColors: false, includeOCR: false, includeFeaturePrint: true`, ~15ms on ANE, 4× parallel via `withThrowingTaskGroup`) so visual similarity search and Drive vector shards (`AssetVector.featurePrint`) are immediately populated on ingest.
- **Tracked cancellable background OCR & Cloud AI**: Heavier multi-language OCR (`includeOCR: true, includeFeaturePrint: false`) and optional Cloud AI auto-tagging run in a tracked `Task(priority: .utility)` registered in `backgroundEnrichmentTasks`, cancelled on `deinit`, checking `Task.isCancelled` before every asset, and posting `CharkleCoreNotifications.libraryDidEnrichInBackground` only when records actually changed.
- **No spurious sync ops**: If OCR returns empty text, `runBackgroundOCRIfNeeded` must NOT call `store.saveAssetLocally`.

### 4. Validation & Error Matrix
- Cancelled task after `visionGate.acquire()` -> immediately calls `visionGate.release()` and returns `LocalAnalysisResult()`.
- Missing thumbnail or `.audio` / `.model3D` asset -> skips Vision cleanly without failing ingest.

### 5. Good / Base / Bad Cases
- **Good**: 75 parallel Swift Testing tests complete in ~8–13s with zero deadlocks; dropping 20 photos into Inbox lands them immediately while OCR/AI enrich in the background.
- **Base**: Single image ingest computes `featurePrint` immediately and persists `AssetVector` before returning.
- **Bad (Prevented)**: Unbounded `.concurrent` Vision queue + untracked `Task.detached` hangs test runs indefinitely and races with `DriveSyncEngine.syncNow()`.

### 6. Tests Required
- `DriveSyncTests.embeddingShards` (`vector.featurePrint != nil` immediately after `ingest`).
- Full parallel `swift test` completing in `< 20s` with 0 failures and 0 hangs.

### 7. Wrong vs Correct
```swift
// WRONG: Unbounded concurrent Vision + uncancelled detached task
Task.detached { [weak self] in
    _ = try? await self?.analyzeAssetsLocally(ids: committedIDs)
}

// CORRECT: Fast FeaturePrint in prepare() + gated, actor-tracked, cancellable background OCR/AI
await Self.visionGate.acquire()
if Task.isCancelled {
    await Self.visionGate.release()
    return LocalAnalysisResult()
}
// ... tracked in `backgroundEnrichmentTasks[jobID]`, cancelled in `deinit`
```

---

## Scenario 2: Structured Rich Media Storage (Social Posts & GitHub Repos)

### 1. Scope / Trigger
- Trigger: Saving an X/Threads/Bluesky post originally stored the downloaded photo as `mediaKind = .image`, flattening the tweet into an image asset and hiding extraction for video posts.

### 2. Signatures
- `CoreModels.swift`: `SocialMediaAttachment(kind: .photo | .video | .gif, url: String, thumbnailURL: String?)`, `SocialPostMetadata.effectiveAttachments`, `AssetRecord.displayTypeLabel`.
- `SocialPostResolver.swift`: `SocialPostResolver.resolve(_ ref: SocialPostReference) async -> ResolvedSocialPost?`.
- `LiveCharkleEngine.swift`: `prepareSocialPost(_:fallbackInput:folderID:)` and `prepareGitHubRepo(_:folderID:)`.

### 3. Contracts
- **Social posts** MUST always persist with `mediaKind = .webBookmark`, `richMetadata.socialPost` populated with full author/handle/timestamp/bodyText/quotedPost/`attachments`, and `ocrText = meta.bodyText`. Never save a tweet as `mediaKind = .image`.
- When a social post contains a video/GIF, cache the downloaded `.mp4` as the local original for instant offline playback while still keeping `mediaKind = .webBookmark`.
- Standalone extraction (`LibraryStore.extractMediaFromSocialPost` / `extractAllMediaFromSocialPost`) supports `.photo`, `.video`, and `.gif`, creating an independent asset whose `sourceURL` and `notes` preserve the originating post author, platform, full text, and canonical URL.
- **GitHub repos** persist with `mediaKind = .webBookmark`, `richMetadata.githubRepo` (owner avatar, stars, forks, watchers, language, license, topics, homepage, OpenGraph image, full README.md).

### 4. Tests Required
- `UpgradeFeaturesTests.gitHubAndSocialParsers`
- `UpgradeFeaturesTests.recursiveFolderQueryAndSocialAttachments` (verifies `effectiveAttachments` synthesis for both new and legacy saved social posts).

---

## Scenario 3: Full Camera EXIF & AI Generation Prompt Extraction (`ImageMetadataExtractor.swift`)

### 1. Scope / Trigger
- Trigger: Photography assets require complete EXIF/TIFF/GPS/IPTC inspection, and AI-generated assets embed prompt/model/sampler/LoRA parameters inside PNG `tEXt`/`iTXt`/`zTXt` chunks, XMP packets, or EXIF `UserComment`.

### 2. Signatures
- `Sources/CharkleCore/Contracts/CoreModels.swift`:
  - `PhotoExifMetadata` (`hasMeaningfulCameraExif: Bool`, `isEmpty: Bool`, `cameraDisplayName`, `exposureSummary`, `formattedAperture`, `formattedFocalLength`)
  - `AIGenerationMetadata` (`generator`, `prompt`, `negativePrompt`, `modelName`, `modelHash`, `sampler`, `scheduler`, `steps`, `cfgScale`, `seed`, `sizeText`, `clipSkip`, `loras`)
- `Sources/CharkleCore/Media/ImageMetadataExtractor.swift`:
  - `ImageMetadataExtractor.extract(from url: URL) -> ExtractedImageMetadata` (bounded 2 MB binary chunk scan cap)

### 3. Contracts
- Extract both `photoExif` and `aiGeneration` during image ingest (`MediaPipeline.swift`) and support synchronous on-demand hydration with in-memory caching for legacy assets imported before v1.0.1.
- **Meaningful EXIF gate**: UI cards MUST gate camera EXIF presentation on `photoExif.hasMeaningfulCameraExif` (camera/lens/date/exposure/ISO/focal/GPS/software/artist/copyright), NOT `!photoExif.isEmpty` — otherwise ordinary illustrations with only generic `sRGB / 8-bit` color profile pop up spurious EXIF cards.
- **Supported AI prompt formats**: A1111/Forge/Civitai `parameters`, ComfyUI workflow/prompt JSON graph traversal, NovelAI, InvokeAI, Draw Things, Midjourney, XMP, and EXIF `UserComment` (stripping ASCII/UNICODE prefix safely via `.flatMap`).

### 4. Tests Required
- `CharkleV101PolishTests`: `ImageMetadataExtractor parses A1111 parameters, ComfyUI graph JSON, and real PNG tEXt + JPEG EXIF`.

---

## Compilation, Testing & Release Build Standards

1. **Zero-Warning Policy**: Always compile with strict warnings-as-errors:
   ```bash
   swift build --build-tests -Xswiftc -warnings-as-errors
   ```
2. **Full Verification Suite**:
   ```bash
   swift test --skip-build
   node scripts/test-figma-plugin.cjs
   ```
3. **Release Bundle, DMG & Code Signing (`scripts/build-app.sh`, `scripts/build-dmg.sh`)**:
   - **ALWAYS** build Release app bundles via `./scripts/build-app.sh release` and distributable arm64 DMGs via `./scripts/build-dmg.sh --rebuild`.
   - Never assemble or codesign `.app` bundles directly inside iCloud-synced `~/Documents` — FileProvider injects `com.apple.FinderInfo` / `com.apple.fileprovider.fpfs#P` xattrs that invalidate signatures. Both `build-app.sh` and `build-dmg.sh` stage in `/tmp` with `cp -RX` + `xattr -cr`, sign `Contents/Helpers/charkle` and `Charkle.app` with a stable certificate (preserving macOS Keychain ACLs across rebuilds), and verify `codesign -v --deep --strict` on the clean `/tmp` copy (never print certificate CN/email).
4. **External Agent MCP Safety (`ExternalAgentPolicy.swift`)**:
   - `CharkleCLI` MCP server exposes only safe read/organize/soft-trash tools (14 tools) and MUST NEVER expose permanent deletion (`ExternalAgentMCPTests.swift`).
5. **Cross-Platform & Repo Hygiene**:
   - Follow [Cross-Platform Contracts](../cross-platform/index.md) for `/.charkle/` sync wire compatibility, `.charkleboard` Figma Bridge ZIPs, and zero external inspiration/author mentions.
