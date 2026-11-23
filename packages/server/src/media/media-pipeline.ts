import crypto from 'node:crypto';
import fs from 'node:fs';
import fsp from 'node:fs/promises';
import path from 'node:path';
import sharp from 'sharp';
import {
  createDefaultAssetRecord,
  detectMediaKind,
  getEffectiveSocialAttachments,
  labFromHex,
  mediaKindLocalizedLabel,
  socialMediaAttachmentLocalizedLabel,
  socialPlatformDisplayName,
  toSwiftUUID,
  type AssetRecord,
  type AssetVector,
  type CacheStats,
  type CaptureInput,
  type LabColor,
  type MediaKind,
  type ThumbnailTier,
  type UUID,
} from '@charkle/shared';
import type { IMediaPipeline, MediaIngestResult } from '../context.js';
import {
  encodeFeaturePrintFloat32,
  type LibraryDatabase,
} from '../db/library-database.js';
import { DEFAULT_CACHE_BUDGET_BYTES } from '../storage/config-store.js';
import {
  renderAudioWaveformCard,
  renderColorSwatchCard,
  renderGenericBadgeCard,
  renderGitHubRepoCard,
  renderModel3DCard,
  renderSocialPostCard,
  renderTextDocumentCard,
  renderWebBookmarkCard,
} from './artwork-renderer.js';
import {
  computeVisualFingerprint,
  extractAudioWaveform,
  extractDominantColors,
} from './color-extractor.js';
import { isWebURL, resolveWebBookmark } from './resolvers/bookmark.js';
import { parseGitHubRepoURL, resolveGitHubRepo } from './resolvers/github.js';
import {
  downloadBoundedBuffer,
  MAX_SOCIAL_PHOTO_BYTES,
  MAX_SOCIAL_VIDEO_BYTES,
  parseSocialPostURL,
  resolveSocialPost,
} from './resolvers/social.js';

const PLAIN_TEXT_EXTS = new Set([
  'txt',
  'md',
  'markdown',
  'json',
  'yaml',
  'yml',
  'toml',
  'csv',
  'rtf',
]);

const MIME_BY_EXT: Record<string, string> = {
  jpg: 'image/jpeg',
  jpeg: 'image/jpeg',
  png: 'image/png',
  gif: 'image/gif',
  apng: 'image/apng',
  webp: 'image/webp',
  avif: 'image/avif',
  heic: 'image/heic',
  heif: 'image/heif',
  bmp: 'image/bmp',
  tif: 'image/tiff',
  tiff: 'image/tiff',
  svg: 'image/svg+xml',
  mp4: 'video/mp4',
  mov: 'video/quicktime',
  m4v: 'video/x-m4v',
  webm: 'video/webm',
  mkv: 'video/x-matroska',
  avi: 'video/x-msvideo',
  mp3: 'audio/mpeg',
  wav: 'audio/wav',
  m4a: 'audio/mp4',
  aac: 'audio/aac',
  flac: 'audio/flac',
  ogg: 'audio/ogg',
  opus: 'audio/opus',
  aif: 'audio/aiff',
  aiff: 'audio/aiff',
  pdf: 'application/pdf',
  md: 'text/markdown',
  markdown: 'text/markdown',
  txt: 'text/plain',
  json: 'application/json',
  yaml: 'text/yaml',
  yml: 'text/yaml',
  toml: 'application/toml',
  csv: 'text/csv',
  rtf: 'application/rtf',
  webloc: 'application/xml',
  url: 'text/plain',
  glb: 'model/gltf-binary',
  gltf: 'model/gltf+json',
  obj: 'model/obj',
  stl: 'model/stl',
  usdz: 'model/vnd.usdz+zip',
  ply: 'application/octet-stream',
  fbx: 'application/octet-stream',
  dae: 'model/vnd.collada+xml',
  psd: 'image/vnd.adobe.photoshop',
};

export function guessMimeType(fileName: string): string {
  const ext = path.extname(fileName).replace(/^\./, '').toLowerCase();
  return MIME_BY_EXT[ext] ?? 'application/octet-stream';
}

export function sanitizeFileName(raw: string, fallback = 'asset'): string {
  const base = path.basename(raw.trim()).replace(/[\\/:*?"<>|\x00-\x1f]/g, '_').trim();
  const cleaned = base.replace(/^\.+/, '');
  return cleaned.length > 0 ? cleaned.slice(0, 180) : fallback;
}

/**
 * Checks whether a PNG buffer is an animated PNG (APNG) by scanning for an `acTL` chunk before `IDAT`.
 */
function isAnimatedPng(buf: Buffer): boolean {
  if (buf.length < 32) return false;
  const sig = buf.subarray(0, 8);
  if (!sig.equals(Buffer.from([0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a]))) {
    return false;
  }
  let offset = 8;
  while (offset + 8 <= buf.length) {
    const len = buf.readUInt32BE(offset);
    const chunkType = buf.toString('ascii', offset + 4, offset + 8);
    if (chunkType === 'acTL') return true;
    if (chunkType === 'IDAT') return false;
    offset += 12 + len;
  }
  return false;
}

function sha256Hex(buf: Buffer): string {
  return crypto.createHash('sha256').update(buf).digest('hex');
}

function stripExt(fileName: string): string {
  const ext = path.extname(fileName);
  return ext ? fileName.slice(0, -ext.length) : fileName;
}

function buildWeblocXml(url: string): Buffer {
  const escaped = url
    .replace(/&/g, '&amp;')
    .replace(/</g, '&lt;')
    .replace(/>/g, '&gt;');
  return Buffer.from(
    `<?xml version="1.0" encoding="UTF-8"?>\n<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">\n<plist version="1.0"><dict><key>URL</key><string>${escaped}</string></dict></plist>\n`,
    'utf8',
  );
}

export class MediaPipeline implements IMediaPipeline {
  public readonly directory: string;
  public readonly originalsDir: string;
  public readonly thumbnailsDir: string;
  public readonly previewsDir: string;
  public readonly stagingDir: string;
  private cacheBudgetBytes: number;

  constructor(directory: string, cacheBudgetBytes = DEFAULT_CACHE_BUDGET_BYTES) {
    this.directory = directory;
    this.originalsDir = path.join(directory, 'Originals');
    this.thumbnailsDir = path.join(directory, 'Thumbnails');
    this.previewsDir = path.join(directory, 'Previews');
    this.stagingDir = path.join(directory, 'Staging');
    this.cacheBudgetBytes = cacheBudgetBytes;
    for (const dir of [
      this.originalsDir,
      this.thumbnailsDir,
      this.previewsDir,
      this.stagingDir,
    ]) {
      fs.mkdirSync(dir, { recursive: true });
    }
  }

  thumbnailTargetPath(id: UUID, tier: ThumbnailTier = 'grid520'): string {
    const dir = tier === 'grid520' ? this.thumbnailsDir : this.previewsDir;
    return path.join(dir, `${toSwiftUUID(id)}.jpg`);
  }

  getThumbnailPath(id: UUID, tier: ThumbnailTier = 'grid520'): string | null {
    const target = this.thumbnailTargetPath(id, tier);
    if (fs.existsSync(target)) return target;
    if (tier === 'preview1400') {
      const fallback = this.thumbnailTargetPath(id, 'grid520');
      if (fs.existsSync(fallback)) return fallback;
    }
    return null;
  }

  originalTargetPath(asset: AssetRecord): string {
    const ext = path
      .extname(asset.fileName)
      .replace(/^\./, '')
      .toLowerCase()
      .replace(/[^a-z0-9]/g, '')
      .slice(0, 16);
    const base = toSwiftUUID(asset.id);
    return path.join(this.originalsDir, ext ? `${base}.${ext}` : base);
  }

  getOriginalPath(asset: AssetRecord): string | null {
    const direct = this.originalTargetPath(asset);
    if (fs.existsSync(direct)) return direct;
    const prefix = toSwiftUUID(asset.id);
    try {
      const entries = fs.readdirSync(this.originalsDir);
      const found = entries.find((e) => e === prefix || e.startsWith(`${prefix}.`));
      return found ? path.join(this.originalsDir, found) : null;
    } catch {
      return null;
    }
  }

  /**
   * Local-cache-only original path lookup (parity with Swift `cachedOriginalURL`).
   * Never triggers remote cloud downloads or LRU mutations.
   */
  cachedOriginalPath(asset: AssetRecord): string | null {
    return this.getOriginalPath(asset);
  }

  async readThumbnailBuffer(id: UUID, tier: ThumbnailTier = 'grid520'): Promise<Buffer | null> {
    const p = this.getThumbnailPath(id, tier);
    if (!p) return null;
    try {
      return await fsp.readFile(p);
    } catch {
      return null;
    }
  }

  async readOriginalBuffer(asset: AssetRecord): Promise<Buffer | null> {
    const p = this.getOriginalPath(asset);
    if (!p) return null;
    try {
      return await fsp.readFile(p);
    } catch {
      return null;
    }
  }

  async installOriginal(
    sourcePathOrBuffer: string | Buffer,
    asset: AssetRecord,
    moveSource = false,
  ): Promise<string> {
    const dest = this.originalTargetPath(asset);
    const previous = this.getOriginalPath(asset);
    await fsp.mkdir(this.originalsDir, { recursive: true });

    if (Buffer.isBuffer(sourcePathOrBuffer)) {
      const tmp = path.join(this.stagingDir, `${crypto.randomUUID()}.tmp`);
      await fsp.writeFile(tmp, sourcePathOrBuffer);
      await fsp.rename(tmp, dest);
    } else if (path.resolve(sourcePathOrBuffer) !== path.resolve(dest)) {
      if (moveSource) {
        await fsp.rename(sourcePathOrBuffer, dest);
      } else {
        const tmp = path.join(this.stagingDir, `${crypto.randomUUID()}.tmp`);
        await fsp.copyFile(sourcePathOrBuffer, tmp);
        await fsp.rename(tmp, dest);
      }
    }

    if (previous && path.resolve(previous) !== path.resolve(dest)) {
      await fsp.unlink(previous).catch(() => undefined);
    }
    return dest;
  }

  async writeThumbnail(id: UUID, tier: ThumbnailTier, jpegBuffer: Buffer): Promise<string> {
    const target = this.thumbnailTargetPath(id, tier);
    const tmp = path.join(this.stagingDir, `${crypto.randomUUID()}.jpg`);
    await fsp.writeFile(tmp, jpegBuffer);
    await fsp.rename(tmp, target);
    return target;
  }

  async extractDominantColors(imageBuffer: Buffer, count = 6): Promise<LabColor[]> {
    return extractDominantColors(imageBuffer, count);
  }

  async computeVisualFingerprint(imageBuffer: Buffer): Promise<number[]> {
    return computeVisualFingerprint(imageBuffer);
  }

  async generateThumbnailsFromBuffer(
    id: UUID,
    imageBuffer: Buffer,
  ): Promise<{ width: number; height: number }> {
    const meta = await sharp(imageBuffer, { animated: false }).rotate().metadata();
    const width = meta.width ?? 800;
    const height = meta.height ?? 600;
    const maxSide = Math.max(width, height);

    const gridBuf = await sharp(imageBuffer, { animated: false })
      .rotate()
      .resize(520, 520, { fit: 'inside', withoutEnlargement: true })
      .flatten({ background: '#ffffff' })
      .jpeg({ quality: 84, mozjpeg: true })
      .toBuffer();
    await this.writeThumbnail(id, 'grid520', gridBuf);

    if (maxSide > 520) {
      const previewBuf = await sharp(imageBuffer, { animated: false })
        .rotate()
        .resize(1400, 1400, { fit: 'inside', withoutEnlargement: true })
        .flatten({ background: '#ffffff' })
        .jpeg({ quality: 88, mozjpeg: true })
        .toBuffer();
      await this.writeThumbnail(id, 'preview1400', previewBuf);
    } else {
      const prevPath = this.thumbnailTargetPath(id, 'preview1400');
      await fsp.unlink(prevPath).catch(() => undefined);
    }

    return { width, height };
  }

  // MARK: - Unified Ingestion (All 5 CaptureInputs & All 8 MediaKinds)

  async ingest(
    input: CaptureInput,
    folderID: UUID | null = null,
    id: UUID = toSwiftUUID(crypto.randomUUID()),
  ): Promise<MediaIngestResult> {
    const assetID = toSwiftUUID(id);

    switch (input.type) {
      case 'fileURL': {
        const rawPath = input.url.startsWith('file://')
          ? decodeURIComponent(new URL(input.url).pathname)
          : input.url;
        const stat = await fsp.stat(rawPath);
        if (!stat.isFile()) {
          throw new Error('请选择一个有效的文件导入。');
        }
        const buffer = await fsp.readFile(rawPath);
        const fileName = sanitizeFileName(path.basename(rawPath));
        return this.ingestUploadedFile(buffer, fileName, guessMimeType(fileName), folderID, assetID);
      }

      case 'imageData': {
        const rawB64 = input.base64Data.includes(',')
          ? input.base64Data.slice(input.base64Data.indexOf(',') + 1)
          : input.base64Data;
        const buffer = Buffer.from(rawB64, 'base64');
        if (buffer.length === 0) {
          throw new Error('图片数据为空。');
        }
        let ext = path.extname(input.suggestedName).replace(/^\./, '').toLowerCase();
        if (!ext) {
          try {
            const meta = await sharp(buffer).metadata();
            ext = meta.format === 'jpeg' ? 'jpg' : (meta.format ?? 'png');
          } catch {
            ext = 'png';
          }
        }
        const base = sanitizeFileName(stripExt(input.suggestedName) || 'Clipboard Image');
        const fileName = `${base}.${ext}`;
        const result = await this.ingestUploadedFile(
          buffer,
          fileName,
          guessMimeType(fileName),
          folderID,
          assetID,
        );
        if (input.sourceURL) {
          try {
            result.asset.sourceURL = input.sourceURL;
            result.asset.sourceDomain = new URL(input.sourceURL).hostname;
          } catch {
            result.asset.sourceURL = input.sourceURL;
          }
        }
        return result;
      }

      case 'webURL': {
        if (!isWebURL(input.url)) {
          throw new Error('仅支持 http:// 或 https:// 网页链接。');
        }
        return this.ingestWebURL(input.url, input.title ?? null, input.notes ?? '', folderID, assetID);
      }

      case 'textSnippet': {
        const cleanTitle = input.title.trim() || '文本片段';
        const fileName = `${sanitizeFileName(cleanTitle)}.md`;
        const buffer = Buffer.from(input.text, 'utf8');
        const result = await this.ingestUploadedFile(
          buffer,
          fileName,
          'text/markdown',
          folderID,
          assetID,
        );
        result.asset.title = cleanTitle;
        if (input.sourceURL) {
          result.asset.sourceURL = input.sourceURL;
          try {
            result.asset.sourceDomain = new URL(input.sourceURL).hostname;
          } catch {
            // ignore
          }
        }
        return result;
      }

      case 'colorSwatch': {
        const swatch = labFromHex(input.hex, 1.0);
        const title = input.title?.trim() || swatch.hex;
        const pngBuf = await renderColorSwatchCard(swatch, title);
        const fileName = `${sanitizeFileName(title)}.png`;
        const result = await this.ingestUploadedFile(
          pngBuf,
          fileName,
          'image/png',
          folderID,
          assetID,
        );
        result.asset.title = title;
        result.asset.dominantColors = [swatch];
        result.asset.notes = `HEX ${swatch.hex} · CIELAB (${swatch.l.toFixed(1)}, ${swatch.a.toFixed(1)}, ${swatch.b.toFixed(1)})`;
        result.asset.tags = Array.from(new Set([...result.asset.tags, '色卡']));
        return result;
      }
    }
  }

  private async ingestWebURL(
    rawUrl: string,
    suppliedTitle: string | null,
    suppliedNotes: string,
    folderID: UUID | null,
    assetID: UUID,
  ): Promise<MediaIngestResult> {
    const parsedUrl = new URL(rawUrl);
    const domain = parsedUrl.hostname;
    const now = new Date().toISOString();

    // 1. Cohesive Social Post (X / Threads / Bluesky) — ALWAYS mediaKind = 'webBookmark'
    if (parseSocialPostURL(rawUrl)) {
      const resolved = await resolveSocialPost(rawUrl);
      if (resolved) {
        const { metadata, title, markdownArchive, coverImageBuffer, primaryVideoBuffer } = resolved;
        const platformTag = socialPlatformDisplayName(metadata.platform);
        const originalBuf = primaryVideoBuffer ?? Buffer.from(markdownArchive, 'utf8');
        const fileExt = primaryVideoBuffer ? 'mp4' : 'md';
        const fileName = `${sanitizeFileName(metadata.authorHandle + '-' + assetID.slice(0, 8))}.${fileExt}`;

        const posterBuf = await renderSocialPostCard(metadata, coverImageBuffer);
        const dims = await this.generateThumbnailsFromBuffer(assetID, posterBuf);
        const colorSource = coverImageBuffer ?? posterBuf;
        const dominantColors = await extractDominantColors(colorSource, 6).catch(() => []);
        const fp = await computeVisualFingerprint(colorSource).catch(() => null);

        const asset = createDefaultAssetRecord({
          id: assetID,
          title: suppliedTitle?.trim() || title,
          fileName,
          folderID,
          contentHash: sha256Hex(originalBuf),
          mediaKind: 'webBookmark', // CRITICAL COHESIVE INVARIANT
          mimeType: primaryVideoBuffer ? 'video/mp4' : 'text/markdown',
          fileSizeBytes: originalBuf.length,
          pixelWidth: dims.width,
          pixelHeight: dims.height,
          sourceURL: metadata.originalURL,
          sourceDomain: new URL(metadata.originalURL).hostname,
          notes: suppliedNotes,
          tags: [platformTag],
          ocrText: metadata.bodyText || null,
          dominantColors,
          isLocalOriginalCached: true,
          createdAt: now,
          updatedAt: now,
          richMetadata: {
            socialPost: metadata,
            githubRepo: null,
            textExcerpt: metadata.bodyText.slice(0, 1200) || null,
            isMarkdown: false,
            model3DFormat: null,
          },
        });
        const originalPath = await this.installOriginal(originalBuf, asset);
        const vector: AssetVector | null = fp
          ? { featurePrint: encodeFeaturePrintFloat32(fp), embedding: null, precision: 16 }
          : null;
        return { asset, originalPath, vector };
      }
    }

    // 2. GitHub Repository
    if (parseGitHubRepoURL(rawUrl)) {
      const repo = await resolveGitHubRepo(rawUrl);
      if (repo) {
        const posterBuf = await renderGitHubRepoCard(repo);
        const dims = await this.generateThumbnailsFromBuffer(assetID, posterBuf);
        const dominantColors = await extractDominantColors(posterBuf, 5).catch(() => []);
        const fp = await computeVisualFingerprint(posterBuf).catch(() => null);
        const originalBuf = buildWeblocXml(`https://github.com/${repo.fullName}`);
        const fileName = `${sanitizeFileName(repo.owner + '-' + repo.repo)}.webloc`;
        const tags = ['GitHub', ...(repo.language ? [repo.language] : [])];

        const asset = createDefaultAssetRecord({
          id: assetID,
          title: suppliedTitle?.trim() || repo.fullName,
          fileName,
          folderID,
          contentHash: sha256Hex(originalBuf),
          mediaKind: 'webBookmark',
          mimeType: 'application/xml',
          fileSizeBytes: originalBuf.length,
          pixelWidth: dims.width,
          pixelHeight: dims.height,
          sourceURL: `https://github.com/${repo.fullName}`,
          sourceDomain: 'github.com',
          notes: suppliedNotes || repo.description || '',
          tags,
          ocrText: repo.description ?? null,
          dominantColors,
          isLocalOriginalCached: true,
          createdAt: now,
          updatedAt: now,
          richMetadata: {
            githubRepo: repo,
            socialPost: null,
            textExcerpt: repo.readmeMarkdown?.slice(0, 1200) ?? repo.description ?? null,
            isMarkdown: Boolean(repo.readmeMarkdown),
            model3DFormat: null,
          },
        });
        const originalPath = await this.installOriginal(originalBuf, asset);
        const vector: AssetVector | null = fp
          ? { featurePrint: encodeFeaturePrintFloat32(fp), embedding: null, precision: 16 }
          : null;
        return { asset, originalPath, vector };
      }
    }

    // 3. Generic Web Bookmark
    const bookmark = await resolveWebBookmark(rawUrl);
    const title = suppliedTitle?.trim() || bookmark.title || domain;
    const posterBuf =
      bookmark.posterBuffer ?? (await renderWebBookmarkCard(title, domain, bookmark.description));
    let dims = { width: 800, height: 640 };
    let dominantColors: LabColor[] = [];
    let fp: number[] | null = null;
    try {
      dims = await this.generateThumbnailsFromBuffer(assetID, posterBuf);
      dominantColors = await extractDominantColors(posterBuf, 5);
      fp = await computeVisualFingerprint(posterBuf);
    } catch {
      const fallbackCard = await renderWebBookmarkCard(title, domain, bookmark.description);
      dims = await this.generateThumbnailsFromBuffer(assetID, fallbackCard);
      dominantColors = await extractDominantColors(fallbackCard, 5).catch(() => []);
      fp = await computeVisualFingerprint(fallbackCard).catch(() => null);
    }

    const originalBuf = buildWeblocXml(rawUrl);
    const fileName = `${sanitizeFileName(title)}.webloc`;
    const asset = createDefaultAssetRecord({
      id: assetID,
      title,
      fileName,
      folderID,
      contentHash: sha256Hex(originalBuf),
      mediaKind: 'webBookmark',
      mimeType: 'application/xml',
      fileSizeBytes: originalBuf.length,
      pixelWidth: dims.width,
      pixelHeight: dims.height,
      sourceURL: rawUrl,
      sourceDomain: domain,
      notes: suppliedNotes || bookmark.description || '',
      tags: [],
      dominantColors,
      isLocalOriginalCached: true,
      createdAt: now,
      updatedAt: now,
    });
    const originalPath = await this.installOriginal(originalBuf, asset);
    const vector: AssetVector | null = fp
      ? { featurePrint: encodeFeaturePrintFloat32(fp), embedding: null, precision: 16 }
      : null;
    return { asset, originalPath, vector };
  }

  async ingestUploadedFile(
    buffer: Buffer,
    rawFileName: string,
    mimeType: string | null,
    folderID: UUID | null = null,
    id: UUID = toSwiftUUID(crypto.randomUUID()),
  ): Promise<MediaIngestResult> {
    const assetID = toSwiftUUID(id);
    const fileName = sanitizeFileName(rawFileName);
    const ext = path.extname(fileName).replace(/^\./, '').toLowerCase();
    const resolvedMime = mimeType && mimeType !== 'application/octet-stream' ? mimeType : guessMimeType(fileName);
    let mediaKind: MediaKind = detectMediaKind(ext, resolvedMime);

    if (ext === 'png' && isAnimatedPng(buffer)) {
      mediaKind = 'animatedImage';
    }

    const now = new Date().toISOString();
    const title = stripExt(fileName) || fileName;
    const asset = createDefaultAssetRecord({
      id: assetID,
      title,
      fileName,
      folderID: folderID ? toSwiftUUID(folderID) : null,
      contentHash: sha256Hex(buffer),
      mediaKind,
      mimeType: resolvedMime,
      fileSizeBytes: buffer.length,
      isLocalOriginalCached: true,
      createdAt: now,
      updatedAt: now,
    });

    let vector: AssetVector | null = null;
    let posterBuffer: Buffer | null = null;

    switch (mediaKind) {
      case 'image':
      case 'animatedImage': {
        try {
          const dims = await this.generateThumbnailsFromBuffer(assetID, buffer);
          asset.pixelWidth = dims.width;
          asset.pixelHeight = dims.height;
          asset.dominantColors = await extractDominantColors(buffer, 6);
          const fp = await computeVisualFingerprint(buffer);
          vector = { featurePrint: encodeFeaturePrintFloat32(fp), embedding: null, precision: 16 };
        } catch {
          posterBuffer = await renderGenericBadgeCard(title, ext || 'IMG', mediaKindLocalizedLabel(mediaKind));
        }
        break;
      }

      case 'designFile': {
        // sharp natively renders SVG and some rasterized design files
        try {
          const dims = await this.generateThumbnailsFromBuffer(assetID, buffer);
          asset.pixelWidth = dims.width;
          asset.pixelHeight = dims.height;
          asset.dominantColors = await extractDominantColors(buffer, 6);
          const fp = await computeVisualFingerprint(buffer);
          vector = { featurePrint: encodeFeaturePrintFloat32(fp), embedding: null, precision: 16 };
        } catch {
          posterBuffer = await renderGenericBadgeCard(title, ext || 'DESIGN', mediaKindLocalizedLabel(mediaKind));
        }
        break;
      }

      case 'document': {
        if (PLAIN_TEXT_EXTS.has(ext)) {
          const text = buffer.subarray(0, 65_536).toString('utf8');
          asset.richMetadata = {
            githubRepo: null,
            socialPost: null,
            textExcerpt: text.slice(0, 1200),
            isMarkdown: ext === 'md' || ext === 'markdown',
            model3DFormat: null,
          };
          asset.ocrText = text.slice(0, 8000);
          posterBuffer = await renderTextDocumentCard(title, (ext || 'TXT').toUpperCase(), text);
        } else {
          posterBuffer = await renderGenericBadgeCard(title, ext || 'DOC', mediaKindLocalizedLabel(mediaKind));
        }
        break;
      }

      case 'audio': {
        // Extract 48-bar waveform + duration; explicitly skip dominantColors & OCR per PARITY_SPEC 3.2
        const audio = extractAudioWaveform(buffer, fileName, 48);
        asset.durationSeconds = audio.durationSeconds;
        asset.waveformPeaks = audio.waveformPeaks;
        asset.dominantColors = [];
        asset.ocrText = null;
        posterBuffer = await renderAudioWaveformCard(title, audio.waveformPeaks, audio.durationSeconds);
        break;
      }

      case 'model3D': {
        // Explicitly skip OCR per PARITY_SPEC 3.2
        const fmt = (ext || '3D').toUpperCase();
        asset.richMetadata = {
          githubRepo: null,
          socialPost: null,
          textExcerpt: null,
          isMarkdown: false,
          model3DFormat: fmt,
        };
        asset.ocrText = null;
        posterBuffer = await renderModel3DCard(title, fmt);
        break;
      }

      case 'video': {
        posterBuffer = await renderGenericBadgeCard(title, ext || 'VIDEO', mediaKindLocalizedLabel(mediaKind));
        break;
      }

      case 'webBookmark': {
        const text = buffer.toString('utf8');
        const urlMatch = /https?:\/\/[^\s<>"']+/i.exec(text);
        if (urlMatch && isWebURL(urlMatch[0])) {
          return this.ingestWebURL(urlMatch[0], null, '', folderID, assetID);
        }
        posterBuffer = await renderWebBookmarkCard(title, 'bookmark', null);
        break;
      }
    }

    if (posterBuffer) {
      const dims = await this.generateThumbnailsFromBuffer(assetID, posterBuffer);
      asset.pixelWidth = dims.width;
      asset.pixelHeight = dims.height;
      if (mediaKind !== 'audio') {
        asset.dominantColors = await extractDominantColors(posterBuffer, 5).catch(() => []);
      }
      const fp = await computeVisualFingerprint(posterBuffer).catch(() => null);
      if (fp) {
        vector = { featurePrint: encodeFeaturePrintFloat32(fp), embedding: null, precision: 16 };
      }
    }

    const originalPath = await this.installOriginal(buffer, asset);
    return { asset, originalPath, vector };
  }

  // MARK: - Rich Asset Refresh & Social Post Standalone Media Extraction

  async refreshRichAsset(asset: AssetRecord): Promise<MediaIngestResult> {
    const targetUrl =
      asset.richMetadata?.socialPost?.originalURL ??
      (asset.richMetadata?.githubRepo
        ? `https://github.com/${asset.richMetadata.githubRepo.fullName}`
        : asset.sourceURL);

    if (!targetUrl || !isWebURL(targetUrl)) {
      const origPath = this.getOriginalPath(asset) ?? this.originalTargetPath(asset);
      return { asset, originalPath: origPath, vector: null };
    }

    const refreshed = await this.ingestWebURL(
      targetUrl,
      null,
      asset.notes,
      asset.folderID ?? null,
      asset.id,
    );

    const mergedTags = Array.from(new Set([...asset.tags, ...refreshed.asset.tags])).sort();
    refreshed.asset = {
      ...refreshed.asset,
      rating: asset.rating,
      pinnedOffline: asset.pinnedOffline,
      isTrashed: asset.isTrashed,
      createdAt: asset.createdAt,
      lastOpenedAt: asset.lastOpenedAt ?? null,
      tags: mergedTags,
      suggestedTags: asset.suggestedTags,
      aiDescription: asset.aiDescription ?? null,
      driveFileID: asset.driveFileID ?? null,
    };
    return refreshed;
  }

  async extractSocialMedia(
    postAsset: AssetRecord,
    attachmentIndex?: number | null,
  ): Promise<MediaIngestResult[]> {
    const post = postAsset.richMetadata?.socialPost;
    if (!post) {
      throw new Error('该素材不是社交推文，无法提取媒体附件。');
    }
    const attachments = getEffectiveSocialAttachments(post);
    if (attachments.length === 0) {
      throw new Error('该推文不包含可提取的图片或视频附件。');
    }

    const indices: number[] =
      attachmentIndex !== undefined && attachmentIndex !== null
        ? [attachmentIndex]
        : attachments.map((_, i) => i);

    const platformTag = socialPlatformDisplayName(post.platform);
    const notesBlock = [
      `来源推文：${post.authorName} (@${post.authorHandle}) · ${platformTag}`,
      '',
      post.bodyText,
      '',
      `原推文链接：${post.originalURL}`,
    ].join('\n');

    const results: MediaIngestResult[] = [];
    for (const idx of indices) {
      if (idx < 0 || idx >= attachments.length) continue;
      const att = attachments[idx];
      let buf: Buffer | null = null;

      // Reuse already-cached primary video if matching
      if (
        (att.kind === 'video' || att.kind === 'gif') &&
        post.videoURL &&
        att.url === post.videoURL &&
        postAsset.mimeType.startsWith('video/')
      ) {
        buf = await this.readOriginalBuffer(postAsset);
      }

      if (!buf) {
        const limit = att.kind === 'photo' ? MAX_SOCIAL_PHOTO_BYTES : MAX_SOCIAL_VIDEO_BYTES;
        buf = await downloadBoundedBuffer(att.url, limit, 20_000);
      }
      if (!buf) {
        throw new Error(`无法下载第 ${idx + 1} 个附件，请检查网络或稍后重试。`);
      }

      const kindLabel = socialMediaAttachmentLocalizedLabel(att.kind);
      const ext =
        att.kind === 'video'
          ? 'mp4'
          : att.kind === 'gif'
            ? (att.url.toLowerCase().includes('.gif') ? 'gif' : 'mp4')
            : (() => {
                try {
                  const u = new URL(att.url);
                  const fmt = u.searchParams.get('format');
                  if (fmt) return fmt.toLowerCase();
                  const pExt = path.extname(u.pathname).replace(/^\./, '').toLowerCase();
                  if (pExt) return pExt;
                } catch {
                  // default jpg
                }
                return 'jpg';
              })();

      const handle = post.authorHandle.replace(/^@/, '');
      const title = `@${handle} ${kindLabel} #${idx + 1}`;
      const fileName = `${sanitizeFileName(handle + '-' + (idx + 1))}.${ext}`;
      const ingested = await this.ingestUploadedFile(
        buf,
        fileName,
        guessMimeType(fileName),
        postAsset.folderID ?? null,
      );
      ingested.asset.title = title;
      ingested.asset.notes = notesBlock;
      ingested.asset.sourceURL = post.originalURL;
      ingested.asset.sourceDomain = new URL(post.originalURL).hostname;
      ingested.asset.tags = Array.from(new Set([...ingested.asset.tags, platformTag])).sort();
      results.push(ingested);
    }

    return results;
  }

  // MARK: - File Cleanup & Configurable LRU Cache

  async removeFiles(asset: AssetRecord): Promise<void> {
    const paths = [
      this.getOriginalPath(asset),
      this.thumbnailTargetPath(asset.id, 'grid520'),
      this.thumbnailTargetPath(asset.id, 'preview1400'),
    ].filter((p): p is string => Boolean(p));
    for (const p of paths) {
      await fsp.unlink(p).catch(() => undefined);
    }
  }

  async removeFilesByIDs(ids: Iterable<UUID>): Promise<void> {
    const idSet = new Set(Array.from(ids, toSwiftUUID));
    if (idSet.size === 0) return;

    try {
      const origEntries = await fsp.readdir(this.originalsDir);
      for (const name of origEntries) {
        const stem = stripExt(name).toUpperCase();
        if (idSet.has(stem)) {
          await fsp.unlink(path.join(this.originalsDir, name)).catch(() => undefined);
        }
      }
    } catch {
      // ignore
    }

    for (const id of idSet) {
      await fsp.unlink(this.thumbnailTargetPath(id, 'grid520')).catch(() => undefined);
      await fsp.unlink(this.thumbnailTargetPath(id, 'preview1400')).catch(() => undefined);
    }
  }

  getCacheBudgetBytes(): number {
    return this.cacheBudgetBytes;
  }

  setCacheBudgetBytes(bytes: number): void {
    this.cacheBudgetBytes = Math.max(1024 * 1024, Math.round(bytes));
  }

  private async dirTotalBytes(dir: string): Promise<number> {
    try {
      const entries = await fsp.readdir(dir);
      let total = 0;
      for (const name of entries) {
        const st = await fsp.stat(path.join(dir, name)).catch(() => null);
        if (st?.isFile()) total += st.size;
      }
      return total;
    } catch {
      return 0;
    }
  }

  private async scanOriginalFiles(): Promise<Array<{ id: UUID; filePath: string; size: number; mtimeMs: number }>> {
    try {
      const entries = await fsp.readdir(this.originalsDir);
      const list: Array<{ id: UUID; filePath: string; size: number; mtimeMs: number }> = [];
      for (const name of entries) {
        const fp = path.join(this.originalsDir, name);
        const st = await fsp.stat(fp).catch(() => null);
        if (!st?.isFile()) continue;
        const id = stripExt(name).toUpperCase();
        list.push({ id, filePath: fp, size: st.size, mtimeMs: st.mtimeMs });
      }
      return list;
    } catch {
      return [];
    }
  }

  async getCacheStats(db: LibraryDatabase): Promise<CacheStats> {
    const [thumbA, thumbB, originals] = await Promise.all([
      this.dirTotalBytes(this.thumbnailsDir),
      this.dirTotalBytes(this.previewsDir),
      this.scanOriginalFiles(),
    ]);
    const protectedIDs = db.protectedAssetIDs();
    let originalCacheBytes = 0;
    let pinnedOfflineBytes = 0;
    let pinnedCount = 0;

    for (const entry of originals) {
      if (protectedIDs.has(entry.id)) {
        pinnedOfflineBytes += entry.size;
        pinnedCount++;
      } else {
        originalCacheBytes += entry.size;
      }
    }

    return {
      thumbnailBytes: thumbA + thumbB,
      originalCacheBytes,
      pinnedOfflineBytes,
      budgetBytes: this.cacheBudgetBytes,
      cachedOriginalCount: originals.length,
      pinnedAssetCount: Math.max(pinnedCount, protectedIDs.size),
    };
  }

  /**
   * Evicts oldest-accessed unpinned originals until total original cache fits within `budgetBytes`.
   * Strictly protects assets with `pinnedOffline === true` OR referenced by any `pinnedOffline` board.
   */
  async evictCacheNow(db: LibraryDatabase): Promise<CacheStats> {
    const protectedIDs = db.protectedAssetIDs();
    const accessTimes = db.originalAccessTimes();
    const originals = await this.scanOriginalFiles();

    let totalOriginalsBytes = originals.reduce((s, e) => s + e.size, 0);
    if (totalOriginalsBytes > this.cacheBudgetBytes) {
      const evictable = originals
        .filter((e) => !protectedIDs.has(e.id))
        .sort((a, b) => {
          const ta = accessTimes.get(a.id) ?? a.mtimeMs / 1000;
          const tb = accessTimes.get(b.id) ?? b.mtimeMs / 1000;
          return ta - tb;
        });

      for (const entry of evictable) {
        if (totalOriginalsBytes <= this.cacheBudgetBytes) break;
        await fsp.unlink(entry.filePath).catch(() => undefined);
        totalOriginalsBytes -= entry.size;
        const asset = db.getAsset(entry.id);
        if (asset && asset.isLocalOriginalCached) {
          db.putAsset({ ...asset, isLocalOriginalCached: false });
        }
      }
    }

    return this.getCacheStats(db);
  }
}
