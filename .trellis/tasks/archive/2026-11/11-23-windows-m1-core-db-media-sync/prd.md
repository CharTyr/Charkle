# PRD: Windows M1 — Rust Core, SQLite FTS5, Media Pipeline & `/.charkle/` Sync

> Parent Task: `11-23-windows-client` · Depends On: None (First Deliverable)

## 1. Goal & User Value

Establish the `./windows/` Cargo workspace and deliver the complete OS-agnostic **`charkle-core`** Rust library covering domain contracts, SQLite WAL + FTS5 + Chinese pinyin + CIELAB + vector storage, 8-kind `MediaPipeline` + EXIF/AI prompt extraction + rich web/social/GitHub resolvers + LRU cache, and 4-mode `DriveSyncEngine` with **100% lossless bidirectional `/.charkle/` sync parity** with macOS Charkle v1.0.1.

## 2. Requirements

- **M1-R1 Workspace & Tooling**: Create `./windows/` Cargo workspace (`crates/charkle-core`, `crates/charkle-platform-win` trait stubs, `crates/charkle-cli` stub, `src-tauri` skeleton), `rust-toolchain.toml`, `scripts/sync-icons.mjs` (syncing all 49 SVGs from `Sources/CharkleApp/Resources/Icons/`), and `scripts/verify-windows.ps1`.
- **M1-R2 Domain Models & `SwiftWireCodec`**: Mirror `CoreModels.swift`, `MediaModels.swift`, `MoodboardModels.swift`, `SyncModels.swift`, and `ExternalAgentPolicy.swift` 1:1 in Rust with `SwiftWireCodec` handling Cocoa reference dates (`978_307_200.0`), uppercase RFC-4122 UUIDs, Base64 `Data`, Swift keyed enums (`BoardLayoutMode`, `BoardNodeKind`, `SyncOperation::Change`), and Base64 JSON fragment `SyncFields`.
- **M1-R3 `LibraryDatabase`**: Implement SQLite schema `user_version = 2` via bundled `rusqlite` matching `LibraryDatabase.swift` (WAL + FTS5 `unicode61 remove_diacritics 2`, `prefix='2 3 4'`, Chinese full pinyin & initials via `pinyin` crate, `asset_tags`, `asset_colors`, `asset_vectors`, `folders`, `boards`, `board_assets`, `sync_ops`, `sync_state`, `original_cache`, GitHub README + social post FTS indexing, recursive folder queries, all 6 `SortOrder` modes, full `FilterCriteria`, `SmartFolderRule` evaluation, `QuickJumpMatch`).
- **M1-R4 `MediaPipeline` & Rich Resolvers**: Ingest all 5 `CaptureInput` forms across all 8 `MediaKind` categories; generate `grid520` and `preview1400` thumbnails (`image`, `fast_image_resize`, `resvg`, plus `ShellThumbnailProvider` trait hook for M3); extract CIELAB dominant color swatches & ΔE; parse EXIF + Stable Diffusion/ComfyUI/Midjourney/NovelAI prompts matching `ImageMetadataExtractor.swift`; compute audio peak waveforms (`symphonia`); enforce configurable 2–100 GB LRU original cache respecting `pinnedOffline` on assets and boards; implement server-side/native `reqwest` resolvers for X/Threads/Bluesky (with avatars & multi-attachments), GitHub repos (OG/README/stars/language/topics), and generic OpenGraph bookmarks; seed sample library on empty first launch.
- **M1-R5 `DriveSyncEngine` & Multi-Backend Transports**: Implement HLC `(time, device)`, per-field LWW clocks, tag tombstone sets, per-node/connector/stroke collection merge, `driveFileID` + `contentHash` rename/move tracking, Windows illegal-character filename sanitization on local projection, lossless two-way `StorageMigration`, and 5 transports (`DirectAPITransport` Google Drive API v3 + PKCE loopback OAuth + shared folder URL/ID + optional `gdirect.exe` IP override, `WebDAVTransport`, `MountedVolumeTransport` behind `VolumeMountInspector`, `LocalFolderTransport`, `InMemoryDriveTransport`).

## 3. Out of Scope

- Tauri React UI views (M2), Win32/WinRT platform concrete implementations (M3), Moodboard Canvas & Figma export UI (M4), Cloud AI / TypeSafe Jev / CLI+MCP commands (M5).
- Touching macOS `Sources/`, `Tests/`, or `Package.swift`.

## 4. Acceptance Criteria

- [ ] `cd windows && cargo test --workspace` passes with zero warnings (`cargo clippy --workspace --all-targets -- -D warnings` clean).
- [ ] Golden macOS `/.charkle/` fixtures (`manifest.json`, `ops/*.jsonl`, `boards/*.json`) decode, mutate, re-encode, and round-trip without data loss.
- [ ] `InMemoryDriveTransport` concurrent multi-device tests verify tag tombstone merges, concurrent board edits, remote rename tracking by `driveFileID`, and lossless migration across storage modes.
- [ ] Benchmark/unit tests verify FTS5 Chinese pinyin/initials search, CIELAB ΔE filtering, EXIF/AI prompt extraction, and LRU eviction respecting `pinnedOffline` protection.
