/**
 * Pure, DOM-free Douyin (抖音) payload & URL parser for Charkle Browser Extension.
 *
 * Normalizes passively observed Douyin Web API JSON responses (`aweme_list`, `aweme_detail`,
 * `collects_list`) into Charkle's unified social bookmark / creator media record schema.
 * Strictly read-only — never initiates network requests or synthesizes anti-bot signatures.
 */

import { isValidDouyinAwemeId } from './url-detect.js';

export function upgradeDouyinHttpsUrl(raw) {
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

export function isHeicImageUrl(rawUrl) {
  const lower = String(rawUrl ?? '').toLowerCase();
  return (
    lower.includes('.heic') ||
    lower.includes('.heif') ||
    lower.includes('~tplv-') && lower.includes('heic') ||
    lower.includes('format=heic') ||
    lower.includes('format=heif')
  );
}

/**
 * Picks the highest-compatibility raster image URL from a Douyin `url_list`
 * (preferring JPEG/WebP/PNG over HEIC/HEIF so desktop thumbnail pipelines decode natively).
 */
export function pickBestDouyinImageUrl(urlList) {
  if (!Array.isArray(urlList) || urlList.length === 0) return '';
  const cleaned = [];
  const seen = new Set();
  for (const raw of urlList) {
    const href = upgradeDouyinHttpsUrl(raw);
    if (!href || seen.has(href)) continue;
    seen.add(href);
    cleaned.push(href);
  }
  if (cleaned.length === 0) return '';
  const nonHeic = cleaned.find((u) => !isHeicImageUrl(u));
  return nonHeic || cleaned[0];
}

function isWatermarkedDouyinPlayUrl(rawUrl) {
  const lower = String(rawUrl ?? '').toLowerCase();
  return lower.includes('/playwm/') || lower.includes('watermark=1');
}

function pickCleanVideoUrlFromList(urlList) {
  if (!Array.isArray(urlList) || urlList.length === 0) return '';
  const valid = [];
  const seen = new Set();
  for (const raw of urlList) {
    const href = upgradeDouyinHttpsUrl(raw);
    if (!href || seen.has(href)) continue;
    seen.add(href);
    valid.push(href);
  }
  if (valid.length === 0) return '';
  // Prefer direct VOD CDN links without watermark path segments
  const cleanDirect = valid.find(
    (u) => !isWatermarkedDouyinPlayUrl(u) && !/\/aweme\/v1\/playwm/i.test(u),
  );
  if (cleanDirect) return cleanDirect;
  const first = valid[0];
  return first.replace(/\/playwm\//gi, '/play/');
}

/**
 * Selects the best watermark-free MP4 stream from a Douyin `aweme.video` object,
 * prioritizing H.264 (`is_h265 === 0`) for universal WebView2 `<video>` playback.
 */
export function pickBestDouyinVideoUrl(videoObj) {
  if (!videoObj || typeof videoObj !== 'object') return null;

  const bitRates = Array.isArray(videoObj.bit_rate) ? videoObj.bit_rate : [];
  const ranked = [];
  for (const br of bitRates) {
    if (!br || typeof br !== 'object') continue;
    const url = pickCleanVideoUrlFromList(br.play_addr?.url_list);
    if (!url) continue;
    const isH265 = Number(br.is_h265 || 0) === 1 || /265|hevc/i.test(String(br.gear_name || ''));
    const bitrateNum = Number(br.bit_rate || br.play_addr?.data_size || 0) || 0;
    const width = Number(br.play_addr?.width || 0) || 0;
    const height = Number(br.play_addr?.height || 0) || 0;
    ranked.push({
      url,
      isH265,
      bitrateNum,
      width,
      height,
    });
  }

  if (ranked.length > 0) {
    ranked.sort((a, b) => {
      // H.264 first for broad HTML5 / WebView2 playback compatibility
      if (a.isH265 !== b.isH265) return a.isH265 ? 1 : -1;
      const areaDiff = b.width * b.height - a.width * a.height;
      if (areaDiff !== 0) return areaDiff;
      return b.bitrateNum - a.bitrateNum;
    });
    return ranked[0].url;
  }

  const h264Url = pickCleanVideoUrlFromList(videoObj.play_addr_h264?.url_list);
  if (h264Url) return h264Url;

  const playUrl = pickCleanVideoUrlFromList(videoObj.play_addr?.url_list);
  if (playUrl) return playUrl;

  const lowBrUrl = pickCleanVideoUrlFromList(videoObj.play_addr_lowbr?.url_list);
  if (lowBrUrl) return lowBrUrl;

  return null;
}

export function parseDouyinMetricCount(raw) {
  if (typeof raw === 'number' && Number.isFinite(raw)) {
    return raw >= 0 ? Math.round(raw) : null;
  }
  const text = String(raw ?? '')
    .trim()
    .replace(/[,+]/g, '');
  if (!text) return null;
  const yiMatch = /^(\d+(?:\.\d+)?)\s*亿$/i.exec(text);
  if (yiMatch) return Math.round(Number.parseFloat(yiMatch[1]) * 100_000_000);
  const wanMatch = /^(\d+(?:\.\d+)?)\s*[万w]$/i.exec(text);
  if (wanMatch) return Math.round(Number.parseFloat(wanMatch[1]) * 10_000);
  const qianMatch = /^(\d+(?:\.\d+)?)\s*[千k]$/i.exec(text);
  if (qianMatch) return Math.round(Number.parseFloat(qianMatch[1]) * 1_000);
  if (/^\d+$/.test(text)) return Number.parseInt(text, 10);
  return null;
}

/**
 * Extracts a Douyin share URL (`v.douyin.com/...` or `www.douyin.com/...`) from Chinese mobile share copy.
 */
export function extractDouyinShareCopyUrl(rawText) {
  const text = String(rawText ?? '').trim();
  if (!text) return null;
  const match = /https?:\/\/(?:(?:www|m|v)\.)?(?:douyin|iesdouyin)\.com\/[^\s\u3000"'<>（）【】「」《》“”]+/i.exec(
    text,
  );
  if (!match) return null;
  return match[0].replace(/[.,!?;:，。！？；：]+$/, '');
}

/**
 * Normalizes a Douyin post href (`/video/<id>`, `/note/<id>`, `/share/video/<id>`, or `?modal_id=<id>`)
 * into canonical `https://www.douyin.com/(video|note)/<aweme_id>` + `douyin:<aweme_id>`.
 */
export function normalizeDouyinPostUrl(rawHref, baseOrigin = 'https://www.douyin.com') {
  if (!rawHref) return null;
  let u;
  try {
    u = new URL(String(rawHref).trim(), baseOrigin);
  } catch {
    return null;
  }
  if (u.protocol !== 'http:' && u.protocol !== 'https:') return null;
  const host = u.hostname.toLowerCase();
  if (
    host !== 'douyin.com' &&
    !host.endsWith('.douyin.com') &&
    host !== 'iesdouyin.com' &&
    !host.endsWith('.iesdouyin.com')
  ) {
    return null;
  }

  const parts = u.pathname.split('/').filter(Boolean);
  let awemeId = null;
  let kind = 'video';

  if (parts.length >= 2 && (parts[0].toLowerCase() === 'video' || parts[0].toLowerCase() === 'note') && isValidDouyinAwemeId(parts[1])) {
    kind = parts[0].toLowerCase();
    awemeId = parts[1];
  } else if (
    parts.length >= 3 &&
    parts[0].toLowerCase() === 'share' &&
    (parts[1].toLowerCase() === 'video' || parts[1].toLowerCase() === 'note') &&
    isValidDouyinAwemeId(parts[2])
  ) {
    kind = parts[1].toLowerCase();
    awemeId = parts[2];
  } else {
    const modalId = (u.searchParams.get('modal_id') || '').trim();
    if (isValidDouyinAwemeId(modalId)) {
      awemeId = modalId;
      kind = 'video';
    }
  }

  if (!awemeId) return null;

  return {
    awemeId,
    kind,
    url: `https://www.douyin.com/${kind}/${awemeId}`,
    dedupKey: `douyin:${awemeId}`,
  };
}

function formatDouyinCreateTime(raw) {
  if (raw === null || raw === undefined || raw === '') {
    return { publishedAtText: null, publishedDateKey: '' };
  }
  let d;
  if (typeof raw === 'number' && Number.isFinite(raw) && raw > 0) {
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

function deriveDouyinTitle(itemTitle, desc) {
  const explicit = String(itemTitle || '').trim();
  if (explicit) return explicit.slice(0, 120);
  const cleaned = String(desc || '')
    .replace(/#[^\s#]+/g, ' ')
    .replace(/\s+/g, ' ')
    .trim();
  if (cleaned) return cleaned.slice(0, 80);
  return String(desc || '').trim().slice(0, 80);
}

function extractDouyinTags(aweme) {
  const tags = [];
  const seen = new Set();
  const addTag = (raw) => {
    const t = String(raw ?? '')
      .trim()
      .replace(/^#/, '');
    if (!t || t.length > 32) return;
    const key = t.toLowerCase();
    if (seen.has(key)) return;
    seen.add(key);
    tags.push(t);
  };

  const textExtra = Array.isArray(aweme?.text_extra) ? aweme.text_extra : [];
  for (const te of textExtra) {
    if (te?.hashtag_name) addTag(te.hashtag_name);
  }

  const desc = String(aweme?.desc || '');
  for (const m of desc.matchAll(/#([^\s#@]{1,30})/g)) {
    if (m[1]) addTag(m[1]);
  }
  return tags.slice(0, 12);
}

function sanitizeDouyinHandle(author) {
  const uniqueId = String(author?.unique_id || '').trim();
  if (uniqueId && uniqueId !== '0' && !uniqueId.startsWith('MS4wLjAB')) return uniqueId;
  const shortId = String(author?.short_id || '').trim();
  if (shortId && shortId !== '0' && !shortId.startsWith('MS4wLjAB')) return shortId;
  return '';
}

function parseDouyinDurationSeconds(aweme) {
  const raw = aweme?.video?.duration ?? aweme?.duration;
  const num = Number(raw);
  if (!Number.isFinite(num) || num <= 0) return null;
  // Douyin API `video.duration` / `aweme.duration` is in milliseconds (e.g., 15400 -> 15.4s).
  const secs = num >= 1000 ? num / 1000 : num;
  return Math.round(secs * 10) / 10;
}

/**
 * Normalizes a single Douyin `aweme` API record into Charkle's unified social post object.
 */
export function normalizeDouyinAwemeItem(aweme, opts = {}) {
  if (!aweme || typeof aweme !== 'object') return null;
  const awemeId = String(aweme.aweme_id || aweme.awemeId || '').trim();
  if (!isValidDouyinAwemeId(awemeId)) return null;

  const imagesArr = Array.isArray(aweme.images) ? aweme.images : [];
  const isPhotoNote = imagesArr.length > 0 || Number(aweme.aweme_type) === 68;

  const author = aweme.author && typeof aweme.author === 'object' ? aweme.author : {};
  const authorName = String(author.nickname || '抖音用户').trim() || '抖音用户';
  const authorHandle = sanitizeDouyinHandle(author);
  const authorAvatarURL =
    pickBestDouyinImageUrl(
      author.avatar_medium?.url_list ||
        author.avatar_thumb?.url_list ||
        author.avatar_larger?.url_list ||
        [],
    ) || null;

  const desc = String(aweme.desc || '').trim();
  const title = deriveDouyinTitle(aweme.item_title || aweme.preview_title, desc);
  const dates = formatDouyinCreateTime(aweme.create_time);
  const stats = aweme.statistics && typeof aweme.statistics === 'object' ? aweme.statistics : {};
  const likeCount = parseDouyinMetricCount(stats.digg_count);
  const replyCount = parseDouyinMetricCount(stats.comment_count);
  const repostCount = parseDouyinMetricCount(stats.share_count);
  const viewCount = parseDouyinMetricCount(stats.play_count);
  const tags = extractDouyinTags(aweme);

  const media = [];
  const seenUrls = new Set();
  let hasVideo = false;
  let videoURL = null;
  let durationSeconds = null;

  if (isPhotoNote && imagesArr.length > 0) {
    for (const imgObj of imagesArr) {
      if (!imgObj || typeof imgObj !== 'object') continue;
      const url =
        pickBestDouyinImageUrl(imgObj.url_list) ||
        pickBestDouyinImageUrl(imgObj.download_url_list);
      if (!url || seenUrls.has(url)) continue;
      seenUrls.add(url);
      media.push({
        kind: 'photo',
        url,
        thumbnailURL: url,
        width: Number(imgObj.width || 0) || 0,
        height: Number(imgObj.height || 0) || 0,
      });
    }
  } else {
    const videoObj = aweme.video && typeof aweme.video === 'object' ? aweme.video : {};
    const coverUrl =
      pickBestDouyinImageUrl(videoObj.origin_cover?.url_list) ||
      pickBestDouyinImageUrl(videoObj.cover?.url_list) ||
      pickBestDouyinImageUrl(videoObj.dynamic_cover?.url_list) ||
      '';
    videoURL = pickBestDouyinVideoUrl(videoObj);
    durationSeconds = parseDouyinDurationSeconds(aweme);
    const width = Number(videoObj.width || videoObj.play_addr?.width || 0) || 0;
    const height = Number(videoObj.height || videoObj.play_addr?.height || 0) || 0;
    hasVideo = true;

    if (videoURL) {
      seenUrls.add(videoURL);
      media.push({
        kind: 'video',
        url: videoURL,
        thumbnailURL: coverUrl || null,
        width,
        height,
      });
    } else if (coverUrl) {
      seenUrls.add(coverUrl);
      media.push({
        kind: 'photo',
        url: coverUrl,
        thumbnailURL: coverUrl,
        width,
        height,
      });
    }
  }

  const originalURL = isPhotoNote
    ? `https://www.douyin.com/note/${awemeId}`
    : `https://www.douyin.com/video/${awemeId}`;

  return {
    platform: 'douyin',
    postID: awemeId,
    tweetID: awemeId,
    videoID: awemeId,
    originalURL,
    dedupKey: `douyin:${awemeId}`,
    authorName,
    authorHandle,
    authorAvatarURL,
    publishedAtText: dates.publishedAtText,
    publishedDateKey: dates.publishedDateKey,
    title,
    articleTitle: title || null,
    bodyText: desc || title || originalURL,
    isRetweet: false,
    likeCount,
    replyCount,
    repostCount,
    viewCount,
    durationSeconds,
    videoDurationSeconds: durationSeconds,
    media,
    hasVideo,
    videoURL,
    needsEnrich: false,
    referer: 'https://www.douyin.com/',
    tags,
    collectionId: opts.collectionId ? String(opts.collectionId) : null,
    collectionName: opts.collectionName ? String(opts.collectionName).trim() || null : null,
  };
}

/**
 * Extracts normalized Douyin posts from any Web API payload (`listcollection`, `collects/video/list`,
 * `favorite`, `post`, `detail`, etc.).
 */
export function extractDouyinPostsFromPayload(payload, opts = {}) {
  if (!payload || typeof payload !== 'object') return [];
  const candidates = [];

  const pushArray = (arr) => {
    if (!Array.isArray(arr)) return;
    for (const entry of arr) {
      if (!entry || typeof entry !== 'object') continue;
      if (entry.aweme_id || entry.awemeId) {
        candidates.push(entry);
      } else if (entry.aweme && typeof entry.aweme === 'object') {
        candidates.push(entry.aweme);
      } else if (entry.aweme_info && typeof entry.aweme_info === 'object') {
        candidates.push(entry.aweme_info);
      }
    }
  };

  pushArray(payload.aweme_list);
  pushArray(payload.aweme_details);
  pushArray(payload.item_list);
  pushArray(payload.cards);
  if (payload.aweme_detail && typeof payload.aweme_detail === 'object') {
    candidates.push(payload.aweme_detail);
  }
  if (payload.data && typeof payload.data === 'object') {
    pushArray(payload.data.aweme_list);
    pushArray(payload.data.aweme_details);
    pushArray(payload.data.item_list);
    if (payload.data.aweme_detail && typeof payload.data.aweme_detail === 'object') {
      candidates.push(payload.data.aweme_detail);
    }
  }

  const byId = new Map();
  for (const rawAweme of candidates) {
    const rec = normalizeDouyinAwemeItem(rawAweme, opts);
    if (!rec) continue;
    const prev = byId.get(rec.postID);
    const prevScore = prev ? (prev.media?.length || 0) * 10 + (prev.videoURL ? 2 : 0) : -1;
    const nextScore = (rec.media?.length || 0) * 10 + (rec.videoURL ? 2 : 0);
    if (!prev || nextScore >= prevScore) {
      byId.set(rec.postID, rec);
    }
  }
  return Array.from(byId.values());
}

/**
 * Extracts Douyin collection folder directory entries (`collects_id -> collects_name`)
 * from `/aweme/v1/web/collects/list/` payloads.
 */
export function extractDouyinCollectionsFromPayload(payload) {
  if (!payload || typeof payload !== 'object') return [];
  const rawList = Array.isArray(payload.collects_list)
    ? payload.collects_list
    : Array.isArray(payload.data?.collects_list)
      ? payload.data.collects_list
      : Array.isArray(payload.favorite_folder_list)
        ? payload.favorite_folder_list
        : [];
  const byId = new Map();
  for (const item of rawList) {
    if (!item || typeof item !== 'object') continue;
    const id = String(item.collects_id_str || item.collects_id || item.id_str || item.id || '').trim();
    const name = String(item.collects_name || item.name || item.title || '').trim();
    if (!id || !name) continue;
    const totalCount = parseDouyinMetricCount(item.total_number ?? item.item_count ?? item.count);
    byId.set(id, { id, name, totalCount });
  }
  return Array.from(byId.values());
}
