# PRD: Windows Parity — Document Stack, Multi-Modal Diff, Scheme B 2-Way Merge & Fluent 2 Tactile Compact View

> **Package**: `windows` (`windows/crates/charkle-core`, `windows/crates/charkle-platform-win`, `windows/src-tauri`, `windows/ui`) · **Priority**: `P1`  
> **Canonical Reference Spec**: [`docs/WINDOWS_DOCUMENT_SYNC_SPEC.md`](../../../docs/WINDOWS_DOCUMENT_SYNC_SPEC.md) · [`design.md`](./design.md) · [`implement.md`](./implement.md)  
> **Cross-Platform Wire Authority**: [`.trellis/spec/cross-platform/index.md`](../../spec/cross-platform/index.md) · **Apple Reference**: `Sources/CharkleCore/Contracts/DocumentAndVersionModels.swift`

---

## 1. Goal & Zero-Drift Parity Mandate

Deliver **100% byte-for-byte wire compatibility and 1:1 functional parity** on **Charkle for Windows (Tauri v2 + Rust + WebView2 + React 19 + Fluent 2)** with the Apple (macOS + iOS/iPadOS) Scheme B Document Adaptation and Universal 5th Gallery Layout Mode (`compactList`).

All organization, archiving, and filtering MUST reuse Charkle's unified native skeleton (Folders, Tags, Smart Folders, Ratings, Inbox, Top-Edge Drop Shelf, `Ctrl+J` Jump Anywhere, and the synchronized `300px` Fluent 2 Inspector) with **zero mini-OA fragmentation**, **100% offline deterministic execution (zero Cloud AI requirement)**, **zero disk wrapper folders**, and **zero file-corruption risk**.

### Strict Workspace & Android FFI Guardrails
1. **Windows-Only Edit Scope**: Keep all implementation edits strictly inside `windows/` (`windows/crates/charkle-core`, `windows/crates/charkle-platform-win`, `windows/src-tauri`, `windows/ui`). Do NOT modify `Sources/`, `Tests/`, `ios/`, `android/`, `web/`, or `windows/Cargo.toml` workspace `members`.
2. **Android UniFFI Compatibility (`android/rust/charkle-android-ffi`)**: `charkle-android-ffi` compiles directly against `windows/crates/charkle-core`. Keep `charkle-core` 100% OS-agnostic (zero Win32/Tauri imports), attach OS-specific legacy `.doc/.wps/.xls/.et` `IFilter` extraction via a `charkle-core::traits` trait with a `NoopLegacyDocumentTextProvider` default builder on `MediaPipeline` / `LiveCharkleEngine`, and keep `#[serde(default)]` on all new `AssetRichMetadata` fields.
3. **Win32 OLE & WebView2 Safety (`windows/AGENTS.md`)**: Never register/revoke OLE drop targets on child WebView2 HWNDs; run all SQLite, ZIP/XML parsing, `IFilter`, WinRT `OcrEngine`, and `CF_HDROP` clipboard operations off the WebView2 UI thread (`tokio::task::spawn_blocking`); stream PDFs and thumbnails via `http://charkle-media.localhost/` (zero Base64 media over IPC).

---

## 2. Requirements

### R1. Lossless `/.charkle/` Wire Contract Parity (`charkle-core` & `swift_codec.rs`)
- **`GalleryLayoutMode`**: Add `RingGallery` (`"ringGallery"`) and `CompactList` (`"compactList"`, localized `"紧凑视图"`) to Rust `GalleryLayoutMode` (`models/core.rs`) and `'compactList'` to TypeScript `GalleryLayoutMode` (`domain.ts`).
- **`MediaKind::detect` Expansion**: Match Swift `MediaKind.detect` 1:1 by recognizing `"doc" | "docx" | "wps" | "et" | "dps" | "xlsx" | "xls" | "pptx" | "ppt" | "odt" | "ods" | "odp" | "epub" | "ofd" | "numbers"` (alongside existing `"pdf" | "md" | "markdown" | "txt" | "rtf" | "key" | "pages" | "json" | "yaml" | "yml" | "toml" | "csv"`) and MIME types containing `"officedocument"`, `"msword"`, `"ms-excel"`, `"ms-powerpoint"`, `"opendocument"`, or `"application/epub+zip"`.
- **`AssetRichMetadata` Optional Extensions**:
  - `version_stack: Option<AssetVersionStackMetadata>` (`#[serde(rename = "versionStack", default, skip_serializing_if = "Option::is_none")]`) with `groupID` (`upper_uuid`), `versionNumber` (`>= 1`), `parentAssetID` (`upper_uuid_opt`), `versionLabel`, `editorName`, `changeNote`, `isPinnedPrimary` (`default = false`), plus exact `sorted_versions`, `resolve_primary_asset`, and `newer_than_primary_count` helpers.
  - `document: Option<DocumentRichMetadata>` (`#[serde(default, skip_serializing_if = "Option::is_none")]`) with open-string `formatFamily` (`docx | xlsx | pptx | pdf | markdown | plainText | legacyOffice | epub | ofd | other`), `wordCount`, `pageCount`, `sheetNames`, `hasNativeRevisions`, `hasTextLayer`, and optional `diffSummary` (`comparedToAssetID` via `upper_uuid`, `addedBlocks`, `removedBlocks`, `modifiedBlocks`, `movedBlocks`, `highRiskNumberChanges`, `highRiskDateChanges`, and 12-int `minimapBuckets` clamped to `0..=2`).
- **Round-Trip Sync Safety**: `SyncFields::diff` and `SyncFields::merge` (`swift_codec.rs`) MUST round-trip `richMetadata.versionStack` and `richMetadata.document` losslessly with sorted keys, Cocoa Reference Epoch dates, and uppercase RFC-4122 UUIDs, while tolerating missing fields and unknown future `formatFamily` tokens without rolling back `apply_op_shard`.

### R2. SQLite `document_content_cache` & Full-Text Pinyin FTS5 Indexing (`library_db.rs`)
- Add strictly local derived table `document_content_cache` in `LibraryDatabase::init_connection` keyed by `asset_id` + `content_hash` (`schema_version`, `structured_json`, `plain_text`, `simhash64`, `updated_at`) with `ON DELETE CASCADE` from `assets(id)`.
- Automatically invalidate/recompute cached entries whenever `assets.content_hash` or `schema_version` changes.
- Feed cached `plain_text` (plus `versionStack.editorName` / `versionStack.changeNote` / `document.sheetNames`) into `LibraryDatabase::search_fields` -> `search_text::index` and `search_text::pinyin` -> `assets_fts` (`ocrText`, `pinyin`, `initials`) so `Ctrl+F` and `Ctrl+J` recall Chinese/English body text and Pinyin initials instantly **without writing full document text into `AssetRecord` or `/.charkle/ops/*.jsonl`**.

### R3. Native Offline Document Parsers, High-Readability Cards, Diff Radar & Scheme B 2-Way Merge (`charkle-core` + `charkle-platform-win`)
- **Zero-Heavy-Dep Native Rust Parsers** (reusing installed `zip`, `quick-xml`, `pulldown-cmark`, `encoding_rs`, `flate2`):
  - **`.docx`**: Safe bounded ZIP reader + `quick-xml` streaming parser over `word/document.xml`, `word/comments.xml`, and `docProps/core.xml` (`cp:lastModifiedBy`), extracting headings, paragraphs, embedded tables (`<w:tbl>`), native `<w:ins>` / `<w:del>` revisions, comments, red-header styling hints, `xmlParagraphIndex`, and flagging `isProtectedComplex` on `<w:fldChar>`, `<w:instrText>`, `<w:drawing>`/SmartArt, `<mc:AlternateContent>`, `<w:pict>`, `<o:OLEObject>`, and merged `<w:tbl>` (`<w:vMerge>` / `<w:gridSpan>`).
  - **`.xlsx`**: Parse `xl/workbook.xml`, `xl/ _rels/workbook.xml.rels`, `xl/sharedStrings.xml`, and `xl/worksheets/sheet*.xml` (sheet names, row numbers, A1 column coordinate decoding, shared/inline/numeric/boolean values, and `<f>` formulas).
  - **`.pptx`**: Extract slide titles & text runs across `ppt/slides/slide*.xml`.
  - **`.pdf`**: Native lightweight PDF stream/text-operator (`BT..ET`, `Tj`, `TJ`, `FlateDecode`) extractor + `hasTextLayer` scanned-PDF detector (paired with `pdfjs-dist` rendering in UI and WinRT `OcrEngine` fallback when `useOcrIfScanned == true`).
  - **`.md / .txt / .csv`**: BOM + UTF-8 strict check -> UTF-16LE/BE -> `encoding_rs::GB18030` decoding; Markdown block extraction via `pulldown-cmark`.
  - **Legacy `.doc / .wps / .xls / .et`**: Dedicated Win32 `IFilter` (`LoadIFilter` / `IFilter::Init` / `GetChunk` / `GetText` on an isolated blocking STA worker thread with panic & timeout guards) in `charkle-platform-win::ifilter`, injected into `charkle-core` via `LegacyDocumentTextProvider`.
- **High-Readability Document Poster Card (`MediaArtwork`)**: Upgrade `.document` procedural card rendering (`artwork.rs`) to match macOS: crisp top page/spreadsheet/red-header preview + clean bottom paper strip displaying format badge, 2-line title, and version indicator.
- **Version Stack Engine**: Exact Chinese office filename stem normalizer + 64-bit paragraph SimHash (`< 150ms`), `isPinnedPrimary` preservation when newer versions join, and automatic `diffSummary` + 12-bucket `minimapBuckets` computation against the previous version.
- **Multi-Modal Diff & High-Risk Radar**: Paragraph hash/SimHash alignment with Move detection (`movedFromIndex` / `movedToIndex`), CJK word/char inline diff tokens, deterministic High-Risk Number/Currency/Percentage & Date/Deadline regex radar, Excel Primary-Key column auto-detection & row alignment, and scanned PDF WinRT `OcrEngine` OCR diff.
- **Scheme B Safe 2-Way Synthesizer**: Lossless `.md/.txt` synthesis + byte-preserving `.docx` template ZIP clone with surgical plain `<w:p>` replacement, strict `quick-xml` + `zip::ZipArchive` post-synthesis integrity verification, and automatic `vN+1` insertion into the library and Version Stack without overwriting originals.

### R4. Tauri v2 IPC, `CF_HDROP` WeChat Copy & Fluent 2 React UI (`windows/src-tauri` + `windows/ui`)
- Expose typed Tauri v2 IPC commands (`detect_version_stack_candidate`, `manage_version_stack`, `read_document_structured`, `compare_document_versions`, `synthesize_document_version`) with complete `InMemoryMockTransport` parity in `windows/ui/src/api/transport.ts`, and update `copy_assets_to_clipboard` + `start_outbound_drag` (`native.rs`) so collapsed Version Stacks always export the **Primary Version's** local original file (`CF_HDROP`, `\\?\`-stripped for WeChat PC).
- **5th Gallery Mode — `GalleryCompactView.tsx` (Fluent 2 + V2 Reference Parity)**:
  - Add `'compactList'` (`紧凑视图`, Fluent `TextBulletListLtr` / `AppsList` icon, shortcut `5` / `Ctrl+5`) to `TopFilterCapsule.tsx`, `SettingsPanesFoundation.tsx`, `OnboardingStudio.tsx`, and `App.tsx`, with **per-destination layout memory** in `coordinatorStore.ts`.
  - Switchable **2-Column Tactile Index Grid (`双列索引卡`, auto 1-col `< 680px` matching `CompactIndexLayoutMetrics.twoColumnMinViewportWidth`) ⇄ 1-Column Folio Strip (`单列折页条`)**, virtualized for 60/120Hz scrolling.
  - **3D Micro-Folio Hover Fan-Out** (`@media (hover: hover) and (pointer: fine)`, disabled under Reduced Motion), **12-Segment Diff Minimap**, and **Inline Expandable Revision Rail** (`主版 v4 · +1 新版` -> `v3` ── `Δ 6处 · 数字1` ── `v4 主版` ── `Δ 3处 · 数字2` ── `v5`, 1-click `设为主版` & `Δ` Quick Look Diff launch).
  - Full selection (`Shift`/`Ctrl`) + **Explorer/Finder-style Rubber-Band Marquee Box Multi-Selection** (dragging from stage margins, row/column gaps, or open middle whitespace of 1-column strips with outbound OLE drag scoped strictly to the left micro-folio + intrinsic title block), `↑/↓` `0ms` navigation, unmodified `Space` Quick Look toggle, outbound Win32 OLE drag (`PointerDragContext` -> `startOutboundDrag`), and drag-onto-card stack merge.
- **Active Drop Stacking Banner & Inspector Section**:
  - When files are dropped onto `TopEdgeDropShelf.tsx` or `GalleryView.tsx` / `FolderTree.tsx`, invoke `detect_version_stack_candidate` and surface a non-blocking Fluent 2 `.win-acrylic` prompt bar with pre-filled `editorName` + 1-line `changeNote` (`Enter` stacks & routes into target folder; `Esc` / `独立保留` keeps separate).
  - Add `版本叠` (`CharkleDisclosureGroup`) in `InspectorView.tsx` (shared 1:1 between Gallery and Quick Look).
- **Universal `Ctrl+J` -> `Ctrl+C` File Copy**: In `JumpAnywhereModal.tsx`, pressing `Ctrl+C` when no input text is selected (plus explicit hover `拷贝文件` button) copies the highlighted asset's Primary Version file via `copyAssetsToClipboard` (`CF_HDROP`) with toast confirmation for instant `Ctrl+V` into WeChat PC.
- **Quick Look Document Studio (`DocumentStudioViewer.tsx` + `PdfDocumentViewer.tsx`)**:
  - **True-Layout `.docx` Reader (`原版版式` ⇄ `结构与批注`)** + clean native readers for `.xlsx` (sheet tabs + sticky header grid), `.pdf` (`pdfjs-dist`), and `.md/.txt`: `.docx` defaults to pure offline client-side **`docx-preview`** rendering real A4 margins, CJK 2-char indents, fonts, official red headers, embedded `word/media/*` images, and merged tables from original bytes via `http://charkle-media.localhost/original/<uuid>`, with a 1-click capsule toggle to **`结构与批注`** (structured blocks, native track-change pills, and comment cards).
  - Version Stack top bar + `对比差异` mode: High-Risk Radar filter pills (`全部改动`, `数字变动`, `日期时间`, `表格变动`, `原生修订/批注`, using pure number icons rather than `¥`), `仅看改动段落` toggle, `J/K` jump, Word Inline & Side-by-Side sync-scroll diff, Excel PK column selector & cell/formula diff, **`pdfjs-dist` dual-canvas Red-Cyan blend & interactive Split Curtain Wipe slider** (plus 1-click WinRT OCR diff for scanned PDFs), and Scheme B 2-Way merge (`按差异合成新版本` -> `净版预览` -> `生成净版 vN+1`) using hanging-indent `−` (`DismissCircle` / minus badge) & `+` (`AddCircle` / plus badge) icon-gutter rows with selective `inlineTokens` span highlighting (forbidding `"旧版："`/`"新版："` text prefixes or full-paragraph solid green/strikethrough).

---

## 3. Acceptance Criteria

1. **Zero-Warning Rust, TypeScript & Packaging Gates**:
   - `cargo fmt --all -- --check`, `cargo clippy --workspace --all-targets -- -D warnings`, and `cargo test --workspace` pass in `windows/`.
   - `cargo check` in `android/rust/charkle-android-ffi` remains unbroken.
   - `npm run typecheck`, `npm test` (including `document-stack-compact-view.test.tsx`), and `npm run build` pass in `windows/ui/`.
2. **Byte-for-Byte Cross-Platform Sync Parity**:
   - `AssetRecord` JSON fixtures produced by macOS `CharkleCore` containing `versionStack` and `document.diffSummary.minimapBuckets` round-trip through Rust `swift_codec.rs` (`SyncFields::diff` / `SyncFields::merge` / `apply_op_shard`) with zero field loss, exact uppercase UUIDs, and exact Cocoa timestamps.
3. **Fluent 2 Design, Accessibility & Purity Compliance**:
   - Light/Dark themes, `prefers-reduced-transparency` / `data-backdrop="solidFallback"` solid fallbacks, `prefers-reduced-motion` / `data-animations="disabled"`, Studio Cobalt vs Windows System Accent, zero violet (`OKLCH 270°–330°`), zero `transition: all`, zero `ease-in` exits, `tabular-nums`, `< 1%` idle CPU, zero external competitor/author mentions, and zero local path leaks.
