# PRD: Windows M4 — Dual-Mode Moodboard Studio, Agent Curator & Figma Bridge

> Parent Task: `11-23-windows-client` · Depends On: `11-23-windows-m1-core-db-media-sync`, `11-23-windows-m2-gallery-nav-quicklook`, `11-23-windows-m3-native-shelf-capture-winrt`

## 1. Goal & User Value

Deliver Charkle's signature **10-second Moodboard Studio** on Windows: 4+1 instant generation powered by the Rust MMR Curator & 8-phase Moodboard Agent Harness, Candidate Replacement Pool, zero-jump **Auto Editorial ↔ Freeform Infinite Canvas** with all 5 node/annotation types, direct external file drop onto canvas, high-DPI PNG/JPG export, and offline lossless **`.charkleboard` ZIP** export verified directly against `Resources/FigmaPlugin/code.js`.

## 2. Requirements

- **M4-R1 `EditorialLayoutSolver` Parity**: Port `EditorialLayoutSolver.swift` (`balanced` 3–4 cols, `magazine` 2–3 cols with up to 3 2-column Hero spans, `compact` 5–7 cols, `reflowNodesInsideGroupFrame`) deterministically into Rust (and shared TS preview helpers) so Auto Editorial layouts match macOS coordinates identically.
- **M4-R2 Moodboards Home & 4+1 Generator + Agent Harness**:
  - Moodboards Home grid (collage preview, palette chips, item count, mode badge, Active Moodboard toggle, offline pin).
  - 4+1 Entry Generator modal (Inspiration Prompt, Seed Assets, Color Palette + ΔE tolerance, Manual Selection, Combined + folder/tag scope + detail focus crop option).
  - Rust `MoodboardCurator` (FTS5 + CIELAB ΔE + perceptual/cloud embeddings + MMR diversity penalty) and `MoodboardAgentHarness` streaming all 8 phases (`planning` → `retrieving` → `inspectingVisuals` → `composing` → `verifying` → `repairing` → `completed` / `fallbackOffline`) over Tauri events with iterative refinement.
- **M4-R3 Right Candidate Replacement Pool**: Present 20–40 ranked replacement assets; support 1-click in-place swap preserving layout slot or drag-add directly onto canvas.
- **M4-R4 Dual-Mode Canvas & All 5 Element/Annotation Types**:
  - **Auto Editorial Mode**: column/spacing/style controls, Hero weight toggle, drag-to-reorder with Kubai Tip 005 ripple (`A * pow(0.7, n)`, `24ms * n` stagger).
  - **Zero-Jump Freeform Infinite Canvas**: freezing resolved editorial rects onto `node.frame` on switch with smooth continuous transition; wheel/pinch zoom, space+drag / middle-mouse pan, 6px smart alignment guides, box-select, rotate, flipH/flipV, lock, z-index ordering, non-destructive normalized crop, multi-step Undo/Redo (`Ctrl+Z` / `Ctrl+Y` / `Ctrl+Shift+Z`).
  - **All 5 Element & Annotation Types**: `assetRef` (hover/loop GIF & video, crop, refresh, OLE outbound drag), `note` (5 styles: `paper`/`ink`/`warm`/`sage`/`slate`), `groupFrame` (6 tints, dragging header moves enclosed children, real-time Smart Auto-Layout reflow on resize), `paletteStrip` (auto-sync board palette, click copy HEX, reverse color search), `BoardConnector` (curved/elbow/straight arrows, dashed/solid, labels, pinpoint normalized internal anchor callouts), and `InkStroke` (freehand vector pen with color/width/opacity).
  - Dragging external files from Windows Explorer directly onto canvas auto-ingests into Inbox + inserts canvas node at drop coordinates; single-source reference model (never duplicating original files).
- **M4-R5 High-DPI Image & Lossless `.charkleboard` Figma Bridge Export**:
  - Rust `BoardImageExporter`: 1×/2× high-DPI PNG/JPG export with toggleable annotations & palette strip, plus copy-to-clipboard for direct `Ctrl+V` into Figma/PowerPoint.
  - Rust `FigmaBridgeExporter`: offline lossless `.charkleboard` ZIP (`format: "charkle-figma-bridge"`, `version: 1`, ≤4096×4096 lossless PNG tiles in `tiles/*.png` with exact 4096 grid alignment & 64-char hex SHA-256, `originals/*.gif` for animated GIFs) passing `Resources/FigmaPlugin/code.js` validation and `scripts/test-figma-plugin.cjs`.

## 3. Out of Scope

- Cloud AI provider configuration UI & TypeSafe Jev sidecar visual rerank controls (M5 — M4 runs full local offline curator + harness fallback and calls the `IntelligenceEngine` trait seam so M5 plugs in Cloud AI / TypeSafe seamlessly).

## 4. Acceptance Criteria

- [ ] Deterministic `EditorialLayoutSolver` tests confirm identical rects/column assignment against macOS test cases across `balanced`, `magazine`, and `compact`.
- [ ] Generating a moodboard from any of the 4+1 entry points streams live harness phases, populates main board + 20–40 candidate pool, and supports 1-click swap + Auto Editorial ↔ Freeform transition with zero coordinate jump.
- [ ] All 5 node/annotation types, multi-step Undo/Redo, and Explorer drag-in-to-canvas work cleanly and sync losslessly with macOS via `/.charkle/boards/<UUID>.json`.
- [ ] Exported `.charkleboard` ZIP passes `Resources/FigmaPlugin/code.js` schema validation (`scripts/test-figma-plugin.cjs`) with valid ≤4096px PNG tiles, SHA-256 hashes, and animated GIF originals.
