# Design: Windows M2 — Tauri IPC, Zero-Copy Media Protocol & Gallery UI

## IPC & Zero-Copy Media Architecture
- **Command Layer (`src-tauri/src/commands/`)**: Thin wrappers grouped by domain (`assets.rs`, `folders.rs`, `media.rs`, `sync.rs`, `query.rs`), serializing Rust DTOs directly to JSON with structured error codes.
- **Zero-Copy Media Protocol (`src-tauri/src/protocol.rs`)**: Registers `charkle-media://` via `tauri::Builder::register_uri_scheme_protocol`. Maps `charkle-media://localhost/thumb/{id}/{tier}` and `charkle-media://localhost/original/{id}` straight to disk streams with `Accept-Ranges: bytes`, `Content-Range`, `206 Partial Content`, `ETag`, and `Cache-Control` headers — preventing WebView2 IPC memory spikes on 4K videos and large GIFs.
- **Window Backdrop (`charkle-platform-win/src/windowing.rs`)**: Reads Windows build via `RtlGetVersion`. Build ≥ 22621 applies `DWMWA_SYSTEMBACKDROP_TYPE = DWMSBT_MAINWINDOW` + dark titlebar sync + `WM_NCHITTEST` `HTMAXBUTTON` rect hit-testing for Snap Layouts; older Win10 builds degrade cleanly to solid neutral chrome.

## Frontend Architecture (`./windows/ui/`)
- **`CharkleTransport` Seam (`src/api/`)**: Every store and component calls `transport.*` — never raw `@tauri-apps/api` directly inside feature views — preserving clean Vitest mocking and optional future Web `HttpTransport`.
- **Virtualization**: Vertical Masonry and Horizontal Justified Masonry compute pure O(N) item rects with `ResizeObserver` width tracking and viewport windowing (`scrollTop ± 1.5 * viewportHeight`) to stay locked at 60/120 FPS up to 50k items.
- **Quick Look Continuity**: Captures source card `DOMRect` on `Space`/double-click to animate hero expansion with `--ease-spring`, collapsing to `150ms` opacity fade when `prefers-reduced-motion` is active.
