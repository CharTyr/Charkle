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
4. **Swift Keyed-Enum & Rich Metadata Payloads**:
   - `BoardLayoutMode`: `{"autoEditorial":{"_0":{...}}}` or `{"freeform":{}}` (MUST remain decodable on all platforms even when default creation is `freeform`).
   - `BoardNodeKind`: `{"assetRef":{...}}`, `{"note":{...}}`, `{"groupFrame":{...}}`, `{"paletteStrip":{...}}`.
   - `GalleryLayoutMode`: `"verticalMasonry" | "horizontalJustified" | "galleryFilmstrip" | "ringGallery" | "compactList"` (`"compactList"` = 5th universal Tactile Studio Compact View `"紧凑视图"`).
   - `MediaKind.document` canonical extension & MIME detection: `"pdf" | "md" | "markdown" | "txt" | "rtf" | "doc" | "docx" | "wps" | "et" | "dps" | "xlsx" | "xls" | "pptx" | "ppt" | "odt" | "ods" | "odp" | "epub" | "ofd" | "key" | "pages" | "numbers" | "json" | "yaml" | "yml" | "toml" | "csv"` (plus MIME fallbacks matching `application/pdf`, `text/*`, `*officedocument*`, `*msword*`, `*ms-excel*`, `*ms-powerpoint*`, `*opendocument*`, and `application/epub+zip`).
   - `AssetRichMetadata.versionStack` (`AssetVersionStackMetadata`, optional, media-agnostic across documents, images, design files, etc.):
     ```json
     {
       "groupID": "UPPERCASE-RFC4122-UUID",
       "versionNumber": 4,
       "parentAssetID": "UPPERCASE-RFC4122-UUID",
       "versionLabel": "v4 · 张主任改",
       "editorName": "张主任",
       "changeNote": "核定第三部分预算数字",
       "isPinnedPrimary": true
     }
     ```
     - `groupID` (required `UUID`, uppercase RFC-4122), `versionNumber` (`Int >= 1`, default `1`), `parentAssetID` (`UUID?`, uppercase RFC-4122), `versionLabel` (`String?`), `editorName` (`String?`), `changeNote` (`String?`), `isPinnedPrimary` (`Bool`, default `false`).
     - Canonical sibling ordering: ascending by `(versionNumber, createdAt, id)`. Canonical Primary Version (`resolvePrimaryAsset`): last sibling in sorted order with `isPinnedPrimary == true`, falling back to the highest `versionNumber` sibling when none is pinned.
   - `AssetRichMetadata.document` (`DocumentRichMetadata` + optional `DocumentDiffSummary`):
     ```json
     {
       "formatFamily": "docx",
       "wordCount": 3420,
       "pageCount": 6,
       "sheetNames": ["2026预算汇总", "部门明细"],
       "hasNativeRevisions": true,
       "hasTextLayer": true,
       "diffSummary": {
         "comparedToAssetID": "UPPERCASE-RFC4122-UUID",
         "addedBlocks": 2,
         "removedBlocks": 1,
         "modifiedBlocks": 5,
         "movedBlocks": 1,
         "highRiskNumberChanges": 2,
         "highRiskDateChanges": 1,
         "minimapBuckets": [0, 0, 1, 0, 0, 2, 2, 0, 1, 0, 2, 0]
       }
     }
     ```
     - `formatFamily` (`String`, known values: `"docx" | "xlsx" | "pptx" | "pdf" | "markdown" | "plainText" | "legacyOffice" | "epub" | "ofd" | "other"`, open-string tolerant so future tokens map safely to `"other"` without failing sync decode), `wordCount` (`Int >= 0`, default `0`), `pageCount` (`Int >= 0`, default `0`), `sheetNames` (`[String]`, default `[]`), `hasNativeRevisions` (`Bool`, default `false`), `hasTextLayer` (`Bool`, default `true`), `diffSummary` (`DocumentDiffSummary?`).
     - `DocumentDiffSummary`: `comparedToAssetID` (required `UUID`, uppercase RFC-4122), `addedBlocks` / `removedBlocks` / `modifiedBlocks` / `movedBlocks` / `highRiskNumberChanges` / `highRiskDateChanges` (`Int >= 0`, default `0`), and `minimapBuckets` (`[Int]` normalized to `12` buckets clamped to `0 | 1 | 2`, where `0` = unchanged, `1` = normal add/modify/move, `2` = high-risk number/currency/percentage/date mutation).
     - **Sync Log Hygiene Invariant**: Full extracted document plain text and structured block/sheet payloads MUST stay in a strictly local SQLite derived table (`document_content_cache` keyed by `(asset_id, content_hash)` feeding `assets_fts` + Pinyin/initials) and MUST NEVER be written into `AssetRecord` wire payloads or `/.charkle/ops/*.jsonl`.
   - `SyncOperation`: `{ "stamp": { "time": Int64, "device": String }, "change": { "<case>": { ... } }, "projectLocation"?: false }`.
   - `AssetChanges.fields` & `BoardChanges.fields`: map of `{ [fieldName]: "<base64-encoded-json-fragment>" }`, excluding `ASSET_SYNC_EXCLUDED_FIELDS` (`id`, `tags`, `isLocalOriginalCached`, `updatedAt`, `updatedHLC`) and `BOARD_SYNC_EXCLUDED_FIELDS` (`id`, `nodes`, `connectors`, `inkStrokes`, `updatedAt`, `updatedHLC`).
5. **Conflict Resolution & Deletion Invariants**:
   - HLC `(time, device)` per-field Last-Write-Wins + tag tombstone sets.
   - Permanently deleted local assets MUST record deletion tombstones so they never respawn from cloud sync; `driveFileID` + `contentHash` track cloud-side renames/moves without losing asset identity.
   - Logical paths inside `/.charkle/` MUST use POSIX `/` separators; Windows clients sanitize illegal OS filename characters (`<>:"/\|?*`) only at local disk projection.

### 4. Validation & Error Matrix
- Malformed or non-finite timestamp -> reject/throw decode error rather than writing `NaN` into `manifest.json` or `ops/*.jsonl`.
- Unknown enum case or future optional `Codable` field -> decode safely with backward-compatible defaults; never drop existing board/asset records.
- Unknown future `SocialPlatform` wire string (e.g. `"douyin"` on older builds or future platform tokens) -> MUST deserialize losslessly (e.g. `SocialPlatform::Unknown(String)` with custom `Serialize`/`Deserialize` preserving the exact wire token across SQLite and `/.charkle/ops/*.jsonl`); closed-enum decode errors that roll back `SyncFields::merge` / `apply_op_shard` transactions are strictly forbidden.

### 5. Good / Base / Bad Cases
- **Good**: A moodboard created on macOS syncs via Google Drive into Web and Windows with identical UUIDs, timestamps, node frames, and tags, and edits converge cleanly.
- **Base**: Legacy `.autoEditorial` boards and unrecognized future `SocialPlatform` strings decode without error, preserve raw wire values on round-trip, and never stall `deviceCursors`.
- **Bad (Prevented)**: Encoding Unix milliseconds instead of Cocoa seconds shifts every synced asset date by 31+ years on macOS; decoding `SocialPlatform` as a closed enum aborts and rolls back an entire 40-shard sync transaction on the first unknown platform string.

### 6. Tests Required
- macOS: `Tests/CharkleTests/DriveSyncTests.swift`, `Tests/CharkleTests/DocumentCoreAndVersionStackTests.swift`, `Tests/CharkleTests/CompactGalleryAndDocumentUITests.swift`
- Web: `web/packages/shared/tests/swift-codec.test.ts` (`swift-codec` round-trip verification)
- Windows: `windows/crates/charkle-core/tests/wire_codec_tests.rs`, `windows/crates/charkle-core/tests/sync_engine_tests.rs`, `windows/crates/charkle-core/tests/douyin_sync_tests.rs`, and `windows/crates/charkle-core/tests/document_and_version_stack_tests.rs` (including `SocialPlatform::Unknown(String)`, `AssetRichMetadata.versionStack`, and `AssetRichMetadata.document` round-trip through `SyncFields::merge` and `apply_op_shard`)

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

## 3. External Agent Pure MCP v2 Safety & Contract (10 Tools · 5+2 Resources · 5 Prompts)

- **Protocol & Dual Transport (CLI Subcommands Retired)**:
  - Pure MCP v2 JSON-RPC 2.0 single & batch requests over **local `stdio`** (`charkle mcp`, works even when the desktop app is closed) AND **Streamable HTTP** (`POST /api/v1/mcp` + `GET /api/v1/mcp/download/<ticket>`, enabling cross-machine & Web/Cloudflare Agents). Negotiates `protocolVersion` against `["2025-11-25", "2025-06-18", "2025-03-26", "2024-11-05"]`; advertises `tools`, `resources`, `prompts`, and `logging`.
  - Every tool emits complete MCP Tool Annotations (`title`, `readOnlyHint`, `destructiveHint: false`, `idempotentHint`, `openWorldHint`) with a lean `tools/list` schema budget (`< 12 KB`).
  - **Low-Token & Cross-Machine Wire Conventions (MCP v2)**:
    - Tool text payloads default to compact JSON; disk `output_path` is strictly retired (all Contact Sheets & Moodboard snapshots return inline MCP `image` blocks).
    - Every ID parameter and dynamic resource URI accepts both canonical UUIDs and unambiguous **8+ character short ID prefixes**.
    - Remote HTTP MCP requires **Scoped Bearer Tokens** (`ExternalAgentToken`, stored strictly as SHA-256 hash + display prefix; completely separate from browser-extension tokens), hides server local filesystem paths, forbids server `file_path` reads on `ingest_assets`, and issues short-lived signed `downloadURL` tickets (`GET /api/v1/mcp/download/<ticket>`). Even when `allowRemoteHTTPMCP` binds HTTP on `0.0.0.0`, all browser-extension endpoints remain strictly loopback-only (`127.0.0.1`).
    - Canonical Pure MCP v2 Agent Skill lives at `Resources/AgentSkill/charkle/SKILL.md`.
- **3-Tier Permission Boundaries (`ExternalAgentAccessLevel`)**:
  - `readOnly`: read tools + `deduplicate_assets(action:"scan")` + `rollback_run(action:"list")`.
  - `inboxAndEnrich`: adds `ingest_assets` (to Inbox/existing folders, no board writes) and `organize_assets` restricted to Inbox assets or pure enrichment (`ai_description` / `add_suggested_tags` / `analyze`), forbidding `trashed` and curated folder moves.
  - `readWriteOrganize`: full safe organize, `manage_folder` (create/update only), `save_moodboard`, `deduplicate_assets(action:"merge")` (soft Trash only), and `rollback_run(action:"rollback")`.
- **Read Tools (4)**:
  - `library_overview` (semantic atlas: counts, compact folders with `recursiveAssetCount`/`topTags`/`palette`/`dominantAspect`, smart folders, canonical `topTags`, `taxonomy`, boards, permissions), `query_assets` (6-in-1 recall + inline Contact Sheet: `query`/`queries[]`/`asset_ids`, `only_inbox`, folder recursion default `true`, tags/any_tags/exclude_tags, CIELAB `tone`, `seed_asset_ids`, `unlike_asset_ids`, `diversify`, `contact_sheet`, `include_folder_suggestions`, stateful `session_id` seen-tracking, auto `facets` & 0-match `relaxationHints`), `inspect_assets` (1–12 finalists with hydrated EXIF/AI prompt/social/GitHub/OCR, optional `include_image`, normalized `crop_box` detail zoom, and HTTP `include_download_url`), `get_board` (lists all boards when selector omitted; reads board context + optional inline PNG `include_snapshot`).
- **Safe Write Tools (6 — All Emit `runID` for Compensating HLC Rollback)**:
  - `ingest_assets` (`web_url(s)`, cross-machine `inline_files` Base64 up to 16 MB/file & 32 MB/batch, `text`, and stdio-only `file_path(s)`), `organize_assets` (heterogeneous `items[]` up to 50 per-asset mutations OR uniform `asset_ids[]`, `dry_run: true` impact diff, canonical tag folding, `ai_description`, `add_suggested_tags`, `analyze`, `refresh_rich_metadata`, soft `trashed`), `manage_folder` (`action: "create" | "update"`, `reuse_existing` default `true`, never delete), `save_moodboard` (create via `sections`/`asset_ids`/`prompt` OR non-destructive patch preserving locked nodes), `deduplicate_assets` (`action: "scan"` with comparison Contact Sheet + `action: "merge"` always `.moveToTrash` with lossless metadata/board-ref merge), `rollback_run` (`action: "list" | "rollback"` restoring assets, folders, and moodboards via compensating HLC ops).
- **Resources (5 static + 2 templates)**:
  - Static: `charkle://library/overview`, `charkle://library/taxonomy`, `charkle://boards`, `charkle://folders`, `charkle://smart-folders`
  - Dynamic templates: `charkle://assets/{asset_id}`, `charkle://boards/{board_id}`
- **Prompts (5)**:
  - `triage_inbox`, `curate_moodboard`, `deduplicate_library`, `extract_design_tokens`, `inspect_ai_prompts`
- **Non-Negotiable Invariant**: Permanent deletion of assets and deletion of folders are **STRICTLY FORBIDDEN** through any MCP surface (`trashed: true` and `deduplicate_assets(action:"merge")` are soft Trash only).

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
10. **Douyin (抖音) Passive Collection, Zero-Download Streaming Bookmarks & Multi-Content Branching**:
    - `SocialPlatform` includes `douyin` (`"douyin"`, display `"抖音"`, `#161823` badge, noun `"作品"`, hiding internal `MS4wLjAB...` `sec_uid` and `>= 12`-digit numeric UIDs in subtitle typography). Parsers MUST support `/video/<id>`, `/note/<id>`, `/slides/<id>`, `/share/(video|note|slides)/<id>`, protocol-relative `//www.douyin.com/note/<id>`, `?modal_id=<id>`, `iesdouyin.com`, and `v.douyin.com` short links (including Chinese mobile share copy), computing canonical deduplication key `douyin:<aweme_id>` across `existing-sources`, `socialBookmark`, `socialMedia`, and single URL ingest.
    - **Strictly passive main-world interception**: `Resources/BrowserExtension/page-bridge.js` (classic script, zero `import`/`export`) passively clones `fetch`/`XHR` responses (`''`/`text`/`json`/`arraybuffer`/`blob`) on `/aweme/v[12]/web/` (`listcollection`, `collects/list`, `collects/video/list`, `favorite`, `post`, `detail`), posting `__charkleSocialBridge: true` (`GRAPHQL_POSTS` & `DOUYIN_COLLECTIONS`) to `content.js` — **NEVER** synthesize `a_bogus` / `X-Bogus` / `msToken` signatures or bypass login/verification challenges. Live DOM guards MUST separate primary vs secondary `semi-tabs` (`?showSubTab=...`), target inner `.route-scroll-container`, and check computed visibility + dimensions in `hasDouyinAuthOrVerifyBlocker()` so hidden `0×0` `iframe#nocaptcha-container` never false-pauses collection.
    - **Decoupled zero-download video gating & per-item Quick Look**: Keep `is_video_platform()` (`isVideoSocialPlatform`) strictly scoped to 16:9 horizontal platforms (`youtube | bilibili`), and gate eager MP4 download skipping on an independent predicate (`prefers_zero_download_video_bookmark()` covering `youtube | bilibili | douyin`). Render Douyin bookmarks as `900×1440` vertical feed cards (`3:4` cover + play circle & `MM:SS` duration pill for videos, or `N 图` pill for multi-image photo-notes + `240px` white footer), and branch Quick Look per item: `douyin && hasVideo` reuses `<QuickLookStreamingVideoView />` (Range proxy + `yt-dlp -g` fallback on missing/`x-expires`-expired streams + frame-to-cover + on-demand MP4 save), while `douyin && !hasVideo` renders the 3:4 multi-image grid.
    - **Douyin CDN Referer, `octet-stream` `ftyp` sniffing & SSRF**: Allow Douyin image/video CDNs (`*.douyinpic.com`, `*.byteimg.com`, `*.ibytedtos.com`, `*.douyinvod.com`, `*.zjcdn.com`, `*.snssdk.com`, `*.bytevcloudapi.com`, `*.amemv.com`, `*.pstatp.com`, `*.douyincdn.com`, `*.bytegoofy.com`) under public HTTPS SSRF guards with `Referer: https://www.douyin.com/`, deprioritize `.heic`/`.heif` in parser `url_list` selection, sniff ISO BMFF `ftyp` brands (`avif`/`heic`/`mp4`) on `application/octet-stream` media downloads, and normalize `application/octet-stream` VOD proxy responses to `video/mp4`.
    - **Content filter, default auto-classification, multi-select Picker & anti-confusion hint**:
      - `lib/storage.js` persists `douyinContentFilter: 'all' | 'video' | 'image'` (`全部` / `仅视频` / `仅图文`) and `douyinAutoClassify: true` (default ON). In `content.js::harvestNow()`, items excluded by `douyinContentFilter` MUST record `seenThisRun` / scroll progress without incrementing `knownStreak`, `skipped`, or `discovered` (preventing consecutive already-imported videos from prematurely halting `'image'`-only syncs).
      - Both desktop Rust (`windows/crates/charkle-core/src/media/douyin.rs::douyin_classification_tag`, `pipeline.rs`, `bridge.rs`) and the extension (`content.js` / `background.js`) automatically append deduplicated **`抖音视频`** (`hasVideo === true`) or **`抖音图文`** (`hasVideo === false`) tags across batch, picker, author-media, single-page, and desktop-paste ingest. When `douyinAutoClassify === true`, `background.js` lazily creates/reuses (`POST /api/v1/folders` with `reuseExisting: true`, cached per parent) `视频` / `图文` subfolders ONLY when items of that type are actually ingested — never creating empty folders and preventing `视频/视频` re-nesting (batch/picker Inbox targets lazily create `<suggestedFolderName>` first; single-page Inbox captures stay in Inbox with tags only).
      - The `批量` tab provides built-in multi-select **「挑选导入」** (`SCAN_DOUYIN_PICKER_ITEMS` supporting `{ scrollMore: true }` on `.route-scroll-container`, `FETCH_EXISTING_SOURCES` `alreadyImported` status, `全选未导入` / `清空` / `加载更多` / `导入所选`), and the `抓图` tab displays a neutral top hint (`#images-social-hint` + `去挑选导入`) on Douyin/Xiaohongshu collection pages so users do not mistakenly clip bare cover images.
    - **Cross-platform extension mirror invariant**: Keep `Resources/BrowserExtension/lib/url-detect.js` self-contained (for Safari's classic Service Worker bundler), mirror every non-test runtime file in `Resources/BrowserExtension/` byte-identically to `windows/src-tauri/resources/BrowserExtension/`, and register all files 1:1 in `windows/src-tauri/tauri.conf.json` (`bundle.resources`).
11. **5th Gallery View Mode (`compactList`), Media-Agnostic Version Stack & Scheme B Document Diff / 2-Way Synthesis**:
    - **Tactile Studio Compact View (`GalleryLayoutMode.compactList`, desktop shortcut `5` / `Ctrl+5`)**:
      - Universal across all 8 `MediaKind`s with local **per-destination layout mode memory** (per folder / Inbox, falling back to global default layout).
      - Desktop views offer a toggleable **2-Column Tactile Index Grid (`双列索引卡`, responsive to 1-col on narrow widths) ⇄ 1-Column Folio Strip (`单列折页条`)** (iPad regular width uses 2-col Bento; iPhone compact width uses 1-col Folio).
      - Left artifact renders a **3D Micro-Folio Stack** for `versionCount > 1` that subtly fans open on fine-pointer hover (`@media (hover: hover) and (pointer: fine)`, pure transform, disabled under Reduced Motion), miniature red-header/sheet/page skeletons for single documents, crisp thumbnail + bottom palette bar for images/designs, and miniature waveform for audio.
      - Right edge displays a **12-Segment Diff Minimap** (`minimapBuckets` of `0` neutral, `1` green add/mod/move, `2` crimson high-risk number/date) + `tabular-nums` timestamp.
      - Clicking/tapping a stack pill (`主版 v4 · +1 新版` or `主版 v4 · 共N版`) unfolds an **Inline Expandable Revision Rail** (`v3` ── `Δ 6处 · ¥1` ── `v4 主版` ── `Δ 3处 · ¥2` ── `v5`), supporting 1-click **`设为主版`** (`isPinnedPrimary`) and 1-click **`Δ`** bridge pills to open Quick Look directly in Diff mode.
      - Preserves 100% gallery parity: single/`Shift`/`⌘`/`Ctrl` multi-selection, `↑/↓` `0ms` keyboard navigation, unmodified `Space` Quick Look toggle, drag-out of the **Primary Version** original file, and drag-drop onto a card to merge into a Version Stack.
    - **Media-Agnostic Version Stack & Anti-Mis-Send Primary Lock (`isPinnedPrimary`)**:
      - Gallery views collapse assets sharing `versionStack.groupID` into a single visible representative resolved via `AssetVersionStackMetadata.resolvePrimaryAsset` (`isPinnedPrimary == true` preferred; otherwise highest `versionNumber`).
      - Appending a newer `vN+1` onto a stack with a pinned primary `vK` MUST NEVER silently override `vK`; outbound drag (`NSPasteboard` / Win32 OLE `DoDragDrop`), clipboard file copy (`⌘C` / `Ctrl+C` `CF_HDROP`), Notch/Top-Edge Shelf drag-out, and iOS Share sheets MUST ALWAYS export the Primary Version's original file.
      - Dropping/importing files into Top Shelf or Folder runs `< 150ms` offline candidate detection (Chinese office filename stem normalizer + 64-bit paragraph SimHash similarity `>= 0.45`) and presents a non-blocking banner pre-filling `editorName` + 1-line `changeNote` while keeping flat independent files on disk (zero wrapper folders).
    - **Universal Quick Jump File Copy (`⌘J / Ctrl+J` -> `⌘C / Ctrl+C`) & Local FTS5 Document Cache**:
      - Pressing `⌘C` / `Ctrl+C` on an asset row in Jump Anywhere copies the Primary Version's original file entity directly to the OS clipboard (`NSPasteboard` file URL / Win32 `CF_HDROP`) for instant paste into WeChat.
      - Native offline parsers extract `.docx / .xlsx / .pptx / .pdf / .md / .txt(UTF-8/UTF-16/GB18030)` (plus OS-native plain-text fallback for legacy `.doc/.wps/.xls/.et` via `NSAttributedString`/`textutil` on macOS and Win32 `IFilter` on Windows), caching structured blocks and full text in local `document_content_cache` to feed `assets_fts` + Pinyin without polluting `/.charkle/ops/*.jsonl`.
    - **Quick Look Document Readers, High-Risk Radar, Visual PDF Diff & Scheme B 2-Way Synthesis**:
      - Quick Look (`300pt/300px` synchronized Inspector 1:1 preserved) renders clean `.docx`, `.xlsx` (sheet tabs), `.pdf`, and `.md/.txt` readers, plus Version Stack diff mode with **High-Risk Radar filters** (`全部改动`, `数字与金额`, `日期与时限`, `表格变动`, `原生修订/批注`), **`仅看改动段落`** collapse, `J/K` jump, Word Inline/Side-by-Side/Move/Table/Comment diff, Excel Primary-Key row-aligned cell & formula diff, and scanned PDF offline OCR (Apple Vision / WinRT `OcrEngine`) + **Red-Cyan blend & interactive Split Curtain Wipe** visual diff.
      - **Scheme B 2-Way Synthesis (`按差异合成新版本`)** produces a new `vN+1` stack sibling (never overwriting originals) via lossless `.md/.txt` merge and **ZIP-preserving `.docx` plain-paragraph `<w:p>` surgical replacement** (preserving `styles.xml`, red headers, headers/footers, numbering, and media byte-for-byte, with XML integrity validation), while marking complex merged tables (`vMerge`/`gridSpan`), `fldComplex`, SmartArt, OLE, `.xlsx`, and `.pdf` as **`受保护结构（只读对比）`** with a 1-click open-in-default-app action.

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
5. **TypeSafe System One (`Jev`) Zero-Hallucination Closed-Set Auto-Tagging & Grounding Contract**:
   - `TypeSafeExperimentalConfig` adds backward-compatible fields `enableClosedSetTagging` (default `true`), `autoApplyHighConfidenceTags` (default `false`), `highConfidenceTagThreshold` (default `0.82`, clamped `0.60...0.98`), and `suggestedTagThreshold` (default `0.52`, clamped `0.30...highConfidenceTagThreshold`). Every Phase 1 & Phase 2 scenario flag (`enableMoodboardFocusCrop`, `enableAutoCleanCrop`, `enableSubjectPalette`, `enablePinpointAnnotations`, `enableSemanticSearch`, `enableInboxSmartTriage`, `enableCuratorVisualRerank`, `enableClosedSetTagging`) MUST actually gate runtime Jev invocations and fall back to offline heuristics/saliency when disabled.
   - **Single-Request Multi-`Noul` Wire Contract**: Closed-set tagging evaluates at most `20` canonical candidate tags per asset in ONE `POST /v1/systemone` multipart request using a single `320px`-long-side JPEG (`>= 280px` TypeSafe minimum) and lean `.noul` instructions (omitting verbose per-question `true/false` criteria boilerplate to keep token footprint ~1.2–1.8k tokens/asset). Output keys are strictly intersected with the submitted candidate map (physically zero hallucination), partitioned into `confirmedTags` (`>= highConfidenceTagThreshold`) and `suggestedTags` (`>= suggestedTagThreshold`).
   - **Two-Stage Local Funnel & Anti-Singleton Hygiene**: When a library has `>= 12` repeated tags (`count >= 2`), one-off singleton tags (`count == 1`) MUST be excluded from the closed-set pool unless explicitly referenced in `LibraryTaxonomyPolicy.tagAliases`. For libraries with `> 20` eligible canonical tags, build the per-asset 20-tag checklist locally using cached visual-neighbor similarity (up to 50%), current & parent folder tag priors (up to 35%), and global frequency backbone, attaching short co-occurring folder/tag/alias hints; cache the vocabulary index (~45s TTL) and invalidate on manual tag mutations.
   - **Zero-Redundancy VLM Skipping & HLC Sync**: When Jev closed-set tagging is active and an asset already has a non-empty `aiDescription`, batch/single retagging MUST skip the slow generative VLM completely (zero redundant LLM tokens; raise Jev-only batch concurrency up to `6` while displaying the active engine label in progress UI). Formal tags promoted via `autoApplyHighConfidenceTags` MUST persist via normal HLC sync ops so they replicate cleanly across devices; fall back to VLM open-set tags only on cold start (`< 3` eligible candidates and 0 Jev hits).
