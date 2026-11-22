import { serve } from '@hono/node-server';
import type { HealthResponse } from '@charkle/shared';
import { createApp, createServerContext, SERVER_DEFAULT_PORT } from './app.js';
import { seedSampleLibrary } from './media/sample-seeder.js';

export { createApp, createServerContext, SERVER_DEFAULT_PORT } from './app.js';
export type { ServerContext } from './context.js';
export { LibraryDatabase } from './db/library-database.js';
export { MediaPipeline } from './media/media-pipeline.js';
export { DriveSyncEngine } from './sync/drive-sync-engine.js';
export { AuthService } from './auth/auth-service.js';
export { ConfigStore } from './storage/config-store.js';
export { SecretVault, SECRET_KEYS } from './storage/secret-vault.js';
export { EventBus } from './api/events.js';

export function createPlaceholderHealth(): HealthResponse {
  return {
    ok: true,
    version: '1.0.0',
    timestamp: new Date().toISOString(),
  };
}

async function startServer(): Promise<void> {
  const port = Number.parseInt(process.env.CHARKLE_PORT ?? String(SERVER_DEFAULT_PORT), 10) || SERVER_DEFAULT_PORT;
  const hostname = process.env.CHARKLE_HOST ?? '127.0.0.1';
  const ctx = createServerContext();

  if (process.env.CHARKLE_AUTO_SEED !== 'false' && ctx.db.isEmpty()) {
    await seedSampleLibrary(ctx.db, ctx.media, false).catch((err) => {
      console.error('[Charkle] Failed to seed sample library:', err);
    });
  }

  const app = createApp(ctx);
  ctx.sync.startAutoSync();

  const server = serve(
    {
      fetch: app.fetch,
      hostname,
      port,
    },
    (info) => {
      console.log(`[Charkle] Server listening on http://${info.address}:${info.port}`);
      console.log(`[Charkle] Data directory: ${ctx.dataDir}`);
      if (!ctx.auth.isInitialized()) {
        console.log('[Charkle] First launch detected — open the Web UI to initialize your admin account.');
      }
    },
  );

  const shutdown = () => {
    ctx.sync.stopAutoSync();
    server.close();
    ctx.db.close();
    process.exit(0);
  };
  process.on('SIGINT', shutdown);
  process.on('SIGTERM', shutdown);
}

const isDirectExecution =
  typeof process !== 'undefined' &&
  process.argv[1] &&
  (process.argv[1].endsWith('/src/index.ts') ||
    process.argv[1].endsWith('/dist/index.js') ||
    process.argv[1].endsWith('\\src\\index.ts') ||
    process.argv[1].endsWith('\\dist\\index.js'));

if (isDirectExecution) {
  startServer().catch((err) => {
    console.error('[Charkle] Fatal startup error:', err);
    process.exit(1);
  });
}
