import React, { useEffect } from 'react';
import {
  Bot,
  Cloud,
  Database,
  Info,
  Keyboard,
  PanelTop,
  Puzzle,
  Settings,
  Sparkles,
  X,
} from 'lucide-react';
import { useCoordinatorStore, useSyncAIStore } from '../../stores';
import type { SettingsTabId } from '../../types/domain';
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
  tabs: Array<{ id: SettingsTabId; label: string; icon: React.ReactNode }>;
}

const SETTINGS_SECTIONS: SettingsSectionDef[] = [
  {
    id: 'foundation',
    title: '基础与存储',
    tabs: [
      { id: 'general', label: '通用', icon: <Settings size={14.5} /> },
      { id: 'library', label: '素材库', icon: <Database size={14.5} /> },
      { id: 'sync', label: '云同步', icon: <Cloud size={14.5} /> },
    ],
  },
  {
    id: 'capture',
    title: '采集与操作',
    tabs: [
      { id: 'dropShelf', label: '顶部悬浮窗', icon: <PanelTop size={14.5} /> },
      { id: 'captureShortcuts', label: '采集与快捷键', icon: <Keyboard size={14.5} /> },
    ],
  },
  {
    id: 'ecosystem',
    title: '生态与智能',
    tabs: [
      { id: 'ai', label: 'AI 智能', icon: <Sparkles size={14.5} /> },
      { id: 'externalAgents', label: '外部 Agent', icon: <Bot size={14.5} /> },
      { id: 'extensions', label: '插件与扩展', icon: <Puzzle size={14.5} /> },
    ],
  },
  {
    id: 'system',
    title: '系统',
    tabs: [{ id: 'advancedAbout', label: '高级与关于', icon: <Info size={14.5} /> }],
  },
];

/**
 * Centered 9-Pane Settings Overlay (M5-R3) mirroring macOS `CharkleSettingsTab.swift` 1:1
 * across 4 calm sections and 9 focused single-purpose panes.
 */
export const SettingsOverlay: React.FC = () => {
  const open = useCoordinatorStore((s) => s.settingsOpen);
  const activeTab = useCoordinatorStore((s) => s.settingsTab);
  const setSettingsTab = useCoordinatorStore((s) => s.setSettingsTab);
  const closeSettings = useCoordinatorStore((s) => s.closeSettings);
  const refreshSettingsData = useSyncAIStore((s) => s.refreshSettingsData);

  useEffect(() => {
    if (!open) return;
    void refreshSettingsData();
    const onKeyDown = (e: KeyboardEvent) => {
      if (e.key === 'Escape') {
        e.preventDefault();
        closeSettings();
      }
    };
    window.addEventListener('keydown', onKeyDown);
    return () => window.removeEventListener('keydown', onKeyDown);
  }, [open, refreshSettingsData, closeSettings]);

  if (!open) return null;

  return (
    <div
      data-testid="settings-overlay"
      role="dialog"
      aria-modal="true"
      aria-label="Charkle 设置中心"
      onClick={(e) => {
        if (e.target === e.currentTarget) closeSettings();
      }}
      className="fixed inset-0 z-50 bg-black/35 backdrop-blur-[4px] flex items-center justify-center p-6"
    >
      <div className="w-full max-w-[920px] h-[min(640px,88vh)] rounded-[var(--radius-modal)] bg-[var(--bg-gallery)] border border-[var(--border-strong)] shadow-[var(--shadow-modal)] flex overflow-hidden">
        {/* Left 4-Section 9-Pane Navigation Rail */}
        <aside className="w-[216px] shrink-0 bg-[var(--bg-sidebar)] border-r border-[var(--border-hairline)] flex flex-col">
          <div className="px-4 py-3.5 border-b border-[var(--border-hairline)] flex items-center justify-between">
            <span className="text-[13.5px] font-semibold text-[var(--text-primary)]">设置</span>
            <span className="text-[10.5px] text-[var(--text-tertiary)] font-mono">Ctrl+,</span>
          </div>

          <nav aria-label="设置分类导航" className="flex-1 overflow-y-auto charkle-scroll px-2.5 py-3 flex flex-col gap-4">
            {SETTINGS_SECTIONS.map((sec) => (
              <div key={sec.id} className="flex flex-col gap-0.5">
                <div className="px-2 pb-1 text-[11px] font-semibold tracking-[0.02em] text-[var(--text-tertiary)]">
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
                        'charkle-pressable w-full h-8 px-2.5 rounded-[var(--radius-chip)] flex items-center gap-2 text-[12.5px] cursor-pointer text-left',
                        active
                          ? 'bg-[var(--accent-soft)] text-[var(--accent)] font-medium'
                          : 'text-[var(--text-primary)] hover:bg-[var(--bg-subtle)]',
                      ].join(' ')}
                    >
                      {tab.icon}
                      <span className="truncate">{tab.label}</span>
                    </button>
                  );
                })}
              </div>
            ))}
          </nav>
        </aside>

        {/* Right Focused Pane Content */}
        <div className="flex-1 min-w-0 flex flex-col bg-[var(--bg-gallery)]">
          <div className="h-11 px-5 border-b border-[var(--border-hairline)] flex items-center justify-end shrink-0">
            <button
              type="button"
              aria-label="关闭设置"
              onClick={closeSettings}
              className="charkle-pressable h-7 w-7 rounded-[var(--radius-card-inner)] inline-flex items-center justify-center text-[var(--text-secondary)] hover:bg-[var(--bg-subtle)] hover:text-[var(--text-primary)] cursor-pointer"
            >
              <X size={15} />
            </button>
          </div>

          <div className="flex-1 min-h-0 overflow-y-auto charkle-scroll p-6">
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
  );
};
