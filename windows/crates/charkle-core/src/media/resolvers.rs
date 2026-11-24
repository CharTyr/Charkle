//! Native `reqwest` rich URL resolvers (zero CORS) for X/Twitter, Bluesky, Threads,
//! GitHub repositories, and generic OpenGraph web bookmarks.
//!
//! Mirrors `XPostResolver.swift`, `SocialPostResolver.swift`, `GitHubRepoResolver.swift`,
//! and `WebBookmark.swift`.

use std::collections::HashSet;
use std::path::Path;
use std::time::Duration;

use base64::engine::general_purpose::STANDARD as BASE64_STD;
use base64::Engine;
use chrono::Utc;
use image::DynamicImage;
use reqwest::Client;
use scraper::{Html, Selector};
use serde::Deserialize;
use url::Url;

use crate::media::artwork::MediaArtwork;
use crate::media::xiaohongshu::{
    XiaohongshuNoteReference, XiaohongshuPostResolver, XiaohongshuURLParser, XIAOHONGSHU_REFERER,
};
use crate::models::core::{
    GitHubRepoMetadata, SocialMediaAttachment, SocialMediaAttachmentKind, SocialPlatform,
    SocialPostMetadata,
};
use crate::traits::WebPageSnapshotProvider;

const USER_AGENT: &str = "Charkle/1.0 (+https://charkle.app)";
const BROWSER_USER_AGENT: &str = "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/131.0.0.0 Safari/537.36";
const MAX_HTML_BYTES: usize = 524_288;
const MAX_DIRECT_IMAGE_BYTES: usize = 8 * 1024 * 1024;
const MAX_OG_IMAGE_BYTES: usize = 6 * 1024 * 1024;
const MAX_FAVICON_BYTES: usize = 512 * 1024;
const MAX_SOCIAL_PHOTO_BYTES: usize = 35_000_000;
const MAX_SOCIAL_VIDEO_BYTES: usize = 160_000_000;

fn http_client(timeout_secs: u64) -> Client {
    Client::builder()
        .timeout(Duration::from_secs(timeout_secs))
        .user_agent(USER_AGENT)
        .build()
        .unwrap_or_else(|_| Client::new())
}

fn browser_http_client(timeout_secs: u64) -> Client {
    Client::builder()
        .timeout(Duration::from_secs(timeout_secs))
        .user_agent(BROWSER_USER_AGENT)
        .redirect(reqwest::redirect::Policy::limited(8))
        .build()
        .unwrap_or_else(|_| http_client(timeout_secs))
}

// =============================================================================
// 1. Universal Web URL Parser & 3-Tier Web Bookmark Resolver
// =============================================================================

/// Parses and extracts arbitrary `http` / `https` web URLs from raw strings or short share copy,
/// mirroring `WebBookmark.swift::WebURLParser` 1:1.
pub struct WebURLParser;

impl WebURLParser {
    /// Parses a standalone web URL string (supporting case-insensitive schemes, Unicode paths,
    /// iterative paired wrapper & trailing CJK/ASCII punctuation stripping with balanced `()`/`[]`,
    /// and standalone `www.<host>` URLs).
    pub fn parse(raw: &str) -> Option<Url> {
        let trimmed = strip_wrappers_and_trailing_punctuation(raw.trim());
        if trimmed.is_empty() || trimmed.chars().any(char::is_whitespace) {
            return None;
        }
        let lower = trimmed.to_ascii_lowercase();
        let normalized = if lower.starts_with("http://") {
            format!("http://{}", &trimmed[7..])
        } else if lower.starts_with("https://") {
            format!("https://{}", &trimmed[8..])
        } else if lower.starts_with("www.") {
            let remainder = &trimmed[4..];
            if !remainder.contains('.') || remainder.starts_with('.') {
                return None;
            }
            format!("https://{trimmed}")
        } else {
            return None;
        };

        let url = Url::parse(&normalized).ok()?;
        Self::is_valid_web_destination(&url).then_some(url)
    }

    /// Extracts the first explicit web URL (`http://`, `https://`, or `www.`) from either a
    /// standalone URL string or short share copy (`<= 320` chars AND `<= 5` lines). Long notes
    /// and bare filenames like `README.md` or `photo.png` are deliberately rejected so prose stays
    /// a text snippet.
    pub fn extract_web_url(text: &str, allow_embedded_in_short_text: bool) -> Option<Url> {
        let trimmed = text.trim();
        if trimmed.is_empty() {
            return None;
        }
        if let Some(direct) = Self::parse(trimmed) {
            return Some(direct);
        }
        if !allow_embedded_in_short_text {
            return None;
        }
        let char_count = trimmed.chars().count();
        let line_count = trimmed.split('\n').count();
        if char_count > 320 || line_count > 5 {
            return None;
        }

        // Scan explicit prefixes (`https://`, `http://`, `www.`) case-insensitively, supporting
        // both space-delimited English text and zero-space CJK share copy (e.g. `推荐https://...！`).
        let bytes = trimmed.as_bytes();
        let mut idx = 0usize;
        while idx < bytes.len() {
            let Some(ch) = trimmed[idx..].chars().next() else {
                break;
            };
            let rest = &trimmed[idx..];
            let has_prefix = rest.len() >= 8
                && rest.as_bytes()[..8].eq_ignore_ascii_case(b"https://")
                || rest.len() >= 7 && rest.as_bytes()[..7].eq_ignore_ascii_case(b"http://")
                || rest.len() >= 4 && rest.as_bytes()[..4].eq_ignore_ascii_case(b"www.");
            if has_prefix {
                let prev_is_ident = trimmed[..idx]
                    .chars()
                    .next_back()
                    .is_some_and(|p| p.is_ascii_alphanumeric() || p == '_' || p == '.');
                if !prev_is_ident {
                    let mut end = rest.len();
                    for (off, c) in rest.char_indices() {
                        if c.is_whitespace()
                            || c >= '\u{2E80}'
                            || matches!(c, '<' | '>' | '"' | '\'')
                        {
                            end = off;
                            break;
                        }
                    }
                    let slice = &rest[..end];
                    if let Some(parsed) = Self::parse(slice) {
                        return Some(parsed);
                    }
                }
            }
            idx += ch.len_utf8();
        }
        None
    }

    /// Returns a clean display domain (lowercased host without a leading `www.`).
    pub fn clean_domain(url: &Url) -> Option<String> {
        let host = url.host_str()?.to_ascii_lowercase();
        if host.is_empty() {
            return None;
        }
        if let Some(stripped) = host.strip_prefix("www.") {
            if !stripped.is_empty() {
                return Some(stripped.to_string());
            }
        }
        Some(host)
    }

    fn is_valid_web_destination(url: &Url) -> bool {
        if !WebBookmarkResolver::is_web_url(url) {
            return false;
        }
        let Some(host) = url.host_str().map(str::to_ascii_lowercase) else {
            return false;
        };
        if host.is_empty() {
            return false;
        }
        if host == "localhost" || host.contains(':') {
            return true;
        }
        let parts: Vec<&str> = host.split('.').collect();
        parts.len() >= 2 && parts.iter().all(|p| !p.is_empty())
    }
}

fn strip_wrappers_and_trailing_punctuation(input: &str) -> String {
    const PAIRS: [(char, char); 10] = [
        ('<', '>'),
        ('"', '"'),
        ('\'', '\''),
        ('(', ')'),
        ('[', ']'),
        ('「', '」'),
        ('《', '》'),
        ('“', '”'),
        ('（', '）'),
        ('【', '】'),
    ];
    const TRAILING_STOP: [char; 19] = [
        '.', ',', ';', '!', '?', '。', '，', '；', '！', '？', '、', '”', '’', '）', '】', '」',
        '》', '>', '"',
    ];
    const LEADING_STOP: [char; 9] = ['<', '"', '\'', '「', '《', '“', '‘', '（', '【'];

    let mut chars: Vec<char> = input.chars().collect();
    let mut changed = true;
    while changed && !chars.is_empty() {
        changed = false;

        while chars.len() >= 2 {
            let first = chars[0];
            let last = chars[chars.len() - 1];
            if PAIRS.iter().any(|&(o, c)| o == first && c == last) {
                chars.remove(chars.len() - 1);
                chars.remove(0);
                while chars.first().is_some_and(|c| c.is_whitespace()) {
                    chars.remove(0);
                }
                while chars.last().is_some_and(|c| c.is_whitespace()) {
                    chars.pop();
                }
                changed = true;
            } else {
                break;
            }
        }

        while let Some(&last) = chars.last() {
            if TRAILING_STOP.contains(&last) {
                chars.pop();
                changed = true;
            } else if last == ')' {
                let open_count = chars.iter().filter(|&&c| c == '(').count();
                let close_count = chars.iter().filter(|&&c| c == ')').count();
                if close_count > open_count {
                    chars.pop();
                    changed = true;
                } else {
                    break;
                }
            } else if last == ']' {
                let open_count = chars.iter().filter(|&&c| c == '[').count();
                let close_count = chars.iter().filter(|&&c| c == ']').count();
                if close_count > open_count {
                    chars.pop();
                    changed = true;
                } else {
                    break;
                }
            } else {
                break;
            }
        }

        while let Some(&first) = chars.first() {
            if LEADING_STOP.contains(&first) {
                chars.remove(0);
                changed = true;
            } else {
                break;
            }
        }
    }

    chars.into_iter().collect()
}

#[derive(Debug, Clone, Default)]
pub struct ResolvedWebBookmark {
    pub title: Option<String>,
    pub description: Option<String>,
    pub site_name: Option<String>,
    pub final_url: Option<String>,
    pub theme_color: Option<String>,
    pub poster_image: Option<DynamicImage>,
    pub poster_url: Option<String>,
    pub favicon_image: Option<DynamicImage>,
    pub favicon_url: Option<String>,
    pub network_unreachable: bool,
}

#[derive(Debug, Clone, Default, PartialEq, Eq)]
pub struct ParsedWebHtml {
    pub title: Option<String>,
    pub description: Option<String>,
    pub site_name: Option<String>,
    pub theme_color: Option<String>,
    pub image_candidates: Vec<String>,
    pub favicon_candidates: Vec<String>,
}

pub struct WebBookmarkResolver;

impl WebBookmarkResolver {
    pub fn is_web_url(url: &Url) -> bool {
        matches!(url.scheme(), "http" | "https")
            && url.host_str().is_some()
            && url.username().is_empty()
            && url.password().is_none()
    }

    /// Parses macOS `.webloc` XML property lists and Windows `.url` INI internet shortcuts.
    pub fn url_in_file(path: &Path) -> Option<Url> {
        let bytes = std::fs::read(path).ok()?;
        if bytes.len() >= 256_000 {
            return None;
        }
        let text = String::from_utf8_lossy(&bytes);
        // Windows .url INI format (`URL=https://...`)
        for line in text.lines() {
            let trimmed = line.trim();
            if trimmed.len() > 4 && trimmed.as_bytes()[..4].eq_ignore_ascii_case(b"url=") {
                if let Some(url) = WebURLParser::parse(trimmed[4..].trim()) {
                    return Some(url);
                }
            }
        }
        // macOS .webloc XML plist (`<key>URL</key><string>https://...</string>`)
        if let Some(key_pos) = text.find("<key>URL</key>") {
            let after = &text[key_pos + "<key>URL</key>".len()..];
            if let Some(s_start) = after.find("<string>") {
                let inner = &after[s_start + "<string>".len()..];
                if let Some(s_end) = inner.find("</string>") {
                    if let Some(url) = WebURLParser::parse(inner[..s_end].trim()) {
                        return Some(url);
                    }
                }
            }
        }
        None
    }

    /// Decodes HTML bytes honoring HTTP `Content-Type` charset, `<meta charset>`, and common CJK
    /// encodings (`utf-8`, `gb18030`, `gbk`, `gb2312`, `big5`, `shift_jis`, `euc-jp`, `iso-8859-1`).
    pub fn decode_html(bytes: &[u8], content_type: Option<&str>) -> String {
        if let Some(label) = extract_charset_from_content_type(content_type) {
            if let Some(enc) = encoding_rs::Encoding::for_label(label.as_bytes()) {
                let (cow, _, _) = enc.decode(bytes);
                return cow.into_owned();
            }
        }

        let head = String::from_utf8_lossy(&bytes[..bytes.len().min(4_096)]);
        if let Some(label) = extract_charset_from_html_head(&head) {
            if let Some(enc) = encoding_rs::Encoding::for_label(label.as_bytes()) {
                let (cow, _, _) = enc.decode(bytes);
                return cow.into_owned();
            }
        }

        if let Ok(utf8) = std::str::from_utf8(bytes) {
            return utf8.to_string();
        }
        let (gb, _, had_errors) = encoding_rs::GB18030.decode(bytes);
        if !had_errors {
            return gb.into_owned();
        }
        String::from_utf8_lossy(bytes).into_owned()
    }

    /// Returns a clean webpage title, rejecting anti-bot / Cloudflare / interstitial placeholder
    /// titles and falling back to `<readable last path segment> — <domain>` (or `<domain>`).
    pub fn usable_page_title(raw: Option<&str>, fallback_url: Option<&Url>) -> Option<String> {
        const BLOCKED_EXACT: &[&str] = &[
            "just a moment...",
            "just a moment",
            "attention required!",
            "attention required! | cloudflare",
            "access denied",
            "403 forbidden",
            "404 not found",
            "checking your browser",
            "verify you are human",
            "please wait...",
            "loading...",
            "redirecting...",
        ];
        if let Some(candidate) = raw.map(str::trim).filter(|s| !s.is_empty()) {
            let lower = candidate.to_ascii_lowercase();
            if !BLOCKED_EXACT.contains(&lower.as_str())
                && !lower.starts_with("just a moment")
                && !lower.starts_with("attention required")
            {
                return Some(candidate.chars().take(220).collect());
            }
        }
        fallback_url.map(Self::fallback_title)
    }

    /// Derives a readable fallback title from a URL's domain and last path segment.
    pub fn fallback_title(url: &Url) -> String {
        let domain = WebURLParser::clean_domain(url)
            .or_else(|| url.host_str().map(str::to_string))
            .unwrap_or_else(|| "网页书签".to_string());
        if let Some(last) = url
            .path_segments()
            .and_then(|mut segs| segs.rfind(|s| !s.is_empty()))
        {
            let lower = last.to_ascii_lowercase();
            if !last.is_empty()
                && last.chars().count() <= 60
                && lower != "index.html"
                && lower != "index.htm"
            {
                let readable = last.replace(['-', '_'], " ");
                return format!("{readable} — {domain}");
            }
        }
        domain
    }

    /// Rejects solid blank white/black/flat canvases produced when a blocked or empty page fails
    /// silently during offscreen browser snapshot capture.
    pub fn is_visually_blank(image: &DynamicImage) -> bool {
        let sample = image
            .resize_exact(32, 20, image::imageops::FilterType::Nearest)
            .to_rgba8();
        let mut min_lum: i32 = 255;
        let mut max_lum: i32 = 0;
        let mut max_channel_spread: i32 = 0;
        for px in sample.pixels() {
            let r = i32::from(px.0[0]);
            let g = i32::from(px.0[1]);
            let b = i32::from(px.0[2]);
            let lum = (r * 299 + g * 587 + b * 114) / 1000;
            min_lum = min_lum.min(lum);
            max_lum = max_lum.max(lum);
            let spread = r.max(g).max(b) - r.min(g).min(b);
            max_channel_spread = max_channel_spread.max(spread);
        }
        (max_lum - min_lum) < 8 && max_channel_spread < 8
    }

    /// Parses OpenGraph, Twitter Card, standard HTML `<title>` / `<h1>` / description,
    /// `theme-color`, ordered cover image candidates (incl. JSON-LD `"image"`), and ordered
    /// favicon candidates offline.
    pub fn parse_html_rich(html: &str, base_url: Option<&Url>) -> ParsedWebHtml {
        let doc = Html::parse_document(html);

        let title_tag = Selector::parse("title").ok().and_then(|sel| {
            doc.select(&sel)
                .next()
                .map(|el| el.text().collect::<String>())
        });
        let h1_tag = Selector::parse("h1").ok().and_then(|sel| {
            doc.select(&sel)
                .next()
                .map(|el| el.text().collect::<String>())
        });
        let title = select_meta(&doc, "og:title")
            .or_else(|| select_meta(&doc, "twitter:title"))
            .or(title_tag)
            .or(h1_tag)
            .map(|s| collapse_whitespace(&s, 220))
            .filter(|s| !s.is_empty());

        let description = select_meta(&doc, "og:description")
            .or_else(|| select_meta(&doc, "twitter:description"))
            .or_else(|| select_meta(&doc, "description"))
            .map(|s| collapse_whitespace(&s, 420))
            .filter(|s| !s.is_empty());

        let site_name = select_meta(&doc, "og:site_name")
            .or_else(|| select_meta(&doc, "application-name"))
            .map(|s| collapse_whitespace(&s, 80))
            .filter(|s| !s.is_empty());

        let theme_color =
            select_meta(&doc, "theme-color").and_then(|raw| normalize_hex_color(&raw));

        let mut image_candidates = Vec::new();
        let mut seen_images = HashSet::new();
        for key in [
            "og:image:secure_url",
            "og:image",
            "og:image:url",
            "twitter:image",
            "twitter:image:src",
        ] {
            for raw in select_all_meta(&doc, key) {
                if let Some(resolved) = resolve_web_href(&raw, base_url) {
                    if seen_images.insert(resolved.clone()) {
                        image_candidates.push(resolved);
                    }
                }
            }
        }
        for raw in select_link_hrefs(&doc, &["image_src"]) {
            if let Some(resolved) = resolve_web_href(&raw, base_url) {
                if seen_images.insert(resolved.clone()) {
                    image_candidates.push(resolved);
                }
            }
        }
        for raw in extract_json_ld_images(&doc) {
            if let Some(resolved) = resolve_web_href(&raw, base_url) {
                if seen_images.insert(resolved.clone()) {
                    image_candidates.push(resolved);
                }
            }
        }

        let mut favicon_candidates = Vec::new();
        let mut seen_icons = HashSet::new();
        for group in [
            &["apple-touch-icon", "apple-touch-icon-precomposed"][..],
            &["icon"][..],
            &["shortcut icon"][..],
        ] {
            for raw in select_link_hrefs(&doc, group) {
                if let Some(resolved) = resolve_web_href(&raw, base_url) {
                    if seen_icons.insert(resolved.clone()) {
                        favicon_candidates.push(resolved);
                    }
                }
            }
        }
        if let Some(base) = base_url {
            if let Ok(root_icon) = base.join("/favicon.ico") {
                if Self::is_web_url(&root_icon) {
                    let icon_str = root_icon.to_string();
                    if seen_icons.insert(icon_str.clone()) {
                        favicon_candidates.push(icon_str);
                    }
                }
            }
        }

        ParsedWebHtml {
            title,
            description,
            site_name,
            theme_color,
            image_candidates,
            favicon_candidates,
        }
    }

    /// Parses OpenGraph metadata directly from HTML (unit-testable offline).
    pub fn parse_html(
        html: &str,
        base_url: Option<&Url>,
    ) -> (Option<String>, Option<String>, Option<String>) {
        let parsed = Self::parse_html_rich(html, base_url);
        (
            parsed.title,
            parsed.description,
            parsed.image_candidates.into_iter().next(),
        )
    }

    /// Single-pass Tier 1 fetch (offline-safe, without browser snapshot fallback).
    pub async fn fetch(url: &Url) -> ResolvedWebBookmark {
        Self::fetch_with_snapshot(url, None).await
    }

    /// Full 3-tier webpage resolver:
    /// - Tier 1: Direct image URL (<= 8 MiB) or HTML OG/Twitter/`image_src`/JSON-LD with CJK
    ///   charset decoding, `Referer`, `>= 160×100` & anti-tracking-pixel aspect guards.
    /// - Tier 2: Optional offscreen browser snapshot (`1280×800`, skipped on `network_unreachable`,
    ///   validated with `is_visually_blank`).
    /// - Tier 3 enrichment: Favicon fetch (`>= 16×16`) for editorial bookmark card fallback.
    pub async fn fetch_with_snapshot(
        url: &Url,
        snapshot_provider: Option<&dyn WebPageSnapshotProvider>,
    ) -> ResolvedWebBookmark {
        if !Self::is_web_url(url) {
            return ResolvedWebBookmark::default();
        }
        let client = browser_http_client(8);
        let mut title: Option<String> = None;
        let mut description: Option<String> = None;
        let mut site_name: Option<String> = None;
        let mut theme_color: Option<String> = None;
        let mut final_url = url.clone();
        let mut poster_image: Option<DynamicImage> = None;
        let mut poster_url: Option<String> = None;
        let mut favicon_image: Option<DynamicImage> = None;
        let mut favicon_url: Option<String> = None;
        let mut icon_candidates: Vec<String> = Vec::new();
        let mut fallback_poster_url: Option<String> = None;
        let mut network_unreachable = false;

        match client
            .get(url.clone())
            .header(
                "Accept",
                "text/html,application/xhtml+xml,application/xml;q=0.9,image/avif,image/webp,image/*;q=0.8,*/*;q=0.5",
            )
            .header("Accept-Language", "zh-CN,zh;q=0.9,en-US;q=0.8,en;q=0.7")
            .send()
            .await
        {
            Ok(resp) if resp.status().is_success() => {
                let resp_url = resp.url().clone();
                if Self::is_web_url(&resp_url) {
                    final_url = resp_url;
                }
                let content_type = resp
                    .headers()
                    .get(reqwest::header::CONTENT_TYPE)
                    .and_then(|v| v.to_str().ok())
                    .map(String::from);
                if let Ok(bytes) = resp.bytes().await {
                    let ct_lower = content_type
                        .as_deref()
                        .unwrap_or("")
                        .to_ascii_lowercase();
                    if ct_lower.starts_with("image/") {
                        if !bytes.is_empty() && bytes.len() <= MAX_DIRECT_IMAGE_BYTES {
                            if let Some(img) =
                                decode_web_image_bytes(&bytes, content_type.as_deref(), 1400)
                            {
                                let filename = final_url
                                    .path_segments()
                                    .and_then(|mut s| s.rfind(|p| !p.is_empty()))
                                    .unwrap_or("")
                                    .trim();
                                let clean_domain = WebURLParser::clean_domain(&final_url);
                                let display_title = if filename.is_empty() {
                                    clean_domain
                                        .clone()
                                        .unwrap_or_else(|| final_url.to_string())
                                } else {
                                    filename.chars().take(220).collect()
                                };
                                return ResolvedWebBookmark {
                                    title: Some(display_title),
                                    description: None,
                                    site_name: clean_domain,
                                    final_url: Some(final_url.to_string()),
                                    theme_color: None,
                                    poster_image: Some(img),
                                    poster_url: Some(final_url.to_string()),
                                    favicon_image: None,
                                    favicon_url: None,
                                    network_unreachable: false,
                                };
                            }
                        }
                    } else {
                        let html = Self::decode_html(
                            &bytes[..bytes.len().min(MAX_HTML_BYTES)],
                            content_type.as_deref(),
                        );
                        let parsed = Self::parse_html_rich(&html, Some(&final_url));
                        title = parsed.title;
                        description = parsed.description;
                        site_name = parsed.site_name;
                        theme_color = parsed.theme_color;
                        icon_candidates = parsed.favicon_candidates;
                        fallback_poster_url = parsed.image_candidates.first().cloned();

                        for candidate in parsed.image_candidates.iter().take(4) {
                            if let Some(img) = Self::fetch_web_image(
                                &client,
                                candidate,
                                &final_url,
                                MAX_OG_IMAGE_BYTES,
                                1200,
                            )
                            .await
                            {
                                let ratio = f64::from(img.width()) / f64::from(img.height().max(1));
                                if img.width() >= 160
                                    && img.height() >= 100
                                    && (0.15..=6.5).contains(&ratio)
                                {
                                    poster_image = Some(img);
                                    poster_url = Some(candidate.clone());
                                    break;
                                } else if img.width() >= 16
                                    && img.height() >= 16
                                    && favicon_image.is_none()
                                {
                                    favicon_image = Some(img);
                                    favicon_url = Some(candidate.clone());
                                }
                            }
                        }
                    }
                }
            }
            Ok(_non_2xx) => {
                // Site reached (e.g. 403/503 to raw reqwest); allow Tier 2 browser snapshot below.
            }
            Err(err) => {
                if err.is_connect() || err.is_builder() {
                    network_unreachable = true;
                }
            }
        }

        // Tier 2: Offscreen ephemeral browser snapshot when Tier 1 got no cover & network is reachable
        if poster_image.is_none() && !network_unreachable {
            if let Some(provider) = snapshot_provider {
                if let Some(snap) = provider.capture_snapshot(final_url.as_str()).await {
                    if let Ok(img) = image::load_from_memory(&snap.png_bytes) {
                        if img.width() >= 160
                            && img.height() >= 100
                            && !Self::is_visually_blank(&img)
                        {
                            poster_image = Some(img);
                            if title.as_deref().map(str::trim).unwrap_or("").is_empty() {
                                title = snap.title;
                            }
                            if description
                                .as_deref()
                                .map(str::trim)
                                .unwrap_or("")
                                .is_empty()
                            {
                                description = snap.description;
                            }
                            if let Some(ref resolved) = snap.final_url {
                                if let Ok(parsed) = Url::parse(resolved) {
                                    if Self::is_web_url(&parsed) {
                                        final_url = parsed;
                                    }
                                }
                            }
                        }
                    }
                }
            }
        }

        // Tier 3 enrichment: fetch site favicon when falling back to editorial card
        if poster_image.is_none() && favicon_image.is_none() && !network_unreachable {
            if icon_candidates.is_empty() {
                if let Ok(root_icon) = final_url.join("/favicon.ico") {
                    if Self::is_web_url(&root_icon) {
                        icon_candidates.push(root_icon.to_string());
                    }
                }
            }
            for candidate in icon_candidates.iter().take(3) {
                if let Some(icon) =
                    Self::fetch_web_image(&client, candidate, &final_url, MAX_FAVICON_BYTES, 128)
                        .await
                {
                    if icon.width() >= 16 && icon.height() >= 16 {
                        favicon_image = Some(icon);
                        favicon_url = Some(candidate.clone());
                        break;
                    }
                }
            }
        }

        ResolvedWebBookmark {
            title: Self::usable_page_title(title.as_deref(), Some(url)),
            description,
            site_name: site_name.or_else(|| WebURLParser::clean_domain(&final_url)),
            final_url: Some(final_url.to_string()),
            theme_color,
            poster_image,
            poster_url: poster_url.or(fallback_poster_url),
            favicon_image,
            favicon_url,
            network_unreachable,
        }
    }

    async fn fetch_web_image(
        client: &Client,
        raw_url: &str,
        referer: &Url,
        max_bytes: usize,
        max_svg_side: u32,
    ) -> Option<DynamicImage> {
        let img_url = Url::parse(raw_url).ok()?;
        if !Self::is_web_url(&img_url) {
            return None;
        }
        let img_resp = client
            .get(img_url)
            .header(
                "Accept",
                "image/avif,image/webp,image/png,image/jpeg,image/gif,image/svg+xml,image/*;q=0.8",
            )
            .header("Referer", referer.as_str())
            .send()
            .await
            .ok()?;
        if !img_resp.status().is_success() {
            return None;
        }
        let content_type = img_resp
            .headers()
            .get(reqwest::header::CONTENT_TYPE)
            .and_then(|v| v.to_str().ok())
            .map(String::from);
        let img_bytes = img_resp.bytes().await.ok()?;
        if img_bytes.is_empty() || img_bytes.len() > max_bytes {
            return None;
        }
        decode_web_image_bytes(&img_bytes, content_type.as_deref(), max_svg_side)
    }
}

fn extract_charset_from_content_type(content_type: Option<&str>) -> Option<String> {
    let ct = content_type?;
    let lower = ct.to_ascii_lowercase();
    let idx = lower.find("charset=")?;
    let rest = &ct[idx + "charset=".len()..];
    let val = rest
        .trim_start_matches([' ', '"', '\''])
        .split([';', '"', '\'', ' ', '\t', '\r', '\n'])
        .next()
        .unwrap_or("")
        .trim();
    (!val.is_empty()).then(|| val.to_ascii_lowercase())
}

fn extract_charset_from_html_head(head: &str) -> Option<String> {
    let lower = head.to_ascii_lowercase();
    let mut search_from = 0usize;
    while let Some(rel) = lower[search_from..].find("<meta") {
        let start = search_from + rel;
        let end = lower[start..]
            .find('>')
            .map(|o| start + o)
            .unwrap_or(lower.len());
        let tag = &lower[start..end];
        if let Some(pos) = tag.find("charset") {
            let after = tag[pos + "charset".len()..].trim_start();
            if let Some(eq) = after.strip_prefix('=') {
                let val = eq
                    .trim_start_matches([' ', '"', '\''])
                    .split(['"', '\'', ';', ' ', '\t', '\r', '\n', '/'])
                    .next()
                    .unwrap_or("")
                    .trim();
                if !val.is_empty() {
                    return Some(val.to_string());
                }
            }
        }
        search_from = end.saturating_add(1).min(lower.len());
    }
    None
}

fn normalize_hex_color(raw: &str) -> Option<String> {
    let trimmed = raw.trim();
    let body = trimmed.strip_prefix('#')?;
    if !body.is_ascii() || !body.bytes().all(|b| b.is_ascii_hexdigit()) {
        return None;
    }
    match body.len() {
        6 => Some(format!("#{}", body.to_ascii_uppercase())),
        3 => {
            let mut out = String::with_capacity(7);
            out.push('#');
            for ch in body.chars() {
                let up = ch.to_ascii_uppercase();
                out.push(up);
                out.push(up);
            }
            Some(out)
        }
        _ => None,
    }
}

fn extract_json_ld_images(doc: &Html) -> Vec<String> {
    let Ok(sel) = Selector::parse(r#"script[type="application/ld+json"]"#) else {
        return Vec::new();
    };
    let mut out = Vec::new();
    for el in doc.select(&sel).take(4) {
        let raw = el.text().collect::<String>();
        let Ok(val) = serde_json::from_str::<serde_json::Value>(raw.trim()) else {
            continue;
        };
        collect_json_ld_images(&val, &mut out);
        if out.len() >= 4 {
            break;
        }
    }
    out
}

fn collect_json_ld_images(val: &serde_json::Value, out: &mut Vec<String>) {
    if out.len() >= 4 {
        return;
    }
    match val {
        serde_json::Value::Object(map) => {
            if let Some(img) = map.get("image") {
                match img {
                    serde_json::Value::String(s) => out.push(s.clone()),
                    serde_json::Value::Object(obj) => {
                        if let Some(u) = obj.get("url").and_then(|v| v.as_str()) {
                            out.push(u.to_string());
                        }
                    }
                    serde_json::Value::Array(arr) => {
                        for elem in arr.iter().take(2) {
                            if let Some(s) = elem.as_str() {
                                out.push(s.to_string());
                            } else if let Some(u) = elem.get("url").and_then(|v| v.as_str()) {
                                out.push(u.to_string());
                            }
                        }
                    }
                    _ => {}
                }
            }
            if let Some(graph) = map.get("@graph").and_then(|v| v.as_array()) {
                for node in graph {
                    collect_json_ld_images(node, out);
                }
            }
        }
        serde_json::Value::Array(arr) => {
            for elem in arr {
                collect_json_ld_images(elem, out);
            }
        }
        _ => {}
    }
}

fn collapse_whitespace(raw: &str, max_chars: usize) -> String {
    raw.split_whitespace()
        .collect::<Vec<_>>()
        .join(" ")
        .chars()
        .take(max_chars)
        .collect()
}

fn resolve_web_href(raw: &str, base_url: Option<&Url>) -> Option<String> {
    let trimmed = raw.trim();
    if trimmed.is_empty() || trimmed.starts_with("data:") {
        return None;
    }
    let resolved = match base_url {
        Some(base) => base.join(trimmed).ok(),
        None => Url::parse(trimmed).ok(),
    }?;
    WebBookmarkResolver::is_web_url(&resolved).then(|| resolved.to_string())
}

fn decode_web_image_bytes(
    bytes: &[u8],
    content_type: Option<&str>,
    max_svg_side: u32,
) -> Option<DynamicImage> {
    let is_svg_mime = content_type.is_some_and(|ct| ct.to_ascii_lowercase().contains("svg"));
    let prefix = std::str::from_utf8(&bytes[..bytes.len().min(256)])
        .ok()
        .map(str::trim_start);
    let looks_like_svg = is_svg_mime
        || prefix.is_some_and(|s| {
            s.starts_with("<svg")
                || (s.starts_with("<?xml") && s.to_ascii_lowercase().contains("<svg"))
        });
    if looks_like_svg {
        if let Some(svg_img) = MediaArtwork::render_svg(bytes, max_svg_side) {
            return Some(svg_img);
        }
    }
    image::load_from_memory(bytes).ok()
}

fn select_meta(doc: &Html, name: &str) -> Option<String> {
    select_all_meta(doc, name).into_iter().next()
}

fn select_all_meta(doc: &Html, name: &str) -> Vec<String> {
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

fn select_link_hrefs(doc: &Html, rel_targets: &[&str]) -> Vec<String> {
    let Ok(sel) = Selector::parse("link[href]") else {
        return Vec::new();
    };
    let mut out = Vec::new();
    for el in doc.select(&sel) {
        let Some(rel) = el.value().attr("rel") else {
            continue;
        };
        let rel_lower = rel.trim().to_ascii_lowercase();
        let matched = rel_targets.iter().any(|target| {
            if target.contains(' ') {
                rel_lower == *target
            } else {
                rel_lower.split_whitespace().any(|tok| tok == *target)
            }
        });
        if matched {
            if let Some(href) = el.value().attr("href") {
                let trimmed = href.trim();
                if !trimmed.is_empty() {
                    out.push(trimmed.to_string());
                }
            }
        }
    }
    out
}

// =============================================================================
// 2. GitHub Repository Resolver
// =============================================================================

#[derive(Debug, Clone, PartialEq, Eq, Hash)]
pub struct GitHubRepoReference {
    pub owner: String,
    pub repo: String,
    pub branch: Option<String>,
}

impl GitHubRepoReference {
    pub fn full_name(&self) -> String {
        format!("{}/{}", self.owner, self.repo)
    }

    pub fn canonical_url(&self) -> String {
        format!("https://github.com/{}/{}", self.owner, self.repo)
    }
}

pub struct GitHubRepoURLParser;

impl GitHubRepoURLParser {
    const RESERVED_OWNERS: &'static [&'static str] = &[
        "settings",
        "notifications",
        "explore",
        "marketplace",
        "topics",
        "trending",
        "collections",
        "events",
        "sponsors",
        "orgs",
        "organizations",
        "search",
        "login",
        "signup",
        "join",
        "features",
        "pricing",
        "enterprise",
        "team",
        "security",
        "about",
        "contact",
        "issues",
        "pulls",
        "codespaces",
        "copilot",
        "new",
        "stars",
        "gist",
        "apps",
        "site",
        "customer-stories",
        "readme",
        "watching",
        "users",
    ];

    pub fn parse(url: &Url) -> Option<GitHubRepoReference> {
        if !matches!(url.scheme(), "http" | "https") {
            return None;
        }
        let host = url.host_str()?.to_ascii_lowercase();
        if host != "github.com" && host != "www.github.com" {
            return None;
        }
        let segments: Vec<&str> = url.path_segments()?.filter(|s| !s.is_empty()).collect();
        if segments.len() < 2 {
            return None;
        }
        let owner = segments[0];
        let mut repo = segments[1];
        if repo.len() > 4 && repo.as_bytes()[repo.len() - 4..].eq_ignore_ascii_case(b".git") {
            repo = &repo[..repo.len() - 4];
        }
        if owner.is_empty()
            || repo.is_empty()
            || Self::RESERVED_OWNERS
                .iter()
                .any(|r| r.eq_ignore_ascii_case(owner))
            || !Self::is_valid_slug(owner)
            || !Self::is_valid_slug(repo)
        {
            return None;
        }
        if segments.len() == 2 {
            return Some(GitHubRepoReference {
                owner: owner.to_string(),
                repo: repo.to_string(),
                branch: None,
            });
        }
        if segments.len() == 4 && segments[2].eq_ignore_ascii_case("tree") {
            return Some(GitHubRepoReference {
                owner: owner.to_string(),
                repo: repo.to_string(),
                branch: Some(segments[3].to_string()),
            });
        }
        None
    }

    fn is_valid_slug(raw: &str) -> bool {
        raw.bytes()
            .all(|b| b.is_ascii_alphanumeric() || matches!(b, b'-' | b'_' | b'.'))
    }

    /// Extracts the first GitHub repository URL embedded in plain text or a share snippet.
    pub fn extract_repo_url(raw: &str) -> Option<Url> {
        for token in raw.split_whitespace() {
            let cleaned = token
                .trim_start_matches(['<', '(', '[', '"', '\'', '（', '【'])
                .trim_end_matches([
                    '>', ')', ']', '"', '\'', ',', ';', '!', '.', '，', '。', '！', '）', '】',
                ]);
            if let Ok(url) = Url::parse(cleaned) {
                if Self::parse(&url).is_some() {
                    return Some(url);
                }
            }
        }
        None
    }
}

pub struct GitHubRepoResolver;

impl GitHubRepoResolver {
    pub fn decode_base64_markdown(encoded: &str) -> Option<String> {
        let compact: String = encoded.chars().filter(|c| !c.is_whitespace()).collect();
        let bytes = BASE64_STD.decode(compact).ok()?;
        let text = String::from_utf8(bytes).ok()?;
        Some(text.chars().take(120_000).collect())
    }

    pub async fn resolve(reference: &GitHubRepoReference) -> GitHubRepoMetadata {
        let client = http_client(10);
        let (info, api_readme) = tokio::join!(
            Self::fetch_repo_info(&client, reference),
            Self::fetch_readme_via_api(&client, reference)
        );
        let default_branch = reference
            .branch
            .clone()
            .or_else(|| info.as_ref().and_then(|i| i.default_branch.clone()))
            .unwrap_or_else(|| "main".to_string());

        let readme = match api_readme {
            Some(ref r) if !r.trim().is_empty() => api_readme,
            _ => Self::fetch_raw_readme(&client, reference, &default_branch).await,
        };

        let resolved_owner = info
            .as_ref()
            .and_then(|i| i.owner.as_ref())
            .and_then(|o| o.login.clone())
            .unwrap_or_else(|| reference.owner.clone());
        let resolved_repo = info
            .as_ref()
            .and_then(|i| i.name.clone())
            .unwrap_or_else(|| reference.repo.clone());

        // If the GitHub REST API was rate-limited or unavailable, rescue description & custom
        // OpenGraph social preview directly from the public repository HTML page.
        let html_fallback = if info.is_none() {
            Url::parse(&reference.canonical_url())
                .ok()
                .map(|u| async move { WebBookmarkResolver::fetch(&u).await })
        } else {
            None
        };
        let html_meta = match html_fallback {
            Some(fut) => Some(fut.await),
            None => None,
        };

        let description = info
            .as_ref()
            .and_then(|i| i.description.as_deref())
            .map(|s| s.trim().to_string())
            .filter(|s| !s.is_empty())
            .or_else(|| {
                html_meta
                    .as_ref()
                    .and_then(|bm| bm.description.clone())
                    .filter(|s| !s.trim().is_empty())
            });
        let open_graph_image_url = html_meta
            .as_ref()
            .and_then(|bm| bm.poster_url.clone())
            .filter(|s| !s.trim().is_empty())
            .or_else(|| {
                Some(format!(
                    "https://opengraph.githubassets.com/1/{resolved_owner}/{resolved_repo}"
                ))
            });

        GitHubRepoMetadata {
            owner: resolved_owner.clone(),
            repo: resolved_repo.clone(),
            full_name: info
                .as_ref()
                .and_then(|i| i.full_name.clone())
                .unwrap_or_else(|| reference.full_name()),
            owner_avatar_url: info
                .as_ref()
                .and_then(|i| i.owner.as_ref())
                .and_then(|o| o.avatar_url.clone()),
            description,
            stars: info.as_ref().and_then(|i| i.stargazers_count).unwrap_or(0),
            forks: info.as_ref().and_then(|i| i.forks_count).unwrap_or(0),
            watchers: info
                .as_ref()
                .and_then(|i| i.subscribers_count.or(i.watchers_count)),
            language: info.as_ref().and_then(|i| i.language.clone()),
            license_name: info
                .as_ref()
                .and_then(|i| i.license.as_ref())
                .and_then(|l| l.spdx_id.clone().or_else(|| l.name.clone())),
            topics: info
                .as_ref()
                .and_then(|i| i.topics.clone())
                .unwrap_or_default()
                .into_iter()
                .take(16)
                .collect(),
            default_branch,
            homepage_url: info
                .as_ref()
                .and_then(|i| i.homepage.as_deref())
                .map(|s| s.trim().to_string())
                .filter(|s| !s.is_empty()),
            open_graph_image_url,
            readme_markdown: readme,
            fetched_at: Utc::now(),
        }
    }

    pub async fn fetch_open_graph_image(repo: &GitHubRepoMetadata) -> Option<DynamicImage> {
        let client = http_client(8);
        let mut candidates = Vec::new();
        if let Some(ref custom) = repo.open_graph_image_url {
            if !custom.trim().is_empty() {
                candidates.push(custom.trim().to_string());
            }
        }
        let standard = format!(
            "https://opengraph.githubassets.com/1/{}/{}",
            repo.owner, repo.repo
        );
        if !candidates.contains(&standard) {
            candidates.push(standard);
        }
        for url in candidates {
            let Ok(resp) = client
                .get(&url)
                .header("Accept", "image/png,image/webp,image/jpeg,image/*")
                .send()
                .await
            else {
                continue;
            };
            if !resp.status().is_success() {
                continue;
            }
            let Ok(bytes) = resp.bytes().await else {
                continue;
            };
            if bytes.len() > MAX_OG_IMAGE_BYTES {
                continue;
            }
            if let Ok(img) = image::load_from_memory(&bytes) {
                if img.width() >= 200 && img.height() >= 100 {
                    return Some(img);
                }
            }
        }
        None
    }

    async fn fetch_repo_info(
        client: &Client,
        reference: &GitHubRepoReference,
    ) -> Option<GitHubRepoApiResponse> {
        let url = format!(
            "https://api.github.com/repos/{}/{}",
            reference.owner, reference.repo
        );
        let resp = client
            .get(url)
            .header("Accept", "application/vnd.github+json")
            .send()
            .await
            .ok()?;
        if !resp.status().is_success() {
            return None;
        }
        resp.json().await.ok()
    }

    async fn fetch_readme_via_api(
        client: &Client,
        reference: &GitHubRepoReference,
    ) -> Option<String> {
        let mut url = format!(
            "https://api.github.com/repos/{}/{}/readme",
            reference.owner, reference.repo
        );
        if let Some(ref branch) = reference.branch {
            url.push_str(&format!("?ref={branch}"));
        }
        let resp = client
            .get(url)
            .header("Accept", "application/vnd.github+json")
            .send()
            .await
            .ok()?;
        if !resp.status().is_success() {
            return None;
        }
        let payload: GitHubReadmeApiResponse = resp.json().await.ok()?;
        let content = payload.content?;
        if payload
            .encoding
            .as_deref()
            .is_some_and(|e| e.eq_ignore_ascii_case("base64"))
        {
            Self::decode_base64_markdown(&content)
        } else {
            Some(content.chars().take(120_000).collect())
        }
    }

    async fn fetch_raw_readme(
        client: &Client,
        reference: &GitHubRepoReference,
        branch: &str,
    ) -> Option<String> {
        let candidates = [
            format!(
                "https://raw.githubusercontent.com/{}/{}/{branch}/README.md",
                reference.owner, reference.repo
            ),
            format!(
                "https://raw.githubusercontent.com/{}/{}/{branch}/readme.md",
                reference.owner, reference.repo
            ),
            format!(
                "https://raw.githubusercontent.com/{}/{}/master/README.md",
                reference.owner, reference.repo
            ),
        ];
        for url in candidates {
            let Ok(resp) = client.get(&url).send().await else {
                continue;
            };
            if !resp.status().is_success() {
                continue;
            }
            if let Ok(text) = resp.text().await {
                if !text.trim().is_empty() {
                    return Some(text.chars().take(120_000).collect());
                }
            }
        }
        None
    }
}

#[derive(Deserialize)]
struct GitHubRepoApiResponse {
    name: Option<String>,
    full_name: Option<String>,
    description: Option<String>,
    stargazers_count: Option<i64>,
    forks_count: Option<i64>,
    watchers_count: Option<i64>,
    subscribers_count: Option<i64>,
    language: Option<String>,
    license: Option<GitHubLicense>,
    topics: Option<Vec<String>>,
    default_branch: Option<String>,
    homepage: Option<String>,
    owner: Option<GitHubOwner>,
}

#[derive(Deserialize)]
struct GitHubOwner {
    login: Option<String>,
    avatar_url: Option<String>,
}

#[derive(Deserialize)]
struct GitHubLicense {
    spdx_id: Option<String>,
    name: Option<String>,
}

#[derive(Deserialize)]
struct GitHubReadmeApiResponse {
    content: Option<String>,
    encoding: Option<String>,
}

// =============================================================================
// 3. X / Twitter, Bluesky & Threads Social Post Resolvers
// =============================================================================

#[derive(Debug, Clone, PartialEq, Eq, Hash)]
pub struct XPostReference {
    pub handle: String,
    pub tweet_id: String,
}

impl XPostReference {
    pub fn canonical_url(&self) -> String {
        format!("https://x.com/{}/status/{}", self.handle, self.tweet_id)
    }
}

pub struct XPostURLParser;

impl XPostURLParser {
    const SUPPORTED_HOSTS: &'static [&'static str] = &[
        "x.com",
        "www.x.com",
        "mobile.x.com",
        "twitter.com",
        "www.twitter.com",
        "mobile.twitter.com",
        "fxtwitter.com",
        "www.fxtwitter.com",
        "vxtwitter.com",
        "www.vxtwitter.com",
        "fixupx.com",
        "www.fixupx.com",
        "fixvx.com",
        "www.fixvx.com",
    ];

    pub fn parse(url: &Url) -> Option<XPostReference> {
        if !matches!(url.scheme(), "http" | "https") {
            return None;
        }
        let host = url.host_str()?.to_ascii_lowercase();
        if !Self::SUPPORTED_HOSTS.contains(&host.as_str()) {
            return None;
        }
        let segments: Vec<&str> = url.path_segments()?.filter(|s| !s.is_empty()).collect();
        let status_idx = segments
            .iter()
            .position(|s| s.eq_ignore_ascii_case("status") || s.eq_ignore_ascii_case("statuses"))?;
        let raw_id = *segments.get(status_idx + 1)?;
        if raw_id.is_empty() || raw_id.len() > 24 || !raw_id.bytes().all(|b| b.is_ascii_digit()) {
            return None;
        }
        let raw_handle = if status_idx >= 1 {
            let candidate = segments[status_idx - 1];
            if candidate.eq_ignore_ascii_case("web") && status_idx >= 2 {
                segments[status_idx - 2]
            } else {
                candidate
            }
        } else {
            "i"
        };
        let clean = raw_handle.trim_matches('@');
        let handle = if !clean.is_empty()
            && clean
                .bytes()
                .all(|b| b.is_ascii_alphanumeric() || b == b'_')
        {
            clean.to_string()
        } else {
            "i".to_string()
        };
        Some(XPostReference {
            handle,
            tweet_id: raw_id.to_string(),
        })
    }

    /// Rewrites `pbs.twimg.com` photo URLs with query parameter `name=orig`.
    pub fn upgrade_twitter_image_url(raw: &str) -> String {
        let Ok(mut url) = Url::parse(raw) else {
            return raw.to_string();
        };
        if !url
            .host_str()
            .is_some_and(|h| h.to_ascii_lowercase().contains("twimg.com"))
        {
            return raw.to_string();
        }
        let mut pairs: Vec<(String, String)> = url
            .query_pairs()
            .map(|(k, v)| (k.into_owned(), v.into_owned()))
            .collect();
        if let Some((_, val)) = pairs.iter_mut().find(|(k, _)| k == "name") {
            *val = "orig".to_string();
        } else {
            pairs.push(("name".to_string(), "orig".to_string()));
        }
        url.query_pairs_mut().clear().extend_pairs(pairs);
        url.to_string()
    }
}

#[derive(Debug, Clone, PartialEq, Eq, Hash)]
pub enum SocialPostReference {
    X(XPostReference),
    Threads {
        handle: String,
        post_id: String,
        canonical_url: String,
    },
    Bluesky {
        handle: String,
        rkey: String,
        canonical_url: String,
    },
    Xiaohongshu(XiaohongshuNoteReference),
}

impl SocialPostReference {
    pub fn platform(&self) -> SocialPlatform {
        match self {
            Self::X(_) => SocialPlatform::X,
            Self::Threads { .. } => SocialPlatform::Threads,
            Self::Bluesky { .. } => SocialPlatform::Bluesky,
            Self::Xiaohongshu(_) => SocialPlatform::Xiaohongshu,
        }
    }

    pub fn canonical_url(&self) -> String {
        match self {
            Self::X(r) => r.canonical_url(),
            Self::Threads { canonical_url, .. } => canonical_url.clone(),
            Self::Bluesky { canonical_url, .. } => canonical_url.clone(),
            Self::Xiaohongshu(r) => r.canonical_url(),
        }
    }

    /// Stable cross-platform deduplication key independent of rotating query params (`xsec_token`, `s=20`).
    pub fn dedup_key(&self) -> String {
        match self {
            Self::X(r) => format!("x:{}", r.tweet_id),
            Self::Threads { post_id, .. } => format!("threads:{post_id}"),
            Self::Bluesky { handle, rkey, .. } => {
                format!("bsky:{}:{rkey}", handle.to_ascii_lowercase())
            }
            Self::Xiaohongshu(r) => r.dedup_key(),
        }
    }
}

/// Computes a stable cross-platform deduplication key for any social or generic web URL string,
/// matching the browser extension (`url-detect.js::canonicalDedupKey`) and macOS `SocialPostResolver`.
pub fn canonical_dedup_key(raw_url: &str) -> Option<String> {
    let trimmed = raw_url.trim();
    if trimmed.is_empty() {
        return None;
    }
    let parsed = Url::parse(trimmed).ok()?;
    if let Some(social_ref) = SocialPostURLParser::parse(&parsed) {
        return Some(social_ref.dedup_key());
    }
    Some(format!("url:{}", trimmed.to_ascii_lowercase()))
}

pub struct SocialPostURLParser;

impl SocialPostURLParser {
    pub fn parse(url: &Url) -> Option<SocialPostReference> {
        if let Some(x_ref) = XPostURLParser::parse(url) {
            return Some(SocialPostReference::X(x_ref));
        }
        if let Some(xhs_ref) = XiaohongshuURLParser::parse(url) {
            return Some(SocialPostReference::Xiaohongshu(xhs_ref));
        }
        if !matches!(url.scheme(), "http" | "https") {
            return None;
        }
        let host = url.host_str()?.to_ascii_lowercase();
        let segments: Vec<&str> = url.path_segments()?.filter(|s| !s.is_empty()).collect();

        if matches!(
            host.as_str(),
            "threads.net" | "www.threads.net" | "threads.com" | "www.threads.com"
        ) {
            if let Some(post_idx) = segments.iter().position(|s| s.eq_ignore_ascii_case("post")) {
                if let Some(&code) = segments.get(post_idx + 1) {
                    let raw_handle = if post_idx >= 1 {
                        segments[post_idx - 1]
                    } else {
                        "threads"
                    };
                    let clean = raw_handle.trim_matches('@');
                    if !clean.is_empty() && !code.is_empty() {
                        return Some(SocialPostReference::Threads {
                            handle: clean.to_string(),
                            post_id: code.to_string(),
                            canonical_url: format!("https://www.threads.net/@{clean}/post/{code}"),
                        });
                    }
                }
            }
            if segments.len() >= 2 && segments[0].eq_ignore_ascii_case("t") {
                let code = segments[1];
                return Some(SocialPostReference::Threads {
                    handle: "threads".to_string(),
                    post_id: code.to_string(),
                    canonical_url: format!("https://www.threads.net/t/{code}"),
                });
            }
        }

        if (host == "bsky.app" || host == "www.bsky.app")
            && segments.len() >= 4
            && segments[0].eq_ignore_ascii_case("profile")
            && segments[2].eq_ignore_ascii_case("post")
        {
            let handle = segments[1];
            let rkey = segments[3];
            if !handle.is_empty() && !rkey.is_empty() {
                return Some(SocialPostReference::Bluesky {
                    handle: handle.to_string(),
                    rkey: rkey.to_string(),
                    canonical_url: format!("https://bsky.app/profile/{handle}/post/{rkey}"),
                });
            }
        }

        None
    }

    /// Extracts the first X/Threads/Bluesky/Xiaohongshu post URL embedded in plain text or share copy.
    pub fn extract_post_url(raw: &str) -> Option<Url> {
        if let Some(xhs_url) = XiaohongshuURLParser::extract_note_url(raw) {
            return Some(xhs_url);
        }
        for token in raw.split_whitespace() {
            let cleaned = token
                .trim_start_matches(['<', '(', '[', '"', '\'', '（', '【'])
                .trim_end_matches([
                    '>', ')', ']', '"', '\'', ',', ';', '!', '.', '，', '。', '！', '）', '】',
                ]);
            if let Ok(url) = Url::parse(cleaned) {
                if Self::parse(&url).is_some() {
                    return Some(url);
                }
            }
        }
        None
    }
}

#[derive(Debug, Clone)]
pub struct ResolvedSocialPost {
    pub metadata: SocialPostMetadata,
    pub primary_media_download_url: Option<String>,
    pub primary_media_kind: Option<SocialMediaAttachmentKind>,
    pub primary_thumbnail_url: Option<String>,
    pub extracted_tags: Vec<String>,
}

impl ResolvedSocialPost {
    pub fn short_title(&self) -> String {
        let candidate = self
            .metadata
            .article_title
            .as_deref()
            .map(str::trim)
            .filter(|s| !s.is_empty())
            .map(String::from)
            .or_else(|| {
                let cleaned = self.metadata.body_text.replace('\n', " ");
                let t = cleaned.trim();
                if t.is_empty() {
                    None
                } else {
                    Some(t.to_string())
                }
            });
        let author_prefix = if self.metadata.platform == SocialPlatform::Xiaohongshu {
            self.metadata.display_author_name()
        } else {
            format!("@{}", self.metadata.author_handle)
        };
        match candidate {
            Some(headline) => {
                let trimmed: String = headline.chars().take(44).collect();
                format!("{author_prefix} · {trimmed}")
            }
            None => format!(
                "{author_prefix} · {}",
                self.metadata.platform.display_name()
            ),
        }
    }

    pub fn markdown_document(&self) -> String {
        let mut lines = Vec::new();
        let clean_name = self.metadata.display_author_name();
        let display = match self.metadata.display_handle_line() {
            Some(handle_line) => {
                if clean_name.is_empty() {
                    handle_line
                } else {
                    format!("{clean_name} ({handle_line})")
                }
            }
            None => {
                if clean_name.is_empty() {
                    self.metadata.platform.display_name().to_string()
                } else {
                    clean_name
                }
            }
        };
        lines.push(format!("# {display}"));
        let mut sub = vec![self.metadata.platform.display_name().to_string()];
        if let Some(ref date) = self.metadata.published_at_text {
            if !date.is_empty() {
                sub.push(date.clone());
            }
        }
        lines.push(format!("_{}_", sub.join(" · ")));
        if let Some(ref article_title) = self.metadata.article_title {
            if !article_title.is_empty() {
                lines.push(String::new());
                lines.push(format!("## {article_title}"));
            }
        }
        let body = self.metadata.body_text.trim();
        if !body.is_empty() {
            lines.push(String::new());
            lines.push(body.to_string());
        }
        if let Some(ref quoted) = self.metadata.quoted_text {
            let qt = quoted.trim();
            if !qt.is_empty() {
                lines.push(String::new());
                if let Some(ref qa) = self.metadata.quoted_author {
                    if !qa.is_empty() {
                        lines.push(format!("> **{qa}**"));
                    }
                }
                for l in qt.lines() {
                    lines.push(format!("> {l}"));
                }
            }
        }
        lines.push(String::new());
        lines.push(format!("原链接：{}", self.metadata.original_url));
        lines.join("\n")
    }
}

pub struct SocialPostResolver;

impl SocialPostResolver {
    pub fn canonical_dedup_key(raw_url: &str) -> Option<String> {
        canonical_dedup_key(raw_url)
    }

    /// Merges live-resolved metadata over fallback/extension-supplied metadata without ever
    /// degrading richer attachments, metrics, or text when remote sites throttle.
    pub fn merge_metadata(
        live: SocialPostMetadata,
        fallback: SocialPostMetadata,
    ) -> SocialPostMetadata {
        let pick_str = |a: &str, b: &str| {
            if !a.trim().is_empty() {
                a.to_string()
            } else {
                b.to_string()
            }
        };
        let pick_opt = |a: Option<String>, b: Option<String>| {
            a.filter(|s| !s.trim().is_empty())
                .or_else(|| b.filter(|s| !s.trim().is_empty()))
        };

        let live_atts = live.effective_attachments();
        let fb_atts = fallback.effective_attachments();
        let attachments = if live_atts.len() >= fb_atts.len() && !live_atts.is_empty() {
            live_atts
        } else if !fb_atts.is_empty() {
            fb_atts
        } else {
            Vec::new()
        };

        let media_urls: Vec<String> = if !attachments.is_empty() {
            attachments.iter().map(|a| a.url.clone()).collect()
        } else if !live.media_urls.is_empty() {
            live.media_urls
        } else {
            fallback.media_urls
        };
        let media_thumbnail_urls: Vec<String> = if !attachments.is_empty() {
            attachments
                .iter()
                .filter_map(|a| {
                    a.thumbnail_url.clone().or_else(|| {
                        (a.kind == SocialMediaAttachmentKind::Photo).then(|| a.url.clone())
                    })
                })
                .collect()
        } else if !live.media_thumbnail_urls.is_empty() {
            live.media_thumbnail_urls
        } else {
            fallback.media_thumbnail_urls
        };

        let body_text = if live.body_text.trim().chars().count()
            >= fallback.body_text.trim().chars().count()
            && !live.body_text.trim().is_empty()
        {
            live.body_text
        } else {
            fallback.body_text
        };

        let author_name = if live.author_name.trim().is_empty()
            || live.author_name.trim() == "小红书笔记"
            || live.author_name.trim() == "小红书用户"
        {
            pick_str(&fallback.author_name, &live.author_name)
        } else {
            live.author_name
        };

        // Preserve xsec_token when fallback had it and live dropped it
        let original_url = if fallback.original_url.contains("xsec_token=")
            && !live.original_url.contains("xsec_token=")
        {
            fallback.original_url
        } else {
            pick_str(&live.original_url, &fallback.original_url)
        };

        SocialPostMetadata {
            platform: live.platform,
            author_name,
            author_handle: pick_str(&live.author_handle, &fallback.author_handle),
            author_avatar_url: pick_opt(live.author_avatar_url, fallback.author_avatar_url),
            published_at_text: pick_opt(live.published_at_text, fallback.published_at_text),
            body_text,
            quoted_author: pick_opt(live.quoted_author, fallback.quoted_author),
            quoted_text: pick_opt(live.quoted_text, fallback.quoted_text),
            article_title: pick_opt(live.article_title, fallback.article_title),
            media_urls,
            media_thumbnail_urls,
            attachments,
            has_video: live.has_video || fallback.has_video,
            video_url: pick_opt(live.video_url, fallback.video_url),
            reply_count: live.reply_count.or(fallback.reply_count),
            repost_count: live.repost_count.or(fallback.repost_count),
            like_count: live.like_count.or(fallback.like_count),
            view_count: live.view_count.or(fallback.view_count),
            original_url,
            media_fetch_failed: live.media_fetch_failed && fallback.media_fetch_failed,
        }
    }

    pub async fn resolve(reference: &SocialPostReference) -> Option<ResolvedSocialPost> {
        match reference {
            SocialPostReference::X(x_ref) => Self::resolve_x(x_ref).await,
            SocialPostReference::Bluesky {
                handle,
                rkey,
                canonical_url,
            } => Self::resolve_bluesky(handle, rkey, canonical_url).await,
            SocialPostReference::Threads {
                handle,
                canonical_url,
                ..
            } => Some(
                Self::resolve_og_fallback(SocialPlatform::Threads, handle, canonical_url).await,
            ),
            SocialPostReference::Xiaohongshu(xhs_ref) => {
                XiaohongshuPostResolver::resolve(xhs_ref).await
            }
        }
    }

    pub async fn download_media_bytes(
        url_str: &str,
        kind: SocialMediaAttachmentKind,
    ) -> Option<(Vec<u8>, String)> {
        let max_bytes = if kind == SocialMediaAttachmentKind::Photo {
            MAX_SOCIAL_PHOTO_BYTES
        } else {
            MAX_SOCIAL_VIDEO_BYTES
        };
        let candidate = if kind == SocialMediaAttachmentKind::Photo {
            XPostURLParser::upgrade_twitter_image_url(url_str)
        } else {
            url_str.to_string()
        };
        let url = Url::parse(&candidate).ok()?;
        if !WebBookmarkResolver::is_web_url(&url) {
            return None;
        }
        let is_xhs = XiaohongshuURLParser::is_xiaohongshu_media_host(url.host_str());
        let client = if is_xhs {
            browser_http_client(30)
        } else {
            http_client(30)
        };
        let mut req = client.get(url.clone());
        if is_xhs {
            req = req.header("Referer", XIAOHONGSHU_REFERER).header(
                "Accept",
                "image/avif,image/webp,image/png,image/jpeg,video/mp4,*/*;q=0.8",
            );
        }
        let resp = req.send().await.ok()?;
        if !resp.status().is_success() {
            return None;
        }
        let mime = resp
            .headers()
            .get(reqwest::header::CONTENT_TYPE)
            .and_then(|v| v.to_str().ok())
            .map(String::from);
        let bytes = resp.bytes().await.ok()?;
        if bytes.is_empty() || bytes.len() > max_bytes {
            return None;
        }
        let ext = resolve_media_extension(&url, mime.as_deref(), kind);
        Some((bytes.to_vec(), ext))
    }

    /// Upgrades low-resolution Twitter `_normal` profile avatars to `_400x400` matching macOS.
    pub fn upgrade_avatar_url(raw: &str) -> String {
        let lower = raw.to_ascii_lowercase();
        if lower.contains("pbs.twimg.com/profile_images/") && raw.contains("_normal.") {
            raw.replacen("_normal.", "_400x400.", 1)
        } else {
            raw.to_string()
        }
    }

    /// Fetches and decodes a social post author's avatar image (`<= 4 MiB`, best-effort).
    pub async fn fetch_avatar_image(url_str: &str) -> Option<DynamicImage> {
        let upgraded = Self::upgrade_avatar_url(url_str.trim());
        let url = Url::parse(&upgraded).ok()?;
        if !WebBookmarkResolver::is_web_url(&url) {
            return None;
        }
        let is_xhs = XiaohongshuURLParser::is_xiaohongshu_media_host(url.host_str());
        let client = if is_xhs {
            browser_http_client(10)
        } else {
            http_client(10)
        };
        let mut req = client
            .get(url)
            .header("Accept", "image/webp,image/png,image/jpeg,image/*");
        if is_xhs {
            req = req.header("Referer", XIAOHONGSHU_REFERER);
        }
        let resp = req.send().await.ok()?;
        if !resp.status().is_success() {
            return None;
        }
        let bytes = resp.bytes().await.ok()?;
        if bytes.is_empty() || bytes.len() > 4 * 1024 * 1024 {
            return None;
        }
        image::load_from_memory(&bytes).ok()
    }

    async fn resolve_x(x_ref: &XPostReference) -> Option<ResolvedSocialPost> {
        let client = http_client(10);
        if let Some(post) = Self::fetch_fxtwitter(&client, x_ref).await {
            return Some(post);
        }
        if let Some(post) = Self::fetch_vxtwitter(&client, x_ref).await {
            return Some(post);
        }
        if let Some(post) = Self::fetch_x_oembed(&client, x_ref).await {
            return Some(post);
        }
        let canonical = x_ref.canonical_url();
        Some(Self::resolve_og_fallback(SocialPlatform::X, &x_ref.handle, &canonical).await)
    }

    async fn fetch_x_oembed(client: &Client, x_ref: &XPostReference) -> Option<ResolvedSocialPost> {
        let canonical = x_ref.canonical_url();
        let mut endpoint = Url::parse("https://publish.twitter.com/oembed").ok()?;
        endpoint
            .query_pairs_mut()
            .append_pair("url", &canonical)
            .append_pair("omit_script", "true");
        let resp = client
            .get(endpoint)
            .header("Accept", "application/json")
            .send()
            .await
            .ok()?;
        if !resp.status().is_success() {
            return None;
        }
        let payload: XOEmbedResponse = resp.json().await.ok()?;
        let body_text = payload
            .html
            .as_deref()
            .map(extract_x_oembed_text)
            .unwrap_or_default();
        if body_text.is_empty() && payload.author_name.is_none() {
            return None;
        }
        let handle = payload
            .author_url
            .as_deref()
            .and_then(|raw| Url::parse(raw).ok())
            .and_then(|u| {
                u.path_segments()
                    .and_then(|mut s| s.find(|seg| !seg.is_empty()).map(str::to_string))
            })
            .filter(|h| !h.trim().is_empty())
            .unwrap_or_else(|| x_ref.handle.clone());
        let author_name = payload
            .author_name
            .filter(|s| !s.trim().is_empty())
            .unwrap_or_else(|| handle.clone());

        let metadata = SocialPostMetadata {
            platform: SocialPlatform::X,
            author_name,
            author_handle: handle.clone(),
            author_avatar_url: None,
            published_at_text: None,
            body_text,
            quoted_author: None,
            quoted_text: None,
            article_title: None,
            media_urls: Vec::new(),
            media_thumbnail_urls: Vec::new(),
            attachments: Vec::new(),
            has_video: false,
            video_url: None,
            reply_count: None,
            repost_count: None,
            like_count: None,
            view_count: None,
            original_url: format!("https://x.com/{handle}/status/{}", x_ref.tweet_id),
            media_fetch_failed: false,
        };
        Some(ResolvedSocialPost {
            metadata,
            primary_media_download_url: None,
            primary_media_kind: None,
            primary_thumbnail_url: None,
            extracted_tags: Vec::new(),
        })
    }

    async fn fetch_fxtwitter(
        client: &Client,
        x_ref: &XPostReference,
    ) -> Option<ResolvedSocialPost> {
        let api_url = format!(
            "https://api.fxtwitter.com/{}/status/{}",
            x_ref.handle, x_ref.tweet_id
        );
        let resp = client
            .get(api_url)
            .header("Accept", "application/json")
            .send()
            .await
            .ok()?;
        if !resp.status().is_success() {
            return None;
        }
        let payload: FxResponse = resp.json().await.ok()?;
        let tweet = payload.tweet?;

        let handle = tweet
            .author
            .as_ref()
            .and_then(|a| a.screen_name.as_deref())
            .filter(|s| !s.trim().is_empty())
            .unwrap_or(&x_ref.handle)
            .to_string();
        let author_name = tweet
            .author
            .as_ref()
            .and_then(|a| a.name.as_deref())
            .filter(|s| !s.trim().is_empty())
            .unwrap_or(&handle)
            .to_string();
        let body_text = tweet
            .raw_text
            .as_ref()
            .and_then(|r| r.text.as_deref())
            .filter(|s| !s.trim().is_empty())
            .or_else(|| tweet.text.as_deref().filter(|s| !s.trim().is_empty()))
            .or_else(|| {
                tweet
                    .article
                    .as_ref()
                    .and_then(|a| a.preview_text.as_deref())
                    .filter(|s| !s.trim().is_empty())
            })
            .unwrap_or("")
            .to_string();

        let mut attachments = extract_fx_attachments(tweet.media.as_ref());
        if attachments.is_empty() {
            if let Some(cover) = tweet
                .article
                .as_ref()
                .and_then(|a| a.cover_media.as_ref())
                .and_then(|c| c.media_info.as_ref())
                .and_then(|m| m.original_img_url.as_deref())
            {
                if Url::parse(cover)
                    .ok()
                    .is_some_and(|u| WebBookmarkResolver::is_web_url(&u))
                {
                    attachments.push(SocialMediaAttachment::new(
                        SocialMediaAttachmentKind::Photo,
                        cover.to_string(),
                        Some(cover.to_string()),
                    ));
                }
            }
        }
        if attachments.is_empty() {
            attachments =
                extract_fx_attachments(tweet.quote.as_ref().and_then(|q| q.media.as_ref()));
        }

        let quoted_author = tweet
            .quote
            .as_ref()
            .and_then(|q| q.author.as_ref())
            .and_then(|a| {
                match (
                    a.name.as_deref().filter(|s| !s.is_empty()),
                    a.screen_name.as_deref().filter(|s| !s.is_empty()),
                ) {
                    (Some(n), Some(h)) => Some(format!("{n} (@{h})")),
                    (None, Some(h)) => Some(format!("@{h}")),
                    (Some(n), None) => Some(n.to_string()),
                    (None, None) => None,
                }
            });
        let quoted_text = tweet.quote.as_ref().and_then(|q| {
            q.raw_text
                .as_ref()
                .and_then(|r| r.text.clone())
                .or_else(|| q.text.clone())
        });

        let video_item = attachments
            .iter()
            .find(|a| {
                matches!(
                    a.kind,
                    SocialMediaAttachmentKind::Video | SocialMediaAttachmentKind::Gif
                )
            })
            .cloned();
        let primary = video_item.clone().or_else(|| attachments.first().cloned());
        let media_urls: Vec<String> = attachments.iter().map(|a| a.url.clone()).collect();
        let thumb_urls: Vec<String> = attachments
            .iter()
            .filter_map(|a| {
                a.thumbnail_url
                    .clone()
                    .or_else(|| (a.kind == SocialMediaAttachmentKind::Photo).then(|| a.url.clone()))
            })
            .collect();

        let canonical = format!("https://x.com/{handle}/status/{}", x_ref.tweet_id);
        let metadata = SocialPostMetadata {
            platform: SocialPlatform::X,
            author_name,
            author_handle: handle,
            author_avatar_url: tweet.author.and_then(|a| a.avatar_url),
            published_at_text: tweet.created_at,
            body_text,
            quoted_author,
            quoted_text,
            article_title: tweet.article.and_then(|a| a.title),
            media_urls,
            media_thumbnail_urls: thumb_urls,
            attachments,
            has_video: video_item.is_some(),
            video_url: video_item.as_ref().map(|v| v.url.clone()),
            reply_count: tweet.replies,
            repost_count: tweet.retweets,
            like_count: tweet.likes,
            view_count: tweet.views,
            original_url: canonical,
            media_fetch_failed: false,
        };

        Some(ResolvedSocialPost {
            metadata,
            primary_media_download_url: primary.as_ref().map(|p| p.url.clone()),
            primary_media_kind: primary.as_ref().map(|p| p.kind),
            primary_thumbnail_url: primary.as_ref().and_then(|p| {
                p.thumbnail_url
                    .clone()
                    .or_else(|| (p.kind == SocialMediaAttachmentKind::Photo).then(|| p.url.clone()))
            }),
            extracted_tags: Vec::new(),
        })
    }

    async fn fetch_vxtwitter(
        client: &Client,
        x_ref: &XPostReference,
    ) -> Option<ResolvedSocialPost> {
        let api_url = format!(
            "https://api.vxtwitter.com/{}/status/{}",
            x_ref.handle, x_ref.tweet_id
        );
        let resp = client
            .get(api_url)
            .header("Accept", "application/json")
            .send()
            .await
            .ok()?;
        if !resp.status().is_success() {
            return None;
        }
        let decoded: VxResponse = resp.json().await.ok()?;
        let handle = decoded
            .user_screen_name
            .filter(|s| !s.trim().is_empty())
            .unwrap_or_else(|| x_ref.handle.clone());
        let author_name = decoded
            .user_name
            .filter(|s| !s.trim().is_empty())
            .unwrap_or_else(|| handle.clone());

        let mut attachments = Vec::new();
        let mut seen = HashSet::new();
        for item in decoded.media_extended.unwrap_or_default() {
            let Some(url_str) = item.url else { continue };
            if !Url::parse(&url_str)
                .ok()
                .is_some_and(|u| WebBookmarkResolver::is_web_url(&u))
                || !seen.insert(url_str.clone())
            {
                continue;
            }
            let kind = match item
                .media_type
                .as_deref()
                .map(str::to_ascii_lowercase)
                .as_deref()
            {
                Some("video") => SocialMediaAttachmentKind::Video,
                Some("gif" | "animated_gif") => SocialMediaAttachmentKind::Gif,
                _ => SocialMediaAttachmentKind::Photo,
            };
            attachments.push(SocialMediaAttachment::new(
                kind,
                url_str,
                item.thumbnail_url,
            ));
        }
        if attachments.is_empty() {
            for url_str in decoded.media_urls.unwrap_or_default() {
                if !seen.insert(url_str.clone()) {
                    continue;
                }
                let lower = url_str.to_ascii_lowercase();
                let kind = if lower.ends_with(".mp4") || lower.ends_with(".mov") {
                    SocialMediaAttachmentKind::Video
                } else {
                    SocialMediaAttachmentKind::Photo
                };
                attachments.push(SocialMediaAttachment::new(kind, url_str, None));
            }
        }

        let video_item = attachments
            .iter()
            .find(|a| {
                matches!(
                    a.kind,
                    SocialMediaAttachmentKind::Video | SocialMediaAttachmentKind::Gif
                )
            })
            .cloned();
        let primary = video_item.clone().or_else(|| attachments.first().cloned());
        let media_urls: Vec<String> = attachments.iter().map(|a| a.url.clone()).collect();
        let thumb_urls: Vec<String> = attachments
            .iter()
            .filter_map(|a| a.thumbnail_url.clone())
            .collect();

        let metadata = SocialPostMetadata {
            platform: SocialPlatform::X,
            author_name,
            author_handle: handle.clone(),
            author_avatar_url: decoded.user_profile_image_url,
            published_at_text: decoded.date,
            body_text: decoded.text.unwrap_or_default(),
            quoted_author: None,
            quoted_text: None,
            article_title: None,
            media_urls,
            media_thumbnail_urls: thumb_urls,
            attachments,
            has_video: video_item.is_some(),
            video_url: video_item.as_ref().map(|v| v.url.clone()),
            reply_count: decoded.replies,
            repost_count: decoded.retweets,
            like_count: decoded.likes,
            view_count: None,
            original_url: format!("https://x.com/{handle}/status/{}", x_ref.tweet_id),
            media_fetch_failed: false,
        };

        Some(ResolvedSocialPost {
            metadata,
            primary_media_download_url: primary.as_ref().map(|p| p.url.clone()),
            primary_media_kind: primary.as_ref().map(|p| p.kind),
            primary_thumbnail_url: primary.as_ref().and_then(|p| p.thumbnail_url.clone()),
            extracted_tags: Vec::new(),
        })
    }

    async fn resolve_bluesky(
        handle: &str,
        rkey: &str,
        canonical_url: &str,
    ) -> Option<ResolvedSocialPost> {
        let client = http_client(10);
        let did = if handle.starts_with("did:") {
            handle.to_string()
        } else {
            let resolve_url = format!(
                "https://public.api.bsky.app/xrpc/com.atproto.identity.resolveHandle?handle={handle}"
            );
            let did_opt = match client.get(resolve_url).send().await {
                Ok(r) if r.status().is_success() => {
                    r.json::<BskyDidResp>().await.ok().and_then(|d| d.did)
                }
                _ => None,
            };
            match did_opt {
                Some(d) => d,
                None => {
                    return Some(
                        Self::resolve_og_fallback(SocialPlatform::Bluesky, handle, canonical_url)
                            .await,
                    );
                }
            }
        };

        let at_uri = format!("at://{did}/app.bsky.feed.post/{rkey}");
        let mut thread_url =
            Url::parse("https://public.api.bsky.app/xrpc/app.bsky.feed.getPostThread").ok()?;
        thread_url
            .query_pairs_mut()
            .append_pair("uri", &at_uri)
            .append_pair("depth", "0");

        let resp = match client.get(thread_url).send().await {
            Ok(r) if r.status().is_success() => r.json::<BskyThreadResp>().await.ok(),
            _ => None,
        };
        let Some(post) = resp.and_then(|r| r.thread).and_then(|t| t.post) else {
            return Some(
                Self::resolve_og_fallback(SocialPlatform::Bluesky, handle, canonical_url).await,
            );
        };

        let author_handle = post
            .author
            .as_ref()
            .and_then(|a| a.handle.clone())
            .filter(|s| !s.is_empty())
            .unwrap_or_else(|| handle.to_string());
        let author_name = post
            .author
            .as_ref()
            .and_then(|a| a.display_name.clone())
            .filter(|s| !s.is_empty())
            .unwrap_or_else(|| author_handle.clone());
        let body_text = post
            .record
            .as_ref()
            .and_then(|r| r.text.clone())
            .unwrap_or_default();

        let images = post
            .embed
            .as_ref()
            .and_then(|e| {
                e.images
                    .clone()
                    .or_else(|| e.media.as_ref().and_then(|m| m.images.clone()))
            })
            .unwrap_or_default();
        let video_thumb = post.embed.as_ref().and_then(|e| {
            e.thumbnail
                .clone()
                .or_else(|| e.media.as_ref().and_then(|m| m.thumbnail.clone()))
        });
        let playlist = post.embed.as_ref().and_then(|e| e.playlist.clone());
        let mut attachments: Vec<SocialMediaAttachment> = images
            .iter()
            .filter_map(|img| {
                let u = img.fullsize.clone().or_else(|| img.thumb.clone())?;
                Some(SocialMediaAttachment::new(
                    SocialMediaAttachmentKind::Photo,
                    u,
                    img.thumb.clone().or_else(|| img.fullsize.clone()),
                ))
            })
            .collect();
        if let Some(ref pl) = playlist {
            if !pl.is_empty() {
                attachments.push(SocialMediaAttachment::new(
                    SocialMediaAttachmentKind::Video,
                    pl.clone(),
                    video_thumb.clone(),
                ));
            }
        }
        let media_urls: Vec<String> = images
            .iter()
            .filter_map(|i| i.fullsize.clone().or_else(|| i.thumb.clone()))
            .collect();
        let mut thumb_urls: Vec<String> = images
            .iter()
            .filter_map(|i| i.thumb.clone().or_else(|| i.fullsize.clone()))
            .collect();
        if let Some(ref vt) = video_thumb {
            thumb_urls.push(vt.clone());
        }
        let has_video = playlist.is_some() || (media_urls.is_empty() && video_thumb.is_some());
        let primary_url = media_urls.first().cloned().or(video_thumb.clone());
        let primary_thumb = thumb_urls.first().cloned();

        let published = post
            .record
            .and_then(|r| r.created_at)
            .or(post.indexed_at)
            .map(|s| s.chars().take(16).collect::<String>().replace('T', " "));

        let metadata = SocialPostMetadata {
            platform: SocialPlatform::Bluesky,
            author_name,
            author_handle,
            author_avatar_url: post.author.and_then(|a| a.avatar),
            published_at_text: published,
            body_text,
            quoted_author: None,
            quoted_text: None,
            article_title: None,
            media_urls,
            media_thumbnail_urls: thumb_urls,
            attachments,
            has_video,
            video_url: playlist,
            reply_count: post.reply_count,
            repost_count: post.repost_count,
            like_count: post.like_count,
            view_count: None,
            original_url: canonical_url.to_string(),
            media_fetch_failed: false,
        };

        Some(ResolvedSocialPost {
            metadata,
            primary_media_download_url: primary_url.clone(),
            primary_media_kind: if has_video {
                Some(SocialMediaAttachmentKind::Video)
            } else if primary_url.is_some() {
                Some(SocialMediaAttachmentKind::Photo)
            } else {
                None
            },
            primary_thumbnail_url: primary_thumb,
            extracted_tags: Vec::new(),
        })
    }

    async fn resolve_og_fallback(
        platform: SocialPlatform,
        handle: &str,
        canonical_url: &str,
    ) -> ResolvedSocialPost {
        let parsed = Url::parse(canonical_url).ok();
        let bookmark = match parsed.as_ref() {
            Some(u) => WebBookmarkResolver::fetch(u).await,
            None => ResolvedWebBookmark::default(),
        };
        let author_name = bookmark
            .title
            .as_deref()
            .and_then(|t| {
                t.split(" (@")
                    .next()
                    .filter(|p| *p != t)
                    .or_else(|| t.split(" on ").next().filter(|p| *p != t))
            })
            .map(|s| s.trim().to_string())
            .filter(|s| !s.is_empty())
            .unwrap_or_else(|| handle.to_string());

        let body_text = bookmark
            .description
            .unwrap_or_else(|| canonical_url.to_string());
        let media_urls: Vec<String> = bookmark.poster_url.clone().into_iter().collect();
        let attachments: Vec<SocialMediaAttachment> = media_urls
            .iter()
            .map(|u| {
                SocialMediaAttachment::new(
                    SocialMediaAttachmentKind::Photo,
                    u.clone(),
                    Some(u.clone()),
                )
            })
            .collect();

        let metadata = SocialPostMetadata {
            platform,
            author_name,
            author_handle: handle.to_string(),
            author_avatar_url: None,
            published_at_text: None,
            body_text,
            quoted_author: None,
            quoted_text: None,
            article_title: None,
            media_urls: media_urls.clone(),
            media_thumbnail_urls: media_urls,
            attachments,
            has_video: false,
            video_url: None,
            reply_count: None,
            repost_count: None,
            like_count: None,
            view_count: None,
            original_url: canonical_url.to_string(),
            media_fetch_failed: false,
        };

        ResolvedSocialPost {
            metadata,
            primary_media_download_url: bookmark.poster_url.clone(),
            primary_media_kind: bookmark
                .poster_url
                .as_ref()
                .map(|_| SocialMediaAttachmentKind::Photo),
            primary_thumbnail_url: bookmark.poster_url,
            extracted_tags: Vec::new(),
        }
    }
}

fn extract_fx_attachments(block: Option<&FxMediaBlock>) -> Vec<SocialMediaAttachment> {
    let Some(block) = block else {
        return Vec::new();
    };
    let items: Vec<&FxMediaItem> = if let Some(ref all) = block.all {
        if !all.is_empty() {
            all.iter().collect()
        } else {
            block
                .photos
                .iter()
                .flatten()
                .chain(block.videos.iter().flatten())
                .collect()
        }
    } else {
        block
            .photos
            .iter()
            .flatten()
            .chain(block.videos.iter().flatten())
            .collect()
    };

    let mut out = Vec::new();
    let mut seen = HashSet::new();
    for item in items {
        let Some(ref url_str) = item.url else {
            continue;
        };
        if !Url::parse(url_str)
            .ok()
            .is_some_and(|u| WebBookmarkResolver::is_web_url(&u))
            || !seen.insert(url_str.clone())
        {
            continue;
        }
        let kind = match item
            .media_type
            .as_deref()
            .map(str::to_ascii_lowercase)
            .as_deref()
        {
            Some("video") => SocialMediaAttachmentKind::Video,
            Some("gif" | "animated_gif") => SocialMediaAttachmentKind::Gif,
            _ => SocialMediaAttachmentKind::Photo,
        };
        let thumb = item
            .thumbnail_url
            .clone()
            .or_else(|| (kind == SocialMediaAttachmentKind::Photo).then(|| url_str.clone()));
        out.push(SocialMediaAttachment::new(kind, url_str.clone(), thumb));
    }
    out
}

fn resolve_media_extension(
    url: &Url,
    mime_type: Option<&str>,
    kind: SocialMediaAttachmentKind,
) -> String {
    if let Some(mime) = mime_type.map(str::to_ascii_lowercase) {
        if mime.contains("mp4") {
            return "mp4".to_string();
        }
        if mime.contains("quicktime") {
            return "mov".to_string();
        }
        if mime.contains("webm") {
            return "webm".to_string();
        }
        if mime.contains("gif") {
            return "gif".to_string();
        }
        if mime.contains("png") {
            return "png".to_string();
        }
        if mime.contains("webp") {
            return "webp".to_string();
        }
        if mime.contains("jpeg") || mime.contains("jpg") {
            return "jpg".to_string();
        }
    }
    if let Some(ext) = Path::new(url.path())
        .extension()
        .and_then(|e| e.to_str())
        .map(str::to_ascii_lowercase)
    {
        if matches!(
            ext.as_str(),
            "jpg" | "jpeg" | "png" | "webp" | "gif" | "mp4" | "mov" | "webm"
        ) {
            return if ext == "jpeg" {
                "jpg".to_string()
            } else {
                ext
            };
        }
    }
    if kind == SocialMediaAttachmentKind::Photo {
        "jpg".to_string()
    } else {
        "mp4".to_string()
    }
}

#[derive(Deserialize)]
struct FxResponse {
    tweet: Option<FxTweet>,
}

#[derive(Deserialize)]
struct FxTweet {
    text: Option<String>,
    raw_text: Option<FxRawText>,
    author: Option<FxAuthor>,
    created_at: Option<String>,
    media: Option<FxMediaBlock>,
    quote: Option<FxQuote>,
    article: Option<FxArticle>,
    replies: Option<i64>,
    retweets: Option<i64>,
    likes: Option<i64>,
    views: Option<i64>,
}

#[derive(Deserialize)]
struct FxQuote {
    text: Option<String>,
    raw_text: Option<FxRawText>,
    author: Option<FxAuthor>,
    media: Option<FxMediaBlock>,
}

#[derive(Deserialize)]
struct FxRawText {
    text: Option<String>,
}

#[derive(Deserialize)]
struct FxAuthor {
    name: Option<String>,
    screen_name: Option<String>,
    avatar_url: Option<String>,
}

#[derive(Deserialize)]
struct FxMediaBlock {
    all: Option<Vec<FxMediaItem>>,
    photos: Option<Vec<FxMediaItem>>,
    videos: Option<Vec<FxMediaItem>>,
}

#[derive(Deserialize)]
struct FxMediaItem {
    #[serde(rename = "type")]
    media_type: Option<String>,
    url: Option<String>,
    thumbnail_url: Option<String>,
}

#[derive(Deserialize)]
struct FxArticle {
    title: Option<String>,
    preview_text: Option<String>,
    cover_media: Option<FxCoverMedia>,
}

#[derive(Deserialize)]
struct FxCoverMedia {
    media_info: Option<FxMediaInfo>,
}

#[derive(Deserialize)]
struct FxMediaInfo {
    original_img_url: Option<String>,
}

#[derive(Deserialize)]
struct VxResponse {
    text: Option<String>,
    user_name: Option<String>,
    user_screen_name: Option<String>,
    user_profile_image_url: Option<String>,
    date: Option<String>,
    media_extended: Option<Vec<VxMediaItem>>,
    #[serde(rename = "mediaURLs")]
    media_urls: Option<Vec<String>>,
    replies: Option<i64>,
    retweets: Option<i64>,
    likes: Option<i64>,
}

#[derive(Deserialize)]
struct VxMediaItem {
    #[serde(rename = "type")]
    media_type: Option<String>,
    url: Option<String>,
    thumbnail_url: Option<String>,
}

#[derive(Deserialize)]
struct BskyDidResp {
    did: Option<String>,
}

#[derive(Deserialize)]
struct BskyThreadResp {
    thread: Option<BskyThreadNode>,
}

#[derive(Deserialize)]
struct BskyThreadNode {
    post: Option<BskyPost>,
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct BskyPost {
    author: Option<BskyAuthor>,
    record: Option<BskyRecord>,
    embed: Option<BskyEmbed>,
    reply_count: Option<i64>,
    repost_count: Option<i64>,
    like_count: Option<i64>,
    indexed_at: Option<String>,
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct BskyAuthor {
    handle: Option<String>,
    display_name: Option<String>,
    avatar: Option<String>,
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct BskyRecord {
    text: Option<String>,
    created_at: Option<String>,
}

#[derive(Deserialize)]
struct BskyEmbed {
    images: Option<Vec<BskyImage>>,
    thumbnail: Option<String>,
    playlist: Option<String>,
    media: Option<BskyNestedMedia>,
}

#[derive(Deserialize)]
struct BskyNestedMedia {
    images: Option<Vec<BskyImage>>,
    thumbnail: Option<String>,
}

#[derive(Clone, Deserialize)]
struct BskyImage {
    fullsize: Option<String>,
    thumb: Option<String>,
}

#[derive(Deserialize)]
struct XOEmbedResponse {
    author_name: Option<String>,
    author_url: Option<String>,
    html: Option<String>,
}

fn extract_x_oembed_text(html: &str) -> String {
    let doc = Html::parse_fragment(html);
    if let Ok(sel) = Selector::parse("blockquote p") {
        let paragraphs: Vec<String> = doc
            .select(&sel)
            .map(|el| {
                el.text()
                    .collect::<String>()
                    .split_whitespace()
                    .collect::<Vec<_>>()
                    .join(" ")
            })
            .filter(|s| !s.is_empty())
            .collect();
        if !paragraphs.is_empty() {
            return paragraphs.join("\n");
        }
    }
    doc.root_element()
        .text()
        .collect::<String>()
        .split_whitespace()
        .collect::<Vec<_>>()
        .join(" ")
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn parses_universal_web_html_og_twitter_favicon_and_theme_color() {
        let base = Url::parse("https://tauri.app/start/").unwrap();
        let html = r##"
        <!doctype html>
        <html>
          <head>
            <title>Tauri Docs</title>
            <meta name="theme-color" content="#24C8DB" />
            <meta property="og:title" content="  Build smaller, faster desktop apps  " />
            <meta property="og:description" content="Build cross-platform apps with Rust and web views." />
            <meta property="og:site_name" content="Tauri" />
            <meta property="og:image" content="/meta/social-card.png" />
            <meta name="twitter:image" content="https://cdn.tauri.app/twitter.png" />
            <link rel="apple-touch-icon" href="/icons/apple-touch.png" />
            <link rel="icon" type="image/svg+xml" href="/icons/logo.svg" />
          </head>
          <body></body>
        </html>
        "##;

        let parsed = WebBookmarkResolver::parse_html_rich(html, Some(&base));
        assert_eq!(
            parsed.title.as_deref(),
            Some("Build smaller, faster desktop apps")
        );
        assert_eq!(
            parsed.description.as_deref(),
            Some("Build cross-platform apps with Rust and web views.")
        );
        assert_eq!(parsed.site_name.as_deref(), Some("Tauri"));
        assert_eq!(parsed.theme_color.as_deref(), Some("#24C8DB"));
        assert_eq!(
            parsed.image_candidates,
            vec![
                "https://tauri.app/meta/social-card.png".to_string(),
                "https://cdn.tauri.app/twitter.png".to_string(),
            ]
        );
        assert_eq!(
            parsed.favicon_candidates,
            vec![
                "https://tauri.app/icons/apple-touch.png".to_string(),
                "https://tauri.app/icons/logo.svg".to_string(),
                "https://tauri.app/favicon.ico".to_string(),
            ]
        );
    }

    #[test]
    fn parses_minimal_html_falling_back_to_title_meta_desc_and_root_favicon() {
        let base = Url::parse("https://example.org/blog/post-1").unwrap();
        let html = r#"
        <html>
          <head>
            <title>Minimal Editorial Page</title>
            <meta name="description" content="Clean fallback summary." />
            <meta name="twitter:image:src" content="https://example.org/hero.webp" />
          </head>
        </html>
        "#;
        let parsed = WebBookmarkResolver::parse_html_rich(html, Some(&base));
        assert_eq!(parsed.title.as_deref(), Some("Minimal Editorial Page"));
        assert_eq!(
            parsed.description.as_deref(),
            Some("Clean fallback summary.")
        );
        assert_eq!(
            parsed.image_candidates,
            vec!["https://example.org/hero.webp".to_string()]
        );
        assert_eq!(
            parsed.favicon_candidates,
            vec!["https://example.org/favicon.ico".to_string()]
        );
    }

    #[test]
    fn extracts_clean_text_from_twitter_oembed_html() {
        let html = r#"<blockquote class="twitter-tweet"><p lang="en">Introducing liquid glass surfaces &amp; crisp motion.</p>&mdash; Charkle (@charkle)</blockquote>"#;
        assert_eq!(
            extract_x_oembed_text(html),
            "Introducing liquid glass surfaces & crisp motion."
        );
    }

    #[test]
    fn parses_github_and_social_urls_accurately() {
        let gh_repo = Url::parse("https://github.com/tauri-apps/tauri").unwrap();
        let gh_parsed = GitHubRepoURLParser::parse(&gh_repo).expect("repo");
        assert_eq!(gh_parsed.full_name(), "tauri-apps/tauri");

        let gh_settings = Url::parse("https://github.com/settings/profile").unwrap();
        assert!(GitHubRepoURLParser::parse(&gh_settings).is_none());

        let x_url = Url::parse("https://x.com/charkle_design/status/1900000001").unwrap();
        assert!(matches!(
            SocialPostURLParser::parse(&x_url),
            Some(SocialPostReference::X(_))
        ));

        let xhs_url = Url::parse(
            "https://www.xiaohongshu.com/explore/67a1b2c3d4e5f60718293a4b?xsec_token=FIRST",
        )
        .unwrap();
        assert!(matches!(
            SocialPostURLParser::parse(&xhs_url),
            Some(SocialPostReference::Xiaohongshu(_))
        ));

        // Cross-platform canonical deduplication keys ignore rotating xsec_token / query noise
        assert_eq!(
            canonical_dedup_key("https://x.com/user/status/1900000001?s=20").as_deref(),
            Some("x:1900000001")
        );
        assert_eq!(
            canonical_dedup_key(
                "https://www.xiaohongshu.com/explore/67A1B2C3D4E5F60718293A4B?xsec_token=T1"
            )
            .as_deref(),
            Some("xhs:67a1b2c3d4e5f60718293a4b")
        );
        assert_eq!(
            canonical_dedup_key(
                "https://www.xiaohongshu.com/discovery/item/67a1b2c3d4e5f60718293a4b?xsec_token=T2"
            )
            .as_deref(),
            Some("xhs:67a1b2c3d4e5f60718293a4b")
        );
        assert_eq!(
            canonical_dedup_key("https://www.threads.net/@charkle/post/C9AbCdEf123").as_deref(),
            Some("threads:C9AbCdEf123")
        );
        assert_eq!(
            canonical_dedup_key("https://bsky.app/profile/Charkle.App/post/3k7abc").as_deref(),
            Some("bsky:charkle.app:3k7abc")
        );
        assert_eq!(
            canonical_dedup_key("https://Tauri.App/start/").as_deref(),
            Some("url:https://tauri.app/start/")
        );
    }

    #[test]
    fn web_url_parser_handles_wrappers_balanced_parens_www_and_short_share_copy() {
        // Case-insensitive scheme + iterative paired wrappers + trailing CJK punctuation
        assert_eq!(
            WebURLParser::parse("《HTTPS://Example.com/design/system》。").map(|u| u.to_string()),
            Some("https://example.com/design/system".to_string())
        );

        // Standalone www.<host> auto-prefixed to https://
        assert_eq!(
            WebURLParser::parse("www.figma.com/community").map(|u| u.to_string()),
            Some("https://www.figma.com/community".to_string())
        );

        // Balanced parentheses kept intact (Wikipedia style), unbalanced outer closing paren stripped
        assert_eq!(
            WebURLParser::parse("(https://en.wikipedia.org/wiki/Swift_(programming_language)).")
                .map(|u| u.to_string()),
            Some("https://en.wikipedia.org/wiki/Swift_(programming_language)".to_string())
        );

        // Reject non-http(s), credentials, and bare tokens
        assert!(WebURLParser::parse("javascript:alert(1)").is_none());
        assert!(WebURLParser::parse("https://user:pass@example.com").is_none());
        assert!(WebURLParser::parse("https://abc").is_none());
        assert!(WebURLParser::parse("README.md").is_none());

        // Short share copy (<= 320 chars & <= 5 lines) extracts explicit URL even with CJK glue
        let share = "推荐这个设计灵感站https://tauri.app/start/太棒了！";
        assert_eq!(
            WebURLParser::extract_web_url(share, true).map(|u| u.to_string()),
            Some("https://tauri.app/start/".to_string())
        );

        // Long prose (> 320 chars or > 5 lines) MUST NOT be hijacked as a URL bookmark
        let long_prose = format!("{} https://tauri.app", "设计笔记正文内容".repeat(45));
        assert!(WebURLParser::extract_web_url(&long_prose, true).is_none());
        let six_lines = "line1\nline2\nline3\nline4\nline5\nhttps://tauri.app";
        assert!(WebURLParser::extract_web_url(six_lines, true).is_none());

        // Bare filenames inside short text MUST NOT match
        assert!(WebURLParser::extract_web_url("请检查 README.md 和 photo.png", true).is_none());
    }

    #[test]
    fn decodes_gbk_gb18030_html_and_filters_interstitial_titles() {
        let html_utf8 = r#"<html><head><meta charset="gbk"><title>视觉设计灵感库</title></head><body><h1>主标题</h1></body></html>"#;
        let (encoded, _, _) = encoding_rs::GB18030.encode(html_utf8);
        let decoded = WebBookmarkResolver::decode_html(&encoded, Some("text/html; charset=gbk"));
        assert!(decoded.contains("视觉设计灵感库"));

        // Also detect <meta charset="gbk"> when Content-Type omits charset
        let decoded_meta = WebBookmarkResolver::decode_html(&encoded, Some("text/html"));
        assert!(decoded_meta.contains("视觉设计灵感库"));

        // Anti-bot / Cloudflare interstitial titles fall back cleanly to readable path — domain
        let original = Url::parse("https://www.example.com/articles/liquid-glass-guide").unwrap();
        assert_eq!(
            WebBookmarkResolver::usable_page_title(Some("Just a moment..."), Some(&original))
                .as_deref(),
            Some("liquid glass guide — example.com")
        );
        assert_eq!(
            WebBookmarkResolver::usable_page_title(Some("403 Forbidden"), Some(&original))
                .as_deref(),
            Some("liquid glass guide — example.com")
        );
        assert_eq!(
            WebBookmarkResolver::usable_page_title(Some("Real Editorial Title"), Some(&original))
                .as_deref(),
            Some("Real Editorial Title")
        );
    }

    #[test]
    fn parses_h1_title_and_json_ld_images_and_detects_blank_snapshots() {
        let base = Url::parse("https://news.example.com/post/42").unwrap();
        let html = r##"
        <html>
          <head>
            <meta name="theme-color" content="#0af" />
            <script type="application/ld+json">
              {"@context":"https://schema.org","@graph":[{"@type":"Article","image":{"url":"/media/hero.jpg"}}]}
            </script>
          </head>
          <body><h1>Editorial H1 Fallback Title</h1></body>
        </html>
        "##;
        let parsed = WebBookmarkResolver::parse_html_rich(html, Some(&base));
        assert_eq!(parsed.title.as_deref(), Some("Editorial H1 Fallback Title"));
        assert_eq!(parsed.theme_color.as_deref(), Some("#00AAFF"));
        assert_eq!(
            parsed.image_candidates,
            vec!["https://news.example.com/media/hero.jpg".to_string()]
        );

        // Blank pure-white and pure-black snapshots must be rejected; rich contrast image passes
        let blank_white = DynamicImage::ImageRgba8(image::RgbaImage::from_pixel(
            320,
            200,
            image::Rgba([255, 255, 255, 255]),
        ));
        let blank_black = DynamicImage::ImageRgba8(image::RgbaImage::from_pixel(
            320,
            200,
            image::Rgba([4, 4, 4, 255]),
        ));
        assert!(WebBookmarkResolver::is_visually_blank(&blank_white));
        assert!(WebBookmarkResolver::is_visually_blank(&blank_black));

        let mut rich = image::RgbaImage::from_pixel(320, 200, image::Rgba([245, 245, 243, 255]));
        for y in 40..160 {
            for x in 40..280 {
                rich.put_pixel(x, y, image::Rgba([37, 99, 235, 255]));
            }
        }
        assert!(!WebBookmarkResolver::is_visually_blank(
            &DynamicImage::ImageRgba8(rich)
        ));
    }

    #[tokio::test]
    async fn offline_unreachable_url_short_circuits_without_invoking_snapshotter() {
        use crate::traits::WebPageSnapshot;
        use std::sync::atomic::{AtomicUsize, Ordering};
        use std::sync::Arc;

        struct CountingSnapshotter(Arc<AtomicUsize>);
        #[async_trait::async_trait]
        impl WebPageSnapshotProvider for CountingSnapshotter {
            async fn capture_snapshot(&self, _url: &str) -> Option<WebPageSnapshot> {
                self.0.fetch_add(1, Ordering::SeqCst);
                None
            }
        }

        let calls = Arc::new(AtomicUsize::new(0));
        let provider = CountingSnapshotter(Arc::clone(&calls));
        // Unbound loopback port refuses connection immediately -> network_unreachable = true
        let url = Url::parse("http://127.0.0.1:1/unreachable-page").unwrap();
        let resolved = WebBookmarkResolver::fetch_with_snapshot(&url, Some(&provider)).await;
        assert!(resolved.network_unreachable);
        assert_eq!(calls.load(Ordering::SeqCst), 0);
        assert_eq!(
            resolved.title.as_deref(),
            Some("unreachable page — 127.0.0.1")
        );
    }
}
