# Implementation Plan: Windows & Browser Extension Douyin Favorites Sync

> **Task**: `.trellis/tasks/11-27-windows-douyin-favorites-sync/`  
> **Companion Docs**: [`prd.md`](./prd.md) · [`design.md`](./design.md) · [`research/codebase-and-compatibility-audit.md`](./research/codebase-and-compatibility-audit.md)  
> **Scope**: Strictly `windows/` + `Resources/BrowserExtension/` (mirrored byte-identically to `windows/src-tauri/resources/BrowserExtension/`) + `.trellis/tasks/` handoff task. Never touch `Sources/`, `Tests/`, `ios/`, `android/`, `web/`, or `scripts/`.

---

## 0. Pre-Start Checklist (Before Running `task.py start`)

Execute these checks after user approves the Phase 1 plan:
1. **Validate Trellis task manifests** (ensures `implement.jsonl` and `check.jsonl` are populated with spec/research entries and `task.json` passes schema checks):
   ```powershell
   python ./.trellis/scripts/task.py validate 11-27-windows-douyin-favorites-sync
   ```
2. **Confirm clean working tree** (only `.trellis/tasks/11-27-windows-douyin-favorites-sync/` untracked/modified):
   ```powershell
   git status --porcelain -uall
   ```
3. **Transition task to `in_progress`** (optionally set `$env:TRELLIS_CONTEXT_ID` so `task.py current` tracks session state; otherwise degraded mode still updates `task.json` cleanly):
   ```powershell
   python ./.trellis/scripts/task.py start 11-27-windows-douyin-favorites-sync
   ```
4. **Read required coding specs** from `implement.jsonl` before writing code (`AGENTS.md`, `DESIGN.md`, `windows/AGENTS.md`, `.trellis/spec/cross-platform/index.md`, `.trellis/spec/windows/index.md`, `.trellis/spec/windows/fluent2-design-system.md`).

---

## Wave 0 — Windows Baseline Gate Prerequisite Fixes (R4)

Fix all 4 pre-existing verification blockers first so every subsequent wave runs against a green, zero-warning baseline.

### Checklist
- [ ] **0.1 `windows/src-tauri/tauri.conf.json:57-78`**: Add the 4 missing v1.3.0 `BrowserExtension` entries under `bundle.resources` (preserving `"resources/..." : "Resources/..."` casing):
  - `"resources/BrowserExtension/page-bridge.js": "Resources/BrowserExtension/page-bridge.js"`
  - `"resources/BrowserExtension/x-bridge-loader.js": "Resources/BrowserExtension/x-bridge-loader.js"`
  - `"resources/BrowserExtension/lib/social-collectors.js": "Resources/BrowserExtension/lib/social-collectors.js"`
  - `"resources/BrowserExtension/lib/x-author-media.js": "Resources/BrowserExtension/lib/x-author-media.js"`
- [ ] **0.2 `windows/ui/vite.config.ts:25-30`**: Add `testTimeout: 20_000` inside `test: { ... }` so full `<App />` jsdom suites (`m4-moodboard-studio.test.tsx`, `m5-settings-ai-onboarding.test.tsx`) never flake at 5000ms.
- [ ] **0.3 Rust 1.97.1 Clippy `-D warnings` fixes**:
  - `windows/crates/charkle-core/src/media/resolvers.rs:585-586`: Delete redundant `drop(push_vid);` and `drop(push_img);` (`clippy::drop_non_drop`).
  - `windows/crates/charkle-platform-win/src/shelf_win.rs:1152-1153`: Replace `elapsed_since_trigger_secs < 0.0 || elapsed_since_trigger_secs > Self::APPROACH_GRACE_SECS` with `!(0.0..=Self::APPROACH_GRACE_SECS).contains(&elapsed_since_trigger_secs)` (`clippy::manual_range_contains`).
- [ ] **0.4 `Resources/BrowserExtension/tests/extension.test.mjs:161-164`**: Make the `START_BOOKMARK_IMPORT` content-script assertion CRLF-safe on Windows (`contentJs.replace(/\r\n/g, '\n').includes(...)` or `/case 'START_BOOKMARK_IMPORT':\r?\n\s+sendResponse\(startBookmarkImport\(msg\.options \|\| \{\}\)\);/`).

### Wave 0 Gate
```powershell
node --test Resources/BrowserExtension/tests/extension.test.mjs
pwsh -NoProfile -ExecutionPolicy Bypass -File windows/scripts/verify-windows.ps1
```
**Expected**: Both exit `0` with zero clippy warnings and zero test failures.

---

## Wave 1 — Live Douyin Schema Verification & Browser Extension Implementation (R1)

### 1A. Live Douyin Web API & DOM Verification (`chrome-mcp-server`)
> **Hard Safety Rule**: Never bypass login walls, CAPTCHAs, slider verifications, or anti-bot gates. If Douyin prompts for login or verification, ask the user to complete it directly in the visible Chrome window, then observe passive network payloads & DOM structure.

- [ ] **1.1** Use `chrome-mcp-server` on the user's logged-in Douyin tabs to confirm live URL patterns, response JSON paths, and DOM selectors across all target views:
  1. Favorites (`/user/self?showTab=favorite_collection`): verify `/aweme/v1/web/aweme/listcollection/` response schema (`aweme_list`, `aweme_id`, `aweme_type`, `desc`, `create_time`, `author`, `statistics`, `video.bit_rate`/`video.play_addr`/`video.origin_cover`, `images`).
  2. Sub-collections (`收藏夹` tab & opening a specific sub-folder): verify `/aweme/v1/web/collects/list/` (`collects_list`, `collects_id_str`/`collects_name`) and `/aweme/v1/web/collects/video/list/`, plus DOM title/header selector for the active sub-folder name and modal/drawer scroll container.
  3. Likes (`/user/self?showTab=like`): verify `/aweme/v1/web/aweme/favorite/`.
  4. Author profile (`/user/<sec_uid>`): verify `/aweme/v1/web/aweme/post/`, tab click selectors for `作品` / `喜欢` / `收藏`, and author nickname DOM selector.
  5. Single video (`/video/<id>`), photo-note (`/note/<id>`), and modal playback (`?modal_id=<id>`): verify `/aweme/v1/web/aweme/detail/` and DOM fallback selectors.
  6. Confirm whether Douyin photo-notes use `aweme_type === 68` and check `.heic` vs `.jpeg`/`.webp` ordering in `images[].url_list` and `video.origin_cover.url_list`.

### 1B. Browser Extension Implementation (`Resources/BrowserExtension/`)
- [ ] **1.2 `Resources/BrowserExtension/manifest.json`**:
  - Add `https://douyin.com/*`, `https://www.douyin.com/*`, `https://m.douyin.com/*` to both `content_scripts[0].matches` (`L45-61`) and `web_accessible_resources[1].matches` (`L110-126`).
  - Update `description` to include Douyin (`抖音`).
- [ ] **1.3 `Resources/BrowserExtension/lib/url-detect.js`** *(keep self-contained for Safari `build-safari-extension.sh` classic SW compatibility)*:
  - Add `DOUYIN_HOSTS`, `DOUYIN_SHORT_HOSTS` (`v.douyin.com`, `www.v.douyin.com`), `isValidDouyinAwemeId(id)` (15–22 ASCII digits), `extractDouyinAwemeId(url)`, `normalizeDouyinPostUrl(raw)`.
  - Extend `detectSourceKind` (`'douyin'`), `canonicalDedupKey` (`douyin:<aweme_id>`), and `detectCollectionRoute` (1:1 Xiaohongshu parity: `collect`, `board`, `likes`, `profile`, `feed`).
- [ ] **1.4 `Resources/BrowserExtension/lib/douyin-parser.js`** *(new pure ESM module, mirroring `lib/xhs-parser.js`; imports only `./url-detect.js`)*:
  - Implement `normalizeDouyinUrl`, `extractDouyinShareCopyUrl`, `pickBestDouyinImageUrl` (deprioritizing `.heic`/`.heif` in favor of JPEG/WebP/PNG), `pickBestDouyinVideoUrl` (preferring H.264 MP4 from `bit_rate`/`play_addr`, excluding watermarked `download_addr`/`playwm`), `extractDouyinPostsFromPayload`, `extractDouyinCollectionsFromPayload`.
- [ ] **1.5 `Resources/BrowserExtension/page-bridge.js`** *(classic script, zero `import`/`export`)*:
  - Add `'douyin'` platform detection, read-only `isTargetEndpoint(url)` matching verified endpoints (`listcollection`, `collects/list`, `collects/video/list`, `favorite`, `post`, `detail`), and passive `fetch`/`XHR` payload extraction emitting `__charkleSocialBridge: true, platform: 'douyin'` (`GRAPHQL_POSTS` + `DOUYIN_COLLECTIONS`).
- [ ] **1.6 `Resources/BrowserExtension/content.js`** *(classic script, zero `import`/`export`)*:
  - Allow `isDouyinHost(host)` in `initXGraphQLBridgeListener` (`L95-129`); populate `capturedSocialPostsByKey` + `douyinCollectionsById`.
  - Extend `detectCurrentCollectionPage` (`L505-933`) & `setupSpaRouteWatcher` (`L4206-4227`) for all 1:1 Xiaohongshu routes + active Douyin tab & sub-collection folder name detection.
  - Add `ensureDouyinCollectTabActive` (mirroring `L3276-3303`), Douyin inner scroll-container detection in `findActiveScrollTarget` (`L3391-3409`), `harvestVisibleDouyinItems` in `harvestNow` (`L3616-3636`) with DOM fallback (`/video/`, `/note/`, `modal_id=`), and login/verification overlay pause guard.
  - Wire `flushChunk` (`L3669-3794`) cache hydration for both `bookmarks` (`INGEST_SOCIAL_BOOKMARKS_CHUNK`) and `author_media` (`INGEST_SOCIAL_MEDIA_CHUNK` respecting `includeVideos`).
  - Extend `updateFloatingLauncherVisibility` (`L1660-1715`) CTA labels (`一键导入抖音收藏` / `一键导入「<夹名>」` / `一键导入抖音喜欢` / `采集抖音作者作品`).
  - Add `extractCurrentSingleDouyinPost()` to `getPageContext` (`L4185-4202`).
- [ ] **1.7 `Resources/BrowserExtension/background.js` & `popup.js` / `popup.html`**:
  - `background.js:510`: Extend browser-context single-page capture branch from `sourceInfo.kind === 'xiaohongshu'` to include `'douyin'`.
  - Ensure `INGEST_SOCIAL_BOOKMARKS_CHUNK` forwards `durationSeconds` / `videoID` / `media` / `hasVideo` / `videoURL` cleanly.
  - `popup.js` / `popup.html`: Expose Douyin profile dual-mode toggle (`作品原文件` vs `收藏卡片`) + `包含视频` checkbox (media mode), auto-tab switch, and `+ 抖音收藏` / `+ 抖音喜欢` / `+ <夹名或作者名>` quick-folder button.
- [ ] **1.8 `Resources/BrowserExtension/tests/extension.test.mjs`**:
  - Add unit tests for `lib/douyin-parser.js` (video post, multi-image `aweme_type: 68` photo-note, HEIC deprioritization, `play_addr` H.264 selection, `collects/list` mapping, share-copy URL extraction), `lib/url-detect.js` (`douyin:<aweme_id>`, `?modal_id=`, `v.douyin.com`, collection routes), `manifest.json` Douyin matches, classic-script `node --check` on `content.js` & `page-bridge.js`, and fixture parity between `lib/douyin-parser.js` and `page-bridge.js`.

### 1C. Mirror Sync & `tauri.conf.json` Registration
- [ ] **1.9** Sync `Resources/BrowserExtension/` byte-identically to `windows/src-tauri/resources/BrowserExtension/` (excluding `tests/`).
- [ ] **1.10** Add `"resources/BrowserExtension/lib/douyin-parser.js": "Resources/BrowserExtension/lib/douyin-parser.js"` to `windows/src-tauri/tauri.conf.json`.

### Wave 1 Gate
```powershell
node --check Resources/BrowserExtension/content.js
node --check Resources/BrowserExtension/page-bridge.js
node --check Resources/BrowserExtension/x-bridge-loader.js
node --test Resources/BrowserExtension/tests/extension.test.mjs
```
Verify byte-identical mirror (PowerShell hash comparison between `Resources/BrowserExtension` and `windows/src-tauri/resources/BrowserExtension`, excluding `tests/`).

---

## Wave 2 — Windows Rust Core & Tauri Protocol Implementation (R2)

### Checklist
- [ ] **2.1 `windows/crates/charkle-core/src/models/core.rs`**:
  - Add `SocialPlatform::Douyin` and `SocialPlatform::Unknown(String)` (drop `Copy`, keep `Clone, Debug, PartialEq, Eq, Hash`).
  - Implement lossless custom `Serialize` & `Deserialize` for `SocialPlatform` (preserving unrecognized wire strings verbatim).
  - Add `prefers_zero_download_video_bookmark(&self) -> bool` (`Youtube | Bilibili | Douyin`), keeping `is_video_platform(&self) -> bool` strictly `Youtube | Bilibili`.
  - Update `raw_value(&self) -> &str`, `from_raw`, `display_name(&self) -> &str`, `post_noun`, `post_type_label`, `open_action_label`.
  - Update `SocialPostMetadata::display_handle_line` & `display_author_name` to sanitize Douyin `sec_uid` (`MS4wLjAB...`) / numeric UIDs and format `抖音号 {trimmed}`.
- [ ] **2.2 `windows/crates/charkle-core/src/media/douyin.rs` & `media/mod.rs`**:
  - Create `media/douyin.rs` (`DOUYIN_REFERER`, `DouyinPostReference`, `DouyinURLParser`, `DouyinPostResolver` best-effort single-URL fallback, `v.douyin.com` SSRF-safe short-link expansion, share-copy URL extraction, `is_douyin_image_host`, `is_douyin_video_host`, `is_douyin_media_host`).
  - Export from `media/mod.rs`.
- [ ] **2.3 `windows/crates/charkle-core/src/media/resolvers.rs`**:
  - Add `SocialPostReference::Douyin(DouyinPostReference)` (`L2305+`) + `canonical_dedup_key` → `douyin:<aweme_id>`.
  - Allow `DouyinURLParser::is_douyin_image_host` in `is_allowed_social_proxy_host` (`L2163`).
  - Auto-attach `DOUYIN_REFERER` in `resolve_cdn_referer` (`L2819`) for `DouyinURLParser::is_douyin_media_host`.
  - Enhance `resolve_media_extension` (`L4496`) with `&[u8]` magic-byte sniffing (JPEG/PNG/WebP/GIF + ISO BMFF `ftyp` brand check: `avif`/`avis` → `avif`, `heic`/`heix`/`mif1`/`msf1` → `heic`, otherwise `mp4`) and pass `&bytes` from `download_media_bytes_with_referer` (`L2951`); refine `sniff_social_media_content_type` (`L4125`).
- [ ] **2.4 `windows/crates/charkle-core/src/media/pipeline.rs`**:
  - Expand `v.douyin.com` short links in `WebUrl` branch before `SocialPostURLParser::parse`.
  - Switch video download skip gates at `L534`, `L824`, `L901` to `!platform.prefers_zero_download_video_bookmark()`.
  - Update `needs_live_enrich` (`L794-816`) for `SocialPlatform::Douyin` (enrich only when sparse: empty attachments AND empty body) and `SocialPlatform::Unknown(_) => false`.
  - Set `pre_duration = meta.video_duration_seconds` for Douyin video bookmarks.
- [ ] **2.5 `windows/crates/charkle-core/src/media/artwork.rs`**:
  - Route `SocialPlatform::Douyin` alongside `SocialPlatform::Xiaohongshu` (`L122`) to shared `900×1440` `vertical_social_feed_card` (keeping public `xiaohongshu_post_card` wrapper intact).
  - Render bottom-right `MM:SS` duration pill on `has_video` Douyin cards when `formatted_duration()` is present, and top-left `N 图` pill on multi-image photo-notes.
  - Add `SocialPlatform::Douyin => "#161823"` and `SocialPlatform::Unknown(_) => "#52525B"` in `L145-153`.
- [ ] **2.6 `windows/crates/charkle-core/src/media/video_platform.rs` & `windows/src-tauri/src/protocol.rs`**:
  - `resolve_playback_plan` (`L1142-1196`): Handle `SocialPlatform::Douyin` with `Referer: https://www.douyin.com/` for direct streams + `resolve_direct_stream_via_yt_dlp_if_available` fallback when `direct_streams.is_empty()` (or refresh fallback on expired stream).
  - `fetch_video_stream_chunk` (`L2516-2664`): Auto-attach `https://www.douyin.com/` Referer for Douyin video hosts; normalize `application/octet-stream` (or empty `Content-Type`) to `video/mp4` when `bytes` begins with `ftyp` or host is a Douyin VOD host.
  - `download_generic_web_video` (`L1863-1869`): Include `DouyinURLParser::is_douyin_video_host(direct.host_str())` in `looks_direct`.
- [ ] **2.7 `windows/crates/charkle-core/src/bridge.rs` & `engine.rs`**:
  - Update `bridge.rs` exhaustive `SocialPlatform` matches (`L1697-1766`, `L1168`, `L2372`) for `Douyin` (`"原作品："`, nickname-first author line/tags) and `Unknown(_)`.
  - Forward `durationSeconds` / `videoID` in social bookmark ingest parsing.
  - Update `engine.rs` call sites (`L2677`, `L3998-4045`) for non-`Copy` `SocialPlatform` (`&self` / `.clone()`), verifying `extract_link_media_attachment` (`L4096-4150`) handles Douyin video save cleanly.
- [ ] **2.8 Rust Unit & Integration Tests**:
  - `SocialPlatform::Douyin` + `SocialPlatform::Unknown("futurePlatform")` lossless `serde_json` round-trip, `SyncFields::merge`, and `LibraryDatabase::apply_op_shard` tests (verifying zero rollback on unknown future platform strings).
  - `DouyinURLParser` tests: `/video/<id>`, `/note/<id>`, `?modal_id=<id>`, `iesdouyin.com`, `v.douyin.com`, Chinese share-copy extraction, canonical `douyin:<aweme_id>` dedup across `existing-sources` & bridge ingest.
  - `resolve_media_extension` & `fetch_video_stream_chunk` tests: `application/octet-stream` + `ftyp isom` → `mp4` / `video/mp4`, `ftyp avif` → `avif`, `ftyp heic` → `heic`, Douyin CDN allowlist & Referer enforcement, SSRF loopback/private-IP rejection.
  - `pipeline.rs` zero-download verification test: `SocialBookmark` for `SocialPlatform::Douyin` with `has_video: true` persists `MediaKind::WebBookmark` without downloading MP4; `900×1440` artwork test for both Douyin video (with duration) and multi-image photo-note (`N 图`).

### Wave 2 Gate
```powershell
Push-Location windows
cargo fmt --all -- --check
cargo clippy --workspace --all-targets -- -D warnings
cargo test --workspace
Pop-Location
```

---

## Wave 3 — Windows React UI Implementation (R3)

### Checklist
- [ ] **3.1 `windows/ui/src/types/domain.ts`**:
  - Add `'douyin'` to `SocialPlatform`; add `isVerticalSocialFeedPlatform(platform)` and `usesStreamingVideoViewer(post)`.
  - Extend `formatSocialDisplayHandle`, `resolveSocialMediaUrl` (Douyin CDN proxy routing), and `getEffectiveSocialAttachments` (`L326`).
- [ ] **3.2 `windows/ui/src/features/quicklook/SocialPostViewer.tsx` & `QuickLookOverlay.tsx`**:
  - Add `douyin` entry to `PLATFORM_META` (`name: '抖音'`, `openLabel: '在抖音中打开'`, `badgeBg: '#161823'`, `noun: '作品'`).
  - Branch Quick Look viewer per item (`usesStreamingVideoViewer(post)`):
    - `douyin && post.hasVideo` → `<QuickLookStreamingVideoView />` (streaming playback + **"设当前帧为封面"** + **"保存视频为独立素材"**).
    - `douyin && !post.hasVideo` → `isVerticalMultiGrid` (`3:4` 2-column photo-note grid + single & batch image extraction).
  - Update `QuickLookOverlay.tsx:1046-1056` for Douyin header/badge parity.
- [ ] **3.3 Gallery, Inspector, Shelf & Paste Parity**:
  - `windows/ui/src/features/gallery/masonryLayout.ts:160-171` (`0.625` vertical aspect fallback)
  - `windows/ui/src/features/gallery/ringGalleryMath.ts:163-169`
  - `windows/ui/src/features/gallery/AssetCard.tsx:82-85, 215` (`'抖音'` badge & vertical fallback card)
  - `windows/ui/src/features/gallery/GalleryFilmstripView.tsx:86, 951`
  - `windows/ui/src/features/inspector/InspectorView.tsx:120, 2088-2145` (`'抖音作品'` + on-demand video extraction button)
  - `windows/ui/src/App.tsx:199-201, 241` (clipboard paste & share-copy regex for `douyin.com` / `v.douyin.com`)
  - `windows/ui/src/features/shelf/TopEdgeDropShelf.tsx:199-208`
  - `windows/ui/src/api/transport.ts:1907-1935` (browser-dev mock)
- [ ] **3.4 Vitest Unit & Component Tests (`windows/ui/src/__tests__/`)**:
  - Test `SocialPostViewer` renders `<QuickLookStreamingVideoView />` for `douyin` video posts and `isVerticalMultiGrid` for `douyin` photo-notes (`!hasVideo`).
  - Test `formatSocialDisplayHandle` omits `sec_uid`/numeric UIDs and formats `抖音号 ...`.
  - Test `resolveSocialMediaUrl` proxies Douyin CDN hosts in Tauri runtime.
  - Test `masonryLayout` / `ringGalleryMath` / `AssetCard` / `InspectorView` parity for `douyin`.
  - Verify Fluent 2 / `DESIGN.md` compliance: zero violet chrome, zero `transition: all`, Light & Dark contrast parity.

### Wave 3 Gate
```powershell
Push-Location windows/ui
npm run typecheck
npm test
npm run build
Pop-Location
```

---

## Wave 4 — Cross-Platform Handoff Task, E2E Integration & Full Verification (R5)

### Checklist
- [ ] **4.1 Create Cross-Platform Parity Handoff Task (`.trellis/tasks/`)**:
  - Run `python ./.trellis/scripts/task.py create "Cross-Platform Douyin SocialPlatform & Sync Parity (macOS / iOS / Web)" --slug cross-platform-douyin-socialplatform-parity --package macos -d "Align macOS/iOS Swift CoreModels, DriveSyncEngine unknown-platform fallback, Safari extension packaging, and Web swift-codec for SocialPlatform::Douyin" --assignee XXXxx7258`.
  - Populate its `prd.md` with exact contract specs (`case douyin = "douyin"`, `douyin:<aweme_id>`, Swift `SocialPostMetadata`/`AssetRichMetadata` unknown-platform graceful decode fallback, `scripts/build-safari-extension.sh` `page-bridge.js` / `x-bridge-loader.js` / `lib/` updates, Web `swift-codec.ts` alignment, and the **mandatory pre-upgrade cloud-sync caveat for macOS/iOS v1.5.1 users**).
  - Do **NOT** edit any file under `Sources/`, `Tests/`, `ios/`, `android/`, `web/`, or `scripts/`.
- [ ] **4.2 Live End-to-End Walkthrough (`tauri dev` + `chrome-mcp-server`)**:
  - Run Charkle Desktop in `tauri dev` (`windows/`) and load the unpacked `Resources/BrowserExtension/` in Chrome.
  - Verify end-to-end on real Douyin pages (user signs in manually; pause cleanly on any login/verification overlay):
    1. Favorites page (`/user/self?showTab=favorite_collection`): floating launcher shows `一键导入抖音收藏`, Popup auto-switches to Batch tab, `+ 抖音收藏` quick-folder works, incremental sync imports cards with `900×1440` covers & zero MP4 files written into `Originals/`.
    2. Specific sub-collection (`收藏夹`子夹): suggested folder matches active sub-collection name.
    3. Re-run sync on same page: `existing-sources` skips already-synced `douyin:<aweme_id>` items cleanly (`skipped > 0`, `imported === 0`).
    4. Likes page (`/user/self?showTab=like`) & Author Profile dual mode (`media` with/without `includeVideos` vs `bookmarks` with auto-switch to 收藏 tab).
    5. Single `/video/<id>`, `/note/<id>`, `?modal_id=<id>` clipping via Popup / `Alt+Shift+C`, plus pasting a `v.douyin.com` share copy directly into Charkle Desktop.
    6. Quick Look on a Douyin video card: streams via `/proxy-video-stream`, **"设当前帧为封面"** updates card cover, **"保存视频为独立素材"** extracts a playable local `.mp4` asset.
    7. Quick Look on a Douyin multi-image photo-note card: displays 3:4 2-column grid and extracts individual/all images cleanly.
    8. Confirm `< 1%` idle CPU after sync/preview settles and Light/Dark theme visual polish.
- [ ] **4.3 Final Automated Verification Suite**:
  ```powershell
  # 1. Browser Extension syntax & unit tests
  node --check Resources/BrowserExtension/content.js
  node --check Resources/BrowserExtension/page-bridge.js
  node --check Resources/BrowserExtension/x-bridge-loader.js
  node --test Resources/BrowserExtension/tests/extension.test.mjs

  # 2. Figma plugin script syntax check (non-destructive sanity check)
  node --check Resources/FigmaPlugin/code.js

  # 3. Byte-identical BrowserExtension mirror verification & tauri.conf.json completeness check
  $srcRoot = (Resolve-Path 'Resources/BrowserExtension').Path
  $dstRoot = (Resolve-Path 'windows/src-tauri/resources/BrowserExtension').Path
  $tauriJson = Get-Content 'windows/src-tauri/tauri.conf.json' -Raw | ConvertFrom-Json
  $registered = $tauriJson.bundle.resources.PSObject.Properties.Name
  Get-ChildItem $srcRoot -Recurse -File | Where-Object { $_.FullName -notmatch '\\tests\\' } | ForEach-Object {
    $rel = $_.FullName.Substring($srcRoot.Length + 1).Replace('\', '/')
    $dst = Join-Path $dstRoot $rel
    if (-not (Test-Path $dst)) { throw "Missing mirror file: $rel" }
    if ((Get-FileHash $_.FullName -Algorithm SHA256).Hash -ne (Get-FileHash $dst -Algorithm SHA256).Hash) {
      throw "Mirror hash mismatch: $rel"
    }
    $key = "resources/BrowserExtension/$rel"
    if ($registered -notcontains $key) { throw "Unregistered in tauri.conf.json: $key" }
  }
  Write-Output "EXTENSION_MIRROR_AND_TAURI_CONF_OK"

  # 4. Full Windows zero-warning verification gate (icons, UI typecheck/test/build, fmt, clippy -D warnings, cargo test)
  pwsh -NoProfile -ExecutionPolicy Bypass -File windows/scripts/verify-windows.ps1

  # 5. Repository purity & secret scan (zero rg dependency)
  $paths = git status --porcelain -uall | ForEach-Object {
    $p = $_.Substring(3).Trim() -replace '^.* -> ', ''
    if ($p -and (Test-Path $p -PathType Leaf)) { $p }
  }
  $pat = '(/Users/[A-Za-z0-9._-]+/|C:\\Users\\[A-Za-z0-9._-]+\\|GoogleOAuthClient\.json|BEGIN (RSA |EC |OPENSSH )?PRIVATE KEY|AIza[0-9A-Za-z_-]{35}|sk-[A-Za-z0-9]{20,}|ghp_[A-Za-z0-9]{36})'
  $hits = if ($paths) { Select-String -Path $paths -Pattern $pat -CaseSensitive:$false } else { @() }
  Write-Output "FILES_SCANNED=$($paths.Count) HITS=$($hits.Count)"
  $hits | ForEach-Object { Write-Output "HIT: $($_.Path):$($_.LineNumber): $($_.Matches[0].Value)" }
  ```
- [ ] **4.4 Workspace Boundary Check**: Run `git status --porcelain -uall` and confirm **zero** modified files under `Sources/`, `Tests/`, `ios/`, `android/`, `web/`, or `scripts/`.

---

## High-Risk Files & Rollback Points

| High-Risk File | Why It Is Sensitive | Rollback / Containment Strategy |
| :--- | :--- | :--- |
| `windows/crates/charkle-core/src/models/core.rs` | `SocialPlatform` wire serde governs `/.charkle/` sync compatibility across all clients; removing `Copy` touches ~7 files in `charkle-core`. | Commit Wave 2 separately after verifying `SyncFields::merge` & `apply_op_shard` round-trip tests for all 9 known platforms + unknown future tokens. |
| `windows/crates/charkle-core/src/media/pipeline.rs` | Incorrectly wiring `prefers_zero_download_video_bookmark()` could break X/XHS video download or accidentally download gigabytes of Douyin MP4s. | Dedicated unit tests asserting Xiaohongshu/X behavior is unchanged while Douyin bookmarks skip eager MP4 download. |
| `windows/crates/charkle-core/src/media/video_platform.rs` & `windows/src-tauri/src/protocol.rs` | HTTP 206 Range proxy SSRF guard and `Content-Type` rewriting directly handle remote HTTPS URLs. | Preserve strict HTTPS + post-redirect `is_safe_public_media_url` checks; add targeted unit tests for loopback/RFC1918 rejection and `octet-stream` `ftyp` rewriting. |
| `Resources/BrowserExtension/page-bridge.js` & `content.js` | Classic scripts injected on high-traffic pages (X, IG, Threads, Bluesky, Xiaohongshu, Douyin); syntax error or unhandled exception breaks existing collectors. | Run `node --check` + full `extension.test.mjs` covering X/XHS/IG/Threads/BSky regressions before touching desktop mirror. |
| `Resources/BrowserExtension/lib/url-detect.js` | Consumed by Safari classic Service Worker bundler (`scripts/build-safari-extension.sh:89`). | Keep Douyin URL helpers self-contained inside `lib/url-detect.js` (zero imports from `lib/douyin-parser.js`). |
| `windows/ui/src/features/quicklook/SocialPostViewer.tsx` | Shared Quick Look viewer for all 9 social platforms; incorrect condition could hide YouTube/Bilibili player or Xiaohongshu multi-image grid. | Add explicit Vitest regression assertions for YouTube, Bilibili, Xiaohongshu, Douyin video, and Douyin photo-note. |
| `windows/src-tauri/tauri.conf.json` | Missing or mis-cased resource keys cause NSIS installer build failures or broken bundled extension. | Verified programmatically in Wave 4 via mirror + `tauri.conf.json` completeness script. |
