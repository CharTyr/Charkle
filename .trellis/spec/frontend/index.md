# Frontend Development Guidelines (`CharkleApp` & `CharkleCanvas`)

> Executable contracts and macOS SwiftUI + AppKit UI conventions for Charkle's desktop app, high-FPS virtualized masonry canvas, freeform moodboard studio, gallery/Quick Look preview parity, hover muted playback, and hardware Notch Shelf.

---

## Architecture Summary

- **Targets**:
  - `Sources/CharkleCanvas/` (`@MainActor` default isolation): High-FPS AppKit-backed `VirtualizedMasonryView`, freeform `MoodboardCanvasView`, `EditorialLayoutSolver`, `FigmaBridgeExporter`, `ThumbnailImageLoader`, `HoverMediaPreview`, `CanvasSupport` (`HorizontalWheelScrollRedirector`, `StageInteractiveBridge`).
  - `Sources/CharkleApp/` (`@MainActor` default isolation): SwiftUI desktop shell, collapsible sidebar, Gallery Filmstrip view, Inspector, Quick Look rich viewers, hardware MacBook Notch Shelf, `@Observable` domain stores, bundled duotone icon system & motion tokens.
- **Platform**: macOS 15+ (Swift 6.2, Apple Silicon). Restrained Apple Liquid Glass (`charkleLiquidGlass`), gallery-first visual hierarchy, 120 FPS interaction discipline.

---

## Guidelines Index

| Guide | Description | Status |
|-------|-------------|--------|
| [Directory Structure](./directory-structure.md) | `CharkleCanvas` and `CharkleApp` layout, resource bundling, component placement | Active |
| [Component Guidelines](./component-guidelines.md) | SwiftUI composition, duotone SVG icons, macOS menu color swatches, Notch morphing clip contract, rich viewers | Active |
| [AppKit Bridge Guidelines](./appkit-bridge-guidelines.md) | SwiftUI↔AppKit drag/drop rules, `nonisolated isFlipped`, multi-item drag, pasteboard caching, GPU zoom animations | Active |
| [State Management](./state-management.md) | `@Observable` domain stores, derived caches, `@ObservationIgnored` + `isolated deinit`, isolated canvas camera state | Active |
| [Type Safety](./type-safety.md) | Swift 6 `@MainActor` isolation, typed drag envelopes (`CharkleDragIdentifiers`), exhaustive enums | Active |
| [Quality Guidelines](./quality-guidelines.md) | Motion discipline, Reduce Motion, Light/Dark parity, idle CPU `< 1%`, verification gates | Active |

---

## Pre-Development Checklist

Before editing `Sources/CharkleApp/` or `Sources/CharkleCanvas/`:

- [ ] Never attach `.onDrag` onto a macOS SwiftUI `Button` (use `.onTapGesture` + `.onDrag { ... } preview: { ... }`).
- [ ] Mark `override nonisolated var isFlipped: Bool { true }` on any flipped AppKit `NSView` that calls `beginDraggingSession`.
- [ ] In internal multi-item drops (`SidebarView.handleDrop`, `MoodboardCanvasView.handleCanvasDrop`), short-circuit `.fileURL` providers once internal IDs are decoded so files are never re-imported as duplicates.
- [ ] Never sort `allAssetsByID.values` inside a SwiftUI `View.body` — read precomputed store caches (`library.cachedRecentActivityAssets`).
- [ ] For macOS `.contextMenu` color icons, render `NSImage` with `isTemplate = false` (`CharkleIconCache.shared.menuFolderIcon`).
- [ ] Keep Notch Shelf content at its fixed final target width inside `.clipShape(shape)` with `animatableData` on both shell and rim paths.

---

## Quality Check (Run Before Finish)

```bash
swift build --build-tests -Xswiftc -warnings-as-errors
swift test --skip-build
./scripts/build-app.sh release && codesign -v --deep dist/Charkle.app
```
