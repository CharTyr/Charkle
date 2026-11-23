# Design: Windows M3 — `charkle-platform-win` Win32/WinRT Architecture

## COM & Threading Discipline
- **STA Worker Pool**: Both `IShellItemImageFactory` (`shell_thumb.rs`) and OLE `DoDragDrop` / `IDropTarget` (`drag_out.rs`, `shelf_win.rs`) require STA COM (`CoInitializeEx(None, COINIT_APARTMENTTHREADED | COINIT_DISABLE_OLE1DDE)` or `OleInitialize`). Never invoke them on Tokio's multi-threaded executor threads!
- **RAII Resource Safety**: Wrap `HBITMAP`, `HDC`, `HGLOBAL`, and COM tokens in dedicated Rust `Drop` structs so early error returns can never leak Windows GDI/USER handles.

## Top-Edge Drop Shelf State Machine (`shelf_win.rs`)
- **Geometry**: Fixed transparent window sized to `(max(980, compact_width) + shadow_margin, 580 + shadow_margin)` positioned at `((monitor.left + monitor.right - w)/2, monitor.top)`.
- **Hit-Testing**: React reports active visible capsule bounds `(x, y, w, h)` in logical DIPs via `set_shelf_hit_rect`; Rust converts by monitor DPI scale and answers `WM_NCHITTEST` with `HTTRANSPARENT` for all pixels outside the active rect (except the 3px × 320px top-center trigger strip).
- **OLE Drag Pre-Trigger**: Register an `IDropTarget` on the top hotstrip/shelf window (or monitor `VK_LBUTTON` + top-edge dwell) so dragging from any external app expands the shelf immediately while preserving foreground focus (`WS_EX_NOACTIVATE`).

## Multi-DPI Screenshot Capture (`capture.rs`)
- Enumerate monitors with `EnumDisplayMonitors` + `GetDpiForMonitor`.
- Capture per-monitor physical pixel buffers via DXGI Desktop Duplication (or `Windows.Graphics.Capture`), falling back to `BitBlt(SRCCOPY | CAPTUREBLT)` if DXGI is unavailable (e.g. RDP).
- Pass frozen frame via `charkle-media://localhost/capture-frame/{token}` to `capture.html` so zero base64 mega-strings cross IPC.
