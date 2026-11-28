# Implementation Plan: Apple Dual-Platform Document Stack, Multi-Modal Diff, Scheme B 2-Way Merge & Tactile Compact View

> **Task**: `.trellis/tasks/11-28-macos-document-stack-diff-and-compact-view/`  
> **Companion Docs**: [`prd.md`](./prd.md) · [`design.md`](./design.md)

---

## Wave 1 — `Sources/CharkleCore` Contracts, Native Parsers, FTS5 Cache, Diff & Scheme B Synthesis

- [x] **1.1 Wire & Domain Models (`CoreModels.swift`, `CoreServiceProtocols.swift`)**:
  - Add `GalleryLayoutMode.compactList` and expand `MediaKind.detect` `.document` extensions (`doc, wps, et, dps, xlsx, xls, odt, epub, ofd`).
  - Add `AssetVersionStackMetadata`, `DocumentDiffSummary`, `DocumentRichMetadata`, `StructuredDocumentPayload`, `VersionStackCandidate`, `VersionStackMutation`, `DocumentComparisonReport`, and `DocumentMergeDecision`.
  - Add default-implemented methods on `CharkleEngineProtocol` and concrete implementations on `LiveCharkleEngine`.
- [x] **1.2 Native Offline Parsers & Poster Cards (`MediaPipeline.swift`, `MediaArtwork.swift`)**:
  - Implement safe ZIP reader/writer + OOXML `.docx` / `.xlsx` / `.pptx` XML parsers, `PDFKit` full-page text & `hasTextLayer` detection, UTF-8 / UTF-16 / GB18030 decoding, and `#if os(macOS)` `NSAttributedString` / `/usr/bin/textutil` fallback.
  - Upgrade `MediaArtwork` `.document` card rendering with top page/sheet/red-header preview + crisp bottom metadata strip.
- [x] **1.3 Local Derived Cache & Version/Diff/Merge Engine (`LibraryDatabase.swift`, `LiveCharkleEngine.swift`)**:
  - Add `document_content_cache` table in `LibraryDatabase` feeding `assets_fts` (with Pinyin/initials) without writing full text into `/.charkle/ops/*.jsonl`.
  - Implement Chinese office stem normalizer + 64-bit paragraph SimHash candidate matcher, `isPinnedPrimary` preservation, 12-bucket `minimapBuckets`, High-Risk Number/Currency/Date radar, Excel PK row alignment, Vision OCR scanned PDF diff, and Scheme B ZIP-preserving `.docx` / `.md` / `.txt` 2-Way synthesis.

## Wave 2 — macOS Native App (`Sources/CharkleApp` & `Sources/CharkleCanvas`)

- [x] **2.1 Tactile Compact View (`CompactIndexGalleryView`, `MainWindowView.swift`, `AppCoordinatorStore.swift`)**:
  - Wire `GalleryLayoutMode.compactList` (`list.bullet`, shortcut `5`, per-destination layout memory, Onboarding & Settings picker).
  - Build virtualized 2-Column Tactile Index Grid ⇄ 1-Column Folio Strip with hover 3D micro-folio fan-out, 12-segment Diff Minimap, inline expandable Revision Rail (`设为主版` & `Δ` diff bridges), `Space` Quick Look, `↑/↓` 0ms navigation, and Primary Version drag-out.
- [x] **2.2 Stack Folding, Drop Prompt, Inspector & `⌘J -> ⌘C` (`LibraryStore.swift`, `NotchShelfView.swift`, `InspectorView.swift`, `JumpAnywhereView.swift`)**:
  - Fold stacks by `versionStack.groupID` in `LibraryStore` resolving drag/copy to `isPinnedPrimary`.
  - Add lightweight active drop stacking banner in Notch Shelf & Gallery/Folder; add `CharkleDisclosureGroup` `版本叠` section in `InspectorView`; add `⌘C` Primary Version file copy in `JumpAnywhereView`.
- [x] **2.3 Quick Look Document Stage (`QuickLookOverlayView.swift`, `QuickLookRichViewers.swift`)**:
  - Add `.docx` / `.xlsx` / `.pdf` / `.md` readers, High-Risk Radar filter pills, `仅看改动段落` toggle, `J/K` jump, Inline & Side-by-Side Word diff, Excel PK-aligned diff, PDF Red-Cyan & Split Curtain visual diff, and Scheme B 2-Way synthesis workflow.

## Wave 3 — iOS / iPadOS Universal App (`ios/CharkleMobile`)

- [x] **3.1 Adaptive Compact View & Primary-Locked Sharing (`MasonryGalleryView.swift`, `RootShellView.swift`)**:
  - Add `compactList` switcher & per-folder layout memory; implement `MobileCompactIndexGalleryView` (1-col iPhone Folio / 2-col iPad Bento) with micro-folio artwork, 12-segment Diff Minimap, and tap-to-expand Revision Rail.
  - Ensure collapsed stacks and `ShareLink` / `UIActivityViewController` always export the `isPinnedPrimary` original file; add import stacking prompt banner.
- [x] **3.2 `AssetDetailView.swift` Readers, Diff Radar, Touch Curtain & 2-Way Merge**:
  - Add `.docx` / `.xlsx` / `.pdf` / `.md` native readers, Version Stack inspector sheet section, High-Risk Radar pills, Excel PK diff, Vision OCR + touch-draggable Split Curtain PDF diff, and Scheme B 2-Way synthesis with 1-tap Share.

## Wave 4 — Verification Gates & Windows Parity Handoff

- [x] **4.1 Automated Tests & Simulator Verification**:
  - `swift build` & `swift test --filter DocumentCoreAndVersionStackTests` & `swift test --filter CompactGalleryAndDocumentUITests` (zero warnings).
  - `xcodebuild -project ios/CharkleMobile.xcodeproj -scheme CharkleMobile -destination 'generic/platform=iOS Simulator' build` (zero errors).
- [x] **4.2 Cross-Platform Wire Spec & Windows Parity Handoff**:
  - Update `.trellis/spec/cross-platform/index.md` and deliver `.trellis/tasks/11-28-windows-document-stack-diff-and-compact-view-parity/` + `docs/WINDOWS_DOCUMENT_SYNC_SPEC.md` verified 1:1 against committed `Sources/CharkleCore` and `Sources/CharkleApp` symbols.
