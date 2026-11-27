# Windows Parity Handoff: Drop Shelf 3-Mode Presentation & Shared Core / UI Reliability Alignment

## Scope & Context

Sync the macOS/iOS `dev` improvements from commits `935ed96`, `dc171e9`, and `e45d340` into `windows/` (`windows/crates/charkle-core`, `windows/crates/charkle-platform-win`, `windows/src-tauri`, `windows/ui`) strictly within `windows/` (never edit `Sources/`, `ios/`, `android/`, or `web/`).

> **Shared Rust Core Reminder**: `windows/crates/charkle-core` is also consumed by `android/rust/charkle-android-ffi` via UniFFI. Keep all `charkle-core` changes 100% OS-agnostic, warning-free, and covered by unit tests (and do NOT modify `windows/Cargo.toml` workspace members).

---

## Part 1: Drop Shelf 3-Mode Presentation Setting ("托盘展开形态")

**macOS Reference (`e45d340`)**:
- `Sources/CharkleApp/Notch/NotchShelfState.swift` (`NotchShelfPresentationMode`, `NotchExpandTrigger`, `isRecentStripExpanded`, `dropOnlyCardHeight`, `shouldShowRecentStripOnExpand(presentationMode:trigger:)`)
- `Sources/CharkleApp/Notch/NotchShelfController.swift` (`expand(trigger:pinOpen:)`, `setRecentStripExpanded(_:)`, live settings observation)
- `Sources/CharkleApp/Notch/NotchShelfView.swift` (slim collection capsule footer `"展开最近素材 (N) ⌄"` + recent strip fold button `"仅收集 ⌃"`)
- `Sources/CharkleApp/Views/Settings/NotchShelfSettingsPane.swift` (`"托盘展开形态"` 3-segment control)
- `Tests/CharkleTests/SwarmMacOSAuditTests.swift` (`notchShelfPresentationModeContracts`)

### 1.1 Three Presentation Modes & Trigger Truth Table

Add `ShelfPresentationMode` (persisted in `shelf-settings.json` with backward-compatible default `"alwaysShowRecent"`):

| Enum Value | UI Label | Dynamic Settings Subtitle | `.drag` Trigger | `.hover` / `.manual` Trigger | `.statusBanner` (when opening from collapsed) |
| :--- | :--- | :--- | :---: | :---: | :---: |
| `alwaysShowRecent` | **始终完整** | 拖放、悬停或快捷键唤出时，均直接显示收集区与最近素材横条 | Show Recent | Show Recent | Show Recent |
| `dropOnlyOnDrag` | **拖放极简** | 拖入文件或链接时仅弹出轻巧收集窗；无拖放悬停或快捷键唤出时完整展示最近素材 | **Slim Collection Only** | Show Recent | **Slim Collection Only** |
| `alwaysDropOnlyUntilExpanded` | **默认仅收集** | 常规触发默认只显示简洁收集窗，点击窗内「展开最近素材」后再展开浏览 | **Slim Collection Only** | **Slim Collection Only** | **Slim Collection Only** |

**Critical Invariants**:
1. Only apply the initial `shouldShowRecentStripOnExpand(presentationMode, trigger)` decision when transitioning from **collapsed → expanded** (`!wasExpanded`). If the shelf is **already expanded** (for example, opened in slim drop-only mode during a drag, and then a drop finishes and displays a processing/confirmation banner), **NEVER** jump-expand the Recent Assets strip mid-banner.
2. When the user clicks **"展开最近素材 (N) ⌄"** inside the slim collection window:
   - Smoothly morph the capsule (`notchMorphSpring` / reduced-motion safe fade) to reveal the Recent Assets strip (and cancel any pending auto-collapse timer so the shelf never flickers closed while unfurling).
   - Provide a subtle compact **"仅收集 ⌃"** button beside **"全部 (N) ⌄"** in the Recent Assets header so the user can fold back to the slim collection window anytime.
   - Entering Full-Waterfall Gallery (`fullGallery = true`) forces `recentStripExpanded = true` so collapsing back from Full-Waterfall returns to the Recent Assets strip cleanly.
3. Changing `presentationMode` in Settings while the shelf is pinned open should reflect immediately for instant preview feedback.
4. Keep full compatibility with **Minimal Capture Mode (`minimalMode == true`)** and all **3 Windows dock edges (`top` / `left` / `right`)**.

### 1.2 Rust / Tauri Host & Win32 Hit-Rect Contract

1. **`windows/src-tauri/src/desktop.rs` (`ShelfSettings`, line ~103)**:
   - Add `#[serde(default = "default_presentation_mode")] pub presentation_mode: String` (`"alwaysShowRecent"` default), serialized camelCase as `presentationMode`.
   - Pass explicit trigger reason (`"drag" | "hover" | "manual" | "statusBanner"`) through `show_shelf_window` / `show_shelf_window_inner_async` and include `presentationMode`, `trigger`, and/or resolved `recentStripExpanded` in the `shelf:state` event payload (`shelf_state_payload`, line ~1060).
2. **Win32 Frame-0 Hit-Rect & `CharkleShelfDropCatcher` Parity (`windows/crates/charkle-platform-win/src/shelf_win.rs`, `windows/src-tauri/src/desktop.rs:1137, 1185`)**:
   - Add `default_drop_only_capsule_rect_for_edge(placement, edge)` alongside `default_compact_capsule_rect_for_edge(placement, edge)`.
   - When opening in slim drop-only mode (`!recentStripExpanded`), seed `set_shelf_hit_rect(...)` and `sync_shelf_drop_catcher(...)` with the **slim capsule rect** on frame 0 so areas outside the slim capsule stay `HTTRANSPARENT` and never steal clicks or drag focus from underlying windows.
   - When the user clicks **"展开最近素材 (N) ⌄"** or **"仅收集 ⌃"** in `TopEdgeDropShelf.tsx`, immediately sync the updated capsule rect via `setShelfHitRect` (and `sync_shelf_drop_catcher` if dragging) without re-registering drop targets (`windows/AGENTS.md` OLE guardrail!).

### 1.3 React UI & Settings Implementation

1. **`windows/ui/src/types/domain.ts`**:
   - Add `export type ShelfPresentationMode = 'alwaysShowRecent' | 'dropOnlyOnDrag' | 'alwaysDropOnlyUntilExpanded';`
   - Add `export type ShelfExpandTrigger = 'drag' | 'hover' | 'manual' | 'statusBanner';`
   - Extend `ShelfSettings` with `presentationMode?: ShelfPresentationMode;` and `shelf:state` event type with `presentationMode?` / `trigger?` / `recentStripExpanded?`.
2. **`windows/ui/src/features/shelf/TopEdgeDropShelf.tsx`**:
   - Track `recentStripExpanded` state alongside `expanded` and `fullGallery`.
   - Slim collection capsule layout (works cleanly for `top` horizontal and `left`/`right` vertical side-edge layouts):
     - Keeps Wing Bar, Quick Capture actions, Target Destination Switcher (`收件箱` / `文件夹` / `活跃情绪板`), slightly roomier Drop Well, and a slim bottom bar displaying the destination hint on the left and **`展开最近素材 (${assets.length})`** (`chevron-down`) on the right.
     - Recent Assets strip header adds compact **`仅收集`** (`chevron-up`) pill right beside **`全部 (${assets.length})`**.
   - Keep `prefers-reduced-motion` and `data-backdrop="solidFallback"` fallbacks intact.
3. **`windows/ui/src/features/settings/SettingsPanesCaptureSystem.tsx` (`DropShelfSettingsPane`, right after line ~188)**:
   - Add a `SettingsRow` titled **`托盘展开形态`** with dynamic subtitle from the selected mode and a 3-option `SegmentedControl<ShelfPresentationMode>` (`始终完整` / `拖放极简` / `默认仅收集`), disabled when `!settings.enabled`.

---

## Part 2: Verified Rust Core (`charkle-core`) Bug Fixes & Sync Hardening

Direct cross-platform parity fixes verified against `windows/crates/charkle-core/` (matching `935ed96`):

1. **[P0 Security] Secondary WebDAV credential fallback leak (`windows/crates/charkle-core/src/engine.rs:3157-3175`)**:
   - `has_backend_webdav_password` (line 3151) already checks `if backend_id != SyncBackendProfile::LEGACY_PRIMARY_ID { return false; }`, **but `read_backend_webdav_password` (lines 3169–3174) unconditionally falls back to `WEBDAV_PASSWORD_VAULT_KEY`**, leaking the primary server's password to any secondary WebDAV backend with an empty secret.
   - **Fix**: Return `String::new()` immediately when `backend_id != SyncBackendProfile::LEGACY_PRIMARY_ID` and the per-backend vault key is absent.
2. **[P0 Sync] Silent deletion of new files at reused paths on iCloud Drive & WebDAV (`windows/crates/charkle-core/src/sync/engine.rs:2084-2108, 2233-2245`)**:
   - Stale `deleted.drive.*` / `deleted.folder.drive.*` marker pruning currently runs only when `is_mounted` (`MOUNTED_PATH_ID_PREFIX`). Deleting `Inbox/a.jpg` and later adding a new `Inbox/a.jpg` on iCloud Drive or WebDAV can cause reconcile to trash the new file.
   - **Fix**: Extend stale deletion-marker pruning and distinct-content fresh UUID minting to **all** path-based transports (`MountedVolume`, `ICloudDrive`, `WebDAV`), scoped cleanly by transport prefix/root.
3. **[P0 Multi-Backend Sync] Primary sync clears shared projections before `sync_secondary_backend` + duplicate-filename misbinding (`windows/crates/charkle-core/src/sync/engine.rs:449, 837-845, 859, 1200-1232`)**:
   - Primary sync clears `projection.boards`, `projection.thumbnails`, and `projection.embeddings` before secondary backends run, causing cover/board/embedding updates to be skipped on secondary backends.
   - **Fix**: Defer clearing shared dirty projections (`defer_projection_clearing`) until all enabled backends succeed. Inside `sync_secondary_backend`, exclude already-bound remote IDs (`bound_remote_ids`) when matching filenames so duplicate filenames (e.g. two `IMG_0001.PNG`) never alias the same remote file, and checkpoint mappings incrementally on partial failure.
4. **[P1 Cover Sync] Remote `grid520` update leaves stale `preview1400` on Device B (`windows/crates/charkle-core/src/sync/engine.rs` & `engine.rs:2602`)**:
   - When downloading an updated remote `grid520` thumbnail (e.g. after macOS/iOS "设当前帧为封面"), delete any stale local `preview1400` thumbnail for that asset so Quick Look displays the updated cover immediately.
   - In `update_asset_cover_image` (`engine.rs:2602`), also invalidate cached dedup/local visual descriptor entries for that asset so Smart Deduplication & Similar Assets reflect the new cover frame.
5. **[P1 Robustness] Codec, Dedup, Resolver & Reasoning-Model Harness Parity**:
   - `media/pureref.rs`: verify all big-endian length reads use checked `usize::try_from`, cap v1 text item recursion depth at `16`, and honor EXIF orientation `5..=8`.
   - `media/dedup.rs`: scope `?s=` / `?t=` URL query stripping strictly to X/YouTube hosts (not generic sites), and factor video duration into anti-chaining.
   - `media/resolvers.rs`: ensure `prepare_web_page` always preserves the original collected URL in `source_url` (never overwriting with login redirects; store redirects in `canonical_url`).
   - `intelligence/harness.rs`: strip `<think>...</think>` blocks and scan balanced JSON objects in `extract_json_object` so reasoning models don't waste retries.

---

## Part 3: Windows UI Robustness & Hygiene Alignment (from `dc171e9`)

Verify and tighten these high-impact UI details in `windows/ui/`:
1. **Moodboard board-switch commit guard**: In `windows/ui/src/stores/moodboardStore.ts`, guard debounced board/note/group mutation commits with `activeBoard?.id === nextDoc.id` (and flush/cancel pending timers on board switch) so edits from Board A never overwrite Board B.
2. **Quick Look video cover & teardown**: Confirm custom local cover thumbnails take visual priority over remote CDN `coverURL` on streaming video bookmarks, surface a warning toast when frame capture returns empty, and guarantee zero lingering audio when closing or stepping away from streaming/embed videos.
3. **Design-system & copy purity**: Audit `SmartFolder` editor, `SmartDeduplicationModal`, `Onboarding`, and `MoodboardGenerator` for zero banned violet (`#6366F1` / OKLCH 270°–330°) and zero user-facing engineering jargon (`CIELAB`, `SHA-256`, `2D-DCT`, `Agent`).

---

## Acceptance Criteria & Verification Gate

1. **Automated Tests**:
   - Rust unit tests covering:
     - `ShelfSettings` backward-compatible deserialization (`presentationMode` default `"alwaysShowRecent"` + round-trip for all 3 modes) & `should_show_recent_strip_on_expand` truth table.
     - `read_backend_webdav_password` non-leak for secondary backends.
     - Path-based transport (`ICloudDrive` / `WebDAV`) deleted-path reuse without silently trashing new files.
     - Multi-backend `defer_projection_clearing` (secondary backend still receives dirty boards/thumbnails/embeddings) and remote `grid520` invalidating stale `preview1400`.
   - React/Vitest unit tests covering:
     - `DropShelfSettingsPane` renders `"托盘展开形态"` 3-segment control with dynamic subtitles and persists `presentationMode`.
     - `TopEdgeDropShelf` renders slim collection capsule on `.drag` in `dropOnlyOnDrag` and on `.hover`/`.manual` in `alwaysDropOnlyUntilExpanded`, expands Recent Assets on clicking `"展开最近素材"`, folds back on clicking `"仅收集"`, and keeps slim capsule on drop confirmation banner without jumping tall.
2. **Mandatory Windows Gate**:
   ```powershell
   pwsh -File windows/scripts/verify-windows.ps1
   ```
   All checks (`sync-icons`, `tsc`, `vitest`, `vite build`, `cargo fmt --check`, `cargo clippy --workspace --all-targets -- -D warnings`, `cargo test --workspace`) pass with **0 warnings and 0 errors**.
3. **Android Compatibility Check (when touching `charkle-core`)**:
   - Keep `windows/crates/charkle-core` strictly free of Win32/Tauri imports and avoid breaking any public symbol used by `android/rust/charkle-android-ffi`.
