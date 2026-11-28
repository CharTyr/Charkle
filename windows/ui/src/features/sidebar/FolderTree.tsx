import React, { useEffect, useMemo, useRef, useState } from 'react';
import {
  Add16Regular,
  ArrowDownload16Regular,
  ArrowUpLeft16Regular,
  ChevronRight12Regular,
  ClipboardPaste16Regular,
  CloudOff16Regular,
  Color16Regular,
  Delete16Regular,
  Edit16Regular,
  FolderAdd16Regular,
  FolderProhibited16Regular,
  MoreHorizontal16Regular,
  Prohibited12Regular,
  Sparkle16Regular,
} from '@fluentui/react-icons';
import {
  Button,
  CharkleFolderIcon,
  DropdownMenu,
  FOLDER_PRESET_COLORS,
  MenuItem,
  MenuSeparator,
  ModalShell,
  WIN_SPRING_SNAPPY,
  m,
} from '../../design-system';
import {
  getFolderSubtreeAssetCount,
  isFolderSubtreePinnedOffline,
  useCoordinatorStore,
  useLibraryStore,
} from '../../stores';
import {
  buildFolderTree,
  type FolderRecord,
  type FolderTreeNode,
} from '../../types/domain';
import { useDndStore } from '../dnd/dndStore';
import {
  beginPointerDrag,
  registerPointerDragHandlers,
  wasRecentPointerDrag,
} from '../dnd/PointerDragContext';
import { FolderCustomizationPopover } from './FolderCustomizationPopover';

export const ASSET_DRAG_MIME = 'application/x-charkle-asset-ids';

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
  allFolders: FolderRecord[];
  activeFolderId: string | null;
  selectedFolderIds: Set<string>;
  expandedIds: Set<string>;
  onToggleExpand: (id: string) => void;
  onEnsureExpanded: (id: string) => void;
  onRowClick: (folder: FolderRecord, e: React.MouseEvent) => void;
  onCreateSubfolder: (parentId: string, name: string) => Promise<void>;
  onRenameFolder: (id: string, name: string) => Promise<void>;
  onMoveFolderToRoot: (ids: string[]) => Promise<void>;
  onUpdateAppearanceBatch: (
    ids: string[],
    colorHex: string | null,
    customSymbol?: string | null,
  ) => Promise<void>;
  onDeleteFolders: (ids: string[], trashContents: boolean) => Promise<void>;
  onRequestDeleteWithContents: (targets: FolderRecord[]) => void;
}

const FolderRow: React.FC<FolderRowProps> = ({
  node,
  allFolders,
  activeFolderId,
  selectedFolderIds,
  expandedIds,
  onToggleExpand,
  onEnsureExpanded,
  onRowClick,
  onCreateSubfolder,
  onRenameFolder,
  onMoveFolderToRoot,
  onUpdateAppearanceBatch,
  onDeleteFolders,
  onRequestDeleteWithContents,
}) => {
  const { folder, children, depth, totalAssetCount } = node;
  const isDestinationSelected = activeFolderId === folder.id;
  const isMultiSelected = selectedFolderIds.has(folder.id) && selectedFolderIds.size > 1;
  const active = isDestinationSelected || selectedFolderIds.has(folder.id);
  const expanded = expandedIds.has(folder.id);

  const destination = useCoordinatorStore((s) => s.destination);
  const openDeduplication = useCoordinatorStore((s) => s.openDeduplication);
  const pushToast = useCoordinatorStore((s) => s.pushToast);
  const allAssets = useLibraryStore((s) => s.allAssets);
  const cutAssetIds = useLibraryStore((s) => s.cutAssetIds);
  const pasteCutAssets = useLibraryStore((s) => s.pasteCutAssets);
  const setFoldersPinnedOffline = useLibraryStore((s) => s.setFoldersPinnedOffline);

  const isPinnedOffline = useMemo(
    () => isFolderSubtreePinnedOffline(allAssets, allFolders, folder.id),
    [allAssets, allFolders, folder.id],
  );
  const liveCount = useMemo(() => {
    if (allAssets.length === 0) return totalAssetCount;
    return getFolderSubtreeAssetCount(allAssets, allFolders, folder.id);
  }, [allAssets, allFolders, folder.id, totalAssetCount]);

  const [renaming, setRenaming] = useState(false);
  const [renameDraft, setRenameDraft] = useState(folder.name);
  const [creatingChild, setCreatingChild] = useState(false);
  const [childDraft, setChildDraft] = useState('');
  const [menuOpen, setMenuOpen] = useState(false);
  const [contextPoint, setContextPoint] = useState<{ x: number; y: number } | null>(null);
  const [customOpen, setCustomOpen] = useState(false);

  const moreBtnRef = useRef<HTMLButtonElement | null>(null);
  const rowRef = useRef<HTMLDivElement | null>(null);
  const renameSettledRef = useRef(false);
  const subCreateSettledRef = useRef(false);

  const pointerDrag = useDndStore((s) => s.pointerDrag);
  const pointerTarget = useDndStore((s) => s.pointerTarget);
  const osFileDrop = useDndStore((s) => s.osFileDrop);

  const isDraggingSelf = pointerDrag?.kind === 'folder' && pointerDrag.folderId === folder.id;
  const ptrZone: 'none' | 'before' | 'inside' | 'after' =
    pointerTarget?.kind === 'folder' && pointerTarget.id === folder.id
      ? pointerTarget.zone
      : 'none';
  const osOverThis =
    osFileDrop.active &&
    osFileDrop.target?.kind === 'folder' &&
    osFileDrop.target.id === folder.id;
  const dropZone: 'none' | 'before' | 'inside' | 'after' = osOverThis ? 'inside' : ptrZone;

  const targetFolderIds = useMemo(() => {
    if (selectedFolderIds.has(folder.id) && selectedFolderIds.size > 1) {
      return Array.from(selectedFolderIds);
    }
    return [folder.id];
  }, [selectedFolderIds, folder.id]);
  const isBatch = targetFolderIds.length > 1;
  const batchSuffix = isBatch ? `（已选 ${targetFolderIds.length} 个）` : '';

  // Auto-expand collapsed folder after hovering a drag over it for 450ms
  useEffect(() => {
    if (dropZone !== 'inside' || expanded || children.length === 0) return;
    const timer = window.setTimeout(() => onEnsureExpanded(folder.id), 450);
    return () => window.clearTimeout(timer);
  }, [dropZone, expanded, children.length, folder.id, onEnsureExpanded]);

  const startRename = () => {
    renameSettledRef.current = false;
    setRenameDraft(folder.name);
    setRenaming(true);
  };

  const cancelRename = () => {
    renameSettledRef.current = true;
    setRenaming(false);
    setRenameDraft(folder.name);
  };

  const commitRename = async () => {
    if (renameSettledRef.current) return;
    renameSettledRef.current = true;
    const trimmed = renameDraft.trim();
    setRenaming(false);
    if (trimmed && trimmed !== folder.name) {
      try {
        await onRenameFolder(folder.id, trimmed);
      } catch (err) {
        pushToast({
          message: `重命名失败：${err instanceof Error ? err.message : String(err)}`,
          tone: 'error',
        });
      }
    }
  };

  const startCreateChild = () => {
    subCreateSettledRef.current = false;
    setChildDraft('');
    setCreatingChild(true);
    onEnsureExpanded(folder.id);
  };

  const cancelCreateChild = () => {
    subCreateSettledRef.current = true;
    setCreatingChild(false);
    setChildDraft('');
  };

  const commitSubfolder = async () => {
    if (subCreateSettledRef.current) return;
    subCreateSettledRef.current = true;
    const trimmed = childDraft.trim();
    setCreatingChild(false);
    setChildDraft('');
    if (trimmed) {
      try {
        await onCreateSubfolder(folder.id, trimmed);
        onEnsureExpanded(folder.id);
      } catch (err) {
        pushToast({
          message: `创建子文件夹失败：${err instanceof Error ? err.message : String(err)}`,
          tone: 'error',
        });
      }
    }
  };

  return (
    <div>
      <div
        ref={rowRef}
        data-drop-folder-id={folder.id}
        data-drop-label={folder.name}
        onPointerDown={(e) => {
          if (renaming) return;
          if ((e.target as HTMLElement).closest('button, input')) return;
          beginPointerDrag(e, {
            kind: 'folder',
            folderId: folder.id,
            name: folder.name,
          });
        }}
        onDoubleClick={() => {
          startRename();
        }}
        onContextMenu={(e) => {
          e.preventDefault();
          e.stopPropagation();
          setContextPoint({ x: e.clientX, y: e.clientY });
          setMenuOpen(true);
        }}
        style={{ paddingLeft: 6 + Math.min(depth, 5) * 14 }}
        className={[
          'group relative flex items-center gap-1.5 pr-1.5 h-[34px] rounded-[var(--win-radius-control)] select-none cursor-pointer transition-colors duration-[83ms]',
          isDraggingSelf ? 'opacity-40' : '',
          isMultiSelected
            ? 'bg-[var(--accent-soft)] ring-1 ring-[var(--accent-ring)] text-[var(--accent)] font-medium'
            : isDestinationSelected
              ? 'bg-[var(--win-subtle-active)] text-[var(--text-primary)] font-medium'
              : 'text-[var(--text-primary)] hover:bg-[var(--win-subtle-hover)] active:bg-[var(--win-subtle-active)]',
          dropZone === 'inside' ? 'ring-2 ring-[var(--accent)] bg-[var(--accent-soft)]' : '',
        ].join(' ')}
        onClick={(e) => {
          if (wasRecentPointerDrag()) return;
          onRowClick(folder, e);
        }}
      >
        {isDestinationSelected && !isMultiSelected && (
          <m.span
            layoutId="win-sidebar-indicator"
            transition={WIN_SPRING_SNAPPY}
            aria-hidden="true"
            className="pointer-events-none absolute left-0 inset-y-0 my-auto w-[3px] h-4 rounded-full bg-[var(--accent)]"
          />
        )}

        {dropZone === 'before' && (
          <div className="pointer-events-none absolute top-0 left-2 right-2 h-[2px] rounded-full bg-[var(--accent)] z-10" />
        )}
        {dropZone === 'after' && (
          <div className="pointer-events-none absolute bottom-0 left-2 right-2 h-[2px] rounded-full bg-[var(--accent)] z-10" />
        )}

        <button
          type="button"
          aria-label={expanded ? '收起子文件夹' : '展开子文件夹'}
          onClick={(e) => {
            e.stopPropagation();
            if (children.length > 0) onToggleExpand(folder.id);
          }}
          className={[
            'w-4 h-4 inline-flex items-center justify-center rounded-[var(--win-radius-control)] text-[var(--text-tertiary)] shrink-0',
            children.length > 0
              ? 'hover:text-[var(--text-primary)] cursor-pointer'
              : 'opacity-0 pointer-events-none',
          ].join(' ')}
        >
          <ChevronRight12Regular
            className={`w-3 h-3 transition-transform duration-150 ${expanded ? 'rotate-90' : ''}`}
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
            aria-label="重命名文件夹"
            onClick={(e) => e.stopPropagation()}
            onChange={(e) => setRenameDraft(e.target.value)}
            onBlur={() => void commitRename()}
            onKeyDown={(e) => {
              if (e.nativeEvent.isComposing || e.keyCode === 229) return;
              if (e.key === 'Enter') {
                e.preventDefault();
                e.stopPropagation();
                void commitRename();
              } else if (e.key === 'Escape') {
                e.preventDefault();
                e.stopPropagation();
                cancelRename();
              }
            }}
            className="win-input-elevation flex-1 min-w-0 h-6 px-1.5 rounded-[var(--win-radius-control)] text-[13px] text-[var(--text-primary)] outline-none"
          />
        ) : (
          <span className="truncate flex-1 min-w-0 text-[13px] leading-[18px]">
            {folder.name}
          </span>
        )}

        {!renaming && (
          <>
            {isPinnedOffline && (
              <span
                title="文件夹素材始终保留在本地"
                className={[
                  'text-[var(--text-tertiary)] shrink-0',
                  menuOpen || customOpen ? 'hidden' : 'group-hover:hidden',
                ].join(' ')}
              >
                <ArrowDownload16Regular className="w-3 h-3" />
              </span>
            )}
            {liveCount > 0 && (
              <span
                className={[
                  'text-[11px] text-[var(--text-tertiary)] charkle-tabular pr-1',
                  menuOpen || customOpen ? 'hidden' : 'group-hover:hidden',
                ].join(' ')}
              >
                {liveCount}
              </span>
            )}
            <div
              className={[
                'items-center gap-0.5 shrink-0',
                menuOpen || customOpen ? 'flex' : 'hidden group-hover:flex',
              ].join(' ')}
            >
              <button
                type="button"
                title={`在「${folder.name}」内新建子文件夹`}
                aria-label={`在 ${folder.name} 内新建子文件夹`}
                onClick={(e) => {
                  e.stopPropagation();
                  startCreateChild();
                }}
                className="h-6 w-6 inline-flex items-center justify-center rounded-[var(--win-radius-control)] text-[var(--text-secondary)] hover:bg-[var(--win-subtle-hover)] hover:text-[var(--text-primary)] cursor-pointer"
              >
                <Add16Regular className="w-3.5 h-3.5" />
              </button>
              <button
                ref={moreBtnRef}
                type="button"
                aria-label={`更多操作：${folder.name}`}
                aria-expanded={menuOpen}
                onClick={(e) => {
                  e.stopPropagation();
                  setContextPoint(null);
                  setMenuOpen((v) => !v);
                }}
                className={[
                  'h-6 w-6 inline-flex items-center justify-center rounded-[var(--win-radius-control)] cursor-pointer',
                  menuOpen || customOpen
                    ? 'bg-[var(--win-subtle-active)] text-[var(--text-primary)]'
                    : 'text-[var(--text-secondary)] hover:bg-[var(--win-subtle-hover)] hover:text-[var(--text-primary)]',
                ].join(' ')}
              >
                <MoreHorizontal16Regular className="w-3.5 h-3.5" />
              </button>
            </div>
          </>
        )}
      </div>

      {/* Fluent 2 Folder Action Dropdown/Context Menu */}
      <DropdownMenu
        open={menuOpen}
        onOpenChange={(v) => {
          setMenuOpen(v);
          if (!v) setContextPoint(null);
        }}
        anchorEl={contextPoint ? null : moreBtnRef.current}
        anchorPoint={contextPoint}
        side={contextPoint ? 'bottom' : 'right'}
        align="start"
        className="w-[236px]"
      >
        {!isBatch && cutAssetIds.length > 0 && (
          <>
            <MenuItem
              icon={<ClipboardPaste16Regular className="w-4 h-4 text-[var(--accent)]" />}
              onSelect={() => {
                setMenuOpen(false);
                void pasteCutAssets(folder.id, destination).then((count) =>
                  pushToast({
                    message: `已将 ${count} 项素材移至「${folder.name}」`,
                    tone: 'success',
                  }),
                );
              }}
            >
              粘贴移动至此（{cutAssetIds.length} 项）
            </MenuItem>
            <MenuSeparator />
          </>
        )}

        {!isBatch && (
          <>
            <MenuItem
              icon={<FolderAdd16Regular className="w-4 h-4" />}
              onSelect={() => {
                setMenuOpen(false);
                startCreateChild();
              }}
            >
              新建子文件夹…
            </MenuItem>
            <MenuItem
              icon={<Edit16Regular className="w-4 h-4" />}
              onSelect={() => {
                setMenuOpen(false);
                startRename();
              }}
            >
              重命名…
            </MenuItem>
            <MenuItem
              icon={<Sparkle16Regular className="w-4 h-4" />}
              onSelect={() => {
                setMenuOpen(false);
                openDeduplication({
                  type: 'folder',
                  folderID: folder.id,
                  includeSubfolders: true,
                });
              }}
            >
              在此文件夹中智能去重…
            </MenuItem>
          </>
        )}

        {(folder.parentID != null || isBatch) && (
          <MenuItem
            icon={<ArrowUpLeft16Regular className="w-4 h-4" />}
            onSelect={() => {
              setMenuOpen(false);
              void onMoveFolderToRoot(targetFolderIds);
            }}
          >
            移至顶层目录{batchSuffix}
          </MenuItem>
        )}

        <MenuSeparator />

        <MenuItem
          icon={<ArrowDownload16Regular className="w-4 h-4" />}
          onSelect={() => {
            setMenuOpen(false);
            void setFoldersPinnedOffline(targetFolderIds, true, destination).then((count) =>
              pushToast({
                message:
                  count > 0
                    ? `已将 ${count} 项素材设为始终保留在本地`
                    : '该文件夹暂无素材',
                tone: 'info',
              }),
            );
          }}
        >
          始终保留在本地{batchSuffix}
        </MenuItem>

        <MenuItem
          icon={<CloudOff16Regular className="w-4 h-4" />}
          onSelect={() => {
            setMenuOpen(false);
            void setFoldersPinnedOffline(targetFolderIds, false, destination).then((count) =>
              pushToast({
                message:
                  count > 0
                    ? `已清理 ${count} 项素材的离线缓存锁定`
                    : '该文件夹暂无离线锁定素材',
                tone: 'info',
              }),
            );
          }}
        >
          清理离线缓存{batchSuffix}
        </MenuItem>

        <MenuSeparator />

        {/* Quick Color Dot Strip */}
        <div className="px-2.5 py-1.5 flex flex-col gap-1.5">
          <span className="text-[11px] font-medium text-[var(--text-tertiary)]">
            更改文件夹颜色{batchSuffix}
          </span>
          <div className="flex items-center gap-1.5">
            <button
              type="button"
              title="恢复默认颜色"
              aria-label="恢复默认颜色"
              onClick={() => {
                setMenuOpen(false);
                void onUpdateAppearanceBatch(targetFolderIds, null, undefined);
              }}
              className="charkle-pressable w-[18px] h-[18px] rounded-full bg-[var(--bg-subtle)] border border-[var(--win-stroke-control)] inline-flex items-center justify-center text-[var(--text-secondary)] cursor-pointer"
            >
              <Prohibited12Regular className="w-2.5 h-2.5" />
            </button>
            {FOLDER_PRESET_COLORS.map((preset) => (
              <button
                key={preset.hex}
                type="button"
                title={preset.name}
                aria-label={preset.name}
                onClick={() => {
                  setMenuOpen(false);
                  void onUpdateAppearanceBatch(targetFolderIds, preset.hex, undefined);
                }}
                style={{ backgroundColor: preset.hex }}
                className={[
                  'charkle-pressable w-[18px] h-[18px] rounded-full border border-black/10 cursor-pointer',
                  folder.colorHex?.toUpperCase() === preset.hex.toUpperCase()
                    ? 'ring-2 ring-offset-1 ring-[var(--accent)]'
                    : '',
                ].join(' ')}
              />
            ))}
          </div>
        </div>

        <MenuItem
          icon={<Color16Regular className="w-4 h-4" />}
          onSelect={() => {
            setMenuOpen(false);
            setCustomOpen(true);
          }}
        >
          自定义文件夹…
        </MenuItem>

        <MenuSeparator />

        <MenuItem
          icon={<FolderProhibited16Regular className="w-4 h-4" />}
          onSelect={() => {
            setMenuOpen(false);
            void onDeleteFolders(targetFolderIds, false);
          }}
        >
          删除文件夹（素材退回收件箱）
        </MenuItem>

        <MenuItem
          tone="danger"
          icon={<Delete16Regular className="w-4 h-4" />}
          onSelect={() => {
            setMenuOpen(false);
            const targets = targetFolderIds
              .map((id) => allFolders.find((f) => f.id === id))
              .filter((f): f is FolderRecord => Boolean(f));
            onRequestDeleteWithContents(targets);
          }}
        >
          删除文件夹及其中素材…{batchSuffix}
        </MenuItem>
      </DropdownMenu>

      <FolderCustomizationPopover
        open={customOpen}
        onOpenChange={setCustomOpen}
        anchorEl={moreBtnRef.current ?? rowRef.current}
        folderName={folder.name}
        colorHex={folder.colorHex}
        customSymbol={folder.customSymbol}
        onApply={(hex, sym) => void onUpdateAppearanceBatch(targetFolderIds, hex, sym)}
      />

      {/* Inline subfolder creation input */}
      {creatingChild && (
        <div
          style={{ paddingLeft: 24 + Math.min(depth + 1, 5) * 14 }}
          className="pr-2 py-1"
        >
          <input
            type="text"
            value={childDraft}
            autoFocus
            aria-label="子文件夹名称"
            placeholder="子文件夹名称…"
            onChange={(e) => setChildDraft(e.target.value)}
            onBlur={() => void commitSubfolder()}
            onKeyDown={(e) => {
              if (e.nativeEvent.isComposing || e.keyCode === 229) return;
              if (e.key === 'Enter') {
                e.preventDefault();
                e.stopPropagation();
                void commitSubfolder();
              } else if (e.key === 'Escape') {
                e.preventDefault();
                e.stopPropagation();
                cancelCreateChild();
              }
            }}
            className="win-input-elevation w-full h-7 px-2 rounded-[var(--win-radius-control)] text-[12.5px] text-[var(--text-primary)] outline-none"
          />
        </div>
      )}

      {/* Recursive children */}
      {expanded && children.length > 0 && (
        <div>
          {children.map((child) => (
            <FolderRow
              key={child.folder.id}
              node={child}
              allFolders={allFolders}
              activeFolderId={activeFolderId}
              selectedFolderIds={selectedFolderIds}
              expandedIds={expandedIds}
              onToggleExpand={onToggleExpand}
              onEnsureExpanded={onEnsureExpanded}
              onRowClick={onRowClick}
              onCreateSubfolder={onCreateSubfolder}
              onRenameFolder={onRenameFolder}
              onMoveFolderToRoot={onMoveFolderToRoot}
              onUpdateAppearanceBatch={onUpdateAppearanceBatch}
              onDeleteFolders={onDeleteFolders}
              onRequestDeleteWithContents={onRequestDeleteWithContents}
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
  onDropAssets: _onDropAssets,
}) => {
  const pushToast = useCoordinatorStore((s) => s.pushToast);
  const allAssets = useLibraryStore((s) => s.allAssets);

  const tree = useMemo(() => buildFolderTree(folders), [folders]);

  const [expandedIds, setExpandedIds] = useState<Set<string>>(
    () => new Set(folders.filter((f) => !f.parentID).map((f) => f.id)),
  );
  // Only include visible (not hidden beneath a collapsed ancestor) rows for Shift+click range selection
  const flatVisibleIds = useMemo(() => {
    const out: string[] = [];
    const visit = (nodes: FolderTreeNode[]) => {
      for (const n of nodes) {
        out.push(n.folder.id);
        if (n.children.length > 0 && expandedIds.has(n.folder.id)) {
          visit(n.children);
        }
      }
    };
    visit(tree);
    return out;
  }, [tree, expandedIds]);
  const [selectedFolderIds, setSelectedFolderIds] = useState<Set<string>>(new Set());
  const [lastClickedId, setLastClickedId] = useState<string | null>(null);
  const [pendingDeleteWithContents, setPendingDeleteWithContents] = useState<FolderRecord[]>([]);
  const seededRef = useRef(false);

  // Seed initial expansion once folders arrive
  useEffect(() => {
    if (seededRef.current || folders.length === 0) return;
    seededRef.current = true;
    const parents = new Set(
      folders.map((f) => f.parentID).filter((id): id is string => Boolean(id)),
    );
    if (parents.size > 0) {
      setExpandedIds((prev) => new Set([...prev, ...parents]));
    }
  }, [folders]);

  // Auto-expand ancestors whenever activeFolderId jumps to a nested folder
  useEffect(() => {
    if (!activeFolderId) return;
    const ancestors: string[] = [];
    let cursor = folders.find((f) => f.id === activeFolderId);
    const seen = new Set<string>();
    while (cursor?.parentID && !seen.has(cursor.parentID)) {
      seen.add(cursor.parentID);
      ancestors.push(cursor.parentID);
      cursor = folders.find((f) => f.id === cursor!.parentID);
    }
    if (ancestors.length > 0) {
      setExpandedIds((prev) => {
        const next = new Set(prev);
        for (const id of ancestors) next.add(id);
        return next;
      });
    }
  }, [activeFolderId, folders]);

  const ensureExpanded = (id: string) => {
    setExpandedIds((prev) => {
      if (prev.has(id)) return prev;
      const next = new Set(prev);
      next.add(id);
      return next;
    });
  };

  const handleRowClick = (folder: FolderRecord, e: React.MouseEvent) => {
    if (e.ctrlKey || e.metaKey) {
      setSelectedFolderIds((prev) => {
        const next = new Set(prev);
        if (next.size === 0 && activeFolderId) next.add(activeFolderId);
        if (next.has(folder.id)) next.delete(folder.id);
        else next.add(folder.id);
        return next;
      });
      setLastClickedId(folder.id);
      return;
    }
    if (e.shiftKey && lastClickedId) {
      const a = flatVisibleIds.indexOf(lastClickedId);
      const b = flatVisibleIds.indexOf(folder.id);
      if (a !== -1 && b !== -1) {
        const [start, end] = a < b ? [a, b] : [b, a];
        setSelectedFolderIds((prev) => new Set([...prev, ...flatVisibleIds.slice(start, end + 1)]));
        return;
      }
    }
    setSelectedFolderIds(new Set([folder.id]));
    setLastClickedId(folder.id);
    onSelectFolder(folder.id);
  };

  // Register PointerDrag folder reorder/nesting handler (asset-to-folder drop is hosted in
  // SidebarView so drops also work on the collapsed 64px folder rail when FolderTree unmounts).
  const foldersRef = useRef(folders);
  foldersRef.current = folders;
  const moveFolderRef = useRef(onMoveFolder);
  moveFolderRef.current = onMoveFolder;

  useEffect(() => {
    return registerPointerDragHandlers({
      onMoveFolder: (draggedId, targetId, zone) => {
        const all = foldersRef.current;
        if (zone === 'root' || !targetId) {
          void moveFolderRef.current(draggedId, null, null);
          return;
        }
        if (draggedId === targetId || isDescendant(all, targetId, draggedId)) {
          return;
        }
        const target = all.find((f) => f.id === targetId);
        if (!target) return;

        if (zone === 'inside') {
          void moveFolderRef.current(draggedId, target.id, null);
          ensureExpanded(target.id);
        } else {
          // Filter out draggedId before computing insertion index (zero off-by-one bug)
          const siblingsWithoutDragged = all
            .filter(
              (f) =>
                (f.parentID ?? null) === (target.parentID ?? null) &&
                f.id !== draggedId,
            )
            .sort((a, b) => a.sortOrder - b.sortOrder || a.name.localeCompare(b.name));
          const idx = siblingsWithoutDragged.findIndex((f) => f.id === target.id);
          const insertIdx = zone === 'before' ? Math.max(0, idx) : Math.max(0, idx + 1);
          void moveFolderRef.current(draggedId, target.parentID ?? null, insertIdx);
        }
      },
    });
  }, []);

  const toggleExpand = (id: string) => {
    setExpandedIds((prev) => {
      const next = new Set(prev);
      if (next.has(id)) next.delete(id);
      else next.add(id);
      return next;
    });
  };

  const handleMoveToRoot = async (ids: string[]) => {
    for (const id of ids) {
      await onMoveFolder(id, null, null);
    }
    pushToast({
      message:
        ids.length > 1
          ? `已将 ${ids.length} 个文件夹移至顶层`
          : `已将「${folders.find((f) => f.id === ids[0])?.name ?? '文件夹'}」移至顶层`,
      tone: 'info',
    });
  };

  const handleUpdateAppearanceBatch = async (
    ids: string[],
    colorHex: string | null,
    customSymbol?: string | null,
  ) => {
    for (const id of ids) {
      const resolvedSymbol =
        customSymbol === undefined
          ? (folders.find((f) => f.id === id)?.customSymbol ?? null)
          : customSymbol;
      await onUpdateAppearance(id, colorHex, resolvedSymbol);
    }
  };

  const handleDeleteBatch = async (ids: string[], trashContents: boolean) => {
    // Skip descendants whose ancestor is already being deleted in the same batch
    const topTargets = ids.filter(
      (id) => !ids.some((other) => other !== id && isDescendant(folders, id, other)),
    );
    for (const id of topTargets) {
      await onDeleteFolder(id, trashContents);
    }
    setSelectedFolderIds((prev) => {
      const next = new Set(prev);
      for (const id of ids) next.delete(id);
      return next;
    });
  };

  const pendingSubtreeCount = useMemo(
    () =>
      pendingDeleteWithContents.reduce(
        (sum, f) => sum + getFolderSubtreeAssetCount(allAssets, folders, f.id),
        0,
      ),
    [pendingDeleteWithContents, allAssets, folders],
  );

  if (tree.length === 0) {
    return (
      <div className="px-2.5 py-2 text-[12px] text-[var(--text-tertiary)]">
        暂无文件夹，点击 + 或拖入外部文件夹
      </div>
    );
  }

  return (
    <>
      <div className="flex flex-col gap-0.5">
        {tree.map((node) => (
          <FolderRow
            key={node.folder.id}
            node={node}
            allFolders={folders}
            activeFolderId={activeFolderId}
            selectedFolderIds={selectedFolderIds}
            expandedIds={expandedIds}
            onToggleExpand={toggleExpand}
            onEnsureExpanded={ensureExpanded}
            onRowClick={handleRowClick}
            onCreateSubfolder={onCreateSubfolder}
            onRenameFolder={onRenameFolder}
            onMoveFolderToRoot={handleMoveToRoot}
            onUpdateAppearanceBatch={handleUpdateAppearanceBatch}
            onDeleteFolders={handleDeleteBatch}
            onRequestDeleteWithContents={setPendingDeleteWithContents}
          />
        ))}
      </div>

      {/* Destructive Delete Folder + Contents Confirmation Modal */}
      <ModalShell
        open={pendingDeleteWithContents.length > 0}
        onClose={() => setPendingDeleteWithContents([])}
        title={
          pendingDeleteWithContents.length > 1
            ? `删除所选 ${pendingDeleteWithContents.length} 个文件夹及其中素材？`
            : `删除「${pendingDeleteWithContents[0]?.name ?? ''}」及其中素材？`
        }
        width="sm"
        footer={
          <>
            <Button variant="standard" onClick={() => setPendingDeleteWithContents([])}>
              取消
            </Button>
            <Button
              variant="danger"
              onClick={async () => {
                const targets = pendingDeleteWithContents.map((f) => f.id);
                setPendingDeleteWithContents([]);
                await handleDeleteBatch(targets, true);
              }}
            >
              连同素材一起删除
            </Button>
          </>
        }
      >
        <p className="text-[13px] text-[var(--text-secondary)] leading-relaxed charkle-prose">
          {pendingSubtreeCount > 0
            ? `将删除所选文件夹及其子文件夹，并将里面的 ${pendingSubtreeCount} 项素材一并移至回收站（可在回收站中恢复或彻底删除）。`
            : '将删除所选文件夹及其子文件夹。'}
        </p>
      </ModalShell>
    </>
  );
};
