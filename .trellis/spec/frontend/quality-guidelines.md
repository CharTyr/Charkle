# Frontend Quality Guidelines

> Motion discipline, accessibility, visual consistency, performance budgets, and pre-release UI verification for Charkle.

---

## Motion & Performance Budgets

1. **Kubai Motion Tokens (`CharkleMotion.swift` / `CanvasMotion` in `CanvasSupport.swift`)**:
   - Always wrap SwiftUI animations with `CharkleMotion.accessible(..., reduced: reduceMotion)` using `@Environment(\.accessibilityReduceMotion)`.
   - Never animate during live scroll (`VirtualizedMasonryView.isLiveScrolling == true`); use interruptible GPU `CABasicAnimation` (`cubic-bezier(0.22, 1, 0.36, 1)`) only for discrete layout changes, zoom, and mode switches.
2. **Idle CPU Budget**:
   - Settled idle CPU of `dist/Charkle.app` MUST stay `< 1%`.
   - Never attach continuous `TimelineView` / high-frequency `Timer` loops when the window or Notch Shelf is idle. The Notch cursor watcher (`0.10s`) must perform only O(1) coordinate & cached `changeCount` checks when collapsed.
3. **Masonry O(log N) Parity**:
   - Both `.verticalMasonry` and `.horizontalJustified` snapshots MUST keep `visibleItems(minY:maxY:)` and `intersectingIDs(in:)` strictly consistent with brute-force bounds checks under `50 ms` across 10,000 items (`PerformanceAndNotchTests`, `UpgradeFeaturesTests`).

---

## Visual & Appearance Parity

- Every new view, popover, sheet, and rich reader card MUST look balanced in both **Light** and **Dark** macOS appearances:
  - Use `CharkleTheme.surfaceElevated(for: colorScheme)`, `CharkleTheme.hairline(for: colorScheme)`, `CanvasSurface.ground(for: colorScheme)`, and adaptive shadow opacities (`colorScheme == .dark ? 0.42 : 0.14`).
  - Keep Liquid Glass (`charkleLiquidGlass`) restrained to floating toolbars, pills, and navigation controls — never glass-wash primary image content.
- Keep `NotchShelfView` strictly `.preferredColorScheme(.dark)` on pure `Color.black` so it merges seamlessly into the physical MacBook camera housing.

---

## Pre-Release Verification Checklist

1. Compile with strict warnings-as-errors: `swift build --build-tests -Xswiftc -warnings-as-errors`
2. Pass all Swift Testing suites (`swift test --skip-build`) and Figma plugin tests (`node scripts/test-figma-plugin.cjs`).
3. Build signed Release bundle via `./scripts/build-app.sh release` and verify `codesign -v --deep dist/Charkle.app`.
4. Relaunch `dist/Charkle.app` and verify settled idle CPU `< 1%` via `ps -axo pid,pcpu,rss,comm | grep Charkle`.
5. Spot-check interactive flows touched by your change:
   - Folder click (recursive subtree assets) & drag-to-reorder (any part of row + top-level parent folders)
   - Multi-select drag (`⌘A` -> drag into folder, no crash, no duplicates)
   - Gallery 3-mode switch + `⌘ + scroll` / pinch zoom animation
   - Moodboard Candidate Pool drag-to-canvas & Smart Group Frame `<|>` resize
   - Notch Shelf open/close morph (zero overflow), external drag smoothness, and recent-assets drag-out
   - Social post native reader (selectable text, playable video, photo/video standalone extraction)
