import React, { useMemo, useRef, useState } from 'react';
import { ChevronDown, Plus, Puzzle, Terminal } from 'lucide-react';
import { buildFolderPathsMap, flattenFolderTree } from '@charkle/shared';
import { CharkleFolderIcon, FolderHierarchyMenu, Popover } from '../../design-system';
import { useCoordinatorStore } from '../../stores/coordinatorStore';
import { useLibraryStore } from '../../stores/libraryStore';
import {
  SettingsButton,
  SettingsCardDivider,
  SettingsRow,
  SettingsSection,
  SettingsSegmented,
} from './SettingsChrome';
import { KEYBOARD_SHORTCUTS, SHORTCUT_SCOPES } from './shortcuts';

type CaptureTargetKind = 'inbox' | 'folder' | 'activeMoodboard';

export const CaptureShortcutsSettingsPane: React.FC = () => {
  const captureTarget = useCoordinatorStore((s) => s.captureTarget);
  const setCaptureTarget = useCoordinatorStore((s) => s.setCaptureTarget);
  const closeSettings = useCoordinatorStore((s) => s.closeSettings);
  const openQuickCapture = useCoordinatorStore((s) => s.openQuickCapture);
  const setSettingsTab = useCoordinatorStore((s) => s.setSettingsTab);
  const folders = useLibraryStore((s) => s.folders);

  const [folderPickerOpen, setFolderPickerOpen] = useState(false);
  const folderTriggerRef = useRef<HTMLButtonElement | null>(null);

  const flattenedFolders = useMemo(() => flattenFolderTree(folders), [folders]);
  const folderPaths = useMemo(() => buildFolderPathsMap(folders), [folders]);

  const selectedFolder = useMemo(
    () =>
      captureTarget.type === 'folder'
        ? folders.find((f) => f.id === captureTarget.folderID) ?? null
        : null,
    [captureTarget, folders],
  );

  const targetOptions = useMemo<ReadonlyArray<{ id: CaptureTargetKind; label: string }>>(() => {
    const base: Array<{ id: CaptureTargetKind; label: string }> = [
      { id: 'inbox', label: '收件箱' },
    ];
    if (folders.length > 0) {
      base.push({ id: 'folder', label: '指定文件夹' });
    }
    base.push({ id: 'activeMoodboard', label: '活跃情绪板' });
    return base;
  }, [folders.length]);

  return (
    <div className="flex flex-col gap-[22px]">
      {/* 应用内采集 */}
      <SettingsSection title="应用内采集">
        <SettingsRow title="默认采集去向">
          <SettingsSegmented
            ariaLabel="默认采集去向"
            options={targetOptions}
            value={captureTarget.type}
            onChange={(val) => {
              if (val === 'inbox') setCaptureTarget({ type: 'inbox' });
              else if (val === 'activeMoodboard') setCaptureTarget({ type: 'activeMoodboard' });
              else if (val === 'folder' && flattenedFolders[0]) {
                setCaptureTarget({ type: 'folder', folderID: flattenedFolders[0].id });
              }
            }}
          />

          {captureTarget.type === 'folder' && flattenedFolders.length > 0 && (
            <>
              <button
                ref={folderTriggerRef}
                type="button"
                aria-label="选择目标文件夹"
                aria-haspopup="menu"
                aria-expanded={folderPickerOpen}
                onClick={() => setFolderPickerOpen((v) => !v)}
                className="charkle-pressable h-[30px] max-w-[180px] px-2.5 rounded-[8px] bg-[var(--settings-subtle,var(--bg-subtle))] border border-[var(--settings-border,var(--border-hairline))] hover:border-[var(--border-strong)] inline-flex items-center gap-1.5 text-[12px] text-[var(--text-primary)] cursor-pointer transition-colors duration-[var(--duration-press,120ms)] ease-[var(--ease-out)]"
              >
                <CharkleFolderIcon
                  colorHex={selectedFolder?.colorHex}
                  customSymbol={selectedFolder?.customSymbol}
                  size={14}
                />
                <span className="truncate">
                  {selectedFolder
                    ? folderPaths[selectedFolder.id] || selectedFolder.name
                    : '选择文件夹'}
                </span>
                <ChevronDown size={12} className="text-[var(--text-tertiary)] shrink-0" />
              </button>

              <Popover
                open={folderPickerOpen}
                onOpenChange={setFolderPickerOpen}
                anchorEl={folderTriggerRef.current}
                placement="bottom-end"
              >
                <FolderHierarchyMenu
                  folders={folders}
                  includeInbox={false}
                  highlightSelection
                  selectedFolderID={captureTarget.folderID}
                  parentSelfPrefix="存入"
                  onSelectFolder={(folderID) => {
                    if (folderID) {
                      setCaptureTarget({ type: 'folder', folderID });
                    }
                    setFolderPickerOpen(false);
                  }}
                />
              </Popover>
            </>
          )}

          <SettingsButton
            variant="primary"
            onClick={() => {
              closeSettings();
              openQuickCapture();
            }}
          >
            <Plus size={12} />
            立即采集
          </SettingsButton>
        </SettingsRow>

        <SettingsCardDivider />

        <SettingsRow title="应用内采集" subtitle="支持拖放、⌘V 粘贴或 ⇧⌘N">
          <SettingsButton variant="secondary" onClick={() => setSettingsTab('extensions')}>
            <Puzzle size={12} />
            安装浏览器扩展
          </SettingsButton>
        </SettingsRow>
      </SettingsSection>

      {/* 分组快捷键 */}
      {SHORTCUT_SCOPES.map((scope) => {
        const entries = KEYBOARD_SHORTCUTS.filter((item) => item.scope === scope);
        if (entries.length === 0) return null;
        return (
          <SettingsSection key={scope} title={scope}>
            {entries.map((entry, idx) => (
              <React.Fragment key={entry.title}>
                {idx > 0 && <SettingsCardDivider />}
                <SettingsRow title={entry.title}>
                  <div className="flex items-center gap-1 shrink-0">
                    {entry.keys.map((keyLabel, kIdx) => (
                      <kbd
                        key={`${entry.title}-${kIdx}`}
                        className="min-w-[24px] h-[24px] px-1.5 rounded-[6px] bg-[var(--settings-subtle,var(--bg-subtle))] border border-[var(--settings-border,var(--border-hairline))] inline-flex items-center justify-center font-mono text-[11px] font-medium text-[var(--text-primary)]"
                      >
                        {keyLabel}
                      </kbd>
                    ))}
                  </div>
                </SettingsRow>
              </React.Fragment>
            ))}
          </SettingsSection>
        );
      })}

      <div className="flex items-center gap-1.5 px-1 text-[11px] text-[var(--settings-label,var(--text-tertiary))]">
        <Terminal size={12} />
        <span>Windows / Linux 用 Ctrl 替代 ⌘</span>
      </div>
    </div>
  );
};
