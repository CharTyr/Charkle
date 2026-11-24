/**
 * Charkle Extension — Popup Workbench Controller (Chrome & Safari)
 */

import { isLargeImageCandidate } from './lib/image-filter.js';
import {
  buildFolderOptions,
  DEFAULT_DESKTOP_SERVER_URL,
  getConfig,
  isConfigured,
} from './lib/storage.js';
import {
  detectBookmarkCollectionPage,
  detectSpecialSource,
  isCapturablePageUrl,
  isLightHex,
  normalizeHexColor,
} from './lib/url-detect.js';

const ext = globalThis.browser ?? globalThis.chrome;
const $ = (id) => document.getElementById(id);

const state = {
  config: null,
  onboardMode: 'desktop',
  activeTab: null,
  pageContext: null,
  collectionPage: { supported: false, platform: null, pageKind: null, label: '', suggestedFolderName: '' },
  bookmarkJob: null,
  activePanel: 'page',
  scannedImages: [],
  selectedImageUrls: new Set(),
  imagesScanned: false,
  isBusy: false,
  currentHex: '#2A60E0',
};

let statusTimer = null;

function sendBg(payload) {
  return ext.runtime.sendMessage(payload);
}

async function sendTabTopFrame(tabId, message) {
  try {
    return await ext.tabs.sendMessage(tabId, message, { frameId: 0 });
  } catch (err) {
    if (err && /frameId|options|signature/i.test(String(err.message || ''))) {
      return await ext.tabs.sendMessage(tabId, message);
    }
    throw err;
  }
}

async function queryTabContent(tab, message) {
  if (!tab?.id || !isCapturablePageUrl(tab.url)) return null;
  try {
    return await sendTabTopFrame(tab.id, message);
  } catch {
    const ensured = await sendBg({
      type: 'ENSURE_CONTENT_SCRIPT',
      tabId: tab.id,
      tabUrl: tab.url,
    }).catch(() => ({ ok: false }));
    if (!ensured?.ok) return null;
    try {
      return await sendTabTopFrame(tab.id, message);
    } catch {
      return null;
    }
  }
}

function getEffectivePageUrl() {
  if (state.pageContext?.url && isCapturablePageUrl(state.pageContext.url)) {
    return state.pageContext.url;
  }
  return state.activeTab?.url || '';
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
    btn.setAttribute('aria-checked', String(btn.dataset.targetMode === mode));
  }

  $('target-folder-wrap').hidden = mode !== 'folder';
  $('target-board-wrap').hidden = mode !== 'board';

  const folderSelect = $('select-folder');
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
    if (!cfg.targetFolderId && mode === 'folder' && folderOptions[0]) {
      folderSelect.value = folderOptions[0].id;
      void persistTargetPatch({
        targetFolderId: folderOptions[0].id,
        targetFolderName: folderOptions[0].name,
      });
    }
  }

  const boardSelect = $('select-board');
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
      const isDesktop = state.config?.connectionMode !== 'web';
      setConnectionIndicator('error', isDesktop ? '桌面端未运行' : '连接异常');
      showStatus(
        'error',
        res?.error ||
          (isDesktop
            ? 'Charkle 桌面端暂未运行，请打开 Mac 上的 Charkle 应用后点击「同步」重连。'
            : '无法连接 Charkle，请检查设置。'),
        isDesktop ? 5500 : 4500,
      );
    }
  } catch (err) {
    const isDesktop = state.config?.connectionMode !== 'web';
    setConnectionIndicator('error', isDesktop ? '桌面端未运行' : '连接失败');
    if (!silent || isDesktop) {
      showStatus(
        'error',
        err instanceof Error
          ? err.message
          : isDesktop
            ? 'Charkle 桌面端暂未运行，请打开 Charkle 应用后重试。'
            : '同步失败',
        5000,
      );
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
  const pageUrl = getEffectivePageUrl();
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
  const pageUrl = getEffectivePageUrl();
  if (state.isBusy || !pageUrl) return;
  state.isBusy = true;
  const btn = $('btn-save-page');
  const origLabel = btn.textContent;
  btn.disabled = true;
  btn.textContent = '收藏中…';
  hideStatus();

  try {
    const res = await sendBg({
      type: 'INGEST_URL',
      url: pageUrl,
      title: $('page-title-input').value.trim(),
      notes: $('page-notes-input').value.trim(),
      socialBookmark: state.pageContext?.socialBookmark || null,
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
    btn.disabled = !isCapturablePageUrl(getEffectivePageUrl());
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

// MARK: - Tab 2: Batch Bookmarks Import (X & Xiaohongshu)

function hydrateBookmarksTab() {
  const pageUrl = getEffectivePageUrl();
  const contentDetected = state.pageContext?.collectionPage;
  const urlDetected = detectBookmarkCollectionPage(pageUrl);
  const detected =
    contentDetected && contentDetected.supported
      ? contentDetected
      : urlDetected.supported
        ? urlDetected
        : contentDetected || urlDetected;
  state.collectionPage = detected;

  const cfg = state.config || {};
  $('bm-opt-skip-dups').checked = cfg.bookmarkSkipDuplicates !== false;
  $('bm-opt-stop-streak').checked = cfg.bookmarkStopOnKnownStreak !== false;
  $('bm-opt-xhs-detail').checked = cfg.bookmarkEnrichXhsDetails !== false;
  $('bm-opt-max-count').value = String(cfg.bookmarkMaxCount || 0);

  const supportedBlock = $('bm-supported-block');
  const guideBlock = $('bm-guide-block');

  if (detected.supported) {
    supportedBlock.hidden = false;
    guideBlock.hidden = true;
    const badge = $('bm-platform-badge');
    badge.dataset.kind = detected.platform;
    badge.textContent =
      detected.platform === 'xiaohongshu'
        ? '小红书'
        : detected.pageKind === 'likes'
          ? 'X 喜欢'
          : 'X 书签';
    $('bm-page-label').textContent = detected.label;
    $('btn-bm-quick-folder').textContent = `+ ${detected.suggestedFolderName}`;
    $('bm-opt-xhs-row').hidden = detected.platform !== 'xiaohongshu';
    if (detected.isCollectionRoute !== false) {
      $('tab-bookmarks').textContent = '收藏导入 ·';
    }
  } else {
    supportedBlock.hidden = true;
    guideBlock.hidden = false;
  }

  renderBookmarkJobProgress(state.pageContext?.bookmarkJob || state.bookmarkJob);
}

function renderBookmarkJobProgress(job) {
  state.bookmarkJob = job || null;
  const card = $('bm-progress-card');
  const startBtn = $('btn-bm-start');
  const controls = $('bm-progress-controls');

  if (!job || job.status === 'idle') {
    card.hidden = true;
    startBtn.hidden = false;
    startBtn.disabled = false;
    return;
  }

  card.hidden = false;
  card.dataset.status = job.status;
  $('bm-progress-phase').textContent = job.errorMessage || job.phase || '正在扫描…';

  const processed = (job.imported || 0) + (job.skipped || 0) + (job.failed || 0);
  const pct =
    job.status === 'done'
      ? 100
      : job.discovered > 0
        ? Math.max(10, Math.min(96, Math.round((processed / Math.max(job.discovered, 1)) * 100)))
        : 12;
  $('bm-bar-fill').style.width = `${pct}%`;

  const failSuffix = job.failed > 0 ? ` · 失败 ${job.failed}` : '';
  $('bm-progress-stats').textContent = `发现 ${job.discovered || 0} · 导入 ${job.imported || 0} · 跳过 ${job.skipped || 0}${failSuffix}`;
  $('bm-progress-last').textContent = job.lastItemTitle ? `最新：${job.lastItemTitle}` : '';

  const isActive = job.status === 'running' || job.status === 'paused';
  controls.hidden = !isActive;
  $('btn-bm-pause').textContent = job.status === 'paused' ? '继续' : '暂停';
  startBtn.hidden = isActive;
  startBtn.disabled = isActive;
  if (!isActive) {
    startBtn.textContent = '再次扫描并导入新增';
  }
}

async function handleStartBookmarkImport() {
  if (!state.activeTab?.id || !state.collectionPage.supported) return;
  hideStatus();

  const skipDuplicates = $('bm-opt-skip-dups').checked;
  const stopOnKnownStreak = $('bm-opt-stop-streak').checked;
  const enrichXhsDetails = $('bm-opt-xhs-detail').checked;
  const maxCount = Number($('bm-opt-max-count').value || 0);

  await persistTargetPatch({
    bookmarkSkipDuplicates: skipDuplicates,
    bookmarkStopOnKnownStreak: stopOnKnownStreak,
    bookmarkEnrichXhsDetails: enrichXhsDetails,
    bookmarkMaxCount: maxCount,
  });

  const btn = $('btn-bm-start');
  btn.disabled = true;
  btn.textContent = '正在启动…';

  const res = await queryTabContent(state.activeTab, {
    type: 'START_BOOKMARK_IMPORT',
    options: {
      skipDuplicates,
      stopOnKnownStreak,
      enrichXhsDetails,
      maxCount,
      preferredPlatform: state.collectionPage?.platform || null,
      preferredLabel: state.collectionPage?.label || null,
      preferredPageKind: state.collectionPage?.pageKind || null,
    },
  });

  if (res?.job) {
    renderBookmarkJobProgress(res.job);
  }
  if (res?.ok) {
    btn.textContent = '一键扫描并批量导入';
  } else {
    showStatus('error', res?.error || '无法在当前标签页启动批量导入，请刷新页面后重试。', 4500);
    btn.disabled = false;
    btn.textContent = '一键扫描并批量导入';
  }
}

async function handleQuickCreateCollectionFolder() {
  const suggested = state.collectionPage?.suggestedFolderName || '社交收藏';
  const btn = $('btn-bm-quick-folder');
  btn.disabled = true;
  try {
    const res = await sendBg({ type: 'CREATE_FOLDER_AND_SELECT', name: suggested });
    if (res?.ok && res.config) {
      state.config = res.config;
      renderTargetControls();
      showStatus(
        'success',
        res.reused ? `已切换目标至现有文件夹「${suggested}」` : `已新建并选中文件夹「${suggested}」`,
        2600,
      );
    } else {
      showStatus('error', res?.error || '创建文件夹失败', 3800);
    }
  } finally {
    btn.disabled = false;
  }
}

// MARK: - Tab 3: Batch Image Grabber

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
    emptyText.textContent = !isCapturablePageUrl(state.activeTab?.url)
      ? '此页面不支持扫描图片'
      : '未发现图片，可滚动页面后重扫';
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
    if (item.width > 0 && item.height > 0) badge.textContent = `${item.width}×${item.height}`;
    else if (item.source === 'og') badge.textContent = '封面';
    else badge.textContent = '图片';

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

// MARK: - Tab 4: Text Snippet

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

// MARK: - Tab 5: Color Swatch & EyeDropper

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
    if (result?.sRGBHex) updateSwatchPreview(result.sRGBHex, true);
  } catch {
    // cancelled
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

// MARK: - Onboarding Submit & Desktop Auto-Detect

function setOnboardingMode(mode) {
  state.onboardMode = mode === 'web' ? 'web' : 'desktop';
  for (const btn of document.querySelectorAll('.seg-btn[data-onboard-mode]')) {
    btn.setAttribute('aria-checked', String(btn.dataset.onboardMode === state.onboardMode));
  }
  const input = $('onboard-server');
  input.placeholder =
    state.onboardMode === 'desktop' ? DEFAULT_DESKTOP_SERVER_URL : 'http://127.0.0.1:3417';
  if (state.onboardMode === 'desktop' && (!input.value || input.value.includes(':3417'))) {
    input.value = DEFAULT_DESKTOP_SERVER_URL;
  } else if (state.onboardMode === 'web' && input.value === DEFAULT_DESKTOP_SERVER_URL) {
    input.value = 'http://127.0.0.1:3417';
  }
}

async function probeDesktopInOnboarding(silent = false) {
  const infoEl = $('onboard-info');
  const errEl = $('onboard-error');
  const detectBtn = $('btn-onboard-detect');
  const detailsEl = $('onboard-manual-details');

  if (detectBtn) {
    detectBtn.disabled = true;
    detectBtn.textContent = '正在自动连接…';
  }
  if (!silent) {
    setConnectionIndicator('checking', '连接中…');
  }

  try {
    const res = await sendBg({ type: 'AUTO_PAIR_LOCAL_DESKTOP', force: true }).catch(() => null);
    if (res?.ok && res.config) {
      state.config = res.config;
      errEl.hidden = true;
      infoEl.hidden = true;
      await enterWorkbenchMode(false);
      showStatus('success', '已自动连接本机 Charkle，无需手动配置', 2600);
      return true;
    }

    setConnectionIndicator('idle', '未连接');
    if (res?.reason === 'AUTO_PAIR_DISABLED' && res.serverUrl) {
      setOnboardingMode('desktop');
      $('onboard-server').value = res.serverUrl;
      if (detailsEl) detailsEl.open = true;
      errEl.hidden = true;
      infoEl.textContent =
        res.error || '已检测到 Charkle 桌面端，但关闭了自动免密配对，请在设置开启或在下方粘贴令牌。';
      infoEl.hidden = false;
      return false;
    }

    if (res?.foundDesktop && res.serverUrl) {
      setOnboardingMode('desktop');
      $('onboard-server').value = res.serverUrl;
      if (detailsEl) detailsEl.open = true;
      infoEl.hidden = true;
      errEl.textContent = res.error || '自动配对未通过，请展开下方手动填写访问令牌。';
      errEl.hidden = false;
      return false;
    }

    if (!silent) {
      infoEl.hidden = true;
      errEl.textContent =
        res?.error || '未检测到运行中的 Charkle 桌面端，请先打开 Mac 上的 Charkle 应用后重试。';
      errEl.hidden = false;
    }
    return false;
  } finally {
    if (detectBtn) {
      detectBtn.disabled = false;
      detectBtn.textContent = '一键自动连接本机 Charkle';
    }
  }
}

async function handleOnboardingSubmit(e) {
  e.preventDefault();
  const serverUrl = $('onboard-server').value.trim();
  const apiToken = $('onboard-token').value.trim();
  const errEl = $('onboard-error');
  const infoEl = $('onboard-info');
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
      connectionMode: state.onboardMode,
      serverUrl,
      apiToken,
      save: true,
    });
    if (res?.ok && res.config) {
      infoEl.hidden = true;
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
    saveBtn.textContent = '测试并保存手动配置';
  }
}

// MARK: - Mode Switching & Init

async function enterWorkbenchMode(shouldRefreshLive = true) {
  $('view-onboarding').hidden = true;
  $('view-workbench').hidden = false;
  $('btn-open-web').hidden = !state.config?.serverUrl || state.config?.connectionMode === 'desktop';

  const cachedUser = state.config?.lastConnectedUser;
  setConnectionIndicator(
    'connected',
    cachedUser?.displayName || cachedUser?.username || '已连接',
  );

  renderTargetControls();
  hydratePageTab();
  hydrateBookmarksTab();
  hydrateTextTab();
  initColorTab();

  // Auto-focus Bookmark Import tab when on a genuine X Bookmarks/History/Likes or Xiaohongshu Collect page, or a job is active!
  const jobRunning =
    state.bookmarkJob &&
    (state.bookmarkJob.status === 'running' || state.bookmarkJob.status === 'paused');
  if ((state.collectionPage.supported && state.collectionPage.isCollectionRoute !== false) || jobRunning) {
    switchTab('bookmarks');
  } else if (state.pageContext?.selection && state.pageContext.selection.length >= 2) {
    $('tab-text').textContent = '文字 ·';
  }

  if (shouldRefreshLive) {
    void refreshTargetsLive(true);
  }
}

function enterOnboardingMode(initialPairResult = null) {
  $('view-workbench').hidden = true;
  $('view-onboarding').hidden = false;
  $('btn-open-web').hidden = true;
  setConnectionIndicator('idle', '未连接');

  setOnboardingMode(state.config?.connectionMode || 'desktop');
  if (state.config?.serverUrl) {
    $('onboard-server').value = state.config.serverUrl;
  }
  if (state.config?.apiToken) {
    $('onboard-token').value = state.config.apiToken;
  }

  const infoEl = $('onboard-info');
  const errEl = $('onboard-error');
  const detailsEl = $('onboard-manual-details');

  if (initialPairResult?.reason === 'AUTO_PAIR_DISABLED' && initialPairResult.serverUrl) {
    setOnboardingMode('desktop');
    $('onboard-server').value = initialPairResult.serverUrl;
    if (detailsEl) detailsEl.open = true;
    errEl.hidden = true;
    infoEl.textContent = initialPairResult.error;
    infoEl.hidden = false;
  } else if (initialPairResult && !initialPairResult.ok && initialPairResult.error) {
    if (initialPairResult.foundDesktop && detailsEl) detailsEl.open = true;
    infoEl.hidden = true;
    errEl.textContent = initialPairResult.error;
    errEl.hidden = false;
  } else {
    infoEl.hidden = true;
    errEl.hidden = true;
  }
}

function bindEvents() {
  $('btn-open-options').addEventListener('click', () => {
    ext.runtime.openOptionsPage?.();
  });

  $('btn-open-web').addEventListener('click', () => {
    if (state.config?.serverUrl) {
      ext.tabs.create({ url: state.config.serverUrl });
    }
  });

  $('btn-onboard-detect').addEventListener('click', () => {
    void probeDesktopInOnboarding(false);
  });

  for (const btn of document.querySelectorAll('.seg-btn[data-onboard-mode]')) {
    btn.addEventListener('click', () => setOnboardingMode(btn.dataset.onboardMode));
  }

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

  // Action Tabs + Keyboard Navigation
  const tabButtons = Array.from(document.querySelectorAll('.tab-btn[data-tab]'));
  for (let i = 0; i < tabButtons.length; i++) {
    const btn = tabButtons[i];
    btn.addEventListener('click', () => switchTab(btn.dataset.tab));
    btn.addEventListener('keydown', (e) => {
      if (e.key === 'ArrowRight' || e.key === 'ArrowLeft') {
        e.preventDefault();
        const delta = e.key === 'ArrowRight' ? 1 : -1;
        const nextBtn = tabButtons[(i + delta + tabButtons.length) % tabButtons.length];
        switchTab(nextBtn.dataset.tab);
        nextBtn.focus();
      }
    });
  }

  // Tab 1
  $('btn-save-page').addEventListener('click', () => void handleSavePage());
  $('btn-capture-visible').addEventListener('click', () => void handleCaptureVisible());

  // Tab 2: Bookmarks Batch Importer
  $('btn-bm-start').addEventListener('click', () => void handleStartBookmarkImport());
  $('btn-bm-quick-folder').addEventListener('click', () => void handleQuickCreateCollectionFolder());
  $('btn-bm-pause').addEventListener('click', async () => {
    if (!state.activeTab?.id) return;
    const msgType = state.bookmarkJob?.status === 'paused' ? 'RESUME_BOOKMARK_IMPORT' : 'PAUSE_BOOKMARK_IMPORT';
    const res = await queryTabContent(state.activeTab, { type: msgType });
    if (res?.job) renderBookmarkJobProgress(res.job);
  });
  $('btn-bm-stop').addEventListener('click', async () => {
    if (!state.activeTab?.id) return;
    const res = await queryTabContent(state.activeTab, { type: 'STOP_BOOKMARK_IMPORT' });
    if (res?.job) renderBookmarkJobProgress(res.job);
  });
  $('btn-goto-x-bookmarks').addEventListener('click', () => {
    ext.tabs.create({ url: 'https://x.com/i/bookmarks' });
  });
  $('btn-goto-xhs-collect').addEventListener('click', () => {
    ext.tabs.create({ url: 'https://www.xiaohongshu.com/explore' });
  });

  // Tab 3: Images
  $('btn-select-large').addEventListener('click', handleSelectLargeImages);
  $('btn-clear-images').addEventListener('click', handleClearImages);
  $('btn-rescan-images').addEventListener('click', () => void scanCurrentPageImages());
  $('btn-save-images').addEventListener('click', () => void handleSaveSelectedImages());

  // Tab 4: Text
  $('text-body-input').addEventListener('input', updateTextCharCount);
  $('btn-save-text').addEventListener('click', () => void handleSaveText());

  // Tab 5: Color
  $('btn-eyedropper').addEventListener('click', () => void handleEyeDropper());
  $('color-native-input').addEventListener('input', (e) => {
    updateSwatchPreview(e.target.value, true);
  });
  $('color-hex-input').addEventListener('input', (e) => {
    const val = e.target.value.trim();
    if (/^#?[0-9a-fA-F]{6}$/.test(val)) {
      updateSwatchPreview(val, false);
      $('color-native-input').value = state.currentHex;
    }
  });
  $('btn-save-color').addEventListener('click', () => void handleSaveColor());

  // Live updates from background worker
  ext.runtime?.onMessage?.addListener((msg) => {
    if (msg?.type === 'BATCH_INGEST_PROGRESS' && state.isBusy) {
      $('btn-save-images').textContent = `正在收藏 ${msg.completed}/${msg.total}…`;
    }
    if (msg?.type === 'BOOKMARK_JOB_UPDATE' && msg.job) {
      if (!msg.tabId || !state.activeTab?.id || msg.tabId === state.activeTab.id) {
        renderBookmarkJobProgress(msg.job);
      }
    }
  });
}

async function init() {
  bindEvents();
  const [config, tabs] = await Promise.all([
    getConfig(),
    ext.tabs.query({ active: true, currentWindow: true }),
  ]);
  state.config = config;
  state.activeTab = tabs?.[0] || null;

  if (state.activeTab && isCapturablePageUrl(state.activeTab.url)) {
    state.pageContext = await queryTabContent(state.activeTab, { type: 'GET_PAGE_CONTEXT' });
  }

  if (isConfigured(state.config)) {
    await enterWorkbenchMode(true);
    return;
  }

  // Zero-config same-machine desktop auto-pairing before ever showing onboarding!
  if (state.config?.connectionMode !== 'web') {
    setConnectionIndicator('checking', '自动连接中…');
    const paired = await sendBg({ type: 'AUTO_PAIR_LOCAL_DESKTOP', force: false }).catch(() => null);
    if (paired?.ok && paired.config) {
      state.config = paired.config;
      await enterWorkbenchMode(false);
      return;
    }
    enterOnboardingMode(paired);
    return;
  }

  enterOnboardingMode();
}

void init();
