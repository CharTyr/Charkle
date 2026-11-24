//! 8-kind `MediaPipeline`, configurable LRU cache with `pinnedOffline` protection,
//! and first-launch `SampleLibrarySeeder`.
//!
//! Mirrors `MediaPipeline.swift`, `MediaPipeline+Cache.swift`, and `SampleLibrarySeeder.swift`.

use std::collections::{HashMap, HashSet};
use std::fs::{self, File};
use std::io::Read;
use std::path::{Path, PathBuf};
use std::sync::Arc;

use chrono::{DateTime, Utc};
use image::{DynamicImage, Rgba, RgbaImage};
use md5::Md5;
use sha2::{Digest, Sha256};
use url::Url;
use uuid::Uuid;

use crate::db::LibraryDatabase;
use crate::error::{CoreError, CoreResult};
use crate::media::artwork::{
    draw_rect_outline, fill_circle, fill_rect, parse_hex_rgb, MediaArtwork,
};
use crate::media::audio::analyze_audio;
use crate::media::color::ColorExtractor;
use crate::media::metadata::ImageMetadataExtractor;
use crate::media::resolvers::{
    GitHubRepoResolver, GitHubRepoURLParser, ResolvedSocialPost, SocialPostResolver,
    SocialPostURLParser, WebBookmarkResolver, WebURLParser,
};
use crate::media::xiaohongshu::XiaohongshuURLParser;
use crate::models::core::{
    AssetRecord, AssetRichMetadata, FolderRecord, LabColor, MediaKind, SocialMediaAttachmentKind,
    SocialPlatform,
};
use crate::models::media::{CacheStats, CaptureInput, ThumbnailTier};
use crate::models::moodboard::{
    BoardLayoutMode, BoardNode, BoardNodeKind, BoardPoint, BoardRect, MoodboardDocument, NoteStyle,
};
use crate::traits::{NoopShellThumbnailProvider, ShellThumbnailProvider, WebPageSnapshotProvider};
use crate::wire::swift_codec::format_swift_uuid;

pub const MIN_CACHE_BUDGET_BYTES: i64 = 2 * 1024 * 1024 * 1024;
pub const MAX_CACHE_BUDGET_BYTES: i64 = 100 * 1024 * 1024 * 1024;
const CACHE_BUDGET_STATE_KEY: &str = "cacheBudgetBytes";

#[derive(Debug, Clone)]
pub struct FileDigests {
    pub sha256: String,
    pub md5: String,
    pub bytes: i64,
}

#[derive(Debug, Clone)]
pub struct MediaImportResult {
    pub asset: AssetRecord,
    pub original_path: PathBuf,
}

#[derive(Debug, Clone)]
pub struct OriginalEntry {
    pub id: Uuid,
    pub path: PathBuf,
    pub bytes: i64,
}

/// Manages local media storage (`Originals/`, `Thumbnails/`, `Previews/`, `Staging/`),
/// thumbnail generation, metadata extraction, rich URL resolution, and LRU eviction.
#[derive(Clone)]
pub struct MediaPipeline {
    pub directory: PathBuf,
    pub originals: PathBuf,
    pub staging: PathBuf,
    thumbnails: PathBuf,
    previews: PathBuf,
    shell_thumb: Arc<dyn ShellThumbnailProvider>,
    web_snapshotter: Option<Arc<dyn WebPageSnapshotProvider>>,
}

impl MediaPipeline {
    pub fn new(directory: impl Into<PathBuf>) -> CoreResult<Self> {
        Self::with_shell_thumbnail_provider(directory, Arc::new(NoopShellThumbnailProvider))
    }

    pub fn with_shell_thumbnail_provider(
        directory: impl Into<PathBuf>,
        shell_thumb: Arc<dyn ShellThumbnailProvider>,
    ) -> CoreResult<Self> {
        let directory = directory.into();
        let originals = directory.join("Originals");
        let thumbnails = directory.join("Thumbnails");
        let previews = directory.join("Previews");
        let staging = directory.join("Staging");
        for dir in [&originals, &thumbnails, &previews, &staging] {
            fs::create_dir_all(dir)?;
        }
        Ok(Self {
            directory,
            originals,
            staging,
            thumbnails,
            previews,
            shell_thumb,
            web_snapshotter: None,
        })
    }

    /// Attaches an optional offscreen browser snapshot provider (Tier 2 web bookmark fallback).
    pub fn with_web_snapshotter(mut self, provider: Arc<dyn WebPageSnapshotProvider>) -> Self {
        self.web_snapshotter = Some(provider);
        self
    }

    pub fn web_snapshotter(&self) -> Option<&dyn WebPageSnapshotProvider> {
        self.web_snapshotter.as_deref()
    }

    pub fn thumbnail_path(&self, id: Uuid, tier: ThumbnailTier) -> PathBuf {
        let dir = match tier {
            ThumbnailTier::Grid520 => &self.thumbnails,
            ThumbnailTier::Preview1400 => &self.previews,
        };
        dir.join(format!("{}.jpg", format_swift_uuid(&id)))
    }

    pub fn thumbnail_url(&self, id: Uuid, tier: ThumbnailTier) -> Option<PathBuf> {
        let path = self.thumbnail_path(id, tier);
        path.is_file().then_some(path)
    }

    pub fn original_path(&self, asset: &AssetRecord) -> PathBuf {
        let ext = Path::new(&asset.file_name)
            .extension()
            .and_then(|e| e.to_str())
            .unwrap_or("")
            .to_ascii_lowercase();
        let safe: String = ext
            .chars()
            .filter(|c| c.is_ascii_alphanumeric())
            .take(16)
            .collect();
        let id_str = format_swift_uuid(&asset.id);
        let file_name = if safe.is_empty() {
            id_str
        } else {
            format!("{id_str}.{safe}")
        };
        self.originals.join(file_name)
    }

    pub fn cached_original(&self, asset: &AssetRecord) -> Option<PathBuf> {
        let direct = self.original_path(asset);
        if direct.is_file() {
            return Some(direct);
        }
        let target_stem = format_swift_uuid(&asset.id);
        let entries = fs::read_dir(&self.originals).ok()?;
        for entry in entries.flatten() {
            let p = entry.path();
            if p.is_file()
                && p.file_stem()
                    .and_then(|s| s.to_str())
                    .is_some_and(|stem| stem.eq_ignore_ascii_case(&target_stem))
            {
                return Some(p);
            }
        }
        None
    }

    pub fn install_original(
        &self,
        source: &Path,
        asset: &AssetRecord,
        move_source: bool,
    ) -> CoreResult<PathBuf> {
        let destination = self.original_path(asset);
        if source == destination {
            return Ok(destination);
        }
        let previous = self.cached_original(asset);
        if move_source {
            replace_file_atomic(source, &destination)?;
        } else {
            let tmp = self.staging.join(format_swift_uuid(&Uuid::new_v4()));
            fs::copy(source, &tmp)?;
            let res = replace_file_atomic(&tmp, &destination);
            if res.is_err() {
                let _ = fs::remove_file(&tmp);
            }
            res?;
        }
        if let Some(prev) = previous {
            if prev != destination {
                let _ = fs::remove_file(prev);
            }
        }
        Ok(destination)
    }

    pub fn remove_files_for_asset(&self, asset: &AssetRecord) {
        if let Some(p) = self.cached_original(asset) {
            let _ = fs::remove_file(p);
        }
        let _ = fs::remove_file(self.thumbnail_path(asset.id, ThumbnailTier::Grid520));
        let _ = fs::remove_file(self.thumbnail_path(asset.id, ThumbnailTier::Preview1400));
    }

    pub fn remove_files_for_ids(&self, ids: &HashSet<Uuid>) -> CoreResult<()> {
        let mut first_err: Option<CoreError> = None;
        for entry in self.original_entries() {
            if ids.contains(&entry.id) {
                if let Err(err) = remove_if_present(&entry.path) {
                    first_err.get_or_insert(err);
                }
            }
        }
        for &id in ids {
            for tier in [ThumbnailTier::Grid520, ThumbnailTier::Preview1400] {
                if let Err(err) = remove_if_present(&self.thumbnail_path(id, tier)) {
                    first_err.get_or_insert(err);
                }
            }
        }
        match first_err {
            Some(err) => Err(err),
            None => Ok(()),
        }
    }

    /// Best-effort deletion of cached originals and thumbnails across all `ids`.
    ///
    /// On Windows, an open preview handle or antivirus scan can transiently lock a single file
    /// (`ERROR_SHARING_VIOLATION`). Rather than aborting mid-batch and stranding all remaining
    /// deletions, every ID is attempted and only IDs with locked files are returned for retry.
    pub fn remove_files_for_ids_best_effort(&self, ids: &HashSet<Uuid>) -> HashSet<Uuid> {
        let mut retry_ids = HashSet::new();
        for entry in self.original_entries() {
            if ids.contains(&entry.id) {
                if let Err(err) = remove_if_present(&entry.path) {
                    tracing::warn!(
                        asset_id = %entry.id,
                        path = %entry.path.display(),
                        error = %err,
                        "Deferred locked original media cleanup on Windows"
                    );
                    retry_ids.insert(entry.id);
                }
            }
        }
        for &id in ids {
            for tier in [ThumbnailTier::Grid520, ThumbnailTier::Preview1400] {
                let path = self.thumbnail_path(id, tier);
                if let Err(err) = remove_if_present(&path) {
                    tracing::warn!(
                        asset_id = %id,
                        path = %path.display(),
                        error = %err,
                        "Deferred locked thumbnail cleanup on Windows"
                    );
                    retry_ids.insert(id);
                }
            }
        }
        retry_ids
    }

    /// Drains `media.cleanup.*` markers, removes files best-effort across the entire batch, and
    /// re-queues only IDs whose files were transiently locked so later sweeps finish cleanup.
    pub fn cleanup_deleted_media(&self, db: &LibraryDatabase) -> CoreResult<()> {
        let cleanup_ids = db.drain_media_cleanup_ids()?;
        if cleanup_ids.is_empty() {
            return Ok(());
        }
        let locked_ids = self.remove_files_for_ids_best_effort(&cleanup_ids);
        if !locked_ids.is_empty() {
            db.requeue_media_cleanup_ids(&locked_ids)?;
        }
        Ok(())
    }

    pub fn digests(path: &Path) -> CoreResult<FileDigests> {
        let mut file = File::open(path)?;
        let mut sha = Sha256::new();
        let mut md5 = Md5::new();
        let mut buf = vec![0u8; 256 * 1024];
        let mut total: i64 = 0;
        loop {
            let n = file.read(&mut buf)?;
            if n == 0 {
                break;
            }
            sha.update(&buf[..n]);
            md5.update(&buf[..n]);
            total += n as i64;
        }
        Ok(FileDigests {
            sha256: hex::encode(sha.finalize()),
            md5: hex::encode(md5.finalize()),
            bytes: total,
        })
    }

    pub fn mime_type(file_name: &str) -> &'static str {
        let ext = Path::new(file_name)
            .extension()
            .and_then(|e| e.to_str())
            .unwrap_or("")
            .to_ascii_lowercase();
        match ext.as_str() {
            "jpg" | "jpeg" => "image/jpeg",
            "png" => "image/png",
            "gif" => "image/gif",
            "webp" => "image/webp",
            "heic" => "image/heic",
            "heif" => "image/heif",
            "tiff" | "tif" => "image/tiff",
            "bmp" => "image/bmp",
            "avif" => "image/avif",
            "svg" => "image/svg+xml",
            "mp4" | "m4v" => "video/mp4",
            "mov" => "video/quicktime",
            "webm" => "video/webm",
            "mkv" => "video/x-matroska",
            "avi" => "video/x-msvideo",
            "mp3" => "audio/mpeg",
            "wav" => "audio/wav",
            "m4a" => "audio/mp4",
            "flac" => "audio/flac",
            "ogg" | "opus" => "audio/ogg",
            "aac" => "audio/aac",
            "pdf" => "application/pdf",
            "md" | "markdown" => "text/markdown",
            "txt" => "text/plain",
            "json" => "application/json",
            "yaml" | "yml" => "application/x-yaml",
            "toml" => "application/toml",
            "csv" => "text/csv",
            "glb" => "model/gltf-binary",
            "gltf" => "model/gltf+json",
            "obj" => "model/obj",
            "stl" => "model/stl",
            "usdz" => "model/vnd.usdz+zip",
            "webloc" | "url" => "text/uri-list",
            _ => "application/octet-stream",
        }
    }

    /// Ingests any of the 5 `CaptureInput` forms across all 8 `MediaKind` categories.
    pub async fn ingest(
        &self,
        input: CaptureInput,
        folder_id: Option<Uuid>,
        id: Option<Uuid>,
    ) -> CoreResult<MediaImportResult> {
        let asset_id = id.unwrap_or_else(Uuid::new_v4);
        let temp_dir = self.staging.join(format_swift_uuid(&asset_id));
        fs::create_dir_all(&temp_dir)?;
        let result = self
            .ingest_in_temp(&temp_dir, input, folder_id, asset_id)
            .await;
        let _ = fs::remove_dir_all(&temp_dir);
        result
    }

    async fn ingest_in_temp(
        &self,
        temp_dir: &Path,
        input: CaptureInput,
        folder_id: Option<Uuid>,
        asset_id: Uuid,
    ) -> CoreResult<MediaImportResult> {
        let mut preferred_title: Option<String> = None;
        let mut notes = String::new();
        let mut source_url: Option<Url> = None;
        let mut extra_tags: Vec<String> = Vec::new();
        let mut forced_media_kind: Option<MediaKind> = None;
        let mut pre_rich: Option<AssetRichMetadata> = None;
        let mut pre_poster: Option<DynamicImage> = None;
        let mut pre_ocr: Option<String> = None;

        // Delegate `.url` / `.webloc` shortcut file drops through the full rich URL resolution pipeline
        // so GitHub repos, X/Threads/Bluesky posts, and universal websites get covers, metadata & FTS5 text.
        let input = match input {
            CaptureInput::FilePath(ref path) if path.is_file() => {
                let ext = path
                    .extension()
                    .and_then(|e| e.to_str())
                    .unwrap_or("")
                    .to_ascii_lowercase();
                if matches!(ext.as_str(), "url" | "webloc") {
                    if let Some(extracted_url) = WebBookmarkResolver::url_in_file(path) {
                        CaptureInput::WebUrl {
                            url: extracted_url.to_string(),
                            title: None,
                            notes: None,
                        }
                    } else {
                        input
                    }
                } else {
                    input
                }
            }
            other => other,
        };

        let staged_file: PathBuf = match input {
            CaptureInput::FilePath(path) => {
                if !path.is_file() {
                    return Err(CoreError::Media(format!(
                        "Select a regular file to import: {}",
                        path.display()
                    )));
                }
                let base = path
                    .file_name()
                    .and_then(|n| n.to_str())
                    .unwrap_or("Reference");
                let dst = temp_dir.join(Self::clean_name(base));
                fs::copy(&path, &dst)?;
                dst
            }
            CaptureInput::ImageData {
                data,
                suggested_name,
                source_url: src,
            } => {
                let clean = Self::clean_name(&suggested_name);
                let detected_ext = image::guess_format(&data)
                    .ok()
                    .and_then(|fmt| fmt.extensions_str().first().copied());
                let file_name = if Path::new(&clean).extension().is_none() {
                    format!("{clean}.{}", detected_ext.unwrap_or("png"))
                } else {
                    clean
                };
                let dst = temp_dir.join(file_name);
                fs::write(&dst, &data)?;
                source_url = src.and_then(|s| Url::parse(&s).ok());
                dst
            }
            CaptureInput::WebUrl {
                url: raw_url,
                title,
                notes: supplied_notes,
            } => {
                let parsed = XiaohongshuURLParser::extract_note_url(&raw_url)
                    .or_else(|| WebURLParser::parse(&raw_url))
                    .or_else(|| Url::parse(raw_url.trim()).ok())
                    .ok_or_else(|| CoreError::Media(format!("Invalid bookmark URL `{raw_url}`")))?;
                if !WebBookmarkResolver::is_web_url(&parsed) {
                    return Err(CoreError::Media(
                        "Unsupported bookmark URL scheme.".to_string(),
                    ));
                }
                // CRITICAL (Pitfall 7): ALWAYS preserve the user's original collected URL as
                // `source_url` — never overwrite with 302 `/login` redirects.
                source_url = Some(parsed.clone());
                preferred_title = title.filter(|s| !s.trim().is_empty());
                notes = supplied_notes.unwrap_or_default();
                forced_media_kind = Some(MediaKind::WebBookmark);

                // Social Post (X / Threads / Bluesky / Xiaohongshu) — Cohesive Storage Invariant:
                // ALWAYS 1 asset with mediaKind = webBookmark + richMetadata.socialPost
                if let Some(social_ref) = SocialPostURLParser::parse(&parsed) {
                    let is_xhs_short_link = matches!(
                        &social_ref,
                        crate::media::resolvers::SocialPostReference::Xiaohongshu(r)
                            if r.is_short_link
                    );
                    let resolved = SocialPostResolver::resolve(&social_ref).await;
                    if let Some(post) = resolved {
                        let platform_tag = post.metadata.platform.display_name().to_string();
                        extra_tags.push(platform_tag);
                        for tag in post.extracted_tags.iter().take(12) {
                            let clean = tag.trim();
                            if !clean.is_empty() {
                                extra_tags.push(clean.to_string());
                            }
                        }
                        if is_xhs_short_link {
                            if let Ok(resolved_url) = Url::parse(&post.metadata.original_url) {
                                if XiaohongshuURLParser::parse(&resolved_url)
                                    .is_some_and(|r| r.note_id.is_some())
                                {
                                    source_url = Some(resolved_url);
                                }
                            }
                        }
                        if preferred_title.is_none() {
                            preferred_title = Some(post.short_title());
                        }
                        if notes.trim().is_empty() && !post.metadata.body_text.trim().is_empty() {
                            notes = post.metadata.body_text.clone();
                        }
                        let mut cover_img = None;
                        let mut downloaded_video: Option<(Vec<u8>, String)> = None;
                        if let Some(ref dl_url) = post.primary_media_download_url {
                            let kind = post
                                .primary_media_kind
                                .unwrap_or(SocialMediaAttachmentKind::Photo);
                            if matches!(
                                kind,
                                SocialMediaAttachmentKind::Video | SocialMediaAttachmentKind::Gif
                            ) {
                                downloaded_video =
                                    SocialPostResolver::download_media_bytes(dl_url, kind).await;
                            } else if let Some((bytes, _)) =
                                SocialPostResolver::download_media_bytes(dl_url, kind).await
                            {
                                cover_img = image::load_from_memory(&bytes).ok();
                            }
                        }
                        if cover_img.is_none() {
                            if let Some(ref thumb_url) = post.primary_thumbnail_url {
                                if let Some((bytes, _)) = SocialPostResolver::download_media_bytes(
                                    thumb_url,
                                    SocialMediaAttachmentKind::Photo,
                                )
                                .await
                                {
                                    cover_img = image::load_from_memory(&bytes).ok();
                                }
                            }
                        }

                        let avatar_img = match post.metadata.author_avatar_url.as_deref() {
                            Some(av_url) if !av_url.trim().is_empty() => {
                                SocialPostResolver::fetch_avatar_image(av_url).await
                            }
                            _ => None,
                        };
                        pre_poster = Some(MediaArtwork::social_post_card_with_avatar(
                            &post.metadata,
                            cover_img.as_ref(),
                            avatar_img.as_ref(),
                        ));
                        let mut ocr_parts = Vec::new();
                        if let Some(ref h) = post.metadata.article_title {
                            if !h.trim().is_empty() {
                                ocr_parts.push(h.trim().to_string());
                            }
                        }
                        if !post.metadata.body_text.trim().is_empty() {
                            ocr_parts.push(post.metadata.body_text.trim().to_string());
                        }
                        if !post.extracted_tags.is_empty() {
                            ocr_parts.push(post.extracted_tags.join(" "));
                        }
                        if !ocr_parts.is_empty() {
                            pre_ocr = Some(ocr_parts.join("\n"));
                        }
                        let md_doc = post.markdown_document();
                        pre_rich = Some(AssetRichMetadata {
                            social_post: Some(post.metadata),
                            is_markdown: true,
                            ..AssetRichMetadata::default()
                        });

                        let base =
                            Self::clean_name(preferred_title.as_deref().unwrap_or("SocialPost"));
                        if let Some((video_bytes, ext)) = downloaded_video {
                            let dst = temp_dir.join(format!("{base}.{ext}"));
                            fs::write(&dst, video_bytes)?;
                            dst
                        } else {
                            let dst = temp_dir.join(format!("{base}.md"));
                            fs::write(&dst, md_doc.as_bytes())?;
                            dst
                        }
                    } else {
                        let base = Self::clean_name(
                            preferred_title
                                .as_deref()
                                .or_else(|| parsed.host_str())
                                .unwrap_or("Bookmark"),
                        );
                        let dst = temp_dir.join(format!("{base}.url"));
                        fs::write(&dst, format!("[InternetShortcut]\r\nURL={parsed}\r\n"))?;
                        dst
                    }
                } else if let Some(gh_ref) = GitHubRepoURLParser::parse(&parsed) {
                    let repo_meta = GitHubRepoResolver::resolve(&gh_ref).await;
                    extra_tags.push("GitHub".to_string());
                    if let Some(ref lang) = repo_meta.language {
                        if !lang.trim().is_empty() {
                            extra_tags.push(lang.clone());
                        }
                    }
                    if preferred_title.is_none() {
                        preferred_title = Some(repo_meta.full_name.clone());
                    }
                    if notes.trim().is_empty() {
                        if let Some(ref desc) = repo_meta.description {
                            if !desc.trim().is_empty() {
                                notes = desc.clone();
                            }
                        }
                    }
                    let mut gh_ocr_parts = vec![repo_meta.full_name.clone()];
                    if let Some(ref desc) = repo_meta.description {
                        gh_ocr_parts.push(desc.clone());
                    }
                    if !repo_meta.topics.is_empty() {
                        gh_ocr_parts.push(repo_meta.topics.join(" "));
                    }
                    if let Some(ref readme) = repo_meta.readme_markdown {
                        let plain = MediaArtwork::markdown_to_plain_text(readme);
                        if !plain.is_empty() {
                            gh_ocr_parts.push(plain.chars().take(4_000).collect());
                        }
                    }
                    pre_ocr = Some(gh_ocr_parts.join("\n"));
                    let og_img = GitHubRepoResolver::fetch_open_graph_image(&repo_meta).await;
                    pre_poster =
                        Some(og_img.unwrap_or_else(|| MediaArtwork::github_repo_card(&repo_meta)));
                    let base = Self::clean_name(&repo_meta.full_name.replace('/', "-"));
                    let dst = temp_dir.join(format!("{base}.url"));
                    fs::write(&dst, format!("[InternetShortcut]\r\nURL={parsed}\r\n"))?;
                    pre_rich = Some(AssetRichMetadata {
                        github_repo: Some(repo_meta),
                        ..AssetRichMetadata::default()
                    });
                    dst
                } else {
                    let bm =
                        WebBookmarkResolver::fetch_with_snapshot(&parsed, self.web_snapshotter())
                            .await;
                    let clean_domain = WebURLParser::clean_domain(&parsed).unwrap_or_else(|| {
                        parsed
                            .host_str()
                            .unwrap_or("web")
                            .trim_start_matches("www.")
                            .to_string()
                    });
                    if preferred_title.is_none() {
                        preferred_title = bm
                            .title
                            .clone()
                            .filter(|s| !s.trim().is_empty())
                            .or_else(|| Some(WebBookmarkResolver::fallback_title(&parsed)));
                    }
                    if notes.trim().is_empty() {
                        if let Some(ref desc) = bm.description {
                            if !desc.trim().is_empty() {
                                notes = desc.clone();
                            }
                        }
                    }
                    let mut web_ocr_parts = vec![
                        preferred_title
                            .clone()
                            .unwrap_or_else(|| clean_domain.clone()),
                        clean_domain.clone(),
                    ];
                    if let Some(ref site) = bm.site_name {
                        web_ocr_parts.push(site.clone());
                    }
                    if let Some(ref desc) = bm.description {
                        web_ocr_parts.push(desc.clone());
                    }
                    pre_ocr = Some(web_ocr_parts.join("\n"));
                    if let Some(ref desc) = bm.description {
                        pre_rich = Some(AssetRichMetadata {
                            text_excerpt: Some(desc.clone()),
                            ..AssetRichMetadata::default()
                        });
                    }
                    let card_title = preferred_title.as_deref().unwrap_or(&clean_domain);
                    pre_poster = Some(bm.poster_image.unwrap_or_else(|| {
                        MediaArtwork::web_page_card(
                            card_title,
                            &clean_domain,
                            bm.site_name.as_deref(),
                            bm.description.as_deref(),
                            Some(parsed.as_str()),
                            bm.theme_color.as_deref(),
                            bm.favicon_image.as_ref(),
                        )
                    }));
                    let base = Self::clean_name(card_title);
                    let dst = temp_dir.join(format!("{base}.url"));
                    fs::write(&dst, format!("[InternetShortcut]\r\nURL={parsed}\r\n"))?;
                    dst
                }
            }
            CaptureInput::SocialBookmark {
                metadata,
                cover_image_data,
                tags,
            } => {
                let mut meta = *metadata;
                forced_media_kind = Some(MediaKind::WebBookmark);

                // Opportunistically enrich sparse browser-extension payloads without ever degrading
                // supplied data if remote sites throttle or are unreachable.
                let needs_live_enrich = match meta.platform {
                    SocialPlatform::X => {
                        meta.effective_attachments().is_empty()
                            || meta.has_video
                            || meta.body_text.trim().is_empty()
                    }
                    SocialPlatform::Xiaohongshu => {
                        let body_trimmed = meta.body_text.trim();
                        let title_trimmed =
                            meta.article_title.as_deref().map(str::trim).unwrap_or("");
                        meta.effective_attachments().len() <= 1
                            && (body_trimmed.is_empty() || body_trimmed == title_trimmed)
                    }
                    SocialPlatform::Threads | SocialPlatform::Bluesky => false,
                };

                let mut live_extracted_tags = Vec::new();
                let mut resolved_video_url: Option<String> = None;
                if needs_live_enrich {
                    if let Ok(parsed_orig) = Url::parse(&meta.original_url) {
                        if let Some(social_ref) = SocialPostURLParser::parse(&parsed_orig) {
                            if let Some(live) = SocialPostResolver::resolve(&social_ref).await {
                                if matches!(
                                    live.primary_media_kind,
                                    Some(
                                        SocialMediaAttachmentKind::Video
                                            | SocialMediaAttachmentKind::Gif
                                    )
                                ) {
                                    resolved_video_url = live.primary_media_download_url.clone();
                                }
                                live_extracted_tags = live.extracted_tags;
                                meta = SocialPostResolver::merge_metadata(live.metadata, meta);
                            }
                        }
                    }
                }

                extra_tags.push(meta.platform.display_name().to_string());
                for tag in tags.into_iter().chain(live_extracted_tags).take(16) {
                    let clean = tag.trim();
                    if !clean.is_empty() {
                        extra_tags.push(clean.to_string());
                    }
                }

                let mut cover_img = cover_image_data
                    .as_deref()
                    .and_then(|bytes| image::load_from_memory(bytes).ok());

                if cover_img.is_none() {
                    let mut cover_urls = Vec::new();
                    for att in meta.effective_attachments() {
                        if att.kind == SocialMediaAttachmentKind::Photo
                            && !cover_urls.contains(&att.url)
                        {
                            cover_urls.push(att.url);
                        }
                        if let Some(ref thumb) = att.thumbnail_url {
                            if !cover_urls.contains(thumb) {
                                cover_urls.push(thumb.clone());
                            }
                        }
                    }
                    for raw in meta
                        .media_urls
                        .iter()
                        .chain(meta.media_thumbnail_urls.iter())
                    {
                        if !cover_urls.contains(raw) {
                            cover_urls.push(raw.clone());
                        }
                    }
                    for cand in cover_urls.iter().take(4) {
                        if let Some((bytes, _)) = SocialPostResolver::download_media_bytes(
                            cand,
                            SocialMediaAttachmentKind::Photo,
                        )
                        .await
                        {
                            if let Ok(img) = image::load_from_memory(&bytes) {
                                cover_img = Some(img);
                                break;
                            }
                        }
                    }
                }

                let mut downloaded_video: Option<(Vec<u8>, String)> = None;
                let video_candidate = resolved_video_url.or_else(|| meta.video_url.clone());
                if meta.has_video {
                    if let Some(ref v_url) = video_candidate {
                        downloaded_video = SocialPostResolver::download_media_bytes(
                            v_url,
                            SocialMediaAttachmentKind::Video,
                        )
                        .await;
                    }
                }

                let avatar_img = match meta.author_avatar_url.as_deref() {
                    Some(av_url) if !av_url.trim().is_empty() => {
                        SocialPostResolver::fetch_avatar_image(av_url).await
                    }
                    _ => None,
                };

                let resolved = ResolvedSocialPost {
                    metadata: meta.clone(),
                    primary_media_download_url: None,
                    primary_media_kind: None,
                    primary_thumbnail_url: None,
                    extracted_tags: Vec::new(),
                };
                let short_title = resolved.short_title();
                let md_doc = resolved.markdown_document();

                preferred_title = Some(short_title.clone());
                notes = meta.body_text.clone();
                source_url = Url::parse(&meta.original_url).ok();
                pre_poster = Some(MediaArtwork::social_post_card_with_avatar(
                    &meta,
                    cover_img.as_ref(),
                    avatar_img.as_ref(),
                ));

                let mut ocr_parts = Vec::new();
                if let Some(ref h) = meta.article_title {
                    if !h.trim().is_empty() {
                        ocr_parts.push(h.trim().to_string());
                    }
                }
                if !meta.body_text.trim().is_empty() {
                    ocr_parts.push(meta.body_text.trim().to_string());
                }
                if !extra_tags.is_empty() {
                    ocr_parts.push(extra_tags.join(" "));
                }
                if !ocr_parts.is_empty() {
                    pre_ocr = Some(ocr_parts.join("\n"));
                }

                pre_rich = Some(AssetRichMetadata {
                    social_post: Some(meta),
                    is_markdown: true,
                    ..AssetRichMetadata::default()
                });

                let base = Self::clean_name(&short_title);
                if let Some((video_bytes, ext)) = downloaded_video {
                    let dst = temp_dir.join(format!("{base}.{ext}"));
                    fs::write(&dst, video_bytes)?;
                    dst
                } else {
                    let dst = temp_dir.join(format!("{base}.md"));
                    fs::write(&dst, md_doc.as_bytes())?;
                    dst
                }
            }
            CaptureInput::TextSnippet {
                title,
                text,
                source_url: src,
            } => {
                preferred_title = Some(title.clone());
                source_url = src.and_then(|s| Url::parse(&s).ok());
                let dst = temp_dir.join(format!("{}.md", Self::clean_name(&title)));
                fs::write(&dst, text.as_bytes())?;
                dst
            }
            CaptureInput::ColorSwatch { hex, title } => {
                let color = LabColor::from_hex(&hex, 1.0);
                let label = title.unwrap_or_else(|| color.hex.clone());
                preferred_title = Some(label.clone());
                let img = MediaArtwork::swatch(&color);
                let png = MediaArtwork::encode_png(&img)?;
                let dst = temp_dir.join(format!("{}.png", Self::clean_name(&label)));
                fs::write(&dst, png)?;
                dst
            }
        };

        let file_name = staged_file
            .file_name()
            .and_then(|n| n.to_str())
            .unwrap_or("Reference")
            .to_string();
        let ext = Path::new(&file_name)
            .extension()
            .and_then(|e| e.to_str())
            .unwrap_or("")
            .to_ascii_lowercase();
        let mime = Self::mime_type(&file_name).to_string();
        let digests = Self::digests(&staged_file)?;
        let detected_kind =
            forced_media_kind.unwrap_or_else(|| MediaKind::detect(&ext, Some(&mime)));

        let default_title = Path::new(&file_name)
            .file_stem()
            .and_then(|s| s.to_str())
            .unwrap_or(&file_name)
            .to_string();

        let mut asset =
            AssetRecord::new(preferred_title.clone().unwrap_or(default_title), file_name);
        asset.id = asset_id;
        asset.folder_id = folder_id;
        asset.content_hash = digests.sha256;
        asset.media_kind = detected_kind;
        asset.mime_type = mime;
        asset.file_size_bytes = digests.bytes;
        asset.source_url = source_url.as_ref().map(Url::to_string);
        asset.source_domain = source_url.and_then(|u| u.host_str().map(String::from));
        asset.notes = notes;
        asset.is_local_original_cached = true;
        asset.rich_metadata = pre_rich;
        if let Some(ocr) = pre_ocr {
            asset.ocr_text = Some(ocr);
        }
        for tag in extra_tags {
            if !asset.tags.iter().any(|t| t.eq_ignore_ascii_case(&tag)) {
                asset.tags.push(tag);
            }
        }

        self.render_and_write_thumbnails(
            &staged_file,
            &mut asset,
            preferred_title.as_deref(),
            pre_poster,
        )
        .await?;
        let installed = self.install_original(&staged_file, &asset, false)?;
        Ok(MediaImportResult {
            asset,
            original_path: installed,
        })
    }

    async fn render_and_write_thumbnails(
        &self,
        file: &Path,
        asset: &mut AssetRecord,
        preferred_title: Option<&str>,
        pre_poster: Option<DynamicImage>,
    ) -> CoreResult<()> {
        let ext = Path::new(&asset.file_name)
            .extension()
            .and_then(|e| e.to_str())
            .unwrap_or("")
            .to_ascii_lowercase();

        let mut poster: Option<DynamicImage> = pre_poster;
        let mut natural_dims: Option<(i32, i32)> = None;

        if poster.is_none() {
            match asset.media_kind {
                MediaKind::Image | MediaKind::AnimatedImage => {
                    if let Ok(raw_bytes) = fs::read(file) {
                        if ext == "png" && ImageMetadataExtractor::is_animated_png(&raw_bytes) {
                            asset.media_kind = MediaKind::AnimatedImage;
                        }
                        if let Ok(img) = image::load_from_memory(&raw_bytes) {
                            natural_dims = Some((img.width() as i32, img.height() as i32));
                            poster = Some(img);
                        }
                        Self::attach_extracted_metadata(&raw_bytes, asset);
                    }
                    if poster.is_none() {
                        poster = self.try_shell_thumbnail(file, 1400).await;
                    }
                }
                MediaKind::DesignFile => {
                    if ext == "svg" {
                        if let Ok(svg_bytes) = fs::read(file) {
                            if let Some(img) = MediaArtwork::render_svg(&svg_bytes, 1400) {
                                natural_dims = Some((img.width() as i32, img.height() as i32));
                                poster = Some(img);
                            }
                        }
                    } else if let Ok(raw_bytes) = fs::read(file) {
                        if let Ok(img) = image::load_from_memory(&raw_bytes) {
                            natural_dims = Some((img.width() as i32, img.height() as i32));
                            poster = Some(img);
                        }
                        Self::attach_extracted_metadata(&raw_bytes, asset);
                    }
                    if poster.is_none() {
                        poster = self.try_shell_thumbnail(file, 1400).await;
                    }
                }
                MediaKind::Video => {
                    poster = self.try_shell_thumbnail(file, 1400).await;
                }
                MediaKind::WebBookmark => {
                    let url = asset
                        .source_url
                        .as_deref()
                        .and_then(|s| Url::parse(s).ok())
                        .or_else(|| WebBookmarkResolver::url_in_file(file));
                    if let Some(ref u) = url {
                        // Preserve original source URL; only populate when previously absent.
                        if asset.source_url.is_none() {
                            asset.source_url = Some(u.to_string());
                        }
                        asset.source_domain = u.host_str().map(String::from);
                        let clean_domain = WebURLParser::clean_domain(u).unwrap_or_else(|| {
                            u.host_str()
                                .unwrap_or("web")
                                .trim_start_matches("www.")
                                .to_string()
                        });
                        let bm =
                            WebBookmarkResolver::fetch_with_snapshot(u, self.web_snapshotter())
                                .await;
                        if preferred_title.is_none() {
                            if let Some(ref t) = bm.title {
                                if !t.trim().is_empty() {
                                    asset.title = t.clone();
                                }
                            }
                        }
                        if let Some(ref desc) = bm.description {
                            if !desc.trim().is_empty() {
                                if asset.notes.trim().is_empty() {
                                    asset.notes = desc.clone();
                                }
                                let mut rich = asset.rich_metadata.clone().unwrap_or_default();
                                rich.text_excerpt = Some(desc.clone());
                                asset.rich_metadata = Some(rich);
                            }
                        }
                        poster = Some(bm.poster_image.unwrap_or_else(|| {
                            MediaArtwork::web_page_card(
                                &asset.title,
                                &clean_domain,
                                bm.site_name.as_deref(),
                                bm.description.as_deref(),
                                asset.source_url.as_deref(),
                                bm.theme_color.as_deref(),
                                bm.favicon_image.as_ref(),
                            )
                        }));
                    }
                }
                MediaKind::Document => {
                    if matches!(
                        ext.as_str(),
                        "md" | "markdown"
                            | "txt"
                            | "rtf"
                            | "json"
                            | "yaml"
                            | "yml"
                            | "toml"
                            | "csv"
                    ) {
                        if let Ok(mut f) = File::open(file) {
                            let mut buf = Vec::new();
                            let _ = (&mut f).take(65_536).read_to_end(&mut buf);
                            let raw_text = String::from_utf8_lossy(&buf).into_owned();
                            let is_md = ext == "md" || ext == "markdown";
                            let plain = if is_md {
                                MediaArtwork::markdown_to_plain_text(&raw_text)
                            } else {
                                raw_text.clone()
                            };
                            let mut rich = asset.rich_metadata.clone().unwrap_or_default();
                            rich.text_excerpt = Some(raw_text.chars().take(1_200).collect());
                            rich.is_markdown = is_md;
                            asset.rich_metadata = Some(rich);
                            asset.ocr_text = Some(plain.chars().take(8_000).collect());
                            poster = Some(MediaArtwork::card(
                                &asset.title,
                                &ext.to_ascii_uppercase(),
                                &raw_text,
                                &[],
                            ));
                        }
                    } else {
                        poster = self.try_shell_thumbnail(file, 1400).await;
                    }
                }
                MediaKind::Audio => {
                    let analysis = analyze_audio(file);
                    asset.duration_seconds = analysis.duration_seconds;
                    asset.waveform_peaks = analysis.waveform_peaks;
                }
                MediaKind::Model3D => {
                    let mut rich = asset.rich_metadata.clone().unwrap_or_default();
                    rich.model_3d_format = Some(ext.to_ascii_uppercase());
                    asset.rich_metadata = Some(rich);
                    poster = self
                        .try_shell_thumbnail(file, 1400)
                        .await
                        .or_else(|| Some(MediaArtwork::model_3d_card(&asset.title, &ext)));
                }
            }
        }

        let image = poster.unwrap_or_else(|| {
            MediaArtwork::card(
                &asset.title,
                asset
                    .source_domain
                    .as_deref()
                    .unwrap_or_else(|| asset.media_kind.localized_label()),
                &asset.notes,
                &asset.waveform_peaks,
            )
        });

        let (w, h) = natural_dims.unwrap_or((image.width() as i32, image.height() as i32));
        asset.pixel_width = w;
        asset.pixel_height = h;

        let grid_max_side = if asset.media_kind == MediaKind::WebBookmark {
            720
        } else {
            ThumbnailTier::Grid520.max_side()
        };
        let grid = MediaArtwork::resize(&image, grid_max_side);
        let grid_jpeg = MediaArtwork::encode_jpeg(&grid, 86)?;
        write_atomic(
            &self.thumbnail_path(asset.id, ThumbnailTier::Grid520),
            &grid_jpeg,
        )?;

        let preview_path = self.thumbnail_path(asset.id, ThumbnailTier::Preview1400);
        if image.width().max(image.height()) > grid_max_side {
            let preview = MediaArtwork::resize(&image, ThumbnailTier::Preview1400.max_side());
            let preview_jpeg = MediaArtwork::encode_jpeg(&preview, 88)?;
            write_atomic(&preview_path, &preview_jpeg)?;
        } else {
            remove_if_present(&preview_path)?;
        }

        if asset.media_kind != MediaKind::Audio {
            asset.dominant_colors = ColorExtractor::extract_dominant_colors(&grid, 6);
        }
        Ok(())
    }

    async fn try_shell_thumbnail(&self, file: &Path, max_side: u32) -> Option<DynamicImage> {
        let png_bytes = self
            .shell_thumb
            .generate_thumbnail_png(file, max_side)
            .await
            .ok()??;
        image::load_from_memory(&png_bytes).ok()
    }

    fn attach_extracted_metadata(bytes: &[u8], asset: &mut AssetRecord) {
        let extracted = ImageMetadataExtractor::extract_from_bytes(bytes);
        if extracted.photo_exif.is_none() && extracted.ai_generation.is_none() {
            return;
        }
        let mut rich = asset.rich_metadata.clone().unwrap_or_default();
        if let Some(exif) = extracted.photo_exif {
            rich.photo_exif = Some(exif);
        }
        if let Some(ai) = extracted.ai_generation {
            rich.ai_generation = Some(ai);
        }
        asset.rich_metadata = Some(rich);
    }

    /// Re-renders thumbnails, dimensions, metadata, audio waveforms, and dominant colors for
    /// a remotely discovered/updated asset from a local file without mutating user annotations.
    pub async fn refresh_from_file(
        &self,
        mut asset: AssetRecord,
        file: &Path,
    ) -> CoreResult<AssetRecord> {
        let preferred = asset.title.clone();
        self.render_and_write_thumbnails(file, &mut asset, Some(&preferred), None)
            .await?;
        Ok(asset)
    }

    /// Writes raw JPEG thumbnail bytes atomically to the requested tier cache path.
    pub fn write_thumbnail_bytes(
        &self,
        id: Uuid,
        tier: ThumbnailTier,
        bytes: &[u8],
    ) -> CoreResult<()> {
        write_atomic(&self.thumbnail_path(id, tier), bytes)
    }

    /// Writes a custom poster image for an asset and updates dimensions + dominant colors.
    pub fn write_custom_poster(
        &self,
        image: &DynamicImage,
        asset: &mut AssetRecord,
    ) -> CoreResult<()> {
        let grid = MediaArtwork::resize(image, 720);
        let grid_jpeg = MediaArtwork::encode_jpeg(&grid, 86)?;
        asset.pixel_width = image.width() as i32;
        asset.pixel_height = image.height() as i32;
        write_atomic(
            &self.thumbnail_path(asset.id, ThumbnailTier::Grid520),
            &grid_jpeg,
        )?;
        let preview_path = self.thumbnail_path(asset.id, ThumbnailTier::Preview1400);
        if image.width().max(image.height()) > 720 {
            let large = MediaArtwork::resize(image, ThumbnailTier::Preview1400.max_side());
            let preview_jpeg = MediaArtwork::encode_jpeg(&large, 88)?;
            write_atomic(&preview_path, &preview_jpeg)?;
        } else {
            remove_if_present(&preview_path)?;
        }
        asset.dominant_colors = ColorExtractor::extract_dominant_colors(&grid, 6);
        Ok(())
    }

    pub fn clean_name(raw: &str) -> String {
        let replaced: String = raw
            .chars()
            .map(|c| {
                if matches!(c, '/' | ':' | '\\' | '<' | '>' | '"' | '|' | '?' | '*')
                    || c.is_control()
                {
                    '-'
                } else {
                    c
                }
            })
            .collect();
        let trimmed: String = replaced.trim().chars().take(140).collect();
        if trimmed.is_empty() || trimmed == "." || trimmed == ".." {
            "Reference".to_string()
        } else {
            trimmed
        }
    }

    // =========================================================================
    // Cache Stats & LRU Eviction (respecting pinnedOffline on assets & boards)
    // =========================================================================

    pub fn thumbnail_bytes(&self) -> i64 {
        [&self.thumbnails, &self.previews]
            .into_iter()
            .flat_map(|dir| fs::read_dir(dir).ok().into_iter().flatten())
            .flatten()
            .filter_map(|e| e.metadata().ok().map(|m| m.len() as i64))
            .sum()
    }

    pub fn original_entries(&self) -> Vec<OriginalEntry> {
        let Ok(entries) = fs::read_dir(&self.originals) else {
            return Vec::new();
        };
        let mut out = Vec::new();
        for entry in entries.flatten() {
            let path = entry.path();
            if !path.is_file() {
                continue;
            }
            let Some(stem) = path.file_stem().and_then(|s| s.to_str()) else {
                continue;
            };
            let Ok(id) = Uuid::parse_str(stem) else {
                continue;
            };
            let bytes = entry.metadata().map(|m| m.len() as i64).unwrap_or(0);
            out.push(OriginalEntry { id, path, bytes });
        }
        out
    }

    /// Sets user-facing LRU original cache budget clamped to 2–100 GB.
    pub fn set_cache_budget_bytes(db: &LibraryDatabase, bytes: i64) -> CoreResult<i64> {
        let clamped = bytes.clamp(MIN_CACHE_BUDGET_BYTES, MAX_CACHE_BUDGET_BYTES);
        db.set_state(CACHE_BUDGET_STATE_KEY, Some(&clamped))?;
        Ok(clamped)
    }

    /// Computes live cache stats and optionally runs LRU eviction when `original_cache_bytes > budget`.
    /// Never evicts assets protected by `pinned_offline` (asset or pinned Moodboard) or lacking `drive_file_id`.
    pub fn cache_stats_and_evict(
        &self,
        db: &LibraryDatabase,
        evict: bool,
        keeping: &HashSet<Uuid>,
        budget_override: Option<i64>,
    ) -> CoreResult<CacheStats> {
        self.cleanup_deleted_media(db)?;

        let default_budget = CacheStats::default().budget_bytes;
        let budget = match budget_override {
            Some(b) => b.max(0),
            None => db
                .state::<i64>(CACHE_BUDGET_STATE_KEY)?
                .unwrap_or(default_budget),
        };
        let pinned = db.protected_asset_ids()?;
        let files = self.original_entries();
        let mut total_size: i64 = files.iter().map(|e| e.bytes).sum();
        let mut count = files.len();

        if evict && total_size > budget {
            let recoverable: HashSet<Uuid> = db
                .asset_drive_bindings()?
                .into_iter()
                .map(|(_, id)| id)
                .collect();
            let access: HashMap<Uuid, DateTime<Utc>> = db.original_access_times()?;

            let mut candidates: Vec<&OriginalEntry> = files
                .iter()
                .filter(|e| {
                    !pinned.contains(&e.id)
                        && !keeping.contains(&e.id)
                        && recoverable.contains(&e.id)
                })
                .collect();

            candidates.sort_by(|a, b| {
                let ta = access.get(&a.id).copied();
                let tb = access.get(&b.id).copied();
                ta.cmp(&tb)
                    .then_with(|| format_swift_uuid(&a.id).cmp(&format_swift_uuid(&b.id)))
            });

            for entry in candidates {
                if total_size <= budget {
                    break;
                }
                remove_if_present(&entry.path)?;
                total_size -= entry.bytes;
                count = count.saturating_sub(1);
                if let Some(mut asset) = db.asset(entry.id)? {
                    asset.is_local_original_cached = false;
                    db.put_asset(&asset)?;
                }
            }
        }

        let pinned_bytes: i64 = files
            .iter()
            .filter(|e| pinned.contains(&e.id))
            .map(|e| e.bytes)
            .sum();

        Ok(CacheStats {
            thumbnail_bytes: self.thumbnail_bytes(),
            original_cache_bytes: total_size,
            pinned_offline_bytes: pinned_bytes,
            budget_bytes: budget,
            cached_original_count: count,
            pinned_asset_count: pinned.len(),
        })
    }
}

fn replace_file_atomic(src: &Path, dst: &Path) -> CoreResult<()> {
    if let Some(parent) = dst.parent() {
        fs::create_dir_all(parent)?;
    }
    if dst.exists() {
        let _ = fs::remove_file(dst);
    }
    match fs::rename(src, dst) {
        Ok(()) => Ok(()),
        Err(_) => {
            fs::copy(src, dst)?;
            let _ = fs::remove_file(src);
            Ok(())
        }
    }
}

fn write_atomic(dst: &Path, bytes: &[u8]) -> CoreResult<()> {
    if let Some(parent) = dst.parent() {
        fs::create_dir_all(parent)?;
    }
    let tmp = dst.with_extension(format!("tmp-{}", Uuid::new_v4().simple()));
    fs::write(&tmp, bytes)?;
    replace_file_atomic(&tmp, dst)
}

fn remove_if_present(path: &Path) -> CoreResult<()> {
    match fs::remove_file(path) {
        Ok(()) => Ok(()),
        Err(e) if e.kind() == std::io::ErrorKind::NotFound => Ok(()),
        Err(e) => Err(e.into()),
    }
}

// =============================================================================
// First-Launch Curated Sample Library Seeder
// =============================================================================

struct SampleSpec {
    title: &'static str,
    file_name: &'static str,
    folder_name: &'static str,
    tags: &'static [&'static str],
    rating: i32,
    notes: &'static str,
    width: u32,
    height: u32,
    bg_hex: &'static str,
    accent_hex: &'static str,
    secondary_hex: &'static str,
}

const SAMPLE_SPECS: &[SampleSpec] = &[
    SampleSpec {
        title: "Dark Admin Dashboard",
        file_name: "Dark Admin Dashboard.png",
        folder_name: "UI Inspiration",
        tags: &["dashboard", "dark-ui", "analytics", "暗黑仪表盘"],
        rating: 5,
        notes:
            "Clean dark obsidian surfaces with electric cobalt data series and hairline dividers.",
        width: 1200,
        height: 820,
        bg_hex: "#0E1015",
        accent_hex: "#2A60E0",
        secondary_hex: "#1A1E2A",
    },
    SampleSpec {
        title: "Serif Typography Poster — Zurich 2026",
        file_name: "Serif Typography Poster.png",
        folder_name: "Typography",
        tags: &["serif", "poster", "typography", "瑞士排版", "海报"],
        rating: 5,
        notes: "High-contrast serif display type with asymmetric Swiss grid margins.",
        width: 840,
        height: 1180,
        bg_hex: "#F4EFE6",
        accent_hex: "#D93829",
        secondary_hex: "#191816",
    },
    SampleSpec {
        title: "Warm Financial Editorial Spread",
        file_name: "Warm Editorial Spread.png",
        folder_name: "Editorial",
        tags: &["editorial", "warm", "magazine", "暖色调", "排版"],
        rating: 4,
        notes: "Paper cream background with warm amber highlights and structured metrics.",
        width: 1160,
        height: 860,
        bg_hex: "#F7F1E5",
        accent_hex: "#C46A34",
        secondary_hex: "#E7C28D",
    },
    SampleSpec {
        title: "Automation Hero Blue",
        file_name: "Automation Hero Blue.png",
        folder_name: "UI Inspiration",
        tags: &["hero", "saas", "blue", "landing-page", "蓝色"],
        rating: 5,
        notes: "Deep cobalt radial lighting with crisp white typography and pill CTA.",
        width: 1280,
        height: 760,
        bg_hex: "#0A1638",
        accent_hex: "#2A60E0",
        secondary_hex: "#4EA1FF",
    },
    SampleSpec {
        title: "Bauhaus Form & Rhythm Study",
        file_name: "Bauhaus Form Study.png",
        folder_name: "Typography",
        tags: &["bauhaus", "geometric", "poster", "包豪斯", "几何"],
        rating: 4,
        notes: "Primary vermilion, ochre, and cobalt shapes balanced on matte charcoal.",
        width: 960,
        height: 960,
        bg_hex: "#1D1E22",
        accent_hex: "#DC3E2B",
        secondary_hex: "#E6A91A",
    },
    SampleSpec {
        title: "Emerald Mobile Fintech Wallet",
        file_name: "Emerald Fintech Mobile.png",
        folder_name: "UI Inspiration",
        tags: &["mobile", "fintech", "emerald", "ios", "金融App"],
        rating: 4,
        notes: "Portrait card hierarchy with translucent emerald card and tabular numbers.",
        width: 760,
        height: 1160,
        bg_hex: "#111615",
        accent_hex: "#10B981",
        secondary_hex: "#1F2A27",
    },
    SampleSpec {
        title: "Monospace Workflow Monitor",
        file_name: "Monospace Workflow Monitor.png",
        folder_name: "UI Inspiration",
        tags: &["developer", "terminal", "dark-ui", "monospace", "工具"],
        rating: 5,
        notes: "High-density technical telemetry panel with crisp status pills.",
        width: 1200,
        height: 800,
        bg_hex: "#141517",
        accent_hex: "#5B8DEF",
        secondary_hex: "#24272C",
    },
    SampleSpec {
        title: "Terracotta Studio — Ceramic Glaze Studies",
        file_name: "Terracotta Studio Identity.png",
        folder_name: "",
        tags: &["ceramic", "terracotta", "minimal", "品牌", "陶土色"],
        rating: 4,
        notes: "Earthy terracotta primary swatch paired with chalk off-white stationery.",
        width: 900,
        height: 1100,
        bg_hex: "#F2ECE3",
        accent_hex: "#BA6B55",
        secondary_hex: "#D4A373",
    },
    SampleSpec {
        title: "Limestone Courtyard — Study in Shadow",
        file_name: "Limestone Courtyard.png",
        folder_name: "Architecture",
        tags: &["architecture", "limestone", "建筑", "午后"],
        rating: 5,
        notes: "A low sun cuts across three stone thresholds.",
        width: 1200,
        height: 900,
        bg_hex: "#E8E2D6",
        accent_hex: "#8C7D6B",
        secondary_hex: "#C8B8A6",
    },
    SampleSpec {
        title: "Herbarium — Silver Eucalyptus",
        file_name: "Silver Eucalyptus.png",
        folder_name: "",
        tags: &["botanical", "sage", "植物", "叶片"],
        rating: 4,
        notes: "An archival plate studying stems and paired leaves.",
        width: 900,
        height: 1160,
        bg_hex: "#F4F3EE",
        accent_hex: "#6B8E76",
        secondary_hex: "#A8BEB0",
    },
];

pub struct SampleLibrarySeeder;

impl SampleLibrarySeeder {
    /// Seeds the 10 curated starter assets, folders, and starter Freeform Moodboard if DB is empty.
    pub async fn seed_if_empty(db: &LibraryDatabase, media: &MediaPipeline) -> CoreResult<bool> {
        if !db.is_empty()? {
            return Ok(false);
        }

        let mut folder_ids: HashMap<&str, Uuid> = HashMap::new();
        for (idx, name) in ["UI Inspiration", "Typography", "Editorial", "Architecture"]
            .into_iter()
            .enumerate()
        {
            let mut folder = FolderRecord::new(name, None);
            folder.sort_order = idx as i32;
            db.record(
                crate::models::sync::SyncOperationChange::Folder(folder.clone()),
                true,
            )?;
            folder_ids.insert(name, folder.id);
        }

        let mut seeded_assets = Vec::with_capacity(SAMPLE_SPECS.len());
        for spec in SAMPLE_SPECS {
            let png = Self::render_sample_png(spec)?;
            let folder_id = if spec.folder_name.is_empty() {
                None
            } else {
                folder_ids.get(spec.folder_name).copied()
            };
            let mut imported = media
                .ingest(
                    CaptureInput::ImageData {
                        data: png,
                        suggested_name: spec.file_name.to_string(),
                        source_url: None,
                    },
                    folder_id,
                    None,
                )
                .await?;
            imported.asset.title = spec.title.to_string();
            imported.asset.tags = spec.tags.iter().map(|t| (*t).to_string()).collect();
            imported.asset.rating = spec.rating;
            imported.asset.notes = spec.notes.to_string();
            let saved = db.save_asset_locally(&imported.asset, true)?;
            db.touch_original(saved.id, Utc::now())?;
            seeded_assets.push(saved);
        }

        // Starter Freeform Moodboard matching DELTA_SYNC_SPEC.md §1.2
        let mut board = MoodboardDocument::new("光、纸与泥 · Light, Paper & Clay");
        board.subtitle = "自由画布示例情绪板 · 光影与材质参考".to_string();
        board.mode = BoardLayoutMode::Freeform;
        board.viewport_center = BoardPoint::new(540.0, 360.0);
        board.viewport_zoom = 1.0;

        let mut palette = Vec::new();
        let starter_picks: Vec<&AssetRecord> = seeded_assets.iter().rev().take(4).collect();
        for (idx, asset) in starter_picks.iter().enumerate() {
            let col = (idx % 2) as f64;
            let row = (idx / 2) as f64;
            let w = 320.0;
            let h = (w / asset.aspect_ratio().clamp(0.6, 1.8)).round();
            board.nodes.push(BoardNode {
                id: Uuid::new_v4(),
                kind: BoardNodeKind::AssetRef {
                    asset_id: asset.id,
                    crop: None,
                    weight: if idx == 0 { 2 } else { 1 },
                    autoplay_loop: true,
                },
                frame: BoardRect::new(40.0 + col * 356.0, 40.0 + row * 380.0, w, h),
                z_index: idx as i32,
                rotation_degrees: 0.0,
                flip_horizontal: false,
                flip_vertical: false,
                is_locked: false,
                editorial_order: idx as i32,
                updated_at: Utc::now(),
            });
            if let Some(first_color) = asset.dominant_colors.first() {
                palette.push(first_color.clone());
            }
        }
        board.nodes.push(BoardNode {
            id: Uuid::new_v4(),
            kind: BoardNodeKind::Note {
                title: Some("方向说明".to_string()),
                text: "克制中性画布上的材质光影与版式节奏参考。".to_string(),
                style: NoteStyle::Warm,
                font_size: 14.0,
            },
            frame: BoardRect::new(760.0, 40.0, 240.0, 150.0),
            z_index: 10,
            rotation_degrees: 0.0,
            flip_horizontal: false,
            flip_vertical: false,
            is_locked: false,
            editorial_order: 10,
            updated_at: Utc::now(),
        });
        board.extracted_palette = palette;
        let _ = db.save_board_locally(&board)?;
        Ok(true)
    }

    fn render_sample_png(spec: &SampleSpec) -> CoreResult<Vec<u8>> {
        let bg = parse_hex_rgb(spec.bg_hex).unwrap_or([246, 246, 245]);
        let accent = parse_hex_rgb(spec.accent_hex).unwrap_or([42, 96, 224]);
        let sec = parse_hex_rgb(spec.secondary_hex).unwrap_or([220, 220, 218]);

        let (w, h) = (spec.width, spec.height);
        let mut img = RgbaImage::from_pixel(w, h, Rgba([bg[0], bg[1], bg[2], 255]));
        fill_rect(
            &mut img,
            w / 14,
            h / 14,
            w - (w / 7),
            h - (h / 7),
            Rgba([sec[0], sec[1], sec[2], 255]),
        );
        fill_circle(
            &mut img,
            (w * 2) / 3,
            h / 3,
            w.min(h) / 4,
            Rgba([accent[0], accent[1], accent[2], 255]),
        );
        draw_rect_outline(
            &mut img,
            w / 14,
            h / 14,
            w - (w / 7),
            h - (h / 7),
            3,
            Rgba([accent[0], accent[1], accent[2], 180]),
        );
        MediaArtwork::encode_png(&DynamicImage::ImageRgba8(img))
    }
}
