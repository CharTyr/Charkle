import type { AssetRecord, GalleryLayoutMode } from '../../types/domain';

export const MIN_COLUMN_WIDTH = 130;
export const MAX_COLUMN_WIDTH = 420;
export const MIN_VERTICAL_COLUMNS = 2;
export const MAX_VERTICAL_COLUMNS = 10;

/**
 * Logarithmic ~18% density stops for Horizontal Justified mode (1:1 macOS `MasonryLayoutEngine.justifiedZoomStops`)
 * so slider drags, Ctrl+Wheel, and +/- clicks step cleanly without thrashing row breaks.
 */
export const JUSTIFIED_ZOOM_STOPS: readonly number[] = [130, 154, 182, 214, 252, 298, 354, 420];

export interface PlacedAssetFrame {
  asset: AssetRecord;
  index: number;
  x: number;
  y: number;
  width: number;
  height: number;
}

export interface MasonryLayoutResult {
  items: PlacedAssetFrame[];
  /** Monotonically non-decreasing running max of `items[0..i].y + height` for O(log N) culling. */
  prefixMaxY: number[];
  totalHeight: number;
  columnCount: number;
  columnWidth: number;
}

export interface ZoomAnchorState {
  assetId: string;
  normV: number;
  screenY: number;
  oldAnchorY: number;
}

export function prefersReducedMotion(): boolean {
  if (typeof window === 'undefined' || !window.matchMedia) return false;
  return window.matchMedia('(prefers-reduced-motion: reduce)').matches;
}

export function verticalColumnCount(
  usableWidth: number,
  targetColumnWidth: number,
  spacing = 12,
): number {
  const safeW = Math.max(240, usableWidth);
  const rawCols = Math.floor((safeW + spacing) / Math.max(120, targetColumnWidth + spacing));
  return Math.max(MIN_VERTICAL_COLUMNS, Math.min(MAX_VERTICAL_COLUMNS, rawCols));
}

export function verticalColumnWidth(
  usableWidth: number,
  columnCount: number,
  spacing = 12,
): number {
  const safeW = Math.max(240, usableWidth);
  const cols = Math.max(MIN_VERTICAL_COLUMNS, Math.min(MAX_VERTICAL_COLUMNS, columnCount));
  return (safeW - spacing * (cols - 1)) / cols;
}

export function minReachableVerticalColumns(usableWidth: number, spacing = 12): number {
  return verticalColumnCount(usableWidth, MAX_COLUMN_WIDTH, spacing);
}

export function maxReachableVerticalColumns(usableWidth: number, spacing = 12): number {
  return verticalColumnCount(usableWidth, MIN_COLUMN_WIDTH, spacing);
}

/**
 * Returns a stable interior `targetColumnWidth` guaranteed to resolve to `columnCount` columns
 * with maximum hysteresis margin on both sides (1:1 macOS `canonicalTargetWidth`).
 */
export function canonicalTargetWidth(
  columnCount: number,
  usableWidth: number,
  spacing = 12,
): number {
  const minCols = minReachableVerticalColumns(usableWidth, spacing);
  const maxCols = maxReachableVerticalColumns(usableWidth, spacing);
  const cols = Math.max(minCols, Math.min(maxCols, columnCount));
  const upper = verticalColumnWidth(usableWidth, cols, spacing);
  const lower = verticalColumnWidth(usableWidth, cols + 1, spacing);
  const clampedUpper = Math.min(MAX_COLUMN_WIDTH, upper);
  const clampedLower = Math.max(MIN_COLUMN_WIDTH, lower);
  let ideal: number;
  if (cols <= minCols) {
    ideal = Math.min(MAX_COLUMN_WIDTH, Math.max((clampedUpper + clampedLower) * 0.5, clampedUpper * 0.94));
  } else if (cols >= maxCols) {
    ideal = Math.max(MIN_COLUMN_WIDTH, Math.min((clampedUpper + clampedLower) * 0.5, clampedLower * 1.06));
  } else {
    ideal = (clampedUpper + clampedLower) * 0.5;
  }
  return Math.round(Math.max(MIN_COLUMN_WIDTH, Math.min(MAX_COLUMN_WIDTH, ideal)));
}

export function snappedJustifiedTargetWidth(rawWidth: number): number {
  const clamped = Math.max(MIN_COLUMN_WIDTH, Math.min(MAX_COLUMN_WIDTH, rawWidth));
  let best = JUSTIFIED_ZOOM_STOPS[0];
  let bestDist = Math.abs(clamped - best);
  for (let i = 1; i < JUSTIFIED_ZOOM_STOPS.length; i++) {
    const stop = JUSTIFIED_ZOOM_STOPS[i];
    const dist = Math.abs(clamped - stop);
    if (dist < bestDist) {
      bestDist = dist;
      best = stop;
    }
  }
  return best;
}

/**
 * Steps density cleanly by exactly 1 column (Vertical Masonry) or 1 logarithmic stop (Horizontal Justified).
 * `direction > 0` zooms IN (larger cards, fewer columns); `direction < 0` zooms OUT (smaller cards, more columns).
 */
export function steppedColumnWidth(
  currentWidth: number,
  direction: number,
  layoutMode: GalleryLayoutMode,
  usableWidth: number,
  spacing = 12,
): number {
  if (direction === 0) {
    return Math.max(MIN_COLUMN_WIDTH, Math.min(MAX_COLUMN_WIDTH, currentWidth));
  }
  const zoomIn = direction > 0;
  if (layoutMode === 'horizontalJustified') {
    const snapped = snappedJustifiedTargetWidth(currentWidth);
    const idx = Math.max(0, JUSTIFIED_ZOOM_STOPS.indexOf(snapped));
    const nextIdx = Math.max(0, Math.min(JUSTIFIED_ZOOM_STOPS.length - 1, idx + (zoomIn ? 1 : -1)));
    return JUSTIFIED_ZOOM_STOPS[nextIdx];
  }

  const minCols = minReachableVerticalColumns(usableWidth, spacing);
  const maxCols = maxReachableVerticalColumns(usableWidth, spacing);
  const currentCols = verticalColumnCount(usableWidth, currentWidth, spacing);
  const targetCols = Math.max(minCols, Math.min(maxCols, currentCols + (zoomIn ? -1 : 1)));
  return canonicalTargetWidth(targetCols, usableWidth, spacing);
}

/**
 * Exact macOS `MasonryLayoutEngine.effectiveAspectRatio` (width / height).
 */
export function effectiveAspectRatio(
  asset: AssetRecord,
  minRatio: number,
  maxRatio: number,
): number {
  const hasPixels = asset.pixelWidth > 0 && asset.pixelHeight > 0;
  const natural = hasPixels ? asset.pixelWidth / asset.pixelHeight : 1.25;
  let rawRatio: number;

  switch (asset.mediaKind) {
    case 'audio':
      rawRatio = 1.55;
      break;
    case 'webBookmark': {
      const social = asset.richMetadata?.socialPost;
      const lowerDomain = (asset.sourceDomain ?? '').toLowerCase();
      const lowerUrl = (asset.sourceURL ?? '').toLowerCase();
      const isVerticalSocialFeed =
        social?.platform === 'xiaohongshu' ||
        social?.platform === 'douyin' ||
        lowerDomain.includes('xiaohongshu') ||
        lowerDomain.includes('xhslink') ||
        lowerDomain.includes('douyin.com') ||
        lowerDomain.includes('iesdouyin.com') ||
        lowerUrl.includes('xiaohongshu') ||
        lowerUrl.includes('xhslink') ||
        lowerUrl.includes('douyin.com') ||
        lowerUrl.includes('iesdouyin.com');
      if (hasPixels) {
        rawRatio = natural;
      } else if (isVerticalSocialFeed) {
        rawRatio = 0.625;
      } else if (social) {
        rawRatio = 1.12;
      } else if (asset.richMetadata?.githubRepo) {
        rawRatio = 1.32;
      } else {
        rawRatio = 1.6;
      }
      break;
    }
    case 'document':
      rawRatio = asset.fileName.toLowerCase().endsWith('.swatch')
        ? 1.0
        : hasPixels
          ? natural
          : 0.84;
      break;
    case 'model3D':
      rawRatio = hasPixels ? natural : 1.0;
      break;
    default:
      rawRatio = natural;
      break;
  }

  return Math.max(minRatio, Math.min(maxRatio, rawRatio));
}

function buildPrefixMaxY(items: PlacedAssetFrame[]): number[] {
  const prefix = new Array<number>(items.length);
  let runningMax = 0;
  for (let i = 0; i < items.length; i++) {
    const bottom = items[i].y + items[i].height;
    if (bottom > runningMax) runningMax = bottom;
    prefix[i] = runningMax;
  }
  return prefix;
}

/**
 * Exact macOS `MasonryLayoutEngine.computeVertical` with `topInset`, `bottomInset`, and `prefixMaxY`.
 */
export function computeVerticalMasonry(
  assets: AssetRecord[],
  containerWidth: number,
  targetCardWidth: number,
  gap = 12,
  topInset = 0,
  bottomInset = 0,
): MasonryLayoutResult {
  const usableWidth = Math.max(240, containerWidth);
  const cols = verticalColumnCount(usableWidth, targetCardWidth, gap);
  const colWidth = (usableWidth - gap * (cols - 1)) / cols;
  const colHeights = new Array<number>(cols).fill(topInset);
  const items: PlacedAssetFrame[] = new Array(assets.length);

  for (let i = 0; i < assets.length; i++) {
    const asset = assets[i];
    let bestCol = 0;
    let minH = colHeights[0];
    for (let c = 1; c < cols; c++) {
      if (colHeights[c] < minH - 0.5) {
        minH = colHeights[c];
        bestCol = c;
      }
    }

    const ratio = effectiveAspectRatio(asset, 0.55, 2.15);
    const cardHeight = Math.round(colWidth / ratio);
    const x = bestCol * (colWidth + gap);
    const y = colHeights[bestCol];

    items[i] = {
      asset,
      index: i,
      x,
      y,
      width: colWidth,
      height: cardHeight,
    };
    colHeights[bestCol] = y + cardHeight + gap;
  }

  const maxColHeight = colHeights.length > 0 ? Math.max(...colHeights) : topInset;
  const totalHeight = Math.max(360, maxColHeight + bottomInset);
  return {
    items,
    prefixMaxY: buildPrefixMaxY(items),
    totalHeight,
    columnCount: cols,
    columnWidth: colWidth,
  };
}

/**
 * Exact macOS `MasonryLayoutEngine.computeJustified`:
 * Packs portrait, square, and landscape assets into equal-height rows flush left-to-right,
 * choosing optimal break-before vs break-after line breaks to stay closest to `idealRowH`.
 */
export function computeHorizontalJustified(
  assets: AssetRecord[],
  containerWidth: number,
  targetRowHeight: number,
  gap = 12,
  topInset = 0,
  bottomInset = 0,
): MasonryLayoutResult {
  const usableWidth = Math.max(240, containerWidth);
  const idealRowH = Math.max(104, Math.min(380, targetRowHeight));

  const items: PlacedAssetFrame[] = [];
  let row: Array<{ index: number; asset: AssetRecord; ratio: number }> = [];
  let ratioSum = 0;
  let cursorY = topInset;

  const flushRow = (justify: boolean) => {
    if (row.length === 0) return;
    const gaps = gap * (row.length - 1);
    const availableForItems = Math.max(60, usableWidth - gaps);
    const rawHeight = justify ? availableForItems / Math.max(0.1, ratioSum) : idealRowH;
    const rowHeight = Math.round(Math.max(84, Math.min(idealRowH * 1.48, rawHeight)));

    let cursorX = 0;
    for (let pos = 0; pos < row.length; pos++) {
      const entry = row[pos];
      const isLast = pos === row.length - 1;
      const itemW =
        justify && isLast
          ? Math.max(44, usableWidth - cursorX)
          : Math.max(44, Math.round(entry.ratio * rowHeight));
      items.push({
        asset: entry.asset,
        index: entry.index,
        x: cursorX,
        y: cursorY,
        width: itemW,
        height: rowHeight,
      });
      cursorX += itemW + gap;
    }

    cursorY += rowHeight + gap;
    row = [];
    ratioSum = 0;
  };

  for (let index = 0; index < assets.length; index++) {
    const asset = assets[index];
    const ratio = effectiveAspectRatio(asset, 0.48, 2.35);
    const projectedCount = row.length + 1;
    const projectedSum = ratioSum + ratio;
    const projectedWidth = projectedSum * idealRowH + gap * (projectedCount - 1);

    if (row.length > 0 && projectedWidth > usableWidth) {
      const hBefore = (usableWidth - gap * (row.length - 1)) / Math.max(0.1, ratioSum);
      const hAfter = (usableWidth - gap * (projectedCount - 1)) / Math.max(0.1, projectedSum);
      const errBefore = Math.abs(hBefore - idealRowH);
      const errAfter = Math.abs(hAfter - idealRowH);
      if (errAfter < errBefore && hAfter >= idealRowH * 0.68) {
        row.push({ index, asset, ratio });
        ratioSum = projectedSum;
        flushRow(true);
      } else {
        flushRow(true);
        row.push({ index, asset, ratio });
        ratioSum = ratio;
      }
    } else {
      row.push({ index, asset, ratio });
      ratioSum = projectedSum;
    }
  }

  if (row.length > 0) {
    const naturalW = ratioSum * idealRowH + gap * (row.length - 1);
    const shouldJustifyLast = naturalW >= usableWidth * 0.68;
    flushRow(shouldJustifyLast);
  }

  const totalHeight = Math.max(360, cursorY + bottomInset);
  const approxCols = Math.max(1, Math.round(usableWidth / Math.max(110, idealRowH)));
  return {
    items,
    prefixMaxY: buildPrefixMaxY(items),
    totalHeight,
    columnCount: approxCols,
    columnWidth: idealRowH,
  };
}

/**
 * O(log N + K) visible window query using `prefixMaxY` binary search
 * (exact port of macOS `MasonryLayoutSnapshot.visibleItems`).
 */
export function visibleItemsInRange(
  layout: MasonryLayoutResult,
  minY: number,
  maxY: number,
): PlacedAssetFrame[] {
  const { items, prefixMaxY } = layout;
  if (items.length === 0 || maxY < minY) return [];

  let lo = 0;
  let hi = items.length;
  while (lo < hi) {
    const mid = lo + ((hi - lo) >> 1);
    if (prefixMaxY[mid] < minY) {
      lo = mid + 1;
    } else {
      hi = mid;
    }
  }
  if (lo >= items.length) return [];

  const result: PlacedAssetFrame[] = [];
  for (let idx = lo; idx < items.length; idx++) {
    const item = items[idx];
    if (item.y > maxY) break;
    if (item.y + item.height >= minY) {
      result.push(item);
    }
  }
  return result;
}

/**
 * Computes exact post-zoom scroll origin Y pinning an anchor asset's normalized vertical point
 * (`anchorNormV`) to `anchorScreenY` on screen. Row-1 cards at the top (`oldScrollY <= 2 && oldAnchorY <= topInset + 4`)
 * remain cleanly flush at `scrollY = 0` so they never clip beneath the floating top pills, while Row-2+ cards
 * automatically scroll to remain stationary under the user's eye even when zooming from the top.
 */
export function anchoredScrollY(params: {
  oldScrollY: number;
  oldAnchorY: number;
  newAnchorY: number;
  newAnchorHeight: number;
  anchorNormV: number;
  anchorScreenY: number;
  topInset: number;
  totalHeight: number;
  viewportHeight: number;
}): number {
  const {
    oldScrollY,
    oldAnchorY,
    newAnchorY,
    newAnchorHeight,
    anchorNormV,
    anchorScreenY,
    topInset,
    totalHeight,
    viewportHeight,
  } = params;
  const maxScrollY = Math.max(0, totalHeight - viewportHeight);
  if (oldScrollY <= 2 && oldAnchorY <= topInset + 4) {
    return 0;
  }
  const newAnchorPointY = newAnchorY + anchorNormV * newAnchorHeight;
  return Math.max(0, Math.min(maxScrollY, newAnchorPointY - anchorScreenY));
}

/**
 * Computes clamped scroll origin centering an asset card inside the usable viewport
 * beneath `topInset` and above `bottomInset` (exact port of macOS `revealScrollY`).
 */
export function revealScrollY(params: {
  itemY: number;
  itemHeight: number;
  topInset: number;
  bottomInset: number;
  totalHeight: number;
  viewportHeight: number;
}): number {
  const { itemY, itemHeight, topInset, bottomInset, totalHeight, viewportHeight } = params;
  const maxScrollY = Math.max(0, totalHeight - viewportHeight);
  if (maxScrollY <= 0) return 0;
  const usableHeight = Math.max(
    80,
    viewportHeight - topInset - Math.min(bottomInset, viewportHeight * 0.25),
  );
  const targetCenterY = topInset + usableHeight * 0.5;
  return Math.max(0, Math.min(maxScrollY, itemY + itemHeight * 0.5 - targetCenterY));
}

/**
 * Pure GPU-composited FLIP reflow animation for Photos-style gallery zoom:
 * - Zero `width`/`height` CSS transitions (pure `transform` + `opacity` WAAPI).
 * - Compensates every card's start position by `ΔscrollY` for 0px Frame-0 jump.
 * - Exact anchor asset glides continuously on top; far-wrapping non-anchor cards softly crossfade
 *   in place (`scale(0.96 -> 1) + opacity(0 -> 1)`) instead of shooting across the viewport.
 */
export function runFlipZoomAnimations(params: {
  visibleItems: PlacedAssetFrame[];
  prevLayout: Map<string, PlacedAssetFrame>;
  cardElements: Map<string, HTMLDivElement>;
  oldScrollY: number;
  newScrollY: number;
  anchorAssetId: string | null;
  columnWidth: number;
}): void {
  if (prefersReducedMotion()) return;
  const {
    visibleItems,
    prevLayout,
    cardElements,
    oldScrollY,
    newScrollY,
    anchorAssetId,
    columnWidth,
  } = params;

  const maxGlideDistance = Math.max(columnWidth * 1.55, 290);
  const glideEasing = 'cubic-bezier(0.19, 1, 0.22, 1)';

  for (const item of visibleItems) {
    const el = cardElements.get(item.asset.id);
    if (!el || typeof el.animate !== 'function') continue;

    // Cancel any in-flight zoom animation so rapid zoom steps remain 100% interruptible
    if (typeof el.getAnimations === 'function') {
      for (const anim of el.getAnimations()) {
        anim.cancel();
      }
    }

    const oldItem = prevLayout.get(item.asset.id);
    const toX = Math.round(item.x);
    const toY = Math.round(item.y);
    const isAnchor = anchorAssetId !== null && item.asset.id === anchorAssetId;

    if (oldItem) {
      const fromX = oldItem.x;
      const fromY = oldItem.y - oldScrollY + newScrollY;
      const dx = fromX - toX;
      const dy = fromY - toY;
      const sx = oldItem.width / Math.max(1, item.width);
      const sy = oldItem.height / Math.max(1, item.height);
      const dist = Math.hypot(dx, dy);

      if (Math.abs(dx) < 0.5 && Math.abs(dy) < 0.5 && Math.abs(sx - 1) < 0.005 && Math.abs(sy - 1) < 0.005) {
        continue;
      }

      if (isAnchor || dist <= maxGlideDistance) {
        el.style.transformOrigin = 'top left';
        el.animate(
          [
            {
              transform: `translate3d(${Math.round(fromX)}px, ${Math.round(fromY)}px, 0) scale(${sx.toFixed(4)}, ${sy.toFixed(4)})`,
            },
            {
              transform: `translate3d(${toX}px, ${toY}px, 0) scale(1, 1)`,
            },
          ],
          {
            duration: 280,
            easing: glideEasing,
          },
        );
      } else {
        el.style.transformOrigin = 'center center';
        el.animate(
          [
            {
              opacity: 0,
              transform: `translate3d(${toX}px, ${toY}px, 0) scale(0.96)`,
            },
            {
              opacity: 1,
              transform: `translate3d(${toX}px, ${toY}px, 0) scale(1)`,
            },
          ],
          {
            duration: 220,
            easing: glideEasing,
          },
        );
      }
    } else {
      el.style.transformOrigin = 'center center';
      el.animate(
        [
          {
            opacity: 0,
            transform: `translate3d(${toX}px, ${toY}px, 0) scale(0.96)`,
          },
          {
            opacity: 1,
            transform: `translate3d(${toX}px, ${toY}px, 0) scale(1)`,
          },
        ],
        {
          duration: 220,
          easing: glideEasing,
        },
      );
    }
  }
}
