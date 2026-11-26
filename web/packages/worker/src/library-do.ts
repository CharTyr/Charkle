import { DurableObject } from 'cloudflare:workers';
import { toSwiftUUID, type ThumbnailTier, type UUID } from '@charkle/shared';
import {
  MULTIPART_UPLOAD_MAX_PARTS,
  MULTIPART_UPLOAD_STATE_PREFIX,
  createCoreApp,
  createRuntimeContext,
  WorkersImageProcessor,
  type AuthenticatedPrincipal,
  type BlobIndexSlot,
  type CloudflareImagesBinding,
  type CloudflareImagesTransformResult,
  type PersistedMultipartUploadSession,
  type RuntimeEnv,
  type ServerContext,
} from '@charkle/server/worker';
import { DurableObjectSqlDatabase } from './do-sql.js';
import type { CharkleWorkerEnv } from './env.js';
import { createBundledAssets } from './generated/bundles.js';
import { R2BlobStore } from './r2-blob.js';

const MIN_AUTO_SYNC_INTERVAL_MS = 15_000;

interface InitializedRuntime {
  serverCtx: ServerContext;
  app: ReturnType<typeof createCoreApp>;
}

export interface EdgeMediaReadRequest {
  kind: 'thumbnail' | 'original';
  id: string;
  tier?: ThumbnailTier;
  cachedOnly?: boolean;
  download?: boolean;
  authHeader?: string | null;
  cookieHeader?: string | null;
}

export type EdgeMediaReadDescriptor =
  | {
      kind: 'error';
      status: 401 | 403 | 404;
      code: string;
      error: string;
    }
  | {
      kind: 'fallbackToDO';
    }
  | {
      kind: 'stream';
      mediaKind: 'thumbnail' | 'original';
      assetID: UUID;
      slot: BlobIndexSlot;
      key: string;
      fallbackKeys: string[];
      keyWasIndexed: boolean;
      contentType: string;
      cacheControl: string;
      fileName?: string;
      download: boolean;
      acceptRanges: boolean;
      cachedOnly: boolean;
      canRemoteDownload: boolean;
    };

export interface EdgeMediaHitReport {
  assetID: UUID;
  slot: BlobIndexSlot;
  key: string;
  sizeBytes: number;
  contentType?: string;
  recordKey: boolean;
  touchOriginal: boolean;
}

export interface EdgeMultipartPartAuthRequest {
  sessionID: string;
  partNumber: number;
  authHeader?: string | null;
  cookieHeader?: string | null;
}

export type EdgeMultipartPartAuthResult =
  | {
      kind: 'error';
      status: 400 | 401 | 403 | 404;
      code: string;
      error: string;
    }
  | {
      kind: 'ok';
      sessionID: UUID;
      blobKey: string;
      uploadId: string;
      partNumber: number;
    };

function parseCookieHeaderValue(cookieHeader: string | null | undefined, name: string): string | null {
  if (!cookieHeader) return null;
  for (const part of cookieHeader.split(';')) {
    const idx = part.indexOf('=');
    if (idx <= 0) continue;
    const k = part.slice(0, idx).trim();
    if (k === name) {
      const raw = part.slice(idx + 1).trim();
      try {
        return decodeURIComponent(raw);
      } catch {
        return raw;
      }
    }
  }
  return null;
}

function authenticateEdgeRequest(
  serverCtx: ServerContext,
  authHeader: string | null | undefined,
  cookieHeader: string | null | undefined,
  requiredScope: 'read' | 'write',
): { ok: true; principal: AuthenticatedPrincipal } | { ok: false; status: 401 | 403; code: string; error: string } {
  let principal: AuthenticatedPrincipal | null = null;

  if (authHeader && authHeader.toLowerCase().startsWith('bearer ')) {
    const token = authHeader.slice(7).trim();
    principal = serverCtx.auth.verifyApiToken(token);
  }
  if (!principal) {
    const sessionCookie = parseCookieHeaderValue(cookieHeader, serverCtx.auth.sessionCookieName);
    if (sessionCookie) {
      principal = serverCtx.auth.verifySessionToken(sessionCookie);
    }
  }

  if (!principal) {
    return {
      ok: false,
      status: 401,
      code: 'UNAUTHORIZED',
      error: '未登录或登录已过期，请先登录 Charkle。',
    };
  }

  if (principal.authType === 'token') {
    const scopes = principal.scopes ?? [];
    if (!scopes.includes(requiredScope)) {
      return {
        ok: false,
        status: 403,
        code: 'INSUFFICIENT_SCOPE',
        error: `当前访问令牌缺少 ${requiredScope} 权限。`,
      };
    }
  }

  return { ok: true, principal };
}

function toRuntimeEnv(env: CharkleWorkerEnv): RuntimeEnv {
  const out: RuntimeEnv = {};
  for (const [key, value] of Object.entries(env)) {
    if (typeof value === 'string') {
      out[key] = value;
    }
  }
  return out;
}

function normalizeRotate(rotate?: number): 0 | 90 | 180 | 270 | undefined {
  if (rotate === undefined || !Number.isFinite(rotate)) return undefined;
  const normalized = ((Math.round(rotate / 90) * 90) % 360 + 360) % 360;
  if (normalized === 0 || normalized === 90 || normalized === 180 || normalized === 270) {
    return normalized;
  }
  return undefined;
}

function wrapImageTransformer(transformer: ImageTransformer): CloudflareImagesTransformResult {
  return {
    transform(options) {
      const next = transformer.transform({
        width: options.width,
        height: options.height,
        fit: options.fit,
        background: options.background,
        rotate: normalizeRotate(options.rotate),
      });
      return wrapImageTransformer(next);
    },
    async output(options) {
      const result = await transformer.output({
        format: options.format,
        quality: options.quality,
      });
      return {
        response: () => result.response(),
      };
    },
  };
}

function adaptImagesBinding(binding?: ImagesBinding): CloudflareImagesBinding | null {
  if (!binding) return null;
  return {
    async info(stream) {
      const info = await binding.info(stream);
      if ('width' in info && 'height' in info) {
        return { width: info.width, height: info.height, format: info.format };
      }
      return { format: info.format };
    },
    input(stream) {
      return wrapImageTransformer(binding.input(stream));
    },
  };
}

function isSyncScheduleMutationPath(pathname: string, method: string): boolean {
  if (method === 'GET' && pathname.startsWith('/api/v1/sync/google/') && pathname.endsWith('/callback')) {
    return true;
  }
  if (method === 'PUT' && pathname === '/api/v1/sync/config') {
    return true;
  }
  if (
    method === 'POST' &&
    (pathname === '/api/v1/sync/migrate' || pathname === '/api/v1/sync/google/sign-out')
  ) {
    return true;
  }
  return false;
}

/**
 * Durable Object hosting a Charkle visual reference library backed by
 * Cloudflare DO SQLite (`ctx.storage.sql`) and Cloudflare R2 (`env.MEDIA_BUCKET`).
 *
 * Exposes lightweight RPC methods (`resolveEdgeMediaRead`, `authorizeEdgeMultipartPart`, etc.)
 * so the stateless outer edge Worker streams media and multipart chunks directly against R2
 * without occupying DO memory or wall-clock duration.
 */
export class CharkleLibraryDO extends DurableObject<CharkleWorkerEnv> {
  private runtime: InitializedRuntime | null = null;
  private initPromise: Promise<InitializedRuntime> | null = null;

  constructor(ctx: DurableObjectState, env: CharkleWorkerEnv) {
    super(ctx, env);
  }

  private async ensureInitialized(): Promise<InitializedRuntime> {
    if (this.runtime) {
      return this.runtime;
    }
    if (!this.initPromise) {
      this.initPromise = this.ctx
        .blockConcurrencyWhile(async () => {
          const sql = new DurableObjectSqlDatabase(this.ctx.storage);
          const blobs = new R2BlobStore(this.env.MEDIA_BUCKET);
          const images = new WorkersImageProcessor({
            imagesBinding: adaptImagesBinding(this.env.IMAGES),
          });
          const bundles = createBundledAssets();
          const runtimeEnv = toRuntimeEnv(this.env);

          const serverCtx = await createRuntimeContext({
            runtimeMode: 'cloudflare',
            sql,
            blobs,
            images,
            bundles,
            vaultSecret: this.env.CHARKLE_VAULT_KEY,
            env: runtimeEnv,
            autoSeed: true,
          });
          const app = createCoreApp(serverCtx);

          await this.reconcileAutoSyncAlarm(serverCtx, false);

          const initialized: InitializedRuntime = { serverCtx, app };
          this.runtime = initialized;
          return initialized;
        })
        .catch((err) => {
          // Clear failed promise so subsequent requests can retry cleanly
          this.initPromise = null;
          throw err;
        });
    }
    return this.initPromise;
  }

  private async reconcileAutoSyncAlarm(
    serverCtx: ServerContext,
    forceReschedule: boolean,
  ): Promise<void> {
    const syncConfig = serverCtx.configStore.getSyncConfig();
    const shouldSchedule =
      (syncConfig.mode === 'directAPIWithGDirect' || syncConfig.mode === 'webDAV') &&
      syncConfig.autoSyncIntervalSeconds > 0;

    const existingAlarm = await this.ctx.storage.getAlarm();
    if (!shouldSchedule) {
      if (existingAlarm !== null) {
        await this.ctx.storage.deleteAlarm();
      }
      return;
    }

    const intervalMs = Math.max(
      MIN_AUTO_SYNC_INTERVAL_MS,
      Math.round(syncConfig.autoSyncIntervalSeconds * 1000),
    );
    const targetTime = Date.now() + intervalMs;
    if (forceReschedule || existingAlarm === null || existingAlarm > targetTime + 5_000) {
      await this.ctx.storage.setAlarm(targetTime);
    }
  }

  // MARK: - Lightweight Edge Worker RPCs (Zero R2 Streaming Inside DO)

  async resolveEdgeMediaRead(req: EdgeMediaReadRequest): Promise<EdgeMediaReadDescriptor> {
    const { serverCtx } = await this.ensureInitialized();
    const authResult = authenticateEdgeRequest(
      serverCtx,
      req.authHeader,
      req.cookieHeader,
      'read',
    );
    if (!authResult.ok) {
      return {
        kind: 'error',
        status: authResult.status,
        code: authResult.code,
        error: authResult.error,
      };
    }

    if (req.kind === 'thumbnail') {
      const tier: ThumbnailTier = req.tier === 'preview1400' ? 'preview1400' : 'grid520';
      const normalizedID = toSwiftUUID(req.id);
      const hint = serverCtx.media.resolveThumbnailKeyHint(normalizedID, tier);
      const indexedEntry = serverCtx.db.getBlobIndexEntry(normalizedID, tier);
      const gridFallbackHit =
        !indexedEntry && tier === 'preview1400' && serverCtx.db.isBlobIndexHydrated()
          ? serverCtx.db.getBlobIndexEntry(normalizedID, 'grid520')
          : null;
      const effectiveSlot: BlobIndexSlot = gridFallbackHit ? 'grid520' : tier;

      return {
        kind: 'stream',
        mediaKind: 'thumbnail',
        assetID: normalizedID,
        slot: effectiveSlot,
        key: hint.key,
        fallbackKeys: hint.fallbackKeys,
        keyWasIndexed: Boolean(indexedEntry || gridFallbackHit),
        contentType: hint.contentType || 'image/jpeg',
        cacheControl: 'private, max-age=3600',
        download: false,
        acceptRanges: false,
        cachedOnly: false,
        canRemoteDownload: false,
      };
    }

    const asset = serverCtx.db.getAsset(req.id);
    if (!asset) {
      return {
        kind: 'error',
        status: 404,
        code: 'NOT_FOUND',
        error: '素材不存在。',
      };
    }

    const cachedOnly = Boolean(req.cachedOnly);
    const canRemoteDownload = !cachedOnly && Boolean(asset.driveFileID);
    const hint = serverCtx.media.resolveOriginalKeyHint(asset);

    // If blob_index is hydrated and original isn't indexed locally, hand off directly to DO sync download
    if (!hint.indexed && serverCtx.db.isBlobIndexHydrated()) {
      if (canRemoteDownload) {
        return { kind: 'fallbackToDO' };
      }
      if (cachedOnly) {
        return {
          kind: 'error',
          status: 404,
          code: 'NOT_CACHED',
          error: '原始文件暂未缓存到本地。',
        };
      }
    }

    return {
      kind: 'stream',
      mediaKind: 'original',
      assetID: asset.id,
      slot: 'original',
      key: hint.key,
      fallbackKeys: [],
      keyWasIndexed: hint.indexed,
      contentType: asset.mimeType || 'application/octet-stream',
      cacheControl: 'private, max-age=600',
      fileName: asset.fileName,
      download: Boolean(req.download),
      acceptRanges: true,
      cachedOnly,
      canRemoteDownload,
    };
  }

  async noteEdgeMediaHit(report: EdgeMediaHitReport): Promise<void> {
    const { serverCtx } = await this.ensureInitialized();
    if (report.recordKey) {
      serverCtx.media.recordBlobKey(
        report.assetID,
        report.slot,
        report.key,
        report.sizeBytes,
        report.contentType,
      );
    }
    if (report.touchOriginal) {
      serverCtx.db.touchOriginal(report.assetID);
    }
  }

  async invalidateEdgeBlobKey(assetID: UUID, slot: BlobIndexSlot): Promise<void> {
    const { serverCtx } = await this.ensureInitialized();
    serverCtx.media.invalidateBlobKey(assetID, slot);
  }

  async authorizeEdgeMultipartPart(
    req: EdgeMultipartPartAuthRequest,
  ): Promise<EdgeMultipartPartAuthResult> {
    const { serverCtx } = await this.ensureInitialized();
    const authResult = authenticateEdgeRequest(
      serverCtx,
      req.authHeader,
      req.cookieHeader,
      'write',
    );
    if (!authResult.ok) {
      return {
        kind: 'error',
        status: authResult.status,
        code: authResult.code,
        error: authResult.error,
      };
    }

    const partNumber = Math.trunc(req.partNumber);
    if (!Number.isFinite(partNumber) || partNumber < 1 || partNumber > MULTIPART_UPLOAD_MAX_PARTS) {
      return {
        kind: 'error',
        status: 400,
        code: 'INVALID_PART_NUMBER',
        error: '分片编号无效（有效范围 1–10000）。',
      };
    }

    const sessionID = toSwiftUUID(req.sessionID);
    const session = serverCtx.db.getState<PersistedMultipartUploadSession>(
      `${MULTIPART_UPLOAD_STATE_PREFIX}${sessionID}`,
    );
    if (!session) {
      return {
        kind: 'error',
        status: 404,
        code: 'UPLOAD_SESSION_NOT_FOUND',
        error: '分片上传会话不存在或已过期。',
      };
    }

    return {
      kind: 'ok',
      sessionID,
      blobKey: session.blobKey,
      uploadId: session.uploadId,
      partNumber,
    };
  }

  async recordEdgeMultipartPart(params: {
    sessionID: UUID;
    partNumber: number;
    etag: string;
    size: number;
  }): Promise<void> {
    const { serverCtx } = await this.ensureInitialized();
    const stateKey = `${MULTIPART_UPLOAD_STATE_PREFIX}${toSwiftUUID(params.sessionID)}`;
    const session = serverCtx.db.getState<PersistedMultipartUploadSession>(stateKey);
    if (!session) return;
    session.parts[String(params.partNumber)] = {
      partNumber: params.partNumber,
      etag: params.etag,
      size: params.size,
    };
    serverCtx.db.setState(stateKey, session);
  }

  // MARK: - HTTP & Alarm Entrypoints

  override async fetch(request: Request): Promise<Response> {
    const { app, serverCtx } = await this.ensureInitialized();
    const url = new URL(request.url);
    const response = await app.fetch(request);

    if (isSyncScheduleMutationPath(url.pathname, request.method)) {
      await this.reconcileAutoSyncAlarm(serverCtx, true).catch((err) => {
        console.error(
          JSON.stringify({
            event: 'charkle.alarm.reconcile_failed',
            path: url.pathname,
            error: err instanceof Error ? err.message : String(err),
          }),
        );
      });
    }

    return response;
  }

  override async alarm(): Promise<void> {
    const { serverCtx } = await this.ensureInitialized();
    const syncConfig = serverCtx.configStore.getSyncConfig();
    const shouldRun =
      (syncConfig.mode === 'directAPIWithGDirect' || syncConfig.mode === 'webDAV') &&
      syncConfig.autoSyncIntervalSeconds > 0;

    if (!shouldRun) {
      await this.ctx.storage.deleteAlarm();
      return;
    }

    try {
      const { report } = await serverCtx.sync.syncNow();
      console.log(
        JSON.stringify({
          event: 'charkle.alarm.sync_completed',
          mode: syncConfig.mode,
          uploadedOps: report.uploadedOps,
          downloadedOps: report.downloadedOps,
          discoveredRemoteAssets: report.discoveredRemoteAssets,
          durationSeconds: report.durationSeconds,
        }),
      );
    } catch (err) {
      // Catch unauthenticated / transient network errors so the alarm does not tight-loop retry
      console.error(
        JSON.stringify({
          event: 'charkle.alarm.sync_failed',
          mode: syncConfig.mode,
          error: err instanceof Error ? err.message : String(err),
        }),
      );
    } finally {
      await serverCtx.secretVault.flush().catch(() => undefined);
      await this.reconcileAutoSyncAlarm(serverCtx, true).catch((err) => {
        console.error(
          JSON.stringify({
            event: 'charkle.alarm.reschedule_failed',
            error: err instanceof Error ? err.message : String(err),
          }),
        );
      });
    }
  }
}
