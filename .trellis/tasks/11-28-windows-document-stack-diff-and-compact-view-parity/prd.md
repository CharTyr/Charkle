# PRD: Windows Parity — Version History, Continuous Paper Diff, Scheme B 2-Way Merge & Fluent 2 Studio Compact View

> **Package**: `windows` (`windows/crates/charkle-core`, `windows/crates/charkle-platform-win`, `windows/src-tauri`, `windows/ui`) · **Priority**: `P1`  
> **Canonical Reference Spec**: [`docs/WINDOWS_DOCUMENT_SYNC_SPEC.md`](../../../docs/WINDOWS_DOCUMENT_SYNC_SPEC.md) · [`design.md`](./design.md) · [`implement.md`](./implement.md)  
> **Cross-Platform Wire Authority**: [`.trellis/spec/cross-platform/index.md`](../../spec/cross-platform/index.md) · **Apple Reference**: `Sources/CharkleCore/Contracts/DocumentAndVersionModels.swift`

---

## 1. Goal & Zero-Drift Parity Mandate

Deliver **100% byte-for-byte wire compatibility and 1:1 visual & interaction parity** on **Charkle for Windows (Tauri v2 + Rust + WebView2 + React 19 + Fluent 2)** with the upgraded Apple (macOS + iOS/iPadOS) Scheme B Document Studio, Universal 5th Gallery Layout Mode (`compactList`), Pure Neutral Surface Palette (`#F5F5F6` / `#FFFFFF` / `#F4F4F5` / `#1C1D20` / `#25262B`), and plain everyday Chinese terminology (`历史版本`, `全部 / 文档 / 媒体`, `单列 / 双列`, `阅读 / 对比 / 合并`, `合并预览`, `保存为新版本`).

All organization, archiving, and filtering MUST reuse Charkle's unified native skeleton (Folders, Tags, Smart Folders, Ratings, Inbox, Top-Edge Drop Shelf, `Ctrl+J` Jump Anywhere, and the synchronized pure-white `300px` Fluent 2 Inspector) with **zero mini-OA fragmentation**, **zero coined jargon or tutorial banners**, **100% offline deterministic execution (zero Cloud AI requirement)**, **zero disk wrapper folders**, and **zero file-corruption risk**.

### Strict Workspace & Android FFI Guardrails
1. **Windows-Only Edit Scope**: Keep all implementation edits strictly inside `windows/` (`windows/crates/charkle-core`, `windows/crates/charkle-platform-win`, `windows/src-tauri`, `windows/ui`). Do NOT modify `Sources/`, `Tests/`, `ios/`, `android/`, `web/`, or `windows/Cargo.toml` workspace `members`.
2. **Android UniFFI Compatibility (`android/rust/charkle-android-ffi`)**: `charkle-android-ffi` compiles directly against `windows/crates/charkle-core`. Keep `charkle-core` 100% OS-agnostic (zero Win32/Tauri imports), attach OS-specific legacy `.doc/.wps/.xls/.et` `IFilter` extraction via `LegacyDocumentTextProvider` with `NoopLegacyDocumentTextProvider` default, and keep `#[serde(default)]` on all new `AssetRichMetadata` fields.
3. **Win32 OLE & WebView2 Safety (`windows/AGENTS.md`)**: Never register/revoke OLE drop targets on child WebView2 HWNDs; run all SQLite, ZIP/XML parsing, `IFilter`, WinRT `OcrEngine`, and `CF_HDROP` clipboard operations off the WebView2 UI thread (`tokio::task::spawn_blocking`); stream PDFs, `.docx` originals, and thumbnails via `http://charkle-media.localhost/` (zero Base64 media over IPC).

---

## 2. Requirements

### R1. Lossless `/.charkle/` Wire Contract Parity (`charkle-core` & `swift_codec.rs`)
- **`GalleryLayoutMode`**: Add `RingGallery` (`"ringGallery"`) and `CompactList` (`"compactList"`, localized `"紧凑视图"`) to Rust `GalleryLayoutMode` (`models/core.rs`) and `'compactList'` to TypeScript `GalleryLayoutMode` (`domain.ts`).
- **`MediaKind::detect` Expansion**: Match Swift `MediaKind.detect` 1:1 across `"doc" | "docx" | "wps" | "et" | "dps" | "xlsx" | "xls" | "pptx" | "ppt" | "odt" | "ods" | "odp" | "epub" | "ofd" | "numbers"` (plus existing document extensions and MIME fallbacks).
- **`AssetRichMetadata` Optional Extensions**:
  - `version_stack: Option<AssetVersionStackMetadata>` (`groupID` via `upper_uuid`, `versionNumber >= 1`, `parentAssetID` via `upper_uuid_opt`, `versionLabel`, `editorName`, `changeNote`, `isPinnedPrimary`), plus exact `sorted_versions`, `resolve_primary_asset`, `newer_than_primary_count`, and `clean_display_descriptor` helpers (suppressing `"本机"`, `"初稿"`, `"修订版"`, and merge boilerplate).
  - `document: Option<DocumentRichMetadata>` with open-string `formatFamily`, `wordCount`, `pageCount`, `sheetNames`, `hasNativeRevisions`, `hasTextLayer`, and optional `diffSummary` (preserving 12-int `minimapBuckets` on the wire).
- **Round-Trip Sync Safety**: `SyncFields::diff` and `SyncFields::merge` (`swift_codec.rs`) MUST round-trip `richMetadata.versionStack` and `richMetadata.document` losslessly with sorted keys, Cocoa Reference Epoch dates, and uppercase RFC-4122 UUIDs.

### R2. SQLite `document_content_cache` & Full-Text Pinyin FTS5 Indexing (`library_db.rs`)
- Add local derived table `document_content_cache` in `LibraryDatabase::init_connection` keyed by `asset_id` + `content_hash` (`schema_version`, `structured_json`, `plain_text`, `simhash64` cast safely as signed `i64`, `updated_at`) with `ON DELETE CASCADE` from `assets(id)`.
- Feed cached `plain_text` + version metadata + `sheetNames` into `assets_fts` (`ocrText`, `pinyin`, `initials`) without writing full document text into `AssetRecord` or `/.charkle/ops/*.jsonl`.

### R3. Native Offline Document Parsers, Real A4 Thumbnails, Diff Radar & Scheme B 2-Way Merge (`charkle-core` + `charkle-platform-win`)
- **Zero-Heavy-Dep Native Rust Parsers** (`zip`, `quick-xml`, `pulldown-cmark`, `encoding_rs`, `flate2`): `.docx`, `.xlsx`, `.pptx`, `.odt`, `.epub`, `.pdf` (stream text + `hasTextLayer` scanned detection + WinRT `OcrEngine` fallback), `.md / .txt / .csv` (UTF-8 / UTF-16 / GB18030), and legacy `.doc / .wps / .xls / .et` (`Win32IFilterDocumentProvider` + OLE UTF-16LE fallback).
- **Real Office Page Thumbnails + Pure-Neutral Fallback Card**: Invoke `IShellItemImageFactory` (`1400 × 1400`) / offscreen `docx-preview` first-page capture FIRST so real formatted document pages are stored directly as `grid520` / `preview1400`; use pure-neutral `MediaArtwork::document_card` (`#F4F5F7` / `#FFFFFF`) only for plain-text/code files or headless fallback.
- **Version Engine, Diff Radar & Safe 2-Way Merge**: Exact Chinese office filename stem normalizer + 64-bit paragraph SimHash (`< 150ms`), `isPinnedPrimary` lock preservation, 2-stage paragraph alignment + Move detection, ordered-multiset Date-first High-Risk Radar, Excel PK row alignment, and byte-preserving `.docx` surgical `<w:p>` 2-Way synthesizer (`None` default `change_note` when left blank).

### R4. Tauri v2 IPC, `CF_HDROP` Primary Copy & Studio-Grade Fluent 2 UI (`windows/src-tauri` + `windows/ui`)
- Expose typed Tauri v2 IPC commands (`detect_version_stack_candidate`, `manage_version_stack`, `read_structured_document`, `compare_document_versions`, `synthesize_document_version`) and update `copy_assets_to_clipboard` + `start_outbound_drag` so collapsed version stacks export the **Primary Version's** file (`CF_HDROP`).
- **5th Gallery Mode — `GalleryCompactView.tsx` (1-Col Hairline Tracklist + 2-Col Non-Splitting Bento + Vertical Timeline Flyout)**:
  - Minimal sub-toolbar: `全部 / 文档 / 媒体` pills shown only on mixed collections (else quiet `"{N} 项"` count), plus icon-only `单列` (`TextBulletListLtr`) ⇄ `双列` (`Grid`) segmented control (`>= 680px`), zero tutorial banners, per-destination layout memory.
  - **1-Column Mode**: Unified elevated hairline table (`--bg-elevated`, `0.5px`/`1px` `leading: 60px` dividers suppressed around hovered/selected rows, inset `9px` rounded row highlight), crisp squircle artwork/page cover (`36×46px` docs / `38×44px` media with `0.5px` optical inner rim & print shadow; clean minimal `MD`/`TXT` sheet without cartoon red/blue bars), scoped OLE drag handle + open middle marquee-selection whitespace, quiet `vN/M ▾` capsule, **audio-only** waveform sparkbar (**zero 12-stick red/green document barcode**), concise spec, and right-aligned tabular timestamp column.
  - **2-Column Mode**: Tight `8px` **non-splitting** Bento grid of `58px`-tall horizontal tiles (`.pair` rows NEVER split on expand).
  - **Universal Vertical Version Timeline Flyout (`VersionTimelinePopover`)**: Clicking `vN/M ▾` in **either** 1-col or 2-col mode opens an anchored newest-first (`vN → v1`) vertical timeline Flyout (`历史版本` header + count + `对比差异` button, `1px` spine with `●` primary / `○` historical nodes, deduplicated labels, inline `Δ N` pill when `N > 0`, 1-click `Pin` primary action) — matched 1:1 in the pure-white `300px` `InspectorView.tsx` (`历史版本` section).
- **Active Drop Candidate Prompt & `Ctrl+J` -> `Ctrl+C` Copy**: Concise `.win-acrylic` prompt (`归入《…》历史版本 (vN)？`, `归入版本` / `单独保留`) and instant `Ctrl+C` Primary Version `CF_HDROP` copy in `JumpAnywhereModal.tsx`.
- **Document Studio (`DocumentStudioViewer.tsx` + `PdfDocumentViewer.tsx`)**:
  - **Single Unified Header**: Format badge + title + concise spec on the left; compact `vN ▾` dropdown (in reader mode) + monochromatic **`阅读 | 对比 | 合并`** segmented control + external open button on the right (zero second horizontal version pill strip).
  - **`阅读`**: Full-bleed offline **`docx-preview`** (`http://charkle-media.localhost/original/<uuid>`) + floating vibrancy `原版版式` ⇄ `正文批注` / `数据表格` toggle, `.xlsx` sheet grid, `.pdf`, and `.md/.txt` readers (zero instructional banners).
  - **`对比`**: Slim diff control bar (`v1 ▾ → v2 ▾`, monochromatic filter chips `全部 / 数字 / 时间 / 表格 / 批注`, `审阅 | 双栏` or `文本 | 叠层 | 卷帘`, `仅看改动`, `↑/↓` / `J/K`) above a **Continuous Paper Sheet** (`max-w-[780px]`, `3px` left margin status bar + inline word-level diff + `"⋯ 省略未改动段落"` inline fold dividers instead of boxy error cards), **Lockstep 2-Column Split Paper** (`max-w-[980px]`, sticky `− vBase | + vTarget` header), Excel PK row diff, and PDF Red-Cyan (`● 旧版 / ● 新版` compact legend) & Split Curtain visual diff.
  - **`合并`**: Interactive Continuous Paper Merge (`底稿：以新版为准 | 以旧版为准`, direct click-to-pick `−` / `+` rows on the paper sheet, collapsible `"合并预览"`, empty default note `""` with placeholder `"备注（可选）"`, primary CTA `"保存为新版本"`).

---

## 3. Acceptance Criteria

1. **Zero-Warning Rust, TypeScript & Packaging Gates**:
   - `cargo fmt --all -- --check`, `cargo clippy --workspace --all-targets -- -D warnings`, and `cargo test --workspace` pass in `windows/`; `cargo check` in `android/rust/charkle-android-ffi` remains unbroken; `npm run typecheck`, `npm test`, and `npm run build` pass in `windows/ui/`.
2. **Byte-for-Byte Cross-Platform Sync Parity**:
   - `AssetRecord` JSON fixtures containing `versionStack` and `document.diffSummary.minimapBuckets` round-trip through Rust `swift_codec.rs` with zero field loss, exact uppercase UUIDs, and exact Cocoa timestamps.
3. **Fluent 2 Pure Neutral Design, Plain Language & Purity Compliance**:
   - Pure neutral surfaces (`#F5F5F6` / `#FFFFFF` / `#F4F4F5` / `#1C1D20` / `#25262B`), zero warm-paper yellow cast, zero violet (`OKLCH 270°–330°`), zero `transition: all`, `tabular-nums`, `< 1%` idle CPU, zero coined jargon or tutorial banners, zero external competitor/author mentions, and zero local path leaks.
