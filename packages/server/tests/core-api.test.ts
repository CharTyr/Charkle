import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { afterEach, describe, expect, it } from 'vitest';
import { createDefaultSmartFolderRule } from '@charkle/shared';
import { createApp, createServerContext } from '../src/app.js';

const tempDirs: string[] = [];

function createApiTestRig() {
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'charkle-api-test-'));
  tempDirs.push(dir);
  const ctx = createServerContext({ dataDir: dir, vaultSecret: 'api-test-secret' });
  const app = createApp(ctx, { staticClientDir: null });
  return { dir, ctx, app };
}

afterEach(() => {
  while (tempDirs.length > 0) {
    const dir = tempDirs.pop()!;
    fs.rmSync(dir, { recursive: true, force: true });
  }
});

describe('Core REST + SSE API end-to-end', () => {
  it('supports folders, smart folders, ingest, boards CRUD, quick jump, cache budget, and sync config', async () => {
    const { ctx, app } = createApiTestRig();
    try {
      // Setup & authenticate
      const setup = await app.request('/api/v1/auth/setup', {
        method: 'POST',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify({ username: 'studio', password: 'studio-password-123' }),
      });
      expect(setup.status).toBe(201);
      const cookie = (setup.headers.get('set-cookie') ?? '').split(';')[0];
      const headers = { 'Content-Type': 'application/json', Cookie: cookie };

      // Create nested folders + customize appearance
      const f1 = (await (
        await app.request('/api/v1/folders', {
          method: 'POST',
          headers,
          body: JSON.stringify({ name: 'Editorial' }),
        })
      ).json()) as { folder: { id: string; name: string } };
      expect(f1.folder.name).toBe('Editorial');

      const f2 = (await (
        await app.request('/api/v1/folders', {
          method: 'POST',
          headers,
          body: JSON.stringify({ name: 'Covers', parentID: f1.folder.id }),
        })
      ).json()) as { folder: { id: string; parentID: string } };
      expect(f2.folder.parentID).toBe(f1.folder.id);

      const appRes = (await (
        await app.request(`/api/v1/folders/${f1.folder.id}/appearance`, {
          method: 'PATCH',
          headers,
          body: JSON.stringify({ colorHex: '#FF9F0A', customSymbol: 'emoji:🎨' }),
        })
      ).json()) as { folder: { colorHex: string; customSymbol: string } };
      expect(appRes.folder.colorHex).toBe('#FF9F0A');
      expect(appRes.folder.customSymbol).toBe('emoji:🎨');

      // Ingest color swatch + markdown snippet into child folder
      const ingRes = (await (
        await app.request('/api/v1/assets/ingest', {
          method: 'POST',
          headers,
          body: JSON.stringify({
            targetFolderID: f2.folder.id,
            inputs: [
              { type: 'colorSwatch', hex: '#D4A373', title: 'Warm Ochre' },
              { type: 'textSnippet', title: '排版原则', text: '# 网格系统\n\n对齐与留白。' },
            ],
          }),
        })
      ).json()) as { assets: Array<{ id: string; title: string }> };
      expect(ingRes.assets).toHaveLength(2);

      // Recursive folder query from parent returns both child assets
      const queryRes = (await (
        await app.request('/api/v1/assets/query', {
          method: 'POST',
          headers,
          body: JSON.stringify({
            criteria: { folderID: f1.folder.id, includeSubfolders: true },
          }),
        })
      ).json()) as { assets: unknown[]; total: number };
      expect(queryRes.total).toBe(2);

      // Batch patch rating & tag
      const batchRes = (await (
        await app.request('/api/v1/assets/batch', {
          method: 'PATCH',
          headers,
          body: JSON.stringify({
            assetIDs: [ingRes.assets[0].id],
            rating: 5,
            addTags: ['featured'],
            removeTags: [],
            acceptSuggestedTags: false,
            dismissSuggestedTags: [],
            folderAssignment: { type: 'unchanged' },
          }),
        })
      ).json()) as { assets: Array<{ rating: number; tags: string[] }> };
      expect(batchRes.assets[0].rating).toBe(5);
      expect(batchRes.assets[0].tags).toContain('featured');

      // Smart folder save + query by smartFolderID
      const sfRes = (await (
        await app.request('/api/v1/smart-folders', {
          method: 'PUT',
          headers,
          body: JSON.stringify({
            name: '5星精选',
            rule: createDefaultSmartFolderRule({ minRating: 5 }),
          }),
        })
      ).json()) as { smartFolders: Array<{ id: string }> };
      const sfID = sfRes.smartFolders[0].id;
      const sfQuery = (await (
        await app.request('/api/v1/assets/query', {
          method: 'POST',
          headers,
          body: JSON.stringify({ smartFolderID: sfID }),
        })
      ).json()) as { assets: Array<{ id: string }>; total: number };
      expect(sfQuery.total).toBe(1);
      expect(sfQuery.assets[0].id).toBe(ingRes.assets[0].id);

      // Create & update moodboard
      const boardRes = (await (
        await app.request('/api/v1/boards', {
          method: 'POST',
          headers,
          body: JSON.stringify({
            title: 'Autumn Editorial',
            seedAssetIDs: [ingRes.assets[0].id],
          }),
        })
      ).json()) as { board: { id: string; title: string; nodes: unknown[] } };
      expect(boardRes.board.nodes).toHaveLength(1);

      // Quick jump finds Chinese pinyin match for 排版原则
      const jumpRes = (await (
        await app.request('/api/v1/library/quick-jump?q=paiban', {
          headers: { Cookie: cookie },
        })
      ).json()) as { matches: Array<{ title: string }> };
      expect(jumpRes.matches.some((m) => m.title === '排版原则')).toBe(true);

      // Cache budget update & stats
      const cacheRes = (await (
        await app.request('/api/v1/cache/budget', {
          method: 'PUT',
          headers,
          body: JSON.stringify({ budgetBytes: 4 * 1024 * 1024 * 1024 }),
        })
      ).json()) as { stats: { budgetBytes: number } };
      expect(cacheRes.stats.budgetBytes).toBe(4 * 1024 * 1024 * 1024);

      // Sync config GET
      const syncCfg = (await (
        await app.request('/api/v1/sync/config', { headers: { Cookie: cookie } })
      ).json()) as { config: { mode: string }; activeLocationSummary: string };
      expect(syncCfg.config.mode).toBe('localOnly');
      expect(syncCfg.activeLocationSummary.length).toBeGreaterThan(0);

      // SSE /api/v1/events streams initial sync.status + live library.changed event
      const abort = new AbortController();
      const sseRes = await app.request('/api/v1/events', {
        headers: { Cookie: cookie },
        signal: abort.signal,
      });
      expect(sseRes.status).toBe(200);
      expect(sseRes.headers.get('content-type')).toContain('text/event-stream');
      const reader = sseRes.body!.getReader();
      const firstChunk = await reader.read();
      const text1 = new TextDecoder().decode(firstChunk.value);
      expect(text1).toContain('event: sync.status');
      ctx.events.emitLibraryChanged('test-ping');
      const secondChunk = await reader.read();
      const text2 = new TextDecoder().decode(secondChunk.value);
      expect(text2).toContain('event: library.changed');
      abort.abort();
      await reader.cancel().catch(() => undefined);
    } finally {
      ctx.db.close();
    }
  });
});
