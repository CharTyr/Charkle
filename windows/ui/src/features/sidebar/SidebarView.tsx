import React, { useEffect, useMemo, useRef, useState } from 'react';
import {
  Add16Regular,
  Add20Regular,
  ArrowSort16Regular,
  ArrowSync16Regular,
  ChevronDown12Regular,
  ClipboardPaste16Regular,
  CloudSync16Regular,
  Delete16Regular,
  Dismiss12Regular,
  Edit16Regular,
  FolderOpen16Regular,
  MoreHorizontal16Regular,
  Options16Regular,
  PanelLeftContract20Regular,
  PanelLeftExpand20Regular,
  Pin12Regular,
  Search16Regular,
  Search20Regular,
  Sparkle16Regular,
} from '@fluentui/react-icons';
import { getTransport } from '../../api/transport';
import {
  Button,
  CharkleBrandMark,
  CharkleFolderIcon,
  CharkleIcon,
  ContextMenu,
  DropdownMenu,
  LayoutGroup,
  MenuItem,
  MenuSeparator,
  Popconfirm,
  Popover,
  Tooltip,
  WIN_SPRING_SNAPPY,
  m,
} from '../../design-system';
import {
  getRecentFrequentSidebarTags,
  getSmartFolderMatchCount,
  getTopTenSidebarTags,
  moveAssetsToFolderWithUndo,
  useCoordinatorStore,
  useLibraryStore,
  useMoodboardStore,
  useSyncAIStore,
} from '../../stores';
import {
  wireDateToMs,
  type DriveTransportMode,
  type SidebarDestination,
  type SmartFolderRecord,
  type SyncStatus,
} from '../../types/domain';
import { useDndStore } from '../dnd/dndStore';
import { registerPointerDragHandlers } from '../dnd/PointerDragContext';
import { runMaterialPackageImport } from '../import/materialPackageImport';
import { FolderTree } from './FolderTree';
import { SmartFolderEditorModal } from './SmartFolderEditorModal';

function isDestEqual(a: SidebarDestination, b: SidebarDestination): boolean {
  if (a.type !== b.type) return false;
  if ('id' in a && 'id' in b) return a.id === b.id;
  if ('name' in a && 'name' in b) return a.name === b.name;
  return true;
}

function formatRelativeSyncTime(value: SyncStatus['lastSyncedAt']): string {
  const ms = wireDateToMs(value);
  if (!ms) return '尚未同步';
  const elapsedSec = Math.max(0, Math.floor((Date.now() - ms) / 1000));
  if (elapsedSec < 15) return '刚刚';
  if (elapsedSec < 60) return `${elapsedSec} 秒前`;
  if (elapsedSec < 3600) return `${Math.floor(elapsedSec / 60)} 分钟前`;
  if (elapsedSec < 86400) return `${Math.floor(elapsedSec / 3600)} 小时前`;
  const d = new Date(ms);
  const mm = String(d.getMonth() + 1).padStart(2, '0');
  const dd = String(d.getDate()).padStart(2, '0');
  const hh = String(d.getHours()).padStart(2, '0');
  const mi = String(d.getMinutes()).padStart(2, '0');
  return `${mm}-${dd} ${hh}:${mi}`;
}

function syncModeLabel(mode: DriveTransportMode | undefined): string {
  switch (mode) {
    case 'directAPIWithGDirect':
      return 'Google Drive';
    case 'iCloudDrive':
      return 'iCloud Drive';
    case 'webDAV':
      return 'WebDAV';
    case 'gdirectMount':
      return 'Drive 挂载';
    default:
      return '本地保存';
  }
}

function syncPhaseLabel(
  status: SyncStatus | null,
  syncing: boolean,
  mode?: DriveTransportMode,
): string {
  const resolvedMode = mode ?? status?.activeMode ?? 'localOnly';
  const enabledBackendCount =
    status?.backendStatuses?.filter((b) => b.isEnabled).length ?? 0;
  if (!status) {
    if (syncing) return '同步中…';
    return resolvedMode === 'localOnly'
      ? '本地保存'
      : `${syncModeLabel(resolvedMode)} · 已同步`;
  }
  const pctSuffix =
    status.progressFraction != null ? ` ${Math.round(status.progressFraction * 100)}%` : '';
  if (status.phase === 'scanning') return `扫描中${pctSuffix}`;
  if (status.phase === 'merging') return `整理中${pctSuffix}`;
  if (typeof status.phase === 'object') {
    if ('uploading' in status.phase) {
      const { completed, total } = status.phase.uploading;
      return total > 0 ? `上传 ${completed}/${total}` : `上传中${pctSuffix}`;
    }
    if ('downloading' in status.phase) {
      const { completed, total } = status.phase.downloading;
      return total > 0 ? `拉取 ${completed}/${total}` : `拉取中${pctSuffix}`;
    }
    if ('error' in status.phase) return '同步异常';
  }
  if (syncing) return '同步中…';
  const base =
    enabledBackendCount > 1
      ? `多后端同步（${enabledBackendCount}）`
      : syncModeLabel(resolvedMode);
  if (enabledBackendCount <= 1 && resolvedMode === 'localOnly') return base;
  return status.pendingOpCount > 0 ? `${base} · 待传 ${status.pendingOpCount}` : `${base} · 已同步`;
}

const SidebarSelectionIndicator: React.FC = () => (
  <m.span
    layoutId="win-sidebar-indicator"
    transition={WIN_SPRING_SNAPPY}
    aria-hidden="true"
    className="pointer-events-none absolute left-0 inset-y-0 my-auto w-[3px] h-4 rounded-full bg-[var(--accent)]"
  />
);

const NavRow: React.FC<{
  iconName: string;
  label: string;
  active: boolean;
  badge?: number | string | null;
  highlightBadge?: boolean;
  isActiveMoodboard?: boolean;
  isPinnedOffline?: boolean;
  dotColorHex?: string | null;
  dropHighlight?: boolean;
  dataAttrs?: Record<string, string>;
  onClick: () => void;
  onContextMenu?: (e: React.MouseEvent) => void;
}> = ({
  iconName,
  label,
  active,
  badge,
  highlightBadge = false,
  isActiveMoodboard = false,
  isPinnedOffline = false,
  dotColorHex = null,
  dropHighlight = false,
  dataAttrs,
  onClick,
  onContextMenu,
}) => (
  <button
    type="button"
    onClick={onClick}
    onContextMenu={onContextMenu}
    {...dataAttrs}
    className={[
      'charkle-pressable relative w-full flex items-center gap-2.5 px-2.5 h-[34px] rounded-[var(--win-radius-control)] text-[13px] leading-[18px] cursor-pointer text-left',
      'focus-visible:outline-2 focus-visible:outline-offset-1 focus-visible:outline-[var(--accent)]',
      active
        ? 'bg-[var(--win-subtle-active)] text-[var(--text-primary)] font-medium'
        : 'text-[var(--text-primary)] hover:bg-[var(--win-subtle-hover)] active:bg-[var(--win-subtle-active)]',
      dropHighlight ? 'ring-2 ring-[var(--accent)] bg-[var(--accent-soft)]' : '',
    ].join(' ')}
  >
    {active && <SidebarSelectionIndicator />}
    <CharkleIcon name={iconName} style="duotone" size={16} isActive={active} />
    <span className="truncate flex-1 min-w-0">{label}</span>
    {dotColorHex && (
      <span
        className="w-[7px] h-[7px] rounded-full shrink-0"
        style={{ backgroundColor: dotColorHex }}
      />
    )}
    {isActiveMoodboard && (
      <span
        title="当前活跃情绪板（悬浮窗直投目标）"
        className="w-1.5 h-1.5 rounded-full bg-[var(--success)] shrink-0"
      />
    )}
    {isPinnedOffline && (
      <Pin12Regular className="w-3 h-3 text-[var(--text-tertiary)] shrink-0" />
    )}
    {badge != null && badge !== 0 && (
      <span
        className={[
          'text-[11px] px-1.5 py-0.5 rounded-full leading-none charkle-tabular shrink-0',
          highlightBadge
            ? 'bg-[var(--accent)] text-[var(--accent-text)] font-semibold'
            : 'text-[var(--text-tertiary)]',
        ].join(' ')}
      >
        {badge}
      </span>
    )}
  </button>
);

export const SidebarView: React.FC = () => {
  const destination = useCoordinatorStore((s) => s.destination);
  const setDestination = useCoordinatorStore((s) => s.setDestination);
  const sidebarCollapsed = useCoordinatorStore((s) => s.sidebarCollapsed);
  const toggleSidebarCollapsed = useCoordinatorStore((s) => s.toggleSidebarCollapsed);
  const sidebarSearchFocusNonce = useCoordinatorStore((s) => s.sidebarSearchFocusNonce);
  const requestSidebarSearchFocus = useCoordinatorStore((s) => s.requestSidebarSearchFocus);
  const surfaceState = useCoordinatorStore((s) => s.surfaceState);
  const settingsOpen = useCoordinatorStore((s) => s.settingsOpen);
  const openSettings = useCoordinatorStore((s) => s.openSettings);
  const setCaptureOpen = useCoordinatorStore((s) => s.setCaptureOpen);
  const openMoodboardGenerator = useCoordinatorStore((s) => s.openMoodboardGenerator);
  const openDeduplication = useCoordinatorStore((s) => s.openDeduplication);
  const activeMoodboardId = useCoordinatorStore((s) => s.activeMoodboardId);
  const setActiveMoodboardId = useCoordinatorStore((s) => s.setActiveMoodboardId);
  const pushToast = useCoordinatorStore((s) => s.pushToast);

  const allAssets = useLibraryStore((s) => s.allAssets);
  const folders = useLibraryStore((s) => s.folders);
  const smartFolders = useLibraryStore((s) => s.smartFolders);
  const tagCounts = useLibraryStore((s) => s.tagCounts);
  const inboxCount = useLibraryStore((s) => s.inboxCount);
  const cutAssetIds = useLibraryStore((s) => s.cutAssetIds);
  const criteria = useLibraryStore((s) => s.criteria);
  const setCriteria = useLibraryStore((s) => s.setCriteria);
  const recentlyTouchedTags = useLibraryStore((s) => s.recentlyTouchedTags);
  const tagUsageFrequency = useLibraryStore((s) => s.tagUsageFrequency);
  const recordTouchedTags = useLibraryStore((s) => s.recordTouchedTags);
  const pasteCutAssets = useLibraryStore((s) => s.pasteCutAssets);
  const createFolder = useLibraryStore((s) => s.createFolder);
  const renameFolder = useLibraryStore((s) => s.renameFolder);
  const moveFolder = useLibraryStore((s) => s.moveFolder);
  const updateFolderAppearance = useLibraryStore((s) => s.updateFolderAppearance);
  const deleteFolder = useLibraryStore((s) => s.deleteFolder);
  const saveSmartFolder = useLibraryStore((s) => s.saveSmartFolder);
  const deleteSmartFolder = useLibraryStore((s) => s.deleteSmartFolder);

  const boards = useMoodboardStore((s) => s.boards);
  const openBoard = useMoodboardStore((s) => s.openBoard);
  const setBoardPinnedOffline = useMoodboardStore((s) => s.setBoardPinnedOffline);
  const deleteBoard = useMoodboardStore((s) => s.deleteBoard);

  const syncConfig = useSyncAIStore((s) => s.syncConfig);
  const syncStatus = useSyncAIStore((s) => s.syncStatus);
  const syncing = useSyncAIStore((s) => s.syncing);
  const syncNow = useSyncAIStore((s) => s.syncNow);
  const refreshSyncAndCache = useSyncAIStore((s) => s.refreshSyncAndCache);

  const pointerTarget = useDndStore((s) => s.pointerTarget);
  const osFileDrop = useDndStore((s) => s.osFileDrop);

  const [searchDraft, setSearchDraft] = useState(criteria.searchQuery);
  const [syncPopoverOpen, setSyncPopoverOpen] = useState(false);
  const [creatingRootFolder, setCreatingRootFolder] = useState(false);
  const [rootFolderName, setRootFolderName] = useState('');
  const [folderSortMenuOpen, setFolderSortMenuOpen] = useState(false);
  const [smartModalOpen, setSmartModalOpen] = useState(false);
  const [editingSmartFolder, setEditingSmartFolder] = useState<SmartFolderRecord | null>(null);
  const [deletingSmartId, setDeletingSmartId] = useState<string | null>(null);
  const [smartContextMenu, setSmartContextMenu] = useState<{
    folder: SmartFolderRecord;
    point: { x: number; y: number };
  } | null>(null);
  const [inboxContextPoint, setInboxContextPoint] = useState<{ x: number; y: number } | null>(null);
  const [tagsExpanded, setTagsExpanded] = useState(true);
  const [allTagsOpen, setAllTagsOpen] = useState(false);
  const [allTagsQuery, setAllTagsQuery] = useState('');
  const [allTagsSortByCount, setAllTagsSortByCount] = useState(true);
  const [boardMenu, setBoardMenu] = useState<{
    id: string;
    title: string;
    pinnedOffline: boolean;
    point: { x: number; y: number };
  } | null>(null);

  const searchInputRef = useRef<HTMLInputElement | null>(null);
  const lastSearchFocusNonceRef = useRef(0);
  const folderSortBtnRef = useRef<HTMLButtonElement | null>(null);
  const smartDeleteAnchorRef = useRef<HTMLButtonElement | null>(null);
  const allTagsBtnRef = useRef<HTMLButtonElement | null>(null);
  const collapsedTagsBtnRef = useRef<HTMLButtonElement | null>(null);
  const syncBtnRef = useRef<HTMLButtonElement | null>(null);
  const collapsedSyncBtnRef = useRef<HTMLButtonElement | null>(null);
  const rootCreateSettledRef = useRef(false);

  const isMoodboardView =
    destination.type === 'moodboardsHome' || destination.type === 'moodboard';
  const effectiveSearchDestination: SidebarDestination = isMoodboardView
    ? { type: 'allItems' }
    : destination;

  // Keep search input synchronized with external criteria resets
  useEffect(() => {
    setSearchDraft(criteria.searchQuery);
  }, [criteria.searchQuery]);

  // Register folder asset drop handler at SidebarView level so it stays active even when
  // the sidebar is collapsed to the 64px icon rail (where FolderTree is not mounted).
  useEffect(() => {
    return registerPointerDragHandlers({
      onDropAssetsToFolder: (folderId, assetIds) => {
        const lib = useLibraryStore.getState();
        const targetName = lib.folders.find((f) => f.id === folderId)?.name ?? '文件夹';
        void moveAssetsToFolderWithUndo(
          assetIds,
          folderId,
          targetName,
          useCoordinatorStore.getState().destination,
        );
      },
    });
  }, []);

  // 120ms debounced unified instant + hybrid search (single search bar, zero mode switching)
  useEffect(() => {
    if (searchDraft === criteria.searchQuery) return;
    const timer = window.setTimeout(() => {
      const trimmed = searchDraft.trim();
      if (isMoodboardView && trimmed.length > 0) {
        setDestination({ type: 'allItems' });
      }
      void setCriteria({ searchQuery: searchDraft }, effectiveSearchDestination);
    }, 120);
    return () => window.clearTimeout(timer);
  }, [
    searchDraft,
    criteria.searchQuery,
    isMoodboardView,
    effectiveSearchDestination,
    setCriteria,
    setDestination,
  ]);

  // Focus & select the single global search input on Ctrl+F or collapsed rail search click
  useEffect(() => {
    if (
      sidebarSearchFocusNonce === 0 ||
      sidebarSearchFocusNonce === lastSearchFocusNonceRef.current ||
      sidebarCollapsed
    ) {
      return;
    }
    lastSearchFocusNonceRef.current = sidebarSearchFocusNonce;
    const raf = window.requestAnimationFrame(() => {
      searchInputRef.current?.focus();
      searchInputRef.current?.select();
    });
    return () => window.cancelAnimationFrame(raf);
  }, [sidebarSearchFocusNonce, sidebarCollapsed]);

  const commitSearchImmediately = () => {
    const trimmed = searchDraft.trim();
    if (isMoodboardView && trimmed.length > 0) {
      setDestination({ type: 'allItems' });
    }
    void setCriteria({ searchQuery: searchDraft }, effectiveSearchDestination);
  };

  const totalNonTrashedCount = useMemo(
    () => allAssets.filter((a) => !a.isTrashed).length,
    [allAssets],
  );
  const untaggedCount = useMemo(
    () => allAssets.filter((a) => !a.isTrashed && a.tags.length === 0).length,
    [allAssets],
  );
  const trashCount = useMemo(
    () => allAssets.filter((a) => a.isTrashed).length,
    [allAssets],
  );

  // Smart Capped Tags (recent 5 + top 10 non-duplicates + active overflow tag)
  const { recentFive, topNonDuplicate, extraSelectedTag, hiddenTagCount } = useMemo(() => {
    const recent = getRecentFrequentSidebarTags(
      tagCounts,
      recentlyTouchedTags,
      tagUsageFrequency,
    );
    const recentLower = new Set(recent.map((t) => t.name.toLowerCase()));
    const topTen = getTopTenSidebarTags(tagCounts);
    const topNonDup = topTen.filter((t) => !recentLower.has(t.name.toLowerCase()));
    const displayedLower = new Set([
      ...recent.map((t) => t.name.toLowerCase()),
      ...topNonDup.map((t) => t.name.toLowerCase()),
    ]);
    let extra = null;
    if (destination.type === 'tag' && !displayedLower.has(destination.name.toLowerCase())) {
      extra =
        tagCounts.find((t) => t.name.toLowerCase() === destination.name.toLowerCase()) ?? null;
    }
    const hidden = Math.max(
      0,
      tagCounts.length - (recent.length + topNonDup.length + (extra ? 1 : 0)),
    );
    return {
      recentFive: recent,
      topNonDuplicate: topNonDup,
      extraSelectedTag: extra,
      hiddenTagCount: hidden,
    };
  }, [tagCounts, recentlyTouchedTags, tagUsageFrequency, destination]);

  const filteredAllTags = useMemo(() => {
    const q = allTagsQuery.trim().toLowerCase();
    const list = q
      ? tagCounts.filter((t) => t.name.toLowerCase().includes(q))
      : [...tagCounts];
    list.sort((a, b) => {
      if (allTagsSortByCount && a.count !== b.count) return b.count - a.count;
      return a.name.localeCompare(b.name, 'zh-CN');
    });
    return list;
  }, [tagCounts, allTagsQuery, allTagsSortByCount]);

  const isDropOverInbox =
    pointerTarget?.kind === 'inbox' ||
    (osFileDrop.active && osFileDrop.target?.kind === 'inbox');
  const isDropOverTrash = pointerTarget?.kind === 'trash';
  const isDropOverFolderRoot =
    pointerTarget?.kind === 'folderRoot' ||
    (osFileDrop.active && osFileDrop.target?.kind === 'folderRoot');
  const dropBoardId =
    pointerTarget?.kind === 'board'
      ? pointerTarget.id
      : osFileDrop.active && osFileDrop.target?.kind === 'board'
        ? osFileDrop.target.id
        : null;

  const activeMode = syncConfig?.mode ?? syncStatus?.activeMode ?? 'localOnly';
  const syncBusy =
    syncing ||
    (syncStatus != null &&
      syncStatus.phase !== 'idle' &&
      !(typeof syncStatus.phase === 'object' && 'error' in syncStatus.phase));
  const syncError =
    syncStatus != null && typeof syncStatus.phase === 'object' && 'error' in syncStatus.phase;
  const syncDotClass = syncError
    ? 'bg-[var(--danger)]'
    : syncBusy || (syncStatus?.pendingOpCount ?? 0) > 0
      ? 'bg-[var(--warning)]'
      : activeMode === 'localOnly'
        ? 'bg-[var(--text-tertiary)]'
        : 'bg-[var(--success)]';
  const syncSummaryText = syncPhaseLabel(syncStatus, syncing, activeMode);

  const handleToggleSyncPopover = () => {
    const next = !syncPopoverOpen;
    setSyncPopoverOpen(next);
    if (next) void refreshSyncAndCache();
  };

  const handleHeaderDoubleClick = (e: React.MouseEvent) => {
    if ((e.target as HTMLElement).closest('button, input, [data-tauri-drag-region="false"]')) {
      return;
    }
    void getTransport().windowToggleMaximize().catch(() => {});
  };

  const startCreateRootFolder = () => {
    rootCreateSettledRef.current = false;
    setRootFolderName('');
    setCreatingRootFolder(true);
  };

  const cancelCreateRootFolder = () => {
    rootCreateSettledRef.current = true;
    setCreatingRootFolder(false);
    setRootFolderName('');
  };

  const commitRootFolder = async () => {
    if (rootCreateSettledRef.current) return;
    rootCreateSettledRef.current = true;
    const trimmed = rootFolderName.trim();
    setCreatingRootFolder(false);
    setRootFolderName('');
    if (trimmed) {
      try {
        const created = await createFolder(trimmed, null);
        pushToast({ message: `已创建文件夹「${created.name}」`, tone: 'success' });
      } catch (err) {
        pushToast({
          message: `创建文件夹失败：${err instanceof Error ? err.message : String(err)}`,
          tone: 'error',
        });
      }
    }
  };

  const sortRootFolders = async (mode: 'name' | 'count') => {
    setFolderSortMenuOpen(false);
    const roots = folders.filter((f) => !f.parentID);
    const sorted = [...roots].sort((a, b) => {
      if (mode === 'count' && a.assetCount !== b.assetCount) {
        return b.assetCount - a.assetCount;
      }
      return a.name.localeCompare(b.name, 'zh-CN', { numeric: true });
    });
    try {
      for (let i = 0; i < sorted.length; i += 1) {
        await moveFolder(sorted[i].id, null, i);
      }
      pushToast({
        message: mode === 'name' ? '文件夹已按名称排好序' : '文件夹已按素材数量排好序',
        tone: 'info',
      });
    } catch (err) {
      pushToast({
        message: `排序失败：${err instanceof Error ? err.message : String(err)}`,
        tone: 'error',
      });
    }
  };

  const selectBoard = (boardId: string) => {
    setActiveMoodboardId(boardId);
    setDestination({ type: 'moodboard', id: boardId });
    void openBoard(boardId);
  };

  const selectTag = (tagName: string) => {
    recordTouchedTags([tagName]);
    setDestination({ type: 'tag', name: tagName });
  };

  const renderAllTagsPopoverContent = () => (
    <div className="flex flex-col gap-2">
      <div className="win-input-elevation flex items-center gap-1.5 h-8 px-2 rounded-[var(--win-radius-control)]">
        <Search16Regular className="w-3.5 h-3.5 text-[var(--text-tertiary)] shrink-0" />
        <input
          type="text"
          value={allTagsQuery}
          onChange={(e) => setAllTagsQuery(e.target.value)}
          placeholder={`搜索全部 ${tagCounts.length} 个标签…`}
          aria-label="搜索全部标签"
          className="flex-1 min-w-0 bg-transparent text-[12px] text-[var(--text-primary)] placeholder:text-[var(--text-tertiary)] outline-none"
        />
        {allTagsQuery && (
          <button
            type="button"
            aria-label="清空标签搜索"
            onClick={() => setAllTagsQuery('')}
            className="text-[var(--text-tertiary)] hover:text-[var(--text-primary)] cursor-pointer inline-flex items-center justify-center"
          >
            <Dismiss12Regular className="w-3 h-3" />
          </button>
        )}
        <button
          type="button"
          onClick={() => setAllTagsSortByCount((v) => !v)}
          className="win-control-elevation px-1.5 py-0.5 rounded-[var(--win-radius-control)] bg-[var(--win-control-fill)] hover:bg-[var(--win-control-fill-hover)] text-[10.5px] font-medium text-[var(--text-secondary)] hover:text-[var(--text-primary)] shrink-0 cursor-pointer"
        >
          {allTagsSortByCount ? '按数量' : '按名称'}
        </button>
      </div>
      <div className="max-h-[300px] overflow-y-auto charkle-scroll flex flex-col gap-0.5">
        {filteredAllTags.length === 0 ? (
          <div className="py-6 text-center text-[12px] text-[var(--text-tertiary)]">
            未找到匹配的标签
          </div>
        ) : (
          filteredAllTags.map((tag) => {
            const selected = destination.type === 'tag' && destination.name === tag.name;
            return (
              <button
                key={tag.name}
                type="button"
                onClick={() => {
                  setAllTagsOpen(false);
                  selectTag(tag.name);
                }}
                className={[
                  'charkle-pressable w-full flex items-center gap-2 px-2.5 h-8 rounded-[var(--win-radius-control)] text-[13px] cursor-pointer text-left',
                  selected
                    ? 'bg-[var(--win-subtle-active)] text-[var(--accent)] font-medium'
                    : 'text-[var(--text-primary)] hover:bg-[var(--win-subtle-hover)]',
                ].join(' ')}
              >
                <CharkleIcon name="tag" style="duotone" size={15} isActive={selected} />
                <span className="truncate flex-1 min-w-0">#{tag.name}</span>
                <span className="text-[11px] text-[var(--text-tertiary)] charkle-tabular shrink-0">
                  {tag.count}
                </span>
              </button>
            );
          })
        )}
      </div>
    </div>
  );

  const renderSyncPopover = () => (
    <Popover
      open={syncPopoverOpen}
      onOpenChange={setSyncPopoverOpen}
      anchorEl={sidebarCollapsed ? collapsedSyncBtnRef.current : syncBtnRef.current}
      placement={sidebarCollapsed ? 'right-start' : 'top-start'}
      className="w-[296px] p-3.5"
    >
      <div className="flex flex-col gap-3 text-[12px]">
        <div className="flex items-center gap-2.5">
          {syncBusy ? (
            <ArrowSync16Regular className="w-4 h-4 animate-spin motion-reduce:animate-none text-[var(--accent)] shrink-0" />
          ) : (
            <span className={`h-2 w-2 rounded-full shrink-0 ${syncDotClass}`} />
          )}
          <div className="min-w-0 flex-1">
            <div className="flex items-center gap-1.5">
              <span className="text-[13px] font-semibold text-[var(--text-primary)] truncate">
                {activeMode === 'localOnly'
                  ? '本地存储模式'
                  : syncBusy
                    ? syncSummaryText
                    : (syncStatus?.pendingOpCount ?? 0) > 0
                      ? `有 ${syncStatus?.pendingOpCount} 项待同步`
                      : '云端存储已连接'}
              </span>
              {syncBusy && syncStatus?.progressFraction != null && (
                <span className="text-[11px] font-semibold charkle-mono charkle-tabular text-[var(--accent)]">
                  {Math.round(syncStatus.progressFraction * 100)}%
                </span>
              )}
            </div>
            <div className="text-[11px] text-[var(--text-secondary)] truncate">
              {syncModeLabel(activeMode)}
            </div>
          </div>
        </div>

        {syncBusy && (
          <div className="flex flex-col gap-1.5">
            <div className="h-1.5 w-full rounded-full bg-[var(--bg-subtle)] overflow-hidden">
              <div
                className="h-full bg-[var(--accent)] rounded-full transition-transform duration-150 origin-left"
                style={{
                  transform: `scaleX(${Math.max(0.08, Math.min(1, syncStatus?.progressFraction ?? 0.35))})`,
                }}
              />
            </div>
            {syncStatus?.currentDetail && (
              <div className="text-[11px] text-[var(--text-secondary)] truncate">
                {syncStatus.currentDetail}
              </div>
            )}
          </div>
        )}

        {!syncBusy && syncStatus?.lastError && (
          <div className="p-2.5 rounded-[var(--win-radius-control)] bg-[var(--danger-soft)] text-[11.5px] text-[var(--danger)] leading-relaxed charkle-wrap-safe">
            {syncStatus.lastError}
          </div>
        )}

        <div className="p-2.5 rounded-[var(--win-radius-card)] bg-[var(--win-layer-default)] border border-[var(--win-stroke-card)] flex flex-col gap-1.5 text-[12px]">
          <div className="flex items-center justify-between">
            <span className="text-[var(--text-secondary)]">上次同步</span>
            <span className="font-medium text-[var(--text-primary)] charkle-tabular">
              {activeMode === 'localOnly'
                ? '仅本地保存'
                : formatRelativeSyncTime(syncStatus?.lastSyncedAt)}
            </span>
          </div>
          <div className="flex items-center justify-between">
            <span className="text-[var(--text-secondary)]">本地待传队列</span>
            <span
              className={[
                'font-medium charkle-tabular',
                (syncStatus?.pendingOpCount ?? 0) > 0
                  ? 'text-[var(--warning)]'
                  : 'text-[var(--text-secondary)]',
              ].join(' ')}
            >
              {(syncStatus?.pendingOpCount ?? 0) > 0
                ? `${syncStatus?.pendingOpCount} 项`
                : '已清空'}
            </span>
          </div>
        </div>

        <div className="flex items-center gap-2">
          {activeMode !== 'localOnly' && (
            <Button
              variant="accent"
              size="xs"
              disabled={syncBusy}
              onClick={() => void syncNow()}
              className="flex-1 justify-center"
            >
              {syncBusy ? '同步中…' : '立即同步'}
            </Button>
          )}
          <Button
            variant={activeMode === 'localOnly' ? 'accent' : 'standard'}
            size="xs"
            onClick={() => {
              setSyncPopoverOpen(false);
              openSettings('sync');
            }}
            className={activeMode === 'localOnly' ? 'flex-1 justify-center' : ''}
          >
            {activeMode === 'localOnly' ? '配置云端同步…' : '存储设置…'}
          </Button>
        </div>
      </div>
    </Popover>
  );

  // Collapsed 64px Icon-Only Mica Rail (fluent2-design-system.md §3.2)
  if (sidebarCollapsed) {
    const topFolders = folders.filter((f) => !f.parentID).slice(0, 8);
    const railBtnClass = (active: boolean, highlighted = false) =>
      [
        'charkle-pressable relative w-[44px] h-[36px] rounded-[var(--win-radius-control)] inline-flex items-center justify-center cursor-pointer shrink-0',
        'focus-visible:outline-2 focus-visible:outline-offset-1 focus-visible:outline-[var(--accent)]',
        active
          ? 'bg-[var(--win-subtle-active)] text-[var(--accent)]'
          : 'text-[var(--text-secondary)] hover:bg-[var(--win-subtle-hover)] active:bg-[var(--win-subtle-active)] hover:text-[var(--text-primary)]',
        highlighted ? 'ring-2 ring-[var(--accent)] bg-[var(--accent-soft)]' : '',
      ].join(' ');

    const isAllItemsActive = isDestEqual(destination, { type: 'allItems' });
    const isInboxActive = isDestEqual(destination, { type: 'inbox' });
    const isUntaggedActive = isDestEqual(destination, { type: 'untagged' });
    const isRecentActive = isDestEqual(destination, { type: 'recent' });
    const isMoodboardActive =
      destination.type === 'moodboardsHome' || destination.type === 'moodboard';
    const isPinterestActive = destination.type === 'pinterest';
    const isTrashActive = isDestEqual(destination, { type: 'trash' });
    const isTagActive = destination.type === 'tag';

    return (
      <LayoutGroup id="win-sidebar">
        <aside
          aria-label="主导航侧边栏"
          data-collapsed="true"
          data-backdrop={surfaceState?.backdrop ?? 'solidFallback'}
          className="charkle-sidebar-surface w-full min-w-0 shrink-0 h-full flex flex-col items-center select-none"
        >
          {/* Top 40px Drag Header — centered BrandMark */}
          <div
            data-tauri-drag-region
            onDoubleClick={handleHeaderDoubleClick}
            className="h-[40px] shrink-0 w-full flex items-center justify-center"
          >
            <CharkleBrandMark size={20} />
          </div>

          {/* Compact Rail Utility Actions (Expand, Search, Quick Capture) */}
          <div className="pb-2 flex flex-col items-center gap-1">
            <Tooltip content="展开侧边栏" shortcut="Ctrl+\" side="right">
              <button
                type="button"
                onClick={toggleSidebarCollapsed}
                aria-label="展开侧边栏"
                className={railBtnClass(false)}
              >
                <PanelLeftExpand20Regular className="w-[18px] h-[18px]" />
              </button>
            </Tooltip>

            <Tooltip content="搜索素材" shortcut="Ctrl+F" side="right">
              <button
                type="button"
                onClick={requestSidebarSearchFocus}
                aria-label="搜索素材"
                className="charkle-pressable win-control-elevation w-[44px] h-[36px] rounded-[var(--win-radius-control)] bg-[var(--win-control-fill)] hover:bg-[var(--win-control-fill-hover)] inline-flex items-center justify-center text-[var(--text-secondary)] hover:text-[var(--text-primary)] cursor-pointer shrink-0 focus-visible:outline-2 focus-visible:outline-offset-1 focus-visible:outline-[var(--accent)]"
              >
                <Search20Regular className="w-[17px] h-[17px]" />
              </button>
            </Tooltip>

            <Tooltip content="导入或采集素材" shortcut="Ctrl+N" side="right">
              <button
                type="button"
                onClick={() => setCaptureOpen(true)}
                aria-label="导入或采集素材"
                className={railBtnClass(false)}
              >
                <Add20Regular className="w-[18px] h-[18px]" />
              </button>
            </Tooltip>
          </div>

          <div className="w-8 h-px bg-[var(--win-stroke-divider)] my-0.5 shrink-0" />

          {/* Main Navigation Icons */}
          <div className="flex-1 min-h-0 overflow-y-auto charkle-scroll-hidden py-1.5 flex flex-col items-center gap-1 w-full">
            <Tooltip content="全部素材" side="right">
              <button
                type="button"
                aria-label="全部素材"
                onClick={() => setDestination({ type: 'allItems' })}
                className={railBtnClass(isAllItemsActive)}
              >
                {isAllItemsActive && <SidebarSelectionIndicator />}
                <CharkleIcon name="library" style="duotone" size={18} isActive={isAllItemsActive} />
              </button>
            </Tooltip>

            <Tooltip content={inboxCount > 0 ? `收件箱 (${inboxCount})` : '收件箱'} side="right">
              <button
                type="button"
                aria-label="收件箱"
                data-drop-inbox="true"
                onClick={() => setDestination({ type: 'inbox' })}
                className={railBtnClass(isInboxActive, isDropOverInbox)}
              >
                {isInboxActive && <SidebarSelectionIndicator />}
                <CharkleIcon name="inbox" style="duotone" size={18} isActive={isInboxActive} />
                {inboxCount > 0 && (
                  <span className="absolute top-1.5 right-1.5 w-[6px] h-[6px] rounded-full bg-[var(--accent)]" />
                )}
              </button>
            </Tooltip>

            <Tooltip content="未打标签" side="right">
              <button
                type="button"
                aria-label="未打标签"
                onClick={() => setDestination({ type: 'untagged' })}
                className={railBtnClass(isUntaggedActive)}
              >
                {isUntaggedActive && <SidebarSelectionIndicator />}
                <CharkleIcon
                  name="untagged"
                  style="duotone"
                  size={18}
                  isActive={isUntaggedActive}
                />
              </button>
            </Tooltip>

            <Tooltip content="最近浏览" side="right">
              <button
                type="button"
                aria-label="最近浏览"
                onClick={() => setDestination({ type: 'recent' })}
                className={railBtnClass(isRecentActive)}
              >
                {isRecentActive && <SidebarSelectionIndicator />}
                <CharkleIcon name="recent" style="duotone" size={18} isActive={isRecentActive} />
              </button>
            </Tooltip>

            <Tooltip content="所有情绪板" side="right">
              <button
                type="button"
                aria-label="所有情绪板"
                onClick={() => setDestination({ type: 'moodboardsHome' })}
                className={railBtnClass(isMoodboardActive)}
              >
                {isMoodboardActive && <SidebarSelectionIndicator />}
                <CharkleIcon
                  name="moodboard"
                  style="duotone"
                  size={18}
                  isActive={isMoodboardActive}
                />
              </button>
            </Tooltip>

            <Tooltip content="Pinterest 无限空间" side="right">
              <button
                type="button"
                aria-label="Pinterest 无限空间"
                data-testid="sidebar-pinterest-rail-btn"
                onClick={() => setDestination({ type: 'pinterest' })}
                className={railBtnClass(isPinterestActive)}
              >
                {isPinterestActive && <SidebarSelectionIndicator />}
                <CharkleIcon
                  name="ai-spark"
                  style="duotone"
                  size={18}
                  isActive={isPinterestActive}
                />
              </button>
            </Tooltip>

            {smartFolders.length > 0 && (
              <>
                <div className="w-6 h-px bg-[var(--win-stroke-divider)] my-0.5 shrink-0" />
                {smartFolders.slice(0, 6).map((sf) => {
                  const active = destination.type === 'smartFolder' && destination.id === sf.id;
                  const count = getSmartFolderMatchCount(allAssets, sf.rule);
                  return (
                    <Tooltip key={sf.id} content={`智能文件夹：${sf.name} (${count})`} side="right">
                      <button
                        type="button"
                        aria-label={`智能文件夹 ${sf.name}`}
                        onClick={() => setDestination({ type: 'smartFolder', id: sf.id })}
                        className={railBtnClass(active)}
                      >
                        {active && <SidebarSelectionIndicator />}
                        <CharkleIcon
                          name="smart-folder"
                          style="duotone"
                          size={18}
                          isActive={active}
                          tintHex={sf.colorHex}
                        />
                      </button>
                    </Tooltip>
                  );
                })}
              </>
            )}

            {topFolders.length > 0 && (
              <>
                <div className="w-6 h-px bg-[var(--win-stroke-divider)] my-0.5 shrink-0" />
                {topFolders.map((folder) => {
                  const active = destination.type === 'folder' && destination.id === folder.id;
                  const dropHi =
                    (pointerTarget?.kind === 'folder' && pointerTarget.id === folder.id) ||
                    (osFileDrop.active &&
                      osFileDrop.target?.kind === 'folder' &&
                      osFileDrop.target.id === folder.id);
                  return (
                    <Tooltip
                      key={folder.id}
                      content={`${folder.name} (${folder.assetCount})`}
                      side="right"
                    >
                      <button
                        type="button"
                        aria-label={folder.name}
                        data-drop-folder-id={folder.id}
                        data-drop-label={folder.name}
                        onClick={() => setDestination({ type: 'folder', id: folder.id })}
                        className={railBtnClass(active, dropHi)}
                      >
                        {active && <SidebarSelectionIndicator />}
                        <CharkleFolderIcon
                          colorHex={folder.colorHex}
                          customSymbol={folder.customSymbol}
                          size={18}
                          isActive={active}
                        />
                      </button>
                    </Tooltip>
                  );
                })}
              </>
            )}

            <div className="w-6 h-px bg-[var(--win-stroke-divider)] my-0.5 shrink-0" />

            {tagCounts.length > 0 && (
              <Tooltip content={`查看全部标签 (${tagCounts.length})`} side="right">
                <button
                  ref={collapsedTagsBtnRef}
                  type="button"
                  aria-label="查看全部标签"
                  onClick={() => setAllTagsOpen((v) => !v)}
                  className={railBtnClass(allTagsOpen || isTagActive)}
                >
                  {isTagActive && <SidebarSelectionIndicator />}
                  <CharkleIcon
                    name="tag"
                    style="duotone"
                    size={18}
                    isActive={allTagsOpen || isTagActive}
                  />
                </button>
              </Tooltip>
            )}

            <Tooltip content={trashCount > 0 ? `回收站 (${trashCount})` : '回收站'} side="right">
              <button
                type="button"
                aria-label={trashCount > 0 ? `回收站 (${trashCount})` : '回收站'}
                data-drop-trash="true"
                onClick={() => setDestination({ type: 'trash' })}
                className={railBtnClass(isTrashActive, isDropOverTrash)}
              >
                {isTrashActive && <SidebarSelectionIndicator />}
                <CharkleIcon name="trash" style="duotone" size={18} isActive={isTrashActive} />
                {trashCount > 0 && (
                  <span className="absolute top-1.5 right-1.5 w-[6px] h-[6px] rounded-full bg-[var(--danger)]/85" />
                )}
              </button>
            </Tooltip>
          </div>

          {/* Pinned Bottom Footer: Cloud Sync + Settings */}
          <div className="w-full shrink-0 border-t border-[var(--win-stroke-divider)] py-2 flex flex-col items-center gap-1">
            <Tooltip content={syncSummaryText} side="right">
              <button
                ref={collapsedSyncBtnRef}
                type="button"
                aria-label="同步状态"
                onClick={handleToggleSyncPopover}
                className={railBtnClass(syncPopoverOpen)}
              >
                {syncBusy ? (
                  <ArrowSync16Regular className="w-4 h-4 animate-spin motion-reduce:animate-none text-[var(--accent)]" />
                ) : (
                  <CloudSync16Regular className="w-[18px] h-[18px]" />
                )}
                <span
                  className={`absolute top-2 right-2 w-[6px] h-[6px] rounded-full ${syncDotClass}`}
                />
              </button>
            </Tooltip>

            <Tooltip content="设置" shortcut="Ctrl+," side="right">
              <button
                type="button"
                onClick={() => openSettings()}
                aria-label="打开设置中心"
                className={railBtnClass(settingsOpen)}
              >
                <CharkleIcon name="settings" style="duotone" size={18} isActive={settingsOpen} />
              </button>
            </Tooltip>
          </div>

          <Popover
            open={allTagsOpen}
            onOpenChange={setAllTagsOpen}
            anchorEl={collapsedTagsBtnRef.current}
            placement="right-start"
            className="w-[272px] p-2.5"
          >
            {renderAllTagsPopoverContent()}
          </Popover>

          {renderSyncPopover()}
        </aside>
      </LayoutGroup>
    );
  }

  // Expanded 248px Full-Height Mica Alt NavigationView
  return (
    <LayoutGroup id="win-sidebar">
      <aside
        aria-label="主导航侧边栏"
        data-collapsed="false"
        data-backdrop={surfaceState?.backdrop ?? 'solidFallback'}
        className="charkle-sidebar-surface w-full min-w-0 shrink-0 h-full flex flex-col select-none"
      >
        {/* Top 40px Drag Header: BrandMark + Wordmark + Collapse (Ctrl+\) + Quick Capture (Ctrl+N) */}
        <div
          data-tauri-drag-region
          onDoubleClick={handleHeaderDoubleClick}
          className="h-[40px] shrink-0 flex items-center justify-between px-3"
        >
          <div
            data-tauri-drag-region
            className="flex items-center gap-2 min-w-0 cursor-default whitespace-nowrap"
          >
            <CharkleBrandMark size={18} />
            <span className="text-[13px] font-semibold tracking-[-0.01em] text-[var(--text-primary)] truncate">
              Charkle
            </span>
          </div>

          <div data-tauri-drag-region="false" className="flex items-center gap-0.5 shrink-0">
            <Tooltip content="收起侧边栏" shortcut="Ctrl+\" side="bottom">
              <button
                type="button"
                data-tauri-drag-region="false"
                onClick={toggleSidebarCollapsed}
                aria-label="收起侧边栏"
                className="charkle-pressable h-7 w-7 inline-flex items-center justify-center rounded-[var(--win-radius-control)] text-[var(--text-secondary)] hover:text-[var(--text-primary)] hover:bg-[var(--win-subtle-hover)] active:bg-[var(--win-subtle-active)] cursor-pointer focus-visible:outline-2 focus-visible:outline-offset-1 focus-visible:outline-[var(--accent)]"
              >
                <PanelLeftContract20Regular className="w-4 h-4" />
              </button>
            </Tooltip>

            <Tooltip content="导入或采集素材" shortcut="Ctrl+N" side="bottom">
              <button
                type="button"
                data-tauri-drag-region="false"
                onClick={() => setCaptureOpen(true)}
                aria-label="导入或采集素材"
                className="charkle-pressable h-7 w-7 inline-flex items-center justify-center rounded-[var(--win-radius-control)] text-[var(--text-secondary)] hover:text-[var(--text-primary)] hover:bg-[var(--win-subtle-hover)] active:bg-[var(--win-subtle-active)] cursor-pointer focus-visible:outline-2 focus-visible:outline-offset-1 focus-visible:outline-[var(--accent)]"
              >
                <Add20Regular className="w-4 h-4" />
              </button>
            </Tooltip>
          </div>
        </div>

        {/* THE ONLY Unified Global Search Input (Instant Literal + Hybrid Semantic, Ctrl+F) */}
        <div className="px-3 pb-2 shrink-0">
          <div className="win-input-elevation h-8 px-2 flex items-center gap-1.5 rounded-[var(--win-radius-control)]">
            <Search16Regular className="w-3.5 h-3.5 shrink-0 text-[var(--text-tertiary)]" />
            <input
              ref={searchInputRef}
              type="text"
              value={searchDraft}
              onChange={(e) => setSearchDraft(e.target.value)}
              onKeyDown={(e) => {
                if (e.nativeEvent.isComposing || e.keyCode === 229) return;
                if (e.key === 'Enter') {
                  e.preventDefault();
                  commitSearchImmediately();
                } else if (e.key === 'Escape') {
                  e.preventDefault();
                  if (searchDraft) {
                    setSearchDraft('');
                    void setCriteria({ searchQuery: '' }, effectiveSearchDestination);
                  } else {
                    searchInputRef.current?.blur();
                  }
                }
              }}
              placeholder="搜索素材、摘要或画面内容…"
              aria-label="搜索素材"
              className="flex-1 min-w-0 bg-transparent text-[13px] leading-[18px] text-[var(--text-primary)] placeholder:text-[var(--text-tertiary)] outline-none"
            />
            {searchDraft && (
              <button
                type="button"
                aria-label="清空搜索"
                onClick={() => {
                  setSearchDraft('');
                  void setCriteria({ searchQuery: '' }, effectiveSearchDestination);
                  searchInputRef.current?.focus();
                }}
                className="h-5 w-5 inline-flex items-center justify-center rounded-[var(--win-radius-control)] text-[var(--text-tertiary)] hover:text-[var(--text-primary)] hover:bg-[var(--win-subtle-hover)] cursor-pointer shrink-0"
              >
                <Dismiss12Regular className="w-3 h-3" />
              </button>
            )}
          </div>
        </div>

        {/* Scrollable Navigation Sections */}
        <div className="flex-1 min-h-0 overflow-y-auto charkle-scroll-hidden px-2 pb-2.5 flex flex-col gap-3">
          {/* Section 1: Library */}
          <section className="flex flex-col gap-0.5">
            <div className="flex items-center justify-between px-2 pb-0.5">
              <span className="text-[11px] font-semibold tracking-[0.02em] text-[var(--text-tertiary)]">
                素材库
              </span>
              <Tooltip content="全媒体智能去重" shortcut="Ctrl+Shift+D" side="right">
                <button
                  type="button"
                  aria-label="全媒体智能去重"
                  data-testid="sidebar-smart-dedup-btn"
                  onClick={() => openDeduplication({ type: 'allActive' })}
                  className="charkle-pressable h-6 w-6 inline-flex items-center justify-center rounded-[var(--win-radius-control)] text-[var(--text-tertiary)] hover:text-[var(--accent)] hover:bg-[var(--win-subtle-hover)] cursor-pointer focus-visible:outline-2 focus-visible:outline-offset-1 focus-visible:outline-[var(--accent)]"
                >
                  <Sparkle16Regular className="w-3.5 h-3.5" />
                </button>
              </Tooltip>
            </div>
            <nav aria-label="素材库导航" className="flex flex-col gap-0.5">
            <NavRow
              iconName="library"
              label="全部素材"
              badge={totalNonTrashedCount || null}
              active={isDestEqual(destination, { type: 'allItems' })}
              onClick={() => setDestination({ type: 'allItems' })}
            />
            <NavRow
              iconName="inbox"
              label="收件箱"
              badge={inboxCount}
              highlightBadge={inboxCount > 0}
              dropHighlight={isDropOverInbox}
              dataAttrs={{ 'data-drop-inbox': 'true' }}
              active={isDestEqual(destination, { type: 'inbox' })}
              onClick={() => setDestination({ type: 'inbox' })}
              onContextMenu={(e) => {
                if (cutAssetIds.length === 0) return;
                e.preventDefault();
                e.stopPropagation();
                setInboxContextPoint({ x: e.clientX, y: e.clientY });
              }}
            />
            <NavRow
              iconName="untagged"
              label="未打标签"
              badge={untaggedCount || null}
              active={isDestEqual(destination, { type: 'untagged' })}
              onClick={() => setDestination({ type: 'untagged' })}
            />
            <NavRow
              iconName="recent"
              label="最近浏览"
              active={isDestEqual(destination, { type: 'recent' })}
              onClick={() => setDestination({ type: 'recent' })}
            />
            <NavRow
              iconName="trash"
              label="回收站"
              badge={trashCount || null}
              dropHighlight={isDropOverTrash}
              dataAttrs={{ 'data-drop-trash': 'true' }}
              active={isDestEqual(destination, { type: 'trash' })}
              onClick={() => setDestination({ type: 'trash' })}
            />
            </nav>
          </section>

          <div className="h-px bg-[var(--win-stroke-divider)] mx-1.5" />

          {/* Section: Pinterest Infinite Exploration Space */}
          <section className="flex flex-col gap-0.5">
            <div className="flex items-center justify-between px-2 pb-0.5">
              <span className="text-[11px] font-semibold tracking-[0.02em] text-[var(--text-tertiary)]">
                灵感发现
              </span>
            </div>
            <NavRow
              iconName="ai-spark"
              label="Pinterest 空间"
              dataAttrs={{ 'data-testid': 'sidebar-pinterest-nav-btn' }}
              active={destination.type === 'pinterest'}
              onClick={() => setDestination({ type: 'pinterest' })}
            />
          </section>

          <div className="h-px bg-[var(--win-stroke-divider)] mx-1.5" />

          {/* Section 2: Moodboards */}
          <section className="flex flex-col gap-0.5">
            <div className="flex items-center justify-between px-2 pb-0.5">
              <span className="text-[11px] font-semibold tracking-[0.02em] text-[var(--text-tertiary)]">
                情绪板
              </span>
              <button
                type="button"
                onClick={() => openMoodboardGenerator('prompt')}
                aria-label="快速生成情绪板"
                className="charkle-pressable inline-flex items-center gap-1 px-1.5 py-0.5 rounded-[var(--win-radius-control)] hover:bg-[var(--win-subtle-hover)] hover:text-[var(--accent)] text-[11px] font-medium text-[var(--text-secondary)] cursor-pointer focus-visible:outline-2 focus-visible:outline-offset-1 focus-visible:outline-[var(--accent)]"
              >
                <Add16Regular className="w-3 h-3" />
                <span>生成</span>
              </button>
            </div>

            <NavRow
              iconName="moodboard"
              label="所有情绪板"
              badge={boards.length || null}
              active={destination.type === 'moodboardsHome'}
              onClick={() => setDestination({ type: 'moodboardsHome' })}
            />

            {boards.map((board) => (
              <NavRow
                key={board.id}
                iconName="sparkle-board"
                label={board.title}
                badge={board.itemCount || null}
                isActiveMoodboard={activeMoodboardId === board.id}
                isPinnedOffline={board.pinnedOffline}
                dropHighlight={dropBoardId === board.id}
                dataAttrs={{ 'data-drop-board-id': board.id, 'data-drop-label': board.title }}
                active={destination.type === 'moodboard' && destination.id === board.id}
                onClick={() => selectBoard(board.id)}
                onContextMenu={(e) => {
                  e.preventDefault();
                  e.stopPropagation();
                  setBoardMenu({
                    id: board.id,
                    title: board.title,
                    pinnedOffline: board.pinnedOffline,
                    point: { x: e.clientX, y: e.clientY },
                  });
                }}
              />
            ))}
          </section>

          <div className="h-px bg-[var(--win-stroke-divider)] mx-1.5" />

          {/* Section 3: Smart Folders */}
          <section className="flex flex-col gap-0.5">
            <div className="flex items-center justify-between px-2 pb-0.5">
              <span className="text-[11px] font-semibold tracking-[0.02em] text-[var(--text-tertiary)]">
                智能文件夹
              </span>
              <Tooltip content="新建智能文件夹（按标签、描述、颜色或类型自动归集）" side="right">
                <button
                  type="button"
                  aria-label="新建智能文件夹"
                  onClick={() => {
                    setEditingSmartFolder(null);
                    setSmartModalOpen(true);
                  }}
                  className="charkle-pressable h-6 w-6 inline-flex items-center justify-center rounded-[var(--win-radius-control)] text-[var(--text-tertiary)] hover:text-[var(--text-primary)] hover:bg-[var(--win-subtle-hover)] cursor-pointer focus-visible:outline-2 focus-visible:outline-offset-1 focus-visible:outline-[var(--accent)]"
                >
                  <Add16Regular className="w-3.5 h-3.5" />
                </button>
              </Tooltip>
            </div>

            <div className="flex flex-col gap-0.5">
              {smartFolders.length === 0 ? (
                <button
                  type="button"
                  onClick={() => {
                    setEditingSmartFolder(null);
                    setSmartModalOpen(true);
                  }}
                  className="charkle-pressable w-full flex items-center gap-2 px-2.5 h-8 rounded-[var(--win-radius-control)] text-[12px] text-[var(--text-tertiary)] hover:text-[var(--text-secondary)] hover:bg-[var(--win-subtle-hover)] cursor-pointer text-left"
                >
                  <CharkleIcon name="smart-folder" style="duotone" size={14} />
                  <span className="truncate">定义规则自动归集素材…</span>
                </button>
              ) : (
                smartFolders.map((sf) => {
                  const active = destination.type === 'smartFolder' && destination.id === sf.id;
                  const matchCount = getSmartFolderMatchCount(allAssets, sf.rule);
                  return (
                    <div
                      key={sf.id}
                      role="button"
                      tabIndex={0}
                      onClick={() => setDestination({ type: 'smartFolder', id: sf.id })}
                      onKeyDown={(e) => {
                        if (e.key === 'Enter' || e.key === ' ') {
                          e.preventDefault();
                          setDestination({ type: 'smartFolder', id: sf.id });
                        }
                      }}
                      onContextMenu={(e) => {
                        e.preventDefault();
                        e.stopPropagation();
                        setSmartContextMenu({
                          folder: sf,
                          point: { x: e.clientX, y: e.clientY },
                        });
                      }}
                      className={[
                        'group relative flex items-center gap-2.5 px-2.5 h-[34px] rounded-[var(--win-radius-control)] text-[13px] leading-[18px] cursor-pointer',
                        'focus-visible:outline-2 focus-visible:outline-offset-1 focus-visible:outline-[var(--accent)]',
                        active
                          ? 'bg-[var(--win-subtle-active)] text-[var(--text-primary)] font-medium'
                          : 'text-[var(--text-primary)] hover:bg-[var(--win-subtle-hover)] active:bg-[var(--win-subtle-active)]',
                      ].join(' ')}
                    >
                      {active && <SidebarSelectionIndicator />}
                      <CharkleIcon
                        name="smart-folder"
                        style="duotone"
                        size={16}
                        isActive={active}
                        tintHex={sf.colorHex}
                      />
                      <span className="truncate flex-1 min-w-0">{sf.name}</span>
                      {matchCount > 0 && (
                        <span
                          className={[
                            'text-[11px] text-[var(--text-tertiary)] charkle-tabular',
                            deletingSmartId === sf.id ? 'hidden' : 'group-hover:hidden',
                          ].join(' ')}
                        >
                          {matchCount}
                        </span>
                      )}
                      <div
                        className={[
                          'items-center gap-0.5 shrink-0',
                          deletingSmartId === sf.id ? 'flex' : 'hidden group-hover:flex',
                        ].join(' ')}
                      >
                        <button
                          type="button"
                          aria-label={`编辑智能文件夹 ${sf.name}`}
                          onClick={(e) => {
                            e.stopPropagation();
                            setEditingSmartFolder(sf);
                            setSmartModalOpen(true);
                          }}
                          className="h-6 w-6 inline-flex items-center justify-center rounded-[var(--win-radius-control)] text-[var(--text-secondary)] hover:bg-[var(--win-subtle-hover)] hover:text-[var(--text-primary)] cursor-pointer"
                        >
                          <Edit16Regular className="w-3.5 h-3.5" />
                        </button>
                        <button
                          type="button"
                          aria-label={`删除智能文件夹 ${sf.name}`}
                          onClick={(e) => {
                            e.stopPropagation();
                            smartDeleteAnchorRef.current = e.currentTarget;
                            setDeletingSmartId(sf.id);
                          }}
                          className="h-6 w-6 inline-flex items-center justify-center rounded-[var(--win-radius-control)] text-[var(--danger)] hover:bg-[var(--danger-soft)] cursor-pointer"
                        >
                          <Delete16Regular className="w-3.5 h-3.5" />
                        </button>
                      </div>
                    </div>
                  );
                })
              )}
            </div>
          </section>

          <div className="h-px bg-[var(--win-stroke-divider)] mx-1.5" />

          {/* Section 4: Hierarchical Folders */}
          <section className="flex flex-col gap-0.5">
            <div
              data-drop-folder-root="true"
              className={[
                'flex items-center justify-between px-2 py-0.5 rounded-[var(--win-radius-control)]',
                isDropOverFolderRoot ? 'bg-[var(--accent-soft)] ring-1 ring-[var(--accent)]' : '',
              ].join(' ')}
            >
              <span className="text-[11px] font-semibold tracking-[0.02em] text-[var(--text-tertiary)]">
                文件夹
              </span>
              <div className="flex items-center gap-0.5">
                <Tooltip content="导入外部素材包 (.eaglepack / .zip)" shortcut="Ctrl+Shift+I" side="right">
                  <button
                    type="button"
                    aria-label="导入外部素材包"
                    data-testid="sidebar-import-package-btn"
                    onClick={() => void runMaterialPackageImport('files')}
                    className="charkle-pressable h-6 w-6 inline-flex items-center justify-center rounded-[var(--win-radius-control)] text-[var(--text-tertiary)] hover:text-[var(--text-primary)] hover:bg-[var(--win-subtle-hover)] cursor-pointer focus-visible:outline-2 focus-visible:outline-offset-1 focus-visible:outline-[var(--accent)]"
                  >
                    <FolderOpen16Regular className="w-3.5 h-3.5" />
                  </button>
                </Tooltip>
                {folders.length > 1 && (
                  <Tooltip content="排序文件夹" side="right">
                    <button
                      ref={folderSortBtnRef}
                      type="button"
                      aria-label="排序文件夹"
                      onClick={() => setFolderSortMenuOpen((v) => !v)}
                      className="charkle-pressable h-6 w-6 inline-flex items-center justify-center rounded-[var(--win-radius-control)] text-[var(--text-tertiary)] hover:text-[var(--text-primary)] hover:bg-[var(--win-subtle-hover)] cursor-pointer focus-visible:outline-2 focus-visible:outline-offset-1 focus-visible:outline-[var(--accent)]"
                    >
                      <ArrowSort16Regular className="w-3.5 h-3.5" />
                    </button>
                  </Tooltip>
                )}
                <Tooltip content="新建文件夹（也可拖入外部文件夹）" side="right">
                  <button
                    type="button"
                    aria-label="新建文件夹"
                    onClick={startCreateRootFolder}
                    className="charkle-pressable h-6 w-6 inline-flex items-center justify-center rounded-[var(--win-radius-control)] text-[var(--text-tertiary)] hover:text-[var(--text-primary)] hover:bg-[var(--win-subtle-hover)] cursor-pointer focus-visible:outline-2 focus-visible:outline-offset-1 focus-visible:outline-[var(--accent)]"
                  >
                    <Add16Regular className="w-3.5 h-3.5" />
                  </button>
                </Tooltip>
              </div>
            </div>

            {creatingRootFolder && (
              <div className="px-1 py-0.5">
                <input
                  type="text"
                  value={rootFolderName}
                  autoFocus
                  placeholder="新文件夹名称…"
                  aria-label="新文件夹名称"
                  onChange={(e) => setRootFolderName(e.target.value)}
                  onBlur={() => void commitRootFolder()}
                  onKeyDown={(e) => {
                    if (e.nativeEvent.isComposing || e.keyCode === 229) return;
                    if (e.key === 'Enter') {
                      e.preventDefault();
                      e.stopPropagation();
                      void commitRootFolder();
                    } else if (e.key === 'Escape') {
                      e.preventDefault();
                      e.stopPropagation();
                      cancelCreateRootFolder();
                    }
                  }}
                  className="win-input-elevation w-full h-8 px-2 rounded-[var(--win-radius-control)] text-[13px] text-[var(--text-primary)] outline-none"
                />
              </div>
            )}

            <FolderTree
              folders={folders}
              activeFolderId={destination.type === 'folder' ? destination.id : null}
              onSelectFolder={(id) => setDestination({ type: 'folder', id })}
              onCreateSubfolder={async (parentId, name) => {
                const created = await createFolder(name, parentId);
                pushToast({ message: `已创建文件夹「${created.name}」`, tone: 'success' });
              }}
              onRenameFolder={async (id, name) => {
                await renameFolder(id, name);
              }}
              onMoveFolder={async (id, newParentId, idx) => {
                await moveFolder(id, newParentId, idx);
              }}
              onUpdateAppearance={async (id, hex, sym) => {
                await updateFolderAppearance(id, hex, sym);
              }}
              onDeleteFolder={async (id, trashContents) => {
                await deleteFolder(id, trashContents, destination);
              }}
              onDropAssets={async (folderId, assetIds) => {
                const targetName = folders.find((f) => f.id === folderId)?.name ?? '文件夹';
                await moveAssetsToFolderWithUndo(assetIds, folderId, targetName, destination);
              }}
            />
          </section>

          {/* Section 5: Smart Capped Tags */}
          {tagCounts.length > 0 && (
            <>
              <div className="h-px bg-[var(--win-stroke-divider)] mx-1.5" />
              <section className="flex flex-col gap-0.5">
                <div className="flex items-center justify-between gap-1">
                  <button
                    type="button"
                    onClick={() => setTagsExpanded((v) => !v)}
                    aria-expanded={tagsExpanded}
                    className="flex-1 flex items-center gap-1 px-2 py-1 rounded-[var(--win-radius-control)] hover:bg-[var(--win-subtle-hover)] text-[11px] font-semibold tracking-[0.02em] text-[var(--text-tertiary)] cursor-pointer text-left focus-visible:outline-2 focus-visible:outline-offset-1 focus-visible:outline-[var(--accent)]"
                  >
                    <ChevronDown12Regular
                      className={`w-3 h-3 transition-transform duration-150 ${tagsExpanded ? '' : '-rotate-90'}`}
                    />
                    <span>标签</span>
                    <span className="font-normal charkle-tabular">{tagCounts.length}</span>
                  </button>
                  <button
                    ref={allTagsBtnRef}
                    type="button"
                    aria-label={`查看全部 ${tagCounts.length} 个标签`}
                    onClick={() => setAllTagsOpen((v) => !v)}
                    className="charkle-pressable px-2 py-0.5 rounded-[var(--win-radius-control)] hover:bg-[var(--win-subtle-hover)] text-[11px] font-medium text-[var(--text-secondary)] hover:text-[var(--accent)] cursor-pointer focus-visible:outline-2 focus-visible:outline-offset-1 focus-visible:outline-[var(--accent)]"
                  >
                    全部
                  </button>
                </div>

                {tagsExpanded && (
                  <div className="flex flex-col gap-0.5">
                    {extraSelectedTag && (
                      <NavRow
                        iconName="tag"
                        label={`#${extraSelectedTag.name}`}
                        badge={extraSelectedTag.count}
                        active
                        onClick={() => selectTag(extraSelectedTag.name)}
                      />
                    )}

                    {recentFive.length > 0 && (
                      <>
                        <div className="px-2.5 pt-1 pb-0.5 text-[10px] font-semibold text-[var(--text-tertiary)]">
                          最近常用
                        </div>
                        {recentFive.map((tag) => (
                          <NavRow
                            key={`recent-${tag.name}`}
                            iconName="tag"
                            label={`#${tag.name}`}
                            badge={tag.count}
                            active={destination.type === 'tag' && destination.name === tag.name}
                            onClick={() => selectTag(tag.name)}
                          />
                        ))}
                      </>
                    )}

                    {topNonDuplicate.length > 0 && (
                      <>
                        {recentFive.length > 0 && (
                          <div className="px-2.5 pt-1.5 pb-0.5 text-[10px] font-semibold text-[var(--text-tertiary)]">
                            高频标签
                          </div>
                        )}
                        {topNonDuplicate.map((tag) => (
                          <NavRow
                            key={`top-${tag.name}`}
                            iconName="tag"
                            label={`#${tag.name}`}
                            badge={tag.count}
                            active={destination.type === 'tag' && destination.name === tag.name}
                            onClick={() => selectTag(tag.name)}
                          />
                        ))}
                      </>
                    )}

                    {hiddenTagCount > 0 && (
                      <button
                        type="button"
                        onClick={() => setAllTagsOpen(true)}
                        className="charkle-pressable mt-1 mx-0.5 h-7 px-2.5 rounded-[var(--win-radius-control)] hover:bg-[var(--win-subtle-hover)] text-[11.5px] font-medium text-[var(--text-secondary)] flex items-center gap-1.5 cursor-pointer"
                      >
                        <MoreHorizontal16Regular className="w-3.5 h-3.5 shrink-0" />
                        <span className="truncate">
                          查看全部 {tagCounts.length} 个标签（已隐藏 {hiddenTagCount} 个）
                        </span>
                      </button>
                    )}
                  </div>
                )}
              </section>
            </>
          )}
        </div>

        {/* Pinned Bottom Footer: Cloud Sync Status Row + THE ONLY Settings Entry */}
        <div className="shrink-0 border-t border-[var(--win-stroke-divider)] px-2 py-2 flex flex-col gap-0.5">
          <button
            ref={syncBtnRef}
            type="button"
            aria-label="同步状态"
            aria-expanded={syncPopoverOpen}
            onClick={handleToggleSyncPopover}
            className={[
              'charkle-pressable w-full flex items-center gap-2.5 px-2.5 h-[34px] rounded-[var(--win-radius-control)] text-[12.5px] cursor-pointer text-left',
              'focus-visible:outline-2 focus-visible:outline-offset-1 focus-visible:outline-[var(--accent)]',
              syncError
                ? 'text-[var(--danger)] bg-[var(--danger-soft)] font-medium'
                : syncPopoverOpen
                  ? 'bg-[var(--win-subtle-active)] text-[var(--text-primary)] font-medium'
                  : 'text-[var(--text-secondary)] hover:bg-[var(--win-subtle-hover)] hover:text-[var(--text-primary)]',
            ].join(' ')}
          >
            <span className="w-4 h-4 inline-flex items-center justify-center shrink-0">
              {syncBusy ? (
                <ArrowSync16Regular className="w-3.5 h-3.5 animate-spin motion-reduce:animate-none text-[var(--accent)]" />
              ) : (
                <span className={`w-2 h-2 rounded-full ${syncDotClass}`} />
              )}
            </span>
            <span className="truncate flex-1 min-w-0 charkle-tabular">{syncSummaryText}</span>
          </button>

          <button
            type="button"
            aria-label="打开设置中心"
            onClick={() => openSettings()}
            className={[
              'charkle-pressable w-full flex items-center justify-between gap-2 px-2.5 h-[34px] rounded-[var(--win-radius-control)] text-[13px] leading-[18px] cursor-pointer',
              'focus-visible:outline-2 focus-visible:outline-offset-1 focus-visible:outline-[var(--accent)]',
              settingsOpen
                ? 'bg-[var(--win-subtle-active)] text-[var(--text-primary)] font-medium'
                : 'text-[var(--text-primary)] hover:bg-[var(--win-subtle-hover)] active:bg-[var(--win-subtle-active)]',
            ].join(' ')}
          >
            <span className="inline-flex items-center gap-2.5 min-w-0">
              <CharkleIcon name="settings" style="duotone" size={16} isActive={settingsOpen} />
              <span className="truncate">设置</span>
            </span>
            <kbd className="text-[11px] charkle-mono text-[var(--text-tertiary)] shrink-0">
              Ctrl+,
            </kbd>
          </button>
        </div>

        {/* Folder Sort Dropdown Menu */}
        <DropdownMenu
          open={folderSortMenuOpen}
          onOpenChange={setFolderSortMenuOpen}
          anchorEl={folderSortBtnRef.current}
          side="bottom"
          align="end"
          className="w-[176px]"
        >
          <MenuItem onSelect={() => void sortRootFolders('name')}>按名称 A→Z 排序</MenuItem>
          <MenuItem onSelect={() => void sortRootFolders('count')}>按素材数量降序</MenuItem>
        </DropdownMenu>

        {/* Inbox Context Menu (Paste Cut Assets) */}
        <ContextMenu
          open={inboxContextPoint !== null}
          onOpenChange={(open) => {
            if (!open) setInboxContextPoint(null);
          }}
          anchorPoint={inboxContextPoint}
          className="w-[216px]"
        >
          <MenuItem
            icon={<ClipboardPaste16Regular className="w-4 h-4 text-[var(--accent)]" />}
            onSelect={() => {
              setInboxContextPoint(null);
              void pasteCutAssets(null, destination)
                .then((count) =>
                  pushToast({ message: `已将 ${count} 项素材移至收件箱`, tone: 'success' }),
                )
                .catch((err) =>
                  pushToast({
                    message: `移动失败：${err instanceof Error ? err.message : String(err)}`,
                    tone: 'error',
                  }),
                );
            }}
          >
            粘贴移动至此（{cutAssetIds.length} 项）
          </MenuItem>
        </ContextMenu>

        {/* Moodboard Context Menu */}
        <ContextMenu
          open={boardMenu !== null}
          onOpenChange={(open) => {
            if (!open) setBoardMenu(null);
          }}
          anchorPoint={boardMenu?.point ?? null}
          className="w-[220px]"
        >
          {boardMenu && (
            <>
              <MenuItem
                onSelect={() => {
                  setActiveMoodboardId(boardMenu.id);
                  pushToast({
                    message: `已锁定「${boardMenu.title}」为悬浮窗活跃情绪板`,
                    tone: 'success',
                  });
                  setBoardMenu(null);
                }}
              >
                {activeMoodboardId === boardMenu.id
                  ? '已是当前活跃情绪板'
                  : '设为当前活跃情绪板'}
              </MenuItem>
              <MenuItem
                onSelect={() => {
                  const next = !boardMenu.pinnedOffline;
                  void setBoardPinnedOffline(boardMenu.id, next);
                  pushToast({
                    message: next ? '整板素材将始终保留在本地' : '已取消整板始终保留在本地',
                    tone: 'info',
                  });
                  setBoardMenu(null);
                }}
              >
                {boardMenu.pinnedOffline ? '取消始终保留在本地' : '始终保留整板在本地'}
              </MenuItem>
              <MenuSeparator />
              <MenuItem
                tone="danger"
                icon={<Delete16Regular className="w-4 h-4" />}
                onSelect={() => {
                  const id = boardMenu.id;
                  setBoardMenu(null);
                  if (destination.type === 'moodboard' && destination.id === id) {
                    setDestination({ type: 'moodboardsHome' });
                  }
                  void deleteBoard(id);
                }}
              >
                删除情绪板
              </MenuItem>
            </>
          )}
        </ContextMenu>

        {/* Smart Folder Right-Click Context Menu */}
        <ContextMenu
          open={smartContextMenu !== null}
          onOpenChange={(open) => {
            if (!open) setSmartContextMenu(null);
          }}
          anchorPoint={smartContextMenu?.point ?? null}
          className="w-[184px]"
        >
          {smartContextMenu && (
            <>
              <MenuItem
                icon={<Options16Regular className="w-4 h-4" />}
                onSelect={() => {
                  const sf = smartContextMenu.folder;
                  setSmartContextMenu(null);
                  setEditingSmartFolder(sf);
                  setSmartModalOpen(true);
                }}
              >
                编辑筛选规则…
              </MenuItem>
              <MenuSeparator />
              <MenuItem
                tone="danger"
                icon={<Delete16Regular className="w-4 h-4" />}
                onSelect={() => {
                  const sf = smartContextMenu.folder;
                  setSmartContextMenu(null);
                  void deleteSmartFolder(sf.id, destination)
                    .then(() =>
                      pushToast({ message: `已删除智能文件夹「${sf.name}」`, tone: 'info' }),
                    )
                    .catch((err) =>
                      pushToast({
                        message: `删除智能文件夹失败：${err instanceof Error ? err.message : String(err)}`,
                        tone: 'error',
                      }),
                    );
                }}
              >
                删除智能文件夹
              </MenuItem>
            </>
          )}
        </ContextMenu>

        {/* Searchable All Tags Popover */}
        <Popover
          open={allTagsOpen}
          onOpenChange={setAllTagsOpen}
          anchorEl={allTagsBtnRef.current}
          placement="right-start"
          className="w-[272px] p-2.5"
        >
          {renderAllTagsPopoverContent()}
        </Popover>

        {renderSyncPopover()}

        <SmartFolderEditorModal
          open={smartModalOpen}
          onClose={() => setSmartModalOpen(false)}
          initial={editingSmartFolder}
          availableTags={tagCounts}
          onSave={(folder) => saveSmartFolder(folder, destination)}
        />

        <Popconfirm
          open={deletingSmartId !== null}
          onOpenChange={(open) => {
            if (!open) setDeletingSmartId(null);
          }}
          anchorEl={smartDeleteAnchorRef.current}
          title="删除此智能文件夹？"
          description="仅删除动态规则，不会删除任何素材文件。"
          confirmLabel="删除"
          onConfirm={() => {
            if (deletingSmartId) {
              const name = smartFolders.find((s) => s.id === deletingSmartId)?.name;
              void deleteSmartFolder(deletingSmartId, destination)
                .then(() =>
                  pushToast({
                    message: name ? `已删除智能文件夹「${name}」` : '已删除智能文件夹',
                    tone: 'info',
                  }),
                )
                .catch((err) =>
                  pushToast({
                    message: `删除智能文件夹失败：${err instanceof Error ? err.message : String(err)}`,
                    tone: 'error',
                  }),
                );
            }
          }}
        />
      </aside>
    </LayoutGroup>
  );
};
