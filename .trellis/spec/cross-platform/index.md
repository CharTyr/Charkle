# Cross-Platform Shared Contracts (macOS · iOS/iPadOS · Windows · Android · Web)

> Single source of truth for wire protocols, file formats, safety boundaries, visual design authority ([`DESIGN.md`](../../../DESIGN.md)), and repository hygiene shared across macOS (`Sources/`), iOS/iPadOS (`ios/`, sharing `Sources/CharkleCore`), Windows (`./windows/`), Android (`./android/`, sharing `windows/crates/charkle-core` via UniFFI), and Web (`./web/`).

---

## 1. Lossless `/.charkle/` Bidirectional Sync Wire Contract

### 1. Scope / Trigger
- Trigger: Any modification to `AssetRecord`, `FolderRecord`, `MoodboardDocument`, `SyncOperation`, `SyncManifest`, or `DriveSyncEngine` on any platform (`Sources/CharkleCore/Sync/`, `web/packages/shared/src/sync/swift-codec.ts`, or `windows/crates/charkle-core/src/sync/`).

### 2. Signatures & Canonical Anchors
- macOS reference: `Sources/CharkleCore/Sync/SyncOperations.swift`, `Sources/CharkleCore/Sync/DriveSyncEngine.swift`, `Sources/CharkleCore/Contracts/*.swift`
- Web codec: `web/packages/shared/src/sync/swift-codec.ts` (`COCOA_REFERENCE_EPOCH_UNIX_SECONDS`, `isoToCocoaSeconds`, `cocoaSecondsToIso`, `toSwiftUUID`, `ASSET_SYNC_EXCLUDED_FIELDS`, `BOARD_SYNC_EXCLUDED_FIELDS`)
- Windows codec & engine: `windows/crates/charkle-core/src/wire/swift_codec.rs`, `windows/crates/charkle-core/src/sync/engine.rs` (see also [Windows Client Guidelines](../windows/index.md))

### 3. Contracts
1. **Timestamps (Cocoa Reference Epoch)**:
   - Swift default `JSONEncoder` encodes `Date` as floating-point seconds since `2001-01-01T00:00:00Z` (`offset = 978_307_200` seconds from Unix epoch).
   - Encode: `cocoaSec = unixMs / 1000 - 978_307_200`.
   - Decode: accept numeric Cocoa seconds (`new Date((v + 978_307_200) * 1000)`) and ISO-8601 fallback strings.
2. **UUIDs & Binary Data**:
   - UUIDs MUST be canonical **uppercase RFC-4122** (`XXXXXXXX-XXXX-XXXX-XXXX-XXXXXXXXXXXX`).
   - Binary `Data` payloads encode as standard Base64 strings.
3. **Directory Layout inside Library Root**:
   - Human-readable media folders live at `<Root>/Inbox/` and `<Root>/<UserFolder>/...`.
   - Sync metadata lives strictly under `<Root>/.charkle/`:
     - `manifest.json` (`{ "version": 1, "rootFolderID": "...", "directories": { ... } }`)
     - `ops/ops-<deviceId>-<seq>.jsonl` (newline-delimited `SyncOperation` JSON objects)
     - `boards/<UUID>.json` (per-board `MoodboardDocument`)
     - `vectors/` (binary vector shards)
4. **Swift Keyed-Enum Payloads**:
   - `BoardLayoutMode`: `{"autoEditorial":{"_0":{...}}}` or `{"freeform":{}}` (MUST remain decodable on all platforms even when default creation is `freeform`).
   - `BoardNodeKind`: `{"assetRef":{...}}`, `{"note":{...}}`, `{"groupFrame":{...}}`, `{"paletteStrip":{...}}`.
   - `SyncOperation`: `{ "stamp": { "time": Int64, "device": String }, "change": { "<case>": { ... } }, "projectLocation"?: false }`.
   - `AssetChanges.fields` & `BoardChanges.fields`: map of `{ [fieldName]: "<base64-encoded-json-fragment>" }`, excluding `ASSET_SYNC_EXCLUDED_FIELDS` (`id`, `tags`, `isLocalOriginalCached`, `updatedAt`, `updatedHLC`) and `BOARD_SYNC_EXCLUDED_FIELDS` (`id`, `nodes`, `connectors`, `inkStrokes`, `updatedAt`, `updatedHLC`).
5. **Conflict Resolution & Deletion Invariants**:
   - HLC `(time, device)` per-field Last-Write-Wins + tag tombstone sets.
   - Permanently deleted local assets MUST record deletion tombstones so they never respawn from cloud sync; `driveFileID` + `contentHash` track cloud-side renames/moves without losing asset identity.
   - Logical paths inside `/.charkle/` MUST use POSIX `/` separators; Windows clients sanitize illegal OS filename characters (`<>:"/\|?*`) only at local disk projection.

### 4. Validation & Error Matrix
- Malformed or non-finite timestamp -> reject/throw decode error rather than writing `NaN` into `manifest.json` or `ops/*.jsonl`.
- Unknown enum case or future optional `Codable` field -> decode safely with backward-compatible defaults; never drop existing board/asset records.

### 5. Good / Base / Bad Cases
- **Good**: A moodboard created on macOS syncs via Google Drive into Web and Windows with identical UUIDs, timestamps, node frames, and tags, and edits converge cleanly.
- **Base**: Legacy `.autoEditorial` boards decode without error and seamlessly upgrade/render.
- **Bad (Prevented)**: Encoding Unix milliseconds instead of Cocoa seconds shifts every synced asset date by 31+ years on macOS.

### 6. Tests Required
- macOS: `Tests/CharkleTests/DriveSyncTests.swift`
- Web: `web/packages/shared/tests/swift-codec.test.ts` (`swift-codec` round-trip verification)
- Windows: `windows/crates/charkle-core/tests/wire_codec_tests.rs` and `windows/crates/charkle-core/tests/sync_engine_tests.rs`

### 7. Wrong vs Correct
```ts
// WRONG: Writing Unix timestamp and lowercase UUID into /.charkle/ops/
{ id: id.toLowerCase(), updatedAt: Date.now() }

// CORRECT: Canonical uppercase UUID and Cocoa epoch seconds
{ id: toSwiftUUID(id), updatedAt: isoToCocoaSeconds(nowIso) }
```

---

## 2. `.charkleboard` Figma / FigJam Bridge Contract

- **Format**: Standard ZIP archive with `.charkleboard` extension (`format: "charkle-figma-bridge"`, `version: 1`).
- **Required Entries**:
  - `board.json` + `migration-report.json`: board metadata, `objects[]` (`image`, `note`, `groupFrame`, `paletteStrip`, `unsupported` with `geometry: { x, y, width, height, angle, flipX, flipY }`), `connectors[]`, `inkStrokes[]`, `originals[]`, `report`.
  - `tiles/<assetUUID>-<x>-<y>.png`: lossless PNG tiles strictly aligned to the `4096×4096 px` pixel grid with 64-char lowercase hex SHA-256 checksums.
  - `originals/<assetUUID>.<ext>`: raw files required for native `figma.createGif` animated GIFs in FigJam.
- **Plugin Parity**: `Resources/FigmaPlugin/` and `web/figma-plugin/` MUST stay byte-identical and pass `node scripts/test-figma-plugin.cjs` (Windows exporter in `windows/crates/charkle-core/src/export/figma_bridge.rs` also verifies directly against `Resources/FigmaPlugin/code.js`).

---

## 3. External Agent & MCP Safety Policy (20 Tools · 4+2 Resources · 4 Prompts)

- **Protocol & Transport**:
  - JSON-RPC 2.0 single & batch requests over stdio (`NDJSON` and split-chunk-safe `Content-Length` framing) or HTTP; negotiates `protocolVersion` against `["2025-11-25", "2025-06-18", "2025-03-26", "2024-11-05"]`; advertises `tools`, `resources`, `prompts`, and `logging`.
  - Every tool emits complete MCP Tool Annotations (`title`, `readOnlyHint`, `destructiveHint: false`, `idempotentHint`, `openWorldHint`) while keeping total `tools/list` JSON schema budget lean (`< 18 KB`).
  - **Low-Token Wire Conventions (v1.2.2+)**:
    - MCP tool text payloads default to compact JSON (no pretty whitespace); `charkle` CLI auto-switches to compact single-line JSON when stdout is piped/non-TTY (opt-in `--pretty` / `--human`).
    - Every ID parameter (`asset_id`, `asset_ids`, `folder_id`, `board_id`, `seed_asset_ids`, `unlike_asset_ids`, `exclude_asset_ids`) and resource URI (`charkle://assets/{asset_id}`, `charkle://boards/{board_id}`) accepts both canonical UUIDs and unambiguous **8+ character short ID prefixes** (backed by primary-key prefix lookup; ambiguous prefixes fail explicitly with candidate IDs).
    - `detail` supports `"visual"` (ultra-lean manifest auto-selected whenever `render_contact_sheet: true`), `"compact"`, `"standard"`, and `"full"`.
    - Parent folder queries default to `include_subfolders: true` (opt-out with `false` / `--no-subfolders`).
    - Canonical low-token Agent Skill lives at `Resources/AgentSkill/charkle/SKILL.md`.
- **Read Tools (12)**:
  - `library_overview` (semantic atlas: counts incl. untagged/trashed, compact folders with `recursiveAssetCount` / `topTags` / `palette` / `dominantAspect`, smart folders, top tags, aspect/media mix, boards, optional `compact` / `include_folder_profiles`), `search_assets` (FTS + CJK word-boundary terms + Pinyin, `include_subfolders` default `true`, `tags`/`any_tags`/`exclude_tags`/`exclude_asset_ids`, `media_kinds`, `aspect_shape`, `color_hex`/`color_tolerance`, CIELAB `tone: dark|light|warm|cool|vivid|muted|high_contrast`, `smart_folder_*`, `only_trashed`, `sort_by`, `diversify`, auto `facets`, one-shot `render_contact_sheet` + `sheet_max_width` `[512..1920]`, pagination), `list_inbox` (paginated, one-shot `render_contact_sheet`), `get_asset` (single `asset_id` or batch `asset_ids` 1–12 finalists with hydrated EXIF, AI generation prompts, social post, GitHub repo metadata, optional `include_image: true`), `render_contact_sheet` (1–24 assets, `max_width` `[512..1920]` default `1024`, multi-intent `queries[]` 2–6 directions in one Contact Sheet, `tone`, `diversify`, `include_image`), `find_similar_assets` (with `unlike_asset_ids` repulsion, `diversify`, one-shot `render_contact_sheet`), `semantic_search` (bilingual EN↔ZH visual expansion, CIELAB tone/aspect extraction, multi-direction `queries[]`, `seed_asset_ids`, `unlike_asset_ids`, `visual_rerank`, Round-Robin visual `diversify`, auto `facets`, one-shot `render_contact_sheet`), `quick_jump`, `suggest_folder`, `list_boards`, `get_board_context` (with node frames, crops, connectors, candidate pool), `export_board_image` (high-res `preview1400` tiles, optional `include_image`).
- **Safe Write Tools (8)**:
  - `organize_assets` (explicit `ai_description` overwrite, tags, suggested tags, rating, notes, folder/Inbox, offline pin), `create_folder`, `update_folder` (rename, move, appearance — never delete), `ingest_asset` (single/batch files or directories, URLs, text; returns post-patch tagged assets), `compose_moodboard`, `patch_moodboard` (non-overlapping placement below existing content, locked-card protection, sections, notes), `trash_assets`, `analyze_assets` (local Vision/EXIF/AI-prompt analysis + optional live rich-metadata refresh).
- **Resources (4 static + 2 templates)**:
  - Static: `charkle://library/overview`, `charkle://boards`, `charkle://folders`, `charkle://smart-folders`
  - Dynamic templates: `charkle://assets/{asset_id}`, `charkle://boards/{board_id}`
- **Prompts (4)**:
  - `triage_inbox`, `curate_moodboard`, `extract_design_tokens`, `inspect_ai_prompts`
- **Non-Negotiable Invariant**: Permanent deletion of assets and deletion of folders are **STRICTLY FORBIDDEN** through any External Agent / MCP / CLI surface (`trash_assets` is soft-trash only). Channel switches (`mcpEnabled` / `cliEnabled`) and access level (`readOnly` / `readWriteOrganize`) are enforced independently.

---

## 4. Repository Purity, Privacy & Acknowledgements Policy

- **Zero External Inspiration / Author Mentions**: Never include names of external reference/competitor products, design-tip authors, or third-party icon-tool branding anywhere in tracked source code, comments, test fixtures, specs, docs, or user-facing UI strings.
- **Approved Integration Credits**: Actual runtime integrations and tools (e.g., Google Drive, WebDAV, Figma / FigJam, X / Threads / Bluesky / GitHub) are referenced strictly as technical integrations; [`gdirect`](https://github.com/mizorewww/gdirect) is explicitly credited in the root `README.md` **Acknowledgements** section as the Google Drive direct-connection fallback.
- **Zero Local Path / Secret Leaks**: Never commit `/Users/<name>/...` personal absolute paths, `Resources/GoogleOAuthClient.json`, `.env*`, `.dev.vars*`, API keys, OAuth tokens, or code-signing certificate identities.
- **Git Push Discipline**: Always push explicitly (`git push origin main` or specific tag) — NEVER run `git push --all` or `--mirror` (which would leak local internal checkpoint refs).

---

## 5. Cross-Platform Gallery & Quick Look Interaction Contracts

1. **Deterministic Spacebar Quick Look Toggle**:
   - Pressing unmodified `Space` (explicitly ignoring `CapsLock`, `NumPad`, and `Fn` modifier bits) MUST open Quick Look for the selected asset across Masonry, Justified, and Gallery Filmstrip views regardless of which non-text pane currently holds focus, and MUST exit Quick Look cleanly when Quick Look is open (unless an editable field inside Quick Look's Inspector or a modal dialog/sheet has focus).
   - Opening Quick Look MUST resign stale text-input focus from underlying views (such as the Search Bar) and suspend any underlying Moodboard Space-pan handler so Space never fails to dismiss or immediately re-opens Quick Look.
2. **Quick Look Side Inspector 1:1 Parity & Synchronized Visibility**:
   - The Quick Look side inspector MUST reuse the exact same full-height `300px`/`300pt` single-asset `Inspector` component (identical card set, editability, drag-to-reorder order, color copy/filter, EXIF/AI metadata, and Similar Assets tab) rather than a shrunk or read-only duplicate drawer.
   - Inspector visibility (`isInspectorVisible`) and active tab (`Info | Similar`) MUST stay synchronously bound between normal library view and Quick Look so collapsing or expanding on either side keeps both views in sync.
3. **Exact-Asset Anchor-Locked Smooth Gallery Zoom**:
   - Zooming the gallery via trackpad pinch, `⌘/Ctrl+Scroll`, slider, or `−`/`+` controls MUST lock onto ONE persistent exact asset card (`sessionZoomAnchor`: cursor card > visible selected card > viewport center card) across consecutive zoom steps until the user manually scrolls or changes selection.
   - Row-2+ anchor cards MUST stay pinned to their exact on-screen Y even when zooming in from `scrollY = 0`, while Row-1 cards stay flush beneath the floating top bar; the exact anchor card MUST always glide continuously on top (never crossfade-pop), while non-anchor far-wrapping cards softly crossfade into place.
4. **Moodboard-to-Library Asset Reveal**:
   - Right-clicking any asset node on a Moodboard MUST offer `"在素材库中定位"` (`Reveal in Library`), navigating directly to the asset's actual location (owning folder with ancestors expanded, Inbox when unassigned, or Trash when soft-deleted), clearing blocking search/visual filters if needed, selecting & centering that exact card in the gallery with a subtle spotlight pulse, and providing a 1-click `"返回情绪板"` toast CTA.
5. **Universal Web URL Collection & Direct Default-Browser Open**:
   - All `http`/`https` URLs (including case-insensitive schemes, Unicode paths, standalone `www.` domains, balanced-paren URLs, and short share copy `<= 320` chars / `<= 5` lines) MUST parse into `.webBookmark` assets across paste, drag-drop, shelf, and CLI/MCP surfaces without misclassifying long prose notes.
   - Generic websites (outside in-app GitHub Repository and X/Threads/Bluesky rich viewers) MUST resolve thumbnails in a single pass via a 3-tier fallback (1. direct image / OG + Twitter + `image_src` + JSON-LD with CJK charset & `Referer`; 2. ephemeral offscreen WebView `1280×800` snapshot with autoplay disabled & blank/interstitial guards; 3. `1200×750` editorial bookmark card with favicon & theme accent), ALWAYS preserving the original collected `sourceURL` (never overwriting with login redirects).
   - Opening a generic web bookmark (`isExternalWebLink`: double-click, Spacebar, Quick Jump, Ring Gallery, Moodboard, Top Shelf, Inspector) MUST launch the system default browser directly rather than opening an in-app Quick Look modal, while Filmstrip stage browsing shows the thumbnail + browser-open button.
6. **4th Gallery View Mode — Outside 3D Ring Gallery (`ringGallery`)**:
   - Alongside Vertical Masonry, Horizontal Justified, and Gallery Filmstrip, desktop clients offer an Outside-only eye-level curved 3D ring (`cardHeight = 300`, `gap = 18`, reference circumference `22 * 198 = 4356`, `R ≈ 693.28`, `perspective = 1500px`, `depthBlur = 2px`, `farFade = 96%`, `cornerRadius = 32px` superellipse-4) rendering library pictures directly without cropping landscape assets: every card shares `cardHeight` and takes its natural aspect-ratio arc width (`clamp(aspect, 0.52, 2.25) * cardHeight`, packed via prefix-sum `RingCardTrack` with exact `gap` spacing, `O(log N)` nearest lookup, smooth rear-seam fade, and front-card-width-aware DoF sharp zone).
   - The ring MUST scale dynamically with viewport width and height (`scaleForWidth` targeting ~94% horizontal fill using exact projected half-width `R·P / sqrt(P² + 2PR)`, capped by vertical headroom `0.78 * usableH / cardHeight`, clamped to `[0.34, 2.8]`), compensating drag/scroll/velocity by `cardScale` for 1:1 pointer tracking, with demand-driven idle pause (`0%` idle GPU), Reduced Motion `<= 200ms` cap, and a collapsed-by-default live tuning panel with reset.
7. **Flexible Root Bounds, Full-Bleed Chrome & 3-Tier Responsive Moodboard Bottom Dock**:
   - Moodboard canvases MUST measure live viewport bounds on an infinitely flexible `minWidth: 0, minHeight: 0` container with the world stage isolated from intrinsic sizing so shrinking a window NEVER ratchets or clips the bottom of the app.
   - Moodboard bottom tool dock + zoom pill MUST adapt cleanly across 3 width tiers (`wide >= 820`, `medium 560–819`, `compact < 560`) with floating contextual pen/connector sub-pills on `< 960` widths and zero overlap/clipping.
   - Full-bleed titlebar chrome MUST align vertical column dividers flush to `y = 0`, widen collapsed icon rail to `76px/76pt`, and keep primary action buttons `shrink-0` / non-wrapping in narrow windows and drop shelves.
8. **Ultra-Low-Resource Minimal Background Shelf Mode**:
   - Desktop clients MUST support a minimal background capture mode (Tray/Menu Bar + Top-Edge Drop Shelf only) that tears down the main window and purges decoded thumbnail memory buffers for `< 1%` idle CPU while retaining a lightweight Recent Assets strip inside the shelf for instant drag-out. Auto-collapse timers MUST be atomically cancelled and cleared on every hover/banner/pin transition so unpinned shelves never wedge open.
9. **Xiaohongshu (小红书) Rich Note Parsing & Chrome / Safari Batch Bookmark Sync Bridge**:
   - `SocialPlatform` includes `xiaohongshu` (`小红书`, `#FF2442` accent, noun `"笔记"`, hiding internal 24-hex user IDs in subtitle typography). Parsers MUST support `/explore/<id>`, `/discovery/item/<id>`, `/user/profile/<uid>/<id>`, and `xhslink.com` short links (including mobile app share copy), preserving `xsec_token` / `xsec_source` query parameters for openability while computing token-independent canonical deduplication keys (`xhs:<noteID>`, `x:<tweetID>`).
   - Xiaohongshu resolvers parse `window.__INITIAL_STATE__` (sanitizing bare JS `undefined` -> `null` outside strings) with multi-`og:image` fallback and interstitial rejection, and ALWAYS attach `Referer: https://www.xiaohongshu.com/` + desktop browser `User-Agent` when fetching `*.xhscdn.com` / `*.xiaohongshu.com` media or avatars. Xiaohongshu bookmark cards MUST render as native vertical feed cards (`900×1440`, `aspectRatio = 0.625`) combining a strict vertical **3:4 (`900×1200`)** full-bleed cover on top with a crisp `240px` paper-white footer preserving the bold note title (up to 2 lines), author avatar/name, and like count (with an idempotent startup migration upgrading legacy covers and 3:4 multi-image grid alignment in Quick Look).
   - Desktop clients expose a loopback-only Bearer-authenticated extension bridge (`127.0.0.1:41937` on macOS, speaking the exact `/api/v1/*` contract plus `GET /api/v1/health`, `POST /api/v1/auth/local-pair`, `GET /api/v1/assets/existing-sources`, `POST /api/v1/folders` with `reuseExisting`, and `socialBookmark` + `skipDuplicates` on `POST /api/v1/assets/ingest`). Same-machine zero-config pairing (`POST /api/v1/auth/local-pair`, default ON and toggleable in Settings) MUST strictly require a browser-extension `Origin` (`chrome-extension://`, `safari-web-extension://`, `moz-extension://`) plus `X-Charkle-Extension: 1`, rejecting all web/localhost origins with `403`, while the extension auto-pairs on install/open and self-heals on port/token changes without exposing raw token fields unless manually expanded. Shared Chrome & Safari MV3 extension source lives in `Resources/BrowserExtension/` (embedded inside `Charkle.app/Contents/Resources/BrowserExtension` for Chromium and compiled into a signed sandboxed `CharkleSafariExtension.appex` inside `Contents/PlugIns/` with `NSAllowsLocalNetworking = true` and classic single-file `background.js` for Safari); its image grabber grid MUST use explicit `grid-auto-rows` + `align-content: start` to avoid WebKit implicit-row overlap.

---

## 6. v1.3–v1.5.1 Cross-Platform Interchange & Media Contracts

1. **Multi-Backend Sync & Anti-Resurrection Invariants (`v1.4.0+`)**:
   - `DriveTransportMode` supports `directAPIWithGDirect`, `iCloudDrive`, `webDAV`, `gdirectMount`, and `localOnly`; multiple `SyncBackendProfile` instances may run simultaneously against independent roots.
   - Permanent asset deletion MUST record tombstones propagated via `/.charkle/ops/` and checked before re-ingesting cloud files by `driveFileID` / relative path so older offline devices never resurrect deleted assets.
2. **6-Platform Social Batch Collector & Non-AI Smart Deduplication (`v1.3.0+`)**:
   - `Resources/BrowserExtension/` (`v1.3.0+`) supports batch author-media & saved-collection import across 6 visual platforms (`x`, `pixiv`, `bluesky`, `threads`, `instagram`, `xiaohongshu`) with per-post subfolder organization and token-independent canonical deduplication keys.
   - Smart Deduplication (`SmartDeduplicator` / `dedup.rs`) MUST remain 100% deterministic without requiring Cloud AI, cover all 8 `MediaKind`s, retain the highest-quality version, losslessly merge tags/notes/folder/moodboard references onto the survivor, and route discarded duplicates to reversible soft Trash by default.
3. **Third-Party Format Interoperability (`v1.3.0+` / `v1.5.0+`)**:
   - **`.eaglepack` / `.library` Lossless Importer**: Preserves nested folders, tags, notes, ratings, URLs, and originals without duplicating existing identical files.
   - **PureRef `.pur` Bidirectional Codec**: Supports lossless import of `.pur` reference boards into Charkle libraries/moodboards and export of Charkle moodboards to `.pur` while preserving relative spatial transforms.
4. **Video Bookmarks, Zero-Download Streaming & Frame-to-Cover (`v1.5.0–v1.5.1`)**:
   - `SocialPlatform` includes `youtube` and `bilibili` alongside `x`, `threads`, `bluesky`, `xiaohongshu`, `pixiv`, `instagram`. Video bookmarks remain zero-download by default (storing link, 16:9 cover, duration, and summary/chapters).
   - Preview-time streaming resolves Tier 1 direct HTTP Range/HLS stream first and automatically falls back to Tier 2 official embed players (with `strict-origin-when-cross-origin` Referer policy for YouTube) while tearing down media cleanly on exit (`0%` idle CPU).
   - **"设当前帧为封面" (`updateAssetCoverImage`)** applies to both local `.video` assets and streaming video bookmarks: atomically regenerates `grid520` & `preview1400` thumbnails, refreshes `dominantColors`, invalidates UI thumbnail caches immediately, and queues `/.charkle/thumbnails/` sync.
