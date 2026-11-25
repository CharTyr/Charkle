/**
 * Pure, DOM-free multi-platform social media collector utilities for Charkle Extension.
 *
 * Covers 6 visual/illustration social platforms:
 * - X / Twitter (`x.com`, `twitter.com`)
 * - Bluesky (`bsky.app`)
 * - Pixiv (`pixiv.net`)
 * - Threads (`threads.net`, `threads.com`)
 * - Instagram (`instagram.com`)
 * - Xiaohongshu (`xiaohongshu.com`)
 */

export {
  buildAuthorRootFolderName,
  buildTweetSubfolderName,
  detectXAuthorProfileUrl,
  extractTweetsFromXGraphQLPayload,
  filterAuthorMediaTweet,
  formatTwitterDate,
  isValidXHandle,
  pickBestTwitterVideoVariant,
  resolveTweetOrganizationFolderName,
  upgradeTwitterMediaUrl,
} from './x-author-media.js';

const BSKY_HOSTS = new Set(['bsky.app', 'www.bsky.app']);
const PIXIV_HOSTS = new Set(['pixiv.net', 'www.pixiv.net', 'touch.pixiv.net']);
const THREADS_HOSTS = new Set(['threads.net', 'www.threads.net', 'threads.com', 'www.threads.com']);
const INSTAGRAM_HOSTS = new Set(['instagram.com', 'www.instagram.com', 'm.instagram.com']);

const INSTAGRAM_RESERVED_TOP = new Set([
  'explore',
  'reels',
  'reel',
  'p',
  'tv',
  'direct',
  'accounts',
  'stories',
  'about',
  'developer',
  'developers',
  'legal',
  'api',
  'static',
  'challenge',
  'session',
  'create',
  'nametag',
  'your_activity',
  'emails',
  'privacy',
  'terms',
  'web',
  'graphql',
  'oauth',
  'lite',
  'download',
  'directory',
  'press',
  'blog',
]);

const THREADS_RESERVED_TOP = new Set([
  't',
  'search',
  'activity',
  'settings',
  'login',
  'signup',
  'saved',
  'liked',
  'following',
  'for_you',
  'privacy',
  'terms',
  'about',
  'download',
  'api',
]);

function upgradeHttpsUrl(raw) {
  const trimmed = String(raw ?? '').trim();
  if (!trimmed) return '';
  let candidate = trimmed;
  if (candidate.startsWith('//')) candidate = `https:${candidate}`;
  else if (/^http:\/\//i.test(candidate)) candidate = `https://${candidate.slice(7)}`;
  try {
    const u = new URL(candidate);
    if (u.protocol !== 'http:' && u.protocol !== 'https:') return '';
    return u.href;
  } catch {
    return '';
  }
}

export function formatIsoOrEpochDate(raw) {
  if (raw === null || raw === undefined || raw === '') {
    return { publishedAtText: null, publishedDateKey: '' };
  }
  let d;
  if (typeof raw === 'number' && Number.isFinite(raw)) {
    const ms = raw > 10_000_000_000 ? raw : raw * 1000;
    d = new Date(ms);
  } else {
    d = new Date(String(raw));
  }
  if (Number.isNaN(d.getTime())) {
    return { publishedAtText: null, publishedDateKey: '' };
  }
  const pad = (n) => String(n).padStart(2, '0');
  const y = d.getFullYear();
  const m = pad(d.getMonth() + 1);
  const day = pad(d.getDate());
  const hh = pad(d.getHours());
  const mm = pad(d.getMinutes());
  return {
    publishedAtText: `${y}-${m}-${day} ${hh}:${mm}`,
    publishedDateKey: `${y}-${m}-${day}`,
  };
}

function sanitizeSegment(raw, maxLen = 64) {
  return String(raw ?? '')
    .replace(/https?:\/\/t\.co\/\S+/gi, '')
    .replace(/<[^>]+>/g, ' ')
    .replace(/[\r\n\t]+/g, ' ')
    .replace(/[\\/:*?"<>|\x00-\x1f]/g, ' ')
    .replace(/\s+/g, ' ')
    .replace(/^\.+/, '')
    .trim()
    .slice(0, maxLen)
    .trim();
}

function stripHtmlToPlainText(raw) {
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

// MARK: - Route Detectors (Bluesky, Pixiv, Threads, Instagram)

/**
 * Detects Bluesky author profiles & media/likes tabs:
 * - `https://bsky.app/profile/<handle>`
 * - `https://bsky.app/profile/<handle>/media`
 * - `https://bsky.app/profile/<handle>/videos`
 * - `https://bsky.app/profile/<handle>/likes`
 * Rejects single posts (`/profile/<handle>/post/<rkey>`).
 */
export function detectBlueskyProfileUrl(rawUrl) {
  let u;
  try {
    u = new URL(String(rawUrl ?? '').trim());
  } catch {
    return null;
  }
  if (u.protocol !== 'http:' && u.protocol !== 'https:') return null;
  if (!BSKY_HOSTS.has(u.hostname.toLowerCase())) return null;

  const parts = u.pathname.split('/').filter(Boolean);
  if (parts.length < 2 || parts[0].toLowerCase() !== 'profile') return null;

  const handle = decodeURIComponent(parts[1]).replace(/^@/, '').trim();
  if (!handle || handle.length > 128) return null;

  const sub = (parts[2] || '').toLowerCase();
  if (sub === 'post' || sub === 'feed' || sub === 'lists' || sub === 'follows' || sub === 'followers') {
    return null;
  }
  if (parts.length > 3) return null;

  const allowedTabs = new Set(['', 'media', 'videos', 'posts', 'likes']);
  if (!allowedTabs.has(sub)) return null;

  return {
    platform: 'bluesky',
    handle,
    tab: sub || 'posts',
    isLikes: sub === 'likes',
    isMediaTab: sub === 'media' || sub === 'videos',
    pageKind: sub === 'likes' ? 'likes' : 'author_media',
    canonicalProfileUrl: `https://bsky.app/profile/${handle}`,
    canonicalMediaUrl: `https://bsky.app/profile/${handle}/media`,
  };
}

/**
 * Detects Pixiv artist profile/works/bookmarks pages (with optional locale prefix like `/en/`):
 * - `/users/<id>`, `/users/<id>/artworks`, `/users/<id>/illustrations`, `/users/<id>/manga`
 * - `/users/<id>/bookmarks/artworks` (optional `/<tag>`, optional `?rest=hide`)
 */
export function detectPixivCollectionUrl(rawUrl) {
  let u;
  try {
    u = new URL(String(rawUrl ?? '').trim());
  } catch {
    return null;
  }
  if (u.protocol !== 'http:' && u.protocol !== 'https:') return null;
  if (!PIXIV_HOSTS.has(u.hostname.toLowerCase())) return null;

  const rawParts = u.pathname.split('/').filter(Boolean);
  if (rawParts.length === 0) return null;

  // Strip optional Pixiv locale prefix (`/en/`, `/ja/`, `/zh/`, `/ko/`, `/zh-tw/`)
  let idx = 0;
  if (/^[a-z]{2}(?:-[a-z]{2})?$/i.test(rawParts[0]) && rawParts[1]?.toLowerCase() === 'users') {
    idx = 1;
  }

  if (rawParts[idx]?.toLowerCase() !== 'users') return null;
  const userId = String(rawParts[idx + 1] || '').trim();
  if (!/^\d{1,16}$/.test(userId)) return null;

  const sub1 = (rawParts[idx + 2] || '').toLowerCase();
  const sub2 = (rawParts[idx + 3] || '').toLowerCase();

  if (sub1 === 'bookmarks') {
    // Only artwork bookmarks (skip novel bookmarks)
    if (sub2 && sub2 !== 'artworks') return null;
    const rawTag = rawParts[idx + 4] ? decodeURIComponent(rawParts[idx + 4]) : '';
    const rest = (u.searchParams.get('rest') || 'show').toLowerCase() === 'hide' ? 'hide' : 'show';
    return {
      platform: 'pixiv',
      userId,
      pageKind: 'bookmarks',
      workFilter: 'bookmarks',
      bookmarkTag: rawTag,
      rest,
      canonicalUrl: `https://www.pixiv.net/users/${userId}/bookmarks/artworks`,
    };
  }

  if (sub1 === 'novels' || sub1 === 'following' || sub1 === 'mypixiv' || sub1 === 'request') {
    return null;
  }

  let workFilter = 'all';
  if (sub1 === 'illustrations') workFilter = 'illusts';
  else if (sub1 === 'manga') workFilter = 'manga';
  else if (sub1 && sub1 !== 'artworks') return null;

  return {
    platform: 'pixiv',
    userId,
    pageKind: 'author_media',
    workFilter,
    bookmarkTag: '',
    rest: 'show',
    canonicalUrl: `https://www.pixiv.net/users/${userId}/artworks`,
  };
}

/**
 * Detects Threads author profile & saved/liked pages on `threads.net` and `threads.com`:
 * - `/@<handle>`, `/@<handle>/media`, `/@<handle>/replies`, `/@<handle>/reposts`
 * - `/saved`, `/liked`
 * Rejects single post routes (`/@<handle>/post/<code>`).
 */
export function detectThreadsProfileUrl(rawUrl) {
  let u;
  try {
    u = new URL(String(rawUrl ?? '').trim());
  } catch {
    return null;
  }
  if (u.protocol !== 'http:' && u.protocol !== 'https:') return null;
  if (!THREADS_HOSTS.has(u.hostname.toLowerCase())) return null;

  const parts = u.pathname.split('/').filter(Boolean);
  if (parts.length === 0) return null;

  const p0 = parts[0].toLowerCase();
  if ((p0 === 'saved' || p0 === 'liked') && parts.length === 1) {
    return {
      platform: 'threads',
      handle: '',
      tab: p0,
      pageKind: p0 === 'liked' ? 'likes' : 'bookmarks',
      canonicalUrl: `${u.origin}/${p0}`,
    };
  }

  if (!parts[0].startsWith('@') || parts.length > 2) return null;
  const handle = parts[0].slice(1).trim();
  if (!handle || THREADS_RESERVED_TOP.has(handle.toLowerCase()) || !/^[a-zA-Z0-9._]{1,40}$/.test(handle)) {
    return null;
  }

  const sub = (parts[1] || '').toLowerCase();
  if (sub && !['media', 'replies', 'reposts'].includes(sub)) return null;

  return {
    platform: 'threads',
    handle,
    tab: sub || 'posts',
    isMediaTab: sub === 'media',
    pageKind: 'author_media',
    canonicalUrl: `${u.origin}/@${handle}`,
  };
}

/**
 * Detects Instagram author profile / reels / tagged / saved pages:
 * - `/<username>/`, `/<username>/reels/`, `/<username>/tagged/`
 * - `/<username>/saved/` and `/<username>/saved/<collection>/<id>/`
 * Rejects single post/reel routes (`/p/<code>`, `/reel/<code>`, `/<user>/p/<code>`).
 */
export function detectInstagramProfileUrl(rawUrl) {
  let u;
  try {
    u = new URL(String(rawUrl ?? '').trim());
  } catch {
    return null;
  }
  if (u.protocol !== 'http:' && u.protocol !== 'https:') return null;
  if (!INSTAGRAM_HOSTS.has(u.hostname.toLowerCase())) return null;

  const parts = u.pathname.split('/').filter(Boolean);
  if (parts.length === 0) return null;

  const first = parts[0].replace(/^@/, '').trim();
  if (!first || INSTAGRAM_RESERVED_TOP.has(first.toLowerCase())) return null;
  if (!/^[a-zA-Z0-9._]{1,40}$/.test(first)) return null;

  const sub = (parts[1] || '').toLowerCase();
  if (sub === 'p' || sub === 'reel' || sub === 'tv' || sub === 'followers' || sub === 'following') {
    return null;
  }

  if (sub === 'saved') {
    return {
      platform: 'instagram',
      handle: first,
      tab: 'saved',
      pageKind: 'bookmarks',
      canonicalUrl: `https://www.instagram.com/${first}/saved/`,
    };
  }

  if (parts.length > 2) return null;
  if (sub && !['reels', 'tagged', 'channel'].includes(sub)) return null;

  return {
    platform: 'instagram',
    handle: first,
    tab: sub || 'posts',
    pageKind: 'author_media',
    canonicalUrl: `https://www.instagram.com/${first}/`,
  };
}

// MARK: - Payload Extractors (Bluesky, Pixiv, Threads, Instagram)

/**
 * Extracts media-bearing posts from Bluesky ATProto `getAuthorFeed` / `getActorLikes` responses.
 */
export function extractPostsFromBlueskyFeedPayload(payload) {
  const feed = Array.isArray(payload?.feed) ? payload.feed : [];
  const byKey = new Map();

  for (const entry of feed) {
    const post = entry?.post;
    if (!post || typeof post !== 'object') continue;
    const uri = String(post.uri || '');
    const rkeyMatch = /\/app\.bsky\.feed\.post\/([a-zA-Z0-9._-]+)$/.exec(uri);
    const postID = rkeyMatch ? rkeyMatch[1] : '';
    if (!postID) continue;

    const authorHandle = String(post.author?.handle || post.author?.did || '').trim().replace(/^@/, '');
    const authorName = String(post.author?.displayName || authorHandle || 'Bluesky').trim();
    const authorAvatarURL = upgradeHttpsUrl(post.author?.avatar || '') || null;
    const isRetweet = Boolean(
      entry?.reason && String(entry.reason.$type || '').toLowerCase().includes('repost'),
    );

    const record = post.record || {};
    const bodyText = String(record.text || '').trim();
    const dates = formatIsoOrEpochDate(record.createdAt || post.indexedAt);

    const embed = post.embed || {};
    const media = [];
    const seen = new Set();

    const imageArrays = [
      Array.isArray(embed.images) ? embed.images : [],
      Array.isArray(embed.media?.images) ? embed.media.images : [],
    ];
    for (const arr of imageArrays) {
      for (const img of arr) {
        const full = upgradeHttpsUrl(img?.fullsize || img?.thumb || '');
        const thumb = upgradeHttpsUrl(img?.thumb || full);
        if (!full || seen.has(full)) continue;
        seen.add(full);
        media.push({
          kind: 'photo',
          url: full,
          thumbnailURL: thumb || full,
          width: Number(img?.aspectRatio?.width || 0) || 0,
          height: Number(img?.aspectRatio?.height || 0) || 0,
        });
      }
    }

    // Video embed (Bluesky exposes HLS `.m3u8` + JPEG thumbnail; desktop downloader saves MP4 if direct or falls back to thumbnail)
    const videoNode =
      String(embed.$type || '').includes('video')
        ? embed
        : String(embed.media?.$type || '').includes('video')
          ? embed.media
          : null;
    if (videoNode) {
      const playlist = upgradeHttpsUrl(videoNode.playlist || '');
      const thumb = upgradeHttpsUrl(videoNode.thumbnail || '');
      const url = playlist || thumb;
      if (url && !seen.has(url)) {
        seen.add(url);
        media.push({
          kind: 'video',
          url,
          thumbnailURL: thumb || null,
          width: Number(videoNode.aspectRatio?.width || 0) || 0,
          height: Number(videoNode.aspectRatio?.height || 0) || 0,
        });
      }
    }

    if (media.length === 0) continue;

    const dedupKey = `bsky:${authorHandle.toLowerCase()}:${postID}`;
    const rec = {
      platform: 'bluesky',
      postID,
      tweetID: postID,
      originalURL: `https://bsky.app/profile/${authorHandle}/post/${postID}`,
      dedupKey,
      authorName,
      authorHandle,
      authorAvatarURL,
      publishedAtText: dates.publishedAtText,
      publishedDateKey: dates.publishedDateKey,
      title: '',
      bodyText,
      isRetweet,
      likeCount: typeof post.likeCount === 'number' ? post.likeCount : null,
      repostCount: typeof post.repostCount === 'number' ? post.repostCount : null,
      replyCount: typeof post.replyCount === 'number' ? post.replyCount : null,
      media,
      hasVideo: media.some((m) => m.kind === 'video' || m.kind === 'gif'),
      needsEnrich: false,
      referer: 'https://bsky.app/',
    };

    const existing = byKey.get(dedupKey);
    if (!existing || rec.media.length > existing.media.length) {
      byKey.set(dedupKey, rec);
    }
  }

  return Array.from(byKey.values());
}

/**
 * Normalizes a Pixiv artwork from `/ajax/illust/<id>` + optional `/ajax/illust/<id>/pages` responses.
 */
export function extractArtworkFromPixivPayloads(illustBody, pagesBody = null) {
  if (!illustBody || typeof illustBody !== 'object') return null;
  const illustId = String(illustBody.illustId || illustBody.id || '').trim();
  if (!/^\d{1,16}$/.test(illustId)) return null;

  const title = String(illustBody.illustTitle || illustBody.title || '').trim();
  const bodyText = stripHtmlToPlainText(illustBody.illustComment || illustBody.description || '');
  const authorName = String(illustBody.userName || '').trim() || `Pixiv #${illustBody.userId || ''}`;
  const authorHandle = String(illustBody.userId || illustBody.userAccount || 'pixiv').trim();
  const dates = formatIsoOrEpochDate(illustBody.createDate || illustBody.uploadDate);

  const rawTags = Array.isArray(illustBody.tags?.tags)
    ? illustBody.tags.tags.map((t) => String(t?.tag || '').trim()).filter(Boolean)
    : Array.isArray(illustBody.tags)
      ? illustBody.tags.map((t) => String(t || '').trim()).filter(Boolean)
      : [];

  const media = [];
  const seen = new Set();
  if (Array.isArray(pagesBody) && pagesBody.length > 0) {
    for (const page of pagesBody) {
      const orig = upgradeHttpsUrl(page?.urls?.original || page?.urls?.regular || page?.urls?.small || '');
      const thumb = upgradeHttpsUrl(page?.urls?.regular || page?.urls?.small || orig);
      if (!orig || seen.has(orig)) continue;
      seen.add(orig);
      media.push({
        kind: 'photo',
        url: orig,
        thumbnailURL: thumb || orig,
        width: Number(page?.width || 0) || 0,
        height: Number(page?.height || 0) || 0,
      });
    }
  } else {
    const orig = upgradeHttpsUrl(
      illustBody.urls?.original || illustBody.urls?.regular || illustBody.url || '',
    );
    const thumb = upgradeHttpsUrl(illustBody.urls?.regular || illustBody.urls?.small || orig);
    if (orig) {
      media.push({
        kind: 'photo',
        url: orig,
        thumbnailURL: thumb || orig,
        width: Number(illustBody.width || 0) || 0,
        height: Number(illustBody.height || 0) || 0,
      });
    }
  }

  if (media.length === 0) return null;

  return {
    platform: 'pixiv',
    postID: illustId,
    tweetID: illustId,
    originalURL: `https://www.pixiv.net/artworks/${illustId}`,
    dedupKey: `pixiv:${illustId}`,
    authorName,
    authorHandle,
    authorAvatarURL: null,
    publishedAtText: dates.publishedAtText,
    publishedDateKey: dates.publishedDateKey,
    title,
    bodyText,
    isRetweet: false,
    media,
    hasVideo: false,
    needsEnrich: false,
    referer: 'https://www.pixiv.net/',
    tags: Array.from(new Set(['Pixiv', authorName, ...rawTags.slice(0, 12)])),
  };
}

function pickBestCandidateUrl(candidates) {
  if (!Array.isArray(candidates) || candidates.length === 0) return null;
  let best = null;
  let bestArea = -1;
  for (const c of candidates) {
    const url = upgradeHttpsUrl(c?.url || '');
    if (!url) continue;
    const w = Number(c?.width || 0) || 0;
    const h = Number(c?.height || 0) || 0;
    const area = w * h;
    if (!best || area > bestArea) {
      best = { url, width: w, height: h };
      bestArea = area;
    }
  }
  return best;
}

function extractMetaMediaItem(node) {
  if (!node || typeof node !== 'object') return null;
  const bestImage = pickBestCandidateUrl(node.image_versions2?.candidates);
  const displayUrl = upgradeHttpsUrl(node.display_url || '') || bestImage?.url || '';
  const bestVideo = pickBestCandidateUrl(node.video_versions);
  const directVideo = upgradeHttpsUrl(node.video_url || '') || bestVideo?.url || '';

  if (directVideo) {
    return {
      kind: 'video',
      url: directVideo,
      thumbnailURL: displayUrl || null,
      width: bestVideo?.width || bestImage?.width || Number(node.original_width || 0) || 0,
      height: bestVideo?.height || bestImage?.height || Number(node.original_height || 0) || 0,
    };
  }
  if (displayUrl) {
    return {
      kind: 'photo',
      url: displayUrl,
      thumbnailURL: displayUrl,
      width: bestImage?.width || Number(node.original_width || node.dimensions?.width || 0) || 0,
      height: bestImage?.height || Number(node.original_height || node.dimensions?.height || 0) || 0,
    };
  }
  return null;
}

function extractMetaMediaList(postNode) {
  const media = [];
  const seen = new Set();
  const pushUnique = (item) => {
    if (!item || !item.url || seen.has(item.url)) return;
    seen.add(item.url);
    media.push(item);
  };

  if (Array.isArray(postNode.carousel_media) && postNode.carousel_media.length > 0) {
    for (const slide of postNode.carousel_media) {
      pushUnique(extractMetaMediaItem(slide));
    }
  } else if (Array.isArray(postNode.edge_sidecar_to_children?.edges) && postNode.edge_sidecar_to_children.edges.length > 0) {
    for (const edge of postNode.edge_sidecar_to_children.edges) {
      pushUnique(extractMetaMediaItem(edge?.node));
    }
  } else {
    pushUnique(extractMetaMediaItem(postNode));
  }
  return media;
}

/**
 * Walks any Threads GraphQL JSON payload and extracts media-bearing Threads posts.
 */
export function extractPostsFromThreadsGraphQLPayload(payload) {
  const byCode = new Map();
  if (!payload || typeof payload !== 'object') return [];

  const stack = [payload];
  const visited = new Set();

  while (stack.length > 0) {
    const cur = stack.pop();
    if (!cur || typeof cur !== 'object' || visited.has(cur)) continue;
    visited.add(cur);

    if (Array.isArray(cur)) {
      for (let i = cur.length - 1; i >= 0; i -= 1) {
        if (cur[i] && typeof cur[i] === 'object') stack.push(cur[i]);
      }
      continue;
    }

    const code = typeof cur.code === 'string' ? cur.code.trim() : '';
    const hasMediaCarrier = Boolean(
      cur.carousel_media || cur.image_versions2 || cur.video_versions,
    );
    if (code && /^[a-zA-Z0-9_-]{4,40}$/.test(code) && hasMediaCarrier && cur.user) {
      const media = extractMetaMediaList(cur);
      if (media.length > 0) {
        const handle = String(cur.user?.username || 'threads').trim().replace(/^@/, '');
        const authorName = String(cur.user?.full_name || handle).trim();
        const bodyText = String(cur.caption?.text || '').trim();
        const dates = formatIsoOrEpochDate(cur.taken_at);
        const isRepost = Boolean(
          cur.text_post_app_info?.share_info?.reposted_post || cur.is_repost,
        );
        const rec = {
          platform: 'threads',
          postID: code,
          tweetID: code,
          originalURL: `https://www.threads.net/@${handle}/post/${code}`,
          dedupKey: `threads:${code}`,
          authorName,
          authorHandle: handle,
          authorAvatarURL: upgradeHttpsUrl(cur.user?.profile_pic_url || '') || null,
          publishedAtText: dates.publishedAtText,
          publishedDateKey: dates.publishedDateKey,
          title: '',
          bodyText,
          isRetweet: isRepost,
          media,
          hasVideo: media.some((m) => m.kind === 'video' || m.kind === 'gif'),
          needsEnrich: false,
          referer: 'https://www.threads.net/',
        };
        const prev = byCode.get(code);
        if (!prev || rec.media.length > prev.media.length) {
          byCode.set(code, rec);
        }
      }
      // Do not descend into quoted/reposted nested post objects
      continue;
    }

    for (const k of Object.keys(cur)) {
      if (k === 'quoted_post' || k === 'reposted_post') continue;
      const v = cur[k];
      if (v && typeof v === 'object') stack.push(v);
    }
  }

  return Array.from(byCode.values());
}

/**
 * Walks Instagram GraphQL (`xdt_api__v1__feed__...` / `edge_owner_to_timeline_media`)
 * and REST (`/api/v1/feed/user/...`) JSON responses and extracts all photos, carousels, and reels.
 */
export function extractPostsFromInstagramPayload(payload) {
  const byCode = new Map();
  if (!payload || typeof payload !== 'object') return [];

  const stack = [payload];
  const visited = new Set();

  while (stack.length > 0) {
    const cur = stack.pop();
    if (!cur || typeof cur !== 'object' || visited.has(cur)) continue;
    visited.add(cur);

    if (Array.isArray(cur)) {
      for (let i = cur.length - 1; i >= 0; i -= 1) {
        if (cur[i] && typeof cur[i] === 'object') stack.push(cur[i]);
      }
      continue;
    }

    const code = String(cur.code || cur.shortcode || '').trim();
    const looksLikeIgPost = Boolean(
      code &&
        /^[a-zA-Z0-9_-]{4,40}$/.test(code) &&
        (cur.carousel_media ||
          cur.image_versions2 ||
          cur.video_versions ||
          cur.display_url ||
          cur.edge_sidecar_to_children),
    );
    if (looksLikeIgPost) {
      const media = extractMetaMediaList(cur);
      if (media.length > 0) {
        const userObj = cur.user || cur.owner || {};
        const handle = String(userObj.username || 'instagram').trim().replace(/^@/, '');
        const authorName = String(userObj.full_name || handle).trim();
        const captionText = String(
          cur.caption?.text ||
            cur.edge_media_to_caption?.edges?.[0]?.node?.text ||
            '',
        ).trim();
        const dates = formatIsoOrEpochDate(cur.taken_at ?? cur.taken_at_timestamp);
        const isReel =
          cur.product_type === 'clips' ||
          cur.__typename === 'GraphVideo' ||
          (media.length === 1 && media[0].kind === 'video');
        const pathKind = isReel ? 'reel' : 'p';
        const rec = {
          platform: 'instagram',
          postID: code,
          tweetID: code,
          originalURL: `https://www.instagram.com/${pathKind}/${code}/`,
          dedupKey: `ig:${code}`,
          authorName,
          authorHandle: handle,
          authorAvatarURL: upgradeHttpsUrl(userObj.profile_pic_url || '') || null,
          publishedAtText: dates.publishedAtText,
          publishedDateKey: dates.publishedDateKey,
          title: '',
          bodyText: captionText,
          isRetweet: false,
          media,
          hasVideo: media.some((m) => m.kind === 'video' || m.kind === 'gif'),
          needsEnrich: false,
          referer: 'https://www.instagram.com/',
        };
        const prev = byCode.get(code);
        if (!prev || rec.media.length > prev.media.length) {
          byCode.set(code, rec);
        }
      }
      continue;
    }

    for (const k of Object.keys(cur)) {
      const v = cur[k];
      if (v && typeof v === 'object') stack.push(v);
    }
  }

  return Array.from(byCode.values());
}

// MARK: - Unified Cross-Platform Folder Naming & Filtering

const PLATFORM_NOUN = {
  x: '推文',
  bluesky: '贴文',
  pixiv: '作品',
  threads: '贴文',
  instagram: '贴文',
  xiaohongshu: '笔记',
};

const PLATFORM_LABEL = {
  x: 'X',
  bluesky: 'Bluesky',
  pixiv: 'Pixiv',
  threads: 'Threads',
  instagram: 'Instagram',
  xiaohongshu: '小红书',
};

export function buildCreatorRootFolderName(platform, authorHandle = '', authorName = '', fallback = '') {
  const cleanHandle = String(authorHandle ?? '').trim().replace(/^@/, '');
  const cleanName = sanitizeSegment(authorName, 36);
  const label = PLATFORM_LABEL[platform] || '社交';

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

export function buildPostSubfolderName(post, { maxSnippetLength = 28 } = {}) {
  const postID = String(post?.postID || post?.tweetID || '').trim();
  const idSuffix = postID.length > 6 ? postID.slice(-6) : postID;
  const dateKey =
    String(post?.publishedDateKey || '').trim() ||
    (String(post?.publishedAtText || '').match(/^\d{4}-\d{2}-\d{2}/)?.[0] ?? '');

  const rawHeadline = String(post?.title || post?.articleTitle || post?.bodyText || '');
  const snippet = sanitizeSegment(rawHeadline, maxSnippetLength);
  const noun = PLATFORM_NOUN[post?.platform] || '作品';

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

export function resolvePostOrganizationFolderName(post, organizeMode = 'per_tweet') {
  if (organizeMode === 'flat') return null;
  if (organizeMode === 'multi_only') {
    const count = Array.isArray(post?.media) ? post.media.length : 0;
    return count >= 2 ? buildPostSubfolderName(post) : null;
  }
  return buildPostSubfolderName(post);
}

export function filterCreatorMediaPost(
  post,
  { targetHandle = '', skipRetweets = true, includeVideos = true } = {},
) {
  const postID = String(post?.postID || post?.tweetID || '').trim();
  if (!post || !postID) return null;

  const normTarget = String(targetHandle || '').trim().replace(/^@/, '').toLowerCase();
  const normAuthor = String(post.authorHandle || '').trim().replace(/^@/, '').toLowerCase();

  if (skipRetweets) {
    if (post.isRetweet) return null;
    if (
      normTarget &&
      normAuthor &&
      normAuthor !== 'i' &&
      post.platform !== 'pixiv' &&
      post.platform !== 'xiaohongshu' &&
      normAuthor !== normTarget
    ) {
      return null;
    }
  }

  const rawMedia = Array.isArray(post.media) ? post.media : [];
  const filteredMedia = includeVideos
    ? rawMedia
    : rawMedia.filter((m) => m && m.kind === 'photo');

  if (filteredMedia.length === 0 && !post.needsEnrich) {
    return null;
  }

  return {
    ...post,
    postID,
    media: filteredMedia,
    hasVideo: filteredMedia.some((m) => m.kind === 'video' || m.kind === 'gif'),
  };
}
