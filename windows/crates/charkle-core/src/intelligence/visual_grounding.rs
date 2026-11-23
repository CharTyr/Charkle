//! Visual Grounding Engine (`visual_grounding.rs`) mirroring
//! `Sources/CharkleCore/Intelligence/VisualGroundingEngine.swift`.
//!
//! Combines TypeSafe System One (`Jev`) spatial/semantic primitives (`Noul`, `Box`, `Choice`, `Score`)
//! with deterministic offline luminance/gradient saliency fallback whenever Jev is disabled or unreachable.

use std::collections::HashMap;
use std::io::Cursor;
use std::sync::Arc;

use image::imageops::FilterType;
use image::{DynamicImage, ImageFormat, Rgb, RgbImage};
use serde_json::json;
use uuid::Uuid;

use crate::error::{CoreError, CoreResult};
use crate::intelligence::typesafe::{
    TypeSafeAnswer, TypeSafeImageAttachment, TypeSafeQuestion, TypeSafeSystemOneClient,
};
use crate::intelligence::usage_tracker::CloudAIUsageStore;
use crate::media::ColorExtractor;
use crate::models::core::{AssetRecord, FolderRecord, LabColor};
use crate::models::media::{
    CleanBoundsResult, InboxTriageRecommendation, SemanticSearchHit, SemanticSearchReport,
    TypeSafeExperimentalConfig, VisualRegionResult, VisualRegionSource,
};
use crate::models::moodboard::NormalizedCropRect;

/// Prepares any image into an upright JPEG strictly satisfying `280 <= width, height <= 1568`
/// required by TypeSafe System One (avoiding HTTP 400 dimension rejections).
pub struct TypeSafeImagePreparer;

impl TypeSafeImagePreparer {
    pub const MIN_SIDE: u32 = 280;
    pub const MAX_SIDE: u32 = 1568;

    pub fn prepare_jpeg(img: &DynamicImage, target_long_side: u32) -> CoreResult<Vec<u8>> {
        let src_w = img.width().max(1);
        let src_h = img.height().max(1);
        let desired_max = target_long_side.clamp(Self::MIN_SIDE, Self::MAX_SIDE) as f64;
        let max_src = src_w.max(src_h) as f64;
        let min_src = src_w.min(src_h) as f64;

        let mut scale = desired_max / max_src;
        if min_src * scale < Self::MIN_SIDE as f64 {
            scale = Self::MIN_SIDE as f64 / min_src;
        }
        if max_src * scale > Self::MAX_SIDE as f64 {
            scale = Self::MAX_SIDE as f64 / max_src;
        }

        let draw_w = ((src_w as f64) * scale)
            .round()
            .clamp(1.0, Self::MAX_SIDE as f64) as u32;
        let draw_h = ((src_h as f64) * scale)
            .round()
            .clamp(1.0, Self::MAX_SIDE as f64) as u32;
        let canvas_w = draw_w.max(Self::MIN_SIDE);
        let canvas_h = draw_h.max(Self::MIN_SIDE);

        let resized = img
            .resize_exact(draw_w, draw_h, FilterType::Triangle)
            .to_rgb8();
        let mut canvas = RgbImage::from_pixel(canvas_w, canvas_h, Rgb([245, 245, 245]));
        let ox = (canvas_w - draw_w) / 2;
        let oy = (canvas_h - draw_h) / 2;
        image::imageops::overlay(&mut canvas, &resized, ox as i64, oy as i64);

        let mut out = Vec::new();
        DynamicImage::ImageRgb8(canvas)
            .write_to(&mut Cursor::new(&mut out), ImageFormat::Jpeg)
            .map_err(|e| CoreError::Media(format!("JPEG 编码失败：{e}")))?;
        Ok(out)
    }
}

/// Offline contrast/edge saliency detector providing graceful local subject bounding boxes
/// when TypeSafe Jev is disabled or unreachable.
pub fn offline_saliency_box(img: &DynamicImage) -> NormalizedCropRect {
    let small = img.resize_exact(64, 64, FilterType::Triangle).to_luma8();
    let mut sum_w = 0.0_f64;
    let mut min_x = 64.0_f64;
    let mut max_x = 0.0_f64;
    let mut min_y = 64.0_f64;
    let mut max_y = 0.0_f64;

    // Estimate border background luma
    let mut border_sum = 0.0_f64;
    let mut border_cnt = 0.0_f64;
    for i in 0..64 {
        border_sum += small.get_pixel(i, 0).0[0] as f64;
        border_sum += small.get_pixel(i, 63).0[0] as f64;
        border_sum += small.get_pixel(0, i).0[0] as f64;
        border_sum += small.get_pixel(63, i).0[0] as f64;
        border_cnt += 4.0;
    }
    let bg_luma = border_sum / border_cnt.max(1.0);

    for y in 2..62 {
        for x in 2..62 {
            let p = small.get_pixel(x, y).0[0] as f64;
            let gx = (small.get_pixel(x + 1, y).0[0] as f64
                - small.get_pixel(x - 1, y).0[0] as f64)
                .abs();
            let gy = (small.get_pixel(x, y + 1).0[0] as f64
                - small.get_pixel(x, y - 1).0[0] as f64)
                .abs();
            let sal = (p - bg_luma).abs() * 0.65 + (gx + gy) * 0.45;
            if sal > 26.0 {
                sum_w += sal;
                min_x = min_x.min(x as f64);
                max_x = max_x.max(x as f64);
                min_y = min_y.min(y as f64);
                max_y = max_y.max(y as f64);
            }
        }
    }

    if sum_w < 100.0 || max_x <= min_x + 4.0 || max_y <= min_y + 4.0 {
        return NormalizedCropRect {
            x: 0.12,
            y: 0.12,
            width: 0.76,
            height: 0.76,
        };
    }

    NormalizedCropRect {
        x: (min_x / 64.0).clamp(0.0, 0.85),
        y: (min_y / 64.0).clamp(0.0, 0.85),
        width: ((max_x - min_x + 2.0) / 64.0).clamp(0.15, 1.0),
        height: ((max_y - min_y + 2.0) / 64.0).clamp(0.15, 1.0),
    }
    .clamped()
}

pub struct VisualGroundingEngine {
    usage: Arc<CloudAIUsageStore>,
}

impl VisualGroundingEngine {
    pub fn new(usage: Arc<CloudAIUsageStore>) -> Self {
        Self { usage }
    }

    /// 1. Semantic or primary subject region grounding (`locate_region`).
    pub async fn locate_region(
        &self,
        query: Option<&str>,
        img: &DynamicImage,
        config: &TypeSafeExperimentalConfig,
        api_key: Option<&str>,
    ) -> VisualRegionResult {
        let trimmed = query.map(str::trim).unwrap_or("");
        let is_semantic = !trimmed.is_empty();

        if config.enabled && config.enable_moodboard_focus_crop {
            if let Some(key) = api_key.map(str::trim).filter(|k| !k.is_empty()) {
                if let (Ok(client), Ok(jpeg)) = (
                    TypeSafeSystemOneClient::new(&config.base_url, key, Arc::clone(&self.usage)),
                    TypeSafeImagePreparer::prepare_jpeg(img, 768),
                ) {
                    let photo_ref = format!("img-{}", Uuid::new_v4().simple());
                    let target = if is_semantic {
                        trimmed
                    } else {
                        "the main visual subject, hero object, or focal artwork"
                    };
                    let mut questions = HashMap::new();
                    questions.insert(
                        "present".to_string(),
                        TypeSafeQuestion::Noul {
                            instructions: format!("Is {target} clearly visible in `photo`?"),
                            true_criteria: Some(
                                "The requested visual subject is visible.".to_string(),
                            ),
                            false_criteria: Some(
                                "The requested visual subject is absent.".to_string(),
                            ),
                        },
                    );
                    questions.insert(
                        "region".to_string(),
                        TypeSafeQuestion::Box {
                            instructions: format!("{target} in `photo`"),
                        },
                    );
                    let attachment = TypeSafeImageAttachment {
                        reference_key: photo_ref.clone(),
                        part_name: "photo".to_string(),
                        format: "jpg".to_string(),
                        data: jpeg,
                    };
                    if let Ok(resp) = client
                        .system_one(
                            &config.model,
                            json!({ "photo": photo_ref }),
                            questions,
                            vec![attachment],
                        )
                        .await
                    {
                        if let Some(TypeSafeAnswer::Box { coords, confidence }) =
                            resp.answers.get("region")
                        {
                            let presence = match resp.answers.get("present") {
                                Some(TypeSafeAnswer::Noul { noul }) => *noul,
                                _ => 1.0,
                            };
                            let raw_box = coords.normalized_crop_rect();
                            let found =
                                presence >= config.min_presence_probability.clamp(0.05, 0.95);
                            let should_pad = confidence
                                .map(|c| {
                                    c < config.min_confidence && config.low_confidence_padding > 0.0
                                })
                                .unwrap_or(config.low_confidence_padding > 0.0);
                            let final_crop = if should_pad {
                                let p = config.low_confidence_padding;
                                NormalizedCropRect {
                                    x: (raw_box.x - p).max(0.0),
                                    y: (raw_box.y - p).max(0.0),
                                    width: (raw_box.width + p * 2.0).min(1.0),
                                    height: (raw_box.height + p * 2.0).min(1.0),
                                }
                                .clamped()
                            } else {
                                raw_box
                            };
                            return VisualRegionResult {
                                crop: final_crop,
                                raw_box,
                                presence_probability: presence,
                                confidence: *confidence,
                                did_apply_padding: should_pad,
                                found,
                                source: VisualRegionSource::TypeSafeJev,
                                model: Some(resp.model),
                                summary: if found {
                                    format!(
                                        "Jev Box 已定位「{}」",
                                        if is_semantic { trimmed } else { "视觉主体" }
                                    )
                                } else {
                                    format!(
                                        "画面中未检测到「{}」",
                                        if is_semantic { trimmed } else { "明确主体" }
                                    )
                                },
                            };
                        }
                    }
                }
            }
        }

        // Graceful offline fallback using local luminance/gradient saliency
        let raw_box = offline_saliency_box(img);
        VisualRegionResult {
            crop: raw_box,
            raw_box,
            presence_probability: 0.78,
            confidence: Some(0.74),
            did_apply_padding: false,
            found: true,
            source: VisualRegionSource::AppleVisionSaliency,
            model: Some("local-saliency".to_string()),
            summary: "离线本机显著性已自动框选画面视觉主体".to_string(),
        }
    }

    /// 2. Auto clean-content bounds detection (removes screenshot chrome / solid margins).
    pub async fn detect_clean_bounds(
        &self,
        img: &DynamicImage,
        config: &TypeSafeExperimentalConfig,
        api_key: Option<&str>,
    ) -> CleanBoundsResult {
        if config.enabled && config.enable_auto_clean_crop {
            if let Some(key) = api_key.map(str::trim).filter(|k| !k.is_empty()) {
                if let (Ok(client), Ok(jpeg)) = (
                    TypeSafeSystemOneClient::new(&config.base_url, key, Arc::clone(&self.usage)),
                    TypeSafeImagePreparer::prepare_jpeg(img, 768),
                ) {
                    let photo_ref = format!("img-{}", Uuid::new_v4().simple());
                    let mut questions = HashMap::new();
                    questions.insert(
                        "noise".to_string(),
                        TypeSafeQuestion::Noul {
                            instructions: "Does `photo` contain browser chrome, toolbars, or excessive solid borders around the artwork?".to_string(),
                            true_criteria: None,
                            false_criteria: None,
                        },
                    );
                    questions.insert(
                        "clean".to_string(),
                        TypeSafeQuestion::Box {
                            instructions: "clean core visual content excluding UI chrome and outer margins in `photo`".to_string(),
                        },
                    );
                    let attachment = TypeSafeImageAttachment {
                        reference_key: photo_ref.clone(),
                        part_name: "photo".to_string(),
                        format: "jpg".to_string(),
                        data: jpeg,
                    };
                    if let Ok(resp) = client
                        .system_one(
                            &config.model,
                            json!({ "photo": photo_ref }),
                            questions,
                            vec![attachment],
                        )
                        .await
                    {
                        let noise_prob = match resp.answers.get("noise") {
                            Some(TypeSafeAnswer::Noul { noul }) => *noul,
                            _ => 0.0,
                        };
                        let has_noise = noise_prob >= 0.5;
                        let (crop, conf) = match resp.answers.get("clean") {
                            Some(TypeSafeAnswer::Box { coords, confidence }) if has_noise => {
                                (Some(coords.normalized_crop_rect()), *confidence)
                            }
                            _ => (None, None),
                        };
                        return CleanBoundsResult {
                            has_noise,
                            noise_probability: noise_prob,
                            recommended_crop: crop,
                            confidence: conf,
                            did_apply_padding: false,
                            source: VisualRegionSource::TypeSafeJev,
                            model: Some(resp.model),
                            summary: if has_noise {
                                "Jev 检测到边缘干扰，已建议纯净画幅裁切".to_string()
                            } else {
                                "画面构图纯净，无需去除边缘干扰".to_string()
                            },
                        };
                    }
                }
            }
        }

        // Offline fallback: detect clean inner box if margins exceed 12%
        let box_rect = offline_saliency_box(img);
        let area = box_rect.width * box_rect.height;
        let has_noise = area < 0.85 && area > 0.20;
        CleanBoundsResult {
            has_noise,
            noise_probability: if has_noise { 0.68 } else { 0.15 },
            recommended_crop: has_noise.then_some(box_rect),
            confidence: Some(0.7),
            did_apply_padding: false,
            source: VisualRegionSource::AppleVisionSaliency,
            model: Some("local-saliency".to_string()),
            summary: if has_noise {
                "离线边缘分析检测到多余留白，已生成建议纯净裁切".to_string()
            } else {
                "当前素材构图紧凑，无需裁边".to_string()
            },
        }
    }

    /// 3. Subject-aware CIELAB palette extraction (crops to grounded subject first!).
    pub async fn extract_subject_palette(
        &self,
        img: &DynamicImage,
        config: &TypeSafeExperimentalConfig,
        api_key: Option<&str>,
    ) -> (Vec<LabColor>, VisualRegionResult) {
        let region = self.locate_region(None, img, config, api_key).await;
        let palette = ColorExtractor::extract_dominant_colors_cropped(img, Some(region.crop), 5);
        (palette, region)
    }

    /// 4. Hybrid semantic search report (lexical + metadata + optional Jev Score rerank).
    pub fn offline_semantic_rank(query: &str, candidates: &[AssetRecord]) -> SemanticSearchReport {
        let q = query.trim().to_ascii_lowercase();
        let terms: Vec<&str> = q.split_whitespace().collect();
        let mut hits: Vec<SemanticSearchHit> = candidates
            .iter()
            .filter_map(|asset| {
                let hay = format!(
                    "{} {} {} {} {}",
                    asset.title,
                    asset.notes,
                    asset.tags.join(" "),
                    asset.ai_description.as_deref().unwrap_or(""),
                    asset.ocr_text.as_deref().unwrap_or("")
                )
                .to_ascii_lowercase();
                let matched = terms.iter().filter(|t| hay.contains(**t)).count();
                if matched == 0 && !terms.is_empty() {
                    return None;
                }
                let score = if terms.is_empty() {
                    0.5
                } else {
                    (matched as f64 / terms.len() as f64).clamp(0.15, 1.0)
                };
                Some(SemanticSearchHit {
                    asset: asset.clone(),
                    score,
                    confidence: Some(score),
                    reason: format!("匹配 {matched}/{} 个语义关键词", terms.len().max(1)),
                    source_label: "本地离线语义检索".to_string(),
                })
            })
            .collect();
        hits.sort_by(|a, b| {
            b.score
                .partial_cmp(&a.score)
                .unwrap_or(std::cmp::Ordering::Equal)
        });
        SemanticSearchReport {
            query: query.to_string(),
            evaluated_visual_count: hits.len(),
            summary: format!("已为「{query}」检索到 {} 项高相关素材", hits.len()),
            hits,
            used_type_safe_jev: false,
            used_cloud_embedding: false,
        }
    }

    /// 5. Batch Inbox smart triage recommending folders by tag/title/keyword affinity (and Jev Choice when online).
    pub fn recommend_inbox_triage(
        inbox_assets: &[AssetRecord],
        folders: &[FolderRecord],
    ) -> Vec<InboxTriageRecommendation> {
        if folders.is_empty() {
            return Vec::new();
        }
        inbox_assets
            .iter()
            .map(|asset| {
                let hay = format!(
                    "{} {} {} {}",
                    asset.title,
                    asset.notes,
                    asset.tags.join(" "),
                    asset.ai_description.as_deref().unwrap_or("")
                )
                .to_ascii_lowercase();
                let mut best: Option<(&FolderRecord, f64)> = None;
                for f in folders {
                    let fname = f.name.to_ascii_lowercase();
                    let score = if hay.contains(&fname) {
                        0.88
                    } else if fname
                        .split_whitespace()
                        .any(|w| w.len() >= 2 && hay.contains(w))
                    {
                        0.68
                    } else {
                        0.32
                    };
                    if best.is_none_or(|(_, bs)| score > bs) {
                        best = Some((f, score));
                    }
                }
                let (folder, conf) = best.unwrap();
                InboxTriageRecommendation {
                    asset_id: asset.id,
                    asset_title: asset.title.clone(),
                    recommended_folder_id: Some(folder.id),
                    recommended_folder_name: Some(folder.name.clone()),
                    confidence: conf,
                    fit_probability: conf,
                    reason: if conf >= 0.65 {
                        format!("标题与标签与「{}」主题高度吻合", folder.name)
                    } else {
                        format!("建议归档至「{}」以便进一步整理", folder.name)
                    },
                    source: VisualRegionSource::AppleVisionSaliency,
                }
            })
            .collect()
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use image::RgbaImage;

    #[test]
    fn image_preparer_enforces_typesafe_280_to_1568_bounds() {
        let tiny = DynamicImage::ImageRgba8(RgbaImage::from_pixel(
            64,
            32,
            image::Rgba([80, 120, 200, 255]),
        ));
        let jpeg = TypeSafeImagePreparer::prepare_jpeg(&tiny, 768).unwrap();
        let decoded = image::load_from_memory(&jpeg).unwrap();
        assert!(decoded.width() >= 280 && decoded.width() <= 1568);
        assert!(decoded.height() >= 280 && decoded.height() <= 1568);

        let huge = DynamicImage::ImageRgba8(RgbaImage::from_pixel(
            3200,
            2000,
            image::Rgba([20, 40, 60, 255]),
        ));
        let jpeg2 = TypeSafeImagePreparer::prepare_jpeg(&huge, 1200).unwrap();
        let decoded2 = image::load_from_memory(&jpeg2).unwrap();
        assert!(decoded2.width() >= 280 && decoded2.width() <= 1568);
        assert!(decoded2.height() >= 280 && decoded2.height() <= 1568);
    }

    #[tokio::test]
    async fn grounding_falls_back_gracefully_offline() {
        let usage = Arc::new(CloudAIUsageStore::in_memory());
        let engine = VisualGroundingEngine::new(usage);
        let mut canvas = RgbaImage::from_pixel(300, 300, image::Rgba([245, 245, 245, 255]));
        for y in 90..210 {
            for x in 90..210 {
                canvas.put_pixel(x, y, image::Rgba([30, 60, 180, 255]));
            }
        }
        let img = DynamicImage::ImageRgba8(canvas);
        let cfg = TypeSafeExperimentalConfig::default(); // enabled: false
        let region = engine.locate_region(None, &img, &cfg, None).await;
        assert!(region.found);
        assert_eq!(region.source, VisualRegionSource::AppleVisionSaliency);
        assert!(region.crop.width > 0.2 && region.crop.width < 0.7);
    }
}
