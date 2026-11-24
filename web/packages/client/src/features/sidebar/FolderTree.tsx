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
  prefersReducedMotion,
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

const ROW_RIPPLE_AMPLITUDE_PX = 6;
const ROW_RIPPLE_DECAY = 0.7;
const ROW_RIPPLE_STAGGER_MS = 24;

export const FolderTree: React.FC<FolderTreeProps> = ({ sortMode, collapsed }) => {
  const folders = useLibraryStore((s) => s.folders);
  const createFolder = useLibraryStore((s) => s.createFolder);
  const renameFolder = useLibraryStore((s) => s.renameFolder);
  const moveFolder = useLibraryStore((s) => s.moveFolder);
  const updateFolderAppearance = useLibraryStore((s) => s.updateFolderAppearance);
  const deleteFolder = useLibraryStore((s) => s.deleteFolder);
  const pinFolderOffline = useLibraryStore((s) => s.pinFolderOffline);
  const pinnedFolderIDs = useLibraryStore((s) => s.pinnedFolderIDs);
  const assetsByID = useLibraryStore((s) => s.assetsByID);
  const batchPatch = useLibraryStore((s) => s.batchPatch);
  const uploadFiles = useLibraryStore((s) => s.uploadFiles);

  const destination = useCoordinatorStore((s) => s.destination);
  const navigate = useCoordinatorStore((s) => s.navigate);
  const pushToast = useCoordinatorStore((s) => s.pushToast);
  const expandedSidebarFolderIDs = useCoordinatorStore((s) => s.expandedSidebarFolderIDs);
  const toggleSidebarFolderExpanded = useCoordinatorStore((s) => s.toggleSidebarFolderExpanded);
  const setSidebarFolderExpanded = useCoordinatorStore((s) => s.setSidebarFolderExpanded);

  const expandedIDs = useMemo(
    () => new Set<UUID>(expandedSidebarFolderIDs),
    [expandedSidebarFolderIDs],
  );
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

  const rawChildrenByParent = useMemo(() => {
    const map = new Map<UUID | null, FolderRecord[]>();
    for (const folder of folders) {
      const key = folder.parentID ?? null;
      const list = map.get(key) ?? [];
      list.push(folder);
      map.set(key, list);
    }
    return map;
  }, [folders]);

  // Recursive subtree asset counts & offline pin state matching macOS SidebarView
  const { subtreeCountByID, folderPinStateByID } = useMemo(() => {
    const countCache = new Map<UUID, number>();
    const subtreeIDsCache = new Map<UUID, UUID[]>();

    const collectSubtree = (id: UUID, stack: Set<UUID>): { count: number; ids: UUID[] } => {
      const cachedCount = countCache.get(id);
      const cachedIDs = subtreeIDsCache.get(id);
      if (cachedCount !== undefined && cachedIDs !== undefined) {
        return { count: cachedCount, ids: cachedIDs };
      }
      if (stack.has(id)) return { count: 0, ids: [] };
      stack.add(id);
      const node = folders.find((f) => f.id === id);
      let sum = node?.assetCount ?? 0;
      const ids: UUID[] = [id];
      const children = rawChildrenByParent.get(id) ?? [];
      for (const child of children) {
        const res = collectSubtree(child.id, stack);
        sum += res.count;
        ids.push(...res.ids);
      }
      stack.delete(id);
      countCache.set(id, sum);
      subtreeIDsCache.set(id, ids);
      return { count: sum, ids };
    };

    const stack = new Set<UUID>();
    for (const folder of folders) {
      collectSubtree(folder.id, stack);
    }

    // Aggregate loaded non-trashed assets per folder ID
    const loadedStatsByFolder = new Map<UUID, { total: number; pinned: number }>();
    for (const asset of Object.values(assetsByID)) {
      if (asset.isTrashed || !asset.folderID) continue;
      const entry = loadedStatsByFolder.get(asset.folderID) ?? { total: 0, pinned: 0 };
      entry.total += 1;
      if (asset.pinnedOffline) entry.pinned += 1;
      loadedStatsByFolder.set(asset.folderID, entry);
    }

    const persistedPinned = new Set(pinnedFolderIDs);
    const pinMap = new Map<UUID, { allPinned: boolean; anyPinned: boolean }>();
    for (const folder of folders) {
      const ids = subtreeIDsCache.get(folder.id) ?? [folder.id];
      let loadedTotal = 0;
      let loadedPinned = 0;
      for (const fid of ids) {
        const stat = loadedStatsByFolder.get(fid);
        if (stat) {
          loadedTotal += stat.total;
          loadedPinned += stat.pinned;
        }
      }
      if (loadedTotal > 0) {
        pinMap.set(folder.id, {
          allPinned: loadedPinned === loadedTotal,
          anyPinned: loadedPinned > 0,
        });
      } else {
        const isPersisted = persistedPinned.has(folder.id);
        pinMap.set(folder.id, { allPinned: isPersisted, anyPinned: isPersisted });
      }
    }

    return { subtreeCountByID: countCache, folderPinStateByID: pinMap };
  }, [folders, rawChildrenByParent, assetsByID, pinnedFolderIDs]);

  const childrenByParent = useMemo(() => {
    const map = new Map<UUID | null, FolderRecord[]>();
    for (const [key, list] of rawChildrenByParent) {
      const sorted = [...list].sort((a, b) => {
        if (sortMode === 'name') return a.name.localeCompare(b.name, 'zh-CN');
        if (sortMode === 'count') {
          const countA = subtreeCountByID.get(a.id) ?? a.assetCount;
          const countB = subtreeCountByID.get(b.id) ?? b.assetCount;
          if (countB !== countA) return countB - countA;
          return a.name.localeCompare(b.name, 'zh-CN');
        }
        if (a.sortOrder !== b.sortOrder) return a.sortOrder - b.sortOrder;
        return a.name.localeCompare(b.name, 'zh-CN');
      });
      map.set(key, sorted);
    }
    return map;
  }, [rawChildrenByParent, sortMode, subtreeCountByID]);

  const toggleExpand = (id: UUID) => {
    toggleSidebarFolderExpanded(id);
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
      setSidebarFolderExpanded(parentID, true);
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
      const position: DropPosition = relY < 0.28 ? 'before' : relY > 0.72 ? 'after' : 'inside';
      setDropTarget({ folderID: folder.id, position });
    }
  };

  const handleRowDrop = async (
    e: React.DragEvent,
    targetFolder: FolderRecord,
    siblingIndex: number,
  ) => {
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
        setSidebarFolderExpanded(targetFolder.id, true);
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

    // Determine active insertion gap among this sibling list for neighbor displacement ripple
    let activeGapIndex: number | null = null;
    const draggedIndexInList = draggedFolderID
      ? list.findIndex((f) => f.id === draggedFolderID)
      : -1;
    if (draggedFolderID && dropTarget && dropTarget.position !== 'inside') {
      const targetIndex = list.findIndex((f) => f.id === dropTarget.folderID);
      if (targetIndex >= 0) {
        const candidateGap = dropTarget.position === 'before' ? targetIndex : targetIndex + 1;
        // No insertion line over the dragged item's own slot
        if (
          draggedIndexInList < 0 ||
          (candidateGap !== draggedIndexInList && candidateGap !== draggedIndexInList + 1)
        ) {
          activeGapIndex = candidateGap;
        }
      }
    }
    const reduced = prefersReducedMotion();

    return list.map((folder, index) => {
      const children = childrenByParent.get(folder.id) ?? [];
      const hasChildren = children.length > 0 || creatingUnderParentID === folder.id;
      const isExpanded = expandedIDs.has(folder.id);
      const isActive = destination.type === 'folder' && destination.id === folder.id;
      const isRenaming = renamingID === folder.id;
      const isDropInside = dropTarget?.folderID === folder.id && dropTarget.position === 'inside';
      const showLineBefore = activeGapIndex === index;
      const showLineAfter = activeGapIndex === index + 1 && index === list.length - 1;
      const totalCount = subtreeCountByID.get(folder.id) ?? folder.assetCount;

      // Neighbor ripple offset: A * 0.7^n with 24ms * n stagger
      let rippleTransform: string | undefined;
      let rippleDelayMs = 0;
      if (!reduced && activeGapIndex !== null && draggedFolderID !== folder.id) {
        const n = index < activeGapIndex ? activeGapIndex - 1 - index : index - activeGapIndex;
        const sign = index < activeGapIndex ? -1 : 1;
        const offsetPx = Number(
          (sign * ROW_RIPPLE_AMPLITUDE_PX * Math.pow(ROW_RIPPLE_DECAY, n)).toFixed(2),
        );
        if (Math.abs(offsetPx) >= 0.35) {
          rippleTransform = `translate3d(0, ${offsetPx}px, 0)`;
          rippleDelayMs = n * ROW_RIPPLE_STAGGER_MS;
        }
      }

      return (
        <div key={folder.id} className="relative">
          {showLineBefore && (
            <div className="charkle-drop-line absolute left-3 right-3 -top-[1px] pointer-events-none z-20" />
          )}

          <div
            data-sidebar-active={isActive ? 'true' : undefined}
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
            style={{
              paddingLeft: collapsed ? 0 : 8 + depth * 14,
              transform: rippleTransform,
              transitionDelay: rippleTransform ? `${rippleDelayMs}ms` : '0ms',
            }}
            className={[
              'group charkle-drag-ripple-item relative z-10 flex items-center gap-1.5 h-8 rounded-[var(--radius-chip)] text-[13px] select-none',
              collapsed ? 'justify-center px-0' : 'pr-2',
              draggedFolderID ? 'cursor-grabbing' : 'cursor-pointer',
              'transition-[background-color,color,opacity,transform] duration-[var(--duration-press)] ease-[var(--ease-out)]',
              isActive
                ? 'text-[var(--text-primary)] font-medium'
                : 'text-[var(--text-secondary)] hover:text-[var(--text-primary)] hover:bg-[var(--bg-subtle)]/75',
              isDropInside ? 'ring-2 ring-[var(--accent)] bg-[var(--accent-soft)]' : '',
              draggedFolderID === folder.id ? 'opacity-45 scale-[0.94]' : '',
            ].join(' ')}
            title={collapsed ? `${folder.name} (${totalCount})` : undefined}
          >
            {!collapsed && (
              <button
                type="button"
                aria-label={isExpanded ? '收起子文件夹' : '展开子文件夹'}
                aria-expanded={hasChildren ? isExpanded : undefined}
                onClick={(e) => {
                  e.stopPropagation();
                  if (hasChildren) toggleExpand(folder.id);
                }}
                className={[
                  'w-[22px] h-[28px] -ml-1 flex items-center justify-center rounded-[5px] text-[var(--text-tertiary)] hover:text-[var(--text-primary)] hover:bg-black/[0.04] dark:hover:bg-white/[0.06] shrink-0',
                  hasChildren ? 'visible cursor-pointer' : 'invisible pointer-events-none',
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
                  <div className="flex items-center gap-1 shrink-0">
                    {folderPinStateByID.get(folder.id)?.allPinned && (
                      <span title="已保留离线副本" className="inline-flex items-center group-hover:hidden">
                        <ArrowDownCircle size={11.5} className="text-[var(--accent)]" />
                      </span>
                    )}
                    <span className="text-[11px] tabular-nums text-[var(--text-tertiary)] group-hover:hidden">
                      {totalCount}
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

          {showLineAfter && (
            <div className="charkle-drop-line absolute left-3 right-3 -bottom-[1px] pointer-events-none z-20" />
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
                setSidebarFolderExpanded(target.id, true);
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

            {(() => {
              const target =
                folders.find((f) => f.id === menuState.folder.id) ?? menuState.folder;
              const pinState = folderPinStateByID.get(target.id) ?? {
                allPinned: false,
                anyPinned: false,
              };
              return (
                <>
                  <button
                    type="button"
                    onClick={() => {
                      setMenuState(null);
                      void pinFolderOffline(target.id, !pinState.allPinned);
                    }}
                    className="charkle-pressable flex items-center gap-2 px-2.5 py-1.5 rounded-[var(--radius-popover-inner)] hover:bg-[var(--bg-subtle)] text-[var(--text-primary)] cursor-pointer text-left"
                  >
                    <ArrowDownCircle
                      size={14}
                      className={
                        pinState.allPinned
                          ? 'text-[var(--accent)]'
                          : 'text-[var(--text-secondary)]'
                      }
                    />
                    {pinState.allPinned ? '取消保留在本地' : '始终保留在本地'}
                  </button>
                  {!pinState.allPinned && pinState.anyPinned && (
                    <button
                      type="button"
                      onClick={() => {
                        setMenuState(null);
                        void pinFolderOffline(target.id, false);
                      }}
                      className="charkle-pressable flex items-center gap-2 px-2.5 py-1.5 rounded-[var(--radius-popover-inner)] hover:bg-[var(--bg-subtle)] text-[var(--text-primary)] cursor-pointer text-left"
                    >
                      <ArrowDownCircle size={14} className="text-[var(--text-secondary)]" />
                      取消保留在本地
                    </button>
                  )}
                </>
              );
            })()}

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

      {/* Delete Folder Confirmation Modal */}
      <ModalShell
        open={Boolean(deleteDialogFolder)}
        onClose={() => setDeleteDialogFolder(null)}
        width="sm"
        title={`删除文件夹「${deleteDialogFolder?.name ?? ''}」`}
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
                pushToast({ tone: 'info', message: `已删除「${f.name}」，素材已移回收件箱` });
              }}
              className="charkle-pressable flex flex-col items-start gap-0.5 p-3 rounded-[var(--radius-settings-outer)] bg-[var(--bg-subtle)] hover:bg-[var(--border-hairline)] text-left cursor-pointer"
            >
              <span className="text-[13px] font-medium text-[var(--text-primary)]">
                仅删除文件夹（素材移回收件箱）
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
                  message: `已删除「${f.name}」及子文件夹，素材已移入回收站`,
                });
              }}
              className="charkle-pressable flex flex-col items-start gap-0.5 p-3 rounded-[var(--radius-settings-outer)] bg-[var(--danger-soft)] hover:bg-[var(--danger)]/18 text-left cursor-pointer"
            >
              <span className="text-[13px] font-medium text-[var(--danger)]">
                删除文件夹并将其中素材移入回收站
              </span>
              <span className="text-[12px] text-[var(--text-secondary)]">
                同时删除子文件夹，并将素材移入回收站
              </span>
            </button>
          </div>
        )}
      </ModalShell>
    </>
  );
};
