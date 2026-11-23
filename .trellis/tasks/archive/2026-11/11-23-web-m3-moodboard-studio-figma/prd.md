# PRD: M3 — Dual-Mode Moodboard Studio, Curator Pool & Figma Bridge

- **Parent Task**: `11-23-web-version`
- **Dependencies**: `11-23-web-m1-core-db-media-sync`, `11-23-web-m2-gallery-nav-quicklook`

## Goal
Deliver Charkle's signature **Dual-Mode Moodboard Studio** on the Web: 4+1 entry quick generation with live streaming **Moodboard Agent Harness**, MMR diversity curation & right-side Candidate Replacement Pool, seamless Auto Editorial ↔ Freeform infinite canvas with all 5 node/annotation types and Undo/Redo, high-DPI image export, and offline lossless **`.charkleboard` Figma/FigJam Bridge** export directly compatible with `Resources/FigmaPlugin`.

## Requirements
1. **Moodboards Home & Active Board**:
   - Grid of board cards showing 4-up preview thumbnails, palette strip, item count, mode badge (`自动排版`/`自由画布`), offline pin toggle, Active Board badge, create/duplicate/delete actions.
2. **4+1 Moodboard Generator & Agent Harness**:
   - Modal supporting Inspiration Prompt, Seed Assets (1–3), Color Palette + ΔE tolerance, Manual Selection, and Combined multi-signal brief (with folder/tag scope, layout style, freeform toggle, curator notes toggle, and auto-focus detail crop option).
   - Server-side `MoodboardCurator` (FTS5 + tag + color ΔE + visual fingerprint + optional Cloud AI semantic score + MMR diversity penalty) and `MoodboardAgentHarness` streaming live `MoodboardAgentStep` phases (`planning` → `retrieving` → `inspectingVisuals` → `composing` → `verifying` → `repairing` → `completed`/`fallbackOffline`) via SSE + refinement instructions on existing boards.
3. **Right Candidate Replacement Pool**:
   - Displays 20–40 ranked replacement candidates alongside the moodboard; 1-click replaces the currently selected canvas image in-place without disrupting layout rhythm, or adds to canvas.
4. **Dual-Mode Canvas (`Auto Editorial` ↔ `Freeform`)**:
   - **Auto Editorial**: Uses `@charkle/shared` `EditorialLayoutSolver` (`balanced`, `magazine` w/ Hero 2× span, `compact`), live spacing/columns/style controls, Hero weight toggle on cards, drag-to-reorder with drag-reorder ripple feedback.
   - **Zero-Jump Transition to Freeform**: Freezes exact editorial rects onto `node.frame` and switches seamlessly into an infinite pan/zoom canvas (wheel zoom, space-drag pan, zoom controls, fit-to-view, smart alignment guides, marquee multi-select, rotate, flipH/flipV, lock, z-index bring-forward/send-back, non-destructive crop editor, multi-step Undo/Redo `⌘Z`/`⇧⌘Z`).
   - One-click "Re-tidy / Auto-Arrange" action.
5. **5 Canvas Node & Annotation Types**:
   - `assetRef` (image/GIF/video hover-loop, non-destructive crop, swap, open Quick Look, pinpoint annotate)
   - `note` (5 styles: `paper`/`ink`/`warm`/`sage`/`slate`, inline title/body editing, font size)
   - `groupFrame` (6 tints, dragging frame header moves enclosed nodes together, resizing triggers `reflowNodesInsideGroupFrame` smart auto-layout option)
   - `paletteStrip` (auto-sync with board palette, click copy HEX, reverse search library)
   - `BoardConnector` (curved/elbow/straight arrow lines between node edges or normalized pinpoint anchors inside an image, solid/dashed, color picker, editable label)
   - `InkStroke` (freehand vector annotation pen tool with color, stroke width, opacity, eraser/delete)
6. **External Drag-In & Export (PNG/JPG + Figma Bridge `.charkleboard`)**:
   - Dropping external files onto the canvas ingests them into Inbox and inserts `assetRef` nodes at drop position.
   - Export modal supporting High-DPI PNG/JPG (1x/2x, include/hide annotations & palette strip) and **`.charkleboard` ZIP** bundle (lossless ≤4096px PNG tiles + SHA-256 + `originals/` native GIFs + `manifest.json` matching `Resources/FigmaPlugin/code.js` + inline Figma plugin install guide).

## Acceptance Criteria
- Users can create a moodboard from prompt, seed assets, colors, or selection, see live Agent Harness steps, swap images from the candidate pool, switch Auto Editorial ↔ Freeform with zero coordinate jump, create/edit all 5 node/annotation types, and undo/redo reliably.
- Server generates valid PNG/JPG exports and `.charkleboard` ZIP archives whose `manifest.json` passes automated schema & SHA-256 verification against `Resources/FigmaPlugin/code.js` expectations.
- `cd web && npm run typecheck && npm test && npm run build` all pass.
