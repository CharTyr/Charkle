# PRD: Windows & Browser Extension Douyin Favorites Sync

> **Package**: `windows` (`windows/` + shared `Resources/BrowserExtension/`) · **Priority**: `P1`  
> **Research Audit**: [`research/codebase-and-compatibility-audit.md`](./research/codebase-and-compatibility-audit.md)

---

## 1. Goal & User Value

Enable Charkle Windows desktop users to collect and incrementally sync **Douyin (抖音)** favorites, collection sub-folders, likes, author profile works, and single video/photo-note posts directly from Chrome/Edge via the Charkle Browser Extension — delivering 1:1 UX parity with Xiaohongshu collection flows while reusing Charkle v1.5.1's zero-download inline streaming video playback, frame-to-cover selection, and on-demand MP4 extraction.

---

## 2. Locked Product & Architecture Decisions

1. **1:1 Xiaohongshu Page Coverage & Folder UX**: Douyin routes, floating launcher, Popup auto-tab, quick folder creation (`reuseExisting`), auto-switch to the "收藏" tab, and `900×1440` vertical feed card geometry align 1:1 with Xiaohongshu. When syncing from a specific Douyin collection sub-folder, the suggested target folder prefers that sub-collection's name (mirroring Xiaohongshu `/board` & `/collection`), falling back to `抖音收藏` (all favorites), `抖音喜欢` (likes), or `<作者名>` (author profile media mode).
2. **First-Class `SocialPlatform::Douyin` (`"douyin"`) + Wire Hardening + Cross-Platform Handoff (Option A)**:
   - Persist Douyin items inside `AssetRichMetadata.socialPost` (`SocialPostMetadata`) with `platform = "douyin"` and canonical deduplication key `douyin:<aweme_id>`, retaining native social fields (`likeCount`, `replyCount`, `repostCount`, `viewCount`, `authorAvatarURL`, `authorHandle`, `videoDurationSeconds`, `videoID`, `attachments`).
   - Harden Windows Rust (`windows/crates/charkle-core`) with graceful unknown-platform decoding so unrecognized future `SocialPlatform` wire values never fail or roll back `/.charkle/` sync transactions.
   - Deliver a structured `.trellis/tasks/` handoff task for macOS/iOS (and Web) to add `case douyin` + Swift unknown-platform decode fallback, and document the pre-upgrade cloud-sync caveat (un-upgraded macOS/iOS v1.5.1 clients sharing a `/.charkle/` cloud library will hit sync decode rollback on `"douyin"` until upgraded).
3. **Zero-Download Streaming Default for Bookmark Cards + Opt-In MP4 Download (Option 1)**:
   - In **Favorites / Likes / Bookmark card mode**, Douyin video items default to **zero eager MP4 download**: sync stores cover artwork + `.md` bookmark + `SocialPostMetadata`, plays inline in Quick Look via local HTTP Range streaming proxy (with `yt-dlp` fallback if ephemeral CDN URLs expire), supports "设当前帧为封面", and provides an explicit one-click **"保存视频为独立素材"** action to save a permanent local MP4.
   - In **Author Profile `media` mode**, batch downloading watermark-free MP4 files remains explicitly opt-in via the existing `includeVideos` checkbox.

---

## 3. Requirements

### R1. Browser Extension — Passive Douyin Capture & Xiaohongshu-Parity Collection Flow
- **Injection & passive read-only bridge** (`Resources/BrowserExtension/manifest.json:43-66, 106-127`, `x-bridge-loader.js:1-23`, `page-bridge.js:16-66, 497-580`, plus new parser module e.g. `lib/douyin-parser.js`):
  - Add `https://douyin.com/*`, `https://www.douyin.com/*`, and `https://m.douyin.com/*` to `content_scripts[0].matches` and `web_accessible_resources[1].matches`.
  - Passively observe `window.fetch` (`res.clone().text()`) and `XHR` (`load`) responses on Douyin Web endpoints (`/aweme/v1/web/aweme/listcollection/`, `/aweme/v1/web/collects/list/`, `/aweme/v1/web/collects/video/list/`, `/aweme/v1/web/aweme/favorite/`, `/aweme/v1/web/aweme/post/`, `/aweme/v1/web/aweme/detail/`) without initiating forged requests or signatures.
  - Emit standardized `__charkleSocialBridge: true` `window.postMessage` payloads (`platform: 'douyin'`, `dedupKey: 'douyin:<aweme_id>'`, `media[]`, `hasVideo`, `videoURL`, `durationSeconds`, `referer: 'https://www.douyin.com/'`, optional `collectionName`) aligned with `page-bridge.js:309-327, 441-459` & `lib/social-collectors.js:442-463, 655-673, 743-761`, plus collection folder metadata (`collects_id -> collects_name`).
- **Route detection, harvesting & UI integration** (`Resources/BrowserExtension/content.js:95-129, 505-933, 1660-1715, 3276-3303, 3391-3409, 3616-3794, 4185-4227`, `lib/url-detect.js:559-587`, `background.js:510`, `popup.js`):
  - Accept Douyin hosts in `initXGraphQLBridgeListener` (`capturedSocialPostsByKey`, preferring richer media payloads per `dedupKey`).
  - Map all Douyin routes 1:1 to Xiaohongshu:
    - Favorites & sub-collections (`/user/self?showTab=favorite_collection`, `/user/<sec_uid>?showTab=favorite_collection`, active "收藏" tab) -> `pageKind: 'collect'/'board'`, `bookmarks` mode (prefer sub-collection name / default `抖音收藏`).
    - Likes (`/user/self?showTab=like`, `/user/<sec_uid>?showTab=like`, active "喜欢" tab) -> `pageKind: 'likes'`, `bookmarks` mode (default `抖音喜欢`).
    - Author profile (`/user/<sec_uid>` / `/user/self`) -> `pageKind: 'profile'`, dual-mode switch (`media` author works -> `<作者名>`, `includeVideos` controls watermark-free MP4 download; vs `bookmarks` -> auto-clicks "收藏" tab via `ensureDouyinCollectTabActive` -> `抖音收藏`).
    - Recommend/search/discover feeds -> `pageKind: 'feed'`, `isCollectionRoute: false` (no floating launcher; manual Popup batch scan available).
  - Include active tab text in SPA route change detection (`content.js:4206-4227`), detect inner scroll containers (`content.js:3391-3409`), and provide DOM fallback scanning (`/video/(\d+)`, `/note/(\d+)`, `modal_id=(\d+)`) for pre-injection/SSR items.
  - Support single-page clipping (`GET_PAGE_CONTEXT` + `background.js:510`) for `/video/<aweme_id>`, `/note/<aweme_id>`, `?modal_id=<aweme_id>`, and `v.douyin.com/<code>`.
- **Content type filter, default auto-classification, multi-select Picker & Images-tab hint** (`lib/storage.js`, `content.js`, `background.js`, `popup.html`/`popup.css`/`popup.js`):
  - **Content filter (`douyinContentFilter: 'all' | 'video' | 'image'`)**: Surface segmented `全部` / `仅视频` / `仅图文` controls directly in the `批量` tab for both batch sync and picker mode; items excluded by the filter advance `seenThisRun` / scroll progress without polluting `knownStreak` / `skipped` / `discovered`.
  - **Default auto-classification (`douyinAutoClassify: true`, toggleable in options)**: Deduplicated **`抖音视频`** (`hasVideo === true`) or **`抖音图文`** (`hasVideo === false`) tags on every Douyin capture; lazily create/reuse (`POST /api/v1/folders` with `reuseExisting: true`, cached per parent) `视频` / `图文` subfolders only when actual items of that type are ingested (zero empty folders, anti-nesting guard; batch/picker Inbox targets lazily create `<suggestedFolderName>` first; single-page Inbox captures stay in Inbox with tags only; `author_media` separates `视频`/`图文` under `<作者名>`).
  - **Built-in multi-select Picker (`挑选导入`)**: Expose `SCAN_DOUYIN_PICKER_ITEMS` (bridge cache + DOM fallback + `{ scrollMore: true }` on `.route-scroll-container`) paired with `FETCH_EXISTING_SOURCES` `alreadyImported` badges, per-item cover/`视频 MM:SS`/`图文 N图` badges, `全选未导入`/`清空`/`加载更多`/`刷新`, and `导入所选 (N)` routed through full ingestion + auto-classification.
  - **Images-tab anti-confusion hint**: On Douyin/Xiaohongshu collection pages, display a neutral banner (`#images-social-hint`) in the `抓图` tab clarifying that image grabbing saves bare cover thumbnails and offering a one-click `去挑选导入` shortcut to the `批量` tab (auto-opening the picker on Douyin).
- **Windows bundle mirror**: Keep `windows/src-tauri/resources/BrowserExtension/` byte-identical to `Resources/BrowserExtension/` and register all extension files in `windows/src-tauri/tauri.conf.json`.

### R2. Windows Rust Core & Tauri Bridge — `SocialPlatform::Douyin`, Wire Hardening, Zero-Download Gating, Artwork & Streaming
- **Platform enum & forward-compatible wire codec** (`windows/crates/charkle-core/src/models/core.rs:112-128`, `wire/swift_codec.rs:376`, `db/library_db.rs:2805-2814, 2921-2922`):
  - Add `SocialPlatform::Douyin` (`"douyin"`, display name `"抖音"`, hiding internal `sec_uid`/numeric IDs in `display_handle_line`).
  - Add unknown-platform deserialization tolerance on `SocialPlatform` so unrecognized future platforms in `/.charkle/` ops shards never fail `SyncFields::merge` or roll back `apply_op_shard`.
- **Decoupled zero-download video bookmarking & auto-classification tags** (`windows/crates/charkle-core/src/models/core.rs:126-128`, `media/douyin.rs`, `media/pipeline.rs:534, 824, 901`, `bridge.rs`):
  - Keep `is_video_platform()` scoped to horizontal 16:9 video platforms (`Youtube | Bilibili`) and introduce an independent zero-download predicate (`prefers_zero_download_video_bookmark()` returning `true` for `Youtube | Bilibili | Douyin`) wired into `pipeline.rs:534, 824, 901`, so Douyin bookmark ingest stores cover + `.md` + `richMetadata.socialPost` without eagerly downloading MP4 files or forcing vertical/photo-note posts into 16:9 layout.
  - Automatically append deduplicated **`抖音视频`** (`has_video == true`) or **`抖音图文`** (`has_video == false`) tags (`douyin_classification_tag`) across desktop `WebUrl` paste/drop, `SocialBookmark`, and `socialMedia` ingest paths without duplicating or displacing existing tags.
- **URL parser, short-link redirect & canonical dedup** (`windows/crates/charkle-core/src/media/`, `bridge.rs`):
  - Parse `/video/<aweme_id>`, `/note/<aweme_id>`, `?modal_id=<aweme_id>`, and resolve `v.douyin.com/<code>` short links (including mobile share copy extraction), producing canonical dedup key `douyin:<aweme_id>` across `GET /api/v1/assets/existing-sources`, `POST /api/v1/assets/ingest` (`socialBookmark`, `socialMedia`), and single URL paste/drop.
  - Handle `application/octet-stream` video responses safely via `ftyp`/magic-byte sniffing when downloading opted-in MP4s (`author_media` with `includeVideos` or on-demand extract).
- **Vertical feed card artwork** (`windows/crates/charkle-core/src/media/artwork.rs:119`):
  - Render Douyin bookmarks as `900×1440` vertical feed cards (`3:4` `900×1200` cover + `240px` white footer with 2-line title, author avatar/name, like count; video cards overlay play icon + bottom-right `MM:SS` duration badge; multi-image cards overlay top-left `N 图` badge).
- **CDN allowlist, Referer & zero-download streaming proxy** (`windows/crates/charkle-core/src/media/video_platform.rs:1142-1261, 1749-1831, 1855-1894, 2224-2292, 2459-2664`, `resolvers.rs:2163`, `windows/src-tauri/src/protocol.rs:112-207`, `engine.rs:2605-2653, 4100-4145`):
  - Allow Douyin image & video CDN hosts (`*.douyinpic.com`, `*.byteimg.com`, `*.ibytedtos.com`, `*.douyinvod.com`, `*.zjcdn.com`, `*.snssdk.com`, `*.bytevcloudapi.com`, `*.amemv.com`) in image proxy and `proxy-video-stream` with automatic `Referer: https://www.douyin.com/`.
  - Wire `resolve_playback_plan` for `SocialPlatform::Douyin` with `Referer: https://www.douyin.com/` and `resolve_direct_stream_via_yt_dlp_if_available` fallback when ephemeral CDN URLs are missing/expired; support on-demand MP4 extraction via `extract_link_media_attachment` + `download_via_yt_dlp_if_available`.

### R3. Windows Desktop UI — Per-Item Quick Look Branching & Fluent 2 Compliance
- Update `windows/ui/src/types/domain.ts:58-71, 230` (`SocialPlatform`, Douyin CDN proxy URLs, labels/styling) without adding `'douyin'` to horizontal-only `isVideoSocialPlatform`.
- Branch `windows/ui/src/features/quicklook/SocialPostViewer.tsx:150, 223-236, 303, 415-613` by **per-item content**:
  - `platform === 'douyin' && post.hasVideo`: reuse `<QuickLookStreamingVideoView />` (`QuickLookStreamingVideoView.tsx:21-53, 239-288`) for zero-download inline streaming, "设当前帧为封面", and explicit "保存视频为独立素材".
  - `platform === 'douyin' && !post.hasVideo`: reuse `isVerticalMultiGrid` (`3:4` 2-column grid with single/batch image extraction).
- Uphold `DESIGN.md` & `.trellis/spec/windows/fluent2-design-system.md` (zero violet chrome, zero `transition: all`, Light/Dark contrast parity, `< 1%` idle CPU).

### R4. Windows Verification Baseline Prerequisite Fixes
Resolve all 4 verified pre-existing baseline blockers so full Windows & extension gates pass with 0 warnings:
1. **NSIS missing extension assets (High)** — `windows/src-tauri/tauri.conf.json:57-78`: add the 4 omitted v1.3.0 `BrowserExtension` files (`page-bridge.js`, `x-bridge-loader.js`, `lib/social-collectors.js`, `lib/x-author-media.js`) plus all new Douyin extension files to `bundle.resources`.
2. **Vitest timeout flake (Medium)** — `windows/ui/vite.config.ts:25-30`: set `testTimeout: 20_000` so full `<App />` jsdom integration tests (`m4-moodboard-studio.test.tsx`, `m5-settings-ai-onboarding.test.tsx`) do not time out at 5000ms.
3. **Rust 1.97.1 `clippy -D warnings` failures (High)** — delete redundant `drop(push_vid); drop(push_img);` in `windows/crates/charkle-core/src/media/resolvers.rs:585-586` (`clippy::drop_non_drop`) and replace the manual range check in `windows/crates/charkle-platform-win/src/shelf_win.rs:1152-1153` with `!(0.0..=Self::APPROACH_GRACE_SECS).contains(&elapsed_since_trigger_secs)` (`clippy::manual_range_contains`).
4. **Windows CRLF test failure (Medium)** — `Resources/BrowserExtension/tests/extension.test.mjs:161-164`: normalize `\r\n` to `\n` (or match `\r?\n`) before asserting `START_BOOKMARK_IMPORT` handler lines.

### R5. Cross-Platform Handoff Task Delivery (macOS / iOS / Web)
- Create a structured `.trellis/tasks/` handoff task (without modifying `Sources/`, `ios/`, or `web/`) documenting:
  - `SocialPlatform.douyin` (`"douyin"`) & `douyin:<aweme_id>` contract for macOS/iOS (`Sources/CharkleCore/Contracts/CoreModels.swift:60, 282, 879, 1047`) and Web (`web/packages/shared/src/models/core.ts:158`, `web/packages/shared/src/sync/swift-codec.ts:672-729`).
  - Required unknown-platform graceful decode fallback in Swift (`SocialPostMetadata.init(from:)` / `AssetRichMetadata.init(from:)`) so future platforms never stall `SyncOperations.swift:136, 316` / `DriveSyncEngine.swift:1037-1046`.
  - Pre-upgrade cloud-sync caveat: users running un-upgraded macOS/iOS v1.5.1 against a shared `/.charkle/` cloud library must upgrade macOS/iOS before syncing Windows-collected Douyin bookmarks.

---

## 4. Out of Scope

- **No direct edits to `Sources/`, `Tests/`, `ios/`, `android/`, or `web/`** in this session (per `AGENTS.md` §1); tracked exclusively via the R5 `.trellis/tasks/` handoff task.
- **No anti-bot signature reverse-engineering or forgery** (no synthesizing `a_bogus`, `X-Bogus`, or `msToken`, and no unauthorized active API polling — strictly passive interception of logged-in browser responses + DOM fallback).
- **No login, CAPTCHA, or anti-bot verification bypass** — if Douyin shows login or verification prompts, the extension pauses and lets the user resolve it directly in the browser.
- **No unattended/scheduled background scraping** — collection is strictly user-triggered in an active browser tab.

---

## 5. Acceptance Criteria

- [ ] **AC-1 (R1 Extension, Filter, Auto-Classification & Picker)**: In Chrome/Edge on Douyin favorites, specific sub-collections, likes, dual-mode author profile, and single `/video/` / `/note/` / `?modal_id=` pages, the extension detects routes accurately, shows the floating launcher on collection routes, suggests the active sub-collection name or default folder (`抖音收藏` / `抖音喜欢` / `<作者名>`), supports `全部`/`仅视频`/`仅图文` filtering without polluting `knownStreak`, defaults to `douyinAutoClassify: true` (deduplicated `抖音视频`/`抖音图文` tags + lazy non-empty `视频`/`图文` subfolders without nesting), provides built-in multi-select 「挑选导入」 (`SCAN_DOUYIN_PICKER_ITEMS`) and the `抓图` tab hint, and incrementally syncs items without duplicates (`douyin:<aweme_id>`).
- [ ] **AC-2 (R2 Zero-Download Video Bookmarks, Auto-Tags & Opt-In Media)**: Favorited Douyin videos default to storing cover artwork (`900×1440` with play icon + `MM:SS` badge) + `.md` bookmark + `SocialPostMetadata` (`platform = "douyin"`) without downloading full MP4s into `Originals/`; desktop paste, bookmark, and `socialMedia` paths automatically append deduplicated `抖音视频` / `抖音图文` tags; Author Profile `media` mode downloads watermark-free MP4s only when `includeVideos` is enabled; single links and `v.douyin.com` short links resolve cleanly.
- [ ] **AC-3 (R2 & R3 Quick Look Branching & Streaming)**: Opening a Douyin video bookmark in Quick Look streams inline via `proxy-video-stream` (falling back to `yt-dlp` if CDN URLs expire), supports "设当前帧为封面" updating thumbnails and `dominantColors`, and supports one-click "保存视频为独立素材" saving a standalone MP4; opening a Douyin multi-image note renders the 3:4 2-column grid with single/batch extraction.
- [ ] **AC-4 (R2 Forward-Compatible Wire Hardening)**: Rust unit tests verify `SocialPlatform::Douyin` round-trip, `douyin:<aweme_id>` dedup, Douyin CDN allowlist/Referer rules, AND decoding an unknown future `SocialPlatform` string in `SyncFields::merge` / `apply_op_shard` without error or transaction rollback.
- [ ] **AC-5 (R1 & R4 Packaging Parity & Zero-Warning Gates)**: `Resources/BrowserExtension/` and `windows/src-tauri/resources/BrowserExtension/` are byte-identical, all extension files are registered in `windows/src-tauri/tauri.conf.json`, and all verification commands pass with zero warnings:
  - `pwsh -NoProfile -ExecutionPolicy Bypass -File windows/scripts/verify-windows.ps1`
  - `node --test Resources/BrowserExtension/tests/extension.test.mjs`
  - `node scripts/test-figma-plugin.cjs`
- [ ] **AC-6 (R5 Handoff & Purity)**: A structured macOS/iOS/Web alignment task exists under `.trellis/tasks/`, and repository purity audit passes with 0 hits (zero personal paths, zero secrets, zero forbidden external product/author mentions).
