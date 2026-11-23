import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import JSZip from 'jszip';
import sharp from 'sharp';
import { afterEach, describe, expect, it, vi } from 'vitest';
import {
  createDefaultMoodboardCurationRequest,
  toSwiftUUID,
  type BoardNode,
  type MoodboardDocument,
} from '@charkle/shared';
import { createApp, createServerContext } from '../src/app.js';
import { MoodboardAgentHarness } from '../src/intelligence/moodboard-agent-harness.js';
import { MoodboardCurator } from '../src/intelligence/moodboard-curator.js';
import { seedSampleLibrary } from '../src/media/sample-seeder.js';

const tempDirs: string[] = [];

function makeTempDir(prefix = 'charkle-delta-ext-'): string {
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), prefix));
  tempDirs.push(dir);
  return dir;
}

async function createRig() {
  const dir = makeTempDir();
  const ctx = createServerContext({ dataDir: dir, vaultSecret: 'delta-test-secret' });
  const app = createApp(ctx, { staticClientDir: null });
  const user = await ctx.auth.setupAdmin('admin', 'strong-password-123');
  const pat = ctx.auth.createApiToken(user.id, 'clipper-pat', ['read', 'write', 'mcp']);
  return { dir, ctx, app, user, pat };
}

async function makePng(width: number, height: number, rgb: [number, number, number]): Promise<Buffer> {
  return sharp({
    create: {
      width,
      height,
      channels: 3,
      background: { r: rgb[0], g: rgb[1], b: rgb[2] },
    },
  })
    .png()
    .toBuffer();
}

function rectsOverlap(
  a: BoardNode['frame'],
  b: BoardNode['frame'],
  epsilon = 0.5,
): boolean {
  return (
    a.x + epsilon < b.x + b.width &&
    a.x + a.width > b.x + epsilon &&
    a.y + epsilon < b.y + b.height &&
    a.y + a.height > b.y + epsilon
  );
}

function assertNoOverlaps(nodes: readonly BoardNode[]): void {
  for (let i = 0; i < nodes.length; i++) {
    expect(nodes[i].frame.width).toBeGreaterThan(0);
    expect(nodes[i].frame.height).toBeGreaterThan(0);
    for (let j = i + 1; j < nodes.length; j++) {
      expect(rectsOverlap(nodes[i].frame, nodes[j].frame)).toBe(false);
    }
  }
}

afterEach(() => {
  vi.restoreAllMocks();
  delete process.env.CHARKLE_EXTENSION_DIR;
  delete process.env.CHARKLE_FIGMA_PLUGIN_DIR;
  while (tempDirs.length > 0) {
    const dir = tempDirs.pop()!;
    fs.rmSync(dir, { recursive: true, force: true });
  }
});

describe('Wave 2 Delta Sync & Browser Clipper Extension Server Support', () => {
  it('serves GET /api/v1/media/:id/original?cachedOnly=1 with 200/206 when cached and 404 without remote download or LRU touch when uncached', async () => {
    const { ctx, app, pat } = await createRig();
    try {
      const payload = Buffer.from('0123456789abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ');
      const ing = await ctx.media.ingestUploadedFile(payload, 'hover-demo.mp4', 'video/mp4');
      ctx.db.saveAssetLocally(ing.asset);

      const downloadSpy = vi.spyOn(ctx.sync, 'downloadOriginal');
      const touchSpy = vi.spyOn(ctx.db, 'touchOriginal');

      // 1. Cached locally -> 200 OK full payload
      const res200 = await app.request(`/api/v1/media/${ing.asset.id}/original?cachedOnly=1`, {
        headers: { Authorization: `Bearer ${pat.token}` },
      });
      expect(res200.status).toBe(200);
      expect(res200.headers.get('accept-ranges')).toBe('bytes');
      expect(res200.headers.get('content-type')).toBe('video/mp4');
      expect(Buffer.from(await res200.arrayBuffer())).toEqual(payload);
      expect(downloadSpy).not.toHaveBeenCalled();
      expect(touchSpy).not.toHaveBeenCalled();

      // 2. Cached locally -> 206 Partial Content HTTP Range
      const res206 = await app.request(`/api/v1/media/${ing.asset.id}/original?cachedOnly=true`, {
        headers: {
          Authorization: `Bearer ${pat.token}`,
          Range: 'bytes=0-15',
        },
      });
      expect(res206.status).toBe(206);
      expect(res206.headers.get('content-range')).toBe(`bytes 0-15/${payload.length}`);
      expect(res206.headers.get('content-length')).toBe('16');
      expect(Buffer.from(await res206.arrayBuffer())).toEqual(payload.subarray(0, 16));
      expect(downloadSpy).not.toHaveBeenCalled();
      expect(touchSpy).not.toHaveBeenCalled();

      // 3. Evict local file -> ?cachedOnly=1 returns 404 NOT_CACHED immediately WITHOUT downloading or touching LRU
      const cachedPath = ctx.media.cachedOriginalPath(ing.asset);
      expect(cachedPath).not.toBeNull();
      fs.unlinkSync(cachedPath!);
      expect(ctx.media.cachedOriginalPath(ing.asset)).toBeNull();

      const resMiss = await app.request(`/api/v1/media/${ing.asset.id}/original?cachedOnly=1`, {
        headers: { Authorization: `Bearer ${pat.token}` },
      });
      expect(resMiss.status).toBe(404);
      const missBody = (await resMiss.json()) as { code: string };
      expect(missBody.code).toBe('NOT_CACHED');
      expect(downloadSpy).not.toHaveBeenCalled();
      expect(touchSpy).not.toHaveBeenCalled();

      // 4. Control check: without cachedOnly, missing local file DOES invoke sync.downloadOriginal
      const resNormal = await app.request(`/api/v1/media/${ing.asset.id}/original`, {
        headers: { Authorization: `Bearer ${pat.token}` },
      });
      expect(resNormal.status).toBe(404);
      expect(downloadSpy).toHaveBeenCalledTimes(1);
    } finally {
      ctx.db.close();
    }
  });

  it('seeds starter moodboard pre-frozen into freeform with non-overlapping editorial frames', async () => {
    const { ctx } = await createRig();
    try {
      const seeded = await seedSampleLibrary(ctx.db, ctx.media);
      expect(seeded).toBe(true);
      const seededBoards = ctx.db.fetchBoards();
      expect(seededBoards).toHaveLength(1);
      const starter = seededBoards[0];
      expect(starter.mode).toEqual({ type: 'freeform' });
      expect(starter.nodes.length).toBeGreaterThanOrEqual(4);
      assertNoOverlaps(starter.nodes);
    } finally {
      ctx.db.close();
    }
  });

  it('defaults POST /api/v1/boards, MoodboardCurator, MoodboardAgentHarness, and MCP compose_moodboard to freeform-first', async () => {
    const { ctx, app, pat } = await createRig();
    try {
      // Add two distinct-aspect assets for API/curator/MCP checks
      const idA = toSwiftUUID('77777777-7777-4777-8777-777777777701');
      const idB = toSwiftUUID('77777777-7777-4777-8777-777777777702');
      const rA = await ctx.media.ingestUploadedFile(await makePng(1200, 800, [195, 115, 80]), 'clay-wide.png', 'image/png', null, idA);
      const rB = await ctx.media.ingestUploadedFile(await makePng(600, 1000, [140, 155, 130]), 'stone-tall.png', 'image/png', null, idB);
      ctx.db.saveAssetLocally({ ...rA.asset, title: 'Warm Clay Study', tags: ['clay', 'warm'] });
      ctx.db.saveAssetLocally({ ...rB.asset, title: 'Tall Stone Monolith', tags: ['clay', 'stone'] });

      // 2. POST /api/v1/boards (seeded & empty) defaults to freeform with clean non-overlapping frames
      const createBoardRes = await app.request('/api/v1/boards', {
        method: 'POST',
        headers: {
          Authorization: `Bearer ${pat.token}`,
          'Content-Type': 'application/json',
        },
        body: JSON.stringify({
          title: 'Seeded Freeform Board',
          seedAssetIDs: [idA, idB],
        }),
      });
      expect(createBoardRes.status).toBe(201);
      const created = (await createBoardRes.json()) as { board: MoodboardDocument };
      expect(created.board.mode).toEqual({ type: 'freeform' });
      expect(created.board.nodes).toHaveLength(2);
      assertNoOverlaps(created.board.nodes);

      // 3. MoodboardCurator.proposeMoodboard returns freeform draft with non-overlapping editorial coordinates
      const curator = new MoodboardCurator(ctx.db);
      const proposal = await curator.proposeMoodboard(
        { type: 'combined', prompt: 'clay warm', seedAssetIDs: [idA, idB], palette: [] },
        4,
        6,
      );
      expect(proposal.draftDocument.mode).toEqual({ type: 'freeform' });
      assertNoOverlaps(proposal.draftDocument.nodes);

      // 4. MoodboardAgentHarness defaults to freeform and respects explicit useFreeformLayout: false
      const harness = new MoodboardAgentHarness(ctx.db, ctx.media);
      const defaultCurated = await harness.curate({
        request: createDefaultMoodboardCurationRequest({
          prompt: 'clay warm',
          seedAssetIDs: [idA, idB],
          preferredCount: 4,
        }),
      });
      expect(defaultCurated.draftDocument.mode).toEqual({ type: 'freeform' });
      assertNoOverlaps(defaultCurated.draftDocument.nodes);

      const legacyEditorialCurated = await harness.curate({
        request: createDefaultMoodboardCurationRequest({
          prompt: 'clay warm',
          seedAssetIDs: [idA, idB],
          preferredCount: 4,
          useFreeformLayout: false,
        }),
      });
      expect(legacyEditorialCurated.draftDocument.mode.type).toBe('autoEditorial');

      // 5. MCP compose_moodboard defaults use_freeform to true unless explicitly false
      ctx.configStore.setExternalAgentConfig({ enabled: true, accessLevel: 'readWriteOrganize' });

      const callCompose = async (args: Record<string, unknown>) => {
        const rpcRes = await app.request('/api/v1/mcp', {
          method: 'POST',
          headers: {
            Authorization: `Bearer ${pat.token}`,
            'Content-Type': 'application/json',
          },
          body: JSON.stringify({
            jsonrpc: '2.0',
            id: 1,
            method: 'tools/call',
            params: { name: 'compose_moodboard', arguments: args },
          }),
        });
        expect(rpcRes.status).toBe(200);
        const body = (await rpcRes.json()) as {
          result: { isError: boolean; content: Array<{ text: string }> };
        };
        expect(body.result.isError).toBe(false);
        return JSON.parse(body.result.content[0].text) as { boardID: string };
      };

      const mcpDefault = await callCompose({
        title: 'MCP Default Freeform',
        asset_ids: [idA, idB],
      });
      const mcpDefaultDoc = ctx.db.getBoard(mcpDefault.boardID)!;
      expect(mcpDefaultDoc.mode).toEqual({ type: 'freeform' });
      assertNoOverlaps(mcpDefaultDoc.nodes);

      const mcpExplicitFalse = await callCompose({
        title: 'MCP Legacy AutoEditorial',
        asset_ids: [idA, idB],
        use_freeform: false,
      });
      const mcpLegacyDoc = ctx.db.getBoard(mcpExplicitFalse.boardID)!;
      expect(mcpLegacyDoc.mode.type).toBe('autoEditorial');
    } finally {
      ctx.db.close();
    }
  });

  it('enforces safe extension CORS for chrome-extension:// & moz-extension:// with Bearer PAT auth and rejects web origins', async () => {
    const { ctx, app, pat } = await createRig();
    try {
      const chromeOrigin = 'chrome-extension://abcdefghijklmnopabcdefghijklmnop';
      const mozOrigin = 'moz-extension://550e8400-e29b-41d4-a716-446655440000';
      const evilWebOrigin = 'https://evil.example.com';

      // 1. Chrome extension OPTIONS preflight -> 204 without auth, exact CORS headers, NEVER credentials
      const preflight = await app.request('/api/v1/assets/ingest', {
        method: 'OPTIONS',
        headers: {
          Origin: chromeOrigin,
          'Access-Control-Request-Method': 'POST',
          'Access-Control-Request-Headers': 'Authorization, Content-Type',
        },
      });
      expect(preflight.status).toBe(204);
      expect(preflight.headers.get('access-control-allow-origin')).toBe(chromeOrigin);
      expect(preflight.headers.get('access-control-allow-methods')).toBe(
        'GET,POST,PUT,PATCH,DELETE,OPTIONS',
      );
      expect(preflight.headers.get('access-control-allow-headers')).toBe(
        'Authorization,Content-Type',
      );
      expect(preflight.headers.get('access-control-max-age')).toBe('86400');
      expect(preflight.headers.get('vary')).toContain('Origin');
      expect(preflight.headers.get('access-control-allow-credentials')).toBeNull();

      // 2. Firefox moz-extension OPTIONS preflight -> 204
      const mozPreflight = await app.request('/api/v1/folders', {
        method: 'OPTIONS',
        headers: { Origin: mozOrigin },
      });
      expect(mozPreflight.status).toBe(204);
      expect(mozPreflight.headers.get('access-control-allow-origin')).toBe(mozOrigin);
      expect(mozPreflight.headers.get('access-control-allow-credentials')).toBeNull();

      // 3. Extension request WITHOUT PAT -> still strictly 401 (with ACAO so extension can read error)
      const unauthExt = await app.request('/api/v1/assets/ingest', {
        method: 'POST',
        headers: {
          Origin: chromeOrigin,
          'Content-Type': 'application/json',
        },
        body: JSON.stringify({
          inputs: [{ type: 'colorSwatch', hex: '#D4A373', title: 'Should Fail' }],
        }),
      });
      expect(unauthExt.status).toBe(401);
      expect(unauthExt.headers.get('access-control-allow-origin')).toBe(chromeOrigin);
      expect(unauthExt.headers.get('vary')).toContain('Origin');
      expect(unauthExt.headers.get('access-control-allow-credentials')).toBeNull();

      // 4. Extension request WITH Bearer chk_... PAT -> 201 + asset ingested + ACAO header
      const authExt = await app.request('/api/v1/assets/ingest', {
        method: 'POST',
        headers: {
          Origin: chromeOrigin,
          Authorization: `Bearer ${pat.token}`,
          'Content-Type': 'application/json',
        },
        body: JSON.stringify({
          inputs: [{ type: 'colorSwatch', hex: '#C46A34', title: 'Clipped Terracotta' }],
        }),
      });
      expect(authExt.status).toBe(201);
      expect(authExt.headers.get('access-control-allow-origin')).toBe(chromeOrigin);
      expect(authExt.headers.get('vary')).toContain('Origin');
      expect(authExt.headers.get('access-control-allow-credentials')).toBeNull();
      const ingested = (await authExt.json()) as { assets: Array<{ title: string }> };
      expect(ingested.assets).toHaveLength(1);
      expect(ingested.assets[0].title).toBe('Clipped Terracotta');

      // 5. Cross-site https:// origin NEVER receives Access-Control-Allow-Origin (CSRF safety)
      const evilOptions = await app.request('/api/v1/assets/ingest', {
        method: 'OPTIONS',
        headers: { Origin: evilWebOrigin },
      });
      expect(evilOptions.headers.get('access-control-allow-origin')).toBeNull();
      expect(evilOptions.headers.get('access-control-allow-credentials')).toBeNull();

      const evilGet = await app.request('/api/v1/health', {
        headers: { Origin: evilWebOrigin },
      });
      expect(evilGet.status).toBe(200);
      expect(evilGet.headers.get('access-control-allow-origin')).toBeNull();
      expect(evilGet.headers.get('access-control-allow-credentials')).toBeNull();
    } finally {
      ctx.db.close();
    }
  });

  it('serves authenticated GET /api/v1/extension/download as valid ZIP containing manifest.json and excluding tests/node_modules/.DS_Store', async () => {
    const { ctx, app, pat } = await createRig();
    try {
      // 1. Unauthenticated request strictly rejected with 401
      const unauth = await app.request('/api/v1/extension/download');
      expect(unauth.status).toBe(401);

      // 2. Real workspace packages/extension bundle download
      const res = await app.request('/api/v1/extension/download', {
        headers: { Authorization: `Bearer ${pat.token}` },
      });
      expect(res.status).toBe(200);
      expect(res.headers.get('content-type')).toBe('application/zip');
      expect(res.headers.get('content-disposition')).toBe(
        'attachment; filename="charkle-web-clipper-extension.zip"',
      );

      const zipBuf = Buffer.from(await res.arrayBuffer());
      expect(zipBuf.length).toBeGreaterThan(500);
      const zip = await JSZip.loadAsync(zipBuf);
      const entryNames = Object.keys(zip.files);

      expect(entryNames).toContain('manifest.json');
      expect(entryNames).toContain('background.js');
      expect(entryNames).toContain('content.js');
      expect(entryNames.some((n) => n.startsWith('lib/'))).toBe(true);
      expect(entryNames.some((n) => n.startsWith('icons/'))).toBe(true);
      expect(entryNames.some((n) => n.startsWith('tests/'))).toBe(false);
      expect(entryNames.some((n) => n.startsWith('node_modules/'))).toBe(false);
      expect(entryNames.some((n) => n.endsWith('.DS_Store'))).toBe(false);

      const manifestRaw = await zip.file('manifest.json')!.async('string');
      const manifest = JSON.parse(manifestRaw) as { manifest_version: number; name: string };
      expect(manifest.manifest_version).toBe(3);
      expect(manifest.name).toBeTruthy();

      // 3. Deterministic exclusion test via CHARKLE_EXTENSION_DIR override
      const fakeExtDir = makeTempDir('charkle-fake-ext-');
      fs.mkdirSync(path.join(fakeExtDir, 'lib'), { recursive: true });
      fs.mkdirSync(path.join(fakeExtDir, 'tests'), { recursive: true });
      fs.mkdirSync(path.join(fakeExtDir, 'node_modules/pkg'), { recursive: true });
      fs.writeFileSync(
        path.join(fakeExtDir, 'manifest.json'),
        JSON.stringify({ manifest_version: 3, name: 'Test Clipper', version: '1.0.0' }),
      );
      fs.writeFileSync(path.join(fakeExtDir, 'background.js'), 'console.log("ok");');
      fs.writeFileSync(path.join(fakeExtDir, 'lib/api.js'), 'export const ok = true;');
      fs.writeFileSync(path.join(fakeExtDir, '.DS_Store'), 'junk');
      fs.writeFileSync(path.join(fakeExtDir, 'tests/unit.test.js'), 'test');
      fs.writeFileSync(path.join(fakeExtDir, 'node_modules/pkg/index.js'), 'dep');
      process.env.CHARKLE_EXTENSION_DIR = fakeExtDir;

      const filteredRes = await app.request('/api/v1/extension/download', {
        headers: { Authorization: `Bearer ${pat.token}` },
      });
      expect(filteredRes.status).toBe(200);
      const filteredZip = await JSZip.loadAsync(Buffer.from(await filteredRes.arrayBuffer()));
      const filteredNames = Object.keys(filteredZip.files).filter((n) => !filteredZip.files[n].dir);
      expect(filteredNames.sort()).toEqual(['background.js', 'lib/api.js', 'manifest.json']);
    } finally {
      ctx.db.close();
    }
  });

  it('serves authenticated GET /api/v1/figma-plugin/download as valid ZIP containing manifest.json, code.js, and ui.html while excluding ui-template.html and dotfiles', async () => {
    const { ctx, app, pat } = await createRig();
    try {
      // 1. Unauthenticated request strictly rejected with 401
      const unauth = await app.request('/api/v1/figma-plugin/download');
      expect(unauth.status).toBe(401);

      // 2. Real workspace figma-plugin/ download
      const res = await app.request('/api/v1/figma-plugin/download', {
        headers: { Authorization: `Bearer ${pat.token}` },
      });
      expect(res.status).toBe(200);
      expect(res.headers.get('content-type')).toBe('application/zip');
      expect(res.headers.get('content-disposition')).toBe(
        'attachment; filename="charkle-figma-bridge-plugin.zip"',
      );

      const zipBuf = Buffer.from(await res.arrayBuffer());
      expect(zipBuf.length).toBeGreaterThan(1000);
      const zip = await JSZip.loadAsync(zipBuf);
      const entryNames = Object.keys(zip.files).filter((n) => !zip.files[n].dir);

      expect(entryNames).toContain('manifest.json');
      expect(entryNames).toContain('code.js');
      expect(entryNames).toContain('ui.html');
      expect(entryNames).toContain('jszip.min.js');
      expect(entryNames).toContain('sha256.min.js');
      expect(entryNames).not.toContain('ui-template.html');
      expect(entryNames.some((n) => n.startsWith('.') || n.endsWith('.DS_Store'))).toBe(false);

      const manifest = JSON.parse(await zip.file('manifest.json')!.async('string')) as {
        name: string;
        main: string;
        ui: string;
      };
      expect(manifest.main).toBe('code.js');
      expect(manifest.ui).toBe('ui.html');

      // 3. Deterministic exclusion check via CHARKLE_FIGMA_PLUGIN_DIR
      const fakeFigmaDir = makeTempDir('charkle-fake-figma-');
      fs.writeFileSync(
        path.join(fakeFigmaDir, 'manifest.json'),
        JSON.stringify({ name: 'Test Bridge', main: 'code.js', ui: 'ui.html' }),
      );
      fs.writeFileSync(path.join(fakeFigmaDir, 'code.js'), 'console.log("figma");');
      fs.writeFileSync(path.join(fakeFigmaDir, 'ui.html'), '<html></html>');
      fs.writeFileSync(path.join(fakeFigmaDir, 'ui-template.html'), '<html>template</html>');
      fs.writeFileSync(path.join(fakeFigmaDir, '.DS_Store'), 'junk');
      process.env.CHARKLE_FIGMA_PLUGIN_DIR = fakeFigmaDir;

      const filteredRes = await app.request('/api/v1/figma-plugin/download', {
        headers: { Authorization: `Bearer ${pat.token}` },
      });
      expect(filteredRes.status).toBe(200);
      const filteredZip = await JSZip.loadAsync(Buffer.from(await filteredRes.arrayBuffer()));
      const filteredNames = Object.keys(filteredZip.files).filter((n) => !filteredZip.files[n].dir);
      expect(filteredNames.sort()).toEqual(['code.js', 'manifest.json', 'ui.html']);
    } finally {
      ctx.db.close();
    }
  });
});
