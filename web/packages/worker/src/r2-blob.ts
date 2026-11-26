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
} from '@charkle/server/worker';

/** R2 single-part upload limit is 5 GiB - 5 MiB (4.995 GiB). */
const R2_MAX_SINGLE_PUT_BYTES = 4_995 * 1024 * 1024;
/** R2 batch delete accepts up to 1,000 keys per call. */
const R2_DELETE_BATCH_SIZE = 1000;
/**
 * Fixed non-final part size for unknown-length stream multipart uploads.
 * Must be >= 5 MiB (R2 minimum) and small enough to stay well inside the 128 MiB Worker isolate.
 */
const R2_STREAM_MULTIPART_PART_BYTES = 8 * 1024 * 1024;

export function sanitizeBlobKey(rawKey: string): string {
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

export function guessContentTypeFromKey(key: string): string | undefined {
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

export function ifNoneMatchMatches(headerValue: string | undefined, etag: string | undefined): boolean {
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

function mergeChunks(chunks: readonly Uint8Array[], totalLength: number): Uint8Array {
  if (chunks.length === 0 || totalLength === 0) return new Uint8Array(0);
  if (chunks.length === 1 && chunks[0].byteLength === totalLength) return chunks[0];
  const merged = new Uint8Array(totalLength);
  let offset = 0;
  for (const chunk of chunks) {
    merged.set(chunk, offset);
    offset += chunk.byteLength;
  }
  return merged;
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
  return mergeChunks(chunks, total);
}

function toR2Range(range: BlobRangeRequest): R2Range | null {
  if ('suffix' in range && range.suffix !== undefined) {
    const suffix = Math.trunc(range.suffix);
    if (!Number.isFinite(suffix) || suffix <= 0) return null;
    return { suffix };
  }
  const start = Math.trunc(range.offset);
  if (!Number.isFinite(start) || start < 0) return null;
  const requestedLength = range.length !== undefined ? Math.trunc(range.length) : undefined;
  if (requestedLength !== undefined && (!Number.isFinite(requestedLength) || requestedLength <= 0)) {
    return null;
  }
  return requestedLength !== undefined ? { offset: start, length: requestedLength } : { offset: start };
}

function hasObjectBody(obj: R2Object | R2ObjectBody): obj is R2ObjectBody {
  return 'body' in obj && obj.body !== null && obj.body !== undefined;
}

function resolveResponseRange(
  range: BlobRangeRequest,
  obj: R2Object,
): { start: number; end: number; length: number; total: number } | null {
  const total = obj.size;
  if (total === 0) return null;

  if ('suffix' in range && range.suffix !== undefined) {
    const suffix = Math.trunc(range.suffix);
    if (!Number.isFinite(suffix) || suffix <= 0) return null;
    const length = Math.min(total, suffix);
    const start = total - length;
    return { start, end: total - 1, length, total };
  }

  const start = Math.trunc(range.offset);
  if (!Number.isFinite(start) || start < 0 || start >= total) return null;

  const requestedLength = range.length !== undefined ? Math.trunc(range.length) : undefined;
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

  if (resolvedLength <= 0 || resolvedStart >= total) return null;
  return {
    start: resolvedStart,
    end: resolvedStart + resolvedLength - 1,
    length: resolvedLength,
    total,
  };
}

/**
 * Cloudflare R2 implementation of `IBlobStore` with:
 * - Single-call conditional + Range streaming (`200`, `206`, `304`, `416`)
 * - Native batch deletes (`bucket.delete(keys[])`)
 * - Zero-copy `FixedLengthStream` puts for known-length streams
 * - Bounded-memory (`<= 8 MiB` RAM) R2 Multipart Upload fallback for unknown-length streams
 * - Explicit Multipart Upload API (`createMultipartUpload` / `uploadMultipartPart` / `complete` / `abort`)
 */
export class R2BlobStore implements IBlobStore {
  private readonly bucket: R2Bucket;
  private readonly multipartPartBytes: number;

  constructor(bucket: R2Bucket, options?: { multipartPartBytes?: number }) {
    this.bucket = bucket;
    this.multipartPartBytes = Math.max(
      1,
      Math.trunc(options?.multipartPartBytes ?? R2_STREAM_MULTIPART_PART_BYTES),
    );
  }

  async put(
    key: string,
    data: Uint8Array | ReadableStream<Uint8Array>,
    options?: { contentType?: string; size?: number },
  ): Promise<{ size: number }> {
    const cleanKey = sanitizeBlobKey(key);
    const contentType = options?.contentType || guessContentTypeFromKey(cleanKey);
    const putOptions: R2PutOptions | undefined = contentType
      ? { httpMetadata: { contentType } }
      : undefined;

    if (data instanceof Uint8Array) {
      const bytes =
        data.byteOffset === 0 && data.byteLength === data.buffer.byteLength
          ? data
          : data.slice();
      const stored = await this.bucket.put(cleanKey, bytes, putOptions);
      return { size: stored?.size ?? bytes.byteLength };
    }

    // Stream directly into R2 with FixedLengthStream when total Content-Length is known and within single-put limit.
    const knownSize =
      typeof options?.size === 'number' && Number.isFinite(options.size) && options.size >= 0
        ? Math.trunc(options.size)
        : undefined;

    const FixedLengthCtor = (
      globalThis as unknown as {
        FixedLengthStream?: new (expectedLength: number) => TransformStream<Uint8Array, Uint8Array>;
      }
    ).FixedLengthStream;

    if (
      knownSize !== undefined &&
      knownSize <= R2_MAX_SINGLE_PUT_BYTES &&
      typeof FixedLengthCtor === 'function'
    ) {
      const fixed = new FixedLengthCtor(knownSize);
      const pipePromise = data.pipeTo(fixed.writable);
      const [stored] = await Promise.all([
        this.bucket.put(cleanKey, fixed.readable, putOptions),
        pipePromise,
      ]);
      return { size: stored?.size ?? knownSize };
    }

    // When stream length is unknown (or > 4.995 GiB), stream in fixed-size parts via R2 Multipart Upload
    // so peak Worker RAM stays bounded (<= 8 MiB), while streams <= partSize still use a single `bucket.put`.
    if (typeof this.bucket.createMultipartUpload === 'function') {
      return this.putUnknownLengthStream(cleanKey, data, putOptions);
    }

    const bytes = await collectStreamBytes(data);
    const stored = await this.bucket.put(cleanKey, bytes, putOptions);
    return { size: stored?.size ?? bytes.byteLength };
  }

  private async putUnknownLengthStream(
    cleanKey: string,
    stream: ReadableStream<Uint8Array>,
    putOptions?: R2PutOptions,
  ): Promise<{ size: number }> {
    const partSize = this.multipartPartBytes;
    const reader = stream.getReader();
    const pendingChunks: Uint8Array[] = [];
    let pendingBytes = 0;
    let totalBytes = 0;
    let multipart: R2MultipartUpload | null = null;
    const uploadedParts: R2UploadedPart[] = [];
    let nextPartNumber = 1;

    const extractExactPart = (): Uint8Array => {
      const out = new Uint8Array(partSize);
      let written = 0;
      while (written < partSize && pendingChunks.length > 0) {
        const head = pendingChunks[0];
        const need = partSize - written;
        if (head.byteLength <= need) {
          out.set(head, written);
          written += head.byteLength;
          pendingChunks.shift();
        } else {
          out.set(head.subarray(0, need), written);
          pendingChunks[0] = head.subarray(need);
          written += need;
        }
      }
      pendingBytes -= partSize;
      return out;
    };

    try {
      for (;;) {
        const { done, value } = await reader.read();
        if (done) break;
        if (value && value.byteLength > 0) {
          pendingChunks.push(value);
          pendingBytes += value.byteLength;
          totalBytes += value.byteLength;

          // Flush full fixed-size parts only once buffered bytes strictly exceed partSize,
          // ensuring small streams (<= partSize) finish in a single regular `bucket.put`.
          while (pendingBytes > partSize) {
            if (!multipart) {
              multipart = await this.bucket.createMultipartUpload(cleanKey, putOptions);
            }
            const partBytes = extractExactPart();
            const uploaded = await multipart.uploadPart(nextPartNumber++, partBytes);
            uploadedParts.push(uploaded);
          }
        }
      }

      if (!multipart) {
        const singlePayload = mergeChunks(pendingChunks, pendingBytes);
        const stored = await this.bucket.put(cleanKey, singlePayload, putOptions);
        return { size: stored?.size ?? singlePayload.byteLength };
      }

      if (pendingBytes > 0) {
        const tailBytes = mergeChunks(pendingChunks, pendingBytes);
        const uploaded = await multipart.uploadPart(nextPartNumber++, tailBytes);
        uploadedParts.push(uploaded);
      }

      const completed = await multipart.complete(uploadedParts);
      return { size: completed?.size ?? totalBytes };
    } catch (err) {
      if (multipart) {
        await multipart.abort().catch(() => undefined);
      }
      throw err;
    } finally {
      reader.releaseLock();
    }
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

  async getConditionalStream(
    key: string,
    options?: BlobConditionalGetOptions,
  ): Promise<BlobConditionalStreamResult | null> {
    const cleanKey = sanitizeBlobKey(key);
    const range = options?.range;
    const ifNoneMatch = options?.ifNoneMatch?.trim() || undefined;

    let r2Range: R2Range | undefined;
    if (range) {
      const converted = toR2Range(range);
      if (!converted) {
        const headObj = await this.bucket.head(cleanKey);
        if (!headObj) return null;
        return {
          status: 'range_not_satisfiable',
          total: headObj.size,
          etag: headObj.httpEtag || headObj.etag,
          contentType: headObj.httpMetadata?.contentType ?? guessContentTypeFromKey(cleanKey),
          lastModifiedMs: headObj.uploaded.getTime(),
        };
      }
      r2Range = converted;
    }

    const onlyIf = ifNoneMatch ? new Headers({ 'if-none-match': ifNoneMatch }) : undefined;
    const obj = onlyIf
      ? await this.bucket.get(cleanKey, { range: r2Range, onlyIf })
      : r2Range
        ? await this.bucket.get(cleanKey, { range: r2Range })
        : await this.bucket.get(cleanKey);

    if (!obj) return null;

    const etag = obj.httpEtag || obj.etag;
    const contentType = obj.httpMetadata?.contentType ?? guessContentTypeFromKey(cleanKey);
    const lastModifiedMs = obj.uploaded.getTime();

    if (!hasObjectBody(obj)) {
      return {
        status: 'not_modified',
        etag,
        contentType,
        lastModifiedMs,
        size: obj.size,
      };
    }

    // Defensive check when a mock/emulator ignores `onlyIf` headers
    if (ifNoneMatch && ifNoneMatchMatches(ifNoneMatch, etag)) {
      await obj.body.cancel().catch(() => undefined);
      return {
        status: 'not_modified',
        etag,
        contentType,
        lastModifiedMs,
        size: obj.size,
      };
    }

    if (range) {
      const resolved = resolveResponseRange(range, obj);
      if (!resolved) {
        await obj.body.cancel().catch(() => undefined);
        return {
          status: 'range_not_satisfiable',
          total: obj.size,
          etag,
          contentType,
          lastModifiedMs,
        };
      }
      return {
        status: 'ok',
        stream: obj.body as ReadableStream<Uint8Array>,
        size: resolved.length,
        contentType,
        etag,
        lastModifiedMs,
        range: {
          start: resolved.start,
          end: resolved.end,
          total: resolved.total,
        },
      };
    }

    return {
      status: 'ok',
      stream: obj.body as ReadableStream<Uint8Array>,
      size: obj.size,
      contentType,
      etag,
      lastModifiedMs,
    };
  }

  async getStream(key: string, range?: BlobRangeRequest): Promise<BlobStreamResult | null> {
    const res = await this.getConditionalStream(key, range ? { range } : undefined);
    if (!res || res.status !== 'ok') return null;
    const { status: _status, ...streamResult } = res;
    return streamResult;
  }

  async delete(key: string): Promise<void> {
    const cleanKey = sanitizeBlobKey(key);
    await this.bucket.delete(cleanKey);
  }

  async deleteMany(keys: readonly string[]): Promise<void> {
    const unique: string[] = [];
    const seen = new Set<string>();
    for (const raw of keys) {
      const clean = sanitizeBlobKey(raw);
      if (!seen.has(clean)) {
        seen.add(clean);
        unique.push(clean);
      }
    }
    if (unique.length === 0) return;
    for (let i = 0; i < unique.length; i += R2_DELETE_BATCH_SIZE) {
      const batch = unique.slice(i, i + R2_DELETE_BATCH_SIZE);
      await this.bucket.delete(batch.length === 1 ? batch[0] : batch);
    }
  }

  async createMultipartUpload(
    key: string,
    options?: { contentType?: string },
  ): Promise<BlobMultipartHandle> {
    const cleanKey = sanitizeBlobKey(key);
    const contentType = options?.contentType || guessContentTypeFromKey(cleanKey);
    const mpOptions: R2MultipartOptions | undefined = contentType
      ? { httpMetadata: { contentType } }
      : undefined;
    const mp = await this.bucket.createMultipartUpload(cleanKey, mpOptions);
    return { key: cleanKey, uploadId: mp.uploadId };
  }

  async uploadMultipartPart(
    key: string,
    uploadId: string,
    partNumber: number,
    data: Uint8Array | ReadableStream<Uint8Array>,
    options?: { size?: number },
  ): Promise<BlobUploadedPart> {
    const cleanKey = sanitizeBlobKey(key);
    const mp = this.bucket.resumeMultipartUpload(cleanKey, uploadId);

    if (data instanceof Uint8Array) {
      const bytes =
        data.byteOffset === 0 && data.byteLength === data.buffer.byteLength
          ? data
          : data.slice();
      const uploaded = await mp.uploadPart(partNumber, bytes);
      return { partNumber: uploaded.partNumber, etag: uploaded.etag, size: bytes.byteLength };
    }

    const knownSize =
      typeof options?.size === 'number' && Number.isFinite(options.size) && options.size >= 0
        ? Math.trunc(options.size)
        : undefined;
    const FixedLengthCtor = (
      globalThis as unknown as {
        FixedLengthStream?: new (expectedLength: number) => TransformStream<Uint8Array, Uint8Array>;
      }
    ).FixedLengthStream;

    if (knownSize !== undefined && typeof FixedLengthCtor === 'function') {
      const fixed = new FixedLengthCtor(knownSize);
      const pipePromise = data.pipeTo(fixed.writable);
      const [uploaded] = await Promise.all([
        mp.uploadPart(partNumber, fixed.readable),
        pipePromise,
      ]);
      return { partNumber: uploaded.partNumber, etag: uploaded.etag, size: knownSize };
    }

    const bytes = await collectStreamBytes(data);
    const uploaded = await mp.uploadPart(partNumber, bytes);
    return { partNumber: uploaded.partNumber, etag: uploaded.etag, size: bytes.byteLength };
  }

  async completeMultipartUpload(
    key: string,
    uploadId: string,
    parts: readonly BlobUploadedPart[],
  ): Promise<{ size: number; etag?: string }> {
    const cleanKey = sanitizeBlobKey(key);
    const mp = this.bucket.resumeMultipartUpload(cleanKey, uploadId);
    const sorted = [...parts]
      .sort((a, b) => a.partNumber - b.partNumber)
      .map((p) => ({ partNumber: p.partNumber, etag: p.etag }));
    const completed = await mp.complete(sorted);
    const expectedTotal = parts.reduce((sum, p) => sum + p.size, 0);
    return {
      size: completed?.size ?? expectedTotal,
      etag: completed?.httpEtag || completed?.etag,
    };
  }

  async abortMultipartUpload(key: string, uploadId: string): Promise<void> {
    const cleanKey = sanitizeBlobKey(key);
    const mp = this.bucket.resumeMultipartUpload(cleanKey, uploadId);
    await mp.abort();
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
