/**
 * Perceptually uniform CIELAB swatch paired with sRGB hex.
 * 1:1 port of Swift `LabColor` (CoreModels.swift), `LabColor.deltaE2000` (ColorExtractor.swift),
 * and `Color.charkleIsLightHex` (CanvasSupport.swift).
 */
export interface LabColor {
  hex: string;
  l: number;
  a: number;
  b: number;
  proportion: number;
}

export interface RGBColor {
  r: number;
  g: number;
  b: number;
}

export interface LabTriple {
  l: number;
  a: number;
  b: number;
}

const HEX6_RE = /^[0-9a-fA-F]{6}$/;

/**
 * Parse a 6-digit sRGB hex string such as "#3B82F6" or "3B82F6".
 * Returns normalized `#RRGGBB` and channel values in `[0, 1]`, or `null` if invalid.
 */
export function parseHex(hexString: string): (RGBColor & { hex: string }) | null {
  const cleaned = hexString.trim().replace(/#/g, '');
  if (!HEX6_RE.test(cleaned)) {
    return null;
  }
  const value = Number.parseInt(cleaned, 16);
  const r = ((value >> 16) & 0xff) / 255.0;
  const g = ((value >> 8) & 0xff) / 255.0;
  const b = (value & 0xff) / 255.0;
  return { r, g, b, hex: `#${cleaned.toUpperCase()}` };
}

/**
 * Format sRGB channels in `[0, 1]` to an uppercase `#RRGGBB` string.
 */
export function sRGBToHex(r: number, g: number, b: number): string {
  const clampByte = (v: number): string => {
    const clamped = Math.max(0, Math.min(1, v));
    return Math.round(clamped * 255)
      .toString(16)
      .padStart(2, '0')
      .toUpperCase();
  };
  return `#${clampByte(r)}${clampByte(g)}${clampByte(b)}`;
}

/**
 * Convert sRGB channels in `[0, 1]` to D65 CIELAB coordinates.
 * Exact match with Swift `LabColor.sRGBToLab(r:g:b:)`.
 */
export function sRGBToLab(r: number, g: number, b: number): LabTriple {
  const linearize = (c: number): number =>
    c <= 0.04045 ? c / 12.92 : Math.pow((c + 0.055) / 1.055, 2.4);

  const rl = linearize(r);
  const gl = linearize(g);
  const bl = linearize(b);

  const x = (rl * 0.4124564 + gl * 0.3575761 + bl * 0.1804375) / 0.95047;
  const y = (rl * 0.2126729 + gl * 0.7151522 + bl * 0.0721750) / 1.0;
  const z = (rl * 0.0193339 + gl * 0.1191920 + bl * 0.9503041) / 1.08883;

  const f = (t: number): number =>
    t > 0.008856 ? Math.cbrt(t) : 7.787 * t + 16.0 / 116.0;

  const fx = f(x);
  const fy = f(y);
  const fz = f(z);

  const l = 116.0 * fy - 16.0;
  const a = 500.0 * (fx - fy);
  const bVal = 200.0 * (fy - fz);
  return { l, a, b: bVal };
}

/**
 * Convert D65 CIELAB coordinates back to clamped sRGB channels in `[0, 1]`.
 */
export function labToSRGB(l: number, a: number, b: number): RGBColor {
  const fy = (l + 16.0) / 116.0;
  const fx = a / 500.0 + fy;
  const fz = fy - b / 200.0;

  const finv = (t: number): number => {
    const t3 = t * t * t;
    return t3 > 0.008856 ? t3 : (t - 16.0 / 116.0) / 7.787;
  };

  const x = finv(fx) * 0.95047;
  const y = finv(fy) * 1.0;
  const z = finv(fz) * 1.08883;

  const rl = x * 3.2404542 + y * -1.5371385 + z * -0.4985314;
  const gl = x * -0.9692660 + y * 1.8760108 + z * 0.0415560;
  const bl = x * 0.0556434 + y * -0.2040259 + z * 1.0572252;

  const delinearize = (c: number): number => {
    const clamped = Math.max(0, Math.min(1, c));
    return clamped <= 0.0031308
      ? 12.92 * clamped
      : 1.055 * Math.pow(clamped, 1.0 / 2.4) - 0.055;
  };

  return {
    r: Math.max(0, Math.min(1, delinearize(rl))),
    g: Math.max(0, Math.min(1, delinearize(gl))),
    b: Math.max(0, Math.min(1, delinearize(bl))),
  };
}

/**
 * Convert D65 CIELAB coordinates to an uppercase sRGB hex string (`#RRGGBB`).
 */
export function labToHex(l: number, a: number, b: number): string {
  const rgb = labToSRGB(l, a, b);
  return sRGBToHex(rgb.r, rgb.g, rgb.b);
}

/**
 * Construct a `LabColor` from an sRGB hex string such as "#3B82F6" or "3B82F6".
 * Falls back to neutral gray `#808080` (`l: 53.59, a: 0, b: 0`) on invalid hex,
 * matching Swift `LabColor.fromHex(_:proportion:)`.
 */
export function labFromHex(hexString: string, proportion = 1.0): LabColor {
  const parsed = parseHex(hexString);
  if (!parsed) {
    return { hex: '#808080', l: 53.59, a: 0, b: 0, proportion };
  }
  const { l, a, b } = sRGBToLab(parsed.r, parsed.g, parsed.b);
  return { hex: parsed.hex, l, a, b, proportion };
}

/**
 * CIE76 Euclidean distance in CIELAB space (fast perceptual proximity).
 */
export function deltaE76(first: LabTriple, second: LabTriple): number {
  const dl = first.l - second.l;
  const da = first.a - second.a;
  const db = first.b - second.b;
  return Math.sqrt(dl * dl + da * da + db * db);
}

/** Alias matching Swift `LabColor.deltaE(to:)`. */
export const deltaE = deltaE76;

/**
 * CIEDE2000 perceptual color distance with standard unit weighting (kL = kC = kH = 1).
 * Exact port of Swift `LabColor.deltaE2000(to:)`.
 */
export function deltaE2000(first: LabTriple, second: LabTriple): number {
  const radians = (deg: number): number => (deg * Math.PI) / 180;
  const degrees = (rad: number): number => (rad * 180) / Math.PI;
  const hue = (a: number, b: number): number => {
    if (a === 0 && b === 0) return 0;
    const angle = degrees(Math.atan2(b, a));
    return angle < 0 ? angle + 360 : angle;
  };

  const meanChroma = (Math.hypot(first.a, first.b) + Math.hypot(second.a, second.b)) * 0.5;
  const chromaPower = Math.pow(meanChroma, 7);
  const g = 0.5 * (1 - Math.sqrt(chromaPower / (chromaPower + Math.pow(25, 7))));

  const a1 = (1 + g) * first.a;
  const a2 = (1 + g) * second.a;
  const c1 = Math.hypot(a1, first.b);
  const c2 = Math.hypot(a2, second.b);
  const h1 = hue(a1, first.b);
  const h2 = hue(a2, second.b);

  const difference = h2 - h1;
  let deltaHue: number;
  if (c1 * c2 === 0) {
    deltaHue = 0;
  } else if (Math.abs(difference) <= 180) {
    deltaHue = difference;
  } else {
    deltaHue = difference > 180 ? difference - 360 : difference + 360;
  }

  let meanHue: number;
  if (c1 * c2 === 0) {
    meanHue = h1 + h2;
  } else if (Math.abs(difference) <= 180) {
    meanHue = (h1 + h2) / 2;
  } else {
    meanHue = (h1 + h2 + (h1 + h2 < 360 ? 360 : -360)) / 2;
  }

  const meanLightness = (first.l + second.l) / 2;
  const meanAdjustedChroma = (c1 + c2) / 2;
  const t =
    1 -
    0.17 * Math.cos(radians(meanHue - 30)) +
    0.24 * Math.cos(radians(2 * meanHue)) +
    0.32 * Math.cos(radians(3 * meanHue + 6)) -
    0.20 * Math.cos(radians(4 * meanHue - 63));

  const lightnessOffset = Math.pow(meanLightness - 50, 2);
  const lightnessScale = 1 + (0.015 * lightnessOffset) / Math.sqrt(20 + lightnessOffset);
  const chromaScale = 1 + 0.045 * meanAdjustedChroma;
  const hueScale = 1 + 0.015 * meanAdjustedChroma * t;

  const adjustedPower = Math.pow(meanAdjustedChroma, 7);
  const rotation =
    -2 *
    Math.sqrt(adjustedPower / (adjustedPower + Math.pow(25, 7))) *
    Math.sin(radians(60 * Math.exp(-Math.pow((meanHue - 275) / 25, 2))));

  const dl = (second.l - first.l) / lightnessScale;
  const dc = (c2 - c1) / chromaScale;
  const dh = (2 * Math.sqrt(c1 * c2) * Math.sin(radians(deltaHue / 2))) / hueScale;

  return Math.sqrt(Math.max(0, dl * dl + dc * dc + dh * dh + rotation * dc * dh));
}

/**
 * Best perceptual color match distance (CIE76) between a target swatch and an item's palette.
 */
export function bestDeltaE(target: LabTriple, palette: readonly LabTriple[]): number | null {
  if (palette.length === 0) return null;
  let best = Number.POSITIVE_INFINITY;
  for (const color of palette) {
    const d = deltaE76(target, color);
    if (d < best) best = d;
  }
  return best;
}

/**
 * Relative perceptual luminance heuristic for picking contrasting ink over swatches.
 * Exact port of Swift `Color.charkleIsLightHex(_:)` (`0.299*r + 0.587*g + 0.114*b > 0.62`).
 */
export function isLightHex(hex: string): boolean {
  const parsed = parseHex(hex);
  if (!parsed) return false;
  const luminance = 0.299 * parsed.r + 0.587 * parsed.g + 0.114 * parsed.b;
  return luminance > 0.62;
}

export const LabColorUtils = {
  parseHex,
  sRGBToHex,
  sRGBToLab,
  labToSRGB,
  labToHex,
  fromHex: labFromHex,
  deltaE,
  deltaE76,
  deltaE2000,
  bestDeltaE,
  isLightHex,
} as const;
