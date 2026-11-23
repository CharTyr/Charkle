# Web Edition Development Guidelines (`./web/`)

> Executable contracts and workspace conventions for Charkle Web — full-stack TypeScript monorepo supporting both self-hosted Node.js / Docker and Cloudflare Workers (Durable Object SQLite + R2).

---

## Architecture Summary

| Workspace / Dir | Path | Responsibility |
| --- | --- | --- |
| `@charkle/shared` | `web/packages/shared/` | Canonical domain models (`AssetRecord`, `MoodboardDocument`, `DriveSyncConfig`, `AuthStatus`), CIELAB/CIEDE2000 math, `SmartFolderRule`, `EditorialLayoutSolver`, CJK/Pinyin search utils, lossless `SwiftWireCodec` (`src/sync/swift-codec.ts`), and typed REST + SSE API contracts. |
| `@charkle/server` | `web/packages/server/` | Hono HTTP + SSE server, runtime-agnostic core over `ISqlDatabase` / `IBlobStore` / `IImageProcessor`, Node.js built-in `node:sqlite` + `sharp` adapters, AES-256-GCM `SecretVault`, Google Drive / WebDAV / local sync engine, Cloud AI & visual grounding, and MCP stdio server. |
| `@charkle/client` | `web/packages/client/` | React + Vite + Tailwind CSS v4 + Zustand visual reference gallery (Vertical Masonry, Horizontal Justified, Filmstrip), Freeform-first infinite moodboard canvas, Quick Look rich viewers, 9-pane Settings overlay, and Onboarding studio. |
| `@charkle/worker` | `web/packages/worker/` | Cloudflare Workers edge entrypoint: Static Assets SPA + `CharkleLibraryDO` (SQLite-backed Durable Object + Alarms) + `R2BlobStore` (HTTP `206` Range streaming) + build-time bundled extension & Figma plugin ZIPs (`src/generated/bundles.ts`). |
| Browser Clipper | `web/packages/extension/` | Manifest V3 browser clipper extension (`popup.*`, `options.*`, `content.js`, `background.js`) with standalone `node --test` suite (`tests/extension.test.mjs`). |
| Figma Bridge | `web/figma-plugin/` | Bundled Figma / FigJam `.charkleboard` importer — MUST remain byte-identical to `Resources/FigmaPlugin/`. |

- **Node.js Runtime**: `>= 22.13.0` (built-in `node:sqlite`, zero native SQLite compilation).

---

## Guidelines Index

| Guide | Description | Status |
| --- | --- | --- |
| [Dual-Runtime Guidelines](./dual-runtime-guidelines.md) | `ISqlDatabase` / `IBlobStore` / `IImageProcessor` seams, DO SQLite & R2 contracts, `pack-zips` build-time bundling, secret handling | Active |
| [Cross-Platform Contracts](../cross-platform/index.md) | `/.charkle/` Swift wire protocol, `.charkleboard` Figma ZIP schema, 14-tool MCP safety policy, repo purity | Active |

---

## Pre-Development Checklist

Before editing files under `web/`:

- [ ] Never import `node:fs`, `node:sqlite`, `sharp`, or `node:crypto` inside `@charkle/shared` or `@charkle/server/worker`-reachable runtime-agnostic server modules; route through `runtime/types.ts` seams (`ISqlDatabase`, `IBlobStore`, `IImageProcessor`, `web-crypto-*`).
- [ ] Keep `@charkle/shared` `SwiftWireCodec` (`web/packages/shared/src/sync/swift-codec.ts`) strictly compatible with macOS `DriveSyncEngine` and `SyncOperations.swift`.
- [ ] Keep `BoardLayoutMode`'s `'autoEditorial'` union variant and `DriveTransportMode`'s `'gdirectMount'` variant decodable for legacy/macOS synced libraries even though Web creates Freeform boards by default.
- [ ] Never introduce macOS-only terms (`Apple Vision`, `刘海`, `访达`, `钥匙串`) or developer jargon (`FTS5`, `CIELAB`, `scrypt`, `Manifest V3`) into user-facing Web or browser extension UI copy.
- [ ] Never commit `.env*`, `.dev.vars*`, `.wrangler/`, `packages/worker/src/generated/bundles.ts`, or local `.charkle-data/` databases.

---

## Quality Check (Run Before Finish)

```bash
cd web
npm run typecheck
npm test
node --test packages/extension/tests/extension.test.mjs
npm run build
```

For Cloudflare Workers changes, also verify:

```bash
cd web
npm run cf:typecheck
npm run cf:dry-run
```
