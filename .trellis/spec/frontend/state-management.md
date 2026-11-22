# Frontend State Management

> `@Observable` domain store boundaries, precomputed view caches, isolated canvas interaction state, and observer cleanup in Swift 6.2.

---

## Store Topology (`Sources/CharkleApp/Stores/`)

All four stores are `@MainActor` `@Observable` `final class` instances injected at app startup in `CharkleAppEntry.swift`:

| Store | Owns | Must NOT Own |
|-------|------|--------------|
| `AppCoordinatorStore` | Selected destination, `isSidebarCollapsed`, `galleryLayoutMode`, `galleryColumnWidth`, active sheet/popover flags, QuickLook playlist, active moodboard ID, toasts | Asset records or SQLite queries |
| `LibraryStore` | `assets` (+ `assetsRevision`), `allAssetsByID`, `cachedRecentActivityAssets`, `folders`, `smartFolders`, `tagCounts`, `inboxCount`, `filter`, `selectedAssetIDs`, `similarAssets`, social media extraction | UI modal flags or canvas camera |
| `MoodboardStore` | `boards`, `activeBoard`, `candidatePool`, undo/redo stacks, `swappingNodeID`, AI agent step stream | Library filter state |
| `SyncAndAIStore` | `syncStatus`, `syncConfig`, `aiConfig`, `typeSafeConfig`, `cacheStats`, `cloudUsage` | Gallery selection state |

---

## Mandatory Performance Patterns

### 1. Never Sort or Filter Full Library Inside SwiftUI `body`
- **Problem prevented**: Calling `allAssetsByID.values.filter(...).sorted(...)` inside `NotchShelfView.body` ran O(N log N) sorting twice per frame on the main thread during drag highlights and hover updates.
- **Required pattern**: Maintain precomputed derived arrays inside `LibraryStore` (e.g., `cachedRecentActivityAssets`, rebuilt inside `rebuildRecentActivityCache()` on `refreshAll()` / `refreshRichAsset()`, and updated O(1) in `markAssetOpened(_:)`). Views read the cached array directly.

### 2. Isolate High-Frequency Canvas Camera & Hover State (`MoodboardCanvasView.swift`)
- Keep 60–120 Hz trackpad pan/zoom/hover mutations in dedicated `@Observable` sub-objects (`FreeformCameraState`, `FreeformHoverState`) so continuous pointer motion never invalidates `MoodboardCanvasView.body` or re-renders toolbars.

### 3. `@Observable` + `NotificationCenter` Observer Cleanup (Swift 6.2)
- Store `NSObjectProtocol` tokens with `@ObservationIgnored` and tear them down in `isolated deinit` (see `LibraryStore.swift` observing `CharkleCoreNotifications.libraryDidEnrichInBackground`):
  ```swift
  @ObservationIgnored private var enrichmentObserver: NSObjectProtocol?

  isolated deinit {
      if let token = enrichmentObserver {
          NotificationCenter.default.removeObserver(token)
      }
  }
  ```

### 4. Incremental Masonry Invalidation
- `LibraryStore.assets` increments `assetsRevision &+= 1` in `didSet`. Pass `assetsRevision` into `VirtualizedMasonryView` so `AppKitMasonryRepresentable` can compare a lightweight `MasonryAssetsSignature` in O(1) instead of diffing thousands of `AssetRecord` structs on every SwiftUI update.
