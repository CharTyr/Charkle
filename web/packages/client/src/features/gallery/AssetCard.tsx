import React, { useRef, useState } from 'react';
import {
  ArrowDownCircle,
  Check,
  ChevronRight,
  Copy,
  Download,
  ExternalLink,
  Eye,
  FolderInput,
  LayoutGrid,
  Palette,
  Pin,
  RotateCcw,
  Scissors,
  Sparkles,
  Star,
  Trash2,
} from 'lucide-react';
import { createDefaultAssetBatchPatch } from '@charkle/shared';
import type { AssetRecord, UUID } from '@charkle/shared';
import { apiClient } from '../../api/client';
import { HoverMediaPreview, stopAllHoverPreviews } from '../../components/HoverMediaPreview';
import {
  ConfirmDialog,
  FolderHierarchyMenu,
  Popover,
  usePresence,
  useSafeTriangleSubmenu,
} from '../../design-system';
import { useCoordinatorStore } from '../../stores/coordinatorStore';
import { useLibraryStore } from '../../stores/libraryStore';
import { useMoodboardStore } from '../../stores/moodboardStore';
import { getCardMediaBadge, isColorSwatchAsset } from './assetCardUtils';

export interface AssetCardProps {
  asset: AssetRecord;
  selected: boolean;
  isCut?: boolean;
  isExiting?: boolean;
  isSpotlighted?: boolean;
  cacheBust: number;
  style?: React.CSSProperties;
  className?: string;
  cardRef?: (el: HTMLDivElement | null) => void;
  onSelect: (id: UUID, e: React.MouseEvent) => void;
  onDoubleClick?: (asset: AssetRecord, rect: DOMRect) => void;
}

const ContextSubmenuShell: React.FC<{
  open: boolean;
  side: 'left' | 'right';
  panelRef: React.MutableRefObject<HTMLDivElement | null>;
  onMouseEnter: () => void;
  children: React.ReactNode;
}> = ({ open, side, panelRef, onMouseEnter, children }) => {
  const { rendered, state } = usePresence(open, 115);
  if (!rendered) return null;
  return (
    <div
      ref={(el) => {
        if (open) panelRef.current = el;
      }}
      data-state={state}
      onMouseEnter={onMouseEnter}
      style={{ transformOrigin: side === 'left' ? 'top right' : 'top left' }}
      className={[
        'charkle-popover-transition absolute top-0 z-30 rounded-[var(--radius-popover-outer)] bg-[var(--bg-elevated)] border border-[var(--border-strong)] shadow-xl',
        state === 'closing' ? 'pointer-events-none' : '',
        side === 'left'
          ? 'right-full mr-1 before:content-[""] before:absolute before:inset-y-0 before:-right-2 before:w-2.5'
          : 'left-full ml-1 before:content-[""] before:absolute before:inset-y-0 before:-left-2 before:w-2.5',
      ].join(' ')}
    >
      {children}
    </div>
  );
};

export const AssetCard: React.FC<AssetCardProps> = React.memo(
  ({
    asset,
    selected,
    isCut = false,
    isExiting = false,
    isSpotlighted = false,
    cacheBust,
    style,
    className = '',
    cardRef,
    onSelect,
    onDoubleClick,
  }) => {
    const localCardRef = useRef<HTMLDivElement | null>(null);
    const [imgError, setImgError] = useState(false);
    const [hovered, setHovered] = useState(false);
    const [hoverPlaying, setHoverPlaying] = useState(false);
    const [contextPoint, setContextPoint] = useState<{ x: number; y: number } | null>(null);
    const [confirmDeleteIDs, setConfirmDeleteIDs] = useState<UUID[] | null>(null);

    const openQuickLook = useCoordinatorStore((s) => s.openQuickLook);
    const openGeneratorModal = useCoordinatorStore((s) => s.openGeneratorModal);
    const activeBoardID = useCoordinatorStore((s) => s.activeBoardID);
    const pushToast = useCoordinatorStore((s) => s.pushToast);
    const isHiddenForHero = useCoordinatorStore((s) => s.quickLookHiddenAssetID === asset.id);

    const selectedAssetIDs = useLibraryStore((s) => s.selectedAssetIDs);
    const folders = useLibraryStore((s) => s.folders);
    const batchPatch = useLibraryStore((s) => s.batchPatch);
    const setCutAssetIDs = useLibraryStore((s) => s.setCutAssetIDs);
    const trashAssets = useLibraryStore((s) => s.trashAssets);
    const restoreAssets = useLibraryStore((s) => s.restoreAssets);
    const permanentlyDeleteAssets = useLibraryStore((s) => s.permanentlyDeleteAssets);
    const upsertAssets = useLibraryStore((s) => s.upsertAssets);

    const boards = useMoodboardStore((s) => s.boards);
    const addAssetsToBoard = useMoodboardStore((s) => s.addAssetsToBoard);

    const badge = getCardMediaBadge(asset);
    const isVisual =
      asset.mediaKind === 'image' ||
      asset.mediaKind === 'animatedImage' ||
      asset.mediaKind === 'video';
    const isSwatch = isColorSwatchAsset(asset);
    const primaryHex = asset.dominantColors[0]?.hex;

    const submenuSide: 'left' | 'right' =
      contextPoint && typeof window !== 'undefined' && contextPoint.x + 440 > window.innerWidth
        ? 'left'
        : 'right';

    const {
      openKey: activeSubmenu,
      setOpenKey: setActiveSubmenu,
      submenuElRef,
      recordPointer,
      requestOpen: requestSubmenu,
      cancelPendingClose,
      closeImmediately: closeSubmenu,
    } = useSafeTriangleSubmenu<'boards' | 'folders'>(submenuSide, 145);

    const handleOpenQL = (e?: React.MouseEvent) => {
      stopAllHoverPreviews();
      const cardEl =
        localCardRef.current ??
        ((e?.currentTarget as HTMLElement | undefined)?.closest(
          '[data-asset-card-id]',
        ) as HTMLElement | null);
      const rect = cardEl?.getBoundingClientRect();
      if (rect && onDoubleClick) {
        onDoubleClick(asset, rect);
      } else {
        openQuickLook(
          asset.id,
          rect
            ? {
                left: rect.left,
                top: rect.top,
                width: rect.width,
                height: rect.height,
              }
            : null,
        );
      }
    };

    const handleDragStart = (e: React.DragEvent) => {
      stopAllHoverPreviews();
      const dragIDs =
        selected && selectedAssetIDs.size > 0 ? Array.from(selectedAssetIDs) : [asset.id];
      const payload = JSON.stringify(dragIDs);
      e.dataTransfer.setData('application/x-charkle-assets', payload);
      e.dataTransfer.setData('application/x-charkle-asset-ids', payload);
      e.dataTransfer.effectAllowed = 'copyMove';
    };

    const targetIDs: UUID[] =
      selected && selectedAssetIDs.size > 0 ? Array.from(selectedAssetIDs) : [asset.id];
    const countSuffix = targetIDs.length > 1 ? ` (${targetIDs.length} 项)` : '';

    const closeMenu = () => {
      setContextPoint(null);
      closeSubmenu();
    };

    const handleAIAnalyze = async (ids: UUID[]) => {
      pushToast({ tone: 'info', message: `正在分析 ${ids.length} 项素材…` });
      try {
        const res = await apiClient.analyzeAssets({ ids });
        if (res.assets?.length) {
          upsertAssets(res.assets);
        }
        pushToast({ tone: 'success', message: `已完成 ${ids.length} 项 AI 打标` });
      } catch (err) {
        pushToast({
          tone: 'error',
          message: err instanceof Error ? err.message : 'AI 重新打标失败',
        });
      }
    };

    return (
      <>
        <div
          ref={(el) => {
            localCardRef.current = el;
            cardRef?.(el);
          }}
          data-asset-card-id={asset.id}
          draggable
          onMouseEnter={() => setHovered(true)}
          onMouseLeave={() => {
            setHovered(false);
            setHoverPlaying(false);
          }}
          onMouseDown={() => stopAllHoverPreviews()}
          onDragStart={handleDragStart}
          onClick={(e) => {
            e.stopPropagation();
            onSelect(asset.id, e);
          }}
          onDoubleClick={handleOpenQL}
          onContextMenu={(e) => {
            e.preventDefault();
            e.stopPropagation();
            stopAllHoverPreviews();
            if (!selected) {
              onSelect(asset.id, e);
            }
            closeSubmenu();
            setContextPoint({ x: e.clientX, y: e.clientY });
          }}
          style={{
            ...style,
            opacity: isHiddenForHero ? 0 : style?.opacity,
          }}
          className={[
            'group relative overflow-hidden rounded-[var(--radius-card-outer)] bg-[var(--bg-subtle)] select-none cursor-pointer',
            'transition-[box-shadow,opacity] duration-[150ms] ease-[var(--ease-out)]',
            selected
              ? 'ring-[2.5px] ring-[var(--accent)] ring-offset-2 ring-offset-[var(--bg-gallery)]'
              : 'ring-1 ring-[var(--border-hairline)] hover:ring-[var(--border-strong)]',
            isCut ? 'opacity-50 outline-2 outline-dashed outline-[var(--accent)] outline-offset-1' : '',
            isExiting ? 'charkle-card-exiting' : '',
            isSpotlighted ? 'charkle-reveal-spotlight z-30' : '',
            className,
          ].join(' ')}
        >
          {/* Artwork Surface */}
          {isSwatch && primaryHex ? (
            <div
              className="w-full h-full flex flex-col items-end justify-end p-3"
              style={{ backgroundColor: primaryHex }}
            >
              <span className="px-2 py-0.5 rounded-[var(--radius-card-inner)] bg-black/35 backdrop-blur-xs text-[11px] font-mono font-medium text-white">
                {primaryHex}
              </span>
            </div>
          ) : !imgError ? (
            <>
              <img
                src={apiClient.thumbnailURL(asset.id, 'grid520', `${asset.updatedAt}-${cacheBust}`)}
                alt={asset.title}
                loading="lazy"
                decoding="async"
                draggable={false}
                onError={() => setImgError(true)}
                className="charkle-media-zoom w-full h-full object-cover block"
              />
              <HoverMediaPreview
                asset={asset}
                active={hovered && !isExiting && !isHiddenForHero}
                fit="cover"
                roundedClass="rounded-[var(--radius-card-outer)]"
                badgePosition="top-right"
                onRevealChange={setHoverPlaying}
              />
            </>
          ) : (
            <div
              className="w-full h-full flex flex-col items-center justify-center p-4 text-center gap-2"
              style={{
                backgroundColor: primaryHex ? `${primaryHex}22` : 'var(--bg-subtle)',
              }}
            >
              {asset.mediaKind === 'audio' ? (
                <div className="flex items-end gap-[2.5px] h-10 w-full max-w-[140px] justify-center">
                  {(asset.waveformPeaks.length > 0
                    ? asset.waveformPeaks.slice(0, 24)
                    : Array.from(
                        { length: 24 },
                        (_, i) => 0.25 + 0.65 * Math.abs(Math.sin(i * 0.45)),
                      )
                  ).map((p, idx) => (
                    <span
                      key={idx}
                      className="w-[3px] rounded-full bg-[var(--accent)]/75"
                      style={{ height: `${Math.max(18, Math.round(p * 100))}%` }}
                    />
                  ))}
                </div>
              ) : (
                <span className="text-[11px] font-mono uppercase tracking-wider px-2 py-0.5 rounded bg-[var(--bg-elevated)] text-[var(--text-secondary)]">
                  {badge || asset.mediaKind}
                </span>
              )}
              <span className="text-[12px] font-medium text-[var(--text-primary)] line-clamp-2">
                {asset.title}
              </span>
            </div>
          )}

          {/* Top-left Circular Checkbox (32x32 hit area, 22x22 circle) */}
          <button
            type="button"
            aria-label={selected ? '取消选中' : '选中素材'}
            onClick={(e) => {
              e.stopPropagation();
              onSelect(asset.id, { ...e, metaKey: true } as React.MouseEvent);
            }}
            className={[
              'absolute top-0.5 left-0.5 h-8 w-8 flex items-center justify-center z-10 cursor-pointer',
              'transition-opacity duration-[140ms] ease-[var(--ease-out)]',
              selected ? 'opacity-100' : 'opacity-0 group-hover:opacity-100 group-focus-within:opacity-100',
            ].join(' ')}
          >
            <span
              className={[
                'h-[22px] w-[22px] rounded-full flex items-center justify-center border shadow-xs',
                selected
                  ? 'bg-[var(--accent)] border-white/80 text-white charkle-micro-pop'
                  : 'bg-black/38 border-white/70 text-transparent backdrop-blur-xs hover:bg-black/55',
              ].join(' ')}
            >
              <Check size={12} strokeWidth={2.75} />
            </span>
          </button>

          {/* Top-right Badges */}
          <div
            className={[
              'absolute top-1.5 right-1.5 flex items-center gap-1 z-10 pointer-events-none transition-opacity duration-[150ms] ease-[var(--ease-out)]',
              hoverPlaying && asset.mediaKind === 'video' ? 'opacity-0' : 'opacity-100',
            ].join(' ')}
          >
            {asset.pinnedOffline && (
              <span
                title="已保留离线副本"
                className="h-5 w-5 rounded-[var(--radius-card-inner)] bg-black/52 backdrop-blur-xs text-white flex items-center justify-center"
              >
                <ArrowDownCircle size={11} />
              </span>
            )}
            {badge && (
              <span className="px-1.5 py-0.5 rounded-[var(--radius-card-inner)] bg-black/58 backdrop-blur-xs text-[10px] font-semibold tracking-wide text-white leading-none">
                {badge}
              </span>
            )}
          </div>

          {/* Hover Quick Look button + subtle bottom caption gradient */}
          <div className="pointer-events-none absolute inset-x-0 bottom-0 opacity-0 group-hover:opacity-100 group-focus-within:opacity-100 transition-opacity duration-[160ms] ease-[var(--ease-out)]">
            <div
              className="flex items-end justify-between gap-2 px-2.5 pb-2 pt-5"
              style={{
                background: isVisual
                  ? 'linear-gradient(180deg, rgba(0,0,0,0) 0%, rgba(0,0,0,0.66) 100%)'
                  : 'linear-gradient(180deg, rgba(0,0,0,0) 0%, rgba(0,0,0,0.52) 100%)',
              }}
            >
              <div className="min-w-0 flex items-center gap-1.5">
                <span className="text-[11.5px] font-medium text-white truncate drop-shadow-xs">
                  {asset.title}
                </span>
                {asset.rating > 0 && (
                  <span className="inline-flex items-center gap-0.5 text-[11px] font-semibold text-[#F2C14E] shrink-0">
                    <Star size={10} className="fill-[#F2C14E] text-[#F2C14E]" />
                    {asset.rating}
                  </span>
                )}
              </div>
              <button
                type="button"
                title="快速预览 (Space)"
                onClick={(e) => {
                  e.stopPropagation();
                  handleOpenQL(e);
                }}
                className="pointer-events-auto charkle-pressable h-6 w-6 rounded-[var(--radius-card-inner)] bg-black/52 hover:bg-black/75 text-white flex items-center justify-center shrink-0 cursor-pointer"
              >
                <Eye size={12} />
              </button>
            </div>
          </div>
        </div>

        {/* Right-Click Context Menu with Safe-Triangle Cascading Submenus */}
        <Popover
          open={Boolean(contextPoint)}
          onOpenChange={(open) => {
            if (!open) closeMenu();
          }}
          anchorPoint={contextPoint}
          glass={false}
        >
          {contextPoint && (
            <div
              role="menu"
              onMouseMove={recordPointer}
              className="w-[228px] p-1.5 flex flex-col gap-0.5 text-[12.5px] text-[var(--text-primary)] select-none"
            >
              <button
                type="button"
                role="menuitem"
                onMouseEnter={(e) => requestSubmenu(null, e)}
                onClick={() => {
                  closeMenu();
                  handleOpenQL();
                }}
                className="w-full px-2.5 py-1.5 rounded-[var(--radius-popover-inner)] flex items-center gap-2 hover:bg-[var(--bg-subtle)] cursor-pointer text-left"
              >
                <Eye size={13.5} className="text-[var(--text-secondary)] shrink-0" />
                <span className="flex-1">快速预览</span>
                <span className="text-[11px] font-mono text-[var(--text-tertiary)]">Space</span>
              </button>

              {asset.sourceURL && (
                <a
                  href={asset.sourceURL}
                  target="_blank"
                  rel="noopener noreferrer"
                  onMouseEnter={(e) => requestSubmenu(null, e)}
                  onClick={closeMenu}
                  className="w-full px-2.5 py-1.5 rounded-[var(--radius-popover-inner)] flex items-center gap-2 hover:bg-[var(--bg-subtle)] cursor-pointer text-left"
                >
                  <ExternalLink size={13.5} className="text-[var(--text-secondary)] shrink-0" />
                  <span>打开来源网页</span>
                </a>
              )}

              <div className="my-1 border-t border-[var(--border-hairline)]" />

              <button
                type="button"
                role="menuitem"
                onMouseEnter={(e) => requestSubmenu(null, e)}
                onClick={async () => {
                  closeMenu();
                  const text = asset.sourceURL || asset.title || asset.fileName;
                  await navigator.clipboard.writeText(text).catch(() => {});
                  pushToast({ tone: 'info', message: `已复制「${asset.title}」` });
                }}
                className="w-full px-2.5 py-1.5 rounded-[var(--radius-popover-inner)] flex items-center gap-2 hover:bg-[var(--bg-subtle)] cursor-pointer text-left"
              >
                <Copy size={13.5} className="text-[var(--text-secondary)] shrink-0" />
                <span>复制名称或链接</span>
              </button>

              {primaryHex && (
                <button
                  type="button"
                  role="menuitem"
                  onMouseEnter={(e) => requestSubmenu(null, e)}
                  onClick={async () => {
                    closeMenu();
                    await navigator.clipboard.writeText(primaryHex).catch(() => {});
                    pushToast({ tone: 'info', message: `已复制主色 ${primaryHex}` });
                  }}
                  className="w-full px-2.5 py-1.5 rounded-[var(--radius-popover-inner)] flex items-center gap-2 hover:bg-[var(--bg-subtle)] cursor-pointer text-left"
                >
                  <Palette size={13.5} className="text-[var(--text-secondary)] shrink-0" />
                  <span className="flex-1">复制主色 {primaryHex}</span>
                  <span
                    className="h-3 w-3 rounded-full border border-black/15 shrink-0"
                    style={{ backgroundColor: primaryHex }}
                  />
                </button>
              )}

              {!asset.isTrashed && (
                <button
                  type="button"
                  role="menuitem"
                  onMouseEnter={(e) => requestSubmenu(null, e)}
                  onClick={() => {
                    closeMenu();
                    setCutAssetIDs(targetIDs);
                    pushToast({
                      tone: 'info',
                      message: `已剪切 ${targetIDs.length} 项素材`,
                    });
                  }}
                  className="w-full px-2.5 py-1.5 rounded-[var(--radius-popover-inner)] flex items-center gap-2 hover:bg-[var(--bg-subtle)] cursor-pointer text-left"
                >
                  <Scissors size={13.5} className="text-[var(--text-secondary)] shrink-0" />
                  <span>剪切{countSuffix}</span>
                </button>
              )}

              <a
                href={apiClient.originalMediaURL(asset.id, { download: true })}
                download={asset.fileName}
                onMouseEnter={(e) => requestSubmenu(null, e)}
                onClick={closeMenu}
                className="w-full px-2.5 py-1.5 rounded-[var(--radius-popover-inner)] flex items-center gap-2 hover:bg-[var(--bg-subtle)] cursor-pointer text-left"
              >
                <Download size={13.5} className="text-[var(--text-secondary)] shrink-0" />
                <span>下载原文件</span>
              </a>

              <div className="my-1 border-t border-[var(--border-hairline)]" />

              {!asset.isTrashed ? (
                <>
                  <button
                    type="button"
                    role="menuitem"
                    onMouseEnter={(e) => requestSubmenu(null, e)}
                    onClick={async () => {
                      closeMenu();
                      const boardID = activeBoardID ?? boards[0]?.id ?? null;
                      if (!boardID) {
                        openGeneratorModal(targetIDs);
                        return;
                      }
                      await addAssetsToBoard(boardID, targetIDs);
                      const boardTitle = boards.find((b) => b.id === boardID)?.title || '情绪板';
                      pushToast({ tone: 'success', message: `已加入「${boardTitle}」` });
                    }}
                    className="w-full px-2.5 py-1.5 rounded-[var(--radius-popover-inner)] flex items-center gap-2 hover:bg-[var(--bg-subtle)] cursor-pointer text-left"
                  >
                    <LayoutGrid size={13.5} className="text-[var(--text-secondary)] shrink-0" />
                    <span>加入情绪板{countSuffix}</span>
                  </button>

                  {/* Cascading Join Specific Moodboard Submenu */}
                  <div
                    className="relative"
                    onMouseEnter={(e) => requestSubmenu('boards', e)}
                  >
                    <button
                      type="button"
                      role="menuitem"
                      aria-haspopup="menu"
                      aria-expanded={activeSubmenu === 'boards'}
                      onClick={(e) => {
                        e.stopPropagation();
                        setActiveSubmenu((cur) => (cur === 'boards' ? null : 'boards'));
                      }}
                      className={[
                        'w-full px-2.5 py-1.5 rounded-[var(--radius-popover-inner)] flex items-center gap-2 cursor-pointer text-left',
                        activeSubmenu === 'boards'
                          ? 'bg-[var(--bg-subtle)]'
                          : 'hover:bg-[var(--bg-subtle)]',
                      ].join(' ')}
                    >
                      <LayoutGrid size={13.5} className="text-[var(--text-secondary)] shrink-0" />
                      <span className="flex-1 truncate">加入指定情绪板</span>
                      <ChevronRight size={13} className="text-[var(--text-tertiary)] shrink-0" />
                    </button>

                    <ContextSubmenuShell
                      open={activeSubmenu === 'boards'}
                      side={submenuSide}
                      panelRef={submenuElRef}
                      onMouseEnter={cancelPendingClose}
                    >
                      <div className="w-[200px] max-h-[240px] overflow-y-auto charkle-scroll p-1.5 flex flex-col gap-0.5">
                        {boards.length === 0 ? (
                          <div className="px-2.5 py-2 text-[12px] text-[var(--text-tertiary)]">
                            暂无情绪板
                          </div>
                        ) : (
                          boards.map((board) => (
                            <button
                              key={board.id}
                              type="button"
                              role="menuitem"
                              onClick={async () => {
                                closeMenu();
                                await addAssetsToBoard(board.id, targetIDs);
                                pushToast({
                                  tone: 'success',
                                  message: `已加入「${board.title}」`,
                                });
                              }}
                              className="w-full px-2.5 py-1.5 rounded-[var(--radius-popover-inner)] text-left truncate hover:bg-[var(--bg-subtle)] cursor-pointer"
                            >
                              {board.title}
                            </button>
                          ))
                        )}
                      </div>
                    </ContextSubmenuShell>
                  </div>

                  <button
                    type="button"
                    role="menuitem"
                    onMouseEnter={(e) => requestSubmenu(null, e)}
                    onClick={() => {
                      closeMenu();
                      openGeneratorModal(targetIDs);
                    }}
                    className="w-full px-2.5 py-1.5 rounded-[var(--radius-popover-inner)] flex items-center gap-2 hover:bg-[var(--bg-subtle)] cursor-pointer text-left"
                  >
                    <Sparkles size={13.5} className="text-[var(--accent)] shrink-0" />
                    <span>以此生成情绪板{countSuffix}</span>
                  </button>

                  {/* Cascading Move to Folder Submenu */}
                  <div
                    className="relative"
                    onMouseEnter={(e) => requestSubmenu('folders', e)}
                  >
                    <button
                      type="button"
                      role="menuitem"
                      aria-haspopup="menu"
                      aria-expanded={activeSubmenu === 'folders'}
                      onClick={(e) => {
                        e.stopPropagation();
                        setActiveSubmenu((cur) => (cur === 'folders' ? null : 'folders'));
                      }}
                      className={[
                        'w-full px-2.5 py-1.5 rounded-[var(--radius-popover-inner)] flex items-center gap-2 cursor-pointer text-left',
                        activeSubmenu === 'folders'
                          ? 'bg-[var(--bg-subtle)]'
                          : 'hover:bg-[var(--bg-subtle)]',
                      ].join(' ')}
                    >
                      <FolderInput size={13.5} className="text-[var(--text-secondary)] shrink-0" />
                      <span className="flex-1 truncate">移动到文件夹</span>
                      <ChevronRight size={13} className="text-[var(--text-tertiary)] shrink-0" />
                    </button>

                    <ContextSubmenuShell
                      open={activeSubmenu === 'folders'}
                      side={submenuSide}
                      panelRef={submenuElRef}
                      onMouseEnter={cancelPendingClose}
                    >
                      <FolderHierarchyMenu
                        folders={folders}
                        includeInbox
                        selectedFolderID={targetIDs.length === 1 ? asset.folderID ?? null : null}
                        highlightSelection={targetIDs.length === 1}
                        parentSelfPrefix="放入"
                        submenuSide={submenuSide}
                        onSelectFolder={(folderID) => {
                          closeMenu();
                          void batchPatch(
                            createDefaultAssetBatchPatch(targetIDs, {
                              folderAssignment: folderID
                                ? { type: 'folder', folderID }
                                : { type: 'inbox' },
                            }),
                          );
                          const label = folderID
                            ? folders.find((f) => f.id === folderID)?.name ?? '文件夹'
                            : '收件箱';
                          pushToast({
                            tone: 'success',
                            message: `已移动 ${targetIDs.length} 项到「${label}」`,
                          });
                        }}
                      />
                    </ContextSubmenuShell>
                  </div>

                  <button
                    type="button"
                    role="menuitem"
                    onMouseEnter={(e) => requestSubmenu(null, e)}
                    onClick={() => {
                      closeMenu();
                      const nextPinned = !asset.pinnedOffline;
                      void batchPatch(
                        createDefaultAssetBatchPatch(targetIDs, { pinnedOffline: nextPinned }),
                      );
                      pushToast({
                        tone: 'info',
                        message: nextPinned ? '已保留离线副本' : '已取消离线保留',
                      });
                    }}
                    className="w-full px-2.5 py-1.5 rounded-[var(--radius-popover-inner)] flex items-center gap-2 hover:bg-[var(--bg-subtle)] cursor-pointer text-left"
                  >
                    <Pin size={13.5} className="text-[var(--text-secondary)] shrink-0" />
                    <span>{asset.pinnedOffline ? '取消离线保留' : '保留离线副本'}</span>
                  </button>

                  <button
                    type="button"
                    role="menuitem"
                    onMouseEnter={(e) => requestSubmenu(null, e)}
                    onClick={() => {
                      closeMenu();
                      void handleAIAnalyze(targetIDs);
                    }}
                    className="w-full px-2.5 py-1.5 rounded-[var(--radius-popover-inner)] flex items-center gap-2 hover:bg-[var(--bg-subtle)] cursor-pointer text-left"
                  >
                    <Sparkles size={13.5} className="text-[var(--text-secondary)] shrink-0" />
                    <span>AI 重新打标{countSuffix}</span>
                  </button>

                  <div className="my-1 border-t border-[var(--border-hairline)]" />

                  <button
                    type="button"
                    role="menuitem"
                    onMouseEnter={(e) => requestSubmenu(null, e)}
                    onClick={() => {
                      closeMenu();
                      void trashAssets(targetIDs);
                    }}
                    className="w-full px-2.5 py-1.5 rounded-[var(--radius-popover-inner)] flex items-center gap-2 hover:bg-[var(--danger-soft)] text-[var(--danger)] cursor-pointer text-left"
                  >
                    <Trash2 size={13.5} className="shrink-0" />
                    <span>移入回收站{countSuffix}</span>
                  </button>
                </>
              ) : (
                <>
                  <button
                    type="button"
                    role="menuitem"
                    onMouseEnter={(e) => requestSubmenu(null, e)}
                    onClick={() => {
                      closeMenu();
                      void restoreAssets(targetIDs);
                    }}
                    className="w-full px-2.5 py-1.5 rounded-[var(--radius-popover-inner)] flex items-center gap-2 hover:bg-[var(--bg-subtle)] cursor-pointer text-left"
                  >
                    <RotateCcw size={13.5} className="text-[var(--text-secondary)] shrink-0" />
                    <span>恢复素材{countSuffix}</span>
                  </button>

                  <button
                    type="button"
                    role="menuitem"
                    onMouseEnter={(e) => requestSubmenu(null, e)}
                    onClick={() => {
                      closeMenu();
                      setConfirmDeleteIDs(targetIDs);
                    }}
                    className="w-full px-2.5 py-1.5 rounded-[var(--radius-popover-inner)] flex items-center gap-2 hover:bg-[var(--danger-soft)] text-[var(--danger)] cursor-pointer text-left"
                  >
                    <Trash2 size={13.5} className="shrink-0" />
                    <span>彻底删除{countSuffix}</span>
                  </button>
                </>
              )}
            </div>
          )}
        </Popover>

        {/* Confirmed Permanent Delete Dialog */}
        <ConfirmDialog
          open={Boolean(confirmDeleteIDs && confirmDeleteIDs.length > 0)}
          onClose={() => setConfirmDeleteIDs(null)}
          title={
            confirmDeleteIDs && confirmDeleteIDs.length > 1
              ? `彻底删除 ${confirmDeleteIDs.length} 项素材？`
              : `彻底删除「${asset.title}」？`
          }
          description="删除后将永久移除文件且无法恢复。"
          confirmLabel="彻底删除"
          onConfirm={async () => {
            if (!confirmDeleteIDs || confirmDeleteIDs.length === 0) return;
            await permanentlyDeleteAssets(confirmDeleteIDs);
            pushToast({ tone: 'info', message: `已彻底删除 ${confirmDeleteIDs.length} 项素材` });
          }}
        />
      </>
    );
  },
);

AssetCard.displayName = 'AssetCard';
