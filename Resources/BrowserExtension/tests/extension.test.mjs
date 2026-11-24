import assert from 'node:assert/strict';
import fs from 'node:fs';
import path from 'node:path';
import test from 'node:test';
import { fileURLToPath } from 'node:url';

import {
  arrayBufferToBase64,
  autoPairLocalDesktop,
  CharkleApiError,
  createCharkleClient,
  createOrReuseFolder,
  fetchExistingSources,
  ingestImageUrl,
  ingestImageUrlsBatch,
  ingestSocialBookmarksChunk,
  ingestUrl,
  probeLocalDesktop,
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
  DEFAULT_DESKTOP_SERVER_URL,
  getConfig,
  isConfigured,
  resolveActiveTarget,
  saveConfig,
} from '../lib/storage.js';
import {
  canonicalDedupKey,
  deriveImageFileName,
  detectBookmarkCollectionPage,
  detectSpecialSource,
  isDirectImageUrl,
  isLightHex,
  isSameOriginUrl,
  normalizeHexColor,
  normalizeServerUrl,
} from '../lib/url-detect.js';
import {
  cleanXiaohongshuBody,
  extractInitialStateJSON,
  normalizeXiaohongshuNoteUrl,
  parseChineseMetricCount,
  parseXiaohongshuNoteHtml,
  sanitizeJSUndefined,
} from '../lib/xhs-parser.js';

const __dirname = path.dirname(fileURLToPath(import.meta.url));
const EXT_ROOT = path.resolve(__dirname, '..');

function createJsonResponse(body, status = 200) {
  return new Response(JSON.stringify(body), {
    status,
    headers: { 'content-type': 'application/json' },
  });
}

// MARK: - 1. Manifest V3 & Asset Integrity Tests

test('manifest.json is valid MV3 with desktop loopback permissions and every referenced file exists', () => {
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
  assert.ok(manifest.host_permissions.includes('http://127.0.0.1/*'));

  assert.equal(manifest.background.service_worker, 'background.js');
  assert.equal(manifest.background.type, 'module');
  assert.equal(manifest.action.default_popup, 'popup.html');
  assert.equal(manifest.options_ui.page, 'options.html');

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

// MARK: - 2. CSS, Motion, Copy, DOM-ID & CSP Hygiene Tests

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

  const popupCss = cssFiles.find((f) => f.name === 'popup.css').content;
  assert.ok(popupCss.includes('grid-auto-rows: 103px;'), 'popup.css .images-grid must lock explicit row height to prevent Safari row squishing');
  assert.ok(popupCss.includes('align-content: start;'), 'popup.css .images-grid must top-align implicit rows');

  assert.equal(/transition\s*:\s*all\b/i.test(contentJs), false, 'content.js must not use transition: all');
  assert.ok(contentJs.includes('prefers-reduced-motion: reduce'), 'content.js must support prefers-reduced-motion');
  assert.ok(contentJs.includes('prefers-color-scheme: dark'), 'content.js must support dark mode');
  assert.ok(contentJs.includes('--ease-out: cubic-bezier(0.23, 1, 0.32, 1)'), 'content.js must define --ease-out');
  assert.equal(/--ease-in\b|cubic-bezier\(\s*0\.42\s*,\s*0\s*,\s*1\s*,\s*1\s*\)/.test(contentJs), false);
  assert.ok(contentJs.includes('if (window !== window.top) return;'), 'content.js must ignore sub-iframes');
  assert.ok(
    contentJs.includes("case 'START_BOOKMARK_IMPORT':\n        sendResponse(startBookmarkImport(msg.options || {}));"),
    'START_BOOKMARK_IMPORT must respond synchronously after launching detached loop',
  );

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
});

// MARK: - 3. URL Detection, Xiaohongshu & Bookmark Collection Pages

test('detectSpecialSource, detectBookmarkCollectionPage, and canonicalDedupKey match X & Xiaohongshu accurately', () => {
  assert.equal(detectSpecialSource('https://x.com/design/status/18881234567890').kind, 'x');
  assert.equal(detectSpecialSource('https://fxtwitter.com/alice/status/99999').kind, 'x');
  assert.equal(detectSpecialSource('https://www.xiaohongshu.com/explore/66a1b2c3d4e5f60718293a4b?xsec_token=abc123').kind, 'xiaohongshu');
  assert.equal(detectSpecialSource('https://www.xiaohongshu.com/discovery/item/66a1b2c3d4e5f60718293a4b').kind, 'xiaohongshu');
  assert.equal(detectSpecialSource('https://www.xiaohongshu.com/user/profile/5f1234567890abcdef123456/66a1b2c3d4e5f60718293a4b?xsec_token=t').kind, 'xiaohongshu');
  assert.equal(detectSpecialSource('http://xhslink.com/a/K8xYz123').kind, 'xiaohongshu');
  assert.equal(detectSpecialSource('https://www.threads.net/@char/post/ABCdef123').kind, 'threads');
  assert.equal(detectSpecialSource('https://bsky.app/profile/alice.bsky.social/post/3k2abc').kind, 'bluesky');
  assert.equal(detectSpecialSource('https://github.com/vercel/next.js').kind, 'github');
  assert.equal(detectSpecialSource('https://example.org/page').kind, 'web');

  // Collection pages (X classic bookmarks, 2026 History hub, likes, lists & Xiaohongshu profile/collect/board)
  const xBm = detectBookmarkCollectionPage('https://x.com/i/bookmarks');
  assert.equal(xBm.supported, true);
  assert.equal(xBm.isCollectionRoute, true);
  assert.equal(xBm.platform, 'x');
  assert.equal(xBm.suggestedFolderName, 'X 书签');

  const xBmAll = detectBookmarkCollectionPage('https://x.com/i/bookmarks/all');
  assert.equal(xBmAll.supported, true);
  assert.equal(xBmAll.pageKind, 'bookmarks');

  const xFolder = detectBookmarkCollectionPage('https://x.com/i/bookmarks/182736455');
  assert.equal(xFolder.supported, true);
  assert.equal(xFolder.pageKind, 'bookmark_folder');

  const xHistory = detectBookmarkCollectionPage('https://x.com/i/history');
  assert.equal(xHistory.supported, true);
  assert.equal(xHistory.platform, 'x');
  assert.equal(xHistory.pageKind, 'history');
  assert.equal(xHistory.suggestedFolderName, 'X 书签');

  const xHistoryBm = detectBookmarkCollectionPage('https://x.com/i/history/bookmarks');
  assert.equal(xHistoryBm.supported, true);
  assert.equal(xHistoryBm.pageKind, 'bookmarks');

  const xHistoryLikes = detectBookmarkCollectionPage('https://x.com/i/history/likes');
  assert.equal(xHistoryLikes.supported, true);
  assert.equal(xHistoryLikes.pageKind, 'likes');
  assert.equal(xHistoryLikes.suggestedFolderName, 'X 喜欢');

  const xUserBm = detectBookmarkCollectionPage('https://x.com/alice/bookmarks');
  assert.equal(xUserBm.supported, true);
  assert.equal(xUserBm.pageKind, 'bookmarks');

  const xUserLikes = detectBookmarkCollectionPage('https://x.com/alice/likes');
  assert.equal(xUserLikes.supported, true);
  assert.equal(xUserLikes.pageKind, 'likes');

  const xhsCollect = detectBookmarkCollectionPage('https://www.xiaohongshu.com/user/profile/5f1234567890abcdef123456?tab=collect');
  assert.equal(xhsCollect.supported, true);
  assert.equal(xhsCollect.platform, 'xiaohongshu');
  assert.equal(xhsCollect.pageKind, 'collect');
  assert.equal(xhsCollect.suggestedFolderName, '小红书收藏');

  const xhsCollectPath = detectBookmarkCollectionPage('https://www.xiaohongshu.com/user/profile/5f1234567890abcdef123456/collect');
  assert.equal(xhsCollectPath.supported, true);
  assert.equal(xhsCollectPath.pageKind, 'collect');

  const xhsSingleNoteUnderProfile = detectBookmarkCollectionPage('https://www.xiaohongshu.com/user/profile/5f1234567890abcdef123456/66a1b2c3d4e5f60718293a4b');
  assert.equal(xhsSingleNoteUnderProfile.supported, false);

  const xhsBoard = detectBookmarkCollectionPage('https://www.xiaohongshu.com/board/66bbccddeeff001122334455');
  assert.equal(xhsBoard.supported, true);
  assert.equal(xhsBoard.pageKind, 'board');

  assert.equal(detectBookmarkCollectionPage('https://www.xiaohongshu.com/explore/66a1b2c3d4e5f60718293a4b').supported, false);
  assert.equal(detectBookmarkCollectionPage('https://example.org').supported, false);

  // Token-independent canonical dedup keys
  assert.equal(
    canonicalDedupKey('https://x.com/alice/status/18881234567890?s=20'),
    'x:18881234567890',
  );
  assert.equal(
    canonicalDedupKey('https://www.xiaohongshu.com/explore/66A1B2C3D4E5F60718293A4B?xsec_token=AAA'),
    canonicalDedupKey('https://www.xiaohongshu.com/discovery/item/66a1b2c3d4e5f60718293a4b?xsec_token=BBB'),
  );
});

// MARK: - 4. Xiaohongshu Initial State Parser

test('xhs-parser normalizes URLs keeping xsec_token, sanitizes JS undefined, and parses carousel + video notes', () => {
  const norm = normalizeXiaohongshuNoteUrl(
    '/user/profile/5f00112233445566778899aa/66a1b2c3d4e5f60718293a4b?xsec_token=TOK_99&xsec_source=pc_collect',
  );
  assert.equal(norm.noteId, '66a1b2c3d4e5f60718293a4b');
  assert.equal(norm.xsecToken, 'TOK_99');
  assert.equal(
    norm.url,
    'https://www.xiaohongshu.com/explore/66a1b2c3d4e5f60718293a4b?xsec_token=TOK_99&xsec_source=pc_collect',
  );

  assert.equal(sanitizeJSUndefined('{"a":undefined,"b":"keep undefined text","c":[undefined,1]}'), '{"a":null,"b":"keep undefined text","c":[null,1]}');
  assert.equal(parseChineseMetricCount('1.2万'), 12000);
  assert.equal(parseChineseMetricCount('3.5千'), 3500);
  assert.equal(parseChineseMetricCount('10万+'), 100000);
  assert.equal(parseChineseMetricCount('428'), 428);
  assert.equal(cleanXiaohongshuBody('色彩灵感 #插画[话题]# #配色[话题]#'), '色彩灵感 #插画 #配色');

  const sampleHtml = `
    <html><body><script>
      window.__INITIAL_STATE__={"note":{"noteDetailMap":{"66a1b2c3d4e5f60718293a4b":{"note":{
        "noteId":"66a1b2c3d4e5f60718293a4b",
        "type":"normal",
        "title":"极简工作室配色灵感",
        "desc":"整理了一组高雅的室内光影参考 #设计[话题]#",
        "time":1730000000000,
        "extra":undefined,
        "user":{"nickname":"林清","userId":"5f00112233445566778899aa","avatar":"http://sns-avatar-qc.xhscdn.com/avatar/a.jpg"},
        "interactInfo":{"likedCount":"1.2万","commentCount":"86","collectedCount":"3.4千"},
        "tagList":[{"name":"设计"},{"name":"配色"}],
        "imageList":[
          {"infoList":[{"imageScene":"WB_PRV","url":"http://sns-webpic-qc.xhscdn.com/p1_prv"},{"imageScene":"WB_DFT","url":"http://sns-webpic-qc.xhscdn.com/p1_dft"}]},
          {"urlDefault":"http://sns-webpic-qc.xhscdn.com/p2_dft"}
        ]
      }}}}}
    </script></body></html>
  `;

  assert.ok(extractInitialStateJSON(sampleHtml));
  const parsed = parseXiaohongshuNoteHtml(sampleHtml, norm.url);
  assert.equal(parsed.platform, 'xiaohongshu');
  assert.equal(parsed.authorName, '林清');
  assert.equal(parsed.authorAvatarURL, 'https://sns-avatar-qc.xhscdn.com/avatar/a.jpg');
  assert.equal(parsed.articleTitle, '极简工作室配色灵感');
  assert.equal(parsed.bodyText, '整理了一组高雅的室内光影参考 #设计');
  assert.equal(parsed.likeCount, 12000);
  assert.equal(parsed.replyCount, 86);
  assert.equal(parsed.repostCount, 3400);
  assert.equal(parsed.attachments.length, 2);
  assert.equal(parsed.attachments[0].url, 'https://sns-webpic-qc.xhscdn.com/p1_dft');
  assert.equal(parsed.attachments[0].thumbnailURL, 'https://sns-webpic-qc.xhscdn.com/p1_prv');
  assert.deepEqual(parsed.tags, ['小红书', '设计', '配色']);
});

// MARK: - 5. Storage, Image Filter & Desktop/Web Dual API Client

test('storage defaults to desktop bridge URL and builds folder hierarchy', async () => {
  const mem = new Map();
  const mockStorage = {
    async get(key) { return { [key]: mem.get(key) }; },
    async set(obj) { for (const [k, v] of Object.entries(obj)) mem.set(k, v); },
  };

  let cfg = await getConfig(mockStorage);
  assert.equal(cfg.serverUrl, DEFAULT_DESKTOP_SERVER_URL);
  assert.equal(isConfigured(cfg), false);

  cfg = await saveConfig(
    {
      serverUrl: 'http://127.0.0.1:41937/',
      apiToken: 'local_secret_token_1234',
      targetMode: 'folder',
      targetFolderId: 'F2',
      cachedFolders: [
        { id: 'F1', name: '灵感', parentID: null, sortOrder: 0, assetCount: 10 },
        { id: 'F2', name: '小红书收藏', parentID: 'F1', sortOrder: 0, assetCount: 5 },
      ],
    },
    mockStorage,
  );
  assert.equal(isConfigured(cfg), true);
  assert.equal(resolveActiveTarget(cfg).label, '小红书收藏');
  assert.equal(buildFolderOptions(cfg.cachedFolders)[1].label.includes('└ 小红书收藏'), true);
});

test('image-filter upgrades xhscdn http -> https and Twitter CDN sizes', () => {
  assert.equal(
    upgradeImageCandidateUrl('http://sns-webpic-qc.xhscdn.com/abc/1.webp'),
    'https://sns-webpic-qc.xhscdn.com/abc/1.webp',
  );
  assert.equal(
    upgradeImageCandidateUrl('https://pbs.twimg.com/media/Foo?format=jpg&name=small'),
    'https://pbs.twimg.com/media/Foo?format=jpg&name=large',
  );
  assert.equal(parseSrcsetBestUrl('/a.jpg 400w, /b.jpg 1600w', 'https://example.com'), 'https://example.com/b.jpg');
  const sorted = filterAndSortImages([
    { url: 'https://example.com/pixel.gif', width: 1, height: 1, source: 'img' },
    { url: 'https://example.com/big.jpg', width: 1200, height: 800, source: 'img' },
  ]);
  assert.equal(sorted.length, 1);
  assert.equal(isLargeImageCandidate(sorted[0]), true);
});

test('API client supports desktop probing, zero-config auto-pairing, folder creation, existing-sources dedup, and socialBookmark Web fallback', async () => {
  const probe = await probeLocalDesktop({
    ports: [41937],
    fetchImpl: async () => createJsonResponse({ ok: true, app: 'charkle-macos', name: 'Charkle macOS', port: 41937, autoPair: true }),
  });
  assert.equal(probe.found, true);
  assert.equal(probe.autoPair, true);
  assert.equal(probe.serverUrl, 'http://127.0.0.1:41937');

  const autoPaired = await autoPairLocalDesktop({
    ports: [41937],
    fetchImpl: async (url, init) => {
      if (url.endsWith('/api/v1/health')) {
        return createJsonResponse({ ok: true, app: 'charkle-macos', name: 'Charkle macOS', port: 41937, autoPair: true });
      }
      assert.equal(url, 'http://127.0.0.1:41937/api/v1/auth/local-pair');
      assert.equal(init.method, 'POST');
      assert.equal(init.headers['X-Charkle-Extension'], '1');
      return createJsonResponse({ ok: true, app: 'charkle-macos', name: 'Charkle macOS', port: 41937, serverUrl: 'http://127.0.0.1:41937', token: 'paired_tok_123' });
    },
  });
  assert.equal(autoPaired.paired, true);
  assert.equal(autoPaired.token, 'paired_tok_123');

  const disabledPair = await autoPairLocalDesktop({
    ports: [41937],
    fetchImpl: async () => createJsonResponse({ ok: true, app: 'charkle-macos', name: 'Charkle macOS', port: 41937, autoPair: false }),
  });
  assert.equal(disabledPair.paired, false);
  assert.equal(disabledPair.foundDesktop, true);
  assert.equal(disabledPair.reason, 'AUTO_PAIR_DISABLED');

  const offlinePair = await autoPairLocalDesktop({
    ports: [41937],
    fetchImpl: async () => {
      throw new Error('ECONNREFUSED');
    },
  });
  assert.equal(offlinePair.paired, false);
  assert.equal(offlinePair.foundDesktop, false);
  assert.equal(offlinePair.reason, 'DESKTOP_NOT_RUNNING');

  const cfg = { serverUrl: 'http://127.0.0.1:41937', apiToken: 'tok_demo' };

  const folderRes = await createOrReuseFolder(cfg, '小红书收藏', null, {
    fetchImpl: async (_url, init) => {
      const body = JSON.parse(init.body);
      assert.equal(body.name, '小红书收藏');
      assert.equal(body.reuseExisting, true);
      return createJsonResponse({ folder: { id: 'F-XHS', name: '小红书收藏' }, reused: false }, 201);
    },
  });
  assert.equal(folderRes.folder.id, 'F-XHS');

  // 404 on older Web server degrades gracefully
  const oldServerSources = await fetchExistingSources(cfg, {
    fetchImpl: async () => createJsonResponse({ error: 'Not found' }, 404),
  });
  assert.equal(oldServerSources.supported, false);
  assert.deepEqual(oldServerSources.canonicalKeys, []);

  // socialBookmark chunk succeeds natively on desktop bridge
  const nativeChunk = await ingestSocialBookmarksChunk(
    cfg,
    [{ platform: 'x', originalURL: 'https://x.com/a/status/1', authorName: 'A', authorHandle: 'a', bodyText: 'hi' }],
    'F-X',
    null,
    {
      fetchImpl: async (_url, init) => {
        const body = JSON.parse(init.body);
        assert.equal(body.inputs[0].type, 'socialBookmark');
        assert.equal(body.skipDuplicates, true);
        return createJsonResponse({ assets: [{ id: 'A1', title: '@a · hi' }], created: 1, skipped: 0 }, 201);
      },
    },
  );
  assert.equal(nativeChunk.created, 1);

  // socialBookmark chunk transparently falls back to webURL on older Web server returning 400
  let calls = 0;
  const fallbackChunk = await ingestSocialBookmarksChunk(
    cfg,
    [{ platform: 'x', originalURL: 'https://x.com/a/status/2', authorName: 'A', bodyText: 'fallback' }],
    null,
    null,
    {
      fetchImpl: async (_url, init) => {
        calls += 1;
        const body = JSON.parse(init.body);
        if (calls === 1) {
          assert.equal(body.inputs[0].type, 'socialBookmark');
          return createJsonResponse({ error: 'Unsupported type' }, 400);
        }
        assert.equal(body.inputs[0].type, 'webURL');
        return createJsonResponse({ assets: [{ id: 'A2', title: 'fallback' }] }, 201);
      },
    },
  );
  assert.equal(calls, 2);
  assert.equal(fallbackChunk.created, 1);

  // Sanity check standard client helpers
  assert.equal(normalizeServerUrl('127.0.0.1:41937/'), 'http://127.0.0.1:41937');
  assert.equal(isSameOriginUrl('http://127.0.0.1:41937', 'http://127.0.0.1:41937/x'), true);
  assert.equal(normalizeHexColor('#2a60e0'), '#2A60E0');
  assert.equal(isLightHex('#FFFFFF'), true);
  assert.equal(isDirectImageUrl('https://cdn.example.com/a.webp'), true);
  assert.equal(deriveImageFileName('https://cdn.example.com/a.jpg', '封面', 'image/webp'), '封面.webp');
  assert.equal(arrayBufferToBase64(new Uint8Array([1, 2, 3]).buffer), Buffer.from([1, 2, 3]).toString('base64'));

  const client = createCharkleClient(cfg, {
    fetchImpl: async () => createJsonResponse({ assets: [{ id: 'OK' }] }, 201),
  });
  await client.ingestUrl('https://example.org', 'T', 'N', null, null);
  await assert.rejects(() => ingestUrl(cfg, 'safari-extension://abc'), CharkleApiError);

  const batchSummary = await ingestImageUrlsBatch(
    cfg,
    [{ url: 'data:image/png;base64,AAAA', title: 'A' }],
    'https://example.org',
    null,
    null,
    { fetchImpl: async () => createJsonResponse({ assets: [{ id: 'I1' }] }, 201) },
  );
  assert.equal(batchSummary.succeeded, 1);

  await ingestImageUrl(cfg, 'data:image/png;base64,AAAA', 'https://example.org', 'A', null, null, {
    fetchImpl: async () => createJsonResponse({ assets: [{ id: 'I2' }] }, 201),
  });

  await testConnection(cfg, {
    fetchImpl: async (url) => {
      if (url.endsWith('/auth/status')) return createJsonResponse({ initialized: true, authenticated: true, user: { username: 'desktop' } });
      if (url.endsWith('/folders')) return createJsonResponse({ folders: [] });
      return createJsonResponse({ boards: [] });
    },
  });
});
