import React, { useEffect, useRef } from 'react';
import { createPortal } from 'react-dom';
import { ShieldCheck, X } from 'lucide-react';
import { CharkleIcon } from '../../design-system/CharkleIcon';
import { useCoordinatorStore } from '../../stores/coordinatorStore';
import type { SettingsTabID } from '../../stores/coordinatorStore';
import { useSyncAIStore } from '../../stores/syncAIStore';
import { AccountSecurityPane } from './AccountSecurityPane';
import { AdvancedAboutSettingsPane } from './AdvancedAboutSettingsPane';
import { AISettingsPane } from './AISettingsPane';
import { CaptureShortcutsSettingsPane } from './CaptureShortcutsSettingsPane';
import { ExternalAgentsSettingsPane } from './ExternalAgentsSettingsPane';
import { ExtensionsSettingsPane } from './ExtensionsSettingsPane';
import { GeneralSettingsPane } from './GeneralSettingsPane';
import { LibrarySettingsPane } from './LibrarySettingsPane';
import { SyncSettingsPane } from './SyncSettingsPane';

interface SettingsTabDef {
  id: SettingsTabID;
  label: string;
  iconName?: string;
}

interface SettingsNavGroup {
  title: string;
  tabs: readonly SettingsTabDef[];
}

const SETTINGS_NAV_GROUPS: readonly SettingsNavGroup[] = [
  {
    title: '基础与存储',
    tabs: [
      { id: 'general', label: '通用', iconName: 'settings' },
      { id: 'accountSecurity', label: '账号与安全' },
      { id: 'library', label: '素材库', iconName: 'library' },
      { id: 'sync', label: '云同步', iconName: 'drive-sync' },
    ],
  },
  {
    title: '采集与操作',
    tabs: [{ id: 'captureShortcuts', label: '采集与快捷键', iconName: 'screenshot' }],
  },
  {
    title: '生态与智能',
    tabs: [
      { id: 'ai', label: 'AI 智能', iconName: 'sparkle-board' },
      { id: 'externalAgents', label: '外部 Agent', iconName: 'connector' },
      { id: 'extensions', label: '插件与扩展', iconName: 'export' },
    ],
  },
  {
    title: '系统',
    tabs: [{ id: 'advancedAbout', label: '高级与关于', iconName: 'filter' }],
  },
];

const TAB_LABEL_MAP: Record<SettingsTabID, string> = {
  general: '通用',
  accountSecurity: '账号与安全',
  library: '素材库',
  sync: '云同步',
  captureShortcuts: '采集与快捷键',
  ai: 'AI 智能',
  externalAgents: '外部 Agent',
  extensions: '插件与扩展',
  advancedAbout: '高级与关于',
};

export const SettingsModal: React.FC = () => {
  const open = useCoordinatorStore((s) => s.settingsOpen);
  const closeSettings = useCoordinatorStore((s) => s.closeSettings);
  const activeTab = useCoordinatorStore((s) => s.settingsTab);
  const setActiveTab = useCoordinatorStore((s) => s.setSettingsTab);

  const loadSyncConfig = useSyncAIStore((s) => s.loadSyncConfig);
  const loadAIConfig = useSyncAIStore((s) => s.loadAIConfig);
  const loadTypeSafeConfig = useSyncAIStore((s) => s.loadTypeSafeConfig);
  const loadCacheStats = useSyncAIStore((s) => s.loadCacheStats);
  const loadExternalAgentConfig = useSyncAIStore((s) => s.loadExternalAgentConfig);

  const scrollPaneRef = useRef<HTMLDivElement | null>(null);
  const closeRef = useRef(closeSettings);
  closeRef.current = closeSettings;

  // Hydrate all settings data when opened
  useEffect(() => {
    if (!open) return;
    void loadSyncConfig().catch(() => {});
    void loadAIConfig().catch(() => {});
    void loadTypeSafeConfig().catch(() => {});
    void loadCacheStats().catch(() => {});
    void loadExternalAgentConfig().catch(() => {});
  }, [
    open,
    loadSyncConfig,
    loadAIConfig,
    loadTypeSafeConfig,
    loadCacheStats,
    loadExternalAgentConfig,
  ]);

  // Reset right-pane scroll offset on tab switch or re-open
  useEffect(() => {
    if (scrollPaneRef.current) {
      scrollPaneRef.current.scrollTop = 0;
    }
  }, [activeTab, open]);

  // Esc dismissal (yields automatically to any nested ModalShell open on top at z-[100])
  useEffect(() => {
    if (!open) return;
    const handleKey = (e: KeyboardEvent) => {
      if (e.key !== 'Escape') return;
      const openDialogs = document.querySelectorAll('[role="dialog"][aria-modal="true"]');
      if (openDialogs.length > 1) return;
      e.preventDefault();
      closeRef.current();
    };
    window.addEventListener('keydown', handleKey, false);
    return () => window.removeEventListener('keydown', handleKey, false);
  }, [open]);

  if (!open || typeof document === 'undefined') return null;

  const activeLabel = TAB_LABEL_MAP[activeTab] ?? '通用';

  return createPortal(
    <div
      className="fixed inset-0 z-[90] flex items-center justify-center p-4 sm:p-6"
      role="dialog"
      aria-modal="true"
      aria-label="Charkle 设置"
    >
      {/* Backdrop */}
      <div
        className="charkle-modal-backdrop fixed inset-0 bg-black/38 backdrop-blur-[3px]"
        onClick={closeSettings}
      />

      {/* Centered Two-Pane Settings Surface */}
      <div
        className={[
          'charkle-modal-panel relative z-10 max-w-[860px] w-[calc(100vw-32px)] sm:w-full h-[min(80vh,640px)]',
          'rounded-[16px] overflow-hidden flex flex-col sm:flex-row',
          'border border-[var(--settings-border,var(--border-hairline))]',
          'shadow-[0_24px_64px_rgba(0,0,0,0.22)]',
        ].join(' ')}
      >
        {/* Left Navigation Rail (204px) */}
        <nav
          aria-label="设置分类导航"
          className="w-full sm:w-[204px] shrink-0 bg-[var(--settings-rail,var(--bg-inspector))] border-b sm:border-b-0 sm:border-r border-[var(--settings-border,var(--border-hairline))] flex flex-col"
        >
          <div className="h-[52px] px-4 flex items-center justify-between shrink-0">
            <span className="text-[14.5px] font-semibold tracking-[-0.01em] text-[var(--text-primary)]">
              设置
            </span>
            <button
              type="button"
              onClick={closeSettings}
              aria-label="关闭设置"
              title="关闭设置 (Esc)"
              className="sm:hidden charkle-pressable w-[26px] h-[26px] rounded-full inline-flex items-center justify-center bg-black/[0.06] dark:bg-white/[0.08] text-[var(--text-secondary)] hover:text-[var(--text-primary)] cursor-pointer"
            >
              <X size={13} strokeWidth={2.2} />
            </button>
          </div>

          <div className="px-2.5 pb-3 flex sm:flex-col gap-3 overflow-x-auto sm:overflow-y-auto charkle-scroll flex-1 min-h-0">
            {SETTINGS_NAV_GROUPS.map((group) => (
              <div key={group.title} className="flex sm:flex-col gap-0.5 shrink-0">
                <div className="hidden sm:block px-2.5 pt-1 pb-1 text-[10.5px] font-medium text-[var(--settings-label,var(--text-tertiary))] select-none">
                  {group.title}
                </div>
                {group.tabs.map((tab) => {
                  const active = activeTab === tab.id;
                  return (
                    <button
                      key={tab.id}
                      type="button"
                      aria-current={active ? 'page' : undefined}
                      onClick={() => setActiveTab(tab.id)}
                      className={[
                        'charkle-pressable flex items-center gap-2.5 px-2.5 h-[32px] rounded-[8px] text-left text-[12.5px] whitespace-nowrap shrink-0 cursor-pointer',
                        'transition-[background-color,color] duration-[var(--duration-press,120ms)] ease-[var(--ease-out)]',
                        active
                          ? 'bg-black/[0.075] dark:bg-white/[0.10] text-[var(--text-primary)] font-semibold'
                          : 'text-[var(--text-secondary)] hover:text-[var(--text-primary)] hover:bg-black/[0.035] dark:hover:bg-white/[0.05] font-normal',
                      ].join(' ')}
                    >
                      {tab.iconName ? (
                        <CharkleIcon name={tab.iconName} size={15} isActive={active} />
                      ) : (
                        <ShieldCheck
                          size={15}
                          strokeWidth={1.85}
                          className={
                            active ? 'text-[var(--text-primary)]' : 'text-[var(--text-secondary)]'
                          }
                        />
                      )}
                      <span className="truncate">{tab.label}</span>
                    </button>
                  );
                })}
              </div>
            ))}
          </div>
        </nav>

        {/* Right Content Column */}
        <div className="flex-1 min-w-0 min-h-0 flex flex-col bg-[var(--settings-content,var(--bg-gallery))]">
          {/* Fixed 52px Header */}
          <div className="h-[52px] px-6 border-b border-[var(--settings-divider,var(--border-hairline))] flex items-center justify-between gap-3 shrink-0">
            <h2 className="text-[15px] font-semibold tracking-[-0.01em] text-[var(--text-primary)] truncate">
              {activeLabel}
            </h2>
            <button
              type="button"
              onClick={closeSettings}
              aria-label="关闭设置"
              title="关闭设置 (Esc)"
              className="hidden sm:inline-flex charkle-pressable w-[26px] h-[26px] rounded-full items-center justify-center bg-black/[0.06] dark:bg-white/[0.08] text-[var(--text-secondary)] hover:text-[var(--text-primary)] hover:bg-black/[0.10] dark:hover:bg-white/[0.14] cursor-pointer transition-colors duration-[var(--duration-press,120ms)] ease-[var(--ease-out)]"
            >
              <X size={13} strokeWidth={2.2} />
            </button>
          </div>

          {/* Scrollable Pane Body */}
          <div
            ref={scrollPaneRef}
            className="flex-1 min-h-0 overflow-y-auto charkle-scroll px-6 py-5"
          >
            {activeTab === 'general' && <GeneralSettingsPane />}
            {activeTab === 'accountSecurity' && <AccountSecurityPane />}
            {activeTab === 'library' && <LibrarySettingsPane />}
            {activeTab === 'sync' && <SyncSettingsPane />}
            {activeTab === 'captureShortcuts' && <CaptureShortcutsSettingsPane />}
            {activeTab === 'ai' && <AISettingsPane />}
            {activeTab === 'externalAgents' && <ExternalAgentsSettingsPane />}
            {activeTab === 'extensions' && <ExtensionsSettingsPane />}
            {activeTab === 'advancedAbout' && <AdvancedAboutSettingsPane />}
          </div>
        </div>
      </div>
    </div>,
    document.body,
  );
};
