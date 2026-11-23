# Charkle-Web Wave 2 Delta Sync Specification

> **Audit Scope**: All non-Notch changes in the macOS repository root (`..`) after Wave 1 (`ecd2212`, `2026-11-23 02:37`), verified against the current `./web` codebase.
>
> **Commits Audited**:
> - `ac8f723` (`02:13`, pre-Wave-1): **Already synced in Wave 1** (all Duotone SVGs, brand icons, Folder Popover, rich viewers, Masonry/Justified/Filmstrip).
> - `f39bfa5` (`02:59`, **PRIMARY DELTA**): Motion craft curve/duration upgrades, muted hover video/GIF preview (`HoverMediaPreview.swift` + local-only `cachedOriginalURL`), full Quick Look parity in `GalleryFilmstripView`, Quick Look wheel/key zoom + 40ms HUD stagger + drawer curve, unified Freeform-first Moodboard Studio (`MoodboardStore`, `MoodboardCanvasView`, `MoodboardGeneratorSheet`, `MainWindowView`).
> - `5bc0f07` (`11:03`, macOS Notch drop hit-testing): **Explicitly excluded** — Web will NOT keep a fake MacBook Notch Shelf.
> - `Resources/FigmaPlugin/*`: **0 diff** against `Charkle-Web/figma-plugin/` (identical; `ui.html` mtime was only a clean rebuild).
> - Untracked/uncommitted live WIP in native `Charkle` (`OnboardingView.swift`, `layered-{ai-spark,gallery,notch,ready}.svg`, working-tree `CharkleSkeuoButtonStyle` / `onboarding*` tokens): currently in-progress macOS onboarding work — **out of scope for committed Wave 2 delta** (Web already has its own first-launch admin setup flow in `AuthGate.tsx`).

---

## Explicit Exclusions & No-Busywork Checklist

- **NO macOS Notch Shelf**: Ignore all `NotchShelf*.swift` changes in `f39bfa5` and all of `5bc0f07` (`NotchDropGeometry`, fixed max-size `NSPanel`, `notchMorphSpring`). Instead, remove the fake top-center MacBook Notch UI from Web (`QuickDropShelf.tsx` / `pt-[24px]` channel in `App.tsx`) while preserving headless global `⌘V` paste-to-capture (see §2.6).
- **NO Figma Plugin changes needed**: `diff -ru Charkle-Web/figma-plugin Charkle/Resources/FigmaPlugin` is empty.
- **NO `JumpAnywhereModal` open/close animation rework needed**: Web's `JumpAnywhereModal.tsx` already opens/closes instantaneously with zero animation delay (matching `f39bfa5`'s removal of `dismissWithAnimation` + `popoverOriginScale`). Only remove its `toggleShelf` quick command (see §2.6).
- **Preserve `.autoEditorial` in `@charkle/shared` schema & Swift codec**: Never remove `BoardLayoutMode`'s `'autoEditorial'` variant or `EditorialLayoutSolver` (`solveEditorialLayout` / `freezeIntoFreeform`) — legacy synced `.charkle/` boards still decode it and silently upgrade to `.freeform` on open.

---

## File Ownership Map (Zero Merge Conflicts Across Wave 2 Builders)

| Builder | Exclusive File Ownership |
| --- | --- |
| **`server-sync`** | `packages/shared/src/models/moodboard.ts`, `packages/server/src/api/routes-core.ts`, `packages/server/src/media/sample-seeder.ts`, `packages/server/src/intelligence/moodboard-curator.ts`, `packages/server/src/agent/external-agent-service.ts`, `packages/server/tests/*`, `packages/shared/tests/*` |
| **`client-sync`** | `packages/client/src/api/client.ts`, `packages/client/src/design-system/tokens.css`, `packages/client/src/App.tsx`, `packages/client/src/stores/coordinatorStore.ts`, `packages/client/src/features/gallery/*` (incl. new `HoverMediaPreview.tsx` + `hoverMediaCoordinator.ts`), `packages/client/src/features/quicklook/*`, `packages/client/src/features/sidebar/*`, `packages/client/src/features/inspector/*`, `packages/client/src/features/jump/*`, `packages/client/src/features/settings/{AppearanceAndOtherTabs,SettingsModal,shortcuts}.ts*`, `packages/client/src/features/shelf/*` |
| **`studio-sync`** | `packages/client/src/stores/moodboardStore.ts`, `packages/client/src/features/moodboard/*` |

> **Cross-builder contract**: `client-sync` exports `HoverMediaPreview` & `supportsHoverPlayback` from `packages/client/src/features/gallery/HoverMediaPreview.tsx` and `originalMediaURL(id, options)` from `packages/client/src/api/client.ts`. `studio-sync` consumes `HoverMediaPreview` inside `NodeViews.tsx` (`AssetNodeView`). Keep `packages/client/src/features/shelf/captureUtils.ts` (`isEditableElement`) intact (imported by `MoodboardCanvasView.tsx`).

---

## 1. Shared & Server / Figma Plugin Delta (for `server-sync`)

### 1.1 Local-Cache-Only Original Endpoint (`cachedOriginalURL` Parity)
Native `CoreServiceProtocols.swift` + `LiveCharkleEngine.swift` added `cachedOriginalURL(for asset: AssetRecord) -> URL?` (`media.cachedOriginal(for: asset)`) so hover video/GIF preview **never triggers remote cloud downloads** when an original has been LRU-evicted or lives cloud-only.

- **Update `GET /api/v1/media/:id/original`** in `packages/server/src/api/routes-core.ts` (L712–727):
  - Read `const cachedOnly = c.req.query('cachedOnly') === '1' || c.req.query('cachedOnly') === 'true';`
  - Resolve `let filePath = ctx.media.getOriginalPath(asset);`
  - **Only** call `filePath = await ctx.sync.downloadOriginal(asset);` when `!filePath && !cachedOnly`.
  - When `cachedOnly` is true and `!filePath` (or file does not exist on disk), return `404` immediately (`{ error: '原始文件暂未缓存到本地。', code: 'NOT_CACHED' }`) **without** calling `ctx.sync.downloadOriginal` and **without** calling `ctx.db.touchOriginal(asset.id)`.
  - Preserve full HTTP `Range` (`206 Partial Content`) support for `<video>` streaming when cached locally.
- **Add test** in `packages/server/tests/core-api.test.ts` (or `core-media.test.ts`):
  - Verify `GET /api/v1/media/:id/original?cachedOnly=1` returns `200` (and `206` on `Range: bytes=0-15`) when cached locally, and returns `404` without invoking `sync.downloadOriginal` when uncached.

### 1.2 Freeform-First Moodboard Defaults (Schema-Compatible)
Native `f39bfa5` makes every newly created, seeded, or AI-curated Moodboard natively `.freeform` while keeping `.autoEditorial` decodable for legacy boards.

- **`packages/shared/src/models/moodboard.ts`**:
  - Keep `BoardLayoutMode = { type: 'autoEditorial'; config: AutoLayoutConfig } | { type: 'freeform' }` unchanged.
  - Update `createDefaultMoodboardDocument()` (L300): default `mode: { type: 'freeform' }`.
  - Update `createDefaultMoodboardCurationRequest()` (L399): default `useFreeformLayout: true`.
- **`packages/server/src/api/routes-core.ts`** (`POST /api/v1/boards`, L948–1008):
  - Newly created boards now inherit `mode: { type: 'freeform' }` from `createDefaultMoodboardDocument()`. When `seedAssetIDs` are provided, keep clean aspect-ratio-preserving non-overlapping node frames (or solve via `solveEditorialLayout` + `freezeIntoFreeform` so seeded boards open cleanly composed).
- **`packages/server/src/media/sample-seeder.ts`** (L624–647):
  - Build `starterBoard` in `mode: { type: 'freeform' }` by running `freezeIntoFreeform(...)` over its editorial layout (columns: 3, spacing: 18, style: `'magazine'`, `containerWidth: 1080`) so the seeded board (`光、纸与泥 · Light, Paper & Clay`) opens immediately as a polished freeform canvas with non-overlapping aspect-fitted cards!
- **`packages/server/src/intelligence/moodboard-curator.ts`** (`proposeMoodboard`, L386–392):
  - Already uses `MoodboardCurator.editorialNodes(...)` with computed frames and calls `createDefaultMoodboardDocument(...)` — once `createDefaultMoodboardDocument` defaults to `{ type: 'freeform' }`, `proposeMoodboard` natively returns a freeform draft!
- **`packages/server/src/agent/external-agent-service.ts`** (L876, L923):
  - Default `useFreeform` parameter to `true` when omitted by external MCP callers.
- **Tests**: Run `npm test -w @charkle/shared` and `npm test -w @charkle/server` (ensure `swift-codec.test.ts` and `editorial-layout.test.ts` remain green — they explicitly pass `mode: { type: 'autoEditorial', ... }`).

### 1.3 Figma Plugin (`Charkle-Web/figma-plugin/`)
- **No action required** — verified byte-for-byte identical to `../Resources/FigmaPlugin/`.

---

## 2. Design System, Motion & Gallery / Quick Look / Sidebar / Jump Delta (for `client-sync`)

### 2.1 Motion Craft Token Upgrades (`packages/client/src/design-system/tokens.css`)
Exact parity with `CharkleMotion.swift` & `CanvasMotion` (`CanvasSupport.swift`) from `f39bfa5` (Kubai Tip 011 + Emil Kowalski Motion Craft):

| Token | Old Value | New Value | Usage |
| --- | --- | --- | --- |
| `--ease-out` | `cubic-bezier(0, 0, 0.58, 1)` | **`cubic-bezier(0.23, 1, 0.32, 1)`** | Strong ease-out for enters, hover/press, popovers, AND **all exits** |
| `--ease-out-strong` | `cubic-bezier(0.22, 1, 0.36, 1)` | `cubic-bezier(0.22, 1, 0.36, 1)` | Active pills, filter chips, stepped reveals (`220ms`) |
| `--ease-in` | `cubic-bezier(0.42, 0, 1, 1)` | **Deprecate / alias to `var(--ease-out)`** | **NEVER use ease-in for UI exits** — exits must start instantaneously |
| `--ease-in-out` | `cubic-bezier(0.42, 0, 0.58, 1)` | **`cubic-bezier(0.77, 0, 0.175, 1)`** | Confident on-screen moves/reflow (`240ms`) |
| **`--ease-drawer`** *(NEW)* | *(missing)* | **`cubic-bezier(0.32, 0.72, 0, 1)`** | Apple/Vaul drawer & side-panel slide (`300ms`): Sidebar, Inspector, Quick Look rail, Candidate Pool |
| `--ease-overshoot` | `cubic-bezier(0.34, 1.56, 0.64, 1)` | `cubic-bezier(0.34, 1.56, 0.64, 1)` | Strictly `<= 64px` confirmations (stars, checkboxes, pins) at **`260ms`** |
| `--duration-press` | `120ms` | `120ms` | Tactile hover/press & sidebar drop highlights |
| `--duration-sm` | `180ms` | `180ms` | Small enters (toasts, menus, folder preview transitions) |
| `--duration-settle` *(NEW)* | *(240ms)* | **`220ms`** | Active pills, chips, filmstrip focus ring |
| `--duration-move` *(NEW)* | *(260ms)* | **`240ms`** | On-screen repositioning |
| `--duration-md` | `260ms` | **`240ms`** | Modals, dialogs |
| `--duration-lg` | `360ms` | **`280ms`** | Large surfaces (strictly `<= 300ms`!) |
| **`--duration-drawer`** *(NEW)* | *(missing)* | **`300ms`** | Sidebar, Inspector, Quick Look side rail, Candidate Pool drawer |
| `--duration-exit-sm` | `140ms` | **`130ms`** | Small exits (with `--ease-out`) |
| `--duration-exit-md` | `190ms` | **`170ms`** | Medium exits (with `--ease-out`) |
| `--duration-overshoot` *(NEW)* | *(280ms)* | **`260ms`** | `.charkle-micro-pop` updated from `280ms` → `260ms` |
| `--duration-popover-in` / `-out` | `160ms` / `110ms` | `160ms` / `110ms` | Both use `--ease-out` |

- Add `@media (prefers-reduced-motion: reduce)` overrides setting `--duration-drawer`, `--duration-settle`, `--duration-move`, `--duration-overshoot` to `150ms` (clean opacity cross-fade).
- Update **Sidebar** (`SidebarView.tsx` L241) width transition from `duration-[240ms] ease-[var(--ease-in-out)]` → **`duration-[var(--duration-drawer)] ease-[var(--ease-drawer)]`**.
- Update **Inspector** (`InspectorView.tsx`) open/close or slide container to use `var(--duration-drawer)` + `var(--ease-drawer)`.
- Update **Folder Customization Popover** (`FolderCustomizationPopover.tsx` L127): smooth color/symbol preview transition using `transition-[transform,opacity] duration-[var(--duration-sm)] ease-[var(--ease-out)]` (respecting `prefers-reduced-motion`).
- Update `api/client.ts`: extend `originalMediaURL(id: UUID, options?: boolean | { download?: boolean; cachedOnly?: boolean })` (keeping backwards compatibility when 2nd arg is `boolean` `download`) so `?cachedOnly=1` is cleanly constructible.

### 2.2 Muted Hover Media Preview (`HoverMediaPreview.swift` Parity)
Create two small, focused client modules:
1. **`packages/client/src/features/gallery/hoverMediaCoordinator.ts`** — module-level single-active-preview controller (0.0% idle CPU, zero React global re-renders):
   - `supportsHoverPlayback(asset: AssetRecord): boolean`: returns `true` **only** when `(asset.mediaKind === 'video' || asset.mediaKind === 'animatedImage') && !asset.richMetadata?.socialPost && !asset.richMetadata?.githubRepo`.
   - Tracks at most **ONE** active preview callback (`stopFn`) across the entire app. Calling `claimHoverPreview(token, stopFn)` immediately invokes the previous holder's `stopFn()`.
   - Exposes `stopAllHoverPreviews()` and `notifyLiveScrolling()` (stops immediately and suppresses new hover previews for `160ms` after the last scroll event).
   - Auto-subscribes once to `window` `blur`, `document` `visibilitychange`, and `pointerdown` (capture) to stop any active hover preview immediately.
2. **`packages/client/src/features/gallery/HoverMediaPreview.tsx`**:
   - Props: `{ asset: AssetRecord; active: boolean; fit?: 'cover' | 'contain'; roundedClass?: string; showMutedBadge?: boolean; disabled?: boolean }`.
   - **Strict invariants matching `HoverMediaPreview.swift`**:
     - Disabled automatically when `!active || disabled || !supportsHoverPlayback(asset)`, when `useCoordinatorStore.getState().quickLookAssetID !== null`, when `window.matchMedia('(prefers-reduced-motion: reduce)').matches`, or when not fine hover pointer (`!(window.matchMedia('(hover: hover) and (pointer: fine)').matches)`).
     - Measure host container size: skip if `width < 32 || height < 32`.
     - **`140ms` dwell debounce** before touching network or spawning any `<video>` / animated `<img>` element (fast cursor sweeps across dozens of cards spawn **0** decoders & **0** requests!).
     - Claims the single global slot in `hoverMediaCoordinator`.
     - **Local-cache-only**: requests `originalMediaURL(asset.id, { cachedOnly: true })` (never triggers cloud download). On `404` or load error, silently hides overlay so underlying static thumbnail remains uninterrupted.
     - **Zero black-frame flash**: mounts overlay container at `opacity: 0` (`pointer-events-none`), transitions to `opacity: 1` in **`150ms cubic-bezier(0.23, 1, 0.32, 1)`** **only after** video `onLoadedData` (`readyState >= 2`) or animated `<img>` `onLoad`.
     - **Strictly muted looping video**: `<video muted loop playsInline autoPlay preload="auto">` with `el.muted = true; el.volume = 0;`.
     - **Muted badge** (video only, never GIF): `20×20` dark rounded pill (`bg-black/56 rounded-[10px]`) with crisp `12px` white muted-speaker icon (`VolumeX`), shown ONLY when `mediaKind === 'video'`, preview is revealed, and card dimensions `>= 92×64`. Position at top-left/bottom-left or swap cleanly with `AssetCard`'s top-right `VIDEO` badge so badges never overlap!
     - **Deterministic teardown** on hover exit / scroll / mousedown / Quick Look open / unmount: cancel `140ms` timer, pause `<video>`, set `video.removeAttribute('src'); video.load();`, release coordinator slot.
- **Mount locations**:
  - `AssetCard.tsx` (used in `VerticalMasonryView` & `HorizontalJustifiedView`): track local hover state (`onMouseEnter` / `onMouseLeave`), call `notifyLiveScrolling()` from scroll listeners in `VerticalMasonryView` & `HorizontalJustifiedView`, call `stopAllHoverPreviews()` on `onMouseDown` / `onDragStart` / Quick Look open.
  - `GalleryFilmstripView.tsx`: mount on bottom filmstrip thumbnail cells ONLY (**never** on the large preview stage).
  - `InspectorView.tsx`: mount on Similar grid thumbnail cards (`tab === 'similar'`).
  - *(Moodboard `AssetNodeView` will be wired by `studio-sync` in §3.4.)*

### 2.3 Full Quick Look Parity in `GalleryFilmstripView.tsx`
Native `f39bfa5` rewrote `GalleryFilmstripView.swift` (+1023 lines) to match `QuickLookOverlayView` 1:1. Web's current `GalleryFilmstripView.tsx` (240 lines) only handles basic `<img>`, `<video>`, and bare `<audio>`.

Upgrade `packages/client/src/features/gallery/GalleryFilmstripView.tsx`:
1. **All 8 Media Viewers on the Main Stage**:
   - Export `ColorSwatchViewer` & `WebBookmarkViewer` from `packages/client/src/features/quicklook/` (e.g., `QuickLookOverlay.tsx` or a tiny shared `MediaStageHelpers.tsx`) so both `QuickLookOverlay` and `GalleryFilmstripView` share the exact same rich viewers:
     - `GitHubRepoViewer` (`asset.richMetadata?.githubRepo`)
     - `SocialPostViewer` (`asset.richMetadata?.socialPost`)
     - `ColorSwatchViewer` (`isColorSwatchAsset(asset)`)
     - `AudioStudioViewer` (`mediaKind === 'audio'`)
     - `LazyModel3DViewer` (`mediaKind === 'model3D'`, wrapped in `React.Suspense`)
     - `DocumentMarkdownViewer` (`mediaKind === 'document'` — handles both Markdown/Text and PDF iframe)
     - `WebBookmarkViewer` (`mediaKind === 'webBookmark'`, showing domain dot, title, monospace URL, notes, "在浏览器中打开" CTA)
     - `<video key={asset.id} src={originalMediaURL(asset.id)} poster={...} controls autoPlay playsInline />` (`mediaKind === 'video'`)
     - Zoomable Visual Stage (`mediaKind === 'image' | 'designFile' | 'animatedImage'`, using `originalMediaURL(asset.id)` for `animatedImage` and `preview1400` thumbnail for `image`/`designFile`).
2. **Interactive Visual Transform Container** (`supportsVisualTransform = !githubRepo && !socialPost && (image | designFile | animatedImage)`):
   - State: `zoom` (`0.5`–`5.0`, default `1`), `pan` (`{ x, y }`), `rotation` (degrees), `flipH`, `flipV`, `stageSize` (measured via `ResizeObserver`).
   - Auto-reset transforms (`zoom=1, pan={0,0}, rotation=0, flipH=false, flipV=false`) immediately whenever `activeAsset.id` changes.
   - **Quarter-turn fit scale (`quarterTurnFitScale`)**: when `displayRotation % 180 === 90`, compute exact scale from `stageSize` & natural aspect ratio (`min(availW / fittedH, availH / fittedW)`, clamped `[0.25, 1.0]`) so rotated landscape/portrait images fit cleanly without clipping.
   - **Correct CSS Transform Order (flip wraps rotation, matching SwiftUI parity)**:
     `transform: translate3d(${pan.x}px, ${pan.y}px, 0) scale(${zoom * quarterTurnFitScale}) scaleX(${flipH ? -1 : 1}) scaleY(${flipV ? -1 : 1}) rotate(${rotation}deg)`
     With rotation delta parity: `const parity = flipH !== flipV ? -1 : 1; setRotation((r) => r + screenDelta * parity);`.
   - **Direct scroll-wheel zoom** on stage (attach non-passive `wheel` listener via ref when `supportsVisualTransform && !quickLookAssetID`):
     - `const clamped = Math.max(-60, Math.min(60, -e.deltaY));`
     - `const sensitivity = e.deltaMode === 0 ? 0.0042 : 0.055;` (smooth trackpad vs stepped mouse wheel)
     - `const factor = Math.exp(clamped * sensitivity);`
     - Clamp `zoom` to `[0.5, 5.0]`; whenever `next <= 1.01`, reset `pan = { x: 0, y: 0 }`.
   - **Drag-to-pan** when `zoom > 1.01` (`grab` / `grabbing` cursor, zero transition during active drag).
   - **Double-click** toggles `100% ↔ 200%` (resets `pan` when returning to `100%`).
3. **Always-Visible Liquid Glass Preview Controls Pill** (rendered above metadata strip when `supportsVisualTransform`):
   - Zoom group: Zoom Out (`-`, `* 0.8`), clickable `${Math.round(zoom * 100)}%` button (resets to 100% + transforms), Zoom In (`+`, `* 1.25`), Reset (`0`).
   - Hairline divider.
   - Rotate & Flip group: Rotate CCW `-90°` (`⇧R`), Rotate CW `+90°` (`R`), Flip H (`⇧H`, active accent fill), Flip V (`⇧V`, active accent fill), conditional accent Reset pill (shows `${displayRotation}°` if rotated + undo icon whenever `hasAnyTransformOrZoom`).
   - Hairline divider.
   - `沉浸预览` (`Space`) button (when `!supportsVisualTransform`, keep `沉浸预览` pill on the metadata strip).
4. **Stage Keyboard Shortcuts** (always-fresh handler via refs/deps, disabled when `quickLookAssetID != null`, any modal `[role="dialog"][aria-modal="true"]` is open, or focus is inside input/textarea/select/contentEditable):
   - `ArrowLeft` / `ArrowRight`: step prev/next
   - `r` / `Shift+R`: rotate `+90°` / `-90°`
   - `Shift+H` / `Shift+V`: flip horizontal / vertical
   - `+` or `=` / `-`: zoom `* 1.25` / `* 0.8` (reset pan at `<= 1.01`)
   - `0`: reset zoom & transforms
5. **Bottom Filmstrip Enhancements**:
   - **Horizontal Wheel Redirect (`HorizontalWheelScrollRedirector` parity)**: attach a non-passive `wheel` listener to `stripRef` that redirects normal vertical mouse wheel (`Math.abs(e.deltaY) > Math.abs(e.deltaX)` and `!e.metaKey && !e.ctrlKey`) into `stripRef.current.scrollLeft += e.deltaY` (`e.preventDefault()`), while leaving native horizontal trackpad swipes untouched!
   - **Focused thumbnail scale `1.04`** with `duration-[var(--duration-settle)] ease-[var(--ease-out-strong)]` (disabled under `prefers-reduced-motion`).
   - **Hover muted playback**: mount `<HoverMediaPreview>` on each filmstrip thumbnail cell.
   - **Star rating micro-overshoot**: apply `charkle-micro-pop` on active star click.
6. **Complete Right-Click Context Menu** on BOTH the main preview stage AND every filmstrip thumbnail cell:
   - Target set: if clicked item is in `selectedAssetIDs` and `selectedAssetIDs.size > 0`, operate on all `selectedAssetIDs` (showing ` (N 项)` suffix); else `[item.id]`.
   - Menu items (use `Popover` or a clean fixed-position portal context menu closing on outside click / Escape):
     - `沉浸预览` (Quick Look)
     - `打开来源网页` (if `item.sourceURL`, opens in new tab)
     - Separator
     - `拷贝` (copies file/URL/title to clipboard + toast)
     - `剪切` (if `!item.isTrashed`, sets `cutAssetIDs` + toast)
     - `下载原文件` (Web equivalent of macOS `在访达中显示`)
     - Separator
     - If `!item.isTrashed`:
       - `加入活跃情绪板` (uses `activeBoardID ?? boards[0]?.id`, or opens Generator modal if no boards exist)
       - `加入指定情绪板 ▸` (submenu listing all `boards`)
       - `移动到文件夹 ▸` (submenu: `收件箱` + all `folders`)
       - `始终保留在本地` / `取消始终保留在本地` (`pinnedOffline` toggle)
       - `AI 重新打标` (`apiClient.analyzeAssets(targetIDs)` + toast)
       - Separator
       - `移至废纸篓` (danger)
     - If `item.isTrashed`:
       - `放回原处` (`restoreAssets`)
       - `彻底删除` (danger, `permanentlyDeleteAssets`)

### 2.4 Quick Look Refinements (`packages/client/src/features/quicklook/QuickLookOverlay.tsx`)
Exact deltas from `QuickLookOverlayView.swift` (`f39bfa5`):
- **HUD reveal stagger**: shorten `window.setTimeout(() => setChromeVisible(true), 110)` (L136) → **`40ms`** (`--duration-sm` + `--ease-out`).
- **Side rail drawer curve**: animate the collapsible right Info rail (`sidePanelOpen`) with **`duration-[var(--duration-drawer)] ease-[var(--ease-drawer)]`** (`300ms cubic-bezier(0.32, 0.72, 0, 1)`).
- **Keyboard zoom shortcuts**: add `+` / `=` (`zoom * 1.25`, max `5`) and `-` (`zoom * 0.8`, min `0.5`, resetting `pan` when `<= 1.01`) inside `onKeyDown` (L160–188), and skip transform shortcuts when `!isVisualImage` or when a confirmation dialog is open.
- **Zoom-out button & wheel parity**:
  - Reset `pan` to `{ x: 0, y: 0 }` when toolbar Zoom Out button crosses `<= 1.01` (L255).
  - Use smooth exponential wheel zoom (`Math.exp(clampedDelta * sensitivity)`) matching `GalleryFilmstripView`.
  - Fix CSS transform order at L488 from `... rotate(${rotation}deg) scaleX(...) scaleY(...)` → **`translate3d(${pan.x}px, ${pan.y}px, 0) scale(${zoom * quarterFitScale}) scaleX(${flipH ? -1 : 1}) scaleY(${flipV ? -1 : 1}) rotate(${rotation}deg)`** so flip wraps rotation cleanly with the existing `parity` math!
  - Compute `quarterFitScale` using live stage viewport dimensions (via `ResizeObserver`) rather than raw pixel ratio alone.
- **Bottom filmstrip horizontal wheel redirect**: attach the same vertical-to-horizontal wheel redirector on Quick Look's bottom filmstrip container (L580).
- **Stop hover previews on open**: call `stopAllHoverPreviews()` whenever `quickLookAssetID` becomes non-null.

### 2.5 Sidebar & Folder Popover Polish
- **`SidebarView.tsx`**:
  - Width collapse transition (L241): `transition-[width] duration-[var(--duration-drawer)] ease-[var(--ease-drawer)]`.
  - Drag-over drop highlight on Inbox / Folders / Moodboards: `duration-[var(--duration-press)] ease-[var(--ease-out)]`.
- **`FolderCustomizationPopover.tsx`**:
  - Smooth color/symbol change transition on the 56px preview `CharkleFolderIcon` using `duration-[var(--duration-sm)] ease-[var(--ease-out)]`.

### 2.6 Fake MacBook Notch Shelf Removal (Per User Decision)
Web will NOT display a fake MacBook Notch Shelf at the top-center bezel:
- **`App.tsx`**:
  - Remove `<QuickDropShelf />` (L16, L297) and remove `pt-[24px]` from `<main>` (L283) so Gallery and Moodboard toolbars sit cleanly at the natural top edge!
  - Mount a **headless** `<GlobalPasteCapture />` listener (reusing `packages/client/src/features/shelf/captureUtils.ts`, zero visible Notch DOM!) so non-input `⌘V` anywhere in Gallery still captures pasted images, URLs (X/Threads/Bluesky/GitHub/Bookmark), text notes, and `#HEX` color swatches into the active target (with a clean Toast confirmation).
- **`JumpAnywhereModal.tsx`**:
  - Remove `cmd-toggle-shelf` (`展开 / 收起快速采集浮窗`) and unused `quickDropShelfOpen` store reads.
- **`packages/client/src/features/settings/AppearanceAndOtherTabs.tsx` & `shortcuts.ts` & `SettingsModal.tsx`**:
  - Replace the "顶部快速采集浮窗 (Quick Drop Shelf)" card in Tab 7 (`采集与快捷键`) with a clean **"全局剪贴板采集 & Chrome 扩展采集"** card (configuring default capture target: `收件箱` / `指定文件夹` / `当前活跃情绪板`, plus a note/button pointing to PAT creation for the `chrome-extension/` companion!).
  - Remove Notch toggle shortcuts from `shortcuts.ts` and add the new Gallery/Quick Look zoom (`+`/`-`/`0`) shortcuts.
- **`packages/client/src/stores/coordinatorStore.ts`**:
  - Remove unused `quickDropShelfOpen` / `quickDropShelfExpanded` / `quickDropShelfPinned` / `quickDropShelfEnabled` state (keep `quickDropTarget` & `activeBoardID` for global paste & Chrome extension workflows!).
- **Keep `packages/client/src/features/shelf/captureUtils.ts`** intact (shared with `GlobalPasteCapture` and `MoodboardCanvasView.tsx`), and delete or retire `QuickDropShelf.tsx`.

---

## 3. Moodboard Studio & Generator Delta (for `studio-sync`)

Native `f39bfa5` unified the Moodboard Studio onto a **single, high-craft Freeform Infinite Canvas** — eliminating the split Auto Editorial stage & mode-switcher dock while retaining one-click Tidy & Editorial initial layout generation.

### 3.1 `packages/client/src/stores/moodboardStore.ts`
- **`applyProposal`** (L441–469):
  - Before saving `target.draftDocument`, check `if (isAutoEditorialMode(draft.mode))` and freeze it via `freezeIntoFreeform(draft, 1080, useLibraryStore.getState().assetsByID)` (matching `MoodboardStore.swift` L107–113!).
- **`proposeMoodboard` / `curateMoodboard`**:
  - Ensure any board refinement or generation passes `useFreeformLayout: true` (matching `MoodboardStore.swift` L475–479).
- **`openBoard`**:
  - Keep fetching cleanly; legacy `.autoEditorial` boards are silently upgraded by `MoodboardCanvasView` on mount (with real viewport width).

### 3.2 `packages/client/src/features/moodboard/MoodboardCanvasView.tsx` & `FloatingToolDock.tsx`
- **Remove Dual-Mode Split & Auto Editorial Stage**:
  - Delete `isAuto` / `autoConfig` branching, `editorialDrag` state & Kubai ripple insertion line, `handleSwitchMode`, `modeTransitioning`, and the entire `isAuto ? (...) : (...)` JSX stage branch in `MoodboardCanvasView.tsx` — ALWAYS render the Freeform Infinite Canvas stage!
  - **Silent Legacy Upgrade (`ensureFreeformModeIfLegacy`)**:
    - On mount / `[document.id]` change, if `isAutoEditorialMode(document.mode)`:
      - Run `const frozen = freezeIntoFreeform(document, Math.max(640, viewport.width), assetsByID);`
      - Call `onCameraChange(computeFitCamera(frozen.nodes, viewport.width, viewport.height, 72, 64, 96), false)` (or sync `frozen.viewportCenter` / `frozen.viewportZoom` with `topClearance = 64` below palette strip)
      - Call `onCommitDocument(() => frozen, { recordHistory: false, immediateSave: true })`.
- **Top Floating Board Palette Strip**:
  - Show whenever `showTopPaletteStrip && document.extractedPalette.length > 0`, where `showTopPaletteStrip = document.mode.type === 'autoEditorial' ? document.mode.config.showPaletteStrip : true` (matching `MoodboardCanvasView.swift` L46–53).
- **Bottom-Right `FreeformZoomControls`**:
  - Always visible (remove `!isAuto` conditional at L1748).
- **Bottom-Center `FloatingToolDock.tsx`**:
  - **Remove** the `自动排版` / `自由画布` segmented mode switcher (`role="tablist"`, `onSwitchMode`, `isAutoEditorial` prop).
  - Always show all Freeform tools: `select (V)`, `pan (H / Space)`, `connector (C)`, `pen (P)`, `eraser (E)`.
  - Always show insert buttons: `添加便签`, `添加分组框`, `添加板内色卡条`.
  - **Add `重新整齐排版` (Tidy) button** (`LayoutGrid` / `Sparkles` icon, invoking `tidyNodesInFreeform(doc, selectedNodeIDs, assetsByID)`) directly in `FloatingToolDock` (matching `MoodboardCanvasView.swift` L563–565!).
  - **Add Contextual Connector Style Selector** when `activeTool === 'connector'` (matching `MoodboardCanvasView.swift` L543–552): segmented pill for `曲线` (`curved`), `折线` (`elbow`), `直线` (`straight`) — replace `const [connectorStyle] = useState<ConnectorStyle>('curved')` with mutable `[connectorStyle, setConnectorStyle]` and pass `connectorStyle` into newly created connectors!
  - Update dock transition timings to match §2.1 (`--duration-settle` / `--ease-out-strong`, `--duration-move` / `--ease-in-out`).
- **Node Creation & Drop Locations**:
  - `addNoteNode`, `addGroupFrameNode`, `addPaletteStripNode`, `defaultPasteLocation`, and `handleCanvasDrop` always target world coordinates (`camera.centerX/Y` or `clientToWorld(...)`), removing all `isAuto ? ... : ...` checks.
- **Keyboard Shortcuts**:
  - `V`/`H`/`C`/`P`/`E` tool shortcuts are always enabled (while still keeping the modal guard `document.querySelector('[role="dialog"][aria-modal="true"]')` and `isEditableElement` guard!).

### 3.3 `MoodboardWorkspaceView.tsx`, `MoodboardsHomeView.tsx` & `CandidatePoolPanel.tsx`
- **`MoodboardWorkspaceView.tsx`**:
  - Remove `isAuto` / `updateAutoConfig` / Auto Editorial header branch (L431–449, L506–550). Always render the clean Freeform header toolbar: zoom `%`, `适配` (`computeFitCamera` with `topClearance = 64`), `一键整理` (`tidyNodesInFreeform`), `撤销`, `重做`.
  - Update `CandidatePoolPanel` slide transition to **`duration-[var(--duration-drawer)] ease-[var(--ease-drawer)]`** (`300ms cubic-bezier(0.32, 0.72, 0, 1)`).
  - Clean up any `"顶部快速采集浮窗"` tooltip copy on the `设为活跃` button → `"设为默认采集目标情绪板（供全局粘贴与浏览器扩展使用）"`.
- **`MoodboardsHomeView.tsx`**:
  - Update header subtitle (L133): `"单源引用素材库 · 无限自由画布与智能灵感策展 · 共 {boards.length} 块情绪板"` (matching `MainWindowView.swift` L123).
  - Update board card badge (L233): always display `"自由画布"` (matching `MainWindowView.swift` L132; remove unused `isAutoEditorialMode` import).

### 3.4 `NodeViews.tsx` (`AssetNodeView`)
- Remove `isAutoEditorial` prop and any auto-editorial-only branches (e.g. Hero toggle if auto-only, or keep weight toggle cleanly labeled).
- **Upgrade video & animated GIF hover playback** (L363–430):
  - At rest, render the lightweight static thumbnail (`thumbnailURL(...)`) for BOTH videos AND animated GIFs (stop continuously decoding full original GIFs on idle boards!).
  - When hovered (`hovered && !isCropping && !hasCrop && (kind?.autoplayLoop ?? true)`), mount the shared `<HoverMediaPreview asset={asset} active={hovered} fit="cover" />` from `../gallery/HoverMediaPreview` — getting the 140ms dwell debounce, single-active-preview coordination, `?cachedOnly=1` local-only lookup, zero black-frame fade-in, and muted badge automatically!

### 3.5 `packages/client/src/features/moodboard/MoodboardGeneratorModal.tsx`
Exact parity with `MoodboardGeneratorSheet.swift` (`f39bfa5`):
- **Remove** `const [useFreeformLayout, setUseFreeformLayout] = useState(false);` (L95) and delete the entire `"画布模式"` (`自动排版` / `自由拼贴`) control row (L634–662).
- **Rename** `"排版节奏"` label (L614) → **`"初始构图节奏"`** (keep the 3 `EditorialStyle` presets: `呼吸均衡` / `杂志主次` / `紧凑拼贴`).
- **Always pass `useFreeformLayout: true`** in `createDefaultMoodboardCurationRequest(...)` (L238).

---

## 4. Verification Gate (Post-Wave-2)

1. `npm run typecheck` — 0 errors across `@charkle/shared`, `@charkle/server`, `@charkle/client`.
2. `npm test` — all existing + new unit tests green (`?cachedOnly=1` never triggers cloud downloads; freeform-first defaults; legacy `.autoEditorial` codec & `freezeIntoFreeform` backwards compatibility intact).
3. `npm run build` — clean production bundle.
4. **Live browser checks**:
   - No fake top-center MacBook Notch pill; `<main>` starts cleanly at `top: 0` with zero toolbar overlap; non-input `⌘V` still captures.
   - `tokens.css` uses `cubic-bezier(0.23, 1, 0.32, 1)` for `--ease-out` & exits, `cubic-bezier(0.32, 0.72, 0, 1)` (`300ms`) for `--ease-drawer`, zero `ease-in` exits, zero `transition-all`.
   - Hovering video/GIF cards triggers muted preview only after `140ms`, uses `?cachedOnly=1`, shows muted icon on videos (`>= 92×64`), stops immediately on scroll / click / Quick Look.
   - `GalleryFilmstripView` renders all 8 media types, supports wheel/key/button zoom + rotate + flip + reset, redirects vertical wheel on bottom filmstrip to horizontal scroll, and opens full right-click context menus on stage & thumbnails.
   - `QuickLookOverlay` reveals HUD at `40ms`, supports `+`/`=`/`-`/`0` keyboard zoom, uses `drawerEase` on Info rail, and flips/rotates cleanly.
   - Moodboard opens directly in unified Freeform canvas (no `自动排版`/`自由画布` mode switcher in dock or Generator modal; `"初始构图节奏"` label in Generator; connector style picker visible when `connector` tool active; Tidy button in dock; legacy boards silently upgrade without losing positions).
