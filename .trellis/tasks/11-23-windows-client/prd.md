# PRD: Charkle Windows Client (Tauri v2 + Pure Rust Core)

## 1. Goal & User Value

Build a native-grade **Windows desktop client** for Charkle inside `./windows/` using **Tauri v2 + pure Rust core (`charkle-core`, `charkle-platform-win`, `charkle-cli`) + React/TypeScript UI (WebView2)**, achieving full functional, visual, and `/.charkle/` sync parity with macOS Charkle v1.0.1 (~43k LOC).

Users get fast startup, a ~15–25 MB NSIS `.exe` installer, genuine Windows 11/10 desktop ergonomics (non-focus-stealing Top-Edge Drop Shelf, multi-DPI region screenshot capture, native OLE outbound file drag to Figma/Photoshop/Explorer, offline WinRT Chinese/English OCR, Windows Shell thumbnails, DPAPI secret vault), and **100% lossless bidirectional sync** with macOS Charkle over the same human-readable `/.charkle/` library format.

---

## 2. Confirmed Facts, Decisions & Codebase Anchors

- **Confirmed Architecture & Delivery Decisions**:
  - **Tech Stack**: Tauri v2 desktop shell + pure Rust core (no Node.js sidecar) + React 19 / Vite 6 / TypeScript / Tailwind CSS v4 / Zustand UI.
  - **Repository Layout**: Self-contained `./windows/` workspace inside the Charkle monorepo (`windows/README.md`), leaving macOS Swift targets (`Sources/`, `Tests/`, `Package.swift`) and the completed Web edition (`./web/`) untouched. Frontend `ui/src/api/` abstracts a pluggable `CharkleTransport` interface (`TauriTransport` for desktop; future `HttpTransport` ready if a thin Rust Web wrapper is ever added) and can reference `./web/packages/client` & `web/docs/` for UI/protocol parity without introducing a Node.js sidecar.
  - **Target OS, Arch & Packaging**: Windows 11 22H2+ primary (Mica/Acrylic floating chrome, native Snap Layouts via `WM_NCHITTEST`) + Windows 10 1903+ graceful fallback; `x86_64` (`x64`) architecture; standard NSIS `.exe` installer (Evergreen WebView2 bootstrapper, non-sandboxed so `charkle-cli.exe`, MCP stdio, and direct filesystem access work cleanly).
  - **Cross-Machine Workflow**: All planning artifacts are authored on macOS (without installing Rust on macOS); implementation, compilation (`cargo`/`tauri`), Win32/WinRT verification, and NSIS `.exe` packaging execute on the user's Windows `x64` machine.
- **macOS v1.0.1 & Monorepo Baseline Anchors**:
  - Core contracts: `Sources/CharkleCore/Contracts/CoreModels.swift`, `MediaModels.swift`, `MoodboardModels.swift`, `SyncModels.swift`, `CoreServiceProtocols.swift`.
  - Database & search: `Sources/CharkleCore/Database/LibraryDatabase.swift:34-160` (SQLite WAL + FTS5 schema `user_version = 2` + pinyin/initials + GitHub/social indexing), `Sources/CharkleCore/Database/SearchText.swift`.
  - Media & sync wire protocol: `Sources/CharkleCore/Media/ImageMetadataExtractor.swift`, `Sources/CharkleCore/Sync/SyncOperations.swift:3-150`, `DriveSyncEngine.swift`, `GDirectIntegration.swift`.
  - Canvas, Figma Bridge & External Agent: `Sources/CharkleCanvas/EditorialLayoutSolver.swift:31-150`, `FigmaBridgeExporter.swift`, `Resources/FigmaPlugin/code.js:37-120`, `Sources/CharkleCore/Intelligence/ExternalAgentPolicy.swift:7-100`, `Sources/CharkleCLI/CharkleCLI.swift`.
  - Visual, Motion, Shelf, Hotkeys & 9-Pane Settings: `Sources/CharkleApp/DesignSystem/CharkleTheme.swift:7-160`, `docs/MOTION_AND_ICON_SPEC.md`, `Sources/CharkleApp/Resources/Icons/` (49 original Duotone/Layered SVGs), `Sources/CharkleApp/Notch/NotchShelfState.swift`, `Sources/CharkleApp/Services/GlobalHotkeyManager.swift`, `Sources/CharkleApp/Views/Settings/CharkleSettingsTab.swift`.
  - Architecture & cross-platform specs: `.trellis/tasks/11-23-windows-client/research/windows-tauri-architecture.md`, `windows/README.md`, `web/docs/PARITY_SPEC.md`, and `web/docs/DELTA_SYNC_SPEC.md`.

---

## 3. Functional & Non-Functional Requirements

### FR-1: Rust Core, SQLite FTS5, All-Media Pipeline & 4-Mode `/.charkle/` Sync (M1)
- **FR-1.1**: Implement OS-agnostic `crates/charkle-core` with SQLite `user_version = 2` (`rusqlite` bundled WAL + FTS5 + Chinese full pinyin/initials + CIELAB color query + vector BLOBs + recursive folder tree + SmartFolder rule engine).
- **FR-1.2**: Support all 5 `CaptureInput` forms across all 8 `MediaKind` categories, `grid520`/`preview1400` thumbnail generation, CIELAB palette extraction, EXIF + AI generation prompt extraction, audio peak waveforms, configurable 2–100 GB LRU original cache with per-asset and per-board `pinnedOffline` protection, native `reqwest` rich resolvers (X/Threads/Bluesky with avatars & multi-attachments, GitHub OG/README, web bookmarks), and first-launch sample library seeding.
- **FR-1.3**: Implement `SwiftWireCodec` (Cocoa epoch floats `978_307_200.0`, uppercase UUIDs, Base64 `Data`, Swift keyed enums, Base64 JSON fragment `SyncFields`, HLC + LWW + tag tombstones) and `DriveSyncEngine` across all 4 macOS transport modes (`directAPIWithGDirect` Google Drive v3 OAuth + shared folder URL/ID + optional Windows `gdirect.exe`, `webDAV`, Windows mounted drive/folder `G:\`/`rclone`/WinFsp, `localOnly`) + `InMemoryDriveTransport` + lossless `StorageMigration`, sanitizing Windows-reserved filenames on local projection without breaking logical metadata.

### FR-2: Tauri IPC Shell, Gallery-First UI, Nav, Inbox & Full-Media Quick Look (M2)
- **FR-2.1**: Wire Tauri v2 commands, event broadcasting, zero-copy `charkle-media://` protocol with HTTP `206 Partial Content` `Range` streaming, Win11 Mica + `WM_NCHITTEST` Snap Layout titlebar (with Win10 1903+ fallback), and pluggable frontend `CharkleTransport`.
- **FR-2.2**: Implement Gallery-First design tokens (Light `#F6F6F5` / Dark `#141517`, neutral cards, restrained floating glass/acrylic chrome, Kubai Tip 004 concentric corners, Tip 011 easing curves, all 49 original SVGs) and 4 Zustand domain stores.
- **FR-2.3**: Deliver Sidebar (system views, live Inbox badge, nested `FolderTree` + hierarchy menus + drag-reorder/re-parent + customization popover, Smart Folders, Tags), Top Floating Visual Filter Capsule, all 3 virtualized Gallery layouts (Vertical Masonry, Horizontal Justified, Filmstrip), marquee multi-select + floating `BatchActionPill`, Inbox Triage (`1–9` + AI suggestion + Inbox Zero), `Ctrl+J` Jump Anywhere, user-reorderable Inspector cards (with EXIF/AI prompt viewer, palette, similar assets), and `Space` Full-Media Quick Look across all 8 media kinds (incl. original long-strip scroll & animation preview, PDF, Markdown/GitHub README, Social post carousel, Audio waveform, Three.js 3D viewer).

### FR-3: Windows-Native Desktop Soul — Top-Edge Drop Shelf, Capture, OLE Drag-Out & WinRT (M3)
- **FR-3.1**: Implement `charkle-platform-win` concrete services behind `charkle-core` traits: Windows Credential Manager / DPAPI `SecretVault` (zero plaintext secrets), offline WinRT `Windows.Media.Ocr` (Chinese/English with graceful missing-pack diagnostics), STA COM `IShellItemImageFactory` Shell thumbnails (with strict RAII `HBITMAP` cleanup for PSD/AI/PDF/HEIC/video/3D), and Win32 `GetDriveTypeW`/`GetVolumeInformationW` mount verification.
- **FR-3.2**: Implement transparent, non-activating **Top-Edge Drop Shelf** (`WS_EX_TOPMOST | WS_EX_TOOLWINDOW | WS_EX_NOACTIVATE`, fixed oversized HWND anchored top-center, dynamic `WM_NCHITTEST` click-through outside visible capsule, 2–3px top-edge drag hotstrip + OLE `IDropTarget`), supporting both Compact Shelf (drop well, Inbox/Folder/Active Moodboard routing, clipboard X/URL hint, recent strip) and Expanded Full-Waterfall Shelf (multi-column masonry, marquee select, drag-out).
- **FR-3.3**: Implement native OLE outbound file drag (`DoDragDrop` with `CF_HDROP` + thumbnail preview) from Gallery, Inspector, Shelf, and Moodboard directly into Figma Desktop, Photoshop, and Windows Explorer.
- **FR-3.4**: Implement global hotkeys (`Alt+Shift+A` multi-DPI DXGI/`Windows.Graphics.Capture` fullscreen region capture overlay with loupe, `Alt+Shift+S` toggle/pin Top-Edge Drop Shelf, `Alt+Shift+V` quick clipboard collect), `AddClipboardFormatListener`, System Tray menu, optional launch-at-login, single-instance guard, and `charkle://` deep links.

### FR-4: Dual-Mode Moodboard Studio, Agent Curator & Lossless Figma Bridge (M4)
- **FR-4.1**: Port deterministic `EditorialLayoutSolver` (`balanced`, `magazine` w/ 2-col Hero span, `compact`, `reflowNodesInsideGroupFrame`), Rust `MoodboardCurator` (MMR diversity), and 8-phase streaming `MoodboardAgentHarness` with 20–40 Candidate Replacement Pool (1-click in-place swap & drag-add).
- **FR-4.2**: Deliver Moodboards Home, 4+1 Generator modal + live harness trace, Auto Editorial ↔ zero-jump Freeform Infinite Canvas (zoom/pan, smart alignment guides, rotate/flip/lock/z-index, non-destructive crop, multi-step Undo/Redo, Kubai 005 drag-reorder ripple), all 5 element/annotation types (`assetRef`, 5-style `note`, 6-tint `groupFrame` w/ child move & auto-reflow, `paletteStrip`, `BoardConnector` w/ pinpoint callouts, `InkStroke`), and external Explorer file drop-to-canvas auto-ingestion.
- **FR-4.3**: Implement Rust high-DPI PNG/JPG `BoardImageExporter` (+ clipboard copy) and offline lossless `.charkleboard` ZIP `FigmaBridgeExporter` (≤4096×4096 PNG tiles + SHA-256 + `originals/*.gif`) validated against `Resources/FigmaPlugin/code.js`.

### FR-5: Hybrid AI, TypeSafe Jev, 9-Pane Settings, Native `charkle-cli.exe` / MCP & NSIS Release (M5)
- **FR-5.1**: Implement all 4 `AIProviderConfig` modes (`disabled`, `chatGPTSubscription`, `gemini`, `openAICompatible` across Chat Completions / Anthropic Messages / OpenAI Responses) + `CloudAIUsageTracker` + DPAPI key storage, plus experimental TypeSafe System One (Jev) visual grounding sidecar with graceful local fallback.
- **FR-5.2**: Implement centered **9-pane Settings Overlay** across 4 sections matching `CharkleSettingsTab.swift` (adapting `刘海浮窗` → `顶部悬浮窗`, including Lossless Storage Migration Wizard and WinRT OCR diagnostics) and skippable **Onboarding Studio**.
- **FR-5.3**: Deliver native `charkle-cli.exe` (`mcp` stdio JSON-RPC 2.0 + CLI commands) and 14-tool `ExternalAgentService` honoring independent `mcpEnabled`/`cliEnabled` switches, `readOnly`/`readWriteOrganize` policy (**permanent delete strictly forbidden**), contact-sheet rendering, and live `Local\CharkleLibraryChanged` wake refresh into the running desktop app.
- **FR-5.4**: Complete Kubai motion & accessibility polish (`prefers-reduced-motion` `150ms` fade, `prefers-reduced-transparency` / Windows Transparency Effects Off solid fallback), cross-platform macOS ↔ Windows sync QA, `x64` NSIS `.exe` bundling (including `charkle-cli.exe`), and `.trellis/spec/` updates.

---

## 4. Child Task Map & Execution Order

| Order | Child Task | Deliverable | Depends On |
| :--- | :--- | :--- | :--- |
| 1 | `11-23-windows-m1-core-db-media-sync` | `./windows/` Cargo workspace, `charkle-core` models + `SwiftWireCodec`, SQLite FTS5/pinyin DB, 8-kind `MediaPipeline` + EXIF/AI prompt + rich resolvers, 4-mode `DriveSyncEngine` + migration | None |
| 2 | `11-23-windows-m2-gallery-nav-quicklook` | Tauri v2 IPC + zero-copy `charkle-media://` Range streaming + Win11 Mica/Snap titlebar, pluggable `CharkleTransport`, Gallery-First UI (3 modes, Folders/SmartFolders, Inbox `1–9`, `Ctrl+J`, reorderable Inspector, 8-kind QuickLook) | M1 |
| 3 | `11-23-windows-m3-native-shelf-capture-winrt` | `charkle-platform-win`: Top-Edge Drop Shelf (Compact + Full-Waterfall, non-activating), OLE `CF_HDROP` drag-out, `Alt+Shift+A/S/V` + multi-DPI capture + clipboard, WinRT OCR, Shell thumbnails, DPAPI vault, Tray & `charkle://` | M1, M2 |
| 4 | `11-23-windows-m4-moodboard-studio-figma` | `EditorialLayoutSolver`, MMR `MoodboardCurator` + 8-phase Agent Harness, Candidate Pool, Dual-Mode Auto↔Freeform canvas (5 element/annotation types, Undo/Redo), PNG export & `.charkleboard` Figma Bridge | M1, M2, M3 |
| 5 | `11-23-windows-m5-ai-settings-cli-mcp-release` | 4-mode Cloud AI + Usage Tracker, TypeSafe Jev sidecar, 9-pane Settings + Onboarding Studio, `charkle-cli.exe` + 14-tool MCP/CLI service, motion/a11y polish, macOS↔Windows sync QA, `x64` NSIS `.exe` release & spec updates | M1–M4 |

---

## 5. Explicit Out of Scope & Constraints

- Modifying or breaking macOS Swift targets (`Sources/`, `Tests/`, `Package.swift`) or the completed Web edition (`./web/`).
- Bundling a Node.js sidecar inside the Windows desktop app (Windows uses a pure Rust core).
- Multi-tenant cloud SaaS auth/billing (remains Local-First private library).
- Legacy Windows 7/8, 32-bit x86, ARM64 Windows bundles, and Microsoft Store MSIX sandboxing.
- Installing Rust or running Windows builds on the current macOS host (implementation & builds run on the user's Windows `x64` machine).

---

## 6. Cross-Child Acceptance Criteria

1. `cargo fmt --all -- --check`, `cargo clippy --workspace --all-targets -- -D warnings`, `cargo test --workspace`, and `cd windows/ui && npm run typecheck && npm test && npm run build` all pass cleanly on the Windows `x64` machine.
2. First launch on Windows 11 (and Windows 10 1903+ fallback) seeds the sample library cleanly in both Light (`#F6F6F5`) and Dark (`#141517`) modes with zero console/runtime errors, native Snap Layouts on the custom maximize button, and full 3-mode gallery, Chinese pinyin + CIELAB filtering, Inbox `1–9`, `Ctrl+J`, reorderable Inspector (incl. EXIF/AI prompts), and 8-kind Quick Look (incl. HTTP `Range` video seeking & long-strip scrolling).
3. Dragging external images/files to the top-center monitor edge springs open the Top-Edge Drop Shelf without stealing focus and ingests to Inbox/Folder/Active Moodboard; dragging assets out delivers real local files via OLE `CF_HDROP` into Explorer and Figma Desktop/Photoshop; `Alt+Shift+A` captures crisp multi-DPI crops; WinRT offline OCR indexes zh/en text; Shell thumbnails render PSD/PDF/video with zero GDI handle leaks; all secrets persist exclusively in DPAPI/Credential Manager.
4. Generating a moodboard via any 4+1 entry streams Agent Harness phases, supports 1-click candidate replacement, zero-jump Auto Editorial ↔ Freeform editing across all 5 element/annotation types with Undo/Redo, high-DPI PNG export, and `.charkleboard` ZIP export verified against `Resources/FigmaPlugin/code.js` (`scripts/test-figma-plugin.cjs`).
5. A real `/.charkle/` library (Google Drive / WebDAV / Local Folder) syncs bidirectionally and losslessly between macOS Charkle v1.0.1 and Windows Charkle (covering assets, nested folders, tags, remote renames, and dual-mode moodboards).
6. All 9 Settings panes + Onboarding Studio work cleanly; `charkle-cli.exe mcp` and CLI subcommands enforce independent `mcpEnabled`/`cliEnabled` + `readOnly`/`readWriteOrganize` policy (never allowing permanent deletion) and live-refresh the running desktop app on writes.
7. `npm run tauri build -- --bundles nsis` produces an `x64` NSIS `.exe` installer that installs, runs, and uninstalls cleanly while leaving macOS `Sources/`, `Tests/`, and `Package.swift` untouched.
