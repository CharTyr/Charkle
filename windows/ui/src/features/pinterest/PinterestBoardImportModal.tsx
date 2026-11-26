import React, { useEffect, useMemo, useState } from 'react';
import {
  ArrowSync16Regular,
  CheckmarkCircle16Filled,
  Dismiss16Regular,
  Folder16Regular,
  LockClosed12Regular,
} from '@fluentui/react-icons';
import { isTauriRuntime } from '../../api/transport';
import { Button } from '../../design-system';
import { useLibraryStore } from '../../stores/libraryStore';
import { usePinterestStore } from '../../stores/pinterestStore';
import {
  buildFolderTree,
  flattenFolderTree,
  resolveSocialMediaUrl,
  type PinterestBoardImportDestination,
} from '../../types/domain';

type DestinationMode = 'pinterestRootFolder' | 'libraryRoot' | 'existingFolder';

/**
 * Batch Pinterest Board Collection Importer modal (`导入画板收藏`).
 * Mirrors macOS v1.4.1 batch board hierarchy import:
 * - Multi-select paginated Pinterest boards with cover thumbnails & pin counts.
 * - 3 destination modes (`Pinterest` root parent folder [default], Library root, existing folder).
 * - Incremental duplicate skip toggle, extra tags, live per-board progress & cancellation.
 */
export const PinterestBoardImportModal: React.FC = () => {
  const open = usePinterestStore((s) => s.boardImportModalOpen);
  const boards = usePinterestStore((s) => s.boards);
  const isLoadingBoards = usePinterestStore((s) => s.isLoadingBoards);
  const isImportingBoards = usePinterestStore((s) => s.isImportingBoards);
  const progress = usePinterestStore((s) => s.boardImportProgress);
  const lastReport = usePinterestStore((s) => s.lastBoardImportReport);

  const closeModal = usePinterestStore((s) => s.closeBoardImportModal);
  const refreshBoards = usePinterestStore((s) => s.refreshBoards);
  const startBoardBatchImport = usePinterestStore((s) => s.startBoardBatchImport);
  const cancelBoardBatchImport = usePinterestStore((s) => s.cancelBoardBatchImport);

  const folders = useLibraryStore((s) => s.folders);
  const flatFolders = useMemo(() => flattenFolderTree(buildFolderTree(folders)), [folders]);

  const [selectedIds, setSelectedIds] = useState<Record<string, true>>({});
  const [destMode, setDestMode] = useState<DestinationMode>('pinterestRootFolder');
  const [existingFolderId, setExistingFolderId] = useState<string>('');
  const [skipDuplicates, setSkipDuplicates] = useState(true);
  const [extraTagsText, setExtraTagsText] = useState('');

  const isTauri = isTauriRuntime();

  useEffect(() => {
    if (!open) return;
    if (boards.length > 0 && Object.keys(selectedIds).length === 0) {
      const next: Record<string, true> = {};
      for (const b of boards) next[b.id] = true;
      setSelectedIds(next);
    }
  }, [open, boards, selectedIds]);

  useEffect(() => {
    if (!existingFolderId && flatFolders.length > 0) {
      setExistingFolderId(flatFolders[0].folder.id);
    }
  }, [existingFolderId, flatFolders]);

  if (!open) return null;

  const selectedBoards = boards.filter((b) => Boolean(selectedIds[b.id]));
  const allSelected = boards.length > 0 && selectedBoards.length === boards.length;
  const totalEstimatedPins = selectedBoards.reduce((sum, b) => sum + Math.max(0, b.pinCount), 0);

  const toggleBoard = (id: string) => {
    setSelectedIds((prev) => {
      const next = { ...prev };
      if (next[id]) delete next[id];
      else next[id] = true;
      return next;
    });
  };

  const toggleSelectAll = () => {
    if (allSelected) {
      setSelectedIds({});
    } else {
      const next: Record<string, true> = {};
      for (const b of boards) next[b.id] = true;
      setSelectedIds(next);
    }
  };

  const handleStart = async () => {
    if (selectedBoards.length === 0 || isImportingBoards) return;
    let destination: PinterestBoardImportDestination = { kind: 'pinterestRootFolder' };
    if (destMode === 'libraryRoot') {
      destination = { kind: 'libraryRoot' };
    } else if (destMode === 'existingFolder' && existingFolderId) {
      destination = { kind: 'existingFolder', folderID: existingFolderId };
    }
    const extraTags = extraTagsText
      .split(/[,，\n]/)
      .map((s) => s.trim())
      .filter(Boolean);
    await startBoardBatchImport(selectedBoards, destination, extraTags, skipDuplicates);
  };

  const progressRatio =
    progress && progress.totalBoards > 0
      ? Math.min(
          1,
          (progress.completedBoards +
            (progress.currentBoardPinCount > 0
              ? progress.currentBoardProcessedPins / progress.currentBoardPinCount
              : 0)) /
            progress.totalBoards,
        )
      : 0;

  return (
    <div
      role="dialog"
      aria-modal="true"
      aria-label="导入 Pinterest 画板收藏"
      data-testid="pinterest-board-import-modal"
      onPointerDown={(e) => e.stopPropagation()}
      onWheel={(e) => e.stopPropagation()}
      onClick={() => {
        if (!isImportingBoards) closeModal();
      }}
      className="fixed inset-0 z-50 flex items-center justify-center bg-black/52 backdrop-blur-[6px] p-5"
    >
      <div
        onClick={(e) => e.stopPropagation()}
        className="w-full max-w-[680px] max-h-[86vh] flex flex-col rounded-[16px] bg-[var(--bg-elevated)] border border-[var(--win-stroke-card)] shadow-[0_24px_64px_rgba(0,0,0,0.4)] overflow-hidden"
      >
        {/* Header */}
        <div className="px-5 py-3.5 border-b border-[var(--win-stroke-divider)] flex items-center justify-between gap-3">
          <div>
            <h2 className="text-[15px] font-semibold text-[var(--text-primary)]">
              导入 Pinterest 画板收藏
            </h2>
            <p className="text-[12px] text-[var(--text-secondary)] mt-0.5">
              按画板名称自动创建对应 Charkle 文件夹，支持增量跳过已导入素材
            </p>
          </div>
          <button
            type="button"
            disabled={isImportingBoards}
            aria-label="关闭画板导入窗口"
            onClick={closeModal}
            className="w-7 h-7 rounded-[var(--win-radius-control)] inline-flex items-center justify-center text-[var(--text-secondary)] hover:text-[var(--text-primary)] hover:bg-[var(--win-subtle-hover)] disabled:opacity-40 cursor-pointer"
          >
            <Dismiss16Regular className="w-4 h-4" />
          </button>
        </div>

        {/* Body */}
        <div className="flex-1 min-h-0 overflow-y-auto px-5 py-4 flex flex-col gap-4">
          {/* Board list controls */}
          <div className="flex items-center justify-between gap-2">
            <span className="text-[12.5px] font-medium text-[var(--text-primary)]">
              选择要同步的画板（已选 {selectedBoards.length}/{boards.length}，预计约{' '}
              {totalEstimatedPins} 项）
            </span>
            <div className="flex items-center gap-1.5">
              <Button
                variant="subtle"
                size="xs"
                disabled={isLoadingBoards || isImportingBoards}
                onClick={() => void refreshBoards()}
              >
                <ArrowSync16Regular
                  className={`w-3.5 h-3.5 ${isLoadingBoards ? 'animate-spin' : ''}`}
                />
                <span>刷新画板</span>
              </Button>
              <Button
                variant="subtle"
                size="xs"
                disabled={boards.length === 0 || isImportingBoards}
                onClick={toggleSelectAll}
              >
                {allSelected ? '取消全选' : '全选'}
              </Button>
            </div>
          </div>

          {/* Boards grid */}
          <div className="max-h-[240px] overflow-y-auto rounded-[10px] border border-[var(--win-stroke-card)] bg-[var(--bg-subtle)]/50 divide-y divide-[var(--win-stroke-divider)]">
            {isLoadingBoards && boards.length === 0 ? (
              <div className="py-8 text-center text-[12.5px] text-[var(--text-secondary)]">
                正在加载 Pinterest 画板列表…
              </div>
            ) : boards.length === 0 ? (
              <div className="py-8 text-center text-[12.5px] text-[var(--text-tertiary)]">
                未找到可导入的画板，请确认已在 Pinterest 创建收藏画板或点击「刷新画板」
              </div>
            ) : (
              boards.map((board) => {
                const checked = Boolean(selectedIds[board.id]);
                const cover = resolveSocialMediaUrl(board.coverImageURL, isTauri);
                return (
                  <label
                    key={board.id}
                    className="flex items-center gap-3 px-3 py-2.5 hover:bg-[var(--win-subtle-hover)] cursor-pointer select-none"
                  >
                    <input
                      type="checkbox"
                      checked={checked}
                      disabled={isImportingBoards}
                      onChange={() => toggleBoard(board.id)}
                      className="w-4 h-4 accent-[var(--accent)] rounded cursor-pointer"
                    />
                    <div className="w-10 h-10 rounded-[7px] overflow-hidden bg-[var(--bg-subtle)] border border-[var(--win-stroke-card)] shrink-0 flex items-center justify-center">
                      {cover ? (
                        <img
                          src={cover}
                          alt={board.name}
                          className="w-full h-full object-cover"
                        />
                      ) : (
                        <Folder16Regular className="w-4 h-4 text-[var(--text-tertiary)]" />
                      )}
                    </div>
                    <div className="flex-1 min-w-0">
                      <div className="flex items-center gap-1.5">
                        <span className="text-[13px] font-medium text-[var(--text-primary)] truncate">
                          {board.name}
                        </span>
                        {board.isSecret && (
                          <LockClosed12Regular
                            className="w-3 h-3 text-[var(--text-tertiary)] shrink-0"
                            title="私密画板"
                          />
                        )}
                      </div>
                      <div className="text-[11.5px] text-[var(--text-tertiary)] charkle-tabular">
                        {board.pinCount} 个素材
                      </div>
                    </div>
                  </label>
                );
              })
            )}
          </div>

          {/* Destination mode selector */}
          <div className="flex flex-col gap-2">
            <span className="text-[12.5px] font-medium text-[var(--text-primary)]">
              目标文件夹结构
            </span>
            <div className="grid grid-cols-1 sm:grid-cols-3 gap-2">
              {(
                [
                  {
                    id: 'pinterestRootFolder',
                    title: 'Pinterest 父文件夹',
                    desc: '自动归档到「Pinterest / 画板名」',
                  },
                  {
                    id: 'libraryRoot',
                    title: '素材库根目录',
                    desc: '每个画板直接创建顶层文件夹',
                  },
                  {
                    id: 'existingFolder',
                    title: '指定已有文件夹',
                    desc: '放入选定文件夹的子目录中',
                  },
                ] as const
              ).map((opt) => (
                <button
                  key={opt.id}
                  type="button"
                  disabled={isImportingBoards}
                  onClick={() => setDestMode(opt.id)}
                  className={[
                    'p-2.5 rounded-[10px] border text-left transition-colors cursor-pointer disabled:opacity-50',
                    destMode === opt.id
                      ? 'border-[var(--accent)] bg-[var(--accent-soft)]'
                      : 'border-[var(--win-stroke-card)] bg-[var(--bg-subtle)]/40 hover:bg-[var(--win-subtle-hover)]',
                  ].join(' ')}
                >
                  <div className="text-[12.5px] font-medium text-[var(--text-primary)]">
                    {opt.title}
                  </div>
                  <div className="text-[11px] text-[var(--text-secondary)] mt-0.5 leading-snug">
                    {opt.desc}
                  </div>
                </button>
              ))}
            </div>

            {destMode === 'existingFolder' && (
              <select
                value={existingFolderId}
                disabled={isImportingBoards || flatFolders.length === 0}
                onChange={(e) => setExistingFolderId(e.target.value)}
                className="h-8 px-2.5 rounded-[var(--win-radius-control)] bg-[var(--win-control-fill)] border border-[var(--win-stroke-control)] text-[12.5px] text-[var(--text-primary)] outline-none"
              >
                {flatFolders.length === 0 ? (
                  <option value="">暂无已有文件夹</option>
                ) : (
                  flatFolders.map((node) => (
                    <option key={node.folder.id} value={node.folder.id}>
                      {'　'.repeat(node.depth)}
                      {node.folder.name}
                    </option>
                  ))
                )}
              </select>
            )}
          </div>

          {/* Options row */}
          <div className="grid grid-cols-1 sm:grid-cols-2 gap-3 items-center">
            <label className="flex items-center gap-2 text-[12.5px] text-[var(--text-primary)] cursor-pointer select-none">
              <input
                type="checkbox"
                checked={skipDuplicates}
                disabled={isImportingBoards}
                onChange={(e) => setSkipDuplicates(e.target.checked)}
                className="w-4 h-4 accent-[var(--accent)] rounded"
              />
              <span>增量跳过已导入的 Pin</span>
            </label>

            <input
              type="text"
              value={extraTagsText}
              disabled={isImportingBoards}
              onChange={(e) => setExtraTagsText(e.target.value)}
              placeholder="附加标签（逗号分隔，可选）"
              className="h-8 px-2.5 rounded-[var(--win-radius-control)] bg-[var(--win-control-fill)] border border-[var(--win-stroke-control)] text-[12.5px] text-[var(--text-primary)] placeholder:text-[var(--text-tertiary)] outline-none focus:border-[var(--accent)]"
            />
          </div>

          {/* Live progress bar */}
          {isImportingBoards && progress && (
            <div
              data-testid="pinterest-board-import-progress"
              className="p-3 rounded-[10px] bg-[var(--bg-subtle)] border border-[var(--win-stroke-card)] flex flex-col gap-2"
            >
              <div className="flex items-center justify-between text-[12px]">
                <span className="font-medium text-[var(--text-primary)] truncate">
                  {progress.phaseMessage}
                </span>
                <span className="text-[var(--text-secondary)] charkle-tabular shrink-0 ml-2">
                  画板 {Math.min(progress.completedBoards + 1, progress.totalBoards)}/
                  {progress.totalBoards}
                </span>
              </div>
              <div className="h-1.5 rounded-full bg-black/10 dark:bg-white/10 overflow-hidden">
                <div
                  className="h-full rounded-full bg-[var(--accent)] transition-all duration-150"
                  style={{ width: `${Math.max(4, Math.round(progressRatio * 100))}%` }}
                />
              </div>
              <div className="flex items-center gap-4 text-[11.5px] text-[var(--text-secondary)] charkle-tabular">
                <span>新增：{progress.importedCount}</span>
                <span>跳过重复：{progress.skippedCount}</span>
                {progress.failedCount > 0 && (
                  <span className="text-[var(--danger)]">失败：{progress.failedCount}</span>
                )}
              </div>
            </div>
          )}

          {/* Completion summary */}
          {!isImportingBoards && lastReport && (
            <div
              data-testid="pinterest-board-import-report"
              className="p-3 rounded-[10px] bg-emerald-500/10 border border-emerald-500/25 flex items-center gap-2.5 text-[12.5px] text-[var(--text-primary)]"
            >
              <CheckmarkCircle16Filled className="w-4 h-4 text-emerald-500 shrink-0" />
              <div className="flex-1 min-w-0">
                {lastReport.wasCancelled ? '导入已取消：' : '导入完成：'}新增{' '}
                <strong>{lastReport.importedAssetCount}</strong> 项，跳过重复{' '}
                <strong>{lastReport.skippedDuplicateCount}</strong> 项
                {lastReport.failedPinCount > 0 ? `，失败 ${lastReport.failedPinCount} 项` : ''}。
              </div>
            </div>
          )}
        </div>

        {/* Footer */}
        <div className="px-5 py-3 border-t border-[var(--win-stroke-divider)] flex items-center justify-end gap-2">
          {isImportingBoards ? (
            <Button variant="danger" size="sm" onClick={() => void cancelBoardBatchImport()}>
              取消导入
            </Button>
          ) : (
            <>
              <Button variant="standard" size="sm" onClick={closeModal}>
                关闭
              </Button>
              <Button
                variant="accent"
                size="sm"
                data-testid="pinterest-start-board-import-btn"
                disabled={
                  selectedBoards.length === 0 ||
                  (destMode === 'existingFolder' && !existingFolderId)
                }
                onClick={() => void handleStart()}
              >
                开始导入 {selectedBoards.length > 0 ? `(${selectedBoards.length} 个画板)` : ''}
              </Button>
            </>
          )}
        </div>
      </div>
    </div>
  );
};
