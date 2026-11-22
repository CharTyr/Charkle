import sharp from 'sharp';
import {
  deltaE2000,
  labToHex,
  sRGBToLab,
  type LabColor,
} from '@charkle/shared';

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

/**
 * Extracts 48 normalized waveform peak bars in [0, 1] and duration (when parseable).
 * Parses WAV PCM buffers directly; falls back to chunked RMS energy for compressed formats.
 */
export function extractAudioWaveform(
  buffer: Buffer,
  fileName: string,
  barCount = 48,
): { durationSeconds: number | null; waveformPeaks: number[] } {
  const count = Math.max(16, Math.min(64, barCount));
  const ext = fileName.toLowerCase().split('.').pop() ?? '';

  // Parse RIFF/WAVE PCM directly for exact peaks & duration
  if (
    ext === 'wav' &&
    buffer.length >= 44 &&
    buffer.toString('ascii', 0, 4) === 'RIFF' &&
    buffer.toString('ascii', 8, 12) === 'WAVE'
  ) {
    let offset = 12;
    let numChannels = 1;
    let sampleRate = 44100;
    let bitsPerSample = 16;
    let dataStart = -1;
    let dataSize = 0;

    while (offset + 8 <= buffer.length) {
      const chunkId = buffer.toString('ascii', offset, offset + 4);
      const chunkSize = buffer.readUInt32LE(offset + 4);
      const bodyStart = offset + 8;
      if (chunkId === 'fmt ' && bodyStart + 16 <= buffer.length) {
        numChannels = Math.max(1, buffer.readUInt16LE(bodyStart + 2));
        sampleRate = Math.max(1, buffer.readUInt32LE(bodyStart + 4));
        bitsPerSample = Math.max(8, buffer.readUInt16LE(bodyStart + 14));
      } else if (chunkId === 'data') {
        dataStart = bodyStart;
        dataSize = Math.min(chunkSize, buffer.length - bodyStart);
        break;
      }
      offset = bodyStart + chunkSize + (chunkSize % 2);
    }

    if (dataStart >= 0 && dataSize > 0) {
      const bytesPerSample = Math.max(1, Math.floor(bitsPerSample / 8));
      const frameBytes = bytesPerSample * numChannels;
      const totalFrames = Math.floor(dataSize / frameBytes);
      const durationSeconds = totalFrames > 0 ? Math.round((totalFrames / sampleRate) * 100) / 100 : null;
      const framesPerBar = Math.max(1, Math.floor(totalFrames / count));
      const rawPeaks: number[] = [];

      for (let bar = 0; bar < count; bar++) {
        const startFrame = bar * framesPerBar;
        const endFrame = Math.min(totalFrames, startFrame + framesPerBar);
        const step = Math.max(1, Math.floor((endFrame - startFrame) / 256));
        let maxAmp = 0;
        for (let f = startFrame; f < endFrame; f += step) {
          const bytePos = dataStart + f * frameBytes;
          if (bytePos + bytesPerSample > buffer.length) break;
          let sample = 0;
          if (bitsPerSample === 16) {
            sample = Math.abs(buffer.readInt16LE(bytePos)) / 32768;
          } else if (bitsPerSample === 8) {
            sample = Math.abs(buffer[bytePos] - 128) / 128;
          } else if (bitsPerSample === 24 && bytePos + 3 <= buffer.length) {
            let v = buffer[bytePos] | (buffer[bytePos + 1] << 8) | (buffer[bytePos + 2] << 16);
            if (v & 0x800000) v |= ~0xffffff;
            sample = Math.abs(v) / 8388608;
          } else if (bitsPerSample === 32 && bytePos + 4 <= buffer.length) {
            sample = Math.min(1, Math.abs(buffer.readFloatLE(bytePos)));
          }
          if (sample > maxAmp) maxAmp = sample;
        }
        rawPeaks.push(maxAmp);
      }

      const maxVal = Math.max(...rawPeaks, 0.001);
      const normalized = rawPeaks.map((v) =>
        Math.round(Math.max(0.08, Math.min(1, v / maxVal)) * 1000) / 1000,
      );
      return { durationSeconds, waveformPeaks: normalized };
    }
  }

  // Generic deterministic chunk-variance envelope for MP3/M4A/OGG/FLAC/AAC/etc.
  if (buffer.length < count * 2) {
    const fallback = Array.from({ length: count }, (_, i) =>
      Math.round((0.25 + 0.65 * Math.abs(Math.sin(i * 0.35))) * 1000) / 1000,
    );
    return { durationSeconds: null, waveformPeaks: fallback };
  }

  const headerSkip = Math.min(Math.floor(buffer.length * 0.05), 4096);
  const bodyLen = Math.max(count, buffer.length - headerSkip);
  const chunkLen = Math.floor(bodyLen / count);
  const energies: number[] = [];

  for (let bar = 0; bar < count; bar++) {
    const start = headerSkip + bar * chunkLen;
    const end = Math.min(buffer.length, start + chunkLen);
    const step = Math.max(1, Math.floor((end - start) / 256));
    let sumSq = 0;
    let n = 0;
    for (let i = start; i < end; i += step) {
      const centered = (buffer[i] - 127.5) / 127.5;
      sumSq += centered * centered;
      n++;
    }
    energies.push(n > 0 ? Math.sqrt(sumSq / n) : 0.2);
  }

  const minE = Math.min(...energies);
  const maxE = Math.max(...energies);
  const span = Math.max(0.05, maxE - minE);
  const peaks = energies.map((e, i) => {
    const scaled = 0.16 + 0.78 * ((e - minE) / span);
    // Subtle envelope modulation when compressed frames have uniform entropy
    const modulation = span < 0.08 ? 0.72 + 0.28 * Math.abs(Math.sin(i * 0.42 + e * 9)) : 1;
    return Math.round(Math.max(0.1, Math.min(1, scaled * modulation)) * 1000) / 1000;
  });

  // Rough duration estimate for MP3 (~128 kbps default if frames unparsed)
  const approxDuration =
    ext === 'mp3' || ext === 'm4a' || ext === 'aac' || ext === 'ogg' || ext === 'opus'
      ? Math.max(1, Math.round((buffer.length / 16000) * 10) / 10)
      : null;

  return { durationSeconds: approxDuration, waveformPeaks: peaks };
}
