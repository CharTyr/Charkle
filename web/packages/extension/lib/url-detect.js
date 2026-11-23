/**
 * Pure URL detection, server URL normalization, hex color & filename utilities.
 * Mirrors packages/server/src/media/resolvers/{social,github}.ts so UI badges
 * match the server's rich-asset classification 1:1.
 */

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

/**
 * Normalizes a user-supplied Charkle Web server URL.
 * Returns normalized origin/base URL without trailing slash, or empty string if invalid.
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
 * Classifies a URL into rich Charkle sources (X, Threads, Bluesky, GitHub Repo, or Web Bookmark).
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
