import { useEffect, useState } from 'react';
import type { CSSProperties } from 'react';
import type { AssetRecord, PhotoExifMetadata } from '../types/domain';

export type ThemeMode = 'system' | 'light' | 'dark';

export interface DuotonePair {
  primary: string;
  secondary: string;
}

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

export function deriveDuotonePair(rawHex: string, isDark: boolean): DuotonePair | null {
  const cleaned = rawHex.replace(/#/g, '').trim();
  if (!/^[0-9a-fA-F]{6}$/.test(cleaned)) return null;
  const val = Number.parseInt(cleaned, 16);
  const r = (val >> 16) & 0xff;
  const g = (val >> 8) & 0xff;
  const b = val & 0xff;

  const toHex = (cr: number, cg: number, cb: number): string => {
    const fmt = (v: number) =>
      Math.max(0, Math.min(255, Math.round(v)))
        .toString(16)
        .padStart(2, '0')
        .toUpperCase();
    return `#${fmt(cr)}${fmt(cg)}${fmt(cb)}`;
  };

  if (isDark) {
    const pr = Math.min(255, r * 0.88 + 255 * 0.12);
    const pg = Math.min(255, g * 0.88 + 255 * 0.12);
    const pb = Math.min(255, b * 0.88 + 255 * 0.12);
    const sr = r * 0.45 + 34 * 0.55;
    const sg = g * 0.45 + 36 * 0.55;
    const sb = b * 0.45 + 42 * 0.55;
    return { primary: toHex(pr, pg, pb), secondary: toHex(sr, sg, sb) };
  }

  return {
    primary: `#${cleaned.toUpperCase()}`,
    secondary: toHex(r * 0.5 + 127.5, g * 0.5 + 127.5, b * 0.5 + 127.5),
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
  if (!hex) return {};
  const cleaned = hex.replace(/#/g, '').trim();
  if (!/^[0-9a-fA-F]{6}$/.test(cleaned)) return {};
  const val = Number.parseInt(cleaned, 16);
  const r = (val >> 16) & 0xff;
  const g = (val >> 8) & 0xff;
  const b = val & 0xff;

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

export function useResolvedIsDark(mode?: ThemeMode): boolean {
  const [domDark, setDomDark] = useState<boolean>(() => {
    if (mode === 'dark') return true;
    if (mode === 'light') return false;
    if (typeof document !== 'undefined' && document.documentElement.dataset.theme) {
      return document.documentElement.dataset.theme === 'dark';
    }
    return resolveSystemDark();
  });

  useEffect(() => {
    if (mode === 'dark') {
      setDomDark(true);
      return;
    }
    if (mode === 'light') {
      setDomDark(false);
      return;
    }
    if (typeof document === 'undefined' || typeof MutationObserver === 'undefined') return;
    const root = document.documentElement;
    const sync = () => setDomDark(root.dataset.theme === 'dark');
    sync();
    const obs = new MutationObserver(sync);
    obs.observe(root, { attributes: true, attributeFilter: ['data-theme', 'class'] });
    return () => obs.disconnect();
  }, [mode]);

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
