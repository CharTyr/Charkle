import React, { useEffect, useRef, useState } from 'react';
import { ArrowLeft, X } from 'lucide-react';
import { CharkleIcon } from '../../design-system';
import { useCoordinatorStore, useSyncAIStore } from '../../stores';
import type { SettingsTabId } from '../../types/domain';
import { SettingsFeedbackBanner } from './SettingsChrome';
import {
  AdvancedAboutSettingsPane,
  CaptureShortcutsSettingsPane,
  DropShelfSettingsPane,
  ExtensionsSettingsPane,
} from './SettingsPanesCaptureSystem';
import {
  GeneralSettingsPane,
  LibrarySettingsPane,
  SyncSettingsPane,
} from './SettingsPanesFoundation';
import { AISettingsPane, ExternalAgentsSettingsPane } from './SettingsPanesIntelligence';

interface SettingsSectionDef {
  id: string;
  title: string;
  tabs: Array<{ id: SettingsTabId; label: string; iconName: string }>;
}

const SETTINGS_SECTIONS: SettingsSectionDef[] = [
  {
    id: 'foundation',
    title: '基础与存储',
    tabs: [
      { id: 'general', label: '通用', iconName: 'settings' },
      { id: 'library', label: '素材库', iconName: 'library' },
      { id: 'sync', label: '云同步', iconName: 'drive-sync' },
    ],
  },
  {
    id: 'capture',
    title: '采集与操作',
    tabs: [
      { id: 'dropShelf', label: '顶部悬浮窗', iconName: 'notch' },
      { id: 'captureShortcuts', label: '采集与快捷键', iconName: 'screenshot' },
    ],
  },
  {
    id: 'ecosystem',
    title: '生态与智能',
    tabs: [
      { id: 'ai', label: 'AI 智能', iconName: 'sparkle-board' },
      { id: 'externalAgents', label: '外部 Agent', iconName: 'connector' },
      { id: 'extensions', label: '插件与扩展', iconName: 'export' },
    ],
  },
  {
    id: 'system',
    title: '系统',
    tabs: [{ id: 'advancedAbout', label: '高级与关于', iconName: 'filter' }],
  },
];

const TAB_LABEL_MAP: Record<SettingsTabId, string> = {
  general: '通用',
  library: '素材库',
  sync: '云同步',
  dropShelf: '顶部悬浮窗',
  captureShortcuts: '采集与快捷键',
  ai: 'AI 智能',
  externalAgents: '外部 Agent',
  extensions: '插件与扩展',
  advancedAbout: '高级与关于',
};

/**
 * Centered 9-Pane Settings Overlay mirroring macOS `SettingsOverlayView.swift` 1:1:
 * - Exact 840 × 636 max geometry with 16px continuous corners & hairline border
 * - 204px calm warm-neutral left navigation rail with duotone CharkleIcon & monochrome active pill
 * - Fixed 52px right pane header with non-destructive `← 返回继续引导` handoff pill & 26px close button
 * - In-overlay dismissible status / error feedback banners above the active pane
 */
export const SettingsOverlay: React.FC = () => {
  const open = useCoordinatorStore((s) => s.settingsOpen);
  const activeTab = useCoordinatorStore((s) => s.settingsTab);
  const setSettingsTab = useCoordinatorStore((s) => s.setSettingsTab);
  const closeSettings = useCoordinatorStore((s) => s.closeSettings);
  const resumeOnboarding = useCoordinatorStore((s) => s.resumeOnboardingOnSettingsClose);
  const onboardingStep = useCoordinatorStore((s) => s.onboardingStep);

  const refreshSettingsData = useSyncAIStore((s) => s.refreshSettingsData);
  const statusMessage = useSyncAIStore((s) => s.statusMessage);
  const errorMessage = useSyncAIStore((s) => s.errorMessage);
  const clearStatusMessage = useSyncAIStore((s) => s.clearStatusMessage);
  const clearErrorMessage = useSyncAIStore((s) => s.clearErrorMessage);

  const [rendered, setRendered] = useState(open);
  const [closing, setClosing] = useState(false);
  const scrollRef = useRef<HTMLDivElement | null>(null);

  useEffect(() => {
    if (open) {
      setClosing(false);
      setRendered(true);
      return;
    }
    if (!rendered) return;
    setClosing(true);
    const timer = window.setTimeout(() => {
      setRendered(false);
      setClosing(false);
    }, 175);
    return () => window.clearTimeout(timer);
  }, [open, rendered]);

  useEffect(() => {
    if (!open) return;
    clearStatusMessage();
    clearErrorMessage();
    void refreshSettingsData();
    const onKeyDown = (e: KeyboardEvent) => {
      if (e.key === 'Escape' && !e.defaultPrevented) {
        if (document.querySelector('[data-charkle-popover-open="true"]')) return;
        e.preventDefault();
        closeSettings();
      }
    };
    window.addEventListener('keydown', onKeyDown);
    return () => window.removeEventListener('keydown', onKeyDown);
  }, [open, refreshSettingsData, closeSettings, clearStatusMessage, clearErrorMessage]);

  useEffect(() => {
    if (scrollRef.current) {
      scrollRef.current.scrollTop = 0;
    }
  }, [activeTab, open]);

  if (!rendered) return null;

  return (
    <div
      data-testid="settings-overlay"
      role="dialog"
      aria-modal="true"
      aria-label="Charkle 设置中心"
      className="fixed inset-0 z-50 flex items-center justify-center p-6"
    >
      <div
        data-closing={closing ? 'true' : undefined}
        onClick={closeSettings}
        className="charkle-modal-scrim fixed inset-0"
      />

      <div
        data-closing={closing ? 'true' : undefined}
        className="charkle-modal-panel relative z-10 w-[min(840px,calc(100vw-48px))] h-[min(636px,calc(100vh-48px))] rounded-[16px] bg-[var(--settings-content)] border border-[var(--settings-border)] shadow-[var(--shadow-modal)] flex overflow-hidden"
      >
        {/* Left 204px 4-Section 9-Pane Navigation Rail */}
        <aside className="w-[204px] shrink-0 bg-[var(--settings-rail)] border-r border-[var(--settings-divider)] flex flex-col select-none">
          <div className="h-[52px] px-4 flex items-center shrink-0">
            <span className="text-[14.5px] font-semibold text-[var(--text-primary)]">设置</span>
          </div>

          <nav
            aria-label="设置分类导航"
            className="flex-1 overflow-y-auto charkle-scroll-hidden px-2 pb-4 flex flex-col gap-3.5"
          >
            {SETTINGS_SECTIONS.map((sec) => (
              <div key={sec.id} className="flex flex-col gap-0.5">
                <div className="px-3 pb-1 text-[10.5px] font-medium text-[var(--settings-label)]">
                  {sec.title}
                </div>
                {sec.tabs.map((tab) => {
                  const active = activeTab === tab.id;
                  return (
                    <button
                      key={tab.id}
                      type="button"
                      role="tab"
                      aria-selected={active}
                      onClick={() => setSettingsTab(tab.id)}
                      className={[
                        'charkle-pressable w-full px-2.5 py-[7px] rounded-[8px] flex items-center gap-[9px] text-[12.5px] cursor-pointer text-left transition-colors duration-150 motion-reduce:transition-none',
                        active
                          ? 'bg-black/[0.075] dark:bg-white/[0.10] text-[var(--text-primary)] font-semibold'
                          : 'text-[var(--text-primary)]/76 hover:bg-black/[0.04] dark:hover:bg-white/[0.05] font-normal',
                      ].join(' ')}
                    >
                      <CharkleIcon
                        name={tab.iconName}
                        style="duotone"
                        size={15}
                        isActive={active}
                      />
                      <span className="truncate">{tab.label}</span>
                    </button>
                  );
                })}
              </div>
            ))}
          </nav>
        </aside>

        {/* Right Focused Pane Content Column */}
        <div className="flex-1 min-w-0 flex flex-col bg-[var(--settings-content)]">
          <header className="h-[52px] px-6 border-b border-[var(--settings-divider)] flex items-center justify-between gap-2.5 shrink-0 select-none">
            <h2 className="text-[15px] font-semibold text-[var(--text-primary)] truncate">
              {TAB_LABEL_MAP[activeTab]}
            </h2>

            <div className="flex items-center gap-2 shrink-0">
              {resumeOnboarding && (
                <button
                  type="button"
                  data-testid="settings-return-onboarding"
                  onClick={closeSettings}
                  title={`返回新手引导第 ${onboardingStep + 1} 步继续配置 (Esc)`}
                  className="charkle-pressable h-[28px] px-3 rounded-full bg-[#18191D] text-white hover:bg-[#2B2D33] dark:bg-white dark:text-[#111215] dark:hover:bg-white/90 text-[12px] font-semibold inline-flex items-center gap-1.5 cursor-pointer transition-colors duration-150 motion-reduce:transition-none"
                >
                  <ArrowLeft size={12.5} />
                  <span>返回继续引导</span>
                </button>
              )}

              <button
                type="button"
                aria-label={resumeOnboarding ? '返回继续引导' : '关闭设置'}
                title={resumeOnboarding ? '返回继续引导 (Esc)' : '关闭设置 (Esc)'}
                onClick={closeSettings}
                className="charkle-pressable h-[26px] w-[26px] rounded-full bg-[var(--settings-subtle)] hover:bg-black/[0.08] dark:hover:bg-white/[0.10] inline-flex items-center justify-center text-[var(--text-secondary)] hover:text-[var(--text-primary)] cursor-pointer transition-colors duration-150 motion-reduce:transition-none"
              >
                <X size={13} />
              </button>
            </div>
          </header>

          <div ref={scrollRef} className="flex-1 min-h-0 overflow-y-auto charkle-scroll px-6 py-5">
            <div className="flex flex-col gap-[18px]">
              {statusMessage && (
                <SettingsFeedbackBanner
                  text={statusMessage}
                  isError={false}
                  onDismiss={clearStatusMessage}
                />
              )}
              {errorMessage && (
                <SettingsFeedbackBanner
                  text={errorMessage}
                  isError={true}
                  onDismiss={clearErrorMessage}
                />
              )}

              <div key={activeTab} className="charkle-pane-fade">
                {activeTab === 'general' && <GeneralSettingsPane />}
                {activeTab === 'library' && <LibrarySettingsPane />}
                {activeTab === 'sync' && <SyncSettingsPane />}
                {activeTab === 'dropShelf' && <DropShelfSettingsPane />}
                {activeTab === 'captureShortcuts' && <CaptureShortcutsSettingsPane />}
                {activeTab === 'ai' && <AISettingsPane />}
                {activeTab === 'externalAgents' && <ExternalAgentsSettingsPane />}
                {activeTab === 'extensions' && <ExtensionsSettingsPane />}
                {activeTab === 'advancedAbout' && <AdvancedAboutSettingsPane />}
              </div>
            </div>
          </div>
        </div>
      </div>
    </div>
  );
};
