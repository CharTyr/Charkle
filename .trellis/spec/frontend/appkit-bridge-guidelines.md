# AppKit Bridge, Drag-and-Drop & High-FPS Canvas Guidelines

> Hard-won macOS SwiftUI ↔ AppKit contracts preventing crashes, swallowed drags, duplicate imports, and frame drops.

---

## Scenario 1: Never Wrap macOS `.onDrag` Views Inside a SwiftUI `Button`

### 1. Scope / Trigger
- Trigger: Any SwiftUI view on macOS that supports both click and `.onDrag` (Sidebar folder tree rows, Moodboard Candidate Pool cards, Quick Add cards, Gallery Filmstrip thumbnails).

### 2. Why It Fails
- On macOS SwiftUI, `Button` runs an internal mouse-down tracking loop (`DragGesture(minimumDistance: 0)` equivalent) that claims mouse events and **completely blocks `.onDrag`**.
- Putting a `Button` on the row body or chevron leaves zero draggable pixels on parent folders and breaks drag-out from Candidate Pool / Quick Add.

### 3. Wrong vs Correct
```swift
// WRONG: Button swallows mouseDragged — .onDrag will never fire on macOS!
Button {
    handleClick(item)
} label: {
    ThumbnailCard(item)
}
.buttonStyle(.plain)
.onDrag { makeProvider(item) }

// CORRECT: Use .onTapGesture + .contentShape + .onDrag with crisp preview
ThumbnailCard(item)
    .contentShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
    .onTapGesture {
        handleClick(item)
    }
    .onDrag {
        makeProvider(item)
    } preview: {
        DragPreviewPill(item)
    }
```

- Reference implementations: `SidebarView.folderTreeRow`, `InspectorView.swift` (Candidate Pool, Quick Add, Similar Items), `GalleryFilmstripView.swift` (filmstrip cards).

---

## Scenario 2: `override nonisolated var isFlipped: Bool { true }` (CRITICAL SWIFT 6 CRASH GUARD)

### 1. Scope / Trigger
- Trigger: Selecting many items (e.g., `⌘A` in Inbox) and dragging them out of `MasonryDocumentView` (`VirtualizedMasonryView.swift`) triggered `EXC_BREAKPOINT (SIGTRAP)` in `_dispatch_assert_queue_fail` -> `_swift_task_checkIsolatedSwift` -> `@objc MasonryDocumentView.isFlipped.getter` on Thread 11 (`com.apple.root.user-interactive-qos`).

### 2. Root Cause & Contract
- When `NSView.beginDraggingSession(with:event:source:)` receives many `NSDraggingItem`s, AppKit invokes `-[NSView convertRect:toView:]` concurrently via `dispatch_apply` on background worker threads, which calls `isFlipped`.
- Under Swift 6 with `.defaultIsolation(MainActor.self)`, a plain `override var isFlipped: Bool { true }` emits a MainActor executor assertion that crashes the app immediately on that worker thread.
- **Rule**: Every flipped `NSView` subclass in `CharkleCanvas` and `CharkleApp` MUST declare:
  ```swift
  override nonisolated var isFlipped: Bool { true }
  ```

---

## Scenario 3: Multi-Item Internal Drag & Duplicate-Import Prevention

### 1. Scope / Trigger
- Trigger: Dragging 2–1,000+ selected assets from `VirtualizedMasonryView` into a Sidebar folder, Moodboard canvas, or external app (Finder/Figma).

### 2. Contract (`VirtualizedMasonryView.startCardDragSession`, `SidebarView.handleDrop`, `MoodboardCanvasView.handleCanvasDrop`)
- **Source (`startCardDragSession`)**:
  - Item `0` ALWAYS carries `CharkleDragIdentifiers.encode(assetIDs: ids)` (ALL selected IDs, even 1,000+) on `.string` plus item `0`'s local `.fileURL` (if cached).
  - Additional `NSDraggingItem`s carry local `.fileURL`s for external Finder/app drag-out, **capped at 32 items** with real thumbnail images only for the top 4 stacked previews and a 2×2 placeholder for items `4..<32`, with `session.draggingFormation = ids.count > 1 ? .pile : .default`.
- **Receivers (`SidebarView.handleDrop`, `MoodboardCanvasView.handleCanvasDrop`)**:
  - Always inspect `.plainText` for `CharkleDragIdentifiers.decodeFolderIDs` / `decodeAssetIDs` FIRST.
  - **CRITICAL**: Once `!internalIDs.isEmpty` or `!draggedFolderIDs.isEmpty`, skip all remaining `.fileURL` / `.url` / `.image` providers and NEVER execute `onDropExternalOntoFolder` / `onDropExternalInputs`. Otherwise items `1...N` (which carry `.fileURL` without `.string`) get re-imported as duplicate assets!

---

## Scenario 4: Zero Pasteboard IPC in High-Frequency Drag & Poll Loops (`NotchShelfController.swift`)

- **Problem prevented**: Reading `pasteboard.string(forType: .string)` or `pasteboard.pasteboardItems` on every `draggingUpdated` (60–120 Hz) or 100ms timer tick triggers synchronous XPC IPC to macOS `pboard`, causing severe drag stutter.
- **Required pattern**:
  1. Key cached inspection state (`isInternal`, `itemCount`, `hasDroppable`) strictly on `pasteboard.changeCount` (O(1) integer check).
  2. In `NotchDropHostingView.draggingUpdated`, fire `onDragEntered` / `onDragExited` ONLY on hit-rect edge transitions (`lastReportedInsideCard` flip), never on every mouse move pixel.
  3. Keep drag arrival zone (`NotchDropGeometry.isPointInDragTriggerZone`, relaxed band below the physical notch to avoid Mission Control / Spaces conflict) strictly separated from drop acceptance (`NotchDropGeometry.strictCardRect`).

---

## Scenario 5: High-FPS AppKit Masonry & Interruptible GPU Zoom (`VirtualizedMasonryView.swift`)

- **Live scroll (`isLiveScrolling == true`)**: ZERO animations (`stripLayoutAnimations()`), pure `CALayer` recycling from `reusePool`, O(log N) binary-search `visibleItems(minY:maxY:)`.
- **Zoom (`magnify(with:)`, `⌘ + scrollWheel`, toolbar slider) & Layout Switch**:
  - Always pass `animate: !reduceMotion` in `handleInteractiveZoom` (never gate on `abs(scaleFactor - 1.0) > 0.04`, which suppresses `⌘ + scroll` animations!).
  - Chain interruptible GPU `CABasicAnimation`s (`MasonryTileLayer.animateFrameTransition`) starting from `layer.presentation()?.frame ?? oldRect` with Kubai Tip 011 ease-out `CAMediaTimingFunction(controlPoints: 0.22, 1.0, 0.36, 1.0)`.
  - Guard `updateNSView` round-trips with `isRecentPinch = (CFAbsoluteTimeGetCurrent() - lastInteractiveZoomAt) < 0.26` so syncing `callbacks.onZoomColumnWidth` back to SwiftUI never cancels the active GPU animation.

---

## Scenario 6: Fixed Max-Size Notch `NSPanel`, Event Bridges & Hover Muted Preview

- **Never call `panel.setFrame` during Notch expand / collapse / compact↔full-gallery morph (`NotchShelfController.swift`, `NotchShelfState.swift`)**:
  - Size the fixed transparent `NSPanel` ONCE per screen to `maxPanelShapeWidth × maxPanelCardHeight` (plus shadow margins) and keep `activeWindowRectProvider` strictly in **unflipped AppKit window coordinates** (`y = 0` at bottom, `maxY` at top bezel). NEVER compare `NSHostingView`'s flipped `convert(sender.draggingLocation, from: nil)` (`y = 0` at top) against an unflipped `strictCardRect`, or compact-mode drags inside a taller fixed panel will completely miss the visible black capsule!
  - **Stale `NSPasteboard(.drag)` guard**: macOS never clears `NSPasteboard(name: .drag)` after a drag ends; always track `baselineDragChangeCount` when `NSEvent.pressedMouseButtons == 0` and only trigger proactive drag-open when `currentDragChangeCount != baselineDragChangeCount`. Always debounce hover-to-open (~`240ms` continuous dwell) so casual sweeps past the menu bar never pop the Notch Shelf open.
  - Pin compact and full-gallery sub-views to their own settled inner dimensions inside `.clipShape(NotchShellShape)` and put the drop shadow strictly on the pure-black background shape layer rather than the full clipped subtree.
- **Always-fresh SwiftUI → AppKit event bridges (`StageInteractiveBridge`, `HorizontalWheelScrollRedirector` in `CanvasSupport.swift`)**:
  - Never install an `NSEvent.addLocalMonitorForEvents` closure once in SwiftUI `.onAppear` that captures `struct View` `let` properties (`assets`, `isQuickLookPresented`, `asset`) — they go stale on view updates. Inject fresh closures on every `updateNSView` and tear down in both `dismantleNSView` and `isolated deinit`.
  - Attach `HorizontalWheelScrollRedirector()` to horizontal thumbnail strips (`NotchShelfView`, `GalleryFilmstripView`) so standard vertical wheel scrolls horizontally without requiring `Shift` while preserving native trackpad horizontal gestures.
- **Hover-to-play muted video & GIF preview (`HoverMediaPreview.swift`)**:
  - Enforce a `140ms` dwell debounce, single active preview, strict local-cache-only lookup (`ThumbnailImageLoader.resolveLocalCachedOriginalURL` -> `engine.cachedOriginalURL`, never triggering cloud downloads), `AVQueuePlayer.isMuted = true`, off-main-thread `CGImageSource` GIF frame decoding, and immediate teardown on live scroll, pointer down, Quick Look open, or exit.
