# PRD: Windows M2 — Tauri IPC, Gallery-First UI, Navigation, Inbox & Quick Look

> Parent Task: `11-23-windows-client` · Depends On: `11-23-windows-m1-core-db-media-sync`

## 1. Goal & User Value

Wire the Tauri v2 desktop application shell to `charkle-core` and deliver the complete **Gallery-First React UI** on Windows 11/10 — featuring zero-copy local media streaming, custom Snap-Layout-aware titlebar with restrained Mica/Acrylic chrome, all 3 gallery layout modes, nested folders & Smart Folders, Inbox Triage (`1–9`), `Ctrl+J` Jump Anywhere, reorderable Inspector cards (with EXIF/AI prompts), and Full-Media Quick Look (`Space`).

## 2. Requirements

- **M2-R1 Tauri v2 Shell & Media Streaming**: Expose typed Tauri IPC commands over `LiveCharkleEngine`, event bridge (`library:changed`, `sync:status`, `asset:enriched`), and custom zero-copy `charkle-media://localhost/...` URI scheme supporting HTTP `206 Partial Content` `Range` requests for instant video/audio scrubbing.
- **M2-R2 Windows 11/10 Chrome & Gallery-First Design System**: Implement frameless main window with custom titlebar supporting Windows 11 Snap Layouts (`WM_NCHITTEST` `HTMAXBUTTON`), Win11 22H2+ Mica backdrop behind sidebar rail + Win10 1903+ clean fallback; exact neutral surfaces (Light `#F6F6F5`/`#FFFFFF`/`#F1F0EC`, Dark `#141517`/`#1E2025`/`#131519`), zero violet/neon chrome, continuous concentric corners (`20/8→12`, `12/6→6`, `14/6→8`), role-mapped easing curves, reduced-motion (`150ms` fade) & reduced-transparency solid fallbacks, and all 49 synced original Duotone/Layered SVG icons.
- **M2-R3 Pluggable `CharkleTransport` & Domain Stores**: Implement `ui/src/api/transport.ts` (`CharkleTransport` interface + `TauriTransport` implementation, keeping future `HttpTransport` Web reuse clean) and 4 Zustand stores (`coordinator`, `library`, `moodboard`, `syncAI`).
- **M2-R4 Navigation, Folders & Smart Folders**: Sidebar with All Items, Inbox (live badge), Moodboards entry, Untagged, Recent, Trash, nested `FolderTree` (create/rename/delete/drag-reorder/re-parent + hierarchical folder move menus matching commit `283bbfe` + custom color/icon popover), Smart Folders (`SmartFolderRule` editor), and Tags with counts.
- **M2-R5 Visual Filter Capsule & 3 Gallery Modes**: Top floating Glass/Acrylic search & filter capsule (live FTS5/pinyin search, semantic search toggle, multi-select `MediaKind`, CIELAB color picker + ΔE slider, `AspectShape`, min star rating, tags, offline-pinned toggle, 6 `SortOrder` modes); Virtualized Vertical Masonry, Horizontal Justified Masonry, and Gallery Filmstrip with borderless cards, hover muted video/GIF preview, marquee box-select, floating `BatchActionPill`, and context menus.
- **M2-R6 Inbox Triage, `Ctrl+J` & Reorderable Inspector**: Inbox Triage Bar (`1–9` quick move to top folders, AI folder suggestion + accept, send to active moodboard, Inbox Zero state); `Ctrl+J` Jump Anywhere modal across folders/boards/tags/assets; Right Inspector with **user-reorderable collapsible cards** (title/notes/rating, tags & AI tags, folder hierarchy picker, offline pin, CIELAB palette w/ copy HEX & reverse color search, EXIF & AI prompt metadata card, similar assets, rich refresh).
- **M2-R7 `Space` Full-Media Quick Look**: Continuous card-to-Quick-Look hero transition, subtle low-saturation ambient tint, bottom filmstrip & `←/→/Esc` nav, and rich viewers for all 8 media types: zoomable Image/GIF (incl. **original long-strip scroll mode & animation playback controls**), HTML5 Video, Audio waveform player, PDF (`pdfjs-dist`), Markdown/Code/Text (`marked` + `dompurify`), GitHub Repo + README card, Social Post multi-attachment carousel, and Three.js 3D viewer (`GLB`/`GLTF`/`OBJ`/`STL`).

## 3. Out of Scope

- Top-Edge Drop Shelf window, global hotkeys, region screenshot capture, OLE outbound drag, WinRT OCR & Shell thumbnails (M3).
- Dual-Mode Moodboard canvas & Figma exporter (M4); Cloud AI / TypeSafe Jev / 9-pane Settings / CLI+MCP (M5).

## 4. Acceptance Criteria

- [ ] `cd windows/ui && npm run typecheck && npm test && npm run build` and `cd windows && cargo check --workspace` pass with zero errors.
- [ ] `npm run tauri dev` launches cleanly on Windows 11/10 in both Light (`#F6F6F5`) and Dark (`#141517`) modes with zero console errors, native Snap Layouts working on maximize button, and sample library seeded on first launch.
- [ ] 10k-asset virtualized scroll, Chinese pinyin + CIELAB filtering, Inbox `1–9` triage, `Ctrl+J` jump, reorderable Inspector cards, and Quick Look across all 8 media kinds (incl. HTTP Range video seeking & long-strip image scrolling) all operate smoothly.
