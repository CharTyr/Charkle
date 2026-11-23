# Implementation Checklist: Web Design, Motion & v1.0.1 Parity Polish

## Ordered Waves
1. **P0 Design System Foundation**:
   - Update `web/packages/client/src/design-system/tokens.css` (bilingual typography switches, `.charkle-modal-veil`, `.charkle-toast-item` `@starting-style` + countdown ring, `.charkle-skeleton` sweep + reduced-motion fallbacks).
   - Add `useDelayedFlag.ts` & `Skeleton.tsx` under `design-system/`, upgrade `coordinatorStore.ts` + `ToastHost.tsx` (pause/resume on hover & focus, exit transition, Undo countdown) and `ModalShell.tsx` (exit transition + soft radial veil).
   - Wire `useDelayedFlag` + structural skeletons into `GalleryView.tsx`, `InboxTriageBar.tsx`, `InspectorView.tsx`, `CandidatePoolPanel.tsx`, and Undo Toasts on soft-trash actions.
2. **P1 Backend/Shared EXIF & AI Prompt Parity**:
   - Add `PhotoExifMetadata` & `AIGenerationMetadata` to `web/packages/shared/src/models/core.ts` and `web/packages/shared/src/sync/swift-codec.ts` + unit tests.
   - Implement pure-TS `web/packages/server/src/media/image-metadata-extractor.ts` (Node + Workers compatible) + wire into `MediaPipeline` + unit tests.
3. **P1 Client Quick Look, Reorderable Inspector, Choice Controls & Token Cleanup**:
   - Upgrade `QuickLookOverlay.tsx` (dynamic `6x–16x` zoom, original long-strip scroll mode, EXIF/AI Prompt panel).
   - Upgrade `InspectorView.tsx` (persisted drag-reorderable sections, EXIF gated on `hasMeaningfulCameraExif`, AI Prompt card with copy, sync cache + `loadedAssetID` anti-flicker).
   - Add `SegmentedControl.tsx`, audit/upgrade the 7 `<select>` usages, fix `MoodboardCanvasView.tsx:1372` `width` transition, and converge hardcoded hex/radius drift back to tokens.
4. **P2 Empty States & Micro-Interactions**:
   - Add `EmptyStateVignette.tsx` (self-contained Light/Dark `160×120` miniature UI SVGs) and wire into Gallery, Inbox Zero, Moodboards Home, Inspector.
   - Add safe-triangle submenu buffering for nested folder move menus and `150ms` soft-delete card exit.
5. **Verification Gate**:
   ```bash
   cd web
   npm run typecheck
   npm test
   node --test packages/extension/tests/extension.test.mjs
   npm run build
   npm run cf:typecheck
   npm run cf:dry-run
   ```
