import type { AssetRecord } from '../../types/domain';

/**
 * Configurable live tuning parameters for the 3D Outside Ring Gallery.
 * All defaults mirror the calibrated eye-level Outside ring geometry and depth-of-field spec.
 */
export interface RingGalleryParameters {
  slotCount: number;
  cardWidth: number;
  cardHeight: number;
  cardGap: number;
  perspective: number;
  depthBlur: number;
  farFade: number;
  cornerRadius: number;
  nearPlane: number;
}

export const DEFAULT_RING_GALLERY_PARAMS: Readonly<RingGalleryParameters> = {
  slotCount: 22,
  cardWidth: 180,
  cardHeight: 300,
  cardGap: 18,
  perspective: 1500,
  depthBlur: 2,
  farFade: 0.96,
  cornerRadius: 32,
  nearPlane: 140,
};

export const DEFAULT_RING_PARAMS: Readonly<RingGalleryParameters> = DEFAULT_RING_GALLERY_PARAMS;

export function createDefaultRingParams(): RingGalleryParameters {
  return { ...DEFAULT_RING_GALLERY_PARAMS };
}

export function ringStep(params: RingGalleryParameters): number {
  return params.cardWidth + params.cardGap;
}

export function ringCircumference(params: RingGalleryParameters): number {
  return params.slotCount * ringStep(params);
}

export function ringRadius(params: RingGalleryParameters): number {
  return ringCircumference(params) / (2.0 * Math.PI);
}

/** Outside view (`bend = -1`): signed curvature `c = -1 / R`. */
export function ringCurvature(params: RingGalleryParameters): number {
  return -1.0 / Math.max(1.0, ringRadius(params));
}

export function areRingParamsEqual(
  a: RingGalleryParameters,
  b: RingGalleryParameters,
): boolean {
  return (
    a.slotCount === b.slotCount &&
    a.cardWidth === b.cardWidth &&
    a.cardHeight === b.cardHeight &&
    a.cardGap === b.cardGap &&
    Math.abs(a.perspective - b.perspective) < 1e-6 &&
    Math.abs(a.depthBlur - b.depthBlur) < 1e-6 &&
    Math.abs(a.farFade - b.farFade) < 1e-6 &&
    Math.abs(a.cornerRadius - b.cornerRadius) < 1e-6 &&
    Math.abs(a.nearPlane - b.nearPlane) < 1e-6
  );
}

/** Deterministic CSS-equivalent `cubic-bezier(x1, y1, x2, y2)` solver. */
export class RingCubicBezier {
  static readonly dragGlide = new RingCubicBezier(0.25, 0.6, 0.2, 1.0);
  static readonly pressIn = new RingCubicBezier(0.23, 1.0, 0.32, 1.0);
  static readonly pressOut = new RingCubicBezier(0.22, 1.0, 0.36, 1.0);

  constructor(
    public readonly x1: number,
    public readonly y1: number,
    public readonly x2: number,
    public readonly y2: number,
  ) {}

  private sampleX(t: number): number {
    const u = 1.0 - t;
    return 3.0 * u * u * t * this.x1 + 3.0 * u * t * t * this.x2 + t * t * t;
  }

  private sampleDX(t: number): number {
    const u = 1.0 - t;
    return (
      3.0 * u * u * this.x1 +
      6.0 * u * t * (this.x2 - this.x1) +
      3.0 * t * t * (1.0 - this.x2)
    );
  }

  private sampleY(t: number): number {
    const u = 1.0 - t;
    return 3.0 * u * u * t * this.y1 + 3.0 * u * t * t * this.y2 + t * t * t;
  }

  evaluate(x: number): number {
    if (x <= 0) return 0;
    if (x >= 1) return 1;
    let t = x;
    for (let i = 0; i < 8; i++) {
      const err = this.sampleX(t) - x;
      if (Math.abs(err) < 1e-6) break;
      const dx = this.sampleDX(t);
      if (Math.abs(dx) < 1e-6) break;
      t = Math.min(1.0, Math.max(0.0, t - err / dx));
    }
    let lo = 0.0;
    let hi = 1.0;
    if (Math.abs(this.sampleX(t) - x) > 1e-4) {
      for (let i = 0; i < 12; i++) {
        const mid = 0.5 * (lo + hi);
        if (this.sampleX(mid) < x) lo = mid;
        else hi = mid;
      }
      t = 0.5 * (lo + hi);
    }
    return this.sampleY(t);
  }
}

export function clamp(v: number, lo: number, hi: number): number {
  return Math.min(hi, Math.max(lo, v));
}

export function smoothstep(edge0: number, edge1: number, x: number): number {
  const denom = edge1 - edge0;
  if (Math.abs(denom) < 1e-9) return x < edge0 ? 0.0 : 1.0;
  const t = clamp((x - edge0) / denom, 0.0, 1.0);
  return t * t * (3.0 - 2.0 * t);
}

/** Wraps signed arc coordinate into `[-circumference / 2, circumference / 2)`. */
export function wrapArc(value: number, circumference: number): number {
  if (!(circumference > 0)) return 0;
  const half = circumference * 0.5;
  let r = value % circumference;
  if (r >= half) r -= circumference;
  if (r < -half) r += circumference;
  return r;
}

/** Positive modulo index in `[0, count)`. */
export function positiveMod(index: number, count: number): number {
  if (count <= 0) return 0;
  const m = index % count;
  return m >= 0 ? m : m + count;
}

/** Euclidean floor division (`Math.floor(a / b)`) supporting negative indices cleanly. */
export function floorDiv(a: number, b: number): number {
  if (b <= 0) return 0;
  return Math.floor(a / b);
}

function isVerticalSocialFeedAsset(asset: AssetRecord): boolean {
  const platform = asset.richMetadata?.socialPost?.platform as string | undefined;
  if (platform === 'xiaohongshu' || platform === 'douyin') return true;
  const domain = (asset.sourceDomain ?? '').toLowerCase();
  if (
    domain.includes('xiaohongshu.com') ||
    domain.includes('xhslink.com') ||
    domain.includes('douyin.com') ||
    domain.includes('iesdouyin.com')
  ) {
    return true;
  }
  const url = (asset.sourceURL ?? '').toLowerCase();
  return (
    url.includes('xiaohongshu.com') ||
    url.includes('xhslink.com') ||
    url.includes('douyin.com') ||
    url.includes('iesdouyin.com')
  );
}

/** Natural aspect ratio per asset matching Horizontal Justified Masonry (zero landscape cropping). */
export function ringEffectiveAspectRatio(
  asset: AssetRecord,
  decodedAspectFallback?: number,
): number {
  const hasPixels = asset.pixelWidth > 0 && asset.pixelHeight > 0;
  const hasDecoded =
    typeof decodedAspectFallback === 'number' &&
    Number.isFinite(decodedAspectFallback) &&
    decodedAspectFallback > 0.05;
  const natural = hasPixels
    ? asset.pixelWidth / asset.pixelHeight
    : hasDecoded
      ? decodedAspectFallback
      : 1.0;
  let raw: number;

  switch (asset.mediaKind) {
    case 'audio':
      raw = 1.55;
      break;
    case 'webBookmark':
      if (hasPixels) {
        raw = natural;
      } else if (isVerticalSocialFeedAsset(asset)) {
        raw = 0.625;
      } else if (hasDecoded) {
        raw = decodedAspectFallback;
      } else if (asset.richMetadata?.socialPost) {
        raw = 1.12;
      } else if (asset.richMetadata?.githubRepo) {
        raw = 1.32;
      } else {
        raw = 1.6;
      }
      break;
    case 'document':
      if (asset.fileName.toLowerCase().endsWith('.swatch')) {
        raw = 1.0;
      } else if (hasPixels || hasDecoded) {
        raw = natural;
      } else {
        raw = 0.84;
      }
      break;
    case 'model3D':
      raw = hasPixels || hasDecoded ? natural : 1.0;
      break;
    default:
      raw = natural;
      break;
  }

  return clamp(raw, 0.52, 2.25);
}

/** Computes a card's unscaled arc width from its natural aspect ratio at fixed `cardHeight`. */
export function ringCardWidthForAspect(aspect: number, cardHeight: number): number {
  const clampedAspect = clamp(aspect, 0.52, 2.25);
  return Math.round(cardHeight * clampedAspect);
}

export function ringCardWidthForAsset(
  asset: AssetRecord,
  cardHeight: number,
  decodedAspectFallback?: number,
): number {
  return ringCardWidthForAspect(
    ringEffectiveAspectRatio(asset, decodedAspectFallback),
    cardHeight,
  );
}

/**
 * Precomputed variable-width arc track mirroring Horizontal Justified Masonry:
 * every card shares `cardHeight`, takes its natural aspect-ratio width, and sits strictly `cardGap` apart.
 */
export class RingCardTrack {
  readonly cardWidths: readonly number[];
  readonly centerArcs: readonly number[];
  readonly totalTrackLength: number;
  readonly cardHeight: number;
  readonly cardGap: number;

  constructor(cardWidths: readonly number[], cardHeight: number, cardGap: number) {
    this.cardWidths = cardWidths;
    this.cardHeight = cardHeight;
    this.cardGap = cardGap;

    if (cardWidths.length === 0) {
      this.centerArcs = [];
      this.totalTrackLength = 0;
      return;
    }

    const centers = new Array<number>(cardWidths.length);
    centers[0] = 0;
    let total = cardWidths[0] + cardGap;
    for (let i = 1; i < cardWidths.length; i++) {
      centers[i] = centers[i - 1] + 0.5 * cardWidths[i - 1] + cardGap + 0.5 * cardWidths[i];
      total += cardWidths[i] + cardGap;
    }
    this.centerArcs = centers;
    this.totalTrackLength = total;
  }

  get count(): number {
    return this.cardWidths.length;
  }

  get isEmpty(): boolean {
    return this.cardWidths.length === 0;
  }

  static build(
    assets: readonly AssetRecord[],
    params: RingGalleryParameters,
    decodedAspects?: ReadonlyMap<string, number>,
  ): RingCardTrack {
    const widths = assets.map((a) =>
      ringCardWidthForAsset(a, params.cardHeight, decodedAspects?.get(a.id)),
    );
    return new RingCardTrack(widths, params.cardHeight, params.cardGap);
  }

  static uniform(count: number, params: RingGalleryParameters): RingCardTrack {
    const n = Math.max(0, count);
    const widths = new Array<number>(n).fill(params.cardWidth);
    return new RingCardTrack(widths, params.cardHeight, params.cardGap);
  }

  equals(other: RingCardTrack): boolean {
    if (
      this.count !== other.count ||
      this.cardHeight !== other.cardHeight ||
      this.cardGap !== other.cardGap
    ) {
      return false;
    }
    for (let i = 0; i < this.cardWidths.length; i++) {
      if (this.cardWidths[i] !== other.cardWidths[i]) return false;
    }
    return true;
  }

  cardWidthForVirtualIndex(vIdx: number): number {
    if (this.cardWidths.length === 0) return 180;
    return this.cardWidths[positiveMod(vIdx, this.cardWidths.length)];
  }

  centerArcForVirtualIndex(vIdx: number): number {
    const n = this.cardWidths.length;
    if (n === 0) return 0;
    const lap = floorDiv(vIdx, n);
    const idx = positiveMod(vIdx, n);
    return lap * this.totalTrackLength + this.centerArcs[idx];
  }

  /** Finds the closest virtual card index to `offset` in `O(log N)`. */
  nearestVirtualIndex(offset: number): number {
    const n = this.cardWidths.length;
    if (n === 0 || !(this.totalTrackLength > 0)) return 0;
    if (n <= 3) {
      let best = 0;
      let bestDist = Math.abs(this.centerArcs[0] - offset);
      for (let i = 1; i < n; i++) {
        const d = Math.abs(this.centerArcs[i] - offset);
        if (d < bestDist) {
          bestDist = d;
          best = i;
        }
      }
      return best;
    }

    const lap = Math.floor(offset / this.totalTrackLength);
    const rem = offset - lap * this.totalTrackLength;

    let lo = 0;
    let hi = n;
    while (lo < hi) {
      const mid = (lo + hi) >>> 1;
      if (this.centerArcs[mid] < rem) {
        lo = mid + 1;
      } else {
        hi = mid;
      }
    }

    const candidates = [lap * n + lo - 1, lap * n + lo, lap * n + lo + 1];
    let bestIdx = candidates[1];
    let bestDist = Math.abs(this.centerArcForVirtualIndex(bestIdx) - offset);
    for (const cand of candidates) {
      const d = Math.abs(this.centerArcForVirtualIndex(cand) - offset);
      if (d < bestDist) {
        bestDist = d;
        bestIdx = cand;
      }
    }
    return bestIdx;
  }

  /**
   * Smoothly interpolates the front card width at the current continuous `offset`
   * so the depth-of-field sharp center zone never jumps between portrait and landscape cards.
   */
  interpolatedFrontCardWidth(offset: number): number {
    if (this.cardWidths.length === 0) return 180;
    const nearest = this.nearestVirtualIndex(offset);
    const c0 = this.centerArcForVirtualIndex(nearest);
    const w0 = this.cardWidthForVirtualIndex(nearest);
    const neighbor = offset >= c0 ? nearest + 1 : nearest - 1;
    if (this.count <= 3 && (neighbor < 0 || neighbor >= this.count)) {
      return w0;
    }
    const c1 = this.centerArcForVirtualIndex(neighbor);
    const w1 = this.cardWidthForVirtualIndex(neighbor);
    const span = Math.abs(c1 - c0);
    if (span <= 1e-4) return w0;
    const t = clamp(Math.abs(offset - c0) / span, 0.0, 1.0);
    return w0 + (w1 - w0) * t;
  }
}

/** Projected visibility & screen-space hit-test geometry for one slot on the Outside Ring. */
export interface RingProjectedCard {
  virtualIndex: number;
  assetIndex: number;
  arcS: number;
  cardWidth: number;
  centerX: number;
  centerZ: number;
  minScreenX: number;
  maxScreenX: number;
  maxHalfScreenY: number;
  uMin: number;
  uMax: number;
  isFarSide: boolean;
  seamAlpha: number;
}

export function ringProjectedCardContains(
  card: RingProjectedCard,
  screenX: number,
  screenY: number,
): boolean {
  return (
    screenX >= card.minScreenX &&
    screenX <= card.maxScreenX &&
    Math.abs(screenY) <= card.maxHalfScreenY
  );
}

/**
 * Exact closed-form unscaled half-width of the projected Outside cylinder silhouette:
 * `x_sil = R * P / sqrt(P^2 + 2 * P * R)`.
 */
export function outsideProjectedHalfWidth(radius: number, perspective: number): number {
  const r = Math.max(1.0, radius);
  const p = Math.max(1.0, perspective);
  return (r * p) / Math.sqrt(p * p + 2.0 * p * r);
}

/**
 * Computes live viewport-adaptive `cardScale` so the Outside ring fills ~94% of the window width
 * while staying cleanly within vertical headroom between top chrome and bottom navigation pill.
 */
export function adaptiveCardScale(
  viewportWidth: number,
  viewportHeight: number,
  topSafeInset: number,
  bottomSafeInset = 72.0,
  params: RingGalleryParameters = DEFAULT_RING_GALLERY_PARAMS,
): number {
  const w = Math.max(240.0, viewportWidth);
  const h = Math.max(220.0, viewportHeight);
  const naturalHalfW = outsideProjectedHalfWidth(ringRadius(params), params.perspective);

  const horizontalMargin = clamp(w * 0.03, 18.0, 44.0);
  const targetHalfW = Math.max(110.0, w * 0.5 - horizontalMargin);
  const scaleForWidth = targetHalfW / Math.max(1.0, naturalHalfW);

  const usableH = Math.max(150.0, h - topSafeInset - bottomSafeInset);
  const scaleForHeight = (usableH * 0.78) / Math.max(1.0, params.cardHeight);

  return clamp(Math.min(scaleForWidth, scaleForHeight), 0.34, 2.8);
}

/** Computes visual vertical center offset (Y-up points from viewport center) between top & bottom chrome. */
export function verticalCenterBias(topSafeInset: number, bottomSafeInset = 72.0): number {
  return (bottomSafeInset - topSafeInset) * 0.5;
}

/** Continuous front-center virtual index for uniform-width tracks (`Math.round(offset / step)`). */
export function frontVirtualIndex(offset: number, step: number): number {
  if (!(step > 0)) return 0;
  return Math.round(offset / step);
}

/** Places a point at signed arc coordinate `s` on a ring with signed curvature `c = bend / R`. */
export function placePoint(
  arcS: number,
  curvature: number,
): { x: number; z: number; angle: number } {
  if (Math.abs(curvature) < 1e-9) {
    return { x: arcS, z: 0, angle: 0 };
  }
  const angle = arcS * curvature;
  return {
    x: Math.sin(angle) / curvature,
    z: (1.0 - Math.cos(angle)) / curvature,
    angle,
  };
}

/** Eye-level straight-on perspective projection `(x, y, z) -> (sx, sy)` from viewport center. */
export function projectPoint(
  x: number,
  y: number,
  z: number,
  perspective: number,
  nearPlane = 140,
): { sx: number; sy: number } | null {
  const depth = perspective - z;
  if (depth < nearPlane) return null;
  const scale = perspective / depth;
  return { sx: x * scale, sy: y * scale };
}

/** Per-pixel Outside depth-of-field blur radius in screen points. */
export function depthOfFieldBlur(
  screenX: number,
  halfViewportWidth: number,
  z: number,
  radius: number,
  maxBlur: number,
  sharpHalfWidth = 110.0,
): number {
  if (!(maxBlur > 0)) return 0;
  const halfW = Math.max(sharpHalfWidth + 10.0, halfViewportWidth);
  const back = clamp(-z / (2.0 * Math.max(1.0, radius)), 0.0, 1.0);
  const sideBlur = maxBlur * smoothstep(sharpHalfWidth, halfW, Math.abs(screenX)) ** 1.4;
  const depthBlur = maxBlur * smoothstep(0.25, 0.8, back) ** 1.2;
  return Math.max(sideBlur, depthBlur);
}

/** Far-side fade fraction toward the page background: `fade * smoothstep(0.3, 1.0, back)`. */
export function farFadeAmount(z: number, radius: number, fade: number): number {
  const back = clamp(-z / (2.0 * Math.max(1.0, radius)), 0.0, 1.0);
  return clamp(fade, 0.0, 1.0) * smoothstep(0.3, 1.0, back);
}

/**
 * Computes post-drag momentum target (snapped to nearest card on `track` or uniform `step`)
 * and glide duration in seconds (`reducedMotion` capped `<= 0.20s`).
 */
export function releaseGlide(
  offset: number,
  velocityArcPerSec: number,
  trackOrStep: RingCardTrack | number,
  reducedMotion: boolean,
): { targetOffset: number; duration: number } {
  if (typeof trackOrStep === 'number') {
    const step = trackOrStep;
    if (!(step > 0)) return { targetOffset: offset, duration: 0.2 };
    if (reducedMotion) {
      const snapped = Math.round(offset / step) * step;
      const dist = Math.abs(snapped - offset);
      return { targetOffset: snapped, duration: Math.min(0.2, Math.max(0.08, dist * 0.0012)) };
    }
    const projected = offset - velocityArcPerSec * 0.26;
    const snapped = Math.round(projected / step) * step;
    const dist = Math.abs(snapped - offset);
    const duration = clamp(dist * 0.0016, 0.42, 1.1);
    return { targetOffset: snapped, duration };
  }

  const track = trackOrStep;
  if (track.isEmpty) return { targetOffset: offset, duration: 0.2 };
  if (reducedMotion) {
    const snapIdx = track.nearestVirtualIndex(offset);
    const snapped = track.centerArcForVirtualIndex(snapIdx);
    const dist = Math.abs(snapped - offset);
    return { targetOffset: snapped, duration: Math.min(0.2, Math.max(0.08, dist * 0.0012)) };
  }
  const projected = offset - velocityArcPerSec * 0.26;
  const snapIdx = track.nearestVirtualIndex(projected);
  const snapped = track.centerArcForVirtualIndex(snapIdx);
  const dist = Math.abs(snapped - offset);
  const duration = clamp(dist * 0.0016, 0.42, 1.1);
  return { targetOffset: snapped, duration };
}

/**
 * Computes the silhouette horizon angle `thetaSil = acos(R / (P + R))` on the Outside ring
 * where projected `sx(theta)` transitions between front-facing and far-facing slopes.
 */
export function outsideSilhouetteAngle(radius: number, perspective: number): number {
  const ratio = clamp(radius / Math.max(1.0, perspective + radius), -1.0, 1.0);
  return Math.acos(ratio);
}

export interface VisibleOutsideCardsOptions {
  track: RingCardTrack;
  offset: number;
  params: RingGalleryParameters;
  viewportWidth: number;
  viewportHeight: number;
  cardScale?: number;
  pressScaleForVirtualIndex?: (vIdx: number) => number;
}

/**
 * Projects all visible variable-width ring cards packed around the full Outside circumference,
 * sorted farthest-first (painter's order). Splits cards straddling the exact silhouette tangent
 * so they never self-overlap and double-blend a crease.
 */
export function visibleOutsideCards(options: VisibleOutsideCardsOptions): RingProjectedCard[] {
  const {
    track,
    offset,
    params,
    viewportWidth,
    viewportHeight,
    cardScale = 1.0,
    pressScaleForVirtualIndex = () => 1.0,
  } = options;

  const assetCount = track.count;
  if (assetCount <= 0 || viewportWidth <= 10 || viewportHeight <= 10) return [];

  const radius = ringRadius(params);
  const halfCirc = ringCircumference(params) * 0.5;
  const c = ringCurvature(params);
  const P = params.perspective;
  const halfW = viewportWidth * 0.5;
  const halfH = viewportHeight * 0.5;
  const pad = params.depthBlur * clamp(cardScale, 0.72, 1.38) + 4.0;
  const thetaSil = outsideSilhouetteAngle(radius, P);

  const centerVirtual = track.nearestVirtualIndex(offset);

  const virtualIndices: number[] = [];
  if (assetCount <= 3) {
    for (let i = 0; i < assetCount; i++) virtualIndices.push(i);
  } else {
    const seamLimit = halfCirc - params.cardGap * 0.5;
    virtualIndices.push(centerVirtual);

    let vRight = centerVirtual + 1;
    let safety = 0;
    while (safety < 64) {
      const s = track.centerArcForVirtualIndex(vRight) - offset;
      const w = track.cardWidthForVirtualIndex(vRight);
      if (s + w * 0.5 > seamLimit) break;
      virtualIndices.push(vRight);
      vRight += 1;
      safety += 1;
    }

    let vLeft = centerVirtual - 1;
    safety = 0;
    while (safety < 64) {
      const s = track.centerArcForVirtualIndex(vLeft) - offset;
      const w = track.cardWidthForVirtualIndex(vLeft);
      if (s - w * 0.5 < -seamLimit) break;
      virtualIndices.push(vLeft);
      vLeft -= 1;
      safety += 1;
    }
  }

  const cards: RingProjectedCard[] = [];

  for (const virtualIdx of virtualIndices) {
    const s = track.centerArcForVirtualIndex(virtualIdx) - offset;
    const baseCardW = track.cardWidthForVirtualIndex(virtualIdx);
    const pScale = pressScaleForVirtualIndex(virtualIdx);
    const halfCardW = baseCardW * 0.5 * pScale;
    const halfCardH = params.cardHeight * 0.5 * pScale;

    const seamMargin = Math.max(0.0, halfCirc - (Math.abs(s) + halfCardW));
    const seamAlpha = assetCount <= 3 ? 1.0 : smoothstep(0.0, 140.0, seamMargin);
    if (seamAlpha < 0.005) continue;

    const thetaStart = (s - halfCardW) / radius;
    const thetaEnd = (s + halfCardW) / radius;
    const absStart = Math.abs(thetaStart);
    const absEnd = Math.abs(thetaEnd);

    let uMin = -halfCardW;
    let uMax = halfCardW;
    let isFarSide = Math.abs(s / radius) > thetaSil;

    if (
      (absStart < thetaSil && absEnd > thetaSil) ||
      (absEnd < thetaSil && absStart > thetaSil)
    ) {
      const sign = s >= 0 ? 1.0 : -1.0;
      const silS = sign * thetaSil * radius;
      const uSil = clamp(silS - s, -halfCardW, halfCardW);
      const pStart = placePoint(s - halfCardW, c);
      const pSil = placePoint(s + uSil, c);
      const pEnd = placePoint(s + halfCardW, c);
      const projStart = projectPoint(pStart.x, 0, pStart.z, P, params.nearPlane);
      const projSil = projectPoint(pSil.x, 0, pSil.z, P, params.nearPlane);
      const projEnd = projectPoint(pEnd.x, 0, pEnd.z, P, params.nearPlane);
      if (projStart && projSil && projEnd) {
        const spanA = Math.abs(projSil.sx - projStart.sx);
        const spanB = Math.abs(projEnd.sx - projSil.sx);
        const startIsFront = absStart < thetaSil;
        if (spanA >= spanB) {
          uMin = -halfCardW;
          uMax = uSil;
          isFarSide = !startIsFront;
        } else {
          uMin = uSil;
          uMax = halfCardW;
          isFarSide = startIsFront;
        }
      }
    }

    if (uMax - uMin <= 0.25) continue;

    let minSX = Number.POSITIVE_INFINITY;
    let maxSX = Number.NEGATIVE_INFINITY;
    let maxHalfSY = 0.0;
    let tooClose = false;

    for (let k = 0; k <= 8; k++) {
      const u = uMin + (uMax - uMin) * (k / 8.0);
      const pt = placePoint(s + u, c);
      if (P - pt.z < params.nearPlane) {
        tooClose = true;
        break;
      }
      const scale = (P / (P - pt.z)) * cardScale;
      const sx = pt.x * scale;
      const sy = halfCardH * scale;
      if (sx < minSX) minSX = sx;
      if (sx > maxSX) maxSX = sx;
      if (sy > maxHalfSY) maxHalfSY = sy;
    }
    if (tooClose) continue;

    if (maxSX + pad < -halfW || minSX - pad > halfW) continue;
    if (maxHalfSY + pad < -halfH) continue;

    const centerPt = placePoint(s + 0.5 * (uMin + uMax), c);
    const assetIdx = positiveMod(virtualIdx, assetCount);
    cards.push({
      virtualIndex: virtualIdx,
      assetIndex: assetIdx,
      arcS: s,
      cardWidth: baseCardW,
      centerX: centerPt.x,
      centerZ: centerPt.z,
      minScreenX: minSX,
      maxScreenX: maxSX,
      maxHalfScreenY: maxHalfSY,
      uMin: uMin / pScale,
      uMax: uMax / pScale,
      isFarSide,
      seamAlpha,
    });
  }

  // Painter's order: farthest Z first so near sharp cards composite cleanly over far blurred cards
  cards.sort((lhs, rhs) => {
    if (Math.abs(lhs.centerZ - rhs.centerZ) > 0.01) {
      return lhs.centerZ - rhs.centerZ;
    }
    return Math.abs(rhs.arcS) - Math.abs(lhs.arcS);
  });

  return cards;
}

export const RingGalleryMath = {
  clamp,
  smoothstep,
  wrapArc,
  positiveMod,
  floorDiv,
  effectiveAspectRatio: ringEffectiveAspectRatio,
  cardWidthForAspect: ringCardWidthForAspect,
  cardWidthForAsset: ringCardWidthForAsset,
  outsideProjectedHalfWidth,
  adaptiveCardScale,
  verticalCenterBias,
  frontVirtualIndex,
  placePoint,
  projectPoint,
  depthOfFieldBlur,
  farFadeAmount,
  releaseGlide,
  outsideSilhouetteAngle,
  visibleOutsideCards,
};
