# Implementation Plan: M1 — Core, DB, Media Pipeline & Multi-Backend Sync

1. [ ] Initialize `./web/package.json` (npm workspaces), `tsconfig.base.json`, and workspace manifests for `shared`, `server`, `client`; install dependencies (`hono`, `@hono/node-server`, `sharp`, `pinyin-pro`, `jszip`, `react`, `react-dom`, `zustand`, `lucide-react`, `marked`, `dompurify`, `three`, `tailwindcss`, `@tailwindcss/vite`, `vite`, `typescript`, `vitest`, `tsx`, `@types/*`).
2. [ ] Build `packages/shared`:
   - `src/models/{core,media,moodboard,sync}.ts`
   - `src/color/lab.ts`, `src/rules/smart-folder.ts`, `src/layout/editorial.ts`
   - `src/sync/swift-codec.ts`
3. [ ] Build `packages/server/src/db/`: `search-text.ts`, `library-database.ts`, `sync-operations.ts`.
4. [ ] Build `packages/server/src/media/`: `color-extractor.ts`, `fingerprint.ts`, `media-pipeline.ts`, `resolvers/{github,social,bookmark}.ts`, `sample-seeder.ts`.
5. [ ] Build `packages/server/src/sync/`: `transport.ts`, `in-memory-transport.ts`, `local-folder-transport.ts`, `webdav-transport.ts`, `direct-api-transport.ts`, `google-oauth.ts`, `drive-sync-engine.ts`.
6. [ ] Build `packages/server/src/storage/config-store.ts`, `engine.ts` (`LiveCharkleWebEngine`), `api/{events,routes,app}.ts`, and `index.ts`.
7. [ ] Add icon sync script in `packages/client` + minimal React+Vite verification shell.
8. [ ] Write & run Vitest suites in `packages/shared` and `packages/server` covering DB, FTS5/pinyin, CIELAB, `SwiftWireCodec`, `EditorialLayoutSolver`, MediaPipeline/LRU, and `DriveSyncEngine` multi-device sync & migration.

## Validation Commands
```bash
cd web && npm run typecheck && npm test
```
