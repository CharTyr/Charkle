import crypto from 'node:crypto';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import JSZip from 'jszip';
import sharp from 'sharp';
import { afterEach, describe, expect, it } from 'vitest';
import {
  createDefaultAssetRecord,
  createDefaultMoodboardDocument,
  labFromHex,
  toSwiftUUID,
  type FigmaBridgeBoardManifest,
  type MoodboardDocument,
} from '@charkle/shared';
import { createApp, createServerContext } from '../src/app.js';
import { FigmaBridgeExporter } from '../src/export/figma-bridge-exporter.js';
import { MoodboardExporter } from '../src/export/moodboard-exporter.js';

const tempDirs: string[] = [];

function createTempDir(): string {
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'charkle-ai-export-'));
  tempDirs.push(dir);
  return dir;
}

afterEach(() => {
  while (tempDirs.length > 0) {
    const dir = tempDirs.pop()!;
    fs.rmSync(dir, { recursive: true, force: true });
  }
});

function sha256Hex(buf: Uint8Array): string {
  return crypto.createHash('sha256').update(buf).digest('hex');
}

/**
 * Exact validation port of `figma-plugin/code.js` (`validate(board)`) + `ui.html` SHA-256 verification.
 */
async function validateCharkleboardLikeFigmaPlugin(zipBuffer: Buffer): Promise<FigmaBridgeBoardManifest> {
  const zip = await JSZip.loadAsync(zipBuffer);
  const boardEntry = zip.file('board.json');
  expect(boardEntry).not.toBeNull();
  const reportEntry = zip.file('migration-report.json');
  expect(reportEntry).not.toBeNull();

  const board = JSON.parse(await boardEntry!.async('string')) as FigmaBridgeBoardManifest;
  expect(board.format).toBe('charkle-figma-bridge');
  expect(board.version).toBe(1);
  expect(Array.isArray(board.objects)).toBe(true);
  expect(board.objects.length).toBeGreaterThanOrEqual(1);
  expect(board.objects.length).toBeLessThanOrEqual(10_000);

  const ids = new Set<string>();
  const allowedKinds = ['image', 'note', 'groupFrame', 'paletteStrip', 'unsupported'];

  for (const object of board.objects) {
    expect(typeof object.id).toBe('string');
    expect(ids.has(object.id)).toBe(false);
    ids.add(object.id);
    expect(allowedKinds).toContain(object.kind);
    if (object.kind === 'unsupported') continue;

    const g = object.geometry;
    expect(Number.isFinite(g.x)).toBe(true);
    expect(Number.isFinite(g.y)).toBe(true);
    expect(g.width).toBeGreaterThan(0);
    expect(g.height).toBeGreaterThan(0);
    expect(g.width).toBeLessThanOrEqual(1e7);
    expect(g.height).toBeLessThanOrEqual(1e7);
    expect(Number.isFinite(g.angle)).toBe(true);

    if (object.kind === 'image') {
      const im = object.image!;
      expect(Number.isInteger(im.pixelWidth) && im.pixelWidth > 0).toBe(true);
      expect(Number.isInteger(im.pixelHeight) && im.pixelHeight > 0).toBe(true);
      expect(im.tiles.length).toBe(Math.ceil(im.pixelWidth / 4096) * Math.ceil(im.pixelHeight / 4096));

      if (im.animation) {
        expect(im.animation.file).toMatch(/^originals\/[A-Za-z0-9._-]+\.gif$/i);
        expect(im.animation.sha256).toMatch(/^[a-f0-9]{64}$/);
        const animEntry = zip.file(im.animation.file);
        expect(animEntry).not.toBeNull();
        const animBytes = await animEntry!.async('uint8array');
        expect(sha256Hex(animBytes)).toBe(im.animation.sha256);
      }

      const seen = new Set<string>();
      for (const tile of im.tiles) {
        expect(tile.file).toMatch(/^tiles\/[A-Za-z0-9._-]+\.png$/i);
        expect(tile.sha256).toMatch(/^[a-f0-9]{64}$/);
        expect(tile.x % 4096).toBe(0);
        expect(tile.y % 4096).toBe(0);
        expect(tile.width).toBe(Math.min(4096, im.pixelWidth - tile.x));
        expect(tile.height).toBe(Math.min(4096, im.pixelHeight - tile.y));
        expect(tile.width).toBeLessThanOrEqual(4096);
        expect(tile.height).toBeLessThanOrEqual(4096);

        const key = `${tile.x}:${tile.y}`;
        expect(seen.has(key)).toBe(false);
        seen.add(key);

        const tileEntry = zip.file(tile.file);
        expect(tileEntry).not.toBeNull();
        const tileBytes = await tileEntry!.async('uint8array');
        expect(sha256Hex(tileBytes)).toBe(tile.sha256);

        const meta = await sharp(Buffer.from(tileBytes)).metadata();
        expect(meta.format).toBe('png');
        expect(meta.width).toBe(tile.width);
        expect(meta.height).toBe(tile.height);
      }
    }
  }

  return board;
}

describe('MoodboardExporter & FigmaBridgeExporter (.charkleboard)', () => {
  it('renders High-DPI 1x/2x PNG and JPEG moodboards with crops, rotations, flips, notes, groups, connectors, ink strokes, and palette strips', async () => {
    const assetID = toSwiftUUID('77777777-7777-4777-8777-777777777701');
    const nodeImgID = toSwiftUUID('77777777-7777-4777-8777-777777777711');
    const nodeNoteID = toSwiftUUID('77777777-7777-4777-8777-777777777712');
    const nodeGrpID = toSwiftUUID('77777777-7777-4777-8777-777777777713');
    const nodePalID = toSwiftUUID('77777777-7777-4777-8777-777777777714');

    const imgBuf = await sharp({
      create: { width: 400, height: 300, channels: 3, background: { r: 186, g: 107, b: 85 } },
    }).png().toBuffer();

    const asset = createDefaultAssetRecord({
      id: assetID,
      title: 'Clay Tile',
      fileName: 'clay.png',
      pixelWidth: 400,
      pixelHeight: 300,
      dominantColors: [labFromHex('#BA6B55', 0.6), labFromHex('#D4A373', 0.4)],
    });

    const now = new Date().toISOString();
    const doc: MoodboardDocument = createDefaultMoodboardDocument({
      id: toSwiftUUID('77777777-7777-4777-8777-777777777799'),
      title: '光、纸与泥 · Studio Board',
      subtitle: 'High-DPI Freeform Test',
      mode: { type: 'freeform' },
      extractedPalette: [labFromHex('#BA6B55'), labFromHex('#D4A373'), labFromHex('#4E7D96')],
      nodes: [
        {
          id: nodeGrpID,
          kind: { type: 'groupFrame', title: '材质分区', tint: 'terracotta' },
          frame: { x: 20, y: 20, width: 620, height: 360 },
          zIndex: 0,
          rotationDegrees: 0,
          flipHorizontal: false,
          flipVertical: false,
          isLocked: false,
          editorialOrder: 0,
          updatedAt: now,
        },
        {
          id: nodeImgID,
          kind: {
            type: 'assetRef',
            assetID,
            crop: { x: 0.1, y: 0.1, width: 0.8, height: 0.8 },
            weight: 2,
            autoplayLoop: false,
          },
          frame: { x: 40, y: 70, width: 280, height: 210 },
          zIndex: 1,
          rotationDegrees: 6,
          flipHorizontal: true,
          flipVertical: false,
          isLocked: false,
          editorialOrder: 1,
          updatedAt: now,
        },
        {
          id: nodeNoteID,
          kind: {
            type: 'note',
            title: '灯光建议',
            text: '保持 3200K 暖侧光，突出粗陶颗粒质感。',
            style: 'warm',
            fontSize: 14,
          },
          frame: { x: 360, y: 80, width: 240, height: 150 },
          zIndex: 2,
          rotationDegrees: 0,
          flipHorizontal: false,
          flipVertical: false,
          isLocked: false,
          editorialOrder: 2,
          updatedAt: now,
        },
        {
          id: nodePalID,
          kind: { type: 'paletteStrip', colors: [labFromHex('#BA6B55')], autoSyncWithBoard: true },
          frame: { x: 40, y: 300, width: 560, height: 56 },
          zIndex: 3,
          rotationDegrees: 0,
          flipHorizontal: false,
          flipVertical: false,
          isLocked: false,
          editorialOrder: 3,
          updatedAt: now,
        },
      ],
      connectors: [
        {
          id: toSwiftUUID('77777777-7777-4777-8777-777777777721'),
          fromNodeID: nodeNoteID,
          fromAnchor: 'leading',
          toNodeID: nodeImgID,
          toAnchor: 'auto',
          toNormalizedPoint: { x: 0.65, y: 0.45 },
          label: '高光细节',
          colorHex: '#BA6B55',
          style: 'curved',
          dashed: true,
          updatedAt: now,
        },
      ],
      inkStrokes: [
        {
          id: toSwiftUUID('77777777-7777-4777-8777-777777777731'),
          points: [
            { x: 60, y: 90, pressure: 1 },
            { x: 140, y: 120, pressure: 1 },
            { x: 200, y: 100, pressure: 1 },
          ],
          colorHex: '#D95D48',
          lineWidth: 3.5,
          opacity: 0.92,
          zIndex: 10,
          createdAt: now,
        },
      ],
    });

    const png1x = await MoodboardExporter.exportImage({
      document: doc,
      assetsByID: { [assetID]: asset },
      loadAssetBuffer: async () => imgBuf,
      format: 'png',
      options: { scale: 1, includeAnnotations: true, includePaletteStrip: true, darkAppearance: false },
    });
    const png2x = await MoodboardExporter.exportImage({
      document: doc,
      assetsByID: { [assetID]: asset },
      loadAssetBuffer: async () => imgBuf,
      format: 'png',
      options: { scale: 2, includeAnnotations: true, includePaletteStrip: true, darkAppearance: true },
    });
    const jpg1x = await MoodboardExporter.exportImage({
      document: doc,
      assetsByID: { [assetID]: asset },
      loadAssetBuffer: async () => imgBuf,
      format: 'jpeg',
      options: { scale: 1, includeAnnotations: false, includePaletteStrip: false },
    });

    const m1 = await sharp(png1x.buffer).metadata();
    const m2 = await sharp(png2x.buffer).metadata();
    const mj = await sharp(jpg1x.buffer).metadata();

    expect(m1.format).toBe('png');
    expect(m2.format).toBe('png');
    expect(mj.format).toBe('jpeg');
    expect(m2.width).toBe(m1.width! * 2);
    expect(m2.height).toBe(m1.height! * 2);
  });

  it('produces valid .charkleboard ZIP passing all figma-plugin/code.js invariants including >4096px tiling, crop baking, and animated GIF preservation', async () => {
    const hugeID = toSwiftUUID('88888888-8888-4888-8888-888888888801');
    const gifID = toSwiftUUID('88888888-8888-4888-8888-888888888802');
    const croppedID = toSwiftUUID('88888888-8888-4888-8888-888888888803');

    // Create a >4096px lossless PNG (4200 x 4150 -> must split into 2x2 = 4 tiles!)
    const hugePng = await sharp({
      create: { width: 4200, height: 4150, channels: 3, background: { r: 78, g: 125, b: 150 } },
    })
      .png({ compressionLevel: 1 })
      .toBuffer();

    // Create a 2-frame animated GIF (40x40 stacked 2 pages -> pages: 2)
    const frameBuf = Buffer.alloc(40 * 80 * 4, 200);
    // Tint second frame differently
    for (let i = 40 * 40 * 4; i < frameBuf.length; i += 4) {
      frameBuf[i] = 220;
      frameBuf[i + 1] = 60;
      frameBuf[i + 2] = 60;
      frameBuf[i + 3] = 255;
    }
    const animatedGif = await sharp(frameBuf, {
      raw: { width: 40, height: 80, channels: 4, pageHeight: 40 },
    })
      .gif({ delay: [120, 120] })
      .toBuffer();

    // Create a 400x200 image for crop baking
    const cropSourcePng = await sharp({
      create: { width: 400, height: 200, channels: 3, background: { r: 212, g: 163, b: 115 } },
    })
      .png()
      .toBuffer();

    const assetsByID = new Map([
      [
        hugeID,
        createDefaultAssetRecord({
          id: hugeID,
          title: 'Ultra High Res Poster',
          fileName: 'poster-huge.png',
          pixelWidth: 4200,
          pixelHeight: 4150,
          mediaKind: 'image',
        }),
      ],
      [
        gifID,
        createDefaultAssetRecord({
          id: gifID,
          title: 'Animated Loop',
          fileName: 'loop.gif',
          pixelWidth: 40,
          pixelHeight: 40,
          mediaKind: 'animatedImage',
        }),
      ],
      [
        croppedID,
        createDefaultAssetRecord({
          id: croppedID,
          title: 'Cropped Detail',
          fileName: 'detail.png',
          pixelWidth: 400,
          pixelHeight: 200,
          mediaKind: 'image',
        }),
      ],
    ]);

    const originals = new Map<string, { buffer: Buffer; fileName: string }>([
      [hugeID, { buffer: hugePng, fileName: 'poster-huge.png' }],
      [gifID, { buffer: animatedGif, fileName: 'loop.gif' }],
      [croppedID, { buffer: cropSourcePng, fileName: 'detail.png' }],
    ]);

    const now = new Date().toISOString();
    const nHuge = toSwiftUUID('88888888-8888-4888-8888-888888888811');
    const nGif = toSwiftUUID('88888888-8888-4888-8888-888888888812');
    const nCrop = toSwiftUUID('88888888-8888-4888-8888-888888888813');
    const nNote = toSwiftUUID('88888888-8888-4888-8888-888888888814');
    const nGroup = toSwiftUUID('88888888-8888-4888-8888-888888888815');

    const doc = createDefaultMoodboardDocument({
      id: toSwiftUUID('88888888-8888-4888-8888-888888888899'),
      title: 'Figma Bridge Full Parity Board',
      subtitle: 'Tiling + GIF + Crop',
      mode: { type: 'freeform' },
      extractedPalette: [labFromHex('#4E7D96'), labFromHex('#D4A373')],
      nodes: [
        {
          id: nGroup,
          kind: { type: 'groupFrame', title: '主视觉区', tint: 'ocean' },
          frame: { x: 0, y: 0, width: 900, height: 500 },
          zIndex: 0,
          rotationDegrees: 0,
          flipHorizontal: false,
          flipVertical: false,
          isLocked: false,
          editorialOrder: 0,
          updatedAt: now,
        },
        {
          id: nHuge,
          kind: { type: 'assetRef', assetID: hugeID, crop: null, weight: 2, autoplayLoop: false },
          frame: { x: 40, y: 60, width: 320, height: 316 },
          zIndex: 1,
          rotationDegrees: 15,
          flipHorizontal: true,
          flipVertical: false,
          isLocked: true,
          editorialOrder: 1,
          updatedAt: now,
        },
        {
          id: nGif,
          kind: { type: 'assetRef', assetID: gifID, crop: null, weight: 1, autoplayLoop: true },
          frame: { x: 400, y: 60, width: 160, height: 160 },
          zIndex: 2,
          rotationDegrees: 0,
          flipHorizontal: false,
          flipVertical: false,
          isLocked: false,
          editorialOrder: 2,
          updatedAt: now,
        },
        {
          id: nCrop,
          kind: {
            type: 'assetRef',
            assetID: croppedID,
            crop: { x: 0.25, y: 0.25, width: 0.5, height: 0.5 },
            weight: 1,
            autoplayLoop: false,
          },
          frame: { x: 400, y: 250, width: 200, height: 100 },
          zIndex: 3,
          rotationDegrees: 0,
          flipHorizontal: false,
          flipVertical: false,
          isLocked: false,
          editorialOrder: 3,
          updatedAt: now,
        },
        {
          id: nNote,
          kind: { type: 'note', title: '说明', text: '无损导入检查', style: 'sage', fontSize: 14 },
          frame: { x: 640, y: 60, width: 220, height: 140 },
          zIndex: 4,
          rotationDegrees: 0,
          flipHorizontal: false,
          flipVertical: false,
          isLocked: false,
          editorialOrder: 4,
          updatedAt: now,
        },
      ],
      connectors: [
        {
          id: toSwiftUUID('88888888-8888-4888-8888-888888888821'),
          fromNodeID: nNote,
          fromAnchor: 'leading',
          toNodeID: nGif,
          toAnchor: 'trailing',
          label: 'GIF 动效',
          colorHex: '#4E7D96',
          style: 'elbow',
          dashed: false,
          updatedAt: now,
        },
      ],
      inkStrokes: [
        {
          id: toSwiftUUID('88888888-8888-4888-8888-888888888831'),
          points: [
            { x: 10, y: 10, pressure: 1 },
            { x: 120, y: 80, pressure: 1 },
          ],
          colorHex: '#D95D48',
          lineWidth: 3.5,
          opacity: 0.92,
          zIndex: 9,
          createdAt: now,
        },
      ],
    });

    const exported = await FigmaBridgeExporter.exportBundle({
      document: doc,
      assetsByID,
      loadOriginalBuffer: async (id) => originals.get(id) ?? null,
      loadThumbnailBuffer: async () => null,
      options: { includeAnnotations: true, includePaletteStrip: true, darkAppearance: false },
    });

    // Run full figma-plugin/code.js + ui.html invariant validator!
    const board = await validateCharkleboardLikeFigmaPlugin(exported.zipBuffer);

    expect(board.report.imageCount).toBe(3);
    expect(board.report.noteCount).toBe(1);
    expect(board.report.groupCount).toBe(1);
    expect(board.report.paletteCount).toBe(1); // auto-synthesized board-palette-header
    expect(board.report.connectorCount).toBe(1);
    expect(board.report.strokeCount).toBe(1);

    // Check >4096px image tiled into 4 tiles (2x2)
    const hugeObj = board.objects.find((o) => o.id === nHuge)!;
    expect(hugeObj.image!.pixelWidth).toBe(4200);
    expect(hugeObj.image!.pixelHeight).toBe(4150);
    expect(hugeObj.image!.tiles).toHaveLength(4);
    expect(hugeObj.geometry.angle).toBe(15);
    expect(hugeObj.geometry.flipX).toBe(true);
    expect(hugeObj.locked).toBe(true);

    // Check animated GIF preserved natively for FigJam `figma.createGif`
    const gifObj = board.objects.find((o) => o.id === nGif)!;
    expect(gifObj.image!.animated).toBe(true);
    expect(gifObj.image!.animation?.file).toBe(`originals/${gifID}.gif`);
    expect(gifObj.warnings).toContain('动画 GIF 在 Figma Design 中以静态首帧导入，原始 GIF 已归档');

    // Check cropped image baked to exact 200x100 pixels!
    const cropObj = board.objects.find((o) => o.id === nCrop)!;
    expect(cropObj.image!.pixelWidth).toBe(200);
    expect(cropObj.image!.pixelHeight).toBe(100);
  });

  it('serves .charkleboard ZIP with X-Charkle-Bridge-Report header over HTTP route', async () => {
    const dir = createTempDir();
    const ctx = createServerContext({ dataDir: dir });
    const app = createApp(ctx, { staticClientDir: null });

    const user = await ctx.auth.setupAdmin('admin', 'strong-password-123');
    const pat = ctx.auth.createApiToken(user.id, 'export-pat', ['read', 'write']);

    const imgBuf = await sharp({
      create: { width: 300, height: 200, channels: 3, background: { r: 100, g: 130, b: 160 } },
    })
      .png()
      .toBuffer();
    const aid = toSwiftUUID('99999999-9999-4999-8999-999999999901');
    const ing = await ctx.media.ingestUploadedFile(imgBuf, 'card.png', 'image/png', null, aid);
    ctx.db.saveAssetLocally(ing.asset);

    const boardID = toSwiftUUID('99999999-9999-4999-8999-999999999999');
    const now = new Date().toISOString();
    ctx.db.saveBoardLocally(
      createDefaultMoodboardDocument({
        id: boardID,
        title: 'Export HTTP Test',
        nodes: [
          {
            id: toSwiftUUID('99999999-9999-4999-8999-999999999911'),
            kind: { type: 'assetRef', assetID: aid, crop: null, weight: 1, autoplayLoop: false },
            frame: { x: 0, y: 0, width: 300, height: 200 },
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

    const res = await app.request(`/api/v1/boards/${boardID}/export/figma`, {
      method: 'POST',
      headers: {
        Authorization: `Bearer ${pat.token}`,
        'Content-Type': 'application/json',
      },
      body: JSON.stringify({ options: { includeAnnotations: true, includePaletteStrip: false } }),
    });

    expect(res.status).toBe(200);
    expect(res.headers.get('content-type')).toBe('application/zip');
    const reportHeader = res.headers.get('x-charkle-bridge-report');
    expect(reportHeader).toBeTruthy();
    const report = JSON.parse(decodeURIComponent(reportHeader!));
    expect(report.imageCount).toBe(1);

    const zipBuf = Buffer.from(await res.arrayBuffer());
    await validateCharkleboardLikeFigmaPlugin(zipBuf);

    ctx.db.close();
  });

  it('crops EXIF-rotated orientation-6 portrait JPEGs upright and preserves strict node Z-order interleaving in MoodboardExporter (P0-05, P1-16)', async () => {
    // 1. EXIF orientation 6 portrait: raw 300x100 (left=red, right=blue) -> upright 100x300 (top=red, bottom=blue)
    const rotatedJpeg = await sharp(
      Buffer.from(
        `<svg xmlns="http://www.w3.org/2000/svg" width="300" height="100">
          <rect x="0" y="0" width="150" height="100" fill="#E63946"/>
          <rect x="150" y="0" width="150" height="100" fill="#1D4ED8"/>
        </svg>`,
      ),
    )
      .withMetadata({ orientation: 6 })
      .jpeg({ quality: 95 })
      .toBuffer();

    const assetID = toSwiftUUID('88888888-8888-4888-8888-888888888801');
    const asset = createDefaultAssetRecord({
      id: assetID,
      title: 'Portrait EXIF',
      fileName: 'portrait.jpg',
      pixelWidth: 100,
      pixelHeight: 300,
    });
    const now = new Date().toISOString();
    const exifDoc = createDefaultMoodboardDocument({
      id: toSwiftUUID('88888888-8888-4888-8888-888888888890'),
      title: 'EXIF Crop Test',
      mode: { type: 'freeform' },
      nodes: [
        {
          id: toSwiftUUID('88888888-8888-4888-8888-888888888811'),
          kind: {
            type: 'assetRef',
            assetID,
            // Bottom half of upright portrait -> MUST be blue!
            crop: { x: 0.1, y: 0.6, width: 0.8, height: 0.35 },
            weight: 1,
            autoplayLoop: false,
          },
          frame: { x: 20, y: 20, width: 200, height: 200 },
          zIndex: 1,
          rotationDegrees: 0,
          flipHorizontal: false,
          flipVertical: false,
          isLocked: false,
          editorialOrder: 0,
          updatedAt: now,
        },
      ],
    });

    const exifRendered = await MoodboardExporter.exportImage({
      document: exifDoc,
      assetsByID: { [assetID]: asset },
      loadAssetBuffer: async () => rotatedJpeg,
      format: 'png',
      options: { scale: 1, includePaletteStrip: false, includeAnnotations: false, padding: 20 },
    });
    const { data: exifRaw, info: exifInfo } = await sharp(exifRendered.buffer)
      .ensureAlpha()
      .raw()
      .toBuffer({ resolveWithObject: true });
    // Count strongly blue vs strongly red pixels in the rendered canvas:
    // bottom half of upright orientation-6 portrait is blue (#1D4ED8), top half is red (#E63946).
    let bluePixels = 0;
    let redPixels = 0;
    for (let p = 0; p < exifRaw.length; p += 4) {
      const r = exifRaw[p];
      const b = exifRaw[p + 2];
      if (b > r + 60) bluePixels++;
      else if (r > b + 60) redPixels++;
    }
    expect(bluePixels).toBeGreaterThan(5000);
    expect(redPixels).toBeLessThan(100);

    // 2. Z-order interleaving: Note(z=1) BEHIND Red Image(z=5), and Ink Note(z=10) ABOVE Red Image(z=5)
    const redPng = await sharp({
      create: { width: 300, height: 300, channels: 3, background: { r: 220, g: 30, b: 30 } },
    })
      .png()
      .toBuffer();
    const redAssetID = toSwiftUUID('88888888-8888-4888-8888-888888888802');
    const redAsset = createDefaultAssetRecord({
      id: redAssetID,
      title: 'Solid Red',
      fileName: 'red.png',
      pixelWidth: 300,
      pixelHeight: 300,
    });
    const zDoc = createDefaultMoodboardDocument({
      id: toSwiftUUID('88888888-8888-4888-8888-888888888891'),
      title: 'Z-Order Test',
      mode: { type: 'freeform' },
      nodes: [
        {
          id: toSwiftUUID('88888888-8888-4888-8888-888888888821'),
          kind: { type: 'note', title: 'Behind', text: 'Should be covered', style: 'paper', fontSize: 16 },
          frame: { x: 0, y: 0, width: 200, height: 200 },
          zIndex: 1,
          rotationDegrees: 0,
          flipHorizontal: false,
          flipVertical: false,
          isLocked: false,
          editorialOrder: 0,
          updatedAt: now,
        },
        {
          id: toSwiftUUID('88888888-8888-4888-8888-888888888822'),
          kind: { type: 'assetRef', assetID: redAssetID, crop: null, weight: 1, autoplayLoop: false },
          frame: { x: 0, y: 0, width: 300, height: 200 },
          zIndex: 5,
          rotationDegrees: 0,
          flipHorizontal: false,
          flipVertical: false,
          isLocked: false,
          editorialOrder: 1,
          updatedAt: now,
        },
        {
          id: toSwiftUUID('88888888-8888-4888-8888-888888888823'),
          kind: { type: 'note', title: 'Above', text: 'Should cover right side', style: 'ink', fontSize: 16 },
          frame: { x: 180, y: 0, width: 120, height: 200 },
          zIndex: 10,
          rotationDegrees: 0,
          flipHorizontal: false,
          flipVertical: false,
          isLocked: false,
          editorialOrder: 2,
          updatedAt: now,
        },
      ],
    });
    const zRendered = await MoodboardExporter.exportImage({
      document: zDoc,
      assetsByID: { [redAssetID]: redAsset },
      loadAssetBuffer: async () => redPng,
      format: 'png',
      options: { scale: 1, includePaletteStrip: false, includeAnnotations: false, padding: 20 },
    });
    const { data: zRaw, info: zInfo } = await sharp(zRendered.buffer)
      .ensureAlpha()
      .raw()
      .toBuffer({ resolveWithObject: true });

    // Canvas has offsetX = 20, offsetY = 20 + 48 = 68; red image occupies x: 20..320, y: 68..268.
    // Left region (x = 100, y = 168): z=5 red image MUST occlude z=1 paper note -> red dominant!
    const leftIdx = (168 * zInfo.width + 100) * 4;
    expect(zRaw[leftIdx]).toBeGreaterThan(170);
    expect(zRaw[leftIdx + 1]).toBeLessThan(80);

    // Right region (x = 250, y = 168): z=10 dark ink note (x: 200..320) MUST sit ABOVE z=5 red image -> dark low R!
    const rightIdx = (168 * zInfo.width + 250) * 4;
    expect(zRaw[rightIdx]).toBeLessThan(70);
  });
});
