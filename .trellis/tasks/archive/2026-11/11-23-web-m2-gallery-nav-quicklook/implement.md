# Implementation Plan: M2 — Gallery-First UI, Navigation, Smart Folders, Inbox & Quick Look

1. [ ] Implement `design-system/`: `tokens.css` (Light/Dark neutral surfaces, concentric radii, Liquid Glass, calibrated motion curves, reduced-motion/transparency media queries), `CharkleIcon.tsx`, `GlassSurface.tsx`, `ToastHost.tsx`.
2. [ ] Implement typed `api/client.ts` + SSE bridge and the 4 Zustand stores (`coordinator`, `library`, `moodboard`, `syncAI`).
3. [ ] Build `features/sidebar/`: `SidebarView.tsx`, nested `FolderTree.tsx` (drag-reorder/nest/asset-drop), `FolderCustomizationPopover.tsx`, `SmartFolderEditorModal.tsx`.
4. [ ] Build `features/gallery/`: `TopFilterCapsule.tsx`, `VerticalMasonryView.tsx`, `HorizontalJustifiedView.tsx`, `GalleryFilmstripView.tsx`, `AssetCard.tsx`, `MarqueeOverlay.tsx`, `BatchActionPill.tsx`, `InboxTriageBar.tsx`, `InboxZeroView.tsx`.
5. [ ] Build `features/jump/JumpAnywhereModal.tsx` (`⌘J`) and `features/inspector/InspectorView.tsx`.
6. [ ] Build `features/quicklook/`: `QuickLookOverlay.tsx`, `ImageGifViewer.tsx`, `VideoAudioViewer.tsx` (waveform canvas), `DocumentViewer.tsx` (PDF iframe + Markdown/code renderer), `GitHubRepoCard.tsx`, `SocialPostCard.tsx`, `Model3DViewer.tsx` (Three.js orbit viewer).
7. [ ] Wire global keyboard shortcuts (`Space`, `⌘J`, `1–9` in Inbox, `⌘A`, `Backspace`/`Delete`, `⌘I` toggle inspector) and run `typecheck` + `build` + browser verification.

## Validation Commands
```bash
cd web && npm run typecheck && npm run build
```
