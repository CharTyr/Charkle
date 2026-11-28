# PRD: Apple Dual-Platform (macOS & iOS/iPadOS) Version History, Continuous Paper Diff, Scheme B 2-Way Merge & Studio Compact View

> **Scope**: `Sources/CharkleCore/`, `Sources/CharkleApp/`, `Sources/CharkleCanvas/`, `Tests/CharkleTests/`, `ios/CharkleMobile/`, `ios/CharkleShareExtension/` · **Priority**: `P1`  
> **Companion Windows Parity Handoff**: [`.trellis/tasks/11-28-windows-document-stack-diff-and-compact-view-parity/`](../11-28-windows-document-stack-diff-and-compact-view-parity/) · [`docs/WINDOWS_DOCUMENT_SYNC_SPEC.md`](../../../docs/WINDOWS_DOCUMENT_SYNC_SPEC.md)

---

## 1. Goal & Zero-Fragmentation Product Philosophy

Extend Charkle on **macOS 15+** and **iOS / iPadOS 18+** (sharing `Sources/CharkleCore` directly) to handle multi-round office document revisions (`.docx`, `.xlsx`, `.pptx`, `.pdf`, `.md`, `.txt`, plus legacy `.doc/.wps/.xls/.et`) and dense multi-media collections **without creating a separate mini-OA silo or inventing coined UI jargon**.

Every organizational concept — Folders, Tags, Smart Folders, Ratings, Inbox, Notch Shelf / Share Extension, `⌘J` Jump Anywhere, and the pure-white (`#FFFFFF` / `#1C1D20`) `300pt` synchronized Inspector — remains **100% unified across all 8 `MediaKind`s**, using crisp pure-neutral studio surfaces (`galleryGround` `#F5F5F6` / `#141518`, `surfaceElevated` `#FFFFFF` / `#1C1D20`, `surfaceSubtle` `#F4F4F5` / `#25262B`) and plain everyday Chinese (`全部 / 文档 / 媒体`, `单列 / 双列`, `历史版本`, `合并版本`, `阅读 / 对比 / 合并`, `合并预览`, `保存为新版本`):

1. **Touchpoint 1 — 5th Universal Gallery Mode (`GalleryLayoutMode.compactList`) & Real A4 Office Page Thumbnails**
2. **Touchpoint 2 — Media-Agnostic Version History (`AssetRichMetadata.versionStack`) & Anti-Mis-Send Primary Lock (`isPinnedPrimary`)**
3. **Touchpoint 3 — Native Structured Document Parsing, Derived Full-Text Pinyin Cache & Instant Primary File Copy (`⌘J` -> `⌘C`)**
4. **Touchpoint 4 — Document Studio Single Unified Header, Continuous Paper Diff, Lockstep Split Sheet & Scheme B 2-Way Merge**

---

## 2. Requirements

### R1. 5th Universal Gallery Layout Mode (`compactList`) & Real A4 Office Page Thumbnails
- Add `.compactList` (`rawValue = "compactList"`, `localizedLabel = "紧凑视图"`, SF Symbol `list.bullet`, macOS shortcut `5`) to `GalleryLayoutMode`, wired into the top layout switcher, Onboarding, Settings default layout picker, and **per-destination layout mode memory** (per folder / Inbox, falling back to global default).
- **Minimal Sub-Toolbar (Zero Tutorial Banners)**:
  - Left: Show monochromatic category pills (`全部`, `文档`, `媒体`) ONLY when the collection mixes documents and visual/audio media (or an active filter is non-`.all`); homogeneous collections display a quiet item count (`"{N} 项"`).
  - Right (macOS `viewportWidth >= 680` & iPad regular width): Icon-only segmented control switching `单列` (`list.bullet`) ⇄ `双列` (`square.grid.2x2`).
- **1-Column Mode (`columns == 1`) — Sleek Unified Hairline Tracklist Surface**:
  - Render rows inside ONE elevated rounded table surface (`surfaceElevated`, single outer `0.5pt` hairline border, zero per-row drop shadows), separated by `0.5pt` hairlines inset beneath the title column (`leading: 60`) that automatically hide around hovered or selected rows, with inset `9pt` rounded row hover/selection highlights.
  - Single-axis horizontal rows: crisp squircle miniature page/media cover (`36×46pt` docs / `38×44pt` media, `6pt` continuous corners, `0.5pt` inner optical rim, delicate print shadow, single subtle offset back-sheet when stacked, and minimal paper tag for plain `.md/.txt` without cartoon red/blue bars) + 1-line title & quiet `#tag` pills + open middle marquee-selection zone + hover quick copy/share icon + quiet `vN/M ▾` trigger capsule + **audio-only** waveform sparkbar (**zero 12-stick red/green document barcode in Compact View rows**) + concise spec summary + tabular right-aligned timestamp column.
- **2-Column Mode (`columns == 2`) — Clean Non-Splitting Bento Grid**:
  - Pair items strictly 2-by-2 with tight `8pt` horizontal/vertical spacing into `58pt`-tall horizontal tiles; **NEVER** split `.pair` rows into full-width `.single` rows.
- **Universal Vertical Version History Popover**:
  - Clicking/tapping `vN/M ▾` in **both** 1-col and 2-col modes opens an anchored newest-first (`vN → v1`) vertical timeline `.popover` (`历史版本` header + count + `对比差异` button; `1pt` vertical hairline spine with filled accent `●` primary and hollow `○` historical nodes; deduplicated non-boilerplate labels without `"本机"` / `"初稿"` / `"修订版"`; inline `Δ N` diff trigger ONLY when `N > 0`; and 1-tap `pin` button to set Primary Version).
- **Full Gallery Interaction Invariants**: Single, `⇧` range, `⌘` multi-selection, and rubber-band marquee box multi-selection; `↑ / ↓` `0ms` keyboard navigation; unmodified `Space` Quick Look toggle; drag-out of the **Primary Version** original file; and drag-drop onto a row/tile to merge versions.
- **Real A4 Office Page Thumbnails (`MediaPipeline` + `MediaArtwork`)**: Render `.docx/.doc/.rtf/.odt` page 1 via `QLThumbnailGenerator` with an AppKit `NSAttributedString` + `NSTextStorage`/`NSLayoutManager`/`NSTextContainer` (`990 × 1400` A4) fallback on macOS so Office documents display real formatted paper thumbnails even without third-party QuickLook extensions installed.

### R2. Universal Media-Agnostic Version History & Anti-Mis-Send Primary Lock
- Expand `MediaKind.detect` `.document` extensions with `"doc", "wps", "et", "dps", "xlsx", "xls", "odt", "epub", "ofd"`.
- Add backward-compatible optional `versionStack: AssetVersionStackMetadata?` and `document: DocumentRichMetadata?` to `AssetRichMetadata` (preserving uppercase RFC-4122 UUIDs, Cocoa Reference Epoch timestamps, and `/.charkle/` HLC sync compatibility across all 5 platforms).
- **Zero Disk Intrusion**: Original files remain independent flat files in their library/open folders; no hidden wrapper directories are created on disk.
- **Active Drop / Import Prompt (`< 150ms`)**:
  - Detect version candidates via normalized Chinese office filename stems + 64-bit paragraph SimHash (`>= 0.45`), presenting a concise non-blocking banner (`归入《…》历史版本 (vN)？` with optional `修改人` + `备注（可选）`, `同时设为主版本`, and `归入版本` / `单独保留`).
- **Primary Version Lock (`isPinnedPrimary`)**:
  - Collapsed stacks across all gallery views, Notch Shelf, `⌘C`, and iOS Share sheets ALWAYS display and export the **`isPinnedPrimary` version** (appending `v5` onto a stack pinned at `v4` never silently overrides `v4`).
- **Synchronized `300pt` Pure-White Inspector (`历史版本`)**: Render the matching newest-first (`vN → v1`) vertical timeline spine inside `InspectorView` (shared 1:1 with Quick Look) and iOS detail inspector sheet, with zero repeated parent titles and zero `"Δ 0处"`.

### R3. Native Offline Document Parsing, Local FTS5 Pinyin Cache & Instant File Copy
- Implement pure native, offline, deterministic extraction in `Sources/CharkleCore` (zero `SwiftUI`, `#if os(macOS)` / `#if canImport(AppKit)` guarded for iOS 18+ compilation) covering `.docx`, `.xlsx`, `.pptx`, `.pdf`, `.md / .txt / .csv` (UTF-8 / UTF-16 / GB18030), and legacy `.doc / .wps / .xls / .et`.
- **Local `document_content_cache` -> `assets_fts`**: Cache structured blocks, full plain text, and `simhash64` in SQLite keyed by `(asset_id, content_hash)` and feed full text + Chinese Pinyin / initials into `assets_fts` **without bloating `/.charkle/ops/*.jsonl`**.
- **Universal `⌘J` -> `⌘C` Primary File Copy**: Copy the highlighted asset's Primary Version file URL directly to `NSPasteboard.general`.

### R4. Document Studio Single Header, Continuous Paper Diff, Split Sheet & Scheme B 2-Way Merge
- **Single Unified Top Header**: Format badge + document title + concise spec on the left; compact `vN ▾` version `Menu` (in reader mode) + monochromatic segmented control **`阅读 | 对比 | 合并`** + external open button on the right (eliminating the second horizontal version pill strip).
- **Mode 1 (`阅读` — Full-Bleed Paper Fidelity)**: Native `QLPreviewView` (macOS, with `dismantleNSView` `close()` teardown) and inline `QLPreviewController` (iOS/iPadOS) paired with a quiet floating vibrancy `原版版式` ⇄ `正文批注` / `数据表格` toggle, plus `.pdf` (`PDFKit`) and `.md / .txt` readers — zero instructional banners.
- **Mode 2 (`对比` — Continuous Paper Sheet & Lockstep 2-Column Split Sheet)**:
  - Slim diff control bar: `v1 ▾ → v2 ▾` pickers, compact monochromatic filter chips (`全部 / 数字 / 时间 / 表格 / 批注`), `审阅 | 双栏` (text/Word) or `文本 | 叠层 | 卷帘` (PDF) switcher, `仅看改动` toggle, and `↑ / ↓` (`J / K`) steppers.
  - **Continuous Paper Sheet (`审阅`)**: ONE centered elevated paper sheet (`maxWidth: 780`) where paragraphs sit in natural reading order with a `3pt` left margin status bar, inline word-level diff (or hanging-indent `minus.circle.fill` / `plus.circle.fill` selective-token rows), and inline **`"⋯ 省略未改动段落"`** fold dividers instead of separate boxy cards.
  - **Lockstep 2-Column Split Paper (`双栏`, macOS & iPad)**: Unified `maxWidth: 980` split sheet with sticky `− vBase | + vTarget` header and synchronized horizontal paragraph rows.
  - **Excel & PDF Diff**: Primary-Key aligned spreadsheet row/formula diff; PDF text/Vision OCR diff + Red-Cyan (`● 旧版 / ● 新版` compact legend) & Split Curtain visual diff without tutorial banners.
- **Mode 3 (`合并` — Interactive Continuous Paper Merge, Empty Default Note)**:
  - Slim template bar (`底稿：以新版为准 | 以旧版为准`), direct click/tap-to-pick `−` / `+` version rows on the continuous paper sheet, collapsible `"合并预览"`, empty default note `""` (`备注（可选）`), and `"保存为新版本"` CTA generating `vN+1` via lossless `.md/.txt` merge and **ZIP-preserving `.docx` surgical `<w:p>` replacement** (protecting complex merged tables, `fldComplex`, SmartArt, OLE, `.xlsx`, and `.pdf` as read-only).

---

## 3. Acceptance Criteria

1. **Zero-Warning Dual-Platform Build & Tests**:
   - `swift build` and `swift test` pass on macOS with zero warnings.
   - `xcodebuild -project ios/CharkleMobile.xcodeproj -scheme CharkleMobile -destination 'generic/platform=iOS Simulator' build` succeeds with zero errors.
2. **Design, Plain-Language & Purity Invariants**:
   - Pure neutral surfaces (`#F5F5F6` / `#FFFFFF` / `#F4F4F5` / `#1C1D20` / `#25262B`), zero warm-paper yellow hexes, zero violet hues (`OKLCH 270°–330°`), `.monospacedDigit()` on all counts/timestamps/deltas, zero coined jargon, zero tutorial banners, zero external competitor/inspiration product or author names, and zero personal absolute paths.
3. **Functional End-to-End Parity**:
   - `compactList` renders a unified hairline tracklist in 1-col mode (audio-only sparkbar, smart divider suppression) and a non-splitting Bento grid in 2-col mode, with the newest-first Vertical Version Timeline `.popover` matched 1:1 in the `300pt` Inspector.
   - Document Studio provides single-header `阅读 | 对比 | 合并`, real A4 Office previews/thumbnails, Continuous Paper Diff + Lockstep 2-Column Split Sheet, and byte-preserving Scheme B `.docx` 2-Way merge with empty default note.
