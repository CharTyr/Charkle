/**
 * Local 9-slice SVG rim-refraction lens and adaptive surface-tone controller for
 * Charkle Windows (WebView2 / Chromium engine), zero external runtime dependencies.
 *
 * 1. Rim-refraction lens: builds four corner displacement tiles + four 1px edge strips
 *    once per `(radius, bezel, corner, power)` tuple, caches decoded PNG data URIs, and
 *    attaches an SVG `feDisplacementMap` filter (with RGB chromatic dispersion) via
 *    `--glass-lens` so `.charkle-glass` and `.charkle-glass-dark` refract imagery at rims.
 * 2. Adaptive surface tone: samples intersecting `[data-asset-hex]` cards underneath
 *    `[data-adapt-glass="true"]` surfaces on scroll/resize, smoothly flipping light/dark
 *    glass ink with hysteresis (`pickInk`), tuning frost density & chroma retention
 *    (`adapt`), and solving the exact minimum WCAG 4.5:1 tint floor (`tintFloor`).
 */

export interface LiquidGlassOptions {
  /** Max rim width in CSS pixels (clamped automatically on compact controls). */
  rim?: number;
  /** How far inward the outer edge samples the backdrop, in rim widths. */
  edge?: number;
  /** Falloff exponent across the rim: `(1 - d / rim) ^ power`. */
  power?: number;
  /** Chromatic dispersion delta between R/G/B passes (`0` = single monochrome pass). */
  dispersion?: number;
  /** Explicit corner radius in px, or `null` to read computed `borderTopLeftRadius`. */
  radius?: number | null;
  /** Explicit superellipse exponent, or `null` to read computed `corner-top-left-shape`. */
  corner?: number | null;
  /** Toggle lens on/off without tearing down the observer. */
  enabled?: boolean;
  /** CSS custom property holding `url(#filter-id)`. */
  property?: string;
}

export interface LiquidGlassHandle {
  readonly supported: boolean;
  bezel: number;
  update: (next?: Partial<LiquidGlassOptions>) => void;
  refresh: () => void;
  destroy: () => void;
}

export type GlassInk = 'dark' | 'light';

export interface SurfaceSample {
  /** Mean perceived sRGB luma in [0, 1] for ink polarity (`pickInk`) & frost density (`adapt`). */
  luminance: number;
  /** Mean WCAG relative linear luminance in [0, 1] for exact WCAG 4.5:1 `tintFloor` math. */
  linearLuminance?: number;
  /** Local visual texture / luminance spread in [0, 1]. */
  texture: number;
  /** Mean saturation / chroma intensity in [0, 1]. */
  color: number;
}

export const LENS_DEFAULTS: Required<LiquidGlassOptions> = {
  rim: 40,
  edge: 1.35,
  power: 2.1,
  dispersion: 0.20,
  radius: null,
  corner: null,
  enabled: true,
  property: '--glass-lens',
};

export const ROUND_CORNER = 2;
const LENS_MIN_PX = 28;
const SETTLE_MS = 140;
const SVG_NS = 'http://www.w3.org/2000/svg';
const XLINK_NS = 'http://www.w3.org/1999/xlink';
const TILE_CACHE_MAX = 48;

interface TileBitmap {
  width: number;
  height: number;
  data: Uint8ClampedArray;
}

interface DecodedTileSet {
  size: number;
  urls: string[];
}

interface FilterNodes {
  id: string;
  host: SVGSVGElement;
  filter: SVGFilterElement;
  pieces: SVGFEImageElement[];
  passes: Array<{ el: SVGFEDisplacementMapElement }>;
  tiles: DecodedTileSet;
}

function clamp01(v: number): number {
  if (!Number.isFinite(v)) return 0;
  return Math.max(0, Math.min(1, v));
}

function parseHexRgb(hex: string | null | undefined): [number, number, number] | null {
  if (!hex) return null;
  const clean = hex.trim().replace(/^#/, '');
  if (!/^[0-9a-fA-F]{6}$/.test(clean)) return null;
  return [
    Number.parseInt(clean.slice(0, 2), 16) / 255,
    Number.parseInt(clean.slice(2, 4), 16) / 255,
    Number.parseInt(clean.slice(4, 6), 16) / 255,
  ];
}

function srgbToLinear(c: number): number {
  return c <= 0.04045 ? c / 12.92 : ((c + 0.055) / 1.055) ** 2.4;
}

/** WCAG relative linear luminance in [0, 1] (used strictly for WCAG 4.5:1 contrast math). */
export function hexLuminance(hex: string | null | undefined): number | null {
  const rgb = parseHexRgb(hex);
  if (!rgb) return null;
  return (
    0.2126 * srgbToLinear(rgb[0]) +
    0.7152 * srgbToLinear(rgb[1]) +
    0.0722 * srgbToLinear(rgb[2])
  );
}

/** Perceived sRGB luma `(0.299*r + 0.587*g + 0.114*b)` in [0, 1] for optical glass ink polarity. */
export function hexPerceivedLuma(hex: string | null | undefined): number | null {
  const rgb = parseHexRgb(hex);
  if (!rgb) return null;
  return 0.299 * rgb[0] + 0.587 * rgb[1] + 0.114 * rgb[2];
}

function hexSaturation(hex: string | null | undefined): number {
  const rgb = parseHexRgb(hex);
  if (!rgb) return 0;
  const max = Math.max(rgb[0], rgb[1], rgb[2]);
  const min = Math.min(rgb[0], rgb[1], rgb[2]);
  if (max <= 0) return 0;
  return (max - min) / max;
}

/**
 * Selects dark ink (on clear light glass) vs light ink (on smoky dark glass)
 * using perceived sRGB luma with pivot `0.50` and hysteresis `±0.05` to prevent
 * flicker at card boundaries and keep warm/pastel backdrops on Light Glass.
 */
export function pickInk(
  luminance: number,
  prev: GlassInk | null = null,
  pivot = 0.5,
  hysteresis = 0.05,
): GlassInk {
  const l = clamp01(luminance);
  if (prev === 'dark') return l < pivot - hysteresis ? 'light' : 'dark';
  if (prev === 'light') return l > pivot + hysteresis ? 'dark' : 'light';
  return l >= pivot ? 'dark' : 'light';
}

/**
 * Maps sampled backdrop perceived luma, texture variance, and saturation to
 * balanced `--density` (veil weight) and `--keep` (chroma retention).
 */
export function adapt(
  sample: SurfaceSample,
  ink: GlassInk,
): { density: number; keep: number } {
  const l = clamp01(sample.luminance);
  const tex = clamp01(sample.texture);
  const col = clamp01(sample.color);
  const midProximity = Math.max(0, 1 - Math.abs(l - 0.5) / 0.5);
  const baseDensity = ink === 'dark' ? 0.24 : 0.28;
  const density = Number(clamp01(baseDensity + tex * 0.56 + midProximity * 0.22).toFixed(3));
  const keep = Number(
    Math.max(0.62, Math.min(1, 1 - Math.max(0, col - 0.5) * (0.28 + tex * 0.45))).toFixed(3),
  );
  return { density, keep };
}

/**
 * Solves for the minimum tint floor alpha (`--floor`) required to maintain
 * WCAG AA 4.5:1 ink contrast over the sampled luminance & texture spread.
 * Returns `0` when natural backdrop contrast already clears 4.5:1 so clear
 * surfaces stay minimally veiled.
 */
export function tintFloor(
  luminance: number,
  texture: number,
  ink: GlassInk,
  tintLevel: number,
  minContrast = 4.5,
): number {
  const l = clamp01(luminance);
  const tex = clamp01(texture);
  const tint = clamp01(tintLevel);
  const inkL = ink === 'dark' ? 0.011 : 0.915;
  const worstBg =
    ink === 'dark'
      ? Math.max(0, l - tex * 0.26)
      : Math.min(1, l + tex * 0.26);

  const contrastAt = (alpha: number): number => {
    const blended = worstBg * (1 - alpha) + tint * alpha;
    const hi = Math.max(inkL, blended);
    const lo = Math.min(inkL, blended);
    return (hi + 0.05) / (lo + 0.05);
  };

  if (contrastAt(0) >= minContrast) return 0;

  let low = 0;
  let high = 0.92;
  for (let i = 0; i < 14; i += 1) {
    const mid = (low + high) * 0.5;
    if (contrastAt(mid) >= minContrast) high = mid;
    else low = mid;
  }
  return Number(high.toFixed(3));
}

/**
 * Only Chromium-based engines (including Windows WebView2 / Edge / Chrome) render
 * `backdrop-filter: url(#svg-filter)` cleanly. Other engines gracefully keep pure CSS glass.
 */
export function isLensSupported(): boolean {
  if (typeof window === 'undefined' || typeof CSS === 'undefined') return false;
  if (typeof ResizeObserver === 'undefined' || typeof document === 'undefined') return false;
  if (!CSS.supports?.('backdrop-filter', 'url(#charkle-lens-probe)')) return false;
  const ua = typeof navigator !== 'undefined' ? navigator.userAgent : '';
  return /Chrome\//.test(ua) && !/Firefox\//.test(ua);
}

export function cornerExponent(shape: string | null | undefined): number {
  const value = String(shape || '').trim();
  if (value === 'squircle') return 4;
  const match = /^superellipse\(\s*([^)\s]+)\s*\)$/.exec(value);
  const k = match ? Number(match[1]) : Number.NaN;
  return Number.isFinite(k) && k >= 0 ? 2 ** k : ROUND_CORNER;
}

function rimStrength(depth: number, power: number): number {
  return depth >= 1 ? 0 : (1 - Math.max(0, depth)) ** power;
}

function contourRadius(depth: number, radius: number, bezel: number): number {
  if (radius >= bezel) return radius - depth * bezel;
  return (1 - depth) * (radius + (bezel - radius) * depth * (2 - depth));
}

function isWithinContour(
  x: number,
  y: number,
  depth: number,
  radius: number,
  bezel: number,
  corner: number,
): boolean {
  const inset = depth * bezel;
  if (x < inset || y < inset) return false;
  const curve = contourRadius(depth, radius, bezel);
  const center = inset + curve;
  if (x >= center || y >= center) return true;
  return ((center - x) / curve) ** corner + ((center - y) / curve) ** corner <= 1;
}

function bendNearCorner(
  x: number,
  y: number,
  radius: number,
  bezel: number,
  corner: number,
  power: number,
): [number, number] {
  if (isWithinContour(x, y, 1, radius, bezel, corner)) return [0, 0];
  let depth = 0;
  if (isWithinContour(x, y, 0, radius, bezel, corner)) {
    let low = 0;
    let high = 1;
    for (let step = 0; step < 14; step += 1) {
      const middle = (low + high) / 2;
      if (isWithinContour(x, y, middle, radius, bezel, corner)) low = middle;
      else high = middle;
    }
    depth = low;
  }
  const strength = rimStrength(depth, power);
  const curve = contourRadius(depth, radius, bezel);
  const center = depth * bezel + curve;
  if (x < center && y < center && curve > 0) {
    const nx = Math.max(0, (center - x) / curve) ** (corner - 1);
    const ny = Math.max(0, (center - y) / curve) ** (corner - 1);
    const length = Math.hypot(nx, ny) || 1;
    return [(nx / length) * strength, (ny / length) * strength];
  }
  return x < y ? [strength, 0] : [0, strength];
}

export function rimDisplacement(
  x: number,
  y: number,
  width: number,
  height: number,
  geometry: { bezel: number; radius: number; corner?: number; power?: number },
): [number, number] {
  const {
    bezel,
    radius,
    corner = ROUND_CORNER,
    power = LENS_DEFAULTS.power,
  } = geometry;
  const rim = Math.min(bezel, height / 2, width / 2);
  const r = Math.max(0, Math.min(radius, width / 2, height / 2));
  const [inwardX, inwardY] = bendNearCorner(
    Math.min(x, width - x),
    Math.min(y, height - y),
    r,
    rim,
    corner,
    power,
  );
  if (inwardX === 0 && inwardY === 0) return [0, 0];
  return [x < width / 2 ? inwardX : -inwardX, y < height / 2 ? inwardY : -inwardY];
}

function lensLayout(width: number, height: number, size: number): Array<[number, number, number, number]> {
  const across = Math.max(1, width - size * 2);
  const down = Math.max(1, height - size * 2);
  return [
    [0, 0, size, size],
    [width - size, 0, size, size],
    [0, height - size, size, size],
    [width - size, height - size, size, size],
    [size, 0, across, size],
    [size, height - size, across, size],
    [0, size, size, down],
    [width - size, size, size, down],
  ];
}

function tilePixels(
  radius: number,
  bezel: number,
  corner: number,
  power: number,
): { size: number; tiles: TileBitmap[] } {
  const size = Math.max(1, Math.ceil(Math.max(radius, bezel)));
  const probe = size * 2 + 1;
  const geometry = { bezel, radius, corner, power };
  return {
    size,
    tiles: lensLayout(probe, probe, size).map(([left, top, w, h]) => {
      const data = new Uint8ClampedArray(w * h * 4);
      for (let y = 0; y < h; y += 1) {
        for (let x = 0; x < w; x += 1) {
          const [dx, dy] = rimDisplacement(left + x + 0.5, top + y + 0.5, probe, probe, geometry);
          const i = (y * w + x) * 4;
          data[i] = Math.round(128 + dx * 127);
          data[i + 1] = Math.round(128 + dy * 127);
          data[i + 2] = 128;
          data[i + 3] = 255;
        }
      }
      return { width: w, height: h, data };
    }),
  };
}

const tileCache = new Map<string, Promise<DecodedTileSet>>();

function lensTiles(
  radius: number,
  bezel: number,
  corner: number,
  power: number,
): Promise<DecodedTileSet> {
  const key = `${radius}:${bezel}:${corner.toFixed(3)}:${power.toFixed(3)}`;
  const cached = tileCache.get(key);
  if (cached) {
    tileCache.delete(key);
    tileCache.set(key, cached);
    return cached;
  }
  const { size, tiles } = tilePixels(radius, bezel, corner, power);
  // Inline PNG data URLs ensure Chromium WebView2 custom protocol origins always decode
  // SVG feImage displacement tiles cleanly with zero origin taint.
  const entry = Promise.all(
    tiles.map(async (tile) => {
      const canvas = document.createElement('canvas');
      canvas.width = tile.width;
      canvas.height = tile.height;
      const context = canvas.getContext('2d');
      if (!context) return '';
      const image = context.createImageData(tile.width, tile.height);
      image.data.set(tile.data);
      context.putImageData(image, 0, 0);
      const url = canvas.toDataURL('image/png');
      const decoded = new Image();
      decoded.src = url;
      await decoded.decode().catch(() => {});
      return url;
    }),
  ).then((urls) => ({ size, urls }));

  tileCache.set(key, entry);
  while (tileCache.size > TILE_CACHE_MAX) {
    const oldest = tileCache.keys().next().value;
    if (oldest !== undefined) tileCache.delete(oldest);
  }
  return entry;
}

function svgNode<K extends keyof SVGElementTagNameMap>(
  tag: K,
  attrs: Record<string, string | number>,
  parent?: Element,
): SVGElementTagNameMap[K] {
  const el = document.createElementNS(SVG_NS, tag);
  for (const [name, value] of Object.entries(attrs)) {
    el.setAttribute(name, String(value));
  }
  parent?.append(el);
  return el;
}

let filterCounter = 0;

function buildFilter(
  width: number,
  height: number,
  tiles: DecodedTileSet,
  split: boolean,
): FilterNodes {
  const id = `charkle-glass-lens-${++filterCounter}`;
  // Keep 1x1 off-screen SVG geometry (not 0x0) so Chromium/WebView2 never skips feImage decoding.
  const host = svgNode('svg', {
    'aria-hidden': 'true',
    width: 1,
    height: 1,
    style: 'position:fixed;left:-9999px;top:-9999px;width:1px;height:1px;pointer-events:none;opacity:0',
  });
  const filter = svgNode(
    'filter',
    {
      id,
      filterUnits: 'userSpaceOnUse',
      'color-interpolation-filters': 'sRGB',
      x: 0,
      y: 0,
      width,
      height,
    },
    host,
  );
  svgNode('feFlood', { 'flood-color': 'rgb(128,128,128)', result: 'flat' }, filter);
  const rects = lensLayout(width, height, tiles.size);
  const pieces = rects.map(([x, y, w, h], index) => {
    const piece = svgNode(
      'feImage',
      {
        href: tiles.urls[index],
        preserveAspectRatio: 'none',
        x,
        y,
        width: w,
        height: h,
        result: `t${index}`,
      },
      filter,
    );
    piece.setAttributeNS(XLINK_NS, 'xlink:href', tiles.urls[index]);
    return piece;
  });
  const merge = svgNode('feMerge', { result: 'map' }, filter);
  svgNode('feMergeNode', { in: 'flat' }, merge);
  rects.forEach((_, index) => svgNode('feMergeNode', { in: `t${index}` }, merge));

  const passes: Array<{ el: SVGFEDisplacementMapElement }> = [];
  const addPass = () => {
    passes.push({
      el: svgNode(
        'feDisplacementMap',
        {
          in: 'SourceGraphic',
          in2: 'map',
          xChannelSelector: 'R',
          yChannelSelector: 'G',
          scale: 0,
        },
        filter,
      ),
    });
  };

  if (split) {
    (['r', 'g', 'b'] as const).forEach((name, channel) => {
      addPass();
      const keep = Array.from({ length: 20 }, (_, cell) =>
        Number(cell === channel * 6 || cell === 18),
      ).join(' ');
      svgNode('feColorMatrix', { type: 'matrix', values: keep, result: name }, filter);
    });
    svgNode('feBlend', { in: 'r', in2: 'g', mode: 'screen' }, filter);
    svgNode('feBlend', { in2: 'b', mode: 'screen' }, filter);
  } else {
    addPass();
  }

  document.body.append(host);
  return { id, host, filter, pieces, passes, tiles };
}

function placeFilter(lens: FilterNodes, width: number, height: number): void {
  lens.filter.setAttribute('width', String(width));
  lens.filter.setAttribute('height', String(height));
  lensLayout(width, height, lens.tiles.size).forEach(([x, y, w, h], index) => {
    const piece = lens.pieces[index];
    piece.setAttribute('x', String(x));
    piece.setAttribute('y', String(y));
    piece.setAttribute('width', String(w));
    piece.setAttribute('height', String(h));
  });
}

export function liquidGlass(
  el: HTMLElement,
  options: LiquidGlassOptions = {},
): LiquidGlassHandle {
  let opts: Required<LiquidGlassOptions> = { ...LENS_DEFAULTS, ...options };
  const supported = isLensSupported();
  let current: { key: string; lens: FilterNodes; width: number; height: number } | null = null;
  let token = 0;
  let frame = 0;
  let lastChange = 0;
  let settleTimer = 0;

  const api: LiquidGlassHandle = {
    supported,
    bezel: 0,
    update(next = {}) {
      opts = { ...opts, ...next };
      schedule();
    },
    refresh: () => schedule(),
    destroy,
  };

  if (!supported) {
    api.update = () => {};
    api.refresh = () => {};
    api.destroy = () => {};
    return api;
  }

  function clear(): void {
    token += 1;
    el.style.removeProperty(opts.property);
    el.removeAttribute('data-lens-active');
    current?.lens.host.remove();
    current = null;
  }

  function setScale(lens: FilterNodes, bezel: number): void {
    const scale = 2 * opts.edge * bezel;
    const split = lens.passes.length > 1;
    lens.passes.forEach((p, channel) => {
      const share = split ? 1 + (1 - channel) * opts.dispersion : 1;
      p.el.setAttribute('scale', (scale * share).toFixed(1));
    });
  }

  async function fit(): Promise<void> {
    frame = 0;
    const width = Math.round(el.offsetWidth);
    const height = Math.round(el.offsetHeight);
    if (!opts.enabled || width < LENS_MIN_PX || height < LENS_MIN_PX) {
      clear();
      return;
    }
    const style = getComputedStyle(el);
    if (
      el.classList.contains('charkle-popover-panel') ||
      (style.willChange && style.willChange !== 'auto')
    ) {
      clear();
      return;
    }
    const cssRadius = Number.parseFloat(style.borderTopLeftRadius) || 0;
    const radius = Math.round(Math.min(opts.radius ?? cssRadius, width / 2, height / 2));
    const corner = opts.corner ?? cornerExponent(style.getPropertyValue('corner-top-left-shape'));
    const bezel = Math.round(Math.max(6, Math.min(opts.rim, Math.min(width, height) / 2.3)));
    const split = opts.dispersion > 0;
    const key = `${radius}:${bezel}:${corner.toFixed(3)}:${opts.power.toFixed(3)}:${split}`;
    api.bezel = bezel;

    if (current?.key === key) {
      if (current.width !== width || current.height !== height) {
        placeFilter(current.lens, width, height);
        current.width = width;
        current.height = height;
      }
      setScale(current.lens, bezel);
      el.setAttribute('data-lens-active', 'true');
      return;
    }

    const now = performance.now();
    const settling = current !== null && now - lastChange < SETTLE_MS;
    lastChange = now;
    if (settling && current) {
      if (current.width !== width || current.height !== height) {
        placeFilter(current.lens, width, height);
        current.width = width;
        current.height = height;
      }
      setScale(current.lens, bezel);
      window.clearTimeout(settleTimer);
      settleTimer = window.setTimeout(schedule, SETTLE_MS);
      return;
    }

    if (current && (current.width !== width || current.height !== height)) {
      placeFilter(current.lens, width, height);
      current.width = width;
      current.height = height;
      setScale(current.lens, bezel);
    }

    const mine = ++token;
    const tiles = await lensTiles(radius, bezel, corner, opts.power);
    if (mine !== token || !el.isConnected) return;
    const lens = buildFilter(width, height, tiles, split);
    setScale(lens, bezel);
    const previous = current;
    current = { key, lens, width, height };
    el.style.setProperty(opts.property, `url(#${lens.id})`);
    el.setAttribute('data-lens-active', 'true');
    if (previous) {
      requestAnimationFrame(() => requestAnimationFrame(() => previous.lens.host.remove()));
    }
  }

  function schedule(): void {
    if (!frame) frame = requestAnimationFrame(() => void fit());
  }

  const observer = new ResizeObserver(schedule);
  observer.observe(el);

  function destroy(): void {
    observer.disconnect();
    cancelAnimationFrame(frame);
    window.clearTimeout(settleTimer);
    clear();
  }

  schedule();
  return api;
}

const GLASS_SELECTOR = '.charkle-glass, .charkle-glass-dark';
const ADAPT_SELECTOR = '[data-adapt-glass="true"]';
const SAMPLE_X_OFFSETS = [0.15, 0.325, 0.5, 0.675, 0.85] as const;
const SAMPLE_Y_OFFSETS = [0.25, 0.5, 0.75] as const;
const LIGHT_CANVAS_LUMA = 0.965;
const DARK_CANVAS_LUMA = 0.08;
const LIGHT_CANVAS_LINEAR_LUM = 0.92;
const DARK_CANVAS_LINEAR_LUM = 0.014;

function trimmedSlice(values: readonly number[], trimCount = 2): number[] {
  if (values.length === 0) return [];
  const sorted = [...values].sort((a, b) => a - b);
  const drop = sorted.length >= trimCount * 2 + 1 ? trimCount : sorted.length >= 4 ? 1 : 0;
  return drop > 0 ? sorted.slice(drop, sorted.length - drop) : sorted;
}

function sampleBackdropUnder(el: HTMLElement, isAppDark: boolean): SurfaceSample {
  const canvasLuma = isAppDark ? DARK_CANVAS_LUMA : LIGHT_CANVAS_LUMA;
  const canvasLinearLum = isAppDark ? DARK_CANVAS_LINEAR_LUM : LIGHT_CANVAS_LINEAR_LUM;
  const fallback: SurfaceSample = {
    luminance: canvasLuma,
    linearLuminance: canvasLinearLum,
    texture: 0.02,
    color: 0.02,
  };
  if (typeof document.elementsFromPoint !== 'function') return fallback;

  const rect = el.getBoundingClientRect();
  if (rect.width < 16 || rect.height < 16) return fallback;

  const perceivedLumas: number[] = [];
  const linearLumas: number[] = [];
  const sats: number[] = [];
  let paletteVariance = 0;
  let paletteSamples = 0;

  for (const yFrac of SAMPLE_Y_OFFSETS) {
    const y = rect.top + rect.height * yFrac;
    if (y < 0 || y > window.innerHeight) continue;

    for (const xFrac of SAMPLE_X_OFFSETS) {
      const x = rect.left + rect.width * xFrac;
      if (x < 0 || x > window.innerWidth) continue;
      const stack = document.elementsFromPoint(x, y);
      let matchedCard: Element | null = null;
      let matchedLuma: number | null = null;
      for (const node of stack) {
        if (node === el || el.contains(node)) continue;
        const candidate = node.closest('[data-asset-hex]');
        if (candidate) {
          const candidateLuma = hexPerceivedLuma(candidate.getAttribute('data-asset-hex'));
          if (candidateLuma !== null) {
            matchedCard = candidate;
            matchedLuma = candidateLuma;
            break;
          }
        }
      }

      if (matchedCard && matchedLuma !== null) {
        const hex = matchedCard.getAttribute('data-asset-hex');
        const linLum = hexLuminance(hex);
        perceivedLumas.push(matchedLuma);
        linearLumas.push(linLum ?? canvasLinearLum);
        sats.push(hexSaturation(hex));
        const colorsAttr = matchedCard.getAttribute('data-asset-colors');
        if (colorsAttr) {
          const extras = colorsAttr
            .split(',')
            .map((h) => hexPerceivedLuma(h))
            .filter((v): v is number => v !== null);
          if (extras.length >= 2) {
            const hi = Math.max(...extras);
            const lo = Math.min(...extras);
            paletteVariance += hi - lo;
            paletteSamples += 1;
          }
        }
        continue;
      }

      perceivedLumas.push(canvasLuma);
      linearLumas.push(canvasLinearLum);
      sats.push(0.02);
    }
  }

  if (perceivedLumas.length === 0) return fallback;
  const trimmedLumas = trimmedSlice(perceivedLumas, 2);
  const trimmedLinear = trimmedSlice(linearLumas, 2);
  const meanLuma = trimmedLumas.reduce((a, b) => a + b, 0) / trimmedLumas.length;
  const meanLinearLum = trimmedLinear.reduce((a, b) => a + b, 0) / trimmedLinear.length;
  const meanSat = sats.reduce((a, b) => a + b, 0) / sats.length;
  const spatialStd = Math.sqrt(
    trimmedLumas.reduce((sum, v) => sum + (v - meanLuma) ** 2, 0) / trimmedLumas.length,
  );
  const avgPaletteSpread = paletteSamples > 0 ? paletteVariance / paletteSamples : 0;
  const texture = clamp01(spatialStd * 1.45 + avgPaletteSpread * 0.25);

  return {
    luminance: meanLuma,
    linearLuminance: meanLinearLum,
    texture,
    color: meanSat,
  };
}

/**
 * Automatically mounts and cleans up SVG rim-refraction lenses on all
 * `.charkle-glass` and `.charkle-glass-dark` surfaces in the window, and drives
 * live adaptive luminance toning on `[data-adapt-glass="true"]` capsules.
 * Optical displacement disables strictly for `forced-colors: active` and
 * `prefers-contrast: more`.
 */
export function startLiquidGlassController(
  options: LiquidGlassOptions = {},
): () => void {
  if (typeof window === 'undefined' || typeof document === 'undefined' || typeof MutationObserver === 'undefined') {
    return () => {};
  }

  const lensCapable = isLensSupported();
  const handles = new Map<HTMLElement, LiquidGlassHandle>();
  const inkState = new WeakMap<HTMLElement, GlassInk>();
  const highContrastMQ = window.matchMedia?.('(prefers-contrast: more)');
  const forcedColorsMQ = window.matchMedia?.('(forced-colors: active)');

  const isGlobalLensDisabled = (): boolean =>
    Boolean(highContrastMQ?.matches || forcedColorsMQ?.matches);

  const shouldHaveLens = (el: HTMLElement): boolean =>
    lensCapable &&
    !isGlobalLensDisabled() &&
    el.isConnected &&
    el.getAttribute('data-no-lens') !== 'true' &&
    !el.classList.contains('charkle-popover-panel') &&
    el.matches(GLASS_SELECTOR);

  const syncElement = (el: HTMLElement) => {
    const existing = handles.get(el);
    if (shouldHaveLens(el)) {
      if (!existing) {
        handles.set(el, liquidGlass(el, options));
      }
    } else if (existing) {
      existing.destroy();
      handles.delete(el);
    }
  };

  let adaptRaf = 0;

  const evaluateAdaptiveSurface = (el: HTMLElement, isAppDark: boolean) => {
    if (!el.isConnected) return;
    if (isGlobalLensDisabled()) {
      if (el.hasAttribute('data-kind')) el.removeAttribute('data-kind');
      return;
    }
    const sample = sampleBackdropUnder(el, isAppDark);
    const prevInk = inkState.get(el) ?? null;
    const ink: GlassInk = isAppDark ? 'light' : pickInk(sample.luminance, prevInk, 0.5, 0.05);
    inkState.set(el, ink);

    if (!isAppDark) {
      if (ink === 'light') {
        if (el.getAttribute('data-kind') !== 'dark') el.setAttribute('data-kind', 'dark');
      } else if (el.hasAttribute('data-kind')) {
        el.removeAttribute('data-kind');
      }
    } else if (el.hasAttribute('data-kind')) {
      el.removeAttribute('data-kind');
    }

    const { density, keep } = adapt(sample, ink);
    const tintLevel = ink === 'dark' ? 1 : 0.014;
    const floor = tintFloor(
      sample.linearLuminance ?? sample.luminance,
      sample.texture,
      ink,
      tintLevel,
    );

    el.style.setProperty('--density', String(density));
    el.style.setProperty('--keep', String(keep));
    el.style.setProperty('--floor', String(floor));
  };

  const runAdaptPass = () => {
    adaptRaf = 0;
    if (!document.body) return;
    const isAppDark =
      document.documentElement.dataset.theme === 'dark' ||
      document.documentElement.classList.contains('dark');
    document.querySelectorAll<HTMLElement>(ADAPT_SELECTOR).forEach((el) => {
      evaluateAdaptiveSurface(el, isAppDark);
    });
  };

  const scheduleAdapt = () => {
    if (!adaptRaf) adaptRaf = requestAnimationFrame(runAdaptPass);
  };

  const scanSubtree = (root: ParentNode) => {
    if (root instanceof HTMLElement) {
      syncElement(root);
    }
    root.querySelectorAll<HTMLElement>(GLASS_SELECTOR).forEach(syncElement);
    scheduleAdapt();
  };

  const detachSubtree = (node: Node) => {
    if (!(node instanceof HTMLElement)) return;
    const existing = handles.get(node);
    if (existing) {
      existing.destroy();
      handles.delete(node);
    }
    node.querySelectorAll<HTMLElement>(GLASS_SELECTOR).forEach((child) => {
      const h = handles.get(child);
      if (h) {
        h.destroy();
        handles.delete(child);
      }
    });
  };

  const syncAll = () => {
    if (isGlobalLensDisabled()) {
      handles.forEach((h) => h.destroy());
      handles.clear();
      return;
    }
    handles.forEach((h, el) => {
      if (!shouldHaveLens(el)) {
        h.destroy();
        handles.delete(el);
      }
    });
    if (document.body) scanSubtree(document.body);
  };

  const domObserver = new MutationObserver((mutations) => {
    let shouldReAdapt = false;
    for (const m of mutations) {
      if (m.type === 'attributes' && m.target instanceof HTMLElement) {
        if (m.attributeName === 'data-asset-hex' || m.attributeName === 'data-adapt-glass') {
          shouldReAdapt = true;
        } else {
          syncElement(m.target);
        }
        continue;
      }
      m.removedNodes.forEach(detachSubtree);
      m.addedNodes.forEach((n) => {
        if (n instanceof HTMLElement) {
          scanSubtree(n);
          if (n.hasAttribute('data-asset-hex') || n.querySelector('[data-asset-hex], [data-adapt-glass]')) {
            shouldReAdapt = true;
          }
        }
      });
    }
    if (shouldReAdapt) scheduleAdapt();
  });

  const themeObserver = new MutationObserver(() => {
    scheduleAdapt();
  });

  if (document.body) {
    scanSubtree(document.body);
    domObserver.observe(document.body, {
      childList: true,
      subtree: true,
      attributes: true,
      attributeFilter: ['class', 'data-no-lens', 'data-asset-hex', 'data-adapt-glass'],
    });
  }
  themeObserver.observe(document.documentElement, {
    attributes: true,
    attributeFilter: ['data-theme', 'class'],
  });

  window.addEventListener('scroll', scheduleAdapt, { capture: true, passive: true });
  window.addEventListener('resize', scheduleAdapt, { passive: true });
  window.addEventListener('charkle:glass-resample', scheduleAdapt);
  highContrastMQ?.addEventListener?.('change', syncAll);
  forcedColorsMQ?.addEventListener?.('change', syncAll);

  return () => {
    domObserver.disconnect();
    themeObserver.disconnect();
    if (adaptRaf) cancelAnimationFrame(adaptRaf);
    window.removeEventListener('scroll', scheduleAdapt, true);
    window.removeEventListener('resize', scheduleAdapt);
    window.removeEventListener('charkle:glass-resample', scheduleAdapt);
    highContrastMQ?.removeEventListener?.('change', syncAll);
    forcedColorsMQ?.removeEventListener?.('change', syncAll);
    handles.forEach((h) => h.destroy());
    handles.clear();
  };
}
