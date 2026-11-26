import {
  buildMediaStreamResponse,
  isAllowedExtensionOrigin,
  parseHttpRangeHeader,
  type BlobConditionalStreamResult,
  type BlobIndexSlot,
} from '@charkle/server/worker';
import type { CharkleWorkerEnv } from './env.js';
import { CharkleLibraryDO } from './library-do.js';
import { R2BlobStore } from './r2-blob.js';

export { CharkleLibraryDO };

const THUMBNAIL_MEDIA_RE = /^\/api\/v1\/media\/([^/]+)\/thumbnail\/(grid520|preview1400)$/;
const ORIGINAL_MEDIA_RE = /^\/api\/v1\/media\/([^/]+)\/original$/;
const MULTIPART_PART_RE = /^\/api\/v1\/uploads\/multipart\/([^/]+)\/part\/(\d+)$/;

function applyEdgeSecurityAndCorsHeaders(request: Request, response: Response): Response {
  const headers = new Headers(response.headers);
  headers.set('X-Content-Type-Options', 'nosniff');
  if (!headers.has('X-Frame-Options')) {
    headers.set('X-Frame-Options', 'DENY');
  }
  headers.set('Referrer-Policy', 'same-origin');

  const origin = request.headers.get('origin')?.trim();
  if (isAllowedExtensionOrigin(origin)) {
    headers.set('Access-Control-Allow-Origin', origin);
    const vary = headers.get('vary');
    if (!vary) {
      headers.set('Vary', 'Origin');
    } else if (!vary.toLowerCase().split(',').map((s) => s.trim()).includes('origin')) {
      headers.set('Vary', `${vary}, Origin`);
    }
  }

  return new Response(request.method === 'HEAD' ? null : response.body, {
    status: response.status,
    statusText: response.statusText,
    headers,
  });
}

function edgeJsonResponse(request: Request, body: unknown, status: number): Response {
  return applyEdgeSecurityAndCorsHeaders(
    request,
    new Response(JSON.stringify(body), {
      status,
      headers: { 'Content-Type': 'application/json; charset=utf-8' },
    }),
  );
}

function safeWaitUntil(ctx: ExecutionContext | undefined, promise: Promise<unknown>): void {
  if (ctx && typeof ctx.waitUntil === 'function') {
    ctx.waitUntil(promise.catch(() => undefined));
  } else {
    void promise.catch(() => undefined);
  }
}

function inferThumbnailSlotFromKey(key: string, defaultSlot: BlobIndexSlot): BlobIndexSlot {
  if (key.startsWith('thumbnails/520/')) return 'grid520';
  if (key.startsWith('thumbnails/1400/')) return 'preview1400';
  return defaultSlot;
}

async function handleEdgeMediaRead(
  request: Request,
  url: URL,
  stub: DurableObjectStub<CharkleLibraryDO>,
  env: CharkleWorkerEnv,
  ctx: ExecutionContext,
): Promise<Response | null> {
  const method = request.method.toUpperCase();
  if (method !== 'GET' && method !== 'HEAD') return null;

  const thumbMatch = THUMBNAIL_MEDIA_RE.exec(url.pathname);
  const origMatch = thumbMatch ? null : ORIGINAL_MEDIA_RE.exec(url.pathname);
  if (!thumbMatch && !origMatch) return null;

  // Fall back transparently if binding/RPC is absent (e.g. minimal unit test mocks)
  if (!env.MEDIA_BUCKET || typeof stub.resolveEdgeMediaRead !== 'function') {
    return null;
  }

  const cachedOnlyQuery = (url.searchParams.get('cachedOnly') ?? '').trim().toLowerCase();
  const cachedOnly = cachedOnlyQuery === '1' || cachedOnlyQuery === 'true';
  const download = url.searchParams.get('download') === '1';

  const descriptor = await stub.resolveEdgeMediaRead({
    kind: thumbMatch ? 'thumbnail' : 'original',
    id: decodeURIComponent((thumbMatch ? thumbMatch[1] : origMatch![1]) ?? ''),
    tier: thumbMatch ? (thumbMatch[2] as 'grid520' | 'preview1400') : undefined,
    cachedOnly,
    download,
    authHeader: request.headers.get('authorization'),
    cookieHeader: request.headers.get('cookie'),
  });

  if (descriptor.kind === 'fallbackToDO') {
    return null;
  }
  if (descriptor.kind === 'error') {
    return edgeJsonResponse(request, { error: descriptor.error, code: descriptor.code }, descriptor.status);
  }

  const store = new R2BlobStore(env.MEDIA_BUCKET);
  const ifNoneMatch = request.headers.get('if-none-match') ?? undefined;
  const parsedRange = descriptor.acceptRanges
    ? parseHttpRangeHeader(request.headers.get('range'))
    : ({ kind: 'none' } as const);

  if (parsedRange.kind === 'invalid') {
    const head = await store.head(descriptor.key);
    if (!head) {
      if (descriptor.keyWasIndexed && typeof stub.invalidateEdgeBlobKey === 'function') {
        safeWaitUntil(ctx, stub.invalidateEdgeBlobKey(descriptor.assetID, descriptor.slot));
      }
      if (descriptor.canRemoteDownload) {
        return null;
      }
      return edgeJsonResponse(
        request,
        {
          error: '原始文件暂未缓存到本地。',
          code: descriptor.cachedOnly ? 'NOT_CACHED' : 'NOT_FOUND',
        },
        404,
      );
    }
    return applyEdgeSecurityAndCorsHeaders(
      request,
      new Response(null, {
        status: 416,
        headers: { 'Content-Range': `bytes */${head.size}` },
      }),
    );
  }

  const readOpts = {
    range: parsedRange.kind === 'valid' ? parsedRange.range : undefined,
    ifNoneMatch,
  };

  let hitKey = descriptor.key;
  let result: BlobConditionalStreamResult | null = await store.getConditionalStream(
    descriptor.key,
    readOpts,
  );
  let resolvedViaFallback = false;

  if (!result && descriptor.keyWasIndexed && typeof stub.invalidateEdgeBlobKey === 'function') {
    safeWaitUntil(ctx, stub.invalidateEdgeBlobKey(descriptor.assetID, descriptor.slot));
  }

  if (!result && descriptor.fallbackKeys.length > 0) {
    for (const fallbackKey of descriptor.fallbackKeys) {
      const candidate = await store.getConditionalStream(fallbackKey, readOpts);
      if (candidate) {
        hitKey = fallbackKey;
        result = candidate;
        resolvedViaFallback = true;
        break;
      }
    }
  }

  if (!result) {
    if (descriptor.mediaKind === 'original' && descriptor.canRemoteDownload) {
      // Original not yet in R2 -> let DO download from Google Drive / WebDAV
      return null;
    }
    return edgeJsonResponse(
      request,
      {
        error:
          descriptor.mediaKind === 'thumbnail'
            ? '缩略图不存在。'
            : '原始文件暂未缓存到本地。',
        code:
          descriptor.mediaKind === 'original' && descriptor.cachedOnly
            ? 'NOT_CACHED'
            : 'NOT_FOUND',
      },
      404,
    );
  }

  // Record index backfill / LRU touch asynchronously without delaying the edge media stream
  const shouldRecordKey = !descriptor.keyWasIndexed || resolvedViaFallback;
  const shouldTouchOriginal = descriptor.mediaKind === 'original' && !descriptor.cachedOnly;
  if ((shouldRecordKey || shouldTouchOriginal) && typeof stub.noteEdgeMediaHit === 'function') {
    const totalSize =
      result.status === 'ok'
        ? (result.range?.total ?? result.size)
        : result.status === 'not_modified'
          ? result.size
          : result.total;
    const hitSlot =
      descriptor.mediaKind === 'thumbnail'
        ? inferThumbnailSlotFromKey(hitKey, descriptor.slot)
        : 'original';
    safeWaitUntil(
      ctx,
      stub.noteEdgeMediaHit({
        assetID: descriptor.assetID,
        slot: hitSlot,
        key: hitKey,
        sizeBytes: totalSize,
        contentType: result.contentType || descriptor.contentType,
        recordKey: shouldRecordKey,
        touchOriginal: shouldTouchOriginal,
      }),
    );
  }

  if (method === 'HEAD' && result.status === 'ok') {
    await result.stream.cancel().catch(() => undefined);
  }

  const response = buildMediaStreamResponse(result, {
    contentType:
      descriptor.mediaKind === 'original'
        ? descriptor.contentType || result.contentType || 'application/octet-stream'
        : result.contentType || descriptor.contentType || 'image/jpeg',
    cacheControl: descriptor.cacheControl,
    fileName: descriptor.fileName,
    download: descriptor.download,
    acceptRanges: descriptor.acceptRanges,
  });

  return applyEdgeSecurityAndCorsHeaders(request, response);
}

async function handleEdgeMultipartPartUpload(
  request: Request,
  url: URL,
  stub: DurableObjectStub<CharkleLibraryDO>,
  env: CharkleWorkerEnv,
): Promise<Response | null> {
  if (request.method.toUpperCase() !== 'PUT') return null;
  const match = MULTIPART_PART_RE.exec(url.pathname);
  if (!match) return null;

  if (
    !env.MEDIA_BUCKET ||
    typeof stub.authorizeEdgeMultipartPart !== 'function' ||
    typeof stub.recordEdgeMultipartPart !== 'function'
  ) {
    return null;
  }

  const sessionID = decodeURIComponent(match[1] ?? '');
  const partNumber = Number.parseInt(match[2] ?? '', 10);

  const auth = await stub.authorizeEdgeMultipartPart({
    sessionID,
    partNumber,
    authHeader: request.headers.get('authorization'),
    cookieHeader: request.headers.get('cookie'),
  });

  if (auth.kind === 'error') {
    return edgeJsonResponse(request, { error: auth.error, code: auth.code }, auth.status);
  }

  if (!request.body) {
    return edgeJsonResponse(
      request,
      { error: '上传分片内容为空。', code: 'EMPTY_PART' },
      400,
    );
  }

  const contentLengthHeader = request.headers.get('content-length');
  const parsedSize = contentLengthHeader ? Number.parseInt(contentLengthHeader, 10) : NaN;
  const knownSize = Number.isFinite(parsedSize) && parsedSize >= 0 ? parsedSize : undefined;

  const store = new R2BlobStore(env.MEDIA_BUCKET);
  const uploaded = await store.uploadMultipartPart(
    auth.blobKey,
    auth.uploadId,
    auth.partNumber,
    request.body as ReadableStream<Uint8Array>,
    { size: knownSize },
  );

  await stub.recordEdgeMultipartPart({
    sessionID: auth.sessionID,
    partNumber: uploaded.partNumber,
    etag: uploaded.etag,
    size: uploaded.size,
  });

  return edgeJsonResponse(request, uploaded, 200);
}

export default {
  async fetch(
    request: Request,
    env: CharkleWorkerEnv,
    ctx: ExecutionContext,
  ): Promise<Response> {
    const url = new URL(request.url);
    if (url.pathname === '/api' || url.pathname.startsWith('/api/')) {
      const libraryId = env.CHARKLE_LIBRARY_ID?.trim() || 'default';
      const id = env.CHARKLE_LIBRARY.idFromName(libraryId);
      const stub = env.CHARKLE_LIBRARY.get(id);

      const edgeMediaResponse = await handleEdgeMediaRead(request, url, stub, env, ctx);
      if (edgeMediaResponse) {
        return edgeMediaResponse;
      }

      const edgePartResponse = await handleEdgeMultipartPartUpload(request, url, stub, env);
      if (edgePartResponse) {
        return edgePartResponse;
      }

      return stub.fetch(request);
    }

    return env.ASSETS.fetch(request);
  },
} satisfies ExportedHandler<CharkleWorkerEnv>;
