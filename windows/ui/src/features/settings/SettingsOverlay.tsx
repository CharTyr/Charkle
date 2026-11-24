import React, { useEffect, useRef } from 'react';
import { Dialog as BaseDialog } from '@base-ui/react/dialog';
import {
  ArrowLeft16Regular,
  CloudSync20Filled,
  CloudSync20Regular,
  Dismiss16Regular,
  Folder20Filled,
  Folder20Regular,
  Info20Filled,
  Info20Regular,
  PlugConnected20Filled,
  PlugConnected20Regular,
  PuzzlePiece20Filled,
  PuzzlePiece20Regular,
  Screenshot20Filled,
  Screenshot20Regular,
  Settings20Filled,
  Settings20Regular,
  Sparkle20Filled,
  Sparkle20Regular,
  WindowHeaderHorizontal20Filled,
  WindowHeaderHorizontal20Regular,
  bundleIcon,
  type FluentIcon,
} from '@fluentui/react-icons';
import { Button, LayoutGroup, m, WIN_SPRING_SNAPPY } from '../../design-system';
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

const GeneralNavIcon = bundleIcon(Settings20Filled, Settings20Regular);
const LibraryNavIcon = bundleIcon(Folder20Filled, Folder20Regular);
const SyncNavIcon = bundleIcon(CloudSync20Filled, CloudSync20Regular);
const DropShelfNavIcon = bundleIcon(
  WindowHeaderHorizontal20Filled,
  WindowHeaderHorizontal20Regular,
);
const CaptureShortcutsNavIcon = bundleIcon(Screenshot20Filled, Screenshot20Regular);
const AINavIcon = bundleIcon(Sparkle20Filled, Sparkle20Regular);
const ExternalAgentsNavIcon = bundleIcon(PlugConnected20Filled, PlugConnected20Regular);
const ExtensionsNavIcon = bundleIcon(PuzzlePiece20Filled, PuzzlePiece20Regular);
const AdvancedAboutNavIcon = bundleIcon(Info20Filled, Info20Regular);

interface SettingsSectionDef {
  id: string;
  title: string;
  tabs: Array<{ id: SettingsTabId; label: string; icon: FluentIcon }>;
}

const SETTINGS_SECTIONS: SettingsSectionDef[] = [
  {
    id: 'foundation',
    title: '基础与存储',
    tabs: [
      { id: 'general', label: '通用', icon: GeneralNavIcon },
      { id: 'library', label: '素材库', icon: LibraryNavIcon },
      { id: 'sync', label: '云同步', icon: SyncNavIcon },
    ],
  },
  {
    id: 'capture',
    title: '采集与操作',
    tabs: [
      { id: 'dropShelf', label: '顶部悬浮窗', icon: DropShelfNavIcon },
      { id: 'captureShortcuts', label: '采集与快捷键', icon: CaptureShortcutsNavIcon },
    ],
  },
  {
    id: 'ecosystem',
    title: '生态与智能',
    tabs: [
      { id: 'ai', label: 'AI 智能', icon: AINavIcon },
      { id: 'externalAgents', label: '外部 Agent', icon: ExternalAgentsNavIcon },
      { id: 'extensions', label: '插件与扩展', icon: ExtensionsNavIcon },
    ],
  },
  {
    id: 'system',
    title: '系统',
    tabs: [{ id: 'advancedAbout', label: '高级与关于', icon: AdvancedAboutNavIcon }],
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

const stopDialogPropagation = {
  onMouseDown: (e: React.MouseEvent) => e.stopPropagation(),
  onPointerDown: (e: React.PointerEvent) => e.stopPropagation(),
  onClick: (e: React.MouseEvent) => e.stopPropagation(),
  onDoubleClick: (e: React.MouseEvent) => e.stopPropagation(),
  onContextMenu: (e: React.MouseEvent) => e.stopPropagation(),
};

/**
 * Centered Fluent 2 9-Pane Settings Modal (fluent2-design-system.md §1.2 & §5):
 * - Centered modal form factor (max 880 x 660px, 10px dialog radius, .win-smoke-scrim)
 * - Left 212px Fluent navigation rail with 3px x 16px spring accent indicator + Regular/Filled icons
 * - Fixed 52px pane header with non-destructive onboarding return pill & Fluent subtle close button
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

  const scrollRef = useRef<HTMLDivElement | null>(null);

  useEffect(() => {
    if (!open) return;
    clearStatusMessage();
    clearErrorMessage();
    void refreshSettingsData();
    const onKeyDown = (e: KeyboardEvent) => {
      if (e.key === 'Escape' && !e.defaultPrevented) {
        if (document.querySelector('[data-charkle-popover-open="true"]')) return;
        if (document.querySelector('[data-settings-submodal-open="true"]')) return;
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

  return (
    <BaseDialog.Root
      open={open}
      modal={true}
      onOpenChange={(nextOpen, details) => {
        if (nextOpen) return;
        if (
          details.reason === 'escape-key' &&
          typeof document !== 'undefined' &&
          (document.querySelector('[data-charkle-popover-open="true"]') ||
            document.querySelector('[data-settings-submodal-open="true"]'))
        ) {
          details.cancel();
          return;
        }
        closeSettings();
      }}
    >
      <BaseDialog.Portal>
        <BaseDialog.Backdrop
          className="win-smoke-scrim win-dialog-backdrop fixed inset-0 z-[90]"
          {...stopDialogPropagation}
        />

        <BaseDialog.Viewport
          className="fixed inset-0 z-[91] flex items-center justify-center p-4 sm:p-6 pointer-events-none"
          {...stopDialogPropagation}
        >
          <BaseDialog.Popup
            data-testid="settings-overlay"
            aria-label="Charkle 设置中心"
            className="win-dialog-popup pointer-events-auto relative w-[min(880px,calc(100vw-48px))] h-[min(660px,calc(100vh-48px))] rounded-[var(--win-radius-dialog)] bg-[var(--settings-content)] border border-[var(--win-stroke-flyout)] shadow-[var(--shadow-modal)] flex overflow-hidden outline-none"
            {...stopDialogPropagation}
          >
            {/* Left 212px Fluent 2 Navigation Rail */}
            <aside className="w-[212px] shrink-0 bg-[var(--settings-rail)] border-r border-[var(--win-stroke-divider)] flex flex-col select-none">
              <div className="h-[52px] px-4 flex items-center shrink-0">
                <BaseDialog.Title className="text-[18px] leading-[24px] font-semibold tracking-[-0.01em] text-[var(--text-primary)] charkle-heading">
                  设置
                </BaseDialog.Title>
              </div>

              <LayoutGroup id="settings-nav-rail">
                <nav
                  aria-label="设置分类导航"
                  role="tablist"
                  className="flex-1 overflow-y-auto charkle-scroll-hidden px-2.5 pb-4 flex flex-col gap-3.5"
                >
                  {SETTINGS_SECTIONS.map((sec) => (
                    <div key={sec.id} className="flex flex-col gap-0.5">
                      <div className="px-2.5 pb-1 text-[11px] leading-[14px] font-medium text-[var(--text-tertiary)]">
                        {sec.title}
                      </div>
                      {sec.tabs.map((tab) => {
                        const active = activeTab === tab.id;
                        const TabIcon = tab.icon;
                        return (
                          <button
                            key={tab.id}
                            type="button"
                            role="tab"
                            aria-selected={active}
                            onClick={() => setSettingsTab(tab.id)}
                            className={[
                              'charkle-pressable relative h-[34px] w-full px-3 rounded-[var(--win-radius-control)] flex items-center gap-2.5 text-[13px] leading-[18px] cursor-pointer text-left',
                              'focus-visible:outline-2 focus-visible:outline-offset-[-1px] focus-visible:outline-[var(--accent)]',
                              active
                                ? 'bg-[var(--win-subtle-active)] text-[var(--text-primary)] font-medium'
                                : 'text-[var(--text-secondary)] hover:text-[var(--text-primary)] hover:bg-[var(--win-subtle-hover)] font-normal',
                            ].join(' ')}
                          >
                            {active && (
                              <m.span
                                layoutId="settings-nav-indicator"
                                transition={WIN_SPRING_SNAPPY}
                                aria-hidden="true"
                                className="absolute left-0 top-1/2 -translate-y-1/2 w-[3px] h-4 rounded-full bg-[var(--accent)]"
                              />
                            )}
                            <TabIcon
                              filled={active}
                              className={[
                                'w-[18px] h-[18px] shrink-0',
                                active ? 'text-[var(--accent)]' : 'text-[var(--text-secondary)]',
                              ].join(' ')}
                            />
                            <span className="truncate">{tab.label}</span>
                          </button>
                        );
                      })}
                    </div>
                  ))}
                </nav>
              </LayoutGroup>
            </aside>

            {/* Right Focused Pane Content Column */}
            <div className="flex-1 min-w-0 flex flex-col bg-[var(--settings-content)]">
              <header className="h-[52px] px-6 border-b border-[var(--win-stroke-divider)] flex items-center justify-between gap-3 shrink-0 select-none">
                <h2 className="text-[18px] leading-[24px] font-semibold tracking-[-0.01em] text-[var(--text-primary)] truncate charkle-heading">
                  {TAB_LABEL_MAP[activeTab]}
                </h2>

                <div className="flex items-center gap-2 shrink-0">
                  {resumeOnboarding && (
                    <Button
                      variant="accent"
                      size="xs"
                      data-testid="settings-return-onboarding"
                      onClick={closeSettings}
                      title={`返回新手引导第 ${onboardingStep + 1} 步继续配置 (Esc)`}
                    >
                      <ArrowLeft16Regular className="w-3.5 h-3.5 shrink-0" />
                      <span>返回继续引导</span>
                    </Button>
                  )}

                  <Button
                    variant="subtle"
                    size="icon"
                    aria-label={resumeOnboarding ? '返回继续引导' : '关闭设置'}
                    title={resumeOnboarding ? '返回继续引导 (Esc)' : '关闭设置 (Esc)'}
                    onClick={closeSettings}
                  >
                    <Dismiss16Regular className="w-4 h-4" />
                  </Button>
                </div>
              </header>

              <div
                ref={scrollRef}
                className="flex-1 min-h-0 overflow-y-auto charkle-scroll px-6 py-5"
              >
                <div className="flex flex-col gap-5">
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
          </BaseDialog.Popup>
        </BaseDialog.Viewport>
      </BaseDialog.Portal>
    </BaseDialog.Root>
  );
};
