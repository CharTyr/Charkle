import { spawn } from 'node:child_process';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import sharp from 'sharp';
import { afterEach, describe, expect, it } from 'vitest';
import {
  createDefaultMoodboardDocument,
  createDefaultTypeSafeExperimentalConfig,
  labFromHex,
  toSwiftUUID,
  type AIConfigResponse,
  type AnalyzeAssetsResponse,
  type BatchTriageInboxResponse,
  type CleanBoundsResponse,
  type ExternalAgentConfigResponse,
  type ExtractPaletteResponse,
  type ExtractSubjectPaletteResponse,
  type LocateVisualRegionResponse,
  type MoodboardProposalResponse,
  type ReplacementCandidatesResponse,
  type SemanticSearchResponse,
  type TypeSafeConfigResponse,
} from '@charkle/shared';
import { createApp, createServerContext } from '../src/app.js';

const tempDirs: string[] = [];

function createTempDir(): string {
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'charkle-ai-routes-'));
  tempDirs.push(dir);
  return dir;
}

afterEach(() => {
  while (tempDirs.length > 0) {
    const dir = tempDirs.pop()!;
    fs.rmSync(dir, { recursive: true, force: true });
  }
});

async function makeSubjectPNG(): Promise<Buffer> {
  const svg = `<svg xmlns="http://www.w3.org/2000/svg" width="320" height="240">
    <rect width="320" height="240" fill="#FFFFFF"/>
    <rect x="70" y="45" width="180" height="150" rx="16" fill="#BA6B55"/>
    <circle cx="160" cy="120" r="40" fill="#F4D35E"/>
  </svg>`;
  return sharp(Buffer.from(svg)).png().toBuffer();
}

describe('AI, TypeSafe, Board Export & Agent HTTP Routes + Real Stdio MCP Subprocess', () => {
  it('handles full AI, TypeSafe, Boards curation/export, and Agent REST lifecycle end-to-end', async () => {
    const dir = createTempDir();
    const ctx = createServerContext({ dataDir: dir });
    const app = createApp(ctx, { staticClientDir: null });

    const user = ctx.auth.setupAdmin('admin', 'strong-password-123');
    const pat = ctx.auth.createApiToken(user.id, 'routes-pat', ['read', 'write', 'mcp']);
    const authHeaders = {
      Authorization: `Bearer ${pat.token}`,
      'Content-Type': 'application/json',
    };

    // Seed folder + 2 assets + 1 board
    const createdFolder = ctx.db.createFolder('陶土器皿', null);
    const folderID = createdFolder.id;

    const a1ID = toSwiftUUID('aaaa1111-1111-4111-8111-111111111111');
    const a2ID = toSwiftUUID('aaaa1111-1111-4111-8111-111111111112');
    const pngBuf = await makeSubjectPNG();
    const ing1 = await ctx.media.ingestUploadedFile(pngBuf, 'terracotta-bowl.png', 'image/png', folderID, a1ID);
    const ing2 = await ctx.media.ingestUploadedFile(pngBuf, 'inbox-ceramic.png', 'image/png', null, a2ID);
    ctx.db.saveAssetLocally({ ...ing1.asset, title: 'Terracotta Bowl', tags: ['陶土', '器皿'] });
    ctx.db.saveAssetLocally({ ...ing2.asset, title: 'Inbox Ceramic', tags: ['陶土'] });

    const boardID = toSwiftUUID('aaaa1111-1111-4111-8111-111111111199');
    const now = new Date().toISOString();
    ctx.db.saveBoardLocally(
      createDefaultMoodboardDocument({
        id: boardID,
        title: 'Route Test Board',
        extractedPalette: [labFromHex('#BA6B55'), labFromHex('#F4D35E')],
        nodes: [
          {
            id: toSwiftUUID('aaaa1111-1111-4111-8111-111111111121'),
            kind: { type: 'assetRef', assetID: a1ID, crop: null, weight: 2, autoplayLoop: false },
            frame: { x: 20, y: 20, width: 320, height: 240 },
            zIndex: 0,
            rotationDegrees: 0,
            flipHorizontal: false,
            flipVertical: false,
            isLocked: false,
            editorialOrder: 0,
            updatedAt: now,
          },
        ],
      }),
    );

    // 1. AI Config GET / PUT / Usage Reset / ChatGPT Connect & Disconnect
    const getCfg = await app.request('/api/v1/ai/config', { headers: authHeaders });
    expect(getCfg.status).toBe(200);
    const cfgBody = (await getCfg.json()) as AIConfigResponse;
    expect(cfgBody.config.provider).toBe('disabled');
    expect(cfgBody.usage.standard).toBeDefined();
    expect(cfgBody.usage.jev).toBeDefined();

    const putCfg = await app.request('/api/v1/ai/config', {
      method: 'PUT',
      headers: authHeaders,
      body: JSON.stringify({
        config: { ...cfgBody.config, provider: 'gemini', chatModel: 'gemini-2.5-flash' },
        apiKey: 'gm-secret-route-key',
      }),
    });
    expect(putCfg.status).toBe(200);
    const savedCfg = (await putCfg.json()) as AIConfigResponse;
    expect(savedCfg.config.provider).toBe('gemini');
    expect(savedCfg.hasStoredKeys.gemini).toBe(true);

    const resetRes = await app.request('/api/v1/ai/usage/reset', {
      method: 'POST',
      headers: authHeaders,
      body: JSON.stringify({ category: 'standard' }),
    });
    expect(resetRes.status).toBe(200);

    const connectCG = await app.request('/api/v1/ai/chatgpt/connect', {
      method: 'POST',
      headers: authHeaders,
      body: JSON.stringify({ accessToken: 'cg-route-tok', email: 'studio@charkle.app' }),
    });
    expect(connectCG.status).toBe(200);
    const disconnectCG = await app.request('/api/v1/ai/chatgpt/disconnect', {
      method: 'POST',
      headers: authHeaders,
    });
    expect(disconnectCG.status).toBe(200);

    // Switch back to disabled for local analysis test
    await app.request('/api/v1/ai/config', {
      method: 'PUT',
      headers: authHeaders,
      body: JSON.stringify({ config: { ...cfgBody.config, provider: 'disabled' } }),
    });

    // 2. Local Analyze, Semantic Search, Inbox Triage, Suggest Folder
    const analyzeRes = await app.request('/api/v1/ai/analyze', {
      method: 'POST',
      headers: authHeaders,
      body: JSON.stringify({ ids: [a1ID, a2ID] }),
    });
    expect(analyzeRes.status).toBe(200);
    const analyzed = (await analyzeRes.json()) as AnalyzeAssetsResponse;
    expect(analyzed.assets).toHaveLength(2);

    const searchRes = await app.request('/api/v1/ai/semantic-search', {
      method: 'POST',
      headers: authHeaders,
      body: JSON.stringify({ query: 'Terracotta', limit: 10 }),
    });
    expect(searchRes.status).toBe(200);
    const searchBody = (await searchRes.json()) as SemanticSearchResponse;
    expect(searchBody.report.hits.some((h) => h.asset.id === a1ID)).toBe(true);

    const triageRes = await app.request('/api/v1/ai/inbox-triage', {
      method: 'POST',
      headers: authHeaders,
      body: JSON.stringify({ assetIDs: [a2ID], maxCount: 10 }),
    });
    expect(triageRes.status).toBe(200);
    const triageBody = (await triageRes.json()) as BatchTriageInboxResponse;
    expect(triageBody.recommendations.length).toBeGreaterThanOrEqual(1);
    expect(triageBody.recommendations[0].recommendedFolderID).toBe(folderID);

    // 3. TypeSafe Config + Visual Grounding endpoints (graceful local fallback when disabled)
    const getTs = await app.request('/api/v1/typesafe/config', { headers: authHeaders });
    expect(getTs.status).toBe(200);
    const putTs = await app.request('/api/v1/typesafe/config', {
      method: 'PUT',
      headers: authHeaders,
      body: JSON.stringify({
        config: createDefaultTypeSafeExperimentalConfig({ enabled: false, minConfidence: 0.55 }),
        apiKey: 'ts-route-key',
      }),
    });
    expect(putTs.status).toBe(200);
    const tsBody = (await putTs.json()) as TypeSafeConfigResponse;
    expect(tsBody.hasStoredKey).toBe(true);
    expect(tsBody.config.minConfidence).toBeCloseTo(0.55, 2);

    const locRes = await app.request('/api/v1/typesafe/locate-region', {
      method: 'POST',
      headers: authHeaders,
      body: JSON.stringify({ assetID: a1ID }),
    });
    expect(locRes.status).toBe(200);
    const locBody = (await locRes.json()) as LocateVisualRegionResponse;
    expect(locBody.result.found).toBe(true);
    expect(locBody.result.source).toBe('appleVisionSaliency');

    const matchRes = await app.request('/api/v1/typesafe/locate-match', {
      method: 'POST',
      headers: authHeaders,
      body: JSON.stringify({ referenceAssetID: a1ID, targetAssetID: a2ID }),
    });
    // locate-match requires TypeSafe Jev to be enabled and returns a clear 400 message when disabled
    expect(matchRes.status).toBe(400);
    const matchErr = (await matchRes.json()) as { error: string };
    expect(matchErr.error).toContain('TypeSafe');

    const boundsRes = await app.request('/api/v1/typesafe/clean-bounds', {
      method: 'POST',
      headers: authHeaders,
      body: JSON.stringify({ assetID: a1ID }),
    });
    expect(boundsRes.status).toBe(200);
    const boundsBody = (await boundsRes.json()) as CleanBoundsResponse;
    expect(typeof boundsBody.result.hasNoise).toBe('boolean');
    expect(boundsBody.result.recommendedCrop?.width ?? 1).toBeGreaterThan(0);

    const subPalRes = await app.request('/api/v1/typesafe/subject-palette', {
      method: 'POST',
      headers: authHeaders,
      body: JSON.stringify({ assetID: a1ID }),
    });
    expect(subPalRes.status).toBe(200);
    const subPalBody = (await subPalRes.json()) as ExtractSubjectPaletteResponse;
    expect(subPalBody.result.colors.length).toBeGreaterThanOrEqual(1);
    expect(subPalBody.result.updatedAsset.id).toBe(a1ID);

    // 4. Boards Propose, Palette, Replacements & High-DPI PNG/JPEG Export
    const propRes = await app.request('/api/v1/boards/propose', {
      method: 'POST',
      headers: authHeaders,
      body: JSON.stringify({
        seed: { type: 'prompt', prompt: 'Terracotta' },
        primaryCount: 4,
        candidateCount: 8,
      }),
    });
    expect(propRes.status).toBe(200);
    const propBody = (await propRes.json()) as MoodboardProposalResponse;
    expect(propBody.proposal.primaryMatches.length).toBeGreaterThanOrEqual(1);

    const palRes = await app.request('/api/v1/boards/palette', {
      method: 'POST',
      headers: authHeaders,
      body: JSON.stringify({ assetIDs: [a1ID, a2ID], count: 4 }),
    });
    expect(palRes.status).toBe(200);
    const palBody = (await palRes.json()) as ExtractPaletteResponse;
    expect(palBody.colors.length).toBeGreaterThanOrEqual(1);

    const repRes = await app.request('/api/v1/boards/replacements', {
      method: 'POST',
      headers: authHeaders,
      body: JSON.stringify({ assetID: a1ID, excluding: [], boardContext: [a1ID], limit: 10 }),
    });
    expect(repRes.status).toBe(200);
    const repBody = (await repRes.json()) as ReplacementCandidatesResponse;
    expect(repBody.candidates.some((c) => c.asset.id === a2ID)).toBe(true);

    const imgExpRes = await app.request(`/api/v1/boards/${boardID}/export/image`, {
      method: 'POST',
      headers: authHeaders,
      body: JSON.stringify({ format: 'png', options: { scale: 2, includePaletteStrip: true } }),
    });
    expect(imgExpRes.status).toBe(200);
    expect(imgExpRes.headers.get('content-type')).toBe('image/png');
    const pngOut = Buffer.from(await imgExpRes.arrayBuffer());
    const pngMeta = await sharp(pngOut).metadata();
    expect(pngMeta.format).toBe('png');
    expect((pngMeta.width ?? 0)).toBeGreaterThan(200);

    // 5. External Agent Config + Tools listing
    const agentGet = await app.request('/api/v1/agent/config', { headers: authHeaders });
    expect(agentGet.status).toBe(200);
    const agentPut = await app.request('/api/v1/agent/config', {
      method: 'PUT',
      headers: authHeaders,
      body: JSON.stringify({ config: { enabled: true, accessLevel: 'readWrite' } }),
    });
    expect(agentPut.status).toBe(200);
    const agentBody = (await agentPut.json()) as ExternalAgentConfigResponse;
    expect(agentBody.config.enabled).toBe(true);
    expect(agentBody.config.accessLevel).toBe('readWrite');

    const toolsRes = await app.request('/api/v1/agent/tools', { headers: authHeaders });
    expect(toolsRes.status).toBe(200);
    const toolsJson = (await toolsRes.json()) as { tools: Array<{ name: string }> };
    expect(toolsJson.tools).toHaveLength(14);

    ctx.db.close();
  });

  it('runs compiled stdio MCP entrypoint (dist/mcp/stdio.js) cleanly over newline-delimited JSON-RPC', async () => {
    const dir = createTempDir();
    // Seed a database with external agent enabled in readOnly mode
    const ctx = createServerContext({ dataDir: dir });
    ctx.configStore.setExternalAgentConfig({ enabled: true, accessLevel: 'readOnly' });
    ctx.db.close();

    const stdioScript = path.resolve(
      path.dirname(new URL(import.meta.url).pathname),
      '../dist/mcp/stdio.js',
    );
    expect(fs.existsSync(stdioScript)).toBe(true);

    const responses = await new Promise<Array<Record<string, unknown>>>((resolve, reject) => {
      const child = spawn(process.execPath, [stdioScript], {
        env: { ...process.env, CHARKLE_DATA_DIR: dir },
        stdio: ['pipe', 'pipe', 'pipe'],
      });

      let stdout = '';
      let stderr = '';
      child.stdout.on('data', (chunk: Buffer) => {
        stdout += chunk.toString('utf8');
      });
      child.stderr.on('data', (chunk: Buffer) => {
        stderr += chunk.toString('utf8');
      });
      child.on('error', reject);
      child.on('close', (code) => {
        if (code !== 0) {
          reject(new Error(`stdio MCP exited with ${code}: ${stderr}`));
          return;
        }
        const lines = stdout
          .split(/\r?\n/)
          .map((l) => l.trim())
          .filter(Boolean)
          .map((l) => JSON.parse(l) as Record<string, unknown>);
        resolve(lines);
      });

      child.stdin.write(
        `${JSON.stringify({ jsonrpc: '2.0', id: 1, method: 'initialize', params: {} })}\n` +
          `${JSON.stringify({ jsonrpc: '2.0', id: 2, method: 'tools/list', params: {} })}\n` +
          `${JSON.stringify({ jsonrpc: '2.0', id: 3, method: 'tools/call', params: { name: 'library_overview', arguments: {} } })}\n`,
      );
      child.stdin.end();
    });

    expect(responses).toHaveLength(3);
    expect(responses[0].id).toBe(1);
    expect((responses[0].result as { serverInfo: { name: string } }).serverInfo.name).toBe('charkle');
    expect((responses[1].result as { tools: unknown[] }).tools).toHaveLength(14);
    const callRes = responses[2].result as { isError: boolean; content: Array<{ text: string }> };
    expect(callRes.isError).toBe(false);
    expect(JSON.parse(callRes.content[0].text)).toMatchObject({ totalAssets: 0, boardCount: 0 });
  });
});
