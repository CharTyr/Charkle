import type { GroupTint, MoodboardAgentPhase, NoteStyle } from '@charkle/shared';

export interface NoteThemeTokens {
  label: string;
  background: string;
  foreground: string;
  mutedForeground: string;
  border: string;
}

export const NOTE_STYLE_PALETTE: Record<NoteStyle, NoteThemeTokens> = {
  paper: {
    label: '纸白',
    background: '#FFFFFF',
    foreground: '#1D1F23',
    mutedForeground: 'rgba(29, 31, 35, 0.56)',
    border: 'rgba(0, 0, 0, 0.09)',
  },
  ink: {
    label: '墨黑',
    background: '#1D1F24',
    foreground: '#F1F2F4',
    mutedForeground: 'rgba(241, 242, 244, 0.62)',
    border: 'rgba(255, 255, 255, 0.14)',
  },
  warm: {
    label: '暖沙',
    background: '#F7F0E4',
    foreground: '#392F22',
    mutedForeground: 'rgba(57, 47, 34, 0.58)',
    border: 'rgba(201, 183, 156, 0.45)',
  },
  sage: {
    label: '鼠尾草',
    background: '#E8F0EA',
    foreground: '#203227',
    mutedForeground: 'rgba(32, 50, 39, 0.58)',
    border: 'rgba(154, 181, 163, 0.45)',
  },
  slate: {
    label: '岩灰',
    background: '#E9EEF3',
    foreground: '#1F2B36',
    mutedForeground: 'rgba(31, 43, 54, 0.58)',
    border: 'rgba(158, 176, 194, 0.45)',
  },
};

export interface GroupTintTokens {
  label: string;
  accent: string;
  tintLight: string;
  tintDark: string;
  borderLight: string;
  borderDark: string;
}

export const GROUP_TINT_PALETTE: Record<GroupTint, GroupTintTokens> = {
  neutral: {
    label: '中性灰',
    accent: '#7D838B',
    tintLight: 'rgba(125, 131, 139, 0.06)',
    tintDark: 'rgba(125, 131, 139, 0.11)',
    borderLight: 'rgba(125, 131, 139, 0.28)',
    borderDark: 'rgba(125, 131, 139, 0.36)',
  },
  sand: {
    label: '暖沙',
    accent: '#B5956B',
    tintLight: 'rgba(181, 149, 107, 0.07)',
    tintDark: 'rgba(181, 149, 107, 0.12)',
    borderLight: 'rgba(181, 149, 107, 0.32)',
    borderDark: 'rgba(181, 149, 107, 0.40)',
  },
  sage: {
    label: '青苔',
    accent: '#6B8E76',
    tintLight: 'rgba(107, 142, 118, 0.07)',
    tintDark: 'rgba(107, 142, 118, 0.12)',
    borderLight: 'rgba(107, 142, 118, 0.32)',
    borderDark: 'rgba(107, 142, 118, 0.40)',
  },
  slate: {
    label: '板岩',
    accent: '#627A94',
    tintLight: 'rgba(98, 122, 148, 0.07)',
    tintDark: 'rgba(98, 122, 148, 0.12)',
    borderLight: 'rgba(98, 122, 148, 0.32)',
    borderDark: 'rgba(98, 122, 148, 0.40)',
  },
  terracotta: {
    label: '陶土',
    accent: '#BA6B55',
    tintLight: 'rgba(186, 107, 85, 0.07)',
    tintDark: 'rgba(186, 107, 85, 0.12)',
    borderLight: 'rgba(186, 107, 85, 0.32)',
    borderDark: 'rgba(186, 107, 85, 0.40)',
  },
  ocean: {
    label: '深海',
    accent: '#4D7E97',
    tintLight: 'rgba(77, 126, 151, 0.07)',
    tintDark: 'rgba(77, 126, 151, 0.12)',
    borderLight: 'rgba(77, 126, 151, 0.32)',
    borderDark: 'rgba(77, 126, 151, 0.40)',
  },
};

export const NOTE_FONT_SIZES = [12, 14, 16, 20] as const;

export const CALM_INK_SWATCHES: ReadonlyArray<{ name: string; hex: string }> = [
  { name: '陶红', hex: '#D95D48' },
  { name: '墨炭', hex: '#2C3038' },
  { name: '钴蓝', hex: '#3D6A99' },
  { name: '青苔', hex: '#4D7C5F' },
  { name: '赭黄', hex: '#C7933B' },
  { name: '粉白', hex: '#EFECE6' },
];

export const CONNECTOR_SWATCHES: ReadonlyArray<{ name: string; hex: string }> = [
  { name: '板岩灰', hex: '#5C6672' },
  { name: '陶红', hex: '#D95D48' },
  { name: '钴蓝', hex: '#3D6A99' },
  { name: '青苔', hex: '#4D7C5F' },
  { name: '赭黄', hex: '#C7933B' },
  { name: '墨黑', hex: '#1F2329' },
];

export const INK_STROKE_WIDTHS: ReadonlyArray<{ label: string; value: number }> = [
  { label: '细', value: 2.0 },
  { label: '中', value: 3.5 },
  { label: '粗', value: 6.5 },
];

export const CURATED_GENERATOR_SWATCHES: readonly string[] = [
  '#253237',
  '#3D5A80',
  '#5C6B73',
  '#6B8E76',
  '#D4A373',
  '#C8B8A6',
  '#BA6B55',
  '#E5B243',
  '#1E2024',
  '#DCDAD4',
];

export const GENERATOR_PRESET_PROMPTS: readonly string[] = [
  '夏日清凉插画与通透蓝天阳光',
  '极简暖调陶艺、纸张肌理与自然光影',
  '瑞士网格排版与高级编辑部视觉',
  '现代暗色数据界面与克制科技感',
];

export const AGENT_PHASE_META: Record<
  MoodboardAgentPhase,
  { label: string; shortLabel: string; order: number }
> = {
  planning: { label: '规划检索策略', shortLabel: '规划', order: 0 },
  retrieving: { label: '多路召回候选', shortLabel: '召回', order: 1 },
  inspectingVisuals: { label: '视觉联系表审片', shortLabel: '审片', order: 2 },
  composing: { label: '分区编排与聚焦裁切', shortLabel: '编排', order: 3 },
  verifying: { label: '校验槽位与约束', shortLabel: '校验', order: 4 },
  repairing: { label: '确定性修复', shortLabel: '修复', order: 5 },
  completed: { label: '策展完成', shortLabel: '完成', order: 6 },
  fallbackOffline: { label: '离线策展完成', shortLabel: '离线完成', order: 6 },
};
