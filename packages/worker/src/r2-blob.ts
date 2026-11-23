import type {
  BlobHeadResult,
  BlobListItem,
  BlobRangeRequest,
  BlobStreamResult,
  IBlobStore,
} from '@charkle/server/worker';

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
  const lastSlash = key.lastIndexOf('/');
  const base = lastSlash >= 0 ? key.slice(lastSlash + 1) : key;
  const dot = base.lastIndexOf('.');
  if (dot <= 0) return undefined;
  const ext = base.slice(dot).toLowerCase();
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
    case '.bmp':
      return 'image/bmp';
    case '.avif':
      return 'image/avif';
    case '.mp4':
      return 'video/mp4';
    case '.webm':
      return 'video/webm';
    case '.mov':
      return 'video/quicktime';
    case '.wav':
      return 'audio/wav';
    case '.mp3':
      return 'audio/mpeg';
    case '.ogg':
      return 'audio/ogg';
    case '.m4a':
      return 'audio/mp4';
    case '.pdf':
      return 'application/pdf';
    case '.md':
      return 'text/markdown';
    case '.txt':
      return 'text/plain';
    case '.json':
      return 'application/json';
    case '.glb':
      return 'model/gltf-binary';
    case '.gltf':
      return 'model/gltf+json';
    case '.usdz':
      return 'model/vnd.usdz+zip';
    case '.zip':
      return 'application/zip';
    default:
      return undefined;
  }
}

async function collectStreamBytes(stream: ReadableStream<Uint8Array>): Promise<Uint8Array> {
  const reader = stream.getReader();
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
  if (chunks.length === 0) return new Uint8Array(0);
  if (chunks.length === 1) return chunks[0];
  const merged = new Uint8Array(total);
  let offset = 0;
  for (const chunk of chunks) {
    merged.set(chunk, offset);
    offset += chunk.byteLength;
  }
  return merged;
}

/**
 * Cloudflare R2 implementation of `IBlobStore` with native HTTP `206 Partial Content`
 * Range streaming, paginated `list()`, and safe unknown-length stream uploads.
 */
export class R2BlobStore implements IBlobStore {
  private readonly bucket: R2Bucket;

  constructor(bucket: R2Bucket) {
    this.bucket = bucket;
  }

  async put(
    key: string,
    data: Uint8Array | ReadableStream<Uint8Array>,
    options?: { contentType?: string },
  ): Promise<{ size: number }> {
    const cleanKey = sanitizeBlobKey(key);
    const contentType = options?.contentType || guessContentTypeFromKey(cleanKey);
    const putOptions: R2PutOptions | undefined = contentType
      ? { httpMetadata: { contentType } }
      : undefined;

    let bytes: Uint8Array;
    if (data instanceof Uint8Array) {
      bytes =
        data.byteOffset === 0 && data.byteLength === data.buffer.byteLength
          ? data
          : data.slice();
    } else {
      // Cloudflare R2 requires a known length for ReadableStream uploads;
      // collect unknown-length streams safely into a Uint8Array.
      bytes = await collectStreamBytes(data);
    }

    const stored = await this.bucket.put(cleanKey, bytes, putOptions);
    return { size: stored?.size ?? bytes.byteLength };
  }

  async getBytes(key: string): Promise<Uint8Array | null> {
    const cleanKey = sanitizeBlobKey(key);
    const obj = await this.bucket.get(cleanKey);
    if (!obj) return null;
    const buf = await obj.arrayBuffer();
    return new Uint8Array(buf);
  }

  async head(key: string): Promise<BlobHeadResult | null> {
    const cleanKey = sanitizeBlobKey(key);
    const obj = await this.bucket.head(cleanKey);
    if (!obj) return null;
    return {
      size: obj.size,
      contentType: obj.httpMetadata?.contentType ?? guessContentTypeFromKey(cleanKey),
      etag: obj.httpEtag || obj.etag,
      lastModifiedMs: obj.uploaded.getTime(),
    };
  }

  async getStream(key: string, range?: BlobRangeRequest): Promise<BlobStreamResult | null> {
    const cleanKey = sanitizeBlobKey(key);

    if (range) {
      const start = Math.trunc(range.offset);
      if (!Number.isFinite(start) || start < 0) {
        return null;
      }
      const requestedLength =
        range.length !== undefined ? Math.trunc(range.length) : undefined;
      if (
        requestedLength !== undefined &&
        (!Number.isFinite(requestedLength) || requestedLength <= 0)
      ) {
        return null;
      }

      const r2Range: R2Range =
        requestedLength !== undefined
          ? { offset: start, length: requestedLength }
          : { offset: start };
      const obj = await this.bucket.get(cleanKey, { range: r2Range });
      if (!obj) return null;

      const total = obj.size;
      if (total === 0 || start >= total) {
        await obj.body.cancel().catch(() => undefined);
        return null;
      }

      let resolvedStart = start;
      let resolvedLength: number;
      if (
        obj.range &&
        'offset' in obj.range &&
        typeof obj.range.offset === 'number' &&
        typeof obj.range.length === 'number'
      ) {
        resolvedStart = obj.range.offset;
        resolvedLength = Math.min(obj.range.length, total - resolvedStart);
      } else {
        const clampedEnd =
          requestedLength !== undefined
            ? Math.min(total - 1, start + requestedLength - 1)
            : total - 1;
        resolvedLength = clampedEnd - start + 1;
      }

      if (resolvedLength <= 0 || resolvedStart >= total) {
        await obj.body.cancel().catch(() => undefined);
        return null;
      }

      const resolvedEnd = resolvedStart + resolvedLength - 1;
      return {
        stream: obj.body as ReadableStream<Uint8Array>,
        size: resolvedLength,
        contentType: obj.httpMetadata?.contentType ?? guessContentTypeFromKey(cleanKey),
        etag: obj.httpEtag || obj.etag,
        lastModifiedMs: obj.uploaded.getTime(),
        range: { start: resolvedStart, end: resolvedEnd, total },
      };
    }

    const obj = await this.bucket.get(cleanKey);
    if (!obj) return null;
    return {
      stream: obj.body as ReadableStream<Uint8Array>,
      size: obj.size,
      contentType: obj.httpMetadata?.contentType ?? guessContentTypeFromKey(cleanKey),
      etag: obj.httpEtag || obj.etag,
      lastModifiedMs: obj.uploaded.getTime(),
    };
  }

  async delete(key: string): Promise<void> {
    const cleanKey = sanitizeBlobKey(key);
    await this.bucket.delete(cleanKey);
  }

  async list(prefix: string): Promise<BlobListItem[]> {
    const cleanPrefix = prefix.trim().replace(/^\/+/, '');
    const results: BlobListItem[] = [];
    let cursor: string | undefined;

    do {
      const listed = await this.bucket.list({
        prefix: cleanPrefix.length > 0 ? cleanPrefix : undefined,
        cursor,
      });
      for (const obj of listed.objects) {
        results.push({
          key: obj.key,
          size: obj.size,
          lastModifiedMs: obj.uploaded.getTime(),
        });
      }
      cursor = listed.truncated ? listed.cursor : undefined;
    } while (cursor);

    results.sort((a, b) => a.key.localeCompare(b.key));
    return results;
  }
}
