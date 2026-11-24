/**
 * Pure Xiaohongshu (小红书) URL normalizer, `__INITIAL_STATE__` parser, and metric utilities.
 * Shared across unit tests and runtime content/background parsing.
 */

import { isValidXhsNoteId } from './url-detect.js';

export function upgradeHttpsUrl(raw) {
  const trimmed = String(raw ?? '').trim();
  if (!trimmed) return '';
  let normalized = trimmed;
  if (normalized.startsWith('//')) {
    normalized = `https:${normalized}`;
  } else if (/^http:\/\//i.test(normalized)) {
    normalized = `https://${normalized.slice(7)}`;
  }
  try {
    const u = new URL(normalized);
    if (u.protocol !== 'http:' && u.protocol !== 'https:') return '';
    return u.href;
  } catch {
    return '';
  }
}

/**
 * Normalizes a Xiaohongshu note href (from `/explore/`, `/discovery/item/`, or `/user/profile/<uid>/<noteId>`)
 * into a canonical `https://www.xiaohongshu.com/explore/<noteId>?xsec_token=...&xsec_source=...` URL
 * while preserving `xsec_token` so notes stay directly openable and resolvable.
 */
export function normalizeXiaohongshuNoteUrl(rawHref, baseOrigin = 'https://www.xiaohongshu.com') {
  if (!rawHref) return null;
  let u;
  try {
    u = new URL(String(rawHref).trim(), baseOrigin);
  } catch {
    return null;
  }
  if (u.protocol !== 'http:' && u.protocol !== 'https:') return null;
  const host = u.hostname.toLowerCase();
  if (!host.endsWith('xiaohongshu.com')) return null;

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

  const out = new URL(`https://www.xiaohongshu.com/explore/${noteId}`);
  if (xsecToken) out.searchParams.set('xsec_token', xsecToken);
  if (xsecSource) out.searchParams.set('xsec_source', xsecSource);

  return {
    noteId,
    xsecToken: xsecToken || null,
    xsecSource: xsecSource || null,
    url: out.href,
    dedupKey: `xhs:${noteId.toLowerCase()}`,
  };
}

/**
 * Replaces bare JS `undefined` tokens outside JSON string literals with `null`.
 */
export function sanitizeJSUndefined(input) {
  const src = String(input ?? '');
  let out = '';
  let inString = false;
  let escaped = false;

  for (let i = 0; i < src.length; i++) {
    const ch = src[i];
    if (inString) {
      out += ch;
      if (escaped) {
        escaped = false;
      } else if (ch === '\\') {
        escaped = true;
      } else if (ch === '"') {
        inString = false;
      }
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
      const prevIdent = /[a-zA-Z0-9_$]/.test(prev);
      const nextIdent = /[a-zA-Z0-9_$]/.test(next);
      if (!prevIdent && !nextIdent) {
        out += 'null';
        i += 8;
        continue;
      }
    }

    out += ch;
  }
  return out;
}

/**
 * Extracts balanced JSON object assigned to `window.__INITIAL_STATE__`.
 */
export function extractInitialStateJSON(html) {
  const src = String(html ?? '');
  const markers = ['window.__INITIAL_STATE__=', 'window.__INITIAL_STATE__ ='];
  for (const marker of markers) {
    const idx = src.indexOf(marker);
    if (idx < 0) continue;
    let start = idx + marker.length;
    while (start < src.length && /\s/.test(src[start])) start++;
    if (src[start] !== '{') continue;

    let depth = 0;
    let inString = false;
    let escaped = false;
    for (let i = start; i < src.length; i++) {
      const ch = src[i];
      if (inString) {
        if (escaped) escaped = false;
        else if (ch === '\\') escaped = true;
        else if (ch === '"') inString = false;
      } else {
        if (ch === '"') inString = true;
        else if (ch === '{') depth++;
        else if (ch === '}') {
          depth--;
          if (depth === 0) {
            return src.slice(start, i + 1);
          }
        }
      }
    }
  }
  return null;
}

export function parseChineseMetricCount(raw) {
  if (typeof raw === 'number' && Number.isFinite(raw)) {
    return Math.max(0, Math.round(raw));
  }
  const s = String(raw ?? '')
    .trim()
    .replace(/\+/g, '')
    .replace(/,/g, '')
    .trim();
  if (!s) return null;
  if (s.endsWith('万') || s.toLowerCase().endsWith('w')) {
    const n = Number.parseFloat(s.slice(0, -1));
    return Number.isFinite(n) ? Math.max(0, Math.round(n * 10_000)) : null;
  }
  if (s.endsWith('千') || s.toLowerCase().endsWith('k')) {
    const n = Number.parseFloat(s.slice(0, -1));
    return Number.isFinite(n) ? Math.max(0, Math.round(n * 1_000)) : null;
  }
  if (/^\d+$/.test(s)) {
    return Number.parseInt(s, 10);
  }
  return null;
}

export function cleanXiaohongshuBody(text) {
  return String(text ?? '')
    .replace(/\[话题\]#/g, '')
    .trim();
}

function locateNoteInState(root, expectedNoteId) {
  if (!root || typeof root !== 'object') return null;
  const noteSection = root.note;
  if (noteSection && typeof noteSection === 'object') {
    const map = noteSection.noteDetailMap;
    if (map && typeof map === 'object') {
      if (expectedNoteId && map[expectedNoteId]?.note) {
        return map[expectedNoteId].note;
      }
      for (const entry of Object.values(map)) {
        if (entry?.note && (entry.note.title || entry.note.desc || entry.note.imageList)) {
          return entry.note;
        }
      }
    }
    if (noteSection.note && typeof noteSection.note === 'object') {
      return noteSection.note;
    }
  }
  if (root.noteData?.data?.noteData) {
    return root.noteData.data.noteData;
  }
  return null;
}

function formatXhsTimestamp(raw) {
  const num = Number(raw);
  if (!Number.isFinite(num) || num < 1_000_000_000) return null;
  const ms = num > 10_000_000_000 ? num : num * 1000;
  const d = new Date(ms);
  if (Number.isNaN(d.getTime())) return null;
  const pad = (v) => String(v).padStart(2, '0');
  return `${d.getFullYear()}-${pad(d.getMonth() + 1)}-${pad(d.getDate())} ${pad(d.getHours())}:${pad(d.getMinutes())}`;
}

/**
 * Parses Xiaohongshu note page HTML (`window.__INITIAL_STATE__`) into a rich Charkle `socialBookmark` payload,
 * merging with any card-level fallback fields when present.
 */
export function parseXiaohongshuNoteHtml(html, noteUrl, fallback = {}) {
  const normalized = normalizeXiaohongshuNoteUrl(noteUrl);
  const expectedId = normalized?.noteId || fallback.noteId || null;
  const rawJson = extractInitialStateJSON(html);
  if (!rawJson) return null;

  let root;
  try {
    root = JSON.parse(sanitizeJSUndefined(rawJson));
  } catch {
    return null;
  }

  const note = locateNoteInState(root, expectedId);
  if (!note) return null;

  const title = String(note.title || fallback.articleTitle || fallback.title || '').trim();
  const desc = cleanXiaohongshuBody(note.desc || fallback.bodyText || '');
  const user = note.user || {};
  const authorName = String(user.nickname || user.nickName || fallback.authorName || '小红书用户').trim();
  const authorHandle = String(user.redId || user.userId || user.id || fallback.authorHandle || 'xiaohongshu').trim();
  const authorAvatarURL = upgradeHttpsUrl(user.avatar || fallback.authorAvatarURL || '') || null;

  const interact = note.interactInfo || {};
  const likeCount = parseChineseMetricCount(interact.likedCount ?? fallback.likeCount);
  const replyCount = parseChineseMetricCount(interact.commentCount);
  const repostCount = parseChineseMetricCount(interact.shareCount ?? interact.collectedCount);
  const publishedAtText = formatXhsTimestamp(note.time ?? note.lastUpdateTime);

  const isVideoNote = String(note.type || '').toLowerCase() === 'video' || Boolean(fallback.hasVideo);
  let videoURL = null;
  const stream = note.video?.media?.stream;
  if (stream && typeof stream === 'object') {
    for (const codec of ['h264', 'av1', 'h265']) {
      const variants = Array.isArray(stream[codec]) ? stream[codec] : [];
      for (const v of variants) {
        const master = upgradeHttpsUrl(v?.masterUrl || '');
        if (master) {
          videoURL = master;
          break;
        }
        const backups = Array.isArray(v?.backupUrls) ? v.backupUrls : [];
        const b = backups.map(upgradeHttpsUrl).find(Boolean);
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

  const imageList = Array.isArray(note.imageList) ? note.imageList : [];
  for (const img of imageList) {
    const infoList = Array.isArray(img?.infoList) ? img.infoList : [];
    const dft = infoList.find((i) => i?.imageScene === 'WB_DFT');
    const prv = infoList.find((i) => i?.imageScene === 'WB_PRV');
    const fullUrl = upgradeHttpsUrl(
      dft?.url || img?.urlDefault || img?.url || infoList[0]?.url || img?.urlPre || '',
    );
    const thumbUrl = upgradeHttpsUrl(prv?.url || img?.urlPre || fullUrl) || fullUrl;
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
      thumbnailURL: coverPhoto || upgradeHttpsUrl(fallback.coverUrl || '') || null,
    });
  } else if (attachments.length === 0) {
    const fallbackCover = coverPhoto || upgradeHttpsUrl(fallback.coverUrl || '');
    if (fallbackCover) {
      attachments.push({ kind: 'photo', url: fallbackCover, thumbnailURL: fallbackCover });
    }
  }

  const tagList = Array.isArray(note.tagList)
    ? note.tagList
        .map((t) => String(t?.name || '').trim())
        .filter((t) => t.length > 0 && t.length <= 32)
    : [];

  if (!title && !desc && attachments.length === 0) {
    return null;
  }

  const canonicalUrl = normalized?.url || noteUrl;
  return {
    type: 'socialBookmark',
    platform: 'xiaohongshu',
    originalURL: canonicalUrl,
    dedupKey: normalized?.dedupKey || fallback.dedupKey || null,
    authorName,
    authorHandle,
    authorAvatarURL,
    publishedAtText,
    articleTitle: title || null,
    bodyText: desc || title || canonicalUrl,
    mediaURLs: attachments.map((a) => a.url),
    mediaThumbnailURLs: attachments.map((a) => a.thumbnailURL || a.url),
    attachments,
    hasVideo: Boolean(videoURL || isVideoNote),
    videoURL,
    replyCount,
    repostCount,
    likeCount,
    tags: Array.from(new Set(['小红书', ...tagList])),
  };
}
