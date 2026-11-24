//! Fast, deterministic local perceptual visual descriptor (`visual_fingerprint.rs`)
//! for offline visual similarity and folder affinity on Windows.
//!
//! Extracts a compact 104-float (421-byte) versioned multi-cue descriptor from any image
//! or thumbnail (`Grid520.jpg`) in <1.5ms without external ML runtimes:
//! - 4×4 spatial CIELAB color & lightness layout (48 dims, mid-gray centered, L2-normalized)
//! - Shift-invariant chroma-weighted Hue + neutral + tonal-key histogram (20 dims, Bhattacharyya)
//! - 2×2 spatial 8-bin Sobel edge orientation HOG (32 dims, quadrant-centered, L2-normalized)
//! - 4 global visual complexity & composition scalars (edge density, chroma, contrast, aspect)
//!
//! Stored exclusively in the local SQLite `local_visual_descriptors` cache table so it
//! never alters or conflicts with cross-platform `asset_vectors.feature_print` sync blobs.

use std::path::Path;

use image::imageops::FilterType;
use image::DynamicImage;

use crate::models::core::LabColor;

const MAGIC: [u8; 4] = *b"CHVF";
const VERSION: u8 = 1;

const LAYOUT_DIM: usize = 48; // 4×4 grid × 3 (L, a, b)
const COLOR_HIST_DIM: usize = 20; // 12 hue + 4 neutral lightness + 4 tonal key
const HOG_DIM: usize = 32; // 2×2 quadrants × 8 unsigned edge orientations
const SCALAR_DIM: usize = 4; // edge density, chroma mean, contrast std, aspect ratio log
pub const DESCRIPTOR_FLOATS: usize = LAYOUT_DIM + COLOR_HIST_DIM + HOG_DIM + SCALAR_DIM;
const SERIALIZED_LEN: usize = 5 + DESCRIPTOR_FLOATS * 4;

const SAMPLE_SIZE: u32 = 32;

/// Compact local perceptual visual descriptor for fast pairwise visual comparison.
#[derive(Debug, Clone, PartialEq)]
pub struct LocalVisualDescriptor {
    pub layout: [f32; LAYOUT_DIM],
    pub color_hist: [f32; COLOR_HIST_DIM],
    pub hog: [f32; HOG_DIM],
    pub scalars: [f32; SCALAR_DIM],
}

impl LocalVisualDescriptor {
    /// Extracts a calibrated multi-cue visual descriptor from a decoded image.
    pub fn extract(image: &DynamicImage) -> Self {
        let orig_w = image.width().max(1) as f64;
        let orig_h = image.height().max(1) as f64;
        let aspect_log = ((orig_w / orig_h).ln().clamp(-1.2, 1.2) / 1.2) as f32;

        let resized = image
            .resize_exact(SAMPLE_SIZE, SAMPLE_SIZE, FilterType::Triangle)
            .to_rgba8();

        let n = (SAMPLE_SIZE * SAMPLE_SIZE) as usize;
        let mut luma = vec![0.0_f64; n];
        let mut layout_sum = [0.0_f64; LAYOUT_DIM];
        let mut layout_weight = [0.0_f64; 16];
        let mut hist = [0.0_f64; COLOR_HIST_DIM];

        let mut l_sum = 0.0_f64;
        let mut l_sq_sum = 0.0_f64;
        let mut chroma_sum = 0.0_f64;
        let mut opaque_weight = 0.0_f64;

        for y in 0..SAMPLE_SIZE {
            for x in 0..SAMPLE_SIZE {
                let [r8, g8, b8, a8] = resized.get_pixel(x, y).0;
                let alpha = (a8 as f64) / 255.0;
                // Composite semi-transparent pixels over neutral mid-gray so alpha icons
                // don't artificially look pure black.
                let r = (r8 as f64 / 255.0) * alpha + 0.5 * (1.0 - alpha);
                let g = (g8 as f64 / 255.0) * alpha + 0.5 * (1.0 - alpha);
                let b = (b8 as f64 / 255.0) * alpha + 0.5 * (1.0 - alpha);

                let (l, a, lab_b) = LabColor::srgb_to_lab(r, g, b);
                let idx = (y * SAMPLE_SIZE + x) as usize;
                luma[idx] = l;

                let cell = ((y / 8) * 4 + (x / 8)) as usize;
                let pw = alpha.max(0.15);
                layout_sum[cell * 3] += ((l - 50.0) / 50.0) * pw;
                layout_sum[cell * 3 + 1] += (a / 55.0) * pw;
                layout_sum[cell * 3 + 2] += (lab_b / 55.0) * pw;
                layout_weight[cell] += pw;

                if alpha >= 0.15 {
                    let chroma = a.hypot(lab_b);
                    l_sum += l * pw;
                    l_sq_sum += l * l * pw;
                    chroma_sum += chroma * pw;
                    opaque_weight += pw;

                    // 12 chromatic hue bins weighted by perceptual chroma (ignores white/black/gray margins)
                    if chroma > 8.0 {
                        let hue_deg = lab_b.atan2(a).to_degrees().rem_euclid(360.0);
                        let pos = hue_deg / 30.0; // 0..12
                        let bin0 = (pos.floor() as usize) % 12;
                        let bin1 = (bin0 + 1) % 12;
                        let frac = pos - pos.floor();
                        let cw = ((chroma - 8.0) / 48.0).clamp(0.05, 1.8) * pw;
                        hist[bin0] += cw * (1.0 - frac);
                        hist[bin1] += cw * frac;
                    } else {
                        // 4 achromatic / neutral lightness bins (bounded weight so margins don't dominate)
                        let nbin = ((l / 25.0).floor() as usize).min(3);
                        hist[12 + nbin] += 0.28 * pw;
                    }

                    // 4 global tonal-key bins (low-key vs mid vs high-key lighting)
                    let tbin = ((l / 25.0).floor() as usize).min(3);
                    hist[16 + tbin] += 0.26 * pw;
                }
            }
        }

        // 1. Finalize 4×4 spatial CIELAB layout (L2-normalized)
        let mut layout = [0.0_f32; LAYOUT_DIM];
        for cell in 0..16 {
            let w = layout_weight[cell].max(1e-6);
            layout[cell * 3] = (layout_sum[cell * 3] / w) as f32;
            layout[cell * 3 + 1] = (layout_sum[cell * 3 + 1] / w) as f32;
            layout[cell * 3 + 2] = (layout_sum[cell * 3 + 2] / w) as f32;
        }
        l2_normalize(&mut layout);

        // 2. Finalize shift-invariant color/tone histogram (square-root probabilities for Bhattacharyya)
        let mut color_hist = [0.0_f32; COLOR_HIST_DIM];
        let hist_sum: f64 = hist.iter().sum();
        if hist_sum > 1e-9 {
            for (dst, src) in color_hist.iter_mut().zip(hist.iter()) {
                *dst = (*src / hist_sum).max(0.0).sqrt() as f32;
            }
        }

        // 3. Finalize 2×2 spatial 8-orientation Sobel HOG (quadrant mean-centered + L2-normalized)
        let mut hog_raw = [0.0_f64; HOG_DIM];
        let mut grad_mag_sum = 0.0_f64;
        let mut grad_count = 0.0_f64;
        let stride = SAMPLE_SIZE as usize;

        for y in 1..(SAMPLE_SIZE as usize - 1) {
            for x in 1..(SAMPLE_SIZE as usize - 1) {
                let tl = luma[(y - 1) * stride + (x - 1)];
                let tc = luma[(y - 1) * stride + x];
                let tr = luma[(y - 1) * stride + (x + 1)];
                let ml = luma[y * stride + (x - 1)];
                let mr = luma[y * stride + (x + 1)];
                let bl = luma[(y + 1) * stride + (x - 1)];
                let bc = luma[(y + 1) * stride + x];
                let br = luma[(y + 1) * stride + (x + 1)];

                let gx = (tr + 2.0 * mr + br) - (tl + 2.0 * ml + bl);
                let gy = (bl + 2.0 * bc + br) - (tl + 2.0 * tc + tr);
                let mag = gx.hypot(gy);
                grad_mag_sum += mag;
                grad_count += 1.0;

                if mag > 3.0 {
                    let angle_deg = gy.atan2(gx).to_degrees().rem_euclid(180.0);
                    let pos = angle_deg / 22.5; // 0..8
                    let b0 = (pos.floor() as usize) % 8;
                    let b1 = (b0 + 1) % 8;
                    let frac = pos - pos.floor();
                    let quad = (if y >= 16 { 2 } else { 0 }) + (if x >= 16 { 1 } else { 0 });
                    hog_raw[quad * 8 + b0] += mag * (1.0 - frac);
                    hog_raw[quad * 8 + b1] += mag * frac;
                }
            }
        }

        let mut hog = [0.0_f32; HOG_DIM];
        for quad in 0..4 {
            let slice = &hog_raw[quad * 8..(quad + 1) * 8];
            let mean = slice.iter().sum::<f64>() / 8.0;
            for b in 0..8 {
                hog[quad * 8 + b] = (slice[b] - mean) as f32;
            }
        }
        l2_normalize(&mut hog);

        // 4. Global visual complexity & style scalars
        let denom = opaque_weight.max(1e-6);
        let l_mean = l_sum / denom;
        let l_var = (l_sq_sum / denom - l_mean * l_mean).max(0.0);
        let contrast_std = (l_var.sqrt() / 35.0).clamp(0.0, 1.0) as f32;
        let chroma_mean = ((chroma_sum / denom) / 60.0).clamp(0.0, 1.0) as f32;
        let edge_density = ((grad_mag_sum / grad_count.max(1.0)) / 95.0).clamp(0.0, 1.0) as f32;

        Self {
            layout,
            color_hist,
            hog,
            scalars: [edge_density, chroma_mean, contrast_std, aspect_log],
        }
    }

    /// Opens an image file from disk (such as a `Grid520.jpg` thumbnail) and extracts its descriptor.
    pub fn extract_from_path(path: &Path) -> Option<Self> {
        let img = image::open(path).ok()?;
        Some(Self::extract(&img))
    }

    /// Serializes the descriptor into a compact 421-byte versioned binary blob.
    pub fn to_bytes(&self) -> Vec<u8> {
        let mut out = Vec::with_capacity(SERIALIZED_LEN);
        out.extend_from_slice(&MAGIC);
        out.push(VERSION);
        for v in self
            .layout
            .iter()
            .chain(self.color_hist.iter())
            .chain(self.hog.iter())
            .chain(self.scalars.iter())
        {
            out.extend_from_slice(&v.to_le_bytes());
        }
        out
    }

    /// Deserializes a versioned `LocalVisualDescriptor` blob, returning `None` on unknown or corrupt payloads.
    pub fn from_bytes(bytes: &[u8]) -> Option<Self> {
        if bytes.len() != SERIALIZED_LEN || bytes[0..4] != MAGIC || bytes[4] != VERSION {
            return None;
        }
        let mut cursor = 5;
        let mut read_f32 = || -> Option<f32> {
            let chunk: [u8; 4] = bytes.get(cursor..cursor + 4)?.try_into().ok()?;
            cursor += 4;
            let val = f32::from_le_bytes(chunk);
            val.is_finite().then_some(val)
        };

        let mut layout = [0.0_f32; LAYOUT_DIM];
        for v in &mut layout {
            *v = read_f32()?;
        }
        let mut color_hist = [0.0_f32; COLOR_HIST_DIM];
        for v in &mut color_hist {
            *v = read_f32()?;
        }
        let mut hog = [0.0_f32; HOG_DIM];
        for v in &mut hog {
            *v = read_f32()?;
        }
        let mut scalars = [0.0_f32; SCALAR_DIM];
        for v in &mut scalars {
            *v = read_f32()?;
        }

        Some(Self {
            layout,
            color_hist,
            hog,
            scalars,
        })
    }

    /// Calibrated perceptual visual similarity in `[0.0, 1.0]` with a strict noise floor so
    /// unrelated images score `0.0` rather than padding false-positive matches.
    pub fn similarity(&self, other: &Self) -> f64 {
        let layout_cos = dot(&self.layout, &other.layout).clamp(-1.0, 1.0);
        let color_bc = dot(&self.color_hist, &other.color_hist).clamp(0.0, 1.0);
        let hog_cos = dot(&self.hog, &other.hog).clamp(-1.0, 1.0);

        let layout_sim = ((layout_cos - 0.42) / 0.58).clamp(0.0, 1.0);
        let color_sim = ((color_bc - 0.64) / 0.36).clamp(0.0, 1.0);
        let hog_sim = ((hog_cos - 0.28) / 0.72).clamp(0.0, 1.0);

        // Require at least one genuine visual cue (spatial layout, chromatic mood, or edge structure)
        // to cross its noise floor before allowing style scalars to contribute.
        if layout_sim < 0.08 && color_sim < 0.14 && hog_sim < 0.25 {
            return 0.0;
        }

        let mut sq_diff = 0.0_f64;
        for i in 0..SCALAR_DIM {
            let d = f64::from(self.scalars[i]) - f64::from(other.scalars[i]);
            sq_diff += d * d;
        }
        let rms = (sq_diff / SCALAR_DIM as f64).sqrt();
        let style_sim = (1.0 - rms / 0.55).clamp(0.0, 1.0);

        let combined = 0.42 * layout_sim + 0.34 * color_sim + 0.16 * hog_sim + 0.08 * style_sim;
        if combined < 0.18 {
            0.0
        } else {
            combined.clamp(0.0, 1.0)
        }
    }
}

fn l2_normalize(values: &mut [f32]) {
    let norm_sq: f64 = values.iter().map(|&v| f64::from(v) * f64::from(v)).sum();
    if norm_sq > 1e-12 {
        let inv = 1.0 / norm_sq.sqrt();
        for v in values.iter_mut() {
            *v = (f64::from(*v) * inv) as f32;
        }
    }
}

fn dot(a: &[f32], b: &[f32]) -> f64 {
    a.iter()
        .zip(b.iter())
        .map(|(&x, &y)| f64::from(x) * f64::from(y))
        .sum()
}

#[cfg(test)]
mod tests {
    use super::*;
    use image::{Rgba, RgbaImage};

    fn make_card(bg: [u8; 3], accent: [u8; 3], cx: i32, cy: i32, radius: i32) -> DynamicImage {
        let mut img = RgbaImage::from_pixel(128, 128, Rgba([bg[0], bg[1], bg[2], 255]));
        // Subtle dark outer bezel mimicking cards that share a dark border
        for x in 0..128 {
            for b in 0..6 {
                img.put_pixel(x, b, Rgba([18, 20, 24, 255]));
                img.put_pixel(x, 127 - b, Rgba([18, 20, 24, 255]));
            }
        }
        for y in 0..128 {
            for b in 0..6 {
                img.put_pixel(b, y, Rgba([18, 20, 24, 255]));
                img.put_pixel(127 - b, y, Rgba([18, 20, 24, 255]));
            }
        }
        for y in 0..128 {
            for x in 0..128 {
                let dx = x as i32 - cx;
                let dy = y as i32 - cy;
                if dx * dx + dy * dy <= radius * radius {
                    img.put_pixel(x, y, Rgba([accent[0], accent[1], accent[2], 255]));
                }
            }
        }
        DynamicImage::ImageRgba8(img)
    }

    #[test]
    fn round_trips_bytes_and_rejects_foreign_blobs() {
        let img = make_card([16, 44, 34], [18, 185, 118], 76, 52, 26);
        let desc = LocalVisualDescriptor::extract(&img);
        let bytes = desc.to_bytes();
        assert_eq!(bytes.len(), SERIALIZED_LEN);
        let decoded = LocalVisualDescriptor::from_bytes(&bytes).expect("valid CHVF payload");
        assert_eq!(desc, decoded);

        assert!(LocalVisualDescriptor::from_bytes(b"bplist00applevision").is_none());
        assert!(LocalVisualDescriptor::from_bytes(&bytes[..12]).is_none());
    }

    #[test]
    fn ranks_visually_similar_cards_above_unrelated_cards_sharing_dark_border() {
        let emerald_a =
            LocalVisualDescriptor::extract(&make_card([18, 46, 36], [20, 188, 120], 78, 52, 26));
        let emerald_b =
            LocalVisualDescriptor::extract(&make_card([22, 54, 42], [26, 174, 112], 72, 58, 24));
        let mustard_red =
            LocalVisualDescriptor::extract(&make_card([225, 168, 24], [212, 42, 34], 76, 52, 26));
        let beige_brown =
            LocalVisualDescriptor::extract(&make_card([196, 182, 165], [118, 96, 78], 76, 52, 26));

        let sim_same_theme = emerald_a.similarity(&emerald_b);
        let sim_mustard = emerald_a.similarity(&mustard_red);
        let sim_beige = emerald_a.similarity(&beige_brown);

        assert!(
            sim_same_theme > 0.70,
            "same visual theme should score high, got {sim_same_theme}"
        );
        assert!(
            sim_mustard < 0.25 && sim_beige < 0.25,
            "unrelated themes with shared dark border should stay low/zero: mustard={sim_mustard}, beige={sim_beige}"
        );
        assert!(sim_same_theme > sim_mustard + 0.45);
        assert!(sim_same_theme > sim_beige + 0.45);
    }
}
