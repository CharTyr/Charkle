//! Douyin (抖音) URL parser, short-link (`v.douyin.com`) & share-copy extractor,
//! CDN host allowlist / Referer policy, and best-effort single-URL fallback resolver.

use std::collections::HashSet;
use std::time::Duration;

use chrono::{DateTime, Utc};
use reqwest::Client;
use scraper::{Html, Selector};
use serde_json::Value;
use url::Url;

use crate::media::resolvers::{ResolvedSocialPost, SocialPostResolver, WebBookmarkResolver};
use crate::media::xiaohongshu::XiaohongshuPostResolver;
use crate::models::core::{
    SocialMediaAttachment, SocialMediaAttachmentKind, SocialPlatform, SocialPostMetadata,
};

pub const DOUYIN_REFERER: &str = "https://www.douyin.com/";
pub const DOUYIN_VIDEO_TAG: &str = "抖音视频";
pub const DOUYIN_PHOTO_NOTE_TAG: &str = "抖音图文";

/// Canonical content-type classification tag for Douyin items (`抖音视频` vs `抖音图文`).
pub fn douyin_classification_tag(has_video: bool) -> &'static str {
    if has_video {
        DOUYIN_VIDEO_TAG
    } else {
        DOUYIN_PHOTO_NOTE_TAG
    }
}
const DOUYIN_BROWSER_UA: &str = "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/131.0.0.0 Safari/537.36";
const MAX_DOUYIN_HTML_BYTES: usize = 2 * 1024 * 1024;

const POST_HOSTS: &[&str] = &[
    "douyin.com",
    "www.douyin.com",
    "m.douyin.com",
    "iesdouyin.com",
    "www.iesdouyin.com",
];
const SHORT_HOSTS: &[&str] = &["v.douyin.com", "www.v.douyin.com"];

const BLOCKED_TITLES: &[&str] = &[
    "验证码中间页",
    "安全验证",
    "验证中心",
    "登录 - 抖音",
    "抖音-记录美好生活",
    "抖音 - 记录美好生活",
];

/// Parsed identity of a Douyin (抖音) video, photo-note (`图文`), or short share link.
#[derive(Debug, Clone, PartialEq, Eq, Hash)]
pub struct DouyinPostReference {
    pub aweme_id: Option<String>,
    pub is_note: bool,
    pub source_url: Url,
    pub is_short_link: bool,
}

impl DouyinPostReference {
    /// Canonical `https://www.douyin.com/video/<aweme_id>` or `/note/<aweme_id>` URL.
    pub fn canonical_url(&self) -> String {
        if let Some(ref aweme_id) = self.aweme_id {
            if !aweme_id.is_empty() {
                let kind = if self.is_note { "note" } else { "video" };
                return format!("https://www.douyin.com/{kind}/{aweme_id}");
            }
        }
        self.source_url.to_string()
    }

    /// Stable cross-platform deduplication key independent of route or query parameters.
    pub fn dedup_key(&self) -> String {
        if let Some(ref aweme_id) = self.aweme_id {
            if !aweme_id.is_empty() {
                return format!("douyin:{aweme_id}");
            }
        }
        format!("url:{}", self.source_url.as_str().to_ascii_lowercase())
    }
}

/// Detects and normalizes Douyin video/photo-note URLs, `?modal_id=` views, and `v.douyin.com`
/// mobile share copy links, plus CDN host classification for anti-hotlink Referer & SSRF checks.
pub struct DouyinURLParser;

impl DouyinURLParser {
    pub fn parse(url: &Url) -> Option<DouyinPostReference> {
        if !matches!(url.scheme(), "http" | "https") {
            return None;
        }
        if !url.username().is_empty() || url.password().is_some() {
            return None;
        }
        let host = url.host_str()?.to_ascii_lowercase();
        let segments: Vec<&str> = url
            .path_segments()
            .map(|iter| iter.filter(|s| !s.is_empty()).collect())
            .unwrap_or_default();

        if SHORT_HOSTS.contains(&host.as_str()) {
            if segments.is_empty() {
                return None;
            }
            return Some(DouyinPostReference {
                aweme_id: None,
                is_note: false,
                source_url: url.clone(),
                is_short_link: true,
            });
        }

        if !POST_HOSTS.contains(&host.as_str()) {
            return None;
        }

        // Direct path patterns:
        // /video/<aweme_id>
        // /note/<aweme_id>
        // /slides/<aweme_id>
        // /share/video/<aweme_id>
        // /share/note/<aweme_id>
        // /share/slides/<aweme_id>
        if segments.len() >= 2
            && segments[0].eq_ignore_ascii_case("video")
            && Self::is_valid_aweme_id(segments[1])
        {
            return Some(DouyinPostReference {
                aweme_id: Some(segments[1].to_string()),
                is_note: false,
                source_url: url.clone(),
                is_short_link: false,
            });
        }

        if segments.len() >= 2
            && (segments[0].eq_ignore_ascii_case("note")
                || segments[0].eq_ignore_ascii_case("slides"))
            && Self::is_valid_aweme_id(segments[1])
        {
            return Some(DouyinPostReference {
                aweme_id: Some(segments[1].to_string()),
                is_note: true,
                source_url: url.clone(),
                is_short_link: false,
            });
        }

        if segments.len() >= 3
            && segments[0].eq_ignore_ascii_case("share")
            && Self::is_valid_aweme_id(segments[2])
        {
            if segments[1].eq_ignore_ascii_case("video") {
                return Some(DouyinPostReference {
                    aweme_id: Some(segments[2].to_string()),
                    is_note: false,
                    source_url: url.clone(),
                    is_short_link: false,
                });
            }
            if segments[1].eq_ignore_ascii_case("note")
                || segments[1].eq_ignore_ascii_case("slides")
            {
                return Some(DouyinPostReference {
                    aweme_id: Some(segments[2].to_string()),
                    is_note: true,
                    source_url: url.clone(),
                    is_short_link: false,
                });
            }
        }

        // Modal query parameter on profile/discover/search pages: ?modal_id=<aweme_id>
        for (k, v) in url.query_pairs() {
            if k.eq_ignore_ascii_case("modal_id") {
                let candidate = v.trim();
                if Self::is_valid_aweme_id(candidate) {
                    let is_note = segments.iter().any(|s| s.eq_ignore_ascii_case("note"));
                    return Some(DouyinPostReference {
                        aweme_id: Some(candidate.to_string()),
                        is_note,
                        source_url: url.clone(),
                        is_short_link: false,
                    });
                }
            }
        }

        None
    }

    /// Extracts a Douyin URL from raw pasted text or Chinese mobile share copy
    /// (e.g. `"7.48 复制打开抖音，看看【作者的作品】... https://v.douyin.com/iXXXX/ 03/12"`),
    /// supporting both space-separated and zero-space CJK-glued links.
    pub fn extract_post_url(text: &str) -> Option<Url> {
        let trimmed = text.trim();
        if trimmed.is_empty() {
            return None;
        }
        if let Ok(direct) = Url::parse(trimmed) {
            if Self::parse(&direct).is_some() {
                return Some(direct);
            }
        }

        let mut idx = 0usize;
        while idx < trimmed.len() {
            let Some(ch) = trimmed[idx..].chars().next() else {
                break;
            };
            let rest = &trimmed[idx..];
            let has_scheme = (rest.len() >= 8
                && rest.as_bytes()[..8].eq_ignore_ascii_case(b"https://"))
                || (rest.len() >= 7 && rest.as_bytes()[..7].eq_ignore_ascii_case(b"http://"));
            if has_scheme {
                let mut end = rest.len();
                for (off, c) in rest.char_indices() {
                    if c.is_whitespace()
                        || c >= '\u{2E80}'
                        || matches!(c, '<' | '>' | '"' | '\'' | '（' | '）' | '【' | '】')
                    {
                        end = off;
                        break;
                    }
                }
                let candidate = rest[..end]
                    .trim_end_matches(['.', ',', ';', '!', '?', ')', ']', '，', '。', '！', '？']);
                if let Ok(url) = Url::parse(candidate) {
                    if Self::parse(&url).is_some() {
                        return Some(url);
                    }
                }
            }
            idx += ch.len_utf8();
        }
        None
    }

    pub fn is_valid_aweme_id(candidate: &str) -> bool {
        let len = candidate.len();
        (15..=22).contains(&len) && candidate.bytes().all(|b| b.is_ascii_digit())
    }

    pub fn is_short_link(url: &Url) -> bool {
        url.host_str()
            .map(|h| SHORT_HOSTS.contains(&h.to_ascii_lowercase().as_str()))
            .unwrap_or(false)
    }

    /// Allowlisted Douyin image & avatar CDN hosts for `/proxy-social` and Referer injection.
    pub fn is_douyin_image_host(host: Option<&str>) -> bool {
        matches_domain_suffix(
            host,
            &[
                "douyinpic.com",
                "byteimg.com",
                "ibytedtos.com",
                "zjcdn.com",
                "snssdk.com",
                "amemv.com",
                "pstatp.com",
                "douyincdn.com",
                "bytegoofy.com",
            ],
        )
    }

    /// Allowlisted Douyin video CDN & playback redirect hosts for `/proxy-video-stream`,
    /// direct download fallback, and auto-Referer injection.
    pub fn is_douyin_video_host(host: Option<&str>) -> bool {
        matches_domain_suffix(
            host,
            &[
                "douyinvod.com",
                "zjcdn.com",
                "snssdk.com",
                "bytevcloudapi.com",
                "amemv.com",
                "douyincdn.com",
                "iesdouyin.com",
                "douyin.com",
            ],
        )
    }

    /// Union of Douyin image and video CDN hosts.
    pub fn is_douyin_media_host(host: Option<&str>) -> bool {
        Self::is_douyin_image_host(host) || Self::is_douyin_video_host(host)
    }

    /// Returns `true` if a Douyin signed VOD URL carries an explicit Unix timestamp expiration
    /// (`x-expires` or `expires`) that has already passed (with a 30-second safety margin).
    pub fn is_stream_url_expired(url: &Url, now_unix_secs: i64) -> bool {
        for (k, v) in url.query_pairs() {
            if k.eq_ignore_ascii_case("x-expires") || k.eq_ignore_ascii_case("expires") {
                let raw = v.trim();
                let parsed = raw
                    .parse::<i64>()
                    .ok()
                    .or_else(|| i64::from_str_radix(raw, 16).ok());
                if let Some(exp) = parsed {
                    if exp > 1_600_000_000 && exp <= now_unix_secs.saturating_add(30) {
                        return true;
                    }
                }
            }
        }
        false
    }
}

fn matches_domain_suffix(host: Option<&str>, suffixes: &[&str]) -> bool {
    let Some(raw) = host else {
        return false;
    };
    let h = raw.trim().to_ascii_lowercase();
    if h.is_empty() {
        return false;
    }
    suffixes
        .iter()
        .any(|suffix| h == *suffix || h.ends_with(&format!(".{suffix}")))
}

/// Best-effort resolver for directly pasted Douyin URLs and `v.douyin.com` short links.
///
/// Never synthesizes anti-bot signatures (`a_bogus` / `X-Bogus`) or attempts to bypass login
/// or verification gates: if public HTML returns a verification/JS shell, falls back gracefully
/// to a clean canonical Douyin bookmark preserving `aweme_id` and watch URL.
pub struct DouyinPostResolver;

impl DouyinPostResolver {
    pub async fn resolve(reference: &DouyinPostReference) -> Option<ResolvedSocialPost> {
        let mut working_ref = reference.clone();
        if reference.is_short_link {
            if let Some(redirected) = Self::resolve_short_link(&reference.source_url).await {
                if let Some(parsed) = DouyinURLParser::parse(&redirected) {
                    working_ref = parsed;
                }
            }
        }

        let canonical_str = working_ref.canonical_url();
        if let Ok(fetch_url) = Url::parse(&canonical_str) {
            if let Some((html, final_url)) = Self::fetch_html(&fetch_url).await {
                let effective_ref = DouyinURLParser::parse(&final_url).unwrap_or_else(|| {
                    if working_ref.aweme_id.is_some() {
                        working_ref.clone()
                    } else {
                        DouyinPostReference {
                            aweme_id: working_ref.aweme_id.clone(),
                            is_note: working_ref.is_note,
                            source_url: final_url,
                            is_short_link: false,
                        }
                    }
                });
                if let Some(from_data) = Self::parse_router_or_render_data(&html, &effective_ref) {
                    return Some(from_data);
                }
                if let Some(from_meta) = Self::parse_meta_fallback(&html, &effective_ref) {
                    return Some(from_meta);
                }
            }
        }

        // Graceful fallback when Douyin serves a JS/verification shell for bare desktop HTTP:
        // preserve canonical URL, aweme_id, and video/note classification without failing ingest.
        working_ref
            .aweme_id
            .as_ref()
            .map(|aweme_id| Self::build_minimal_bookmark(&working_ref, aweme_id))
    }

    /// Follows redirects on `v.douyin.com/<code>` (capped at 6 hops, SSRF-guarded).
    pub async fn resolve_short_link(url: &Url) -> Option<Url> {
        if !SocialPostResolver::is_safe_public_media_url(url) {
            return None;
        }
        let client = Client::builder()
            .timeout(Duration::from_secs(12))
            .user_agent(DOUYIN_BROWSER_UA)
            .redirect(reqwest::redirect::Policy::limited(6))
            .build()
            .ok()?;

        let resp = client
            .get(url.clone())
            .header("Accept", "text/html,application/xhtml+xml,*/*;q=0.8")
            .send()
            .await
            .ok()?;

        let final_url = resp.url().clone();
        if !SocialPostResolver::is_safe_public_media_url(&final_url) {
            return None;
        }
        Some(final_url)
    }

    async fn fetch_html(url: &Url) -> Option<(String, Url)> {
        if !SocialPostResolver::is_safe_public_media_url(url) {
            return None;
        }
        let client = Client::builder()
            .timeout(Duration::from_secs(12))
            .user_agent(DOUYIN_BROWSER_UA)
            .redirect(reqwest::redirect::Policy::limited(5))
            .build()
            .ok()?;

        let resp = client
            .get(url.clone())
            .header(
                "Accept",
                "text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8",
            )
            .header("Accept-Language", "zh-CN,zh;q=0.9,en;q=0.7")
            .header("Referer", DOUYIN_REFERER)
            .send()
            .await
            .ok()?;

        if !resp.status().is_success() {
            return None;
        }
        let final_url = resp.url().clone();
        if !SocialPostResolver::is_safe_public_media_url(&final_url) {
            return None;
        }
        let bytes = resp.bytes().await.ok()?;
        if bytes.is_empty() || bytes.len() > MAX_DOUYIN_HTML_BYTES {
            return None;
        }
        let html = String::from_utf8_lossy(&bytes).into_owned();
        Some((html, final_url))
    }

    // =========================================================================
    // Pure, Offline Unit-Testable Parsers
    // =========================================================================

    pub fn parse_router_or_render_data(
        html: &str,
        reference: &DouyinPostReference,
    ) -> Option<ResolvedSocialPost> {
        let root = extract_embedded_douyin_json(html)?;
        let aweme = locate_aweme_object(&root, reference.aweme_id.as_deref())?;
        Self::build_from_aweme_value(aweme, reference)
    }

    pub fn parse_meta_fallback(
        html: &str,
        reference: &DouyinPostReference,
    ) -> Option<ResolvedSocialPost> {
        let doc = Html::parse_document(html);
        let raw_title = select_meta(&doc, "og:title")
            .or_else(|| select_title(&doc))
            .unwrap_or_default();
        let clean_title = clean_douyin_page_title(&raw_title);
        let description = select_meta(&doc, "og:description")
            .or_else(|| select_meta(&doc, "description"))
            .unwrap_or_default();
        let cover = select_meta(&doc, "og:image").and_then(|s| upgraded_https_url(&s));

        if is_blocked_title(&clean_title) && cover.is_none() && description.trim().is_empty() {
            return None;
        }
        if clean_title.is_empty() && description.trim().is_empty() && cover.is_none() {
            return None;
        }

        let canonical_url = reference.canonical_url();
        let mut attachments = Vec::new();
        let mut media_urls = Vec::new();
        let mut media_thumbs = Vec::new();
        if let Some(ref c) = cover {
            attachments.push(SocialMediaAttachment::new(
                SocialMediaAttachmentKind::Photo,
                c.clone(),
                Some(c.clone()),
            ));
            media_urls.push(c.clone());
            media_thumbs.push(c.clone());
        }

        let body_text = if !description.trim().is_empty() {
            description.trim().to_string()
        } else if !clean_title.is_empty() {
            clean_title.clone()
        } else {
            canonical_url.clone()
        };

        let meta = SocialPostMetadata {
            platform: SocialPlatform::Douyin,
            author_name: "抖音用户".to_string(),
            author_handle: "douyin".to_string(),
            author_avatar_url: None,
            published_at_text: None,
            body_text,
            quoted_author: None,
            quoted_text: None,
            article_title: (!clean_title.is_empty()).then_some(clean_title),
            media_urls,
            media_thumbnail_urls: media_thumbs,
            attachments,
            has_video: !reference.is_note,
            video_url: None,
            reply_count: None,
            repost_count: None,
            like_count: None,
            view_count: None,
            original_url: canonical_url,
            media_fetch_failed: false,
            video_duration_seconds: None,
            video_summary: None,
            video_outline: Vec::new(),
            video_id: reference.aweme_id.clone(),
            video_cid: None,
        };

        Some(ResolvedSocialPost {
            metadata: meta,
            primary_media_download_url: cover.clone(),
            primary_media_kind: cover.as_ref().map(|_| SocialMediaAttachmentKind::Photo),
            primary_thumbnail_url: cover,
            extracted_tags: Vec::new(),
        })
    }

    fn build_from_aweme_value(
        aweme: &Value,
        reference: &DouyinPostReference,
    ) -> Option<ResolvedSocialPost> {
        let aweme_id = string_value(aweme.get("aweme_id").or_else(|| aweme.get("awemeId")))
            .or_else(|| reference.aweme_id.clone());
        let desc = string_value(aweme.get("desc")).unwrap_or_default();
        let explicit_title = string_value(
            aweme
                .get("item_title")
                .or_else(|| aweme.get("preview_title")),
        );

        let images = aweme.get("images").and_then(Value::as_array);
        let aweme_type = aweme.get("aweme_type").and_then(Value::as_i64);
        let is_photo_note =
            reference.is_note || aweme_type == Some(68) || images.is_some_and(|a| !a.is_empty());

        let author = aweme.get("author");
        let author_name = author
            .and_then(|a| string_value(a.get("nickname")))
            .unwrap_or_else(|| "抖音用户".to_string());
        let author_handle = author
            .and_then(|a| {
                string_value(a.get("unique_id"))
                    .or_else(|| string_value(a.get("short_id")))
                    .or_else(|| string_value(a.get("uid")))
            })
            .unwrap_or_else(|| "douyin".to_string());
        let author_avatar_url = author.and_then(|a| {
            pick_best_image_url_from_node(a.get("avatar_medium"))
                .or_else(|| pick_best_image_url_from_node(a.get("avatar_thumb")))
                .or_else(|| pick_best_image_url_from_node(a.get("avatar_larger")))
        });

        let published_at_text = format_epoch_timestamp(aweme.get("create_time"));

        let stats = aweme.get("statistics");
        let like_count = stats
            .and_then(|s| s.get("digg_count"))
            .and_then(XiaohongshuPostResolver::parse_chinese_metric_count);
        let reply_count = stats
            .and_then(|s| s.get("comment_count"))
            .and_then(XiaohongshuPostResolver::parse_chinese_metric_count);
        let repost_count = stats
            .and_then(|s| s.get("share_count").or_else(|| s.get("collect_count")))
            .and_then(XiaohongshuPostResolver::parse_chinese_metric_count);
        let view_count = stats
            .and_then(|s| s.get("play_count"))
            .and_then(XiaohongshuPostResolver::parse_chinese_metric_count);

        let mut extracted_tags = Vec::new();
        let mut seen_tags = HashSet::new();
        if let Some(extras) = aweme.get("text_extra").and_then(Value::as_array) {
            for entry in extras {
                if let Some(tag) = string_value(entry.get("hashtag_name")) {
                    let clean = tag.trim_start_matches('#').trim().to_string();
                    if !clean.is_empty() && seen_tags.insert(clean.to_ascii_lowercase()) {
                        extracted_tags.push(clean);
                    }
                }
            }
        }

        let mut attachments = Vec::new();
        let mut media_urls = Vec::new();
        let mut media_thumbs = Vec::new();
        let mut video_url: Option<String> = None;
        let mut primary_thumb: Option<String> = None;
        let mut video_duration_seconds: Option<f64> = None;

        if is_photo_note {
            if let Some(imgs) = images {
                for img in imgs {
                    if let Some(u) = pick_best_image_url_from_node(Some(img)) {
                        if primary_thumb.is_none() {
                            primary_thumb = Some(u.clone());
                        }
                        attachments.push(SocialMediaAttachment::new(
                            SocialMediaAttachmentKind::Photo,
                            u.clone(),
                            Some(u.clone()),
                        ));
                        media_urls.push(u.clone());
                        media_thumbs.push(u);
                    }
                }
            }
        } else if let Some(video) = aweme.get("video") {
            if let Some(dur_ms) = video
                .get("duration")
                .and_then(Value::as_f64)
                .or_else(|| aweme.get("duration").and_then(Value::as_f64))
            {
                if dur_ms > 0.0 {
                    video_duration_seconds = Some(if dur_ms > 3600.0 {
                        dur_ms / 1000.0
                    } else {
                        dur_ms
                    });
                }
            }
            let cover = pick_best_image_url_from_node(video.get("origin_cover"))
                .or_else(|| pick_best_image_url_from_node(video.get("cover")))
                .or_else(|| pick_best_image_url_from_node(video.get("dynamic_cover")));
            primary_thumb = cover.clone();
            video_url = pick_best_video_url_from_node(video);
            if let Some(ref v_url) = video_url {
                attachments.push(SocialMediaAttachment::new(
                    SocialMediaAttachmentKind::Video,
                    v_url.clone(),
                    cover.clone(),
                ));
                media_urls.push(v_url.clone());
                if let Some(ref c) = cover {
                    media_thumbs.push(c.clone());
                }
            } else if let Some(ref c) = cover {
                attachments.push(SocialMediaAttachment::new(
                    SocialMediaAttachmentKind::Photo,
                    c.clone(),
                    Some(c.clone()),
                ));
                media_urls.push(c.clone());
                media_thumbs.push(c.clone());
            }
        }

        let canonical_url = if let Some(ref id) = aweme_id {
            let kind = if is_photo_note { "note" } else { "video" };
            format!("https://www.douyin.com/{kind}/{id}")
        } else {
            reference.canonical_url()
        };

        let article_title = explicit_title.or_else(|| derive_headline_from_desc(&desc));
        let body_text = if !desc.trim().is_empty() {
            desc
        } else {
            article_title
                .clone()
                .unwrap_or_else(|| canonical_url.clone())
        };

        let has_video = !is_photo_note;
        let primary_download = if has_video {
            video_url.clone().or_else(|| primary_thumb.clone())
        } else {
            primary_thumb.clone()
        };
        let primary_kind = if has_video && video_url.is_some() {
            Some(SocialMediaAttachmentKind::Video)
        } else if primary_thumb.is_some() {
            Some(SocialMediaAttachmentKind::Photo)
        } else {
            None
        };

        let meta = SocialPostMetadata {
            platform: SocialPlatform::Douyin,
            author_name,
            author_handle,
            author_avatar_url,
            published_at_text,
            body_text,
            quoted_author: None,
            quoted_text: None,
            article_title,
            media_urls,
            media_thumbnail_urls: media_thumbs,
            attachments,
            has_video,
            video_url,
            reply_count,
            repost_count,
            like_count,
            view_count,
            original_url: canonical_url,
            media_fetch_failed: false,
            video_duration_seconds,
            video_summary: None,
            video_outline: Vec::new(),
            video_id: aweme_id,
            video_cid: None,
        };

        Some(ResolvedSocialPost {
            metadata: meta,
            primary_media_download_url: primary_download,
            primary_media_kind: primary_kind,
            primary_thumbnail_url: primary_thumb,
            extracted_tags,
        })
    }

    fn build_minimal_bookmark(
        reference: &DouyinPostReference,
        aweme_id: &str,
    ) -> ResolvedSocialPost {
        let canonical_url = reference.canonical_url();
        let label = if reference.is_note {
            format!("抖音图文 {aweme_id}")
        } else {
            format!("抖音作品 {aweme_id}")
        };
        let meta = SocialPostMetadata {
            platform: SocialPlatform::Douyin,
            author_name: "抖音用户".to_string(),
            author_handle: "douyin".to_string(),
            author_avatar_url: None,
            published_at_text: None,
            body_text: canonical_url.clone(),
            quoted_author: None,
            quoted_text: None,
            article_title: Some(label),
            media_urls: Vec::new(),
            media_thumbnail_urls: Vec::new(),
            attachments: Vec::new(),
            has_video: !reference.is_note,
            video_url: None,
            reply_count: None,
            repost_count: None,
            like_count: None,
            view_count: None,
            original_url: canonical_url,
            media_fetch_failed: false,
            video_duration_seconds: None,
            video_summary: None,
            video_outline: Vec::new(),
            video_id: Some(aweme_id.to_string()),
            video_cid: None,
        };
        ResolvedSocialPost {
            metadata: meta,
            primary_media_download_url: None,
            primary_media_kind: None,
            primary_thumbnail_url: None,
            extracted_tags: Vec::new(),
        }
    }
}

fn upgraded_https_url(raw: &str) -> Option<String> {
    let trimmed = raw.trim();
    if trimmed.is_empty() {
        return None;
    }
    let normalized = if trimmed.starts_with("//") {
        format!("https:{trimmed}")
    } else if trimmed.len() >= 7 && trimmed[..7].eq_ignore_ascii_case("http://") {
        format!("https://{}", &trimmed[7..])
    } else {
        trimmed.to_string()
    };
    let parsed = Url::parse(&normalized).ok()?;
    if !WebBookmarkResolver::is_web_url(&parsed) {
        return None;
    }
    Some(parsed.to_string())
}

fn pick_best_image_url_from_node(node: Option<&Value>) -> Option<String> {
    let list = node?.get("url_list").and_then(Value::as_array)?;
    let mut non_heic: Vec<String> = Vec::new();
    let mut fallback: Vec<String> = Vec::new();
    for entry in list {
        let Some(raw) = entry.as_str() else {
            continue;
        };
        let Some(url) = upgraded_https_url(raw) else {
            continue;
        };
        let lower = url.to_ascii_lowercase();
        let is_heic = lower.contains(".heic")
            || lower.contains(".heif")
            || lower.contains("format=heic")
            || lower.contains("~tplv-dy-aweme-images-v2:3000:3000:q75.heic");
        if is_heic {
            fallback.push(url);
        } else {
            non_heic.push(url);
        }
    }
    non_heic
        .into_iter()
        .find(|u| {
            let l = u.to_ascii_lowercase();
            l.contains(".jpeg") || l.contains(".jpg") || l.contains(".png") || l.contains(".webp")
        })
        .or_else(|| {
            list.iter()
                .filter_map(Value::as_str)
                .filter_map(upgraded_https_url)
                .find(|u| {
                    let l = u.to_ascii_lowercase();
                    !l.contains(".heic") && !l.contains(".heif")
                })
        })
        .or_else(|| fallback.into_iter().next())
}

fn pick_best_video_url_from_node(video: &Value) -> Option<String> {
    // Prefer highest-bitrate H.264 stream (`is_h265 == 0`) from `bit_rate` for widest WebView2
    // playback compatibility, excluding watermarked `playwm` URLs.
    if let Some(bit_rates) = video.get("bit_rate").and_then(Value::as_array) {
        let mut candidates: Vec<(bool, i64, String)> = Vec::new();
        for br in bit_rates {
            let is_h265 = br.get("is_h265").and_then(Value::as_i64).unwrap_or(0) != 0;
            let rate = br.get("bit_rate").and_then(Value::as_i64).unwrap_or(0);
            if let Some(url) = br
                .get("play_addr")
                .and_then(|p| p.get("url_list"))
                .and_then(Value::as_array)
                .and_then(|arr| {
                    arr.iter()
                        .filter_map(Value::as_str)
                        .filter_map(upgraded_https_url)
                        .find(|u| !u.to_ascii_lowercase().contains("playwm"))
                })
            {
                candidates.push((!is_h265, rate, url));
            }
        }
        candidates.sort_by(|a, b| b.0.cmp(&a.0).then_with(|| b.1.cmp(&a.1)));
        if let Some((_, _, url)) = candidates.into_iter().next() {
            return Some(url);
        }
    }

    video
        .get("play_addr")
        .and_then(|p| p.get("url_list"))
        .and_then(Value::as_array)
        .and_then(|arr| {
            arr.iter()
                .filter_map(Value::as_str)
                .filter_map(upgraded_https_url)
                .find(|u| !u.to_ascii_lowercase().contains("playwm"))
        })
}

fn extract_embedded_douyin_json(html: &str) -> Option<Value> {
    // Strategy 1: <script id="RENDER_DATA" type="application/json">percent-encoded-json</script>
    if let Some(render_start) = html.find("id=\"RENDER_DATA\"") {
        if let Some(tag_end) = html[render_start..].find('>') {
            let body = &html[render_start + tag_end + 1..];
            if let Some(close) = body.find("</script>") {
                let raw = body[..close].trim();
                if let Ok(decoded) = percent_decode_utf8(raw) {
                    if let Ok(val) = serde_json::from_str::<Value>(&decoded) {
                        return Some(val);
                    }
                }
                if let Ok(val) = serde_json::from_str::<Value>(raw) {
                    return Some(val);
                }
            }
        }
    }

    // Strategy 2: window._ROUTER_DATA = {...}</script>
    if let Some(marker) = html.find("window._ROUTER_DATA") {
        if let Some(eq_off) = html[marker..].find('=') {
            let after_eq = html[marker + eq_off + 1..].trim_start();
            if let Some(close) = after_eq.find("</script>") {
                let candidate = after_eq[..close].trim().trim_end_matches(';').trim();
                if let Ok(val) = serde_json::from_str::<Value>(candidate) {
                    return Some(val);
                }
            }
        }
    }

    None
}

fn percent_decode_utf8(input: &str) -> Result<String, std::string::FromUtf8Error> {
    let bytes = input.as_bytes();
    let mut out = Vec::with_capacity(bytes.len());
    let mut i = 0;
    while i < bytes.len() {
        if bytes[i] == b'%' && i + 2 < bytes.len() {
            if let (Some(hi), Some(lo)) = (hex_nibble(bytes[i + 1]), hex_nibble(bytes[i + 2])) {
                out.push((hi << 4) | lo);
                i += 3;
                continue;
            }
        }
        out.push(bytes[i]);
        i += 1;
    }
    String::from_utf8(out)
}

fn hex_nibble(b: u8) -> Option<u8> {
    match b {
        b'0'..=b'9' => Some(b - b'0'),
        b'a'..=b'f' => Some(b - b'a' + 10),
        b'A'..=b'F' => Some(b - b'A' + 10),
        _ => None,
    }
}

fn locate_aweme_object<'a>(root: &'a Value, target_id: Option<&str>) -> Option<&'a Value> {
    match root {
        Value::Object(map) => {
            if let Some(id_val) = map.get("aweme_id").or_else(|| map.get("awemeId")) {
                if let Some(id_str) = id_val.as_str() {
                    if target_id.is_none_or(|t| t == id_str)
                        && (map.contains_key("desc")
                            || map.contains_key("video")
                            || map.contains_key("images"))
                    {
                        return Some(root);
                    }
                }
            }
            for key in ["aweme_detail", "awemeDetail", "detail", "itemInfo"] {
                if let Some(child) = map.get(key) {
                    if let Some(found) = locate_aweme_object(child, target_id) {
                        return Some(found);
                    }
                }
            }
            for val in map.values() {
                if let Some(found) = locate_aweme_object(val, target_id) {
                    return Some(found);
                }
            }
            None
        }
        Value::Array(arr) => {
            for item in arr {
                if let Some(found) = locate_aweme_object(item, target_id) {
                    return Some(found);
                }
            }
            None
        }
        _ => None,
    }
}

fn string_value(val: Option<&Value>) -> Option<String> {
    let v = val?;
    match v {
        Value::String(s) => {
            let trimmed = s.trim();
            if trimmed.is_empty() {
                None
            } else {
                Some(trimmed.to_string())
            }
        }
        Value::Number(n) => Some(n.to_string()),
        _ => None,
    }
}

fn format_epoch_timestamp(val: Option<&Value>) -> Option<String> {
    let raw = val.and_then(|v| {
        v.as_i64()
            .or_else(|| v.as_str().and_then(|s| s.trim().parse::<i64>().ok()))
    })?;
    if raw <= 0 {
        return None;
    }
    let secs = if raw > 10_000_000_000 {
        raw / 1000
    } else {
        raw
    };
    DateTime::<Utc>::from_timestamp(secs, 0).map(|dt| dt.format("%Y-%m-%d %H:%M").to_string())
}

fn derive_headline_from_desc(desc: &str) -> Option<String> {
    let first_line = desc
        .lines()
        .map(str::trim)
        .find(|l| !l.is_empty())
        .unwrap_or("");
    let stripped = first_line
        .split('#')
        .next()
        .map(str::trim)
        .filter(|s| !s.is_empty())
        .unwrap_or(first_line);
    if stripped.is_empty() {
        None
    } else {
        Some(stripped.chars().take(80).collect())
    }
}

fn select_meta(doc: &Html, name: &str) -> Option<String> {
    let sel_prop = Selector::parse(&format!("meta[property='{name}']")).ok()?;
    if let Some(el) = doc.select(&sel_prop).next() {
        if let Some(content) = el.value().attr("content").map(str::trim) {
            if !content.is_empty() {
                return Some(content.to_string());
            }
        }
    }
    let sel_name = Selector::parse(&format!("meta[name='{name}']")).ok()?;
    if let Some(el) = doc.select(&sel_name).next() {
        if let Some(content) = el.value().attr("content").map(str::trim) {
            if !content.is_empty() {
                return Some(content.to_string());
            }
        }
    }
    None
}

fn select_title(doc: &Html) -> Option<String> {
    let sel = Selector::parse("title").ok()?;
    let text: String = doc.select(&sel).next()?.text().collect();
    let trimmed = text.trim();
    if trimmed.is_empty() {
        None
    } else {
        Some(trimmed.to_string())
    }
}

fn clean_douyin_page_title(raw: &str) -> String {
    let trimmed = raw.trim();
    for suffix in [" - 抖音", "- 抖音", " - Douyin", "-抖音"] {
        if let Some(prefix) = trimmed.strip_suffix(suffix) {
            return prefix.trim().to_string();
        }
    }
    trimmed.to_string()
}

fn is_blocked_title(title: &str) -> bool {
    let trimmed = title.trim();
    trimmed.is_empty() || BLOCKED_TITLES.iter().any(|b| trimmed.contains(b))
}
