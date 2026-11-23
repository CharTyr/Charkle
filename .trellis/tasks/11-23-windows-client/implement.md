# Implementation Plan: Charkle Windows Client (Tauri v2 + Pure Rust Core)

## Execution Strategy & Cross-Machine Handoff

- **Planning Phase (Complete on macOS)**: All PRDs, technical designs, architecture research, and M1–M5 child tasks are authored here without installing Rust on macOS.
- **Implementation Phase (On Windows x64 Machine)**:
  1. Sync/pull the repository onto the Windows 10/11 `x64` machine.
  2. Complete the one-time Windows toolchain setup in `research/windows-tauri-architecture.md` §5 (Visual Studio 2022 C++ Build Tools, `rustup` `x86_64-pc-windows-msvc`, Node.js 22+, WebView2 runtime).
  3. Execute the 5 independently verifiable child tasks sequentially (`M1` → `M5`), running `python ./.trellis/scripts/task.py start <child-dir>` for each child, passing every build/test/runtime gate before moving on.
  4. Never modify macOS Swift targets (`Sources/`, `Tests/`, `Package.swift`), except optionally running macOS `swift test` to export golden `/.charkle/` sync fixture files for round-trip parity verification.

---

## Ordered Milestone Checklist

### Milestone 1 (`11-23-windows-m1-core-db-media-sync`) — Rust Core, SQLite FTS5, Media Pipeline & `/.charkle/` Sync
- [ ] Scaffold `./windows/` Cargo workspace (`crates/charkle-core`, `crates/charkle-platform-win` stubs, `crates/charkle-cli` stub, `src-tauri` minimal shell) + `scripts/sync-icons.mjs` + `scripts/verify-windows.ps1`.
- [ ] Implement all domain models (`CoreModels`, `MediaModels`, `MoodboardModels`, `SyncModels`, `SettingsModels`) and `SwiftWireCodec` with golden macOS fixture round-trip unit tests.
- [ ] Implement `LibraryDatabase` (`rusqlite` bundled WAL + FTS5 + `pinyin` full/initials + CIELAB color query + vector BLOBs + recursive folder tree + sync ops/clocks).
- [ ] Implement `MediaPipeline` (8 `MediaKind` detectors, `grid520`/`preview1400` thumbnails, CIELAB palette extraction, EXIF/AI prompt metadata parser, audio waveform peaks, LRU original cache + offline pin protection, X/Threads/Bluesky/GitHub/WebBookmark resolvers, `SampleLibrarySeeder`).
- [ ] Implement `DriveSyncEngine` + 5 transports (`DirectAPITransport` Google Drive v3 + PKCE OAuth + shared folder URL/ID + optional `gdirect.exe` IP override, `WebDAVTransport`, `MountedVolumeTransport` with Windows drive check, `LocalFolderTransport`, `InMemoryDriveTransport`) + lossless `StorageMigration`.
- **Gate**: `cargo test --workspace` green (including multi-device sync conflict, rename-by-driveFileID, and macOS Swift wire round-trip tests).

### Milestone 2 (`11-23-windows-m2-gallery-nav-quicklook`) — Tauri IPC Shell, Gallery-First UI, Nav, Inbox & Quick Look
- [ ] Wire `src-tauri/` commands (`CharkleEngineProtocol` surface), live event emitter, zero-copy `charkle-media://` protocol with HTTP `Range` support, custom frameless titlebar with Win11 Mica + `WM_NCHITTEST` Snap Layouts + Win10 fallback.
- [ ] Scaffold `./windows/ui/` (React 19 + Vite 6 + TS + Tailwind v4 + Zustand), pluggable `CharkleTransport` (`TauriTransport`), Gallery-First Light/Dark design tokens, calibrated motion tokens + reduced-motion/transparency fallbacks, and synced 49 original SVGs.
- [ ] Implement `Sidebar` (All Items, Inbox badge, Moodboards, Untagged, Recent, Trash, nested `FolderTree` + hierarchy menus + drag-reorder/re-parent + customization popover, `SmartFolders` + rule editor, Tags).
- [ ] Implement `TopFilterCapsule` (FTS5/pinyin live search, semantic search toggle, multi-select `MediaKind`, CIELAB color + ΔE slider, `AspectShape`, rating, tags, offline pin, 6 sort orders, 3 layout switcher).
- [ ] Implement 3 gallery views (Virtualized Vertical Masonry, Horizontal Justified, Gallery Filmstrip), marquee box-select, floating `BatchActionPill`, Inbox Triage (`1–9` + AI suggestion + Inbox Zero), `Ctrl+J` Jump Anywhere, reorderable `Inspector` cards (with EXIF/AI prompt viewer, palette, similar assets), and `Space` Full-Media Quick Look (original long-strip & animation preview, Video, Audio waveform, PDF, Markdown/Code, GitHub README, Social post multi-attachment, Three.js 3D viewer).
- **Gate**: `cargo check --workspace`, `npm run typecheck`, `npm test`, `npm run build` green + live `npm run tauri dev` verification on Windows in Light & Dark modes.

### Milestone 3 (`11-23-windows-m3-native-shelf-capture-winrt`) — Windows Native Soul (Drop Shelf, Capture, OLE Drag-Out, WinRT OCR & Shell Thumbs)
- [ ] Implement `charkle-platform-win` native services: DPAPI/Credential Manager `SecretVault`, WinRT `Windows.Media.Ocr` offline Chinese/English OCR, STA COM `IShellItemImageFactory` Shell thumbnails (PSD/AI/PDF/HEIC/video/3D), and Win32 `GetDriveTypeW`/`GetVolumeInformationW` mount verification.
- [ ] Implement Top-Edge Drop Shelf (`shelf` Tauri window + `shelf_win.rs`): fixed oversized transparent `WS_EX_TOPMOST | WS_EX_TOOLWINDOW | WS_EX_NOACTIVATE` window, dynamic click-through, 3px top-edge drag hotstrip + OLE `IDropTarget`, Compact Shelf & Expanded Full-Waterfall Shelf (`shelf.html`), Inbox/Folder/Active Moodboard routing, clipboard X/URL hint.
- [ ] Implement outbound native OLE file drag (`DoDragDrop` with `CF_HDROP` + thumbnail preview) from Gallery, Inspector, Moodboard, and Full-Waterfall Shelf into Figma Desktop / Photoshop / Windows Explorer.
- [ ] Implement system-wide global hotkeys (`Alt+Shift+A` capture, `Alt+Shift+S` toggle shelf, `Alt+Shift+V` quick clipboard collect), multi-DPI `Windows.Graphics.Capture`/DXGI fullscreen snipping overlay (`capture.html`), clipboard listener (`AddClipboardFormatListener`), System Tray menu, launch-at-login, and `charkle://` deep link handler.
- **Gate**: Real Windows 10/11 verification of non-focus-stealing drag-to-top-edge expand, outbound file drag into Explorer/Figma, multi-DPI screenshot crop, offline WinRT OCR, Shell thumbnail generation, and DPAPI secret persistence.

### Milestone 4 (`11-23-windows-m4-moodboard-studio-figma`) — Dual-Mode Moodboard Studio, Agent Curator & Figma Bridge
- [ ] Port `EditorialLayoutSolver` (`balanced`, `magazine` w/ 2-col Hero span, `compact`, `reflowNodesInsideGroupFrame`) identically into Rust + shared TS preview helpers with deterministic parity tests against macOS output.
- [ ] Implement Rust `MoodboardCurator` (MMR diversity + multi-signal scoring) + `MoodboardAgentHarness` (8-phase live event streaming + refinement) + candidate replacement pool (20–40 ranked candidates).
- [ ] Implement `MoodboardsHome`, 4+1 Generator modal + live Agent Harness trace, right Candidate Replacement Pool (1-click in-place swap & drag-add), and Dual-Mode `MoodboardCanvas` (Auto Editorial ↔ zero-jump Freeform infinite canvas with pan/zoom, smart alignment guides, rotate/flip/lock/z-index, non-destructive crop, Undo/Redo, drag-reorder neighbor ripple).
- [ ] Support all 5 node/annotation types (`assetRef`, 5-style `note`, 6-tint `groupFrame` with child move & auto-reflow, `paletteStrip`, `BoardConnector` curved/elbow/straight w/ pinpoint callouts, `InkStroke` freehand pen) and external file drop directly onto canvas (auto-ingest Inbox + drop coordinates).
- [ ] Implement Rust high-DPI PNG/JPG `BoardImageExporter` and lossless `.charkleboard` ZIP `FigmaBridgeExporter` (≤4096px PNG tiles + SHA-256 + `originals/*.gif`), validated against `Resources/FigmaPlugin/code.js` and `scripts/test-figma-plugin.cjs`.
- **Gate**: `cargo test --workspace`, `npm run typecheck`, `npm test`, `node ../scripts/test-figma-plugin.cjs` pass + smooth Auto↔Freeform & export test on Windows.

### Milestone 5 (`11-23-windows-m5-ai-settings-cli-mcp-release`) — Hybrid AI, TypeSafe Jev, 9-Pane Settings, CLI/MCP & NSIS Release
- [ ] Implement `CloudAIProvider` (Disabled/Local, ChatGPT Subscription OAuth, Gemini, OpenAI-Compatible across Chat Completions / Anthropic Messages / OpenAI Responses) + `CloudAIUsageTracker` + DPAPI key storage.
- [ ] Implement experimental `TypeSafeSystemOneClient` & `VisualGroundingEngine` (focus crop, visual-match crop, auto clean-crop, subject palette, pinpoint callouts, hybrid semantic search, batch inbox triage, visual rerank) with graceful local fallback.
- [ ] Implement centered **9-pane `SettingsOverlay`** (4 sections matching `CharkleSettingsTab.swift`: 基础与存储 / 采集与操作 / 生态与智能 / 系统, with `顶部悬浮窗` replacing `刘海浮窗` + Lossless Storage Migration Wizard) and skippable **Onboarding Studio**.
- [ ] Implement native `charkle-cli.exe` (`mcp` stdio JSON-RPC 2.0 + CLI subcommands) + 14-tool `ExternalAgentService` honoring independent `mcpEnabled`/`cliEnabled` & `readOnly`/`readWriteOrganize` policy + live Windows event refresh into running desktop app.
- [ ] Finalize motion & accessibility polish, cross-platform macOS ↔ Windows `/.charkle/` sync E2E verification, build signed/unsigned `x64` NSIS `.exe` installer (`npm run tauri build`), and update `.trellis/spec/` with Windows Tauri/Rust conventions.
- **Gate**: Clean `x64` NSIS `.exe` installs & runs on Windows 11 (and Win10 fallback check), macOS ↔ Windows Google Drive/Local `/.charkle/` bidirectional sync passes, `charkle-cli.exe mcp` & CLI verified, existing macOS `swift test` untouched.

---

## Windows Validation Commands

```powershell
# 1. Sync original SVG icons from macOS resources
cd windows
node scripts/sync-icons.mjs

# 2. Rust core, platform, CLI & Tauri checks/tests
cargo fmt --all -- --check
cargo clippy --workspace --all-targets -- -D warnings
cargo test --workspace

# 3. Frontend typecheck, unit tests & production build
cd ui
npm run typecheck
npm test
npm run build

# 4. Run live Tauri v2 desktop app on Windows
npm run tauri dev

# 5. Build x64 NSIS .exe installer (M5 release gate)
npm run tauri build -- --bundles nsis

# 6. Validate exported .charkleboard compatibility with Figma Plugin
node ..\scripts\test-figma-plugin.cjs
```

---

## Risky Seams & Rollback Points

1. **Top-Edge Drop Shelf Click-Through & Focus Isolation (`shelf_win.rs`)**: Incorrect `WS_EX_TRANSPARENT` / `WS_EX_NOACTIVATE` handling can block clicks on maximized app titlebars (e.g. Chrome tabs) or steal focus mid-drag. Mitigation: keep collapsed hotstrip strictly 2–3px at `y = 0` center 320px and add instant `Alt+Shift+S` + tray toggle override.
2. **COM STA Threading & GDI Handle Leaks (`shell_thumb.rs`, `drag_out.rs`)**: Calling `IShellItemImageFactory` or `DoDragDrop` from Tokio MTA worker threads causes subtle COM failures; leaking `HBITMAP` hits Windows' 10,000 GDI handle cap. Mitigation: dedicated STA worker thread + RAII `Drop` guards around `HBITMAP` and `CoUninitialize`.
3. **Swift Wire Codec Subtlety (`wire/swift_codec.rs`)**: Any mismatch in Cocoa date epoch, Swift keyed-enum wrapping (`{"autoEditorial":{"_0":{...}}}`), or Base64 `SyncFields` fragments could corrupt a shared macOS `/.charkle/` library. Mitigation: mandatory macOS-generated golden fixture round-trip test gate in M1 before ever pointing at a real production Drive library.
4. **Rollback Boundary**: Every milestone is confined to `./windows/`; reverting any milestone leaves macOS `Sources/`, `Tests/`, and `Package.swift` completely untouched.
