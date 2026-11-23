import crypto from 'node:crypto';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import JSZip from 'jszip';
import sharp from 'sharp';
import { afterEach, describe, expect, it } from 'vitest';
import {
  createDefaultDriveSyncConfig,
  createDefaultMoodboardDocument,
  labFromHex,
  toSwiftUUID,
  type ClientPreprocessedMedia,
  type HealthResponse,
} from '@charkle/shared';
import { NodeBlobStore } from '../src/runtime/node-blob.js';
import { NodePasswordHasher } from '../src/runtime/node-hash.js';
import { NodeSqlDatabase } from '../src/runtime/node-sql.js';
import { createNodeSecretVault } from '../src/runtime/node-storage.js';
import {
  createCoreApp,
  createRuntimeContext,
  encodeFeaturePrintFloat32,
  InMemoryDriveTransport,
  SampleLibrarySeeder,
  SECRET_KEYS,
  SecretVault,
  VAULT_SECRETS_STATE_KEY,
  WebCryptoPasswordHasher,
  WorkersImageProcessor,
  bytesToBase64,
  inspectImageHeader,
  streamToBytes,
  utf8Decode,
  type BlobHeadResult,
  type BlobListItem,
  type BlobRangeRequest,
  type BlobStreamResult,
  type CloudflareImagesBinding,
  type IBlobStore,
} from '../src/worker-exports.js';

const tempDirs: string[] = [];

function makeTempDir(prefix = 'charkle-cf-runtime-'): string {
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), prefix));
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
 * Pure in-memory R2-compatible `IBlobStore` with true Range slicing and streaming.
 */
class MemoryBlobStore implements IBlobStore {
  private readonly store = new Map<
    string,
    { bytes: Uint8Array; contentType?: string; lastModifiedMs: number }
  >();

  async put(
    key: string,
    data: Uint8Array | ReadableStream<Uint8Array>,
    options?: { contentType?: string },
  ): Promise<{ size: number }> {
    const bytes =
      data instanceof Uint8Array
        ? new Uint8Array(data.buffer.slice(data.byteOffset, data.byteOffset + data.byteLength))
        : await streamToBytes(data);
    this.store.set(key, {
      bytes,
      contentType: options?.contentType,
      lastModifiedMs: Date.now(),
    });
    return { size: bytes.byteLength };
  }

  async getBytes(key: string): Promise<Uint8Array | null> {
    const entry = this.store.get(key);
    return entry ? new Uint8Array(entry.bytes) : null;
  }

  async getStream(key: string, range?: BlobRangeRequest): Promise<BlobStreamResult | null> {
    const entry = this.store.get(key);
    if (!entry) return null;
    const total = entry.bytes.byteLength;
    let slice = entry.bytes;
    let resolvedRange: { start: number; end: number; total: number } | undefined;

    if (range) {
      const start = Math.max(0, Math.min(range.offset, total));
      const end =
        range.length !== undefined
          ? Math.min(total - 1, start + Math.max(0, range.length) - 1)
          : total - 1;
      slice = start <= end ? entry.bytes.subarray(start, end + 1) : new Uint8Array(0);
      resolvedRange = { start, end, total };
    }

    const payload = new Uint8Array(slice);
    const stream = new ReadableStream<Uint8Array>({
      start(controller) {
        if (payload.byteLength > 0) controller.enqueue(payload);
        controller.close();
      },
    });

    return {
      stream,
      size: payload.byteLength,
      contentType: entry.contentType,
      lastModifiedMs: entry.lastModifiedMs,
      range: resolvedRange,
    };
  }

  async head(key: string): Promise<BlobHeadResult | null> {
    const entry = this.store.get(key);
    if (!entry) return null;
    return {
      size: entry.bytes.byteLength,
      contentType: entry.contentType,
      lastModifiedMs: entry.lastModifiedMs,
    };
  }

  async delete(key: string): Promise<void> {
    this.store.delete(key);
  }

  async list(prefix: string): Promise<BlobListItem[]> {
    const out: BlobListItem[] = [];
    for (const [key, entry] of this.store.entries()) {
      if (key.startsWith(prefix)) {
        out.push({
          key,
          size: entry.bytes.byteLength,
          lastModifiedMs: entry.lastModifiedMs,
        });
      }
    }
    return out;
  }
}

/**
 * Constructs a valid 24-bit uncompressed BMP of given dimensions and RGB color.
 */
function createSolidBmp(width: number, height: number, r: number, g: number, b: number): Uint8Array {
  const rowStride = Math.ceil((width * 3) / 4) * 4;
  const pixelBytes = rowStride * height;
  const fileSize = 54 + pixelBytes;
  const out = new Uint8Array(fileSize);
  const view = new DataView(out.buffer);
  out[0] = 0x42; // 'B'
  out[1] = 0x4d; // 'M'
  view.setUint32(2, fileSize, true);
  view.setUint32(10, 54, true); // pixel data offset
  view.setUint32(14, 40, true); // BITMAPINFOHEADER
  view.setInt32(18, width, true);
  view.setInt32(22, height, true);
  view.setUint16(26, 1, true); // planes
  view.setUint16(28, 24, true); // bpp
  view.setUint32(34, pixelBytes, true);
  for (let y = 0; y < height; y++) {
    const rowOff = 54 + y * rowStride;
    for (let x = 0; x < width; x++) {
      out[rowOff + x * 3] = b;
      out[rowOff + x * 3 + 1] = g;
      out[rowOff + x * 3 + 2] = r;
    }
  }
  return out;
}

describe('Cloudflare Workers Runtime Seams, Dual-Runtime Parity & Import Audit', () => {
  it('guarantees ZERO transitive Node-only / sharp imports reachable from src/worker-exports.ts', () => {
    const here = path.dirname(fileURLToPath(import.meta.url));
    const srcRoot = path.resolve(here, '../src');
    const entryFile = path.join(srcRoot, 'worker-exports.ts');

    const FORBIDDEN_SPECIFIERS = new Set([
      'node:fs',
      'node:fs/promises',
      'fs',
      'fs/promises',
      'node:sqlite',
      'node:os',
      'os',
      'node:readline',
      'readline',
      'node:crypto',
      'crypto',
      'node:path',
      'path',
      'node:stream',
      'stream',
      'node:url',
      'url',
      'sharp',
      '@hono/node-server',
    ]);

    const visited = new Set<string>();
    const violations: string[] = [];

    const IMPORT_RE =
      /(?:^|\n)\s*(?:import|export)\s+(?:type\s+)?(?:[\s\S]*?\s+from\s+)?['"]([^'"]+)['"]|import\(\s*['"]([^'"]+)['"]\s*\)/g;

    const walk = (filePath: string) => {
      const abs = path.resolve(filePath);
      if (visited.has(abs)) return;
      visited.add(abs);

      const relFromSrc = path.relative(srcRoot, abs).replace(/\\/g, '/');
      if (relFromSrc.includes('local-folder-transport') || /^runtime\/node-/.test(relFromSrc)) {
        violations.push(`Forbidden Node-only module reached: ${relFromSrc}`);
      }

      const content = fs.readFileSync(abs, 'utf8');
      let match: RegExpExecArray | null;
      IMPORT_RE.lastIndex = 0;
      while ((match = IMPORT_RE.exec(content)) !== null) {
        const spec = match[1] ?? match[2];
        if (!spec) continue;
        if (FORBIDDEN_SPECIFIERS.has(spec) || spec.startsWith('node:')) {
          violations.push(`${relFromSrc} imports forbidden specifier "${spec}"`);
          continue;
        }
        if (spec.includes('local-folder-transport') || /runtime\/node-/.test(spec)) {
          violations.push(`${relFromSrc} imports forbidden local module "${spec}"`);
          continue;
        }
        if (spec.startsWith('.')) {
          const base = path.resolve(path.dirname(abs), spec);
          const candidates = [
            base.replace(/\.js$/, '.ts'),
            base.replace(/\.mjs$/, '.ts'),
            `${base}.ts`,
            path.join(base, 'index.ts'),
            base,
          ];
          const resolved = candidates.find((c) => fs.existsSync(c) && fs.statSync(c).isFile());
          if (resolved && resolved.startsWith(srcRoot)) {
            walk(resolved);
          }
        }
      }
    };

    walk(entryFile);

    expect(visited.size).toBeGreaterThanOrEqual(20);
    expect(violations).toEqual([]);
  });

  it('hashes with Web Crypto PBKDF2-SHA256 (<=100k iterations) and verifies legacy Node scrypt hashes', async () => {
    const cfHasher = new WebCryptoPasswordHasher({ iterations: 250_000 }); // clamped to 100k CF cap
    const hash = await cfHasher.hash('s3cret-design-pass');
    expect(hash).toMatch(/^pbkdf2\$100000\$[0-9a-f]{32}\$[0-9a-f]{64}$/);
    expect(await cfHasher.verify('s3cret-design-pass', hash)).toBe(true);
    expect(await cfHasher.verify('wrong-password', hash)).toBe(false);

    // NodePasswordHasher verifies PBKDF2 AND legacy scrypt$ AND bare-hex + salt formats
    const nodeHasher = new NodePasswordHasher();
    expect(await nodeHasher.verify('s3cret-design-pass', hash)).toBe(true);

    const legacySalt = crypto.randomBytes(16).toString('hex');
    const legacyDerived = crypto
      .scryptSync('legacy-pass-42', legacySalt, 64, { N: 16384, r: 8, p: 1 })
      .toString('hex');
    const scryptTagged = `scrypt$${legacySalt}$${legacyDerived}`;

    expect(await nodeHasher.verify('legacy-pass-42', scryptTagged)).toBe(true);
    expect(await nodeHasher.verify('wrong', scryptTagged)).toBe(false);
    expect(await nodeHasher.verify('legacy-pass-42', legacyDerived, legacySalt)).toBe(true);
    expect(await nodeHasher.verify('wrong', legacyDerived, legacySalt)).toBe(false);
  });

  it('parses PNG, JPEG, GIF, WebP (VP8/VP8L/VP8X), BMP & SVG headers and renders SVG artwork + exports in WorkersImageProcessor', async () => {
    const processor = new WorkersImageProcessor();

    // PNG & JPEG generated by sharp (just to create real test fixtures)
    const png = await sharp({
      create: { width: 321, height: 123, channels: 3, background: { r: 190, g: 95, b: 60 } },
    })
      .png()
      .toBuffer();
    const jpeg = await sharp({
      create: { width: 410, height: 260, channels: 3, background: { r: 30, g: 120, b: 200 } },
    })
      .jpeg({ quality: 85 })
      .toBuffer();

    expect(await processor.inspectDimensions(png)).toMatchObject({ width: 321, height: 123, format: 'png' });
    expect(await processor.inspectDimensions(jpeg)).toMatchObject({ width: 410, height: 260, format: 'jpeg' });

    // GIF89a header (170x95)
    const gif = new Uint8Array([
      0x47, 0x49, 0x46, 0x38, 0x39, 0x61, 170, 0, 95, 0, 0x80, 0, 0,
    ]);
    expect(inspectImageHeader(gif)).toMatchObject({ width: 170, height: 95, format: 'gif' });

    // WebP VP8X header (640x360)
    const webpVp8x = new Uint8Array(30);
    webpVp8x.set([0x52, 0x49, 0x46, 0x46], 0); // RIFF
    webpVp8x.set([0x57, 0x45, 0x42, 0x50], 8); // WEBP
    webpVp8x.set([0x56, 0x50, 0x38, 0x58], 12); // VP8X
    const wMinus1 = 640 - 1;
    const hMinus1 = 360 - 1;
    webpVp8x[24] = wMinus1 & 0xff;
    webpVp8x[25] = (wMinus1 >> 8) & 0xff;
    webpVp8x[26] = (wMinus1 >> 16) & 0xff;
    webpVp8x[27] = hMinus1 & 0xff;
    webpVp8x[28] = (hMinus1 >> 8) & 0xff;
    webpVp8x[29] = (hMinus1 >> 16) & 0xff;
    expect(inspectImageHeader(webpVp8x)).toMatchObject({ width: 640, height: 360, format: 'webp' });

    // SVG width/height + viewBox
    const svg = new TextEncoder().encode(
      '<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 800 500"><rect fill="#C46A34" width="800" height="500"/></svg>',
    );
    expect(inspectImageHeader(svg)).toMatchObject({ width: 800, height: 500, format: 'svg' });

    // BMP dimension + pure-TS color extraction + 64-dim fingerprint
    const bmp = createSolidBmp(32, 24, 196, 106, 52);
    expect(inspectImageHeader(bmp)).toMatchObject({ width: 32, height: 24, format: 'bmp' });
    const extracted = await processor.extractColorsAndFingerprint(bmp, 'image/bmp');
    expect(extracted.colors.length).toBeGreaterThan(0);
    expect(extracted.colors[0].hex.toUpperCase()).toBe('#C46A34');
    expect(extracted.featurePrint?.length).toBe(64);

    // SVG vector artwork cards
    const swatchCard = await processor.renderArtworkCard({
      kind: 'colorSwatch',
      color: labFromHex('#BA6B55'),
      title: 'Terracotta',
    });
    expect(swatchCard.mimeType).toBe('image/svg+xml');
    expect(utf8Decode(swatchCard.grid520)).toContain('<svg');
    expect(utf8Decode(swatchCard.grid520)).toContain('#BA6B55');

    const bookmarkCard = await processor.renderArtworkCard({
      kind: 'webBookmark',
      title: 'Cloudflare Workers Docs',
      domain: 'developers.cloudflare.com',
      description: 'Run Charkle globally at the edge.',
    });
    expect(utf8Decode(bookmarkCard.grid520)).toContain('developers.cloudflare.com');

    // Optional Cloudflare Images binding integration
    let transformCalls = 0;
    const mockImagesBinding: CloudflareImagesBinding = {
      input(_stream) {
        const chain = {
          transform() {
            transformCalls++;
            return chain;
          },
          async output() {
            return {
              response() {
                return new Response(new Uint8Array(jpeg), {
                  status: 200,
                  headers: { 'Content-Type': 'image/jpeg' },
                });
              },
            };
          },
        };
        return chain;
      },
    };
    const cfImagesProc = new WorkersImageProcessor({ imagesBinding: mockImagesBinding });
    const largePng = await sharp({
      create: { width: 1600, height: 900, channels: 3, background: { r: 80, g: 120, b: 160 } },
    })
      .png()
      .toBuffer();
    const cfThumbs = await cfImagesProc.generateThumbnails(largePng, 'image/png');
    expect(transformCalls).toBeGreaterThanOrEqual(2);
    expect(cfThumbs.mimeType).toBe('image/jpeg');
    expect(cfThumbs.grid520?.byteLength).toBeGreaterThan(0);
    expect(cfThumbs.preview1400?.byteLength).toBeGreaterThan(0);

    // Pure-JS lossless .charkleboard ZIP export without sharp
    const board = createDefaultMoodboardDocument({
      id: toSwiftUUID('77777777-7777-4777-8777-777777777701'),
      title: 'Edge Moodboard',
      nodes: [
        {
          id: toSwiftUUID('77777777-7777-4777-8777-777777777711'),
          kind: {
            type: 'note',
            title: 'Direction',
            text: 'Minimal warm terracotta & linen',
            style: 'warm',
            fontSize: 16,
          },
          frame: { x: 20, y: 20, width: 260, height: 140 },
          zIndex: 0,
          rotationDegrees: 0,
          flipHorizontal: false,
          flipVertical: false,
          isLocked: false,
          editorialOrder: 0,
          updatedAt: new Date().toISOString(),
        },
      ],
    });
    const zipResult = await processor.exportFigmaBridgeZip({
      document: board,
      assetsByID: new Map(),
      loadOriginalBytes: async () => null,
      loadThumbnailBytes: async () => null,
    });
    const parsedZip = await JSZip.loadAsync(zipResult.zipBytes);
    expect(parsedZip.file('board.json')).not.toBeNull();
    expect(parsedZip.file('migration-report.json')).not.toBeNull();
    expect(zipResult.report.noteCount).toBe(1);
  });

  it('persists SecretVault AES-256-GCM ciphertext in ISqlDatabase via Web Crypto and stays wire-compatible with Node vault', async () => {
    const dir = makeTempDir('charkle-vault-');
    const sql = new NodeSqlDatabase(path.join(dir, 'vault.sqlite'));
    try {
      // 1. Write via pure Web Crypto SecretVault (no syncCrypto)
      const vault1 = await SecretVault.open(sql, { masterKeySecret: 'shared-vault-passphrase' });
      vault1.set(SECRET_KEYS.GEMINI_API_KEY, 'AIza-test-cloudflare-key');
      vault1.set(SECRET_KEYS.WEBDAV_PASSWORD, 'webdav-super-secret');
      await vault1.flush();

      // Confirm ciphertext in SQLite does NOT leak plaintext
      const rawRow = sql.get<{ payload: string }>(
        'SELECT payload FROM sync_state WHERE key = ?',
        [VAULT_SECRETS_STATE_KEY],
      );
      expect(rawRow?.payload).toBeTruthy();
      expect(rawRow!.payload).not.toContain('AIza-test-cloudflare-key');
      expect(rawRow!.payload).not.toContain('webdav-super-secret');

      // 2. Reopen with fresh Web Crypto SecretVault
      const vault2 = await SecretVault.open(sql, { masterKeySecret: 'shared-vault-passphrase' });
      expect(vault2.get(SECRET_KEYS.GEMINI_API_KEY)).toBe('AIza-test-cloudflare-key');
      expect(vault2.get(SECRET_KEYS.WEBDAV_PASSWORD)).toBe('webdav-super-secret');

      // 3. Open with Node synchronous vault adapter -> exact wire-format compatibility!
      const nodeVault = createNodeSecretVault(sql, dir, 'shared-vault-passphrase');
      expect(nodeVault.get(SECRET_KEYS.GEMINI_API_KEY)).toBe('AIza-test-cloudflare-key');
      nodeVault.set(SECRET_KEYS.OPENAI_API_KEY, 'sk-node-written-key');

      // 4. Web Crypto SecretVault reads back what Node wrote!
      const vault3 = await SecretVault.open(sql, { masterKeySecret: 'shared-vault-passphrase' });
      expect(vault3.get(SECRET_KEYS.OPENAI_API_KEY)).toBe('sk-node-written-key');
    } finally {
      sql.close();
    }
  });

  it('supports NodeBlobStore streaming Range reads and blocks path traversal', async () => {
    const dir = makeTempDir('charkle-blob-');
    const store = new NodeBlobStore(dir);
    const payload = new TextEncoder().encode('0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZ');
    const stream = new ReadableStream<Uint8Array>({
      start(c) {
        c.enqueue(payload.subarray(0, 12));
        c.enqueue(payload.subarray(12));
        c.close();
      },
    });
    const putRes = await store.put('originals/sample.txt', stream, { contentType: 'text/plain' });
    expect(putRes.size).toBe(payload.byteLength);

    const sliced = await store.getStream('originals/sample.txt', { offset: 10, length: 6 });
    expect(sliced).not.toBeNull();
    expect(sliced!.range).toEqual({ start: 10, end: 15, total: payload.byteLength });
    expect(utf8Decode(await streamToBytes(sliced!.stream))).toBe('ABCDEF');

    await expect(store.put('../escape.txt', payload)).rejects.toThrow(/unsafe|escapes/i);
  });

  it('runs full Cloudflare runtimeMode end-to-end: health, 内置云存储, dynamic OAuth callback, ClientPreprocessedMedia, Range 206, seeding & streaming sync', async () => {
    const dir = makeTempDir('charkle-cf-e2e-');
    const sql = new NodeSqlDatabase(path.join(dir, 'do-sqlite.db'));
    const blobs = new MemoryBlobStore();
    const sharedDrive = new InMemoryDriveTransport({ email: 'edge@charkle.app' });

    const ctx = await createRuntimeContext({
      runtimeMode: 'cloudflare',
      sql,
      blobs,
      images: new WorkersImageProcessor(),
      passwordHasher: new WebCryptoPasswordHasher(),
      vaultSecret: 'cf-e2e-secret',
      transportOverride: sharedDrive,
      env: {
        CHARKLE_GOOGLE_CLIENT_ID: 'cf-google-client-id',
        CHARKLE_GOOGLE_CLIENT_SECRET: 'cf-google-client-secret',
      },
    });
    const app = createCoreApp(ctx);

    try {
      // 1. GET /api/v1/health reports runtimeMode: 'cloudflare' & exact feature flags
      const healthRes = await app.request('/api/v1/health');
      expect(healthRes.status).toBe(200);
      const health = (await healthRes.json()) as HealthResponse;
      expect(health.ok).toBe(true);
      expect(health.runtimeMode).toBe('cloudflare');
      expect(health.features).toEqual({
        localFolder: false,
        clientExportPreferred: true,
        googleDrive: true,
        webdav: true,
      });

      // 2. Setup admin using Web Crypto PBKDF2-SHA256 & authenticate
      const setupRes = await app.request('/api/v1/auth/setup', {
        method: 'POST',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify({ username: 'edgeadmin', password: 'edge-password-123' }),
      });
      expect(setupRes.status).toBe(201);
      const cookie = (setupRes.headers.get('set-cookie') ?? '').split(';')[0];
      const authHeaders = { Cookie: cookie };

      // 3. GET /api/v1/sync/config shows '内置云存储' for localOnly on cloudflare!
      const syncCfgRes = await app.request('/api/v1/sync/config', { headers: authHeaders });
      expect(syncCfgRes.status).toBe(200);
      const syncCfg = (await syncCfgRes.json()) as {
        config: { mode: string };
        activeLocationSummary: string;
      };
      expect(syncCfg.config.mode).toBe('localOnly');
      expect(syncCfg.activeLocationSummary).toBe('内置云存储');

      // 4. Dynamic Google OAuth callback URL derivation behind Cloudflare reverse proxy headers
      const oauthStartRes = await app.request('/api/v1/sync/google/oauth/start', {
        method: 'POST',
        headers: {
          ...authHeaders,
          'Content-Type': 'application/json',
          'X-Forwarded-Proto': 'https',
          'X-Forwarded-Host': 'charkle.example.workers.dev',
        },
        body: JSON.stringify({}),
      });
      expect(oauthStartRes.status).toBe(200);
      const oauthStart = (await oauthStartRes.json()) as {
        authURL: string;
        state: string;
      };
      const parsedAuthUrl = new URL(oauthStart.authURL);
      expect(parsedAuthUrl.searchParams.get('redirect_uri')).toBe(
        'https://charkle.example.workers.dev/api/v1/sync/google/oauth/callback',
      );
      expect(parsedAuthUrl.searchParams.get('client_id')).toBe('cf-google-client-id');
      // PKCE state is persisted in SQLite sync_state so DO hibernation / reconnect survives!
      const savedPkce = ctx.db.getState<unknown>(`oauth.google.pkce.${oauthStart.state}`);
      expect(savedPkce).not.toBeNull();

      // 5. Upload with ClientPreprocessedMedia (browser-generated thumbnails, colors & 64-dim fingerprint)
      const originalBytes = new Uint8Array(256);
      for (let i = 0; i < originalBytes.length; i++) originalBytes[i] = i;
      const thumb520 = await sharp({
        create: { width: 120, height: 80, channels: 3, background: { r: 196, g: 106, b: 52 } },
      })
        .jpeg({ quality: 80 })
        .toBuffer();
      const thumb1400 = await sharp({
        create: { width: 240, height: 160, channels: 3, background: { r: 196, g: 106, b: 52 } },
      })
        .jpeg({ quality: 84 })
        .toBuffer();

      const fp = Array.from({ length: 64 }, (_, i) => (i === 0 ? 1 : 0));
      const preprocessed: ClientPreprocessedMedia = {
        pixelWidth: 1920,
        pixelHeight: 1080,
        thumbnail520Base64: bytesToBase64(thumb520),
        thumbnail1400Base64: bytesToBase64(thumb1400),
        dominantColors: [labFromHex('#C46A34', 0.8), labFromHex('#F5EDE4', 0.2)],
        featurePrintBase64: encodeFeaturePrintFloat32(fp),
      };

      const form = new FormData();
      form.append(
        'files',
        new File([originalBytes], 'hero-shot.bin', { type: 'application/octet-stream' }),
      );
      form.append('preprocessed', JSON.stringify([preprocessed]));

      const uploadRes = await app.request('/api/v1/assets/upload', {
        method: 'POST',
        headers: authHeaders,
        body: form,
      });
      expect(uploadRes.status).toBe(201);
      const uploaded = (await uploadRes.json()) as {
        assets: Array<{
          id: string;
          pixelWidth: number | null;
          pixelHeight: number | null;
          dominantColors: Array<{ hex: string }>;
        }>;
      };
      expect(uploaded.assets).toHaveLength(1);
      const asset = uploaded.assets[0];
      expect(asset.pixelWidth).toBe(1920);
      expect(asset.pixelHeight).toBe(1080);
      expect(asset.dominantColors[0].hex.toUpperCase()).toBe('#C46A34');
      expect(ctx.db.getVector(asset.id)?.featurePrint).toBe(preprocessed.featurePrintBase64);

      // 6. Thumbnail & Range 206 streaming from MemoryBlobStore (R2 semantics)
      const thumbRes = await app.request(`/api/v1/media/${asset.id}/thumbnail/grid520`, {
        headers: authHeaders,
      });
      expect(thumbRes.status).toBe(200);
      expect(thumbRes.headers.get('content-type')).toBe('image/jpeg');
      expect((await thumbRes.arrayBuffer()).byteLength).toBe(thumb520.byteLength);

      const previewRes = await app.request(`/api/v1/media/${asset.id}/thumbnail/preview1400`, {
        headers: authHeaders,
      });
      expect(previewRes.status).toBe(200);
      expect(previewRes.headers.get('content-type')).toBe('image/jpeg');
      expect((await previewRes.arrayBuffer()).byteLength).toBe(thumb1400.byteLength);

      const rangeRes = await app.request(`/api/v1/media/${asset.id}/original`, {
        headers: { ...authHeaders, Range: 'bytes=16-31' },
      });
      expect(rangeRes.status).toBe(206);
      expect(rangeRes.headers.get('content-range')).toBe('bytes 16-31/256');
      const rangeBody = new Uint8Array(await rangeRes.arrayBuffer());
      expect(rangeBody.byteLength).toBe(16);
      expect(rangeBody[0]).toBe(16);
      expect(rangeBody[15]).toBe(31);

      const badRangeRes = await app.request(`/api/v1/media/${asset.id}/original`, {
        headers: { ...authHeaders, Range: 'bytes=999-1024' },
      });
      expect(badRangeRes.status).toBe(416);

      // 7. JSON ingest with imageData + ClientPreprocessedMedia
      const ingestRes = await app.request('/api/v1/assets/ingest', {
        method: 'POST',
        headers: { ...authHeaders, 'Content-Type': 'application/json' },
        body: JSON.stringify({
          inputs: [
            {
              type: 'imageData',
              base64Data: bytesToBase64(thumb520),
              suggestedName: 'Pasted Inspiration.jpg',
              preprocessed,
            },
          ],
        }),
      });
      expect(ingestRes.status).toBe(201);
      const ingested = (await ingestRes.json()) as {
        assets: Array<{ id: string; pixelWidth: number | null; dominantColors: Array<{ hex: string }> }>;
      };
      expect(ingested.assets[0].pixelWidth).toBe(1920);
      expect(ingested.assets[0].dominantColors[0].hex.toUpperCase()).toBe('#C46A34');

      // 8. SampleLibrarySeeder works smoothly on WorkersImageProcessor (zero sharp)
      const seeded = await SampleLibrarySeeder.seed(ctx.db, ctx.media, true);
      expect(seeded).toBe(true);
      expect(ctx.db.countAssets()).toBeGreaterThan(5);

      // 9. Streaming sync against remote transport (zero node:fs)
      const syncReport = await ctx.sync.syncWithTransport(
        sharedDrive,
        createDefaultDriveSyncConfig({
          mode: 'directAPIWithGDirect',
          rootFolderName: 'CharkleEdge',
        }),
      );
      expect(syncReport.uploadedOps).toBeGreaterThan(0);
      expect(sharedDrive.readTextByPath('CharkleEdge/.charkle/manifest.json')).not.toBeNull();
    } finally {
      sql.close();
    }
  });
});
