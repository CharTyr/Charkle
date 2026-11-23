import React, { useMemo, useRef, useState } from 'react';
import {
  ChevronRight,
  FolderPlus,
  MoreHorizontal,
  Palette,
  Pencil,
  Trash2,
} from 'lucide-react';
import { CharkleFolderIcon, Popconfirm, Popover } from '../../design-system';
import {
  buildFolderTree,
  type FolderRecord,
  type FolderTreeNode,
} from '../../types/domain';
import { FolderCustomizationPopover } from './FolderCustomizationPopover';

export const ASSET_DRAG_MIME = 'application/x-charkle-asset-ids';
const FOLDER_DRAG_MIME = 'application/x-charkle-folder-id';

function isDescendant(
  folders: FolderRecord[],
  candidateId: string,
  possibleAncestorId: string,
): boolean {
  let cursor = folders.find((f) => f.id === candidateId);
  const visited = new Set<string>();
  while (cursor?.parentID) {
    if (cursor.parentID === possibleAncestorId) return true;
    if (visited.has(cursor.parentID)) break;
    visited.add(cursor.parentID);
    cursor = folders.find((f) => f.id === cursor!.parentID);
  }
  return false;
}

export interface FolderTreeProps {
  folders: FolderRecord[];
  activeFolderId: string | null;
  onSelectFolder: (id: string) => void;
  onCreateSubfolder: (parentId: string, name: string) => Promise<void>;
  onRenameFolder: (id: string, name: string) => Promise<void>;
  onMoveFolder: (
    id: string,
    newParentId: string | null,
    insertAtIndex?: number | null,
  ) => Promise<void>;
  onUpdateAppearance: (
    id: string,
    colorHex: string | null,
    customSymbol: string | null,
  ) => Promise<void>;
  onDeleteFolder: (id: string, trashContents: boolean) => Promise<void>;
  onDropAssets: (folderId: string, assetIds: string[]) => Promise<void>;
}

interface FolderRowProps {
  node: FolderTreeNode;
  siblingIndex: number;
  allFolders: FolderRecord[];
  activeFolderId: string | null;
  expandedIds: Set<string>;
  onToggleExpand: (id: string) => void;
  onSelectFolder: (id: string) => void;
  onCreateSubfolder: (parentId: string, name: string) => Promise<void>;
  onRenameFolder: (id: string, name: string) => Promise<void>;
  onMoveFolder: (
    id: string,
    newParentId: string | null,
    insertAtIndex?: number | null,
  ) => Promise<void>;
  onUpdateAppearance: (
    id: string,
    colorHex: string | null,
    customSymbol: string | null,
  ) => Promise<void>;
  onDeleteFolder: (id: string, trashContents: boolean) => Promise<void>;
  onDropAssets: (folderId: string, assetIds: string[]) => Promise<void>;
}

const FolderRow: React.FC<FolderRowProps> = ({
  node,
  siblingIndex,
  allFolders,
  activeFolderId,
  expandedIds,
  onToggleExpand,
  onSelectFolder,
  onCreateSubfolder,
  onRenameFolder,
  onMoveFolder,
  onUpdateAppearance,
  onDeleteFolder,
  onDropAssets,
}) => {
  const { folder, children, depth, totalAssetCount } = node;
  const active = activeFolderId === folder.id;
  const expanded = expandedIds.has(folder.id);

  const [renaming, setRenaming] = useState(false);
  const [renameDraft, setRenameDraft] = useState(folder.name);
  const [creatingChild, setCreatingChild] = useState(false);
  const [childDraft, setChildDraft] = useState('');
  const [menuOpen, setMenuOpen] = useState(false);
  const [customOpen, setCustomOpen] = useState(false);
  const [deleteConfirmOpen, setDeleteConfirmOpen] = useState(false);
  const [dropZone, setDropZone] = useState<'none' | 'before' | 'inside' | 'after'>('none');

  const moreBtnRef = useRef<HTMLButtonElement | null>(null);
  const rowRef = useRef<HTMLDivElement | null>(null);

  const commitRename = async () => {
    const trimmed = renameDraft.trim();
    setRenaming(false);
    if (trimmed && trimmed !== folder.name) {
      await onRenameFolder(folder.id, trimmed);
    }
  };

  const commitSubfolder = async () => {
    const trimmed = childDraft.trim();
    setCreatingChild(false);
    setChildDraft('');
    if (trimmed) {
      await onCreateSubfolder(folder.id, trimmed);
      if (!expanded) onToggleExpand(folder.id);
    }
  };

  const handleDragOver = (e: React.DragEvent) => {
    const types = Array.from(e.dataTransfer.types);
    const hasAssets = types.includes(ASSET_DRAG_MIME);
    const hasFolder = types.includes(FOLDER_DRAG_MIME);
    if (!hasAssets && !hasFolder) return;
    e.preventDefault();
    e.stopPropagation();

    if (hasAssets) {
      e.dataTransfer.dropEffect = 'move';
      setDropZone('inside');
      return;
    }

    const rect = rowRef.current?.getBoundingClientRect();
    if (!rect) return;
    const relY = (e.clientY - rect.top) / Math.max(1, rect.height);
    if (relY < 0.24) setDropZone('before');
    else if (relY > 0.76) setDropZone('after');
    else setDropZone('inside');
    e.dataTransfer.dropEffect = 'move';
  };

  const handleDrop = async (e: React.DragEvent) => {
    e.preventDefault();
    e.stopPropagation();
    const zone = dropZone;
    setDropZone('none');

    const rawAssets = e.dataTransfer.getData(ASSET_DRAG_MIME);
    if (rawAssets) {
      try {
        const ids = JSON.parse(rawAssets) as string[];
        if (Array.isArray(ids) && ids.length > 0) {
          await onDropAssets(folder.id, ids);
        }
      } catch {
        // Ignore malformed drag data
      }
      return;
    }

    const draggedFolderId = e.dataTransfer.getData(FOLDER_DRAG_MIME);
    if (!draggedFolderId || draggedFolderId === folder.id) return;
    if (isDescendant(allFolders, folder.id, draggedFolderId)) return;

    if (zone === 'inside') {
      await onMoveFolder(draggedFolderId, folder.id, null);
      if (!expanded) onToggleExpand(folder.id);
    } else if (zone === 'before') {
      await onMoveFolder(draggedFolderId, folder.parentID ?? null, siblingIndex);
    } else if (zone === 'after') {
      await onMoveFolder(draggedFolderId, folder.parentID ?? null, siblingIndex + 1);
    }
  };

  return (
    <div>
      <div
        ref={rowRef}
        draggable={!renaming}
        onDragStart={(e) => {
          e.dataTransfer.setData(FOLDER_DRAG_MIME, folder.id);
          e.dataTransfer.effectAllowed = 'move';
        }}
        onDragOver={handleDragOver}
        onDragLeave={() => setDropZone('none')}
        onDrop={(e) => void handleDrop(e)}
        onDoubleClick={() => {
          setRenameDraft(folder.name);
          setRenaming(true);
        }}
        style={{ paddingLeft: 6 + depth * 14 }}
        className={[
          'group relative flex items-center gap-1 pr-1.5 h-[30px] rounded-[var(--radius-chip)] select-none cursor-pointer',
          active
            ? 'bg-[var(--accent-soft)] text-[var(--accent)] font-medium'
            : 'text-[var(--text-primary)] hover:bg-[var(--bg-subtle)]/80',
          dropZone === 'inside' ? 'ring-2 ring-[var(--accent)] bg-[var(--accent-soft)]' : '',
        ].join(' ')}
        onClick={() => onSelectFolder(folder.id)}
      >
        {dropZone === 'before' && (
          <div className="pointer-events-none absolute top-0 left-2 right-2 h-[2px] rounded-full bg-[var(--accent)]" />
        )}
        {dropZone === 'after' && (
          <div className="pointer-events-none absolute bottom-0 left-2 right-2 h-[2px] rounded-full bg-[var(--accent)]" />
        )}

        <button
          type="button"
          aria-label={expanded ? '收起子文件夹' : '展开子文件夹'}
          onClick={(e) => {
            e.stopPropagation();
            if (children.length > 0) onToggleExpand(folder.id);
          }}
          className={[
            'w-4 h-4 inline-flex items-center justify-center rounded text-[var(--text-tertiary)] shrink-0',
            children.length > 0 ? 'hover:text-[var(--text-primary)] cursor-pointer' : 'opacity-0 pointer-events-none',
          ].join(' ')}
        >
          <ChevronRight
            size={12}
            className={`transition-transform duration-150 ${expanded ? 'rotate-90' : ''}`}
          />
        </button>

        <CharkleFolderIcon
          colorHex={folder.colorHex}
          customSymbol={folder.customSymbol}
          size={16}
          isActive={active}
        />

        {renaming ? (
          <input
            type="text"
            value={renameDraft}
            autoFocus
            onClick={(e) => e.stopPropagation()}
            onChange={(e) => setRenameDraft(e.target.value)}
            onBlur={() => void commitRename()}
            onKeyDown={(e) => {
              if (e.key === 'Enter') void commitRename();
              if (e.key === 'Escape') setRenaming(false);
            }}
            className="flex-1 min-w-0 h-5 px-1.5 rounded bg-[var(--bg-elevated)] border border-[var(--accent)] text-[12.5px] text-[var(--text-primary)] outline-none"
          />
        ) : (
          <span className="truncate flex-1 min-w-0 text-[12.5px] leading-none">
            {folder.name}
          </span>
        )}

        {!renaming && (
          <>
            <span className="text-[11px] text-[var(--text-tertiary)] charkle-tabular group-hover:hidden">
              {totalAssetCount}
            </span>
            <button
              ref={moreBtnRef}
              type="button"
              aria-label={`更多操作：${folder.name}`}
              onClick={(e) => {
                e.stopPropagation();
                setMenuOpen((v) => !v);
              }}
              className="hidden group-hover:inline-flex h-5 w-5 items-center justify-center rounded text-[var(--text-secondary)] hover:bg-[var(--bg-elevated)] hover:text-[var(--text-primary)] cursor-pointer"
            >
              <MoreHorizontal size={13} />
            </button>
          </>
        )}
      </div>

      {/* Folder action menu */}
      <Popover
        open={menuOpen}
        onOpenChange={setMenuOpen}
        anchorEl={moreBtnRef.current}
        placement="bottom-end"
        className="w-[172px] p-1"
      >
        <button
          type="button"
          onClick={() => {
            setMenuOpen(false);
            setCreatingChild(true);
            if (!expanded) onToggleExpand(folder.id);
          }}
          className="w-full flex items-center gap-2 px-2.5 py-1.5 text-[12.5px] text-[var(--text-primary)] hover:bg-[var(--bg-subtle)] rounded-[var(--radius-popover-inner)] cursor-pointer"
        >
          <FolderPlus size={13.5} className="text-[var(--text-secondary)]" />
          新建子文件夹
        </button>
        <button
          type="button"
          onClick={() => {
            setMenuOpen(false);
            setRenameDraft(folder.name);
            setRenaming(true);
          }}
          className="w-full flex items-center gap-2 px-2.5 py-1.5 text-[12.5px] text-[var(--text-primary)] hover:bg-[var(--bg-subtle)] rounded-[var(--radius-popover-inner)] cursor-pointer"
        >
          <Pencil size={13.5} className="text-[var(--text-secondary)]" />
          重命名
        </button>
        <button
          type="button"
          onClick={() => {
            setMenuOpen(false);
            setCustomOpen(true);
          }}
          className="w-full flex items-center gap-2 px-2.5 py-1.5 text-[12.5px] text-[var(--text-primary)] hover:bg-[var(--bg-subtle)] rounded-[var(--radius-popover-inner)] cursor-pointer"
        >
          <Palette size={13.5} className="text-[var(--text-secondary)]" />
          图标与色彩…
        </button>
        <div className="my-1 h-px bg-[var(--border-hairline)]" />
        <button
          type="button"
          onClick={() => {
            setMenuOpen(false);
            setDeleteConfirmOpen(true);
          }}
          className="w-full flex items-center gap-2 px-2.5 py-1.5 text-[12.5px] text-[var(--danger)] hover:bg-[var(--danger-soft)] rounded-[var(--radius-popover-inner)] cursor-pointer"
        >
          <Trash2 size={13.5} />
          删除文件夹…
        </button>
      </Popover>

      <FolderCustomizationPopover
        open={customOpen}
        onOpenChange={setCustomOpen}
        anchorEl={moreBtnRef.current ?? rowRef.current}
        colorHex={folder.colorHex}
        customSymbol={folder.customSymbol}
        onApply={(hex, sym) => void onUpdateAppearance(folder.id, hex, sym)}
      />

      <Popconfirm
        open={deleteConfirmOpen}
        onOpenChange={setDeleteConfirmOpen}
        anchorEl={moreBtnRef.current ?? rowRef.current}
        title={`删除「${folder.name}」？`}
        description="文件夹内的素材将保留并回到收件箱，不会丢失文件。"
        confirmLabel="删除文件夹"
        onConfirm={() => void onDeleteFolder(folder.id, false)}
      />

      {/* Inline subfolder creation input */}
      {creatingChild && (
        <div
          style={{ paddingLeft: 24 + (depth + 1) * 14 }}
          className="pr-2 py-1"
        >
          <input
            type="text"
            value={childDraft}
            autoFocus
            placeholder="输入子文件夹名称…"
            onChange={(e) => setChildDraft(e.target.value)}
            onBlur={() => void commitSubfolder()}
            onKeyDown={(e) => {
              if (e.key === 'Enter') void commitSubfolder();
              if (e.key === 'Escape') {
                setCreatingChild(false);
                setChildDraft('');
              }
            }}
            className="w-full h-6 px-2 rounded bg-[var(--bg-elevated)] border border-[var(--accent)] text-[12px] text-[var(--text-primary)] outline-none"
          />
        </div>
      )}

      {/* Recursive children */}
      {expanded && children.length > 0 && (
        <div>
          {children.map((child, idx) => (
            <FolderRow
              key={child.folder.id}
              node={child}
              siblingIndex={idx}
              allFolders={allFolders}
              activeFolderId={activeFolderId}
              expandedIds={expandedIds}
              onToggleExpand={onToggleExpand}
              onSelectFolder={onSelectFolder}
              onCreateSubfolder={onCreateSubfolder}
              onRenameFolder={onRenameFolder}
              onMoveFolder={onMoveFolder}
              onUpdateAppearance={onUpdateAppearance}
              onDeleteFolder={onDeleteFolder}
              onDropAssets={onDropAssets}
            />
          ))}
        </div>
      )}
    </div>
  );
};

export const FolderTree: React.FC<FolderTreeProps> = ({
  folders,
  activeFolderId,
  onSelectFolder,
  onCreateSubfolder,
  onRenameFolder,
  onMoveFolder,
  onUpdateAppearance,
  onDeleteFolder,
  onDropAssets,
}) => {
  const tree = useMemo(() => buildFolderTree(folders), [folders]);
  const [expandedIds, setExpandedIds] = useState<Set<string>>(
    () => new Set(folders.filter((f) => !f.parentID).map((f) => f.id)),
  );

  const toggleExpand = (id: string) => {
    setExpandedIds((prev) => {
      const next = new Set(prev);
      if (next.has(id)) next.delete(id);
      else next.add(id);
      return next;
    });
  };

  if (tree.length === 0) {
    return (
      <div className="px-3 py-2 text-[12px] text-[var(--text-tertiary)]">
        暂无文件夹，点击右上角 + 创建
      </div>
    );
  }

  return (
    <div className="flex flex-col gap-0.5">
      {tree.map((node, idx) => (
        <FolderRow
          key={node.folder.id}
          node={node}
          siblingIndex={idx}
          allFolders={folders}
          activeFolderId={activeFolderId}
          expandedIds={expandedIds}
          onToggleExpand={toggleExpand}
          onSelectFolder={onSelectFolder}
          onCreateSubfolder={onCreateSubfolder}
          onRenameFolder={onRenameFolder}
          onMoveFolder={onMoveFolder}
          onUpdateAppearance={onUpdateAppearance}
          onDeleteFolder={onDeleteFolder}
          onDropAssets={onDropAssets}
        />
      ))}
    </div>
  );
};
