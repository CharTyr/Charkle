import React, { useMemo, useRef, useState } from 'react';
import {
  ArrowUpDown,
  ChevronDown,
  ClipboardPaste,
  Ellipsis,
  PanelLeftClose,
  PanelLeftOpen,
  Pencil,
  Pin,
  Plus,
  Search,
  Settings,
  SlidersHorizontal,
  Trash2,
  X,
} from 'lucide-react';
import {
  CharkleFolderIcon,
  CharkleIcon,
  Popconfirm,
  Popover,
} from '../../design-system';
import {
  getRecentFrequentSidebarTags,
  getSmartFolderMatchCount,
  getTopTenSidebarTags,
  useCoordinatorStore,
  useLibraryStore,
  useMoodboardStore,
} from '../../stores';
import type { SidebarDestination, SmartFolderRecord } from '../../types/domain';
import { useDndStore } from '../dnd/dndStore';
import { FolderTree } from './FolderTree';
import { SmartFolderEditorModal } from './SmartFolderEditorModal';

function isDestEqual(a: SidebarDestination, b: SidebarDestination): boolean {
  if (a.type !== b.type) return false;
  if ('id' in a && 'id' in b) return a.id === b.id;
  if ('name' in a && 'name' in b) return a.name === b.name;
  return true;
}

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
      'charkle-pressable w-full flex items-center gap-2.5 px-2.5 h-[30px] rounded-[var(--radius-chip)] text-[12.5px] cursor-pointer text-left',
      active
        ? 'bg-[var(--accent-soft)] text-[var(--accent)] font-medium'
        : 'text-[var(--text-primary)] hover:bg-[var(--bg-subtle)]/80',
      dropHighlight ? 'ring-2 ring-[var(--accent)] bg-[var(--accent-soft)]' : '',
    ].join(' ')}
  >
    <CharkleIcon name={iconName} style="duotone" size={16} isActive={active} />
    <span className="truncate flex-1 min-w-0 leading-[1.45]">{label}</span>
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
      <Pin size={10.5} className="text-[var(--text-tertiary)] shrink-0" />
    )}
    {badge != null && badge !== 0 && (
      <span
        className={[
          'text-[10.5px] px-1.5 py-0.5 rounded-full leading-none charkle-tabular shrink-0',
          highlightBadge
            ? 'bg-[var(--accent)] text-white font-semibold'
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
  const surfaceState = useCoordinatorStore((s) => s.surfaceState);
  const isMica = surfaceState?.backdrop === 'mica';
  const isMoodboardView =
    destination.type === 'moodboardsHome' || destination.type === 'moodboard';
  const sidebarBorderClass =
    isMica && !isMoodboardView ? '' : 'border-r border-[var(--border-hairline)]';
  const settingsOpen = useCoordinatorStore((s) => s.settingsOpen);
  const openSettings = useCoordinatorStore((s) => s.openSettings);
  const setJumpOpen = useCoordinatorStore((s) => s.setJumpOpen);
  const openMoodboardGenerator = useCoordinatorStore((s) => s.openMoodboardGenerator);
  const activeMoodboardId = useCoordinatorStore((s) => s.activeMoodboardId);
  const setActiveMoodboardId = useCoordinatorStore((s) => s.setActiveMoodboardId);
  const pushToast = useCoordinatorStore((s) => s.pushToast);

  const allAssets = useLibraryStore((s) => s.allAssets);
  const folders = useLibraryStore((s) => s.folders);
  const smartFolders = useLibraryStore((s) => s.smartFolders);
  const tagCounts = useLibraryStore((s) => s.tagCounts);
  const inboxCount = useLibraryStore((s) => s.inboxCount);
  const cutAssetIds = useLibraryStore((s) => s.cutAssetIds);
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
  const updateAssets = useLibraryStore((s) => s.updateAssets);

  const boards = useMoodboardStore((s) => s.boards);
  const openBoard = useMoodboardStore((s) => s.openBoard);
  const setBoardPinnedOffline = useMoodboardStore((s) => s.setBoardPinnedOffline);
  const deleteBoard = useMoodboardStore((s) => s.deleteBoard);

  const pointerTarget = useDndStore((s) => s.pointerTarget);
  const osFileDrop = useDndStore((s) => s.osFileDrop);

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

  const folderSortBtnRef = useRef<HTMLButtonElement | null>(null);
  const smartDeleteAnchorRef = useRef<HTMLButtonElement | null>(null);
  const allTagsBtnRef = useRef<HTMLButtonElement | null>(null);
  const collapsedTagsBtnRef = useRef<HTMLButtonElement | null>(null);
  const rootCreateSettledRef = useRef(false);

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

  // Smart Capped Tags (1:1 macOS SidebarView.swift)
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
      <div className="flex items-center gap-1.5 h-7 px-2 rounded-[var(--radius-card-inner)] bg-[var(--bg-subtle)]">
        <Search size={12.5} className="text-[var(--text-tertiary)] shrink-0" />
        <input
          type="text"
          value={allTagsQuery}
          onChange={(e) => setAllTagsQuery(e.target.value)}
          placeholder={`搜索全部 ${tagCounts.length} 个标签…`}
          className="flex-1 min-w-0 bg-transparent text-[12px] text-[var(--text-primary)] outline-none"
        />
        {allTagsQuery && (
          <button
            type="button"
            aria-label="清空搜索"
            onClick={() => setAllTagsQuery('')}
            className="text-[var(--text-tertiary)] hover:text-[var(--text-primary)] cursor-pointer"
          >
            <X size={12} />
          </button>
        )}
        <button
          type="button"
          onClick={() => setAllTagsSortByCount((v) => !v)}
          className="px-1.5 py-0.5 rounded-full bg-[var(--bg-elevated)] text-[10px] font-medium text-[var(--text-secondary)] hover:text-[var(--text-primary)] shrink-0 cursor-pointer"
        >
          {allTagsSortByCount ? '按数量' : '按名称'}
        </button>
      </div>
      <div className="max-h-[300px] overflow-y-auto charkle-scroll flex flex-col gap-0.5">
        {filteredAllTags.length === 0 ? (
          <div className="py-6 text-center text-[11.5px] text-[var(--text-tertiary)]">
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
                  'charkle-pressable w-full flex items-center gap-2 px-2 py-1.5 rounded-[7px] text-[12px] cursor-pointer text-left',
                  selected
                    ? 'bg-[var(--accent-soft)] text-[var(--accent)] font-medium'
                    : 'text-[var(--text-primary)] hover:bg-[var(--bg-subtle)]',
                ].join(' ')}
              >
                <CharkleIcon name="tag" style="duotone" size={14} isActive={selected} />
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

  // Collapsed 76px Icon-Only Rail (1:1 macOS SidebarView.swift collapsedRailBody, Pitfall 11)
  if (sidebarCollapsed) {
    const topFolders = folders.filter((f) => !f.parentID).slice(0, 8);
    const railBtnClass = (active: boolean, highlighted = false) =>
      [
        'charkle-pressable relative w-[44px] h-[36px] rounded-[10px] inline-flex items-center justify-center cursor-pointer shrink-0',
        active
          ? 'bg-[var(--accent-soft)] text-[var(--accent)]'
          : 'text-[var(--text-secondary)] hover:bg-[var(--bg-subtle)] hover:text-[var(--text-primary)]',
        highlighted ? 'ring-2 ring-[var(--accent)] bg-[var(--accent-soft)]' : '',
      ].join(' ');

    return (
      <aside
        aria-label="主导航侧边栏"
        data-collapsed="true"
        className={`charkle-mica-chrome w-[76px] shrink-0 h-full flex flex-col items-center ${sidebarBorderClass} select-none`}
      >
        <div className="py-2 flex flex-col items-center gap-1.5">
          <button
            type="button"
            onClick={toggleSidebarCollapsed}
            title="展开侧边栏 (Ctrl+\)"
            aria-label="展开侧边栏"
            className="charkle-pressable w-[44px] h-[34px] rounded-[9px] inline-flex items-center justify-center text-[var(--text-secondary)] hover:bg-[var(--bg-subtle)] hover:text-[var(--text-primary)] cursor-pointer shrink-0"
          >
            <PanelLeftOpen size={16} />
          </button>
          <button
            type="button"
            onClick={() => setJumpOpen(true)}
            title="快速跳转 (Ctrl+J)"
            aria-label="快速跳转"
            className="charkle-pressable w-[44px] h-[34px] rounded-[9px] bg-[var(--bg-subtle)]/70 hover:bg-[var(--bg-subtle)] inline-flex items-center justify-center text-[var(--text-secondary)] cursor-pointer shrink-0"
          >
            <Search size={15} />
          </button>
        </div>

        <div className="w-8 h-px bg-[var(--border-hairline)] my-0.5" />

        <div className="flex-1 min-h-0 overflow-y-auto [scrollbar-width:none] [&::-webkit-scrollbar]:hidden py-2 flex flex-col items-center gap-1.5 w-full">
          <button
            type="button"
            title="全部素材"
            onClick={() => setDestination({ type: 'allItems' })}
            className={railBtnClass(isDestEqual(destination, { type: 'allItems' }))}
          >
            <CharkleIcon name="library" style="duotone" size={18} isActive={isDestEqual(destination, { type: 'allItems' })} />
          </button>
          <button
            type="button"
            title={`收件箱 (${inboxCount})`}
            data-drop-inbox="true"
            onClick={() => setDestination({ type: 'inbox' })}
            className={railBtnClass(isDestEqual(destination, { type: 'inbox' }), isDropOverInbox)}
          >
            <CharkleIcon name="inbox" style="duotone" size={18} isActive={isDestEqual(destination, { type: 'inbox' })} />
            {inboxCount > 0 && (
              <span className="absolute top-1.5 right-1.5 w-[6px] h-[6px] rounded-full bg-[var(--accent)]" />
            )}
          </button>
          <button
            type="button"
            title="未打标签"
            onClick={() => setDestination({ type: 'untagged' })}
            className={railBtnClass(isDestEqual(destination, { type: 'untagged' }))}
          >
            <CharkleIcon name="untagged" style="duotone" size={18} isActive={isDestEqual(destination, { type: 'untagged' })} />
          </button>
          <button
            type="button"
            title="最近浏览"
            onClick={() => setDestination({ type: 'recent' })}
            className={railBtnClass(isDestEqual(destination, { type: 'recent' }))}
          >
            <CharkleIcon name="recent" style="duotone" size={18} isActive={isDestEqual(destination, { type: 'recent' })} />
          </button>
          <button
            type="button"
            title="所有情绪板"
            onClick={() => setDestination({ type: 'moodboardsHome' })}
            className={railBtnClass(
              destination.type === 'moodboardsHome' || destination.type === 'moodboard',
            )}
          >
            <CharkleIcon
              name="moodboard"
              style="duotone"
              size={18}
              isActive={destination.type === 'moodboardsHome' || destination.type === 'moodboard'}
            />
          </button>

          {smartFolders.length > 0 && (
            <>
              <div className="w-6 h-px bg-[var(--border-hairline)] my-0.5" />
              {smartFolders.slice(0, 6).map((sf) => {
                const active = destination.type === 'smartFolder' && destination.id === sf.id;
                const count = getSmartFolderMatchCount(allAssets, sf.rule);
                return (
                  <button
                    key={sf.id}
                    type="button"
                    title={`智能文件夹：${sf.name} (${count})`}
                    onClick={() => setDestination({ type: 'smartFolder', id: sf.id })}
                    className={railBtnClass(active)}
                  >
                    <CharkleIcon
                      name="smart-folder"
                      style="duotone"
                      size={18}
                      isActive={active}
                      tintHex={sf.colorHex}
                    />
                  </button>
                );
              })}
            </>
          )}

          {topFolders.length > 0 && (
            <>
              <div className="w-6 h-px bg-[var(--border-hairline)] my-0.5" />
              {topFolders.map((folder) => {
                const active = destination.type === 'folder' && destination.id === folder.id;
                const dropHi =
                  (pointerTarget?.kind === 'folder' && pointerTarget.id === folder.id) ||
                  (osFileDrop.active &&
                    osFileDrop.target?.kind === 'folder' &&
                    osFileDrop.target.id === folder.id);
                return (
                  <button
                    key={folder.id}
                    type="button"
                    data-drop-folder-id={folder.id}
                    data-drop-label={folder.name}
                    title={`${folder.name} (${folder.assetCount})`}
                    onClick={() => setDestination({ type: 'folder', id: folder.id })}
                    className={railBtnClass(active, dropHi)}
                  >
                    <CharkleFolderIcon
                      colorHex={folder.colorHex}
                      customSymbol={folder.customSymbol}
                      size={18}
                      isActive={active}
                    />
                  </button>
                );
              })}
            </>
          )}

          <div className="w-6 h-px bg-[var(--border-hairline)] my-0.5" />

          {tagCounts.length > 0 && (
            <button
              ref={collapsedTagsBtnRef}
              type="button"
              title={`查看全部标签 (${tagCounts.length})`}
              onClick={() => setAllTagsOpen((v) => !v)}
              className={railBtnClass(allTagsOpen || destination.type === 'tag')}
            >
              <CharkleIcon name="tag" style="duotone" size={18} isActive={allTagsOpen} />
            </button>
          )}

          <button
            type="button"
            title={trashCount > 0 ? `回收站 (${trashCount})` : '回收站'}
            aria-label={trashCount > 0 ? `回收站 (${trashCount})` : '回收站'}
            data-drop-trash="true"
            onClick={() => setDestination({ type: 'trash' })}
            className={railBtnClass(isDestEqual(destination, { type: 'trash' }), isDropOverTrash)}
          >
            <CharkleIcon name="trash" style="duotone" size={18} isActive={isDestEqual(destination, { type: 'trash' })} />
            {trashCount > 0 && (
              <span className="absolute top-1.5 right-1.5 w-[6px] h-[6px] rounded-full bg-[var(--danger)]/85" />
            )}
          </button>
        </div>

        <div className="w-full border-t border-[var(--border-hairline)] py-2 flex justify-center">
          <button
            type="button"
            onClick={() => openSettings()}
            title="设置 (Ctrl+,)"
            aria-label="打开设置"
            className={railBtnClass(settingsOpen)}
          >
            <Settings size={17} />
          </button>
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
      </aside>
    );
  }

  return (
    <aside
      aria-label="主导航侧边栏"
      data-collapsed="false"
      className={`charkle-mica-chrome w-[232px] shrink-0 h-full flex flex-col ${sidebarBorderClass} select-none`}
    >
      <div className="flex-1 min-h-0 overflow-y-auto [scrollbar-width:none] [&::-webkit-scrollbar]:hidden px-2 py-2.5 flex flex-col gap-3.5">
        {/* Section 1: Library */}
        <nav className="flex flex-col gap-0.5">
          <div className="flex items-center justify-between px-2 pb-1">
            <span className="text-[11px] font-semibold tracking-[0.02em] text-[var(--text-tertiary)]">
              素材库
            </span>
            <button
              type="button"
              onClick={toggleSidebarCollapsed}
              title="收起为仅图标侧边栏 (Ctrl+\)"
              aria-label="收起为仅图标侧边栏"
              className="charkle-pressable h-5 w-5 inline-flex items-center justify-center rounded text-[var(--text-tertiary)] hover:text-[var(--text-primary)] hover:bg-[var(--bg-subtle)] cursor-pointer"
            >
              <PanelLeftClose size={13} />
            </button>
          </div>

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

        <div className="h-px bg-[var(--border-hairline)] mx-1.5" />

        {/* Section 2: Moodboards */}
        <section className="flex flex-col gap-0.5">
          <div className="flex items-center justify-between px-2 pb-1">
            <span className="text-[11px] font-semibold tracking-[0.02em] text-[var(--text-tertiary)]">
              情绪板
            </span>
            <button
              type="button"
              onClick={() => openMoodboardGenerator('prompt')}
              title="快速生成情绪板"
              className="charkle-pressable inline-flex items-center gap-1 px-2 py-0.5 rounded-full bg-[var(--bg-subtle)] hover:bg-[var(--accent-soft)] hover:text-[var(--accent)] text-[10.5px] font-medium text-[var(--text-secondary)] cursor-pointer"
            >
              <Plus size={10.5} />
              <span>快速生成</span>
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

        <div className="h-px bg-[var(--border-hairline)] mx-1.5" />

        {/* Section 3: Smart Folders */}
        <section className="flex flex-col gap-1">
          <div className="flex items-center justify-between px-2">
            <span className="text-[11px] font-semibold tracking-[0.02em] text-[var(--text-tertiary)]">
              智能文件夹
            </span>
            <button
              type="button"
              aria-label="新建智能文件夹"
              title="新建智能文件夹（按标签/描述/颜色/类型自动归集）"
              onClick={() => {
                setEditingSmartFolder(null);
                setSmartModalOpen(true);
              }}
              className="charkle-pressable h-5 w-5 inline-flex items-center justify-center rounded text-[var(--text-tertiary)] hover:text-[var(--text-primary)] hover:bg-[var(--bg-subtle)] cursor-pointer"
            >
              <Plus size={13} />
            </button>
          </div>

          <div className="flex flex-col gap-0.5">
            {smartFolders.length === 0 ? (
              <button
                type="button"
                onClick={() => {
                  setEditingSmartFolder(null);
                  setSmartModalOpen(true);
                }}
                className="charkle-pressable w-full flex items-center gap-1.5 px-2.5 py-1.5 rounded-[var(--radius-chip)] text-[11.5px] text-[var(--text-tertiary)] hover:text-[var(--text-secondary)] hover:bg-[var(--bg-subtle)]/60 cursor-pointer text-left"
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
                    onClick={() => setDestination({ type: 'smartFolder', id: sf.id })}
                    onContextMenu={(e) => {
                      e.preventDefault();
                      e.stopPropagation();
                      setSmartContextMenu({
                        folder: sf,
                        point: { x: e.clientX, y: e.clientY },
                      });
                    }}
                    className={[
                      'group flex items-center gap-2 px-2.5 h-[30px] rounded-[var(--radius-chip)] text-[12.5px] cursor-pointer',
                      active
                        ? 'bg-[var(--accent-soft)] text-[var(--accent)] font-medium'
                        : 'text-[var(--text-primary)] hover:bg-[var(--bg-subtle)]/80',
                    ].join(' ')}
                  >
                    <CharkleIcon
                      name="smart-folder"
                      style="duotone"
                      size={15}
                      isActive={active}
                      tintHex={sf.colorHex}
                    />
                    <span className="truncate flex-1 min-w-0">{sf.name}</span>
                    {matchCount > 0 && (
                      <span className="text-[10.5px] text-[var(--text-tertiary)] charkle-tabular group-hover:hidden">
                        {matchCount}
                      </span>
                    )}
                    <div className="hidden group-hover:flex items-center gap-0.5">
                      <button
                        type="button"
                        aria-label={`编辑智能文件夹 ${sf.name}`}
                        onClick={(e) => {
                          e.stopPropagation();
                          setEditingSmartFolder(sf);
                          setSmartModalOpen(true);
                        }}
                        className="h-5 w-5 inline-flex items-center justify-center rounded text-[var(--text-secondary)] hover:bg-[var(--bg-elevated)] cursor-pointer"
                      >
                        <Pencil size={11.5} />
                      </button>
                      <button
                        type="button"
                        aria-label={`删除智能文件夹 ${sf.name}`}
                        onClick={(e) => {
                          e.stopPropagation();
                          smartDeleteAnchorRef.current = e.currentTarget;
                          setDeletingSmartId(sf.id);
                        }}
                        className="h-5 w-5 inline-flex items-center justify-center rounded text-[var(--danger)] hover:bg-[var(--danger-soft)] cursor-pointer"
                      >
                        <Trash2 size={11.5} />
                      </button>
                    </div>
                  </div>
                );
              })
            )}
          </div>
        </section>

        <div className="h-px bg-[var(--border-hairline)] mx-1.5" />

        {/* Section 4: Hierarchical Folders */}
        <section className="flex flex-col gap-1">
          <div
            data-drop-folder-root="true"
            className={[
              'flex items-center justify-between px-2 py-0.5 rounded-[6px]',
              isDropOverFolderRoot ? 'bg-[var(--accent-soft)] ring-1 ring-[var(--accent)]' : '',
            ].join(' ')}
          >
            <span className="text-[11px] font-semibold tracking-[0.02em] text-[var(--text-tertiary)]">
              文件夹
            </span>
            <div className="flex items-center gap-0.5">
              {folders.length > 1 && (
                <button
                  ref={folderSortBtnRef}
                  type="button"
                  aria-label="排序文件夹"
                  title="排序文件夹"
                  onClick={() => setFolderSortMenuOpen((v) => !v)}
                  className="charkle-pressable h-5 w-5 inline-flex items-center justify-center rounded text-[var(--text-tertiary)] hover:text-[var(--text-primary)] hover:bg-[var(--bg-subtle)] cursor-pointer"
                >
                  <ArrowUpDown size={11.5} />
                </button>
              )}
              <button
                type="button"
                aria-label="新建文件夹"
                title="新建文件夹（也可直接拖入外部文件夹至此）"
                onClick={startCreateRootFolder}
                className="charkle-pressable h-5 w-5 inline-flex items-center justify-center rounded text-[var(--text-tertiary)] hover:text-[var(--text-primary)] hover:bg-[var(--bg-subtle)] cursor-pointer"
              >
                <Plus size={13} />
              </button>
            </div>
          </div>

          {creatingRootFolder && (
            <div className="px-1.5 py-0.5">
              <input
                type="text"
                value={rootFolderName}
                autoFocus
                placeholder="新文件夹名称…"
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
                className="w-full h-7 px-2 rounded-[var(--radius-card-inner)] bg-[var(--bg-elevated)] border border-[var(--accent)] text-[12.5px] text-[var(--text-primary)] outline-none"
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
              await updateAssets(
                { assetIDs: assetIds, folderAssignment: { folder: folderId } },
                destination,
                {
                  undoMessage: `已移动 ${assetIds.length} 项到「${targetName}」`,
                  undoPatch: { assetIDs: assetIds, folderAssignment: 'inbox' },
                },
              );
            }}
          />
        </section>

        {/* Section 5: Smart Capped Tags (1:1 macOS SidebarView.swift) */}
        {tagCounts.length > 0 && (
          <>
            <div className="h-px bg-[var(--border-hairline)] mx-1.5" />
            <section className="flex flex-col gap-0.5">
              <div className="flex items-center justify-between gap-1">
                <button
                  type="button"
                  onClick={() => setTagsExpanded((v) => !v)}
                  title={tagsExpanded ? '收起标签栏' : '展开常用标签'}
                  className="flex-1 flex items-center gap-1 px-2 py-1 rounded-[6px] hover:bg-[var(--bg-subtle)]/70 text-[11px] font-semibold tracking-[0.02em] text-[var(--text-tertiary)] cursor-pointer text-left"
                >
                  <ChevronDown
                    size={11.5}
                    className={`transition-transform duration-150 ${tagsExpanded ? '' : '-rotate-90'}`}
                  />
                  <span>标签</span>
                  <span className="font-normal charkle-tabular">{tagCounts.length}</span>
                </button>
                <button
                  ref={allTagsBtnRef}
                  type="button"
                  title={`查看并搜索全部 ${tagCounts.length} 个标签`}
                  onClick={() => setAllTagsOpen((v) => !v)}
                  className="charkle-pressable px-1.5 py-0.5 rounded-full bg-[var(--bg-subtle)] hover:bg-[var(--accent-soft)] text-[10.5px] font-medium text-[var(--text-secondary)] hover:text-[var(--accent)] cursor-pointer"
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
                      <div className="px-2.5 pt-1 pb-0.5 text-[9.5px] font-semibold text-[var(--text-tertiary)]">
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
                        <div className="px-2.5 pt-1.5 pb-0.5 text-[9.5px] font-semibold text-[var(--text-tertiary)]">
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
                      className="charkle-pressable mt-1 mx-0.5 h-[26px] px-2.5 rounded-[7px] bg-[var(--bg-subtle)]/75 hover:bg-[var(--bg-subtle)] text-[11px] font-medium text-[var(--text-secondary)] flex items-center gap-1.5 cursor-pointer"
                    >
                      <Ellipsis size={12.5} className="shrink-0" />
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

      {/* Bottom-left Settings Footer */}
      <div className="shrink-0 border-t border-[var(--border-hairline)] px-2 py-2">
        <button
          type="button"
          onClick={() => openSettings()}
          className={[
            'charkle-pressable w-full flex items-center justify-between gap-2 px-2.5 h-[32px] rounded-[var(--radius-chip)] text-[12.5px] cursor-pointer',
            settingsOpen
              ? 'bg-[var(--accent-soft)] text-[var(--accent)] font-medium'
              : 'text-[var(--text-secondary)] hover:bg-[var(--bg-subtle)] hover:text-[var(--text-primary)]',
          ].join(' ')}
        >
          <span className="inline-flex items-center gap-2">
            <Settings size={15} />
            <span>设置</span>
          </span>
          <kbd className="text-[10.5px] charkle-mono text-[var(--text-tertiary)]">Ctrl+,</kbd>
        </button>
      </div>

      {/* Folder Sort Menu Popover */}
      <Popover
        open={folderSortMenuOpen}
        onOpenChange={setFolderSortMenuOpen}
        anchorEl={folderSortBtnRef.current}
        placement="bottom-end"
        className="w-[164px] p-1"
      >
        <div className="flex flex-col gap-0.5 text-[12px]">
          <button
            type="button"
            onClick={() => void sortRootFolders('name')}
            className="charkle-pressable w-full text-left px-2.5 py-1.5 rounded-[var(--radius-popover-inner)] text-[var(--text-primary)] hover:bg-[var(--bg-subtle)] cursor-pointer"
          >
            按名称 A→Z 排序
          </button>
          <button
            type="button"
            onClick={() => void sortRootFolders('count')}
            className="charkle-pressable w-full text-left px-2.5 py-1.5 rounded-[var(--radius-popover-inner)] text-[var(--text-primary)] hover:bg-[var(--bg-subtle)] cursor-pointer"
          >
            按素材数量降序
          </button>
        </div>
      </Popover>

      {/* Inbox Context Menu (Paste Cut Assets) */}
      <Popover
        open={inboxContextPoint !== null}
        onOpenChange={(open) => {
          if (!open) setInboxContextPoint(null);
        }}
        anchorPoint={inboxContextPoint}
        className="w-[200px] p-1"
      >
        <button
          type="button"
          onClick={() => {
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
          className="charkle-pressable w-full flex items-center gap-2 px-2.5 py-1.5 rounded-[var(--radius-popover-inner)] text-[12px] text-[var(--accent)] font-medium hover:bg-[var(--accent-soft)] cursor-pointer text-left"
        >
          <ClipboardPaste size={13} />
          <span>粘贴移动至此（{cutAssetIds.length} 项）</span>
        </button>
      </Popover>

      {/* Moodboard Context Menu */}
      <Popover
        open={boardMenu !== null}
        onOpenChange={(open) => {
          if (!open) setBoardMenu(null);
        }}
        anchorPoint={boardMenu?.point ?? null}
        className="w-[216px] p-1"
      >
        {boardMenu && (
          <div className="flex flex-col gap-0.5 text-[12px]">
            <button
              type="button"
              onClick={() => {
                setActiveMoodboardId(boardMenu.id);
                pushToast({
                  message: `已锁定「${boardMenu.title}」为悬浮窗活跃情绪板`,
                  tone: 'success',
                });
                setBoardMenu(null);
              }}
              className="charkle-pressable w-full text-left px-2.5 py-1.5 rounded-[var(--radius-popover-inner)] text-[var(--text-primary)] hover:bg-[var(--bg-subtle)] cursor-pointer"
            >
              {activeMoodboardId === boardMenu.id ? '已是当前活跃情绪板' : '设为当前活跃情绪板'}
            </button>
            <button
              type="button"
              onClick={() => {
                const next = !boardMenu.pinnedOffline;
                void setBoardPinnedOffline(boardMenu.id, next);
                pushToast({
                  message: next ? '整板素材将始终保留在本地' : '已取消整板始终保留在本地',
                  tone: 'info',
                });
                setBoardMenu(null);
              }}
              className="charkle-pressable w-full text-left px-2.5 py-1.5 rounded-[var(--radius-popover-inner)] text-[var(--text-primary)] hover:bg-[var(--bg-subtle)] cursor-pointer"
            >
              {boardMenu.pinnedOffline ? '取消始终保留在本地' : '始终保留整板在本地'}
            </button>
            <div className="my-1 h-px bg-[var(--border-hairline)]" />
            <button
              type="button"
              onClick={() => {
                const id = boardMenu.id;
                setBoardMenu(null);
                if (destination.type === 'moodboard' && destination.id === id) {
                  setDestination({ type: 'moodboardsHome' });
                }
                void deleteBoard(id);
              }}
              className="charkle-pressable w-full text-left px-2.5 py-1.5 rounded-[var(--radius-popover-inner)] text-[var(--danger)] hover:bg-[var(--danger-soft)] cursor-pointer"
            >
              删除情绪板
            </button>
          </div>
        )}
      </Popover>

      {/* Smart Folder Right-Click Context Menu */}
      <Popover
        open={smartContextMenu !== null}
        onOpenChange={(open) => {
          if (!open) setSmartContextMenu(null);
        }}
        anchorPoint={smartContextMenu?.point ?? null}
        className="w-[176px] p-1"
      >
        {smartContextMenu && (
          <div className="flex flex-col gap-0.5 text-[12px]">
            <button
              type="button"
              onClick={() => {
                const sf = smartContextMenu.folder;
                setSmartContextMenu(null);
                setEditingSmartFolder(sf);
                setSmartModalOpen(true);
              }}
              className="charkle-pressable w-full flex items-center gap-2 px-2.5 py-1.5 rounded-[var(--radius-popover-inner)] text-[var(--text-primary)] hover:bg-[var(--bg-subtle)] cursor-pointer text-left"
            >
              <SlidersHorizontal size={12.5} className="text-[var(--text-secondary)]" />
              <span>编辑筛选规则…</span>
            </button>
            <div className="my-1 h-px bg-[var(--border-hairline)]" />
            <button
              type="button"
              onClick={() => {
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
              className="charkle-pressable w-full flex items-center gap-2 px-2.5 py-1.5 rounded-[var(--radius-popover-inner)] text-[var(--danger)] hover:bg-[var(--danger-soft)] cursor-pointer text-left"
            >
              <Trash2 size={12.5} />
              <span>删除智能文件夹</span>
            </button>
          </div>
        )}
      </Popover>

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
  );
};
