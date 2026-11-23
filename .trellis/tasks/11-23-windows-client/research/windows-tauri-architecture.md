# Research: Charkle Windows Client Architecture (Tauri v2 + Pure Rust Core + React UI)

> Audited against macOS Charkle v1.0.1 (~43k LOC Swift 6.2/6.4) in this monorepo.
> Companion references: `web/docs/PARITY_SPEC.md`, `web/docs/DELTA_SYNC_SPEC.md`, and `windows/README.md`.

---

## 1. Module-to-Module Parity Map (macOS Swift → Windows Tauri v2 / Rust / React)

| macOS Module / Anchor | Lines | Windows Equivalent (`./windows/`) | Native Replacement & Interop Notes |
| :--- | ---: | :--- | :--- |
| `CharkleCore/Contracts/*.swift` | ~3,190 | `crates/charkle-core/src/models/*` + `ui/src/types/*` | 1:1 Rust `struct`/`enum` + TypeScript DTO mirrors (exported or verified via golden JSON fixtures) |
| `CharkleCore/Database/{LibraryDatabase,SQLiteConnection,SearchText,AssetVector}.swift` | ~820 | `crates/charkle-core/src/db/*` | `rusqlite` (`bundled` feature, SQLite WAL + FTS5 `unicode61 remove_diacritics 2`, `prefix='2 3 4'`, schema `user_version = 2`), `pinyin` crate, SIMD/loop f32/f16 cosine vector search |
| `CharkleCore/Media/*` (Pipeline, Cache, ImageMetadataExtractor, MarkdownDocumentParser, MediaArtwork, SVG, Social/X/GitHub/Web resolvers, SampleSeeder) | ~4,800 | `crates/charkle-core/src/media/*` + `crates/charkle-platform-win/src/shell_thumb.rs` | `image` + `fast_image_resize` + `resvg` + `kamadak-exif`/PNG/JPEG/WebP chunk AI prompt parser + `symphonia` waveform peaks + Win32 `IShellItemImageFactory` fallback (PSD/AI/PDF/HEIC/video/3D) + `reqwest` rich resolvers (zero CORS) |
| `CharkleCore/Sync/*` (DriveSyncEngine, DirectAPI, WebDAV, MountedVolume, InMemory, SyncOperations, GoogleOAuth, GDirectIntegration) | ~4,950 | `crates/charkle-core/src/sync/*` + `crates/charkle-platform-win/src/mount.rs` | Exact `/.charkle/` wire parity via `SwiftWireCodec`; Google Drive API v3 OAuth (PKCE loopback `127.0.0.1`), WebDAV (`PROPFIND`/`PUT`/`MOVE`), Windows mounted drive check (`GetDriveTypeW`/`GetVolumeInformationW` for `G:\`/WinFsp/`rclone`/`gdirect.exe`), local folder, lossless migration |
| `CharkleCore/Intelligence/*` (ColorExtractor, VisionAnalyzer, CloudAIProvider, ChatGPTSignInClient, UsageTracker, Curator, AgentHarness, ContactSheet, BoardImageRenderer, TypeSafe, VisualGrounding, ExternalAgentService, Policy, KeychainStore) | ~8,400 | `crates/charkle-core/src/intelligence/*` + `crates/charkle-core/src/agent/*` + `crates/charkle-platform-win/src/{ocr,vault}.rs` | WinRT `Windows.Media.Ocr` offline Chinese/English OCR; perceptual multi-scale visual fingerprint; Windows Credential Manager / DPAPI secret vault; all 4 Cloud AI modes + TypeSafe Jev sidecar + 14-tool MCP/CLI policy engine (`mcpEnabled` & `cliEnabled` independent) |
| `CharkleCLI/CharkleCLI.swift` | ~360 | `crates/charkle-cli/` (`charkle-cli.exe`) | Native Rust CLI binary sharing `charkle-core`: `mcp` stdio JSON-RPC 2.0 + `status`/`overview`/`inbox`/`search`/`organize`/`board` commands + live IPC wake signal to running desktop app |
| `CharkleCanvas/*` (VirtualizedMasonry, EditorialLayoutSolver, MoodboardCanvas, NodeViews, Exporter, FigmaBridgeExporter) | ~9,350 | `crates/charkle-core/src/{layout,export}/*` + `ui/src/features/{gallery,moodboard}/*` | Deterministic O(N) `EditorialLayoutSolver` mirrored identically; virtualized 3-mode gallery; GPU-transformed Freeform canvas + SVG connectors/ink; Rust high-DPI PNG/JPG renderer + `.charkleboard` lossless ZIP exporter verified against `Resources/FigmaPlugin/code.js` |
| `CharkleApp/DesignSystem/*` + `Resources/Icons/*` | ~1,000 + 49 SVGs | `ui/src/design-system/*` + `ui/public/icons/*` | Exact Light (`#F6F6F5`) & Dark (`#141517`) neutral palette, Windows 11 Mica/Acrylic floating chrome, Kubai Tip 004/005/010/011/015 tokens, synced original Duotone & Layered SVG icons |
| `CharkleApp/Notch/*` + `Services/*` (NotchShelf, GlobalHotkey, ScreenshotCapturer, ClipboardCollector) | ~2,200 | `crates/charkle-platform-win/src/{shelf,drag_out,capture,clipboard,hotkeys}.rs` + `src-tauri/` + `ui/src/features/shelf/*` | Transparent non-activating Top-Edge Drop Shelf (Compact + Full-Waterfall), `Alt+Shift+A/S/V`, DXGI/`Windows.Graphics.Capture` multi-DPI snipping overlay, `AddClipboardFormatListener`, OLE `DoDragDrop` (`CF_HDROP`), system tray & `charkle://` deep links |
| `CharkleApp/Views/*` + `Stores/*` | ~16,900 | `ui/src/stores/*` + `ui/src/features/*` | 4 Zustand stores (`coordinator`, `library`, `moodboard`, `syncAI`), Sidebar + nested FolderTree + hierarchy menus + SmartFolders, TopFilterCapsule, Inbox Triage (`1–9`), `Ctrl+J` Jump Anywhere, Reorderable Inspector cards (with EXIF/AI prompts), Full-Media QuickLook, 9-pane Settings overlay (4 sections), Skippable Onboarding Studio |

---

## 2. Recommended Rust & Frontend Dependency Stack

### Rust Workspace (`./windows/Cargo.toml`)
- **Desktop Shell**: `tauri = "2"`, `tauri-build = "2"`, `tauri-plugin-global-shortcut = "2"`, `tauri-plugin-autostart = "2"`, `tauri-plugin-deep-link = "2"`, `tauri-plugin-dialog = "2"`, `tauri-plugin-shell = "2"`, `tauri-plugin-single-instance = "2"`, `window-vibrancy = "0.6"` (or direct `DwmSetWindowAttribute` via `windows-rs` for full Win11/Win10 control).
- **Windows Native APIs (`#[cfg(target_os = "windows")]`)**:
  - `windows = "0.58"` (or latest 0.60+ compatible with Rust 1.85+) with targeted features:
    - `Win32_Foundation`, `Win32_UI_WindowsAndMessaging`, `Win32_UI_Input_KeyboardAndMouse`, `Win32_UI_HiDpi`, `Win32_UI_Shell`, `Win32_UI_Shell_Common`
    - `Win32_Graphics_Dwm`, `Win32_Graphics_Gdi`, `Win32_Graphics_Dxgi`, `Win32_Graphics_Direct3D11`
    - `Win32_System_Com`, `Win32_System_Ole`, `Win32_System_DataExchange`, `Win32_System_Memory`, `Win32_System_LibraryLoader`
    - `Win32_Security_Credentials`, `Win32_Security_Cryptography`
    - `Win32_Storage_FileSystem`
    - `Media_Ocr`, `Graphics_Imaging`, `Graphics_Capture`, `Storage_Streams`, `Globalization`
- **Core Engine (`crates/charkle-core`, strictly cross-platform OS-agnostic)**:
  - Database: `rusqlite = { version = "0.32+", features = ["bundled", "modern_sqlite"] }` (includes WAL + FTS5 out of the box with zero external DLLs).
  - Pinyin: `pinyin = "0.10"` (full pinyin + first-letter initials matching `SearchText.swift`).
  - Async & Networking: `tokio`, `reqwest = { features = ["json", "stream", "rustls-tls", "multipart"] }`, `url`, `base64`, `hex`, `sha2`, `md-5`.
  - Serialization & IDs: `serde`, `serde_json`, `uuid = { features = ["v4", "serde"] }`, `chrono`.
  - Imaging & Export: `image`, `fast_image_resize`, `resvg` (SVG rasterization), `kamadak-exif` + custom PNG `tEXt`/`iTXt`/`zTXt` & JPEG/WebP prompt parser (matching `ImageMetadataExtractor.swift`), `zip` (lossless `.charkleboard` bundle with stored/deflated entries), `symphonia` (audio duration + peak waveform sampling).
  - Markdown/HTML Parsing: `scraper` (HTML OpenGraph / X / Threads / Bluesky / GitHub parsing), `pulldown-cmark` (server-side text extraction).
  - File Watching & CLI: `notify` (local library / external write watching), `clap` (for `charkle-cli.exe`), `thiserror`, `tracing`, `tracing-subscriber`.

### Frontend (`./windows/ui/package.json`)
- **Framework**: React 19, TypeScript 5.8+ (strict), Vite 6, Tailwind CSS v4.
- **State & Motion**: `zustand`, `framer-motion` (strictly configured with Kubai Tip 011 curves & `useReducedMotion`).
- **Rich Viewers**: `three` + `@types/three` (GLB/GLTF/OBJ/STL 3D Quick Look), `marked` + `dompurify` (GitHub README / Markdown Quick Look), `pdfjs-dist` (PDF Quick Look page viewer), `lucide-react` (secondary UI chrome fallback behind Charkle's 49 original Duotone/Layered SVG icons).
- **Testing**: `vitest`, `@testing-library/react`.

---

## 3. Critical Win32 / WinRT Engineering Blueprints

### 3.1 Top-Edge Drop Shelf (Windows Counterpart to `NotchShelfController.swift`)
- **Non-Negotiable Motion Invariant** (from `NotchShelfState.swift` & `MOTION_AND_ICON_SPEC.md`):
  - Never mutate Win32 HWND bounds (`SetWindowPos`) mid-spring animation! Allocate a **fixed oversized transparent window** anchored flush to `monitor.work_area.top` (`y = monitor_rect.top`), centered horizontally on the active monitor.
  - All transitions (Collapsed 4px pill ↔ Compact Shelf `660×330` ↔ Full-Waterfall Shelf `980×580`) animate purely inside WebView2 with CSS/Framer Motion transforms from `transform-origin: top center`.
- **Window Flags & Click-Through**:
  - Extended styles: `WS_EX_TOPMOST | WS_EX_TOOLWINDOW | WS_EX_NOACTIVATE | WS_EX_LAYERED`.
  - When collapsed or when pointer is over transparent margin pixels outside the visible capsule bounds, enable click-through (`WS_EX_TRANSPARENT` or region hit-test via `WM_NCHITTEST` returning `HTTRANSPARENT` outside active capsule rect).
- **Drag-to-Top-Edge Auto-Expand**:
  - Maintain a lightweight background pointer watcher (or invisible 3px tall × 320px wide top-center hotstrip window with native OLE `IDropTarget` registered via `RegisterDragDrop`).
  - When `IDropTarget::DragEnter` fires on the hotstrip (or cursor enters top 4px while `GetAsyncKeyState(VK_LBUTTON) < 0` with an active drag), emit `shelf:drag-enter` to the Shelf WebView, disable click-through on the expanded capsule bounds, and spring open smoothly without stealing focus from Chrome/Explorer/Figma!
  - Accept dropped files (`CF_HDROP`), URLs (`UniformResourceLocatorW` / `CF_UNICODETEXT`), and DIB/PNG bitmaps (`CF_DIBV5`), routing directly to `targetMode` (`Inbox` / `Folder` / `Active Moodboard`).

### 3.2 Outbound Native File Drag (`DoDragDrop` with `CF_HDROP`)
- Standard WebView2 HTML5 drag cannot deliver real local files to Photoshop, Figma Desktop, Premiere, or Windows Explorer.
- Solution:
  1. When user initiates a drag on one or more selected gallery/shelf/moodboard assets, React invokes `start_outbound_file_drag(asset_ids: Vec<String>)`.
  2. Rust resolves local original file paths (using already-cached originals immediately, or materializing from local library / LRU cache).
  3. On an STA-initialized COM thread (or UI thread), Rust constructs a COM `IDataObject` implementing `CF_HDROP` (`DROPFILES` struct with double-null UTF-16 paths) and calls Win32 `DoDragDrop(data_object, drop_source, DROPEFFECT_COPY | DROPEFFECT_LINK, &mut effect)`.
  4. Optional `IDragSourceHelper` attaches a thumbnail bitmap preview so dragging looks native on Windows 11.

### 3.3 Multi-DPI Region Screenshot Capture (`Alt+Shift+A`)
- Ensure app manifest declares `PerMonitorV2` DPI awareness (Tauri v2 default).
- Capture strategy:
  1. Snapshot each monitor's desktop frame cleanly via `Windows.Graphics.Capture` / DXGI Desktop Duplication (with fast GDI `BitBlt` fallback on restricted/remote RDP sessions).
  2. Open a frameless fullscreen topmost overlay window spanning the virtual desktop (or per monitor) displaying the frozen frame at 1:1 physical pixels.
  3. Overlay renders dark dimming mask, crosshair, pixel dimensions badge, and 8× zoom loupe; releasing selection crops the exact physical pixel rectangle, encodes lossless PNG, ingests via `CaptureInput::RawImage`, and routes to Inbox or Active Moodboard.

### 3.4 Offline WinRT OCR & Shell Thumbnails (COM Threading Safety)
- **WinRT OCR (`Windows.Media.Ocr.OcrEngine`)**:
  - Attempt `OcrEngine::TryCreateFromUserProfileLanguages()`, with explicit preference probe for `zh-Hans` / `zh-Hant` / `en-US` installed language packs (`OcrEngine::AvailableRecognizerLanguages()`).
  - Decode image bytes into `SoftwareBitmap` (`BitmapPixelFormat::Bgra8`, `BitmapAlphaMode::Premultiplied`), run `RecognizeAsync`, join recognized lines with spaces/newlines.
  - If no Windows OCR language pack is installed, return graceful diagnostic metadata (`ocrUnavailableReason`) and fall back to Cloud AI / TypeSafe Jev without throwing.
- **Shell Thumbnails (`IShellItemImageFactory`)**:
  - Dedicated single-threaded worker initialized with `CoInitializeEx(None, COINIT_APARTMENTTHREADED | COINIT_DISABLE_OLE1DDE)`.
  - Call `SHCreateItemFromParsingName` → `IShellItemImageFactory::GetImage(SIZE { cx, cy }, SIIGBF_THUMBNAILONLY | SIIGBF_BIGGERSIZEOK)` → extract `HBITMAP` RGBA pixels → encode JPEG/WebP thumbnail (`grid520` / `preview1400`) → `DeleteObject(hbitmap)` immediately to prevent GDI handle leaks!

### 3.5 Windows 11 Mica / Acrylic, Snap Layouts & Win10 Fallback
- Detect Windows build number via `RtlGetVersion`:
  - **Build ≥ 22621 (Win11 22H2+)**: Apply `DWMWA_SYSTEMBACKDROP_TYPE` = `DWMSBT_MAINWINDOW` (Mica) on main window backdrop behind transparent sidebar rail, `DWMWA_USE_IMMERSIVE_DARK_MODE` synced with Light/Dark theme, and `DWMWA_WINDOW_CORNER_PREFERENCE` = `DWMWCP_ROUND`.
  - **Build 19041–22620 (Win10 2004 / Win11 21H2)**: Fall back cleanly to calibrated translucent Acrylic or crisp solid surface (`#F6F6F5` / `#141517`) with zero visual glitches.
  - **Snap Layouts on Custom Titlebar**: Subclass main HWND `WM_NCHITTEST` so hovering over the custom React maximize button coordinate rect returns `HTMAXBUTTON`, unlocking native Windows 11 Snap Layout flyouts!
  - **Accessibility**: Observe Windows Transparency Effects (`HKEY_CURRENT_USER\Software\Microsoft\Windows\CurrentVersion\Themes\Personalize\EnableTransparency`) and `SPI_GETCLIENTAREAANIMATION` + CSS `@media (prefers-reduced-motion: reduce)` / `@media (prefers-reduced-transparency: reduce)`.

---

## 4. Exact Swift `/.charkle/` Wire-Format Parity Rules

Verified directly from `Sources/CharkleCore/Sync/SyncOperations.swift`, `DriveSyncEngine.swift`, and `Contracts/*.swift`:

1. **Timestamps**: Cocoa Reference Date float seconds since `2001-01-01T00:00:00Z` (`COCOA_EPOCH_OFFSET_SEC = 978_307_200.0`).
   - Encode: `(unix_ms as f64 / 1000.0) - 978_307_200.0`.
   - Decode: accept both `f64`/`i64` (Cocoa float seconds) and RFC-3339 ISO-8601 strings defensively.
2. **UUIDs**: Uppercase RFC-4122 hyphenated (`XXXXXXXX-XXXX-XXXX-XXXX-XXXXXXXXXXXX`).
3. **Binary `Data`**: Standard Base64 string.
4. **Swift Keyed Enums**:
   - `BoardLayoutMode`: `{"autoEditorial":{"_0":{...}}}` or `{"freeform":{}}`.
   - `BoardNodeKind`: `{"assetRef":{"assetID":...,"crop":...,"weight":...,"autoplayLoop":...}}`, `{"note":{"title":...,"text":...,"style":...,"fontSize":...}}`, `{"groupFrame":{"title":...,"tint":...}}`, `{"paletteStrip":{"colors":...,"autoSyncWithBoard":...}}`.
   - `SyncOperation::Change`: `asset`, `board`, `folder`, `deleteAsset`, `deleteBoard`, `deleteFolder`, `vector` (matching Swift synthesized Codable keys `_0`, `driveID`, `_1`).
5. **`SyncFields` Delta Map**:
   - `AssetChanges.fields` & `BoardChanges.fields` are JSON maps `{ "<fieldName>": "<base64-encoded-canonical-json-fragment>" }`.
   - Excluded keys: Asset (`id`, `tags`, `isLocalOriginalCached`, `updatedAt`, `updatedHLC`), Board (`id`, `nodes`, `connectors`, `inkStrokes`, `updatedAt`, `updatedHLC`).
6. **CRDT Merge Rules**:
   - `SyncStamp { time: i64, device: String }` compared lexicographically `(time, device)` with `time = max(now_ms * 1024, prev + 1)`.
   - Per-field LWW clock keys: `"field:<key>"`; collection keys: `"node:<UUID>"`, `"connector:<UUID>"`, `"stroke:<UUID>"`; tombstone key: `"deleted"`.
   - Tag sets merge case-insensitively (`SearchText::normalize`) via `tagsAdded` / `tagsRemoved`.
7. **Golden Fixture Strategy**:
   - Before shipping M1, generate real `manifest.json`, `ops/*.jsonl`, and `boards/*.json` fixtures from macOS Swift (`CharkleTests`) and verify Rust `SwiftWireCodec` decodes, mutates, re-encodes, and Swift re-imports them losslessly!

---

## 5. Windows Machine Development Setup Checklist

Run once on the Windows 10/11 `x64` development machine before starting M1:

1. **Visual Studio 2022 Build Tools** (or Visual Studio 2022 Community):
   - Install workload **Desktop development with C++** (MSVC v143 + Windows 11 SDK 10.0.22621+).
2. **Rust MSVC Toolchain**:
   - Install via `winget install Rustlang.Rustup` (or `rustup-init.exe`), selecting default `x86_64-pc-windows-msvc` stable toolchain (Rust 1.85+).
3. **Node.js & npm**:
   - Install Node.js 22+ LTS (`winget install OpenJS.NodeJS.LTS`).
4. **WebView2 Runtime**:
   - Pre-installed on Windows 11; on Windows 10 verify Edge WebView2 Evergreen Runtime is present.
5. **Tauri CLI & Optional Tools**:
   - `cargo install tauri-cli --version "^2"` (or invoke via local `@tauri-apps/cli` devDependency inside `./windows/ui`).
   - Optional: install Chinese & English Windows OCR language packs (`Settings → Time & language → Language & region`) to exercise offline WinRT OCR in M3.
