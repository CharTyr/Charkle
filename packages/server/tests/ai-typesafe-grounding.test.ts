import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import sharp from 'sharp';
import { afterEach, describe, expect, it } from 'vitest';
import {
  createDefaultAssetRecord,
  createDefaultTypeSafeExperimentalConfig,
  toSwiftUUID,
} from '@charkle/shared';
import { FakeCloudAIProvider, type FetchLike } from '../src/intelligence/cloud-ai-provider.js';
import { CloudAIUsageTracker } from '../src/intelligence/cloud-ai-usage-tracker.js';
import {
  TYPESAFE_DANGER_ZONE_IMAGES_HEADER,
  TypeSafeImagePreparer,
  TypeSafeSystemOneClient,
} from '../src/intelligence/typesafe-client.js';
import {
  VisualGroundingEngine,
  VisualGroundingService,
} from '../src/intelligence/visual-grounding-engine.js';
import { MediaPipeline } from '../src/media/media-pipeline.js';
import { NodeBlobStore } from '../src/runtime/node-blob.js';
import { NodeImageProcessor } from '../src/runtime/node-image.js';
import { openNodeLibraryDatabase } from '../src/runtime/node-sql.js';

const tempDirs: string[] = [];

function createTempDir(): string {
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'charkle-ai-jev-'));
  tempDirs.push(dir);
  return dir;
}

afterEach(() => {
  while (tempDirs.length > 0) {
    const dir = tempDirs.pop()!;
    fs.rmSync(dir, { recursive: true, force: true });
  }
});

/**
 * Generates a white 600x600 image with a vivid crimson 220x220 square centered at (190, 190).
 */
async function createSubjectTestPNG(): Promise<Buffer> {
  const svg = Buffer.from(
    `<svg xmlns="http://www.w3.org/2000/svg" width="600" height="600">
      <rect width="600" height="600" fill="#FFFFFF"/>
      <rect x="190" y="190" width="220" height="220" fill="#D92638"/>
    </svg>`,
  );
  return sharp(svg).png().toBuffer();
}

describe('TypeSafe System One (Jev) & VisualGroundingEngine', () => {
  const nodeImages = new NodeImageProcessor();

  it('enforces 280..1568 pixel bounds on tiny, huge, and extreme-aspect images', async () => {
    const tiny = await sharp({
      create: { width: 80, height: 60, channels: 3, background: { r: 40, g: 80, b: 160 } },
    }).png().toBuffer();
    const prepTiny = await TypeSafeImagePreparer.prepareJPEG(tiny, 512, 0.86, nodeImages);
    expect(prepTiny).not.toBeNull();
    expect(prepTiny!.width).toBeGreaterThanOrEqual(280);
    expect(prepTiny!.height).toBeGreaterThanOrEqual(280);
    expect(prepTiny!.width).toBeLessThanOrEqual(1568);
    expect(prepTiny!.height).toBeLessThanOrEqual(1568);

    const pano = await sharp({
      create: { width: 2000, height: 100, channels: 3, background: { r: 200, g: 120, b: 60 } },
    }).png().toBuffer();
    const prepPano = await TypeSafeImagePreparer.prepareJPEG(pano, 1568, 0.86, nodeImages);
    expect(prepPano).not.toBeNull();
    expect(prepPano!.width).toBe(1568);
    expect(prepPano!.height).toBe(280);
  });

  it('sends exact /v1/systemone multipart protocol (part-1 JSON + TypeSafe-Danger-Zone-Images) and records Jev usage', async () => {
    const dir = createTempDir();
    const db = openNodeLibraryDatabase(path.join(dir, 'jev.sqlite'));
    const usage = new CloudAIUsageTracker(db);

    let capturedUrl = '';
    let capturedHeaders: Record<string, string> = {};
    let capturedBodyText = '';

    const mockFetch: FetchLike = async (input, init) => {
      capturedUrl = String(input);
      capturedHeaders = (init?.headers ?? {}) as Record<string, string>;
      if (capturedUrl.endsWith('/v1/models')) {
        return new Response(
          JSON.stringify({
            models: [{ name: 'jev-latest', description: 'System One', releaseDate: '2026-06-01' }],
          }),
          { status: 200 },
        );
      }
      capturedBodyText = Buffer.from(init?.body as Uint8Array).toString('latin1');
      return new Response(
        JSON.stringify({
          model: 'jev-latest',
          answers: {
            present: { type: 'noul', noul: 0.94 },
            region: {
              type: 'box',
              box: { top: 0.25, bottom: 0.75, left: 0.2, right: 0.8 },
              confidence: 0.48,
            },
          },
          usage: { input_tokens: 410, output_tokens: 24 },
        }),
        { status: 200 },
      );
    };

    const client = new TypeSafeSystemOneClient({
      baseURL: 'https://api.typesafe.ai',
      apiKey: 'ts-live-key',
      usage,
      fetchFn: mockFetch,
    });

    const models = await client.listModels();
    expect(models).toHaveLength(1);
    expect(models[0].name).toBe('jev-latest');

    const imgBuf = await createSubjectTestPNG();
    const engine = new VisualGroundingEngine({ usage, fetchFn: mockFetch, images: nodeImages });
    const cfg = createDefaultTypeSafeExperimentalConfig({
      enabled: true,
      minConfidence: 0.6,
      lowConfidencePadding: 0.05,
      minPresenceProbability: 0.45,
    });

    const result = await engine.locateRegion({
      query: 'crimson square',
      imageBuffer: imgBuf,
      config: cfg,
      apiKey: 'ts-live-key',
    });

    expect(capturedUrl).toBe('https://api.typesafe.ai/v1/systemone');
    expect(capturedHeaders.Authorization).toBe('Bearer ts-live-key');
    expect(capturedHeaders[TYPESAFE_DANGER_ZONE_IMAGES_HEADER]).toBe('true');
    expect(capturedHeaders['Content-Type']).toMatch(/^multipart\/form-data; boundary=/);

    // Part 1 MUST be name="request" with Content-Type: application/json
    const firstPartIdx = capturedBodyText.indexOf('Content-Disposition: form-data; name="request"\r\nContent-Type: application/json');
    const photoPartIdx = capturedBodyText.indexOf('Content-Disposition: form-data; name="photo"; filename="photo.jpg"');
    expect(firstPartIdx).toBeGreaterThan(0);
    expect(photoPartIdx).toBeGreaterThan(firstPartIdx);

    // Low confidence (0.48 < 0.60) triggers outward padding by 0.05
    expect(result.found).toBe(true);
    expect(result.source).toBe('typeSafeJev');
    expect(result.didApplyPadding).toBe(true);
    expect(result.rawBox.x).toBeCloseTo(0.2, 4);
    expect(result.crop.x).toBeCloseTo(0.15, 4);
    expect(result.crop.y).toBeCloseTo(0.2, 4);

    // Usage tracked exclusively in `jev` bucket
    const snap = await usage.snapshot();
    expect(snap.jev.totalRequests).toBe(1);
    expect(snap.jev.totalInputTokens).toBe(410);
    expect(snap.jev.totalOutputTokens).toBe(24);
    expect(snap.standard.totalRequests).toBe(0);

    db.close();
  });

  it('falls back cleanly to local sharp saliency, clean bounds, and subject palette persistence when Jev is disabled', async () => {
    const dir = createTempDir();
    const db = openNodeLibraryDatabase(path.join(dir, 'local-fallback.sqlite'));
    const media = new MediaPipeline({
      blobs: new NodeBlobStore(path.join(dir, 'media')),
      images: nodeImages,
    });

    const subjectPng = await createSubjectTestPNG();
    const assetID = toSwiftUUID('11111111-1111-4111-8111-111111111111');
    const ingested = await media.ingestUploadedFile(subjectPng, 'crimson-card.png', 'image/png', null, assetID);
    db.saveAssetLocally(ingested.asset);

    const engine = new VisualGroundingEngine({ images: nodeImages });
    const service = new VisualGroundingService({
      db,
      media,
      engine,
      getTypeSafeConfig: () => createDefaultTypeSafeExperimentalConfig({ enabled: false }),
      getTypeSafeAPIKey: () => null,
      getCloudAIProvider: () => null,
    });

    const region = await service.locateVisualRegion(assetID, null);
    expect(region.source).toBe('appleVisionSaliency');
    expect(region.found).toBe(true);
    // Should localize around the center red square (approx 0.31..0.68)
    expect(region.rawBox.x).toBeGreaterThan(0.2);
    expect(region.rawBox.y).toBeGreaterThan(0.2);
    expect(region.rawBox.width).toBeLessThan(0.6);

    const cleanBounds = await service.detectCleanContentBounds(assetID);
    expect(cleanBounds.source).toBe('appleVisionSaliency');
    expect(cleanBounds.hasNoise).toBe(true);
    expect(cleanBounds.recommendedCrop).not.toBeNull();

    const paletteRes = await service.extractSubjectPalette(assetID, null);
    expect(paletteRes.colors.length).toBeGreaterThan(0);
    // Top subject color should be strongly red (high R / positive CIELAB a*) rather than white background
    expect(paletteRes.colors[0].a).toBeGreaterThan(30);
    // Persisted into SQLite
    const persisted = db.getAsset(assetID)!;
    expect(persisted.dominantColors[0].hex).toBe(paletteRes.colors[0].hex);

    db.close();
  });

  it('runs 3-signal hybrid semanticSearch and closed-set batchTriageInbox respecting null rejection', async () => {
    const dir = createTempDir();
    const db = openNodeLibraryDatabase(path.join(dir, 'phase2.sqlite'));
    const media = new MediaPipeline({
      blobs: new NodeBlobStore(path.join(dir, 'media')),
      images: nodeImages,
    });

    const archFolder = db.createFolder('Architecture');
    const uiFolder = db.createFolder('UI Design');

    const imgBuf = await createSubjectTestPNG();
    const a1ID = toSwiftUUID('22222222-2222-4222-8222-222222222221');
    const a2ID = toSwiftUUID('22222222-2222-4222-8222-222222222222');

    const r1 = await media.ingestUploadedFile(imgBuf, 'sunset-pavilion.png', 'image/png', null, a1ID);
    const r2 = await media.ingestUploadedFile(imgBuf, 'mystery-clip.png', 'image/png', null, a2ID);
    db.saveAssetLocally({ ...r1.asset, title: 'Concrete Pavilion', tags: ['architecture'] });
    db.saveAssetLocally({ ...r2.asset, title: 'IMG_9921', tags: [] });

    const fakeProvider = new FakeCloudAIProvider({
      embeddingIdentity: 'fake:emb',
      embeddings: {
        'brutalist architecture': [1, 0, 0, 0],
      },
    });
    db.saveVector(a1ID, {
      featurePrint: null,
      embedding: [0.95, 0.05, 0, 0],
      embeddingModel: 'fake:emb',
      precision: 32,
    });
    db.saveVector(a2ID, {
      featurePrint: null,
      embedding: [0.1, 0.9, 0, 0],
      embeddingModel: 'fake:emb',
      precision: 32,
    });

    const mockFetch: FetchLike = async (_input, init) => {
      const bodyStr = Buffer.from(init?.body as Uint8Array).toString('utf8');
      if (bodyStr.includes('"type":"score"')) {
        // Return high Jev visual score for a2 (even though untagged!) and strong score for a1
        return new Response(
          JSON.stringify({
            model: 'jev-latest',
            answers: {
              item_0: { type: 'score', score: 3, confidence: 0.92 },
              item_1: { type: 'score', score: 2, confidence: 0.81 },
            },
            usage: { input_tokens: 200, output_tokens: 15 },
          }),
          { status: 200 },
        );
      }
      // Inbox folder classification: accept Concrete Pavilion -> Architecture (f_0), reject IMG_9921 (low fits_any)
      if (bodyStr.includes('Concrete Pavilion')) {
        return new Response(
          JSON.stringify({
            model: 'jev-latest',
            answers: {
              fits_any: { type: 'noul', noul: 0.91 },
              folder: { type: 'choice', choice: 'f_0', confidence: 0.88, probabilities: { f_0: 0.88, f_1: 0.12 } },
            },
          }),
          { status: 200 },
        );
      }
      return new Response(
        JSON.stringify({
          model: 'jev-latest',
          answers: {
            fits_any: { type: 'noul', noul: 0.18 },
            folder: { type: 'choice', choice: 'f_1', confidence: 0.55, probabilities: { f_0: 0.45, f_1: 0.55 } },
          },
        }),
        { status: 200 },
      );
    };

    const tsCfg = createDefaultTypeSafeExperimentalConfig({
      enabled: true,
      enableSemanticSearch: true,
      enableInboxSmartTriage: true,
      minPresenceProbability: 0.45,
    });
    const engine = new VisualGroundingEngine({ fetchFn: mockFetch, images: nodeImages });
    const service = new VisualGroundingService({
      db,
      media,
      engine,
      getTypeSafeConfig: () => tsCfg,
      getTypeSafeAPIKey: () => 'ts-key',
      getCloudAIProvider: () => fakeProvider,
    });

    // 1. Hybrid 3-signal Semantic Search
    const searchReport = await service.semanticSearch('brutalist architecture', {}, 10);
    expect(searchReport.usedTypeSafeJev).toBe(true);
    expect(searchReport.usedCloudEmbedding).toBe(true);
    expect(searchReport.hits).toHaveLength(2);
    expect(searchReport.hits[0].asset.id).toBe(a1ID);
    expect(searchReport.hits[1].asset.id).toBe(a2ID);

    // 2. Batch Inbox Triage respects null rejection!
    const recs = await service.batchTriageInbox([], 10);
    expect(recs).toHaveLength(2);
    const rec1 = recs.find((r) => r.assetID === a1ID)!;
    const rec2 = recs.find((r) => r.assetID === a2ID)!;
    expect(rec1.recommendedFolderID).toBe(archFolder.id);
    expect(rec1.confidence).toBeGreaterThanOrEqual(0.65);
    expect(rec2.recommendedFolderID).toBeNull();
    expect(rec2.fitProbability).toBeLessThan(0.45);
    expect(uiFolder.id).toBeTruthy();

    // 3. Single-asset suggestFolder respects Jev null rejection (does NOT force fallback)
    const rejectedSuggestion = await service.suggestFolder(a2ID);
    expect(rejectedSuggestion).toBeNull();

    // 4. Visual Match 2-image call
    const matchMock: FetchLike = async (_in, init) => {
      const text = Buffer.from(init?.body as Uint8Array).toString('latin1');
      expect(text).toContain('name="target_image"');
      expect(text).toContain('name="reference_image"');
      return new Response(
        JSON.stringify({
          model: 'jev-latest',
          answers: {
            present: { type: 'noul', noul: 0.95 },
            region: { type: 'box', box: { top: 0.1, bottom: 0.4, left: 0.1, right: 0.4 }, confidence: 0.9 },
          },
        }),
        { status: 200 },
      );
    };
    const matchService = new VisualGroundingService({
      db,
      media,
      engine: new VisualGroundingEngine({ fetchFn: matchMock, images: nodeImages }),
      getTypeSafeConfig: () => tsCfg,
      getTypeSafeAPIKey: () => 'ts-key',
      getCloudAIProvider: () => null,
    });
    const matchRes = await matchService.locateVisualMatch(a1ID, a2ID);
    expect(matchRes.found).toBe(true);
    expect(matchRes.didApplyPadding).toBe(false);

    // Verify helper record factory compiles cleanly
    expect(createDefaultAssetRecord({ id: a1ID, title: 'x', fileName: 'x.png' }).id).toBe(a1ID);

    db.close();
  });
});
