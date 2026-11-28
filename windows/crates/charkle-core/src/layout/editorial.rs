//! Deterministic O(N) Auto Editorial Bento / Masonry layout solver matching macOS
//! `Sources/CharkleCanvas/EditorialLayoutSolver.swift` coordinate-for-coordinate across
//! `balanced`, `magazine` (up to 3 two-column Hero spans), and `compact`, plus
//! Smart Auto-Layout `reflow_nodes_inside_group_frame` and zero-jump `freeze_into_freeform`.

use std::collections::{HashMap, HashSet};

use serde::{Deserialize, Serialize};
use uuid::Uuid;

use crate::models::core::AssetRecord;
use crate::models::moodboard::{
    AutoLayoutConfig, BoardLayoutMode, BoardNode, BoardNodeKind, BoardPoint, BoardRect,
    EditorialStyle, MoodboardDocument, NormalizedCropRect,
};
use crate::wire::swift_codec::format_swift_uuid;

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct EditorialSize {
    pub width: f64,
    pub height: f64,
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct EditorialLayoutResult {
    pub frames: HashMap<String, BoardRect>,
    pub ordered_node_ids: Vec<String>,
    pub content_size: EditorialSize,
    pub column_width: f64,
    pub column_count: usize,
}

impl EditorialLayoutResult {
    pub fn frame_for(&self, id: Uuid) -> Option<BoardRect> {
        self.frames.get(&format_swift_uuid(&id)).copied()
    }
}

pub struct EditorialLayoutSolver;

impl EditorialLayoutSolver {
    pub fn solve(
        nodes: &[BoardNode],
        config: AutoLayoutConfig,
        container_width: f64,
        assets_by_id: &HashMap<Uuid, AssetRecord>,
        padding: f64,
    ) -> EditorialLayoutResult {
        let safe_container_w = if container_width.is_finite() && container_width > 0.0 {
            container_width
        } else {
            1120.0
        };
        let safe_padding = if padding.is_finite() {
            padding.clamp(0.0, 240.0)
        } else {
            28.0
        };
        let safe_spacing = if config.spacing.is_finite() {
            config.spacing.clamp(0.0, 120.0)
        } else {
            16.0
        };

        let effective_padding = match config.style {
            EditorialStyle::Magazine => (safe_padding + 10.0).max(36.0),
            EditorialStyle::Balanced => safe_padding.max(22.0),
            EditorialStyle::Compact => safe_padding.clamp(12.0, 14.0),
        };
        let usable_width = (safe_container_w - effective_padding * 2.0).max(320.0);
        let style_spacing = match config.style {
            EditorialStyle::Magazine => (safe_spacing + 10.0).max(26.0),
            EditorialStyle::Balanced => safe_spacing.max(15.0),
            EditorialStyle::Compact => 6.0,
        };

        let cols: usize = match config.style {
            EditorialStyle::Magazine => {
                (((usable_width + style_spacing) / 280.0) as i32).clamp(2, 3) as usize
            }
            EditorialStyle::Balanced => {
                (((usable_width + style_spacing) / 220.0) as i32).clamp(3, 4) as usize
            }
            EditorialStyle::Compact => {
                (((usable_width + style_spacing) / 142.0) as i32).clamp(5, 7) as usize
            }
        };

        let col_width = (usable_width - style_spacing * ((cols - 1) as f64)) / (cols as f64);

        let mut sorted_nodes: Vec<&BoardNode> = nodes.iter().collect();
        sorted_nodes.sort_by(|lhs, rhs| {
            lhs.editorial_order
                .cmp(&rhs.editorial_order)
                .then_with(|| format_swift_uuid(&lhs.id).cmp(&format_swift_uuid(&rhs.id)))
        });

        let mut column_heights = vec![effective_padding; cols];
        let mut frames: HashMap<String, BoardRect> = HashMap::with_capacity(sorted_nodes.len());

        let mut hero_quota: i32 = if config.style == EditorialStyle::Magazine {
            3
        } else {
            0
        };
        let mut magazine_hero_assigned = false;

        for (index, node) in sorted_nodes.iter().enumerate() {
            let key = format_swift_uuid(&node.id);
            match &node.kind {
                BoardNodeKind::GroupFrame { .. } => {
                    let max_y = column_heights
                        .iter()
                        .copied()
                        .fold(effective_padding, f64::max);
                    let raw_h = if node.frame.height.is_finite() && node.frame.height > 0.0 {
                        node.frame.height
                    } else {
                        60.0
                    };
                    let header_height = raw_h.clamp(54.0, 86.0);
                    frames.insert(
                        key,
                        BoardRect::new(effective_padding, max_y, usable_width, header_height),
                    );
                    let next_y = max_y + header_height + style_spacing;
                    column_heights.fill(next_y);
                }
                BoardNodeKind::PaletteStrip { .. } => {
                    let max_y = column_heights
                        .iter()
                        .copied()
                        .fold(effective_padding, f64::max);
                    let strip_height = if config.style == EditorialStyle::Compact {
                        56.0
                    } else {
                        76.0
                    };
                    frames.insert(
                        key,
                        BoardRect::new(effective_padding, max_y, usable_width, strip_height),
                    );
                    let next_y = max_y + strip_height + style_spacing;
                    column_heights.fill(next_y);
                }
                BoardNodeKind::Note {
                    text, font_size, ..
                } => {
                    let col = shortest_column_index(&column_heights);
                    let x = effective_padding + (col as f64) * (col_width + style_spacing);
                    let y = column_heights[col];
                    let char_count = text.chars().count();
                    let estimated_lines = (((char_count as f64) / 18.0) as i32 + 2).clamp(3, 10);
                    let safe_font = if font_size.is_finite() {
                        font_size.clamp(10.0, 48.0)
                    } else {
                        14.0
                    };
                    let height =
                        ((estimated_lines as f64) * (safe_font * 1.45).max(18.0) + 42.0).max(124.0);
                    frames.insert(key, BoardRect::new(x, y, col_width, height));
                    column_heights[col] = y + height + style_spacing;
                }
                BoardNodeKind::AssetRef {
                    asset_id,
                    crop,
                    weight,
                    ..
                } => {
                    let aspect =
                        resolved_aspect_ratio(*asset_id, *crop, assets_by_id, config.style);
                    let wants_hero = if config.style == EditorialStyle::Magazine
                        && cols >= 3
                        && hero_quota > 0
                    {
                        (!magazine_hero_assigned && index == 0)
                            || *weight >= 2
                            || (index > 0 && index % 5 == 0)
                    } else {
                        false
                    };

                    if wants_hero {
                        if let Some(span_start) = best_two_column_span_start(&column_heights) {
                            hero_quota -= 1;
                            magazine_hero_assigned = true;
                            let span_width = col_width * 2.0 + style_spacing;
                            let clamped_aspect = aspect.clamp(0.85, 1.85);
                            let height = span_width / clamped_aspect;
                            let y = column_heights[span_start].max(column_heights[span_start + 1]);
                            let x = effective_padding
                                + (span_start as f64) * (col_width + style_spacing);
                            frames.insert(key, BoardRect::new(x, y, span_width, height));
                            let next_y = y + height + style_spacing;
                            column_heights[span_start] = next_y;
                            column_heights[span_start + 1] = next_y;
                            continue;
                        }
                    }

                    let col = shortest_column_index(&column_heights);
                    let x = effective_padding + (col as f64) * (col_width + style_spacing);
                    let y = column_heights[col];
                    let height = col_width / aspect;
                    frames.insert(key, BoardRect::new(x, y, col_width, height));
                    column_heights[col] = y + height + style_spacing;
                }
            }
        }

        let max_height = column_heights
            .iter()
            .copied()
            .fold(effective_padding, f64::max)
            + effective_padding
            + 88.0;

        EditorialLayoutResult {
            frames,
            ordered_node_ids: sorted_nodes
                .iter()
                .map(|n| format_swift_uuid(&n.id))
                .collect(),
            content_size: EditorialSize {
                width: safe_container_w,
                height: max_height.max(480.0),
            },
            column_width: col_width,
            column_count: cols,
        }
    }

    /// Smart Auto-Layout GroupFrame reflow matching `EditorialLayoutSolver.reflowNodesInsideGroupFrame`.
    pub fn reflow_nodes_inside_group_frame(
        group_rect: BoardRect,
        child_nodes: &[BoardNode],
        assets_by_id: &HashMap<Uuid, AssetRecord>,
        header_height: f64,
        padding: f64,
        spacing: f64,
    ) -> HashMap<Uuid, BoardRect> {
        if child_nodes.is_empty() {
            return HashMap::new();
        }
        let inner_x = group_rect.x + padding;
        let inner_y = group_rect.y + header_height + padding * 0.6;
        let inner_w = (group_rect.width - padding * 2.0).max(80.0);
        let inner_h = (group_rect.height - header_height - padding * 1.6).max(60.0);

        fn quantize_coord(value: f64, step: f64) -> i64 {
            if value.is_finite() {
                (value / step)
                    .round()
                    .clamp(i64::MIN as f64, i64::MAX as f64) as i64
            } else {
                i64::MAX
            }
        }
        let mut ordered: Vec<&BoardNode> = child_nodes.iter().collect();
        ordered.sort_by(|lhs, rhs| {
            quantize_coord(lhs.frame.min_y(), 24.0)
                .cmp(&quantize_coord(rhs.frame.min_y(), 24.0))
                .then_with(|| {
                    quantize_coord(lhs.frame.min_x(), 12.0)
                        .cmp(&quantize_coord(rhs.frame.min_x(), 12.0))
                })
                .then_with(|| lhs.editorial_order.cmp(&rhs.editorial_order))
                .then_with(|| lhs.id.cmp(&rhs.id))
        });

        let ratios: Vec<f64> = ordered
            .iter()
            .map(|node| match node.kind {
                BoardNodeKind::AssetRef { asset_id, crop, .. } => {
                    resolved_aspect_ratio(asset_id, crop, assets_by_id, EditorialStyle::Balanced)
                }
                _ => {
                    let raw = if node.frame.width.is_finite() && node.frame.height.is_finite() {
                        node.frame.width / node.frame.height.max(1.0)
                    } else {
                        1.25
                    };
                    if raw.is_finite() {
                        raw.clamp(0.65, 2.2)
                    } else {
                        1.25
                    }
                }
            })
            .collect();

        let n = ordered.len();
        let mut best_frames: HashMap<Uuid, BoardRect> = HashMap::new();
        let mut best_coverage = -1.0_f64;

        for row_count in 1..=n.min(6) {
            let total_gaps_y = spacing * ((row_count - 1) as f64);
            let avail_h = (inner_h - total_gaps_y).max(32.0);
            let total_ratio: f64 = ratios.iter().sum();
            let target_row_ratio = total_ratio / (row_count as f64);

            let mut rows: Vec<Vec<usize>> = Vec::new();
            let mut current_row: Vec<usize> = Vec::new();
            let mut current_sum = 0.0_f64;
            for (idx, &ratio) in ratios.iter().enumerate().take(n) {
                current_row.push(idx);
                current_sum += ratio;
                let remaining_rows = row_count.saturating_sub(rows.len()).saturating_sub(1);
                let remaining_items = n.saturating_sub(idx).saturating_sub(1);
                if remaining_rows > 0
                    && (remaining_items == remaining_rows || current_sum >= target_row_ratio * 0.88)
                {
                    rows.push(current_row);
                    current_row = Vec::new();
                    current_sum = 0.0;
                }
            }
            if !current_row.is_empty() {
                rows.push(current_row);
            }

            let mut natural_row_heights: Vec<f64> = Vec::with_capacity(rows.len());
            for r in &rows {
                let gaps_x = spacing * (r.len().saturating_sub(1) as f64);
                let sum_r: f64 = r.iter().map(|&idx| ratios[idx]).sum();
                let row_h = ((inner_w - gaps_x) / sum_r.max(0.1)).max(24.0);
                natural_row_heights.push(row_h);
            }

            let sum_natural_h: f64 = natural_row_heights.iter().sum();
            let vertical_scale = if sum_natural_h > avail_h {
                avail_h / sum_natural_h
            } else {
                1.0
            };

            let mut candidate: HashMap<Uuid, BoardRect> = HashMap::with_capacity(n);
            let mut total_painted_area = 0.0_f64;
            let mut cursor_y = inner_y;

            for (r_idx, r) in rows.iter().enumerate() {
                let row_h = (natural_row_heights[r_idx] * vertical_scale).max(24.0);
                let gaps_x = spacing * (r.len().saturating_sub(1) as f64);
                let raw_row_w = r.iter().map(|&idx| ratios[idx] * row_h).sum::<f64>() + gaps_x;
                let horiz_scale = if raw_row_w > inner_w {
                    (inner_w - gaps_x) / (raw_row_w - gaps_x).max(1.0)
                } else {
                    1.0
                };
                let effective_h = row_h * horiz_scale;

                let mut cursor_x = inner_x;
                for &item_idx in r {
                    let w = (ratios[item_idx] * effective_h).max(24.0);
                    let rect = BoardRect::new(cursor_x, cursor_y, w, effective_h);
                    candidate.insert(ordered[item_idx].id, rect);
                    total_painted_area += w * effective_h;
                    cursor_x += w + spacing;
                }
                cursor_y += effective_h + spacing;
            }

            if total_painted_area > best_coverage {
                best_coverage = total_painted_area;
                best_frames = candidate;
            }
        }

        best_frames
    }

    /// Freezes the exact computed Auto Editorial rects onto every node's `frame` and transitions
    /// the document to `BoardLayoutMode::Freeform` with zero coordinate jump.
    pub fn freeze_into_freeform(
        document: &MoodboardDocument,
        container_width: f64,
        assets_by_id: &HashMap<Uuid, AssetRecord>,
    ) -> MoodboardDocument {
        let mut copy = document.clone();
        let config = match document.mode {
            BoardLayoutMode::AutoEditorial(cfg) => cfg,
            BoardLayoutMode::Freeform => AutoLayoutConfig::default(),
        };
        let solved = Self::solve(&document.nodes, config, container_width, assets_by_id, 28.0);
        for node in &mut copy.nodes {
            if let Some(rect) = solved.frame_for(node.id) {
                node.frame = rect;
            }
        }
        copy.mode = BoardLayoutMode::Freeform;
        copy.viewport_zoom = 1.0;
        copy.viewport_center = BoardPoint::new(
            solved.content_size.width * 0.5,
            (solved.content_size.height * 0.5).min(420.0),
        );
        copy
    }

    /// Re-tidies either selected nodes (when >= 2 selected) or the entire board while staying Freeform.
    pub fn tidy_nodes_in_freeform(
        document: &MoodboardDocument,
        selected_node_ids: &HashSet<Uuid>,
        assets_by_id: &HashMap<Uuid, AssetRecord>,
    ) -> MoodboardDocument {
        let mut copy = document.clone();
        let target_nodes: Vec<BoardNode> = if selected_node_ids.len() >= 2 {
            copy.nodes
                .iter()
                .filter(|n| selected_node_ids.contains(&n.id))
                .cloned()
                .collect()
        } else {
            copy.nodes.clone()
        };
        if target_nodes.is_empty() {
            return copy;
        }

        let min_x = target_nodes
            .iter()
            .map(|n| n.frame.min_x())
            .fold(f64::INFINITY, f64::min);
        let min_y = target_nodes
            .iter()
            .map(|n| n.frame.min_y())
            .fold(f64::INFINITY, f64::min);
        let max_x = target_nodes
            .iter()
            .map(|n| n.frame.max_x())
            .fold(f64::NEG_INFINITY, f64::max);
        let origin_x = if min_x.is_finite() { min_x } else { 40.0 };
        let origin_y = if min_y.is_finite() { min_y } else { 40.0 };
        let span = if max_x.is_finite() {
            max_x - origin_x + 56.0
        } else {
            1080.0
        };
        let width = span.clamp(760.0, 1440.0);

        let solved = Self::solve(
            &target_nodes,
            AutoLayoutConfig {
                columns: 4,
                spacing: 16.0,
                style: EditorialStyle::Balanced,
                show_palette_strip: true,
            },
            width,
            assets_by_id,
            0.0,
        );

        for node in &mut copy.nodes {
            if let Some(rect) = solved.frame_for(node.id) {
                node.frame = BoardRect::new(
                    origin_x + rect.x,
                    origin_y + rect.y,
                    rect.width,
                    rect.height,
                );
            }
        }
        copy
    }
}

fn resolved_aspect_ratio(
    asset_id: Uuid,
    crop: Option<NormalizedCropRect>,
    assets_by_id: &HashMap<Uuid, AssetRecord>,
    style: EditorialStyle,
) -> f64 {
    let mut ratio = assets_by_id
        .get(&asset_id)
        .map(AssetRecord::aspect_ratio)
        .filter(|v| v.is_finite() && *v > 0.05)
        .unwrap_or(1.25);
    if let Some(c) = crop {
        if c.width.is_finite() && c.height.is_finite() && c.width > 0.05 && c.height > 0.05 {
            ratio *= c.width / c.height;
        }
    }
    if !ratio.is_finite() {
        ratio = 1.25;
    }
    match style {
        EditorialStyle::Compact => ratio.clamp(0.80, 1.32),
        EditorialStyle::Magazine => ratio.clamp(0.56, 2.15),
        EditorialStyle::Balanced => ratio.clamp(0.64, 1.85),
    }
}

fn shortest_column_index(heights: &[f64]) -> usize {
    if heights.is_empty() {
        return 0;
    }
    let mut best_idx = 0;
    let mut best_val = heights[0];
    for (i, &val) in heights.iter().enumerate().skip(1) {
        if val < best_val - 1.0 {
            best_val = val;
            best_idx = i;
        }
    }
    best_idx
}

fn best_two_column_span_start(heights: &[f64]) -> Option<usize> {
    if heights.len() < 2 {
        return None;
    }
    let mut best_start = 0;
    let mut best_max = heights[0].max(heights[1]);
    for i in 1..(heights.len() - 1) {
        let pair_max = heights[i].max(heights[i + 1]);
        if pair_max < best_max - 1.0 {
            best_max = pair_max;
            best_start = i;
        }
    }
    Some(best_start)
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::models::core::MediaKind;
    use chrono::Utc;

    fn make_asset(id: Uuid, w: i32, h: i32) -> AssetRecord {
        let mut a = AssetRecord::new("Test", "test.png");
        a.id = id;
        a.media_kind = MediaKind::Image;
        a.pixel_width = w;
        a.pixel_height = h;
        a
    }

    fn make_asset_node(id: Uuid, asset_id: Uuid, order: i32, weight: i32) -> BoardNode {
        BoardNode {
            id,
            kind: BoardNodeKind::AssetRef {
                asset_id,
                crop: None,
                weight,
                autoplay_loop: false,
            },
            frame: BoardRect::default(),
            z_index: order,
            rotation_degrees: 0.0,
            flip_horizontal: false,
            flip_vertical: false,
            is_locked: false,
            editorial_order: order,
            updated_at: Utc::now(),
        }
    }

    #[test]
    fn magazine_assigns_up_to_three_two_column_heroes_and_matches_macos_columns() {
        let mut assets = HashMap::new();
        let mut nodes = Vec::new();
        for i in 0..12 {
            let aid = Uuid::from_u128(100 + i as u128);
            let nid = Uuid::from_u128(200 + i as u128);
            assets.insert(aid, make_asset(aid, 1200, 900));
            nodes.push(make_asset_node(nid, aid, i, if i == 3 { 2 } else { 1 }));
        }

        let res = EditorialLayoutSolver::solve(
            &nodes,
            AutoLayoutConfig {
                columns: 3,
                spacing: 16.0,
                style: EditorialStyle::Magazine,
                show_palette_strip: true,
            },
            1120.0,
            &assets,
            28.0,
        );

        // Magazine at 1120px: effectivePadding=38, usable=1044, spacing=26 -> cols=3
        assert_eq!(res.column_count, 3);
        let hero_count = nodes
            .iter()
            .filter(|n| {
                res.frame_for(n.id)
                    .is_some_and(|r| r.width > res.column_width * 1.5)
            })
            .count();
        assert_eq!(hero_count, 3);
    }

    #[test]
    fn balanced_compact_group_reflow_and_zero_jump_freeze_stay_consistent() {
        let mut assets = HashMap::new();
        let mut nodes = Vec::new();
        for i in 0..8 {
            let aid = Uuid::from_u128(300 + i as u128);
            let nid = Uuid::from_u128(400 + i as u128);
            assets.insert(aid, make_asset(aid, 800, 1000));
            nodes.push(make_asset_node(nid, aid, i, 1));
        }

        let balanced = EditorialLayoutSolver::solve(
            &nodes,
            AutoLayoutConfig {
                columns: 4,
                spacing: 16.0,
                style: EditorialStyle::Balanced,
                show_palette_strip: true,
            },
            1120.0,
            &assets,
            28.0,
        );
        assert_eq!(balanced.column_count, 4);

        let compact = EditorialLayoutSolver::solve(
            &nodes,
            AutoLayoutConfig {
                columns: 6,
                spacing: 8.0,
                style: EditorialStyle::Compact,
                show_palette_strip: true,
            },
            1120.0,
            &assets,
            28.0,
        );
        assert_eq!(compact.column_count, 7);

        // Zero-jump freeze preserves exact frames
        let mut doc = MoodboardDocument::new("Freeze Test");
        doc.mode = BoardLayoutMode::AutoEditorial(AutoLayoutConfig {
            columns: 4,
            spacing: 16.0,
            style: EditorialStyle::Balanced,
            show_palette_strip: true,
        });
        doc.nodes = nodes.clone();
        let frozen = EditorialLayoutSolver::freeze_into_freeform(&doc, 1120.0, &assets);
        assert_eq!(frozen.mode, BoardLayoutMode::Freeform);
        for n in &frozen.nodes {
            assert_eq!(Some(n.frame), balanced.frame_for(n.id));
        }

        // Smart GroupFrame reflow keeps every child strictly inside groupRect
        let group = BoardRect::new(40.0, 40.0, 540.0, 420.0);
        let reflowed = EditorialLayoutSolver::reflow_nodes_inside_group_frame(
            group,
            &nodes[..5],
            &assets,
            38.0,
            12.0,
            10.0,
        );
        assert_eq!(reflowed.len(), 5);
        for rect in reflowed.values() {
            assert!(rect.min_x() >= group.min_x());
            assert!(rect.min_y() >= group.min_y() + 38.0);
            assert!(rect.max_x() <= group.max_x() + 1.0);
            assert!(rect.max_y() <= group.max_y() + 1.0);
        }
    }
}
