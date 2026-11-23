# Charkle

Visual reference library & rapid moodboard studio across **macOS**, **Web**, and **Windows** — unified in one monorepo with lossless bidirectional `/.charkle/` cloud sync, built-in MCP / External Agent tools, and Figma / FigJam Bridge parity.

## Platforms & Monorepo Layout

| Platform | Path | Status | Stack & Highlights |
| --- | --- | --- | --- |
| **macOS Native** | `./` (`Package.swift`, `Sources/`, `Tests/`, `Resources/`, `scripts/`) | **v1.0.1 Released** | Swift 6 + SwiftUI + AppKit (macOS 15+). Virtualized Masonry / Justified / Filmstrip gallery, Dual-Mode Moodboard Infinite Canvas, Full-Media Quick Look (original long-strip preview, EXIF & AI prompt metadata), Notch Shelf, Google Drive / `gdirect` / WebDAV sync, `charkle-cli` & MCP server. |
| **Web Edition** | [`./web/`](./web/) | **Completed** | Full-stack TypeScript monorepo (`@charkle/shared`, `@charkle/server`, `@charkle/client`, `@charkle/worker`). Supports self-hosted Node.js / Docker (`node:sqlite` + `sharp`) and zero-server **Cloudflare Workers** (Durable Object SQLite + R2), Browser Clipper extension, and MCP stdio server. |
| **Windows Native** | [`./windows/`](./windows/) | **Planned** | Tauri v2 + pure Rust Core (`charkle-core`, `charkle-cli`, `src-tauri/`) + React UI (`ui/`). Windows 11 Mica/Acrylic floating chrome, Top-Edge Drop Shelf, WinRT offline OCR, Shell thumbnails, DPAPI vault, OLE drag-and-drop, and NSIS installer. |
| **Figma Bridge** | `Resources/FigmaPlugin/` & `web/figma-plugin/` | **Available** | Lossless `.charkleboard` ZIP importer for Figma & FigJam preserving editable frames, high-DPI tiles, native GIFs, notes, connectors, and ink strokes. |

---

## Quick Start

### macOS Native (`./`)

Requires macOS 15+ and Swift 6.2+.

```bash
# Build & run test suite
swift build
swift test

# Build signed app bundle & distributable DMG (arm64)
./scripts/build-dmg.sh --rebuild
```

Prebuilt macOS installers are published on [GitHub Releases](https://github.com/CharTyr/Charkle/releases).

### Web Edition (`./web/`)

Requires Node.js 22.13+.

```bash
cd web
npm ci

# Start local dev servers (API :3417 + Vite client :5173)
npm run dev

# Type-check, test, and build production bundles
npm run typecheck
npm test
npm run build
```

Docker & **Cloudflare Workers** (`npm run cf:dev` / `npm run cf:deploy`) deployment instructions are documented in [`web/README.md`](./web/README.md).

### Windows Native (`./windows/`)

The Windows desktop client is planned in `./windows/` as a self-contained Cargo + Tauri v2 + React workspace sharing the exact `/.charkle/` wire protocol and Figma Bridge contract with macOS and Web. See [`windows/README.md`](./windows/README.md) for the architecture and milestone roadmap.

---

## Cross-Platform Parity

- **Lossless `/.charkle/` Sync**: All clients read and write the same sharded metadata & media manifest format (Cocoa reference timestamps, HLC + per-field LWW conflict resolution, tag tombstones) across Google Drive API, WebDAV, mounted drives, and local folders.
- **Moodboard & Figma Bridge**: Dual-mode Auto Editorial ↔ Freeform canvas documents and `.charkleboard` ZIP exports stay wire-compatible across macOS, Web, and Windows.
- **External Agent & MCP**: Consistent library search, asset capture, folder organization, and moodboard curation tools exposed via CLI / MCP.

## Architecture & Docs

- **macOS Modules**: `Sources/CharkleCore` (`nonisolated`), `Sources/CharkleCanvas` (`@MainActor`), `Sources/CharkleApp` (`@MainActor`), `Sources/CharkleCLI`, `Tests/CharkleTests`
- **Design & Specs**: [`docs/BLUEPRINT.md`](./docs/BLUEPRINT.md) · [`docs/MOTION_AND_ICON_SPEC.md`](./docs/MOTION_AND_ICON_SPEC.md) · [`web/README.md`](./web/README.md) · [`windows/README.md`](./windows/README.md)
