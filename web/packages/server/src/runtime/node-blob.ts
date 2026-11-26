import crypto from 'node:crypto';
import fs from 'node:fs';
import fsp from 'node:fs/promises';
import path from 'node:path';
import { Readable } from 'node:stream';
import type {
  BlobConditionalGetOptions,
  BlobConditionalStreamResult,
  BlobHeadResult,
  BlobListItem,
  BlobMultipartHandle,
  BlobRangeRequest,
  BlobStreamResult,
  BlobUploadedPart,
  IBlobStore,
} from './types.js';
import { streamToBytes } from './web-crypto-utils.js';

function ifNoneMatchMatches(headerValue: string | undefined, etag: string | undefined): boolean {
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

function sanitizeBlobKey(rawKey: string): string {
  const trimmed = rawKey.trim().replace(/^\/+/, '');
  if (!trimmed || trimmed.includes('\0') || trimmed.includes('\\')) {
    throw new Error(`Invalid blob key: "${rawKey}"`);
  }
  const segments = trimmed.split('/');
  for (const seg of segments) {
    if (!seg || seg === '.' || seg === '..') {
      throw new Error(`Unsafe blob key segment: "${rawKey}"`);
    }
  }
  return segments.join('/');
}

function guessContentTypeFromKey(key: string): string | undefined {
  const ext = path.extname(key).toLowerCase();
  switch (ext) {
    case '.jpg':
    case '.jpeg':
      return 'image/jpeg';
    case '.png':
      return 'image/png';
    case '.webp':
      return 'image/webp';
    case '.gif':
      return 'image/gif';
    case '.svg':
      return 'image/svg+xml';
    case '.mp4':
      return 'video/mp4';
    case '.webm':
      return 'video/webm';
    case '.wav':
      return 'audio/wav';
    case '.mp3':
      return 'audio/mpeg';
    case '.pdf':
      return 'application/pdf';
    case '.md':
      return 'text/markdown';
    case '.txt':
      return 'text/plain';
    case '.json':
      return 'application/json';
    default:
      return undefined;
  }
}

/**
 * Local filesystem implementation of `IBlobStore` with atomic staging writes,
 * strict path traversal prevention, and true streaming HTTP Range reads.
 * ONLY imported by Node entrypoints (`app.ts`, `mcp-stdio.ts`, Node tests).
 */
export class NodeBlobStore implements IBlobStore {
  public readonly rootDir: string;
  private readonly stagingDir: string;

  constructor(rootDir: string) {
    this.rootDir = path.resolve(rootDir);
    this.stagingDir = path.join(this.rootDir, '.staging');
    fs.mkdirSync(this.rootDir, { recursive: true });
    fs.mkdirSync(this.stagingDir, { recursive: true });
  }

  private resolveSafePath(rawKey: string): { key: string; absPath: string } {
    const key = sanitizeBlobKey(rawKey);
    const absPath = path.resolve(this.rootDir, key);
    if (absPath !== this.rootDir && !absPath.startsWith(this.rootDir + path.sep)) {
      throw new Error(`Blob key escapes root directory: "${rawKey}"`);
    }
    return { key, absPath };
  }

  targetFilePath(key: string): string {
    return this.resolveSafePath(key).absPath;
  }

  localFilePath(key: string): string | null {
    try {
      const { absPath } = this.resolveSafePath(key);
      return fs.existsSync(absPath) ? absPath : null;
    } catch {
      return null;
    }
  }

  async put(
    key: string,
    data: Uint8Array | ReadableStream<Uint8Array>,
    _options?: { contentType?: string },
  ): Promise<{ size: number }> {
    const { absPath } = this.resolveSafePath(key);
    await fsp.mkdir(path.dirname(absPath), { recursive: true });
    await fsp.mkdir(this.stagingDir, { recursive: true });

    const tmpPath = path.join(this.stagingDir, `${crypto.randomUUID()}.tmp`);
    try {
      if (data instanceof Uint8Array) {
        await fsp.writeFile(tmpPath, data);
        await fsp.rename(tmpPath, absPath);
        return { size: data.byteLength };
      }

      // Stream directly to temp file without buffering the entire payload in memory
      let totalBytes = 0;
      const fh = await fsp.open(tmpPath, 'w');
      try {
        const reader = data.getReader();
        try {
          for (;;) {
            const { done, value } = await reader.read();
            if (done) break;
            if (value && value.byteLength > 0) {
              await fh.write(value);
              totalBytes += value.byteLength;
            }
          }
        } finally {
          reader.releaseLock();
        }
      } finally {
        await fh.close();
      }
      await fsp.rename(tmpPath, absPath);
      return { size: totalBytes };
    } catch (err) {
      await fsp.unlink(tmpPath).catch(() => undefined);
      throw err;
    }
  }

  async getBytes(key: string): Promise<Uint8Array | null> {
    const { absPath } = this.resolveSafePath(key);
    try {
      const buf = await fsp.readFile(absPath);
      return new Uint8Array(buf.buffer, buf.byteOffset, buf.byteLength);
    } catch {
      return null;
    }
  }

  async head(key: string): Promise<BlobHeadResult | null> {
    const { absPath } = this.resolveSafePath(key);
    try {
      const st = await fsp.stat(absPath);
      if (!st.isFile()) return null;
      return {
        size: st.size,
        contentType: guessContentTypeFromKey(key),
        etag: `"${st.size}-${Math.trunc(st.mtimeMs)}"`,
        lastModifiedMs: st.mtimeMs,
      };
    } catch {
      return null;
    }
  }

  async getConditionalStream(
    key: string,
    options?: BlobConditionalGetOptions,
  ): Promise<BlobConditionalStreamResult | null> {
    const { absPath } = this.resolveSafePath(key);
    const st = await fsp.stat(absPath).catch(() => null);
    if (!st || !st.isFile()) return null;

    const total = st.size;
    const contentType = guessContentTypeFromKey(key);
    const etag = `"${total}-${Math.trunc(st.mtimeMs)}"`;

    if (options?.ifNoneMatch && ifNoneMatchMatches(options.ifNoneMatch, etag)) {
      return {
        status: 'not_modified',
        etag,
        contentType,
        lastModifiedMs: st.mtimeMs,
        size: total,
      };
    }

    const range = options?.range;
    if (range) {
      if (total === 0) {
        return {
          status: 'range_not_satisfiable',
          total: 0,
          etag,
          contentType,
          lastModifiedMs: st.mtimeMs,
        };
      }
      let start: number;
      let end: number;
      if ('suffix' in range && range.suffix !== undefined) {
        const suffix = Math.trunc(range.suffix);
        if (!Number.isFinite(suffix) || suffix <= 0) {
          return {
            status: 'range_not_satisfiable',
            total,
            etag,
            contentType,
            lastModifiedMs: st.mtimeMs,
          };
        }
        const len = Math.min(total, suffix);
        start = total - len;
        end = total - 1;
      } else {
        start = Math.trunc(range.offset);
        if (!Number.isFinite(start) || start < 0 || start >= total) {
          return {
            status: 'range_not_satisfiable',
            total,
            etag,
            contentType,
            lastModifiedMs: st.mtimeMs,
          };
        }
        const requestedLength =
          range.length !== undefined ? Math.trunc(range.length) : undefined;
        if (
          requestedLength !== undefined &&
          (!Number.isFinite(requestedLength) || requestedLength <= 0)
        ) {
          return {
            status: 'range_not_satisfiable',
            total,
            etag,
            contentType,
            lastModifiedMs: st.mtimeMs,
          };
        }
        const requestedEnd =
          requestedLength !== undefined ? start + requestedLength - 1 : total - 1;
        end = Math.min(total - 1, requestedEnd);
        if (start > end) {
          return {
            status: 'range_not_satisfiable',
            total,
            etag,
            contentType,
            lastModifiedMs: st.mtimeMs,
          };
        }
      }
      const chunkLen = end - start + 1;
      const nodeStream = fs.createReadStream(absPath, { start, end });
      const webStream = Readable.toWeb(nodeStream) as unknown as ReadableStream<Uint8Array>;
      return {
        status: 'ok',
        stream: webStream,
        size: chunkLen,
        contentType,
        etag,
        lastModifiedMs: st.mtimeMs,
        range: { start, end, total },
      };
    }

    if (total === 0) {
      return {
        status: 'ok',
        stream: new ReadableStream<Uint8Array>({
          start(controller) {
            controller.close();
          },
        }),
        size: 0,
        contentType,
        etag,
        lastModifiedMs: st.mtimeMs,
      };
    }

    const nodeStream = fs.createReadStream(absPath);
    const webStream = Readable.toWeb(nodeStream) as unknown as ReadableStream<Uint8Array>;
    return {
      status: 'ok',
      stream: webStream,
      size: total,
      contentType,
      etag,
      lastModifiedMs: st.mtimeMs,
    };
  }

  async getStream(key: string, range?: BlobRangeRequest): Promise<BlobStreamResult | null> {
    const res = await this.getConditionalStream(key, range ? { range } : undefined);
    if (!res || res.status !== 'ok') return null;
    const { status: _status, ...streamResult } = res;
    return streamResult;
  }

  async delete(key: string): Promise<void> {
    const { absPath } = this.resolveSafePath(key);
    await fsp.unlink(absPath).catch(() => undefined);
  }

  async deleteMany(keys: readonly string[]): Promise<void> {
    const seen = new Set<string>();
    const paths: string[] = [];
    for (const key of keys) {
      const { key: clean, absPath } = this.resolveSafePath(key);
      if (!seen.has(clean)) {
        seen.add(clean);
        paths.push(absPath);
      }
    }
    await Promise.all(paths.map((p) => fsp.unlink(p).catch(() => undefined)));
  }

  private multipartDir(uploadId: string): string {
    const safeId = uploadId.replace(/[^a-zA-Z0-9_-]/g, '');
    if (!safeId) throw new Error('Invalid multipart uploadId');
    return path.join(this.stagingDir, 'multipart', safeId);
  }

  async createMultipartUpload(
    key: string,
    _options?: { contentType?: string },
  ): Promise<BlobMultipartHandle> {
    const { key: cleanKey } = this.resolveSafePath(key);
    const uploadId = crypto.randomUUID().replace(/-/g, '');
    await fsp.mkdir(this.multipartDir(uploadId), { recursive: true });
    return { key: cleanKey, uploadId };
  }

  async uploadMultipartPart(
    key: string,
    uploadId: string,
    partNumber: number,
    data: Uint8Array | ReadableStream<Uint8Array>,
  ): Promise<BlobUploadedPart> {
    this.resolveSafePath(key);
    const cleanPart = Math.trunc(partNumber);
    if (!Number.isFinite(cleanPart) || cleanPart < 1 || cleanPart > 10_000) {
      throw new Error(`Invalid multipart part number: ${partNumber}`);
    }
    const dir = this.multipartDir(uploadId);
    await fsp.mkdir(dir, { recursive: true });
    const partPath = path.join(dir, `part-${String(cleanPart).padStart(5, '0')}.bin`);
    const hash = crypto.createHash('md5');
    let totalBytes = 0;

    if (data instanceof Uint8Array) {
      hash.update(data);
      totalBytes = data.byteLength;
      await fsp.writeFile(partPath, data);
    } else {
      const fh = await fsp.open(partPath, 'w');
      try {
        const reader = data.getReader();
        try {
          for (;;) {
            const { done, value } = await reader.read();
            if (done) break;
            if (value && value.byteLength > 0) {
              hash.update(value);
              await fh.write(value);
              totalBytes += value.byteLength;
            }
          }
        } finally {
          reader.releaseLock();
        }
      } finally {
        await fh.close();
      }
    }

    return {
      partNumber: cleanPart,
      etag: `"${hash.digest('hex')}"`,
      size: totalBytes,
    };
  }

  async completeMultipartUpload(
    key: string,
    uploadId: string,
    parts: readonly BlobUploadedPart[],
  ): Promise<{ size: number; etag?: string }> {
    const { absPath } = this.resolveSafePath(key);
    const dir = this.multipartDir(uploadId);
    const sorted = [...parts].sort((a, b) => a.partNumber - b.partNumber);
    await fsp.mkdir(path.dirname(absPath), { recursive: true });
    const tmpPath = path.join(this.stagingDir, `${crypto.randomUUID()}.assembled`);
    let totalSize = 0;

    try {
      const outFh = await fsp.open(tmpPath, 'w');
      try {
        for (const part of sorted) {
          const partPath = path.join(dir, `part-${String(part.partNumber).padStart(5, '0')}.bin`);
          const buf = await fsp.readFile(partPath);
          await outFh.write(buf);
          totalSize += buf.byteLength;
        }
      } finally {
        await outFh.close();
      }
      await fsp.rename(tmpPath, absPath);
      const st = await fsp.stat(absPath).catch(() => null);
      const etag = st ? `"${st.size}-${Math.trunc(st.mtimeMs)}"` : undefined;
      return { size: totalSize, etag };
    } catch (err) {
      await fsp.unlink(tmpPath).catch(() => undefined);
      throw err;
    } finally {
      await fsp.rm(dir, { recursive: true, force: true }).catch(() => undefined);
    }
  }

  async abortMultipartUpload(_key: string, uploadId: string): Promise<void> {
    await fsp.rm(this.multipartDir(uploadId), { recursive: true, force: true }).catch(() => undefined);
  }

  async list(prefix: string): Promise<BlobListItem[]> {
    const cleanPrefix = prefix.replace(/^\/+/, '');
    const results: BlobListItem[] = [];

    const walk = async (dir: string, relDir: string): Promise<void> => {
      let entries: fs.Dirent[];
      try {
        entries = await fsp.readdir(dir, { withFileTypes: true });
      } catch {
        return;
      }
      for (const entry of entries) {
        if (entry.name === '.staging' && relDir === '') continue;
        const childRel = relDir ? `${relDir}/${entry.name}` : entry.name;
        const childAbs = path.join(dir, entry.name);
        if (entry.isDirectory()) {
          // Prune directories that cannot match prefix
          if (
            cleanPrefix.length === 0 ||
            childRel.startsWith(cleanPrefix) ||
            cleanPrefix.startsWith(`${childRel}/`)
          ) {
            await walk(childAbs, childRel);
          }
        } else if (entry.isFile()) {
          if (cleanPrefix.length === 0 || childRel.startsWith(cleanPrefix)) {
            const st = await fsp.stat(childAbs).catch(() => null);
            if (st?.isFile()) {
              results.push({
                key: childRel,
                size: st.size,
                lastModifiedMs: st.mtimeMs,
              });
            }
          }
        }
      }
    };

    await walk(this.rootDir, '');
    results.sort((a, b) => a.key.localeCompare(b.key));
    return results;
  }
}

export { streamToBytes };
