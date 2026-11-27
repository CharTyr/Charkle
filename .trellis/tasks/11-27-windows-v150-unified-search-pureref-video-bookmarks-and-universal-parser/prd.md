# Windows Parity Handoff (v1.5.0): Unified Search, PureRef (.pur), YouTube/Bilibili Video Bookmarks, Universal Web Parser & Batch Link Media Extraction

## Scope
Mirror the macOS & iOS `v1.5.0` feature set and `/.charkle/` sync metadata schema inside `windows/` (`windows/crates/charkle-core`, `windows/src-tauri`, `windows/ui`) without modifying macOS or iOS files.

---

## 1. Cross-Platform `/.charkle/` Sync Wire Contract (MANDATORY FIRST)

Preserve exact backward-compatible JSON keys (camelCase) in `AssetRichMetadata` so libraries synced across macOS, iOS, and Windows round-trip with zero data loss:

### 1.1 `SocialPlatform` Enum Extensions
Add two raw string values alongside existing platforms (`x`, `xiaohongshu`, `threads`, `bluesky`, `pixiv`, `instagram`):
- `"youtube"` (`isVideoPlatform = true`)
- `"bilibili"` (`isVideoPlatform = true`)

### 1.2 `SocialPostMetadata` Optional Extensions
All fields MUST use `#[serde(default)]` so legacy records decode cleanly:
```json
{
  "videoDurationSeconds": 612.0,
  "videoSummary": "视频核心摘要文本...",
  "videoOutline": ["00:00 开场与背景", "02:15 关键拆解"],
  "videoID": "BV1xx411c7mD",
  "videoCID": 123456789
}
```

### 1.3 `WebPageRichMetadata` (`AssetRichMetadata.webPage`)
Add optional `webPage` field to `AssetRichMetadata`:
```json
{
  "webPage": {
    "siteName": "Example Site",
    "authorName": "Author Name",
    "publishedAtText": "2026-11-27",
    "summary": "Extracted description or article lead summary...",
    "attachments": [
      {
        "id": "video:https://cdn.example.com/demo.mp4",
        "kind": "video",
        "url": "https://cdn.example.com/demo.mp4",
        "thumbnailURL": "https://cdn.example.com/poster.jpg"
      }
    ],
    "hasVideo": true,
    "durationSeconds": 95.0,
    "canonicalURL": "https://example.com/post/123"
  }
}
```
`SocialMediaAttachment.kind` values remain `"photo" | "video" | "gif"`.

---

## 2. YouTube & Bilibili Video Bookmarking + Summaries + On-Demand Video Save

Reference implementation: `Sources/CharkleCore/Media/VideoPlatformResolver.swift`, `Sources/CharkleCore/Media/SocialPostResolver.swift`, `Sources/CharkleCore/Media/MediaArtwork.swift`.

### 2.1 Zero-Download Default Bookmark Contract (STRICT)
When bookmarking a YouTube (`youtube.com/watch?v=`, `youtu.be/`, `youtube.com/shorts/`, `youtube.com/live/`, `m.youtube.com/`) or Bilibili (`bilibili.com/video/BV...`, `av...`, `b23.tv/...` short redirect, `m.bilibili.com/`) URL:
- **NEVER download the video file on default bookmarking.**
- Fetch ONLY: title, creator/UP name & avatar, 16:9 cover thumbnail (`Referer: https://www.bilibili.com/` required for `i0/i1/i2.hdslb.com` to avoid HTTP 403), duration, and existing video summary/chapters:
  - **Bilibili**:
    1. Resolve `b23.tv` redirects first; parse `BV`/`av` ID and optional `?p=N` page index.
    2. Query `https://api.bilibili.com/x/web-interface/view?bvid=...` (or `aid=...`) for title, owner, `pic`, `duration`, `cid`, `desc`, and `pages`.
    3. Fetch WBI signing keys from `https://api.bilibili.com/x/web-interface/nav` (`img_url` / `sub_url`), apply the standard 64-entry `mixinKeyEncTab` + MD5 `w_rid` signature, and query `https://api.bilibili.com/x/web-interface/view/conclusion/get` (`bvid`, `cid`, `up_mid`) to retrieve Bilibili's AI summary (`model_result.summary`) and timestamped outline (`model_result.outline`).
  - **YouTube**:
    1. Call InnerTube `POST https://www.youtube.com/youtubei/v1/player` (`WEB` / `ANDROID` client payload) with fallback to YouTube oEmbed + watch HTML parsing.
    2. Extract title, author, `lengthSeconds`, high-res thumbnail (`maxresdefault`/`hqdefault`), description timestamp chapters (`00:00 ...`), and caption track digest (XML/JSON3 timedtext first-pass summary if available).
- Write summary + outline into `notes` and `ocrText` (searchable via unified search) and generate a clean 16:9 video bookmark preview card (`~1.26` aspect ratio with play emblem, duration badge, and `"含视频摘要"` pill when summary/outline is present).

### 2.2 Explicit On-Demand Video Save ("保存视频为独立素材")
- In Quick Look / Detail view, Inspector, and context menu for YouTube / Bilibili bookmarks:
  - Render the 16:9 cover + open-in-browser link (NEVER feed a web watch URL directly to `<video>`), display the `"视频摘要"` card and chapter outline, and provide an explicit **"保存视频为独立素材"** button.
- Only when explicitly triggered:
  - Download progressive MP4 via native HTTP (`Bilibili x/player/wbi/playurl` HTML5 `fnval=1&platform=html5&high_quality=1` with `Referer: https://www.bilibili.com/`; `YouTube InnerTube` progressive MP4 `formats`), with optional local `yt-dlp` CLI fallback on Windows when available on `PATH` (resolving best MP4 ≤ 1080p for adaptive/DASH-only streams).
  - Import the downloaded `.mp4` as a standalone video asset preserving source URL, creator, video title, and current folder/tags (with SHA-256 dedup).

---

## 3. Universal Multi-Platform Rich Webpage Parser

Reference implementation: `Sources/CharkleCore/Media/WebBookmark.swift`.

Upgrade generic webpage bookmarking (raise HTML body cap to 1 MB) with a 5-layer universal extraction pipeline:
1. **HTML Meta Tags**: OpenGraph (`og:title`, `og:description`, `og:image`, `og:site_name`, `og:video`, `og:video:secure_url`, `og:video:url`), Twitter Card (`twitter:title`, `twitter:description`, `twitter:image`, `twitter:player:stream`), `article:author`, `article:published_time`, `<meta name="author">`, and `<link rel="canonical">`.
2. **Full JSON-LD (Schema.org)**: Parse all `<script type="application/ld+json">` blocks (including `@graph` arrays and nested objects) for `Article`, `NewsArticle`, `BlogPosting`, `VideoObject`, `CreativeWork`, `WebPage` — extracting `headline`/`name`, `description`, `author`, `datePublished`, `thumbnailUrl`/`image`, `contentUrl`/`embedUrl`, and ISO-8601 `duration` (`PT#H#M#S`).
3. **Universal oEmbed Auto-Discovery**: Follow `<link rel="alternate" type="application/json+oembed" href="...">` (SSRF-checked) to recover `title`, `author_name`, `provider_name`, `thumbnail_url` for platforms like Vimeo, SoundCloud, Dailymotion, CodePen, Behance, Figma, etc.
4. **DOM Media & Readable Summary Extraction**: Extract `<video src>` / `<video><source src>` + poster, lazy-loaded hero `<img>` (`data-original`, `data-src`, `data-lazy-src`, largest `srcset` candidate, skipping tracking pixels/icons), and first readable `<article>` / `<main>` / `<p>` paragraphs when meta description is absent or too short.
5. **Headless WebView2 SPA Fallback**: For JS-rendered SPAs where static HTML lacks meaningful title/media/summary, hydrate in a hidden WebView2 instance (bounded timeout) and probe rendered DOM title, description, lead paragraphs, hero images, and `<video>` sources.

Persist discovered `WebPageRichMetadata` into `AssetRichMetadata.webPage` and index summary into `notes` + `ocrText`. In Detail view & Inspector, display rich webpage summary + discovered attachments and allow extracting any image/video into a standalone library asset (direct HTTP download or optional `yt-dlp` fallback for embedded video pages).

---

## 4. Multi-Select Batch Link Media Extraction

Reference implementation: `Sources/CharkleCore/Contracts/CoreModels.swift` (`AssetRecord.extractableLinkAttachments`), `Sources/CharkleApp/Stores/LibraryStore.swift` (`extractMediaFromSelectedLinks`), `Sources/CharkleApp/Views/MainWindowView.swift`.

- Compute `extractableLinkAttachments` uniformly for any selected bookmark asset:
  - Social posts (`x`, `xiaohongshu`, `threads`, `bluesky`, `pixiv`, `instagram`),
  - Video platforms (`youtube`, `bilibili` — on-demand download),
  - Rich webpages (`webPage.attachments`).
- In the multi-select floating action pill, display a 1-click **"提取媒体 (N)"** button whenever `>= 1` selected assets have extractable link media.
- Run extraction cleanly with progress status & summary toast (succeeded/skipped/failed counts), preserving each link's folder, source URL, and metadata.

---

## 5. Unified Seamless Semantic Search

- Remove standalone `✨ 语义` mode toggle buttons and `"返回普通检索"` return banners from the top toolbar / filter chrome.
- Fuse instant literal / FTS / OCR / Pinyin filtering (0 ms synchronous) with background hybrid semantic search (when local/AI embeddings are enabled), merging and deduplicating hits seamlessly inside the unified search bar.

---

## 6. Bidirectional PureRef (`.pur`) Import/Export & Clipboard/Drag Polish

Reference implementation: `Sources/CharkleCore/Media/PureRefCodec.swift`, `Tests/CharkleTests/PureRefCodecTests.swift`.

- **Import `.pur`**:
  - Support PureRef v1.10 binary scenes (header + MD5 integrity verification + zlib/embedded image streams + item transform/crop/opacity/text notes) and v2.0+ multi-format image container extraction.
  - Import embedded images into the Charkle library (SHA-256 deduplicated) and reconstruct a Charkle Moodboard preserving relative spatial layout, scale, and rotation.
- **Export `.pur`**:
  - Export any Charkle Moodboard into a valid PureRef v1.10 `.pur` binary file so users can round-trip directly with PureRef.
- **Clipboard & Gallery Drag Polish**:
  - Single-image copy (`Ctrl+C`) places one clean image/file payload without duplicate entries.
  - Dragging an image out of the gallery exports the full-resolution original file when locally available instead of a compressed thumbnail.

---

## 7. Release Coordination (`v1.5.0`)
- Bump Windows package versions (`windows/Cargo.toml`, `windows/src-tauri/tauri.conf.json`, `windows/ui/package.json`, updater fallback/tests) to `1.5.0`.
- Follow `.agents/skills/charkle-windows-ship/SKILL.md`:
  - Run full TypeScript + Vitest + Vite + `cargo fmt --check` + `cargo clippy --all-targets -- -D warnings` + `cargo test --workspace` + NSIS release build (`Charkle_1.5.0_x64-setup.exe`).
  - Target shared GitHub Release `v1.5.0` (macOS DMG and iOS unsigned IPA published first): upload `Charkle_1.5.0_x64-setup.exe` and replace **only** the `## Windows（v1.5.0）` placeholder section, preserving macOS and iOS release notes verbatim.
