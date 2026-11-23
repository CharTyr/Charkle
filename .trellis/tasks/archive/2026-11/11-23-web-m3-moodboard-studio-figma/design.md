# Design: M3 — Dual-Mode Moodboard Studio, Curator Pool & Figma Bridge

## Server Modules
- `intelligence/moodboard-curator.ts`: Multi-signal scorer (FTS5 rank + tag match + CIELAB ΔE harmony + visual fingerprint cosine similarity + optional Cloud embedding) + Greedy MMR diversity reranker (`lambda = 0.72`) + palette extractor (`extractBoardPalette`) + `replacementCandidates`.
- `intelligence/moodboard-agent-harness.ts`: Multi-phase orchestrator emitting `MoodboardAgentStep` events over SSE; uses Cloud AI (when configured) for semantic planning, section drafting, visual contact-sheet critique, and repair, with deterministic offline fallback (`fallbackOffline`).
- `export/moodboard-exporter.ts`: Renders board layout (Auto Editorial or Freeform), images (with normalized crops, rotation, flips), styled notes, group frames, palette strips, Bezier connectors, and ink strokes via SVG + `sharp` compositing at 1x/2x DPI.
- `export/figma-bridge-exporter.ts`: Exact port of `FigmaBridgeExporter.swift` using `sharp` + `jszip` + Node `crypto` SHA-256; splits images >4096px into lossless PNG tiles, preserves raw files in `originals/` (supporting native FigJam GIFs), emits `manifest.json` matching `Resources/FigmaPlugin/code.js`.

## Client Canvas Architecture
- `MoodboardCanvasView.tsx`:
  - Floating bottom Liquid Glass Tool Dock (`Select`, `Pan`, `Add Note`, `Add Frame`, `Connector`, `Ink Pen`, `Palette Strip`, `Auto↔Freeform` segmented toggle, `Undo/Redo`, `Export`).
  - Dual render pipeline sharing identical `NodeCard` components so switching Auto Editorial ↔ Freeform smoothly animates transforms from `EditorialLayoutSolver.solve()` frames to stored `node.frame`.
  - Dedicated SVG overlay in world coordinates for `BoardConnector` (hit-testing, arrowhead markers, midpoint label editing, pinpoint dots) and `InkStroke` (pointer capture + quadratic smoothing).
  - Immutable `MoodboardDocument` history stack (`past[]`, `present`, `future[]`, debounced auto-save to `PUT /api/v1/boards/:id`).
