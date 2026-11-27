use std::collections::BTreeMap;

use charkle_core::db::LibraryDatabase;
use charkle_core::engine::LiveCharkleEngine;
use charkle_core::media::{MediaArtwork, VideoPlatformResolver, VideoStreamPlaybackPlan};
use charkle_core::models::core::{
    MediaKind, SocialMediaAttachment, SocialMediaAttachmentKind, WebPageRichMetadata,
};
use charkle_core::models::media::{CaptureInput, ThumbnailTier};
use charkle_core::wire::swift_codec::format_swift_uuid;
use image::{DynamicImage, Rgba, RgbaImage};
use tempfile::tempdir;
use url::Url;

fn solid_jpeg_bytes(width: u32, height: u32, rgb: [u8; 3]) -> Vec<u8> {
    let img = DynamicImage::ImageRgba8(RgbaImage::from_pixel(
        width,
        height,
        Rgba([rgb[0], rgb[1], rgb[2], 255]),
    ));
    MediaArtwork::encode_jpeg(&img, 90).expect("encode jpeg")
}

#[test]
fn video_bookmark_embed_players_and_html_contracts() {
    // 1. YouTube embed player includes valid origin + strict-origin-when-cross-origin Referer (avoids Error 153)
    let yt_url = Url::parse("https://www.youtube.com/watch?v=dQw4w9WgXcQ").unwrap();
    let yt_embed =
        VideoPlatformResolver::embed_player(&yt_url, None, None).expect("YouTube embed player");
    assert!(yt_embed.url.contains("youtube.com/embed/dQw4w9WgXcQ"));
    assert!(yt_embed.url.contains("origin=https://charkle.app"));
    assert!(yt_embed
        .embed_html
        .contains("strict-origin-when-cross-origin"));
    assert!(yt_embed.embed_html.contains("<iframe"));
    let (rendered_html, base_url) =
        VideoPlatformResolver::embed_html(&yt_embed.url, &yt_embed.referer);
    assert!(base_url.starts_with("https://"));
    assert!(rendered_html.contains("strict-origin-when-cross-origin"));
    assert!(rendered_html.contains("<iframe"));

    // 2. Bilibili embed player preserves bvid, cid, and page with bilibili.com Referer
    let bili_url = Url::parse("https://www.bilibili.com/video/BV1xx411c7mD?p=2").unwrap();
    let bili_embed = VideoPlatformResolver::embed_player(&bili_url, None, Some(987_654))
        .expect("Bilibili embed player");
    assert!(bili_embed.url.contains("player.bilibili.com/player.html"));
    assert!(bili_embed.url.contains("bvid=BV1xx411c7mD"));
    assert!(bili_embed.url.contains("cid=987654"));
    assert!(bili_embed.url.contains("page=2"));
    assert!(bili_embed.referer.contains("bilibili.com"));

    // 3. Generic video platforms (Vimeo, Dailymotion) and direct stream URL classifier
    let vimeo_url = Url::parse("https://vimeo.com/123456789").unwrap();
    let vimeo_embed =
        VideoPlatformResolver::embed_player(&vimeo_url, None, None).expect("Vimeo embed player");
    assert!(vimeo_embed.url.contains("player.vimeo.com/video/123456789"));

    let dm_url = Url::parse("https://www.dailymotion.com/video/x8abcde").unwrap();
    let dm_embed =
        VideoPlatformResolver::embed_player(&dm_url, None, None).expect("Dailymotion embed player");
    assert!(dm_embed
        .url
        .contains("geo.dailymotion.com/player.html?video=x8abcde"));

    assert!(VideoPlatformResolver::looks_like_direct_video_stream_url(
        &Url::parse("https://cdn.example.com/reel.mp4").unwrap()
    ));
    assert!(VideoPlatformResolver::looks_like_direct_video_stream_url(
        &Url::parse("https://cdn.example.com/master.m3u8?token=1").unwrap()
    ));
    assert!(!VideoPlatformResolver::looks_like_direct_video_stream_url(
        &yt_url
    ));

    // SSRF guard rejects loopback / private IP embed targets
    let local_url = Url::parse("http://127.0.0.1:41937/embed/evil").unwrap();
    assert!(VideoPlatformResolver::embed_player(&local_url, None, None).is_none());

    // Timestamp formatting parity
    assert_eq!(VideoPlatformResolver::format_video_timestamp(84.0), "01:24");
    assert_eq!(
        VideoPlatformResolver::format_video_timestamp(3725.0),
        "1:02:05"
    );
    assert_eq!(VideoPlatformResolver::format_video_timestamp(-5.0), "00:00");
}

#[tokio::test]
async fn web_page_playback_plan_discovers_direct_streams_and_embed_fallback() {
    let canonical = Url::parse("https://vimeo.com/987654321").unwrap();
    let web = WebPageRichMetadata {
        site_name: Some("Vimeo".to_string()),
        author_name: Some("Motion Lab".to_string()),
        published_at_text: None,
        summary: Some("Demo reel".to_string()),
        attachments: vec![
            SocialMediaAttachment::new(
                SocialMediaAttachmentKind::Video,
                "https://cdn.example.com/demo/reel.mp4?token=abc",
                Some("https://cdn.example.com/demo/poster.jpg".to_string()),
            ),
            // Unsafe localhost stream must be filtered out
            SocialMediaAttachment::new(
                SocialMediaAttachmentKind::Video,
                "http://127.0.0.1:9000/internal.mp4",
                None,
            ),
        ],
        has_video: true,
        duration_seconds: Some(95.0),
        canonical_url: Some(canonical.to_string()),
    };

    let plan: VideoStreamPlaybackPlan =
        VideoPlatformResolver::resolve_web_page_playback_plan(&web, Some(&canonical)).await;
    assert!(plan.has_playable_source());
    assert_eq!(plan.direct_streams.len(), 1);
    assert_eq!(
        plan.direct_streams[0].url,
        "https://cdn.example.com/demo/reel.mp4?token=abc"
    );
    assert!(!plan.direct_streams[0].is_hls);
    assert_eq!(
        plan.direct_streams[0]
            .http_headers
            .get("Referer")
            .map(String::as_str),
        Some("https://vimeo.com/987654321")
    );
    assert!(plan
        .embed_player
        .as_ref()
        .is_some_and(|e| e.url.contains("player.vimeo.com/video/987654321")));
}

#[tokio::test]
async fn update_asset_cover_image_regenerates_thumbnails_colors_dimensions_and_sync_projection() {
    let tmp = tempdir().unwrap();
    let engine = LiveCharkleEngine::open(tmp.path()).unwrap();
    let db = LibraryDatabase::open(&tmp.path().join("Library.sqlite3")).unwrap();

    // 1. Seed a blue swatch asset (simulating a bookmark/cover update)
    let imported = engine
        .ingest(
            vec![CaptureInput::ColorSwatch {
                hex: "#1A4FD6".to_string(),
                title: Some("ClipCoverSeed".to_string()),
            }],
            None,
            None,
        )
        .await
        .unwrap();
    let asset = imported.into_iter().next().unwrap();

    // Clear thumbnail projection so we can assert update_asset_cover_image re-marks it
    let id_key = format_swift_uuid(&asset.id);
    db.set_state::<BTreeMap<String, String>>("projection.thumbnails", None)
        .unwrap();

    // Replace cover with a crisp 1280x720 solid crimson frame
    let crimson_jpeg = solid_jpeg_bytes(1280, 720, [230, 42, 42]);
    let updated = engine
        .update_asset_cover_image(asset.id, &crimson_jpeg)
        .unwrap();

    assert_eq!(updated.id, asset.id);
    assert_eq!(updated.pixel_width, 1280);
    assert_eq!(updated.pixel_height, 720);
    let top_hex = updated
        .dominant_colors
        .first()
        .map(|c| c.hex.to_ascii_uppercase())
        .unwrap_or_default();
    assert!(
        top_hex.starts_with("#E") || top_hex.starts_with("#D") || top_hex.starts_with("#F"),
        "expected crimson dominant color, got {top_hex}"
    );
    assert!(engine
        .cached_thumbnail_path(asset.id, ThumbnailTier::Grid520)
        .is_some());
    assert!(engine
        .cached_thumbnail_path(asset.id, ThumbnailTier::Preview1400)
        .is_some());

    // Thumbnail sync projection must be marked for cross-platform `/.charkle/` propagation
    let dirty_thumbs: BTreeMap<String, String> = db
        .state("projection.thumbnails")
        .unwrap()
        .unwrap_or_default();
    assert!(
        dirty_thumbs.contains_key(&id_key),
        "expected thumbnails projection dirty for {id_key}"
    );

    // 2. Local `.video` asset preserves its original native dimensions (e.g. 1920x1080) even when
    //    updated from a smaller 640x360 captured frame
    let video_path = tmp.path().join("demo.mp4");
    std::fs::write(&video_path, b"not-a-real-mp4-header-placeholder").unwrap();
    let vid_imported = engine
        .ingest(vec![CaptureInput::FilePath(video_path)], None, None)
        .await
        .unwrap();
    let mut vid = vid_imported.into_iter().next().unwrap();
    assert_eq!(vid.media_kind, MediaKind::Video);
    vid.pixel_width = 1920;
    vid.pixel_height = 1080;
    db.put_asset(&vid).unwrap();

    let small_emerald = solid_jpeg_bytes(640, 360, [24, 185, 96]);
    let vid_updated = engine
        .update_asset_cover_image(vid.id, &small_emerald)
        .unwrap();
    assert_eq!(vid_updated.pixel_width, 1920);
    assert_eq!(vid_updated.pixel_height, 1080);
    let vid_top_hex = vid_updated
        .dominant_colors
        .first()
        .map(|c| c.hex.to_ascii_uppercase())
        .unwrap_or_default();
    assert!(
        vid_top_hex.starts_with("#1") || vid_top_hex.starts_with("#2"),
        "expected emerald dominant color, got {vid_top_hex}"
    );

    // 3. Reject empty or corrupt payloads gracefully
    assert!(engine.update_asset_cover_image(asset.id, &[]).is_err());
    assert!(engine
        .update_asset_cover_image(asset.id, b"not-an-image")
        .is_err());
}
