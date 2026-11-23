# Research: macOS Charkle Parity Audit & Wire-Format Specification

Audited directly from repository root (`.`) (~42,815 LOC across Swift targets).

## 1. Module-to-Module Parity Map

| macOS Module / File | Lines | Web Equivalent | Notes |
| :--- | ---: | :--- | :--- |
| `CharkleCore/Contracts/*.swift` | ~2,670 | `web/packages/shared/src/models/*` | 1:1 TypeScript types & helpers |
| `CharkleCore/Database/LibraryDatabase.swift` + `SearchText.swift` + `AssetVector.swift` | ~750 | `web/packages/server/src/db/*` | Node 26 `node:sqlite` WAL + FTS5 + `pinyin-pro` |
| `CharkleCore/Media/*` (Pipeline, Cache, Artwork, SVG, WebBookmark, XPost, SocialPost, GitHub, SampleSeeder) | ~2,700 | `web/packages/server/src/media/*` | Server-side resolvers (no CORS), `sharp` thumbnails + LRU cache |
| `CharkleCore/Sync/*` (DriveSyncEngine, DirectAPI, WebDAV, MountedVolume, InMemory, SyncOperations, GoogleOAuth) | ~4,600 | `web/packages/server/src/sync/*` + `shared/src/swift-codec.ts` | Exact `/.charkle/` wire compatibility + lossless migration |
| `CharkleCore/Intelligence/*` (ColorExtractor, Vision, CloudAI, ChatGPT, UsageTracker, Curator, AgentHarness, ContactSheet, BoardRenderer, TypeSafe, VisualGrounding, ExternalAgentService, Policy) | ~8,300 | `web/packages/server/src/intelligence/*` + `agent/*` | All 4 Cloud AI modes, TypeSafe Jev sidecar + local fallback, 14 MCP tools |
| `CharkleCanvas/*` (VirtualizedMasonry, EditorialLayoutSolver, MoodboardCanvas, NodeViews, Exporter, FigmaBridgeExporter) | ~9,350 | `web/packages/shared/src/layout/editorial.ts` + `client/src/features/{gallery,moodboard}/*` + `server/src/export/*` | 3 Gallery modes, Auto↔Freeform canvas, PNG + `.charkleboard` ZIP |
| `CharkleApp/DesignSystem/*` + `Resources/Icons/*` | ~700 + 40 SVGs | `web/packages/client/src/design-system/*` + `public/icons/*` | Exact Light/Dark neutral hexes, Liquid Glass, calibrated motion curves, original SVGs |
| `CharkleApp/Stores/*` | ~2,480 | `web/packages/client/src/stores/*` | 4 domain Zustand stores (`coordinator`, `library`, `moodboard`, `syncAI`) |
| `CharkleApp/Views/*` + `Notch/*` + `Services/*` | ~14,500 | `web/packages/client/src/features/*` | Sidebar, SmartFolders, FilterCapsule, Inbox, QuickLook, Inspector, Settings (6 tabs), JumpAnywhere, QuickDropShelf |

## 2. Exact Swift Codable Wire Rules for `/.charkle/` Sync

Verified from `DriveSyncEngine.swift`, `SyncOperations.swift`, and `Contracts/*.swift`:
1. **Dates**: Swift default `JSONEncoder` encodes `Date` as numeric seconds since `2001-01-01T00:00:00Z` (`COCOA_EPOCH_OFFSET_SEC = 978307200`).
   - Encode: `cocoaSec = unixMs / 1000 - 978307200`
   - Decode: if `typeof v === 'number'`, `new Date((v + 978307200) * 1000)`; if `typeof v === 'string'`, `new Date(v)`.
2. **UUIDs**: Uppercase RFC-4122 (`XXXXXXXX-XXXX-XXXX-XXXX-XXXXXXXXXXXX`).
3. **Data**: Standard Base64 string.
4. **SyncOperations (`ops/ops-<deviceId>-<seq>.jsonl`)**:
   - One JSON object per line (`\n`-delimited).
   - `SyncOperation`: `{ "stamp": { "time": Int64, "device": String }, "change": { "<case>": { ... } }, "projectLocation"?: false }`
   - `AssetChanges.fields` & `BoardChanges.fields`: map of `{ [fieldName]: "<base64-encoded-json-fragment>" }`.
5. **Boards (`boards/<UUID>.json`)**:
   - Encoded `MoodboardDocument` with Swift keyed-enum `mode` (`{"autoEditorial":{"_0":{...}}}` or `{"freeform":{}}`) and `nodes[].kind` (`{"assetRef":{...}}`, `{"note":{...}}`, `{"groupFrame":{...}}`, `{"paletteStrip":{...}}`).
6. **Manifest (`manifest.json`)**:
   - `{ "version": 1, "rootFolderID": "...", "directories": { ... } }`.

## 3. Exact `.charkleboard` Figma Bridge Schema

Verified from `FigmaBridgeExporter.swift` and `Resources/FigmaPlugin/code.js`:
- ZIP archive with `.charkleboard` extension containing:
  - `manifest.json` (`objects[]`, `originals[]`, `warnings[]`, board metadata)
  - `tiles/<hash>_r<row>_c<col>.png` (lossless PNG tiles ≤ 4096×4096 px with SHA-256 checksums)
  - `originals/<assetUUID>.<ext>` (raw files, required for native `figma.createGif` animated GIFs in FigJam)
- Object `kind` values: `image`, `note`, `groupFrame`, `paletteStrip`, `connector`, `inkStroke`, `unsupported`.
- Supported transforms per object: `geometry: { x, y, width, height, angle, flipX, flipY }`.

## 4. External Agent & MCP 14-Tool Surface

Verified from `CharkleExternalAgentService.swift`:
- **Read Tools (8)**: `library_overview`, `search_assets`, `list_inbox`, `get_asset`, `render_contact_sheet`, `list_boards`, `get_board_context`, `export_board_image`.
- **Write Tools (6)**: `organize_assets`, `create_folder`, `ingest_asset`, `compose_moodboard`, `patch_moodboard`, `trash_assets`.
- **Resources (2)**: `charkle://library/overview`, `charkle://boards`.
- **Policy (`ExternalAgentConfig`)**: `enabled: boolean`, `accessLevel: 'readOnly' | 'readWrite'`.
