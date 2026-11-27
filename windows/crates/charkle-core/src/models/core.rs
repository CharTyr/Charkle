//! Core library domain models mirroring `Sources/CharkleCore/Contracts/CoreModels.swift`.

use std::collections::{BTreeSet, HashMap, HashSet};

use chrono::{DateTime, Utc};
use serde::{Deserialize, Serialize};
use uuid::Uuid;

use crate::wire::swift_codec::{cocoa_date, cocoa_date_opt, upper_uuid, upper_uuid_opt};

#[derive(Debug, Clone, Copy, PartialEq, Eq, PartialOrd, Ord, Hash, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub enum MediaKind {
    Image,
    AnimatedImage,
    Video,
    WebBookmark,
    Document,
    DesignFile,
    Audio,
    #[serde(rename = "model3D")]
    Model3D,
}

impl MediaKind {
    pub const ALL: [MediaKind; 8] = [
        MediaKind::Image,
        MediaKind::AnimatedImage,
        MediaKind::Video,
        MediaKind::WebBookmark,
        MediaKind::Document,
        MediaKind::DesignFile,
        MediaKind::Audio,
        MediaKind::Model3D,
    ];

    pub fn raw_value(self) -> &'static str {
        match self {
            Self::Image => "image",
            Self::AnimatedImage => "animatedImage",
            Self::Video => "video",
            Self::WebBookmark => "webBookmark",
            Self::Document => "document",
            Self::DesignFile => "designFile",
            Self::Audio => "audio",
            Self::Model3D => "model3D",
        }
    }

    pub fn localized_label(self) -> &'static str {
        match self {
            Self::Image => "图片",
            Self::AnimatedImage => "动图",
            Self::Video => "视频",
            Self::WebBookmark => "网页",
            Self::Document => "文档",
            Self::DesignFile => "设计文件",
            Self::Audio => "音频",
            Self::Model3D => "3D 模型",
        }
    }

    pub fn detect(file_extension: &str, mime_type: Option<&str>) -> Self {
        let lower = file_extension
            .trim()
            .trim_start_matches('.')
            .to_ascii_lowercase();
        match lower.as_str() {
            "gif" | "apng" => Self::AnimatedImage,
            "jpg" | "jpeg" | "png" | "heic" | "heif" | "webp" | "tiff" | "tif" | "bmp" | "avif"
            | "jxl" => Self::Image,
            "mp4" | "mov" | "m4v" | "webm" | "mkv" | "avi" => Self::Video,
            "pdf" | "md" | "markdown" | "txt" | "rtf" | "docx" | "pptx" | "key" | "pages"
            | "json" | "yaml" | "yml" | "toml" | "csv" => Self::Document,
            "svg" | "psd" | "psb" | "sketch" | "fig" | "ai" | "eps" | "xd" | "afdesign"
            | "afphoto" => Self::DesignFile,
            "mp3" | "wav" | "m4a" | "aac" | "flac" | "ogg" | "aiff" | "aif" | "opus" | "caf"
            | "alac" | "wma" | "m4b" | "mid" | "midi" => Self::Audio,
            "usdz" | "usda" | "usdc" | "obj" | "stl" | "scn" | "dae" | "gltf" | "glb" | "fbx"
            | "ply" | "3ds" | "blend" => Self::Model3D,
            "webloc" | "url" => Self::WebBookmark,
            _ => {
                if let Some(mime) = mime_type.map(|m| m.to_ascii_lowercase()) {
                    if mime.starts_with("image/gif") {
                        return Self::AnimatedImage;
                    }
                    if mime.starts_with("image/svg") {
                        return Self::DesignFile;
                    }
                    if mime.starts_with("image/") {
                        return Self::Image;
                    }
                    if mime.starts_with("video/") {
                        return Self::Video;
                    }
                    if mime.starts_with("audio/") {
                        return Self::Audio;
                    }
                    if mime.starts_with("model/") {
                        return Self::Model3D;
                    }
                    if mime == "application/pdf" || mime.starts_with("text/") {
                        return Self::Document;
                    }
                }
                Self::Document
            }
        }
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub enum SocialPlatform {
    X,
    Threads,
    Bluesky,
    Xiaohongshu,
    Pixiv,
    Instagram,
    Youtube,
    Bilibili,
}

impl SocialPlatform {
    pub fn is_video_platform(self) -> bool {
        matches!(self, Self::Youtube | Self::Bilibili)
    }

    pub fn raw_value(self) -> &'static str {
        match self {
            Self::X => "x",
            Self::Threads => "threads",
            Self::Bluesky => "bluesky",
            Self::Xiaohongshu => "xiaohongshu",
            Self::Pixiv => "pixiv",
            Self::Instagram => "instagram",
            Self::Youtube => "youtube",
            Self::Bilibili => "bilibili",
        }
    }

    pub fn from_raw(raw: &str) -> Option<Self> {
        match raw.trim().to_ascii_lowercase().as_str() {
            "x" | "twitter" => Some(Self::X),
            "threads" => Some(Self::Threads),
            "bluesky" | "bsky" => Some(Self::Bluesky),
            "xiaohongshu" | "xhs" | "rednote" => Some(Self::Xiaohongshu),
            "pixiv" => Some(Self::Pixiv),
            "instagram" | "ig" => Some(Self::Instagram),
            "youtube" | "yt" | "youtu.be" => Some(Self::Youtube),
            "bilibili" | "bili" | "b23" => Some(Self::Bilibili),
            _ => None,
        }
    }

    pub fn display_name(self) -> &'static str {
        match self {
            Self::X => "X",
            Self::Threads => "Threads",
            Self::Bluesky => "Bluesky",
            Self::Xiaohongshu => "小红书",
            Self::Pixiv => "Pixiv",
            Self::Instagram => "Instagram",
            Self::Youtube => "YouTube",
            Self::Bilibili => "B站",
        }
    }

    pub fn post_noun(self) -> &'static str {
        match self {
            Self::X => "推文",
            Self::Xiaohongshu => "笔记",
            Self::Pixiv => "作品",
            Self::Youtube | Self::Bilibili => "视频",
            Self::Threads | Self::Bluesky | Self::Instagram => "贴文",
        }
    }

    pub fn post_type_label(self) -> &'static str {
        match self {
            Self::X => "X 推文",
            Self::Threads => "Threads 贴文",
            Self::Bluesky => "Bluesky 贴文",
            Self::Xiaohongshu => "小红书 笔记",
            Self::Pixiv => "Pixiv 作品",
            Self::Instagram => "Instagram 贴文",
            Self::Youtube => "YouTube 视频",
            Self::Bilibili => "B站 视频",
        }
    }

    pub fn open_action_label(self) -> &'static str {
        match self {
            Self::X => "在 X 打开",
            Self::Threads => "在 Threads 打开",
            Self::Bluesky => "在 Bluesky 打开",
            Self::Xiaohongshu => "在小红书打开",
            Self::Pixiv => "在 Pixiv 打开",
            Self::Instagram => "在 Instagram 打开",
            Self::Youtube => "在 YouTube 打开",
            Self::Bilibili => "在 B 站打开",
        }
    }
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct GitHubRepoMetadata {
    pub owner: String,
    pub repo: String,
    pub full_name: String,
    #[serde(
        rename = "ownerAvatarURL",
        alias = "ownerAvatarUrl",
        default,
        skip_serializing_if = "Option::is_none"
    )]
    pub owner_avatar_url: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub description: Option<String>,
    #[serde(default)]
    pub stars: i64,
    #[serde(default)]
    pub forks: i64,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub watchers: Option<i64>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub language: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub license_name: Option<String>,
    #[serde(default)]
    pub topics: Vec<String>,
    #[serde(default = "default_branch_main")]
    pub default_branch: String,
    #[serde(
        rename = "homepageURL",
        default,
        skip_serializing_if = "Option::is_none"
    )]
    pub homepage_url: Option<String>,
    #[serde(
        rename = "openGraphImageURL",
        default,
        skip_serializing_if = "Option::is_none"
    )]
    pub open_graph_image_url: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub readme_markdown: Option<String>,
    #[serde(with = "cocoa_date")]
    pub fetched_at: DateTime<Utc>,
}

fn default_branch_main() -> String {
    "main".to_string()
}

impl GitHubRepoMetadata {
    pub fn new(owner: impl Into<String>, repo: impl Into<String>) -> Self {
        let owner = owner.into();
        let repo = repo.into();
        let full_name = format!("{owner}/{repo}");
        let og = format!("https://opengraph.githubassets.com/1/{owner}/{repo}");
        Self {
            owner,
            repo,
            full_name,
            owner_avatar_url: None,
            description: None,
            stars: 0,
            forks: 0,
            watchers: None,
            language: None,
            license_name: None,
            topics: Vec::new(),
            default_branch: "main".to_string(),
            homepage_url: None,
            open_graph_image_url: Some(og),
            readme_markdown: None,
            fetched_at: Utc::now(),
        }
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub enum SocialMediaAttachmentKind {
    Photo,
    Video,
    Gif,
}

impl SocialMediaAttachmentKind {
    pub fn raw_value(self) -> &'static str {
        match self {
            Self::Photo => "photo",
            Self::Video => "video",
            Self::Gif => "gif",
        }
    }

    pub fn localized_label(self) -> &'static str {
        match self {
            Self::Photo => "图片",
            Self::Video => "视频",
            Self::Gif => "动图",
        }
    }
}

#[derive(Debug, Clone, PartialEq, Eq, Hash, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct SocialMediaAttachment {
    pub id: String,
    pub kind: SocialMediaAttachmentKind,
    pub url: String,
    #[serde(
        rename = "thumbnailURL",
        default,
        skip_serializing_if = "Option::is_none"
    )]
    pub thumbnail_url: Option<String>,
}

impl SocialMediaAttachment {
    pub fn new(
        kind: SocialMediaAttachmentKind,
        url: impl Into<String>,
        thumbnail_url: Option<String>,
    ) -> Self {
        let url = url.into();
        Self {
            id: format!("{}:{url}", kind.raw_value()),
            kind,
            url,
            thumbnail_url,
        }
    }
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct SocialPostMetadata {
    pub platform: SocialPlatform,
    pub author_name: String,
    pub author_handle: String,
    #[serde(
        rename = "authorAvatarURL",
        default,
        skip_serializing_if = "Option::is_none"
    )]
    pub author_avatar_url: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub published_at_text: Option<String>,
    pub body_text: String,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub quoted_author: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub quoted_text: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub article_title: Option<String>,
    #[serde(rename = "mediaURLs", default)]
    pub media_urls: Vec<String>,
    #[serde(rename = "mediaThumbnailURLs", default)]
    pub media_thumbnail_urls: Vec<String>,
    #[serde(default)]
    pub attachments: Vec<SocialMediaAttachment>,
    #[serde(default)]
    pub has_video: bool,
    #[serde(rename = "videoURL", default, skip_serializing_if = "Option::is_none")]
    pub video_url: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub reply_count: Option<i64>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub repost_count: Option<i64>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub like_count: Option<i64>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub view_count: Option<i64>,
    #[serde(rename = "originalURL")]
    pub original_url: String,
    #[serde(default)]
    pub media_fetch_failed: bool,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub video_duration_seconds: Option<f64>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub video_summary: Option<String>,
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    pub video_outline: Vec<String>,
    #[serde(rename = "videoID", default, skip_serializing_if = "Option::is_none")]
    pub video_id: Option<String>,
    #[serde(rename = "videoCID", default, skip_serializing_if = "Option::is_none")]
    pub video_cid: Option<i64>,
}

impl SocialPostMetadata {
    pub fn has_video_summary_content(&self) -> bool {
        self.video_summary
            .as_deref()
            .is_some_and(|s| !s.trim().is_empty())
            || !self.video_outline.is_empty()
    }

    pub fn formatted_video_duration(&self) -> Option<String> {
        let secs = self.video_duration_seconds.filter(|&d| d > 0.0)?;
        let total = secs.round() as i64;
        let h = total / 3600;
        let m = (total % 3600) / 60;
        let s = total % 60;
        if h > 0 {
            Some(format!("{h}:{m:02}:{s:02}"))
        } else {
            Some(format!("{m:02}:{s:02}"))
        }
    }

    /// Displayable handle subtitle (omits internal 24-hex Xiaohongshu user IDs and redundant video IDs).
    pub fn display_handle_line(&self) -> Option<String> {
        let trimmed = self.author_handle.trim();
        if trimmed.is_empty() {
            return None;
        }
        if self.platform == SocialPlatform::Xiaohongshu {
            let is_internal_hex =
                trimmed.len() == 24 && trimmed.bytes().all(|b| b.is_ascii_hexdigit());
            if is_internal_hex
                || trimmed.eq_ignore_ascii_case("xiaohongshu")
                || trimmed == self.author_name.trim()
            {
                return None;
            }
            return Some(format!("小红书号 {trimmed}"));
        }
        if self.platform == SocialPlatform::Bilibili {
            if trimmed.eq_ignore_ascii_case("bilibili") || trimmed == self.author_name.trim() {
                return None;
            }
            return Some(trimmed.to_string());
        }
        if self.platform == SocialPlatform::Youtube {
            if trimmed.starts_with("UC") && trimmed.len() >= 20 {
                return None;
            }
            if trimmed == self.author_name.trim() {
                return None;
            }
            return Some(trimmed.to_string());
        }
        Some(format!("@{trimmed}"))
    }

    /// Clean display author name that never leaks an internal 24-hex Xiaohongshu user ID.
    pub fn display_author_name(&self) -> String {
        let name = self.author_name.trim();
        let is_internal_hex = name.len() == 24 && name.bytes().all(|b| b.is_ascii_hexdigit());
        if !name.is_empty() && !is_internal_hex {
            return name.to_string();
        }
        if self.platform == SocialPlatform::Xiaohongshu {
            "小红书用户".to_string()
        } else {
            let handle = self.author_handle.trim();
            if handle.is_empty() {
                self.platform.display_name().to_string()
            } else {
                handle.to_string()
            }
        }
    }

    /// Unified typed attachment list across both newly saved posts and legacy saved social posts.
    pub fn effective_attachments(&self) -> Vec<SocialMediaAttachment> {
        if !self.attachments.is_empty() {
            return self.attachments.clone();
        }
        let mut items = Vec::new();
        let mut seen = HashSet::new();
        if let Some(ref v_url) = self.video_url {
            if !v_url.is_empty() && seen.insert(v_url.clone()) {
                items.push(SocialMediaAttachment::new(
                    SocialMediaAttachmentKind::Video,
                    v_url.clone(),
                    self.media_thumbnail_urls.first().cloned(),
                ));
            }
        }
        for (idx, url_str) in self.media_urls.iter().enumerate() {
            if !seen.insert(url_str.clone()) {
                continue;
            }
            let lower = url_str.to_ascii_lowercase();
            let is_vid = lower.contains(".mp4")
                || lower.contains(".m3u8")
                || lower.contains("/ext_tw_video/")
                || lower.contains("/amplify_video/")
                || lower.contains("video.twimg.com");
            let thumb = self.media_thumbnail_urls.get(idx).cloned();
            items.push(SocialMediaAttachment::new(
                if is_vid {
                    SocialMediaAttachmentKind::Video
                } else {
                    SocialMediaAttachmentKind::Photo
                },
                url_str.clone(),
                thumb,
            ));
        }
        items
    }
}

#[derive(Debug, Clone, Default, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct PhotoExifMetadata {
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub camera_make: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub camera_model: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub lens_model: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub captured_at: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub exposure_time: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub f_number: Option<f64>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub iso: Option<i32>,
    #[serde(
        rename = "focalLengthMM",
        default,
        skip_serializing_if = "Option::is_none"
    )]
    pub focal_length_mm: Option<f64>,
    #[serde(
        rename = "focalLength35mm",
        default,
        skip_serializing_if = "Option::is_none"
    )]
    pub focal_length_35mm: Option<i32>,
    #[serde(
        rename = "exposureBiasEV",
        default,
        skip_serializing_if = "Option::is_none"
    )]
    pub exposure_bias_ev: Option<f64>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub metering_mode: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub flash_fired: Option<bool>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub white_balance: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub color_profile: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub bit_depth: Option<i32>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub dpi_width: Option<i32>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub software: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub artist: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub copyright: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub latitude: Option<f64>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub longitude: Option<f64>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub altitude_meters: Option<f64>,
}

impl PhotoExifMetadata {
    pub fn camera_display_name(&self) -> Option<String> {
        let make = self.camera_make.as_deref().unwrap_or("").trim();
        let model = self.camera_model.as_deref().unwrap_or("").trim();
        if make.is_empty() && model.is_empty() {
            return None;
        }
        if model.is_empty() {
            return Some(make.to_string());
        }
        if make.is_empty() {
            return Some(model.to_string());
        }
        if model.to_lowercase().starts_with(&make.to_lowercase()) {
            return Some(model.to_string());
        }
        Some(format!("{make} {model}"))
    }

    pub fn formatted_aperture(&self) -> Option<String> {
        let f = self.f_number.filter(|&v| v > 0.0)?;
        let rounded = (f * 10.0).round() / 10.0;
        if (rounded - rounded.round()).abs() < 0.01 {
            Some(format!("f/{}", rounded.round() as i64))
        } else {
            Some(format!("f/{rounded:.1}"))
        }
    }

    pub fn formatted_focal_length(&self) -> Option<String> {
        let fl = self.focal_length_mm.filter(|&v| v > 0.0)?;
        let base = if (fl - fl.round()).abs() < 0.05 {
            format!("{}mm", fl.round() as i64)
        } else {
            format!("{fl:.1}mm")
        };
        if let Some(eq) = self.focal_length_35mm.filter(|&v| v > 0) {
            if (eq as f64 - fl).abs() >= 1.5 {
                return Some(format!("{base}（等效 {eq}mm）"));
            }
        }
        Some(base)
    }

    pub fn exposure_summary(&self) -> Option<String> {
        let mut parts = Vec::new();
        if let Some(fl) = self.focal_length_mm.filter(|&v| v > 0.0) {
            if (fl - fl.round()).abs() < 0.05 {
                parts.push(format!("{}mm", fl.round() as i64));
            } else {
                parts.push(format!("{fl:.1}mm"));
            }
        }
        if let Some(ap) = self.formatted_aperture() {
            parts.push(ap);
        }
        if let Some(ref exp) = self.exposure_time {
            if !exp.is_empty() {
                parts.push(exp.clone());
            }
        }
        if let Some(iso) = self.iso.filter(|&v| v > 0) {
            parts.push(format!("ISO {iso}"));
        }
        if parts.is_empty() {
            None
        } else {
            Some(parts.join(" · "))
        }
    }

    pub fn has_meaningful_camera_exif(&self) -> bool {
        self.camera_display_name().is_some()
            || self.lens_model.is_some()
            || self.captured_at.is_some()
            || self.exposure_time.is_some()
            || self.f_number.is_some()
            || self.iso.is_some()
            || self.focal_length_mm.is_some()
            || self.latitude.is_some()
            || self.software.is_some()
            || self.artist.is_some()
            || self.copyright.is_some()
    }

    pub fn is_empty(&self) -> bool {
        !self.has_meaningful_camera_exif()
            && self.color_profile.is_none()
            && self.bit_depth.is_none()
            && self.dpi_width.is_none()
    }
}

#[derive(Debug, Clone, Default, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct AIGenerationMetadata {
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub generator: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub prompt: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub negative_prompt: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub model_name: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub model_hash: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub sampler: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub scheduler: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub steps: Option<i32>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub cfg_scale: Option<f64>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub seed: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub size_text: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub clip_skip: Option<i32>,
    #[serde(default)]
    pub loras: Vec<String>,
    #[serde(default)]
    pub extra_parameters: std::collections::BTreeMap<String, String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub raw_parameters: Option<String>,
}

impl AIGenerationMetadata {
    pub fn is_empty(&self) -> bool {
        let has_prompt = self.prompt.as_deref().is_some_and(|s| !s.trim().is_empty());
        let has_neg = self
            .negative_prompt
            .as_deref()
            .is_some_and(|s| !s.trim().is_empty());
        let has_raw = self
            .raw_parameters
            .as_deref()
            .is_some_and(|s| !s.trim().is_empty());
        !has_prompt
            && !has_neg
            && self.model_name.is_none()
            && self.sampler.is_none()
            && self.steps.is_none()
            && self.seed.is_none()
            && !has_raw
    }
}

#[derive(Debug, Clone, Default, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct WebPageRichMetadata {
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub site_name: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub author_name: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub published_at_text: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub summary: Option<String>,
    #[serde(default)]
    pub attachments: Vec<SocialMediaAttachment>,
    #[serde(default)]
    pub has_video: bool,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub duration_seconds: Option<f64>,
    #[serde(
        rename = "canonicalURL",
        default,
        skip_serializing_if = "Option::is_none"
    )]
    pub canonical_url: Option<String>,
}

#[derive(Debug, Clone, Default, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct AssetRichMetadata {
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub github_repo: Option<GitHubRepoMetadata>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub social_post: Option<SocialPostMetadata>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub web_page: Option<WebPageRichMetadata>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub photo_exif: Option<PhotoExifMetadata>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub ai_generation: Option<AIGenerationMetadata>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub text_excerpt: Option<String>,
    #[serde(default)]
    pub is_markdown: bool,
    #[serde(
        rename = "model3DFormat",
        default,
        skip_serializing_if = "Option::is_none"
    )]
    pub model_3d_format: Option<String>,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub enum AspectShape {
    Landscape,
    Portrait,
    Square,
    Ultrawide,
}

impl AspectShape {
    pub fn raw_value(self) -> &'static str {
        match self {
            Self::Landscape => "landscape",
            Self::Portrait => "portrait",
            Self::Square => "square",
            Self::Ultrawide => "ultrawide",
        }
    }

    pub fn localized_label(self) -> &'static str {
        match self {
            Self::Landscape => "横图",
            Self::Portrait => "竖图",
            Self::Square => "方图",
            Self::Ultrawide => "超宽",
        }
    }

    pub fn classify(width: i32, height: i32) -> Self {
        if width <= 0 || height <= 0 {
            return Self::Square;
        }
        let ratio = width as f64 / height as f64;
        if ratio >= 2.0 {
            Self::Ultrawide
        } else if ratio >= 1.15 {
            Self::Landscape
        } else if ratio <= 0.87 {
            Self::Portrait
        } else {
            Self::Square
        }
    }
}

/// Perceptually uniform CIELAB swatch paired with sRGB hex.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct LabColor {
    pub hex: String,
    pub l: f64,
    pub a: f64,
    pub b: f64,
    #[serde(default = "default_proportion")]
    pub proportion: f64,
}

fn default_proportion() -> f64 {
    1.0
}

impl LabColor {
    pub fn new(hex: impl Into<String>, l: f64, a: f64, b: f64, proportion: f64) -> Self {
        Self {
            hex: hex.into(),
            l,
            a,
            b,
            proportion,
        }
    }

    /// CIE76 Euclidean distance in CIELAB space.
    pub fn delta_e(&self, other: &LabColor) -> f64 {
        let dl = self.l - other.l;
        let da = self.a - other.a;
        let db = self.b - other.b;
        (dl * dl + da * da + db * db).sqrt()
    }

    /// CIEDE2000 perceptual color difference (unit weights for lightness, chroma, hue).
    pub fn delta_e_2000(&self, other: &LabColor) -> f64 {
        let to_rad = |deg: f64| deg * std::f64::consts::PI / 180.0;
        let to_deg = |rad: f64| rad * 180.0 / std::f64::consts::PI;
        let hue = |a: f64, b: f64| {
            if a == 0.0 && b == 0.0 {
                0.0
            } else {
                let angle = to_deg(b.atan2(a));
                if angle < 0.0 {
                    angle + 360.0
                } else {
                    angle
                }
            }
        };

        let mean_chroma = (self.a.hypot(self.b) + other.a.hypot(other.b)) * 0.5;
        let chroma_power = mean_chroma.powi(7);
        let g = 0.5 * (1.0 - (chroma_power / (chroma_power + 25.0_f64.powi(7))).sqrt());
        let a1 = (1.0 + g) * self.a;
        let a2 = (1.0 + g) * other.a;
        let c1 = a1.hypot(self.b);
        let c2 = a2.hypot(other.b);
        let h1 = hue(a1, self.b);
        let h2 = hue(a2, other.b);
        let diff = h2 - h1;
        let delta_hue = if c1 * c2 == 0.0 {
            0.0
        } else if diff.abs() <= 180.0 {
            diff
        } else if diff > 180.0 {
            diff - 360.0
        } else {
            diff + 360.0
        };
        let mean_hue = if c1 * c2 == 0.0 {
            h1 + h2
        } else if diff.abs() <= 180.0 {
            (h1 + h2) * 0.5
        } else if h1 + h2 < 360.0 {
            (h1 + h2 + 360.0) * 0.5
        } else {
            (h1 + h2 - 360.0) * 0.5
        };

        let mean_lightness = (self.l + other.l) * 0.5;
        let mean_adj_chroma = (c1 + c2) * 0.5;
        let t = 1.0 - 0.17 * to_rad(mean_hue - 30.0).cos()
            + 0.24 * to_rad(2.0 * mean_hue).cos()
            + 0.32 * to_rad(3.0 * mean_hue + 6.0).cos()
            - 0.20 * to_rad(4.0 * mean_hue - 63.0).cos();
        let lightness_offset = (mean_lightness - 50.0).powi(2);
        let lightness_scale = 1.0 + 0.015 * lightness_offset / (20.0 + lightness_offset).sqrt();
        let chroma_scale = 1.0 + 0.045 * mean_adj_chroma;
        let hue_scale = 1.0 + 0.015 * mean_adj_chroma * t;
        let adj_power = mean_adj_chroma.powi(7);
        let rotation = -2.0
            * (adj_power / (adj_power + 25.0_f64.powi(7))).sqrt()
            * to_rad(60.0 * (-((mean_hue - 275.0) / 25.0).powi(2)).exp()).sin();
        let dl = (other.l - self.l) / lightness_scale;
        let dc = (c2 - c1) / chroma_scale;
        let dh = 2.0 * (c1 * c2).sqrt() * to_rad(delta_hue * 0.5).sin() / hue_scale;
        (dl * dl + dc * dc + dh * dh + rotation * dc * dh)
            .max(0.0)
            .sqrt()
    }

    /// Construct a `LabColor` from an sRGB hex string such as `"#3B82F6"` or `"3B82F6"`.
    pub fn from_hex(hex_string: &str, proportion: f64) -> Self {
        let cleaned = hex_string.trim().replace('#', "");
        if cleaned.len() != 6 {
            return Self::new("#808080", 53.59, 0.0, 0.0, proportion);
        }
        let Ok(value) = u32::from_str_radix(&cleaned, 16) else {
            return Self::new("#808080", 53.59, 0.0, 0.0, proportion);
        };
        let r = ((value >> 16) & 0xFF) as f64 / 255.0;
        let g = ((value >> 8) & 0xFF) as f64 / 255.0;
        let b = (value & 0xFF) as f64 / 255.0;
        let (l, a, b_val) = Self::srgb_to_lab(r, g, b);
        Self::new(
            format!("#{}", cleaned.to_ascii_uppercase()),
            l,
            a,
            b_val,
            proportion,
        )
    }

    pub fn srgb_to_lab(r: f64, g: f64, b: f64) -> (f64, f64, f64) {
        let linearize = |c: f64| {
            if c <= 0.04045 {
                c / 12.92
            } else {
                ((c + 0.055) / 1.055).powf(2.4)
            }
        };
        let rl = linearize(r);
        let gl = linearize(g);
        let bl = linearize(b);

        let x = (rl * 0.4124564 + gl * 0.3575761 + bl * 0.1804375) / 0.95047;
        let y = (rl * 0.2126729 + gl * 0.7151522 + bl * 0.0721750) / 1.00000;
        let z = (rl * 0.0193339 + gl * 0.1191920 + bl * 0.9503041) / 1.08883;

        let f = |t: f64| {
            if t > 0.008856 {
                t.cbrt()
            } else {
                7.787 * t + 16.0 / 116.0
            }
        };
        let fx = f(x);
        let fy = f(y);
        let fz = f(z);

        let l = (116.0 * fy) - 16.0;
        let a = 500.0 * (fx - fy);
        let b_val = 200.0 * (fy - fz);
        (l, a, b_val)
    }
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct AssetRecord {
    #[serde(with = "upper_uuid")]
    pub id: Uuid,
    pub title: String,
    pub file_name: String,
    #[serde(
        rename = "folderID",
        default,
        skip_serializing_if = "Option::is_none",
        with = "upper_uuid_opt"
    )]
    pub folder_id: Option<Uuid>,
    #[serde(
        rename = "driveFileID",
        default,
        skip_serializing_if = "Option::is_none"
    )]
    pub drive_file_id: Option<String>,
    #[serde(default)]
    pub content_hash: String,
    #[serde(default = "default_media_kind")]
    pub media_kind: MediaKind,
    #[serde(default = "default_mime_type")]
    pub mime_type: String,
    #[serde(default)]
    pub file_size_bytes: i64,
    #[serde(default = "default_pixel_width")]
    pub pixel_width: i32,
    #[serde(default = "default_pixel_height")]
    pub pixel_height: i32,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub duration_seconds: Option<f64>,
    #[serde(default)]
    pub waveform_peaks: Vec<f32>,
    #[serde(rename = "sourceURL", default, skip_serializing_if = "Option::is_none")]
    pub source_url: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub source_domain: Option<String>,
    #[serde(default)]
    pub notes: String,
    #[serde(default)]
    pub tags: Vec<String>,
    #[serde(default)]
    pub suggested_tags: Vec<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub ai_description: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub ocr_text: Option<String>,
    #[serde(default)]
    pub dominant_colors: Vec<LabColor>,
    #[serde(default)]
    pub rating: i32,
    #[serde(default)]
    pub pinned_offline: bool,
    #[serde(default)]
    pub is_local_original_cached: bool,
    #[serde(default)]
    pub is_trashed: bool,
    #[serde(with = "cocoa_date")]
    pub created_at: DateTime<Utc>,
    #[serde(with = "cocoa_date")]
    pub updated_at: DateTime<Utc>,
    #[serde(rename = "updatedHLC", default)]
    pub updated_hlc: i64,
    #[serde(
        default,
        skip_serializing_if = "Option::is_none",
        with = "cocoa_date_opt"
    )]
    pub last_opened_at: Option<DateTime<Utc>>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub rich_metadata: Option<AssetRichMetadata>,
}

fn default_media_kind() -> MediaKind {
    MediaKind::Image
}
fn default_mime_type() -> String {
    "image/jpeg".to_string()
}
fn default_pixel_width() -> i32 {
    1200
}
fn default_pixel_height() -> i32 {
    900
}

impl AssetRecord {
    /// Unified extractable link media across social posts, YouTube/Bilibili video bookmarks,
    /// and rich webpages (`rich_metadata.web_page.attachments`).
    pub fn extractable_link_attachments(&self) -> Vec<SocialMediaAttachment> {
        if let Some(ref rich) = self.rich_metadata {
            if let Some(ref post) = rich.social_post {
                let effective = post.effective_attachments();
                if !effective.is_empty() {
                    return effective;
                }
                if post.platform.is_video_platform() && !post.original_url.trim().is_empty() {
                    return vec![SocialMediaAttachment::new(
                        SocialMediaAttachmentKind::Video,
                        post.original_url.clone(),
                        post.media_thumbnail_urls.first().cloned(),
                    )];
                }
            }
            if let Some(ref wp) = rich.web_page {
                if !wp.attachments.is_empty() {
                    return wp.attachments.clone();
                }
                if wp.has_video {
                    if let Some(url) = wp.canonical_url.as_ref().or(self.source_url.as_ref()) {
                        if !url.trim().is_empty() {
                            return vec![SocialMediaAttachment::new(
                                SocialMediaAttachmentKind::Video,
                                url.clone(),
                                None,
                            )];
                        }
                    }
                }
            }
        }
        Vec::new()
    }

    pub fn new(title: impl Into<String>, file_name: impl Into<String>) -> Self {
        let now = Utc::now();
        Self {
            id: Uuid::new_v4(),
            title: title.into(),
            file_name: file_name.into(),
            folder_id: None,
            drive_file_id: None,
            content_hash: String::new(),
            media_kind: MediaKind::Image,
            mime_type: "image/jpeg".to_string(),
            file_size_bytes: 0,
            pixel_width: 1200,
            pixel_height: 900,
            duration_seconds: None,
            waveform_peaks: Vec::new(),
            source_url: None,
            source_domain: None,
            notes: String::new(),
            tags: Vec::new(),
            suggested_tags: Vec::new(),
            ai_description: None,
            ocr_text: None,
            dominant_colors: Vec::new(),
            rating: 0,
            pinned_offline: false,
            is_local_original_cached: false,
            is_trashed: false,
            created_at: now,
            updated_at: now,
            updated_hlc: 0,
            last_opened_at: None,
            rich_metadata: None,
        }
    }

    pub fn aspect_ratio(&self) -> f64 {
        if self.pixel_width > 0 && self.pixel_height > 0 {
            self.pixel_width as f64 / self.pixel_height as f64
        } else {
            1.0
        }
    }

    pub fn aspect_shape(&self) -> AspectShape {
        AspectShape::classify(self.pixel_width, self.pixel_height)
    }

    pub fn is_in_inbox(&self) -> bool {
        self.folder_id.is_none() && !self.is_trashed
    }

    pub fn recent_activity_date(&self) -> DateTime<Utc> {
        match self.last_opened_at {
            Some(opened) if opened > self.created_at => opened,
            _ => self.created_at,
        }
    }

    pub fn is_github_repo(&self) -> bool {
        self.rich_metadata
            .as_ref()
            .is_some_and(|m| m.github_repo.is_some())
    }

    pub fn is_social_post(&self) -> bool {
        self.rich_metadata
            .as_ref()
            .is_some_and(|m| m.social_post.is_some())
    }

    pub fn display_type_label(&self) -> String {
        if let Some(post) = self
            .rich_metadata
            .as_ref()
            .and_then(|m| m.social_post.as_ref())
        {
            return post.platform.post_type_label().to_string();
        }
        if self.is_github_repo() {
            return "GitHub 仓库".to_string();
        }
        self.media_kind.localized_label().to_string()
    }

    pub fn is_markdown_document(&self) -> bool {
        if self.rich_metadata.as_ref().is_some_and(|m| m.is_markdown) {
            return true;
        }
        let ext = std::path::Path::new(&self.file_name)
            .extension()
            .and_then(|e| e.to_str())
            .unwrap_or("")
            .to_ascii_lowercase();
        self.media_kind == MediaKind::Document && (ext == "md" || ext == "markdown")
    }

    pub fn is_plain_text_document(&self) -> bool {
        let ext = std::path::Path::new(&self.file_name)
            .extension()
            .and_then(|e| e.to_str())
            .unwrap_or("")
            .to_ascii_lowercase();
        self.media_kind == MediaKind::Document
            && matches!(
                ext.as_str(),
                "txt" | "md" | "markdown" | "json" | "yaml" | "yml" | "toml" | "csv" | "rtf"
            )
    }
}

#[derive(Debug, Clone, PartialEq, Eq, Hash, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct FolderRecord {
    #[serde(with = "upper_uuid")]
    pub id: Uuid,
    pub name: String,
    #[serde(
        rename = "parentID",
        default,
        skip_serializing_if = "Option::is_none",
        with = "upper_uuid_opt"
    )]
    pub parent_id: Option<Uuid>,
    #[serde(
        rename = "driveFolderID",
        default,
        skip_serializing_if = "Option::is_none"
    )]
    pub drive_folder_id: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub color_hex: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub custom_symbol: Option<String>,
    #[serde(default)]
    pub sort_order: i32,
    #[serde(default)]
    pub asset_count: i32,
    #[serde(with = "cocoa_date")]
    pub created_at: DateTime<Utc>,
    #[serde(with = "cocoa_date")]
    pub updated_at: DateTime<Utc>,
}

impl FolderRecord {
    pub fn new(name: impl Into<String>, parent_id: Option<Uuid>) -> Self {
        let now = Utc::now();
        Self {
            id: Uuid::new_v4(),
            name: name.into(),
            parent_id,
            drive_folder_id: None,
            color_hex: None,
            custom_symbol: None,
            sort_order: 0,
            asset_count: 0,
            created_at: now,
            updated_at: now,
        }
    }
}

/// Cycle-safe, orphan-tolerant hierarchical tree node for `FolderRecord`.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct FolderHierarchyNode {
    pub folder: FolderRecord,
    pub depth: usize,
    pub children: Vec<FolderHierarchyNode>,
}

impl FolderHierarchyNode {
    pub fn sorted_siblings(items: &[FolderRecord]) -> Vec<FolderRecord> {
        let mut sorted = items.to_vec();
        sorted.sort_by(|lhs, rhs| {
            lhs.sort_order
                .cmp(&rhs.sort_order)
                .then_with(|| lhs.name.to_lowercase().cmp(&rhs.name.to_lowercase()))
                .then_with(|| lhs.id.cmp(&rhs.id))
        });
        sorted
    }

    pub fn build_tree(folders: &[FolderRecord]) -> Vec<FolderHierarchyNode> {
        let mut by_parent: HashMap<Option<Uuid>, Vec<FolderRecord>> = HashMap::new();
        let mut known_ids = HashSet::new();
        for f in folders {
            known_ids.insert(f.id);
            by_parent.entry(f.parent_id).or_default().push(f.clone());
        }

        let mut visited = HashSet::new();
        fn make_nodes(
            records: &[FolderRecord],
            depth: usize,
            by_parent: &HashMap<Option<Uuid>, Vec<FolderRecord>>,
            visited: &mut HashSet<Uuid>,
        ) -> Vec<FolderHierarchyNode> {
            let mut nodes = Vec::new();
            for folder in FolderHierarchyNode::sorted_siblings(records) {
                if !visited.insert(folder.id) {
                    continue;
                }
                let child_records = by_parent
                    .get(&Some(folder.id))
                    .map(Vec::as_slice)
                    .unwrap_or(&[]);
                let children = make_nodes(child_records, depth + 1, by_parent, visited);
                nodes.push(FolderHierarchyNode {
                    folder,
                    depth,
                    children,
                });
            }
            nodes
        }

        let roots: Vec<FolderRecord> = folders
            .iter()
            .filter(|f| f.parent_id.is_none_or(|pid| !known_ids.contains(&pid)))
            .cloned()
            .collect();
        let mut forest = make_nodes(&roots, 0, &by_parent, &mut visited);

        let remaining: Vec<FolderRecord> = folders
            .iter()
            .filter(|f| !visited.contains(&f.id))
            .cloned()
            .collect();
        if !remaining.is_empty() {
            forest.extend(make_nodes(&remaining, 0, &by_parent, &mut visited));
        }
        forest
    }

    pub fn flattened(folders: &[FolderRecord]) -> Vec<FolderHierarchyNode> {
        fn append(nodes: &[FolderHierarchyNode], out: &mut Vec<FolderHierarchyNode>) {
            for node in nodes {
                out.push(node.clone());
                append(&node.children, out);
            }
        }
        let mut result = Vec::new();
        append(&Self::build_tree(folders), &mut result);
        result
    }

    pub fn contains(&self, folder_id: Option<Uuid>) -> bool {
        let Some(target) = folder_id else {
            return false;
        };
        if self.folder.id == target {
            return true;
        }
        self.children.iter().any(|c| c.contains(Some(target)))
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub enum InspectorInfoSection {
    PreviewIdentity,
    QuickActions,
    ColorsAndTags,
    #[serde(rename = "notesAndOCR")]
    NotesAndOcr,
    AiGeneration,
    PhotoExif,
    MediaSpecs,
    GithubRepo,
    SocialMediaExtract,
}

impl InspectorInfoSection {
    pub const DEFAULT_ORDER: [InspectorInfoSection; 9] = [
        Self::PreviewIdentity,
        Self::QuickActions,
        Self::ColorsAndTags,
        Self::NotesAndOcr,
        Self::AiGeneration,
        Self::PhotoExif,
        Self::MediaSpecs,
        Self::GithubRepo,
        Self::SocialMediaExtract,
    ];
}

#[derive(Debug, Clone, PartialEq, Eq, Hash, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct TagCount {
    pub name: String,
    pub count: i64,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, Serialize, Deserialize, Default)]
#[serde(rename_all = "camelCase")]
pub enum SmartFolderMatchMode {
    #[default]
    All,
    Any,
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct SmartFolderRule {
    #[serde(default)]
    pub match_mode: SmartFolderMatchMode,
    #[serde(default)]
    pub tags: Vec<String>,
    #[serde(default)]
    pub description_query: String,
    #[serde(default)]
    pub color_hexes: Vec<String>,
    #[serde(default = "default_smart_folder_tolerance")]
    pub color_tolerance: f64,
    #[serde(default)]
    pub media_kinds: Vec<MediaKind>,
    #[serde(default)]
    pub min_rating: i32,
}

fn default_smart_folder_tolerance() -> f64 {
    24.0
}

impl Default for SmartFolderRule {
    fn default() -> Self {
        Self {
            match_mode: SmartFolderMatchMode::All,
            tags: Vec::new(),
            description_query: String::new(),
            color_hexes: Vec::new(),
            color_tolerance: 24.0,
            media_kinds: Vec::new(),
            min_rating: 0,
        }
    }
}

impl SmartFolderRule {
    pub fn has_any_condition(&self) -> bool {
        !self.tags.is_empty()
            || !self.description_query.trim().is_empty()
            || !self.color_hexes.is_empty()
            || !self.media_kinds.is_empty()
            || self.min_rating > 0
    }

    /// Evaluates whether a non-trashed asset satisfies this smart folder rule.
    pub fn matches(&self, asset: &AssetRecord) -> bool {
        if asset.is_trashed {
            return false;
        }
        let mut checks = Vec::new();

        let clean_tags: Vec<String> = self
            .tags
            .iter()
            .map(|t| t.trim().to_lowercase())
            .filter(|t| !t.is_empty())
            .collect();
        if !clean_tags.is_empty() {
            let asset_tags: HashSet<String> =
                asset.tags.iter().map(|t| t.trim().to_lowercase()).collect();
            let matched = match self.match_mode {
                SmartFolderMatchMode::All => clean_tags.iter().all(|t| asset_tags.contains(t)),
                SmartFolderMatchMode::Any => clean_tags.iter().any(|t| asset_tags.contains(t)),
            };
            checks.push(matched);
        }

        let query = self.description_query.trim().to_lowercase();
        if !query.is_empty() {
            let tokens: Vec<&str> = query.split_whitespace().collect();
            let mut parts = vec![
                asset.title.as_str(),
                asset.notes.as_str(),
                asset.ai_description.as_deref().unwrap_or(""),
                asset.ocr_text.as_deref().unwrap_or(""),
            ];
            if let Some(ref rich) = asset.rich_metadata {
                if let Some(ref repo) = rich.github_repo {
                    parts.push(repo.full_name.as_str());
                    parts.push(repo.description.as_deref().unwrap_or(""));
                }
                if let Some(ref post) = rich.social_post {
                    parts.push(post.author_name.as_str());
                    parts.push(post.body_text.as_str());
                }
            }
            let haystack = parts.join("\n").to_lowercase();
            let matched = tokens.iter().all(|tok| haystack.contains(tok));
            checks.push(matched);
        }

        let clean_colors: Vec<&str> = self
            .color_hexes
            .iter()
            .map(|c| c.trim())
            .filter(|c| !c.is_empty())
            .collect();
        if !clean_colors.is_empty() {
            let target_labs: Vec<LabColor> = clean_colors
                .iter()
                .map(|hex| LabColor::from_hex(hex, 1.0))
                .collect();
            let tolerance = self.color_tolerance.max(4.0);
            let matched = !asset.dominant_colors.is_empty()
                && target_labs.iter().any(|target| {
                    asset
                        .dominant_colors
                        .iter()
                        .any(|c| c.delta_e(target) <= tolerance)
                });
            checks.push(matched);
        }

        if !self.media_kinds.is_empty() {
            checks.push(self.media_kinds.contains(&asset.media_kind));
        }

        if self.min_rating > 0 {
            checks.push(asset.rating >= self.min_rating);
        }

        if checks.is_empty() {
            return false;
        }
        match self.match_mode {
            SmartFolderMatchMode::All => checks.into_iter().all(|c| c),
            SmartFolderMatchMode::Any => checks.into_iter().any(|c| c),
        }
    }
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct SmartFolderRecord {
    #[serde(with = "upper_uuid")]
    pub id: Uuid,
    pub name: String,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub color_hex: Option<String>,
    #[serde(default)]
    pub rule: SmartFolderRule,
    #[serde(default)]
    pub sort_order: i32,
    #[serde(with = "cocoa_date")]
    pub created_at: DateTime<Utc>,
    #[serde(with = "cocoa_date")]
    pub updated_at: DateTime<Utc>,
}

impl SmartFolderRecord {
    pub fn new(name: impl Into<String>, rule: SmartFolderRule) -> Self {
        let now = Utc::now();
        Self {
            id: Uuid::new_v4(),
            name: name.into(),
            color_hex: None,
            rule,
            sort_order: 0,
            created_at: now,
            updated_at: now,
        }
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, Default, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub enum SortOrder {
    #[default]
    Newest,
    Oldest,
    NameAsc,
    RatingDesc,
    FileSizeDesc,
    Relevance,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, Default, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub enum GalleryLayoutMode {
    #[default]
    VerticalMasonry,
    HorizontalJustified,
    GalleryFilmstrip,
}

#[derive(Debug, Clone, PartialEq, Eq, Hash)]
pub enum SidebarDestination {
    AllItems,
    Inbox,
    MoodboardsHome,
    Moodboard(Uuid),
    Untagged,
    Recent,
    Trash,
    Folder(Uuid),
    SmartFolder(Uuid),
    Tag(String),
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct FilterCriteria {
    #[serde(default)]
    pub search_query: String,
    #[serde(default)]
    pub kinds: BTreeSet<MediaKind>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub selected_color_hex: Option<String>,
    #[serde(default = "default_color_tolerance")]
    pub color_tolerance: f64,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub shape: Option<AspectShape>,
    #[serde(default)]
    pub min_rating: i32,
    #[serde(default)]
    pub tags: BTreeSet<String>,
    #[serde(
        rename = "folderID",
        default,
        skip_serializing_if = "Option::is_none",
        with = "upper_uuid_opt"
    )]
    pub folder_id: Option<Uuid>,
    #[serde(default)]
    pub include_subfolders: bool,
    #[serde(default)]
    pub only_inbox: bool,
    #[serde(default)]
    pub only_untagged: bool,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub only_recent_days: Option<i32>,
    #[serde(default)]
    pub only_pinned_offline: bool,
    #[serde(default)]
    pub include_trashed: bool,
    #[serde(default)]
    pub only_trashed: bool,
    #[serde(default)]
    pub sort_by: SortOrder,
}

fn default_color_tolerance() -> f64 {
    28.0
}

impl Default for FilterCriteria {
    fn default() -> Self {
        Self {
            search_query: String::new(),
            kinds: BTreeSet::new(),
            selected_color_hex: None,
            color_tolerance: 28.0,
            shape: None,
            min_rating: 0,
            tags: BTreeSet::new(),
            folder_id: None,
            include_subfolders: false,
            only_inbox: false,
            only_untagged: false,
            only_recent_days: None,
            only_pinned_offline: false,
            include_trashed: false,
            only_trashed: false,
            sort_by: SortOrder::Newest,
        }
    }
}

impl FilterCriteria {
    pub fn has_active_visual_filters(&self) -> bool {
        !self.kinds.is_empty()
            || self.selected_color_hex.is_some()
            || self.shape.is_some()
            || self.min_rating > 0
            || !self.tags.is_empty()
            || self.only_pinned_offline
    }

    pub fn clear_visual_filters(&mut self) {
        self.kinds.clear();
        self.selected_color_hex = None;
        self.shape = None;
        self.min_rating = 0;
        self.tags.clear();
        self.only_pinned_offline = false;
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Default, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub enum FolderAssignment {
    #[default]
    Unchanged,
    Inbox,
    Folder(#[serde(with = "upper_uuid")] Uuid),
}

#[derive(Debug, Clone, Default, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct AssetBatchPatch {
    #[serde(rename = "assetIDs", with = "crate::wire::swift_codec::upper_uuid_vec")]
    pub asset_ids: Vec<Uuid>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub title: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub notes: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub ai_description: Option<String>,
    #[serde(rename = "sourceURL", default, skip_serializing_if = "Option::is_none")]
    pub source_url: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub rating: Option<i32>,
    #[serde(default)]
    pub add_tags: Vec<String>,
    #[serde(default)]
    pub remove_tags: Vec<String>,
    #[serde(default)]
    pub accept_suggested_tags: bool,
    #[serde(default)]
    pub dismiss_suggested_tags: Vec<String>,
    #[serde(default)]
    pub folder_assignment: FolderAssignment,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub pinned_offline: Option<bool>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub is_trashed: Option<bool>,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub enum QuickJumpKind {
    Folder,
    Moodboard,
    Tag,
    Asset,
}

impl QuickJumpKind {
    pub fn raw_value(self) -> &'static str {
        match self {
            Self::Folder => "folder",
            Self::Moodboard => "moodboard",
            Self::Tag => "tag",
            Self::Asset => "asset",
        }
    }
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct QuickJumpMatch {
    pub id: String,
    pub kind: QuickJumpKind,
    pub title: String,
    pub subtitle: String,
    #[serde(
        rename = "targetUUID",
        default,
        skip_serializing_if = "Option::is_none",
        with = "upper_uuid_opt"
    )]
    pub target_uuid: Option<Uuid>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub tag_name: Option<String>,
    pub score: f64,
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct ScoredAsset {
    pub asset: AssetRecord,
    pub score: f64,
    #[serde(default)]
    pub match_reasons: Vec<String>,
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct FolderSuggestion {
    #[serde(rename = "folderID", with = "upper_uuid")]
    pub folder_id: Uuid,
    pub folder_name: String,
    pub confidence: f64,
    pub reason: String,
}
