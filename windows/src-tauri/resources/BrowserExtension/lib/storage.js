/**
 * Persistent extension settings & cached target lists backed by chrome.storage.local / browser.storage.local.
 */

import { normalizeServerUrl } from './url-detect.js';

export const STORAGE_KEY = 'charkleClipperConfig';
export const DEFAULT_DESKTOP_SERVER_URL = 'http://127.0.0.1:41937';

export const DEFAULT_CONFIG = Object.freeze({
  connectionMode: 'desktop', // 'desktop' | 'web'
  serverUrl: DEFAULT_DESKTOP_SERVER_URL,
  apiToken: '',
  targetMode: 'inbox', // 'inbox' | 'folder' | 'board'
  targetFolderId: null,
  targetFolderName: '',
  targetBoardId: null,
  targetBoardName: '',
  enableDragDrop: true,
  enableBookmarkFloatingButton: true,
  bookmarkSkipDuplicates: true,
  bookmarkStopOnKnownStreak: true,
  bookmarkEnrichXhsDetails: true,
  bookmarkMaxCount: 0, // 0 = unlimited
  authorMediaOrganizeMode: 'per_tweet', // 'per_tweet' | 'per_post' | 'multi_only' | 'flat'
  authorMediaIncludeVideos: true,
  authorMediaSkipRetweets: true,
  xhsProfileCollectMode: 'media', // 'media' | 'bookmarks'
  douyinProfileCollectMode: 'media', // 'media' | 'bookmarks'
  douyinContentFilter: 'all', // 'all' | 'video' | 'image'
  douyinAutoClassify: true,
  cachedFolders: [],
  cachedBoards: [],
  lastConnectedUser: null,
  lastSyncedAt: null,
});

function getStorageArea(storageOverride) {
  if (storageOverride) return storageOverride;
  const api = globalThis.browser ?? globalThis.chrome;
  if (api && api.storage && api.storage.local) {
    return api.storage.local;
  }
  return null;
}

export async function getConfig(storageOverride) {
  const area = getStorageArea(storageOverride);
  if (!area) return { ...DEFAULT_CONFIG };
  const result = await area.get(STORAGE_KEY);
  const stored = result && typeof result[STORAGE_KEY] === 'object' ? result[STORAGE_KEY] : {};
  return {
    ...DEFAULT_CONFIG,
    ...stored,
    cachedFolders: Array.isArray(stored.cachedFolders) ? stored.cachedFolders : [],
    cachedBoards: Array.isArray(stored.cachedBoards) ? stored.cachedBoards : [],
  };
}

export async function saveConfig(patch, storageOverride) {
  const current = await getConfig(storageOverride);
  const next = { ...current, ...patch };
  if ('serverUrl' in patch) {
    next.serverUrl = patch.serverUrl ? normalizeServerUrl(patch.serverUrl) : '';
  }
  if ('apiToken' in patch) {
    next.apiToken = String(patch.apiToken ?? '').trim();
  }
  if (next.connectionMode !== 'desktop' && next.connectionMode !== 'web') {
    next.connectionMode = 'desktop';
  }
  if (next.targetMode !== 'inbox' && next.targetMode !== 'folder' && next.targetMode !== 'board') {
    next.targetMode = 'inbox';
  }
  const maxCount = Number(next.bookmarkMaxCount);
  next.bookmarkMaxCount = Number.isFinite(maxCount) && maxCount > 0 ? Math.round(maxCount) : 0;
  if (!['per_tweet', 'per_post', 'multi_only', 'flat'].includes(next.authorMediaOrganizeMode)) {
    next.authorMediaOrganizeMode = 'per_tweet';
  }
  if (next.xhsProfileCollectMode !== 'media' && next.xhsProfileCollectMode !== 'bookmarks') {
    next.xhsProfileCollectMode = 'media';
  }
  if (next.douyinProfileCollectMode !== 'media' && next.douyinProfileCollectMode !== 'bookmarks') {
    next.douyinProfileCollectMode = 'media';
  }
  if (!['all', 'video', 'image'].includes(next.douyinContentFilter)) {
    next.douyinContentFilter = 'all';
  }
  next.douyinAutoClassify = next.douyinAutoClassify !== false;

  const area = getStorageArea(storageOverride);
  if (area) {
    await area.set({ [STORAGE_KEY]: next });
  }
  return next;
}

export function isConfigured(config) {
  return Boolean(config && normalizeServerUrl(config.serverUrl) && String(config.apiToken || '').trim());
}

/**
 * Resolves the active capture target (folder or board or inbox) + friendly display label.
 */
export function resolveActiveTarget(config) {
  if (!config || config.targetMode === 'inbox') {
    return {
      mode: 'inbox',
      targetFolderId: null,
      targetBoardId: null,
      label: '收件箱',
    };
  }
  if (config.targetMode === 'folder' && config.targetFolderId) {
    const matched = Array.isArray(config.cachedFolders)
      ? config.cachedFolders.find((f) => f.id === config.targetFolderId)
      : null;
    return {
      mode: 'folder',
      targetFolderId: config.targetFolderId,
      targetBoardId: null,
      label: matched?.name || config.targetFolderName || '指定文件夹',
    };
  }
  if (config.targetMode === 'board' && config.targetBoardId) {
    const matched = Array.isArray(config.cachedBoards)
      ? config.cachedBoards.find((b) => b.id === config.targetBoardId)
      : null;
    return {
      mode: 'board',
      targetFolderId: null,
      targetBoardId: config.targetBoardId,
      label: matched?.title || config.targetBoardName || '当前情绪板',
    };
  }
  return {
    mode: 'inbox',
    targetFolderId: null,
    targetBoardId: null,
    label: '收件箱',
  };
}

/**
 * Flattens FolderRecord[] into indented select options preserving parent-child hierarchy.
 */
export function buildFolderOptions(folders) {
  if (!Array.isArray(folders) || folders.length === 0) return [];
  const byId = new Map(folders.map((f) => [f.id, f]));
  const childrenMap = new Map();

  for (const f of folders) {
    const parentKey = f.parentID && byId.has(f.parentID) && f.parentID !== f.id ? f.parentID : '__root__';
    if (!childrenMap.has(parentKey)) childrenMap.set(parentKey, []);
    childrenMap.get(parentKey).push(f);
  }

  for (const list of childrenMap.values()) {
    list.sort((a, b) => (a.sortOrder ?? 0) - (b.sortOrder ?? 0) || String(a.name).localeCompare(String(b.name)));
  }

  const visited = new Set();
  const options = [];

  function walk(parentKey, depth) {
    const nodes = childrenMap.get(parentKey) || [];
    for (const node of nodes) {
      if (visited.has(node.id)) continue;
      visited.add(node.id);
      const prefix = depth > 0 ? `${'　'.repeat(depth)}└ ` : '';
      const countSuffix = typeof node.assetCount === 'number' && node.assetCount > 0 ? ` (${node.assetCount})` : '';
      options.push({
        id: node.id,
        name: node.name,
        depth,
        label: `${prefix}${node.name}${countSuffix}`,
      });
      walk(node.id, Math.min(depth + 1, 6));
    }
  }

  walk('__root__', 0);

  for (const f of folders) {
    if (!visited.has(f.id)) {
      options.push({
        id: f.id,
        name: f.name,
        depth: 0,
        label: f.name,
      });
    }
  }

  return options;
}
