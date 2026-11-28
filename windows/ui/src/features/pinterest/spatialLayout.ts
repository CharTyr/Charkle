//! Pure 2D spatial layout engine & cursor-anchored camera for the Pinterest Infinite Space.
//! Mirrors `Sources/CharkleCore/Services/Pinterest/PinterestModels.swift` and
//! `windows/crates/charkle-core/src/pinterest/models.rs` 1:1.

import type { PinterestPin } from '../../types/domain';

export interface SpatialPoint {
  x: number;
  y: number;
}

export interface SpatialSize {
  width: number;
  height: number;
}

export interface SpatialRect {
  x: number;
  y: number;
  width: number;
  height: number;
}

export interface PinterestSpatialCard {
  id: string;
  pin: PinterestPin;
  frame: SpatialRect;
  columnIndex: number;
  ringIndex: number;
}

export function pinAspectRatio(pin: Pick<PinterestPin, 'pixelWidth' | 'pixelHeight'>): number {
  if (
    Number.isFinite(pin.pixelWidth) &&
    Number.isFinite(pin.pixelHeight) &&
    pin.pixelWidth > 0 &&
    pin.pixelHeight > 0
  ) {
    return Math.min(2.1, Math.max(0.45, pin.pixelWidth / pin.pixelHeight));
  }
  return 0.78;
}

export function pinDisplayTitle(
  pin: Pick<PinterestPin, 'id' | 'title' | 'description' | 'boardName'>,
): string {
  const title = pin.title.trim();
  if (title) return title;
  const desc = pin.description.trim();
  if (desc) return desc.slice(0, 72);
  const board = pin.boardName?.trim();
  if (board) return board;
  return `Pinterest ${pin.id}`;
}

export function pinDisplayImageUrl(
  pin: Pick<PinterestPin, 'thumbnailURL' | 'previewURL' | 'originalURL'>,
  renderedWidth: number,
): string | undefined {
  if (renderedWidth <= 150) {
    return pin.thumbnailURL || pin.previewURL || pin.originalURL || undefined;
  }
  if (renderedWidth <= 420) {
    return pin.previewURL || pin.originalURL || pin.thumbnailURL || undefined;
  }
  return pin.originalURL || pin.previewURL || pin.thumbnailURL || undefined;
}

export function rectsIntersect(a: SpatialRect, b: SpatialRect): boolean {
  return (
    a.x < b.x + b.width &&
    a.x + a.width > b.x &&
    a.y < b.y + b.height &&
    a.y + a.height > b.y
  );
}

export function rectInset(r: SpatialRect, dx: number, dy: number): SpatialRect {
  return {
    x: r.x + dx,
    y: r.y + dy,
    width: r.width - dx * 2,
    height: r.height - dy * 2,
  };
}

export function rectUnion(a: SpatialRect, b: SpatialRect): SpatialRect {
  if (a.width === 0 && a.height === 0) return { ...b };
  const minX = Math.min(a.x, b.x);
  const minY = Math.min(a.y, b.y);
  const maxX = Math.max(a.x + a.width, b.x + b.width);
  const maxY = Math.max(a.y + a.height, b.y + b.height);
  return {
    x: minX,
    y: minY,
    width: maxX - minX,
    height: maxY - minY,
  };
}

interface ColumnBounds {
  topY: number;
  bottomY: number;
}

const COLUMN_STAGGER_PATTERN = [0, 38, -28, 52, -18, 26, -44];

/**
 * Deterministic, append-only bidirectional infinite masonry layout centered around `(0, 0)`.
 * Existing cards NEVER move when appending new pages (0px jump), cards expand across all
 * four quadrants without overlap, and viewport culling / directional prefetch stay O(N).
 */
export class PinterestSpatialLayout {
  readonly cardWidth: number;
  readonly gap: number;

  private _cards: PinterestSpatialCard[] = [];
  private placedIds = new Set<string>();
  private columns = new Map<number, ColumnBounds>();
  private activeRadius = 2;
  private _contentBounds: SpatialRect = { x: 0, y: 0, width: 0, height: 0 };

  constructor(cardWidth = 224, gap = 16) {
    this.cardWidth = Math.max(120, cardWidth);
    this.gap = Math.max(6, gap);
  }

  get cards(): readonly PinterestSpatialCard[] {
    return this._cards;
  }

  get contentBounds(): SpatialRect {
    return this._contentBounds;
  }

  reset(): void {
    this._cards = [];
    this.placedIds.clear();
    this.columns.clear();
    this.activeRadius = 2;
    this._contentBounds = { x: 0, y: 0, width: 0, height: 0 };
  }

  append(pins: readonly PinterestPin[]): PinterestSpatialCard[] {
    const inserted: PinterestSpatialCard[] = [];
    const stride = this.cardWidth + this.gap;

    for (const pin of pins) {
      if (this.placedIds.has(pin.id)) continue;
      this.placedIds.add(pin.id);

      const desiredRadius = Math.max(2, Math.floor(Math.sqrt(this._cards.length + 1) * 0.62) + 1);
      if (desiredRadius > this.activeRadius) {
        this.activeRadius = desiredRadius;
      }

      const ratio = pinAspectRatio(pin);
      const cardHeight = Math.round(Math.min(460, Math.max(110, this.cardWidth / ratio)));

      let bestCol = 0;
      let bestY = 0;
      let bestPlaceSouth = true;
      let bestScore = Number.POSITIVE_INFINITY;

      for (let col = -this.activeRadius; col <= this.activeRadius; col += 1) {
        const colCenterX = col * stride;
        const bounds = this.columns.get(col);
        if (bounds) {
          const southY = bounds.bottomY + this.gap;
          const southCenterY = southY + cardHeight * 0.5;
          const southDist = Math.hypot(colCenterX, southCenterY);
          if (southDist < bestScore) {
            bestScore = southDist;
            bestCol = col;
            bestY = southY;
            bestPlaceSouth = true;
          }

          const northY = bounds.topY - this.gap - cardHeight;
          const northCenterY = northY + cardHeight * 0.5;
          const northDist = Math.hypot(colCenterX, northCenterY);
          if (northDist < bestScore) {
            bestScore = northDist;
            bestCol = col;
            bestY = northY;
            bestPlaceSouth = false;
          }
        } else {
          const stagger = this.columnStagger(col);
          const initialY = -cardHeight * 0.5 + stagger;
          const centerY = initialY + cardHeight * 0.5;
          const dist = Math.hypot(colCenterX, centerY);
          if (dist < bestScore) {
            bestScore = dist;
            bestCol = col;
            bestY = initialY;
            bestPlaceSouth = true;
          }
        }
      }

      const frameX = bestCol * stride - this.cardWidth * 0.5;
      const frame: SpatialRect = {
        x: frameX,
        y: bestY,
        width: this.cardWidth,
        height: cardHeight,
      };

      const existing = this.columns.get(bestCol);
      if (existing) {
        if (bestPlaceSouth) {
          existing.bottomY = frame.y + frame.height;
        } else {
          existing.topY = frame.y;
        }
      } else {
        this.columns.set(bestCol, {
          topY: frame.y,
          bottomY: frame.y + frame.height,
        });
      }

      const midX = frame.x + frame.width * 0.5;
      const midY = frame.y + frame.height * 0.5;
      const ringIndex = Math.round(Math.hypot(midX, midY) / Math.max(1, stride));
      const card: PinterestSpatialCard = {
        id: pin.id,
        pin,
        frame,
        columnIndex: bestCol,
        ringIndex,
      };
      this._cards.push(card);
      inserted.push(card);

      if (this._cards.length === 1) {
        this._contentBounds = { ...frame };
      } else {
        this._contentBounds = rectUnion(this._contentBounds, frame);
      }
    }

    return inserted;
  }

  visibleCards(worldRect: SpatialRect, overscan = 320): PinterestSpatialCard[] {
    const query = rectInset(worldRect, -overscan, -overscan);
    return this._cards.filter((card) => rectsIntersect(card.frame, query));
  }

  isApproachingEdge(worldRect: SpatialRect, threshold = 460): boolean {
    if (this._cards.length === 0) return true;
    const b = this._contentBounds;
    return (
      worldRect.x <= b.x + threshold ||
      worldRect.x + worldRect.width >= b.x + b.width - threshold ||
      worldRect.y <= b.y + threshold ||
      worldRect.y + worldRect.height >= b.y + b.height - threshold
    );
  }

  predictivePrefetchCards(
    worldRect: SpatialRect,
    lookaheadOffset: SpatialSize,
    halo = 720,
    limit = 36,
  ): PinterestSpatialCard[] {
    if (this._cards.length === 0 || limit <= 0) return [];
    const projected: SpatialRect = {
      x: worldRect.x + lookaheadOffset.width,
      y: worldRect.y + lookaheadOffset.height,
      width: worldRect.width,
      height: worldRect.height,
    };
    const searchRect = rectInset(rectUnion(worldRect, projected), -halo, -halo);
    const focusX = worldRect.x + worldRect.width * 0.5 + lookaheadOffset.width * 0.72;
    const focusY = worldRect.y + worldRect.height * 0.5 + lookaheadOffset.height * 0.72;

    const scored: Array<{ card: PinterestSpatialCard; distSq: number }> = [];
    for (const card of this._cards) {
      if (!rectsIntersect(card.frame, searchRect) || rectsIntersect(card.frame, worldRect)) {
        continue;
      }
      const dx = card.frame.x + card.frame.width * 0.5 - focusX;
      const dy = card.frame.y + card.frame.height * 0.5 - focusY;
      scored.push({ card, distSq: dx * dx + dy * dy });
    }
    scored.sort((a, b) => a.distSq - b.distSq);
    return scored.slice(0, limit).map((s) => s.card);
  }

  private columnStagger(col: number): number {
    const idx = Math.abs(col) % COLUMN_STAGGER_PATTERN.length;
    const sign = col < 0 ? -1 : 1;
    return COLUMN_STAGGER_PATTERN[idx] * sign + (col === 0 ? 0 : this.gap * 0.25);
  }
}

export interface InfiniteSpatialCamera {
  offset: SpatialPoint;
  scale: number;
}

export const SPATIAL_CAMERA_MIN_SCALE = 0.24;
export const SPATIAL_CAMERA_MAX_SCALE = 3.2;
export const SPATIAL_CAMERA_DEFAULT_SCALE = 0.9;

function safeFinite(value: number, fallback: number): number {
  return Number.isFinite(value) ? value : fallback;
}

export function createCenteredCamera(
  viewport: SpatialSize,
  scale = SPATIAL_CAMERA_DEFAULT_SCALE,
): InfiniteSpatialCamera {
  const finiteScale = safeFinite(scale, SPATIAL_CAMERA_DEFAULT_SCALE);
  const clamped = Math.min(SPATIAL_CAMERA_MAX_SCALE, Math.max(SPATIAL_CAMERA_MIN_SCALE, finiteScale));
  const w = Math.max(0, safeFinite(viewport.width, 0));
  const h = Math.max(0, safeFinite(viewport.height, 0));
  return {
    scale: clamped,
    offset: {
      x: w * 0.5,
      y: h * 0.5,
    },
  };
}

export function cameraScreenToWorld(
  camera: InfiniteSpatialCamera,
  screen: SpatialPoint,
): SpatialPoint {
  const safeScale = Math.max(0.001, safeFinite(camera.scale, SPATIAL_CAMERA_DEFAULT_SCALE));
  const ox = safeFinite(camera.offset.x, 0);
  const oy = safeFinite(camera.offset.y, 0);
  const sx = safeFinite(screen.x, 0);
  const sy = safeFinite(screen.y, 0);
  return {
    x: (sx - ox) / safeScale,
    y: (sy - oy) / safeScale,
  };
}

export function cameraWorldToScreen(
  camera: InfiniteSpatialCamera,
  world: SpatialPoint,
): SpatialPoint {
  const safeScale = Math.max(0.001, safeFinite(camera.scale, SPATIAL_CAMERA_DEFAULT_SCALE));
  const ox = safeFinite(camera.offset.x, 0);
  const oy = safeFinite(camera.offset.y, 0);
  const wx = safeFinite(world.x, 0);
  const wy = safeFinite(world.y, 0);
  return {
    x: wx * safeScale + ox,
    y: wy * safeScale + oy,
  };
}

export function cameraZoomAt(
  camera: InfiniteSpatialCamera,
  newScale: number,
  anchor: SpatialPoint,
): InfiniteSpatialCamera {
  const finiteScale = safeFinite(newScale, safeFinite(camera.scale, SPATIAL_CAMERA_DEFAULT_SCALE));
  const clamped = Math.min(SPATIAL_CAMERA_MAX_SCALE, Math.max(SPATIAL_CAMERA_MIN_SCALE, finiteScale));
  const safeAnchor: SpatialPoint = {
    x: safeFinite(anchor.x, 0),
    y: safeFinite(anchor.y, 0),
  };
  const worldBefore = cameraScreenToWorld(camera, safeAnchor);
  return {
    scale: clamped,
    offset: {
      x: safeAnchor.x - worldBefore.x * clamped,
      y: safeAnchor.y - worldBefore.y * clamped,
    },
  };
}

export function cameraVisibleWorldRect(
  camera: InfiniteSpatialCamera,
  viewport: SpatialSize,
): SpatialRect {
  const w = Math.max(0, safeFinite(viewport.width, 0));
  const h = Math.max(0, safeFinite(viewport.height, 0));
  const tl = cameraScreenToWorld(camera, { x: 0, y: 0 });
  const br = cameraScreenToWorld(camera, { x: w, y: h });
  return {
    x: tl.x,
    y: tl.y,
    width: Math.max(0, br.x - tl.x),
    height: Math.max(0, br.y - tl.y),
  };
}
