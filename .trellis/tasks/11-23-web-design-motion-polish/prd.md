# PRD: Web Frontend Design, Motion & v1.0.1 Parity Polish

> Package: `web` (`./web/`) · Priority: `P1` · Primary Design Authority: [`DESIGN.md`](../../../DESIGN.md)

## 1. Goal & User Value

Bring Charkle Web (`./web/`) to full visual, motion, interaction, and functional parity with [`DESIGN.md`](../../../DESIGN.md) and macOS Charkle v1.0.1+ — eliminating loader flicker, abrupt overlay mounts/unmounts, hardcoded style drift, layout-thrashing animations, and missing EXIF/AI Prompt/long-strip/reorderable-inspector workflows while keeping dual Node.js + Cloudflare Workers runtime compatibility 100% intact.

---

## 2. Requirements (Ordered by Leverage from `DESIGN.md` §8)

### P0 — Core Feel & Visual Polish
- **P0-1 Interactive Interruptible `ToastHost`**:
  - Upgrade `web/packages/client/src/design-system/ToastHost.tsx` & `stores/coordinatorStore.ts`:
    - Smooth interruptible enter (`180ms` `--ease-out`, `translateY(8px) scale(0.96) -> none`) and exit (`130ms` `--ease-out`, stay mounted through exit transition) using `@starting-style` / state-driven CSS transitions.
    - Pause auto-dismiss timer on pointer hover OR keyboard focus inside toast (`pauseToast` / `resumeToast`), close focused toast on `Escape`.
    - Live circular SVG countdown ring on action/Undo toasts (`durationMs >= 5000`), concentric inner/outer radii (`16px` outer / `6px` pad / `10px` inner).
    - Wire one-click `"撤销"` Undo Toast into soft-trash actions across Gallery, Batch Pill, and Inspector.
- **P0-2 Interruptible Soft-Veil `ModalShell`**:
  - Upgrade `web/packages/client/src/design-system/ModalShell.tsx` & `tokens.css`:
    - Keep mounted during `170ms` `--ease-out` exit transition (zero abrupt unmount flash).
    - Replace `bg-black/42 backdrop-blur-[3px]` with pure GPU soft radial veil (`.charkle-modal-veil`, Light `0.075 -> 0.165`, Dark `0.34 -> 0.50`) matching macOS `CharkleModalBackdrop`.
- **P0-3 Global Bilingual Typography Switches**:
  - Add `DESIGN.md` §4.2 rules into `web/packages/client/src/design-system/tokens.css` (`text-wrap: balance` on headings, `text-wrap: pretty` on paragraphs, `:lang(zh) { text-autospace: normal; text-spacing-trim: trim-start; }`, opt-out on `code, pre, kbd, input, textarea, select`, ensure `overflow-wrap: anywhere` instead of `word-break: break-all` / `line-break: anywhere`).
- **P0-4 Anti-Flicker Delayed Loaders & Structural Skeletons**:
  - Create `design-system/useDelayedFlag.ts` (`useDelayedFlag(active, 300, 500)`) and `design-system/Skeleton.tsx` (`GalleryMasonrySkeleton`, `InboxTriageSkeleton`, `CandidateGridSkeleton`, `InspectorSimilarSkeleton`) with coordinated sweep (`prefers-reduced-motion` static fallback).
  - Audit and replace bare centered `animate-spin` placeholders (20 instances across client views, including `GalleryView.tsx`, `InboxTriageBar.tsx`, `InspectorView.tsx`, and `CandidatePoolPanel.tsx`); preserve existing data cleanly during refresh.

### P1 — Consistency, Performance & macOS v1.0.1 Parity
- **P1-1 Token & Radius Convergence**:
  - Audit and migrate hardcoded UI chrome hex colors (e.g. `#5B8DEF` in `QuickLookOverlay.tsx`, `GalleryFilmstripView.tsx`, `Model3DViewer.tsx`) and ad-hoc `rounded-[Npx]` radii outside `design-system/` (converging off-grid pixel radii onto concentric `--radius-*` tokens in `tokens.css`). Keep user-data swatch palettes untouched.
- **P1-2 Transform-Only Canvas Transitions**:
  - Remove layout-property `width` transition in `web/packages/client/src/features/moodboard/MoodboardCanvasView.tsx:1372`; keep transitions strictly on `transform` and `opacity`.
- **P1-3 EXIF, AI Generation Prompt, Long-Strip Quick Look & Reorderable Zero-Flicker Inspector**:
  - **`@charkle/shared`**: Add `PhotoExifMetadata` & `AIGenerationMetadata` (`hasMeaningfulCameraExif`, `exposureSummary`, etc.) on `AssetRichMetadata` with 100% lossless `swift-codec.ts` round-trip compatibility with macOS `CoreModels.swift`.
  - **`@charkle/server` (Dual Runtime — Node + Cloudflare Workers)**: Implement pure-TS zero-`node:fs` `image-metadata-extractor.ts` parsing JPEG EXIF/TIFF/GPS/IPTC/XMP + PNG `tEXt`/`iTXt`/`zTXt` (A1111/ComfyUI/NovelAI/InvokeAI/Draw Things/Midjourney) using Web-standard `DecompressionStream('deflate')`; wire into `MediaPipeline` ingest + on-demand metadata hydration.
  - **`@charkle/client`**:
    - `QuickLookOverlay.tsx`: upgrade zoom ceiling to dynamic `6x–16x`, add original full-resolution long-strip vertical scroll mode (`height >= 1600 && height / width >= 2.2`) with toggle, and display EXIF + AI Prompt cards in side info panel.
    - `InspectorView.tsx`: add persisted drag-reorderable `InspectorInfoSection` order (`localStorage['charkle.inspectorSectionOrder']`), complete Camera EXIF card (gated strictly by `hasMeaningfulCameraExif`) & AI Prompt card with 1-click Copy, synchronous metadata cache, and `loadedAssetID` thumbnail anti-flicker guard.
- **P1-4 Choice Controls Upgrade**:
  - Audit all 7 `<select>` controls (`QuickCaptureModal.tsx:452`, `TopFilterCapsule.tsx:219`, `InspectorView.tsx:402/923`, `NodeViews.tsx:832`, `OnboardingModal.tsx:1425`, `SettingsChrome.tsx:314`): convert 2–5 short-option pickers to a reusable `SegmentedControl` (`design-system/SegmentedControl.tsx`), and keep growing lists (folders, models) as styled / searchable selects.

### P2 — Craft & Finishing Touches
- **P2-1 Miniature Product-UI Empty States**:
  - Build `design-system/EmptyStateVignette.tsx` with 5 self-contained `160×120` inline SVGs matching `DESIGN.md` §5.2 (`emptyLibrary`, `emptyFolder`, `noFilterResults`, `inboxZero`, `emptyMoodboard`, plus `emptyTrash` / `emptyInspector`) with automatic Light/Dark CSS variable theming and `prefers-reduced-motion` safety. Wire into `GalleryView`, `InboxZeroView`, `MoodboardsHomeView`, `InspectorView`.
- **P2-2 Cascade Menu Safe Triangle & Card Delete Exit**:
  - Add pointer-trajectory safe-triangle submenu tolerance + `180ms` grace timer on nested folder move submenus (`web/packages/client/src/features/gallery/GalleryFilmstripView.tsx:841-925` and shared context menus), and crisp `150ms` scale+opacity exit animation on card soft-delete paired with Undo Toast.
  - Pair single-item permanent delete triggers in Quick Look & Inspector with anchored non-modal Popconfirm (keeping modal dialog for batch delete / Empty Trash) to match macOS `CharklePopconfirm`.

---

## 3. Acceptance Criteria

- [ ] `cd web && npm run typecheck && npm test && node --test packages/extension/tests/extension.test.mjs && npm run build` all pass with 0 errors.
- [ ] `cd web && npm run cf:typecheck && npm run cf:dry-run` pass (confirming zero `node:fs` / `node:zlib` violations in Cloudflare Workers bundle).
- [ ] New unit tests pass for `PhotoExifMetadata` / `AIGenerationMetadata` `swift-codec` round-trip and `image-metadata-extractor` (PNG `tEXt` A1111 + ComfyUI JSON + JPEG EXIF).
- [ ] Visual check in Light & Dark modes, `prefers-reduced-motion`, and `prefers-reduced-transparency` confirms every `DESIGN.md` §9 gate passes.
- [ ] Zero external reference/author mentions and zero personal paths introduced.
