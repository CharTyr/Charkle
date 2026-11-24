//! Xiaohongshu (小红书) full-chain URL parser, `window.__INITIAL_STATE__` & OpenGraph note
//! resolver, Chinese metric parser, and Referer-injecting CDN media proxy cache.
//!
//! Mirrors `Sources/CharkleCore/Media/XiaohongshuPostResolver.swift`.

use std::collections::HashSet;
use std::path::{Path, PathBuf};
use std::time::Duration;

use chrono::{DateTime, Utc};
use reqwest::Client;
use scraper::{Html, Selector};
use serde_json::Value;
use sha2::{Digest, Sha256};
use url::Url;

use crate::media::resolvers::{ResolvedSocialPost, WebBookmarkResolver};
use crate::models::core::{
    SocialMediaAttachment, SocialMediaAttachmentKind, SocialPlatform, SocialPostMetadata,
};

pub const XIAOHONGSHU_REFERER: &str = "https://www.xiaohongshu.com/";
const XHS_BROWSER_UA: &str = "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/131.0.0.0 Safari/537.36";
const MAX_XHS_HTML_BYTES: usize = 1_572_864;
pub const MAX_XHS_PROXY_BYTES: usize = 20 * 1024 * 1024;

const NOTE_HOSTS: &[&str] = &[
    "xiaohongshu.com",
    "www.xiaohongshu.com",
    "m.xiaohongshu.com",
];
const SHORT_HOSTS: &[&str] = &["xhslink.com", "www.xhslink.com"];

const BLOCKED_TITLES: &[&str] = &[
    "页面不见了",
    "你访问的页面不见了",
    "安全验证",
    "安全限制",
    "登录 - 小红书",
    "小红书 - 你的生活兴趣社区",
    "小红书 - 你的生活指南",
];

/// Parsed identity of a Xiaohongshu (小红书) note or short share link.
#[derive(Debug, Clone, PartialEq, Eq, Hash)]
pub struct XiaohongshuNoteReference {
    pub note_id: Option<String>,
    pub xsec_token: Option<String>,
    pub xsec_source: Option<String>,
    pub source_url: Url,
    pub is_short_link: bool,
}

impl XiaohongshuNoteReference {
    /// Canonical `/explore/<noteID>` URL preserving `xsec_token` & `xsec_source` query params.
    pub fn canonical_url(&self) -> String {
        if let Some(ref note_id) = self.note_id {
            if !note_id.is_empty() {
                if let Ok(mut url) =
                    Url::parse(&format!("https://www.xiaohongshu.com/explore/{note_id}"))
                {
                    let mut pairs = Vec::new();
                    if let Some(ref t) = self.xsec_token {
                        if !t.is_empty() {
                            pairs.push(("xsec_token", t.as_str()));
                        }
                    }
                    if let Some(ref s) = self.xsec_source {
                        if !s.is_empty() {
                            pairs.push(("xsec_source", s.as_str()));
                        }
                    }
                    if !pairs.is_empty() {
                        url.query_pairs_mut().extend_pairs(pairs);
                    }
                    return url.to_string();
                }
            }
        }
        self.source_url.to_string()
    }

    /// Stable deduplication key independent of rotating `xsec_token` parameters.
    pub fn dedup_key(&self) -> String {
        if let Some(ref note_id) = self.note_id {
            if !note_id.is_empty() {
                return format!("xhs:{}", note_id.to_ascii_lowercase());
            }
        }
        format!("url:{}", self.source_url.as_str().to_ascii_lowercase())
    }
}

/// Detects and extracts Xiaohongshu note URLs and mobile app short links (`xhslink.com`).
pub struct XiaohongshuURLParser;

impl XiaohongshuURLParser {
    pub fn parse(url: &Url) -> Option<XiaohongshuNoteReference> {
        if !matches!(url.scheme(), "http" | "https") {
            return None;
        }
        if !url.username().is_empty() || url.password().is_some() {
            return None;
        }
        let host = url.host_str()?.to_ascii_lowercase();
        let segments: Vec<&str> = url.path_segments()?.filter(|s| !s.is_empty()).collect();

        if SHORT_HOSTS.contains(&host.as_str()) {
            if segments.is_empty() {
                return None;
            }
            return Some(XiaohongshuNoteReference {
                note_id: None,
                xsec_token: None,
                xsec_source: None,
                source_url: url.clone(),
                is_short_link: true,
            });
        }

        if !NOTE_HOSTS.contains(&host.as_str()) {
            return None;
        }

        let mut xsec_token: Option<String> = None;
        let mut xsec_source: Option<String> = None;
        for (k, v) in url.query_pairs() {
            let trimmed = v.trim();
            if trimmed.is_empty() {
                continue;
            }
            if k == "xsec_token" && xsec_token.is_none() {
                xsec_token = Some(trimmed.to_string());
            } else if k == "xsec_source" && xsec_source.is_none() {
                xsec_source = Some(trimmed.to_string());
            }
        }

        // Supported paths:
        // /explore/<noteId>
        // /discovery/item/<noteId>
        // /user/profile/<userId>/<noteId>
        let note_id = if segments.len() >= 2
            && segments[0].eq_ignore_ascii_case("explore")
            && Self::is_valid_note_id(segments[1])
        {
            Some(segments[1].to_string())
        } else if segments.len() >= 3
            && segments[0].eq_ignore_ascii_case("discovery")
            && segments[1].eq_ignore_ascii_case("item")
            && Self::is_valid_note_id(segments[2])
        {
            Some(segments[2].to_string())
        } else if segments.len() >= 4
            && segments[0].eq_ignore_ascii_case("user")
            && segments[1].eq_ignore_ascii_case("profile")
            && Self::is_valid_note_id(segments[3])
        {
            Some(segments[3].to_string())
        } else {
            None
        }?;

        Some(XiaohongshuNoteReference {
            note_id: Some(note_id),
            xsec_token,
            xsec_source,
            source_url: url.clone(),
            is_short_link: false,
        })
    }

    /// Extracts a Xiaohongshu URL from raw pasted text or mobile share copy
    /// (e.g. `"67 某某发布了一篇小红书笔记... http://xhslink.com/a/xxxx 复制本条信息..."`),
    /// supporting both space-separated and zero-space CJK-glued links.
    pub fn extract_note_url(text: &str) -> Option<Url> {
        let trimmed = text.trim();
        if trimmed.is_empty() {
            return None;
        }
        if let Ok(direct) = Url::parse(trimmed) {
            if Self::parse(&direct).is_some() {
                return Some(direct);
            }
        }

        // Scan explicit `http://` / `https://` prefixes cleanly across UTF-8 char boundaries.
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

    pub fn is_valid_note_id(candidate: &str) -> bool {
        let len = candidate.len();
        (16..=40).contains(&len) && candidate.bytes().all(|b| b.is_ascii_alphanumeric())
    }

    pub fn is_xiaohongshu_media_host(host: Option<&str>) -> bool {
        let Some(raw) = host else {
            return false;
        };
        let h = raw.trim().to_ascii_lowercase();
        if h.is_empty() {
            return false;
        }
        h == "xhscdn.com"
            || h.ends_with(".xhscdn.com")
            || h == "xiaohongshu.com"
            || h.ends_with(".xiaohongshu.com")
    }
}

/// Resolves Xiaohongshu note metadata, full carousel image list, video stream, tags, and author info
/// from `window.__INITIAL_STATE__` (with resilient OpenGraph multi-image fallback).
pub struct XiaohongshuPostResolver;

impl XiaohongshuPostResolver {
    pub async fn resolve(reference: &XiaohongshuNoteReference) -> Option<ResolvedSocialPost> {
        let mut working_ref = reference.clone();
        if reference.is_short_link {
            if let Some(redirected) = Self::resolve_short_link(&reference.source_url).await {
                if let Some(parsed) = XiaohongshuURLParser::parse(&redirected) {
                    working_ref = parsed;
                }
            }
        }

        let candidate_urls = Self::build_candidate_fetch_urls(&working_ref);
        for fetch_url in candidate_urls {
            let Some((html, final_url)) = Self::fetch_html(&fetch_url).await else {
                continue;
            };
            let effective_ref = XiaohongshuURLParser::parse(&final_url).unwrap_or_else(|| {
                if working_ref.note_id.is_some() {
                    working_ref.clone()
                } else {
                    XiaohongshuNoteReference {
                        note_id: working_ref.note_id.clone(),
                        xsec_token: working_ref.xsec_token.clone(),
                        xsec_source: working_ref.xsec_source.clone(),
                        source_url: final_url,
                        is_short_link: false,
                    }
                }
            });
            if let Some(from_state) = Self::parse_initial_state(&html, &effective_ref) {
                return Some(from_state);
            }
            if let Some(from_meta) = Self::parse_meta_fallback(&html, &effective_ref) {
                return Some(from_meta);
            }
        }
        None
    }

    // =========================================================================
    // Pure, Offline Unit-Testable Parsers
    // =========================================================================

    pub fn parse_initial_state(
        html: &str,
        reference: &XiaohongshuNoteReference,
    ) -> Option<ResolvedSocialPost> {
        let json_str = extract_initial_state_json(html)?;
        let sanitized = Self::sanitize_js_undefined(&json_str);
        let root: Value = serde_json::from_str(&sanitized).ok()?;
        let note_obj = locate_note_dictionary(&root, reference.note_id.as_deref())?;

        let note_id = string_value(note_obj.get("noteId").or_else(|| note_obj.get("id")))
            .or_else(|| reference.note_id.clone());
        let raw_title = string_value(note_obj.get("title")).unwrap_or_default();
        let raw_desc =
            Self::clean_xiaohongshu_body(&string_value(note_obj.get("desc")).unwrap_or_default());

        let user_obj = note_obj.get("user");
        let author_name = user_obj
            .and_then(|u| string_value(u.get("nickname").or_else(|| u.get("nickName"))))
            .unwrap_or_else(|| "小红书用户".to_string());
        let author_handle = user_obj
            .and_then(|u| {
                string_value(
                    u.get("redId")
                        .or_else(|| u.get("userId"))
                        .or_else(|| u.get("id")),
                )
            })
            .unwrap_or_else(|| "xiaohongshu".to_string());
        let author_avatar = user_obj
            .and_then(|u| string_value(u.get("avatar")))
            .and_then(|s| upgraded_https_url(&s));

        let published_at_text = format_timestamp(
            note_obj
                .get("time")
                .or_else(|| note_obj.get("lastUpdateTime")),
        );

        let interact = note_obj.get("interactInfo");
        let like_count = interact
            .and_then(|i| i.get("likedCount"))
            .and_then(Self::parse_chinese_metric_count);
        let comment_count = interact
            .and_then(|i| i.get("commentCount"))
            .and_then(Self::parse_chinese_metric_count);
        let share_count = interact
            .and_then(|i| i.get("shareCount").or_else(|| i.get("collectedCount")))
            .and_then(Self::parse_chinese_metric_count);

        // Extract hashtags from `tagList[].name`
        let mut extracted_tags = Vec::new();
        let mut seen_tags = HashSet::new();
        if let Some(tag_list) = note_obj.get("tagList").and_then(Value::as_array) {
            for item in tag_list {
                if let Some(name) = string_value(item.get("name")) {
                    let key = name.to_lowercase();
                    if seen_tags.insert(key) {
                        extracted_tags.push(name);
                    }
                }
            }
        }

        let mut attachments = Vec::new();
        let mut seen_urls = HashSet::new();

        let is_video_note =
            string_value(note_obj.get("type")).is_some_and(|t| t.eq_ignore_ascii_case("video"));
        let video_url = note_obj.get("video").and_then(extract_video_stream_url);

        let mut cover_photo_url: Option<String> = None;
        if let Some(image_list) = note_obj.get("imageList").and_then(Value::as_array) {
            for item in image_list {
                let Some(photo_url) = extract_best_image_url(item) else {
                    continue;
                };
                if cover_photo_url.is_none() {
                    cover_photo_url = Some(photo_url.clone());
                }
                if !is_video_note && seen_urls.insert(photo_url.clone()) {
                    let preview =
                        extract_preview_image_url(item).unwrap_or_else(|| photo_url.clone());
                    attachments.push(SocialMediaAttachment::new(
                        SocialMediaAttachmentKind::Photo,
                        photo_url,
                        Some(preview),
                    ));
                }
            }
        }

        if let Some(ref v_url) = video_url {
            if seen_urls.insert(v_url.clone()) {
                attachments.insert(
                    0,
                    SocialMediaAttachment::new(
                        SocialMediaAttachmentKind::Video,
                        v_url.clone(),
                        cover_photo_url.clone(),
                    ),
                );
            }
        } else if is_video_note {
            if let Some(ref cover) = cover_photo_url {
                if attachments.is_empty() {
                    attachments.push(SocialMediaAttachment::new(
                        SocialMediaAttachmentKind::Photo,
                        cover.clone(),
                        Some(cover.clone()),
                    ));
                }
            }
        }

        // Reject empty shells from unauthenticated redirects
        let has_substance =
            !raw_title.is_empty() || !raw_desc.is_empty() || !attachments.is_empty();
        if !has_substance {
            return None;
        }

        let final_ref = XiaohongshuNoteReference {
            note_id: note_id.or_else(|| reference.note_id.clone()),
            xsec_token: reference.xsec_token.clone(),
            xsec_source: reference.xsec_source.clone(),
            source_url: reference.source_url.clone(),
            is_short_link: false,
        };

        let media_urls: Vec<String> = attachments.iter().map(|a| a.url.clone()).collect();
        let thumb_urls: Vec<String> = attachments
            .iter()
            .filter_map(|a| {
                a.thumbnail_url
                    .clone()
                    .or_else(|| (a.kind == SocialMediaAttachmentKind::Photo).then(|| a.url.clone()))
            })
            .collect();
        let primary = attachments.first().cloned();
        let primary_thumb = primary
            .as_ref()
            .and_then(|p| p.thumbnail_url.clone())
            .or(cover_photo_url);

        let body_text = if raw_desc.is_empty() {
            raw_title.clone()
        } else {
            raw_desc
        };
        let article_title = (!raw_title.is_empty()).then_some(raw_title);

        let metadata = SocialPostMetadata {
            platform: SocialPlatform::Xiaohongshu,
            author_name,
            author_handle,
            author_avatar_url: author_avatar,
            published_at_text,
            body_text,
            quoted_author: None,
            quoted_text: None,
            article_title,
            media_urls,
            media_thumbnail_urls: thumb_urls,
            attachments,
            has_video: video_url.is_some() || is_video_note,
            video_url,
            reply_count: comment_count,
            repost_count: share_count,
            like_count,
            view_count: None,
            original_url: final_ref.canonical_url(),
            media_fetch_failed: false,
        };

        Some(ResolvedSocialPost {
            metadata,
            primary_media_download_url: primary.as_ref().map(|p| p.url.clone()),
            primary_media_kind: primary.as_ref().map(|p| p.kind),
            primary_thumbnail_url: primary_thumb,
            extracted_tags,
        })
    }

    pub fn parse_meta_fallback(
        html: &str,
        reference: &XiaohongshuNoteReference,
    ) -> Option<ResolvedSocialPost> {
        let doc = Html::parse_document(html);
        let og_title = select_meta_all(&doc, "og:title")
            .into_iter()
            .next()
            .or_else(|| select_html_title(&doc));
        let og_desc = select_meta_all(&doc, "og:description")
            .into_iter()
            .next()
            .or_else(|| select_meta_all(&doc, "description").into_iter().next())
            .unwrap_or_default();
        let og_images: Vec<String> = select_meta_all(&doc, "og:image")
            .into_iter()
            .filter_map(|s| upgraded_https_url(&s))
            .filter(|s| !is_placeholder_asset(s))
            .collect();
        let og_video = select_meta_all(&doc, "og:videourl")
            .into_iter()
            .next()
            .and_then(|s| upgraded_https_url(&s));

        let raw_title = og_title.as_deref().unwrap_or("");
        let cleaned_title = clean_page_title(raw_title);
        if cleaned_title.is_empty() && og_desc.trim().is_empty() && og_images.is_empty() {
            return None;
        }
        if og_images.is_empty() && og_video.is_none() && is_blocked_interstitial_title(raw_title) {
            return None;
        }

        let mut attachments = Vec::new();
        let mut seen = HashSet::new();
        if let Some(ref v) = og_video {
            if seen.insert(v.clone()) {
                attachments.push(SocialMediaAttachment::new(
                    SocialMediaAttachmentKind::Video,
                    v.clone(),
                    og_images.first().cloned(),
                ));
            }
        }
        for img in &og_images {
            if seen.insert(img.clone()) {
                attachments.push(SocialMediaAttachment::new(
                    SocialMediaAttachmentKind::Photo,
                    img.clone(),
                    Some(img.clone()),
                ));
            }
        }

        let clean_body = Self::clean_xiaohongshu_body(&og_desc);
        let media_urls: Vec<String> = attachments.iter().map(|a| a.url.clone()).collect();
        let thumb_urls: Vec<String> = attachments
            .iter()
            .map(|a| a.thumbnail_url.clone().unwrap_or_else(|| a.url.clone()))
            .collect();
        let primary = attachments.first().cloned();
        let primary_thumb = primary
            .as_ref()
            .and_then(|p| p.thumbnail_url.clone())
            .or_else(|| og_images.first().cloned());

        let metadata = SocialPostMetadata {
            platform: SocialPlatform::Xiaohongshu,
            author_name: "小红书笔记".to_string(),
            author_handle: reference
                .note_id
                .clone()
                .unwrap_or_else(|| "xiaohongshu".to_string()),
            author_avatar_url: None,
            published_at_text: None,
            body_text: if clean_body.is_empty() {
                cleaned_title.clone()
            } else {
                clean_body
            },
            quoted_author: None,
            quoted_text: None,
            article_title: (!cleaned_title.is_empty()).then_some(cleaned_title),
            media_urls,
            media_thumbnail_urls: thumb_urls,
            attachments,
            has_video: og_video.is_some(),
            video_url: og_video,
            reply_count: None,
            repost_count: None,
            like_count: None,
            view_count: None,
            original_url: reference.canonical_url(),
            media_fetch_failed: false,
        };

        Some(ResolvedSocialPost {
            metadata,
            primary_media_download_url: primary.as_ref().map(|p| p.url.clone()),
            primary_media_kind: primary.as_ref().map(|p| p.kind),
            primary_thumbnail_url: primary_thumb,
            extracted_tags: Vec::new(),
        })
    }

    /// Parses Xiaohongshu count values like `128`, `"1.2万"`, `"3.4千"`, `"10万+"`, `"2.5w"`, `"1.8k"`.
    pub fn parse_chinese_metric_count(raw: &Value) -> Option<i64> {
        match raw {
            Value::Number(n) => {
                if let Some(i) = n.as_i64() {
                    Some(i.max(0))
                } else {
                    n.as_f64().map(|f| (f.round() as i64).max(0))
                }
            }
            Value::String(s) => Self::parse_chinese_metric_str(s),
            _ => None,
        }
    }

    pub fn parse_chinese_metric_str(raw: &str) -> Option<i64> {
        let cleaned = raw.trim().replace(['+', ','], "");
        let s = cleaned.trim();
        if s.is_empty() {
            return None;
        }
        if let Some(prefix) = s
            .strip_suffix('万')
            .or_else(|| s.strip_suffix('w'))
            .or_else(|| s.strip_suffix('W'))
        {
            return prefix
                .trim()
                .parse::<f64>()
                .ok()
                .map(|v| (v * 10_000.0).round().max(0.0) as i64);
        }
        if let Some(prefix) = s
            .strip_suffix('千')
            .or_else(|| s.strip_suffix('k'))
            .or_else(|| s.strip_suffix('K'))
        {
            return prefix
                .trim()
                .parse::<f64>()
                .ok()
                .map(|v| (v * 1_000.0).round().max(0.0) as i64);
        }
        s.parse::<i64>().ok().map(|v| v.max(0))
    }

    /// Replaces bare JS `undefined` tokens outside JSON string literals with `null`,
    /// preserving any `"undefined"` content inside strings.
    pub fn sanitize_js_undefined(input: &str) -> String {
        let mut out = String::with_capacity(input.len());
        let mut in_string = false;
        let mut escaped = false;
        let mut idx = 0usize;

        while idx < input.len() {
            let Some(ch) = input[idx..].chars().next() else {
                break;
            };
            if in_string {
                out.push(ch);
                if escaped {
                    escaped = false;
                } else if ch == '\\' {
                    escaped = true;
                } else if ch == '"' {
                    in_string = false;
                }
                idx += ch.len_utf8();
                continue;
            }

            if ch == '"' {
                in_string = true;
                out.push(ch);
                idx += 1;
                continue;
            }

            if ch == 'u' && input[idx..].starts_with("undefined") {
                let after = idx + "undefined".len();
                let prev_is_ident = input[..idx]
                    .chars()
                    .next_back()
                    .is_some_and(|p| p.is_alphanumeric() || p == '_' || p == '$');
                let next_is_ident = input[after..]
                    .chars()
                    .next()
                    .is_some_and(|n| n.is_alphanumeric() || n == '_' || n == '$');
                if !prev_is_ident && !next_is_ident {
                    out.push_str("null");
                    idx = after;
                    continue;
                }
            }

            out.push(ch);
            idx += ch.len_utf8();
        }
        out
    }

    pub fn clean_xiaohongshu_body(text: &str) -> String {
        text.replace("[话题]#", "").trim().to_string()
    }

    // =========================================================================
    // Networking
    // =========================================================================

    fn build_candidate_fetch_urls(reference: &XiaohongshuNoteReference) -> Vec<Url> {
        let mut list = Vec::new();
        let mut seen = HashSet::new();
        let mut push_url = |u: Url| {
            if seen.insert(u.as_str().to_string()) {
                list.push(u);
            }
        };
        if let Ok(canon) = Url::parse(&reference.canonical_url()) {
            push_url(canon);
        }
        push_url(reference.source_url.clone());
        if let Some(ref note_id) = reference.note_id {
            if let Ok(mut disc) = Url::parse(&format!(
                "https://www.xiaohongshu.com/discovery/item/{note_id}"
            )) {
                let mut pairs = Vec::new();
                if let Some(ref t) = reference.xsec_token {
                    pairs.push(("xsec_token", t.as_str()));
                }
                if let Some(ref s) = reference.xsec_source {
                    pairs.push(("xsec_source", s.as_str()));
                }
                if !pairs.is_empty() {
                    disc.query_pairs_mut().extend_pairs(pairs);
                }
                push_url(disc);
            }
        }
        list
    }

    async fn resolve_short_link(url: &Url) -> Option<Url> {
        let client = Client::builder()
            .timeout(Duration::from_secs(10))
            .user_agent(XHS_BROWSER_UA)
            .redirect(reqwest::redirect::Policy::limited(8))
            .build()
            .ok()?;
        let resp = client
            .get(url.clone())
            .header("Accept-Language", "zh-CN,zh;q=0.9,en;q=0.8")
            .send()
            .await
            .ok()?;
        let final_url = resp.url().clone();
        WebBookmarkResolver::is_web_url(&final_url).then_some(final_url)
    }

    async fn fetch_html(url: &Url) -> Option<(String, Url)> {
        let client = Client::builder()
            .timeout(Duration::from_secs(12))
            .user_agent(XHS_BROWSER_UA)
            .redirect(reqwest::redirect::Policy::limited(8))
            .build()
            .ok()?;
        let resp = client
            .get(url.clone())
            .header(
                "Accept",
                "text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8",
            )
            .header("Accept-Language", "zh-CN,zh;q=0.9,en;q=0.8")
            .header("Referer", XIAOHONGSHU_REFERER)
            .send()
            .await
            .ok()?;
        if !resp.status().is_success() {
            return None;
        }
        let final_url = resp.url().clone();
        let bytes = resp.bytes().await.ok()?;
        if bytes.is_empty() {
            return None;
        }
        let capped = &bytes[..bytes.len().min(MAX_XHS_HTML_BYTES)];
        let html = String::from_utf8_lossy(capped).into_owned();
        Some((html, final_url))
    }
}

// =============================================================================
// Referer-Injecting Xiaohongshu Media Proxy & Disk Cache (`charkle-media://localhost/proxy-xhs`)
// =============================================================================

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct XhsProxyResponse {
    pub bytes: Vec<u8>,
    pub content_type: String,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub enum XhsProxyError {
    BadRequest(&'static str),
    Forbidden(&'static str),
    TooLarge,
    Upstream(String),
}

/// Validates that a proxy target URL is strictly `https://` on an allowlisted Xiaohongshu CDN host
/// (`*.xhscdn.com`, `xhscdn.com`, `*.xiaohongshu.com`, `xiaohongshu.com`), preventing SSRF.
pub fn validate_xhs_proxy_url(raw_url: &str) -> Result<Url, XhsProxyError> {
    let trimmed = raw_url.trim();
    if trimmed.is_empty() {
        return Err(XhsProxyError::BadRequest("Missing url parameter"));
    }
    let parsed = Url::parse(trimmed).map_err(|_| XhsProxyError::BadRequest("Invalid url"))?;
    if parsed.scheme() != "https" {
        return Err(XhsProxyError::Forbidden(
            "Only HTTPS Xiaohongshu URLs allowed",
        ));
    }
    if !parsed.username().is_empty() || parsed.password().is_some() {
        return Err(XhsProxyError::Forbidden(
            "Credentials not allowed in proxy URL",
        ));
    }
    if !XiaohongshuURLParser::is_xiaohongshu_media_host(parsed.host_str()) {
        return Err(XhsProxyError::Forbidden(
            "Host not in Xiaohongshu CDN allowlist",
        ));
    }
    Ok(parsed)
}

/// Computes the deterministic SHA-256 cache filename stem for a normalized proxy URL.
pub fn xhs_proxy_cache_key(normalized_url: &str) -> String {
    hex::encode(Sha256::digest(normalized_url.as_bytes()))
}

/// Fetches a Xiaohongshu CDN asset with `Referer: https://www.xiaohongshu.com/`, caching bytes
/// under `cache_dir/<sha256>.bin` (max 20 MiB, 10s timeout).
pub async fn fetch_or_cache_xhs_media(
    raw_url: &str,
    cache_dir: &Path,
) -> Result<XhsProxyResponse, XhsProxyError> {
    let url = validate_xhs_proxy_url(raw_url)?;
    let hash = xhs_proxy_cache_key(url.as_str());
    let bin_path = cache_dir.join(format!("{hash}.bin"));
    let ct_path = cache_dir.join(format!("{hash}.ct"));

    if let Ok(cached_bytes) = tokio::fs::read(&bin_path).await {
        if !cached_bytes.is_empty() && cached_bytes.len() <= MAX_XHS_PROXY_BYTES {
            let content_type = tokio::fs::read_to_string(&ct_path)
                .await
                .ok()
                .map(|s| s.trim().to_string())
                .filter(|s| !s.is_empty())
                .unwrap_or_else(|| {
                    sniff_media_content_type(&cached_bytes, url.as_str()).to_string()
                });
            return Ok(XhsProxyResponse {
                bytes: cached_bytes,
                content_type,
            });
        }
    }

    let client = Client::builder()
        .timeout(Duration::from_secs(10))
        .user_agent(XHS_BROWSER_UA)
        .redirect(reqwest::redirect::Policy::limited(5))
        .build()
        .map_err(|e| XhsProxyError::Upstream(e.to_string()))?;

    let resp = client
        .get(url.clone())
        .header("Referer", XIAOHONGSHU_REFERER)
        .header(
            "Accept",
            "image/avif,image/webp,image/png,image/jpeg,video/mp4,*/*;q=0.8",
        )
        .send()
        .await
        .map_err(|e| XhsProxyError::Upstream(e.to_string()))?;

    // Guard against open redirects escaping the Xiaohongshu CDN allowlist.
    if resp.url().scheme() != "https"
        || !XiaohongshuURLParser::is_xiaohongshu_media_host(resp.url().host_str())
    {
        return Err(XhsProxyError::Forbidden(
            "Redirected host outside Xiaohongshu CDN allowlist",
        ));
    }

    if !resp.status().is_success() {
        return Err(XhsProxyError::Upstream(format!(
            "Upstream status {}",
            resp.status().as_u16()
        )));
    }

    if let Some(len) = resp.content_length() {
        if len as usize > MAX_XHS_PROXY_BYTES {
            return Err(XhsProxyError::TooLarge);
        }
    }

    let header_ct = resp
        .headers()
        .get(reqwest::header::CONTENT_TYPE)
        .and_then(|v| v.to_str().ok())
        .map(|s| s.split(';').next().unwrap_or(s).trim().to_string())
        .filter(|s| !s.is_empty());

    let bytes = resp
        .bytes()
        .await
        .map_err(|e| XhsProxyError::Upstream(e.to_string()))?;
    if bytes.is_empty() {
        return Err(XhsProxyError::Upstream("Empty upstream body".to_string()));
    }
    if bytes.len() > MAX_XHS_PROXY_BYTES {
        return Err(XhsProxyError::TooLarge);
    }

    let content_type =
        header_ct.unwrap_or_else(|| sniff_media_content_type(&bytes, url.as_str()).to_string());
    let vec_bytes = bytes.to_vec();

    // Persist cache atomically (best-effort; never fail request on disk cache write error).
    if tokio::fs::create_dir_all(cache_dir).await.is_ok() {
        let tmp_bin: PathBuf = cache_dir.join(format!("{hash}.bin.tmp"));
        if tokio::fs::write(&tmp_bin, &vec_bytes).await.is_ok() {
            let _ = tokio::fs::rename(&tmp_bin, &bin_path).await;
        }
        let _ = tokio::fs::write(&ct_path, content_type.as_bytes()).await;
    }

    Ok(XhsProxyResponse {
        bytes: vec_bytes,
        content_type,
    })
}

fn sniff_media_content_type(bytes: &[u8], url_str: &str) -> &'static str {
    if bytes.starts_with(b"\x89PNG\r\n\x1a\n") {
        return "image/png";
    }
    if bytes.starts_with(&[0xFF, 0xD8, 0xFF]) {
        return "image/jpeg";
    }
    if bytes.len() >= 12 && &bytes[0..4] == b"RIFF" && &bytes[8..12] == b"WEBP" {
        return "image/webp";
    }
    if bytes.starts_with(b"GIF8") {
        return "image/gif";
    }
    if bytes.len() >= 12 && &bytes[4..8] == b"ftyp" {
        let brand = &bytes[8..12];
        if brand == b"avif" || brand == b"avis" {
            return "image/avif";
        }
        return "video/mp4";
    }
    let lower = url_str.to_ascii_lowercase();
    if lower.contains(".mp4") {
        "video/mp4"
    } else if lower.contains(".png") {
        "image/png"
    } else if lower.contains(".webp") {
        "image/webp"
    } else {
        "image/jpeg"
    }
}

// =============================================================================
// JSON & HTML Helper Functions
// =============================================================================

fn extract_initial_state_json(html: &str) -> Option<String> {
    const MARKERS: [&str; 2] = ["window.__INITIAL_STATE__=", "window.__INITIAL_STATE__ ="];
    for marker in MARKERS {
        let Some(pos) = html.find(marker) else {
            continue;
        };
        let mut cursor = pos + marker.len();
        while cursor < html.len() {
            let Some(c) = html[cursor..].chars().next() else {
                break;
            };
            if c.is_whitespace() {
                cursor += c.len_utf8();
            } else {
                break;
            }
        }
        if !html[cursor..].starts_with('{') {
            continue;
        }

        let mut depth = 0i32;
        let mut in_string = false;
        let mut escaped = false;
        for (rel, c) in html[cursor..].char_indices() {
            if in_string {
                if escaped {
                    escaped = false;
                } else if c == '\\' {
                    escaped = true;
                } else if c == '"' {
                    in_string = false;
                }
            } else {
                match c {
                    '"' => in_string = true,
                    '{' => depth += 1,
                    '}' => {
                        depth -= 1;
                        if depth == 0 {
                            let end = cursor + rel + 1;
                            return Some(html[cursor..end].to_string());
                        }
                    }
                    _ => {}
                }
            }
        }
    }
    None
}

fn locate_note_dictionary<'a>(root: &'a Value, expected_id: Option<&str>) -> Option<&'a Value> {
    // Shape 1: desktop web `root.note.noteDetailMap[noteId].note`
    if let Some(note_section) = root.get("note") {
        if let Some(detail_map) = note_section.get("noteDetailMap").and_then(Value::as_object) {
            if let Some(id) = expected_id {
                if let Some(note) = detail_map.get(id).and_then(|e| e.get("note")) {
                    if note.is_object() {
                        return Some(note);
                    }
                }
            }
            for entry in detail_map.values() {
                if let Some(note) = entry.get("note") {
                    if note.is_object()
                        && (note.get("title").is_some()
                            || note.get("desc").is_some()
                            || note.get("imageList").is_some())
                    {
                        return Some(note);
                    }
                }
            }
        }
        if let Some(direct) = note_section.get("note") {
            if direct.is_object() {
                return Some(direct);
            }
        }
    }
    // Shape 2: mobile web `root.noteData.data.noteData`
    if let Some(note_data) = root.get("noteData") {
        if let Some(inner) = note_data.get("data").and_then(|d| d.get("noteData")) {
            if inner.is_object() {
                return Some(inner);
            }
        }
        if note_data.is_object()
            && (note_data.get("title").is_some() || note_data.get("imageList").is_some())
        {
            return Some(note_data);
        }
    }
    None
}

fn extract_best_image_url(item: &Value) -> Option<String> {
    if let Some(info_list) = item.get("infoList").and_then(Value::as_array) {
        if let Some(dft) = info_list
            .iter()
            .find(|i| string_value(i.get("imageScene")).as_deref() == Some("WB_DFT"))
        {
            if let Some(url) = string_value(dft.get("url")).and_then(|s| upgraded_https_url(&s)) {
                return Some(url);
            }
        }
        for info in info_list {
            if let Some(url) = string_value(info.get("url")).and_then(|s| upgraded_https_url(&s)) {
                return Some(url);
            }
        }
    }
    for key in ["urlDefault", "url", "urlPre", "originalUrl"] {
        if let Some(url) = string_value(item.get(key)).and_then(|s| upgraded_https_url(&s)) {
            return Some(url);
        }
    }
    None
}

fn extract_preview_image_url(item: &Value) -> Option<String> {
    if let Some(info_list) = item.get("infoList").and_then(Value::as_array) {
        if let Some(prv) = info_list
            .iter()
            .find(|i| string_value(i.get("imageScene")).as_deref() == Some("WB_PRV"))
        {
            if let Some(url) = string_value(prv.get("url")).and_then(|s| upgraded_https_url(&s)) {
                return Some(url);
            }
        }
    }
    string_value(item.get("urlPre").or_else(|| item.get("urlDefault")))
        .and_then(|s| upgraded_https_url(&s))
}

fn extract_video_stream_url(video_obj: &Value) -> Option<String> {
    if let Some(stream) = video_obj.get("media").and_then(|m| m.get("stream")) {
        for codec in ["h264", "av1", "h265"] {
            if let Some(variants) = stream.get(codec).and_then(Value::as_array) {
                for v in variants {
                    if let Some(master) =
                        string_value(v.get("masterUrl")).and_then(|s| upgraded_https_url(&s))
                    {
                        return Some(master);
                    }
                    if let Some(backups) = v.get("backupUrls").and_then(Value::as_array) {
                        for b in backups {
                            if let Some(u) = b.as_str().and_then(upgraded_https_url) {
                                return Some(u);
                            }
                        }
                    }
                }
            }
        }
    }
    if let Some(origin_key) = video_obj
        .get("consumer")
        .and_then(|c| string_value(c.get("originVideoKey")))
    {
        let trimmed = origin_key.trim_matches('/');
        if !trimmed.is_empty() {
            return Some(format!("https://sns-video-bd.xhscdn.com/{trimmed}"));
        }
    }
    None
}

fn format_timestamp(raw: Option<&Value>) -> Option<String> {
    let val = raw?;
    let numeric = val
        .as_f64()
        .or_else(|| val.as_i64().map(|i| i as f64))
        .or_else(|| val.as_str().and_then(|s| s.trim().parse::<f64>().ok()))?;
    if numeric <= 1_000_000_000.0 {
        return None;
    }
    let secs = if numeric > 10_000_000_000.0 {
        (numeric / 1000.0).floor() as i64
    } else {
        numeric.floor() as i64
    };
    let dt = DateTime::<Utc>::from_timestamp(secs, 0)?;
    Some(dt.format("%Y-%m-%d %H:%M").to_string())
}

fn string_value(raw: Option<&Value>) -> Option<String> {
    let s = raw?.as_str()?.trim();
    (!s.is_empty()).then(|| s.to_string())
}

fn upgraded_https_url(raw: &str) -> Option<String> {
    let trimmed = raw.trim();
    if trimmed.is_empty() {
        return None;
    }
    let normalized = if trimmed.starts_with("//") {
        format!("https:{trimmed}")
    } else if trimmed.len() >= 7 && trimmed.as_bytes()[..7].eq_ignore_ascii_case(b"http://") {
        format!("https://{}", &trimmed[7..])
    } else {
        trimmed.to_string()
    };
    let url = Url::parse(&normalized).ok()?;
    WebBookmarkResolver::is_web_url(&url).then(|| url.to_string())
}

fn is_placeholder_asset(url_str: &str) -> bool {
    let lower = url_str.to_ascii_lowercase();
    lower.contains("favicon") || lower.contains("xhs-logo") || lower.contains("fe-platform/logo")
}

fn clean_page_title(raw: &str) -> String {
    let mut title = raw.trim();
    for suffix in [" - 小红书", " - 小红书网页版", " | 小红书"] {
        if let Some(stripped) = title.strip_suffix(suffix) {
            title = stripped.trim();
        }
    }
    title.to_string()
}

fn is_blocked_interstitial_title(title: &str) -> bool {
    let trimmed = title.trim();
    if trimmed.is_empty() {
        return true;
    }
    BLOCKED_TITLES
        .iter()
        .any(|blocked| trimmed.contains(blocked))
}

fn select_html_title(doc: &Html) -> Option<String> {
    let sel = Selector::parse("title").ok()?;
    let text = doc.select(&sel).next()?.text().collect::<String>();
    let trimmed = text.trim();
    (!trimmed.is_empty()).then(|| trimmed.to_string())
}

fn select_meta_all(doc: &Html, name: &str) -> Vec<String> {
    let Ok(sel) = Selector::parse("meta") else {
        return Vec::new();
    };
    let mut out = Vec::new();
    for el in doc.select(&sel) {
        let Some(key) = el
            .value()
            .attr("property")
            .or_else(|| el.value().attr("name"))
        else {
            continue;
        };
        if key.eq_ignore_ascii_case(name) {
            if let Some(content) = el.value().attr("content") {
                let trimmed = content.trim();
                if !trimmed.is_empty() {
                    out.push(trimmed.to_string());
                }
            }
        }
    }
    out
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn parses_xiaohongshu_urls_and_share_copy_preserving_xsec_token() {
        let explore = Url::parse(
            "https://www.xiaohongshu.com/explore/67a1b2c3d4e5f60718293a4b?xsec_token=AB123_xyz&xsec_source=pc_feed",
        )
        .unwrap();
        let parsed = XiaohongshuURLParser::parse(&explore).expect("explore URL");
        assert_eq!(parsed.note_id.as_deref(), Some("67a1b2c3d4e5f60718293a4b"));
        assert_eq!(parsed.xsec_token.as_deref(), Some("AB123_xyz"));
        assert_eq!(parsed.xsec_source.as_deref(), Some("pc_feed"));
        assert!(!parsed.is_short_link);
        assert_eq!(parsed.dedup_key(), "xhs:67a1b2c3d4e5f60718293a4b");
        assert!(parsed.canonical_url().contains("xsec_token=AB123_xyz"));
        assert!(parsed.canonical_url().contains("xsec_source=pc_feed"));

        // discovery/item and user/profile paths produce the exact same dedup key
        let discovery = Url::parse(
            "https://www.xiaohongshu.com/discovery/item/67A1B2C3D4E5F60718293A4B?xsec_token=ROTATED",
        )
        .unwrap();
        assert_eq!(
            XiaohongshuURLParser::parse(&discovery).unwrap().dedup_key(),
            "xhs:67a1b2c3d4e5f60718293a4b"
        );

        let profile_note = Url::parse(
            "https://www.xiaohongshu.com/user/profile/5f11223344556677889900aa/67a1b2c3d4e5f60718293a4b",
        )
        .unwrap();
        assert_eq!(
            XiaohongshuURLParser::parse(&profile_note)
                .unwrap()
                .note_id
                .as_deref(),
            Some("67a1b2c3d4e5f60718293a4b")
        );

        // Mobile share copy with xhslink.com short link
        let share_copy = "67 设计师小王发布了一篇小红书笔记，快来看吧！😆 http://xhslink.com/a/K9xYzAbC12 复制本条信息，打开【小红书】App查看精彩内容！";
        let extracted = XiaohongshuURLParser::extract_note_url(share_copy).expect("short link");
        assert_eq!(extracted.as_str(), "http://xhslink.com/a/K9xYzAbC12");
        let short_ref = XiaohongshuURLParser::parse(&extracted).expect("short ref");
        assert!(short_ref.is_short_link);
        assert!(short_ref.note_id.is_none());

        // CJK-glued URL with zero spaces
        let glued = "推荐看这篇https://www.xiaohongshu.com/explore/67a1b2c3d4e5f60718293a4b超赞！";
        assert_eq!(
            XiaohongshuURLParser::extract_note_url(glued)
                .unwrap()
                .as_str(),
            "https://www.xiaohongshu.com/explore/67a1b2c3d4e5f60718293a4b"
        );
    }

    #[test]
    fn sanitizes_js_undefined_only_outside_string_literals() {
        let raw = r#"{"a":undefined,"b":"keep undefined inside string","c":[undefined,1,"x\"undefined\""],"undefinedKey":undefined,"notUndefined":true}"#;
        let sanitized = XiaohongshuPostResolver::sanitize_js_undefined(raw);
        let parsed: Value = serde_json::from_str(&sanitized).expect("valid JSON after sanitize");
        assert!(parsed["a"].is_null());
        assert_eq!(parsed["b"].as_str(), Some("keep undefined inside string"));
        assert!(parsed["c"][0].is_null());
        assert_eq!(parsed["c"][1].as_i64(), Some(1));
        assert_eq!(parsed["c"][2].as_str(), Some("x\"undefined\""));
        assert!(parsed["undefinedKey"].is_null());
        assert_eq!(parsed["notUndefined"].as_bool(), Some(true));
    }

    #[test]
    fn parses_chinese_metric_counts_accurately() {
        assert_eq!(
            XiaohongshuPostResolver::parse_chinese_metric_str("128"),
            Some(128)
        );
        assert_eq!(
            XiaohongshuPostResolver::parse_chinese_metric_str("1,234"),
            Some(1234)
        );
        assert_eq!(
            XiaohongshuPostResolver::parse_chinese_metric_str("1.2万"),
            Some(12_000)
        );
        assert_eq!(
            XiaohongshuPostResolver::parse_chinese_metric_str("10万+"),
            Some(100_000)
        );
        assert_eq!(
            XiaohongshuPostResolver::parse_chinese_metric_str("3.4千"),
            Some(3_400)
        );
        assert_eq!(
            XiaohongshuPostResolver::parse_chinese_metric_str("2.5w"),
            Some(25_000)
        );
        assert_eq!(
            XiaohongshuPostResolver::parse_chinese_metric_count(&serde_json::json!(42)),
            Some(42)
        );
        assert_eq!(
            XiaohongshuPostResolver::parse_chinese_metric_str("赞"),
            None
        );
    }

    #[test]
    fn parses_initial_state_carousel_tags_and_meta_fallback() {
        let url = Url::parse(
            "https://www.xiaohongshu.com/explore/67a1b2c3d4e5f60718293a4b?xsec_token=TOK99",
        )
        .unwrap();
        let note_ref = XiaohongshuURLParser::parse(&url).unwrap();
        let html = r#"<!doctype html><html><head><script>
window.__INITIAL_STATE__={"note":{"noteDetailMap":{"67a1b2c3d4e5f60718293a4b":{"note":{
  "noteId":"67a1b2c3d4e5f60718293a4b",
  "title":"极简纸感海报排版参考",
  "desc":"分享一组网格系统灵感 #平面设计[话题]# #排版[话题]#",
  "type":"normal",
  "time":1730000000000,
  "extra":undefined,
  "user":{"nickname":"版式实验室","userId":"5f11223344556677889900aa","avatar":"http://sns-avatar-qc.xhscdn.com/avatar/1.jpg"},
  "interactInfo":{"likedCount":"1.2万","commentCount":"86","collectedCount":"3.4千"},
  "tagList":[{"name":"平面设计"},{"name":"排版"}],
  "imageList":[
    {"infoList":[{"imageScene":"WB_PRV","url":"http://sns-webpic-qc.xhscdn.com/p1_prv.webp"},{"imageScene":"WB_DFT","url":"http://sns-webpic-qc.xhscdn.com/p1_dft.webp"}]},
    {"urlDefault":"//sns-webpic-qc.xhscdn.com/p2.webp"}
  ]
}}}}}</script></head></html>"#;

        let resolved =
            XiaohongshuPostResolver::parse_initial_state(html, &note_ref).expect("initial state");
        assert_eq!(resolved.metadata.platform, SocialPlatform::Xiaohongshu);
        assert_eq!(resolved.metadata.author_name, "版式实验室");
        assert_eq!(resolved.metadata.display_handle_line(), None);
        assert_eq!(
            resolved.metadata.article_title.as_deref(),
            Some("极简纸感海报排版参考")
        );
        assert_eq!(
            resolved.metadata.body_text,
            "分享一组网格系统灵感 #平面设计 #排版"
        );
        assert_eq!(resolved.metadata.like_count, Some(12_000));
        assert_eq!(resolved.metadata.reply_count, Some(86));
        assert_eq!(resolved.metadata.repost_count, Some(3_400));
        assert_eq!(resolved.metadata.attachments.len(), 2);
        assert_eq!(
            resolved.metadata.attachments[0].url,
            "https://sns-webpic-qc.xhscdn.com/p1_dft.webp"
        );
        assert_eq!(
            resolved.metadata.attachments[0].thumbnail_url.as_deref(),
            Some("https://sns-webpic-qc.xhscdn.com/p1_prv.webp")
        );
        assert_eq!(
            resolved.metadata.attachments[1].url,
            "https://sns-webpic-qc.xhscdn.com/p2.webp"
        );
        assert_eq!(resolved.extracted_tags, vec!["平面设计", "排版"]);
        assert!(resolved.metadata.original_url.contains("xsec_token=TOK99"));

        // Blocked interstitial HTML without images must return None
        let blocked_html =
            r#"<html><head><title>安全验证 - 小红书</title></head><body></body></html>"#;
        assert!(XiaohongshuPostResolver::parse_meta_fallback(blocked_html, &note_ref).is_none());

        // Valid OpenGraph fallback parses multi-image note cleanly
        let og_html = r#"<html><head>
            <meta property="og:title" content="柔和光影配色 - 小红书" />
            <meta property="og:description" content="暖灰与钴蓝配色 #色彩[话题]#" />
            <meta property="og:image" content="http://sns-webpic-qc.xhscdn.com/cover1.webp" />
            <meta property="og:image" content="https://sns-webpic-qc.xhscdn.com/favicon.ico" />
        </head></html>"#;
        let og = XiaohongshuPostResolver::parse_meta_fallback(og_html, &note_ref).expect("og");
        assert_eq!(og.metadata.article_title.as_deref(), Some("柔和光影配色"));
        assert_eq!(og.metadata.attachments.len(), 1);
        assert_eq!(
            og.metadata.attachments[0].url,
            "https://sns-webpic-qc.xhscdn.com/cover1.webp"
        );
    }

    #[test]
    fn validates_xhs_proxy_url_allowlist_strictly() {
        assert!(validate_xhs_proxy_url("https://sns-webpic-qc.xhscdn.com/abc.webp").is_ok());
        assert!(validate_xhs_proxy_url("https://sns-video-bd.xhscdn.com/stream/1.mp4").is_ok());
        assert!(validate_xhs_proxy_url("https://www.xiaohongshu.com/assets/a.png").is_ok());
        assert!(matches!(
            validate_xhs_proxy_url("http://sns-webpic-qc.xhscdn.com/abc.webp"),
            Err(XhsProxyError::Forbidden(_))
        ));
        assert!(matches!(
            validate_xhs_proxy_url("https://evil.com/x.png"),
            Err(XhsProxyError::Forbidden(_))
        ));
        assert!(matches!(
            validate_xhs_proxy_url("https://xhscdn.com.evil.com/x.png"),
            Err(XhsProxyError::Forbidden(_))
        ));
        assert!(matches!(
            validate_xhs_proxy_url("https://127.0.0.1:41937/api/v1/health"),
            Err(XhsProxyError::Forbidden(_))
        ));
        assert!(matches!(
            validate_xhs_proxy_url(""),
            Err(XhsProxyError::BadRequest(_))
        ));
    }
}
