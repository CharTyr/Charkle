# Implementation Plan: Windows Parity — Document Stack, Multi-Modal Diff, Scheme B 2-Way Merge & Fluent 2 Tactile Compact View

> **Task**: `.trellis/tasks/11-28-windows-document-stack-diff-and-compact-view-parity/`  
> **Companion Docs**: [`prd.md`](./prd.md) · [`design.md`](./design.md) · [`docs/WINDOWS_DOCUMENT_SYNC_SPEC.md`](../../../docs/WINDOWS_DOCUMENT_SYNC_SPEC.md)  
> **Scope**: Strictly `windows/` (`windows/crates/*`, `windows/src-tauri/*`, `windows/ui/*`). Never edit `Sources/`, `Tests/`, `ios/`, `android/`, `web/`, or `windows/Cargo.toml` workspace members.

---

## 0. Pre-Start Checklist (Before Running `task.py start`)

1. Validate task context manifests:
   ```powershell
   python ./.trellis/scripts/task.py validate 11-28-windows-document-stack-diff-and-compact-view-parity
   ```
2. Activate task:
   ```powershell
   python ./.trellis/scripts/task.py start 11-28-windows-document-stack-diff-and-compact-view-parity
   ```
3. Read `docs/WINDOWS_DOCUMENT_SYNC_SPEC.md`, `.trellis/spec/cross-platform/index.md`, `.trellis/spec/windows/fluent2-design-system.md`, and `windows/AGENTS.md` in full before editing code.

---

## Wave 1 — Wire Models, SQLite `document_content_cache` & Native Offline Parsers (`charkle-core` + `charkle-platform-win`)

### Checklist
- [ ] **1.1 Wire & Domain Contracts (`windows/crates/charkle-core/src/models/document.rs` & `core.rs`)**:
  - Create `models/document.rs` (re-exported from `models/mod.rs`) implementing `AssetVersionStackMetadata` (`sorted_versions`, `resolve_primary_asset`, `newer_than_primary_count`), `DocumentFormatFamily`, `DocumentDiffSummary` (`normalize_minimap_buckets`, `compact_bridge_label`), `DocumentRichMetadata`, `StructuredDocumentPayload`, `VersionStackCandidate`, `VersionStackMutation`, `DocumentComparisonReport`, and `DocumentMergeDecision` per `docs/WINDOWS_DOCUMENT_SYNC_SPEC.md` §1.2.
  - Extend `AssetRichMetadata` (`models/core.rs:835`) with `version_stack` and `document`; add `RingGallery` and `CompactList` to `GalleryLayoutMode` (`models/core.rs:1670`); expand `MediaKind::detect` (`models/core.rs:63`) and `MediaPipeline::mime_type` (`media/pipeline.rs:305`) with all office/ebook extensions & MIME checks.
- [ ] **1.2 Local Derived SQLite Cache & FTS5 Pinyin Indexing (`db/library_db.rs`)**:
  - Add `document_content_cache` DDL in `LibraryDatabase::init_connection` (`library_db.rs:181`), storing `simhash64` via lossless `u64 <-> i64` bit-cast.
  - Implement `get_document_cache`, `upsert_document_cache`, and `find_simhash_candidates` on `LibraryDatabase`, feeding bounded `plain_text` + `version_stack` / `document` metadata into `assets_fts` (`search_text::index` + `search_text::pinyin`) without writing full text into `AssetRecord` or `sync_ops`.
  - Extend `SmartFolderRule::matches` and `LibraryDatabase::quick_jump` to recall document body hits, sheet names, and version editor/notes.
- [ ] **1.3 Native Document Parsers, Win32 `IFilter` & Poster Artwork (`media/document_parser.rs`, `artwork.rs`, `charkle-platform-win/src/ifilter.rs`)**:
  - Add `LegacyDocumentTextProvider` + `NoopLegacyDocumentTextProvider` in `charkle-core/src/traits/mod.rs` and `Win32IFilterDocumentProvider` (with OLE UTF-16LE clean-machine fallback, `spawn_blocking`, and `catch_unwind`) in `charkle-platform-win/src/ifilter.rs`.
  - Implement bounded native `.docx`, `.xlsx`, `.pptx`, `.odt`, `.epub`, `.pdf` (text + `has_text_layer`), and UTF-8/UTF-16/GB18030 `.md/.txt/.csv` parsers in `media/document_parser.rs`.
  - Upgrade `MediaArtwork::document_card` (`media/artwork.rs`) and wire `MediaPipeline` ingest (`media/pipeline.rs`) to populate `DocumentRichMetadata`, `document_content_cache` (`ocr_text <= 2_000` chars, `text_excerpt <= 1_200` chars), and crisp `900×1240` document poster thumbnails.

### Wave 1 Gate
```powershell
cd windows && cargo clippy --workspace --all-targets -- -D warnings && cargo test -p charkle-core -p charkle-platform-win
cd ../android/rust/charkle-android-ffi && cargo check
```

---

## Wave 2 — Version Stack Engine, Multi-Modal Diff Radar, Scheme B Synthesizer & Tauri IPC (`charkle-core` + `src-tauri`)

### Checklist
- [ ] **2.1 Version Stack & Multi-Modal Diff Engine (`media/version_stack.rs`, `media/document_diff.rs`)**:
  - Implement Chinese office filename stem normalizer + 64-bit paragraph SimHash matcher (`< 150ms`), `manage_version_stack` (`join`, `create`, `setPrimary`, `unstack`, `updateMeta`) preserving `isPinnedPrimary` when newer versions join, and auto-computing `diffSummary` + 12-bucket `minimapBuckets`.
  - Implement paragraph anchor + Move detection + CJK word/char inline diff tokens + deterministic High-Risk Number/Currency/Percentage & Date/Deadline radar + Excel Primary-Key column auto-detection & row alignment + WinRT `OcrEngine` scanned PDF OCR hook.
- [ ] **2.2 Scheme B Safe 2-Way Synthesizer (`media/document_merge.rs`, `engine.rs`)**:
  - Implement lossless `.md/.txt` 2-Way merge and byte-preserving `.docx` ZIP surgical `<w:p>` replacement (preserving `<w:pPr>`, `<w:rPr>`, `styles.xml`, headers/footers, numbering, and media; enforcing `quick_xml` + `ZipArchive` validation; locking `is_protected_complex` blocks), inserting `vN+1` into the library & stack.
- [ ] **2.3 Tauri v2 IPC Commands & Primary-Resolved Copy/Drag (`windows/src-tauri/src/commands/documents.rs`, `native.rs`, `lib.rs`)**:
  - Register `detect_version_stack_candidate`, `manage_version_stack`, `read_structured_document` (`read_document_structured`), `compare_document_versions`, and `synthesize_document_version` (plus loopback HTTP bridge parity in `bridge.rs` if needed).
  - Update `copy_assets_to_clipboard` and `start_outbound_drag` (`native.rs`) so stacked assets resolve to `resolve_primary_asset` by default (`CF_HDROP` for WeChat PC).
- [ ] **2.4 Rust Integration Test Suite (`windows/crates/charkle-core/tests/document_and_version_stack_tests.rs`)**:
  - Cover `swift_codec` wire round-trip, `.docx/.xlsx/GB18030/PDF` parsing, FTS5 Pinyin search, stem + SimHash stacking, `isPinnedPrimary` anti-override, High-Risk radar, Excel PK row insertion alignment, and `.docx` surgical merge integrity.

### Wave 2 Gate
```powershell
cd windows && cargo fmt --all -- --check && cargo clippy --workspace --all-targets -- -D warnings && cargo test --workspace
```

---

## Wave 3 — Fluent 2 Tactile Compact View, Stack UX, `Ctrl+J -> Ctrl+C` & Quick Look Document Studio (`windows/ui`)

### Checklist
- [ ] **3.1 Domain Types, Dual Transport & Store Folding (`domain.ts`, `transport.ts`, `coordinatorStore.ts`, `libraryStore.ts`)**:
  - Add `'compactList'` and all document/version TypeScript interfaces to `domain.ts`; implement both `TauriTransport` and deterministic `InMemoryMockTransport` methods in `transport.ts`.
  - Add per-destination layout memory in `coordinatorStore.ts` and `versionStack.groupID` Primary-Version folding (`resolvePrimaryAsset`) in `libraryStore.ts`.
- [ ] **3.2 Tactile Studio Compact View (`GalleryCompactView.tsx`, `TopFilterCapsule.tsx`, `GalleryView.tsx`, `App.tsx`)**:
  - Wire `'compactList'` switcher (`紧凑视图`, shortcut `5` / `Ctrl+5`), Settings default layout option, and Onboarding layout option.
  - Build virtualized `GalleryCompactView.tsx` with 2-col Tactile Index Grid ⇄ 1-col Folio Strip, hover 3D micro-folio fan-out (fine-pointer + reduced-motion guarded), 12-segment Diff Minimap, inline expandable Revision Rail (`设为主版` & `Δ` diff bridges), `Shift`/`Ctrl` multi-select, `↑/↓` `0ms` nav, `Space` Quick Look, and Primary Version drag-out / drop-to-stack.
- [ ] **3.3 Active Drop Banner, Inspector Section & `Ctrl+J -> Ctrl+C` (`TopEdgeDropShelf.tsx`, `InspectorView.tsx`, `JumpAnywhereModal.tsx`)**:
  - Surface `< 150ms` non-blocking `.win-acrylic` version-stacking prompt on drops into `TopEdgeDropShelf` (updating `setShelfHitRect` cleanly) and `GalleryView`/Folder; add context-menu stack actions (`合并为版本叠`, `设为主版本`, `拆出为独立素材`).
  - Add `CharkleDisclosureGroup` `版本叠` card in `InspectorView.tsx` (1:1 shared with Quick Look).
  - Add `Ctrl+C` Primary Version `CF_HDROP` file copy in `JumpAnywhereModal.tsx`.
- [ ] **3.4 Quick Look Document Studio & Visual PDF Diff (`DocumentStudioViewer.tsx`, `PdfDocumentViewer.tsx`, `QuickLookOverlay.tsx`)**:
  - Build `.docx` and `.xlsx` native Fluent 2 readers alongside `.pdf` and `.md/.txt`.
  - Build Version Stack Diff stage: High-Risk Radar filter pills, `仅看改动段落` toggle, `J/K` jump, Word Inline & Side-by-Side sync-scroll diff, Excel PK selector & cell/formula diff, `pdfjs-dist` dual-canvas **Red-Cyan blend & Split Curtain Wipe** + WinRT OCR trigger, and Scheme B 2-Way merge (`按差异合成新版本` -> `净版预览` -> `生成净版 vN+1`).
- [ ] **3.5 Vitest Regression Suite (`windows/ui/src/__tests__/document-stack-compact-view.test.tsx`)**:
  - Test Compact View 2-col/1-col & Revision Rail, per-destination layout memory, `isPinnedPrimary` anti-override, `Ctrl+J -> Ctrl+C` primary file copy, Quick Look readers, High-Risk Radar, Excel PK diff, PDF visual diff modes, and 2-Way synthesis.

### Wave 3 & Final Pre-Commit Gate
```powershell
cd windows/ui && npm run typecheck && npm test && npm run build
cd ../..
pwsh -NoProfile -ExecutionPolicy Bypass -File windows/scripts/verify-windows.ps1
node --test Resources/BrowserExtension/tests/extension.test.mjs
node scripts/test-figma-plugin.cjs
```
