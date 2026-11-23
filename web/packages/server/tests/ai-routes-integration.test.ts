import { spawn } from 'node:child_process';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import sharp from 'sharp';
import { afterEach, describe, expect, it } from 'vitest';
import {
  createDefaultAIProviderConfig,
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
  type TestAIConnectionResponse,
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

    const user = await ctx.auth.setupAdmin('admin', 'strong-password-123');
    const loginRes = await app.request('/api/v1/auth/login', {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({ username: 'admin', password: 'strong-password-123' }),
    });
    expect(loginRes.status).toBe(200);
    const sessionCookie = (loginRes.headers.get('set-cookie') ?? '').split(';')[0];
    const sessionHeaders = {
      Cookie: sessionCookie,
      'Content-Type': 'application/json',
    };
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
    // P0-02: PATs must NEVER mutate External Agent config -> 403 Forbidden
    const agentPutPat = await app.request('/api/v1/agent/config', {
      method: 'PUT',
      headers: authHeaders,
      body: JSON.stringify({ config: { enabled: true, accessLevel: 'readWrite' } }),
    });
    expect(agentPutPat.status).toBe(403);
    // Admin session cookie succeeds
    const agentPut = await app.request('/api/v1/agent/config', {
      method: 'PUT',
      headers: sessionHeaders,
      body: JSON.stringify({ config: { enabled: true, accessLevel: 'readWrite' } }),
    });
    expect(agentPut.status).toBe(200);
    const agentBody = (await agentPut.json()) as ExternalAgentConfigResponse;
    expect(agentBody.config.enabled).toBe(true);
    expect(agentBody.config.accessLevel).toBe('readWrite');

    const toolsRes = await app.request('/api/v1/agent/tools', { headers: authHeaders });
    expect(toolsRes.status).toBe(200);
    const toolsJson = (await toolsRes.json()) as { tools: Array<{ name: string }> };
    expect(toolsJson.tools).toHaveLength(20);

    const diagRes = await app.request('/api/v1/agent/diagnostics', { headers: authHeaders });
    expect(diagRes.status).toBe(200);
    const diagJson = (await diagRes.json()) as { ok: boolean; capabilities: { toolCount: number } };
    expect(diagJson.ok).toBe(true);
    expect(diagJson.capabilities.toolCount).toBe(20);

    ctx.db.close();
  });

  it('runs compiled stdio MCP entrypoint (dist/mcp/stdio.js) cleanly over newline-delimited JSON-RPC', async () => {
    const dir = createTempDir();
    // Seed a database with external agent enabled in readOnly mode
    const ctx = createServerContext({ dataDir: dir });
    ctx.configStore.setExternalAgentConfig({
      enabled: true,
      mcpEnabled: true,
      cliEnabled: true,
      accessLevel: 'readOnly',
    });
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
    expect((responses[1].result as { tools: unknown[] }).tools).toHaveLength(20);
    const callRes = responses[2].result as { isError: boolean; content: Array<{ text: string }> };
    expect(callRes.isError).toBe(false);
    expect(JSON.parse(callRes.content[0].text)).toMatchObject({ totalAssets: 0, boardCount: 0 });
  });

  it('tests live Cloud AI connections via POST /api/v1/ai/test across all providers including fallbacks and keyless Ollama', async () => {
    const dir = createTempDir();
    const ctx = createServerContext({ dataDir: dir });

    const calls: Array<{ url: string; method: string; headers: Record<string, string> }> = [];
    const mockFetch: typeof fetch = async (input, init) => {
      const url = String(input);
      const method = (init?.method ?? 'GET').toUpperCase();
      const rawHeaders = (init?.headers ?? {}) as Record<string, string>;
      const headers: Record<string, string> = {};
      for (const [k, v] of Object.entries(rawHeaders)) {
        headers[k.toLowerCase()] = String(v);
      }
      calls.push({ url, method, headers });

      // Gemini endpoints
      if (url.includes('generativelanguage.googleapis.com')) {
        const key = headers['x-goog-api-key'];
        if (key === 'bad-gemini-key') {
          return new Response(JSON.stringify({ error: { message: 'API key invalid' } }), { status: 401 });
        }
        if (url.endsWith('/models/gemini-2.5-flash')) {
          return new Response(JSON.stringify({ name: 'models/gemini-2.5-flash' }), { status: 200 });
        }
        if (url.endsWith('/models/nonexistent-model')) {
          return new Response(JSON.stringify({ error: { message: 'Not found' } }), { status: 404 });
        }
        if (url.endsWith('/models')) {
          return new Response(JSON.stringify({ models: [{ name: 'models/gemini-2.5-flash' }] }), { status: 200 });
        }
      }

      // Anthropic endpoints
      if (url.includes('api.anthropic.com')) {
        if (method === 'GET' && url.endsWith('/models')) {
          return new Response(JSON.stringify({ data: [{ id: 'claude-sonnet-4-5' }] }), { status: 200 });
        }
      }
      if (url.includes('anthropic-proxy.example.com')) {
        if (method === 'GET' && url.endsWith('/models')) {
          return new Response('not found', { status: 404 });
        }
        if (method === 'POST' && url.endsWith('/messages')) {
          return new Response(
            JSON.stringify({
              content: [{ type: 'text', text: '{"ok":true}' }],
              usage: { input_tokens: 5, output_tokens: 3 },
            }),
            { status: 200 },
          );
        }
      }

      // OpenAI Chat Completions (direct /models hit & 404 ping fallback)
      if (url.includes('api.openai.com') && method === 'GET' && url.endsWith('/models')) {
        return new Response(
          JSON.stringify({ data: [{ id: 'gpt-5.4-mini' }, { id: 'gpt-4.1-mini' }] }),
          { status: 200 },
        );
      }
      if (url.includes('chat-fallback.example.com')) {
        if (method === 'GET' && url.endsWith('/models')) {
          return new Response('not found', { status: 404 });
        }
        if (method === 'POST' && url.endsWith('/chat/completions')) {
          return new Response(
            JSON.stringify({
              choices: [{ message: { content: '{"ok":true}' } }],
              usage: { prompt_tokens: 4, completion_tokens: 2, total_tokens: 6 },
            }),
            { status: 200 },
          );
        }
      }

      // OpenAI Responses 405 fallback ping
      if (url.includes('responses-fallback.example.com')) {
        if (method === 'GET' && url.endsWith('/models')) {
          return new Response('method not allowed', { status: 405 });
        }
        if (method === 'POST' && url.endsWith('/responses')) {
          return new Response(
            JSON.stringify({
              output_text: '{"ok":true}',
              usage: { input_tokens: 4, output_tokens: 2, total_tokens: 6 },
            }),
            { status: 200 },
          );
        }
      }

      // Keyless localhost Ollama
      if (url.startsWith('http://localhost:11434/v1/models') && method === 'GET') {
        return new Response(JSON.stringify({ data: [{ id: 'qwen2.5vl:7b' }] }), { status: 200 });
      }

      return new Response('unexpected url', { status: 500 });
    };

    const app = createApp(ctx, { staticClientDir: null, aiOptions: { fetchFn: mockFetch } });
    const user = await ctx.auth.setupAdmin('admin', 'strong-password-123');
    const pat = ctx.auth.createApiToken(user.id, 'ai-test-pat', ['read', 'write']);
    const authHeaders = {
      Authorization: `Bearer ${pat.token}`,
      'Content-Type': 'application/json',
    };

    const postTest = (payload: Record<string, unknown>) =>
      app.request('/api/v1/ai/test', {
        method: 'POST',
        headers: authHeaders,
        body: JSON.stringify(payload),
      });

    try {
      // 1. Disabled -> 400
      const disabledRes = await postTest({
        config: createDefaultAIProviderConfig({ provider: 'disabled' }),
      });
      expect(disabledRes.status).toBe(400);

      // 2. Gemini 200 hit (strips leading models/ prefix)
      const gemOk = await postTest({
        config: createDefaultAIProviderConfig({
          provider: 'gemini',
          chatModel: 'models/gemini-2.5-flash',
        }),
        apiKey: 'good-gemini-key',
      });
      expect(gemOk.status).toBe(200);
      const gemOkJson = (await gemOk.json()) as TestAIConnectionResponse;
      expect(gemOkJson.ok).toBe(true);
      expect(gemOkJson.summary).toContain('gemini-2.5-flash');

      // 3. Gemini 404 model missing + 200 list fallback -> 400 model_not_found
      const gemMissing = await postTest({
        config: createDefaultAIProviderConfig({
          provider: 'gemini',
          chatModel: 'nonexistent-model',
        }),
        apiKey: 'good-gemini-key',
      });
      expect(gemMissing.status).toBe(400);
      const gemMissingJson = (await gemMissing.json()) as { error: string };
      expect(gemMissingJson.error).toContain('nonexistent-model');

      // 4. Gemini 401 bad key -> 401
      const gemBadKey = await postTest({
        config: createDefaultAIProviderConfig({
          provider: 'gemini',
          chatModel: 'gemini-2.5-flash',
        }),
        apiKey: 'bad-gemini-key',
      });
      expect(gemBadKey.status).toBe(401);

      // 5. OpenAI Chat Completions 200 /models
      const oaiOk = await postTest({
        config: createDefaultAIProviderConfig({
          provider: 'openAICompatible',
          customEndpointFormat: 'openAIChatCompletions',
          baseURL: 'https://api.openai.com/v1',
          chatModel: 'gpt-4.1-mini',
        }),
        apiKey: 'sk-test',
      });
      expect(oaiOk.status).toBe(200);
      expect(((await oaiOk.json()) as TestAIConnectionResponse).summary).toContain('gpt-4.1-mini');

      // 6. OpenAI Chat Completions 404 fallback ping
      const oaiFallback = await postTest({
        config: createDefaultAIProviderConfig({
          provider: 'openAICompatible',
          customEndpointFormat: 'openAIChatCompletions',
          baseURL: 'https://chat-fallback.example.com/v1',
          chatModel: 'deepseek-chat',
        }),
        apiKey: 'sk-ds',
      });
      expect(oaiFallback.status).toBe(200);
      expect(((await oaiFallback.json()) as TestAIConnectionResponse).summary).toContain('deepseek-chat');

      // 7. OpenAI Responses 405 fallback ping
      const respFallback = await postTest({
        config: createDefaultAIProviderConfig({
          provider: 'openAICompatible',
          customEndpointFormat: 'openAIResponses',
          baseURL: 'https://responses-fallback.example.com/v1',
          chatModel: 'gpt-5.4-mini',
        }),
        apiKey: 'sk-resp',
      });
      expect(respFallback.status).toBe(200);
      expect(((await respFallback.json()) as TestAIConnectionResponse).summary).toContain('gpt-5.4-mini');

      // 8. Anthropic Messages 200 /models & 404 ping fallback
      const claudeOk = await postTest({
        config: createDefaultAIProviderConfig({
          provider: 'openAICompatible',
          customEndpointFormat: 'anthropicMessages',
          baseURL: 'https://api.anthropic.com/v1',
          chatModel: 'claude-sonnet-4-5',
        }),
        apiKey: 'sk-ant-test',
      });
      expect(claudeOk.status).toBe(200);
      expect(((await claudeOk.json()) as TestAIConnectionResponse).summary).toContain('claude-sonnet-4-5');

      const claudeFallback = await postTest({
        config: createDefaultAIProviderConfig({
          provider: 'openAICompatible',
          customEndpointFormat: 'anthropicMessages',
          baseURL: 'https://anthropic-proxy.example.com/v1',
          chatModel: 'claude-sonnet-4-5',
        }),
        apiKey: 'sk-ant-proxy',
      });
      expect(claudeFallback.status).toBe(200);
      expect(((await claudeFallback.json()) as TestAIConnectionResponse).summary).toContain('Anthropic');

      // 9. Keyless localhost Ollama -> 200 with NO Authorization header
      calls.length = 0;
      const ollamaRes = await postTest({
        config: createDefaultAIProviderConfig({
          provider: 'openAICompatible',
          customEndpointFormat: 'openAIChatCompletions',
          baseURL: 'http://localhost:11434/v1',
          chatModel: 'qwen2.5vl:7b',
        }),
        apiKey: null,
      });
      expect(ollamaRes.status).toBe(200);
      expect(((await ollamaRes.json()) as TestAIConnectionResponse).summary).toContain('qwen2.5vl:7b');
      expect(calls[0].url).toBe('http://localhost:11434/v1/models');
      expect(calls[0].headers.authorization).toBeUndefined();

      // 10. ChatGPT Subscription: disconnected -> 400; connected -> 200 with models
      const chatgptDisconnected = await postTest({
        config: createDefaultAIProviderConfig({ provider: 'chatGPTSubscription' }),
      });
      expect(chatgptDisconnected.status).toBe(400);

      const connectRes = await app.request('/api/v1/ai/chatgpt/connect', {
        method: 'POST',
        headers: authHeaders,
        body: JSON.stringify({ accessToken: 'cgpt-sub-token', email: 'designer@studio.test' }),
      });
      expect(connectRes.status).toBe(200);

      const chatgptOk = await postTest({
        config: createDefaultAIProviderConfig({ provider: 'chatGPTSubscription' }),
      });
      expect(chatgptOk.status).toBe(200);
      const chatgptJson = (await chatgptOk.json()) as TestAIConnectionResponse;
      expect(chatgptJson.ok).toBe(true);
      expect(chatgptJson.models?.length).toBeGreaterThanOrEqual(2);
      expect(chatgptJson.summary).toContain(`可用模型 ${chatgptJson.models!.length} 个`);
    } finally {
      ctx.db.close();
    }
  });

  it('honors localOnly: true on POST /api/v1/ai/analyze without invoking configured Cloud AI', async () => {
    const dir = createTempDir();
    const ctx = createServerContext({ dataDir: dir });

    let cloudFetchCalls = 0;
    const spyFetch: typeof fetch = async () => {
      cloudFetchCalls += 1;
      return new Response('should never be called during localOnly', { status: 500 });
    };

    const app = createApp(ctx, { staticClientDir: null, aiOptions: { fetchFn: spyFetch } });
    const user = await ctx.auth.setupAdmin('admin', 'strong-password-123');
    const pat = ctx.auth.createApiToken(user.id, 'local-only-pat', ['read', 'write']);
    const authHeaders = {
      Authorization: `Bearer ${pat.token}`,
      'Content-Type': 'application/json',
    };

    try {
      // Configure Gemini cloud AI with a stored key
      const saveCfg = await app.request('/api/v1/ai/config', {
        method: 'PUT',
        headers: authHeaders,
        body: JSON.stringify({
          config: createDefaultAIProviderConfig({
            provider: 'gemini',
            chatModel: 'gemini-2.5-flash',
          }),
          apiKey: 'stored-gemini-key',
        }),
      });
      expect(saveCfg.status).toBe(200);

      // Ingest a real image and wipe its dominantColors so we can prove offline rebuild populates them
      const png = await sharp({
        create: { width: 240, height: 180, channels: 3, background: { r: 210, g: 95, b: 60 } },
      })
        .png()
        .toBuffer();
      const id = toSwiftUUID('dddddddd-dddd-4ddd-8ddd-dddddddddd01');
      const ing = await ctx.media.ingestUploadedFile(png, 'terracotta.png', 'image/png', null, id);
      ctx.db.saveAssetLocally({ ...ing.asset, dominantColors: [] });
      expect(ctx.db.getAsset(id)!.dominantColors).toHaveLength(0);

      // Run POST /api/v1/ai/analyze with localOnly: true
      const analyzeRes = await app.request('/api/v1/ai/analyze', {
        method: 'POST',
        headers: authHeaders,
        body: JSON.stringify({ ids: [id], localOnly: true }),
      });
      expect(analyzeRes.status).toBe(200);
      const body = (await analyzeRes.json()) as AnalyzeAssetsResponse;
      expect(body.assets).toHaveLength(1);
      expect(body.assets[0].dominantColors.length).toBeGreaterThan(0);
      expect(cloudFetchCalls).toBe(0);

      const vec = ctx.db.getVector(id);
      expect(vec?.featurePrint).toBeTruthy();
    } finally {
      ctx.db.close();
    }
  });

  it('propagates AbortSignal cancellation to POST /api/v1/boards/curate and stops upstream AI calls (P1-12)', async () => {
    const dir = createTempDir();
    const ctx = createServerContext({ dataDir: dir });

    let upstreamAborted = false;
    let upstreamStarted!: () => void;
    const upstreamReady = new Promise<void>((resolve) => {
      upstreamStarted = resolve;
    });

    const slowFetch: typeof fetch = (_input, init) =>
      new Promise((_resolve, reject) => {
        upstreamStarted();
        const sig = init?.signal;
        if (sig?.aborted) {
          upstreamAborted = true;
          reject(Object.assign(new Error('Aborted'), { name: 'AbortError' }));
          return;
        }
        sig?.addEventListener(
          'abort',
          () => {
            upstreamAborted = true;
            reject(Object.assign(new Error('Aborted'), { name: 'AbortError' }));
          },
          { once: true },
        );
      });

    const app = createApp(ctx, { staticClientDir: null, aiOptions: { fetchFn: slowFetch } });
    const user = await ctx.auth.setupAdmin('admin', 'strong-password-123');
    const pat = ctx.auth.createApiToken(user.id, 'curate-abort-pat', ['read', 'write']);
    const authHeaders = {
      Authorization: `Bearer ${pat.token}`,
      'Content-Type': 'application/json',
    };

    try {
      ctx.configStore.setAIConfig(
        createDefaultAIProviderConfig({
          provider: 'gemini',
          chatModel: 'gemini-2.5-flash',
          embeddingModel: '',
        }),
      );
      ctx.secretVault.set('ai.gemini.apiKey', 'fake-key');
      const png = await makeSubjectPNG();
      const ing = await ctx.media.ingestUploadedFile(png, 'abort-test.png', 'image/png');
      ctx.db.saveAssetLocally(ing.asset);

      const ac = new AbortController();
      const reqPromise = app.request('/api/v1/boards/curate', {
        method: 'POST',
        headers: authHeaders,
        body: JSON.stringify({ prompt: 'warm terracotta editorial' }),
        signal: ac.signal,
      });

      await upstreamReady;
      ac.abort();
      const res = await reqPromise;
      expect(upstreamAborted).toBe(true);
      expect(res.status).not.toBe(200);
    } finally {
      ctx.db.close();
    }
  });
});
