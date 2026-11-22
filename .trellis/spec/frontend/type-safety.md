# Frontend Type Safety (Swift 6.2)

> Strict concurrency isolation, typed drag payloads, exhaustive switches, and compile-time guarantees across `CharkleCanvas` and `CharkleApp`.

---

## Target Isolation Matrix (`Package.swift`)

| Target | Default Isolation | Upcoming Features |
|--------|-------------------|-------------------|
| `CharkleCore` | `nonisolated` | `NonisolatedNonsendingByDefault`, `InferIsolatedConformances` |
| `CharkleCLI` | `nonisolated` | `NonisolatedNonsendingByDefault`, `InferIsolatedConformances` |
| `CharkleCanvas` | `@MainActor` | `NonisolatedNonsendingByDefault`, `InferIsolatedConformances` |
| `CharkleApp` | `@MainActor` | `NonisolatedNonsendingByDefault`, `InferIsolatedConformances` |
| `CharkleTests` | `nonisolated` | `NonisolatedNonsendingByDefault`, `InferIsolatedConformances` |

---

## Concurrency & Isolation Rules

1. **Explicit `nonisolated` for cross-actor shapes, geometry & AppKit background callbacks**:
   - Mark pure `Shape`s (`NotchShellShape`, `NotchShellRimPath`), pure math enums (`NotchDropGeometry`, `MasonryLayoutEngine`, `EditorialLayoutSolver`), and `NSView.isFlipped` as `nonisolated`.
2. **Avoid non-Sendable closure capture in `async let` inside `@MainActor` Views**:
   - Under `NonisolatedNonsendingByDefault`, calling a non-`@Sendable` closure property (e.g., `resolveOriginalURL`) inside `async let` fails with `#NonSendableExitingActor`. Either mark the callback `@Sendable` or `await` sequentially inside a `@MainActor` `Task` (see `GalleryFilmstripView.loadPreview(for:)`).
3. **Explicit `CGFloat` casts in SceneKit / CoreGraphics math**:
   - Never mix `Float`, `Double`, and `CGFloat` inside `SCNVector3(...)` expressions — Swift type-checking can time out on complex mixed-scalar expressions. Cast components explicitly to `CGFloat` (see `QuickLookRichViewers.swift`, `MediaPipeline.swift`).

---

## Typed Cross-View Contracts

1. **Drag Payloads (`CharkleDragIdentifiers` in `CanvasSupport.swift`)**:
   - Never pass raw ad-hoc UUID strings or custom prefixes across views. Always encode/decode via:
     - `CharkleDragIdentifiers.encode(assetIDs:)` / `decodeAssetIDs(from:)`
     - `CharkleDragIdentifiers.encode(folderIDs:)` / `decodeFolderIDs(from:)`
     - `CharkleDragIdentifiers.isInternalDrag(_:)`
2. **Exhaustive Domain Enums**:
   - Avoid `default:` catch-alls when switching over `MediaKind`, `GalleryLayoutMode`, `SidebarDestination`, or `SocialPlatform` so adding a new media family (like `.model3D`) forces the compiler to flag every renderer, badge, contact sheet, and thumbnail loader that must handle it.
3. **Display Labels on Model (`AssetRecord.displayTypeLabel`)**:
   - Always use `asset.displayTypeLabel` (not `asset.mediaKind.localizedLabel`) in user-facing type rows so structured social posts (`"X 推文"`) and GitHub repos (`"GitHub 仓库"`) never display misleadingly as generic bookmarks or images.
