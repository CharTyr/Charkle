//! Visual contact-sheet renderer (`contact_sheet.rs`) for External Agents (`render_contact_sheet`)
//! and multimodal visual inspection.
//!
//! Renders up to 24 asset thumbnails into a crisp numbered grid image (JPEG, `512..=1920` px wide)
//! with zero-padded `#01..#24` badges so multimodal agents can visually inspect candidates in a
//! single low-token image call.

use std::io::Cursor;

use image::codecs::jpeg::JpegEncoder;
use image::imageops::FilterType;
use image::{DynamicImage, Rgba, RgbaImage};

use crate::error::{CoreError, CoreResult};
use crate::media::MediaPipeline;
use crate::models::core::AssetRecord;
use crate::models::media::ThumbnailTier;

pub const CONTACT_SHEET_MIN_WIDTH: u32 = 512;
pub const CONTACT_SHEET_MAX_WIDTH: u32 = 1920;
pub const CONTACT_SHEET_DEFAULT_WIDTH: u32 = 1024;
pub const CONTACT_SHEET_MAX_ASSETS: usize = 24;

#[derive(Debug, Clone, Copy)]
pub struct ContactSheetOptions {
    pub columns: Option<u32>,
    pub max_width: u32,
    pub jpeg_quality: u8,
}

impl Default for ContactSheetOptions {
    fn default() -> Self {
        Self {
            columns: None,
            max_width: CONTACT_SHEET_DEFAULT_WIDTH,
            jpeg_quality: 74,
        }
    }
}

#[derive(Debug, Clone)]
pub struct ContactSheetResult {
    pub jpeg_bytes: Vec<u8>,
    pub width: u32,
    pub height: u32,
    pub slots: Vec<(usize, AssetRecord)>,
}

/// Renders up to 24 assets into a clean numbered contact sheet JPEG with configurable width
/// (`512..=1920`) and JPEG quality.
pub fn render_contact_sheet_with_options(
    assets: &[AssetRecord],
    media: &MediaPipeline,
    options: ContactSheetOptions,
) -> CoreResult<ContactSheetResult> {
    let items: Vec<AssetRecord> = assets
        .iter()
        .take(CONTACT_SHEET_MAX_ASSETS)
        .cloned()
        .collect();
    let count = items.len().max(1) as u32;
    let default_cols = match count {
        1 => 1,
        2 => 2,
        3 | 4 => 2,
        5..=9 => 3,
        _ => 4,
    };
    let cols = options
        .columns
        .unwrap_or(default_cols)
        .clamp(1, 6)
        .min(count);
    let rows = count.div_ceil(cols);

    let max_width = options
        .max_width
        .clamp(CONTACT_SHEET_MIN_WIDTH, CONTACT_SHEET_MAX_WIDTH);
    let gap = if max_width <= 640 { 8u32 } else { 12u32 };
    let pad = if max_width <= 640 { 12u32 } else { 16u32 };

    let usable_w = max_width
        .saturating_sub(pad * 2 + cols.saturating_sub(1) * gap)
        .max(cols * 96);
    let cell_w = (usable_w / cols).max(96);
    let cell_h = ((cell_w as f64) * 0.75).round().max(72.0) as u32;

    let canvas_w = pad * 2 + cols * cell_w + cols.saturating_sub(1) * gap;
    let canvas_h = pad * 2 + rows * cell_h + rows.saturating_sub(1) * gap;
    let mut canvas = RgbaImage::from_pixel(canvas_w, canvas_h, Rgba([244, 244, 242, 255]));
    let mut slots = Vec::with_capacity(items.len());

    for (idx, asset) in items.into_iter().enumerate() {
        let col = (idx as u32) % cols;
        let row = (idx as u32) / cols;
        let ox = pad + col * (cell_w + gap);
        let oy = pad + row * (cell_h + gap);

        // Cell card background
        fill_rect(
            &mut canvas,
            ox,
            oy,
            cell_w,
            cell_h,
            Rgba([230, 232, 236, 255]),
        );

        // Try loading grid thumbnail, preview thumbnail, or local original
        let loaded = media
            .thumbnail_url(asset.id, ThumbnailTier::Grid520)
            .and_then(|p| image::open(p).ok())
            .or_else(|| {
                media
                    .thumbnail_url(asset.id, ThumbnailTier::Preview1400)
                    .and_then(|p| image::open(p).ok())
            })
            .or_else(|| {
                let orig = media.original_path(&asset);
                image::open(orig).ok()
            });

        if let Some(img) = loaded {
            let resized = img
                .resize_to_fill(cell_w, cell_h, FilterType::Triangle)
                .to_rgba8();
            image::imageops::overlay(&mut canvas, &resized, ox as i64, oy as i64);
        } else if let Some(first_color) = asset.dominant_colors.first() {
            if let Some(rgb) = parse_hex_rgb(&first_color.hex) {
                fill_rect(
                    &mut canvas,
                    ox,
                    oy,
                    cell_w,
                    cell_h,
                    Rgba([rgb[0], rgb[1], rgb[2], 255]),
                );
            }
        }

        // Crisp dark numbered pill badge in top-left corner (#01 .. #24)
        let badge_w = 40u32;
        let badge_h = 22u32;
        fill_rect(
            &mut canvas,
            ox + 6,
            oy + 6,
            badge_w,
            badge_h,
            Rgba([20, 22, 26, 228]),
        );
        draw_badge_label(
            &mut canvas,
            ox + 10,
            oy + 12,
            idx + 1,
            Rgba([255, 255, 255, 255]),
        );

        slots.push((idx + 1, asset));
    }

    let rgb = DynamicImage::ImageRgba8(canvas).to_rgb8();
    let mut jpeg_bytes = Vec::new();
    let quality = options.jpeg_quality.clamp(50, 95);
    let mut cursor = Cursor::new(&mut jpeg_bytes);
    let mut encoder = JpegEncoder::new_with_quality(&mut cursor, quality);
    encoder
        .encode_image(&rgb)
        .map_err(|e| CoreError::Media(format!("联系表 JPEG 编码失败：{e}")))?;

    Ok(ContactSheetResult {
        jpeg_bytes,
        width: canvas_w,
        height: canvas_h,
        slots,
    })
}

/// Backward-compatible wrapper rendering a numbered contact sheet JPEG with explicit column count.
pub fn render_contact_sheet(
    assets: &[AssetRecord],
    media: &MediaPipeline,
    columns: u32,
) -> CoreResult<ContactSheetResult> {
    render_contact_sheet_with_options(
        assets,
        media,
        ContactSheetOptions {
            columns: Some(columns.clamp(1, 6)),
            max_width: CONTACT_SHEET_DEFAULT_WIDTH,
            jpeg_quality: 74,
        },
    )
}

fn fill_rect(img: &mut RgbaImage, x: u32, y: u32, w: u32, h: u32, color: Rgba<u8>) {
    let max_x = (x + w).min(img.width());
    let max_y = (y + h).min(img.height());
    for py in y..max_y {
        for px in x..max_x {
            img.put_pixel(px, py, color);
        }
    }
}

fn parse_hex_rgb(hex: &str) -> Option<[u8; 3]> {
    let clean = hex.trim().trim_start_matches('#');
    if clean.len() != 6 || !clean.is_ascii() {
        return None;
    }
    let val = u32::from_str_radix(clean, 16).ok()?;
    Some([
        ((val >> 16) & 0xFF) as u8,
        ((val >> 8) & 0xFF) as u8,
        (val & 0xFF) as u8,
    ])
}

/// Tiny 3x5 bitmap renderer (scaled 2x) for zero-padded `#01..#24` contact-sheet badges.
fn draw_badge_label(img: &mut RgbaImage, x: u32, y: u32, num: usize, color: Rgba<u8>) {
    const HASH_GLYPH: [u8; 5] = [0b101, 0b111, 0b101, 0b111, 0b101];
    const DIGITS: [[u8; 5]; 10] = [
        [0b111, 0b101, 0b101, 0b101, 0b111],
        [0b010, 0b110, 0b010, 0b010, 0b111],
        [0b111, 0b001, 0b111, 0b100, 0b111],
        [0b111, 0b001, 0b111, 0b001, 0b111],
        [0b101, 0b101, 0b111, 0b001, 0b001],
        [0b111, 0b100, 0b111, 0b001, 0b111],
        [0b111, 0b100, 0b111, 0b101, 0b111],
        [0b111, 0b001, 0b001, 0b010, 0b010],
        [0b111, 0b101, 0b111, 0b101, 0b111],
        [0b111, 0b101, 0b111, 0b001, 0b111],
    ];
    let text = format!("#{num:02}");
    let mut cursor_x = x;
    for ch in text.chars() {
        let glyph = if ch == '#' {
            Some(&HASH_GLYPH)
        } else if ch.is_ascii_digit() {
            Some(&DIGITS[(ch as u8 - b'0') as usize])
        } else {
            None
        };
        if let Some(rows) = glyph {
            for (row_idx, row_bits) in rows.iter().enumerate() {
                for col_idx in 0..3 {
                    if (row_bits >> (2 - col_idx)) & 1 == 1 {
                        fill_rect(
                            img,
                            cursor_x + (col_idx as u32) * 2,
                            y + (row_idx as u32) * 2,
                            2,
                            2,
                            color,
                        );
                    }
                }
            }
            cursor_x += 8;
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::models::core::LabColor;
    use tempfile::tempdir;

    #[test]
    fn renders_numbered_contact_sheet_jpeg_and_respects_512_floor_and_24_cap() {
        let dir = tempdir().unwrap();
        let media = MediaPipeline::new(dir.path()).unwrap();
        let assets: Vec<AssetRecord> = (0..26)
            .map(|idx| {
                let mut a = AssetRecord::new(format!("Poster {idx}"), format!("p{idx}.jpg"));
                a.dominant_colors = vec![LabColor::from_hex(
                    if idx % 2 == 0 { "#2A60E0" } else { "#D95D48" },
                    1.0,
                )];
                a
            })
            .collect();

        let sheet = render_contact_sheet_with_options(
            &assets,
            &media,
            ContactSheetOptions {
                columns: None,
                max_width: 512,
                jpeg_quality: 74,
            },
        )
        .unwrap();
        assert_eq!(sheet.slots.len(), 24);
        assert_eq!(&sheet.jpeg_bytes[0..2], &[0xFF, 0xD8]);
        assert!(sheet.width <= 512);
        assert!(sheet.width >= 480);

        // Requesting below floor clamps to 512
        let clamped = render_contact_sheet_with_options(
            &assets[..4],
            &media,
            ContactSheetOptions {
                columns: Some(2),
                max_width: 200,
                jpeg_quality: 74,
            },
        )
        .unwrap();
        assert!(clamped.width >= 480 && clamped.width <= 512);
    }
}
