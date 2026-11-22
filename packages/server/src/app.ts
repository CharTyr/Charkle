import fs from 'node:fs';
import fsp from 'node:fs/promises';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import { Hono } from 'hono';
import { EventBus } from './api/events.js';
import {
  createAuthMiddleware,
  createSecurityHeadersMiddleware,
  type AppVariables,
} from './api/middleware-auth.js';
import { registerAIRoutes, type AIRouteOptions } from './api/routes-ai.js';
import { registerCoreRoutes } from './api/routes-core.js';
import { AuthService } from './auth/auth-service.js';
import { LoginRateLimiter } from './auth/rate-limiter.js';
import type { ServerContext } from './context.js';
import { LibraryDatabase } from './db/library-database.js';
import { guessMimeType, MediaPipeline } from './media/media-pipeline.js';
import { ConfigStore } from './storage/config-store.js';
import { SecretVault } from './storage/secret-vault.js';
import type { DriveTransport } from './sync/drive-transport.js';
import { DriveSyncEngine } from './sync/drive-sync-engine.js';

export const SERVER_DEFAULT_PORT = 3417;

export interface CreateServerContextOptions {
  dataDir?: string;
  dbPath?: string;
  vaultSecret?: string;
  transportOverride?: DriveTransport;
}

export function createServerContext(options: CreateServerContextOptions = {}): ServerContext {
  const dataDir = path.resolve(
    options.dataDir ??
      process.env.CHARKLE_DATA_DIR ??
      path.resolve(process.cwd(), '.charkle-data'),
  );
  fs.mkdirSync(dataDir, { recursive: true });

  const dbPath = options.dbPath ?? path.join(dataDir, 'charkle.sqlite');
  const db = new LibraryDatabase(dbPath);
  const configStore = new ConfigStore(dataDir);
  const secretVault = new SecretVault(dataDir, options.vaultSecret);
  const events = new EventBus();
  const media = new MediaPipeline(path.join(dataDir, 'media'), configStore.getCacheBudgetBytes());
  const auth = new AuthService(db);
  auth.bootstrapFromEnv();

  const sync = new DriveSyncEngine({
    db,
    media,
    configStore,
    secretVault,
    events,
    transportOverride: options.transportOverride,
  });

  return {
    db,
    media,
    sync,
    configStore,
    secretVault,
    auth,
    events,
    dataDir,
  };
}

export type AIRoutesRegistrar = (
  app: Hono<{ Variables: AppVariables }>,
  ctx: ServerContext,
) => void;

export interface CreateAppOptions {
  rateLimiter?: LoginRateLimiter;
  staticClientDir?: string | null;
  registerAI?: AIRoutesRegistrar | false;
  aiOptions?: AIRouteOptions;
}

const STATIC_MIME_MAP: Record<string, string> = {
  '.html': 'text/html; charset=utf-8',
  '.js': 'application/javascript; charset=utf-8',
  '.mjs': 'application/javascript; charset=utf-8',
  '.css': 'text/css; charset=utf-8',
  '.json': 'application/json; charset=utf-8',
  '.svg': 'image/svg+xml',
  '.png': 'image/png',
  '.jpg': 'image/jpeg',
  '.jpeg': 'image/jpeg',
  '.webp': 'image/webp',
  '.ico': 'image/x-icon',
  '.woff': 'font/woff',
  '.woff2': 'font/woff2',
  '.ttf': 'font/ttf',
  '.map': 'application/json',
};

function defaultStaticClientDir(): string {
  const here = path.dirname(fileURLToPath(import.meta.url));
  return path.resolve(here, '../../client/dist');
}

function registerStaticClient(app: Hono<{ Variables: AppVariables }>, clientDir: string): void {
  const resolvedRoot = path.resolve(clientDir);
  const indexPath = path.join(resolvedRoot, 'index.html');

  app.get('*', async (c) => {
    const pathname = new URL(c.req.url).pathname;
    if (pathname.startsWith('/api/')) {
      return c.json({ error: 'API 端点不存在。', code: 'NOT_FOUND' }, 404);
    }

    if (!fs.existsSync(resolvedRoot)) {
      return c.text('Charkle Server is running. Build packages/client to serve the Web UI.', 200);
    }

    const decoded = decodeURIComponent(pathname).replace(/^\/+/, '');
    const candidate = path.resolve(resolvedRoot, decoded);
    if (
      decoded.length > 0 &&
      candidate.startsWith(resolvedRoot + path.sep) &&
      fs.existsSync(candidate) &&
      fs.statSync(candidate).isFile()
    ) {
      const ext = path.extname(candidate).toLowerCase();
      const mime = STATIC_MIME_MAP[ext] ?? guessMimeType(candidate);
      const buf = await fsp.readFile(candidate);
      const isHashedAsset = pathname.startsWith('/assets/');
      return new Response(new Uint8Array(buf), {
        status: 200,
        headers: {
          'Content-Type': mime,
          'Content-Length': String(buf.length),
          'Cache-Control': isHashedAsset
            ? 'public, max-age=31536000, immutable'
            : 'public, max-age=300',
        },
      });
    }

    if (fs.existsSync(indexPath)) {
      const html = await fsp.readFile(indexPath, 'utf8');
      return c.html(html, 200);
    }

    return c.notFound();
  });
}

export function createApp(
  ctx: ServerContext,
  options: CreateAppOptions = {},
): Hono<{ Variables: AppVariables }> {
  const app = new Hono<{ Variables: AppVariables }>();

  app.use('*', createSecurityHeadersMiddleware());
  app.use('/api/v1/*', createAuthMiddleware(ctx));

  if (typeof options.registerAI === 'function') {
    options.registerAI(app, ctx);
  } else if (options.registerAI !== false) {
    registerAIRoutes(app, ctx, options.aiOptions);
  }
  registerCoreRoutes(app, ctx, { rateLimiter: options.rateLimiter });

  if (options.staticClientDir !== null) {
    registerStaticClient(app, options.staticClientDir ?? defaultStaticClientDir());
  }

  return app;
}
