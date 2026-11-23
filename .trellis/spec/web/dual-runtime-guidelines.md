# Web Dual-Runtime Guidelines (Node.js & Cloudflare Workers)

> Executable contracts for keeping `@charkle/server` cleanly portable across Node.js / Docker (`node:sqlite` + local FS + `sharp`) and Cloudflare Workers (`CharkleLibraryDO` SQLite + R2 + `workerd`).

---

## Scenario 1: Runtime Seam Abstractions (`web/packages/server/src/runtime/types.ts`)

### 1. Scope / Trigger
- Trigger: Any change to database access, binary media storage, thumbnail/artwork rendering, secret encryption, or downloadable plugin/extension ZIP bundles inside `web/packages/server/` or `web/packages/worker/`.

### 2. Signatures
- `web/packages/server/src/runtime/types.ts`:
  ```ts
  export interface ISqlDatabase {
    exec(sql: string): void;
    run(sql: string, params?: SqlParam[]): { changes: number; lastInsertRowid?: number | bigint };
    get<T = Record<string, unknown>>(sql: string, params?: SqlParam[]): T | undefined;
    all<T = Record<string, unknown>>(sql: string, params?: SqlParam[]): T[];
    transaction<T>(fn: () => T): T;
    close?(): void;
  }

  export interface IBlobStore {
    put(key: string, data: Uint8Array | ReadableStream<Uint8Array>, options?: { contentType?: string }): Promise<{ size: number }>;
    getBytes(key: string): Promise<Uint8Array | null>;
    getStream(key: string, range?: BlobRangeRequest): Promise<BlobStreamResult | null>;
    head(key: string): Promise<BlobHeadResult | null>;
    delete(key: string): Promise<void>;
    list(prefix: string): Promise<BlobListItem[]>;
    localFilePath?(key: string): string | null;
    targetFilePath?(key: string): string;
  }
  ```
- Worker entrypoint (`web/packages/worker/src/index.ts`, `library-do.ts`):
  - Routes `/api` and `/api/*` into `env.CHARKLE_LIBRARY.idFromName(env.CHARKLE_LIBRARY_ID || 'default')`.
  - Routes all other paths to `env.ASSETS.fetch(request)` (Static Assets SPA).

### 3. Contracts
- **Strict Worker bundle isolation**: Code imported via `@charkle/server/worker` MUST have zero runtime imports of `node:fs`, `node:path` disk access, `node:sqlite`, or native `sharp`.
- **Durable Object SQLite (`web/packages/worker/src/do-sql.ts`)**:
  - `exec()` MUST split multi-statement SQL scripts cleanly while ignoring semicolons inside quotes/comments and skipping Node-only `PRAGMA` statements.
  - `get()` / `all()` MUST normalize returned `ArrayBuffer` BLOB columns into `Uint8Array`.
  - `transaction()` MUST guard nested calls against `workerd` `transactionSync` re-entrancy and recover cleanly on error.
- **R2 Streaming (`web/packages/worker/src/r2-blob.ts`)**:
  - `getStream(key, range)` MUST support native HTTP `206 Partial Content` Range reads with accurate `{ start, end, total }`.
  - `list(prefix)` MUST paginate across truncated R2 cursors and return sorted results.
- **Build-Time Bundled ZIPs (`web/packages/worker/scripts/pack-zips.mjs`)**:
  - Pre-packs `packages/extension/` (excluding `tests/`, `node_modules/`, dotfiles) and `figma-plugin/` (excluding `ui-template.html`, dotfiles) into `packages/worker/src/generated/bundles.ts` (gitignored).
  - Always regenerate via `npm run cf:pack` before Worker typecheck/tests/deploy.
- **Encrypted `SecretVault` (`web/packages/server/src/storage/secret-vault.ts`)**:
  - Stores secrets AES-256-GCM encrypted in `sync_state['vault.secrets.v1']`.
  - Production Workers MUST configure `CHARKLE_VAULT_KEY` via `wrangler secret put` (local dev uses gitignored `packages/worker/.dev.vars`).
- **Cached-Only Hover Media (`GET /api/v1/media/:id/original?cachedOnly=1`)**:
  - When `cachedOnly=1` (or `true`) and the original is not locally cached, return `404` (`code: 'NOT_CACHED'`) immediately WITHOUT invoking `sync.downloadOriginal` and WITHOUT touching LRU metadata.

### 4. Validation & Error Matrix
- Missing local cached original with `?cachedOnly=1` -> `404 { error, code: 'NOT_CACHED' }`, zero remote sync calls.
- Invalid `PRAGMA` on DO SQLite -> ignored gracefully; genuine SQL syntax/constraint error -> thrown immediately.
- Missing `CHARKLE_VAULT_KEY` in production Worker -> must fail/warn cleanly rather than silently storing plaintext secrets.

### 5. Good / Base / Bad Cases
- **Good**: Adding a new API route uses `ctx.db`, `ctx.blobs`, and `ctx.imageProcessor`, so both `npm test` (Node) and `npm run cf:dry-run` (Workers) pass without runtime branching.
- **Base**: Streaming a video via `GET /api/v1/media/:id/original` with `Range: bytes=0-65535` returns `206 Partial Content` on both Node FS and Cloudflare R2.
- **Bad (Prevented)**: Importing `fs.readFileSync` inside a route handler to serve `figma-plugin.zip` crashes Cloudflare Workers bundling with `node:fs` resolution failure.

### 6. Tests Required
- `web/packages/worker/tests/worker-adapters.test.ts` (`DurableObjectSqlDatabase` 5 tests, `R2BlobStore` 4 tests, `createBundledAssets` 2 tests).
- `web/packages/server/tests/runtime-cloudflare.test.ts` (dual-runtime server integration).
- `web/packages/server/tests/core-delta-extension.test.ts` (`cachedOnly=1`, extension ZIP, Figma plugin ZIP).

### 7. Wrong vs Correct
```ts
// WRONG: Direct Node filesystem access inside shared route code
import fs from 'node:fs';
const bytes = fs.readFileSync(path.join(dataDir, 'originals', fileName));

// CORRECT: Runtime-agnostic IBlobStore seam (works on Node FS and Cloudflare R2)
const streamResult = await ctx.blobs.getStream(`originals/${fileName}`, range);
```
