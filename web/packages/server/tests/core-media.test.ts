import crypto from 'node:crypto';
import fs from 'node:fs';
import fsp from 'node:fs/promises';
import os from 'node:os';
import path from 'node:path';
import sharp from 'sharp';
import { afterEach, describe, expect, it, vi } from 'vitest';
import {
  createDefaultMoodboardDocument,
  toSwiftUUID,
} from '@charkle/shared';
import {
  cosineSimilarity,
  decodeFeaturePrintFloat32,
  type LibraryDatabase,
} from '../src/db/library-database.js';
import { wrapLines } from '../src/media/artwork-renderer.js';
import { MediaPipeline } from '../src/media/media-pipeline.js';
import { seedSampleLibrary } from '../src/media/sample-seeder.js';
import { NodeBlobStore } from '../src/runtime/node-blob.js';
import { NodeImageProcessor } from '../src/runtime/node-image.js';
import { openNodeLibraryDatabase } from '../src/runtime/node-sql.js';

const tempDirs: string[] = [];

function makeTempEnv(): { dir: string; db: LibraryDatabase; media: MediaPipeline } {
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'charkle-media-test-'));
  tempDirs.push(dir);
  const db = openNodeLibraryDatabase(path.join(dir, 'library.sqlite'));
  const media = new MediaPipeline({
    blobs: new NodeBlobStore(path.join(dir, 'media')),
    images: new NodeImageProcessor(),
    readLocalFile: async (filePath) => new Uint8Array(await fsp.readFile(filePath)),
  });
  return { dir, db, media };
}

async function makeSolidPng(width: number, height: number, rgb: { r: number; g: number; b: number }): Promise<Buffer> {
  return sharp({
    create: { width, height, channels: 4, background: { ...rgb, alpha: 1 } },
  })
    .png()
    .toBuffer();
}

function makeSimpleWav(durationSec = 0.5): Buffer {
  const sampleRate = 8000;
  const count = Math.floor(sampleRate * durationSec);
  const buf = Buffer.alloc(44 + count * 2);
  buf.write('RIFF', 0, 'ascii');
  buf.writeUInt32LE(36 + count * 2, 4);
  buf.write('WAVE', 8, 'ascii');
  buf.write('fmt ', 12, 'ascii');
  buf.writeUInt32LE(16, 16);
  buf.writeUInt16LE(1, 20);
  buf.writeUInt16LE(1, 22);
  buf.writeUInt32LE(sampleRate, 24);
  buf.writeUInt32LE(sampleRate * 2, 28);
  buf.writeUInt16LE(2, 32);
  buf.writeUInt16LE(16, 34);
  buf.write('data', 36, 'ascii');
  buf.writeUInt32LE(count * 2, 40);
  for (let i = 0; i < count; i++) {
    const val = Math.round(Math.sin((2 * Math.PI * 440 * i) / sampleRate) * 20000);
    buf.writeInt16LE(val, 44 + i * 2);
  }
  return buf;
}

afterEach(() => {
  vi.restoreAllMocks();
  while (tempDirs.length > 0) {
    const dir = tempDirs.pop()!;
    fs.rmSync(dir, { recursive: true, force: true });
  }
});

describe('MediaPipeline (All 8 MediaKinds, Rich Resolvers, Seeder & Pinned LRU Eviction)', () => {
  it('ingests all 8 MediaKind categories with accurate thumbnails, CIELAB colors, fingerprints, waveform & OCR rules', async () => {
    const { db, media } = makeTempEnv();
    try {
      // 1. Image (>520px -> generates both grid520 and preview1400)
      const redPng = await makeSolidPng(800, 600, { r: 215, g: 55, b: 45 });
      const imgRes = await media.ingestUploadedFile(redPng, 'crimson.png', 'image/png');
      expect(imgRes.asset.mediaKind).toBe('image');
      expect(imgRes.asset.pixelWidth).toBe(800);
      expect(imgRes.asset.pixelHeight).toBe(600);
      expect(imgRes.asset.dominantColors.length).toBeGreaterThan(0);
      expect(media.getThumbnailPath(imgRes.asset.id, 'grid520')).not.toBeNull();
      expect(fs.existsSync(media.thumbnailTargetPath(imgRes.asset.id, 'preview1400'))).toBe(true);
      expect(imgRes.vector?.featurePrint).toBeTruthy();

      // Compare fingerprints: similar red scores much higher than blue
      const warmRedPng = await makeSolidPng(300, 300, { r: 205, g: 60, b: 50 });
      const bluePng = await makeSolidPng(300, 300, { r: 30, g: 80, b: 220 });
      const warmRes = await media.ingestUploadedFile(warmRedPng, 'warm.png', 'image/png');
      const blueRes = await media.ingestUploadedFile(bluePng, 'blue.png', 'image/png');
      // <=520px should NOT create preview1400 file
      expect(fs.existsSync(media.thumbnailTargetPath(warmRes.asset.id, 'preview1400'))).toBe(false);

      const fpRed = decodeFeaturePrintFloat32(imgRes.vector!.featurePrint!)!;
      const fpWarm = decodeFeaturePrintFloat32(warmRes.vector!.featurePrint!)!;
      const fpBlue = decodeFeaturePrintFloat32(blueRes.vector!.featurePrint!)!;
      expect(fpRed).toHaveLength(64);
      expect(cosineSimilarity(fpRed, fpWarm)).toBeGreaterThan(cosineSimilarity(fpRed, fpBlue));

      // 2. Animated image (.gif)
      const gifRes = await media.ingestUploadedFile(redPng, 'loop.gif', 'image/gif');
      expect(gifRes.asset.mediaKind).toBe('animatedImage');

      // 3. Video (.mp4)
      const vidRes = await media.ingestUploadedFile(Buffer.from('fake-mp4-bytes'), 'clip.mp4', 'video/mp4');
      expect(vidRes.asset.mediaKind).toBe('video');

      // 4. Document (.md via textSnippet)
      const docRes = await media.ingest({
        type: 'textSnippet',
        title: 'Design Notes',
        text: '# Heading\n\nTypography and color rhythm.',
      });
      expect(docRes.asset.mediaKind).toBe('document');
      expect(docRes.asset.richMetadata?.isMarkdown).toBe(true);
      expect(docRes.asset.ocrText).toContain('Typography');

      // 5. DesignFile (.svg)
      const svgBuf = Buffer.from('<svg xmlns="http://www.w3.org/2000/svg" width="200" height="200"><rect width="200" height="200" fill="#10B981"/></svg>');
      const designRes = await media.ingestUploadedFile(svgBuf, 'icon.svg', 'image/svg+xml');
      expect(designRes.asset.mediaKind).toBe('designFile');
      expect(designRes.asset.dominantColors.length).toBeGreaterThan(0);

      // 6. Audio (.wav) -> 48 waveform peaks, duration parsed, NO dominantColors & NO OCR per PARITY_SPEC
      const audioRes = await media.ingestUploadedFile(makeSimpleWav(0.6), 'loop.wav', 'audio/wav');
      expect(audioRes.asset.mediaKind).toBe('audio');
      expect(audioRes.asset.waveformPeaks).toHaveLength(48);
      expect(audioRes.asset.durationSeconds).toBeCloseTo(0.6, 1);
      expect(audioRes.asset.dominantColors).toEqual([]);
      expect(audioRes.asset.ocrText).toBeNull();

      // 7. Model3D (.obj) -> model3DFormat set, NO OCR per PARITY_SPEC
      const objRes = await media.ingestUploadedFile(Buffer.from('v 0 0 0\nv 1 0 0\nv 0 1 0\nf 1 2 3\n'), 'cube.obj', 'model/obj');
      expect(objRes.asset.mediaKind).toBe('model3D');
      expect(objRes.asset.richMetadata?.model3DFormat).toBe('OBJ');
      expect(objRes.asset.ocrText).toBeNull();

      // 8. Color swatch CaptureInput
      const swatchRes = await media.ingest({ type: 'colorSwatch', hex: '#D4A373', title: 'Warm Sand' });
      expect(swatchRes.asset.dominantColors[0].hex).toBe('#D4A373');
      expect(swatchRes.asset.tags).toContain('色卡');
    } finally {
      db.close();
    }
  });

  it('enforces cohesive social post webBookmark storage & standalone media extraction', async () => {
    const { db, media } = makeTempEnv();
    try {
      const samplePhoto = await makeSolidPng(400, 300, { r: 78, g: 125, b: 150 });
      vi.stubGlobal(
        'fetch',
        vi.fn(async (input: string | URL) => {
          const url = String(input);
          if (url.includes('api.fxtwitter.com')) {
            return new Response(
              JSON.stringify({
                tweet: {
                  text: 'Minimal architectural concrete study in Kyoto.',
                  author: { name: 'Kengo Studio', screen_name: 'kengo_arch' },
                  likes: 920,
                  retweets: 112,
                  media: {
                    all: [
                      {
                        type: 'photo',
                        url: 'https://pbs.twimg.com/media/testphoto.jpg',
                        thumbnail_url: 'https://pbs.twimg.com/media/testphoto.jpg',
                      },
                    ],
                  },
                },
              }),
              { status: 200, headers: { 'Content-Type': 'application/json' } },
            );
          }
          if (url.includes('pbs.twimg.com')) {
            return new Response(new Uint8Array(samplePhoto), {
              status: 200,
              headers: { 'Content-Type': 'image/png' },
            });
          }
          return new Response('not found', { status: 404 });
        }),
      );

      const postRes = await media.ingest({
        type: 'webURL',
        url: 'https://x.com/kengo_arch/status/1888888888888888888',
      });
      // Cohesive invariant: NEVER flattened to 'image'
      expect(postRes.asset.mediaKind).toBe('webBookmark');
      expect(postRes.asset.richMetadata?.socialPost?.platform).toBe('x');
      expect(postRes.asset.richMetadata?.socialPost?.authorHandle).toBe('kengo_arch');
      expect(postRes.asset.richMetadata?.socialPost?.attachments).toHaveLength(1);
      expect(postRes.asset.richMetadata?.socialPost?.attachments[0].url).toContain('name=orig');
      expect(postRes.asset.tags).toContain('X');

      // Standalone media extraction
      const extracted = await media.extractSocialMedia(postRes.asset, 0);
      expect(extracted).toHaveLength(1);
      expect(extracted[0].asset.mediaKind).toBe('image');
      expect(extracted[0].asset.title).toBe('@kengo_arch 图片 #1');
      expect(extracted[0].asset.notes).toContain('来源推文：Kengo Studio (@kengo_arch) · X');
      expect(extracted[0].asset.notes).toContain('原推文链接：https://x.com/kengo_arch/status/1888888888888888888');
      expect(extracted[0].asset.sourceURL).toBe('https://x.com/kengo_arch/status/1888888888888888888');
    } finally {
      db.close();
    }
  });

  it('evicts oldest unpinned originals by LRU while strictly protecting pinned assets and pinned boards', async () => {
    const { db, media } = makeTempEnv();
    try {
      const payload = Buffer.alloc(600 * 1024, 0x42); // 600 KB each

      const r1 = await media.ingestUploadedFile(payload, 'old-unpinned.bin', 'application/octet-stream');
      const r2 = await media.ingestUploadedFile(payload, 'pinned-asset.bin', 'application/octet-stream');
      const r3 = await media.ingestUploadedFile(payload, 'board-pinned.bin', 'application/octet-stream');
      const r4 = await media.ingestUploadedFile(payload, 'recent-unpinned.bin', 'application/octet-stream');

      db.saveAssetLocally(r1.asset);
      db.saveAssetLocally({ ...r2.asset, pinnedOffline: true });
      db.saveAssetLocally(r3.asset);
      db.saveAssetLocally(r4.asset);

      // Pin a moodboard referencing r3
      db.saveBoardLocally(
        createDefaultMoodboardDocument({
          id: toSwiftUUID(crypto.randomUUID()),
          title: 'Pinned Offline Board',
          pinnedOffline: true,
          nodes: [
            {
              id: toSwiftUUID(crypto.randomUUID()),
              kind: { type: 'assetRef', assetID: r3.asset.id, weight: 1, autoplayLoop: false },
              frame: { x: 0, y: 0, width: 200, height: 200 },
              zIndex: 1,
              rotationDegrees: 0,
              flipHorizontal: false,
              flipVertical: false,
              isLocked: false,
              editorialOrder: 0,
              updatedAt: new Date().toISOString(),
            },
          ],
        }),
      );

      // Set explicit LRU timestamps: r1 oldest, r4 newest
      db.touchOriginal(r1.asset.id, new Date('2026-01-01T00:00:00Z'));
      db.touchOriginal(r2.asset.id, new Date('2026-01-02T00:00:00Z'));
      db.touchOriginal(r3.asset.id, new Date('2026-01-03T00:00:00Z'));
      db.touchOriginal(r4.asset.id, new Date('2026-11-01T00:00:00Z'));

      // Total originals = 2.4 MB; set budget to 1.8 MB (fits 3 files -> must evict ONLY r1!)
      media.setCacheBudgetBytes(1_850_000);
      const stats = await media.evictCacheNow(db);

      expect(media.getOriginalPath(r1.asset)).toBeNull(); // Oldest unpinned evicted!
      expect(db.getAsset(r1.asset.id)?.isLocalOriginalCached).toBe(false);
      expect(media.getOriginalPath(r2.asset)).not.toBeNull(); // Pinned asset protected!
      expect(media.getOriginalPath(r3.asset)).not.toBeNull(); // Pinned board asset protected!
      expect(media.getOriginalPath(r4.asset)).not.toBeNull(); // Newer unpinned retained!
      expect(stats.cachedOriginalCount).toBe(3);

      // Even if budget drops below pinned size (1 MiB), pinned assets MUST NEVER be evicted
      media.setCacheBudgetBytes(1024 * 1024);
      await media.evictCacheNow(db);
      expect(media.getOriginalPath(r4.asset)).toBeNull();
      expect(media.getOriginalPath(r2.asset)).not.toBeNull();
      expect(media.getOriginalPath(r3.asset)).not.toBeNull();
    } finally {
      db.close();
    }
  });

  it('seeds complete curated multi-media starter library idempotently', async () => {
    const { db, media } = makeTempEnv();
    try {
      const seededFirst = await seedSampleLibrary(db, media);
      expect(seededFirst).toBe(true);
      const seededSecond = await seedSampleLibrary(db, media);
      expect(seededSecond).toBe(false);

      const assets = db.fetchAssets();
      expect(assets.length).toBeGreaterThanOrEqual(16);
      expect(assets.some((a) => a.richMetadata?.githubRepo)).toBe(true);
      expect(assets.some((a) => a.richMetadata?.socialPost && a.mediaKind === 'webBookmark')).toBe(true);
      expect(assets.some((a) => a.mediaKind === 'audio' && a.waveformPeaks.length === 48)).toBe(true);
      expect(assets.some((a) => a.mediaKind === 'model3D')).toBe(true);
      expect(db.fetchFolders().length).toBe(4);
      expect(db.fetchSmartFolders().length).toBe(1);
      expect(db.fetchBoards().length).toBe(1);
    } finally {
      db.close();
    }
  });

  it('wraps English descriptions on word boundaries without mid-word breaks', () => {
    const desc =
      'Neutral Gallery-First surfaces, concentric radii, CIELAB palettes, and Kubai motion curves for visual curation tools.';
    const lines = wrapLines(desc, 44, 4);
    expect(lines.length).toBeGreaterThanOrEqual(2);
    expect(lines.length).toBeLessThanOrEqual(4);
    // Ensure no word was broken mid-word across lines
    const rejoined = lines.join(' ');
    expect(rejoined).toContain('concentric radii');
    expect(rejoined).toContain('motion curves');
    expect(rejoined).toContain('curation tools.');

    // Long unspaced token still wraps safely without throwing
    const longToken = wrapLines('https://example.com/' + 'a'.repeat(80), 30, 3);
    expect(longToken.length).toBe(3);
    expect(longToken[2].endsWith('…')).toBe(true);
  });
});
