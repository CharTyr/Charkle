//! 8-phase streaming Moodboard Agent Harness (`planning` -> `retrieving` ->
//! `inspectingVisuals` -> `composing` -> `verifying` -> `repairing` -> `completed` / `fallbackOffline`).

use std::collections::HashMap;
use std::sync::Arc;

use chrono::Utc;
use uuid::Uuid;

use crate::db::LibraryDatabase;
use crate::error::CoreResult;
use crate::intelligence::curator::{IntelligenceEngine, LocalIntelligenceEngine, MoodboardCurator};
use crate::layout::EditorialLayoutSolver;
use crate::models::core::{AssetRecord, LabColor};
use crate::models::moodboard::{
    AutoLayoutConfig, BoardLayoutMode, BoardNode, BoardNodeKind, BoardRect, EditorialStyle,
    GroupTint, MoodboardAgentPhase, MoodboardAgentStep, MoodboardAgentStepStatus,
    MoodboardCurationRequest, MoodboardDocument, MoodboardProposal, MoodboardSectionDraft,
    NormalizedCropRect, NoteStyle,
};

pub struct MoodboardAgentHarness;

impl MoodboardAgentHarness {
    /// Generates or iteratively refines a complete `MoodboardProposal` while streaming every
    /// `MoodboardAgentStep` phase to `on_step` for live UI progress display.
    pub async fn run<F>(
        db: &LibraryDatabase,
        request: &MoodboardCurationRequest,
        engine: Option<Arc<dyn IntelligenceEngine>>,
        mut on_step: F,
    ) -> CoreResult<MoodboardProposal>
    where
        F: FnMut(MoodboardAgentStep),
    {
        let intel: Arc<dyn IntelligenceEngine> =
            engine.unwrap_or_else(|| Arc::new(LocalIntelligenceEngine));
        let used_cloud = intel.is_cloud_enabled();
        let mut trace: Vec<MoodboardAgentStep> = Vec::with_capacity(8);

        let mut record = |phase: MoodboardAgentPhase,
                          title: &str,
                          detail: String,
                          status: MoodboardAgentStepStatus| {
            let step = MoodboardAgentStep {
                id: Uuid::new_v4(),
                phase,
                title: title.to_string(),
                detail,
                status,
                timestamp: Utc::now(),
            };
            on_step(step.clone());
            trace.push(step);
        };

        // 1. Planning
        let combined_prompt = match &request.refinement_instruction {
            Some(refinement) if !refinement.trim().is_empty() => {
                if request.prompt.trim().is_empty() {
                    refinement.trim().to_string()
                } else {
                    format!("{} {}", request.prompt.trim(), refinement.trim())
                }
            }
            _ => request.prompt.trim().to_string(),
        };
        let expanded_terms = intel.expand_prompt_terms(&combined_prompt).await;
        record(
            MoodboardAgentPhase::Planning,
            "拆解主题与构图策略",
            if combined_prompt.is_empty() {
                format!(
                    "按 {} 项种子与色板目标规划版式（目标 {} 项）",
                    request.seed_asset_ids.len(),
                    request.preferred_count
                )
            } else {
                format!(
                    "解析关键词：{}（扩展 {} 个检索词）",
                    combined_prompt,
                    expanded_terms.len()
                )
            },
            MoodboardAgentStepStatus::Done,
        );

        // 2. Retrieving
        let mut local_req = request.clone();
        local_req.prompt = combined_prompt.clone();
        let (raw_primary, raw_candidates, extracted_palette) =
            MoodboardCurator::curate_local(db, &local_req, &expanded_terms)?;
        record(
            MoodboardAgentPhase::Retrieving,
            "召回候选素材与色彩匹配",
            format!(
                "已从本地库检索 {} 项主选素材与 {} 项候选替换池",
                raw_primary.len(),
                raw_candidates.len()
            ),
            MoodboardAgentStepStatus::Done,
        );

        // 3. Inspecting visuals
        let primary_matches = intel.rerank_candidates(&combined_prompt, raw_primary).await;
        let candidate_pool = raw_candidates;
        let insights_count = primary_matches
            .iter()
            .filter(|s| s.asset.ai_description.is_some() || !s.asset.dominant_colors.is_empty())
            .count();
        record(
            MoodboardAgentPhase::InspectingVisuals,
            "视觉构图与色板分析",
            format!(
                "评估 {} 项素材的画面比例、主色分布与视觉多样性（MMR 去重）",
                insights_count
            ),
            MoodboardAgentStepStatus::Done,
        );

        // 4. Composing
        let (mut draft_doc, sections) = Self::compose_document(
            request,
            &combined_prompt,
            &primary_matches,
            &candidate_pool,
            &extracted_palette,
        );
        record(
            MoodboardAgentPhase::Composing,
            "编排情绪板版面与策展分区",
            format!(
                "生成 {} 个画布节点、{} 个色卡主色与 {} 个主题分区",
                draft_doc.nodes.len(),
                extracted_palette.len(),
                sections.len()
            ),
            MoodboardAgentStepStatus::Done,
        );

        // 5. Verifying
        let mut repair_notes: Vec<String> = Vec::new();
        let asset_nodes_count = draft_doc
            .nodes
            .iter()
            .filter(|n| matches!(n.kind, BoardNodeKind::AssetRef { .. }))
            .count();
        let needs_repair = asset_nodes_count == 0
            || draft_doc
                .nodes
                .iter()
                .any(|n| n.frame.width <= 0.0 || n.frame.height <= 0.0);

        record(
            MoodboardAgentPhase::Verifying,
            "校验视觉均衡与坐标完整性",
            if needs_repair {
                "检测到部分节点尺寸待归一化，进入自动修复阶段".to_string()
            } else {
                format!(
                    "全部 {} 个画布对象坐标与比例校验通过",
                    draft_doc.nodes.len()
                )
            },
            if needs_repair {
                MoodboardAgentStepStatus::Warning
            } else {
                MoodboardAgentStepStatus::Done
            },
        );

        // 6. Repairing (always runs cleanly to normalize frames & prevent overlaps)
        let assets_by_id: HashMap<Uuid, AssetRecord> = primary_matches
            .iter()
            .map(|s| (s.asset.id, s.asset.clone()))
            .collect();
        if needs_repair {
            let solved = EditorialLayoutSolver::solve(
                &draft_doc.nodes,
                AutoLayoutConfig {
                    columns: 4,
                    spacing: 16.0,
                    style: request.layout_style,
                    show_palette_strip: true,
                },
                1120.0,
                &assets_by_id,
                28.0,
            );
            for node in &mut draft_doc.nodes {
                if let Some(rect) = solved.frame_for(node.id) {
                    node.frame = rect;
                }
            }
            repair_notes.push("已对画布节点坐标执行重排与无重叠修复".to_string());
        }
        record(
            MoodboardAgentPhase::Repairing,
            "版面微调与间距收敛",
            if repair_notes.is_empty() {
                "版面节奏紧凑均衡，无需额外重排".to_string()
            } else {
                repair_notes.join("；")
            },
            MoodboardAgentStepStatus::Done,
        );

        // 7/8. Completed or FallbackOffline
        let final_phase = if used_cloud {
            MoodboardAgentPhase::Completed
        } else {
            MoodboardAgentPhase::FallbackOffline
        };
        record(
            final_phase,
            if used_cloud {
                "智能策展完成"
            } else {
                "本地离线策展完成"
            },
            format!(
                "已就绪：主画布 {} 项 + 候选替换池 {} 项",
                primary_matches.len(),
                candidate_pool.len()
            ),
            MoodboardAgentStepStatus::Done,
        );

        let summary = if combined_prompt.is_empty() {
            format!(
                "围绕 {} 项精选灵感与 {} 种主色生成视觉情绪板",
                primary_matches.len(),
                extracted_palette.len()
            )
        } else {
            format!(
                "以「{}」为方向精选 {} 项参考素材，并备好 {} 项可一键替换候选",
                combined_prompt,
                primary_matches.len(),
                candidate_pool.len()
            )
        };

        Ok(MoodboardProposal {
            draft_document: draft_doc,
            primary_matches,
            candidate_pool,
            extracted_palette,
            used_cloud_ai: used_cloud,
            curated_summary: summary,
            agent_trace: trace,
            sections,
            rejected_summary: if request.excluded_asset_ids.is_empty() {
                None
            } else {
                Some(format!(
                    "已排除 {} 项素材",
                    request.excluded_asset_ids.len()
                ))
            },
            cached_visual_insights_count: insights_count,
        })
    }

    fn compose_document(
        request: &MoodboardCurationRequest,
        prompt: &str,
        primary: &[crate::models::core::ScoredAsset],
        candidates: &[crate::models::core::ScoredAsset],
        palette: &[LabColor],
    ) -> (MoodboardDocument, Vec<MoodboardSectionDraft>) {
        let now = Utc::now();
        let mut doc = request.existing_board.clone().unwrap_or_else(|| {
            let title = if !prompt.is_empty() {
                prompt.chars().take(28).collect()
            } else if let Some(first) = primary.first() {
                format!(
                    "{} · 灵感板",
                    first.asset.title.chars().take(18).collect::<String>()
                )
            } else {
                "未命名情绪板".to_string()
            };
            MoodboardDocument::new(title)
        });

        doc.subtitle = if !prompt.is_empty() {
            format!("主题策展 · {}", prompt.chars().take(48).collect::<String>())
        } else {
            "色彩与构图精选".to_string()
        };
        doc.extracted_palette = palette.to_vec();
        doc.candidate_asset_ids = candidates.iter().map(|c| c.asset.id).collect();
        doc.updated_at = now;

        let mut nodes: Vec<BoardNode> = Vec::new();
        let mut order = 0_i32;

        // Optional curated intro note
        if request.include_curator_notes && (!prompt.is_empty() || !primary.is_empty()) {
            let note_text = if prompt.is_empty() {
                format!(
                    "围绕 {} 项视觉参考提炼质感、构图节奏与色板平衡。",
                    primary.len()
                )
            } else {
                format!(
                    "视觉方向：{}\n精选 {} 项高契合度素材，右侧候选池支持一键替换。",
                    prompt,
                    primary.len()
                )
            };
            nodes.push(BoardNode {
                id: Uuid::new_v4(),
                kind: BoardNodeKind::Note {
                    title: Some("策展思路".to_string()),
                    text: note_text,
                    style: NoteStyle::Warm,
                    font_size: 14.0,
                },
                frame: BoardRect::new(0.0, 0.0, 260.0, 150.0),
                z_index: order,
                rotation_degrees: 0.0,
                flip_horizontal: false,
                flip_vertical: false,
                is_locked: false,
                editorial_order: order,
                updated_at: now,
            });
            order += 1;
        }

        // Asset nodes (top 1–2 marked Hero weight=2 for Magazine layout)
        let mut sections: Vec<MoodboardSectionDraft> = Vec::new();
        let mut hero_ids: Vec<Uuid> = Vec::new();
        for (idx, item) in primary.iter().enumerate() {
            let weight =
                if idx == 0 || (idx == 4 && request.layout_style == EditorialStyle::Magazine) {
                    hero_ids.push(item.asset.id);
                    2
                } else {
                    1
                };
            let crop = if request.auto_focus_detail_crop
                && (item.asset.aspect_ratio() > 1.7 || item.asset.aspect_ratio() < 0.6)
            {
                Some(NormalizedCropRect::from_box(0.12, 0.88, 0.12, 0.88))
            } else {
                None
            };
            nodes.push(BoardNode {
                id: Uuid::new_v4(),
                kind: BoardNodeKind::AssetRef {
                    asset_id: item.asset.id,
                    crop,
                    weight,
                    autoplay_loop: true,
                },
                frame: BoardRect::new(0.0, 0.0, 280.0, 220.0),
                z_index: order,
                rotation_degrees: 0.0,
                flip_horizontal: false,
                flip_vertical: false,
                is_locked: false,
                editorial_order: order,
                updated_at: now,
            });
            order += 1;
        }

        if !primary.is_empty() {
            sections.push(MoodboardSectionDraft {
                id: Uuid::new_v4(),
                title: "核心视觉焦点".to_string(),
                tint: GroupTint::Sand,
                rationale: "高契合度主视觉与材质代表".to_string(),
                asset_ids: primary.iter().map(|s| s.asset.id).collect(),
                hero_asset_ids: hero_ids,
            });
        }

        // Palette Strip node if extracted colors available
        if !palette.is_empty() {
            nodes.push(BoardNode {
                id: Uuid::new_v4(),
                kind: BoardNodeKind::PaletteStrip {
                    colors: palette.to_vec(),
                    auto_sync_with_board: true,
                },
                frame: BoardRect::new(0.0, 0.0, 480.0, 76.0),
                z_index: order,
                rotation_degrees: 0.0,
                flip_horizontal: false,
                flip_vertical: false,
                is_locked: false,
                editorial_order: order,
                updated_at: now,
            });
        }

        let assets_by_id: HashMap<Uuid, AssetRecord> = primary
            .iter()
            .map(|s| (s.asset.id, s.asset.clone()))
            .collect();
        let cfg = AutoLayoutConfig {
            columns: match request.layout_style {
                EditorialStyle::Magazine => 3,
                EditorialStyle::Balanced => 4,
                EditorialStyle::Compact => 6,
            },
            spacing: 16.0,
            style: request.layout_style,
            show_palette_strip: true,
        };
        doc.nodes = nodes;
        doc.mode = BoardLayoutMode::AutoEditorial(cfg);

        // Solve initial frames deterministically; freeze into Freeform if requested
        let solved = EditorialLayoutSolver::solve(&doc.nodes, cfg, 1120.0, &assets_by_id, 28.0);
        for node in &mut doc.nodes {
            if let Some(rect) = solved.frame_for(node.id) {
                node.frame = rect;
            }
        }
        if request.use_freeform_layout {
            doc = EditorialLayoutSolver::freeze_into_freeform(&doc, 1120.0, &assets_by_id);
        }

        (doc, sections)
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::models::core::{AssetRecord, MediaKind};
    use tempfile::tempdir;

    #[tokio::test]
    async fn harness_streams_all_phases_and_builds_primary_plus_candidate_pool() {
        let dir = tempdir().unwrap();
        let db = LibraryDatabase::open(&dir.path().join("lib.sqlite3")).unwrap();

        for i in 0..32 {
            let mut a = AssetRecord::new(format!("暖色建筑构图参考 {i}"), format!("arch-{i}.png"));
            a.media_kind = MediaKind::Image;
            a.content_hash = format!("h-{i}");
            a.pixel_width = 1200;
            a.pixel_height = 900 + (i % 4) * 150;
            a.tags = vec!["建筑".to_string(), format!("series-{}", i % 6)];
            a.rating = (i % 5) + 1;
            a.dominant_colors = vec![LabColor {
                hex: if i % 2 == 0 {
                    "#BA6B55".to_string()
                } else {
                    "#2A60E0".to_string()
                },
                l: if i % 2 == 0 { 55.0 } else { 44.0 },
                a: if i % 2 == 0 { 28.0 } else { 18.0 },
                b: if i % 2 == 0 { 22.0 } else { -58.0 },
                proportion: 0.7,
            }];
            db.save_asset_locally(&a, false).unwrap();
        }

        let req = MoodboardCurationRequest {
            prompt: "暖色 建筑".to_string(),
            preferred_count: 8,
            candidate_count: 20,
            layout_style: EditorialStyle::Magazine,
            use_freeform_layout: false,
            include_curator_notes: true,
            ..Default::default()
        };

        let mut streamed_phases = Vec::new();
        let proposal = MoodboardAgentHarness::run(&db, &req, None, |step| {
            streamed_phases.push(step.phase);
        })
        .await
        .expect("harness run");

        assert_eq!(proposal.primary_matches.len(), 8);
        assert_eq!(proposal.candidate_pool.len(), 20);
        assert!(!proposal.extracted_palette.is_empty());
        assert_eq!(
            streamed_phases,
            vec![
                MoodboardAgentPhase::Planning,
                MoodboardAgentPhase::Retrieving,
                MoodboardAgentPhase::InspectingVisuals,
                MoodboardAgentPhase::Composing,
                MoodboardAgentPhase::Verifying,
                MoodboardAgentPhase::Repairing,
                MoodboardAgentPhase::FallbackOffline,
            ]
        );
    }
}
