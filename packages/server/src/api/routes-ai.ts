import { randomUUID } from 'node:crypto';
import type { Context, Env, Hono } from 'hono';
import { streamSSE } from 'hono/streaming';
import {
  createDefaultMoodboardCurationRequest,
  getBoardReferencedAssetIDs,
  toSwiftUUID,
  type AIConfigResponse,
  type AnalyzeAssetsRequest,
  type AssetRecord,
  type BatchTriageInboxRequest,
  type CloudAIProviderKind,
  type CurateMoodboardRequest,
  type ExportMoodboardRequest,
  type ExtractPaletteRequest,
  type ExtractSubjectPaletteRequest,
  type LocateVisualMatchRequest,
  type LocateVisualRegionRequest,
  type MoodboardExportOptions,
  type ProposeMoodboardRequest,
  type ReplacementCandidatesRequest,
  type ResetAIUsageRequest,
  type SaveAIConfigRequest,
  type SaveExternalAgentConfigRequest,
  type SaveTypeSafeConfigRequest,
  type SemanticSearchRequest,
  type TestTypeSafeConnectionRequest,
  type TypeSafeExperimentalConfig,
  type UUID,
} from '@charkle/shared';
import type { ServerContext } from '../context.js';
import { encodeFeaturePrintFloat32 } from '../db/library-database.js';
import { SECRET_KEYS } from '../storage/secret-vault.js';
import { ExternalAgentService } from '../agent/external-agent-service.js';
import { FigmaBridgeExporter, FigmaBridgeExportError } from '../export/figma-bridge-exporter.js';
import {
  MoodboardExporter,
  type ExtendedMoodboardExportOptions,
} from '../export/moodboard-exporter.js';
import {
  aiProviderSecretKey,
  buildAssetEnrichmentText,
  ChatGPTSubscriptionClient,
  CloudAIError,
  CloudTagNormalizer,
  createCloudAIProvider,
  type CloudAIProvider,
  type FetchLike,
} from '../intelligence/cloud-ai-provider.js';
import { CloudAIUsageTracker } from '../intelligence/cloud-ai-usage-tracker.js';
import { MoodboardAgentHarness } from '../intelligence/moodboard-agent-harness.js';
import { MoodboardCurator } from '../intelligence/moodboard-curator.js';
import {
  TypeSafeError,
  TypeSafeSystemOneClient,
} from '../intelligence/typesafe-client.js';
import {
  VisualGroundingEngine,
  VisualGroundingService,
} from '../intelligence/visual-grounding-engine.js';

export interface AIRouteOptions {
  fetchFn?: FetchLike;
  usageTracker?: CloudAIUsageTracker;
}

function errorStatusFor(err: unknown): 400 | 401 | 403 | 404 | 429 | 500 | 502 {
  if (err instanceof CloudAIError || err instanceof TypeSafeError) {
    if (err.status === 401) return 401;
    if (err.status === 403) return 403;
    if (err.status === 429) return 429;
    if (err.status && err.status >= 500) return 502;
    return 400;
  }
  if (err instanceof FigmaBridgeExportError) return 400;
  return 500;
}

function errorMessage(err: unknown): string {
  return err instanceof Error ? err.message : String(err);
}

function safeFileSlug(title: string, fallback: string): string {
  const cleaned = title
    .trim()
    .replace(/[\\/:*?"<>|\x00-\x1f]/g, '_')
    .replace(/\s+/g, ' ')
    .slice(0, 64);
  return cleaned || fallback;
}

async function safeJsonBody<T>(c: Context): Promise<T> {
  try {
    return (await c.req.json()) as T;
  } catch {
    return {} as T;
  }
}

export function createAIRuntime(ctx: ServerContext, options: AIRouteOptions = {}) {
  const usage = options.usageTracker ?? new CloudAIUsageTracker(ctx.db);
  const fetchFn = options.fetchFn ?? globalThis.fetch;

  const chatGPT = new ChatGPTSubscriptionClient({
    vault: ctx.secretVault,
    stateStore: ctx.db,
    configStore: ctx.configStore,
    usage,
    fetchFn,
  });

  const groundingEngine = new VisualGroundingEngine({ usage, fetchFn });
  const curator = new MoodboardCurator(ctx.db);
  const harness = new MoodboardAgentHarness(ctx.db, ctx.media);

  const getTypeSafeKey = (): string | null =>
    ctx.secretVault.get(SECRET_KEYS.TYPESAFE_API_KEY) ??
    (process.env.TYPESAFE_API_KEY?.trim() || null);

  const vaultWithEnvFallback = {
    get(key: string): string | null {
      const stored = ctx.secretVault.get(key);
      if (stored) return stored;
      if (key === SECRET_KEYS.GEMINI_API_KEY) {
        return process.env.GEMINI_API_KEY?.trim() || null;
      }
      if (key === SECRET_KEYS.OPENAI_API_KEY) {
        const cfg = ctx.configStore.getAIConfig();
        if (cfg.customEndpointFormat === 'anthropicMessages') {
          return process.env.ANTHROPIC_API_KEY?.trim() || process.env.OPENAI_API_KEY?.trim() || null;
        }
        return process.env.OPENAI_API_KEY?.trim() || null;
      }
      if (key === SECRET_KEYS.TYPESAFE_API_KEY) {
        return process.env.TYPESAFE_API_KEY?.trim() || null;
      }
      return null;
    },
    set(key: string, value: string): void {
      ctx.secretVault.set(key, value);
    },
    delete(key: string): void {
      ctx.secretVault.delete(key);
    },
    has(key: string): boolean {
      return this.get(key) !== null;
    },
  };

  const resolveProvider = (): CloudAIProvider | null => {
    const config = ctx.configStore.getAIConfig();
    return createCloudAIProvider(config, {
      vault: vaultWithEnvFallback,
      chatGPTClient: chatGPT,
      usage,
      fetchFn,
    });
  };

  const groundingService = new VisualGroundingService({
    db: ctx.db,
    media: ctx.media,
    engine: groundingEngine,
    getTypeSafeConfig: () => ctx.configStore.getTypeSafeConfig(),
    getTypeSafeAPIKey: getTypeSafeKey,
    getCloudAIProvider: resolveProvider,
  });

  const agentService = new ExternalAgentService({
    db: ctx.db,
    media: ctx.media,
    configStore: ctx.configStore,
    events: ctx.events,
    getCloudAIProvider: resolveProvider,
    getTypeSafeAPIKey: getTypeSafeKey,
    grounding: groundingEngine,
  });

  const buildAIConfigResponse = async (): Promise<AIConfigResponse> => {
    const config = ctx.configStore.getAIConfig();
    const chatGPTSession = await chatGPT.currentSession();
    const hasStoredKeys: Record<CloudAIProviderKind, boolean> = {
      disabled: false,
      chatGPTSubscription: chatGPTSession.status === 'connected' && chatGPTSession.sharingEnabled,
      gemini: vaultWithEnvFallback.has(SECRET_KEYS.GEMINI_API_KEY),
      openAICompatible: vaultWithEnvFallback.has(SECRET_KEYS.OPENAI_API_KEY),
    };
    const usageSummary = await usage.snapshot();
    return {
      config,
      hasStoredKeys,
      usage: usageSummary,
      chatGPTSession,
    };
  };

  return {
    usage,
    fetchFn,
    chatGPT,
    groundingEngine,
    groundingService,
    curator,
    harness,
    agentService,
    resolveProvider,
    getTypeSafeKey,
    buildAIConfigResponse,
  };
}

/**
 * Registers all AI, Visual Grounding (TypeSafe Jev), Moodboard Curation/Export,
 * Offline Lossless Figma Bridge, and External Agent MCP routes on the Hono app.
 */
export function registerAIRoutes<E extends Env = Env>(
  app: Hono<E>,
  ctx: ServerContext,
  options: AIRouteOptions = {},
): void {
  const rt = createAIRuntime(ctx, options);

  // =========================================================================
  // MARK: - Cloud AI Configuration, ChatGPT Session, Usage & Analysis
  // =========================================================================

  app.get('/api/v1/ai/config', async (c) => {
    const response = await rt.buildAIConfigResponse();
    return c.json(response);
  });

  app.put('/api/v1/ai/config', async (c) => {
    try {
      const body = await safeJsonBody<SaveAIConfigRequest>(c);
      if (!body.config) {
        return c.json({ error: '缺少 AI 配置对象。', code: 'INVALID_REQUEST' }, 400);
      }
      const saved = ctx.configStore.setAIConfig(body.config);
      if (body.apiKey !== undefined && body.apiKey !== null && saved.provider !== 'disabled') {
        const trimmed = body.apiKey.trim();
        if (saved.provider === 'chatGPTSubscription') {
          if (!trimmed) {
            await rt.chatGPT.disconnect();
          } else {
            await rt.chatGPT.connectWithToken({ accessToken: trimmed });
          }
        } else {
          const keyName = aiProviderSecretKey(saved.provider);
          if (!trimmed) ctx.secretVault.delete(keyName);
          else ctx.secretVault.set(keyName, trimmed);
        }
      }
      return c.json(await rt.buildAIConfigResponse());
    } catch (err) {
      return c.json({ error: errorMessage(err) }, errorStatusFor(err));
    }
  });

  app.post('/api/v1/ai/usage/reset', async (c) => {
    const body = await safeJsonBody<ResetAIUsageRequest>(c);
    await rt.usage.reset(body.category ?? null);
    return c.json(await rt.buildAIConfigResponse());
  });

  app.get('/api/v1/ai/chatgpt/session', async (c) => {
    const session = await rt.chatGPT.currentSession();
    return c.json({ session });
  });

  app.post('/api/v1/ai/chatgpt/connect', async (c) => {
    try {
      const body = await safeJsonBody<{
        accessToken?: string;
        refreshToken?: string | null;
        email?: string | null;
        name?: string | null;
        subject?: string | null;
        sharingEnabled?: boolean;
        baseURL?: string | null;
      }>(c);
      if (!body.accessToken?.trim()) {
        return c.json({ error: '请提供 ChatGPT 订阅访问令牌。', code: 'MISSING_TOKEN' }, 400);
      }
      const session = await rt.chatGPT.connectWithToken({
        accessToken: body.accessToken,
        refreshToken: body.refreshToken,
        email: body.email,
        name: body.name,
        subject: body.subject,
        sharingEnabled: body.sharingEnabled ?? true,
        baseURL: body.baseURL,
      });
      const currentCfg = ctx.configStore.getAIConfig();
      const updatedCfg = ctx.configStore.setAIConfig({
        ...currentCfg,
        provider: 'chatGPTSubscription',
        chatModel:
          !currentCfg.chatModel ||
          currentCfg.chatModel.startsWith('gemini-') ||
          currentCfg.chatModel.startsWith('claude-')
            ? 'gpt-5.4-mini'
            : currentCfg.chatModel,
        embeddingModel: '',
      });
      return c.json({ session, config: updatedCfg });
    } catch (err) {
      return c.json({ error: errorMessage(err) }, errorStatusFor(err));
    }
  });

  app.post('/api/v1/ai/chatgpt/disconnect', async (c) => {
    await rt.chatGPT.disconnect();
    const session = await rt.chatGPT.currentSession();
    return c.json({ session });
  });

  app.get('/api/v1/ai/chatgpt/models', async (c) => {
    try {
      const models = await rt.chatGPT.listModels();
      return c.json({ models });
    } catch (err) {
      return c.json({ error: errorMessage(err) }, errorStatusFor(err));
    }
  });

  app.post('/api/v1/ai/analyze', async (c) => {
    try {
      const body = await safeJsonBody<AnalyzeAssetsRequest>(c);
      const ids = Array.isArray(body.ids) ? body.ids : [];
      if (ids.length === 0) {
        return c.json({ assets: [] });
      }

      const aiCfg = ctx.configStore.getAIConfig();
      const syncCfg = ctx.configStore.getSyncConfig();
      const seen = new Set<UUID>();
      const updatedAssets: AssetRecord[] = [];

      if (aiCfg.provider === 'disabled') {
        // Local-only visual color + perceptual fingerprint refresh
        for (const rawId of ids) {
          const id = toSwiftUUID(rawId);
          if (seen.has(id)) continue;
          seen.add(id);
          const before = ctx.db.getAsset(id);
          if (!before) continue;
          const thumbBuf = await ctx.media.readThumbnailBuffer(id, 'grid520');
          if (!thumbBuf) {
            updatedAssets.push(before);
            continue;
          }
          const [colors, fp] = await Promise.all([
            before.mediaKind === 'audio'
              ? Promise.resolve(before.dominantColors)
              : ctx.media.extractDominantColors(thumbBuf, 6),
            ctx.media.computeVisualFingerprint(thumbBuf),
          ]);
          const saved = ctx.db.transaction(() => {
            const current = ctx.db.getAsset(id);
            if (!current || current.contentHash !== before.contentHash) return null;
            const next: AssetRecord = {
              ...current,
              dominantColors: colors.length > 0 && current.mediaKind !== 'audio' ? colors : current.dominantColors,
            };
            if (fp.length > 0) {
              const vec = {
                featurePrint: encodeFeaturePrintFloat32(fp),
                embedding: null,
                embeddingModel: null,
                precision: 16 as const,
              };
              if (syncCfg.syncEmbeddings) ctx.db.recordSyncChange({ type: 'vector', id, vector: vec });
              else ctx.db.saveVector(id, vec);
            }
            return ctx.db.saveAssetLocally(next);
          });
          if (saved) updatedAssets.push(saved);
        }
      } else {
        const provider = rt.resolveProvider();
        if (!provider) {
          return c.json({ assets: [] });
        }
        const existingLibraryTags = ctx.db.fetchTagCounts().map((t) => t.name);
        for (const rawId of ids) {
          const id = toSwiftUUID(rawId);
          if (seen.has(id)) continue;
          seen.add(id);
          const before = ctx.db.getAsset(id);
          if (!before) continue;
          const thumbBuf = aiCfg.sendThumbnailsToCloud
            ? await ctx.media.readThumbnailBuffer(id, 'grid520')
            : null;
          const promptText = buildAssetEnrichmentText(before, existingLibraryTags);
          const enrichment = await provider.enrich(promptText, thumbBuf);

          const saved = ctx.db.transaction(() => {
            const current = ctx.db.getAsset(id);
            if (!current || current.contentHash !== before.contentHash) return null;
            const latestTags = ctx.db.fetchTagCounts().map((t) => t.name);
            const canonicalTags = CloudTagNormalizer.canonicalizeSuggestedTags(
              enrichment.suggestedTags,
              latestTags.length > 0 ? latestTags : existingLibraryTags,
              current.tags,
              CloudTagNormalizer.preferredLanguage(),
              6,
            );
            const next: AssetRecord = {
              ...current,
              aiDescription: enrichment.description ?? current.aiDescription,
              suggestedTags: canonicalTags,
            };
            if (enrichment.embedding && enrichment.embedding.length > 0) {
              const vec = {
                featurePrint: null,
                embedding: enrichment.embedding,
                embeddingModel: provider.embeddingIdentity,
                precision: 16 as const,
              };
              if (syncCfg.syncEmbeddings) ctx.db.recordSyncChange({ type: 'vector', id, vector: vec });
              else ctx.db.saveVector(id, vec);
            }
            return ctx.db.saveAssetLocally(next);
          });
          if (saved) updatedAssets.push(saved);
        }
      }

      if (updatedAssets.length > 0) {
        ctx.events.emitLibraryEnriched(updatedAssets.map((a) => a.id));
      }
      return c.json({ assets: updatedAssets });
    } catch (err) {
      return c.json({ error: errorMessage(err) }, errorStatusFor(err));
    }
  });

  app.post('/api/v1/ai/semantic-search', async (c) => {
    try {
      const body = await safeJsonBody<SemanticSearchRequest>(c);
      const report = await rt.groundingService.semanticSearch(
        body.query ?? '',
        body.criteria ?? {},
        body.limit ?? 48,
      );
      return c.json({ report });
    } catch (err) {
      return c.json({ error: errorMessage(err) }, errorStatusFor(err));
    }
  });

  app.post('/api/v1/ai/inbox-triage', async (c) => {
    try {
      const body = await safeJsonBody<BatchTriageInboxRequest>(c);
      const recommendations = await rt.groundingService.batchTriageInbox(
        body.assetIDs ?? [],
        body.maxCount ?? 24,
      );
      return c.json({ recommendations });
    } catch (err) {
      return c.json({ error: errorMessage(err) }, errorStatusFor(err));
    }
  });

  app.post('/api/v1/ai/suggest-folder', async (c) => {
    try {
      const body = await safeJsonBody<{ assetID?: UUID }>(c);
      if (!body.assetID) {
        return c.json({ error: '缺少 assetID。' }, 400);
      }
      const suggestion = await rt.groundingService.suggestFolder(body.assetID);
      return c.json({ suggestion });
    } catch (err) {
      return c.json({ error: errorMessage(err) }, errorStatusFor(err));
    }
  });

  // =========================================================================
  // MARK: - Experimental TypeSafe System One (Jev) Visual Grounding
  // =========================================================================

  app.get('/api/v1/typesafe/config', (c) => {
    return c.json({
      config: ctx.configStore.getTypeSafeConfig(),
      hasStoredKey: Boolean(rt.getTypeSafeKey()),
    });
  });

  app.put('/api/v1/typesafe/config', async (c) => {
    try {
      const body = await safeJsonBody<SaveTypeSafeConfigRequest>(c);
      if (!body.config) {
        return c.json({ error: '缺少 TypeSafe 配置对象。' }, 400);
      }
      const raw = body.config;
      const sanitized: TypeSafeExperimentalConfig = {
        ...raw,
        baseURL: (raw.baseURL ?? '').trim() || 'https://api.typesafe.ai',
        model: (raw.model ?? '').trim() || 'jev-latest',
        minConfidence: Math.max(0.05, Math.min(0.95, raw.minConfidence ?? 0.6)),
        lowConfidencePadding: Math.max(0.0, Math.min(0.25, raw.lowConfidencePadding ?? 0.05)),
        minPresenceProbability: Math.max(0.05, Math.min(0.95, raw.minPresenceProbability ?? 0.45)),
      };

      if (body.apiKey !== undefined && body.apiKey !== null) {
        const trimmed = body.apiKey.trim();
        if (!trimmed) ctx.secretVault.delete(SECRET_KEYS.TYPESAFE_API_KEY);
        else ctx.secretVault.set(SECRET_KEYS.TYPESAFE_API_KEY, trimmed);
      }

      const saved = ctx.configStore.setTypeSafeConfig(sanitized);
      return c.json({
        config: saved,
        hasStoredKey: Boolean(rt.getTypeSafeKey()),
      });
    } catch (err) {
      return c.json({ error: errorMessage(err) }, errorStatusFor(err));
    }
  });

  app.post('/api/v1/typesafe/test', async (c) => {
    try {
      const body = await safeJsonBody<TestTypeSafeConnectionRequest>(c);
      const cfg = body.config ?? ctx.configStore.getTypeSafeConfig();
      const resolvedKey = body.apiKey?.trim() || rt.getTypeSafeKey();
      if (!resolvedKey) {
        return c.json({ error: '请先填写 TypeSafe API 密钥后再测试连接。' }, 400);
      }
      const client = new TypeSafeSystemOneClient({
        baseURL: cfg.baseURL,
        apiKey: resolvedKey,
        usage: rt.usage,
        fetchFn: rt.fetchFn,
      });
      const models = await client.listModels();
      return c.json({ models });
    } catch (err) {
      return c.json({ error: errorMessage(err) }, errorStatusFor(err));
    }
  });

  app.post('/api/v1/typesafe/locate-region', async (c) => {
    try {
      const body = await safeJsonBody<LocateVisualRegionRequest>(c);
      if (!body.assetID) {
        return c.json({ error: '缺少 assetID。' }, 400);
      }
      const result = await rt.groundingService.locateVisualRegion(body.assetID, body.query);
      return c.json({ result });
    } catch (err) {
      return c.json({ error: errorMessage(err) }, errorStatusFor(err));
    }
  });

  app.post('/api/v1/typesafe/locate-match', async (c) => {
    try {
      const body = await safeJsonBody<LocateVisualMatchRequest>(c);
      if (!body.referenceAssetID || !body.targetAssetID) {
        return c.json({ error: '缺少 referenceAssetID 或 targetAssetID。' }, 400);
      }
      const result = await rt.groundingService.locateVisualMatch(
        body.referenceAssetID,
        body.targetAssetID,
      );
      return c.json({ result });
    } catch (err) {
      return c.json({ error: errorMessage(err) }, errorStatusFor(err));
    }
  });

  app.post('/api/v1/typesafe/clean-bounds', async (c) => {
    try {
      const body = await safeJsonBody<{ assetID?: UUID }>(c);
      if (!body.assetID) {
        return c.json({ error: '缺少 assetID。' }, 400);
      }
      const result = await rt.groundingService.detectCleanContentBounds(body.assetID);
      return c.json({ result });
    } catch (err) {
      return c.json({ error: errorMessage(err) }, errorStatusFor(err));
    }
  });

  app.post('/api/v1/typesafe/subject-palette', async (c) => {
    try {
      const body = await safeJsonBody<ExtractSubjectPaletteRequest>(c);
      if (!body.assetID) {
        return c.json({ error: '缺少 assetID。' }, 400);
      }
      const result = await rt.groundingService.extractSubjectPalette(body.assetID, body.query);
      ctx.events.emitLibraryChanged('ai.subject_palette', [result.updatedAsset.id]);
      return c.json({ result });
    } catch (err) {
      return c.json({ error: errorMessage(err) }, errorStatusFor(err));
    }
  });

  // =========================================================================
  // MARK: - Moodboard Curation, Palette, Replacements & High-DPI/Figma Exports
  // =========================================================================

  app.post('/api/v1/boards/propose', async (c) => {
    try {
      const body = await safeJsonBody<ProposeMoodboardRequest>(c);
      if (!body.seed) {
        return c.json({ error: '缺少情绪板 seed 参数。' }, 400);
      }
      let provider: CloudAIProvider | null = null;
      try {
        provider = rt.resolveProvider();
      } catch {
        provider = null;
      }
      const proposal = await rt.curator.proposeMoodboard(
        body.seed,
        body.primaryCount ?? 12,
        body.candidateCount ?? 24,
        provider,
      );
      return c.json({ proposal });
    } catch (err) {
      return c.json({ error: errorMessage(err) }, errorStatusFor(err));
    }
  });

  app.post('/api/v1/boards/curate', async (c) => {
    const rawReq = await safeJsonBody<Partial<CurateMoodboardRequest>>(c);
    const request = createDefaultMoodboardCurationRequest(rawReq);
    const requestID = randomUUID();
    const accept = c.req.header('accept') ?? '';
    const wantsSSE = accept.includes('text/event-stream');

    let provider: CloudAIProvider | null = null;
    try {
      provider = rt.resolveProvider();
    } catch {
      provider = null;
    }

    const typeSafeConfig = ctx.configStore.getTypeSafeConfig();
    const typeSafeAPIKey = rt.getTypeSafeKey();

    if (wantsSSE) {
      return streamSSE(c, async (stream) => {
        try {
          const proposal = await rt.harness.curate({
            request,
            provider,
            typeSafeConfig,
            typeSafeAPIKey,
            grounding: rt.groundingEngine,
            onStep: async (step) => {
              ctx.events.emitAICurateStep(requestID, step);
              await stream.writeSSE({
                event: 'step',
                data: JSON.stringify({ type: 'ai.curate.step', requestID, step }),
              });
            },
          });
          await stream.writeSSE({
            event: 'done',
            data: JSON.stringify({ proposal }),
          });
        } catch (err) {
          await stream.writeSSE({
            event: 'error',
            data: JSON.stringify({ error: errorMessage(err) }),
          });
        }
      });
    }

    try {
      const proposal = await rt.harness.curate({
        request,
        provider,
        typeSafeConfig,
        typeSafeAPIKey,
        grounding: rt.groundingEngine,
        onStep: (step) => {
          ctx.events.emitAICurateStep(requestID, step);
        },
      });
      return c.json({ proposal });
    } catch (err) {
      return c.json({ error: errorMessage(err) }, errorStatusFor(err));
    }
  });

  app.post('/api/v1/boards/palette', async (c) => {
    const body = await safeJsonBody<ExtractPaletteRequest>(c);
    const colors = rt.curator.extractBoardPalette(body.assetIDs ?? [], body.count ?? 6);
    return c.json({ colors });
  });

  app.post('/api/v1/boards/replacements', async (c) => {
    const body = await safeJsonBody<ReplacementCandidatesRequest>(c);
    if (!body.assetID) {
      return c.json({ error: '缺少 assetID。' }, 400);
    }
    const candidates = rt.curator.replacementCandidates(
      body.assetID,
      body.excluding ?? [],
      body.boardContext ?? [],
      body.limit ?? 24,
    );
    return c.json({ candidates });
  });

  app.post('/api/v1/boards/:id/export/image', async (c) => {
    try {
      const boardID = toSwiftUUID(c.req.param('id'));
      const doc = ctx.db.getBoard(boardID);
      if (!doc) {
        return c.json({ error: `Moodboard not found: ${boardID}` }, 404);
      }

      const body = await safeJsonBody<
        ExportMoodboardRequest & { options?: Partial<ExtendedMoodboardExportOptions> }
      >(c);
      const format = body.format === 'jpeg' ? 'jpeg' : 'png';
      const assetsByID = new Map<UUID, AssetRecord>();
      for (const aid of getBoardReferencedAssetIDs(doc)) {
        const asset = ctx.db.getAsset(aid);
        if (asset) assetsByID.set(aid, asset);
      }

      const rendered = await MoodboardExporter.exportImage({
        document: doc,
        assetsByID,
        loadAssetBuffer: async (assetID, tier) => {
          const asset = assetsByID.get(assetID);
          if (asset && (asset.mediaKind === 'image' || asset.mediaKind === 'animatedImage')) {
            const orig = await ctx.media.readOriginalBuffer(asset);
            if (orig && orig.length > 0) return orig;
          }
          return (
            (await ctx.media.readThumbnailBuffer(assetID, tier)) ??
            (await ctx.media.readThumbnailBuffer(assetID, 'grid520'))
          );
        },
        format,
        containerWidth: body.containerWidth ?? 1120,
        options: body.options,
      });

      const ext = format === 'jpeg' ? 'jpg' : 'png';
      const slug = safeFileSlug(doc.title, `moodboard-${doc.id.slice(0, 8)}`);
      const encodedName = encodeURIComponent(`${slug}.${ext}`);

      return new Response(new Uint8Array(rendered.buffer), {
        status: 200,
        headers: {
          'Content-Type': rendered.mimeType,
          'Content-Length': String(rendered.buffer.length),
          'Content-Disposition': `attachment; filename="moodboard.${ext}"; filename*=UTF-8''${encodedName}`,
        },
      });
    } catch (err) {
      return c.json({ error: errorMessage(err) }, errorStatusFor(err));
    }
  });

  app.post('/api/v1/boards/:id/export/figma', async (c) => {
    try {
      const boardID = toSwiftUUID(c.req.param('id'));
      const doc = ctx.db.getBoard(boardID);
      if (!doc) {
        return c.json({ error: `Moodboard not found: ${boardID}` }, 404);
      }

      const body = await safeJsonBody<{
        containerWidth?: number;
        options?: Partial<MoodboardExportOptions>;
      }>(c);

      const assetsByID = new Map<UUID, AssetRecord>();
      for (const aid of getBoardReferencedAssetIDs(doc)) {
        const asset = ctx.db.getAsset(aid);
        if (asset) assetsByID.set(aid, asset);
      }

      const exported = await FigmaBridgeExporter.exportBundle({
        document: doc,
        assetsByID,
        containerWidth: body.containerWidth ?? 1120,
        options: body.options,
        loadOriginalBuffer: async (assetID) => {
          const asset = assetsByID.get(assetID);
          if (!asset) return null;
          const buf = await ctx.media.readOriginalBuffer(asset);
          if (!buf || buf.length === 0) return null;
          return { buffer: buf, fileName: asset.fileName };
        },
        loadThumbnailBuffer: async (assetID, tier) => ctx.media.readThumbnailBuffer(assetID, tier),
      });

      const slug = safeFileSlug(doc.title, `moodboard-${doc.id.slice(0, 8)}`);
      const encodedName = encodeURIComponent(`${slug}.charkleboard`);

      return new Response(new Uint8Array(exported.zipBuffer), {
        status: 200,
        headers: {
          'Content-Type': 'application/zip',
          'Content-Length': String(exported.zipBuffer.length),
          'Content-Disposition': `attachment; filename="moodboard.charkleboard"; filename*=UTF-8''${encodedName}`,
          'X-Charkle-Bridge-Report': encodeURIComponent(JSON.stringify(exported.report)),
        },
      });
    } catch (err) {
      return c.json({ error: errorMessage(err) }, errorStatusFor(err));
    }
  });

  // =========================================================================
  // MARK: - External Agent Config & JSON-RPC 2.0 MCP Endpoint
  // =========================================================================

  app.get('/api/v1/agent/config', (c) => {
    return c.json({ config: ctx.configStore.getExternalAgentConfig() });
  });

  app.put('/api/v1/agent/config', async (c) => {
    const body = await safeJsonBody<SaveExternalAgentConfigRequest>(c);
    if (!body.config) {
      return c.json({ error: '缺少外部 Agent 配置。' }, 400);
    }
    const config = ctx.configStore.setExternalAgentConfig(body.config);
    return c.json({ config });
  });

  app.get('/api/v1/agent/tools', (c) => {
    return c.json({ tools: ExternalAgentService.mcpToolDefinitions() });
  });

  app.post('/api/v1/mcp', async (c) => {
    const rawText = await c.req.text();
    const response = await rt.agentService.handleJSONRPC(rawText);
    if (response === null) {
      return c.body(null, 204);
    }
    return c.json(response, 200);
  });
}
