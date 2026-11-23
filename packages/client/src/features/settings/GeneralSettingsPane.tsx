import React from 'react';
import { Check, Laptop, Moon, Sparkles, Sun } from 'lucide-react';
import type { GalleryLayoutMode } from '@charkle/shared';
import { CharkleBrandMark } from '../../design-system/CharkleIcon';
import type { ThemeMode } from '../../design-system/theme';
import { useCoordinatorStore } from '../../stores/coordinatorStore';
import {
  SettingsButton,
  SettingsCardDivider,
  SettingsRow,
  SettingsSection,
  SettingsSegmented,
  SettingsSwitch,
} from './SettingsChrome';

const THEME_OPTIONS: ReadonlyArray<{
  id: ThemeMode;
  label: string;
  icon: React.ReactNode;
  bg: string;
  card: string;
  bar: string;
}> = [
  {
    id: 'light',
    label: '浅色',
    icon: <Sun size={12} />,
    bg: '#F4F4F2',
    card: '#FFFFFF',
    bar: '#E5E5E2',
  },
  {
    id: 'dark',
    label: '深色',
    icon: <Moon size={12} />,
    bg: '#151619',
    card: '#22242A',
    bar: '#2B2D34',
  },
  {
    id: 'system',
    label: '跟随系统',
    icon: <Laptop size={12} />,
    bg: 'linear-gradient(135deg, #F4F4F2 50%, #151619 50%)',
    card: '#FFFFFF',
    bar: '#D4D4D8',
  },
];

const ICON_VARIANTS: ReadonlyArray<{
  id: 'auto' | 'light' | 'dark';
  label: string;
  hint: string;
}> = [
  { id: 'auto', label: '跟随主题', hint: '随明暗自动切换' },
  { id: 'light', label: '浅色图标', hint: '固定浅色标识' },
  { id: 'dark', label: '深色图标', hint: '固定深色标识' },
];

const LAYOUT_OPTIONS: ReadonlyArray<{ id: GalleryLayoutMode; label: string }> = [
  { id: 'verticalMasonry', label: '纵向瀑布流' },
  { id: 'horizontalJustified', label: '横向等高行' },
  { id: 'galleryFilmstrip', label: '画廊视图' },
];

export const GeneralSettingsPane: React.FC = () => {
  const themeMode = useCoordinatorStore((s) => s.themeMode);
  const setThemeMode = useCoordinatorStore((s) => s.setThemeMode);
  const brandIconVariant = useCoordinatorStore((s) => s.brandIconVariant);
  const setBrandIconVariant = useCoordinatorStore((s) => s.setBrandIconVariant);
  const layoutMode = useCoordinatorStore((s) => s.layoutMode);
  const setLayoutMode = useCoordinatorStore((s) => s.setLayoutMode);
  const sidebarCollapsed = useCoordinatorStore((s) => s.sidebarCollapsed);
  const setSidebarCollapsed = useCoordinatorStore((s) => s.setSidebarCollapsed);
  const closeSettings = useCoordinatorStore((s) => s.closeSettings);
  const presentOnboarding = useCoordinatorStore((s) => s.presentOnboarding);

  return (
    <div className="flex flex-col gap-[22px]">
      {/* 外观与图标 */}
      <SettingsSection title="外观与图标">
        {/* Theme Mode Cards */}
        <div className="px-4 py-3.5 flex flex-col gap-2.5">
          <div className="flex items-baseline justify-between gap-2">
            <span className="text-[13px] font-medium text-[var(--text-primary)]">主题模式</span>
            <span className="text-[11px] text-[var(--settings-label,var(--text-tertiary))]">
              切换界面的明暗外观
            </span>
          </div>
          <div className="grid grid-cols-3 gap-2.5">
            {THEME_OPTIONS.map((opt) => {
              const active = themeMode === opt.id;
              return (
                <button
                  key={opt.id}
                  type="button"
                  aria-pressed={active}
                  onClick={() => setThemeMode(opt.id)}
                  className={[
                    'charkle-pressable flex flex-col gap-2 p-2 rounded-[10px] border text-left cursor-pointer',
                    'transition-[border-color,background-color] duration-[var(--duration-press,120ms)] ease-[var(--ease-out)]',
                    active
                      ? 'border-[var(--accent)] bg-[var(--accent-soft)]/50'
                      : 'border-[var(--settings-border,var(--border-hairline))] bg-[var(--settings-subtle,var(--bg-subtle))] hover:border-[var(--border-strong)]',
                  ].join(' ')}
                >
                  <div
                    className="h-12 w-full rounded-[6px] border border-black/10 dark:border-white/10 p-1.5 flex items-end justify-between relative overflow-hidden"
                    style={{ background: opt.bg }}
                  >
                    <div className="flex flex-col gap-1">
                      <span
                        className="w-9 h-2 rounded-[2px]"
                        style={{ background: opt.bar }}
                      />
                      <span
                        className="w-7 h-4 rounded-[3px] border border-black/10"
                        style={{ background: opt.card }}
                      />
                    </div>
                    <span
                      className="w-4.5 h-4.5 rounded-full inline-flex items-center justify-center"
                      style={{
                        background: active ? 'var(--accent)' : 'rgba(128,128,128,0.22)',
                        color: active ? '#FFFFFF' : '#71717A',
                      }}
                    >
                      {active ? <Check size={10} strokeWidth={2.8} /> : opt.icon}
                    </span>
                  </div>
                  <span className="text-[12px] font-medium text-[var(--text-primary)] px-0.5">
                    {opt.label}
                  </span>
                </button>
              );
            })}
          </div>
        </div>

        <SettingsCardDivider />

        {/* App Icon Style Cards */}
        <div className="px-4 py-3.5 flex flex-col gap-2.5">
          <div className="flex items-baseline justify-between gap-2">
            <span className="text-[13px] font-medium text-[var(--text-primary)]">应用图标</span>
            <span className="text-[11px] text-[var(--settings-label,var(--text-tertiary))]">
              侧边栏与浏览器标签页图标风格
            </span>
          </div>
          <div className="grid grid-cols-3 gap-2.5">
            {ICON_VARIANTS.map((opt) => {
              const active = brandIconVariant === opt.id;
              return (
                <button
                  key={opt.id}
                  type="button"
                  aria-pressed={active}
                  onClick={() => setBrandIconVariant(opt.id)}
                  className={[
                    'charkle-pressable flex items-center gap-2.5 p-2.5 rounded-[10px] border text-left cursor-pointer',
                    'transition-[border-color,background-color] duration-[var(--duration-press,120ms)] ease-[var(--ease-out)]',
                    active
                      ? 'border-[var(--accent)] bg-[var(--accent-soft)]/50'
                      : 'border-[var(--settings-border,var(--border-hairline))] bg-[var(--settings-subtle,var(--bg-subtle))] hover:border-[var(--border-strong)]',
                  ].join(' ')}
                >
                  <CharkleBrandMark size={30} variant={opt.id} />
                  <div className="min-w-0 flex-1">
                    <div className="text-[12px] font-medium text-[var(--text-primary)] truncate">
                      {opt.label}
                    </div>
                    <div className="text-[10.5px] text-[var(--text-tertiary)] truncate">
                      {opt.hint}
                    </div>
                  </div>
                </button>
              );
            })}
          </div>
        </div>

        <SettingsCardDivider />

        {/* Default Gallery Layout */}
        <SettingsRow
          title="画廊默认排布"
          subtitle="浏览全部素材与文件夹时的默认排列方式"
        >
          <SettingsSegmented
            ariaLabel="画廊默认排布"
            options={LAYOUT_OPTIONS}
            value={layoutMode}
            onChange={setLayoutMode}
          />
        </SettingsRow>

        <SettingsCardDivider />

        {/* Compact Sidebar */}
        <SettingsRow
          title="默认收起侧边栏为精简图标栏"
          subtitle="给瀑布流留出更宽画幅，随时可用 ⌘\ 切换展开"
        >
          <SettingsSwitch
            ariaLabel="默认收起侧边栏为精简图标栏"
            checked={sidebarCollapsed}
            onChange={setSidebarCollapsed}
          />
        </SettingsRow>
      </SettingsSection>

      {/* 入门与帮助 */}
      <SettingsSection title="入门与帮助">
        <SettingsRow
          title="快速上手引导"
          subtitle="随时重温素材库存储、浏览器扩展、AI 智能与外观配置"
        >
          <SettingsButton
            variant="primary"
            onClick={() => {
              closeSettings();
              presentOnboarding();
            }}
          >
            <Sparkles size={12} />
            重新查看
          </SettingsButton>
        </SettingsRow>
      </SettingsSection>
    </div>
  );
};
