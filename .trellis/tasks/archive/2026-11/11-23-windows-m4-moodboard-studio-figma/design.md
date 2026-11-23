# Design: Windows M4 — Moodboard Canvas Engine & Exporters

## Shared Deterministic Layout & Undo Architecture
- `crates/charkle-core/src/layout/editorial.rs` mirrors `EditorialLayoutSolver.swift` (`balanced`, `magazine` w/ 3-hero quota, `compact`, `reflow_nodes_inside_group_frame`). A thin TypeScript mirror in `ui/src/features/moodboard/editorial.ts` enables 60/120 FPS interactive drag-reorder preview without IPC round-trips, verified against the same golden JSON layout fixtures.
- Freeform stage renders nodes via GPU-composited `transform: translate3d(x, y, 0) scale(z)` inside a viewport-culled world container, with a crisp SVG overlay layer for `BoardConnector` (cubic Bezier / orthogonal elbow / straight + pinpoint normalized anchors) and `InkStroke` (smoothed quadratic paths).
- Immutable snapshot Undo/Redo ring buffer in `moodboardStore` (`Ctrl+Z` / `Ctrl+Y` / `Ctrl+Shift+Z`) debounces continuous drags/strokes into atomic undo entries and persists mutated `MoodboardDocument` snapshots to `charkle-core` (generating incremental `BoardChanges` sync ops).

## Exporters (`crates/charkle-core/src/export/`)
- `board_image.rs`: Composites full-res images, crops, notes, frames, palette strip, connectors, and ink strokes via `image` + `tiny-skia` / `resvg` at 1×/2× DPI.
- `figma_bridge.rs`: Tiles high-res images along exact `4096×4096` grid boundaries (`x % 4096 == 0`, `y % 4096 == 0`), computes lowercase SHA-256 per PNG tile and animated GIF original, writes `manifest.json` matching `Resources/FigmaPlugin/code.js:37-120`, and bundles into `.charkleboard` ZIP.
