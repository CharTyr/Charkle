import { useEffect, useState } from 'react';
import type { CSSProperties } from 'react';
import type { GroupTint, NoteStyle } from '@charkle/shared';

export type ThemeMode = 'system' | 'light' | 'dark';

export interface DuotonePair {
  primary: string;
  secondary: string;
}

/**
 * Exact 7 macOS folder preset colors matching `FolderCustomizationPopover.swift`.
 */
export const MACOS_FOLDER_COLORS: ReadonlyArray<{ name: string; hex: string }> = [
  { name: '红色', hex: '#FF453A' },
  { name: '橙色', hex: '#FF9F0A' },
  { name: '黄色', hex: '#FFD60A' },
  { name: '绿色', hex: '#30D158' },
  { name: '蓝色', hex: '#0A84FF' },
  { name: '紫色', hex: '#BF5AF2' },
  { name: '灰色', hex: '#8E8E93' },
];

/**
 * 10 curated visual filter palette swatches matching macOS `MainWindowView`.
 */
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

/**
 * 12 Smart Folder editor preset swatches matching macOS `SmartFolderEditorSheet`.
 */
export const SMART_FOLDER_PRESET_COLORS: readonly string[] = [
  '#E11D48',
  '#F97316',
  '#F59E0B',
  '#10B981',
  '#06B6D4',
  '#3B82F6',
  '#6366F1',
  '#EC4899',
  '#18181B',
  '#71717A',
  '#E4E4E7',
  '#FFFFFF',
];

/**
 * Calm Note themes matching `PARITY_SPEC.md` §8.2.
 */
export const NOTE_STYLE_THEMES: Record<
  NoteStyle,
  { label: string; bg: string; fg: string; border: string }
> = {
  paper: { label: '纸白', bg: '#FFFFFF', fg: '#1D1F23', border: 'rgba(29, 31, 35, 0.10)' },
  ink: { label: '墨黑', bg: '#1D1F24', fg: '#F1F2F4', border: 'rgba(255, 255, 255, 0.14)' },
  warm: { label: '暖米', bg: '#F7F0E4', fg: '#392F22', border: 'rgba(57, 47, 34, 0.12)' },
  sage: { label: '鼠尾草', bg: '#E8F0EA', fg: '#203227', border: 'rgba(32, 50, 39, 0.12)' },
  slate: { label: '石板蓝', bg: '#E9EEF3', fg: '#1F2B36', border: 'rgba(31, 43, 54, 0.12)' },
};

/**
 * Group Frame tints matching `PARITY_SPEC.md` §8.2.
 */
export const GROUP_TINT_THEMES: Record<GroupTint, { label: string; hex: string }> = {
  neutral: { label: '中性灰', hex: '#7D838B' },
  sand: { label: '砂岩', hex: '#B5956B' },
  sage: { label: '苔绿', hex: '#6B8E76' },
  slate: { label: '石青', hex: '#627A94' },
  terracotta: { label: '陶土', hex: '#BA6B55' },
  ocean: { label: '海蓝', hex: '#4D7E97' },
};

/**
 * Ink Pen curated palette swatches matching `PARITY_SPEC.md` §8.2.
 */
export const INK_PEN_SWATCHES: readonly string[] = [
  '#D95D48',
  '#2C3038',
  '#3D6A99',
  '#4D7C5F',
  '#C7933B',
  '#EFECE6',
];

/**
 * GitHub language dot colors matching `PARITY_SPEC.md` §2.1.
 */
export const GITHUB_LANGUAGE_COLORS: Record<string, string> = {
  Swift: '#F05138',
  TypeScript: '#3178C6',
  JavaScript: '#F1E05A',
  Python: '#3572A5',
  Rust: '#DEA584',
  Go: '#00ADD8',
  HTML: '#E34C26',
  CSS: '#563D7C',
};

export function getGitHubLanguageColor(language?: string | null): string {
  if (!language) return '#60A5FA';
  return GITHUB_LANGUAGE_COLORS[language] ?? '#60A5FA';
}

/**
 * Exact port of Swift `CharkleIconCache.deriveDuotonePair(from:isDark:)`.
 * Light mode: primary = #RRGGBB, secondary = 50% tint over #FFFFFF.
 * Dark mode: primary = 88% color + 12% white, secondary = 45% color over #22242A.
 */
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

  const sr = r * 0.5 + 255 * 0.5;
  const sg = g * 0.5 + 255 * 0.5;
  const sb = b * 0.5 + 255 * 0.5;
  return { primary: `#${cleaned.toUpperCase()}`, secondary: toHex(sr, sg, sb) };
}

/**
 * Low-saturation ambient tint backdrop from a dominant swatch HEX.
 * Light mode opacity: 0.06; Dark mode opacity: 0.10.
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

  const alpha = variant === 'quicklook' ? (isDark ? 0.16 : 0.11) : isDark ? 0.10 : 0.06;
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

export function applyThemeToDocument(mode: ThemeMode, iconVariant?: 'auto' | 'light' | 'dark'): 'light' | 'dark' {
  const effective = resolveEffectiveTheme(mode);
  if (typeof document !== 'undefined') {
    const root = document.documentElement;
    root.dataset.theme = effective;
    root.classList.toggle('dark', effective === 'dark');

    const favicon = document.querySelector<HTMLLinkElement>('link[rel="icon"]');
    if (favicon) {
      const targetDark = iconVariant === 'dark' || (iconVariant !== 'light' && effective === 'dark');
      favicon.href = targetDark ? '/app-icons/Charkle-Dark.svg' : '/app-icons/Charkle-Light.svg';
    }
  }
  return effective;
}

export function useSystemDarkMode(): boolean {
  const [isDark, setIsDark] = useState<boolean>(() => resolveSystemDark());
  useEffect(() => {
    if (typeof window === 'undefined' || !window.matchMedia) return;
    const mq = window.matchMedia('(prefers-color-scheme: dark)');
    const handler = (e: MediaQueryListEvent) => setIsDark(e.matches);
    setIsDark(mq.matches);
    mq.addEventListener('change', handler);
    return () => mq.removeEventListener('change', handler);
  }, []);
  return isDark;
}

export function useResolvedIsDark(mode?: ThemeMode): boolean {
  const sysDark = useSystemDarkMode();
  const [domDark, setDomDark] = useState<boolean>(() =>
    typeof document !== 'undefined' ? document.documentElement.dataset.theme === 'dark' : sysDark,
  );

  useEffect(() => {
    if (mode) return;
    if (typeof document === 'undefined' || typeof MutationObserver === 'undefined') return;
    const root = document.documentElement;
    const update = () => setDomDark(root.dataset.theme === 'dark');
    update();
    const obs = new MutationObserver(update);
    obs.observe(root, { attributes: true, attributeFilter: ['data-theme', 'class'] });
    return () => obs.disconnect();
  }, [mode]);

  if (mode === 'dark') return true;
  if (mode === 'light') return false;
  if (mode === 'system') return sysDark;
  return domDark;
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
