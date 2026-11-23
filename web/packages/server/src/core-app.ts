import { Hono } from 'hono';
import type { RuntimeFeatures, RuntimeMode } from '@charkle/shared';
import { EventBus } from './api/events.js';
import {
  createAuthMiddleware,
  createExtensionCorsMiddleware,
  createSecurityHeadersMiddleware,
  type AppVariables,
} from './api/middleware-auth.js';
import { registerAIRoutes, type AIRouteOptions } from './api/routes-ai.js';
import { registerCoreRoutes } from './api/routes-core.js';
import { AuthService } from './auth/auth-service.js';
import { LoginRateLimiter } from './auth/rate-limiter.js';
import type { ServerContext } from './context.js';
import { LibraryDatabase } from './db/library-database.js';
import { MediaPipeline } from './media/media-pipeline.js';
import { seedSampleLibrary } from './media/sample-seeder.js';
import type {
  IBlobStore,
  IBundleAssets,
  IImageProcessor,
  IPasswordHasher,
  ISqlDatabase,
  LocalTransportFactory,
  RuntimeEnv,
} from './runtime/types.js';
import { WebCryptoPasswordHasher } from './runtime/web-crypto-hash.js';
import { WorkersImageProcessor } from './runtime/workers-image.js';
import { ConfigStore } from './storage/config-store.js';
import { SecretVault } from './storage/secret-vault.js';
import type { DriveTransport } from './sync/drive-transport.js';
import { DriveSyncEngine } from './sync/drive-sync-engine.js';

export type AIRoutesRegistrar = (
  app: Hono<{ Variables: AppVariables }>,
  ctx: ServerContext,
) => void;

export interface CreateCoreAppOptions {
  rateLimiter?: LoginRateLimiter;
  registerAI?: AIRoutesRegistrar | false;
  aiOptions?: AIRouteOptions;
}

export interface CreateRuntimeContextOptions {
  runtimeMode: RuntimeMode;
  sql: ISqlDatabase;
  blobs: IBlobStore;
  images?: IImageProcessor;
  bundles?: IBundleAssets;
  passwordHasher?: IPasswordHasher;
  /** Optional master secret for AES-256-GCM SecretVault (defaults to `env.CHARKLE_VAULT_KEY` or persisted DB key). */
  vaultSecret?: string;
  /** Optional explicit runtime env map (e.g. Cloudflare Worker `env` bindings). */
  env?: RuntimeEnv;
  /** Logical data directory label (defaults to `':cloudflare:'` on cloudflare, `'.charkle-data'` on node). */
  dataDir?: string;
  /** Optional feature flags override (defaults derived from `runtimeMode`). */
  features?: Partial<RuntimeFeatures>;
  /** Optional override transport for DriveSyncEngine (e.g. InMemoryDriveTransport in tests). */
  transportOverride?: DriveTransport;
  /** Optional factory for localFolder sync transport (Node-only). */
  localTransportFactory?: LocalTransportFactory;
  /** Optional custom fetch function for outbound HTTP (sync / OAuth). */
  fetchFn?: typeof fetch;
  /** Optional Node-only local file reader for `fileURL` ingest. */
  readLocalFile?: (filePath: string) => Promise<Uint8Array>;
  /** Optional Node-only localFs helpers for MCP / `fileURL` ingest. */
  localFs?: ServerContext['localFs'];
  /** Optional pre-created ConfigStore / SecretVault (e.g. Node legacy file migration). */
  configStore?: ConfigStore;
  secretVault?: SecretVault;
  /** Optional auto-seed sample library when DB is empty (default `false`). */
  autoSeed?: boolean;
}

const EMPTY_BUNDLE_ASSETS: IBundleAssets = {
  async getExtensionZip(): Promise<Uint8Array | null> {
    return null;
  },
  async getFigmaPluginZip(): Promise<Uint8Array | null> {
    return null;
  },
};

export function defaultRuntimeFeatures(runtimeMode: RuntimeMode): RuntimeFeatures {
  return {
    localFolder: runtimeMode === 'node',
    clientExportPreferred: runtimeMode === 'cloudflare',
    googleDrive: true,
    webdav: true,
  };
}

/**
 * Runtime-agnostic async factory that builds a complete `ServerContext`
 * backed by any `ISqlDatabase` (Node `DatabaseSync` or Cloudflare Durable Object SQLite)
 * and `IBlobStore` (local filesystem or Cloudflare R2).
 *
 * Strictly free of `node:fs`, `node:sqlite`, `sharp`, or `@hono/node-server` imports.
 */
export async function createRuntimeContext(
  options: CreateRuntimeContextOptions,
): Promise<ServerContext> {
  const runtimeMode = options.runtimeMode;
  const features: RuntimeFeatures = {
    ...defaultRuntimeFeatures(runtimeMode),
    ...(options.features ?? {}),
  };

  const db = new LibraryDatabase(options.sql);
  const configStore = options.configStore ?? new ConfigStore(options.sql);
  const secretVault =
    options.secretVault ??
    (await SecretVault.open(options.sql, {
      masterKeySecret: options.vaultSecret,
      env: options.env,
    }));
  const images = options.images ?? new WorkersImageProcessor();
  const bundles = options.bundles ?? EMPTY_BUNDLE_ASSETS;
  const passwordHasher = options.passwordHasher ?? new WebCryptoPasswordHasher();
  const events = new EventBus();

  const media = new MediaPipeline({
    blobs: options.blobs,
    images,
    cacheBudgetBytes: configStore.getCacheBudgetBytes(),
    readLocalFile: options.readLocalFile,
  });

  const auth = new AuthService(db, passwordHasher);
  await auth.bootstrapFromEnv(options.env);

  const sync = new DriveSyncEngine({
    db,
    media,
    configStore,
    secretVault,
    events,
    transportOverride: options.transportOverride,
    localTransportFactory: options.localTransportFactory,
    runtimeMode,
    env: options.env,
  });

  if (options.autoSeed && db.isEmpty()) {
    await seedSampleLibrary(db, media, false);
  }

  return {
    runtimeMode,
    features,
    db,
    blobs: options.blobs,
    images,
    bundles,
    media,
    sync,
    configStore,
    secretVault,
    auth,
    events,
    dataDir: options.dataDir ?? (runtimeMode === 'cloudflare' ? ':cloudflare:' : '.charkle-data'),
    env: options.env,
    localFs: options.localFs,
  };
}

/**
 * Builds the runtime-agnostic Charkle Hono API app (`/api/v1/*`, `/api/v1/mcp`, SSE `/api/v1/events`).
 * Works identically on Node.js/Docker AND Cloudflare Workers (Durable Object + R2).
 */
export function createCoreApp(
  ctx: ServerContext,
  options: CreateCoreAppOptions = {},
): Hono<{ Variables: AppVariables }> {
  const app = new Hono<{ Variables: AppVariables }>();

  app.use('*', createSecurityHeadersMiddleware());
  app.use('/api/v1/*', createExtensionCorsMiddleware());
  // Ensure any async Web Crypto SecretVault writes are durably persisted to SQLite
  // before the HTTP response finishes (critical for Cloudflare Workers / DO lifetimes).
  app.use('/api/v1/*', async (_c, next) => {
    try {
      await next();
    } finally {
      await ctx.secretVault.flush().catch((err) => {
        console.error('[Charkle] Failed to flush SecretVault:', err);
      });
    }
  });
  app.use('/api/v1/*', createAuthMiddleware(ctx));

  if (typeof options.registerAI === 'function') {
    options.registerAI(app, ctx);
  } else if (options.registerAI !== false) {
    registerAIRoutes(app, ctx, options.aiOptions);
  }
  registerCoreRoutes(app, ctx, { rateLimiter: options.rateLimiter });

  app.all('/api/*', (c) => c.json({ error: 'API 端点不存在。', code: 'NOT_FOUND' }, 404));

  return app;
}
