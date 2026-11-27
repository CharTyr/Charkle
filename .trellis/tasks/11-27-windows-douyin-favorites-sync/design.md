# Technical Design: Windows & Browser Extension Douyin Favorites Sync

> **Task**: `.trellis/tasks/11-27-windows-douyin-favorites-sync/`  
> **Package**: `windows` (`windows/` + shared `Resources/BrowserExtension/`) · **Priority**: `P1`  
> **Authorities**: `AGENTS.md`, `DESIGN.md`, `.trellis/spec/cross-platform/index.md`, `.trellis/spec/windows/index.md`, `.trellis/spec/windows/fluent2-design-system.md`, `windows/AGENTS.md`  
> **Research Baseline**: [`research/codebase-and-compatibility-audit.md`](./research/codebase-and-compatibility-audit.md)

---

## 1. Confirmed Decisions & Architecture Boundaries

### 1.1 Locked Decisions
1. **Page Coverage & UX Parity**: 1:1 alignment with existing Xiaohongshu flows — favorites (`收藏`), collection sub-folders (`收藏夹`, preferring active sub-folder name as target folder, falling back to `抖音收藏`), likes (`喜欢` → `抖音喜欢`), author profile dual mode (`media` → `<作者名>` vs `bookmarks` → `抖音收藏` with auto-switch to 收藏 tab), discover/search feed (`isCollectionRoute: false`), and single-post clipping (`/video/<id>`, `/note/<id>`, `?modal_id=<id>`, `v.douyin.com/<code>`).
2. **`/.charkle/` Wire Model (Option A)**: First-class `SocialPlatform::Douyin` (`"douyin"`) inside `AssetRichMetadata.socialPost` (`SocialPostMetadata`), canonical dedup key `douyin:<aweme_id>`, lossless unknown-platform wire decoding in `windows/crates/charkle-core`, plus a dedicated `.trellis/tasks/` cross-platform alignment task for macOS/iOS and Web.
3. **Video Storage Policy (Option 1 — Zero-Download Bookmark Card Default)**:
   - **Favorites / Likes / Single-Post Bookmark Card Mode (`socialBookmark` / `WebUrl`)**: Zero eager MP4 download on ingest. Persist only the `900×1440` cover artwork, `.md` archive, and `SocialPostMetadata` (preserving `videoID`, `videoDurationSeconds`, `hasVideo`, `videoURL`, `attachments`). Quick Look plays inline via local HTTP Range streaming proxy (`yt-dlp -g` fallback when ephemeral CDN URLs expire), supports **"设当前帧为封面"**, and provides explicit one-click **"保存视频为独立素材"** (`extract_link_media_attachment`).
   - **Author Profile Raw Media Mode (`socialMedia` / `author_media`)**: Respects the explicit `includeVideos` checkbox; when enabled, downloads watermark-free MP4 binaries (alongside photo-note originals) into the author's folder hierarchy.

### 1.2 Strict Scope & Safety Boundaries
- **In-Scope Code Changes**: Exclusively `windows/` and `Resources/BrowserExtension/` (mirrored byte-identically to `windows/src-tauri/resources/BrowserExtension/`).
- **Out-of-Scope Folders**: Never edit `Sources/`, `Tests/`, `ios/`, `android/`, `web/`, or `scripts/` in this task (`AGENTS.md` §1). Cross-platform alignment (including Safari build script packaging updates) is handed off via `.trellis/tasks/`.
- **Anti-Bot & Auth Boundary**: Strictly passive read-only observation of logged-in browser network traffic (`fetch` / `XHR`) plus DOM fallback. **Never** synthesize `a_bogus` / `X-Bogus` / `msToken` signatures, never initiate unauthorized active Douyin private API calls from content scripts, and never bypass login, CAPTCHA, or anti-bot challenges (pause and notify the user to resolve directly in the visible browser).

---

## 2. End-to-End Architecture & Data Flow

```text
┌────────────────────────────────────────────────────────────────────────────┐
│ Chrome / Edge Tab (douyin.com / www.douyin.com / m.douyin.com)             │
│                                                                            │
│  [document_start] x-bridge-loader.js ──inject──▶ page-bridge.js (MAIN)     │
│     • Read-only fetch (res.clone().text()) & XHR (load) interception       │
│     • Targets: listcollection / collects/list / collects/video/list /      │
│                favorite / post / detail                                    │
│     • Emits window.postMessage({ __charkleSocialBridge: true,              │
│         platform: 'douyin', type: 'GRAPHQL_POSTS' | 'DOUYIN_COLLECTIONS' })│
│                                      │                                     │
│                                      ▼                                     │
│  [document_idle] content.js (ISOLATED, classic script)                     │
│     • capturedSocialPostsByKey (Map, max 5000) + douyinCollectionsById     │
│     • Route & tab detection (1:1 XHS parity) + SPA watcher + Floating Pill │
│     • Autonomous humanized scroll + harvestVisibleDouyinItems + DOM fallbk │
│     • GET_PAGE_CONTEXT single-post capture (/video/, /note/, ?modal_id=)   │
└──────────────────────────────────────┬─────────────────────────────────────┘
                                       │ chrome.runtime.sendMessage
                                       ▼
┌────────────────────────────────────────────────────────────────────────────┐
│ background.js (MV3 ESM Service Worker) + lib/url-detect.js + lib/api.js    │
│  • Queries POST /api/v1/assets/existing-sources (dedup: douyin:<aweme_id>) │
│  • Chunks INGEST_SOCIAL_BOOKMARKS_CHUNK ─▶ POST /api/v1/assets/ingest      │
│    (type: "socialBookmark") or INGEST_SOCIAL_MEDIA_CHUNK ("socialMedia")   │
└──────────────────────────────────────┬─────────────────────────────────────┘
                                       │ Localhost HTTP + Bearer Token
                                       ▼
┌────────────────────────────────────────────────────────────────────────────┐
│ Windows Desktop Rust Core (charkle-core + src-tauri)                       │
│  • bridge.rs: parses platform "douyin", dedupKey "douyin:<aweme_id>"       │
│  • media/douyin.rs: URL & v.douyin.com short-link / share-copy resolver,   │
│    CDN allowlist, Referer: https://www.douyin.com/, octet-stream ftyp sniff│
│  • media/pipeline.rs: prefers_zero_download_video_bookmark() skips MP4 DL  │
│  • media/artwork.rs: 900×1440 vertical feed card (MM:SS / N 图 badge)      │
│  • protocol.rs + media/video_platform.rs:                                  │
│      - /proxy-social (Douyin image CDNs + Referer)                         │
│      - /proxy-video-stream (HTTP 206 Range + ftyp->video/mp4 + Referer)    │
│      - resolve_playback_plan (direct stream + yt-dlp -g fallback)          │
│      - extract_link_media_attachment (direct + download_generic_web_video) │
│  • models/core.rs: SocialPlatform::Douyin + lossless Unknown(String) serde │
└──────────────────────────────────────┬─────────────────────────────────────┘
                                       │ Tauri IPC + LibraryChanged Events
                                       ▼
┌────────────────────────────────────────────────────────────────────────────┐
│ Windows React UI (windows/ui/src/)                                         │
│  • Gallery (Masonry / Ring / Filmstrip / AssetCard): 900×1440 (0.625)      │
│  • Quick Look (SocialPostViewer.tsx) — per-item branching:                 │
│      - hasVideo: QuickLookStreamingVideoView + 设当前帧为封面 + 保存 MP4    │
│      - !hasVideo: isVerticalMultiGrid (3:4 2-col photo-note grid + 提取)   │
│  • Paste/Drop (App.tsx, TopEdgeDropShelf.tsx): v.douyin.com & share copy   │
└────────────────────────────────────────────────────────────────────────────┘
```

---

## 3. Browser Extension Design (`Resources/BrowserExtension/`)

### 3.1 Classic-Script & Safari-Build Module Boundary (Verified)
Direct audit of `Resources/BrowserExtension/manifest.json`, `content.js`, `lib/xhs-parser.js`, `lib/url-detect.js`, and `scripts/build-safari-extension.sh` establishes three hard constraints:
1. **`content.js`, `x-bridge-loader.js`, and `page-bridge.js` are classic scripts**: They execute without `type="module"` and MUST contain zero `import`/`export` statements.
2. **`background.js`, `popup.js`, `options.js`, `lib/*.js`, and `tests/extension.test.mjs` are ES Modules**: `manifest.json:25` declares `"type": "module"` for the Chrome/Edge Service Worker, and `lib/xhs-parser.js:6` imports from `./url-detect.js` (never the reverse).
3. **Safari build script compatibility (`scripts/build-safari-extension.sh:40-44, 89-91`)**: `build-safari-extension.sh` copies all `lib/*.js`, but its `strip_esm()` classic Service Worker bundler concatenates only `['lib/url-detect.js', 'lib/storage.js', 'lib/api.js', 'background.js']` (and does not yet copy `page-bridge.js` / `x-bridge-loader.js`).

**Module organization rule**:
- **`lib/url-detect.js`**: Keep Douyin host sets (`DOUYIN_HOSTS`, `DOUYIN_SHORT_HOSTS`), `isValidDouyinAwemeId`, `normalizeDouyinUrl`, `detectSourceKind`, `detectCollectionRoute`, and `canonicalDedupKey` (`douyin:<aweme_id>`) **self-contained inside `lib/url-detect.js`** (identical to Xiaohongshu `XHS_HOSTS` / `isValidXhsNoteId`), so Safari's 4-file classic SW bundle never breaks.
- **`lib/douyin-parser.js` (new pure ESM module)**: Mirror `lib/xhs-parser.js`. Imports only from `./url-detect.js`. Contains pure, DOM-free parsers for Douyin Web JSON payloads (`extractDouyinPostsFromPayload`, `extractDouyinCollectionsFromPayload`), share-copy text extraction, cover/photo/watermark-free video URL selection (`play_addr` vs `download_addr`, preferring `playwm` → `play` stripping only when safe or preferring `bit_rate` H.264/MP4 URLs from `video.play_addr.url_list`), `aweme_type` video vs photo-note (`68` / `images` array) classification, and Chinese metric parsing. Directly unit-tested by `tests/extension.test.mjs`.
- **`page-bridge.js` & `content.js`**: Remain 100% classic scripts; keep Douyin JSON extraction in `page-bridge.js` structurally 1:1 with `lib/douyin-parser.js`, guarded by `node --check` + shared JSON fixture parity tests in `tests/extension.test.mjs`.
- **Safari packaging gap**: Document copying `page-bridge.js` / `x-bridge-loader.js` and bundling `lib/social-collectors.js` / `lib/x-author-media.js` in `scripts/build-safari-extension.sh` inside the macOS cross-platform handoff task (Wave 4).

### 3.2 `manifest.json` & `x-bridge-loader.js`
- Add `https://douyin.com/*`, `https://www.douyin.com/*`, and `https://m.douyin.com/*` to BOTH:
  - `content_scripts[0].matches` (`manifest.json:45-61`, `x-bridge-loader.js` at `document_start`)
  - `web_accessible_resources[1].matches` (`manifest.json:110-126`, exposing `page-bridge.js`)
- Update `manifest.json` description and bump version (e.g., `1.3.0` → `1.4.0` if appropriate during implementation, ensuring `tests/extension.test.mjs` assertions stay synchronized).

### 3.3 `page-bridge.js` Passive Interception & `window.postMessage` Contract
- Extend `PLATFORM` detection (`page-bridge.js:16-30`) to return `'douyin'` when hostname is `douyin.com`, `www.douyin.com`, or `m.douyin.com`.
- Extend `isTargetEndpoint(url)` (`page-bridge.js:40-66`) for `'douyin'` (all read-only observation):
  - `/aweme/v1/web/aweme/listcollection/` — All favorites (`aweme_list`)
  - `/aweme/v1/web/collects/list/` — Collection folders directory (`collects_list`: `collects_id_str` / `collects_id` → `collects_name`)
  - `/aweme/v1/web/collects/video/list/` — Items inside a specific collection folder (`aweme_list`, query param `collects_id`)
  - `/aweme/v1/web/aweme/favorite/` — Likes (`aweme_list`)
  - `/aweme/v1/web/aweme/post/` — Author profile posts (`aweme_list`)
  - `/aweme/v1/web/aweme/detail/` — Single item detail (`aweme_detail`)
  - *(Verified via `chrome-mcp-server` in Wave 1 before coding; tolerate alternate `/aweme/v2/web/` or `/aweme/v1/web/mix/` paths if observed.)*
- **Outbound `window.postMessage` contracts**:
  1. Posts payload (reuses existing listener contract):
     ```js
     window.postMessage({
       __charkleSocialBridge: true,
       __charkleXBridge: false,
       platform: 'douyin',
       type: 'GRAPHQL_POSTS',
       posts: normalizedPosts,
     }, window.location.origin);
     ```
  2. Collection folder metadata payload (optional auxiliary map for accurate sub-collection folder naming):
     ```js
     window.postMessage({
       __charkleSocialBridge: true,
       __charkleXBridge: false,
       platform: 'douyin',
       type: 'DOUYIN_COLLECTIONS',
       collections: [{ id: String(collectsId), name: String(collectsName), totalCount: Number(count) || null }],
     }, window.location.origin);
     ```
- **Normalized Douyin Post Schema** (aligned with `page-bridge.js:309-327, 441-459` & `social-collectors.js:442-463`):
  ```js
  {
    platform: 'douyin',
    postID: awemeId,                // 15-22 digit string
    tweetID: awemeId,               // legacy alias used by shared batch pipeline
    originalURL: isPhotoNote
      ? `https://www.douyin.com/note/${awemeId}`
      : `https://www.douyin.com/video/${awemeId}`,
    dedupKey: `douyin:${awemeId}`,
    authorName,                     // author.nickname
    authorHandle,                   // author.unique_id || author.short_id (never expose raw sec_uid as @handle)
    authorAvatarURL,                // https-upgraded author.avatar_thumb / avatar_medium
    publishedAtText,                // "YYYY-MM-DD HH:mm" from create_time (epoch sec)
    publishedDateKey,               // "YYYY-MM-DD"
    title,                          // item_title || first non-hashtag sentence of desc
    bodyText,                       // full desc
    isRetweet: false,
    likeCount,                      // statistics.digg_count
    replyCount,                     // statistics.comment_count
    repostCount,                    // statistics.share_count
    viewCount,                      // statistics.play_count (when present)
    durationSeconds,                // Math.round(video.duration / 1000) or duration / 1000.0
    media,                          // Photo-note: all images[].url_list (prefer non-heic JPEG/WebP/PNG); Video: [{ kind: 'video', url: bestMp4Url, thumbnailURL: coverUrl, width, height }]
    hasVideo,                       // true unless photo-note (`images?.length > 0` && `aweme_type === 68` or no playable video stream)
    videoURL,                       // best watermark-free MP4 play_addr URL (null for pure photo-note)
    needsEnrich: false,
    referer: 'https://www.douyin.com/',
    tags,                           // text_extra hashtags (hashtag_name)
    collectionId,                   // optional collects_id when intercepted from collects/video/list
  }
  ```
- **Photo-Note vs Video Classification & Image Format Hygiene**:
  - Douyin photo-notes ("图文") carry `aweme_type === 68` (or non-empty `images` array with `images.length > 0`). Extract every slide's best raster URL from `images[i].url_list` (preferring `.jpeg` / `.jpg` / `.png` / `.webp` over `.heic` because Rust `image` crate decodes JPEG/PNG/WebP natively without external HEIF codecs!).
  - For videos, pick the highest-quality H.264/MP4 URL from `video.bit_rate` (preferring `is_h265 === 0` for maximum WebView2 `<video>` compatibility!) or `video.play_addr.url_list` (excluding watermarked `download_addr` and `playwm` URLs). Pick cover from `video.origin_cover.url_list` → `video.cover.url_list` (preferring non-HEIC).

### 3.4 `content.js`, `background.js`, `popup.js` Integration Points (1:1 Xiaohongshu Parity)

| Feature / Page | Xiaohongshu Anchor | Douyin 1:1 Implementation |
| :--- | :--- | :--- |
| **Bridge Listener** | `content.js:95-129` (`initXGraphQLBridgeListener`) | Allow `isDouyinHost(host)`; ingest `GRAPHQL_POSTS` into `capturedSocialPostsByKey` (retaining richer `media.length` / `videoURL`); ingest `DOUYIN_COLLECTIONS` into `douyinCollectionsById` (`Map<id, name>`). |
| **Favorites (`收藏`) & Sub-Collections (`收藏夹`)** | `content.js:686-768` (`collect` / `board`, default `小红书收藏`) | Match `/user/self?showTab=favorite_collection`, `/user/<sec_uid>?showTab=favorite_collection`, or active DOM "收藏" tab → `pageKind: 'collect'`; when inside a specific sub-collection (active sub-folder header / `collects_id` query / intercepted `collects/video/list`), `pageKind: 'board'`, `suggestedFolderName = activeCollectionName || '抖音收藏'`; `mode: 'bookmarks'`. |
| **Likes (`喜欢`)** | `content.js:700-735` (`likes`, default `小红书点赞`) | Match `/user/self?showTab=like`, `/user/<sec_uid>?showTab=like`, or active DOM "喜欢" tab → `pageKind: 'likes'`, `suggestedFolderName: '抖音喜欢'`, `mode: 'bookmarks'`. |
| **Profile Dual Mode (`作品`)** | `content.js:736-773` (`profile`, `xhsProfileCollectMode`) | Match `/user/<sec_uid>` / `/user/self` default "作品" tab → `pageKind: 'profile'`; Popup switches `douyinProfileCollectMode` (or unified profile mode selector) between `'media'` (author raw files, folder `<作者名>`, `includeVideos` opt-in) and `'bookmarks'` (favorites & likes cards, folder `抖音收藏`). |
| **Auto-Switch Collect Tab** | `content.js:3276-3303` (`ensureXiaohongshuCollectTabActive`) | Add `ensureDouyinCollectTabActive()`: when starting a `bookmarks` job on `pageKind === 'profile'`, find and click the visible "收藏" tab and wait up to 2.5s for intercepted posts or list render. |
| **Generic Feed / Search** | `content.js:760-773` (`feed`, `isCollectionRoute: false`) | Recommend / Discover / Search pages with video/note cards → `pageKind: 'feed'`, `isCollectionRoute: false` (suppresses floating pill; manual Popup batch scan available). |
| **SPA Watcher** | `content.js:4206-4227` (`setupSpaRouteWatcher`) | Append active Douyin tab & sub-collection title to the watcher signature (`L4217-4219`) so switching `作品 ↔ 喜欢 ↔ 收藏 ↔ 具体收藏夹` immediately updates floating pill & Popup without page reload. |
| **Scroll Target** | `content.js:3391-3409` (`findActiveScrollTarget`) | Detect inner scrollable containers inside Douyin collection modals/drawers and profile tabs (`overflowY: auto|scroll`, `scrollHeight > clientHeight + 120`). |
| **Harvest & DOM Fallback** | `content.js:3616-3636` (`harvestNow`), `L3669-3794` (`flushChunk`) | Add `harvestVisibleDouyinItems(pageInfo, runOptions)`: consume `capturedSocialPostsByKey` matching current active view/collection first; scan DOM anchors (`/video/(\d+)`, `/note/(\d+)`, `modal_id=(\d+)`) for pre-injection/SSR fallback (capturing cover `<img>` + title). Respect `includeVideos` in `author_media` mode. Hydrate batch items from `capturedSocialPostsByKey` before `INGEST_SOCIAL_BOOKMARKS_CHUNK` / `INGEST_SOCIAL_MEDIA_CHUNK`. |
| **Anti-Bot / Login Detection** | `content.js` batch job error/pause handling | If Douyin displays a login modal or verification overlay (captcha / slider dialog) during batch scrolling, pause the batch job (`pauseRequested = true`) and show a clear HUD status message (`检测到抖音登录或验证弹窗，请在页面完成后点击继续`) rather than hammering scroll/retrying. |
| **Floating Launcher** | `content.js:1660-1715` (`updateFloatingLauncherVisibility`) | Reuse exact visibility gate; dynamic CTA labels: `一键导入抖音收藏` (or `一键导入「<夹名>」`) / `一键导入抖音喜欢` / `采集抖音作者作品`. |
| **Single-Page Clipping** | `content.js:4185-4202` (`getPageContext`) + `background.js:510` | Add `extractCurrentSingleDouyinPost()`: resolve `aweme_id` from `/video/<id>`, `/note/<id>`, or `?modal_id=<id>`, look up `capturedSocialPostsByKey.get('douyin:' + awemeId)`, fall back to DOM metadata (`<video>`, cover `<img>`, title, author). Extend `background.js:510` from `sourceInfo.kind === 'xiaohongshu'` to `sourceInfo.kind === 'xiaohongshu' || sourceInfo.kind === 'douyin'`. |
| **Popup & Quick Folder** | `popup.js` + `popup.html` | Auto-switch to Batch tab on `isCollectionRoute !== false`; show Douyin profile dual-mode toggle (`作品原文件` / `收藏卡片`) + `包含视频` checkbox when in `media` mode; reuse `btn-bm-quick-folder` (`CREATE_FOLDER_AND_SELECT` with `reuseExisting`) showing `+ 抖音收藏` / `+ 抖音喜欢` / `+ <夹名或作者名>`. |

### 3.5 Windows Extension Mirror & `tauri.conf.json`
- Every edit under `Resources/BrowserExtension/` MUST be mirrored byte-identically to `windows/src-tauri/resources/BrowserExtension/`.
- `windows/src-tauri/tauri.conf.json:57-78` uses lowercase source keys (`"resources/BrowserExtension/..."`) mapped to capital-R destination paths (`"Resources/BrowserExtension/..."`).
- Register the 4 missing v1.3.0 files (Wave 0) plus the new `lib/douyin-parser.js` (Wave 1):
  ```json
  "resources/BrowserExtension/page-bridge.js": "Resources/BrowserExtension/page-bridge.js",
  "resources/BrowserExtension/x-bridge-loader.js": "Resources/BrowserExtension/x-bridge-loader.js",
  "resources/BrowserExtension/lib/social-collectors.js": "Resources/BrowserExtension/lib/social-collectors.js",
  "resources/BrowserExtension/lib/x-author-media.js": "Resources/BrowserExtension/lib/x-author-media.js",
  "resources/BrowserExtension/lib/douyin-parser.js": "Resources/BrowserExtension/lib/douyin-parser.js"
  ```

---

## 4. Windows Rust Core & Bridge Design (`windows/crates/charkle-core/` + `windows/src-tauri/`)

### 4.1 `SocialPlatform::Douyin` & Lossless Unknown-Platform Serde (`models/core.rs`)

#### Exhaustive Impact Audit (Verified)
- `windows/src-tauri/` and `android/rust/charkle-android-ffi/` contain **zero** direct matches on `SocialPlatform`.
- Inside `windows/crates/charkle-core/`, `SocialPlatform` is matched in 7 source files (`models/core.rs`, `bridge.rs`, `engine.rs`, `media/artwork.rs`, `media/pipeline.rs`, `media/resolvers.rs`, `media/video_platform.rs`, `media/xiaohongshu.rs`).
- Currently `models/core.rs:112-123` derives `Copy` and uses `#[serde(rename_all = "camelCase")]` with no unknown fallback.

#### Trade-off Analysis: `#[serde(other)] Other` vs `Unknown(String)`
| Aspect | Variant 1: `#[serde(other)] Other` (keeps `Copy`) | Variant 2: `Unknown(String)` + custom `Serialize`/`Deserialize` (drops `Copy`, keeps `Clone`) — **SELECTED** |
| :--- | :--- | :--- |
| **`/.charkle/` Round-Trip Fidelity** | **Lossy**: Decoding `"futureApp"` produces `Other`, which serializes back as `"other"` in SQLite `rich_metadata_json` and overwrites `"futureApp"` if `richMetadata` is later re-emitted. | **100% Lossless**: Custom `Deserialize` stores `"futureApp"` inside `Unknown("futureApp")`; custom `Serialize` emits `"futureApp"` verbatim back to SQLite and `/.charkle/` ops. |
| **Refactor Footprint** | Minimal (~0 signature changes). | Small & strictly internal to `charkle-core` (~7 files, ~20 call sites changing `self` → `&self` or `.clone()`; zero Tauri IPC / FFI schema break). |
| **UI & Display Behavior** | Fixed fallback `"other"`. | `raw_value(&self) -> &str` returns the preserved wire token; `display_name(&self) -> &str` returns non-empty token or `"社交动态"`. |

**Exact Contract in `windows/crates/charkle-core/src/models/core.rs`**:
```rust
#[derive(Debug, Clone, PartialEq, Eq, Hash)]
pub enum SocialPlatform {
    X,
    Threads,
    Bluesky,
    Xiaohongshu,
    Pixiv,
    Instagram,
    Youtube,
    Bilibili,
    Douyin,
    Unknown(String),
}
```
- **Custom `Serialize`**: Known variants emit canonical lowercase/camelCase strings (`"x"`, `"threads"`, `"bluesky"`, `"xiaohongshu"`, `"pixiv"`, `"instagram"`, `"youtube"`, `"bilibili"`, `"douyin"`). `Unknown(raw)` emits `raw.as_str()`.
- **Custom `Deserialize`**: Exact camelCase match for all 9 known variants (plus trimmed case-insensitive match for robustness); any other string `s` deserializes to `Ok(SocialPlatform::Unknown(s))` — **never returns a serde error**, guaranteeing `SyncFields::merge` (`wire/swift_codec.rs:376`) and `apply_op_shard` (`db/library_db.rs:2805-2814`) never roll back on future platform tokens!
- **`from_raw(raw: &str) -> Option<Self>`**: Add `"douyin" | "iesdouyin" | "dy" => Some(Self::Douyin)`. Keep `from_raw` returning `Option` (returning `None` for unrecognized bridge strings so explicit URL fallback still works).
- **Display metadata helpers**:
  - `display_name(&self) -> &str`: `Self::Douyin => "抖音"`
  - `post_noun(&self) -> &str`: `Self::Douyin => "作品"`
  - `post_type_label(&self) -> &str`: `Self::Douyin => "抖音 作品"`
  - `open_action_label(&self) -> &str`: `Self::Douyin => "在抖音打开"`
- **Capability predicate decoupling (CRITICAL)**:
  - Keep `is_video_platform(&self) -> bool` strictly `matches!(self, Self::Youtube | Self::Bilibili)` so 16:9 horizontal card layout (`artwork.rs:119`) and YouTube/Bilibili `VideoPlatformURLParser` routing (`engine.rs:4016, 4044`) remain completely unaffected.
  - Add **`prefers_zero_download_video_bookmark(&self) -> bool`**:
    ```rust
    pub fn prefers_zero_download_video_bookmark(&self) -> bool {
        matches!(self, Self::Youtube | Self::Bilibili | Self::Douyin)
    }
    ```
  - Wire `prefers_zero_download_video_bookmark()` into `pipeline.rs:534, 824, 901` so Douyin video bookmarks NEVER download full MP4s on ingest, while `pipeline.rs:502, 600` keep checking `is_video_platform()` (or handle Douyin's `900×1440` aspect explicitly!).
- **Handle sanitation (`models/core.rs:418-469`)**:
  - In `SocialPostMetadata::display_handle_line()`: for `SocialPlatform::Douyin`, suppress `douyin`, internal `MS4wLjAB...` (`sec_uid`), long pure-numeric internal UIDs (`>= 12` digits), or duplicates of `author_name`; format human-readable handles as `抖音号 {trimmed}`.
  - In `SocialPostMetadata::display_author_name()`: fall back to `"抖音用户"` when `author_name` is empty or looks like an internal `MS4wLjAB...` `sec_uid`.

### 4.2 Dedicated Module `windows/crates/charkle-core/src/media/douyin.rs`
Mirror `media/xiaohongshu.rs` and export from `media/mod.rs`:
- **Constants**: `pub const DOUYIN_REFERER: &str = "https://www.douyin.com/";`
- **`DouyinPostReference` & `DouyinURLParser`**:
  - `parse(url: &Url) -> Option<DouyinPostReference>`:
    - Hosts: `douyin.com`, `www.douyin.com`, `m.douyin.com`, `iesdouyin.com`, `www.iesdouyin.com`.
    - Paths: `/video/<aweme_id>`, `/note/<aweme_id>`, `/share/video/<aweme_id>`, `/share/note/<aweme_id>`, or any Douyin URL containing query param `modal_id=<aweme_id>` (where `<aweme_id>` is 15–22 ASCII digits).
    - Canonical URL: `https://www.douyin.com/video/<aweme_id>` (or `/note/<aweme_id>` when source path is `/note/`).
    - Canonical dedup key: `douyin:<aweme_id>`.
  - `is_short_link(url: &Url) -> bool`: detects `v.douyin.com/<code>` (plus `www.v.douyin.com`).
  - `extract_url_from_share_copy(text: &str) -> Option<String>`: extracts `https://v.douyin.com/...` or `https://www.douyin.com/...` from Chinese mobile share text (e.g., `7.48 复制打开抖音，看看... https://v.douyin.com/iXXXX/ ...`).
  - `resolve_short_link(url: &Url) -> Option<Url>`: follows redirects (limited to 6 hops, enforcing `SocialPostResolver::is_safe_public_media_url` on every destination) to expand `v.douyin.com/<code>` into canonical `/video/<id>` or `/note/<id>`.
  - **CDN Host Allowlists (SSRF-safe)**:
    - `is_douyin_image_host(host: Option<&str>) -> bool`: `douyinpic.com`, `byteimg.com`, `ibytedtos.com`, `zjcdn.com`, `snssdk.com`, `amemv.com`, `pstatp.com` (exact or subdomain suffix).
    - `is_douyin_video_host(host: Option<&str>) -> bool`: `douyinvod.com`, `zjcdn.com`, `snssdk.com`, `bytevcloudapi.com`, `amemv.com`, `douyin.com` (for `/aweme/v1/play/`).
    - `is_douyin_media_host(host: Option<&str>) -> bool`: union of image & video hosts.
- **`DouyinPostResolver::resolve(reference)` (best-effort single-URL fallback)**:
  - Used when a user pastes a bare `douyin.com/video/<id>` or `v.douyin.com/<code>` URL directly into Charkle Desktop without the browser extension.
  - Fetches public page HTML with desktop/mobile browser UA + SSRF guard, attempts OG/meta tags (`og:title`, `og:description`, `og:image`) and SSR embedded JSON (`RENDER_DATA` / `_ROUTER_DATA` if present without triggering anti-bot), gracefully falling back to minimal bookmark metadata (`title`, `original_url`, `video_id: Some(aweme_id)`, `has_video: !is_note`) so paste/drop NEVER fails even if Douyin serves a JS shell or verification wall.
- **Wire into `media/resolvers.rs`**:
  - Add `SocialPostReference::Douyin(DouyinPostReference)` (`resolvers.rs:2305+`), returning `SocialPlatform::Douyin` and `canonical_dedup_key` → `douyin:<aweme_id>`.
  - `SocialPostURLParser::parse` + short-link resolution in `pipeline.rs` (`WebUrl` branch) handle `v.douyin.com` redirect expansion before `SocialPostURLParser::parse`.
  - `XPostURLParser::is_allowed_social_proxy_host` (`resolvers.rs:2163`): include `DouyinURLParser::is_douyin_image_host(host)`.
  - `SocialPostResolver::resolve_cdn_referer` (`resolvers.rs:2819`): if `DouyinURLParser::is_douyin_media_host(host)`, return `Some(DOUYIN_REFERER)`.
  - **`application/octet-stream` + ISO BMFF `ftyp` magic-byte sniffing**:
    - Update `resolve_media_extension` (`resolvers.rs:4496-4555`) to accept `&[u8]` (passed from `download_media_bytes_with_referer` at `L2951`): when `mime_type` is `None` or `application/octet-stream` (or URL has no standard image/video extension), sniff `bytes` magic headers:
      - JPEG (`FF D8 FF` → `jpg`), PNG (`89 50 4E 47` → `png`), WebP (`RIFF....WEBP` → `webp`), GIF (`GIF8` → `gif`).
      - ISO BMFF (`bytes.len() >= 12 && &bytes[4..8] == b"ftyp"`): inspect major brand `&bytes[8..12]` — `avif`/`avis` → `avif`, `heic`/`heix`/`mif1`/`msf1` → `heic`, otherwise (e.g., `isom`/`mp41`/`mp42`/`avc1`/`M4V `) → `mp4`!
    - Also refine `sniff_social_media_content_type` (`resolvers.rs:4125-4131`) with the same `heic`/`heix`/`mif1` check so `/proxy-social` serves accurate `Content-Type` headers.

### 4.3 `bridge.rs` & `pipeline.rs` Integration
- **`bridge.rs`**:
  - `parse_social_bookmark_item` (`L1168`) & `parse_creator_media_job` (`L2372`): automatically recognize `"douyin"` via `SocialPlatform::from_raw` and canonicalize `dedupKey` via `canonical_dedup_key` → `douyin:<aweme_id>`.
  - `ingest_creator_media_job` (`L1697-1766`):
    - Include `SocialPlatform::Douyin` alongside `Pixiv | Xiaohongshu` for clean nickname-first `author_line`, `merged_tags`, and `author_prefix` (never prefixing raw `sec_uid` with `@`).
    - Match arm `L1719-1727`: add `SocialPlatform::Douyin => "原作品："` and `SocialPlatform::Unknown(_) => "原链接："`.
  - Pass `durationSeconds` / `videoID` cleanly when `socialBookmark` payloads arrive from the extension so `SocialPostMetadata.video_duration_seconds` and `video_id` are persisted on first ingest.
- **`pipeline.rs`**:
  - `WebUrl` branch (`L500-605`): resolve `v.douyin.com` short links before `SocialPostURLParser::parse`; use `let skip_eager_video = post.metadata.platform.prefers_zero_download_video_bookmark();` at `L534` so Douyin video bookmarks stay zero-download; keep `is_video_platform` for 16:9 YouTube/Bilibili-specific duration/poster paths while setting `pre_duration = meta.video_duration_seconds` for Douyin too.
  - `SocialBookmark` branch (`L794-910`):
    - `needs_live_enrich` (`L794-816`): for `SocialPlatform::Douyin`, enrich only when BOTH `effective_attachments().is_empty()` AND `body_text.trim().is_empty()` (never hammer Douyin HTML endpoints during batch collection when `page-bridge.js` already supplied rich metadata). Add `SocialPlatform::Unknown(_) => false`.
    - `L824` & `L901`: gate eager video download on `!platform.prefers_zero_download_video_bookmark()` instead of `!platform.is_video_platform()`.
    - Cover acquisition (`L861-897`): works automatically via `download_media_bytes` → `resolve_cdn_referer` (`https://www.douyin.com/`). If primary cover is HEIC and fails `image::load_from_memory`, `cover_urls` naturally falls through to the next candidate URL (and `lib/douyin-parser.js` already prioritizes JPEG/WebP/PNG covers first).

### 4.4 `artwork.rs` Vertical `900×1440` Feed Card Spec
- Extend `artwork.rs:122-124` so BOTH `SocialPlatform::Xiaohongshu` and `SocialPlatform::Douyin` render the `900×1440` vertical feed card (`3:4` `900×1200` cover + `1.5px #EFEFEF` divider + `900×240` `#FFFFFF` footer with 2-line CJK bold title, circular author avatar/monogram, clean author nickname, right-aligned likes):
  - Refactor `xiaohongshu_post_card` (keeping public wrapper `xiaohongshu_post_card` for backward compatibility with existing tests) into a shared `vertical_social_feed_card(meta, cover, avatar)` parameterized by platform accent & fallback labels:
    - Xiaohongshu: accent `#FF2442`, fallback monogram `'小'`, fallback title `"{author} 的小红书笔记"`.
    - Douyin: accent `#161823` (ink-charcoal neutral per `DESIGN.md` zero-violet chrome discipline) with crisp `#FE2C55` heart/accent glyph, fallback monogram `'抖'`, fallback title `"{author} 的抖音作品"`.
  - **Douyin badge overlays on `900×1200` cover**:
    - **Photo-note (`media_count > 1 && !meta.has_video`)**: top-left dark translucent pill `{media_count} 图` (`x=24, y=28`), identical to Xiaohongshu.
    - **Video (`meta.has_video`)**: centered play circle (`cx=450, cy=600, r=44`), PLUS bottom-right translucent duration pill (`MM:SS` via `meta.formatted_duration()`, e.g., `x=760..876, y=1136..1176`) whenever `video_duration_seconds > 0`.
  - Add `SocialPlatform::Douyin => "#161823"` and `SocialPlatform::Unknown(_) => "#52525B"` in `artwork.rs:145-153` (`platform_badge_hex`).

### 4.5 Streaming Playback, Range Proxy & On-Demand Save (`video_platform.rs`, `protocol.rs`, `engine.rs`)
1. **`video_platform.rs::resolve_playback_plan` (`L1142-1196`)**:
   - Add dedicated `SocialPlatform::Douyin` arm (or extend default arm explicitly):
     - Set `User-Agent: STREAM_BROWSER_UA` and `Referer: https://www.douyin.com/`.
     - Populate `direct_streams` from `post.effective_attachments()` (`Video | Gif`) passing `is_safe_public_media_url`.
     - **Expired / missing ephemeral CDN fallback**: Because Douyin VOD URLs carry short-lived signatures (`x-expires`), if `direct_streams.is_empty()` — OR as an appended fallback stream when `watch_url` is present and local `yt-dlp` is installed on PATH — resolve via `Self::resolve_direct_stream_via_yt_dlp_if_available(watch_url.as_str()).await` (6s timeout, `CREATE_NO_WINDOW`). *(Note: If a stored direct stream exists, put it first for instant <200ms playback when freshly synced, and allow Quick Look's retry / playback error handler to request `resolve_video_playback_plan` with a `force_refresh` flag or fall back to `yt-dlp -g` so freshly synced videos don't pay a 2–5s `yt-dlp` spawn on every open!)*
2. **`video_platform.rs::fetch_video_stream_chunk` (`L2516-2664`) & `protocol.rs:112-207`**:
   - Auto-Referer fallback (`L2540-2546`): if explicit `referer` is absent and `DouyinURLParser::is_douyin_video_host(parsed.host_str())`, inject `Some("https://www.douyin.com/".to_string())`.
   - **`application/octet-stream` → `video/mp4` normalization (`L2598-2663`)**: After reading `bytes`, if upstream `content_type` is empty or `application/octet-stream` (case-insensitive) AND (`(bytes.len() >= 12 && &bytes[4..8] == b"ftyp")` OR `DouyinURLParser::is_douyin_video_host(parsed.host_str())`), rewrite `content_type = "video/mp4".to_string()` so WebView2 `<video>` reliably decodes and seeks Range-proxied Douyin streams (note: non-zero byte-range chunks do not start with `ftyp`, so checking the Douyin VOD host covers both `bytes=0-...` and mid-stream seeks!).
3. **On-demand save (`engine.rs:4096-4150` + `video_platform.rs:1855-1894`)**:
   - Clicking **"保存视频为独立素材"** in Quick Look calls `extract_link_media_attachment`.
   - `engine.rs:4100` first tries `SocialPostResolver::download_media_bytes_with_referer` (with `Referer: https://www.douyin.com/` + `ftyp` extension sniffing → `.mp4`).
   - If the stored Douyin CDN URL has expired (HTTP 403/410), `engine.rs:4125-4133` automatically falls back to `VideoPlatformResolver::download_generic_web_video(page_url, parsed_att_url, ...)`, which tries `download_stream_file` and then `download_via_yt_dlp_if_available`.
   - **Fix in `video_platform.rs:1863-1869`**: Expand `looks_direct` to also accept `DouyinURLParser::is_douyin_video_host(direct.host_str())` so signed Douyin VOD URLs without `.mp4` in the path are attempted directly before invoking `yt-dlp`.

---

## 5. Windows React UI Design (`windows/ui/src/`)

### 5.1 Type & Domain Layer (`windows/ui/src/types/domain.ts`)
- Extend `SocialPlatform` (`L58-67`): add `'douyin'` (and tolerate unknown string values gracefully in runtime helpers without crashing).
- Keep `isVideoSocialPlatform` (`L69-71`) as `youtube | bilibili` (16:9 video platforms); add helper `isVerticalSocialFeedPlatform(platform)` returning `platform === 'xiaohongshu' || platform === 'douyin'`, and `usesStreamingVideoViewer(post)` returning `isVideoSocialPlatform(post.platform) || (post.platform === 'douyin' && Boolean(post.hasVideo))`.
- Extend `formatSocialDisplayHandle` (`L195-215`): mirror Rust sanitation for `'douyin'` (suppress `'douyin'`, `MS4wLjAB...` `sec_uid`, long numeric IDs, duplicate nickname; format human handles as `抖音号 ...`).
- Extend `resolveSocialMediaUrl` (`L230-265`): route Douyin CDN hosts (`douyinpic.com`, `byteimg.com`, `ibytedtos.com`, `zjcdn.com`, `snssdk.com`, `amemv.com`, `pstatp.com`) through `/proxy-social` in Tauri runtime.
- Extend `getEffectiveSocialAttachments` (`L326`): when `usesStreamingVideoViewer(post)` is true and `attachments.length === 0` with `post.originalURL`, synthesize a `Video` attachment pointing to `post.originalURL` so Inspector / Quick Look's "保存视频为独立素材" CTA remains available even for bare pasted links!

### 5.2 Quick Look Per-Item Branching (`SocialPostViewer.tsx` + `QuickLookOverlay.tsx`)
- **`SocialPostViewer.tsx`**:
  - Add `douyin: { name: '抖音', openLabel: '在抖音中打开', badgeBg: '#161823', noun: '作品' }` to `PLATFORM_META` (`L75-87`).
  - Replace platform-only `isVideoPlatform` viewer switch (`L130, 303, 415`) with per-item `useStreamingPlayer = usesStreamingVideoViewer(post)`:
    - **Douyin Video (`platform === 'douyin' && post.hasVideo`)**: Render `<QuickLookStreamingVideoView />` (`aspect-video` container with `object-contain` cleanly letterboxes vertical 9:16 videos without cropping, preserving full transport controls, **"设当前帧为封面"**, and **"保存视频为独立素材"** CTA).
    - **Douyin Multi-Image Photo-Note (`platform === 'douyin' && !post.hasVideo`)**: Fall through to the multi-image attachment grid with `isVerticalMultiGrid = (isXiaohongshu || isDouyin) && !useStreamingPlayer && attachments.length > 1` (`L150`, 3:4 2-column grid + per-image & batch "全部提取为独立素材").
  - Display formatted duration pill (`MM:SS`) in post header metadata when `post.videoDurationSeconds > 0`.
- **`QuickLookOverlay.tsx:1046-1056`**: Extend Xiaohongshu badge/label checks to include `douyin` (`抖音` / `作品`).

### 5.3 Full Gallery, Inspector & Input Parity (Verified UI Touchpoints)
Every UI surface that currently special-cases `xiaohongshu` receives 1:1 `douyin` support:
1. **`windows/ui/src/features/gallery/masonryLayout.ts:160-171`**: Treat `douyin` / `douyin.com` / `v.douyin.com` identically to `xiaohongshu` (`rawRatio = 0.625` fallback when `pixelWidth/Height` not yet hydrated).
2. **`windows/ui/src/features/gallery/ringGalleryMath.ts:163-169`**: Recognize `platform === 'douyin'` and `douyin.com` / `v.douyin.com` in vertical card aspect classification.
3. **`windows/ui/src/features/gallery/AssetCard.tsx:82-85, 215`**: Badge label `'抖音'`; reuse vertical feed card fallback styling (`isVerticalSocialFeed = isXiaohongshu || isDouyin`).
4. **`windows/ui/src/features/gallery/GalleryFilmstripView.tsx:86, 951`**: Include `douyin` in vertical social card ratio & platform indicator.
5. **`windows/ui/src/features/inspector/InspectorView.tsx:120, 2088-2145`**: Platform label `'抖音作品'` / `'抖音'`, badge color `'#161823'`, post noun `'作品'`, and include `usesStreamingVideoViewer(post)` in `effectiveExtractItems` so Inspector also exposes **"保存视频为独立素材"** for Douyin video bookmarks.
6. **`windows/ui/src/App.tsx:199-201, 241`**: Extend clipboard paste / share-copy URL extraction regex to match `douyin.com/(?:video|note|user)/...`, `iesdouyin.com/...`, and `v.douyin.com/...` (including Chinese mobile share text containing embedded `https://v.douyin.com/...` links).
7. **`windows/ui/src/features/shelf/TopEdgeDropShelf.tsx:199-208`**: Recognize `douyin.com`, `iesdouyin.com`, `v.douyin.com` in drag-drop URL classification.
8. **`windows/ui/src/api/transport.ts:1907-1935`**: Add browser-dev mock branch for `douyin.com` / `v.douyin.com` so UI tests and non-Tauri browser preview stay functional.

---

## 6. Cross-Platform Compatibility & Migration Notice

### 6.1 Verified Impact on Un-Upgraded Clients Sharing `/.charkle/`
As verified in [`research/codebase-and-compatibility-audit.md`](./research/codebase-and-compatibility-audit.md) §5.3:
- **Published macOS v1.5.1 & iOS v1.5.1** (`Sources/CharkleCore/Contracts/CoreModels.swift:60, 282, 879, 1047`, `SyncOperations.swift:136, 316`, `DriveSyncEngine.swift:1037-1046`): `SocialPlatform` is a closed Swift enum. Pulling an op shard containing `"platform": "douyin"` throws `DecodingError.dataCorrupted` and rolls back the sync chunk transaction without advancing `deviceCursors`.
- **Un-upgraded Windows / Android Rust clients**: Identical `serde_json::Error` rollback prior to this task's `SocialPlatform::Douyin` + `Unknown(String)` hardening.
- **Web client** (`web/packages/shared/src/sync/swift-codec.ts:672-703, 718-729`): Coerces unrecognized platforms to `'x'` and drops v1.5 fields if re-saved.

### 6.2 Required Mitigation & Release Sequencing
1. **Windows-side forward hardening (this task)**: Implement lossless `SocialPlatform::Unknown(String)` serde in `windows/crates/charkle-core` so future platforms never stall Windows/Android sync again.
2. **Mandatory Cross-Platform Handoff Task (Wave 4)**: Create `.trellis/tasks/<MM-DD>-cross-platform-douyin-socialplatform-parity/` (PRD + `task.json`, without editing `Sources/`, `ios/`, `web/`, or `scripts/`) specifying:
   - macOS/iOS (`Sources/CharkleCore/`): add `case douyin = "douyin"`, add lossless/graceful unknown-platform fallback in `SocialPostMetadata.init(from:)` / `AssetRichMetadata.init(from:)`, add `douyin:<aweme_id>` dedup & `900×1440` card / streaming parity, and update `scripts/build-safari-extension.sh` to package `page-bridge.js` + `x-bridge-loader.js` + full `lib/` bundle.
   - Web (`web/packages/shared/`): add `'douyin'` (and missing v1.3–v1.5 platforms) to `SocialPlatform` and preserve unknown platform strings + v1.5 rich metadata fields in `swift-codec.ts`.
3. **User-facing Pre-Upgrade Notice**: Include an explicit warning in release notes / task handoff: users sharing a `/.charkle/` cloud sync library between Windows and macOS/iOS v1.5.1 MUST upgrade macOS/iOS to the version containing `case douyin` before cloud-syncing Windows-collected Douyin bookmarks.

---

## 7. Key Trade-offs, Risks & Rollback Strategy

| Risk / Trade-off | Impact | Mitigation | Rollback Point |
| :--- | :--- | :--- | :--- |
| **Douyin Web API path / field drift** | Passive parser misses fields or fails to recognize a sub-collection API shape. | Wave 1 begins with live schema verification via `chrome-mcp-server` on real logged-in Douyin tabs; keep defensive multi-path field fallbacks (`aweme_list` / `aweme_detail`, `origin_cover` / `cover`, `bit_rate` / `play_addr`) + DOM fallback scanning. | Revert `page-bridge.js` / `lib/douyin-parser.js` / `content.js` Douyin hooks; zero impact on X/XHS/IG/Threads/BSky. |
| **Ephemeral Douyin VOD URL expiration** | Bookmarked `douyinvod.com` direct stream URLs expire hours after collection. | Quick Look `resolve_playback_plan` falls back to `yt-dlp -g` (`CREATE_NO_WINDOW`, 6s timeout); "保存视频为独立素材" falls back to `download_generic_web_video` / `yt-dlp`; users always have "在抖音打开" fallback. | Zero data loss — bookmark card, cover, text, and canonical `/video/<id>` link remain intact. |
| **Douyin HEIC cover / image URLs** | Rust `image` crate cannot decode HEIC natively, causing blank covers if HEIC URL is picked first. | `lib/douyin-parser.js` & `page-bridge.js` filter/deprioritize `.heic`/`.heif` URLs in `url_list` in favor of `.jpeg`/`.webp`/`.png`; Rust cover downloader iterates up to 4 candidate URLs (`pipeline.rs:884`). | Pure parser ordering adjustment; no schema migration. |
| **`SocialPlatform` dropping `Copy`** | Compiler touchpoints across `charkle-core` (~7 files). | Purely internal to `charkle-core`; validated immediately by `cargo clippy --workspace --all-targets -- -D warnings` and `cargo test --workspace`. | Isolated within Wave 2 commit; clean git revert if ever needed. |
| **Douyin login wall / verification modal during batch scroll** | Aggressive scrolling triggers rate-limit or verification prompt. | Humanized scroll cadence + automatic pause when login/verification modal is detected; strictly user-resolved in visible tab (never bypass). | Batch job pauses cleanly with already-flushed chunks preserved via `douyin:<aweme_id>` dedup. |
| **Windows / Extension mirror drift** | Installer ships stale extension lacking `page-bridge.js` or `lib/douyin-parser.js`. | Enforce byte-identical copy + automated diff verification and `tauri.conf.json` entry check in Wave 1 & Wave 4. | Re-sync `windows/src-tauri/resources/BrowserExtension/` from canonical `Resources/BrowserExtension/`. |
