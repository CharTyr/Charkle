import JSZip from 'jszip';
import {
  createDefaultMoodboardExportOptions,
  deltaE2000,
  isLightHex,
  labFromHex,
  labToHex,
  mediaKindLocalizedLabel,
  solveEditorialLayout,
  sRGBToHex,
  sRGBToLab,
  type AssetRecord,
  type BoardRect,
  type FigmaBridgeBoardManifest,
  type FigmaBridgeObject,
  type FigmaBridgeObjectGeometry,
  type FigmaBridgeReport,
  type GroupTint,
  type LabColor,
  type MediaKind,
  type NoteStyle,
  type UUID,
} from '@charkle/shared';
import {
  buildAudioWaveformSvg,
  buildColorSwatchSvg,
  buildGenericBadgeSvg,
  buildGitHubRepoSvg,
  buildModel3DSvg,
  buildSocialPostSvg,
  buildTextDocumentSvg,
  buildWebBookmarkSvg,
  escapeXml,
} from '../media/artwork-svg.js';
import type {
  ArtworkRenderRequest,
  CloudflareImagesBinding,
  ContactSheetItemInput,
  ContactSheetRenderResult,
  CropAndPadOptions,
  FigmaBridgeExportRequestParams,
  GeneratedThumbnailsResult,
  IImageProcessor,
  MoodboardExportRequestParams,
  RenderedCardResult,
} from './types.js';
import {
  bytesToBase64,
  bytesToStream,
  posixExtname,
  sha256HexAsync,
  sha256HexSync,
  utf8Decode,
  utf8Encode,
} from './web-crypto-utils.js';

export interface ImageHeaderInfo {
  width: number;
  height: number;
  format: 'png' | 'jpeg' | 'gif' | 'webp' | 'bmp' | 'svg';
  mimeType: string;
}

function readAscii(bytes: Uint8Array, start: number, len: number): string {
  let out = '';
  const end = Math.min(bytes.byteLength, start + len);
  for (let i = start; i < end; i++) {
    out += String.fromCharCode(bytes[i]);
  }
  return out;
}

export function sniffImageMimeType(bytes: Uint8Array, fallback = 'application/octet-stream'): string {
  if (bytes.byteLength >= 8) {
    // PNG
    if (
      bytes[0] === 0x89 &&
      bytes[1] === 0x50 &&
      bytes[2] === 0x4e &&
      bytes[3] === 0x47 &&
      bytes[4] === 0x0d &&
      bytes[5] === 0x0a &&
      bytes[6] === 0x1a &&
      bytes[7] === 0x0a
    ) {
      return 'image/png';
    }
  }
  if (bytes.byteLength >= 3 && bytes[0] === 0xff && bytes[1] === 0xd8 && bytes[2] === 0xff) {
    return 'image/jpeg';
  }
  if (bytes.byteLength >= 6) {
    const head6 = readAscii(bytes, 0, 6);
    if (head6 === 'GIF87a' || head6 === 'GIF89a') return 'image/gif';
  }
  if (
    bytes.byteLength >= 12 &&
    readAscii(bytes, 0, 4) === 'RIFF' &&
    readAscii(bytes, 8, 4) === 'WEBP'
  ) {
    return 'image/webp';
  }
  if (bytes.byteLength >= 2 && bytes[0] === 0x42 && bytes[1] === 0x4d) {
    return 'image/bmp';
  }
  const headText = utf8Decode(bytes.subarray(0, Math.min(512, bytes.byteLength))).trimStart();
  if (headText.startsWith('<svg') || (headText.startsWith('<?xml') && headText.includes('<svg'))) {
    return 'image/svg+xml';
  }
  return fallback;
}

/**
 * Pure-TS binary header parser for PNG, JPEG, GIF, WebP (VP8/VP8L/VP8X), BMP, and SVG.
 * Zero Node or native dependencies.
 */
export function inspectImageHeader(
  bytes: Uint8Array,
  mimeType?: string,
): ImageHeaderInfo | null {
  if (!bytes || bytes.byteLength < 8) return null;
  const view = new DataView(bytes.buffer, bytes.byteOffset, bytes.byteLength);

  // 1. PNG (IHDR at byte offset 16..24)
  if (
    bytes.byteLength >= 24 &&
    bytes[0] === 0x89 &&
    bytes[1] === 0x50 &&
    bytes[2] === 0x4e &&
    bytes[3] === 0x47 &&
    bytes[4] === 0x0d &&
    bytes[5] === 0x0a &&
    bytes[6] === 0x1a &&
    bytes[7] === 0x0a
  ) {
    const width = view.getUint32(16, false);
    const height = view.getUint32(20, false);
    if (width > 0 && height > 0) {
      return { width, height, format: 'png', mimeType: 'image/png' };
    }
  }

  // 2. GIF (GIF87a / GIF89a)
  if (bytes.byteLength >= 10) {
    const sig = readAscii(bytes, 0, 6);
    if (sig === 'GIF87a' || sig === 'GIF89a') {
      const width = view.getUint16(6, true);
      const height = view.getUint16(8, true);
      if (width > 0 && height > 0) {
        return { width, height, format: 'gif', mimeType: 'image/gif' };
      }
    }
  }

  // 3. WebP (RIFF....WEBP -> VP8 / VP8L / VP8X)
  if (
    bytes.byteLength >= 30 &&
    readAscii(bytes, 0, 4) === 'RIFF' &&
    readAscii(bytes, 8, 4) === 'WEBP'
  ) {
    const chunk = readAscii(bytes, 12, 4);
    if (chunk === 'VP8X' && bytes.byteLength >= 30) {
      const width = 1 + (bytes[24] | (bytes[25] << 8) | (bytes[26] << 16));
      const height = 1 + (bytes[27] | (bytes[28] << 8) | (bytes[29] << 16));
      if (width > 0 && height > 0) {
        return { width, height, format: 'webp', mimeType: 'image/webp' };
      }
    } else if (chunk === 'VP8L' && bytes.byteLength >= 25 && bytes[20] === 0x2f) {
      const b0 = bytes[21];
      const b1 = bytes[22];
      const b2 = bytes[23];
      const b3 = bytes[24];
      const width = 1 + (b0 | ((b1 & 0x3f) << 8));
      const height = 1 + (((b1 & 0xc0) >> 6) | (b2 << 2) | ((b3 & 0x0f) << 10));
      if (width > 0 && height > 0) {
        return { width, height, format: 'webp', mimeType: 'image/webp' };
      }
    } else if (chunk === 'VP8 ' && bytes.byteLength >= 30) {
      // Keyframe starts with 3-byte sync code 0x9D 0x01 0x2A at offset 23..25
      if (bytes[23] === 0x9d && bytes[24] === 0x01 && bytes[25] === 0x2a) {
        const width = view.getUint16(26, true) & 0x3fff;
        const height = view.getUint16(28, true) & 0x3fff;
        if (width > 0 && height > 0) {
          return { width, height, format: 'webp', mimeType: 'image/webp' };
        }
      }
    }
  }

  // 4. JPEG (walk markers until SOF0..SOF15 except DHT/JPG/DAC)
  if (bytes.byteLength >= 4 && bytes[0] === 0xff && bytes[1] === 0xd8) {
    let offset = 2;
    while (offset + 4 <= bytes.byteLength) {
      if (bytes[offset] !== 0xff) {
        offset++;
        continue;
      }
      while (offset < bytes.byteLength && bytes[offset] === 0xff) offset++;
      if (offset >= bytes.byteLength) break;
      const marker = bytes[offset++];
      // Standalone markers without length
      if (marker === 0xd8 || marker === 0xd9 || marker === 0x01 || (marker >= 0xd0 && marker <= 0xd7)) {
        continue;
      }
      if (offset + 2 > bytes.byteLength) break;
      const segLen = view.getUint16(offset, false);
      if (segLen < 2) break;

      const isSof =
        (marker >= 0xc0 && marker <= 0xc3) ||
        (marker >= 0xc5 && marker <= 0xc7) ||
        (marker >= 0xc9 && marker <= 0xcb) ||
        (marker >= 0xcd && marker <= 0xcf);
      if (isSof && offset + 7 <= bytes.byteLength) {
        const height = view.getUint16(offset + 3, false);
        const width = view.getUint16(offset + 5, false);
        if (width > 0 && height > 0) {
          return { width, height, format: 'jpeg', mimeType: 'image/jpeg' };
        }
      }
      offset += segLen;
    }
  }

  // 5. BMP (DIB header)
  if (bytes.byteLength >= 26 && bytes[0] === 0x42 && bytes[1] === 0x4d) {
    const width = Math.abs(view.getInt32(18, true));
    const height = Math.abs(view.getInt32(22, true));
    if (width > 0 && height > 0) {
      return { width, height, format: 'bmp', mimeType: 'image/bmp' };
    }
  }

  // 6. SVG (parse <svg ... width="" height="" viewBox="...">)
  const sniffed = mimeType?.toLowerCase().includes('svg')
    ? 'image/svg+xml'
    : sniffImageMimeType(bytes);
  if (sniffed === 'image/svg+xml') {
    const headerStr = utf8Decode(bytes.subarray(0, Math.min(4096, bytes.byteLength)));
    const svgTagMatch = /<svg\b([^>]*)>/i.exec(headerStr);
    if (svgTagMatch) {
      const attrs = svgTagMatch[1];
      const wMatch = /\bwidth\s*=\s*["']\s*([0-9.]+)(?:px)?\s*["']/i.exec(attrs);
      const hMatch = /\bheight\s*=\s*["']\s*([0-9.]+)(?:px)?\s*["']/i.exec(attrs);
      if (wMatch && hMatch) {
        const w = Math.round(Number.parseFloat(wMatch[1]));
        const h = Math.round(Number.parseFloat(hMatch[1]));
        if (w > 0 && h > 0) {
          return { width: w, height: h, format: 'svg', mimeType: 'image/svg+xml' };
        }
      }
      const vbMatch = /\bviewBox\s*=\s*["']\s*[-\d.]+\s+[-\d.]+\s+([0-9.]+)\s+([0-9.]+)\s*["']/i.exec(
        attrs,
      );
      if (vbMatch) {
        const w = Math.round(Number.parseFloat(vbMatch[1]));
        const h = Math.round(Number.parseFloat(vbMatch[2]));
        if (w > 0 && h > 0) {
          return { width: w, height: h, format: 'svg', mimeType: 'image/svg+xml' };
        }
      }
      return { width: 800, height: 600, format: 'svg', mimeType: 'image/svg+xml' };
    }
  }

  return null;
}

function extractSvgColors(svgText: string, maxCount: number): LabColor[] {
  const counts = new Map<string, number>();
  const hexRe = /#([0-9a-fA-F]{6})\b/g;
  let m: RegExpExecArray | null;
  while ((m = hexRe.exec(svgText)) !== null) {
    const hex = `#${m[1].toUpperCase()}`;
    counts.set(hex, (counts.get(hex) ?? 0) + 1);
  }
  if (counts.size === 0) return [];
  const total = Array.from(counts.values()).reduce((a, b) => a + b, 0) || 1;
  const raw = Array.from(counts.entries())
    .sort((a, b) => b[1] - a[1])
    .map(([hex, n]) => labFromHex(hex, n / total));

  const merged: LabColor[] = [];
  for (const sw of raw) {
    if (!merged.some((mItem) => deltaE2000(mItem, sw) < 7.5)) {
      merged.push(sw);
    }
    if (merged.length >= maxCount) break;
  }
  const mergedSum = merged.reduce((s, c) => s + c.proportion, 0) || 1;
  return merged.map((c) => ({
    ...c,
    proportion: Math.round((c.proportion / mergedSum) * 10000) / 10000,
  }));
}

function extractPngPaletteColors(bytes: Uint8Array, maxCount: number): LabColor[] {
  if (bytes.byteLength < 33) return [];
  const view = new DataView(bytes.buffer, bytes.byteOffset, bytes.byteLength);
  let offset = 8;
  while (offset + 12 <= bytes.byteLength) {
    const len = view.getUint32(offset, false);
    const type = readAscii(bytes, offset + 4, 4);
    if (type === 'PLTE' && len >= 3 && offset + 8 + len <= bytes.byteLength) {
      const swatches: LabColor[] = [];
      const entries = Math.floor(len / 3);
      const step = Math.max(1, Math.floor(entries / 24));
      for (let i = 0; i < entries; i += step) {
        const base = offset + 8 + i * 3;
        const hex = sRGBToHex(bytes[base] / 255, bytes[base + 1] / 255, bytes[base + 2] / 255);
        const sw = labFromHex(hex, 1);
        if (!swatches.some((m) => deltaE2000(m, sw) < 10)) {
          swatches.push(sw);
        }
        if (swatches.length >= maxCount) break;
      }
      const n = swatches.length || 1;
      return swatches.map((s) => ({ ...s, proportion: Math.round((1 / n) * 10000) / 10000 }));
    }
    if (type === 'IDAT' || type === 'IEND') break;
    offset += 12 + len;
  }
  return [];
}

function extractBmpColors(bytes: Uint8Array, maxCount: number): LabColor[] {
  if (bytes.byteLength < 54 || bytes[0] !== 0x42 || bytes[1] !== 0x4d) return [];
  const view = new DataView(bytes.buffer, bytes.byteOffset, bytes.byteLength);
  const pixelOffset = view.getUint32(10, true);
  const width = Math.abs(view.getInt32(18, true));
  const height = Math.abs(view.getInt32(22, true));
  const bpp = view.getUint16(28, true);
  const compression = view.getUint32(30, true);
  if (compression !== 0 || (bpp !== 24 && bpp !== 32) || width <= 0 || height <= 0) return [];

  const bytesPerPixel = bpp / 8;
  const rowStride = Math.ceil((width * bytesPerPixel) / 4) * 4;
  const stepX = Math.max(1, Math.floor(width / 32));
  const stepY = Math.max(1, Math.floor(height / 32));
  const buckets = new Map<string, { r: number; g: number; b: number; n: number }>();

  for (let y = 0; y < height; y += stepY) {
    const rowStart = pixelOffset + y * rowStride;
    if (rowStart + width * bytesPerPixel > bytes.byteLength) break;
    for (let x = 0; x < width; x += stepX) {
      const p = rowStart + x * bytesPerPixel;
      const b = bytes[p];
      const g = bytes[p + 1];
      const r = bytes[p + 2];
      const key = `${r >> 4}-${g >> 4}-${b >> 4}`;
      const existing = buckets.get(key);
      if (existing) {
        existing.r += r;
        existing.g += g;
        existing.b += b;
        existing.n += 1;
      } else {
        buckets.set(key, { r, g, b, n: 1 });
      }
    }
  }

  const total = Array.from(buckets.values()).reduce((s, v) => s + v.n, 0) || 1;
  const sorted = Array.from(buckets.values())
    .sort((a, b) => b.n - a.n)
    .map((v) => {
      const lab = sRGBToLab(v.r / v.n / 255, v.g / v.n / 255, v.b / v.n / 255);
      return {
        hex: labToHex(lab.l, lab.a, lab.b),
        l: Math.round(lab.l * 100) / 100,
        a: Math.round(lab.a * 100) / 100,
        b: Math.round(lab.b * 100) / 100,
        proportion: v.n / total,
      };
    });

  const merged: LabColor[] = [];
  for (const sw of sorted) {
    if (!merged.some((m) => deltaE2000(m, sw) < 8)) {
      merged.push(sw);
    }
    if (merged.length >= maxCount) break;
  }
  const sum = merged.reduce((s, c) => s + c.proportion, 0) || 1;
  return merged.map((c) => ({ ...c, proportion: Math.round((c.proportion / sum) * 10000) / 10000 }));
}

function buildDeterministicFingerprint(bytes: Uint8Array, colors: readonly LabColor[]): Float32Array {
  const vec = new Float32Array(64);
  // Seed first 24 dims from palette CIELAB colors (8 slots * 3 channels)
  for (let i = 0; i < 8; i++) {
    const c = colors[i % Math.max(1, colors.length)];
    if (c) {
      vec[i * 3] = c.l / 100;
      vec[i * 3 + 1] = c.a / 128;
      vec[i * 3 + 2] = c.b / 128;
    }
  }
  // Fill remaining 40 dims with deterministic byte distribution histogram across slices
  const len = bytes.byteLength;
  if (len > 0) {
    const sliceLen = Math.max(1, Math.floor(len / 40));
    for (let i = 0; i < 40; i++) {
      const start = Math.min(len - 1, i * sliceLen);
      const end = Math.min(len, start + Math.min(sliceLen, 256));
      let sum = 0;
      let cnt = 0;
      for (let j = start; j < end; j++) {
        sum += bytes[j] / 255;
        cnt++;
      }
      vec[24 + i] = cnt > 0 ? sum / cnt : 0;
    }
  }
  // L2 normalize
  let normSq = 0;
  for (let i = 0; i < vec.length; i++) normSq += vec[i] * vec[i];
  const norm = Math.sqrt(normSq) || 1;
  for (let i = 0; i < vec.length; i++) vec[i] = vec[i] / norm;
  return vec;
}

function mediaBadgeLabel(kind: MediaKind): string | null {
  switch (kind) {
    case 'video':
      return 'VID';
    case 'animatedImage':
      return 'GIF';
    case 'document':
      return 'PDF';
    case 'webBookmark':
      return 'WEB';
    case 'designFile':
      return 'DES';
    case 'audio':
      return 'AUD';
    case 'model3D':
      return '3D';
    case 'image':
      return null;
  }
}

function noteStyleHex(style: NoteStyle): { background: string; foreground: string; border: string } {
  switch (style) {
    case 'paper':
      return { background: '#FFFFFF', foreground: '#1D1F23', border: '#D9DBDE' };
    case 'ink':
      return { background: '#1D1F24', foreground: '#F1F2F4', border: '#3A3D45' };
    case 'warm':
      return { background: '#F7F0E4', foreground: '#392F22', border: '#C9B79C' };
    case 'sage':
      return { background: '#E8F0EA', foreground: '#203227', border: '#9AB5A3' };
    case 'slate':
      return { background: '#E9EEF3', foreground: '#1F2B36', border: '#9EB0C2' };
  }
}

function groupTintHex(tint: GroupTint): string {
  switch (tint) {
    case 'neutral':
      return '#7D838B';
    case 'sand':
      return '#B5956B';
    case 'sage':
      return '#6B8E76';
    case 'slate':
      return '#627A94';
    case 'terracotta':
      return '#BA6B55';
    case 'ocean':
      return '#4D7E97';
  }
}

function geometryObj(
  rect: BoardRect,
  angle: number,
  flipX: boolean,
  flipY: boolean,
): FigmaBridgeObjectGeometry {
  return {
    x: rect.x,
    y: rect.y,
    width: rect.width,
    height: rect.height,
    angle,
    flipX,
    flipY,
  };
}

export interface WorkersImageProcessorOptions {
  imagesBinding?: CloudflareImagesBinding | null;
}

/**
 * 100% Cloudflare Workers-safe image processor (ZERO `sharp`, ZERO `node:fs`).
 * - Pure-TS binary header parser for PNG, JPEG, GIF, WebP (VP8/VP8L/VP8X), BMP, SVG
 * - Optional Cloudflare Images binding (`env.IMAGES`) for server-side JPEG thumbnail generation
 * - Crisp vector SVG cards (`image/svg+xml`) matching Node's `artwork-renderer.ts` templates
 * - Pure-TS SVG/BMP/PLTE palette extractor + deterministic 64-dim fingerprint
 * - Pure-TS SVG Contact Sheet & Pure-JS `JSZip` `.charkleboard` exporter
 */
export class WorkersImageProcessor implements IImageProcessor {
  private readonly imagesBinding: CloudflareImagesBinding | null;

  constructor(options: WorkersImageProcessorOptions = {}) {
    this.imagesBinding = options.imagesBinding ?? null;
  }

  async inspectDimensions(
    bytes: Uint8Array,
    mimeType?: string,
  ): Promise<{ width: number; height: number; format?: string } | null> {
    const parsed = inspectImageHeader(bytes, mimeType);
    if (parsed) {
      return { width: parsed.width, height: parsed.height, format: parsed.format };
    }
    if (this.imagesBinding?.info) {
      try {
        const info = await this.imagesBinding.info(bytesToStream(bytes));
        if (info.width && info.height) {
          return { width: info.width, height: info.height, format: info.format };
        }
      } catch {
        // Ignore binding info errors
      }
    }
    return null;
  }

  private async resizeWithCloudflareImages(
    bytes: Uint8Array,
    maxSide: number,
    quality: number,
  ): Promise<Uint8Array | null> {
    if (!this.imagesBinding) return null;
    try {
      const output = await this.imagesBinding
        .input(bytesToStream(bytes))
        .transform({ width: maxSide, height: maxSide, fit: 'scale-down' })
        .output({ format: 'image/jpeg', quality });
      const res = output.response();
      if (!res.ok) return null;
      return new Uint8Array(await res.arrayBuffer());
    } catch {
      return null;
    }
  }

  async generateThumbnails(
    bytes: Uint8Array,
    mimeType: string,
  ): Promise<GeneratedThumbnailsResult> {
    const header = inspectImageHeader(bytes, mimeType);
    const width = header?.width ?? 800;
    const height = header?.height ?? 600;
    const resolvedMime = header?.mimeType ?? sniffImageMimeType(bytes, mimeType || 'image/jpeg');

    // If Cloudflare Images binding is configured and input is raster, generate real resized JPEGs
    if (this.imagesBinding && resolvedMime !== 'image/svg+xml') {
      const grid520 = await this.resizeWithCloudflareImages(bytes, 520, 84);
      if (grid520) {
        const preview1400 =
          Math.max(width, height) > 520
            ? (await this.resizeWithCloudflareImages(bytes, 1400, 88)) ?? undefined
            : undefined;
        return {
          grid520,
          preview1400,
          mimeType: 'image/jpeg',
          width,
          height,
        };
      }
    }

    // Native passthrough for SVG or web-renderable rasters when no binding or client didn't preprocess
    const webSafe =
      resolvedMime === 'image/svg+xml' ||
      resolvedMime === 'image/jpeg' ||
      resolvedMime === 'image/png' ||
      resolvedMime === 'image/webp' ||
      resolvedMime === 'image/gif';

    if (webSafe && bytes.byteLength <= 4 * 1024 * 1024) {
      return {
        grid520: bytes,
        preview1400: Math.max(width, height) > 520 ? bytes : undefined,
        mimeType: resolvedMime,
        width,
        height,
      };
    }

    return { width, height };
  }

  async extractColorsAndFingerprint(
    bytes: Uint8Array,
    mimeType?: string,
    options: { count?: number } = {},
  ): Promise<{ colors: LabColor[]; featurePrint?: Float32Array }> {
    const count = Math.max(1, Math.min(8, Math.trunc(options.count ?? 6)));
    const resolvedMime = sniffImageMimeType(bytes, mimeType || '');
    let colors: LabColor[] = [];

    if (resolvedMime === 'image/svg+xml') {
      colors = extractSvgColors(utf8Decode(bytes), count);
    } else if (resolvedMime === 'image/bmp') {
      colors = extractBmpColors(bytes, count);
    } else if (resolvedMime === 'image/png') {
      colors = extractPngPaletteColors(bytes, count);
    }

    const featurePrint = buildDeterministicFingerprint(bytes, colors);
    return { colors, featurePrint };
  }

  async renderArtworkCard(input: ArtworkRenderRequest): Promise<RenderedCardResult> {
    let svgOut: { svg: string; width: number; height: number };
    switch (input.kind) {
      case 'colorSwatch':
        svgOut = buildColorSwatchSvg(input.color, input.title);
        break;
      case 'textDocument':
        svgOut = buildTextDocumentSvg(input.title, input.badge, input.excerpt);
        break;
      case 'audioWaveform':
        svgOut = buildAudioWaveformSvg(input.title, input.peaks, input.durationSeconds);
        break;
      case 'model3D':
        svgOut = buildModel3DSvg(input.title, input.format);
        break;
      case 'githubRepo':
        svgOut = buildGitHubRepoSvg(input.repo);
        break;
      case 'socialPost':
        svgOut = buildSocialPostSvg(input.post, {
          inlineCoverBytes: input.coverImageBytes ?? null,
        });
        break;
      case 'webBookmark':
        svgOut = buildWebBookmarkSvg(input.title, input.domain, input.description);
        break;
      case 'genericBadge':
        svgOut = buildGenericBadgeSvg(input.title, input.ext, input.kindLabel);
        break;
      case 'svg': {
        const bytes = utf8Encode(input.svg);
        const header = inspectImageHeader(bytes, 'image/svg+xml');
        svgOut = {
          svg: input.svg,
          width: input.width ?? header?.width ?? 800,
          height: input.height ?? header?.height ?? 600,
        };
        break;
      }
    }

    const svgBytes = utf8Encode(svgOut.svg);
    return {
      grid520: svgBytes,
      preview1400: Math.max(svgOut.width, svgOut.height) > 520 ? svgBytes : undefined,
      fullImage: svgBytes,
      mimeType: 'image/svg+xml',
      width: svgOut.width,
      height: svgOut.height,
    };
  }

  async cropAndPad(
    bytes: Uint8Array,
    opts: CropAndPadOptions = {},
  ): Promise<{ data: Uint8Array; width: number; height: number; mimeType: string } | null> {
    const header = inspectImageHeader(bytes);
    const targetLongSide = Math.max(280, Math.min(1568, Math.round(opts.targetLongSide ?? 768)));
    if (this.imagesBinding && header && header.format !== 'svg') {
      const resized = await this.resizeWithCloudflareImages(
        bytes,
        targetLongSide,
        Math.round((opts.quality ?? 0.86) * 100),
      );
      if (resized) {
        const outHeader = inspectImageHeader(resized);
        return {
          data: resized,
          width: outHeader?.width ?? targetLongSide,
          height: outHeader?.height ?? targetLongSide,
          mimeType: 'image/jpeg',
        };
      }
    }
    if (!header) return null;
    return {
      data: bytes,
      width: header.width,
      height: header.height,
      mimeType: header.mimeType,
    };
  }

  async renderContactSheet(
    items: ContactSheetItemInput[],
    opts: { maxCanvasWidth?: number; format?: 'png' | 'jpeg'; jpegQuality?: number } = {},
  ): Promise<ContactSheetRenderResult | null> {
    const capped = items.slice(0, 16);
    if (capped.length === 0) return null;

    const count = capped.length;
    const columns = count <= 4 ? Math.min(2, count) : count <= 9 ? 3 : 4;
    const rows = Math.ceil(count / columns);
    const margin = 18;
    const gap = 14;
    const canvasWidth = Math.max(640, Math.round(opts.maxCanvasWidth ?? 1280));
    const cellWidth = Math.floor((canvasWidth - margin * 2 - gap * (columns - 1)) / columns);
    const cellHeight = Math.floor(cellWidth * 0.82);
    const canvasHeight = margin * 2 + rows * cellHeight + Math.max(0, rows - 1) * gap;

    const slotToAssetID = new Map<number, UUID>();
    const orderedSlots: Array<{ slot: number; assetID: UUID }> = [];
    const cells: string[] = [];

    for (let idx = 0; idx < capped.length; idx++) {
      const entry = capped[idx];
      const col = idx % columns;
      const row = Math.floor(idx / columns);
      const x = margin + col * (cellWidth + gap);
      const y = margin + row * (cellHeight + gap);

      slotToAssetID.set(entry.slot, entry.asset.id);
      orderedSlots.push({ slot: entry.slot, assetID: entry.asset.id });

      const clipId = `cell_${idx}`;
      const fallbackColor = entry.asset.dominantColors[0]?.hex ?? '#2D303A';
      let imgTag = `<rect x="${x}" y="${y}" width="${cellWidth}" height="${cellHeight}" rx="10" fill="${escapeXml(fallbackColor)}"/>`;
      if (entry.thumbnailBytes && entry.thumbnailBytes.byteLength > 0) {
        const mime = sniffImageMimeType(entry.thumbnailBytes, 'image/jpeg');
        const dataUri = `data:${mime};base64,${bytesToBase64(entry.thumbnailBytes)}`;
        imgTag = `<defs><clipPath id="${clipId}"><rect x="${x}" y="${y}" width="${cellWidth}" height="${cellHeight}" rx="10"/></clipPath></defs>
          <rect x="${x}" y="${y}" width="${cellWidth}" height="${cellHeight}" rx="10" fill="#25272E"/>
          <image href="${dataUri}" x="${x}" y="${y}" width="${cellWidth}" height="${cellHeight}" preserveAspectRatio="xMidYMid meet" clip-path="url(#${clipId})"/>`;
      }

      const slotBadge = `#${String(entry.slot).padStart(2, '0')}`;
      const kindBadge = mediaBadgeLabel(entry.asset.mediaKind);
      cells.push(`
        ${imgTag}
        <rect x="${x + 8}" y="${y + 8}" width="44" height="24" rx="6" fill="rgba(16,18,24,0.86)" stroke="rgba(255,255,255,0.22)"/>
        <text x="${x + 30}" y="${y + 24}" text-anchor="middle" fill="#FFFFFF" font-family="ui-monospace, Menlo, monospace" font-size="13" font-weight="700">${slotBadge}</text>
        ${
          kindBadge
            ? `<rect x="${x + cellWidth - 46}" y="${y + 8}" width="38" height="22" rx="5" fill="rgba(16,18,24,0.78)"/><text x="${x + cellWidth - 27}" y="${y + 23}" text-anchor="middle" fill="#D5DBE8" font-family="ui-monospace, Menlo, monospace" font-size="11" font-weight="600">${kindBadge}</text>`
            : ''
        }
        <rect x="${x}" y="${y}" width="${cellWidth}" height="${cellHeight}" rx="10" fill="none" stroke="rgba(255,255,255,0.12)"/>
      `);
    }

    const svg = `<svg xmlns="http://www.w3.org/2000/svg" width="${canvasWidth}" height="${canvasHeight}" viewBox="0 0 ${canvasWidth} ${canvasHeight}">
      <rect width="${canvasWidth}" height="${canvasHeight}" fill="#181A1F"/>
      ${cells.join('\n')}
    </svg>`;

    return {
      data: utf8Encode(svg),
      mimeType: 'image/svg+xml',
      slotToAssetID,
      orderedSlots,
      width: canvasWidth,
      height: canvasHeight,
    };
  }

  async exportMoodboardImage(
    params: MoodboardExportRequestParams,
  ): Promise<{ data: Uint8Array; mimeType: string; width: number; height: number }> {
    const opts = createDefaultMoodboardExportOptions(params.options);
    const bgMode = params.options?.backgroundMode ?? (opts.darkAppearance ? 'dark' : 'light');
    const bgFill = bgMode === 'transparent' ? 'none' : bgMode === 'dark' ? '#141517' : '#F6F6F5';
    const textFill = bgMode === 'dark' ? '#F2F3F6' : '#18191D';

    const assetRecordObj: Record<string, AssetRecord> = {};
    for (const [k, v] of params.assetsByID.entries()) assetRecordObj[k] = v;

    let framesById = new Map<UUID, BoardRect>();
    if (params.document.mode.type === 'autoEditorial') {
      const solved = solveEditorialLayout(
        params.document.nodes,
        params.document.mode.config,
        params.containerWidth ?? 1120,
        assetRecordObj,
      );
      for (const [id, r] of Object.entries(solved.frames)) {
        framesById.set(id, r);
      }
    } else {
      for (const n of params.document.nodes) {
        framesById.set(n.id, n.frame);
      }
    }

    let minX = Number.POSITIVE_INFINITY;
    let minY = Number.POSITIVE_INFINITY;
    let maxX = Number.NEGATIVE_INFINITY;
    let maxY = Number.NEGATIVE_INFINITY;
    for (const r of framesById.values()) {
      minX = Math.min(minX, r.x);
      minY = Math.min(minY, r.y);
      maxX = Math.max(maxX, r.x + r.width);
      maxY = Math.max(maxY, r.y + r.height);
    }
    if (!Number.isFinite(minX)) {
      minX = 0;
      minY = 0;
      maxX = 800;
      maxY = 600;
    }

    const pad = Math.max(24, opts.padding);
    const width = Math.max(400, Math.round(maxX - minX + pad * 2));
    const height = Math.max(300, Math.round(maxY - minY + pad * 2));
    const offsetX = pad - minX;
    const offsetY = pad - minY;

    const sorted = [...params.document.nodes].sort((a, b) => a.zIndex - b.zIndex);
    const parts: string[] = [];

    for (const node of sorted) {
      const r = framesById.get(node.id) ?? node.frame;
      const x = r.x + offsetX;
      const y = r.y + offsetY;
      if (node.kind.type === 'groupFrame') {
        const accent = groupTintHex(node.kind.tint);
        parts.push(
          `<rect x="${x}" y="${y}" width="${r.width}" height="${r.height}" rx="18" fill="${accent}" fill-opacity="0.1" stroke="${accent}" stroke-opacity="0.35" stroke-width="2"/>`,
          `<text x="${x + 18}" y="${y + 28}" fill="${textFill}" font-family="-apple-system, PingFang SC, sans-serif" font-size="16" font-weight="600">${escapeXml(node.kind.title)}</text>`,
        );
      } else if (node.kind.type === 'assetRef') {
        const bytes =
          (await params.loadAssetBytes(node.kind.assetID, 'preview1400')) ??
          (await params.loadAssetBytes(node.kind.assetID, 'grid520'));
        if (bytes && bytes.byteLength > 0) {
          const mime = sniffImageMimeType(bytes, 'image/jpeg');
          const dataUri = `data:${mime};base64,${bytesToBase64(bytes)}`;
          const clipId = `n_${node.id.replace(/[^a-zA-Z0-9]/g, '')}`;
          parts.push(
            `<defs><clipPath id="${clipId}"><rect x="${x}" y="${y}" width="${r.width}" height="${r.height}" rx="12"/></clipPath></defs>`,
            `<image href="${dataUri}" x="${x}" y="${y}" width="${r.width}" height="${r.height}" preserveAspectRatio="xMidYMid slice" clip-path="url(#${clipId})"/>`,
          );
        } else {
          parts.push(
            `<rect x="${x}" y="${y}" width="${r.width}" height="${r.height}" rx="12" fill="#2A2D36"/>`,
          );
        }
      } else if (node.kind.type === 'note') {
        const style = noteStyleHex(node.kind.style);
        parts.push(
          `<rect x="${x}" y="${y}" width="${r.width}" height="${r.height}" rx="14" fill="${style.background}" stroke="${style.border}" stroke-width="1.5"/>`,
          `<text x="${x + 18}" y="${y + 34}" fill="${style.foreground}" font-family="-apple-system, PingFang SC, sans-serif" font-size="${node.kind.fontSize}" font-weight="600">${escapeXml(node.kind.title || node.kind.text.slice(0, 48))}</text>`,
        );
      }
    }

    const svg = `<svg xmlns="http://www.w3.org/2000/svg" width="${width}" height="${height}" viewBox="0 0 ${width} ${height}">
      ${bgFill !== 'none' ? `<rect width="${width}" height="${height}" fill="${bgFill}"/>` : ''}
      ${parts.join('\n')}
    </svg>`;
    return {
      data: utf8Encode(svg),
      mimeType: 'image/svg+xml',
      width,
      height,
    };
  }

  async exportFigmaBridgeZip(
    params: FigmaBridgeExportRequestParams,
  ): Promise<{ zipBytes: Uint8Array; manifest: FigmaBridgeBoardManifest; report: FigmaBridgeReport }> {
    const opts = createDefaultMoodboardExportOptions(params.options);
    const doc = params.document;
    const assetRecordObj: Record<string, AssetRecord> = {};
    for (const [k, v] of params.assetsByID.entries()) assetRecordObj[k] = v;

    let framesById = new Map<UUID, BoardRect>();
    if (doc.mode.type === 'autoEditorial') {
      const solved = solveEditorialLayout(
        doc.nodes,
        doc.mode.config,
        params.containerWidth ?? 1120,
        assetRecordObj,
      );
      for (const [id, r] of Object.entries(solved.frames)) framesById.set(id, r);
    } else {
      for (const n of doc.nodes) framesById.set(n.id, n.frame);
    }

    const zip = new JSZip();
    const objects: FigmaBridgeObject[] = [];
    const originals: FigmaBridgeBoardManifest['originals'] = [];
    const warningsList: FigmaBridgeReport['warnings'] = [];
    const seenOriginals = new Set<string>();

    let imageCount = 0;
    let noteCount = 0;
    let groupCount = 0;
    let paletteCount = 0;

    const sortedNodes = [...doc.nodes].sort((a, b) => a.zIndex - b.zIndex);
    for (const node of sortedNodes) {
      const rect = framesById.get(node.id) ?? node.frame;
      const geom = geometryObj(rect, node.rotationDegrees, node.flipHorizontal, node.flipVertical);

      if (node.kind.type === 'groupFrame') {
        groupCount++;
        objects.push({
          id: node.id,
          kind: 'groupFrame',
          name: node.kind.title || '分组',
          geometry: geom,
          locked: node.isLocked,
          warnings: [],
          group: {
            title: node.kind.title,
            tint: node.kind.tint,
            accentHex: groupTintHex(node.kind.tint),
          },
        });
      } else if (node.kind.type === 'note') {
        noteCount++;
        const st = noteStyleHex(node.kind.style);
        objects.push({
          id: node.id,
          kind: 'note',
          name: node.kind.title || '文字卡片',
          geometry: geom,
          locked: node.isLocked,
          warnings: [],
          note: {
            title: node.kind.title ?? null,
            text: node.kind.text,
            style: node.kind.style,
            fontSize: node.kind.fontSize,
            backgroundHex: st.background,
            foregroundHex: st.foreground,
            borderHex: st.border,
          },
        });
      } else if (node.kind.type === 'paletteStrip') {
        paletteCount++;
        const swatches = (
          node.kind.colors.length > 0 ? node.kind.colors : doc.extractedPalette
        ).map((c) => ({ hex: c.hex, isLight: isLightHex(c.hex) }));
        objects.push({
          id: node.id,
          kind: 'paletteStrip',
          name: '色板条',
          geometry: geom,
          locked: node.isLocked,
          warnings: [],
          palette: { swatches },
        });
      } else if (node.kind.type === 'assetRef') {
        const asset = params.assetsByID.get(node.kind.assetID);
        const orig = await params.loadOriginalBytes(node.kind.assetID);
        const thumb =
          (await params.loadThumbnailBytes(node.kind.assetID, 'preview1400')) ??
          (await params.loadThumbnailBytes(node.kind.assetID, 'grid520'));
        const tileBytes = orig?.bytes ?? thumb;
        const warnings: string[] = [];

        if (!tileBytes || tileBytes.byteLength === 0) {
          warnings.push('缺少可用的图片数据，请在浏览器端重新导出。');
          warningsList.push({
            id: node.id,
            name: asset?.title ?? node.kind.assetID,
            issues: warnings,
          });
          objects.push({
            id: node.id,
            kind: 'unsupported',
            name: asset?.title ?? '缺失素材',
            geometry: geom,
            locked: node.isLocked,
            warnings,
          });
          continue;
        }

        const header = inspectImageHeader(tileBytes, asset?.mimeType);
        const pixelWidth = header?.width ?? asset?.pixelWidth ?? 800;
        const pixelHeight = header?.height ?? asset?.pixelHeight ?? 600;
        const sha = await sha256HexAsync(tileBytes);
        const ext =
          header?.format === 'png'
            ? 'png'
            : header?.format === 'gif'
              ? 'gif'
              : header?.format === 'webp'
                ? 'webp'
                : 'jpg';

        if (orig && !seenOriginals.has(node.kind.assetID)) {
          seenOriginals.add(node.kind.assetID);
          const origExt = posixExtname(orig.fileName ?? asset?.fileName ?? '').replace(/^\./, '') || ext;
          const origPath = `originals/${node.kind.assetID}.${origExt}`;
          const origSha = await sha256HexAsync(orig.bytes);
          zip.file(origPath, orig.bytes);
          originals.push({
            id: node.kind.assetID,
            name: asset?.fileName ?? `${node.kind.assetID}.${origExt}`,
            file: origPath,
            sha256: origSha,
            bytes: orig.bytes.byteLength,
          });
        }

        const isAnimated = header?.format === 'gif' || asset?.mediaKind === 'animatedImage';
        if (pixelWidth > 4096 || pixelHeight > 4096) {
          warnings.push('图片尺寸超过 4096px，建议在浏览器端导出以获得无损自动切片。');
        }
        if (node.kind.crop) {
          warnings.push('服务端无图形库模式保留原图，建议在浏览器端导出以烘焙裁剪区域。');
        }
        if (warnings.length > 0) {
          warningsList.push({
            id: node.id,
            name: asset?.title ?? node.kind.assetID,
            issues: warnings,
          });
        }

        const tileFile = `tiles/${sha256HexSync(node.id).slice(0, 8)}_r0_c0.${ext}`;
        zip.file(tileFile, tileBytes);
        imageCount++;

        objects.push({
          id: node.id,
          kind: 'image',
          name: asset?.title ?? mediaKindLocalizedLabel(asset?.mediaKind ?? 'image'),
          geometry: geom,
          locked: node.isLocked,
          cornerRadius: 12,
          warnings,
          image: {
            pixelWidth,
            pixelHeight,
            tiles: [
              {
                file: tileFile,
                x: 0,
                y: 0,
                width: pixelWidth,
                height: pixelHeight,
                sha256: sha,
              },
            ],
            animated: isAnimated,
            ...(isAnimated && header?.format === 'gif'
              ? { animation: { file: `originals/${node.kind.assetID}.gif`, sha256: sha } }
              : {}),
          },
        });
      }
    }

    const report: FigmaBridgeReport = {
      objectCount: objects.length,
      imageCount,
      noteCount,
      groupCount,
      paletteCount,
      connectorCount: opts.includeAnnotations ? doc.connectors.length : 0,
      strokeCount: opts.includeAnnotations ? doc.inkStrokes.length : 0,
      reviewCount: warningsList.length,
      warnings: warningsList,
    };

    const manifest: FigmaBridgeBoardManifest = {
      format: 'charkle-figma-bridge',
      version: 1,
      boardId: doc.id,
      name: doc.title,
      subtitle: doc.subtitle,
      mode: doc.mode.type,
      darkAppearance: opts.darkAppearance,
      exportedAt: new Date().toISOString(),
      sourceOS: 'Cloudflare Workers',
      objects,
      connectors: opts.includeAnnotations
        ? doc.connectors.map((c) => ({
            id: c.id,
            fromNodeID: c.fromNodeID,
            fromAnchor: c.fromAnchor,
            toNodeID: c.toNodeID,
            toAnchor: c.toAnchor,
            style: c.style,
            colorHex: c.colorHex,
            dashed: c.dashed,
            label: c.label ?? null,
          }))
        : [],
      inkStrokes: opts.includeAnnotations
        ? doc.inkStrokes.map((s) => ({
            id: s.id,
            points: s.points,
            colorHex: s.colorHex,
            lineWidth: s.lineWidth,
            opacity: s.opacity,
          }))
        : [],
      originals,
      report,
    };

    zip.file('board.json', JSON.stringify(manifest, null, 2));
    zip.file('migration-report.json', JSON.stringify(report, null, 2));
    const zipBytes = await zip.generateAsync({
      type: 'uint8array',
      compression: 'DEFLATE',
      compressionOptions: { level: 6 },
    });

    return { zipBytes, manifest, report };
  }
}
