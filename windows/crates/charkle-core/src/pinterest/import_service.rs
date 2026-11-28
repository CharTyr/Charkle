//! Downloads selected Pinterest pins at original resolution and ingests them into
//! `LiveCharkleEngine`, including batch user-board hierarchy import with incremental
//! duplicate skipping and cancellation.
//!
//! Mirrors `Sources/CharkleCore/Services/Pinterest/PinterestImportService.swift`.

use std::collections::HashSet;
use std::future::Future;
use std::sync::atomic::{AtomicBool, Ordering};
use std::time::Duration;

use reqwest::Client;
use url::Url;
use uuid::Uuid;

use crate::engine::LiveCharkleEngine;
use crate::error::{CoreError, CoreResult};
use crate::media::resolvers::SocialPostResolver;
use crate::models::core::{AssetBatchPatch, FilterCriteria, FolderRecord};
use crate::models::media::CaptureInput;

use super::models::{
    PinterestBatchImportReport, PinterestBoard, PinterestBoardImportDestination,
    PinterestBoardImportProgress, PinterestBoardsImportReport, PinterestPin,
};
use super::parser::PinterestJSONParser;

const MAX_PINTEREST_MEDIA_BYTES: usize = 90 * 1024 * 1024;
const PINTEREST_BROWSER_UA: &str = "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/131.0.0.0 Safari/537.36";

#[derive(Debug, Clone)]
pub struct PinterestMediaPayload {
    pub data: Vec<u8>,
    pub mime_type: String,
    pub suggested_extension: String,
}

pub struct PinterestImportService;

impl PinterestImportService {
    /// Collects all Pinterest Pin IDs already present in the non-trashed Charkle library.
    pub fn existing_imported_pin_ids(engine: &LiveCharkleEngine) -> HashSet<String> {
        let criteria = FilterCriteria {
            include_trashed: false,
            ..Default::default()
        };
        let Ok(assets) = engine.fetch_assets(&criteria) else {
            return HashSet::new();
        };
        let mut ids = HashSet::new();
        for asset in assets {
            if let Some(ref url) = asset.source_url {
                if let Some(pin_id) = PinterestJSONParser::extract_pin_id(url) {
                    ids.insert(pin_id);
                }
            }
        }
        ids
    }

    /// Batch-imports selected Pinterest pins into `engine` using the default `reqwest` downloader.
    pub async fn import_pins<FProgress>(
        pins: &[PinterestPin],
        engine: &LiveCharkleEngine,
        target_folder_id: Option<Uuid>,
        extra_tags: &[String],
        skip_duplicates: bool,
        mut on_progress: FProgress,
    ) -> PinterestBatchImportReport
    where
        FProgress: FnMut(usize, usize, &PinterestPin),
    {
        Self::import_pins_with_fetcher(
            pins,
            engine,
            target_folder_id,
            extra_tags,
            skip_duplicates,
            |url| async move { Self::fetch_media_bytes(&url).await },
            &mut on_progress,
        )
        .await
    }

    /// Batch-imports selected Pinterest pins using a pluggable async media fetcher (enabling
    /// 100% offline deterministic unit tests).
    pub async fn import_pins_with_fetcher<FFetch, FutFetch, FProgress>(
        pins: &[PinterestPin],
        engine: &LiveCharkleEngine,
        target_folder_id: Option<Uuid>,
        extra_tags: &[String],
        skip_duplicates: bool,
        media_fetcher: FFetch,
        on_progress: &mut FProgress,
    ) -> PinterestBatchImportReport
    where
        FFetch: Fn(String) -> FutFetch,
        FutFetch: Future<Output = CoreResult<PinterestMediaPayload>>,
        FProgress: FnMut(usize, usize, &PinterestPin),
    {
        let mut report = PinterestBatchImportReport::default();
        if pins.is_empty() {
            return report;
        }

        let mut existing_ids = if skip_duplicates {
            Self::existing_imported_pin_ids(engine)
        } else {
            HashSet::new()
        };

        let normalized_extra_tags: Vec<String> = extra_tags
            .iter()
            .map(|t| t.trim().to_string())
            .filter(|t| !t.is_empty())
            .collect();

        let total = pins.len();
        for (idx, pin) in pins.iter().enumerate() {
            on_progress(idx, total, pin);

            if skip_duplicates && existing_ids.contains(&pin.id) {
                report.skipped_duplicate_pin_ids.push(pin.id.clone());
                continue;
            }

            let Some(media_url) = pin.best_import_media_url() else {
                report.failed_pin_ids.push(pin.id.clone());
                report
                    .errors
                    .push(format!("Pin {} 缺少可用媒体链接", pin.id));
                continue;
            };

            let payload = match media_fetcher(media_url.to_string()).await {
                Ok(p) => p,
                Err(err) => {
                    report.failed_pin_ids.push(pin.id.clone());
                    report
                        .errors
                        .push(format!("Pin {} 导入失败：{err}", pin.id));
                    continue;
                }
            };

            let is_video = payload.mime_type.to_ascii_lowercase().starts_with("video/")
                || payload.suggested_extension.eq_ignore_ascii_case("mp4");
            let file_name = format!(
                "{}.{}",
                Self::sanitized_file_stem(pin),
                payload.suggested_extension
            );

            let mut temp_video_path: Option<std::path::PathBuf> = None;
            let input = if is_video {
                let tmp_path = std::env::temp_dir().join(format!(
                    "charkle-pin-{}-{file_name}",
                    Uuid::new_v4().simple()
                ));
                if let Err(err) = std::fs::write(&tmp_path, &payload.data) {
                    report.failed_pin_ids.push(pin.id.clone());
                    report
                        .errors
                        .push(format!("Pin {} 写入临时视频失败：{err}", pin.id));
                    continue;
                }
                temp_video_path = Some(tmp_path.clone());
                CaptureInput::FilePath(tmp_path)
            } else {
                CaptureInput::ImageData {
                    data: payload.data,
                    suggested_name: file_name,
                    source_url: Some(pin.pin_page_url.clone()),
                }
            };

            let ingest_res = engine.ingest(vec![input], target_folder_id, None).await;
            if let Some(ref tmp) = temp_video_path {
                let _ = std::fs::remove_file(tmp);
            }

            let created = match ingest_res {
                Ok(items) => items,
                Err(err) => {
                    report.failed_pin_ids.push(pin.id.clone());
                    report
                        .errors
                        .push(format!("Pin {} 入库失败：{err}", pin.id));
                    continue;
                }
            };

            let Some(mut first) = created.into_iter().next() else {
                report.failed_pin_ids.push(pin.id.clone());
                continue;
            };

            let mut tags = vec!["Pinterest".to_string()];
            if let Some(ref board_name) = pin.board_name {
                let clean = board_name.trim();
                if !clean.is_empty() {
                    tags.push(clean.to_string());
                }
            }
            tags.extend(normalized_extra_tags.iter().cloned());

            let notes = Self::compose_notes(pin);
            let title = pin.display_title();
            let patch = AssetBatchPatch {
                asset_ids: vec![first.id],
                title: (!title.is_empty()).then_some(title),
                notes: (!notes.is_empty()).then_some(notes),
                source_url: Some(pin.pin_page_url.clone()),
                add_tags: tags,
                ..Default::default()
            };

            if let Ok(updated) = engine.update_assets(&patch) {
                if let Some(u) = updated.into_iter().next() {
                    first = u;
                }
            }

            existing_ids.insert(pin.id.clone());
            report.imported_assets.push(first);
        }

        if let Some(last) = pins.last() {
            on_progress(total, total, last);
        }

        report
    }

    /// Imports one or more Pinterest boards into matching Charkle folders, preserving board
    /// structure and skipping already-imported Pin IDs incrementally.
    #[allow(clippy::too_many_arguments)]
    pub async fn import_boards<FPins, FutPins, FFetch, FutFetch, FProgress>(
        boards: &[PinterestBoard],
        engine: &LiveCharkleEngine,
        destination: PinterestBoardImportDestination,
        extra_tags: &[String],
        skip_duplicates: bool,
        cancel_flag: Option<&AtomicBool>,
        pin_provider: FPins,
        media_fetcher: FFetch,
        mut on_progress: FProgress,
    ) -> PinterestBoardsImportReport
    where
        FPins: Fn(PinterestBoard) -> FutPins,
        FutPins: Future<Output = CoreResult<Vec<PinterestPin>>>,
        FFetch: Fn(String) -> FutFetch,
        FutFetch: Future<Output = CoreResult<PinterestMediaPayload>>,
        FProgress: FnMut(PinterestBoardImportProgress),
    {
        let mut report = PinterestBoardsImportReport::default();
        if boards.is_empty() {
            return report;
        }

        let parent_folder_id: Option<Uuid> = match destination {
            PinterestBoardImportDestination::LibraryRoot => None,
            PinterestBoardImportDestination::ExistingFolder { folder_id } => Some(folder_id),
            PinterestBoardImportDestination::PinterestRootFolder => {
                match Self::resolve_or_create_folder(engine, "Pinterest", None) {
                    Ok(root) => {
                        report.created_or_reused_folder_ids.push(root.id);
                        Some(root.id)
                    }
                    Err(err) => {
                        report
                            .errors
                            .push(format!("无法创建 Pinterest 根目录：{err}"));
                        return report;
                    }
                }
            }
        };

        let is_cancelled = || {
            cancel_flag
                .map(|flag| flag.load(Ordering::SeqCst))
                .unwrap_or(false)
        };

        let total_boards = boards.len();
        for (board_index, board) in boards.iter().enumerate() {
            if is_cancelled() {
                report.was_cancelled = true;
                break;
            }

            let folder_name = Self::sanitized_folder_name(&board.name);
            on_progress(PinterestBoardImportProgress {
                total_boards,
                completed_boards: board_index,
                current_board_name: board.name.clone(),
                current_board_index: board_index,
                current_board_pin_count: board.pin_count.max(0) as usize,
                current_board_processed_pins: 0,
                imported_count: report.imported_asset_count,
                skipped_count: report.skipped_duplicate_count,
                failed_count: report.failed_pin_count,
                phase_message: format!("正在读取画板「{}」…", board.name),
            });

            let target_folder =
                match Self::resolve_or_create_folder(engine, &folder_name, parent_folder_id) {
                    Ok(folder) => {
                        if !report.created_or_reused_folder_ids.contains(&folder.id) {
                            report.created_or_reused_folder_ids.push(folder.id);
                        }
                        folder
                    }
                    Err(err) => {
                        report
                            .errors
                            .push(format!("画板「{}」创建目录失败：{err}", board.name));
                        continue;
                    }
                };

            let pins = match pin_provider(board.clone()).await {
                Ok(p) => p,
                Err(err) => {
                    report
                        .errors
                        .push(format!("画板「{}」拉取素材列表失败：{err}", board.name));
                    continue;
                }
            };

            if is_cancelled() {
                report.was_cancelled = true;
                break;
            }

            let mut existing_ids = if skip_duplicates {
                Self::existing_imported_pin_ids(engine)
            } else {
                HashSet::new()
            };

            let pin_total = pins.len();
            let mut board_tags = Vec::with_capacity(extra_tags.len() + 1);
            board_tags.push(board.name.clone());
            board_tags.extend(extra_tags.iter().cloned());

            for (pin_idx, pin) in pins.iter().enumerate() {
                if is_cancelled() {
                    report.was_cancelled = true;
                    break;
                }

                on_progress(PinterestBoardImportProgress {
                    total_boards,
                    completed_boards: board_index,
                    current_board_name: board.name.clone(),
                    current_board_index: board_index,
                    current_board_pin_count: pin_total,
                    current_board_processed_pins: pin_idx,
                    imported_count: report.imported_asset_count,
                    skipped_count: report.skipped_duplicate_count,
                    failed_count: report.failed_pin_count,
                    phase_message: format!(
                        "正在导入「{}」({}/{pin_total})",
                        board.name,
                        pin_idx + 1
                    ),
                });

                if skip_duplicates && existing_ids.contains(&pin.id) {
                    report.skipped_duplicate_count += 1;
                    continue;
                }

                let mut noop = |_cur: usize, _tot: usize, _p: &PinterestPin| {};
                let single = Self::import_pins_with_fetcher(
                    std::slice::from_ref(pin),
                    engine,
                    Some(target_folder.id),
                    &board_tags,
                    false,
                    &media_fetcher,
                    &mut noop,
                )
                .await;

                report.imported_asset_count += single.imported_assets.len();
                report.skipped_duplicate_count += single.skipped_duplicate_pin_ids.len();
                report.failed_pin_count += single.failed_pin_ids.len();
                report.errors.extend(single.errors);

                if !single.imported_assets.is_empty() {
                    existing_ids.insert(pin.id.clone());
                }
            }

            if report.was_cancelled {
                break;
            }

            on_progress(PinterestBoardImportProgress {
                total_boards,
                completed_boards: board_index + 1,
                current_board_name: board.name.clone(),
                current_board_index: board_index,
                current_board_pin_count: pin_total,
                current_board_processed_pins: pin_total,
                imported_count: report.imported_asset_count,
                skipped_count: report.skipped_duplicate_count,
                failed_count: report.failed_pin_count,
                phase_message: format!("已完成画板「{}」", board.name),
            });
        }

        report
    }

    pub fn resolve_or_create_folder(
        engine: &LiveCharkleEngine,
        name: &str,
        parent_id: Option<Uuid>,
    ) -> CoreResult<FolderRecord> {
        let trimmed = name.trim();
        let target_name = if trimmed.is_empty() {
            "Pinterest"
        } else {
            trimmed
        };
        let existing = engine.fetch_folders()?;
        if let Some(matched) = existing
            .into_iter()
            .find(|f| f.parent_id == parent_id && f.name.trim().eq_ignore_ascii_case(target_name))
        {
            return Ok(matched);
        }
        engine.create_folder(target_name, parent_id)
    }

    pub fn sanitized_folder_name(raw: &str) -> String {
        let replaced = raw.trim().replace('/', "·").replace(':', "-");
        let cleaned: String = replaced
            .chars()
            .filter(|c| !matches!(c, '\\' | '*' | '?' | '"' | '<' | '>' | '|'))
            .collect();
        let trimmed = cleaned.trim();
        if trimmed.is_empty() {
            "未命名画板".to_string()
        } else {
            trimmed.chars().take(64).collect()
        }
    }

    pub fn compose_notes(pin: &PinterestPin) -> String {
        let mut lines: Vec<String> = Vec::new();
        let desc = pin.description.trim();
        if !desc.is_empty() {
            lines.push(desc.to_string());
        }
        let mut meta: Vec<String> = Vec::new();
        if let Some(ref author) = pin.author_name {
            let clean = author.trim();
            if !clean.is_empty() {
                meta.push(format!("作者：{clean}"));
            }
        }
        if let Some(ref board) = pin.board_name {
            let clean = board.trim();
            if !clean.is_empty() {
                meta.push(format!("画板：{clean}"));
            }
        }
        if let Some(ref link) = pin.link_url {
            let clean = link.trim();
            if !clean.is_empty() {
                meta.push(format!("来源：{clean}"));
            }
        }
        if !meta.is_empty() {
            lines.push(meta.join(" · "));
        }
        lines.join("\n\n")
    }

    /// Downloads original Pinterest artwork or video with safe SSRF checks and Pinterest Referer.
    pub async fn fetch_media_bytes(raw_url: &str) -> CoreResult<PinterestMediaPayload> {
        let parsed = Url::parse(raw_url.trim())
            .map_err(|_| CoreError::InvalidPayload(format!("无效的媒体链接：{raw_url}")))?;
        if !SocialPostResolver::is_safe_public_media_url(&parsed) {
            return Err(CoreError::InvalidPayload(format!(
                "拒绝访问非公开媒体地址：{raw_url}"
            )));
        }

        let client = Client::builder()
            .timeout(Duration::from_secs(30))
            .user_agent(PINTEREST_BROWSER_UA)
            .redirect(crate::net_safety::public_redirect_policy(8, false))
            .build()
            .map_err(CoreError::Network)?;

        let mut response = client
            .get(parsed.clone())
            .header("Referer", "https://www.pinterest.com/")
            .header(
                "Accept",
                "image/avif,image/webp,image/png,image/jpeg,video/mp4,*/*;q=0.8",
            )
            .send()
            .await
            .map_err(CoreError::Network)?;

        if !SocialPostResolver::is_safe_public_media_url(response.url()) {
            return Err(CoreError::InvalidPayload(
                "重定向后的媒体地址不安全".to_string(),
            ));
        }
        if !response.status().is_success() {
            return Err(CoreError::Http {
                status_code: response.status().as_u16(),
                message: format!("HTTP {}", response.status().as_u16()),
            });
        }
        if let Some(len) = response.content_length() {
            if len as usize > MAX_PINTEREST_MEDIA_BYTES {
                return Err(CoreError::InvalidPayload(
                    "媒体文件超过 90MB 限制".to_string(),
                ));
            }
        }

        let header_mime = response
            .headers()
            .get(reqwest::header::CONTENT_TYPE)
            .and_then(|v| v.to_str().ok())
            .map(|s| s.split(';').next().unwrap_or(s).trim().to_ascii_lowercase())
            .filter(|s| !s.is_empty());

        let bytes = crate::net_safety::read_bounded_bytes(&mut response, MAX_PINTEREST_MEDIA_BYTES)
            .await
            .map_err(|_| {
                CoreError::InvalidPayload("媒体文件超过 90MB 限制或下载失败".to_string())
            })?;

        if bytes.is_empty() || bytes.len() > MAX_PINTEREST_MEDIA_BYTES {
            return Err(CoreError::InvalidPayload(
                "下载到的媒体内容为空或过大".to_string(),
            ));
        }

        let Some(sniffed_mime) = Self::sniff_magic_mime(&bytes) else {
            let reported = header_mime.as_deref().unwrap_or("unknown");
            return Err(CoreError::InvalidPayload(format!(
                "媒体链接返回了不支持的非图片/视频内容 ({reported})"
            )));
        };
        if let Some(ref hdr) = header_mime {
            if hdr.contains("svg")
                || hdr.contains("html")
                || hdr.contains("javascript")
                || hdr.contains("xml")
                || hdr.contains("json")
            {
                return Err(CoreError::InvalidPayload(format!(
                    "媒体链接返回了非媒体内容 ({hdr})"
                )));
            }
        }

        let mime = sniffed_mime.to_string();
        let ext = Self::extension_for(&mime, &parsed);
        Ok(PinterestMediaPayload {
            data: bytes,
            mime_type: mime,
            suggested_extension: ext,
        })
    }

    fn sanitized_file_stem(pin: &PinterestPin) -> String {
        let base = pin.display_title();
        let cleaned: String = base
            .chars()
            .map(|c| {
                if c.is_alphanumeric() || matches!(c, '-' | '_' | ' ') {
                    c
                } else {
                    ' '
                }
            })
            .collect();
        let compact = cleaned.split_whitespace().collect::<Vec<_>>().join("_");
        let truncated: String = compact.chars().take(48).collect();
        let safe_id: String = pin
            .id
            .chars()
            .filter(|c| c.is_ascii_alphanumeric() || matches!(c, '-' | '_'))
            .take(32)
            .collect();
        let safe_id = if safe_id.is_empty() {
            "pin".to_string()
        } else {
            safe_id
        };
        if truncated.is_empty() {
            format!("pinterest_{safe_id}")
        } else {
            format!("{truncated}_{safe_id}")
        }
    }

    /// Sniffs supported raster image / video magic bytes strictly (never trusts URL extension or SVG/HTML).
    fn sniff_magic_mime(bytes: &[u8]) -> Option<&'static str> {
        if bytes.len() >= 8 && bytes.starts_with(&[0x89, b'P', b'N', b'G', 0x0D, 0x0A, 0x1A, 0x0A])
        {
            return Some("image/png");
        }
        if bytes.len() >= 3 && bytes[0] == 0xFF && bytes[1] == 0xD8 && bytes[2] == 0xFF {
            return Some("image/jpeg");
        }
        if bytes.len() >= 6 && (bytes.starts_with(b"GIF87a") || bytes.starts_with(b"GIF89a")) {
            return Some("image/gif");
        }
        if bytes.len() >= 12 && &bytes[0..4] == b"RIFF" && &bytes[8..12] == b"WEBP" {
            return Some("image/webp");
        }
        if bytes.len() >= 12 && &bytes[4..8] == b"ftyp" {
            if bytes[8..12] == *b"avif" || bytes[8..12] == *b"avis" {
                return Some("image/avif");
            }
            return Some("video/mp4");
        }
        if bytes.len() >= 4 && bytes.starts_with(&[0x1A, 0x45, 0xDF, 0xA3]) {
            return Some("video/webm");
        }
        if bytes.len() >= 2 && &bytes[0..2] == b"BM" {
            return Some("image/bmp");
        }
        None
    }

    fn extension_for(mime: &str, url: &Url) -> String {
        let lower = mime.to_ascii_lowercase();
        if lower.contains("png") {
            return "png".to_string();
        }
        if lower.contains("webp") {
            return "webp".to_string();
        }
        if lower.contains("gif") {
            return "gif".to_string();
        }
        if lower.contains("avif") {
            return "avif".to_string();
        }
        if lower.contains("mp4") || lower.contains("video/") {
            return "mp4".to_string();
        }
        if lower.contains("jpeg") || lower.contains("jpg") {
            return "jpg".to_string();
        }
        if let Some(ext) = url
            .path_segments()
            .and_then(|mut s| s.next_back())
            .and_then(|seg| seg.rsplit_once('.'))
            .map(|(_, ext)| ext.to_ascii_lowercase())
        {
            if matches!(
                ext.as_str(),
                "jpg" | "jpeg" | "png" | "webp" | "gif" | "avif" | "mp4"
            ) {
                return ext;
            }
        }
        "jpg".to_string()
    }
}
