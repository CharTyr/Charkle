/**
 * Charkle Extension — Calm Studio Popup Controller (Chrome & Safari)
 */

import { isLargeImageCandidate } from './lib/image-filter.js';
import { resolvePostOrganizationFolderName } from './lib/social-collectors.js';
import {
  buildFolderOptions,
  DEFAULT_DESKTOP_SERVER_URL,
  getConfig,
  isConfigured,
  resolveActiveTarget,
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

const PLATFORM_BADGE_MAP = {
  x: { author_media: 'X 作者', likes: 'X 喜欢', default: 'X 书签' },
  pixiv: { bookmarks: 'Pixiv 收藏', default: 'Pixiv 画师' },
  bluesky: { likes: 'Bluesky 喜欢', default: 'Bluesky 作者' },
  threads: { author_media: 'Threads 作者', likes: 'Threads 喜欢', default: 'Threads 保存' },
  instagram: { author_media: 'Instagram', default: 'IG 收藏' },
  xiaohongshu: { profile: '小红书作者', likes: '小红书点赞', default: '小红书' },
  douyin: { profile: '抖音作者', likes: '抖音喜欢', board: '抖音收藏夹', default: '抖音收藏' },
};

const PLATFORM_NOUN_MAP = {
  x: '推文',
  pixiv: '作品',
  bluesky: '贴文',
  threads: '贴文',
  instagram: '贴文',
  xiaohongshu: '笔记',
  douyin: '作品',
};

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
  organizeMode: 'per_tweet',
  maxCount: 0,
  xhsCollectMode: 'media',
  douyinCollectMode: 'media',
  douyinContentFilter: 'all',
  douyinAutoClassify: true,
  douyinPickerOpen: false,
  douyinPickerLoading: false,
  douyinPickerItems: [],
  douyinPickerCanScrollMore: true,
  selectedDouyinKeys: new Set(),
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

function isMediaModeForPage(page) {
  if (!page?.supported) return false;
  if (['pixiv', 'bluesky', 'threads', 'instagram'].includes(page.platform)) return true;
  if (page.platform === 'x' && page.pageKind === 'author_media') return true;
  if (page.platform === 'xiaohongshu' && page.pageKind === 'profile' && state.xhsCollectMode === 'media') {
    return true;
  }
  if (page.platform === 'douyin' && page.pageKind === 'profile' && state.douyinCollectMode === 'media') {
    return true;
  }
  return false;
}

function resolveSuggestedFolderForPage(page) {
  if (!page?.supported) return '社交收藏';
  if (page.platform === 'xiaohongshu' && page.pageKind === 'profile') {
    return state.xhsCollectMode === 'bookmarks'
      ? '小红书收藏'
      : page.authorName || page.suggestedFolderName || '小红书收藏';
  }
  if (page.platform === 'douyin' && page.pageKind === 'profile') {
    return state.douyinCollectMode === 'bookmarks'
      ? '抖音收藏'
      : page.authorName || page.suggestedFolderName || '抖音收藏';
  }
  return page.suggestedFolderName || '专属目录';
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

// MARK: - Compact Collapsible Destination Bar

function renderTargetControls() {
  const cfg = state.config;
  if (!cfg) return;

  const mode = cfg.targetMode || 'inbox';
  const activeTarget = resolveActiveTarget(cfg);
  const modeTag = mode === 'folder' ? '文件夹 · ' : mode === 'board' ? '情绪板 · ' : '';
  $('dest-active-label').textContent = `${modeTag}${activeTarget.label}`;

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
            ? 'Charkle 桌面端暂未运行，请打开 Charkle 应用后点击同步重连。'
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

// MARK: - Mode Rail Tabs

function switchTab(tabKey) {
  state.activePanel = tabKey;
  for (const btn of document.querySelectorAll('.mode-btn[data-tab]')) {
    const selected = btn.dataset.tab === tabKey;
    btn.setAttribute('aria-selected', String(selected));
    btn.tabIndex = selected ? 0 : -1;
  }
  for (const panel of document.querySelectorAll('.tab-panel')) {
    panel.hidden = panel.id !== `panel-${tabKey}`;
  }
  if (tabKey === 'images') {
    updateImagesSocialHintVisibility();
    if (!state.imagesScanned) {
      void scanCurrentPageImages();
    }
  }
}

function updateImagesSocialHintVisibility() {
  const page = state.collectionPage;
  const shouldShow = Boolean(
    page?.supported && (page.platform === 'douyin' || page.platform === 'xiaohongshu'),
  );
  $('images-social-hint').hidden = !shouldShow;
  if (shouldShow) {
    $('btn-images-goto-picker').textContent = page.platform === 'douyin' ? '去挑选导入' : '去批量导入';
  }
}

// MARK: - Panel 1: Current Page & Screenshot

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

// MARK: - Panel 2: Context-First 7-Platform Batch Collector

function renderBatchSegmentedState() {
  for (const btn of document.querySelectorAll('.seg-btn[data-org-mode]')) {
    btn.setAttribute('aria-checked', String(btn.dataset.orgMode === state.organizeMode));
  }
  for (const btn of document.querySelectorAll('.seg-btn[data-max-count]')) {
    btn.setAttribute('aria-checked', String(Number(btn.dataset.maxCount) === state.maxCount));
  }
  const activeProfileMode =
    state.collectionPage?.platform === 'douyin' ? state.douyinCollectMode : state.xhsCollectMode;
  for (const btn of document.querySelectorAll('.seg-btn[data-xhs-mode]')) {
    btn.setAttribute('aria-checked', String(btn.dataset.xhsMode === activeProfileMode));
  }
  for (const btn of document.querySelectorAll('.seg-btn[data-dy-filter]')) {
    btn.setAttribute('aria-checked', String(btn.dataset.dyFilter === state.douyinContentFilter));
  }
}

function formatShortDuration(sec) {
  const total = Math.round(Number(sec) || 0);
  if (total <= 0) return '';
  const mins = Math.floor(total / 60);
  const secs = total % 60;
  return `${String(mins).padStart(2, '0')}:${String(secs).padStart(2, '0')}`;
}

function getFilteredDouyinPickerItems() {
  const items = state.douyinPickerItems || [];
  if (state.douyinContentFilter === 'video') return items.filter((i) => i.hasVideo === true);
  if (state.douyinContentFilter === 'image') return items.filter((i) => i.hasVideo === false);
  return items;
}

function updateDouyinFilterLabels() {
  const allBtn = $('btn-dy-filter-all');
  const videoBtn = $('btn-dy-filter-video');
  const imageBtn = $('btn-dy-filter-image');
  if (!allBtn || !videoBtn || !imageBtn) return;
  if (state.douyinPickerOpen && state.douyinPickerItems.length > 0) {
    const allCount = state.douyinPickerItems.length;
    const videoCount = state.douyinPickerItems.filter((i) => i.hasVideo === true).length;
    const imageCount = state.douyinPickerItems.filter((i) => i.hasVideo === false).length;
    allBtn.textContent = `全部 (${allCount})`;
    videoBtn.textContent = `仅视频 (${videoCount})`;
    imageBtn.textContent = `仅图文 (${imageCount})`;
  } else {
    allBtn.textContent = '全部';
    videoBtn.textContent = '仅视频';
    imageBtn.textContent = '仅图文';
  }
}

function updateBatchRulesSummary() {
  const page = state.collectionPage;
  if (!page?.supported) return;
  const isMedia = isMediaModeForPage(page);
  const noun = PLATFORM_NOUN_MAP[page.platform] || '作品';
  const parts = [];

  if (isMedia) {
    if (state.organizeMode === 'flat') parts.push('平铺在作者目录');
    else if (state.organizeMode === 'multi_only') parts.push(`仅多图${noun}建目录`);
    else parts.push(`按${noun}建子目录`);

    if (page.platform !== 'pixiv') {
      parts.push($('bm-opt-include-videos').checked ? '含视频' : '仅图片');
    }
    if (['x', 'bluesky', 'threads'].includes(page.platform) && page.pageKind === 'author_media') {
      if ($('bm-opt-skip-retweets').checked) parts.push('仅原创');
    }
  } else {
    parts.push(page.platform === 'douyin' ? '收藏卡片 · 在线播放' : '富卡片书签模式');
    if (page.platform === 'xiaohongshu' && $('bm-opt-xhs-detail').checked) {
      parts.push('提取多图正文');
    }
  }

  if (page.platform === 'douyin') {
    if (state.douyinContentFilter === 'video') parts.push('仅视频');
    else if (state.douyinContentFilter === 'image') parts.push('仅图文');
    if ($('bm-opt-dy-classify').checked) parts.push('自动分目录');
  }

  if ($('bm-opt-skip-dups').checked) {
    parts.push($('bm-opt-stop-streak').checked ? '增量去重' : '跳过重复');
  }
  if (state.maxCount > 0) {
    parts.push(`最多 ${state.maxCount} 条`);
  }

  $('bm-rules-summary').textContent = parts.join(' · ');

  const startBtn = $('btn-bm-start');
  const jobActive =
    state.bookmarkJob &&
    (state.bookmarkJob.status === 'running' || state.bookmarkJob.status === 'paused');
  if (!jobActive) {
    startBtn.textContent = getBatchStartButtonLabel(page, isMedia);
  }
}

function getBatchStartButtonLabel(page, isMedia) {
  if (!page?.supported) return '开始批量采集';
  if (page.platform === 'pixiv') {
    return page.pageKind === 'bookmarks' ? '一键采集 Pixiv 收藏作品' : '一键采集画师全部作品';
  }
  if (isMedia) {
    const noun = PLATFORM_NOUN_MAP[page.platform] || '作品';
    return state.organizeMode === 'flat' ? '一键采集全部媒体' : `一键采集全部媒体（按${noun}整理）`;
  }
  return '一键扫描并批量导入';
}

function syncBatchModeVisibility() {
  const page = state.collectionPage;
  if (!page?.supported) return;
  const isMedia = isMediaModeForPage(page);
  const noun = PLATFORM_NOUN_MAP[page.platform] || '作品';

  $('bm-author-media-opts').hidden = !isMedia;
  $('bm-opt-videos-row').hidden = page.platform === 'pixiv';
  $('bm-opt-retweets-row').hidden =
    !['x', 'bluesky', 'threads'].includes(page.platform) || page.pageKind !== 'author_media';
  $('bm-opt-xhs-row').hidden = !(page.platform === 'xiaohongshu' && !isMedia);
  $('bm-opt-dy-classify-row').hidden = page.platform !== 'douyin';
  $('bm-douyin-filter-wrap').hidden = page.platform !== 'douyin';
  $('btn-bm-open-picker').hidden = page.platform !== 'douyin';
  $('bm-opt-max-count-label').textContent = isMedia ? `单次${noun}上限` : '单次导入上限';
  $('btn-bm-quick-folder').textContent = `+ ${resolveSuggestedFolderForPage(page)}`;
  updateDouyinFilterLabels();
  updateBatchRulesSummary();
}

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
  $('bm-opt-include-videos').checked = cfg.authorMediaIncludeVideos !== false;
  $('bm-opt-skip-retweets').checked = cfg.authorMediaSkipRetweets !== false;

  const rawOrg = cfg.authorMediaOrganizeMode || 'per_tweet';
  state.organizeMode = rawOrg === 'per_post' ? 'per_tweet' : rawOrg;
  state.maxCount = [0, 30, 100, 300].includes(Number(cfg.bookmarkMaxCount))
    ? Number(cfg.bookmarkMaxCount)
    : 0;
  state.xhsCollectMode = cfg.xhsProfileCollectMode === 'bookmarks' ? 'bookmarks' : 'media';
  state.douyinCollectMode = cfg.douyinProfileCollectMode === 'bookmarks' ? 'bookmarks' : 'media';
  state.douyinContentFilter = ['all', 'video', 'image'].includes(cfg.douyinContentFilter)
    ? cfg.douyinContentFilter
    : 'all';
  state.douyinAutoClassify = cfg.douyinAutoClassify !== false;
  $('bm-opt-dy-classify').checked = state.douyinAutoClassify;

  renderBatchSegmentedState();
  updateImagesSocialHintVisibility();

  const supportedBlock = $('bm-supported-block');
  const guideBlock = $('bm-guide-block');
  const tabDot = $('tab-bookmarks-dot');

  if (detected.supported) {
    supportedBlock.hidden = false;
    guideBlock.hidden = true;
    const badge = $('bm-platform-badge');
    badge.dataset.kind = detected.platform;
    const badgeGroup = PLATFORM_BADGE_MAP[detected.platform] || { default: '批量采集' };
    badge.textContent = badgeGroup[detected.pageKind] || badgeGroup.default;

    $('bm-page-label').textContent = detected.label;
    $('bm-page-label').title = detected.label;
    $('btn-bm-quick-folder').textContent = `+ ${resolveSuggestedFolderForPage(detected)}`;

    const isProfileDualMode =
      (detected.platform === 'xiaohongshu' || detected.platform === 'douyin') &&
      detected.pageKind === 'profile';
    $('bm-xhs-mode-wrap').hidden = !isProfileDualMode;
    if (isProfileDualMode) {
      $('btn-profile-mode-media').textContent =
        detected.platform === 'douyin' ? '作者作品原文件' : '作者作品原图';
      $('btn-profile-mode-bookmarks').textContent =
        detected.platform === 'douyin' ? '收藏与喜欢卡片' : '收藏与点赞卡片';
    }

    tabDot.hidden = detected.isCollectionRoute === false;
    syncBatchModeVisibility();
  } else {
    supportedBlock.hidden = true;
    guideBlock.hidden = false;
    tabDot.hidden = true;
  }

  renderBookmarkJobProgress(state.pageContext?.bookmarkJob || state.bookmarkJob);
}

function renderBookmarkJobProgress(job) {
  state.bookmarkJob = job || null;
  const card = $('bm-progress-card');
  const startBtn = $('btn-bm-start');
  const pickerBtn = $('btn-bm-open-picker');
  const controls = $('bm-progress-controls');
  const isDouyin = state.collectionPage?.platform === 'douyin';
  const isMedia = job?.mode === 'author_media' || isMediaModeForPage(state.collectionPage);
  const noun = PLATFORM_NOUN_MAP[job?.platform || state.collectionPage?.platform] || '作品';

  if (!job || job.status === 'idle') {
    card.hidden = true;
    startBtn.hidden = false;
    startBtn.disabled = false;
    pickerBtn.hidden = !isDouyin;
    pickerBtn.disabled = false;
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
  $('bm-progress-stats').textContent = isMedia
    ? `${noun} ${job.discovered || 0} · 文件入库 ${job.mediaImported || 0} · 跳过 ${job.skipped || 0}${failSuffix}`
    : `发现 ${job.discovered || 0} · 导入 ${job.imported || 0} · 跳过 ${job.skipped || 0}${failSuffix}`;
  $('bm-progress-last').textContent = job.lastItemTitle ? `最新：${job.lastItemTitle}` : '';

  const isActive = job.status === 'running' || job.status === 'paused';
  if (isActive && state.douyinPickerOpen) {
    setDouyinPickerVisibility(false);
  }
  controls.hidden = !isActive;
  $('btn-bm-pause').textContent = job.status === 'paused' ? '继续' : '暂停';
  startBtn.hidden = isActive;
  startBtn.disabled = isActive;
  pickerBtn.hidden = isActive || !isDouyin;
  pickerBtn.disabled = isActive;
  if (!isActive) {
    startBtn.textContent = isMedia ? '再次扫描并采集新增' : '再次扫描并导入新增';
  }
}

async function persistBatchOptions() {
  state.douyinAutoClassify = $('bm-opt-dy-classify').checked;
  await persistTargetPatch({
    bookmarkSkipDuplicates: $('bm-opt-skip-dups').checked,
    bookmarkStopOnKnownStreak: $('bm-opt-stop-streak').checked,
    bookmarkEnrichXhsDetails: $('bm-opt-xhs-detail').checked,
    bookmarkMaxCount: state.maxCount,
    authorMediaOrganizeMode: state.organizeMode,
    authorMediaIncludeVideos: $('bm-opt-include-videos').checked,
    authorMediaSkipRetweets: $('bm-opt-skip-retweets').checked,
    xhsProfileCollectMode: state.xhsCollectMode,
    douyinProfileCollectMode: state.douyinCollectMode,
    douyinContentFilter: state.douyinContentFilter,
    douyinAutoClassify: state.douyinAutoClassify,
  });
}

async function handleStartBookmarkImport() {
  if (!state.activeTab?.id || !state.collectionPage.supported) return;
  hideStatus();

  const skipDuplicates = $('bm-opt-skip-dups').checked;
  const stopOnKnownStreak = $('bm-opt-stop-streak').checked;
  const enrichXhsDetails = $('bm-opt-xhs-detail').checked;
  const includeVideos = $('bm-opt-include-videos').checked;
  const skipRetweets = $('bm-opt-skip-retweets').checked;

  await persistBatchOptions();

  const isMedia = isMediaModeForPage(state.collectionPage);
  const btn = $('btn-bm-start');
  const defaultBtnLabel = getBatchStartButtonLabel(state.collectionPage, isMedia);
  btn.disabled = true;
  btn.textContent = '正在启动…';

  const res = await queryTabContent(state.activeTab, {
    type: 'START_BOOKMARK_IMPORT',
    options: {
      skipDuplicates,
      stopOnKnownStreak,
      enrichXhsDetails,
      maxCount: state.maxCount,
      organizeMode: state.organizeMode,
      includeVideos,
      skipRetweets,
      xhsCollectMode: state.xhsCollectMode,
      douyinCollectMode: state.douyinCollectMode,
      douyinContentFilter: state.douyinContentFilter,
      douyinAutoClassify: $('bm-opt-dy-classify').checked,
      preferredPlatform: state.collectionPage?.platform || null,
      preferredLabel: state.collectionPage?.label || null,
      preferredPageKind: state.collectionPage?.pageKind || null,
      preferredAuthorHandle: state.collectionPage?.authorHandle || null,
    },
  });

  if (res?.job) {
    renderBookmarkJobProgress(res.job);
  }
  if (res?.ok) {
    btn.textContent = defaultBtnLabel;
  } else {
    showStatus('error', res?.error || '无法在当前标签页启动批量采集，请刷新页面后重试。', 4500);
    btn.disabled = false;
    btn.textContent = defaultBtnLabel;
  }
}

async function handleQuickCreateCollectionFolder() {
  const suggested = resolveSuggestedFolderForPage(state.collectionPage);
  const btn = $('btn-bm-quick-folder');
  btn.disabled = true;
  try {
    const res = await sendBg({ type: 'CREATE_FOLDER_AND_SELECT', name: suggested });
    if (res?.ok && res.config) {
      state.config = res.config;
      renderTargetControls();
      showStatus(
        'success',
        res.reused ? `已切换目标至「${suggested}」` : `已新建并选中「${suggested}」`,
        2400,
      );
    } else {
      showStatus('error', res?.error || '创建文件夹失败', 3800);
    }
  } finally {
    btn.disabled = false;
  }
}

// MARK: - Douyin Built-in Multi-Select Picker

function setDouyinPickerVisibility(open) {
  state.douyinPickerOpen = Boolean(open);
  $('bm-douyin-picker').hidden = !state.douyinPickerOpen;
  $('bm-primary-actions').hidden = state.douyinPickerOpen;
  $('bm-options-disclosure').hidden = state.douyinPickerOpen;
  $('bm-rules-summary').hidden = state.douyinPickerOpen;
  updateDouyinFilterLabels();
}

function updateDouyinPickerActionUI() {
  const visible = getFilteredDouyinPickerItems();
  const visibleSelectedCount = visible.filter((i) => state.selectedDouyinKeys.has(i.dedupKey)).length;
  const unimportedCount = visible.filter((i) => !i.alreadyImported).length;
  $('bm-picker-summary').textContent = state.douyinPickerLoading
    ? '正在读取当前页作品…'
    : `已载入 ${visible.length} 条 · 未导入 ${unimportedCount}`;
  const importBtn = $('btn-picker-import');
  importBtn.disabled = state.isBusy || state.douyinPickerLoading || visibleSelectedCount === 0;
  if (!state.isBusy) {
    importBtn.textContent = `导入所选 (${visibleSelectedCount})`;
  }
  $('btn-picker-more').disabled = state.isBusy || state.douyinPickerLoading;
  $('btn-picker-refresh').disabled = state.isBusy || state.douyinPickerLoading;
}

function renderDouyinPickerList() {
  updateDouyinFilterLabels();
  const listEl = $('bm-picker-list');
  const emptyEl = $('bm-picker-empty');
  const emptyText = $('bm-picker-empty-text');
  const visible = getFilteredDouyinPickerItems();

  listEl.innerHTML = '';

  if (visible.length === 0) {
    listEl.hidden = true;
    emptyEl.hidden = false;
    emptyText.textContent = state.douyinPickerLoading
      ? '正在扫描当前页作品…'
      : state.douyinPickerItems.length > 0
        ? '当前筛选类型下暂无已载入作品，可切换筛选或点击「加载更多」'
        : '当前页尚未捕获到作品，可先向下滚动页面或点击「加载更多」';
    updateDouyinPickerActionUI();
    return;
  }

  emptyEl.hidden = true;
  listEl.hidden = false;

  const fragment = document.createDocumentFragment();
  for (const item of visible) {
    const selected = state.selectedDouyinKeys.has(item.dedupKey);
    const row = document.createElement('button');
    row.type = 'button';
    row.className = 'dy-picker-row';
    if (selected) row.classList.add('is-selected');
    if (item.alreadyImported) row.classList.add('is-imported');
    row.setAttribute('role', 'listitem');
    row.setAttribute('aria-pressed', String(selected));
    row.dataset.key = item.dedupKey;

    const thumb = document.createElement('div');
    thumb.className = 'dy-picker-thumb';
    if (item.coverUrl) {
      const img = document.createElement('img');
      img.src = item.coverUrl;
      img.alt = '';
      img.loading = 'lazy';
      img.decoding = 'async';
      img.referrerPolicy = 'no-referrer';
      thumb.appendChild(img);
    }
    const kindBadge = document.createElement('span');
    kindBadge.className = 'dy-picker-kind';
    if (item.hasVideo) {
      const dur = formatShortDuration(item.durationSeconds);
      kindBadge.textContent = dur ? `视频 ${dur}` : '视频';
    } else {
      kindBadge.textContent = item.imageCount > 1 ? `图文 ${item.imageCount}图` : '图文';
    }
    thumb.appendChild(kindBadge);

    const meta = document.createElement('div');
    meta.className = 'dy-picker-meta';
    const titleEl = document.createElement('span');
    titleEl.className = 'dy-picker-title';
    titleEl.textContent = item.title || '无标题抖音作品';

    const sub = document.createElement('div');
    sub.className = 'dy-picker-sub';
    const author = document.createElement('span');
    author.className = 'dy-picker-author';
    author.textContent = item.authorName || '抖音用户';
    sub.appendChild(author);

    if (item.alreadyImported) {
      const imp = document.createElement('span');
      imp.className = 'dy-picker-imported-pill';
      imp.textContent = '已导入';
      sub.appendChild(imp);
    }
    meta.append(titleEl, sub);

    const check = document.createElement('span');
    check.className = 'dy-picker-check';
    check.innerHTML =
      '<svg width="11" height="11" viewBox="0 0 12 12" fill="none" aria-hidden="true"><path d="M2.4 6.2L4.9 8.7L9.6 3.5" stroke="currentColor" stroke-width="1.8" stroke-linecap="round" stroke-linejoin="round"/></svg>';

    row.append(thumb, meta, check);
    row.addEventListener('click', () => {
      if (state.selectedDouyinKeys.has(item.dedupKey)) {
        state.selectedDouyinKeys.delete(item.dedupKey);
        row.classList.remove('is-selected');
        row.setAttribute('aria-pressed', 'false');
      } else {
        state.selectedDouyinKeys.add(item.dedupKey);
        row.classList.add('is-selected');
        row.setAttribute('aria-pressed', 'true');
      }
      updateDouyinPickerActionUI();
    });
    fragment.appendChild(row);
  }

  listEl.appendChild(fragment);
  updateDouyinPickerActionUI();
}

async function scanDouyinPickerItemsFromTab({ scrollMore = false } = {}) {
  if (!state.activeTab?.id || state.douyinPickerLoading) return;
  state.douyinPickerLoading = true;
  updateDouyinPickerActionUI();
  hideStatus();

  try {
    const isMedia = isMediaModeForPage(state.collectionPage);
    const [scanRes, existingRes] = await Promise.all([
      queryTabContent(state.activeTab, {
        type: 'SCAN_DOUYIN_PICKER_ITEMS',
        options: {
          scrollMore,
          preferredPlatform: state.collectionPage?.platform || 'douyin',
          preferredPageKind: state.collectionPage?.pageKind || null,
          preferredLabel: state.collectionPage?.label || null,
        },
      }),
      sendBg({ type: 'FETCH_EXISTING_SOURCES' }).catch(() => null),
    ]);

    const knownKeys = new Set();
    if (existingRes?.ok) {
      const keys =
        isMedia && Array.isArray(existingRes.mediaCanonicalKeys)
          ? existingRes.mediaCanonicalKeys
          : existingRes.canonicalKeys || [];
      for (const k of keys) knownKeys.add(k);
    }

    if (scanRes?.ok && Array.isArray(scanRes.items)) {
      if (scanRes.pageInfo?.supported) {
        state.collectionPage = scanRes.pageInfo;
        $('btn-bm-quick-folder').textContent = `+ ${resolveSuggestedFolderForPage(scanRes.pageInfo)}`;
      }
      state.douyinPickerCanScrollMore = Boolean(scanRes.canScrollMore);
      const prevImported = new Set(
        state.douyinPickerItems.filter((i) => i.alreadyImported).map((i) => i.dedupKey),
      );
      state.douyinPickerItems = scanRes.items.map((item) => ({
        ...item,
        alreadyImported: knownKeys.has(item.dedupKey) || prevImported.has(item.dedupKey),
      }));
    } else if (scanRes?.error) {
      showStatus('error', scanRes.error, 3800);
    }
  } catch (err) {
    showStatus('error', err instanceof Error ? err.message : '读取当前页抖音作品失败', 3800);
  } finally {
    state.douyinPickerLoading = false;
    renderDouyinPickerList();
  }
}

async function openDouyinPicker() {
  if (!state.collectionPage?.supported || state.collectionPage.platform !== 'douyin') return;
  setDouyinPickerVisibility(true);
  await scanDouyinPickerItemsFromTab({ scrollMore: false });
}

function handlePickerSelectUnimported() {
  const visible = getFilteredDouyinPickerItems();
  for (const item of visible) {
    if (!item.alreadyImported) {
      state.selectedDouyinKeys.add(item.dedupKey);
    }
  }
  renderDouyinPickerList();
}

function handlePickerClearSelection() {
  state.selectedDouyinKeys.clear();
  renderDouyinPickerList();
}

async function handleImportSelectedDouyinItems() {
  if (state.isBusy) return;
  const selectedItems = getFilteredDouyinPickerItems().filter((i) =>
    state.selectedDouyinKeys.has(i.dedupKey),
  );
  if (selectedItems.length === 0) return;

  state.isBusy = true;
  const importBtn = $('btn-picker-import');
  importBtn.disabled = true;
  importBtn.textContent = `正在导入 0/${selectedItems.length}…`;
  hideStatus();

  const isMedia = isMediaModeForPage(state.collectionPage);
  const autoClassify = $('bm-opt-dy-classify').checked;
  const includeVideos = $('bm-opt-include-videos').checked;
  const suggestedFolder = resolveSuggestedFolderForPage(state.collectionPage);

  let totalCreated = 0;
  let totalFailed = 0;
  let completed = 0;
  let lastTargetLabel = '';

  try {
    let mediaRootFolderId = null;
    if (isMedia) {
      const rootName = state.collectionPage?.authorName || suggestedFolder || '抖音作品';
      const rootRes = await sendBg({ type: 'ENSURE_AUTHOR_ROOT_FOLDER', name: rootName });
      if (!rootRes?.ok || !rootRes.folder?.id) {
        throw new Error(rootRes?.error || `无法准备目录「${rootName}」`);
      }
      mediaRootFolderId = rootRes.folder.id;
      lastTargetLabel = rootRes.targetLabel || rootName;
    }

    const chunkSize = isMedia ? (includeVideos ? 1 : 3) : 5;
    for (let i = 0; i < selectedItems.length; i += chunkSize) {
      const chunk = selectedItems.slice(i, i + chunkSize);
      const isFinalChunk = i + chunkSize >= selectedItems.length;
      let res;

      if (isMedia) {
        const posts = chunk
          .map((item) => {
            const p = item.mediaPost || {};
            const media = includeVideos
              ? p.media || []
              : (p.media || []).filter((m) => m && m.kind === 'photo');
            if (media.length === 0) return null;
            return {
              ...p,
              media,
              hasVideo: media.some((m) => m.kind === 'video' || m.kind === 'gif'),
              subfolderName: resolvePostOrganizationFolderName(p, state.organizeMode),
              organizeMode: state.organizeMode,
              includeVideos,
            };
          })
          .filter(Boolean);

        if (posts.length > 0) {
          res = await sendBg({
            type: 'INGEST_SOCIAL_MEDIA_CHUNK',
            posts,
            targetFolderId: mediaRootFolderId,
            targetBoardId: null,
            skipDuplicates: false,
            autoClassify,
            suggestedFolderName: suggestedFolder,
            isFinalChunk,
          });
        } else {
          res = { ok: true, created: 0 };
        }
      } else {
        const bookmarks = chunk.map((item) => item.bookmark).filter(Boolean);
        res = await sendBg({
          type: 'INGEST_SOCIAL_BOOKMARKS_CHUNK',
          bookmarks,
          skipDuplicates: false,
          autoClassify,
          suggestedFolderName: suggestedFolder,
          isFinalChunk,
        });
      }

      if (res?.ok) {
        totalCreated += Number(res.created || 0);
        if (res.targetLabel) lastTargetLabel = res.targetLabel;
        const doneKeys = new Set(chunk.map((item) => item.dedupKey));
        state.douyinPickerItems = state.douyinPickerItems.map((entry) =>
          doneKeys.has(entry.dedupKey) ? { ...entry, alreadyImported: true } : entry,
        );
        for (const k of doneKeys) state.selectedDouyinKeys.delete(k);
      } else {
        totalFailed += chunk.length;
      }

      completed += chunk.length;
      importBtn.textContent = `正在导入 ${completed}/${selectedItems.length}…`;
      renderDouyinPickerList();
    }

    if (totalCreated > 0 && autoClassify) {
      void refreshTargetsLive(true);
    }

    if (totalFailed === 0) {
      const destText = lastTargetLabel ? `到 ${lastTargetLabel}` : '';
      showStatus('success', `已导入 ${totalCreated || selectedItems.length} 条抖音作品${destText}`, 3800);
    } else {
      showStatus(
        'error',
        `已导入 ${totalCreated} 条，${totalFailed} 条导入失败，请稍后重试`,
        4500,
      );
    }
  } catch (err) {
    showStatus('error', err instanceof Error ? err.message : '导入所选抖音作品失败', 4500);
  } finally {
    state.isBusy = false;
    renderDouyinPickerList();
  }
}

// MARK: - Panel 3: Batch Image Grabber

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

// MARK: - Panel 4: Text Snippet

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

// MARK: - Panel 5: Color Swatch & EyeDropper

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
        res?.error || '未检测到运行中的 Charkle 桌面端，请先打开 Charkle 应用后重试。';
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
    saveBtn.textContent = '测试并保存';
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

  // Context-first auto-selection: Batch collector when on any supported creator/collection page or active job
  const jobRunning =
    state.bookmarkJob &&
    (state.bookmarkJob.status === 'running' || state.bookmarkJob.status === 'paused');
  if ((state.collectionPage.supported && state.collectionPage.isCollectionRoute !== false) || jobRunning) {
    switchTab('bookmarks');
  } else if (state.pageContext?.selection && state.pageContext.selection.length >= 2) {
    $('tab-text-dot').hidden = false;
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

  // Destination Drawer
  $('btn-refresh-targets').addEventListener('click', (e) => {
    e.stopPropagation();
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
    renderTargetControls();
  });

  $('select-board').addEventListener('change', async (e) => {
    const id = e.target.value || null;
    const matched = (state.config?.cachedBoards || []).find((b) => b.id === id);
    await persistTargetPatch({
      targetMode: 'board',
      targetBoardId: id,
      targetBoardName: matched?.title || '',
    });
    renderTargetControls();
  });

  // Mode Rail + Keyboard Arrow Navigation
  const tabButtons = Array.from(document.querySelectorAll('.mode-btn[data-tab]'));
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

  // Panel 1: Current Page
  $('btn-save-page').addEventListener('click', () => void handleSavePage());
  $('btn-capture-visible').addEventListener('click', () => void handleCaptureVisible());

  // Panel 2: Batch Collector
  $('btn-bm-start').addEventListener('click', () => void handleStartBookmarkImport());
  $('btn-bm-open-picker').addEventListener('click', () => void openDouyinPicker());
  $('btn-bm-quick-folder').addEventListener('click', () => void handleQuickCreateCollectionFolder());
  $('btn-picker-select-new').addEventListener('click', handlePickerSelectUnimported);
  $('btn-picker-clear').addEventListener('click', handlePickerClearSelection);
  $('btn-picker-more').addEventListener('click', () => void scanDouyinPickerItemsFromTab({ scrollMore: true }));
  $('btn-picker-refresh').addEventListener('click', () => void scanDouyinPickerItemsFromTab({ scrollMore: false }));
  $('btn-picker-close').addEventListener('click', () => setDouyinPickerVisibility(false));
  $('btn-picker-import').addEventListener('click', () => void handleImportSelectedDouyinItems());

  for (const btn of document.querySelectorAll('.seg-btn[data-dy-filter]')) {
    btn.addEventListener('click', () => {
      state.douyinContentFilter = btn.dataset.dyFilter || 'all';
      renderBatchSegmentedState();
      updateBatchRulesSummary();
      if (state.douyinPickerOpen) renderDouyinPickerList();
      void persistBatchOptions();
    });
  }
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

  for (const btn of document.querySelectorAll('.seg-btn[data-org-mode]')) {
    btn.addEventListener('click', () => {
      state.organizeMode = btn.dataset.orgMode || 'per_tweet';
      renderBatchSegmentedState();
      updateBatchRulesSummary();
      void persistBatchOptions();
    });
  }

  for (const btn of document.querySelectorAll('.seg-btn[data-max-count]')) {
    btn.addEventListener('click', () => {
      state.maxCount = Number(btn.dataset.maxCount || 0);
      renderBatchSegmentedState();
      updateBatchRulesSummary();
      void persistBatchOptions();
    });
  }

  for (const btn of document.querySelectorAll('.seg-btn[data-xhs-mode]')) {
    btn.addEventListener('click', () => {
      const nextMode = btn.dataset.xhsMode === 'bookmarks' ? 'bookmarks' : 'media';
      if (state.collectionPage?.platform === 'douyin') {
        state.douyinCollectMode = nextMode;
      } else {
        state.xhsCollectMode = nextMode;
      }
      renderBatchSegmentedState();
      syncBatchModeVisibility();
      void persistBatchOptions();
    });
  }

  for (const id of [
    'bm-opt-include-videos',
    'bm-opt-skip-retweets',
    'bm-opt-xhs-detail',
    'bm-opt-dy-classify',
    'bm-opt-skip-dups',
    'bm-opt-stop-streak',
  ]) {
    $(id).addEventListener('change', () => {
      updateBatchRulesSummary();
      void persistBatchOptions();
    });
  }

  for (const tile of document.querySelectorAll('.platform-tile[data-open-url]')) {
    tile.addEventListener('click', () => {
      const targetUrl = tile.dataset.openUrl;
      if (targetUrl) ext.tabs.create({ url: targetUrl });
    });
  }

  // Panel 3: Images
  $('btn-images-goto-picker').addEventListener('click', () => {
    switchTab('bookmarks');
    if (state.collectionPage?.platform === 'douyin') {
      void openDouyinPicker();
    }
  });
  $('btn-select-large').addEventListener('click', handleSelectLargeImages);
  $('btn-clear-images').addEventListener('click', handleClearImages);
  $('btn-rescan-images').addEventListener('click', () => void scanCurrentPageImages());
  $('btn-save-images').addEventListener('click', () => void handleSaveSelectedImages());

  // Panel 4: Text
  $('text-body-input').addEventListener('input', updateTextCharCount);
  $('btn-save-text').addEventListener('click', () => void handleSaveText());

  // Panel 5: Color
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
