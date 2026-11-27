//! Unit and integration tests for Douyin (抖音) support, lossless `SocialPlatform::Unknown(String)`
//! wire compatibility, `/.charkle/` sync shard merge resilience, CDN anti-hotlink & SSRF rules,
//! `application/octet-stream` `ftyp` magic-byte sniffing, zero-download bookmark ingest, and
//! `900×1440` vertical feed card rendering.

use std::collections::BTreeMap;

use charkle_core::db::LibraryDatabase;
use charkle_core::media::{
    canonical_dedup_key, normalize_video_stream_content_type, resolve_media_extension,
    validate_social_proxy_url, DouyinPostReference, DouyinPostResolver, DouyinURLParser,
    MediaArtwork, MediaPipeline, SocialPostResolver, SocialPostURLParser, VideoPlatformResolver,
    XPostURLParser, DOUYIN_REFERER,
};
use charkle_core::models::core::{
    AssetRecord, AssetRichMetadata, FilterCriteria, MediaKind, SocialMediaAttachment,
    SocialMediaAttachmentKind, SocialPlatform, SocialPostMetadata,
};
use charkle_core::models::media::CaptureInput;
use charkle_core::models::sync::{
    AssetChanges, SyncClocks, SyncOperation, SyncOperationChange, SyncStamp,
};
use charkle_core::wire::swift_codec::{canonical_json_bytes, SyncFields};
use image::{DynamicImage, ImageFormat, Rgba, RgbaImage};
use tempfile::tempdir;
use url::Url;
use uuid::Uuid;

fn sample_cover_png(color: [u8; 4]) -> Vec<u8> {
    let img = RgbaImage::from_pixel(120, 160, Rgba(color));
    let mut cursor = std::io::Cursor::new(Vec::new());
    DynamicImage::ImageRgba8(img)
        .write_to(&mut cursor, ImageFormat::Png)
        .unwrap();
    cursor.into_inner()
}

fn sample_douyin_meta(has_video: bool) -> SocialPostMetadata {
    let attachments = if has_video {
        vec![SocialMediaAttachment::new(
            SocialMediaAttachmentKind::Video,
            "https://v26-web.douyinvod.com/demo/stream?x-expires=4102444800",
            Some("https://p3-pc.douyinpic.com/img/cover.jpeg".to_string()),
        )]
    } else {
        vec![
            SocialMediaAttachment::new(
                SocialMediaAttachmentKind::Photo,
                "https://p3-pc.douyinpic.com/img/slide-1.jpeg",
                Some("https://p3-pc.douyinpic.com/img/slide-1.jpeg".to_string()),
            ),
            SocialMediaAttachment::new(
                SocialMediaAttachmentKind::Photo,
                "https://p3-pc.douyinpic.com/img/slide-2.jpeg",
                Some("https://p3-pc.douyinpic.com/img/slide-2.jpeg".to_string()),
            ),
            SocialMediaAttachment::new(
                SocialMediaAttachmentKind::Photo,
                "https://p3-pc.douyinpic.com/img/slide-3.jpeg",
                Some("https://p3-pc.douyinpic.com/img/slide-3.jpeg".to_string()),
            ),
        ]
    };
    SocialPostMetadata {
        platform: SocialPlatform::Douyin,
        author_name: "光影漫步".to_string(),
        author_handle: "studio_alpha".to_string(),
        author_avatar_url: None,
        published_at_text: Some("2026-11-27 18:00".to_string()),
        body_text: "冬日街拍构图与色彩分层 #摄影 #色调".to_string(),
        quoted_author: None,
        quoted_text: None,
        article_title: Some("冬日街拍构图与色彩分层".to_string()),
        media_urls: attachments.iter().map(|a| a.url.clone()).collect(),
        media_thumbnail_urls: attachments
            .iter()
            .filter_map(|a| a.thumbnail_url.clone())
            .collect(),
        attachments,
        has_video,
        video_url: has_video
            .then(|| "https://v26-web.douyinvod.com/demo/stream?x-expires=4102444800".to_string()),
        reply_count: Some(128),
        repost_count: Some(460),
        like_count: Some(15_200),
        view_count: Some(98_000),
        original_url: if has_video {
            "https://www.douyin.com/video/7456789012345678901".to_string()
        } else {
            "https://www.douyin.com/note/7456789012345678902".to_string()
        },
        media_fetch_failed: false,
        video_duration_seconds: has_video.then_some(95.0),
        video_summary: None,
        video_outline: Vec::new(),
        video_id: Some(if has_video {
            "7456789012345678901".to_string()
        } else {
            "7456789012345678902".to_string()
        }),
        video_cid: None,
    }
}

#[test]
fn social_platform_douyin_and_unknown_lossless_serde_and_sync_op_merge() {
    // 1. First-class Douyin wire contract & decoupled zero-download predicate
    assert_eq!(
        serde_json::to_string(&SocialPlatform::Douyin).unwrap(),
        "\"douyin\""
    );
    assert_eq!(
        serde_json::from_str::<SocialPlatform>("\"douyin\"").unwrap(),
        SocialPlatform::Douyin
    );
    assert_eq!(
        SocialPlatform::from_raw("douyin"),
        Some(SocialPlatform::Douyin)
    );
    assert_eq!(
        SocialPlatform::from_raw("iesdouyin"),
        Some(SocialPlatform::Douyin)
    );
    assert_eq!(SocialPlatform::from_raw("dy"), Some(SocialPlatform::Douyin));
    assert_eq!(SocialPlatform::from_raw("future_app"), None);
    assert!(!SocialPlatform::Douyin.is_video_platform());
    assert!(SocialPlatform::Douyin.prefers_zero_download_video_bookmark());
    assert!(SocialPlatform::Youtube.is_video_platform());
    assert!(SocialPlatform::Youtube.prefers_zero_download_video_bookmark());
    assert!(SocialPlatform::Bilibili.is_video_platform());
    assert!(SocialPlatform::Bilibili.prefers_zero_download_video_bookmark());
    assert!(!SocialPlatform::Xiaohongshu.prefers_zero_download_video_bookmark());
    assert_eq!(SocialPlatform::Douyin.display_name(), "抖音");
    assert_eq!(SocialPlatform::Douyin.post_noun(), "作品");
    assert_eq!(SocialPlatform::Douyin.open_action_label(), "在抖音打开");

    // 2. Lossless unknown future platform round-trip
    let decoded: SocialPlatform = serde_json::from_str("\"future_app\"").unwrap();
    assert_eq!(decoded, SocialPlatform::Unknown("future_app".to_string()));
    assert_eq!(serde_json::to_string(&decoded).unwrap(), "\"future_app\"");
    assert!(!decoded.is_video_platform());
    assert!(!decoded.prefers_zero_download_video_bookmark());
    assert_eq!(decoded.raw_value(), "future_app");
    assert_eq!(decoded.display_name(), "future_app");

    // 3. SyncFields::merge with an incoming unknown future platform never fails and preserves raw string
    let asset_id = Uuid::new_v4();
    let mut base = AssetRecord::new("Future Note", "future.md");
    base.id = asset_id;
    base.media_kind = MediaKind::WebBookmark;
    base.mime_type = "text/markdown".to_string();
    base.file_size_bytes = 128;
    base.content_hash = "hash_future".to_string();

    let future_rich = serde_json::json!({
        "socialPost": {
            "platform": "future_app",
            "authorName": "Creator",
            "authorHandle": "creator",
            "bodyText": "From a newer client",
            "mediaURLs": [],
            "mediaThumbnailURLs": [],
            "attachments": [],
            "hasVideo": false,
            "originalURL": "https://future.example.com/post/42",
            "mediaFetchFailed": false
        }
    });
    let mut delta = BTreeMap::new();
    delta.insert(
        "richMetadata".to_string(),
        canonical_json_bytes(&future_rich).unwrap(),
    );
    let mut clocks = SyncClocks::default();
    let stamp = SyncStamp {
        time: 100,
        device: "remote-future-device".to_string(),
    };
    let merged = SyncFields::merge(&delta, &base, &["id"], &stamp, &mut clocks)
        .expect("unknown SocialPlatform must merge without serde error");
    let sp = merged
        .rich_metadata
        .as_ref()
        .and_then(|r| r.social_post.as_ref())
        .expect("socialPost present");
    assert_eq!(
        sp.platform,
        SocialPlatform::Unknown("future_app".to_string())
    );
    let serialized_again = serde_json::to_value(&merged).unwrap();
    assert_eq!(
        serialized_again["richMetadata"]["socialPost"]["platform"],
        "future_app"
    );

    // 4. LibraryDatabase::apply_op_shard commits both `douyin` and `future_app` ops without rollback
    let tmp = tempdir().unwrap();
    let db = LibraryDatabase::open(&tmp.path().join("Library.sqlite3")).unwrap();

    let douyin_id = Uuid::new_v4();
    let mut douyin_asset = AssetRecord::new("冬日街拍构图与色彩分层", "douyin.md");
    douyin_asset.id = douyin_id;
    douyin_asset.media_kind = MediaKind::WebBookmark;
    douyin_asset.mime_type = "text/markdown".to_string();
    douyin_asset.file_size_bytes = 256;
    douyin_asset.content_hash = "hash_douyin".to_string();
    douyin_asset.rich_metadata = Some(AssetRichMetadata {
        social_post: Some(sample_douyin_meta(true)),
        ..AssetRichMetadata::default()
    });
    let douyin_fields = SyncFields::diff(
        &douyin_asset,
        None,
        &[
            "id",
            "tags",
            "isLocalOriginalCached",
            "updatedAt",
            "updatedHLC",
        ],
    )
    .unwrap();

    let future_id = Uuid::new_v4();
    let mut future_fields = BTreeMap::new();
    future_fields.insert("fileName".to_string(), br#""future.md""#.to_vec());
    future_fields.insert("title".to_string(), br#""Future Note""#.to_vec());
    future_fields.insert("mediaKind".to_string(), br#""webBookmark""#.to_vec());
    future_fields.insert("mimeType".to_string(), br#""text/markdown""#.to_vec());
    future_fields.insert("fileSizeBytes".to_string(), b"128".to_vec());
    future_fields.insert("contentHash".to_string(), br#""hash_future_2""#.to_vec());
    future_fields.insert(
        "richMetadata".to_string(),
        canonical_json_bytes(&future_rich).unwrap(),
    );

    let shard_ops = vec![
        SyncOperation {
            stamp: SyncStamp {
                time: 200,
                device: "dev-remote".to_string(),
            },
            change: SyncOperationChange::Asset(AssetChanges {
                id: douyin_id,
                fields: douyin_fields,
                tags_added: vec!["抖音".to_string()],
                tags_removed: Vec::new(),
            }),
            project_location: None,
        },
        SyncOperation {
            stamp: SyncStamp {
                time: 201,
                device: "dev-remote".to_string(),
            },
            change: SyncOperationChange::Asset(AssetChanges {
                id: future_id,
                fields: future_fields,
                tags_added: Vec::new(),
                tags_removed: Vec::new(),
            }),
            project_location: None,
        },
    ];
    let mut cursors = BTreeMap::new();
    cursors.insert("dev-remote".to_string(), 2i64);
    db.apply_op_shard(&shard_ops, &[], "deviceCursors", &cursors)
        .expect("apply_op_shard must succeed for both douyin and unknown future platforms");

    let all_assets = db
        .fetch_assets(&FilterCriteria::default(), None)
        .expect("fetch_assets");
    let fetched_douyin = all_assets
        .iter()
        .find(|a| a.id == douyin_id)
        .expect("douyin stored");
    assert_eq!(
        fetched_douyin
            .rich_metadata
            .as_ref()
            .and_then(|r| r.social_post.as_ref())
            .map(|p| &p.platform),
        Some(&SocialPlatform::Douyin)
    );
    let fetched_future = all_assets
        .iter()
        .find(|a| a.id == future_id)
        .expect("future stored");
    assert_eq!(
        fetched_future
            .rich_metadata
            .as_ref()
            .and_then(|r| r.social_post.as_ref())
            .map(|p| &p.platform),
        Some(&SocialPlatform::Unknown("future_app".to_string()))
    );
}

#[test]
fn douyin_handle_sanitation_hides_sec_uid_and_long_numeric_ids() {
    let mut meta = sample_douyin_meta(true);
    assert_eq!(
        meta.display_handle_line().as_deref(),
        Some("抖音号 studio_alpha")
    );

    meta.author_handle = "MS4wLjABAAAA9x8y7z6w5v4u3t2s1r0q_abcdef123456".to_string();
    assert_eq!(meta.display_handle_line(), None);

    meta.author_handle = "1234567890123456".to_string();
    assert_eq!(meta.display_handle_line(), None);

    meta.author_handle = "douyin".to_string();
    assert_eq!(meta.display_handle_line(), None);

    meta.author_name = "MS4wLjABAAAA9x8y7z6w5v4u3t2s1r0q".to_string();
    assert_eq!(meta.display_author_name(), "抖音用户");
}

#[test]
fn douyin_url_parser_short_links_share_copy_and_canonical_dedup() {
    let id = "7456789012345678901";
    let video_urls = [
        format!("https://www.douyin.com/video/{id}"),
        format!("https://douyin.com/video/{id}?previous_page=favorite"),
        format!("https://m.douyin.com/share/video/{id}"),
        format!("https://www.iesdouyin.com/share/video/{id}/?mid=123"),
        format!("https://www.douyin.com/user/self?showTab=favorite_collection&modal_id={id}"),
    ];
    for raw in &video_urls {
        let parsed = Url::parse(raw).unwrap();
        let dy_ref =
            DouyinURLParser::parse(&parsed).unwrap_or_else(|| panic!("parse failed: {raw}"));
        assert_eq!(dy_ref.aweme_id.as_deref(), Some(id));
        assert!(!dy_ref.is_note);
        assert!(!dy_ref.is_short_link);
        assert_eq!(dy_ref.dedup_key(), format!("douyin:{id}"));
        assert_eq!(
            canonical_dedup_key(raw).as_deref(),
            Some(format!("douyin:{id}").as_str())
        );

        let sref = SocialPostURLParser::parse(&parsed).unwrap();
        assert_eq!(sref.platform(), SocialPlatform::Douyin);
        assert_eq!(sref.dedup_key(), format!("douyin:{id}"));
    }

    let note_url = Url::parse("https://www.douyin.com/note/7456789012345678902").unwrap();
    let note_ref = DouyinURLParser::parse(&note_url).unwrap();
    assert!(note_ref.is_note);
    assert_eq!(
        note_ref.canonical_url(),
        "https://www.douyin.com/note/7456789012345678902"
    );
    assert_eq!(note_ref.dedup_key(), "douyin:7456789012345678902");

    let short_url = Url::parse("https://v.douyin.com/iAbCdEfG/").unwrap();
    let short_ref = DouyinURLParser::parse(&short_url).unwrap();
    assert!(short_ref.is_short_link);
    assert!(short_ref.aweme_id.is_none());
    assert!(DouyinURLParser::is_short_link(&short_url));

    // Share copy with spaces and CJK-glued links
    let share_copy =
        "7.48 复制打开抖音，看看【光影漫步的作品】冬日色彩 https://v.douyin.com/iAbCdEfG/ 03/12";
    let extracted =
        SocialPostURLParser::extract_post_url(share_copy).expect("extract v.douyin.com");
    assert_eq!(extracted.as_str(), "https://v.douyin.com/iAbCdEfG/");

    let glued = "看看这个作品https://www.douyin.com/video/7456789012345678901太绝了";
    let extracted_glued = DouyinURLParser::extract_post_url(glued).expect("extract CJK-glued");
    assert_eq!(
        extracted_glued.as_str(),
        "https://www.douyin.com/video/7456789012345678901"
    );
}

#[test]
fn douyin_render_data_and_meta_parsers_handle_video_and_photo_note() {
    // 1. Video RENDER_DATA (prefers H.264 over H.265, excludes playwm, prefers JPEG over HEIC)
    let video_json = serde_json::json!({
        "aweme_detail": {
            "aweme_id": "7456789012345678901",
            "aweme_type": 0,
            "desc": "胶片感调色思路 #调色 #后期",
            "create_time": 1730000000,
            "author": {
                "nickname": "阿林影像",
                "unique_id": "alin_film",
                "avatar_thumb": {
                    "url_list": ["https://p3-pc.douyinpic.com/aweme/100x100/av.jpeg"]
                }
            },
            "statistics": {
                "digg_count": 8840,
                "comment_count": 312,
                "share_count": 905,
                "play_count": 120000
            },
            "text_extra": [
                { "hashtag_name": "调色" },
                { "hashtag_name": "后期" }
            ],
            "video": {
                "duration": 64000,
                "origin_cover": {
                    "url_list": [
                        "https://p3-pc.douyinpic.com/img/cover~tplv.heic",
                        "https://p3-pc.douyinpic.com/img/cover~tplv.jpeg"
                    ]
                },
                "bit_rate": [
                    {
                        "is_h265": 1,
                        "bit_rate": 3200000,
                        "play_addr": {
                            "url_list": ["https://v26-web.douyinvod.com/hevc_stream"]
                        }
                    },
                    {
                        "is_h265": 0,
                        "bit_rate": 1800000,
                        "play_addr": {
                            "url_list": [
                                "https://v26-web.douyinvod.com/playwm/watermarked",
                                "https://v26-web.douyinvod.com/h264_clean"
                            ]
                        }
                    }
                ]
            }
        }
    });
    let html_video = format!(
        r#"<html><body><script id="RENDER_DATA" type="application/json">{}</script></body></html>"#,
        serde_json::to_string(&video_json).unwrap()
    );
    let vref = DouyinPostReference {
        aweme_id: Some("7456789012345678901".to_string()),
        is_note: false,
        source_url: Url::parse("https://www.douyin.com/video/7456789012345678901").unwrap(),
        is_short_link: false,
    };
    let resolved_video =
        DouyinPostResolver::parse_router_or_render_data(&html_video, &vref).expect("video parsed");
    assert_eq!(resolved_video.metadata.platform, SocialPlatform::Douyin);
    assert!(resolved_video.metadata.has_video);
    assert_eq!(
        resolved_video.metadata.video_url.as_deref(),
        Some("https://v26-web.douyinvod.com/h264_clean")
    );
    assert_eq!(
        resolved_video.primary_thumbnail_url.as_deref(),
        Some("https://p3-pc.douyinpic.com/img/cover~tplv.jpeg")
    );
    assert_eq!(resolved_video.metadata.video_duration_seconds, Some(64.0));
    assert_eq!(resolved_video.metadata.like_count, Some(8840));
    assert_eq!(resolved_video.extracted_tags, vec!["调色", "后期"]);

    // 2. Multi-image photo-note (`aweme_type: 68`) via window._ROUTER_DATA
    let note_json = serde_json::json!({
        "loaderData": {
            "note": {
                "aweme_detail": {
                    "aweme_id": "7456789012345678902",
                    "aweme_type": 68,
                    "desc": "三张建筑线条参考",
                    "author": { "nickname": "建筑笔记", "unique_id": "arch_notes" },
                    "images": [
                        { "url_list": ["https://p3-pc.douyinpic.com/1.heic", "https://p3-pc.douyinpic.com/1.webp"] },
                        { "url_list": ["https://p3-pc.douyinpic.com/2.jpeg"] }
                    ]
                }
            }
        }
    });
    let html_note = format!(
        r#"<html><body><script>window._ROUTER_DATA = {};</script></body></html>"#,
        serde_json::to_string(&note_json).unwrap()
    );
    let nref = DouyinPostReference {
        aweme_id: Some("7456789012345678902".to_string()),
        is_note: true,
        source_url: Url::parse("https://www.douyin.com/note/7456789012345678902").unwrap(),
        is_short_link: false,
    };
    let resolved_note =
        DouyinPostResolver::parse_router_or_render_data(&html_note, &nref).expect("note parsed");
    assert!(!resolved_note.metadata.has_video);
    assert_eq!(resolved_note.metadata.attachments.len(), 2);
    assert_eq!(
        resolved_note.metadata.attachments[0].url,
        "https://p3-pc.douyinpic.com/1.webp"
    );

    // 3. Meta fallback rejects verification interstitials
    let blocked_html = "<html><head><title>验证码中间页</title></head><body></body></html>";
    assert!(DouyinPostResolver::parse_meta_fallback(blocked_html, &vref).is_none());
}

#[test]
fn douyin_cdn_allowlist_referer_ssrf_and_octet_stream_ftyp_sniffing() {
    // Allowlisted Douyin image CDNs
    for host in [
        "p3-pc.douyinpic.com",
        "p9-sign.byteimg.com",
        "p1.ibytedtos.com",
        "p3.zjcdn.com",
        "p6.amemv.com",
        "p3.snssdk.com",
    ] {
        assert!(
            XPostURLParser::is_allowed_social_proxy_host(Some(host)),
            "expected allowed image CDN host: {host}"
        );
        let u = Url::parse(&format!("https://{host}/img/test")).unwrap();
        assert!(validate_social_proxy_url(u.as_str()).is_ok());
        assert_eq!(
            SocialPostResolver::resolve_cdn_referer(&u, None),
            Some(DOUYIN_REFERER)
        );
    }

    // Video CDNs receive Douyin Referer
    for vhost in [
        "v26-web.douyinvod.com",
        "v3.zjcdn.com",
        "v9.bytevcloudapi.com",
    ] {
        let u = Url::parse(&format!("https://{vhost}/stream/item")).unwrap();
        assert!(DouyinURLParser::is_douyin_video_host(Some(vhost)));
        assert_eq!(
            SocialPostResolver::resolve_cdn_referer(&u, None),
            Some(DOUYIN_REFERER)
        );
    }

    // Blocked / spoofed / SSRF hosts rejected
    for bad in [
        "http://p3-pc.douyinpic.com/img/test.jpg",
        "https://douyinpic.com.evil.com/img/test.jpg",
        "https://127.0.0.1/img/test.jpg",
        "https://192.168.1.10/img/test.jpg",
        "https://localhost/img/test.jpg",
    ] {
        assert!(
            validate_social_proxy_url(bad).is_err(),
            "expected SSRF/allowlist rejection for {bad}"
        );
    }

    // application/octet-stream + ISO BMFF ftyp sniffing in resolve_media_extension
    let extless_url = Url::parse("https://v26-web.douyinvod.com/aweme/play/opaque-token").unwrap();
    let mp4_ftyp = b"\x00\x00\x00\x18ftypisom\x00\x00\x02\x00";
    let avif_ftyp = b"\x00\x00\x00\x1cftypavif\x00\x00\x00\x00";
    let heic_ftyp = b"\x00\x00\x00\x18ftypheic\x00\x00\x00\x00";
    let webp_hdr = b"RIFF\x24\x00\x00\x00WEBPVP8 ";
    let jpeg_hdr = b"\xFF\xD8\xFF\xE0\x00\x10JFIF";

    assert_eq!(
        resolve_media_extension(
            &extless_url,
            Some("application/octet-stream"),
            mp4_ftyp,
            SocialMediaAttachmentKind::Video
        ),
        "mp4"
    );
    assert_eq!(
        resolve_media_extension(
            &extless_url,
            Some("application/octet-stream"),
            avif_ftyp,
            SocialMediaAttachmentKind::Photo
        ),
        "avif"
    );
    assert_eq!(
        resolve_media_extension(
            &extless_url,
            Some("application/octet-stream"),
            heic_ftyp,
            SocialMediaAttachmentKind::Photo
        ),
        "heic"
    );
    assert_eq!(
        resolve_media_extension(
            &extless_url,
            Some("application/octet-stream"),
            webp_hdr,
            SocialMediaAttachmentKind::Photo
        ),
        "webp"
    );
    assert_eq!(
        resolve_media_extension(
            &extless_url,
            Some("application/octet-stream"),
            jpeg_hdr,
            SocialMediaAttachmentKind::Photo
        ),
        "jpg"
    );

    // Stream proxy Content-Type normalization for application/octet-stream
    assert_eq!(
        normalize_video_stream_content_type(
            Some("application/octet-stream"),
            &extless_url,
            mp4_ftyp
        ),
        "video/mp4"
    );
    // Mid-stream byte-range chunk (no leading ftyp) on Douyin VOD host still normalizes to video/mp4
    assert_eq!(
        normalize_video_stream_content_type(
            Some("application/octet-stream"),
            &extless_url,
            b"\x01\x02\x03\x04\x05\x06\x07\x08\x09\x0a\x0b\x0c"
        ),
        "video/mp4"
    );
    assert_eq!(
        normalize_video_stream_content_type(Some("video/webm"), &extless_url, b""),
        "video/webm"
    );

    // Stream expiration check (`x-expires`)
    let expired_u = Url::parse("https://v26-web.douyinvod.com/video?x-expires=1700000000").unwrap();
    let fresh_u = Url::parse("https://v26-web.douyinvod.com/video?x-expires=4102444800").unwrap();
    assert!(DouyinURLParser::is_stream_url_expired(
        &expired_u,
        1_750_000_000
    ));
    assert!(!DouyinURLParser::is_stream_url_expired(
        &fresh_u,
        1_750_000_000
    ));
}

#[test]
fn douyin_artwork_renders_900x1440_vertical_cards_for_video_and_photo_note() {
    let cover = DynamicImage::ImageRgba8(RgbaImage::from_pixel(720, 1280, Rgba([34, 48, 68, 255])));

    let video_meta = sample_douyin_meta(true);
    let video_card = MediaArtwork::social_post_card_with_avatar(&video_meta, Some(&cover), None);
    assert_eq!((video_card.width(), video_card.height()), (900, 1440));
    let video_text_only = MediaArtwork::social_post_card_with_avatar(&video_meta, None, None);
    assert_eq!(
        (video_text_only.width(), video_text_only.height()),
        (900, 1440)
    );

    let note_meta = sample_douyin_meta(false);
    let note_card = MediaArtwork::social_post_card_with_avatar(&note_meta, Some(&cover), None);
    assert_eq!((note_card.width(), note_card.height()), (900, 1440));
}

#[tokio::test]
async fn douyin_social_bookmark_ingest_enforces_zero_download_video_contract() {
    let tmp = tempdir().unwrap();
    let pipeline = MediaPipeline::new(tmp.path()).unwrap();

    let mut meta = sample_douyin_meta(true);
    // Point video_url at a non-routable loopback URL; zero-download contract must NOT attempt download
    meta.video_url = Some("https://127.0.0.1:9/must-never-be-downloaded.mp4".to_string());
    meta.attachments = vec![SocialMediaAttachment::new(
        SocialMediaAttachmentKind::Video,
        "https://127.0.0.1:9/must-never-be-downloaded.mp4",
        Some("https://p3-pc.douyinpic.com/img/cover.jpeg".to_string()),
    )];

    let imported = pipeline
        .ingest(
            CaptureInput::SocialBookmark {
                metadata: Box::new(meta),
                cover_image_data: Some(sample_cover_png([24, 32, 46, 255])),
                tags: vec!["摄影".to_string()],
            },
            None,
            None,
        )
        .await
        .expect("Douyin SocialBookmark ingest should succeed");

    assert_eq!(imported.asset.media_kind, MediaKind::WebBookmark);
    assert_eq!(imported.asset.pixel_width, 900);
    assert_eq!(imported.asset.pixel_height, 1440);
    assert_eq!(imported.asset.duration_seconds, Some(95.0));
    assert!(
        imported.asset.file_name.ends_with(".md"),
        "expected lightweight .md bookmark archive, got {}",
        imported.asset.file_name
    );

    let saved_post = imported
        .asset
        .rich_metadata
        .as_ref()
        .and_then(|r| r.social_post.as_ref())
        .expect("socialPost persisted");
    assert_eq!(saved_post.platform, SocialPlatform::Douyin);
    assert!(saved_post.has_video);
    assert_eq!(saved_post.video_duration_seconds, Some(95.0));
    assert_eq!(saved_post.video_id.as_deref(), Some("7456789012345678901"));
    assert_eq!(
        imported
            .asset
            .tags
            .iter()
            .filter(|t| t.as_str() == "抖音视频")
            .count(),
        1
    );
    assert!(!imported.asset.tags.iter().any(|t| t == "抖音图文"));
    assert!(imported.asset.tags.iter().any(|t| t == "抖音"));
    assert!(imported.asset.tags.iter().any(|t| t == "摄影"));

    // Confirm zero MP4 binaries were written into Originals/
    let originals_dir = tmp.path().join("Originals");
    if originals_dir.exists() {
        for entry in std::fs::read_dir(&originals_dir).unwrap().flatten() {
            let name = entry.file_name().to_string_lossy().to_ascii_lowercase();
            assert!(
                !name.ends_with(".mp4"),
                "unexpected MP4 in Originals: {name}"
            );
        }
    }
}

#[tokio::test]
async fn douyin_playback_plan_attaches_referer_and_ignores_watch_page_attachments() {
    let mut meta = sample_douyin_meta(true);
    meta.attachments.insert(
        0,
        SocialMediaAttachment::new(
            SocialMediaAttachmentKind::Video,
            "https://www.douyin.com/video/7456789012345678901",
            None,
        ),
    );
    let plan = VideoPlatformResolver::resolve_playback_plan(&meta).await;
    assert_eq!(
        plan.watch_url.as_deref(),
        Some("https://www.douyin.com/video/7456789012345678901")
    );
    assert_eq!(plan.direct_streams.len(), 1);
    assert_eq!(
        plan.direct_streams[0].url,
        "https://v26-web.douyinvod.com/demo/stream?x-expires=4102444800"
    );
    assert_eq!(
        plan.direct_streams[0]
            .http_headers
            .get("Referer")
            .map(String::as_str),
        Some(DOUYIN_REFERER)
    );
    assert!(plan.embed_player.is_none());
}

#[tokio::test]
async fn douyin_auto_classification_tags_video_and_photo_note_dedup() {
    let tmp = tempdir().unwrap();
    let pipeline = MediaPipeline::new(tmp.path()).unwrap();

    // 1. Video bookmark where extension already passed `抖音视频` & `抖音` -> deduplicated cleanly
    let mut video_meta = sample_douyin_meta(true);
    video_meta.video_url = Some("https://127.0.0.1:9/skip.mp4".to_string());
    video_meta.attachments = vec![SocialMediaAttachment::new(
        SocialMediaAttachmentKind::Video,
        "https://127.0.0.1:9/skip.mp4",
        None,
    )];
    let video_imported = pipeline
        .ingest(
            CaptureInput::SocialBookmark {
                metadata: Box::new(video_meta),
                cover_image_data: Some(sample_cover_png([24, 32, 46, 255])),
                tags: vec![
                    "抖音".to_string(),
                    "抖音视频".to_string(),
                    "抖音收藏".to_string(),
                    "调色".to_string(),
                ],
            },
            None,
            None,
        )
        .await
        .expect("Douyin video bookmark ingest");
    assert_eq!(
        video_imported
            .asset
            .tags
            .iter()
            .filter(|t| t.as_str() == "抖音视频")
            .count(),
        1
    );
    assert_eq!(
        video_imported
            .asset
            .tags
            .iter()
            .filter(|t| t.as_str() == "抖音")
            .count(),
        1
    );
    assert!(!video_imported.asset.tags.iter().any(|t| t == "抖音图文"));
    assert!(video_imported.asset.tags.iter().any(|t| t == "抖音收藏"));
    assert!(video_imported.asset.tags.iter().any(|t| t == "调色"));

    // 2. Photo-note bookmark without pre-supplied type tag -> auto-appends `抖音图文`
    let mut note_meta = sample_douyin_meta(false);
    note_meta.attachments = vec![SocialMediaAttachment::new(
        SocialMediaAttachmentKind::Photo,
        "https://p3-pc.douyinpic.com/img/slide-1.jpeg",
        Some("https://p3-pc.douyinpic.com/img/slide-1.jpeg".to_string()),
    )];
    let note_imported = pipeline
        .ingest(
            CaptureInput::SocialBookmark {
                metadata: Box::new(note_meta),
                cover_image_data: Some(sample_cover_png([44, 62, 86, 255])),
                tags: vec!["抖音收藏".to_string(), "构图".to_string()],
            },
            None,
            None,
        )
        .await
        .expect("Douyin photo-note bookmark ingest");
    assert_eq!(
        note_imported
            .asset
            .tags
            .iter()
            .filter(|t| t.as_str() == "抖音图文")
            .count(),
        1
    );
    assert!(!note_imported.asset.tags.iter().any(|t| t == "抖音视频"));
    assert!(note_imported.asset.tags.iter().any(|t| t == "抖音"));
    assert!(note_imported.asset.tags.iter().any(|t| t == "抖音收藏"));
    assert!(note_imported.asset.tags.iter().any(|t| t == "构图"));

    // 3. Photo-note bookmark where extension already passed `抖音图文` -> deduplicated cleanly
    let mut note_dup_meta = sample_douyin_meta(false);
    note_dup_meta.original_url = "https://www.douyin.com/note/7456789012345678999".to_string();
    note_dup_meta.attachments = vec![SocialMediaAttachment::new(
        SocialMediaAttachmentKind::Photo,
        "https://p3-pc.douyinpic.com/img/slide-2.jpeg",
        Some("https://p3-pc.douyinpic.com/img/slide-2.jpeg".to_string()),
    )];
    let note_dup_imported = pipeline
        .ingest(
            CaptureInput::SocialBookmark {
                metadata: Box::new(note_dup_meta),
                cover_image_data: Some(sample_cover_png([60, 72, 90, 255])),
                tags: vec![
                    "抖音图文".to_string(),
                    "抖音".to_string(),
                    "配色".to_string(),
                ],
            },
            None,
            None,
        )
        .await
        .expect("Douyin photo-note dedup ingest");
    assert_eq!(
        note_dup_imported
            .asset
            .tags
            .iter()
            .filter(|t| t.as_str() == "抖音图文")
            .count(),
        1
    );
    assert_eq!(
        note_dup_imported
            .asset
            .tags
            .iter()
            .filter(|t| t.as_str() == "抖音")
            .count(),
        1
    );
    assert!(note_dup_imported.asset.tags.iter().any(|t| t == "配色"));
}
