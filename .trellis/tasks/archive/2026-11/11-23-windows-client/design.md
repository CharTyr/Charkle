# Technical Design: Charkle Windows Client (Tauri v2 + Pure Rust Core + React UI)

## 1. Architectural Overview & Directory Boundaries

The Windows client lives in a strictly self-contained `./windows/` workspace inside the Charkle monorepo (see `windows/README.md`), leaving macOS Swift targets (`Sources/`, `Tests/`, `Package.swift`) and the completed Web edition (`./web/`) untouched while reusing repo SVG icons (`Sources/CharkleApp/Resources/Icons/`), referencing `./web/packages/client` & `web/docs/` parity specs where helpful, and validating Figma exports against `Resources/FigmaPlugin/code.js`.

```text
windows/
├── Cargo.toml                         # Cargo workspace: charkle-core, charkle-platform-win, charkle-cli, src-tauri
├── rust-toolchain.toml                # stable (x86_64-pc-windows-msvc on Windows)
├── scripts/
│   ├── sync-icons.mjs                 # Copies & verifies 49 SVG icons from ../Sources/CharkleApp/Resources/Icons
│   └── verify-windows.ps1             # One-shot Windows build/test/bundle verification script
├── crates/
│   ├── charkle-core/                  # OS-agnostic deep core library (100% headless-testable!)
│   │   └── src/
│   │       ├── models/                # CoreModels, MediaModels, MoodboardModels, SyncModels, SettingsModels
│   │       ├── wire/                  # SwiftWireCodec (Cocoa dates, uppercase UUID, Base64, keyed enums)
│   │       ├── db/                    # LibraryDatabase (rusqlite WAL + FTS5 + pinyin + CIELAB + vectors)
│   │       ├── media/                 # MediaPipeline, LRU cache, EXIF/AI prompt parser, rich resolvers, seeder
│   │       ├── sync/                  # DriveSyncEngine, DirectAPI, WebDAV, MountedVolume, Local, InMemory, Migration
│   │       ├── layout/                # EditorialLayoutSolver (balanced/magazine/compact + groupFrame reflow)
│   │       ├── intelligence/          # ColorExtractor, PerceptualFingerprint, CloudAI, UsageTracker,
│   │       │                          # TypeSafeClient, VisualGrounding, Curator (MMR), MoodboardAgentHarness
│   │       ├── export/                # BoardImageExporter (PNG/JPG), FigmaBridgeExporter (.charkleboard ZIP)
│   │       ├── agent/                 # ExternalAgentService (14 MCP/CLI tools + ExternalAgentPolicy)
│   │       ├── traits/                # Platform seams: SecretVault, NativeOcr, ShellThumbnailer, MountVerifier
│   │       └── engine.rs              # LiveCharkleEngine unified facade
│   ├── charkle-platform-win/          # Windows-specific implementations behind charkle-core traits + Win32 helpers
│   │   └── src/
│   │       ├── ocr.rs                 # WinRT Windows.Media.Ocr (offline zh/en)
│   │       ├── shell_thumb.rs         # STA COM IShellItemImageFactory (PSD/AI/PDF/HEIC/video/3D)
│   │       ├── vault.rs               # Windows Credential Manager / DPAPI secret store
│   │       ├── mount.rs               # GetDriveTypeW / GetVolumeInformationW + optional gdirect.exe probe
│   │       ├── windowing.rs           # Win11 Mica/Acrylic DWM, WM_NCHITTEST Snap Layouts, Win10 fallback
│   │       ├── shelf_win.rs           # Top-Edge Drop Shelf HWND (WS_EX_NOACTIVATE, hotstrip, IDropTarget)
│   │       ├── drag_out.rs            # OLE DoDragDrop (CF_HDROP + IDragSourceHelper preview)
│   │       ├── capture.rs             # Windows.Graphics.Capture / DXGI multi-DPI desktop snapshot
│   │       └── clipboard.rs           # AddClipboardFormatListener watcher (images, files, URLs, X links, hex)
│   └── charkle-cli/                   # Native standalone charkle-cli.exe (stdio MCP + CLI commands)
├── src-tauri/                         # Tauri v2 application shell
│   ├── tauri.conf.json                # Windows x64 NSIS bundler, multi-window config (main, shelf, capture)
│   ├── capabilities/                  # Scoped Tauri v2 window permissions
│   └── src/
│       ├── main.rs                    # App boot, single-instance lock, tray, deep-link, hotkeys
│       ├── commands/                  # Typed Tauri IPC commands mirroring CharkleEngineProtocol
│       ├── protocol.rs                # Zero-copy `charkle-media://localhost/...` streaming with HTTP Range
│       ├── events.rs                  # Live event broadcaster (sync, harness steps, enrichment, shelf, CLI wake)
│       └── windows_shell.rs           # Wires charkle-platform-win into main / shelf / capture WebView windows
└── ui/                                # React 19 + Vite 6 + TypeScript + Tailwind CSS v4 + Zustand
    ├── public/icons/                  # Synced original Duotone & Layered SVGs
    └── src/
        ├── api/                       # Pluggable `CharkleTransport` seam (`TauriTransport` now; `HttpTransport` ready)
        ├── design-system/             # Gallery-First tokens, Windows Mica/Acrylic CSS, CharkleMotion, CharkleIcon
        ├── stores/                    # 4 domain Zustand stores: coordinator, library, moodboard, syncAI
        ├── components/                # Titlebar (Snap Layout aware), Glass pills, Popovers, Drop rings
        └── features/
            ├── sidebar/               # System views, nested FolderTree, HierarchyMenus, Customization, SmartFolders
            ├── gallery/               # TopFilterCapsule, Vertical/Horizontal Masonry, Filmstrip, Marquee, BatchPill, Inbox
            ├── quicklook/             # Space QuickLook overlay + 8 rich viewers (long-strip, anim, README, social, 3D, PDF, audio)
            ├── inspector/             # Reorderable cards, EXIF/AI prompt inspector, palette, similar, TypeSafe tools
            ├── moodboard/             # Home, 4+1 Generator + HarnessTrace, CandidatePool, DualModeCanvas, 5 nodes, Export
            ├── shelf/                 # Separate lightweight entry (`shelf.html`) for Top-Edge Drop Shelf (Compact + Full-Waterfall)
            ├── capture/               # Separate lightweight entry (`capture.html`) for fullscreen region snipping overlay
            ├── jump/                  # Ctrl+J JumpAnywhere modal
            ├── settings/              # Centered 9-pane SettingsOverlay (4 sections) + Migration Wizard
            └── onboarding/            # Skippable Onboarding Studio
```

---

## 2. Deep-Module Boundaries & Platform Seams

Following `.trellis/spec/` deep-module principles (introduce seams only where ≥2 real implementations exist):

1. **`PlatformServices` Seams inside `crates/charkle-core/src/traits/`** (2 implementations each: `charkle-platform-win` on Windows vs `Stub/Test` implementations for headless unit testing):
   - `SecretVault`: Windows DPAPI / Credential Manager vs in-memory test vault.
   - `NativeOcrProvider`: WinRT `Windows.Media.Ocr` vs mock OCR for tests.
   - `ShellThumbnailProvider`: STA COM `IShellItemImageFactory` vs fallback/mock.
   - `VolumeMountInspector`: Win32 `GetDriveTypeW`/`GetVolumeInformationW` + optional `gdirect.exe` vs mock.
2. **`DriveTransport` Seam inside `crates/charkle-core/src/sync/`** (5 real adapters mirroring macOS):
   - `DirectAPITransport` (Google Drive API v3 + PKCE OAuth + shared folder URL/ID + optional `gdirect.exe` IP override)
   - `WebDAVTransport` (`PROPFIND` / `GET` / `PUT` / `MKCOL` / `MOVE` / `DELETE`)
   - `MountedVolumeTransport` (Google Drive Desktop `G:\` / `rclone` / WinFsp with strict mount verification)
   - `LocalFolderTransport` (pure local folder `%USERPROFILE%\Pictures\Charkle`)
   - `InMemoryDriveTransport` (multi-device concurrent sync & rename conflict tests)
3. **`CharkleTransport` Seam inside `ui/src/api/`** (future-proofs optional Web reuse with zero Rust duplication):
   - Primary implementation: `TauriTransport` — calls Tauri v2 `invoke()` commands, subscribes to Tauri `listen()` events, and resolves thumbnails/originals via custom zero-copy `charkle-media://localhost/media/{id}/{tier|original}` protocol (supports `206 Partial Content` HTTP `Range` for instant video/audio scrubbing without copying bytes through JSON IPC).
   - Future seam: `HttpTransport` can be plugged in later if a thin `axum` HTTP wrapper around `charkle-core` is ever added for browser access.

---

## 3. Data Flow, Storage & Interop Contracts

### 3.1 Local Data Layout on Windows
- App data root: `%LOCALAPPDATA%\Charkle\` (overrideable via `--library-dir <path>` in `charkle-cli.exe` and tests):
  - `library.sqlite` (SQLite WAL + FTS5 schema `user_version = 2`, 1:1 with `LibraryDatabase.swift`)
  - `thumbnails/grid520/<uuid>.jpg` & `thumbnails/preview1400/<uuid>.jpg`
  - `cache/originals/<uuid>.<ext>` (configurable 2–100 GB LRU cache; `pinnedOffline` assets & boards exempt from eviction)
  - `config/app-config.json`, `config/sync-config.json`, `config/ai-config.json`, `config/agent-policy.json`
  - Secrets (OAuth tokens, WebDAV password, Cloud AI API keys, ChatGPT tokens): **NEVER written in plaintext JSON** — stored exclusively via Windows Credential Manager / DPAPI (`CryptProtectData`).

### 3.2 `/.charkle/` Bidirectional Sync Parity
- `SwiftWireCodec` guarantees byte-semantic compatibility with macOS `DriveSyncEngine`:
  - Cocoa epoch timestamps (`978_307_200.0`), uppercase UUIDs, Base64 `Data`, Swift keyed enums, Base64 JSON fragment `SyncFields`, HLC `(time, device)` clocks, tag tombstone sets, and `driveFileID` + `contentHash` rename/move reconciliation.
  - Files in user folders remain 100% human-readable (`Inbox/`, nested `<UserFolder>/`), and Windows path separators (`\`) are normalized to POSIX `/` inside `/.charkle/` metadata and normalized safely against Windows illegal filename characters (`<>:"/\|?*`) on local projection.

### 3.3 External Agent IPC & Live Refresh
- `charkle-cli.exe` operates directly on the shared `library.sqlite` (WAL concurrent access) honoring `ExternalAgentConfig` (`mcpEnabled`, `cliEnabled`, `accessLevel: readOnly | readWriteOrganize`; permanent delete ALWAYS forbidden).
- On external write operations, `charkle-cli.exe` writes a lightweight trigger signal (Windows named event `Local\CharkleLibraryChanged` or sentinel timestamp file watched by `notify`) so the running Tauri desktop app emits `library:changed` and live-refreshes open UI views immediately.

---

## 4. Visual System, Windowing & Multi-Window Architecture

### 4.1 Three Scoped Tauri Windows
1. **`main` (Primary Gallery & Studio Window)**:
   - Custom frameless titlebar (`decorations: false`, `transparent: true` on Win11 Mica backdrop) with `WM_NCHITTEST` Snap Layout support on the maximize button.
   - Strictly neutral Gallery Ground (`#F6F6F5` Light / `#141517` Dark) so artwork colors are never polluted; floating chrome ONLY uses restrained Acrylic/Glass backdrop (Top Search/Filter Capsule, Moodboard Bottom Tool Dock, Multi-Select Batch Action Pill, Quick Look HUD).
   - 9-pane centered Settings Overlay (`4 sections`: 基础与存储 / 采集与操作 / 生态与智能 / 系统) and skippable Onboarding Studio.
2. **`shelf` (Top-Edge Drop Shelf — `shelf.html`)**:
   - Fixed oversized transparent HWND anchored at active monitor top-center (`WS_EX_TOPMOST | WS_EX_TOOLWINDOW | WS_EX_NOACTIVATE`).
   - Supports Compact Shelf (`660×330` inner capsule: quick drop well, Inbox/Folder/Active Moodboard target pill, clipboard X/URL detector, recent strip) and Full-Waterfall Shelf (`980×580`: multi-column masonry, marquee multi-select, native OLE drag-out).
   - Never mutates HWND size mid-animation; toggles pointer pass-through dynamically outside active capsule rect.
3. **`capture` (Fullscreen Region Snipping Overlay — `capture.html`)**:
   - Created/shown on `Alt+Shift+A` over captured physical-pixel desktop snapshot; zero flicker, instant dismiss on `Esc` or mouse-up crop.

### 4.2 Motion & Accessibility Parity (`docs/MOTION_AND_ICON_SPEC.md`)
- Exact role-mapped easing tokens (`--ease-out`, `--ease-out-strong`, `--ease-in`, `--ease-in-out`, `--ease-overshoot`, spring response/damping), continuous concentric corners (`20/8→12`, `12/6→6`, `14/6→8`), drag-reorder neighbor ripple (`A * pow(0.7, n)`, `24ms * n` stagger), and UI continuity (Card ↔ QuickLook hero zoom, travelling sidebar pill, Auto Editorial ↔ Freeform smooth coordinate interpolation).
- Windows keyboard ergonomics: `Ctrl+J` (Jump Anywhere), `Ctrl+Z` / `Ctrl+Y` & `Ctrl+Shift+Z` (Undo/Redo), `Space` (Quick Look), `1–9` (Inbox Triage), `Alt+Shift+A` (Capture), `Alt+Shift+S` (Toggle Top Drop Shelf), `Alt+Shift+V` (Quick Collect Clipboard).
- Full `prefers-reduced-motion` (`0.15s` cross-fade) and `prefers-reduced-transparency` / Windows Transparency Effects Off solid fallback.

---

## 5. Key Trade-Offs & Rollback Strategy

- **Pure Rust Core vs Node Sidecar**: Choosing pure Rust (`charkle-core`) eliminates bundling a ~50MB Node runtime, gives <150ms cold start and ~15–25MB NSIS installer, and provides zero-overhead `windows-rs` access to WinRT OCR, Shell thumbnails, OLE drag-out, and DPAPI. Trade-off is implementing core logic in Rust rather than sharing TS with the paused Node Web plan — mitigated by clean 1:1 module mirroring against macOS Swift and golden cross-platform wire fixtures.
- **Win11 Primary + Win10 1903+ Fallback**: Build-number runtime detection keeps Win11 Mica/Snap Layouts first-class while automatically degrading visual backdrop on Win10 without breaking layout or contrast.
- **Strict Repo Isolation & Rollback**: All Windows work lives inside `./windows/` and `.trellis/tasks/11-23-windows-*`. Any milestone can be rolled back cleanly without touching macOS (`Sources/`, `Tests/`, `Package.swift`) or Web (`./web/`).
