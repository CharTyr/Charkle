import { DurableObject } from 'cloudflare:workers';
import {
  createCoreApp,
  createRuntimeContext,
  WorkersImageProcessor,
  type CloudflareImagesBinding,
  type CloudflareImagesTransformResult,
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
