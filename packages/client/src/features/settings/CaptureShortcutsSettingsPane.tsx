import React from 'react';
import { Plus, Puzzle, Terminal } from 'lucide-react';
import { useCoordinatorStore } from '../../stores/coordinatorStore';
import { useLibraryStore } from '../../stores/libraryStore';
import {
  SettingsButton,
  SettingsCardDivider,
  SettingsRow,
  SettingsSection,
  SettingsSelect,
} from './SettingsChrome';
import { KEYBOARD_SHORTCUTS, SHORTCUT_SCOPES } from './shortcuts';

export const CaptureShortcutsSettingsPane: React.FC = () => {
  const captureTarget = useCoordinatorStore((s) => s.captureTarget);
  const setCaptureTarget = useCoordinatorStore((s) => s.setCaptureTarget);
  const closeSettings = useCoordinatorStore((s) => s.closeSettings);
  const openQuickCapture = useCoordinatorStore((s) => s.openQuickCapture);
  const setSettingsTab = useCoordinatorStore((s) => s.setSettingsTab);
  const folders = useLibraryStore((s) => s.folders);

  return (
    <div className="flex flex-col gap-[22px]">
      {/* 应用内采集 */}
      <SettingsSection title="应用内采集">
        <SettingsRow
          title="默认采集去向"
          subtitle="通过全窗口拖放、全局 ⌘V 粘贴或 ⇧⌘N 快速采集时的默认入库位置"
        >
          <SettingsSelect
            aria-label="默认采集去向"
            value={captureTarget.type}
            onChange={(e) => {
              const val = e.target.value;
              if (val === 'inbox') setCaptureTarget({ type: 'inbox' });
              else if (val === 'activeMoodboard') setCaptureTarget({ type: 'activeMoodboard' });
              else if (val === 'folder' && folders[0]) {
                setCaptureTarget({ type: 'folder', folderID: folders[0].id });
              }
            }}
          >
            <option value="inbox">收件箱</option>
            {folders.length > 0 && <option value="folder">指定文件夹</option>}
            <option value="activeMoodboard">当前活跃情绪板</option>
          </SettingsSelect>

          {captureTarget.type === 'folder' && folders.length > 0 && (
            <SettingsSelect
              aria-label="选择目标文件夹"
              value={captureTarget.folderID}
              onChange={(e) => setCaptureTarget({ type: 'folder', folderID: e.target.value })}
              className="max-w-[140px]"
            >
              {folders.map((f) => (
                <option key={f.id} value={f.id}>
                  {f.name}
                </option>
              ))}
            </SettingsSelect>
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

        <SettingsRow
          title="全窗口拖放 · ⌘V 剪贴板粘贴 · ⇧⌘N 弹窗"
          subtitle="拖入本地文件或直接粘贴截图、网页、推文、GitHub 与色卡即可入库；跨网页采集可配合浏览器扩展"
        >
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
                <SettingsRow title={entry.title} subtitle={entry.description}>
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
        <span>在 Windows / Linux 上可使用 Ctrl 替代 ⌘（Command）。</span>
      </div>
    </div>
  );
};
