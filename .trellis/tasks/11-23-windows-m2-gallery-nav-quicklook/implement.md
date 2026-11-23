# Implementation Checklist: Windows M2

## Prerequisites
- `11-23-windows-m1-core-db-media-sync` completed and `cargo test --workspace` green.

## Ordered Steps
1. Implement `src-tauri/src/{commands,protocol,events}.rs` and `charkle-platform-win/src/windowing.rs` (Win11 Mica, Win10 fallback, Snap Layout `WM_NCHITTEST`).
2. Scaffold `./windows/ui/` (React 19 + Vite 6 + TS + Tailwind v4 + Zustand + Vitest), run `scripts/sync-icons.mjs`, and implement `CharkleTheme` CSS tokens, Kubai motion utilities, `CharkleIcon`, and `TauriTransport`.
3. Build `AppShell` (custom Snap-aware titlebar + `Sidebar` with nested `FolderTree`, hierarchy menus, customization popover, `SmartFolderEditor`, Tags).
4. Build `TopFilterCapsule`, 3 virtualized gallery modes (`VerticalMasonry`, `HorizontalJustified`, `GalleryFilmstrip`), marquee multi-select, `BatchActionPill`, and `InboxTriageBar`.
5. Build `JumpAnywhere` (`Ctrl+J`), reorderable `Inspector` (with EXIF/AI prompts, palette, similar assets), and `QuickLookOverlay` (all 8 rich viewers incl. long-strip, animation controls, PDF, Markdown/GitHub, Social carousel, Audio waveform, Three.js 3D).
6. Run unit tests, typecheck, production Vite build, and live `npm run tauri dev` verification on Windows in Light & Dark modes.

## Validation Commands
```powershell
cd windows
cargo clippy --workspace --all-targets -- -D warnings
cargo test --workspace
cd ui
npm run typecheck
npm test
npm run build
npm run tauri dev
```
