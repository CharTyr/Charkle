//! 100% Classical Non-AI Multi-Media Smart Deduplication Engine covering all 8 `MediaKind`s
//! with strict media-bucket isolation, local fingerprint caching, highest-quality version ranking,
//! and lossless metadata + Moodboard reference merging.
//!
//! Mirrors `Sources/CharkleCore/Media/SmartDeduplicator.swift` 1:1.

use std::collections::{HashMap, HashSet};
use std::path::Path;
use std::sync::OnceLock;

use image::imageops::FilterType;
use image::{DynamicImage, RgbaImage};
use serde::{Deserialize, Serialize};
use sha2::{Digest, Sha256};
use url::Url;
use uuid::Uuid;

use crate::media::resolvers::{GitHubRepoURLParser, SocialPostURLParser};
use crate::models::core::{AssetRecord, MediaKind};
use crate::wire::swift_codec::{upper_uuid, upper_uuid_vec};

#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, Default, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub enum DeduplicationSensitivity {
    Strict,
    #[default]
    Balanced,
    Relaxed,
}

#[derive(Debug, Clone, Copy)]
struct Thresholds {
    max_aspect_ratio_factor: f64,
    max_phash_hamming: u32,
    max_dhash_hamming: u32,
    alt_tight_phash: u32,
    alt_loose_dhash: u32,
    min_luma_zncc: f64,
    max_color_mad: f64,
    flat_image_max_color_mad: f64,
    video_duration_abs_seconds: f64,
    video_duration_rel_ratio: f64,
    audio_duration_abs_seconds: f64,
    audio_duration_rel_ratio: f64,
    min_audio_waveform_zncc: f64,
    max_audio_envelope_mad: f64,
}

impl DeduplicationSensitivity {
    fn thresholds(self) -> Thresholds {
        match self {
            Self::Strict => Thresholds {
                max_aspect_ratio_factor: 1.04,
                max_phash_hamming: 4,
                max_dhash_hamming: 5,
                alt_tight_phash: 2,
                alt_loose_dhash: 8,
                min_luma_zncc: 0.985,
                max_color_mad: 6.5 / 255.0,
                flat_image_max_color_mad: 2.0 / 255.0,
                video_duration_abs_seconds: 0.5,
                video_duration_rel_ratio: 0.02,
                audio_duration_abs_seconds: 0.25,
                audio_duration_rel_ratio: 0.01,
                min_audio_waveform_zncc: 0.985,
                max_audio_envelope_mad: 0.04,
            },
            Self::Balanced => Thresholds {
                max_aspect_ratio_factor: 1.10,
                max_phash_hamming: 8,
                max_dhash_hamming: 10,
                alt_tight_phash: 5,
                alt_loose_dhash: 14,
                min_luma_zncc: 0.955,
                max_color_mad: 12.0 / 255.0,
                flat_image_max_color_mad: 2.5 / 255.0,
                video_duration_abs_seconds: 1.5,
                video_duration_rel_ratio: 0.06,
                audio_duration_abs_seconds: 0.65,
                audio_duration_rel_ratio: 0.025,
                min_audio_waveform_zncc: 0.96,
                max_audio_envelope_mad: 0.075,
            },
            Self::Relaxed => Thresholds {
                max_aspect_ratio_factor: 1.18,
                max_phash_hamming: 12,
                max_dhash_hamming: 14,
                alt_tight_phash: 9,
                alt_loose_dhash: 18,
                min_luma_zncc: 0.915,
                max_color_mad: 18.0 / 255.0,
                flat_image_max_color_mad: 3.5 / 255.0,
                video_duration_abs_seconds: 3.0,
                video_duration_rel_ratio: 0.12,
                audio_duration_abs_seconds: 1.5,
                audio_duration_rel_ratio: 0.05,
                min_audio_waveform_zncc: 0.92,
                max_audio_envelope_mad: 0.12,
            },
        }
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub enum DuplicateMatchKind {
    ExactBinary,
    NearIdentical,
    CanonicalLink,
    NormalizedText,
    AudioWaveform,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, Default, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub enum DuplicateDisposalMode {
    #[default]
    MoveToTrash,
    PermanentlyDelete,
}

#[derive(Debug, Clone, PartialEq, Eq, Default, Serialize, Deserialize)]
#[serde(tag = "type", rename_all = "camelCase")]
pub enum DeduplicationScanScope {
    #[default]
    AllActive,
    Inbox,
    Folder {
        #[serde(rename = "folderID", with = "upper_uuid")]
        folder_id: Uuid,
        #[serde(default = "default_true")]
        include_subfolders: bool,
    },
}

fn default_true() -> bool {
    true
}

#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct DuplicateAssetCandidate {
    pub asset: AssetRecord,
    pub quality_score: f64,
    pub resolution_pixels: i64,
    pub format_label: String,
    pub is_lossless_format: bool,
    pub sharpness_score: f64,
    pub is_recommended_keep: bool,
    pub is_referenced_by_board: bool,
    pub similarity_to_keeper: f64,
    pub quality_reasons: Vec<String>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct DuplicateGroup {
    #[serde(with = "upper_uuid")]
    pub id: Uuid,
    pub primary_media_kind: MediaKind,
    pub match_kind: DuplicateMatchKind,
    pub similarity_score: f64,
    #[serde(rename = "recommendedKeepAssetID", with = "upper_uuid")]
    pub recommended_keep_asset_id: Uuid,
    pub candidates: Vec<DuplicateAssetCandidate>,
    pub reclaimable_bytes: i64,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct DeduplicationScanReport {
    pub scanned_asset_count: usize,
    pub skipped_non_visual_count: usize,
    pub groups: Vec<DuplicateGroup>,
    pub total_duplicate_items: usize,
    pub total_reclaimable_bytes: i64,
    pub duration_seconds: f64,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct DeduplicationResolutionPlan {
    #[serde(rename = "keepAssetID", with = "upper_uuid")]
    pub keep_asset_id: Uuid,
    #[serde(rename = "removeAssetIDs", with = "upper_uuid_vec")]
    pub remove_asset_ids: Vec<Uuid>,
}

#[derive(Debug, Clone, Default, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct DeduplicationCleanupResult {
    pub resolved_group_count: usize,
    pub removed_asset_count: usize,
    pub reclaimed_bytes: i64,
    pub merged_metadata_count: usize,
    pub updated_board_count: usize,
}

/// Classical non-AI perceptual image fingerprint cached locally in `dedup-fingerprints-v1.json`.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct ClassicalImageFingerprint {
    pub p_hash: u64,
    pub d_hash: u64,
    pub luma16: Vec<u8>,
    pub rgb8: Vec<u8>,
    pub luma_std_dev: f32,
    pub sharpness: f32,
    pub aspect_ratio: f64,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct CachedDedupFingerprintEntry {
    pub content_hash: String,
    pub fingerprint: ClassicalImageFingerprint,
}

#[derive(Debug, Clone)]
pub struct IndexedMediaAsset {
    pub asset: AssetRecord,
    pub fingerprint: Option<ClassicalImageFingerprint>,
    pub canonical_bookmark_key: Option<String>,
    pub normalized_text_hash: Option<String>,
}

#[derive(Debug, Clone)]
pub struct QualityEvaluation {
    pub score: f64,
    pub resolution_pixels: i64,
    pub format_label: String,
    pub is_lossless_format: bool,
    pub sharpness_score: f64,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
enum MediaComparisonBucket {
    RasterVisual, // Image + AnimatedImage
    Video,
    Audio,
    DesignFile,
    WebBookmark,
    Document,
    Model3D,
}

impl MediaComparisonBucket {
    fn for_kind(kind: MediaKind) -> Self {
        match kind {
            MediaKind::Image | MediaKind::AnimatedImage => Self::RasterVisual,
            MediaKind::Video => Self::Video,
            MediaKind::Audio => Self::Audio,
            MediaKind::DesignFile => Self::DesignFile,
            MediaKind::WebBookmark => Self::WebBookmark,
            MediaKind::Document => Self::Document,
            MediaKind::Model3D => Self::Model3D,
        }
    }
}

fn dct_cos_table() -> &'static [[f64; 32]; 8] {
    static TABLE: OnceLock<[[f64; 32]; 8]> = OnceLock::new();
    TABLE.get_or_init(|| {
        let mut table = [[0.0_f64; 32]; 8];
        for (u, row) in table.iter_mut().enumerate() {
            let scale = if u == 0 {
                (1.0_f64 / 32.0).sqrt()
            } else {
                (2.0_f64 / 32.0).sqrt()
            };
            for (x, cell) in row.iter_mut().enumerate() {
                *cell = scale
                    * (((2.0 * x as f64 + 1.0) * u as f64 * std::f64::consts::PI) / 64.0).cos();
            }
        }
        table
    })
}

const TRACKING_QUERY_PARAMS: &[&str] = &[
    "utm_source",
    "utm_medium",
    "utm_campaign",
    "utm_term",
    "utm_content",
    "utm_id",
    "fbclid",
    "gclid",
    "dclid",
    "msclkid",
    "igshid",
    "mc_cid",
    "mc_eid",
    "ref",
    "ref_src",
    "ref_url",
    "spm",
    "spm_id_from",
    "from",
    "share_source",
    "share_medium",
    "share_session_id",
    "s",
    "t",
    "xsec_token",
    "xsec_source",
];

pub struct SmartDeduplicator;

impl SmartDeduplicator {
    pub fn needs_visual_fingerprint(kind: MediaKind) -> bool {
        matches!(
            kind,
            MediaKind::Image
                | MediaKind::AnimatedImage
                | MediaKind::Video
                | MediaKind::DesignFile
                | MediaKind::Model3D
        )
    }

    pub fn compute_fingerprint_from_path(
        path: &Path,
        declared_aspect_ratio: Option<f64>,
    ) -> Option<ClassicalImageFingerprint> {
        let img = image::open(path).ok()?;
        Self::compute_fingerprint(&img, declared_aspect_ratio)
    }

    pub fn compute_fingerprint(
        image: &DynamicImage,
        declared_aspect_ratio: Option<f64>,
    ) -> Option<ClassicalImageFingerprint> {
        if image.width() < 4 || image.height() < 4 {
            return None;
        }
        let rgba32 =
            composite_on_white(image.resize_exact(32, 32, FilterType::Triangle).to_rgba8());
        let rgba9x8 = composite_on_white(image.resize_exact(9, 8, FilterType::Triangle).to_rgba8());

        // 1. Rec.709 32x32 luminance matrix
        let mut luma32 = [0.0_f64; 32 * 32];
        for (i, px) in rgba32.pixels().enumerate() {
            let [r, g, b, _] = px.0;
            luma32[i] = 0.2126 * f64::from(r) + 0.7152 * f64::from(g) + 0.0722 * f64::from(b);
        }

        let p_hash = compute_phash(&luma32);

        // 2. 9x8 horizontal gradient dHash
        let mut d_hash = 0u64;
        let mut bit_index = 0u32;
        for y in 0..8u32 {
            for x in 0..8u32 {
                let lpx = rgba9x8.get_pixel(x, y).0;
                let rpx = rgba9x8.get_pixel(x + 1, y).0;
                let ll = 0.2126 * f64::from(lpx[0])
                    + 0.7152 * f64::from(lpx[1])
                    + 0.0722 * f64::from(lpx[2]);
                let rl = 0.2126 * f64::from(rpx[0])
                    + 0.7152 * f64::from(rpx[1])
                    + 0.0722 * f64::from(rpx[2]);
                if ll < rl {
                    d_hash |= 1u64 << bit_index;
                }
                bit_index += 1;
            }
        }

        // 3. 16x16 luma grid & std dev
        let mut luma16 = vec![0u8; 16 * 16];
        let mut sum_l = 0.0_f64;
        let mut sum_l2 = 0.0_f64;
        for y in 0..16usize {
            for x in 0..16usize {
                let y2 = y * 2;
                let x2 = x * 2;
                let avg = (luma32[y2 * 32 + x2]
                    + luma32[y2 * 32 + x2 + 1]
                    + luma32[(y2 + 1) * 32 + x2]
                    + luma32[(y2 + 1) * 32 + x2 + 1])
                    * 0.25;
                let clamped = avg.round().clamp(0.0, 255.0) as u8;
                luma16[y * 16 + x] = clamped;
                let v = f64::from(clamped);
                sum_l += v;
                sum_l2 += v * v;
            }
        }
        let mean_l = sum_l / 256.0;
        let var_l = ((sum_l2 / 256.0) - mean_l * mean_l).max(0.0);
        let luma_std_dev = var_l.sqrt() as f32;

        // 4. 8x8 sRGB color grid (192 bytes)
        let mut rgb8 = vec![0u8; 8 * 8 * 3];
        for by in 0..8u32 {
            for bx in 0..8u32 {
                let (mut sr, mut sg, mut sb) = (0u32, 0u32, 0u32);
                for dy in 0..4u32 {
                    for dx in 0..4u32 {
                        let [r, g, b, _] = rgba32.get_pixel(bx * 4 + dx, by * 4 + dy).0;
                        sr += u32::from(r);
                        sg += u32::from(g);
                        sb += u32::from(b);
                    }
                }
                let out_off = ((by * 8 + bx) * 3) as usize;
                rgb8[out_off] = (sr >> 4) as u8;
                rgb8[out_off + 1] = (sg >> 4) as u8;
                rgb8[out_off + 2] = (sb >> 4) as u8;
            }
        }

        let sharpness = compute_laplacian_sharpness(image);
        let aspect_ratio = match declared_aspect_ratio {
            Some(d) if d.is_finite() && d > 0.02 && d < 50.0 => d,
            _ => f64::from(image.width()) / f64::from(image.height().max(1)),
        };

        Some(ClassicalImageFingerprint {
            p_hash,
            d_hash,
            luma16,
            rgb8,
            luma_std_dev,
            sharpness,
            aspect_ratio,
        })
    }

    pub fn canonical_bookmark_key(asset: &AssetRecord) -> Option<String> {
        if asset.media_kind != MediaKind::WebBookmark {
            return None;
        }
        if let Some(repo) = asset
            .rich_metadata
            .as_ref()
            .and_then(|r| r.github_repo.as_ref())
        {
            return Some(format!(
                "github:{}/{}",
                repo.owner.to_ascii_lowercase(),
                repo.repo.to_ascii_lowercase()
            ));
        }
        let raw = asset
            .rich_metadata
            .as_ref()
            .and_then(|r| r.social_post.as_ref())
            .map(|p| p.original_url.as_str())
            .or(asset.source_url.as_deref())?;
        let trimmed = raw.trim();
        if trimmed.is_empty() {
            return None;
        }
        let mut url = Url::parse(trimmed).ok()?;
        if let Some(social) = SocialPostURLParser::parse(&url) {
            return Some(social.dedup_key());
        }
        if let Some(repo) = GitHubRepoURLParser::parse(&url) {
            return Some(format!(
                "github:{}/{}",
                repo.owner.to_ascii_lowercase(),
                repo.repo.to_ascii_lowercase()
            ));
        }
        let raw_host = url.host_str()?.to_ascii_lowercase();
        let host = raw_host
            .strip_prefix("www.")
            .unwrap_or(&raw_host)
            .to_string();
        let mut path = url.path().to_string();
        while path.len() > 1 && path.ends_with('/') {
            path.pop();
        }
        let mut filtered_query: Vec<(String, String)> = url
            .query_pairs()
            .filter(|(k, _)| {
                let lower = k.to_ascii_lowercase();
                !lower.starts_with("utm_") && !TRACKING_QUERY_PARAMS.contains(&lower.as_str())
            })
            .map(|(k, v)| (k.into_owned(), v.into_owned()))
            .collect();
        filtered_query.sort_by(|a, b| {
            a.0.to_ascii_lowercase()
                .cmp(&b.0.to_ascii_lowercase())
                .then_with(|| a.1.cmp(&b.1))
        });

        let _ = url.set_scheme("https");
        let _ = url.set_host(Some(&host));
        url.set_path(&path);
        url.set_fragment(None);
        if filtered_query.is_empty() {
            url.set_query(None);
        } else {
            url.query_pairs_mut().clear().extend_pairs(filtered_query);
        }
        Some(format!("web:{}", url.as_str().to_ascii_lowercase()))
    }

    pub fn normalized_document_text_hash(
        asset: &AssetRecord,
        cached_file: Option<&Path>,
    ) -> Option<String> {
        if asset.media_kind != MediaKind::Document {
            return None;
        }
        let ext = Path::new(&asset.file_name)
            .extension()
            .and_then(|e| e.to_str())
            .unwrap_or("")
            .to_ascii_lowercase();
        let is_plain_text = matches!(
            ext.as_str(),
            "md" | "markdown" | "txt" | "rtf" | "json" | "yaml" | "yml" | "toml" | "csv"
        );
        let raw_text: Option<String> = if is_plain_text {
            cached_file
                .and_then(|p| std::fs::read(p).ok())
                .filter(|b| b.len() <= 2 * 1024 * 1024)
                .map(|b| String::from_utf8_lossy(&b).into_owned())
        } else {
            None
        }
        .or_else(|| {
            asset
                .ocr_text
                .as_deref()
                .filter(|s| s.trim().chars().count() >= 64)
                .map(String::from)
        })
        .or_else(|| {
            asset
                .rich_metadata
                .as_ref()
                .and_then(|r| r.text_excerpt.as_deref())
                .filter(|s| s.trim().chars().count() >= 64)
                .map(String::from)
        });

        let raw = raw_text?;
        let normalized = raw
            .replace("\r\n", "\n")
            .replace('\r', "\n")
            .split_whitespace()
            .collect::<Vec<_>>()
            .join(" ");
        if normalized.chars().count() < 48 {
            return None;
        }
        Some(hex::encode(Sha256::digest(normalized.as_bytes())))
    }

    pub fn visual_similarity(
        lhs: &ClassicalImageFingerprint,
        rhs: &ClassicalImageFingerprint,
        sensitivity: DeduplicationSensitivity,
    ) -> Option<f64> {
        let th = sensitivity.thresholds();
        let ra = lhs.aspect_ratio.max(0.05);
        let rb = rhs.aspect_ratio.max(0.05);
        let aspect_factor = (ra / rb).max(rb / ra);
        if aspect_factor > th.max_aspect_ratio_factor {
            return None;
        }

        let color_mad = rgb_mean_absolute_difference(&lhs.rgb8, &rhs.rgb8);

        let min_std = lhs.luma_std_dev.min(rhs.luma_std_dev);
        let max_std = lhs.luma_std_dev.max(rhs.luma_std_dev);
        if min_std < 3.5 {
            if max_std >= 6.0 || color_mad > th.flat_image_max_color_mad {
                return None;
            }
            return Some((1.0 - color_mad * 4.0).clamp(0.0, 1.0));
        }

        let p_dist = (lhs.p_hash ^ rhs.p_hash).count_ones();
        let d_dist = (lhs.d_hash ^ rhs.d_hash).count_ones();
        let passes_hash = (p_dist <= th.max_phash_hamming && d_dist <= th.max_dhash_hamming)
            || (p_dist <= th.alt_tight_phash && d_dist <= th.alt_loose_dhash);
        if !passes_hash || color_mad > th.max_color_mad {
            return None;
        }

        let zncc = luma_zncc(&lhs.luma16, &rhs.luma16);
        if zncc < th.min_luma_zncc {
            return None;
        }

        let hash_sim = 1.0 - (f64::from(p_dist) * 0.6 + f64::from(d_dist) * 0.4) / 64.0;
        let color_sim = (1.0 - color_mad * 2.2).max(0.0);
        let combined = 0.45 * zncc + 0.30 * hash_sim + 0.25 * color_sim;
        Some(combined.clamp(0.0, 0.999))
    }

    pub fn audio_waveform_similarity(
        duration_a: Option<f64>,
        peaks_a: &[f32],
        duration_b: Option<f64>,
        peaks_b: &[f32],
        sensitivity: DeduplicationSensitivity,
    ) -> Option<f64> {
        if peaks_a.len() < 12 || peaks_b.len() < 12 {
            return None;
        }
        let th = sensitivity.thresholds();
        if let (Some(da), Some(db)) = (duration_a, duration_b) {
            if da > 0.2 && db > 0.2 {
                let max_diff = th
                    .audio_duration_abs_seconds
                    .max(da.min(db) * th.audio_duration_rel_ratio);
                if (da - db).abs() > max_diff {
                    return None;
                }
            }
        }

        let a = resample_normalized_envelope(peaks_a, 64);
        let b = resample_normalized_envelope(peaks_b, 64);

        let mut mean_a = 0.0;
        let mut mean_b = 0.0;
        let mut mad = 0.0;
        for i in 0..64 {
            mean_a += a[i];
            mean_b += b[i];
            mad += (a[i] - b[i]).abs();
        }
        mean_a /= 64.0;
        mean_b /= 64.0;
        mad /= 64.0;
        if mad > th.max_audio_envelope_mad {
            return None;
        }

        let (mut num, mut den_a, mut den_b) = (0.0, 0.0, 0.0);
        for i in 0..64 {
            let da = a[i] - mean_a;
            let db = b[i] - mean_b;
            num += da * db;
            den_a += da * da;
            den_b += db * db;
        }
        let std_a = (den_a / 64.0).sqrt();
        let std_b = (den_b / 64.0).sqrt();
        if std_a.min(std_b) < 0.015 {
            if std_a.max(std_b) >= 0.03 || mad > 0.018 {
                return None;
            }
            return Some((1.0 - mad * 4.0).clamp(0.0, 0.999));
        }

        let denom = (den_a * den_b).sqrt();
        if denom <= 1e-6 {
            return None;
        }
        let zncc = num / denom;
        if zncc < th.min_audio_waveform_zncc {
            return None;
        }
        Some((0.65 * zncc + 0.35 * (1.0 - mad * 2.0).max(0.0)).clamp(0.0, 0.999))
    }

    pub fn evaluate_quality(
        asset: &AssetRecord,
        sharpness: f32,
        is_referenced_by_board: bool,
    ) -> QualityEvaluation {
        let ext = Path::new(&asset.file_name)
            .extension()
            .and_then(|e| e.to_str())
            .unwrap_or("")
            .to_ascii_lowercase();
        let mime = asset.mime_type.to_ascii_lowercase();
        let sharpness_f64 = f64::from(sharpness).clamp(0.0, 100.0);
        let tie_breaker = metadata_tie_breaker(asset, is_referenced_by_board);

        match asset.media_kind {
            MediaKind::Image | MediaKind::AnimatedImage => {
                let pixels =
                    i64::from(asset.pixel_width.max(1)) * i64::from(asset.pixel_height.max(1));
                let (format_label, is_lossless, format_bonus, bpp_norm) =
                    if asset.media_kind == MediaKind::AnimatedImage {
                        let label = if ext == "apng" {
                            "APNG 动图"
                        } else {
                            "GIF 动图"
                        };
                        (label.to_string(), ext == "apng", 120.0, 0.5)
                    } else {
                        match ext.as_str() {
                            "png" => ("PNG 无损".to_string(), true, 32.0, 0.28),
                            "tif" | "tiff" => ("TIFF 无损".to_string(), true, 34.0, 0.22),
                            "bmp" => ("BMP 无损".to_string(), true, 26.0, 0.16),
                            "jxl" => ("JPEG XL".to_string(), true, 32.0, 1.3),
                            "heic" | "heif" => ("HEIC".to_string(), false, 18.0, 1.35),
                            "avif" => ("AVIF".to_string(), false, 18.0, 1.45),
                            "webp" => ("WebP".to_string(), false, 16.0, 1.2),
                            "jpg" | "jpeg" => ("JPG".to_string(), false, 8.0, 1.0),
                            "gif" => ("GIF".to_string(), false, 0.0, 0.7),
                            _ => {
                                if mime.contains("png") {
                                    ("PNG 无损".to_string(), true, 32.0, 0.28)
                                } else if mime.contains("webp") {
                                    ("WebP".to_string(), false, 16.0, 1.2)
                                } else if mime.contains("jpeg") || mime.contains("jpg") {
                                    ("JPG".to_string(), false, 8.0, 1.0)
                                } else {
                                    let lbl = if ext.is_empty() {
                                        "图片".to_string()
                                    } else {
                                        ext.to_ascii_uppercase()
                                    };
                                    (lbl, false, 4.0, 1.0)
                                }
                            }
                        }
                    };
                let res_score = (pixels as f64).max(1.0).log2() * 100.0;
                let raw_bpp = (asset.file_size_bytes.max(0) as f64) / (pixels.max(1) as f64);
                let density_bonus = (1.0 + (raw_bpp * bpp_norm).min(4.0) * 10.0).log2() * 18.0;
                QualityEvaluation {
                    score: res_score
                        + format_bonus
                        + density_bonus
                        + sharpness_f64 * 0.22
                        + tie_breaker,
                    resolution_pixels: pixels,
                    format_label,
                    is_lossless_format: is_lossless,
                    sharpness_score: sharpness_f64,
                }
            }
            MediaKind::Video => {
                let pixels =
                    i64::from(asset.pixel_width.max(1)) * i64::from(asset.pixel_height.max(1));
                let res_score = (pixels as f64).max(1.0).log2() * 100.0;
                let duration = asset.duration_seconds.unwrap_or(1.0).max(0.5);
                let kbps = (asset.file_size_bytes.max(0) as f64 * 8.0) / duration / 1000.0;
                let bitrate_bonus = (1.0 + kbps.max(0.0) / 200.0).log2() * 32.0;
                let (format_label, format_bonus) = match ext.as_str() {
                    "mov" => ("MOV 视频".to_string(), 18.0),
                    "mp4" | "m4v" => ("MP4 视频".to_string(), 16.0),
                    "mkv" => ("MKV 视频".to_string(), 16.0),
                    "webm" => ("WebM 视频".to_string(), 10.0),
                    _ => (
                        if ext.is_empty() {
                            "视频".to_string()
                        } else {
                            format!("{} 视频", ext.to_ascii_uppercase())
                        },
                        8.0,
                    ),
                };
                QualityEvaluation {
                    score: res_score
                        + bitrate_bonus
                        + format_bonus
                        + sharpness_f64 * 0.15
                        + tie_breaker,
                    resolution_pixels: pixels,
                    format_label,
                    is_lossless_format: false,
                    sharpness_score: sharpness_f64,
                }
            }
            MediaKind::Audio => {
                let duration = asset.duration_seconds.unwrap_or(1.0).max(0.5);
                let kbps = (asset.file_size_bytes.max(0) as f64 * 8.0) / duration / 1000.0;
                let (format_label, is_lossless, format_bonus) = match ext.as_str() {
                    "flac" => ("FLAC 无损".to_string(), true, 320.0),
                    "wav" => ("WAV 无损".to_string(), true, 315.0),
                    "aiff" | "aif" => ("AIFF 无损".to_string(), true, 315.0),
                    "alac" => ("ALAC 无损".to_string(), true, 315.0),
                    "caf" => ("CAF 音频".to_string(), true, 300.0),
                    "m4a" | "aac" => ("AAC / M4A".to_string(), false, 160.0),
                    "opus" => ("Opus 音频".to_string(), false, 165.0),
                    "ogg" => ("OGG 音频".to_string(), false, 150.0),
                    "mp3" => ("MP3".to_string(), false, 130.0),
                    _ => (
                        if ext.is_empty() {
                            "音频".to_string()
                        } else {
                            ext.to_ascii_uppercase()
                        },
                        false,
                        110.0,
                    ),
                };
                let bitrate_score = (1.0 + kbps.max(0.0) / 16.0).log2() * 45.0;
                QualityEvaluation {
                    score: format_bonus + bitrate_score + tie_breaker,
                    resolution_pixels: 0,
                    format_label,
                    is_lossless_format: is_lossless,
                    sharpness_score: 0.0,
                }
            }
            MediaKind::DesignFile => {
                let pixels =
                    i64::from(asset.pixel_width.max(1)) * i64::from(asset.pixel_height.max(1));
                let (format_label, format_bonus) = match ext.as_str() {
                    "svg" => ("SVG 矢量".to_string(), 260.0),
                    "ai" | "eps" => ("矢量源文件".to_string(), 255.0),
                    "psd" | "psb" => ("PSD 分层源文件".to_string(), 250.0),
                    "fig" => ("Figma 源文件".to_string(), 245.0),
                    "sketch" => ("Sketch 源文件".to_string(), 240.0),
                    "afdesign" | "afphoto" => ("Affinity 源文件".to_string(), 235.0),
                    _ => (
                        if ext.is_empty() {
                            "设计文件".to_string()
                        } else {
                            ext.to_ascii_uppercase()
                        },
                        200.0,
                    ),
                };
                let size_score =
                    (1.0 + (asset.file_size_bytes.max(0) as f64) / 1024.0).log2() * 14.0;
                let res_score = (pixels as f64).max(1.0).log2() * 40.0;
                QualityEvaluation {
                    score: format_bonus + res_score + size_score + tie_breaker,
                    resolution_pixels: pixels,
                    format_label,
                    is_lossless_format: true,
                    sharpness_score: sharpness_f64,
                }
            }
            MediaKind::WebBookmark => {
                let mut score = 100.0;
                let label = if let Some(post) = asset
                    .rich_metadata
                    .as_ref()
                    .and_then(|r| r.social_post.as_ref())
                {
                    score += post.effective_attachments().len() as f64 * 28.0;
                    if !post.media_fetch_failed {
                        score += 45.0;
                    }
                    if post.video_url.is_some()
                        || (asset.file_size_bytes > 50_000 && post.has_video)
                    {
                        score += 35.0;
                    }
                    score += (post.body_text.chars().count() as f64 * 0.08).min(40.0);
                    if post.author_avatar_url.is_some() {
                        score += 6.0;
                    }
                    post.platform.post_type_label().to_string()
                } else if let Some(repo) = asset
                    .rich_metadata
                    .as_ref()
                    .and_then(|r| r.github_repo.as_ref())
                {
                    score += 60.0;
                    if repo
                        .readme_markdown
                        .as_deref()
                        .is_some_and(|s| !s.is_empty())
                    {
                        score += 35.0;
                    }
                    if repo.description.as_deref().is_some_and(|s| !s.is_empty()) {
                        score += 10.0;
                    }
                    "GitHub 仓库".to_string()
                } else {
                    if asset.pixel_width > 0 && asset.pixel_height > 0 {
                        score += 20.0;
                    }
                    "网页书签".to_string()
                };
                score += (1.0 + (asset.file_size_bytes.max(0) as f64) / 512.0).log2() * 5.0;
                QualityEvaluation {
                    score: score + tie_breaker * 2.0,
                    resolution_pixels: i64::from(asset.pixel_width.max(0))
                        * i64::from(asset.pixel_height.max(0)),
                    format_label: label,
                    is_lossless_format: false,
                    sharpness_score: 0.0,
                }
            }
            MediaKind::Document => {
                let format_label = if ext.is_empty() {
                    "文档".to_string()
                } else {
                    ext.to_ascii_uppercase()
                };
                let size_score =
                    (1.0 + (asset.file_size_bytes.max(0) as f64) / 512.0).log2() * 22.0;
                let format_bonus = match ext.as_str() {
                    "pdf" => 40.0,
                    "docx" | "pptx" | "key" | "pages" => 36.0,
                    "md" | "markdown" => 32.0,
                    _ => 20.0,
                };
                QualityEvaluation {
                    score: format_bonus + size_score + tie_breaker * 2.0,
                    resolution_pixels: i64::from(asset.pixel_width.max(0))
                        * i64::from(asset.pixel_height.max(0)),
                    format_label,
                    is_lossless_format: true,
                    sharpness_score: 0.0,
                }
            }
            MediaKind::Model3D => {
                let (format_label, format_bonus) = match ext.as_str() {
                    "blend" => ("Blender 工程".to_string(), 240.0),
                    "usdz" | "usda" | "usdc" => ("USDZ 3D".to_string(), 230.0),
                    "glb" | "gltf" => ("glTF / GLB".to_string(), 225.0),
                    "fbx" => ("FBX 3D".to_string(), 220.0),
                    "obj" => ("OBJ 网格".to_string(), 190.0),
                    "stl" => ("STL 网格".to_string(), 180.0),
                    _ => (
                        if ext.is_empty() {
                            "3D 模型".to_string()
                        } else {
                            format!("{} 3D", ext.to_ascii_uppercase())
                        },
                        170.0,
                    ),
                };
                let size_score =
                    (1.0 + (asset.file_size_bytes.max(0) as f64) / 4096.0).log2() * 25.0;
                QualityEvaluation {
                    score: format_bonus + size_score + tie_breaker,
                    resolution_pixels: i64::from(asset.pixel_width.max(0))
                        * i64::from(asset.pixel_height.max(0)),
                    format_label,
                    is_lossless_format: true,
                    sharpness_score: sharpness_f64,
                }
            }
        }
    }

    pub fn cluster_duplicates(
        items: &[IndexedMediaAsset],
        sensitivity: DeduplicationSensitivity,
        board_referenced_asset_ids: &HashSet<Uuid>,
    ) -> Vec<DuplicateGroup> {
        if items.len() < 2 {
            return Vec::new();
        }
        let mut by_bucket: HashMap<MediaComparisonBucket, Vec<&IndexedMediaAsset>> = HashMap::new();
        for item in items {
            by_bucket
                .entry(MediaComparisonBucket::for_kind(item.asset.media_kind))
                .or_default()
                .push(item);
        }

        let mut all_groups = Vec::new();
        for (bucket, bucket_items) in by_bucket {
            if bucket_items.len() >= 2 {
                all_groups.extend(cluster_within_bucket(
                    bucket,
                    &bucket_items,
                    sensitivity,
                    board_referenced_asset_ids,
                ));
            }
        }

        all_groups.sort_by(|a, b| {
            let a_exact = a.match_kind == DuplicateMatchKind::ExactBinary;
            let b_exact = b.match_kind == DuplicateMatchKind::ExactBinary;
            b_exact
                .cmp(&a_exact)
                .then_with(|| b.reclaimable_bytes.cmp(&a.reclaimable_bytes))
                .then_with(|| b.candidates.len().cmp(&a.candidates.len()))
        });
        all_groups
    }
}

fn cluster_within_bucket(
    bucket: MediaComparisonBucket,
    items: &[&IndexedMediaAsset],
    sensitivity: DeduplicationSensitivity,
    board_referenced_asset_ids: &HashSet<Uuid>,
) -> Vec<DuplicateGroup> {
    // 1. Pre-group exact SHA-256 matches
    let mut exact_by_hash: HashMap<String, Vec<usize>> = HashMap::new();
    for (idx, item) in items.iter().enumerate() {
        let h = item.asset.content_hash.trim();
        if !h.is_empty() {
            exact_by_hash.entry(h.to_string()).or_default().push(idx);
        }
    }

    let mut rep_indices: Vec<usize> = Vec::new();
    let mut rep_to_members: HashMap<usize, Vec<usize>> = HashMap::new();
    let mut handled_hashes: HashSet<String> = HashSet::new();

    for (idx, item) in items.iter().enumerate() {
        let h = item.asset.content_hash.trim();
        if !h.is_empty() {
            if let Some(group) = exact_by_hash.get(h) {
                if group.len() >= 2 {
                    if !handled_hashes.insert(h.to_string()) {
                        continue;
                    }
                    let rep = group
                        .iter()
                        .copied()
                        .find(|&i| items[i].fingerprint.is_some())
                        .unwrap_or(group[0]);
                    rep_indices.push(rep);
                    rep_to_members.insert(rep, group.clone());
                    continue;
                }
            }
        }
        rep_indices.push(idx);
        rep_to_members.insert(idx, vec![idx]);
    }

    // 2. Bucket-specific classical matching across representatives
    let mut verified_edges: Vec<(usize, usize, f64, DuplicateMatchKind)> = Vec::new();

    match bucket {
        MediaComparisonBucket::WebBookmark => {
            let mut by_key: HashMap<String, Vec<usize>> = HashMap::new();
            for (rep_pos, &item_idx) in rep_indices.iter().enumerate() {
                if let Some(key) = items[item_idx]
                    .canonical_bookmark_key
                    .clone()
                    .or_else(|| SmartDeduplicator::canonical_bookmark_key(&items[item_idx].asset))
                {
                    by_key.entry(key).or_default().push(rep_pos);
                }
            }
            for positions in by_key.values() {
                if positions.len() >= 2 {
                    for &pos in &positions[1..] {
                        verified_edges.push((
                            positions[0],
                            pos,
                            1.0,
                            DuplicateMatchKind::CanonicalLink,
                        ));
                    }
                }
            }
        }
        MediaComparisonBucket::Document => {
            let mut by_text: HashMap<String, Vec<usize>> = HashMap::new();
            for (rep_pos, &item_idx) in rep_indices.iter().enumerate() {
                if let Some(ref th) = items[item_idx].normalized_text_hash {
                    if !th.is_empty() {
                        by_text.entry(th.clone()).or_default().push(rep_pos);
                    }
                }
            }
            for positions in by_text.values() {
                if positions.len() >= 2 {
                    for &pos in &positions[1..] {
                        verified_edges.push((
                            positions[0],
                            pos,
                            1.0,
                            DuplicateMatchKind::NormalizedText,
                        ));
                    }
                }
            }
        }
        MediaComparisonBucket::Audio => {
            let audio_reps: Vec<(usize, usize)> = rep_indices
                .iter()
                .enumerate()
                .filter(|(_, &item_idx)| items[item_idx].asset.waveform_peaks.len() >= 12)
                .map(|(pos, &idx)| (pos, idx))
                .collect();
            for i in 0..audio_reps.len() {
                let (pos_a, idx_a) = audio_reps[i];
                let a = &items[idx_a].asset;
                for &(pos_b, idx_b) in &audio_reps[i + 1..] {
                    let b = &items[idx_b].asset;
                    if let Some(sim) = SmartDeduplicator::audio_waveform_similarity(
                        a.duration_seconds,
                        &a.waveform_peaks,
                        b.duration_seconds,
                        &b.waveform_peaks,
                        sensitivity,
                    ) {
                        verified_edges.push((pos_a, pos_b, sim, DuplicateMatchKind::AudioWaveform));
                    }
                }
            }
        }
        MediaComparisonBucket::RasterVisual
        | MediaComparisonBucket::Video
        | MediaComparisonBucket::DesignFile
        | MediaComparisonBucket::Model3D => {
            let effective_sens = if matches!(
                bucket,
                MediaComparisonBucket::DesignFile | MediaComparisonBucket::Model3D
            ) && sensitivity == DeduplicationSensitivity::Relaxed
            {
                DeduplicationSensitivity::Balanced
            } else {
                sensitivity
            };
            let th = effective_sens.thresholds();
            let max_p = th.max_phash_hamming.max(th.alt_tight_phash);
            let max_d = th.max_dhash_hamming.max(th.alt_loose_dhash);

            let fp_reps: Vec<(usize, usize, &ClassicalImageFingerprint)> = rep_indices
                .iter()
                .enumerate()
                .filter_map(|(pos, &item_idx)| {
                    items[item_idx]
                        .fingerprint
                        .as_ref()
                        .map(|fp| (pos, item_idx, fp))
                })
                .collect();

            let mut check_visual_pair =
                |left: (usize, usize, &ClassicalImageFingerprint),
                 right: (usize, usize, &ClassicalImageFingerprint)| {
                    if bucket == MediaComparisonBucket::Video {
                        if let (Some(da), Some(db)) = (
                            items[left.1].asset.duration_seconds,
                            items[right.1].asset.duration_seconds,
                        ) {
                            if da > 0.2 && db > 0.2 {
                                let max_diff = th
                                    .video_duration_abs_seconds
                                    .max(da.min(db) * th.video_duration_rel_ratio);
                                if (da - db).abs() > max_diff {
                                    return;
                                }
                            }
                        }
                    }
                    if let Some(sim) =
                        SmartDeduplicator::visual_similarity(left.2, right.2, effective_sens)
                    {
                        verified_edges.push((
                            left.0,
                            right.0,
                            sim,
                            DuplicateMatchKind::NearIdentical,
                        ));
                    }
                };

            if fp_reps.len() <= 4_000 {
                for i in 0..fp_reps.len() {
                    let left = fp_reps[i];
                    for &right in &fp_reps[i + 1..] {
                        if left.2.luma_std_dev >= 3.5 && right.2.luma_std_dev >= 3.5 {
                            if (left.2.p_hash ^ right.2.p_hash).count_ones() > max_p {
                                continue;
                            }
                            if (left.2.d_hash ^ right.2.d_hash).count_ones() > max_d {
                                continue;
                            }
                        }
                        check_visual_pair(left, right);
                    }
                }
            } else {
                // 4x16-bit Multi-Index Hashing (MIH) for large libraries (> 4,000 visual assets)
                let mut p_buckets: [HashMap<u16, Vec<usize>>; 4] = Default::default();
                let mut d_buckets: [HashMap<u16, Vec<usize>>; 4] = Default::default();
                let mut flat_indices: Vec<usize> = Vec::new();

                for (pos, entry) in fp_reps.iter().enumerate() {
                    if entry.2.luma_std_dev < 3.5 {
                        flat_indices.push(pos);
                    }
                    for band in 0..4usize {
                        let p_slice = ((entry.2.p_hash >> (band * 16)) & 0xFFFF) as u16;
                        let d_slice = ((entry.2.d_hash >> (band * 16)) & 0xFFFF) as u16;
                        p_buckets[band].entry(p_slice).or_default().push(pos);
                        d_buckets[band].entry(d_slice).or_default().push(pos);
                    }
                }

                let mut checked_pairs: HashSet<u64> = HashSet::new();
                let mut check_pair_idx = |i: usize, j: usize| {
                    let lo = i.min(j);
                    let hi = i.max(j);
                    if lo == hi {
                        return;
                    }
                    let key = ((lo as u64) << 32) | (hi as u64);
                    if checked_pairs.insert(key) {
                        check_visual_pair(fp_reps[lo], fp_reps[hi]);
                    }
                };

                for band in 0..4usize {
                    for list in p_buckets[band].values() {
                        if list.len() >= 2 && list.len() <= 256 {
                            for a in 0..list.len() {
                                for &b in &list[a + 1..] {
                                    check_pair_idx(list[a], b);
                                }
                            }
                        }
                    }
                    for list in d_buckets[band].values() {
                        if list.len() >= 2 && list.len() <= 256 {
                            for a in 0..list.len() {
                                for &b in &list[a + 1..] {
                                    check_pair_idx(list[a], b);
                                }
                            }
                        }
                    }
                }
                if flat_indices.len() >= 2 && flat_indices.len() <= 512 {
                    for a in 0..flat_indices.len() {
                        for &b in &flat_indices[a + 1..] {
                            check_pair_idx(flat_indices[a], b);
                        }
                    }
                }
            }
        }
    }

    // 3. Anti-chaining clustering via Union-Find
    verified_edges.sort_by(|a, b| b.2.partial_cmp(&a.2).unwrap_or(std::cmp::Ordering::Equal));
    let mut parent: Vec<usize> = (0..rep_indices.len()).collect();
    let mut cluster_members: Vec<Vec<usize>> = (0..rep_indices.len()).map(|i| vec![i]).collect();
    let mut cluster_non_exact_kind: HashMap<usize, DuplicateMatchKind> = HashMap::new();

    fn find(parent: &mut [usize], mut x: usize) -> usize {
        while parent[x] != x {
            parent[x] = parent[parent[x]];
            x = parent[x];
        }
        x
    }

    for (a, b, _sim, kind) in verified_edges {
        let ra = find(&mut parent, a);
        let rb = find(&mut parent, b);
        if ra == rb {
            continue;
        }
        if kind == DuplicateMatchKind::NearIdentical {
            if let (Some(fp_a), Some(fp_b)) = (
                items[rep_indices[ra]].fingerprint.as_ref(),
                items[rep_indices[rb]].fingerprint.as_ref(),
            ) {
                if SmartDeduplicator::visual_similarity(fp_a, fp_b, sensitivity).is_none() {
                    continue;
                }
            }
        }
        let (keep_root, merge_root) = if cluster_members[ra].len() >= cluster_members[rb].len() {
            (ra, rb)
        } else {
            (rb, ra)
        };
        parent[merge_root] = keep_root;
        let moved = std::mem::take(&mut cluster_members[merge_root]);
        cluster_members[keep_root].extend(moved);
        cluster_non_exact_kind.insert(keep_root, kind);
    }

    // 4. Materialize DuplicateGroup objects with highest-quality ranking
    let mut groups = Vec::new();
    let mut visited_roots = HashSet::new();

    for rep_pos in 0..rep_indices.len() {
        let root = find(&mut parent, rep_pos);
        if !visited_roots.insert(root) {
            continue;
        }
        let mut member_item_indices: Vec<usize> = Vec::new();
        for &rp in &cluster_members[root] {
            if let Some(members) = rep_to_members.get(&rep_indices[rp]) {
                member_item_indices.extend(members);
            } else {
                member_item_indices.push(rep_indices[rp]);
            }
        }
        if member_item_indices.len() < 2 {
            continue;
        }

        let unique_hashes: HashSet<&str> = member_item_indices
            .iter()
            .map(|&i| items[i].asset.content_hash.as_str())
            .filter(|h| !h.is_empty())
            .collect();
        let is_all_exact_binary = unique_hashes.len() == 1
            && member_item_indices
                .iter()
                .all(|&i| !items[i].asset.content_hash.is_empty());
        let match_kind = if is_all_exact_binary {
            DuplicateMatchKind::ExactBinary
        } else {
            cluster_non_exact_kind
                .get(&root)
                .copied()
                .unwrap_or(DuplicateMatchKind::NearIdentical)
        };

        struct ScoredEntry {
            item_idx: usize,
            eval: QualityEvaluation,
            is_board_ref: bool,
        }

        let mut scored: Vec<ScoredEntry> = member_item_indices
            .iter()
            .map(|&idx| {
                let item = items[idx];
                let board_ref = board_referenced_asset_ids.contains(&item.asset.id);
                let eval = SmartDeduplicator::evaluate_quality(
                    &item.asset,
                    item.fingerprint
                        .as_ref()
                        .map(|f| f.sharpness)
                        .unwrap_or(0.0),
                    board_ref,
                );
                ScoredEntry {
                    item_idx: idx,
                    eval,
                    is_board_ref: board_ref,
                }
            })
            .collect();

        scored.sort_by(|lhs, rhs| {
            if (lhs.eval.score - rhs.eval.score).abs() > 0.001 {
                return rhs
                    .eval
                    .score
                    .partial_cmp(&lhs.eval.score)
                    .unwrap_or(std::cmp::Ordering::Equal);
            }
            let la = &items[lhs.item_idx].asset;
            let ra = &items[rhs.item_idx].asset;
            la.created_at
                .cmp(&ra.created_at)
                .then_with(|| la.id.to_string().cmp(&ra.id.to_string()))
        });

        let Some(winner) = scored.first() else {
            continue;
        };
        let winner_item = items[winner.item_idx];
        let runner_up = scored.get(1);

        let mut group_min_sim = 1.0_f64;
        let mut candidates = Vec::with_capacity(scored.len());

        for (rank, entry) in scored.iter().enumerate() {
            let item = items[entry.item_idx];
            let is_keeper = rank == 0;
            let sim_to_keeper = if is_keeper
                || is_all_exact_binary
                || matches!(
                    match_kind,
                    DuplicateMatchKind::CanonicalLink | DuplicateMatchKind::NormalizedText
                )
                || (!item.asset.content_hash.is_empty()
                    && item.asset.content_hash == winner_item.asset.content_hash)
            {
                1.0
            } else if match_kind == DuplicateMatchKind::AudioWaveform {
                SmartDeduplicator::audio_waveform_similarity(
                    winner_item.asset.duration_seconds,
                    &winner_item.asset.waveform_peaks,
                    item.asset.duration_seconds,
                    &item.asset.waveform_peaks,
                    sensitivity,
                )
                .unwrap_or(0.96)
            } else if let (Some(w_fp), Some(c_fp)) =
                (winner_item.fingerprint.as_ref(), item.fingerprint.as_ref())
            {
                SmartDeduplicator::visual_similarity(w_fp, c_fp, sensitivity)
                    .or_else(|| {
                        SmartDeduplicator::visual_similarity(
                            w_fp,
                            c_fp,
                            DeduplicationSensitivity::Relaxed,
                        )
                    })
                    .unwrap_or(0.94)
            } else {
                0.95
            };

            if !is_keeper {
                group_min_sim = group_min_sim.min(sim_to_keeper);
            }

            let compared_eval = if is_keeper {
                runner_up.map(|r| &r.eval)
            } else {
                Some(&winner.eval)
            };
            let compared_asset = if is_keeper {
                runner_up.map(|r| &items[r.item_idx].asset)
            } else {
                Some(&winner_item.asset)
            };

            let reasons = build_reasons(
                &entry.eval,
                &item.asset,
                is_keeper,
                entry.is_board_ref,
                compared_eval,
                compared_asset,
                match_kind,
            );

            candidates.push(DuplicateAssetCandidate {
                asset: item.asset.clone(),
                quality_score: entry.eval.score,
                resolution_pixels: entry.eval.resolution_pixels,
                format_label: entry.eval.format_label.clone(),
                is_lossless_format: entry.eval.is_lossless_format,
                sharpness_score: entry.eval.sharpness_score,
                is_recommended_keep: is_keeper,
                is_referenced_by_board: entry.is_board_ref,
                similarity_to_keeper: sim_to_keeper,
                quality_reasons: reasons,
            });
        }

        let reclaimable_bytes: i64 = candidates
            .iter()
            .filter(|c| c.asset.id != winner_item.asset.id)
            .map(|c| c.asset.file_size_bytes.max(0))
            .sum();

        groups.push(DuplicateGroup {
            id: Uuid::new_v4(),
            primary_media_kind: winner_item.asset.media_kind,
            match_kind,
            similarity_score: if is_all_exact_binary {
                1.0
            } else {
                group_min_sim
            },
            recommended_keep_asset_id: winner_item.asset.id,
            candidates,
            reclaimable_bytes,
        });
    }

    groups
}

fn build_reasons(
    entry: &QualityEvaluation,
    asset: &AssetRecord,
    is_keeper: bool,
    is_board_ref: bool,
    other: Option<&QualityEvaluation>,
    other_asset: Option<&AssetRecord>,
    match_kind: DuplicateMatchKind,
) -> Vec<String> {
    let mut reasons = Vec::new();
    if is_keeper {
        match match_kind {
            DuplicateMatchKind::ExactBinary => {
                if is_board_ref {
                    reasons.push("情绪板引用中".to_string());
                }
                if asset.folder_id.is_some() && other_asset.is_some_and(|o| o.folder_id.is_none()) {
                    reasons.push("已整理至文件夹".to_string());
                }
                if !asset.tags.is_empty() || asset.rating > 0 {
                    reasons.push("含标签或评分".to_string());
                }
                if reasons.is_empty() {
                    reasons.push("最早导入原件".to_string());
                }
            }
            DuplicateMatchKind::CanonicalLink => {
                let my_ok = asset
                    .rich_metadata
                    .as_ref()
                    .and_then(|r| r.social_post.as_ref())
                    .is_some_and(|p| !p.media_fetch_failed);
                let other_fail = other_asset
                    .and_then(|a| a.rich_metadata.as_ref())
                    .and_then(|r| r.social_post.as_ref())
                    .is_some_and(|p| p.media_fetch_failed);
                if my_ok && other_fail {
                    reasons.push("媒体加载完整".to_string());
                }
                let my_atts = asset
                    .rich_metadata
                    .as_ref()
                    .and_then(|r| r.social_post.as_ref())
                    .map(|p| p.effective_attachments().len())
                    .unwrap_or(0);
                let other_atts = other_asset
                    .and_then(|a| a.rich_metadata.as_ref())
                    .and_then(|r| r.social_post.as_ref())
                    .map(|p| p.effective_attachments().len())
                    .unwrap_or(0);
                if my_atts > other_atts {
                    reasons.push(format!("附件更完整（{my_atts} 项）"));
                }
                if is_board_ref {
                    reasons.push("情绪板引用中".to_string());
                }
                if reasons.is_empty() {
                    reasons.push("内容更完整".to_string());
                }
            }
            DuplicateMatchKind::NormalizedText => {
                if asset.file_size_bytes > other_asset.map(|o| o.file_size_bytes).unwrap_or(0) {
                    reasons.push("原件更完整".to_string());
                }
                if !asset.tags.is_empty() || asset.rating > 0 {
                    reasons.push("含标签或评分".to_string());
                }
                if reasons.is_empty() {
                    reasons.push("推荐保留原件".to_string());
                }
            }
            DuplicateMatchKind::AudioWaveform => {
                if entry.is_lossless_format && other.is_none_or(|o| !o.is_lossless_format) {
                    reasons.push(format!("无损音质（{}）", entry.format_label));
                } else if asset.file_size_bytes as f64
                    > (other_asset.map(|o| o.file_size_bytes).unwrap_or(0) as f64) * 1.15
                {
                    reasons.push("比特率更高".to_string());
                }
                if is_board_ref {
                    reasons.push("情绪板引用中".to_string());
                }
                if reasons.is_empty() {
                    reasons.push("音质最优".to_string());
                }
            }
            DuplicateMatchKind::NearIdentical => {
                if let (Some(o_eval), Some(o_asset)) = (other, other_asset) {
                    if asset.media_kind == MediaKind::AnimatedImage
                        && o_asset.media_kind == MediaKind::Image
                    {
                        reasons.push("保留完整动图".to_string());
                    }
                    if (entry.resolution_pixels as f64) > (o_eval.resolution_pixels as f64) * 1.05 {
                        let ratio = (entry.resolution_pixels as f64)
                            / (o_eval.resolution_pixels.max(1) as f64);
                        if ratio >= 1.5 {
                            reasons.push(format!("分辨率 {ratio:.1}×"));
                        } else {
                            reasons.push("分辨率更高".to_string());
                        }
                    }
                    if entry.is_lossless_format && !o_eval.is_lossless_format {
                        reasons.push("无损/源格式".to_string());
                    } else if (asset.file_size_bytes as f64)
                        > (o_asset.file_size_bytes as f64) * 1.2
                        && (entry.resolution_pixels as f64)
                            >= (o_eval.resolution_pixels as f64) * 0.95
                    {
                        reasons.push(if asset.media_kind == MediaKind::Video {
                            "视频码率更高".to_string()
                        } else {
                            "压缩损失更少".to_string()
                        });
                    }
                    if entry.sharpness_score > o_eval.sharpness_score + 3.0 {
                        reasons.push("细节更锐利".to_string());
                    }
                }
                if is_board_ref {
                    reasons.push("情绪板引用中".to_string());
                }
                if reasons.is_empty() {
                    reasons.push("综合画质最优".to_string());
                }
            }
        }
    } else {
        match match_kind {
            DuplicateMatchKind::ExactBinary => reasons.push("完全重复副本".to_string()),
            DuplicateMatchKind::CanonicalLink => reasons.push("重复收藏链接".to_string()),
            DuplicateMatchKind::NormalizedText => reasons.push("重复文本副本".to_string()),
            DuplicateMatchKind::AudioWaveform => {
                if !entry.is_lossless_format && other.is_some_and(|o| o.is_lossless_format) {
                    reasons.push("有损压缩音质".to_string());
                } else {
                    reasons.push("较低码率音频副本".to_string());
                }
            }
            DuplicateMatchKind::NearIdentical => {
                if let Some(o_eval) = other {
                    if (entry.resolution_pixels as f64) < (o_eval.resolution_pixels as f64) * 0.95 {
                        reasons.push("分辨率较低".to_string());
                    } else if !entry.is_lossless_format && o_eval.is_lossless_format {
                        reasons.push("有损压缩版本".to_string());
                    } else if (asset.file_size_bytes as f64)
                        < (other_asset.map(|o| o.file_size_bytes).unwrap_or(0) as f64) * 0.85
                    {
                        reasons.push(if asset.media_kind == MediaKind::Video {
                            "较低码率视频".to_string()
                        } else {
                            "高压缩低码率".to_string()
                        });
                    } else {
                        reasons.push("较低画质副本".to_string());
                    }
                }
            }
        }
        if is_board_ref {
            reasons.push("清理时自动迁移情绪板引用".to_string());
        }
    }
    reasons
}

fn metadata_tie_breaker(asset: &AssetRecord, is_referenced_by_board: bool) -> f64 {
    let mut score = 0.0;
    if is_referenced_by_board {
        score += 3.0;
    }
    if asset.folder_id.is_some() {
        score += 1.5;
    }
    if asset.rating > 0 {
        score += f64::from(asset.rating.min(5)) * 0.3;
    }
    if !asset.tags.is_empty() {
        score += (asset.tags.len() as f64 * 0.25).min(1.2);
    }
    if !asset.notes.trim().is_empty() {
        score += 0.4;
    }
    if asset.source_url.is_some() {
        score += 0.3;
    }
    if asset
        .rich_metadata
        .as_ref()
        .and_then(|r| r.photo_exif.as_ref())
        .is_some_and(|e| e.has_meaningful_camera_exif())
    {
        score += 0.4;
    }
    if asset
        .rich_metadata
        .as_ref()
        .and_then(|r| r.ai_generation.as_ref())
        .is_some_and(|a| !a.is_empty())
    {
        score += 0.4;
    }
    if asset.pinned_offline {
        score += 0.4;
    }
    score
}

fn composite_on_white(mut rgba: RgbaImage) -> RgbaImage {
    for px in rgba.pixels_mut() {
        let [r, g, b, a] = px.0;
        if a < 255 {
            let af = f32::from(a) / 255.0;
            let inv = 1.0 - af;
            px.0[0] = (f32::from(r) * af + 255.0 * inv).round() as u8;
            px.0[1] = (f32::from(g) * af + 255.0 * inv).round() as u8;
            px.0[2] = (f32::from(b) * af + 255.0 * inv).round() as u8;
            px.0[3] = 255;
        }
    }
    rgba
}

fn compute_phash(luma: &[f64; 32 * 32]) -> u64 {
    let table = dct_cos_table();
    let mut row_dct = [0.0_f64; 32 * 8];
    for y in 0..32usize {
        let base = y * 32;
        for u in 0..8usize {
            let cos_u = &table[u];
            let mut acc = 0.0;
            for x in 0..32usize {
                acc += luma[base + x] * cos_u[x];
            }
            row_dct[y * 8 + u] = acc;
        }
    }

    let mut coeffs = [0.0_f64; 64];
    for v in 0..8usize {
        let cos_v = &table[v];
        for u in 0..8usize {
            let mut acc = 0.0;
            for y in 0..32usize {
                acc += row_dct[y * 8 + u] * cos_v[y];
            }
            coeffs[v * 8 + u] = acc;
        }
    }

    let mut ac: Vec<f64> = coeffs[1..].to_vec();
    ac.sort_by(|a, b| a.partial_cmp(b).unwrap_or(std::cmp::Ordering::Equal));
    let median = ac[ac.len() / 2];

    let mut hash = 0u64;
    for (i, &c) in coeffs.iter().enumerate().skip(1) {
        if c > median {
            hash |= 1u64 << i;
        }
    }
    if coeffs[0] > 32.0 * 128.0 {
        hash |= 1;
    }
    hash
}

fn compute_laplacian_sharpness(image: &DynamicImage) -> f32 {
    let src_w = image.width().max(1);
    let src_h = image.height().max(1);
    let scale = (128.0 / f64::from(src_w.max(src_h))).min(1.0);
    let w = ((f64::from(src_w) * scale).round() as u32).max(8);
    let h = ((f64::from(src_h) * scale).round() as u32).max(8);
    let rgba = image.resize_exact(w, h, FilterType::Triangle).to_rgba8();

    let mut luma = vec![0.0_f32; (w * h) as usize];
    for (i, px) in rgba.pixels().enumerate() {
        let [r, g, b, _] = px.0;
        luma[i] = 0.2126 * f32::from(r) + 0.7152 * f32::from(g) + 0.0722 * f32::from(b);
    }

    let (mut sum, mut sum_sq, mut count) = (0.0_f64, 0.0_f64, 0usize);
    let wu = w as usize;
    let hu = h as usize;
    for y in 1..hu.saturating_sub(1) {
        let row = y * wu;
        for x in 1..wu.saturating_sub(1) {
            let c = luma[row + x];
            let lap = f64::from(
                luma[row - wu + x] + luma[row + wu + x] + luma[row + x - 1] + luma[row + x + 1]
                    - 4.0 * c,
            );
            sum += lap;
            sum_sq += lap * lap;
            count += 1;
        }
    }
    if count == 0 {
        return 0.0;
    }
    let mean = sum / (count as f64);
    let variance = ((sum_sq / (count as f64)) - mean * mean).max(0.0);
    ((variance.ln_1p() * 11.5).min(100.0)) as f32
}

fn resample_normalized_envelope(peaks: &[f32], target_count: usize) -> Vec<f64> {
    if peaks.is_empty() {
        return vec![0.0; target_count];
    }
    let mut out = vec![0.0_f64; target_count];
    let max_idx = (peaks.len().saturating_sub(1)) as f64;
    let denom = (target_count.saturating_sub(1)).max(1) as f64;
    let mut max_peak = 0.0_f64;
    for (i, slot) in out.iter_mut().enumerate() {
        let pos = (i as f64 / denom) * max_idx;
        let lo = pos.floor() as usize;
        let hi = (lo + 1).min(peaks.len() - 1);
        let frac = pos - (lo as f64);
        let val = (f64::from(peaks[lo]) * (1.0 - frac) + f64::from(peaks[hi]) * frac).max(0.0);
        *slot = val;
        if val > max_peak {
            max_peak = val;
        }
    }
    if max_peak > 1e-5 {
        for slot in &mut out {
            *slot /= max_peak;
        }
    }
    out
}

fn rgb_mean_absolute_difference(a: &[u8], b: &[u8]) -> f64 {
    let n = a.len().min(b.len());
    if n == 0 {
        return 1.0;
    }
    let total: u64 = a
        .iter()
        .zip(b.iter())
        .map(|(&x, &y)| u64::from(x.abs_diff(y)))
        .sum();
    (total as f64) / ((n as f64) * 255.0)
}

fn luma_zncc(a: &[u8], b: &[u8]) -> f64 {
    let n = a.len().min(b.len());
    if n == 0 {
        return 0.0;
    }
    let nf = n as f64;
    let mean_a: f64 = a[..n].iter().map(|&v| f64::from(v)).sum::<f64>() / nf;
    let mean_b: f64 = b[..n].iter().map(|&v| f64::from(v)).sum::<f64>() / nf;
    let (mut num, mut den_a, mut den_b) = (0.0, 0.0, 0.0);
    for i in 0..n {
        let da = f64::from(a[i]) - mean_a;
        let db = f64::from(b[i]) - mean_b;
        num += da * db;
        den_a += da * da;
        den_b += db * db;
    }
    let denom = (den_a * den_b).sqrt();
    if denom <= 1e-6 {
        0.0
    } else {
        num / denom
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::media::artwork::MediaArtwork;
    use image::Rgba;

    fn make_pattern_image(w: u32, h: u32, tint: [u8; 3]) -> DynamicImage {
        let mut img = RgbaImage::new(w, h);
        for y in 0..h {
            for x in 0..w {
                let fx = x as f32 / w as f32;
                let fy = y as f32 / h as f32;
                let diag: f32 = if (fx - fy).abs() < 0.18 { 1.0 } else { 0.32 };
                let circle: f32 = if (fx - 0.72).powi(2) + (fy - 0.28).powi(2) < 0.045 {
                    0.95
                } else {
                    0.0
                };
                let v = (diag + circle).min(1.0);
                let r = (f32::from(tint[0]) * v).round().clamp(0.0, 255.0) as u8;
                let g = (f32::from(tint[1]) * v).round().clamp(0.0, 255.0) as u8;
                let b = (f32::from(tint[2]) * v).round().clamp(0.0, 255.0) as u8;
                img.put_pixel(x, y, Rgba([r, g, b, 255]));
            }
        }
        DynamicImage::ImageRgba8(img)
    }

    #[test]
    fn clusters_highres_png_vs_scaled_jpg_and_rejects_recolor_and_solid_swatches() {
        let hi_img = make_pattern_image(800, 600, [220, 140, 80]);
        let lo_jpg_bytes =
            MediaArtwork::encode_jpeg(&hi_img.resize_exact(400, 300, FilterType::Triangle), 76)
                .unwrap();
        let lo_img = image::load_from_memory(&lo_jpg_bytes).unwrap();
        let recolored_img = make_pattern_image(800, 600, [50, 120, 235]);
        let swatch_a =
            DynamicImage::ImageRgba8(RgbaImage::from_pixel(200, 200, Rgba([220, 40, 40, 255])));
        let swatch_b =
            DynamicImage::ImageRgba8(RgbaImage::from_pixel(200, 200, Rgba([40, 180, 90, 255])));

        let mut a_hi = AssetRecord::new("Hero High", "hero.png");
        a_hi.media_kind = MediaKind::Image;
        a_hi.mime_type = "image/png".to_string();
        a_hi.pixel_width = 800;
        a_hi.pixel_height = 600;
        a_hi.file_size_bytes = 640_000;
        a_hi.content_hash = "hash_hi".to_string();

        let mut a_lo = AssetRecord::new("Hero Low", "hero.jpg");
        a_lo.media_kind = MediaKind::Image;
        a_lo.mime_type = "image/jpeg".to_string();
        a_lo.pixel_width = 400;
        a_lo.pixel_height = 300;
        a_lo.file_size_bytes = 42_000;
        a_lo.content_hash = "hash_lo".to_string();

        let mut a_recolor = AssetRecord::new("Hero Blue", "hero_blue.png");
        a_recolor.media_kind = MediaKind::Image;
        a_recolor.pixel_width = 800;
        a_recolor.pixel_height = 600;
        a_recolor.file_size_bytes = 620_000;
        a_recolor.content_hash = "hash_blue".to_string();

        let mut a_sw_a = AssetRecord::new("Red Swatch", "red.png");
        a_sw_a.media_kind = MediaKind::Image;
        a_sw_a.pixel_width = 200;
        a_sw_a.pixel_height = 200;
        a_sw_a.content_hash = "hash_sw_a".to_string();

        let mut a_sw_b = AssetRecord::new("Green Swatch", "green.png");
        a_sw_b.media_kind = MediaKind::Image;
        a_sw_b.pixel_width = 200;
        a_sw_b.pixel_height = 200;
        a_sw_b.content_hash = "hash_sw_b".to_string();

        let items = vec![
            IndexedMediaAsset {
                asset: a_hi.clone(),
                fingerprint: SmartDeduplicator::compute_fingerprint(&hi_img, Some(800.0 / 600.0)),
                canonical_bookmark_key: None,
                normalized_text_hash: None,
            },
            IndexedMediaAsset {
                asset: a_lo.clone(),
                fingerprint: SmartDeduplicator::compute_fingerprint(&lo_img, Some(400.0 / 300.0)),
                canonical_bookmark_key: None,
                normalized_text_hash: None,
            },
            IndexedMediaAsset {
                asset: a_recolor,
                fingerprint: SmartDeduplicator::compute_fingerprint(
                    &recolored_img,
                    Some(800.0 / 600.0),
                ),
                canonical_bookmark_key: None,
                normalized_text_hash: None,
            },
            IndexedMediaAsset {
                asset: a_sw_a,
                fingerprint: SmartDeduplicator::compute_fingerprint(&swatch_a, Some(1.0)),
                canonical_bookmark_key: None,
                normalized_text_hash: None,
            },
            IndexedMediaAsset {
                asset: a_sw_b,
                fingerprint: SmartDeduplicator::compute_fingerprint(&swatch_b, Some(1.0)),
                canonical_bookmark_key: None,
                normalized_text_hash: None,
            },
        ];

        let groups = SmartDeduplicator::cluster_duplicates(
            &items,
            DeduplicationSensitivity::Balanced,
            &HashSet::new(),
        );
        assert_eq!(groups.len(), 1, "only hi/lo pair should cluster");
        assert_eq!(groups[0].recommended_keep_asset_id, a_hi.id);
        assert_eq!(groups[0].candidates.len(), 2);
    }

    #[test]
    fn isolates_design_psd_from_exported_png_and_clusters_audio_bookmarks_and_docs() {
        let img = make_pattern_image(400, 400, [180, 110, 90]);
        let fp = SmartDeduplicator::compute_fingerprint(&img, Some(1.0));

        // 1. PSD vs PNG with identical preview MUST stay isolated
        let mut psd = AssetRecord::new("Artwork", "artwork.psd");
        psd.media_kind = MediaKind::DesignFile;
        psd.content_hash = "h_psd".to_string();
        let mut png = AssetRecord::new("Artwork", "artwork.png");
        png.media_kind = MediaKind::Image;
        png.content_hash = "h_png".to_string();

        // 2. Audio FLAC vs MP3 with matching normalized waveform -> keeps FLAC
        let peaks: Vec<f32> = (0..48)
            .map(|i| ((i as f32 * 0.37).sin().abs() * 0.8 + 0.1).min(1.0))
            .collect();
        let mut flac = AssetRecord::new("Track", "track.flac");
        flac.media_kind = MediaKind::Audio;
        flac.duration_seconds = Some(120.0);
        flac.file_size_bytes = 28_000_000;
        flac.waveform_peaks = peaks.clone();
        flac.content_hash = "h_flac".to_string();

        let mut mp3 = AssetRecord::new("Track", "track.mp3");
        mp3.media_kind = MediaKind::Audio;
        mp3.duration_seconds = Some(120.2);
        mp3.file_size_bytes = 3_800_000;
        mp3.waveform_peaks = peaks.iter().map(|v| v * 0.92).collect();
        mp3.content_hash = "h_mp3".to_string();

        // 3. Duplicate web bookmarks differing only by tracking params
        let mut bm1 = AssetRecord::new("Article", "a.url");
        bm1.media_kind = MediaKind::WebBookmark;
        bm1.source_url = Some("https://www.pixiv.net/artworks/12556677?utm_source=x".to_string());
        bm1.file_size_bytes = 2000;
        bm1.content_hash = "h_bm1".to_string();

        let mut bm2 = AssetRecord::new("Article Copy", "b.url");
        bm2.media_kind = MediaKind::WebBookmark;
        bm2.source_url = Some("https://pixiv.net/en/artworks/12556677".to_string());
        bm2.file_size_bytes = 1200;
        bm2.content_hash = "h_bm2".to_string();

        // 4. Duplicate documents matching normalized text
        let text = "Charkle design studio reference guidelines for optical contrast and editorial balance across desktop displays.";
        let mut doc1 = AssetRecord::new("Notes", "notes.md");
        doc1.media_kind = MediaKind::Document;
        doc1.ocr_text = Some(text.to_string());
        doc1.file_size_bytes = 4096;
        doc1.content_hash = "h_doc1".to_string();

        let mut doc2 = AssetRecord::new("Notes Copy", "notes_copy.txt");
        doc2.media_kind = MediaKind::Document;
        doc2.ocr_text = Some(text.replace(' ', "   \n"));
        doc2.file_size_bytes = 2048;
        doc2.content_hash = "h_doc2".to_string();

        let items = vec![
            IndexedMediaAsset {
                asset: psd,
                fingerprint: fp.clone(),
                canonical_bookmark_key: None,
                normalized_text_hash: None,
            },
            IndexedMediaAsset {
                asset: png,
                fingerprint: fp,
                canonical_bookmark_key: None,
                normalized_text_hash: None,
            },
            IndexedMediaAsset {
                asset: flac.clone(),
                fingerprint: None,
                canonical_bookmark_key: None,
                normalized_text_hash: None,
            },
            IndexedMediaAsset {
                asset: mp3,
                fingerprint: None,
                canonical_bookmark_key: None,
                normalized_text_hash: None,
            },
            IndexedMediaAsset {
                canonical_bookmark_key: SmartDeduplicator::canonical_bookmark_key(&bm1),
                asset: bm1,
                fingerprint: None,
                normalized_text_hash: None,
            },
            IndexedMediaAsset {
                canonical_bookmark_key: SmartDeduplicator::canonical_bookmark_key(&bm2),
                asset: bm2,
                fingerprint: None,
                normalized_text_hash: None,
            },
            IndexedMediaAsset {
                normalized_text_hash: SmartDeduplicator::normalized_document_text_hash(&doc1, None),
                asset: doc1,
                fingerprint: None,
                canonical_bookmark_key: None,
            },
            IndexedMediaAsset {
                normalized_text_hash: SmartDeduplicator::normalized_document_text_hash(&doc2, None),
                asset: doc2,
                fingerprint: None,
                canonical_bookmark_key: None,
            },
        ];

        let groups = SmartDeduplicator::cluster_duplicates(
            &items,
            DeduplicationSensitivity::Balanced,
            &HashSet::new(),
        );
        // Should yield exactly 3 groups: Audio, WebBookmark, Document (PSD & PNG strictly isolated!)
        assert_eq!(groups.len(), 3);
        let audio_group = groups
            .iter()
            .find(|g| g.match_kind == DuplicateMatchKind::AudioWaveform)
            .expect("audio group");
        assert_eq!(audio_group.recommended_keep_asset_id, flac.id);
        assert!(groups
            .iter()
            .any(|g| g.match_kind == DuplicateMatchKind::CanonicalLink));
        assert!(groups
            .iter()
            .any(|g| g.match_kind == DuplicateMatchKind::NormalizedText));
    }
}
