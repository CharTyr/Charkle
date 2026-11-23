import type { UUID } from '@charkle/shared';

export interface LayoutRect {
  left: number;
  top: number;
  width: number;
  height: number;
}

export interface ZoomLayoutItem extends LayoutRect {
  id: UUID;
}

export interface SessionZoomAnchor {
  assetID: UUID;
  normU: number;
  normV: number;
  screenY: number;
}

export interface AnchoredScrollYParams {
  oldScrollY: number;
  oldAnchorRect: LayoutRect;
  newAnchorRect: LayoutRect;
  anchorNormV: number;
  anchorScreenY: number;
  topInset?: number;
  totalHeight: number;
  viewportHeight: number;
  newOpticalScale?: number;
  opticalAnchorScreenY?: number;
}

export interface RevealScrollYParams {
  itemRect: LayoutRect;
  topInset: number;
  bottomInset?: number;
  totalHeight: number;
  viewportHeight: number;
}

export interface PickSessionZoomAnchorParams {
  items: readonly ZoomLayoutItem[];
  scrollTop: number;
  viewportHeight: number;
  viewportWidth?: number;
  topInset?: number;
  pointerPoint?: { x: number; y: number } | null;
  selectedAssetIDs?: ReadonlySet<UUID>;
  existingAnchor?: SessionZoomAnchor | null;
  forceCursorLookup?: boolean;
}

export type ArrowDirection = 'ArrowUp' | 'ArrowDown' | 'ArrowLeft' | 'ArrowRight';

function clamp(min: number, max: number, value: number): number {
  return Math.max(min, Math.min(max, value));
}

/**
 * Computes the next discrete column-stepped target width so toolbar `−` / `+` buttons
 * (and optical pinch commits) always move cleanly by exactly 1 column in Vertical Masonry,
 * avoiding dead clicks or 2-column jumps (`DESIGN.md` Photos-style zoom).
 *
 * `deltaColumns = -1` -> zoom IN (fewer, larger columns)
 * `deltaColumns = +1` -> zoom OUT (more, smaller columns)
 */
export function steppedColumnWidth(
  containerWidth: number,
  currentColWidth: number,
  deltaColumns: -1 | 1,
  spacing = 12,
  horizontalPadding = 20,
): number {
  const usableWidth = Math.max(240, containerWidth - horizontalPadding * 2);
  const currentCols = Math.max(
    2,
    Math.min(10, Math.floor((usableWidth + spacing) / Math.max(120, currentColWidth + spacing))),
  );
  const targetCols = clamp(2, 10, currentCols + deltaColumns);

  if (targetCols === currentCols) {
    return Math.round(clamp(130, 420, currentColWidth - deltaColumns * 30));
  }

  // Pick a targetColumnWidth cleanly inside the band that produces `targetCols`
  const maxWidthForTarget = (usableWidth - (targetCols - 1) * spacing) / targetCols;
  const minWidthForTarget = (usableWidth - targetCols * spacing) / (targetCols + 1);
  const midTarget = Math.floor((maxWidthForTarget + minWidthForTarget) * 0.5);
  const candidate = clamp(130, 420, midTarget);

  // Verify the candidate maps to targetCols when within [130, 420]
  const resolvedCols = Math.max(
    2,
    Math.min(10, Math.floor((usableWidth + spacing) / Math.max(120, candidate + spacing))),
  );
  if (resolvedCols === targetCols) {
    return Math.round(candidate);
  }
  return Math.round(clamp(130, 420, Math.floor(maxWidthForTarget) - 1));
}

/**
 * Precomputes prefix maximum bottom (`top + height`) for a list whose `top` is monotonically
 * non-decreasing, enabling O(log N + K) visible window slicing via `visibleItemsBinaryRange`.
 */
export function buildPrefixMaxBottom<T extends { top: number; height: number }>(
  items: readonly T[],
): number[] {
  const prefix = new Array<number>(items.length);
  let maxB = -Infinity;
  for (let i = 0; i < items.length; i++) {
    const b = items[i].top + items[i].height;
    if (b > maxB) maxB = b;
    prefix[i] = maxB;
  }
  return prefix;
}

/**
 * O(log N + K) visible slice for monotonically non-decreasing `top` layout arrays.
 */
export function visibleItemsBinaryRange<T extends { top: number; height: number }>(
  items: readonly T[],
  prefixMaxBottom: readonly number[],
  minY: number,
  maxY: number,
): T[] {
  const n = items.length;
  if (n === 0) return [];

  // First index where prefixMaxBottom[i] >= minY
  let lo = 0;
  let hi = n;
  while (lo < hi) {
    const mid = (lo + hi) >>> 1;
    if (prefixMaxBottom[mid] < minY) lo = mid + 1;
    else hi = mid;
  }
  const start = lo;
  if (start >= n) return [];

  // First index where items[i].top > maxY
  lo = start;
  hi = n;
  while (lo < hi) {
    const mid = (lo + hi) >>> 1;
    if (items[mid].top <= maxY) lo = mid + 1;
    else hi = mid;
  }
  const end = lo;

  const result: T[] = [];
  for (let i = start; i < end; i++) {
    const item = items[i];
    if (item.top + item.height >= minY && item.top <= maxY) {
      result.push(item);
    }
  }
  return result;
}

/**
 * Spatial 2D keyboard arrow navigation (`↑↓←→`) over laid-out gallery cards (Masonry or Justified).
 * - `← / →` step to the visually adjacent card on the same horizontal band, wrapping to previous/next
 *   index at row edges for seamless keyboard browsing.
 * - `↑ / ↓` move to the closest card above/below with strong column-overlap preference.
 */
export function findSpatialArrowTarget(
  items: readonly ZoomLayoutItem[],
  currentID: UUID | null,
  direction: ArrowDirection,
): UUID | null {
  if (items.length === 0) return null;
  if (!currentID) return items[0].id;

  const curIdx = items.findIndex((it) => it.id === currentID);
  if (curIdx < 0) return items[0].id;

  const cur = items[curIdx];
  const curCx = cur.left + cur.width * 0.5;
  const curCy = cur.top + cur.height * 0.5;
  const curRight = cur.left + cur.width;
  const curBottom = cur.top + cur.height;

  if (direction === 'ArrowLeft' || direction === 'ArrowRight') {
    const isLeft = direction === 'ArrowLeft';
    let best: ZoomLayoutItem | null = null;
    let bestScore = Infinity;

    for (const item of items) {
      if (item.id === cur.id) continue;
      const cx = item.left + item.width * 0.5;
      const dx = isLeft ? curCx - cx : cx - curCx;
      if (dx <= 6) continue;

      const overlapY = Math.min(curBottom, item.top + item.height) - Math.max(cur.top, item.top);
      const minH = Math.min(cur.height, item.height);
      const cy = item.top + item.height * 0.5;
      const dy = Math.abs(cy - curCy);

      if (overlapY >= minH * 0.22 || dy <= cur.height * 0.55) {
        const score = dx + dy * 1.6;
        if (score < bestScore) {
          bestScore = score;
          best = item;
        }
      }
    }

    if (best) return best.id;
    const fallbackIdx = isLeft ? curIdx - 1 : curIdx + 1;
    if (fallbackIdx >= 0 && fallbackIdx < items.length) {
      return items[fallbackIdx].id;
    }
    return cur.id;
  }

  // Vertical movement (ArrowUp / ArrowDown)
  const isUp = direction === 'ArrowUp';
  let bestOverlap: ZoomLayoutItem | null = null;
  let bestOverlapScore = Infinity;
  let bestAny: ZoomLayoutItem | null = null;
  let bestAnyScore = Infinity;

  for (const item of items) {
    if (item.id === cur.id) continue;
    const cy = item.top + item.height * 0.5;
    const dy = isUp ? curCy - cy : cy - curCy;
    if (dy <= 10) continue;

    // Require target edge not to be strictly on the wrong side
    if (isUp && item.top >= cur.top - 2) continue;
    if (!isUp && item.top + item.height <= curBottom + 2) continue;

    const cx = item.left + item.width * 0.5;
    const dx = Math.abs(cx - curCx);
    const overlapX = Math.min(curRight, item.left + item.width) - Math.max(cur.left, item.left);
    const minW = Math.min(cur.width, item.width);

    if (overlapX > Math.min(20, minW * 0.2)) {
      const edgeGap = isUp
        ? Math.max(0, cur.top - (item.top + item.height))
        : Math.max(0, item.top - curBottom);
      const score = edgeGap + dy * 0.35 + dx * 2.0;
      if (score < bestOverlapScore) {
        bestOverlapScore = score;
        bestOverlap = item;
      }
    }

    const anyScore = dy + dx * 1.45;
    if (anyScore < bestAnyScore) {
      bestAnyScore = anyScore;
      bestAny = item;
    }
  }

  return (bestOverlap ?? bestAny)?.id ?? cur.id;
}

/**
 * Computes the exact post-zoom scrollTop that keeps an anchor asset's normalized vertical point
 * (`anchorNormV`) pinned to `anchorScreenY` on screen.
 * Row-1 cards at the very top (`oldScrollY <= 2 && oldAnchorRect.top <= topInset + 4`) stay flush
 * at `scrollTop = 0` beneath the floating top filter bar, while Row-2+ cards scroll automatically
 * to remain stationary under the user's eye even when zooming from `scrollTop = 0`.
 */
export function anchoredScrollY({
  oldScrollY,
  oldAnchorRect,
  newAnchorRect,
  anchorNormV,
  anchorScreenY,
  topInset = 76,
  totalHeight,
  viewportHeight,
  newOpticalScale = 1,
  opticalAnchorScreenY = 0,
}: AnchoredScrollYParams): number {
  const maxScrollY = Math.max(0, totalHeight - viewportHeight);
  if (oldScrollY <= 2 && oldAnchorRect.top <= topInset + 4) {
    return 0;
  }
  const newAnchorPointY = newAnchorRect.top + anchorNormV * newAnchorRect.height;
  const safeScale = Math.max(0.1, newOpticalScale);
  const targetRawY = opticalAnchorScreenY + (anchorScreenY - opticalAnchorScreenY) / safeScale;
  return clamp(0, maxScrollY, newAnchorPointY - targetRawY);
}

/**
 * Computes the clamped vertical scrollTop that centers `itemRect` vertically within the usable
 * viewport band `[topInset, viewportHeight - min(bottomInset, viewportHeight * 0.25)]`.
 */
export function revealScrollY({
  itemRect,
  topInset,
  bottomInset = 64,
  totalHeight,
  viewportHeight,
}: RevealScrollYParams): number {
  const maxScrollY = Math.max(0, totalHeight - viewportHeight);
  if (maxScrollY <= 0) return 0;
  const usableHeight = Math.max(
    80,
    viewportHeight - topInset - Math.min(bottomInset, viewportHeight * 0.25),
  );
  const targetCenterY = topInset + usableHeight * 0.5;
  const itemMidY = itemRect.top + itemRect.height * 0.5;
  return clamp(0, maxScrollY, itemMidY - targetCenterY);
}

/**
 * Selects or reuses the persistent exact-asset zoom anchor across consecutive zoom steps:
 * Priority: 1) exact card under cursor (`pointerPoint`) > 2) existing `sessionZoomAnchor` >
 * 3) visible selected card nearest center > 4) card nearest cursor > 5) card nearest viewport center.
 */
export function pickSessionZoomAnchor({
  items,
  scrollTop,
  viewportHeight,
  viewportWidth = 960,
  topInset = 0,
  pointerPoint = null,
  selectedAssetIDs,
  existingAnchor = null,
  forceCursorLookup = false,
}: PickSessionZoomAnchorParams): { anchor: SessionZoomAnchor; item: ZoomLayoutItem } | null {
  if (items.length === 0) return null;

  const byID = new Map<UUID, ZoomLayoutItem>();
  for (const item of items) {
    byID.set(item.id, item);
  }

  const makeAnchor = (
    item: ZoomLayoutItem,
    hitPoint: { x: number; y: number } | null,
  ): SessionZoomAnchor => {
    let normU = 0.5;
    let normV = 0.5;
    if (hitPoint && item.width > 1 && item.height > 1) {
      normU = clamp(0.05, 0.95, (hitPoint.x - item.left) / item.width);
      normV = clamp(0.05, 0.95, (hitPoint.y - item.top) / item.height);
    }
    const screenY = item.top + normV * item.height - scrollTop;
    return { assetID: item.id, normU, normV, screenY };
  };

  // 1. Direct pointer hit on a specific card (wheel / pinch over card)
  if (forceCursorLookup && pointerPoint) {
    const hit = items.find(
      (item) =>
        pointerPoint.x >= item.left &&
        pointerPoint.x <= item.left + item.width &&
        pointerPoint.y >= item.top &&
        pointerPoint.y <= item.top + item.height,
    );
    if (hit) {
      if (existingAnchor && existingAnchor.assetID === hit.id) {
        return { anchor: existingAnchor, item: hit };
      }
      return { anchor: makeAnchor(hit, pointerPoint), item: hit };
    }
  }

  // 2. Reuse existing session anchor across consecutive zoom steps
  if (existingAnchor) {
    const existingItem = byID.get(existingAnchor.assetID);
    if (existingItem) {
      return { anchor: existingAnchor, item: existingItem };
    }
  }

  const visTop = scrollTop + topInset;
  const visBottom = scrollTop + viewportHeight;
  const visMidX = viewportWidth * 0.5;
  const visMidY = visTop + Math.max(40, visBottom - visTop) * 0.5;

  const isVisible = (item: ZoomLayoutItem) =>
    item.top + item.height >= scrollTop && item.top <= visBottom;

  // 3. Visible selected card nearest viewport center
  if (selectedAssetIDs && selectedAssetIDs.size > 0) {
    let bestSelected: ZoomLayoutItem | null = null;
    let bestDist = Infinity;
    for (const id of selectedAssetIDs) {
      const item = byID.get(id);
      if (!item || !isVisible(item)) continue;
      const dist = Math.hypot(
        item.left + item.width * 0.5 - visMidX,
        item.top + item.height * 0.5 - visMidY,
      );
      if (dist < bestDist) {
        bestDist = dist;
        bestSelected = item;
      }
    }
    if (bestSelected) {
      return { anchor: makeAnchor(bestSelected, null), item: bestSelected };
    }
  }

  // 4. Card nearest cursor if cursor is inside viewport
  if (pointerPoint) {
    let nearestCursor: ZoomLayoutItem | null = null;
    let bestDist = Infinity;
    for (const item of items) {
      if (item.top + item.height < scrollTop - 60 || item.top > visBottom + 60) continue;
      const dist = Math.hypot(
        item.left + item.width * 0.5 - pointerPoint.x,
        item.top + item.height * 0.5 - pointerPoint.y,
      );
      if (dist < bestDist) {
        bestDist = dist;
        nearestCursor = item;
      }
    }
    if (nearestCursor) {
      return { anchor: makeAnchor(nearestCursor, null), item: nearestCursor };
    }
  }

  // 5. Card nearest viewport center
  let bestCenter: ZoomLayoutItem | null = null;
  let bestDist = Infinity;
  for (const item of items) {
    if (!isVisible(item)) continue;
    const dist = Math.hypot(
      item.left + item.width * 0.5 - visMidX,
      item.top + item.height * 0.5 - visMidY,
    );
    if (dist < bestDist) {
      bestDist = dist;
      bestCenter = item;
    }
  }
  const chosen = bestCenter ?? items[0];
  return { anchor: makeAnchor(chosen, null), item: chosen };
}
