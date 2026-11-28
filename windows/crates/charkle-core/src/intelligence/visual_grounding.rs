//! Visual Grounding Engine (`visual_grounding.rs`) mirroring
//! `Sources/CharkleCore/Intelligence/VisualGroundingEngine.swift`.
//!
//! Combines TypeSafe System One (`Jev`) spatial/semantic primitives (`Noul`, `Box`, `Choice`, `Score`)
//! with deterministic offline luminance/gradient saliency fallback whenever Jev is disabled or unreachable.

use std::collections::{HashMap, HashSet};
use std::io::Cursor;
use std::sync::Arc;

use image::imageops::FilterType;
use image::{DynamicImage, ImageFormat, Rgb, RgbImage};
use serde_json::{json, Value};
use uuid::Uuid;

use crate::db::search_text;
use crate::error::{CoreError, CoreResult};
use crate::intelligence::cloud_ai::CloudAIProvider;
use crate::intelligence::typesafe::{
    TypeSafeAnswer, TypeSafeImageAttachment, TypeSafeQuestion, TypeSafeSystemOneClient,
};
use crate::intelligence::usage_tracker::CloudAIUsageStore;
use crate::media::{ColorExtractor, LocalVisualDescriptor};
use crate::models::agent::LibraryTaxonomyPolicy;
use crate::models::core::{AssetRecord, FolderRecord, LabColor};
use crate::models::media::{
    cosine_similarity, AssetVector, CleanBoundsResult, ClosedSetTagMatch, ClosedSetTagOption,
    ClosedSetTaggingResult, InboxTriageRecommendation, SemanticSearchHit, SemanticSearchReport,
    TypeSafeExperimentalConfig, VisualRegionResult, VisualRegionSource,
};
use crate::models::moodboard::NormalizedCropRect;

/// Closed-set candidate folder metadata fed into visual & cloud AI Inbox Smart Triage.
#[derive(Debug, Clone)]
pub struct FolderOptionInput {
    pub id: Uuid,
    pub name: String,
    pub display_path: String,
    pub sample_tags: Vec<String>,
    pub sample_titles: Vec<String>,
}

/// Structured output of a single-asset closed-set folder classification call.
#[derive(Debug, Clone)]
pub struct FolderClassificationResult {
    pub folder_id: Option<Uuid>,
    pub confidence: f64,
    pub fit_probability: f64,
    pub reason: String,
    pub source: VisualRegionSource,
}

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

    /// Internal Jev subject/semantic Box + Noul grounding call (callers enforce their own Phase 1 feature gate).
    async fn locate_region_via_jev(
        &self,
        query: Option<&str>,
        img: &DynamicImage,
        config: &TypeSafeExperimentalConfig,
        api_key: Option<&str>,
    ) -> Option<VisualRegionResult> {
        let trimmed = query.map(str::trim).unwrap_or("");
        let is_semantic = !trimmed.is_empty();
        let key = api_key.map(str::trim).filter(|k| !k.is_empty())?;
        let client =
            TypeSafeSystemOneClient::new(&config.base_url, key, Arc::clone(&self.usage)).ok()?;
        let jpeg = TypeSafeImagePreparer::prepare_jpeg(img, 768).ok()?;

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
                true_criteria: Some("The requested visual subject is visible.".to_string()),
                false_criteria: Some("The requested visual subject is absent.".to_string()),
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
        let resp = client
            .system_one(
                &config.model,
                json!({ "photo": photo_ref }),
                questions,
                vec![attachment],
            )
            .await
            .ok()?;

        let TypeSafeAnswer::Box { coords, confidence } = resp.answers.get("region")? else {
            return None;
        };
        let presence = match resp.answers.get("present") {
            Some(TypeSafeAnswer::Noul { noul }) => *noul,
            _ => 1.0,
        };
        let raw_box = coords.normalized_crop_rect();
        let found = presence >= config.min_presence_probability.clamp(0.05, 0.95);
        let should_pad = confidence
            .map(|c| c < config.min_confidence && config.low_confidence_padding > 0.0)
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
        Some(VisualRegionResult {
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
        })
    }

    fn offline_region_fallback(img: &DynamicImage) -> VisualRegionResult {
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

    /// 1. Semantic or primary subject region grounding (`locate_region`).
    ///
    /// Runtime Phase 1 gate: requires `config.enabled && (config.enable_moodboard_focus_crop || config.enable_pinpoint_annotations)`.
    pub async fn locate_region(
        &self,
        query: Option<&str>,
        img: &DynamicImage,
        config: &TypeSafeExperimentalConfig,
        api_key: Option<&str>,
    ) -> VisualRegionResult {
        if config.enabled
            && (config.enable_moodboard_focus_crop || config.enable_pinpoint_annotations)
        {
            if let Some(hit) = self
                .locate_region_via_jev(query, img, config, api_key)
                .await
            {
                return hit;
            }
        }
        Self::offline_region_fallback(img)
    }

    /// 1b. Moodboard visual match / detail focus crop grounding (`locate_visual_match`).
    ///
    /// Runtime Phase 1 gate: strictly requires `config.enabled && config.enable_moodboard_focus_crop`.
    pub async fn locate_visual_match(
        &self,
        query: &str,
        img: &DynamicImage,
        config: &TypeSafeExperimentalConfig,
        api_key: Option<&str>,
    ) -> VisualRegionResult {
        if config.enabled && config.enable_moodboard_focus_crop {
            if let Some(hit) = self
                .locate_region_via_jev(Some(query), img, config, api_key)
                .await
            {
                return hit;
            }
        }
        Self::offline_region_fallback(img)
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
    ///
    /// Runtime Phase 1 gate: strictly requires `config.enabled && config.enable_subject_palette`;
    /// falls back to offline saliency directly with zero HTTP calls when disabled.
    pub async fn extract_subject_palette(
        &self,
        img: &DynamicImage,
        config: &TypeSafeExperimentalConfig,
        api_key: Option<&str>,
    ) -> (Vec<LabColor>, VisualRegionResult) {
        let region = if config.enabled && config.enable_subject_palette {
            self.locate_region_via_jev(None, img, config, api_key)
                .await
                .unwrap_or_else(|| Self::offline_region_fallback(img))
        } else {
            Self::offline_region_fallback(img)
        };
        let palette = ColorExtractor::extract_dominant_colors_cropped(img, Some(region.crop), 5);
        (palette, region)
    }

    /// 3b. Visual rerank scoring for semantic search or moodboard curator candidate pools.
    ///
    /// Runtime Phase 2 gate: requires `config.enabled && (config.enable_semantic_search || config.enable_curator_visual_rerank)`.
    pub async fn score_candidates_for_query(
        &self,
        query: &str,
        candidates: &[(Uuid, Vec<u8>)],
        config: &TypeSafeExperimentalConfig,
        api_key: Option<&str>,
    ) -> HashMap<Uuid, f64> {
        let trimmed = query.trim();
        if trimmed.is_empty()
            || candidates.is_empty()
            || !config.enabled
            || !(config.enable_semantic_search || config.enable_curator_visual_rerank)
        {
            return HashMap::new();
        }
        let Some(key) = api_key.map(str::trim).filter(|k| !k.is_empty()) else {
            return HashMap::new();
        };
        let Ok(client) =
            TypeSafeSystemOneClient::new(&config.base_url, key, Arc::clone(&self.usage))
        else {
            return HashMap::new();
        };

        let mut scores = HashMap::new();
        for (asset_id, jpeg) in candidates.iter().take(16) {
            if jpeg.is_empty() {
                continue;
            }
            let photo_ref = format!("cand-{}", Uuid::new_v4().simple());
            let mut questions = HashMap::new();
            questions.insert(
                "fit".to_string(),
                TypeSafeQuestion::Noul {
                    instructions: format!(
                        "Does `photo` visually match the design query \"{trimmed}\"?"
                    ),
                    true_criteria: None,
                    false_criteria: None,
                },
            );
            let attachment = TypeSafeImageAttachment {
                reference_key: photo_ref.clone(),
                part_name: "photo".to_string(),
                format: "jpg".to_string(),
                data: jpeg.clone(),
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
                if let Some(TypeSafeAnswer::Noul { noul }) = resp.answers.get("fit") {
                    if noul.is_finite() {
                        scores.insert(*asset_id, noul.clamp(0.0, 1.0));
                    }
                }
            }
        }
        scores
    }

    /// 6. Zero-Hallucination Closed-Set Multi-`Noul` Tag Classifier (`classify_closed_set_tags`).
    ///
    /// Evaluates up to `max_candidate_tags` (default 20) canonical library tags in a **single**
    /// `POST /v1/systemone` multipart request (1 image upload, lean prompts with no verbose
    /// `criteria` block). Every returned tag is strictly intersected against `candidate_tags`
    /// and split by dual calibrated thresholds (`confirmed_tags` vs `suggested_tags`).
    #[allow(clippy::too_many_arguments)]
    pub async fn classify_closed_set_tags(
        &self,
        asset_title: &str,
        existing_tags: &[String],
        asset_notes: &str,
        image_jpeg: Option<&[u8]>,
        candidate_tags: &[ClosedSetTagOption],
        config: &TypeSafeExperimentalConfig,
        api_key: Option<&str>,
        max_candidate_tags: usize,
        max_confirmed_tags: usize,
        max_suggested_tags: usize,
    ) -> CoreResult<ClosedSetTaggingResult> {
        let key = match api_key.map(str::trim).filter(|k| !k.is_empty()) {
            Some(k) if config.enabled && config.enable_closed_set_tagging => k,
            _ => return Ok(ClosedSetTaggingResult::default()),
        };

        let existing_norm: HashSet<String> = existing_tags
            .iter()
            .map(|t| search_text::normalize(t))
            .filter(|s| !s.is_empty())
            .collect();
        let cap = max_candidate_tags.clamp(1, 32);
        let mut deduped_norm = HashSet::new();
        let mut capped_candidates: Vec<ClosedSetTagOption> =
            Vec::with_capacity(candidate_tags.len().min(cap));
        for option in candidate_tags {
            let trimmed = option.name.trim();
            if trimmed.is_empty() {
                continue;
            }
            let norm = search_text::normalize(trimmed);
            if norm.is_empty() || existing_norm.contains(&norm) || !deduped_norm.insert(norm) {
                continue;
            }
            capped_candidates.push(ClosedSetTagOption {
                name: trimmed.to_string(),
                aliases: option.aliases.clone(),
                context_hints: option.context_hints.clone(),
            });
            if capped_candidates.len() >= cap {
                break;
            }
        }
        if capped_candidates.is_empty() {
            return Ok(ClosedSetTaggingResult::default());
        }

        let client = TypeSafeSystemOneClient::new(&config.base_url, key, Arc::clone(&self.usage))?;

        let mut state = json!({
            "title": asset_title.chars().take(80).collect::<String>()
        });
        if !existing_tags.is_empty() {
            state["tags"] = json!(existing_tags.iter().take(8).cloned().collect::<Vec<_>>());
        }
        let trimmed_notes = asset_notes.trim();
        if !trimmed_notes.is_empty() {
            state["notes"] = json!(trimmed_notes.chars().take(140).collect::<String>());
        }

        let mut attachments = Vec::new();
        let has_image = image_jpeg.is_some_and(|b| !b.is_empty());
        if let Some(jpeg) = image_jpeg.filter(|b| !b.is_empty()) {
            let photo_ref = format!("tagimg-{}", Uuid::new_v4().simple());
            state["photo"] = json!(photo_ref);
            attachments.push(TypeSafeImageAttachment {
                reference_key: photo_ref,
                part_name: "photo".to_string(),
                format: "jpg".to_string(),
                data: jpeg.to_vec(),
            });
        }

        let subject = if has_image { "`photo`" } else { "this asset" };
        let mut questions = HashMap::with_capacity(capped_candidates.len());
        let mut key_to_tag_name: HashMap<String, String> =
            HashMap::with_capacity(capped_candidates.len());

        for (idx, option) in capped_candidates.iter().enumerate() {
            let key_name = format!("t_{idx}");
            key_to_tag_name.insert(key_name.clone(), option.name.clone());

            let mut hint_parts: Vec<&str> = Vec::with_capacity(4);
            for alias in option.aliases.iter().take(2) {
                let clean = alias.trim();
                if !clean.is_empty() {
                    hint_parts.push(clean);
                }
            }
            for hint in option.context_hints.iter().take(2) {
                let clean = hint.trim();
                if !clean.is_empty() {
                    hint_parts.push(clean);
                }
            }
            let context_clause = if hint_parts.is_empty() {
                String::new()
            } else {
                format!(" ({})", hint_parts.join("/"))
            };

            // Lean prompt: deliberately omit verbose true/false `criteria` to keep per-asset
            // token footprint around ~1.2-1.8k tokens for up to 20 parallel Noul tags.
            questions.insert(
                key_name,
                TypeSafeQuestion::Noul {
                    instructions: format!(
                        "Does {subject} fit tag \"{}\"{context_clause}?",
                        option.name
                    ),
                    true_criteria: None,
                    false_criteria: None,
                },
            );
        }

        let response = client
            .system_one(&config.model, state, questions, attachments)
            .await?;

        let sanitized = config.clone().sanitized();
        let high_threshold = sanitized.high_confidence_tag_threshold;
        let suggested_threshold = sanitized.suggested_tag_threshold;

        let mut confirmed: Vec<ClosedSetTagMatch> = Vec::new();
        let mut suggested: Vec<ClosedSetTagMatch> = Vec::new();
        for (key_name, tag_name) in &key_to_tag_name {
            let Some(TypeSafeAnswer::Noul { noul }) = response.answers.get(key_name) else {
                continue;
            };
            if !noul.is_finite() {
                continue;
            }
            let prob = noul.clamp(0.0, 1.0);
            if prob >= high_threshold {
                confirmed.push(ClosedSetTagMatch {
                    tag: tag_name.clone(),
                    probability: prob,
                });
            } else if prob >= suggested_threshold {
                suggested.push(ClosedSetTagMatch {
                    tag: tag_name.clone(),
                    probability: prob,
                });
            }
        }

        let sort_matches = |items: &mut Vec<ClosedSetTagMatch>| {
            items.sort_by(|lhs, rhs| {
                if (lhs.probability - rhs.probability).abs() > 0.001 {
                    rhs.probability
                        .partial_cmp(&lhs.probability)
                        .unwrap_or(std::cmp::Ordering::Equal)
                } else {
                    lhs.tag.cmp(&rhs.tag)
                }
            });
        };
        sort_matches(&mut confirmed);
        sort_matches(&mut suggested);
        confirmed.truncate(max_confirmed_tags.max(1));
        suggested.truncate(max_suggested_tags.max(1));

        Ok(ClosedSetTaggingResult {
            confirmed_tags: confirmed,
            suggested_tags: suggested,
            evaluated_tag_count: capped_candidates.len(),
            model: if response.model.is_empty() {
                None
            } else {
                Some(response.model)
            },
        })
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

    /// 5. Closed-set Inbox Folder Classification via TypeSafe System One (`Choice` + companion `Noul`).
    ///
    /// Mirrors `VisualGroundingEngine.swift:classifyIntoFolders`: prevents hallucinated folder names
    /// and abstains (`folder_id: None`) when `fits_any` probability is below `min_presence_probability`.
    #[allow(clippy::too_many_arguments)]
    pub async fn classify_into_folders(
        &self,
        asset_title: &str,
        asset_tags: &[String],
        asset_notes: &str,
        image_jpeg: Option<&[u8]>,
        folders: &[FolderOptionInput],
        config: &TypeSafeExperimentalConfig,
        api_key: &str,
    ) -> CoreResult<FolderClassificationResult> {
        if folders.is_empty() {
            return Ok(FolderClassificationResult {
                folder_id: None,
                confidence: 0.0,
                fit_probability: 0.0,
                reason: "素材库暂无目标文件夹".to_string(),
                source: VisualRegionSource::TypeSafeJev,
            });
        }
        let key = api_key.trim();
        if !config.enabled || key.is_empty() {
            return Err(CoreError::InvalidOperation(
                "Inbox 智能分拣需要开启 TypeSafe (Jev) 实验档并配置 API 密钥。".to_string(),
            ));
        }

        let client = TypeSafeSystemOneClient::new(&config.base_url, key, Arc::clone(&self.usage))?;
        let capped = &folders[..folders.len().min(32)];

        let mut criteria = HashMap::new();
        let mut by_key: HashMap<String, &FolderOptionInput> = HashMap::new();
        for (idx, folder) in capped.iter().enumerate() {
            let option_key = format!("f_{idx}");
            by_key.insert(option_key.clone(), folder);
            let tags_hint = if folder.sample_tags.is_empty() {
                String::new()
            } else {
                format!(
                    " (typical themes/tags: {})",
                    folder
                        .sample_tags
                        .iter()
                        .take(6)
                        .cloned()
                        .collect::<Vec<_>>()
                        .join(", ")
                )
            };
            criteria.insert(
                option_key,
                format!("Folder \"{}\"{tags_hint}", folder.display_path),
            );
        }

        let mut state = json!({
            "title": asset_title.chars().take(120).collect::<String>(),
            "tags": asset_tags.iter().take(10).cloned().collect::<Vec<_>>(),
            "notes": asset_notes.chars().take(240).collect::<String>(),
        });
        let mut attachments = Vec::new();
        if let Some(jpeg) = image_jpeg.filter(|b| !b.is_empty()) {
            let photo_ref = format!("inbox-{}", Uuid::new_v4().simple());
            state["photo"] = json!(photo_ref);
            attachments.push(TypeSafeImageAttachment {
                reference_key: photo_ref,
                part_name: "inbox_photo".to_string(),
                format: "jpg".to_string(),
                data: jpeg.to_vec(),
            });
        }

        let folder_names_list = capped
            .iter()
            .map(|f| f.display_path.as_str())
            .collect::<Vec<_>>()
            .join(", ");
        let target_desc = if attachments.is_empty() {
            "this design asset's metadata"
        } else {
            "`photo` and its metadata"
        };

        let mut questions = HashMap::new();
        questions.insert(
            "fits_any".to_string(),
            TypeSafeQuestion::Noul {
                instructions: format!(
                    "Does {target_desc} clearly belong in one of these design reference folders ({folder_names_list})?"
                ),
                true_criteria: Some(
                    "The visual subject, medium, or design style clearly matches at least one listed folder."
                        .to_string(),
                ),
                false_criteria: Some(
                    "None of the listed folders fit well; it should stay uncategorized in Inbox."
                        .to_string(),
                ),
            },
        );
        questions.insert(
            "folder".to_string(),
            TypeSafeQuestion::Choice {
                instructions: format!("Which folder best fits {target_desc}?"),
                criteria,
            },
        );

        let resp = client
            .system_one(&config.model, state, questions, attachments)
            .await?;

        let raw_fit = match resp.answers.get("fits_any") {
            Some(TypeSafeAnswer::Noul { noul }) if noul.is_finite() => noul.clamp(0.0, 1.0),
            _ => 0.5,
        };

        let (chosen, effective_conf) = match resp.answers.get("folder") {
            Some(TypeSafeAnswer::Choice {
                choice,
                confidence,
                probabilities,
            }) => {
                let Some(&folder) = by_key.get(choice) else {
                    return Ok(FolderClassificationResult {
                        folder_id: None,
                        confidence: 0.0,
                        fit_probability: raw_fit,
                        reason: "未能确定合适目录，建议暂留收件箱".to_string(),
                        source: VisualRegionSource::TypeSafeJev,
                    });
                };
                let top_prob = probabilities
                    .get(choice)
                    .copied()
                    .filter(|v| v.is_finite())
                    .unwrap_or(raw_fit)
                    .clamp(0.0, 1.0);
                let conf = confidence
                    .filter(|v| v.is_finite())
                    .unwrap_or(top_prob)
                    .clamp(0.0, 1.0);
                (folder, conf)
            }
            _ => {
                return Ok(FolderClassificationResult {
                    folder_id: None,
                    confidence: 0.0,
                    fit_probability: raw_fit,
                    reason: "未能确定合适目录，建议暂留收件箱".to_string(),
                    source: VisualRegionSource::TypeSafeJev,
                });
            }
        };

        let min_fit = if config.min_presence_probability.is_finite() {
            config.min_presence_probability.clamp(0.35, 0.85)
        } else {
            0.5
        };
        if raw_fit < min_fit {
            return Ok(FolderClassificationResult {
                folder_id: None,
                confidence: effective_conf,
                fit_probability: raw_fit,
                reason: format!(
                    "匹配度偏低（{}%），建议暂留收件箱（最接近：{}）",
                    (raw_fit * 100.0).round() as i32,
                    chosen.name
                ),
                source: VisualRegionSource::TypeSafeJev,
            });
        }

        Ok(FolderClassificationResult {
            folder_id: Some(chosen.id),
            confidence: effective_conf,
            fit_probability: raw_fit,
            reason: format!(
                "Jev 视觉归类（匹配度 {}% · 置信度 {}%）",
                (raw_fit * 100.0).round() as i32,
                (effective_conf * 100.0).round() as i32
            ),
            source: VisualRegionSource::TypeSafeJev,
        })
    }

    /// Closed-set Inbox Folder Classification via any configured Cloud AI provider
    /// (Gemini, OpenAI Compatible, Anthropic Messages, or ChatGPT Subscription).
    ///
    /// Inspects the prepared thumbnail JPEG (when `send_thumbnails_to_cloud` is enabled on the provider)
    /// alongside asset metadata and existing folder examples, and abstains honestly when no folder fits.
    pub async fn classify_into_folders_cloud_ai(
        provider: &dyn CloudAIProvider,
        asset: &AssetRecord,
        image_jpeg: Option<&[u8]>,
        folders: &[FolderOptionInput],
    ) -> CoreResult<FolderClassificationResult> {
        if folders.is_empty() {
            return Ok(FolderClassificationResult {
                folder_id: None,
                confidence: 0.0,
                fit_probability: 0.0,
                reason: "素材库暂无目标文件夹".to_string(),
                source: VisualRegionSource::AppleVisionSaliency,
            });
        }

        let capped = &folders[..folders.len().min(32)];
        let mut by_key: HashMap<String, &FolderOptionInput> = HashMap::new();
        let mut folder_lines = Vec::with_capacity(capped.len());
        for (idx, folder) in capped.iter().enumerate() {
            let key = format!("f_{idx}");
            by_key.insert(key.clone(), folder);
            let mut details = Vec::new();
            if !folder.sample_tags.is_empty() {
                details.push(format!(
                    "常见标签: {}",
                    folder
                        .sample_tags
                        .iter()
                        .take(6)
                        .cloned()
                        .collect::<Vec<_>>()
                        .join("、")
                ));
            }
            if !folder.sample_titles.is_empty() {
                details.push(format!(
                    "示例素材: {}",
                    folder
                        .sample_titles
                        .iter()
                        .take(4)
                        .cloned()
                        .collect::<Vec<_>>()
                        .join("、")
                ));
            }
            let suffix = if details.is_empty() {
                String::new()
            } else {
                format!("（{}）", details.join("；"))
            };
            folder_lines.push(format!("- {key}: \"{}\"{suffix}", folder.display_path));
        }

        let palette_hex: Vec<String> = asset
            .dominant_colors
            .iter()
            .take(4)
            .map(|c| c.hex.to_uppercase())
            .collect();
        let combined_tags: Vec<String> = asset
            .tags
            .iter()
            .chain(asset.suggested_tags.iter())
            .take(12)
            .cloned()
            .collect();

        let instructions = concat!(
            "You are a careful visual reference librarian for Charkle. ",
            "Decide whether the given asset clearly belongs in ONE of the listed existing folders. ",
            "NEVER force a bad match: if none of the folders clearly fits the asset's visual subject, design medium, or theme, set fits_any to false and folder_key to null. ",
            "Return ONLY valid JSON with exact keys: ",
            "{\"fits_any\": boolean, \"folder_key\": \"f_0\" | null, \"confidence\": 0.0..1.0, \"reason\": \"1 concise Chinese sentence explaining why\"}."
        );

        let prompt = format!(
            "Existing folders (closed set — choose ONLY a listed folder_key or null):\n{}\n\nAsset to classify:\n- title: {}\n- fileName: {}\n- mediaKind: {:?}\n- tags: {}\n- notes: {}\n- aiDescription: {}\n- ocrText: {}\n- dominantColors: {}\n{}",
            folder_lines.join("\n"),
            asset.title.chars().take(120).collect::<String>(),
            asset.file_name.chars().take(100).collect::<String>(),
            asset.media_kind,
            if combined_tags.is_empty() {
                "(none)".to_string()
            } else {
                combined_tags.join(", ")
            },
            asset.notes.chars().take(200).collect::<String>(),
            asset
                .ai_description
                .as_deref()
                .unwrap_or("")
                .chars()
                .take(240)
                .collect::<String>(),
            asset
                .ocr_text
                .as_deref()
                .unwrap_or("")
                .chars()
                .take(200)
                .collect::<String>(),
            if palette_hex.is_empty() {
                "(none)".to_string()
            } else {
                palette_hex.join(", ")
            },
            if image_jpeg.is_some() {
                "An image preview of this asset is attached. Base your judgment primarily on what you see in the image."
            } else {
                "No image preview is attached; judge strictly from the metadata above."
            }
        );

        let images = image_jpeg
            .filter(|b| !b.is_empty())
            .map(|b| vec![b.to_vec()])
            .unwrap_or_default();

        let raw = provider
            .complete_json(instructions, &prompt, &images)
            .await?;
        let parsed = parse_cloud_triage_json(&raw, &by_key, provider.provider_label());
        Ok(parsed)
    }

    /// Lightweight standalone keyword triage (honestly abstains with `None` when nothing matches;
    /// full desktop Inbox Triage runs through `LiveCharkleEngine::suggest_folders_for_assets` plus
    /// TypeSafe Jev / Cloud AI when configured).
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
                    "{} {} {} {} {}",
                    asset.title,
                    asset.notes,
                    asset.tags.join(" "),
                    asset.suggested_tags.join(" "),
                    asset.ai_description.as_deref().unwrap_or("")
                )
                .to_lowercase();
                let hay_words = ascii_word_set(&hay);

                let mut best: Option<(&FolderRecord, f64)> = None;
                for f in folders {
                    let fname = f.name.trim().to_lowercase();
                    if fname.is_empty() {
                        continue;
                    }
                    let f_words = ascii_word_set(&fname);
                    let score = if !fname.is_ascii() && hay.contains(&fname) {
                        0.88
                    } else if !f_words.is_empty() && f_words.iter().all(|w| hay_words.contains(w)) {
                        0.86
                    } else if !f_words.is_empty()
                        && f_words.iter().any(|w| {
                            (w.len() >= 3 || w == "ui" || w == "ux" || w == "3d")
                                && hay_words.contains(w)
                        })
                    {
                        0.66
                    } else {
                        0.0
                    };
                    if score > 0.0 && best.is_none_or(|(_, bs)| score > bs) {
                        best = Some((f, score));
                    }
                }

                if let Some((folder, conf)) = best {
                    InboxTriageRecommendation {
                        asset_id: asset.id,
                        asset_title: asset.title.clone(),
                        recommended_folder_id: Some(folder.id),
                        recommended_folder_name: Some(folder.name.clone()),
                        confidence: conf,
                        fit_probability: conf,
                        reason: format!("标题或标签与目录「{}」主题吻合", folder.name),
                        source: VisualRegionSource::AppleVisionSaliency,
                    }
                } else {
                    InboxTriageRecommendation {
                        asset_id: asset.id,
                        asset_title: asset.title.clone(),
                        recommended_folder_id: None,
                        recommended_folder_name: None,
                        confidence: 0.0,
                        fit_probability: 0.0,
                        reason: "离线未匹配到明确目录，建议暂留收件箱".to_string(),
                        source: VisualRegionSource::AppleVisionSaliency,
                    }
                }
            })
            .collect()
    }
}

// =============================================================================
// Two-Stage Local Candidate Funnel (mirrors ClosedSetTagFunnel.swift)
// =============================================================================

/// Builds a bounded, noise-filtered closed-set tag checklist (`<= 20` canonical tags) for any asset
/// using zero-cost local signals before sending a single TypeSafe System One (`Jev`) multi-`Noul` request:
///
/// 1. **Taxonomy & Singleton Hygiene**: Folds `LibraryTaxonomyPolicy.tag_aliases` into canonical tags
///    and filters one-off singleton noise (`count == 1`) once a library has `>= 12` repeated tags.
/// 2. **Visual Neighbor Funnel**: Uses cached `LocalVisualDescriptor` & `AssetVector` similarity
///    to surface tags from visually similar assets (up to 50% / 10 slots).
/// 3. **Folder Prior + Global Backbone**: Combines current (`1.0x`) + parent (`0.45x`) folder tag
///    frequencies (up to 35% / 7 slots) with highest-frequency global canonical tags.
pub struct ClosedSetTagFunnel {
    alias_norm_to_canonical_norm: HashMap<String, String>,
    canonical_spelling: HashMap<String, String>,
    aliases_by_canonical_norm: HashMap<String, Vec<String>>,
    context_hints_by_canonical_norm: HashMap<String, Vec<String>>,
    eligible_sorted_by_frequency: Vec<String>,
    folder_parent_by_id: HashMap<Uuid, Uuid>,
    folder_tag_counts: HashMap<Uuid, HashMap<String, usize>>,
    asset_canonical_eligible_tags: HashMap<Uuid, Vec<String>>,
    descriptors: HashMap<Uuid, LocalVisualDescriptor>,
    vectors: HashMap<Uuid, AssetVector>,
}

impl ClosedSetTagFunnel {
    pub fn new(
        active_assets: &[AssetRecord],
        folders: &[FolderRecord],
        descriptors: HashMap<Uuid, LocalVisualDescriptor>,
        vectors: HashMap<Uuid, AssetVector>,
        taxonomy: &LibraryTaxonomyPolicy,
    ) -> Self {
        let mut folder_name_by_id: HashMap<Uuid, String> = HashMap::with_capacity(folders.len());
        let mut folder_parent_by_id: HashMap<Uuid, Uuid> = HashMap::new();
        for folder in folders {
            folder_name_by_id.insert(folder.id, folder.name.clone());
            if let Some(pid) = folder.parent_id {
                folder_parent_by_id.insert(folder.id, pid);
            }
        }

        // 1. Resolve taxonomy aliases -> canonical norm & spelling
        let mut alias_map: HashMap<String, String> = HashMap::new();
        let mut preferred_spelling: HashMap<String, String> = HashMap::new();
        let mut reverse_aliases: HashMap<String, HashSet<String>> = HashMap::new();
        let mut explicit_canonical_norms: HashSet<String> = HashSet::new();

        for (raw_alias, raw_target) in &taxonomy.tag_aliases {
            let alias = raw_alias.trim();
            let target = raw_target.trim();
            let alias_norm = search_text::normalize(alias);
            let target_norm = search_text::normalize(target);
            if alias_norm.is_empty() || target_norm.is_empty() || alias_norm == target_norm {
                continue;
            }
            alias_map.insert(alias_norm, target_norm.clone());
            preferred_spelling.insert(target_norm.clone(), target.to_string());
            explicit_canonical_norms.insert(target_norm.clone());
            reverse_aliases
                .entry(target_norm)
                .or_default()
                .insert(alias.to_string());
        }
        let aliases_by_canonical_norm: HashMap<String, Vec<String>> = reverse_aliases
            .into_iter()
            .map(|(k, set)| {
                let mut v: Vec<String> = set.into_iter().collect();
                v.sort();
                (k, v)
            })
            .collect();

        // 2. Single pass over active assets for canonical frequency, spelling votes, folder & co-occurrence context
        let mut tag_freq: HashMap<String, usize> = HashMap::new();
        let mut spelling_votes: HashMap<String, HashMap<String, usize>> = HashMap::new();
        let mut folder_tag_counts: HashMap<Uuid, HashMap<String, usize>> = HashMap::new();
        let mut tag_folder_cooc: HashMap<String, HashMap<String, usize>> = HashMap::new();
        let mut tag_tag_cooc: HashMap<String, HashMap<String, usize>> = HashMap::new();
        let mut raw_asset_canonical_tags: HashMap<Uuid, Vec<String>> =
            HashMap::with_capacity(active_assets.len());

        for asset in active_assets {
            if asset.is_trashed || asset.tags.is_empty() {
                continue;
            }
            let mut asset_norms: Vec<String> = Vec::new();
            let mut seen_on_asset: HashSet<String> = HashSet::new();
            for raw_tag in &asset.tags {
                let trimmed = raw_tag.trim();
                let raw_norm = search_text::normalize(trimmed);
                if raw_norm.is_empty() {
                    continue;
                }
                let canonical = alias_map
                    .get(&raw_norm)
                    .cloned()
                    .unwrap_or_else(|| raw_norm.clone());
                if !seen_on_asset.insert(canonical.clone()) {
                    continue;
                }
                asset_norms.push(canonical.clone());
                *tag_freq.entry(canonical.clone()).or_insert(0) += 1;
                if !alias_map.contains_key(&raw_norm) {
                    *spelling_votes
                        .entry(canonical.clone())
                        .or_default()
                        .entry(trimmed.to_string())
                        .or_insert(0) += 1;
                }
                if let Some(fid) = asset.folder_id {
                    *folder_tag_counts
                        .entry(fid)
                        .or_default()
                        .entry(canonical.clone())
                        .or_insert(0) += 1;
                    if let Some(fname) = folder_name_by_id.get(&fid) {
                        *tag_folder_cooc
                            .entry(canonical.clone())
                            .or_default()
                            .entry(fname.clone())
                            .or_insert(0) += 1;
                    }
                }
            }
            if !asset_norms.is_empty() {
                if asset_norms.len() <= 12 {
                    for i in 0..asset_norms.len() {
                        let a = &asset_norms[i];
                        for (j, b) in asset_norms.iter().enumerate() {
                            if i != j {
                                *tag_tag_cooc
                                    .entry(a.clone())
                                    .or_default()
                                    .entry(b.clone())
                                    .or_insert(0) += 1;
                            }
                        }
                    }
                }
                raw_asset_canonical_tags.insert(asset.id, asset_norms);
            }
        }

        let mut canonical_spelling = preferred_spelling;
        for (norm, votes) in spelling_votes {
            if canonical_spelling.contains_key(&norm) {
                continue;
            }
            if let Some((best, _)) = votes
                .into_iter()
                .max_by(|a, b| a.1.cmp(&b.1).then_with(|| b.0.cmp(&a.0)))
            {
                canonical_spelling.insert(norm, best);
            }
        }

        // 3. Anti-singleton noise hygiene: once >= 12 repeated tags exist, exclude count == 1 singletons
        //    unless explicitly targeted by taxonomy.tag_aliases.
        let repeated_norms: HashSet<String> = tag_freq
            .iter()
            .filter_map(|(k, &cnt)| (cnt >= 2).then_some(k.clone()))
            .collect();
        let mut eligible_set: HashSet<String> = if repeated_norms.len() >= 12 {
            repeated_norms
        } else {
            tag_freq.keys().cloned().collect()
        };
        eligible_set.extend(explicit_canonical_norms);

        let mut eligible_sorted_by_frequency: Vec<String> = eligible_set
            .iter()
            .filter(|n| canonical_spelling.contains_key(*n))
            .cloned()
            .collect();
        eligible_sorted_by_frequency.sort_by(|lhs, rhs| {
            let lf = tag_freq.get(lhs).copied().unwrap_or(0);
            let rf = tag_freq.get(rhs).copied().unwrap_or(0);
            rf.cmp(&lf).then_with(|| {
                let ls = canonical_spelling
                    .get(lhs)
                    .map(String::as_str)
                    .unwrap_or(lhs);
                let rs = canonical_spelling
                    .get(rhs)
                    .map(String::as_str)
                    .unwrap_or(rhs);
                ls.cmp(rs)
            })
        });

        let mut asset_canonical_eligible_tags: HashMap<Uuid, Vec<String>> =
            HashMap::with_capacity(raw_asset_canonical_tags.len());
        for (id, norms) in raw_asset_canonical_tags {
            let kept: Vec<String> = norms
                .into_iter()
                .filter(|n| eligible_set.contains(n))
                .collect();
            if !kept.is_empty() {
                asset_canonical_eligible_tags.insert(id, kept);
            }
        }

        // 4. Compact context hints (top 2 co-occurring folders + top 2 co-occurring canonical tags)
        let mut context_hints_by_canonical_norm: HashMap<String, Vec<String>> = HashMap::new();
        for norm in &eligible_sorted_by_frequency {
            let mut hints: Vec<String> = Vec::with_capacity(4);
            if let Some(folder_counts) = tag_folder_cooc.get(norm) {
                let mut pairs: Vec<(&String, usize)> =
                    folder_counts.iter().map(|(k, &v)| (k, v)).collect();
                pairs.sort_by(|a, b| b.1.cmp(&a.1).then_with(|| a.0.cmp(b.0)));
                for (fname, _) in pairs.into_iter().take(2) {
                    hints.push(fname.clone());
                }
            }
            if let Some(co_tags) = tag_tag_cooc.get(norm) {
                let mut pairs: Vec<(&String, usize)> = co_tags
                    .iter()
                    .filter(|(k, _)| {
                        eligible_set.contains(*k) && canonical_spelling.contains_key(*k)
                    })
                    .map(|(k, &v)| (k, v))
                    .collect();
                pairs.sort_by(|a, b| b.1.cmp(&a.1).then_with(|| a.0.cmp(b.0)));
                for (co_norm, _) in pairs.into_iter().take(2) {
                    if let Some(sp) = canonical_spelling.get(co_norm) {
                        hints.push(sp.clone());
                    }
                }
            }
            if !hints.is_empty() {
                context_hints_by_canonical_norm.insert(norm.clone(), hints);
            }
        }

        Self {
            alias_norm_to_canonical_norm: alias_map,
            canonical_spelling,
            aliases_by_canonical_norm,
            context_hints_by_canonical_norm,
            eligible_sorted_by_frequency,
            folder_parent_by_id,
            folder_tag_counts,
            asset_canonical_eligible_tags,
            descriptors,
            vectors,
        }
    }

    pub fn eligible_tag_count(&self) -> usize {
        self.eligible_sorted_by_frequency.len()
    }

    pub fn select_candidates(
        &self,
        asset: &AssetRecord,
        max_candidates: usize,
    ) -> Vec<ClosedSetTagOption> {
        let cap = max_candidates.clamp(1, 32);
        let mut existing_norms: HashSet<String> = HashSet::new();
        for raw_tag in &asset.tags {
            let raw_norm = search_text::normalize(raw_tag);
            if !raw_norm.is_empty() {
                let folded = self
                    .alias_norm_to_canonical_norm
                    .get(&raw_norm)
                    .cloned()
                    .unwrap_or(raw_norm);
                existing_norms.insert(folded);
            }
        }

        let available: Vec<&String> = self
            .eligible_sorted_by_frequency
            .iter()
            .filter(|n| !existing_norms.contains(*n))
            .collect();
        if available.is_empty() {
            return Vec::new();
        }
        if available.len() <= cap {
            return available
                .into_iter()
                .filter_map(|n| self.make_option(n))
                .collect();
        }

        let mut picked_norms: Vec<String> = Vec::with_capacity(cap);
        let mut picked_set: HashSet<String> = HashSet::with_capacity(cap);
        let try_push = |norm: &str,
                        picked_norms: &mut Vec<String>,
                        picked_set: &mut HashSet<String>|
         -> bool {
            if picked_norms.len() < cap
                && !existing_norms.contains(norm)
                && self.canonical_spelling.contains_key(norm)
                && picked_set.insert(norm.to_string())
            {
                picked_norms.push(norm.to_string());
                true
            } else {
                false
            }
        };

        // Signal 1: Visual Neighbor Tags (up to 50% / 10 slots) via cached LocalVisualDescriptor & embeddings
        let target_desc = self.descriptors.get(&asset.id);
        let target_emb = self
            .vectors
            .get(&asset.id)
            .and_then(|v| v.embedding.as_deref());
        if target_desc.is_some() || target_emb.is_some() {
            let mut neighbor_sims: Vec<(Uuid, f64)> = Vec::new();
            for (&other_id, other_tags) in &self.asset_canonical_eligible_tags {
                if other_id == asset.id || other_tags.is_empty() {
                    continue;
                }
                let mut sim = 0.0_f64;
                if let (Some(td), Some(od)) = (target_desc, self.descriptors.get(&other_id)) {
                    sim = sim.max(td.similarity(od));
                }
                if let (Some(te), Some(oe)) = (
                    target_emb,
                    self.vectors
                        .get(&other_id)
                        .and_then(|v| v.embedding.as_deref()),
                ) {
                    if let Some(cos) = cosine_similarity(te, oe) {
                        sim = sim.max(f64::from(cos.clamp(0.0, 1.0)));
                    }
                }
                if sim >= 0.35 {
                    neighbor_sims.push((other_id, sim));
                }
            }
            if !neighbor_sims.is_empty() {
                neighbor_sims.sort_by(|a, b| {
                    b.1.partial_cmp(&a.1)
                        .unwrap_or(std::cmp::Ordering::Equal)
                        .then_with(|| a.0.cmp(&b.0))
                });
                let mut visual_tag_scores: HashMap<&str, f64> = HashMap::new();
                for (nid, sim) in neighbor_sims.into_iter().take(12) {
                    if let Some(tags) = self.asset_canonical_eligible_tags.get(&nid) {
                        for norm in tags {
                            if !existing_norms.contains(norm) {
                                *visual_tag_scores.entry(norm.as_str()).or_insert(0.0) += sim;
                            }
                        }
                    }
                }
                let mut ranked: Vec<(&str, f64)> = visual_tag_scores.into_iter().collect();
                ranked.sort_by(|lhs, rhs| {
                    if (lhs.1 - rhs.1).abs() > 0.001 {
                        rhs.1
                            .partial_cmp(&lhs.1)
                            .unwrap_or(std::cmp::Ordering::Equal)
                    } else {
                        lhs.0.cmp(rhs.0)
                    }
                });
                let visual_budget = (cap / 2).max(6).min(cap);
                for (norm, _) in ranked.into_iter().take(visual_budget) {
                    try_push(norm, &mut picked_norms, &mut picked_set);
                }
            }
        }

        // Signal 2: Same-folder (1.0x) & parent-folder (0.45x) tag prior (up to 35% / 7 slots)
        if let Some(fid) = asset.folder_id {
            let mut folder_scores: HashMap<&str, f64> = HashMap::new();
            if let Some(counts) = self.folder_tag_counts.get(&fid) {
                for (norm, &cnt) in counts {
                    if !existing_norms.contains(norm) {
                        *folder_scores.entry(norm.as_str()).or_insert(0.0) += cnt as f64;
                    }
                }
            }
            if let Some(parent_id) = self.folder_parent_by_id.get(&fid) {
                if let Some(counts) = self.folder_tag_counts.get(parent_id) {
                    for (norm, &cnt) in counts {
                        if !existing_norms.contains(norm) {
                            *folder_scores.entry(norm.as_str()).or_insert(0.0) +=
                                (cnt as f64) * 0.45;
                        }
                    }
                }
            }
            let mut ranked: Vec<(&str, f64)> = folder_scores.into_iter().collect();
            ranked.sort_by(|lhs, rhs| {
                if (lhs.1 - rhs.1).abs() > 0.001 {
                    rhs.1
                        .partial_cmp(&lhs.1)
                        .unwrap_or(std::cmp::Ordering::Equal)
                } else {
                    lhs.0.cmp(rhs.0)
                }
            });
            let folder_budget = ((cap as f64) * 0.35).round().max(4.0) as usize;
            let mut folder_added = 0usize;
            for (norm, _) in ranked {
                if folder_added >= folder_budget || picked_norms.len() >= cap {
                    break;
                }
                if try_push(norm, &mut picked_norms, &mut picked_set) {
                    folder_added += 1;
                }
            }
        }

        // Signal 3: Global highest-frequency canonical backbone tags
        for norm in available {
            if picked_norms.len() >= cap {
                break;
            }
            try_push(norm, &mut picked_norms, &mut picked_set);
        }

        picked_norms
            .iter()
            .filter_map(|n| self.make_option(n))
            .collect()
    }

    fn make_option(&self, norm: &str) -> Option<ClosedSetTagOption> {
        let name = self.canonical_spelling.get(norm)?.clone();
        Some(ClosedSetTagOption {
            name,
            aliases: self
                .aliases_by_canonical_norm
                .get(norm)
                .cloned()
                .unwrap_or_default(),
            context_hints: self
                .context_hints_by_canonical_norm
                .get(norm)
                .cloned()
                .unwrap_or_default(),
        })
    }
}

/// Canonicalizes open-set VLM suggested tags against existing library tag spellings and strips
/// tags already present on the asset (used as cold-start or non-Jev fallback).
pub fn canonicalize_suggested_tags(
    raw_tags: &[String],
    existing_library_tags: &[String],
    existing_asset_tags: &[String],
    max_count: usize,
) -> Vec<String> {
    let mut library_spelling: HashMap<String, String> = HashMap::new();
    for t in existing_library_tags {
        let trimmed = t.trim();
        let norm = search_text::normalize(trimmed);
        if !norm.is_empty() {
            library_spelling
                .entry(norm)
                .or_insert_with(|| trimmed.to_string());
        }
    }
    let existing_norm: HashSet<String> = existing_asset_tags
        .iter()
        .map(|t| search_text::normalize(t))
        .filter(|s| !s.is_empty())
        .collect();
    let mut seen = HashSet::new();
    let mut out = Vec::new();
    for raw in raw_tags {
        let trimmed = raw.trim().trim_start_matches('#').trim();
        if trimmed.is_empty() {
            continue;
        }
        let norm = search_text::normalize(trimmed);
        if norm.is_empty() || existing_norm.contains(&norm) || !seen.insert(norm.clone()) {
            continue;
        }
        let canonical = library_spelling
            .get(&norm)
            .cloned()
            .unwrap_or_else(|| trimmed.to_string());
        out.push(canonical);
        if out.len() >= max_count {
            break;
        }
    }
    out
}

fn ascii_word_set(text: &str) -> HashSet<String> {
    let mut out = HashSet::new();
    let mut buf = String::new();
    for ch in text.chars() {
        if ch.is_ascii_alphanumeric() {
            buf.push(ch.to_ascii_lowercase());
        } else if !buf.is_empty() {
            if buf.len() >= 2 {
                out.insert(std::mem::take(&mut buf));
            } else {
                buf.clear();
            }
        }
    }
    if buf.len() >= 2 {
        out.insert(buf);
    }
    out
}

fn parse_cloud_triage_json(
    raw: &str,
    by_key: &HashMap<String, &FolderOptionInput>,
    provider_label: &str,
) -> FolderClassificationResult {
    let Some(val) = crate::intelligence::cloud_ai::extract_json_object_value(raw) else {
        return FolderClassificationResult {
            folder_id: None,
            confidence: 0.0,
            fit_probability: 0.0,
            reason: format!("{provider_label} 未返回可解析的分类结果，建议暂留收件箱"),
            source: VisualRegionSource::AppleVisionSaliency,
        };
    };

    let fits_any = val
        .get("fits_any")
        .or_else(|| val.get("fitsAny"))
        .and_then(Value::as_bool)
        .unwrap_or(false);
    let conf = val
        .get("confidence")
        .and_then(Value::as_f64)
        .filter(|v| v.is_finite())
        .unwrap_or(if fits_any { 0.72 } else { 0.25 })
        .clamp(0.0, 1.0);
    let model_reason = val
        .get("reason")
        .and_then(Value::as_str)
        .map(str::trim)
        .filter(|s| !s.is_empty())
        .map(|s| s.chars().take(120).collect::<String>());
    let key = val
        .get("folder_key")
        .or_else(|| val.get("folderKey"))
        .and_then(Value::as_str)
        .map(str::trim);

    if !fits_any || conf < 0.45 {
        return FolderClassificationResult {
            folder_id: None,
            confidence: conf,
            fit_probability: conf,
            reason: model_reason.unwrap_or_else(|| {
                format!("{provider_label} 判断暂无明确匹配目录，建议暂留收件箱")
            }),
            source: VisualRegionSource::AppleVisionSaliency,
        };
    }

    if let Some(folder) = key.and_then(|k| by_key.get(k).copied()) {
        FolderClassificationResult {
            folder_id: Some(folder.id),
            confidence: conf,
            fit_probability: conf,
            reason: model_reason.unwrap_or_else(|| {
                format!(
                    "{provider_label} 推荐归档至「{}」（置信度 {}%）",
                    folder.name,
                    (conf * 100.0).round() as i32
                )
            }),
            source: VisualRegionSource::AppleVisionSaliency,
        }
    } else {
        FolderClassificationResult {
            folder_id: None,
            confidence: 0.0,
            fit_probability: 0.0,
            reason: model_reason
                .unwrap_or_else(|| format!("{provider_label} 未匹配到已有目录，建议暂留收件箱")),
            source: VisualRegionSource::AppleVisionSaliency,
        }
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

    #[test]
    fn recommend_inbox_triage_abstains_instead_of_blindly_picking_first_folder() {
        let f_ui = FolderRecord::new("UI Inspiration", None);
        let f_arch = FolderRecord::new("Architecture", None);
        let unrelated = AssetRecord::new("GCqrsxJbUAAbbdB", "GCqrsxJbUAAbbdB.jpg");
        let building = AssetRecord::new("building_facade", "building_facade.png");
        let matched = AssetRecord::new("Brutalist Architecture", "arch.png");

        let recs = VisualGroundingEngine::recommend_inbox_triage(
            &[unrelated, building, matched],
            &[f_ui, f_arch.clone()],
        );
        assert_eq!(recs.len(), 3);
        assert!(
            recs[0].recommended_folder_id.is_none(),
            "Unmatched asset must stay in Inbox, not blindly pick folders[0]"
        );
        assert!(
            recs[1].recommended_folder_id.is_none(),
            "'building_facade' must NOT match 'UI' via substring"
        );
        assert_eq!(recs[2].recommended_folder_id, Some(f_arch.id));
    }

    #[test]
    fn cloud_triage_json_parser_enforces_closed_set_and_abstention() {
        let f0 = FolderOptionInput {
            id: Uuid::new_v4(),
            name: "UI Inspiration".to_string(),
            display_path: "UI Inspiration".to_string(),
            sample_tags: vec!["移动端".to_string()],
            sample_titles: vec![],
        };
        let f1 = FolderOptionInput {
            id: Uuid::new_v4(),
            name: "Editorial".to_string(),
            display_path: "Editorial".to_string(),
            sample_tags: vec!["杂志排版".to_string()],
            sample_titles: vec![],
        };
        let mut by_key = HashMap::new();
        by_key.insert("f_0".to_string(), &f0);
        by_key.insert("f_1".to_string(), &f1);

        let good = parse_cloud_triage_json(
            r#"{"fits_any": true, "folder_key": "f_1", "confidence": 0.91, "reason": "杂志网格排版风格"}"#,
            &by_key,
            "Google Gemini",
        );
        assert_eq!(good.folder_id, Some(f1.id));
        assert!((good.confidence - 0.91).abs() < 1e-6);

        let abstain = parse_cloud_triage_json(
            r#"{"fits_any": false, "folder_key": "f_0", "confidence": 0.30, "reason": "与现有目录不符"}"#,
            &by_key,
            "Google Gemini",
        );
        assert!(abstain.folder_id.is_none());

        let hallucinated = parse_cloud_triage_json(
            r#"{"fits_any": true, "folder_key": "f_99", "confidence": 0.95, "reason": "幻觉目录"}"#,
            &by_key,
            "Google Gemini",
        );
        assert!(hallucinated.folder_id.is_none());
    }

    #[test]
    fn legacy_typesafe_config_decodes_closed_set_defaults_and_sanitizes_thresholds() {
        let legacy_json = r#"{"enabled":true,"model":"jev-latest","enableSubjectPalette":false}"#;
        let cfg: TypeSafeExperimentalConfig = serde_json::from_str(legacy_json).unwrap();
        assert!(cfg.enable_closed_set_tagging);
        assert!(!cfg.auto_apply_high_confidence_tags);
        assert!((cfg.high_confidence_tag_threshold - 0.82).abs() < 1e-6);
        assert!((cfg.suggested_tag_threshold - 0.52).abs() < 1e-6);
        assert!(!cfg.enable_subject_palette);

        let extreme = TypeSafeExperimentalConfig {
            high_confidence_tag_threshold: 0.40,
            suggested_tag_threshold: 0.95,
            ..Default::default()
        }
        .sanitized();
        assert!((extreme.high_confidence_tag_threshold - 0.60).abs() < 1e-6);
        assert!((extreme.suggested_tag_threshold - 0.60).abs() < 1e-6);
    }

    #[tokio::test]
    async fn closed_set_tag_classifier_sends_single_lean_multipart_request_and_forbids_hallucinations(
    ) {
        use std::sync::atomic::{AtomicUsize, Ordering};
        use tokio::io::{AsyncReadExt, AsyncWriteExt};
        use tokio::net::TcpListener;

        let listener = TcpListener::bind("127.0.0.1:0").await.unwrap();
        let addr = listener.local_addr().unwrap();
        let captured_requests = Arc::new(std::sync::Mutex::new(Vec::<String>::new()));
        let req_count = Arc::new(AtomicUsize::new(0));
        let cap_clone = Arc::clone(&captured_requests);
        let cnt_clone = Arc::clone(&req_count);

        tokio::spawn(async move {
            if let Ok((mut stream, _)) = listener.accept().await {
                cnt_clone.fetch_add(1, Ordering::SeqCst);
                let mut buf = vec![0u8; 65536];
                let mut total = Vec::new();
                loop {
                    match tokio::time::timeout(
                        std::time::Duration::from_millis(250),
                        stream.read(&mut buf),
                    )
                    .await
                    {
                        Ok(Ok(0)) | Err(_) => break,
                        Ok(Ok(n)) => {
                            total.extend_from_slice(&buf[..n]);
                            if total.windows(4).any(|w| w == b"--\r\n") {
                                break;
                            }
                        }
                        Ok(Err(_)) => break,
                    }
                }
                cap_clone
                    .lock()
                    .unwrap()
                    .push(String::from_utf8_lossy(&total).into_owned());

                let resp_body = json!({
                    "model": "jev-latest",
                    "answers": {
                        "t_0": { "type": "noul", "noul": 0.93 },
                        "t_1": { "type": "noul", "noul": 0.64 },
                        "t_2": { "type": "noul", "noul": 0.21 },
                        "t_hallucinated": { "type": "noul", "noul": 0.99 }
                    },
                    "usage": { "input_tokens": 1320, "output_tokens": 48 }
                })
                .to_string();
                let http = format!(
                    "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: {}\r\nConnection: close\r\n\r\n{}",
                    resp_body.len(),
                    resp_body
                );
                let _ = stream.write_all(http.as_bytes()).await;
                let _ = stream.shutdown().await;
            }
        });

        let usage = Arc::new(CloudAIUsageStore::in_memory());
        let grounding = VisualGroundingEngine::new(Arc::clone(&usage));
        let cfg = TypeSafeExperimentalConfig {
            enabled: true,
            base_url: format!("http://127.0.0.1:{}", addr.port()),
            model: "jev-latest".to_string(),
            enable_closed_set_tagging: true,
            high_confidence_tag_threshold: 0.82,
            suggested_tag_threshold: 0.52,
            ..Default::default()
        };

        let img = DynamicImage::ImageRgba8(RgbaImage::from_pixel(
            320,
            320,
            image::Rgba([220, 180, 120, 255]),
        ));
        let jpeg = TypeSafeImagePreparer::prepare_jpeg(&img, 320).unwrap();

        let res = grounding
            .classify_closed_set_tags(
                "Golden Film Poster",
                &["已有标签".to_string()],
                "暖色胶片海报",
                Some(&jpeg),
                &[
                    ClosedSetTagOption {
                        name: "胶片".to_string(),
                        aliases: vec!["复古胶片".to_string()],
                        context_hints: vec!["摄影".to_string()],
                    },
                    ClosedSetTagOption {
                        name: "暖色调".to_string(),
                        aliases: vec![],
                        context_hints: vec!["配色".to_string()],
                    },
                    ClosedSetTagOption {
                        name: "赛博朋克".to_string(),
                        aliases: vec![],
                        context_hints: vec![],
                    },
                    ClosedSetTagOption {
                        name: "已有标签".to_string(),
                        aliases: vec![],
                        context_hints: vec![],
                    },
                ],
                &cfg,
                Some("ts-test-key"),
                20,
                5,
                6,
            )
            .await
            .unwrap();

        assert_eq!(req_count.load(Ordering::SeqCst), 1);
        assert_eq!(res.evaluated_tag_count, 3);
        assert_eq!(res.confirmed_tags.len(), 1);
        assert_eq!(res.confirmed_tags[0].tag, "胶片");
        assert_eq!(res.suggested_tags.len(), 1);
        assert_eq!(res.suggested_tags[0].tag, "暖色调");

        let raw_wire = captured_requests.lock().unwrap()[0].clone();
        assert!(
            raw_wire.contains("TypeSafe-Danger-Zone-Images: true")
                || raw_wire
                    .to_ascii_lowercase()
                    .contains("typesafe-danger-zone-images: true")
        );
        assert!(
            !raw_wire.contains("\"criteria\""),
            "Lean closed-set multi-Noul prompt must NOT include verbose criteria boilerplate"
        );
    }

    #[test]
    fn closed_set_tag_funnel_suppresses_singletons_folds_aliases_and_prioritizes_folder_and_visual_neighbors(
    ) {
        let parent_folder = FolderRecord::new("插画总集", None);
        let child_folder = FolderRecord::new("水彩人物", Some(parent_folder.id));

        let mut assets = Vec::new();
        // Create 13 repeated canonical tags (>= 12 triggers anti-singleton hygiene)
        for i in 0..13 {
            let tag = format!("核心标签{i:02}");
            for copy in 0..2 {
                let mut a =
                    AssetRecord::new(format!("Core {i}-{copy}"), format!("c{i}_{copy}.png"));
                a.tags = vec![tag.clone()];
                assets.push(a);
            }
        }
        // Add alias-folded tag + folder prior + parent-folder prior + one-off singleton
        for i in 0..3 {
            let mut a = AssetRecord::new(format!("Child {i}"), format!("ch{i}.png"));
            a.folder_id = Some(child_folder.id);
            a.tags = vec!["手绘风".to_string(), "水彩".to_string()];
            assets.push(a);
        }
        for i in 0..2 {
            let mut a = AssetRecord::new(format!("Parent {i}"), format!("p{i}.png"));
            a.folder_id = Some(parent_folder.id);
            a.tags = vec!["人物设定".to_string()];
            assets.push(a);
        }
        let mut singleton = AssetRecord::new("OneOff", "oneoff.png");
        singleton.tags = vec!["一次性孤儿噪声标签".to_string()];
        assets.push(singleton);

        let mut taxonomy = LibraryTaxonomyPolicy::default();
        taxonomy
            .tag_aliases
            .insert("手绘风".to_string(), "手绘插画".to_string());

        let funnel = ClosedSetTagFunnel::new(
            &assets,
            &[parent_folder.clone(), child_folder.clone()],
            HashMap::new(),
            HashMap::new(),
            &taxonomy,
        );

        let mut target = AssetRecord::new("New Sketch", "new.png");
        target.folder_id = Some(child_folder.id);

        let cands = funnel.select_candidates(&target, 20);
        assert!(cands.len() <= 20);
        let names: Vec<&str> = cands.iter().map(|c| c.name.as_str()).collect();
        assert!(
            !names.contains(&"一次性孤儿噪声标签"),
            "Singleton tag must be suppressed once >= 12 repeated tags exist"
        );
        assert!(
            names.contains(&"手绘插画") && !names.contains(&"手绘风"),
            "Alias must fold into canonical spelling"
        );
        let hand_drawn = cands.iter().find(|c| c.name == "手绘插画").unwrap();
        assert!(hand_drawn.aliases.iter().any(|a| a == "手绘风"));
        assert!(names.contains(&"水彩"));
        assert!(names.contains(&"人物设定"));
    }

    #[tokio::test]
    async fn phase1_runtime_feature_flags_skip_jev_http_and_fall_back_offline() {
        use std::sync::atomic::{AtomicUsize, Ordering};
        use tokio::net::TcpListener;

        let listener = TcpListener::bind("127.0.0.1:0").await.unwrap();
        let addr = listener.local_addr().unwrap();
        let hits = Arc::new(AtomicUsize::new(0));
        let hits_bg = Arc::clone(&hits);
        tokio::spawn(async move {
            while let Ok((_stream, _)) = listener.accept().await {
                hits_bg.fetch_add(1, Ordering::SeqCst);
            }
        });

        let usage = Arc::new(CloudAIUsageStore::in_memory());
        let grounding = VisualGroundingEngine::new(usage);
        let img = DynamicImage::ImageRgba8(RgbaImage::from_pixel(
            300,
            300,
            image::Rgba([40, 90, 200, 255]),
        ));

        // 1. enable_subject_palette = false -> 0 HTTP calls even when enabled = true & focus_crop = true
        let cfg_no_palette = TypeSafeExperimentalConfig {
            enabled: true,
            base_url: format!("http://127.0.0.1:{}", addr.port()),
            enable_moodboard_focus_crop: true,
            enable_subject_palette: false,
            enable_auto_clean_crop: false,
            enable_pinpoint_annotations: false,
            ..Default::default()
        };
        let (_colors, pal_reg) = grounding
            .extract_subject_palette(&img, &cfg_no_palette, Some("ts-key"))
            .await;
        assert_eq!(pal_reg.source, VisualRegionSource::AppleVisionSaliency);

        // 2. enable_auto_clean_crop = false -> 0 HTTP calls
        let clean = grounding
            .detect_clean_bounds(&img, &cfg_no_palette, Some("ts-key"))
            .await;
        assert_eq!(clean.source, VisualRegionSource::AppleVisionSaliency);

        // 3. both enable_moodboard_focus_crop & enable_pinpoint_annotations = false -> 0 HTTP calls
        let cfg_no_region = TypeSafeExperimentalConfig {
            enable_moodboard_focus_crop: false,
            enable_pinpoint_annotations: false,
            ..cfg_no_palette
        };
        let reg = grounding
            .locate_region(Some("hero"), &img, &cfg_no_region, Some("ts-key"))
            .await;
        assert_eq!(reg.source, VisualRegionSource::AppleVisionSaliency);

        assert_eq!(
            hits.load(Ordering::SeqCst),
            0,
            "Disabled Phase 1 flags MUST trigger zero TypeSafe HTTP requests"
        );
    }
}
