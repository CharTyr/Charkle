//! Procedural media poster cards, swatch rendering, SVG rasterization (`resvg`),
//! fast Lanczos resizing (`fast_image_resize`), and Markdown plain-text extraction (`pulldown-cmark`).

use std::io::Cursor;

use fast_image_resize as fr;
use image::codecs::jpeg::JpegEncoder;
use image::codecs::png::PngEncoder;
use image::{ColorType, DynamicImage, ImageEncoder, Rgba, RgbaImage};
use pulldown_cmark::{Event, Parser};
use resvg::tiny_skia;
use resvg::usvg;

use crate::error::{CoreError, CoreResult};
use crate::models::core::{GitHubRepoMetadata, LabColor, SocialPlatform, SocialPostMetadata};

pub struct MediaArtwork;

impl MediaArtwork {
    /// Renders a crisp 640×640 solid color swatch card matching `MediaArtwork.swatch`.
    pub fn swatch(color: &LabColor) -> DynamicImage {
        let rgb = parse_hex_rgb(&color.hex).unwrap_or([128, 128, 128]);
        let mut img = RgbaImage::from_pixel(640, 640, Rgba([rgb[0], rgb[1], rgb[2], 255]));
        // Subtle inner hairline frame
        let border = Rgba([
            rgb[0].saturating_sub(24),
            rgb[1].saturating_sub(24),
            rgb[2].saturating_sub(24),
            255,
        ]);
        draw_rect_outline(&mut img, 0, 0, 640, 640, 2, border);
        DynamicImage::ImageRgba8(img)
    }

    /// Renders a clean neutral editorial poster card for text/document/audio/bookmark assets.
    pub fn card(_title: &str, _label: &str, text: &str, waveform: &[f32]) -> DynamicImage {
        let (w, h) = if !waveform.is_empty() {
            (800, 516) // 1.55 audio aspect ratio
        } else {
            (800, 640)
        };
        let mut img = RgbaImage::from_pixel(w, h, Rgba([246, 246, 245, 255]));
        fill_rect(&mut img, 28, 28, w - 56, h - 56, Rgba([255, 255, 255, 255]));
        draw_rect_outline(
            &mut img,
            28,
            28,
            w - 56,
            h - 56,
            2,
            Rgba([229, 229, 226, 255]),
        );

        // Header accent pill
        fill_rect(&mut img, 64, 68, 132, 28, Rgba([237, 237, 233, 255]));
        fill_rect(&mut img, 64, 120, 420, 20, Rgba([24, 25, 28, 255]));

        if !waveform.is_empty() {
            let bars = waveform.len().min(48);
            let area_x = 64u32;
            let area_w = w - 128;
            let mid_y = 310u32;
            let max_half_h = 115.0_f32;
            let slot = (area_w as f32) / (bars.max(1) as f32);
            let bar_w = (slot * 0.58).max(4.0) as u32;
            for (idx, &peak) in waveform.iter().take(bars).enumerate() {
                let norm = peak.clamp(0.08, 1.0);
                let half_h = (norm * max_half_h).round() as u32;
                let bx = area_x + (idx as f32 * slot).round() as u32;
                let by = mid_y.saturating_sub(half_h);
                let bh = (half_h * 2).max(6);
                let color = if idx < bars / 3 {
                    Rgba([42, 96, 224, 255])
                } else {
                    Rgba([92, 96, 105, 255])
                };
                fill_rect(&mut img, bx, by, bar_w, bh, color);
            }
        } else {
            // Minimalist typographic placeholder lines reflecting excerpt density
            let line_count = text.lines().count().clamp(4, 9);
            for i in 0..line_count {
                let y = 176 + (i as u32) * 38;
                let lw = if i % 3 == 2 {
                    460
                } else {
                    640 - ((i as u32 * 37) % 140)
                };
                let tone = if i == 0 {
                    Rgba([92, 96, 105, 255])
                } else {
                    Rgba([214, 216, 220, 255])
                };
                fill_rect(&mut img, 64, y, lw, 14, tone);
            }
        }
        DynamicImage::ImageRgba8(img)
    }

    /// Renders a crisp light editorial poster card for a social post (800×920 with cover or 800×620 text-only).
    pub fn social_post_card(
        meta: &SocialPostMetadata,
        cover: Option<&DynamicImage>,
    ) -> DynamicImage {
        let (w, h) = if cover.is_some() {
            (800, 920)
        } else {
            (800, 620)
        };
        let mut img = RgbaImage::from_pixel(w, h, Rgba([250, 250, 249, 255]));
        draw_rect_outline(&mut img, 0, 0, w, h, 2, Rgba([228, 228, 231, 255]));

        let pill_color = match meta.platform {
            SocialPlatform::X => Rgba([24, 24, 27, 255]),
            SocialPlatform::Threads => Rgba([39, 39, 42, 255]),
            SocialPlatform::Bluesky => Rgba([2, 132, 199, 255]),
        };

        // Platform badge pill & avatar placeholder circle
        fill_rect(&mut img, 48, 44, 108, 34, pill_color);
        fill_circle(&mut img, 76, 128, 28, Rgba([228, 228, 231, 255]));
        fill_rect(&mut img, 122, 108, 240, 18, Rgba([24, 25, 28, 255]));
        fill_rect(&mut img, 122, 136, 168, 12, Rgba([138, 143, 153, 255]));

        // Body excerpt lines
        let lines = (meta.body_text.chars().count() / 36).clamp(2, 5);
        for i in 0..lines {
            let y = 186 + (i as u32) * 32;
            let lw = 680 - ((i as u32 * 53) % 160);
            fill_rect(&mut img, 48, y, lw, 14, Rgba([63, 63, 70, 255]));
        }

        if let Some(cover_img) = cover {
            let box_x = 48u32;
            let box_y = 380u32;
            let box_w = w - 96;
            let box_h = h - box_y - 48;
            let fitted =
                cover_img.resize_to_fill(box_w, box_h, image::imageops::FilterType::Triangle);
            image::imageops::overlay(
                &mut img,
                &fitted.to_rgba8(),
                i64::from(box_x),
                i64::from(box_y),
            );
            if meta.has_video {
                fill_circle(
                    &mut img,
                    box_x + box_w / 2,
                    box_y + box_h / 2,
                    42,
                    Rgba([15, 17, 21, 210]),
                );
                // Simple play triangle highlight
                fill_rect(
                    &mut img,
                    box_x + box_w / 2 - 10,
                    box_y + box_h / 2 - 14,
                    24,
                    28,
                    Rgba([255, 255, 255, 255]),
                );
            }
        }

        DynamicImage::ImageRgba8(img)
    }

    /// Renders a dark editorial GitHub repository poster card (`820×620`, `#111317` ground).
    pub fn github_repo_card(repo: &GitHubRepoMetadata) -> DynamicImage {
        let (w, h) = (820u32, 620u32);
        let mut img = RgbaImage::from_pixel(w, h, Rgba([17, 19, 23, 255]));
        fill_rect(&mut img, 32, 32, w - 64, h - 64, Rgba([30, 35, 43, 255]));
        draw_rect_outline(&mut img, 32, 32, w - 64, h - 64, 2, Rgba([48, 54, 61, 255]));

        let lang_hex = match repo.language.as_deref().unwrap_or("") {
            "Swift" => "#F05138",
            "TypeScript" => "#3178C6",
            "JavaScript" => "#F1E05A",
            "Python" => "#3572A5",
            "Rust" => "#DEA584",
            "Go" => "#00ADD8",
            "HTML" => "#E34C26",
            "CSS" => "#563D7C",
            _ => "#60A5FA",
        };
        let lang_rgb = parse_hex_rgb(lang_hex).unwrap_or([96, 165, 250]);
        fill_circle(
            &mut img,
            88,
            96,
            16,
            Rgba([lang_rgb[0], lang_rgb[1], lang_rgb[2], 255]),
        );
        fill_rect(&mut img, 124, 82, 420, 26, Rgba([242, 243, 245, 255]));

        for i in 0..3 {
            fill_rect(
                &mut img,
                72,
                160 + i * 34,
                640 - i * 80,
                14,
                Rgba([161, 166, 176, 255]),
            );
        }
        // Topic chips
        let chip_count = repo.topics.len().clamp(2, 5) as u32;
        for i in 0..chip_count {
            fill_rect(
                &mut img,
                72 + i * 124,
                490,
                108,
                32,
                Rgba([42, 96, 224, 96]),
            );
        }
        DynamicImage::ImageRgba8(img)
    }

    /// Renders a dark studio 3D model poster card (`800×800`, `#181A20`).
    pub fn model_3d_card(_title: &str, _format: &str) -> DynamicImage {
        let mut img = RgbaImage::from_pixel(800, 800, Rgba([24, 26, 32, 255]));
        fill_circle(&mut img, 400, 380, 180, Rgba([42, 46, 56, 255]));
        draw_rect_outline(&mut img, 270, 250, 260, 260, 4, Rgba([91, 141, 239, 255]));
        fill_rect(&mut img, 310, 620, 180, 34, Rgba([36, 39, 44, 255]));
        DynamicImage::ImageRgba8(img)
    }

    /// Rasterizes an SVG buffer into a crisp RGBA `DynamicImage` via `resvg`.
    pub fn render_svg(svg_bytes: &[u8], max_side: u32) -> Option<DynamicImage> {
        let opt = usvg::Options::default();
        let tree = usvg::Tree::from_data(svg_bytes, &opt).ok()?;
        let size = tree.size();
        let src_w = size.width().max(1.0);
        let src_h = size.height().max(1.0);
        let scale = (max_side as f32) / src_w.max(src_h);
        let dst_w = (src_w * scale).round().clamp(1.0, max_side as f32) as u32;
        let dst_h = (src_h * scale).round().clamp(1.0, max_side as f32) as u32;

        let mut pixmap = tiny_skia::Pixmap::new(dst_w, dst_h)?;
        let transform =
            tiny_skia::Transform::from_scale(dst_w as f32 / src_w, dst_h as f32 / src_h);
        resvg::render(&tree, transform, &mut pixmap.as_mut());

        // tiny-skia produces premultiplied RGBA; un-premultiply cleanly for `image::RgbaImage`.
        let mut rgba = Vec::with_capacity((dst_w * dst_h * 4) as usize);
        for px in pixmap.pixels() {
            let a = px.alpha();
            if a == 0 {
                rgba.extend_from_slice(&[0, 0, 0, 0]);
            } else if a == 255 {
                rgba.extend_from_slice(&[px.red(), px.green(), px.blue(), 255]);
            } else {
                let af = a as f32 / 255.0;
                rgba.push(((px.red() as f32 / af).round().min(255.0)) as u8);
                rgba.push(((px.green() as f32 / af).round().min(255.0)) as u8);
                rgba.push(((px.blue() as f32 / af).round().min(255.0)) as u8);
                rgba.push(a);
            }
        }
        RgbaImage::from_raw(dst_w, dst_h, rgba).map(DynamicImage::ImageRgba8)
    }

    /// Resizes `image` so `max(width, height) <= max_side` using `fast_image_resize` Lanczos3.
    pub fn resize(image: &DynamicImage, max_side: u32) -> DynamicImage {
        let orig_w = image.width();
        let orig_h = image.height();
        if orig_w == 0 || orig_h == 0 || orig_w.max(orig_h) <= max_side {
            return image.clone();
        }
        let scale = max_side as f64 / orig_w.max(orig_h) as f64;
        let dst_w = ((orig_w as f64 * scale).round() as u32).max(1);
        let dst_h = ((orig_h as f64 * scale).round() as u32).max(1);

        let src_rgba = image.to_rgba8();
        let Ok(src_view) =
            fr::images::ImageRef::new(orig_w, orig_h, src_rgba.as_raw(), fr::PixelType::U8x4)
        else {
            return image.resize(dst_w, dst_h, image::imageops::FilterType::Lanczos3);
        };
        let mut dst_img = fr::images::Image::new(dst_w, dst_h, fr::PixelType::U8x4);
        let mut resizer = fr::Resizer::new();
        let options = fr::ResizeOptions::new()
            .resize_alg(fr::ResizeAlg::Convolution(fr::FilterType::Lanczos3));
        if resizer.resize(&src_view, &mut dst_img, &options).is_ok() {
            if let Some(buf) = RgbaImage::from_raw(dst_w, dst_h, dst_img.into_vec()) {
                return DynamicImage::ImageRgba8(buf);
            }
        }
        image.resize(dst_w, dst_h, image::imageops::FilterType::Lanczos3)
    }

    /// Encodes `image` to RGB JPEG bytes (`quality`: 1..=100, compositing transparency on neutral light ground).
    pub fn encode_jpeg(image: &DynamicImage, quality: u8) -> CoreResult<Vec<u8>> {
        let rgba = image.to_rgba8();
        let (w, h) = rgba.dimensions();
        let mut rgb = Vec::with_capacity((w * h * 3) as usize);
        for px in rgba.pixels() {
            let [r, g, b, a] = px.0;
            if a == 255 {
                rgb.extend_from_slice(&[r, g, b]);
            } else {
                let af = a as f32 / 255.0;
                let bg = 246.0_f32;
                rgb.push((r as f32 * af + bg * (1.0 - af)).round() as u8);
                rgb.push((g as f32 * af + bg * (1.0 - af)).round() as u8);
                rgb.push((b as f32 * af + bg * (1.0 - af)).round() as u8);
            }
        }
        let mut out = Cursor::new(Vec::new());
        let mut enc = JpegEncoder::new_with_quality(&mut out, quality);
        enc.encode(&rgb, w, h, ColorType::Rgb8.into())
            .map_err(|e| CoreError::Media(format!("JPEG encode failed: {e}")))?;
        Ok(out.into_inner())
    }

    /// Encodes `image` to lossless RGBA PNG bytes.
    pub fn encode_png(image: &DynamicImage) -> CoreResult<Vec<u8>> {
        let rgba = image.to_rgba8();
        let (w, h) = rgba.dimensions();
        let mut out = Cursor::new(Vec::new());
        let enc = PngEncoder::new(&mut out);
        enc.write_image(rgba.as_raw(), w, h, ColorType::Rgba8.into())
            .map_err(|e| CoreError::Media(format!("PNG encode failed: {e}")))?;
        Ok(out.into_inner())
    }

    /// Extracts clean plain text from Markdown via `pulldown-cmark` for FTS5 indexing & excerpts.
    pub fn markdown_to_plain_text(markdown: &str) -> String {
        let parser = Parser::new(markdown);
        let mut out = String::with_capacity(markdown.len().min(16_384));
        for event in parser {
            match event {
                Event::Text(t) | Event::Code(t) => {
                    out.push_str(&t);
                }
                Event::SoftBreak | Event::HardBreak | Event::End(_)
                    if !out.ends_with('\n') && !out.ends_with(' ') && !out.is_empty() =>
                {
                    out.push(' ');
                }
                _ => {}
            }
        }
        out.trim().to_string()
    }
}

pub(crate) fn parse_hex_rgb(hex: &str) -> Option<[u8; 3]> {
    let cleaned = hex.trim().trim_start_matches('#');
    if cleaned.len() != 6 {
        return None;
    }
    let val = u32::from_str_radix(cleaned, 16).ok()?;
    Some([
        ((val >> 16) & 0xFF) as u8,
        ((val >> 8) & 0xFF) as u8,
        (val & 0xFF) as u8,
    ])
}

pub(crate) fn fill_rect(img: &mut RgbaImage, x: u32, y: u32, w: u32, h: u32, color: Rgba<u8>) {
    let (iw, ih) = img.dimensions();
    let x_end = x.saturating_add(w).min(iw);
    let y_end = y.saturating_add(h).min(ih);
    for py in y.min(ih)..y_end {
        for px in x.min(iw)..x_end {
            blend_pixel(img.get_pixel_mut(px, py), color);
        }
    }
}

pub(crate) fn draw_rect_outline(
    img: &mut RgbaImage,
    x: u32,
    y: u32,
    w: u32,
    h: u32,
    thickness: u32,
    color: Rgba<u8>,
) {
    fill_rect(img, x, y, w, thickness, color);
    fill_rect(img, x, y + h.saturating_sub(thickness), w, thickness, color);
    fill_rect(img, x, y, thickness, h, color);
    fill_rect(img, x + w.saturating_sub(thickness), y, thickness, h, color);
}

pub(crate) fn fill_circle(img: &mut RgbaImage, cx: u32, cy: u32, radius: u32, color: Rgba<u8>) {
    let (iw, ih) = img.dimensions();
    let r2 = (radius as i64) * (radius as i64);
    let min_x = cx.saturating_sub(radius);
    let max_x = cx.saturating_add(radius).min(iw.saturating_sub(1));
    let min_y = cy.saturating_sub(radius);
    let max_y = cy.saturating_add(radius).min(ih.saturating_sub(1));
    for py in min_y..=max_y {
        let dy = py as i64 - cy as i64;
        for px in min_x..=max_x {
            let dx = px as i64 - cx as i64;
            if dx * dx + dy * dy <= r2 {
                blend_pixel(img.get_pixel_mut(px, py), color);
            }
        }
    }
}

fn blend_pixel(dst: &mut Rgba<u8>, src: Rgba<u8>) {
    if src.0[3] == 255 {
        *dst = src;
        return;
    }
    let a = src.0[3] as f32 / 255.0;
    let inv = 1.0 - a;
    dst.0[0] = (src.0[0] as f32 * a + dst.0[0] as f32 * inv).round() as u8;
    dst.0[1] = (src.0[1] as f32 * a + dst.0[1] as f32 * inv).round() as u8;
    dst.0[2] = (src.0[2] as f32 * a + dst.0[2] as f32 * inv).round() as u8;
    dst.0[3] = 255;
}
