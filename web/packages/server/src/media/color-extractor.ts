import sharp from 'sharp';
import {
  deltaE76,
  labFromHex,
  sRGBToHex,
  sRGBToLab,
  type LabColor,
} from '@charkle/shared';
export { extractAudioWaveform } from './audio-waveform.js';

/**
 * Extracts 5–7 perceptually dominant CIELAB swatches from an image buffer using k-means++
 * aligned 1:1 with macOS `ColorExtractor.swift` (48×48, alpha >= 40, 8 iterations, mean sRGB, ΔE76 < 8.0).
 */
export async function extractDominantColors(
  imageBuffer: Buffer,
  targetCount = 6,
): Promise<LabColor[]> {
  const k = Math.max(1, Math.min(8, Math.trunc(targetCount)));
  const { data, info } = await sharp(imageBuffer)
    .rotate()
    .resize(48, 48, { fit: 'inside', withoutEnlargement: true })
    .ensureAlpha()
    .raw()
    .toBuffer({ resolveWithObject: true });

  const pixels: Array<{ r: number; g: number; b: number }> = [];
  for (let i = 0; i < data.length; i += info.channels) {
    const alpha = data[i + 3] ?? 255;
    if (alpha < 40) continue;
    pixels.push({
      r: data[i] / 255,
      g: data[i + 1] / 255,
      b: data[i + 2] / 255,
    });
  }

  if (pixels.length === 0) return [];

  const labPixels = pixels.map((p) => sRGBToLab(p.r, p.g, p.b));
  const targetK = Math.min(k, pixels.length);
  const centroids: Array<{ l: number; a: number; b: number }> = [
    labPixels[Math.floor(labPixels.length / 2)],
  ];

  while (centroids.length < targetK) {
    let farthestIndex = 0;
    let maxMinDist = -1;
    for (let idx = 0; idx < labPixels.length; idx++) {
      const p = labPixels[idx];
      let minDist = Number.POSITIVE_INFINITY;
      for (const c of centroids) {
        const dl = p.l - c.l;
        const da = p.a - c.a;
        const db = p.b - c.b;
        const d = dl * dl + da * da + db * db;
        if (d < minDist) minDist = d;
      }
      if (minDist > maxMinDist) {
        maxMinDist = minDist;
        farthestIndex = idx;
      }
    }
    if (maxMinDist <= 1.0) break;
    centroids.push(labPixels[farthestIndex]);
  }

  const clusterCount = centroids.length;
  const assignments = new Int32Array(labPixels.length);

  for (let iter = 0; iter < 8; iter++) {
    const sumL = new Float64Array(clusterCount);
    const sumA = new Float64Array(clusterCount);
    const sumB = new Float64Array(clusterCount);
    const counts = new Int32Array(clusterCount);

    for (let i = 0; i < labPixels.length; i++) {
      const p = labPixels[i];
      let bestC = 0;
      let bestD = Number.POSITIVE_INFINITY;
      for (let c = 0; c < clusterCount; c++) {
        const ctr = centroids[c];
        const dl = p.l - ctr.l;
        const da = p.a - ctr.a;
        const db = p.b - ctr.b;
        const d = dl * dl + da * da + db * db;
        if (d < bestD) {
          bestD = d;
          bestC = c;
        }
      }
      assignments[i] = bestC;
      sumL[bestC] += p.l;
      sumA[bestC] += p.a;
      sumB[bestC] += p.b;
      counts[bestC]++;
    }

    for (let c = 0; c < clusterCount; c++) {
      if (counts[c] > 0) {
        centroids[c] = {
          l: sumL[c] / counts[c],
          a: sumA[c] / counts[c],
          b: sumB[c] / counts[c],
        };
      }
    }
  }

  const sumR = new Float64Array(clusterCount);
  const sumG = new Float64Array(clusterCount);
  const sumBl = new Float64Array(clusterCount);
  const clusterSize = new Int32Array(clusterCount);

  for (let i = 0; i < pixels.length; i++) {
    const c = assignments[i];
    sumR[c] += pixels[i].r;
    sumG[c] += pixels[i].g;
    sumBl[c] += pixels[i].b;
    clusterSize[c] += 1;
  }

  const rawSwatches: LabColor[] = [];
  for (let c = 0; c < clusterCount; c++) {
    if (clusterSize[c] <= 0) continue;
    const n = clusterSize[c];
    const hex = sRGBToHex(sumR[c] / n, sumG[c] / n, sumBl[c] / n);
    rawSwatches.push(labFromHex(hex, n / pixels.length));
  }

  rawSwatches.sort((a, b) => b.proportion - a.proportion);
  const merged: LabColor[] = [];
  for (const sw of rawSwatches) {
    if (!merged.some((m) => deltaE76(m, sw) < 8.0)) {
      merged.push(sw);
    }
  }

  const total = merged.reduce((acc, c) => acc + c.proportion, 0) || 1;
  return merged.slice(0, k).map((c) => ({
    ...c,
    proportion: Math.round((c.proportion / total) * 10000) / 10000,
  }));
}

/**
 * Computes a deterministic 64-dimensional L2-normalized perceptual visual fingerprint
 * combining spatial CIELAB color blocks (24d), 4x4 luminance layout (16d),
 * 4x4 Sobel edge energy (16d), and global chroma/tone distribution (8d).
 */
export async function computeVisualFingerprint(imageBuffer: Buffer): Promise<number[]> {
  const { data } = await sharp(imageBuffer)
    .rotate()
    .resize(32, 32, { fit: 'fill' })
    .removeAlpha()
    .raw()
    .toBuffer({ resolveWithObject: true });

  const width = 32;
  const height = 32;
  const lum = new Float32Array(width * height);
  const labL = new Float32Array(width * height);
  const labA = new Float32Array(width * height);
  const labB = new Float32Array(width * height);

  for (let i = 0; i < width * height; i++) {
    const r = data[i * 3] / 255;
    const g = data[i * 3 + 1] / 255;
    const b = data[i * 3 + 2] / 255;
    lum[i] = 0.299 * r + 0.587 * g + 0.114 * b;
    const lab = sRGBToLab(r, g, b);
    labL[i] = lab.l / 100;
    labA[i] = lab.a / 128;
    labB[i] = lab.b / 128;
  }

  const vec = new Float32Array(64);
  let idx = 0;

  // 1. 4x2 spatial CIELAB means (8 cells * 3 channels = 24 dims)
  for (let gy = 0; gy < 2; gy++) {
    for (let gx = 0; gx < 4; gx++) {
      let sL = 0;
      let sA = 0;
      let sB = 0;
      let cnt = 0;
      for (let y = gy * 16; y < (gy + 1) * 16; y++) {
        for (let x = gx * 8; x < (gx + 1) * 8; x++) {
          const p = y * width + x;
          sL += labL[p];
          sA += labA[p];
          sB += labB[p];
          cnt++;
        }
      }
      vec[idx++] = sL / cnt;
      vec[idx++] = sA / cnt;
      vec[idx++] = sB / cnt;
    }
  }

  // 2. 4x4 luminance means (16 dims)
  for (let gy = 0; gy < 4; gy++) {
    for (let gx = 0; gx < 4; gx++) {
      let s = 0;
      let cnt = 0;
      for (let y = gy * 8; y < (gy + 1) * 8; y++) {
        for (let x = gx * 8; x < (gx + 1) * 8; x++) {
          s += lum[y * width + x];
          cnt++;
        }
      }
      vec[idx++] = s / cnt;
    }
  }

  // 3. 4x4 gradient/edge energy (16 dims)
  for (let gy = 0; gy < 4; gy++) {
    for (let gx = 0; gx < 4; gx++) {
      let energy = 0;
      let cnt = 0;
      for (let y = gy * 8; y < (gy + 1) * 8; y++) {
        for (let x = gx * 8; x < (gx + 1) * 8; x++) {
          const x1 = Math.min(width - 1, x + 1);
          const y1 = Math.min(height - 1, y + 1);
          const dx = lum[y * width + x1] - lum[y * width + x];
          const dy = lum[y1 * width + x] - lum[y * width + x];
          energy += Math.hypot(dx, dy);
          cnt++;
        }
      }
      vec[idx++] = energy / cnt;
    }
  }

  // 4. 8-bin luminance + chroma histogram (8 dims)
  const hist = new Float32Array(8);
  for (let i = 0; i < width * height; i++) {
    const lBin = Math.min(3, Math.floor(lum[i] * 4));
    hist[lBin] += 1;
    const chroma = Math.hypot(labA[i], labB[i]);
    const cBin = Math.min(3, Math.floor(chroma * 4));
    hist[4 + cBin] += 1;
  }
  for (let i = 0; i < 8; i++) {
    vec[idx++] = hist[i] / (width * height);
  }

  // L2 normalize
  let normSq = 0;
  for (let i = 0; i < vec.length; i++) normSq += vec[i] * vec[i];
  const norm = Math.sqrt(normSq) || 1;
  return Array.from(vec, (v) => v / norm);
}
