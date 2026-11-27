import assert from 'node:assert/strict';
import fs from 'node:fs';
import path from 'node:path';
import test from 'node:test';
import { fileURLToPath } from 'node:url';
import vm from 'node:vm';

import {
  arrayBufferToBase64,
  autoPairLocalDesktop,
  CharkleApiError,
  createCharkleClient,
  createOrReuseFolder,
  DEFAULT_DESKTOP_PROBE_PORTS,
  fetchExistingSources,
  ingestImageUrl,
  ingestImageUrlsBatch,
  ingestSocialBookmarksChunk,
  ingestSocialMediaChunk,
  ingestTextSnippet,
  ingestTweetMediaChunk,
  ingestUrl,
  probeLocalDesktop,
  testConnection,
} from '../lib/api.js';
import {
  buildCreatorRootFolderName,
  buildPostSubfolderName,
  detectBlueskyProfileUrl,
  detectInstagramProfileUrl,
  detectPixivCollectionUrl,
  detectThreadsProfileUrl,
  extractArtworkFromPixivPayloads,
  extractDouyinCollectionsFromPayload,
  extractDouyinPostsFromPayload,
  extractDouyinShareCopyUrl,
  extractPostsFromBlueskyFeedPayload,
  extractPostsFromInstagramPayload,
  extractPostsFromThreadsGraphQLPayload,
  filterCreatorMediaPost,
  normalizeDouyinPostUrl,
  parseDouyinMetricCount,
  pickBestDouyinImageUrl,
  pickBestDouyinVideoUrl,
} from '../lib/social-collectors.js';
import {
  buildAuthorRootFolderName,
  buildTweetSubfolderName,
  detectXAuthorProfileUrl,
  extractTweetsFromXGraphQLPayload,
  filterAuthorMediaTweet,
  pickBestTwitterVideoVariant,
  resolveTweetOrganizationFolderName,
  upgradeTwitterMediaUrl,
} from '../lib/x-author-media.js';
import {
  filterAndSortImages,
  isLargeImageCandidate,
  parseSrcsetBestUrl,
  upgradeImageCandidateUrl,
} from '../lib/image-filter.js';
import {
  buildFolderOptions,
  DEFAULT_CONFIG,
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
  isValidDouyinAwemeId,
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
    contentJs
      .replace(/\r\n/g, '\n')
      .includes("case 'START_BOOKMARK_IMPORT':\n        sendResponse(startBookmarkImport(msg.options || {}));"),
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

// MARK: - 6. Regression Tests: Port Range, Context Menus, Desktop Auto-Heal & XHS Likes Tags

test('probeLocalDesktop default port range matches LocalExtensionBridgeServer (41937..41946)', async () => {
  assert.deepEqual(DEFAULT_DESKTOP_PROBE_PORTS, [
    41937, 41938, 41939, 41940, 41941, 41942, 41943, 41944, 41945, 41946,
  ]);

  const probedPorts = [];
  const probe = await probeLocalDesktop({
    fetchImpl: async (url) => {
      const parsed = new URL(url);
      const port = Number(parsed.port);
      probedPorts.push(port);
      if (port === 41946) {
        return createJsonResponse({
          ok: true,
          app: 'charkle-macos',
          name: 'Charkle macOS',
          port: 41946,
          autoPair: true,
        });
      }
      throw new Error('ECONNREFUSED');
    },
  });

  assert.deepEqual(probedPorts, [
    41937, 41938, 41939, 41940, 41941, 41942, 41943, 41944, 41945, 41946,
  ]);
  assert.equal(probe.found, true);
  assert.equal(probe.port, 41946);
  assert.equal(probe.serverUrl, 'http://127.0.0.1:41946');
});

test('registerContextMenus supports both Promise-based browser.* and callback-based chrome.*', async () => {
  const bg = await import('../background.js?test=context-menus');

  // 1. Promise-only browser.contextMenus (throws TypeError if callback argument is passed)
  const promiseCreated = [];
  const promiseApi = {
    runtime: {},
    contextMenus: {
      removeAll(...args) {
        if (args.length > 0) {
          throw new TypeError('contextMenus.removeAll: Expected at most 0 arguments');
        }
        return Promise.resolve();
      },
      create(item, ...rest) {
        if (rest.length > 0) {
          throw new TypeError('unexpected callback in promise mode');
        }
        promiseCreated.push(item.id);
        return item.id;
      },
    },
  };
  await bg.registerContextMenus(promiseApi, { preferPromise: true });
  assert.equal(promiseCreated.length, 5);
  assert.deepEqual(promiseCreated, [
    'charkle-save-image',
    'charkle-save-link',
    'charkle-save-selection',
    'charkle-save-page',
    'charkle-capture-visible',
  ]);

  // 2. Callback-based chrome.contextMenus
  const callbackCreated = [];
  const callbackApi = {
    runtime: { lastError: null },
    contextMenus: {
      removeAll(cb) {
        assert.equal(typeof cb, 'function');
        cb();
      },
      create(item, cb) {
        assert.equal(typeof cb, 'function');
        callbackCreated.push(item.id);
        cb();
      },
    },
  };
  bg.registerContextMenus(callbackApi, { preferPromise: false });
  assert.equal(callbackCreated.length, 5);

  // 3. Fallback when callback-style call throws on a Promise-only removeAll()
  const fallbackCreated = [];
  const fallbackApi = {
    runtime: {},
    contextMenus: {
      removeAll(...args) {
        if (args.length > 0) {
          throw new TypeError('callback not allowed');
        }
        return Promise.resolve();
      },
      create(item) {
        fallbackCreated.push(item.id);
      },
    },
  };
  await bg.registerContextMenus(fallbackApi, { preferPromise: false });
  assert.equal(fallbackCreated.length, 5);
});

test('background auto-heals screenshot, page capture, all 5 context menus, and batch image save on stale desktop token/port', async () => {
  const prevBrowser = globalThis.browser;
  const prevChrome = globalThis.chrome;
  const prevFetch = globalThis.fetch;

  const mem = new Map();
  let captureCalls = 0;
  const toasts = [];
  const ingestCalls = [];
  let forceNonRetryableBatchError = false;

  const mockChrome = {
    storage: {
      local: {
        async get(key) {
          return { [key]: mem.get(key) };
        },
        async set(obj) {
          for (const [k, v] of Object.entries(obj)) mem.set(k, v);
        },
      },
    },
    action: {
      setBadgeText() {},
      setBadgeBackgroundColor() {},
      setBadgeTextColor() {},
    },
    tabs: {
      async sendMessage(_tabId, payload) {
        if (payload?.type === 'CHARKLE_TOAST') {
          toasts.push(payload);
        }
        return { ok: true };
      },
      async captureVisibleTab(_windowId, _opts) {
        captureCalls += 1;
        return 'data:image/png;base64,iVBORw0KGgo=';
      },
      async query() {
        return [{ id: 11, windowId: 7, url: 'https://example.org/post', title: 'Example Post' }];
      },
    },
    runtime: {
      lastError: null,
      getURL: (p) => `chrome-extension://test/${p}`,
      sendMessage: async () => ({ ok: true }),
      openOptionsPage() {},
      onInstalled: { addListener() {} },
      onStartup: { addListener() {} },
      onMessage: { addListener() {} },
    },
    contextMenus: {
      removeAll(cb) {
        cb?.();
      },
      create(_item, cb) {
        cb?.();
      },
      onClicked: { addListener() {} },
    },
    commands: {
      onCommand: { addListener() {} },
    },
    notifications: {
      create(_opts, cb) {
        cb?.();
      },
    },
  };

  const seedStaleDesktopConfig = async () => {
    await saveConfig(
      {
        connectionMode: 'desktop',
        serverUrl: 'http://127.0.0.1:41937',
        apiToken: 'stale_token',
        targetMode: 'inbox',
      },
      mockChrome.storage.local,
    );
  };

  globalThis.browser = undefined;
  globalThis.chrome = mockChrome;
  globalThis.fetch = async (url, init = {}) => {
    const parsed = new URL(url);
    const auth = init.headers?.Authorization || init.headers?.authorization || '';

    // External image URLs fail fetchImageBytes so ingestImageUrl falls back to ingestUrl on bridge
    if (parsed.hostname === 'cdn.example.org') {
      throw new Error('Blocked external fetch in test');
    }

    // Old port 41937 rejects with 401 (stale token) or refuses health probe
    if (parsed.port === '41937') {
      if (parsed.pathname === '/api/v1/health') {
        throw new Error('ECONNREFUSED');
      }
      if (forceNonRetryableBatchError && parsed.pathname === '/api/v1/assets/ingest') {
        return createJsonResponse({ error: '图片解码失败', code: 'DECODE_FAILED' }, 500);
      }
      return createJsonResponse({ error: '访问令牌已失效', code: 'UNAUTHORIZED' }, 401);
    }

    // Active desktop bridge moved to port 41945 with new token
    if (parsed.port === '41945') {
      if (parsed.pathname === '/api/v1/health') {
        return createJsonResponse({
          ok: true,
          app: 'charkle-macos',
          name: 'Charkle macOS',
          port: 41945,
          autoPair: true,
        });
      }
      if (parsed.pathname === '/api/v1/auth/local-pair') {
        return createJsonResponse({
          ok: true,
          app: 'charkle-macos',
          name: 'Charkle macOS',
          port: 41945,
          serverUrl: 'http://127.0.0.1:41945',
          token: 'healed_token_41945',
        });
      }
      if (auth !== 'Bearer healed_token_41945') {
        return createJsonResponse({ error: 'Unauthorized', code: 'UNAUTHORIZED' }, 401);
      }
      if (parsed.pathname === '/api/v1/auth/status') {
        return createJsonResponse({
          initialized: true,
          authenticated: true,
          user: { username: 'desktop', displayName: 'Charkle macOS' },
        });
      }
      if (parsed.pathname === '/api/v1/folders') {
        return createJsonResponse({ folders: [] });
      }
      if (parsed.pathname === '/api/v1/boards') {
        return createJsonResponse({ boards: [] });
      }
      if (parsed.pathname === '/api/v1/assets/ingest') {
        const body = JSON.parse(init.body);
        ingestCalls.push({ port: parsed.port, type: body.inputs?.[0]?.type });
        return createJsonResponse({ assets: [{ id: 'A-HEALED', title: 'Healed Asset' }] }, 201);
      }
    }

    throw new Error('ECONNREFUSED');
  };

  try {
    const bg = await import('../background.js?test=autoheal');
    const tab = { id: 11, windowId: 7, url: 'https://example.org/article', title: 'Design Notes' };

    // 1. CAPTURE_VISIBLE_TAB auto-heals and only captures screenshot once
    await seedStaleDesktopConfig();
    captureCalls = 0;
    const shotRes = await bg.handleMessage({ type: 'CAPTURE_VISIBLE_TAB', tab }, {});
    assert.equal(shotRes.ok, true);
    assert.equal(shotRes.assets[0].id, 'A-HEALED');
    assert.equal(captureCalls, 1, 'captureVisibleTab must not be called twice during auto-heal retry');

    // 2. captureCurrentPage (shortcut Alt+Shift+C) auto-heals
    await seedStaleDesktopConfig();
    toasts.length = 0;
    await bg.captureCurrentPage(tab);
    assert.ok(toasts.some((t) => t.variant === 'success'), 'captureCurrentPage should succeed after auto-heal');

    // 3. All 5 context menu handlers auto-heal
    const menuCases = [
      { menuItemId: 'charkle-save-image', srcUrl: 'https://cdn.example.org/pic.png', pageUrl: tab.url },
      { menuItemId: 'charkle-save-link', linkUrl: 'https://example.org/ref', pageUrl: tab.url },
      { menuItemId: 'charkle-save-selection', selectionText: '关键设计笔记', pageUrl: tab.url },
      { menuItemId: 'charkle-save-page', pageUrl: tab.url },
      { menuItemId: 'charkle-capture-visible', pageUrl: tab.url },
    ];
    for (const info of menuCases) {
      await seedStaleDesktopConfig();
      toasts.length = 0;
      await bg.handleContextMenuClick(info, tab);
      assert.ok(
        toasts.some((t) => t.variant === 'success'),
        `Context menu ${info.menuItemId} should auto-heal and show success toast`,
      );
      const updatedCfg = await getConfig(mockChrome.storage.local);
      assert.equal(updatedCfg.serverUrl, 'http://127.0.0.1:41945');
      assert.equal(updatedCfg.apiToken, 'healed_token_41945');
    }

    // 4. INGEST_IMAGES_BATCH rethrows retryable error when succeeded === 0, triggering auto-heal
    await seedStaleDesktopConfig();
    const healedBatch = await bg.handleMessage(
      {
        type: 'INGEST_IMAGES_BATCH',
        items: [{ url: 'data:image/png;base64,AAAA', title: 'Card 1' }],
        sourcePageUrl: tab.url,
      },
      {},
    );
    assert.equal(healedBatch.ok, true);
    assert.equal(healedBatch.succeeded, 1);

    // 5. INGEST_IMAGES_BATCH returns error message when succeeded === 0 on non-retryable error
    await seedStaleDesktopConfig();
    forceNonRetryableBatchError = true;
    const failedBatch = await bg.handleMessage(
      {
        type: 'INGEST_IMAGES_BATCH',
        items: [{ url: 'data:image/png;base64,BBBB', title: 'Bad Card' }],
        sourcePageUrl: tab.url,
      },
      {},
    );
    forceNonRetryableBatchError = false;
    assert.equal(failedBatch.ok, false);
    assert.equal(failedBatch.succeeded, 0);
    assert.equal(failedBatch.error, '图片解码失败');
    assert.equal(failedBatch.errors[0].status, 500);
    assert.equal(failedBatch.errors[0].code, 'DECODE_FAILED');
  } finally {
    globalThis.browser = prevBrowser;
    globalThis.chrome = prevChrome;
    globalThis.fetch = prevFetch;
  }
});

test('content.js enrichXhsNoteInBrowser preserves cardItem.tags on likes pages instead of hardcoding 小红书收藏', async () => {
  const contentSource = fs.readFileSync(path.join(EXT_ROOT, 'content.js'), 'utf8');
  assert.ok(
    contentSource.includes('Array.isArray(cardItem.tags)'),
    'enrichXhsNoteInBrowser should inspect cardItem.tags',
  );

  // Execute the real content.js enrichXhsNoteInBrowser function inside an isolated VM sandbox
  const instrumented = contentSource.replace(
    'initConfigSync();',
    'globalThis.__testExports = { enrichXhsNoteInBrowser }; initConfigSync();',
  );
  const noteId = '66a1b2c3d4e5f60718293a4b';
  const padding = ' '.repeat(600);
  const detailHtml = `<html><body>${padding}<script>window.__INITIAL_STATE__={"note":{"noteDetailMap":{"${noteId}":{"note":{"noteId":"${noteId}","type":"normal","title":"配色参考","desc":"室内光线 #设计[话题]#","user":{"nickname":"林清","userId":"u1"},"interactInfo":{"likedCount":"120"},"tagList":[{"name":"设计"}],"imageList":[{"urlDefault":"http://sns-webpic-qc.xhscdn.com/a.jpg"}]}}}}}</script></body></html>`;

  const noop = () => {};
  const win = {
    location: { href: 'https://www.xiaohongshu.com/user/profile/u1?tab=like', origin: 'https://www.xiaohongshu.com', hostname: 'www.xiaohongshu.com', pathname: '/user/profile/u1' },
    addEventListener: noop,
    history: { pushState: noop, replaceState: noop },
    setInterval: () => 0,
    setTimeout,
    clearTimeout,
  };
  win.top = win;
  const ctx = vm.createContext({
    window: win,
    document: {
      title: '小红书',
      addEventListener: noop,
      querySelector: () => null,
      querySelectorAll: () => [],
      documentElement: {},
      body: {},
    },
    Node: { TEXT_NODE: 3, ELEMENT_NODE: 1 },
    Element: class {},
    URL,
    Date,
    Set,
    Array,
    Math,
    JSON,
    Number,
    String,
    Boolean,
    Promise,
    console,
    setTimeout,
    clearTimeout,
    setInterval: () => 0,
    clearInterval: noop,
    chrome: {
      storage: { local: { get: async () => ({}) }, onChanged: { addListener: noop } },
      runtime: { onMessage: { addListener: noop }, sendMessage: async () => ({}), getURL: (p) => p },
    },
    fetch: async () => new Response(detailHtml, { status: 200, headers: { 'content-type': 'text/html' } }),
  });
  ctx.globalThis = ctx;
  vm.runInContext(instrumented, ctx);

  const likesCard = {
    noteId,
    originalURL: `https://www.xiaohongshu.com/explore/${noteId}?xsec_token=tok1`,
    dedupKey: `xhs:${noteId}`,
    tags: ['小红书', '小红书点赞'],
  };
  const enrichedLikes = await ctx.__testExports.enrichXhsNoteInBrowser(likesCard);
  assert.ok(enrichedLikes.tags.includes('小红书'));
  assert.ok(enrichedLikes.tags.includes('设计'));
  assert.ok(enrichedLikes.tags.includes('小红书点赞'), 'likes card must preserve 小红书点赞 tag');
  assert.equal(
    enrichedLikes.tags.includes('小红书收藏'),
    false,
    'likes card must NOT be mis-tagged with 小红书收藏',
  );

  const collectCard = {
    noteId,
    originalURL: `https://www.xiaohongshu.com/explore/${noteId}?xsec_token=tok2`,
    dedupKey: `xhs:${noteId}`,
    tags: ['小红书', '小红书收藏'],
  };
  const enrichedCollect = await ctx.__testExports.enrichXhsNoteInBrowser(collectCard);
  assert.ok(enrichedCollect.tags.includes('小红书收藏'));
  assert.equal(enrichedCollect.tags.includes('小红书点赞'), false);

  const fallbackCard = {
    noteId,
    originalURL: `https://www.xiaohongshu.com/explore/${noteId}?xsec_token=tok3`,
    dedupKey: `xhs:${noteId}`,
  };
  const enrichedFallback = await ctx.__testExports.enrichXhsNoteInBrowser(fallbackCard);
  assert.ok(enrichedFallback.tags.includes('小红书收藏'));
});

// MARK: - 10. X Author All-Media Collector (Profile Detection, GraphQL Parser, Tweet Organization & API)

test('detectXAuthorProfileUrl and detectBookmarkCollectionPage recognize X artist profiles and reject reserved routes', () => {
  const mediaPage = detectXAuthorProfileUrl('https://x.com/wlopwangling/media');
  assert.ok(mediaPage);
  assert.equal(mediaPage.handle, 'wlopwangling');
  assert.equal(mediaPage.isMediaTab, true);

  const rootPage = detectXAuthorProfileUrl('https://twitter.com/artist_01');
  assert.ok(rootPage);
  assert.equal(rootPage.handle, 'artist_01');
  assert.equal(rootPage.isMediaTab, false);

  const highlightsPage = detectXAuthorProfileUrl('https://x.com/artist_01/highlights');
  assert.ok(highlightsPage);
  assert.equal(highlightsPage.tab, 'highlights');

  // Reserved routes & single tweets must NOT be treated as author profiles
  assert.equal(detectXAuthorProfileUrl('https://x.com/home'), null);
  assert.equal(detectXAuthorProfileUrl('https://x.com/explore'), null);
  assert.equal(detectXAuthorProfileUrl('https://x.com/i/bookmarks'), null);
  assert.equal(detectXAuthorProfileUrl('https://x.com/artist_01/status/1899999999'), null);
  assert.equal(detectXAuthorProfileUrl('https://x.com/artist_01/likes'), null);

  // Unified collection page detector bridges author profiles cleanly
  const detected = detectBookmarkCollectionPage('https://x.com/artist_01/media');
  assert.equal(detected.supported, true);
  assert.equal(detected.platform, 'x');
  assert.equal(detected.pageKind, 'author_media');
  assert.equal(detected.authorHandle, 'artist_01');
  assert.equal(detected.suggestedFolderName, '@artist_01');
});

test('upgradeTwitterMediaUrl, pickBestTwitterVideoVariant, and extractTweetsFromXGraphQLPayload preserve all multi-photo origs and MP4s', () => {
  assert.equal(
    upgradeTwitterMediaUrl('https://pbs.twimg.com/media/AbCdEfG?format=png&name=360x360'),
    'https://pbs.twimg.com/media/AbCdEfG?format=png&name=orig',
  );
  assert.equal(
    upgradeTwitterMediaUrl('https://pbs.twimg.com/media/AbCdEfG.jpg:small'),
    'https://pbs.twimg.com/media/AbCdEfG?format=jpg&name=orig',
  );

  const bestMp4 = pickBestTwitterVideoVariant({
    variants: [
      { content_type: 'application/x-mpegURL', url: 'https://video.twimg.com/clip.m3u8' },
      { content_type: 'video/mp4', bitrate: 832000, url: 'https://video.twimg.com/clip-480p.mp4' },
      { content_type: 'video/mp4', bitrate: 2176000, url: 'https://video.twimg.com/clip-1080p.mp4' },
    ],
  });
  assert.equal(bestMp4, 'https://video.twimg.com/clip-1080p.mp4');

  // Realistic UserMedia GraphQL payload with 3-photo original tweet, 1 video tweet, 1 retweet, and 1 quoted tweet
  const graphqlPayload = {
    data: {
      user: {
        result: {
          timeline_v2: {
            timeline: {
              instructions: [
                {
                  entries: [
                    {
                      content: {
                        itemContent: {
                          tweet_results: {
                            result: {
                              __typename: 'TweetWithVisibilityResults',
                              tweet: {
                                rest_id: '1900000000000000001',
                                core: {
                                  user_results: {
                                    result: {
                                      legacy: { screen_name: 'pix_artist', name: '画师小星', profile_image_url_https: 'https://pbs.twimg.com/profile_images/1/a_normal.jpg' },
                                    },
                                  },
                                },
                                legacy: {
                                  id_str: '1900000000000000001',
                                  created_at: 'Fri Nov 20 12:30:00 +0000 2026',
                                  full_text: '角色立绘三视图 https://t.co/xyz123',
                                  favorite_count: 4200,
                                  extended_entities: {
                                    media: [
                                      { type: 'photo', media_url_https: 'https://pbs.twimg.com/media/IMG1.png', original_info: { width: 2400, height: 3200 } },
                                      { type: 'photo', media_url_https: 'https://pbs.twimg.com/media/IMG2.jpg', original_info: { width: 2400, height: 3200 } },
                                      { type: 'photo', media_url_https: 'https://pbs.twimg.com/media/IMG3.jpg', original_info: { width: 2400, height: 3200 } },
                                    ],
                                  },
                                },
                                quoted_status_result: {
                                  result: {
                                    rest_id: '9999999999999999999',
                                    legacy: {
                                      id_str: '9999999999999999999',
                                      full_text: 'Should be ignored',
                                      extended_entities: {
                                        media: [{ type: 'photo', media_url_https: 'https://pbs.twimg.com/media/QUOTED.jpg' }],
                                      },
                                    },
                                  },
                                },
                              },
                            },
                          },
                        },
                      },
                    },
                    {
                      content: {
                        itemContent: {
                          tweet_results: {
                            result: {
                              rest_id: '1900000000000000002',
                              core: { user_results: { result: { legacy: { screen_name: 'pix_artist', name: '画师小星' } } } },
                              legacy: {
                                id_str: '1900000000000000002',
                                created_at: 'Thu Nov 19 08:00:00 +0000 2026',
                                full_text: '绘画过程延时',
                                extended_entities: {
                                  media: [
                                    {
                                      type: 'video',
                                      media_url_https: 'https://pbs.twimg.com/ext_tw_video_thumb/1/img.jpg',
                                      video_info: {
                                        variants: [
                                          { content_type: 'video/mp4', bitrate: 500000, url: 'https://video.twimg.com/low.mp4' },
                                          { content_type: 'video/mp4', bitrate: 2000000, url: 'https://video.twimg.com/hd.mp4' },
                                        ],
                                      },
                                    },
                                  ],
                                },
                              },
                            },
                          },
                        },
                      },
                    },
                    {
                      content: {
                        itemContent: {
                          tweet_results: {
                            result: {
                              rest_id: '1900000000000000003',
                              core: { user_results: { result: { legacy: { screen_name: 'pix_artist', name: '画师小星' } } } },
                              legacy: {
                                id_str: '1900000000000000003',
                                retweeted_status_result: {
                                  result: {
                                    rest_id: '1888888888888888888',
                                    core: { user_results: { result: { legacy: { screen_name: 'other_artist', name: '别人' } } } },
                                    legacy: {
                                      id_str: '1888888888888888888',
                                      full_text: 'Retweeted art',
                                      extended_entities: {
                                        media: [{ type: 'photo', media_url_https: 'https://pbs.twimg.com/media/RT1.jpg' }],
                                      },
                                    },
                                  },
                                },
                              },
                            },
                          },
                        },
                      },
                    },
                  ],
                },
              ],
            },
          },
        },
      },
    },
  };

  const tweets = extractTweetsFromXGraphQLPayload(graphqlPayload);
  assert.equal(tweets.length, 3, 'Quoted tweet must be ignored while original/video/RT tweets are parsed');

  const multi = tweets.find((t) => t.tweetID === '1900000000000000001');
  assert.ok(multi);
  assert.equal(multi.media.length, 3);
  assert.equal(multi.media[0].url, 'https://pbs.twimg.com/media/IMG1?format=png&name=orig');
  assert.equal(multi.isRetweet, false);
  assert.equal(multi.authorAvatarURL, 'https://pbs.twimg.com/profile_images/1/a_400x400.jpg');

  const vid = tweets.find((t) => t.tweetID === '1900000000000000002');
  assert.ok(vid);
  assert.equal(vid.media[0].kind, 'video');
  assert.equal(vid.media[0].url, 'https://video.twimg.com/hd.mp4');

  const rt = tweets.find((t) => t.tweetID === '1888888888888888888');
  assert.ok(rt);
  assert.equal(rt.isRetweet, true);
  assert.equal(filterAuthorMediaTweet(rt, { targetHandle: 'pix_artist', skipRetweets: true }), null);
  assert.equal(filterAuthorMediaTweet(vid, { targetHandle: 'pix_artist', includeVideos: false }), null);

  // Deterministic folder naming & organization modes
  assert.equal(buildAuthorRootFolderName('pix_artist', '画师小星'), '画师小星 (@pix_artist)');
  assert.equal(buildAuthorRootFolderName('pix_artist', 'pix_artist'), '@pix_artist');

  const folderName = buildTweetSubfolderName(multi);
  assert.ok(folderName.includes('角色立绘三视图'));
  assert.ok(folderName.includes('[000001]'));
  assert.equal(folderName.includes('t.co'), false);

  assert.ok(resolveTweetOrganizationFolderName(multi, 'per_tweet'));
  assert.ok(resolveTweetOrganizationFolderName(multi, 'multi_only'));
  assert.equal(resolveTweetOrganizationFolderName(vid, 'multi_only'), null);
  assert.equal(resolveTweetOrganizationFolderName(multi, 'flat'), null);
});

test('ingestTweetMediaChunk posts tweetMedia batches and falls back cleanly on older servers returning HTTP 400', async () => {
  const calls = [];
  const modernFetch = async (url, init) => {
    calls.push({ url, method: init?.method, body: init?.body ? JSON.parse(init.body) : null });
    return createJsonResponse({
      assets: [{ id: 'a1', title: 'Art 1' }, { id: 'a2', title: 'Art 2' }],
      created: 2,
      tweetsImported: 1,
      skipped: 0,
      createdFolders: 1,
    }, 201);
  };

  const config = { serverUrl: 'http://127.0.0.1:41937', apiToken: 'tok-test' };
  const sampleTweet = {
    tweetID: '1900000000000000001',
    originalURL: 'https://x.com/pix_artist/status/1900000000000000001',
    authorHandle: 'pix_artist',
    authorName: '画师小星',
    subfolderName: '2026-11-20 · 立绘 [000001]',
    media: [
      { kind: 'photo', url: 'https://pbs.twimg.com/media/IMG1?format=png&name=orig' },
      { kind: 'photo', url: 'https://pbs.twimg.com/media/IMG2?format=jpg&name=orig' },
    ],
  };

  const res = await ingestTweetMediaChunk(config, [sampleTweet], 'folder-root-1', null, {
    fetchImpl: modernFetch,
  });
  assert.equal(res.created, 2);
  assert.equal(res.tweetsImported, 1);
  assert.equal(res.createdFolders, 1);
  assert.equal(calls[0].body.inputs[0].type, 'tweetMedia');
  assert.equal(calls[0].body.targetFolderID, 'folder-root-1');

  // Older server fallback: returns 400 for `tweetMedia`, then accepts POST /folders + imageData ingest
  const fallbackCalls = [];
  const legacyFetch = async (url, init) => {
    fallbackCalls.push(url);
    if (url.endsWith('/api/v1/assets/ingest')) {
      const parsed = JSON.parse(init.body);
      if (parsed.inputs[0].type === 'tweetMedia') {
        return createJsonResponse({ error: 'unsupported' }, 400);
      }
      return createJsonResponse({ assets: [{ id: 'legacy-1', title: 'Art' }] }, 201);
    }
    if (url.endsWith('/api/v1/folders')) {
      return createJsonResponse({ folder: { id: 'sub-1', name: '2026-11-20 · 立绘 [000001]' }, reused: false }, 201);
    }
    // Simulated CDN image fetch
    return new Response(new Uint8Array([137, 80, 78, 71]), {
      status: 200,
      headers: { 'content-type': 'image/png' },
    });
  };

  const fb = await ingestTweetMediaChunk(config, [sampleTweet], 'folder-root-1', null, {
    fetchImpl: legacyFetch,
  });
  assert.equal(fb.created, 2);
  assert.equal(fb.tweetsImported, 1);
  assert.equal(fb.createdFolders, 1);
  assert.ok(fallbackCalls.some((u) => u.endsWith('/api/v1/folders')));
});

// MARK: - 11. Multi-Platform Social Batch Collectors (Bluesky, Pixiv, Threads, Instagram) & Redesigned Popup Hygiene

test('multi-platform detectors & canonicalDedupKey cover Bluesky, Pixiv, Threads, and Instagram cleanly', () => {
  // Single-post special sources & dedup keys
  assert.equal(detectSpecialSource('https://www.pixiv.net/artworks/123456789').kind, 'pixiv');
  assert.equal(detectSpecialSource('https://www.pixiv.net/en/artworks/123456789').postID, '123456789');
  assert.equal(detectSpecialSource('https://www.pixiv.net/member_illust.php?mode=medium&illust_id=98765').postID, '98765');
  assert.equal(canonicalDedupKey('https://www.pixiv.net/en/artworks/123456789'), 'pixiv:123456789');

  assert.equal(detectSpecialSource('https://www.instagram.com/p/C9AbCdEf123/').kind, 'instagram');
  assert.equal(detectSpecialSource('https://www.instagram.com/artist_name/reel/D1XyZ_99/').postID, 'D1XyZ_99');
  assert.equal(canonicalDedupKey('https://www.instagram.com/p/C9AbCdEf123/?igsh=xyz'), 'ig:C9AbCdEf123');

  // Bluesky profiles & likes
  const bskyMedia = detectBlueskyProfileUrl('https://bsky.app/profile/artist.bsky.social/media');
  assert.ok(bskyMedia);
  assert.equal(bskyMedia.handle, 'artist.bsky.social');
  assert.equal(bskyMedia.pageKind, 'author_media');
  assert.equal(detectBlueskyProfileUrl('https://bsky.app/profile/artist.bsky.social/post/3k2abc'), null);
  assert.equal(detectBookmarkCollectionPage('https://bsky.app/profile/artist.bsky.social/likes').pageKind, 'likes');

  // Pixiv artist works, filtered manga, locale prefix & bookmarks
  const pixivAuthor = detectPixivCollectionUrl('https://www.pixiv.net/en/users/543210/illustrations');
  assert.ok(pixivAuthor);
  assert.equal(pixivAuthor.userId, '543210');
  assert.equal(pixivAuthor.workFilter, 'illusts');
  assert.equal(pixivAuthor.pageKind, 'author_media');

  const pixivBm = detectPixivCollectionUrl('https://www.pixiv.net/users/543210/bookmarks/artworks/风景?rest=hide');
  assert.ok(pixivBm);
  assert.equal(pixivBm.pageKind, 'bookmarks');
  assert.equal(pixivBm.bookmarkTag, '风景');
  assert.equal(pixivBm.rest, 'hide');
  assert.equal(detectBookmarkCollectionPage('https://www.pixiv.net/users/543210/artworks').platform, 'pixiv');

  // Threads profiles on both threads.net & threads.com + saved
  const threadsProfile = detectThreadsProfileUrl('https://www.threads.com/@painter_studio/media');
  assert.ok(threadsProfile);
  assert.equal(threadsProfile.handle, 'painter_studio');
  assert.equal(threadsProfile.pageKind, 'author_media');
  assert.equal(detectThreadsProfileUrl('https://www.threads.net/@painter_studio/post/ABC123'), null);
  assert.equal(detectBookmarkCollectionPage('https://www.threads.net/saved').pageKind, 'bookmarks');

  // Instagram profiles, reels & saved while rejecting reserved paths & single posts
  const igProfile = detectInstagramProfileUrl('https://www.instagram.com/studio.ink/');
  assert.ok(igProfile);
  assert.equal(igProfile.handle, 'studio.ink');
  assert.equal(igProfile.pageKind, 'author_media');
  assert.equal(detectInstagramProfileUrl('https://www.instagram.com/explore/'), null);
  assert.equal(detectInstagramProfileUrl('https://www.instagram.com/p/C9AbCdEf123/'), null);
  assert.equal(detectBookmarkCollectionPage('https://www.instagram.com/studio.ink/saved/all-posts/').pageKind, 'bookmarks');
});

test('multi-platform payload extractors normalize Bluesky, Pixiv multi-page, Threads, and Instagram media accurately', async () => {
  // 1. Bluesky ATProto feed with original 2-photo post + 1 repost
  const bskyPosts = extractPostsFromBlueskyFeedPayload({
    feed: [
      {
        post: {
          uri: 'at://did:plc:abc/app.bsky.feed.post/3l9abc123',
          author: { handle: 'mori.bsky.social', displayName: '森画师', avatar: 'https://cdn.bsky.app/img/avatar/a.jpg' },
          record: { text: '水彩练习', createdAt: '2026-11-22T09:15:00Z' },
          embed: {
            images: [
              { fullsize: 'https://cdn.bsky.app/img/feed_fullsize/1.jpeg', thumb: 'https://cdn.bsky.app/img/feed_thumbnail/1.jpeg' },
              { fullsize: 'https://cdn.bsky.app/img/feed_fullsize/2.jpeg', thumb: 'https://cdn.bsky.app/img/feed_thumbnail/2.jpeg' },
            ],
          },
        },
      },
      {
        reason: { $type: 'app.bsky.feed.defs#reasonRepost' },
        post: {
          uri: 'at://did:plc:xyz/app.bsky.feed.post/3l9rep999',
          author: { handle: 'other.bsky.social', displayName: 'Other' },
          record: { text: 'Reposted' },
          embed: { images: [{ fullsize: 'https://cdn.bsky.app/img/feed_fullsize/rt.jpeg' }] },
        },
      },
    ],
  });
  assert.equal(bskyPosts.length, 2);
  assert.equal(bskyPosts[0].media.length, 2);
  assert.equal(bskyPosts[0].dedupKey, 'bsky:mori.bsky.social:3l9abc123');
  assert.equal(filterCreatorMediaPost(bskyPosts[1], { targetHandle: 'mori.bsky.social', skipRetweets: true }), null);

  // 2. Pixiv multi-page artwork
  const pixivArt = extractArtworkFromPixivPayloads(
    {
      illustId: '12556677',
      illustTitle: '星夜水彩合集',
      illustComment: '第一张练习<br/>欢迎收藏',
      userId: '543210',
      userName: '青岚',
      createDate: '2026-11-20T12:00:00+09:00',
      tags: { tags: [{ tag: 'オリジナル' }, { tag: '水彩' }] },
    },
    [
      { urls: { original: 'https://i.pximg.net/img-original/img/p0.png', regular: 'https://i.pximg.net/img-master/p0.jpg' }, width: 2400, height: 3200 },
      { urls: { original: 'https://i.pximg.net/img-original/img/p1.png', regular: 'https://i.pximg.net/img-master/p1.jpg' }, width: 2400, height: 3200 },
    ],
  );
  assert.ok(pixivArt);
  assert.equal(pixivArt.platform, 'pixiv');
  assert.equal(pixivArt.dedupKey, 'pixiv:12556677');
  assert.equal(pixivArt.referer, 'https://www.pixiv.net/');
  assert.equal(pixivArt.media.length, 2);
  assert.equal(pixivArt.media[0].url, 'https://i.pximg.net/img-original/img/p0.png');
  assert.ok(buildPostSubfolderName(pixivArt).includes('星夜水彩合集'));
  assert.equal(buildCreatorRootFolderName('pixiv', '543210', '青岚'), '青岚 (Pixiv)');

  // 3. Threads GraphQL carousel picking highest-res candidate
  const threadsPosts = extractPostsFromThreadsGraphQLPayload({
    data: {
      mediaData: {
        edges: [
          {
            node: {
              thread_items: [
                {
                  post: {
                    code: 'C9ThrPost1',
                    taken_at: 1763625600,
                    user: { username: 'painter_studio', full_name: 'Painter Studio' },
                    caption: { text: '线稿过程' },
                    carousel_media: [
                      {
                        image_versions2: {
                          candidates: [
                            { url: 'https://scontent.cdninstagram.com/small.jpg', width: 320, height: 320 },
                            { url: 'https://scontent.cdninstagram.com/orig1.jpg', width: 1440, height: 1800 },
                          ],
                        },
                      },
                      {
                        video_versions: [
                          { url: 'https://scontent.cdninstagram.com/clip_hd.mp4', width: 1080, height: 1920 },
                        ],
                        image_versions2: { candidates: [{ url: 'https://scontent.cdninstagram.com/poster.jpg', width: 1080, height: 1920 }] },
                      },
                    ],
                  },
                },
              ],
            },
          },
        ],
      },
    },
  });
  assert.equal(threadsPosts.length, 1);
  assert.equal(threadsPosts[0].dedupKey, 'threads:C9ThrPost1');
  assert.equal(threadsPosts[0].media.length, 2);
  assert.equal(threadsPosts[0].media[0].url, 'https://scontent.cdninstagram.com/orig1.jpg');
  assert.equal(threadsPosts[0].media[1].kind, 'video');

  // 4. Instagram classic edge_owner_to_timeline_media sidecar + modern API
  const igPosts = extractPostsFromInstagramPayload({
    data: {
      user: {
        edge_owner_to_timeline_media: {
          edges: [
            {
              node: {
                shortcode: 'IgArt001',
                taken_at_timestamp: 1763625600,
                owner: { username: 'studio.ink' },
                edge_media_to_caption: { edges: [{ node: { text: 'Poster design series' } }] },
                edge_sidecar_to_children: {
                  edges: [
                    { node: { display_url: 'https://scontent.cdninstagram.com/slide1.jpg', dimensions: { width: 1080, height: 1350 } } },
                    { node: { display_url: 'https://scontent.cdninstagram.com/slide2.jpg', dimensions: { width: 1080, height: 1350 } } },
                  ],
                },
              },
            },
          ],
        },
      },
    },
  });
  assert.equal(igPosts.length, 1);
  assert.equal(igPosts[0].dedupKey, 'ig:IgArt001');
  assert.equal(igPosts[0].media.length, 2);

  // 5. ingestSocialMediaChunk posts `socialMedia` type cleanly
  const posted = [];
  const res = await ingestSocialMediaChunk(
    { serverUrl: 'http://127.0.0.1:41937', apiToken: 'tok-test' },
    [pixivArt],
    'folder-pixiv',
    null,
    {
      fetchImpl: async (_url, init) => {
        posted.push(JSON.parse(init.body));
        return createJsonResponse({ assets: [{ id: 'p1' }, { id: 'p2' }], created: 2, postsImported: 1, skipped: 0, createdFolders: 1 }, 201);
      },
    },
  );
  assert.equal(res.created, 2);
  assert.equal(res.postsImported, 1);
  assert.equal(posted[0].inputs[0].type, 'socialMedia');
  assert.equal(posted[0].inputs[0].platform, 'pixiv');
  assert.equal(posted[0].inputs[0].referer, 'https://www.pixiv.net/');
});

// MARK: - 12. Douyin (抖音) URL Detection, Parser, Passive Page-Bridge & Classic-Script Parity Tests

test('Douyin URL detection, short links, share copy, canonicalDedupKey, and 6 route shapes align 1:1 with Xiaohongshu', () => {
  // Valid / invalid aweme IDs
  assert.equal(isValidDouyinAwemeId('7412345678901234567'), true);
  assert.equal(isValidDouyinAwemeId('12345'), false);
  assert.equal(isValidDouyinAwemeId('abc7412345678901234'), false);

  // Single-post special sources (video, note, share, modal_id, v.douyin.com short link)
  const vSrc = detectSpecialSource('https://www.douyin.com/video/7412345678901234567');
  assert.equal(vSrc.kind, 'douyin');
  assert.equal(vSrc.postID, '7412345678901234567');
  assert.equal(vSrc.badgeText, '抖音作品');

  const nSrc = detectSpecialSource('https://www.douyin.com/note/7412345678901234568');
  assert.equal(nSrc.kind, 'douyin');
  assert.equal(nSrc.postID, '7412345678901234568');

  const modalSrc = detectSpecialSource(
    'https://www.douyin.com/user/self?showTab=favorite_collection&modal_id=7412345678901234567',
  );
  assert.equal(modalSrc.kind, 'douyin');
  assert.equal(modalSrc.postID, '7412345678901234567');

  const shareSrc = detectSpecialSource('https://www.iesdouyin.com/share/video/7412345678901234567/');
  assert.equal(shareSrc.kind, 'douyin');
  assert.equal(shareSrc.postID, '7412345678901234567');

  const shortSrc = detectSpecialSource('https://v.douyin.com/iR8xYz9A/');
  assert.equal(shortSrc.kind, 'douyin');
  assert.equal(shortSrc.hostname, 'v.douyin.com');

  // Share copy extraction
  assert.equal(
    extractDouyinShareCopyUrl('7.48 复制打开抖音，看看【摄影师】的作品 https://v.douyin.com/iR8xYz9A/ 复制此链接'),
    'https://v.douyin.com/iR8xYz9A/',
  );

  // Canonical deduplication key collapses video/note/share/modal_id identically
  assert.equal(
    canonicalDedupKey('https://www.douyin.com/video/7412345678901234567?from=collect'),
    'douyin:7412345678901234567',
  );
  assert.equal(
    canonicalDedupKey('https://www.douyin.com/note/7412345678901234567'),
    'douyin:7412345678901234567',
  );
  assert.equal(
    canonicalDedupKey('https://www.douyin.com/user/self?showTab=favorite_collection&modal_id=7412345678901234567'),
    'douyin:7412345678901234567',
  );
  assert.equal(
    canonicalDedupKey('https://www.iesdouyin.com/share/video/7412345678901234567/'),
    'douyin:7412345678901234567',
  );

  // URL normalizer
  const normNote = normalizeDouyinPostUrl('/note/7412345678901234568?enter_from=fav');
  assert.equal(normNote.kind, 'note');
  assert.equal(normNote.url, 'https://www.douyin.com/note/7412345678901234568');
  assert.equal(normNote.dedupKey, 'douyin:7412345678901234568');

  // 6 Douyin collection / profile / single-post route checks
  const dyCollect = detectBookmarkCollectionPage('https://www.douyin.com/user/self?showTab=favorite_collection');
  assert.equal(dyCollect.supported, true);
  assert.equal(dyCollect.isCollectionRoute, true);
  assert.equal(dyCollect.platform, 'douyin');
  assert.equal(dyCollect.pageKind, 'collect');
  assert.equal(dyCollect.suggestedFolderName, '抖音收藏');

  const dySubBoard = detectBookmarkCollectionPage(
    'https://www.douyin.com/user/self?showTab=favorite_collection&collects_id=7333444555666',
  );
  assert.equal(dySubBoard.supported, true);
  assert.equal(dySubBoard.pageKind, 'board');
  assert.equal(dySubBoard.collectionId, '7333444555666');

  const dyBoardPath = detectBookmarkCollectionPage('https://www.douyin.com/collection/7333444555666');
  assert.equal(dyBoardPath.supported, true);
  assert.equal(dyBoardPath.pageKind, 'board');

  const dyLikes = detectBookmarkCollectionPage('https://www.douyin.com/user/self?showTab=like');
  assert.equal(dyLikes.supported, true);
  assert.equal(dyLikes.pageKind, 'likes');
  assert.equal(dyLikes.suggestedFolderName, '抖音喜欢');

  const dyProfile = detectBookmarkCollectionPage('https://www.douyin.com/user/MS4wLjABAAAA_demo_sec_uid');
  assert.equal(dyProfile.supported, true);
  assert.equal(dyProfile.pageKind, 'profile');

  // Dedicated single video/note pages are NOT batch collection routes
  assert.equal(detectBookmarkCollectionPage('https://www.douyin.com/video/7412345678901234567').supported, false);
  assert.equal(detectBookmarkCollectionPage('https://www.douyin.com/note/7412345678901234568').supported, false);
});

test('douyin-parser normalizes short video (H.264, non-HEIC cover, duration), multi-image photo-note, and collects_list', () => {
  assert.equal(parseDouyinMetricCount('2.4万'), 24000);
  assert.equal(parseDouyinMetricCount('1.5亿'), 150000000);
  assert.equal(parseDouyinMetricCount('8.6k'), 8600);
  assert.equal(
    pickBestDouyinImageUrl([
      'http://p3-pc-sign.douyinpic.com/tos-cn-i-0813/a~tplv-dy-heic.heic',
      'http://p3-pc-sign.douyinpic.com/tos-cn-i-0813/a~tplv-dy-aweme-images.jpeg',
    ]),
    'https://p3-pc-sign.douyinpic.com/tos-cn-i-0813/a~tplv-dy-aweme-images.jpeg',
  );

  // Prefers H.264 watermark-free MP4 over H.265 / playwm
  const pickedMp4 = pickBestDouyinVideoUrl({
    bit_rate: [
      {
        gear_name: 'normal_1080_265',
        is_h265: 1,
        bit_rate: 4_500_000,
        play_addr: { width: 1080, height: 1920, url_list: ['https://v26-web.douyinvod.com/hevc_1080'] },
      },
      {
        gear_name: 'normal_1080_0',
        is_h265: 0,
        bit_rate: 3_200_000,
        play_addr: {
          width: 1080,
          height: 1920,
          url_list: [
            'https://www.douyin.com/aweme/v1/playwm/?video_id=wm',
            'https://v26-web.douyinvod.com/h264_1080_clean',
          ],
        },
      },
    ],
  });
  assert.equal(pickedMp4, 'https://v26-web.douyinvod.com/h264_1080_clean');

  const samplePayload = {
    aweme_list: [
      {
        aweme_id: '7412345678901234567',
        aweme_type: 0,
        desc: '室内建筑布光拆解 #布光 #建筑摄影',
        create_time: 1763625600,
        author: {
          nickname: '光影工作室',
          unique_id: 'MS4wLjABAAAA_hidden_sec',
          short_id: '886622',
          avatar_thumb: { url_list: ['http://p3-pc.douyinpic.com/avatar.jpeg'] },
        },
        statistics: { digg_count: 15800, comment_count: 342, share_count: 910, play_count: 120000 },
        text_extra: [{ hashtag_name: '布光' }, { hashtag_name: '建筑摄影' }],
        video: {
          duration: 15400,
          width: 1080,
          height: 1920,
          origin_cover: {
            url_list: [
              'https://p3-pc-sign.douyinpic.com/cover.heic',
              'https://p3-pc-sign.douyinpic.com/cover.jpeg',
            ],
          },
          bit_rate: [
            {
              is_h265: 0,
              bit_rate: 2_800_000,
              play_addr: { width: 1080, height: 1920, url_list: ['https://v26-web.douyinvod.com/v1_h264'] },
            },
          ],
        },
      },
      {
        aweme_id: '7412345678901234568',
        aweme_type: 68,
        item_title: '胶片调色预设分享',
        desc: '6 张实拍对比 #调色',
        create_time: 1763629200,
        author: { nickname: '森野胶片', unique_id: 'senye_film' },
        statistics: { digg_count: 4200, comment_count: 55, share_count: 180 },
        images: [
          { width: 1440, height: 1920, url_list: ['https://p3-pc-sign.douyinpic.com/img1.heic', 'https://p3-pc-sign.douyinpic.com/img1.webp'] },
          { width: 1440, height: 1920, url_list: ['https://p3-pc-sign.douyinpic.com/img2.jpeg'] },
        ],
      },
    ],
  };

  const posts = extractDouyinPostsFromPayload(samplePayload, { collectionId: '778899' });
  assert.equal(posts.length, 2);

  const vid = posts[0];
  assert.equal(vid.platform, 'douyin');
  assert.equal(vid.dedupKey, 'douyin:7412345678901234567');
  assert.equal(vid.originalURL, 'https://www.douyin.com/video/7412345678901234567');
  assert.equal(vid.authorName, '光影工作室');
  assert.equal(vid.authorHandle, '886622', 'Must never expose MS4wLjAB sec_uid as handle');
  assert.equal(vid.authorAvatarURL, 'https://p3-pc.douyinpic.com/avatar.jpeg');
  assert.equal(vid.hasVideo, true);
  assert.equal(vid.videoURL, 'https://v26-web.douyinvod.com/v1_h264');
  assert.equal(vid.durationSeconds, 15.4);
  assert.equal(vid.videoDurationSeconds, 15.4);
  assert.equal(vid.media.length, 1);
  assert.equal(vid.media[0].kind, 'video');
  assert.equal(vid.media[0].thumbnailURL, 'https://p3-pc-sign.douyinpic.com/cover.jpeg');
  assert.equal(vid.likeCount, 15800);
  assert.equal(vid.viewCount, 120000);
  assert.deepEqual(vid.tags, ['布光', '建筑摄影']);
  assert.equal(vid.collectionId, '778899');
  assert.equal(vid.referer, 'https://www.douyin.com/');

  const photoNote = posts[1];
  assert.equal(photoNote.originalURL, 'https://www.douyin.com/note/7412345678901234568');
  assert.equal(photoNote.hasVideo, false);
  assert.equal(photoNote.videoURL, null);
  assert.equal(photoNote.title, '胶片调色预设分享');
  assert.equal(photoNote.media.length, 2);
  assert.equal(photoNote.media[0].url, 'https://p3-pc-sign.douyinpic.com/img1.webp');
  assert.equal(photoNote.media[1].url, 'https://p3-pc-sign.douyinpic.com/img2.jpeg');

  // Collection directory extraction & creator root folder naming
  const cols = extractDouyinCollectionsFromPayload({
    collects_list: [
      { collects_id_str: '778899', collects_name: '运镜参考', total_number: 42 },
      { collects_id: 778900, collects_name: '调色灵感', total_number: 18 },
    ],
  });
  assert.deepEqual(cols, [
    { id: '778899', name: '运镜参考', totalCount: 42 },
    { id: '778900', name: '调色灵感', totalCount: 18 },
  ]);
  assert.equal(buildCreatorRootFolderName('douyin', 'MS4wLjABAAAA_sec', '光影工作室'), '光影工作室');
});

test('manifest, classic-script constraints, Safari url-detect isolation, and page-bridge Douyin passive interception hold end-to-end', async () => {
  const manifest = JSON.parse(fs.readFileSync(path.join(EXT_ROOT, 'manifest.json'), 'utf8'));
  const bridgeLoaderMatches = manifest.content_scripts[0].matches;
  const warMatches = manifest.web_accessible_resources[1].matches;
  for (const pat of ['https://douyin.com/*', 'https://www.douyin.com/*', 'https://m.douyin.com/*']) {
    assert.ok(bridgeLoaderMatches.includes(pat), `Missing Douyin content_scripts match: ${pat}`);
    assert.ok(warMatches.includes(pat), `Missing Douyin web_accessible_resources match: ${pat}`);
  }

  // Classic scripts must contain zero static ESM import/export declarations
  for (const classicFile of ['page-bridge.js', 'content.js', 'x-bridge-loader.js']) {
    const src = fs.readFileSync(path.join(EXT_ROOT, classicFile), 'utf8');
    assert.equal(/^\s*(?:import|export)\s/m.test(src), false, `${classicFile} must stay a classic script`);
  }

  // url-detect.js must NOT import from douyin-parser.js (preserves Safari 4-file classic SW bundler)
  const urlDetectSrc = fs.readFileSync(path.join(EXT_ROOT, 'lib/url-detect.js'), 'utf8');
  assert.equal(urlDetectSrc.includes('douyin-parser.js'), false);

  // Execute page-bridge.js in a sandboxed Douyin window context and verify passive fetch interception
  const bridgeSrc = fs.readFileSync(path.join(EXT_ROOT, 'page-bridge.js'), 'utf8');
  const postedMessages = [];
  const mockFetchResponses = new Map([
    [
      'https://www.douyin.com/aweme/v1/web/collects/list/?cursor=0&count=20',
      JSON.stringify({ collects_list: [{ collects_id_str: '778899', collects_name: '运镜参考', total_number: 12 }] }),
    ],
    [
      'https://www.douyin.com/aweme/v1/web/collects/video/list/?collects_id=778899&cursor=0',
      JSON.stringify({
        aweme_list: [
          {
            aweme_id: '7412345678901234569',
            aweme_type: 0,
            desc: '手持跟拍运镜 #运镜',
            create_time: 1763625600,
            author: { nickname: '镜头日记', unique_id: 'lens_diary' },
            statistics: { digg_count: 990 },
            video: {
              duration: 12000,
              origin_cover: { url_list: ['https://p3-pc-sign.douyinpic.com/c.jpeg'] },
              play_addr: { url_list: ['https://v26-web.douyinvod.com/lens_clean'] },
            },
          },
        ],
      }),
    ],
    [
      'https://www.douyin.com/aweme/v1/web/other/unrelated/',
      JSON.stringify({ aweme_list: [{ aweme_id: '7412345678909999999', desc: 'ignored' }] }),
    ],
  ]);

  const sandboxWindow = {
    location: { origin: 'https://www.douyin.com', hostname: 'www.douyin.com', href: 'https://www.douyin.com/user/self?showTab=favorite_collection' },
    postMessage(msg, origin) {
      postedMessages.push({ msg, origin });
    },
    fetch: async (url) => {
      const body = mockFetchResponses.get(url) || '{}';
      return {
        ok: true,
        clone() {
          return { text: async () => body };
        },
      };
    },
  };
  const sandbox = {
    window: sandboxWindow,
    URL,
    Date,
    Set,
    Map,
    Array,
    Object,
    String,
    Number,
    Boolean,
    Math,
    JSON,
    RegExp,
    XMLHttpRequest: undefined,
  };
  vm.runInNewContext(bridgeSrc, sandbox);

  await sandboxWindow.fetch('https://www.douyin.com/aweme/v1/web/collects/list/?cursor=0&count=20');
  await sandboxWindow.fetch('https://www.douyin.com/aweme/v1/web/collects/video/list/?collects_id=778899&cursor=0');
  await sandboxWindow.fetch('https://www.douyin.com/aweme/v1/web/other/unrelated/');
  await new Promise((r) => setTimeout(r, 20));

  const colMsg = postedMessages.find((m) => m.msg?.type === 'DOUYIN_COLLECTIONS');
  assert.ok(colMsg, 'page-bridge must emit DOUYIN_COLLECTIONS on /collects/list/');
  assert.equal(colMsg.msg.collections[0].name, '运镜参考');

  const postMsg = postedMessages.find((m) => m.msg?.type === 'GRAPHQL_POSTS');
  assert.ok(postMsg, 'page-bridge must emit GRAPHQL_POSTS on /collects/video/list/');
  assert.equal(postMsg.msg.platform, 'douyin');
  assert.equal(postMsg.msg.collectionId, '778899');
  assert.equal(postMsg.msg.sourceEndpoint, 'collects_video_list');
  assert.equal(postMsg.msg.posts.length, 1);
  assert.equal(postMsg.msg.posts[0].dedupKey, 'douyin:7412345678901234569');
  assert.equal(postMsg.msg.posts[0].durationSeconds, 12);
  assert.equal(postMsg.msg.posts[0].videoURL, 'https://v26-web.douyinvod.com/lens_clean');
  assert.equal(
    postedMessages.some((m) => m.msg?.posts?.some((p) => p.postID === '7412345678909999999')),
    false,
    'Non-target endpoints must not be emitted',
  );
});

test('Douyin storage config, content.js hooks, and background single-page capture work seamlessly', async () => {
  const mem = new Map();
  const mockStorage = {
    async get(key) { return { [key]: mem.get(key) }; },
    async set(obj) { for (const [k, v] of Object.entries(obj)) mem.set(k, v); },
  };

  let cfg = await getConfig(mockStorage);
  assert.equal(cfg.douyinProfileCollectMode, 'media');
  cfg = await saveConfig({ douyinProfileCollectMode: 'bookmarks' }, mockStorage);
  assert.equal(cfg.douyinProfileCollectMode, 'bookmarks');
  cfg = await saveConfig({ douyinProfileCollectMode: 'invalid_val' }, mockStorage);
  assert.equal(cfg.douyinProfileCollectMode, 'media');

  const contentJs = fs.readFileSync(path.join(EXT_ROOT, 'content.js'), 'utf8');
  for (const sym of [
    'isDouyinHost',
    'DOUYIN_COLLECTIONS',
    'ensureDouyinCollectTabActive',
    'harvestVisibleDouyinItems',
    'extractCurrentSingleDouyinPost',
    'hasDouyinAuthOrVerifyBlocker',
    'douyinProfileCollectMode',
  ]) {
    assert.ok(contentJs.includes(sym), `content.js missing Douyin symbol: ${sym}`);
  }

  // Verify background.js captureCurrentPage pulls GET_PAGE_CONTEXT socialBookmark on Douyin pages
  const prevBrowser = globalThis.browser;
  const prevChrome = globalThis.chrome;
  const prevFetch = globalThis.fetch;
  const postedPayloads = [];
  let requestedPageContext = false;

  const bgMem = new Map();
  const mockChrome = {
    storage: {
      local: {
        async get(key) { return { [key]: bgMem.get(key) }; },
        async set(obj) { for (const [k, v] of Object.entries(obj)) bgMem.set(k, v); },
      },
    },
    action: { setBadgeText() {}, setBadgeBackgroundColor() {}, setBadgeTextColor() {} },
    tabs: {
      async sendMessage(_tabId, payload) {
        if (payload?.type === 'GET_PAGE_CONTEXT') {
          requestedPageContext = true;
          return {
            ok: true,
            socialBookmark: {
              platform: 'douyin',
              postID: '7412345678901234567',
              videoID: '7412345678901234567',
              originalURL: 'https://www.douyin.com/video/7412345678901234567',
              dedupKey: 'douyin:7412345678901234567',
              authorName: '光影工作室',
              authorHandle: '886622',
              articleTitle: '室内建筑布光拆解',
              bodyText: '室内建筑布光拆解 #布光',
              hasVideo: true,
              videoURL: 'https://v26-web.douyinvod.com/v1_h264',
              durationSeconds: 15.4,
              videoDurationSeconds: 15.4,
              attachments: [
                {
                  kind: 'video',
                  url: 'https://v26-web.douyinvod.com/v1_h264',
                  thumbnailURL: 'https://p3-pc-sign.douyinpic.com/cover.jpeg',
                },
              ],
              tags: ['抖音', '布光'],
            },
          };
        }
        return { ok: true };
      },
      async query() { return []; },
    },
    runtime: {
      lastError: null,
      getURL: (p) => `chrome-extension://test/${p}`,
      sendMessage: async () => ({ ok: true }),
      openOptionsPage() {},
      onInstalled: { addListener() {} },
      onStartup: { addListener() {} },
      onMessage: { addListener() {} },
    },
    contextMenus: { removeAll(cb) { cb?.(); }, create(_i, cb) { cb?.(); }, onClicked: { addListener() {} } },
    commands: { onCommand: { addListener() {} } },
    notifications: { create(_o, cb) { cb?.(); } },
  };

  globalThis.browser = undefined;
  globalThis.chrome = mockChrome;
  globalThis.fetch = async (url, init = {}) => {
    if (String(url).endsWith('/api/v1/assets/ingest')) {
      postedPayloads.push(JSON.parse(init.body));
      return createJsonResponse({ assets: [{ id: 'DY-1', title: '室内建筑布光拆解' }], created: 1, skipped: 0 }, 201);
    }
    return createJsonResponse({ ok: true });
  };

  try {
    await saveConfig(
      { connectionMode: 'desktop', serverUrl: 'http://127.0.0.1:41937', apiToken: 'tok_dy', targetMode: 'inbox' },
      mockChrome.storage.local,
    );
    const bg = await import('../background.js?test=douyin-single');
    await bg.captureCurrentPage({
      id: 42,
      windowId: 1,
      url: 'https://www.douyin.com/video/7412345678901234567',
      title: '室内建筑布光拆解 - 抖音',
    });
    assert.equal(requestedPageContext, true);
    assert.equal(postedPayloads.length, 1);
    assert.equal(postedPayloads[0].inputs[0].type, 'socialBookmark');
    assert.equal(postedPayloads[0].inputs[0].platform, 'douyin');
    assert.equal(postedPayloads[0].inputs[0].videoDurationSeconds, 15.4);
  } finally {
    globalThis.browser = prevBrowser;
    globalThis.chrome = prevChrome;
    globalThis.fetch = prevFetch;
  }
});

test('Douyin live-page regression audit: hidden nocaptcha iframe, protocol-relative //note/, route-scroll-container, dual semi-tabs, and XHR POST/GET', async () => {
  // 1. Protocol-relative //www.douyin.com/note/<id> across url-detect.js & douyin-parser.js
  const protoRelNote = '//www.douyin.com/note/7697580146296325233';
  const relSrc = detectSpecialSource(protoRelNote);
  assert.equal(relSrc.kind, 'douyin');
  assert.equal(relSrc.postID, '7697580146296325233');
  assert.equal(canonicalDedupKey(protoRelNote), 'douyin:7697580146296325233');
  assert.equal(normalizeDouyinPostUrl(protoRelNote).url, 'https://www.douyin.com/note/7697580146296325233');
  assert.equal(
    detectBookmarkCollectionPage('https://www.douyin.com/user/self?showSubTab=video&showTab=favorite_collection')
      .pageKind,
    'collect',
  );

  // 2. XHR interception in page-bridge.js across all 4 live endpoints (POST + GET, text / json / arraybuffer)
  const bridgeSrc = fs.readFileSync(path.join(EXT_ROOT, 'page-bridge.js'), 'utf8');
  const xhrMessages = [];

  class MockXHR {
    constructor() {
      this._listeners = new Map();
      this.status = 200;
      this.responseType = '';
      this.responseText = '';
      this.response = null;
    }
    open(method, url) {
      this._method = method;
      this._url = url;
    }
    addEventListener(evt, fn) {
      if (!this._listeners.has(evt)) this._listeners.set(evt, []);
      this._listeners.get(evt).push(fn);
    }
    send(body) {
      this._body = body;
      const fns = this._listeners.get('load') || [];
      for (const fn of fns) fn();
    }
  }

  const sandboxWindow = {
    location: {
      origin: 'https://www.douyin.com',
      hostname: 'www.douyin.com',
      href: 'https://www.douyin.com/user/self?showSubTab=video&showTab=favorite_collection',
    },
    postMessage(msg, origin) {
      xhrMessages.push({ msg, origin });
    },
    fetch: undefined,
  };

  vm.runInNewContext(bridgeSrc, {
    window: sandboxWindow,
    XMLHttpRequest: MockXHR,
    URL,
    URLSearchParams,
    TextDecoder,
    Date,
    Set,
    Map,
    Array,
    Object,
    String,
    Number,
    Boolean,
    Math,
    JSON,
    RegExp,
  });

  // 2a. POST /aweme/v1/web/aweme/listcollection/ with responseType '' (text)
  const xhr1 = new MockXHR();
  xhr1.responseType = '';
  xhr1.responseText = JSON.stringify({
    aweme_list: [
      {
        aweme_id: '7706622133079146481',
        aweme_type: 0,
        desc: '收藏视频实测',
        author: { nickname: '创作者A' },
        video: {
          duration: 9500,
          origin_cover: { url_list: ['https://p3-pc-sign.douyinpic.com/v.jpeg'] },
          play_addr: { url_list: ['https://v26-web.douyinvod.com/v_live'] },
        },
      },
    ],
  });
  xhr1.open('POST', '/aweme/v1/web/aweme/listcollection/?device_platform=webapp');
  xhr1.send('count=20&cursor=0');

  // 2b. GET /aweme/v1/web/collects/list/ with responseType 'json'
  const xhr2 = new MockXHR();
  xhr2.responseType = 'json';
  xhr2.response = {
    collects_list: [{ collects_id: 7111222333, collects_id_str: '7111222333', collects_name: '分镜库', total_number: 7 }],
  };
  xhr2.open('GET', 'https://www.douyin.com/aweme/v1/web/collects/list/?cursor=0&count=20');
  xhr2.send();

  // 2c. GET /aweme/v1/web/collects/video/list/?collects_id=7111222333 with responseType 'text'
  const xhr3 = new MockXHR();
  xhr3.responseType = 'text';
  xhr3.responseText = JSON.stringify({
    aweme_list: [
      {
        aweme_id: '7697580146296325233',
        aweme_type: 68,
        desc: '实测图文作品',
        author: { nickname: '创作者B' },
        images: [{ url_list: ['https://p3-pc-sign.douyinpic.com/n1.webp'] }],
      },
    ],
  });
  xhr3.open('GET', 'https://www.douyin.com/aweme/v1/web/collects/video/list/?collects_id=7111222333&cursor=0');
  xhr3.send();

  // 2d. GET /aweme/v1/web/aweme/favorite/ with responseType 'arraybuffer'
  const xhr4 = new MockXHR();
  xhr4.responseType = 'arraybuffer';
  xhr4.response = new TextEncoder().encode(
    JSON.stringify({
      aweme_list: [
        {
          aweme_id: '7700000000000000001',
          aweme_type: 68,
          desc: '喜欢图文',
          author: { nickname: '创作者C' },
          images: [{ url_list: ['https://p3-pc-sign.douyinpic.com/fav1.jpeg'] }],
        },
      ],
    }),
  ).buffer;
  xhr4.open('GET', '/aweme/v1/web/aweme/favorite/?sec_user_id=MS4wLjAB_demo');
  xhr4.send();

  assert.equal(xhrMessages.filter((m) => m.msg?.type === 'DOUYIN_COLLECTIONS').length, 1);
  assert.equal(
    xhrMessages.find((m) => m.msg?.type === 'DOUYIN_COLLECTIONS').msg.collections[0].name,
    '分镜库',
  );
  const postEvents = xhrMessages.filter((m) => m.msg?.type === 'GRAPHQL_POSTS');
  assert.equal(postEvents.length, 3);
  assert.equal(postEvents[0].msg.sourceEndpoint, 'listcollection');
  assert.equal(postEvents[0].msg.posts[0].dedupKey, 'douyin:7706622133079146481');
  assert.equal(postEvents[1].msg.sourceEndpoint, 'collects_video_list');
  assert.equal(postEvents[1].msg.collectionId, '7111222333');
  assert.equal(postEvents[1].msg.posts[0].originalURL, 'https://www.douyin.com/note/7697580146296325233');
  assert.equal(postEvents[1].msg.posts[0].hasVideo, false);
  assert.equal(postEvents[2].msg.sourceEndpoint, 'favorite');
  assert.equal(postEvents[2].msg.posts[0].dedupKey, 'douyin:7700000000000000001');

  // 3. Execute real content.js helpers in isolated VM to verify nocaptcha, route-scroll-container, //note/, and dual semi-tabs
  const contentJs = fs.readFileSync(path.join(EXT_ROOT, 'content.js'), 'utf8');
  const instrumented = contentJs.replace(
    'initConfigSync();',
    'globalThis.__dyTestExports = { hasDouyinAuthOrVerifyBlocker, findActiveScrollTarget, normalizeDouyinHref, detectCurrentCollectionPage, getActiveDouyinPrimaryTabText, getActiveDouyinSubTabText }; initConfigSync();',
  );

  const hiddenNocaptcha = {
    id: 'nocaptcha-container',
    _style: { display: 'none', visibility: 'hidden', opacity: '0' },
    getBoundingClientRect: () => ({ width: 0, height: 0 }),
  };
  let visibleCaptcha = null;
  const routeScrollEl = {
    className: 'parent-route-container route-scroll-container',
    scrollHeight: 2389,
    clientHeight: 811,
    _style: { overflowY: 'auto' },
  };
  const primaryActiveTab = { textContent: '收藏' };
  const secondaryActiveTab = { textContent: '视频' };

  const mockDoc = {
    title: '我的主页 - 抖音',
    documentElement: { scrollHeight: 811, clientHeight: 811 },
    scrollingElement: { scrollHeight: 811, clientHeight: 811 },
    body: { scrollHeight: 811, clientHeight: 811, innerText: '' },
    addEventListener() {},
    querySelector(sel) {
      if (sel.includes('route-scroll-container')) return routeScrollEl;
      return null;
    },
    querySelectorAll(sel) {
      if (sel.includes('iframe[src*="captcha"]')) {
        return visibleCaptcha ? [hiddenNocaptcha, visibleCaptcha] : [hiddenNocaptcha];
      }
      if (sel.includes('.route-scroll-container')) return [routeScrollEl];
      if (sel.includes('[role="tab"][aria-selected="true"]')) {
        return [secondaryActiveTab, primaryActiveTab];
      }
      return [];
    },
  };
  const contentWin = {
    location: {
      origin: 'https://www.douyin.com',
      hostname: 'www.douyin.com',
      href: 'https://www.douyin.com/user/self?showSubTab=video&showTab=favorite_collection',
    },
    innerHeight: 811,
    addEventListener() {},
    getComputedStyle: (el) => el?._style || {},
  };
  contentWin.window = contentWin;
  contentWin.top = contentWin;

  const contentSandbox = {
    window: contentWin,
    document: mockDoc,
    chrome: { runtime: { onMessage: { addListener() {} } }, storage: { local: { get: async () => ({}) } } },
    URL,
    URLSearchParams,
    Date,
    Set,
    Map,
    Array,
    Object,
    String,
    Number,
    Boolean,
    Math,
    JSON,
    RegExp,
    Element: class {},
    setInterval: () => 0,
    setTimeout: () => 0,
    clearTimeout() {},
    requestAnimationFrame: () => 0,
  };
  contentSandbox.globalThis = contentSandbox;
  vm.runInNewContext(instrumented, contentSandbox);

  const dy = contentSandbox.__dyTestExports;
  assert.equal(dy.hasDouyinAuthOrVerifyBlocker(), false, '0x0 hidden nocaptcha-container must NOT trigger blocker');
  visibleCaptcha = {
    id: 'real-captcha',
    _style: { display: 'block', visibility: 'visible', opacity: '1' },
    getBoundingClientRect: () => ({ width: 340, height: 280 }),
  };
  assert.equal(dy.hasDouyinAuthOrVerifyBlocker(), true, 'Visible captcha iframe must pause batch sync');

  assert.equal(
    dy.normalizeDouyinHref('//www.douyin.com/note/7697580146296325233')?.url,
    'https://www.douyin.com/note/7697580146296325233',
  );
  assert.equal(
    dy.findActiveScrollTarget('douyin'),
    routeScrollEl,
    'findActiveScrollTarget must select div.parent-route-container.route-scroll-container',
  );
  assert.equal(dy.getActiveDouyinPrimaryTabText(), '收藏');
  assert.equal(dy.getActiveDouyinSubTabText(), '视频');
  const detectedPage = dy.detectCurrentCollectionPage(contentWin.location.href);
  assert.equal(detectedPage.platform, 'douyin');
  assert.equal(detectedPage.pageKind, 'collect');
  assert.equal(detectedPage.suggestedFolderName, '抖音收藏');
});

test('Douyin UX upgrades: storage defaults & validation for douyinContentFilter and douyinAutoClassify', async () => {
  assert.equal(DEFAULT_CONFIG.douyinContentFilter, 'all');
  assert.equal(DEFAULT_CONFIG.douyinAutoClassify, true);

  const mem = {};
  const mockStorage = {
    async get(key) {
      return { [key]: mem[key] };
    },
    async set(obj) {
      Object.assign(mem, obj);
    },
  };

  const initial = await getConfig(mockStorage);
  assert.equal(initial.douyinContentFilter, 'all');
  assert.equal(initial.douyinAutoClassify, true);

  const savedImageOff = await saveConfig(
    { douyinContentFilter: 'image', douyinAutoClassify: false },
    mockStorage,
  );
  assert.equal(savedImageOff.douyinContentFilter, 'image');
  assert.equal(savedImageOff.douyinAutoClassify, false);

  const savedInvalid = await saveConfig(
    { douyinContentFilter: 'invalid_mode', douyinAutoClassify: true },
    mockStorage,
  );
  assert.equal(savedInvalid.douyinContentFilter, 'all');
  assert.equal(savedInvalid.douyinAutoClassify, true);

  const savedVideo = await saveConfig({ douyinContentFilter: 'video' }, mockStorage);
  assert.equal(savedVideo.douyinContentFilter, 'video');
});

test('Douyin UX upgrades: background.js lazy auto-classification (tags, zero empty folders, cache hit, Inbox/Folder/Single/AuthorMedia)', async () => {
  const prevBrowser = globalThis.browser;
  const prevChrome = globalThis.chrome;
  const prevFetch = globalThis.fetch;

  const mem = {};
  const folderCalls = [];
  const ingestCalls = [];
  let folderSeq = 1;
  const createdFolderByKey = new Map();

  const mockChrome = {
    storage: {
      local: {
        async get(key) {
          return { [key]: mem[key] };
        },
        async set(obj) {
          Object.assign(mem, obj);
        },
      },
    },
    action: { setBadgeText() {}, setBadgeBackgroundColor() {} },
    tabs: {
      async sendMessage() {
        return { ok: true };
      },
      async query() {
        return [];
      },
    },
    runtime: {
      lastError: null,
      getURL: (p) => `chrome-extension://test/${p}`,
      sendMessage: async () => ({ ok: true }),
      openOptionsPage() {},
      onInstalled: { addListener() {} },
      onStartup: { addListener() {} },
      onMessage: { addListener() {} },
    },
    contextMenus: { removeAll(cb) { cb?.(); }, create(_i, cb) { cb?.(); }, onClicked: { addListener() {} } },
    commands: { onCommand: { addListener() {} } },
    notifications: { create(_o, cb) { cb?.(); } },
  };

  globalThis.browser = undefined;
  globalThis.chrome = mockChrome;
  globalThis.fetch = async (url, init = {}) => {
    const u = String(url);
    if (u.endsWith('/api/v1/folders') && init.method === 'POST') {
      const body = JSON.parse(init.body);
      folderCalls.push(body);
      const pid = body.parentID || body.parentId || null;
      const key = `${pid || '__root__'}::${body.name}`;
      let id = createdFolderByKey.get(key);
      const reused = Boolean(id);
      if (!id) {
        id = `F-${folderSeq++}-${body.name}`;
        createdFolderByKey.set(key, id);
      }
      return createJsonResponse({ folder: { id, name: body.name, parentId: pid }, reused }, 201);
    }
    if (u.endsWith('/api/v1/assets/ingest')) {
      const body = JSON.parse(init.body);
      ingestCalls.push(body);
      const inputs = Array.isArray(body.inputs) ? body.inputs : [];
      return createJsonResponse(
        { assets: inputs.map((inp, idx) => ({ id: `A-${idx}`, title: inp.articleTitle || inp.title || 'dy' })), created: inputs.length, skipped: 0 },
        201,
      );
    }
    if (u.includes('/api/v1/folders') || u.includes('/api/v1/boards') || u.includes('/api/v1/auth/me')) {
      return createJsonResponse({ folders: [], boards: [], user: { username: 'desktop', displayName: 'Charkle' } }, 200);
    }
    return createJsonResponse({ ok: true });
  };

  try {
    const bg = await import('../background.js?test=douyin-auto-classify');
    bg.clearDouyinFolderCache();

    // Case A: Batch folder target with ONLY video items -> lazily creates ONLY `视频`, NEVER `图文`
    await saveConfig(
      {
        connectionMode: 'desktop',
        serverUrl: 'http://127.0.0.1:41937',
        apiToken: 'tok_dy_ac',
        targetMode: 'folder',
        targetFolderId: 'F-ROOT',
        targetFolderName: '摄影灵感',
        douyinAutoClassify: true,
      },
      mockChrome.storage.local,
    );

    const resA = await bg.handleMessage({
      type: 'INGEST_SOCIAL_BOOKMARKS_CHUNK',
      bookmarks: [
        {
          platform: 'douyin',
          postID: '7410000000000000001',
          originalURL: 'https://www.douyin.com/video/7410000000000000001',
          hasVideo: true,
          articleTitle: '布光视频1',
          tags: ['抖音'],
        },
        {
          platform: 'douyin',
          postID: '7410000000000000002',
          originalURL: 'https://www.douyin.com/video/7410000000000000002',
          hasVideo: true,
          articleTitle: '布光视频2',
          tags: ['抖音', '抖音视频'],
        },
      ],
      skipDuplicates: true,
      autoClassify: true,
      isFinalChunk: true,
    });
    assert.equal(resA.ok, true);
    assert.equal(folderCalls.length, 1, 'Only 视频 subfolder must be created when chunk has only videos');
    assert.deepEqual(folderCalls[0], { name: '视频', parentID: 'F-ROOT', reuseExisting: true });
    assert.equal(ingestCalls.length, 1);
    assert.equal(ingestCalls[0].targetFolderID, createdFolderByKey.get('F-ROOT::视频'));
    assert.ok(ingestCalls[0].inputs[0].tags.includes('抖音视频'));
    assert.equal(ingestCalls[0].inputs[0].tags.includes('抖音图文'), false);
    assert.equal(
      ingestCalls[0].inputs[1].tags.filter((t) => t === '抖音视频').length,
      1,
      '抖音视频 tag must be deduplicated',
    );

    // Case B: Batch Inbox target with mixed video + photo-note -> lazily creates root `运镜参考` + `视频` + `图文`, cached on chunk 2
    folderCalls.length = 0;
    ingestCalls.length = 0;
    await saveConfig(
      {
        targetMode: 'inbox',
        targetFolderId: null,
        targetFolderName: '',
        targetBoardId: null,
        targetBoardName: '',
        douyinAutoClassify: true,
      },
      mockChrome.storage.local,
    );

    const mixedChunk = [
      {
        platform: 'douyin',
        postID: '7410000000000000010',
        originalURL: 'https://www.douyin.com/video/7410000000000000010',
        hasVideo: true,
        articleTitle: '运镜教程',
        tags: ['抖音'],
      },
      {
        platform: 'douyin',
        postID: '7410000000000000011',
        originalURL: 'https://www.douyin.com/note/7410000000000000011',
        hasVideo: false,
        articleTitle: '构图参考图集',
        tags: ['抖音'],
      },
    ];
    const resB1 = await bg.handleMessage({
      type: 'INGEST_SOCIAL_BOOKMARKS_CHUNK',
      bookmarks: mixedChunk,
      autoClassify: true,
      suggestedFolderName: '运镜参考',
      isFinalChunk: false,
    });
    assert.equal(resB1.ok, true);
    assert.equal(resB1.targetLabel, '运镜参考');
    assert.equal(folderCalls.length, 3, 'Inbox batch should create root + 视频 + 图文');
    assert.equal(folderCalls[0].name, '运镜参考');
    assert.equal(folderCalls[0].parentID, null);
    const sugRootId = createdFolderByKey.get('__root__::运镜参考');
    assert.equal(folderCalls[1].parentID, sugRootId);
    assert.equal(folderCalls[1].name, '视频');
    assert.equal(folderCalls[2].parentID, sugRootId);
    assert.equal(folderCalls[2].name, '图文');
    assert.equal(ingestCalls.length, 2);
    assert.equal(ingestCalls[0].targetFolderID, createdFolderByKey.get(`${sugRootId}::视频`));
    assert.ok(ingestCalls[0].inputs[0].tags.includes('抖音视频'));
    assert.equal(ingestCalls[1].targetFolderID, createdFolderByKey.get(`${sugRootId}::图文`));
    assert.ok(ingestCalls[1].inputs[0].tags.includes('抖音图文'));

    // Second chunk hits douyinFolderCache -> ZERO additional folder creation requests
    folderCalls.length = 0;
    const resB2 = await bg.handleMessage({
      type: 'INGEST_SOCIAL_BOOKMARKS_CHUNK',
      bookmarks: mixedChunk,
      autoClassify: true,
      suggestedFolderName: '运镜参考',
      isFinalChunk: true,
    });
    assert.equal(resB2.ok, true);
    assert.equal(folderCalls.length, 0, 'Cached Douyin folders must prevent redundant POST /api/v1/folders');

    // Case C: Single-page INGEST_URL -> Inbox creates ZERO folders (still attaches tag); selected folder routes to 视频/图文 without double nesting
    folderCalls.length = 0;
    ingestCalls.length = 0;
    const resCInbox = await bg.handleMessage({
      type: 'INGEST_URL',
      url: 'https://www.douyin.com/note/7410000000000000020',
      socialBookmark: {
        platform: 'douyin',
        postID: '7410000000000000020',
        originalURL: 'https://www.douyin.com/note/7410000000000000020',
        hasVideo: false,
        articleTitle: '单页图文收藏',
        tags: ['抖音'],
      },
    });
    assert.equal(resCInbox.ok, true);
    assert.equal(folderCalls.length, 0, 'Single-page clip to Inbox must NOT create folders');
    assert.equal(ingestCalls[0].targetFolderID, null);
    assert.ok(ingestCalls[0].inputs[0].tags.includes('抖音图文'));

    // Selected folder routes single photo-note into `F-ROOT/图文`
    folderCalls.length = 0;
    ingestCalls.length = 0;
    await saveConfig(
      { targetMode: 'folder', targetFolderId: 'F-ROOT', targetFolderName: '摄影灵感' },
      mockChrome.storage.local,
    );
    const resCFolder = await bg.handleMessage({
      type: 'INGEST_URL',
      url: 'https://www.douyin.com/note/7410000000000000021',
      socialBookmark: {
        platform: 'douyin',
        postID: '7410000000000000021',
        originalURL: 'https://www.douyin.com/note/7410000000000000021',
        hasVideo: false,
        articleTitle: '单页图文到目录',
        tags: ['抖音'],
      },
    });
    assert.equal(resCFolder.ok, true);
    assert.equal(folderCalls.length, 1);
    assert.deepEqual(folderCalls[0], { name: '图文', parentID: 'F-ROOT', reuseExisting: true });
    assert.equal(ingestCalls[0].targetFolderID, createdFolderByKey.get('F-ROOT::图文'));

    // Already targeting a folder named `视频` must NOT create nested `视频/视频`
    folderCalls.length = 0;
    ingestCalls.length = 0;
    const vidFolderId = createdFolderByKey.get('F-ROOT::视频');
    await saveConfig(
      { targetMode: 'folder', targetFolderId: vidFolderId, targetFolderName: '视频' },
      mockChrome.storage.local,
    );
    await bg.handleMessage({
      type: 'INGEST_URL',
      url: 'https://www.douyin.com/video/7410000000000000022',
      socialBookmark: {
        platform: 'douyin',
        postID: '7410000000000000022',
        originalURL: 'https://www.douyin.com/video/7410000000000000022',
        hasVideo: true,
        articleTitle: '避免嵌套',
        tags: ['抖音'],
      },
    });
    assert.equal(folderCalls.length, 0, 'Must not double-nest 视频/视频');
    assert.equal(ingestCalls[0].targetFolderID, vidFolderId);

    // Case D: INGEST_SOCIAL_MEDIA_CHUNK (author_media) splits under <作者名>/视频 & <作者名>/图文, and respects autoClassify: false
    folderCalls.length = 0;
    ingestCalls.length = 0;
    const resDOn = await bg.handleMessage({
      type: 'INGEST_SOCIAL_MEDIA_CHUNK',
      targetFolderId: 'F-AUTHOR-1',
      targetBoardId: null,
      targetLabel: '某创作者',
      autoClassify: true,
      posts: [
        {
          platform: 'douyin',
          postID: '7410000000000000031',
          originalURL: 'https://www.douyin.com/video/7410000000000000031',
          hasVideo: true,
          media: [{ kind: 'video', url: 'https://v26-web.douyinvod.com/v1.mp4' }],
          tags: ['抖音'],
        },
        {
          platform: 'douyin',
          postID: '7410000000000000032',
          originalURL: 'https://www.douyin.com/note/7410000000000000032',
          hasVideo: false,
          media: [{ kind: 'photo', url: 'https://p3-pc-sign.douyinpic.com/p1.jpeg' }],
          tags: ['抖音'],
        },
      ],
      isFinalChunk: true,
    });
    assert.equal(resDOn.ok, true);
    assert.equal(folderCalls.length, 2);
    assert.deepEqual(folderCalls[0], { name: '视频', parentID: 'F-AUTHOR-1', reuseExisting: true });
    assert.deepEqual(folderCalls[1], { name: '图文', parentID: 'F-AUTHOR-1', reuseExisting: true });
    assert.equal(ingestCalls[0].targetFolderID, createdFolderByKey.get('F-AUTHOR-1::视频'));
    assert.ok(ingestCalls[0].inputs[0].tags.includes('抖音视频'));
    assert.equal(ingestCalls[1].targetFolderID, createdFolderByKey.get('F-AUTHOR-1::图文'));
    assert.ok(ingestCalls[1].inputs[0].tags.includes('抖音图文'));

    // autoClassify: false skips subfolder creation while still attaching 抖音视频/抖音图文 tags
    folderCalls.length = 0;
    ingestCalls.length = 0;
    const resDOff = await bg.handleMessage({
      type: 'INGEST_SOCIAL_MEDIA_CHUNK',
      targetFolderId: 'F-AUTHOR-OFF',
      targetBoardId: null,
      targetLabel: '不分类作者',
      autoClassify: false,
      posts: [
        {
          platform: 'douyin',
          postID: '7410000000000000033',
          originalURL: 'https://www.douyin.com/note/7410000000000000033',
          hasVideo: false,
          media: [{ kind: 'photo', url: 'https://p3-pc-sign.douyinpic.com/p2.jpeg' }],
          tags: ['抖音'],
        },
      ],
      isFinalChunk: true,
    });
    assert.equal(resDOff.ok, true);
    assert.equal(folderCalls.length, 0, 'autoClassify: false must NOT create any subfolder');
    assert.equal(ingestCalls[0].targetFolderID, 'F-AUTHOR-OFF');
    assert.ok(ingestCalls[0].inputs[0].tags.includes('抖音图文'));
  } finally {
    globalThis.browser = prevBrowser;
    globalThis.chrome = prevChrome;
    globalThis.fetch = prevFetch;
  }
});

test('Douyin UX upgrades: content.js filter never pollutes knownStreak, picker scans & scrolls route-scroll-container, and popup UI contracts hold', async () => {
  const contentJs = fs.readFileSync(path.join(EXT_ROOT, 'content.js'), 'utf8');
  const instrumented = contentJs.replace(
    'initConfigSync();',
    'globalThis.__dyUxExports = { matchesDouyinContentFilter, ensureDouyinTypeTagList, capturedSocialPostsByKey, startBookmarkImport, snapshotBatchJob, scanDouyinPickerItems }; initConfigSync();',
  );

  let registeredOnMessage = null;
  const sentMessages = [];
  const routeScrollEl = {
    className: 'parent-route-container route-scroll-container',
    scrollTop: 0,
    scrollHeight: 2600,
    clientHeight: 800,
    _style: { overflowY: 'auto' },
    scrollBy(optsOrX, y) {
      const delta = typeof optsOrX === 'object' ? Number(optsOrX.top || 0) : Number(y || 0);
      this.scrollTop = Math.min(this.scrollHeight - this.clientHeight, this.scrollTop + delta);
    },
  };

  // Pre-seed 10 already-known videos + 2 unseen photo-notes to prove `仅图文` NEVER trips knownStreak >= 8
  const knownVideoKeys = Array.from({ length: 10 }, (_, idx) => `douyin:74200000000000000${String(idx).padStart(2, '0')}`);

  const makeMockEl = () => ({
    className: '',
    dataset: {},
    style: {},
    hidden: false,
    innerHTML: '',
    textContent: '',
    setAttribute() {},
    getAttribute() {
      return null;
    },
    addEventListener() {},
    append() {},
    appendChild() {},
    remove() {},
    classList: { add() {}, remove() {}, toggle() {}, contains: () => false },
    attachShadow() {
      return { append() {}, appendChild() {}, querySelector: () => makeMockEl() };
    },
    querySelector: () => makeMockEl(),
    querySelectorAll: () => [],
  });

  const mockDoc = {
    title: '我的主页 - 抖音',
    documentElement: { scrollHeight: 800, clientHeight: 800, appendChild() {} },
    scrollingElement: { scrollHeight: 800, clientHeight: 800 },
    body: { scrollHeight: 800, clientHeight: 800, innerText: '', appendChild() {} },
    createElement: () => makeMockEl(),
    addEventListener() {},
    querySelector(sel) {
      if (sel.includes('route-scroll-container')) return routeScrollEl;
      return null;
    },
    querySelectorAll(sel) {
      if (sel.includes('.route-scroll-container')) return [routeScrollEl];
      return [];
    },
  };

  const contentWin = {
    location: {
      origin: 'https://www.douyin.com',
      hostname: 'www.douyin.com',
      href: 'https://www.douyin.com/user/self?showTab=favorite_collection',
      search: '?showTab=favorite_collection',
      pathname: '/user/self',
    },
    innerHeight: 800,
    addEventListener() {},
    getComputedStyle: (el) => el?._style || {},
  };
  contentWin.window = contentWin;
  contentWin.top = contentWin;

  class FastMutationObserver {
    observe() {}
    disconnect() {}
  }

  const contentSandbox = {
    window: contentWin,
    document: mockDoc,
    MutationObserver: FastMutationObserver,
    Element: class {},
    chrome: {
      storage: { local: { get: async () => ({}) }, onChanged: { addListener() {} } },
      runtime: {
        getURL: (p) => p,
        onMessage: {
          addListener(fn) {
            registeredOnMessage = fn;
          },
        },
        async sendMessage(msg) {
          sentMessages.push(msg);
          if (msg.type === 'FETCH_EXISTING_SOURCES') {
            return { ok: true, canonicalKeys: knownVideoKeys, mediaCanonicalKeys: [], sources: [] };
          }
          if (msg.type === 'INGEST_SOCIAL_BOOKMARKS_CHUNK') {
            return {
              ok: true,
              created: msg.bookmarks.length,
              skipped: 0,
              assets: msg.bookmarks.map((b, i) => ({ id: `B-${i}`, title: b.articleTitle || 'dy' })),
            };
          }
          return { ok: true };
        },
      },
    },
    URL,
    URLSearchParams,
    Date,
    Set,
    Map,
    Array,
    Object,
    String,
    Number,
    Boolean,
    Math,
    JSON,
    RegExp,
    Promise,
    // Fast immediate timer so scroll loop finishes in milliseconds inside the unit test
    setTimeout: (fn) => globalThis.setTimeout(fn, 0),
    clearTimeout: (id) => globalThis.clearTimeout(id),
    setInterval: () => 0,
    clearInterval() {},
    requestAnimationFrame: (fn) => {
      fn();
      return 0;
    },
  };
  contentSandbox.globalThis = contentSandbox;
  vm.runInNewContext(instrumented, contentSandbox);

  const ux = contentSandbox.__dyUxExports;
  assert.equal(ux.matchesDouyinContentFilter({ hasVideo: true }, 'all'), true);
  assert.equal(ux.matchesDouyinContentFilter({ hasVideo: true }, 'video'), true);
  assert.equal(ux.matchesDouyinContentFilter({ hasVideo: true }, 'image'), false);
  assert.equal(ux.matchesDouyinContentFilter({ hasVideo: false }, 'image'), true);
  assert.equal(ux.matchesDouyinContentFilter({ hasVideo: false }, 'video'), false);

  // Populate 10 already-known videos followed by 2 unseen photo-notes
  for (let i = 0; i < 10; i++) {
    const id = `74200000000000000${String(i).padStart(2, '0')}`;
    ux.capturedSocialPostsByKey.set(`douyin:${id}`, {
      platform: 'douyin',
      postID: id,
      dedupKey: `douyin:${id}`,
      originalURL: `https://www.douyin.com/video/${id}`,
      title: `已导入视频 ${i}`,
      bodyText: `已导入视频 ${i}`,
      authorName: '视频作者',
      hasVideo: true,
      durationSeconds: 18 + i,
      coverUrl: `https://p3-pc-sign.douyinpic.com/v${i}.jpeg`,
      media: [{ kind: 'video', url: `https://v26-web.douyinvod.com/v${i}.mp4`, thumbnailURL: `https://p3-pc-sign.douyinpic.com/v${i}.jpeg` }],
    });
  }
  for (let j = 0; j < 2; j++) {
    const id = `743000000000000000${j}`;
    ux.capturedSocialPostsByKey.set(`douyin:${id}`, {
      platform: 'douyin',
      postID: id,
      dedupKey: `douyin:${id}`,
      originalURL: `https://www.douyin.com/note/${id}`,
      title: `待导入图文 ${j}`,
      bodyText: `待导入图文 ${j}`,
      authorName: '图文作者',
      hasVideo: false,
      coverUrl: `https://p3-pc-sign.douyinpic.com/n${j}_1.jpeg`,
      media: [
        { kind: 'photo', url: `https://p3-pc-sign.douyinpic.com/n${j}_1.jpeg` },
        { kind: 'photo', url: `https://p3-pc-sign.douyinpic.com/n${j}_2.jpeg` },
        { kind: 'photo', url: `https://p3-pc-sign.douyinpic.com/n${j}_3.jpeg` },
      ],
    });
  }

  // 1. Test SCAN_DOUYIN_PICKER_ITEMS via onMessage handler (initial + scrollMore: true)
  const pickerInitial = await new Promise((resolve) => {
    const keptOpen = registeredOnMessage({ type: 'SCAN_DOUYIN_PICKER_ITEMS', options: { scrollMore: false } }, {}, resolve);
    assert.equal(keptOpen, true, 'SCAN_DOUYIN_PICKER_ITEMS must return true for async sendResponse');
  });
  assert.equal(pickerInitial.ok, true);
  assert.equal(pickerInitial.items.length, 12);
  assert.equal(pickerInitial.canScrollMore, true);
  const sampleVid = pickerInitial.items.find((i) => i.postID === '7420000000000000000');
  const sampleNote = pickerInitial.items.find((i) => i.postID === '7430000000000000000');
  assert.equal(sampleVid.hasVideo, true);
  assert.equal(sampleVid.durationSeconds, 18);
  assert.ok(sampleVid.bookmark && sampleVid.mediaPost);
  assert.equal(sampleNote.hasVideo, false);
  assert.equal(sampleNote.imageCount, 3);
  assert.ok(sampleNote.bookmark.tags.includes('抖音图文'));

  const pickerMore = await new Promise((resolve) => {
    registeredOnMessage({ type: 'SCAN_DOUYIN_PICKER_ITEMS', options: { scrollMore: true } }, {}, resolve);
  });
  assert.equal(pickerMore.ok, true);
  assert.ok(routeScrollEl.scrollTop > 0, 'scrollMore: true must scroll route-scroll-container');

  // 2. Test batch import with douyinContentFilter: 'image' -> 10 known videos must NOT trip knownStreak or increment skipped
  routeScrollEl.scrollTop = routeScrollEl.scrollHeight - routeScrollEl.clientHeight;
  const started = ux.startBookmarkImport({
    douyinContentFilter: 'image',
    douyinAutoClassify: true,
    skipDuplicates: true,
    stopOnKnownStreak: true,
  });
  assert.equal(started.ok, true);

  // Wait for async batch loop to settle cleanly
  for (let tick = 0; tick < 80; tick++) {
    await new Promise((r) => setTimeout(r, 15));
    const snap = ux.snapshotBatchJob();
    if (snap.status === 'done' || snap.status === 'error' || snap.status === 'stopped') break;
  }

  const finalSnap = ux.snapshotBatchJob();
  assert.equal(finalSnap.status, 'done');
  assert.equal(finalSnap.discovered, 2, 'Only the 2 matching photo-notes should count as discovered');
  assert.equal(finalSnap.skipped, 0, 'Filtered-out known videos must NEVER increment skipped or knownStreak');
  assert.equal(finalSnap.imported, 2, 'Both unseen photo-notes must be imported past 10 known videos');

  const ingestMsgs = sentMessages.filter((m) => m.type === 'INGEST_SOCIAL_BOOKMARKS_CHUNK');
  assert.equal(ingestMsgs.length, 1);
  assert.equal(ingestMsgs[0].autoClassify, true);
  assert.equal(ingestMsgs[0].bookmarks.length, 2);
  assert.ok(ingestMsgs[0].bookmarks.every((b) => b.hasVideo === false && b.tags.includes('抖音图文')));

  // 3. Verify popup.html & popup.js contract for filter bar, auto-classify checkbox, picker DOM, and Images social hint
  const popupHtml = fs.readFileSync(path.join(EXT_ROOT, 'popup.html'), 'utf8');
  const popupJs = fs.readFileSync(path.join(EXT_ROOT, 'popup.js'), 'utf8');
  for (const requiredId of [
    'bm-douyin-filter-wrap',
    'btn-dy-filter-all',
    'btn-dy-filter-video',
    'btn-dy-filter-image',
    'bm-opt-dy-classify-row',
    'bm-opt-dy-classify',
    'bm-primary-actions',
    'btn-bm-open-picker',
    'bm-douyin-picker',
    'bm-picker-list',
    'btn-picker-import',
    'images-social-hint',
    'btn-images-goto-picker',
  ]) {
    assert.ok(popupHtml.includes(`id="${requiredId}"`), `popup.html missing #${requiredId}`);
  }
  for (const fnName of [
    'function formatShortDuration(',
    'function getFilteredDouyinPickerItems(',
    'function updateDouyinFilterLabels(',
    'async function openDouyinPicker(',
    'async function handleImportSelectedDouyinItems(',
    'function updateImagesSocialHintVisibility(',
  ]) {
    assert.ok(popupJs.includes(fnName), `popup.js missing ${fnName}`);
  }
});
