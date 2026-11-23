# Frontend Directory Structure

> Organization of `Sources/CharkleCanvas/` (reusable high-FPS AppKit/SwiftUI canvases) and `Sources/CharkleApp/` (desktop shell, stores, views, notch, and design system).

---

## Module Layout

```text
Sources/
├── CharkleCanvas/                      # @MainActor reusable canvas & layout target (depends only on CharkleCore)
│   ├── CanvasSupport.swift             # CharkleDragIdentifiers, NotchDropGeometry, CanvasSurface, CanvasMotion, formatters
│   ├── VirtualizedMasonryView.swift    # 120 FPS CALayer-recycled AppKit Masonry (Vertical + Justified + pinch/⌘+scroll GPU zoom)
│   ├── ThumbnailImageLoader.swift      # Async 2-tier thumbnail cache (grid520 / preview1400) + invalidationVersion
│   ├── MoodboardCanvasView.swift       # Dual-mode canvas (Auto Editorial ↔ Freeform), connectors, ink, smart frame resize
│   ├── MoodboardNodeViews.swift        # Asset card, note card, BoardGroupFrameView (N · 标题 + side <|> handles)
│   ├── EditorialLayoutSolver.swift     # 3 distinct editorial styles (.magazine / .balanced / .compact) + smart group reflow
│   ├── MoodboardExporter.swift         # High-DPI PNG/PDF moodboard export
│   └── FigmaBridgeExporter.swift       # Editable .charkleboard bundle export (>4096px lossless PNG tiles + SHA-256)
└── CharkleApp/                         # @MainActor macOS executable target
    ├── CharkleAppEntry.swift           # App entry, WindowGroup, MenuBar commands (⌘\ sidebar toggle, shortcuts)
    ├── DesignSystem/
    │   ├── CharkleIcon.swift           # CharkleIcon, CharkleFolderIcon, CharkleIconCache (Duotone SVG + menuFolderIcon)
    │   ├── CharkleTheme.swift          # Color tokens, hairlines, Liquid Glass helpers, soft radial modal backdrop
    │   ├── CharkleMotion.swift         # Spring/ease tokens + Reduce Motion wrapper (`CharkleMotion.accessible`)
    │   ├── CharkleToastOverlay.swift   # Interactive Liquid Glass toast stack (hover-pause + Undo countdown ring)
    │   ├── CharkleEmptyStateVignette.swift # 7 miniature product-UI empty-state vector schematics (Light/Dark)
    │   ├── CharkleLoadingKit.swift     # Anti-flicker 300ms delayed skeletons & board loading skeleton
    │   └── AppIconManager.swift        # Light/Dark dock icon switcher
    ├── Notch/
    │   ├── NotchShelfState.swift       # @Observable geometry & mode state (Compact vs Full Waterfall)
    │   ├── NotchShelfController.swift  # Fixed transparent NSPanel, NotchSensorView, cached drag pasteboard watcher
    │   └── NotchShelfView.swift        # Pure-black NotchShellShape/RimPath morphing UI + recent strip + waterfall
    ├── Services/
    │   ├── ClipboardCollector.swift    # Clipboard image/file/URL/GitHub/X/Threads/Bluesky capture
    │   ├── GlobalHotkeyManager.swift   # Carbon global hotkeys (capture, clipboard, notch toggle)
    │   ├── ScreenCapturePermissionChecker.swift # Screen Recording status check & System Settings deep-linker
    │   └── ScreenshotCapturer.swift    # Interactive macOS area screenshot capture
    ├── Stores/
    │   ├── AppCoordinatorStore.swift   # Navigation, sidebar collapse, galleryLayoutMode, inspectorInfoSectionOrder, onboarding/settings, QuickLook, toasts
    │   ├── LibraryStore.swift          # Assets, folders, smart folders, tags, cachedRecentActivityAssets, synchronous metadata cache, media extraction
    │   ├── MoodboardStore.swift        # Active board, undo/redo, candidate pool, AI curation, palette sync
    │   └── SyncAndAIStore.swift        # Cloud sync status, AI config, TypeSafe Jev config, usage tracking
    ├── Views/
    │   ├── MainWindowView.swift        # Top-level split layout, toolbar, 3-mode gallery switcher, folder breadcrumb bar
    │   ├── SidebarView.swift           # Collapsible rail, smart folders, multi-select draggable folder tree, smart tag cap
    │   ├── GalleryFilmstripView.swift  # Finder-style hero stage (with live rich viewers) + bottom filmstrip scrubber
    │   ├── InspectorView.swift         # Reorderable single-asset cards (EXIF/AI prompt/palette/similar), batch edit, moodboard rail
    │   ├── QuickLookOverlayView.swift  # Fullscreen original-res & long-strip preview + collapsible right drawer (信息 | 类似项目)
    │   ├── QuickLookRichViewers.swift  # GitHub Repo + README, Social Post + AVPlayer + extract, Markdown, 3D SceneKit
    │   ├── OnboardingView.swift        # Skippable 6-step first-launch & re-runnable onboarding studio
    │   ├── FolderCustomizationPopover.swift # macOS-style color presets + ColorPicker + categorized SF Symbols + Emoji
    │   ├── SmartFolderEditorSheet.swift     # Rule builder (tags, description, multi-CIELAB colors, media kinds, rating)
    │   ├── JumpAnywhereView.swift      # ⌘J Pinyin/Chinese Quick Jump palette
    │   ├── MoodboardGeneratorSheet.swift    # 4-entry rapid moodboard generator
    │   └── Settings/                   # Centered 4-section, 9-pane SettingsOverlayView + SettingsChrome + GoogleOAuthSetupSheet
    └── Resources/Icons/                # 48 bundled SVG icons (`duotone-*.svg` & `layered-*.svg`, source palette #445C94 / #B4BED4)
```

---

## Placement Rules

- Pure geometry, layout math, drag payload encoding, and AppKit canvas rendering belong in `Sources/CharkleCanvas/` so unit tests in `CharkleTests` can verify them directly without booting `CharkleApp`.
- Domain state mutations belong in `Sources/CharkleApp/Stores/`, never inline inside SwiftUI view closures.
- Keep AppIcon assets (`Resources/AppIcons/`, `Resources/AppIcon.icns`) completely separate from in-app functional icons (`Sources/CharkleApp/Resources/Icons/duotone-*.svg`).
