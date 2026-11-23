# Charkle for Windows (Planned)

Native-grade **Windows desktop client** for Charkle built with **Tauri v2 + pure Rust Core + React UI**, targeting full feature, visual, and lossless bidirectional `/.charkle/` sync parity with Charkle for macOS and Charkle Web.

## Planned Workspace Architecture

```text
windows/
├── Cargo.toml                # Cargo workspace root
├── crates/
│   ├── charkle-core/         # Pure Rust core: SQLite WAL+FTS5+pinyin, media pipeline, EXIF/AI prompt, sync engine, AI & MCP service
│   └── charkle-cli/          # Standalone charkle-cli.exe (CLI subcommands + MCP stdio)
├── src-tauri/                # Tauri v2 shell + windows-rs Win32/WinRT native bridge + NSIS bundler
└── ui/                       # React + TypeScript + Vite frontend (pluggable CharkleTransport)
```

## Target Platform & Native Counterparts

- **Target OS**: Windows 11 22H2+ primary (x64, Mica/Acrylic floating chrome, Snap Layouts), with graceful Windows 10 1903+ fallback; distributed via standard NSIS `.exe` installer.
- **Top-Edge Drop Shelf**: Frameless, always-on-top, non-activating (`WS_EX_TOPMOST | WS_EX_TOOLWINDOW | WS_EX_NOACTIVATE`) shelf with Compact and Full-Waterfall modes.
- **Native System Integration**:
  - Offline OCR via WinRT `Windows.Media.Ocr.OcrEngine`
  - System thumbnails (PSD/AI/PDF/HEIC/video/3D) via Shell `IShellItemImageFactory`
  - Credential storage via Windows Credential Manager / DPAPI
  - Outbound drag-and-drop to Figma / Photoshop / Explorer via OLE `DoDragDrop` (`CF_HDROP`)
  - Global hotkeys (`Alt+Shift+A/S/V`) & region capture via `Windows.Graphics.Capture` / DXGI
- **Sync Backends**: Google Drive API v3 (+ optional Windows `gdirect.exe`), WebDAV, Windows Mounted Drive/Folder (`G:\` / `rclone` / WinFsp), and Local Only.

## Milestone Roadmap

1. **M1 — Core, DB, Media & Sync**: Rust workspace (`charkle-core`), SQLite WAL/FTS5/pinyin/CIELAB/vectors, 8-kind media pipeline + EXIF/AI prompt parser + social/web resolvers, `/.charkle/` wire-compatible sync engine.
2. **M2 — Gallery, Navigation & Quick Look**: Tauri v2 + React Gallery-First UI, 3 gallery layouts, nested folders & Smart Folders, Inbox Triage (`1–9`), `Ctrl+J` Jump Anywhere, reorderable Inspector cards, Full-Media Quick Look.
3. **M3 — Native Shelf, Capture & WinRT**: Top-Edge Drop Shelf, global hotkeys, region screenshot capture, clipboard collector, OLE outbound file drag, WinRT OCR, Shell thumbnails, tray & deep links.
4. **M4 — Moodboard Studio & Figma Bridge**: Moodboards Home, 4+1 Generator & Agent Harness, Dual-Mode Auto Editorial ↔ Freeform canvas, high-DPI export, lossless `.charkleboard` ZIP Figma Bridge.
5. **M5 — Hybrid AI, Settings, CLI/MCP & Installer**: Cloud AI providers, 9-pane Settings & Onboarding, `charkle-cli.exe` + 14-tool MCP service, NSIS packaging & cross-platform parity verification.
