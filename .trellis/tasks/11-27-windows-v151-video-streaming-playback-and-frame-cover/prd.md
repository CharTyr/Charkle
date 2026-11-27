# Windows Parity Handoff (v1.5.1): Zero-Download Inline Video Streaming Playback & Video Frame-to-Cover Selection

## Scope
Mirror the macOS & iOS `v1.5.1` video preview upgrades inside `windows/` (`windows/crates/charkle-core`, `windows/src-tauri`, `windows/ui`) without touching macOS, iOS, or Android files.

---

## 1. Zero-Download Inline Streaming Playback in Quick Look

Reference implementation: `Sources/CharkleCore/Media/VideoPlatformResolver.swift` (`VideoStreamPlaybackPlan`, `resolvePlaybackPlan`, `resolveWebPagePlaybackPlan`, `embedPlayer(for:)`, `embedHTML(for:)`), `Sources/CharkleApp/Views/QuickLookRichViewers.swift` (`QuickLookStreamingVideoView`), `Sources/CharkleApp/Views/QuickLookOverlayView.swift`.

### Requirements
- **Default bookmarking stays 100% zero-download**: only link metadata, 16:9 cover, duration, and video summary/chapters are stored on bookmark.
- **Preview-time streaming resolution (with ~120 ms debounce)** so rapid keyboard navigation does not waste network calls:
  1. **Tier 1 (Native `<video>` Direct Stream)**:
     - **Bilibili**: resolve progressive HTML5 MP4 stream via `x/player/wbi/playurl` (`fnval=1&platform=html5&high_quality=1`) and proxy byte-range requests via local Tauri stream proxy with `Referer: https://www.bilibili.com/video/<bvid>` + desktop `User-Agent`.
     - **YouTube**: probe InnerTube `hlsManifestUrl` (`.m3u8`) and progressive muxed MP4 `formats`, plus optional zero-download `yt-dlp -g` lookup when `yt-dlp` is installed on `PATH`.
     - **Generic video webpages (`WebPageRichMetadata.hasVideo` / `.video` attachments)**: stream direct `.mp4` / `.m3u8` / `.mov` / `.webm` URLs with page `Referer`.
  2. **Tier 2 (Official Embed Player Automatic Fallback)**:
     - Automatically fall back to an embedded player whenever direct streams are unavailable or fail (`error` event):
       - **YouTube**: `https://www.youtube.com/embed/<videoID>?autoplay=1&playsinline=1&rel=0&modestbranding=1&origin=https://charkle.app` with `<meta name="referrer" content="strict-origin-when-cross-origin">` and `referrerpolicy="strict-origin-when-cross-origin"` to avoid YouTube Error 153.
       - **Bilibili**: `https://player.bilibili.com/player.html?bvid=<bvid>&cid=<cid>&page=<p>&autoplay=1&danmaku=0&high_quality=1` with `https://www.bilibili.com/` referer.
       - **Vimeo / Dailymotion / generic `/embed/`**: `player.vimeo.com/video/<id>` / `geo.dailymotion.com/player.html?video=<id>`.
     - When both direct stream and embed player exist, expose a compact top-right **"切换网页播放器 / 切换原生流式"** toggle.
     - On Quick Look close or asset switch, immediately pause/unload `<video>` and clear iframe `src` (`0%` idle CPU).
- Retain the `"视频摘要"` card, chapter outline, and explicit **"保存视频为独立素材"** on-demand download CTA right alongside the streaming stage.

---

## 2. Select Any Video Frame as Asset Cover ("设当前帧为封面")

Reference implementation: `Sources/CharkleCore/LiveCharkleEngine.swift` (`updateAssetCoverImage(id:imageData:)`), `Sources/CharkleCore/Media/VideoPlatformResolver.swift` (`VideoFrameCapture`), `Sources/CharkleApp/Views/QuickLookOverlayView.swift`, `Sources/CharkleApp/Views/QuickLookRichViewers.swift`.

### Requirements
- **Rust Core + Tauri Command (`update_asset_cover_image(asset_id, image_bytes)`)**:
  - Decode JPEG/PNG bytes, atomically regenerate `grid520` (720px Retina) & `preview1400` (1400px) thumbnails, and re-extract `dominantColors` from the chosen frame.
  - Preserve native `pixelWidth`/`pixelHeight` for local `.video` assets when already known (`> 0`), while updating dimensions for `.webBookmark` cover frames.
  - Persist updated asset metadata locally, bump `updatedAt`, emit `.upsertAsset`, and mark the `thumbnails` sync projection so the new cover propagates across macOS, iOS, and Windows via `/.charkle/`.
- **Quick Look UI ("设当前帧为封面")**:
  - Available for BOTH **local `.video` assets** (bottom HUD) and **streaming video bookmarks / social video posts** (player top-right action pill):
    - In `<video>` mode: draw the current decoded frame onto an offscreen `<canvas>` (`toBlob('image/jpeg', 0.9)`) and capture the playhead timestamp (`MM:SS`).
    - In embedded iframe mode: capture the visible player region cleanly (WebView2 `CapturePreview` or equivalent region snapshot) so cover selection works even in fallback embed mode.
  - Immediately invalidate thumbnail caches in React/Tauri so masonry waterfall tiles, filmstrip, and Inspector reflect the new cover frame with zero reload delay, and display a confirmation toast (e.g. `"已将 01:24 画面设为素材封面"`).

---

## 3. Release Coordination (`v1.5.1`)
- Bump Windows versions (`windows/Cargo.toml`, `windows/src-tauri/tauri.conf.json`, `windows/ui/package.json`, updater fallback/tests) to `1.5.1`.
- Target shared GitHub Release `v1.5.1`: upload `Charkle_1.5.1_x64-setup.exe` and replace **only** the `## Windows（v1.5.1）` placeholder section, preserving macOS and iOS release notes verbatim.
