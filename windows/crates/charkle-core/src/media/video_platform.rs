//! YouTube & Bilibili video bookmark resolver (zero-download default collection with cover,
//! duration, Bilibili WBI AI summary/outline, YouTube chapters/caption digest) and explicit
//! on-demand MP4 downloader (native progressive MP4 + optional Windows `yt-dlp` fallback).
//!
//! Mirrors `Sources/CharkleCore/Media/VideoPlatformResolver.swift`.

use std::collections::{BTreeMap, HashSet};
use std::path::{Path, PathBuf};
use std::sync::{Mutex, OnceLock};
use std::time::{Duration, Instant, SystemTime, UNIX_EPOCH};

use chrono::{DateTime, Utc};
use md5::{Digest as Md5Digest, Md5};
use reqwest::Client;
use serde::{Deserialize, Serialize};
use serde_json::{json, Value};
use url::Url;

use crate::error::{CoreError, CoreResult};
use crate::media::douyin::{DouyinURLParser, DOUYIN_REFERER};
use crate::media::resolvers::{ResolvedSocialPost, SocialPostResolver};
use crate::models::core::{
    SocialMediaAttachment, SocialMediaAttachmentKind, SocialPlatform, SocialPostMetadata,
    WebPageRichMetadata,
};

pub const STREAM_BROWSER_UA: &str = "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/131.0.0.0 Safari/537.36";
pub const STREAM_IOS_YOUTUBE_UA: &str =
    "com.google.ios.youtube/19.29.1 (iPhone16,2; U; CPU iOS 17_5_1 like Mac OS X;)";
pub const STREAM_ANDROID_YOUTUBE_UA: &str =
    "com.google.android.youtube/19.29.37 (Linux; U; Android 14) gzip";

const BROWSER_UA: &str = STREAM_BROWSER_UA;
const IOS_YOUTUBE_UA: &str = STREAM_IOS_YOUTUBE_UA;
const ANDROID_YOUTUBE_UA: &str = STREAM_ANDROID_YOUTUBE_UA;

/// Direct streaming media candidate (progressive HTTP Range MP4 or adaptive HLS `.m3u8`).
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct VideoDirectStream {
    pub url: String,
    #[serde(default)]
    pub http_headers: BTreeMap<String, String>,
    #[serde(default)]
    pub is_hls: bool,
}

/// Official embedded HTML5 player fallback (zero disk download).
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct VideoEmbedPlayer {
    pub url: String,
    pub referer: String,
    pub user_agent: Option<String>,
    pub use_iframe_wrapper: bool,
    pub embed_html: String,
}

/// Zero-download streaming playback descriptor for bookmarked video-site items
/// (YouTube, Bilibili, Vimeo, Dailymotion, and generic rich webpages with discovered video streams).
#[derive(Debug, Clone, Default, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct VideoStreamPlaybackPlan {
    #[serde(default)]
    pub direct_streams: Vec<VideoDirectStream>,
    pub embed_player: Option<VideoEmbedPlayer>,
    pub watch_url: Option<String>,
}

impl VideoStreamPlaybackPlan {
    pub fn has_playable_source(&self) -> bool {
        !self.direct_streams.is_empty() || self.embed_player.is_some()
    }
}

const MIXIN_KEY_ENC_TAB: [usize; 64] = [
    46, 47, 18, 2, 53, 8, 23, 32, 15, 50, 10, 31, 58, 3, 45, 35, 27, 43, 5, 49, 33, 9, 42, 19, 29,
    28, 14, 39, 12, 38, 41, 13, 37, 48, 7, 16, 24, 55, 40, 61, 26, 17, 0, 1, 60, 51, 30, 4, 22, 25,
    54, 21, 56, 59, 6, 63, 57, 62, 11, 36, 20, 34, 44, 52,
];

#[derive(Debug, Clone, PartialEq, Eq, Hash)]
pub enum VideoPlatformReference {
    Youtube {
        video_id: String,
        canonical_url: Url,
    },
    Bilibili {
        bvid: Option<String>,
        aid: Option<i64>,
        short_url: Option<Url>,
        page: Option<u32>,
        canonical_url: Url,
    },
}

impl VideoPlatformReference {
    pub fn platform(&self) -> SocialPlatform {
        match self {
            Self::Youtube { .. } => SocialPlatform::Youtube,
            Self::Bilibili { .. } => SocialPlatform::Bilibili,
        }
    }

    pub fn canonical_url(&self) -> &Url {
        match self {
            Self::Youtube { canonical_url, .. } | Self::Bilibili { canonical_url, .. } => {
                canonical_url
            }
        }
    }

    pub fn dedup_key(&self) -> String {
        match self {
            Self::Youtube { video_id, .. } => format!("yt:{video_id}"),
            Self::Bilibili {
                bvid,
                aid,
                short_url,
                page,
                canonical_url,
            } => {
                let page_suffix = match page {
                    Some(p) if *p > 1 => format!(":p{p}"),
                    _ => String::new(),
                };
                if let Some(bv) = bvid.as_deref().filter(|s| !s.is_empty()) {
                    return format!("bili:{bv}{page_suffix}");
                }
                if let Some(a) = aid {
                    return format!("bili:av{a}{page_suffix}");
                }
                let code = short_url
                    .as_ref()
                    .and_then(|u| u.path_segments()?.rfind(|s| !s.is_empty()))
                    .unwrap_or_else(|| canonical_url.as_str());
                format!("bili:short:{code}")
            }
        }
    }
}

pub struct VideoPlatformURLParser;

impl VideoPlatformURLParser {
    pub fn is_bilibili_media_host(host: Option<&str>) -> bool {
        let Some(raw) = host else { return false };
        let h = raw.trim().to_ascii_lowercase();
        h == "hdslb.com"
            || h.ends_with(".hdslb.com")
            || h == "bilivideo.com"
            || h.ends_with(".bilivideo.com")
            || h == "bilivideo.cn"
            || h.ends_with(".bilivideo.cn")
            || h == "bilibili.com"
            || h.ends_with(".bilibili.com")
    }

    pub fn is_youtube_media_host(host: Option<&str>) -> bool {
        let Some(raw) = host else { return false };
        let h = raw.trim().to_ascii_lowercase();
        h == "ytimg.com"
            || h.ends_with(".ytimg.com")
            || h == "ggpht.com"
            || h.ends_with(".ggpht.com")
    }

    pub fn parse(url: &Url) -> Option<VideoPlatformReference> {
        if !matches!(url.scheme(), "http" | "https") {
            return None;
        }
        let host = url.host_str()?.to_ascii_lowercase();
        let segments: Vec<&str> = url
            .path_segments()
            .map(|segs| segs.filter(|s| !s.is_empty()).collect())
            .unwrap_or_default();

        const YT_HOSTS: &[&str] = &[
            "youtube.com",
            "www.youtube.com",
            "m.youtube.com",
            "music.youtube.com",
            "youtu.be",
            "www.youtu.be",
            "youtube-nocookie.com",
            "www.youtube-nocookie.com",
        ];
        if YT_HOSTS.contains(&host.as_str()) {
            let video_id = Self::extract_youtube_video_id(&host, &segments, url)?;
            let canonical = Url::parse(&format!("https://www.youtube.com/watch?v={video_id}"))
                .unwrap_or_else(|_| url.clone());
            return Some(VideoPlatformReference::Youtube {
                video_id,
                canonical_url: canonical,
            });
        }

        const BILI_HOSTS: &[&str] = &["bilibili.com", "www.bilibili.com", "m.bilibili.com"];
        if BILI_HOSTS.contains(&host.as_str()) {
            let page = url
                .query_pairs()
                .find(|(k, _)| k.eq_ignore_ascii_case("p"))
                .and_then(|(_, v)| v.parse::<u32>().ok())
                .filter(|&p| p > 1);
            let suffix = page.map(|p| format!("?p={p}")).unwrap_or_default();
            for seg in &segments {
                if let Some(bvid) = Self::extract_bvid(seg) {
                    let canonical =
                        Url::parse(&format!("https://www.bilibili.com/video/{bvid}{suffix}"))
                            .unwrap_or_else(|_| url.clone());
                    return Some(VideoPlatformReference::Bilibili {
                        bvid: Some(bvid),
                        aid: None,
                        short_url: None,
                        page,
                        canonical_url: canonical,
                    });
                }
                if let Some(aid) = Self::extract_aid(seg) {
                    let canonical =
                        Url::parse(&format!("https://www.bilibili.com/video/av{aid}{suffix}"))
                            .unwrap_or_else(|_| url.clone());
                    return Some(VideoPlatformReference::Bilibili {
                        bvid: None,
                        aid: Some(aid),
                        short_url: None,
                        page,
                        canonical_url: canonical,
                    });
                }
            }
            return None;
        }

        const BILI_SHORT_HOSTS: &[&str] =
            &["b23.tv", "www.b23.tv", "bili2233.cn", "www.bili2233.cn"];
        if BILI_SHORT_HOSTS.contains(&host.as_str()) {
            let code = *segments.first()?;
            if code.is_empty() {
                return None;
            }
            if let Some(bvid) = Self::extract_bvid(code) {
                let canonical = Url::parse(&format!("https://www.bilibili.com/video/{bvid}"))
                    .unwrap_or_else(|_| url.clone());
                return Some(VideoPlatformReference::Bilibili {
                    bvid: Some(bvid),
                    aid: None,
                    short_url: Some(url.clone()),
                    page: None,
                    canonical_url: canonical,
                });
            }
            if let Some(aid) = Self::extract_aid(code) {
                let canonical = Url::parse(&format!("https://www.bilibili.com/video/av{aid}"))
                    .unwrap_or_else(|_| url.clone());
                return Some(VideoPlatformReference::Bilibili {
                    bvid: None,
                    aid: Some(aid),
                    short_url: Some(url.clone()),
                    page: None,
                    canonical_url: canonical,
                });
            }
            let canonical =
                Url::parse(&format!("https://b23.tv/{code}")).unwrap_or_else(|_| url.clone());
            return Some(VideoPlatformReference::Bilibili {
                bvid: None,
                aid: None,
                short_url: Some(canonical.clone()),
                page: None,
                canonical_url: canonical,
            });
        }

        None
    }

    pub fn is_valid_youtube_id(raw: &str) -> bool {
        raw.len() == 11
            && raw
                .bytes()
                .all(|b| b.is_ascii_alphanumeric() || b == b'_' || b == b'-')
    }

    fn extract_youtube_video_id(host: &str, segments: &[&str], url: &Url) -> Option<String> {
        if host == "youtu.be" || host == "www.youtu.be" {
            return segments
                .first()
                .copied()
                .filter(|s| Self::is_valid_youtube_id(s))
                .map(str::to_string);
        }
        if let Some((_, v)) = url.query_pairs().find(|(k, _)| k == "v") {
            if Self::is_valid_youtube_id(&v) {
                return Some(v.into_owned());
            }
        }
        if segments.len() >= 2 {
            let prefix = segments[0].to_ascii_lowercase();
            if matches!(prefix.as_str(), "shorts" | "live" | "embed" | "v")
                && Self::is_valid_youtube_id(segments[1])
            {
                return Some(segments[1].to_string());
            }
        }
        None
    }

    pub fn extract_bvid(segment: &str) -> Option<String> {
        let clean = segment.trim_matches('/');
        if clean.len() == 12
            && clean.starts_with("BV")
            && clean[2..].bytes().all(|b| b.is_ascii_alphanumeric())
        {
            Some(clean.to_string())
        } else {
            None
        }
    }

    pub fn extract_aid(segment: &str) -> Option<i64> {
        let lower = segment.trim_matches('/').to_ascii_lowercase();
        let digits = lower.strip_prefix("av")?;
        if !digits.is_empty() && digits.bytes().all(|b| b.is_ascii_digit()) {
            digits.parse::<i64>().ok()
        } else {
            None
        }
    }
}

#[derive(Clone)]
struct CachedWbiKeys {
    img_key: String,
    sub_key: String,
    fetched_at: Instant,
}

static WBI_CACHE: OnceLock<Mutex<Option<CachedWbiKeys>>> = OnceLock::new();

#[derive(Debug, Clone)]
struct BilibiliViewInfo {
    bvid: String,
    #[allow(dead_code)]
    aid: i64,
    cid: i64,
    title: String,
    desc: String,
    cover_url: Option<Url>,
    duration_seconds: f64,
    published_date_text: Option<String>,
    owner_name: String,
    owner_mid: i64,
    owner_face_url: Option<Url>,
    view_count: Option<i64>,
    like_count: Option<i64>,
    reply_count: Option<i64>,
    share_count: Option<i64>,
}

#[derive(Debug, Clone, Copy)]
enum YouTubeClientProfile {
    Ios,
    Android,
    TvEmbedded,
}

impl YouTubeClientProfile {
    fn client_context(self) -> Value {
        match self {
            Self::Ios => json!({
                "clientName": "IOS",
                "clientVersion": "19.29.1",
                "deviceMake": "Apple",
                "deviceModel": "iPhone16,2",
                "osName": "iPhone",
                "osVersion": "17.5.1.21F90",
                "hl": "zh-CN",
                "gl": "US"
            }),
            Self::Android => json!({
                "clientName": "ANDROID",
                "clientVersion": "19.29.37",
                "androidSdkVersion": 34,
                "hl": "zh-CN",
                "gl": "US"
            }),
            Self::TvEmbedded => json!({
                "clientName": "TVHTML5_SIMPLY_EMBEDDED_PLAYER",
                "clientVersion": "2.0",
                "hl": "zh-CN",
                "gl": "US"
            }),
        }
    }

    fn user_agent(self) -> &'static str {
        match self {
            Self::Ios => IOS_YOUTUBE_UA,
            Self::Android => ANDROID_YOUTUBE_UA,
            Self::TvEmbedded => BROWSER_UA,
        }
    }
}

pub struct VideoPlatformResolver;

impl VideoPlatformResolver {
    fn api_client() -> Client {
        Client::builder()
            .timeout(Duration::from_secs(12))
            .user_agent(BROWSER_UA)
            .redirect(crate::net_safety::public_redirect_policy(8, false))
            .build()
            .unwrap_or_else(|_| Client::new())
    }

    fn download_client() -> Client {
        Client::builder()
            .timeout(Duration::from_secs(240))
            .user_agent(BROWSER_UA)
            .redirect(crate::net_safety::public_redirect_policy(8, false))
            .build()
            .unwrap_or_else(|_| Client::new())
    }

    // MARK: - 1. Default Metadata + Cover + Video Summary Resolution (ZERO Video Download)

    pub async fn resolve(reference: &VideoPlatformReference) -> Option<ResolvedSocialPost> {
        match reference {
            VideoPlatformReference::Bilibili {
                bvid,
                aid,
                short_url,
                page,
                canonical_url,
            } => {
                Self::resolve_bilibili(bvid.clone(), *aid, short_url.as_ref(), *page, canonical_url)
                    .await
            }
            VideoPlatformReference::Youtube {
                video_id,
                canonical_url,
            } => Self::resolve_youtube(video_id, canonical_url).await,
        }
    }

    async fn resolve_bilibili(
        mut bvid: Option<String>,
        mut aid: Option<i64>,
        short_url: Option<&Url>,
        mut page: Option<u32>,
        fallback_canonical: &Url,
    ) -> Option<ResolvedSocialPost> {
        if bvid.is_none() && aid.is_none() {
            if let Some(su) = short_url {
                if let Some(expanded) = Self::expand_short_redirect(su).await {
                    if let Some(VideoPlatformReference::Bilibili {
                        bvid: rbv,
                        aid: raid,
                        page: rpage,
                        ..
                    }) = VideoPlatformURLParser::parse(&expanded)
                    {
                        bvid = rbv;
                        aid = raid;
                        page = page.or(rpage);
                    }
                }
            }
        }
        if bvid.is_none() && aid.is_none() {
            return None;
        }

        let info = Self::fetch_bilibili_view_info(bvid.as_deref(), aid, page).await?;
        let suffix = page
            .filter(|&p| p > 1)
            .map(|p| format!("?p={p}"))
            .unwrap_or_default();
        let canonical_url = Url::parse(&format!(
            "https://www.bilibili.com/video/{}{suffix}",
            info.bvid
        ))
        .unwrap_or_else(|_| fallback_canonical.clone());

        let (ai_summary, ai_outline) =
            Self::fetch_bilibili_ai_summary(&info.bvid, info.cid, info.owner_mid).await;
        let desc_chapters = Self::extract_timestamp_chapters(&info.desc);
        let final_outline = if !ai_outline.is_empty() {
            ai_outline
        } else {
            desc_chapters
        };

        let cover_str = info.cover_url.as_ref().map(|u| u.as_str().to_string());
        let attachment = SocialMediaAttachment::new(
            SocialMediaAttachmentKind::Video,
            canonical_url.as_str(),
            cover_str.clone(),
        );

        let metadata = SocialPostMetadata {
            platform: SocialPlatform::Bilibili,
            author_name: info.owner_name,
            author_handle: if info.owner_mid > 0 {
                format!("UP {}", info.owner_mid)
            } else {
                "bilibili".to_string()
            },
            author_avatar_url: info.owner_face_url.map(|u| u.to_string()),
            published_at_text: info.published_date_text,
            body_text: info.desc,
            quoted_author: None,
            quoted_text: None,
            article_title: Some(info.title),
            media_urls: cover_str.clone().into_iter().collect(),
            media_thumbnail_urls: cover_str.into_iter().collect(),
            attachments: vec![attachment],
            has_video: true,
            video_url: Some(canonical_url.to_string()),
            reply_count: info.reply_count,
            repost_count: info.share_count,
            like_count: info.like_count,
            view_count: info.view_count,
            original_url: canonical_url.to_string(),
            media_fetch_failed: false,
            video_duration_seconds: (info.duration_seconds > 0.0).then_some(info.duration_seconds),
            video_summary: ai_summary,
            video_outline: final_outline,
            video_id: Some(info.bvid),
            video_cid: (info.cid > 0).then_some(info.cid),
        };

        // STRICT ZERO-DOWNLOAD DEFAULT CONTRACT: leave primary_media_download_url = None
        Some(ResolvedSocialPost {
            metadata,
            primary_media_download_url: None,
            primary_media_kind: None,
            primary_thumbnail_url: info.cover_url.map(|u| u.to_string()),
            extracted_tags: Vec::new(),
        })
    }

    async fn fetch_bilibili_view_info(
        bvid: Option<&str>,
        aid: Option<i64>,
        page: Option<u32>,
    ) -> Option<BilibiliViewInfo> {
        let mut url = Url::parse("https://api.bilibili.com/x/web-interface/view").ok()?;
        if let Some(bv) = bvid.filter(|s| !s.is_empty()) {
            url.query_pairs_mut().append_pair("bvid", bv);
        } else {
            let a = aid?;
            url.query_pairs_mut().append_pair("aid", &a.to_string());
        }

        let resp = Self::api_client()
            .get(url)
            .header("Referer", "https://www.bilibili.com/")
            .send()
            .await
            .ok()?;
        if !resp.status().is_success() {
            return None;
        }
        let root: Value = resp.json().await.ok()?;
        if root.get("code").and_then(Value::as_i64) != Some(0) {
            return None;
        }
        let info = root.get("data")?.as_object()?;

        let resolved_bvid = info
            .get("bvid")
            .and_then(Value::as_str)
            .map(str::to_string)
            .or_else(|| bvid.map(str::to_string))
            .unwrap_or_default();
        let resolved_aid = parse_i64(info.get("aid")).or(aid).unwrap_or(0);
        let mut resolved_cid = parse_i64(info.get("cid")).unwrap_or(0);
        let mut resolved_dur = parse_i64(info.get("duration")).unwrap_or(0) as f64;

        if let Some(target_page) = page.filter(|&p| p > 1) {
            if let Some(pages) = info.get("pages").and_then(Value::as_array) {
                if let Some(matched) = pages
                    .iter()
                    .find(|p| parse_i64(p.get("page")) == Some(i64::from(target_page)))
                {
                    if let Some(pcid) = parse_i64(matched.get("cid")) {
                        resolved_cid = pcid;
                    }
                    if let Some(pdur) = parse_i64(matched.get("duration")).filter(|&d| d > 0) {
                        resolved_dur = pdur as f64;
                    }
                }
            }
        }

        let title = info
            .get("title")
            .and_then(Value::as_str)
            .map(str::trim)
            .unwrap_or("")
            .to_string();
        let raw_desc = info
            .get("desc")
            .and_then(Value::as_str)
            .map(str::trim)
            .unwrap_or("");
        let clean_desc = if raw_desc == "-" {
            String::new()
        } else {
            raw_desc.to_string()
        };
        let cover_url = normalized_https_url(info.get("pic").and_then(Value::as_str));

        let owner = info.get("owner").and_then(Value::as_object);
        let owner_name = owner
            .and_then(|o| o.get("name"))
            .and_then(Value::as_str)
            .map(str::trim)
            .filter(|s| !s.is_empty())
            .unwrap_or("B站 UP 主")
            .to_string();
        let owner_mid = owner.and_then(|o| parse_i64(o.get("mid"))).unwrap_or(0);
        let owner_face_url =
            normalized_https_url(owner.and_then(|o| o.get("face")).and_then(Value::as_str));

        let stat = info.get("stat").and_then(Value::as_object);
        let pub_date_text = parse_i64(info.get("pubdate"))
            .filter(|&ts| ts > 0)
            .and_then(|ts| DateTime::<Utc>::from_timestamp(ts, 0))
            .map(|dt| dt.format("%Y-%m-%d").to_string());

        let final_bvid = if resolved_bvid.is_empty() {
            format!("av{resolved_aid}")
        } else {
            resolved_bvid
        };

        Some(BilibiliViewInfo {
            bvid: final_bvid.clone(),
            aid: resolved_aid,
            cid: resolved_cid,
            title: if title.is_empty() { final_bvid } else { title },
            desc: clean_desc,
            cover_url,
            duration_seconds: resolved_dur,
            published_date_text: pub_date_text,
            owner_name,
            owner_mid,
            owner_face_url,
            view_count: stat.and_then(|s| parse_i64(s.get("view"))),
            like_count: stat.and_then(|s| parse_i64(s.get("like"))),
            reply_count: stat.and_then(|s| parse_i64(s.get("reply"))),
            share_count: stat.and_then(|s| parse_i64(s.get("share"))),
        })
    }

    async fn fetch_wbi_keys() -> Option<(String, String)> {
        let cache = WBI_CACHE.get_or_init(|| Mutex::new(None));
        if let Ok(guard) = cache.lock() {
            if let Some(ref entry) = *guard {
                if entry.fetched_at.elapsed() < Duration::from_secs(1800) {
                    return Some((entry.img_key.clone(), entry.sub_key.clone()));
                }
            }
        }

        let resp = Self::api_client()
            .get("https://api.bilibili.com/x/web-interface/nav")
            .header("Referer", "https://www.bilibili.com/")
            .send()
            .await
            .ok()?;
        if !resp.status().is_success() {
            return None;
        }
        let root: Value = resp.json().await.ok()?;
        let wbi_img = root.get("data")?.get("wbi_img")?.as_object()?;
        let img_url = wbi_img.get("img_url")?.as_str()?;
        let sub_url = wbi_img.get("sub_url")?.as_str()?;
        let extract_stem = |raw: &str| -> Option<String> {
            let u = Url::parse(raw).ok()?;
            let last = u.path_segments()?.next_back()?;
            let stem = last.rsplit_once('.').map(|(s, _)| s).unwrap_or(last);
            (!stem.is_empty()).then(|| stem.to_string())
        };
        let img_key = extract_stem(img_url)?;
        let sub_key = extract_stem(sub_url)?;

        if let Ok(mut guard) = cache.lock() {
            *guard = Some(CachedWbiKeys {
                img_key: img_key.clone(),
                sub_key: sub_key.clone(),
                fetched_at: Instant::now(),
            });
        }
        Some((img_key, sub_key))
    }

    /// Computes Bilibili WBI `wts` + `w_rid` (MD5) signed query pairs.
    pub fn sign_bilibili_wbi(
        params: &BTreeMap<String, String>,
        img_key: &str,
        sub_key: &str,
        timestamp: i64,
    ) -> Vec<(String, String)> {
        let combined: Vec<char> = format!("{img_key}{sub_key}").chars().collect();
        let mut mixin = String::with_capacity(32);
        for &idx in &MIXIN_KEY_ENC_TAB {
            if let Some(&ch) = combined.get(idx) {
                mixin.push(ch);
                if mixin.len() == 32 {
                    break;
                }
            }
        }

        let mut working = params.clone();
        working.insert("wts".to_string(), timestamp.to_string());

        let mut encoded_pairs = Vec::with_capacity(working.len());
        let mut out = Vec::with_capacity(working.len() + 1);
        for (k, v) in working {
            let filtered: String = v
                .chars()
                .filter(|c| !matches!(c, '!' | '\'' | '(' | ')' | '*'))
                .collect();
            encoded_pairs.push(format!(
                "{}={}",
                wbi_percent_encode(&k),
                wbi_percent_encode(&filtered)
            ));
            out.push((k, filtered));
        }

        let query_string = encoded_pairs.join("&");
        let mut hasher = Md5::new();
        hasher.update(format!("{query_string}{mixin}").as_bytes());
        let w_rid = hex::encode(hasher.finalize());
        out.push(("w_rid".to_string(), w_rid));
        out
    }

    async fn fetch_bilibili_ai_summary(
        bvid: &str,
        cid: i64,
        up_mid: i64,
    ) -> (Option<String>, Vec<String>) {
        if cid <= 0 {
            return (None, Vec::new());
        }
        let Some((img_key, sub_key)) = Self::fetch_wbi_keys().await else {
            return (None, Vec::new());
        };
        let mut params = BTreeMap::new();
        params.insert("bvid".to_string(), bvid.to_string());
        params.insert("cid".to_string(), cid.to_string());
        if up_mid > 0 {
            params.insert("up_mid".to_string(), up_mid.to_string());
        }
        let ts = SystemTime::now()
            .duration_since(UNIX_EPOCH)
            .map(|d| d.as_secs() as i64)
            .unwrap_or(0);
        let signed = Self::sign_bilibili_wbi(&params, &img_key, &sub_key, ts);

        let Ok(mut url) =
            Url::parse("https://api.bilibili.com/x/web-interface/view/conclusion/get")
        else {
            return (None, Vec::new());
        };
        {
            let mut qp = url.query_pairs_mut();
            for (k, v) in signed {
                qp.append_pair(&k, &v);
            }
        }

        let Ok(resp) = Self::api_client()
            .get(url)
            .header("Referer", format!("https://www.bilibili.com/video/{bvid}"))
            .send()
            .await
        else {
            return (None, Vec::new());
        };
        if !resp.status().is_success() {
            return (None, Vec::new());
        }
        let Ok(root) = resp.json::<Value>().await else {
            return (None, Vec::new());
        };
        if root.get("code").and_then(Value::as_i64) != Some(0) {
            return (None, Vec::new());
        }
        let Some(model_result) = root
            .get("data")
            .and_then(|d| d.get("model_result"))
            .and_then(Value::as_object)
        else {
            return (None, Vec::new());
        };

        let summary = model_result
            .get("summary")
            .and_then(Value::as_str)
            .map(str::trim)
            .filter(|s| !s.is_empty())
            .map(str::to_string);

        let mut outline_lines = Vec::new();
        if let Some(outlines) = model_result.get("outline").and_then(Value::as_array) {
            for section in outlines {
                if let Some(sec_title) = section
                    .get("title")
                    .and_then(Value::as_str)
                    .map(str::trim)
                    .filter(|s| !s.is_empty())
                {
                    let line = match parse_i64(section.get("timestamp")) {
                        Some(ts) => format!("{} {sec_title}", format_timestamp(ts)),
                        None => sec_title.to_string(),
                    };
                    outline_lines.push(line);
                }
                if let Some(parts) = section.get("part_outline").and_then(Value::as_array) {
                    for part in parts.iter().take(4) {
                        if let Some(content) = part
                            .get("content")
                            .and_then(Value::as_str)
                            .map(str::trim)
                            .filter(|s| !s.is_empty())
                        {
                            let line = match parse_i64(part.get("timestamp")) {
                                Some(ts) => format!("  · {} {content}", format_timestamp(ts)),
                                None => format!("  · {content}"),
                            };
                            outline_lines.push(line);
                        }
                    }
                }
                if outline_lines.len() >= 16 {
                    break;
                }
            }
        }
        outline_lines.truncate(16);
        (summary, outline_lines)
    }

    // MARK: - YouTube Metadata + Chapters + Caption Digest

    async fn resolve_youtube(video_id: &str, canonical_url: &Url) -> Option<ResolvedSocialPost> {
        let player =
            Self::fetch_youtube_player_response(video_id, YouTubeClientProfile::Android).await;
        let oembed = if player.is_none() {
            Self::fetch_youtube_oembed(canonical_url).await
        } else {
            None
        };

        let video_details = player
            .as_ref()
            .and_then(|p| p.get("videoDetails"))
            .and_then(Value::as_object);
        let microformat = player
            .as_ref()
            .and_then(|p| p.get("microformat"))
            .and_then(|m| m.get("playerMicroformatRenderer"))
            .and_then(Value::as_object);

        let title = video_details
            .and_then(|d| d.get("title"))
            .and_then(Value::as_str)
            .or_else(|| {
                oembed
                    .as_ref()
                    .and_then(|o| o.get("title"))
                    .and_then(Value::as_str)
            })
            .map(str::trim)
            .filter(|s| !s.is_empty())?
            .to_string();

        let author_name = video_details
            .and_then(|d| d.get("author"))
            .and_then(Value::as_str)
            .or_else(|| {
                oembed
                    .as_ref()
                    .and_then(|o| o.get("author_name"))
                    .and_then(Value::as_str)
            })
            .map(str::trim)
            .filter(|s| !s.is_empty())
            .unwrap_or("YouTube 频道")
            .to_string();

        let channel_id = video_details
            .and_then(|d| d.get("channelId"))
            .and_then(Value::as_str)
            .unwrap_or("")
            .to_string();
        let short_desc = video_details
            .and_then(|d| d.get("shortDescription"))
            .and_then(Value::as_str)
            .map(str::trim)
            .unwrap_or("")
            .to_string();
        let duration_seconds = video_details
            .and_then(|d| parse_f64(d.get("lengthSeconds")))
            .filter(|&d| d > 0.0);
        let view_count = video_details.and_then(|d| parse_i64(d.get("viewCount")));
        let publish_date = microformat
            .and_then(|m| m.get("publishDate").or_else(|| m.get("uploadDate")))
            .and_then(Value::as_str)
            .map(|s| s.chars().take(10).collect::<String>())
            .filter(|s| !s.is_empty());

        let cover_url = video_details
            .and_then(|d| d.get("thumbnail"))
            .and_then(|t| t.get("thumbnails"))
            .and_then(Value::as_array)
            .and_then(|thumbs| {
                thumbs
                    .iter()
                    .filter_map(|e| {
                        let u = normalized_https_url(e.get("url").and_then(Value::as_str))?;
                        let w = parse_i64(e.get("width")).unwrap_or(0);
                        Some((u, w))
                    })
                    .max_by_key(|(_, w)| *w)
                    .map(|(u, _)| u)
            })
            .or_else(|| {
                normalized_https_url(
                    oembed
                        .as_ref()
                        .and_then(|o| o.get("thumbnail_url"))
                        .and_then(Value::as_str),
                )
            })
            .or_else(|| {
                Url::parse(&format!("https://i.ytimg.com/vi/{video_id}/hqdefault.jpg")).ok()
            });

        let chapters = Self::extract_timestamp_chapters(&short_desc);
        let caption_digest = Self::fetch_youtube_caption_summary(player.as_ref()).await;
        let desc_digest = Self::extract_concise_description_lead(&short_desc);
        let summary_text = caption_digest.or(desc_digest);

        let cover_str = cover_url.as_ref().map(|u| u.as_str().to_string());
        let attachment = SocialMediaAttachment::new(
            SocialMediaAttachmentKind::Video,
            canonical_url.as_str(),
            cover_str.clone(),
        );

        let metadata = SocialPostMetadata {
            platform: SocialPlatform::Youtube,
            author_name: author_name.clone(),
            author_handle: if channel_id.is_empty() {
                author_name
            } else {
                channel_id
            },
            author_avatar_url: None,
            published_at_text: publish_date,
            body_text: short_desc,
            quoted_author: None,
            quoted_text: None,
            article_title: Some(title),
            media_urls: cover_str.clone().into_iter().collect(),
            media_thumbnail_urls: cover_str.into_iter().collect(),
            attachments: vec![attachment],
            has_video: true,
            video_url: Some(canonical_url.to_string()),
            reply_count: None,
            repost_count: None,
            like_count: None,
            view_count,
            original_url: canonical_url.to_string(),
            media_fetch_failed: false,
            video_duration_seconds: duration_seconds,
            video_summary: summary_text,
            video_outline: chapters,
            video_id: Some(video_id.to_string()),
            video_cid: None,
        };

        Some(ResolvedSocialPost {
            metadata,
            primary_media_download_url: None,
            primary_media_kind: None,
            primary_thumbnail_url: cover_url.map(|u| u.to_string()),
            extracted_tags: Vec::new(),
        })
    }

    async fn fetch_youtube_player_response(
        video_id: &str,
        profile: YouTubeClientProfile,
    ) -> Option<Value> {
        let context = match profile {
            YouTubeClientProfile::TvEmbedded => json!({
                "client": profile.client_context(),
                "thirdParty": { "embedUrl": "https://www.youtube.com/" }
            }),
            _ => json!({
                "client": profile.client_context()
            }),
        };
        let body = json!({
            "context": context,
            "videoId": video_id,
            "contentCheckOk": true,
            "racyCheckOk": true
        });
        let resp = Self::api_client()
            .post("https://www.youtube.com/youtubei/v1/player?prettyPrint=false")
            .header("User-Agent", profile.user_agent())
            .header("Origin", "https://www.youtube.com")
            .json(&body)
            .send()
            .await
            .ok()?;
        if !resp.status().is_success() {
            return None;
        }
        resp.json::<Value>().await.ok()
    }

    async fn fetch_youtube_oembed(canonical_url: &Url) -> Option<Value> {
        let mut url = Url::parse("https://www.youtube.com/oembed").ok()?;
        url.query_pairs_mut()
            .append_pair("url", canonical_url.as_str())
            .append_pair("format", "json");
        let resp = Self::api_client().get(url).send().await.ok()?;
        if !resp.status().is_success() {
            return None;
        }
        resp.json::<Value>().await.ok()
    }

    async fn fetch_youtube_caption_summary(player_payload: Option<&Value>) -> Option<String> {
        let tracks = player_payload?
            .get("captions")?
            .get("playerCaptionsTracklistRenderer")?
            .get("captionTracks")?
            .as_array()?;
        if tracks.is_empty() {
            return None;
        }
        let lang_of = |t: &Value| {
            t.get("languageCode")
                .and_then(Value::as_str)
                .unwrap_or("")
                .to_ascii_lowercase()
        };
        let is_asr = |t: &Value| t.get("kind").and_then(Value::as_str) == Some("asr");

        let preferred = tracks
            .iter()
            .find(|t| lang_of(t).starts_with("zh") && !is_asr(t))
            .or_else(|| tracks.iter().find(|t| lang_of(t).starts_with("zh")))
            .or_else(|| {
                tracks
                    .iter()
                    .find(|t| lang_of(t).starts_with("en") && !is_asr(t))
            })
            .or_else(|| tracks.iter().find(|t| lang_of(t).starts_with("en")))
            .or_else(|| tracks.first())?;

        let base_str = preferred.get("baseUrl")?.as_str()?;
        let mut caption_url = Url::parse(base_str).ok()?;
        if !SocialPostResolver::is_safe_public_media_url(&caption_url) {
            return None;
        }
        if !caption_url.query_pairs().any(|(k, _)| k == "fmt") {
            caption_url.query_pairs_mut().append_pair("fmt", "json3");
        }

        let resp = Self::api_client().get(caption_url).send().await.ok()?;
        if !resp.status().is_success() {
            return None;
        }
        let bytes = resp.bytes().await.ok()?;
        if bytes.is_empty() || bytes.len() > 2 * 1024 * 1024 {
            return None;
        }

        let mut pieces: Vec<String> = Vec::new();
        if let Ok(json) = serde_json::from_slice::<Value>(&bytes) {
            if let Some(events) = json.get("events").and_then(Value::as_array) {
                for ev in events {
                    let Some(segs) = ev.get("segs").and_then(Value::as_array) else {
                        continue;
                    };
                    let line: String = segs
                        .iter()
                        .filter_map(|s| s.get("utf8").and_then(Value::as_str))
                        .collect::<String>()
                        .replace('\n', " ");
                    let clean = line.trim();
                    if !clean.is_empty() && pieces.last().map(String::as_str) != Some(clean) {
                        pieces.push(clean.to_string());
                    }
                    if pieces.len() >= 48 {
                        break;
                    }
                }
            }
        }
        if pieces.is_empty() {
            return None;
        }
        let joined = pieces
            .join(" ")
            .split_whitespace()
            .collect::<Vec<_>>()
            .join(" ");
        if joined.chars().count() < 16 {
            return None;
        }
        if joined.chars().count() > 360 {
            let prefix: String = joined.chars().take(356).collect();
            Some(format!("{}…", prefix.trim()))
        } else {
            Some(joined)
        }
    }

    // MARK: - 1.5 Zero-Download Inline Streaming Playback Plan (Preview-Time Only)

    /// Resolves an inline zero-download streaming plan for a bookmarked social/video post:
    /// - Tier 1: Direct progressive HTTP Range MP4 / HLS `.m3u8` streams with required site headers
    ///   (`Referer`, `User-Agent`), proxied via `charkle-media://localhost/proxy-video-stream`.
    /// - Tier 2: Official embedded HTML5 player fallback (YouTube embed with valid origin &
    ///   `strict-origin-when-cross-origin` Referer to prevent Error 153, Bilibili HTML5 player,
    ///   Vimeo, Dailymotion, or explicit `/embed/` player URLs).
    pub async fn resolve_playback_plan(post: &SocialPostMetadata) -> VideoStreamPlaybackPlan {
        let watch_url = Url::parse(post.original_url.trim()).ok();
        match post.platform {
            SocialPlatform::Bilibili => {
                Self::resolve_bilibili_playback_plan(post, watch_url.as_ref()).await
            }
            SocialPlatform::Youtube => {
                Self::resolve_youtube_playback_plan(post, watch_url.as_ref()).await
            }
            SocialPlatform::Douyin => {
                Self::resolve_douyin_playback_plan(post, watch_url.as_ref()).await
            }
            _ => {
                let mut direct_streams = Vec::new();
                let mut seen = HashSet::new();
                let mut headers = BTreeMap::new();
                headers.insert("User-Agent".to_string(), BROWSER_UA.to_string());
                if post.platform == SocialPlatform::Xiaohongshu {
                    headers.insert(
                        "Referer".to_string(),
                        "https://www.xiaohongshu.com/".to_string(),
                    );
                } else if let Some(ref w) = watch_url {
                    headers.insert("Referer".to_string(), w.to_string());
                }
                for att in post.effective_attachments() {
                    if !matches!(
                        att.kind,
                        SocialMediaAttachmentKind::Video | SocialMediaAttachmentKind::Gif
                    ) {
                        continue;
                    }
                    let Ok(u) = Url::parse(att.url.trim()) else {
                        continue;
                    };
                    if !SocialPostResolver::is_safe_public_media_url(&u) {
                        continue;
                    }
                    if seen.insert(u.as_str().to_string()) {
                        let is_hls = is_hls_url(&u);
                        direct_streams.push(VideoDirectStream {
                            url: u.to_string(),
                            http_headers: headers.clone(),
                            is_hls,
                        });
                    }
                }
                let embed_player = watch_url
                    .as_ref()
                    .and_then(|u| Self::embed_player(u, None, None));
                VideoStreamPlaybackPlan {
                    direct_streams,
                    embed_player,
                    watch_url: watch_url.map(|u| u.to_string()),
                }
            }
        }
    }

    /// Resolves an inline zero-download streaming plan for Douyin video bookmarks:
    /// prefers fresh direct CDN streams captured by the extension (with Douyin `Referer`),
    /// and automatically falls back to `yt-dlp -g` when the stored stream is missing or its
    /// signed `x-expires` timestamp has expired.
    async fn resolve_douyin_playback_plan(
        post: &SocialPostMetadata,
        watch_url: Option<&Url>,
    ) -> VideoStreamPlaybackPlan {
        let mut headers = BTreeMap::new();
        headers.insert("User-Agent".to_string(), BROWSER_UA.to_string());
        headers.insert("Referer".to_string(), DOUYIN_REFERER.to_string());

        let now_unix = Utc::now().timestamp();
        let mut fresh_streams = Vec::new();
        let mut expired_streams = Vec::new();
        let mut seen = HashSet::new();

        for att in post.effective_attachments() {
            if !matches!(
                att.kind,
                SocialMediaAttachmentKind::Video | SocialMediaAttachmentKind::Gif
            ) {
                continue;
            }
            let Ok(u) = Url::parse(att.url.trim()) else {
                continue;
            };
            if !SocialPostResolver::is_safe_public_media_url(&u) {
                continue;
            }
            // Skip canonical watch-page URLs (`/video/<id>`) — those are HTML pages, not streams.
            if DouyinURLParser::parse(&u).is_some()
                && !u.path().to_ascii_lowercase().contains("/aweme/v1/play")
            {
                continue;
            }
            if !seen.insert(u.as_str().to_string()) {
                continue;
            }
            let stream = VideoDirectStream {
                url: u.to_string(),
                http_headers: headers.clone(),
                is_hls: is_hls_url(&u),
            };
            if DouyinURLParser::is_stream_url_expired(&u, now_unix) {
                expired_streams.push(stream);
            } else {
                fresh_streams.push(stream);
            }
        }

        let mut direct_streams = fresh_streams;
        if direct_streams.is_empty() {
            if let Some(page_url) = watch_url {
                if let Some(mut ytdlp_stream) =
                    Self::resolve_direct_stream_via_yt_dlp_if_available(page_url.as_str()).await
                {
                    ytdlp_stream
                        .http_headers
                        .entry("Referer".to_string())
                        .or_insert_with(|| DOUYIN_REFERER.to_string());
                    ytdlp_stream
                        .http_headers
                        .entry("User-Agent".to_string())
                        .or_insert_with(|| BROWSER_UA.to_string());
                    if seen.insert(ytdlp_stream.url.clone()) {
                        direct_streams.push(ytdlp_stream);
                    }
                }
            }
        }
        // Keep any expired URL at the tail as a last-resort fallback in case of local clock skew.
        direct_streams.extend(expired_streams);

        VideoStreamPlaybackPlan {
            direct_streams,
            embed_player: None,
            watch_url: watch_url.map(|u| u.to_string()),
        }
    }

    /// Resolves an inline zero-download streaming plan for any generic rich webpage bookmark
    /// (`WebPageRichMetadata`).
    pub async fn resolve_web_page_playback_plan(
        web: &WebPageRichMetadata,
        fallback_url: Option<&Url>,
    ) -> VideoStreamPlaybackPlan {
        let canonical = web
            .canonical_url
            .as_deref()
            .and_then(|s| Url::parse(s.trim()).ok())
            .or_else(|| fallback_url.cloned());

        let mut direct_streams = Vec::new();
        let mut seen = HashSet::new();
        let mut embed_candidate = canonical
            .as_ref()
            .and_then(|u| Self::embed_player(u, None, None));

        let mut headers = BTreeMap::new();
        headers.insert("User-Agent".to_string(), BROWSER_UA.to_string());
        if let Some(ref c) = canonical {
            headers.insert("Referer".to_string(), c.to_string());
        }

        for att in &web.attachments {
            if att.kind != SocialMediaAttachmentKind::Video {
                continue;
            }
            let Ok(u) = Url::parse(att.url.trim()) else {
                continue;
            };
            if !SocialPostResolver::is_safe_public_media_url(&u) {
                continue;
            }
            if Self::looks_like_direct_video_stream_url(&u) {
                if seen.insert(u.as_str().to_string()) {
                    let is_hls = is_hls_url(&u);
                    direct_streams.push(VideoDirectStream {
                        url: u.to_string(),
                        http_headers: headers.clone(),
                        is_hls,
                    });
                }
            } else if embed_candidate.is_none() {
                embed_candidate = Self::embed_player(&u, None, None);
            }
        }

        if direct_streams.is_empty() && web.has_video {
            if let Some(ref page_url) = canonical {
                if let Some(ytdlp_stream) =
                    Self::resolve_direct_stream_via_yt_dlp_if_available(page_url.as_str()).await
                {
                    direct_streams.push(ytdlp_stream);
                }
            }
        }

        VideoStreamPlaybackPlan {
            direct_streams,
            embed_player: embed_candidate,
            watch_url: canonical.map(|u| u.to_string()),
        }
    }

    /// Pure URL recognizer returning a clean embed player descriptor for major video platforms
    /// (YouTube, Bilibili, Vimeo, Dailymotion, or explicit `/embed/` player URLs).
    pub fn embed_player(
        url: &Url,
        bvid_override: Option<&str>,
        cid_override: Option<i64>,
    ) -> Option<VideoEmbedPlayer> {
        if !SocialPostResolver::is_safe_public_media_url(url) {
            return None;
        }
        let host = url.host_str()?.to_ascii_lowercase();

        if let Some(parsed) = VideoPlatformURLParser::parse(url) {
            match parsed {
                VideoPlatformReference::Youtube { video_id, .. } => {
                    // Supply `origin=https://charkle.app` + matching Referer policy to avoid YouTube Error 153.
                    let embed_str = format!(
                        "https://www.youtube.com/embed/{video_id}?autoplay=1&playsinline=1&rel=0&modestbranding=1&origin=https://charkle.app"
                    );
                    let referer = "https://charkle.app".to_string();
                    let (embed_html, _) = Self::embed_html(&embed_str, &referer);
                    return Some(VideoEmbedPlayer {
                        url: embed_str,
                        referer,
                        user_agent: Some(BROWSER_UA.to_string()),
                        use_iframe_wrapper: true,
                        embed_html,
                    });
                }
                VideoPlatformReference::Bilibili {
                    bvid: parsed_bv,
                    aid: parsed_aid,
                    page,
                    ..
                } => {
                    let mut items: Vec<(String, String)> = Vec::new();
                    let chosen_bv = bvid_override
                        .map(str::trim)
                        .filter(|s| !s.is_empty())
                        .map(str::to_string)
                        .or(parsed_bv);
                    if let Some(bv) = chosen_bv {
                        items.push(("bvid".to_string(), bv));
                    } else if let Some(aid) = parsed_aid {
                        items.push(("aid".to_string(), aid.to_string()));
                    }
                    if let Some(cid) = cid_override.filter(|&c| c > 0) {
                        items.push(("cid".to_string(), cid.to_string()));
                    }
                    if let Some(p) = page.filter(|&p| p > 1) {
                        items.push(("page".to_string(), p.to_string()));
                    }
                    if !items.is_empty() {
                        items.push(("autoplay".to_string(), "1".to_string()));
                        items.push(("danmaku".to_string(), "0".to_string()));
                        items.push(("high_quality".to_string(), "1".to_string()));
                        if let Ok(mut embed_url) =
                            Url::parse("https://player.bilibili.com/player.html")
                        {
                            {
                                let mut qp = embed_url.query_pairs_mut();
                                for (k, v) in items {
                                    qp.append_pair(&k, &v);
                                }
                            }
                            let embed_str = embed_url.to_string();
                            let referer = "https://www.bilibili.com/".to_string();
                            let (embed_html, _) = Self::embed_html(&embed_str, &referer);
                            return Some(VideoEmbedPlayer {
                                url: embed_str,
                                referer,
                                user_agent: Some(BROWSER_UA.to_string()),
                                use_iframe_wrapper: true,
                                embed_html,
                            });
                        }
                    }
                }
            }
        }

        let segments: Vec<&str> = url
            .path_segments()
            .map(|segs| segs.filter(|s| !s.is_empty()).collect())
            .unwrap_or_default();

        // Vimeo (`vimeo.com/<digits>` or `player.vimeo.com/video/<digits>`)
        if matches!(
            host.as_str(),
            "vimeo.com" | "www.vimeo.com" | "player.vimeo.com"
        ) {
            if let Some(numeric_id) = segments
                .iter()
                .rev()
                .copied()
                .find(|s| s.len() >= 5 && s.bytes().all(|b| b.is_ascii_digit()))
            {
                let embed_str =
                    format!("https://player.vimeo.com/video/{numeric_id}?autoplay=1&playsinline=1");
                let referer = "https://vimeo.com/".to_string();
                let (embed_html, _) = Self::embed_html(&embed_str, &referer);
                return Some(VideoEmbedPlayer {
                    url: embed_str,
                    referer,
                    user_agent: Some(BROWSER_UA.to_string()),
                    use_iframe_wrapper: true,
                    embed_html,
                });
            }
        }

        // Dailymotion (`dailymotion.com/video/<id>` or `dai.ly/<id>` or `geo.dailymotion.com`)
        if matches!(
            host.as_str(),
            "dailymotion.com" | "www.dailymotion.com" | "dai.ly" | "geo.dailymotion.com"
        ) {
            let video_code: Option<String> = if host == "dai.ly" {
                segments.first().copied().map(str::to_string)
            } else if let Some(idx) = segments.iter().position(|s| *s == "video") {
                segments.get(idx + 1).copied().map(str::to_string)
            } else {
                url.query_pairs()
                    .find(|(k, _)| k == "video")
                    .map(|(_, v)| v.into_owned())
            };
            if let Some(code) = video_code.filter(|c| {
                !c.is_empty()
                    && c.bytes()
                        .all(|b| b.is_ascii_alphanumeric() || b == b'_' || b == b'-')
            }) {
                let embed_str = format!("https://geo.dailymotion.com/player.html?video={code}");
                let referer = "https://www.dailymotion.com/".to_string();
                let (embed_html, _) = Self::embed_html(&embed_str, &referer);
                return Some(VideoEmbedPlayer {
                    url: embed_str,
                    referer,
                    user_agent: Some(BROWSER_UA.to_string()),
                    use_iframe_wrapper: true,
                    embed_html,
                });
            }
        }

        // Explicit embed / player URLs discovered from `og:video` / JSON-LD `embedUrl`
        let lower_path = url.path().to_ascii_lowercase();
        if (host.starts_with("player.")
            || lower_path.contains("/embed/")
            || lower_path.contains("player.html"))
            && !Self::looks_like_direct_video_stream_url(url)
        {
            let referer = format!("{}://{host}/", url.scheme());
            let embed_str = url.to_string();
            let (embed_html, _) = Self::embed_html(&embed_str, &referer);
            return Some(VideoEmbedPlayer {
                url: embed_str,
                referer,
                user_agent: Some(BROWSER_UA.to_string()),
                use_iframe_wrapper: true,
                embed_html,
            });
        }

        None
    }

    /// Generates clean full-bleed responsive iframe HTML with explicit
    /// `strict-origin-when-cross-origin` Referer policy (prevents YouTube Error 153 and Bilibili
    /// Referer rejection in embedded WebViews).
    pub fn embed_html(embed_url: &str, referer: &str) -> (String, String) {
        let escaped_src = embed_url
            .replace('&', "&amp;")
            .replace('"', "&quot;")
            .replace('<', "&lt;")
            .replace('>', "&gt;");
        let html = format!(
            r#"<!DOCTYPE html>
<html>
<head>
  <meta charset="utf-8">
  <meta name="viewport" content="width=device-width, initial-scale=1.0, maximum-scale=1.0, user-scalable=no">
  <meta name="referrer" content="strict-origin-when-cross-origin">
  <style>
    html, body {{
      margin: 0;
      padding: 0;
      width: 100%;
      height: 100%;
      background: #000;
      overflow: hidden;
    }}
    iframe {{
      position: fixed;
      inset: 0;
      width: 100%;
      height: 100%;
      border: 0;
      background: #000;
    }}
  </style>
</head>
<body>
  <iframe
    src="{escaped_src}"
    referrerpolicy="strict-origin-when-cross-origin"
    allow="accelerometer; autoplay; clipboard-write; encrypted-media; gyroscope; picture-in-picture; web-share; fullscreen"
    allowfullscreen
    webkitallowfullscreen>
  </iframe>
</body>
</html>"#
        );
        let base_url = Url::parse(referer)
            .ok()
            .filter(|u| matches!(u.scheme(), "http" | "https"))
            .map(|u| u.to_string())
            .unwrap_or_else(|| "https://charkle.app".to_string());
        (html, base_url)
    }

    /// Returns `true` when `url` points directly to a playable media stream rather than an HTML
    /// watch/embed page.
    pub fn looks_like_direct_video_stream_url(url: &Url) -> bool {
        let ext = Path::new(url.path())
            .extension()
            .and_then(|e| e.to_str())
            .unwrap_or("")
            .to_ascii_lowercase();
        if matches!(ext.as_str(), "mp4" | "m4v" | "mov" | "m3u8" | "webm") {
            return true;
        }
        let lower = url.as_str().to_ascii_lowercase();
        lower.contains(".mp4?")
            || lower.contains(".m3u8?")
            || lower.contains(".mov?")
            || lower.contains(".webm?")
            || lower.contains("mime=video")
            || lower.contains("/videoplayback?")
    }

    /// Formats a video playhead timestamp (`MM:SS` or `H:MM:SS`) for user-facing cover toasts.
    pub fn format_video_timestamp(seconds: f64) -> String {
        if !seconds.is_finite() || seconds < 0.0 {
            return "00:00".to_string();
        }
        format_timestamp(seconds.round() as i64)
    }

    async fn resolve_bilibili_playback_plan(
        post: &SocialPostMetadata,
        watch_url: Option<&Url>,
    ) -> VideoStreamPlaybackPlan {
        let mut bvid = post
            .video_id
            .as_deref()
            .map(str::trim)
            .filter(|s| !s.is_empty())
            .map(str::to_string);
        let mut aid: Option<i64> = None;
        let mut cid = post.video_cid;
        let mut page: Option<u32> = None;

        if let Some(orig) = watch_url {
            if let Some(VideoPlatformReference::Bilibili {
                bvid: parsed_bv,
                aid: parsed_aid,
                short_url,
                page: parsed_page,
                ..
            }) = VideoPlatformURLParser::parse(orig)
            {
                if bvid.is_none() {
                    bvid = parsed_bv;
                }
                aid = parsed_aid;
                page = parsed_page;
                if bvid.is_none() && aid.is_none() {
                    if let Some(su) = short_url {
                        if let Some(expanded) = Self::expand_short_redirect(&su).await {
                            if let Some(VideoPlatformReference::Bilibili {
                                bvid: rbv,
                                aid: raid,
                                page: rpage,
                                ..
                            }) = VideoPlatformURLParser::parse(&expanded)
                            {
                                bvid = rbv;
                                aid = raid;
                                page = page.or(rpage);
                            }
                        }
                    }
                }
            }
        }

        if cid.unwrap_or(0) <= 0 || bvid.is_none() {
            if let Some(fresh) = Self::fetch_bilibili_view_info(bvid.as_deref(), aid, page).await {
                bvid = Some(fresh.bvid);
                cid = Some(fresh.cid);
            }
        }

        let mut direct_streams = Vec::new();
        if let (Some(ref resolved_bvid), Some(resolved_cid)) = (&bvid, cid.filter(|&c| c > 0)) {
            let referer = format!("https://www.bilibili.com/video/{resolved_bvid}");
            let mut headers = BTreeMap::new();
            headers.insert("Referer".to_string(), referer);
            headers.insert("User-Agent".to_string(), BROWSER_UA.to_string());
            let urls = Self::fetch_bilibili_progressive_streams(resolved_bvid, resolved_cid).await;
            for u in urls {
                if SocialPostResolver::is_safe_public_media_url(&u) {
                    direct_streams.push(VideoDirectStream {
                        url: u.to_string(),
                        http_headers: headers.clone(),
                        is_hls: false,
                    });
                }
            }
        }

        let canonical_for_embed = if let Some(ref bv) = bvid {
            let suffix = page
                .filter(|&p| p > 1)
                .map(|p| format!("?p={p}"))
                .unwrap_or_default();
            Url::parse(&format!("https://www.bilibili.com/video/{bv}{suffix}"))
                .ok()
                .or_else(|| watch_url.cloned())
        } else {
            watch_url.cloned()
        };

        let embed_player = canonical_for_embed
            .as_ref()
            .and_then(|u| Self::embed_player(u, bvid.as_deref(), cid));

        VideoStreamPlaybackPlan {
            direct_streams,
            embed_player,
            watch_url: canonical_for_embed
                .or_else(|| watch_url.cloned())
                .map(|u| u.to_string()),
        }
    }

    async fn resolve_youtube_playback_plan(
        post: &SocialPostMetadata,
        watch_url: Option<&Url>,
    ) -> VideoStreamPlaybackPlan {
        let video_id = post
            .video_id
            .as_deref()
            .filter(|id| VideoPlatformURLParser::is_valid_youtube_id(id))
            .map(str::to_string)
            .or_else(|| {
                let u = watch_url?;
                match VideoPlatformURLParser::parse(u)? {
                    VideoPlatformReference::Youtube { video_id, .. } => Some(video_id),
                    _ => None,
                }
            });

        let canonical_url = video_id
            .as_deref()
            .and_then(|id| Url::parse(&format!("https://www.youtube.com/watch?v={id}")).ok())
            .or_else(|| watch_url.cloned());
        let embed_player = canonical_url
            .as_ref()
            .and_then(|u| Self::embed_player(u, None, None));

        let Some(video_id) = video_id else {
            return VideoStreamPlaybackPlan {
                direct_streams: Vec::new(),
                embed_player,
                watch_url: canonical_url.map(|u| u.to_string()),
            };
        };

        let mut direct_streams = Vec::new();
        let mut hls_streams = Vec::new();
        let mut seen = HashSet::new();

        for profile in [
            YouTubeClientProfile::Ios,
            YouTubeClientProfile::Android,
            YouTubeClientProfile::TvEmbedded,
        ] {
            let Some(payload) = Self::fetch_youtube_player_response(&video_id, profile).await
            else {
                continue;
            };
            let Some(streaming_data) = payload.get("streamingData") else {
                continue;
            };

            let mut headers = BTreeMap::new();
            headers.insert("User-Agent".to_string(), profile.user_agent().to_string());
            headers.insert(
                "Referer".to_string(),
                "https://www.youtube.com/".to_string(),
            );

            if let Some(formats) = streaming_data.get("formats").and_then(Value::as_array) {
                let mut progressive: Vec<(Url, i64)> = formats
                    .iter()
                    .filter_map(|entry| {
                        let url_str = entry.get("url")?.as_str()?;
                        let u = Url::parse(url_str).ok()?;
                        if !SocialPostResolver::is_safe_public_media_url(&u) {
                            return None;
                        }
                        let mime = entry
                            .get("mimeType")
                            .and_then(Value::as_str)
                            .unwrap_or("")
                            .to_ascii_lowercase();
                        if !mime.contains("video/mp4") {
                            return None;
                        }
                        let height = parse_i64(entry.get("height")).unwrap_or(0);
                        let bitrate = parse_i64(entry.get("bitrate")).unwrap_or(0);
                        Some((u, height * 10_000 + bitrate / 1_000))
                    })
                    .collect();
                progressive.sort_by_key(|(_, rank)| std::cmp::Reverse(*rank));

                for (stream_url, _) in progressive {
                    if seen.insert(stream_url.as_str().to_string()) {
                        direct_streams.push(VideoDirectStream {
                            url: stream_url.to_string(),
                            http_headers: headers.clone(),
                            is_hls: false,
                        });
                    }
                }
            }

            if let Some(hls_str) = streaming_data.get("hlsManifestUrl").and_then(Value::as_str) {
                if let Ok(hls_url) = Url::parse(hls_str) {
                    if SocialPostResolver::is_safe_public_media_url(&hls_url)
                        && seen.insert(hls_url.as_str().to_string())
                    {
                        hls_streams.push(VideoDirectStream {
                            url: hls_url.to_string(),
                            http_headers: headers.clone(),
                            is_hls: true,
                        });
                    }
                }
            }

            if !direct_streams.is_empty() {
                break;
            }
        }

        // Optional zero-download `yt-dlp -g` fallback when progressive MP4 wasn't returned by InnerTube
        if direct_streams.is_empty() {
            if let Some(ref c) = canonical_url {
                if let Some(ytdlp_stream) =
                    Self::resolve_direct_stream_via_yt_dlp_if_available(c.as_str()).await
                {
                    if seen.insert(ytdlp_stream.url.clone()) {
                        if ytdlp_stream.is_hls {
                            hls_streams.push(ytdlp_stream);
                        } else {
                            direct_streams.push(ytdlp_stream);
                        }
                    }
                }
            }
        }

        // Keep progressive muxed MP4 streams first (natively playable in WebView2 `<video>`),
        // followed by any HLS manifests for native-HLS environments.
        direct_streams.extend(hls_streams);

        VideoStreamPlaybackPlan {
            direct_streams,
            embed_player,
            watch_url: canonical_url.map(|u| u.to_string()),
        }
    }

    /// Optional zero-download helper: resolves a direct streaming URL via `yt-dlp -g` with a
    /// bounded timeout (`6s`) and `CREATE_NO_WINDOW` on Windows. Never downloads media to disk.
    async fn resolve_direct_stream_via_yt_dlp_if_available(
        page_url: &str,
    ) -> Option<VideoDirectStream> {
        let parsed = Url::parse(page_url.trim()).ok()?;
        if !SocialPostResolver::is_safe_public_media_url(&parsed) {
            return None;
        }
        let binary = find_yt_dlp_binary()?;
        let url_owned = parsed.to_string();
        let referer = url_owned.clone();

        let join = tokio::task::spawn_blocking(move || {
            let mut cmd = std::process::Command::new(binary);
            cmd.args([
                "--no-playlist",
                "--no-warnings",
                "-g",
                "-f",
                "best[ext=mp4]/best[protocol*=m3u8]/best",
                "--",
                &url_owned,
            ]);
            #[cfg(target_os = "windows")]
            {
                use std::os::windows::process::CommandExt;
                const CREATE_NO_WINDOW: u32 = 0x0800_0000;
                cmd.creation_flags(CREATE_NO_WINDOW);
            }
            let mut child = cmd
                .stdout(std::process::Stdio::piped())
                .stderr(std::process::Stdio::null())
                .spawn()
                .ok()?;

            let deadline = Instant::now() + Duration::from_secs(6);
            loop {
                match child.try_wait() {
                    Ok(Some(status)) => {
                        if !status.success() {
                            return None;
                        }
                        break;
                    }
                    Ok(None) => {
                        if Instant::now() >= deadline {
                            let _ = child.kill();
                            let _ = child.wait();
                            return None;
                        }
                        std::thread::sleep(Duration::from_millis(40));
                    }
                    Err(_) => {
                        let _ = child.kill();
                        return None;
                    }
                }
            }

            let output = child.wait_with_output().ok()?;
            let stdout = String::from_utf8_lossy(&output.stdout);
            let first_line = stdout
                .lines()
                .map(str::trim)
                .find(|line| line.starts_with("https://") || line.starts_with("http://"))?;
            let stream_url = Url::parse(first_line).ok()?;
            if !SocialPostResolver::is_safe_public_media_url(&stream_url) {
                return None;
            }
            let is_hls = is_hls_url(&stream_url);
            let mut headers = BTreeMap::new();
            headers.insert("Referer".to_string(), referer);
            headers.insert("User-Agent".to_string(), BROWSER_UA.to_string());
            Some(VideoDirectStream {
                url: stream_url.to_string(),
                http_headers: headers,
                is_hls,
            })
        });

        tokio::time::timeout(Duration::from_secs(7), join)
            .await
            .ok()?
            .ok()?
    }

    // MARK: - 2. Explicit On-Demand Video Download

    pub async fn download_video(
        post: &SocialPostMetadata,
        directory: &Path,
        base_name: &str,
    ) -> CoreResult<PathBuf> {
        match post.platform {
            SocialPlatform::Bilibili => {
                Self::download_bilibili_video(post, directory, base_name).await
            }
            SocialPlatform::Youtube => {
                Self::download_youtube_video(post, directory, base_name).await
            }
            _ => Err(CoreError::InvalidOperation(
                "无法识别该视频链接。".to_string(),
            )),
        }
    }

    /// Universal on-demand video downloader for arbitrary webpage links (direct MP4/WebM/MOV HTTP
    /// download first, falling back to local `yt-dlp` on PATH when available).
    pub async fn download_generic_web_video(
        page_url: &str,
        direct_stream_url: Option<&Url>,
        directory: &Path,
        base_name: &str,
    ) -> CoreResult<PathBuf> {
        if let Some(direct) = direct_stream_url {
            if SocialPostResolver::is_safe_public_media_url(direct) {
                let lower = direct.as_str().to_ascii_lowercase();
                let is_douyin_stream = DouyinURLParser::is_douyin_video_host(direct.host_str())
                    && (DouyinURLParser::parse(direct).is_none()
                        || lower.contains("/aweme/v1/play"));
                let looks_direct = lower.contains(".mp4")
                    || lower.contains(".mov")
                    || lower.contains(".m4v")
                    || lower.contains(".webm")
                    || lower.contains("video")
                    || is_douyin_stream;
                let referer = if is_douyin_stream {
                    Some(DOUYIN_REFERER)
                } else {
                    Some(page_url)
                };
                if looks_direct {
                    if let Some(file) = Self::download_stream_file(
                        direct, directory, base_name, BROWSER_UA, referer,
                    )
                    .await
                    {
                        return Ok(file);
                    }
                }
            }
        }

        if let Some(file) =
            Self::download_via_yt_dlp_if_available(page_url, directory, base_name).await
        {
            return Ok(file);
        }

        Err(CoreError::Media(
            "未能从该网页直接提取视频流。若本机已安装 yt-dlp 并加入 PATH，Charkle 可自动支持主流视频网站保存 MP4。".to_string(),
        ))
    }

    async fn download_bilibili_video(
        post: &SocialPostMetadata,
        directory: &Path,
        base_name: &str,
    ) -> CoreResult<PathBuf> {
        let mut bvid = post
            .video_id
            .as_deref()
            .map(str::trim)
            .filter(|s| !s.is_empty())
            .map(str::to_string);
        let mut aid: Option<i64> = None;
        let mut cid = post.video_cid;
        let mut page: Option<u32> = None;

        if let Ok(orig) = Url::parse(&post.original_url) {
            if let Some(VideoPlatformReference::Bilibili {
                bvid: pbv,
                aid: paid,
                short_url,
                page: ppage,
                ..
            }) = VideoPlatformURLParser::parse(&orig)
            {
                if bvid.is_none() {
                    bvid = pbv;
                }
                aid = paid;
                page = ppage;
                if bvid.is_none() && aid.is_none() {
                    if let Some(su) = short_url {
                        if let Some(expanded) = Self::expand_short_redirect(&su).await {
                            if let Some(VideoPlatformReference::Bilibili {
                                bvid: rbv,
                                aid: raid,
                                page: rpage,
                                ..
                            }) = VideoPlatformURLParser::parse(&expanded)
                            {
                                bvid = rbv;
                                aid = raid;
                                page = page.or(rpage);
                            }
                        }
                    }
                }
            }
        }

        if cid.unwrap_or(0) <= 0 || bvid.is_none() {
            if let Some(fresh) = Self::fetch_bilibili_view_info(bvid.as_deref(), aid, page).await {
                bvid = Some(fresh.bvid);
                cid = Some(fresh.cid);
            }
        }

        let (Some(resolved_bvid), Some(resolved_cid)) = (bvid, cid.filter(|&c| c > 0)) else {
            return Err(CoreError::Media(
                "无法解析 B 站视频 BV 号或分 P CID".to_string(),
            ));
        };

        let streams = Self::fetch_bilibili_progressive_streams(&resolved_bvid, resolved_cid).await;
        let referer = format!("https://www.bilibili.com/video/{resolved_bvid}");
        for stream in streams {
            if let Some(file) = Self::download_stream_file(
                &stream,
                directory,
                base_name,
                BROWSER_UA,
                Some(&referer),
            )
            .await
            {
                return Ok(file);
            }
        }

        if let Some(file) =
            Self::download_via_yt_dlp_if_available(&post.original_url, directory, base_name).await
        {
            return Ok(file);
        }

        Err(CoreError::Media(
            "该 B 站视频暂无法直接获取 MP4 流（可能需要大会员或登录权限），可点击「在 B 站打开」观看。".to_string(),
        ))
    }

    async fn fetch_bilibili_progressive_streams(bvid: &str, cid: i64) -> Vec<Url> {
        let profiles = [
            vec![
                ("bvid", bvid.to_string()),
                ("cid", cid.to_string()),
                ("qn", "80".to_string()),
                ("fnval", "1".to_string()),
                ("platform", "html5".to_string()),
                ("high_quality", "1".to_string()),
            ],
            vec![
                ("bvid", bvid.to_string()),
                ("cid", cid.to_string()),
                ("qn", "64".to_string()),
                ("fnval", "1".to_string()),
                ("platform", "html5".to_string()),
                ("high_quality", "1".to_string()),
            ],
            vec![
                ("bvid", bvid.to_string()),
                ("cid", cid.to_string()),
                ("qn", "32".to_string()),
                ("fnval", "1".to_string()),
            ],
        ];

        let wbi_keys = Self::fetch_wbi_keys().await;
        let mut candidates = Vec::new();
        let mut seen = HashSet::new();

        for profile in profiles {
            let endpoint = if wbi_keys.is_some() {
                "https://api.bilibili.com/x/player/wbi/playurl"
            } else {
                "https://api.bilibili.com/x/player/playurl"
            };
            let Ok(mut url) = Url::parse(endpoint) else {
                continue;
            };
            if let Some((ref img_key, ref sub_key)) = wbi_keys {
                let map: BTreeMap<String, String> = profile
                    .into_iter()
                    .map(|(k, v)| (k.to_string(), v))
                    .collect();
                let ts = SystemTime::now()
                    .duration_since(UNIX_EPOCH)
                    .map(|d| d.as_secs() as i64)
                    .unwrap_or(0);
                let signed = Self::sign_bilibili_wbi(&map, img_key, sub_key, ts);
                let mut qp = url.query_pairs_mut();
                for (k, v) in signed {
                    qp.append_pair(&k, &v);
                }
            } else {
                let mut qp = url.query_pairs_mut();
                for (k, v) in profile {
                    qp.append_pair(k, &v);
                }
            }

            let Ok(resp) = Self::api_client()
                .get(url)
                .header("Referer", format!("https://www.bilibili.com/video/{bvid}"))
                .send()
                .await
            else {
                continue;
            };
            if !resp.status().is_success() {
                continue;
            }
            let Ok(root) = resp.json::<Value>().await else {
                continue;
            };
            if root.get("code").and_then(Value::as_i64) != Some(0) {
                continue;
            }
            let Some(first) = root
                .get("data")
                .and_then(|d| d.get("durl"))
                .and_then(Value::as_array)
                .and_then(|arr| arr.first())
                .and_then(Value::as_object)
            else {
                continue;
            };

            if let Some(u) = normalized_https_url(first.get("url").and_then(Value::as_str)) {
                if seen.insert(u.as_str().to_string()) {
                    candidates.push(u);
                }
            }
            if let Some(backups) = first.get("backup_url").and_then(Value::as_array) {
                for b in backups {
                    if let Some(u) = normalized_https_url(b.as_str()) {
                        if seen.insert(u.as_str().to_string()) {
                            candidates.push(u);
                        }
                    }
                }
            }
            if !candidates.is_empty() {
                break;
            }
        }
        candidates
    }

    async fn download_youtube_video(
        post: &SocialPostMetadata,
        directory: &Path,
        base_name: &str,
    ) -> CoreResult<PathBuf> {
        let video_id = post
            .video_id
            .as_deref()
            .filter(|id| VideoPlatformURLParser::is_valid_youtube_id(id))
            .map(str::to_string)
            .or_else(|| {
                let u = Url::parse(&post.original_url).ok()?;
                match VideoPlatformURLParser::parse(&u)? {
                    VideoPlatformReference::Youtube { video_id, .. } => Some(video_id),
                    _ => None,
                }
            });

        let Some(video_id) = video_id else {
            return Err(CoreError::Media("无法解析 YouTube 视频 ID".to_string()));
        };

        for profile in [
            YouTubeClientProfile::Ios,
            YouTubeClientProfile::Android,
            YouTubeClientProfile::TvEmbedded,
        ] {
            let Some(payload) = Self::fetch_youtube_player_response(&video_id, profile).await
            else {
                continue;
            };
            let Some(formats) = payload
                .get("streamingData")
                .and_then(|s| s.get("formats"))
                .and_then(Value::as_array)
            else {
                continue;
            };

            let mut progressive: Vec<(Url, i64)> = formats
                .iter()
                .filter_map(|entry| {
                    let url_str = entry.get("url")?.as_str()?;
                    let u = Url::parse(url_str).ok()?;
                    if !SocialPostResolver::is_safe_public_media_url(&u) {
                        return None;
                    }
                    let mime = entry
                        .get("mimeType")
                        .and_then(Value::as_str)
                        .unwrap_or("")
                        .to_ascii_lowercase();
                    if !mime.contains("video/mp4") {
                        return None;
                    }
                    let height = parse_i64(entry.get("height")).unwrap_or(0);
                    let bitrate = parse_i64(entry.get("bitrate")).unwrap_or(0);
                    Some((u, height * 10_000 + bitrate / 1_000))
                })
                .collect();
            progressive.sort_by_key(|(_, rank)| std::cmp::Reverse(*rank));

            for (stream_url, _) in progressive {
                if let Some(file) = Self::download_stream_file(
                    &stream_url,
                    directory,
                    base_name,
                    profile.user_agent(),
                    Some("https://www.youtube.com/"),
                )
                .await
                {
                    return Ok(file);
                }
            }
        }

        if let Some(file) =
            Self::download_via_yt_dlp_if_available(&post.original_url, directory, base_name).await
        {
            return Ok(file);
        }

        Err(CoreError::Media(
            "YouTube 当前限制了该视频的直链获取。若本机已安装 yt-dlp 并加入 PATH，Charkle 将自动调用其保存高清 MP4；也可点击「在 YouTube 打开」观看。".to_string(),
        ))
    }

    async fn download_stream_file(
        url: &Url,
        directory: &Path,
        base_name: &str,
        user_agent: &str,
        referer: Option<&str>,
    ) -> Option<PathBuf> {
        if !SocialPostResolver::is_safe_public_media_url(url) {
            return None;
        }
        let mut req = Self::download_client()
            .get(url.clone())
            .header("User-Agent", user_agent)
            .header("Accept", "*/*");
        if let Some(r) = referer {
            req = req.header("Referer", r);
        }
        const MIN_VIDEO_BYTES: u64 = 8 * 1024;
        const MAX_VIDEO_BYTES: u64 = 600 * 1024 * 1024;
        let mut resp = req.send().await.ok()?;
        if !resp.status().is_success() {
            return None;
        }
        if !SocialPostResolver::is_safe_public_media_url(resp.url()) {
            return None;
        }
        if let Some(len) = resp.content_length() {
            if !(MIN_VIDEO_BYTES..=MAX_VIDEO_BYTES).contains(&len) {
                return None;
            }
        }

        // Stream directly to a sibling temp file so downloading up to 600 MiB never spikes RAM.
        let safe_base = sanitized_file_name(base_name);
        let dest = directory.join(format!("{safe_base}.mp4"));
        let tmp_dest = directory.join(format!(
            "{safe_base}.{}.part",
            uuid::Uuid::new_v4().simple()
        ));
        let mut out_file = tokio::fs::File::create(&tmp_dest).await.ok()?;
        let mut total_written: u64 = 0;
        let mut head_probe: Vec<u8> = Vec::with_capacity(64);

        use tokio::io::AsyncWriteExt;
        while let Some(chunk) = match resp.chunk().await {
            Ok(c) => c,
            Err(_) => {
                drop(out_file);
                let _ = tokio::fs::remove_file(&tmp_dest).await;
                return None;
            }
        } {
            if head_probe.len() < 64 {
                let take = (64 - head_probe.len()).min(chunk.len());
                head_probe.extend_from_slice(&chunk[..take]);
                if head_probe.len() >= 16 {
                    let head = String::from_utf8_lossy(&head_probe).to_ascii_lowercase();
                    if head.contains("<html") || head.contains("<!doctype") {
                        drop(out_file);
                        let _ = tokio::fs::remove_file(&tmp_dest).await;
                        return None;
                    }
                }
            }
            total_written = total_written.saturating_add(chunk.len() as u64);
            if total_written > MAX_VIDEO_BYTES {
                drop(out_file);
                let _ = tokio::fs::remove_file(&tmp_dest).await;
                return None;
            }
            if out_file.write_all(&chunk).await.is_err() {
                drop(out_file);
                let _ = tokio::fs::remove_file(&tmp_dest).await;
                return None;
            }
        }
        if out_file.flush().await.is_err() || total_written < MIN_VIDEO_BYTES {
            drop(out_file);
            let _ = tokio::fs::remove_file(&tmp_dest).await;
            return None;
        }
        drop(out_file);
        if tokio::fs::rename(&tmp_dest, &dest).await.is_err() {
            let _ = tokio::fs::remove_file(&tmp_dest).await;
            return None;
        }
        Some(dest)
    }

    async fn download_via_yt_dlp_if_available(
        page_url: &str,
        directory: &Path,
        base_name: &str,
    ) -> Option<PathBuf> {
        let parsed = Url::parse(page_url.trim()).ok()?;
        if !SocialPostResolver::is_safe_public_media_url(&parsed) {
            return None;
        }
        let binary = find_yt_dlp_binary()?;
        let safe_base = sanitized_file_name(base_name);
        let output_template = directory
            .join(format!("{safe_base}.%(ext)s"))
            .to_string_lossy()
            .to_string();
        let dir_owned = directory.to_path_buf();
        let url_owned = parsed.to_string();

        tokio::task::spawn_blocking(move || {
            let mut cmd = std::process::Command::new(binary);
            cmd.args([
                "--no-playlist",
                "--no-warnings",
                "--max-filesize",
                "600M",
                "-f",
                "best[height<=1080][ext=mp4]/bestvideo[height<=1080][ext=mp4]+bestaudio[ext=m4a]/best[height<=1080]/best",
                "--merge-output-format",
                "mp4",
                "-o",
                &output_template,
                "--",
                &url_owned,
            ]);
            #[cfg(target_os = "windows")]
            {
                use std::os::windows::process::CommandExt;
                const CREATE_NO_WINDOW: u32 = 0x0800_0000;
                cmd.creation_flags(CREATE_NO_WINDOW);
            }
            let mut child = cmd
                .stdout(std::process::Stdio::null())
                .stderr(std::process::Stdio::null())
                .spawn()
                .ok()?;
            let deadline = Instant::now() + Duration::from_secs(300);
            let status = loop {
                match child.try_wait() {
                    Ok(Some(st)) => break st,
                    Ok(None) => {
                        if Instant::now() >= deadline {
                            let _ = child.kill();
                            let _ = child.wait();
                            return None;
                        }
                        std::thread::sleep(Duration::from_millis(120));
                    }
                    Err(_) => {
                        let _ = child.kill();
                        let _ = child.wait();
                        return None;
                    }
                }
            };
            if !status.success() {
                return None;
            }
            let entries = std::fs::read_dir(&dir_owned).ok()?;
            for entry in entries.flatten() {
                let p = entry.path();
                if !p.is_file() {
                    continue;
                }
                let ext = p
                    .extension()
                    .and_then(|e| e.to_str())
                    .unwrap_or("")
                    .to_ascii_lowercase();
                let stem = p.file_stem().and_then(|s| s.to_str()).unwrap_or("");
                if matches!(ext.as_str(), "mp4" | "mov" | "m4v" | "webm" | "mkv")
                    && stem.starts_with(&safe_base)
                {
                    return Some(p);
                }
            }
            None
        })
        .await
        .ok()
        .flatten()
    }

    // MARK: - Helpers

    pub fn extract_timestamp_chapters(text: &str) -> Vec<String> {
        let mut chapters = Vec::new();
        for raw_line in text.lines() {
            let line = raw_line.trim();
            if line.is_empty() || line.chars().count() > 110 {
                continue;
            }
            if looks_like_timestamp_chapter(line) {
                chapters.push(line.to_string());
                if chapters.len() >= 16 {
                    break;
                }
            }
        }
        if chapters.len() >= 2 {
            chapters
        } else {
            Vec::new()
        }
    }

    fn extract_concise_description_lead(text: &str) -> Option<String> {
        let mut kept: Vec<&str> = Vec::new();
        let mut total_chars = 0usize;
        for raw_line in text.lines() {
            let line = raw_line.trim();
            if line.is_empty() {
                continue;
            }
            let lower = line.to_ascii_lowercase();
            if lower.starts_with("http://")
                || lower.starts_with("https://")
                || line.starts_with('#')
            {
                continue;
            }
            kept.push(line);
            total_chars += line.chars().count();
            if total_chars >= 220 || kept.len() >= 3 {
                break;
            }
        }
        let joined = kept.join("\n").trim().to_string();
        if joined.chars().count() < 18 {
            return None;
        }
        if joined.chars().count() > 300 {
            let prefix: String = joined.chars().take(296).collect();
            Some(format!("{}…", prefix.trim()))
        } else {
            Some(joined)
        }
    }

    async fn expand_short_redirect(short_url: &Url) -> Option<Url> {
        if !SocialPostResolver::is_safe_public_media_url(short_url) {
            return None;
        }
        let resp = Self::api_client()
            .get(short_url.clone())
            .send()
            .await
            .ok()?;
        let final_url = resp.url().clone();
        SocialPostResolver::is_safe_public_media_url(&final_url).then_some(final_url)
    }
}

fn find_yt_dlp_binary() -> Option<PathBuf> {
    let names: &[&str] = if cfg!(target_os = "windows") {
        &["yt-dlp.exe", "yt-dlp"]
    } else {
        &["yt-dlp"]
    };
    if let Some(path_var) = std::env::var_os("PATH") {
        for dir in std::env::split_paths(&path_var) {
            for name in names {
                let cand = dir.join(name);
                if cand.is_file() {
                    return Some(cand);
                }
            }
        }
    }
    None
}

fn looks_like_timestamp_chapter(line: &str) -> bool {
    let bytes = line.as_bytes();
    let mut i = 0usize;
    let mut colon_count = 0usize;
    let mut part_digits = 0usize;
    while i < bytes.len() {
        let b = bytes[i];
        if b.is_ascii_digit() {
            part_digits += 1;
            if part_digits > 2 {
                return false;
            }
            i += 1;
        } else if b == b':' {
            if part_digits == 0 || colon_count >= 2 {
                return false;
            }
            colon_count += 1;
            part_digits = 0;
            i += 1;
        } else {
            break;
        }
    }
    if colon_count == 0 || part_digits != 2 {
        return false;
    }
    let rest = line[i..].trim_start_matches(|c: char| {
        c.is_whitespace() || matches!(c, '-' | '–' | '—' | '·' | '|' | ':')
    });
    !rest.trim().is_empty()
}

fn wbi_percent_encode(input: &str) -> String {
    let mut out = String::with_capacity(input.len());
    for byte in input.as_bytes() {
        let b = *byte;
        if b.is_ascii_alphanumeric() || matches!(b, b'-' | b'_' | b'.' | b'~') {
            out.push(b as char);
        } else {
            out.push_str(&format!("%{b:02X}"));
        }
    }
    out
}

fn normalized_https_url(raw: Option<&str>) -> Option<Url> {
    let trimmed = raw?.trim();
    if trimmed.is_empty() {
        return None;
    }
    if let Some(rest) = trimmed.strip_prefix("//") {
        Url::parse(&format!("https://{rest}")).ok()
    } else if let Some(rest) = trimmed.strip_prefix("http://") {
        Url::parse(&format!("https://{rest}")).ok()
    } else {
        Url::parse(trimmed).ok()
    }
}

fn parse_i64(value: Option<&Value>) -> Option<i64> {
    match value? {
        Value::Number(n) => n.as_i64().or_else(|| n.as_f64().map(|v| v as i64)),
        Value::String(s) => s.trim().parse::<i64>().ok(),
        _ => None,
    }
}

fn parse_f64(value: Option<&Value>) -> Option<f64> {
    match value? {
        Value::Number(n) => n.as_f64(),
        Value::String(s) => s.trim().parse::<f64>().ok(),
        _ => None,
    }
}

const STREAM_PROXY_CHUNK_BYTES: u64 = 2 * 1024 * 1024;
const STREAM_PROXY_MAX_RANGE_BYTES: u64 = 4 * 1024 * 1024;
const STREAM_PROXY_MAX_BODY_BYTES: usize = 16 * 1024 * 1024;

#[derive(Debug, Clone)]
pub struct VideoStreamProxyResponse {
    pub status: u16,
    pub content_type: String,
    pub content_range: Option<String>,
    pub content_length: Option<u64>,
    pub accept_ranges: bool,
    pub bytes: Vec<u8>,
}

#[derive(Debug)]
pub enum VideoStreamProxyError {
    BadRequest(&'static str),
    Forbidden(&'static str),
    TooLarge,
    Upstream(String),
}

/// Computes a bounded upstream `Range` header so open-ended browser requests (`bytes=0-`) stream
/// incrementally in 2–4 MiB windows instead of buffering an entire multi-hundred-MB MP4 into RAM.
pub fn compute_bounded_upstream_range(client_range: Option<&str>) -> Option<String> {
    let raw = client_range?.trim();
    let spec = raw
        .strip_prefix("bytes=")
        .or_else(|| raw.strip_prefix("BYTES="))?;
    let first = spec.split(',').next().unwrap_or("").trim();
    let (start_str, end_str) = first.split_once('-')?;

    if start_str.is_empty() {
        let suffix = end_str.trim().parse::<u64>().ok()?;
        if suffix == 0 {
            return None;
        }
        let clamped = suffix.min(STREAM_PROXY_MAX_RANGE_BYTES);
        return Some(format!("bytes=-{clamped}"));
    }

    let start = start_str.trim().parse::<u64>().ok()?;
    if end_str.trim().is_empty() {
        let end = start.saturating_add(STREAM_PROXY_CHUNK_BYTES - 1);
        return Some(format!("bytes={start}-{end}"));
    }

    let requested_end = end_str.trim().parse::<u64>().ok()?;
    if requested_end < start {
        return None;
    }
    let bounded_end = requested_end.min(start.saturating_add(STREAM_PROXY_MAX_RANGE_BYTES - 1));
    Some(format!("bytes={start}-{bounded_end}"))
}

/// Validates and proxies a single bounded HTTP byte-range chunk from a public HTTPS video stream,
/// injecting site-required `Referer` and desktop/mobile `User-Agent` headers without saving to disk.
pub async fn fetch_video_stream_chunk(
    raw_url: &str,
    referer: Option<&str>,
    ua_preset: Option<&str>,
    client_range: Option<&str>,
    is_head: bool,
) -> Result<VideoStreamProxyResponse, VideoStreamProxyError> {
    let trimmed = raw_url.trim();
    if trimmed.is_empty() {
        return Err(VideoStreamProxyError::BadRequest("Missing url parameter"));
    }
    let parsed =
        Url::parse(trimmed).map_err(|_| VideoStreamProxyError::BadRequest("Invalid stream URL"))?;
    if parsed.scheme() != "https" || !SocialPostResolver::is_safe_public_media_url(&parsed) {
        return Err(VideoStreamProxyError::Forbidden(
            "Video stream proxy only permits public HTTPS media URLs",
        ));
    }

    let safe_referer: Option<String> = match referer.map(str::trim).filter(|s| !s.is_empty()) {
        Some(r) if !r.contains('\r') && !r.contains('\n') => Url::parse(r)
            .ok()
            .filter(|u| matches!(u.scheme(), "http" | "https"))
            .map(|u| u.to_string()),
        _ => {
            if VideoPlatformURLParser::is_bilibili_media_host(parsed.host_str()) {
                Some("https://www.bilibili.com/".to_string())
            } else if DouyinURLParser::is_douyin_video_host(parsed.host_str()) {
                Some(DOUYIN_REFERER.to_string())
            } else {
                None
            }
        }
    };

    let ua = match ua_preset.map(str::trim) {
        Some("ios-youtube") => STREAM_IOS_YOUTUBE_UA,
        Some("android-youtube") => STREAM_ANDROID_YOUTUBE_UA,
        _ => STREAM_BROWSER_UA,
    };

    let client = Client::builder()
        .timeout(Duration::from_secs(20))
        .redirect(crate::net_safety::public_redirect_policy(6, true))
        .build()
        .unwrap_or_else(|_| Client::new());

    let mut req = if is_head {
        client.head(parsed.clone())
    } else {
        client.get(parsed.clone())
    };
    req = req
        .header("User-Agent", ua)
        .header("Accept", "*/*")
        .header("Accept-Encoding", "identity");

    if let Some(ref r) = safe_referer {
        req = req.header("Referer", r);
    }
    if !is_head {
        if let Some(bounded_range) = compute_bounded_upstream_range(client_range) {
            req = req.header("Range", bounded_range);
        }
    }

    let mut resp = req
        .send()
        .await
        .map_err(|e| VideoStreamProxyError::Upstream(format!("Stream upstream failed: {e}")))?;

    if resp.url().scheme() != "https" || !SocialPostResolver::is_safe_public_media_url(resp.url()) {
        return Err(VideoStreamProxyError::Forbidden(
            "Redirected stream target blocked by SSRF guard",
        ));
    }

    let status = resp.status().as_u16();
    if status >= 400 {
        return Err(VideoStreamProxyError::Upstream(format!(
            "Upstream returned HTTP {status}"
        )));
    }

    let raw_content_type = resp
        .headers()
        .get(reqwest::header::CONTENT_TYPE)
        .and_then(|v| v.to_str().ok())
        .map(str::to_string);
    let content_range = resp
        .headers()
        .get(reqwest::header::CONTENT_RANGE)
        .and_then(|v| v.to_str().ok())
        .map(str::to_string);
    let content_length = resp.content_length();
    let accept_ranges = resp
        .headers()
        .get(reqwest::header::ACCEPT_RANGES)
        .and_then(|v| v.to_str().ok())
        .map(|v| !v.eq_ignore_ascii_case("none"))
        .unwrap_or(true);

    if is_head {
        let content_type =
            normalize_video_stream_content_type(raw_content_type.as_deref(), resp.url(), &[]);
        return Ok(VideoStreamProxyResponse {
            status,
            content_type,
            content_range,
            content_length,
            accept_ranges,
            bytes: Vec::new(),
        });
    }

    if let Some(len) = content_length {
        if len as usize > STREAM_PROXY_MAX_BODY_BYTES {
            return Err(VideoStreamProxyError::TooLarge);
        }
    }

    let mut bytes = Vec::with_capacity(
        content_length
            .map(|l| (l as usize).min(STREAM_PROXY_CHUNK_BYTES as usize))
            .unwrap_or(256 * 1024),
    );
    while let Some(chunk) = resp
        .chunk()
        .await
        .map_err(|e| VideoStreamProxyError::Upstream(format!("Stream read error: {e}")))?
    {
        if bytes.len().saturating_add(chunk.len()) > STREAM_PROXY_MAX_BODY_BYTES {
            return Err(VideoStreamProxyError::TooLarge);
        }
        bytes.extend_from_slice(&chunk);
    }

    let content_type =
        normalize_video_stream_content_type(raw_content_type.as_deref(), resp.url(), &bytes);

    Ok(VideoStreamProxyResponse {
        status,
        content_type,
        content_range,
        content_length: Some(bytes.len() as u64),
        accept_ranges,
        bytes,
    })
}

/// Normalizes video stream proxy `Content-Type` headers, upgrading generic
/// `application/octet-stream` payloads (common on Douyin VOD CDNs) to `video/mp4`
/// when ISO BMFF `ftyp` magic bytes or a known video host is detected.
pub fn normalize_video_stream_content_type(
    upstream_ct: Option<&str>,
    url: &Url,
    bytes: &[u8],
) -> String {
    let trimmed = upstream_ct
        .map(|s| s.split(';').next().unwrap_or(s).trim())
        .filter(|s| !s.is_empty());
    let is_generic_octet = trimmed.is_none_or(|ct| {
        ct.eq_ignore_ascii_case("application/octet-stream")
            || ct.eq_ignore_ascii_case("binary/octet-stream")
    });
    if !is_generic_octet {
        if let Some(ct) = upstream_ct.map(str::trim).filter(|s| !s.is_empty()) {
            return ct.to_string();
        }
    }
    if is_hls_url(url) {
        return "application/vnd.apple.mpegurl".to_string();
    }
    if (bytes.len() >= 12 && &bytes[4..8] == b"ftyp")
        || DouyinURLParser::is_douyin_video_host(url.host_str())
    {
        return "video/mp4".to_string();
    }
    "video/mp4".to_string()
}

/// Crops a full-window PNG preview captured from WebView2 to the requested logical rectangle
/// (`x, y, width, height` scaled by `device_pixel_ratio`) and encodes it as a crisp JPEG cover.
pub fn crop_png_region_to_jpeg(
    png_bytes: &[u8],
    x: f64,
    y: f64,
    width: f64,
    height: f64,
    device_pixel_ratio: f64,
) -> CoreResult<Vec<u8>> {
    if png_bytes.is_empty() {
        return Err(CoreError::InvalidPayload(
            "Empty WebView preview screenshot.".to_string(),
        ));
    }
    let decoded = image::load_from_memory(png_bytes)
        .map_err(|_| CoreError::InvalidPayload("Failed to decode WebView preview PNG.".into()))?;
    let img_w = decoded.width();
    let img_h = decoded.height();
    if img_w == 0 || img_h == 0 {
        return Err(CoreError::InvalidPayload(
            "Zero-dimension WebView preview.".to_string(),
        ));
    }
    let dpr = if device_pixel_ratio.is_finite() {
        device_pixel_ratio.clamp(0.5, 4.0)
    } else {
        1.0
    };
    let rx = ((x.max(0.0) * dpr).round() as u32).min(img_w.saturating_sub(1));
    let ry = ((y.max(0.0) * dpr).round() as u32).min(img_h.saturating_sub(1));
    let max_w = img_w.saturating_sub(rx).max(1);
    let max_h = img_h.saturating_sub(ry).max(1);
    let rw = ((width.max(1.0) * dpr).round() as u32).clamp(1, max_w);
    let rh = ((height.max(1.0) * dpr).round() as u32).clamp(1, max_h);

    let cropped = decoded.crop_imm(rx, ry, rw, rh);
    let bounded = if cropped.width().max(cropped.height()) > 1_600 {
        crate::media::MediaArtwork::resize(&cropped, 1_600)
    } else {
        cropped
    };
    crate::media::MediaArtwork::encode_jpeg(&bounded, 90)
}

fn is_hls_url(url: &Url) -> bool {
    let ext = Path::new(url.path())
        .extension()
        .and_then(|e| e.to_str())
        .unwrap_or("")
        .to_ascii_lowercase();
    ext == "m3u8" || url.as_str().to_ascii_lowercase().contains(".m3u8")
}

fn format_timestamp(seconds: i64) -> String {
    let clamped = seconds.max(0);
    let h = clamped / 3600;
    let m = (clamped % 3600) / 60;
    let s = clamped % 60;
    if h > 0 {
        format!("{h}:{m:02}:{s:02}")
    } else {
        format!("{m:02}:{s:02}")
    }
}

fn sanitized_file_name(raw: &str) -> String {
    let cleaned: String = raw
        .trim()
        .chars()
        .map(|c| {
            if matches!(
                c,
                '/' | ':' | '\\' | '?' | '%' | '*' | '|' | '"' | '<' | '>'
            ) {
                '_'
            } else {
                c
            }
        })
        .collect();
    let trimmed = cleaned.trim();
    if trimmed.is_empty() {
        "CharkleVideo".to_string()
    } else {
        trimmed.chars().take(72).collect()
    }
}
