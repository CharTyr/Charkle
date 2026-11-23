import sharp from 'sharp';
import {
  deltaE2000,
  labToHex,
  sRGBToLab,
  type LabColor,
} from '@charkle/shared';
export { extractAudioWaveform } from './audio-waveform.js';

interface PixelSample {
  l: number;
  a: number;
  b: number;
}

/**
 * Extracts 5–7 perceptually dominant CIELAB swatches from an image buffer using k-means++
 * with deterministic initialization and ΔE2000 near-duplicate merging.
 */
export async function extractDominantColors(
  imageBuffer: Buffer,
  targetCount = 6,
): Promise<LabColor[]> {
  const k = Math.max(1, Math.min(8, Math.trunc(targetCount)));
  const { data, info } = await sharp(imageBuffer)
    .rotate()
    .resize(64, 64, { fit: 'inside', withoutEnlargement: true })
    .ensureAlpha()
    .raw()
    .toBuffer({ resolveWithObject: true });

  const samples: PixelSample[] = [];
  const totalPixels = info.width * info.height;
  for (let i = 0; i < totalPixels; i++) {
    const off = i * 4;
    const alpha = data[off + 3];
    if (alpha < 128) continue;
    const r = data[off] / 255;
    const g = data[off + 1] / 255;
    const b = data[off + 2] / 255;
    samples.push(sRGBToLab(r, g, b));
  }

  if (samples.length === 0) return [];

  // Deterministic k-means++ centroid initialization
  const centroids: PixelSample[] = [samples[Math.floor(samples.length / 2)]];
  const distSq = new Float64Array(samples.length).fill(Infinity);

  while (centroids.length < k && centroids.length < samples.length) {
    const last = centroids[centroids.length - 1];
    let bestIdx = 0;
    let maxDist = -1;
    for (let i = 0; i < samples.length; i++) {
      const s = samples[i];
      const dl = s.l - last.l;
      const da = s.a - last.a;
      const db = s.b - last.b;
      const d = dl * dl + da * da + db * db;
      if (d < distSq[i]) distSq[i] = d;
      if (distSq[i] > maxDist) {
        maxDist = distSq[i];
        bestIdx = i;
      }
    }
    if (maxDist <= 1e-6) break;
    centroids.push({ ...samples[bestIdx] });
  }

  const assignments = new Int32Array(samples.length);
  const clusterCount = centroids.length;

  for (let iter = 0; iter < 12; iter++) {
    let changed = false;
    const sumL = new Float64Array(clusterCount);
    const sumA = new Float64Array(clusterCount);
    const sumB = new Float64Array(clusterCount);
    const counts = new Int32Array(clusterCount);

    for (let i = 0; i < samples.length; i++) {
      const s = samples[i];
      let bestC = 0;
      let bestD = Infinity;
      for (let c = 0; c < clusterCount; c++) {
        const ctr = centroids[c];
        const dl = s.l - ctr.l;
        const da = s.a - ctr.a;
        const db = s.b - ctr.b;
        const d = dl * dl + da * da + db * db;
        if (d < bestD) {
          bestD = d;
          bestC = c;
        }
      }
      if (assignments[i] !== bestC) {
        assignments[i] = bestC;
        changed = true;
      }
      sumL[bestC] += s.l;
      sumA[bestC] += s.a;
      sumB[bestC] += s.b;
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
    if (!changed) break;
  }

  // Final counts
  const finalCounts = new Int32Array(clusterCount);
  for (let i = 0; i < samples.length; i++) {
    finalCounts[assignments[i]]++;
  }

  let rawSwatches: LabColor[] = [];
  for (let c = 0; c < clusterCount; c++) {
    if (finalCounts[c] <= 0) continue;
    const ctr = centroids[c];
    rawSwatches.push({
      hex: labToHex(ctr.l, ctr.a, ctr.b),
      l: Math.round(ctr.l * 100) / 100,
      a: Math.round(ctr.a * 100) / 100,
      b: Math.round(ctr.b * 100) / 100,
      proportion: finalCounts[c] / samples.length,
    });
  }

  rawSwatches.sort((a, b) => b.proportion - a.proportion);

  // Merge perceptually near-identical clusters (ΔE2000 < 7.5)
  const merged: LabColor[] = [];
  for (const sw of rawSwatches) {
    const existing = merged.find((m) => deltaE2000(m, sw) < 7.5);
    if (existing) {
      const totalProp = existing.proportion + sw.proportion;
      const w1 = existing.proportion / totalProp;
      const w2 = sw.proportion / totalProp;
      existing.l = Math.round((existing.l * w1 + sw.l * w2) * 100) / 100;
      existing.a = Math.round((existing.a * w1 + sw.a * w2) * 100) / 100;
      existing.b = Math.round((existing.b * w1 + sw.b * w2) * 100) / 100;
      existing.hex = labToHex(existing.l, existing.a, existing.b);
      existing.proportion = totalProp;
    } else {
      merged.push({ ...sw });
    }
  }

  // Normalize proportions
  const total = merged.reduce((acc, c) => acc + c.proportion, 0) || 1;
  return merged
    .sort((a, b) => b.proportion - a.proportion)
    .slice(0, k)
    .map((c) => ({
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
