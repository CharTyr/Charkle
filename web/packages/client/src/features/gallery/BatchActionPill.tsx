import React, { useRef, useState } from 'react';
import { FolderInput, Sparkles, Tag, Trash2, X } from 'lucide-react';
import { createDefaultAssetBatchPatch } from '@charkle/shared';
import {
  CharkleFolderIcon,
  CharkleIcon,
  GlassSurface,
  Popover,
} from '../../design-system';
import { useCoordinatorStore } from '../../stores/coordinatorStore';
import { useLibraryStore } from '../../stores/libraryStore';
import { useMoodboardStore } from '../../stores/moodboardStore';

export const BatchActionPill: React.FC = () => {
  const selectedAssetIDs = useLibraryStore((s) => s.selectedAssetIDs);
  const folders = useLibraryStore((s) => s.folders);
  const batchPatch = useLibraryStore((s) => s.batchPatch);
  const trashAssets = useLibraryStore((s) => s.trashAssets);
  const clearSelection = useLibraryStore((s) => s.clearSelection);

  const boards = useMoodboardStore((s) => s.boards);
  const addAssetsToBoard = useMoodboardStore((s) => s.addAssetsToBoard);

  const activeBoardID = useCoordinatorStore((s) => s.activeBoardID);
  const openGeneratorModal = useCoordinatorStore((s) => s.openGeneratorModal);
  const pushToast = useCoordinatorStore((s) => s.pushToast);

  const [folderMenuOpen, setFolderMenuOpen] = useState(false);
  const [tagMenuOpen, setTagMenuOpen] = useState(false);
  const [tagDraft, setTagDraft] = useState('');

  const folderBtnRef = useRef<HTMLButtonElement | null>(null);
  const tagBtnRef = useRef<HTMLButtonElement | null>(null);

  if (selectedAssetIDs.size < 2) return null;

  const ids = Array.from(selectedAssetIDs);
  const activeBoard = boards.find((b) => b.id === activeBoardID) ?? boards[0] ?? null;

  const handleAddToBoard = async () => {
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
    if (!cleaned) return;
    setTagDraft('');
    setTagMenuOpen(false);
    await batchPatch(createDefaultAssetBatchPatch(ids, { addTags: [cleaned] }));
    pushToast({ tone: 'success', message: `已为 ${ids.length} 项素材添加标签 #${cleaned}` });
  };

  return (
    <div className="fixed bottom-5 left-1/2 -translate-x-1/2 z-40 pointer-events-none">
      <GlassSurface
        variant="regular"
        radius="dock"
        className="pointer-events-auto p-1.5 flex items-center gap-1 charkle-modal-panel"
      >
        <span className="px-2.5 text-[12.5px] font-semibold text-[var(--text-primary)] tabular-nums">
          已选 {ids.length} 项
        </span>

        <div className="w-px h-4 bg-[var(--border-hairline)] mx-0.5" />

        <button
          type="button"
          onClick={() => void handleAddToBoard()}
          className="charkle-pressable h-8 px-2.5 inline-flex items-center gap-1.5 rounded-[var(--radius-dock-inner)] text-[12.5px] font-medium text-[var(--text-primary)] hover:bg-[var(--bg-subtle)] cursor-pointer"
        >
          <CharkleIcon name="moodboard" size={15} />
          {activeBoard ? `加入「${activeBoard.title}」` : '加入情绪板'}
        </button>

        <button
          type="button"
          onClick={() => openGeneratorModal(ids)}
          className="charkle-pressable h-8 px-2.5 inline-flex items-center gap-1.5 rounded-[var(--radius-dock-inner)] text-[12.5px] font-medium text-[var(--accent)] hover:bg-[var(--accent-soft)] cursor-pointer"
        >
          <Sparkles size={14} />
          以此策展
        </button>

        <button
          ref={folderBtnRef}
          type="button"
          onClick={() => setFolderMenuOpen((v) => !v)}
          className="charkle-pressable h-8 px-2.5 inline-flex items-center gap-1.5 rounded-[var(--radius-dock-inner)] text-[12.5px] font-medium text-[var(--text-primary)] hover:bg-[var(--bg-subtle)] cursor-pointer"
        >
          <FolderInput size={14} />
          移动
        </button>

        <button
          ref={tagBtnRef}
          type="button"
          onClick={() => setTagMenuOpen((v) => !v)}
          className="charkle-pressable h-8 px-2.5 inline-flex items-center gap-1.5 rounded-[var(--radius-dock-inner)] text-[12.5px] font-medium text-[var(--text-primary)] hover:bg-[var(--bg-subtle)] cursor-pointer"
        >
          <Tag size={14} />
          打标签
        </button>

        <button
          type="button"
          onClick={() => void trashAssets(ids)}
          className="charkle-pressable h-8 px-2.5 inline-flex items-center gap-1.5 rounded-[var(--radius-dock-inner)] text-[12.5px] font-medium text-[var(--danger)] hover:bg-[var(--danger-soft)] cursor-pointer"
        >
          <Trash2 size={14} />
          移入回收站
        </button>

        <button
          type="button"
          aria-label="取消选择"
          onClick={clearSelection}
          className="charkle-pressable h-8 w-8 inline-flex items-center justify-center rounded-[var(--radius-dock-inner)] text-[var(--text-tertiary)] hover:text-[var(--text-primary)] hover:bg-[var(--bg-subtle)] cursor-pointer"
        >
          <X size={14} />
        </button>
      </GlassSurface>

      {/* Move to Folder Popover */}
      <Popover
        open={folderMenuOpen}
        onOpenChange={setFolderMenuOpen}
        anchorEl={folderBtnRef.current}
        placement="top-center"
      >
        <div className="w-[220px] max-h-[280px] overflow-y-auto charkle-scroll p-1.5 flex flex-col gap-0.5 text-[12.5px]">
          <button
            type="button"
            onClick={async () => {
              setFolderMenuOpen(false);
              await batchPatch(
                createDefaultAssetBatchPatch(ids, { folderAssignment: { type: 'inbox' } }),
              );
              pushToast({ tone: 'success', message: `已将 ${ids.length} 项移回收件箱` });
            }}
            className="charkle-pressable flex items-center gap-2 px-2.5 py-1.5 rounded-[var(--radius-popover-inner)] hover:bg-[var(--bg-subtle)] text-[var(--text-primary)] cursor-pointer text-left"
          >
            <CharkleIcon name="inbox" size={16} />
            收件箱
          </button>
          {folders.map((folder) => (
            <button
              key={folder.id}
              type="button"
              onClick={async () => {
                setFolderMenuOpen(false);
                await batchPatch(
                  createDefaultAssetBatchPatch(ids, {
                    folderAssignment: { type: 'folder', folderID: folder.id },
                  }),
                );
                pushToast({
                  tone: 'success',
                  message: `已将 ${ids.length} 项移动到「${folder.name}」`,
                });
              }}
              className="charkle-pressable flex items-center gap-2 px-2.5 py-1.5 rounded-[var(--radius-popover-inner)] hover:bg-[var(--bg-subtle)] text-[var(--text-primary)] cursor-pointer text-left"
            >
              <CharkleFolderIcon
                colorHex={folder.colorHex}
                customSymbol={folder.customSymbol}
                size={16}
              />
              <span className="truncate flex-1">{folder.name}</span>
            </button>
          ))}
        </div>
      </Popover>

      {/* Quick Tag Popover */}
      <Popover
        open={tagMenuOpen}
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
            placeholder="输入标签名回车批量添加…"
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
    </div>
  );
};
