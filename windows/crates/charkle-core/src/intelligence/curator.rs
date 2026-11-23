//! MMR (Maximal Marginal Relevance) visual + semantic + color moodboard curator
//! and pluggable `IntelligenceEngine` trait seam (allowing M5 Cloud AI / TypeSafe Jev to plug in).

use std::collections::{HashMap, HashSet};

use async_trait::async_trait;
use uuid::Uuid;

use crate::db::{search_text, LibraryDatabase};
use crate::error::CoreResult;
use crate::models::core::{AssetRecord, FilterCriteria, LabColor, ScoredAsset};
use crate::models::media::cosine_similarity;
use crate::models::moodboard::MoodboardCurationRequest;

/// Pluggable AI / Visual Intelligence seam.
/// M4 uses `LocalIntelligenceEngine` (FTS5 + CIELAB ΔE + local embeddings + MMR);
/// M5 plugs in Cloud AI & TypeSafe Jev visual reranking through this exact trait.
#[async_trait]
pub trait IntelligenceEngine: Send + Sync {
    fn is_cloud_enabled(&self) -> bool {
        false
    }

    async fn expand_prompt_terms(&self, prompt: &str) -> Vec<String> {
        default_expand_prompt(prompt)
    }

    async fn rerank_candidates(&self, _prompt: &str, scored: Vec<ScoredAsset>) -> Vec<ScoredAsset> {
        scored
    }
}

#[derive(Debug, Default, Clone, Copy)]
pub struct LocalIntelligenceEngine;

#[async_trait]
impl IntelligenceEngine for LocalIntelligenceEngine {}

fn default_expand_prompt(prompt: &str) -> Vec<String> {
    let trimmed = prompt.trim();
    if trimmed.is_empty() {
        return Vec::new();
    }
    let mut terms: Vec<String> = trimmed
        .split(|c: char| {
            c.is_whitespace() || matches!(c, ',' | '，' | '、' | '/' | '·' | ';' | '；')
        })
        .map(str::trim)
        .filter(|s| !s.is_empty())
        .map(|s| s.to_lowercase())
        .collect();
    terms.sort();
    terms.dedup();
    terms
}

/// Computes CIE76 ΔE perceptual distance between two CIELAB colors.
pub fn lab_delta_e(a: &LabColor, b: &LabColor) -> f64 {
    let dl = a.l - b.l;
    let da = a.a - b.a;
    let db = a.b - b.b;
    (dl * dl + da * da + db * db).sqrt()
}

/// Ranks library assets using FTS5, CIELAB ΔE palette harmony, seed visual/vector similarity,
/// and MMR diversity penalty to produce primary board picks + 20–40 ranked replacement candidates.
pub struct MoodboardCurator;

impl MoodboardCurator {
    pub fn curate_local(
        db: &LibraryDatabase,
        request: &MoodboardCurationRequest,
        expanded_terms: &[String],
    ) -> CoreResult<(Vec<ScoredAsset>, Vec<ScoredAsset>, Vec<LabColor>)> {
        let all_assets = db.fetch_assets(&FilterCriteria::default(), None)?;
        let folders = db.fetch_folders()?;

        // Expand scoped folders recursively
        let scope_folder_ids: HashSet<Uuid> = if request.scope_folder_ids.is_empty() {
            HashSet::new()
        } else {
            let mut allowed: HashSet<Uuid> = request.scope_folder_ids.iter().copied().collect();
            let mut changed = true;
            while changed {
                changed = false;
                for f in &folders {
                    if let Some(pid) = f.parent_id {
                        if allowed.contains(&pid) && allowed.insert(f.id) {
                            changed = true;
                        }
                    }
                }
            }
            allowed
        };

        let excluded: HashSet<Uuid> = request.excluded_asset_ids.iter().copied().collect();
        let seed_set: HashSet<Uuid> = request.seed_asset_ids.iter().copied().collect();
        let locked_set: HashSet<Uuid> = request.locked_asset_ids.iter().copied().collect();
        let required_tags: Vec<String> = request
            .required_tags
            .iter()
            .map(|t| search_text::normalize(t))
            .filter(|t| !t.is_empty())
            .collect();

        // Collect seed profiles (tags, colors, optional embeddings)
        let seed_assets: Vec<&AssetRecord> = all_assets
            .iter()
            .filter(|a| seed_set.contains(&a.id))
            .collect();

        let mut seed_tags: HashSet<String> = HashSet::new();
        let mut seed_colors: Vec<LabColor> = Vec::new();
        let mut seed_vectors: Vec<Vec<f32>> = Vec::new();
        for sa in &seed_assets {
            for t in &sa.tags {
                seed_tags.insert(search_text::normalize(t));
            }
            seed_colors.extend(sa.dominant_colors.iter().take(3).cloned());
            if let Ok(Some(av)) = db.vector(sa.id) {
                if let Some(emb) = av.embedding {
                    seed_vectors.push(emb);
                }
            }
        }

        let target_palette: Vec<LabColor> = if !request.target_palette.is_empty() {
            request.target_palette.clone()
        } else {
            seed_colors.clone()
        };

        // Optional FTS5 boost set
        let fts_hits: HashSet<Uuid> = if !request.prompt.trim().is_empty() {
            let criteria = FilterCriteria {
                search_query: request.prompt.clone(),
                ..Default::default()
            };
            db.fetch_assets(&criteria, None)
                .unwrap_or_default()
                .into_iter()
                .map(|a| a.id)
                .collect()
        } else {
            HashSet::new()
        };

        let tolerance = request.color_tolerance.clamp(8.0, 65.0);
        let mut scored: Vec<ScoredAsset> = Vec::new();

        for asset in all_assets {
            if asset.is_trashed {
                continue;
            }
            if excluded.contains(&asset.id) && !locked_set.contains(&asset.id) {
                continue;
            }
            if !scope_folder_ids.is_empty()
                && !seed_set.contains(&asset.id)
                && !locked_set.contains(&asset.id)
            {
                let in_scope = asset
                    .folder_id
                    .is_some_and(|fid| scope_folder_ids.contains(&fid));
                if !in_scope {
                    continue;
                }
            }
            if !required_tags.is_empty()
                && !seed_set.contains(&asset.id)
                && !locked_set.contains(&asset.id)
            {
                let asset_tags: HashSet<String> = asset
                    .tags
                    .iter()
                    .map(|t| search_text::normalize(t))
                    .collect();
                if !required_tags.iter().all(|rt| asset_tags.contains(rt)) {
                    continue;
                }
            }

            let mut score = 0.20_f64;
            let mut reasons: Vec<String> = Vec::new();

            if locked_set.contains(&asset.id) {
                score += 2.0;
                reasons.push("已锁定保留".to_string());
            }
            if seed_set.contains(&asset.id) {
                score += 1.2;
                reasons.push("种子参考素材".to_string());
            }

            // Text / FTS5 / prompt term overlap
            if fts_hits.contains(&asset.id) {
                score += 0.65;
                reasons.push("主题关键词匹配".to_string());
            } else if !expanded_terms.is_empty() {
                let hay = format!(
                    "{} {} {} {} {}",
                    asset.title,
                    asset.notes,
                    asset.tags.join(" "),
                    asset.ocr_text.as_deref().unwrap_or(""),
                    asset.ai_description.as_deref().unwrap_or("")
                )
                .to_lowercase();
                let hits = expanded_terms
                    .iter()
                    .filter(|t| hay.contains(t.as_str()))
                    .count();
                if hits > 0 {
                    score += (hits as f64 / expanded_terms.len() as f64) * 0.55;
                    reasons.push("语义标签契合".to_string());
                }
            }

            // CIELAB ΔE palette harmony
            if !target_palette.is_empty() && !asset.dominant_colors.is_empty() {
                let mut best_de = f64::INFINITY;
                for target in &target_palette {
                    for c in &asset.dominant_colors {
                        best_de = best_de.min(lab_delta_e(target, c));
                    }
                }
                if best_de <= tolerance {
                    let color_bonus = (1.0 - (best_de / tolerance)).clamp(0.0, 1.0) * 0.6;
                    score += color_bonus;
                    reasons.push("色彩和谐".to_string());
                }
            }

            // Seed tag overlap
            if !seed_tags.is_empty() && !seed_set.contains(&asset.id) {
                let overlap = asset
                    .tags
                    .iter()
                    .filter(|t| seed_tags.contains(&search_text::normalize(t)))
                    .count();
                if overlap > 0 {
                    score += (overlap as f64 * 0.15).min(0.45);
                    reasons.push("同主题标签".to_string());
                }
            }

            // Embedding cosine similarity against seed vectors
            if !seed_vectors.is_empty() && !seed_set.contains(&asset.id) {
                if let Ok(Some(av)) = db.vector(asset.id) {
                    if let Some(vec) = av.embedding {
                        let best_cos = seed_vectors
                            .iter()
                            .filter_map(|sv| cosine_similarity(sv, &vec).map(f64::from))
                            .fold(0.0_f64, f64::max);
                        if best_cos > 0.25 {
                            score += best_cos * 0.5;
                            reasons.push("视觉向量相近".to_string());
                        }
                    }
                }
            }

            // Quality prior (user rating + media richness)
            if asset.rating > 0 {
                score += (asset.rating as f64) * 0.04;
            }
            if reasons.is_empty() {
                reasons.push("构图与材质补充".to_string());
            }

            scored.push(ScoredAsset {
                asset,
                score,
                match_reasons: reasons,
            });
        }

        // Initial descending relevance sort (deterministic tie-break by id)
        scored.sort_by(|a, b| {
            b.score
                .partial_cmp(&a.score)
                .unwrap_or(std::cmp::Ordering::Equal)
                .then_with(|| a.asset.id.cmp(&b.asset.id))
        });

        let primary_target = request.preferred_count.clamp(1, 36);
        let candidate_target = request.candidate_count.clamp(12, 48);

        // Apply MMR (Maximal Marginal Relevance) diversity selection for primary picks
        let primary = select_mmr_diverse(&scored, primary_target, &locked_set, 0.72);
        let primary_ids: HashSet<Uuid> = primary.iter().map(|s| s.asset.id).collect();

        let candidates: Vec<ScoredAsset> = scored
            .into_iter()
            .filter(|s| !primary_ids.contains(&s.asset.id))
            .take(candidate_target)
            .collect();

        let palette = extract_board_palette(&primary, &request.target_palette);
        Ok((primary, candidates, palette))
    }
}

/// Maximal Marginal Relevance (MMR) selection balancing relevance and visual/tag diversity
/// so generated moodboards avoid near-duplicate clusters.
fn select_mmr_diverse(
    ranked: &[ScoredAsset],
    limit: usize,
    locked: &HashSet<Uuid>,
    lambda: f64,
) -> Vec<ScoredAsset> {
    if ranked.len() <= limit {
        return ranked.to_vec();
    }

    let mut selected: Vec<ScoredAsset> = Vec::with_capacity(limit);
    let mut used = vec![false; ranked.len()];

    // Always keep explicitly locked assets first
    for (i, item) in ranked.iter().enumerate() {
        if locked.contains(&item.asset.id) && selected.len() < limit {
            used[i] = true;
            selected.push(item.clone());
        }
    }

    let max_rel = ranked.first().map(|s| s.score.max(0.001)).unwrap_or(1.0);

    while selected.len() < limit {
        let mut best_idx = None;
        let mut best_mmr = f64::NEG_INFINITY;

        for (i, cand) in ranked.iter().enumerate() {
            if used[i] {
                continue;
            }
            let norm_rel = cand.score / max_rel;
            let max_sim = selected
                .iter()
                .map(|s| pairwise_asset_similarity(&cand.asset, &s.asset))
                .fold(0.0_f64, f64::max);
            let mmr = lambda * norm_rel - (1.0 - lambda) * max_sim;
            if mmr > best_mmr {
                best_mmr = mmr;
                best_idx = Some(i);
            }
        }

        match best_idx {
            Some(idx) => {
                used[idx] = true;
                selected.push(ranked[idx].clone());
            }
            None => break,
        }
    }

    selected
}

fn pairwise_asset_similarity(a: &AssetRecord, b: &AssetRecord) -> f64 {
    let mut sim = 0.0_f64;

    // Color similarity via ΔE
    if let (Some(ca), Some(cb)) = (a.dominant_colors.first(), b.dominant_colors.first()) {
        let de = lab_delta_e(ca, cb);
        sim += (1.0 - (de / 45.0).min(1.0)) * 0.55;
    }

    // Tag Jaccard similarity
    if !a.tags.is_empty() && !b.tags.is_empty() {
        let ta: HashSet<String> = a.tags.iter().map(|t| t.to_lowercase()).collect();
        let tb: HashSet<String> = b.tags.iter().map(|t| t.to_lowercase()).collect();
        let inter = ta.intersection(&tb).count() as f64;
        let union = ta.union(&tb).count().max(1) as f64;
        sim += (inter / union) * 0.30;
    }

    // Same folder slight redundancy signal
    if a.folder_id.is_some() && a.folder_id == b.folder_id {
        sim += 0.15;
    }

    sim.min(1.0)
}

/// Extracts up to 6 distinct board palette swatches from curated primary assets.
pub fn extract_board_palette(
    primary: &[ScoredAsset],
    explicit_palette: &[LabColor],
) -> Vec<LabColor> {
    let mut bucket: HashMap<String, (LabColor, f64)> = HashMap::new();
    for c in explicit_palette {
        let key = c.hex.to_uppercase();
        bucket.insert(key, (c.clone(), 1.5));
    }
    for item in primary {
        for color in item.asset.dominant_colors.iter().take(2) {
            let key = color.hex.to_uppercase();
            let entry = bucket.entry(key).or_insert_with(|| (color.clone(), 0.0));
            entry.1 += color.proportion.max(0.15);
        }
    }
    let mut list: Vec<(LabColor, f64)> = bucket.into_values().collect();
    list.sort_by(|a, b| b.1.partial_cmp(&a.1).unwrap_or(std::cmp::Ordering::Equal));

    // Deduplicate visually near-identical colors (ΔE < 14)
    let mut distinct: Vec<LabColor> = Vec::new();
    for (c, _) in list {
        if distinct.iter().all(|d| lab_delta_e(d, &c) >= 14.0) {
            distinct.push(c);
            if distinct.len() >= 6 {
                break;
            }
        }
    }
    distinct
}
