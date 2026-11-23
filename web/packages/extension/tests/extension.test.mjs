import assert from 'node:assert/strict';
import fs from 'node:fs';
import path from 'node:path';
import test from 'node:test';
import { fileURLToPath } from 'node:url';

import {
  arrayBufferToBase64,
  CharkleApiError,
  createCharkleClient,
  ingestImageUrl,
  ingestImageUrlsBatch,
  testConnection,
} from '../lib/api.js';
import {
  filterAndSortImages,
  isLargeImageCandidate,
  parseSrcsetBestUrl,
  upgradeImageCandidateUrl,
} from '../lib/image-filter.js';
import {
  buildFolderOptions,
  getConfig,
  isConfigured,
  resolveActiveTarget,
  saveConfig,
} from '../lib/storage.js';
import {
  deriveImageFileName,
  detectSpecialSource,
  isDirectImageUrl,
  isLightHex,
  isSameOriginUrl,
  normalizeHexColor,
  normalizeServerUrl,
} from '../lib/url-detect.js';

const __dirname = path.dirname(fileURLToPath(import.meta.url));
const EXT_ROOT = path.resolve(__dirname, '..');

function createJsonResponse(body, status = 200) {
  return new Response(JSON.stringify(body), {
    status,
    headers: { 'content-type': 'application/json' },
  });
}

// MARK: - 1. Manifest V3 & Asset Integrity Tests

test('manifest.json is valid MV3 and every referenced file exists', () => {
  const manifestPath = path.join(EXT_ROOT, 'manifest.json');
  const manifest = JSON.parse(fs.readFileSync(manifestPath, 'utf8'));

  assert.equal(manifest.manifest_version, 3);
  assert.equal(typeof manifest.name, 'string');
  assert.equal(typeof manifest.version, 'string');

  const requiredPerms = ['activeTab', 'contextMenus', 'storage', 'scripting', 'notifications'];
  for (const perm of requiredPerms) {
    assert.ok(manifest.permissions.includes(perm), `Missing permission: ${perm}`);
  }
  assert.ok(manifest.host_permissions.includes('<all_urls>'));

  assert.equal(manifest.background.service_worker, 'background.js');
  assert.equal(manifest.background.type, 'module');
  assert.equal(manifest.action.default_popup, 'popup.html');
  assert.equal(manifest.options_ui.page, 'options.html');

  // Verify commands exist without key collisions
  assert.ok(manifest.commands._execute_action);
  assert.ok(manifest.commands['quick-capture-page']);
  assert.equal(manifest.commands['quick-capture-page'].suggested_key.default, 'Alt+Shift+C');
  assert.notEqual(
    manifest.commands._execute_action.suggested_key.default,
    manifest.commands['quick-capture-page'].suggested_key.default,
  );

  // Verify all referenced files exist on disk
  const filesToCheck = [
    manifest.background.service_worker,
    manifest.action.default_popup,
    manifest.options_ui.page,
    ...Object.values(manifest.icons),
    ...Object.values(manifest.action.default_icon),
    ...manifest.content_scripts.flatMap((cs) => cs.js || []),
    ...manifest.web_accessible_resources.flatMap((r) => r.resources || []),
  ];

  for (const rel of filesToCheck) {
    const abs = path.join(EXT_ROOT, rel);
    assert.ok(fs.existsSync(abs), `Referenced file missing: ${rel}`);
    assert.ok(fs.statSync(abs).size > 0, `Referenced file empty: ${rel}`);
  }
});

// MARK: - 2. CSS, Motion, Copy & CSP Hygiene Tests

test('CSS, HTML, and runtime UI files pass motion, token, CSP, DOM-ID, and clean-copy checks', () => {
  const cssFiles = ['popup.css', 'options.css'].map((f) => ({
    name: f,
    content: fs.readFileSync(path.join(EXT_ROOT, f), 'utf8'),
  }));
  const contentJs = fs.readFileSync(path.join(EXT_ROOT, 'content.js'), 'utf8');

  for (const { name, content } of cssFiles) {
    assert.equal(/transition\s*:\s*all\b/i.test(content), false, `${name} must not use transition: all`);
    assert.equal(/linear-gradient|radial-gradient/i.test(content), false, `${name} must not use decorative gradients`);
    assert.ok(content.includes('#F6F6F5'), `${name} should use Charkle Light ground #F6F6F5`);
    assert.ok(content.includes('#141517'), `${name} should use Charkle Dark ground #141517`);
    assert.ok(content.includes('prefers-color-scheme: dark'), `${name} should auto-adapt to dark mode`);
    assert.ok(content.includes('prefers-reduced-motion: reduce'), `${name} must support prefers-reduced-motion`);
    assert.ok(content.includes('corner-shape: superellipse(1.25)'), `${name} should include continuous corners`);
  }

  // content.js overlay styling checks
  assert.equal(/transition\s*:\s*all\b/i.test(contentJs), false, 'content.js must not use transition: all');
  assert.ok(contentJs.includes('prefers-reduced-motion: reduce'), 'content.js must support prefers-reduced-motion');
  assert.ok(contentJs.includes('prefers-color-scheme: dark'), 'content.js must support dark mode');
  assert.ok(contentJs.includes('--ease-out: cubic-bezier(0.23, 1, 0.32, 1)'), 'content.js must define --ease-out');
  assert.ok(contentJs.includes('--ease-out-strong'), 'content.js must use --ease-out-strong');
  assert.equal(/--ease-in\b|cubic-bezier\(\s*0\.42\s*,\s*0\s*,\s*1\s*,\s*1\s*\)/.test(contentJs), false, 'content.js must not use ease-in on UI');

  // MV3 CSP: zero inline scripts or inline onclick handlers in HTML
  for (const htmlFile of ['popup.html', 'options.html']) {
    const html = fs.readFileSync(path.join(EXT_ROOT, htmlFile), 'utf8');
    assert.equal(/\sonclick=/i.test(html), false, `${htmlFile} must not use inline onclick handlers`);
    const scriptTags = [...html.matchAll(/<script\b([^>]*)>/gi)];
    assert.ok(scriptTags.length >= 1, `${htmlFile} should load its JS module`);
    for (const m of scriptTags) {
      assert.ok(/\bsrc=/.test(m[1]), `${htmlFile} must not contain inline <script> blocks`);
    }
  }

  // Every $('id') in popup.js / options.js must exist in its corresponding HTML file
  for (const [jsName, htmlName] of [
    ['popup.js', 'popup.html'],
    ['options.js', 'options.html'],
  ]) {
    const js = fs.readFileSync(path.join(EXT_ROOT, jsName), 'utf8');
    const html = fs.readFileSync(path.join(EXT_ROOT, htmlName), 'utf8');
    const htmlIds = new Set([...html.matchAll(/\bid="([^"]+)"/g)].map((m) => m[1]));
    const referencedIds = [...js.matchAll(/\$\(['"]([^'"]+)['"]\)/g)].map((m) => m[1]);
    assert.ok(referencedIds.length > 0, `${jsName} should reference DOM IDs`);
    for (const id of referencedIds) {
      assert.ok(htmlIds.has(id), `${jsName} references missing DOM id #${id} in ${htmlName}`);
    }
  }

  // Zero developer jargon / internal design-system terms across extension UI & runtime files
  const forbiddenJargon =
    /\b(Manifest V3|Bearer|PAT|Personal Access Token|Shadow DOM|CORS|Gallery-First|Liquid Glass|16-Grid|Layered|Duotone|scrypt|HttpOnly|FTS5)\b|唯一主角|零摩擦/i;
  for (const rel of [
    'popup.html',
    'popup.css',
    'popup.js',
    'options.html',
    'options.css',
    'options.js',
    'content.js',
    'background.js',
  ]) {
    const text = fs.readFileSync(path.join(EXT_ROOT, rel), 'utf8');
    const hit = forbiddenJargon.exec(text);
    assert.equal(hit, null, `${rel} contains forbidden developer jargon: ${hit?.[0]}`);
  }
});

// MARK: - 3. URL Detection, Color & Filename Utilities

test('detectSpecialSource matches X, Threads, Bluesky, GitHub repos, and generic web URLs', () => {
  assert.equal(detectSpecialSource('https://x.com/design/status/18881234567890').kind, 'x');
  assert.equal(detectSpecialSource('https://fxtwitter.com/alice/status/99999').kind, 'x');
  assert.equal(detectSpecialSource('https://x.com/i/web/status/123456').kind, 'x');
  assert.equal(detectSpecialSource('https://www.threads.net/@char/post/ABCdef123').kind, 'threads');
  assert.equal(detectSpecialSource('https://threads.com/t/XYZ789').kind, 'threads');
  assert.equal(
    detectSpecialSource('https://bsky.app/profile/alice.bsky.social/post/3k2abc').kind,
    'bluesky',
  );
  assert.equal(detectSpecialSource('https://github.com/vercel/next.js').kind, 'github');
  assert.equal(detectSpecialSource('https://github.com/vercel/next.js/tree/canary').kind, 'github');
  assert.equal(detectSpecialSource('https://github.com/vercel/next.js/issues/123').kind, 'web');
  assert.equal(detectSpecialSource('https://github.com/settings/tokens').kind, 'web');
  assert.equal(detectSpecialSource('https://example.com/channels/minimal').kind, 'web');
  assert.equal(detectSpecialSource('chrome://extensions').kind, 'unsupported');
});

test('normalizeServerUrl, isSameOriginUrl, hex and image filename helpers work accurately', () => {
  assert.equal(normalizeServerUrl('http://127.0.0.1:3417/'), 'http://127.0.0.1:3417');
  assert.equal(normalizeServerUrl('127.0.0.1:3417'), 'http://127.0.0.1:3417');
  assert.equal(normalizeServerUrl('localhost:3417'), 'http://localhost:3417');
  assert.equal(normalizeServerUrl('charkle.example.com/'), 'https://charkle.example.com');
  assert.equal(normalizeServerUrl('ftp://invalid.host'), '');
  assert.equal(normalizeServerUrl('javascript:alert(1)'), '');
  assert.equal(normalizeServerUrl('file:///etc/passwd'), '');

  assert.equal(isSameOriginUrl('http://127.0.0.1:3417', 'http://127.0.0.1:3417/boards/1'), true);
  assert.equal(isSameOriginUrl('http://127.0.0.1:3417', 'https://example.com/page'), false);

  assert.equal(normalizeHexColor('#abc'), '#AABBCC');
  assert.equal(normalizeHexColor('2a60e0'), '#2A60E0');
  assert.equal(normalizeHexColor('not-a-color'), null);
  assert.equal(isLightHex('#F6F6F5'), true);
  assert.equal(isLightHex('#141517'), false);

  assert.equal(isDirectImageUrl('https://cdn.example.com/photo.webp?w=1200'), true);
  assert.equal(isDirectImageUrl('https://pbs.twimg.com/media/abc?format=jpg&name=large'), true);
  assert.equal(isDirectImageUrl('https://example.com/article'), false);

  assert.equal(
    deriveImageFileName('https://cdn.example.com/hero.jpg?v=1', '', 'image/webp'),
    'hero.webp',
  );
  assert.equal(
    deriveImageFileName('https://cdn.example.com/a', '灵感封面', 'image/png'),
    '灵感封面.png',
  );
});

// MARK: - 4. Image Filter & Storage Helpers

test('image-filter filters tiny pixels, upgrades Twitter CDN URLs, deduplicates and sorts by area', () => {
  assert.equal(
    upgradeImageCandidateUrl('https://pbs.twimg.com/media/FooBar?format=jpg&name=small'),
    'https://pbs.twimg.com/media/FooBar?format=jpg&name=large',
  );
  assert.equal(
    parseSrcsetBestUrl('/small.jpg 400w, /large.jpg 1600w', 'https://example.com/post'),
    'https://example.com/large.jpg',
  );

  const filtered = filterAndSortImages([
    { url: 'https://example.com/tracker.gif', width: 1, height: 1, source: 'img' },
    { url: 'https://example.com/icon.png', width: 32, height: 32, source: 'img' },
    { url: 'https://example.com/med.jpg', width: 300, height: 200, alt: 'Medium', source: 'img' },
    { url: 'https://example.com/hero.jpg', width: 1920, height: 1080, alt: 'Hero', source: 'img' },
    { url: 'https://example.com/hero.jpg', width: 800, height: 450, alt: '', source: 'bg' },
    { url: 'https://example.com/og.png', width: 0, height: 0, alt: 'OG', source: 'og' },
  ]);

  assert.equal(filtered.length, 3);
  assert.equal(filtered[0].url, 'https://example.com/hero.jpg');
  assert.equal(filtered[0].width, 1920);
  assert.equal(filtered[1].url, 'https://example.com/med.jpg');
  assert.equal(filtered[2].url, 'https://example.com/og.png');
  assert.equal(isLargeImageCandidate(filtered[0]), true);
  assert.equal(isLargeImageCandidate(filtered[1]), false);
  assert.equal(isLargeImageCandidate(filtered[2]), true);
});

test('storage helpers resolve targets and build nested folder hierarchy cleanly', async () => {
  const mem = new Map();
  const mockStorage = {
    async get(key) {
      return { [key]: mem.get(key) };
    },
    async set(obj) {
      for (const [k, v] of Object.entries(obj)) mem.set(k, v);
    },
  };

  let cfg = await getConfig(mockStorage);
  assert.equal(isConfigured(cfg), false);
  assert.equal(resolveActiveTarget(cfg).label, '收件箱');

  cfg = await saveConfig(
    {
      serverUrl: 'http://127.0.0.1:3417/',
      apiToken: 'chk_secret123',
      targetMode: 'folder',
      targetFolderId: 'F-CHILD',
      cachedFolders: [
        { id: 'F-ROOT', name: '设计参考', parentID: null, sortOrder: 0, assetCount: 12 },
        { id: 'F-CHILD', name: '字体排版', parentID: 'F-ROOT', sortOrder: 0, assetCount: 4 },
      ],
    },
    mockStorage,
  );

  assert.equal(isConfigured(cfg), true);
  assert.equal(cfg.serverUrl, 'http://127.0.0.1:3417');
  assert.deepEqual(resolveActiveTarget(cfg), {
    mode: 'folder',
    targetFolderId: 'F-CHILD',
    targetBoardId: null,
    label: '字体排版',
  });

  const tree = buildFolderOptions(cfg.cachedFolders);
  assert.equal(tree.length, 2);
  assert.equal(tree[0].id, 'F-ROOT');
  assert.equal(tree[1].id, 'F-CHILD');
  assert.ok(tree[1].label.includes('└ 字体排版'));
});

// MARK: - 5. API Client Contract Tests

test('testConnection validates auth/status and fetches folders + boards with Bearer token', async () => {
  const calls = [];
  const mockFetch = async (url, init) => {
    calls.push({ url, method: init.method, auth: init.headers.Authorization });
    if (url.endsWith('/api/v1/auth/status')) {
      return createJsonResponse({
        initialized: true,
        authenticated: true,
        user: { id: 'U1', username: 'char', displayName: 'Char', role: 'owner' },
        sessionCount: 1,
      });
    }
    if (url.endsWith('/api/v1/folders')) {
      return createJsonResponse({ folders: [{ id: 'F1', name: 'UI 灵感', parentID: null, sortOrder: 0, assetCount: 5 }] });
    }
    if (url.endsWith('/api/v1/boards')) {
      return createJsonResponse({ boards: [{ id: 'B1', title: '品牌视觉板', itemCount: 8 }] });
    }
    throw new Error(`Unexpected URL: ${url}`);
  };

  const cfg = { serverUrl: 'http://127.0.0.1:3417', apiToken: 'chk_test_token' };
  const res = await testConnection(cfg, { fetchImpl: mockFetch });
  assert.equal(res.ok, true);
  assert.equal(res.user.username, 'char');
  assert.equal(res.folders.length, 1);
  assert.equal(res.boards.length, 1);
  assert.equal(calls.length, 3);
  assert.ok(calls.every((c) => c.auth === 'Bearer chk_test_token'));

  await assert.rejects(
    () =>
      testConnection(cfg, {
        fetchImpl: async () =>
          createJsonResponse({ initialized: true, authenticated: false, user: null, sessionCount: 0 }),
      }),
    (err) => err instanceof CharkleApiError && err.code === 'UNAUTHORIZED',
  );
});

test('ingestUrl, ingestImageDataUrl, ingestTextSnippet, ingestColorSwatch send exact Charkle server contracts', async () => {
  const captured = [];
  const mockFetch = async (url, init) => {
    captured.push({
      url,
      method: init.method,
      headers: init.headers,
      body: JSON.parse(init.body),
    });
    return createJsonResponse({ assets: [{ id: 'A1', title: 'Saved' }] }, 201);
  };

  const client = createCharkleClient(
    { serverUrl: 'http://127.0.0.1:3417', apiToken: 'chk_demo' },
    { fetchImpl: mockFetch },
  );

  await client.ingestUrl('https://x.com/a/status/123', '推文标题', '备注', 'FOLDER-1', null);
  await client.ingestImageDataUrl('data:image/png;base64,AAAA', 'shot.png', 'https://example.com', null, 'BOARD-1');
  await client.ingestTextSnippet('设计笔记', '留白即呼吸感', 'https://example.com', 'FOLDER-1', null);
  await client.ingestColorSwatch('#2a60e0', 'Studio Blue', null, 'BOARD-1');

  assert.equal(captured.length, 4);
  for (const call of captured) {
    assert.equal(call.url, 'http://127.0.0.1:3417/api/v1/assets/ingest');
    assert.equal(call.method, 'POST');
    assert.equal(call.headers.Authorization, 'Bearer chk_demo');
  }

  assert.deepEqual(captured[0].body, {
    inputs: [{ type: 'webURL', url: 'https://x.com/a/status/123', title: '推文标题', notes: '备注' }],
    targetFolderID: 'FOLDER-1',
    targetBoardID: null,
  });

  assert.deepEqual(captured[1].body, {
    inputs: [
      {
        type: 'imageData',
        base64Data: 'data:image/png;base64,AAAA',
        suggestedName: 'shot.png',
        sourceURL: 'https://example.com',
      },
    ],
    targetFolderID: null,
    targetBoardID: 'BOARD-1',
  });

  assert.deepEqual(captured[2].body, {
    inputs: [
      {
        type: 'textSnippet',
        title: '设计笔记',
        text: '留白即呼吸感',
        sourceURL: 'https://example.com',
      },
    ],
    targetFolderID: 'FOLDER-1',
    targetBoardID: null,
  });

  assert.deepEqual(captured[3].body, {
    inputs: [{ type: 'colorSwatch', hex: '#2A60E0', title: 'Studio Blue' }],
    targetFolderID: null,
    targetBoardID: 'BOARD-1',
  });
});

test('ingestImageUrl fetches binary image and falls back gracefully when fetch fails', async () => {
  const cfg = { serverUrl: 'http://127.0.0.1:3417', apiToken: 'chk_img' };
  const fakePng = new Uint8Array([0x89, 0x50, 0x4e, 0x47, 1, 2, 3, 4]);
  assert.equal(arrayBufferToBase64(fakePng.buffer), Buffer.from(fakePng).toString('base64'));

  let postedBody = null;
  await ingestImageUrl(
    cfg,
    'https://cdn.site.example/art.png',
    'https://site.example/gallery',
    '作品海报',
    'FOLDER-9',
    null,
    {
      fetchImpl: async (url, init) => {
        if (url === 'https://cdn.site.example/art.png') {
          return new Response(fakePng, { status: 200, headers: { 'content-type': 'image/png' } });
        }
        postedBody = JSON.parse(init.body);
        return createJsonResponse({ assets: [{ id: 'IMG-1', title: '作品海报' }] }, 201);
      },
    },
  );
  assert.equal(postedBody.inputs[0].type, 'imageData');
  assert.equal(postedBody.inputs[0].suggestedName, '作品海报.png');
  assert.equal(postedBody.inputs[0].sourceURL, 'https://site.example/gallery');
  assert.equal(postedBody.targetFolderID, 'FOLDER-9');

  let fallbackBody = null;
  await ingestImageUrl(
    cfg,
    'https://blocked.example/secret.jpg',
    'https://blocked.example/post',
    '参考图',
    null,
    'BOARD-2',
    {
      fetchImpl: async (url, init) => {
        if (url.startsWith('https://blocked.example/')) {
          return new Response('Forbidden', { status: 403, headers: { 'content-type': 'text/plain' } });
        }
        fallbackBody = JSON.parse(init.body);
        return createJsonResponse({ assets: [{ id: 'IMG-2', title: '参考图' }] }, 201);
      },
    },
  );
  assert.equal(fallbackBody.inputs[0].type, 'webURL');
  assert.equal(fallbackBody.inputs[0].url, 'https://blocked.example/secret.jpg');
  assert.equal(fallbackBody.targetBoardID, 'BOARD-2');
});

test('ingestImageUrlsBatch tolerates partial failures and reports live progress', async () => {
  const cfg = { serverUrl: 'http://127.0.0.1:3417', apiToken: 'chk_batch' };
  const progressEvents = [];
  const summary = await ingestImageUrlsBatch(
    cfg,
    [
      { url: 'data:image/png;base64,AAAA', title: 'A' },
      { url: 'data:image/png;base64,BBBB', title: 'B' },
    ],
    'https://example.com',
    null,
    null,
    {
      concurrency: 2,
      onProgress: (p) => progressEvents.push(p),
      fetchImpl: async (_url, init) => {
        const body = JSON.parse(init.body);
        if (body.inputs[0].suggestedName.startsWith('B')) {
          return createJsonResponse({ error: '测试失败' }, 500);
        }
        return createJsonResponse({ assets: [{ id: 'OK-1', title: 'A' }] }, 201);
      },
    },
  );

  assert.equal(summary.total, 2);
  assert.equal(summary.succeeded, 1);
  assert.equal(summary.failed, 1);
  assert.equal(progressEvents.length, 2);
  assert.equal(progressEvents[1].completed, 2);
});
