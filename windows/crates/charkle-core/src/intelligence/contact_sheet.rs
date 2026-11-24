//! Visual contact-sheet renderer (`contact_sheet.rs`) for External Agents (`render_contact_sheet`)
//! and multimodal visual inspection.
//!
//! Renders up to 16 asset thumbnails into a crisp numbered grid image (JPEG) with badge numbers
//! so multimodal agents can visually inspect 16 candidates in a single image call.

use std::io::Cursor;

use image::imageops::FilterType;
use image::{DynamicImage, ImageFormat, Rgba, RgbaImage};

use crate::error::{CoreError, CoreResult};
use crate::media::MediaPipeline;
use crate::models::core::AssetRecord;
use crate::models::media::ThumbnailTier;

#[derive(Debug, Clone)]
pub struct ContactSheetResult {
    pub jpeg_bytes: Vec<u8>,
    pub width: u32,
    pub height: u32,
    pub slots: Vec<(usize, AssetRecord)>,
}

/// Renders up to 16 assets into a clean numbered contact sheet JPEG.
pub fn render_contact_sheet(
    assets: &[AssetRecord],
    media: &MediaPipeline,
    columns: u32,
) -> CoreResult<ContactSheetResult> {
    let items: Vec<AssetRecord> = assets.iter().take(16).cloned().collect();
    let cols = columns.clamp(1, 4).min(items.len().max(1) as u32);
    let rows = (items.len().max(1) as u32).div_ceil(cols);
    let cell_w = 240u32;
    let cell_h = 180u32;
    let gap = 12u32;
    let pad = 16u32;

    let canvas_w = pad * 2 + cols * cell_w + (cols.saturating_sub(1)) * gap;
    let canvas_h = pad * 2 + rows * cell_h + (rows.saturating_sub(1)) * gap;
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

        // Try loading grid thumbnail or original
        let loaded = media
            .thumbnail_url(asset.id, ThumbnailTier::Grid520)
            .and_then(|p| image::open(p).ok())
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

        // Crisp dark numbered pill badge in top-left corner (#1 .. #16)
        let badge_w = 34u32;
        let badge_h = 24u32;
        fill_rect(
            &mut canvas,
            ox + 8,
            oy + 8,
            badge_w,
            badge_h,
            Rgba([20, 22, 26, 220]),
        );
        draw_small_number(
            &mut canvas,
            ox + 14,
            oy + 14,
            idx + 1,
            Rgba([255, 255, 255, 255]),
        );

        slots.push((idx + 1, asset));
    }

    let mut jpeg_bytes = Vec::new();
    DynamicImage::ImageRgba8(canvas)
        .to_rgb8()
        .write_to(&mut Cursor::new(&mut jpeg_bytes), ImageFormat::Jpeg)
        .map_err(|e| CoreError::Media(format!("联系表 JPEG 编码失败：{e}")))?;

    Ok(ContactSheetResult {
        jpeg_bytes,
        width: canvas_w,
        height: canvas_h,
        slots,
    })
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

/// Tiny 3x5 bitmap digit renderer (scaled 2x) for numbered contact-sheet slot badges (1..16).
fn draw_small_number(img: &mut RgbaImage, x: u32, y: u32, num: usize, color: Rgba<u8>) {
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
    let text = num.to_string();
    let mut cursor_x = x;
    for ch in text.chars() {
        let d = (ch as u8).saturating_sub(b'0') as usize;
        if d < 10 {
            for (row_idx, row_bits) in DIGITS[d].iter().enumerate() {
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
    fn renders_numbered_contact_sheet_jpeg() {
        let dir = tempdir().unwrap();
        let media = MediaPipeline::new(dir.path()).unwrap();
        let mut a1 = AssetRecord::new("Poster A", "a.jpg");
        a1.dominant_colors = vec![LabColor {
            hex: "#2A60E0".into(),
            l: 45.0,
            a: 20.0,
            b: -60.0,
            proportion: 1.0,
        }];
        let mut a2 = AssetRecord::new("Poster B", "b.jpg");
        a2.dominant_colors = vec![LabColor {
            hex: "#D95D48".into(),
            l: 55.0,
            a: 45.0,
            b: 30.0,
            proportion: 1.0,
        }];
        let sheet = render_contact_sheet(&[a1, a2], &media, 4).unwrap();
        assert_eq!(sheet.slots.len(), 2);
        assert_eq!(&sheet.jpeg_bytes[0..2], &[0xFF, 0xD8]);
        assert!(sheet.width >= 500);
    }
}
