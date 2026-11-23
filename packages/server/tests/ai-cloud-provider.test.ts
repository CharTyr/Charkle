import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { afterEach, describe, expect, it } from 'vitest';
import { createDefaultAIProviderConfig } from '@charkle/shared';
import {
  AnthropicMessagesProvider,
  ChatGPTSubscriptionClient,
  CloudTagNormalizer,
  createCloudAIProvider,
  GeminiProvider,
  OpenAICompatibleProvider,
  OpenAIResponsesProvider,
  type FetchLike,
} from '../src/intelligence/cloud-ai-provider.js';
import { CloudAIUsageTracker } from '../src/intelligence/cloud-ai-usage-tracker.js';
import { openNodeLibraryDatabase } from '../src/runtime/node-sql.js';
import { createNodeConfigStore, createNodeSecretVault } from '../src/runtime/node-storage.js';
import { SECRET_KEYS } from '../src/storage/secret-vault.js';

const tempDirs: string[] = [];

function createTempDir(): string {
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'charkle-ai-cloud-'));
  tempDirs.push(dir);
  return dir;
}

afterEach(() => {
  while (tempDirs.length > 0) {
    const dir = tempDirs.pop()!;
    fs.rmSync(dir, { recursive: true, force: true });
  }
});

describe('CloudAIProvider & CloudAIUsageTracker', () => {
  it('returns null provider when mode is disabled', () => {
    const dir = createTempDir();
    const db = openNodeLibraryDatabase(path.join(dir, 'disabled.sqlite'));
    const vault = createNodeSecretVault(db.sql, dir);
    const provider = createCloudAIProvider(createDefaultAIProviderConfig({ provider: 'disabled' }), {
      vault,
    });
    expect(provider).toBeNull();
    db.close();
  });

  it('invokes Google Gemini vision/text + gemini-embedding-001 and honors sendThumbnailsToCloud', async () => {
    const dir = createTempDir();
    const db = openNodeLibraryDatabase(path.join(dir, 'test.sqlite'));
    const usage = new CloudAIUsageTracker(db);

    const calls: Array<{ url: string; headers: Record<string, string>; body: Record<string, unknown> }> = [];
    const mockFetch: FetchLike = async (input, init) => {
      const url = String(input);
      const headers = (init?.headers ?? {}) as Record<string, string>;
      const body = init?.body ? (JSON.parse(String(init.body)) as Record<string, unknown>) : {};
      calls.push({ url, headers, body });

      if (url.includes(':embedContent')) {
        return new Response(JSON.stringify({ embedding: { values: [0.1, 0.2, 0.3, 0.4] } }), {
          status: 200,
          headers: { 'Content-Type': 'application/json' },
        });
      }
      return new Response(
        JSON.stringify({
          candidates: [
            {
              content: {
                parts: [
                  {
                    text: JSON.stringify({
                      description: '极简建筑光影参考图',
                      tags: ['极简', '建筑', '光影'],
                    }),
                  },
                ],
              },
            },
          ],
          usageMetadata: {
            promptTokenCount: 120,
            candidatesTokenCount: 35,
            totalTokenCount: 155,
          },
        }),
        { status: 200, headers: { 'Content-Type': 'application/json' } },
      );
    };

    const cfgWithThumb = createDefaultAIProviderConfig({
      provider: 'gemini',
      baseURL: 'https://generativelanguage.googleapis.com',
      chatModel: 'gemini-2.5-flash',
      embeddingModel: 'gemini-embedding-001',
      sendThumbnailsToCloud: true,
    });

    const gemini = new GeminiProvider(cfgWithThumb, 'gem-secret-key', {
      usage,
      fetchFn: mockFetch,
    });

    const result = await gemini.enrich('Warm concrete pavilion', Buffer.from([0xff, 0xd8, 0xff]));
    expect(result.description).toBe('极简建筑光影参考图');
    expect(result.suggestedTags).toEqual(['极简', '建筑', '光影']);
    expect(result.embedding).toEqual([0.1, 0.2, 0.3, 0.4]);

    expect(calls).toHaveLength(2);
    expect(calls[0].url).toContain('/v1beta/models/gemini-2.5-flash:generateContent');
    expect(calls[0].headers['x-goog-api-key']).toBe('gem-secret-key');
    const partsWithThumb = (calls[0].body.contents as Array<{ parts: unknown[] }>)[0].parts;
    expect(partsWithThumb).toHaveLength(2);
    expect(calls[1].url).toContain('/v1beta/models/gemini-embedding-001:embedContent');

    // Privacy flag: sendThumbnailsToCloud = false MUST omit inline_data
    const geminiPrivate = new GeminiProvider(
      { ...cfgWithThumb, sendThumbnailsToCloud: false, embeddingModel: '' },
      'gem-secret-key',
      { usage, fetchFn: mockFetch },
    );
    await geminiPrivate.enrich('Text only ref', Buffer.from([0xff, 0xd8, 0xff]));
    const partsWithoutThumb = (calls[2].body.contents as Array<{ parts: unknown[] }>)[0].parts;
    expect(partsWithoutThumb).toHaveLength(1);

    // Usage recorded in standard bucket ONLY (jev stays 0)
    const summary = await usage.snapshot();
    expect(summary.standard.totalRequests).toBe(3);
    expect(summary.standard.totalInputTokens).toBeGreaterThanOrEqual(240);
    expect(summary.standard.totalOutputTokens).toBe(70);
    expect(summary.standard.byModel['gemini-2.5-flash'].requests).toBe(2);
    expect(summary.standard.byModel['gemini-embedding-001'].requests).toBe(1);
    expect(summary.standard.estimatedCostUSD).toBeGreaterThan(0);
    expect(summary.jev.totalRequests).toBe(0);

    db.close();
  });

  it('supports all 3 openAICompatible endpoint formats (Chat Completions, Anthropic Messages, OpenAI Responses)', async () => {
    const dir = createTempDir();
    const db = openNodeLibraryDatabase(path.join(dir, 'test.sqlite'));
    const usage = new CloudAIUsageTracker(db);
    const seenUrls: string[] = [];
    const seenHeaders: Array<Record<string, string>> = [];

    const mockFetch: FetchLike = async (input, init) => {
      const url = String(input);
      seenUrls.push(url);
      seenHeaders.push((init?.headers ?? {}) as Record<string, string>);

      if (url.endsWith('/chat/completions')) {
        return new Response(
          JSON.stringify({
            choices: [{ message: { content: '{"description":"ChatComp描述","tags":["排版"]}' } }],
            usage: { prompt_tokens: 50, completion_tokens: 20, total_tokens: 70 },
          }),
          { status: 200 },
        );
      }
      if (url.endsWith('/embeddings')) {
        return new Response(
          JSON.stringify({
            data: [{ embedding: [0.5, 0.5, 0.7] }],
            usage: { prompt_tokens: 10, total_tokens: 10 },
          }),
          { status: 200 },
        );
      }
      if (url.endsWith('/messages')) {
        return new Response(
          JSON.stringify({
            content: [{ type: 'text', text: '{"description":"Anthropic描述","tags":["极简","插画"]}' }],
            usage: { input_tokens: 80, output_tokens: 25 },
          }),
          { status: 200 },
        );
      }
      if (url.endsWith('/responses')) {
        return new Response(
          JSON.stringify({
            output_text: '{"description":"Responses描述","tags":["摄影"]}',
            usage: { input_tokens: 60, output_tokens: 18, total_tokens: 78 },
          }),
          { status: 200 },
        );
      }
      return new Response('Not Found', { status: 404 });
    };

    // 1. OpenAI Chat Completions
    const chatProv = new OpenAICompatibleProvider(
      createDefaultAIProviderConfig({
        provider: 'openAICompatible',
        customEndpointFormat: 'openAIChatCompletions',
        baseURL: 'https://api.openai.com',
        chatModel: 'gpt-4.1-mini',
        embeddingModel: 'text-embedding-3-small',
      }),
      'sk-openai',
      { usage, fetchFn: mockFetch },
    );
    const r1 = await chatProv.enrich('Editorial grid', Buffer.from([1, 2, 3]));
    expect(r1.description).toBe('ChatComp描述');
    expect(r1.embedding).toEqual([0.5, 0.5, 0.7]);

    // 2. Anthropic Messages
    const anthProv = new AnthropicMessagesProvider(
      createDefaultAIProviderConfig({
        provider: 'openAICompatible',
        customEndpointFormat: 'anthropicMessages',
        baseURL: 'https://api.anthropic.com',
        chatModel: 'claude-sonnet-4-5',
        embeddingModel: '',
      }),
      'sk-ant',
      { usage, fetchFn: mockFetch },
    );
    const r2 = await anthProv.enrich('Poster illustration', Buffer.from([1, 2, 3]));
    expect(r2.description).toBe('Anthropic描述');
    expect(r2.embedding).toBeNull();
    await expect(anthProv.embed('hello')).rejects.toThrow(/Anthropic/);
    expect(seenHeaders[2]['x-api-key']).toBe('sk-ant');
    expect(seenHeaders[2]['anthropic-version']).toBe('2023-06-01');

    // 3. OpenAI Responses
    const respProv = new OpenAIResponsesProvider(
      createDefaultAIProviderConfig({
        provider: 'openAICompatible',
        customEndpointFormat: 'openAIResponses',
        baseURL: 'https://api.openai.com',
        chatModel: 'gpt-4.1-mini',
        embeddingModel: '',
      }),
      'sk-resp',
      { usage, fetchFn: mockFetch },
    );
    const r3 = await respProv.enrich('Architectural photo', null);
    expect(r3.description).toBe('Responses描述');
    expect(seenUrls).toEqual([
      'https://api.openai.com/v1/chat/completions',
      'https://api.openai.com/v1/embeddings',
      'https://api.anthropic.com/v1/messages',
      'https://api.openai.com/v1/responses',
    ]);

    const snap = await usage.snapshot();
    expect(snap.standard.totalRequests).toBe(4);
    expect(Object.keys(snap.standard.byModel)).toContain('claude-sonnet-4-5');
    expect(Object.keys(snap.standard.byModel)).toContain('gpt-4.1-mini');

    db.close();
  });

  it('manages ChatGPT subscription session lifecycle, model listing, and reauth detection', async () => {
    const dir = createTempDir();
    const db = openNodeLibraryDatabase(path.join(dir, 'test.sqlite'));
    const vault = createNodeSecretVault(db.sql, dir);
    const configStore = createNodeConfigStore(db.sql, dir);
    const usage = new CloudAIUsageTracker(db);

    let failAuth = false;
    const mockFetch: FetchLike = async (input) => {
      const url = String(input);
      if (failAuth) {
        return new Response(JSON.stringify({ error: 'expired' }), { status: 401 });
      }
      if (url.endsWith('/models')) {
        return new Response(
          JSON.stringify({
            data: [
              { id: 'gpt-5.4-mini', name: 'GPT-5.4 Mini' },
              { id: 'gpt-4.1', name: 'GPT-4.1' },
              { id: 'whisper-1', name: 'Whisper' },
            ],
          }),
          { status: 200 },
        );
      }
      return new Response(
        JSON.stringify({
          output_text: '{"ok":true}',
          usage: { input_tokens: 40, output_tokens: 12, total_tokens: 52 },
        }),
        { status: 200 },
      );
    };

    const client = new ChatGPTSubscriptionClient({
      vault,
      stateStore: db,
      configStore,
      usage,
      fetchFn: mockFetch,
    });

    expect((await client.currentSession()).status).toBe('disconnected');

    const connected = await client.connectWithToken({
      accessToken: 'chatgpt-tok-123',
      email: 'designer@example.com',
      name: 'Char',
      sharingEnabled: true,
    });
    expect(connected.status).toBe('connected');
    expect(connected.email).toBe('designer@example.com');
    expect(vault.get(SECRET_KEYS.CHATGPT_ACCESS_TOKEN)).toBe('chatgpt-tok-123');

    const models = await client.listModels();
    expect(models.map((m) => m.slug)).toEqual(['gpt-5.4-mini', 'gpt-4.1']);

    const provider = createCloudAIProvider(
      createDefaultAIProviderConfig({ provider: 'chatGPTSubscription', chatModel: 'gpt-5.4-mini' }),
      { vault, chatGPTClient: client, usage, fetchFn: mockFetch },
    )!;
    const out = await provider.completeJSON('Return JSON', 'Hello', []);
    expect(out).toBe('{"ok":true}');

    // 401 transitions session to reauthRequired
    failAuth = true;
    await expect(provider.completeJSON('Return JSON', 'Hello', [])).rejects.toThrow(/过期/);
    expect((await client.currentSession()).status).toBe('reauthRequired');

    await client.disconnect();
    expect((await client.currentSession()).status).toBe('disconnected');
    expect(vault.get(SECRET_KEYS.CHATGPT_ACCESS_TOKEN)).toBeNull();

    db.close();
  });

  it('persists separated standard vs jev usage buckets across restarts, rolls over daily, and resets per bucket', async () => {
    const dir = createTempDir();
    const db = openNodeLibraryDatabase(path.join(dir, 'usage.sqlite'));
    const day1 = new Date('2026-11-20T10:00:00Z');
    const day2 = new Date('2026-11-21T10:00:00Z');

    const tracker1 = new CloudAIUsageTracker(db);
    await tracker1.record({
      category: 'standard',
      providerLabel: 'Google Gemini',
      model: 'gemini-2.5-flash',
      inputTokens: 100,
      outputTokens: 50,
      now: day1,
    });
    await tracker1.record({
      category: 'jev',
      providerLabel: 'TypeSafe (Jev)',
      model: 'jev-latest',
      inputTokens: 300,
      outputTokens: 40,
      now: day1,
    });

    // Reload from SQLite sync_state in a fresh tracker instance
    const tracker2 = new CloudAIUsageTracker(db);
    const snapDay1 = await tracker2.snapshot(day1);
    expect(snapDay1.standard.totalRequests).toBe(1);
    expect(snapDay1.standard.totalTokens).toBe(150);
    expect(snapDay1.jev.totalRequests).toBe(1);
    expect(snapDay1.jev.totalTokens).toBe(340);
    expect(snapDay1.totalRequests).toBe(2);
    expect(snapDay1.totalTokens).toBe(490);

    // Day rollover resets today* while keeping total*
    const snapDay2 = await tracker2.snapshot(day2);
    expect(snapDay2.todayRequests).toBe(0);
    expect(snapDay2.standard.todayRequests).toBe(0);
    expect(snapDay2.jev.todayRequests).toBe(0);
    expect(snapDay2.standard.totalRequests).toBe(1);
    expect(snapDay2.jev.totalRequests).toBe(1);

    // Reset only jev bucket leaves standard intact
    const afterJevReset = await tracker2.reset('jev', day2);
    expect(afterJevReset.jev.totalRequests).toBe(0);
    expect(afterJevReset.standard.totalRequests).toBe(1);
    expect(afterJevReset.totalRequests).toBe(1);

    db.close();
  });

  it('canonicalizes bilingual and synonymous AI tags into clean monolingual library tags', () => {
    const tags = CloudTagNormalizer.canonicalizeSuggestedTags(
      ['#插画 / Illustration', '极简主义 (Minimalism)', 'Architecture', 'UI', '已有标签'],
      ['极简', '建筑'],
      ['已有标签'],
    );
    expect(tags).toEqual(['极简', '建筑', '插画', 'UI']);
  });
});
