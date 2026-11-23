# PRD: Windows M3 — Top-Edge Drop Shelf, Capture, OLE Drag-Out, WinRT OCR & Shell Thumbs

> Parent Task: `11-23-windows-client` · Depends On: `11-23-windows-m1-core-db-media-sync`, `11-23-windows-m2-gallery-nav-quicklook`

## 1. Goal & User Value

Deliver the **Windows-native desktop soul** that separates a real creative companion from a web page: a non-focus-stealing **Top-Edge Drop Shelf** (Windows counterpart to macOS Notch Shelf, supporting both Compact and Expanded Full-Waterfall modes), native **OLE outbound file drag** straight into Figma Desktop / Photoshop / Explorer, system-wide hotkeys (`Alt+Shift+A/S/V`), multi-DPI region screenshot capture, clipboard collector, offline **WinRT Chinese/English OCR**, **Windows Shell thumbnails** (PSD/AI/PDF/HEIC/video/3D), DPAPI credential vault, System Tray, launch-at-login, and `charkle://` deep links.

## 2. Requirements

- **M3-R1 Native Platform Services (`charkle-platform-win`)**:
  - `SecretVault`: Windows Credential Manager (`CredWriteW`/`CredReadW`) / DPAPI (`CryptProtectData`) replacing stub vault for OAuth tokens, WebDAV passwords, and AI keys.
  - `NativeOcrProvider`: Offline WinRT `Windows.Media.Ocr.OcrEngine` (probing `zh-Hans`, `zh-Hant`, `en-US`, user profile languages) with graceful diagnostic message if OCR language packs are missing.
  - `ShellThumbnailProvider`: Dedicated STA COM worker using `IShellItemImageFactory` with strict RAII `HBITMAP` cleanup to generate thumbnails for PSD/AI/PDF/HEIC/video/3D when native Rust decoders don't handle the format.
  - `VolumeMountInspector`: Win32 `GetDriveTypeW` / `GetVolumeInformationW` mount verification (supporting Google Drive Desktop `G:\`, `rclone`, WinFsp) + optional Windows `gdirect.exe` detection.
- **M3-R2 Top-Edge Drop Shelf (`shelf` window + `shelf.html`)**:
  - Fixed oversized transparent topmost non-activating window (`WS_EX_TOPMOST | WS_EX_TOOLWINDOW | WS_EX_NOACTIVATE | WS_EX_LAYERED`) anchored top-center of active cursor monitor — never resizing the Win32 HWND mid-spring animation.
  - Dynamic click-through outside the visible capsule bounds so maximized apps' titlebars/tabs are never blocked.
  - 2–3px top-center drag hotstrip with native OLE `IDropTarget` + drag-hover auto-expand when dragging files, URLs, or images from Chrome/Explorer/Figma.
  - Full dual-state parity with `NotchShelfState.swift`: **Compact Shelf** (drop well, target routing pill `收件箱 / 指定文件夹 / 当前活跃情绪板`, clipboard X/URL quick-capture chip, Recent Assets horizontal strip) and **Expanded Full-Waterfall Shelf** (multi-column masonry, marquee multi-select, native drag-out).
- **M3-R3 Outbound Native File Drag (`DoDragDrop`)**:
  - Dragging 1 or more selected assets out of Gallery, Inspector, Full-Waterfall Shelf, or Moodboard invokes Win32 OLE `DoDragDrop` with `CF_HDROP` (+ optional `IDragSourceHelper` thumbnail preview) so Photoshop, Figma Desktop, Premiere, and Explorer receive real local files.
- **M3-R4 Global Hotkeys, Multi-DPI Region Capture & Clipboard Collector**:
  - System-wide shortcuts (`Alt+Shift+A` region capture, `Alt+Shift+S` toggle/pin Top-Edge Drop Shelf, `Alt+Shift+V` quick-collect clipboard) configurable and toggleable.
  - Multi-DPI `Windows.Graphics.Capture` / DXGI Desktop Duplication (with GDI `BitBlt` fallback) + instant fullscreen frameless selection overlay (`capture.html`) with crosshair, pixel size badge, and 8× zoom loupe; saves directly to selected target (Inbox / Folder / Active Moodboard).
  - Clipboard listener (`AddClipboardFormatListener`) detecting images, file drops, URLs (incl. X/Threads/Bluesky/GitHub), text snippets, and hex colors.
- **M3-R5 Desktop Integration**:
  - System Tray icon & quick menu (Open Charkle, Toggle Top Shelf, Capture Area, Quick Collect Clipboard, Sync Now, Quit), optional launch-at-login (`tauri-plugin-autostart`), single-instance guard (`tauri-plugin-single-instance`), and `charkle://` URL scheme registration (`tauri-plugin-deep-link`).

## 3. Out of Scope

- Dual-Mode Moodboard canvas & `.charkleboard` Figma export (M4).
- Cloud AI / TypeSafe Jev / 9-pane Settings UI / `charkle-cli.exe` MCP (M5; M3 exposes minimal Settings/Tray hooks for hotkeys & shelf behavior).

## 4. Acceptance Criteria

- [ ] Dragging an image or file from Chrome or Explorer to the top-center edge of the screen smoothly springs open the Top-Edge Drop Shelf **without stealing window focus**, ingests the drop to Inbox/Folder/Active Moodboard, and collapses back with zero stuck click-through zones.
- [ ] Dragging one or multiple assets from Charkle's Gallery or Full-Waterfall Shelf directly drops real original files into Windows Explorer and Figma Desktop / Photoshop.
- [ ] `Alt+Shift+A` captures crisp 1:1 physical-pixel crops across mixed-DPI multi-monitor setups (e.g. 100% + 150% scaling); `Alt+Shift+S` toggles/pins the shelf; `Alt+Shift+V` collects clipboard image/URL/text.
- [ ] Offline WinRT OCR extracts Chinese & English text into FTS5 search index; Shell thumbnails render PSD/PDF/video previews with zero GDI handle leaks across 500 consecutive thumbnail calls; secrets persist encrypted in DPAPI/Credential Manager.
