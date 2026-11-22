import React, { useMemo, useRef, useState } from 'react';
import {
  ArrowDownCircle,
  ArrowUpDown,
  ChevronRight,
  LogOut,
  Pencil,
  Plus,
  Search,
  Settings,
  Sparkles,
  Trash2,
} from 'lucide-react';
import {
  createDefaultAssetBatchPatch,
  isSyncStatusActive,
  syncStatusLocalizedPhaseTitle,
} from '@charkle/shared';
import type { SidebarDestination, SmartFolderRecord, UUID } from '@charkle/shared';
import {
  CharkleBrandMark,
  CharkleIcon,
  Popover,
} from '../../design-system';
import { useAuthStore } from '../../stores/authStore';
import { useCoordinatorStore } from '../../stores/coordinatorStore';
import { useLibraryStore } from '../../stores/libraryStore';
import { useMoodboardStore } from '../../stores/moodboardStore';
import { useSyncAIStore } from '../../stores/syncAIStore';
import { FolderTree } from './FolderTree';
import type { FolderSortMode } from './FolderTree';
import { SmartFolderEditorModal } from './SmartFolderEditorModal';

interface PrimaryNavItem {
  key: string;
  label: string;
  icon: string;
  dest: SidebarDestination;
  count?: number;
  acceptDropInbox?: boolean;
}

export const SidebarView: React.FC = () => {
  const destination = useCoordinatorStore((s) => s.destination);
  const navigate = useCoordinatorStore((s) => s.navigate);
  const openBoard = useCoordinatorStore((s) => s.openBoard);
  const sidebarCollapsed = useCoordinatorStore((s) => s.sidebarCollapsed);
  const toggleSidebar = useCoordinatorStore((s) => s.toggleSidebar);
  const activeBoardID = useCoordinatorStore((s) => s.activeBoardID);
  const setActiveBoardID = useCoordinatorStore((s) => s.setActiveBoardID);
  const setJumpAnywhereOpen = useCoordinatorStore((s) => s.setJumpAnywhereOpen);
  const openSettings = useCoordinatorStore((s) => s.openSettings);
  const openGeneratorModal = useCoordinatorStore((s) => s.openGeneratorModal);
  const pushToast = useCoordinatorStore((s) => s.pushToast);

  const counts = useLibraryStore((s) => s.counts);
  const smartFolders = useLibraryStore((s) => s.smartFolders);
  const tags = useLibraryStore((s) => s.tags);
  const assets = useLibraryStore((s) => s.assets);
  const createFolder = useLibraryStore((s) => s.createFolder);
  const deleteSmartFolder = useLibraryStore((s) => s.deleteSmartFolder);
  const batchPatch = useLibraryStore((s) => s.batchPatch);
  const uploadFiles = useLibraryStore((s) => s.uploadFiles);

  const boards = useMoodboardStore((s) => s.boards);
  const createBoard = useMoodboardStore((s) => s.createBoard);
  const addAssetsToBoard = useMoodboardStore((s) => s.addAssetsToBoard);

  const syncStatus = useSyncAIStore((s) => s.syncStatus);
  const sseConnected = useSyncAIStore((s) => s.sseConnected);

  const user = useAuthStore((s) => s.user);
  const logout = useAuthStore((s) => s.logout);

  const [folderSortMode, setFolderSortMode] = useState<FolderSortMode>('manual');
  const [creatingRootFolder, setCreatingRootFolder] = useState(false);
  const [newRootFolderName, setNewRootFolderName] = useState('');

  const [smartFolderModalOpen, setSmartFolderModalOpen] = useState(false);
  const [editingSmartFolder, setEditingSmartFolder] = useState<SmartFolderRecord | null>(null);

  const [allTagsOpen, setAllTagsOpen] = useState(false);
  const [allTagsSearch, setAllTagsSearch] = useState('');
  const [allTagsSort, setAllTagsSort] = useState<'count' | 'name'>('count');
  const allTagsBtnRef = useRef<HTMLButtonElement | null>(null);

  const [userMenuOpen, setUserMenuOpen] = useState(false);
  const userBtnRef = useRef<HTMLButtonElement | null>(null);

  const [inboxDragOver, setInboxDragOver] = useState(false);
  const [boardDragOverID, setBoardDragOverID] = useState<UUID | null>(null);

  const primaryItems: PrimaryNavItem[] = useMemo(
    () => [
      { key: 'allItems', label: '全部素材', icon: 'library', dest: { type: 'allItems' }, count: counts.total },
      {
        key: 'inbox',
        label: '收件箱',
        icon: 'inbox',
        dest: { type: 'inbox' },
        count: counts.inbox,
        acceptDropInbox: true,
      },
      { key: 'untagged', label: '未打标签', icon: 'untagged', dest: { type: 'untagged' }, count: counts.untagged },
      { key: 'recent', label: '最近使用', icon: 'recent', dest: { type: 'recent' } },
      { key: 'trash', label: '回收站', icon: 'trash', dest: { type: 'trash' }, count: counts.trash },
    ],
    [counts],
  );

  // Kubai 015 Travelling Active Indicator index for primary nav
  const activePrimaryIndex = useMemo(
    () => primaryItems.findIndex((item) => item.dest.type === destination.type),
    [primaryItems, destination.type],
  );

  // Smart Capped Tags (5 recent-frequent + top 10 by count, matching PARITY_SPEC §4.2)
  const visibleTags = useMemo(() => {
    const scoreMap = new Map<string, number>();
    const recentSlice = assets.slice(0, 60);
    const freqMap = new Map<string, number>();
    recentSlice.forEach((asset, idx) => {
      const recencyBonus = Math.max(0, 60 - idx) * 1.5;
      for (const tag of asset.tags) {
        freqMap.set(tag, (freqMap.get(tag) ?? 0) + 1);
        scoreMap.set(tag, Math.max(scoreMap.get(tag) ?? 0, recencyBonus));
      }
    });
    const recentFrequent = Array.from(freqMap.entries())
      .map(([name, freq]) => ({ name, score: (scoreMap.get(name) ?? 0) + freq * 4 }))
      .sort((a, b) => b.score - a.score)
      .slice(0, 5)
      .map((x) => x.name);

    const topTen = [...tags]
      .sort((a, b) => (b.count !== a.count ? b.count - a.count : a.name.localeCompare(b.name, 'zh-CN')))
      .slice(0, 10)
      .map((t) => t.name);

    const tagLookup = new Map(tags.map((t) => [t.name, t]));
    const orderedNames: string[] = [];
    const seen = new Set<string>();
    const pushName = (name: string) => {
      if (!seen.has(name) && tagLookup.has(name)) {
        seen.add(name);
        orderedNames.push(name);
      }
    };
    if (destination.type === 'tag') pushName(destination.name);
    recentFrequent.forEach(pushName);
    topTen.forEach(pushName);
    return orderedNames.map((n) => tagLookup.get(n)!);
  }, [assets, tags, destination]);

  const filteredAllTags = useMemo(() => {
    const q = allTagsSearch.trim().toLowerCase();
    const list = q ? tags.filter((t) => t.name.toLowerCase().includes(q)) : [...tags];
    return list.sort((a, b) =>
      allTagsSort === 'count'
        ? b.count - a.count || a.name.localeCompare(b.name, 'zh-CN')
        : a.name.localeCompare(b.name, 'zh-CN'),
    );
  }, [tags, allTagsSearch, allTagsSort]);

  const handleCreateRootFolder = async () => {
    const trimmed = newRootFolderName.trim();
    setCreatingRootFolder(false);
    setNewRootFolderName('');
    if (!trimmed) return;
    try {
      const folder = await createFolder(trimmed, null);
      navigate({ type: 'folder', id: folder.id });
    } catch (err) {
      pushToast({ tone: 'error', message: err instanceof Error ? err.message : '创建文件夹失败' });
    }
  };

  const handleCreateBlankBoard = async () => {
    try {
      const board = await createBoard(`未命名情绪板 ${boards.length + 1}`);
      openBoard(board.id);
      pushToast({ tone: 'success', message: `已创建情绪板「${board.title}」` });
    } catch (err) {
      pushToast({ tone: 'error', message: err instanceof Error ? err.message : '创建情绪板失败' });
    }
  };

  const handleDropOnInbox = async (e: React.DragEvent) => {
    e.preventDefault();
    setInboxDragOver(false);
    const assetPayload = e.dataTransfer.getData('application/x-charkle-assets');
    if (assetPayload) {
      try {
        const ids = JSON.parse(assetPayload) as UUID[];
        if (ids.length > 0) {
          await batchPatch(
            createDefaultAssetBatchPatch(ids, { folderAssignment: { type: 'inbox' } }),
          );
          pushToast({ tone: 'success', message: `已将 ${ids.length} 项素材移回收件箱` });
        }
      } catch {
        // Ignore
      }
      return;
    }
    if (e.dataTransfer.files?.length) {
      const imported = await uploadFiles(Array.from(e.dataTransfer.files));
      pushToast({ tone: 'success', message: `已导入 ${imported.length} 项素材到收件箱` });
    }
  };

  const handleDropOnBoard = async (e: React.DragEvent, boardID: UUID, boardTitle: string) => {
    e.preventDefault();
    setBoardDragOverID(null);
    const assetPayload = e.dataTransfer.getData('application/x-charkle-assets');
    if (assetPayload) {
      try {
        const ids = JSON.parse(assetPayload) as UUID[];
        if (ids.length > 0) {
          await addAssetsToBoard(boardID, ids);
          pushToast({ tone: 'success', message: `已将 ${ids.length} 项素材加入「${boardTitle}」` });
        }
      } catch {
        // Ignore
      }
      return;
    }
    if (e.dataTransfer.files?.length) {
      const imported = await uploadFiles(Array.from(e.dataTransfer.files), { targetBoardID: boardID });
      pushToast({ tone: 'success', message: `已导入 ${imported.length} 项素材至「${boardTitle}」` });
    }
  };

  const syncing = isSyncStatusActive(syncStatus);
  const syncLabel = syncStatusLocalizedPhaseTitle(syncStatus);

  return (
    <aside
      className={[
        'h-full shrink-0 flex flex-col bg-[var(--bg-sidebar)] border-r border-[var(--border-hairline)]',
        'transition-[width] duration-[240ms] ease-[var(--ease-in-out)] select-none',
        sidebarCollapsed ? 'w-[58px]' : 'w-[240px]',
      ].join(' ')}
    >
      {/* Top Brand + Collapse + Jump */}
      <div className="flex items-center justify-between gap-2 px-3 pt-3 pb-2 shrink-0">
        <button
          type="button"
          onClick={() => navigate({ type: 'allItems' })}
          className="charkle-pressable flex items-center gap-2 min-w-0 cursor-pointer"
          title="Charkle"
        >
          <CharkleBrandMark size={24} />
          {!sidebarCollapsed && (
            <span className="text-[14.5px] font-semibold tracking-[-0.02em] text-[var(--text-primary)] truncate">
              Charkle
            </span>
          )}
        </button>

        <button
          type="button"
          onClick={toggleSidebar}
          title={sidebarCollapsed ? '展开侧边栏 (⌘\\)' : '收起侧边栏 (⌘\\)'}
          className="charkle-pressable h-7 w-7 inline-flex items-center justify-center rounded-[var(--radius-chip)] text-[var(--text-secondary)] hover:text-[var(--text-primary)] hover:bg-[var(--bg-subtle)] cursor-pointer shrink-0"
        >
          <CharkleIcon name="sidebar-toggle" size={16} />
        </button>
      </div>

      {/* Jump Anywhere Button */}
      <div className="px-2.5 pb-2 shrink-0">
        <button
          type="button"
          onClick={() => setJumpAnywhereOpen(true)}
          title="随处跳转 (⌘J)"
          className={[
            'charkle-pressable w-full h-8 flex items-center gap-2 rounded-[var(--radius-chip)] bg-[var(--bg-elevated)]/85 border border-[var(--border-hairline)] text-[12.5px] text-[var(--text-secondary)] hover:text-[var(--text-primary)] cursor-pointer',
            sidebarCollapsed ? 'justify-center px-0' : 'px-2.5 justify-between',
          ].join(' ')}
        >
          <span className="inline-flex items-center gap-1.5 min-w-0">
            <Search size={13} className="shrink-0 text-[var(--text-tertiary)]" />
            {!sidebarCollapsed && <span className="truncate">随处跳转…</span>}
          </span>
          {!sidebarCollapsed && (
            <kbd className="text-[10.5px] font-mono px-1.5 py-0.5 rounded bg-[var(--bg-subtle)] text-[var(--text-tertiary)]">
              ⌘J
            </kbd>
          )}
        </button>
      </div>

      {/* Main Scrollable Navigation */}
      <div className="flex-1 min-h-0 overflow-y-auto charkle-scroll px-2 pb-3 flex flex-col gap-4">
        {/* Section 1: Library Primary Destinations with Kubai 015 Travelling Active Indicator */}
        <div className="relative flex flex-col gap-0.5">
          {activePrimaryIndex >= 0 && (
            <div
              aria-hidden="true"
              className="pointer-events-none absolute left-0 right-0 h-8 rounded-[var(--radius-chip)] bg-[var(--bg-elevated)] shadow-[0_1px_2px_rgba(0,0,0,0.06)] border border-[var(--border-hairline)]/60 transition-transform duration-[220ms] ease-[var(--ease-out-strong)]"
              style={{ transform: `translateY(${activePrimaryIndex * 34}px)` }}
            />
          )}

          {primaryItems.map((item) => {
            const active = destination.type === item.dest.type;
            const isInboxDrop = item.acceptDropInbox && inboxDragOver;
            return (
              <button
                key={item.key}
                type="button"
                onClick={() => navigate(item.dest)}
                onDragOver={
                  item.acceptDropInbox
                    ? (e) => {
                        e.preventDefault();
                        setInboxDragOver(true);
                      }
                    : undefined
                }
                onDragLeave={item.acceptDropInbox ? () => setInboxDragOver(false) : undefined}
                onDrop={item.acceptDropInbox ? (e) => void handleDropOnInbox(e) : undefined}
                title={sidebarCollapsed ? item.label : undefined}
                className={[
                  'charkle-pressable relative z-10 h-8 flex items-center gap-2 rounded-[var(--radius-chip)] text-[13px] cursor-pointer',
                  sidebarCollapsed ? 'justify-center px-0' : 'px-2.5',
                  active
                    ? 'text-[var(--text-primary)] font-medium'
                    : 'text-[var(--text-secondary)] hover:text-[var(--text-primary)] hover:bg-[var(--bg-subtle)]/65',
                  isInboxDrop ? 'ring-2 ring-[var(--accent)] bg-[var(--accent-soft)]' : '',
                ].join(' ')}
              >
                <CharkleIcon name={item.icon} size={18} isActive={active} />
                {!sidebarCollapsed && (
                  <>
                    <span className="flex-1 text-left truncate">{item.label}</span>
                    {typeof item.count === 'number' && item.count > 0 && (
                      <span
                        className={[
                          'text-[11px] tabular-nums px-1.5 py-0.25 rounded-full',
                          item.key === 'inbox'
                            ? 'bg-[var(--accent-soft)] text-[var(--accent)] font-semibold'
                            : 'text-[var(--text-tertiary)]',
                        ].join(' ')}
                      >
                        {item.count}
                      </span>
                    )}
                  </>
                )}
              </button>
            );
          })}
        </div>

        {/* Section 2: Moodboards */}
        <div className="flex flex-col gap-1">
          {!sidebarCollapsed && (
            <div className="flex items-center justify-between px-2 text-[11px] font-semibold uppercase tracking-[0.04em] text-[var(--text-tertiary)]">
              <span>情绪板</span>
              <div className="flex items-center gap-0.5">
                <button
                  type="button"
                  title="AI 智能策展情绪板"
                  onClick={() => openGeneratorModal()}
                  className="charkle-pressable h-5 w-5 inline-flex items-center justify-center rounded hover:bg-[var(--bg-subtle)] text-[var(--accent)] cursor-pointer"
                >
                  <Sparkles size={12} />
                </button>
                <button
                  type="button"
                  title="新建空白情绪板"
                  onClick={() => void handleCreateBlankBoard()}
                  className="charkle-pressable h-5 w-5 inline-flex items-center justify-center rounded hover:bg-[var(--bg-subtle)] text-[var(--text-secondary)] hover:text-[var(--text-primary)] cursor-pointer"
                >
                  <Plus size={13} />
                </button>
              </div>
            </div>
          )}

          <button
            type="button"
            onClick={() => navigate({ type: 'moodboardsHome' })}
            title={sidebarCollapsed ? '全部情绪板' : undefined}
            className={[
              'charkle-pressable h-8 flex items-center gap-2 rounded-[var(--radius-chip)] text-[13px] cursor-pointer',
              sidebarCollapsed ? 'justify-center px-0' : 'px-2.5',
              destination.type === 'moodboardsHome'
                ? 'bg-[var(--bg-elevated)] text-[var(--text-primary)] font-medium shadow-[0_1px_2px_rgba(0,0,0,0.06)]'
                : 'text-[var(--text-secondary)] hover:text-[var(--text-primary)] hover:bg-[var(--bg-subtle)]/75',
            ].join(' ')}
          >
            <CharkleIcon
              name="moodboard"
              size={18}
              isActive={destination.type === 'moodboardsHome'}
            />
            {!sidebarCollapsed && (
              <>
                <span className="flex-1 text-left truncate">全部情绪板</span>
                <span className="text-[11px] tabular-nums text-[var(--text-tertiary)]">
                  {boards.length}
                </span>
              </>
            )}
          </button>

          {!sidebarCollapsed &&
            boards.map((board) => {
              const active = destination.type === 'moodboard' && destination.id === board.id;
              const isTargetActive = activeBoardID === board.id;
              const dragOver = boardDragOverID === board.id;
              return (
                <div
                  key={board.id}
                  onClick={() => openBoard(board.id)}
                  onDragOver={(e) => {
                    e.preventDefault();
                    setBoardDragOverID(board.id);
                  }}
                  onDragLeave={() => {
                    if (boardDragOverID === board.id) setBoardDragOverID(null);
                  }}
                  onDrop={(e) => void handleDropOnBoard(e, board.id, board.title)}
                  className={[
                    'group charkle-pressable h-7.5 flex items-center gap-2 pl-4 pr-2 rounded-[var(--radius-chip)] text-[12.5px] cursor-pointer',
                    active
                      ? 'bg-[var(--bg-elevated)] text-[var(--text-primary)] font-medium shadow-[0_1px_2px_rgba(0,0,0,0.05)]'
                      : 'text-[var(--text-secondary)] hover:text-[var(--text-primary)] hover:bg-[var(--bg-subtle)]/70',
                    dragOver ? 'ring-2 ring-[var(--accent)] bg-[var(--accent-soft)]' : '',
                  ].join(' ')}
                >
                  <button
                    type="button"
                    title={isTargetActive ? '当前默认接收情绪板' : '设为当前活跃接收板'}
                    onClick={(e) => {
                      e.stopPropagation();
                      setActiveBoardID(board.id);
                      pushToast({ tone: 'info', message: `已设「${board.title}」为当前活跃情绪板` });
                    }}
                    className="h-3.5 w-3.5 inline-flex items-center justify-center shrink-0 cursor-pointer"
                  >
                    <span
                      className={[
                        'h-2 w-2 rounded-full transition-colors duration-150',
                        isTargetActive
                          ? 'bg-[var(--success)]'
                          : 'bg-[var(--border-strong)] group-hover:bg-[var(--text-tertiary)]',
                      ].join(' ')}
                    />
                  </button>
                  <span className="flex-1 truncate">{board.title}</span>
                  {board.pinnedOffline && (
                    <ArrowDownCircle size={12} className="text-[var(--accent)] shrink-0" />
                  )}
                  <span className="text-[11px] tabular-nums text-[var(--text-tertiary)]">
                    {board.itemCount}
                  </span>
                </div>
              );
            })}
        </div>

        {/* Section 3: Smart Folders */}
        {!sidebarCollapsed && (
          <div className="flex flex-col gap-1">
            <div className="flex items-center justify-between px-2 text-[11px] font-semibold uppercase tracking-[0.04em] text-[var(--text-tertiary)]">
              <span>智能文件夹</span>
              <button
                type="button"
                title="新建智能文件夹"
                onClick={() => {
                  setEditingSmartFolder(null);
                  setSmartFolderModalOpen(true);
                }}
                className="charkle-pressable h-5 w-5 inline-flex items-center justify-center rounded hover:bg-[var(--bg-subtle)] text-[var(--text-secondary)] hover:text-[var(--text-primary)] cursor-pointer"
              >
                <Plus size={13} />
              </button>
            </div>

            {smartFolders.length === 0 ? (
              <button
                type="button"
                onClick={() => {
                  setEditingSmartFolder(null);
                  setSmartFolderModalOpen(true);
                }}
                className="mx-1 px-2 py-1.5 rounded-[var(--radius-chip)] text-[12px] text-[var(--text-tertiary)] hover:text-[var(--text-secondary)] hover:bg-[var(--bg-subtle)]/60 text-left cursor-pointer"
              >
                + 按规则自动聚合素材
              </button>
            ) : (
              smartFolders.map((sf) => {
                const active = destination.type === 'smartFolder' && destination.id === sf.id;
                return (
                  <div
                    key={sf.id}
                    onClick={() => navigate({ type: 'smartFolder', id: sf.id })}
                    className={[
                      'group h-8 flex items-center gap-2 px-2.5 rounded-[var(--radius-chip)] text-[13px] cursor-pointer',
                      active
                        ? 'bg-[var(--bg-elevated)] text-[var(--text-primary)] font-medium shadow-[0_1px_2px_rgba(0,0,0,0.05)]'
                        : 'text-[var(--text-secondary)] hover:text-[var(--text-primary)] hover:bg-[var(--bg-subtle)]/75',
                    ].join(' ')}
                  >
                    <CharkleIcon
                      name="smart-folder"
                      size={17}
                      isActive={active}
                      tintHex={sf.colorHex ?? null}
                    />
                    <span className="flex-1 truncate">{sf.name}</span>
                    <div className="hidden group-hover:flex items-center gap-0.5 shrink-0">
                      <button
                        type="button"
                        title="编辑规则"
                        onClick={(e) => {
                          e.stopPropagation();
                          setEditingSmartFolder(sf);
                          setSmartFolderModalOpen(true);
                        }}
                        className="h-5 w-5 inline-flex items-center justify-center rounded hover:bg-[var(--border-hairline)] text-[var(--text-tertiary)] hover:text-[var(--text-primary)] cursor-pointer"
                      >
                        <Pencil size={11} />
                      </button>
                      <button
                        type="button"
                        title="删除智能文件夹"
                        onClick={(e) => {
                          e.stopPropagation();
                          void deleteSmartFolder(sf.id);
                        }}
                        className="h-5 w-5 inline-flex items-center justify-center rounded hover:bg-[var(--danger-soft)] text-[var(--text-tertiary)] hover:text-[var(--danger)] cursor-pointer"
                      >
                        <Trash2 size={11} />
                      </button>
                    </div>
                  </div>
                );
              })
            )}
          </div>
        )}

        {/* Section 4: Hierarchical Folders */}
        <div className="flex flex-col gap-1">
          {!sidebarCollapsed && (
            <div className="flex items-center justify-between px-2 text-[11px] font-semibold uppercase tracking-[0.04em] text-[var(--text-tertiary)]">
              <span>文件夹</span>
              <div className="flex items-center gap-0.5">
                <button
                  type="button"
                  title={
                    folderSortMode === 'manual'
                      ? '排序：手动（点击切换名称 A→Z）'
                      : folderSortMode === 'name'
                        ? '排序：名称 A→Z（点击切换数量）'
                        : '排序：素材数量（点击切换手动）'
                  }
                  onClick={() =>
                    setFolderSortMode((m) =>
                      m === 'manual' ? 'name' : m === 'name' ? 'count' : 'manual',
                    )
                  }
                  className="charkle-pressable h-5 w-5 inline-flex items-center justify-center rounded hover:bg-[var(--bg-subtle)] text-[var(--text-secondary)] hover:text-[var(--text-primary)] cursor-pointer"
                >
                  <ArrowUpDown size={11} />
                </button>
                <button
                  type="button"
                  title="新建文件夹"
                  onClick={() => {
                    setCreatingRootFolder(true);
                    setNewRootFolderName('');
                  }}
                  className="charkle-pressable h-5 w-5 inline-flex items-center justify-center rounded hover:bg-[var(--bg-subtle)] text-[var(--text-secondary)] hover:text-[var(--text-primary)] cursor-pointer"
                >
                  <Plus size={13} />
                </button>
              </div>
            </div>
          )}

          <FolderTree sortMode={folderSortMode} collapsed={sidebarCollapsed} />

          {!sidebarCollapsed && creatingRootFolder && (
            <div className="flex items-center gap-1.5 h-8 px-2.5">
              <CharkleIcon name="folder" size={17} />
              <input
                type="text"
                autoFocus
                placeholder="新文件夹名称…"
                value={newRootFolderName}
                onChange={(e) => setNewRootFolderName(e.target.value)}
                onBlur={() => void handleCreateRootFolder()}
                onKeyDown={(e) => {
                  if (e.key === 'Enter') void handleCreateRootFolder();
                  if (e.key === 'Escape') {
                    setCreatingRootFolder(false);
                    setNewRootFolderName('');
                  }
                }}
                className="flex-1 min-w-0 h-6 px-1.5 text-[12.5px] rounded bg-[var(--bg-elevated)] border border-[var(--accent)] text-[var(--text-primary)] focus:outline-none"
              />
            </div>
          )}
        </div>

        {/* Section 5: Smart Capped Tags */}
        {!sidebarCollapsed && tags.length > 0 && (
          <div className="flex flex-col gap-1.5">
            <div className="flex items-center justify-between px-2 text-[11px] font-semibold uppercase tracking-[0.04em] text-[var(--text-tertiary)]">
              <span>标签</span>
              <button
                ref={allTagsBtnRef}
                type="button"
                onClick={() => setAllTagsOpen((v) => !v)}
                className="text-[11px] font-medium normal-case text-[var(--text-secondary)] hover:text-[var(--accent)] inline-flex items-center gap-0.5 cursor-pointer"
              >
                全部 ({tags.length})
                <ChevronRight size={11} />
              </button>
            </div>

            <div className="flex flex-wrap gap-1 px-1.5">
              {visibleTags.map((tag) => {
                const active = destination.type === 'tag' && destination.name === tag.name;
                return (
                  <button
                    key={tag.name}
                    type="button"
                    onClick={() => navigate({ type: 'tag', name: tag.name })}
                    className={[
                      'charkle-pressable inline-flex items-center gap-1 px-2 py-0.5 rounded-[var(--radius-chip)] text-[12px] cursor-pointer max-w-full',
                      active
                        ? 'bg-[var(--accent-soft)] text-[var(--accent)] font-medium'
                        : 'bg-[var(--bg-subtle)]/80 text-[var(--text-secondary)] hover:text-[var(--text-primary)] hover:bg-[var(--bg-subtle)]',
                    ].join(' ')}
                  >
                    <span className="truncate">#{tag.name}</span>
                    <span className="text-[10.5px] opacity-65 tabular-nums">{tag.count}</span>
                  </button>
                );
              })}
            </div>
          </div>
        )}
      </div>

      {/* Bottom Sync Status Pill + Settings + User Menu */}
      <div className="shrink-0 p-2 border-t border-[var(--border-hairline)] flex flex-col gap-1.5">
        <button
          type="button"
          onClick={() => openSettings('cloudSync')}
          title={`存储与同步：${syncLabel}`}
          className={[
            'charkle-pressable h-8 flex items-center gap-2 rounded-[var(--radius-chip)] text-[12px] text-[var(--text-secondary)] hover:text-[var(--text-primary)] hover:bg-[var(--bg-subtle)] cursor-pointer',
            sidebarCollapsed ? 'justify-center px-0' : 'px-2.5',
          ].join(' ')}
        >
          <span
            className={[
              'h-2 w-2 rounded-full shrink-0',
              syncStatus.phase.type === 'error'
                ? 'bg-[var(--danger)]'
                : syncing
                  ? 'bg-[var(--accent)] animate-pulse'
                  : sseConnected
                    ? 'bg-[var(--success)]'
                    : 'bg-[var(--text-tertiary)]',
            ].join(' ')}
          />
          {!sidebarCollapsed && (
            <span className="flex-1 text-left truncate">{syncLabel}</span>
          )}
        </button>

        <div
          className={[
            'flex items-center gap-1',
            sidebarCollapsed ? 'flex-col' : 'justify-between',
          ].join(' ')}
        >
          <button
            ref={userBtnRef}
            type="button"
            onClick={() => setUserMenuOpen((v) => !v)}
            title={user?.displayName || user?.username || '账号'}
            className={[
              'charkle-pressable h-8 flex items-center gap-2 rounded-[var(--radius-chip)] text-[12.5px] text-[var(--text-secondary)] hover:text-[var(--text-primary)] hover:bg-[var(--bg-subtle)] cursor-pointer min-w-0',
              sidebarCollapsed ? 'w-8 justify-center px-0' : 'flex-1 px-2',
            ].join(' ')}
          >
            <span className="h-5.5 w-5.5 rounded-full bg-[var(--accent-soft)] text-[var(--accent)] text-[11px] font-semibold inline-flex items-center justify-center shrink-0">
              {(user?.displayName || user?.username || 'C').slice(0, 1).toUpperCase()}
            </span>
            {!sidebarCollapsed && (
              <span className="truncate font-medium text-[var(--text-primary)]">
                {user?.displayName || user?.username || '管理员'}
              </span>
            )}
          </button>

          <button
            type="button"
            onClick={() => openSettings('accountSecurity')}
            title="设置中心 (⌘,)"
            className="charkle-pressable h-8 w-8 inline-flex items-center justify-center rounded-[var(--radius-chip)] text-[var(--text-secondary)] hover:text-[var(--text-primary)] hover:bg-[var(--bg-subtle)] cursor-pointer shrink-0"
          >
            <Settings size={16} />
          </button>
        </div>
      </div>

      {/* All Tags Popover */}
      <Popover
        open={allTagsOpen}
        onOpenChange={setAllTagsOpen}
        anchorEl={allTagsBtnRef.current}
        placement="right-start"
      >
        <div className="w-[260px] p-3 flex flex-col gap-2.5">
          <div className="flex items-center gap-1.5">
            <input
              type="text"
              autoFocus
              value={allTagsSearch}
              onChange={(e) => setAllTagsSearch(e.target.value)}
              placeholder="筛选标签…"
              className="flex-1 h-7.5 px-2.5 text-[12.5px] rounded-[var(--radius-chip)] bg-[var(--bg-elevated)] border border-[var(--border-hairline)] text-[var(--text-primary)] focus:outline-none focus:border-[var(--accent)]"
            />
            <button
              type="button"
              onClick={() => setAllTagsSort((s) => (s === 'count' ? 'name' : 'count'))}
              className="charkle-pressable h-7.5 px-2 text-[11.5px] rounded-[var(--radius-chip)] bg-[var(--bg-subtle)] text-[var(--text-secondary)] cursor-pointer"
            >
              {allTagsSort === 'count' ? '按热度' : 'A→Z'}
            </button>
          </div>
          <div className="max-h-[260px] overflow-y-auto charkle-scroll flex flex-col gap-0.5">
            {filteredAllTags.map((tag) => (
              <button
                key={tag.name}
                type="button"
                onClick={() => {
                  navigate({ type: 'tag', name: tag.name });
                  setAllTagsOpen(false);
                }}
                className="charkle-pressable flex items-center justify-between px-2 py-1.5 rounded-[var(--radius-chip)] text-[12.5px] text-[var(--text-primary)] hover:bg-[var(--bg-subtle)] cursor-pointer"
              >
                <span className="truncate">#{tag.name}</span>
                <span className="text-[11px] tabular-nums text-[var(--text-tertiary)]">
                  {tag.count}
                </span>
              </button>
            ))}
          </div>
        </div>
      </Popover>

      {/* User Account Popover */}
      <Popover
        open={userMenuOpen}
        onOpenChange={setUserMenuOpen}
        anchorEl={userBtnRef.current}
        placement="top-start"
      >
        <div className="w-[200px] p-1.5 flex flex-col gap-0.5 text-[12.5px]">
          <div className="px-2.5 py-1.5 border-b border-[var(--border-hairline)] mb-1">
            <div className="font-semibold text-[var(--text-primary)] truncate">
              {user?.displayName || user?.username}
            </div>
            <div className="text-[11px] text-[var(--text-tertiary)] truncate">
              @{user?.username}
            </div>
          </div>
          <button
            type="button"
            onClick={() => {
              setUserMenuOpen(false);
              openSettings('accountSecurity');
            }}
            className="charkle-pressable flex items-center gap-2 px-2.5 py-1.5 rounded-[var(--radius-popover-inner)] hover:bg-[var(--bg-subtle)] text-[var(--text-primary)] cursor-pointer"
          >
            <Settings size={14} className="text-[var(--text-secondary)]" />
            账号与安全设置
          </button>
          <button
            type="button"
            onClick={() => {
              setUserMenuOpen(false);
              void logout();
            }}
            className="charkle-pressable flex items-center gap-2 px-2.5 py-1.5 rounded-[var(--radius-popover-inner)] hover:bg-[var(--danger-soft)] text-[var(--danger)] cursor-pointer"
          >
            <LogOut size={14} />
            退出登录
          </button>
        </div>
      </Popover>

      {/* Smart Folder Editor Modal */}
      <SmartFolderEditorModal
        open={smartFolderModalOpen}
        editingFolder={editingSmartFolder}
        onClose={() => setSmartFolderModalOpen(false)}
      />
    </aside>
  );
};
