# Charkle-Web Round 4 Delta Sync Specification

> **Audit Scope**: macOS upstream commits `5bc0f07..fced1d5` (including `7a730c9`, `b7f046d`, `283bbfe`, `08e26ed`, `4777a8e`, `8284dc6`, `1641718`, `1a5224e`, `884bc63`, `590b5a1`, `3852261`, `ce72927`, `3cb9375`, `fced1d5`), canonical `DESIGN.md`, `.trellis/spec/cross-platform/index.md`, and Web Trellis tasks (`11-23-web-design-motion-polish`, `11-23-web-windows-mcp-cli-v2-parity`) mapped onto `Charkle-Web` (`HEAD 57903a3`).

---

## 0. Non-Negotiable Global Guardrails (All 3 Builders)

1. **Dual-Runtime Compatibility (Node.js/Docker + Cloudflare Workers DO SQLite + R2)**:
   - ZERO transitive `node:*` (`node:fs`, `node:zlib`, `node:sqlite`, `node:readline`, `node:os`, `node:crypto`) or `sharp` imports reachable from `@charkle/server/worker` (`packages/server/dist/worker-exports.js`).
   - All new shared/server modules (`image-metadata-extractor.ts`, `external-agent-schema.ts`, `external-agent-service.ts`, `mcp/stdio-frame-parser.ts`) MUST use Web-standard APIs (`Uint8Array`, `DataView`, `TextDecoder`, `DecompressionStream('deflate')`, `fetch`). Only `packages/server/src/mcp-stdio.ts` may import Node stream/fs modules.
   - Mandatory gate: `npm run cf:typecheck && npm run cf:dry-run` MUST pass with 0 errors.
2. **Web-Specific Capabilities Preserved**:
   - Keep **Auth Login** (`AuthGate`, `账号与安全` pane, sessions, `chk_...` PAT tokens).
   - Keep **Browser Clipper Extension** (`packages/extension/`, `/api/v1/extension/download`).
   - Keep browser-native Canvas preprocessing & PNG/JPG/`.charkleboard` exporters (`lib/client-media.ts`, `lib/client-board-export.ts`).
3. **Repository Purity, Zero Local Paths & Zero User-Facing Developer Jargon**:
   - **Zero external inspiration/competitor/author mentions** anywhere in tracked source, comments, tests, or docs (each builder executes the exact file:line scrub table in its section).
   - **Zero personal absolute paths** (e.g., home-directory paths) in code, tests, or docs.
   - **Zero violet/neon AI chrome** (`OKLCH 270°–330°` / `#8B5CF6`). Studio Cobalt (`#2A60E0` / `#5B8DEF`) + neutral studio surfaces only.
   - **Zero developer jargon in user-facing UI strings**: forbid `Gallery-First`, `Liquid Glass`, `16-Grid`, `Layered`, `Duotone`, `Manifest V3`, `scrypt`, `FTS5`, `CIELAB`, `MMR`, `Agent Harness`, `Shadow DOM`, `Apple Vision`.
4. **Figma Plugin Parity (`figma-plugin/`)**:
   - Verified byte-identical to macOS `Resources/FigmaPlugin/` as of `fced1d5`. Do NOT drift `figma-plugin/ui.html`, `code.js`, or `manifest.json`.

---

## 0.1 Frozen Cross-Builder Contracts (Build Order: `r4-backend` Shared First)

`r4-backend` publishes `@charkle/shared` changes and runs `npm run build -w @charkle/shared` first so `r4-client-core` and `r4-client-studio` compile against frozen types immediately.

### A. `@charkle/shared` Frozen TypeScript Additions

#### 1. `packages/shared/src/models/core.ts`

```ts
export interface PhotoExifMetadata {
  cameraMake?: string | null;
  cameraModel?: string | null;
  lensModel?: string | null;
  capturedAt?: string | null;
  exposureTime?: string | null;
  fNumber?: number | null;
  iso?: number | null;
  focalLengthMM?: number | null;
  focalLength35mm?: number | null;
  exposureBiasEV?: number | null;
  meteringMode?: string | null;
  flashFired?: boolean | null;
  whiteBalance?: string | null;
  colorProfile?: string | null;
  bitDepth?: number | null;
  dpiWidth?: number | null;
  software?: string | null;
  artist?: string | null;
  copyright?: string | null;
  latitude?: number | null;
  longitude?: number | null;
  altitudeMeters?: number | null;
}

export interface AIGenerationMetadata {
  generator?: string | null;
  prompt?: string | null;
  negativePrompt?: string | null;
  modelName?: string | null;
  modelHash?: string | null;
  sampler?: string | null;
  scheduler?: string | null;
  steps?: number | null;
  cfgScale?: number | null;
  seed?: string | null;
  sizeText?: string | null;
  clipSkip?: number | null;
  loras: string[];
  extraParameters: Record<string, string>;
  rawParameters?: string | null;
}

// Extend AssetRichMetadata (wire-compatible with macOS CoreModels.swift)
export interface AssetRichMetadata {
  githubRepo?: GitHubRepoMetadata | null;
  socialPost?: SocialPostMetadata | null;
  photoExif?: PhotoExifMetadata | null;
  aiGeneration?: AIGenerationMetadata | null;
  textExcerpt?: string | null;
  isMarkdown: boolean;
  model3DFormat?: string | null;
}

// Required pure helpers matching macOS CoreModels.swift verbatim:
export function getPhotoExifCameraDisplayName(exif: PhotoExifMetadata): string | null;
export function formatPhotoExifAperture(exif: PhotoExifMetadata): string | null; // "f/2" or "f/1.8"
export function formatPhotoExifFocalLength(exif: PhotoExifMetadata): string | null; // "35mm" or "23mm（等效 35mm）"
export function getPhotoExifExposureSummary(exif: PhotoExifMetadata): string | null; // "35mm · f/1.8 · 1/250s · ISO 400"
export function hasMeaningfulCameraExif(exif?: PhotoExifMetadata | null): boolean;
export function isPhotoExifEmpty(exif?: PhotoExifMetadata | null): boolean;
export function isAIGenerationEmpty(ai?: AIGenerationMetadata | null): boolean;
```

- `hasMeaningfulCameraExif(exif)` returns `true` ONLY when at least one of `cameraDisplayName`, `lensModel`, `capturedAt`, `exposureTime`, `fNumber`, `iso`, `focalLengthMM`, `latitude`, `software`, `artist`, `copyright` is present (never pops a camera EXIF card for bare `colorProfile`/`bitDepth`/`dpiWidth`).
- `isPhotoExifEmpty(exif)` returns `!hasMeaningfulCameraExif(exif) && !exif?.colorProfile && exif?.bitDepth == null && exif?.dpiWidth == null`.

```ts
// Hierarchical folder tree helpers
export interface FolderHierarchyNode {
  id: UUID;
  folder: FolderRecord;
  depth: number;
  children: FolderHierarchyNode[];
}
export function buildFolderTree(folders: readonly FolderRecord[]): FolderHierarchyNode[];
export function flattenFolderTree(folders: readonly FolderRecord[]): FolderHierarchyNode[];
export function folderNodeContains(node: FolderHierarchyNode, folderID?: UUID | null): boolean;
export function buildFolderPathsMap(folders: readonly FolderRecord[]): Record<UUID, string>;

// Persistent drag-reorderable Inspector Info sections
export type InspectorInfoSection =
  | 'previewIdentity'
  | 'quickActions'
  | 'colorsAndTags'
  | 'notesAndOCR'
  | 'aiGeneration'
  | 'photoExif'
  | 'mediaSpecs'
  | 'githubRepo'
  | 'socialMediaExtract';

export const DEFAULT_INSPECTOR_SECTION_ORDER: readonly InspectorInfoSection[] = [
  'previewIdentity',
  'quickActions',
  'colorsAndTags',
  'notesAndOCR',
  'aiGeneration',
  'photoExif',
  'mediaSpecs',
  'githubRepo',
  'socialMediaExtract',
] as const;

export function inspectorInfoSectionTitle(section: InspectorInfoSection): string;
export function normalizeInspectorSectionOrder(rawValues: readonly string[]): InspectorInfoSection[];
export function moveInspectorSection(
  dragged: InspectorInfoSection,
  target: InspectorInfoSection,
  order: readonly InspectorInfoSection[],
): InspectorInfoSection[];
export function moveInspectorSectionToTop(
  section: InspectorInfoSection,
  order: readonly InspectorInfoSection[],
): InspectorInfoSection[];
export function moveInspectorSectionToBottom(
  section: InspectorInfoSection,
  order: readonly InspectorInfoSection[],
): InspectorInfoSection[];
export function stepInspectorSection(
  section: InspectorInfoSection,
  delta: number,
  visible: readonly InspectorInfoSection[],
  order: readonly InspectorInfoSection[],
): InspectorInfoSection[];
```

#### 2. `packages/shared/src/models/sync.ts`

```ts
export type ExternalAgentChannel = 'mcp' | 'cli';

export interface ExternalAgentConfig {
  /** Aggregate toggle (`mcpEnabled || cliEnabled`); kept for backward-compatible persistence. */
  enabled: boolean;
  mcpEnabled: boolean;
  cliEnabled: boolean;
  accessLevel: ExternalAgentAccessLevel;
}

// Migration rule in createDefaultExternalAgentConfig(overrides):
// - If `mcpEnabled` or `cliEnabled` is omitted, inherit `overrides.enabled ?? true`.
// - Recompute `enabled = mcpEnabled || cliEnabled`.
// - If caller passes ONLY `{ enabled: false }` (legacy patch), set both `mcpEnabled = false` and `cliEnabled = false`.
export function externalAgentAllowsRead(
  config: ExternalAgentConfig,
  channel?: ExternalAgentChannel,
): boolean;
export function externalAgentAllowsWrite(
  config: ExternalAgentConfig,
  channel?: ExternalAgentChannel,
): boolean;
```

#### 3. `packages/shared/src/api/contracts.ts`

```ts
export interface ExternalAgentDiagnosticsResponse {
  ok: boolean;
  serverVersion: string;
  runtimeMode: RuntimeMode;
  supportedProtocolVersions: string[];
  policy: {
    mcpEnabled: boolean;
    cliEnabled: boolean;
    accessLevel: ExternalAgentAccessLevel;
    mcpCanWrite: boolean;
    cliCanWrite: boolean;
  };
  capabilities: {
    toolCount: number;
    readToolCount: number;
    writeToolCount: number;
    resourceCount: number;
    resourceTemplateCount: number;
    promptCount: number;
    permanentDeleteAllowed: false;
  };
  library: {
    totalAssets: number;
    inboxCount: number;
    untaggedCount: number;
    trashedCount: number;
    folderCount: number;
    smartFolderCount: number;
    boardCount: number;
  };
  syncMode: string;
  aiProvider: string;
  cache: CacheStats;
  error?: string;
}
```

New HTTP endpoints:
- `POST /api/v1/assets/:id/hydrate-metadata` → `AssetDetailResponse` (`{ asset: AssetRecord }`)
- `GET /api/v1/agent/diagnostics` → `ExternalAgentDiagnosticsResponse`
- `POST /api/v1/mcp` → supports JSON-RPC 2.0 single objects AND batch arrays (`204` when notification-only, `200` JSON object/array otherwise).

### B. Client Cross-Slice Frozen Interfaces (`r4-client-core` → `r4-client-studio`)

1. **`packages/client/src/design-system/index.ts`** MUST export:
   - `useDelayedFlag(active: boolean, delayMs?: number, minVisibleMs?: number): boolean`
   - `SkeletonBlock`, `GalleryMasonrySkeleton`, `InboxTriageSkeleton`, `CandidateGridSkeleton`, `InspectorSimilarSkeleton`, `BoardCanvasSkeleton`
   - `EmptyStateVignette` (`props: { kind: EmptyStateKind; compact?: boolean; className?: string }`) where `EmptyStateKind = 'emptyLibrary' | 'emptyFolder' | 'noFilterResults' | 'emptyTrash' | 'inboxZero' | 'emptyMoodboard' | 'emptyInspector'`
   - `SegmentedControl<T extends string>` (`props: { options: ReadonlyArray<{ id: T; label: string; icon?: React.ReactNode }>; value: T; onChange: (next: T) => void; size?: 'sm' | 'md'; disabled?: boolean; ariaLabel?: string; className?: string }`)
   - `DisclosureGroup` (`props: { open: boolean; onOpenChange: (open: boolean) => void; label: React.ReactNode; children: React.ReactNode; className?: string; headerClassName?: string }`)
   - `FolderHierarchyMenu` (`props: { folders: readonly FolderRecord[]; includeInbox?: boolean; selectedFolderID?: UUID | null; highlightSelection?: boolean; parentSelfPrefix?: string; onSelectFolder: (folderID: UUID | null) => void }`)
   - `FolderHierarchyScopeTree` (`props: { folders: readonly FolderRecord[]; selectedFolderIDs: ReadonlySet<UUID>; onChange: (next: Set<UUID>) => void }`)
2. **`packages/client/src/stores/coordinatorStore.ts`** additions:
   - `selectedInspectorTab: 'info' | 'similar'`, `setSelectedInspectorTab(tab: 'info' | 'similar'): void`
   - `pendingGalleryReveal: { assetID: UUID; nonce: number } | null`, `requestRevealAssetInGallery(assetID: UUID): void`, `clearPendingGalleryReveal(nonce: number): void`
   - `ToastItem` adds `tone?: 'info' | 'success' | 'warning' | 'error'`, `paused?: boolean`, `remainingMs?: number`, `durationMs?: number`, `exiting?: boolean`; actions add `pauseToast(id: string): void`, `resumeToast(id: string): void`, `triggerToastAction(id: string): void`.
3. **`packages/client/src/lib/revealAssetInLibrary.ts`** (owned by `r4-client-core`, called by `r4-client-studio`):
   - `export async function revealAssetInLibrary(assetID: UUID, sourceBoardID?: UUID | null): Promise<void>`
4. **`packages/client/src/api/client.ts` & `packages/client/src/stores/syncAIStore.ts`** additions:
   - `apiClient.hydrateAssetMetadata(id: UUID): Promise<AssetDetailResponse>`
   - `apiClient.getExternalAgentDiagnostics(): Promise<ExternalAgentDiagnosticsResponse>`
   - `syncAIStore`: `externalAgentDiagnostics: ExternalAgentDiagnosticsResponse | null`, `isRunningAgentDiagnostics: boolean`, `runExternalAgentDiagnostics: () => Promise<ExternalAgentDiagnosticsResponse>`.

---

## 1. Builder Section: `r4-backend`

**Ownership**: `packages/shared/**`, `packages/server/**`, `packages/worker/**`, `figma-plugin/**` (NEVER touch `packages/client/**`).

### 1.1 `@charkle/shared` Models & Swift Wire Codec
1. **`packages/shared/src/models/core.ts`**:
   - Add `PhotoExifMetadata`, `AIGenerationMetadata`, extend `AssetRichMetadata` (`photoExif`, `aiGeneration`), and add all pure EXIF/AI helpers, `FolderHierarchyNode` tree builders, and `InspectorInfoSection` order helpers from §0.1A.
2. **`packages/shared/src/models/sync.ts`**:
   - Upgrade `ExternalAgentConfig` with `mcpEnabled` & `cliEnabled` + `ExternalAgentChannel` + channel-aware `externalAgentAllowsRead` / `externalAgentAllowsWrite` + v1.0.0 migration in `createDefaultExternalAgentConfig`.
3. **`packages/shared/src/api/contracts.ts`**:
   - Export `ExternalAgentDiagnosticsResponse` and re-export all new core/sync types from `packages/shared/src/index.ts`.
4. **`packages/shared/src/sync/swift-codec.ts`**:
   - Update `encodeSwiftAssetRichMetadata` & `decodeSwiftAssetRichMetadata` to preserve `photoExif` (all 22 optional fields) and `aiGeneration` (all 15 fields, defaulting `loras: []`, `extraParameters: {}`) losslessly matching `CoreModels.swift` JSON keys verbatim!
   - Add round-trip tests in `packages/shared/tests/swift-codec.test.ts` covering `PhotoExifMetadata`, `AIGenerationMetadata`, `FolderHierarchyNode`, `InspectorInfoSection`, and `ExternalAgentConfig` v1.0.0 migration.

### 1.2 Pure-TS Dual-Runtime Image Metadata Extractor (EXIF + AI Prompts)
Create **`packages/server/src/media/image-metadata-extractor.ts`** (100% Workers-safe — ZERO `node:*` imports, ZERO `sharp`):
- Export `extractImageMetadata(bytes: Uint8Array, mimeType?: string): Promise<{ photoExif: PhotoExifMetadata | null; aiGeneration: AIGenerationMetadata | null }>`.
- Scan cap: `maxBinaryScanBytes = 2 * 1024 * 1024`.
- **Binary Container Parsers**:
  1. **PNG**: scan chunks (`tEXt`, `iTXt`, `zTXt`, `eXIf`, `pHYs`, `iCCP`, `IHDR` bitDepth) until `IEND`. Inflate `zTXt` and compressed `iTXt` using Web-standard `new DecompressionStream('deflate')` (RFC 1950 zlib stream; safe fallback if malformed). Parse `eXIf` payload as raw TIFF IFD!
  2. **JPEG**: walk `0xFFE1` (APP1) markers for `Exif\0\0` (TIFF IFD0 + ExifIFD + GPSIFD) and `http://ns.adobe.com/xap/1.0/\0` (XMP XML string), plus `0xFFED` (APP13 IPTC byline/copyright/caption) and `0xFFE0` (JFIF DPI) / `0xFFE2` (ICC profile name).
  3. **WebP (RIFF/WEBP)**: walk `EXIF` and `XMP ` chunks.
  4. **TIFF IFD Reader** (both `II` little-endian and `MM` big-endian): extract Make (`0x010F`), Model (`0x0110`), Software (`0x0131`), DateTime (`0x0132`), Artist (`0x013B`), Copyright (`0x8298`), XResolution (`0x011A`), ExifIFDPointer (`0x8769`), GPSInfoIFDPointer (`0x8825`); inside ExifIFD extract ExposureTime (`0x829A`), FNumber (`0x829D`), ISO (`0x8827`), DateTimeOriginal (`0x9003`), DateTimeDigitized (`0x9004`), OffsetTimeOriginal (`0x9011`), ExposureBiasValue (`0x9204`), MeteringMode (`0x9207` → Chinese labels `1:平均测光, 2:中央重点测光, 3:点测光, 4:多点测光, 5:评价测光, 6:局部测光`), Flash (`0x9209` → `(v & 1) !== 0`), FocalLength (`0x920A`), UserComment (`0x9286`, handling `ASCII\0\0\0` & `UNICODE\0` UTF-16BE/LE), WhiteBalance (`0xA403` → `0:自动, 1:手动`), FocalLenIn35mmFilm (`0xA405`), LensModel (`0xA434`), ColorSpace (`0xA001` → `1:sRGB`); inside GPSIFD extract Lat/LatRef/Lon/LonRef/Alt/AltRef (DMS rational → signed decimal degrees).
- **AI Generation Parsers** (matching macOS `ImageMetadataExtractor.swift` priority A→G):
  - **A**: A1111 / Forge / reForge / Civitai (`parameters` chunk or EXIF UserComment with `Steps:`/`Negative prompt:`/`Sampler:`) — extracts positive/negative prompt, `Steps`, `Sampler`, `Schedule type`/`Scheduler`, `CFG scale`/`Distilled CFG Scale`, `Seed`, `Size`, `Model`, `Model hash`, `Clip skip`, `<lora:name:weight>` + `Lora hashes`, `extraParameters` (max 8), `rawParameters` (max 8000 chars).
  - **B**: ComfyUI node-graph JSON (`prompt` chunk) — traces `KSampler`/`SamplerCustom`/`RandomNoise`/`BasicScheduler`/`KSamplerSelect`/`FluxGuidance`/`CheckpointLoader`/`UNETLoader`/`LoraLoader`/`LatentImage`/`CLIPTextEncode` nodes to reconstruct positive/negative prompts, model, sampler, scheduler, steps, cfg, seed, size, and LoRAs.
  - **C**: NovelAI (`Software` contains `NovelAI` or `Comment` JSON with `uc`/`v4_prompt`).
  - **D**: InvokeAI (`invokeai_metadata` or `sd-metadata` JSON).
  - **E**: Midjourney (`Description` containing `Job ID:`, `--v `, `--ar `, `--niji`).
  - **F**: SwarmUI (`sui_image_params`), Draw Things (`c`/`uc`), XMP (`exif:UserComment`, `dc:description`), TIFF ImageDescription, IPTC Caption.
  - **G**: Generic plain-text PNG `prompt` chunk.
- **Formatting parity**: `formatExposureTime(seconds)` (`>= 0.5` → `"Xs"` / `"X.Xs"`, `< 0.5` → `"1/Ns"`), `formatExifDate` (`YYYY:MM:DD HH:MM:SS` → `YYYY-MM-DD HH:MM:SS` + optional `(+08:00)`).

### 1.3 MediaPipeline, GitHub OG Card, X Avatar & Database FTS5 Integration
1. **`packages/server/src/media/media-pipeline.ts`** & **`packages/server/src/context.ts`**:
   - Call `extractImageMetadata(bytes, mimeType)` during `ingestFileBytes` for `image`, `animatedImage`, `designFile`, merging `photoExif` & `aiGeneration` into `asset.richMetadata`.
   - Add `hydrateImageMetadata(asset: AssetRecord): Promise<AssetRecord | null>` on `MediaPipeline` / `IMediaPipeline`: skips if not `image`/`animatedImage`/`designFile` or if `photoExif`/`aiGeneration` already populated; reads original bytes from `this.blobs.getBytes(this.originalBlobKey(asset))`, extracts metadata, returns updated `AssetRecord` (or `null` when nothing new found).
   - **GitHub OpenGraph Card (`packages/server/src/media/resolvers/github.ts`)**:
     - Export `fetchGitHubOpenGraphCardBytes(repo: GitHubRepoMetadata): Promise<{ bytes: Uint8Array; mimeType: string } | null>` fetching `repo.openGraphImageURL` / `https://opengraph.githubassets.com/1/${owner}/${repo}` with 6s timeout & 4 MiB cap (validating image magic bytes & min dimensions >= 200x100).
     - In `MediaPipeline` (both ingest and `refreshRichAsset`), try `fetchGitHubOpenGraphCardBytes(repo)` first and generate thumbnails from it; fall back cleanly to `renderArtworkCard({ kind: 'githubRepo', repo })` when offline/unavailable.
   - **Social Post Real Author Avatar (`packages/server/src/media/resolvers/social.ts`, `runtime/types.ts`, `media/artwork-svg.ts`, `media/artwork-renderer.ts`)**:
     - Export `fetchSocialAvatarBytes(rawURL?: string | null): Promise<Uint8Array | null>` trying `_normal.` → `_400x400.` upgrade for `pbs.twimg.com/profile_images/` before original URL (6s timeout, 2 MiB cap).
     - Add optional `authorAvatarBytes?: Uint8Array | null` to `ArtworkRenderRequest` (`kind: 'socialPost'`).
     - In `buildSocialPostSvg`, render circular 52px author avatar (clipped `<image>` data URI when `authorAvatarBytes` is present, crisp dark circle monogram fallback otherwise) and keep the top-right clean without a colliding duplicate badge.
2. **`packages/server/src/db/library-database.ts`**:
   - In FTS5 searchable text builder (`buildFtsDocument` / `upsertAssetFts`), append `photoExif` (`cameraDisplayName`, `lensModel`, `exposureSummary`, `software`, `artist`) and `aiGeneration` (`generator`, `modelName`, `sampler`, `loras.join(' ')`, `prompt.slice(0, 2000)`, `negativePrompt.slice(0, 600)`).
3. **`packages/server/src/api/routes-core.ts`**:
   - Add `POST /api/v1/assets/:id/hydrate-metadata`: runs `ctx.media.hydrateImageMetadata(asset)`, saves updated record to DB (`ctx.db.saveAssetLocally`), returns `{ asset }`.
4. **`packages/server/src/api/routes-ai.ts`**:
   - In `POST /api/v1/assets/analyze` (`localOnly: true`), also hydrate EXIF/AI metadata for image/animatedImage/designFile assets.
   - Add `GET /api/v1/agent/diagnostics` returning `await rt.agentService.runDiagnostics()`.
   - Update `POST /api/v1/mcp` to forward `rawText` to `rt.agentService.handleJSONRPC(rawText)` (which now handles both single objects and batch arrays, returning `null` → `204` or object/array → `200`).

### 1.4 MCP v2 Server (20 Safe Tools · 4+2 Resources · 4 Prompts · Batch · Framing)
1. **Create `packages/server/src/agent/external-agent-schema.ts`** (Workers-safe):
   - Constants: `MCP_SERVER_VERSION = '1.0.1'`, `MCP_SUPPORTED_PROTOCOL_VERSIONS = ['2025-11-25', '2025-06-18', '2025-03-26', '2024-11-05']`, `MCP_DEFAULT_PROTOCOL_VERSION = '2025-03-26'`, `negotiateProtocolVersion(requested?: string | null)`.
   - `mcpResourceDefinitions()` (4 static): `charkle://library/overview`, `charkle://boards`, `charkle://folders`, `charkle://smart-folders`.
   - `mcpResourceTemplateDefinitions()` (2 dynamic): `charkle://assets/{asset_id}`, `charkle://boards/{board_id}`.
   - `mcpPromptDefinitions()` & `renderPrompt(name, args)` (4 studio workflows): `triage_inbox`, `curate_moodboard`, `extract_design_tokens`, `inspect_ai_prompts`.
   - `mcpToolDefinitions()` (**exact 20 safe tools**, every tool carrying `annotations: { title, readOnlyHint, destructiveHint: false, idempotentHint, openWorldHint }`):
     - **12 Read**: `library_overview`, `search_assets`, `list_inbox`, `get_asset`, `render_contact_sheet`, `find_similar_assets`, `semantic_search`, `quick_jump`, `suggest_folder`, `list_boards`, `get_board_context`, `export_board_image`.
     - **8 Safe Write**: `organize_assets`, `create_folder`, `update_folder`, `ingest_asset`, `compose_moodboard`, `patch_moodboard`, `trash_assets`, `analyze_assets`.
     - *(Note: use platform-neutral Web wording in descriptions — e.g. `"built-in visual feature print"` instead of `"Apple Vision FeaturePrint"`.)*
2. **Upgrade `packages/server/src/agent/external-agent-service.ts`**:
   - **Dispatcher**: support JSON-RPC 2.0 single object AND batch array (`Array.isArray(parsed)` — reject empty batch with `-32600`, drop notification-only items, return `null` when batch produces zero responses).
   - Handle `initialize` (check `externalAgentAllowsRead(policy, channel)`, negotiate version, advertise `tools`, `resources`, `prompts`, `logging`), `notifications/initialized`, `notifications/cancelled`, `notifications/roots/list_changed`, `ping`, `logging/setLevel`, `tools/list`, `tools/call`, `resources/list`, `resources/templates/list`, `resources/read` (all 4 static + 2 template prefixes), `prompts/list`, `prompts/get`.
   - **Policy Enforcement**: accept `channel: ExternalAgentChannel = 'mcp'` on `handleJSONRPC` & `callTool`. Block disabled channel with `-32001` (or tool error). Block all 8 write tools when `!externalAgentAllowsWrite(policy, channel)`. Permanent asset delete and folder delete MUST NEVER exist.
   - **Upgrade all 14 existing tools** to full v2 contract (pagination `offset`/`hasMore`/`nextOffset`, `include_subfolders`, `smart_folder_id`/`smart_folder_name`, `media_kinds`, `aspect_shape`, `only_untagged`, `only_recent_days`, `only_pinned_offline`, `only_trashed`, `include_trashed`, `sort_by`, `get_asset` lazy EXIF/AI hydration + complete `richMetadata` + optional `include_image: true` / `image_max_side`, `render_contact_sheet` `max_width` & `include_image`, `export_board_image` `preview1400`-first & `include_image`, `organize_assets` explicit `ai_description` overwrite + `dismiss_suggested_tags` + `pinned_offline` + `skippedIDs`, `create_folder` `color_hex`/`custom_symbol`, `ingest_asset` `file_paths`/`folder_id`/`notes`/`rating`/`target_board_id` returning post-patch assets, `patch_moodboard` non-overlapping placement starting at `maxY + 24`, `add_section`/`section_tint`, `remove_node_ids`, `note_style`, `use_freeform`, `layout_style`, `paletteStrip` sync, `skippedLockedAssetIDs`/`skippedLockedNodeIDs`/`skippedMissingAssetIDs`).
   - **Implement 6 new safe tools**:
     - `find_similar_assets`: uses `deps.db.findSimilarAssets(uuid, limit)` + optional `render_contact_sheet` (top 16).
     - `semantic_search`: uses `VisualGroundingEngine` / `CloudAIProvider` / DB FTS5 fallback matching `/api/v1/ai/semantic-search`.
     - `quick_jump`: uses `deps.db.quickJump(query, limit)`.
     - `suggest_folder`: accepts `asset_id` or `asset_ids` (up to 20), runs `deps.db.suggestFolder(id)` for each.
     - `update_folder`: rename, move (`parent_id`/`parent_path`/`move_to_root`), appearance (`color_hex`/`custom_symbol`) — NEVER delete.
     - `analyze_assets`: runs local color/fingerprint + EXIF/AI metadata extraction on up to 20 `asset_ids`, plus optional `refresh_rich_metadata: true` calling `deps.media.refreshRichAsset` for web bookmarks.
   - **Add `runDiagnostics()`** returning `ExternalAgentDiagnosticsResponse` (wired into `GET /api/v1/agent/diagnostics`).
3. **Create `packages/server/src/mcp/stdio-frame-parser.ts`** & update **`packages/server/src/mcp-stdio.ts`**:
   - Port `MCPStdioFrameParser.swift` to pure `Uint8Array` state machine (`MCPStdioFrameParser` with `append(chunk: Uint8Array)`, `finishEOF()`, `encode(payload: Uint8Array, framing: 'ndjson' | 'contentLength')`, `maxFrameBytes = 32 * 1024 * 1024`).
   - Preserves split `Content-Length` headers across arbitrary stream chunks (`\r\n\r\n` or `\n\n`), handles NDJSON objects `{...}` and batch arrays `[...]`, and replies using the matching framing!
   - Wire `MCPStdioFrameParser` into `packages/server/src/mcp-stdio.ts` replacing `readline.createInterface` (pass `channel: 'cli'` or `'mcp'`? Keep stdio MCP as `channel: 'mcp'` so toggling `mcpEnabled` controls MCP stdio/HTTP, while checking `cliEnabled` if invoked as CLI helper; also check policy in `mcp-stdio.ts` via `service.handleJSONRPC(payload, 'mcp')`!).
4. **Export check (`packages/server/src/worker-exports.ts`)**:
   - Export `extractImageMetadata` and `ExternalAgentService` if useful; verify ZERO `node:*` / `sharp` imports in `dist/worker-exports.js`.

### 1.5 Purity Scrub (`r4-backend`)
- `packages/shared/tests/drive-sync-config.test.ts:75,79`: replace personal home directory mount path with `/Volumes/GoogleDrive`.
- `packages/server/src/media/sample-seeder.ts:413`: replace external design-tip reference with `calibrated motion curves`.
- `packages/server/tests/core-media.test.ts:309`: match updated clean description string.

### 1.6 Required Tests (`r4-backend`)
- `packages/shared/tests/swift-codec.test.ts`: `PhotoExifMetadata`, `AIGenerationMetadata`, `FolderHierarchyNode`, `InspectorInfoSection`, `ExternalAgentConfig` migration.
- `packages/server/tests/image-metadata-extractor.test.ts`: JPEG EXIF/TIFF/GPS, PNG `tEXt` A1111 + LoRAs, PNG `zTXt`/`iTXt` (zlib via `DecompressionStream`), ComfyUI graph JSON, NovelAI, InvokeAI, Midjourney, Draw Things, SwarmUI.
- `packages/server/tests/ai-mcp-agent.test.ts`: all 20 tools, 4 static + 2 dynamic resources, 4 prompts, protocol version negotiation, batch JSON-RPC, independent `mcpEnabled`/`cliEnabled` toggles, `MCPStdioFrameParser` split-chunk `Content-Length` + `NDJSON`, `runDiagnostics()`, and zero-permanent-delete invariant.
- Run: `npm run build -w @charkle/shared && npm test -w @charkle/shared && npm test -w @charkle/server && npm test -w @charkle/worker && npm run cf:typecheck && npm run cf:dry-run`.

---

## 2. Builder Section: `r4-client-core`

**Ownership**: `packages/client/src/{App.tsx,design-system/**,api/**,stores/**,components/**,lib/**,features/{auth,onboarding,sidebar,gallery,quicklook,inspector,jump,capture}/**}` (NEVER touch `features/moodboard/**`, `features/settings/**`, or backend packages).

### 2.1 Design System Foundations (`DESIGN.md` P0 / P1 / P2)
1. **`packages/client/src/design-system/tokens.css`**:
   - **Bilingual Typography Switches (`DESIGN.md` §4.2)**:
     - `h1, h2, h3, .charkle-heading { text-wrap: balance; }`
     - `p, .charkle-prose { text-wrap: pretty; }`
     - `:lang(zh) { text-autospace: normal; text-spacing-trim: trim-start; }`
     - `code, pre, kbd, input, textarea, select { text-autospace: no-autospace; }`
     - Ensure `overflow-wrap: anywhere` utility (`.charkle-wrap-anywhere`) replaces any `word-break: break-all` on CJK prose.
   - **Soft Radial Modal Veil (`.charkle-modal-veil`)**:
     - Light: `background: radial-gradient(circle at 50% 42%, rgba(20, 22, 26, 0.075) 0%, rgba(20, 22, 26, 0.165) 100%)` (ZERO `backdrop-filter`).
     - Dark: `background: radial-gradient(circle at 50% 42%, rgba(0, 0, 0, 0.34) 0%, rgba(0, 0, 0, 0.50) 100%)`.
   - **Interruptible Modal & Toast Transitions**:
     - State-driven CSS transitions (`[data-state="open"]` / `[data-state="closing"]`): Modal enter `240ms var(--ease-out)` (`scale(0.96) translateY(6px) -> none`), exit `170ms var(--ease-out)`; Toast enter `180ms var(--ease-out)` (`translateY(-6px) scale(0.96) -> none`), exit `130ms var(--ease-out)`.
   - **Coordinated Skeleton Shimmer (`.charkle-skeleton`)**:
     - Calibrated neutral fill (Light `#E8E8E5`, Dark `rgba(255,255,255,0.08)`), pure GPU opacity pulse (`1.0 -> 0.58`, `0.95s ease-in-out alternate infinite`), collapses to static tint under `prefers-reduced-motion: reduce`.
   - **Reveal Spotlight Pulse (`.charkle-reveal-spotlight`)**:
     - Crisp Studio Cobalt halo ring pulse (`900ms var(--ease-out-strong)`, 2 subtle breaths then settles cleanly; static highlight fade under Reduce Motion).
   - **Card Soft-Delete Exit (`.charkle-card-exiting`)**:
     - `150ms var(--ease-out)` `transform: scale(0.94); opacity: 0;` (never `scale(0)`, never `ease-in`).
   - **Purity Scrub**: clean external reference/author comments on `tokens.css:46,57,76,164`, `Popover.tsx:33`, `JumpAnywhereModal.tsx:311`, `SidebarView.tsx:114,299`, `FolderTree.tsx:231`.
2. **`packages/client/src/design-system/ModalShell.tsx`**:
   - Keep mounted during `170ms` exit transition (`rendered` + `closing` state with timeout cleanup) so closing never flashes abruptly.
   - Replace `bg-black/42 backdrop-blur-[3px]` with `.charkle-modal-veil`.
3. **`packages/client/src/design-system/ToastHost.tsx` & `stores/coordinatorStore.ts`**:
   - Anchor stack cleanly at **top-right (`top-4 right-5`)** matching `CharkleToastOverlay.swift`, pointer-events-none wrapper, max-width `380px`, concentric radii (`rounded-[var(--radius-popover-outer)]` outer / `6px–8px` pad / `rounded-[var(--radius-popover-inner)]` inner).
   - Support `tone: 'info' | 'success' | 'warning' | 'error'`, interruptible enter/exit transitions (`exiting` state held for `130ms`), hover & keyboard focus pause/resume (`pauseToast` / `resumeToast`), `Escape` closes focused toast.
   - Render live circular SVG countdown ring (`16×16`) on action/Undo toasts (`durationMs >= 4800`, pausing smoothly when `toast.paused`, static under Reduce Motion).
   - Wire one-click `"撤销"` Undo Toast (`restoreAssets(ids)`) into ALL soft-trash actions (`App.tsx` Backspace/Delete, `AssetCard.tsx` context menu, `BatchActionPill.tsx`, `InspectorView.tsx`) paired with crisp `150ms` card exit animation!
4. **New Design System Primitives** (all exported from `design-system/index.ts`):
   - **`useDelayedFlag.ts`**: `useDelayedFlag(active, delayMs = 300, minVisibleMs = 500)` anti-flicker hook (`DESIGN.md` §7.6).
   - **`Skeleton.tsx`**: `SkeletonBlock`, `GalleryMasonrySkeleton` (3–5 column realistic card heights), `InboxTriageSkeleton`, `CandidateGridSkeleton`, `InspectorSimilarSkeleton`, `BoardCanvasSkeleton` (3-column board layout using `useDelayedFlag(true, 300, 500)`).
   - **`EmptyStateVignette.tsx`**: 7 self-contained `160×120` (compact `132×98`) inline SVGs with 45° subtle hatch plate & automatic Light/Dark CSS variables matching `CharkleEmptyStateVignette.swift` (`emptyLibrary`, `emptyFolder`, `noFilterResults`, `emptyTrash`, `inboxZero`, `emptyMoodboard`, `emptyInspector`). Wire into `GalleryView`, `InboxZeroView`, `InspectorView`.
   - **`SegmentedControl.tsx`**: accessible `role="radiogroup"` segmented switcher with sliding/elevated active pill (`--duration-move` `--ease-in-out`) for 2–5 short options.
   - **`DisclosureGroup.tsx`**: full-row clickable disclosure (`min-h-[30px]`, rotated 90° chevron, subtle hover background, `aria-expanded`, Reduce Motion safe).
   - **`FolderHierarchyMenu.tsx`**: recursive cascading folder submenu with **pointer-trajectory safe-triangle buffer** (`DESIGN.md` §7.4 — tracks cursor delta toward open child submenu rect with ~140ms grace timer so diagonal movement never accidentally closes child menus!) + `"放入「父目录」"` self-target row + divider + descendants.
   - **`FolderHierarchyScopeTree.tsx`**: compact multi-select collapsible folder tree (port of `CharkleHierarchicalFolderScopeTree`).

### 2.2 API Client, Stores & Reveal-in-Library Helper
1. **`packages/client/src/api/client.ts`**:
   - Add `hydrateAssetMetadata(id: UUID): Promise<AssetDetailResponse>` (`POST /api/v1/assets/:id/hydrate-metadata`).
   - Add `getExternalAgentDiagnostics(): Promise<ExternalAgentDiagnosticsResponse>` (`GET /api/v1/agent/diagnostics`).
2. **`packages/client/src/stores/coordinatorStore.ts`**:
   - Add `selectedInspectorTab: 'info' | 'similar'` (persisted or synced live) + `setSelectedInspectorTab`.
   - Add `pendingGalleryReveal: { assetID: UUID; nonce: number } | null` + `requestRevealAssetInGallery(assetID)` + `clearPendingGalleryReveal(nonce)`.
   - Add `pauseToast`, `resumeToast`, `triggerToastAction`, `exiting` toast lifecycle.
   - Add `expandedSidebarFolderIDs` helper (or `revealFolderPath(folderID)` action on `libraryStore` / `coordinatorStore`) so revealing an asset in a nested subfolder automatically expands all ancestor folders in `FolderTree.tsx`!
3. **`packages/client/src/stores/syncAIStore.ts`**:
   - Add `externalAgentDiagnostics`, `isRunningAgentDiagnostics`, `runExternalAgentDiagnostics()`.
4. **`packages/client/src/lib/revealAssetInLibrary.ts`**:
   - Implement exact macOS `revealAssetInLibrary(assetID, sourceBoardID)` flow (`ce72927`):
     1. Look up asset in `libraryStore.assetsByID[assetID]` (fallback `apiClient.getAsset(assetID)` if not yet cached in memory); if missing, toast `"该素材已不在素材库中"` (`warning`) and return.
     2. Close Quick Look (`closeQuickLook()`).
     3. Determine destination: `trash` if `asset.isTrashed`, `folder(folderID)` if owning folder exists (and expand all ancestor folders in sidebar!), `inbox` if `folderID == null`, else `allItems`.
     4. Navigate to destination & await `loadAssets(targetDestination)`. If `assetID` is hidden by active search/visual/semantic filters, clear search query, visual filters, and semantic search, then reload `targetDestination` (with fallback to `allItems` if still missing).
     5. Select `[assetID]` (`selectAsset(assetID, 'replace')`) and trigger `requestRevealAssetInGallery(assetID)`.
     6. Show Toast `"已定位到「<locationPath>」"`; if `sourceBoardID` is provided, include 1-click CTA `"返回情绪板"` (`actionLabel: '返回情绪板'`, `durationMs: 6500`, `onAction: () => openBoard(sourceBoardID)`).
   - Also trigger `requestRevealAssetInGallery(id)` when jumping to an asset from `JumpAnywhereModal.tsx`.

### 2.3 Reliable Spacebar Quick Look + Unified 300px Inspector + Long-Strip & 6x–16x Zoom
1. **Deterministic Spacebar Quick Look (`App.tsx`, `QuickLookOverlay.tsx`, `GalleryFilmstripView.tsx`)**:
   - In `App.tsx` global keydown listener (capture phase where appropriate):
     - Match unmodified Space with `const isUnmodified = !e.metaKey && !e.ctrlKey && !e.altKey && !e.shiftKey;` and `(e.code === 'Space' || e.key === ' ')` (explicitly ignoring `CapsLock`/`NumLock`, guarding `!e.repeat`).
     - Work across ALL gallery views (`verticalMasonry`, `horizontalJustified`, `galleryFilmstrip`) regardless of whether Sidebar, Toolbar, or Inspector holds non-text focus (skip only when `isInputElement(e.target)` or a modal/dialog is open).
     - When opening Quick Look, blur any stale focused element (`(document.activeElement as HTMLElement | null)?.blur?.()`) so Space never gets swallowed or triggers a previously focused toolbar button!
   - In `QuickLookOverlay.tsx`:
     - Handle `⌘⌥I` / `Ctrl+Alt+I` AND `⌘I` / `Ctrl+I` to toggle `coordinatorStore.inspectorOpen` synchronously with the main workspace.
     - While editing a text field inside Quick Look's hosted Inspector: `Escape` blurs the text input first (without closing Quick Look); `Space` inserts a space normally; once unfocused, `Space` or `Escape` closes Quick Look cleanly.
2. **Unified Full-Height 300px Inspector inside Quick Look (`QuickLookOverlay.tsx` + `InspectorView.tsx`)**:
   - Delete Quick Look's separate read-only `sidePanelOpen` mini-drawer!
   - Give `InspectorView` optional props: `pinnedAsset?: AssetRecord | null`, `isQuickLookHosted?: boolean`, `onRequestCloseQuickLook?: () => void`.
   - Render `<InspectorView pinnedAsset={asset} isQuickLookHosted onRequestCloseQuickLook={closeQuickLook} />` docked full-height (`w-[300px]`, smooth `--ease-drawer` `300ms` collapse/expand) inside `QuickLookOverlay.tsx`, bound 1:1 to `coordinatorStore.inspectorOpen` and `coordinatorStore.selectedInspectorTab` (`'info' | 'similar'`).
   - Clicking a Similar Asset inside Quick Look's Inspector switches Quick Look directly to that asset and updates gallery selection; clicking a color swatch filters the library and closes Quick Look.
3. **Quick Look Original Long-Strip Scroll Mode & 6x–16x Dynamic Zoom (`QuickLookOverlay.tsx`)**:
   - Compute `isTallStripImage = !isGitHubRepo && !isSocialPost && (mediaKind === 'image' || mediaKind === 'designFile') && pixelWidth > 0 && pixelHeight >= 1600 && (pixelHeight / pixelWidth) >= 2.2`.
   - Compute `maxZoomLimit = Math.max(6, Math.min(16, Math.max(asset.pixelWidth, asset.pixelHeight) / 550))`.
   - Always load full-resolution original (`apiClient.originalMediaURL(asset.id)`) with instant thumbnail placeholder until decoded.
   - When `isTallStripImage` is true, default `isLongStripScrollMode = true`: render full-width vertically scrollable original image inside stage with a floating toggle button (`"长图滚动"` / `"适配全屏"`) in the bottom HUD; wheel scrolls vertically in long-strip mode and zooms up to `maxZoomLimit` in fit mode.
   - Replace hardcoded `#5B8DEF` loaders/accents in `QuickLookOverlay.tsx`, `GalleryFilmstripView.tsx`, and `Model3DViewer.tsx` with `var(--accent)`.

### 2.4 Reorderable Zero-Flicker Inspector + EXIF & AI Prompt Cards (`InspectorView.tsx`)
1. **Sync `tab` to `coordinatorStore.selectedInspectorTab`** (removing local `useState<'info' | 'similar'>`).
2. **Persisted Drag-Reorderable `InspectorInfoSection` Cards**:
   - Persist order in `localStorage['charkle.inspectorSectionOrder']` normalized via `normalizeInspectorSectionOrder`.
   - Support HTML5 drag-and-drop reordering across section cards + compact hover/header controls (`置顶`, `上移`, `下移`, `置底`, plus `"恢复默认顺序"` button when customized).
3. **Camera EXIF Card (`photoExif`)**:
   - Render ONLY when `hasMeaningfulCameraExif(asset.richMetadata?.photoExif)` is `true`!
   - Show camera display name, lens model, `exposureSummary` pill (`tabular-nums`), focal length (with 35mm eq.), exposure bias, metering mode, flash, white balance, capture date, software, artist/copyright, and GPS coordinates (with 1-click copy).
4. **AI Generation Prompt Card (`aiGeneration`)**:
   - Render when `!isAIGenerationEmpty(asset.richMetadata?.aiGeneration)`.
   - Show generator badge (e.g., `ComfyUI`, `Stable Diffusion (A1111)`, `NovelAI`, `Midjourney`), positive prompt box with 1-click copy button, negative prompt box with copy button, compact parameter grid (`modelName`, `sampler`, `scheduler`, `steps`, `cfgScale`, `seed`, `sizeText`, `clipSkip`), LoRA pills, and a full-row `DisclosureGroup` for `rawParameters`.
5. **Zero-Flicker Switching & On-Demand Hydration**:
   - Maintain a synchronous module-level `Map<UUID, AssetRecord>` hydrated-metadata cache + bind preview `<img>` with `loadedAssetID === asset.id` guard (never flashing the previous asset's image or delaying card visibility).
   - When inspecting an `image`/`animatedImage`/`designFile` without `photoExif` & `aiGeneration` yet (and not already hydrated this session), call `apiClient.hydrateAssetMetadata(asset.id)` once in background and upsert into `libraryStore`.
6. **Choice Controls & Hierarchy Menus**:
   - Replace bare folder `<select>` at `InspectorView.tsx:402,923` with `FolderHierarchyMenu` trigger button!
   - Replace `InspectorSimilarSkeleton` + `useDelayedFlag(loadingSimilar, 300, 500)` for bare spinner in Similar tab, and `EmptyStateVignette kind="emptyInspector"` when no asset is selected.

### 2.5 Photos-Style Persistent Exact-Asset Anchor-Locked Gallery Zoom & Reveal (`features/gallery/`)
Create **`packages/client/src/features/gallery/galleryZoomMath.ts`**:
- Export exact pure math ported from `VirtualizedMasonryView.swift` (`590b5a1` & `ce72927`):
  - `anchoredScrollY({ oldScrollY, oldAnchorRect, newAnchorRect, anchorNormV, anchorScreenY, topInset, totalHeight, viewportHeight })`:
    - If `oldScrollY <= 2 && oldAnchorRect.top <= topInset + 4`, return `0` (Row-1 cards stay cleanly below floating top capsule).
    - Otherwise return `clamp(0, maxScrollY, (newAnchorRect.top + anchorNormV * newAnchorRect.height) - anchorScreenY)`.
  - `revealScrollY({ itemRect, topInset, bottomInset, totalHeight, viewportHeight })`:
    - Centers `itemRect` vertically within usable height `[topInset, viewportHeight - min(bottomInset, viewportHeight * 0.25)]`, clamped to `[0, maxScrollY]`.
  - `pickSessionZoomAnchor({ items, scrollTop, viewportHeight, topInset, pointerPoint, selectedAssetIDs })`:
    - Priority: **1) card under cursor (`pointerPoint`)** > **2) visible selected card** > **3) card nearest viewport center**. Stores `{ assetID, normU, normV, screenY }`.
- Wire into BOTH **`VerticalMasonryView.tsx`** and **`HorizontalJustifiedView.tsx`** (and TopFilterCapsule zoom slider / `−` / `+` buttons):
  - Persist `sessionZoomAnchorRef` across consecutive zoom steps (Cmd/Ctrl+wheel, trackpad pinch, slider drag, `−`/`+` buttons); clear ONLY on manual user scroll (guarded by `isProgrammaticZoomScrollRef`) or selection change!
  - Apply `scroller.scrollTop = nextScrollY` inside `useLayoutEffect` synchronously BEFORE paint so frame 0 has 0px jump!
  - FLIP-animate card reflow (`transform` only, `240ms var(--ease-in-out)`, disabled during live scroll and under Reduce Motion): keep the exact anchor card gliding smoothly on elevated `zIndex: 30` (NEVER crossfading), and softly crossfade cards that wrapped far across rows (`Math.hypot(dx, dy) > viewportHeight * 0.75`).
  - Handle `pendingGalleryReveal` in `VerticalMasonryView`, `HorizontalJustifiedView`, and `GalleryFilmstripView`: scroll to `revealScrollY`, clear nonce via `clearPendingGalleryReveal`, and apply `.charkle-reveal-spotlight` for `950ms` to the target card!
- **Skeletons, Empty States & Choice Controls in Gallery / Capture / Onboarding / Sidebar**:
  - `GalleryView.tsx`: use `useDelayedFlag(loading && assets.length === 0, 300, 500)` + `<GalleryMasonrySkeleton />`; preserve existing grid quietly on refresh; render `<EmptyStateVignette>` (`emptyLibrary`, `emptyFolder`, `noFilterResults`, `emptyTrash`) with clear next-step CTA; wire `EmptyStateVignette kind="inboxZero"` into `InboxZeroView.tsx`.
  - `InboxTriageBar.tsx`: use `useDelayedFlag(isTriaging, 300, 500)` + `<InboxTriageSkeleton />`.
  - `TopFilterCapsule.tsx:219`, `QuickCaptureModal.tsx:452`, `OnboardingModal.tsx:1425`: audit native `<select>` controls — upgrade 2–5 short-option pickers to `<SegmentedControl>` and upgrade folder/growing pickers to `FolderHierarchyMenu` / styled custom menu.
  - `SidebarView.tsx` & `FolderTree.tsx`: widen hit targets matching `3cb9375` — make the entire **标签** header row clickable to expand/collapse (`24×24` chevron with 90° rotation), widen folder expand chevrons to `22×28`, and auto-expand ancestor folders whenever `revealAssetInLibrary` targets a nested folder!

---

## 3. Builder Section: `r4-client-studio`

**Ownership**: `packages/client/src/features/moodboard/**`, `packages/client/src/features/settings/**` (NEVER touch `design-system/**`, `stores/**`, `gallery/**`, `quicklook/**`, `inspector/**`, or backend packages).

### 3.1 Moodboard Studio Upgrades (`packages/client/src/features/moodboard/**`)
1. **Right-Click `"在素材库中定位"` (`Reveal in Library`) (`NodeViews.tsx`, `MoodboardCanvasView.tsx`, `MoodboardWorkspaceView.tsx`)**:
   - In `NodeViews.tsx` (`BoardAssetNodeView`), add `onRevealInLibrary?: () => void` prop and add `<MenuAction icon={<Crosshair size={13} />} label="在素材库中定位" ... />` directly below `"快速预览 (Space)"` (lines 600–606) when `asset` is present.
   - Thread `onRevealInLibrary={(assetID) => void revealAssetInLibrary(assetID, activeDocument?.id)}` from `MoodboardWorkspaceView.tsx` → `MoodboardCanvasView.tsx` → `NodeViews.tsx` (calling the frozen helper in `../../lib/revealAssetInLibrary`).
2. **Eliminate Layout-Property Canvas Transition (`MoodboardCanvasView.tsx:1372`, `DESIGN.md` P1-2)**:
   - Change line 1372 from transitioning `transform, width, height` to strictly `transform var(--duration-move, 240ms) var(--ease-in-out)` (NEVER transition `width` or `height`!).
   - Suspend canvas Space-pan keyboard handler whenever `useCoordinatorStore.getState().quickLookAssetID !== null` (or any modal is open) so Spacebar Quick Look dismisses cleanly without starting a canvas pan.
3. **Delayed Structural Skeletons & Miniature Empty States**:
   - `MoodboardWorkspaceView.tsx`: replace bare centered loading spinner during initial board load (`loadingBoard && !activeDocument`) with `<BoardCanvasSkeleton />` (from `../../design-system`), preserving existing board while saving/refreshing.
   - `CandidatePoolPanel.tsx`: replace bare `animate-spin` with `useDelayedFlag(loadingCandidates, 300, 500)` + `<CandidateGridSkeleton />`.
   - `MoodboardsHomeView.tsx` & `MoodboardCanvasView.tsx` (empty board state): use `<EmptyStateVignette kind="emptyMoodboard" />` matching `DESIGN.md` §5.2.
4. **Choice Controls, Hierarchical Scope Tree & Full-Row Disclosures**:
   - `NodeViews.tsx:832`: upgrade the short-option note/node `<select>` (2–5 options like note style/font size) to `<SegmentedControl>` (from `../../design-system`).
   - `MoodboardGeneratorModal.tsx`: replace flat folder scope list with `<FolderHierarchyScopeTree>` (from `../../design-system`) and use `<DisclosureGroup>` for collapsible advanced options.
   - Card removal on canvas: pair single-card delete with crisp Undo Toast (`pushToast({ message: '已从情绪板移除卡片', actionLabel: '撤销', onAction: undo })`).

### 3.2 Settings & MCP v2 UI Parity (`packages/client/src/features/settings/**`)
1. **`SettingsChrome.tsx`**:
   - Upgrade `InlineGuideDisclosure` to full-row clickable header (`w-full min-h-[28px] px-2.5 py-1.5 rounded-[var(--radius-chip)] hover:bg-black/[0.04] dark:hover:bg-white/[0.055] flex items-center justify-between`, smooth 90° chevron rotation, `aria-expanded`) matching `3cb9375`.
   - Audit `SettingsSelect` (`SettingsChrome.tsx:314`) and all panes (`GeneralSettingsPane`, `SyncSettingsPane`, `AISettingsPane`, `LibrarySettingsPane`): replace any 2–5 short-option `<SettingsSelect>` with `<SettingsSegmented>` / `<SegmentedControl>` while keeping dynamic/long lists (AI models, timezone/folders) as styled selects; converge ad-hoc `rounded-[7px]` / `rounded-[5px]` to `--radius-settings-inner` / `--radius-chip`.
   - Use full-row `<DisclosureGroup>` in `AISettingsPane.tsx` for expandable model/endpoint/advanced blocks.
2. **`shortcuts.ts` & `ExternalAgentsSettingsPane.tsx` (MCP v2 + Independent Channel Toggles + Self-Check)**:
   - Update `MCP_TOOL_INVENTORY` in `shortcuts.ts` to all **20 safe tools** (12 Read + 8 Write, matching §1.4 verbatim) + export `MCP_RESOURCE_INVENTORY` (4 static + 2 dynamic templates) and `MCP_PROMPT_INVENTORY` (4 studio workflows) + update `EXTERNAL_AGENT_SAMPLE_PROMPTS` to include Contact Sheet review, folder recommendation, and AI generation prompt extraction.
   - Update `ExternalAgentsSettingsPane.tsx`:
     - Replace single `"允许外部 AI 工具接入"` switch with TWO independent channel toggles matching macOS `7a730c9` & `fced1d5`:
       1. **`启用 MCP 服务`** (`config.mcpEnabled`) with live status badge (`已启用` / `已关闭`).
       2. **`启用本地命令行 (stdio) 服务`** (`config.cliEnabled`) with live status badge (note: on Cloudflare runtime, clarify HTTP MCP is primary and local stdio runs on self-hosted Node).
     - Keep `权限级别` (`仅只读` / `允许整理与生板`) enabled whenever `config.mcpEnabled || config.cliEnabled`.
     - Add **服务与工具连通自检** row (`运行自检` button calling `syncAIStore.runExternalAgentDiagnostics()`), displaying live summary (`正常 · 20 项安全工具（12 读 / 8 写）· 6 项资源 · 4 套工作流 · 永不允许永久删除`).
     - Update folded client snippets to include HTTP MCP JSON, Claude Code (`claude mcp add`), Codex (`codex mcp add`), and Node stdio JSON.
     - Update tool inventory disclosure title to `"查看全部 20 个安全工具、资源与工作流"` showing tools (respecting `mcpEnabled`/`cliEnabled` + `accessLevel`), 4+2 resources, and 4 prompts.
   - Keep `AccountSecurityPane.tsx`, `ExtensionsSettingsPane.tsx`, and Cloudflare/Node runtime guards in `SyncSettingsPane.tsx` & `LibrarySettingsPane.tsx` 100% intact.
   - Verify ZERO developer jargon or external reference mentions across all `features/settings/**` copy.

---

## 4. Final Verification Gate (Run After All 3 Builders Land)

```bash
npm run typecheck
npm test
node --test packages/extension/tests/extension.test.mjs
npm run build
npm run cf:typecheck
npm run cf:dry-run
```

Plus static purity & Workers-safety checks:
1. Confirm `packages/server/dist/worker-exports.js` has ZERO `node:*` or `sharp` transitive imports.
2. Confirm ZERO external inspiration/competitor/author names, ZERO personal absolute paths, ZERO `#8B5CF6` violet chrome, ZERO `transition: all`, and ZERO user-facing developer jargon across `packages/`.
3. Confirm `diff -ru ../Charkle/Resources/FigmaPlugin figma-plugin` returns empty (byte-identical).
