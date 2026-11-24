import React, { useMemo, useRef, useState } from 'react';
import {
  ArrowDownCircle,
  Cloud,
  FolderInput,
  LayoutGrid,
  RotateCcw,
  Sparkles,
  Star,
  Tag,
  Trash2,
  X,
} from 'lucide-react';
import { Button, ModalShell, Popover } from '../../design-system';
import {
  useCoordinatorStore,
  useLibraryStore,
  useMoodboardStore,
} from '../../stores';
import { FolderMoveMenu } from '../sidebar/FolderMoveMenu';

/**
 * Floating bottom-center Liquid Glass multi-select batch action capsule (shown when >= 2 items selected,
 * matching macOS `MainWindowView.swift:751, 1861-2070`).
 */
export const BatchActionPill: React.FC = () => {
  const selectedAssetIds = useCoordinatorStore((s) => s.selectedAssetIds);
  const clearSelection = useCoordinatorStore((s) => s.clearSelection);
  const destination = useCoordinatorStore((s) => s.destination);
  const setMoodboardGeneratorOpen = useCoordinatorStore((s) => s.setMoodboardGeneratorOpen);
  const pushToast = useCoordinatorStore((s) => s.pushToast);
  const isModalOverlayActive = useCoordinatorStore(
    (s) =>
      s.settingsOpen ||
      s.onboardingOpen ||
      s.quickLookAssetId !== null ||
      s.jumpOpen ||
      s.captureOpen ||
      s.moodboardGeneratorOpen,
  );

  const assets = useLibraryStore((s) => s.assets);
  const folders = useLibraryStore((s) => s.folders);
  const tagCounts = useLibraryStore((s) => s.tagCounts);
  const updateAssets = useLibraryStore((s) => s.updateAssets);
  const permanentlyDeleteAssets = useLibraryStore((s) => s.permanentlyDeleteAssets);

  const boards = useMoodboardStore((s) => s.boards);
  const addAssetsToBoard = useMoodboardStore((s) => s.addAssetsToBoard);

  const [moveOpen, setMoveOpen] = useState(false);
  const [tagOpen, setTagOpen] = useState(false);
  const [rateOpen, setRateOpen] = useState(false);
  const [boardOpen, setBoardOpen] = useState(false);
  const [tagDraft, setTagDraft] = useState('');
  const [permDeleteIds, setPermDeleteIds] = useState<string[] | null>(null);

  const moveBtnRef = useRef<HTMLButtonElement | null>(null);
  const tagBtnRef = useRef<HTMLButtonElement | null>(null);
  const rateBtnRef = useRef<HTMLButtonElement | null>(null);
  const boardBtnRef = useRef<HTMLButtonElement | null>(null);

  const selectedAssets = useMemo(() => {
    if (selectedAssetIds.length < 2) return [];
    const set = new Set(selectedAssetIds);
    return assets.filter((a) => set.has(a.id));
  }, [assets, selectedAssetIds]);

  const showPill = selectedAssetIds.length >= 2 && !isModalOverlayActive;
  if (!showPill && permDeleteIds === null) return null;

  const isTrashSelection =
    destination.type === 'trash' ||
    (selectedAssets.length > 0 && selectedAssets.every((a) => a.isTrashed));
  const allKeptLocally =
    selectedAssets.length > 0 && selectedAssets.every((a) => a.pinnedOffline);

  const applyBatchTag = async (tag: string) => {
    const clean = tag.trim();
    const ids = [...selectedAssetIds];
    if (!clean || ids.length === 0) return;
    await updateAssets({ assetIDs: ids, addTags: [clean] }, destination);
    setTagDraft('');
    setTagOpen(false);
    pushToast({
      message: `已为 ${ids.length} 项添加标签 #${clean}`,
      tone: 'success',
    });
  };

  return (
    <>
      {showPill && (
      <div className="pointer-events-none absolute bottom-5 left-1/2 -translate-x-1/2 z-30 max-w-[calc(100%-32px)]">
        <div
          data-pill="true"
          data-adapt-glass="true"
          className="charkle-reveal-bottom pointer-events-auto charkle-glass rounded-full px-3 py-1.5 flex items-center gap-1.5 text-[12px]"
        >
          <span className="pl-1 pr-1.5 font-semibold text-[var(--text-primary)] charkle-tabular whitespace-nowrap">
            已选 {selectedAssetIds.length} 项
          </span>

          <div className="h-4 w-px bg-[var(--border-hairline)]" />

          {isTrashSelection ? (
            <>
              <button
                type="button"
                data-pill="true"
                onClick={() => {
                  const ids = [...selectedAssetIds];
                  clearSelection();
                  void updateAssets({ assetIDs: ids, isTrashed: false }, destination).then(() =>
                    pushToast({
                      message: `已将 ${ids.length} 项放回原处`,
                      tone: 'success',
                    }),
                  );
                }}
                className="charkle-pressable h-7 px-3 inline-flex items-center gap-1.5 rounded-full bg-[var(--accent)] hover:bg-[var(--accent-hover)] text-white font-semibold cursor-pointer whitespace-nowrap"
              >
                <RotateCcw size={13} />
                <span>放回原处</span>
              </button>

              <button
                type="button"
                data-pill="true"
                onClick={() => setPermDeleteIds([...selectedAssetIds])}
                className="charkle-pressable h-7 px-2.5 inline-flex items-center gap-1.5 rounded-full bg-[var(--danger-soft)] text-[var(--danger)] hover:bg-[var(--danger)] hover:text-white font-semibold cursor-pointer whitespace-nowrap"
              >
                <Trash2 size={13} />
                <span>彻底删除</span>
              </button>
            </>
          ) : (
            <>
              {/* Primary Cobalt CTA: Generate Moodboard from selection */}
              <button
                type="button"
                data-pill="true"
                onClick={() => setMoodboardGeneratorOpen(true)}
                className="charkle-pressable h-7 px-3 inline-flex items-center gap-1.5 rounded-full bg-[var(--accent)] hover:bg-[var(--accent-hover)] text-white font-semibold cursor-pointer whitespace-nowrap"
              >
                <Sparkles size={13} />
                <span>生成情绪板</span>
              </button>

              {boards.length > 0 && (
                <button
                  ref={boardBtnRef}
                  type="button"
                  onClick={() => setBoardOpen((v) => !v)}
                  className="charkle-pressable h-7 px-2 inline-flex items-center gap-1 rounded-full text-[var(--text-primary)] hover:bg-black/[0.06] dark:hover:bg-white/[0.10] font-medium cursor-pointer whitespace-nowrap"
                >
                  <LayoutGrid size={13} />
                  <span>加入板</span>
                </button>
              )}

              <button
                ref={moveBtnRef}
                type="button"
                onClick={() => setMoveOpen((v) => !v)}
                className="charkle-pressable h-7 px-2 inline-flex items-center gap-1 rounded-full text-[var(--text-primary)] hover:bg-black/[0.06] dark:hover:bg-white/[0.10] font-medium cursor-pointer whitespace-nowrap"
              >
                <FolderInput size={13} />
                <span>移动</span>
              </button>

              <button
                ref={tagBtnRef}
                type="button"
                onClick={() => setTagOpen((v) => !v)}
                className="charkle-pressable h-7 px-2 inline-flex items-center gap-1 rounded-full text-[var(--text-primary)] hover:bg-black/[0.06] dark:hover:bg-white/[0.10] font-medium cursor-pointer whitespace-nowrap"
              >
                <Tag size={13} />
                <span>加标签</span>
              </button>

              <button
                ref={rateBtnRef}
                type="button"
                onClick={() => setRateOpen((v) => !v)}
                className="charkle-pressable h-7 px-2 inline-flex items-center gap-1 rounded-full text-[var(--text-primary)] hover:bg-black/[0.06] dark:hover:bg-white/[0.10] font-medium cursor-pointer whitespace-nowrap"
              >
                <Star size={13} />
                <span>评分</span>
              </button>

              {/* Smart Kept-Locally Toggle */}
              <button
                type="button"
                aria-label={allKeptLocally ? '取消全部保留在本地' : '全部始终保留在本地'}
                title={allKeptLocally ? '取消全部保留在本地' : '全部始终保留在本地'}
                onClick={() => {
                  const nextPinned = !allKeptLocally;
                  const count = selectedAssetIds.length;
                  void updateAssets(
                    { assetIDs: selectedAssetIds, pinnedOffline: nextPinned },
                    destination,
                  ).then(() =>
                    pushToast({
                      message: nextPinned
                        ? `已将 ${count} 项设为始终保留在本地`
                        : `已取消 ${count} 项的始终保留`,
                      tone: 'info',
                    }),
                  );
                }}
                className={[
                  'charkle-pressable h-7 w-7 inline-flex items-center justify-center rounded-full hover:bg-black/[0.06] dark:hover:bg-white/[0.10] cursor-pointer',
                  allKeptLocally ? 'text-[var(--accent)]' : 'text-[var(--text-primary)]',
                ].join(' ')}
              >
                {allKeptLocally ? <ArrowDownCircle size={14} /> : <Cloud size={14} />}
              </button>

              <button
                type="button"
                aria-label="移至回收站"
                title="移至回收站"
                onClick={() => {
                  const ids = [...selectedAssetIds];
                  clearSelection();
                  void updateAssets({ assetIDs: ids, isTrashed: true }, destination, {
                    undoMessage: `已移至回收站 (${ids.length} 项)`,
                    undoPatch: { assetIDs: ids, isTrashed: false },
                  });
                }}
                className="charkle-pressable h-7 w-7 inline-flex items-center justify-center rounded-full text-[var(--danger)] hover:bg-[var(--danger-soft)] cursor-pointer"
              >
                <Trash2 size={13.5} />
              </button>
            </>
          )}

          <button
            type="button"
            aria-label="取消选择"
            title="取消选择 (Esc)"
            onClick={clearSelection}
            className="charkle-pressable h-6 w-6 inline-flex items-center justify-center rounded-full text-[var(--text-secondary)] hover:bg-black/[0.06] dark:hover:bg-white/[0.10] hover:text-[var(--text-primary)] cursor-pointer"
          >
            <X size={12.5} />
          </button>
        </div>
      </div>
      )}

      {/* Move Popover */}
      <Popover
        open={moveOpen}
        onOpenChange={setMoveOpen}
        anchorEl={moveBtnRef.current}
        placement="top-center"
        className="p-1.5"
      >
        <FolderMoveMenu
          folders={folders}
          onSelectFolder={(folderId) => {
            setMoveOpen(false);
            const ids = [...selectedAssetIds];
            const destName = folderId
              ? folders.find((f) => f.id === folderId)?.name ?? '文件夹'
              : '收件箱';
            void updateAssets(
              {
                assetIDs: ids,
                folderAssignment: folderId ? { folder: folderId } : 'inbox',
              },
              destination,
              {
                undoMessage: `已移动 ${ids.length} 项至「${destName}」`,
                undoPatch: { assetIDs: ids, folderAssignment: 'inbox' },
              },
            );
          }}
        />
      </Popover>

      {/* Batch Tag Popover */}
      <Popover
        open={tagOpen}
        onOpenChange={setTagOpen}
        anchorEl={tagBtnRef.current}
        placement="top-center"
        className="w-[244px] p-3"
      >
        <form
          onSubmit={(e) => {
            e.preventDefault();
            void applyBatchTag(tagDraft);
          }}
          className="flex flex-col gap-2"
        >
          <div className="text-[12px] font-semibold text-[var(--text-primary)]">
            为 {selectedAssetIds.length} 项素材添加标签
          </div>
          <input
            type="text"
            value={tagDraft}
            autoFocus
            onChange={(e) => setTagDraft(e.target.value)}
            placeholder="输入标签回车…"
            className="h-7 px-2.5 rounded-[var(--radius-popover-inner)] bg-[var(--bg-subtle)] text-[12px] text-[var(--text-primary)] outline-none focus:ring-1 focus:ring-[var(--accent)]"
          />
          {tagCounts.length > 0 && (
            <div className="flex flex-wrap gap-1">
              {tagCounts.slice(0, 8).map((t) => (
                <button
                  key={t.name}
                  type="button"
                  onClick={() => void applyBatchTag(t.name)}
                  className="charkle-pressable px-2 py-0.5 text-[11px] rounded-full bg-[var(--bg-subtle)] text-[var(--text-secondary)] hover:text-[var(--text-primary)] cursor-pointer"
                >
                  #{t.name}
                </button>
              ))}
            </div>
          )}
        </form>
      </Popover>

      {/* Batch Rating Popover */}
      <Popover
        open={rateOpen}
        onOpenChange={setRateOpen}
        anchorEl={rateBtnRef.current}
        placement="top-center"
        className="p-1.5"
      >
        <div className="flex flex-col gap-0.5 min-w-[128px]">
          {[1, 2, 3, 4, 5].map((r) => (
            <button
              key={r}
              type="button"
              onClick={() => {
                setRateOpen(false);
                void updateAssets({ assetIDs: selectedAssetIds, rating: r }, destination);
              }}
              className="charkle-pressable w-full flex items-center gap-0.5 px-2.5 py-1.5 rounded-[var(--radius-popover-inner)] text-[12px] text-[#E5B243] hover:bg-[var(--bg-subtle)] cursor-pointer"
            >
              {'★'.repeat(r)}
            </button>
          ))}
          <div className="my-0.5 h-px bg-[var(--border-hairline)]" />
          <button
            type="button"
            onClick={() => {
              setRateOpen(false);
              void updateAssets({ assetIDs: selectedAssetIds, rating: 0 }, destination);
            }}
            className="charkle-pressable w-full text-left px-2.5 py-1.5 rounded-[var(--radius-popover-inner)] text-[12px] text-[var(--text-secondary)] hover:bg-[var(--bg-subtle)] cursor-pointer"
          >
            清除评分
          </button>
        </div>
      </Popover>

      {/* Send to Existing Moodboard Popover */}
      <Popover
        open={boardOpen}
        onOpenChange={setBoardOpen}
        anchorEl={boardBtnRef.current}
        placement="top-center"
        className="w-[220px] p-1.5"
      >
        <div className="flex flex-col gap-0.5">
          {boards.map((b) => (
            <button
              key={b.id}
              type="button"
              onClick={() => {
                setBoardOpen(false);
                void addAssetsToBoard(b.id, selectedAssetIds);
              }}
              className="w-full text-left px-2.5 py-1.5 text-[12.5px] rounded-[var(--radius-popover-inner)] text-[var(--text-primary)] hover:bg-[var(--bg-subtle)] truncate cursor-pointer"
            >
              {b.title}
            </button>
          ))}
        </div>
      </Popover>

      {/* Bulk Permanent Delete Confirmation Modal */}
      <ModalShell
        open={permDeleteIds !== null}
        onClose={() => setPermDeleteIds(null)}
        title={`彻底删除 ${permDeleteIds?.length ?? 0} 项素材？`}
        width="sm"
        footer={
          <>
            <Button variant="secondary" onClick={() => setPermDeleteIds(null)}>
              取消
            </Button>
            <Button
              variant="danger"
              onClick={async () => {
                const ids = permDeleteIds ?? [];
                setPermDeleteIds(null);
                if (ids.length > 0) {
                  clearSelection();
                  await permanentlyDeleteAssets(ids, destination);
                }
              }}
            >
              彻底删除
            </Button>
          </>
        }
      >
        <p className="text-[13px] text-[var(--text-secondary)] leading-relaxed charkle-prose">
          彻底删除后将无法从回收站恢复。
        </p>
      </ModalShell>
    </>
  );
};
