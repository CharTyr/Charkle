import React, { useMemo, useRef, useState } from 'react';
import {
  FolderInput,
  Pin,
  RotateCcw,
  Sparkles,
  Square,
  Star,
  Tag,
  Trash2,
  X,
} from 'lucide-react';
import { createDefaultAssetBatchPatch } from '@charkle/shared';
import type { UUID } from '@charkle/shared';
import { apiClient } from '../../api/client';
import {
  CharkleIcon,
  ConfirmDialog,
  FolderHierarchyMenu,
  GlassSurface,
  Popover,
  usePresence,
} from '../../design-system';
import { useCoordinatorStore } from '../../stores/coordinatorStore';
import { useLibraryStore } from '../../stores/libraryStore';
import { useMoodboardStore } from '../../stores/moodboardStore';

export const BatchActionPill: React.FC = () => {
  const destination = useCoordinatorStore((s) => s.destination);
  const activeBoardID = useCoordinatorStore((s) => s.activeBoardID);
  const openGeneratorModal = useCoordinatorStore((s) => s.openGeneratorModal);
  const pushToast = useCoordinatorStore((s) => s.pushToast);

  const selectedAssetIDs = useLibraryStore((s) => s.selectedAssetIDs);
  const assets = useLibraryStore((s) => s.assets);
  const assetsByID = useLibraryStore((s) => s.assetsByID);
  const folders = useLibraryStore((s) => s.folders);
  const batchPatch = useLibraryStore((s) => s.batchPatch);
  const trashAssets = useLibraryStore((s) => s.trashAssets);
  const restoreAssets = useLibraryStore((s) => s.restoreAssets);
  const permanentlyDeleteAssets = useLibraryStore((s) => s.permanentlyDeleteAssets);
  const clearSelection = useLibraryStore((s) => s.clearSelection);
  const upsertAssets = useLibraryStore((s) => s.upsertAssets);

  const boards = useMoodboardStore((s) => s.boards);
  const addAssetsToBoard = useMoodboardStore((s) => s.addAssetsToBoard);

  const [folderMenuOpen, setFolderMenuOpen] = useState(false);
  const [tagMenuOpen, setTagMenuOpen] = useState(false);
  const [ratingMenuOpen, setRatingMenuOpen] = useState(false);
  const [tagDraft, setTagDraft] = useState('');
  const [confirmPermanentDelete, setConfirmPermanentDelete] = useState(false);
  const [aiProgress, setAiProgress] = useState<{ done: number; total: number } | null>(null);
  const aiCancelRef = useRef(false);

  const folderBtnRef = useRef<HTMLButtonElement | null>(null);
  const tagBtnRef = useRef<HTMLButtonElement | null>(null);
  const ratingBtnRef = useRef<HTMLButtonElement | null>(null);

  const lastCountRef = useRef(0);
  const isOpen = selectedAssetIDs.size >= 2;
  if (isOpen) {
    lastCountRef.current = selectedAssetIDs.size;
  }
  const { rendered, state } = usePresence(isOpen, 135);

  const ids = useMemo(() => Array.from(selectedAssetIDs), [selectedAssetIDs]);
  const selectedAssets = useMemo(() => {
    const byIdMap = new Map(assets.map((a) => [a.id, a]));
    return ids
      .map((id) => byIdMap.get(id) ?? assetsByID[id])
      .filter((a): a is NonNullable<typeof a> => Boolean(a));
  }, [ids, assets, assetsByID]);

  const isTrashMode =
    destination.type === 'trash' ||
    (selectedAssets.length > 0 && selectedAssets.every((a) => a.isTrashed));

  const allPinned =
    selectedAssets.length > 0 && selectedAssets.every((a) => Boolean(a.pinnedOffline));

  if (!rendered) {
    return (
      <ConfirmDialog
        open={confirmPermanentDelete}
        onClose={() => setConfirmPermanentDelete(false)}
        title={`彻底删除 ${lastCountRef.current} 项素材？`}
        description="删除后将永久移除文件且无法恢复。"
        confirmLabel="彻底删除"
        onConfirm={async () => {
          if (ids.length === 0) return;
          await permanentlyDeleteAssets(ids);
          pushToast({ tone: 'info', message: `已彻底删除 ${ids.length} 项素材` });
        }}
      />
    );
  }

  const displayCount = isOpen ? ids.length : lastCountRef.current;
  const activeBoard = boards.find((b) => b.id === activeBoardID) ?? boards[0] ?? null;

  const handleAddToBoard = async () => {
    if (ids.length === 0) return;
    if (!activeBoard) {
      openGeneratorModal(ids);
      return;
    }
    await addAssetsToBoard(activeBoard.id, ids);
    pushToast({
      tone: 'success',
      message: `已将 ${ids.length} 项素材加入情绪板「${activeBoard.title}」`,
    });
  };

  const handleAddTag = async () => {
    const cleaned = tagDraft.trim().replace(/^#+/, '');
    if (!cleaned || ids.length === 0) return;
    setTagDraft('');
    setTagMenuOpen(false);
    await batchPatch(createDefaultAssetBatchPatch(ids, { addTags: [cleaned] }));
    pushToast({ tone: 'success', message: `已为 ${ids.length} 项素材添加标签 #${cleaned}` });
  };

  const handleBatchRate = async (rating: number) => {
    setRatingMenuOpen(false);
    if (ids.length === 0) return;
    await batchPatch(createDefaultAssetBatchPatch(ids, { rating }));
    pushToast({
      tone: 'success',
      message: rating > 0 ? `已为 ${ids.length} 项设为 ${rating} 星` : `已清除 ${ids.length} 项评分`,
    });
  };

  const handleBatchTogglePin = async () => {
    if (ids.length === 0) return;
    const nextPinned = !allPinned;
    await batchPatch(createDefaultAssetBatchPatch(ids, { pinnedOffline: nextPinned }));
    pushToast({
      tone: 'info',
      message: nextPinned
        ? `已为 ${ids.length} 项保留离线副本`
        : `已取消 ${ids.length} 项离线保留`,
    });
  };

  const handleBatchAIAnalyze = async () => {
    if (ids.length === 0) return;
    if (aiProgress) {
      aiCancelRef.current = true;
      return;
    }
    aiCancelRef.current = false;
    const targets: UUID[] = [...ids];
    const batchSize = 4;
    let done = 0;
    setAiProgress({ done: 0, total: targets.length });
    try {
      for (let i = 0; i < targets.length; i += batchSize) {
        if (aiCancelRef.current) break;
        const slice = targets.slice(i, i + batchSize);
        const res = await apiClient.analyzeAssets({ ids: slice });
        if (res.assets?.length) upsertAssets(res.assets);
        done = Math.min(targets.length, i + slice.length);
        setAiProgress({ done, total: targets.length });
      }
      pushToast({
        tone: aiCancelRef.current ? 'info' : 'success',
        message: aiCancelRef.current
          ? `已停止 AI 打标（已完成 ${done}/${targets.length}）`
          : `已完成 ${done} 项 AI 打标`,
      });
    } catch (err) {
      pushToast({
        tone: 'error',
        message: err instanceof Error ? err.message : '批量 AI 打标失败',
      });
    } finally {
      setAiProgress(null);
      aiCancelRef.current = false;
    }
  };

  return (
    <>
      <div className="fixed bottom-5 left-1/2 -translate-x-1/2 z-40 pointer-events-none">
        <GlassSurface
          variant="regular"
          radius="dock"
          data-state={state}
          className={[
            'charkle-pill-transition p-1.5 flex items-center gap-1 max-w-[calc(100vw-32px)] overflow-x-auto',
            state === 'closing' ? 'pointer-events-none' : 'pointer-events-auto',
          ].join(' ')}
        >
          <span className="px-2.5 text-[12.5px] font-semibold text-[var(--text-primary)] tabular-nums shrink-0">
            已选 {displayCount} 项
          </span>

          <div className="w-px h-4 bg-[var(--border-hairline)] mx-0.5 shrink-0" />

          {isTrashMode ? (
            <>
              <button
                type="button"
                onClick={() => void restoreAssets(ids)}
                className="charkle-pressable h-8 px-2.5 inline-flex items-center gap-1.5 rounded-[var(--radius-dock-inner)] text-[12.5px] font-medium text-[var(--text-primary)] hover:bg-[var(--bg-subtle)] cursor-pointer shrink-0"
              >
                <RotateCcw size={14} />
                恢复
              </button>

              <button
                type="button"
                onClick={() => setConfirmPermanentDelete(true)}
                className="charkle-pressable h-8 px-2.5 inline-flex items-center gap-1.5 rounded-[var(--radius-dock-inner)] text-[12.5px] font-medium text-[var(--danger)] hover:bg-[var(--danger-soft)] cursor-pointer shrink-0"
              >
                <Trash2 size={14} />
                彻底删除
              </button>
            </>
          ) : (
            <>
              <button
                type="button"
                onClick={() => void handleAddToBoard()}
                className="charkle-pressable h-8 px-2.5 inline-flex items-center gap-1.5 rounded-[var(--radius-dock-inner)] text-[12.5px] font-medium text-[var(--text-primary)] hover:bg-[var(--bg-subtle)] cursor-pointer shrink-0"
              >
                <CharkleIcon name="moodboard" size={15} />
                {activeBoard ? `加入「${activeBoard.title}」` : '加入情绪板'}
              </button>

              <button
                type="button"
                onClick={() => openGeneratorModal(ids)}
                className="charkle-pressable h-8 px-2.5 inline-flex items-center gap-1.5 rounded-[var(--radius-dock-inner)] text-[12.5px] font-medium text-[var(--accent)] hover:bg-[var(--accent-soft)] cursor-pointer shrink-0"
              >
                <Sparkles size={14} />
                以此策展
              </button>

              <button
                ref={folderBtnRef}
                type="button"
                onClick={() => setFolderMenuOpen((v) => !v)}
                className="charkle-pressable h-8 px-2.5 inline-flex items-center gap-1.5 rounded-[var(--radius-dock-inner)] text-[12.5px] font-medium text-[var(--text-primary)] hover:bg-[var(--bg-subtle)] cursor-pointer shrink-0"
              >
                <FolderInput size={14} />
                移动
              </button>

              <button
                ref={tagBtnRef}
                type="button"
                onClick={() => setTagMenuOpen((v) => !v)}
                className="charkle-pressable h-8 px-2.5 inline-flex items-center gap-1.5 rounded-[var(--radius-dock-inner)] text-[12.5px] font-medium text-[var(--text-primary)] hover:bg-[var(--bg-subtle)] cursor-pointer shrink-0"
              >
                <Tag size={14} />
                打标签
              </button>

              <button
                ref={ratingBtnRef}
                type="button"
                onClick={() => setRatingMenuOpen((v) => !v)}
                title="批量评分"
                className="charkle-pressable h-8 px-2 inline-flex items-center gap-1 rounded-[var(--radius-dock-inner)] text-[12.5px] font-medium text-[var(--text-primary)] hover:bg-[var(--bg-subtle)] cursor-pointer shrink-0"
              >
                <Star size={14} />
                评分
              </button>

              <button
                type="button"
                onClick={() => void handleBatchAIAnalyze()}
                title={aiProgress ? '停止批量 AI 打标' : '批量 AI 打标'}
                className={[
                  'charkle-pressable h-8 px-2 inline-flex items-center gap-1.5 rounded-[var(--radius-dock-inner)] text-[12.5px] font-medium cursor-pointer shrink-0',
                  aiProgress
                    ? 'bg-[var(--accent-soft)] text-[var(--accent)]'
                    : 'text-[var(--text-primary)] hover:bg-[var(--bg-subtle)]',
                ].join(' ')}
              >
                {aiProgress ? (
                  <>
                    <Square size={11} className="fill-current" />
                    <span className="tabular-nums">
                      {aiProgress.done}/{aiProgress.total}
                    </span>
                  </>
                ) : (
                  <>
                    <Sparkles size={13.5} />
                    AI 打标
                  </>
                )}
              </button>

              <button
                type="button"
                onClick={() => void handleBatchTogglePin()}
                title={allPinned ? '取消离线保留' : '保留离线副本'}
                className={[
                  'charkle-pressable h-8 w-8 inline-flex items-center justify-center rounded-[var(--radius-dock-inner)] cursor-pointer shrink-0',
                  allPinned
                    ? 'bg-[var(--accent-soft)] text-[var(--accent)]'
                    : 'text-[var(--text-secondary)] hover:text-[var(--text-primary)] hover:bg-[var(--bg-subtle)]',
                ].join(' ')}
              >
                <Pin size={14} />
              </button>

              <button
                type="button"
                onClick={() => void trashAssets(ids)}
                className="charkle-pressable h-8 px-2.5 inline-flex items-center gap-1.5 rounded-[var(--radius-dock-inner)] text-[12.5px] font-medium text-[var(--danger)] hover:bg-[var(--danger-soft)] cursor-pointer shrink-0"
              >
                <Trash2 size={14} />
                移入回收站
              </button>
            </>
          )}

          <button
            type="button"
            aria-label="取消选择"
            onClick={clearSelection}
            className="charkle-pressable h-8 w-8 inline-flex items-center justify-center rounded-[var(--radius-dock-inner)] text-[var(--text-tertiary)] hover:text-[var(--text-primary)] hover:bg-[var(--bg-subtle)] cursor-pointer shrink-0"
          >
            <X size={14} />
          </button>
        </GlassSurface>

        {/* Move to Folder Popover */}
        <Popover
          open={folderMenuOpen && isOpen && !isTrashMode}
          onOpenChange={setFolderMenuOpen}
          anchorEl={folderBtnRef.current}
          placement="top-center"
        >
          <FolderHierarchyMenu
            folders={folders}
            includeInbox
            parentSelfPrefix="放入"
            onSelectFolder={async (folderID) => {
              setFolderMenuOpen(false);
              await batchPatch(
                createDefaultAssetBatchPatch(ids, {
                  folderAssignment: folderID ? { type: 'folder', folderID } : { type: 'inbox' },
                }),
              );
              const label = folderID
                ? folders.find((f) => f.id === folderID)?.name ?? '文件夹'
                : '收件箱';
              pushToast({
                tone: 'success',
                message: `已将 ${ids.length} 项移动到「${label}」`,
              });
            }}
          />
        </Popover>

        {/* Quick Tag Popover */}
        <Popover
          open={tagMenuOpen && isOpen && !isTrashMode}
          onOpenChange={setTagMenuOpen}
          anchorEl={tagBtnRef.current}
          placement="top-center"
        >
          <div className="w-[240px] p-2.5 flex items-center gap-1.5">
            <input
              type="text"
              autoFocus
              value={tagDraft}
              onChange={(e) => setTagDraft(e.target.value)}
              onKeyDown={(e) => {
                if (e.key === 'Enter') void handleAddTag();
              }}
              placeholder="输入标签回车添加…"
              className="flex-1 h-8 px-2.5 text-[12.5px] rounded-[var(--radius-chip)] bg-[var(--bg-elevated)] border border-[var(--border-hairline)] text-[var(--text-primary)] focus:outline-none focus:border-[var(--accent)]"
            />
            <button
              type="button"
              onClick={() => void handleAddTag()}
              className="charkle-pressable h-8 px-2.5 rounded-[var(--radius-chip)] bg-[var(--accent)] text-white text-[12px] font-medium cursor-pointer"
            >
              添加
            </button>
          </div>
        </Popover>

        {/* Batch Rating Popover */}
        <Popover
          open={ratingMenuOpen && isOpen && !isTrashMode}
          onOpenChange={setRatingMenuOpen}
          anchorEl={ratingBtnRef.current}
          placement="top-center"
        >
          <div className="p-2 flex items-center gap-1">
            {[1, 2, 3, 4, 5].map((star) => (
              <button
                key={star}
                type="button"
                title={`设为 ${star} 星`}
                onClick={() => void handleBatchRate(star)}
                className="charkle-pressable h-8 w-8 rounded-[var(--radius-chip)] hover:bg-[var(--bg-subtle)] inline-flex items-center justify-center cursor-pointer"
              >
                <Star size={16} className="fill-[#F2C14E] text-[#F2C14E]" />
              </button>
            ))}
            <button
              type="button"
              onClick={() => void handleBatchRate(0)}
              className="charkle-pressable h-8 px-2 rounded-[var(--radius-chip)] text-[11.5px] text-[var(--text-secondary)] hover:bg-[var(--bg-subtle)] cursor-pointer"
            >
              清除
            </button>
          </div>
        </Popover>
      </div>

      {/* Confirmed Permanent Delete Dialog */}
      <ConfirmDialog
        open={confirmPermanentDelete}
        onClose={() => setConfirmPermanentDelete(false)}
        title={`彻底删除 ${ids.length} 项素材？`}
        description="删除后将永久移除文件且无法恢复。"
        confirmLabel="彻底删除"
        onConfirm={async () => {
          if (ids.length === 0) return;
          await permanentlyDeleteAssets(ids);
          pushToast({ tone: 'info', message: `已彻底删除 ${ids.length} 项素材` });
        }}
      />
    </>
  );
};
