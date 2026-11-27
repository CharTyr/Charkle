# Cross-Platform Parity Handoff: Douyin `SocialPlatform`, Unknown-Platform Sync Resilience & Safari / Web Alignment

> **Source Task (Windows)**: [`.trellis/tasks/11-27-windows-douyin-favorites-sync/`](../11-27-windows-douyin-favorites-sync/)  
> **Target Platforms**: macOS (`Sources/`, `Tests/`, `scripts/`), iOS/iPadOS (`ios/`), Web (`web/`)  
> **Priority**: `P1` · **Status**: `planning` (Handoff — do not edit `windows/` when implementing this task)  
> **Canonical Contracts**: `AGENTS.md`, `DESIGN.md`, `.trellis/spec/cross-platform/index.md`

---

## 1. Goal & Cloud-Sync Compatibility Alert

Charkle Windows & BrowserExtension are adding first-class **Douyin (抖音)** favorites, collection sub-folders, likes, author profile works, and single-post sync using `SocialPlatform::Douyin` (`"douyin"`) inside `AssetRichMetadata.socialPost` (`/.charkle/` sync wire format).

> [!IMPORTANT]
> **Pre-Upgrade Cloud-Sync Caveat (macOS / iOS v1.5.1)**:  
> Published macOS v1.5.1 and iOS v1.5.1 decode `SocialPlatform` as a strict closed Swift enum (`Sources/CharkleCore/Contracts/CoreModels.swift:60, 282, 879, 1047`). When `DriveSyncEngine` (`Sources/CharkleCore/Sync/DriveSyncEngine.swift:1037-1046`) calls `SyncFields.merge` (`Sources/CharkleCore/Sync/SyncOperations.swift:136, 316`) on an op shard containing `"platform": "douyin"`, `JSONDecoder` throws `DecodingError.dataCorrupted`, **rolling back the entire chunk transaction (up to 40 op shards) without advancing `deviceCursors`**.  
> Users sharing a `/.charkle/` Google Drive / WebDAV / iCloud / mounted library between Windows and macOS/iOS **MUST upgrade macOS/iOS to the release containing this task's `case douyin` + unknown-platform decode resilience before cloud-syncing Windows-collected Douyin bookmarks**.

This task brings macOS, iOS/iPadOS, Safari Web Extension packaging, and Web to 100% lossless parity with Windows and eliminates closed-enum sync stalls permanently for any future platforms.

---

## 2. Canonical Cross-Platform Wire Contract (`/.charkle/`)

### 2.1 `SocialPlatform` Wire Token & Deduplication Key
- **Wire value**: `"douyin"` (camelCase/lowercase JSON string inside `AssetRichMetadata.socialPost.platform`).
- **Display metadata**:
  - `displayName`: `"抖音"`
  - `postNoun`: `"作品"`
  - `postTypeLabel`: `"抖音 作品"`
  - `openActionLabel`: `"在抖音打开"`
- **Canonical deduplication key**: `douyin:<aweme_id>` (15–22 ASCII digit `aweme_id`), independent of query noise (`modal_id`, tracking params) or `v.douyin.com` short links.
- **Supported URL shapes**:
  - `https://www.douyin.com/video/<aweme_id>` / `m.douyin.com` / `iesdouyin.com`
  - `https://www.douyin.com/note/<aweme_id>` (photo-note / 图文)
  - `/share/video/<aweme_id>`, `/share/note/<aweme_id>`
  - Any Douyin URL carrying `?modal_id=<aweme_id>`
  - `https://v.douyin.com/<code>` short links (including Chinese mobile share copy text)
- **Handle sanitation (`displayHandleLine` / `displayAuthorName`)**:
  - Hide internal `sec_uid` strings (`MS4wLjAB...`), long numeric UIDs (`>= 12` digits), `"douyin"`, or duplicates of `authorName`.
  - Format human-readable handles as `"抖音号 <handle>"`; fall back author name to `"抖音用户"`.

---

## 3. macOS & iOS Requirements (`Sources/`, `Tests/`, `ios/`, `scripts/`)

### M1. `SocialPlatform.douyin` + Lossless Unknown-Platform Decode Resilience (CRITICAL)
- **`Sources/CharkleCore/Contracts/CoreModels.swift:60-113, 280-307, 876-896`**:
  - Add `case douyin` (wire value `"douyin"`).
  - **Fix the closed-enum sync stall permanently**: Replace closed `String`-backed `Codable` synthesis with lossless unknown-platform handling (mirroring Windows `SocialPlatform::Unknown(String)`):
    - Preferred approach: `case unknown(String)` with custom `init(from:)` / `encode(to:)` preserving the original raw string verbatim across SQLite storage and `/.charkle/` op round-trips (providing `rawValue` / `fromRaw` helpers and safe default display labels `"社交动态"` / `"原链接"`), OR graceful fallback inside `SocialPostMetadata.init(from:)` / `AssetRichMetadata.init(from:)` ensuring unknown `platform` tokens **never throw** during `SyncFields.merge` (`SyncOperations.swift:136, 316`) or `DriveSyncEngine` (`DriveSyncEngine.swift:1037-1046`).
  - Update `SocialPostMetadata.displayHandleLine` (`CoreModels.swift:310-329`) for `.douyin` handle sanitation.

### M2. Decoupled Zero-Download Video Bookmarking (`prefersZeroDownloadVideoBookmark`)
- **`Sources/CharkleCore/Contracts/CoreModels.swift:70-72`** & media ingest pipeline:
  - Keep `isVideoPlatform` scoped to horizontal 16:9 platforms (`.youtube || .bilibili`).
  - Add an independent predicate `prefersZeroDownloadVideoBookmark: Bool` returning `true` for `.youtube`, `.bilibili`, and `.douyin`, wired into bookmark ingest so Douyin video bookmarks store cover + `.md` + `SocialPostMetadata` by default (zero eager MP4 download) without forcing vertical videos or multi-image notes ("图文") into 16:9 layout.

### M3. Douyin URL Parser, CDN Referer, `900×1440` Card & Quick Look Streaming Parity
- **`Sources/CharkleCore/Media/`** (`SocialPostResolver.swift`, `VideoPlatformResolver.swift`, `MediaArtwork.swift`, new `DouyinPostResolver.swift`):
  - Parse `/video/<id>`, `/note/<id>`, `?modal_id=<id>`, `iesdouyin.com`, and `v.douyin.com` short-link redirects (SSRF-guarded), computing `douyin:<aweme_id>` in `SocialPostReference.dedupKey` (`SocialPostResolver.swift:39-49`).
  - Allow Douyin image & video CDN hosts (`*.douyinpic.com`, `*.byteimg.com`, `*.ibytedtos.com`, `*.douyinvod.com`, `*.zjcdn.com`, `*.snssdk.com`, `*.bytevcloudapi.com`, `*.amemv.com`, `*.pstatp.com`) with automatic `Referer: https://www.douyin.com/` and desktop browser `User-Agent`.
  - Handle `application/octet-stream` video/image responses via ISO BMFF `ftyp` magic-byte sniffing (`avif`/`heic`/`mp4`) so streamed and extracted MP4s decode reliably.
  - Render Douyin bookmarks as `900×1440` vertical feed cards (`3:4` `900×1200` cover + `240px` white footer, accent `#161823` with `#FE2C55` heart/badge; video cards show play circle + bottom-right `MM:SS` duration pill; multi-image photo-notes show top-left `N 图` pill).
  - Wire `VideoPlatformResolver.resolvePlaybackPlan(for:)` for `.douyin` (direct stream with `Referer: https://www.douyin.com/` + macOS `yt-dlp` fallback when ephemeral CDN URLs expire) and on-demand MP4 extraction (`downloadGenericWebVideo` / `yt-dlp`).
- **`Sources/CharkleApp/`, `Sources/CharkleCanvas/`, `ios/CharkleMobile/`**:
  - Branch Quick Look (`QuickLookRichViewers.swift`, `AssetDetailView.swift`) by per-item content: `.douyin && post.hasVideo` reuses `QuickLookStreamingVideoView` (inline streaming + "设当前帧为封面" + "保存视频为独立素材"); `.douyin && !post.hasVideo` renders the 3:4 multi-image grid with single/batch image extraction.
  - Update `VirtualizedMasonryView.swift`, `RingGalleryMetalView.swift`, `InspectorView.swift`, `LocalExtensionBridgeServer.swift`, and `ios/CharkleMobile/` (`MobileTheme.swift:390`, `MobileAppStore.swift:1134`, `AssetDetailView.swift:1014`) for `.douyin` aspect ratio (`0.625`), badge labels, and bridge dedup/ingest parity.

### M4. Safari Web Extension Packaging Alignment (`scripts/build-safari-extension.sh`)
- **`scripts/build-safari-extension.sh:40-44, 89-102`**:
  - Line 40 currently copies only `content.js popup.html popup.css popup.js options.html options.css options.js`, omitting `page-bridge.js` and `x-bridge-loader.js` required by `Resources/BrowserExtension/manifest.json` (`content_scripts[0]` and `web_accessible_resources[1]`). Add `page-bridge.js` and `x-bridge-loader.js` to the copy loop!
  - Verify `lib/*.js` copy (`L43`) packages `lib/social-collectors.js`, `lib/x-author-media.js`, and `lib/douyin-parser.js` into `Contents/Resources/lib/`.
  - Check classic Service Worker bundling (`L89-90`): keep `lib/url-detect.js` self-contained and add any additional `lib/*.js` modules imported by `background.js` in dependency order before `background.js`.
  - Extend syntax verification (`L99-102`) with `node --check` on `page-bridge.js` and `x-bridge-loader.js`.
  - Verify signed `CharkleSafariExtension.appex` in clean `/tmp` copy via `codesign --verify --deep --strict`.

---

## 4. Web Requirements (`web/`)

### W1. `@charkle/shared` `SocialPlatform` & Lossless `SwiftWireCodec` Alignment
- **`web/packages/shared/src/models/core.ts:158-183`**:
  - Bring `SocialPlatform` up to parity with desktop (`'x' | 'threads' | 'bluesky' | 'xiaohongshu' | 'pixiv' | 'instagram' | 'youtube' | 'bilibili' | 'douyin'` plus tolerant string handling for unknown future platforms), updating `socialPlatformDisplayName` and `socialPlatformOpenActionLabel`.
- **`web/packages/shared/src/sync/swift-codec.ts:644-729`**:
  - Replace line 676's lossy coercion (`obj.platform === 'threads' || obj.platform === 'bluesky' ? obj.platform : 'x'`) with lossless preservation of all known platform strings AND unrecognized future platform strings.
  - Preserve v1.5 `SocialPostMetadata` fields (`videoDurationSeconds`, `videoSummary`, `videoOutline`, `videoID`, `videoCID`) and `AssetRichMetadata.webPage` (`WebPageRichMetadata`) across encode/decode so Web never strips desktop metadata on round-trip sync.
- **`web/packages/server/` & `web/packages/client/`**:
  - Update `SocialPostViewer.tsx`, `artwork-svg.ts`, and `media/resolvers/social.ts` for `'douyin'` rendering, canonical dedup (`douyin:<aweme_id>`), and safe fallback for unknown platforms.
  - Sync `Resources/BrowserExtension/` updates back to `web/packages/extension/` and verify Cloudflare Workers (`npm run cf:pack && npm run cf:typecheck && npm run cf:dry-run`).

---

## 5. Out of Scope

- Do **not** modify `windows/` files in this task (Windows implementation lives in `.trellis/tasks/11-27-windows-douyin-favorites-sync/`).
- Do **not** reverse-engineer Douyin anti-bot signatures or bypass login/CAPTCHA gates.

---

## 6. Acceptance Criteria

- [ ] **AC-1 (macOS / iOS Lossless Unknown-Platform & Douyin Decode)**: Swift unit tests (`Tests/CharkleTests/`) verify `SocialPlatform.douyin` (`"douyin"`) round-trip AND decoding an unknown future platform (e.g., `"futureApp"`) inside `AssetRichMetadata.socialPost` through `SyncFields.merge` and `DriveSyncEngine` without throwing or rolling back `deviceCursors`.
- [ ] **AC-2 (macOS / iOS Douyin Parity)**: `douyin:<aweme_id>` canonical dedup, `v.douyin.com` short-link expansion, `prefersZeroDownloadVideoBookmark`, `900×1440` card artwork, Quick Look streaming playback + frame-to-cover + on-demand MP4 save (video) vs 3:4 grid (photo-note) all pass `swift build --build-tests -Xswiftc -warnings-as-errors && swift test --skip-build`.
- [ ] **AC-3 (Safari Extension Bundle)**: `./scripts/build-safari-extension.sh` copies `page-bridge.js`, `x-bridge-loader.js`, and all `lib/*.js` (including `lib/douyin-parser.js`), passes `node --check` on all classic scripts, and passes strict `/tmp` `codesign --verify --deep --strict` on `CharkleSafariExtension.appex`.
- [ ] **AC-4 (Web Lossless Codec & Dual Runtime)**: `web/packages/shared/tests/swift-codec.test.ts` proves lossless round-trip of `"douyin"`, unknown future `platform` strings, v1.5 video fields, and `webPage`; `cd web && npm run typecheck && npm test && npm run build && npm run cf:typecheck && npm run cf:dry-run` all pass.
- [ ] **AC-5 (Purity)**: Zero personal paths, secrets, signing cert identities, or forbidden external product/author mentions.
