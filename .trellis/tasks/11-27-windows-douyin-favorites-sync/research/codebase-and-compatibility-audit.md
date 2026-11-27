# Research Audit: Douyin Favorites Sync (Windows & Browser Extension)

> **Task**: `.trellis/tasks/11-27-windows-douyin-favorites-sync/`  
> **Scope**: Read-only codebase & cross-platform compatibility audit for Phase 1 planning.  
> **Primary Authorities**: `AGENTS.md`, `DESIGN.md`, `.trellis/spec/cross-platform/index.md`, `.trellis/spec/windows/index.md`, `.trellis/spec/windows/fluent2-design-system.md`, `windows/AGENTS.md`.

---

## 1. v1.5.0 / v1.5.1 Video Bookmark & Zero-Download Streaming Architecture

### 1.1 Current State in Windows Rust Core & UI
- **No Douyin platform support yet**:
  - `SocialPlatform` in `windows/crates/charkle-core/src/models/core.rs:114-123` defines 8 variants: `X | Threads | Bluesky | Xiaohongshu | Pixiv | Instagram | Youtube | Bilibili`.
  - `VideoPlatformReference` in `windows/crates/charkle-core/src/media/video_platform.rs:82-94` defines only `Youtube | Bilibili`.
  - `windows/ui/src/types/domain.ts:58-71` mirrors the same 8 literals and defines `isVideoSocialPlatform` as `youtube | bilibili`.
- **Reusable v1.5.0 / v1.5.1 streaming & cover infrastructure already live end-to-end**:
  1. **Playback plan resolution**:
     - `windows/crates/charkle-core/src/media/video_platform.rs:1142-1196` (`resolve_playback_plan`): for non-Bilibili/YouTube social posts, iterates `post.effective_attachments()` for `Video | Gif` and constructs a `VideoDirectStream` with `STREAM_BROWSER_UA` + `Referer`.
     - `video_platform.rs:1200-1261` (`resolve_web_page_playback_plan`) handles generic `WebPageRichMetadata` video streams.
     - `video_platform.rs:1749-1831` (`resolve_direct_stream_via_yt_dlp_if_available`) runs zero-download URL extraction (`yt-dlp --no-playlist --no-warnings -g -f best[ext=mp4]/best[protocol*=m3u8]/best`, 6s timeout, Windows `CREATE_NO_WINDOW` `0x0800_0000`).
  2. **Zero-copy HTTP 206 Range streaming proxy**:
     - `windows/src-tauri/src/protocol.rs:112-207` + `video_platform.rs:2459-2664` (`fetch_video_stream_chunk`) expose `charkle-media://localhost/proxy-video-stream?url=&referer=&ua=` with public HTTPS + post-redirect SSRF validation, open-ended Range clamping (2 MiB/chunk, 4 MiB cap), Referer validation/fallback, and `CORS: *` (enabling `<video crossOrigin="anonymous">` canvas frame capture).
  3. **On-demand video save to standalone asset**:
     - `windows/crates/charkle-core/src/engine.rs:4100-4145` (`extract_link_media_attachment`) attempts direct `download_media_bytes_with_referer`, then falls back to `download_generic_web_video` (`video_platform.rs:1855-1894`) and `download_via_yt_dlp_if_available` (`video_platform.rs:2224-2292`, muxing up to 1080p MP4).
  4. **Frame-to-cover selection ("设当前帧为封面")**:
     - `windows/ui/src/features/quicklook/QuickLookStreamingVideoView.tsx:21-53, 239-288` (Tier 1 offscreen `<canvas>` 1600px JPEG 0.9; Tier 2 `captureWebviewRegionJpeg` -> `video_platform.rs:2668-2709` `crop_png_region_to_jpeg`) and `SocialPostViewer.tsx:223-236, 511-522` (`social-video-set-cover-btn`) call `engine.rs:2605-2653` (`update_asset_cover_image`) to persist custom covers, refresh `dominantColors`, and update thumbnails/sync projections.

### 1.2 Critical Pitfall: Decoupling `is_video_platform()` for Dual Video + Multi-Photo Content
- Currently, `is_video_platform()` (`windows/crates/charkle-core/src/models/core.rs:126-128`, `windows/ui/src/types/domain.ts:69-71`) couples three separate concerns:
  1. Skipping eager MP4 downloads at ingest (`windows/crates/charkle-core/src/media/pipeline.rs:534, 824, 901`);
  2. Forcing 16:9 `1280×720` horizontal video cards (`artwork.rs:119`);
  3. Hiding the multi-image attachment grid in `SocialPostViewer.tsx:303, 415`.
- Because Douyin hosts **both vertical short videos and multi-image notes ("图文")**:
  - Leaving Douyin out of zero-download gating would cause `pipeline.rs:901` to eagerly download every favorited MP4 into `Originals/`.
  - Adding Douyin directly into `is_video_platform()` would force vertical videos and multi-image posts into 16:9 horizontal cards and hide the multi-image gallery.
- **Recommended Reuse Design**:
  1. Introduce an independent predicate on `SocialPlatform` (e.g., `prefers_zero_download_video_bookmark()` returning `true` for `Youtube | Bilibili | Douyin`) wired into `pipeline.rs:534, 824, 901`, so favorites ingest stores only cover artwork + `.md` bookmark + `richMetadata` (preserving `videoID`, `videoDurationSeconds`, `hasVideo`, `videoURL`, `attachments`).
  2. Extend streaming & CDN proxy allowlists / Referer rules:
     - `video_platform.rs::resolve_playback_plan`: attach `Referer: https://www.douyin.com/` for Douyin and fall back to `resolve_direct_stream_via_yt_dlp_if_available` when ephemeral stream URLs are missing or expired.
     - `video_platform.rs::fetch_video_stream_chunk`: auto-supply Douyin Referer for `*.douyinvod.com`, `*.zjcdn.com`, `*.snssdk.com`, `*.bytevcloudapi.com`.
     - `resolvers.rs:2163` (`is_allowed_social_proxy_host`), `resolve_cdn_referer`, and `windows/ui/src/types/domain.ts:230` (`resolveSocialMediaUrl`): allow Douyin image CDNs (`*.douyinpic.com`, `*.byteimg.com`, `*.ibytedtos.com`, `*.zjcdn.com`, `*.snssdk.com`, `*.amemv.com`).
  3. Render cards & Quick Look by **per-item content type**:
     - Gallery card (`artwork.rs`): adopt the `900×1440` vertical feed card spec (`3:4` `900×1200` cover + `240px` white footer; video items overlay play badge + bottom-right `MM:SS` duration badge; multi-image items overlay top-left `N 图` badge).
     - Quick Look (`SocialPostViewer.tsx`): `hasVideo == true` renders `<QuickLookStreamingVideoView />` (zero-download streaming + frame-to-cover + on-demand "保存视频为独立素材"); `!hasVideo` renders `isVerticalMultiGrid` (`L150, 415-613`, 3:4 2-column grid with single/batch image extraction).

---

## 2. `page-bridge.js` Passive Interception Contract & `content.js` Integration Points

### 2.1 Injection Chain
- `Resources/BrowserExtension/manifest.json:43-66, 106-127` + `Resources/BrowserExtension/x-bridge-loader.js:1-23`:
  - Add `https://douyin.com/*`, `https://www.douyin.com/*`, `https://m.douyin.com/*` to both `content_scripts[0].matches` and `web_accessible_resources[1].matches` so `x-bridge-loader.js` injects `page-bridge.js` into the page main world at `document_start` in the top frame.

### 2.2 Read-Only Passive Interception & `window.postMessage` Contract
- `Resources/BrowserExtension/page-bridge.js:16-66, 497-580`:
  - Strictly passive observation of `window.fetch` (`res.clone().text()`) and `XMLHttpRequest` (`load` listener) — **never forge anti-bot signatures (`a_bogus` / `X-Bogus`) or initiate unauthorized active API requests**.
  - Target Douyin Web API endpoints for `isTargetEndpoint(url)`:
    - All favorites: `/aweme/v1/web/aweme/listcollection/`
    - Collections directory (`collects_id -> collects_name` map): `/aweme/v1/web/collects/list/`
    - Videos inside a collection folder: `/aweme/v1/web/collects/video/list/`
    - Likes: `/aweme/v1/web/aweme/favorite/`
    - Author posts: `/aweme/v1/web/aweme/post/`
    - Single item detail: `/aweme/v1/web/aweme/detail/`
  - Outbound `window.postMessage` envelope (aligned with X / Instagram / Threads / Bluesky):
    ```js
    window.postMessage({
      __charkleSocialBridge: true,
      __charkleXBridge: false,
      platform: 'douyin',
      type: 'GRAPHQL_POSTS', // optionally emit type: 'DOUYIN_COLLECTIONS' for folder metadata
      posts: normalizedPosts,
    }, window.location.origin);
    ```
  - Normalized item payload (aligned with `page-bridge.js:309-327, 441-459` & `Resources/BrowserExtension/lib/social-collectors.js:442-463, 655-673, 743-761`):
    - `{ platform: 'douyin', postID: awemeId, tweetID: awemeId, originalURL, dedupKey: 'douyin:<awemeId>', authorName, authorHandle, authorAvatarURL, publishedAtText, publishedDateKey, title, bodyText, isRetweet: false, likeCount, replyCount, repostCount, viewCount, durationSeconds, media: [{ kind: 'photo'|'video', url, thumbnailURL, width, height }], hasVideo, videoURL, needsEnrich: false, referer: 'https://www.douyin.com/', tags, collectionName? }`.

### 2.3 Exact Integration Points in `content.js` & `background.js`
1. `initXGraphQLBridgeListener` (`Resources/BrowserExtension/content.js:95-129`): allow `isDouyinHost(host)` so intercepted posts populate `capturedSocialPostsByKey` (5000-item cap, preferring richer `media.length` entries per `dedupKey`).
2. `detectCurrentCollectionPage` (`content.js:505-933`) & `setupSpaRouteWatcher` (`content.js:4206-4227`): recognize Douyin routes + active tab text in the SPA route signature (`L4217-4219`).
3. `findActiveScrollTarget` (`content.js:3391-3409`): detect inner scroll containers on Douyin profile and collection drawers/modals.
4. `harvestNow` (`content.js:3616-3636`): add `harvestVisibleDouyinItems(pageInfo, runOptions)` consuming `capturedSocialPostsByKey` first (respecting `includeVideos` in `author_media` mode), with DOM fallback scanning `/video/(\d+)`, `/note/(\d+)`, and `modal_id=(\d+)` for pre-injection/SSR items.
5. `flushChunk` (`content.js:3669-3794`): `author_media` reuses `L3722-3734` cache hydration -> `INGEST_SOCIAL_MEDIA_CHUNK` (`socialMedia`); `bookmarks` hydrates from latest cache -> `INGEST_SOCIAL_BOOKMARKS_CHUNK` (`socialBookmark`).
6. `getPageContext` (`content.js:4185-4202`) & `Resources/BrowserExtension/background.js:510`: single-page clipping calls `extractCurrentSingleDouyinPost()` (bridge cache + DOM fallback) and extends the `sourceInfo.kind === 'xiaohongshu'` branch at `background.js:510` to include `'douyin'`.

---

## 3. 1:1 Route & UX Coverage Mapping (Aligned with Xiaohongshu)

User confirmed that Douyin page coverage defaults to matching the existing Xiaohongshu design:

| Dimension | Xiaohongshu Reference Implementation | Douyin 1:1 Mapping |
| :--- | :--- | :--- |
| **Single-Post Clipping** | `/explore/<id>`, `/discovery/item/<id>`, `/user/profile/<uid>/<id>`, `xhslink.com/*` -> `xhs:<id>`; `GET_PAGE_CONTEXT` direct extract (`lib/url-detect.js:559-587`, `background.js:510`) | `/video/<aweme_id>`, `/note/<aweme_id>`, any page `?modal_id=<aweme_id>`, `v.douyin.com/<code>` -> `douyin:<aweme_id>`; `GET_PAGE_CONTEXT` reads bridge cache + DOM fallback |
| **Favorites / Collection Folders** | `/user/profile/<uid>?tab=collect` (or active "收藏" tab), `/board*`, `/collection*` -> `pageKind: 'collect'/'board'`, `bookmarks` mode, default folder `小红书收藏` (`content.js:686-768`) | `/user/self?showTab=favorite_collection`, `/user/<sec_uid>?showTab=favorite_collection` (all favorites & specific sub-collections, or active "收藏" tab) -> `pageKind: 'collect'/'board'`, `bookmarks` mode, prefer sub-collection name / default `抖音收藏` |
| **Likes Page** | `/user/profile/<uid>?tab=like` (or active "赞过/点赞" tab) -> `pageKind: 'likes'`, `bookmarks` mode, default folder `小红书点赞` | `/user/self?showTab=like`, `/user/<sec_uid>?showTab=like` (or active "喜欢" tab) -> `pageKind: 'likes'`, `bookmarks` mode, default folder `抖音喜欢` |
| **Profile Dual Mode** | `/user/profile/<uid>` default posts tab -> `pageKind: 'profile'`, Popup switches `media` (author works) vs `bookmarks` (favorites & likes), folder `<作者名>` / `小红书收藏` | `/user/<sec_uid>` / `/user/self` default posts tab -> `pageKind: 'profile'`, Popup switches `media` (author works) vs `bookmarks` (favorites & likes cards), folder `<作者名>` / `抖音收藏` |
| **Auto-Switch Collect Tab** | `ensureXiaohongshuCollectTabActive` (`content.js:3276-3303`): `profile` + `!isMediaMode` auto-clicks "收藏" tab & waits 2.4s | `ensureDouyinCollectTabActive`: `profile` + `!isMediaMode` auto-clicks "收藏" tab & waits for API/list render |
| **Generic Feed / Search** | Discover/search pages with `.note-item` -> `pageKind: 'feed'`, `isCollectionRoute: false` (no floating launcher; manual batch scan via Popup) | Recommend/search/discover feeds with item cards -> `pageKind: 'feed'`, `isCollectionRoute: false` (no floating launcher; manual batch scan via Popup) |
| **Floating Launcher** | `updateFloatingLauncherVisibility` (`content.js:1660-1715`): `supported && isCollectionRoute !== false && configured && ...` | Same visibility/dock state machine; labels: `一键导入抖音收藏` (or folder name) / `一键导入抖音喜欢` / `采集抖音作者作品` |
| **Popup Auto-Tab & Quick Folder** | Auto-switches to Batch tab when `isCollectionRoute !== false`; `btn-bm-quick-folder` invokes `CREATE_FOLDER_AND_SELECT` with `reuseExisting` (`popup.js`) | 100% reused; displays `+ 抖音收藏` / `+ 抖音喜欢` / `+ <夹名或作者名>` |
| **Card & Quick Look Spec** | `900×1440` vertical card (3:4 cover + `N 图`/play badge + `240px` white footer: 2-line title + avatar/author + likes); hides internal 24-hex ID | Same `900×1440` vertical card (video: play badge + `MM:SS` duration; multi-image: `N 图` badge); hides internal `sec_uid`/numeric IDs; Quick Look branches by video vs multi-image |

---

## 4. Windows Baseline Gate Blockers (4 Exact Locations & Minimal Fixes)

Verified during baseline environment check on Rust 1.97.1 / Node 22.19.0 / Windows CRLF checkout:

1. **`windows/src-tauri/tauri.conf.json:57-78` (NSIS bundle missing 4 extension files)**:
   - `bundle.resources` lists only 21 `BrowserExtension` files, omitting 4 v1.3.0 files (`page-bridge.js`, `x-bridge-loader.js`, `lib/social-collectors.js`, `lib/x-author-media.js`).
   - Minimal fix: add those 4 mappings (plus any new Douyin module such as `lib/douyin-parser.js`) and keep `windows/src-tauri/resources/BrowserExtension/` byte-identical to `Resources/BrowserExtension/`.
2. **`windows/ui/vite.config.ts:25-30` (Vitest default 5000ms timeout)**:
   - Full `<App />` jsdom integration suites (`m4-moodboard-studio.test.tsx` ~5.1s, `m5-settings-ai-onboarding.test.tsx` ~4.5s) hit Vitest's default 5000ms timeout on Windows.
   - Minimal fix: add `testTimeout: 20_000` under `test: { ... }`.
3. **Rust 1.97.1 Clippy `-D warnings` blockers (3 warnings)**:
   - `windows/crates/charkle-core/src/media/resolvers.rs:585-586` (`clippy::drop_non_drop`): remove redundant `drop(push_vid); drop(push_img);` (NLL releases closure borrows automatically).
   - `windows/crates/charkle-platform-win/src/shelf_win.rs:1152-1153` (`clippy::manual_range_contains`): change `elapsed_since_trigger_secs < 0.0 || elapsed_since_trigger_secs > Self::APPROACH_GRACE_SECS` to `!(0.0..=Self::APPROACH_GRACE_SECS).contains(&elapsed_since_trigger_secs)` (preserving `NaN` rejection).
4. **`Resources/BrowserExtension/tests/extension.test.mjs:161-164` (Windows CRLF assertion failure)**:
   - With `core.autocrlf=true`, `content.js` has `\r\n`, breaking hardcoded `\n` in `contentJs.includes("case 'START_BOOKMARK_IMPORT':\n        sendResponse(startBookmarkImport(msg.options || {}));")`.
   - Minimal fix: normalize line endings (`contentJs.replace(/\r\n/g, '\n')`) or match `\r?\n` via RegExp.

---

## 5. Cross-Platform `/.charkle/` Compatibility & Decoding Audit (CRITICAL)

### 5.1 Repository-Wide `douyin` / `tiktok` Inventory
- Zero implemented platform enums, URL parsers, or collectors exist anywhere across `Sources/`, `ios/`, `android/`, `web/`, `windows/`, or `Resources/BrowserExtension/`.
- Only two comments mention Douyin/TikTok:
  - `Sources/CharkleCore/Media/VideoPlatformResolver.swift:1261` (`downloadGenericWebVideo` doc comment).
  - `Sources/CharkleCore/Media/WebBookmark.swift:414` (Tier 1.5 oEmbed doc comment).

### 5.2 Per-Platform `SocialPlatform` & Dedup Key Status
- **macOS & iOS** (`Sources/CharkleCore/Contracts/CoreModels.swift:60-113`): 8 cases (`x`, `threads`, `bluesky`, `xiaohongshu`, `pixiv`, `instagram`, `youtube`, `bilibili`); dedup keys in `Sources/CharkleCore/Media/SocialPostResolver.swift:39-49, 278-285` (`x:<id>`, `xhs:<id>`, `threads:<id>`, `bsky:<handle>:<rkey>`, `pixiv:<id>`, `ig:<shortcode>`, `yt:<id>`, `bili:<bvid>`, fallback `url:<lowercased>`).
- **Windows & Android Rust Core** (`windows/crates/charkle-core/src/models/core.rs:112-205`): identical 8 variants (`#[serde(rename_all = "camelCase")]`). Android Kotlin (`android/app/src/main/java/com/charkle/android/core/CharkleModels.kt:59-60, 159`) stores `platform: String`, and `android/rust/charkle-android-ffi/src/` has no exhaustive match on `SocialPlatform`.
- **Web** (`web/packages/shared/src/models/core.ts:158-160`): lags behind with only `'x' | 'threads' | 'bluesky'`.

### 5.3 Breaking Sync Evidence: What Happens If `"douyin"` Is Written to `socialPost.platform` in `/.charkle/`?
Verified directly from source code on every platform:

1. **Published macOS v1.5.1 & iOS v1.5.1 — HARD DECODE FAILURE + STALLED SYNC TRANSACTION**:
   - `Sources/CharkleCore/Contracts/CoreModels.swift:60`: `SocialPlatform: String, Codable` is a closed Swift enum with no unknown-case fallback.
   - `CoreModels.swift:282`: `SocialPostMetadata.init(from:)` runs `try c.decode(SocialPlatform.self, forKey: .platform)` -> throws `DecodingError.dataCorrupted` on `"douyin"`.
   - `CoreModels.swift:879`: `AssetRichMetadata.init(from:)` runs `try container.decodeIfPresent(SocialPostMetadata.self, forKey: .socialPost)` (no `try?` swallow) -> propagates to synthesized `AssetRecord: Codable` (`CoreModels.swift:1047`).
   - `Sources/CharkleCore/Sync/SyncOperations.swift:136, 316`: `SyncFields.merge` runs `JSONDecoder().decode(AssetRecord.self, ...)` -> throws on merge.
   - `Sources/CharkleCore/Sync/DriveSyncEngine.swift:1037-1046`: `database.transaction { store.apply(item.line.operation) ... setState(deviceCursors) }` -> **rolls back the entire chunk (up to 40 op shards) and never advances `deviceCursors`, permanently stalling cloud sync on un-upgraded macOS/iOS clients**.
2. **Older Windows & Android Rust clients — SAME HARD DECODE FAILURE + TRANSACTION ROLLBACK**:
   - `windows/crates/charkle-core/src/models/core.rs:112-123`: `SocialPlatform` uses closed `#[derive(Deserialize)]` (no `#[serde(other)]`).
   - `windows/crates/charkle-core/src/wire/swift_codec.rs:376`: `SyncFields::merge` calls `serde_json::from_value(Value::Object(fields))?` -> fails with `unknown variant "douyin"`.
   - `windows/crates/charkle-core/src/db/library_db.rs:2805-2814, 2921-2922`: `apply_op_shard` propagates `?` inside a single SQLite transaction, rolling back the whole shard and cursor update.
3. **Web client — NO CRASH, SILENT COERCION + FIELD LOSS**:
   - `web/packages/shared/src/sync/swift-codec.ts:672-703`: line 676 coerces any platform other than `'threads' | 'bluesky'` into `'x'`; lines 718-729 omit `webPage` and v1.5 video fields (`videoDurationSeconds`, `videoID`, etc.), risking metadata loss on round-trip edits.

### 5.4 Wire Compatibility Options for User Decision (Q1)
- **Option A (First-class `SocialPlatform::Douyin` `"douyin"` + cross-platform parity handoff task)**:
  - Clean domain model matching Xiaohongshu / Bilibili / YouTube (`likeCount`, `authorAvatarURL`, `displayHandleLine`, `videoDurationSeconds`, `socialPost` card & viewer).
  - Windows `charkle-core` can also harden future forward-compatibility (e.g., unknown-platform tolerance), AND we create a structured `.trellis/tasks/` handoff task for macOS/iOS (and Web) to add `case douyin` + unknown-platform graceful decode fallback before shared cloud-library release.
  - **Trade-off**: Until macOS/iOS ships `case douyin`, users syncing a shared `/.charkle/` cloud library containing Windows-synced Douyin bookmarks will hit sync decode errors on un-upgraded macOS/iOS v1.5.1.
- **Option B (Persist inside `AssetRichMetadata.webPage` (`WebPageRichMetadata`) for zero-wait v1.5.1 compatibility)**:
  - `WebPageRichMetadata` (`siteName: "抖音"`, `authorName`, `summary`, `attachments`, `hasVideo`, `durationSeconds`, `canonicalURL`) is already natively decoded and stream-played on published macOS/iOS v1.5.1 with zero sync breakage.
  - **Trade-off**: Loses native `SocialPostMetadata` fields (`likeCount`, `authorAvatarURL`, `authorHandle`, `replyCount`, `repostCount`, `publishedAtText`) and diverges from the Xiaohongshu / X / Bilibili `SocialPostMetadata` architecture, requiring custom `sourceDomain == douyin.com` branching across UI/bridge/dedup layers.

---

## 6. Workspace Scope & Trellis Process Notes
- Per `AGENTS.md` §1, edits in this Windows session stay strictly scoped to `windows/` and shared `Resources/BrowserExtension/` (kept byte-identical with `windows/src-tauri/resources/BrowserExtension/`); macOS (`Sources/`), iOS (`ios/`), Android (`android/`), and Web (`web/`) changes are handed off via `.trellis/tasks/`.
- Because the repo root contains `.claude/` and `.cursor/`, `task.py create` generated empty `implement.jsonl` and `check.jsonl`; before running `task.py start`, curate real spec & research entries into both manifests (or pass `--allow-empty-context` if intentionally running inline).
