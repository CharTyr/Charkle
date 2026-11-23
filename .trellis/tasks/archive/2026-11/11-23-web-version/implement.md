# Implementation Plan: Charkle Web Full-Parity Sync Development

## Execution Strategy

Execute sequentially across the 5 independently verifiable child tasks (`M1` → `M5`), running `task.py start <child>` for each milestone, verifying builds/tests/runtime at every gate before advancing, and keeping the existing macOS Swift codebase strictly untouched.

---

## Milestone Checklist

### Milestone 1 (`11-23-web-m1-core-db-media-sync`) — Core, DB, Media & Multi-Backend Sync
- [ ] Scaffold `./web/` npm workspaces (`packages/shared`, `packages/server`, `packages/client`) + TypeScript / Vite / Vitest configs + icon sync script from `Sources/CharkleApp/Resources/Icons/`.
- [ ] Implement `@charkle/shared`: all domain types (`CoreModels`, `MediaModels`, `MoodboardModels`, `SyncModels`), `LabColor` & ΔE math, `SmartFolderRule` evaluator, `EditorialLayoutSolver`, and `SwiftWireCodec`.
- [ ] Implement `LibraryDatabase` on Node 26 `node:sqlite` (WAL + FTS5 + `pinyin-pro` + CIELAB color query + vectors + recursive folder queries + sync ops/clocks).
- [ ] Implement `MediaPipeline` (8 `MediaKind` detectors, `sharp` 520/1400 thumbnails, CIELAB extraction, audio waveform extraction, LRU original cache + offline pinning, rich resolvers for X/Threads/Bluesky/GitHub/WebBookmark, `SampleLibrarySeeder`).
- [ ] Implement `DriveSyncEngine` + 4 transports (`DirectAPITransport` Google Drive API v3 + OAuth + shared folders, `WebDAVTransport`, `LocalFolderTransport`, `InMemoryDriveTransport`) + lossless `StorageMigration`.
- [ ] Implement Hono REST + SSE API server & comprehensive `vitest` suite (DB, FTS5/pinyin, color filter, media ingest, Swift wire codec round-trip, multi-device sync conflict/rename tests).
- **Gate**: `cd web && npm run typecheck && npm test` all green.

### Milestone 2 (`11-23-web-m2-gallery-nav-quicklook`) — Gallery-First UI, Nav, Inbox & Quick Look
- [ ] Implement Gallery-First design system (`theme.css`, Light/Dark tokens, Liquid Glass utilities, concentric radii, `CharkleIcon` loading original Duotone/Layered SVGs, Zustand domain stores + SSE listener).
- [ ] Implement `SidebarView` (all system destinations, Inbox count badge, nested `FolderTree` with drag-reorder/nesting & `FolderCustomizationPopover`, `SmartFolders` + `SmartFolderEditorSheet`, `Tags`).
- [ ] Implement `TopFilterCapsule` (FTS5/pinyin search, semantic search toggle, media kinds, CIELAB color + tolerance, aspect shape, rating, tags, offline pin, sort order, layout mode switcher).
- [ ] Implement 3 Gallery views (`VerticalMasonryView`, `HorizontalJustifiedView`, `GalleryFilmstripView`), marquee box-select, floating `BatchActionPill`, and `InboxTriageBar` (`1–9` shortcuts, AI suggestion, Inbox Zero).
- [ ] Implement `JumpAnywhereModal` (`⌘J`), `InspectorView` (single + multi-select, tags/AI tags, palette, similar assets, TypeSafe actions), and `QuickLookOverlay` (all 8 media viewers incl. GitHub README, Social Post carousel, Audio waveform, PDF/Markdown/Code, Three.js 3D viewer, filmstrip, ambient tint).
- **Gate**: `cd web && npm run typecheck && npm run build` green + live browser smoke verification.

### Milestone 3 (`11-23-web-m3-moodboard-studio-figma`) — Dual-Mode Moodboard Studio & Figma Bridge
- [ ] Implement `MoodboardsHomeView` + Active Moodboard selector + `MoodboardGeneratorModal` (4+1 entries + live SSE Agent Harness trace UI).
- [ ] Implement server-side `MoodboardCurator` (MMR diversity + multi-signal scoring) + `MoodboardAgentHarness` (multi-phase streaming + refinement).
- [ ] Implement `MoodboardCanvasView`: Auto Editorial (`balanced`/`magazine`/`compact`, drag-reorder ripple, Hero weight) ↔ Freeform infinite canvas (pan/zoom, smart alignment guides, rotate/flip/lock/z-index, non-destructive crop, Undo/Redo).
- [ ] Implement all 5 node/annotation types (`AssetRef`, 5-style `Note`, 6-tint `GroupFrame` w/ auto-reflow & child move, `PaletteStrip`, `BoardConnector` w/ pinpoint callouts, `InkStroke` freehand pen), right `CandidatePoolPanel`, and drag-external-file-to-canvas auto-ingest.
- [ ] Implement server-side High-DPI PNG/JPG exporter and offline lossless `.charkleboard` ZIP `FigmaBridgeExporter` (verified against `Resources/FigmaPlugin/code.js` schema & SHA-256 tile verification).
- **Gate**: `cd web && npm run typecheck && npm test && npm run build` green + verified `.charkleboard` export structure.

### Milestone 4 (`11-23-web-m4-ai-typesafe-settings-shelf-mcp`) — Hybrid AI, TypeSafe Jev, Settings, Shelf & MCP
- [ ] Implement `CloudAIProvider` (Disabled/Local, ChatGPT Subscription, Gemini, OpenAI Chat Completions, Anthropic Messages, OpenAI Responses) + `CloudAIUsageTracker` + encrypted server secret vault.
- [ ] Implement Experimental `TypeSafeSystemOneClient` + `VisualGroundingEngine` (all Phase 1 & Phase 2 actions with graceful local fallback).
- [ ] Implement complete 6-tab `SettingsModal` (`存储与同步` + Lossless Migration Wizard + OAuth/WebDAV/Local configs + gdirect info, `智能与搜索`, `外观与图标`, `外部 Agent 与 MCP`, `缓存空间`, `采集与快捷键`).
- [ ] Implement Web `QuickDropShelf` (top-center spring-morphing dark glass capsule, global drag-drop, `⌘V` clipboard capture, URL/text/swatch capture, Inbox/Folder/Active Moodboard target switcher).
- [ ] Implement `ExternalAgentService` (all 14 MCP tools over JSON-RPC 2.0 HTTP & stdio CLI + contact sheet renderer + policy enforcement + SSE UI live refresh).
- **Gate**: `cd web && npm run typecheck && npm test && npm run build` green + MCP tool & Settings E2E checks.

### Milestone 5 (`11-23-web-m5-motion-polish-e2e-verification`) — Motion Polish, Interop QA & Final Acceptance
- [ ] Audit and refine calibrated motion continuity (Quick Look hero transition, travelling sidebar pill, Auto↔Freeform interpolation, popover trigger-origin scale, reduced-motion / reduced-transparency fallbacks).
- [ ] Run automated cross-platform `/.charkle/` Swift ↔ Web sync round-trip tests and `.charkleboard` Figma Bridge verification tests.
- [ ] Run real-browser E2E walkthrough across Light (`#F6F6F5`) and Dark (`#141517`) modes covering Library, Inbox, Quick Look, Moodboard Studio, Quick Drop Shelf, and Settings.
- [ ] Update `.trellis/spec/` with Web architecture & sync interop conventions and verify existing `swift test` remains clean.

---

## Validation Commands

```bash
# Typecheck all Web workspaces
cd web && npm run typecheck

# Unit & integration tests (DB, Codec, Sync, AI, Figma Bridge, MCP)
cd web && npm test

# Production build (shared + server + client)
cd web && npm run build

# Verify native Swift suite remains unaffected
cd . && swift test
```

## Risky Seams & Rollback Points

1. **Swift ↔ Web `/.charkle/` Wire Format**: Handled centrally in `web/packages/shared/src/swift-codec.ts` with dedicated golden-fixture tests matching Swift's exact `JSONEncoder` output (Cocoa reference dates, uppercase UUIDs, keyed enums, Base64 `SyncFields`).
2. **`.charkleboard` Figma Plugin Interop**: Checked directly against `Resources/FigmaPlugin/code.js` required fields (`manifest.json` version, `objects`, `geometry`, `tiles`, `originals`, SHA-256).
3. **Browser CORS & Large Media Streaming**: All external fetches (Drive, WebDAV, X/Threads/Bluesky, GitHub, Cloud AI, TypeSafe) execute on the Node.js server; video/audio originals stream via HTTP `Range` requests.
4. **Rollback**: Each milestone is committed cleanly on top of `./web/` without altering Swift sources; any defect rolls back locally within the affected workspace package.
