import crypto from 'node:crypto';
import fs from 'node:fs';
import fsp from 'node:fs/promises';
import path from 'node:path';
import { Readable } from 'node:stream';
import type {
  BlobHeadResult,
  BlobListItem,
  BlobRangeRequest,
  BlobStreamResult,
  IBlobStore,
} from './types.js';
import { streamToBytes } from './web-crypto-utils.js';

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

  async getStream(key: string, range?: BlobRangeRequest): Promise<BlobStreamResult | null> {
    const { absPath } = this.resolveSafePath(key);
    const st = await fsp.stat(absPath).catch(() => null);
    if (!st || !st.isFile()) return null;

    const total = st.size;
    const contentType = guessContentTypeFromKey(key);
    const etag = `"${total}-${Math.trunc(st.mtimeMs)}"`;

    if (range) {
      const start = Math.max(0, Math.trunc(range.offset));
      const requestedEnd =
        range.length !== undefined ? start + Math.max(0, Math.trunc(range.length)) - 1 : total - 1;
      const end = Math.min(total - 1, requestedEnd);
      if (start >= total || start > end) {
        return null;
      }
      const chunkLen = end - start + 1;
      const nodeStream = fs.createReadStream(absPath, { start, end });
      const webStream = Readable.toWeb(nodeStream) as unknown as ReadableStream<Uint8Array>;
      return {
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
      stream: webStream,
      size: total,
      contentType,
      etag,
      lastModifiedMs: st.mtimeMs,
    };
  }

  async delete(key: string): Promise<void> {
    const { absPath } = this.resolveSafePath(key);
    await fsp.unlink(absPath).catch(() => undefined);
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
