# Frontend Component Guidelines

> Conventions for SwiftUI views, duotone functional SVG icons, macOS context menus, rich media stages, and hardware Notch Shelf animations.

---

## In-App Functional Icons (`CharkleIcon.swift`)

- All in-app toolbar, sidebar, inspector, and notch functional icons use bundled duotone SVGs stored at `Sources/CharkleApp/Resources/Icons/duotone-*.svg` (canonical palette: primary `#445C94`, secondary `#B4BED4`), sized `17–20pt`.
- `CharkleIconCache` dynamically adapts `#445C94` / `#B4BED4` for Light, Dark, Active, and custom folder `tintHex` variants and caches resulting `NSImage`s with `isTemplate = false`.
- **Folders with custom appearance**: Use `CharkleFolderIcon(colorHex:customSymbol:size:isActive:)` in `SidebarView`, `MainWindowView` folder breadcrumb/subfolder pills, and `FolderCustomizationPopover`.
- **Do NOT touch AppIcon PNGs/ICNS** when asked to update in-app functional icons.

### Colored Icons inside macOS `.contextMenu` / `Menu`

- **Gotcha**: AppKit `NSMenuItem` strips SwiftUI `.foregroundStyle()` on SF Symbols inside `.contextMenu`, turning colored circles/icons monochrome gray.
- **Required pattern**: Render a crisp `16×16` `NSImage` with `isTemplate = false` via `CharkleIconCache.shared.menuFolderIcon(colorHex:isDark:)` and pass it inside `Label { Text(...) } icon: { Image(nsImage: ...) }`. See `SidebarView.swift` (`"更改文件夹颜色"` submenu).

---

## Rich Media Viewers Parity (`QuickLookRichViewers.swift`)

Every rich asset type MUST render its native interactive viewer in **both** `QuickLookOverlayView` AND `GalleryFilmstripView`:

| Asset Predicate | Native Viewer | Key Capabilities |
|-----------------|---------------|------------------|
| `asset.richMetadata?.githubRepo != nil` | `QuickLookGitHubRepoCard` | Owner avatar, stats, language, topics, OpenGraph banner, rendered README.md, refresh button |
| `asset.richMetadata?.socialPost != nil` | `QuickLookSocialPostCard` | Author header, selectable full body text, quoted post, playable `AVPlayerView` for videos/GIFs, per-item & extract-all photo/video buttons |
| `asset.isPlainTextDocument` | `QuickLookMarkdownReaderCard` | Block Markdown renderer + raw source toggle + copy |
| `asset.mediaKind == .model3D` | `QuickLookModel3DViewer` | Interactive `SCNView` 3D stage with camera reset |

- **Never** show only the baked raster waterfall poster (`AssetThumbnailSurface`) for a social post or GitHub repo in `GalleryFilmstripView` — users must be able to select tweet text, play embedded videos, and extract attachments directly.
- When `SocialPostInlineVideoPlayer` updates in `GalleryFilmstripView` (arrow-key stepping between tweets), `updateNSView` MUST compare `context.coordinator.currentURL != url` and swap `nsView.player` cleanly.

---

## Notch Shelf Morphing Animation Contract (`NotchShelfView.swift`)

### Scenario: Zero-Overflow Dynamic-Island Morphing

- **Problem prevented**: Animating `ZStack.frame(width:)` from `collapsedWidth` to `expandedShapeWidth` WITHOUT `.clipShape(shape)` and WITHOUT fixing interior content width causes buttons, counts, and thumbnail strips to reflow and spill outside the black notch bezel mid-spring.
- **Required structure**:
  1. Both `NotchShellShape` AND `NotchShellRimPath` MUST implement `animatableData: AnimatablePair<CGFloat, CGFloat>` so fill, clip mask, and 0.75pt rim stroke stay locked together on every frame.
  2. Always give `expandedContent` its exact final target dimensions `.frame(width: targetWidth, height: targetHeight, alignment: .top)` so interior elements NEVER reflow or drift horizontally during open/close.
  3. Apply `.background(Color.black).clipShape(shape)` directly on the morphing frame container before `.overlay(rim)` and a single `.shadow(...)` (avoid stacked double 24px Gaussian shadows that force expensive offscreen re-rasterization on every spring frame).
  4. Do NOT combine a redundant `.scaleEffect(x: 0.86, y: 0.38)` on the outer morphing container with the frame morph.
  5. Apply `.clipped()` on the horizontal recent-assets `ScrollView`.

---

## Sidebar Conventions (`SidebarView.swift`)

- **Collapsible Rail**: `56pt` icon-only rail ↔ `232pt` full sidebar toggled via `⌘\` (`coordinator.isSidebarCollapsed`).
- **Folder Counts**: Always display `library.subtreeAssetCount(for: folder.id)` (not `folder.assetCount`) so parent folders show total nested asset counts matching the recursive folder view.
- **Smart Tag Cap**: Render Top 10 most-used + up to 5 recent/frequent tags inline; hide remaining tags behind the searchable `"全部"` / `"查看全部 N 个标签"` popover (`allTagsPopoverContent`), while keeping any actively selected tag visible.
- **Folder Insertion Slots**: Always keep a dedicated trailing root insertion slot after `ForEach(visibleFolderTree)` (even when the last top-level folder is expanded), and adjust same-parent downward drag indices (`if oldIndex < runningInsertIndex { adjustedIndex = runningInsertIndex - 1 }`) so drops land exactly on the highlighted blue insertion line.
