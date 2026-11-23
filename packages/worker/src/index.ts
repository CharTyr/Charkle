import type { CharkleWorkerEnv } from './env.js';

export { CharkleLibraryDO } from './library-do.js';

export default {
  async fetch(
    request: Request,
    env: CharkleWorkerEnv,
    _ctx: ExecutionContext,
  ): Promise<Response> {
    const url = new URL(request.url);
    if (url.pathname === '/api' || url.pathname.startsWith('/api/')) {
      const libraryId = env.CHARKLE_LIBRARY_ID?.trim() || 'default';
      const id = env.CHARKLE_LIBRARY.idFromName(libraryId);
      const stub = env.CHARKLE_LIBRARY.get(id);
      return stub.fetch(request);
    }

    return env.ASSETS.fetch(request);
  },
} satisfies ExportedHandler<CharkleWorkerEnv>;
