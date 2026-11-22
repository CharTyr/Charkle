import React, { useEffect, useState } from 'react';
import { ArrowRight, CheckCircle2, AlertTriangle } from 'lucide-react';
import {
  activeStorageLocationSummary,
  createDefaultDriveSyncConfig,
  driveTransportModeLocalizedLabel,
} from '@charkle/shared';
import type {
  DriveSyncConfig,
  DriveTransportMode,
  StorageMigrationReport,
} from '@charkle/shared';
import { Button } from '../../design-system/Button';
import { ModalShell } from '../../design-system/ModalShell';
import { useCoordinatorStore } from '../../stores/coordinatorStore';
import { useSyncAIStore } from '../../stores/syncAIStore';

export interface StorageMigrationModalProps {
  open: boolean;
  onClose: () => void;
  currentConfig: DriveSyncConfig;
}

const TARGET_MODES: ReadonlyArray<DriveTransportMode> = [
  'directAPIWithGDirect',
  'webDAV',
  'localOnly',
];

export const StorageMigrationModal: React.FC<StorageMigrationModalProps> = ({
  open,
  onClose,
  currentConfig,
}) => {
  const migrateStorage = useSyncAIStore((s) => s.migrateStorage);
  const pushToast = useCoordinatorStore((s) => s.pushToast);

  const [draft, setDraft] = useState<DriveSyncConfig>(currentConfig);
  const [webDAVPassword, setWebDAVPassword] = useState('');
  const [migrating, setMigrating] = useState(false);
  const [report, setReport] = useState<StorageMigrationReport | null>(null);
  const [error, setError] = useState<string | null>(null);

  useEffect(() => {
    if (open) {
      setDraft(createDefaultDriveSyncConfig(currentConfig));
      setWebDAVPassword('');
      setReport(null);
      setError(null);
    }
  }, [open, currentConfig]);

  const handleRunMigration = async () => {
    setMigrating(true);
    setError(null);
    try {
      const res = await migrateStorage(draft, webDAVPassword || null);
      setReport(res);
      pushToast({
        tone: 'success',
        message: `已完成无损迁移：${res.migratedAssets} 项素材、${res.migratedBoards} 块情绪板`,
      });
    } catch (err) {
      setError(err instanceof Error ? err.message : '存储位置无损迁移失败');
    } finally {
      setMigrating(false);
    }
  };

  return (
    <ModalShell
      open={open}
      onClose={() => {
        if (!migrating) onClose();
      }}
      width="md"
      title="无损存储迁移向导"
      subtitle="在纯本地文件夹、Google Drive 与 WebDAV 云盘间双向无损转移完整素材库"
      footer={
        report ? (
          <Button variant="primary" size="sm" onClick={onClose}>
            完成
          </Button>
        ) : (
          <>
            <Button variant="secondary" size="sm" disabled={migrating} onClick={onClose}>
              取消
            </Button>
            <Button variant="primary" size="sm" loading={migrating} onClick={handleRunMigration}>
              开始无损迁移
            </Button>
          </>
        )
      }
    >
      <div className="flex flex-col gap-4">
        {/* Source -> Target visual summary */}
        <div className="rounded-[var(--radius-settings-outer)] bg-[var(--bg-gallery)] border border-[var(--border-hairline)] p-3.5 flex items-center justify-between gap-3 text-[12px]">
          <div className="min-w-0 flex-1">
            <div className="text-[10.5px] text-[var(--text-tertiary)]">当前存储位置</div>
            <div className="font-medium text-[var(--text-primary)] truncate mt-0.5">
              {activeStorageLocationSummary(currentConfig)}
            </div>
          </div>
          <ArrowRight size={16} className="text-[var(--text-tertiary)] shrink-0" />
          <div className="min-w-0 flex-1 text-right">
            <div className="text-[10.5px] text-[var(--text-tertiary)]">目标存储位置</div>
            <div className="font-medium text-[var(--accent)] truncate mt-0.5">
              {activeStorageLocationSummary(draft)}
            </div>
          </div>
        </div>

        {error && (
          <div className="p-3 rounded-[var(--radius-settings-inner)] bg-[var(--danger-soft)] text-[var(--danger)] text-[12px] flex items-center gap-2">
            <AlertTriangle size={14} className="shrink-0" />
            <span>{error}</span>
          </div>
        )}

        {report ? (
          <div className="rounded-[var(--radius-settings-outer)] bg-[var(--success-soft)] border border-[var(--success)]/30 p-4 flex flex-col gap-3">
            <div className="flex items-center gap-2 text-[13.5px] font-semibold text-[var(--success)]">
              <CheckCircle2 size={16} />
              素材库无损迁移完成（耗时 {report.durationSeconds.toFixed(1)}s）
            </div>
            <div className="grid grid-cols-2 sm:grid-cols-4 gap-2 text-center">
              {[
                { label: '迁移素材', value: report.migratedAssets },
                { label: '拉取原图', value: report.downloadedOriginals },
                { label: '文件夹', value: report.migratedFolders },
                { label: '情绪板', value: report.migratedBoards },
              ].map((item) => (
                <div
                  key={item.label}
                  className="rounded-[var(--radius-settings-inner)] bg-[var(--bg-elevated)] py-2 px-1.5 border border-[var(--border-hairline)]"
                >
                  <div className="text-[15px] font-semibold text-[var(--text-primary)] tabular-nums">
                    {item.value}
                  </div>
                  <div className="text-[10.5px] text-[var(--text-secondary)]">{item.label}</div>
                </div>
              ))}
            </div>
            <p className="text-[11.5px] text-[var(--text-secondary)]">
              新存储路径：<span className="font-mono">{report.targetLocation}</span>
            </p>
          </div>
        ) : (
          <div className="flex flex-col gap-3.5">
            <div>
              <label className="block text-[12px] font-semibold text-[var(--text-primary)] mb-1.5">
                目标存储方式
              </label>
              <div className="grid grid-cols-3 gap-1.5 p-1 rounded-[var(--radius-settings-inner)] bg-[var(--bg-subtle)] border border-[var(--border-hairline)]">
                {TARGET_MODES.map((m) => (
                  <button
                    key={m}
                    type="button"
                    onClick={() => setDraft((d) => ({ ...d, mode: m }))}
                    className={[
                      'py-1.5 rounded-[6px] text-[12px] font-medium cursor-pointer',
                      draft.mode === m
                        ? 'bg-[var(--bg-elevated)] text-[var(--text-primary)] shadow-xs'
                        : 'text-[var(--text-secondary)] hover:text-[var(--text-primary)]',
                    ].join(' ')}
                  >
                    {driveTransportModeLocalizedLabel(m)}
                  </button>
                ))}
              </div>
            </div>

            {draft.mode === 'directAPIWithGDirect' && (
              <div className="flex flex-col gap-2.5">
                <div>
                  <label className="block text-[12px] font-medium text-[var(--text-primary)] mb-1">
                    Google Drive 根目录名
                  </label>
                  <input
                    type="text"
                    value={draft.rootFolderName}
                    onChange={(e) => setDraft((d) => ({ ...d, rootFolderName: e.target.value }))}
                    className="w-full h-9 px-3 rounded-[var(--radius-settings-inner)] bg-[var(--bg-subtle)] border border-[var(--border-hairline)] text-[12.5px] text-[var(--text-primary)] outline-none focus:border-[var(--accent)]"
                  />
                </div>
                <div>
                  <label className="block text-[12px] font-medium text-[var(--text-primary)] mb-1">
                    共享文件夹链接或 ID（可选）
                  </label>
                  <input
                    type="text"
                    value={draft.sharedFolderURLOrID}
                    onChange={(e) =>
                      setDraft((d) => ({ ...d, sharedFolderURLOrID: e.target.value }))
                    }
                    placeholder="留空则使用我的云端硬盘根目录"
                    className="w-full h-9 px-3 rounded-[var(--radius-settings-inner)] bg-[var(--bg-subtle)] border border-[var(--border-hairline)] text-[12.5px] text-[var(--text-primary)] outline-none focus:border-[var(--accent)]"
                  />
                </div>
              </div>
            )}

            {draft.mode === 'webDAV' && (
              <div className="flex flex-col gap-2.5">
                <div>
                  <label className="block text-[12px] font-medium text-[var(--text-primary)] mb-1">
                    WebDAV 服务器地址
                  </label>
                  <input
                    type="url"
                    value={draft.webDAVServerURL}
                    onChange={(e) => setDraft((d) => ({ ...d, webDAVServerURL: e.target.value }))}
                    placeholder="https://dav.example.com/dav/"
                    className="w-full h-9 px-3 rounded-[var(--radius-settings-inner)] bg-[var(--bg-subtle)] border border-[var(--border-hairline)] text-[12.5px] text-[var(--text-primary)] outline-none focus:border-[var(--accent)]"
                  />
                </div>
                <div className="grid grid-cols-2 gap-2.5">
                  <div>
                    <label className="block text-[12px] font-medium text-[var(--text-primary)] mb-1">
                      用户名
                    </label>
                    <input
                      type="text"
                      value={draft.webDAVUsername}
                      onChange={(e) => setDraft((d) => ({ ...d, webDAVUsername: e.target.value }))}
                      className="w-full h-9 px-3 rounded-[var(--radius-settings-inner)] bg-[var(--bg-subtle)] border border-[var(--border-hairline)] text-[12.5px] text-[var(--text-primary)] outline-none focus:border-[var(--accent)]"
                    />
                  </div>
                  <div>
                    <label className="block text-[12px] font-medium text-[var(--text-primary)] mb-1">
                      密码 / 应用专用密码
                    </label>
                    <input
                      type="password"
                      value={webDAVPassword}
                      onChange={(e) => setWebDAVPassword(e.target.value)}
                      placeholder="留空则沿用已保存密码"
                      className="w-full h-9 px-3 rounded-[var(--radius-settings-inner)] bg-[var(--bg-subtle)] border border-[var(--border-hairline)] text-[12.5px] text-[var(--text-primary)] outline-none focus:border-[var(--accent)]"
                    />
                  </div>
                </div>
                <div>
                  <label className="block text-[12px] font-medium text-[var(--text-primary)] mb-1">
                    远程目录路径
                  </label>
                  <input
                    type="text"
                    value={draft.webDAVRemotePath}
                    onChange={(e) => setDraft((d) => ({ ...d, webDAVRemotePath: e.target.value }))}
                    placeholder="/Charkle"
                    className="w-full h-9 px-3 rounded-[var(--radius-settings-inner)] bg-[var(--bg-subtle)] border border-[var(--border-hairline)] text-[12.5px] text-[var(--text-primary)] outline-none focus:border-[var(--accent)]"
                  />
                </div>
              </div>
            )}

            {draft.mode === 'localOnly' && (
              <div>
                <label className="block text-[12px] font-medium text-[var(--text-primary)] mb-1">
                  本地素材库路径（服务端文件系统路径）
                </label>
                <input
                  type="text"
                  value={draft.localLibraryPath}
                  onChange={(e) => setDraft((d) => ({ ...d, localLibraryPath: e.target.value }))}
                  placeholder=".charkle-data/library"
                  className="w-full h-9 px-3 rounded-[var(--radius-settings-inner)] bg-[var(--bg-subtle)] border border-[var(--border-hairline)] font-mono text-[12px] text-[var(--text-primary)] outline-none focus:border-[var(--accent)]"
                />
              </div>
            )}

            <p className="text-[11.5px] text-[var(--text-secondary)] leading-relaxed">
              迁移过程会先拉取所有尚未缓存的云端原件，再将原文件、文件夹结构、标签、色板与全部情绪板按 `/.charkle/` 标准同步格式写入目标位置，原位置数据不会被删除。
            </p>
          </div>
        )}
      </div>
    </ModalShell>
  );
};
