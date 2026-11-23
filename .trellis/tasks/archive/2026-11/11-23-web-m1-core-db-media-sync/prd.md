# PRD: M1 — Web Foundation, SQLite/FTS5, Media Pipeline & Multi-Backend Sync

- **Parent Task**: `11-23-web-version`
- **Dependencies**: None (first milestone)

## Goal
Establish the `./web/` npm workspaces foundation (`shared`, `server`, `client`), exact domain contracts & `SwiftWireCodec`, SQLite WAL + FTS5/pinyin/color/vector `LibraryDatabase`, all-8-media-kind `MediaPipeline` + rich link resolvers, multi-backend `DriveSyncEngine` (Google Drive, WebDAV, Local Folder, InMemory) + lossless migration, and the Hono REST + SSE API server.

## Requirements
1. **Workspace & Tooling**: `./web/` with `packages/shared`, `packages/server`, `packages/client`; strict TypeScript, Vitest, Vite 6 + React 19 shell, and automated icon sync script copying `Sources/CharkleApp/Resources/Icons/*.svg` into `client/public/icons/`.
2. **Isomorphic `@charkle/shared`**:
   - Complete TypeScript models mirroring `CoreModels.swift`, `MediaModels.swift`, `MoodboardModels.swift`, `SyncModels.swift`.
   - `LabColor` (sRGB→CIELAB + ΔE), `AspectShape.classify`, `MediaKind.detect`, `SmartFolderRule.matches`, `DriveSyncConfig.extractGoogleDriveFolderID`.
   - Exact port of `EditorialLayoutSolver` (`solve` for `balanced`/`magazine`/`compact` + `reflowNodesInsideGroupFrame`).
   - `SwiftWireCodec` for lossless macOS `/.charkle/` JSON/JSONL encoding & decoding (Cocoa reference timestamps, uppercase UUIDs, Swift keyed enums, Base64 `SyncFields`).
3. **`LibraryDatabase` (`node:sqlite`)**:
   - WAL mode, schema version 2 matching `LibraryDatabase.swift` (`assets`, `assets_fts` FTS5 w/ `pinyin-pro`, `asset_tags`, `asset_colors`, `asset_vectors`, `folders`, `smart_folders`, `boards`, `board_assets`, `sync_ops`, `sync_state`, `original_cache`).
   - Full `FilterCriteria` SQL query builder (recursive subfolder CTE, CIELAB squared-distance color match, FTS5 + pinyin/initials search, all 6 `SortOrder` modes), `QuickJump`, vector cosine similarity, folder move/reorder/appearance, and CRDT `apply(SyncOperation)` merge.
4. **`MediaPipeline` & Rich Resolvers**:
   - Ingest all 5 `CaptureInput` types across all 8 `MediaKind` categories.
   - `sharp` thumbnails (`grid520`, `preview1400`), CIELAB dominant color extraction, perceptual fingerprint vector, audio waveform peaks, configurable LRU original cache + offline pin protection.
   - Server-side resolvers for X / Threads / Bluesky posts, GitHub repositories (metadata + README), generic WebBookmarks (OpenGraph), and `SampleLibrarySeeder` on first launch.
5. **`DriveSyncEngine` & Transports**:
   - `DirectAPITransport` (Google Drive API v3 + PKCE OAuth + shared folder URL/ID + incremental Changes), `WebDAVTransport`, `LocalFolderTransport`, `InMemoryDriveTransport`.
   - `/.charkle/` sharded incremental sync (`manifest.json`, `ops/ops-<device>-<seq>.jsonl`, `boards/<uuid>.json`, `thumbnails/`, `embeddings/`), `driveFileID` rename tracking, lossless two-way `StorageMigration`, and live SSE `SyncStatus` stream.
6. **REST + SSE Server**: Hono server exposing `/api/v1/*`, Range-enabled media streaming, and `/api/v1/events` SSE bus.

## Acceptance Criteria
- `cd web && npm run typecheck` passes with 0 errors across all 3 packages.
- `cd web && npm test` passes unit & integration tests covering: SQLite FTS5/Chinese pinyin/CIELAB/recursive folder queries, `SwiftWireCodec` round-trip against macOS Swift fixtures, all-media ingestion & LRU eviction respecting pinned assets, multi-device sync merge & remote rename reconciliation via `InMemoryDriveTransport`, and `EditorialLayoutSolver` deterministic layout.
- Starting the server serves `/api/v1/health`, auto-seeds the sample library if empty, and responds cleanly to library, folder, smart-folder, board, media, and SSE requests.
