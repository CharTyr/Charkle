import { useSyncExternalStore } from 'react';
import type { CSSProperties } from 'react';
import type { AccentSource, AssetRecord, PhotoExifMetadata } from '../types/domain';

export type ThemeMode = 'system' | 'light' | 'dark';

export interface DuotonePair {
  primary: string;
  secondary: string;
}

export interface FluentAccentPalette {
  accent: string;
  hover: string;
  pressed: string;
  soft: string;
  ring: string;
  text: string;
}

const STUDIO_LIGHT_ACCENT: FluentAccentPalette = {
  accent: '#2A60E0',
  hover: '#2151C7',
  pressed: '#1A42A8',
  soft: 'rgba(42, 96, 224, 0.11)',
  ring: 'rgba(42, 96, 224, 0.35)',
  text: '#FFFFFF',
};

const STUDIO_DARK_ACCENT: FluentAccentPalette = {
  accent: '#5B8DEF',
  hover: '#74A0F7',
  pressed: '#4A7CE0',
  soft: 'rgba(91, 141, 239, 0.17)',
  ring: 'rgba(91, 141, 239, 0.44)',
  text: '#0D1117',
};

export const FOLDER_PRESET_COLORS: ReadonlyArray<{ name: string; hex: string }> = [
  { name: '红色', hex: '#E04F44' },
  { name: '橙色', hex: '#E68A1E' },
  { name: '黄色', hex: '#D9A721' },
  { name: '绿色', hex: '#28A656' },
  { name: '蓝色', hex: '#2A60E0' },
  { name: '青蓝', hex: '#2E86AB' },
  { name: '中性灰', hex: '#7D838B' },
];

/** 10 curated low-saturation filter swatches (DESIGN.md §2.4). */
export const FILTER_PRESET_COLORS: readonly string[] = [
  '#1E2024',
  '#5C6B73',
  '#3D5A80',
  '#4E7D96',
  '#6B8E76',
  '#D4A373',
  '#BA6B55',
  '#E5B243',
  '#C8B8A6',
  '#F0EEE9',
];

export const SMART_FOLDER_PRESET_COLORS: readonly string[] = [
  '#D93B30',
  '#E68A1E',
  '#D9A721',
  '#249A4B',
  '#2E86AB',
  '#2A60E0',
  '#4D7E97',
  '#BA6B55',
  '#18191C',
  '#7D838B',
  '#C8B8A6',
  '#F0EEE9',
];

export const GITHUB_LANGUAGE_COLORS: Record<string, string> = {
  Swift: '#F05138',
  TypeScript: '#3178C6',
  JavaScript: '#E5B243',
  Python: '#3572A5',
  Rust: '#DEA584',
  Go: '#00ADD8',
  HTML: '#E34C26',
  CSS: '#4D7E97',
};

export function getGitHubLanguageColor(language?: string | null): string {
  if (!language) return '#5B8DEF';
  return GITHUB_LANGUAGE_COLORS[language] ?? '#5B8DEF';
}

function parseHexRgb(rawHex: string | null | undefined): [number, number, number] | null {
  if (!rawHex) return null;
  const cleaned = rawHex.replace(/#/g, '').trim();
  if (!/^[0-9a-fA-F]{6}$/.test(cleaned)) return null;
  const val = Number.parseInt(cleaned, 16);
  return [(val >> 16) & 0xff, (val >> 8) & 0xff, val & 0xff];
}

function rgbToHex(r: number, g: number, b: number): string {
  const fmt = (v: number) =>
    Math.max(0, Math.min(255, Math.round(v)))
      .toString(16)
      .padStart(2, '0')
      .toUpperCase();
  return `#${fmt(r)}${fmt(g)}${fmt(b)}`;
}

function rgbToHsl(r: number, g: number, b: number): [number, number, number] {
  const rn = r / 255;
  const gn = g / 255;
  const bn = b / 255;
  const max = Math.max(rn, gn, bn);
  const min = Math.min(rn, gn, bn);
  const d = max - min;
  const l = (max + min) / 2;
  let h = 0;
  let s = 0;
  if (d !== 0) {
    s = d / (1 - Math.abs(2 * l - 1));
    switch (max) {
      case rn:
        h = ((gn - bn) / d) % 6;
        break;
      case gn:
        h = (bn - rn) / d + 2;
        break;
      default:
        h = (rn - gn) / d + 4;
        break;
    }
    h *= 60;
    if (h < 0) h += 360;
  }
  return [h, s, l];
}

function hslToRgb(h: number, s: number, l: number): [number, number, number] {
  const clampedS = Math.max(0, Math.min(1, s));
  const clampedL = Math.max(0, Math.min(1, l));
  const c = (1 - Math.abs(2 * clampedL - 1)) * clampedS;
  const x = c * (1 - Math.abs(((h / 60) % 2) - 1));
  const m = clampedL - c / 2;
  let r1 = 0;
  let g1 = 0;
  let b1 = 0;
  if (h < 60) [r1, g1, b1] = [c, x, 0];
  else if (h < 120) [r1, g1, b1] = [x, c, 0];
  else if (h < 180) [r1, g1, b1] = [0, c, x];
  else if (h < 240) [r1, g1, b1] = [0, x, c];
  else if (h < 300) [r1, g1, b1] = [x, 0, c];
  else [r1, g1, b1] = [c, 0, x];
  return [
    Math.round((r1 + m) * 255),
    Math.round((g1 + m) * 255),
    Math.round((b1 + m) * 255),
  ];
}

function srgbChannelToLinear(c: number): number {
  const s = c / 255;
  return s <= 0.04045 ? s / 12.92 : Math.pow((s + 0.055) / 1.055, 2.4);
}

/** WCAG 2.1 relative luminance (0.0 – 1.0). */
export function relativeLuminance(r: number, g: number, b: number): number {
  return (
    0.2126 * srgbChannelToLinear(r) +
    0.7152 * srgbChannelToLinear(g) +
    0.0722 * srgbChannelToLinear(b)
  );
}

/** WCAG 2.1 contrast ratio between two relative luminances (1.0 – 21.0). */
export function contrastRatio(l1: number, l2: number): number {
  const hi = Math.max(l1, l2);
  const lo = Math.min(l1, l2);
  return (hi + 0.05) / (lo + 0.05);
}

const LIGHT_GALLERY_LUMINANCE = relativeLuminance(0xf6, 0xf6, 0xf5);
const DARK_SURFACE_LUMINANCE = relativeLuminance(0x24, 0x26, 0x2c);
const DARK_INK_LUMINANCE = relativeLuminance(0x11, 0x12, 0x14);
const WHITE_LUMINANCE = 1.0;

/**
 * Derives a WCAG >= 4.5:1 calibrated Fluent 2 accent palette from an arbitrary
 * Windows DWM system accent color (or falls back cleanly to Studio Cobalt).
 */
export function deriveFluentAccentPalette(
  sourceHex: string | null | undefined,
  isDark: boolean,
): FluentAccentPalette {
  const rgb = parseHexRgb(sourceHex);
  if (!rgb) {
    return isDark ? { ...STUDIO_DARK_ACCENT } : { ...STUDIO_LIGHT_ACCENT };
  }

  let [h, s, l] = rgbToHsl(rgb[0], rgb[1], rgb[2]);

  if (!isDark) {
    // Light mode: ensure accent achieves >= 4.5:1 against both light gallery surface and white label ink
    let [ar, ag, ab] = hslToRgb(h, s, l);
    let lum = relativeLuminance(ar, ag, ab);
    for (let i = 0; i < 40; i++) {
      const vsSurface = contrastRatio(lum, LIGHT_GALLERY_LUMINANCE);
      const vsWhite = contrastRatio(lum, WHITE_LUMINANCE);
      if (vsSurface >= 4.5 && vsWhite >= 4.5) break;
      l = Math.max(0.12, l - 0.02);
      [ar, ag, ab] = hslToRgb(h, s, l);
      lum = relativeLuminance(ar, ag, ab);
    }
    const [hr, hg, hb] = hslToRgb(h, s, Math.max(0.08, l - 0.055));
    const [pr, pg, pb] = hslToRgb(h, s, Math.max(0.05, l - 0.11));
    const whiteContrast = contrastRatio(lum, WHITE_LUMINANCE);
    const darkContrast = contrastRatio(lum, DARK_INK_LUMINANCE);
    return {
      accent: rgbToHex(ar, ag, ab),
      hover: rgbToHex(hr, hg, hb),
      pressed: rgbToHex(pr, pg, pb),
      soft: `rgba(${ar}, ${ag}, ${ab}, 0.11)`,
      ring: `rgba(${ar}, ${ag}, ${ab}, 0.35)`,
      text: whiteContrast >= darkContrast ? '#FFFFFF' : '#111214',
    };
  }

  // Dark mode: lift dark colors into a luminous, legible range (>= 4.5:1 against dark elevated cards)
  if (l > 0.78) l = 0.76;
  let [ar, ag, ab] = hslToRgb(h, Math.min(0.92, Math.max(s, s > 0.08 ? 0.55 : s)), l);
  let lum = relativeLuminance(ar, ag, ab);
  for (let i = 0; i < 40; i++) {
    if (contrastRatio(lum, DARK_SURFACE_LUMINANCE) >= 4.5) break;
    l = Math.min(0.84, l + 0.02);
    [ar, ag, ab] = hslToRgb(h, Math.min(0.92, Math.max(s, s > 0.08 ? 0.55 : s)), l);
    lum = relativeLuminance(ar, ag, ab);
  }
  const effectiveS = Math.min(0.92, Math.max(s, s > 0.08 ? 0.55 : s));
  const [hr, hg, hb] = hslToRgb(h, effectiveS, Math.min(0.9, l + 0.055));
  const [pr, pg, pb] = hslToRgb(h, effectiveS, Math.max(0.28, l - 0.06));
  const whiteContrast = contrastRatio(lum, WHITE_LUMINANCE);
  const darkContrast = contrastRatio(lum, DARK_INK_LUMINANCE);

  return {
    accent: rgbToHex(ar, ag, ab),
    hover: rgbToHex(hr, hg, hb),
    pressed: rgbToHex(pr, pg, pb),
    soft: `rgba(${ar}, ${ag}, ${ab}, 0.17)`,
    ring: `rgba(${ar}, ${ag}, ${ab}, 0.44)`,
    text: darkContrast >= whiteContrast ? '#111214' : '#FFFFFF',
  };
}

/**
 * Applies either Studio Cobalt or calibrated Windows system accent CSS tokens to `:root`.
 */
export function applyAccentToDocument(
  accentSource: AccentSource,
  systemAccentHex: string | null | undefined,
  isDark: boolean,
): FluentAccentPalette {
  const palette = deriveFluentAccentPalette(
    accentSource === 'windows' ? systemAccentHex : null,
    isDark,
  );
  if (typeof document !== 'undefined') {
    const root = document.documentElement;
    root.dataset.accentSource = accentSource;
    root.style.setProperty('--accent', palette.accent);
    root.style.setProperty('--accent-hover', palette.hover);
    root.style.setProperty('--accent-pressed', palette.pressed);
    root.style.setProperty('--accent-soft', palette.soft);
    root.style.setProperty('--accent-ring', palette.ring);
    root.style.setProperty('--accent-text', palette.text);
  }
  return palette;
}

export function deriveDuotonePair(rawHex: string, isDark: boolean): DuotonePair | null {
  const rgb = parseHexRgb(rawHex);
  if (!rgb) return null;
  const [r, g, b] = rgb;

  if (isDark) {
    const pr = Math.min(255, r * 0.88 + 255 * 0.12);
    const pg = Math.min(255, g * 0.88 + 255 * 0.12);
    const pb = Math.min(255, b * 0.88 + 255 * 0.12);
    const sr = r * 0.45 + 34 * 0.55;
    const sg = g * 0.45 + 36 * 0.55;
    const sb = b * 0.45 + 42 * 0.55;
    return { primary: rgbToHex(pr, pg, pb), secondary: rgbToHex(sr, sg, sb) };
  }

  return {
    primary: rgbToHex(r, g, b),
    secondary: rgbToHex(r * 0.5 + 127.5, g * 0.5 + 127.5, b * 0.5 + 127.5),
  };
}

/**
 * Low-saturation ambient tint backdrop strictly reserved for Inspector top gradient (0.06/0.10)
 * and Quick Look background (DESIGN.md §2.3).
 */
export function computeAmbientTintStyle(
  hex: string | null | undefined,
  isDark: boolean,
  variant: 'inspector' | 'quicklook' = 'inspector',
): CSSProperties {
  const rgb = parseHexRgb(hex);
  if (!rgb) return {};
  const [r, g, b] = rgb;

  const alpha = variant === 'quicklook' ? (isDark ? 0.14 : 0.10) : isDark ? 0.10 : 0.06;
  return {
    backgroundImage:
      variant === 'quicklook'
        ? `radial-gradient(ellipse 70% 60% at 50% 42%, rgba(${r}, ${g}, ${b}, ${alpha}) 0%, rgba(${r}, ${g}, ${b}, 0) 75%)`
        : `linear-gradient(180deg, rgba(${r}, ${g}, ${b}, ${alpha}) 0%, rgba(${r}, ${g}, ${b}, 0) 100%)`,
  };
}

export function resolveSystemDark(): boolean {
  if (typeof window === 'undefined' || !window.matchMedia) return false;
  return window.matchMedia('(prefers-color-scheme: dark)').matches;
}

export function resolveEffectiveTheme(mode: ThemeMode): 'light' | 'dark' {
  if (mode === 'system') return resolveSystemDark() ? 'dark' : 'light';
  return mode;
}

export function applyThemeToDocument(mode: ThemeMode): 'light' | 'dark' {
  const effective = resolveEffectiveTheme(mode);
  if (typeof document !== 'undefined') {
    const root = document.documentElement;
    root.dataset.theme = effective;
    root.classList.toggle('dark', effective === 'dark');
    const favicon = document.querySelector<HTMLLinkElement>('link[rel="icon"]');
    if (favicon) {
      favicon.href = effective === 'dark' ? '/app-icons/Charkle-Dark.svg' : '/app-icons/Charkle-Light.svg';
    }
  }
  return effective;
}

function readDomResolvedIsDark(): boolean {
  if (typeof document !== 'undefined') {
    const root = document.documentElement;
    if (root.dataset.theme === 'dark') return true;
    if (root.dataset.theme === 'light') return false;
    if (root.classList.contains('dark')) return true;
  }
  return resolveSystemDark();
}

const themeListeners = new Set<() => void>();
let sharedThemeObserver: MutationObserver | null = null;
let sharedColorSchemeMedia: MediaQueryList | null = null;

function notifyThemeListeners() {
  for (const listener of themeListeners) {
    listener();
  }
}

function subscribeThemeChanges(listener: () => void): () => void {
  themeListeners.add(listener);
  if (themeListeners.size === 1) {
    if (typeof document !== 'undefined' && typeof MutationObserver !== 'undefined') {
      sharedThemeObserver = new MutationObserver(notifyThemeListeners);
      sharedThemeObserver.observe(document.documentElement, {
        attributes: true,
        attributeFilter: ['data-theme', 'class'],
      });
    }
    if (typeof window !== 'undefined' && typeof window.matchMedia === 'function') {
      sharedColorSchemeMedia = window.matchMedia('(prefers-color-scheme: dark)');
      sharedColorSchemeMedia.addEventListener?.('change', notifyThemeListeners);
    }
  }
  return () => {
    themeListeners.delete(listener);
    if (themeListeners.size === 0) {
      sharedThemeObserver?.disconnect();
      sharedThemeObserver = null;
      sharedColorSchemeMedia?.removeEventListener?.('change', notifyThemeListeners);
      sharedColorSchemeMedia = null;
    }
  };
}

export function useResolvedIsDark(mode?: ThemeMode): boolean {
  const domDark = useSyncExternalStore(
    subscribeThemeChanges,
    readDomResolvedIsDark,
    () => false,
  );
  if (mode === 'dark') return true;
  if (mode === 'light') return false;
  return domDark;
}

/** Matches macOS & DESIGN.md §7.7 long-strip detection (`height >= 1600 && h/w >= 2.2`). */
export function isLongStripImage(asset: Pick<AssetRecord, 'pixelWidth' | 'pixelHeight' | 'mediaKind'>): boolean {
  if (asset.mediaKind !== 'image' && asset.mediaKind !== 'designFile') return false;
  if (asset.pixelWidth <= 0 || asset.pixelHeight < 1600) return false;
  return asset.pixelHeight / asset.pixelWidth >= 2.2;
}

/** Matches `PhotoExifMetadata::has_meaningful_camera_exif` (DESIGN.md §7.7 zero-noise EXIF gate). */
export function hasMeaningfulCameraExif(exif: PhotoExifMetadata | null | undefined): boolean {
  if (!exif) return false;
  return Boolean(
    exif.cameraMake ||
      exif.cameraModel ||
      exif.lensModel ||
      exif.capturedAt ||
      exif.exposureTime ||
      (exif.fNumber && exif.fNumber > 0) ||
      (exif.iso && exif.iso > 0) ||
      (exif.focalLengthMM && exif.focalLengthMM > 0) ||
      exif.latitude != null ||
      exif.software ||
      exif.artist ||
      exif.copyright,
  );
}

export function isLightHex(rawHex: string | null | undefined): boolean {
  const rgb = parseHexRgb(rawHex);
  if (!rgb) return false;
  const luminance = 0.2126 * (rgb[0] / 255) + 0.7152 * (rgb[1] / 255) + 0.0722 * (rgb[2] / 255);
  return luminance > 0.62;
}

export function formatBytes(bytes: number): string {
  if (!Number.isFinite(bytes) || bytes <= 0) return '0 B';
  const units = ['B', 'KB', 'MB', 'GB', 'TB'];
  let idx = 0;
  let val = bytes;
  while (val >= 1024 && idx < units.length - 1) {
    val /= 1024;
    idx++;
  }
  return `${idx === 0 ? Math.round(val) : val.toFixed(val >= 100 ? 0 : 1)} ${units[idx]}`;
}

export function formatDuration(seconds: number | null | undefined): string {
  if (!seconds || !Number.isFinite(seconds) || seconds <= 0) return '0:00';
  const total = Math.round(seconds);
  const mins = Math.floor(total / 60);
  const secs = total % 60;
  return `${mins}:${String(secs).padStart(2, '0')}`;
}
