import React, { useMemo, useState } from 'react';
import {
  ArrowDownCircle,
  ChevronRight,
  FolderPlus,
  MoreHorizontal,
  Palette,
  Pencil,
  Trash2,
} from 'lucide-react';
import { createDefaultAssetBatchPatch } from '@charkle/shared';
import type { FolderRecord, UUID } from '@charkle/shared';
import {
  Button,
  CharkleFolderIcon,
  MACOS_FOLDER_COLORS,
  ModalShell,
  Popover,
} from '../../design-system';
import { useCoordinatorStore } from '../../stores/coordinatorStore';
import { useLibraryStore } from '../../stores/libraryStore';
import { FolderCustomizationPopover } from './FolderCustomizationPopover';

export type FolderSortMode = 'manual' | 'name' | 'count';

export interface FolderTreeProps {
  sortMode: FolderSortMode;
  collapsed: boolean;
}

type DropPosition = 'before' | 'inside' | 'after';

interface DropTargetState {
  folderID: UUID;
  position: DropPosition;
}

export const FolderTree: React.FC<FolderTreeProps> = ({ sortMode, collapsed }) => {
  const folders = useLibraryStore((s) => s.folders);
  const createFolder = useLibraryStore((s) => s.createFolder);
  const renameFolder = useLibraryStore((s) => s.renameFolder);
  const moveFolder = useLibraryStore((s) => s.moveFolder);
  const updateFolderAppearance = useLibraryStore((s) => s.updateFolderAppearance);
  const deleteFolder = useLibraryStore((s) => s.deleteFolder);
  const pinFolderOffline = useLibraryStore((s) => s.pinFolderOffline);
  const batchPatch = useLibraryStore((s) => s.batchPatch);
  const uploadFiles = useLibraryStore((s) => s.uploadFiles);

  const destination = useCoordinatorStore((s) => s.destination);
  const navigate = useCoordinatorStore((s) => s.navigate);
  const pushToast = useCoordinatorStore((s) => s.pushToast);

  const [expandedIDs, setExpandedIDs] = useState<Set<UUID>>(() => new Set());
  const [renamingID, setRenamingID] = useState<UUID | null>(null);
  const [renameDraft, setRenameDraft] = useState('');
  const [creatingUnderParentID, setCreatingUnderParentID] = useState<UUID | null>(null);
  const [newSubfolderName, setNewSubfolderName] = useState('');

  const [draggedFolderID, setDraggedFolderID] = useState<UUID | null>(null);
  const [dropTarget, setDropTarget] = useState<DropTargetState | null>(null);

  const [menuState, setMenuState] = useState<{
    folder: FolderRecord;
    anchorEl?: HTMLElement | null;
    anchorPoint?: { x: number; y: number } | null;
  } | null>(null);

  const [customizeState, setCustomizeState] = useState<{
    folder: FolderRecord;
    anchorEl?: HTMLElement | null;
    anchorPoint?: { x: number; y: number } | null;
  } | null>(null);

  const [deleteDialogFolder, setDeleteDialogFolder] = useState<FolderRecord | null>(null);

  const childrenByParent = useMemo(() => {
    const map = new Map<UUID | null, FolderRecord[]>();
    for (const folder of folders) {
      const key = folder.parentID ?? null;
      const list = map.get(key) ?? [];
      list.push(folder);
      map.set(key, list);
    }
    for (const [, list] of map) {
      list.sort((a, b) => {
        if (sortMode === 'name') return a.name.localeCompare(b.name, 'zh-CN');
        if (sortMode === 'count') {
          if (b.assetCount !== a.assetCount) return b.assetCount - a.assetCount;
          return a.name.localeCompare(b.name, 'zh-CN');
        }
        if (a.sortOrder !== b.sortOrder) return a.sortOrder - b.sortOrder;
        return a.name.localeCompare(b.name, 'zh-CN');
      });
    }
    return map;
  }, [folders, sortMode]);

  const toggleExpand = (id: UUID) => {
    setExpandedIDs((prev) => {
      const next = new Set(prev);
      if (next.has(id)) next.delete(id);
      else next.add(id);
      return next;
    });
  };

  const commitRename = async () => {
    if (!renamingID) return;
    const trimmed = renameDraft.trim();
    const id = renamingID;
    setRenamingID(null);
    if (!trimmed) return;
    try {
      await renameFolder(id, trimmed);
    } catch (err) {
      pushToast({ tone: 'error', message: err instanceof Error ? err.message : '重命名失败' });
    }
  };

  const commitSubfolderCreate = async () => {
    const parentID = creatingUnderParentID;
    const trimmed = newSubfolderName.trim();
    setCreatingUnderParentID(null);
    setNewSubfolderName('');
    if (!trimmed || !parentID) return;
    try {
      const created = await createFolder(trimmed, parentID);
      setExpandedIDs((prev) => new Set(prev).add(parentID));
      navigate({ type: 'folder', id: created.id });
    } catch (err) {
      pushToast({ tone: 'error', message: err instanceof Error ? err.message : '创建子文件夹失败' });
    }
  };

  const handleRowDragOver = (e: React.DragEvent, folder: FolderRecord) => {
    e.preventDefault();
    const hasAssets = e.dataTransfer.types.includes('application/x-charkle-assets');
    const hasFiles = e.dataTransfer.types.includes('Files');
    if (hasAssets || hasFiles) {
      e.dataTransfer.dropEffect = hasFiles ? 'copy' : 'move';
      setDropTarget({ folderID: folder.id, position: 'inside' });
      return;
    }
    if (draggedFolderID && draggedFolderID !== folder.id) {
      e.dataTransfer.dropEffect = 'move';
      const rect = (e.currentTarget as HTMLElement).getBoundingClientRect();
      const relY = (e.clientY - rect.top) / Math.max(1, rect.height);
      const position: DropPosition = relY < 0.25 ? 'before' : relY > 0.75 ? 'after' : 'inside';
      setDropTarget({ folderID: folder.id, position });
    }
  };

  const handleRowDrop = async (e: React.DragEvent, targetFolder: FolderRecord, siblingIndex: number) => {
    e.preventDefault();
    e.stopPropagation();
    const currentDrop = dropTarget;
    setDropTarget(null);

    // 1. Asset drag-drop onto folder
    const assetPayload = e.dataTransfer.getData('application/x-charkle-assets');
    if (assetPayload) {
      try {
        const assetIDs = JSON.parse(assetPayload) as UUID[];
        if (assetIDs.length > 0) {
          await batchPatch(
            createDefaultAssetBatchPatch(assetIDs, {
              folderAssignment: { type: 'folder', folderID: targetFolder.id },
            }),
          );
          pushToast({
            tone: 'success',
            message: `已移动 ${assetIDs.length} 项素材到「${targetFolder.name}」`,
          });
        }
      } catch {
        // Ignore invalid payload
      }
      return;
    }

    // 2. External file upload drop onto folder
    if (e.dataTransfer.files && e.dataTransfer.files.length > 0) {
      const files = Array.from(e.dataTransfer.files);
      try {
        const imported = await uploadFiles(files, { targetFolderID: targetFolder.id });
        pushToast({
          tone: 'success',
          message: `已导入 ${imported.length} 项文件至「${targetFolder.name}」`,
        });
      } catch (err) {
        pushToast({ tone: 'error', message: err instanceof Error ? err.message : '导入文件失败' });
      }
      return;
    }

    // 3. Folder drag-to-reorder / nest
    const sourceID = draggedFolderID || e.dataTransfer.getData('application/x-charkle-folder');
    setDraggedFolderID(null);
    if (!sourceID || sourceID === targetFolder.id) return;

    const pos = currentDrop?.position ?? 'inside';
    try {
      if (pos === 'inside') {
        await moveFolder(sourceID, targetFolder.id, null);
        setExpandedIDs((prev) => new Set(prev).add(targetFolder.id));
      } else {
        const insertIdx = pos === 'before' ? siblingIndex : siblingIndex + 1;
        await moveFolder(sourceID, targetFolder.parentID ?? null, insertIdx);
      }
    } catch (err) {
      pushToast({ tone: 'error', message: err instanceof Error ? err.message : '移动文件夹失败' });
    }
  };

  const renderNodes = (parentID: UUID | null, depth: number): React.ReactNode => {
    const list = childrenByParent.get(parentID) ?? [];
    if (list.length === 0) return null;

    return list.map((folder, index) => {
      const children = childrenByParent.get(folder.id) ?? [];
      const hasChildren = children.length > 0 || creatingUnderParentID === folder.id;
      const isExpanded = expandedIDs.has(folder.id);
      const isActive = destination.type === 'folder' && destination.id === folder.id;
      const isRenaming = renamingID === folder.id;
      const isDropBefore = dropTarget?.folderID === folder.id && dropTarget.position === 'before';
      const isDropInside = dropTarget?.folderID === folder.id && dropTarget.position === 'inside';
      const isDropAfter = dropTarget?.folderID === folder.id && dropTarget.position === 'after';

      return (
        <div key={folder.id} className="relative">
          {/* Thin drag-reorder insertion line */}
          {isDropBefore && (
            <div className="absolute left-3 right-3 top-0 h-[2px] rounded-full bg-[var(--accent)] pointer-events-none z-10" />
          )}

          <div
            draggable={!isRenaming}
            onDragStart={(e) => {
              setDraggedFolderID(folder.id);
              e.dataTransfer.setData('application/x-charkle-folder', folder.id);
              e.dataTransfer.effectAllowed = 'move';
            }}
            onDragEnd={() => {
              setDraggedFolderID(null);
              setDropTarget(null);
            }}
            onDragOver={(e) => handleRowDragOver(e, folder)}
            onDragLeave={() => {
              if (dropTarget?.folderID === folder.id) setDropTarget(null);
            }}
            onDrop={(e) => void handleRowDrop(e, folder, index)}
            onContextMenu={(e) => {
              e.preventDefault();
              setMenuState({ folder, anchorPoint: { x: e.clientX, y: e.clientY } });
            }}
            onClick={() => {
              if (!isRenaming) navigate({ type: 'folder', id: folder.id });
            }}
            style={{ paddingLeft: collapsed ? 8 : 8 + depth * 14 }}
            className={[
              'group relative flex items-center gap-1.5 h-8 pr-2 rounded-[var(--radius-chip)] text-[13px] cursor-pointer select-none',
              'transition-[background-color,color,opacity] duration-[var(--duration-press)] ease-[var(--ease-out)]',
              isActive
                ? 'bg-[var(--bg-elevated)] text-[var(--text-primary)] font-medium shadow-[0_1px_2px_rgba(0,0,0,0.05)]'
                : 'text-[var(--text-secondary)] hover:text-[var(--text-primary)] hover:bg-[var(--bg-subtle)]/75',
              isDropInside ? 'ring-2 ring-[var(--accent)] bg-[var(--accent-soft)]' : '',
              draggedFolderID === folder.id ? 'opacity-45' : '',
            ].join(' ')}
            title={collapsed ? `${folder.name} (${folder.assetCount})` : undefined}
          >
            {!collapsed && (
              <button
                type="button"
                onClick={(e) => {
                  e.stopPropagation();
                  if (hasChildren) toggleExpand(folder.id);
                }}
                className={[
                  'h-4 w-4 flex items-center justify-center rounded text-[var(--text-tertiary)] hover:text-[var(--text-primary)] shrink-0',
                  hasChildren ? 'visible cursor-pointer' : 'invisible',
                ].join(' ')}
              >
                <ChevronRight
                  size={12}
                  className="transition-transform duration-[180ms] ease-[var(--ease-out-strong)]"
                  style={{ transform: isExpanded ? 'rotate(90deg)' : 'rotate(0deg)' }}
                />
              </button>
            )}

            <CharkleFolderIcon
              colorHex={folder.colorHex}
              customSymbol={folder.customSymbol}
              size={18}
              isActive={isActive}
            />

            {!collapsed && (
              <>
                {isRenaming ? (
                  <input
                    type="text"
                    autoFocus
                    value={renameDraft}
                    onClick={(e) => e.stopPropagation()}
                    onChange={(e) => setRenameDraft(e.target.value)}
                    onBlur={() => void commitRename()}
                    onKeyDown={(e) => {
                      if (e.key === 'Enter') void commitRename();
                      if (e.key === 'Escape') setRenamingID(null);
                    }}
                    className="flex-1 min-w-0 h-6 px-1.5 text-[12.5px] rounded bg-[var(--bg-elevated)] border border-[var(--accent)] text-[var(--text-primary)] focus:outline-none"
                  />
                ) : (
                  <span className="flex-1 min-w-0 truncate">{folder.name}</span>
                )}

                {!isRenaming && (
                  <div className="flex items-center gap-0.5 shrink-0">
                    <span className="text-[11px] tabular-nums text-[var(--text-tertiary)] group-hover:hidden">
                      {folder.assetCount}
                    </span>
                    <button
                      type="button"
                      aria-label="文件夹菜单"
                      onClick={(e) => {
                        e.stopPropagation();
                        setMenuState({ folder, anchorEl: e.currentTarget });
                      }}
                      className="hidden group-hover:inline-flex h-5 w-5 items-center justify-center rounded text-[var(--text-tertiary)] hover:text-[var(--text-primary)] hover:bg-[var(--border-hairline)] cursor-pointer"
                    >
                      <MoreHorizontal size={13} />
                    </button>
                  </div>
                )}
              </>
            )}
          </div>

          {isDropAfter && (
            <div className="absolute left-3 right-3 bottom-0 h-[2px] rounded-full bg-[var(--accent)] pointer-events-none z-10" />
          )}

          {/* Nested Children + Inline Create Subfolder */}
          {!collapsed && isExpanded && (
            <div>
              {renderNodes(folder.id, depth + 1)}
              {creatingUnderParentID === folder.id && (
                <div
                  style={{ paddingLeft: 22 + (depth + 1) * 14 }}
                  className="flex items-center gap-1.5 h-8 pr-2"
                >
                  <CharkleFolderIcon size={16} />
                  <input
                    type="text"
                    autoFocus
                    placeholder="新子文件夹名称…"
                    value={newSubfolderName}
                    onChange={(e) => setNewSubfolderName(e.target.value)}
                    onBlur={() => void commitSubfolderCreate()}
                    onKeyDown={(e) => {
                      if (e.key === 'Enter') void commitSubfolderCreate();
                      if (e.key === 'Escape') {
                        setCreatingUnderParentID(null);
                        setNewSubfolderName('');
                      }
                    }}
                    className="flex-1 min-w-0 h-6 px-1.5 text-[12.5px] rounded bg-[var(--bg-elevated)] border border-[var(--accent)] text-[var(--text-primary)] focus:outline-none"
                  />
                </div>
              )}
            </div>
          )}
        </div>
      );
    });
  };

  return (
    <>
      <div className="flex flex-col gap-0.5">{renderNodes(null, 0)}</div>

      {/* Folder Context Menu Popover */}
      <Popover
        open={Boolean(menuState)}
        onOpenChange={(open) => {
          if (!open) setMenuState(null);
        }}
        anchorEl={menuState?.anchorEl}
        anchorPoint={menuState?.anchorPoint}
        placement="bottom-start"
      >
        {menuState && (
          <div className="w-[216px] p-1.5 flex flex-col gap-0.5 text-[12.5px]">
            <button
              type="button"
              onClick={() => {
                const target = menuState.folder;
                setMenuState(null);
                setExpandedIDs((prev) => new Set(prev).add(target.id));
                setCreatingUnderParentID(target.id);
                setNewSubfolderName('');
              }}
              className="charkle-pressable flex items-center gap-2 px-2.5 py-1.5 rounded-[var(--radius-popover-inner)] hover:bg-[var(--bg-subtle)] text-[var(--text-primary)] cursor-pointer text-left"
            >
              <FolderPlus size={14} className="text-[var(--text-secondary)]" />
              新建子文件夹
            </button>

            <button
              type="button"
              onClick={() => {
                const target = menuState.folder;
                setMenuState(null);
                setRenamingID(target.id);
                setRenameDraft(target.name);
              }}
              className="charkle-pressable flex items-center gap-2 px-2.5 py-1.5 rounded-[var(--radius-popover-inner)] hover:bg-[var(--bg-subtle)] text-[var(--text-primary)] cursor-pointer text-left"
            >
              <Pencil size={14} className="text-[var(--text-secondary)]" />
              重命名
            </button>

            {/* Quick 7-color dots */}
            <div className="px-2.5 py-1.5 flex items-center justify-between gap-1">
              {MACOS_FOLDER_COLORS.map((c) => (
                <button
                  key={c.hex}
                  type="button"
                  title={c.name}
                  onClick={() => {
                    const target = menuState.folder;
                    setMenuState(null);
                    void updateFolderAppearance(target.id, c.hex, target.customSymbol ?? null);
                  }}
                  className="charkle-pressable h-4.5 w-4.5 rounded-full border border-black/15 cursor-pointer"
                  style={{ backgroundColor: c.hex }}
                />
              ))}
            </div>

            <button
              type="button"
              onClick={() => {
                const state = menuState;
                setMenuState(null);
                setCustomizeState(state);
              }}
              className="charkle-pressable flex items-center gap-2 px-2.5 py-1.5 rounded-[var(--radius-popover-inner)] hover:bg-[var(--bg-subtle)] text-[var(--text-primary)] cursor-pointer text-left"
            >
              <Palette size={14} className="text-[var(--text-secondary)]" />
              自定义图标与颜色…
            </button>

            <button
              type="button"
              onClick={() => {
                const target = menuState.folder;
                setMenuState(null);
                void pinFolderOffline(target.id, true);
              }}
              className="charkle-pressable flex items-center gap-2 px-2.5 py-1.5 rounded-[var(--radius-popover-inner)] hover:bg-[var(--bg-subtle)] text-[var(--text-primary)] cursor-pointer text-left"
            >
              <ArrowDownCircle size={14} className="text-[var(--text-secondary)]" />
              保留离线副本
            </button>

            <div className="h-px my-1 bg-[var(--border-hairline)]" />

            <button
              type="button"
              onClick={() => {
                const target = menuState.folder;
                setMenuState(null);
                setDeleteDialogFolder(target);
              }}
              className="charkle-pressable flex items-center gap-2 px-2.5 py-1.5 rounded-[var(--radius-popover-inner)] hover:bg-[var(--danger-soft)] text-[var(--danger)] cursor-pointer text-left"
            >
              <Trash2 size={14} />
              删除文件夹…
            </button>
          </div>
        )}
      </Popover>

      {/* Folder Customization Popover */}
      <Popover
        open={Boolean(customizeState)}
        onOpenChange={(open) => {
          if (!open) setCustomizeState(null);
        }}
        anchorEl={customizeState?.anchorEl}
        anchorPoint={customizeState?.anchorPoint}
        placement="right-start"
      >
        {customizeState && (
          <FolderCustomizationPopover
            folder={
              folders.find((f) => f.id === customizeState.folder.id) ?? customizeState.folder
            }
            onUpdate={(colorHex, customSymbol) => {
              void updateFolderAppearance(customizeState.folder.id, colorHex, customSymbol);
            }}
          />
        )}
      </Popover>

      {/* Delete Folder Confirmation Modal (matching deleteFolder(trashContents:)) */}
      <ModalShell
        open={Boolean(deleteDialogFolder)}
        onClose={() => setDeleteDialogFolder(null)}
        width="sm"
        title={`删除文件夹「${deleteDialogFolder?.name ?? ''}」`}
        subtitle="请选择如何处理文件夹内的素材"
        footer={
          <Button variant="ghost" onClick={() => setDeleteDialogFolder(null)}>
            取消
          </Button>
        }
      >
        {deleteDialogFolder && (
          <div className="flex flex-col gap-2.5">
            <button
              type="button"
              onClick={async () => {
                const f = deleteDialogFolder;
                setDeleteDialogFolder(null);
                await deleteFolder(f.id, false);
                pushToast({ tone: 'info', message: `已删除「${f.name}」，素材已安全移回收件箱` });
              }}
              className="charkle-pressable flex flex-col items-start gap-0.5 p-3 rounded-[var(--radius-settings-outer)] bg-[var(--bg-subtle)] hover:bg-[var(--border-hairline)] text-left cursor-pointer"
            >
              <span className="text-[13px] font-medium text-[var(--text-primary)]">
                仅删除文件夹（素材移回收件箱）
              </span>
              <span className="text-[12px] text-[var(--text-secondary)]">
                保留文件夹中的所有素材，将其归位至「收件箱」等待重新整理。
              </span>
            </button>

            <button
              type="button"
              onClick={async () => {
                const f = deleteDialogFolder;
                setDeleteDialogFolder(null);
                await deleteFolder(f.id, true);
                pushToast({
                  tone: 'info',
                  message: `已删除「${f.name}」及其子树，相关素材已移入回收站`,
                });
              }}
              className="charkle-pressable flex flex-col items-start gap-0.5 p-3 rounded-[var(--radius-settings-outer)] bg-[var(--danger-soft)] hover:bg-[var(--danger)]/18 text-left cursor-pointer"
            >
              <span className="text-[13px] font-medium text-[var(--danger)]">
                删除文件夹并将其中素材移入回收站
              </span>
              <span className="text-[12px] text-[var(--text-secondary)]">
                同时移除所有子文件夹，并将该子树下的全部素材软删除至回收站。
              </span>
            </button>
          </div>
        )}
      </ModalShell>
    </>
  );
};
