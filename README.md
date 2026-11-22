# Charkle Web

Self-hosted full-stack TypeScript visual reference library & rapid moodboard studio — featuring 1:1 domain parity and lossless bidirectional `/.charkle/` sync with Charkle for macOS, built-in MCP server, and bundled Figma / FigJam bridge plugin.

## Workspace Architecture

| Package | Path | Responsibility |
| --- | --- | --- |
| `@charkle/shared` | `packages/shared` | Canonical domain models (`AssetRecord`, `MoodboardDocument`, `DriveSyncConfig`, `AuthStatus`), CIELAB/CIEDE2000 color math, `SmartFolderRule` evaluator, `EditorialLayoutSolver`, CJK/Pinyin search text utilities, lossless Swift `/.charkle/` wire codec, and typed REST + SSE API contracts. |
| `@charkle/server` | `packages/server` | Hono HTTP + SSE server, Node.js built-in `node:sqlite` WAL + FTS5 database, `sharp` media pipeline & 2-tier thumbnail cache, authentication & API tokens, bidirectional Google Drive / WebDAV / local sync engine, Cloud AI & visual grounding integration, and MCP stdio server. |
| `@charkle/client` | `packages/client` | React + Tailwind CSS v4 + Zustand visual reference gallery (vertical masonry, horizontal justified, gallery filmstrip), infinite dual-mode moodboard canvas (Auto Editorial ↔ Freeform, notes, smart group frames, connectors, ink annotations, 3D viewer), quick jump, and settings. |
| Figma Bridge | `figma-plugin` | Bundled Figma / FigJam bridge plugin (`manifest.json`, `code.js`, `ui.html`) for importing exported moodboard packages with editable layers. |

## Prerequisites

- **Node.js 22.13+** (tested on **Node.js 26.11.0**, using built-in `node:sqlite` — no native SQLite addon compilation required).

## Quick Start

```bash
# Install all workspace dependencies
npm install

# Start development servers (API server on :3417 + Vite client on :5173)
npm run dev

# Type-check all packages
npm run typecheck

# Run test suites
npm test

# Build production bundles
npm run build

# Start production server
npm start

# Launch MCP stdio server for external AI agents
npm run mcp
```

## Docker Deployment

```bash
docker build -t charkle-web .
docker run -d \
  --name charkle-web \
  -p 3417:3417 \
  -v charkle_data:/data \
  -e CHARKLE_DATA_DIR=/data \
  charkle-web
```

## Environment Variables

Copy `.env.example` to `.env` and adjust as needed. All AI provider keys, Google Drive OAuth settings, and WebDAV credentials can also be configured securely from the Web UI once signed in.
