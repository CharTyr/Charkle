/**
 * Charkle Extension — In-Page Helper & Autonomous X / Xiaohongshu Bookmark Batch Collector
 *
 * 1. Responds to SCAN_PAGE_IMAGES & GET_PAGE_CONTEXT (including live Xiaohongshu note extraction)
 * 2. Optional Cross-Site Drag-to-Collect Corner Drop Dock
 * 3. Autonomous One-Click Batch Importer for X Bookmarks/Likes & Xiaohongshu Collections/Boards
 *    with MutationObserver + humanized scrolling, incremental dedup, in-browser XHS detail enrichment,
 *    streaming chunk upload, and an isolated Shadow DOM live progress HUD.
 */

(() => {
  // Never run inside sub-iframes so hidden third-party or auth iframes cannot hijack tab messages.
  if (window !== window.top) return;
  if (window.__charkleClipperLoaded) return;
  window.__charkleClipperLoaded = true;

  const ext = globalThis.browser ?? globalThis.chrome;
  const STORAGE_KEY = 'charkleClipperConfig';
  const MIN_DIM = 64;
  const MAX_SCAN_IMAGES = 60;

  const runtimeState = {
    enableDragDrop: true,
    enableBookmarkFloatingButton: true,
    configured: false,
    isOwnOrigin: false,
    targetLabel: '收件箱',
    config: null,
  };

  let shadowHost = null;
  let shadowRoot = null;
  let dropPillEl = null;
  let dropPillTitleEl = null;
  let toastEl = null;
  let toastIconEl = null;
  let toastTextEl = null;
  let toastDetailEl = null;
  let launchPillEl = null;
  let launchPillBtnEl = null;
  let launchPillLabelEl = null;
  let hudEl = null;
  let hudTitleEl = null;
  let hudPhaseEl = null;
  let hudBarFillEl = null;
  let hudStatsEl = null;
  let hudLastItemEl = null;
  let hudPauseBtnEl = null;
  let hudStopBtnEl = null;
  let hudCloseBtnEl = null;

  let activeDragImage = null;
  let isDockVisible = false;
  let toastHideTimer = null;
  let isToastHovered = false;
  let launchPillDismissedForHref = '';

  const batchJob = {
    status: 'idle', // 'idle' | 'running' | 'paused' | 'done' | 'stopped' | 'error'
    mode: 'bookmarks', // 'bookmarks' | 'author_media'
    platform: null, // 'x' | 'xiaohongshu'
    platformLabel: '',
    authorHandle: '',
    phase: '',
    discovered: 0,
    queued: 0,
    imported: 0,
    mediaImported: 0,
    skipped: 0,
    failed: 0,
    lastItemTitle: '',
    errorMessage: '',
    stopRequested: false,
    pauseRequested: false,
    targetLabel: '收件箱',
    startedAt: 0,
  };

  // Passively captured media posts from `page-bridge.js` across X, Bluesky, Threads & Instagram
  const capturedXTweetsById = new Map();
  const capturedSocialPostsByKey = new Map();
  const MAX_CAPTURED_SOCIAL_POSTS = 5000;

  function trimCapturedMap(map, limit) {
    if (map.size <= limit) return;
    const overflow = map.size - limit;
    let removed = 0;
    for (const key of map.keys()) {
      map.delete(key);
      removed += 1;
      if (removed >= overflow) break;
    }
  }

  function initXGraphQLBridgeListener() {
    const host = window.location.hostname.toLowerCase();
    if (!isXHost(host) && !isBlueskyHost(host) && !isThreadsHost(host) && !isInstagramHost(host)) {
      return;
    }
    window.addEventListener('message', (event) => {
      if (event.source !== window || event.origin !== window.location.origin) return;
      const data = event.data;
      if (!data || (data.__charkleSocialBridge !== true && data.__charkleXBridge !== true)) return;
      const incoming = Array.isArray(data.posts)
        ? data.posts
        : Array.isArray(data.tweets)
          ? data.tweets
          : [];
      for (const post of incoming) {
        if (!post) continue;
        const postID = String(post.postID || post.tweetID || '').trim();
        if (!postID) continue;
        const platform = post.platform || data.platform || 'x';
        const dedupKey = post.dedupKey || `${platform}:${postID}`;
        const prev = capturedSocialPostsByKey.get(dedupKey);
        if (!prev || (Array.isArray(post.media) && post.media.length >= (prev.media?.length || 0))) {
          capturedSocialPostsByKey.set(dedupKey, { ...post, platform, postID, dedupKey });
        }
        if (platform === 'x') {
          const prevX = capturedXTweetsById.get(postID);
          if (!prevX || (Array.isArray(post.media) && post.media.length >= (prevX.media?.length || 0))) {
            capturedXTweetsById.set(postID, { ...post, platform: 'x', postID, tweetID: postID });
          }
        }
      }
      trimCapturedMap(capturedSocialPostsByKey, MAX_CAPTURED_SOCIAL_POSTS);
      trimCapturedMap(capturedXTweetsById, MAX_CAPTURED_SOCIAL_POSTS);
    });
  }

  // MARK: - Config Sync

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
    runtimeState.config = cfg && typeof cfg === 'object' ? cfg : null;
    if (!cfg || typeof cfg !== 'object') {
      runtimeState.configured = false;
      runtimeState.isOwnOrigin = false;
      runtimeState.enableDragDrop = true;
      runtimeState.enableBookmarkFloatingButton = true;
      runtimeState.targetLabel = '收件箱';
      updateFloatingLauncherVisibility();
      return;
    }
    const serverOrigin = normalizeOrigin(cfg.serverUrl);
    runtimeState.configured = Boolean(serverOrigin && String(cfg.apiToken || '').trim());
    runtimeState.isOwnOrigin = Boolean(serverOrigin && serverOrigin === window.location.origin);
    runtimeState.enableDragDrop = cfg.enableDragDrop !== false;
    runtimeState.enableBookmarkFloatingButton = cfg.enableBookmarkFloatingButton !== false;

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
    updateFloatingLauncherVisibility();
  }

  function initConfigSync() {
    if (!ext?.storage?.local) return;
    Promise.resolve(ext.storage.local.get(STORAGE_KEY))
      .then((res) => {
        const stored = res?.[STORAGE_KEY];
        applyConfigSnapshot(stored);
        if (!runtimeState.configured && stored?.connectionMode !== 'web') {
          Promise.resolve(ext.runtime.sendMessage({ type: 'AUTO_PAIR_LOCAL_DESKTOP', force: false })).catch(() => {});
        }
      })
      .catch(() => {});

    ext.storage.onChanged?.addListener((changes, areaName) => {
      if (areaName === 'local' && changes[STORAGE_KEY]) {
        applyConfigSnapshot(changes[STORAGE_KEY].newValue);
      }
    });
  }

  // MARK: - Collection Page Detection

  function isValidXhsNoteId(candidate) {
    return typeof candidate === 'string' && /^[a-zA-Z0-9]{16,40}$/.test(candidate);
  }

  function isXHost(host) {
    return (
      host === 'x.com' ||
      host === 'www.x.com' ||
      host === 'mobile.x.com' ||
      host === 'twitter.com' ||
      host === 'www.twitter.com' ||
      host === 'mobile.twitter.com'
    );
  }

  function isXhsHost(host) {
    return host === 'xiaohongshu.com' || host === 'www.xiaohongshu.com' || host === 'm.xiaohongshu.com';
  }

  function isBlueskyHost(host) {
    return host === 'bsky.app' || host === 'www.bsky.app';
  }

  function isPixivHost(host) {
    return host === 'pixiv.net' || host === 'www.pixiv.net' || host === 'touch.pixiv.net';
  }

  function isThreadsHost(host) {
    return (
      host === 'threads.net' ||
      host === 'www.threads.net' ||
      host === 'threads.com' ||
      host === 'www.threads.com'
    );
  }

  function isInstagramHost(host) {
    return host === 'instagram.com' || host === 'www.instagram.com' || host === 'm.instagram.com';
  }

  const INSTAGRAM_RESERVED_PROFILES = new Set([
    'explore', 'reels', 'reel', 'p', 'tv', 'direct', 'accounts', 'stories', 'about',
    'developer', 'developers', 'legal', 'api', 'static', 'challenge', 'session', 'create',
    'nametag', 'your_activity', 'emails', 'privacy', 'terms', 'web', 'graphql', 'oauth',
    'lite', 'download', 'directory', 'press', 'blog',
  ]);

  const THREADS_RESERVED_PROFILES = new Set([
    't', 'search', 'activity', 'settings', 'login', 'signup', 'saved', 'liked',
    'following', 'for_you', 'privacy', 'terms', 'about', 'download', 'api',
  ]);

  const SOCIAL_PLATFORM_NOUN = {
    x: '推文',
    bluesky: '贴文',
    pixiv: '作品',
    threads: '贴文',
    instagram: '贴文',
    xiaohongshu: '笔记',
  };

  const SOCIAL_PLATFORM_DISPLAY = {
    x: 'X',
    bluesky: 'Bluesky',
    pixiv: 'Pixiv',
    threads: 'Threads',
    instagram: 'Instagram',
    xiaohongshu: '小红书',
  };

  function readCreatorDisplayName(platform, fallbackHandle = '') {
    try {
      if (platform === 'x') return readXProfileDisplayName(fallbackHandle);
      if (platform === 'bluesky') {
        const el = document.querySelector('[data-testid="profileHeaderDisplayName"], main h1');
        const t = (el?.textContent || '').trim();
        if (t && !t.startsWith('@')) return t;
      }
      if (platform === 'pixiv') {
        const h1 = document.querySelector('h1');
        const t = (h1?.textContent || '').trim();
        if (t && !/^(pixiv|イラスト|マンガ|作品)$/i.test(t)) return t;
        const fromTitle = String(document.title || '').replace(/\s*-\s*pixiv.*$/i, '').trim();
        if (fromTitle) return fromTitle;
      }
      if (platform === 'threads') {
        const h1 = document.querySelector('main h1, h1');
        const t = (h1?.textContent || '').trim();
        if (t) return t;
      }
      if (platform === 'instagram') {
        const header = document.querySelector('header');
        if (header) {
          const candidates = Array.from(header.querySelectorAll('span, h1, h2'))
            .map((el) => (el.textContent || '').trim())
            .filter((t) => t && t.length <= 48 && t.toLowerCase() !== fallbackHandle.toLowerCase() && !/^(follow|following|message|posts?|followers?|关注|发消息|帖子|粉丝)/i.test(t));
          if (candidates[0]) return candidates[0];
        }
      }
      if (platform === 'xiaohongshu') {
        const nameEl = document.querySelector('.user-name, .user-nickname, [class*="user-name"]');
        const t = (nameEl?.textContent || '').trim();
        if (t) return t;
      }
    } catch {
      // ignore DOM read errors
    }
    return fallbackHandle || '';
  }

  function buildCreatorRootFolderName(platform, authorHandle, authorName = '', fallback = '') {
    const cleanHandle = String(authorHandle ?? '').trim().replace(/^@/, '');
    const cleanName = sanitizeXFolderSegment(authorName, 36);
    const label = SOCIAL_PLATFORM_DISPLAY[platform] || '社交';
    if (platform === 'pixiv' || platform === 'xiaohongshu') {
      if (cleanName && cleanHandle && /^\d+$/.test(cleanHandle)) {
        return `${cleanName} (${label})`.slice(0, 64);
      }
      if (cleanName) return cleanName.slice(0, 64);
      if (cleanHandle) return `${label} #${cleanHandle}`.slice(0, 64);
      return fallback || `${label} 作品`;
    }
    if (!cleanHandle) return cleanName || fallback || `${label} 作者媒体`;
    if (cleanName && cleanName.toLowerCase() !== cleanHandle.toLowerCase() && cleanName !== `@${cleanHandle}`) {
      return `${cleanName} (@${cleanHandle})`.slice(0, 64);
    }
    return `@${cleanHandle}`;
  }

  function buildPostSubfolderName(post, maxSnippetLength = 28) {
    const postID = String(post?.postID || post?.tweetID || '').trim();
    const idSuffix = postID.length > 6 ? postID.slice(-6) : postID;
    const dateKey =
      String(post?.publishedDateKey || '').trim() ||
      (String(post?.publishedAtText || '').match(/^\d{4}-\d{2}-\d{2}/)?.[0] ?? '');
    const headline = String(post?.title || post?.articleTitle || post?.bodyText || '');
    const snippet = sanitizeXFolderSegment(headline, maxSnippetLength);
    const noun = SOCIAL_PLATFORM_NOUN[post?.platform] || '作品';
    const parts = [];
    if (dateKey) parts.push(dateKey);
    if (snippet) {
      parts.push(idSuffix ? `${snippet} [${idSuffix}]` : snippet);
    } else if (postID) {
      parts.push(`${noun} ${postID}`);
    } else {
      parts.push(`未命名${noun}`);
    }
    return parts.join(' · ');
  }

  function resolvePostSubfolderName(post, organizeMode = 'per_tweet') {
    if (organizeMode === 'flat') return null;
    if (organizeMode === 'multi_only') {
      const count = Array.isArray(post?.media) ? post.media.length : 0;
      return count >= 2 ? buildPostSubfolderName(post) : null;
    }
    return buildPostSubfolderName(post);
  }

  function formatDateString(raw) {
    if (raw === null || raw === undefined || raw === '') {
      return { publishedAtText: null, publishedDateKey: '' };
    }
    let d;
    if (typeof raw === 'number' && Number.isFinite(raw)) {
      d = new Date(raw > 10_000_000_000 ? raw : raw * 1000);
    } else {
      d = new Date(String(raw));
    }
    if (Number.isNaN(d.getTime())) return { publishedAtText: null, publishedDateKey: '' };
    const pad = (n) => String(n).padStart(2, '0');
    const y = d.getFullYear();
    const m = pad(d.getMonth() + 1);
    const day = pad(d.getDate());
    return {
      publishedAtText: `${y}-${m}-${day} ${pad(d.getHours())}:${pad(d.getMinutes())}`,
      publishedDateKey: `${y}-${m}-${day}`,
    };
  }

  function stripHtmlSimple(raw) {
    return String(raw ?? '')
      .replace(/<br\s*\/?>/gi, '\n')
      .replace(/<\/p>/gi, '\n')
      .replace(/<[^>]+>/g, '')
      .replace(/&amp;/g, '&')
      .replace(/&lt;/g, '<')
      .replace(/&gt;/g, '>')
      .replace(/&quot;/g, '"')
      .replace(/&#39;/g, "'")
      .replace(/&nbsp;/g, ' ')
      .replace(/\n{3,}/g, '\n\n')
      .trim();
  }

  function getActiveXTabText() {
    try {
      const activeTabs = document.querySelectorAll('[role="tab"][aria-selected="true"]');
      for (const tab of activeTabs) {
        const text = (tab.textContent || '').trim();
        if (text) return text;
      }
    } catch {
      // ignore DOM errors
    }
    return '';
  }

  const X_RESERVED_PROFILE_SEGMENTS = new Set([
    'home', 'explore', 'notifications', 'messages', 'i', 'search', 'settings', 'compose',
    'login', 'signup', 'logout', 'tos', 'privacy', 'intent', 'hashtag', 'lists', 'communities',
    'jobs', 'grok', 'premium', 'verified-orgs', 'download', 'account', 'about', 'help',
    'status', 'statuses', 'share', 'widgets', 'who_to_follow', 'connect_people',
    'bookmarks', 'likes', 'history',
  ]);
  const X_AUTHOR_TABS = new Set(['', 'media', 'highlights', 'with_replies', 'articles']);

  function readXProfileDisplayName(handle) {
    try {
      const nameBlock = document.querySelector('[data-testid="UserName"]');
      if (nameBlock) {
        const spans = Array.from(nameBlock.querySelectorAll('span'))
          .map((s) => (s.textContent || '').trim())
          .filter(Boolean);
        const nameCandidate = spans.find((t) => !t.startsWith('@') && t !== '·');
        if (nameCandidate) return nameCandidate;
      }
    } catch {
      // ignore DOM errors
    }
    return handle || '';
  }

  function sanitizeXFolderSegment(raw, maxLen = 64) {
    return String(raw ?? '')
      .replace(/https?:\/\/t\.co\/\S+/gi, '')
      .replace(/[\r\n\t]+/g, ' ')
      .replace(/[\\/:*?"<>|\x00-\x1f]/g, ' ')
      .replace(/\s+/g, ' ')
      .replace(/^\.+/, '')
      .trim()
      .slice(0, maxLen)
      .trim();
  }

  function buildAuthorRootFolderName(authorHandle, authorName = '') {
    const cleanHandle = String(authorHandle ?? '').trim().replace(/^@/, '');
    const cleanName = sanitizeXFolderSegment(authorName, 36);
    if (!cleanHandle) return cleanName || 'X 作者媒体';
    if (cleanName && cleanName.toLowerCase() !== cleanHandle.toLowerCase() && cleanName !== `@${cleanHandle}`) {
      return `${cleanName} (@${cleanHandle})`.slice(0, 64);
    }
    return `@${cleanHandle}`;
  }

  function buildTweetSubfolderName(tweet, maxSnippetLength = 28) {
    const tweetID = String(tweet?.tweetID || '').trim();
    const idSuffix = tweetID.length > 6 ? tweetID.slice(-6) : tweetID;
    const dateKey =
      String(tweet?.publishedDateKey || '').trim() ||
      (String(tweet?.publishedAtText || '').match(/^\d{4}-\d{2}-\d{2}/)?.[0] ?? '');
    const snippet = sanitizeXFolderSegment(tweet?.bodyText || '', maxSnippetLength);
    const parts = [];
    if (dateKey) parts.push(dateKey);
    if (snippet) {
      parts.push(idSuffix ? `${snippet} [${idSuffix}]` : snippet);
    } else if (tweetID) {
      parts.push(`推文 ${tweetID}`);
    } else {
      parts.push('未命名推文');
    }
    return parts.join(' · ');
  }

  function resolveTweetSubfolderName(tweet, organizeMode = 'per_tweet') {
    if (organizeMode === 'flat') return null;
    if (organizeMode === 'multi_only') {
      const count = Array.isArray(tweet?.media) ? tweet.media.length : 0;
      return count >= 2 ? buildTweetSubfolderName(tweet) : null;
    }
    return buildTweetSubfolderName(tweet);
  }

  function upgradeTwitterPhotoToOrig(rawUrl) {
    const base = upgradeUrl(rawUrl);
    if (!base) return '';
    try {
      const u = new URL(base);
      if (u.hostname.toLowerCase() === 'pbs.twimg.com' && u.pathname.startsWith('/media/')) {
        const colonIdx = u.pathname.indexOf(':');
        if (colonIdx > 0) u.pathname = u.pathname.slice(0, colonIdx);
        u.searchParams.set('name', 'orig');
        return u.href;
      }
      return u.href;
    } catch {
      return base;
    }
  }

  function detectCurrentCollectionPage(rawUrl = window.location.href) {
    let u;
    try {
      u = new URL(rawUrl);
    } catch {
      return {
        supported: false,
        isCollectionRoute: false,
        platform: null,
        pageKind: null,
        label: '',
        suggestedFolderName: '',
      };
    }
    const host = u.hostname.toLowerCase();
    const parts = u.pathname.split('/').filter(Boolean);
    const p0 = (parts[0] || '').toLowerCase();
    const p1 = (parts[1] || '').toLowerCase();
    const p2 = (parts[2] || '').toLowerCase();

    if (isXHost(host)) {
      const activeTabText = getActiveXTabText();
      const activeTabIsLikes = /^(喜欢|赞过|likes?)$/i.test(activeTabText) || /\b(likes?)\b|喜欢/i.test(activeTabText);
      const activeTabIsBookmarks = /^(书签|bookmarks?)$/i.test(activeTabText) || /\b(bookmarks?)\b|书签/i.test(activeTabText);

      // Classic & folder bookmarks: /i/bookmarks, /i/bookmarks/all, /i/bookmarks/<folderId>
      if (parts.length >= 2 && p0 === 'i' && p1 === 'bookmarks') {
        const folderId = parts[2] && p2 !== 'all' ? parts[2] : null;
        if (!folderId && activeTabIsLikes) {
          return {
            supported: true,
            isCollectionRoute: true,
            platform: 'x',
            pageKind: 'likes',
            label: 'X 历史 · 喜欢',
            suggestedFolderName: 'X 喜欢',
          };
        }
        return {
          supported: true,
          isCollectionRoute: true,
          platform: 'x',
          pageKind: folderId ? 'bookmark_folder' : 'bookmarks',
          label: folderId ? 'X 书签文件夹' : 'X 书签收藏页',
          suggestedFolderName: 'X 书签',
        };
      }

      // X 2026 unified History hub: /i/history, /i/history/bookmarks, /i/history/likes, etc.
      if (parts.length >= 2 && p0 === 'i' && p1 === 'history') {
        if (p2 === 'likes' || (!p2 && activeTabIsLikes)) {
          return {
            supported: true,
            isCollectionRoute: true,
            platform: 'x',
            pageKind: 'likes',
            label: 'X 历史 · 喜欢',
            suggestedFolderName: 'X 喜欢',
          };
        }
        if (p2 === 'bookmarks' || activeTabIsBookmarks) {
          return {
            supported: true,
            isCollectionRoute: true,
            platform: 'x',
            pageKind: 'bookmarks',
            label: 'X 书签收藏页',
            suggestedFolderName: 'X 书签',
          };
        }
        return {
          supported: true,
          isCollectionRoute: true,
          platform: 'x',
          pageKind: 'history',
          label: 'X 历史 · 书签',
          suggestedFolderName: 'X 书签',
        };
      }

      // Profile-scoped bookmarks / likes / history: /<handle>/bookmarks, /<handle>/likes, /<handle>/history
      if (parts.length >= 2 && p1 === 'bookmarks') {
        return {
          supported: true,
          isCollectionRoute: true,
          platform: 'x',
          pageKind: 'bookmarks',
          label: 'X 书签收藏页',
          suggestedFolderName: 'X 书签',
        };
      }
      if (parts.length >= 2 && p1 === 'likes') {
        return {
          supported: true,
          isCollectionRoute: true,
          platform: 'x',
          pageKind: 'likes',
          label: 'X 喜欢列表',
          suggestedFolderName: 'X 喜欢',
        };
      }
      if (parts.length >= 2 && p1 === 'history') {
        return {
          supported: true,
          isCollectionRoute: true,
          platform: 'x',
          pageKind: activeTabIsLikes ? 'likes' : 'history',
          label: activeTabIsLikes ? 'X 历史 · 喜欢' : 'X 历史 · 书签',
          suggestedFolderName: activeTabIsLikes ? 'X 喜欢' : 'X 书签',
        };
      }
      if (parts.length >= 3 && p0 === 'i' && p1 === 'lists') {
        return {
          supported: true,
          isCollectionRoute: true,
          platform: 'x',
          pageKind: 'list',
          label: 'X 列表',
          suggestedFolderName: 'X 书签',
        };
      }

      // Author profile / media pages: /<handle>, /<handle>/media, /<handle>/highlights, /<handle>/with_replies
      if (parts.length >= 1 && parts.length <= 2) {
        const candidateHandle = parts[0].replace(/^@/, '');
        const subTab = (parts[1] || '').toLowerCase();
        if (
          /^[a-zA-Z0-9_]{1,32}$/.test(candidateHandle) &&
          !X_RESERVED_PROFILE_SEGMENTS.has(candidateHandle.toLowerCase()) &&
          X_AUTHOR_TABS.has(subTab)
        ) {
          const authorName = readXProfileDisplayName(candidateHandle);
          return {
            supported: true,
            isCollectionRoute: true,
            platform: 'x',
            pageKind: 'author_media',
            authorHandle: candidateHandle,
            authorName,
            isMediaTab: subTab === 'media',
            label: `X 作者媒体 · @${candidateHandle}`,
            suggestedFolderName: buildAuthorRootFolderName(candidateHandle, authorName),
          };
        }
      }

      // DOM-aware fallback on X (handles any future X route renames such as History / Bookmarks tabs)
      const isSingleTweetPage =
        (parts.length >= 3 && (p1 === 'status' || p1 === 'statuses') && /^\d{1,24}$/.test(parts[2])) ||
        (parts.length >= 4 && p0 === 'i' && p1 === 'web' && p2 === 'status');
      if (!isSingleTweetPage) {
        const title = String(document.title || '');
        const heading = String(document.querySelector('main h2[role="heading"]')?.textContent || '');
        const looksLikeCollectionDom =
          /^(历史|书签|喜欢|Bookmarks?|History|Likes?)\s*[/|·-]/i.test(title) ||
          /^(历史|书签|Bookmarks?|History)$/i.test(heading.trim()) ||
          activeTabIsBookmarks ||
          activeTabIsLikes;
        if (looksLikeCollectionDom) {
          return {
            supported: true,
            isCollectionRoute: true,
            platform: 'x',
            pageKind: activeTabIsLikes ? 'likes' : 'bookmarks',
            label: activeTabIsLikes ? 'X 历史 · 喜欢' : 'X 书签收藏页',
            suggestedFolderName: activeTabIsLikes ? 'X 喜欢' : 'X 书签',
          };
        }
        if (document.querySelector('article[data-testid="tweet"]')) {
          return {
            supported: true,
            isCollectionRoute: false,
            platform: 'x',
            pageKind: 'timeline',
            label: '当前 X 页面推文列表',
            suggestedFolderName: 'X 书签',
          };
        }
      }
    }

    if (isXhsHost(host)) {
      const isSingleXhsNote =
        (parts.length >= 2 && p0 === 'explore' && isValidXhsNoteId(parts[1])) ||
        (parts.length >= 3 && p0 === 'discovery' && p1 === 'item' && isValidXhsNoteId(parts[2])) ||
        (parts.length >= 4 && p0 === 'user' && p1 === 'profile' && isValidXhsNoteId(parts[3]));

      if (parts.length >= 3 && p0 === 'user' && p1 === 'profile' && !isSingleXhsNote) {
        const tab = (u.searchParams.get('tab') || parts[3] || '').toLowerCase();
        if (tab === 'collect' || tab === 'fav' || tab === 'favorite' || tab === 'favorites') {
          return {
            supported: true,
            isCollectionRoute: true,
            platform: 'xiaohongshu',
            pageKind: 'collect',
            label: '小红书收藏页',
            suggestedFolderName: '小红书收藏',
          };
        }
        if (tab === 'like' || tab === 'likes') {
          return {
            supported: true,
            isCollectionRoute: true,
            platform: 'xiaohongshu',
            pageKind: 'likes',
            label: '小红书点赞页',
            suggestedFolderName: '小红书点赞',
          };
        }
        const xhsAuthor = readCreatorDisplayName('xiaohongshu', '');
        const activeXhsTab = (
          document.querySelector('.reds-tab-item.active, [class*="tab-item"].active, [role="tab"][aria-selected="true"]')?.textContent || ''
        ).trim();
        const isCollectActive = /^收藏/.test(activeXhsTab);
        const isLikesActive = /^赞过|^点赞/.test(activeXhsTab);
        if (isCollectActive) {
          return {
            supported: true,
            isCollectionRoute: true,
            platform: 'xiaohongshu',
            pageKind: 'collect',
            authorName: xhsAuthor,
            label: '小红书收藏页',
            suggestedFolderName: '小红书收藏',
          };
        }
        if (isLikesActive) {
          return {
            supported: true,
            isCollectionRoute: true,
            platform: 'xiaohongshu',
            pageKind: 'likes',
            authorName: xhsAuthor,
            label: '小红书点赞页',
            suggestedFolderName: '小红书点赞',
          };
        }
        return {
          supported: true,
          isCollectionRoute: true,
          platform: 'xiaohongshu',
          pageKind: 'profile',
          authorHandle: parts[2] || '',
          authorName: xhsAuthor,
          label: xhsAuthor ? `小红书作者 · ${xhsAuthor}` : '小红书个人主页',
          suggestedFolderName: xhsAuthor ? buildCreatorRootFolderName('xiaohongshu', parts[2] || '', xhsAuthor) : '小红书收藏',
        };
      }
      if (parts.length >= 1 && (p0 === 'board' || p0 === 'collection' || p0 === 'collections' || p0 === 'collect')) {
        return {
          supported: true,
          isCollectionRoute: true,
          platform: 'xiaohongshu',
          pageKind: 'board',
          label: '小红书收藏专辑',
          suggestedFolderName: '小红书收藏',
        };
      }
      if (!isSingleXhsNote && document.querySelector('section.note-item, .note-item')) {
        return {
          supported: true,
          isCollectionRoute: false,
          platform: 'xiaohongshu',
          pageKind: 'feed',
          label: '当前小红书笔记列表',
          suggestedFolderName: '小红书收藏',
        };
      }
    }

    // Bluesky: /profile/<handle>[/(media|videos|posts|likes)]
    if (isBlueskyHost(host)) {
      if (parts.length >= 2 && p0 === 'profile' && parts.length <= 3) {
        const handle = decodeURIComponent(parts[1]).replace(/^@/, '').trim();
        const sub = (parts[2] || '').toLowerCase();
        if (handle && ['', 'media', 'videos', 'posts', 'likes'].includes(sub)) {
          const isLikes = sub === 'likes';
          const authorName = readCreatorDisplayName('bluesky', handle);
          return {
            supported: true,
            isCollectionRoute: true,
            platform: 'bluesky',
            pageKind: isLikes ? 'likes' : 'author_media',
            authorHandle: handle,
            authorName,
            isMediaTab: sub === 'media' || sub === 'videos',
            label: isLikes ? `Bluesky 喜欢 · @${handle}` : `Bluesky 作者媒体 · @${handle}`,
            suggestedFolderName: isLikes
              ? 'Bluesky 喜欢'
              : buildCreatorRootFolderName('bluesky', handle, authorName),
          };
        }
      }
    }

    // Pixiv: /[locale/]users/<uid>[/(artworks|illustrations|manga|bookmarks/artworks[/<tag>])]
    if (isPixivHost(host)) {
      let idx = 0;
      if (/^[a-z]{2}(?:-[a-z]{2})?$/i.test(parts[0] || '') && (parts[1] || '').toLowerCase() === 'users') {
        idx = 1;
      }
      if ((parts[idx] || '').toLowerCase() === 'users' && /^\d{1,16}$/.test(parts[idx + 1] || '')) {
        const userId = parts[idx + 1];
        const sub1 = (parts[idx + 2] || '').toLowerCase();
        const sub2 = (parts[idx + 3] || '').toLowerCase();
        if (sub1 === 'bookmarks' && (!sub2 || sub2 === 'artworks')) {
          const bookmarkTag = parts[idx + 4] ? decodeURIComponent(parts[idx + 4]) : '';
          const rest = (u.searchParams.get('rest') || 'show').toLowerCase() === 'hide' ? 'hide' : 'show';
          return {
            supported: true,
            isCollectionRoute: true,
            platform: 'pixiv',
            pageKind: 'bookmarks',
            authorHandle: userId,
            authorName: readCreatorDisplayName('pixiv', userId),
            workFilter: 'bookmarks',
            bookmarkTag,
            rest,
            label: bookmarkTag ? `Pixiv 收藏 · #${bookmarkTag}` : 'Pixiv 收藏作品',
            suggestedFolderName: bookmarkTag ? `Pixiv 收藏 · ${bookmarkTag}` : 'Pixiv 收藏',
          };
        }
        if (!sub1 || ['artworks', 'illustrations', 'manga'].includes(sub1)) {
          const workFilter = sub1 === 'illustrations' ? 'illusts' : sub1 === 'manga' ? 'manga' : 'all';
          const authorName = readCreatorDisplayName('pixiv', userId);
          const filterLabel = workFilter === 'illusts' ? '插画' : workFilter === 'manga' ? '漫画' : '全部作品';
          return {
            supported: true,
            isCollectionRoute: true,
            platform: 'pixiv',
            pageKind: 'author_media',
            authorHandle: userId,
            authorName,
            workFilter,
            label: authorName && authorName !== userId ? `Pixiv · ${authorName}（${filterLabel}）` : `Pixiv 画师${filterLabel}`,
            suggestedFolderName: buildCreatorRootFolderName('pixiv', userId, authorName),
          };
        }
      }
    }

    // Threads: /@<handle>[/(media|replies|reposts)] or /saved, /liked
    if (isThreadsHost(host)) {
      if ((p0 === 'saved' || p0 === 'liked') && parts.length === 1) {
        return {
          supported: true,
          isCollectionRoute: true,
          platform: 'threads',
          pageKind: p0 === 'liked' ? 'likes' : 'bookmarks',
          authorHandle: '',
          authorName: '',
          label: p0 === 'liked' ? 'Threads 喜欢列表' : 'Threads 已保存列表',
          suggestedFolderName: p0 === 'liked' ? 'Threads 喜欢' : 'Threads 收藏',
        };
      }
      if (parts.length >= 1 && parts.length <= 2 && parts[0].startsWith('@')) {
        const handle = parts[0].slice(1).trim();
        const sub = (parts[1] || '').toLowerCase();
        if (
          handle &&
          !THREADS_RESERVED_PROFILES.has(handle.toLowerCase()) &&
          /^[a-zA-Z0-9._]{1,40}$/.test(handle) &&
          (!sub || ['media', 'replies', 'reposts'].includes(sub))
        ) {
          const authorName = readCreatorDisplayName('threads', handle);
          return {
            supported: true,
            isCollectionRoute: true,
            platform: 'threads',
            pageKind: 'author_media',
            authorHandle: handle,
            authorName,
            isMediaTab: sub === 'media',
            label: `Threads 作者媒体 · @${handle}`,
            suggestedFolderName: buildCreatorRootFolderName('threads', handle, authorName),
          };
        }
      }
    }

    // Instagram: /<username>[/(reels|tagged|saved)]
    if (isInstagramHost(host)) {
      if (parts.length >= 1) {
        const handle = parts[0].replace(/^@/, '').trim();
        const sub = (parts[1] || '').toLowerCase();
        if (
          handle &&
          !INSTAGRAM_RESERVED_PROFILES.has(handle.toLowerCase()) &&
          /^[a-zA-Z0-9._]{1,40}$/.test(handle) &&
          !['p', 'reel', 'tv', 'followers', 'following'].includes(sub)
        ) {
          if (sub === 'saved') {
            return {
              supported: true,
              isCollectionRoute: true,
              platform: 'instagram',
              pageKind: 'bookmarks',
              authorHandle: handle,
              authorName: handle,
              label: `Instagram 收藏 · @${handle}`,
              suggestedFolderName: 'Instagram 收藏',
            };
          }
          if (parts.length <= 2 && (!sub || ['reels', 'tagged', 'channel'].includes(sub))) {
            const authorName = readCreatorDisplayName('instagram', handle);
            return {
              supported: true,
              isCollectionRoute: true,
              platform: 'instagram',
              pageKind: 'author_media',
              authorHandle: handle,
              authorName,
              label: `Instagram 作者媒体 · @${handle}`,
              suggestedFolderName: buildCreatorRootFolderName('instagram', handle, authorName),
            };
          }
        }
      }
    }

    return {
      supported: false,
      isCollectionRoute: false,
      platform: null,
      pageKind: null,
      label: '',
      suggestedFolderName: '',
    };
  }

  // MARK: - Isolated Overlay UI (Drop Pill + Status Toast + Floating Import Launcher + Live Progress HUD)

  function ensureShadowUI() {
    if (shadowRoot) return shadowRoot;

    shadowHost = document.createElement('div');
    shadowHost.id = 'charkle-clipper-host';
    shadowHost.style.cssText = 'all: initial; position: fixed; inset: 0; pointer-events: none; z-index: 2147483646;';
    shadowRoot = shadowHost.attachShadow({ mode: 'open' });

    const lightIconUrl = ext.runtime.getURL('icons/charkle-light.svg');
    const darkIconUrl = ext.runtime.getURL('icons/charkle-dark.svg');

    const style = document.createElement('style');
    style.textContent = `
      :host {
        --bg-surface: rgba(255, 255, 255, 0.88);
        --bg-surface-active: rgba(255, 255, 255, 0.96);
        --bg-solid: #FFFFFF;
        --bg-subtle: rgba(24, 25, 28, 0.06);
        --text-primary: #18191C;
        --text-secondary: #5C6069;
        --border-hairline: rgba(0, 0, 0, 0.09);
        --accent: #2A60E0;
        --accent-hover: #2151C7;
        --accent-soft: rgba(42, 96, 224, 0.12);
        --xhs-red: #FF2442;
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
          --bg-surface: rgba(24, 26, 32, 0.88);
          --bg-surface-active: rgba(32, 35, 43, 0.96);
          --bg-solid: #1E2025;
          --bg-subtle: rgba(255, 255, 255, 0.08);
          --text-primary: #F2F3F5;
          --text-secondary: #A1A6B0;
          --border-hairline: rgba(255, 255, 255, 0.11);
          --accent: #5B8DEF;
          --accent-hover: #74A0F7;
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
        .ck-pill, .ck-icon-tile, .ck-toast, .ck-toast-icon, .ck-launch, .ck-hud, .ck-hud-btn {
          corner-shape: superellipse(1.25);
        }
      }

      @media (prefers-reduced-transparency: reduce) {
        .ck-pill, .ck-toast, .ck-launch, .ck-hud {
          background: var(--bg-solid);
          backdrop-filter: none;
          -webkit-backdrop-filter: none;
        }
      }

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

      /* Floating One-Click Bookmark Import Trigger (X Bookmarks & Xiaohongshu Collect only) */
      .ck-launch {
        position: fixed;
        right: 20px;
        bottom: 22px;
        display: flex;
        align-items: center;
        gap: 6px;
        padding: 5px 6px 5px 10px;
        border-radius: 14px;
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
          opacity 180ms var(--ease-out-strong),
          transform 200ms var(--ease-out-strong);
        box-sizing: border-box;
      }

      .ck-launch.is-visible {
        pointer-events: auto;
        opacity: 1;
        transform: translateY(0) scale(1);
      }

      .ck-launch-btn {
        display: inline-flex;
        align-items: center;
        gap: 7px;
        height: 30px;
        padding: 0 11px 0 8px;
        border: none;
        border-radius: 9px;
        background: var(--accent);
        color: #FFFFFF;
        font-family: inherit;
        font-size: 12.5px;
        font-weight: 600;
        cursor: pointer;
        transition:
          background-color 140ms var(--ease-out),
          transform 120ms var(--ease-out);
      }

      .ck-launch-btn:hover {
        background: var(--accent-hover);
      }

      .ck-launch-btn:active {
        transform: scale(0.97);
      }

      .ck-launch-close {
        width: 24px;
        height: 24px;
        border: none;
        border-radius: 7px;
        background: transparent;
        color: var(--text-secondary);
        font-size: 15px;
        line-height: 1;
        cursor: pointer;
        display: grid;
        place-items: center;
        transition: background-color 140ms var(--ease-out), color 140ms var(--ease-out);
      }

      .ck-launch-close:hover {
        background: var(--bg-subtle);
        color: var(--text-primary);
      }

      /* Live Batch Progress HUD */
      .ck-hud {
        position: fixed;
        right: 20px;
        bottom: 20px;
        width: 320px;
        padding: 12px 14px;
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
          opacity 180ms var(--ease-out-strong),
          transform 220ms var(--ease-out-strong);
        box-sizing: border-box;
        display: flex;
        flex-direction: column;
        gap: 8px;
      }

      .ck-hud.is-visible {
        pointer-events: auto;
        opacity: 1;
        transform: translateY(0) scale(1);
      }

      .ck-hud-head {
        display: flex;
        align-items: center;
        justify-content: space-between;
        gap: 8px;
      }

      .ck-hud-title-row {
        display: flex;
        align-items: center;
        gap: 7px;
        min-width: 0;
      }

      .ck-hud-title {
        font-size: 13px;
        font-weight: 650;
        white-space: nowrap;
        overflow: hidden;
        text-overflow: ellipsis;
      }

      .ck-hud-phase {
        font-size: 11.5px;
        color: var(--text-secondary);
        line-height: 1.35;
      }

      .ck-hud-bar {
        width: 100%;
        height: 5px;
        border-radius: 999px;
        background: var(--bg-subtle);
        overflow: hidden;
      }

      .ck-hud-bar-fill {
        height: 100%;
        width: 14%;
        border-radius: 999px;
        background: var(--accent);
        transition: width 220ms var(--ease-out);
      }

      .ck-hud[data-status="done"] .ck-hud-bar-fill {
        background: var(--success);
      }

      .ck-hud[data-status="error"] .ck-hud-bar-fill {
        background: var(--danger);
      }

      .ck-hud-stats {
        font-size: 11.5px;
        font-weight: 550;
        font-variant-numeric: tabular-nums;
        color: var(--text-primary);
      }

      .ck-hud-last {
        font-size: 11px;
        color: var(--text-secondary);
        white-space: nowrap;
        overflow: hidden;
        text-overflow: ellipsis;
      }

      .ck-hud-actions {
        display: flex;
        align-items: center;
        gap: 6px;
        padding-top: 2px;
      }

      .ck-hud-btn {
        flex: 1;
        height: 28px;
        padding: 0 10px;
        border-radius: 8px;
        border: 1px solid var(--border-hairline);
        background: var(--bg-solid);
        color: var(--text-primary);
        font-family: inherit;
        font-size: 12px;
        font-weight: 550;
        cursor: pointer;
        transition: background-color 140ms var(--ease-out), transform 120ms var(--ease-out);
      }

      .ck-hud-btn:hover {
        background: var(--bg-subtle);
      }

      .ck-hud-btn:active {
        transform: scale(0.97);
      }

      .ck-hud-btn.is-danger {
        color: var(--danger);
      }

      /* In-Page Status Toast */
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
        .ck-toast.is-visible,
        .ck-launch,
        .ck-launch.is-visible,
        .ck-hud,
        .ck-hud.is-visible {
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
      if (e.dataTransfer) e.dataTransfer.dropEffect = 'copy';
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

    // Floating One-Click Bookmark Import Pill
    launchPillEl = document.createElement('div');
    launchPillEl.className = 'ck-launch';
    launchPillEl.setAttribute('aria-hidden', 'true');
    launchPillEl.innerHTML = `
      <img class="ck-brand-img ck-brand-light" src="${lightIconUrl}" alt="" />
      <img class="ck-brand-img ck-brand-dark" src="${darkIconUrl}" alt="" />
      <button type="button" class="ck-launch-btn"><span class="ck-launch-label">一键批量导入</span></button>
      <button type="button" class="ck-launch-close" title="暂不显示" aria-label="关闭">×</button>
    `;
    launchPillBtnEl = launchPillEl.querySelector('.ck-launch-btn');
    launchPillLabelEl = launchPillEl.querySelector('.ck-launch-label');
    launchPillBtnEl.addEventListener('click', () => {
      const cfg = runtimeState.config || {};
      void startBookmarkImport({
        skipDuplicates: cfg.bookmarkSkipDuplicates !== false,
        stopOnKnownStreak: cfg.bookmarkStopOnKnownStreak !== false,
        enrichXhsDetails: cfg.bookmarkEnrichXhsDetails !== false,
        maxCount: Number(cfg.bookmarkMaxCount || 0),
        organizeMode: cfg.authorMediaOrganizeMode || 'per_tweet',
        includeVideos: cfg.authorMediaIncludeVideos !== false,
        skipRetweets: cfg.authorMediaSkipRetweets !== false,
        xhsCollectMode: cfg.xhsProfileCollectMode || 'media',
        targetLabel: runtimeState.targetLabel,
      });
    });
    launchPillEl.querySelector('.ck-launch-close').addEventListener('click', () => {
      launchPillDismissedForHref = window.location.href;
      hideFloatingLauncher();
    });

    // Live Batch Progress HUD
    hudEl = document.createElement('div');
    hudEl.className = 'ck-hud';
    hudEl.dataset.status = 'idle';
    hudEl.setAttribute('aria-hidden', 'true');
    hudEl.innerHTML = `
      <div class="ck-hud-head">
        <div class="ck-hud-title-row">
          <img class="ck-brand-img ck-brand-light" src="${lightIconUrl}" alt="" />
          <img class="ck-brand-img ck-brand-dark" src="${darkIconUrl}" alt="" />
          <span class="ck-hud-title">Charkle 批量导入</span>
        </div>
        <button type="button" class="ck-launch-close ck-hud-close" title="收起面板" aria-label="收起">×</button>
      </div>
      <div class="ck-hud-phase">准备中…</div>
      <div class="ck-hud-bar"><div class="ck-hud-bar-fill"></div></div>
      <div class="ck-hud-stats">已发现 0 · 已导入 0 · 跳过 0</div>
      <div class="ck-hud-last"></div>
      <div class="ck-hud-actions">
        <button type="button" class="ck-hud-btn ck-hud-pause">暂停</button>
        <button type="button" class="ck-hud-btn is-danger ck-hud-stop">停止并保存</button>
      </div>
    `;
    hudTitleEl = hudEl.querySelector('.ck-hud-title');
    hudPhaseEl = hudEl.querySelector('.ck-hud-phase');
    hudBarFillEl = hudEl.querySelector('.ck-hud-bar-fill');
    hudStatsEl = hudEl.querySelector('.ck-hud-stats');
    hudLastItemEl = hudEl.querySelector('.ck-hud-last');
    hudPauseBtnEl = hudEl.querySelector('.ck-hud-pause');
    hudStopBtnEl = hudEl.querySelector('.ck-hud-stop');
    hudCloseBtnEl = hudEl.querySelector('.ck-hud-close');

    hudPauseBtnEl.addEventListener('click', () => {
      if (batchJob.status === 'running') {
        batchJob.pauseRequested = true;
        batchJob.status = 'paused';
        batchJob.phase = '已暂停，点击「继续」恢复自动扫描';
        syncHudAndPush();
      } else if (batchJob.status === 'paused') {
        batchJob.pauseRequested = false;
        batchJob.status = 'running';
        batchJob.phase = '正在继续扫描并导入…';
        syncHudAndPush();
      }
    });

    hudStopBtnEl.addEventListener('click', () => {
      if (batchJob.status === 'running' || batchJob.status === 'paused') {
        batchJob.stopRequested = true;
        batchJob.pauseRequested = false;
        batchJob.phase = '正在保存已扫描条目并停止…';
        syncHudAndPush();
      } else {
        hideHud();
      }
    });

    hudCloseBtnEl.addEventListener('click', () => {
      if (batchJob.status !== 'running' && batchJob.status !== 'paused') {
        hideHud();
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

    shadowRoot.append(style, dropPillEl, launchPillEl, hudEl, toastEl);
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
    hideFloatingLauncher();
    dropPillEl.classList.remove('is-over');
    updateDropPillCopy(false);
    dropPillEl.setAttribute('aria-hidden', 'false');
    requestAnimationFrame(() => {
      if (isDockVisible && dropPillEl) dropPillEl.classList.add('is-visible');
    });
  }

  function hideDropDock() {
    isDockVisible = false;
    activeDragImage = null;
    if (dropPillEl) {
      dropPillEl.classList.remove('is-visible', 'is-over');
      dropPillEl.setAttribute('aria-hidden', 'true');
    }
    updateFloatingLauncherVisibility();
  }

  function hideFloatingLauncher() {
    if (launchPillEl) {
      launchPillEl.classList.remove('is-visible');
      launchPillEl.setAttribute('aria-hidden', 'true');
    }
  }

  function updateFloatingLauncherVisibility() {
    const info = detectCurrentCollectionPage();
    const jobActive = batchJob.status === 'running' || batchJob.status === 'paused';
    const shouldShow =
      info.supported &&
      info.isCollectionRoute !== false &&
      runtimeState.configured &&
      !runtimeState.isOwnOrigin &&
      runtimeState.enableBookmarkFloatingButton &&
      !jobActive &&
      !isDockVisible &&
      launchPillDismissedForHref !== window.location.href;

    if (!shouldShow) {
      hideFloatingLauncher();
      return;
    }

    ensureShadowUI();
    launchPillLabelEl.textContent = (() => {
      if (info.platform === 'pixiv') {
        return info.pageKind === 'bookmarks' ? '采集 Pixiv 收藏作品' : '采集 Pixiv 画师作品';
      }
      if (info.platform === 'bluesky') {
        return info.pageKind === 'likes'
          ? '采集 Bluesky 喜欢'
          : `采集 @${info.authorHandle || '作者'} 全部媒体`;
      }
      if (info.platform === 'threads') {
        return info.pageKind === 'author_media'
          ? `采集 @${info.authorHandle || '作者'} 全部媒体`
          : '采集 Threads 收藏';
      }
      if (info.platform === 'instagram') {
        return info.pageKind === 'author_media'
          ? `采集 @${info.authorHandle || '作者'} 全部媒体`
          : '采集 Instagram 收藏';
      }
      if (info.platform === 'xiaohongshu') {
        if (info.pageKind === 'likes') return '一键导入小红书点赞';
        if (info.pageKind === 'profile' && runtimeState.config?.xhsProfileCollectMode === 'media') {
          return '采集小红书作者作品';
        }
        return '一键导入小红书收藏';
      }
      return info.pageKind === 'author_media'
        ? `采集 @${info.authorHandle || '作者'} 全部媒体`
        : info.pageKind === 'likes'
          ? '一键导入 X 喜欢'
          : '一键导入 X 书签';
    })();
    launchPillEl.setAttribute('aria-hidden', 'false');
    requestAnimationFrame(() => {
      if (launchPillEl) launchPillEl.classList.add('is-visible');
    });
  }

  function showHud() {
    ensureShadowUI();
    hideFloatingLauncher();
    hideToastImmediate();
    hudEl.setAttribute('aria-hidden', 'false');
    requestAnimationFrame(() => {
      if (hudEl) hudEl.classList.add('is-visible');
    });
  }

  function hideHud() {
    if (hudEl) {
      hudEl.classList.remove('is-visible');
      hudEl.setAttribute('aria-hidden', 'true');
    }
    updateFloatingLauncherVisibility();
  }

  function snapshotBatchJob() {
    return {
      status: batchJob.status,
      mode: batchJob.mode,
      platform: batchJob.platform,
      platformLabel: batchJob.platformLabel,
      authorHandle: batchJob.authorHandle,
      phase: batchJob.phase,
      discovered: batchJob.discovered,
      queued: batchJob.queued,
      imported: batchJob.imported,
      mediaImported: batchJob.mediaImported,
      skipped: batchJob.skipped,
      failed: batchJob.failed,
      lastItemTitle: batchJob.lastItemTitle,
      errorMessage: batchJob.errorMessage,
      targetLabel: batchJob.targetLabel,
    };
  }

  function syncHudAndPush() {
    if (hudEl) {
      hudEl.dataset.status = batchJob.status;
      const platformName = SOCIAL_PLATFORM_DISPLAY[batchJob.platform] || '社交';
      const postNoun = SOCIAL_PLATFORM_NOUN[batchJob.platform] || '作品';
      hudTitleEl.textContent =
        batchJob.mode === 'author_media'
          ? `${platformName} 媒体采集 → ${batchJob.targetLabel}`
          : batchJob.platform === 'xiaohongshu'
            ? `导入小红书收藏 → ${batchJob.targetLabel}`
            : `导入 ${platformName} 收藏 → ${batchJob.targetLabel}`;
      hudPhaseEl.textContent = batchJob.errorMessage || batchJob.phase || '准备中…';

      const processed = batchJob.imported + batchJob.skipped + batchJob.failed;
      const pct =
        batchJob.status === 'done'
          ? 100
          : batchJob.discovered > 0
            ? Math.max(10, Math.min(96, Math.round((processed / Math.max(batchJob.discovered, 1)) * 100)))
            : 12;
      hudBarFillEl.style.width = `${pct}%`;

      const failSuffix = batchJob.failed > 0 ? ` · 失败 ${batchJob.failed}` : '';
      hudStatsEl.textContent =
        batchJob.mode === 'author_media'
          ? `${postNoun} ${batchJob.discovered} · 文件入库 ${batchJob.mediaImported} · 跳过 ${batchJob.skipped}${failSuffix}`
          : `发现 ${batchJob.discovered} · 导入 ${batchJob.imported} · 跳过 ${batchJob.skipped}${failSuffix}`;
      hudLastItemEl.textContent = batchJob.lastItemTitle ? `最新：${batchJob.lastItemTitle}` : '';

      const active = batchJob.status === 'running' || batchJob.status === 'paused';
      hudPauseBtnEl.hidden = !active;
      hudPauseBtnEl.textContent = batchJob.status === 'paused' ? '继续' : '暂停';
      hudStopBtnEl.textContent = active ? '停止并保存' : '关闭';
      hudStopBtnEl.classList.toggle('is-danger', active);
      hudCloseBtnEl.hidden = active;
    }

    Promise.resolve(
      ext.runtime.sendMessage({
        type: 'BOOKMARK_JOB_STATUS_PUSH',
        job: snapshotBatchJob(),
      }),
    ).catch(() => {});
  }

  function toastIconSvg(variant) {
    if (variant === 'progress') return '<span class="ck-spinner" aria-hidden="true"></span>';
    if (variant === 'error') {
      return '<svg width="15" height="15" viewBox="0 0 16 16" fill="none" aria-hidden="true"><path d="M8 4.5v4.2M8 11.4v.4" stroke="currentColor" stroke-width="1.8" stroke-linecap="round"/><circle cx="8" cy="8" r="6.25" stroke="currentColor" stroke-width="1.4"/></svg>';
    }
    return '<svg width="15" height="15" viewBox="0 0 16 16" fill="none" aria-hidden="true"><path d="M3.5 8.4L6.6 11.4L12.6 4.8" stroke="currentColor" stroke-width="1.8" stroke-linecap="round" stroke-linejoin="round"/></svg>';
  }

  function scheduleToastHide(delayMs) {
    if (toastHideTimer) clearTimeout(toastHideTimer);
    toastHideTimer = setTimeout(() => {
      toastHideTimer = null;
      if (!isToastHovered && toastEl) toastEl.classList.remove('is-visible');
    }, delayMs);
  }

  function hideToastImmediate() {
    if (toastHideTimer) {
      clearTimeout(toastHideTimer);
      toastHideTimer = null;
    }
    if (toastEl) toastEl.classList.remove('is-visible');
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

  // MARK: - Xiaohongshu In-Browser Parser Helpers (Self-Contained for Content Script)

  function upgradeHttps(raw) {
    const trimmed = String(raw || '').trim();
    if (!trimmed) return '';
    let candidate = trimmed;
    if (candidate.startsWith('//')) candidate = `https:${candidate}`;
    else if (/^http:\/\//i.test(candidate)) candidate = `https://${candidate.slice(7)}`;
    try {
      const u = new URL(candidate, window.location.href);
      if (u.protocol !== 'http:' && u.protocol !== 'https:') return '';
      return u.href;
    } catch {
      return '';
    }
  }

  function normalizeXhsNoteHref(rawHref) {
    if (!rawHref) return null;
    let u;
    try {
      u = new URL(String(rawHref).trim(), window.location.origin);
    } catch {
      return null;
    }
    if (!u.hostname.toLowerCase().endsWith('xiaohongshu.com')) return null;
    const parts = u.pathname.split('/').filter(Boolean);
    let noteId = null;
    if (parts.length >= 2 && parts[0].toLowerCase() === 'explore' && isValidXhsNoteId(parts[1])) {
      noteId = parts[1];
    } else if (
      parts.length >= 3 &&
      parts[0].toLowerCase() === 'discovery' &&
      parts[1].toLowerCase() === 'item' &&
      isValidXhsNoteId(parts[2])
    ) {
      noteId = parts[2];
    } else if (
      parts.length >= 4 &&
      parts[0].toLowerCase() === 'user' &&
      parts[1].toLowerCase() === 'profile' &&
      isValidXhsNoteId(parts[3])
    ) {
      noteId = parts[3];
    }
    if (!noteId) return null;

    const xsecToken = (u.searchParams.get('xsec_token') || '').trim();
    const xsecSource = (u.searchParams.get('xsec_source') || '').trim();
    const canonical = new URL(`https://www.xiaohongshu.com/explore/${noteId}`);
    if (xsecToken) canonical.searchParams.set('xsec_token', xsecToken);
    if (xsecSource) canonical.searchParams.set('xsec_source', xsecSource);

    return {
      noteId,
      xsecToken: xsecToken || null,
      url: canonical.href,
      dedupKey: `xhs:${noteId.toLowerCase()}`,
    };
  }

  function sanitizeJSUndefined(src) {
    let out = '';
    let inString = false;
    let escaped = false;
    for (let i = 0; i < src.length; i++) {
      const ch = src[i];
      if (inString) {
        out += ch;
        if (escaped) escaped = false;
        else if (ch === '\\') escaped = true;
        else if (ch === '"') inString = false;
        continue;
      }
      if (ch === '"') {
        inString = true;
        out += ch;
        continue;
      }
      if (ch === 'u' && src.startsWith('undefined', i)) {
        const prev = i > 0 ? src[i - 1] : '';
        const next = i + 9 < src.length ? src[i + 9] : '';
        if (!/[a-zA-Z0-9_$]/.test(prev) && !/[a-zA-Z0-9_$]/.test(next)) {
          out += 'null';
          i += 8;
          continue;
        }
      }
      out += ch;
    }
    return out;
  }

  function extractInitialStateFromHtml(html) {
    const markers = ['window.__INITIAL_STATE__=', 'window.__INITIAL_STATE__ ='];
    for (const marker of markers) {
      const idx = html.indexOf(marker);
      if (idx < 0) continue;
      let start = idx + marker.length;
      while (start < html.length && /\s/.test(html[start])) start++;
      if (html[start] !== '{') continue;
      let depth = 0;
      let inString = false;
      let escaped = false;
      for (let i = start; i < html.length; i++) {
        const ch = html[i];
        if (inString) {
          if (escaped) escaped = false;
          else if (ch === '\\') escaped = true;
          else if (ch === '"') inString = false;
        } else {
          if (ch === '"') inString = true;
          else if (ch === '{') depth++;
          else if (ch === '}') {
            depth--;
            if (depth === 0) return html.slice(start, i + 1);
          }
        }
      }
    }
    return null;
  }

  function parseChineseCount(raw) {
    if (typeof raw === 'number' && Number.isFinite(raw)) return Math.max(0, Math.round(raw));
    const s = String(raw ?? '').trim().replace(/[+,]/g, '');
    if (!s) return null;
    if (s.endsWith('万') || s.toLowerCase().endsWith('w')) {
      const v = Number.parseFloat(s.slice(0, -1));
      return Number.isFinite(v) ? Math.max(0, Math.round(v * 10_000)) : null;
    }
    if (s.endsWith('千') || s.toLowerCase().endsWith('k')) {
      const v = Number.parseFloat(s.slice(0, -1));
      return Number.isFinite(v) ? Math.max(0, Math.round(v * 1_000)) : null;
    }
    return /^\d+$/.test(s) ? Number.parseInt(s, 10) : null;
  }

  function parseXhsNoteStateFromHtml(html, noteUrl, fallback = {}) {
    const rawJson = extractInitialStateFromHtml(html);
    if (!rawJson) return null;
    let root;
    try {
      root = JSON.parse(sanitizeJSUndefined(rawJson));
    } catch {
      return null;
    }
    const norm = normalizeXhsNoteHref(noteUrl);
    const expectedId = norm?.noteId || fallback.noteId || null;
    let note = null;
    const map = root?.note?.noteDetailMap;
    if (map && typeof map === 'object') {
      if (expectedId && map[expectedId]?.note) note = map[expectedId].note;
      else {
        for (const entry of Object.values(map)) {
          if (entry?.note && (entry.note.title || entry.note.desc || entry.note.imageList)) {
            note = entry.note;
            break;
          }
        }
      }
    }
    if (!note && root?.note?.note) note = root.note.note;
    if (!note && root?.noteData?.data?.noteData) note = root.noteData.data.noteData;
    if (!note) return null;

    const title = String(note.title || fallback.articleTitle || '').trim();
    const desc = String(note.desc || fallback.bodyText || '').replace(/\[话题\]#/g, '').trim();
    const user = note.user || {};
    const authorName = String(user.nickname || user.nickName || fallback.authorName || '小红书用户').trim();
    const authorHandle = String(user.redId || user.userId || user.id || fallback.authorHandle || 'xiaohongshu').trim();
    const authorAvatarURL = upgradeHttps(user.avatar || fallback.authorAvatarURL || '') || null;
    const interact = note.interactInfo || {};

    let publishedAtText = null;
    const ts = Number(note.time ?? note.lastUpdateTime);
    if (Number.isFinite(ts) && ts > 1_000_000_000) {
      const d = new Date(ts > 10_000_000_000 ? ts : ts * 1000);
      const pad = (v) => String(v).padStart(2, '0');
      if (!Number.isNaN(d.getTime())) {
        publishedAtText = `${d.getFullYear()}-${pad(d.getMonth() + 1)}-${pad(d.getDate())} ${pad(d.getHours())}:${pad(d.getMinutes())}`;
      }
    }

    const isVideoNote = String(note.type || '').toLowerCase() === 'video' || Boolean(fallback.hasVideo);
    let videoURL = null;
    const stream = note.video?.media?.stream;
    if (stream && typeof stream === 'object') {
      for (const codec of ['h264', 'av1', 'h265']) {
        const list = Array.isArray(stream[codec]) ? stream[codec] : [];
        for (const v of list) {
          const master = upgradeHttps(v?.masterUrl || '');
          if (master) {
            videoURL = master;
            break;
          }
          const b = (Array.isArray(v?.backupUrls) ? v.backupUrls : []).map(upgradeHttps).find(Boolean);
          if (b) {
            videoURL = b;
            break;
          }
        }
        if (videoURL) break;
      }
    }
    if (!videoURL && note.video?.consumer?.originVideoKey) {
      const key = String(note.video.consumer.originVideoKey).replace(/^\/+/, '');
      if (key) videoURL = `https://sns-video-bd.xhscdn.com/${key}`;
    }

    const attachments = [];
    const seen = new Set();
    let coverPhoto = null;
    for (const img of Array.isArray(note.imageList) ? note.imageList : []) {
      const infos = Array.isArray(img?.infoList) ? img.infoList : [];
      const dft = infos.find((i) => i?.imageScene === 'WB_DFT');
      const prv = infos.find((i) => i?.imageScene === 'WB_PRV');
      const fullUrl = upgradeHttps(dft?.url || img?.urlDefault || img?.url || infos[0]?.url || img?.urlPre || '');
      const thumbUrl = upgradeHttps(prv?.url || img?.urlPre || fullUrl) || fullUrl;
      if (!fullUrl) continue;
      if (!coverPhoto) coverPhoto = fullUrl;
      if (!isVideoNote && !seen.has(fullUrl)) {
        seen.add(fullUrl);
        attachments.push({ kind: 'photo', url: fullUrl, thumbnailURL: thumbUrl });
      }
    }
    if (videoURL && !seen.has(videoURL)) {
      seen.add(videoURL);
      attachments.unshift({
        kind: 'video',
        url: videoURL,
        thumbnailURL: coverPhoto || fallback.coverUrl || null,
      });
    } else if (attachments.length === 0 && (coverPhoto || fallback.coverUrl)) {
      const c = coverPhoto || fallback.coverUrl;
      attachments.push({ kind: 'photo', url: c, thumbnailURL: c });
    }

    if (!title && !desc && attachments.length === 0) return null;

    const tags = Array.isArray(note.tagList)
      ? note.tagList.map((t) => String(t?.name || '').trim()).filter((t) => t && t.length <= 32)
      : [];

    return {
      type: 'socialBookmark',
      platform: 'xiaohongshu',
      originalURL: norm?.url || noteUrl,
      dedupKey: norm?.dedupKey || fallback.dedupKey || null,
      authorName,
      authorHandle,
      authorAvatarURL,
      publishedAtText,
      articleTitle: title || null,
      bodyText: desc || title || noteUrl,
      mediaURLs: attachments.map((a) => a.url),
      mediaThumbnailURLs: attachments.map((a) => a.thumbnailURL || a.url),
      attachments,
      hasVideo: Boolean(videoURL || isVideoNote),
      videoURL,
      replyCount: parseChineseCount(interact.commentCount),
      repostCount: parseChineseCount(interact.shareCount ?? interact.collectedCount),
      likeCount: parseChineseCount(interact.likedCount ?? fallback.likeCount),
      tags: Array.from(new Set(['小红书', ...tags])),
    };
  }

  function extractCurrentSingleXiaohongshuNote() {
    const norm = normalizeXhsNoteHref(window.location.href);
    if (!norm) return null;

    // 1. Scan inline scripts for window.__INITIAL_STATE__
    for (const script of document.querySelectorAll('script')) {
      const text = script.textContent || '';
      if (text.includes('window.__INITIAL_STATE__')) {
        const parsed = parseXhsNoteStateFromHtml(text, window.location.href, { noteId: norm.noteId });
        if (parsed) return parsed;
      }
    }

    // 2. Live DOM extraction fallback (works cleanly on SPA-navigated Xiaohongshu note modals & pages)
    const title = (
      document.querySelector('#detail-title, .note-content .title, [class*="detail-title"]')?.textContent ||
      document.title.replace(/\s*-\s*小红书.*$/, '') ||
      ''
    ).trim();
    const desc = (
      document.querySelector('#detail-desc, .note-content .desc, [class*="note-text"]')?.textContent || ''
    )
      .replace(/\[话题\]#/g, '')
      .trim();
    const authorName = (
      document.querySelector('.author-wrapper .username, .author-container .name, [class*="author"] .username')?.textContent ||
      '小红书用户'
    ).trim();
    const avatarImg = document.querySelector('.author-wrapper img, .author-container img');
    const authorAvatarURL = upgradeHttps(avatarImg?.currentSrc || avatarImg?.src || '') || null;

    const attachments = [];
    const seen = new Set();
    for (const img of document.querySelectorAll(
      '.swiper-slide:not(.swiper-slide-duplicate) img, .note-slider-img, .media-container img, .img-container img',
    )) {
      const u = upgradeHttps(img.currentSrc || img.src || '');
      if (u && !u.includes('avatar') && !seen.has(u)) {
        seen.add(u);
        attachments.push({ kind: 'photo', url: u, thumbnailURL: u });
      }
    }
    const videoEl = document.querySelector('.player-container video, video');
    const videoSrc = upgradeHttps(videoEl?.currentSrc || videoEl?.src || '') || null;
    if (videoSrc && !seen.has(videoSrc)) {
      attachments.unshift({
        kind: 'video',
        url: videoSrc,
        thumbnailURL: upgradeHttps(videoEl?.poster || '') || attachments[0]?.url || null,
      });
    }

    if (!title && !desc && attachments.length === 0) return null;
    return {
      type: 'socialBookmark',
      platform: 'xiaohongshu',
      originalURL: norm.url,
      dedupKey: norm.dedupKey,
      authorName,
      authorHandle: norm.noteId,
      authorAvatarURL,
      articleTitle: title || null,
      bodyText: desc || title || norm.url,
      mediaURLs: attachments.map((a) => a.url),
      mediaThumbnailURLs: attachments.map((a) => a.thumbnailURL || a.url),
      attachments,
      hasVideo: Boolean(videoSrc),
      videoURL: videoSrc,
      tags: ['小红书'],
    };
  }

  // MARK: - X & Xiaohongshu DOM Harvesters for Batch Bookmark Import

  function extractTweetTextWithEmoji(tweetTextEl) {
    if (!tweetTextEl) return '';
    let out = '';
    for (const node of tweetTextEl.childNodes) {
      if (node.nodeType === Node.TEXT_NODE) {
        out += node.textContent || '';
      } else if (node.nodeType === Node.ELEMENT_NODE) {
        if (node.tagName === 'IMG' && node.getAttribute('alt')) {
          out += node.getAttribute('alt');
        } else if (node.tagName === 'BR') {
          out += '\n';
        } else {
          out += extractTweetTextWithEmoji(node);
        }
      }
    }
    return out.trim();
  }

  function parseXActionCount(article, selectors) {
    for (const sel of selectors) {
      const btn = article.querySelector(sel);
      if (!btn) continue;
      const text = (btn.textContent || '').trim();
      const parsed = parseChineseCount(text);
      if (parsed !== null) return parsed;
    }
    return null;
  }

  function harvestVisibleXTweets(pageKind = 'bookmarks') {
    const items = [];
    const articles = document.querySelectorAll('article[data-testid="tweet"]');
    const primaryTag = pageKind === 'likes' ? 'X 喜欢' : 'X 书签';
    for (const article of articles) {
      // Find the primary tweet status anchor (the one wrapping <time>) so we never grab a quoted tweet's link.
      let statusAnchor = null;
      const timeEl = article.querySelector('time');
      if (timeEl) {
        const parentLink = timeEl.closest('a[href*="/status/"]');
        if (parentLink && parentLink.closest('article[data-testid="tweet"]') === article) {
          statusAnchor = parentLink;
        }
      }
      if (!statusAnchor) {
        for (const a of article.querySelectorAll('a[href*="/status/"]')) {
          if (a.closest('[role="link"][tabindex="0"]')) continue;
          statusAnchor = a;
          break;
        }
      }
      if (!statusAnchor) continue;

      const rawHref = statusAnchor.getAttribute('href') || '';
      let pathname = rawHref;
      try {
        pathname = new URL(rawHref, window.location.origin).pathname;
      } catch {
        // keep rawHref
      }
      let handle = 'i';
      let tweetID = '';
      const webMatch = /^\/i\/web\/status\/(\d{1,24})/.exec(pathname);
      const stdMatch = /^\/([^/]+)\/status(?:es)?\/(\d{1,24})/.exec(pathname);
      if (webMatch) {
        tweetID = webMatch[1];
      } else if (stdMatch) {
        handle = stdMatch[1].replace(/^@/, '') || 'i';
        tweetID = stdMatch[2];
      } else {
        continue;
      }
      const canonicalURL = `https://x.com/${handle}/status/${tweetID}`;

      const userNameBlock = article.querySelector('[data-testid="User-Name"]');
      let authorName = handle;
      let authorHandle = handle;
      if (userNameBlock) {
        const spans = Array.from(userNameBlock.querySelectorAll('span'))
          .map((s) => (s.textContent || '').trim())
          .filter(Boolean);
        const atSpan = spans.find((t) => t.startsWith('@') && t.length > 1);
        if (atSpan) authorHandle = atSpan.slice(1);
        const nameCandidate = spans.find((t) => !t.startsWith('@') && t !== '·');
        if (nameCandidate) authorName = nameCandidate;
      }

      const avatarImg = article.querySelector('[data-testid="Tweet-User-Avatar"] img');
      let authorAvatarURL = upgradeHttps(avatarImg?.currentSrc || avatarImg?.src || '') || null;
      if (authorAvatarURL && authorAvatarURL.includes('_normal.')) {
        authorAvatarURL = authorAvatarURL.replace('_normal.', '_400x400.');
      }

      const publishedAtText = timeEl?.getAttribute('datetime')
        ? timeEl.getAttribute('datetime').slice(0, 16).replace('T', ' ')
        : null;

      const textEls = article.querySelectorAll('[data-testid="tweetText"]');
      const bodyText = textEls[0] ? extractTweetTextWithEmoji(textEls[0]) : '';
      const quotedText = textEls[1] ? extractTweetTextWithEmoji(textEls[1]) : null;

      const attachments = [];
      const seenMedia = new Set();
      for (const img of article.querySelectorAll('[data-testid="tweetPhoto"] img')) {
        const u = upgradeUrl(img.currentSrc || img.src || '');
        if (u && !seenMedia.has(u)) {
          seenMedia.add(u);
          attachments.push({ kind: 'photo', url: u, thumbnailURL: u });
        }
      }

      const videoPlayer = article.querySelector('[data-testid="videoPlayer"], [data-testid="videoComponent"]');
      const videoEl = videoPlayer?.querySelector('video');
      const hasVideo = Boolean(videoPlayer || videoEl);
      const videoPoster = upgradeHttps(videoEl?.getAttribute('poster') || '') || null;
      if (hasVideo && videoPoster && attachments.length === 0) {
        attachments.push({ kind: 'photo', url: videoPoster, thumbnailURL: videoPoster });
      }

      if (attachments.length === 0) {
        const cardImg = article.querySelector(
          '[data-testid="card.layoutLarge.media"] img, [data-testid="card.layoutSmall.media"] img, [data-testid="article-cover-image"] img',
        );
        const cardUrl = upgradeUrl(cardImg?.currentSrc || cardImg?.src || '');
        if (cardUrl && !seenMedia.has(cardUrl)) {
          seenMedia.add(cardUrl);
          attachments.push({ kind: 'photo', url: cardUrl, thumbnailURL: cardUrl });
        }
      }

      const replyCount = parseXActionCount(article, ['button[data-testid="reply"]']);
      const repostCount = parseXActionCount(article, ['button[data-testid="retweet"]', 'button[data-testid="unretweet"]']);
      const likeCount = parseXActionCount(article, ['button[data-testid="like"]', 'button[data-testid="unlike"]']);

      items.push({
        type: 'socialBookmark',
        platform: 'x',
        originalURL: canonicalURL,
        dedupKey: `x:${tweetID}`,
        authorName,
        authorHandle,
        authorAvatarURL,
        publishedAtText,
        bodyText: bodyText || canonicalURL,
        quotedText: quotedText || null,
        mediaURLs: attachments.map((a) => a.url),
        mediaThumbnailURLs: attachments.map((a) => a.thumbnailURL || a.url),
        attachments,
        hasVideo,
        videoURL: null,
        replyCount,
        repostCount,
        likeCount,
        tags: ['X', primaryTag],
      });
    }
    return items;
  }

  function harvestVisibleXhsNotes(pageKind = 'collect') {
    const items = [];
    const seenIds = new Set();
    const primaryTag = pageKind === 'likes' ? '小红书点赞' : '小红书收藏';
    let cards = Array.from(document.querySelectorAll('section.note-item, .note-item'));

    if (cards.length === 0) {
      const containerSet = new Set();
      for (const a of document.querySelectorAll(
        'a[href*="/explore/"], a[href*="/discovery/item/"], a[href*="/user/profile/"]',
      )) {
        const norm = normalizeXhsNoteHref(a.getAttribute('href') || '');
        if (!norm) continue;
        const container = a.closest('section, article, li') || a.parentElement;
        if (container) containerSet.add(container);
      }
      cards = Array.from(containerSet);
    }

    for (const card of cards) {
      const anchors = Array.from(card.querySelectorAll('a[href]'));
      let bestNorm = null;
      for (const a of anchors) {
        const norm = normalizeXhsNoteHref(a.getAttribute('href') || '');
        if (!norm) continue;
        // Strongly prefer the anchor carrying xsec_token so the note remains resolvable.
        if (!bestNorm || (norm.xsecToken && !bestNorm.xsecToken)) {
          bestNorm = norm;
        }
      }
      if (!bestNorm || seenIds.has(bestNorm.noteId)) continue;
      seenIds.add(bestNorm.noteId);

      const title = (
        card.querySelector('.footer .title span, .title span, a.title, .title')?.textContent ||
        card.querySelector('.cover img, img')?.getAttribute('alt') ||
        ''
      ).trim();
      const authorName = (
        card.querySelector('.author .name, .author-wrapper .name, .author-name, .name')?.textContent ||
        '小红书用户'
      ).trim();
      const avatarImg = card.querySelector('.author img, .author-wrapper img, img.author-avatar');
      const authorAvatarURL = upgradeHttps(avatarImg?.currentSrc || avatarImg?.src || '') || null;

      const coverImg = card.querySelector('a.cover img, .cover img, img');
      const coverUrl = upgradeHttps(
        coverImg?.currentSrc || coverImg?.getAttribute('data-src') || coverImg?.src || '',
      );
      const likeCountText = card.querySelector('.like-wrapper .count, .count')?.textContent || '';
      const likeCount = parseChineseCount(likeCountText);
      const hasVideo = Boolean(
        card.querySelector('.play-icon, [class*="play-icon"], [class*="video-icon"], .video-tag'),
      );

      const attachments = coverUrl ? [{ kind: 'photo', url: coverUrl, thumbnailURL: coverUrl }] : [];
      items.push({
        type: 'socialBookmark',
        platform: 'xiaohongshu',
        noteId: bestNorm.noteId,
        originalURL: bestNorm.url,
        dedupKey: bestNorm.dedupKey,
        authorName,
        authorHandle: bestNorm.noteId,
        authorAvatarURL,
        articleTitle: title || null,
        bodyText: title || bestNorm.url,
        coverUrl: coverUrl || null,
        mediaURLs: attachments.map((a) => a.url),
        mediaThumbnailURLs: attachments.map((a) => a.thumbnailURL || a.url),
        attachments,
        hasVideo,
        videoURL: null,
        likeCount,
        tags: ['小红书', primaryTag],
      });
    }

    return items;
  }

  async function ensureXAuthorMediaTabActive(pageInfo) {
    if (!pageInfo || pageInfo.platform !== 'x' || pageInfo.pageKind !== 'author_media') return;
    const handle = String(pageInfo.authorHandle || '').trim();
    if (!handle) return;
    if (/\/media\/?$/i.test(window.location.pathname)) return;

    const targetHref = `/${handle.toLowerCase()}/media`;
    const tabLinks = Array.from(document.querySelectorAll('a[role="tab"], [role="tablist"] a[href]'));
    const mediaTab = tabLinks.find((el) => {
      const href = String(el.getAttribute('href') || '').trim().toLowerCase();
      if (href === targetHref) return true;
      const text = (el.textContent || '').trim();
      return /^(媒体|media|メディア)$/i.test(text);
    });
    if (!mediaTab) return;

    batchJob.phase = `正在自动切换至 @${handle} 的「媒体」标签页…`;
    syncHudAndPush();
    mediaTab.click();
    for (let waited = 0; waited < 3000 && !batchJob.stopRequested; waited += 300) {
      await sleep(300);
      if (
        /\/media\/?$/i.test(window.location.pathname) &&
        (document.querySelector('main a[href*="/status/"] img') ||
          document.querySelector('article[data-testid="tweet"]'))
      ) {
        break;
      }
    }
    await sleep(350);
  }

  function harvestVisibleXAuthorMedia(pageInfo, runOptions) {
    const targetHandle = String(pageInfo?.authorHandle || '').trim().replace(/^@/, '');
    const targetLower = targetHandle.toLowerCase();
    const skipRetweets = runOptions?.skipRetweets !== false;
    const includeVideos = runOptions?.includeVideos !== false;
    const authorDisplayName = readXProfileDisplayName(targetHandle) || pageInfo?.authorName || targetHandle;
    const mergedById = new Map();

    // 1. Pull rich passively intercepted GraphQL tweets first (contains ALL 4 photos + MP4 videos + text + timestamps).
    for (const gqlTweet of capturedXTweetsById.values()) {
      if (!gqlTweet || !gqlTweet.tweetID) continue;
      const authorLower = String(gqlTweet.authorHandle || '').toLowerCase();
      if (skipRetweets) {
        if (gqlTweet.isRetweet) continue;
        if (targetLower && authorLower && authorLower !== 'i' && authorLower !== targetLower) continue;
      }
      const filteredMedia = includeVideos
        ? gqlTweet.media || []
        : (gqlTweet.media || []).filter((m) => m && m.kind === 'photo');
      if (filteredMedia.length === 0) continue;
      mergedById.set(gqlTweet.tweetID, {
        ...gqlTweet,
        media: filteredMedia,
        hasVideo: filteredMedia.some((m) => m.kind === 'video' || m.kind === 'gif'),
        needsEnrich: false,
      });
    }

    // 2. Harvest visible /media grid tiles (covers page-1 tiles rendered before bridge attached).
    const primaryCol = document.querySelector('[data-testid="primaryColumn"], main') || document;
    for (const anchor of primaryCol.querySelectorAll('a[href*="/status/"]')) {
      if (anchor.closest('[data-testid="UserDescription"], [data-testid="sidebarColumn"]')) continue;
      const rawHref = anchor.getAttribute('href') || '';
      let pathname = rawHref;
      try {
        pathname = new URL(rawHref, window.location.origin).pathname;
      } catch {
        // keep rawHref
      }
      const match = /^\/([^/]+)\/status(?:es)?\/(\d{1,24})(?:\/(photo|video)\/\d+)?/i.exec(pathname);
      if (!match) continue;
      const handle = match[1].replace(/^@/, '') || targetHandle || 'i';
      const tweetID = match[2];
      const mediaKindHint = (match[3] || '').toLowerCase();

      if (skipRetweets && targetLower && handle.toLowerCase() !== 'i' && handle.toLowerCase() !== targetLower) {
        continue;
      }
      if (mergedById.has(tweetID)) continue;

      const img = anchor.querySelector('img[src*="pbs.twimg.com"]');
      const hasVideoBadge =
        mediaKindHint === 'video' ||
        Boolean(
          anchor.querySelector('[data-testid="playButton"], svg[aria-label*="Play"], [data-testid="videoComponent"]'),
        );
      if (!img && !hasVideoBadge) continue;

      const rawSrc = img?.currentSrc || img?.src || '';
      const isVideoThumb =
        hasVideoBadge ||
        rawSrc.includes('ext_tw_video_thumb') ||
        rawSrc.includes('amplify_video_thumb') ||
        rawSrc.includes('tweet_video_thumb');
      if (isVideoThumb && !includeVideos) continue;

      const upgraded = rawSrc ? upgradeTwitterPhotoToOrig(rawSrc) : '';
      const media = upgraded
        ? [
            {
              kind: isVideoThumb ? 'video' : 'photo',
              url: upgraded,
              thumbnailURL: upgradeUrl(rawSrc) || upgraded,
            },
          ]
        : [];
      mergedById.set(tweetID, {
        tweetID,
        originalURL: `https://x.com/${handle}/status/${tweetID}`,
        dedupKey: `x:${tweetID}`,
        authorName: authorDisplayName || handle,
        authorHandle: handle,
        authorAvatarURL: null,
        publishedAtText: null,
        publishedDateKey: '',
        bodyText: '',
        isRetweet: false,
        media,
        hasVideo: isVideoThumb,
        // Grid tiles only show 1 cover thumbnail & omit multi-photo lists + text, so let desktop enrich via XPostResolver.
        needsEnrich: true,
      });
    }

    // 3. Harvest visible timeline tweet articles (when user runs directly on Posts/Highlights/Replies tab).
    const timelineTweets = harvestVisibleXTweets('author_media');
    for (const item of timelineTweets) {
      const m = /\/status\/(\d{1,24})/.exec(item.originalURL || '');
      const tweetID = m ? m[1] : '';
      if (!tweetID || mergedById.has(tweetID)) continue;
      const authorLower = String(item.authorHandle || '').toLowerCase();
      if (skipRetweets && targetLower && authorLower && authorLower !== 'i' && authorLower !== targetLower) {
        continue;
      }
      const rawAttachments = Array.isArray(item.attachments) ? item.attachments : [];
      if (rawAttachments.length === 0 && !item.hasVideo) continue;
      if (item.hasVideo && rawAttachments.length === 0 && !includeVideos) continue;

      const media = rawAttachments
        .filter((att) => includeVideos || att.kind === 'photo')
        .map((att) => ({
          kind: att.kind || 'photo',
          url: att.kind === 'photo' ? upgradeTwitterPhotoToOrig(att.url) : att.url,
          thumbnailURL: att.thumbnailURL || att.url,
        }));
      if (media.length === 0 && !(item.hasVideo && includeVideos)) continue;

      mergedById.set(tweetID, {
        tweetID,
        originalURL: item.originalURL,
        dedupKey: `x:${tweetID}`,
        authorName: item.authorName || authorDisplayName || targetHandle,
        authorHandle: item.authorHandle || targetHandle,
        authorAvatarURL: item.authorAvatarURL || null,
        publishedAtText: item.publishedAtText || null,
        publishedDateKey: item.publishedAtText ? item.publishedAtText.slice(0, 10) : '',
        bodyText: item.bodyText === item.originalURL ? '' : item.bodyText,
        isRetweet: false,
        media,
        hasVideo: Boolean(item.hasVideo),
        needsEnrich: Boolean(item.hasVideo),
      });
    }

    return Array.from(mergedById.values());
  }

  // MARK: - Bluesky, Pixiv, Threads & Instagram Collectors

  function isLikelyAvatarImageUrl(url) {
    const lower = String(url || '').toLowerCase();
    return (
      lower.includes('avatar') ||
      lower.includes('profile_pic') ||
      lower.includes('profile_images') ||
      lower.includes('s150x150') ||
      lower.includes('s100x100') ||
      lower.includes('/img/avatar/')
    );
  }

  function bestImgUrlFromElement(img) {
    if (!img) return '';
    const srcset = img.getAttribute('srcset') || '';
    if (srcset) {
      const best = pickBestSrcset(srcset);
      if (best) return best;
    }
    return upgradeHttps(img.currentSrc || img.getAttribute('data-src') || img.src || '');
  }

  function harvestVisibleBlueskyMedia(pageInfo, runOptions) {
    const targetLower = String(pageInfo?.authorHandle || '').trim().replace(/^@/, '').toLowerCase();
    const skipRetweets = runOptions?.skipRetweets !== false && pageInfo?.pageKind !== 'likes';
    const includeVideos = runOptions?.includeVideos !== false;
    const mergedByKey = new Map();

    for (const post of capturedSocialPostsByKey.values()) {
      if (post.platform !== 'bluesky') continue;
      if (skipRetweets) {
        if (post.isRetweet) continue;
        if (targetLower && String(post.authorHandle || '').toLowerCase() !== targetLower) continue;
      }
      const media = includeVideos ? post.media || [] : (post.media || []).filter((m) => m && m.kind === 'photo');
      if (media.length === 0) continue;
      mergedByKey.set(post.dedupKey, { ...post, media, hasVideo: media.some((m) => m.kind !== 'photo') });
    }

    // DOM fallback on bsky.app feed/media grids
    for (const anchor of document.querySelectorAll('a[href*="/profile/"][href*="/post/"]')) {
      const href = anchor.getAttribute('href') || '';
      const m = /\/profile\/([^/]+)\/post\/([a-zA-Z0-9._-]+)/.exec(href);
      if (!m) continue;
      const handle = decodeURIComponent(m[1]).replace(/^@/, '');
      const postID = m[2];
      if (skipRetweets && targetLower && handle.toLowerCase() !== targetLower) continue;
      const dedupKey = `bsky:${handle.toLowerCase()}:${postID}`;
      if (mergedByKey.has(dedupKey)) continue;

      const container = anchor.closest('[data-testid*="feedItem"], [data-testid*="post"], article, div[role="link"]') || anchor.parentElement;
      const imgs = container ? Array.from(container.querySelectorAll('img[src*="cdn.bsky.app"]')) : [];
      const media = [];
      const seen = new Set();
      for (const img of imgs) {
        const src = bestImgUrlFromElement(img);
        if (!src || isLikelyAvatarImageUrl(src) || seen.has(src)) continue;
        const fullsize = src.replace('/img/feed_thumbnail/', '/img/feed_fullsize/');
        seen.add(fullsize);
        media.push({ kind: 'photo', url: fullsize, thumbnailURL: src });
      }
      const hasVideo = Boolean(container?.querySelector('video'));
      if (media.length === 0 && !(hasVideo && includeVideos)) continue;
      mergedByKey.set(dedupKey, {
        platform: 'bluesky',
        postID,
        tweetID: postID,
        originalURL: `https://bsky.app/profile/${handle}/post/${postID}`,
        dedupKey,
        authorName: readCreatorDisplayName('bluesky', handle) || handle,
        authorHandle: handle,
        publishedAtText: null,
        publishedDateKey: '',
        title: '',
        bodyText: '',
        isRetweet: false,
        media,
        hasVideo,
        needsEnrich: media.length === 0 || hasVideo,
        referer: 'https://bsky.app/',
      });
    }

    return Array.from(mergedByKey.values());
  }

  function harvestVisibleThreadsMedia(pageInfo, runOptions) {
    const targetLower = String(pageInfo?.authorHandle || '').trim().replace(/^@/, '').toLowerCase();
    const skipRetweets = runOptions?.skipRetweets !== false && pageInfo?.pageKind === 'author_media';
    const includeVideos = runOptions?.includeVideos !== false;
    const mergedByKey = new Map();

    // 1. Passive GraphQL capture (carries complete carousels & MP4 videos)
    for (const post of capturedSocialPostsByKey.values()) {
      if (post.platform !== 'threads') continue;
      if (skipRetweets) {
        if (post.isRetweet) continue;
        if (targetLower && String(post.authorHandle || '').toLowerCase() !== targetLower) continue;
      }
      const media = includeVideos ? post.media || [] : (post.media || []).filter((m) => m && m.kind === 'photo');
      if (media.length === 0) continue;
      mergedByKey.set(post.dedupKey, { ...post, media, hasVideo: media.some((m) => m.kind !== 'photo') });
    }

    // 2. DOM fallback for already-rendered Threads posts
    for (const anchor of document.querySelectorAll('a[href*="/post/"]')) {
      const rawHref = anchor.getAttribute('href') || '';
      const m = /\/@?([^/]+)\/post\/([a-zA-Z0-9_-]+)/.exec(rawHref);
      if (!m) continue;
      const handle = m[1].replace(/^@/, '');
      const code = m[2];
      if (skipRetweets && targetLower && handle.toLowerCase() !== targetLower) continue;
      const dedupKey = `threads:${code}`;
      if (mergedByKey.has(dedupKey)) continue;

      const container = anchor.closest('[data-pressable-container="true"], article') || anchor.parentElement?.parentElement;
      if (!container) continue;
      const media = [];
      const seen = new Set();

      if (includeVideos) {
        for (const vid of container.querySelectorAll('video')) {
          const vSrc = upgradeHttps(vid.currentSrc || vid.src || '');
          const poster = upgradeHttps(vid.getAttribute('poster') || '');
          const chosen = vSrc && !vSrc.startsWith('blob:') ? vSrc : poster;
          if (!chosen || seen.has(chosen)) continue;
          seen.add(chosen);
          media.push({ kind: vSrc && !vSrc.startsWith('blob:') ? 'video' : 'photo', url: chosen, thumbnailURL: poster || chosen });
        }
      }
      for (const img of container.querySelectorAll('img')) {
        const w = img.naturalWidth || img.clientWidth || 0;
        const h = img.naturalHeight || img.clientHeight || 0;
        if ((w > 0 && w < 120) || (h > 0 && h < 120)) continue;
        const src = bestImgUrlFromElement(img);
        if (!src || isLikelyAvatarImageUrl(src) || seen.has(src)) continue;
        seen.add(src);
        media.push({ kind: 'photo', url: src, thumbnailURL: src });
      }
      if (media.length === 0) continue;

      const timeEl = container.querySelector('time');
      const dates = formatDateString(timeEl?.getAttribute('datetime') || '');
      const textParts = Array.from(container.querySelectorAll('span[dir="auto"], div[dir="auto"]'))
        .map((el) => (el.textContent || '').trim())
        .filter((t) => t && t.length > 1 && t !== handle && t !== `@${handle}`);
      mergedByKey.set(dedupKey, {
        platform: 'threads',
        postID: code,
        tweetID: code,
        originalURL: `https://www.threads.net/@${handle}/post/${code}`,
        dedupKey,
        authorName: readCreatorDisplayName('threads', handle) || handle,
        authorHandle: handle,
        publishedAtText: dates.publishedAtText,
        publishedDateKey: dates.publishedDateKey,
        title: '',
        bodyText: (textParts[0] || '').slice(0, 600),
        isRetweet: false,
        media,
        hasVideo: media.some((x) => x.kind === 'video' || x.kind === 'gif'),
        needsEnrich: false,
        referer: 'https://www.threads.net/',
      });
    }

    return Array.from(mergedByKey.values());
  }

  function harvestVisibleInstagramMedia(pageInfo, runOptions) {
    const targetLower = String(pageInfo?.authorHandle || '').trim().replace(/^@/, '').toLowerCase();
    const skipRetweets = runOptions?.skipRetweets !== false && pageInfo?.pageKind === 'author_media';
    const includeVideos = runOptions?.includeVideos !== false;
    const authorDisplayName = readCreatorDisplayName('instagram', pageInfo?.authorHandle || '') || pageInfo?.authorHandle || 'instagram';
    const mergedByKey = new Map();

    // 1. Passive GraphQL/REST capture (full multi-slide carousels + highest-res MP4 reels)
    for (const post of capturedSocialPostsByKey.values()) {
      if (post.platform !== 'instagram') continue;
      if (skipRetweets && targetLower && post.authorHandle && post.authorHandle !== 'instagram' && post.authorHandle.toLowerCase() !== targetLower) {
        continue;
      }
      const media = includeVideos ? post.media || [] : (post.media || []).filter((m) => m && m.kind === 'photo');
      if (media.length === 0) continue;
      mergedByKey.set(post.dedupKey, { ...post, media, hasVideo: media.some((m) => m.kind !== 'photo') });
    }

    // 2. DOM grid fallback (`/p/<code>/` and `/reel/<code>/` tiles)
    const root = document.querySelector('main') || document;
    for (const anchor of root.querySelectorAll('a[href*="/p/"], a[href*="/reel/"], a[href*="/tv/"]')) {
      const rawHref = anchor.getAttribute('href') || '';
      const m = /\/(p|reel|tv)\/([a-zA-Z0-9_-]{4,40})/.exec(rawHref);
      if (!m) continue;
      const pathKind = m[1] === 'reel' ? 'reel' : 'p';
      const code = m[2];
      const dedupKey = `ig:${code}`;
      if (mergedByKey.has(dedupKey)) continue;

      const isReel = pathKind === 'reel';
      if (isReel && !includeVideos) continue;

      const img = anchor.querySelector('img');
      const src = bestImgUrlFromElement(img);
      if (!src || isLikelyAvatarImageUrl(src)) continue;
      const alt = String(img?.getAttribute('alt') || '').trim();

      mergedByKey.set(dedupKey, {
        platform: 'instagram',
        postID: code,
        tweetID: code,
        originalURL: `https://www.instagram.com/${pathKind}/${code}/`,
        dedupKey,
        authorName: authorDisplayName,
        authorHandle: pageInfo?.authorHandle || 'instagram',
        publishedAtText: null,
        publishedDateKey: '',
        title: '',
        bodyText: alt.slice(0, 500),
        isRetweet: false,
        media: [{ kind: 'photo', url: src, thumbnailURL: src }],
        hasVideo: isReel,
        needsEnrich: false,
        referer: 'https://www.instagram.com/',
      });
    }

    return Array.from(mergedByKey.values());
  }

  async function flushCreatorMediaBatch(posts, {
    skipDuplicates,
    isFinal,
    organizeMode,
    includeVideos,
    effectiveTargetFolderId,
    platform,
    authorHandle,
    authorName,
  }) {
    if (!posts || posts.length === 0) return;
    const platformTag = SOCIAL_PLATFORM_DISPLAY[platform] || '社交';
    const baseTags = Array.from(
      new Set(
        [
          platformTag,
          platform !== 'pixiv' && platform !== 'xiaohongshu' && authorHandle ? `@${authorHandle}` : '',
          authorName || '',
        ].filter(Boolean),
      ),
    );
    const preparedPosts = posts.map((post) => {
      const mergedTags = Array.from(new Set([...(post.tags || []), ...baseTags]));
      return {
        ...post,
        platform: post.platform || platform,
        subfolderName: resolvePostSubfolderName(post, organizeMode),
        organizeMode,
        includeVideos,
        tags: mergedTags,
      };
    });

    const noun = SOCIAL_PLATFORM_NOUN[platform] || '作品';
    batchJob.phase = `正在下载原画质媒体并按${noun}整理（本批 ${preparedPosts.length} 条）…`;
    syncHudAndPush();

    const msgPayload = {
      type: 'INGEST_SOCIAL_MEDIA_CHUNK',
      posts: preparedPosts,
      skipDuplicates,
      isFinalChunk: isFinal,
      targetFolderId: effectiveTargetFolderId,
      targetBoardId: null,
      targetLabel: batchJob.targetLabel,
      badgeText: String(Math.min(999, batchJob.mediaImported + preparedPosts.length)),
    };

    try {
      const res = await ext.runtime.sendMessage(msgPayload);
      if (res?.ok) {
        batchJob.mediaImported += Number(res.created || 0);
        batchJob.imported += Number(res.postsImported ?? res.tweetsImported ?? 0);
        batchJob.skipped += Number(res.skipped || 0);
        const lastPost = preparedPosts[preparedPosts.length - 1];
        const lastTitle =
          res.assets?.[res.assets.length - 1]?.title ||
          lastPost?.title ||
          lastPost?.subfolderName ||
          `${noun} ${lastPost?.postID || ''}`;
        if (lastTitle) batchJob.lastItemTitle = lastTitle;
      } else {
        batchJob.failed += preparedPosts.length;
      }
    } catch {
      batchJob.failed += preparedPosts.length;
    }
    syncHudAndPush();
  }

  async function runPixivDirectCollection(pageInfo, runOptions, knownKeys, effectiveTargetFolderId) {
    const { skipDuplicates, stopOnKnownStreak, maxCount, organizeMode, includeVideos } = runOptions;
    const userId = String(pageInfo.authorHandle || '').trim();
    const isBookmarks = pageInfo.pageKind === 'bookmarks';

    let authorName = pageInfo.authorName || `Pixiv #${userId}`;
    try {
      if (!isBookmarks && userId) {
        const userRes = await fetch(`/ajax/user/${userId}?full=1`, { credentials: 'include' });
        if (userRes.ok) {
          const userJson = await userRes.json();
          if (userJson?.body?.name) authorName = String(userJson.body.name).trim();
        }
      }
    } catch {
      // fall back to DOM display name
    }

    const rootName = isBookmarks
      ? pageInfo.suggestedFolderName || 'Pixiv 收藏'
      : buildCreatorRootFolderName('pixiv', userId, authorName);
    batchJob.phase = `正在准备文件夹「${rootName}」…`;
    syncHudAndPush();
    const folderRes = await ext.runtime.sendMessage({ type: 'ENSURE_AUTHOR_ROOT_FOLDER', name: rootName });
    if (!folderRes?.ok || !folderRes.folder?.id) {
      throw new Error(folderRes?.error || `无法创建文件夹「${rootName}」。`);
    }
    const rootFolderId = folderRes.folder.id;
    batchJob.targetLabel = folderRes.targetLabel || rootName;
    syncHudAndPush();

    // Collect ordered artwork IDs from Pixiv's same-origin JSON API
    const workIds = [];
    if (isBookmarks) {
      let offset = 0;
      const limit = 48;
      const tagParam = encodeURIComponent(pageInfo.bookmarkTag || '');
      const restParam = pageInfo.rest === 'hide' ? 'hide' : 'show';
      while (!batchJob.stopRequested) {
        batchJob.phase = `正在读取 Pixiv 收藏列表（已获取 ${workIds.length} 件）…`;
        syncHudAndPush();
        const url = `/ajax/user/${userId}/illusts/bookmarks?tag=${tagParam}&offset=${offset}&limit=${limit}&rest=${restParam}`;
        const res = await fetch(url, { credentials: 'include' });
        if (!res.ok) break;
        const json = await res.json();
        const works = Array.isArray(json?.body?.works) ? json.body.works : [];
        if (works.length === 0) break;
        for (const w of works) {
          const id = String(w?.id || '').trim();
          if (/^\d{1,16}$/.test(id)) workIds.push(id);
        }
        const total = Number(json?.body?.total || 0);
        offset += works.length;
        if (offset >= total || works.length < limit) break;
        if (maxCount > 0 && workIds.length >= maxCount * 2) break;
        await sleep(240);
      }
    } else {
      batchJob.phase = `正在获取画师「${authorName}」的全部作品清单…`;
      syncHudAndPush();
      const res = await fetch(`/ajax/user/${userId}/profile/all`, { credentials: 'include' });
      if (!res.ok) {
        throw new Error('无法读取 Pixiv 画师作品列表，请确认已在当前浏览器登录 Pixiv。');
      }
      const json = await res.json();
      const body = json?.body || {};
      const idSet = new Set();
      const filter = pageInfo.workFilter || 'all';
      if (filter === 'all' || filter === 'illusts') {
        if (body.illusts && typeof body.illusts === 'object') {
          for (const id of Object.keys(body.illusts)) idSet.add(id);
        }
      }
      if (filter === 'all' || filter === 'manga') {
        if (body.manga && typeof body.manga === 'object') {
          for (const id of Object.keys(body.manga)) idSet.add(id);
        }
      }
      workIds.push(
        ...Array.from(idSet)
          .filter((id) => /^\d{1,16}$/.test(id))
          .sort((a, b) => Number(b) - Number(a)),
      );
    }

    if (workIds.length === 0) {
      return { hitKnownBoundary: false };
    }

    let pendingQueue = [];
    let knownStreak = 0;
    let hitKnownBoundary = false;

    for (const illustId of workIds) {
      await waitWhilePaused();
      if (batchJob.stopRequested) break;
      if (maxCount > 0 && batchJob.queued >= maxCount) break;

      const dedupKey = `pixiv:${illustId}`;
      batchJob.discovered += 1;

      if (skipDuplicates && knownKeys.has(dedupKey)) {
        batchJob.skipped += 1;
        knownStreak += 1;
        syncHudAndPush();
        if (stopOnKnownStreak && batchJob.discovered >= 10 && knownStreak >= 8) {
          hitKnownBoundary = true;
          break;
        }
        continue;
      }

      knownStreak = 0;
      knownKeys.add(dedupKey);
      batchJob.queued += 1;

      batchJob.phase = `正在解析 Pixiv 作品 #${illustId} 原图页面…`;
      syncHudAndPush();

      try {
        const illustRes = await fetch(`/ajax/illust/${illustId}`, { credentials: 'include' });
        if (!illustRes.ok) {
          batchJob.failed += 1;
          continue;
        }
        const illustJson = await illustRes.json();
        const illustBody = illustJson?.body;
        if (!illustBody) {
          batchJob.failed += 1;
          continue;
        }

        let pagesBody = null;
        if (Number(illustBody.pageCount || 1) > 1) {
          const pagesRes = await fetch(`/ajax/illust/${illustId}/pages`, { credentials: 'include' });
          if (pagesRes.ok) {
            const pagesJson = await pagesRes.json();
            if (Array.isArray(pagesJson?.body)) pagesBody = pagesJson.body;
          }
        }

        const media = [];
        const seenUrls = new Set();
        if (Array.isArray(pagesBody) && pagesBody.length > 0) {
          for (const p of pagesBody) {
            const orig = upgradeHttps(p?.urls?.original || p?.urls?.regular || '');
            const thumb = upgradeHttps(p?.urls?.regular || p?.urls?.small || orig);
            if (!orig || seenUrls.has(orig)) continue;
            seenUrls.add(orig);
            media.push({ kind: 'photo', url: orig, thumbnailURL: thumb || orig });
          }
        } else {
          const orig = upgradeHttps(illustBody.urls?.original || illustBody.urls?.regular || '');
          const thumb = upgradeHttps(illustBody.urls?.regular || illustBody.urls?.small || orig);
          if (orig) media.push({ kind: 'photo', url: orig, thumbnailURL: thumb || orig });
        }

        if (media.length === 0) continue;

        const dates = formatDateString(illustBody.createDate || illustBody.uploadDate);
        const rawTags = Array.isArray(illustBody.tags?.tags)
          ? illustBody.tags.tags.map((t) => String(t?.tag || '').trim()).filter(Boolean)
          : [];
        const workAuthorName = String(illustBody.userName || authorName).trim();

        pendingQueue.push({
          platform: 'pixiv',
          postID: illustId,
          tweetID: illustId,
          originalURL: `https://www.pixiv.net/artworks/${illustId}`,
          dedupKey,
          authorName: workAuthorName,
          authorHandle: String(illustBody.userId || userId),
          publishedAtText: dates.publishedAtText,
          publishedDateKey: dates.publishedDateKey,
          title: String(illustBody.illustTitle || illustBody.title || '').trim(),
          bodyText: stripHtmlSimple(illustBody.illustComment || illustBody.description || ''),
          isRetweet: false,
          media,
          hasVideo: false,
          needsEnrich: false,
          referer: 'https://www.pixiv.net/',
          tags: Array.from(new Set(['Pixiv', workAuthorName, ...rawTags.slice(0, 12)])),
        });

        if (pendingQueue.length >= 3) {
          const chunk = pendingQueue.splice(0, 3);
          await flushCreatorMediaBatch(chunk, {
            skipDuplicates,
            isFinal: false,
            organizeMode,
            includeVideos,
            effectiveTargetFolderId: rootFolderId,
            platform: 'pixiv',
            authorHandle: userId,
            authorName,
          });
        }
      } catch {
        batchJob.failed += 1;
      }

      await sleep(260);
    }

    while (pendingQueue.length > 0) {
      const chunk = pendingQueue.splice(0, 3);
      await flushCreatorMediaBatch(chunk, {
        skipDuplicates,
        isFinal: pendingQueue.length === 0,
        organizeMode,
        includeVideos,
        effectiveTargetFolderId: rootFolderId,
        platform: 'pixiv',
        authorHandle: userId,
        authorName,
      });
    }

    return { hitKnownBoundary };
  }

  async function runBlueskyDirectApiCollection(pageInfo, runOptions, knownKeys, rootFolderId) {
    const { skipDuplicates, stopOnKnownStreak, maxCount, organizeMode, includeVideos, skipRetweets } = runOptions;
    const actor = String(pageInfo.authorHandle || '').trim();
    if (!actor || pageInfo.pageKind === 'likes') return null;

    let cursor = '';
    let pendingQueue = [];
    let knownStreak = 0;
    let hitKnownBoundary = false;
    let fetchedAnyPage = false;
    const seenKeys = new Set();

    while (!batchJob.stopRequested && !hitKnownBoundary) {
      await waitWhilePaused();
      if (batchJob.stopRequested) break;
      if (maxCount > 0 && batchJob.queued >= maxCount) break;

      const params = new URLSearchParams({
        actor,
        filter: 'posts_with_media',
        limit: '50',
      });
      if (cursor) params.set('cursor', cursor);

      batchJob.phase = `正在通过 Bluesky 接口读取 @${actor} 的媒体贴文…`;
      syncHudAndPush();

      let json;
      try {
        const res = await fetch(`https://public.api.bsky.app/xrpc/app.bsky.feed.getAuthorFeed?${params.toString()}`);
        if (!res.ok) {
          return fetchedAnyPage ? { hitKnownBoundary } : null;
        }
        json = await res.json();
      } catch {
        return fetchedAnyPage ? { hitKnownBoundary } : null;
      }
      fetchedAnyPage = true;

      const feed = Array.isArray(json?.feed) ? json.feed : [];
      if (feed.length === 0) break;

      for (const entry of feed) {
        const post = entry?.post;
        if (!post) continue;
        const rkeyMatch = /\/app\.bsky\.feed\.post\/([a-zA-Z0-9._-]+)$/.exec(String(post.uri || ''));
        const postID = rkeyMatch ? rkeyMatch[1] : '';
        if (!postID) continue;

        const isRepost = Boolean(entry?.reason && String(entry.reason.$type || '').toLowerCase().includes('repost'));
        const authorHandle = String(post.author?.handle || actor).trim().replace(/^@/, '');
        if (skipRetweets && (isRepost || authorHandle.toLowerCase() !== actor.toLowerCase())) {
          continue;
        }

        const embed = post.embed || {};
        const media = [];
        const seen = new Set();
        for (const list of [embed.images, embed.media?.images]) {
          if (!Array.isArray(list)) continue;
          for (const img of list) {
            const full = upgradeHttps(img?.fullsize || img?.thumb || '');
            const thumb = upgradeHttps(img?.thumb || full);
            if (!full || seen.has(full)) continue;
            seen.add(full);
            media.push({ kind: 'photo', url: full, thumbnailURL: thumb || full });
          }
        }
        const videoNode =
          String(embed.$type || '').includes('video')
            ? embed
            : String(embed.media?.$type || '').includes('video')
              ? embed.media
              : null;
        if (videoNode && includeVideos) {
          const url = upgradeHttps(videoNode.playlist || videoNode.thumbnail || '');
          const thumb = upgradeHttps(videoNode.thumbnail || '');
          if (url && !seen.has(url)) {
            seen.add(url);
            media.push({ kind: 'video', url, thumbnailURL: thumb || null });
          }
        }
        if (media.length === 0) continue;

        const dedupKey = `bsky:${authorHandle.toLowerCase()}:${postID}`;
        if (seenKeys.has(dedupKey)) continue;
        seenKeys.add(dedupKey);
        batchJob.discovered += 1;

        if (skipDuplicates && knownKeys.has(dedupKey)) {
          batchJob.skipped += 1;
          knownStreak += 1;
          if (stopOnKnownStreak && batchJob.discovered >= 10 && knownStreak >= 8) {
            hitKnownBoundary = true;
            break;
          }
          continue;
        }

        knownStreak = 0;
        knownKeys.add(dedupKey);
        const dates = formatDateString(post.record?.createdAt || post.indexedAt);
        pendingQueue.push({
          platform: 'bluesky',
          postID,
          tweetID: postID,
          originalURL: `https://bsky.app/profile/${authorHandle}/post/${postID}`,
          dedupKey,
          authorName: String(post.author?.displayName || authorHandle).trim(),
          authorHandle,
          publishedAtText: dates.publishedAtText,
          publishedDateKey: dates.publishedDateKey,
          title: '',
          bodyText: String(post.record?.text || '').trim(),
          isRetweet: isRepost,
          media,
          hasVideo: media.some((m) => m.kind !== 'photo'),
          needsEnrich: false,
          referer: 'https://bsky.app/',
        });
        batchJob.queued += 1;

        if (pendingQueue.length >= 3) {
          const chunk = pendingQueue.splice(0, 3);
          await flushCreatorMediaBatch(chunk, {
            skipDuplicates,
            isFinal: false,
            organizeMode,
            includeVideos,
            effectiveTargetFolderId: rootFolderId,
            platform: 'bluesky',
            authorHandle: actor,
            authorName: readCreatorDisplayName('bluesky', actor) || pageInfo.authorName || actor,
          });
        }
        if (maxCount > 0 && batchJob.queued >= maxCount) break;
      }

      cursor = String(json?.cursor || '').trim();
      if (!cursor) break;
      await sleep(220);
    }

    while (pendingQueue.length > 0) {
      const chunk = pendingQueue.splice(0, 3);
      await flushCreatorMediaBatch(chunk, {
        skipDuplicates,
        isFinal: pendingQueue.length === 0,
        organizeMode,
        includeVideos,
        effectiveTargetFolderId: rootFolderId,
        platform: 'bluesky',
        authorHandle: actor,
        authorName: readCreatorDisplayName('bluesky', actor) || pageInfo.authorName || actor,
      });
    }

    return { hitKnownBoundary };
  }

  async function ensureXiaohongshuCollectTabActive(pageInfo) {
    if (!pageInfo || pageInfo.platform !== 'xiaohongshu' || pageInfo.pageKind !== 'profile') return;

    // Locate the "收藏" tab on Xiaohongshu profile page if not already selected.
    const tabs = Array.from(
      document.querySelectorAll('.reds-tab-item, [class*="tab-item"], [role="tab"], .sub-tab-list span'),
    );
    const collectTab = tabs.find((el) => {
      const text = (el.textContent || '').trim();
      return text === '收藏' || text.startsWith('收藏 ') || /^收藏\d*$/.test(text);
    });
    if (!collectTab) return;

    const alreadyActive =
      collectTab.classList.contains('active') ||
      collectTab.classList.contains('is-active') ||
      collectTab.getAttribute('aria-selected') === 'true';

    if (!alreadyActive) {
      batchJob.phase = '正在自动切换至小红书「收藏」标签页…';
      syncHudAndPush();
      collectTab.click();
      for (let waited = 0; waited < 2400 && !batchJob.stopRequested; waited += 300) {
        await sleep(300);
        if (document.querySelector('section.note-item, .note-item')) break;
      }
    }
  }

  async function enrichXhsNoteInBrowser(cardItem) {
    try {
      const res = await fetch(cardItem.originalURL, {
        credentials: 'include',
        headers: { Accept: 'text/html,application/xhtml+xml' },
      });
      if (!res.ok) return cardItem;
      const html = await res.text();
      if (!html || html.length < 512) return cardItem;
      const enriched = parseXhsNoteStateFromHtml(html, cardItem.originalURL, cardItem);
      if (enriched) {
        const inheritedTags =
          Array.isArray(cardItem.tags) && cardItem.tags.length > 0 ? cardItem.tags : ['小红书收藏'];
        enriched.tags = Array.from(new Set([...(enriched.tags || []), ...inheritedTags]));
        return enriched;
      }
    } catch {
      // Gracefully keep card-level metadata if XHS throttles detail fetch.
    }
    return cardItem;
  }

  function sleep(ms) {
    return new Promise((resolve) => setTimeout(resolve, ms));
  }

  async function waitWhilePaused() {
    while (batchJob.pauseRequested && !batchJob.stopRequested) {
      await sleep(220);
    }
  }

  function hasActivePageLoadingSpinner(platform) {
    if (platform === 'x' || platform === 'threads' || platform === 'instagram' || platform === 'bluesky') {
      return Boolean(document.querySelector('[role="progressbar"], svg[aria-label*="Loading"]'));
    }
    return Boolean(document.querySelector('.reds-loading, .loading-container, [class*="loading"]'));
  }

  function resolveImportPageInfo(options = {}) {
    const detected = detectCurrentCollectionPage();
    if (detected.supported) return detected;

    const host = window.location.hostname.toLowerCase();
    if (isXHost(host)) {
      const pageKind = options.preferredPageKind || 'bookmarks';
      if (pageKind === 'author_media') {
        const handle =
          options.preferredAuthorHandle ||
          window.location.pathname.split('/').filter(Boolean)[0]?.replace(/^@/, '') ||
          '';
        const authorName = readXProfileDisplayName(handle);
        return {
          supported: true,
          isCollectionRoute: true,
          platform: 'x',
          pageKind: 'author_media',
          authorHandle: handle,
          authorName,
          label: options.preferredLabel || `X 作者媒体 · @${handle}`,
          suggestedFolderName: buildAuthorRootFolderName(handle, authorName),
        };
      }
      return {
        supported: true,
        isCollectionRoute: true,
        platform: 'x',
        pageKind,
        label: options.preferredLabel || (pageKind === 'likes' ? 'X 喜欢列表' : 'X 书签收藏页'),
        suggestedFolderName: pageKind === 'likes' ? 'X 喜欢' : 'X 书签',
      };
    }
    if (isXhsHost(host)) {
      const pageKind = options.preferredPageKind || 'collect';
      return {
        supported: true,
        isCollectionRoute: true,
        platform: 'xiaohongshu',
        pageKind,
        label: options.preferredLabel || '小红书收藏页',
        suggestedFolderName: pageKind === 'likes' ? '小红书点赞' : '小红书收藏',
      };
    }
    return detected;
  }

  function findActiveScrollTarget(platform) {
    const docEl = document.scrollingElement || document.documentElement;
    if (docEl && docEl.scrollHeight > window.innerHeight + 80) {
      return window;
    }
    if (platform === 'xiaohongshu') {
      const anchor = document.querySelector('section.note-item, .note-item, #userPostedFeeds, .feeds-container');
      let cur = anchor?.parentElement || null;
      while (cur && cur !== document.body && cur !== document.documentElement) {
        const style = window.getComputedStyle(cur);
        const overflowY = style.overflowY || '';
        if ((overflowY === 'auto' || overflowY === 'scroll') && cur.scrollHeight > cur.clientHeight + 80) {
          return cur;
        }
        cur = cur.parentElement;
      }
    }
    return window;
  }

  function readScrollMetrics(target) {
    if (target === window) {
      const docEl = document.scrollingElement || document.documentElement;
      return {
        scrollTop: window.scrollY || docEl?.scrollTop || 0,
        clientHeight: window.innerHeight,
        scrollHeight: docEl?.scrollHeight || document.body.scrollHeight || 0,
      };
    }
    return {
      scrollTop: target.scrollTop,
      clientHeight: target.clientHeight,
      scrollHeight: target.scrollHeight,
    };
  }

  async function advanceScrollStep(target, stepPx) {
    const before = readScrollMetrics(target).scrollTop;
    if (target === window) {
      window.scrollBy({ top: stepPx, behavior: 'smooth' });
      await sleep(160);
      if (Math.abs(readScrollMetrics(window).scrollTop - before) < 4) {
        window.scrollBy(0, stepPx);
      }
    } else {
      target.scrollBy({ top: stepPx, behavior: 'smooth' });
      await sleep(160);
      if (Math.abs(target.scrollTop - before) < 4) {
        target.scrollTop += stepPx;
      }
    }
  }

  async function fetchExistingSourcesWithRetry() {
    let lastRes = null;
    for (let attempt = 0; attempt < 2; attempt += 1) {
      try {
        const res = await ext.runtime.sendMessage({ type: 'FETCH_EXISTING_SOURCES' });
        if (res && typeof res === 'object') return res;
        lastRes = res;
      } catch (err) {
        if (attempt === 1) throw err;
      }
      await sleep(220);
    }
    return lastRes;
  }

  function shouldRunMediaCollectionMode(pageInfo, options = {}) {
    if (!pageInfo?.supported) return false;
    if (pageInfo.platform === 'pixiv') return true;
    if (pageInfo.platform === 'bluesky' || pageInfo.platform === 'threads' || pageInfo.platform === 'instagram') {
      return true;
    }
    if (pageInfo.platform === 'x' && pageInfo.pageKind === 'author_media') return true;
    if (
      pageInfo.platform === 'xiaohongshu' &&
      pageInfo.pageKind === 'profile' &&
      (options.xhsCollectMode || runtimeState.config?.xhsProfileCollectMode || 'media') === 'media'
    ) {
      return true;
    }
    return false;
  }

  function startBookmarkImport(options = {}) {
    if (batchJob.status === 'running' || batchJob.status === 'paused') {
      showHud();
      return { ok: true, alreadyRunning: true, job: snapshotBatchJob() };
    }

    const pageInfo = resolveImportPageInfo(options);
    if (!pageInfo.supported) {
      return {
        ok: false,
        error: '请先打开 X、Pixiv、Bluesky、Threads、Instagram 或小红书的作者主页或收藏页。',
      };
    }

    const isMediaMode = shouldRunMediaCollectionMode(pageInfo, options);
    const runOptions = {
      skipDuplicates: options.skipDuplicates !== false,
      stopOnKnownStreak: options.stopOnKnownStreak !== false,
      enrichXhsDetails: options.enrichXhsDetails !== false,
      maxCount: Math.max(0, Number(options.maxCount || 0)),
      organizeMode: options.organizeMode || runtimeState.config?.authorMediaOrganizeMode || 'per_tweet',
      includeVideos:
        'includeVideos' in options
          ? options.includeVideos !== false
          : runtimeState.config?.authorMediaIncludeVideos !== false,
      skipRetweets:
        'skipRetweets' in options
          ? options.skipRetweets !== false
          : runtimeState.config?.authorMediaSkipRetweets !== false,
      xhsCollectMode: options.xhsCollectMode || runtimeState.config?.xhsProfileCollectMode || 'media',
      targetFolderId: 'targetFolderId' in options ? options.targetFolderId : undefined,
      targetBoardId: 'targetBoardId' in options ? options.targetBoardId : undefined,
      targetLabel: options.targetLabel || runtimeState.targetLabel || '收件箱',
    };

    Object.assign(batchJob, {
      status: 'running',
      mode: isMediaMode ? 'author_media' : 'bookmarks',
      platform: pageInfo.platform,
      platformLabel: pageInfo.label,
      authorHandle: pageInfo.authorHandle || '',
      phase: '正在连接 Charkle 并检查已导入记录…',
      discovered: 0,
      queued: 0,
      imported: 0,
      mediaImported: 0,
      skipped: 0,
      failed: 0,
      lastItemTitle: '',
      errorMessage: '',
      stopRequested: false,
      pauseRequested: false,
      targetLabel: runOptions.targetLabel,
      startedAt: Date.now(),
    });
    showHud();
    syncHudAndPush();

    // Run autonomously in the background so START_BOOKMARK_IMPORT replies immediately (prevents Safari port timeout).
    void runBookmarkImportLoop(pageInfo, runOptions);
    return { ok: true, job: snapshotBatchJob() };
  }

  async function runBookmarkImportLoop(pageInfo, runOptions) {
    const {
      skipDuplicates,
      stopOnKnownStreak,
      enrichXhsDetails,
      maxCount,
      organizeMode,
      includeVideos,
      skipRetweets,
    } = runOptions;
    let effectiveTargetFolderId = runOptions.targetFolderId;
    const effectiveTargetBoardId = runOptions.targetBoardId;
    const isMediaMode = batchJob.mode === 'author_media';
    const postNoun = SOCIAL_PLATFORM_NOUN[pageInfo.platform] || '作品';

    try {
      // 1. Fetch existing canonical keys for instant incremental dedup
      const knownKeys = new Set();
      if (skipDuplicates) {
        const existingRes = await fetchExistingSourcesWithRetry();
        if (!existingRes?.ok) {
          throw new Error(existingRes?.error || '无法连接 Charkle，请检查扩展设置。');
        }
        if (isMediaMode && Array.isArray(existingRes.mediaCanonicalKeys)) {
          for (const k of existingRes.mediaCanonicalKeys) knownKeys.add(k);
        } else {
          for (const k of existingRes.canonicalKeys || []) knownKeys.add(k);
          for (const s of existingRes.sources || []) knownKeys.add(`url:${String(s).toLowerCase()}`);
        }
      }

      // Dedicated direct-API collector for Pixiv (zero scroll fragility, full multi-page original quality)
      if (pageInfo.platform === 'pixiv') {
        const pixivResult = await runPixivDirectCollection(pageInfo, runOptions, knownKeys, effectiveTargetFolderId);
        finishBatchJobStatus(pageInfo, isMediaMode, Boolean(pixivResult?.hitKnownBoundary));
        return;
      }

      if (pageInfo.platform === 'xiaohongshu' && !isMediaMode) {
        await ensureXiaohongshuCollectTabActive(pageInfo);
      } else if (isMediaMode) {
        if (pageInfo.platform === 'x') {
          await ensureXAuthorMediaTabActive(pageInfo);
        }
        const liveAuthorName = readCreatorDisplayName(pageInfo.platform, pageInfo.authorHandle) || pageInfo.authorName || '';
        const authorFolderName =
          pageInfo.pageKind === 'author_media' || pageInfo.pageKind === 'profile'
            ? buildCreatorRootFolderName(pageInfo.platform, pageInfo.authorHandle, liveAuthorName, pageInfo.suggestedFolderName)
            : pageInfo.suggestedFolderName || `${SOCIAL_PLATFORM_DISPLAY[pageInfo.platform] || '社交'} 收藏`;
        batchJob.phase = `正在准备文件夹「${authorFolderName}」…`;
        syncHudAndPush();
        const folderRes = await ext.runtime.sendMessage({
          type: 'ENSURE_AUTHOR_ROOT_FOLDER',
          name: authorFolderName,
        });
        if (!folderRes?.ok || !folderRes.folder?.id) {
          throw new Error(folderRes?.error || `无法创建文件夹「${authorFolderName}」。`);
        }
        effectiveTargetFolderId = folderRes.folder.id;
        batchJob.targetLabel = folderRes.targetLabel || authorFolderName;
        syncHudAndPush();

        // Try direct public ATProto API on Bluesky author profiles first (fast & cursor-paginated)
        if (pageInfo.platform === 'bluesky' && pageInfo.pageKind === 'author_media') {
          const bskyResult = await runBlueskyDirectApiCollection(pageInfo, runOptions, knownKeys, effectiveTargetFolderId);
          if (bskyResult) {
            finishBatchJobStatus(pageInfo, true, Boolean(bskyResult.hitKnownBoundary));
            return;
          }
        }
      }

      const seenThisRun = new Set();
      let pendingQueue = [];
      let knownStreak = 0;
      let hitKnownBoundary = false;

      const harvestNow = () => {
        const rawList = (() => {
          if (pageInfo.platform === 'x') {
            return isMediaMode
              ? harvestVisibleXAuthorMedia(pageInfo, { includeVideos, skipRetweets })
              : harvestVisibleXTweets(pageInfo.pageKind);
          }
          if (pageInfo.platform === 'bluesky') {
            return harvestVisibleBlueskyMedia(pageInfo, { includeVideos, skipRetweets });
          }
          if (pageInfo.platform === 'threads') {
            return harvestVisibleThreadsMedia(pageInfo, { includeVideos, skipRetweets });
          }
          if (pageInfo.platform === 'instagram') {
            return harvestVisibleInstagramMedia(pageInfo, { includeVideos, skipRetweets });
          }
          if (pageInfo.platform === 'xiaohongshu') {
            return harvestVisibleXhsNotes(pageInfo.pageKind);
          }
          return [];
        })();

        let addedCount = 0;
        for (const item of rawList) {
          const key = item.dedupKey || `url:${item.originalURL.toLowerCase()}`;
          if (seenThisRun.has(key)) continue;
          seenThisRun.add(key);
          batchJob.discovered += 1;
          addedCount += 1;

          if (skipDuplicates && knownKeys.has(key)) {
            batchJob.skipped += 1;
            knownStreak += 1;
            if (stopOnKnownStreak && batchJob.discovered >= 10 && knownStreak >= 8) {
              hitKnownBoundary = true;
              break;
            }
            continue;
          }

          knownStreak = 0;
          knownKeys.add(key);
          pendingQueue.push(item);
          batchJob.queued += 1;

          if (maxCount > 0 && batchJob.queued >= maxCount) {
            break;
          }
        }
        return addedCount;
      };

      const chunkSize = isMediaMode ? 3 : 5;
      const flushChunk = async (isFinal = false) => {
        if (pendingQueue.length === 0) return;
        const batch = pendingQueue.splice(0, isFinal ? pendingQueue.length : chunkSize);

        if (isMediaMode) {
          let preparedBatch = batch;
          if (pageInfo.platform === 'x') {
            preparedBatch = batch.map((tweet) => {
              const latestGql = capturedXTweetsById.get(tweet.tweetID || tweet.postID);
              return latestGql && (!tweet.media?.length || latestGql.media.length >= tweet.media.length)
                ? {
                    ...tweet,
                    ...latestGql,
                    media: includeVideos ? latestGql.media : latestGql.media.filter((m) => m.kind === 'photo'),
                    needsEnrich: false,
                  }
                : tweet;
            });
          } else if (pageInfo.platform === 'xiaohongshu') {
            batchJob.phase = `正在提取小红书笔记原图与视频（本批 ${batch.length} 篇）…`;
            syncHudAndPush();
            const converted = [];
            for (let i = 0; i < batch.length; i += 2) {
              const pair = batch.slice(i, i + 2);
              const enrichedPair = await Promise.all(pair.map((card) => enrichXhsNoteInBrowser(card)));
              for (const note of enrichedPair) {
                const media = (note.attachments || [])
                  .filter((att) => includeVideos || att.kind === 'photo')
                  .map((att) => ({ kind: att.kind || 'photo', url: att.url, thumbnailURL: att.thumbnailURL || att.url }));
                if (media.length === 0) continue;
                converted.push({
                  platform: 'xiaohongshu',
                  postID: note.noteId || note.authorHandle || String(Date.now()),
                  tweetID: note.noteId || note.authorHandle || '',
                  originalURL: note.originalURL,
                  dedupKey: note.dedupKey,
                  authorName: note.authorName || pageInfo.authorName || '小红书用户',
                  authorHandle: note.authorHandle || pageInfo.authorHandle || 'xiaohongshu',
                  publishedAtText: note.publishedAtText || null,
                  publishedDateKey: note.publishedAtText ? note.publishedAtText.slice(0, 10) : '',
                  title: note.articleTitle || '',
                  bodyText: note.bodyText === note.originalURL ? '' : note.bodyText,
                  isRetweet: false,
                  media,
                  hasVideo: Boolean(note.hasVideo),
                  needsEnrich: false,
                  referer: 'https://www.xiaohongshu.com/',
                  tags: Array.isArray(note.tags) ? note.tags : ['小红书'],
                });
              }
              if (i + 2 < batch.length) await sleep(240);
            }
            preparedBatch = converted;
          } else {
            preparedBatch = batch.map((post) => {
              const latest = capturedSocialPostsByKey.get(post.dedupKey);
              return latest && (!post.media?.length || latest.media.length >= post.media.length)
                ? {
                    ...post,
                    ...latest,
                    media: includeVideos ? latest.media : latest.media.filter((m) => m.kind === 'photo'),
                    needsEnrich: false,
                  }
                : post;
            });
          }

          await flushCreatorMediaBatch(preparedBatch, {
            skipDuplicates,
            isFinal,
            organizeMode,
            includeVideos,
            effectiveTargetFolderId,
            platform: pageInfo.platform,
            authorHandle: pageInfo.authorHandle || '',
            authorName: readCreatorDisplayName(pageInfo.platform, pageInfo.authorHandle) || pageInfo.authorName || '',
          });
          return;
        }

        let prepared = batch;
        if (pageInfo.platform === 'xiaohongshu' && enrichXhsDetails) {
          batchJob.phase = `正在提取小红书笔记完整多图与正文（本批 ${batch.length} 条）…`;
          syncHudAndPush();
          prepared = [];
          for (let i = 0; i < batch.length; i += 2) {
            const pair = batch.slice(i, i + 2);
            const enrichedPair = await Promise.all(pair.map((card) => enrichXhsNoteInBrowser(card)));
            prepared.push(...enrichedPair);
            if (i + 2 < batch.length) await sleep(240);
          }
        }

        batchJob.phase = `正在写入 Charkle（${batchJob.targetLabel}）…`;
        syncHudAndPush();

        const msgPayload = {
          type: 'INGEST_SOCIAL_BOOKMARKS_CHUNK',
          bookmarks: prepared,
          skipDuplicates,
          isFinalChunk: isFinal,
          badgeText: String(Math.min(999, batchJob.imported + prepared.length)),
        };
        if (effectiveTargetFolderId !== undefined) msgPayload.targetFolderId = effectiveTargetFolderId;
        if (effectiveTargetBoardId !== undefined) msgPayload.targetBoardId = effectiveTargetBoardId;
        if (runOptions.targetLabel) msgPayload.targetLabel = runOptions.targetLabel;

        try {
          const res = await ext.runtime.sendMessage(msgPayload);
          if (res?.ok) {
            batchJob.imported += Number(res.created || 0);
            batchJob.skipped += Number(res.skipped || 0);
            const lastTitle =
              res.assets?.[res.assets.length - 1]?.title ||
              prepared[prepared.length - 1]?.articleTitle ||
              prepared[prepared.length - 1]?.authorName ||
              '';
            if (lastTitle) batchJob.lastItemTitle = lastTitle;
          } else {
            batchJob.failed += prepared.length;
          }
        } catch {
          batchJob.failed += prepared.length;
        }
        syncHudAndPush();
      };

      const observer = new MutationObserver(() => {
        if (batchJob.status === 'running' && !batchJob.stopRequested && !hitKnownBoundary) {
          harvestNow();
        }
      });
      observer.observe(document.body, { childList: true, subtree: true });

      try {
        batchJob.phase = `正在扫描${pageInfo.label}…`;
        harvestNow();
        for (let initWait = 0; batchJob.discovered === 0 && initWait < 2400 && !batchJob.stopRequested; initWait += 300) {
          await sleep(300);
          harvestNow();
        }
        syncHudAndPush();

        let idleRounds = 0;
        const maxIdleRounds = 6;
        let scrollTarget = findActiveScrollTarget(pageInfo.platform);
        let lastScrollHeight = readScrollMetrics(scrollTarget).scrollHeight;

        while (!batchJob.stopRequested && !hitKnownBoundary) {
          await waitWhilePaused();
          if (batchJob.stopRequested) break;
          if (maxCount > 0 && batchJob.queued >= maxCount) break;

          if (pendingQueue.length >= chunkSize) {
            await flushChunk(false);
            if (batchJob.stopRequested) break;
          }

          batchJob.phase = `正在自动滚动扫描${pageInfo.label}…`;
          syncHudAndPush();

          scrollTarget = findActiveScrollTarget(pageInfo.platform);
          const beforeMetrics = readScrollMetrics(scrollTarget);
          const stepPx = Math.max(460, Math.round(beforeMetrics.clientHeight * 0.76));
          await advanceScrollStep(scrollTarget, stepPx);

          const baseDelay =
            pageInfo.platform === 'xiaohongshu' || pageInfo.platform === 'instagram' ? 920 : 700;
          await sleep(baseDelay);

          let spinnerWait = 0;
          while (hasActivePageLoadingSpinner(pageInfo.platform) && spinnerWait < 2400 && !batchJob.stopRequested) {
            await sleep(400);
            spinnerWait += 400;
          }

          const newlyFound = harvestNow();
          const afterMetrics = readScrollMetrics(scrollTarget);
          const nearBottom =
            afterMetrics.scrollTop + afterMetrics.clientHeight >= afterMetrics.scrollHeight - 40;
          const scrollDidNotMove = Math.abs(afterMetrics.scrollTop - beforeMetrics.scrollTop) < 4;

          if (
            newlyFound === 0 &&
            afterMetrics.scrollHeight === lastScrollHeight &&
            (nearBottom || scrollDidNotMove)
          ) {
            idleRounds += 1;
            if (idleRounds >= maxIdleRounds) break;
            await sleep(450);
          } else {
            idleRounds = 0;
            lastScrollHeight = afterMetrics.scrollHeight;
          }
          syncHudAndPush();
        }
      } finally {
        observer.disconnect();
      }

      while (pendingQueue.length > 0) {
        await flushChunk(pendingQueue.length <= chunkSize);
      }

      finishBatchJobStatus(pageInfo, isMediaMode, hitKnownBoundary);
    } catch (err) {
      batchJob.status = 'error';
      batchJob.errorMessage = err instanceof Error ? err.message : `批量采集${postNoun}失败，请稍后重试。`;
      batchJob.phase = batchJob.errorMessage;
      syncHudAndPush();
    }
  }

  function finishBatchJobStatus(pageInfo, isMediaMode, hitKnownBoundary) {
    const noun = SOCIAL_PLATFORM_NOUN[pageInfo.platform] || '作品';
    const platformName = SOCIAL_PLATFORM_DISPLAY[pageInfo.platform] || '社交';

    if (batchJob.stopRequested) {
      batchJob.status = 'stopped';
      batchJob.phase = isMediaMode
        ? `已停止 · 入库 ${batchJob.mediaImported} 个文件（${batchJob.imported} 条${noun}）`
        : `已停止 · 导入 ${batchJob.imported} 条（跳过 ${batchJob.skipped} 条）`;
    } else if (hitKnownBoundary) {
      batchJob.status = 'done';
      batchJob.phase = isMediaMode
        ? `增量同步完成 · 新增 ${batchJob.mediaImported} 个文件`
        : `增量同步完成 · 新增 ${batchJob.imported} 条`;
    } else if (batchJob.discovered === 0) {
      batchJob.status = 'done';
      batchJob.phase = isMediaMode
        ? `未发现可采集的${platformName}${noun}，请确认已登录并处于作品/媒体页`
        : `未发现可导入的${platformName}收藏，请确认已登录账号`;
    } else {
      batchJob.status = 'done';
      batchJob.phase = isMediaMode
        ? `采集完成 · 入库 ${batchJob.mediaImported} 个文件（${batchJob.imported} 条${noun}，跳过 ${batchJob.skipped} 条）`
        : `扫描完成 · 导入 ${batchJob.imported} 条，跳过 ${batchJob.skipped} 条`;
    }
    syncHudAndPush();
  }

  // MARK: - Drag-to-Collect Listeners

  function upgradeUrl(rawUrl) {
    if (!rawUrl) return '';
    const trimmed = String(rawUrl).trim();
    if (trimmed.startsWith('data:image/')) return trimmed;
    try {
      const u = new URL(trimmed.startsWith('//') ? `https:${trimmed}` : trimmed, window.location.href);
      if (u.protocol !== 'http:' && u.protocol !== 'https:') return '';
      u.hash = '';
      if (u.hostname.endsWith('xhscdn.com') && u.protocol === 'http:') {
        u.protocol = 'https:';
      }
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
      if (target.tagName === 'IMG') return extractImageFromImgElement(target);
      const nestedImg = target.querySelector?.('img');
      if (nestedImg) return extractImageFromImgElement(nestedImg);
      const closestImg = target.closest?.('picture')?.querySelector('img');
      if (closestImg) return extractImageFromImgElement(closestImg);
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
        if (resolved) return { url: resolved, title: document.title };
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
    Promise.resolve(
      ext.runtime.sendMessage({
        type: 'INGEST_IMAGE_URL',
        imageUrl: dropped.url,
        sourcePageUrl: window.location.href,
        title: dropped.title || '',
      }),
    )
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
        showToast({ variant: 'error', message: '收藏失败，请重试' });
      });
  }

  document.addEventListener(
    'dragstart',
    (event) => {
      if (!runtimeState.enableDragDrop || !runtimeState.configured || runtimeState.isOwnOrigin) return;
      const candidate = extractImageFromDragStart(event);
      if (!candidate) return;
      activeDragImage = candidate;
      showDropDock();
    },
    { passive: true },
  );

  document.addEventListener('dragend', () => { if (isDockVisible) hideDropDock(); }, { passive: true });
  window.addEventListener('drop', () => { if (isDockVisible) hideDropDock(); }, { passive: true });
  window.addEventListener('keydown', (e) => { if (e.key === 'Escape' && isDockVisible) hideDropDock(); }, { passive: true });
  window.addEventListener('blur', () => { if (isDockVisible) hideDropDock(); }, { passive: true });

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

    for (const img of document.querySelectorAll('img')) {
      const rect = img.getBoundingClientRect();
      const w = img.naturalWidth || Math.round(rect.width) || 0;
      const h = img.naturalHeight || Math.round(rect.height) || 0;
      if (w > 0 && h > 0 && (w < MIN_DIM || h < MIN_DIM)) continue;

      let bestUrl = '';
      const picture = img.closest('picture');
      if (picture) {
        for (const source of picture.querySelectorAll('source[srcset]')) {
          const best = pickBestSrcset(source.getAttribute('srcset') || '');
          if (best) {
            bestUrl = best;
            break;
          }
        }
      }
      if (!bestUrl && img.getAttribute('srcset')) {
        bestUrl = pickBestSrcset(img.getAttribute('srcset'));
      }
      if (!bestUrl) {
        bestUrl =
          img.currentSrc ||
          img.getAttribute('data-original') ||
          img.getAttribute('data-src') ||
          img.src ||
          '';
      }
      addCandidate(bestUrl, w, h, img.alt || img.title || '', picture ? 'picture' : 'img');
    }

    // CSS background images on prominent containers
    const bgEls = document.querySelectorAll('[style*="background"], section, article, header, figure, a');
    let bgChecked = 0;
    for (const el of bgEls) {
      if (bgChecked >= 240) break;
      bgChecked += 1;
      const rect = el.getBoundingClientRect();
      if (rect.width < MIN_DIM || rect.height < MIN_DIM) continue;
      const bg = window.getComputedStyle(el).backgroundImage;
      if (!bg || bg === 'none' || !bg.includes('url(')) continue;
      const match = /url\(["']?([^"')]+)["']?\)/i.exec(bg);
      if (match && match[1]) {
        addCandidate(match[1], rect.width, rect.height, el.getAttribute('aria-label') || '', 'bg');
      }
    }

    // OpenGraph / Twitter card cover images
    for (const meta of document.querySelectorAll('meta[property="og:image"], meta[name="og:image"], meta[name="twitter:image"]')) {
      const content = meta.getAttribute('content') || '';
      if (content) addCandidate(content, 0, 0, document.title || '', 'og');
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
    const selection = String(window.getSelection?.()?.toString() || '').trim();
    const descMeta =
      document.querySelector('meta[property="og:description"]')?.getAttribute('content') ||
      document.querySelector('meta[name="description"]')?.getAttribute('content') ||
      '';
    const xhsNote = extractCurrentSingleXiaohongshuNote();
    return {
      ok: true,
      url: window.location.href,
      title: xhsNote?.articleTitle || document.title || '',
      description: (xhsNote?.bodyText || descMeta || '').trim().slice(0, 600),
      selection: selection.slice(0, 12000),
      socialBookmark: xhsNote,
      collectionPage: detectCurrentCollectionPage(),
      bookmarkJob: snapshotBatchJob(),
    };
  }

  // MARK: - SPA Route Watcher (active on supported social platforms only so other websites pay zero overhead)

  function setupSpaRouteWatcher() {
    const host = window.location.hostname.toLowerCase();
    const isTrackedHost =
      isXHost(host) ||
      isXhsHost(host) ||
      isBlueskyHost(host) ||
      isPixivHost(host) ||
      isThreadsHost(host) ||
      isInstagramHost(host);
    if (!isTrackedHost) return;

    let lastSignature = `${window.location.href}|${document.title}|${getActiveXTabText()}`;
    const onStateMaybeChanged = () => {
      const nextSignature = `${window.location.href}|${document.title}|${getActiveXTabText()}`;
      if (nextSignature !== lastSignature) {
        lastSignature = nextSignature;
        updateFloatingLauncherVisibility();
      }
    };
    window.addEventListener('popstate', onStateMaybeChanged);
    setInterval(onStateMaybeChanged, 1200);
  }

  // MARK: - Message Listener

  ext.runtime?.onMessage?.addListener((msg, _sender, sendResponse) => {
    if (!msg || typeof msg.type !== 'string') return;

    switch (msg.type) {
      case 'CHARKLE_PING':
        sendResponse({ ok: true });
        return;

      case 'CHARKLE_TOAST':
        showToast({
          variant: msg.variant || 'success',
          message: msg.message || '',
          detail: msg.detail || '',
        });
        sendResponse({ ok: true });
        return;

      case 'GET_PAGE_CONTEXT':
        sendResponse(getPageContext());
        return;

      case 'SCAN_PAGE_IMAGES':
        sendResponse({ ok: true, images: scanPageImages() });
        return;

      case 'GET_BOOKMARK_JOB_STATE':
        sendResponse({
          ok: true,
          collectionPage: detectCurrentCollectionPage(),
          job: snapshotBatchJob(),
        });
        return;

      case 'START_BOOKMARK_IMPORT':
        sendResponse(startBookmarkImport(msg.options || {}));
        return;

      case 'PAUSE_BOOKMARK_IMPORT':
        if (batchJob.status === 'running') {
          batchJob.pauseRequested = true;
          batchJob.status = 'paused';
          batchJob.phase = '已暂停';
          syncHudAndPush();
        }
        sendResponse({ ok: true, job: snapshotBatchJob() });
        return;

      case 'RESUME_BOOKMARK_IMPORT':
        if (batchJob.status === 'paused') {
          batchJob.pauseRequested = false;
          batchJob.status = 'running';
          batchJob.phase = '正在继续扫描并导入…';
          syncHudAndPush();
        }
        sendResponse({ ok: true, job: snapshotBatchJob() });
        return;

      case 'STOP_BOOKMARK_IMPORT':
        if (batchJob.status === 'running' || batchJob.status === 'paused') {
          batchJob.stopRequested = true;
          batchJob.pauseRequested = false;
          batchJob.phase = '正在停止并保存已扫描条目…';
          syncHudAndPush();
        }
        sendResponse({ ok: true, job: snapshotBatchJob() });
        return;
    }
  });

  initXGraphQLBridgeListener();
  initConfigSync();
  setupSpaRouteWatcher();
})();
