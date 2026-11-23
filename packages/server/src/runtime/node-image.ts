import sharp from 'sharp';
import {
  clampCropRect,
  deltaE76,
  isMeaningfulCropSubregion,
  labFromHex,
  sRGBToHex,
  sRGBToLab,
  type LabColor,
  type NormalizedCropRect,
} from '@charkle/shared';
import { FigmaBridgeExporter } from '../export/figma-bridge-exporter.js';
import { MoodboardExporter } from '../export/moodboard-exporter.js';
import { ContactSheetRenderer } from '../intelligence/contact-sheet-renderer.js';
import {
  renderAudioWaveformCard,
  renderColorSwatchCard,
  renderGenericBadgeCard,
  renderGitHubRepoCard,
  renderModel3DCard,
  renderSocialPostCard,
  renderSvgToPng,
  renderTextDocumentCard,
  renderWebBookmarkCard,
} from '../media/artwork-renderer.js';
import { computeVisualFingerprint, extractDominantColors } from '../media/color-extractor.js';
import type {
  ArtworkRenderRequest,
  ContactSheetItemInput,
  ContactSheetRenderResult,
  CropAndPadOptions,
  FigmaBridgeExportRequestParams,
  GeneratedThumbnailsResult,
  IImageProcessor,
  MoodboardExportRequestParams,
  RenderedCardResult,
} from './types.js';
import { toBuffer } from './web-crypto-utils.js';

/**
 * Node `sharp` implementation of TypeSafe's 280..1568 upright JPEG preparer.
 */
export async function prepareTypeSafeJPEGWithSharp(
  input: Buffer | Uint8Array | string,
  opts: CropAndPadOptions = {},
): Promise<{ data: Buffer; width: number; height: number } | null> {
  const minSide = opts.minSide ?? 280;
  const maxSide = opts.maxSide ?? 1568;
  const targetLongSide = opts.targetLongSide ?? 768;
  const quality = opts.quality ?? 0.86;
  try {
    const src = typeof input === 'string' ? input : toBuffer(input);
    const oriented = await sharp(src).rotate().toBuffer({ resolveWithObject: true });

    const srcW = oriented.info.width;
    const srcH = oriented.info.height;
    if (!srcW || !srcH) return null;

    const desiredMax = Math.max(minSide, Math.min(maxSide, Math.round(targetLongSide)));
    let scale = desiredMax / Math.max(srcW, srcH);
    if (Math.min(srcW, srcH) * scale < minSide) {
      scale = minSide / Math.min(srcW, srcH);
    }
    if (Math.max(srcW, srcH) * scale > maxSide) {
      scale = maxSide / Math.max(srcW, srcH);
    }

    const drawW = Math.max(1, Math.min(maxSide, Math.round(srcW * scale)));
    const drawH = Math.max(1, Math.min(maxSide, Math.round(srcH * scale)));
    const canvasW = Math.max(minSide, drawW);
    const canvasH = Math.max(minSide, drawH);

    let pipeline = sharp(oriented.data).resize(drawW, drawH, {
      fit: 'fill',
      kernel: sharp.kernel.lanczos3,
    });

    if (canvasW > drawW || canvasH > drawH) {
      const left = Math.floor((canvasW - drawW) / 2);
      const right = canvasW - drawW - left;
      const top = Math.floor((canvasH - drawH) / 2);
      const bottom = canvasH - drawH - top;
      pipeline = pipeline.extend({
        top,
        bottom,
        left,
        right,
        background: { r: 245, g: 245, b: 245, alpha: 1 },
      });
    }

    const jpegQuality = Math.max(40, Math.min(100, Math.round(quality * 100)));
    const out = await pipeline
      .flatten({ background: { r: 245, g: 245, b: 245 } })
      .jpeg({ quality: jpegQuality })
      .toBuffer({ resolveWithObject: true });

    return {
      data: out.data,
      width: out.info.width,
      height: out.info.height,
    };
  } catch {
    return null;
  }
}

/**
 * Node `sharp` implementation of cropped CIELAB k-means palette extraction.
 */
export async function extractCroppedDominantColorsWithSharp(
  imageBuffer: Uint8Array,
  crop?: NormalizedCropRect | null,
  count = 6,
): Promise<LabColor[]> {
  if (count <= 0) return [];
  try {
    let pipeline = sharp(toBuffer(imageBuffer)).rotate();
    const meta = await pipeline.metadata();
    const imgW = meta.width ?? 0;
    const imgH = meta.height ?? 0;
    if (imgW <= 0 || imgH <= 0) return [];

    if (
      crop &&
      crop.width > 0.04 &&
      crop.height > 0.04 &&
      !(crop.x === 0 && crop.y === 0 && crop.width === 1 && crop.height === 1)
    ) {
      const clamped = clampCropRect(crop);
      const left = Math.max(0, Math.min(imgW - 1, Math.floor(clamped.x * imgW)));
      const top = Math.max(0, Math.min(imgH - 1, Math.floor(clamped.y * imgH)));
      const width = Math.max(4, Math.min(imgW - left, Math.round(clamped.width * imgW)));
      const height = Math.max(4, Math.min(imgH - top, Math.round(clamped.height * imgH)));
      if (width >= 4 && height >= 4) {
        pipeline = pipeline.extract({ left, top, width, height });
      }
    }

    const { data, info } = await pipeline
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
    const k = Math.min(count, 8, pixels.length);
    const centroids: Array<{ l: number; a: number; b: number }> = [
      labPixels[Math.floor(labPixels.length / 2)],
    ];

    while (centroids.length < k) {
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
        let bestIdx = 0;
        let bestDist = Number.POSITIVE_INFINITY;
        for (let cIdx = 0; cIdx < clusterCount; cIdx++) {
          const c = centroids[cIdx];
          const dl = p.l - c.l;
          const da = p.a - c.a;
          const db = p.b - c.b;
          const dist = dl * dl + da * da + db * db;
          if (dist < bestDist) {
            bestDist = dist;
            bestIdx = cIdx;
          }
        }
        assignments[i] = bestIdx;
        sumL[bestIdx] += p.l;
        sumA[bestIdx] += p.a;
        sumB[bestIdx] += p.b;
        counts[bestIdx] += 1;
      }

      for (let cIdx = 0; cIdx < clusterCount; cIdx++) {
        if (counts[cIdx] > 0) {
          centroids[cIdx] = {
            l: sumL[cIdx] / counts[cIdx],
            a: sumA[cIdx] / counts[cIdx],
            b: sumB[cIdx] / counts[cIdx],
          };
        }
      }
    }

    const sumR = new Float64Array(clusterCount);
    const sumG = new Float64Array(clusterCount);
    const sumBl = new Float64Array(clusterCount);
    const clusterSize = new Int32Array(clusterCount);

    for (let i = 0; i < pixels.length; i++) {
      const cIdx = assignments[i];
      sumR[cIdx] += pixels[i].r;
      sumG[cIdx] += pixels[i].g;
      sumBl[cIdx] += pixels[i].b;
      clusterSize[cIdx] += 1;
    }

    const rawSwatches: LabColor[] = [];
    for (let cIdx = 0; cIdx < clusterCount; cIdx++) {
      if (clusterSize[cIdx] <= 0) continue;
      const n = clusterSize[cIdx];
      const hex = sRGBToHex(sumR[cIdx] / n, sumG[cIdx] / n, sumBl[cIdx] / n);
      rawSwatches.push(labFromHex(hex, n / pixels.length));
    }

    rawSwatches.sort((a, b) => b.proportion - a.proportion);
    const merged: LabColor[] = [];
    for (const swatch of rawSwatches) {
      if (!merged.some((m) => deltaE76(m, swatch) < 8.0)) {
        merged.push(swatch);
      }
    }
    return merged.slice(0, count);
  } catch {
    return [];
  }
}

/**
 * Node `sharp` local edge + border contrast + center saliency detector.
 */
export async function detectPrimarySubjectBoxWithSharp(
  imageBuffer: Uint8Array,
): Promise<NormalizedCropRect | null> {
  try {
    const { data, info } = await sharp(toBuffer(imageBuffer))
      .rotate()
      .resize(96, 96, { fit: 'inside', withoutEnlargement: true })
      .ensureAlpha()
      .raw()
      .toBuffer({ resolveWithObject: true });

    const w = info.width;
    const h = info.height;
    if (w < 8 || h < 8) return null;

    const labL = new Float32Array(w * h);
    const labA = new Float32Array(w * h);
    const labB = new Float32Array(w * h);
    const alphaArr = new Uint8Array(w * h);

    for (let y = 0; y < h; y++) {
      for (let x = 0; x < w; x++) {
        const idx = y * w + x;
        const p = idx * info.channels;
        alphaArr[idx] = data[p + 3] ?? 255;
        const lab = sRGBToLab(data[p] / 255, data[p + 1] / 255, data[p + 2] / 255);
        labL[idx] = lab.l;
        labA[idx] = lab.a;
        labB[idx] = lab.b;
      }
    }

    let bgL = 0;
    let bgA = 0;
    let bgB = 0;
    let bgCount = 0;
    const rim = Math.max(1, Math.min(3, Math.floor(Math.min(w, h) * 0.05)));
    for (let y = 0; y < h; y++) {
      for (let x = 0; x < w; x++) {
        if (x < rim || x >= w - rim || y < rim || y >= h - rim) {
          const idx = y * w + x;
          bgL += labL[idx];
          bgA += labA[idx];
          bgB += labB[idx];
          bgCount++;
        }
      }
    }
    if (bgCount > 0) {
      bgL /= bgCount;
      bgA /= bgCount;
      bgB /= bgCount;
    }

    const salience = new Float32Array(w * h);
    let maxSalience = 0;
    let sumSalience = 0;

    for (let y = 0; y < h; y++) {
      for (let x = 0; x < w; x++) {
        const idx = y * w + x;
        if (alphaArr[idx] < 30) {
          salience[idx] = 0;
          continue;
        }
        const dl = labL[idx] - bgL;
        const da = labA[idx] - bgA;
        const db = labB[idx] - bgB;
        const borderDiff = Math.sqrt(dl * dl + da * da + db * db);

        const xm = Math.max(0, x - 1);
        const xp = Math.min(w - 1, x + 1);
        const ym = Math.max(0, y - 1);
        const yp = Math.min(h - 1, y + 1);
        const gx =
          -labL[ym * w + xm] +
          labL[ym * w + xp] -
          2 * labL[y * w + xm] +
          2 * labL[y * w + xp] -
          labL[yp * w + xm] +
          labL[yp * w + xp];
        const gy =
          -labL[ym * w + xm] -
          2 * labL[ym * w + x] -
          labL[ym * w + xp] +
          labL[yp * w + xm] +
          2 * labL[yp * w + x] +
          labL[yp * w + xp];
        const edgeMag = Math.hypot(gx, gy) * 0.16;

        const nx = (x + 0.5) / w - 0.5;
        const ny = (y + 0.5) / h - 0.5;
        const centerWeight = 0.72 + 0.28 * Math.exp(-(nx * nx + ny * ny) * 3.2);

        const s = (borderDiff * 0.72 + edgeMag * 0.28) * centerWeight;
        salience[idx] = s;
        if (s > maxSalience) maxSalience = s;
        sumSalience += s;
      }
    }

    if (maxSalience < 6.0) return null;
    const meanSalience = sumSalience / (w * h);
    const threshold = Math.max(6.0, meanSalience * 1.15, maxSalience * 0.28);

    let minX = w;
    let minY = h;
    let maxX = -1;
    let maxY = -1;
    let activePixels = 0;

    for (let y = 0; y < h; y++) {
      for (let x = 0; x < w; x++) {
        if (salience[y * w + x] >= threshold) {
          if (x < minX) minX = x;
          if (x > maxX) maxX = x;
          if (y < minY) minY = y;
          if (y > maxY) maxY = y;
          activePixels++;
        }
      }
    }

    if (activePixels < Math.max(4, Math.floor(w * h * 0.005)) || maxX <= minX || maxY <= minY) {
      return null;
    }

    const rect: NormalizedCropRect = clampCropRect({
      x: minX / w,
      y: minY / h,
      width: (maxX - minX + 1) / w,
      height: (maxY - minY + 1) / h,
    });

    if (!isMeaningfulCropSubregion(rect)) {
      return null;
    }
    return rect;
  } catch {
    return null;
  }
}

/**
 * Full-fidelity Node.js `sharp`-powered `IImageProcessor`.
 * ONLY imported by Node entrypoints (`app.ts`, `mcp-stdio.ts`, Node tests).
 */
export class NodeImageProcessor implements IImageProcessor {
  async inspectDimensions(
    bytes: Uint8Array,
  ): Promise<{ width: number; height: number; format?: string } | null> {
    try {
      const meta = await sharp(toBuffer(bytes), { animated: false }).rotate().metadata();
      if (!meta.width || !meta.height) return null;
      return {
        width: meta.width,
        height: meta.height,
        format: meta.format,
      };
    } catch {
      return null;
    }
  }

  async generateThumbnails(bytes: Uint8Array): Promise<GeneratedThumbnailsResult> {
    const buf = toBuffer(bytes);
    const meta = await sharp(buf, { animated: false }).rotate().metadata();
    const width = meta.width ?? 800;
    const height = meta.height ?? 600;
    const maxSide = Math.max(width, height);

    const gridBuf = await sharp(buf, { animated: false })
      .rotate()
      .resize(520, 520, { fit: 'inside', withoutEnlargement: true })
      .flatten({ background: '#ffffff' })
      .jpeg({ quality: 84, mozjpeg: true })
      .toBuffer();

    let previewBuf: Uint8Array | undefined;
    if (maxSide > 520) {
      const preview = await sharp(buf, { animated: false })
        .rotate()
        .resize(1400, 1400, { fit: 'inside', withoutEnlargement: true })
        .flatten({ background: '#ffffff' })
        .jpeg({ quality: 88, mozjpeg: true })
        .toBuffer();
      previewBuf = new Uint8Array(preview.buffer, preview.byteOffset, preview.byteLength);
    }

    return {
      grid520: new Uint8Array(gridBuf.buffer, gridBuf.byteOffset, gridBuf.byteLength),
      preview1400: previewBuf,
      mimeType: 'image/jpeg',
      width,
      height,
    };
  }

  async extractColorsAndFingerprint(
    bytes: Uint8Array,
    _mimeType?: string,
    options: { crop?: NormalizedCropRect | null; count?: number } = {},
  ): Promise<{ colors: LabColor[]; featurePrint?: Float32Array }> {
    const buf = toBuffer(bytes);
    const count = options.count ?? 6;
    const colors = options.crop
      ? await extractCroppedDominantColorsWithSharp(buf, options.crop, count)
      : await extractDominantColors(buf, count);
    const fp = await computeVisualFingerprint(buf).catch(() => null);
    return {
      colors,
      featurePrint: fp ? new Float32Array(fp) : undefined,
    };
  }

  async renderArtworkCard(input: ArtworkRenderRequest): Promise<RenderedCardResult> {
    let pngBuf: Buffer;
    switch (input.kind) {
      case 'colorSwatch':
        pngBuf = await renderColorSwatchCard(input.color, input.title);
        break;
      case 'textDocument':
        pngBuf = await renderTextDocumentCard(input.title, input.badge, input.excerpt);
        break;
      case 'audioWaveform':
        pngBuf = await renderAudioWaveformCard(input.title, input.peaks, input.durationSeconds);
        break;
      case 'model3D':
        pngBuf = await renderModel3DCard(input.title, input.format);
        break;
      case 'githubRepo':
        pngBuf = await renderGitHubRepoCard(input.repo);
        break;
      case 'socialPost':
        pngBuf = await renderSocialPostCard(
          input.post,
          input.coverImageBytes ? toBuffer(input.coverImageBytes) : null,
        );
        break;
      case 'webBookmark':
        pngBuf = await renderWebBookmarkCard(input.title, input.domain, input.description);
        break;
      case 'genericBadge':
        pngBuf = await renderGenericBadgeCard(input.title, input.ext, input.kindLabel);
        break;
      case 'svg':
        pngBuf = await renderSvgToPng(input.svg);
        break;
    }

    const thumbs = await this.generateThumbnails(pngBuf);
    return {
      grid520: thumbs.grid520 ?? new Uint8Array(pngBuf),
      preview1400: thumbs.preview1400,
      fullImage: new Uint8Array(pngBuf.buffer, pngBuf.byteOffset, pngBuf.byteLength),
      mimeType: 'image/jpeg',
      width: thumbs.width ?? 800,
      height: thumbs.height ?? 600,
    };
  }

  async detectPrimarySubjectBox(bytes: Uint8Array): Promise<NormalizedCropRect | null> {
    return detectPrimarySubjectBoxWithSharp(bytes);
  }

  async cropAndPad(
    bytes: Uint8Array,
    opts?: CropAndPadOptions,
  ): Promise<{ data: Uint8Array; width: number; height: number; mimeType: string } | null> {
    const res = await prepareTypeSafeJPEGWithSharp(bytes, opts);
    if (!res) return null;
    return {
      data: new Uint8Array(res.data.buffer, res.data.byteOffset, res.data.byteLength),
      width: res.width,
      height: res.height,
      mimeType: 'image/jpeg',
    };
  }

  async renderContactSheet(
    items: ContactSheetItemInput[],
    opts?: { maxCanvasWidth?: number; format?: 'png' | 'jpeg'; jpegQuality?: number },
  ): Promise<ContactSheetRenderResult | null> {
    const res = await ContactSheetRenderer.render(
      items.map((item) => ({
        slot: item.slot,
        asset: item.asset,
        thumbnailBuffer: item.thumbnailBytes ? toBuffer(item.thumbnailBytes) : null,
        thumbnailPath: item.thumbnailPath ?? null,
      })),
      opts,
    );
    if (!res) return null;
    return {
      data: new Uint8Array(res.data.buffer, res.data.byteOffset, res.data.byteLength),
      mimeType: res.mimeType,
      slotToAssetID: res.slotToAssetID,
      orderedSlots: res.orderedSlots,
      width: res.width,
      height: res.height,
    };
  }

  async exportMoodboardImage(
    params: MoodboardExportRequestParams,
  ): Promise<{ data: Uint8Array; mimeType: string; width: number; height: number }> {
    const rendered = await MoodboardExporter.exportImage({
      document: params.document,
      assetsByID: params.assetsByID,
      loadAssetBuffer: async (assetID, tier) => {
        const bytes = await params.loadAssetBytes(assetID, tier);
        return bytes ? toBuffer(bytes) : null;
      },
      format: params.format,
      containerWidth: params.containerWidth,
      options: params.options,
    });
    return {
      data: new Uint8Array(
        rendered.buffer.buffer,
        rendered.buffer.byteOffset,
        rendered.buffer.byteLength,
      ),
      mimeType: rendered.mimeType,
      width: rendered.width,
      height: rendered.height,
    };
  }

  async exportFigmaBridgeZip(
    params: FigmaBridgeExportRequestParams,
  ): Promise<{ zipBytes: Uint8Array; manifest: import('@charkle/shared').FigmaBridgeBoardManifest; report: import('@charkle/shared').FigmaBridgeReport }> {
    const res = await FigmaBridgeExporter.exportBundle({
      document: params.document,
      assetsByID: params.assetsByID,
      containerWidth: params.containerWidth,
      options: params.options,
      loadOriginalBuffer: async (assetID) => {
        const loaded = await params.loadOriginalBytes(assetID);
        return loaded ? { buffer: toBuffer(loaded.bytes), fileName: loaded.fileName } : null;
      },
      loadThumbnailBuffer: async (assetID, tier) => {
        const bytes = await params.loadThumbnailBytes(assetID, tier);
        return bytes ? toBuffer(bytes) : null;
      },
    });
    return {
      zipBytes: new Uint8Array(
        res.zipBuffer.buffer,
        res.zipBuffer.byteOffset,
        res.zipBuffer.byteLength,
      ),
      manifest: res.manifest,
      report: res.report,
    };
  }
}
