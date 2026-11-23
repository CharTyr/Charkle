//! Perceptual dominant color extraction using downsampled CIELAB k-means clustering.
//!
//! Mirrors `Sources/CharkleCore/Intelligence/ColorExtractor.swift`.

use image::imageops::FilterType;
use image::DynamicImage;

use crate::models::core::LabColor;
use crate::models::moodboard::NormalizedCropRect;

pub struct ColorExtractor;

impl ColorExtractor {
    /// Extracts up to `count` dominant colors sorted by perceptual visual weight,
    /// optionally restricted to a normalized top-left `crop` region.
    pub fn extract_dominant_colors_cropped(
        image: &DynamicImage,
        crop: Option<NormalizedCropRect>,
        count: usize,
    ) -> Vec<LabColor> {
        let Some(crop) = crop else {
            return Self::extract_dominant_colors(image, count);
        };
        if crop == NormalizedCropRect::FULL || crop.width <= 0.04 || crop.height <= 0.04 {
            return Self::extract_dominant_colors(image, count);
        }
        let clamped = crop.clamped();
        let w = image.width();
        let h = image.height();
        let x = ((clamped.x * w as f64).floor() as u32).min(w.saturating_sub(1));
        let y = ((clamped.y * h as f64).floor() as u32).min(h.saturating_sub(1));
        let cw = ((clamped.width * w as f64).round() as u32)
            .max(4)
            .min(w.saturating_sub(x));
        let ch = ((clamped.height * h as f64).round() as u32)
            .max(4)
            .min(h.saturating_sub(y));
        if cw < 4 || ch < 4 {
            return Self::extract_dominant_colors(image, count);
        }
        let cropped = image.crop_imm(x, y, cw, ch);
        Self::extract_dominant_colors(&cropped, count)
    }

    /// Extracts up to `count` dominant colors from `image` using deterministic k-means++ in CIELAB.
    pub fn extract_dominant_colors(image: &DynamicImage, count: usize) -> Vec<LabColor> {
        if count == 0 || image.width() == 0 || image.height() == 0 {
            return Vec::new();
        }
        let pixels = Self::sample_rgb_pixels(image, 48);
        if pixels.is_empty() {
            return Vec::new();
        }

        let k = count.min(8).min(pixels.len());
        let lab_pixels: Vec<(f64, f64, f64)> = pixels
            .iter()
            .map(|&(r, g, b)| LabColor::srgb_to_lab(r, g, b))
            .collect();

        let mut centroids: Vec<(f64, f64, f64)> = Vec::with_capacity(k);
        centroids.push(lab_pixels[lab_pixels.len() / 2]);

        while centroids.len() < k {
            let mut farthest_idx = 0usize;
            let mut max_min_dist = -1.0_f64;
            for (idx, p) in lab_pixels.iter().enumerate() {
                let mut min_dist = f64::MAX;
                for c in &centroids {
                    let dl = p.0 - c.0;
                    let da = p.1 - c.1;
                    let db = p.2 - c.2;
                    let d = dl * dl + da * da + db * db;
                    if d < min_dist {
                        min_dist = d;
                    }
                }
                if min_dist > max_min_dist {
                    max_min_dist = min_dist;
                    farthest_idx = idx;
                }
            }
            if max_min_dist <= 1.0 {
                break;
            }
            centroids.push(lab_pixels[farthest_idx]);
        }

        let cluster_count = centroids.len();
        let mut assignments = vec![0usize; lab_pixels.len()];

        for _ in 0..8 {
            let mut sum_l = vec![0.0_f64; cluster_count];
            let mut sum_a = vec![0.0_f64; cluster_count];
            let mut sum_b = vec![0.0_f64; cluster_count];
            let mut counts = vec![0usize; cluster_count];

            for (i, p) in lab_pixels.iter().enumerate() {
                let mut best_idx = 0usize;
                let mut best_dist = f64::MAX;
                for (c_idx, c) in centroids.iter().enumerate() {
                    let dl = p.0 - c.0;
                    let da = p.1 - c.1;
                    let db = p.2 - c.2;
                    let d = dl * dl + da * da + db * db;
                    if d < best_dist {
                        best_dist = d;
                        best_idx = c_idx;
                    }
                }
                assignments[i] = best_idx;
                sum_l[best_idx] += p.0;
                sum_a[best_idx] += p.1;
                sum_b[best_idx] += p.2;
                counts[best_idx] += 1;
            }

            for c_idx in 0..cluster_count {
                if counts[c_idx] > 0 {
                    let n = counts[c_idx] as f64;
                    centroids[c_idx] = (sum_l[c_idx] / n, sum_a[c_idx] / n, sum_b[c_idx] / n);
                }
            }
        }

        let mut sum_r = vec![0.0_f64; cluster_count];
        let mut sum_g = vec![0.0_f64; cluster_count];
        let mut sum_bl = vec![0.0_f64; cluster_count];
        let mut cluster_size = vec![0usize; cluster_count];

        for (i, &(r, g, b)) in pixels.iter().enumerate() {
            let c_idx = assignments[i];
            sum_r[c_idx] += r;
            sum_g[c_idx] += g;
            sum_bl[c_idx] += b;
            cluster_size[c_idx] += 1;
        }

        let total = pixels.len() as f64;
        let mut raw_swatches = Vec::with_capacity(cluster_count);
        for c_idx in 0..cluster_count {
            if cluster_size[c_idx] == 0 {
                continue;
            }
            let n = cluster_size[c_idx] as f64;
            let r = ((sum_r[c_idx] / n) * 255.0).round().clamp(0.0, 255.0) as u8;
            let g = ((sum_g[c_idx] / n) * 255.0).round().clamp(0.0, 255.0) as u8;
            let b = ((sum_bl[c_idx] / n) * 255.0).round().clamp(0.0, 255.0) as u8;
            let hex = format!("#{r:02X}{g:02X}{b:02X}");
            raw_swatches.push(LabColor::from_hex(&hex, n / total));
        }

        raw_swatches.sort_by(|a, b| {
            b.proportion
                .partial_cmp(&a.proportion)
                .unwrap_or(std::cmp::Ordering::Equal)
        });

        let mut merged: Vec<LabColor> = Vec::new();
        for swatch in raw_swatches {
            if !merged
                .iter()
                .any(|existing| existing.delta_e(&swatch) < 8.0)
            {
                merged.push(swatch);
                if merged.len() >= count {
                    break;
                }
            }
        }
        merged
    }

    fn sample_rgb_pixels(image: &DynamicImage, max_side: u32) -> Vec<(f64, f64, f64)> {
        let orig_w = image.width();
        let orig_h = image.height();
        let scale = (max_side as f64 / orig_w.max(orig_h) as f64).min(1.0);
        let w = ((orig_w as f64 * scale).round() as u32).max(1);
        let h = ((orig_h as f64 * scale).round() as u32).max(1);
        let small = if w != orig_w || h != orig_h {
            image.resize_exact(w, h, FilterType::Triangle)
        } else {
            image.clone()
        };
        let rgba = small.to_rgba8();
        let mut samples = Vec::with_capacity((w * h) as usize);
        for pixel in rgba.pixels() {
            let [r, g, b, a] = pixel.0;
            if a < 40 {
                continue;
            }
            samples.push((r as f64 / 255.0, g as f64 / 255.0, b as f64 / 255.0));
        }
        samples
    }

    /// Best perceptual CIE76 color match distance between `target` and `palette`.
    pub fn best_delta_e(target: &LabColor, palette: &[LabColor]) -> Option<f64> {
        palette
            .iter()
            .map(|c| target.delta_e(c))
            .min_by(|a, b| a.partial_cmp(b).unwrap_or(std::cmp::Ordering::Equal))
    }
}
