# Charkle Web — macOS Feature & Contract Parity Specification

> **Source of truth**: Working tree of `/Users/char/Documents/Projects/Charkle` (audited across `CharkleCore`, `CharkleApp`, `CharkleCanvas`, and `Resources/FigmaPlugin/code.js`).
> **Audience**: Wave 2 Backend & Frontend engineers implementing `Charkle-Web` to 100% functional parity with zero omissions.

---

## 1. Social Post Capture & Media Extraction (X / Threads / Bluesky)

### 1.1 Supported URL Patterns (`SocialPostURLParser`)
| Platform | Accepted Hosts | Accepted Path Patterns | Canonical URL |
|---|---|---|---|
| **X / Twitter** (`x`) | `x.com`, `twitter.com`, `mobile.x.com`, `mobile.twitter.com`, `www.*`, `fxtwitter.com`, `vxtwitter.com`, `fixupx.com`, `fixvx.com` | `/<handle>/status/<id>`, `/<handle>/statuses/<id>`, `/i/web/status/<id>` (`id` numeric, `1..24` digits) | `https://x.com/<handle>/status/<id>` |
| **Bluesky** (`bluesky`) | `bsky.app`, `www.bsky.app` | `/profile/<handle-or-did>/post/<rkey>` | `https://bsky.app/profile/<handle>/post/<rkey>` |
| **Threads** (`threads`) | `threads.net`, `threads.com`, `www.*` | `/@<handle>/post/<shortcode>` or `/t/<shortcode>` | `https://www.threads.net/@<handle>/post/<shortcode>` |

### 1.2 Backend Resolution Pipelines
- **X (`XPostResolver`)**:
  1. Primary: `GET https://api.fxtwitter.com/<handle>/status/<id>`. Reads `tweet.raw_text.text ?? tweet.text ?? tweet.article.preview_text`, `author.name`, `author.screen_name`, `author.avatar_url`, `article.title`, `quote` (`author`, `text`, `media`), engagement (`replies`, `retweets`, `likes`, `views`).
     - Media extraction order: `tweet.media.all` (photos/videos/gifs) → else `tweet.media.photos + tweet.media.videos` → else `tweet.article.cover_media.media_info.original_img_url` → else `tweet.quote.media`.
  2. Fallback: `GET https://api.vxtwitter.com/<handle>/status/<id>`. Reads `media_extended` (`image`/`video`/`gif`) or `mediaURLs`.
  3. Photo URL upgrade: rewrite `pbs.twimg.com` photo URLs with query param `name=orig`.
  4. Download limits: photo `35 MB`, video/gif `160 MB`.
- **Bluesky (`SocialPostResolver`)**:
  1. If actor is not `did:*`, resolve via `GET https://public.api.bsky.app/xrpc/com.atproto.identity.resolveHandle?handle=<actor>`.
  2. Fetch thread: `GET https://public.api.bsky.app/xrpc/app.bsky.feed.getPostThread?uri=at://<did>/app.bsky.feed.post/<rkey>&depth=0`.
  3. Extract `embed.images` / `embed.media.images`, `embed.playlist` (video), `embed.thumbnail`, `replyCount`, `repostCount`, `likeCount`, `author.avatar`.
  4. On failure, fall back to OpenGraph HTML parsing (`og:title`, `og:description`, `og:image`, cap HTML read at `512 KB`).
- **Threads (`SocialPostResolver`)**: OpenGraph HTML parser (`512 KB` cap) extracting author handle, description, and `og:image`.

### 1.3 Cohesive Storage Invariant (Critical Fix)
- A social post is **ALWAYS** stored as **ONE cohesive asset with `mediaKind = "webBookmark"`** and populated `richMetadata.socialPost`. **NEVER** flatten a social post into `mediaKind = "image"` or split it during initial capture.
- **Primary video offline caching**: If the post contains a video or GIF, download & cache the primary `.mp4` as the asset's original file for offline inline playback while **forcing `mediaKind = "webBookmark"`**. Otherwise store the generated Markdown archive (`<author> · <platform> ...`) as the original.
- Set `ocrText = bodyText` (plus quoted text/article title via FTS indexer), append platform `displayName` (`"X"`, `"Threads"`, `"Bluesky"`) to `tags`.
- **Custom Poster Card (`MediaArtwork.socialPostCard`)**: Render crisp light editorial card (`800×920` when media exists, `800×620` text-only) with platform badge pill (`X` `#18181B`, `Threads` `#27272A`, `Bluesky` `#0284C7`), author name + `@handle`, body excerpt, cover media, and centered play icon overlay when `hasVideo`.
- **Schema (`SocialPostMetadata` & `SocialMediaAttachment`)**:
  ```ts
  type SocialPlatform = 'x' | 'threads' | 'bluesky';
  interface SocialMediaAttachment {
    id: string; // default `${kind}:${url}`
    kind: 'photo' | 'video' | 'gif';
    url: string;
    thumbnailURL?: string;
  }
  interface SocialPostMetadata {
    platform: SocialPlatform;
    authorName: string;
    authorHandle: string;
    authorAvatarURL?: string;
    publishedAtText?: string;
    bodyText: string;
    quotedAuthor?: string;
    quotedText?: string;
    articleTitle?: string;
    mediaURLs: string[];
    mediaThumbnailURLs: string[];
    attachments: SocialMediaAttachment[];
    hasVideo: boolean;
    videoURL?: string;
    replyCount?: number;
    repostCount?: number;
    likeCount?: number;
    viewCount?: number;
    originalURL: string;
    mediaFetchFailed: boolean;
  }
  ```
- **`effectiveAttachments` backward compatibility**: If `attachments` is empty, derive typed items from `videoURL` (as `video`) + `mediaURLs` (sniff `.mp4`/`.m3u8`/`/ext_tw_video/`/`/amplify_video/`/`video.twimg.com` → `video`, else `photo`), deduplicated by URL.
- **Retry & Refresh (`refreshRichAsset(id)`)**: When `mediaFetchFailed === true`, Quick Look and Inspector show a warning banner with `"重试获取"` that re-runs the resolver, updates `richMetadata`, regenerates poster thumbnails, and invalidates client caches.
- **Standalone Media Extraction**: Available in Quick Look (`QuickLookSocialPostCard`), Filmstrip stage, and Inspector:
  - Single item: `POST /api/assets/:id/extract-media` (`{ attachmentIndex }`) → downloads/reuses cached original video or image, ingests into `postAsset.folderID`, titles `@<handle> <图片|视频|动图> #<n>`, attaches `notes`:
    ```
    来源推文：<authorName> (@<authorHandle>) · <platform>

    <bodyText>

    原推文链接：<originalURL>
    ```
    adds platform tag, preserves `sourceURL = originalURL`.
  - Batch: `"全部提取为独立素材"` extracts every item in `effectiveAttachments`.

---

## 2. GitHub Repository Resolver & README Viewer

### 2.1 URL Parsing & API Fetch (`GitHubRepoResolver`)
- Accepted hosts: `github.com`, `www.github.com`.
- Accepted paths: `/<owner>/<repo>` (strip `.git`) and `/<owner>/<repo>/tree/<branch>`.
- Reject deep paths (`/blob/`, `/issues/`, `/pull/`, etc.) and 33 reserved owners (`settings`, `explore`, `issues`, `pulls`, `gist`, `orgs`, `marketplace`, `sponsors`, `topics`, `trending`, `collections`, `events`, `notifications`, `login`, `signup`, `join`, `about`, `pricing`, `features`, `enterprise`, `team`, `security`, `customer-stories`, `readme`, `codespaces`, `copilot`, `apps`, `new`, `search`, `stars`, `watching`, `organizations`, `users`).
- Parallel requests:
  1. `GET https://api.github.com/repos/<owner>/<repo>` (`Accept: application/vnd.github+json`).
  2. `GET https://api.github.com/repos/<owner>/<repo>/readme[?ref=<branch>]` (Base64-decode `content`).
  3. Fallback if API README fails: raw fetches `https://raw.githubusercontent.com/<owner>/<repo>/{branch}/README.md`, `readme.md`, `master/README.md`.
  4. Cap `readmeMarkdown` at `120,000` chars; `topics` capped at `16`.
- `GitHubRepoMetadata`: `{ owner, repo, fullName, ownerAvatarURL?, description?, stars, forks, watchers?, language?, licenseName?, topics[], defaultBranch, homepageURL?, openGraphImageURL, readmeMarkdown?, fetchedAt }`. Default `openGraphImageURL = https://opengraph.githubassets.com/1/<owner>/<repo>`.
- Auto-tags: `["GitHub"]` + `[language]` (if present).
- Poster card: dark editorial `820×620` (`#111317` background, `#1E232B` header/pills) showing owner/repo, description, stars/forks, language dot, and topic chips.
- **Language Dot Colors**: `Swift #F05138`, `TypeScript #3178C6`, `JavaScript #F1E05A`, `Python #3572A5`, `Rust #DEA584`, `Go #00ADD8`, `HTML #E34C26`, `CSS #563D7C`, default `#60A5FA`.
- **Viewer (Quick Look `740×680` & Inspector card)**: Header with repo title, stars/forks/license/language pills, topic tags, `"在 GitHub 打开"` + `"访问主页"` buttons, and full rendered Markdown README (with Raw toggle & Copy README).

---

## 3. Media Kinds, Ingestion & Rich Viewers

### 3.1 `MediaKind` Extension Detection (`CoreModels.MediaKind.detect`)
| `mediaKind` | Localized Label | Extensions | MIME Fallback |
|---|---|---|---|
| `image` | 图片 | `jpg, jpeg, png, heic, heif, webp, tiff, tif, bmp, avif, jxl` (APNG `.png` promoted to `animatedImage`) | `image/*` |
| `animatedImage` | 动图 | `gif, apng` | `image/gif` |
| `video` | 视频 | `mp4, mov, m4v, webm, mkv, avi` | `video/*` |
| `webBookmark` | 网页 | `webloc, url` (+ all URL captures, Social Posts, GitHub Repos) | — |
| `document` | 文档 | `pdf, md, markdown, txt, rtf, docx, pptx, key, pages, json, yaml, yml, toml, csv` | `application/pdf`, `text/*`, default |
| `designFile` | 设计文件 | `svg, psd, psb, sketch, fig, ai, eps, xd, afdesign, afphoto` | `image/svg*` |
| `audio` | 音频 | `mp3, wav, m4a, aac, flac, ogg, aiff, aif, opus, caf, alac, wma, m4b, mid, midi` | `audio/*` |
| `model3D` | 3D 模型 | `usdz, usda, usdc, obj, stl, scn, dae, gltf, glb, fbx, ply, 3ds, blend` | `model/*` |

### 3.2 Ingestion & Thumbnail Tiers (`MediaPipeline` / `LiveCharkleEngine`)
- **Thumbnail Tiers**: `grid520` (max side `520px`, JPEG) and `preview1400` (max side `1400px`, JPEG, only created when `max(w,h) > 520`).
- **Concurrency & Directory Import**: Bounded 4-worker pool; recursive folder import max depth `16`; skips `.git`, `.svn`, `.hg`, `node_modules`, `__MACOSX`, `.Trash`, `.build`, `DerivedData`, dotfiles, symlinks.
- **Background Enrichment**: Runs OCR (explicitly **skips `.audio` and `.model3D`**) + optional Cloud AI auto-tagging (`autoAnalyzeOnImport`), emits realtime library update event.
- **Plain Text & Markdown (`isPlainTextDocument`, `isMarkdownDocument`)**:
  - Plain text extensions: `txt, md, markdown, json, yaml, yml, toml, csv, rtf`.
  - Ingestion reads first `65,536` bytes: stores `richMetadata.textExcerpt` (`prefix(1200)`), `richMetadata.isMarkdown` (`ext in ['md', 'markdown']`), `ocrText` (`prefix(8000)`), renders typographic card poster.
  - Quick Look viewer (`740×620`): reads up to `256 KB`, segmented `"排版视图"` (Rendered Markdown / syntax-highlighted code) vs `"源码"` (Raw monospace), `"复制全文"` button.
- **Audio Waveform**:
  - Backend extracts `durationSeconds` and `48` normalized peak bars (`waveformPeaks: number[]` in `[0, 1]`). Skips dominant color extraction for `.audio`.
  - Masonry card: `1.55` aspect ratio, `AUDIO` badge, displays mini waveform poster.
  - Quick Look Audio Studio Card (`580px` wide): circular play/pause button tinted with dominant color (or accent), time elapsed / total, interactive scrubbable waveform rendering `waveformPeaks.slice(0, 64)` (48 backend bars; empty fallback synthetic 48-bar curve `0.25 + 0.65 * Math.abs(Math.sin(i * 0.35))`), click or drag horizontally to seek.
- **3D Model Viewer**:
  - Ingestion sets `richMetadata.model3DFormat = ext.toUpperCase()`, generates snapshot thumbnail or styled 3D badge poster card.
  - Quick Look viewer (`960×640`, dark studio `#181A20` stage): interactive WebGL orbit viewer (Three.js / `<model-viewer>` supporting GLB/GLTF/OBJ/STL/PLY/FBX/DAE/USDZ where browser-supported, fallback poster card for unsupported native formats like `.blend`/`.scn`), auto studio lighting, format badge pill, `"重置视角"` camera reset button, mouse drag orbit + wheel zoom.
- **Other Quick Look Viewers**:
  - **PDF (`860×680`)**: Embedded multi-page PDF viewer (`pdf.js` / iframe), page counter, zoom.
  - **Video (`1020×640`)**: Native HTML5 `<video controls playsInline>` with poster.
  - **Animated GIF/APNG**: Native animated playback + loop indicator.
  - **Color Swatch (`420×420`)**: Large solid swatch card + HEX / RGB / HSL / CIELAB values with 1-click copy.
  - **Web Bookmark (`620px`)**: OG poster, title, domain pill, notes, `"在浏览器打开"` button.

---

## 4. Database, FTS5 Search, Sidebar, Folder Customization & Smart Folders

### 4.1 SQLite Schema & Rich FTS5 Indexing (`LibraryDatabase`)
- Core tables: `assets`, `assets_fts` (FTS5 `unicode61 remove_diacritics 2`, `prefix='2 3 4'`), `asset_tags`, `asset_colors` (CIELAB `l, a, b, hex, proportion`), `asset_vectors` (`feature_print`, `embedding`, `precision`, `embedding_model`), `folders`, `boards`, `board_assets`, `sync_ops`, `sync_state`, `original_cache`.
- **FTS5 columns & BM25 weights**: `(title=8, fileName=3, notes=1, tags=5, ocrText=2, aiDescription=2, sourceDomain=1, pinyin=3, initials=2)`.
- **Rich Metadata FTS Augmentation**: When indexing an asset, concatenate into the FTS `ocrText` column:
  - `richMetadata.githubRepo`: `fullName`, `description`, `language`, `topics.join(' ')`, first `4000` chars of `readmeMarkdown`.
  - `richMetadata.socialPost`: `platform.displayName`, `authorName`, `@authorHandle`, `articleTitle`, `bodyText`, `quotedText`.
- **Activity Timestamp**: `markAssetOpened(id)` updates `lastOpenedAt = now` locally **without** emitting a sync op. `recentActivityDate = max(createdAt, lastOpenedAt ?? -Infinity)`.
- **Folder Subtree & Move Rules**:
  - `includeSubfolders` expands `folderID` via BFS across `folders.parentID`.
  - `moveFolder(id, newParentID, sortOrder)`: cycle guard (reject moving into self/descendant), auto-dedup rename if sibling name collides, reindex sibling `sortOrder`.
  - `deleteFolder(id, trashContents: false)`: moves direct assets to Inbox (`folderID = null`), deletes folder.
  - `deleteFolder(id, trashContents: true)`: collects subtree post-order, moves all non-trashed assets in subtree to Trash (`folderID = null, isTrashed = true`), deletes all folders in subtree.

### 4.2 Sidebar (`SidebarView`)
- Collapsible rail: `56px` icon rail ↔ `232px` expanded (`⌘\` / `Ctrl+\`), Jump Anywhere trigger (`⌘J` / `Ctrl+J`).
- **5 Sections**:
  1. **Library**: `allItems` (全部素材), `inbox` (收件箱 — supports drop & paste-cut), `untagged` (未打标签), `recent` (最近使用 — `onlyRecentDays: 7` / recent activity), `trash` (回收站).
  2. **Moodboards**: Quick AI Generator CTA button (`MoodboardGeneratorSheet`), `moodboardsHome` (全部情绪板), list of boards with **active green dot** for current target board & offline pin indicator.
  3. **Smart Folders**: List with live matched asset count, custom color dot, context menu Edit / Delete, `+` button to open `SmartFolderEditorSheet`.
  4. **Hierarchical Folders**:
     - Sort toggle: A→Z vs by asset count.
     - Drag-to-reorder between sibling insertion slots + drag-to-nest onto folder row + external file/folder drop.
     - Cmd/Ctrl & Shift multi-select; inline create/rename with click-outside commit/dismiss.
     - Context menu: Create Subfolder, Rename, Quick 7-Color submenu, `"自定义图标与颜色..."` (`FolderCustomizationPopover`), Pin/Clear Offline, Delete (keep items in Inbox) vs Delete with contents (move to Trash).
  5. **Smart Capped Tags**:
     - Shows `recentFrequentSidebarTags` (up to `5`, scored by `recencyBonus = max(0, 60 - idx) * 1.5 + freqBonus = freq * 4.0`) + `topTenSidebarTags` (top `10` by count, tie-break A→Z), deduplicated + always includes currently selected tag.
     - `"全部标签 (N)"` button opens searchable popover with count/name sort toggle.

### 4.3 Folder Customization (`FolderCustomizationPopover`)
- Persisted on `FolderRecord`: `colorHex: string | null`, `customSymbol: string | null`.
- **7 macOS Preset Colors**:
  - 红色 `#FF453A`, 橙色 `#FF9F0A`, 黄色 `#FFD60A`, 绿色 `#30D158`, 蓝色 `#0A84FF`, 紫色 `#BF5AF2`, 灰色 `#8E8E93` + Reset (`null`) + custom HTML `<input type="color">`.
- **Icon/Symbol Storage Format**:
  - Preset symbol: `"sf:<name>"` — 48 icons grouped in 4 categories (`设计与创意`, `影像与媒体`, `人物与自然`, `开发与工作`; map SF Symbol names to crisp Lucide/custom SVG equivalents in Web while preserving the `"sf:<name>"` persisted wire format).
  - Emoji: `"emoji:<char>"` — 32 curated emoji presets + custom emoji text input.

### 4.4 Smart Folders (`SmartFolderRecord` / `SmartFolderEditorSheet`)
- Persisted in `sync_state` under key `"smart_folders.v1"` (JSON array of `SmartFolderRecord`).
- **Schema**:
  ```ts
  interface SmartFolderRule {
    matchMode: 'all' | 'any';
    tags: string[];
    descriptionQuery: string; // space-separated tokens, all tokens must match haystack
    colorHexes: string[];
    colorTolerance: number;   // CIELAB DeltaE, range 10..48 step 2, default 24.0
    mediaKinds: MediaKind[];
    minRating: number;        // 0..5
  }
  interface SmartFolderRecord {
    id: string;
    name: string;
    colorHex?: string; // defaults to selectedColorHexes[0]
    rule: SmartFolderRule;
    sortOrder: number;
    createdAt: string;
    updatedAt: string;
  }
  ```
- **Exact `matches(asset)` evaluation**:
  - Rejects trashed assets (`!asset.isTrashed`).
  - Only active (non-empty / `>0`) clauses produce a boolean entry in `checks[]`. If `checks.length === 0`, return `false`.
  - **Tags**: lowercased exact match; if `matchMode === 'all'` require `cleanTags.every(...)`, else `cleanTags.some(...)`.
  - **Keywords**: split `descriptionQuery` on whitespace; all tokens must substring-match lowercased `[title, notes, aiDescription, ocrText, githubRepo.fullName, githubRepo.description, socialPost.authorName, socialPost.bodyText]`.
  - **Colors**: `minTolerance = max(4.0, colorTolerance)`; matches if `!dominantColors.isEmpty` and any target color has CIE76 `deltaE <= minTolerance` against any dominant color.
  - **MediaKinds**: `mediaKinds.includes(asset.mediaKind)`.
  - **MinRating**: `asset.rating >= minRating`.
  - Final combine: `matchMode === 'all' ? checks.every(Boolean) : checks.some(Boolean)`.
- **Editor Sheet**: Live match count badge, Name, MatchMode segmented control, Tags (chips + input stripping `#` + top-10 quick-add chips), Keywords input, 12 preset colors (`#E11D48 #F97316 #F59E0B #10B981 #06B6D4 #3B82F6 #6366F1 #EC4899 #18181B #71717A #E4E4E7 #FFFFFF`) + custom picker + ΔE slider (`10..48`, step `2`), all 8 MediaKind chips, Min Rating `0..5`.

---

## 5. Gallery Layout Modes, Masonry Math & Top/Filter Bars

### 5.1 3 Gallery Layout Modes (`GalleryLayoutMode`)
1. **`verticalMasonry` ("纵向瀑布流")**:
   - `spacing = 12`, `horizontalPadding = 20`.
   - `usableWidth = max(240, viewportWidth - 40)`.
   - `cols = clamp(2, 10, floor((usableWidth + 12) / max(120, targetColumnWidth + 12)))`.
   - `cardWidth = (usableWidth - (cols - 1) * 12) / cols`.
   - Effective aspect ratio clamped to `[0.55, 2.15]`; place next item in shortest column (tie-break left-to-right with `-0.5px` epsilon).
   - `targetColumnWidth` range `130..420` (synced with top slider, pinch-to-zoom, and `⌘/Ctrl + wheel` anchored to cursor).
2. **`horizontalJustified` ("横向瀑布流")**:
   - `idealRowH = clamp(116, 360, targetColumnWidth * 0.92)`.
   - Effective aspect ratio clamped to `[0.48, 2.35]`.
   - Greedy row packing: when adding item causes `naturalRowW >= usableWidth`, compare `|hBefore - idealRowH|` vs `|hAfter - idealRowH|` (only take `after` if `hAfter >= idealRowH * 0.68`).
   - Clamp final `rowHeight` to `[84, idealRowH * 1.48]`. Last row is justified only if `naturalW >= usableWidth * 0.68`, otherwise rendered at `idealRowH`.
3. **`galleryFilmstrip` ("画廊视图")**:
   - Large centered preview stage: renders rich interactive cards inline for GitHub Repo, Social Post (with media extraction), Markdown/Text, 3D Model, Audio, Video, or `preview1400` image; overlay left/right chevron navigation buttons.
   - Compact info strip under stage: title, dimensions/type, `index / total`, inline 1–5 star rating, `"快速预览"` Quick Look button.
   - Bottom filmstrip (`height: 96px`): horizontal virtualized thumb strip (`thumbHeight: 68px`, `thumbWidth = clamp(46, 116, 68 * clamp(0.6, 1.75, aspectRatio))`).
   - Keyboard `←`/`→` steps selection, Cmd/Ctrl & Shift multi-select, double-click opens Quick Look, always calls `markAssetOpened(id)`.

### 5.2 Card Aspect Ratios, Badges & Interactions (`VirtualizedMasonryView`)
- **Card Effective Aspect Ratio**: `audio = 1.55`, `socialPost = natural || 1.12`, `githubRepo = 1.32`, `webBookmark = 1.25`, `swatch = 1.0`, `document = 0.84`, `model3D = natural || 1.0`, images/GIF/video = natural.
- **Top-right Media Pill Badges**: `image` = none, `animatedImage` = `GIF`, `video` = formatted `m:ss`, `audio` = `AUDIO`, `githubRepo` = `GITHUB`, `socialPost` = platform name (`X`/`THREADS`/`BLUESKY`), `webBookmark` = `WEB`, `document`/`designFile` = uppercase extension (swatch = none), `model3D` = `model3DFormat || "3D"`.
- **Card Overlays**:
  - Top-left `22×22` circular checkbox inside `32×32` hit area (visible on hover or when selected).
  - Bottom `34px` hover caption gradient (`title` + `★N` in `#F2C14E`) for visual media (image/GIF/video).
  - Cut clipboard state: card opacity `0.52` + dashed `[5, 4]` border.
- **Interactions**: Rubber-band marquee drag selection, `⌘A` select all, `⌘C` copy, `⌘X` cut, `⌘V` paste/import, `Space` Quick Look, `Esc` clear selection.

### 5.3 Top Floating Bar, Visual Filter Bar & Utility Strips (`MainWindowView`)
- **Top Floating Bar**: Search capsule + `"语义"` hybrid semantic toggle pill (triggers hybrid semantic search on Enter + shows `semanticSearchStatusBar` with candidate/source info and `"返回普通检索"`), Filter toggle (`⇧⌘S`), Sort picker (`newest`, `oldest`, `nameAsc`, `ratingDesc`, `fileSizeDesc`, `relevance`), 3-mode layout switcher, Column width slider (`130..420`), Quick Moodboard CTA, Sync Status Pill (with progress popover), Inspector toggle.
- **Visual Filter Bar**:
  - 8 MediaKind toggle chips.
  - AspectShape pills (`横图`, `竖图`, `方图`, `超宽` — thresholds: `>=2.0` ultrawide, `>=1.15` landscape, `<=0.87` portrait, else square).
  - 10 Preset Colors (`#1E2024 #5C6B73 #3D5A80 #4E7D96 #6B8E76 #D4A373 #BA6B55 #E5B243 #C8B8A6 #F0EEE9`) + custom color picker + CIELAB ΔE tolerance slider `10..55` (labels: `<=18` 精确, `<=34` 适中, `>34` 宽松).
  - Min Star Rating `1..5`, `"已保留在本地"` toggle, Clear button.
- **Contextual Strips**:
  - Folder Breadcrumbs + direct Subfolders strip + Create Subfolder popover.
  - Trash Action Bar: `"全部恢复"` (Restore All) & `"清空回收站"` (Empty Trash with confirmation).
  - Multi-Select Floating Batch Pill (when `selectedAssetIDs.size >= 2`): count, Add to Moodboard, Move to Folder, Tag, Trash, Clear.
- **Jump Anywhere Palette (`⌘J` / `Ctrl+J`, `JumpAnywhereView`)**:
  - Spotlight-style command palette with `↑`/`↓`/`Enter`/`Esc` keyboard navigation.
  - Empty query shows 4 Quick Commands (`快速生成情绪板…`, `前往收件箱清理台`, `展开 / 收起快速采集浮窗`, `导入 / 快捷采集`).
  - Non-empty query searches `moodboard`, `folder`, `tag`, and `asset` (`QuickJumpKind`, supporting zh/en/Pinyin matching).

---

## 6. Inbox Triage (`1–9` Shortcuts, Batch AI Triage & Inbox Zero)

- **Keyboard `1–9` Quick Archive**: When viewing `inbox` and no text input is focused, pressing unmodified digit `1`–`9` archives currently selected asset(s) (or the first Inbox item if none selected) into `folders[digit - 1]` with brief undo toast.
- **Inbox Triage Bar**: Displays pending Inbox count, single-asset AI 1-click suggested folder pill, `"智能分拣"` button, quick `1–9` folder chips, and 1-click Send to Moodboard menu.
- **Single-Asset Folder Suggestion (`suggestFolder`)**:
  - When TypeSafe Jev is enabled + `enableInboxSmartTriage`: invokes Jev `classifyIntoFolders`. **Crucial fix**: if Jev rejects (`recommendedFolderID === null`), respect `null` (do NOT fall back to a forced random folder guess).
  - When TypeSafe is disabled/unavailable: offline `curator.suggestFolder` (tag/keyword/color similarity).
- **Batch AI Triage (`batchTriageInbox`)**:
  - Processes up to `24` Inbox assets with `4` parallel workers (`targetLongSide: 384`) calling Jev `classifyIntoFolders` (or offline curator fallback).
  - Sorted by: has recommended folder first → `confidence` desc → `fitProbability` desc.
  - **Batch Triage Sheet**: Thumbnail, title, recommended folder badge (or "保留在收件箱"), confidence `%`, reason text, Select All / Select None toggles; rows with `recommendedFolderID != null && confidence >= 0.65` are **auto-checked** by default; `"应用已选 (N)"` executes batch folder moves.
- **Inbox Zero State**: Celebratory empty view (`InboxZeroCelebrationView`) with stepped entrance (`enterMd` + `45ms` delayed `settleStrong` icon badge) and quick CTA to browse All Items or open a Moodboard.

---

## 7. Quick Look Overlay & Inspector (`QuickLookOverlayView`, `InspectorView`)

### 7.1 Quick Look Overlay
- **Ambient Backdrop**: Light mode `rgba(21, 22, 25, 0.68)`, Dark mode `rgba(0, 0, 0, 0.76)` layered with `CharkleTheme.ambientTint(dominantHex, dark)`.
- **Choreography**: Media appears immediately; secondary chrome (toolbar, captions, arrows) fades in after **`110ms`** delay.
- **Keyboard Shortcuts**:
  - `Space` / `Esc`: Close
  - `←` / `→`: Step previous / next asset
  - `R`: Rotate `+90°`, `⇧R`: Rotate `-90°`
  - `⇧H`: Flip horizontal, `⇧V`: Flip vertical
  - `0`: Reset rotation, flips, zoom, and pan
- **Transform & Fit Math**:
  - Rotation parity when flipped: `parity = (flipH !== flipV) ? -1 : 1` so visual clockwise rotation always matches user expectation.
  - `quarterTurnFitScale`: when rotated `90°`/`270°`, auto-scale image so rotated bounding box fits inside stage without clipping.
  - Zoom: `0.5x..5.0x` (pinch / wheel / buttons `×0.8` & `×1.25`), double-click toggles `1.0x ↔ 2.0x`, drag to pan when `zoom > 1.01`.
- **Collapsible Side Panel (`292px` width)**: Toggleable right rail with segmented `"信息"` | `"类似项目"` (matches Inspector single-asset panel).

### 7.2 Inspector (`300px` Right Rail)
- **Ambient Tint**: Top `200px` subtle radial/linear ambient tint ONLY in Single Asset mode (`0.10` dark / `0.06` light opacity).
- **Single Asset Mode**: Segmented `"信息"` | `"类似项目"` (2-col similar visual/tag/color grid with match reason tooltips & drag-out).
  - Cards: Preview & Identity (inline title edit, 1–5 star rating with `microOvershoot`, Pin Offline), Quick Actions (Add to Moodboard, Move Folder, Reveal/Copy/Cut, or Trash Restore/Permanent Delete), Palette & Tags (dominant swatches: click copies HEX, right-click filters by color; **`"按主体重提"`** Jev/saliency subject palette button; AI retag button; tag chips + add input + AI suggested tags with accept / dismiss / accept-all / clear), Notes + OCR + AI Description, Media Specs (dimensions, size, hash, domain, dates), conditional GitHub Repo card (stats + open README), conditional Social Post Media Extraction card (extract single / extract all / retry failed).
- **Multi-Select Batch Mode (`>=2` selected)**: Overview + Create Moodboard CTA, Bulk Organize (Move Folder, Batch Tag, Batch AI Retag with live progress bar & Stop button, Accept/Clear AI suggestions, Batch Star Rating), Batch Pin Offline / Move to Trash.
- **Moodboard Inspector Mode**: Identity (editable title/subtitle, Set Active Board, Pin Board Offline), AI Curator Assistant (refinement prompt input + 3 quick chips: `"重新分区编排"`, `"补充同氛围图"`, `"精简不协调"` + expandable agent trace + Undo), **Candidate Swap Pool** (2-col grid up to `24` assets: click swaps into `swappingNodeID` if swap mode active, else appends to board; also draggable onto canvas), Harmonious Palette Strip (up to 7 colors + Re-extract), Quick Add Library Search (3-col grid up to 9), Export & Delivery (Figma Bridge `.charkleboard`, Figma Plugin Guide, Copy 2× PNG, Save PNG/JPG).

---

## 8. Moodboard Studio & AI Agent Harness

### 8.1 Dual Modes (`MoodboardCanvasView`, `MoodboardNodeViews`)
- **Auto Editorial Mode**: Styles `balanced` ("呼吸均衡"), `magazine` ("杂志主次", Hero weight=2 spans 2 columns), `compact` ("紧凑拼贴"). Drag-to-reorder uses Kubai 005 neighbor ripple (`amplitude = 8px`, `distance <= 5`, `delay = 24ms * n`). `"转为自由画布"` (`freezeIntoFreeform`) bakes computed frames into absolute coordinates.
- **Freeform Infinite Canvas**:
  - **5 Tools**: `select (V)`, `pan (H)`, `connector (C)`, `pen (P)`, `eraser (E)`.
  - **Camera**: Zoom `0.2x..3.0x` (button steps `×0.82` / `×1.22`, Fit-to-Canvas clamps `0.22..1.8`). Dot grid `worldStep = 28` quantized screen spacing `16..56`. Middle-mouse drag OR hold `Space` pans; quick tap `Space` on selected asset opens Quick Look.
  - **Smart Snap Guides**: Threshold `6 / zoom` world px snapping `minX`, `midX`, `maxX`, `minY`, `midY`, `maxY` against sibling nodes.

### 8.2 Node Types, Transforms, Crop, Pinpoints & Group Auto-Reflow
- **`assetRef`**: Hover controls: Hero toggle (`weight 1 ↔ 2`), Swap (`"换一张"`, sets `swappingNodeID` to highlight Candidate Pool), Lock icon, `"局部取景 · 还原"` badge when `crop != null`, Quick Look trigger.
- **`note`**: 5 calm themes:
  - `paper` (`#FFFFFF` bg / `#1D1F23` fg), `ink` (`#1D1F24` / `#F1F2F4`), `warm` (`#F7F0E4` / `#392F22`), `sage` (`#E8F0EA` / `#203227`), `slate` (`#E9EEF3` / `#1F2B36`). Font sizes: `12, 14, 16, 20`.
- **`groupFrame`**: 6 tints:
  - `neutral #7D838B`, `sand #B5956B`, `sage #6B8E76`, `slate #627A94`, `terracotta #BA6B55`, `ocean #4D7E97`.
  - Header shows enclosed item count, `"自适应排布"` auto-reflow button, tint picker dots.
  - **Live Side-Edge Auto-Reflow**: Left/right `5×34` capsule edge bars resize frame width and live-reflow enclosed nodes into masonry/grid columns inside the frame. Dragging the group moves all enclosed nodes together.
- **`paletteStrip`**: `autoSyncWithBoard` toggle, displays extracted swatches, click copies HEX.
- **Node Transforms**:
  - 4 corner resize handles using rotated-axis projection to pin the opposite corner. Min sizes: `note 140×96`, `groupFrame 180×120`, `paletteStrip 160×48`, `assetRef 84×60`. `assetRef` is aspect-locked by default (`Shift` inverts).
  - Top-center rotation knob (`22px`): `Shift` snaps `15°` increments; magnetic cardinal snap within `±3°` of `0°/±90°/180°`; double-click resets to `0°`.
  - Floating `selectedTransformBar` positioned above bottom tool dock (rotate ±90°, flip H/V, lock, bring forward/back, reset crop, delete).
- **Jev Box Node Context Actions**:
  1. **聚焦主体** (`locateRegion` subject mode) → sets non-destructive `crop`.
  2. **按描述局部取景** (`400px` prompt sheet → `locateRegion` semantic query).
  3. **按参考图匹配区域** (`480px` asset picker sheet → `locateVisualMatch`).
  4. **自动去杂边** (`detectCleanContentBounds`).
  5. **精准标注细节 (Pinpoint Callout)** (`420px` sheet): locates object box center → maps through existing crop via `crop.mappingImagePointToVisible(center)` → creates a `note` node alongside the card + `BoardConnector` with `toNormalizedPoint` rendered with halo circle (`radius = 9 * zoom`) and solid center dot (`radius = 3.6 * zoom`).
  6. **还原完整画面** (`crop = null`).
- **Ink Pen & Eraser**:
  - 6 swatches: `#D95D48 #2C3038 #3D6A99 #4D7C5F #C7933B #EFECE6`; 3 widths: `2.0 / 3.5 / 6.5`; opacity `0.92`; quadratic midpoint path smoothing.
  - Eraser hit radius: `18 / zoom` (`1.4×` for connector midpoint).

### 8.3 Moodboard Agent Harness & Generator Workbench (`MoodboardAgentHarness`, `MoodboardGeneratorSheet`)
- **Execution Phases (`MoodboardAgentPhase`)**:
  1. `planning`: Parse brief, folders, seeds, target palette, layout intent.
  2. `retrieving`: Multi-route recall (max `32` candidates). **Stage 2.5 (optional)**: when TypeSafe Jev + `enableCuratorVisualRerank` active, score top `24` candidates via Jev `Score` and blend `max(jevScore, prior * 0.35 + jevScore * 0.65)`.
  3. `inspectingVisuals`: Render numbered `#01..#32` JPEG Contact Sheets (`16` tiles per sheet) and send to Cloud Vision LLM for strict JSON curation ("宁缺毋滥" — reject off-topic candidates, emit `rejectedNote` & `visualInsights`).
  4. `verifying`: Validate grounded integer slots against `slotToAsset`, deduplicate, enforce locked/seed/excluded constraints.
  5. `repairing` (optional): 1-turn deterministic auto-repair if JSON or slot indices are invalid.
  6. `composing` (optional **Stage 3.5**): When `autoFocusDetailCrop` is checked, run Jev `locateRegion` (`targetLongSide: 640`) on up to `12` selected images to apply detail-focused non-destructive crops.
  7. `completed` (persists `visualInsights` back to asset `aiDescription`/tags in DB) OR `fallbackOffline` (strict offline score cutoff `0.34` when query/palette/seed signal exists).
- **Generator Workbench Sheet (`960×660`)**:
  - Left Studio: prompt textarea + 4 preset chips, multi-folder scope chips, 1–4 seed asset picker, 1–3 palette hexes from 10 curated swatches + tolerance slider (`12..46`), layout style (`magazine`/`balanced`/`compact`), Auto Editorial vs Freeform toggle, item count (`6`/`10`/`16`), `"包含策展说明"` checkbox, `"细节聚焦自动裁切"` (`autoFocusDetailCrop`) checkbox.
  - Right Workbench: collapsible step-by-step Agent Trace timeline, proposal summary + palette strip + `rejectedNote`, sectioned 3-col preview grid with Hero badge & hover Lock / Exclude buttons, bottom multi-turn refinement input (`refineProposal`).

---

## 9. Exact `.charkleboard` Figma Bridge ZIP & Manifest Schema

Must be 100% compatible with `Resources/FigmaPlugin/code.js` (`format: "charkle-figma-bridge"`, `version: 1`).

### 9.1 ZIP Archive Layout
```
<BoardName>.charkleboard (standard ZIP)
├── board.json
├── migration-report.json
├── tiles/
│   └── <prefix>-<x>-<y>.png        # 4096×4096 max lossless PNG tiles
└── originals/
    └── <assetID>.<ext>             # Original GIFs (for animated frames) & referenced originals
```

### 9.2 `board.json` Schema & Strict Plugin Invariants
```json
{
  "format": "charkle-figma-bridge",
  "version": 1,
  "boardId": "<UUID>",
  "name": "<title>",
  "subtitle": "<subtitle>",
  "mode": "autoEditorial | freeform",
  "darkAppearance": false,
  "exportedAt": "2026-11-23T00:00:00Z",
  "sourceOS": "Charkle Web",
  "objects": [ /* 1..10000 items, unique string id */ ],
  "connectors": [
    {
      "id": "<UUID>",
      "fromNodeID": "<UUID>",
      "fromAnchor": "auto | top | bottom | leading | trailing",
      "toNodeID": "<UUID>",
      "toAnchor": "auto | top | bottom | leading | trailing",
      "style": "curved | elbow | straight",
      "colorHex": "#5C6672",
      "dashed": false,
      "label": null
    }
  ],
  "inkStrokes": [
    {
      "id": "<UUID>",
      "points": [{ "x": 10.5, "y": 20.0 }],
      "colorHex": "#D95D48",
      "lineWidth": 3.5,
      "opacity": 0.92
    }
  ],
  "originals": [
    { "id": "<UUID>", "name": "file.gif", "file": "originals/<UUID>.gif", "sha256": "<64-lower-hex>", "bytes": 12345 }
  ],
  "report": {
    "objectCount": 10,
    "imageCount": 6,
    "noteCount": 1,
    "groupCount": 2,
    "paletteCount": 1,
    "connectorCount": 1,
    "strokeCount": 0,
    "reviewCount": 0,
    "warnings": [{ "id": "<UUID>", "name": "...", "issues": ["..."] }]
  }
}
```
- **Every `object` requires**:
  - `id`: unique non-empty string
  - `kind`: `"image" | "note" | "groupFrame" | "paletteStrip" | "unsupported"`
  - `name`: string
  - `geometry`: `{ x, y, width, height, angle, flipX, flipY }` where `0 < width, height <= 10_000_000`
  - `locked`: boolean (optional), `cornerRadius`: number (images use `12`), `warnings`: `string[]`
- **Kind-specific payloads**:
  - `"image"`:
    ```json
    "image": {
      "pixelWidth": 2400,
      "pixelHeight": 1600,
      "tiles": [
        { "file": "tiles/<id>-0-0.png", "x": 0, "y": 0, "width": 2400, "height": 1600, "sha256": "<64-lowercase-hex>" }
      ],
      "animated": false,
      "animation": { "file": "originals/<assetID>.gif", "sha256": "<64-lowercase-hex>" } // only when animated: true
    }
    ```
    **Mandatory Tile Invariants checked by `code.js`**:
    - `x % 4096 === 0` and `y % 4096 === 0`
    - `width === Math.min(4096, pixelWidth - x)` and `height === Math.min(4096, pixelHeight - y)`
    - `tiles.length === Math.ceil(pixelWidth / 4096) * Math.ceil(pixelHeight / 4096)`
    - Every `sha256` MUST be exact 64-char lowercase hex matching the ZIP entry bytes.
    - If `node.crop` is set on `assetRef`, bake the crop into the exported raster/tiles before tiling!
  - `"note"`: `note: { title, text, style, fontSize, backgroundHex, foregroundHex, borderHex }`.
  - `"groupFrame"`: `group: { title, tint, accentHex }`.
  - `"paletteStrip"`: `palette: { swatches: [{ hex, isLight }] }`. When `includePaletteStrip` is enabled and no strip exists, synthesize top header `"board-palette-header"` at `y = minY - 54 - 24`, height `54`.
- `migration-report.json`: standalone copy of `report` object.

---

## 10. Cloud AI Usage Tracking (`CloudAIUsageTracker`)

- **Separated Buckets**: Track two independent `CloudAIUsageBucket` instances inside `CloudAIUsageSummary`:
  - `standard`: Gemini / OpenAI / Anthropic / ChatGPT subscription calls
  - `jev`: TypeSafe System One (Jev) calls
  - Plus combined top-level totals (`todayRequests`, `todayTotalTokens`, `totalRequests`, `totalTokens`, etc.) synchronized on every record/reset.
- **Bucket Fields**:
  ```ts
  interface CloudAIUsageBucket {
    dayKey: string; // local YYYY-MM-DD; auto-zeros today* fields on date change
    todayRequests: number;
    todayInputTokens: number;
    todayOutputTokens: number;
    todayTotalTokens: number;
    totalRequests: number;
    totalInputTokens: number;
    totalOutputTokens: number;
    totalTokens: number;
    lastProviderLabel?: string;
    lastModel?: string;
    lastUsedAt?: string;
    lastCallTokens?: number;
  }
  ```
- **Token Formatter (`formatTokenCount`)**: `>= 1_000_000` → `"%.2fM"`, `>= 10_000` → `"%.1fK"`, `>= 1_000` → `"%.2fK"`, else exact integer string.
- **Reset Scopes**: `all` | `standard` | `jev`.

---

## 11. TypeSafe System One (Jev) Protocol, Thresholds & Fallbacks

### 11.1 Endpoints & Wire Format (`TypeSafeSystemOneClient`)
- Base URL default: `https://api.typesafe.ai` (auto-append `/v1` when URL path is empty; allow `http://` ONLY for `localhost`, `127.0.0.1`, `::1`).
- Endpoints: `GET <base>/v1/models` and `POST <base>/v1/systemone`.
- Auth header: `Authorization: Bearer <apiKey>`.
- **Mandatory Header**: Send `TypeSafe-Danger-Zone-Images: true` whenever images or `box` questions are included.
- **Multipart Upload Rules (when images attached)**:
  - **Part 1 MUST be `name="request"` with `Content-Type: application/json`** containing `{ model, state, questions, assets: { [refKey]: { type: "image", part: partName } } }`.
  - Subsequent parts carry binary image bytes: `name="<partName>"; filename="<partName>.<jpg|png>"`.
- **Image Preprocessing (`TypeSafeImagePreparer`)**:
  - Upright EXIF-normalized JPEG (quality `0.86`).
  - Strictly enforce **`280 <= width, height <= 1568`**.
  - For extreme aspect ratios (`> 5.6:1`) where scaling long side to `1568` makes short side `< 280`, pad onto `#F5F5F5` canvas so both edges satisfy `[280, 1568]`.
- **4 Primitives**:
  - `noul` → `{ probability: number }`
  - `box` → `{ box: { top, bottom, left, right }, confidence?: number }` (normalized `[0, 1]`, top-left origin)
  - `choice` → `{ choice: string, confidence: number, probabilities: Record<string, number> }`
  - `score` → `{ score: 0|1|2|3, confidence: number, probabilities: Record<string, number>, legend }` → normalized `score / 3.0`
- Record every Jev response's `usage.input_tokens` & `usage.output_tokens` into `CloudAIUsageStore` bucket `.jev`.

### 11.2 Config Defaults, Thresholds & Offline Fallbacks (`VisualGroundingEngine`)
- **Defaults (`TypeSafeExperimentalConfig`)**: `enabled = false`, `baseURL = "https://api.typesafe.ai"`, `model = "jev-latest"`, `minConfidence = 0.60` (UI slider `0.30..0.90`), `lowConfidencePadding = 0.05`, `minPresenceProbability = 0.45`, all 7 feature toggles (`enableMoodboardFocusCrop`, `enableAutoCleanCrop`, `enableSubjectPalette`, `enablePinpointAnnotations`, `enableSemanticSearch`, `enableInboxSmartTriage`, `enableCuratorVisualRerank`) default `true`.
- **Grounding Operations**:
  1. `locateRegion(subject | query)`: companion `noul("present")` + `box("region")`. `found = presence >= clamp(0.05, 0.95, minPresenceProbability)`. If `(confidence == null || confidence < minConfidence) && lowConfidencePadding > 0`, pad box outward by `lowConfidencePadding`. **Fallback**: local saliency/subject detector + `0.04` pad (subject mode only; text query requires Jev).
  2. `locateVisualMatch(target, reference)`: 2 images (`target_image`, `reference_image`), `noul` + `box`. Requires Jev.
  3. `detectCleanContentBounds`: `noul("has_noise")` (`>= clamp(0.35, 0.90, minPresenceProbability)`) + `box("core_content")`, low-conf pad `min(0.03, lowConfidencePadding)`, requires `crop.isMeaningfulSubregion` (`w >= 0.04 && h >= 0.04 && area < 0.96`). **Fallback**: local saliency + `0.03` pad.
  4. `extractSubjectPalette`: `locateRegion` → CIELAB k-means (`count = 6`) on cropped pixels.
  5. `scoreCandidatesForQuery`: batches of `4` (`maxConcurrency = 3`), 4-level rubric `0..3`, returns `score / 3.0`.
  6. `classifyIntoFolders`: up to `32` folders (`f_0..f_31` with up to 6 sample tags each), `noul("fits_any")` + `choice("folder")`. Returns `recommendedFolderID = null` if `fitProbability < clamp(0.35, 0.85, minPresenceProbability)`.
- **Hybrid Semantic Search Fusion (`LiveCharkleEngine.semanticSearch`)**:
  - Signal A (`t`): FTS5 + Pinyin (`searchRanks`, split up to 8 tokens).
  - Signal B (`e`): Cloud Embedding cosine `> 0.22`, mapped `clamp(0, 1, (cos - 0.22) / 0.63)`.
  - Signal C (`j`): TypeSafe Jev `Score` on up to `24` visual candidates (top 16 from A+B + newest untagged/uncaptioned visual items, `targetLongSide: 384`, `batchSize: 4`, `maxConcurrency: 3`).
  - Fusion:
    - If Jev scored: `max(j, j * 0.72 + max(t, e) * 0.28)`
    - Else if `e >= 0.28`: `max(e, e * 0.75 + t * 0.25)`
    - Else: `t * 0.85`
  - Threshold cutoff: `0.32` if Jev or Cloud Embedding ran, else `0.05`.

---

## 12. All 6 Settings Tabs (`SettingsView`)

1. **`cloudSync` ("存储与同步")**: Storage backend picker (Local / Google Drive OAuth + shared folder URL/ID + Shared With Me picker / WebDAV), live sync status & progress card, Lossless Storage Migration flow, advanced sync controls.
2. **`intelligence` ("智能与搜索")**:
   - 4 offline capability tiles (CIELAB Color, Local OCR/FTS5+Pinyin, Visual Similarity, Offline Curator).
   - Cloud AI provider selector: `disabled` | `chatGPTSubscription` (or Web OAuth/API) | `gemini` (`gemini-2.5-flash` / `gemini-embedding-001`) | `openAICompatible` with 3 endpoint formats: `openAIChatCompletions` (`gpt-4.1-mini`), `anthropicMessages` (`claude-sonnet-4-5`, no embeddings), `openAIResponses` (`gpt-4.1-mini`).
   - Toggles: `autoAnalyzeOnImport`, `sendThumbnailsToCloud`.
   - Separated **Cloud AI Usage Cards**: `standard` bucket card + `jev` bucket card with today/total requests & tokens + per-bucket Reset buttons.
   - **TypeSafe System One (Jev) Experimental Card**: Enable toggle, Base URL, API key, Model picker (fetched from `/v1/models`), Test Connection, Confidence slider (`0.30..0.90`), and all 7 feature toggles.
3. **`appearance` ("外观与图标")**: Theme selector (System / Light / Dark) + Light/Dark Brand App Icon / Favicon switcher.
4. **`externalAgent` ("外部 Agent 与 MCP")**: Enable toggle, Access Level (`readOnly` vs `readWriteOrganize`), safety callout ("永远无法永久删除素材"), copyable Claude Code & generic MCP server JSON config snippets (HTTP/SSE/stdio endpoint for Web), CLI helper snippet, 4 capability summary tiles.
5. **`storage` ("缓存空间")**: 3-segment storage breakdown bar (`#4E7D96` thumbnails, `#D4A373` temp cached originals, `#6B8E76` pinned offline originals), budget slider `2..100 GB`, `"立即清理缓存"` evict button.
6. **`captureShortcuts` ("采集与快捷键")**: Quick Drop Shelf enable/pin preferences, preview shelf trigger button, complete 13-shortcut reference table (`⌘J`, `⌘\`, `⇧⌘S`, `Space`, `1–9`, `R`/`⇧R`/`⇧H`/`⇧V`/`0`, `V/H/C/P/E`, `⌘A/C/X/V`, etc.).

---

## 13. All 14 MCP Tools & JSON-RPC 2.0 Protocol (`CharkleExternalAgentService`)

- **JSON-RPC 2.0 Methods**: `initialize` (`protocolVersion: "2025-03-26"`, `serverInfo: { name: "charkle", version: "1.0.0" }`), `notifications/initialized`, `ping`, `tools/list`, `tools/call`, `resources/list`, `resources/read`.
- **MCP Resources**: `charkle://library/overview` and `charkle://boards` (`application/json`).
- **Policy Enforcement**:
  - Disabled → reject all reads & writes.
  - `readOnly` → allow the 8 Read tools & Resources; block the 6 Write tools with localized error message.
  - `readWriteOrganize` → allow all 14 tools; **NEVER** expose permanent delete (`trash_assets` is soft-trash only; `destructiveHint: false` on all 14 tools).

| # | Tool Name | Access | Required Args | Key Optional Args | Return Shape |
|---|---|---|---|---|---|
| 1 | `library_overview` | Read | — | — | `{ totalAssets, inboxCount, boardCount, accessLevel, canWrite, mediaKindCounts, folders[{id,name,path,assetCount}], topTags[40]{name,count} }` |
| 2 | `search_assets` | Read | — | `query, folder_id, folder_path, tags[], color_hex, color_tolerance(28), min_rating, only_inbox, only_untagged, media_kinds[], limit(1..100, def 30)` | `{ totalMatched, returned, assets[] }` |
| 3 | `list_inbox` | Read | — | `limit(1..100, def 40)` | `{ inboxTotal, returned, assets[] }` |
| 4 | `get_asset` | Read | `asset_id` | — | Full asset summary + `ocrText, suggestedTags, sourceDomain, fileSizeBytes, pixelWidth, pixelHeight, thumbnailPath, localOriginalPath, isTrashed` |
| 5 | `render_contact_sheet` | Read | — | `asset_ids[<=16], query, folder_path, only_inbox, only_untagged, color_hex, limit(1..16, def 16), output_path` | Multimodal: `[image/jpeg, json { sheetWidth, sheetHeight, slotCount, slots[{slot, badge "#01", assetID, title, folderPath, tags, dominantColors[4], aiDescription}], savedPath? }]` |
| 6 | `list_boards` | Read | — | — | `{ count, boards[{id, title, subtitle, mode, itemCount, paletteHexes, pinnedOffline, updatedAt}] }` |
| 7 | `get_board_context` | Read | — | `board_id` or `title` | `{ id, title, subtitle, mode, itemCount, palette[{hex, proportion, lab}], notes[], sections[], assets[{...summary, nodeID, weight, isHero, isLocked, localOriginalPath?}] }` |
| 8 | `export_board_image` | Read | — | `board_id` or `title`, `width(1440)`, `dark_appearance(false)`, `output_path` | Multimodal: `[image/png, json { boardID, title, itemCount, bytes, mimeType, savedPath? }]` |
| 9 | `organize_assets` | Write | `asset_ids[]` | `folder_id, folder_path, move_to_inbox, add_tags[], remove_tags[], rating(0..5), title, notes, ai_description, accept_suggested_tags` | `{ updatedCount, assetIDs[] }` |
| 10 | `create_folder` | Write | `name` | `parent_id, parent_path` | `{ id, name, parentID }` |
| 11 | `ingest_asset` | Write | one of `file_path` \| `web_url` \| `text` | `title, folder_path, folder_id, tags[]` | `{ importedCount, assets[] }` |
| 12 | `compose_moodboard` | Write | Mode A: `sections[]` or `asset_ids[]`; Mode B: `prompt` | `title, subtitle, curator_note, layout_style(magazine\|balanced\|compact), use_freeform, hero_asset_ids[], folder_path, preferred_count(2..24, def 12)` | Mode A: `{ boardID, title, subtitle, itemCount, paletteHexes }`; Mode B adds `usedCloudAI, curatedSummary` |
| 13 | `patch_moodboard` | Write | `board_id` or `title` | `new_title, subtitle, add_asset_ids[], remove_asset_ids[]` (respects `isLocked`!), `add_note, note_title` | `{ boardID, title, itemCount, paletteHexes }` (auto-recomputes palette & synced paletteStrip nodes) |
| 14 | `trash_assets` | Write | `asset_ids[]` | `trashed(def true)` | `{ updatedCount, trashed, note: "Soft Trash only..." }` |

---

## 14. Notch Shelf → Web Quick Drop Shelf (`NotchShelfView`, `NotchShelfState`)

Mirror macOS Notch Shelf as a floating/dockable **Web Quick Drop Shelf** drawer/pill:
- **Compact Mode**:
  - Top wing bar: Charkle mark, Pin Open toggle, Jump to Main Window, Close.
  - Quick capture row: Paste from Clipboard (`⌘V`), URL Quick Capture (auto-detects X/Threads/Bluesky/GitHub URLs), File Picker.
  - **3-Way Capture Target Segmented Pill**: `inbox` (收件箱) | `folder` (with inline folder dropdown) | `activeMoodboard` (shows green status dot + active board title).
  - **Drop Well (`52px` height)**: 5 explicit states — (1) Idle drop/paste prompt, (2) Clipboard social/GitHub URL 1-click quick-save banner, (3) Drag-over blue highlight (`#3B82F6`) showing file count & destination hint, (4) Processing spinner, (5) Green success confirmation banner.
  - **Recent Activity Filmstrip**: Ranked by `recentActivityDate = max(createdAt, lastOpenedAt)` (both recently saved AND recently opened!), `24` cards (`96×82px`) with hover Copy, Quick Look, and drag-out + `"全部 (N)"` button to expand.
- **Expanded Full-Waterfall Mode**:
  - Header with search pill, live selection count pill, `"收起"` collapse button.
  - Embedded dark (`#000000` ground) `VirtualizedMasonryView` (`targetColumnWidth: 158`) with marquee multi-select, right-click actions, and drag-out to Moodboard/Folders.

---

## 15. Design System Tokens & Sample Library Seeder

### 15.1 Color Surfaces & Radii (`CharkleTheme`)
| Token | Light Mode | Dark Mode |
|---|---|---|
| `galleryGround` | `#F6F6F5` | `#141517` |
| `surfaceElevated` | `#FFFFFF` | `#1E2025` |
| `surfaceSubtle` | `#EDEDE9` | `#24272C` |
| `inspectorBg` | `#F1F0EC` | `#131519` |
| `inspectorField` | `#F6F5F1` | `#16181D` |
| `hairline` | `rgba(0, 0, 0, 0.08)` | `rgba(255, 255, 255, 0.09)` |
| `ambientTint` opacity | `0.06` | `0.10` |

- **Concentric 4pt Radii**: `dockOuter = 20px` / `dockInner = 12px` (`8px` pad); `cardOuter = 12px` / `innerBadge = 6px` (`6px` pad); `settingsOuter = 14px` / `settingsInner = 8px`; `popoverOuter = 16px` / `popoverInner = 10px`; `chip = 8px`.

### 15.2 Motion Curves (`CharkleMotion` — Kubai Tip 011)
| Token | Curve | Duration | Usage |
|---|---|---|---|
| `enterSm` / `enterMd` / `enterLg` | `cubic-bezier(0, 0, 0.58, 1)` | `180ms` / `260ms` / `360ms` | Entrances by footprint |
| `settleStrong` | `cubic-bezier(0.22, 1, 0.36, 1)` | `240ms` | Hero settle & Inbox Zero badge |
| `exitSm` / `exitMd` | `cubic-bezier(0.42, 0, 1, 1)` | `140ms` / `190ms` | Exits |
| `moveOnScreen` | `cubic-bezier(0.42, 0, 0.58, 1)` | `260ms` | On-screen repositioning |
| `microOvershoot` | `cubic-bezier(0.34, 1.56, 0.64, 1)` | `280ms` | Small controls `<= 64px` ONLY (stars, pins, checkboxes) |
| `hoverPress` | ease-out | `120ms` | Button active press: `scale(0.97)` + `opacity: 0.88` |
| `popoverEnter` / `popoverExit` | ease-out / ease-in | `160ms` / `110ms` | Popovers & menus |
| `reducedMotionFade` | linear | `150ms` | `prefers-reduced-motion: reduce` fallback |

### 15.3 Duotone SVG Icon Recoloring (`CharkleIcon`)
- Base SVG palette uses `#445C94` (accent stroke/fill) and `#B4BED4` (muted body fill).
- Dynamic recoloring:
  - Light inactive: `#445C94` / `#B4BED4`
  - Light active: `#2A60E0` / `#AFC6F7`
  - Dark inactive: `#8EA8E8` / `#3D4E75`
  - Dark active: `#9BB7FF` / `#3E5998`
- Custom folder tint (`colorHex`, exact `deriveDuotonePair` formula):
  - **Light mode**: `primary = #RRGGBB`; `secondary = rgb * 0.50 + 255 * 0.50` (50% tint over `#FFFFFF`).
  - **Dark mode**: `primary = min(255, rgb * 0.88 + 255 * 0.12)`; `secondary = (r * 0.45 + 34 * 0.55, g * 0.45 + 36 * 0.55, b * 0.45 + 42 * 0.55)` (45% color over `#22242A`).

### 15.4 Sample Library Seeder (`SampleLibrarySeeder`)
- First-run optional demo seed creates **10** curated vector/editorial artworks across 4 folders (`Architecture`, `Editorial`, `Typography`, `UI Inspiration`) + **2** Inbox items (`Terracotta Studio`, `Herbarium`) + **1** sample Moodboard `"光、纸与泥 · Light, Paper & Clay"` referencing indices `[1, 2, 4, 7, 8, 9]`.
