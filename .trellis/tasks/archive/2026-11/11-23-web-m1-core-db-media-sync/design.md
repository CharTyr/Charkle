# Design: M1 — Core, DB, Media Pipeline & Multi-Backend Sync

## Module Boundaries
- `@charkle/shared`: Zero Node/DOM dependencies. Exports `models/*`, `color/lab.ts`, `rules/smart-folder.ts`, `layout/editorial.ts`, `sync/swift-codec.ts`.
- `@charkle/server`:
  - `db/library-database.ts`: Wraps `node:sqlite` `DatabaseSync` with WAL + prepared statements + transaction helper + `SearchText` (`pinyin-pro`).
  - `db/sync-operations.ts`: HLC stamp generator, `AssetChanges`/`BoardChanges` diffing & CRDT merge (`SyncClocks`), `requeueLibraryForBackendMigration`.
  - `media/media-pipeline.ts`: Content-hash ingestion, `sharp` thumbnail generation (`grid520`, `preview1400`), CIELAB k-means/histogram dominant color extraction, perceptual DCT/color vector fingerprint, audio peak sampler, LRU original cache manager.
  - `media/resolvers/`: `github-resolver.ts`, `social-resolver.ts` (X/Threads/Bluesky via oEmbed/syndication/API/HTML OG fallbacks), `bookmark-resolver.ts`, `sample-seeder.ts`.
  - `sync/transport.ts`: `DriveTransport` interface matching `SyncModels.swift` + `direct-api-transport.ts`, `webdav-transport.ts`, `local-folder-transport.ts`, `in-memory-transport.ts`.
  - `sync/drive-sync-engine.ts`: Pulls remote ops, crawls/incrementally diffs inventory, reconciles renames/deletes, uploads physical files & sharded ops JSONL, syncs boards/thumbnails, broadcasts progress over SSE.
  - `storage/config-store.ts`: Persists `DriveSyncConfig`, `AIProviderConfig`, `TypeSafeExperimentalConfig`, `ExternalAgentConfig`, and encrypted secrets (`0600`) in `<dataDir>/config/`.
  - `api/app.ts`: Hono router + SSE event emitter + static media streaming with HTTP `Range` support.
- Data directory default: `./web/.charkle-data` (overridable via `CHARKLE_DATA_DIR` env var for testing and self-hosting).
