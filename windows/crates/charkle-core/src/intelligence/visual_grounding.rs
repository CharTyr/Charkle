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

use crate::error::{CoreError, CoreResult};
use crate::intelligence::cloud_ai::CloudAIProvider;
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
    let trimmed = raw.trim();
    let cleaned = match (trimmed.find('{'), trimmed.rfind('}')) {
        (Some(start), Some(end)) if start <= end => &trimmed[start..=end],
        _ => trimmed,
    };
    let Ok(val) = serde_json::from_str::<Value>(cleaned) else {
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
}
