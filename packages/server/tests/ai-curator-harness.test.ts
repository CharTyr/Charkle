import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import sharp from 'sharp';
import { afterEach, describe, expect, it } from 'vitest';
import {
  createDefaultAssetRecord,
  createDefaultMoodboardCurationRequest,
  createDefaultTypeSafeExperimentalConfig,
  labFromHex,
  toSwiftUUID,
  type MoodboardAgentStep,
} from '@charkle/shared';
import { createApp, createServerContext } from '../src/app.js';
import { encodeFeaturePrintFloat32, LibraryDatabase } from '../src/db/library-database.js';
import { FakeCloudAIProvider, type FetchLike } from '../src/intelligence/cloud-ai-provider.js';
import { ContactSheetRenderer } from '../src/intelligence/contact-sheet-renderer.js';
import { MoodboardAgentHarness } from '../src/intelligence/moodboard-agent-harness.js';
import { MoodboardCurator } from '../src/intelligence/moodboard-curator.js';
import { VisualGroundingEngine } from '../src/intelligence/visual-grounding-engine.js';
import { MediaPipeline } from '../src/media/media-pipeline.js';

const tempDirs: string[] = [];

function createTempDir(): string {
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'charkle-ai-curator-'));
  tempDirs.push(dir);
  return dir;
}

afterEach(() => {
  while (tempDirs.length > 0) {
    const dir = tempDirs.pop()!;
    fs.rmSync(dir, { recursive: true, force: true });
  }
});

async function makeSolidPNG(r: number, g: number, b: number, w = 320, h = 240): Promise<Buffer> {
  return sharp({ create: { width: w, height: h, channels: 3, background: { r, g, b } } })
    .png()
    .toBuffer();
}

describe('ContactSheetRenderer, MoodboardCurator & MoodboardAgentHarness', () => {
  it('renders up to 16 numbered thumbnails into a crisp labeled PNG contact sheet', async () => {
    const entries = await Promise.all(
      Array.from({ length: 16 }, async (_, idx) => {
        const id = toSwiftUUID(`33333333-3333-4333-8333-3333333333${String(idx + 1).padStart(2, '0')}`);
        const buf = idx < 12 ? await makeSolidPNG((idx * 20) % 255, 110, 180) : null;
        return {
          slot: idx + 1,
          asset: createDefaultAssetRecord({
            id,
            title: `Ref ${idx + 1}`,
            fileName: `ref-${idx + 1}.png`,
            mediaKind: idx === 15 ? 'video' : 'image',
            dominantColors: [labFromHex('#BA6B55')],
          }),
          thumbnailBuffer: buf,
        };
      }),
    );

    const sheet = await ContactSheetRenderer.render(entries, { format: 'png', maxCanvasWidth: 1280 });
    expect(sheet).not.toBeNull();
    expect(sheet!.mimeType).toBe('image/png');
    expect(sheet!.slotToAssetID.size).toBe(16);
    expect(sheet!.orderedSlots[0].slot).toBe(1);
    expect(sheet!.orderedSlots[15].slot).toBe(16);

    const meta = await sharp(sheet!.data).metadata();
    expect(meta.format).toBe('png');
    expect(meta.width).toBe(1280);
    expect(meta.height).toBeGreaterThan(600);
  });

  it('scores with multi-signal fusion, deduplicates via Greedy MMR, extracts board palette, and finds replacements', async () => {
    const dir = createTempDir();
    const db = new LibraryDatabase(path.join(dir, 'curator.sqlite'));

    const idSeed = toSwiftUUID('44444444-4444-4444-8444-444444444401');
    const idDup = toSwiftUUID('44444444-4444-4444-8444-444444444402');
    const idDiverse = toSwiftUUID('44444444-4444-4444-8444-444444444403');
    const idUnrelated = toSwiftUUID('44444444-4444-4444-8444-444444444404');

    const terracotta = labFromHex('#BA6B55', 0.65);
    const terracottaNear = labFromHex('#BD6E58', 0.5);
    const warmSand = labFromHex('#D4A373', 0.45);
    const coolCyan = labFromHex('#06B6D4', 0.8);

    db.saveAssetLocally(
      createDefaultAssetRecord({
        id: idSeed,
        title: 'Terracotta Courtyard',
        fileName: 'seed.jpg',
        contentHash: 'hash-seed',
        tags: ['terracotta', 'minimal', 'architecture'],
        dominantColors: [terracotta, warmSand],
        rating: 5,
      }),
    );
    db.saveAssetLocally(
      createDefaultAssetRecord({
        id: idDup,
        title: 'Terracotta Courtyard Copy',
        fileName: 'dup.jpg',
        contentHash: 'hash-seed', // exact duplicate content hash -> MMR should penalize!
        tags: ['terracotta', 'minimal', 'architecture'],
        dominantColors: [terracottaNear, warmSand],
        rating: 5,
      }),
    );
    db.saveAssetLocally(
      createDefaultAssetRecord({
        id: idDiverse,
        title: 'Terracotta Minimal Vessel',
        fileName: 'vessel.jpg',
        contentHash: 'hash-vessel',
        tags: ['terracotta', 'minimal', 'architecture'],
        dominantColors: [warmSand, terracotta],
        rating: 5,
      }),
    );
    db.saveAssetLocally(
      createDefaultAssetRecord({
        id: idUnrelated,
        title: 'Neon Cyberpunk City',
        fileName: 'cyber.jpg',
        contentHash: 'hash-cyber',
        tags: ['neon'],
        dominantColors: [coolCyan],
        rating: 2,
      }),
    );

    db.saveVector(idSeed, { featurePrint: encodeFeaturePrintFloat32([1, 0, 0, 0]), precision: 16 });
    db.saveVector(idDup, { featurePrint: encodeFeaturePrintFloat32([1, 0, 0, 0]), precision: 16 });
    db.saveVector(idDiverse, { featurePrint: encodeFeaturePrintFloat32([0.35, 0.936, 0, 0]), precision: 16 });
    db.saveVector(idUnrelated, { featurePrint: encodeFeaturePrintFloat32([0, 0, 0, 1]), precision: 16 });

    const curator = new MoodboardCurator(db);

    // Greedy MMR should pick idDiverse ahead of exact duplicate idDup when curating with prompt + seed
    const proposal = await curator.proposeMoodboard(
      { type: 'combined', prompt: 'terracotta minimal', seedAssetIDs: [idSeed], palette: [] },
      2,
      4,
    );
    expect(proposal.primaryMatches[0].asset.id).toBe(idSeed);
    expect(proposal.primaryMatches[1].asset.id).toBe(idDiverse);

    // Palette extraction merges terracotta & terracottaNear (CIEDE2000 < 8) and normalizes proportions
    const palette = curator.extractBoardPalette([idSeed, idDup, idDiverse], 5);
    expect(palette.length).toBeGreaterThanOrEqual(2);
    const propSum = palette.reduce((acc, c) => acc + c.proportion, 0);
    expect(propSum).toBeCloseTo(1.0, 4);
    // Lightest to darkest order
    for (let i = 1; i < palette.length; i++) {
      expect(palette[i - 1].l).toBeGreaterThanOrEqual(palette[i].l);
    }

    // Replacement candidates exclude current boardContext & excluding list
    const replacements = curator.replacementCandidates(idSeed, [idUnrelated], [idSeed, idDup], 10);
    expect(replacements.map((r) => r.asset.id)).toContain(idDiverse);
    expect(replacements.map((r) => r.asset.id)).not.toContain(idSeed);
    expect(replacements.map((r) => r.asset.id)).not.toContain(idDup);
    expect(replacements.map((r) => r.asset.id)).not.toContain(idUnrelated);

    db.close();
  });

  it('streams full MoodboardAgentHarness phases with 1-turn auto-repair, Stage 2.5 Jev rerank, Stage 3.5 detail crop & visual insight caching', async () => {
    const dir = createTempDir();
    const db = new LibraryDatabase(path.join(dir, 'harness.sqlite'));
    const media = new MediaPipeline(path.join(dir, 'media'));

    const id1 = toSwiftUUID('55555555-5555-4555-8555-555555555501');
    const id2 = toSwiftUUID('55555555-5555-4555-8555-555555555502');
    const id3 = toSwiftUUID('55555555-5555-4555-8555-555555555503');

    const img1 = await makeSolidPNG(190, 110, 85);
    const img2 = await makeSolidPNG(210, 165, 115);
    const img3 = await makeSolidPNG(30, 40, 60);

    for (const [id, buf, title] of [
      [id1, img1, 'Warm Clay Lamp'],
      [id2, img2, 'Linen Shadow Study'],
      [id3, img3, 'Dark Dashboard UI'],
    ] as const) {
      const res = await media.ingestUploadedFile(buf, `${title}.png`, 'image/png', null, id);
      db.saveAssetLocally({ ...res.asset, title });
    }

    let llmCalls = 0;
    const provider = new FakeCloudAIProvider({
      jsonResponder: (_systemPrompt, userPrompt) => {
        llmCalls++;
        if (llmCalls === 1) {
          // Intentionally return malformed response on turn 1 to verify deterministic 1-turn auto-repair!
          return 'not-valid-json';
        }
        // Read exact slot numbers assigned in the Contact Sheet manifest
        const slotOf = (title: string): number => {
          const m = userPrompt.match(new RegExp(`#(\\d+)[^\\n]*${title}`));
          return m ? Number(m[1]) : 1;
        };
        const lampSlot = slotOf('Warm Clay Lamp');
        const linenSlot = slotOf('Linen Shadow Study');
        return JSON.stringify({
          boardTitle: '暖陶与光影',
          boardSubtitle: '克制的材质与自然光氛围板',
          curatorNote: {
            title: '视觉定调说明',
            text: '以陶土暖棕与亚麻米色为主调，聚焦材质肌理与漫反射自然光。',
            style: 'warm',
          },
          recommendedLayout: 'magazine',
          sections: [
            {
              title: '核心主视觉',
              tint: 'sand',
              rationale: '暖光与陶土材质',
              slots: [
                { slot: lampSlot, weight: 2, reason: '核心陶土台灯主视觉' },
                { slot: linenSlot, weight: 1, reason: '亚麻光影层次补充' },
              ],
            },
          ],
          candidatePoolSlots: [],
          rejectedNote: '剔除了深色 UI 仪表盘以保持自然材质统一性',
          visualInsights: [
            { slot: lampSlot, description: '暖陶材质台灯与柔和侧逆光', tags: ['陶土', '光影'] },
          ],
        });
      },
    });

    const jevFetch: FetchLike = async (_in, init) => {
      const text = Buffer.from(init?.body as Uint8Array).toString('utf8');
      if (text.includes('"type":"score"')) {
        return new Response(
          JSON.stringify({
            model: 'jev-latest',
            answers: {
              item_0: { type: 'score', score: 3, confidence: 0.95 },
              item_1: { type: 'score', score: 2.5, confidence: 0.9 },
              item_2: { type: 'score', score: 0, confidence: 0.9 },
            },
          }),
          { status: 200 },
        );
      }
      // Stage 3.5 autoFocusDetailCrop box response
      return new Response(
        JSON.stringify({
          model: 'jev-latest',
          answers: {
            present: { type: 'noul', noul: 0.92 },
            region: {
              type: 'box',
              box: { top: 0.15, bottom: 0.85, left: 0.2, right: 0.8 },
              confidence: 0.85,
            },
          },
        }),
        { status: 200 },
      );
    };

    const harness = new MoodboardAgentHarness(db, media);
    const steps: MoodboardAgentStep[] = [];
    const proposal = await harness.curate({
      request: createDefaultMoodboardCurationRequest({
        prompt: '暖陶材质与自然光影',
        preferredCount: 6,
        autoFocusDetailCrop: true,
        includeCuratorNotes: true,
      }),
      provider,
      typeSafeConfig: createDefaultTypeSafeExperimentalConfig({
        enabled: true,
        enableCuratorVisualRerank: true,
      }),
      typeSafeAPIKey: 'ts-key',
      grounding: new VisualGroundingEngine({ fetchFn: jevFetch }),
      onStep: (s) => {
        steps.push(s);
      },
    });

    expect(llmCalls).toBe(2); // Initial + 1-turn auto-repair
    expect(proposal.usedCloudAI).toBe(true);
    expect(proposal.draftDocument.title).toBe('暖陶与光影');
    expect(proposal.sections).toHaveLength(1);
    expect(proposal.primaryMatches).toHaveLength(2);
    expect(proposal.rejectedSummary).toContain('UI');
    expect(proposal.cachedVisualInsightsCount).toBe(1);

    const phases = steps.map((s) => s.phase);
    expect(phases).toContain('planning');
    expect(phases).toContain('retrieving');
    expect(phases).toContain('inspectingVisuals');
    expect(phases).toContain('repairing');
    expect(phases).toContain('composing');
    expect(phases).toContain('verifying');
    expect(phases).toContain('completed');

    // Verify Stage 3.5 autoFocusDetailCrop wrote non-destructive crops onto assetRef nodes
    const assetNodes = proposal.draftDocument.nodes.filter((n) => n.kind.type === 'assetRef');
    expect(assetNodes.length).toBe(2);
    expect(assetNodes.every((n) => n.kind.type === 'assetRef' && n.kind.crop !== null)).toBe(true);

    // Verify visual insight cached back to SQLite!
    const enrichedAsset = db.getAsset(id1)!;
    expect(enrichedAsset.aiDescription).toBe('暖陶材质台灯与柔和侧逆光');
    expect(enrichedAsset.suggestedTags).toContain('光影');

    db.close();
  });

  it('streams SSE steps and final proposal over POST /api/v1/boards/curate', async () => {
    const dir = createTempDir();
    const ctx = createServerContext({ dataDir: dir });
    const app = createApp(ctx, { staticClientDir: null });

    const user = ctx.auth.setupAdmin('admin', 'strong-password-123');
    const token = ctx.auth.createApiToken(user.id, 'test-pat', ['read', 'write', 'mcp']);

    const img = await makeSolidPNG(120, 140, 160);
    const id = toSwiftUUID('66666666-6666-4666-8666-666666666601');
    const ing = await ctx.media.ingestUploadedFile(img, 'nordic-stone.png', 'image/png', null, id);
    ctx.db.saveAssetLocally({ ...ing.asset, title: 'Nordic Stone', tags: ['nordic', 'minimal'] });

    const res = await app.request('/api/v1/boards/curate', {
      method: 'POST',
      headers: {
        Authorization: `Bearer ${token.token}`,
        'Content-Type': 'application/json',
        Accept: 'text/event-stream',
      },
      body: JSON.stringify({
        prompt: 'nordic minimal',
        preferredCount: 4,
      }),
    });

    expect(res.status).toBe(200);
    expect(res.headers.get('content-type')).toContain('text/event-stream');
    const body = await res.text();
    expect(body).toContain('event: step');
    expect(body).toContain('event: done');
    expect(body).toContain('"proposal"');

    ctx.db.close();
  });
});
