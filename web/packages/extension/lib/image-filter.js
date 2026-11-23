/**
 * Pure image candidate normalization, deduplication, resolution upgrade & sorting helpers.
 */

export const MIN_IMAGE_DIMENSION = 64;
export const LARGE_IMAGE_DIMENSION = 400;

/**
 * Parses an HTML srcset attribute and returns the highest-resolution candidate URL.
 */
export function parseSrcsetBestUrl(srcset, baseUrl = '') {
  if (!srcset || typeof srcset !== 'string') return '';
  let bestUrl = '';
  let bestScore = -1;

  // Split cautiously on commas that precede another URL candidate
  const entries = srcset.split(/,\s+(?=\S)/);
  for (const rawEntry of entries) {
    const trimmed = rawEntry.trim();
    if (!trimmed) continue;
    const parts = trimmed.split(/\s+/);
    const urlPart = parts[0];
    if (!urlPart || urlPart.startsWith('data:image/svg')) continue;

    let score = 1;
    const descriptor = parts[1] || '';
    const wMatch = /^(\d+)w$/i.exec(descriptor);
    const xMatch = /^(\d+(?:\.\d+)?)x$/i.exec(descriptor);
    if (wMatch) {
      score = Number.parseInt(wMatch[1], 10);
    } else if (xMatch) {
      score = Number.parseFloat(xMatch[1]) * 1000;
    }

    if (score >= bestScore) {
      try {
        bestUrl = baseUrl ? new URL(urlPart, baseUrl).href : urlPart;
        bestScore = score;
      } catch {
        // ignore unresolvable candidate
      }
    }
  }
  return bestUrl;
}

/**
 * Safely upgrades well-known low-res CDN preview URLs to high-resolution originals
 * while preserving query tokens required for signed CDNs.
 */
export function upgradeImageCandidateUrl(rawUrl) {
  if (!rawUrl || typeof rawUrl !== 'string') return '';
  const trimmed = rawUrl.trim();
  if (trimmed.startsWith('data:image/')) return trimmed;

  try {
    const u = new URL(trimmed);
    if (u.protocol !== 'http:' && u.protocol !== 'https:') return '';
    u.hash = '';

    // Twitter/X media CDN: upgrade name=small/medium/360x360/thumb -> name=large
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

export function isTinyOrTrackingImage(item, minDim = MIN_IMAGE_DIMENSION) {
  const url = String(item?.url || '');
  if (!url) return true;
  if (url.startsWith('javascript:') || url.startsWith('blob:')) return true;
  if (url.startsWith('data:image/svg+xml') && url.length < 2048) return true;

  const w = Number(item?.width || 0);
  const h = Number(item?.height || 0);
  if (w > 0 && h > 0) {
    if (w < minDim || h < minDim) return true;
  }
  // Filter well-known 1x1 analytics pixel URLs even when dimensions aren't measured
  if (/(?:^|[/?&])(pixel|beacon|spacer|blank|1x1)\.(gif|png)(?:$|[?#])/i.test(url)) {
    return true;
  }
  return false;
}

/**
 * Deduplicates, filters tiny images (< 64px), and sorts by pixel area descending.
 */
export function filterAndSortImages(candidates, options = {}) {
  const minDim = options.minDim ?? MIN_IMAGE_DIMENSION;
  const limit = options.limit ?? 60;
  const deduped = new Map();

  for (const raw of candidates || []) {
    const upgraded = upgradeImageCandidateUrl(raw?.url);
    if (!upgraded) continue;

    const width = Math.max(0, Math.round(Number(raw?.width || 0)));
    const height = Math.max(0, Math.round(Number(raw?.height || 0)));
    const candidate = {
      url: upgraded,
      width,
      height,
      alt: String(raw?.alt || '').trim().slice(0, 140),
      source: raw?.source || 'img', // 'img' | 'picture' | 'bg' | 'og'
    };

    if (isTinyOrTrackingImage(candidate, minDim)) continue;

    const existing = deduped.get(upgraded);
    if (!existing) {
      deduped.set(upgraded, candidate);
    } else {
      const existingArea = existing.width * existing.height;
      const nextArea = candidate.width * candidate.height;
      if (nextArea > existingArea) {
        deduped.set(upgraded, {
          ...candidate,
          alt: candidate.alt || existing.alt,
        });
      } else if (!existing.alt && candidate.alt) {
        existing.alt = candidate.alt;
      }
    }
  }

  const list = Array.from(deduped.values());
  list.sort((a, b) => {
    const areaA = a.width * a.height;
    const areaB = b.width * b.height;
    if (areaA !== areaB) return areaB - areaA;
    if (a.source === 'og' && b.source !== 'og') return -1;
    if (b.source === 'og' && a.source !== 'og') return 1;
    return a.url.localeCompare(b.url);
  });

  return list.slice(0, limit);
}

export function isLargeImageCandidate(item, threshold = LARGE_IMAGE_DIMENSION) {
  const w = Number(item?.width || 0);
  const h = Number(item?.height || 0);
  if (w === 0 && h === 0) return item?.source === 'og';
  return Math.max(w, h) >= threshold;
}
