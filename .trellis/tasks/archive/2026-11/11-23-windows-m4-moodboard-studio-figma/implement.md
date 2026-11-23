# Implementation Checklist: Windows M4

## Prerequisites
- `11-23-windows-m1-core-db-media-sync`, `11-23-windows-m2-gallery-nav-quicklook`, and `11-23-windows-m3-native-shelf-capture-winrt` completed and green on Windows.

## Ordered Steps
1. Implement `crates/charkle-core/src/layout/editorial.rs` + TS mirror + golden parity tests against macOS `EditorialLayoutSolver.swift`.
2. Implement `crates/charkle-core/src/intelligence/{curator,harness}.rs` (MMR scoring, 8-phase streaming events, candidate pool) + Tauri commands & event streaming.
3. Implement `ui/src/features/moodboard/` (`MoodboardsHome`, `GeneratorModal` + live `HarnessTrace`, `CandidatePoolPanel`, `DualModeCanvas` with Auto Editorial ↔ Freeform transition, Undo/Redo, drag-reorder ripple, smart alignment guides).
4. Implement all 5 element/annotation views & editors (`AssetRef` + crop, `Note`, `GroupFrame` + auto-reflow, `PaletteStrip`, `BoardConnector` + pinpoint callouts, `InkStroke`) and external file drop-to-canvas ingestion.
5. Implement `crates/charkle-core/src/export/{board_image,figma_bridge}.rs` + copy-to-clipboard + `.charkleboard` save dialog; verify output against `Resources/FigmaPlugin/code.js` via `scripts/test-figma-plugin.cjs`.
6. Run full Rust + Frontend tests and verify bidirectional macOS ↔ Windows moodboard `/.charkle/boards/<UUID>.json` round-trip.

## Validation Commands
```powershell
cd windows
cargo clippy --workspace --all-targets -- -D warnings
cargo test --workspace
cd ui
npm run typecheck
npm test
npm run build
node ..\..\scripts\test-figma-plugin.cjs
```
