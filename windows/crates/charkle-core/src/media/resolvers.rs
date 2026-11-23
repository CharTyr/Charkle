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

use crate::models::core::{
    GitHubRepoMetadata, SocialMediaAttachment, SocialMediaAttachmentKind, SocialPlatform,
    SocialPostMetadata,
};

const USER_AGENT: &str = "Charkle/1.0 (+https://charkle.app)";
const MAX_HTML_BYTES: usize = 524_288;
const MAX_OG_IMAGE_BYTES: usize = 5 * 1024 * 1024;
const MAX_SOCIAL_PHOTO_BYTES: usize = 35_000_000;
const MAX_SOCIAL_VIDEO_BYTES: usize = 160_000_000;

fn http_client(timeout_secs: u64) -> Client {
    Client::builder()
        .timeout(Duration::from_secs(timeout_secs))
        .user_agent(USER_AGENT)
        .build()
        .unwrap_or_else(|_| Client::new())
}

// =============================================================================
// 1. Generic Web Bookmark Resolver
// =============================================================================

#[derive(Debug, Clone, Default)]
pub struct ResolvedWebBookmark {
    pub title: Option<String>,
    pub description: Option<String>,
    pub poster_image: Option<DynamicImage>,
    pub poster_url: Option<String>,
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
            if trimmed.len() > 4 && trimmed[..4].eq_ignore_ascii_case("url=") {
                if let Ok(url) = Url::parse(trimmed[4..].trim()) {
                    if Self::is_web_url(&url) {
                        return Some(url);
                    }
                }
            }
        }
        // macOS .webloc XML plist (`<key>URL</key><string>https://...</string>`)
        if let Some(key_pos) = text.find("<key>URL</key>") {
            let after = &text[key_pos + "<key>URL</key>".len()..];
            if let Some(s_start) = after.find("<string>") {
                let inner = &after[s_start + "<string>".len()..];
                if let Some(s_end) = inner.find("</string>") {
                    if let Ok(url) = Url::parse(inner[..s_end].trim()) {
                        if Self::is_web_url(&url) {
                            return Some(url);
                        }
                    }
                }
            }
        }
        None
    }

    /// Parses OpenGraph metadata directly from HTML (unit-testable offline).
    pub fn parse_html(
        html: &str,
        base_url: Option<&Url>,
    ) -> (Option<String>, Option<String>, Option<String>) {
        let doc = Html::parse_document(html);
        let og_title = select_meta(&doc, "og:title");
        let title_tag = Selector::parse("title").ok().and_then(|sel| {
            doc.select(&sel)
                .next()
                .map(|el| el.text().collect::<String>())
        });
        let raw_title = og_title.or(title_tag).map(|s| {
            s.split_whitespace()
                .collect::<Vec<_>>()
                .join(" ")
                .chars()
                .take(250)
                .collect::<String>()
        });
        let title = raw_title.filter(|s| !s.is_empty());

        let description = select_meta(&doc, "og:description")
            .or_else(|| select_meta(&doc, "description"))
            .map(|s| s.trim().to_string())
            .filter(|s| !s.is_empty());

        let og_image = select_meta(&doc, "og:image").and_then(|raw| {
            let resolved = match base_url {
                Some(base) => base.join(raw.trim()).ok(),
                None => Url::parse(raw.trim()).ok(),
            }?;
            Self::is_web_url(&resolved).then(|| resolved.to_string())
        });

        (title, description, og_image)
    }

    pub async fn fetch(url: &Url) -> ResolvedWebBookmark {
        if !Self::is_web_url(url) {
            return ResolvedWebBookmark::default();
        }
        let client = http_client(7);
        let Ok(resp) = client.get(url.clone()).send().await else {
            return ResolvedWebBookmark::default();
        };
        if !resp.status().is_success() {
            return ResolvedWebBookmark::default();
        }
        let final_url = resp.url().clone();
        if !Self::is_web_url(&final_url) {
            return ResolvedWebBookmark::default();
        }
        let Ok(bytes) = resp.bytes().await else {
            return ResolvedWebBookmark::default();
        };
        let html = String::from_utf8_lossy(&bytes[..bytes.len().min(MAX_HTML_BYTES)]);
        let (title, description, poster_url) = Self::parse_html(&html, Some(&final_url));

        let mut poster_image = None;
        if let Some(ref img_url_str) = poster_url {
            if let Ok(img_url) = Url::parse(img_url_str) {
                if Self::is_web_url(&img_url) {
                    if let Ok(img_resp) = client.get(img_url).send().await {
                        if img_resp.status().is_success() {
                            if let Ok(img_bytes) = img_resp.bytes().await {
                                if img_bytes.len() <= MAX_OG_IMAGE_BYTES {
                                    poster_image = image::load_from_memory(&img_bytes).ok();
                                }
                            }
                        }
                    }
                }
            }
        }

        ResolvedWebBookmark {
            title,
            description,
            poster_image,
            poster_url,
        }
    }
}

fn select_meta(doc: &Html, name: &str) -> Option<String> {
    let sel = Selector::parse("meta").ok()?;
    for el in doc.select(&sel) {
        let key = el
            .value()
            .attr("property")
            .or_else(|| el.value().attr("name"))?;
        if key.eq_ignore_ascii_case(name) {
            if let Some(content) = el.value().attr("content") {
                let trimmed = content.trim();
                if !trimmed.is_empty() {
                    return Some(trimmed.to_string());
                }
            }
        }
    }
    None
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
        if repo.len() > 4 && repo[repo.len() - 4..].eq_ignore_ascii_case(".git") {
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
            description: info
                .as_ref()
                .and_then(|i| i.description.as_deref())
                .map(|s| s.trim().to_string())
                .filter(|s| !s.is_empty()),
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
            open_graph_image_url: Some(format!(
                "https://opengraph.githubassets.com/1/{resolved_owner}/{resolved_repo}"
            )),
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
}

impl SocialPostReference {
    pub fn platform(&self) -> SocialPlatform {
        match self {
            Self::X(_) => SocialPlatform::X,
            Self::Threads { .. } => SocialPlatform::Threads,
            Self::Bluesky { .. } => SocialPlatform::Bluesky,
        }
    }

    pub fn canonical_url(&self) -> String {
        match self {
            Self::X(r) => r.canonical_url(),
            Self::Threads { canonical_url, .. } => canonical_url.clone(),
            Self::Bluesky { canonical_url, .. } => canonical_url.clone(),
        }
    }
}

pub struct SocialPostURLParser;

impl SocialPostURLParser {
    pub fn parse(url: &Url) -> Option<SocialPostReference> {
        if let Some(x_ref) = XPostURLParser::parse(url) {
            return Some(SocialPostReference::X(x_ref));
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
}

#[derive(Debug, Clone)]
pub struct ResolvedSocialPost {
    pub metadata: SocialPostMetadata,
    pub primary_media_download_url: Option<String>,
    pub primary_media_kind: Option<SocialMediaAttachmentKind>,
    pub primary_thumbnail_url: Option<String>,
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
        match candidate {
            Some(headline) => {
                let trimmed: String = headline.chars().take(44).collect();
                format!("@{} · {trimmed}", self.metadata.author_handle)
            }
            None => format!(
                "@{} · {}",
                self.metadata.author_handle,
                self.metadata.platform.display_name()
            ),
        }
    }

    pub fn markdown_document(&self) -> String {
        let mut lines = Vec::new();
        let display = if self.metadata.author_name.is_empty() {
            format!("@{}", self.metadata.author_handle)
        } else {
            format!(
                "{} (@{})",
                self.metadata.author_name, self.metadata.author_handle
            )
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
        let client = http_client(30);
        let resp = client.get(url.clone()).send().await.ok()?;
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

    async fn resolve_x(x_ref: &XPostReference) -> Option<ResolvedSocialPost> {
        let client = http_client(10);
        if let Some(post) = Self::fetch_fxtwitter(&client, x_ref).await {
            return Some(post);
        }
        Self::fetch_vxtwitter(&client, x_ref).await
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
