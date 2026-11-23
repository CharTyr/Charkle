//! Pure Rust 1x/2x high-DPI PNG & JPEG moodboard image compositor.
//!
//! Renders resolved Auto Editorial or Freeform layouts including group frames,
//! full-resolution cropped/flipped images, styled note cards, palette strips,
//! connectors, and freehand ink strokes.

use std::collections::HashMap;
use std::io::Cursor;

use image::imageops::FilterType;
use image::{DynamicImage, ImageFormat, Rgba, RgbaImage};
use serde::{Deserialize, Serialize};
use uuid::Uuid;

use crate::error::{CoreError, CoreResult};
use crate::layout::EditorialLayoutSolver;
use crate::media::MediaPipeline;
use crate::models::core::AssetRecord;
use crate::models::media::ThumbnailTier;
use crate::models::moodboard::{
    BoardConnector, BoardLayoutMode, BoardNodeKind, BoardPoint, BoardRect, ConnectorAnchor,
    ConnectorStyle, GroupTint, MoodboardDocument, NoteStyle,
};
use crate::wire::swift_codec::format_swift_uuid;

#[derive(Debug, Clone, Copy, PartialEq, Eq, Default, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub enum BoardImageFormat {
    #[default]
    Png,
    Jpeg,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct MoodboardExportOptions {
    #[serde(default = "default_scale")]
    pub scale: f64,
    #[serde(default)]
    pub format: BoardImageFormat,
    #[serde(default = "default_true")]
    pub include_annotations: bool,
    #[serde(default = "default_true")]
    pub include_palette_strip: bool,
    #[serde(default)]
    pub dark_appearance: bool,
    #[serde(default = "default_container_width")]
    pub container_width: f64,
}

fn default_scale() -> f64 {
    2.0
}
fn default_true() -> bool {
    true
}
fn default_container_width() -> f64 {
    1120.0
}

impl Default for MoodboardExportOptions {
    fn default() -> Self {
        Self {
            scale: 2.0,
            format: BoardImageFormat::Png,
            include_annotations: true,
            include_palette_strip: true,
            dark_appearance: false,
            container_width: 1120.0,
        }
    }
}

pub struct BoardImageExporter;

impl BoardImageExporter {
    /// Renders a moodboard document into PNG or JPEG bytes at 1x or 2x DPI scale.
    pub fn render_bytes(
        document: &MoodboardDocument,
        assets_by_id: &HashMap<Uuid, AssetRecord>,
        media: &MediaPipeline,
        options: &MoodboardExportOptions,
    ) -> CoreResult<Vec<u8>> {
        let resolved = resolve_frames(document, assets_by_id, options.container_width);
        if resolved.is_empty() && document.ink_strokes.is_empty() {
            return Err(CoreError::InvalidOperation(
                "当前情绪板里没有可导出的画布内容".to_string(),
            ));
        }

        let mut min_x = f64::INFINITY;
        let mut min_y = f64::INFINITY;
        let mut max_x = f64::NEG_INFINITY;
        let mut max_y = f64::NEG_INFINITY;

        for rect in resolved.values() {
            min_x = min_x.min(rect.min_x());
            min_y = min_y.min(rect.min_y());
            max_x = max_x.max(rect.max_x());
            max_y = max_y.max(rect.max_y());
        }
        if options.include_annotations {
            for stroke in &document.ink_strokes {
                for pt in &stroke.points {
                    min_x = min_x.min(pt.x);
                    min_y = min_y.min(pt.y);
                    max_x = max_x.max(pt.x);
                    max_y = max_y.max(pt.y);
                }
            }
        }
        if !min_x.is_finite() {
            min_x = 0.0;
            min_y = 0.0;
            max_x = 800.0;
            max_y = 600.0;
        }

        let pad = 36.0;
        let top_palette_extra =
            if options.include_palette_strip && !document.extracted_palette.is_empty() {
                78.0
            } else {
                0.0
            };
        let origin_x = min_x - pad;
        let origin_y = min_y - pad - top_palette_extra;
        let logical_w = (max_x - min_x + pad * 2.0).clamp(320.0, 4800.0);
        let logical_h = (max_y - min_y + pad * 2.0 + top_palette_extra).clamp(240.0, 6400.0);

        // Cap maximum exported image side to 6400px so 2x export stays fast and RAM-safe
        let requested_scale = options.scale.clamp(1.0, 2.0);
        let max_scale = (6400.0 / logical_w.max(logical_h)).min(requested_scale);
        let scale = max_scale.max(0.5);

        let canvas_w = (logical_w * scale).round().max(1.0) as u32;
        let canvas_h = (logical_h * scale).round().max(1.0) as u32;

        let bg = if options.dark_appearance {
            Rgba([0x14, 0x15, 0x17, 255])
        } else {
            Rgba([0xF6, 0xF6, 0xF5, 255])
        };
        let mut canvas = RgbaImage::from_pixel(canvas_w, canvas_h, bg);

        let to_px = |x: f64, y: f64| -> (i32, i32) {
            (
                ((x - origin_x) * scale).round() as i32,
                ((y - origin_y) * scale).round() as i32,
            )
        };

        // Optional top Board Palette Strip
        if options.include_palette_strip && !document.extracted_palette.is_empty() {
            let strip_w = (max_x - min_x).clamp(280.0, 560.0);
            let strip_rect = BoardRect::new(min_x, min_y - 68.0, strip_w, 48.0);
            draw_palette_strip(
                &mut canvas,
                strip_rect,
                &document
                    .extracted_palette
                    .iter()
                    .take(7)
                    .map(|c| c.hex.as_str())
                    .collect::<Vec<_>>(),
                origin_x,
                origin_y,
                scale,
            );
        }

        // Order: GroupFrames first, then z_index ascending, then editorial_order
        let mut ordered_nodes = document.nodes.clone();
        ordered_nodes.sort_by(|lhs, rhs| {
            let l_grp = matches!(lhs.kind, BoardNodeKind::GroupFrame { .. });
            let r_grp = matches!(rhs.kind, BoardNodeKind::GroupFrame { .. });
            r_grp
                .cmp(&l_grp)
                .then_with(|| lhs.z_index.cmp(&rhs.z_index))
                .then_with(|| lhs.editorial_order.cmp(&rhs.editorial_order))
        });

        for node in &ordered_nodes {
            let Some(&rect) = resolved.get(&node.id) else {
                continue;
            };
            let (px, py) = to_px(rect.x, rect.y);
            let pw = (rect.width * scale).round().max(1.0) as i32;
            let ph = (rect.height * scale).round().max(1.0) as i32;

            match &node.kind {
                BoardNodeKind::GroupFrame { tint, .. } => {
                    let accent = parse_hex_rgba(group_tint_hex(*tint), 255);
                    let fill = Rgba([accent[0], accent[1], accent[2], 32]);
                    let border = Rgba([accent[0], accent[1], accent[2], 140]);
                    fill_rect_alpha(&mut canvas, px, py, pw, ph, fill);
                    stroke_rect(
                        &mut canvas,
                        px,
                        py,
                        pw,
                        ph,
                        (2.0 * scale).round().max(1.0) as i32,
                        border,
                    );
                }
                BoardNodeKind::Note { style, .. } => {
                    let (bg_hex, _fg_hex, border_hex) = note_style_hex(*style);
                    let fill = parse_hex_rgba(bg_hex, 255);
                    let border = parse_hex_rgba(border_hex, 255);
                    fill_rect_alpha(&mut canvas, px, py, pw, ph, fill);
                    stroke_rect(
                        &mut canvas,
                        px,
                        py,
                        pw,
                        ph,
                        (1.5 * scale).round().max(1.0) as i32,
                        border,
                    );
                }
                BoardNodeKind::PaletteStrip {
                    colors,
                    auto_sync_with_board,
                } => {
                    let active = if *auto_sync_with_board && !document.extracted_palette.is_empty()
                    {
                        &document.extracted_palette
                    } else {
                        colors
                    };
                    let hexes: Vec<&str> = active.iter().map(|c| c.hex.as_str()).collect();
                    draw_palette_strip(&mut canvas, rect, &hexes, origin_x, origin_y, scale);
                }
                BoardNodeKind::AssetRef { asset_id, crop, .. } => {
                    if let Some(mut img) = load_asset_image(*asset_id, assets_by_id, media) {
                        if let Some(c) = crop {
                            if c.width > 0.04 && c.height > 0.04 && c.area() < 0.99 {
                                let iw = img.width() as f64;
                                let ih = img.height() as f64;
                                let cx = (c.x * iw).round().clamp(0.0, iw - 1.0) as u32;
                                let cy = (c.y * ih).round().clamp(0.0, ih - 1.0) as u32;
                                let cw = (c.width * iw).round().clamp(1.0, iw - cx as f64) as u32;
                                let ch = (c.height * ih).round().clamp(1.0, ih - cy as f64) as u32;
                                img = img.crop_imm(cx, cy, cw, ch);
                            }
                        }
                        if node.flip_horizontal {
                            img = img.fliph();
                        }
                        if node.flip_vertical {
                            img = img.flipv();
                        }
                        let norm_rot = ((node.rotation_degrees.round() as i32) % 360 + 360) % 360;
                        if norm_rot == 90 {
                            img = img.rotate90();
                        } else if norm_rot == 180 {
                            img = img.rotate180();
                        } else if norm_rot == 270 {
                            img = img.rotate270();
                        }

                        let resized = img
                            .resize_exact(pw as u32, ph as u32, FilterType::Lanczos3)
                            .to_rgba8();
                        blit_rgba(&mut canvas, &resized, px, py);
                    } else {
                        let placeholder = if options.dark_appearance {
                            Rgba([38, 42, 48, 255])
                        } else {
                            Rgba([225, 224, 220, 255])
                        };
                        fill_rect_alpha(&mut canvas, px, py, pw, ph, placeholder);
                    }
                }
            }
        }

        // Annotations: Connectors + Ink Strokes
        if options.include_annotations {
            for conn in &document.connectors {
                if let (Some(&from_r), Some(&to_r)) = (
                    resolved.get(&conn.from_node_id),
                    resolved.get(&conn.to_node_id),
                ) {
                    draw_connector(&mut canvas, conn, from_r, to_r, origin_x, origin_y, scale);
                }
            }
            for stroke in &document.ink_strokes {
                if stroke.points.len() < 2 {
                    continue;
                }
                let alpha = (stroke.opacity.clamp(0.05, 1.0) * 255.0).round() as u8;
                let col = parse_hex_rgba(&stroke.color_hex, alpha);
                let thickness = (stroke.line_width * scale).clamp(1.0, 24.0);
                for pair in stroke.points.windows(2) {
                    let (x0, y0) = to_px(pair[0].x, pair[0].y);
                    let (x1, y1) = to_px(pair[1].x, pair[1].y);
                    draw_thick_line(
                        &mut canvas,
                        x0 as f64,
                        y0 as f64,
                        x1 as f64,
                        y1 as f64,
                        thickness,
                        col,
                        false,
                    );
                }
            }
        }

        let mut out = Vec::new();
        let dyn_img = DynamicImage::ImageRgba8(canvas);
        match options.format {
            BoardImageFormat::Png => {
                dyn_img
                    .write_to(&mut Cursor::new(&mut out), ImageFormat::Png)
                    .map_err(|e| CoreError::Media(format!("PNG encode failed: {e}")))?;
            }
            BoardImageFormat::Jpeg => {
                let rgb = dyn_img.to_rgb8();
                let mut enc = image::codecs::jpeg::JpegEncoder::new_with_quality(&mut out, 92);
                enc.encode_image(&rgb)
                    .map_err(|e| CoreError::Media(format!("JPEG encode failed: {e}")))?;
            }
        }
        Ok(out)
    }
}

pub(crate) fn resolve_frames(
    document: &MoodboardDocument,
    assets_by_id: &HashMap<Uuid, AssetRecord>,
    container_width: f64,
) -> HashMap<Uuid, BoardRect> {
    match document.mode {
        BoardLayoutMode::AutoEditorial(cfg) => {
            let solved = EditorialLayoutSolver::solve(
                &document.nodes,
                cfg,
                container_width,
                assets_by_id,
                28.0,
            );
            document
                .nodes
                .iter()
                .filter_map(|n| {
                    solved
                        .frames
                        .get(&format_swift_uuid(&n.id))
                        .map(|&r| (n.id, r))
                })
                .collect()
        }
        BoardLayoutMode::Freeform => document.nodes.iter().map(|n| (n.id, n.frame)).collect(),
    }
}

fn load_asset_image(
    asset_id: Uuid,
    assets_by_id: &HashMap<Uuid, AssetRecord>,
    media: &MediaPipeline,
) -> Option<DynamicImage> {
    if let Some(asset) = assets_by_id.get(&asset_id) {
        if let Some(orig) = media.cached_original(asset) {
            if let Ok(img) = image::open(&orig) {
                return Some(img);
            }
        }
    }
    for tier in [ThumbnailTier::Preview1400, ThumbnailTier::Grid520] {
        if let Some(thumb) = media.thumbnail_url(asset_id, tier) {
            if let Ok(img) = image::open(&thumb) {
                return Some(img);
            }
        }
    }
    None
}

pub(crate) fn note_style_hex(style: NoteStyle) -> (&'static str, &'static str, &'static str) {
    match style {
        NoteStyle::Paper => ("#FFFFFF", "#1D1F23", "#D9DBDE"),
        NoteStyle::Ink => ("#1D1F24", "#F1F2F4", "#3A3D45"),
        NoteStyle::Warm => ("#F7F0E4", "#392F22", "#C9B79C"),
        NoteStyle::Sage => ("#E8F0EA", "#203227", "#9AB5A3"),
        NoteStyle::Slate => ("#E9EEF3", "#1F2B36", "#9EB0C2"),
    }
}

pub(crate) fn group_tint_hex(tint: GroupTint) -> &'static str {
    match tint {
        GroupTint::Neutral => "#7D838B",
        GroupTint::Sand => "#B5956B",
        GroupTint::Sage => "#6B8E76",
        GroupTint::Slate => "#627A94",
        GroupTint::Terracotta => "#BA6B55",
        GroupTint::Ocean => "#4D7E97",
    }
}

pub(crate) fn is_light_hex(hex: &str) -> bool {
    let px = parse_hex_rgba(hex, 255);
    let lum = 0.299 * (px[0] as f64) + 0.587 * (px[1] as f64) + 0.114 * (px[2] as f64);
    lum >= 168.0
}

fn parse_hex_rgba(hex: &str, alpha: u8) -> Rgba<u8> {
    let clean = hex.trim().trim_start_matches('#');
    if clean.len() == 6 {
        if let (Ok(r), Ok(g), Ok(b)) = (
            u8::from_str_radix(&clean[0..2], 16),
            u8::from_str_radix(&clean[2..4], 16),
            u8::from_str_radix(&clean[4..6], 16),
        ) {
            return Rgba([r, g, b, alpha]);
        }
    }
    Rgba([92, 102, 114, alpha])
}

fn draw_palette_strip(
    canvas: &mut RgbaImage,
    rect: BoardRect,
    hexes: &[&str],
    origin_x: f64,
    origin_y: f64,
    scale: f64,
) {
    let items: Vec<&str> = if hexes.is_empty() {
        vec!["#8B95A1"]
    } else {
        hexes.to_vec()
    };
    let n = items.len();
    let gap = 6.0;
    let sw_w = ((rect.width - gap * ((n - 1) as f64)) / (n as f64)).max(12.0);
    for (idx, hex) in items.iter().enumerate() {
        let sx = rect.x + (idx as f64) * (sw_w + gap);
        let px = ((sx - origin_x) * scale).round() as i32;
        let py = ((rect.y - origin_y) * scale).round() as i32;
        let pw = (sw_w * scale).round().max(1.0) as i32;
        let ph = (rect.height * scale).round().max(1.0) as i32;
        fill_rect_alpha(canvas, px, py, pw, ph, parse_hex_rgba(hex, 255));
    }
}

fn resolve_anchor_point(
    rect: BoardRect,
    anchor: ConnectorAnchor,
    normalized: Option<BoardPoint>,
    other: BoardRect,
) -> BoardPoint {
    if let Some(norm) = normalized {
        return BoardPoint::new(
            rect.x + norm.x.clamp(0.0, 1.0) * rect.width,
            rect.y + norm.y.clamp(0.0, 1.0) * rect.height,
        );
    }
    let resolved = if anchor == ConnectorAnchor::Auto {
        let dx = other.mid_x() - rect.mid_x();
        let dy = other.mid_y() - rect.mid_y();
        if dx.abs() >= dy.abs() {
            if dx >= 0.0 {
                ConnectorAnchor::Trailing
            } else {
                ConnectorAnchor::Leading
            }
        } else if dy >= 0.0 {
            ConnectorAnchor::Bottom
        } else {
            ConnectorAnchor::Top
        }
    } else {
        anchor
    };
    match resolved {
        ConnectorAnchor::Top => BoardPoint::new(rect.mid_x(), rect.min_y()),
        ConnectorAnchor::Bottom => BoardPoint::new(rect.mid_x(), rect.max_y()),
        ConnectorAnchor::Leading => BoardPoint::new(rect.min_x(), rect.mid_y()),
        ConnectorAnchor::Trailing => BoardPoint::new(rect.max_x(), rect.mid_y()),
        ConnectorAnchor::Auto => BoardPoint::new(rect.mid_x(), rect.mid_y()),
    }
}

fn draw_connector(
    canvas: &mut RgbaImage,
    conn: &BoardConnector,
    from_r: BoardRect,
    to_r: BoardRect,
    origin_x: f64,
    origin_y: f64,
    scale: f64,
) {
    let p0 = resolve_anchor_point(from_r, conn.from_anchor, conn.from_normalized_point, to_r);
    let p1 = resolve_anchor_point(to_r, conn.to_anchor, conn.to_normalized_point, from_r);
    let x0 = (p0.x - origin_x) * scale;
    let y0 = (p0.y - origin_y) * scale;
    let x1 = (p1.x - origin_x) * scale;
    let y1 = (p1.y - origin_y) * scale;
    let col = parse_hex_rgba(&conn.color_hex, 235);
    let width = (2.2 * scale).max(1.5);

    match conn.style {
        ConnectorStyle::Straight => {
            draw_thick_line(canvas, x0, y0, x1, y1, width, col, conn.dashed);
        }
        ConnectorStyle::Elbow => {
            let mid_x = (x0 + x1) * 0.5;
            draw_thick_line(canvas, x0, y0, mid_x, y0, width, col, conn.dashed);
            draw_thick_line(canvas, mid_x, y0, mid_x, y1, width, col, conn.dashed);
            draw_thick_line(canvas, mid_x, y1, x1, y1, width, col, conn.dashed);
        }
        ConnectorStyle::Curved => {
            let dx = (x1 - x0).abs().max(40.0 * scale) * 0.45;
            let c0x = x0 + if x1 >= x0 { dx } else { -dx };
            let c1x = x1 - if x1 >= x0 { dx } else { -dx };
            let steps = 28;
            let mut prev = (x0, y0);
            for s in 1..=steps {
                let t = (s as f64) / (steps as f64);
                let omt = 1.0 - t;
                let bx = omt.powi(3) * x0
                    + 3.0 * omt.powi(2) * t * c0x
                    + 3.0 * omt * t.powi(2) * c1x
                    + t.powi(3) * x1;
                let by = omt.powi(3) * y0
                    + 3.0 * omt.powi(2) * t * y0
                    + 3.0 * omt * t.powi(2) * y1
                    + t.powi(3) * y1;
                if !conn.dashed || s % 2 == 1 {
                    draw_thick_line(canvas, prev.0, prev.1, bx, by, width, col, false);
                }
                prev = (bx, by);
            }
        }
    }
}

fn blend_pixel(dst: &mut Rgba<u8>, src: Rgba<u8>) {
    let a = src[3] as f32 / 255.0;
    if a <= 0.0 {
        return;
    }
    if a >= 0.999 {
        *dst = src;
        return;
    }
    let inv = 1.0 - a;
    dst[0] = (src[0] as f32 * a + dst[0] as f32 * inv).round() as u8;
    dst[1] = (src[1] as f32 * a + dst[1] as f32 * inv).round() as u8;
    dst[2] = (src[2] as f32 * a + dst[2] as f32 * inv).round() as u8;
    dst[3] = 255;
}

fn fill_rect_alpha(canvas: &mut RgbaImage, x: i32, y: i32, w: i32, h: i32, color: Rgba<u8>) {
    let cw = canvas.width() as i32;
    let ch = canvas.height() as i32;
    let x0 = x.max(0);
    let y0 = y.max(0);
    let x1 = (x + w).min(cw);
    let y1 = (y + h).min(ch);
    for py in y0..y1 {
        for px in x0..x1 {
            blend_pixel(canvas.get_pixel_mut(px as u32, py as u32), color);
        }
    }
}

fn stroke_rect(canvas: &mut RgbaImage, x: i32, y: i32, w: i32, h: i32, t: i32, color: Rgba<u8>) {
    fill_rect_alpha(canvas, x, y, w, t, color);
    fill_rect_alpha(canvas, x, y + h - t, w, t, color);
    fill_rect_alpha(canvas, x, y, t, h, color);
    fill_rect_alpha(canvas, x + w - t, y, t, h, color);
}

fn blit_rgba(canvas: &mut RgbaImage, src: &RgbaImage, dst_x: i32, dst_y: i32) {
    let cw = canvas.width() as i32;
    let ch = canvas.height() as i32;
    for sy in 0..src.height() {
        let dy = dst_y + sy as i32;
        if dy < 0 || dy >= ch {
            continue;
        }
        for sx in 0..src.width() {
            let dx = dst_x + sx as i32;
            if dx < 0 || dx >= cw {
                continue;
            }
            blend_pixel(
                canvas.get_pixel_mut(dx as u32, dy as u32),
                *src.get_pixel(sx, sy),
            );
        }
    }
}

#[allow(clippy::too_many_arguments)]
fn draw_thick_line(
    canvas: &mut RgbaImage,
    x0: f64,
    y0: f64,
    x1: f64,
    y1: f64,
    width: f64,
    color: Rgba<u8>,
    dashed: bool,
) {
    let dist = ((x1 - x0).powi(2) + (y1 - y0).powi(2)).sqrt();
    let steps = (dist * 1.5).ceil().max(1.0) as i32;
    let r = (width * 0.5).ceil() as i32;
    let cw = canvas.width() as i32;
    let ch = canvas.height() as i32;

    for s in 0..=steps {
        if dashed && ((s / 8) % 2 == 1) {
            continue;
        }
        let t = (s as f64) / (steps as f64);
        let cx = (x0 + (x1 - x0) * t).round() as i32;
        let cy = (y0 + (y1 - y0) * t).round() as i32;
        for dy in -r..=r {
            for dx in -r..=r {
                if (dx * dx + dy * dy) as f64 <= (width * 0.5 + 0.35).powi(2) {
                    let px = cx + dx;
                    let py = cy + dy;
                    if px >= 0 && px < cw && py >= 0 && py < ch {
                        blend_pixel(canvas.get_pixel_mut(px as u32, py as u32), color);
                    }
                }
            }
        }
    }
}
