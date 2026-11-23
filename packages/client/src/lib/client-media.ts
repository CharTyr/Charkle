import {
  deltaE2000,
  encodeBytesBase64,
  labToHex,
  sRGBToLab,
  type ClientPreprocessedMedia,
  type LabColor,
} from '@charkle/shared';

const IMAGE_EXTENSIONS = new Set([
  'jpg',
  'jpeg',
  'png',
  'gif',
  'apng',
  'webp',
  'avif',
  'bmp',
  'svg',
  'ico',
]);

const VIDEO_EXTENSIONS = new Set(['mp4', 'mov', 'm4v', 'webm', 'ogv', 'mkv']);

const AUDIO_EXTENSIONS = new Set([
  'mp3',
  'wav',
  'm4a',
  'aac',
  'ogg',
  'opus',
  'flac',
  'aif',
  'aiff',
]);

const MAX_AUDIO_DECODE_BYTES = 64 * 1024 * 1024;
const MEDIA_DECODE_TIMEOUT_MS = 6000;
const WAVEFORM_BAR_COUNT = 48;

interface PixelLabSample {
  l: number;
  a: number;
  b: number;
}

function fileExtension(fileName?: string): string {
  if (!fileName) return '';
  const dot = fileName.lastIndexOf('.');
  if (dot < 0 || dot === fileName.length - 1) return '';
  return fileName.slice(dot + 1).toLowerCase();
}

function classifyMediaCategory(
  mimeType?: string,
  fileName?: string,
): 'image' | 'video' | 'audio' | 'other' {
  const mime = (mimeType || '').toLowerCase().trim();
  const ext = fileExtension(fileName);

  if (mime.startsWith('image/') || IMAGE_EXTENSIONS.has(ext)) {
    // Skip raw/Photoshop files that browsers cannot decode directly
    if (ext === 'psd' || ext === 'raw' || ext === 'dng' || ext === 'cr2' || ext === 'nef') {
      return 'other';
    }
    return 'image';
  }
  if (mime.startsWith('video/') || VIDEO_EXTENSIONS.has(ext)) {
    return 'video';
  }
  if (mime.startsWith('audio/') || AUDIO_EXTENSIONS.has(ext)) {
    return 'audio';
  }
  return 'other';
}

function isSVGAsset(mimeType?: string, fileName?: string): boolean {
  const mime = (mimeType || '').toLowerCase();
  return mime === 'image/svg+xml' || fileExtension(fileName) === 'svg';
}

function withTimeout<T>(promise: Promise<T>, ms: number): Promise<T> {
  return new Promise<T>((resolve, reject) => {
    const timer = window.setTimeout(() => {
      reject(new Error('Media preprocessing timeout'));
    }, ms);
    promise.then(
      (val) => {
        window.clearTimeout(timer);
        resolve(val);
      },
      (err) => {
        window.clearTimeout(timer);
        reject(err);
      },
    );
  });
}

function createCanvas(width: number, height: number): HTMLCanvasElement {
  const canvas = document.createElement('canvas');
  canvas.width = Math.max(1, Math.round(width));
  canvas.height = Math.max(1, Math.round(height));
  return canvas;
}

function stripDataUrlPrefix(dataUrl: string): string | null {
  const idx = dataUrl.indexOf(',');
  if (idx < 0) return null;
  const raw = dataUrl.slice(idx + 1);
  return raw.length > 0 ? raw : null;
}

function renderJpegThumbnailBase64(
  source: CanvasImageSource,
  sourceWidth: number,
  sourceHeight: number,
  maxDimension: number,
  quality: number,
): string | null {
  if (sourceWidth <= 0 || sourceHeight <= 0) return null;
  const scale = Math.min(1, maxDimension / Math.max(sourceWidth, sourceHeight));
  const outW = Math.max(1, Math.round(sourceWidth * scale));
  const outH = Math.max(1, Math.round(sourceHeight * scale));

  const canvas = createCanvas(outW, outH);
  const ctx = canvas.getContext('2d');
  if (!ctx) return null;

  ctx.fillStyle = '#FFFFFF';
  ctx.fillRect(0, 0, outW, outH);
  ctx.imageSmoothingEnabled = true;
  ctx.imageSmoothingQuality = 'high';
  ctx.drawImage(source, 0, 0, outW, outH);

  try {
    return stripDataUrlPrefix(canvas.toDataURL('image/jpeg', quality));
  } catch {
    return null;
  }
}

/**
 * Extracts 5–6 perceptually dominant CIELAB swatches from an image source via a
 * downsampled 48×48 canvas, deterministic k-means++, and ΔE2000 cluster merging.
 */
function extractDominantColorsFromSource(
  source: CanvasImageSource,
  sourceWidth: number,
  sourceHeight: number,
  targetCount = 6,
): LabColor[] {
  const k = Math.max(1, Math.min(8, Math.trunc(targetCount)));
  const scale = Math.min(1, 48 / Math.max(sourceWidth, sourceHeight, 1));
  const sampleW = Math.max(1, Math.round(sourceWidth * scale));
  const sampleH = Math.max(1, Math.round(sourceHeight * scale));

  const canvas = createCanvas(sampleW, sampleH);
  const ctx = canvas.getContext('2d', { willReadFrequently: true });
  if (!ctx) return [];

  ctx.clearRect(0, 0, sampleW, sampleH);
  ctx.imageSmoothingEnabled = true;
  ctx.imageSmoothingQuality = 'medium';
  ctx.drawImage(source, 0, 0, sampleW, sampleH);

  let data: Uint8ClampedArray;
  try {
    data = ctx.getImageData(0, 0, sampleW, sampleH).data;
  } catch {
    return [];
  }

  const samples: PixelLabSample[] = [];
  const totalPixels = sampleW * sampleH;
  for (let i = 0; i < totalPixels; i++) {
    const off = i * 4;
    if (data[off + 3] < 128) continue;
    const r = data[off] / 255;
    const g = data[off + 1] / 255;
    const b = data[off + 2] / 255;
    samples.push(sRGBToLab(r, g, b));
  }

  if (samples.length === 0) return [];

  // Deterministic k-means++ centroid initialization
  const centroids: PixelLabSample[] = [{ ...samples[Math.floor(samples.length / 2)] }];
  const distSq = new Float64Array(samples.length).fill(Number.POSITIVE_INFINITY);

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
      let bestD = Number.POSITIVE_INFINITY;
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

  const finalCounts = new Int32Array(clusterCount);
  for (let i = 0; i < samples.length; i++) {
    finalCounts[assignments[i]]++;
  }

  const rawSwatches: LabColor[] = [];
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
 * Computes a deterministic 64-dim L2-normalized spatial color/luma/edge Float32Array
 * visual fingerprint matching the backend `computeVisualFingerprint` layout.
 */
function computeFeaturePrintBase64FromSource(source: CanvasImageSource): string | null {
  const width = 32;
  const height = 32;
  const canvas = createCanvas(width, height);
  const ctx = canvas.getContext('2d', { willReadFrequently: true });
  if (!ctx) return null;

  ctx.fillStyle = '#FFFFFF';
  ctx.fillRect(0, 0, width, height);
  ctx.imageSmoothingEnabled = true;
  ctx.imageSmoothingQuality = 'medium';
  ctx.drawImage(source, 0, 0, width, height);

  let data: Uint8ClampedArray;
  try {
    data = ctx.getImageData(0, 0, width, height).data;
  } catch {
    return null;
  }

  const lum = new Float32Array(width * height);
  const labL = new Float32Array(width * height);
  const labA = new Float32Array(width * height);
  const labB = new Float32Array(width * height);

  for (let i = 0; i < width * height; i++) {
    const off = i * 4;
    const r = data[off] / 255;
    const g = data[off + 1] / 255;
    const b = data[off + 2] / 255;
    lum[i] = 0.299 * r + 0.587 * g + 0.114 * b;
    const lab = sRGBToLab(r, g, b);
    labL[i] = lab.l / 100;
    labA[i] = lab.a / 128;
    labB[i] = lab.b / 128;
  }

  const vec = new Float32Array(64);
  let idx = 0;

  // 1. 4x2 spatial CIELAB means (24 dims)
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

  let normSq = 0;
  for (let i = 0; i < vec.length; i++) normSq += vec[i] * vec[i];
  const norm = Math.sqrt(normSq) || 1;
  for (let i = 0; i < vec.length; i++) vec[i] /= norm;

  return encodeBytesBase64(new Uint8Array(vec.buffer, vec.byteOffset, vec.byteLength));
}

function loadImageElement(blob: Blob): Promise<HTMLImageElement> {
  return new Promise((resolve, reject) => {
    const url = URL.createObjectURL(blob);
    const img = new Image();
    img.decoding = 'async';
    img.onload = () => {
      URL.revokeObjectURL(url);
      resolve(img);
    };
    img.onerror = () => {
      URL.revokeObjectURL(url);
      reject(new Error('Image decode failed'));
    };
    img.src = url;
  });
}

async function decodeImageSource(
  blob: Blob,
  mimeType?: string,
  fileName?: string,
): Promise<{
  source: CanvasImageSource;
  width: number;
  height: number;
  cleanup: () => void;
} | null> {
  const isSvg = isSVGAsset(mimeType, fileName);

  if (!isSvg && typeof createImageBitmap === 'function') {
    try {
      const bitmap = await withTimeout(createImageBitmap(blob), MEDIA_DECODE_TIMEOUT_MS);
      if (bitmap.width > 0 && bitmap.height > 0) {
        return {
          source: bitmap,
          width: bitmap.width,
          height: bitmap.height,
          cleanup: () => bitmap.close(),
        };
      }
      bitmap.close();
    } catch {
      // Fall back to HTMLImageElement
    }
  }

  try {
    const img = await withTimeout(loadImageElement(blob), MEDIA_DECODE_TIMEOUT_MS);
    const width = img.naturalWidth || (isSvg ? 1200 : 0);
    const height = img.naturalHeight || (isSvg ? 900 : 0);
    if (width <= 0 || height <= 0) return null;
    return {
      source: img,
      width,
      height,
      cleanup: () => {},
    };
  } catch {
    return null;
  }
}

export function extractVisualMetadataFromSource(
  source: CanvasImageSource,
  width: number,
  height: number,
): ClientPreprocessedMedia | undefined {
  if (width <= 0 || height <= 0) return undefined;
  const pixelWidth = Math.round(width);
  const pixelHeight = Math.round(height);

  const thumbnail520Base64 = renderJpegThumbnailBase64(source, pixelWidth, pixelHeight, 520, 0.82);
  const thumbnail1400Base64 = renderJpegThumbnailBase64(
    source,
    pixelWidth,
    pixelHeight,
    1400,
    0.86,
  );
  const dominantColors = extractDominantColorsFromSource(source, pixelWidth, pixelHeight, 6);
  const featurePrintBase64 = computeFeaturePrintBase64FromSource(source);

  return {
    pixelWidth,
    pixelHeight,
    thumbnail520Base64,
    thumbnail1400Base64,
    dominantColors: dominantColors.length > 0 ? dominantColors : undefined,
    featurePrintBase64,
  };
}

async function preprocessImageBlob(
  blob: Blob,
  mimeType?: string,
  fileName?: string,
): Promise<ClientPreprocessedMedia | undefined> {
  const decoded = await decodeImageSource(blob, mimeType, fileName);
  if (!decoded) return undefined;
  try {
    return extractVisualMetadataFromSource(decoded.source, decoded.width, decoded.height);
  } finally {
    decoded.cleanup();
  }
}

async function preprocessVideoBlob(blob: Blob): Promise<ClientPreprocessedMedia | undefined> {
  const url = URL.createObjectURL(blob);
  const video = document.createElement('video');
  video.muted = true;
  video.playsInline = true;
  video.preload = 'auto';

  try {
    const result = await withTimeout(
      new Promise<ClientPreprocessedMedia | undefined>((resolve, reject) => {
        let settled = false;
        const finish = (val: ClientPreprocessedMedia | undefined) => {
          if (settled) return;
          settled = true;
          resolve(val);
        };
        const fail = (err: Error) => {
          if (settled) return;
          settled = true;
          reject(err);
        };

        const captureFrame = () => {
          const vw = video.videoWidth;
          const vh = video.videoHeight;
          const duration =
            Number.isFinite(video.duration) && video.duration > 0
              ? Math.round(video.duration * 100) / 100
              : null;

          if (vw > 0 && vh > 0) {
            const visual = extractVisualMetadataFromSource(video, vw, vh);
            finish({
              ...visual,
              pixelWidth: vw,
              pixelHeight: vh,
              durationSeconds: duration,
            });
          } else if (duration !== null) {
            finish({ durationSeconds: duration });
          } else {
            finish(undefined);
          }
        };

        video.onloadedmetadata = () => {
          const targetTime =
            Number.isFinite(video.duration) && video.duration > 0.25
              ? Math.min(0.5, video.duration * 0.1)
              : 0;
          if (targetTime > 0) {
            try {
              video.currentTime = targetTime;
              return;
            } catch {
              // Fall through to loadeddata capture
            }
          }
          if (video.readyState >= 2) {
            captureFrame();
          }
        };

        video.onseeked = captureFrame;
        video.onloadeddata = () => {
          if (video.currentTime === 0 && video.videoWidth > 0) {
            captureFrame();
          }
        };
        video.onerror = () => fail(new Error('Unsupported video codec'));
        video.src = url;
        video.load();
      }),
      MEDIA_DECODE_TIMEOUT_MS,
    );
    return result;
  } catch {
    return undefined;
  } finally {
    video.onloadedmetadata = null;
    video.onseeked = null;
    video.onloadeddata = null;
    video.onerror = null;
    video.removeAttribute('src');
    try {
      video.load();
    } catch {
      // Ignore cleanup errors
    }
    URL.revokeObjectURL(url);
  }
}

async function preprocessAudioBlob(blob: Blob): Promise<ClientPreprocessedMedia | undefined> {
  if (blob.size <= 0 || blob.size > MAX_AUDIO_DECODE_BYTES) return undefined;

  const AudioCtx =
    window.AudioContext ||
    (window as unknown as { webkitAudioContext?: typeof AudioContext }).webkitAudioContext;
  if (typeof AudioCtx !== 'function') return undefined;

  let audioCtx: AudioContext | null = null;
  try {
    const arrayBuffer = await blob.arrayBuffer();
    audioCtx = new AudioCtx();
    const audioBuffer = await withTimeout(
      audioCtx.decodeAudioData(arrayBuffer.slice(0)),
      MEDIA_DECODE_TIMEOUT_MS,
    );

    const durationSeconds =
      Number.isFinite(audioBuffer.duration) && audioBuffer.duration > 0
        ? Math.round(audioBuffer.duration * 100) / 100
        : null;

    const totalLength = audioBuffer.length;
    if (totalLength <= 0 || audioBuffer.numberOfChannels <= 0) {
      return durationSeconds !== null ? { durationSeconds } : undefined;
    }

    const channelCount = Math.min(2, audioBuffer.numberOfChannels);
    const channels: Float32Array[] = [];
    for (let ch = 0; ch < channelCount; ch++) {
      channels.push(audioBuffer.getChannelData(ch));
    }

    const barCount = WAVEFORM_BAR_COUNT;
    const samplesPerBar = Math.max(1, Math.floor(totalLength / barCount));
    const rawPeaks = new Float32Array(barCount);
    let maxPeak = 0.001;

    for (let bar = 0; bar < barCount; bar++) {
      const start = bar * samplesPerBar;
      const end = Math.min(totalLength, start + samplesPerBar);
      const step = Math.max(1, Math.floor((end - start) / 512));
      let peak = 0;
      for (let i = start; i < end; i += step) {
        let amp = 0;
        for (let ch = 0; ch < channelCount; ch++) {
          const v = Math.abs(channels[ch][i]);
          if (v > amp) amp = v;
        }
        if (amp > peak) peak = amp;
      }
      rawPeaks[bar] = peak;
      if (peak > maxPeak) maxPeak = peak;
    }

    const waveformPeaks: number[] = Array.from(rawPeaks, (v) => {
      const norm = Math.max(0.08, Math.min(1, v / maxPeak));
      return Math.round(norm * 1000) / 1000;
    });

    return {
      durationSeconds,
      waveformPeaks,
    };
  } catch {
    return undefined;
  } finally {
    if (audioCtx) {
      void audioCtx.close().catch(() => {});
    }
  }
}

/**
 * Pure browser-side media preprocessor generating thumbnails (`grid520` / `preview1400`),
 * natural dimensions, dominant CIELAB color swatches, 64-dim visual fingerprint,
 * video poster frames, and 48-bar audio waveforms before upload.
 *
 * Never throws or blocks an upload if the browser codec does not support a file format.
 */
export async function preprocessBlobForUpload(
  blob: Blob,
  mimeType?: string,
  fileName?: string,
): Promise<ClientPreprocessedMedia | undefined> {
  if (typeof window === 'undefined' || typeof document === 'undefined') {
    return undefined;
  }

  try {
    const category = classifyMediaCategory(mimeType || blob.type, fileName);
    if (category === 'image') {
      return await preprocessImageBlob(blob, mimeType || blob.type, fileName);
    }
    if (category === 'video') {
      return await preprocessVideoBlob(blob);
    }
    if (category === 'audio') {
      return await preprocessAudioBlob(blob);
    }
    return undefined;
  } catch {
    return undefined;
  }
}

export async function preprocessFileForUpload(
  file: File,
): Promise<ClientPreprocessedMedia | undefined> {
  return preprocessBlobForUpload(file, file.type, file.name);
}

/**
 * Preprocesses a raw base64 image payload (used by clipboard paste & screen capture `imageData`).
 */
export async function preprocessBase64Image(
  base64Data: string,
  suggestedName?: string,
): Promise<ClientPreprocessedMedia | undefined> {
  if (typeof window === 'undefined' || typeof document === 'undefined' || !base64Data) {
    return undefined;
  }
  try {
    const clean = base64Data.includes(',') ? base64Data.slice(base64Data.indexOf(',') + 1) : base64Data;
    const bin = atob(clean);
    const bytes = new Uint8Array(bin.length);
    for (let i = 0; i < bin.length; i++) {
      bytes[i] = bin.charCodeAt(i);
    }
    const ext = fileExtension(suggestedName);
    const mime =
      ext === 'jpg' || ext === 'jpeg'
        ? 'image/jpeg'
        : ext === 'webp'
          ? 'image/webp'
          : ext === 'gif'
            ? 'image/gif'
            : ext === 'svg'
              ? 'image/svg+xml'
              : 'image/png';
    return await preprocessBlobForUpload(new Blob([bytes], { type: mime }), mime, suggestedName);
  } catch {
    return undefined;
  }
}
