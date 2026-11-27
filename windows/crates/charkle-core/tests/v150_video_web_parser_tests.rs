//! Unit tests for Charkle v1.5.0 video bookmarking (YouTube/Bilibili),
//! 5-layer universal web bookmark parser, and extractable link media detection.

use charkle_core::media::{
    MediaArtwork, SocialPostURLParser, VideoPlatformReference, VideoPlatformResolver,
    VideoPlatformURLParser, WebBookmarkResolver, XPostURLParser,
};
use charkle_core::models::core::{
    AssetRecord, AssetRichMetadata, MediaKind, SocialMediaAttachment, SocialMediaAttachmentKind,
    SocialPlatform, SocialPostMetadata, WebPageRichMetadata,
};
use image::{DynamicImage, Rgba, RgbaImage};
use url::Url;

#[test]
fn parses_youtube_and_bilibili_urls_and_share_copy() {
    let cases = [
        (
            "https://www.youtube.com/watch?v=dQw4w9WgXcQ&t=42s",
            SocialPlatform::Youtube,
            "yt:dQw4w9WgXcQ",
        ),
        (
            "https://youtu.be/dQw4w9WgXcQ?si=abc",
            SocialPlatform::Youtube,
            "yt:dQw4w9WgXcQ",
        ),
        (
            "https://www.youtube.com/shorts/abcdefghijk",
            SocialPlatform::Youtube,
            "yt:abcdefghijk",
        ),
        (
            "https://www.bilibili.com/video/BV1GJ411x7h7/?p=2",
            SocialPlatform::Bilibili,
            "bili:BV1GJ411x7h7:p2",
        ),
        (
            "https://www.bilibili.com/video/av170001",
            SocialPlatform::Bilibili,
            "bili:av170001",
        ),
        (
            "https://b23.tv/abc123X",
            SocialPlatform::Bilibili,
            "bili:short:abc123X",
        ),
    ];

    for (raw, expected_platform, expected_dedup) in cases {
        let u = Url::parse(raw).unwrap();
        let vref = VideoPlatformURLParser::parse(&u).expect(raw);
        assert_eq!(vref.platform(), expected_platform, "url={raw}");
        assert_eq!(vref.dedup_key(), expected_dedup, "url={raw}");

        let sref = SocialPostURLParser::parse(&u).expect(raw);
        assert_eq!(sref.platform(), expected_platform);
        assert_eq!(sref.dedup_key(), expected_dedup);
    }

    // Embedded Bilibili share copy
    let share = "【一个超赞的设计教程】 https://b23.tv/XyZ9870 复制打开";
    let extracted = SocialPostURLParser::extract_post_url(share).expect("extract b23.tv");
    assert_eq!(extracted.as_str(), "https://b23.tv/XyZ9870");
}

#[test]
fn bilibili_wbi_signing_and_proxy_allowlist_work() {
    let mut params = std::collections::BTreeMap::new();
    params.insert("bvid".to_string(), "BV1GJ411x7h7".to_string());
    params.insert("cid".to_string(), "12345".to_string());
    let signed = VideoPlatformResolver::sign_bilibili_wbi(
        &params,
        "7cd084941338484aae1ad9425b84077c",
        "4932caff0ff746eab6f01bf08b70ac45",
        1_700_000_000,
    );
    assert!(signed
        .iter()
        .any(|(k, v)| k == "bvid" && v == "BV1GJ411x7h7"));
    assert!(signed.iter().any(|(k, v)| k == "cid" && v == "12345"));
    assert!(signed.iter().any(|(k, v)| k == "wts" && v == "1700000000"));
    let rid = signed
        .iter()
        .find(|(k, _)| k == "w_rid")
        .map(|(_, v)| v.as_str())
        .expect("w_rid present");
    assert_eq!(rid.len(), 32);
    assert!(rid.bytes().all(|b| b.is_ascii_hexdigit()));

    assert!(XPostURLParser::is_allowed_social_proxy_host(Some(
        "i0.hdslb.com"
    )));
    assert!(XPostURLParser::is_allowed_social_proxy_host(Some(
        "i.ytimg.com"
    )));
    assert!(XPostURLParser::is_allowed_social_proxy_host(Some(
        "yt3.ggpht.com"
    )));
}

#[test]
fn extracts_timestamp_chapters_and_renders_16x9_video_card() {
    let desc =
        "Intro\n00:00 Opening Setup\n02:15 Key Lighting Breakdown\n1:05:30 Color Grading\nThanks!";
    let chapters = VideoPlatformResolver::extract_timestamp_chapters(desc);
    assert_eq!(chapters.len(), 3);
    assert_eq!(chapters[0], "00:00 Opening Setup");
    assert_eq!(chapters[1], "02:15 Key Lighting Breakdown");
    assert_eq!(chapters[2], "1:05:30 Color Grading");

    let meta = SocialPostMetadata {
        platform: SocialPlatform::Bilibili,
        author_name: "光影实验室".to_string(),
        author_handle: "UP 10086".to_string(),
        author_avatar_url: None,
        published_at_text: Some("2026-11-26".to_string()),
        body_text: "完整灯光拆解".to_string(),
        quoted_author: None,
        quoted_text: None,
        article_title: Some("室内电影布光 3 步法".to_string()),
        media_urls: vec!["https://i0.hdslb.com/bfs/archive/cover.jpg".to_string()],
        media_thumbnail_urls: vec!["https://i0.hdslb.com/bfs/archive/cover.jpg".to_string()],
        attachments: vec![SocialMediaAttachment::new(
            SocialMediaAttachmentKind::Video,
            "https://www.bilibili.com/video/BV1GJ411x7h7",
            Some("https://i0.hdslb.com/bfs/archive/cover.jpg".to_string()),
        )],
        has_video: true,
        video_url: None,
        reply_count: Some(180),
        repost_count: Some(420),
        like_count: Some(12_300),
        view_count: Some(185_000),
        original_url: "https://www.bilibili.com/video/BV1GJ411x7h7".to_string(),
        media_fetch_failed: false,
        video_duration_seconds: Some(754.0),
        video_summary: Some("讲解主光、轮廓光与环境补光的比例控制。".to_string()),
        video_outline: chapters,
        video_id: Some("BV1GJ411x7h7".to_string()),
        video_cid: Some(987_654),
    };
    assert_eq!(meta.formatted_video_duration().as_deref(), Some("12:34"));
    assert!(meta.has_video_summary_content());

    let cover = DynamicImage::ImageRgba8(RgbaImage::from_pixel(1280, 720, Rgba([28, 52, 92, 255])));
    let card = MediaArtwork::social_post_card_with_avatar(&meta, Some(&cover), None);
    assert_eq!((card.width(), card.height()), (1280, 720));

    let vref = VideoPlatformReference::Bilibili {
        bvid: Some("BV1GJ411x7h7".to_string()),
        aid: None,
        short_url: None,
        page: None,
        canonical_url: Url::parse("https://www.bilibili.com/video/BV1GJ411x7h7").unwrap(),
    };
    assert_eq!(
        vref.canonical_url().as_str(),
        "https://www.bilibili.com/video/BV1GJ411x7h7"
    );
}

#[test]
fn universal_web_parser_extracts_json_ld_iso8601_oembed_videos_lazy_images_and_lead_paragraphs() {
    let html = r#"<!doctype html>
<html>
<head>
  <title>Ignored Fallback Title</title>
  <link rel="alternate" type="application/json+oembed" href="/oembed.json?url=demo">
  <link rel="canonical" href="https://studio.example.com/reel/lighting">
  <script type="application/ld+json">
  {
    "@context": "https://schema.org",
    "@graph": [
      {
        "@type": "VideoObject",
        "name": "Cinematic Volumetric Lighting Study",
        "description": "Deep breakdown of volumetric scattering and subtle color contrast.",
        "author": { "@type": "Person", "name": "Maya Lin" },
        "publisher": { "@type": "Organization", "name": "Studio Example" },
        "uploadDate": "2026-11-20T10:30:00Z",
        "duration": "PT1H2M5S",
        "contentUrl": "https://cdn.example.com/videos/volumetric.mp4",
        "thumbnailUrl": ["https://cdn.example.com/posters/volumetric.jpg"]
      }
    ]
  }
  </script>
</head>
<body>
  <article>
    <video poster="/posters/fallback.jpg">
      <source src="/media/reel.mp4" type="video/mp4">
    </video>
    <img data-original="/images/still-01.webp" width="1200" height="800" />
    <img src="/images/pixel.gif" width="1" height="1" />
    <p>This first readable paragraph explains how practical key fixtures shape architectural depth across dark surfaces.</p>
  </article>
</body>
</html>"#;

    let base = Url::parse("https://studio.example.com/reel/lighting").unwrap();
    let parsed = WebBookmarkResolver::parse_html_rich(html, Some(&base));

    assert_eq!(
        parsed.title.as_deref(),
        Some("Cinematic Volumetric Lighting Study")
    );
    assert_eq!(parsed.author_name.as_deref(), Some("Maya Lin"));
    assert_eq!(parsed.site_name.as_deref(), Some("Studio Example"));
    assert_eq!(
        parsed.published_at_text.as_deref(),
        Some("2026-11-20T10:30:00Z")
    );
    assert_eq!(parsed.duration_seconds, Some(3725.0));
    assert!(parsed.is_video_page);
    assert_eq!(
        parsed.oembed_url.as_deref(),
        Some("https://studio.example.com/oembed.json?url=demo")
    );
    assert!(parsed
        .video_candidates
        .contains(&"https://cdn.example.com/videos/volumetric.mp4".to_string()));
    assert!(parsed
        .video_candidates
        .contains(&"https://studio.example.com/media/reel.mp4".to_string()));
    assert!(parsed
        .image_candidates
        .contains(&"https://studio.example.com/images/still-01.webp".to_string()));
    assert!(!parsed
        .image_candidates
        .iter()
        .any(|u| u.contains("pixel.gif")));
}

#[test]
fn asset_extractable_link_attachments_covers_social_video_and_rich_webpages() {
    let mut web_asset = AssetRecord::new("Design Essay", "essay.url");
    web_asset.media_kind = MediaKind::WebBookmark;
    web_asset.rich_metadata = Some(AssetRichMetadata {
        web_page: Some(WebPageRichMetadata {
            site_name: Some("Studio Journal".to_string()),
            author_name: Some("Aria".to_string()),
            published_at_text: Some("2026-11-25".to_string()),
            summary: Some("Visual rhythm notes.".to_string()),
            attachments: vec![
                SocialMediaAttachment::new(
                    SocialMediaAttachmentKind::Video,
                    "https://cdn.example.com/clip.mp4",
                    Some("https://cdn.example.com/hero.jpg".to_string()),
                ),
                SocialMediaAttachment::new(
                    SocialMediaAttachmentKind::Photo,
                    "https://cdn.example.com/still.png",
                    None,
                ),
            ],
            has_video: true,
            duration_seconds: Some(95.0),
            canonical_url: Some("https://cdn.example.com/essay".to_string()),
        }),
        ..AssetRichMetadata::default()
    });

    let atts = web_asset.extractable_link_attachments();
    assert_eq!(atts.len(), 2);
    assert_eq!(atts[0].kind, SocialMediaAttachmentKind::Video);
    assert_eq!(atts[1].kind, SocialMediaAttachmentKind::Photo);
}
