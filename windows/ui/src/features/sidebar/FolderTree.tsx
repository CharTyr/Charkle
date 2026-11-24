import React, { useEffect, useMemo, useRef, useState } from 'react';
import {
  ArrowDownCircle,
  ArrowUpLeft,
  Ban,
  ChevronRight,
  ClipboardPaste,
  CloudOff,
  FolderMinus,
  FolderPlus,
  MoreHorizontal,
  Palette,
  Pencil,
  Plus,
  Trash2,
} from 'lucide-react';
import {
  Button,
  CharkleFolderIcon,
  FOLDER_PRESET_COLORS,
  ModalShell,
  Popover,
} from '../../design-system';
import {
  getFolderSubtreeAssetCount,
  isFolderSubtreePinnedOffline,
  useCoordinatorStore,
  useLibraryStore,
} from '../../stores';
import {
  buildFolderTree,
  flattenFolderTree,
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
          'group relative flex items-center gap-1 pr-1.5 h-[30px] rounded-[var(--radius-chip)] select-none cursor-pointer transition-colors duration-120',
          isDraggingSelf ? 'opacity-40' : '',
          isMultiSelected
            ? 'bg-[var(--accent-soft)] ring-1 ring-[var(--accent-ring)] text-[var(--accent)] font-medium'
            : isDestinationSelected
              ? 'bg-[var(--accent-soft)] text-[var(--accent)] font-medium'
              : 'text-[var(--text-primary)] hover:bg-[var(--bg-subtle)]/80',
          dropZone === 'inside' ? 'ring-2 ring-[var(--accent)] bg-[var(--accent-soft)]' : '',
        ].join(' ')}
        onClick={(e) => {
          if (wasRecentPointerDrag()) return;
          onRowClick(folder, e);
        }}
      >
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
            'w-4 h-4 inline-flex items-center justify-center rounded text-[var(--text-tertiary)] shrink-0',
            children.length > 0
              ? 'hover:text-[var(--text-primary)] cursor-pointer'
              : 'opacity-0 pointer-events-none',
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
            className="flex-1 min-w-0 h-5 px-1.5 rounded bg-[var(--bg-elevated)] border border-[var(--accent)] text-[12.5px] text-[var(--text-primary)] outline-none"
          />
        ) : (
          <span className="truncate flex-1 min-w-0 text-[12.5px] leading-[1.45] py-[1px]">
            {folder.name}
          </span>
        )}

        {!renaming && (
          <>
            {isPinnedOffline && (
              <span title="文件夹素材始终保留在本地" className="text-[var(--text-tertiary)] shrink-0 group-hover:hidden">
                <ArrowDownCircle size={10.5} />
              </span>
            )}
            {liveCount > 0 && (
              <span className="text-[11px] text-[var(--text-tertiary)] charkle-tabular group-hover:hidden">
                {liveCount}
              </span>
            )}
            <div className="hidden group-hover:flex items-center gap-0.5 shrink-0">
              <button
                type="button"
                title={`在「${folder.name}」内新建子文件夹`}
                aria-label={`在 ${folder.name} 内新建子文件夹`}
                onClick={(e) => {
                  e.stopPropagation();
                  startCreateChild();
                }}
                className="h-5 w-5 inline-flex items-center justify-center rounded text-[var(--text-secondary)] hover:bg-[var(--bg-elevated)] hover:text-[var(--text-primary)] cursor-pointer"
              >
                <Plus size={12} />
              </button>
              <button
                ref={moreBtnRef}
                type="button"
                aria-label={`更多操作：${folder.name}`}
                onClick={(e) => {
                  e.stopPropagation();
                  setContextPoint(null);
                  setMenuOpen((v) => !v);
                }}
                className="h-5 w-5 inline-flex items-center justify-center rounded text-[var(--text-secondary)] hover:bg-[var(--bg-elevated)] hover:text-[var(--text-primary)] cursor-pointer"
              >
                <MoreHorizontal size={13} />
              </button>
            </div>
          </>
        )}
      </div>

      {/* Full macOS-parity Folder Action Menu */}
      <Popover
        open={menuOpen}
        onOpenChange={(v) => {
          setMenuOpen(v);
          if (!v) setContextPoint(null);
        }}
        anchorEl={contextPoint ? null : moreBtnRef.current}
        anchorPoint={contextPoint}
        placement="bottom-end"
        className="w-[222px] p-1"
      >
        <div className="flex flex-col gap-0.5 text-[12px]">
          {!isBatch && cutAssetIds.length > 0 && (
            <>
              <button
                type="button"
                onClick={() => {
                  setMenuOpen(false);
                  void pasteCutAssets(folder.id, destination).then((count) =>
                    pushToast({
                      message: `已将 ${count} 项素材移至「${folder.name}」`,
                      tone: 'success',
                    }),
                  );
                }}
                className="charkle-pressable w-full flex items-center gap-2 px-2.5 py-1.5 text-[var(--accent)] font-medium hover:bg-[var(--accent-soft)] rounded-[var(--radius-popover-inner)] cursor-pointer text-left"
              >
                <ClipboardPaste size={13} />
                <span className="truncate">粘贴移动至此（{cutAssetIds.length} 项）</span>
              </button>
              <div className="my-1 h-px bg-[var(--border-hairline)]" />
            </>
          )}

          {!isBatch && (
            <>
              <button
                type="button"
                onClick={() => {
                  setMenuOpen(false);
                  startCreateChild();
                }}
                className="charkle-pressable w-full flex items-center gap-2 px-2.5 py-1.5 text-[var(--text-primary)] hover:bg-[var(--bg-subtle)] rounded-[var(--radius-popover-inner)] cursor-pointer text-left"
              >
                <FolderPlus size={13} className="text-[var(--text-secondary)]" />
                <span>新建子文件夹…</span>
              </button>
              <button
                type="button"
                onClick={() => {
                  setMenuOpen(false);
                  startRename();
                }}
                className="charkle-pressable w-full flex items-center gap-2 px-2.5 py-1.5 text-[var(--text-primary)] hover:bg-[var(--bg-subtle)] rounded-[var(--radius-popover-inner)] cursor-pointer text-left"
              >
                <Pencil size={13} className="text-[var(--text-secondary)]" />
                <span>重命名…</span>
              </button>
            </>
          )}

          {(folder.parentID != null || isBatch) && (
            <button
              type="button"
              onClick={() => {
                setMenuOpen(false);
                void onMoveFolderToRoot(targetFolderIds);
              }}
              className="charkle-pressable w-full flex items-center gap-2 px-2.5 py-1.5 text-[var(--text-primary)] hover:bg-[var(--bg-subtle)] rounded-[var(--radius-popover-inner)] cursor-pointer text-left"
            >
              <ArrowUpLeft size={13} className="text-[var(--text-secondary)]" />
              <span className="truncate">移至顶层目录{batchSuffix}</span>
            </button>
          )}

          <div className="my-1 h-px bg-[var(--border-hairline)]" />

          <button
            type="button"
            onClick={() => {
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
            className="charkle-pressable w-full flex items-center gap-2 px-2.5 py-1.5 text-[var(--text-primary)] hover:bg-[var(--bg-subtle)] rounded-[var(--radius-popover-inner)] cursor-pointer text-left"
          >
            <ArrowDownCircle size={13} className="text-[var(--text-secondary)]" />
            <span className="truncate">始终保留在本地{batchSuffix}</span>
          </button>

          <button
            type="button"
            onClick={() => {
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
            className="charkle-pressable w-full flex items-center gap-2 px-2.5 py-1.5 text-[var(--text-primary)] hover:bg-[var(--bg-subtle)] rounded-[var(--radius-popover-inner)] cursor-pointer text-left"
          >
            <CloudOff size={13} className="text-[var(--text-secondary)]" />
            <span className="truncate">清理离线缓存{batchSuffix}</span>
          </button>

          <div className="my-1 h-px bg-[var(--border-hairline)]" />

          {/* Quick Color Dot Strip (1:1 macOS quick color picker) */}
          <div className="px-2.5 py-1.5 flex flex-col gap-1.5">
            <span className="text-[10.5px] font-medium text-[var(--text-tertiary)]">
              更改文件夹颜色{batchSuffix}
            </span>
            <div className="flex items-center gap-1.5">
              <button
                type="button"
                title="恢复默认颜色"
                onClick={() => {
                  setMenuOpen(false);
                  void onUpdateAppearanceBatch(targetFolderIds, null, undefined);
                }}
                className="charkle-pressable w-[18px] h-[18px] rounded-full bg-[var(--bg-subtle)] border border-[var(--border-hairline)] inline-flex items-center justify-center text-[var(--text-secondary)] cursor-pointer"
              >
                <Ban size={10} />
              </button>
              {FOLDER_PRESET_COLORS.map((preset) => (
                <button
                  key={preset.hex}
                  type="button"
                  title={preset.name}
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

          <button
            type="button"
            onClick={() => {
              setMenuOpen(false);
              setCustomOpen(true);
            }}
            className="charkle-pressable w-full flex items-center gap-2 px-2.5 py-1.5 text-[var(--text-primary)] hover:bg-[var(--bg-subtle)] rounded-[var(--radius-popover-inner)] cursor-pointer text-left"
          >
            <Palette size={13} className="text-[var(--text-secondary)]" />
            <span>自定义文件夹…</span>
          </button>

          <div className="my-1 h-px bg-[var(--border-hairline)]" />

          {/* Dual Folder Delete (1:1 macOS SidebarView.swift) */}
          <button
            type="button"
            onClick={() => {
              setMenuOpen(false);
              void onDeleteFolders(targetFolderIds, false);
            }}
            className="charkle-pressable w-full flex items-center gap-2 px-2.5 py-1.5 text-[var(--text-primary)] hover:bg-[var(--bg-subtle)] rounded-[var(--radius-popover-inner)] cursor-pointer text-left"
          >
            <FolderMinus size={13} className="text-[var(--text-secondary)] shrink-0" />
            <span className="truncate">删除文件夹（素材退回收件箱）</span>
          </button>

          <button
            type="button"
            onClick={() => {
              setMenuOpen(false);
              const targets = targetFolderIds
                .map((id) => allFolders.find((f) => f.id === id))
                .filter((f): f is FolderRecord => Boolean(f));
              onRequestDeleteWithContents(targets);
            }}
            className="charkle-pressable w-full flex items-center gap-2 px-2.5 py-1.5 text-[var(--danger)] hover:bg-[var(--danger-soft)] rounded-[var(--radius-popover-inner)] cursor-pointer text-left"
          >
            <Trash2 size={13} className="shrink-0" />
            <span className="truncate">删除文件夹及其中素材…{batchSuffix}</span>
          </button>
        </div>
      </Popover>

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
            className="w-full h-6 px-2 rounded bg-[var(--bg-elevated)] border border-[var(--accent)] text-[12px] text-[var(--text-primary)] outline-none"
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
  onDropAssets,
}) => {
  const pushToast = useCoordinatorStore((s) => s.pushToast);
  const allAssets = useLibraryStore((s) => s.allAssets);

  const tree = useMemo(() => buildFolderTree(folders), [folders]);
  const flatVisibleIds = useMemo(() => flattenFolderTree(tree).map((n) => n.folder.id), [tree]);

  const [expandedIds, setExpandedIds] = useState<Set<string>>(
    () => new Set(folders.filter((f) => !f.parentID).map((f) => f.id)),
  );
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

  // Register PointerDrag folder reorder/nesting & asset drop handlers
  const foldersRef = useRef(folders);
  foldersRef.current = folders;
  const moveFolderRef = useRef(onMoveFolder);
  moveFolderRef.current = onMoveFolder;
  const dropAssetsRef = useRef(onDropAssets);
  dropAssetsRef.current = onDropAssets;

  useEffect(() => {
    return registerPointerDragHandlers({
      onDropAssetsToFolder: (folderId, assetIds) => {
        void dropAssetsRef.current(folderId, assetIds);
      },
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
      <div className="px-3 py-2 text-[11.5px] text-[var(--text-tertiary)]">
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
            <Button variant="secondary" onClick={() => setPendingDeleteWithContents([])}>
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
        <p className="text-[13px] text-[var(--text-secondary)] leading-relaxed">
          {pendingSubtreeCount > 0
            ? `将删除所选文件夹及其子文件夹，并将里面的 ${pendingSubtreeCount} 项素材一并移至回收站（可在回收站中恢复或彻底删除）。`
            : '将删除所选文件夹及其子文件夹。'}
        </p>
      </ModalShell>
    </>
  );
};
