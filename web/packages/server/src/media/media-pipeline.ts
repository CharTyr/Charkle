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
  type ClientPreprocessedMedia,
  type LabColor,
  type MediaKind,
  type ThumbnailTier,
  type UUID,
} from '@charkle/shared';
import type { IMediaPipeline, MediaIngestResult } from '../context.js';
import { encodeFeaturePrintFloat32, type LibraryDatabase } from '../db/library-database.js';
import type {
  BlobHeadResult,
  BlobRangeRequest,
  BlobStreamResult,
  IBlobStore,
  IImageProcessor,
} from '../runtime/types.js';
import {
  base64ToBytes,
  posixBasename,
  posixExtname,
  posixStripExt,
  randomUUID,
  sha256HexSync,
  toBuffer,
  utf8Decode,
  utf8Encode,
} from '../runtime/web-crypto-utils.js';
import { sniffImageMimeType } from '../runtime/workers-image.js';
import { DEFAULT_CACHE_BUDGET_BYTES } from '../storage/config-store.js';
import { extractAudioWaveform } from './audio-waveform.js';
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

const THUMB_EXT_CANDIDATES: ReadonlyArray<{ ext: string; mime: string }> = [
  { ext: 'jpg', mime: 'image/jpeg' },
  { ext: 'svg', mime: 'image/svg+xml' },
  { ext: 'png', mime: 'image/png' },
  { ext: 'webp', mime: 'image/webp' },
  { ext: 'gif', mime: 'image/gif' },
];

function extForImageMime(mimeType: string): string {
  const lower = mimeType.toLowerCase();
  if (lower.includes('svg')) return 'svg';
  if (lower.includes('png')) return 'png';
  if (lower.includes('webp')) return 'webp';
  if (lower.includes('gif')) return 'gif';
  return 'jpg';
}

export function guessMimeType(fileName: string): string {
  const ext = posixExtname(fileName).replace(/^\./, '').toLowerCase();
  return MIME_BY_EXT[ext] ?? 'application/octet-stream';
}

export function sanitizeFileName(raw: string, fallback = 'asset'): string {
  const base = posixBasename(raw.trim()).replace(/[\\/:*?"<>|\x00-\x1f]/g, '_').trim();
  const cleaned = base.replace(/^\.+/, '');
  return cleaned.length > 0 ? cleaned.slice(0, 180) : fallback;
}

/**
 * Checks whether a PNG buffer is an animated PNG (APNG) by scanning for an `acTL` chunk before `IDAT`.
 */
function isAnimatedPng(buf: Uint8Array): boolean {
  if (buf.byteLength < 32) return false;
  if (
    buf[0] !== 0x89 ||
    buf[1] !== 0x50 ||
    buf[2] !== 0x4e ||
    buf[3] !== 0x47 ||
    buf[4] !== 0x0d ||
    buf[5] !== 0x0a ||
    buf[6] !== 0x1a ||
    buf[7] !== 0x0a
  ) {
    return false;
  }
  const view = new DataView(buf.buffer, buf.byteOffset, buf.byteLength);
  let offset = 8;
  while (offset + 8 <= buf.byteLength) {
    const len = view.getUint32(offset, false);
    const chunkType = String.fromCharCode(
      buf[offset + 4],
      buf[offset + 5],
      buf[offset + 6],
      buf[offset + 7],
    );
    if (chunkType === 'acTL') return true;
    if (chunkType === 'IDAT') return false;
    offset += 12 + len;
  }
  return false;
}

function buildWeblocXml(url: string): Uint8Array {
  const escaped = url
    .replace(/&/g, '&amp;')
    .replace(/</g, '&lt;')
    .replace(/>/g, '&gt;');
  return utf8Encode(
    `<?xml version="1.0" encoding="UTF-8"?>\n<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">\n<plist version="1.0"><dict><key>URL</key><string>${escaped}</string></dict></plist>\n`,
  );
}

export interface MediaPipelineDeps {
  blobs: IBlobStore;
  images: IImageProcessor;
  cacheBudgetBytes?: number;
  /** Optional Node-only local file reader for `CaptureInput { type: 'fileURL' }`. */
  readLocalFile?: (filePath: string) => Promise<Uint8Array>;
}

/**
 * Runtime-agnostic media pipeline backed by `IBlobStore` and `IImageProcessor`.
 * Stores all blobs cleanly under:
 * - `originals/<ID>.<ext>`
 * - `thumbnails/520/<ID>.<ext>`
 * - `thumbnails/1400/<ID>.<ext>`
 *
 * ZERO direct `node:fs`, `node:path`, `node:crypto`, or `sharp` imports.
 */
export class MediaPipeline implements IMediaPipeline {
  public readonly blobs: IBlobStore;
  public readonly images: IImageProcessor;
  private readonly readLocalFile?: (filePath: string) => Promise<Uint8Array>;
  private cacheBudgetBytes: number;

  constructor(deps: MediaPipelineDeps) {
    this.blobs = deps.blobs;
    this.images = deps.images;
    this.readLocalFile = deps.readLocalFile;
    this.cacheBudgetBytes = deps.cacheBudgetBytes ?? DEFAULT_CACHE_BUDGET_BYTES;
  }

  private thumbnailKey(id: UUID, tier: ThumbnailTier = 'grid520', ext = 'jpg'): string {
    const dir = tier === 'grid520' ? 'thumbnails/520' : 'thumbnails/1400';
    return `${dir}/${toSwiftUUID(id)}.${ext}`;
  }

  originalBlobKey(asset: AssetRecord): string {
    const ext = posixExtname(asset.fileName)
      .replace(/^\./, '')
      .toLowerCase()
      .replace(/[^a-z0-9]/g, '')
      .slice(0, 16);
    const base = toSwiftUUID(asset.id);
    return ext ? `originals/${base}.${ext}` : `originals/${base}`;
  }

  thumbnailTargetPath(id: UUID, tier: ThumbnailTier = 'grid520'): string {
    const key = this.thumbnailKey(id, tier, 'jpg');
    return this.blobs.targetFilePath ? this.blobs.targetFilePath(key) : key;
  }

  getThumbnailPath(id: UUID, tier: ThumbnailTier = 'grid520'): string | null {
    if (!this.blobs.localFilePath) return null;
    for (const cand of THUMB_EXT_CANDIDATES) {
      const hit = this.blobs.localFilePath(this.thumbnailKey(id, tier, cand.ext));
      if (hit) return hit;
    }
    if (tier === 'preview1400') {
      for (const cand of THUMB_EXT_CANDIDATES) {
        const hit = this.blobs.localFilePath(this.thumbnailKey(id, 'grid520', cand.ext));
        if (hit) return hit;
      }
    }
    return null;
  }

  originalTargetPath(asset: AssetRecord): string {
    const key = this.originalBlobKey(asset);
    return this.blobs.targetFilePath ? this.blobs.targetFilePath(key) : key;
  }

  getOriginalPath(asset: AssetRecord): string | null {
    if (!this.blobs.localFilePath) return null;
    return this.blobs.localFilePath(this.originalBlobKey(asset));
  }

  cachedOriginalPath(asset: AssetRecord): string | null {
    return this.getOriginalPath(asset);
  }

  async findOriginalBlobKey(asset: AssetRecord): Promise<string | null> {
    const direct = this.originalBlobKey(asset);
    if (await this.blobs.head(direct)) return direct;
    const prefix = `originals/${toSwiftUUID(asset.id)}`;
    const listed = await this.blobs.list(prefix);
    const found = listed.find((item) => item.key === prefix || item.key.startsWith(`${prefix}.`));
    return found ? found.key : null;
  }

  async findThumbnailBlobKey(
    id: UUID,
    tier: ThumbnailTier = 'grid520',
  ): Promise<{ key: string; contentType: string } | null> {
    for (const cand of THUMB_EXT_CANDIDATES) {
      const key = this.thumbnailKey(id, tier, cand.ext);
      const info = await this.blobs.head(key);
      if (info) {
        return { key, contentType: info.contentType || cand.mime };
      }
    }
    if (tier === 'preview1400') {
      for (const cand of THUMB_EXT_CANDIDATES) {
        const key = this.thumbnailKey(id, 'grid520', cand.ext);
        const info = await this.blobs.head(key);
        if (info) {
          return { key, contentType: info.contentType || cand.mime };
        }
      }
    }
    return null;
  }

  async hasOriginal(asset: AssetRecord): Promise<boolean> {
    return (await this.findOriginalBlobKey(asset)) !== null;
  }

  async hasThumbnail(id: UUID, tier: ThumbnailTier = 'grid520'): Promise<boolean> {
    return (await this.findThumbnailBlobKey(id, tier)) !== null;
  }

  async getThumbnailHead(
    id: UUID,
    tier: ThumbnailTier = 'grid520',
  ): Promise<(BlobHeadResult & { key: string; contentType: string }) | null> {
    for (const cand of THUMB_EXT_CANDIDATES) {
      const key = this.thumbnailKey(id, tier, cand.ext);
      const info = await this.blobs.head(key);
      if (info) {
        return { ...info, key, contentType: info.contentType || cand.mime };
      }
    }
    if (tier === 'preview1400') {
      for (const cand of THUMB_EXT_CANDIDATES) {
        const key = this.thumbnailKey(id, 'grid520', cand.ext);
        const info = await this.blobs.head(key);
        if (info) {
          return { ...info, key, contentType: info.contentType || cand.mime };
        }
      }
    }
    return null;
  }

  async getThumbnailStream(
    id: UUID,
    tier: ThumbnailTier = 'grid520',
  ): Promise<(BlobStreamResult & { key: string; contentType: string }) | null> {
    const found = await this.findThumbnailBlobKey(id, tier);
    if (!found) return null;
    const res = await this.blobs.getStream(found.key);
    if (!res) return null;
    return {
      ...res,
      key: found.key,
      contentType: res.contentType || found.contentType,
    };
  }

  async getOriginalHead(asset: AssetRecord): Promise<(BlobHeadResult & { key: string }) | null> {
    const key = await this.findOriginalBlobKey(asset);
    if (!key) return null;
    const info = await this.blobs.head(key);
    return info ? { ...info, key } : null;
  }

  async getOriginalStream(
    asset: AssetRecord,
    range?: BlobRangeRequest,
  ): Promise<BlobStreamResult | null> {
    const key = await this.findOriginalBlobKey(asset);
    if (!key) return null;
    return this.blobs.getStream(key, range);
  }

  async readThumbnailBuffer(id: UUID, tier: ThumbnailTier = 'grid520'): Promise<Buffer | null> {
    const found = await this.findThumbnailBlobKey(id, tier);
    if (!found) return null;
    const bytes = await this.blobs.getBytes(found.key);
    return bytes ? toBuffer(bytes) : null;
  }

  async readOriginalBuffer(asset: AssetRecord): Promise<Buffer | null> {
    const key = await this.findOriginalBlobKey(asset);
    if (!key) return null;
    const bytes = await this.blobs.getBytes(key);
    return bytes ? toBuffer(bytes) : null;
  }

  async installOriginal(
    source: Uint8Array | ReadableStream<Uint8Array> | string,
    asset: AssetRecord,
    _moveSource = false,
  ): Promise<string> {
    const destKey = this.originalBlobKey(asset);
    const previousKey = await this.findOriginalBlobKey(asset);

    let payload: Uint8Array | ReadableStream<Uint8Array>;
    if (typeof source === 'string') {
      if (!this.readLocalFile) {
        throw new Error('当前运行环境不支持从本地文件路径安装原始文件。');
      }
      payload = await this.readLocalFile(source);
    } else {
      payload = source;
    }

    await this.blobs.put(destKey, payload, {
      contentType: asset.mimeType || 'application/octet-stream',
    });

    if (previousKey && previousKey !== destKey) {
      await this.blobs.delete(previousKey).catch(() => undefined);
    }
    return this.blobs.localFilePath?.(destKey) ?? destKey;
  }

  async writeThumbnail(
    id: UUID,
    tier: ThumbnailTier,
    bytes: Uint8Array,
    mimeType?: string,
  ): Promise<string> {
    const resolvedMime = sniffImageMimeType(bytes, mimeType || 'image/jpeg');
    const ext = extForImageMime(resolvedMime);
    const targetKey = this.thumbnailKey(id, tier, ext);

    // Clean up any stale thumbnail with a different extension for this tier
    for (const cand of THUMB_EXT_CANDIDATES) {
      if (cand.ext !== ext) {
        await this.blobs.delete(this.thumbnailKey(id, tier, cand.ext)).catch(() => undefined);
      }
    }

    await this.blobs.put(targetKey, bytes, { contentType: resolvedMime });
    return this.blobs.localFilePath?.(targetKey) ?? targetKey;
  }

  private async clearThumbnailTier(id: UUID, tier: ThumbnailTier): Promise<void> {
    for (const cand of THUMB_EXT_CANDIDATES) {
      await this.blobs.delete(this.thumbnailKey(id, tier, cand.ext)).catch(() => undefined);
    }
  }

  async extractDominantColors(imageBuffer: Uint8Array, count = 6): Promise<LabColor[]> {
    const res = await this.images.extractColorsAndFingerprint(imageBuffer, undefined, { count });
    return res.colors;
  }

  async computeVisualFingerprint(imageBuffer: Uint8Array): Promise<number[]> {
    const res = await this.images.extractColorsAndFingerprint(imageBuffer);
    return res.featurePrint ? Array.from(res.featurePrint) : [];
  }

  async generateThumbnailsFromBuffer(
    id: UUID,
    imageBuffer: Uint8Array,
    mimeType?: string,
  ): Promise<{ width: number; height: number }> {
    const resolvedMime = sniffImageMimeType(imageBuffer, mimeType || 'image/jpeg');
    const generated = await this.images.generateThumbnails(imageBuffer, resolvedMime);
    const width = generated.width ?? 800;
    const height = generated.height ?? 600;
    const thumbMime = generated.mimeType ?? resolvedMime;

    if (generated.grid520 && generated.grid520.byteLength > 0) {
      await this.writeThumbnail(id, 'grid520', generated.grid520, thumbMime);
    }
    if (generated.preview1400 && generated.preview1400.byteLength > 0) {
      await this.writeThumbnail(id, 'preview1400', generated.preview1400, thumbMime);
    } else {
      await this.clearThumbnailTier(id, 'preview1400');
    }

    return { width, height };
  }

  private async storeRenderedCard(
    id: UUID,
    card: {
      grid520: Uint8Array;
      preview1400?: Uint8Array;
      mimeType: string;
      width: number;
      height: number;
    },
  ): Promise<{ width: number; height: number }> {
    await this.writeThumbnail(id, 'grid520', card.grid520, card.mimeType);
    if (card.preview1400 && card.preview1400.byteLength > 0) {
      await this.writeThumbnail(id, 'preview1400', card.preview1400, card.mimeType);
    } else {
      await this.clearThumbnailTier(id, 'preview1400');
    }
    return { width: card.width, height: card.height };
  }

  // MARK: - Unified Ingestion (All 5 CaptureInputs & All 8 MediaKinds + ClientPreprocessedMedia)

  async ingest(
    input: CaptureInput,
    folderID: UUID | null = null,
    id: UUID = toSwiftUUID(randomUUID()),
  ): Promise<MediaIngestResult> {
    const assetID = toSwiftUUID(id);

    switch (input.type) {
      case 'fileURL': {
        if (!this.readLocalFile) {
          throw new Error('当前运行环境不支持直接读取服务器本地文件路径，请通过文件上传导入。');
        }
        const rawPath = input.url.startsWith('file://')
          ? decodeURIComponent(new URL(input.url).pathname)
          : input.url;
        const buffer = await this.readLocalFile(rawPath);
        const fileName = sanitizeFileName(posixBasename(rawPath));
        return this.ingestUploadedFile(
          buffer,
          fileName,
          guessMimeType(fileName),
          folderID,
          assetID,
          input.preprocessed ?? null,
        );
      }

      case 'imageData': {
        const buffer = base64ToBytes(input.base64Data);
        if (buffer.byteLength === 0) {
          throw new Error('图片数据为空。');
        }
        let ext = posixExtname(input.suggestedName).replace(/^\./, '').toLowerCase();
        if (!ext) {
          const info = await this.images.inspectDimensions(buffer).catch(() => null);
          if (info?.format) {
            ext = info.format === 'jpeg' ? 'jpg' : info.format;
          } else {
            const sniffed = sniffImageMimeType(buffer, 'image/png');
            ext = extForImageMime(sniffed);
          }
        }
        const base = sanitizeFileName(posixStripExt(input.suggestedName) || 'Clipboard Image');
        const fileName = `${base}.${ext}`;
        const result = await this.ingestUploadedFile(
          buffer,
          fileName,
          guessMimeType(fileName),
          folderID,
          assetID,
          input.preprocessed ?? null,
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
        return this.ingestWebURL(
          input.url,
          input.title ?? null,
          input.notes ?? '',
          folderID,
          assetID,
        );
      }

      case 'textSnippet': {
        const cleanTitle = input.title.trim() || '文本片段';
        const fileName = `${sanitizeFileName(cleanTitle)}.md`;
        const buffer = utf8Encode(input.text);
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
        const card = await this.images.renderArtworkCard({
          kind: 'colorSwatch',
          color: swatch,
          title,
        });
        const isSvg = card.mimeType === 'image/svg+xml' || sniffImageMimeType(card.fullImage) === 'image/svg+xml';
        const fileName = `${sanitizeFileName(title)}.${isSvg ? 'svg' : 'png'}`;
        const originalMime = isSvg ? 'image/svg+xml' : 'image/png';
        const now = new Date().toISOString();
        await this.storeRenderedCard(assetID, card);
        const analysis = await this.images
          .extractColorsAndFingerprint(card.fullImage, originalMime, { count: 3 })
          .catch(() => ({ colors: [swatch], featurePrint: undefined }));
        const asset = createDefaultAssetRecord({
          id: assetID,
          title,
          fileName,
          folderID: folderID ? toSwiftUUID(folderID) : null,
          contentHash: sha256HexSync(card.fullImage),
          mediaKind: 'image',
          mimeType: originalMime,
          fileSizeBytes: card.fullImage.byteLength,
          pixelWidth: card.width,
          pixelHeight: card.height,
          dominantColors: [swatch],
          notes: `HEX ${swatch.hex} · CIELAB (${swatch.l.toFixed(1)}, ${swatch.a.toFixed(1)}, ${swatch.b.toFixed(1)})`,
          tags: ['色卡'],
          isLocalOriginalCached: true,
          createdAt: now,
          updatedAt: now,
        });
        const originalPath = await this.installOriginal(card.fullImage, asset);
        const vector: AssetVector | null = analysis.featurePrint
          ? {
              featurePrint: encodeFeaturePrintFloat32(Array.from(analysis.featurePrint)),
              embedding: null,
              precision: 16,
            }
          : null;
        return { asset, originalPath, vector };
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
        const originalBuf: Uint8Array = primaryVideoBuffer ?? utf8Encode(markdownArchive);
        const fileExt = primaryVideoBuffer ? 'mp4' : 'md';
        const fileName = `${sanitizeFileName(metadata.authorHandle + '-' + assetID.slice(0, 8))}.${fileExt}`;

        const card = await this.images.renderArtworkCard({
          kind: 'socialPost',
          post: metadata,
          coverImageBytes: coverImageBuffer ?? null,
        });
        const dims = await this.storeRenderedCard(assetID, card);
        const colorSource: Uint8Array = coverImageBuffer ?? card.fullImage;
        const analysis = await this.images
          .extractColorsAndFingerprint(colorSource, undefined, { count: 6 })
          .catch(() => ({ colors: [] as LabColor[], featurePrint: undefined }));

        const asset = createDefaultAssetRecord({
          id: assetID,
          title: suppliedTitle?.trim() || title,
          fileName,
          folderID,
          contentHash: sha256HexSync(originalBuf),
          mediaKind: 'webBookmark', // CRITICAL COHESIVE INVARIANT
          mimeType: primaryVideoBuffer ? 'video/mp4' : 'text/markdown',
          fileSizeBytes: originalBuf.byteLength,
          pixelWidth: dims.width,
          pixelHeight: dims.height,
          sourceURL: metadata.originalURL,
          sourceDomain: new URL(metadata.originalURL).hostname,
          notes: suppliedNotes,
          tags: [platformTag],
          ocrText: metadata.bodyText || null,
          dominantColors: analysis.colors,
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
        const vector: AssetVector | null = analysis.featurePrint
          ? {
              featurePrint: encodeFeaturePrintFloat32(Array.from(analysis.featurePrint)),
              embedding: null,
              precision: 16,
            }
          : null;
        return { asset, originalPath, vector };
      }
    }

    // 2. GitHub Repository
    if (parseGitHubRepoURL(rawUrl)) {
      const repo = await resolveGitHubRepo(rawUrl);
      if (repo) {
        const card = await this.images.renderArtworkCard({ kind: 'githubRepo', repo });
        const dims = await this.storeRenderedCard(assetID, card);
        const analysis = await this.images
          .extractColorsAndFingerprint(card.fullImage, card.mimeType, { count: 5 })
          .catch(() => ({ colors: [] as LabColor[], featurePrint: undefined }));
        const originalBuf = buildWeblocXml(`https://github.com/${repo.fullName}`);
        const fileName = `${sanitizeFileName(repo.owner + '-' + repo.repo)}.webloc`;
        const tags = ['GitHub', ...(repo.language ? [repo.language] : [])];

        const asset = createDefaultAssetRecord({
          id: assetID,
          title: suppliedTitle?.trim() || repo.fullName,
          fileName,
          folderID,
          contentHash: sha256HexSync(originalBuf),
          mediaKind: 'webBookmark',
          mimeType: 'application/xml',
          fileSizeBytes: originalBuf.byteLength,
          pixelWidth: dims.width,
          pixelHeight: dims.height,
          sourceURL: `https://github.com/${repo.fullName}`,
          sourceDomain: 'github.com',
          notes: suppliedNotes || repo.description || '',
          tags,
          ocrText: repo.description ?? null,
          dominantColors: analysis.colors,
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
        const vector: AssetVector | null = analysis.featurePrint
          ? {
              featurePrint: encodeFeaturePrintFloat32(Array.from(analysis.featurePrint)),
              embedding: null,
              precision: 16,
            }
          : null;
        return { asset, originalPath, vector };
      }
    }

    // 3. Generic Web Bookmark
    const bookmark = await resolveWebBookmark(rawUrl);
    const title = suppliedTitle?.trim() || bookmark.title || domain;
    let dims = { width: 800, height: 640 };
    let dominantColors: LabColor[] = [];
    let fp: Float32Array | undefined;

    if (bookmark.posterBuffer) {
      try {
        dims = await this.generateThumbnailsFromBuffer(assetID, bookmark.posterBuffer);
        const analysis = await this.images.extractColorsAndFingerprint(
          bookmark.posterBuffer,
          undefined,
          { count: 5 },
        );
        dominantColors = analysis.colors;
        fp = analysis.featurePrint;
      } catch {
        const fallback = await this.images.renderArtworkCard({
          kind: 'webBookmark',
          title,
          domain,
          description: bookmark.description,
        });
        dims = await this.storeRenderedCard(assetID, fallback);
        const analysis = await this.images
          .extractColorsAndFingerprint(fallback.fullImage, fallback.mimeType, { count: 5 })
          .catch(() => ({ colors: [] as LabColor[], featurePrint: undefined }));
        dominantColors = analysis.colors;
        fp = analysis.featurePrint;
      }
    } else {
      const card = await this.images.renderArtworkCard({
        kind: 'webBookmark',
        title,
        domain,
        description: bookmark.description,
      });
      dims = await this.storeRenderedCard(assetID, card);
      const analysis = await this.images
        .extractColorsAndFingerprint(card.fullImage, card.mimeType, { count: 5 })
        .catch(() => ({ colors: [] as LabColor[], featurePrint: undefined }));
      dominantColors = analysis.colors;
      fp = analysis.featurePrint;
    }

    const originalBuf = buildWeblocXml(rawUrl);
    const fileName = `${sanitizeFileName(title)}.webloc`;
    const asset = createDefaultAssetRecord({
      id: assetID,
      title,
      fileName,
      folderID,
      contentHash: sha256HexSync(originalBuf),
      mediaKind: 'webBookmark',
      mimeType: 'application/xml',
      fileSizeBytes: originalBuf.byteLength,
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
      ? { featurePrint: encodeFeaturePrintFloat32(Array.from(fp)), embedding: null, precision: 16 }
      : null;
    return { asset, originalPath, vector };
  }

  async ingestUploadedFile(
    data: Uint8Array,
    rawFileName: string,
    mimeType: string | null,
    folderID: UUID | null = null,
    id: UUID = toSwiftUUID(randomUUID()),
    preprocessed?: ClientPreprocessedMedia | null,
  ): Promise<MediaIngestResult> {
    const buffer = data instanceof Uint8Array ? data : new Uint8Array(data);
    const assetID = toSwiftUUID(id);
    const fileName = sanitizeFileName(rawFileName);
    const ext = posixExtname(fileName).replace(/^\./, '').toLowerCase();
    const resolvedMime =
      mimeType && mimeType !== 'application/octet-stream' ? mimeType : guessMimeType(fileName);
    let mediaKind: MediaKind = detectMediaKind(ext, resolvedMime);

    if (ext === 'png' && isAnimatedPng(buffer)) {
      mediaKind = 'animatedImage';
    }

    const now = new Date().toISOString();
    const title = posixStripExt(fileName) || fileName;
    const asset = createDefaultAssetRecord({
      id: assetID,
      title,
      fileName,
      folderID: folderID ? toSwiftUUID(folderID) : null,
      contentHash: sha256HexSync(buffer),
      mediaKind,
      mimeType: resolvedMime,
      fileSizeBytes: buffer.byteLength,
      isLocalOriginalCached: true,
      createdAt: now,
      updatedAt: now,
    });

    // Apply client-supplied preprocessed thumbnails, dimensions, colors, fingerprint, waveform, duration
    let hasClientThumb520 = false;
    let hasClientDims = false;
    let vector: AssetVector | null = null;

    if (preprocessed) {
      if (
        typeof preprocessed.pixelWidth === 'number' &&
        preprocessed.pixelWidth > 0 &&
        typeof preprocessed.pixelHeight === 'number' &&
        preprocessed.pixelHeight > 0
      ) {
        asset.pixelWidth = Math.round(preprocessed.pixelWidth);
        asset.pixelHeight = Math.round(preprocessed.pixelHeight);
        hasClientDims = true;
      }
      if (typeof preprocessed.durationSeconds === 'number' && preprocessed.durationSeconds > 0) {
        asset.durationSeconds = Math.round(preprocessed.durationSeconds * 100) / 100;
      }
      if (Array.isArray(preprocessed.waveformPeaks) && preprocessed.waveformPeaks.length > 0) {
        asset.waveformPeaks = preprocessed.waveformPeaks
          .slice(0, 64)
          .map((v) => Math.max(0.05, Math.min(1, Number(v) || 0.1)));
      }
      if (
        mediaKind !== 'audio' &&
        Array.isArray(preprocessed.dominantColors) &&
        preprocessed.dominantColors.length > 0
      ) {
        asset.dominantColors = preprocessed.dominantColors.slice(0, 8);
      }
      if (typeof preprocessed.featurePrintBase64 === 'string' && preprocessed.featurePrintBase64.trim()) {
        vector = {
          featurePrint: preprocessed.featurePrintBase64.trim(),
          embedding: null,
          precision: 16,
        };
      }
      if (typeof preprocessed.thumbnail520Base64 === 'string' && preprocessed.thumbnail520Base64.trim()) {
        try {
          const thumb520Bytes = base64ToBytes(preprocessed.thumbnail520Base64);
          if (thumb520Bytes.byteLength > 0) {
            await this.writeThumbnail(assetID, 'grid520', thumb520Bytes);
            hasClientThumb520 = true;
          }
        } catch {
          // Fall back to server generation below
        }
      }
      if (typeof preprocessed.thumbnail1400Base64 === 'string' && preprocessed.thumbnail1400Base64.trim()) {
        try {
          const thumb1400Bytes = base64ToBytes(preprocessed.thumbnail1400Base64);
          if (thumb1400Bytes.byteLength > 0) {
            await this.writeThumbnail(assetID, 'preview1400', thumb1400Bytes);
          }
        } catch {
          // Ignore invalid optional preview1400
        }
      }
    }

    let renderedCard:
      | {
          grid520: Uint8Array;
          preview1400?: Uint8Array;
          fullImage: Uint8Array;
          mimeType: string;
          width: number;
          height: number;
        }
      | null = null;

    switch (mediaKind) {
      case 'image':
      case 'animatedImage': {
        if (!hasClientThumb520) {
          try {
            const dims = await this.generateThumbnailsFromBuffer(assetID, buffer, resolvedMime);
            if (!hasClientDims) {
              asset.pixelWidth = dims.width;
              asset.pixelHeight = dims.height;
              hasClientDims = true;
            }
          } catch {
            renderedCard = await this.images.renderArtworkCard({
              kind: 'genericBadge',
              title,
              ext: ext || 'IMG',
              kindLabel: mediaKindLocalizedLabel(mediaKind),
            });
          }
        } else if (!hasClientDims) {
          const inspected = await this.images.inspectDimensions(buffer, resolvedMime).catch(() => null);
          if (inspected) {
            asset.pixelWidth = inspected.width;
            asset.pixelHeight = inspected.height;
            hasClientDims = true;
          }
        }

        if (!renderedCard && (asset.dominantColors.length === 0 || !vector)) {
          const analysis = await this.images
            .extractColorsAndFingerprint(buffer, resolvedMime, { count: 6 })
            .catch(() => ({ colors: [] as LabColor[], featurePrint: undefined }));
          if (asset.dominantColors.length === 0 && analysis.colors.length > 0) {
            asset.dominantColors = analysis.colors;
          }
          if (!vector && analysis.featurePrint) {
            vector = {
              featurePrint: encodeFeaturePrintFloat32(Array.from(analysis.featurePrint)),
              embedding: null,
              precision: 16,
            };
          }
        }
        break;
      }

      case 'designFile': {
        if (!hasClientThumb520) {
          try {
            const dims = await this.generateThumbnailsFromBuffer(assetID, buffer, resolvedMime);
            if (!hasClientDims) {
              asset.pixelWidth = dims.width;
              asset.pixelHeight = dims.height;
              hasClientDims = true;
            }
          } catch {
            renderedCard = await this.images.renderArtworkCard({
              kind: 'genericBadge',
              title,
              ext: ext || 'DESIGN',
              kindLabel: mediaKindLocalizedLabel(mediaKind),
            });
          }
        }
        if (!renderedCard && (asset.dominantColors.length === 0 || !vector)) {
          const analysis = await this.images
            .extractColorsAndFingerprint(buffer, resolvedMime, { count: 6 })
            .catch(() => ({ colors: [] as LabColor[], featurePrint: undefined }));
          if (asset.dominantColors.length === 0 && analysis.colors.length > 0) {
            asset.dominantColors = analysis.colors;
          }
          if (!vector && analysis.featurePrint) {
            vector = {
              featurePrint: encodeFeaturePrintFloat32(Array.from(analysis.featurePrint)),
              embedding: null,
              precision: 16,
            };
          }
        }
        break;
      }

      case 'document': {
        if (PLAIN_TEXT_EXTS.has(ext)) {
          const text = utf8Decode(buffer.subarray(0, 65_536));
          asset.richMetadata = {
            githubRepo: null,
            socialPost: null,
            textExcerpt: text.slice(0, 1200),
            isMarkdown: ext === 'md' || ext === 'markdown',
            model3DFormat: null,
          };
          asset.ocrText = text.slice(0, 8000);
          if (!hasClientThumb520) {
            renderedCard = await this.images.renderArtworkCard({
              kind: 'textDocument',
              title,
              badge: (ext || 'TXT').toUpperCase(),
              excerpt: text,
            });
          }
        } else if (!hasClientThumb520) {
          renderedCard = await this.images.renderArtworkCard({
            kind: 'genericBadge',
            title,
            ext: ext || 'DOC',
            kindLabel: mediaKindLocalizedLabel(mediaKind),
          });
        }
        break;
      }

      case 'audio': {
        // Extract 48-bar waveform + duration; explicitly skip dominantColors & OCR per PARITY_SPEC 3.2
        if (asset.waveformPeaks.length === 0) {
          const audio = extractAudioWaveform(buffer, fileName, 48);
          if (asset.durationSeconds == null) asset.durationSeconds = audio.durationSeconds;
          asset.waveformPeaks = audio.waveformPeaks;
        }
        asset.dominantColors = [];
        asset.ocrText = null;
        if (!hasClientThumb520) {
          renderedCard = await this.images.renderArtworkCard({
            kind: 'audioWaveform',
            title,
            peaks: asset.waveformPeaks,
            durationSeconds: asset.durationSeconds ?? null,
          });
        }
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
        if (!hasClientThumb520) {
          renderedCard = await this.images.renderArtworkCard({
            kind: 'model3D',
            title,
            format: fmt,
          });
        }
        break;
      }

      case 'video': {
        if (!hasClientThumb520) {
          renderedCard = await this.images.renderArtworkCard({
            kind: 'genericBadge',
            title,
            ext: ext || 'VIDEO',
            kindLabel: mediaKindLocalizedLabel(mediaKind),
          });
        }
        break;
      }

      case 'webBookmark': {
        const text = utf8Decode(buffer);
        const urlMatch = /https?:\/\/[^\s<>"']+/i.exec(text);
        if (urlMatch && isWebURL(urlMatch[0])) {
          return this.ingestWebURL(urlMatch[0], null, '', folderID, assetID);
        }
        if (!hasClientThumb520) {
          renderedCard = await this.images.renderArtworkCard({
            kind: 'webBookmark',
            title,
            domain: 'bookmark',
            description: null,
          });
        }
        break;
      }
    }

    if (renderedCard) {
      const dims = await this.storeRenderedCard(assetID, renderedCard);
      if (!hasClientDims) {
        asset.pixelWidth = dims.width;
        asset.pixelHeight = dims.height;
      }
      const analysis = await this.images
        .extractColorsAndFingerprint(renderedCard.fullImage, renderedCard.mimeType, { count: 5 })
        .catch(() => ({ colors: [] as LabColor[], featurePrint: undefined }));
      if (mediaKind !== 'audio' && asset.dominantColors.length === 0) {
        asset.dominantColors = analysis.colors;
      }
      if (!vector && analysis.featurePrint) {
        vector = {
          featurePrint: encodeFeaturePrintFloat32(Array.from(analysis.featurePrint)),
          embedding: null,
          precision: 16,
        };
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
      const origKey = (await this.findOriginalBlobKey(asset)) ?? this.originalBlobKey(asset);
      return {
        asset,
        originalPath: this.blobs.localFilePath?.(origKey) ?? origKey,
        vector: null,
      };
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
      let buf: Uint8Array | null = null;

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
            ? att.url.toLowerCase().includes('.gif')
              ? 'gif'
              : 'mp4'
            : (() => {
                try {
                  const u = new URL(att.url);
                  const fmt = u.searchParams.get('format');
                  if (fmt) return fmt.toLowerCase();
                  const pExt = posixExtname(u.pathname).replace(/^\./, '').toLowerCase();
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
    const origKey = await this.findOriginalBlobKey(asset);
    if (origKey) {
      await this.blobs.delete(origKey).catch(() => undefined);
    }
    await this.clearThumbnailTier(asset.id, 'grid520');
    await this.clearThumbnailTier(asset.id, 'preview1400');
  }

  async removeFilesByIDs(ids: Iterable<UUID>): Promise<void> {
    const idSet = new Set(Array.from(ids, toSwiftUUID));
    if (idSet.size === 0) return;

    const allOriginals = await this.blobs.list('originals/').catch(() => []);
    for (const item of allOriginals) {
      const name = posixBasename(item.key);
      const stem = posixStripExt(name).toUpperCase();
      if (idSet.has(stem)) {
        await this.blobs.delete(item.key).catch(() => undefined);
      }
    }

    for (const id of idSet) {
      await this.clearThumbnailTier(id, 'grid520');
      await this.clearThumbnailTier(id, 'preview1400');
    }
  }

  getCacheBudgetBytes(): number {
    return this.cacheBudgetBytes;
  }

  setCacheBudgetBytes(bytes: number): void {
    this.cacheBudgetBytes = Math.max(1024 * 1024, Math.round(bytes));
  }

  async getCacheStats(db: LibraryDatabase): Promise<CacheStats> {
    const [thumbs520, thumbs1400, originals] = await Promise.all([
      this.blobs.list('thumbnails/520/').catch(() => []),
      this.blobs.list('thumbnails/1400/').catch(() => []),
      this.blobs.list('originals/').catch(() => []),
    ]);

    const thumbnailBytes =
      thumbs520.reduce((s, e) => s + e.size, 0) + thumbs1400.reduce((s, e) => s + e.size, 0);
    const protectedIDs = db.protectedAssetIDs();
    let originalCacheBytes = 0;
    let pinnedOfflineBytes = 0;
    let pinnedCount = 0;

    for (const entry of originals) {
      const id = posixStripExt(posixBasename(entry.key)).toUpperCase();
      if (protectedIDs.has(id)) {
        pinnedOfflineBytes += entry.size;
        pinnedCount++;
      } else {
        originalCacheBytes += entry.size;
      }
    }

    return {
      thumbnailBytes,
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
    const originals = await this.blobs.list('originals/').catch(() => []);

    let totalOriginalsBytes = originals.reduce((s, e) => s + e.size, 0);
    if (totalOriginalsBytes > this.cacheBudgetBytes) {
      const evictable = originals
        .map((e) => ({
          id: posixStripExt(posixBasename(e.key)).toUpperCase(),
          key: e.key,
          size: e.size,
          mtimeMs: e.lastModifiedMs ?? 0,
        }))
        .filter((e) => !protectedIDs.has(e.id))
        .sort((a, b) => {
          const ta = accessTimes.get(a.id) ?? a.mtimeMs / 1000;
          const tb = accessTimes.get(b.id) ?? b.mtimeMs / 1000;
          return ta - tb;
        });

      for (const entry of evictable) {
        if (totalOriginalsBytes <= this.cacheBudgetBytes) break;
        await this.blobs.delete(entry.key).catch(() => undefined);
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
