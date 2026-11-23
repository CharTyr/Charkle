/**
 * Charkle Extension — Background Service Worker
 *
 * Responsibilities:
 * - Registers 5 Chinese right-click context menus
 * - Handles keyboard command shortcuts (Alt+Shift+C quick capture current page)
 * - Executes direct background image fetching & Charkle API ingestion
 * - Coordinates batch image saves, target sync, badge flashes & in-page/desktop feedback
 */

import {
  ingestColorSwatch,
  ingestImageDataUrl,
  ingestImageUrl,
  ingestImageUrlsBatch,
  ingestTextSnippet,
  ingestUrl,
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

const MENU_ITEMS = [
  {
    id: 'charkle-save-image',
    title: '收藏图片到 Charkle',
    contexts: ['image'],
  },
  {
    id: 'charkle-save-link',
    title: '收藏链接/推文/GitHub 到 Charkle',
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

function registerContextMenus() {
  chrome.contextMenus.removeAll(() => {
    for (const item of MENU_ITEMS) {
      chrome.contextMenus.create(item, () => {
        // Ignore duplicate/transient runtime errors during rapid SW reloads
        void chrome.runtime.lastError;
      });
    }
  });
}

chrome.runtime.onInstalled.addListener(() => {
  registerContextMenus();
});

chrome.runtime.onStartup.addListener(() => {
  registerContextMenus();
});

function setActionBadge(text, color, clearAfterMs = 0) {
  if (badgeClearTimer) {
    clearTimeout(badgeClearTimer);
    badgeClearTimer = null;
  }
  chrome.action.setBadgeText({ text }).catch(() => {});
  if (color) {
    chrome.action.setBadgeBackgroundColor({ color }).catch(() => {});
  }
  if (typeof chrome.action.setBadgeTextColor === 'function') {
    chrome.action.setBadgeTextColor({ color: '#FFFFFF' }).catch(() => {});
  }
  if (clearAfterMs > 0) {
    badgeClearTimer = setTimeout(() => {
      chrome.action.setBadgeText({ text: '' }).catch(() => {});
      badgeClearTimer = null;
    }, clearAfterMs);
  }
}

function flashBusyBadge() {
  setActionBadge('…', '#2A60E0', 0);
}

function flashSuccessBadge() {
  setActionBadge('✓', '#249A4B', 2600);
}

function flashErrorBadge() {
  setActionBadge('!', '#D93B30', 3600);
}

async function ensureContentScript(tabId, tabUrl) {
  if (!tabId || !isCapturablePageUrl(tabUrl)) return false;
  try {
    await chrome.tabs.sendMessage(tabId, { type: 'CHARKLE_PING' });
    return true;
  } catch {
    try {
      await chrome.scripting.executeScript({
        target: { tabId },
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
    await chrome.tabs.sendMessage(tabId, {
      type: 'CHARKLE_TOAST',
      ...payload,
    });
    return true;
  } catch {
    return false;
  }
}

function showDesktopNotification(title, message) {
  if (!chrome.notifications) return;
  chrome.notifications.create(
    {
      type: 'basic',
      iconUrl: chrome.runtime.getURL('icons/icon-128.png'),
      title,
      message,
      silent: true,
    },
    () => {
      void chrome.runtime.lastError;
    },
  );
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
  const config = await getConfig();
  if (!isConfigured(config)) {
    flashErrorBadge();
    await notifyUser(
      tab,
      'error',
      '尚未连接 Charkle 服务',
      '请在扩展设置中填写服务地址与访问令牌',
    );
    chrome.runtime.openOptionsPage();
    return null;
  }
  return config;
}

async function captureVisibleTabAndIngest(tab, overrideTarget = null) {
  const config = await requireConfiguredOrPrompt(tab);
  if (!config) {
    throw new Error('尚未连接 Charkle 服务，请先在设置中配置。');
  }
  if (!tab || typeof tab.windowId !== 'number') {
    throw new Error('无法获取当前标签页窗口。');
  }

  const target = overrideTarget || resolveActiveTarget(config);
  flashBusyBadge();
  try {
    const dataUrl = await chrome.tabs.captureVisibleTab(tab.windowId, { format: 'png' });
    const fileName = buildScreenshotFileName(tab.title);
    const res = await ingestImageDataUrl(
      config,
      dataUrl,
      fileName,
      isCapturablePageUrl(tab.url) ? tab.url : null,
      target.targetFolderId,
      target.targetBoardId,
    );
    flashSuccessBadge();
    return { res, target, dataUrl };
  } catch (err) {
    flashErrorBadge();
    throw err;
  }
}

async function captureCurrentPage(tab) {
  const config = await requireConfiguredOrPrompt(tab);
  if (!config) return;

  const pageUrl = tab?.url || '';
  if (!isCapturablePageUrl(pageUrl)) {
    flashErrorBadge();
    await notifyUser(tab, 'error', '当前页面不支持网页收藏', '仅支持普通网页');
    return;
  }

  const target = resolveActiveTarget(config);
  const sourceInfo = detectSpecialSource(pageUrl);
  flashBusyBadge();
  await sendTabToast(tab?.id, pageUrl, {
    variant: 'progress',
    message: `正在收藏${sourceInfo.badgeText}…`,
    detail: tab?.title || sourceInfo.hostname,
  });

  try {
    const res = await ingestUrl(
      config,
      pageUrl,
      tab?.title || '',
      '',
      target.targetFolderId,
      target.targetBoardId,
    );
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

chrome.contextMenus.onClicked.addListener(async (info, tab) => {
  const config = await requireConfiguredOrPrompt(tab);
  if (!config) return;

  const target = resolveActiveTarget(config);

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
        const res = await ingestImageUrl(
          config,
          srcUrl,
          info.pageUrl || tab?.url || null,
          tab?.title || '',
          target.targetFolderId,
          target.targetBoardId,
        );
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
        let res;
        if (isDirectImageUrl(linkUrl)) {
          res = await ingestImageUrl(
            config,
            linkUrl,
            info.pageUrl || tab?.url || null,
            info.selectionText || '',
            target.targetFolderId,
            target.targetBoardId,
          );
        } else {
          res = await ingestUrl(
            config,
            linkUrl,
            info.selectionText || '',
            info.pageUrl ? `摘自：${info.pageUrl}` : '',
            target.targetFolderId,
            target.targetBoardId,
          );
        }
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
        const res = await ingestTextSnippet(
          config,
          title,
          text,
          info.pageUrl || tab?.url || null,
          target.targetFolderId,
          target.targetBoardId,
        );
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
        const { res } = await captureVisibleTabAndIngest(tab, target);
        const savedTitle = res?.assets?.[0]?.title || '页面截屏';
        await notifyUser(tab, 'success', `已截取画面到 ${target.label}`, savedTitle);
      } catch (err) {
        await notifyUser(tab, 'error', err instanceof Error ? err.message : '截取页面失败');
      }
      return;
    }
  }
});

chrome.commands.onCommand.addListener(async (command) => {
  if (command === 'quick-capture-page') {
    const [tab] = await chrome.tabs.query({ active: true, currentWindow: true });
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

async function handleMessage(msg, sender) {
  if (!msg || typeof msg.type !== 'string') {
    return { ok: false, error: '无效消息。' };
  }

  switch (msg.type) {
    case 'PING':
      return { ok: true };

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
      const config = await getConfig();
      const pageUrl = msg.pageUrl || sender?.tab?.url || '';
      const activeTarget = resolveActiveTarget(config);
      return {
        ok: true,
        enableDragDrop: config.enableDragDrop !== false,
        configured: isConfigured(config),
        isOwnOrigin: Boolean(config.serverUrl && pageUrl && isSameOriginUrl(config.serverUrl, pageUrl)),
        targetLabel: activeTarget.label,
      };
    }

    case 'TEST_CONNECTION': {
      const existing = await getConfig();
      const candidate = {
        ...existing,
        serverUrl: msg.serverUrl !== undefined ? msg.serverUrl : existing.serverUrl,
        apiToken: msg.apiToken !== undefined ? msg.apiToken : existing.apiToken,
      };
      const result = await testConnection(candidate);
      if (msg.save) {
        const saved = await saveConfig({
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
      const config = await getConfig();
      if (!isConfigured(config)) {
        return { ok: false, error: '尚未连接 Charkle 服务。' };
      }
      const result = await testConnection(config);
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

    case 'SET_TARGET': {
      const patch = {};
      if ('targetMode' in msg) patch.targetMode = msg.targetMode;
      if ('targetFolderId' in msg) patch.targetFolderId = msg.targetFolderId;
      if ('targetFolderName' in msg) patch.targetFolderName = msg.targetFolderName;
      if ('targetBoardId' in msg) patch.targetBoardId = msg.targetBoardId;
      if ('targetBoardName' in msg) patch.targetBoardName = msg.targetBoardName;
      if ('enableDragDrop' in msg) patch.enableDragDrop = Boolean(msg.enableDragDrop);
      const saved = await saveConfig(patch);
      return { ok: true, config: saved, activeTarget: resolveActiveTarget(saved) };
    }

    case 'ENSURE_CONTENT_SCRIPT': {
      const injected = await ensureContentScript(msg.tabId, msg.tabUrl);
      return { ok: injected };
    }

    case 'INGEST_URL': {
      const config = await getConfig();
      const target = resolveMessageTarget(config, msg);
      flashBusyBadge();
      try {
        const res = await ingestUrl(
          config,
          msg.url,
          msg.title || '',
          msg.notes || '',
          target.targetFolderId,
          target.targetBoardId,
        );
        flashSuccessBadge();
        return { ok: true, assets: res.assets || [], targetLabel: target.label };
      } catch (err) {
        flashErrorBadge();
        throw err;
      }
    }

    case 'INGEST_IMAGE_URL': {
      const config = await getConfig();
      const target = resolveMessageTarget(config, msg);
      flashBusyBadge();
      try {
        const res = await ingestImageUrl(
          config,
          msg.imageUrl,
          msg.sourcePageUrl || sender?.tab?.url || null,
          msg.title || '',
          target.targetFolderId,
          target.targetBoardId,
        );
        flashSuccessBadge();
        return { ok: true, assets: res.assets || [], targetLabel: target.label };
      } catch (err) {
        flashErrorBadge();
        throw err;
      }
    }

    case 'INGEST_IMAGES_BATCH': {
      const config = await getConfig();
      const target = resolveMessageTarget(config, msg);
      const items = Array.isArray(msg.items) ? msg.items : [];
      if (items.length === 0) {
        return { ok: false, error: '请先选择至少一张图片。' };
      }
      flashBusyBadge();
      try {
        const summary = await ingestImageUrlsBatch(
          config,
          items,
          msg.sourcePageUrl || null,
          target.targetFolderId,
          target.targetBoardId,
          {
            concurrency: 3,
            onProgress(progress) {
              chrome.runtime
                .sendMessage({
                  type: 'BATCH_INGEST_PROGRESS',
                  ...progress,
                })
                .catch(() => {});
            },
          },
        );
        if (summary.succeeded > 0) {
          flashSuccessBadge();
        } else {
          flashErrorBadge();
        }
        return { ok: summary.succeeded > 0, ...summary, targetLabel: target.label };
      } catch (err) {
        flashErrorBadge();
        throw err;
      }
    }

    case 'CAPTURE_VISIBLE_TAB': {
      const config = await getConfig();
      const target = resolveMessageTarget(config, msg);
      let tab = msg.tab || null;
      if (!tab) {
        const [activeTab] = await chrome.tabs.query({ active: true, currentWindow: true });
        tab = activeTab || null;
      }
      const { res, dataUrl } = await captureVisibleTabAndIngest(tab, target);
      return {
        ok: true,
        assets: res.assets || [],
        targetLabel: target.label,
        previewDataUrl: dataUrl,
      };
    }

    case 'INGEST_TEXT_SNIPPET': {
      const config = await getConfig();
      const target = resolveMessageTarget(config, msg);
      flashBusyBadge();
      try {
        const res = await ingestTextSnippet(
          config,
          msg.title || '文字灵感',
          msg.text || '',
          msg.sourceUrl || null,
          target.targetFolderId,
          target.targetBoardId,
        );
        flashSuccessBadge();
        return { ok: true, assets: res.assets || [], targetLabel: target.label };
      } catch (err) {
        flashErrorBadge();
        throw err;
      }
    }

    case 'INGEST_COLOR_SWATCH': {
      const config = await getConfig();
      const target = resolveMessageTarget(config, msg);
      flashBusyBadge();
      try {
        const res = await ingestColorSwatch(
          config,
          msg.hex,
          msg.title || '',
          target.targetFolderId,
          target.targetBoardId,
        );
        flashSuccessBadge();
        return { ok: true, assets: res.assets || [], targetLabel: target.label };
      } catch (err) {
        flashErrorBadge();
        throw err;
      }
    }

    case 'OPEN_OPTIONS': {
      chrome.runtime.openOptionsPage();
      return { ok: true };
    }

    default:
      return { ok: false, error: '不支持的操作' };
  }
}

chrome.runtime.onMessage.addListener((msg, sender, sendResponse) => {
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
