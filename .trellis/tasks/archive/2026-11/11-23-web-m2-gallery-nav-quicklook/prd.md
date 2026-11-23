# PRD: M2 — Gallery-First UI, Navigation, Smart Folders, Inbox & Quick Look

- **Parent Task**: `11-23-web-version`
- **Dependencies**: `11-23-web-m1-core-db-media-sync`

## Goal
Build the complete Gallery-First Charkle Web interface matching macOS visual craft, neutral color surfaces, restrained Liquid Glass floating controls, original SVG icons, full navigation (Folders + Smart Folders + Tags), 3 Gallery layouts, Inbox Triage Station, `⌘J` Jump Anywhere, Right Inspector, and Full-Media `Space` Quick Look across all 8 media types.

## Requirements
1. **Design System & Icons**:
   - Exact Light (`#F6F6F5`) & Dark (`#141517`) neutral palettes, concentric corner radii (`20/12`, `12/6`, `14/8`), easing variables, restrained Liquid Glass strictly on floating chrome, zero violet/neon AI clutter.
   - `CharkleIcon` component rendering all original Duotone & Layered SVGs synced from `Sources/CharkleApp/Resources/Icons/`.
2. **Sidebar & Organization**:
   - All system destinations (`全部素材`, `收件箱` w/ live count badge, `情绪板`, `未标签`, `最近使用`, `废纸篓`).
   - Nested Folders tree with expand/collapse, inline create/rename/delete, drag-to-reorder & nest, drag assets onto folders, and `FolderCustomizationPopover` (color swatch + custom icon picker).
   - Smart Folders list + `SmartFolderEditorSheet` (`all`/`any` match mode, tags, description query, CIELAB color hexes + tolerance, media kinds, min rating, live match preview count).
   - Tags list with asset counts.
3. **Top Floating Liquid Glass Search & Visual Filter Capsule**:
   - Instant FTS5/pinyin search bar + Hybrid Semantic Search toggle button.
   - Expandable visual filter strip: MediaKind pills, CIELAB color picker + ΔE tolerance slider, AspectShape (`横图`/`竖图`/`方图`/`超宽`), min rating stars, active tag filters, offline-pinned toggle, 6 `SortOrder` options, layout mode switcher (`纵向瀑布流`/`横向瀑布流`/`画廊视图`), and card density slider.
4. **3 Gallery Layouts & Multi-Selection**:
   - `VerticalMasonryView` (virtualized columns), `HorizontalJustifiedView` (equal-height justified rows), and `GalleryFilmstripView` (hero viewer + bottom filmstrip).
   - Borderless continuous-corner cards, hover/selection chrome, marquee drag box-select, `⌘A`/Shift-click range select, context menu, and bottom floating Liquid Glass `BatchActionPill` (move folder, add tag, rate, pin offline, send to moodboard, trash/restore/permanent delete).
5. **Inbox Triage Station & `⌘J` Jump Anywhere**:
   - Inbox top triage bar showing numbered (`1`–`9`) quick-move target folders, AI recommended folder chip with 1-click accept, send-to-active-board, and clean Inbox Zero state with Layered icon.
   - `⌘J` floating search palette jumping across Folders, Moodboards, Tags, and Assets with keyboard arrows + Enter.
6. **Right Inspector**:
   - Single-asset mode (low-saturation ambient tint, editable title/notes, 0–5 star rating, folder picker, tags + AI suggested tags accept/dismiss, CIELAB dominant palette w/ click-to-copy & reverse color search, metadata grid, similar assets carousel, offline pin, rich asset refresh, TypeSafe subject-palette/auto-clean-crop buttons) and multi-select batch edit mode.
7. **`Space` Full-Media Quick Look Overlay**:
   - Ambient low-saturation tint backdrop, floating Liquid Glass HUD controls, bottom filmstrip, `←/→/Esc` navigation, and rich viewers for all 8 media types: zoom/pan Image & GIF, HTML5 Video, Audio waveform player, PDF/Markdown/Code/Text viewer, GitHub Repo + README card (with refresh & GitHub link), Social Post viewer (X/Threads/Bluesky multi-attachment carousel, quote card, stats), and Three.js interactive 3D Model viewer (GLB/GLTF/OBJ/STL).

## Acceptance Criteria
- All 3 gallery views render smoothly with sample library and newly uploaded/ingested files; filters (search/pinyin/color/kind/shape/rating/smart folder/tag) update results accurately.
- Creating/editing/nesting/customizing folders and smart folders persists across page reloads.
- Inbox `1–9` keyboard triage, `⌘J` Jump Anywhere, Inspector edits, and `Space` Quick Look work for every media kind including GitHub README, Social Post, Audio waveform, Markdown/PDF, and 3D models.
- `cd web && npm run typecheck && npm run build` succeeds with 0 errors.
