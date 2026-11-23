# Implementation Checklist: Windows M3

## Prerequisites
- `11-23-windows-m2-gallery-nav-quicklook` completed and `npm run tauri dev` verified on Windows.

## Ordered Steps
1. Implement `charkle-platform-win/src/{vault,ocr,shell_thumb,mount}.rs` behind `charkle-core` traits + Windows unit/stress tests (incl. 500-iteration GDI handle leak check).
2. Implement `shelf_win.rs` + `ui/shelf.html` + `ui/src/features/shelf/` (fixed oversized transparent non-activating window, `WM_NCHITTEST` click-through, top-edge hotstrip + `IDropTarget`, Compact + Full-Waterfall Shelf).
3. Implement `drag_out.rs` (`DoDragDrop` + `CF_HDROP` + `IDragSourceHelper`) and hook outbound drag handlers into Gallery, Inspector, and Full-Waterfall Shelf.
4. Implement `capture.rs` + `ui/capture.html` (DXGI/`Windows.Graphics.Capture` + GDI fallback, multi-DPI virtual desktop crop overlay with loupe), `clipboard.rs` (`AddClipboardFormatListener`), and global hotkeys (`Alt+Shift+A/S/V`).
5. Wire System Tray, `tauri-plugin-autostart`, `tauri-plugin-single-instance`, and `charkle://` deep links in `src-tauri/src/main.rs`.
6. Run comprehensive manual + automated Windows verification checklist across Win11 (and Win10 fallback if available).

## Validation Commands
```powershell
cd windows
cargo clippy --workspace --all-targets -- -D warnings
cargo test --workspace
cd ui
npm run typecheck
npm test
npm run tauri dev
```
