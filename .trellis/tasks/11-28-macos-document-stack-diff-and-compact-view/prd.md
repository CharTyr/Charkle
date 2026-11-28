# PRD: Apple Dual-Platform (macOS & iOS/iPadOS) Document Stack, Multi-Modal Diff, Scheme B 2-Way Merge & Tactile Compact View

> **Scope**: `Sources/CharkleCore/`, `Sources/CharkleApp/`, `Sources/CharkleCanvas/`, `Tests/CharkleTests/`, `ios/CharkleMobile/`, `ios/CharkleShareExtension/` · **Priority**: `P1`  
> **Companion Windows Parity Handoff**: [`.trellis/tasks/11-28-windows-document-stack-diff-and-compact-view-parity/`](../11-28-windows-document-stack-diff-and-compact-view-parity/) · [`docs/WINDOWS_DOCUMENT_SYNC_SPEC.md`](../../../docs/WINDOWS_DOCUMENT_SYNC_SPEC.md)

---

## 1. Goal & Zero-Fragmentation Product Philosophy

Extend Charkle on **macOS 15+** and **iOS / iPadOS 18+** (sharing `Sources/CharkleCore` directly) to handle multi-round office document revisions (`.docx`, `.xlsx`, `.pptx`, `.pdf`, `.md`, `.txt`, plus legacy `.doc/.wps/.xls/.et`) and dense multi-media collections **without creating a separate mini-OA silo**.

Every organizational concept — Folders, Tags, Smart Folders, Ratings, Inbox, Notch Shelf / Share Extension, `⌘J` Jump Anywhere, and the `300pt` synchronized Inspector — remains **100% unified across all 8 `MediaKind`s**. Document and multi-version workflows grow organically from four native touchpoints under **Scheme B (100% offline, deterministic, zero-AI, zero-corruption boundaries)**:

1. **Touchpoint 1 — 5th Universal Gallery Mode (`GalleryLayoutMode.compactList`) & High-Readability Document Cards**
2. **Touchpoint 2 — Media-Agnostic Version Stack (`AssetRichMetadata.versionStack`) & Anti-Mis-Send Primary Lock (`isPinnedPrimary`)**
3. **Touchpoint 3 — Native Structured Document Parsing, Derived Full-Text Pinyin Cache & Instant Primary File Copy (`⌘J` -> `⌘C`)**
4. **Touchpoint 4 — Quick Look / Detail Stage Document Readers, High-Risk Radar, Visual PDF Diff & Scheme B 2-Way Synthesis**

---

## 2. Requirements

### R1. 5th Universal Gallery Layout Mode (`compactList`) & Readable Masonry Document Cards
- Add `.compactList` (`rawValue = "compactList"`, `localizedLabel = "紧凑视图"`, SF Symbol `list.bullet`, macOS shortcut `5`) to `GalleryLayoutMode`, wired into the top layout switcher, Onboarding, Settings default layout picker, and **per-destination layout mode memory** (e.g., per folder / Inbox, falling back to global default).
- Render virtualized tactile index cards across all 8 `MediaKind`s:
  - **macOS (`CompactIndexGalleryView`)**: Toggleable **2-Column Tactile Index Grid (`双列索引卡`, responsive to 1-col on narrow widths) ⇄ 1-Column Folio Strip (`单列折页条`)**.
  - **iOS / iPadOS (`MobileCompactIndexGalleryView`)**: Adaptive **1-Column Folio Cards** on iPhone compact width and **2-Column Bento Index Grid** on iPad regular width.
  - **3D Micro-Folio Left Artifact**: Version stacks (`versionCount > 1`) render layered paper sheets that subtly fan open on fine-pointer hover (`rotation3DEffect`, respecting `accessibilityReduceMotion`); single documents show red-header / spreadsheet / page micro-skeletons; images and design files show crisp thumbnails with a bottom palette bar; audio shows a miniature waveform.
  - **12-Segment Diff Minimap**: Versioned documents display a 12-bucket change spectrum (`0` = neutral unchanged, `1` = green added/modified, `2` = red high-risk number/currency/date change) paired with `.monospacedDigit()` timestamp.
  - **Inline Expandable Revision Rail**: Clicking/tapping a version pill (`主版 v4 · +1 新版` or `主版 v4 · 共N版`) expands an inline horizontal revision rail (`v3` ── `Δ 6处 · 数字1` ── `v4 主版` ── `Δ 3处 · 数字2` ── `v5`), supporting 1-click/tap **`设为主版`** (`isPinnedPrimary`) and 1-click/tap on **`Δ`** bridge pills to open Quick Look / `AssetDetailView` directly in Diff mode.
  - **Full Gallery Interaction Invariants**: Single, `⇧` range, `⌘` multi-selection, and rubber-band marquee box multi-selection (dragging from stage margins, gaps, or open middle strip whitespace); batch action bar; `↑ / ↓` `0ms` keyboard navigation; unmodified `Space` Quick Look toggle (masking `[.command, .option, .control, .shift]` via `WindowKeyEventBridge`); drag-out of the **Primary Version** original file (to WeChat, Finder, or Moodboard); and drag-drop onto a card to merge into a Version Stack.
- **High-Readability Masonry Document Poster Cards (`MediaArtwork`)**: Replace flat grey placeholders with a clean top page/spreadsheet/red-header preview + crisp bottom paper footer showing format accent badge, clean title, and version indicator.

### R2. Universal Media-Agnostic Version Stack & Anti-Mis-Send Primary Lock
- Expand `MediaKind.detect` `.document` extensions with `"doc", "wps", "et", "dps", "xlsx", "xls", "odt", "epub", "ofd"`.
- Add backward-compatible optional `versionStack: AssetVersionStackMetadata?` and `document: DocumentRichMetadata?` to `AssetRichMetadata` (preserving uppercase RFC-4122 UUIDs, Cocoa Reference Epoch timestamps, and `/.charkle/` HLC sync compatibility across all 5 platforms).
- **Zero Disk Intrusion**: Original files remain independent flat files in their library/open folders; no hidden wrapper directories are created on disk.
- **Active Drop / Import Stacking Prompt (`< 150ms`)**:
  - When dropping files into **Notch Shelf** or **Gallery / Folder** on macOS (or importing via `CaptureSheetView` / Files picker / iPad drag-drop on iOS/iPadOS), run `detectVersionStackCandidate` using normalized Chinese office filename stems (stripping `(1)`, `（2）`, `副本`, `_v2`, `初稿/修改稿/终稿/最终版`, dates, and extracting editor suffix hints such as `-张主任改`) plus 64-bit paragraph SimHash similarity (`>= 0.45`).
  - On match, present a lightweight non-blocking prompt banner (`叠入《…》作为 vN？`) pre-filling `editorName` (from filename suffix or OOXML `cp:lastModifiedBy`) + 1-line optional `changeNote`, routing automatically into the target stack's owning folder on confirmation.
  - Support manual drag-merge onto existing cards and context-menu actions (`合并为版本叠`, `设为主版本`, `拆出为独立素材`).
- **Primary Version Lock (`isPinnedPrimary`)**:
  - Collapsed stacks in Masonry, Justified, Filmstrip, Ring, Compact View, Notch Shelf, and iOS Share sheets ALWAYS display, drag out, and copy/share the **`isPinnedPrimary` version** (or highest `versionNumber` when none is pinned).
  - Appending `v5` onto a stack whose primary version is pinned at `v4` MUST NEVER silently override `v4`; instead, surface a subtle `+1 新版` badge until the user explicitly promotes `v5`.
- **Synchronized `300pt` Inspector Section**: Add `版本叠` using `CharkleDisclosureGroup` (never bare `DisclosureGroup`) in `InspectorView` (shared 1:1 with Quick Look) and iOS detail inspector sheet.

### R3. Native Offline Document Parsing, Local FTS5 Pinyin Cache & Instant File Copy
- Implement pure native, offline, deterministic extraction in `Sources/CharkleCore` (zero `SwiftUI`, `#if os(macOS)` / `#if canImport(AppKit)` guarded for iOS 18+ compilation):
  - **`.docx`**: Safe ZIP reader + `Foundation.XMLParser` over `word/document.xml`, `word/comments.xml`, and `docProps/core.xml` (`cp:lastModifiedBy`), extracting headings, body paragraphs, embedded tables, native `<w:ins>` / `<w:del>` revisions, comments, and flagging protected complex blocks (`fldComplex`, SmartArt, OLE, `vMerge`).
  - **`.xlsx`**: `xl/workbook.xml`, `xl/sharedStrings.xml`, `xl/worksheets/sheet*.xml` (sheet names, row/column cells, cached values, and `<f>` formulas).
  - **`.pptx`**: Slide text extraction (`ppt/slides/slide*.xml`).
  - **`.pdf`**: `PDFKit` full-page text extraction + `hasTextLayer` scanned-document flag.
  - **`.md / .txt / .csv`**: Automatic UTF-8 / UTF-16 / GB18030 (`CFStringEncoding` `0x0632`) decoding.
  - **Legacy `.doc / .wps / .xls / .et`**: `#if os(macOS)` `NSAttributedString` / `/usr/bin/textutil` silent plain-text fallback (graceful metadata-only fallback on iOS).
- **Local `document_content_cache` -> `assets_fts`**: Cache structured blocks, full plain text, and `simhash64` in SQLite keyed by `(asset_id, content_hash)` and feed full text + Chinese Pinyin / initials into `assets_fts` **without bloating `/.charkle/ops/*.jsonl`**.
- **Universal `⌘J` -> `⌘C` Primary File Copy**: In `JumpAnywhereView`, pressing `⌘C` copies the highlighted asset's original file URL (for stacks, the Primary Version file) directly to `NSPasteboard.general` with toast confirmation for 3-second paste into WeChat.

### R4. Quick Look / Detail Stage Readers, High-Risk Radar, Visual PDF Diff & Scheme B 2-Way Synthesis
- **True-Layout Office Preview + Structured Readers (`原版版式` ⇄ `结构与批注`)**: Render `.docx`, `.doc`, `.pptx`, `.ppt`, `.rtf`, `.pages`, `.key` (plus optional toggle on `.xlsx`) with native `OfficeImport` true paper layout (`QLPreviewView` on macOS with `dismantleNSView` `close()` teardown; inline `QLPreviewController` on iOS/iPadOS) alongside a 1-click **`原版版式` ⇄ `结构与批注`** capsule toggle for structured blocks, formulas, and comments, plus `.pdf` (`PDFKit`) and `.md / .txt` (rendered / raw toggle).
- **Multi-Modal Diff Stage (`对比差异`)**:
  - **High-Risk Radar Capsule Filters**: `全部改动`, `数字变动`, `日期时间`, `表格变动`, `原生修订/批注` (using `number.circle` rather than `¥`) + **`仅看改动段落`** collapse toggle + `J / K` hunk navigation (macOS).
  - **Word / Text Diff & Icon-Gutter Selective Highlighting**: Paragraph alignment with block Move detection, Chinese word/character inline diff tokens, Side-by-Side synchronized view (macOS), embedded table cell diffs, comment changes, and hanging-indent `minus.circle.fill` / `plus.circle.fill` gutter badges with selective `inlineTokens` span highlighting (no `"旧版："`/`"新版："` text prefixes or full-paragraph solid green/strikethrough).
  - **Excel (`.xlsx`) Diff**: Sheet change badges + automatic/selectable Primary-Key column row alignment (preventing cascading false-red shifts on inserted rows) + `旧值 → 新值` and formula diff highlights.
  - **PDF (incl. Scanned Red-Header / Signed Docs)**: Text-layer diff + Apple `Vision` (`VNRecognizeTextRequest`) offline OCR diff + **Visual Page Overlay Diff** (Red-Cyan difference blend & interactive Split Curtain Wipe slider on both macOS and iOS/iPadOS).
- **Scheme B Zero-Corruption 2-Way Synthesis (`按差异合成新版本`)**:
  - Default to newer version as template; allow per-hunk **`保留旧版` / `采用新版` / `当场微调`** + **`净版预览`** -> generates new `vN+1` file attached to the same Version Stack (never overwriting originals).
  - **Lossless `.md / .txt`** synthesis + **ZIP-preserving `.docx` surgical plain-paragraph `<w:p>` replacement** (preserving `styles.xml`, red headers, headers/footers, numbering, and embedded images byte-for-byte, validating XML & ZIP integrity).
  - **Hard Safety Guardrail**: Complex merged tables (`vMerge`/`gridSpan`), `fldComplex`, SmartArt, OLE, `.xlsx`, and `.pdf` are strictly marked **`受保护结构（只读对比）`** with a 1-click **`用默认应用打开`** action.

---

## 3. Acceptance Criteria

1. **Zero-Warning Dual-Platform Build & Tests**:
   - `swift build` and `swift test` pass on macOS with zero warnings (including `DocumentCoreAndVersionStackTests` and `CompactGalleryAndDocumentUITests`).
   - `xcodebuild -project ios/CharkleMobile.xcodeproj -scheme CharkleMobile -destination 'generic/platform=iOS Simulator' build` succeeds with zero errors (`Sources/CharkleCore` has zero `import SwiftUI` and zero unguarded macOS-only APIs).
2. **Design, Accessibility & Purity Invariants**:
   - Zero violet hues (`OKLCH 270°–330°`), `.monospacedDigit()` on all counts/timestamps/deltas, every macOS `.menuStyle(.borderlessButton)` includes `.menuIndicator(.hidden)` & `.fixedSize()`, every SF Symbol verified non-nil on macOS, collapsible sections use `CharkleDisclosureGroup`, unmodified `Space` masks `[.command, .option, .control, .shift]`, full-bleed overlays use `.ignoresSafeArea`.
   - Zero external competitor/inspiration product or author names, and zero personal absolute paths anywhere in tracked files.
3. **Functional End-to-End Parity**:
   - All 8 media kinds render smoothly in `compactList` (2-col Bento / 1-col Folio) with per-destination layout memory, hover 3D micro-folio fan-out, 12-segment Diff Minimap, and inline Revision Rail.
   - Dropping revised office/design files prompts `< 150ms` version stacking; pinning `v4` as Primary Version prevents `v5` from overriding drag-out / `⌘C` / iOS Share exports.
   - High-Risk Radar catches currency/percentage/number and date edits deterministically; Excel PK row alignment tolerates row insertions without misalignment; scanned PDFs support offline OCR + Red-Cyan / Split Curtain visual comparison; Scheme B `.docx` 2-Way merge preserves non-body ZIP entries byte-for-byte and opens cleanly in Word/WPS.
