# Windows Client Guidelines (Tauri v2 · Rust · React 19)

> Architectural & coding standards for `./windows/` (`charkle-core`, `charkle-platform-win`, `charkle-cli`, `src-tauri`, `ui`).  
> **Windows UI & Component Spec**: See [Charkle Windows Fluent 2 设计与组件规范](./fluent2-design-system.md) for the canonical Windows 11 Fluent 2 / WinUI 3 desktop layout, Token system, `@base-ui/react` + `motion/react` + `@fluentui/react-icons` architecture, and motion contracts.

---

## 1. Crate & Directory Architecture

- `windows/crates/charkle-core`: Pure OS-agnostic Rust domain core (SQLite v2 + FTS5 + Pinyin, 8-kind Media Pipeline, EXIF/A1111/ComfyUI metadata, CIELAB k-means, `/.charkle/` CRDT HLC Sync + Storage Migration, `EditorialLayoutSolver`, Hybrid Cloud AI + ChatGPT PKCE OAuth + Usage Tracker + TypeSafe Jev Visual Grounding + Contact Sheet, `BoardImageExporter` + `FigmaBridgeExporter`, 14-tool `CharkleExternalAgentService`). Zero Win32/Tauri imports allowed.
- `windows/crates/charkle-platform-win`: Concrete Windows 10/11 native implementations of `charkle-core` OS seams + desktop UX:
  - `windowing.rs`: Win11 22H2+ Mica (`DWMWA_SYSTEMBACKDROP_TYPE`), Win10/Transparency-Off solid fallback, custom frameless Snap Layouts (`WM_NCHITTEST` -> `HTMAXBUTTON`).
  - `vault.rs`: Windows Credential Manager + DPAPI (`SecretVault`). **Zero plaintext secrets on disk.**
  - `ocr.rs`: Offline WinRT `Windows.Media.Ocr.OcrEngine` (`NativeOcrProvider`).
  - `shell_thumb.rs`: Dedicated STA COM thread (`IShellItemImageFactory`) for PDF/PSD/3D/Office thumbnails with GDI `DeleteObject` cleanup verified over 500 calls.
  - `shelf_win.rs` / `drag_out.rs` / `capture.rs` / `clipboard.rs`: Non-activating Top-Edge Drop Shelf (`WS_EX_NOACTIVATE`), OLE `DoDragDrop` (`CF_HDROP`), multi-DPI DXGI/GDI screen capture, `AddClipboardFormatListener` + `CF_DIB` writer.
  - `wake.rs`: Cross-process Win32 named event (`Local\CharkleLibraryChanged`) + `.wake` file fallback bridging headless `charkle-cli.exe` writes to live desktop UI refreshes.
- `windows/crates/charkle-cli`: Standalone `charkle-cli.exe` exposing `mcp` (JSON-RPC 2.0 stdio) and CLI subcommands directly over SQLite `WAL` mode, enforcing `external-agent.json` policy (`mcpEnabled`, `cliEnabled`, `readOnly` / `readWriteOrganize`, soft-trash only).
- `windows/src-tauri`: Thin Tauri v2 host registering typed IPC commands (`commands/*.rs`), `charkle-media://` zero-copy HTTP 206 Range media protocol, tray/hotkeys/autostart/single-instance/`charkle://` deep links, and NSIS bundling.
- `windows/ui`: React 19 + TypeScript + Tailwind v4 + Zustand UI implementing Windows 11 Fluent 2 desktop design tokens ([`fluent2-design-system.md`](./fluent2-design-system.md)) alongside `DESIGN.md` brand invariants, zero native `<select>`, zero `transition: all`, and dual-transport (`TauriTransport` / `InMemoryMockTransport`).

---

## 2. Non-Negotiable Windows Contracts

1. **Zero Base64 Media Transfer Over IPC**: Images, videos, PDFs, audio, and 3D assets MUST stream via `http://charkle-media.localhost/thumb/<uuid>/<tier>` or `/original/<uuid>` with HTTP `206 Partial Content` support — never Base64-encoded inside JSON IPC responses.
2. **Credential Storage Invariant**: Cloud AI API keys (`ai.provider.api_key.v1`), ChatGPT OAuth tokens (`ai.chatgpt.connection.v1`), TypeSafe keys (`ai.typesafe.api_key.v1`), Google OAuth tokens, and WebDAV passwords MUST reside exclusively in `WinCredentialVault` (DPAPI / Credential Manager).
3. **External Agent Safety**: `charkle-cli.exe` MUST check `ExternalAgentConfigStore::load(&data_dir)` dynamically on every tool call, keep `mcpEnabled` and `cliEnabled` independent, and NEVER expose permanent deletion.
4. **Reduced Motion & Transparency Fallbacks**: Every floating Acrylic / translucent surface (`.win-acrylic`, `.win-acrylic-header`, `.win-acrylic-dark`, and legacy `.charkle-glass` during migration) MUST disable `backdrop-filter` and degrade to crisp high-contrast neutral solid surfaces under both `@media (prefers-reduced-transparency: reduce)` and `:root[data-backdrop="solidFallback"]` (Windows 10 / Transparency Effects Off).
5. **Lossless `SocialPlatform` Wire Tolerance & Decoupled Zero-Download Gating**: `SocialPlatform` (`windows/crates/charkle-core/src/models/core.rs`) MUST preserve unrecognized future platform strings losslessly via `SocialPlatform::Unknown(String)` custom `Serialize`/`Deserialize` so `/.charkle/` sync shards never fail `SyncFields::merge` or roll back `apply_op_shard`. Keep zero-download video bookmarking (`prefers_zero_download_video_bookmark()` for `Youtube | Bilibili | Douyin`) decoupled from 16:9 horizontal layout (`is_video_platform()` for `Youtube | Bilibili`), and normalize `application/octet-stream` VOD chunks with ISO BMFF `ftyp` or Douyin VOD hosts to `video/mp4`.
6. **Three-Way Browser Extension Packaging Parity**: `Resources/BrowserExtension/` (excluding `tests/`), `windows/src-tauri/resources/BrowserExtension/`, and `windows/src-tauri/tauri.conf.json` (`bundle.resources` entries using `"resources/BrowserExtension/<rel>": "Resources/BrowserExtension/<rel>"`) MUST stay 1:1 byte-identical and completely registered; classic scripts (`content.js`, `page-bridge.js`, `x-bridge-loader.js`) MUST stay `import`/`export`-free and pass `node --check`, and `lib/url-detect.js` MUST stay self-contained for Safari's classic SW bundler.

---

## 3. Release Packaging & Verification Gate

- NSIS per-user `x64` installer (`tauri.conf.json` + `tauri.nsis.conf.json` via `windows/scripts/build-release-nsis.ps1`) bundles `Charkle.exe`, `charkle-cli.exe`, `Resources/BrowserExtension/*`, `Resources/FigmaPlugin/*`, and WebView2 `embedBootstrapper`.
- Mandatory pre-commit gate:
  ```powershell
  pwsh -NoProfile -ExecutionPolicy Bypass -File windows/scripts/verify-windows.ps1
  node --test Resources/BrowserExtension/tests/extension.test.mjs
  node scripts/test-figma-plugin.cjs
  ```
