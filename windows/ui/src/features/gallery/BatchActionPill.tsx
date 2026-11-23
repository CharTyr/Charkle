import React, { useRef, useState } from 'react';
import {
  FolderInput,
  LayoutGrid,
  Pin,
  RotateCcw,
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
 * Floating bottom BatchActionPill (.charkle-glass) when >= 1 asset is selected.
 */
export const BatchActionPill: React.FC = () => {
  const selectedAssetIds = useCoordinatorStore((s) => s.selectedAssetIds);
  const clearSelection = useCoordinatorStore((s) => s.clearSelection);
  const destination = useCoordinatorStore((s) => s.destination);

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
  const [permDeleteOpen, setPermDeleteOpen] = useState(false);

  const moveBtnRef = useRef<HTMLButtonElement | null>(null);
  const tagBtnRef = useRef<HTMLButtonElement | null>(null);
  const rateBtnRef = useRef<HTMLButtonElement | null>(null);
  const boardBtnRef = useRef<HTMLButtonElement | null>(null);

  if (selectedAssetIds.length === 0) return null;
  const inTrash = destination.type === 'trash';

  const applyBatchTag = async (tag: string) => {
    const clean = tag.trim();
    if (!clean) return;
    await updateAssets({ assetIDs: selectedAssetIds, addTags: [clean] }, destination);
    setTagDraft('');
    setTagOpen(false);
  };

  return (
    <>
      <div className="pointer-events-none fixed bottom-5 left-1/2 -translate-x-1/2 z-[60]">
        <div className="pointer-events-auto charkle-glass rounded-[var(--radius-dock-outer)] px-2.5 py-1.5 flex items-center gap-1 text-[12px]">
          <span className="px-2 font-semibold text-[var(--text-primary)] charkle-tabular">
            已选 {selectedAssetIds.length} 项
          </span>

          <div className="h-4 w-px bg-[var(--border-hairline)] mx-0.5" />

          {!inTrash ? (
            <>
              <button
                ref={moveBtnRef}
                type="button"
                onClick={() => setMoveOpen((v) => !v)}
                className="charkle-pressable h-7 px-2.5 inline-flex items-center gap-1.5 rounded-[var(--radius-dock-inner)] text-[var(--text-primary)] hover:bg-[var(--bg-subtle)] cursor-pointer"
              >
                <FolderInput size={13.5} />
                <span>移动</span>
              </button>

              <button
                ref={tagBtnRef}
                type="button"
                onClick={() => setTagOpen((v) => !v)}
                className="charkle-pressable h-7 px-2.5 inline-flex items-center gap-1.5 rounded-[var(--radius-dock-inner)] text-[var(--text-primary)] hover:bg-[var(--bg-subtle)] cursor-pointer"
              >
                <Tag size={13.5} />
                <span>标签</span>
              </button>

              <button
                ref={rateBtnRef}
                type="button"
                onClick={() => setRateOpen((v) => !v)}
                className="charkle-pressable h-7 px-2.5 inline-flex items-center gap-1.5 rounded-[var(--radius-dock-inner)] text-[var(--text-primary)] hover:bg-[var(--bg-subtle)] cursor-pointer"
              >
                <Star size={13.5} />
                <span>评分</span>
              </button>

              <button
                type="button"
                onClick={() =>
                  void updateAssets(
                    { assetIDs: selectedAssetIds, pinnedOffline: true },
                    destination,
                  )
                }
                className="charkle-pressable h-7 px-2.5 inline-flex items-center gap-1.5 rounded-[var(--radius-dock-inner)] text-[var(--text-primary)] hover:bg-[var(--bg-subtle)] cursor-pointer"
              >
                <Pin size={13.5} />
                <span>离线</span>
              </button>

              {boards.length > 0 && (
                <button
                  ref={boardBtnRef}
                  type="button"
                  onClick={() => setBoardOpen((v) => !v)}
                  className="charkle-pressable h-7 px-2.5 inline-flex items-center gap-1.5 rounded-[var(--radius-dock-inner)] text-[var(--text-primary)] hover:bg-[var(--bg-subtle)] cursor-pointer"
                >
                  <LayoutGrid size={13.5} />
                  <span>情绪板</span>
                </button>
              )}

              <button
                type="button"
                onClick={() => {
                  const ids = [...selectedAssetIds];
                  clearSelection();
                  void updateAssets({ assetIDs: ids, isTrashed: true }, destination, {
                    undoMessage: `已将 ${ids.length} 项移入回收站`,
                    undoPatch: { assetIDs: ids, isTrashed: false },
                  });
                }}
                className="charkle-pressable h-7 px-2.5 inline-flex items-center gap-1.5 rounded-[var(--radius-dock-inner)] text-[var(--danger)] hover:bg-[var(--danger-soft)] cursor-pointer"
              >
                <Trash2 size={13.5} />
                <span>移至回收站</span>
              </button>
            </>
          ) : (
            <>
              <button
                type="button"
                onClick={() => {
                  const ids = [...selectedAssetIds];
                  clearSelection();
                  void updateAssets({ assetIDs: ids, isTrashed: false }, destination);
                }}
                className="charkle-pressable h-7 px-2.5 inline-flex items-center gap-1.5 rounded-[var(--radius-dock-inner)] text-[var(--text-primary)] hover:bg-[var(--bg-subtle)] cursor-pointer"
              >
                <RotateCcw size={13.5} />
                <span>还原</span>
              </button>

              <button
                type="button"
                onClick={() => setPermDeleteOpen(true)}
                className="charkle-pressable h-7 px-2.5 inline-flex items-center gap-1.5 rounded-[var(--radius-dock-inner)] text-[var(--danger)] hover:bg-[var(--danger-soft)] cursor-pointer"
              >
                <Trash2 size={13.5} />
                <span>永久删除</span>
              </button>
            </>
          )}

          <button
            type="button"
            aria-label="取消选择"
            onClick={clearSelection}
            className="charkle-pressable h-7 w-7 inline-flex items-center justify-center rounded-[var(--radius-dock-inner)] text-[var(--text-secondary)] hover:bg-[var(--bg-subtle)] hover:text-[var(--text-primary)] cursor-pointer"
          >
            <X size={14} />
          </button>
        </div>
      </div>

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
            void updateAssets(
              {
                assetIDs: ids,
                folderAssignment: folderId ? { folder: folderId } : 'inbox',
              },
              destination,
              {
                undoMessage: `已移动 ${ids.length} 项素材`,
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
        className="w-[240px] p-2.5"
      >
        <form
          onSubmit={(e) => {
            e.preventDefault();
            void applyBatchTag(tagDraft);
          }}
          className="flex flex-col gap-2"
        >
          <input
            type="text"
            value={tagDraft}
            autoFocus
            onChange={(e) => setTagDraft(e.target.value)}
            placeholder="输入标签后按回车…"
            className="h-7 px-2.5 rounded-[var(--radius-popover-inner)] bg-[var(--bg-subtle)] text-[12px] text-[var(--text-primary)] outline-none"
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
        className="p-2"
      >
        <div className="flex items-center gap-1">
          {[0, 1, 2, 3, 4, 5].map((r) => (
            <button
              key={r}
              type="button"
              onClick={() => {
                setRateOpen(false);
                void updateAssets({ assetIDs: selectedAssetIds, rating: r }, destination);
              }}
              className="charkle-pressable h-7 px-2 rounded-[var(--radius-popover-inner)] text-[12px] text-[var(--text-primary)] hover:bg-[var(--bg-subtle)] cursor-pointer"
            >
              {r === 0 ? '清除' : `${r}★`}
            </button>
          ))}
        </div>
      </Popover>

      {/* Send to Moodboard Popover */}
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

      {/* Bulk Permanent Delete Confirmation Modal (DESIGN.md §7.3) */}
      <ModalShell
        open={permDeleteOpen}
        onClose={() => setPermDeleteOpen(false)}
        title={`永久删除 ${selectedAssetIds.length} 项素材？`}
        width="sm"
        footer={
          <>
            <Button variant="secondary" onClick={() => setPermDeleteOpen(false)}>
              取消
            </Button>
            <Button
              variant="danger"
              onClick={async () => {
                setPermDeleteOpen(false);
                await permanentlyDeleteAssets([...selectedAssetIds], destination);
              }}
            >
              确认永久删除
            </Button>
          </>
        }
      >
        <p className="text-[13px] text-[var(--text-secondary)] leading-relaxed charkle-prose">
          此操作将从本地素材库与同步记录中永久清除这 {selectedAssetIds.length} 项文件，且无法撤销。
        </p>
      </ModalShell>
    </>
  );
};
