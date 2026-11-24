/**
 * Charkle API client for Chrome & Safari Browser Extension.
 * Supports both Charkle macOS Desktop Bridge (`http://127.0.0.1:41937`) and Charkle Web servers.
 */

import {
  deriveImageFileName,
  normalizeHexColor,
  normalizeServerUrl,
} from './url-detect.js';

const DEFAULT_TIMEOUT_MS = 28_000;
const MAX_JSON_IMAGE_BYTES = 14 * 1024 * 1024;
const MAX_FETCH_IMAGE_BYTES = 35 * 1024 * 1024;

export class CharkleApiError extends Error {
  constructor(message, { status = 0, code = 'API_ERROR', cause = null } = {}) {
    super(message);
    this.name = 'CharkleApiError';
    this.status = status;
    this.code = code;
    if (cause) this.cause = cause;
  }
}

function resolveEndpoint(config, pathname) {
  const base = normalizeServerUrl(config?.serverUrl);
  if (!base) {
    throw new CharkleApiError('请先填写有效的服务地址（例如 http://127.0.0.1:41937）。', {
      code: 'INVALID_SERVER_URL',
    });
  }
  const token = String(config?.apiToken ?? '').trim();
  if (!token) {
    throw new CharkleApiError('请先填写访问令牌。', {
      code: 'MISSING_TOKEN',
    });
  }
  return {
    url: `${base}${pathname}`,
    token,
  };
}

async function fetchWithTimeout(fetchImpl, url, init = {}, timeoutMs = DEFAULT_TIMEOUT_MS) {
  const controller = new AbortController();
  const timer = setTimeout(() => controller.abort(), timeoutMs);
  try {
    return await fetchImpl(url, {
      ...init,
      signal: controller.signal,
    });
  } catch (err) {
    if (err && err.name === 'AbortError') {
      throw new CharkleApiError('请求超时，请检查 Charkle 是否已运行或网络连接是否正常。', {
        code: 'TIMEOUT',
        cause: err,
      });
    }
    throw new CharkleApiError('无法连接到 Charkle，请确认 Charkle 桌面端或服务端已启动。', {
      code: 'NETWORK_ERROR',
      cause: err,
    });
  } finally {
    clearTimeout(timer);
  }
}

async function requestJson(
  config,
  pathname,
  { method = 'GET', body, timeoutMs = DEFAULT_TIMEOUT_MS, fetchImpl = globalThis.fetch } = {},
) {
  const { url, token } = resolveEndpoint(config, pathname);
  const headers = {
    Authorization: `Bearer ${token}`,
    Accept: 'application/json',
  };
  const init = { method, headers };
  if (body !== undefined) {
    headers['Content-Type'] = 'application/json';
    init.body = JSON.stringify(body);
  }

  const res = await fetchWithTimeout(fetchImpl, url, init, timeoutMs);
  const text = await res.text();
  let data = null;
  if (text) {
    try {
      data = JSON.parse(text);
    } catch {
      data = null;
    }
  }

  if (!res.ok) {
    const serverMsg = data && typeof data.error === 'string' ? data.error : '';
    const code = data && typeof data.code === 'string' ? data.code : `HTTP_${res.status}`;
    if (res.status === 401) {
      throw new CharkleApiError(serverMsg || '访问令牌无效或已过期，请在设置中重新配置。', {
        status: 401,
        code,
      });
    }
    throw new CharkleApiError(serverMsg || `连接失败（${res.status}）`, {
      status: res.status,
      code,
    });
  }

  if (data === null) {
    throw new CharkleApiError('无法识别该服务地址，请检查设置', {
      status: res.status,
      code: 'INVALID_RESPONSE',
    });
  }

  return data;
}

export function arrayBufferToBase64(buffer) {
  const bytes = new Uint8Array(buffer);
  const chunkSize = 0x8000;
  let binary = '';
  for (let i = 0; i < bytes.length; i += chunkSize) {
    const slice = bytes.subarray(i, Math.min(i + chunkSize, bytes.length));
    binary += String.fromCharCode(...slice);
  }
  return btoa(binary);
}

export const DEFAULT_DESKTOP_PROBE_PORTS = Object.freeze([
  41937, 41938, 41939, 41940, 41941, 41942, 41943, 41944, 41945, 41946,
]);

/**
 * Probes loopback ports (default 41937..41946, matching LocalExtensionBridgeServer.swift)
 * for a running Charkle macOS desktop app.
 */
export async function probeLocalDesktop(opts = {}) {
  const fetchImpl = opts.fetchImpl ?? globalThis.fetch;
  const ports = Array.isArray(opts.ports) ? opts.ports : DEFAULT_DESKTOP_PROBE_PORTS;
  for (const port of ports) {
    const baseUrl = `http://127.0.0.1:${port}`;
    try {
      const res = await fetchWithTimeout(
        fetchImpl,
        `${baseUrl}/api/v1/health`,
        { method: 'GET', headers: { Accept: 'application/json' } },
        1200,
      );
      if (!res.ok) continue;
      const data = await res.json().catch(() => null);
      if (data && data.ok === true && String(data.app || '').startsWith('charkle')) {
        return {
          found: true,
          serverUrl: baseUrl,
          app: data.app,
          name: data.name || 'Charkle 桌面端',
          port,
          autoPair: data.autoPair !== false,
        };
      }
    } catch {
      // probe next port
    }
  }
  return { found: false, serverUrl: null, autoPair: false };
}

/**
 * Zero-config same-machine pairing with a running Charkle desktop bridge on 127.0.0.1.
 * The desktop server strictly validates the browser extension Origin and `X-Charkle-Extension: 1` header.
 */
export async function autoPairLocalDesktop(opts = {}) {
  const fetchImpl = opts.fetchImpl ?? globalThis.fetch;
  const probe = await probeLocalDesktop(opts);
  if (!probe.found || !probe.serverUrl) {
    return {
      paired: false,
      foundDesktop: false,
      serverUrl: null,
      reason: 'DESKTOP_NOT_RUNNING',
      error: '未检测到运行中的 Charkle 桌面端，请先打开 Mac 上的 Charkle 应用。',
    };
  }
  if (probe.autoPair === false) {
    return {
      paired: false,
      foundDesktop: true,
      serverUrl: probe.serverUrl,
      name: probe.name,
      port: probe.port,
      reason: 'AUTO_PAIR_DISABLED',
      error: '已检测到 Charkle 桌面端，但你关闭了「同机扩展自动免密配对」，请在设置开启或手动填入令牌。',
    };
  }

  try {
    const res = await fetchWithTimeout(
      fetchImpl,
      `${probe.serverUrl}/api/v1/auth/local-pair`,
      {
        method: 'POST',
        headers: {
          Accept: 'application/json',
          'X-Charkle-Extension': '1',
        },
      },
      3000,
    );
    const data = await res.json().catch(() => null);
    if (res.ok && data && data.ok === true && typeof data.token === 'string' && data.token.trim()) {
      return {
        paired: true,
        foundDesktop: true,
        serverUrl: data.serverUrl || probe.serverUrl,
        token: data.token.trim(),
        app: data.app || probe.app,
        name: data.name || probe.name,
        port: data.port || probe.port,
      };
    }
    return {
      paired: false,
      foundDesktop: true,
      serverUrl: probe.serverUrl,
      name: probe.name,
      port: probe.port,
      reason: (data && data.code) || `HTTP_${res.status}`,
      error: (data && data.error) || '自动配对未通过，请展开下方手动粘贴访问令牌。',
    };
  } catch (err) {
    return {
      paired: false,
      foundDesktop: true,
      serverUrl: probe.serverUrl,
      name: probe.name,
      port: probe.port,
      reason: 'PAIR_NETWORK_ERROR',
      error: err instanceof Error ? err.message : '无法完成自动配对，请重试或手动填入令牌。',
    };
  }
}

/**
 * Tests connection against GET /api/v1/auth/status + GET /api/v1/folders + GET /api/v1/boards.
 */
export async function testConnection(config, opts = {}) {
  const fetchImpl = opts.fetchImpl ?? globalThis.fetch;
  const status = await requestJson(config, '/api/v1/auth/status', {
    method: 'GET',
    timeoutMs: 10_000,
    fetchImpl,
  });

  if (!status.initialized) {
    throw new CharkleApiError('服务尚未完成初始化，请先在 Charkle 创建账号。', {
      status: 400,
      code: 'NOT_INITIALIZED',
    });
  }
  if (!status.authenticated) {
    throw new CharkleApiError('访问令牌无效或已撤销，请在 Charkle 设置中重新复制或生成。', {
      status: 401,
      code: 'UNAUTHORIZED',
    });
  }

  const [foldersRes, boardsRes] = await Promise.all([
    requestJson(config, '/api/v1/folders', { method: 'GET', timeoutMs: 12_000, fetchImpl }),
    requestJson(config, '/api/v1/boards', { method: 'GET', timeoutMs: 12_000, fetchImpl }),
  ]);

  return {
    ok: true,
    status,
    user: status.user ?? null,
    folders: Array.isArray(foldersRes.folders) ? foldersRes.folders : [],
    boards: Array.isArray(boardsRes.boards) ? boardsRes.boards : [],
  };
}

/**
 * Creates (or reuses an existing) folder by name for one-click bookmark collection organization.
 */
export async function createOrReuseFolder(config, name, parentId = null, opts = {}) {
  const cleanName = String(name ?? '').trim();
  if (!cleanName) {
    throw new CharkleApiError('请填写文件夹名称。', { code: 'INVALID_NAME' });
  }
  return requestJson(config, '/api/v1/folders', {
    method: 'POST',
    body: {
      name: cleanName,
      parentID: parentId || null,
      reuseExisting: opts.reuseExisting !== false,
    },
    timeoutMs: 12_000,
    fetchImpl: opts.fetchImpl ?? globalThis.fetch,
  });
}

/**
 * Fetches existing asset canonical dedup keys (`x:<tweetID>`, `xhs:<noteID>`, etc.) for incremental sync.
 * Gracefully degrades to empty sets on older servers without this endpoint.
 */
export async function fetchExistingSources(config, opts = {}) {
  try {
    const res = await requestJson(config, '/api/v1/assets/existing-sources', {
      method: 'GET',
      timeoutMs: 12_000,
      fetchImpl: opts.fetchImpl ?? globalThis.fetch,
    });
    return {
      supported: true,
      sources: Array.isArray(res.sources) ? res.sources : [],
      canonicalKeys: Array.isArray(res.canonicalKeys) ? res.canonicalKeys : [],
    };
  } catch (err) {
    if (err instanceof CharkleApiError && (err.status === 404 || err.status === 405)) {
      return { supported: false, sources: [], canonicalKeys: [] };
    }
    throw err;
  }
}

/**
 * Ingests a URL via POST /api/v1/assets/ingest.
 */
export async function ingestUrl(
  config,
  url,
  title = '',
  notes = '',
  targetFolderId = null,
  targetBoardId = null,
  opts = {},
) {
  const cleanUrl = String(url ?? '').trim();
  if (!/^https?:\/\//i.test(cleanUrl)) {
    throw new CharkleApiError('仅支持普通网页链接', {
      code: 'INVALID_URL',
    });
  }

  return requestJson(config, '/api/v1/assets/ingest', {
    method: 'POST',
    body: {
      inputs: [
        {
          type: 'webURL',
          url: cleanUrl,
          title: String(title ?? '').trim() || null,
          notes: String(notes ?? '').trim() || null,
        },
      ],
      targetFolderID: targetFolderId || null,
      targetBoardID: targetBoardId || null,
      skipDuplicates: Boolean(opts.skipDuplicates),
    },
    timeoutMs: 45_000,
    fetchImpl: opts.fetchImpl ?? globalThis.fetch,
  });
}

/**
 * Ingests one or more rich social bookmarks (X / Xiaohongshu) in a single chunk,
 * automatically falling back to `webURL` inputs when connected to an older Charkle Web server.
 */
export async function ingestSocialBookmarksChunk(
  config,
  bookmarks,
  targetFolderId = null,
  targetBoardId = null,
  opts = {},
) {
  const list = Array.isArray(bookmarks) ? bookmarks.filter((b) => b && b.originalURL) : [];
  if (list.length === 0) {
    return { assets: [], created: 0, skipped: 0 };
  }

  const fetchImpl = opts.fetchImpl ?? globalThis.fetch;
  const skipDuplicates = opts.skipDuplicates !== false;

  try {
    const res = await requestJson(config, '/api/v1/assets/ingest', {
      method: 'POST',
      body: {
        inputs: list.map((item) => ({
          ...item,
          type: 'socialBookmark',
        })),
        targetFolderID: targetFolderId || null,
        targetBoardID: targetBoardId || null,
        skipDuplicates,
      },
      timeoutMs: 65_000,
      fetchImpl,
    });
    const assets = Array.isArray(res.assets) ? res.assets : [];
    return {
      assets,
      created: typeof res.created === 'number' ? res.created : assets.length,
      skipped: typeof res.skipped === 'number' ? res.skipped : 0,
    };
  } catch (err) {
    // Graceful fallback if connected to an older Charkle Web server that only accepts `webURL`.
    if (err instanceof CharkleApiError && err.status === 400) {
      const res = await requestJson(config, '/api/v1/assets/ingest', {
        method: 'POST',
        body: {
          inputs: list.map((item) => ({
            type: 'webURL',
            url: item.originalURL,
            title: item.articleTitle || item.authorName || null,
            notes: item.bodyText || null,
          })),
          targetFolderID: targetFolderId || null,
          targetBoardID: targetBoardId || null,
        },
        timeoutMs: 65_000,
        fetchImpl,
      });
      const assets = Array.isArray(res.assets) ? res.assets : [];
      return { assets, created: assets.length, skipped: 0 };
    }
    throw err;
  }
}

export async function ingestImageDataUrl(
  config,
  dataUrl,
  fileName = '页面截屏.png',
  sourceUrl = null,
  targetFolderId = null,
  targetBoardId = null,
  opts = {},
) {
  const raw = String(dataUrl ?? '').trim();
  if (!raw) {
    throw new CharkleApiError('图片数据为空，无法收藏。', { code: 'EMPTY_IMAGE' });
  }

  return requestJson(config, '/api/v1/assets/ingest', {
    method: 'POST',
    body: {
      inputs: [
        {
          type: 'imageData',
          base64Data: raw,
          suggestedName: String(fileName || '页面截屏.png'),
          sourceURL: sourceUrl || null,
        },
      ],
      targetFolderID: targetFolderId || null,
      targetBoardID: targetBoardId || null,
    },
    timeoutMs: 35_000,
    fetchImpl: opts.fetchImpl ?? globalThis.fetch,
  });
}

async function uploadImageBlobMultipart(
  config,
  blob,
  fileName,
  sourcePageUrl,
  targetFolderId,
  targetBoardId,
  fetchImpl,
) {
  const { url, token } = resolveEndpoint(config, '/api/v1/assets/upload');
  const form = new FormData();
  form.append('file', blob, fileName);
  if (targetFolderId) form.append('targetFolderID', targetFolderId);
  if (targetBoardId) form.append('targetBoardID', targetBoardId);
  if (sourcePageUrl) form.append('sourceURL', sourcePageUrl);

  const res = await fetchWithTimeout(
    fetchImpl,
    url,
    {
      method: 'POST',
      headers: {
        Authorization: `Bearer ${token}`,
        Accept: 'application/json',
      },
      body: form,
    },
    45_000,
  );

  const data = await res.json().catch(() => null);
  if (!res.ok) {
    throw new CharkleApiError(data?.error || `上传图片失败（${res.status}）`, {
      status: res.status,
      code: data?.code || `HTTP_${res.status}`,
    });
  }
  return data;
}

async function fetchImageBytes(imageUrl, fetchImpl) {
  const attempts = [
    { credentials: 'omit', redirect: 'follow' },
    { credentials: 'include', redirect: 'follow' },
  ];

  let lastError = null;
  for (const init of attempts) {
    try {
      const res = await fetchWithTimeout(fetchImpl, imageUrl, init, 20_000);
      if (!res.ok) {
        lastError = new Error(`HTTP ${res.status}`);
        continue;
      }
      const contentType = (res.headers.get('content-type') || '').split(';')[0].trim().toLowerCase();
      if (contentType && (contentType.startsWith('text/html') || contentType === 'application/json')) {
        lastError = new Error(`Unexpected content-type: ${contentType}`);
        continue;
      }
      const buffer = await res.arrayBuffer();
      if (!buffer || buffer.byteLength === 0) {
        lastError = new Error('Empty image body');
        continue;
      }
      if (buffer.byteLength > MAX_FETCH_IMAGE_BYTES) {
        throw new CharkleApiError('图片体积超过 35MB 限制。', { code: 'IMAGE_TOO_LARGE' });
      }
      return {
        buffer,
        mimeType: contentType.startsWith('image/') ? contentType : '',
      };
    } catch (err) {
      if (err instanceof CharkleApiError && err.code === 'IMAGE_TOO_LARGE') {
        throw err;
      }
      lastError = err;
    }
  }
  throw lastError || new Error('Failed to fetch image');
}

export async function ingestImageUrl(
  config,
  imageUrl,
  sourcePageUrl = null,
  title = '',
  targetFolderId = null,
  targetBoardId = null,
  opts = {},
) {
  const fetchImpl = opts.fetchImpl ?? globalThis.fetch;
  const cleanImageUrl = String(imageUrl ?? '').trim();
  if (!cleanImageUrl) {
    throw new CharkleApiError('缺少图片链接。', { code: 'INVALID_IMAGE_URL' });
  }

  if (cleanImageUrl.startsWith('data:image/')) {
    const mimeMatch = /^data:(image\/[a-z0-9.+-]+);/i.exec(cleanImageUrl);
    const fileName = deriveImageFileName('', title, mimeMatch ? mimeMatch[1] : 'image/png');
    return ingestImageDataUrl(
      config,
      cleanImageUrl,
      fileName,
      sourcePageUrl || null,
      targetFolderId,
      targetBoardId,
      { fetchImpl },
    );
  }

  let fetched = null;
  try {
    fetched = await fetchImageBytes(cleanImageUrl, fetchImpl);
  } catch (err) {
    if (err instanceof CharkleApiError && err.code === 'IMAGE_TOO_LARGE') {
      throw err;
    }
    const notes = sourcePageUrl ? `来源页面：${sourcePageUrl}` : '';
    return ingestUrl(config, cleanImageUrl, title, notes, targetFolderId, targetBoardId, {
      fetchImpl,
    });
  }

  const fileName = deriveImageFileName(cleanImageUrl, title, fetched.mimeType);
  const effectiveSource = sourcePageUrl || cleanImageUrl;

  if (fetched.buffer.byteLength <= MAX_JSON_IMAGE_BYTES) {
    const b64 = arrayBufferToBase64(fetched.buffer);
    const dataUrl = `data:${fetched.mimeType || 'image/png'};base64,${b64}`;
    try {
      return await ingestImageDataUrl(
        config,
        dataUrl,
        fileName,
        effectiveSource,
        targetFolderId,
        targetBoardId,
        { fetchImpl },
      );
    } catch (err) {
      if (!(err instanceof CharkleApiError && err.status === 413)) {
        throw err;
      }
    }
  }

  const blob = new Blob([fetched.buffer], {
    type: fetched.mimeType || 'application/octet-stream',
  });
  return uploadImageBlobMultipart(
    config,
    blob,
    fileName,
    effectiveSource,
    targetFolderId,
    targetBoardId,
    fetchImpl,
  );
}

export async function ingestTextSnippet(
  config,
  title,
  text,
  sourceUrl = null,
  targetFolderId = null,
  targetBoardId = null,
  opts = {},
) {
  const cleanText = String(text ?? '').trim();
  if (!cleanText) {
    throw new CharkleApiError('请输入要收藏的文字内容。', { code: 'EMPTY_TEXT' });
  }
  const cleanTitle = String(title ?? '').trim() || '文字灵感';

  return requestJson(config, '/api/v1/assets/ingest', {
    method: 'POST',
    body: {
      inputs: [
        {
          type: 'textSnippet',
          title: cleanTitle,
          text: cleanText,
          sourceURL: sourceUrl || null,
        },
      ],
      targetFolderID: targetFolderId || null,
      targetBoardID: targetBoardId || null,
    },
    timeoutMs: 25_000,
    fetchImpl: opts.fetchImpl ?? globalThis.fetch,
  });
}

export async function ingestColorSwatch(
  config,
  hex,
  title = '',
  targetFolderId = null,
  targetBoardId = null,
  opts = {},
) {
  const normalized = normalizeHexColor(hex);
  if (!normalized) {
    throw new CharkleApiError('请输入有效的 HEX 颜色值（例如 #2A60E0）。', {
      code: 'INVALID_HEX',
    });
  }

  return requestJson(config, '/api/v1/assets/ingest', {
    method: 'POST',
    body: {
      inputs: [
        {
          type: 'colorSwatch',
          hex: normalized,
          title: String(title ?? '').trim() || normalized,
        },
      ],
      targetFolderID: targetFolderId || null,
      targetBoardID: targetBoardId || null,
    },
    timeoutMs: 20_000,
    fetchImpl: opts.fetchImpl ?? globalThis.fetch,
  });
}

export async function ingestImageUrlsBatch(
  config,
  items,
  sourcePageUrl = null,
  targetFolderId = null,
  targetBoardId = null,
  opts = {},
) {
  const list = Array.isArray(items) ? items : [];
  const concurrency = Math.max(1, Math.min(4, opts.concurrency ?? 3));
  const onProgress = typeof opts.onProgress === 'function' ? opts.onProgress : null;
  const fetchImpl = opts.fetchImpl ?? globalThis.fetch;

  const assets = [];
  const errors = [];
  let completed = 0;
  let cursor = 0;

  async function worker() {
    while (cursor < list.length) {
      const idx = cursor++;
      const item = list[idx];
      const url = typeof item === 'string' ? item : item?.url;
      const title = typeof item === 'string' ? '' : item?.title || item?.alt || '';
      try {
        const res = await ingestImageUrl(
          config,
          url,
          sourcePageUrl,
          title,
          targetFolderId,
          targetBoardId,
          { fetchImpl },
        );
        if (Array.isArray(res?.assets)) {
          assets.push(...res.assets);
        }
      } catch (err) {
        errors.push({
          url,
          message: err instanceof Error ? err.message : '收藏失败',
          ...(typeof err?.status === 'number' ? { status: err.status } : {}),
          ...(typeof err?.code === 'string' ? { code: err.code } : {}),
        });
      } finally {
        completed++;
        if (onProgress) {
          onProgress({ completed, total: list.length, succeeded: assets.length, failed: errors.length });
        }
      }
    }
  }

  const workers = Array.from({ length: Math.min(concurrency, Math.max(1, list.length)) }, () =>
    worker(),
  );
  await Promise.all(workers);

  return {
    total: list.length,
    succeeded: assets.length,
    failed: errors.length,
    assets,
    errors,
  };
}

export function createCharkleClient(config, opts = {}) {
  return {
    probeLocalDesktop: () => probeLocalDesktop(opts),
    autoPairLocalDesktop: () => autoPairLocalDesktop(opts),
    testConnection: () => testConnection(config, opts),
    createOrReuseFolder: (name, parentId, extraOpts) =>
      createOrReuseFolder(config, name, parentId, { ...opts, ...extraOpts }),
    fetchExistingSources: () => fetchExistingSources(config, opts),
    ingestUrl: (url, title, notes, targetFolderId, targetBoardId, extraOpts) =>
      ingestUrl(config, url, title, notes, targetFolderId, targetBoardId, { ...opts, ...extraOpts }),
    ingestSocialBookmarksChunk: (bookmarks, targetFolderId, targetBoardId, extraOpts) =>
      ingestSocialBookmarksChunk(config, bookmarks, targetFolderId, targetBoardId, { ...opts, ...extraOpts }),
    ingestImageUrl: (imageUrl, sourcePageUrl, title, targetFolderId, targetBoardId) =>
      ingestImageUrl(config, imageUrl, sourcePageUrl, title, targetFolderId, targetBoardId, opts),
    ingestImageDataUrl: (dataUrl, fileName, sourceUrl, targetFolderId, targetBoardId) =>
      ingestImageDataUrl(config, dataUrl, fileName, sourceUrl, targetFolderId, targetBoardId, opts),
    ingestTextSnippet: (title, text, sourceUrl, targetFolderId, targetBoardId) =>
      ingestTextSnippet(config, title, text, sourceUrl, targetFolderId, targetBoardId, opts),
    ingestColorSwatch: (hex, title, targetFolderId, targetBoardId) =>
      ingestColorSwatch(config, hex, title, targetFolderId, targetBoardId, opts),
    ingestImageUrlsBatch: (items, sourcePageUrl, targetFolderId, targetBoardId, extraOpts) =>
      ingestImageUrlsBatch(config, items, sourcePageUrl, targetFolderId, targetBoardId, {
        ...opts,
        ...extraOpts,
      }),
  };
}
