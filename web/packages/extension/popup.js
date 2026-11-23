/**
 * Charkle Extension — Popup Controller
 */

import { isLargeImageCandidate } from './lib/image-filter.js';
import {
  buildFolderOptions,
  getConfig,
  isConfigured,
  resolveActiveTarget,
} from './lib/storage.js';
import {
  detectSpecialSource,
  isCapturablePageUrl,
  isLightHex,
  normalizeHexColor,
} from './lib/url-detect.js';

const $ = (id) => document.getElementById(id);

const state = {
  config: null,
  activeTab: null,
  pageContext: null,
  activePanel: 'page',
  scannedImages: [],
  selectedImageUrls: new Set(),
  imagesScanned: false,
  isBusy: false,
  currentHex: '#2A60E0',
};

let statusTimer = null;

function sendBg(payload) {
  return chrome.runtime.sendMessage(payload);
}

async function queryTabContent(tab, message) {
  if (!tab?.id || !isCapturablePageUrl(tab.url)) return null;
  try {
    return await chrome.tabs.sendMessage(tab.id, message);
  } catch {
    // Lazily inject content.js for tabs opened prior to extension install
    const ensured = await sendBg({
      type: 'ENSURE_CONTENT_SCRIPT',
      tabId: tab.id,
      tabUrl: tab.url,
    }).catch(() => ({ ok: false }));
    if (!ensured?.ok) return null;
    try {
      return await chrome.tabs.sendMessage(tab.id, message);
    } catch {
      return null;
    }
  }
}

// MARK: - Status & Header Helpers

function setConnectionIndicator(connState, label) {
  const pill = $('conn-pill');
  const labelEl = $('conn-label');
  pill.dataset.state = connState;
  labelEl.textContent = label;
}

function showStatus(variant, text, autoHideMs = 3400) {
  const banner = $('status-banner');
  const textEl = $('status-banner-text');
  if (statusTimer) {
    clearTimeout(statusTimer);
    statusTimer = null;
  }
  banner.dataset.variant = variant;
  textEl.textContent = text;
  banner.hidden = false;
  if (autoHideMs > 0) {
    statusTimer = setTimeout(() => {
      banner.hidden = true;
      statusTimer = null;
    }, autoHideMs);
  }
}

function hideStatus() {
  if (statusTimer) {
    clearTimeout(statusTimer);
    statusTimer = null;
  }
  $('status-banner').hidden = true;
}

// MARK: - Target Selector Rendering

function renderTargetControls() {
  const cfg = state.config;
  if (!cfg) return;

  const mode = cfg.targetMode || 'inbox';
  for (const btn of document.querySelectorAll('.seg-btn[data-target-mode]')) {
    const isSelected = btn.dataset.targetMode === mode;
    btn.setAttribute('aria-checked', String(isSelected));
  }

  const folderWrap = $('target-folder-wrap');
  const boardWrap = $('target-board-wrap');
  folderWrap.hidden = mode !== 'folder';
  boardWrap.hidden = mode !== 'board';

  // Populate folders
  const folderSelect = $('select-folder');
  const folderOptions = buildFolderOptions(cfg.cachedFolders || []);
  folderSelect.innerHTML = '';
  if (folderOptions.length === 0) {
    const opt = document.createElement('option');
    opt.value = '';
    opt.textContent = '暂无文件夹（将存入收件箱）';
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
    if (!cfg.targetFolderId && mode === 'folder' && folderOptions[0]) {
      folderSelect.value = folderOptions[0].id;
      void persistTargetPatch({
        targetFolderId: folderOptions[0].id,
        targetFolderName: folderOptions[0].name,
      });
    }
  }

  // Populate boards
  const boardSelect = $('select-board');
  const boards = Array.isArray(cfg.cachedBoards) ? cfg.cachedBoards : [];
  boardSelect.innerHTML = '';
  if (boards.length === 0) {
    const opt = document.createElement('option');
    opt.value = '';
    opt.textContent = '暂无情绪板（将存入收件箱）';
    boardSelect.appendChild(opt);
    boardSelect.disabled = true;
  } else {
    boardSelect.disabled = false;
    for (const board of boards) {
      const opt = document.createElement('option');
      opt.value = board.id;
      const countText = typeof board.itemCount === 'number' ? ` (${board.itemCount})` : '';
      opt.textContent = `${board.title}${countText}`;
      if (board.id === cfg.targetBoardId) opt.selected = true;
      boardSelect.appendChild(opt);
    }
    if (!cfg.targetBoardId && mode === 'board' && boards[0]) {
      boardSelect.value = boards[0].id;
      void persistTargetPatch({
        targetBoardId: boards[0].id,
        targetBoardName: boards[0].title,
      });
    }
  }
}

async function persistTargetPatch(patch) {
  const res = await sendBg({ type: 'SET_TARGET', ...patch });
  if (res?.ok && res.config) {
    state.config = res.config;
  }
}

async function refreshTargetsLive(silent = false) {
  const icon = $('icon-refresh-targets');
  icon?.classList.add('is-spinning');
  if (!silent) setConnectionIndicator('checking', '同步中…');
  try {
    const res = await sendBg({ type: 'REFRESH_TARGETS' });
    if (res?.ok && res.config) {
      state.config = res.config;
      const userLabel = res.user?.displayName || res.user?.username || '已连接';
      setConnectionIndicator('connected', userLabel);
      renderTargetControls();
      if (!silent) {
        showStatus(
          'success',
          `已同步 ${res.folders.length} 个文件夹与 ${res.boards.length} 个情绪板`,
          2200,
        );
      }
    } else {
      setConnectionIndicator('error', '连接异常');
      if (!silent) {
        showStatus('error', res?.error || '无法连接 Charkle 服务，请检查设置。', 4500);
      }
    }
  } catch (err) {
    setConnectionIndicator('error', '连接失败');
    if (!silent) {
      showStatus('error', err instanceof Error ? err.message : '同步失败', 4500);
    }
  } finally {
    icon?.classList.remove('is-spinning');
  }
}

// MARK: - Tabs

function switchTab(tabKey) {
  state.activePanel = tabKey;
  for (const btn of document.querySelectorAll('.tab-btn[data-tab]')) {
    const selected = btn.dataset.tab === tabKey;
    btn.setAttribute('aria-selected', String(selected));
    btn.tabIndex = selected ? 0 : -1;
  }
  for (const panel of document.querySelectorAll('.tab-panel')) {
    panel.hidden = panel.id !== `panel-${tabKey}`;
  }
  if (tabKey === 'images' && !state.imagesScanned) {
    void scanCurrentPageImages();
  }
}

// MARK: - Tab 1: Current Page & Screenshot

function hydratePageTab() {
  const tab = state.activeTab;
  const pageUrl = tab?.url || '';
  const source = detectSpecialSource(pageUrl);

  const hostEl = $('page-host');
  hostEl.textContent = source.hostname || '当前标签页';
  hostEl.title = pageUrl;

  const badgeEl = $('source-badge');
  badgeEl.dataset.kind = source.kind;
  badgeEl.textContent = source.badgeText;

  const faviconEl = $('page-favicon');
  if (tab?.favIconUrl && /^https?:\/\//i.test(tab.favIconUrl)) {
    faviconEl.src = tab.favIconUrl;
    faviconEl.hidden = false;
  } else {
    faviconEl.hidden = true;
  }

  $('page-title-input').value = state.pageContext?.title || tab?.title || '';
  if (state.pageContext?.description && !$('page-notes-input').value) {
    $('page-notes-input').value = state.pageContext.description;
  }

  const saveBtn = $('btn-save-page');
  saveBtn.textContent = source.actionLabel;
  saveBtn.disabled = !isCapturablePageUrl(pageUrl);
}

async function handleSavePage() {
  if (state.isBusy || !state.activeTab?.url) return;
  state.isBusy = true;
  const btn = $('btn-save-page');
  const origLabel = btn.textContent;
  btn.disabled = true;
  btn.textContent = '收藏中…';
  hideStatus();

  try {
    const res = await sendBg({
      type: 'INGEST_URL',
      url: state.activeTab.url,
      title: $('page-title-input').value.trim(),
      notes: $('page-notes-input').value.trim(),
    });
    if (res?.ok) {
      const savedTitle = res.assets?.[0]?.title || $('page-title-input').value.trim() || '网页';
      showStatus('success', `已收藏「${savedTitle}」到 ${res.targetLabel}`);
    } else {
      showStatus('error', res?.error || '收藏网页失败', 4500);
    }
  } catch (err) {
    showStatus('error', err instanceof Error ? err.message : '收藏网页失败', 4500);
  } finally {
    state.isBusy = false;
    btn.disabled = !isCapturablePageUrl(state.activeTab?.url);
    btn.textContent = origLabel;
  }
}

async function handleCaptureVisible() {
  if (state.isBusy) return;
  state.isBusy = true;
  const btn = $('btn-capture-visible');
  const origHtml = btn.innerHTML;
  btn.disabled = true;
  btn.textContent = '截屏中…';
  hideStatus();

  try {
    const res = await sendBg({
      type: 'CAPTURE_VISIBLE_TAB',
      tab: state.activeTab
        ? {
            id: state.activeTab.id,
            windowId: state.activeTab.windowId,
            title: state.activeTab.title,
            url: state.activeTab.url,
          }
        : null,
    });
    if (res?.ok) {
      if (res.previewDataUrl) {
        $('screenshot-preview-img').src = res.previewDataUrl;
        $('screenshot-preview-wrap').hidden = false;
      }
      showStatus('success', `已截取当前画面到 ${res.targetLabel}`);
    } else {
      showStatus('error', res?.error || '截取页面失败', 4500);
    }
  } catch (err) {
    showStatus('error', err instanceof Error ? err.message : '截取页面失败', 4500);
  } finally {
    state.isBusy = false;
    btn.disabled = false;
    btn.innerHTML = origHtml;
  }
}

// MARK: - Tab 2: Batch Image Grabber

function updateImagesSelectionUI() {
  const count = state.selectedImageUrls.size;
  const saveBtn = $('btn-save-images');
  saveBtn.disabled = count === 0 || state.isBusy;
  if (!state.isBusy) {
    saveBtn.textContent = `收藏所选 (${count})`;
  }
}

function renderImagesGrid() {
  const grid = $('images-grid');
  const emptyEl = $('images-empty');
  const emptyText = $('images-empty-text');
  const summaryEl = $('images-summary');
  const list = state.scannedImages;

  grid.innerHTML = '';

  if (list.length === 0) {
    grid.hidden = true;
    emptyEl.hidden = false;
    if (!isCapturablePageUrl(state.activeTab?.url)) {
      emptyText.textContent = '浏览器内部页面不支持扫描图片，可在任意普通网页使用。';
    } else {
      emptyText.textContent = '未发现大于 64px 的图片，可滚动加载页面后点击「重扫」。';
    }
    summaryEl.textContent = '发现 0 张图片';
    updateImagesSelectionUI();
    return;
  }

  emptyEl.hidden = true;
  grid.hidden = false;
  summaryEl.textContent = `发现 ${list.length} 张图片`;

  const fragment = document.createDocumentFragment();
  for (const item of list) {
    const tile = document.createElement('button');
    tile.type = 'button';
    tile.className = 'image-tile';
    tile.setAttribute('role', 'listitem');
    tile.dataset.url = item.url;
    const isSelected = state.selectedImageUrls.has(item.url);
    if (isSelected) tile.classList.add('is-selected');
    tile.setAttribute('aria-pressed', String(isSelected));
    tile.title = item.alt || item.url;

    const img = document.createElement('img');
    img.src = item.url;
    img.alt = item.alt || '';
    img.loading = 'lazy';
    img.decoding = 'async';

    const badge = document.createElement('span');
    badge.className = 'image-res-badge';
    if (item.width > 0 && item.height > 0) {
      badge.textContent = `${item.width}×${item.height}`;
    } else if (item.source === 'og') {
      badge.textContent = '封面';
    } else {
      badge.textContent = '图片';
    }

    const check = document.createElement('span');
    check.className = 'image-check';
    check.innerHTML =
      '<svg width="11" height="11" viewBox="0 0 12 12" fill="none" aria-hidden="true"><path d="M2.4 6.2L4.9 8.7L9.6 3.5" stroke="currentColor" stroke-width="1.8" stroke-linecap="round" stroke-linejoin="round"/></svg>';

    tile.append(img, badge, check);
    tile.addEventListener('click', () => {
      if (state.selectedImageUrls.has(item.url)) {
        state.selectedImageUrls.delete(item.url);
        tile.classList.remove('is-selected');
        tile.setAttribute('aria-pressed', 'false');
      } else {
        state.selectedImageUrls.add(item.url);
        tile.classList.add('is-selected');
        tile.setAttribute('aria-pressed', 'true');
      }
      updateImagesSelectionUI();
    });
    fragment.appendChild(tile);
  }

  grid.appendChild(fragment);
  updateImagesSelectionUI();
}

async function scanCurrentPageImages() {
  state.imagesScanned = true;
  $('images-summary').textContent = '正在扫描页面图片…';
  $('images-empty').hidden = true;

  const res = await queryTabContent(state.activeTab, { type: 'SCAN_PAGE_IMAGES' });
  if (res?.ok && Array.isArray(res.images)) {
    state.scannedImages = res.images;
    // Keep only selections that still exist
    const validSet = new Set(res.images.map((i) => i.url));
    for (const u of Array.from(state.selectedImageUrls)) {
      if (!validSet.has(u)) state.selectedImageUrls.delete(u);
    }
  } else {
    state.scannedImages = [];
    state.selectedImageUrls.clear();
  }
  renderImagesGrid();
}

function handleSelectLargeImages() {
  const large = state.scannedImages.filter((item) => isLargeImageCandidate(item, 400));
  const pool = large.length > 0 ? large : state.scannedImages;
  state.selectedImageUrls = new Set(pool.map((i) => i.url));
  for (const tile of $('images-grid').querySelectorAll('.image-tile')) {
    const selected = state.selectedImageUrls.has(tile.dataset.url);
    tile.classList.toggle('is-selected', selected);
    tile.setAttribute('aria-pressed', String(selected));
  }
  updateImagesSelectionUI();
}

function handleClearImages() {
  state.selectedImageUrls.clear();
  for (const tile of $('images-grid').querySelectorAll('.image-tile')) {
    tile.classList.remove('is-selected');
    tile.setAttribute('aria-pressed', 'false');
  }
  updateImagesSelectionUI();
}

async function handleSaveSelectedImages() {
  if (state.isBusy || state.selectedImageUrls.size === 0) return;
  const items = state.scannedImages
    .filter((i) => state.selectedImageUrls.has(i.url))
    .map((i) => ({ url: i.url, title: i.alt || state.activeTab?.title || '' }));

  state.isBusy = true;
  const btn = $('btn-save-images');
  btn.disabled = true;
  btn.textContent = `正在收藏 0/${items.length}…`;
  hideStatus();

  try {
    const res = await sendBg({
      type: 'INGEST_IMAGES_BATCH',
      items,
      sourcePageUrl: state.activeTab?.url || null,
    });
    if (res?.ok) {
      const msg =
        res.failed > 0
          ? `已收藏 ${res.succeeded} 张图片到 ${res.targetLabel}（${res.failed} 张失败）`
          : `已收藏 ${res.succeeded} 张图片到 ${res.targetLabel}`;
      showStatus('success', msg, 4000);
      handleClearImages();
    } else {
      showStatus('error', res?.error || '批量收藏图片失败', 4500);
    }
  } catch (err) {
    showStatus('error', err instanceof Error ? err.message : '批量收藏失败', 4500);
  } finally {
    state.isBusy = false;
    updateImagesSelectionUI();
  }
}

// MARK: - Tab 3: Text Snippet

function hydrateTextTab() {
  const titleEl = $('text-title-input');
  const bodyEl = $('text-body-input');
  const sourceLabelEl = $('text-source-label');
  const includeSourceEl = $('text-include-source');

  const pageUrl = state.activeTab?.url || '';
  const capturable = isCapturablePageUrl(pageUrl);
  includeSourceEl.disabled = !capturable;
  includeSourceEl.checked = capturable;

  if (capturable) {
    const host = detectSpecialSource(pageUrl).hostname || '当前网页';
    sourceLabelEl.textContent = `附带来源链接（${host}）`;
  } else {
    sourceLabelEl.textContent = '当前页面无外部来源链接';
  }

  if (!titleEl.value) {
    titleEl.value = state.pageContext?.title || state.activeTab?.title || '';
  }
  if (state.pageContext?.selection && !bodyEl.value) {
    bodyEl.value = state.pageContext.selection;
  }
  updateTextCharCount();
}

function updateTextCharCount() {
  const len = $('text-body-input').value.trim().length;
  $('text-char-count').textContent = `${len} 字`;
}

async function handleSaveText() {
  if (state.isBusy) return;
  const text = $('text-body-input').value.trim();
  if (!text) {
    showStatus('error', '请先输入或选中要收藏的文字内容。', 3200);
    $('text-body-input').focus();
    return;
  }

  state.isBusy = true;
  const btn = $('btn-save-text');
  btn.disabled = true;
  btn.textContent = '收藏中…';
  hideStatus();

  try {
    const includeSource = $('text-include-source').checked && isCapturablePageUrl(state.activeTab?.url);
    const res = await sendBg({
      type: 'INGEST_TEXT_SNIPPET',
      title: $('text-title-input').value.trim() || '文字灵感',
      text,
      sourceUrl: includeSource ? state.activeTab.url : null,
    });
    if (res?.ok) {
      showStatus('success', `已收藏文字灵感到 ${res.targetLabel}`);
      $('text-body-input').value = '';
      updateTextCharCount();
    } else {
      showStatus('error', res?.error || '收藏文字失败', 4500);
    }
  } catch (err) {
    showStatus('error', err instanceof Error ? err.message : '收藏文字失败', 4500);
  } finally {
    state.isBusy = false;
    btn.disabled = false;
    btn.textContent = '收藏文字灵感';
  }
}

// MARK: - Tab 4: Color Swatch & EyeDropper

function updateSwatchPreview(rawHex, syncInputs = true) {
  const normalized = normalizeHexColor(rawHex);
  if (!normalized) return false;
  state.currentHex = normalized;

  const stage = $('color-swatch-stage');
  stage.style.backgroundColor = normalized;
  stage.dataset.light = String(isLightHex(normalized));
  $('color-swatch-hex').textContent = normalized;
  $('color-native-dot').style.backgroundColor = normalized;

  if (syncInputs) {
    $('color-hex-input').value = normalized;
    $('color-native-input').value = normalized;
  }
  return true;
}

function initColorTab() {
  const eyeBtn = $('btn-eyedropper');
  if (typeof window.EyeDropper !== 'function') {
    eyeBtn.hidden = true;
  }
  updateSwatchPreview(state.currentHex, true);
}

async function handleEyeDropper() {
  if (typeof window.EyeDropper !== 'function') return;
  try {
    const dropper = new window.EyeDropper();
    const result = await dropper.open();
    if (result?.sRGBHex) {
      updateSwatchPreview(result.sRGBHex, true);
    }
  } catch {
    // User pressed Escape to cancel EyeDropper
  }
}

async function handleSaveColor() {
  if (state.isBusy) return;
  const normalized = normalizeHexColor($('color-hex-input').value);
  if (!normalized) {
    showStatus('error', '请输入有效的 HEX 色值（如 #2A60E0）。', 3400);
    $('color-hex-input').focus();
    return;
  }
  updateSwatchPreview(normalized, true);

  state.isBusy = true;
  const btn = $('btn-save-color');
  btn.disabled = true;
  btn.textContent = '收藏中…';
  hideStatus();

  try {
    const res = await sendBg({
      type: 'INGEST_COLOR_SWATCH',
      hex: normalized,
      title: $('color-title-input').value.trim() || normalized,
    });
    if (res?.ok) {
      showStatus('success', `已收藏色卡 ${normalized} 到 ${res.targetLabel}`);
      $('color-title-input').value = '';
    } else {
      showStatus('error', res?.error || '收藏色卡失败', 4500);
    }
  } catch (err) {
    showStatus('error', err instanceof Error ? err.message : '收藏色卡失败', 4500);
  } finally {
    state.isBusy = false;
    btn.disabled = false;
    btn.textContent = '收藏色卡';
  }
}

// MARK: - Onboarding Submit

async function handleOnboardingSubmit(e) {
  e.preventDefault();
  const serverUrl = $('onboard-server').value.trim();
  const apiToken = $('onboard-token').value.trim();
  const errEl = $('onboard-error');
  const saveBtn = $('btn-onboard-save');

  errEl.hidden = true;
  if (!serverUrl || !apiToken) {
    errEl.textContent = '请填写服务地址与访问令牌。';
    errEl.hidden = false;
    return;
  }

  saveBtn.disabled = true;
  saveBtn.textContent = '正在验证连接…';
  setConnectionIndicator('checking', '连接中…');

  try {
    const res = await sendBg({
      type: 'TEST_CONNECTION',
      serverUrl,
      apiToken,
      save: true,
    });
    if (res?.ok && res.config) {
      state.config = res.config;
      await enterWorkbenchMode(false);
      showStatus('success', '连接成功，已同步文件夹与情绪板');
    } else {
      setConnectionIndicator('error', '未连接');
      errEl.textContent = res?.error || '连接失败，请核对服务地址与访问令牌。';
      errEl.hidden = false;
    }
  } catch (err) {
    setConnectionIndicator('error', '未连接');
    errEl.textContent = err instanceof Error ? err.message : '连接失败';
    errEl.hidden = false;
  } finally {
    saveBtn.disabled = false;
    saveBtn.textContent = '测试并保存';
  }
}

// MARK: - Mode Switching & Init

async function enterWorkbenchMode(shouldRefreshLive = true) {
  $('view-onboarding').hidden = true;
  $('view-workbench').hidden = false;
  $('btn-open-web').hidden = false;

  const cachedUser = state.config?.lastConnectedUser;
  setConnectionIndicator(
    'connected',
    cachedUser?.displayName || cachedUser?.username || '已连接',
  );

  renderTargetControls();
  hydratePageTab();
  hydrateTextTab();
  initColorTab();

  // If user has active text selection on page, gently hint or switch if appropriate
  if (state.pageContext?.selection && state.pageContext.selection.length >= 2) {
    $('tab-text').textContent = '文字灵感 ·';
  }

  if (shouldRefreshLive) {
    void refreshTargetsLive(true);
  }
}

function enterOnboardingMode() {
  $('view-workbench').hidden = true;
  $('view-onboarding').hidden = false;
  $('btn-open-web').hidden = true;
  setConnectionIndicator('idle', '未连接');

  if (state.config?.serverUrl) {
    $('onboard-server').value = state.config.serverUrl;
  }
  if (state.config?.apiToken) {
    $('onboard-token').value = state.config.apiToken;
  }
}

function bindEvents() {
  $('btn-open-options').addEventListener('click', () => {
    chrome.runtime.openOptionsPage();
  });

  $('btn-open-web').addEventListener('click', () => {
    if (state.config?.serverUrl) {
      chrome.tabs.create({ url: state.config.serverUrl });
    }
  });

  $('btn-toggle-onboard-token').addEventListener('click', () => {
    const input = $('onboard-token');
    input.type = input.type === 'password' ? 'text' : 'password';
  });

  $('onboarding-form').addEventListener('submit', handleOnboardingSubmit);

  // Target Bar
  $('btn-refresh-targets').addEventListener('click', () => {
    void refreshTargetsLive(false);
  });

  for (const segBtn of document.querySelectorAll('.seg-btn[data-target-mode]')) {
    segBtn.addEventListener('click', async () => {
      const nextMode = segBtn.dataset.targetMode;
      const patch = { targetMode: nextMode };
      if (nextMode === 'folder' && !state.config?.targetFolderId && state.config?.cachedFolders?.[0]) {
        patch.targetFolderId = state.config.cachedFolders[0].id;
        patch.targetFolderName = state.config.cachedFolders[0].name;
      }
      if (nextMode === 'board' && !state.config?.targetBoardId && state.config?.cachedBoards?.[0]) {
        patch.targetBoardId = state.config.cachedBoards[0].id;
        patch.targetBoardName = state.config.cachedBoards[0].title;
      }
      await persistTargetPatch(patch);
      renderTargetControls();
    });
  }

  $('select-folder').addEventListener('change', async (e) => {
    const id = e.target.value || null;
    const matched = (state.config?.cachedFolders || []).find((f) => f.id === id);
    await persistTargetPatch({
      targetMode: 'folder',
      targetFolderId: id,
      targetFolderName: matched?.name || '',
    });
  });

  $('select-board').addEventListener('change', async (e) => {
    const id = e.target.value || null;
    const matched = (state.config?.cachedBoards || []).find((b) => b.id === id);
    await persistTargetPatch({
      targetMode: 'board',
      targetBoardId: id,
      targetBoardName: matched?.title || '',
    });
  });

  // Action Tabs + Keyboard Arrow Navigation
  const tabButtons = Array.from(document.querySelectorAll('.tab-btn[data-tab]'));
  for (let i = 0; i < tabButtons.length; i++) {
    const btn = tabButtons[i];
    btn.addEventListener('click', () => switchTab(btn.dataset.tab));
    btn.addEventListener('keydown', (e) => {
      if (e.key === 'ArrowRight' || e.key === 'ArrowLeft') {
        e.preventDefault();
        const dir = e.key === 'ArrowRight' ? 1 : -1;
        const nextBtn = tabButtons[(i + dir + tabButtons.length) % tabButtons.length];
        nextBtn.focus();
        switchTab(nextBtn.dataset.tab);
      }
    });
  }

  // Tab 1
  $('btn-save-page').addEventListener('click', handleSavePage);
  $('btn-capture-visible').addEventListener('click', handleCaptureVisible);

  // Tab 2
  $('btn-select-large').addEventListener('click', handleSelectLargeImages);
  $('btn-clear-images').addEventListener('click', handleClearImages);
  $('btn-rescan-images').addEventListener('click', () => {
    void scanCurrentPageImages();
  });
  $('btn-save-images').addEventListener('click', handleSaveSelectedImages);

  // Tab 3
  $('text-body-input').addEventListener('input', updateTextCharCount);
  $('btn-save-text').addEventListener('click', handleSaveText);

  // Tab 4
  $('btn-eyedropper').addEventListener('click', handleEyeDropper);
  $('color-native-input').addEventListener('input', (e) => {
    updateSwatchPreview(e.target.value, true);
  });
  $('color-hex-input').addEventListener('input', (e) => {
    const val = e.target.value.trim();
    if (normalizeHexColor(val)) {
      updateSwatchPreview(val, false);
      $('color-native-input').value = state.currentHex;
    }
  });
  $('btn-save-color').addEventListener('click', handleSaveColor);

  // Live batch progress updates from background service worker
  chrome.runtime.onMessage.addListener((msg) => {
    if (msg?.type === 'BATCH_INGEST_PROGRESS' && state.isBusy) {
      $('btn-save-images').textContent = `正在收藏 ${msg.completed}/${msg.total}…`;
    }
  });
}

async function bootstrap() {
  bindEvents();
  const [config, tabs] = await Promise.all([
    getConfig(),
    chrome.tabs.query({ active: true, currentWindow: true }),
  ]);
  state.config = config;
  state.activeTab = tabs[0] || null;

  if (state.activeTab && isCapturablePageUrl(state.activeTab.url)) {
    state.pageContext = await queryTabContent(state.activeTab, { type: 'GET_PAGE_CONTEXT' });
  }

  if (isConfigured(config)) {
    await enterWorkbenchMode(true);
  } else {
    enterOnboardingMode();
  }
}

void bootstrap();
