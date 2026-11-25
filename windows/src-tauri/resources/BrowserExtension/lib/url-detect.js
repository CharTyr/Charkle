/**
 * Pure URL detection, bookmark collection page detection, canonical deduplication keys,
 * server URL normalization, hex color & filename utilities.
 * Shared across Chrome and Safari extension builds.
 */

import {
  buildCreatorRootFolderName,
  detectBlueskyProfileUrl,
  detectInstagramProfileUrl,
  detectPixivCollectionUrl,
  detectThreadsProfileUrl,
  detectXAuthorProfileUrl,
} from './social-collectors.js';

const X_HOSTS = new Set([
  'x.com',
  'twitter.com',
  'mobile.x.com',
  'mobile.twitter.com',
  'www.x.com',
  'www.twitter.com',
  'fxtwitter.com',
  'www.fxtwitter.com',
  'vxtwitter.com',
  'www.vxtwitter.com',
  'fixupx.com',
  'www.fixupx.com',
  'fixvx.com',
  'www.fixvx.com',
]);

const BSKY_HOSTS = new Set(['bsky.app', 'www.bsky.app']);

const THREADS_HOSTS = new Set([
  'threads.net',
  'www.threads.net',
  'threads.com',
  'www.threads.com',
]);

const XHS_HOSTS = new Set([
  'xiaohongshu.com',
  'www.xiaohongshu.com',
  'm.xiaohongshu.com',
]);

const XHS_SHORT_HOSTS = new Set(['xhslink.com', 'www.xhslink.com']);

const PIXIV_HOSTS = new Set(['pixiv.net', 'www.pixiv.net', 'touch.pixiv.net']);

const INSTAGRAM_HOSTS = new Set(['instagram.com', 'www.instagram.com', 'm.instagram.com']);

const GITHUB_HOSTS = new Set(['github.com', 'www.github.com']);

const GITHUB_RESERVED_OWNERS = new Set([
  'settings',
  'explore',
  'issues',
  'pulls',
  'gist',
  'orgs',
  'marketplace',
  'sponsors',
  'topics',
  'trending',
  'collections',
  'events',
  'notifications',
  'login',
  'signup',
  'join',
  'about',
  'pricing',
  'features',
  'enterprise',
  'team',
  'security',
  'customer-stories',
  'readme',
  'codespaces',
  'copilot',
  'apps',
  'new',
  'search',
  'stars',
  'watching',
  'organizations',
  'users',
]);

const DIRECT_IMAGE_EXTS = new Set([
  'jpg',
  'jpeg',
  'png',
  'webp',
  'gif',
  'apng',
  'avif',
  'bmp',
  'svg',
  'heic',
  'heif',
]);

const MIME_TO_EXT = {
  'image/jpeg': 'jpg',
  'image/jpg': 'jpg',
  'image/png': 'png',
  'image/webp': 'webp',
  'image/gif': 'gif',
  'image/apng': 'apng',
  'image/avif': 'avif',
  'image/svg+xml': 'svg',
  'image/bmp': 'bmp',
  'image/tiff': 'tiff',
  'image/heic': 'heic',
  'image/heif': 'heif',
};

export function isValidXhsNoteId(candidate) {
  return typeof candidate === 'string' && /^[a-zA-Z0-9]{16,40}$/.test(candidate);
}

/**
 * Normalizes a user-supplied Charkle server URL (Desktop loopback or self-hosted Web).
 */
export function normalizeServerUrl(raw) {
  const trimmed = String(raw ?? '').trim();
  if (!trimmed) return '';

  let candidate = trimmed;
  const hasExplicitScheme = /^[a-zA-Z][a-zA-Z0-9+.-]*:\/\//.test(candidate);
  const hasNonHttpColonScheme = /^[a-zA-Z][a-zA-Z0-9+.-]*:(?!\d)/.test(candidate);

  if (!hasExplicitScheme && !hasNonHttpColonScheme) {
    const looksLocal =
      /^(localhost|127\.0\.0\.1|0\.0\.0\.0|\[::1\]|10\.|192\.168\.|172\.(1[6-9]|2\d|3[01])\.)/i.test(
        candidate,
      );
    candidate = `${looksLocal ? 'http' : 'https'}://${candidate}`;
  }

  try {
    const u = new URL(candidate);
    if (u.protocol !== 'http:' && u.protocol !== 'https:') return '';
    if (!u.hostname) return '';
    const pathname = u.pathname.replace(/\/+$/, '');
    return `${u.origin}${pathname}`;
  } catch {
    return '';
  }
}

export function isCapturablePageUrl(rawUrl) {
  try {
    const u = new URL(String(rawUrl ?? '').trim());
    return u.protocol === 'http:' || u.protocol === 'https:';
  } catch {
    return false;
  }
}

export function isSameOriginUrl(urlA, urlB) {
  try {
    const a = new URL(String(urlA ?? '').trim());
    const b = new URL(String(urlB ?? '').trim());
    return a.origin === b.origin;
  } catch {
    return false;
  }
}

/**
 * Classifies a URL into rich Charkle sources (X, Xiaohongshu, Threads, Bluesky, GitHub Repo, or Web Bookmark).
 */
export function detectSpecialSource(rawUrl) {
  let u;
  try {
    u = new URL(String(rawUrl ?? '').trim());
  } catch {
    return {
      kind: 'unknown',
      label: '网页书签',
      badgeText: '网页',
      actionLabel: '收藏当前网页',
      hostname: '',
    };
  }

  if (u.protocol !== 'http:' && u.protocol !== 'https:') {
    return {
      kind: 'unsupported',
      label: '不支持的页面',
      badgeText: '内部页面',
      actionLabel: '无法收藏此页面',
      hostname: u.protocol.replace(/:$/, ''),
    };
  }

  const host = u.hostname.toLowerCase();
  const parts = u.pathname.split('/').filter(Boolean);

  // X / Twitter status
  if (X_HOSTS.has(host)) {
    if (
      parts.length >= 4 &&
      parts[0].toLowerCase() === 'i' &&
      parts[1].toLowerCase() === 'web' &&
      parts[2].toLowerCase() === 'status' &&
      /^\d{1,24}$/.test(parts[3])
    ) {
      return {
        kind: 'x',
        label: 'X 推文',
        badgeText: 'X 推文',
        actionLabel: '收藏 X 推文',
        hostname: 'x.com',
        handle: 'i',
        postID: parts[3],
      };
    }
    if (
      parts.length >= 3 &&
      (parts[1].toLowerCase() === 'status' || parts[1].toLowerCase() === 'statuses') &&
      /^\d{1,24}$/.test(parts[2])
    ) {
      return {
        kind: 'x',
        label: 'X 推文',
        badgeText: 'X 推文',
        actionLabel: '收藏 X 推文',
        hostname: 'x.com',
        handle: parts[0].replace(/^@/, ''),
        postID: parts[2],
      };
    }
  }

  // Xiaohongshu note or short share link
  if (XHS_SHORT_HOSTS.has(host) && parts.length >= 1) {
    return {
      kind: 'xiaohongshu',
      label: '小红书笔记',
      badgeText: '小红书笔记',
      actionLabel: '收藏小红书笔记',
      hostname: 'xhslink.com',
      postID: parts.join('/'),
    };
  }
  if (XHS_HOSTS.has(host)) {
    let noteID = null;
    if (parts.length >= 2 && parts[0].toLowerCase() === 'explore' && isValidXhsNoteId(parts[1])) {
      noteID = parts[1];
    } else if (
      parts.length >= 3 &&
      parts[0].toLowerCase() === 'discovery' &&
      parts[1].toLowerCase() === 'item' &&
      isValidXhsNoteId(parts[2])
    ) {
      noteID = parts[2];
    } else if (
      parts.length >= 4 &&
      parts[0].toLowerCase() === 'user' &&
      parts[1].toLowerCase() === 'profile' &&
      isValidXhsNoteId(parts[3])
    ) {
      noteID = parts[3];
    }
    if (noteID) {
      return {
        kind: 'xiaohongshu',
        label: '小红书笔记',
        badgeText: '小红书笔记',
        actionLabel: '收藏小红书笔记',
        hostname: 'xiaohongshu.com',
        postID: noteID,
      };
    }
  }

  // Bluesky post
  if (BSKY_HOSTS.has(host)) {
    if (parts.length >= 4 && parts[0] === 'profile' && parts[2] === 'post') {
      return {
        kind: 'bluesky',
        label: 'Bluesky 贴文',
        badgeText: 'Bluesky',
        actionLabel: '收藏 Bluesky 贴文',
        hostname: 'bsky.app',
        handle: parts[1].replace(/^@/, ''),
        postID: parts[3],
      };
    }
  }

  // Threads post
  if (THREADS_HOSTS.has(host)) {
    if (parts.length >= 3 && parts[0].startsWith('@') && parts[1] === 'post') {
      return {
        kind: 'threads',
        label: 'Threads 贴文',
        badgeText: 'Threads',
        actionLabel: '收藏 Threads 贴文',
        hostname: 'threads.net',
        handle: parts[0].slice(1),
        postID: parts[2],
      };
    }
    if (parts.length >= 2 && parts[0] === 't') {
      return {
        kind: 'threads',
        label: 'Threads 贴文',
        badgeText: 'Threads',
        actionLabel: '收藏 Threads 贴文',
        hostname: 'threads.net',
        handle: 'threads',
        postID: parts[1],
      };
    }
  }

  // Pixiv artwork
  if (PIXIV_HOSTS.has(host)) {
    const artIdx = parts.findIndex((seg) => seg.toLowerCase() === 'artworks');
    if (artIdx >= 0 && parts[artIdx + 1] && /^\d{1,16}$/.test(parts[artIdx + 1])) {
      return {
        kind: 'pixiv',
        label: 'Pixiv 作品',
        badgeText: 'Pixiv 作品',
        actionLabel: '收藏 Pixiv 作品',
        hostname: 'pixiv.net',
        postID: parts[artIdx + 1],
      };
    }
    if (parts[0]?.toLowerCase() === 'member_illust.php') {
      const id = (u.searchParams.get('illust_id') || '').trim();
      if (/^\d{1,16}$/.test(id)) {
        return {
          kind: 'pixiv',
          label: 'Pixiv 作品',
          badgeText: 'Pixiv 作品',
          actionLabel: '收藏 Pixiv 作品',
          hostname: 'pixiv.net',
          postID: id,
        };
      }
    }
  }

  // Instagram post / reel
  if (INSTAGRAM_HOSTS.has(host)) {
    const igIdx = parts.findIndex((seg) => ['p', 'reel', 'reels', 'tv'].includes(seg.toLowerCase()));
    if (igIdx >= 0 && parts[igIdx + 1] && /^[a-zA-Z0-9_-]{4,40}$/.test(parts[igIdx + 1])) {
      return {
        kind: 'instagram',
        label: 'Instagram 贴文',
        badgeText: 'Instagram',
        actionLabel: '收藏 Instagram 贴文',
        hostname: 'instagram.com',
        postID: parts[igIdx + 1],
      };
    }
  }

  // GitHub repository
  if (GITHUB_HOSTS.has(host) && parts.length >= 2) {
    const owner = parts[0];
    const repo = parts[1].replace(/\.git$/i, '');
    const isValidRepoPath =
      parts.length === 2 || (parts.length >= 4 && parts[2].toLowerCase() === 'tree');
    if (
      !GITHUB_RESERVED_OWNERS.has(owner.toLowerCase()) &&
      repo &&
      !repo.startsWith('.') &&
      isValidRepoPath
    ) {
      return {
        kind: 'github',
        label: 'GitHub 仓库',
        badgeText: 'GitHub 仓库',
        actionLabel: '收藏 GitHub 仓库',
        hostname: 'github.com',
        owner,
        repo,
      };
    }
  }

  return {
    kind: 'web',
    label: '网页书签',
    badgeText: '网页书签',
    actionLabel: '收藏当前网页',
    hostname: host.replace(/^www\./, ''),
  };
}

/**
 * Detects whether the active page is a supported X Bookmarks / History / Likes or Xiaohongshu Collection / Board page
 * eligible for one-click batch bookmark import.
 */
export function detectBookmarkCollectionPage(rawUrl) {
  let u;
  try {
    u = new URL(String(rawUrl ?? '').trim());
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
  if (u.protocol !== 'http:' && u.protocol !== 'https:') {
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

  if (X_HOSTS.has(host)) {
    // Classic & folder bookmarks: /i/bookmarks, /i/bookmarks/all, /i/bookmarks/<folderId>
    if (parts.length >= 2 && p0 === 'i' && p1 === 'bookmarks') {
      const folderId = parts[2] && p2 !== 'all' ? parts[2] : null;
      return {
        supported: true,
        isCollectionRoute: true,
        platform: 'x',
        pageKind: folderId ? 'bookmark_folder' : 'bookmarks',
        label: folderId ? 'X 书签文件夹' : 'X 书签收藏页',
        suggestedFolderName: 'X 书签',
      };
    }
    // X 2026 unified History hub (Bookmarks / Likes / Videos / Articles): /i/history*
    if (parts.length >= 2 && p0 === 'i' && p1 === 'history') {
      if (p2 === 'likes') {
        return {
          supported: true,
          isCollectionRoute: true,
          platform: 'x',
          pageKind: 'likes',
          label: 'X 历史 · 喜欢',
          suggestedFolderName: 'X 喜欢',
        };
      }
      if (p2 === 'bookmarks' || !p2) {
        return {
          supported: true,
          isCollectionRoute: true,
          platform: 'x',
          pageKind: p2 === 'bookmarks' ? 'bookmarks' : 'history',
          label: p2 === 'bookmarks' ? 'X 书签收藏页' : 'X 历史 · 书签',
          suggestedFolderName: 'X 书签',
        };
      }
      return {
        supported: true,
        isCollectionRoute: true,
        platform: 'x',
        pageKind: 'history',
        label: 'X 历史列表',
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
        pageKind: 'history',
        label: 'X 历史 · 书签',
        suggestedFolderName: 'X 书签',
      };
    }
    // Lists: /i/lists/<listId>
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
    const authorProfile = detectXAuthorProfileUrl(u.href);
    if (authorProfile) {
      return {
        supported: true,
        isCollectionRoute: true,
        platform: 'x',
        pageKind: 'author_media',
        authorHandle: authorProfile.handle,
        isMediaTab: authorProfile.isMediaTab,
        label: `X 作者媒体 · @${authorProfile.handle}`,
        suggestedFolderName: `@${authorProfile.handle}`,
      };
    }
  }

  if (XHS_HOSTS.has(host)) {
    // Profile pages: /user/profile/<uid> (with optional ?tab=collect|like or non-note sub-route)
    if (
      parts.length >= 3 &&
      p0 === 'user' &&
      p1 === 'profile' &&
      !(parts.length >= 4 && isValidXhsNoteId(parts[3]))
    ) {
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
      return {
        supported: true,
        isCollectionRoute: true,
        platform: 'xiaohongshu',
        pageKind: 'profile',
        label: '小红书个人主页（自动切至收藏）',
        suggestedFolderName: '小红书收藏',
      };
    }
    if (
      parts.length >= 1 &&
      (p0 === 'board' || p0 === 'collection' || p0 === 'collections' || p0 === 'collect')
    ) {
      return {
        supported: true,
        isCollectionRoute: true,
        platform: 'xiaohongshu',
        pageKind: 'board',
        label: '小红书收藏专辑',
        suggestedFolderName: '小红书收藏',
      };
    }
  }

  // Bluesky author profile / media / likes
  const bskyProfile = detectBlueskyProfileUrl(u.href);
  if (bskyProfile) {
    return {
      supported: true,
      isCollectionRoute: true,
      platform: 'bluesky',
      pageKind: bskyProfile.pageKind,
      authorHandle: bskyProfile.handle,
      isMediaTab: bskyProfile.isMediaTab,
      label: bskyProfile.isLikes
        ? `Bluesky 喜欢 · @${bskyProfile.handle}`
        : `Bluesky 作者媒体 · @${bskyProfile.handle}`,
      suggestedFolderName: bskyProfile.isLikes
        ? 'Bluesky 喜欢'
        : buildCreatorRootFolderName('bluesky', bskyProfile.handle),
    };
  }

  // Pixiv artist works & bookmarks
  const pixivPage = detectPixivCollectionUrl(u.href);
  if (pixivPage) {
    const isBookmarks = pixivPage.pageKind === 'bookmarks';
    const filterLabel =
      pixivPage.workFilter === 'illusts'
        ? '插画'
        : pixivPage.workFilter === 'manga'
          ? '漫画'
          : '全部作品';
    return {
      supported: true,
      isCollectionRoute: true,
      platform: 'pixiv',
      pageKind: pixivPage.pageKind,
      authorHandle: pixivPage.userId,
      workFilter: pixivPage.workFilter,
      bookmarkTag: pixivPage.bookmarkTag,
      rest: pixivPage.rest,
      label: isBookmarks
        ? pixivPage.bookmarkTag
          ? `Pixiv 收藏 · #${pixivPage.bookmarkTag}`
          : 'Pixiv 收藏作品'
        : `Pixiv 画师${filterLabel}`,
      suggestedFolderName: isBookmarks
        ? pixivPage.bookmarkTag
          ? `Pixiv 收藏 · ${pixivPage.bookmarkTag}`
          : 'Pixiv 收藏'
        : `Pixiv #${pixivPage.userId}`,
    };
  }

  // Threads author profile / saved / liked
  const threadsPage = detectThreadsProfileUrl(u.href);
  if (threadsPage) {
    const isAuthor = threadsPage.pageKind === 'author_media';
    return {
      supported: true,
      isCollectionRoute: true,
      platform: 'threads',
      pageKind: threadsPage.pageKind,
      authorHandle: threadsPage.handle,
      isMediaTab: Boolean(threadsPage.isMediaTab),
      label: isAuthor
        ? `Threads 作者媒体 · @${threadsPage.handle}`
        : threadsPage.pageKind === 'likes'
          ? 'Threads 喜欢列表'
          : 'Threads 已保存列表',
      suggestedFolderName: isAuthor
        ? buildCreatorRootFolderName('threads', threadsPage.handle)
        : threadsPage.pageKind === 'likes'
          ? 'Threads 喜欢'
          : 'Threads 收藏',
    };
  }

  // Instagram author profile / reels / saved
  const igPage = detectInstagramProfileUrl(u.href);
  if (igPage) {
    const isAuthor = igPage.pageKind === 'author_media';
    return {
      supported: true,
      isCollectionRoute: true,
      platform: 'instagram',
      pageKind: igPage.pageKind,
      authorHandle: igPage.handle,
      label: isAuthor
        ? `Instagram 作者媒体 · @${igPage.handle}`
        : `Instagram 收藏 · @${igPage.handle}`,
      suggestedFolderName: isAuthor
        ? buildCreatorRootFolderName('instagram', igPage.handle)
        : 'Instagram 收藏',
    };
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

/**
 * Computes a stable canonical deduplication key matching Charkle macOS `SocialPostResolver.canonicalDedupKey`.
 */
export function canonicalDedupKey(rawUrl) {
  const trimmed = String(rawUrl ?? '').trim();
  if (!trimmed) return null;
  const info = detectSpecialSource(trimmed);
  if (info.kind === 'x' && info.postID) {
    return `x:${info.postID}`;
  }
  if (info.kind === 'xiaohongshu' && info.postID && info.hostname === 'xiaohongshu.com') {
    return `xhs:${info.postID.toLowerCase()}`;
  }
  if (info.kind === 'threads' && info.postID) {
    return `threads:${info.postID}`;
  }
  if (info.kind === 'bluesky' && info.handle && info.postID) {
    return `bsky:${info.handle.toLowerCase()}:${info.postID}`;
  }
  if (info.kind === 'pixiv' && info.postID) {
    return `pixiv:${info.postID}`;
  }
  if (info.kind === 'instagram' && info.postID) {
    return `ig:${info.postID}`;
  }
  return `url:${trimmed.toLowerCase()}`;
}

export function isDirectImageUrl(rawUrl) {
  if (!rawUrl) return false;
  if (String(rawUrl).startsWith('data:image/')) return true;
  try {
    const u = new URL(String(rawUrl).trim());
    if (u.protocol !== 'http:' && u.protocol !== 'https:') return false;
    const pathname = u.pathname.toLowerCase();
    const dot = pathname.lastIndexOf('.');
    if (dot >= 0) {
      const ext = pathname.slice(dot + 1);
      if (DIRECT_IMAGE_EXTS.has(ext)) return true;
    }
    const formatParam = (u.searchParams.get('format') || '').toLowerCase();
    if (DIRECT_IMAGE_EXTS.has(formatParam)) return true;
    return false;
  } catch {
    return false;
  }
}

export function normalizeHexColor(raw) {
  const cleaned = String(raw ?? '')
    .trim()
    .replace(/^#/, '');
  if (/^[0-9a-fA-F]{3}$/.test(cleaned)) {
    const expanded = cleaned
      .split('')
      .map((ch) => ch + ch)
      .join('')
      .toUpperCase();
    return `#${expanded}`;
  }
  if (/^[0-9a-fA-F]{6}$/.test(cleaned)) {
    return `#${cleaned.toUpperCase()}`;
  }
  return null;
}

export function isLightHex(hex) {
  const normalized = normalizeHexColor(hex);
  if (!normalized) return false;
  const r = Number.parseInt(normalized.slice(1, 3), 16);
  const g = Number.parseInt(normalized.slice(3, 5), 16);
  const b = Number.parseInt(normalized.slice(5, 7), 16);
  const luminance = (0.299 * r + 0.587 * g + 0.114 * b) / 255;
  return luminance > 0.62;
}

export function extensionFromMime(mimeType) {
  const clean = String(mimeType ?? '')
    .split(';')[0]
    .trim()
    .toLowerCase();
  return MIME_TO_EXT[clean] || '';
}

export function sanitizeBaseName(raw, fallback = 'charkle-image') {
  const cleaned = String(raw ?? '')
    .trim()
    .replace(/[\\/:*?"<>|\x00-\x1f]/g, '_')
    .replace(/\s+/g, ' ')
    .replace(/^\.+/, '')
    .trim();
  return cleaned ? cleaned.slice(0, 120) : fallback;
}

export function deriveImageFileName(imageUrl, preferredTitle = '', mimeType = '') {
  let urlBase = '';
  let urlExt = '';

  if (imageUrl && !String(imageUrl).startsWith('data:')) {
    try {
      const u = new URL(imageUrl);
      const segments = u.pathname.split('/').filter(Boolean);
      const last = segments.length > 0 ? decodeURIComponent(segments[segments.length - 1]) : '';
      const dot = last.lastIndexOf('.');
      if (dot > 0) {
        const candidateExt = last.slice(dot + 1).toLowerCase();
        if (DIRECT_IMAGE_EXTS.has(candidateExt)) {
          urlExt = candidateExt === 'jpeg' ? 'jpg' : candidateExt;
          urlBase = last.slice(0, dot);
        } else {
          urlBase = last;
        }
      } else {
        urlBase = last;
      }
      if (!urlExt) {
        const formatParam = (u.searchParams.get('format') || '').toLowerCase();
        if (DIRECT_IMAGE_EXTS.has(formatParam)) {
          urlExt = formatParam === 'jpeg' ? 'jpg' : formatParam;
        }
      }
    } catch {
      // ignore invalid URL
    }
  }

  const mimeExt = extensionFromMime(mimeType);
  const ext = mimeExt || urlExt || 'png';
  const strippedTitle = String(preferredTitle ?? '')
    .trim()
    .replace(/\.(jpe?g|png|webp|gif|apng|avif|svg|bmp)$/i, '');
  const base = sanitizeBaseName(strippedTitle || urlBase, 'charkle-image');
  return `${base}.${ext}`;
}
