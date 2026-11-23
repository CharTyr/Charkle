# Design: M2 — Gallery-First UI, Navigation, Smart Folders, Inbox & Quick Look

## Client State Architecture (4 Domain Zustand Stores)
Mirroring `Sources/CharkleApp/Stores/`:
1. `useCoordinatorStore`: `destination` (`SidebarDestination`), `layoutMode` (`GalleryLayoutMode`), `showInspector`, `showQuickLook`, `quickLookAssetID`, `showJumpAnywhere`, `showSettings`, `activeBoardID`, `themeMode` (`light`/`dark`/`system`), `cardScale`, `toastBanner`.
2. `useLibraryStore`: `assets`, `folders`, `smartFolders`, `tagCounts`, `inboxCount`, `criteria` (`FilterCriteria`), `selectedAssetIDs`, `semanticSearchMode`, `semanticReport`, `similarAssets`, `folderSuggestion`, CRUD & batch actions.
3. `useMoodboardStore`: `boards`, `activeDocument`, `proposal`, `agentSteps`, `isCurating` (expanded in M3).
4. `useSyncAndAIStore`: `syncConfig`, `syncStatus`, `aiConfig`, `typeSafeConfig`, `agentConfig`, `cacheStats` (expanded in M4) + shared `EventSource('/api/v1/events')` subscriber refreshing stores live.

## Layout & Virtualization
- Three-column desktop shell (`Sidebar 248px` | `Main Canvas flex-1` | `Collapsible Inspector 300px`), top floating Liquid Glass filter capsule with soft scroll-edge fade mask (`mask-image`).
- `VerticalMasonryView` & `HorizontalJustifiedView` compute deterministic absolute rects from `ResizeObserver` width and render only rows/cards intersecting `[scrollTop - 400, scrollTop + viewportHeight + 400]`.
- `QuickLookOverlay` mounts as a portal over the app with focus trap, keyboard listener (`Space`/`Escape`/`ArrowLeft`/`ArrowRight`), and dedicated sub-viewer dispatch by `asset.mediaKind` + `asset.richMetadata`.
