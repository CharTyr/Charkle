# Technical Design: Charkle Web Full-Parity Architecture

## 1. Architectural Overview & Package Boundaries

`./web/` is organized as an npm workspaces monorepo with 3 cleanly separated TypeScript packages mirroring macOS Charkle's deep-module split (`CharkleCore`, `CharkleCanvas`, `CharkleApp`):

```text
web/
├── package.json                 # npm workspaces root: dev, build, test, typecheck, start
├── tsconfig.base.json           # strict TS 5.x, NodeNext / ESNext
├── packages/
│   ├── shared/                  # Pure isomorphic contracts, SwiftWireCodec, EditorialLayoutSolver,
│   │                            # CIELAB/ΔE math, SmartFolderRule evaluator, Pinyin normalizer
│   ├── server/                  # Local-First Node 26 backend (Hono/Fastify or native HTTP + Hono)
│   │   ├── src/
│   │   │   ├── db/              # LibraryDatabase (node:sqlite WAL + FTS5 + pinyin + vectors)
│   │   │   ├── media/           # MediaPipeline (sharp/canvas thumbnails, waveforms, LRU cache,
│   │   │   │                    # X/Threads/Bluesky/GitHub/WebBookmark resolvers, sample seeder)
│   │   │   ├── sync/            # DriveSyncEngine, DirectAPITransport, WebDAVTransport,
│   │   │   │                    # LocalFolderTransport, InMemoryTransport, StorageMigration
│   │   │   ├── intelligence/    # IntelligenceEngine, ColorExtractor, PerceptualFingerprint,
│   │   │   │                    # CloudAIProvider (Gemini/OpenAI/Anthropic/ChatGPT),
│   │   │   │                    # CloudAIUsageTracker, TypeSafeClient, VisualGroundingEngine,
│   │   │   │                    # MoodboardCurator, MoodboardAgentHarness, ContactSheetRenderer
│   │   │   ├── export/          # MoodboardImageExporter, FigmaBridgeExporter (.charkleboard ZIP)
│   │   │   ├── agent/           # ExternalAgentService (14 MCP tools, JSON-RPC 2.0 HTTP + stdio)
│   │   │   ├── api/             # REST routes + SSE event bus (sync progress, harness steps, live refresh)
│   │   │   └── storage/         # LocalConfigStore & EncryptedSecretVault (0600)
│   └── client/                  # React 19 + Vite 6 + TypeScript + Tailwind CSS v4 + Zustand
│       ├── public/icons/        # Synced/served original SVG icons from Sources/CharkleApp/Resources/Icons
│       └── src/
│           ├── design-system/   # Tokens (CharkleTheme + CharkleMotion + Liquid Glass CSS + Icon)
│           ├── stores/          # Domain stores matching macOS: coordinator, library, moodboard, syncAI
│           ├── api/             # Typed fetch + SSE client
│           ├── components/      # Shared HUD pills, popovers, flow layouts, drop rings, badges
│           └── features/
│               ├── sidebar/     # Sidebar, nested FolderTree, FolderCustomizationPopover, SmartFolderEditor
│               ├── gallery/     # TopFilterCapsule, VerticalMasonry, HorizontalJustified, GalleryFilmstrip,
│               │                # MarqueeSelect, BatchActionPill, InboxTriageBar
│               ├── quicklook/   # QuickLookOverlay, Image/Video/Audio/PDF/Markdown/GitHub/Social/3D viewers
│               ├── inspector/   # Right Inspector (single & multi-select, palette, similar, TypeSafe tools)
│               ├── moodboard/   # MoodboardsHome, GeneratorSheet + HarnessTrace, CandidatePool,
│               │                # DualModeCanvas (Auto Editorial + Freeform), NodeViews, Connectors, Ink, Export
│               ├── jump/        # Cmd+J JumpAnywhere modal
│               ├── shelf/       # Top QuickDropShelf (Notch Shelf Web counterpart)
│               └── settings/    # 6-tab Settings modal + StorageMigrationWizard
```

### Core Dependency Choices (Minimal, High-Reliability, Zero Native Build Fragility)
- **Database**: Node 26 built-in `node:sqlite` (`DatabaseSync`) — zero C++ rebuild issues, native WAL + FTS5 (`unicode61 remove_diacritics 2`, `prefix='2 3 4'`).
- **HTTP Server**: `hono` + `@hono/node-server` — ultra-clean typed routing, streaming SSE, multipart file uploads, and static asset serving.
- **Image Processing & Contact Sheets / Export**: `sharp` (fast libvips for thumbnails, CIELAB/pixel sampling, crop, tile splitting ≤4096px, PNG/JPG export, SVG rasterization) with graceful fallback for SVG/non-raster formats; `jszip` (already used by `Resources/FigmaPlugin`!) for lossless `.charkleboard` ZIP bundling.
- **Pinyin**: `pinyin-pro` — accurate Mandarin full pinyin + initials + polyphone support matching `SearchText.swift`.
- **Frontend**: React 19, Vite 6, TypeScript 5.8+, Tailwind CSS v4 (strictly mapped to Charkle neutral palette & concentric radius tokens), `zustand` for domain stores, `framer-motion` (or CSS WAAPI + motion tokens strictly using role-mapped curves and `useReducedMotion`), `lucide-react` as fallback behind Charkle's original Duotone/Layered SVGs, `three` (lightweight WebGL viewer for GLB/GLTF/OBJ/STL 3D models in Quick Look), `marked` + `dompurify` for safe GitHub README & Markdown rendering.
- **Testing**: `vitest` across `shared`, `server`, and `client` + live browser verification via Antigravity browser / Playwright.

---

## 2. Data Model & macOS `/.charkle/` Wire-Format Compatibility

### 2.1 SQLite Schema (`LibraryDatabase`)
Mirrors `Sources/CharkleCore/Database/LibraryDatabase.swift` 1:1 (schema `user_version = 2`):
- `assets (id, drive_id, content_hash, folder_id, kind, shape, title, rating, size, created, pinned, trashed, payload)` + indexes `assets_folder`, `assets_recency`, `assets_hash`
- `assets_fts USING fts5(title, fileName, notes, tags, ocrText, aiDescription, sourceDomain, pinyin, initials, tokenize='unicode61 remove_diacritics 2', prefix='2 3 4')`
- `asset_tags (asset_id, tag COLLATE NOCASE)`
- `asset_colors (asset_id, l, a, b)`
- `asset_vectors (asset_id, feature_print, embedding, precision, embedding_model)`
- `folders (id, drive_id, payload)`
- `smart_folders (id, payload)` *(persisted cleanly in `sync_state` key `smartFolders` or dedicated table, synced via config)*
- `boards (id, pinned, payload)` & `board_assets (board_id, asset_id)`
- `sync_ops (seq AUTOINCREMENT, payload)` & `sync_state (key, payload)` & `original_cache (asset_id, accessed_at)`

### 2.2 `SwiftWireCodec` (Critical Interop Seam)
To guarantee lossless bidirectional sync with macOS `DriveSyncEngine` (`/.charkle/`):
- **Timestamps**: Convert JS ISO-8601 strings / epoch ms ↔ Swift default Cocoa Reference Date float (`(unixMs / 1000) - 978307200`). Decoder accepts BOTH Cocoa float numbers and ISO-8601 strings defensively.
- **UUIDs**: Normalize canonical UUIDs to uppercase hyphenated format on wire (`UUID.toUpperCase()`) to match Swift `UUID.uuidString`.
- **Swift Keyed Enums**: Exact bidirectional adapter for:
  - `BoardLayoutMode`: `{"autoEditorial":{"_0":{...}}}` ↔ `{ type: 'autoEditorial', config: {...} }`; `{"freeform":{}}` ↔ `{ type: 'freeform' }`
  - `BoardNodeKind`: `{"assetRef":{"assetID":...,"crop":...,"weight":...,"autoplayLoop":...}}`, `{"note":{"title":...,"text":...,"style":...,"fontSize":...}}`, `{"groupFrame":{"title":...,"tint":...}}`, `{"paletteStrip":{"colors":...,"autoSyncWithBoard":...}}`
  - `SyncOperation.Change`: `asset`, `board`, `folder`, `deleteAsset`, `deleteBoard`, `deleteFolder`, `vector`
  - `SyncFields`: Base64-encoded JSON fragment values inside `fields: Record<string, string>` matching Swift `[String: Data]`.
- **HLC & CRDT Merge**: Identical `SyncStamp(time, device)` using `max(nowMs * 1024, prev + 1)`, per-field LWW clocks (`field:<key>`), tombstone tag set merge (`tagsAdded`/`tagsRemoved`), and per-node/connector/stroke collection merge (`node:<id>`, `connector:<id>`, `stroke:<id>`).

---

## 3. API & Real-Time Streaming Contract

All client-server communication flows through `/api/v1/*` + SSE `/api/v1/events` + MCP `/api/v1/mcp`:

| Domain | Endpoints |
| :--- | :--- |
| **Library & Assets** | `GET /api/v1/assets` (full `FilterCriteria`), `GET /api/v1/assets/:id`, `POST /api/v1/assets/ingest` (multipart files / URL / text / swatch / base64), `PATCH /api/v1/assets/batch` (`AssetBatchPatch`), `DELETE /api/v1/assets` (permanent), `POST /api/v1/assets/:id/opened`, `POST /api/v1/assets/:id/refresh-rich`, `GET /api/v1/assets/:id/similar`, `GET /api/v1/assets/:id/suggest-folder` |
| **Media Serving** | `GET /api/v1/media/:id/thumbnail/:tier` (`grid520`/`preview1400`), `GET /api/v1/media/:id/original` (supports HTTP `Range` streaming for video/audio!), `GET /api/v1/cache/stats`, `PUT /api/v1/cache/budget`, `POST /api/v1/cache/evict` |
| **Folders & Smart Folders & Tags** | `GET/POST /api/v1/folders`, `PATCH/DELETE /api/v1/folders/:id`, `POST /api/v1/folders/:id/move`, `PATCH /api/v1/folders/:id/appearance`; `GET/POST/PUT/DELETE /api/v1/smart-folders`; `GET /api/v1/tags`, `GET /api/v1/inbox/count`, `GET /api/v1/quick-jump` |
| **Moodboards & Export** | `GET /api/v1/boards`, `GET/PUT/DELETE /api/v1/boards/:id`, `POST /api/v1/boards/propose`, `POST /api/v1/boards/curate` (SSE streaming `MoodboardAgentStep` + final `MoodboardProposal`), `POST /api/v1/boards/:id/pin`, `POST /api/v1/boards/palette`, `POST /api/v1/boards/replacements`, `POST /api/v1/boards/:id/export/image`, `POST /api/v1/boards/:id/export/figma` (returns `.charkleboard` ZIP download + report headers) |
| **Hybrid AI & TypeSafe Jev** | `GET/PUT /api/v1/ai/config`, `GET /api/v1/ai/usage`, `POST /api/v1/ai/analyze-local`, `POST /api/v1/ai/enrich-cloud`, `GET/POST/DELETE /api/v1/ai/chatgpt/*`; `GET/PUT /api/v1/typesafe/config`, `POST /api/v1/typesafe/test`, `POST /api/v1/typesafe/locate-region`, `POST /api/v1/typesafe/locate-match`, `POST /api/v1/typesafe/clean-bounds`, `POST /api/v1/typesafe/subject-palette`, `POST /api/v1/typesafe/semantic-search`, `POST /api/v1/typesafe/batch-triage` |
| **Sync & Storage** | `GET/PUT /api/v1/sync/config`, `GET /api/v1/sync/status`, `POST /api/v1/sync/now`, `POST /api/v1/sync/google/oauth/*`, `GET /api/v1/sync/google/shared-folders`, `POST /api/v1/sync/webdav/test`, `POST /api/v1/sync/migrate` |
| **External Agent & MCP** | `GET/PUT /api/v1/agent/config`, `POST /api/v1/mcp` (JSON-RPC 2.0) + `GET /api/v1/mcp/sse`, plus CLI stdio runner `node packages/server/dist/mcp-stdio.js` |
| **Live Events (SSE)** | `GET /api/v1/events` pushes `sync.status`, `sync.completed`, `library.changed`, `library.enriched`, `board.updated` so external MCP writes or background enrichment update UI instantaneously |

---

## 4. Visual System & Canvas Architecture

### 4.1 Gallery-First Neutral & Restrained Liquid Glass Tokens
Exact CSS Custom Properties mirroring `CharkleTheme.swift`:
- **Light**: `--gallery-ground: #F6F6F5`, `--surface-elevated: #FFFFFF`, `--surface-subtle: #EDEDE9`, `--inspector-bg: #F1F0EC`, `--inspector-field: #F6F5F1`, `--hairline: rgba(0,0,0,0.08)`, `--ink-secondary: rgba(60,60,67,0.72)`.
- **Dark**: `--gallery-ground: #141517`, `--surface-elevated: #1E2025`, `--surface-subtle: #24272C`, `--inspector-bg: #131519`, `--inspector-field: #16181D`, `--hairline: rgba(255,255,255,0.09)`, `--ink-secondary: rgba(255,255,255,0.64)`.
- **Liquid Glass (Strictly Floating Chrome Only)**:
  - `backdrop-filter: blur(22px) saturate(180%)` + subtle specular top-leading hairline rim + soft ambient drop shadow; automatically switches to solid high-contrast surface under `@media (prefers-reduced-transparency: reduce)`.
  - Applied ONLY to: Top Search/Filter Capsule, Moodboard Floating Bottom Tool Dock, Multi-Select Batch Action Pill, Quick Look HUD Controls, and Top Quick Drop Shelf.
- **Concentric Radii (4pt Grid)**: Dock `20px / pad 8px -> 12px`; Card `12px / pad 6px -> 6px`; Settings `14px / pad 6px -> 8px`; Popover `16px -> 10px`; Chip `8px`.

### 4.2 High-FPS Masonry & Dual-Mode Moodboard Canvas
- **Virtualized Masonry (`VerticalMasonryView` & `HorizontalJustifiedView`)**: Pure deterministic O(N) layout computation with viewport windowing (`scrollTop ± overscan`), ResizeObserver width tracking, marquee box-select, keyboard arrow navigation, and drag-out to folders/boards.
- **Dual-Mode Moodboard (`MoodboardCanvasView`)**:
  - Shares `EditorialLayoutSolver` directly from `@charkle/shared` (exact port of `EditorialLayoutSolver.swift` including `balanced`/`magazine`/`compact` rules and `reflowNodesInsideGroupFrame`).
  - Switching `Auto Editorial` → `Freeform` snapshots resolved `frames` directly onto `node.frame` and animates smoothly with zero coordinate jump.
  - Freeform canvas uses GPU-accelerated `transform: translate3d(...) scale(...)` world stage + SVG overlay layer for `BoardConnector` (cubic Bezier / orthogonal elbow / straight arrows + pinpoint normalized targets + editable mid-path labels) and `InkStroke` (smoothed quadratic SVG paths with pressure-modulated widths).
  - Full snapshot-based Undo/Redo stack (`⌘Z` / `⇧⌘Z`), smart alignment guides (center/edge snapping within 6px), and non-destructive normalized crop mode.

---

## 5. Tradeoffs & Rollback Considerations

- **Shared Package Isomorphism**: Placing `EditorialLayoutSolver`, `SmartFolderRule.matches`, `LabColor`/`deltaE`, and `SwiftWireCodec` in `packages/shared` prevents frontend/backend drift and enables fast unit testing with zero DOM or SQLite setup.
- **Native Code Isolation**: `./web/` is completely self-contained and never modifies `Sources/`, `Tests/`, or `Package.swift`. Rollback of any Web milestone is cleanly isolated inside `./web/` and `.trellis/tasks/`.
- **Graceful Degradation**: All external network services (Google Drive, WebDAV, X/Threads/Bluesky, Cloud AI, TypeSafe Jev) degrade gracefully with clear user-facing Chinese status copy and full offline fallback (Local Folder + local CIELAB/FTS5/MMR curation).
