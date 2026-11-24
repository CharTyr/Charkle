/**
 * Charkle Extension — Options Page Controller (Chrome & Safari)
 */

import {
  buildFolderOptions,
  DEFAULT_DESKTOP_SERVER_URL,
  getConfig,
  isConfigured,
} from './lib/storage.js';

const ext = globalThis.browser ?? globalThis.chrome;
const $ = (id) => document.getElementById(id);

let currentConfig = null;
let selectedConnectionMode = 'desktop';

function isSafariExtension() {
  try {
    return ext.runtime.getURL('').startsWith('safari-web-extension://');
  } catch {
    return false;
  }
}

function sendBg(payload) {
  return ext.runtime.sendMessage(payload);
}

function setHeaderStatus(state, text) {
  const pill = $('header-conn-pill');
  pill.dataset.state = state;
  $('header-conn-text').textContent = text;
}

function showFeedback(variant, message) {
  const box = $('conn-feedback');
  box.dataset.variant = variant;
  box.textContent = message;
  box.hidden = false;
}

function renderConnectionMode() {
  for (const btn of document.querySelectorAll('.seg-btn[data-conn-mode]')) {
    btn.setAttribute('aria-checked', String(btn.dataset.connMode === selectedConnectionMode));
  }
  const urlInput = $('opt-server-url');
  urlInput.placeholder =
    selectedConnectionMode === 'desktop' ? DEFAULT_DESKTOP_SERVER_URL : 'http://127.0.0.1:3417';
}

function renderAll() {
  const cfg = currentConfig;
  if (!cfg) return;

  selectedConnectionMode = cfg.connectionMode || 'desktop';
  renderConnectionMode();

  $('opt-server-url').value = cfg.serverUrl || DEFAULT_DESKTOP_SERVER_URL;
  $('opt-api-token').value = cfg.apiToken || '';

  const openWebBtn = $('btn-open-charkle');
  openWebBtn.hidden = !cfg.serverUrl || cfg.connectionMode === 'desktop';

  if (isConfigured(cfg)) {
    const userLabel = cfg.lastConnectedUser?.displayName || cfg.lastConnectedUser?.username || '已连接';
    setHeaderStatus('connected', userLabel);
  } else {
    setHeaderStatus('idle', '未连接');
  }

  $('switch-drag-drop').setAttribute('aria-checked', String(cfg.enableDragDrop !== false));
  $('switch-bookmark-btn').setAttribute(
    'aria-checked',
    String(cfg.enableBookmarkFloatingButton !== false),
  );

  renderTargetSection();
}

function renderTargetSection() {
  const cfg = currentConfig;
  if (!cfg) return;

  const mode = cfg.targetMode || 'inbox';
  for (const btn of document.querySelectorAll('.seg-btn[data-target-mode]')) {
    btn.setAttribute('aria-checked', String(btn.dataset.targetMode === mode));
  }

  $('opt-folder-wrap').hidden = mode !== 'folder';
  $('opt-board-wrap').hidden = mode !== 'board';

  const folderSelect = $('opt-select-folder');
  const folderOptions = buildFolderOptions(cfg.cachedFolders || []);
  folderSelect.innerHTML = '';
  if (folderOptions.length === 0) {
    const opt = document.createElement('option');
    opt.value = '';
    opt.textContent = '暂无文件夹';
    folderSelect.appendChild(opt);
    folderSelect.disabled = true;
  } else {
    folderSelect.disabled = false;
    for (const item of folderOptions) {
      const opt = document.createElement('option');
      opt.value = item.id;
      opt.textContent = item.label;
      if (item.id === cfg.targetFolderId) opt.selected = true;
      folderSelect.appendChild(opt);
    }
  }

  const boardSelect = $('opt-select-board');
  const boards = Array.isArray(cfg.cachedBoards) ? cfg.cachedBoards : [];
  boardSelect.innerHTML = '';
  if (boards.length === 0) {
    const opt = document.createElement('option');
    opt.value = '';
    opt.textContent = '暂无情绪板';
    boardSelect.appendChild(opt);
    boardSelect.disabled = true;
  } else {
    boardSelect.disabled = false;
    for (const board of boards) {
      const opt = document.createElement('option');
      opt.value = board.id;
      const countSuffix = typeof board.itemCount === 'number' ? ` (${board.itemCount})` : '';
      opt.textContent = `${board.title}${countSuffix}`;
      if (board.id === cfg.targetBoardId) opt.selected = true;
      boardSelect.appendChild(opt);
    }
  }
}

async function runConnectionTest(shouldSave) {
  const serverUrl = $('opt-server-url').value.trim();
  const apiToken = $('opt-api-token').value.trim();
  if (!serverUrl || !apiToken) {
    showFeedback('error', '请填写服务地址与访问令牌。');
    return;
  }

  const testBtn = $('btn-test-conn');
  const saveBtn = $('btn-save-conn');
  testBtn.disabled = true;
  saveBtn.disabled = true;
  setHeaderStatus('checking', '验证中…');

  try {
    const res = await sendBg({
      type: 'TEST_CONNECTION',
      connectionMode: selectedConnectionMode,
      serverUrl,
      apiToken,
      save: shouldSave,
    });
    if (res?.ok) {
      if (shouldSave && res.config) {
        currentConfig = res.config;
        renderAll();
      }
      const who = res.user?.displayName || res.user?.username || '已连接';
      setHeaderStatus('connected', who);
      showFeedback(
        'success',
        `${shouldSave ? '已保存并连接' : '连接成功'}：${who}（${res.folders.length} 个文件夹，${res.boards.length} 个情绪板）`,
      );
    } else {
      setHeaderStatus('error', '连接失败');
      showFeedback('error', res?.error || '连接失败，请核对服务地址与访问令牌。');
    }
  } catch (err) {
    setHeaderStatus('error', '连接失败');
    showFeedback('error', err instanceof Error ? err.message : '连接失败');
  } finally {
    testBtn.disabled = false;
    saveBtn.disabled = false;
  }
}

async function handleDetectDesktop() {
  const btn = $('btn-detect-desktop');
  btn.disabled = true;
  btn.textContent = '正在自动连接…';
  setHeaderStatus('checking', '连接中…');
  try {
    const res = await sendBg({ type: 'AUTO_PAIR_LOCAL_DESKTOP', force: true });
    if (res?.ok && res.config) {
      currentConfig = res.config;
      renderAll();
      const who = res.user?.displayName || res.user?.username || 'Charkle macOS';
      setHeaderStatus('connected', who);
      showFeedback(
        'success',
        `已自动免密连接本机 ${who}（同步了 ${res.folders?.length || 0} 个文件夹、${res.boards?.length || 0} 个情绪板）`,
      );
    } else if (res?.foundDesktop && res.serverUrl) {
      selectedConnectionMode = 'desktop';
      renderConnectionMode();
      $('opt-server-url').value = res.serverUrl;
      setHeaderStatus('idle', '待手动填写令牌');
      showFeedback(
        'error',
        res.error || '已检测到 Charkle 桌面端，但关闭了自动免密配对，请在设置开启或粘贴令牌。',
      );
    } else {
      setHeaderStatus('error', '未检测到桌面端');
      showFeedback(
        'error',
        res?.error || '未检测到运行中的 Charkle 桌面端，请先打开 Mac 上的 Charkle 应用并确认本地连接桥接已开启。',
      );
    }
  } finally {
    btn.disabled = false;
    btn.textContent = '一键连接本机桌面端';
  }
}

async function persistPatch(patch) {
  const res = await sendBg({ type: 'SET_TARGET', ...patch });
  if (res?.ok && res.config) {
    currentConfig = res.config;
    renderTargetSection();
    $('switch-drag-drop').setAttribute('aria-checked', String(currentConfig.enableDragDrop !== false));
    $('switch-bookmark-btn').setAttribute(
      'aria-checked',
      String(currentConfig.enableBookmarkFloatingButton !== false),
    );
  }
}

function bindEvents() {
  if (isSafariExtension()) {
    $('shortcuts-footer').hidden = true;
  }

  $('btn-open-charkle').addEventListener('click', () => {
    if (currentConfig?.serverUrl) {
      ext.tabs.create({ url: currentConfig.serverUrl });
    }
  });

  $('btn-detect-desktop').addEventListener('click', () => {
    void handleDetectDesktop();
  });

  for (const btn of document.querySelectorAll('.seg-btn[data-conn-mode]')) {
    btn.addEventListener('click', () => {
      selectedConnectionMode = btn.dataset.connMode === 'web' ? 'web' : 'desktop';
      renderConnectionMode();
      const input = $('opt-server-url');
      if (selectedConnectionMode === 'desktop' && (!input.value || input.value.includes(':3417'))) {
        input.value = DEFAULT_DESKTOP_SERVER_URL;
      } else if (selectedConnectionMode === 'web' && input.value === DEFAULT_DESKTOP_SERVER_URL) {
        input.value = 'http://127.0.0.1:3417';
      }
    });
  }

  $('btn-toggle-token').addEventListener('click', () => {
    const input = $('opt-api-token');
    input.type = input.type === 'password' ? 'text' : 'password';
  });

  $('btn-test-conn').addEventListener('click', () => {
    void runConnectionTest(false);
  });

  $('connection-form').addEventListener('submit', (e) => {
    e.preventDefault();
    void runConnectionTest(true);
  });

  $('btn-sync-targets').addEventListener('click', async () => {
    const btn = $('btn-sync-targets');
    btn.disabled = true;
    btn.textContent = '刷新中…';
    try {
      const res = await sendBg({ type: 'REFRESH_TARGETS' });
      if (res?.ok && res.config) {
        currentConfig = res.config;
        renderAll();
        showFeedback(
          'success',
          `已刷新目标列表：${res.folders.length} 个文件夹、${res.boards.length} 个情绪板`,
        );
      } else {
        showFeedback('error', res?.error || '刷新失败，请先保存有效连接配置。');
      }
    } finally {
      btn.disabled = false;
      btn.textContent = '刷新列表';
    }
  });

  for (const btn of document.querySelectorAll('.seg-btn[data-target-mode]')) {
    btn.addEventListener('click', async () => {
      const mode = btn.dataset.targetMode;
      const patch = { targetMode: mode };
      if (mode === 'folder' && !currentConfig?.targetFolderId && currentConfig?.cachedFolders?.[0]) {
        patch.targetFolderId = currentConfig.cachedFolders[0].id;
        patch.targetFolderName = currentConfig.cachedFolders[0].name;
      }
      if (mode === 'board' && !currentConfig?.targetBoardId && currentConfig?.cachedBoards?.[0]) {
        patch.targetBoardId = currentConfig.cachedBoards[0].id;
        patch.targetBoardName = currentConfig.cachedBoards[0].title;
      }
      await persistPatch(patch);
    });
  }

  $('opt-select-folder').addEventListener('change', async (e) => {
    const id = e.target.value || null;
    const matched = (currentConfig?.cachedFolders || []).find((f) => f.id === id);
    await persistPatch({
      targetMode: 'folder',
      targetFolderId: id,
      targetFolderName: matched?.name || '',
    });
  });

  $('opt-select-board').addEventListener('change', async (e) => {
    const id = e.target.value || null;
    const matched = (currentConfig?.cachedBoards || []).find((b) => b.id === id);
    await persistPatch({
      targetMode: 'board',
      targetBoardId: id,
      targetBoardName: matched?.title || '',
    });
  });

  $('switch-drag-drop').addEventListener('click', async () => {
    const nextEnabled = !(currentConfig?.enableDragDrop !== false);
    await persistPatch({ enableDragDrop: nextEnabled });
  });

  $('switch-bookmark-btn').addEventListener('click', async () => {
    const nextEnabled = !(currentConfig?.enableBookmarkFloatingButton !== false);
    await persistPatch({ enableBookmarkFloatingButton: nextEnabled });
  });

  $('btn-open-shortcuts').addEventListener('click', () => {
    Promise.resolve(ext.tabs.create({ url: 'chrome://extensions/shortcuts' })).catch(() => {});
  });
}

async function init() {
  bindEvents();
  currentConfig = await getConfig();
  renderAll();
  if (isConfigured(currentConfig)) {
    const res = await sendBg({ type: 'REFRESH_TARGETS' }).catch(() => null);
    if (res?.ok && res.config) {
      currentConfig = res.config;
      renderAll();
    }
  } else if (currentConfig.connectionMode !== 'web') {
    const paired = await sendBg({ type: 'AUTO_PAIR_LOCAL_DESKTOP', force: false }).catch(() => null);
    if (paired?.ok && paired.config) {
      currentConfig = paired.config;
      renderAll();
      showFeedback('success', '已自动免密连接本机 Charkle 桌面端，无需手动填写令牌。');
    }
  }
}

void init();
