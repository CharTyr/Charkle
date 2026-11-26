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
import {
  encodeFeaturePrintFloat32,
  type BlobIndexSlot,
  type LibraryDatabase,
} from '../db/library-database.js';
import { isBinaryPlist, parseBinaryPlist } from '../runtime/bplist.js';
import type {
  BlobConditionalGetOptions,
  BlobConditionalStreamResult,
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
import { extractImageMetadata } from './image-metadata-extractor.js';
import { isWebURL, resolveWebBookmark } from './resolvers/bookmark.js';
import {
  fetchGitHubOpenGraphCardBytes,
  parseGitHubRepoURL,
  resolveGitHubRepo,
} from './resolvers/github.js';
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
  /** Optional SQLite database enabling persistent `blob_index` key/size tracking (zero R2 `head`/`list` amplification). */
  db?: LibraryDatabase;
  cacheBudgetBytes?: number;
  /** Optional Node-only local file reader for `CaptureInput { type: 'fileURL' }`. */
  readLocalFile?: (filePath: string) => Promise<Uint8Array>;
}

interface LocalBlobRecord {
  blobKey: string;
  contentType: string | null;
  sizeBytes: number;
  updatedAt: number;
}

function ifNoneMatchMatchesHeader(headerValue: string | undefined, etag: string | undefined): boolean {
  if (!headerValue || !etag) return false;
  const cleanTarget = etag.trim().replace(/^W\//i, '').replace(/^"|"$/g, '');
  if (!cleanTarget) return false;
  for (const rawPart of headerValue.split(',')) {
    const part = rawPart.trim();
    if (!part) continue;
    if (part === '*') return true;
    const cleanPart = part.replace(/^W\//i, '').replace(/^"|"$/g, '');
    if (cleanPart === cleanTarget) return true;
  }
  return false;
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
  private readonly db?: LibraryDatabase;
  private readonly memBlobIndex = new Map<string, LocalBlobRecord>();
  private readonly readLocalFile?: (filePath: string) => Promise<Uint8Array>;
  private cacheBudgetBytes: number;

  constructor(deps: MediaPipelineDeps) {
    this.blobs = deps.blobs;
    this.images = deps.images;
    this.db = deps.db;
    this.readLocalFile = deps.readLocalFile;
    this.cacheBudgetBytes = deps.cacheBudgetBytes ?? DEFAULT_CACHE_BUDGET_BYTES;
  }

  private memIndexKey(assetID: UUID, slot: BlobIndexSlot): string {
    return `${toSwiftUUID(assetID)}:${slot}`;
  }

  private isIndexHydrated(): boolean {
    return Boolean(this.db?.isBlobIndexHydrated());
  }

  private getIndexedBlob(assetID: UUID, slot: BlobIndexSlot): LocalBlobRecord | null {
    if (this.db) {
      const row = this.db.getBlobIndexEntry(assetID, slot);
      if (row) {
        return {
          blobKey: row.blobKey,
          contentType: row.contentType,
          sizeBytes: row.sizeBytes,
          updatedAt: row.updatedAt,
        };
      }
      return null;
    }
    return this.memBlobIndex.get(this.memIndexKey(assetID, slot)) ?? null;
  }

  recordBlobKey(
    assetID: UUID,
    slot: BlobIndexSlot,
    key: string,
    sizeBytes: number,
    contentType?: string | null,
  ): void {
    const normalizedID = toSwiftUUID(assetID);
    const resolvedType = contentType ?? guessMimeType(key);
    const cleanSize = Math.max(0, Math.trunc(sizeBytes));
    if (this.db) {
      this.db.setBlobIndexEntry(normalizedID, slot, key, cleanSize, resolvedType);
    } else {
      this.memBlobIndex.set(this.memIndexKey(normalizedID, slot), {
        blobKey: key,
        contentType: resolvedType,
        sizeBytes: cleanSize,
        updatedAt: Date.now() / 1000,
      });
    }
  }

  invalidateBlobKey(assetID: UUID, slot: BlobIndexSlot): void {
    const normalizedID = toSwiftUUID(assetID);
    if (this.db) {
      this.db.deleteBlobIndexEntry(normalizedID, slot);
    } else {
      this.memBlobIndex.delete(this.memIndexKey(normalizedID, slot));
    }
  }

  private async deleteKeys(keys: readonly string[]): Promise<void> {
    if (keys.length === 0) return;
    if (typeof this.blobs.deleteMany === 'function') {
      await this.blobs.deleteMany(keys).catch(() => undefined);
      return;
    }
    await Promise.all(keys.map((k) => this.blobs.delete(k).catch(() => undefined)));
  }

  private async getBlobConditionalStream(
    key: string,
    options?: BlobConditionalGetOptions,
  ): Promise<BlobConditionalStreamResult | null> {
    if (typeof this.blobs.getConditionalStream === 'function') {
      return this.blobs.getConditionalStream(key, options);
    }

    // Fallback for lightweight IBlobStore implementations (e.g., MemoryBlobStore in unit tests)
    const range = options?.range;
    const ifNoneMatch = options?.ifNoneMatch?.trim() || undefined;

    if (range && 'suffix' in range && range.suffix !== undefined) {
      const head = await this.blobs.head(key);
      if (!head) return null;
      const total = head.size;
      const suffix = Math.trunc(range.suffix);
      if (total === 0 || !Number.isFinite(suffix) || suffix <= 0) {
        return {
          status: 'range_not_satisfiable',
          total,
          etag: head.etag,
          contentType: head.contentType,
          lastModifiedMs: head.lastModifiedMs,
        };
      }
      const len = Math.min(total, suffix);
      const start = total - len;
      const res = await this.blobs.getStream(key, { offset: start, length: len });
      if (!res) return null;
      return { status: 'ok', ...res };
    }

    const res = await this.blobs.getStream(key, range);
    if (!res) {
      if (range) {
        const head = await this.blobs.head(key);
        if (head) {
          return {
            status: 'range_not_satisfiable',
            total: head.size,
            etag: head.etag,
            contentType: head.contentType,
            lastModifiedMs: head.lastModifiedMs,
          };
        }
      }
      return null;
    }

    if (
      range &&
      res.range &&
      (res.range.total === 0 ||
        res.range.start >= res.range.total ||
        res.range.start > res.range.end)
    ) {
      await res.stream.cancel().catch(() => undefined);
      return {
        status: 'range_not_satisfiable',
        total: res.range.total,
        etag: res.etag,
        contentType: res.contentType,
        lastModifiedMs: res.lastModifiedMs,
      };
    }

    const etag = res.etag ?? `"${res.size}-${Math.trunc(res.lastModifiedMs ?? 0)}"`;
    if (ifNoneMatch && ifNoneMatchMatchesHeader(ifNoneMatch, etag)) {
      await res.stream.cancel().catch(() => undefined);
      return {
        status: 'not_modified',
        etag,
        contentType: res.contentType,
        lastModifiedMs: res.lastModifiedMs,
        size: res.range?.total ?? res.size,
      };
    }

    return {
      status: 'ok',
      ...res,
      etag,
    };
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

  resolveThumbnailKeyHint(
    id: UUID,
    tier: ThumbnailTier = 'grid520',
  ): { key: string; contentType: string | null; fallbackKeys: string[] } {
    const indexed = this.getIndexedBlob(id, tier);
    if (indexed) {
      const fallbacks: string[] = [];
      if (tier === 'preview1400') {
        const gridIndexed = this.getIndexedBlob(id, 'grid520');
        if (gridIndexed) {
          fallbacks.push(gridIndexed.blobKey);
        }
      }
      return {
        key: indexed.blobKey,
        contentType: indexed.contentType || guessMimeType(indexed.blobKey),
        fallbackKeys: fallbacks,
      };
    }

    if (tier === 'preview1400') {
      const gridIndexed = this.getIndexedBlob(id, 'grid520');
      if (gridIndexed && this.isIndexHydrated()) {
        return {
          key: gridIndexed.blobKey,
          contentType: gridIndexed.contentType || guessMimeType(gridIndexed.blobKey),
          fallbackKeys: [],
        };
      }
    }

    const candidates: string[] = [];
    for (const cand of THUMB_EXT_CANDIDATES) {
      candidates.push(this.thumbnailKey(id, tier, cand.ext));
    }
    if (tier === 'preview1400') {
      const gridIndexed = this.getIndexedBlob(id, 'grid520');
      if (gridIndexed) {
        candidates.push(gridIndexed.blobKey);
      } else {
        for (const cand of THUMB_EXT_CANDIDATES) {
          candidates.push(this.thumbnailKey(id, 'grid520', cand.ext));
        }
      }
    }
    return {
      key: candidates[0],
      contentType: guessMimeType(candidates[0]),
      fallbackKeys: candidates.slice(1),
    };
  }

  resolveOriginalKeyHint(asset: AssetRecord): { key: string; indexed: boolean } {
    const indexed = this.getIndexedBlob(asset.id, 'original');
    if (indexed) {
      return { key: indexed.blobKey, indexed: true };
    }
    return { key: this.originalBlobKey(asset), indexed: false };
  }

  thumbnailTargetPath(id: UUID, tier: ThumbnailTier = 'grid520'): string {
    const key = this.thumbnailKey(id, tier, 'jpg');
    return this.blobs.targetFilePath ? this.blobs.targetFilePath(key) : key;
  }

  getThumbnailPath(id: UUID, tier: ThumbnailTier = 'grid520'): string | null {
    if (!this.blobs.localFilePath) return null;
    const indexed = this.getIndexedBlob(id, tier);
    if (indexed) {
      const hit = this.blobs.localFilePath(indexed.blobKey);
      if (hit) return hit;
    }
    for (const cand of THUMB_EXT_CANDIDATES) {
      const hit = this.blobs.localFilePath(this.thumbnailKey(id, tier, cand.ext));
      if (hit) return hit;
    }
    if (tier === 'preview1400') {
      const gridIndexed = this.getIndexedBlob(id, 'grid520');
      if (gridIndexed) {
        const hit = this.blobs.localFilePath(gridIndexed.blobKey);
        if (hit) return hit;
      }
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
    const indexed = this.getIndexedBlob(asset.id, 'original');
    if (indexed) {
      const hit = this.blobs.localFilePath(indexed.blobKey);
      if (hit) return hit;
    }
    return this.blobs.localFilePath(this.originalBlobKey(asset));
  }

  cachedOriginalPath(asset: AssetRecord): string | null {
    return this.getOriginalPath(asset);
  }

  async findOriginalBlobKey(asset: AssetRecord): Promise<string | null> {
    const indexed = this.getIndexedBlob(asset.id, 'original');
    if (indexed) {
      const info = await this.blobs.head(indexed.blobKey);
      if (info) return indexed.blobKey;
      this.invalidateBlobKey(asset.id, 'original');
    }

    const direct = this.originalBlobKey(asset);
    if (!indexed || indexed.blobKey !== direct) {
      const directInfo = await this.blobs.head(direct);
      if (directInfo) {
        this.recordBlobKey(asset.id, 'original', direct, directInfo.size, directInfo.contentType);
        return direct;
      }
    }

    // When blob_index is hydrated, avoid expensive Class A `list()` fallback on missing originals
    if (this.isIndexHydrated()) {
      return null;
    }

    const prefix = `originals/${toSwiftUUID(asset.id)}`;
    const listed = await this.blobs.list(prefix);
    const found = listed.find((item) => item.key === prefix || item.key.startsWith(`${prefix}.`));
    if (found) {
      this.recordBlobKey(asset.id, 'original', found.key, found.size);
      return found.key;
    }
    return null;
  }

  async findThumbnailBlobKey(
    id: UUID,
    tier: ThumbnailTier = 'grid520',
  ): Promise<{ key: string; contentType: string } | null> {
    const indexed = this.getIndexedBlob(id, tier);
    if (indexed) {
      const info = await this.blobs.head(indexed.blobKey);
      if (info) {
        return {
          key: indexed.blobKey,
          contentType: info.contentType || indexed.contentType || guessMimeType(indexed.blobKey),
        };
      }
      this.invalidateBlobKey(id, tier);
    }

    if (tier === 'preview1400' && this.isIndexHydrated()) {
      const gridIndexed = this.getIndexedBlob(id, 'grid520');
      if (gridIndexed) {
        const info = await this.blobs.head(gridIndexed.blobKey);
        if (info) {
          return {
            key: gridIndexed.blobKey,
            contentType: info.contentType || gridIndexed.contentType || guessMimeType(gridIndexed.blobKey),
          };
        }
        this.invalidateBlobKey(id, 'grid520');
      }
      return null;
    }

    for (const cand of THUMB_EXT_CANDIDATES) {
      const key = this.thumbnailKey(id, tier, cand.ext);
      const info = await this.blobs.head(key);
      if (info) {
        const contentType = info.contentType || cand.mime;
        this.recordBlobKey(id, tier, key, info.size, contentType);
        return { key, contentType };
      }
    }
    if (tier === 'preview1400') {
      const gridIndexed = this.getIndexedBlob(id, 'grid520');
      if (gridIndexed) {
        const info = await this.blobs.head(gridIndexed.blobKey);
        if (info) {
          return {
            key: gridIndexed.blobKey,
            contentType: info.contentType || gridIndexed.contentType || guessMimeType(gridIndexed.blobKey),
          };
        }
        this.invalidateBlobKey(id, 'grid520');
      }
      for (const cand of THUMB_EXT_CANDIDATES) {
        const key = this.thumbnailKey(id, 'grid520', cand.ext);
        const info = await this.blobs.head(key);
        if (info) {
          const contentType = info.contentType || cand.mime;
          this.recordBlobKey(id, 'grid520', key, info.size, contentType);
          return { key, contentType };
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
    const indexed = this.getIndexedBlob(id, tier);
    if (indexed) {
      const info = await this.blobs.head(indexed.blobKey);
      if (info) {
        return {
          ...info,
          key: indexed.blobKey,
          contentType: info.contentType || indexed.contentType || guessMimeType(indexed.blobKey),
        };
      }
      this.invalidateBlobKey(id, tier);
    }

    if (tier === 'preview1400' && this.isIndexHydrated()) {
      const gridIndexed = this.getIndexedBlob(id, 'grid520');
      if (gridIndexed) {
        const info = await this.blobs.head(gridIndexed.blobKey);
        if (info) {
          return {
            ...info,
            key: gridIndexed.blobKey,
            contentType: info.contentType || gridIndexed.contentType || guessMimeType(gridIndexed.blobKey),
          };
        }
        this.invalidateBlobKey(id, 'grid520');
      }
      return null;
    }

    for (const cand of THUMB_EXT_CANDIDATES) {
      const key = this.thumbnailKey(id, tier, cand.ext);
      const info = await this.blobs.head(key);
      if (info) {
        const contentType = info.contentType || cand.mime;
        this.recordBlobKey(id, tier, key, info.size, contentType);
        return { ...info, key, contentType };
      }
    }
    if (tier === 'preview1400') {
      for (const cand of THUMB_EXT_CANDIDATES) {
        const key = this.thumbnailKey(id, 'grid520', cand.ext);
        const info = await this.blobs.head(key);
        if (info) {
          const contentType = info.contentType || cand.mime;
          this.recordBlobKey(id, 'grid520', key, info.size, contentType);
          return { ...info, key, contentType };
        }
      }
    }
    return null;
  }

  async getThumbnailConditionalStream(
    id: UUID,
    tier: ThumbnailTier = 'grid520',
    ifNoneMatch?: string,
  ): Promise<(BlobConditionalStreamResult & { key: string; contentType: string }) | null> {
    const tryReadKey = async (
      key: string,
      slot: ThumbnailTier,
      fallbackMime: string,
      recordOnHit: boolean,
    ): Promise<(BlobConditionalStreamResult & { key: string; contentType: string }) | null> => {
      const res = await this.getBlobConditionalStream(key, { ifNoneMatch });
      if (!res) return null;
      const contentType = res.contentType || fallbackMime;
      if (recordOnHit && res.status !== 'range_not_satisfiable') {
        const totalSize = res.status === 'ok' ? (res.range?.total ?? res.size) : res.size;
        this.recordBlobKey(id, slot, key, totalSize, contentType);
      }
      return { ...res, key, contentType };
    };

    // Fast path: 1 single R2 `get` directly from indexed key
    const indexed = this.getIndexedBlob(id, tier);
    if (indexed) {
      const hit = await tryReadKey(
        indexed.blobKey,
        tier,
        indexed.contentType || guessMimeType(indexed.blobKey),
        false,
      );
      if (hit) return hit;
      this.invalidateBlobKey(id, tier);
    }

    // Hydrated preview1400 miss -> jump straight to indexed grid520 in 1 single R2 `get`
    if (tier === 'preview1400' && this.isIndexHydrated()) {
      const gridIndexed = this.getIndexedBlob(id, 'grid520');
      if (gridIndexed) {
        const hit = await tryReadKey(
          gridIndexed.blobKey,
          'grid520',
          gridIndexed.contentType || guessMimeType(gridIndexed.blobKey),
          false,
        );
        if (hit) return hit;
        this.invalidateBlobKey(id, 'grid520');
      }
      return null;
    }

    // Unindexed probe: direct `get` without prior `head` so common `.jpg` still resolves in 1 call
    for (const cand of THUMB_EXT_CANDIDATES) {
      const key = this.thumbnailKey(id, tier, cand.ext);
      if (indexed && key === indexed.blobKey) continue;
      const hit = await tryReadKey(key, tier, cand.mime, true);
      if (hit) return hit;
    }

    if (tier === 'preview1400') {
      const gridIndexed = this.getIndexedBlob(id, 'grid520');
      if (gridIndexed) {
        const hit = await tryReadKey(
          gridIndexed.blobKey,
          'grid520',
          gridIndexed.contentType || guessMimeType(gridIndexed.blobKey),
          false,
        );
        if (hit) return hit;
        this.invalidateBlobKey(id, 'grid520');
      }
      for (const cand of THUMB_EXT_CANDIDATES) {
        const key = this.thumbnailKey(id, 'grid520', cand.ext);
        if (gridIndexed && key === gridIndexed.blobKey) continue;
        const hit = await tryReadKey(key, 'grid520', cand.mime, true);
        if (hit) return hit;
      }
    }

    return null;
  }

  async getThumbnailStream(
    id: UUID,
    tier: ThumbnailTier = 'grid520',
  ): Promise<(BlobStreamResult & { key: string; contentType: string }) | null> {
    const res = await this.getThumbnailConditionalStream(id, tier);
    if (!res || res.status !== 'ok') return null;
    const { status: _status, ...streamRes } = res;
    return streamRes;
  }

  async getOriginalHead(asset: AssetRecord): Promise<(BlobHeadResult & { key: string }) | null> {
    const indexed = this.getIndexedBlob(asset.id, 'original');
    if (indexed) {
      const info = await this.blobs.head(indexed.blobKey);
      if (info) return { ...info, key: indexed.blobKey };
      this.invalidateBlobKey(asset.id, 'original');
    }
    const direct = this.originalBlobKey(asset);
    if (!indexed || indexed.blobKey !== direct) {
      const info = await this.blobs.head(direct);
      if (info) {
        this.recordBlobKey(asset.id, 'original', direct, info.size, info.contentType);
        return { ...info, key: direct };
      }
    }
    if (this.isIndexHydrated()) return null;
    const prefix = `originals/${toSwiftUUID(asset.id)}`;
    const listed = await this.blobs.list(prefix);
    const found = listed.find((item) => item.key === prefix || item.key.startsWith(`${prefix}.`));
    if (!found) return null;
    const info = await this.blobs.head(found.key);
    if (!info) return null;
    this.recordBlobKey(asset.id, 'original', found.key, info.size, info.contentType);
    return { ...info, key: found.key };
  }

  async getOriginalConditionalStream(
    asset: AssetRecord,
    options?: BlobConditionalGetOptions,
  ): Promise<(BlobConditionalStreamResult & { key: string }) | null> {
    const indexed = this.getIndexedBlob(asset.id, 'original');
    const primaryKey = indexed?.blobKey ?? this.originalBlobKey(asset);
    const primaryRes = await this.getBlobConditionalStream(primaryKey, options);
    if (primaryRes) {
      if (!indexed) {
        const totalSize =
          primaryRes.status === 'ok'
            ? (primaryRes.range?.total ?? primaryRes.size)
            : primaryRes.status === 'not_modified'
              ? primaryRes.size
              : primaryRes.total;
        this.recordBlobKey(
          asset.id,
          'original',
          primaryKey,
          totalSize,
          primaryRes.contentType ?? asset.mimeType,
        );
      }
      return { ...primaryRes, key: primaryKey };
    }

    if (indexed) {
      this.invalidateBlobKey(asset.id, 'original');
      const directKey = this.originalBlobKey(asset);
      if (directKey !== indexed.blobKey) {
        const directRes = await this.getBlobConditionalStream(directKey, options);
        if (directRes) {
          const totalSize =
            directRes.status === 'ok'
              ? (directRes.range?.total ?? directRes.size)
              : directRes.status === 'not_modified'
                ? directRes.size
                : directRes.total;
          this.recordBlobKey(
            asset.id,
            'original',
            directKey,
            totalSize,
            directRes.contentType ?? asset.mimeType,
          );
          return { ...directRes, key: directKey };
        }
      }
    }

    if (this.isIndexHydrated()) {
      return null;
    }

    const prefix = `originals/${toSwiftUUID(asset.id)}`;
    const listed = await this.blobs.list(prefix);
    const found = listed.find((item) => item.key === prefix || item.key.startsWith(`${prefix}.`));
    if (!found || found.key === primaryKey) return null;
    const fallbackRes = await this.getBlobConditionalStream(found.key, options);
    if (!fallbackRes) return null;
    this.recordBlobKey(
      asset.id,
      'original',
      found.key,
      found.size,
      fallbackRes.contentType ?? asset.mimeType,
    );
    return { ...fallbackRes, key: found.key };
  }

  async getOriginalStream(
    asset: AssetRecord,
    range?: BlobRangeRequest,
  ): Promise<BlobStreamResult | null> {
    const res = await this.getOriginalConditionalStream(asset, range ? { range } : undefined);
    if (!res || res.status !== 'ok') return null;
    const { status: _status, key: _key, ...streamRes } = res;
    return streamRes;
  }

  async readThumbnailBuffer(id: UUID, tier: ThumbnailTier = 'grid520'): Promise<Buffer | null> {
    const res = await this.getThumbnailConditionalStream(id, tier);
    if (!res || res.status !== 'ok') return null;
    const reader = res.stream.getReader();
    const chunks: Uint8Array[] = [];
    let total = 0;
    try {
      for (;;) {
        const { done, value } = await reader.read();
        if (done) break;
        if (value && value.byteLength > 0) {
          chunks.push(value);
          total += value.byteLength;
        }
      }
    } finally {
      reader.releaseLock();
    }
    const merged = new Uint8Array(total);
    let offset = 0;
    for (const chunk of chunks) {
      merged.set(chunk, offset);
      offset += chunk.byteLength;
    }
    return toBuffer(merged);
  }

  async readOriginalBuffer(asset: AssetRecord): Promise<Buffer | null> {
    const hint = this.resolveOriginalKeyHint(asset);
    const direct = await this.blobs.getBytes(hint.key);
    if (direct) {
      if (!hint.indexed) {
        this.recordBlobKey(asset.id, 'original', hint.key, direct.byteLength, asset.mimeType);
      }
      return toBuffer(direct);
    }
    if (hint.indexed) {
      this.invalidateBlobKey(asset.id, 'original');
    }
    const key = await this.findOriginalBlobKey(asset);
    if (!key || key === hint.key) return null;
    const bytes = await this.blobs.getBytes(key);
    return bytes ? toBuffer(bytes) : null;
  }

  async installOriginal(
    source: Uint8Array | ReadableStream<Uint8Array> | string,
    asset: AssetRecord,
    _moveSource = false,
    knownSize?: number,
  ): Promise<string> {
    const destKey = this.originalBlobKey(asset);
    const previousKey = this.getIndexedBlob(asset.id, 'original')?.blobKey ?? null;

    let payload: Uint8Array | ReadableStream<Uint8Array>;
    if (typeof source === 'string') {
      if (!this.readLocalFile) {
        throw new Error('当前运行环境不支持从本地文件路径安装原始文件。');
      }
      payload = await this.readLocalFile(source);
    } else {
      payload = source;
    }

    const contentType = asset.mimeType || 'application/octet-stream';
    const resolvedSize =
      payload instanceof Uint8Array
        ? payload.byteLength
        : typeof knownSize === 'number' && Number.isFinite(knownSize) && knownSize >= 0
          ? Math.trunc(knownSize)
          : undefined;

    const putRes = await this.blobs.put(destKey, payload, {
      contentType,
      size: resolvedSize,
    });
    this.recordBlobKey(asset.id, 'original', destKey, putRes.size, contentType);

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
    const prev = this.getIndexedBlob(id, tier);

    await this.blobs.put(targetKey, bytes, {
      contentType: resolvedMime,
      size: bytes.byteLength,
    });
    this.recordBlobKey(id, tier, targetKey, bytes.byteLength, resolvedMime);

    if (prev && prev.blobKey !== targetKey) {
      await this.blobs.delete(prev.blobKey).catch(() => undefined);
    } else if (!prev && !this.isIndexHydrated()) {
      // Only sweep legacy unindexed extensions in one batched delete call
      const staleKeys = THUMB_EXT_CANDIDATES.filter((cand) => cand.ext !== ext).map((cand) =>
        this.thumbnailKey(id, tier, cand.ext),
      );
      await this.deleteKeys(staleKeys);
    }

    return this.blobs.localFilePath?.(targetKey) ?? targetKey;
  }

  private async clearThumbnailTier(id: UUID, tier: ThumbnailTier): Promise<void> {
    const prev = this.getIndexedBlob(id, tier);
    if (prev) {
      this.invalidateBlobKey(id, tier);
      await this.blobs.delete(prev.blobKey).catch(() => undefined);
      return;
    }
    if (this.isIndexHydrated()) {
      return;
    }
    const keys = THUMB_EXT_CANDIDATES.map((cand) => this.thumbnailKey(id, tier, cand.ext));
    await this.deleteKeys(keys);
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
        const info = await this.images.inspectDimensions(buffer).catch(() => null);
        const sniffedMime = sniffImageMimeType(buffer, 'image/png');
        const actualExt =
          info?.format === 'jpeg'
            ? 'jpg'
            : info?.format
              ? info.format.toLowerCase()
              : extForImageMime(sniffedMime);
        const rawExt = posixExtname(input.suggestedName).replace(/^\./, '').toLowerCase();
        const canonicalRawExt = rawExt === 'jpeg' ? 'jpg' : rawExt;
        const ext =
          actualExt && (!canonicalRawExt || (canonicalRawExt !== actualExt && ['jpg', 'png', 'webp', 'gif', 'avif', 'svg'].includes(actualExt)))
            ? actualExt
            : rawExt || 'png';
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
        const {
          metadata,
          title,
          markdownArchive,
          coverImageBuffer,
          primaryVideoBuffer,
          authorAvatarBytes,
        } = resolved;
        const platformTag = socialPlatformDisplayName(metadata.platform);
        const originalBuf: Uint8Array = primaryVideoBuffer ?? utf8Encode(markdownArchive);
        const fileExt = primaryVideoBuffer ? 'mp4' : 'md';
        const fileName = `${sanitizeFileName(metadata.authorHandle + '-' + assetID.slice(0, 8))}.${fileExt}`;

        const card = await this.images.renderArtworkCard({
          kind: 'socialPost',
          post: metadata,
          coverImageBytes: coverImageBuffer ?? null,
          authorAvatarBytes: authorAvatarBytes ?? null,
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
        let dims: { width: number; height: number } | null = null;
        let analysis: { colors: LabColor[]; featurePrint?: Float32Array } = {
          colors: [],
          featurePrint: undefined,
        };

        const ogCard = await fetchGitHubOpenGraphCardBytes(repo).catch(() => null);
        if (ogCard) {
          try {
            dims = await this.generateThumbnailsFromBuffer(assetID, ogCard.bytes, ogCard.mimeType);
            analysis = await this.images
              .extractColorsAndFingerprint(ogCard.bytes, ogCard.mimeType, { count: 5 })
              .catch(() => ({ colors: [] as LabColor[], featurePrint: undefined }));
          } catch {
            dims = null;
          }
        }
        if (!dims) {
          const card = await this.images.renderArtworkCard({ kind: 'githubRepo', repo });
          dims = await this.storeRenderedCard(assetID, card);
          analysis = await this.images
            .extractColorsAndFingerprint(card.fullImage, card.mimeType, { count: 5 })
            .catch(() => ({ colors: [] as LabColor[], featurePrint: undefined }));
        }
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
        const extractedImgMeta = await extractImageMetadata(buffer, resolvedMime).catch(() => ({
          photoExif: null,
          aiGeneration: null,
        }));
        if (extractedImgMeta.photoExif || extractedImgMeta.aiGeneration) {
          asset.richMetadata = {
            ...(asset.richMetadata ?? { isMarkdown: false }),
            photoExif: extractedImgMeta.photoExif ?? asset.richMetadata?.photoExif ?? null,
            aiGeneration: extractedImgMeta.aiGeneration ?? asset.richMetadata?.aiGeneration ?? null,
          };
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
        const extractedDesignMeta = await extractImageMetadata(buffer, resolvedMime).catch(() => ({
          photoExif: null,
          aiGeneration: null,
        }));
        if (extractedDesignMeta.photoExif || extractedDesignMeta.aiGeneration) {
          asset.richMetadata = {
            ...(asset.richMetadata ?? { isMarkdown: false }),
            photoExif: extractedDesignMeta.photoExif ?? asset.richMetadata?.photoExif ?? null,
            aiGeneration: extractedDesignMeta.aiGeneration ?? asset.richMetadata?.aiGeneration ?? null,
          };
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
        const extractedURL = extractWebBookmarkURL(buffer);
        if (extractedURL && isWebURL(extractedURL)) {
          return this.ingestWebURL(extractedURL, null, '', folderID, assetID);
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

  /**
   * Finalizes an already-uploaded original blob (e.g. from R2/Node Multipart Upload) into a full
   * `AssetRecord` WITHOUT loading the multi-hundred-MB original payload into Worker/Server memory.
   */
  async finalizePrestoredOriginal(opts: {
    assetID: UUID;
    blobKey: string;
    fileName: string;
    mimeType: string | null;
    fileSizeBytes: number;
    folderID?: UUID | null;
    contentHash?: string | null;
    preprocessed?: ClientPreprocessedMedia | null;
  }): Promise<MediaIngestResult> {
    const assetID = toSwiftUUID(opts.assetID);
    const fileName = sanitizeFileName(opts.fileName);
    const ext = posixExtname(fileName).replace(/^\./, '').toLowerCase();
    const resolvedMime =
      opts.mimeType && opts.mimeType !== 'application/octet-stream'
        ? opts.mimeType
        : guessMimeType(fileName);
    const mediaKind: MediaKind = detectMediaKind(ext, resolvedMime);
    const now = new Date().toISOString();
    const title = posixStripExt(fileName) || fileName;
    const rawHash = (opts.contentHash ?? '').trim().toLowerCase();
    const validHash = /^[0-9a-f]{64}$/.test(rawHash) ? rawHash : '';

    const asset = createDefaultAssetRecord({
      id: assetID,
      title,
      fileName,
      folderID: opts.folderID ? toSwiftUUID(opts.folderID) : null,
      contentHash: validHash,
      mediaKind,
      mimeType: resolvedMime,
      fileSizeBytes: Math.max(0, Math.trunc(opts.fileSizeBytes)),
      isLocalOriginalCached: true,
      createdAt: now,
      updatedAt: now,
    });

    const preprocessed = opts.preprocessed ?? null;
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
          // Fall back to lightweight artwork badge below
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

    if (mediaKind === 'audio') {
      asset.dominantColors = [];
      asset.ocrText = null;
    } else if (mediaKind === 'model3D') {
      asset.richMetadata = {
        githubRepo: null,
        socialPost: null,
        textExcerpt: null,
        isMarkdown: false,
        model3DFormat: (ext || '3D').toUpperCase(),
      };
      asset.ocrText = null;
    }

    if (!hasClientThumb520) {
      const renderedCard =
        mediaKind === 'audio'
          ? await this.images.renderArtworkCard({
              kind: 'audioWaveform',
              title,
              peaks: asset.waveformPeaks,
              durationSeconds: asset.durationSeconds ?? null,
            })
          : mediaKind === 'model3D'
            ? await this.images.renderArtworkCard({
                kind: 'model3D',
                title,
                format: (ext || '3D').toUpperCase(),
              })
            : await this.images.renderArtworkCard({
                kind: 'genericBadge',
                title,
                ext: ext || mediaKind.toUpperCase(),
                kindLabel: mediaKindLocalizedLabel(mediaKind),
              });

      const dims = await this.storeRenderedCard(assetID, renderedCard);
      if (!hasClientDims) {
        asset.pixelWidth = dims.width;
        asset.pixelHeight = dims.height;
      }
    }

    this.recordBlobKey(assetID, 'original', opts.blobKey, asset.fileSizeBytes, resolvedMime);
    const originalPath = this.blobs.localFilePath?.(opts.blobKey) ?? opts.blobKey;
    return { asset, originalPath, vector };
  }

  // MARK: - Rich Asset Refresh, Lazy Image Metadata Hydration & Social Post Standalone Media Extraction

  /**
   * Lazily extracts camera EXIF and embedded AI generation prompt metadata from the cached original blob.
   * Returns an updated `AssetRecord` if new metadata was discovered, or `null` when unchanged/not applicable.
   */
  async hydrateImageMetadata(asset: AssetRecord): Promise<AssetRecord | null> {
    if (
      asset.mediaKind !== 'image' &&
      asset.mediaKind !== 'animatedImage' &&
      asset.mediaKind !== 'designFile'
    ) {
      return null;
    }
    if (asset.richMetadata?.photoExif != null || asset.richMetadata?.aiGeneration != null) {
      return null;
    }
    const origKey = await this.findOriginalBlobKey(asset);
    if (!origKey) return null;
    const bytes = await this.blobs.getBytes(origKey);
    if (!bytes || bytes.byteLength < 8) return null;

    const extracted = await extractImageMetadata(bytes, asset.mimeType).catch(() => ({
      photoExif: null,
      aiGeneration: null,
    }));
    if (!extracted.photoExif && !extracted.aiGeneration) {
      return null;
    }

    return {
      ...asset,
      richMetadata: {
        ...(asset.richMetadata ?? { isMarkdown: false }),
        photoExif: extracted.photoExif ?? asset.richMetadata?.photoExif ?? null,
        aiGeneration: extracted.aiGeneration ?? asset.richMetadata?.aiGeneration ?? null,
      },
    };
  }

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
    const keysToDelete: string[] = [];
    const normalizedID = toSwiftUUID(asset.id);
    if (this.db) {
      const entries = this.db.getBlobIndexEntriesForAsset(normalizedID);
      for (const e of entries) keysToDelete.push(e.blobKey);
      this.db.deleteBlobIndexForAssets([normalizedID]);
    }
    if (keysToDelete.length === 0) {
      const origKey = await this.findOriginalBlobKey(asset);
      if (origKey) keysToDelete.push(origKey);
      if (!this.isIndexHydrated()) {
        for (const cand of THUMB_EXT_CANDIDATES) {
          keysToDelete.push(this.thumbnailKey(normalizedID, 'grid520', cand.ext));
          keysToDelete.push(this.thumbnailKey(normalizedID, 'preview1400', cand.ext));
        }
      }
    } else if (!keysToDelete.some((k) => k.startsWith('originals/'))) {
      // Ensure deterministic original key is removed even if only thumbnails were indexed
      const direct = this.originalBlobKey(asset);
      keysToDelete.push(direct);
    }
    this.memBlobIndex.delete(this.memIndexKey(normalizedID, 'original'));
    this.memBlobIndex.delete(this.memIndexKey(normalizedID, 'grid520'));
    this.memBlobIndex.delete(this.memIndexKey(normalizedID, 'preview1400'));
    await this.deleteKeys(keysToDelete);
  }

  async removeFilesByIDs(ids: Iterable<UUID>): Promise<void> {
    const idSet = new Set(Array.from(ids, toSwiftUUID));
    if (idSet.size === 0) return;

    const keysToDelete: string[] = [];
    const unindexedIDs = new Set<UUID>();

    for (const id of idSet) {
      if (this.db) {
        const entries = this.db.getBlobIndexEntriesForAsset(id);
        if (entries.length > 0) {
          for (const e of entries) keysToDelete.push(e.blobKey);
        } else if (!this.isIndexHydrated()) {
          unindexedIDs.add(id);
        }
      } else {
        const orig = this.memBlobIndex.get(this.memIndexKey(id, 'original'));
        const g520 = this.memBlobIndex.get(this.memIndexKey(id, 'grid520'));
        const p1400 = this.memBlobIndex.get(this.memIndexKey(id, 'preview1400'));
        if (orig) keysToDelete.push(orig.blobKey);
        if (g520) keysToDelete.push(g520.blobKey);
        if (p1400) keysToDelete.push(p1400.blobKey);
        if (!orig) unindexedIDs.add(id);
      }
      this.memBlobIndex.delete(this.memIndexKey(id, 'original'));
      this.memBlobIndex.delete(this.memIndexKey(id, 'grid520'));
      this.memBlobIndex.delete(this.memIndexKey(id, 'preview1400'));
    }

    // Only scan `originals/` for legacy pre-v4 unindexed assets (ZERO Class A list calls when hydrated!)
    if (unindexedIDs.size > 0) {
      const allOriginals = await this.blobs.list('originals/').catch(() => []);
      for (const item of allOriginals) {
        const name = posixBasename(item.key);
        const stem = posixStripExt(name).toUpperCase();
        if (unindexedIDs.has(stem)) {
          keysToDelete.push(item.key);
        }
      }
      for (const id of unindexedIDs) {
        for (const cand of THUMB_EXT_CANDIDATES) {
          keysToDelete.push(this.thumbnailKey(id, 'grid520', cand.ext));
          keysToDelete.push(this.thumbnailKey(id, 'preview1400', cand.ext));
        }
      }
    }

    if (this.db) {
      this.db.deleteBlobIndexForAssets(idSet);
    }
    await this.deleteKeys(keysToDelete);
  }

  getCacheBudgetBytes(): number {
    return this.cacheBudgetBytes;
  }

  setCacheBudgetBytes(bytes: number): void {
    this.cacheBudgetBytes = Math.max(0, Math.round(bytes));
  }

  async cleanupDeletedMedia(db: LibraryDatabase): Promise<void> {
    const cleanups = db.getStatesWithPrefix<boolean>('media.cleanup.');
    if (cleanups.length === 0) return;
    const ids = cleanups.map((item) => item.key.slice('media.cleanup.'.length));
    await this.removeFilesByIDs(ids);
    for (const item of cleanups) {
      db.setState(item.key, null);
    }
  }

  private async ensureBlobIndexHydrated(db: LibraryDatabase): Promise<boolean> {
    if (this.db !== db) return false;
    if (db.isBlobIndexHydrated()) return true;

    const [thumbs520, thumbs1400, originals] = await Promise.all([
      this.blobs.list('thumbnails/520/').catch(() => []),
      this.blobs.list('thumbnails/1400/').catch(() => []),
      this.blobs.list('originals/').catch(() => []),
    ]);

    db.transaction(() => {
      for (const item of thumbs520) {
        const id = posixStripExt(posixBasename(item.key)).toUpperCase();
        if (id) {
          db.setBlobIndexEntry(
            id,
            'grid520',
            item.key,
            item.size,
            guessMimeType(item.key),
            item.lastModifiedMs ?? Date.now(),
          );
        }
      }
      for (const item of thumbs1400) {
        const id = posixStripExt(posixBasename(item.key)).toUpperCase();
        if (id) {
          db.setBlobIndexEntry(
            id,
            'preview1400',
            item.key,
            item.size,
            guessMimeType(item.key),
            item.lastModifiedMs ?? Date.now(),
          );
        }
      }
      for (const item of originals) {
        const id = posixStripExt(posixBasename(item.key)).toUpperCase();
        if (id) {
          db.setBlobIndexEntry(
            id,
            'original',
            item.key,
            item.size,
            guessMimeType(item.key),
            item.lastModifiedMs ?? Date.now(),
          );
        }
      }
      db.setBlobIndexHydrated(true);
    });
    return true;
  }

  private computeStatsFromBlobIndex(db: LibraryDatabase): CacheStats {
    const totals = db.getBlobIndexSlotTotals();
    const originals = db.listBlobIndexBySlot('original');
    const protectedIDs = db.protectedAssetIDs();
    let pinnedOfflineBytes = 0;
    let pinnedCount = 0;
    for (const entry of originals) {
      if (protectedIDs.has(entry.assetID)) {
        pinnedOfflineBytes += entry.sizeBytes;
        pinnedCount++;
      }
    }
    return {
      thumbnailBytes: totals.thumbnailBytes,
      originalCacheBytes: totals.originalBytes,
      pinnedOfflineBytes,
      budgetBytes: this.cacheBudgetBytes,
      cachedOriginalCount: totals.originalCount,
      pinnedAssetCount: Math.max(pinnedCount, protectedIDs.size),
    };
  }

  async getCacheStats(db: LibraryDatabase): Promise<CacheStats> {
    if (await this.ensureBlobIndexHydrated(db)) {
      return this.computeStatsFromBlobIndex(db);
    }

    const [thumbs520, thumbs1400, originals] = await Promise.all([
      this.blobs.list('thumbnails/520/').catch(() => []),
      this.blobs.list('thumbnails/1400/').catch(() => []),
      this.blobs.list('originals/').catch(() => []),
    ]);

    const thumbnailBytes =
      thumbs520.reduce((s, e) => s + e.size, 0) + thumbs1400.reduce((s, e) => s + e.size, 0);
    const protectedIDs = db.protectedAssetIDs();
    let totalOriginalBytes = 0;
    let pinnedOfflineBytes = 0;
    let pinnedCount = 0;

    for (const entry of originals) {
      totalOriginalBytes += entry.size;
      const id = posixStripExt(posixBasename(entry.key)).toUpperCase();
      if (protectedIDs.has(id)) {
        pinnedOfflineBytes += entry.size;
        pinnedCount++;
      }
    }

    return {
      thumbnailBytes,
      // Report total cached original bytes (matching macOS MediaPipeline+Cache.swift)
      originalCacheBytes: totalOriginalBytes,
      pinnedOfflineBytes,
      budgetBytes: this.cacheBudgetBytes,
      cachedOriginalCount: originals.length,
      pinnedAssetCount: Math.max(pinnedCount, protectedIDs.size),
    };
  }

  /**
   * Evicts oldest-accessed unpinned, cloud-backed originals until total original cache fits within `budgetBytes`.
   * Strictly protects:
   * - Assets without a cloud `driveFileID` binding (unbacked local-only originals are NEVER permanently deleted!)
   * - Assets with `pinnedOffline === true` OR referenced by any `pinnedOffline` board
   * - Any asset IDs explicitly passed in `keepingIDs`
   */
  async evictCacheNow(
    db: LibraryDatabase,
    keepingIDs: ReadonlySet<UUID> = new Set(),
    options?: { skipStats?: boolean },
  ): Promise<CacheStats> {
    await this.cleanupDeletedMedia(db);
    const useIndex = await this.ensureBlobIndexHydrated(db);

    if (useIndex) {
      const totals = db.getBlobIndexSlotTotals();
      if (totals.originalBytes > this.cacheBudgetBytes) {
        const protectedIDs = db.protectedAssetIDs();
        const recoverableIDs = new Set(db.getAssetDriveBindings().map((b) => toSwiftUUID(b.assetID)));
        const accessTimes = db.originalAccessTimes();
        const indexedOriginals = db.listBlobIndexBySlot('original');

        let totalOriginalsBytes = totals.originalBytes;
        const evictable = indexedOriginals
          .filter(
            (e) =>
              !protectedIDs.has(e.assetID) &&
              !keepingIDs.has(e.assetID) &&
              recoverableIDs.has(e.assetID),
          )
          .sort((a, b) => {
            const ta = accessTimes.get(a.assetID) ?? a.updatedAt;
            const tb = accessTimes.get(b.assetID) ?? b.updatedAt;
            return ta - tb || a.assetID.localeCompare(b.assetID);
          });

        const toEvict: typeof evictable = [];
        for (const entry of evictable) {
          if (totalOriginalsBytes <= this.cacheBudgetBytes) break;
          toEvict.push(entry);
          totalOriginalsBytes -= entry.sizeBytes;
        }

        if (toEvict.length > 0) {
          await this.deleteKeys(toEvict.map((e) => e.blobKey));
          db.transaction(() => {
            for (const entry of toEvict) {
              db.deleteBlobIndexEntry(entry.assetID, 'original');
              const asset = db.getAsset(entry.assetID);
              if (asset && asset.isLocalOriginalCached) {
                db.putAsset({ ...asset, isLocalOriginalCached: false });
              }
            }
          });
        }
      }

      if (options?.skipStats) {
        return {
          thumbnailBytes: 0,
          originalCacheBytes: totals.originalBytes,
          pinnedOfflineBytes: 0,
          budgetBytes: this.cacheBudgetBytes,
          cachedOriginalCount: totals.originalCount,
          pinnedAssetCount: 0,
        };
      }
      return this.computeStatsFromBlobIndex(db);
    }

    const protectedIDs = db.protectedAssetIDs();
    const recoverableIDs = new Set(db.getAssetDriveBindings().map((b) => toSwiftUUID(b.assetID)));
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
        .filter(
          (e) =>
            !protectedIDs.has(e.id) &&
            !keepingIDs.has(e.id) &&
            recoverableIDs.has(e.id),
        )
        .sort((a, b) => {
          const ta = accessTimes.get(a.id) ?? a.mtimeMs / 1000;
          const tb = accessTimes.get(b.id) ?? b.mtimeMs / 1000;
          return ta - tb || a.id.localeCompare(b.id);
        });

      const keysToDelete: string[] = [];
      const evictedIDs: UUID[] = [];
      for (const entry of evictable) {
        if (totalOriginalsBytes <= this.cacheBudgetBytes) break;
        keysToDelete.push(entry.key);
        evictedIDs.push(entry.id);
        totalOriginalsBytes -= entry.size;
      }
      if (keysToDelete.length > 0) {
        await this.deleteKeys(keysToDelete);
        for (const id of evictedIDs) {
          this.memBlobIndex.delete(this.memIndexKey(id, 'original'));
          const asset = db.getAsset(id);
          if (asset && asset.isLocalOriginalCached) {
            db.putAsset({ ...asset, isLocalOriginalCached: false });
          }
        }
      }
    }

    if (options?.skipStats) {
      return {
        thumbnailBytes: 0,
        originalCacheBytes: totalOriginalsBytes,
        pinnedOfflineBytes: 0,
        budgetBytes: this.cacheBudgetBytes,
        cachedOriginalCount: originals.length,
        pinnedAssetCount: protectedIDs.size,
      };
    }

    return this.getCacheStats(db);
  }
}

function decodeXmlEntities(raw: string): string {
  return raw
    .replace(/&lt;/g, '<')
    .replace(/&gt;/g, '>')
    .replace(/&quot;/g, '"')
    .replace(/&apos;/g, "'")
    .replace(/&#39;/g, "'")
    .replace(/&amp;/g, '&');
}

/**
 * Extracts the bookmark URL from macOS XML `.webloc`, macOS binary `bplist00` `.webloc`,
 * or Windows `.url` INI files — never capturing Apple's PropertyList DTD URL.
 */
export function extractWebBookmarkURL(buffer: Uint8Array): string | null {
  if (buffer.byteLength === 0 || buffer.byteLength > 256_000) return null;

  // 1. Binary plist (`bplist00`)
  if (isBinaryPlist(buffer)) {
    try {
      const parsed = parseBinaryPlist(buffer);
      if (parsed && typeof parsed === 'object' && !Array.isArray(parsed) && !(parsed instanceof Uint8Array)) {
        const dict = parsed as Record<string, unknown>;
        if (typeof dict.URL === 'string' && dict.URL.trim().length > 0) {
          return dict.URL.trim();
        }
        // Fallback case-insensitive key match
        for (const [k, v] of Object.entries(dict)) {
          if (k.toLowerCase() === 'url' && typeof v === 'string' && v.trim().length > 0) {
            return v.trim();
          }
        }
      }
    } catch {
      return null;
    }
    return null;
  }

  const text = utf8Decode(buffer);

  // 2. XML property list: `<key>URL</key><string>...</string>`
  const xmlMatch = /<key>\s*URL\s*<\/key>\s*<string>([\s\S]*?)<\/string>/i.exec(text);
  if (xmlMatch?.[1]) {
    const candidate = decodeXmlEntities(xmlMatch[1]).trim();
    if (candidate.length > 0) return candidate;
  }

  // 3. Windows `.url` INI file (`URL=https://...`)
  for (const line of text.split(/\r?\n/)) {
    const trimmed = line.trim();
    if (/^url\s*=/i.test(trimmed)) {
      const val = trimmed.replace(/^url\s*=\s*/i, '').trim();
      if (val.length > 0) return val;
    }
  }

  // 4. Plain-text fallback ONLY if it's NOT a plist XML document (avoid capturing Apple DTD URL!)
  if (!/<!DOCTYPE\s+plist/i.test(text) && !/<plist\b/i.test(text)) {
    const plainMatch = /https?:\/\/[^\s<>"']+/i.exec(text);
    if (plainMatch?.[0]) return plainMatch[0];
  }

  return null;
}
