/**
 * Pure utilities for X (Twitter) Author All-Media collection:
 * - Author profile / media route detection
 * - High-resolution (`name=orig`) media URL upgrade & best MP4 variant selection
 * - GraphQL `UserMedia` / `UserTweets` / `TweetDetail` response extraction
 * - Deterministic per-tweet folder naming & organization strategies
 */

const X_PROFILE_HOSTS = new Set([
  'x.com',
  'www.x.com',
  'mobile.x.com',
  'twitter.com',
  'www.twitter.com',
  'mobile.twitter.com',
]);

const X_RESERVED_TOP_SEGMENTS = new Set([
  'home',
  'explore',
  'notifications',
  'messages',
  'i',
  'search',
  'settings',
  'compose',
  'login',
  'signup',
  'logout',
  'tos',
  'privacy',
  'intent',
  'hashtag',
  'lists',
  'communities',
  'jobs',
  'grok',
  'premium',
  'verified-orgs',
  'download',
  'account',
  'about',
  'help',
  'status',
  'statuses',
  'share',
  'widgets',
  'who_to_follow',
  'connect_people',
  'bookmarks',
  'likes',
  'history',
]);

const X_AUTHOR_MEDIA_TABS = new Set(['', 'media', 'highlights', 'with_replies', 'articles']);

export function isValidXHandle(raw) {
  const clean = String(raw ?? '').trim().replace(/^@/, '');
  if (!clean || clean.length > 32) return false;
  if (X_RESERVED_TOP_SEGMENTS.has(clean.toLowerCase())) return false;
  return /^[a-zA-Z0-9_]{1,32}$/.test(clean);
}

/**
 * Detects whether a URL is an X author profile or author media page
 * (e.g. `https://x.com/artist`, `https://x.com/artist/media`).
 */
export function detectXAuthorProfileUrl(rawUrl) {
  let u;
  try {
    u = new URL(String(rawUrl ?? '').trim());
  } catch {
    return null;
  }
  if (u.protocol !== 'http:' && u.protocol !== 'https:') return null;
  const host = u.hostname.toLowerCase();
  if (!X_PROFILE_HOSTS.has(host)) return null;

  const parts = u.pathname.split('/').filter(Boolean);
  if (parts.length === 0 || parts.length > 2) return null;

  const handle = parts[0].replace(/^@/, '');
  if (!isValidXHandle(handle)) return null;

  const subTab = (parts[1] || '').toLowerCase();
  if (!X_AUTHOR_MEDIA_TABS.has(subTab)) return null;

  return {
    isAuthorProfile: true,
    handle,
    tab: subTab || 'posts',
    isMediaTab: subTab === 'media',
    canonicalProfileUrl: `https://x.com/${handle}`,
    canonicalMediaUrl: `https://x.com/${handle}/media`,
  };
}

/**
 * Upgrades `pbs.twimg.com/media/...` URLs to original full resolution (`name=orig`),
 * preserving format (`png`/`jpg`/`webp`) and handling legacy `:small`/`:large` suffixes.
 */
export function upgradeTwitterMediaUrl(rawUrl, preferredName = 'orig') {
  const trimmed = String(rawUrl ?? '').trim();
  if (!trimmed) return '';
  let candidate = trimmed;
  if (candidate.startsWith('//')) candidate = `https:${candidate}`;
  else if (/^http:\/\//i.test(candidate)) candidate = `https://${candidate.slice(7)}`;

  try {
    const u = new URL(candidate);
    if (u.protocol !== 'http:' && u.protocol !== 'https:') return '';
    u.hash = '';
    if (u.hostname.toLowerCase() === 'pbs.twimg.com' && u.pathname.startsWith('/media/')) {
      // Handle legacy `.../media/ABC.jpg:small` suffix
      const colonIdx = u.pathname.indexOf(':');
      if (colonIdx > 0) {
        u.pathname = u.pathname.slice(0, colonIdx);
      }
      if (!u.searchParams.get('format')) {
        const extMatch = /\.([a-z0-9]+)$/i.exec(u.pathname);
        if (extMatch) {
          const ext = extMatch[1].toLowerCase() === 'jpeg' ? 'jpg' : extMatch[1].toLowerCase();
          if (['jpg', 'png', 'webp'].includes(ext)) {
            u.pathname = u.pathname.slice(0, -extMatch[0].length);
            u.searchParams.set('format', ext);
          }
        }
      }
      u.searchParams.set('name', preferredName || 'orig');
    }
    return u.href;
  } catch {
    return '';
  }
}

/**
 * Selects the highest-bitrate progressive MP4 variant from X GraphQL `video_info`.
 */
export function pickBestTwitterVideoVariant(videoInfo) {
  const variants = Array.isArray(videoInfo?.variants) ? videoInfo.variants : [];
  let bestUrl = '';
  let bestBitrate = -1;
  for (const v of variants) {
    const url = String(v?.url || '').trim();
    if (!url || !/^https?:\/\//i.test(url)) continue;
    const ct = String(v?.content_type || '').toLowerCase();
    if (ct !== 'video/mp4' && !/\.mp4(?:$|\?)/i.test(url)) continue;
    const bitrate = Number(v?.bitrate ?? 0);
    if (!bestUrl || bitrate >= bestBitrate) {
      bestUrl = url;
      bestBitrate = Number.isFinite(bitrate) ? bitrate : 0;
    }
  }
  return bestUrl || null;
}

export function formatTwitterDate(rawCreatedAt) {
  if (!rawCreatedAt) return { publishedAtText: null, publishedDateKey: '' };
  const d = new Date(rawCreatedAt);
  if (Number.isNaN(d.getTime())) return { publishedAtText: null, publishedDateKey: '' };
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

function unwrapTweetResult(node) {
  if (!node || typeof node !== 'object') return null;
  if (node.__typename === 'TweetWithVisibilityResults' && node.tweet) {
    return node.tweet;
  }
  if (node.tweet && typeof node.tweet === 'object' && node.tweet.legacy) {
    return node.tweet;
  }
  if (node.legacy && (node.rest_id || node.legacy.id_str)) {
    return node;
  }
  return null;
}

function extractUserIdentity(tweetObj) {
  const userResult = tweetObj?.core?.user_results?.result;
  const userCore = userResult?.core || {};
  const userLegacy = userResult?.legacy || {};
  const handle = String(userCore.screen_name || userLegacy.screen_name || '').trim().replace(/^@/, '');
  const name = String(userCore.name || userLegacy.name || handle || '').trim();
  let avatar = String(userResult?.avatar?.image_url || userLegacy.profile_image_url_https || '').trim();
  if (avatar && avatar.includes('_normal.')) {
    avatar = avatar.replace('_normal.', '_400x400.');
  }
  return {
    authorHandle: handle,
    authorName: name || handle,
    authorAvatarURL: avatar || null,
  };
}

function extractMediaFromLegacy(legacy) {
  const rawList =
    Array.isArray(legacy?.extended_entities?.media) && legacy.extended_entities.media.length > 0
      ? legacy.extended_entities.media
      : Array.isArray(legacy?.entities?.media)
        ? legacy.entities.media
        : [];
  const items = [];
  const seen = new Set();

  for (const m of rawList) {
    if (!m || typeof m !== 'object') continue;
    const rawType = String(m.type || 'photo').toLowerCase();
    const thumbRaw = m.media_url_https || m.media_url || '';
    const thumbUrl = upgradeTwitterMediaUrl(thumbRaw, 'large') || thumbRaw;
    const width = Number(m.original_info?.width || m.sizes?.large?.w || 0) || 0;
    const height = Number(m.original_info?.height || m.sizes?.large?.h || 0) || 0;

    if (rawType === 'video' || rawType === 'animated_gif') {
      const mp4 = pickBestTwitterVideoVariant(m.video_info);
      const url = mp4 || thumbUrl;
      if (!url || seen.has(url)) continue;
      seen.add(url);
      items.push({
        kind: rawType === 'animated_gif' ? 'gif' : 'video',
        url,
        thumbnailURL: thumbUrl || null,
        width,
        height,
      });
    } else {
      const origUrl = upgradeTwitterMediaUrl(thumbRaw, 'orig');
      if (!origUrl || seen.has(origUrl)) continue;
      seen.add(origUrl);
      items.push({
        kind: 'photo',
        url: origUrl,
        thumbnailURL: thumbUrl || origUrl,
        width,
        height,
      });
    }
  }
  return items;
}

/**
 * Walks any X GraphQL response payload (`UserMedia`, `UserTweets`, `TweetDetail`, etc.)
 * and extracts normalized media-bearing tweets while distinguishing original posts from retweets.
 */
export function extractTweetsFromXGraphQLPayload(payload) {
  const byId = new Map();
  if (!payload || typeof payload !== 'object') return [];

  const stack = [payload];
  const visited = new Set();

  while (stack.length > 0) {
    const cur = stack.pop();
    if (!cur || typeof cur !== 'object' || visited.has(cur)) continue;
    visited.add(cur);

    if (Array.isArray(cur)) {
      for (let i = cur.length - 1; i >= 0; i -= 1) {
        const el = cur[i];
        if (el && typeof el === 'object') stack.push(el);
      }
      continue;
    }

    const candidate = cur.tweet_results?.result ? unwrapTweetResult(cur.tweet_results.result) : null;
    if (candidate && candidate.legacy) {
      const outerIdentity = extractUserIdentity(candidate);
      const retweetedInner = unwrapTweetResult(candidate.legacy?.retweeted_status_result?.result);
      const isRetweet = Boolean(retweetedInner);
      const targetTweet = retweetedInner || candidate;
      const legacy = targetTweet.legacy || {};
      const tweetID = String(targetTweet.rest_id || legacy.id_str || '').trim();
      const media = extractMediaFromLegacy(legacy);

      if (/^\d{1,24}$/.test(tweetID) && media.length > 0) {
        const identity = extractUserIdentity(targetTweet);
        const authorHandle = identity.authorHandle || outerIdentity.authorHandle || 'i';
        const authorName = identity.authorName || authorHandle;
        const noteText = targetTweet.note_tweet?.note_tweet_results?.result?.text || '';
        const bodyText = String(noteText || legacy.full_text || legacy.text || '').trim();
        const { publishedAtText, publishedDateKey } = formatTwitterDate(legacy.created_at);

        const record = {
          tweetID,
          originalURL: `https://x.com/${authorHandle}/status/${tweetID}`,
          dedupKey: `x:${tweetID}`,
          authorName,
          authorHandle,
          authorAvatarURL: identity.authorAvatarURL,
          publishedAtText,
          publishedDateKey,
          bodyText,
          isRetweet,
          retweetedByHandle: isRetweet ? outerIdentity.authorHandle || null : null,
          likeCount: typeof legacy.favorite_count === 'number' ? legacy.favorite_count : null,
          repostCount: typeof legacy.retweet_count === 'number' ? legacy.retweet_count : null,
          replyCount: typeof legacy.reply_count === 'number' ? legacy.reply_count : null,
          media,
          hasVideo: media.some((m) => m.kind === 'video' || m.kind === 'gif'),
          needsEnrich: false,
        };

        const existing = byId.get(tweetID);
        if (!existing || record.media.length > existing.media.length) {
          byId.set(tweetID, record);
        }
      }
      // Do not descend into quoted_status_result so quoted tweets don't pollute the author's media list.
      continue;
    }

    for (const key of Object.keys(cur)) {
      if (key === 'quoted_status_result') continue;
      const val = cur[key];
      if (val && typeof val === 'object') {
        stack.push(val);
      }
    }
  }

  return Array.from(byId.values());
}

function sanitizeFolderSegment(raw, maxLen = 64) {
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

export function buildAuthorRootFolderName(authorHandle, authorName = '') {
  const cleanHandle = String(authorHandle ?? '').trim().replace(/^@/, '');
  const cleanName = sanitizeFolderSegment(authorName, 36);
  if (!cleanHandle) return cleanName || 'X 作者媒体';
  if (cleanName && cleanName.toLowerCase() !== cleanHandle.toLowerCase() && cleanName !== `@${cleanHandle}`) {
    return `${cleanName} (@${cleanHandle})`.slice(0, 64);
  }
  return `@${cleanHandle}`;
}

/**
 * Generates a deterministic, collision-free, human-readable subfolder name for a tweet.
 * Example: `2026-11-20 · Lighting study [890123]`
 */
export function buildTweetSubfolderName(tweet, { maxSnippetLength = 28 } = {}) {
  const tweetID = String(tweet?.tweetID || '').trim();
  const idSuffix = tweetID.length > 6 ? tweetID.slice(-6) : tweetID;
  const dateKey =
    String(tweet?.publishedDateKey || '').trim() ||
    (String(tweet?.publishedAtText || '').match(/^\d{4}-\d{2}-\d{2}/)?.[0] ?? '');

  const snippet = sanitizeFolderSegment(tweet?.bodyText || '', maxSnippetLength);
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

export function resolveTweetOrganizationFolderName(tweet, organizeMode = 'per_tweet') {
  if (organizeMode === 'flat') return null;
  if (organizeMode === 'multi_only') {
    const count = Array.isArray(tweet?.media) ? tweet.media.length : 0;
    return count >= 2 ? buildTweetSubfolderName(tweet) : null;
  }
  return buildTweetSubfolderName(tweet);
}

/**
 * Filters a normalized tweet record according to author-media collection preferences.
 */
export function filterAuthorMediaTweet(
  tweet,
  { targetHandle = '', skipRetweets = true, includeVideos = true } = {},
) {
  if (!tweet || !tweet.tweetID) return null;
  const normTarget = String(targetHandle || '').trim().replace(/^@/, '').toLowerCase();
  const normAuthor = String(tweet.authorHandle || '').trim().replace(/^@/, '').toLowerCase();

  if (skipRetweets) {
    if (tweet.isRetweet) return null;
    if (normTarget && normAuthor && normAuthor !== 'i' && normAuthor !== normTarget) {
      return null;
    }
  }

  const rawMedia = Array.isArray(tweet.media) ? tweet.media : [];
  const filteredMedia = includeVideos
    ? rawMedia
    : rawMedia.filter((m) => m && m.kind === 'photo');

  if (filteredMedia.length === 0 && !tweet.needsEnrich) {
    return null;
  }

  return {
    ...tweet,
    media: filteredMedia,
    hasVideo: filteredMedia.some((m) => m.kind === 'video' || m.kind === 'gif'),
  };
}
