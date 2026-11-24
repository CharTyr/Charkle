//! Procedural media poster cards, swatch rendering, SVG rasterization (`resvg`),
//! fast Lanczos resizing (`fast_image_resize`), and Markdown plain-text extraction (`pulldown-cmark`).

use std::io::Cursor;
use std::sync::{Arc, OnceLock};

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
        Self::social_post_card_with_avatar(meta, cover, None)
    }

    /// Renders a social post editorial poster card with optional author avatar composited into
    /// the circular header portrait (matching macOS `SocialPostResolver` / `MediaArtwork`).
    /// Xiaohongshu notes automatically render as native `900×1440` 3:4 cover + title/author/likes cards.
    pub fn social_post_card_with_avatar(
        meta: &SocialPostMetadata,
        cover: Option<&DynamicImage>,
        avatar: Option<&DynamicImage>,
    ) -> DynamicImage {
        if meta.platform == SocialPlatform::Xiaohongshu {
            return Self::xiaohongshu_post_card(meta, cover, avatar);
        }

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
            SocialPlatform::Xiaohongshu => Rgba([255, 36, 66, 255]),
        };

        // Platform badge pill & circular author avatar (or neutral placeholder)
        fill_rect(&mut img, 48, 44, 108, 34, pill_color);
        fill_circle(&mut img, 76, 128, 28, Rgba([228, 228, 231, 255]));
        if let Some(av) = avatar {
            composite_circular_avatar(&mut img, av, 76, 128, 28);
        }
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

    /// Native Xiaohongshu feed card (`900×1440`):
    /// - With cover: strict vertical 3:4 (`900×1200`) aspect-fill cover with multi-image (`N 图`)
    ///   pill or video play badge, `1.5px #EFEFEF` divider, and `900×240` `#FFFFFF` footer with
    ///   2-line CJK-wrapped bold title, circular author avatar/monogram, nickname (never 24-hex
    ///   `userId`), and right-aligned `#FF2442 ♥ <likes>`.
    /// - Without cover: clean `900×1440` editorial text-only fallback with `12px #FF2442` top ribbon.
    pub fn xiaohongshu_post_card(
        meta: &SocialPostMetadata,
        cover: Option<&DynamicImage>,
        avatar: Option<&DynamicImage>,
    ) -> DynamicImage {
        const W: u32 = 900;
        const COVER_H: u32 = 1_200;
        const H: u32 = 1_440;

        let author_name = meta.display_author_name();
        let initial = author_name
            .chars()
            .next()
            .unwrap_or('小')
            .to_uppercase()
            .to_string();

        if let Some(cover_img) = cover {
            let mut img = RgbaImage::from_pixel(W, H, Rgba([255, 255, 255, 255]));
            let fitted = cover_img
                .resize_to_fill(W, COVER_H, image::imageops::FilterType::Triangle)
                .to_rgba8();
            image::imageops::overlay(&mut img, &fitted, 0, 0);

            let raw_title = meta
                .article_title
                .as_deref()
                .map(str::trim)
                .filter(|s| !s.is_empty())
                .unwrap_or_else(|| meta.body_text.trim());
            let display_title = if raw_title.is_empty() {
                format!("{author_name} 的小红书笔记")
            } else {
                raw_title.to_string()
            };
            let title_lines = wrap_cjk_aware_ellipsis(&display_title, 42, 2);
            let media_count = meta.effective_attachments().len();

            let mut svg = String::with_capacity(4096);
            svg.push_str(&format!(
                r##"<svg xmlns="http://www.w3.org/2000/svg" width="{W}" height="{H}" viewBox="0 0 {W} {H}">
"##
            ));

            // Multi-image indicator pill at top-left (leaves top-right clear for floating badge)
            if media_count > 1 && !meta.has_video {
                let label = format!("{media_count} 图");
                svg.push_str(&format!(
                    r##"  <rect x="24" y="28" width="96" height="44" rx="22" ry="22" fill="#111827" fill-opacity="0.66"/>
  <text x="72" y="57" text-anchor="middle" font-family="Microsoft YaHei UI, Segoe UI, sans-serif" font-size="20" font-weight="700" fill="#FFFFFF">{}</text>
"##,
                    escape_svg_xml(&label)
                ));
            }

            // Video play badge centered on 3:4 cover
            if meta.has_video {
                svg.push_str(
                    r##"  <circle cx="450" cy="600" r="44" fill="#000000" fill-opacity="0.58"/>
  <polygon points="438,580 438,620 472,600" fill="#FFFFFF"/>
"##,
                );
            }

            // Hairline divider & crisp paper-white bottom footer
            svg.push_str(
                r##"  <rect x="0" y="1200" width="900" height="240" fill="#FFFFFF"/>
  <rect x="0" y="1199" width="900" height="1.5" fill="#EFEFEF"/>
"##,
            );

            // Bold 2-line CJK-wrapped title
            let mut title_y = if title_lines.len() > 1 {
                1256u32
            } else {
                1280u32
            };
            for line in &title_lines {
                svg.push_str(&format!(
                    r##"  <text x="34" y="{title_y}" font-family="Microsoft YaHei UI, Segoe UI, sans-serif" font-size="32" font-weight="700" fill="#18191C">{}</text>
"##,
                    escape_svg_xml(line)
                ));
                title_y += 46;
            }

            // Author circular monogram fallback (overlaid with real photo below when available)
            if avatar.is_none() {
                svg.push_str(&format!(
                    r##"  <circle cx="55" cy="1385" r="21" fill="#FF2442" fill-opacity="0.14"/>
  <text x="55" y="1393" text-anchor="middle" font-family="Microsoft YaHei UI, Segoe UI, sans-serif" font-size="20" font-weight="700" fill="#FF2442">{}</text>
"##,
                    escape_svg_xml(&initial)
                ));
            }

            // Author nickname + right-aligned #FF2442 ♥ likes
            let author_max_chars = if meta.like_count.is_some() { 20 } else { 30 };
            let author_short = truncate_chars(&author_name, author_max_chars);
            svg.push_str(&format!(
                r##"  <text x="90" y="1393" font-family="Microsoft YaHei UI, Segoe UI, sans-serif" font-size="23" font-weight="400" fill="#5C6069">{}</text>
"##,
                escape_svg_xml(&author_short)
            ));

            if let Some(likes) = meta.like_count {
                let formatted = format_metric_count(likes);
                svg.push_str(&format!(
                    r##"  <text x="866" y="1393" text-anchor="end" font-family="Segoe UI, Microsoft YaHei UI, sans-serif" font-size="22" font-weight="500"><tspan fill="#FF2442">♥</tspan><tspan fill="#6B7280"> {}</tspan></text>
"##,
                    escape_svg_xml(&formatted)
                ));
            }

            // Outer hairline frame so white footer stays crisp on light gallery background
            svg.push_str(
                r##"  <rect x="1" y="1" width="898" height="1438" fill="none" stroke="#E5E7EB" stroke-width="2"/>
</svg>"##,
            );

            if let Some(overlay_img) = Self::render_svg_with_fonts(svg.as_bytes(), H) {
                image::imageops::overlay(&mut img, &overlay_img.to_rgba8(), 0, 0);
            } else {
                fill_rect(
                    &mut img,
                    0,
                    COVER_H,
                    W,
                    H - COVER_H,
                    Rgba([255, 255, 255, 255]),
                );
                fill_rect(&mut img, 0, COVER_H, W, 2, Rgba([239, 239, 239, 255]));
                draw_rect_outline(&mut img, 0, 0, W, H, 2, Rgba([229, 231, 235, 255]));
            }

            if let Some(av) = avatar {
                composite_circular_avatar(&mut img, av, 55, 1385, 21);
            }

            return DynamicImage::ImageRgba8(img);
        }

        // Clean 900×1440 text-only editorial fallback with 12px #FF2442 top ribbon
        let mut svg = String::with_capacity(4096);
        svg.push_str(&format!(
            r##"<svg xmlns="http://www.w3.org/2000/svg" width="{W}" height="{H}" viewBox="0 0 {W} {H}">
  <rect x="0" y="0" width="{W}" height="{H}" fill="#FFFFFF"/>
  <rect x="0" y="0" width="{W}" height="12" fill="#FF2442"/>
  <rect x="1" y="1" width="898" height="1438" fill="none" stroke="#E5E7EB" stroke-width="2"/>
"##
        ));

        if avatar.is_none() {
            svg.push_str(&format!(
                r##"  <circle cx="81" cy="89" r="29" fill="#FF2442"/>
  <text x="81" y="99" text-anchor="middle" font-family="Microsoft YaHei UI, Segoe UI, sans-serif" font-size="26" font-weight="700" fill="#FFFFFF">{}</text>
"##,
                escape_svg_xml(&initial)
            ));
        }

        let mut sub_parts = Vec::new();
        if let Some(handle_line) = meta.display_handle_line() {
            sub_parts.push(handle_line);
        } else {
            sub_parts.push(meta.platform.display_name().to_string());
        }
        if let Some(ref date) = meta.published_at_text {
            let trimmed = date.trim();
            if !trimmed.is_empty() {
                sub_parts.push(trimmed.chars().take(16).collect());
            }
        }
        let sub_line = sub_parts.join(" · ");

        svg.push_str(&format!(
            r##"  <text x="128" y="84" font-family="Microsoft YaHei UI, Segoe UI, sans-serif" font-size="27" font-weight="700" fill="#111827">{}</text>
  <text x="128" y="114" font-family="Microsoft YaHei UI, Segoe UI, sans-serif" font-size="19" font-weight="400" fill="#6B7280">{}</text>
  <rect x="52" y="144" width="796" height="2" fill="#F3F4F6"/>
"##,
            escape_svg_xml(&truncate_chars(&author_name, 26)),
            escape_svg_xml(&truncate_chars(&sub_line, 40)),
        ));

        let mut cursor_y = 212u32;
        if let Some(headline) = meta
            .article_title
            .as_deref()
            .map(str::trim)
            .filter(|s| !s.is_empty())
        {
            for line in wrap_cjk_aware_ellipsis(headline, 36, 3) {
                svg.push_str(&format!(
                    r##"  <text x="52" y="{cursor_y}" font-family="Microsoft YaHei UI, Segoe UI, sans-serif" font-size="36" font-weight="700" fill="#111827">{}</text>
"##,
                    escape_svg_xml(&line)
                ));
                cursor_y += 50;
            }
            cursor_y += 14;
        }

        let body_source = meta.body_text.trim();
        let title_trimmed = meta.article_title.as_deref().map(str::trim).unwrap_or("");
        if !body_source.is_empty() && body_source != title_trimmed {
            for line in wrap_cjk_aware_ellipsis(body_source, 48, 16) {
                if cursor_y > 1300 {
                    break;
                }
                svg.push_str(&format!(
                    r##"  <text x="52" y="{cursor_y}" font-family="Microsoft YaHei UI, Segoe UI, sans-serif" font-size="26" font-weight="400" fill="#374151">{}</text>
"##,
                    escape_svg_xml(&line)
                ));
                cursor_y += 42;
            }
        }

        let mut metrics = Vec::new();
        if let Some(l) = meta.like_count {
            metrics.push(format!("{} 赞", format_metric_count(l)));
        }
        if let Some(rt) = meta.repost_count {
            metrics.push(format!("{} 收藏", format_metric_count(rt)));
        }
        if let Some(r) = meta.reply_count {
            metrics.push(format!("{} 评论", format_metric_count(r)));
        }
        let footer_text = if metrics.is_empty() {
            meta.platform.open_action_label().to_string()
        } else {
            metrics.join("   ")
        };

        svg.push_str(&format!(
            r##"  <rect x="52" y="1354" width="796" height="2" fill="#F3F4F6"/>
  <text x="52" y="1402" font-family="Microsoft YaHei UI, Segoe UI, sans-serif" font-size="20" font-weight="400" fill="#6B7280">{}</text>
</svg>"##,
            escape_svg_xml(&footer_text)
        ));

        let mut base = Self::render_svg_with_fonts(svg.as_bytes(), H).unwrap_or_else(|| {
            let mut fallback = RgbaImage::from_pixel(W, H, Rgba([255, 255, 255, 255]));
            fill_rect(&mut fallback, 0, 0, W, 12, Rgba([255, 36, 66, 255]));
            draw_rect_outline(&mut fallback, 0, 0, W, H, 2, Rgba([229, 231, 235, 255]));
            DynamicImage::ImageRgba8(fallback)
        });

        if let Some(av) = avatar {
            let mut rgba = base.to_rgba8();
            composite_circular_avatar(&mut rgba, av, 81, 89, 29);
            base = DynamicImage::ImageRgba8(rgba);
        }

        base
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

    /// Renders a crisp `1200×750` light editorial paper bookmark card matching
    /// `MediaArtwork.swift::webPageCard` 1:1 (warm `#F5F5F3` canvas, elevated `#FFFFFF` card,
    /// luminance-filtered theme-color top ribbon with domain-hash fallback, real favicon or
    /// monogram badge, site name & domain, `WEB` pill, up to 3-line title + 3-line description,
    /// bottom canonical URL & `↗ 默认浏览器打开` badge).
    pub fn web_page_card(
        title: &str,
        domain: &str,
        site_name: Option<&str>,
        description: Option<&str>,
        url_string: Option<&str>,
        theme_color: Option<&str>,
        favicon: Option<&DynamicImage>,
    ) -> DynamicImage {
        let (w, h) = (1200u32, 750u32);
        let accent_u32 = resolve_web_card_accent_hex(theme_color, domain);
        let accent_hex = format!("#{accent_u32:06X}");
        let clean_domain = domain.trim().trim_start_matches("www.");
        let domain_display = if clean_domain.is_empty() {
            "web"
        } else {
            clean_domain
        };
        let primary_header = site_name
            .map(str::trim)
            .filter(|s| !s.is_empty())
            .unwrap_or(domain_display);
        let display_title = {
            let t = title.trim();
            if t.is_empty() {
                domain_display
            } else {
                t
            }
        };
        let title_lines = wrap_cjk_aware(display_title, 26, 3);
        let desc_lines = description
            .map(str::trim)
            .filter(|s| !s.is_empty())
            .map(|d| wrap_cjk_aware(d, 44, 3))
            .unwrap_or_default();
        let footer_url = url_string
            .map(str::trim)
            .filter(|s| !s.is_empty())
            .map(str::to_string)
            .unwrap_or_else(|| format!("https://{domain_display}"));
        let footer_url_short = truncate_chars(&footer_url, 68);
        let initial = domain_display
            .chars()
            .next()
            .unwrap_or('W')
            .to_ascii_uppercase()
            .to_string();

        let mut svg = String::with_capacity(4096);
        svg.push_str(&format!(
            r##"<svg xmlns="http://www.w3.org/2000/svg" width="{w}" height="{h}" viewBox="0 0 {w} {h}">
  <defs>
    <clipPath id="cardClip"><rect x="34" y="34" width="1132" height="682" rx="28" ry="28"/></clipPath>
  </defs>
  <rect x="0" y="0" width="{w}" height="{h}" fill="#F5F5F3"/>
  <rect x="34" y="34" width="1132" height="682" rx="28" ry="28" fill="#FFFFFF" stroke="#E5E7EB" stroke-width="2"/>
  <g clip-path="url(#cardClip)">
    <rect x="34" y="34" width="1132" height="12" fill="{accent_hex}"/>
  </g>
"##
        ));

        // Header icon slot at top-left (y = 86..138 matching macOS y = 612 bottom-up)
        if favicon.is_some() {
            svg.push_str(
                r##"  <rect x="78" y="86" width="52" height="52" rx="13" ry="13" fill="#F3F4F6" stroke="#000000" stroke-opacity="0.08" stroke-width="1.5"/>
"##,
            );
        } else {
            svg.push_str(&format!(
                r##"  <rect x="78" y="86" width="52" height="52" rx="13" ry="13" fill="{accent_hex}" fill-opacity="0.14"/>
  <text x="104" y="121" text-anchor="middle" font-family="Segoe UI, Microsoft YaHei UI, sans-serif" font-size="25" font-weight="700" fill="{accent_hex}">{}</text>
"##,
                escape_svg_xml(&initial)
            ));
        }

        // Site name, domain & top-right WEB pill
        svg.push_str(&format!(
            r##"  <text x="148" y="109" font-family="Segoe UI, Microsoft YaHei UI, sans-serif" font-size="22" font-weight="700" fill="#111827">{}</text>
  <text x="148" y="135" font-family="Segoe UI, Microsoft YaHei UI, sans-serif" font-size="17" font-weight="400" fill="#6B7280">{}</text>
  <rect x="1018" y="94" width="104" height="36" rx="18" ry="18" fill="{accent_hex}" fill-opacity="0.12"/>
  <text x="1070" y="118" text-anchor="middle" font-family="Segoe UI, Microsoft YaHei UI, sans-serif" font-size="17" font-weight="700" fill="{accent_hex}">WEB</text>
  <rect x="78" y="166" width="1044" height="2" fill="#F0F1F4"/>
"##,
            escape_svg_xml(&truncate_chars(primary_header, 42)),
            escape_svg_xml(&truncate_chars(domain_display, 54)),
        ));

        // Up to 3 lines of main title
        let mut title_y = 242u32;
        for line in &title_lines {
            svg.push_str(&format!(
                r##"  <text x="78" y="{title_y}" font-family="Microsoft YaHei UI, Segoe UI, sans-serif" font-size="44" font-weight="700" fill="#111827">{}</text>
"##,
                escape_svg_xml(line),
            ));
            title_y += 62;
        }

        // Up to 3 lines of description
        let mut desc_y = (title_y + 18).max(418);
        for line in &desc_lines {
            if desc_y > 580 {
                break;
            }
            svg.push_str(&format!(
                r##"  <text x="78" y="{desc_y}" font-family="Microsoft YaHei UI, Segoe UI, sans-serif" font-size="23" font-weight="400" fill="#4B5563">{}</text>
"##,
                escape_svg_xml(line),
            ));
            desc_y += 38;
        }

        // Footer divider, canonical URL & dark browser-open pill
        svg.push_str(&format!(
            r##"  <rect x="78" y="620" width="1044" height="2" fill="#F0F1F4"/>
  <text x="78" y="672" font-family="Segoe UI, Microsoft YaHei UI, sans-serif" font-size="19" font-weight="400" fill="#6B7280">{}</text>
  <rect x="912" y="644" width="210" height="44" rx="22" ry="22" fill="#111827"/>
  <text x="1017" y="672" text-anchor="middle" font-family="Microsoft YaHei UI, Segoe UI, sans-serif" font-size="18" font-weight="700" fill="#FFFFFF">↗ 默认浏览器打开</text>
</svg>"##,
            escape_svg_xml(&footer_url_short),
        ));

        let mut base = Self::render_svg_with_fonts(svg.as_bytes(), w).unwrap_or_else(|| {
            let mut fallback = RgbaImage::from_pixel(w, h, Rgba([245, 245, 243, 255]));
            let r = ((accent_u32 >> 16) & 0xFF) as u8;
            let g = ((accent_u32 >> 8) & 0xFF) as u8;
            let b = (accent_u32 & 0xFF) as u8;
            fill_rect(
                &mut fallback,
                34,
                34,
                w - 68,
                h - 68,
                Rgba([255, 255, 255, 255]),
            );
            fill_rect(&mut fallback, 34, 34, w - 68, 12, Rgba([r, g, b, 255]));
            DynamicImage::ImageRgba8(fallback)
        });

        // Composite the real fetched favicon inside the rounded 52×52 badge (with 4px inset)
        if let Some(icon) = favicon {
            let mut rgba = base.to_rgba8();
            let fitted = icon
                .resize_to_fill(44, 44, image::imageops::FilterType::Triangle)
                .to_rgba8();
            image::imageops::overlay(&mut rgba, &fitted, 82, 90);
            base = DynamicImage::ImageRgba8(rgba);
        }

        base
    }

    /// Backward-compatible wrapper rendering the `1200×750` editorial bookmark card.
    pub fn web_bookmark_card(
        title: &str,
        domain: &str,
        description: Option<&str>,
        favicon: Option<&DynamicImage>,
        theme_color: Option<&str>,
    ) -> DynamicImage {
        Self::web_page_card(title, domain, None, description, None, theme_color, favicon)
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
        Self::render_svg_inner(svg_bytes, max_side, usvg::Options::default())
    }

    /// Rasterizes an SVG buffer with Windows/system UI fonts loaded once via `OnceLock` so
    /// editorial bookmark cards render crisp CJK + Latin typography.
    pub fn render_svg_with_fonts(svg_bytes: &[u8], max_side: u32) -> Option<DynamicImage> {
        let opt = usvg::Options {
            fontdb: cached_ui_fontdb(),
            ..Default::default()
        };
        Self::render_svg_inner(svg_bytes, max_side, opt)
    }

    fn render_svg_inner(
        svg_bytes: &[u8],
        max_side: u32,
        opt: usvg::Options<'_>,
    ) -> Option<DynamicImage> {
        let max_side = max_side.max(1);
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

/// Parses CSS hex colors (`#RGB`, `#RRGGBB`, or `#RRGGBBAA`) from HTML `<meta name="theme-color">`.
pub(crate) fn parse_css_hex_rgb(raw: &str) -> Option<[u8; 3]> {
    let cleaned = raw.trim().trim_start_matches('#');
    if !cleaned.is_ascii() {
        return None;
    }
    match cleaned.len() {
        3 => {
            let mut chars = cleaned.chars();
            let r = chars.next()?.to_digit(16)? as u8;
            let g = chars.next()?.to_digit(16)? as u8;
            let b = chars.next()?.to_digit(16)? as u8;
            Some([r * 17, g * 17, b * 17])
        }
        6 => parse_hex_rgb(cleaned),
        8 => parse_hex_rgb(&cleaned[..6]),
        _ => None,
    }
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

fn cached_ui_fontdb() -> Arc<usvg::fontdb::Database> {
    static FONT_DB: OnceLock<Arc<usvg::fontdb::Database>> = OnceLock::new();
    Arc::clone(FONT_DB.get_or_init(|| {
        let mut db = usvg::fontdb::Database::new();
        let mut loaded_fast = false;
        if let Some(windir) = std::env::var_os("WINDIR") {
            let fonts_dir = std::path::PathBuf::from(windir).join("Fonts");
            for file in ["msyh.ttc", "msyhbd.ttc", "segoeui.ttf", "segoeuib.ttf"] {
                let p = fonts_dir.join(file);
                if p.is_file() && db.load_font_file(&p).is_ok() {
                    loaded_fast = true;
                }
            }
        }
        if !loaded_fast {
            db.load_system_fonts();
        }
        db.set_sans_serif_family("Microsoft YaHei UI");
        Arc::new(db)
    }))
}

pub(crate) fn resolve_web_card_accent_hex(theme_color: Option<&str>, domain: &str) -> u32 {
    if let Some([r, g, b]) = theme_color.and_then(parse_css_hex_rgb) {
        let lum = (u32::from(r) * 299 + u32::from(g) * 587 + u32::from(b) * 114) / 1000;
        // Avoid near-white or near-black theme colors vanishing against the white paper card.
        if lum > 22 && lum < 215 {
            return (u32::from(r) << 16) | (u32::from(g) << 8) | u32::from(b);
        }
    }
    const PALETTE: [u32; 8] = [
        0x2563EB, 0x0F766E, 0x4F46E5, 0xB45309, 0x0369A1, 0x7C3AED, 0xBE123C, 0x334155,
    ];
    let mut hash: u64 = 5381;
    for byte in domain.as_bytes() {
        hash = hash
            .wrapping_shl(5)
            .wrapping_add(hash)
            .wrapping_add(u64::from(*byte));
    }
    PALETTE[(hash as usize) % PALETTE.len()]
}

fn wrap_cjk_aware(raw: &str, max_weight: usize, max_lines: usize) -> Vec<String> {
    let mut result = Vec::new();
    for paragraph in raw.lines() {
        let trimmed = paragraph.trim();
        if trimmed.is_empty() {
            continue;
        }
        let mut current = String::new();
        let mut weight = 0usize;
        for ch in trimmed.chars() {
            let w = if ch.is_ascii() { 1 } else { 2 };
            if weight + w > max_weight && !current.is_empty() {
                result.push(current);
                if result.len() >= max_lines {
                    return result;
                }
                current = ch.to_string();
                weight = w;
            } else {
                current.push(ch);
                weight += w;
            }
        }
        if !current.is_empty() {
            result.push(current);
            if result.len() >= max_lines {
                return result;
            }
        }
    }
    result
}

fn truncate_chars(raw: &str, max_chars: usize) -> String {
    let mut chars = raw.chars();
    let taken: String = chars.by_ref().take(max_chars).collect();
    if chars.next().is_some() {
        format!("{taken}…")
    } else {
        taken
    }
}

fn composite_circular_avatar(
    img: &mut RgbaImage,
    avatar: &DynamicImage,
    cx: u32,
    cy: u32,
    radius: u32,
) {
    let (w, h) = img.dimensions();
    let diam = radius.saturating_mul(2).max(1);
    let fitted = avatar
        .resize_to_fill(diam, diam, image::imageops::FilterType::Triangle)
        .to_rgba8();
    let cx_i = cx as i32;
    let cy_i = cy as i32;
    let r_i = radius as i32;
    let r_sq = r_i * r_i;
    let inner_r_sq = (r_i - 1).max(0) * (r_i - 1).max(0);
    for dy in 0..diam {
        for dx in 0..diam {
            let px = cx_i - r_i + dx as i32;
            let py = cy_i - r_i + dy as i32;
            let ox = px - cx_i;
            let oy = py - cy_i;
            let d2 = ox * ox + oy * oy;
            if d2 <= r_sq && px >= 0 && py >= 0 {
                let ux = px as u32;
                let uy = py as u32;
                if ux < w && uy < h {
                    let mut pixel = *fitted.get_pixel(dx, dy);
                    if d2 > inner_r_sq {
                        blend_pixel(&mut pixel, Rgba([0, 0, 0, 20]));
                    }
                    img.put_pixel(ux, uy, pixel);
                }
            }
        }
    }
}

fn format_metric_count(count: i64) -> String {
    let clamped = count.max(0);
    if clamped >= 1_000_000 {
        format!("{:.1}M", clamped as f64 / 1_000_000.0)
    } else if clamped >= 1_000 {
        format!("{:.1}k", clamped as f64 / 1_000.0)
    } else {
        clamped.to_string()
    }
}

fn wrap_cjk_aware_ellipsis(raw: &str, max_weight: usize, max_lines: usize) -> Vec<String> {
    let mut lines = wrap_cjk_aware(raw, max_weight, max_lines + 1);
    if lines.len() > max_lines {
        lines.truncate(max_lines);
        if let Some(last) = lines.last_mut() {
            let mut chars: Vec<char> = last.chars().collect();
            if chars.len() >= 2 {
                chars.pop();
            }
            *last = format!("{}…", chars.into_iter().collect::<String>());
        }
    }
    lines
}

fn escape_svg_xml(raw: &str) -> String {
    let mut out = String::with_capacity(raw.len());
    for ch in raw.chars() {
        match ch {
            '&' => out.push_str("&amp;"),
            '<' => out.push_str("&lt;"),
            '>' => out.push_str("&gt;"),
            '"' => out.push_str("&quot;"),
            '\'' => out.push_str("&#39;"),
            c if c.is_control() && c != ' ' => {}
            c => out.push(c),
        }
    }
    out
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn parses_css_hex_colors_safely_without_panicking_on_utf8() {
        assert_eq!(parse_css_hex_rgb("#24C8DB"), Some([0x24, 0xC8, 0xDB]));
        assert_eq!(parse_css_hex_rgb("#0af"), Some([0x00, 0xAA, 0xFF]));
        assert_eq!(parse_css_hex_rgb("#112233cc"), Some([0x11, 0x22, 0x33]));
        assert_eq!(parse_css_hex_rgb("你好ab"), None);
        assert_eq!(parse_css_hex_rgb("rgb(1,2,3)"), None);
    }

    #[test]
    fn renders_web_bookmark_card_with_and_without_favicon() {
        let bare = MediaArtwork::web_page_card(
            "Tauri — Build smaller, faster, and more secure desktop applications",
            "tauri.app",
            Some("Tauri"),
            Some("Cross-platform desktop framework built with Rust and web views."),
            Some("https://tauri.app/"),
            Some("#24C8DB"),
            None,
        );
        assert_eq!((bare.width(), bare.height()), (1200, 750));

        let icon =
            DynamicImage::ImageRgba8(RgbaImage::from_pixel(32, 32, Rgba([36, 200, 219, 255])));
        let with_icon =
            MediaArtwork::web_bookmark_card("Tauri", "tauri.app", None, Some(&icon), Some("#0af"));
        assert_eq!((with_icon.width(), with_icon.height()), (1200, 750));

        // Near-white and near-black theme colors must fall back to the deterministic domain palette
        assert_ne!(
            resolve_web_card_accent_hex(Some("#FFFFFF"), "example.com"),
            0xFFFFFF
        );
        assert_ne!(
            resolve_web_card_accent_hex(Some("#000000"), "example.com"),
            0x000000
        );
        assert_eq!(
            resolve_web_card_accent_hex(Some("#2563EB"), "example.com"),
            0x2563EB
        );
    }

    #[test]
    fn renders_native_900x1440_xiaohongshu_post_cards_with_and_without_cover() {
        use crate::models::core::{SocialMediaAttachment, SocialMediaAttachmentKind};

        let meta = SocialPostMetadata {
            platform: SocialPlatform::Xiaohongshu,
            author_name: "视觉研究社".to_string(),
            author_handle: "5f11223344556677889900aa".to_string(),
            author_avatar_url: None,
            published_at_text: Some("2026-11-24 12:00".to_string()),
            body_text: "分享一组 3:4 纸感画册排版参考".to_string(),
            quoted_author: None,
            quoted_text: None,
            article_title: Some("极简网格画册排版参考".to_string()),
            media_urls: vec![
                "https://sns-webpic-qc.xhscdn.com/1.webp".to_string(),
                "https://sns-webpic-qc.xhscdn.com/2.webp".to_string(),
            ],
            media_thumbnail_urls: vec![],
            attachments: vec![
                SocialMediaAttachment::new(
                    SocialMediaAttachmentKind::Photo,
                    "https://sns-webpic-qc.xhscdn.com/1.webp",
                    None,
                ),
                SocialMediaAttachment::new(
                    SocialMediaAttachmentKind::Photo,
                    "https://sns-webpic-qc.xhscdn.com/2.webp",
                    None,
                ),
            ],
            has_video: false,
            video_url: None,
            reply_count: Some(45),
            repost_count: Some(320),
            like_count: Some(12_800),
            view_count: None,
            original_url: "https://www.xiaohongshu.com/explore/67a1b2c3d4e5f60718293a4b"
                .to_string(),
            media_fetch_failed: false,
        };

        // Cover-bearing card: exact 900×1440 with 3:4 cover top + white footer bottom
        let cover =
            DynamicImage::ImageRgba8(RgbaImage::from_pixel(1200, 900, Rgba([42, 96, 224, 255])));
        let avatar =
            DynamicImage::ImageRgba8(RgbaImage::from_pixel(64, 64, Rgba([255, 36, 66, 255])));
        let with_cover =
            MediaArtwork::social_post_card_with_avatar(&meta, Some(&cover), Some(&avatar));
        assert_eq!((with_cover.width(), with_cover.height()), (900, 1440));
        // Top cover zone preserves cover color; bottom footer stays paper-white
        let rgba = with_cover.to_rgba8();
        assert_eq!(rgba.get_pixel(450, 600).0, [42, 96, 224, 255]);
        assert_eq!(rgba.get_pixel(880, 1420).0, [255, 255, 255, 255]);

        // Text-only fallback card: exact 900×1440 with #FF2442 top ribbon
        let text_only = MediaArtwork::xiaohongshu_post_card(&meta, None, None);
        assert_eq!((text_only.width(), text_only.height()), (900, 1440));
        let fb_rgba = text_only.to_rgba8();
        assert_eq!(fb_rgba.get_pixel(450, 5).0, [255, 36, 66, 255]);
    }
}
