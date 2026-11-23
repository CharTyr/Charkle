# Implementation Plan: M3 — Dual-Mode Moodboard Studio, Curator Pool & Figma Bridge

1. [ ] Implement server `moodboard-curator.ts` & `moodboard-agent-harness.ts` + SSE streaming `/api/v1/boards/curate`, `/propose`, `/palette`, `/replacements`.
2. [ ] Implement server `moodboard-exporter.ts` (PNG/JPG 1x/2x) and `figma-bridge-exporter.ts` (`.charkleboard` ZIP + SHA-256 tiles + `originals/`) + export API endpoints.
3. [ ] Implement client `MoodboardsHomeView.tsx`, `MoodboardGeneratorModal.tsx` (4+1 tabs + live Agent Harness trace), and `CandidatePoolPanel.tsx`.
4. [ ] Implement client `MoodboardCanvasView.tsx` + `NodeViews.tsx` (`AssetRefNode`, `NoteNode`, `GroupFrameNode`, `PaletteStripNode`), `ConnectorLayer.tsx`, `InkLayer.tsx`, `CropEditorOverlay.tsx`, `FloatingToolDock.tsx`, `ExportModal.tsx` (PNG/JPG + `.charkleboard` + Figma plugin guide), and Undo/Redo store slice.
5. [ ] Wire drag-external-file-onto-canvas auto-ingest + pinpoint callout sheet + Auto Editorial drag-reorder ripple.
6. [ ] Write Vitest tests for `MoodboardCurator` (MMR diversity & replacements), `MoodboardAgentHarness` (offline & refinement), and `FigmaBridgeExporter` (ZIP integrity, tile split, SHA-256, `Resources/FigmaPlugin/code.js` contract).

## Validation Commands
```bash
cd web && npm run typecheck && npm test && npm run build
```
