/**
 * Charkle Extension — Lightweight In-Page Helper
 *
 * 1. Responds to SCAN_PAGE_IMAGES & GET_PAGE_CONTEXT from popup.js
 * 2. Optional Cross-Site Drag-to-Collect Corner Drop Dock (default enabled;
 *    never activates on Charkle's own origin or during normal browsing)
 * 3. Renders status toasts inside an isolated overlay root
 */

(() => {
  if (window.__charkleClipperLoaded) return;
  window.__charkleClipperLoaded = true;

  const STORAGE_KEY = 'charkleClipperConfig';
  const MIN_DIM = 64;
  const MAX_SCAN_IMAGES = 60;

  const runtimeState = {
    enableDragDrop: true,
    configured: false,
    isOwnOrigin: false,
    targetLabel: '收件箱',
  };

  let shadowHost = null;
  let shadowRoot = null;
  let dropPillEl = null;
  let dropPillTitleEl = null;
  let toastEl = null;
  let toastIconEl = null;
  let toastTextEl = null;
  let toastDetailEl = null;

  let activeDragImage = null;
  let isDockVisible = false;
  let toastHideTimer = null;
  let isToastHovered = false;

  // MARK: - Config Sync (never runs drag dock on Charkle Web's own origin)

  function normalizeOrigin(rawUrl) {
    try {
      const trimmed = String(rawUrl || '').trim();
      if (!trimmed) return '';
      const candidate = /^https?:\/\//i.test(trimmed) ? trimmed : `https://${trimmed}`;
      return new URL(candidate).origin;
    } catch {
      return '';
    }
  }

  function applyConfigSnapshot(cfg) {
    if (!cfg || typeof cfg !== 'object') {
      runtimeState.configured = false;
      runtimeState.isOwnOrigin = false;
      runtimeState.enableDragDrop = true;
      runtimeState.targetLabel = '收件箱';
      return;
    }
    const serverOrigin = normalizeOrigin(cfg.serverUrl);
    runtimeState.configured = Boolean(serverOrigin && String(cfg.apiToken || '').trim());
    runtimeState.isOwnOrigin = Boolean(serverOrigin && serverOrigin === window.location.origin);
    runtimeState.enableDragDrop = cfg.enableDragDrop !== false;

    if (cfg.targetMode === 'folder' && cfg.targetFolderId) {
      const matched = Array.isArray(cfg.cachedFolders)
        ? cfg.cachedFolders.find((f) => f.id === cfg.targetFolderId)
        : null;
      runtimeState.targetLabel = matched?.name || cfg.targetFolderName || '指定文件夹';
    } else if (cfg.targetMode === 'board' && cfg.targetBoardId) {
      const matched = Array.isArray(cfg.cachedBoards)
        ? cfg.cachedBoards.find((b) => b.id === cfg.targetBoardId)
        : null;
      runtimeState.targetLabel = matched?.title || cfg.targetBoardName || '当前情绪板';
    } else {
      runtimeState.targetLabel = '收件箱';
    }

    if (dropPillEl && !dropPillEl.classList.contains('is-over')) {
      updateDropPillCopy(false);
    }
    if (runtimeState.isOwnOrigin || !runtimeState.enableDragDrop || !runtimeState.configured) {
      hideDropDock();
    }
  }

  function initConfigSync() {
    if (!chrome?.storage?.local) return;
    chrome.storage.local
      .get(STORAGE_KEY)
      .then((res) => applyConfigSnapshot(res?.[STORAGE_KEY]))
      .catch(() => {});

    chrome.storage.onChanged.addListener((changes, areaName) => {
      if (areaName === 'local' && changes[STORAGE_KEY]) {
        applyConfigSnapshot(changes[STORAGE_KEY].newValue);
      }
    });
  }

  // MARK: - Isolated Overlay (mounted lazily on first drag or toast)

  function ensureShadowUI() {
    if (shadowRoot) return shadowRoot;

    shadowHost = document.createElement('div');
    shadowHost.id = 'charkle-clipper-host';
    shadowHost.style.cssText = 'all: initial; position: fixed; inset: 0; pointer-events: none; z-index: 2147483646;';
    shadowRoot = shadowHost.attachShadow({ mode: 'open' });

    const lightIconUrl = chrome.runtime.getURL('icons/charkle-light.svg');
    const darkIconUrl = chrome.runtime.getURL('icons/charkle-dark.svg');

    const style = document.createElement('style');
    style.textContent = `
      :host {
        --bg-surface: rgba(255, 255, 255, 0.84);
        --bg-surface-active: rgba(255, 255, 255, 0.94);
        --bg-solid: #FFFFFF;
        --text-primary: #18191C;
        --text-secondary: #5C6069;
        --border-hairline: rgba(0, 0, 0, 0.09);
        --accent: #2A60E0;
        --accent-soft: rgba(42, 96, 224, 0.12);
        --success: #249A4B;
        --success-soft: rgba(36, 154, 75, 0.13);
        --danger: #D93B30;
        --danger-soft: rgba(217, 59, 48, 0.12);
        --shadow-float:
          inset 0 1px 0 rgba(255, 255, 255, 0.9),
          inset 1px 0 0 rgba(255, 255, 255, 0.56),
          0 0 0 0.5px rgba(0, 0, 0, 0.08),
          0 12px 32px rgba(0, 0, 0, 0.12);
        --ease-out: cubic-bezier(0.23, 1, 0.32, 1);
        --ease-out-strong: cubic-bezier(0.22, 1, 0.36, 1);
        --backdrop: blur(22px) saturate(180%) brightness(1.04);
        font-family: -apple-system, BlinkMacSystemFont, "SF Pro Text", "PingFang SC", "Hiragino Sans GB", "Noto Sans SC", Inter, system-ui, sans-serif;
        -webkit-font-smoothing: antialiased;
      }

      @media (prefers-color-scheme: dark) {
        :host {
          --bg-surface: rgba(24, 26, 32, 0.86);
          --bg-surface-active: rgba(32, 35, 43, 0.95);
          --bg-solid: #1E2025;
          --text-primary: #F2F3F5;
          --text-secondary: #A1A6B0;
          --border-hairline: rgba(255, 255, 255, 0.11);
          --accent: #5B8DEF;
          --accent-soft: rgba(91, 141, 239, 0.18);
          --success: #34C769;
          --success-soft: rgba(52, 199, 105, 0.18);
          --danger: #F2584D;
          --danger-soft: rgba(242, 88, 77, 0.18);
          --shadow-float:
            inset 0 1px 0 rgba(255, 255, 255, 0.14),
            inset 1px 0 0 rgba(255, 255, 255, 0.07),
            0 0 0 0.5px rgba(255, 255, 255, 0.11),
            0 14px 36px rgba(0, 0, 0, 0.44);
          --backdrop: blur(22px) saturate(165%) brightness(0.92);
        }
      }

      @supports (corner-shape: superellipse(1.25)) {
        .ck-pill, .ck-icon-tile, .ck-toast, .ck-toast-icon {
          corner-shape: superellipse(1.25);
        }
      }

      @media (prefers-reduced-transparency: reduce) {
        .ck-pill, .ck-toast {
          background: var(--bg-solid);
          backdrop-filter: none;
          -webkit-backdrop-filter: none;
        }
      }

      /* Corner Drag-to-Collect Drop Pill (16px outer / 8px padding / 8px inner) */
      .ck-pill {
        position: fixed;
        right: 20px;
        bottom: 20px;
        display: flex;
        align-items: center;
        gap: 10px;
        max-width: 340px;
        padding: 8px 16px 8px 8px;
        border-radius: 16px;
        border: 1px solid var(--border-hairline);
        background: var(--bg-surface);
        backdrop-filter: var(--backdrop);
        -webkit-backdrop-filter: var(--backdrop);
        box-shadow: var(--shadow-float);
        color: var(--text-primary);
        pointer-events: none;
        opacity: 0;
        transform: translateY(12px) scale(0.96);
        transition:
          opacity 140ms var(--ease-out),
          transform 140ms var(--ease-out),
          border-color 160ms var(--ease-out-strong),
          background-color 160ms var(--ease-out-strong),
          box-shadow 160ms var(--ease-out-strong);
        user-select: none;
        box-sizing: border-box;
      }

      .ck-pill.is-visible {
        pointer-events: auto;
        opacity: 1;
        transform: translateY(0) scale(1);
        transition:
          opacity 190ms var(--ease-out-strong),
          transform 220ms var(--ease-out-strong),
          border-color 160ms var(--ease-out-strong),
          background-color 160ms var(--ease-out-strong),
          box-shadow 160ms var(--ease-out-strong);
      }

      .ck-pill.is-visible.is-over {
        background: var(--bg-surface-active);
        border-color: var(--accent);
        box-shadow:
          0 0 0 3px var(--accent-soft),
          var(--shadow-float);
        transform: translateY(-2px) scale(1.02);
      }

      .ck-icon-tile {
        width: 32px;
        height: 32px;
        flex-shrink: 0;
        border-radius: 8px;
        display: grid;
        place-items: center;
        background: var(--accent-soft);
      }

      .ck-brand-img {
        width: 20px;
        height: 20px;
        display: block;
        pointer-events: none;
      }

      .ck-brand-dark { display: none; }
      @media (prefers-color-scheme: dark) {
        .ck-brand-light { display: none; }
        .ck-brand-dark { display: block; }
      }

      .ck-pill-copy {
        display: flex;
        flex-direction: column;
        min-width: 0;
        gap: 1px;
        pointer-events: none;
      }

      .ck-pill-title {
        font-size: 13px;
        font-weight: 600;
        line-height: 1.3;
        letter-spacing: -0.01em;
        white-space: nowrap;
        overflow: hidden;
        text-overflow: ellipsis;
      }

      /* In-Page Status Toast (CSS transition retargeting) */
      .ck-toast {
        position: fixed;
        right: 20px;
        bottom: 20px;
        display: flex;
        align-items: center;
        gap: 10px;
        max-width: 340px;
        min-height: 44px;
        padding: 8px 14px 8px 8px;
        border-radius: 16px;
        border: 1px solid var(--border-hairline);
        background: var(--bg-surface);
        backdrop-filter: var(--backdrop);
        -webkit-backdrop-filter: var(--backdrop);
        box-shadow: var(--shadow-float);
        color: var(--text-primary);
        pointer-events: none;
        opacity: 0;
        transform: translateY(10px) scale(0.96);
        transition:
          opacity 140ms var(--ease-out),
          transform 150ms var(--ease-out);
        box-sizing: border-box;
      }

      .ck-toast.is-visible {
        pointer-events: auto;
        opacity: 1;
        transform: translateY(0) scale(1);
        transition:
          opacity 180ms var(--ease-out-strong),
          transform 220ms var(--ease-out-strong);
      }

      .ck-toast-icon {
        width: 28px;
        height: 28px;
        flex-shrink: 0;
        border-radius: 8px;
        display: grid;
        place-items: center;
        background: var(--accent-soft);
        color: var(--accent);
      }

      .ck-toast[data-variant="success"] .ck-toast-icon {
        background: var(--success-soft);
        color: var(--success);
      }

      .ck-toast[data-variant="error"] .ck-toast-icon {
        background: var(--danger-soft);
        color: var(--danger);
      }

      .ck-toast-body {
        display: flex;
        flex-direction: column;
        min-width: 0;
        gap: 1px;
      }

      .ck-toast-text {
        font-size: 13px;
        font-weight: 550;
        line-height: 1.3;
        white-space: nowrap;
        overflow: hidden;
        text-overflow: ellipsis;
      }

      .ck-toast-detail {
        font-size: 11px;
        line-height: 1.3;
        color: var(--text-secondary);
        white-space: nowrap;
        overflow: hidden;
        text-overflow: ellipsis;
      }

      .ck-toast-detail:empty {
        display: none;
      }

      @keyframes ck-spin {
        to { transform: rotate(360deg); }
      }

      .ck-spinner {
        width: 14px;
        height: 14px;
        border: 2px solid currentColor;
        border-top-color: transparent;
        border-radius: 999px;
        animation: ck-spin 700ms linear infinite;
      }

      @media (prefers-reduced-motion: reduce) {
        .ck-pill,
        .ck-pill.is-visible,
        .ck-pill.is-visible.is-over,
        .ck-toast,
        .ck-toast.is-visible {
          transform: none;
          transition:
            opacity 150ms linear,
            border-color 150ms linear,
            background-color 150ms linear;
        }
        .ck-spinner {
          animation-duration: 1400ms;
        }
      }
    `;

    // Drop Pill
    dropPillEl = document.createElement('div');
    dropPillEl.className = 'ck-pill';
    dropPillEl.setAttribute('aria-hidden', 'true');
    dropPillEl.innerHTML = `
      <div class="ck-icon-tile">
        <img class="ck-brand-img ck-brand-light" src="${lightIconUrl}" alt="" />
        <img class="ck-brand-img ck-brand-dark" src="${darkIconUrl}" alt="" />
      </div>
      <div class="ck-pill-copy">
        <span class="ck-pill-title"></span>
      </div>
    `;
    dropPillTitleEl = dropPillEl.querySelector('.ck-pill-title');
    updateDropPillCopy(false);

    dropPillEl.addEventListener('dragenter', (e) => {
      if (!isDockVisible) return;
      e.preventDefault();
      e.stopPropagation();
      dropPillEl.classList.add('is-over');
      updateDropPillCopy(true);
    });

    dropPillEl.addEventListener('dragover', (e) => {
      if (!isDockVisible) return;
      e.preventDefault();
      e.stopPropagation();
      if (e.dataTransfer) {
        e.dataTransfer.dropEffect = 'copy';
      }
      if (!dropPillEl.classList.contains('is-over')) {
        dropPillEl.classList.add('is-over');
        updateDropPillCopy(true);
      }
    });

    dropPillEl.addEventListener('dragleave', (e) => {
      if (!isDockVisible) return;
      if (e.relatedTarget && dropPillEl.contains(e.relatedTarget)) return;
      dropPillEl.classList.remove('is-over');
      updateDropPillCopy(false);
    });

    dropPillEl.addEventListener('drop', (e) => {
      if (!isDockVisible) return;
      e.preventDefault();
      e.stopPropagation();
      const dropped = extractImageFromDropEvent(e) || activeDragImage;
      hideDropDock();
      if (dropped && dropped.url) {
        collectDroppedImage(dropped);
      }
    });

    // Status Toast
    toastEl = document.createElement('div');
    toastEl.className = 'ck-toast';
    toastEl.setAttribute('role', 'status');
    toastEl.setAttribute('aria-live', 'polite');
    toastEl.dataset.variant = 'success';
    toastEl.innerHTML = `
      <div class="ck-toast-icon"></div>
      <div class="ck-toast-body">
        <span class="ck-toast-text"></span>
        <span class="ck-toast-detail"></span>
      </div>
    `;
    toastIconEl = toastEl.querySelector('.ck-toast-icon');
    toastTextEl = toastEl.querySelector('.ck-toast-text');
    toastDetailEl = toastEl.querySelector('.ck-toast-detail');

    toastEl.addEventListener('mouseenter', () => {
      isToastHovered = true;
      if (toastHideTimer) {
        clearTimeout(toastHideTimer);
        toastHideTimer = null;
      }
    });
    toastEl.addEventListener('mouseleave', () => {
      isToastHovered = false;
      if (toastEl.classList.contains('is-visible') && toastEl.dataset.variant !== 'progress') {
        scheduleToastHide(1800);
      }
    });

    shadowRoot.append(style, dropPillEl, toastEl);
    (document.documentElement || document.body).appendChild(shadowHost);
    return shadowRoot;
  }

  function updateDropPillCopy(isHovering) {
    if (!dropPillTitleEl) return;
    dropPillTitleEl.textContent = isHovering
      ? `松手收藏 · ${runtimeState.targetLabel}`
      : `收藏到 Charkle · ${runtimeState.targetLabel}`;
  }

  function showDropDock() {
    ensureShadowUI();
    isDockVisible = true;
    hideToastImmediate();
    dropPillEl.classList.remove('is-over');
    updateDropPillCopy(false);
    dropPillEl.setAttribute('aria-hidden', 'false');
    requestAnimationFrame(() => {
      if (isDockVisible && dropPillEl) {
        dropPillEl.classList.add('is-visible');
      }
    });
  }

  function hideDropDock() {
    isDockVisible = false;
    activeDragImage = null;
    if (dropPillEl) {
      dropPillEl.classList.remove('is-visible', 'is-over');
      dropPillEl.setAttribute('aria-hidden', 'true');
    }
  }

  function toastIconSvg(variant) {
    if (variant === 'progress') {
      return '<span class="ck-spinner" aria-hidden="true"></span>';
    }
    if (variant === 'error') {
      return '<svg width="15" height="15" viewBox="0 0 16 16" fill="none" aria-hidden="true"><path d="M8 4.5v4.2M8 11.4v.4" stroke="currentColor" stroke-width="1.8" stroke-linecap="round"/><circle cx="8" cy="8" r="6.25" stroke="currentColor" stroke-width="1.4"/></svg>';
    }
    return '<svg width="15" height="15" viewBox="0 0 16 16" fill="none" aria-hidden="true"><path d="M3.5 8.4L6.6 11.4L12.6 4.8" stroke="currentColor" stroke-width="1.8" stroke-linecap="round" stroke-linejoin="round"/></svg>';
  }

  function scheduleToastHide(delayMs) {
    if (toastHideTimer) clearTimeout(toastHideTimer);
    toastHideTimer = setTimeout(() => {
      toastHideTimer = null;
      if (!isToastHovered && toastEl) {
        toastEl.classList.remove('is-visible');
      }
    }, delayMs);
  }

  function hideToastImmediate() {
    if (toastHideTimer) {
      clearTimeout(toastHideTimer);
      toastHideTimer = null;
    }
    if (toastEl) {
      toastEl.classList.remove('is-visible');
    }
  }

  function showToast({ variant = 'success', message = '', detail = '' }) {
    if (!message) return;
    ensureShadowUI();
    if (toastHideTimer) {
      clearTimeout(toastHideTimer);
      toastHideTimer = null;
    }
    toastEl.dataset.variant = variant;
    toastIconEl.innerHTML = toastIconSvg(variant);
    toastTextEl.textContent = message;
    toastDetailEl.textContent = detail || '';
    requestAnimationFrame(() => {
      if (toastEl) toastEl.classList.add('is-visible');
    });
    if (variant !== 'progress') {
      scheduleToastHide(variant === 'error' ? 4200 : 3200);
    }
  }

  // MARK: - Drag-to-Collect Listeners

  function upgradeUrl(rawUrl) {
    if (!rawUrl) return '';
    const trimmed = String(rawUrl).trim();
    if (trimmed.startsWith('data:image/')) return trimmed;
    try {
      const u = new URL(trimmed, window.location.href);
      if (u.protocol !== 'http:' && u.protocol !== 'https:') return '';
      u.hash = '';
      if (u.hostname === 'pbs.twimg.com' && u.pathname.startsWith('/media/')) {
        const nameParam = (u.searchParams.get('name') || '').toLowerCase();
        if (
          !nameParam ||
          nameParam === 'small' ||
          nameParam === 'medium' ||
          nameParam === 'thumb' ||
          /^\d+x\d+$/.test(nameParam)
        ) {
          u.searchParams.set('name', 'large');
        }
      }
      return u.href;
    } catch {
      return '';
    }
  }

  function pickBestSrcset(srcset) {
    if (!srcset) return '';
    let best = '';
    let bestScore = -1;
    const entries = srcset.split(/,\s+(?=\S)/);
    for (const entry of entries) {
      const parts = entry.trim().split(/\s+/);
      const urlPart = parts[0];
      if (!urlPart || urlPart.startsWith('data:image/svg')) continue;
      let score = 1;
      const desc = parts[1] || '';
      const wMatch = /^(\d+)w$/i.exec(desc);
      const xMatch = /^(\d+(?:\.\d+)?)x$/i.exec(desc);
      if (wMatch) score = Number.parseInt(wMatch[1], 10);
      else if (xMatch) score = Number.parseFloat(xMatch[1]) * 1000;
      if (score >= bestScore) {
        best = upgradeUrl(urlPart);
        bestScore = score;
      }
    }
    return best;
  }

  function extractImageFromImgElement(img) {
    if (!img || img.tagName !== 'IMG') return null;
    const w = img.naturalWidth || img.clientWidth || 0;
    const h = img.naturalHeight || img.clientHeight || 0;
    if (w > 0 && h > 0 && (w < 32 || h < 32)) return null;

    let bestUrl = '';
    const picture = img.closest('picture');
    if (picture) {
      for (const source of picture.querySelectorAll('source[srcset]')) {
        const candidate = pickBestSrcset(source.getAttribute('srcset') || '');
        if (candidate) {
          bestUrl = candidate;
          break;
        }
      }
    }
    if (!bestUrl && img.getAttribute('srcset')) {
      bestUrl = pickBestSrcset(img.getAttribute('srcset'));
    }
    if (!bestUrl) {
      bestUrl = upgradeUrl(
        img.currentSrc ||
          img.getAttribute('data-original') ||
          img.getAttribute('data-src') ||
          img.src ||
          '',
      );
    }
    if (!bestUrl) return null;
    return {
      url: bestUrl,
      title: (img.alt || img.title || document.title || '').trim().slice(0, 120),
    };
  }

  function extractImageFromDragStart(event) {
    const target = event.target;
    if (target instanceof Element) {
      if (target.tagName === 'IMG') {
        return extractImageFromImgElement(target);
      }
      const nestedImg = target.querySelector?.('img');
      if (nestedImg) {
        return extractImageFromImgElement(nestedImg);
      }
      const closestImg = target.closest?.('picture')?.querySelector('img');
      if (closestImg) {
        return extractImageFromImgElement(closestImg);
      }
    }
    return null;
  }

  function extractImageFromDropEvent(event) {
    const dt = event.dataTransfer;
    if (!dt) return null;

    const html = dt.getData('text/html');
    if (html) {
      const match = /<img[^>]+src=["']([^"']+)["']/i.exec(html);
      if (match && match[1]) {
        const resolved = upgradeUrl(match[1].replace(/&amp;/g, '&'));
        if (resolved) {
          const altMatch = /<img[^>]+alt=["']([^"']*)["']/i.exec(html);
          return { url: resolved, title: altMatch ? altMatch[1] : document.title };
        }
      }
    }

    const uri = dt.getData('text/uri-list') || dt.getData('text/plain');
    if (uri) {
      const firstLine = uri
        .split(/\r?\n/)
        .map((line) => line.trim())
        .find((line) => line && !line.startsWith('#'));
      if (firstLine) {
        const resolved = upgradeUrl(firstLine);
        if (resolved) {
          return { url: resolved, title: document.title };
        }
      }
    }
    return null;
  }

  function collectDroppedImage(dropped) {
    showToast({
      variant: 'progress',
      message: '正在收藏图片…',
      detail: dropped.title || '',
    });
    chrome.runtime
      .sendMessage({
        type: 'INGEST_IMAGE_URL',
        imageUrl: dropped.url,
        sourcePageUrl: window.location.href,
        title: dropped.title || '',
      })
      .then((res) => {
        if (res && res.ok) {
          const savedTitle = res.assets?.[0]?.title || dropped.title || '图片';
          showToast({
            variant: 'success',
            message: `已收藏到 ${res.targetLabel || runtimeState.targetLabel}`,
            detail: savedTitle,
          });
        } else {
          showToast({
            variant: 'error',
            message: res?.error || '收藏图片失败',
          });
        }
      })
      .catch(() => {
        showToast({
          variant: 'error',
          message: '收藏失败，请重试',
        });
      });
  }

  document.addEventListener(
    'dragstart',
    (event) => {
      if (!runtimeState.enableDragDrop || !runtimeState.configured || runtimeState.isOwnOrigin) {
        return;
      }
      const candidate = extractImageFromDragStart(event);
      if (!candidate) return;
      activeDragImage = candidate;
      showDropDock();
    },
    { passive: true },
  );

  document.addEventListener(
    'dragend',
    () => {
      if (isDockVisible) hideDropDock();
    },
    { passive: true },
  );

  window.addEventListener(
    'drop',
    () => {
      if (isDockVisible) hideDropDock();
    },
    { passive: true },
  );

  window.addEventListener(
    'keydown',
    (e) => {
      if (e.key === 'Escape' && isDockVisible) {
        hideDropDock();
      }
    },
    { passive: true },
  );

  window.addEventListener(
    'blur',
    () => {
      if (isDockVisible) hideDropDock();
    },
    { passive: true },
  );

  // MARK: - High-Res Page Image Scanner

  function scanPageImages() {
    const candidates = new Map();

    function addCandidate(rawUrl, width, height, alt, source) {
      const url = upgradeUrl(rawUrl);
      if (!url) return;
      if (url.startsWith('data:image/svg+xml') && url.length < 2048) return;
      if (/(?:^|[/?&])(pixel|beacon|spacer|blank|1x1)\.(gif|png)(?:$|[?#])/i.test(url)) return;

      const w = Math.max(0, Math.round(Number(width || 0)));
      const h = Math.max(0, Math.round(Number(height || 0)));
      if (w > 0 && h > 0 && (w < MIN_DIM || h < MIN_DIM)) return;

      const existing = candidates.get(url);
      if (!existing || w * h > existing.width * existing.height) {
        candidates.set(url, {
          url,
          width: w,
          height: h,
          alt: String(alt || existing?.alt || '').trim().slice(0, 140),
          source,
        });
      }
    }

    // 1. <img> and <picture><source>
    const imgs = document.querySelectorAll('img');
    for (const img of imgs) {
      if (img.closest('#charkle-clipper-host')) continue;
      const rect = img.getBoundingClientRect();
      const w = img.naturalWidth || Math.round(rect.width);
      const h = img.naturalHeight || Math.round(rect.height);
      const alt = img.alt || img.title || '';

      let bestSrc = '';
      const picture = img.closest('picture');
      if (picture) {
        for (const sourceEl of picture.querySelectorAll('source[srcset]')) {
          const picked = pickBestSrcset(sourceEl.getAttribute('srcset') || '');
          if (picked) {
            bestSrc = picked;
            break;
          }
        }
      }
      if (!bestSrc && img.getAttribute('srcset')) {
        bestSrc = pickBestSrcset(img.getAttribute('srcset'));
      }
      const fallbackSrc =
        img.getAttribute('data-original') ||
        img.getAttribute('data-actualsrc') ||
        img.getAttribute('data-src') ||
        img.getAttribute('data-lazy-src') ||
        img.currentSrc ||
        img.src ||
        '';

      const chosen = bestSrc || fallbackSrc;
      if (chosen) {
        addCandidate(chosen, w, h, alt, picture ? 'picture' : 'img');
      }
    }

    // 2. Visible CSS background images (bounded scan to keep page responsive)
    const bgNodes = document.querySelectorAll(
      'div, section, figure, article, a, header, span, li',
    );
    const maxBgChecks = Math.min(bgNodes.length, 600);
    for (let i = 0; i < maxBgChecks; i++) {
      const el = bgNodes[i];
      const rect = el.getBoundingClientRect();
      if (rect.width < MIN_DIM || rect.height < MIN_DIM) continue;
      const bg = window.getComputedStyle(el).backgroundImage;
      if (!bg || bg === 'none' || !bg.includes('url(')) continue;
      const matches = bg.matchAll(/url\(["']?([^"')]+)["']?\)/g);
      for (const m of matches) {
        if (m[1]) {
          addCandidate(
            m[1],
            Math.round(rect.width),
            Math.round(rect.height),
            el.getAttribute('aria-label') || el.getAttribute('title') || '',
            'bg',
          );
        }
      }
    }

    // 3. Social / page cover meta images
    const metaSelectors = [
      'meta[property="og:image:secure_url"]',
      'meta[property="og:image"]',
      'meta[name="twitter:image"]',
      'meta[name="twitter:image:src"]',
    ];
    for (const sel of metaSelectors) {
      for (const meta of document.querySelectorAll(sel)) {
        const content = meta.getAttribute('content');
        if (content) {
          addCandidate(content, 0, 0, document.title || '', 'og');
        }
      }
    }
    const imageSrcLink = document.querySelector('link[rel="image_src"]');
    if (imageSrcLink?.getAttribute('href')) {
      addCandidate(imageSrcLink.getAttribute('href'), 0, 0, document.title || '', 'og');
    }

    const list = Array.from(candidates.values());
    list.sort((a, b) => {
      const areaA = a.width * a.height;
      const areaB = b.width * b.height;
      if (areaA !== areaB) return areaB - areaA;
      if (a.source === 'og' && b.source !== 'og') return -1;
      if (b.source === 'og' && a.source !== 'og') return 1;
      return a.url.localeCompare(b.url);
    });

    return list.slice(0, MAX_SCAN_IMAGES);
  }

  function getPageContext() {
    const selection = window.getSelection ? window.getSelection().toString().trim() : '';
    const descMeta =
      document.querySelector('meta[name="description"]')?.getAttribute('content') ||
      document.querySelector('meta[property="og:description"]')?.getAttribute('content') ||
      '';
    return {
      title: document.title || '',
      url: window.location.href,
      selection,
      description: descMeta.trim().slice(0, 300),
    };
  }

  chrome.runtime.onMessage.addListener((msg, _sender, sendResponse) => {
    if (!msg || typeof msg.type !== 'string') return;
    switch (msg.type) {
      case 'CHARKLE_PING':
        sendResponse({ ok: true });
        return;
      case 'GET_PAGE_CONTEXT':
        sendResponse({ ok: true, ...getPageContext() });
        return;
      case 'SCAN_PAGE_IMAGES':
        sendResponse({
          ok: true,
          images: scanPageImages(),
          ...getPageContext(),
        });
        return;
      case 'CHARKLE_TOAST':
        showToast({
          variant: msg.variant || 'success',
          message: msg.message || '',
          detail: msg.detail || '',
        });
        sendResponse({ ok: true });
        return;
    }
  });

  initConfigSync();
})();
