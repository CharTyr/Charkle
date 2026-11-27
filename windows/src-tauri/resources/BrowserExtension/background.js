/**
 * Charkle Extension — Background Service Worker (Chrome & Safari MV3)
 *
 * Responsibilities:
 * - Registers 5 Chinese right-click context menus
 * - Handles keyboard command shortcuts (Alt+Shift+C quick capture current page)
 * - Executes direct background image fetching & Charkle API ingestion
 * - Bridges one-click batch X Bookmarks & Xiaohongshu Collection imports (with live dedup + chunk ingest)
 * - Supports both Charkle macOS Desktop Bridge (`http://127.0.0.1:41937`) and Charkle Web servers
 */

import {
  autoPairLocalDesktop,
  CharkleApiError,
  createOrReuseFolder,
  fetchExistingSources,
  ingestColorSwatch,
  ingestImageDataUrl,
  ingestImageUrl,
  ingestImageUrlsBatch,
  ingestSocialBookmarksChunk,
  ingestSocialMediaChunk,
  ingestTextSnippet,
  ingestTweetMediaChunk,
  ingestUrl,
  probeLocalDesktop,
  testConnection,
} from './lib/api.js';
import {
  getConfig,
  isConfigured,
  resolveActiveTarget,
  saveConfig,
} from './lib/storage.js';
import {
  detectSpecialSource,
  isCapturablePageUrl,
  isDirectImageUrl,
  isSameOriginUrl,
  sanitizeBaseName,
} from './lib/url-detect.js';

const ext = globalThis.browser ?? globalThis.chrome;

const MENU_ITEMS = [
  {
    id: 'charkle-save-image',
    title: '收藏图片到 Charkle',
    contexts: ['image'],
  },
  {
    id: 'charkle-save-link',
    title: '收藏链接/小红书/推文/GitHub 到 Charkle',
    contexts: ['link'],
  },
  {
    id: 'charkle-save-selection',
    title: '收藏选中文字到 Charkle',
    contexts: ['selection'],
  },
  {
    id: 'charkle-save-page',
    title: '收藏当前网页到 Charkle',
    contexts: ['page'],
  },
  {
    id: 'charkle-capture-visible',
    title: '截取当前页面到 Charkle',
    contexts: ['page', 'frame'],
  },
];

let badgeClearTimer = null;

function createContextMenuItems(contextMenus, runtime, preferPromise) {
  for (const item of MENU_ITEMS) {
    try {
      const maybePromise = preferPromise
        ? contextMenus.create(item)
        : contextMenus.create(item, () => {
            void runtime?.lastError;
          });
      if (maybePromise && typeof maybePromise.catch === 'function') {
        maybePromise.catch(() => {});
      }
    } catch {
      // ignore browser-specific menu creation quirk
    }
  }
}

export function registerContextMenus(
  api = ext,
  { preferPromise = Boolean(globalThis.browser) } = {},
) {
  if (!api?.contextMenus) return;
  let created = false;
  const createAll = () => {
    if (created) return;
    created = true;
    createContextMenuItems(api.contextMenus, api.runtime, preferPromise);
  };
  try {
    if (preferPromise) {
      const res = api.contextMenus.removeAll();
      if (res && typeof res.then === 'function') {
        return res.then(createAll, createAll);
      }
      createAll();
      return;
    }
    const res = api.contextMenus.removeAll(() => {
      void api.runtime?.lastError;
      createAll();
    });
    if (res && typeof res.then === 'function') {
      return res.then(createAll, createAll);
    }
  } catch {
    try {
      const fallback = api.contextMenus.removeAll();
      if (fallback && typeof fallback.then === 'function') {
        return fallback.then(createAll, createAll);
      }
      createAll();
    } catch {
      // ignore if contextMenus unavailable
    }
  }
}

let activeAutoPairPromise = null;

export function isRetryableDesktopError(err) {
  if (!err) return false;
  const code = String(err.code || '');
  const status = Number(err.status || 0);
  return (
    status === 401 ||
    code === 'UNAUTHORIZED' ||
    code === 'NETWORK_ERROR' ||
    code === 'TIMEOUT' ||
    code === 'INVALID_SERVER_URL' ||
    code === 'MISSING_TOKEN'
  );
}

/**
 * Automatically pairs with a running same-machine Charkle desktop bridge on 127.0.0.1,
 * hydrating folders/boards and preserving user target selections.
 * Never overwrites an explicitly configured Charkle Web server unless `force` is true.
 */
async function attemptAutoPairDesktop({ force = false } = {}) {
  if (activeAutoPairPromise) {
    return activeAutoPairPromise;
  }

  const run = (async () => {
    const existing = await getConfig();
    if (!force && isConfigured(existing)) {
      return {
        ok: true,
        paired: true,
        alreadyConfigured: true,
        config: existing,
        activeTarget: resolveActiveTarget(existing),
      };
    }
    if (!force && existing.connectionMode === 'web' && String(existing.apiToken || '').trim()) {
      return {
        ok: false,
        paired: false,
        foundDesktop: false,
        reason: 'WEB_MODE_CONFIGURED',
        error: '当前已配置网页服务模式。',
      };
    }

    const pair = await autoPairLocalDesktop();
    if (!pair.paired) {
      return {
        ok: false,
        paired: false,
        foundDesktop: Boolean(pair.foundDesktop),
        serverUrl: pair.serverUrl || null,
        name: pair.name || null,
        reason: pair.reason || 'DESKTOP_NOT_RUNNING',
        error: pair.error || '未检测到运行中的 Charkle 桌面端。',
      };
    }

    const candidate = {
      ...existing,
      connectionMode: 'desktop',
      serverUrl: pair.serverUrl,
      apiToken: pair.token,
    };
    const result = await testConnection(candidate);

    let nextFolderId = existing.targetFolderId;
    let nextFolderName = existing.targetFolderName;
    if (nextFolderId) {
      const matched = result.folders.find((f) => f.id === nextFolderId);
      if (matched) nextFolderName = matched.name;
      else {
        nextFolderId = null;
        nextFolderName = '';
      }
    }
    let nextBoardId = existing.targetBoardId;
    let nextBoardName = existing.targetBoardName;
    if (nextBoardId) {
      const matched = result.boards.find((b) => b.id === nextBoardId);
      if (matched) nextBoardName = matched.title;
      else {
        nextBoardId = null;
        nextBoardName = '';
      }
    }

    const saved = await saveConfig({
      connectionMode: 'desktop',
      serverUrl: pair.serverUrl,
      apiToken: pair.token,
      cachedFolders: result.folders,
      cachedBoards: result.boards,
      targetFolderId: nextFolderId,
      targetFolderName: nextFolderName,
      targetBoardId: nextBoardId,
      targetBoardName: nextBoardName,
      lastConnectedUser: result.user
        ? {
            username: result.user.username,
            displayName: result.user.displayName,
          }
        : { username: 'desktop', displayName: pair.name || 'Charkle macOS' },
      lastSyncedAt: new Date().toISOString(),
    });

    return {
      ok: true,
      paired: true,
      ...result,
      config: saved,
      activeTarget: resolveActiveTarget(saved),
    };
  })();

  activeAutoPairPromise = run;
  try {
    return await run;
  } finally {
    if (activeAutoPairPromise === run) {
      activeAutoPairPromise = null;
    }
  }
}

/**
 * Ensures an active configuration (auto-pairing with local Charkle desktop if needed)
 * and self-heals once if the desktop bridge port changed or token was regenerated.
 */
export async function withDesktopAutoHeal(operation) {
  let config = await getConfig();
  if (!isConfigured(config) && config.connectionMode !== 'web') {
    const paired = await attemptAutoPairDesktop({ force: false }).catch(() => null);
    if (paired?.ok && paired.config) {
      config = paired.config;
    }
  }
  if (!isConfigured(config)) {
    throw new Error('未检测到运行中的 Charkle 桌面端，请先打开 Charkle 应用。');
  }

  try {
    return await operation(config);
  } catch (err) {
    if (config.connectionMode === 'desktop' && isRetryableDesktopError(err)) {
      const healed = await attemptAutoPairDesktop({ force: true }).catch(() => null);
      if (healed?.ok && healed.config) {
        return await operation(healed.config);
      }
      if (healed?.reason === 'DESKTOP_NOT_RUNNING') {
        throw new Error('Charkle 桌面端暂未运行，请先打开 Mac 上的 Charkle 应用后重试。');
      }
      if (healed?.reason === 'AUTO_PAIR_DISABLED' && healed.error) {
        throw new Error(healed.error);
      }
    }
    throw err;
  }
}

ext?.runtime?.onInstalled?.addListener(() => {
  registerContextMenus();
  void attemptAutoPairDesktop({ force: false }).catch(() => {});
});

ext?.runtime?.onStartup?.addListener(() => {
  registerContextMenus();
  void attemptAutoPairDesktop({ force: false }).catch(() => {});
});

function setActionBadge(text, color, clearAfterMs = 0) {
  if (!ext?.action) return;
  if (badgeClearTimer) {
    clearTimeout(badgeClearTimer);
    badgeClearTimer = null;
  }
  Promise.resolve(ext.action.setBadgeText?.({ text })).catch(() => {});
  if (color) {
    Promise.resolve(ext.action.setBadgeBackgroundColor?.({ color })).catch(() => {});
  }
  if (typeof ext.action.setBadgeTextColor === 'function') {
    Promise.resolve(ext.action.setBadgeTextColor({ color: '#FFFFFF' })).catch(() => {});
  }
  if (clearAfterMs > 0) {
    badgeClearTimer = setTimeout(() => {
      Promise.resolve(ext?.action?.setBadgeText?.({ text: '' })).catch(() => {});
      badgeClearTimer = null;
    }, clearAfterMs);
    if (badgeClearTimer && typeof badgeClearTimer.unref === 'function') {
      badgeClearTimer.unref();
    }
  }
}

function flashBusyBadge(label = '…') {
  setActionBadge(label, '#2A60E0', 0);
}

function flashSuccessBadge() {
  setActionBadge('✓', '#249A4B', 2600);
}

function flashErrorBadge() {
  setActionBadge('!', '#D93B30', 3600);
}

async function sendTopFrameTabMessage(tabId, payload) {
  try {
    return await ext.tabs.sendMessage(tabId, payload, { frameId: 0 });
  } catch (err) {
    // Fallback for browser runtimes that reject frameId options object
    if (err && /frameId|options|signature/i.test(String(err.message || ''))) {
      return await ext.tabs.sendMessage(tabId, payload);
    }
    throw err;
  }
}

async function ensureContentScript(tabId, tabUrl) {
  if (!tabId || !isCapturablePageUrl(tabUrl)) return false;
  try {
    await sendTopFrameTabMessage(tabId, { type: 'CHARKLE_PING' });
    return true;
  } catch {
    if (!ext.scripting?.executeScript) return false;
    try {
      await ext.scripting.executeScript({
        target: { tabId, allFrames: false },
        files: ['content.js'],
      });
      return true;
    } catch {
      return false;
    }
  }
}

async function sendTabToast(tabId, tabUrl, payload) {
  if (!tabId || !isCapturablePageUrl(tabUrl)) return false;
  try {
    await sendTopFrameTabMessage(tabId, {
      type: 'CHARKLE_TOAST',
      ...payload,
    });
    return true;
  } catch {
    return false;
  }
}

function showDesktopNotification(title, message) {
  if (!ext?.notifications?.create) return;
  try {
    ext.notifications.create(
      {
        type: 'basic',
        iconUrl: ext.runtime.getURL('icons/icon-128.png'),
        title,
        message,
        silent: true,
      },
      () => {
        void ext.runtime?.lastError;
      },
    );
  } catch {
    // Safari does not expose desktop notifications API
  }
}

async function notifyUser(tab, variant, message, detail = '') {
  const deliveredInPage = await sendTabToast(tab?.id, tab?.url, {
    variant,
    message,
    detail,
  });
  if (!deliveredInPage) {
    const title = variant === 'error' ? '收藏失败' : 'Charkle';
    const body = detail ? `${message} · ${detail}` : message;
    showDesktopNotification(title, body);
  }
}

function buildScreenshotFileName(tabTitle) {
  const now = new Date();
  const stamp = [
    now.getFullYear(),
    String(now.getMonth() + 1).padStart(2, '0'),
    String(now.getDate()).padStart(2, '0'),
    '-',
    String(now.getHours()).padStart(2, '0'),
    String(now.getMinutes()).padStart(2, '0'),
  ].join('');
  const base = sanitizeBaseName(tabTitle || '页面截屏', '页面截屏').slice(0, 60);
  return `${base}-截屏-${stamp}.png`;
}

async function requireConfiguredOrPrompt(tab) {
  let config = await getConfig();
  if (!isConfigured(config) && config.connectionMode !== 'web') {
    const paired = await attemptAutoPairDesktop({ force: false }).catch(() => null);
    if (paired?.ok && paired.config) {
      config = paired.config;
    }
  }
  if (!isConfigured(config)) {
    flashErrorBadge();
    await notifyUser(
      tab,
      'error',
      '尚未连接到 Charkle',
      '请先打开 Mac 上的 Charkle 桌面端，或在扩展设置中手动配置',
    );
    ext.runtime.openOptionsPage?.();
    return null;
  }
  return config;
}

export async function captureVisibleTabAndIngest(tab, overrideTarget = null) {
  if (!tab || typeof tab.windowId !== 'number') {
    throw new Error('无法获取当前标签页窗口。');
  }

  flashBusyBadge();
  try {
    let dataUrl = null;
    const fileName = buildScreenshotFileName(tab.title);
    const result = await withDesktopAutoHeal(async (cfg) => {
      const target =
        typeof overrideTarget === 'function'
          ? overrideTarget(cfg)
          : overrideTarget || resolveActiveTarget(cfg);
      if (!dataUrl) {
        dataUrl = await ext.tabs.captureVisibleTab(tab.windowId, { format: 'png' });
      }
      const res = await ingestImageDataUrl(
        cfg,
        dataUrl,
        fileName,
        isCapturablePageUrl(tab.url) ? tab.url : null,
        target.targetFolderId,
        target.targetBoardId,
      );
      return { res, target, dataUrl };
    });
    flashSuccessBadge();
    return result;
  } catch (err) {
    flashErrorBadge();
    throw err;
  }
}

const douyinFolderCache = new Map();

export function clearDouyinFolderCache() {
  douyinFolderCache.clear();
}

export function withDouyinTypeTag(item) {
  if (!item || item.platform !== 'douyin') return item;
  const typeTag = item.hasVideo ? '抖音视频' : '抖音图文';
  const existing = Array.isArray(item.tags) ? item.tags : [];
  const merged = Array.from(new Set([...existing, typeTag].filter(Boolean))).slice(0, 16);
  return { ...item, tags: merged };
}

async function ensureCachedSubfolder(cfg, parentId, folderName, stateTracker) {
  const cleanName = String(folderName || '').trim();
  if (!cleanName) return { id: parentId || null, name: '', createdNew: false };
  const cacheKey = `${cfg.serverUrl || ''}::${parentId || '__root__'}::${cleanName.toLowerCase()}`;
  const cached = douyinFolderCache.get(cacheKey);
  if (cached?.id) {
    return { id: cached.id, name: cached.name || cleanName, createdNew: false };
  }
  const res = await createOrReuseFolder(cfg, cleanName, parentId || null, { reuseExisting: true });
  const folder = res?.folder;
  if (folder?.id) {
    douyinFolderCache.set(cacheKey, { id: folder.id, name: folder.name || cleanName });
    if (!res.reused && stateTracker) stateTracker.createdAny = true;
    return { id: folder.id, name: folder.name || cleanName, createdNew: !res.reused };
  }
  return { id: parentId || null, name: cleanName, createdNew: false };
}

async function resolveDouyinAutoFolder(
  cfg,
  baseTarget,
  isVideo,
  { allowCreateRootFromInbox = false, suggestedRootName = '抖音收藏' } = {},
  stateTracker = null,
) {
  if (!baseTarget.targetFolderId && baseTarget.targetBoardId) {
    return { folderId: null, label: baseTarget.label };
  }
  const typeSubName = isVideo ? '视频' : '图文';
  let parentId = baseTarget.targetFolderId || null;
  let parentLabel = baseTarget.label || '';

  if (!parentId) {
    if (!allowCreateRootFromInbox) {
      return { folderId: null, label: baseTarget.label || '收件箱' };
    }
    const rootName = String(suggestedRootName || '抖音收藏').trim() || '抖音收藏';
    const rootFolder = await ensureCachedSubfolder(cfg, null, rootName, stateTracker);
    parentId = rootFolder.id;
    parentLabel = rootFolder.name || rootName;
  }

  const leafName = String(parentLabel).split('/').pop().trim();
  if (leafName === typeSubName) {
    return { folderId: parentId, label: parentLabel };
  }

  const sub = await ensureCachedSubfolder(cfg, parentId, typeSubName, stateTracker);
  return {
    folderId: sub.id || parentId,
    label: parentLabel ? `${parentLabel} / ${typeSubName}` : typeSubName,
  };
}

function scheduleFolderCacheRefresh(cfg) {
  testConnection(cfg)
    .then((res) =>
      saveConfig({
        cachedFolders: res.folders,
        cachedBoards: res.boards,
      }),
    )
    .catch(() => {});
}

export async function captureCurrentPage(tab) {
  const config = await requireConfiguredOrPrompt(tab);
  if (!config) return;

  const pageUrl = tab?.url || '';
  if (!isCapturablePageUrl(pageUrl)) {
    flashErrorBadge();
    await notifyUser(tab, 'error', '当前页面不支持网页收藏', '仅支持普通网页');
    return;
  }

  const sourceInfo = detectSpecialSource(pageUrl);
  flashBusyBadge();
  await sendTabToast(tab?.id, pageUrl, {
    variant: 'progress',
    message: `正在收藏${sourceInfo.badgeText}…`,
    detail: tab?.title || sourceInfo.hostname,
  });

  try {
    // On Xiaohongshu or Douyin post pages, try pulling live authenticated post data from the tab first.
    let preExtractedBookmark = null;
    if ((sourceInfo.kind === 'xiaohongshu' || sourceInfo.kind === 'douyin') && tab?.id) {
      const ctxRes = await sendTopFrameTabMessage(tab.id, { type: 'GET_PAGE_CONTEXT' }).catch(
        () => null,
      );
      if (ctxRes?.ok && ctxRes.socialBookmark) {
        preExtractedBookmark = ctxRes.socialBookmark;
      }
    }

    const { res, target } = await withDesktopAutoHeal(async (cfg) => {
      const t = resolveActiveTarget(cfg);
      let effectiveTarget = t;
      let r;
      if (preExtractedBookmark) {
        const tagged = withDouyinTypeTag(preExtractedBookmark);
        let destFolderId = t.targetFolderId;
        const tracker = { createdAny: false };
        if (
          tagged.platform === 'douyin' &&
          cfg.douyinAutoClassify !== false &&
          t.targetFolderId
        ) {
          const routed = await resolveDouyinAutoFolder(
            cfg,
            t,
            Boolean(tagged.hasVideo),
            { allowCreateRootFromInbox: false },
            tracker,
          );
          destFolderId = routed.folderId;
          effectiveTarget = { ...t, targetFolderId: destFolderId, label: routed.label };
        }
        r = await ingestSocialBookmarksChunk(
          cfg,
          [tagged],
          destFolderId,
          t.targetBoardId,
          { skipDuplicates: false },
        );
        if (tracker.createdAny) scheduleFolderCacheRefresh(cfg);
      } else {
        r = await ingestUrl(
          cfg,
          pageUrl,
          tab?.title || '',
          '',
          t.targetFolderId,
          t.targetBoardId,
        );
      }
      return { res: r, target: effectiveTarget };
    });
    const savedTitle = res?.assets?.[0]?.title || tab?.title || sourceInfo.hostname;
    flashSuccessBadge();
    await notifyUser(tab, 'success', `已收藏到 ${target.label}`, savedTitle);
  } catch (err) {
    flashErrorBadge();
    await notifyUser(
      tab,
      'error',
      err instanceof Error ? err.message : '收藏网页失败',
    );
  }
}

export async function handleContextMenuClick(info, tab) {
  const config = await requireConfiguredOrPrompt(tab);
  if (!config) return;

  switch (info.menuItemId) {
    case 'charkle-save-image': {
      const srcUrl = info.srcUrl || '';
      if (!srcUrl) return;
      flashBusyBadge();
      await sendTabToast(tab?.id, tab?.url, {
        variant: 'progress',
        message: '正在收藏图片…',
      });
      try {
        const { res, target } = await withDesktopAutoHeal(async (cfg) => {
          const t = resolveActiveTarget(cfg);
          const r = await ingestImageUrl(
            cfg,
            srcUrl,
            info.pageUrl || tab?.url || null,
            tab?.title || '',
            t.targetFolderId,
            t.targetBoardId,
          );
          return { res: r, target: t };
        });
        const savedTitle = res?.assets?.[0]?.title || '图片';
        flashSuccessBadge();
        await notifyUser(tab, 'success', `已收藏图片到 ${target.label}`, savedTitle);
      } catch (err) {
        flashErrorBadge();
        await notifyUser(tab, 'error', err instanceof Error ? err.message : '收藏图片失败');
      }
      return;
    }

    case 'charkle-save-link': {
      const linkUrl = info.linkUrl || '';
      if (!linkUrl) return;
      flashBusyBadge();
      const sourceInfo = detectSpecialSource(linkUrl);
      await sendTabToast(tab?.id, tab?.url, {
        variant: 'progress',
        message: `正在收藏${sourceInfo.badgeText}…`,
      });
      try {
        const { res, target } = await withDesktopAutoHeal(async (cfg) => {
          const t = resolveActiveTarget(cfg);
          let r;
          if (isDirectImageUrl(linkUrl)) {
            r = await ingestImageUrl(
              cfg,
              linkUrl,
              info.pageUrl || tab?.url || null,
              info.selectionText || '',
              t.targetFolderId,
              t.targetBoardId,
            );
          } else {
            r = await ingestUrl(
              cfg,
              linkUrl,
              info.selectionText || '',
              info.pageUrl ? `摘自：${info.pageUrl}` : '',
              t.targetFolderId,
              t.targetBoardId,
            );
          }
          return { res: r, target: t };
        });
        const savedTitle = res?.assets?.[0]?.title || sourceInfo.hostname || linkUrl;
        flashSuccessBadge();
        await notifyUser(tab, 'success', `已收藏到 ${target.label}`, savedTitle);
      } catch (err) {
        flashErrorBadge();
        await notifyUser(tab, 'error', err instanceof Error ? err.message : '收藏链接失败');
      }
      return;
    }

    case 'charkle-save-selection': {
      const text = String(info.selectionText || '').trim();
      if (!text) return;
      flashBusyBadge();
      await sendTabToast(tab?.id, tab?.url, {
        variant: 'progress',
        message: '正在收藏文字摘录…',
      });
      try {
        const title = tab?.title ? `${tab.title} · 摘录` : '文字摘录';
        const { res, target } = await withDesktopAutoHeal(async (cfg) => {
          const t = resolveActiveTarget(cfg);
          const r = await ingestTextSnippet(
            cfg,
            title,
            text,
            info.pageUrl || tab?.url || null,
            t.targetFolderId,
            t.targetBoardId,
          );
          return { res: r, target: t };
        });
        const savedTitle = res?.assets?.[0]?.title || title;
        flashSuccessBadge();
        await notifyUser(tab, 'success', `已收藏文字到 ${target.label}`, savedTitle);
      } catch (err) {
        flashErrorBadge();
        await notifyUser(tab, 'error', err instanceof Error ? err.message : '收藏文字失败');
      }
      return;
    }

    case 'charkle-save-page': {
      await captureCurrentPage(tab);
      return;
    }

    case 'charkle-capture-visible': {
      try {
        const { res, target } = await captureVisibleTabAndIngest(tab);
        const savedTitle = res?.assets?.[0]?.title || '页面截屏';
        await notifyUser(tab, 'success', `已截取画面到 ${target.label}`, savedTitle);
      } catch (err) {
        await notifyUser(tab, 'error', err instanceof Error ? err.message : '截取页面失败');
      }
      return;
    }
  }
}

ext?.contextMenus?.onClicked?.addListener(handleContextMenuClick);

ext?.commands?.onCommand?.addListener(async (command) => {
  if (command === 'quick-capture-page') {
    const [tab] = await ext.tabs.query({ active: true, currentWindow: true });
    if (tab) {
      await captureCurrentPage(tab);
    }
  }
});

function resolveMessageTarget(config, msg) {
  if (msg && ('targetFolderId' in msg || 'targetBoardId' in msg)) {
    return {
      targetFolderId: msg.targetFolderId || null,
      targetBoardId: msg.targetBoardId || null,
      label: msg.targetLabel || resolveActiveTarget(config).label,
    };
  }
  return resolveActiveTarget(config);
}

export async function handleMessage(msg, sender) {
  if (!msg || typeof msg.type !== 'string') {
    return { ok: false, error: '无效消息。' };
  }

  switch (msg.type) {
    case 'PING':
      return { ok: true };

    case 'PROBE_LOCAL_DESKTOP': {
      const probe = await probeLocalDesktop();
      return { ok: true, ...probe };
    }

    case 'AUTO_PAIR_LOCAL_DESKTOP': {
      return await attemptAutoPairDesktop({ force: Boolean(msg.force) });
    }

    case 'GET_CONFIG': {
      const config = await getConfig();
      return {
        ok: true,
        config,
        configured: isConfigured(config),
        activeTarget: resolveActiveTarget(config),
      };
    }

    case 'GET_DRAG_CONTEXT': {
      let config = await getConfig();
      if (!isConfigured(config) && config.connectionMode !== 'web') {
        const paired = await attemptAutoPairDesktop({ force: false }).catch(() => null);
        if (paired?.ok && paired.config) {
          config = paired.config;
        }
      }
      const pageUrl = msg.pageUrl || sender?.tab?.url || '';
      const activeTarget = resolveActiveTarget(config);
      return {
        ok: true,
        enableDragDrop: config.enableDragDrop !== false,
        enableBookmarkFloatingButton: config.enableBookmarkFloatingButton !== false,
        configured: isConfigured(config),
        isOwnOrigin: Boolean(config.serverUrl && pageUrl && isSameOriginUrl(config.serverUrl, pageUrl)),
        targetLabel: activeTarget.label,
      };
    }

    case 'TEST_CONNECTION': {
      const existing = await getConfig();
      const candidate = {
        ...existing,
        connectionMode: msg.connectionMode ?? existing.connectionMode,
        serverUrl: msg.serverUrl !== undefined ? msg.serverUrl : existing.serverUrl,
        apiToken: msg.apiToken !== undefined ? msg.apiToken : existing.apiToken,
      };
      const result = await testConnection(candidate);
      if (msg.save) {
        const saved = await saveConfig({
          connectionMode: candidate.connectionMode,
          serverUrl: candidate.serverUrl,
          apiToken: candidate.apiToken,
          cachedFolders: result.folders,
          cachedBoards: result.boards,
          lastConnectedUser: result.user
            ? {
                username: result.user.username,
                displayName: result.user.displayName,
              }
            : null,
          lastSyncedAt: new Date().toISOString(),
        });
        return { ok: true, ...result, config: saved, activeTarget: resolveActiveTarget(saved) };
      }
      return { ok: true, ...result };
    }

    case 'REFRESH_TARGETS': {
      clearDouyinFolderCache();
      const { config, result } = await withDesktopAutoHeal(async (cfg) => {
        const res = await testConnection(cfg);
        return { config: cfg, result: res };
      });
      let nextFolderId = config.targetFolderId;
      let nextFolderName = config.targetFolderName;
      if (nextFolderId) {
        const matched = result.folders.find((f) => f.id === nextFolderId);
        if (matched) {
          nextFolderName = matched.name;
        } else {
          nextFolderId = null;
          nextFolderName = '';
        }
      }
      let nextBoardId = config.targetBoardId;
      let nextBoardName = config.targetBoardName;
      if (nextBoardId) {
        const matched = result.boards.find((b) => b.id === nextBoardId);
        if (matched) {
          nextBoardName = matched.title;
        } else {
          nextBoardId = null;
          nextBoardName = '';
        }
      }

      const saved = await saveConfig({
        cachedFolders: result.folders,
        cachedBoards: result.boards,
        targetFolderId: nextFolderId,
        targetFolderName: nextFolderName,
        targetBoardId: nextBoardId,
        targetBoardName: nextBoardName,
        lastConnectedUser: result.user
          ? {
              username: result.user.username,
              displayName: result.user.displayName,
            }
          : config.lastConnectedUser,
        lastSyncedAt: new Date().toISOString(),
      });
      return {
        ok: true,
        folders: result.folders,
        boards: result.boards,
        user: result.user,
        config: saved,
        activeTarget: resolveActiveTarget(saved),
      };
    }

    case 'CREATE_FOLDER_AND_SELECT': {
      const { created, refreshed } = await withDesktopAutoHeal(async (cfg) => {
        const c = await createOrReuseFolder(cfg, msg.name, msg.parentId || null, {
          reuseExisting: true,
        });
        const r = await testConnection(cfg);
        return { created: c, refreshed: r };
      });
      const folder = created.folder;
      const saved = await saveConfig({
        cachedFolders: refreshed.folders,
        cachedBoards: refreshed.boards,
        targetMode: 'folder',
        targetFolderId: folder?.id || null,
        targetFolderName: folder?.name || msg.name,
      });
      return {
        ok: true,
        folder,
        reused: Boolean(created.reused),
        config: saved,
        activeTarget: resolveActiveTarget(saved),
      };
    }

    case 'SET_TARGET': {
      const patch = {};
      const allowedKeys = [
        'targetMode',
        'targetFolderId',
        'targetFolderName',
        'targetBoardId',
        'targetBoardName',
        'enableDragDrop',
        'enableBookmarkFloatingButton',
        'bookmarkSkipDuplicates',
        'bookmarkStopOnKnownStreak',
        'bookmarkEnrichXhsDetails',
        'bookmarkMaxCount',
        'authorMediaOrganizeMode',
        'authorMediaIncludeVideos',
        'authorMediaSkipRetweets',
        'xhsProfileCollectMode',
        'douyinProfileCollectMode',
        'douyinContentFilter',
        'douyinAutoClassify',
      ];
      for (const key of allowedKeys) {
        if (key in msg) patch[key] = msg[key];
      }
      const saved = await saveConfig(patch);
      return { ok: true, config: saved, activeTarget: resolveActiveTarget(saved) };
    }

    case 'ENSURE_CONTENT_SCRIPT': {
      const injected = await ensureContentScript(msg.tabId, msg.tabUrl);
      return { ok: injected };
    }

    case 'FETCH_EXISTING_SOURCES': {
      const res = await withDesktopAutoHeal((cfg) => fetchExistingSources(cfg));
      return { ok: true, ...res };
    }

    case 'ENSURE_AUTHOR_ROOT_FOLDER': {
      const folderName = String(msg.name || '').trim();
      if (!folderName) {
        return { ok: false, error: '缺少作者文件夹名称。' };
      }
      const { created, refreshed, parentLabel } = await withDesktopAutoHeal(async (cfg) => {
        const active = resolveActiveTarget(cfg);
        const parentId =
          'parentId' in msg
            ? msg.parentId || null
            : active.mode === 'folder'
              ? active.targetFolderId
              : null;
        // If user already selected a folder with the same name as the author folder, reuse it directly instead of nesting `@a/@a`.
        if (
          parentId &&
          active.label &&
          active.label.trim().toLowerCase() === folderName.toLowerCase()
        ) {
          return {
            created: { folder: { id: parentId, name: active.label }, reused: true },
            refreshed: null,
            parentLabel: active.label,
          };
        }
        const c = await createOrReuseFolder(cfg, folderName, parentId, { reuseExisting: true });
        const r = c.reused ? null : await testConnection(cfg).catch(() => null);
        return { created: c, refreshed: r, parentLabel: active.mode === 'folder' ? active.label : '' };
      });
      if (refreshed) {
        await saveConfig({
          cachedFolders: refreshed.folders,
          cachedBoards: refreshed.boards,
        });
      }
      const folder = created.folder;
      const displayLabel =
        parentLabel && parentLabel.toLowerCase() !== (folder?.name || folderName).toLowerCase()
          ? `${parentLabel} / ${folder?.name || folderName}`
          : folder?.name || folderName;
      return {
        ok: true,
        folder,
        reused: Boolean(created.reused),
        targetLabel: displayLabel,
      };
    }

    case 'INGEST_SOCIAL_MEDIA_CHUNK':
    case 'INGEST_TWEET_MEDIA_CHUNK': {
      const posts = Array.isArray(msg.posts) ? msg.posts : Array.isArray(msg.tweets) ? msg.tweets : [];
      if (posts.length === 0) {
        const cfg = await getConfig();
        return {
          ok: true,
          assets: [],
          created: 0,
          postsImported: 0,
          tweetsImported: 0,
          skipped: 0,
          createdFolders: 0,
          targetLabel: resolveMessageTarget(cfg, msg).label,
        };
      }
      flashBusyBadge(msg.badgeText || '…');
      try {
        const useUnified = msg.type === 'INGEST_SOCIAL_MEDIA_CHUNK';
        const taggedPosts = posts.map(withDouyinTypeTag);
        const { res, target } = await withDesktopAutoHeal(async (cfg) => {
          const t = resolveMessageTarget(cfg, msg);
          const ingestFn = useUnified ? ingestSocialMediaChunk : ingestTweetMediaChunk;
          const shouldAutoClassify =
            useUnified &&
            ('autoClassify' in msg ? msg.autoClassify !== false : cfg.douyinAutoClassify !== false) &&
            taggedPosts.some((p) => p?.platform === 'douyin');

          if (!shouldAutoClassify) {
            const r = await ingestFn(
              cfg,
              taggedPosts,
              t.targetFolderId,
              t.targetBoardId,
              { skipDuplicates: msg.skipDuplicates !== false },
            );
            return { res: r, target: t };
          }

          const tracker = { createdAny: false };
          const dyVideos = taggedPosts.filter((p) => p?.platform === 'douyin' && p.hasVideo);
          const dyImages = taggedPosts.filter((p) => p?.platform === 'douyin' && !p.hasVideo);
          const others = taggedPosts.filter((p) => p?.platform !== 'douyin');

          const merged = {
            assets: [],
            created: 0,
            postsImported: 0,
            tweetsImported: 0,
            skipped: 0,
            createdFolders: 0,
          };
          let finalLabel = t.label;

          const runGroup = async (group, destFolderId, destBoardId) => {
            if (group.length === 0) return;
            const r = await ingestFn(cfg, group, destFolderId, destBoardId, {
              skipDuplicates: msg.skipDuplicates !== false,
            });
            if (Array.isArray(r.assets)) merged.assets.push(...r.assets);
            merged.created += Number(r.created || 0);
            merged.postsImported += Number(r.postsImported ?? r.tweetsImported ?? 0);
            merged.tweetsImported = merged.postsImported;
            merged.skipped += Number(r.skipped || 0);
            merged.createdFolders += Number(r.createdFolders || 0);
          };

          if (dyVideos.length > 0) {
            const routed = await resolveDouyinAutoFolder(
              cfg,
              t,
              true,
              { allowCreateRootFromInbox: true, suggestedRootName: msg.suggestedFolderName || '抖音收藏' },
              tracker,
            );
            finalLabel = routed.label;
            await runGroup(dyVideos, routed.folderId, t.targetBoardId);
          }
          if (dyImages.length > 0) {
            const routed = await resolveDouyinAutoFolder(
              cfg,
              t,
              false,
              { allowCreateRootFromInbox: true, suggestedRootName: msg.suggestedFolderName || '抖音收藏' },
              tracker,
            );
            finalLabel =
              dyVideos.length > 0
                ? t.targetFolderId
                  ? t.label
                  : msg.suggestedFolderName || '抖音收藏'
                : routed.label;
            await runGroup(dyImages, routed.folderId, t.targetBoardId);
          }
          if (others.length > 0) {
            await runGroup(others, t.targetFolderId, t.targetBoardId);
          }
          if (tracker.createdAny) scheduleFolderCacheRefresh(cfg);
          return { res: merged, target: { ...t, label: finalLabel } };
        });
        if (msg.isFinalChunk) {
          flashSuccessBadge();
        }
        return { ok: true, ...res, targetLabel: target.label };
      } catch (err) {
        if (msg.isFinalChunk) {
          flashErrorBadge();
        }
        throw err;
      }
    }

    case 'INGEST_SOCIAL_BOOKMARKS_CHUNK': {
      const bookmarks = Array.isArray(msg.bookmarks) ? msg.bookmarks : [];
      if (bookmarks.length === 0) {
        const cfg = await getConfig();
        return {
          ok: true,
          assets: [],
          created: 0,
          skipped: 0,
          targetLabel: resolveMessageTarget(cfg, msg).label,
        };
      }
      flashBusyBadge(msg.badgeText || '…');
      try {
        const taggedBookmarks = bookmarks.map(withDouyinTypeTag);
        const { res, target } = await withDesktopAutoHeal(async (cfg) => {
          const t = resolveMessageTarget(cfg, msg);
          const shouldAutoClassify =
            ('autoClassify' in msg ? msg.autoClassify !== false : cfg.douyinAutoClassify !== false) &&
            taggedBookmarks.some((b) => b?.platform === 'douyin');

          if (!shouldAutoClassify) {
            const r = await ingestSocialBookmarksChunk(
              cfg,
              taggedBookmarks,
              t.targetFolderId,
              t.targetBoardId,
              { skipDuplicates: msg.skipDuplicates !== false },
            );
            return { res: r, target: t };
          }

          const tracker = { createdAny: false };
          const dyVideos = taggedBookmarks.filter((b) => b?.platform === 'douyin' && b.hasVideo);
          const dyImages = taggedBookmarks.filter((b) => b?.platform === 'douyin' && !b.hasVideo);
          const others = taggedBookmarks.filter((b) => b?.platform !== 'douyin');

          const merged = { assets: [], created: 0, skipped: 0 };
          let finalLabel = t.label;

          const runGroup = async (group, destFolderId, destBoardId) => {
            if (group.length === 0) return;
            const r = await ingestSocialBookmarksChunk(cfg, group, destFolderId, destBoardId, {
              skipDuplicates: msg.skipDuplicates !== false,
            });
            if (Array.isArray(r.assets)) merged.assets.push(...r.assets);
            merged.created += Number(r.created || 0);
            merged.skipped += Number(r.skipped || 0);
          };

          if (dyVideos.length > 0) {
            const routed = await resolveDouyinAutoFolder(
              cfg,
              t,
              true,
              { allowCreateRootFromInbox: true, suggestedRootName: msg.suggestedFolderName || '抖音收藏' },
              tracker,
            );
            finalLabel = routed.label;
            await runGroup(dyVideos, routed.folderId, t.targetBoardId);
          }
          if (dyImages.length > 0) {
            const routed = await resolveDouyinAutoFolder(
              cfg,
              t,
              false,
              { allowCreateRootFromInbox: true, suggestedRootName: msg.suggestedFolderName || '抖音收藏' },
              tracker,
            );
            finalLabel =
              dyVideos.length > 0
                ? t.targetFolderId
                  ? t.label
                  : msg.suggestedFolderName || '抖音收藏'
                : routed.label;
            await runGroup(dyImages, routed.folderId, t.targetBoardId);
          }
          if (others.length > 0) {
            await runGroup(others, t.targetFolderId, t.targetBoardId);
          }
          if (tracker.createdAny) scheduleFolderCacheRefresh(cfg);
          return { res: merged, target: { ...t, label: finalLabel } };
        });
        if (msg.isFinalChunk) {
          flashSuccessBadge();
        }
        return { ok: true, ...res, targetLabel: target.label };
      } catch (err) {
        if (msg.isFinalChunk) {
          flashErrorBadge();
        }
        throw err;
      }
    }

    case 'BOOKMARK_JOB_STATUS_PUSH': {
      // Relay progress from content script to any open popup and keep toolbar badge fresh.
      const job = msg.job;
      if (job) {
        if (job.status === 'running') {
          const count = job.mode === 'author_media' ? (job.mediaImported || job.imported || 0) : (job.imported || 0);
          const badge = count > 0 ? String(Math.min(999, count)) : '…';
          flashBusyBadge(badge);
        } else if (job.status === 'done') {
          flashSuccessBadge();
        } else if (job.status === 'error') {
          flashErrorBadge();
        } else if (job.status === 'stopped' || job.status === 'idle') {
          setActionBadge('', '', 0);
        }
      }
      Promise.resolve(
        ext.runtime.sendMessage({
          type: 'BOOKMARK_JOB_UPDATE',
          tabId: sender?.tab?.id ?? null,
          job,
        }),
      ).catch(() => {});
      return { ok: true };
    }

    case 'INGEST_URL': {
      flashBusyBadge();
      try {
        const { res, target } = await withDesktopAutoHeal(async (cfg) => {
          const t = resolveMessageTarget(cfg, msg);
          let effectiveTarget = t;
          let r;
          if (msg.socialBookmark) {
            const payload = withDouyinTypeTag({ ...msg.socialBookmark });
            if (msg.title) payload.articleTitle = msg.title;
            if (msg.notes) payload.bodyText = msg.notes;
            let destFolderId = t.targetFolderId;
            const tracker = { createdAny: false };
            if (
              payload.platform === 'douyin' &&
              cfg.douyinAutoClassify !== false &&
              t.targetFolderId
            ) {
              const routed = await resolveDouyinAutoFolder(
                cfg,
                t,
                Boolean(payload.hasVideo),
                { allowCreateRootFromInbox: false },
                tracker,
              );
              destFolderId = routed.folderId;
              effectiveTarget = { ...t, targetFolderId: destFolderId, label: routed.label };
            }
            r = await ingestSocialBookmarksChunk(
              cfg,
              [payload],
              destFolderId,
              t.targetBoardId,
              { skipDuplicates: false },
            );
            if (tracker.createdAny) scheduleFolderCacheRefresh(cfg);
          } else {
            r = await ingestUrl(
              cfg,
              msg.url,
              msg.title || '',
              msg.notes || '',
              t.targetFolderId,
              t.targetBoardId,
            );
          }
          return { res: r, target: effectiveTarget };
        });
        flashSuccessBadge();
        return { ok: true, assets: res.assets || [], targetLabel: target.label };
      } catch (err) {
        flashErrorBadge();
        throw err;
      }
    }

    case 'INGEST_IMAGE_URL': {
      flashBusyBadge();
      try {
        const { res, target } = await withDesktopAutoHeal(async (cfg) => {
          const t = resolveMessageTarget(cfg, msg);
          const r = await ingestImageUrl(
            cfg,
            msg.imageUrl,
            msg.sourcePageUrl || sender?.tab?.url || null,
            msg.title || '',
            t.targetFolderId,
            t.targetBoardId,
          );
          return { res: r, target: t };
        });
        flashSuccessBadge();
        return { ok: true, assets: res.assets || [], targetLabel: target.label };
      } catch (err) {
        flashErrorBadge();
        throw err;
      }
    }

    case 'INGEST_IMAGES_BATCH': {
      const items = Array.isArray(msg.items) ? msg.items : [];
      if (items.length === 0) {
        return { ok: false, error: '请先选择至少一张图片。' };
      }
      flashBusyBadge();
      try {
        const { summary, target } = await withDesktopAutoHeal(async (cfg) => {
          const t = resolveMessageTarget(cfg, msg);
          const s = await ingestImageUrlsBatch(
            cfg,
            items,
            msg.sourcePageUrl || null,
            t.targetFolderId,
            t.targetBoardId,
            {
              concurrency: 3,
              onProgress(progress) {
                Promise.resolve(
                  ext?.runtime?.sendMessage?.({
                    type: 'BATCH_INGEST_PROGRESS',
                    ...progress,
                  }),
                ).catch(() => {});
              },
            },
          );
          if (s.succeeded === 0) {
            const retryable = s.errors.find((entry) => isRetryableDesktopError(entry));
            if (retryable) {
              throw new CharkleApiError(retryable.message || '批量收藏图片失败', {
                status: Number(retryable.status || 0),
                code: String(retryable.code || 'API_ERROR'),
              });
            }
          }
          return { summary: s, target: t };
        });
        if (summary.succeeded > 0) {
          flashSuccessBadge();
        } else {
          flashErrorBadge();
        }
        return {
          ok: summary.succeeded > 0,
          ...summary,
          ...(summary.succeeded === 0
            ? { error: summary.errors[0]?.message || '批量收藏图片失败' }
            : {}),
          targetLabel: target.label,
        };
      } catch (err) {
        flashErrorBadge();
        throw err;
      }
    }

    case 'CAPTURE_VISIBLE_TAB': {
      let tab = msg.tab || null;
      if (!tab) {
        const [activeTab] = await ext.tabs.query({ active: true, currentWindow: true });
        tab = activeTab || null;
      }
      const { res, target, dataUrl } = await captureVisibleTabAndIngest(tab, (cfg) =>
        resolveMessageTarget(cfg, msg),
      );
      return {
        ok: true,
        assets: res.assets || [],
        targetLabel: target.label,
        previewDataUrl: dataUrl,
      };
    }

    case 'INGEST_TEXT_SNIPPET': {
      flashBusyBadge();
      try {
        const { res, target } = await withDesktopAutoHeal(async (cfg) => {
          const t = resolveMessageTarget(cfg, msg);
          const r = await ingestTextSnippet(
            cfg,
            msg.title || '文字灵感',
            msg.text || '',
            msg.sourceUrl || null,
            t.targetFolderId,
            t.targetBoardId,
          );
          return { res: r, target: t };
        });
        flashSuccessBadge();
        return { ok: true, assets: res.assets || [], targetLabel: target.label };
      } catch (err) {
        flashErrorBadge();
        throw err;
      }
    }

    case 'INGEST_COLOR_SWATCH': {
      flashBusyBadge();
      try {
        const { res, target } = await withDesktopAutoHeal(async (cfg) => {
          const t = resolveMessageTarget(cfg, msg);
          const r = await ingestColorSwatch(
            cfg,
            msg.hex,
            msg.title || '',
            t.targetFolderId,
            t.targetBoardId,
          );
          return { res: r, target: t };
        });
        flashSuccessBadge();
        return { ok: true, assets: res.assets || [], targetLabel: target.label };
      } catch (err) {
        flashErrorBadge();
        throw err;
      }
    }

    case 'OPEN_OPTIONS': {
      ext.runtime.openOptionsPage?.();
      return { ok: true };
    }

    default:
      return { ok: false, error: '不支持的操作' };
  }
}

ext?.runtime?.onMessage?.addListener((msg, sender, sendResponse) => {
  handleMessage(msg, sender)
    .then((result) => sendResponse(result))
    .catch((err) => {
      sendResponse({
        ok: false,
        error: err instanceof Error ? err.message : '操作失败，请稍后重试。',
        code: err?.code || 'ERROR',
      });
    });
  return true;
});
