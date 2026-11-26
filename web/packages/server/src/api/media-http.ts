import type { ClientPreprocessedMedia, UUID } from '@charkle/shared';
import type { BlobConditionalStreamResult, BlobRangeRequest } from '../runtime/types.js';

export const MULTIPART_UPLOAD_STATE_PREFIX = 'upload.mp.';
/** Fixed 8 MiB chunk size: >= R2 5 MiB minimum and far under Cloudflare's 100 MB request limit & 128 MiB RAM. */
export const MULTIPART_UPLOAD_PART_SIZE_BYTES = 8 * 1024 * 1024;
export const MULTIPART_UPLOAD_MAX_PARTS = 10_000;
/** Maximum total file size accepted by R2 multipart upload (~4.995 TiB). */
export const MULTIPART_UPLOAD_MAX_FILE_BYTES = 5 * 1024 * 1024 * 1024 * 1024 - 5 * 1024 * 1024 * 1024;

export interface PersistedMultipartUploadSession {
  sessionID: UUID;
  assetID: UUID;
  blobKey: string;
  uploadId: string;
  fileName: string;
  mimeType: string;
  fileSizeBytes: number;
  targetFolderID: UUID | null;
  targetBoardID: UUID | null;
  preprocessed: ClientPreprocessedMedia | null;
  parts: Record<string, { partNumber: number; etag: string; size: number }>;
  createdAtMs: number;
}

export type ParsedRangeHeader =
  | { kind: 'none' }
  | { kind: 'invalid' }
  | { kind: 'valid'; range: BlobRangeRequest };

/**
 * Parses a single RFC 9110 HTTP `Range: bytes=...` header into a storage-level `BlobRangeRequest`
 * WITHOUT needing a prior `HEAD` call to know total file size.
 */
export function parseHttpRangeHeader(rangeHeader: string | undefined | null): ParsedRangeHeader {
  if (!rangeHeader) return { kind: 'none' };
  const trimmed = rangeHeader.trim();
  if (!trimmed.toLowerCase().startsWith('bytes=')) {
    return { kind: 'none' };
  }
  const spec = trimmed.slice(6).trim();
  // Reject multi-range specs or malformed syntax cleanly
  const match = /^(\d*)-(\d*)$/.exec(spec);
  if (!match) return { kind: 'invalid' };
  const startRaw = match[1];
  const endRaw = match[2];
  if (!startRaw && !endRaw) return { kind: 'invalid' };

  if (!startRaw && endRaw) {
    const suffix = Number.parseInt(endRaw, 10);
    if (!Number.isFinite(suffix) || suffix <= 0) return { kind: 'invalid' };
    return { kind: 'valid', range: { suffix } };
  }

  const start = Number.parseInt(startRaw, 10);
  if (!Number.isFinite(start) || start < 0) return { kind: 'invalid' };

  if (!endRaw) {
    return { kind: 'valid', range: { offset: start } };
  }

  const end = Number.parseInt(endRaw, 10);
  if (!Number.isFinite(end) || end < start) return { kind: 'invalid' };
  return { kind: 'valid', range: { offset: start, length: end - start + 1 } };
}

export function buildMediaDisposition(fileName: string, download: boolean): string {
  const encoded = encodeURIComponent(fileName);
  return download
    ? `attachment; filename*=UTF-8''${encoded}`
    : `inline; filename*=UTF-8''${encoded}`;
}

export interface BuildMediaStreamResponseOptions {
  contentType: string;
  cacheControl: string;
  fileName?: string;
  download?: boolean;
  acceptRanges?: boolean;
  extraHeaders?: Record<string, string>;
}

/**
 * Converts a single-roundtrip `BlobConditionalStreamResult` into a standard HTTP
 * `200`, `206`, `304`, or `416` `Response` shared identically by Node Hono routes and the Cloudflare edge Worker.
 */
export function buildMediaStreamResponse(
  result: BlobConditionalStreamResult,
  options: BuildMediaStreamResponseOptions,
): Response {
  const baseHeaders: Record<string, string> = {
    'Cache-Control': options.cacheControl,
    ...(options.extraHeaders ?? {}),
  };

  if (result.status === 'not_modified') {
    return new Response(null, {
      status: 304,
      headers: {
        ...baseHeaders,
        ETag: result.etag,
      },
    });
  }

  if (result.status === 'range_not_satisfiable') {
    return new Response(null, {
      status: 416,
      headers: {
        ...baseHeaders,
        'Content-Range': `bytes */${result.total}`,
      },
    });
  }

  const headers: Record<string, string> = {
    ...baseHeaders,
    'Content-Type': options.contentType || result.contentType || 'application/octet-stream',
    'Content-Length': String(result.size),
  };

  if (options.acceptRanges) {
    headers['Accept-Ranges'] = 'bytes';
  }
  if (result.etag) {
    headers.ETag = result.etag;
  }
  if (headers['Content-Type'] === 'application/pdf') {
    headers['X-Frame-Options'] = 'SAMEORIGIN';
  }
  if (options.fileName) {
    headers['Content-Disposition'] = buildMediaDisposition(
      options.fileName,
      Boolean(options.download),
    );
  }

  if (result.range) {
    headers['Content-Range'] =
      `bytes ${result.range.start}-${result.range.end}/${result.range.total}`;
    return new Response(result.stream, {
      status: 206,
      headers,
    });
  }

  return new Response(result.stream, {
    status: 200,
    headers,
  });
}
