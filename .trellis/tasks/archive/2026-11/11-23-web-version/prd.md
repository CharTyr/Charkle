# PRD: Charkle Web Full-Parity Sync Development

## 1. Goal & User Value

Synchronously develop a complete, production-grade **Web version of Charkle** inside `./web/` that achieves full functional, visual, and data-protocol parity with the current macOS Swift codebase (~43k LOC across `CharkleCore`, `CharkleCanvas`, `CharkleApp`, and `CharkleCLI`).

Users can collect, search, organize, curate dual-mode moodboards, export lossless `.charkleboard` bundles to Figma/FigJam, invoke Hybrid AI / TypeSafe Jev / external MCP agents, and sync their entire visual library seamlessly across macOS and Web through the same human-readable `/.charkle/` storage format (Google Drive, WebDAV, or Local Folder).

---

## 2. Confirmed Facts & Codebase Anchors

- **Repository & Target Directory**: Single repository at repository root (`.`); Web edition lives in `./web/` (`packages/shared`, `packages/server`, `packages/client`) and reuses repo assets in [Sources/CharkleApp/Resources/Icons](Sources/CharkleApp/Resources/Icons) and [Resources/FigmaPlugin](Resources/FigmaPlugin).
- **Local Toolchain**: Node.js `v26.11.0` with built-in `node:sqlite` (`DatabaseSync` verified with FTS5 `unicode61 remove_diacritics 2` and `prefix='2 3 4'`), `npm 11.20.0`.
- **Core Domain Contracts**:
  - 8 `MediaKind` types, `SocialPostMetadata` (X / Threads / Bluesky), `GitHubRepoMetadata`, `LabColor` (CIELAB + ΔE), `AssetRecord`, `FolderRecord`, `SmartFolderRecord` / `SmartFolderRule`, `GalleryLayoutMode` (3 modes), `FilterCriteria`, `AssetBatchPatch`, `QuickJumpMatch` — [CoreModels.swift](Sources/CharkleCore/Contracts/CoreModels.swift#L3-L939).
  - `CaptureInput`, `ThumbnailTier` (`grid520`, `preview1400`), `CacheStats`, `AIProviderConfig` (`disabled`, `chatGPTSubscription`, `gemini`, `openAICompatible` with 3 custom endpoint formats), `TypeSafeExperimentalConfig` & Phase 1/2 grounding models — [MediaModels.swift](Sources/CharkleCore/Contracts/MediaModels.swift#L3-L504).
  - Dual-mode `MoodboardDocument` (`autoEditorial` 3 styles ↔ `freeform`), 4 `BoardNodeKind` variants (`assetRef`, `note`, `groupFrame`, `paletteStrip`), `BoardConnector` (pinpoint normalized anchors), `InkStroke`, `MoodboardCurationRequest`, `MoodboardAgentPhase` (8 phases), `MoodboardProposal` — [MoodboardModels.swift](Sources/CharkleCore/Contracts/MoodboardModels.swift#L3-L637).
  - Multi-backend `DriveSyncConfig` (`directAPIWithGDirect`, `webDAV`, `gdirectMount`, `localOnly`), shared Google Drive folder URL/ID parsing, `StorageMigrationReport`, `SyncStatus`, `SyncReport` — [SyncModels.swift](Sources/CharkleCore/Contracts/SyncModels.swift#L3-L538).
  - Unified engine facade `CharkleEngineProtocol` — [CoreServiceProtocols.swift](Sources/CharkleCore/Contracts/CoreServiceProtocols.swift#L9-L118).
- **Persistence & Sync Wire Format**:
  - SQLite WAL + FTS5 + pinyin/initials + `asset_tags` + `asset_colors` + `asset_vectors` + `folders` + `boards` + `board_assets` + `sync_ops` + `sync_state` + `original_cache` — [LibraryDatabase.swift](Sources/CharkleCore/Database/LibraryDatabase.swift#L36-L136) and [SearchText.swift](Sources/CharkleCore/Database/SearchText.swift#L4-L120).
  - `DriveSyncEngine` and `SyncOperations` encode `manifest.json`, `ops/ops-<device>-<seq>.jsonl`, and `boards/<uuid>.json` using Swift's default `JSONEncoder()` (Cocoa reference date float timestamps since 2001-01-01T00:00:00Z, uppercase hyphenated UUIDs, Base64 `Data`, Swift keyed-enum payloads) — [DriveSyncEngine.swift](Sources/CharkleCore/Sync/DriveSyncEngine.swift#L272-L448), [SyncOperations.swift](Sources/CharkleCore/Sync/SyncOperations.swift#L3-L140).
- **Canvas, Figma Bridge & External Agent**:
  - Deterministic O(N) `EditorialLayoutSolver` (`balanced`, `magazine` w/ 2-col Hero span, `compact`, plus `reflowNodesInsideGroupFrame`) — [EditorialLayoutSolver.swift](Sources/CharkleCanvas/EditorialLayoutSolver.swift#L31-L180).
  - Offline lossless `.charkleboard` ZIP exporter (`manifest.json`, ≤4096px lossless PNG tiles + SHA-256, `originals/` for native GIFs) compatible with [Resources/FigmaPlugin/code.js](Resources/FigmaPlugin/code.js) — [FigmaBridgeExporter.swift](Sources/CharkleCanvas/FigmaBridgeExporter.swift#L31-L260).
  - 14 MCP/CLI tools (8 read + 6 write) gated by `ExternalAgentConfig` policy (`disabled` / `readOnly` / `readWrite`) — [CharkleExternalAgentService.swift](Sources/CharkleCore/Intelligence/CharkleExternalAgentService.swift#L67-L220).
- **Visual & Motion System**:
  - Gallery-First neutral surfaces (Light `#F6F6F5` / `#FFFFFF` / `#F1F0EC`; Dark `#141517` / `#1E2025` / `#131519`), zero violet/neon AI chrome, continuous concentric continuous concentric corners (`R=20/12`, `12/6`, `14/8`), restrained Liquid Glass strictly on floating controls, role-mapped role-mapped easing curves — [CharkleTheme.swift](Sources/CharkleApp/DesignSystem/CharkleTheme.swift#L7-L242) and [MOTION_AND_ICON_SPEC.md](docs/MOTION_AND_ICON_SPEC.md#L7-L70).

---

## 3. Functional Requirements (Full-Parity Inventory)

### FR-1: Local-First Backend, SQLite FTS5 & All-Media Pipeline (M1)
- **FR-1.1**: Provide a local-first Node.js/TypeScript backend backed by `node:sqlite` (WAL + FTS5 + Chinese pinyin/initials tokenization + CIELAB color distance + vector storage) matching the macOS schema semantics.
- **FR-1.2**: Support ingestion of all 5 `CaptureInput` forms (file upload/local file, raw image/clipboard data, web URL, text snippet, color swatch) across all 8 `MediaKind` categories.
- **FR-1.3**: Provide server-side rich link resolvers (zero CORS restrictions): X / Threads / Bluesky social posts (multi-photo/video/GIF attachments, quoted posts, engagement stats, refresh), GitHub repositories (owner avatar, stars/forks/language/topics/README markdown, refresh), and generic web bookmarks (OpenGraph metadata & preview).
- **FR-1.4**: Generate and cache `grid520` and `preview1400` thumbnails, extract CIELAB dominant color swatches, compute audio peak waveforms, manage configurable LRU original file cache with per-asset and per-board `pinnedOffline` protection, and seed a curated sample library on first launch if empty.
- **FR-1.5**: Implement `DriveSyncEngine` with `SwiftWireCodec` so Google Drive API v3 (OAuth + shared folder URL/ID), WebDAV, and Local Folder modes read/write macOS-compatible `/.charkle/` directories (`manifest.json`, `ops/*.jsonl`, `boards/*.json`, `thumbnails/`, `embeddings/`), reconcile renames by `driveFileID`/`contentHash`, support lossless two-way storage migration, and stream live `SyncStatus` updates via SSE.

### FR-2: Gallery-First Web UI, Navigation, Smart Folders, Inbox & Quick Look (M2)
- **FR-2.1**: Implement the exact Gallery-First design system in Light & Dark modes with restrained Liquid Glass floating controls, continuous concentric corners, and all original Duotone & Layered SVG icons from `Sources/CharkleApp/Resources/Icons/`.
- **FR-2.2**: Implement Sidebar navigation covering All Items, Inbox (live count badge), Moodboards Home + individual boards, Untagged, Recent, Trash, nested Folders (create/rename/delete/drag-reorder/re-parent + custom color & icon popover), Smart Folders (create/edit/delete via `SmartFolderRule` editor), and Tags with counts.
- **FR-2.3**: Implement Top Floating Liquid Glass Search & Visual Filter Capsule supporting live FTS5/pinyin search, Hybrid Semantic Search toggle, multi-select `MediaKind`, CIELAB color swatch picker + ΔE tolerance slider, `AspectShape`, minimum star rating, tag chips, offline-pinned filter, and all 6 `SortOrder` modes.
- **FR-2.4**: Implement all 3 `GalleryLayoutMode` views: Virtualized Vertical Masonry, Horizontal Justified Masonry, and Gallery Filmstrip — with clean borderless cards, hover/selection indicators, marquee box-select, multi-select floating batch action pill, and context menus.
- **FR-2.5**: Implement Inbox Triage Station (`1–9` quick move to top folders, single/batch AI folder suggestion & one-click accept, send to active moodboard, Inbox Zero empty state) and `⌘J` Jump Anywhere modal across folders, boards, tags, and assets.
- **FR-2.6**: Implement Right Inspector (title, notes, 0–5 rating, tags, AI suggested tag accept/dismiss, folder reassignment, offline pin, CIELAB palette with click-to-copy HEX & reverse color search, similar assets, subject palette extraction, auto clean-crop, rich asset refresh).
- **FR-2.7**: Implement `Space` Full-Media Quick Look overlay with low-saturation ambient tint, bottom filmstrip navigation, keyboard navigation (`←/→/Esc`), and dedicated rich viewers: zoomable Image/GIF, HTML5 Video, Audio waveform player, PDF/Markdown/Code/Text reader, GitHub Repo + README card, Social Post multi-attachment viewer, and interactive 3D Model viewer (GLB/GLTF/OBJ/STL).

### FR-3: Dual-Mode Moodboard Studio, Agent Curator & Figma Bridge (M3)
- **FR-3.1**: Implement Moodboards Home overview (cards with preview collage, palette chips, item count, mode badge, active-board toggle, offline pin) and full Moodboard Workspace.
- **FR-3.2**: Implement 4+1 Entry Moodboard Generator modal (Inspiration Prompt, Seed Assets, Color Palette + tolerance, Manual Selection, Combined + folder/tag scope + detail focus crop option) powered by the server-side **Moodboard Agent Harness** with live SSE phase trace (`planning` → `retrieving` → `inspectingVisuals` → `composing` → `verifying` → `repairing` → `completed` / `fallbackOffline`), MMR diversity curation, and refinement instructions.
- **FR-3.3**: Implement Right Candidate Replacement Pool (20–40 ranked replacements; 1-click in-place swap preserving layout position or drag-add onto canvas).
- **FR-3.4**: Implement **Auto Editorial Mode** matching `EditorialLayoutSolver` (`balanced`, `magazine` with 2-col Hero span, `compact`, column/spacing controls, Hero weight toggle, drag-to-reorder with drag-reorder ripple) and zero-jump transition into **Freeform Infinite Canvas** (wheel/pinch zoom, pan, smart alignment guides, box-select, rotate, flipH/flipV, lock, z-index ordering, non-destructive crop editor, multi-step Undo/Redo).
- **FR-3.5**: Support all 5 canvas element types: `assetRef` (hover/loop GIF & video, crop, refresh), `note` (5 styles: `paper`/`ink`/`warm`/`sage`/`slate`, editable title/body/fontSize), `groupFrame` (6 tints, dragging header moves enclosed children, real-time Smart Auto-Layout reflow inside resized frame), `paletteStrip` (auto-sync with board colors, click copy HEX, search library by color), `BoardConnector` (curved/elbow/straight arrows, dashed/solid, labels, pinpoint normalized internal anchor callouts), and `InkStroke` (freehand vector annotation pen with color/width/opacity).
- **FR-3.6**: Support dragging external files directly onto the moodboard canvas (auto-ingests into Inbox + creates canvas node at drop coordinates), exporting high-DPI PNG/JPG (toggle annotations & palette strip), and exporting offline lossless **`.charkleboard` ZIP bundles** directly importable by `Resources/FigmaPlugin` in Figma / FigJam.

### FR-4: Hybrid AI, TypeSafe Jev, Settings Center, Quick Drop Shelf & MCP (M4)
- **FR-4.1**: Implement Hybrid AI engine supporting Local-only mode + Cloud providers (`chatGPTSubscription`, `gemini`, `openAICompatible` across OpenAI Chat Completions, Anthropic Messages, and OpenAI Responses formats), API key secure server-side storage, auto-analyze on import, thumbnail-sending privacy toggle, and `CloudAIUsageTracker` telemetry.
- **FR-4.2**: Implement Experimental **TypeSafe System One (Jev)** visual grounding sidecar (connection test & model listing, semantic focus crop, visual-match crop, auto clean-content crop, subject-aware palette, pinpoint callout annotations, hybrid semantic search, batch inbox smart triage, curator visual rerank) with graceful local fallback when disabled or unreachable.
- **FR-4.3**: Implement complete **6-Tab Settings Center** matching macOS `SettingsView`: `存储与同步` (Google Drive OAuth + shared folder picker + WebDAV + Local Folder + gdirect compatibility diagnostics + lossless Migration Wizard), `智能与搜索` (Cloud AI + usage stats + TypeSafe Jev toggles/thresholds), `外观与图标` (Light/Dark/System theme & icon variants), `外部 Agent 与 MCP` (enable/policy selector + MCP endpoint/config snippet copy), `缓存空间` (live `CacheStats`, budget slider 2–100 GB, manual LRU evict), `采集与快捷键` (Quick Drop Shelf settings & shortcut cheat sheet).
- **FR-4.4**: Implement Web **Quick Drop Shelf（顶部灵动灵感投放胶囊）** — top-center expandable dark-glass capsule mapped from macOS Notch Shelf, supporting global file/URL drag-and-drop anywhere onto the top edge, global `⌘V` clipboard paste (images, URLs, text, hex colors), manual URL/snippet/swatch quick capture, and target routing (`Inbox` / `Folder` / `Active Moodboard`).
- **FR-4.5**: Expose all 14 External Agent / MCP tools (JSON-RPC 2.0 over HTTP/SSE and stdio CLI entrypoint `web/server` MCP bridge) enforcing `ExternalAgentConfig` (`disabled` / `readOnly` / `readWrite`), including server-side contact sheet image rendering and live SSE library refresh pushes to open browser tabs.

### FR-5: Motion Continuity, Accessibility & End-to-End Parity Verification (M5)
- **FR-5.1**: Implement calibrated motion tokens (`--ease-out`, `--ease-out-strong`, `--ease-in`, `--ease-in-out`, `--ease-overshoot`, spring physics) across transitions: Card ↔ Quick Look continuity, Sidebar travelling active pill, Auto Editorial ↔ Freeform smooth coordinate interpolation, Popover trigger-origin scaling, drag-to-reorder ripple, and Quick Drop Shelf spring morphing.
- **FR-5.2**: Honor `prefers-reduced-motion` (collapse spatial transitions to 150ms cross-fade) and `prefers-reduced-transparency` (replace glass backdrops with high-contrast solid surfaces).
- **FR-5.3**: Verify macOS ↔ Web `/.charkle/` sync round-trip compatibility, `.charkleboard` Figma Plugin compatibility, TypeScript type-checking, unit/integration test suites, and live browser E2E testing across Light and Dark modes.

---

## 4. Child Task Map & Execution Order

| Order | Child Task | Deliverable | Depends On |
| :--- | :--- | :--- | :--- |
| 1 | `11-23-web-m1-core-db-media-sync` | `./web/` workspace, `shared` models + `SwiftWireCodec`, SQLite FTS5/pinyin DB, 8-kind `MediaPipeline` + rich resolvers, multi-backend `DriveSyncEngine` + migration, REST/SSE server, backend tests | None |
| 2 | `11-23-web-m2-gallery-nav-quicklook` | Gallery-First design system & icons, Sidebar + Folders + Smart Folders, Top Filter Capsule, 3 Gallery Views, Multi-Select, Inbox Triage, `⌘J` Jump Anywhere, Inspector, Full-Media Quick Look | M1 |
| 3 | `11-23-web-m3-moodboard-studio-figma` | Moodboards Home, 4+1 Generator + Agent Harness Trace, Candidate Pool, Auto Editorial ↔ Freeform Canvas, 5 Node/Annotation types, Undo/Redo, PNG Export, `.charkleboard` Figma Bridge | M1, M2 |
| 4 | `11-23-web-m4-ai-typesafe-settings-shelf-mcp` | Multi-provider Cloud AI + Usage Tracker, TypeSafe Jev sidecar, 6-Tab Settings + Migration Wizard, Top Quick Drop Shelf, 14-tool MCP/Agent server + live SSE refresh | M1, M2, M3 |
| 5 | `11-23-web-m5-motion-polish-e2e-verification` | calibrated motion continuity & a11y fallbacks, macOS↔Web sync parity tests, Figma Bridge bundle check, Playwright/Browser E2E in Light & Dark modes, `.trellis/spec/` updates | M1–M4 |

---

## 5. Native-Only Mapping & Out of Scope

- **macOS Hardware / OS-Exclusive Primitives Mapped Cleanly for Web**:
  - Physical MacBook Notch `NSPanel` + Mission Control bypass → Web **Quick Drop Shelf** (top-center spring-morphing dark-glass capsule + global drag/paste capture).
  - System-wide macOS global hotkeys & screen region capture (`CGWindowList` / `screencapture`) → In-app shortcuts + browser Screen Capture API (`getDisplayMedia`) snapshot button + clipboard `⌘V` paste.
  - `gdirect` FUSE/NFS local mount & macOS Keychain → Web uses direct Google Drive API v3 / WebDAV / Local Folder with server-side encrypted local secret vault (`.secrets.json` with 0600 permissions); Settings displays `gdirect` interoperability guidance for hybrid macOS+Web users.
  - Apple Vision `VNFeaturePrint` / native OCR → Web server computes perceptual visual fingerprints (multi-scale color/edge/DCT embeddings) + optional Cloud AI / TypeSafe Jev vision & OCR, maintaining full API & fallback compatibility.
- **Explicitly Out of Scope**:
  - Multi-tenant public cloud SaaS auth/billing (Charkle Web is Local-First / self-hosted private-library architecture matching macOS Charkle).
  - Modifying or breaking existing Swift targets (`Sources/`, `Tests/`, `Package.swift`).

---

## 6. Cross-Child Acceptance Criteria

1. Running `npm run dev` (or `npm run build && npm start`) inside `./web/` launches both the Node.js API/SSE/MCP server and React Web client cleanly on localhost with zero TypeScript or bundler errors.
2. First launch seeds the curated sample library; users can browse in all 3 gallery modes, filter by Chinese pinyin / CIELAB color / media kind / aspect / rating / tags / smart folder, triage Inbox with `1–9`, quick-jump with `⌘J`, and preview all 8 media types (including GitHub README, X/Threads/Bluesky posts, audio waveform, Markdown, PDF, and 3D models) in Quick Look.
3. Users can generate a moodboard via any of the 4+1 entry points (observing live Agent Harness steps and candidate pool), toggle smoothly between Auto Editorial (`balanced`/`magazine`/`compact`) and Freeform infinite canvas, edit all 5 node/annotation types with Undo/Redo, export high-DPI PNG, and export a `.charkleboard` ZIP whose `manifest.json` + tiles + SHA-256 checksums validate against `Resources/FigmaPlugin/code.js`.
4. Users can configure Google Drive / WebDAV / Local Folder sync, run lossless storage migration, and exchange a `/.charkle/` directory with macOS Charkle (verified by automated Swift-wire-format round-trip tests covering assets, folders, tags, and moodboards).
5. Users can configure Cloud AI providers, TypeSafe Jev sidecar, cache budget, appearance, and External Agent MCP policy in the 6-tab Settings Center; calling MCP tools via HTTP/stdio respects policy and live-refreshes open Web UI tabs via SSE.
6. All unit/integration tests pass (`npm test` in `./web/`), visual & interactive flows are verified in a real browser across both Light (`#F6F6F5`) and Dark (`#141517`) modes with zero console/runtime errors, and existing `swift test` remains untouched/green.
