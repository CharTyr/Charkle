import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import zlib from 'node:zlib';
import sharp from 'sharp';
import { afterEach, describe, expect, it } from 'vitest';
import {
  getPhotoExifCameraDisplayName,
  getPhotoExifExposureSummary,
  hasMeaningfulCameraExif,
  toSwiftUUID,
  type SocialPostMetadata,
} from '@charkle/shared';
import { createApp, createServerContext } from '../src/app.js';
import { renderSocialPostCard } from '../src/media/artwork-renderer.js';
import { buildSocialPostSvg } from '../src/media/artwork-svg.js';
import {
  extractImageMetadata,
  extractPNGTextChunks,
  formatExifDate,
  formatExposureTime,
} from '../src/media/image-metadata-extractor.js';
import { fetchGitHubOpenGraphCardBytes } from '../src/media/resolvers/github.js';
import { fetchSocialAvatarBytes } from '../src/media/resolvers/social.js';

const tempDirs: string[] = [];

function createTempDir(): string {
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'charkle-meta-test-'));
  tempDirs.push(dir);
  return dir;
}

afterEach(() => {
  while (tempDirs.length > 0) {
    const dir = tempDirs.pop()!;
    fs.rmSync(dir, { recursive: true, force: true });
  }
});

// MARK: - Synthetic Binary Container Builders for Deterministic Tests

function crc32(buf: Uint8Array): number {
  let c = 0xffffffff;
  for (let i = 0; i < buf.byteLength; i++) {
    c ^= buf[i];
    for (let k = 0; k < 8; k++) {
      c = (c >>> 1) ^ (0xedb88320 & -(c & 1));
    }
  }
  return (c ^ 0xffffffff) >>> 0;
}

function makePngChunk(type: string, data: Uint8Array): Uint8Array {
  const out = new Uint8Array(12 + data.byteLength);
  const view = new DataView(out.buffer);
  view.setUint32(0, data.byteLength, false);
  for (let i = 0; i < 4; i++) out[4 + i] = type.charCodeAt(i);
  out.set(data, 8);
  const crc = crc32(out.subarray(4, 8 + data.byteLength));
  view.setUint32(8 + data.byteLength, crc, false);
  return out;
}

function concatBytes(parts: Uint8Array[]): Uint8Array {
  const total = parts.reduce((s, p) => s + p.byteLength, 0);
  const out = new Uint8Array(total);
  let off = 0;
  for (const p of parts) {
    out.set(p, off);
    off += p.byteLength;
  }
  return out;
}

/**
 * Injects custom PNG chunks right before the `IEND` chunk of a valid PNG buffer.
 */
function injectPngChunks(png: Uint8Array, extraChunks: Uint8Array[]): Uint8Array {
  const view = new DataView(png.buffer, png.byteOffset, png.byteLength);
  let offset = 8;
  while (offset + 12 <= png.byteLength) {
    const len = view.getUint32(offset, false);
    const type = String.fromCharCode(
      png[offset + 4],
      png[offset + 5],
      png[offset + 6],
      png[offset + 7],
    );
    if (type === 'IEND') {
      return concatBytes([png.subarray(0, offset), ...extraChunks, png.subarray(offset)]);
    }
    offset += 12 + len;
  }
  return concatBytes([png, ...extraChunks]);
}

function makeTextChunk(keyword: string, text: string): Uint8Array {
  const k = Buffer.from(keyword, 'latin1');
  const v = Buffer.from(text, 'utf8');
  return makePngChunk('tEXt', concatBytes([k, new Uint8Array([0]), v]));
}

function makeZtxtChunk(keyword: string, text: string): Uint8Array {
  const k = Buffer.from(keyword, 'latin1');
  const compressed = zlib.deflateSync(Buffer.from(text, 'utf8'));
  return makePngChunk('zTXt', concatBytes([k, new Uint8Array([0, 0]), compressed]));
}

function makeItxtChunk(keyword: string, text: string, compressed: boolean): Uint8Array {
  const k = Buffer.from(keyword, 'latin1');
  const body = compressed ? zlib.deflateSync(Buffer.from(text, 'utf8')) : Buffer.from(text, 'utf8');
  return makePngChunk(
    'iTXt',
    concatBytes([k, new Uint8Array([0, compressed ? 1 : 0, 0, 0, 0]), body]),
  );
}

/**
 * Builds a minimal valid TIFF block with IFD0, ExifIFD, and GPSIFD in either
 * little-endian (`II`) or big-endian (`MM`) byte order.
 */
function buildSyntheticTiff(opts: {
  littleEndian: boolean;
  make?: string;
  model?: string;
  software?: string;
  artist?: string;
  copyright?: string;
  lensModel?: string;
  dateTimeOriginal?: string;
  offsetTimeOriginal?: string;
  exposureNum?: number;
  exposureDen?: number;
  fNumberNum?: number;
  fNumberDen?: number;
  iso?: number;
  focalNum?: number;
  focalDen?: number;
  focal35?: number;
  exposureBiasNum?: number;
  exposureBiasDen?: number;
  meteringMode?: number;
  flash?: number;
  whiteBalance?: number;
  userCommentBytes?: Uint8Array;
  gps?: { lat: [number, number, number]; latRef: 'N' | 'S'; lon: [number, number, number]; lonRef: 'E' | 'W'; alt: number; altRef: 0 | 1 };
}): Uint8Array {
  const le = opts.littleEndian;
  const buf = new Uint8Array(4096);
  const view = new DataView(buf.buffer);

  // Header
  buf[0] = le ? 0x49 : 0x4d;
  buf[1] = le ? 0x49 : 0x4d;
  view.setUint16(2, 42, le);
  view.setUint32(4, 8, le); // IFD0 at offset 8

  let heapPtr = 1024;
  const writeStringHeap = (s: string): { offset: number; count: number; inlineBytes?: Uint8Array } => {
    const bytes = Buffer.from(`${s}\0`, 'utf8');
    if (bytes.byteLength <= 4) {
      const padded = new Uint8Array(4);
      padded.set(bytes, 0);
      return { offset: 0, count: bytes.byteLength, inlineBytes: padded };
    }
    const offset = heapPtr;
    buf.set(bytes, offset);
    heapPtr += bytes.byteLength + (bytes.byteLength % 2);
    return { offset, count: bytes.byteLength };
  };
  const writeBytesHeap = (bytes: Uint8Array): { offset: number; count: number } => {
    const offset = heapPtr;
    buf.set(bytes, offset);
    heapPtr += bytes.byteLength + (bytes.byteLength % 2);
    return { offset, count: bytes.byteLength };
  };
  const writeRationalsHeap = (pairs: Array<[number, number]>, signed = false): { offset: number; count: number } => {
    const offset = heapPtr;
    for (let i = 0; i < pairs.length; i++) {
      if (signed) {
        view.setInt32(heapPtr, pairs[i][0], le);
        view.setInt32(heapPtr + 4, pairs[i][1], le);
      } else {
        view.setUint32(heapPtr, pairs[i][0], le);
        view.setUint32(heapPtr + 4, pairs[i][1], le);
      }
      heapPtr += 8;
    }
    return { offset, count: pairs.length };
  };

  interface RawEntry {
    tag: number;
    type: number;
    count: number;
    valueOrOffset: number;
    inlineBytes?: Uint8Array;
  }

  const writeIFD = (startOffset: number, entries: RawEntry[]): number => {
    entries.sort((a, b) => a.tag - b.tag);
    view.setUint16(startOffset, entries.length, le);
    let pos = startOffset + 2;
    for (const e of entries) {
      view.setUint16(pos, e.tag, le);
      view.setUint16(pos + 2, e.type, le);
      view.setUint32(pos + 4, e.count, le);
      if (e.inlineBytes) {
        buf.set(e.inlineBytes.subarray(0, 4), pos + 8);
      } else if (e.type === 3 && e.count === 1) {
        view.setUint16(pos + 8, e.valueOrOffset, le);
      } else {
        view.setUint32(pos + 8, e.valueOrOffset, le);
      }
      pos += 12;
    }
    view.setUint32(pos, 0, le); // next IFD = 0
    return pos + 4;
  };

  const exifEntries: RawEntry[] = [];
  if (opts.exposureNum != null && opts.exposureDen != null) {
    const r = writeRationalsHeap([[opts.exposureNum, opts.exposureDen]]);
    exifEntries.push({ tag: 0x829a, type: 5, count: 1, valueOrOffset: r.offset });
  }
  if (opts.fNumberNum != null && opts.fNumberDen != null) {
    const r = writeRationalsHeap([[opts.fNumberNum, opts.fNumberDen]]);
    exifEntries.push({ tag: 0x829d, type: 5, count: 1, valueOrOffset: r.offset });
  }
  if (opts.iso != null) {
    exifEntries.push({ tag: 0x8827, type: 3, count: 1, valueOrOffset: opts.iso });
  }
  if (opts.dateTimeOriginal) {
    const s = writeStringHeap(opts.dateTimeOriginal);
    exifEntries.push({ tag: 0x9003, type: 2, count: s.count, valueOrOffset: s.offset });
  }
  if (opts.offsetTimeOriginal) {
    const s = writeStringHeap(opts.offsetTimeOriginal);
    exifEntries.push({ tag: 0x9011, type: 2, count: s.count, valueOrOffset: s.offset });
  }
  if (opts.exposureBiasNum != null && opts.exposureBiasDen != null) {
    const r = writeRationalsHeap([[opts.exposureBiasNum, opts.exposureBiasDen]], true);
    exifEntries.push({ tag: 0x9204, type: 10, count: 1, valueOrOffset: r.offset });
  }
  if (opts.meteringMode != null) {
    exifEntries.push({ tag: 0x9207, type: 3, count: 1, valueOrOffset: opts.meteringMode });
  }
  if (opts.flash != null) {
    exifEntries.push({ tag: 0x9209, type: 3, count: 1, valueOrOffset: opts.flash });
  }
  if (opts.focalNum != null && opts.focalDen != null) {
    const r = writeRationalsHeap([[opts.focalNum, opts.focalDen]]);
    exifEntries.push({ tag: 0x920a, type: 5, count: 1, valueOrOffset: r.offset });
  }
  if (opts.userCommentBytes) {
    const b = writeBytesHeap(opts.userCommentBytes);
    exifEntries.push({ tag: 0x9286, type: 7, count: b.count, valueOrOffset: b.offset });
  }
  if (opts.whiteBalance != null) {
    exifEntries.push({ tag: 0xa403, type: 3, count: 1, valueOrOffset: opts.whiteBalance });
  }
  if (opts.focal35 != null) {
    exifEntries.push({ tag: 0xa405, type: 3, count: 1, valueOrOffset: opts.focal35 });
  }
  if (opts.lensModel) {
    const s = writeStringHeap(opts.lensModel);
    exifEntries.push({ tag: 0xa434, type: 2, count: s.count, valueOrOffset: s.offset });
  }

  const gpsEntries: RawEntry[] = [];
  if (opts.gps) {
    gpsEntries.push({
      tag: 0x0001,
      type: 2,
      count: 2,
      valueOrOffset: 0,
      inlineBytes: new Uint8Array([opts.gps.latRef.charCodeAt(0), 0, 0, 0]),
    });
    const latR = writeRationalsHeap([
      [opts.gps.lat[0], 1],
      [opts.gps.lat[1], 1],
      [Math.round(opts.gps.lat[2] * 100), 100],
    ]);
    gpsEntries.push({ tag: 0x0002, type: 5, count: 3, valueOrOffset: latR.offset });
    gpsEntries.push({
      tag: 0x0003,
      type: 2,
      count: 2,
      valueOrOffset: 0,
      inlineBytes: new Uint8Array([opts.gps.lonRef.charCodeAt(0), 0, 0, 0]),
    });
    const lonR = writeRationalsHeap([
      [opts.gps.lon[0], 1],
      [opts.gps.lon[1], 1],
      [Math.round(opts.gps.lon[2] * 100), 100],
    ]);
    gpsEntries.push({ tag: 0x0004, type: 5, count: 3, valueOrOffset: lonR.offset });
    gpsEntries.push({
      tag: 0x0005,
      type: 1,
      count: 1,
      valueOrOffset: 0,
      inlineBytes: new Uint8Array([opts.gps.altRef, 0, 0, 0]),
    });
    const altR = writeRationalsHeap([[Math.round(Math.abs(opts.gps.alt) * 10), 10]]);
    gpsEntries.push({ tag: 0x0006, type: 5, count: 1, valueOrOffset: altR.offset });
  }

  const exifOffset = 320;
  const gpsOffset = 720;
  if (exifEntries.length > 0) writeIFD(exifOffset, exifEntries);
  if (gpsEntries.length > 0) writeIFD(gpsOffset, gpsEntries);

  const ifd0: RawEntry[] = [];
  if (opts.make) {
    const s = writeStringHeap(opts.make);
    ifd0.push({ tag: 0x010f, type: 2, count: s.count, valueOrOffset: s.offset, inlineBytes: s.inlineBytes });
  }
  if (opts.model) {
    const s = writeStringHeap(opts.model);
    ifd0.push({ tag: 0x0110, type: 2, count: s.count, valueOrOffset: s.offset, inlineBytes: s.inlineBytes });
  }
  if (opts.software) {
    const s = writeStringHeap(opts.software);
    ifd0.push({ tag: 0x0131, type: 2, count: s.count, valueOrOffset: s.offset, inlineBytes: s.inlineBytes });
  }
  if (opts.artist) {
    const s = writeStringHeap(opts.artist);
    ifd0.push({ tag: 0x013b, type: 2, count: s.count, valueOrOffset: s.offset, inlineBytes: s.inlineBytes });
  }
  if (opts.copyright) {
    const s = writeStringHeap(opts.copyright);
    ifd0.push({ tag: 0x8298, type: 2, count: s.count, valueOrOffset: s.offset, inlineBytes: s.inlineBytes });
  }
  if (exifEntries.length > 0) {
    ifd0.push({ tag: 0x8769, type: 4, count: 1, valueOrOffset: exifOffset });
  }
  if (gpsEntries.length > 0) {
    ifd0.push({ tag: 0x8825, type: 4, count: 1, valueOrOffset: gpsOffset });
  }
  writeIFD(8, ifd0);

  return buf.slice(0, heapPtr);
}

function wrapJpegWithApp1(exifTiff?: Uint8Array, xmpXml?: string): Uint8Array {
  const segments: Uint8Array[] = [new Uint8Array([0xff, 0xd8])];
  if (exifTiff) {
    const payload = concatBytes([Buffer.from('Exif\0\0', 'ascii'), exifTiff]);
    const header = new Uint8Array(4);
    header[0] = 0xff;
    header[1] = 0xe1;
    new DataView(header.buffer).setUint16(2, payload.byteLength + 2, false);
    segments.push(header, payload);
  }
  if (xmpXml) {
    const payload = concatBytes([
      Buffer.from('http://ns.adobe.com/xap/1.0/\0', 'ascii'),
      Buffer.from(xmpXml, 'utf8'),
    ]);
    const header = new Uint8Array(4);
    header[0] = 0xff;
    header[1] = 0xe1;
    new DataView(header.buffer).setUint16(2, payload.byteLength + 2, false);
    segments.push(header, payload);
  }
  segments.push(new Uint8Array([0xff, 0xd9]));
  return concatBytes(segments);
}

function makeWebP(chunks: Array<{ fourCC: string; payload: Uint8Array }>): Uint8Array {
  const bodyParts: Uint8Array[] = [Buffer.from('WEBP', 'ascii')];
  for (const ch of chunks) {
    const header = new Uint8Array(8);
    for (let i = 0; i < 4; i++) header[i] = ch.fourCC.charCodeAt(i);
    new DataView(header.buffer).setUint32(4, ch.payload.byteLength, true);
    bodyParts.push(header, ch.payload);
    if (ch.payload.byteLength % 2 === 1) bodyParts.push(new Uint8Array([0]));
  }
  const body = concatBytes(bodyParts);
  const riff = new Uint8Array(8);
  riff.set(Buffer.from('RIFF', 'ascii'), 0);
  new DataView(riff.buffer).setUint32(4, body.byteLength, true);
  return concatBytes([riff, body]);
}

describe('Pure-TS ImageMetadataExtractor (EXIF + AI Prompts) & Rich Card Parity', () => {
  it('extracts full JPEG EXIF/TIFF/GPS metadata in both little-endian (II) and big-endian (MM)', async () => {
    expect(formatExposureTime(1 / 250)).toBe('1/250s');
    expect(formatExposureTime(2.0)).toBe('2s');
    expect(formatExposureTime(0.8)).toBe('0.8s');
    expect(formatExifDate('2026:11:20 14:22:08', '+08:00')).toBe('2026-11-20 14:22:08 (+08:00)');

    for (const littleEndian of [true, false]) {
      const tiff = buildSyntheticTiff({
        littleEndian,
        make: 'FUJIFILM',
        model: 'X-T5',
        software: 'Capture One 23',
        artist: 'Studio Artist',
        copyright: '© 2026 Studio',
        lensModel: 'XF23mmF1.4 R LM WR',
        dateTimeOriginal: '2026:11:20 15:30:12',
        offsetTimeOriginal: '+08:00',
        exposureNum: 1,
        exposureDen: 250,
        fNumberNum: 18,
        fNumberDen: 10,
        iso: 400,
        focalNum: 23,
        focalDen: 1,
        focal35: 35,
        exposureBiasNum: -1,
        exposureBiasDen: 3,
        meteringMode: 5,
        flash: 0,
        whiteBalance: 0,
        gps: {
          lat: [33, 52, 7.68],
          latRef: 'S',
          lon: [151, 12, 33.48],
          lonRef: 'E',
          alt: 18.5,
          altRef: 0,
        },
      });
      const jpeg = wrapJpegWithApp1(tiff);
      const { photoExif, aiGeneration } = await extractImageMetadata(jpeg, 'image/jpeg');

      expect(aiGeneration).toBeNull();
      expect(photoExif).not.toBeNull();
      expect(hasMeaningfulCameraExif(photoExif)).toBe(true);
      expect(getPhotoExifCameraDisplayName(photoExif!)).toBe('FUJIFILM X-T5');
      expect(photoExif!.lensModel).toBe('XF23mmF1.4 R LM WR');
      expect(photoExif!.capturedAt).toBe('2026-11-20 15:30:12 (+08:00)');
      expect(photoExif!.exposureTime).toBe('1/250s');
      expect(photoExif!.fNumber).toBeCloseTo(1.8, 2);
      expect(photoExif!.iso).toBe(400);
      expect(photoExif!.focalLengthMM).toBe(23);
      expect(photoExif!.focalLength35mm).toBe(35);
      expect(getPhotoExifExposureSummary(photoExif!)).toBe('23mm · f/1.8 · 1/250s · ISO 400');
      expect(photoExif!.meteringMode).toBe('评价测光');
      expect(photoExif!.flashFired).toBe(false);
      expect(photoExif!.whiteBalance).toBe('自动');
      expect(photoExif!.latitude).toBeLessThan(-33.8);
      expect(photoExif!.longitude).toBeGreaterThan(151.2);
      expect(photoExif!.altitudeMeters).toBeCloseTo(18.5, 1);
    }
  });

  it('parses PNG tEXt, zlib zTXt (via Web DecompressionStream), compressed iTXt, and eXIf chunks for A1111, ComfyUI, NovelAI, InvokeAI, and Midjourney', async () => {
    const basePng = await sharp({
      create: { width: 64, height: 64, channels: 3, background: { r: 120, g: 140, b: 160 } },
    })
      .png()
      .toBuffer();

    // 1. A1111 in zTXt (RFC 1950 zlib stream -> inflated by DecompressionStream('deflate'))
    const a1111Text = [
      'brutalist concrete gallery, warm diffused daylight, <lora:film_grain:0.65>',
      'Negative prompt: blurry, watermark, distorted',
      'Steps: 28, Sampler: DPM++ 2M, Schedule type: Karras, CFG scale: 6.5, Seed: 987654321, Size: 1024x1344, Model hash: a1b2c3d4, Model: juggernautXL_v9, Clip skip: 2, Lora hashes: "studio_light: ff0011, film_grain: aa2233", Version: f2.0.1v1.10.1-forge',
    ].join('\n');
    const a1111Png = injectPngChunks(basePng, [makeZtxtChunk('parameters', a1111Text)]);
    const ztxtChunks = await extractPNGTextChunks(a1111Png);
    expect(ztxtChunks.parameters).toContain('Steps: 28');

    const a1111Meta = await extractImageMetadata(a1111Png, 'image/png');
    expect(a1111Meta.aiGeneration).not.toBeNull();
    expect(a1111Meta.aiGeneration!.generator).toBe('SD WebUI Forge');
    expect(a1111Meta.aiGeneration!.prompt).toContain('brutalist concrete gallery');
    expect(a1111Meta.aiGeneration!.negativePrompt).toBe('blurry, watermark, distorted');
    expect(a1111Meta.aiGeneration!.steps).toBe(28);
    expect(a1111Meta.aiGeneration!.sampler).toBe('DPM++ 2M');
    expect(a1111Meta.aiGeneration!.scheduler).toBe('Karras');
    expect(a1111Meta.aiGeneration!.cfgScale).toBe(6.5);
    expect(a1111Meta.aiGeneration!.seed).toBe('987654321');
    expect(a1111Meta.aiGeneration!.sizeText).toBe('1024 × 1344');
    expect(a1111Meta.aiGeneration!.modelName).toBe('juggernautXL_v9');
    expect(a1111Meta.aiGeneration!.clipSkip).toBe(2);
    expect(a1111Meta.aiGeneration!.loras).toEqual(['film_grain:0.65', 'studio_light', 'film_grain']);

    // 2. ComfyUI node graph in compressed iTXt
    const comfyGraph = JSON.stringify({
      '1': { class_type: 'CheckpointLoaderSimple', inputs: { ckpt_name: 'models/flux1-dev.safetensors' } },
      '2': { class_type: 'LoraLoader', inputs: { lora_name: 'loras/editorial_grain.safetensors' } },
      '3': { class_type: 'CLIPTextEncode', inputs: { text: 'minimalist terracotta ceramics on linen' } },
      '4': { class_type: 'CLIPTextEncode', inputs: { text: 'oversaturated, neon' } },
      '5': { class_type: 'EmptyLatentImage', inputs: { width: 1200, height: 1600 } },
      '6': {
        class_type: 'KSampler',
        inputs: {
          seed: 424242,
          steps: 24,
          cfg: 5.5,
          sampler_name: 'euler',
          scheduler: 'simple',
          positive: ['3', 0],
          negative: ['4', 0],
        },
      },
    });
    const comfyPng = injectPngChunks(basePng, [makeItxtChunk('prompt', comfyGraph, true)]);
    const comfyMeta = await extractImageMetadata(comfyPng, 'image/png');
    expect(comfyMeta.aiGeneration?.generator).toBe('ComfyUI');
    expect(comfyMeta.aiGeneration?.prompt).toBe('minimalist terracotta ceramics on linen');
    expect(comfyMeta.aiGeneration?.negativePrompt).toBe('oversaturated, neon');
    expect(comfyMeta.aiGeneration?.modelName).toBe('flux1-dev.safetensors');
    expect(comfyMeta.aiGeneration?.loras).toEqual(['editorial_grain.safetensors']);
    expect(comfyMeta.aiGeneration?.sizeText).toBe('1200 × 1600');
    expect(comfyMeta.aiGeneration?.steps).toBe(24);
    expect(comfyMeta.aiGeneration?.seed).toBe('424242');

    // 3. NovelAI
    const naiPng = injectPngChunks(basePng, [
      makeTextChunk('Software', 'NovelAI'),
      makeTextChunk(
        'Comment',
        JSON.stringify({
          prompt: 'watercolor coastal town',
          uc: 'lowres, bad anatomy',
          steps: 28,
          sampler: 'k_euler_ancestral',
          scale: 5,
          seed: 10101,
          width: 832,
          height: 1216,
        }),
      ),
    ]);
    const naiMeta = await extractImageMetadata(naiPng, 'image/png');
    expect(naiMeta.aiGeneration?.generator).toBe('NovelAI');
    expect(naiMeta.aiGeneration?.prompt).toBe('watercolor coastal town');
    expect(naiMeta.aiGeneration?.negativePrompt).toBe('lowres, bad anatomy');

    // 4. InvokeAI
    const invokePng = injectPngChunks(basePng, [
      makeTextChunk(
        'invokeai_metadata',
        JSON.stringify({
          positive_prompt: 'nordic timber library interior',
          negative_prompt: 'cluttered',
          model: { name: 'sdxl-base-1.0' },
          scheduler: 'dpmpp_2m_k',
          steps: 32,
          cfg_scale: 7,
          seed: 777,
          width: 1024,
          height: 1024,
        }),
      ),
    ]);
    const invokeMeta = await extractImageMetadata(invokePng, 'image/png');
    expect(invokeMeta.aiGeneration?.generator).toBe('InvokeAI');
    expect(invokeMeta.aiGeneration?.modelName).toBe('sdxl-base-1.0');
    expect(invokeMeta.aiGeneration?.prompt).toBe('nordic timber library interior');

    // 5. Midjourney
    const mjPng = injectPngChunks(basePng, [
      makeTextChunk(
        'Description',
        'minimal architectural courtyard, morning shadow --ar 4:5 --v 6.1 --seed 5511 Job ID: mj-job-001',
      ),
    ]);
    const mjMeta = await extractImageMetadata(mjPng, 'image/png');
    expect(mjMeta.aiGeneration?.generator).toBe('Midjourney');
    expect(mjMeta.aiGeneration?.modelName).toBe('Midjourney v6.1');
    expect(mjMeta.aiGeneration?.seed).toBe('5511');
    expect(mjMeta.aiGeneration?.extraParameters['Job ID']).toBe('mj-job-001');
  });

  it('extracts EXIF UserComment (UTF-16BE UNICODE) and WebP XMP for Draw Things & SwarmUI', async () => {
    // JPEG with UNICODE UTF-16BE UserComment containing Draw Things JSON
    const dtJson = JSON.stringify({
      c: 'editorial fashion portrait on medium format film',
      uc: 'harsh flash',
      model: 'flux_schnell_q8p',
      steps: 12,
      scale: 4.5,
      seed: 314159,
      sampler: 'Euler A',
      size: '1024x1280',
    });
    const utf16be = new Uint8Array(dtJson.length * 2);
    const dv = new DataView(utf16be.buffer);
    for (let i = 0; i < dtJson.length; i++) dv.setUint16(i * 2, dtJson.charCodeAt(i), false);
    const userCommentBytes = concatBytes([Buffer.from('UNICODE\0', 'ascii'), utf16be]);

    const jpeg = wrapJpegWithApp1(
      buildSyntheticTiff({ littleEndian: false, userCommentBytes }),
    );
    const dtMeta = await extractImageMetadata(jpeg, 'image/jpeg');
    expect(dtMeta.aiGeneration?.generator).toBe('Draw Things');
    expect(dtMeta.aiGeneration?.prompt).toBe('editorial fashion portrait on medium format film');
    expect(dtMeta.aiGeneration?.modelName).toBe('flux_schnell_q8p');

    // WebP with XMP containing SwarmUI sui_image_params
    const swarmJson = JSON.stringify({
      sui_image_params: {
        prompt: 'misty mountain shrine at dawn',
        negativeprompt: 'text, logo',
        model: 'sd3.5_large',
        steps: 30,
        cfgscale: 5.0,
        seed: 8888,
        sampler: 'dpmpp_2m',
        scheduler: 'sgm_uniform',
      },
    }).replace(/"/g, '&quot;');
    const xmp = `<x:xmpmeta><rdf:RDF><rdf:Description><exif:UserComment>${swarmJson}</exif:UserComment></rdf:Description></rdf:RDF></x:xmpmeta>`;
    const webp = makeWebP([{ fourCC: 'XMP ', payload: Buffer.from(xmp, 'utf8') }]);
    const swarmMeta = await extractImageMetadata(webp, 'image/webp');
    expect(swarmMeta.aiGeneration?.generator).toBe('SwarmUI');
    expect(swarmMeta.aiGeneration?.prompt).toBe('misty mountain shrine at dawn');
    expect(swarmMeta.aiGeneration?.modelName).toBe('sd3.5_large');
  });

  it('indexes EXIF & AI prompts in FTS5 and hydrates legacy assets via POST /api/v1/assets/:id/hydrate-metadata', async () => {
    const dir = createTempDir();
    const ctx = createServerContext({ dataDir: dir });
    const app = createApp(ctx, { staticClientDir: null });

    const user = await ctx.auth.setupAdmin('admin', 'strong-password-123');
    const pat = ctx.auth.createApiToken(user.id, 'meta-pat', ['read', 'write']);
    const authHeaders = {
      Authorization: `Bearer ${pat.token}`,
      'Content-Type': 'application/json',
    };

    const basePng = await sharp({
      create: { width: 120, height: 120, channels: 3, background: { r: 200, g: 110, b: 80 } },
    })
      .png()
      .toBuffer();

    const exifTiff = buildSyntheticTiff({
      littleEndian: true,
      make: 'Leica',
      model: 'Q3',
      lensModel: 'Summilux 28mm f/1.7',
      iso: 200,
    });
    const richPng = injectPngChunks(basePng, [
      makePngChunk('eXIf', exifTiff),
      makeTextChunk(
        'parameters',
        'kyoto wooden machiya courtyard\nNegative prompt: cartoon\nSteps: 20, Sampler: Euler, CFG scale: 7, Seed: 42, Model: machiyaXL_v2',
      ),
    ]);

    // 1. Direct ingest populates photoExif + aiGeneration + FTS5 immediately
    const id1 = toSwiftUUID('bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbb01');
    const ingested = await ctx.media.ingestUploadedFile(richPng, 'kyoto-render.png', 'image/png', null, id1);
    const saved = ctx.db.saveAssetLocally(ingested.asset);
    expect(saved.richMetadata?.photoExif?.cameraMake).toBe('Leica');
    expect(saved.richMetadata?.aiGeneration?.modelName).toBe('machiyaXL_v2');

    // FTS5 finds by AI prompt, AI model, and camera gear!
    expect(ctx.db.fetchAssets({ searchQuery: 'machiyaXL_v2' }).map((a) => a.id)).toContain(id1);
    expect(ctx.db.fetchAssets({ searchQuery: 'Leica' }).map((a) => a.id)).toContain(id1);
    expect(ctx.db.fetchAssets({ searchQuery: 'courtyard' }).map((a) => a.id)).toContain(id1);

    // 2. Clear richMetadata to simulate a pre-Round-4 legacy asset, then hydrate via HTTP endpoint!
    ctx.db.saveAssetLocally({ ...saved, richMetadata: null }, false);
    expect(ctx.db.getAsset(id1)!.richMetadata).toBeNull();

    const hydrateRes = await app.request(`/api/v1/assets/${id1}/hydrate-metadata`, {
      method: 'POST',
      headers: authHeaders,
    });
    expect(hydrateRes.status).toBe(200);
    const hydratedBody = (await hydrateRes.json()) as {
      asset: { richMetadata?: { photoExif?: { cameraModel?: string }; aiGeneration?: { modelName?: string } } };
    };
    expect(hydratedBody.asset.richMetadata?.photoExif?.cameraModel).toBe('Q3');
    expect(hydratedBody.asset.richMetadata?.aiGeneration?.modelName).toBe('machiyaXL_v2');

    ctx.db.close();
  });

  it('renders circular social author avatars cleanly on both SVG (Workers) and PNG (Node) and validates GitHub OG / X avatar URL upgrade', async () => {
    const avatarPng = await sharp({
      create: { width: 96, height: 96, channels: 3, background: { r: 42, g: 96, b: 224 } },
    })
      .png()
      .toBuffer();

    const post: SocialPostMetadata = {
      platform: 'x',
      authorName: 'Studio Designer',
      authorHandle: 'studiodesigner',
      authorAvatarURL: 'https://pbs.twimg.com/profile_images/12345/photo_normal.jpg',
      publishedAtText: '2026-11-22',
      bodyText: 'Testing real circular author avatar compositing across Node and Workers.',
      mediaURLs: [],
      mediaThumbnailURLs: [],
      attachments: [],
      hasVideo: false,
      originalURL: 'https://x.com/studiodesigner/status/123456',
      mediaFetchFailed: false,
    };

    // Workers-safe SVG with inline circular avatar clipPath
    const svgOut = buildSocialPostSvg(post, { inlineAvatarBytes: avatarPng });
    expect(svgOut.svg).toContain('id="socialAvatarClip"');
    expect(svgOut.svg).toContain('data:image/png;base64,');

    // Node sharp PNG compositing with real circular avatar
    const pngCard = await renderSocialPostCard(post, null, avatarPng);
    const meta = await sharp(pngCard).metadata();
    expect(meta.format).toBe('png');
    expect(meta.width).toBe(800);

    // Verify _normal. -> _400x400. avatar upgrade & GitHub OG fetch validation using mocked fetch
    const origFetch = globalThis.fetch;
    const requestedUrls: string[] = [];
    const ogPng = await sharp({
      create: { width: 400, height: 200, channels: 3, background: { r: 20, g: 24, b: 30 } },
    })
      .png()
      .toBuffer();

    globalThis.fetch = (async (input: RequestInfo | URL) => {
      const url = String(input);
      requestedUrls.push(url);
      if (url.includes('_400x400.')) {
        return new Response(new Uint8Array(avatarPng), {
          status: 200,
          headers: { 'Content-Type': 'image/png' },
        });
      }
      if (url.includes('opengraph.githubassets.com')) {
        return new Response(new Uint8Array(ogPng), {
          status: 200,
          headers: { 'Content-Type': 'image/png' },
        });
      }
      return new Response(null, { status: 404 });
    }) as typeof fetch;

    try {
      const fetchedAvatar = await fetchSocialAvatarBytes(post.authorAvatarURL);
      expect(fetchedAvatar).not.toBeNull();
      expect(requestedUrls[0]).toContain('_400x400.');

      const fetchedOG = await fetchGitHubOpenGraphCardBytes({
        owner: 'charkle',
        repo: 'studio',
        openGraphImageURL: 'https://opengraph.githubassets.com/1/charkle/studio',
      });
      expect(fetchedOG).not.toBeNull();
      expect(fetchedOG!.mimeType).toBe('image/png');
    } finally {
      globalThis.fetch = origFetch;
    }
  });
});
