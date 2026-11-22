import React, { useEffect, useRef } from 'react';
import { ShieldCheck, X } from 'lucide-react';
import { CharkleBrandMark, CharkleIcon } from '../../design-system/CharkleIcon';
import { ModalShell } from '../../design-system/ModalShell';
import { useCoordinatorStore } from '../../stores/coordinatorStore';
import type { SettingsTabID } from '../../stores/coordinatorStore';
import { AccountSecurityTab } from './AccountSecurityTab';
import {
  AppearanceTab,
  CaptureShortcutsTab,
  ExternalAgentTab,
  StorageCacheTab,
} from './AppearanceAndOtherTabs';
import { CloudSyncTab } from './CloudSyncTab';
import { IntelligenceTab } from './IntelligenceTab';

const SETTINGS_TABS: ReadonlyArray<{
  id: SettingsTabID;
  label: string;
  iconName?: string;
}> = [
  { id: 'accountSecurity', label: '账号与安全' },
  { id: 'cloudSync', label: '存储与同步', iconName: 'drive-sync' },
  { id: 'intelligence', label: '智能与搜索', iconName: 'sparkle-board' },
  { id: 'appearance', label: '外观与图标', iconName: 'moodboard' },
  { id: 'externalAgent', label: '外部 Agent 与 MCP', iconName: 'connector' },
  { id: 'storage', label: '缓存空间', iconName: 'library' },
  { id: 'captureShortcuts', label: '采集与快捷键', iconName: 'notch' },
];

export const SettingsModal: React.FC = () => {
  const open = useCoordinatorStore((s) => s.settingsOpen);
  const closeSettings = useCoordinatorStore((s) => s.closeSettings);
  const activeTab = useCoordinatorStore((s) => s.settingsTab);
  const setActiveTab = useCoordinatorStore((s) => s.setSettingsTab);
  const scrollPaneRef = useRef<HTMLDivElement | null>(null);

  useEffect(() => {
    if (scrollPaneRef.current) {
      scrollPaneRef.current.scrollTop = 0;
    }
  }, [activeTab, open]);

  return (
    <ModalShell
      open={open}
      onClose={closeSettings}
      width="xl"
      noPadding
      hideCloseButton
    >
      <div className="flex flex-col sm:flex-row h-[min(78vh,660px)] overflow-hidden">
        {/* Clean macOS-grade Left Navigation Rail */}
        <nav
          aria-label="设置分类导航"
          className="w-full sm:w-[214px] shrink-0 border-b sm:border-b-0 sm:border-r border-[var(--border-hairline)] bg-[var(--bg-inspector)] flex flex-col"
        >
          <div className="px-4 py-4 flex items-center justify-between gap-2">
            <div className="flex items-center gap-2.5">
              <CharkleBrandMark size={22} />
              <span className="text-[14px] font-semibold text-[var(--text-primary)]">设置</span>
            </div>
            <button
              type="button"
              onClick={closeSettings}
              aria-label="关闭设置"
              className="sm:hidden charkle-pressable w-7 h-7 rounded-[var(--radius-chip)] inline-flex items-center justify-center text-[var(--text-secondary)] hover:bg-[var(--bg-subtle)] cursor-pointer"
            >
              <X size={15} />
            </button>
          </div>

          <div className="px-2 pb-3 flex sm:flex-col gap-1 overflow-x-auto sm:overflow-y-auto charkle-scroll">
            {SETTINGS_TABS.map((tab) => {
              const active = activeTab === tab.id;
              return (
                <button
                  key={tab.id}
                  type="button"
                  aria-current={active ? 'page' : undefined}
                  onClick={() => setActiveTab(tab.id)}
                  className={[
                    'charkle-pressable flex items-center gap-2.5 px-3 py-2 rounded-[var(--radius-settings-inner)] text-left text-[12.5px] whitespace-nowrap shrink-0 cursor-pointer',
                    active
                      ? 'bg-[var(--accent-soft)] text-[var(--text-primary)] font-semibold'
                      : 'text-[var(--text-secondary)] hover:text-[var(--text-primary)] hover:bg-[var(--bg-subtle)]/70 font-normal',
                  ].join(' ')}
                >
                  {tab.iconName ? (
                    <CharkleIcon name={tab.iconName} style="duotone" size={16} isActive={active} />
                  ) : (
                    <ShieldCheck
                      size={16}
                      className={active ? 'text-[var(--accent)]' : 'text-[var(--text-secondary)]'}
                    />
                  )}
                  <span className="truncate">{tab.label}</span>
                </button>
              );
            })}
          </div>

          <div className="hidden sm:block mt-auto px-4 py-3 border-t border-[var(--border-hairline)] text-[10.5px] text-[var(--text-tertiary)]">
            Charkle Web Studio · 与 macOS 原生版 100% 互通
          </div>
        </nav>

        {/* Scrollable Content Pane */}
        <div className="flex-1 min-w-0 min-h-0 flex flex-col bg-[var(--bg-gallery)]">
          <div className="hidden sm:flex items-center justify-end px-4 pt-3 pb-1 shrink-0">
            <button
              type="button"
              onClick={closeSettings}
              aria-label="关闭设置"
              className="charkle-pressable w-7 h-7 rounded-[var(--radius-chip)] inline-flex items-center justify-center text-[var(--text-secondary)] hover:text-[var(--text-primary)] hover:bg-[var(--bg-subtle)] cursor-pointer"
            >
              <X size={16} />
            </button>
          </div>

          <div
            ref={scrollPaneRef}
            className="flex-1 min-h-0 overflow-y-auto charkle-scroll px-5 sm:px-6 pb-6 pt-3 sm:pt-1"
          >
            {activeTab === 'accountSecurity' && <AccountSecurityTab />}
            {activeTab === 'cloudSync' && <CloudSyncTab />}
            {activeTab === 'intelligence' && <IntelligenceTab />}
            {activeTab === 'appearance' && <AppearanceTab />}
            {activeTab === 'externalAgent' && <ExternalAgentTab />}
            {activeTab === 'storage' && <StorageCacheTab />}
            {activeTab === 'captureShortcuts' && <CaptureShortcutsTab />}
          </div>
        </div>
      </div>
    </ModalShell>
  );
};
