import React, { useCallback, useEffect, useMemo, useRef, useState } from 'react';
import {
  ChevronLeft,
  ChevronRight,
  Copy,
  Download,
  ExternalLink,
  Eye,
  FlipHorizontal2,
  FlipVertical2,
  FolderInput,
  LayoutGrid,
  Maximize2,
  Pin,
  RotateCcw,
  RotateCw,
  Scissors,
  ScrollText,
  Sparkles,
  Star,
  Trash2,
  Undo2,
  ZoomIn,
  ZoomOut,
} from 'lucide-react';
import { createDefaultAssetBatchPatch, getAssetDisplayTypeLabel } from '@charkle/shared';
import type { AssetRecord, UUID } from '@charkle/shared';
import { apiClient } from '../../api/client';
import {
  HoverMediaPreview,
  notifyLiveScrolling,
  stopAllHoverPreviews,
} from '../../components/HoverMediaPreview';
import {
  Button,
  ConfirmDialog,
  FolderHierarchyMenu,
  formatBytes,
  Popover,
  prefersReducedMotion,
  usePresence,
  useSafeTriangleSubmenu,
} from '../../design-system';
import { useCoordinatorStore } from '../../stores/coordinatorStore';
import { useLibraryStore } from '../../stores/libraryStore';
import { useMoodboardStore } from '../../stores/moodboardStore';
import { isEditableElement } from '../capture/captureUtils';
import { AudioStudioViewer } from '../quicklook/AudioStudioViewer';
import { DocumentMarkdownViewer } from '../quicklook/DocumentMarkdownViewer';
import { GitHubRepoViewer } from '../quicklook/GitHubRepoViewer';
import {
  classifyAssetViewerKind,
  ColorSwatchViewer,
  computeDynamicMaxZoom,
  computeQuarterTurnFitScale,
  computeWheelZoomFactor,
  Delayed3DStagePlaceholder,
  isTallStripDimensions,
  LazyModel3DViewer,
  supportsVisualTransform,
  useHorizontalWheelRedirect,
  WebBookmarkViewer,
} from '../quicklook/MediaStageHelpers';
import { SocialPostViewer } from '../quicklook/SocialPostViewer';
import { getCardEffectiveAspectRatio } from './assetCardUtils';

export interface GalleryFilmstripViewProps {
  assets: AssetRecord[];
}

interface ContextMenuState {
  asset: AssetRecord;
  x: number;
  y: number;
}

const FilmstripSubmenuShell: React.FC<{
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

export const GalleryFilmstripView: React.FC<GalleryFilmstripViewProps> = ({ assets }) => {
  const selectedAssetIDs = useLibraryStore((s) => s.selectedAssetIDs);
  const selectAsset = useLibraryStore((s) => s.selectAsset);
  const batchPatch = useLibraryStore((s) => s.batchPatch);
  const markOpened = useLibraryStore((s) => s.markOpened);
  const cacheBust = useLibraryStore((s) => s.cacheBustVersion);
  const folders = useLibraryStore((s) => s.folders);
  const setCutAssetIDs = useLibraryStore((s) => s.setCutAssetIDs);
  const trashAssets = useLibraryStore((s) => s.trashAssets);
  const restoreAssets = useLibraryStore((s) => s.restoreAssets);
  const permanentlyDeleteAssets = useLibraryStore((s) => s.permanentlyDeleteAssets);
  const upsertAssets = useLibraryStore((s) => s.upsertAssets);

  const openQuickLook = useCoordinatorStore((s) => s.openQuickLook);
  const openGeneratorModal = useCoordinatorStore((s) => s.openGeneratorModal);
  const activeBoardID = useCoordinatorStore((s) => s.activeBoardID);
  const pushToast = useCoordinatorStore((s) => s.pushToast);
  const pendingGalleryReveal = useCoordinatorStore((s) => s.pendingGalleryReveal);
  const clearPendingGalleryReveal = useCoordinatorStore((s) => s.clearPendingGalleryReveal);

  const boards = useMoodboardStore((s) => s.boards);
  const addAssetsToBoard = useMoodboardStore((s) => s.addAssetsToBoard);

  const stripRef = useRef<HTMLDivElement | null>(null);
  const stageRef = useRef<HTMLDivElement | null>(null);
  const longStripUserOverrideRef = useRef(false);

  const [zoom, setZoom] = useState(1);
  const [pan, setPan] = useState({ x: 0, y: 0 });
  const [rotation, setRotation] = useState(0);
  const [flipH, setFlipH] = useState(false);
  const [flipV, setFlipV] = useState(false);
  const [draggingPan, setDraggingPan] = useState(false);
  const [stageSize, setStageSize] = useState({ width: 0, height: 0 });
  const [naturalSize, setNaturalSize] = useState<{ width: number; height: number } | null>(null);
  const [originalFailedID, setOriginalFailedID] = useState<UUID | null>(null);
  const [isLongStripScrollMode, setIsLongStripScrollMode] = useState(false);
  const [hoveredThumbID, setHoveredThumbID] = useState<UUID | null>(null);
  const [poppedStar, setPoppedStar] = useState<{ assetID: UUID; star: number; seq: number } | null>(
    null,
  );
  const [contextMenu, setContextMenu] = useState<ContextMenuState | null>(null);
  const [confirmDelete, setConfirmDelete] = useState<{ ids: UUID[]; label: string } | null>(null);
  const [spotlightAssetID, setSpotlightAssetID] = useState<UUID | null>(null);

  const panOriginRef = useRef({ x: 0, y: 0, panX: 0, panY: 0 });

  const activeIndex = useMemo(() => {
    if (assets.length === 0) return -1;
    for (const id of selectedAssetIDs) {
      const idx = assets.findIndex((a) => a.id === id);
      if (idx >= 0) return idx;
    }
    return 0;
  }, [assets, selectedAssetIDs]);

  const activeAsset = activeIndex >= 0 ? assets[activeIndex] : null;
  const activeAssetID = activeAsset?.id ?? null;
  const viewerKind = activeAsset ? classifyAssetViewerKind(activeAsset) : 'visual';
  const isTransformable = activeAsset ? supportsVisualTransform(activeAsset) : false;

  const effWidth = naturalSize?.width || activeAsset?.pixelWidth || 0;
  const effHeight = naturalSize?.height || activeAsset?.pixelHeight || 0;
  const maxZoomLimit = useMemo(
    () => computeDynamicMaxZoom(effWidth, effHeight),
    [effWidth, effHeight],
  );
  const isTallStripImage = Boolean(
    activeAsset &&
      isTransformable &&
      activeAsset.mediaKind !== 'animatedImage' &&
      isTallStripDimensions(effWidth, effHeight),
  );

  const submenuSide: 'left' | 'right' =
    contextMenu && typeof window !== 'undefined' && contextMenu.x + 440 > window.innerWidth
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

  const closeMenu = useCallback(() => {
    setContextMenu(null);
    closeSubmenu();
  }, [closeSubmenu]);

  const resetTransforms = useCallback(() => {
    setZoom(1);
    setPan({ x: 0, y: 0 });
    setRotation(0);
    setFlipH(false);
    setFlipV(false);
  }, []);

  const applyZoomMultiplier = useCallback(
    (factor: number) => {
      setIsLongStripScrollMode(false);
      longStripUserOverrideRef.current = true;
      setZoom((z) => {
        const next = Math.max(0.5, Math.min(maxZoomLimit, Number((z * factor).toFixed(3))));
        if (next <= 1.01) {
          setPan({ x: 0, y: 0 });
        }
        return next;
      });
    },
    [maxZoomLimit],
  );

  // Shortest-arc cumulative rotation (90 -> 180 -> 270 -> 360, never spinning backwards -270°)
  const rotateByScreenDelta = useCallback(
    (screenDelta: number) => {
      setIsLongStripScrollMode(false);
      longStripUserOverrideRef.current = true;
      const parity = flipH !== flipV ? -1 : 1;
      setRotation((r) => r + screenDelta * parity);
    },
    [flipH, flipV],
  );

  // Auto-reset transforms & scroll active thumbnail into view when active asset changes
  useEffect(() => {
    resetTransforms();
    setNaturalSize(null);
    setOriginalFailedID(null);
    longStripUserOverrideRef.current = false;
    setIsLongStripScrollMode(false);
    if (!activeAssetID) return;
    void markOpened(activeAssetID);
    const thumbEl = stripRef.current?.querySelector<HTMLElement>(
      `[data-filmstrip-id="${activeAssetID}"]`,
    );
    thumbEl?.scrollIntoView({
      behavior: prefersReducedMotion() ? 'auto' : 'smooth',
      inline: 'center',
      block: 'nearest',
    });
  }, [activeAssetID, markOpened, resetTransforms]);

  useEffect(() => {
    if (isTallStripImage && !longStripUserOverrideRef.current) {
      setIsLongStripScrollMode(true);
    }
  }, [isTallStripImage]);

  // Live stage viewport size for quarter-turn fit scale
  useEffect(() => {
    const el = stageRef.current;
    if (!el || typeof ResizeObserver === 'undefined') return;
    const update = () => {
      setStageSize({ width: el.clientWidth, height: el.clientHeight });
    };
    update();
    const ro = new ResizeObserver(update);
    ro.observe(el);
    return () => ro.disconnect();
  }, [activeAssetID]);

  // Handle Reveal-in-Library in Filmstrip view
  useEffect(() => {
    if (!pendingGalleryReveal) return;
    const found = assets.some((a) => a.id === pendingGalleryReveal.assetID);
    if (!found) return;
    const thumbEl = stripRef.current?.querySelector<HTMLElement>(
      `[data-filmstrip-id="${pendingGalleryReveal.assetID}"]`,
    );
    thumbEl?.scrollIntoView({
      behavior: prefersReducedMotion() ? 'auto' : 'smooth',
      inline: 'center',
      block: 'nearest',
    });
    setSpotlightAssetID(pendingGalleryReveal.assetID);
    clearPendingGalleryReveal(pendingGalleryReveal.nonce);
    const timer = window.setTimeout(() => {
      setSpotlightAssetID((cur) => (cur === pendingGalleryReveal.assetID ? null : cur));
    }, 950);
    return () => window.clearTimeout(timer);
  }, [pendingGalleryReveal, assets, clearPendingGalleryReveal]);

  // Direct non-passive wheel zoom on the visual stage (skip during Long-Strip natural vertical scroll unless Cmd/Ctrl held)
  useEffect(() => {
    const el = stageRef.current;
    if (!el || !isTransformable) return;

    const onWheel = (e: WheelEvent) => {
      if (useCoordinatorStore.getState().isOverlayPresented()) return;
      if (document.querySelector('[role="dialog"][aria-modal="true"]')) return;
      if (e.deltaY === 0) return;
      if (isLongStripScrollMode && !e.metaKey && !e.ctrlKey) return;
      e.preventDefault();
      if (isLongStripScrollMode) {
        setIsLongStripScrollMode(false);
        longStripUserOverrideRef.current = true;
      }
      const factor = computeWheelZoomFactor(e);
      setZoom((z) => {
        const next = Math.max(0.5, Math.min(maxZoomLimit, Number((z * factor).toFixed(3))));
        if (next <= 1.01) {
          setPan({ x: 0, y: 0 });
        }
        return next;
      });
    };

    el.addEventListener('wheel', onWheel, { passive: false });
    return () => el.removeEventListener('wheel', onWheel);
  }, [isTransformable, activeAssetID, maxZoomLimit, isLongStripScrollMode]);

  // Vertical mouse wheel -> horizontal scroll on bottom filmstrip
  useHorizontalWheelRedirect(stripRef, assets.length > 0);

  // Stage keyboard shortcuts (ArrowLeft/Right, R/⇧R, ⇧H/⇧V, +/=/-, 0)
  useEffect(() => {
    const onKeyDown = (e: KeyboardEvent) => {
      if (isEditableElement(e.target)) return;
      if (useCoordinatorStore.getState().isOverlayPresented()) return;
      if (document.querySelector('[role="dialog"][aria-modal="true"]')) return;
      if (assets.length === 0) return;

      if (e.key === 'ArrowRight' && !e.metaKey && !e.ctrlKey && !e.altKey) {
        e.preventDefault();
        const next = Math.min(assets.length - 1, activeIndex + 1);
        selectAsset(assets[next].id, 'replace');
        return;
      }
      if (e.key === 'ArrowLeft' && !e.metaKey && !e.ctrlKey && !e.altKey) {
        e.preventDefault();
        const prev = Math.max(0, activeIndex - 1);
        selectAsset(assets[prev].id, 'replace');
        return;
      }

      if (!isTransformable || e.metaKey || e.ctrlKey || e.altKey) return;

      if (e.key === 'r' || e.key === 'R') {
        e.preventDefault();
        rotateByScreenDelta(e.shiftKey ? -90 : 90);
      } else if ((e.key === 'h' || e.key === 'H') && e.shiftKey) {
        e.preventDefault();
        setFlipH((v) => !v);
      } else if ((e.key === 'v' || e.key === 'V') && e.shiftKey) {
        e.preventDefault();
        setFlipV((v) => !v);
      } else if (e.key === '+' || e.key === '=') {
        e.preventDefault();
        applyZoomMultiplier(1.25);
      } else if (e.key === '-') {
        e.preventDefault();
        applyZoomMultiplier(0.8);
      } else if (e.key === '0') {
        e.preventDefault();
        resetTransforms();
      }
    };
    window.addEventListener('keydown', onKeyDown);
    return () => window.removeEventListener('keydown', onKeyDown);
  }, [
    assets,
    activeIndex,
    isTransformable,
    selectAsset,
    rotateByScreenDelta,
    applyZoomMultiplier,
    resetTransforms,
  ]);

  if (!activeAsset) return null;

  const stepBy = (delta: number) => {
    const nextIdx = Math.max(0, Math.min(assets.length - 1, activeIndex + delta));
    selectAsset(assets[nextIdx].id, 'replace');
  };

  const openContextMenuFor = (asset: AssetRecord, e: React.MouseEvent) => {
    e.preventDefault();
    e.stopPropagation();
    stopAllHoverPreviews();
    closeSubmenu();
    setContextMenu({ asset, x: e.clientX, y: e.clientY });
  };

  const openQuickLookFromStage = (assetID: UUID, sourceEl?: HTMLElement | null) => {
    const rect = sourceEl?.getBoundingClientRect();
    openQuickLook(
      assetID,
      rect
        ? { left: rect.left, top: rect.top, width: rect.width, height: rect.height }
        : null,
    );
  };

  const displayRotation = ((rotation % 360) + 360) % 360;
  const hasAnyTransformOrZoom =
    Math.abs(zoom - 1) > 0.01 ||
    Math.abs(pan.x) > 0.5 ||
    Math.abs(pan.y) > 0.5 ||
    displayRotation !== 0 ||
    flipH ||
    flipV;

  const quarterTurnFitScale = isTransformable
    ? computeQuarterTurnFitScale(
        {
          width: Math.max(120, stageSize.width - 40),
          height: Math.max(120, stageSize.height - 84),
        },
        activeAsset,
        rotation,
        naturalSize,
      )
    : 1;

  const useOriginalSrc =
    activeAsset.mediaKind === 'animatedImage' ||
    (activeAsset.mediaKind === 'image' && originalFailedID !== activeAsset.id);

  const stageImgSrc = useOriginalSrc
    ? apiClient.originalMediaURL(activeAsset.id)
    : apiClient.thumbnailURL(
        activeAsset.id,
        'preview1400',
        `${activeAsset.updatedAt}-${cacheBust}`,
      );

  // Context menu action target calculation
  const contextTargetIDs: UUID[] = contextMenu
    ? selectedAssetIDs.has(contextMenu.asset.id) && selectedAssetIDs.size > 0
      ? Array.from(selectedAssetIDs)
      : [contextMenu.asset.id]
    : [];
  const contextCountSuffix = contextTargetIDs.length > 1 ? ` (${contextTargetIDs.length} 项)` : '';

  const handleCopyAssets = async (targetAsset: AssetRecord) => {
    const text = targetAsset.sourceURL || targetAsset.title || targetAsset.fileName;
    try {
      await navigator.clipboard.writeText(text);
      pushToast({ tone: 'info', message: `已复制「${targetAsset.title}」` });
    } catch {
      pushToast({ tone: 'error', message: '无法写入剪贴板' });
    }
  };

  const handleAddToActiveBoard = async (ids: UUID[]) => {
    const boardID = activeBoardID ?? boards[0]?.id ?? null;
    if (!boardID) {
      openGeneratorModal(ids);
      return;
    }
    try {
      await addAssetsToBoard(boardID, ids);
      const boardName = boards.find((b) => b.id === boardID)?.title || '活跃情绪板';
      pushToast({ tone: 'success', message: `已加入「${boardName}」` });
    } catch {
      pushToast({ tone: 'error', message: '加入情绪板失败' });
    }
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
    <div className="flex-1 min-h-0 flex flex-col px-5 pb-4 gap-3">
      {/* Main Hero Preview Stage */}
      <div
        ref={stageRef}
        onContextMenu={(e) => openContextMenuFor(activeAsset, e)}
        className="relative flex-1 min-h-[300px] rounded-[var(--radius-dock-outer)] bg-[var(--bg-elevated)] border border-[var(--border-hairline)] overflow-hidden flex items-center justify-center p-4"
      >
        <div
          className={[
            'w-full h-full flex items-center justify-center',
            isLongStripScrollMode
              ? 'overflow-y-auto overflow-x-hidden charkle-scroll items-start pb-14'
              : isTransformable
                ? 'overflow-hidden pb-11'
                : 'overflow-hidden [&>*]:max-h-full [&>*]:max-w-full',
          ].join(' ')}
        >
          {viewerKind === 'githubRepo' && activeAsset.richMetadata?.githubRepo ? (
            <GitHubRepoViewer asset={activeAsset} repo={activeAsset.richMetadata.githubRepo} />
          ) : viewerKind === 'socialPost' && activeAsset.richMetadata?.socialPost ? (
            <SocialPostViewer asset={activeAsset} post={activeAsset.richMetadata.socialPost} />
          ) : viewerKind === 'swatch' ? (
            <ColorSwatchViewer asset={activeAsset} />
          ) : viewerKind === 'audio' ? (
            <AudioStudioViewer asset={activeAsset} />
          ) : viewerKind === 'model3D' ? (
            <React.Suspense fallback={<Delayed3DStagePlaceholder />}>
              <LazyModel3DViewer asset={activeAsset} />
            </React.Suspense>
          ) : viewerKind === 'document' ? (
            <DocumentMarkdownViewer asset={activeAsset} />
          ) : viewerKind === 'webBookmark' ? (
            <WebBookmarkViewer asset={activeAsset} cacheBust={cacheBust} />
          ) : viewerKind === 'video' ? (
            <video
              key={activeAsset.id}
              src={apiClient.originalMediaURL(activeAsset.id)}
              poster={apiClient.thumbnailURL(
                activeAsset.id,
                'preview1400',
                `${activeAsset.updatedAt}-${cacheBust}`,
              )}
              controls
              autoPlay
              playsInline
              className="max-w-full max-h-full rounded-[var(--radius-card-outer)] object-contain shadow-md"
            />
          ) : isLongStripScrollMode ? (
            <img
              key={activeAsset.id}
              src={stageImgSrc}
              alt={activeAsset.title}
              draggable={false}
              onLoad={(e) => {
                const img = e.currentTarget;
                if (img.naturalWidth > 0 && img.naturalHeight > 0) {
                  setNaturalSize({ width: img.naturalWidth, height: img.naturalHeight });
                }
              }}
              onError={() => {
                if (useOriginalSrc && activeAsset.mediaKind === 'image') {
                  setOriginalFailedID(activeAsset.id);
                }
              }}
              className="w-full max-w-[920px] h-auto rounded-[var(--radius-card-outer)] select-none block mx-auto"
            />
          ) : (
            <img
              key={activeAsset.id}
              src={stageImgSrc}
              alt={activeAsset.title}
              draggable={false}
              onLoad={(e) => {
                const img = e.currentTarget;
                if (img.naturalWidth > 0 && img.naturalHeight > 0) {
                  setNaturalSize({ width: img.naturalWidth, height: img.naturalHeight });
                }
              }}
              onError={() => {
                if (useOriginalSrc && activeAsset.mediaKind === 'image') {
                  setOriginalFailedID(activeAsset.id);
                }
              }}
              onDoubleClick={() => {
                setZoom((z) => {
                  const next = z > 1.1 ? 1 : Math.min(maxZoomLimit, 2.5);
                  if (next === 1) setPan({ x: 0, y: 0 });
                  return next;
                });
              }}
              onMouseDown={(e) => {
                if (e.button !== 0 || zoom <= 1.01) return;
                e.preventDefault();
                setDraggingPan(true);
                panOriginRef.current = { x: e.clientX, y: e.clientY, panX: pan.x, panY: pan.y };
                const onMove = (ev: MouseEvent) => {
                  setPan({
                    x: panOriginRef.current.panX + (ev.clientX - panOriginRef.current.x),
                    y: panOriginRef.current.panY + (ev.clientY - panOriginRef.current.y),
                  });
                };
                const onUp = () => {
                  setDraggingPan(false);
                  window.removeEventListener('mousemove', onMove);
                  window.removeEventListener('mouseup', onUp);
                };
                window.addEventListener('mousemove', onMove);
                window.addEventListener('mouseup', onUp);
              }}
              style={{
                transform: `translate3d(${pan.x}px, ${pan.y}px, 0) scale(${zoom * quarterTurnFitScale}) scaleX(${flipH ? -1 : 1}) scaleY(${flipV ? -1 : 1}) rotate(${rotation}deg)`,
                transition: draggingPan
                  ? 'none'
                  : 'transform var(--duration-settle) var(--ease-out-strong)',
                cursor: zoom > 1.01 ? (draggingPan ? 'grabbing' : 'grab') : 'zoom-in',
              }}
              className="max-w-full max-h-full object-contain rounded-[var(--radius-card-outer)] select-none"
            />
          )}
        </div>

        {/* Left / Right Chevrons */}
        <button
          type="button"
          disabled={activeIndex <= 0}
          onClick={() => stepBy(-1)}
          aria-label="上一项"
          className="charkle-pressable charkle-glass absolute left-3 top-1/2 -translate-y-1/2 z-20 h-9 w-9 rounded-full flex items-center justify-center text-[var(--text-primary)] disabled:opacity-25 cursor-pointer"
        >
          <ChevronLeft size={18} />
        </button>
        <button
          type="button"
          disabled={activeIndex >= assets.length - 1}
          onClick={() => stepBy(1)}
          aria-label="下一项"
          className="charkle-pressable charkle-glass absolute right-3 top-1/2 -translate-y-1/2 z-20 h-9 w-9 rounded-full flex items-center justify-center text-[var(--text-primary)] disabled:opacity-25 cursor-pointer"
        >
          <ChevronRight size={18} />
        </button>

        {/* Always-Visible Floating Translucent Controls Pill */}
        {isTransformable && (
          <div className="charkle-glass absolute bottom-3 left-1/2 -translate-x-1/2 z-20 px-1.5 py-1 rounded-full flex items-center gap-0.5 max-w-[calc(100%-24px)] overflow-x-auto">
            {isTallStripImage && (
              <>
                <button
                  type="button"
                  title={isLongStripScrollMode ? '切换为整图缩放' : '切换为长图纵览'}
                  onClick={() => {
                    longStripUserOverrideRef.current = true;
                    setIsLongStripScrollMode((v) => !v);
                    resetTransforms();
                  }}
                  className={[
                    'charkle-pressable h-7 px-2 rounded-full text-[11.5px] font-medium inline-flex items-center gap-1 cursor-pointer shrink-0',
                    isLongStripScrollMode
                      ? 'bg-[var(--accent)] text-white'
                      : 'hover:bg-black/6 dark:hover:bg-white/10 text-[var(--text-primary)]',
                  ].join(' ')}
                >
                  {isLongStripScrollMode ? <Maximize2 size={12} /> : <ScrollText size={12} />}
                  {isLongStripScrollMode ? '整图' : '长图'}
                </button>
                <div className="w-px h-4 bg-[var(--border-strong)] mx-1 shrink-0" />
              </>
            )}

            {/* Zoom Group */}
            <button
              type="button"
              title="缩小 (-)"
              onClick={() => applyZoomMultiplier(0.8)}
              className="charkle-pressable h-7 w-7 rounded-full hover:bg-black/6 dark:hover:bg-white/10 text-[var(--text-primary)] flex items-center justify-center cursor-pointer shrink-0"
            >
              <ZoomOut size={13.5} />
            </button>
            <button
              type="button"
              title="重置缩放与变换 (0)"
              onClick={resetTransforms}
              className="charkle-pressable h-7 px-1.5 rounded-full hover:bg-black/6 dark:hover:bg-white/10 text-[11.5px] font-mono tabular-nums text-[var(--text-secondary)] hover:text-[var(--text-primary)] min-w-[44px] text-center cursor-pointer shrink-0"
            >
              {Math.round(zoom * 100)}%
            </button>
            <button
              type="button"
              title="放大 (+)"
              onClick={() => applyZoomMultiplier(1.25)}
              className="charkle-pressable h-7 w-7 rounded-full hover:bg-black/6 dark:hover:bg-white/10 text-[var(--text-primary)] flex items-center justify-center cursor-pointer shrink-0"
            >
              <ZoomIn size={13.5} />
            </button>

            <div className="w-px h-4 bg-[var(--border-strong)] mx-1 shrink-0" />

            {/* Rotate & Flip Group */}
            <button
              type="button"
              title="逆时针旋转 90° (⇧R)"
              onClick={() => rotateByScreenDelta(-90)}
              className="charkle-pressable h-7 w-7 rounded-full hover:bg-black/6 dark:hover:bg-white/10 text-[var(--text-primary)] flex items-center justify-center cursor-pointer shrink-0"
            >
              <RotateCcw size={13.5} />
            </button>
            <button
              type="button"
              title="顺时针旋转 90° (R)"
              onClick={() => rotateByScreenDelta(90)}
              className="charkle-pressable h-7 w-7 rounded-full hover:bg-black/6 dark:hover:bg-white/10 text-[var(--text-primary)] flex items-center justify-center cursor-pointer shrink-0"
            >
              <RotateCw size={13.5} />
            </button>
            <button
              type="button"
              title="水平翻转 (⇧H)"
              onClick={() => setFlipH((v) => !v)}
              className={[
                'charkle-pressable h-7 w-7 rounded-full flex items-center justify-center cursor-pointer shrink-0',
                flipH
                  ? 'bg-[var(--accent)] text-white'
                  : 'hover:bg-black/6 dark:hover:bg-white/10 text-[var(--text-primary)]',
              ].join(' ')}
            >
              <FlipHorizontal2 size={13.5} />
            </button>
            <button
              type="button"
              title="垂直翻转 (⇧V)"
              onClick={() => setFlipV((v) => !v)}
              className={[
                'charkle-pressable h-7 w-7 rounded-full flex items-center justify-center cursor-pointer shrink-0',
                flipV
                  ? 'bg-[var(--accent)] text-white'
                  : 'hover:bg-black/6 dark:hover:bg-white/10 text-[var(--text-primary)]',
              ].join(' ')}
            >
              <FlipVertical2 size={13.5} />
            </button>

            {hasAnyTransformOrZoom && (
              <button
                type="button"
                title="重置全部变换 (0)"
                onClick={resetTransforms}
                className="charkle-pressable h-7 px-2 ml-0.5 rounded-full bg-[var(--accent-soft)] text-[var(--accent)] text-[11px] font-medium inline-flex items-center gap-1 cursor-pointer shrink-0"
              >
                <Undo2 size={11.5} />
                {displayRotation !== 0 ? `${displayRotation}°` : '重置'}
              </button>
            )}

            <div className="w-px h-4 bg-[var(--border-strong)] mx-1 shrink-0" />

            <button
              type="button"
              title="沉浸预览 (Space)"
              onClick={() => openQuickLookFromStage(activeAsset.id, stageRef.current)}
              className="charkle-pressable h-7 px-2.5 rounded-full hover:bg-black/6 dark:hover:bg-white/10 text-[var(--text-primary)] text-[12px] font-medium inline-flex items-center gap-1.5 cursor-pointer shrink-0"
            >
              <Eye size={13} />
              沉浸预览
            </button>
          </div>
        )}
      </div>

      {/* Compact Stage Info Bar */}
      <div className="flex flex-wrap items-center justify-between gap-3 px-2 shrink-0">
        <div className="flex items-center gap-3 min-w-0">
          <span className="text-[13.5px] font-semibold text-[var(--text-primary)] truncate max-w-[320px]">
            {activeAsset.title}
          </span>
          <span className="text-[12px] text-[var(--text-tertiary)] shrink-0">
            {getAssetDisplayTypeLabel(activeAsset)}
            {activeAsset.pixelWidth > 0 && ` · ${activeAsset.pixelWidth}×${activeAsset.pixelHeight}`}
            {activeAsset.fileSizeBytes > 0 && ` · ${formatBytes(activeAsset.fileSizeBytes)}`}
          </span>
        </div>

        <div className="flex items-center gap-3 shrink-0">
          <div className="flex items-center gap-0.5">
            {[1, 2, 3, 4, 5].map((star) => {
              const filled = activeAsset.rating >= star;
              const isPopping =
                poppedStar?.assetID === activeAsset.id && poppedStar.star === star && filled;
              return (
                <button
                  key={star}
                  type="button"
                  aria-label={`评分 ${star} 星`}
                  onClick={() => {
                    const nextRating = activeAsset.rating === star ? 0 : star;
                    if (nextRating > 0) {
                      setPoppedStar((prev) => ({
                        assetID: activeAsset.id,
                        star,
                        seq: (prev?.seq ?? 0) + 1,
                      }));
                    }
                    void batchPatch(
                      createDefaultAssetBatchPatch([activeAsset.id], { rating: nextRating }),
                    );
                  }}
                  className="charkle-pressable p-0.5 cursor-pointer"
                >
                  <Star
                    key={isPopping ? `pop-${poppedStar.seq}` : 'static'}
                    size={14}
                    className={[
                      filled ? 'fill-[#F2C14E] text-[#F2C14E]' : 'text-[var(--text-tertiary)]',
                      isPopping ? 'charkle-micro-pop' : '',
                    ].join(' ')}
                  />
                </button>
              );
            })}
          </div>

          <span className="text-[12px] tabular-nums text-[var(--text-tertiary)]">
            {activeIndex + 1} / {assets.length}
          </span>

          {!isTransformable && (
            <Button
              variant="secondary"
              size="xs"
              onClick={() => openQuickLookFromStage(activeAsset.id, stageRef.current)}
            >
              <Eye size={13} />
              沉浸预览
            </Button>
          )}
        </div>
      </div>

      {/* Bottom 92px Filmstrip */}
      <div
        ref={stripRef}
        onScroll={() => notifyLiveScrolling()}
        className="h-[92px] shrink-0 flex items-center gap-2.5 overflow-x-auto charkle-scroll px-3 py-2 rounded-[var(--radius-settings-outer)] bg-[var(--bg-elevated)]/75 border border-[var(--border-hairline)]"
      >
        {assets.map((asset) => {
          const isCurrent = asset.id === activeAsset.id;
          const isSelected = selectedAssetIDs.has(asset.id);
          const ratio = Math.max(0.6, Math.min(1.75, getCardEffectiveAspectRatio(asset)));
          const thumbW = Math.round(Math.max(46, Math.min(116, 68 * ratio)));
          return (
            <button
              key={asset.id}
              type="button"
              data-filmstrip-id={asset.id}
              data-active={isCurrent ? 'true' : 'false'}
              onMouseEnter={() => setHoveredThumbID(asset.id)}
              onMouseLeave={() => setHoveredThumbID((cur) => (cur === asset.id ? null : cur))}
              onMouseDown={() => stopAllHoverPreviews()}
              onClick={(e) => {
                if (e.shiftKey) selectAsset(asset.id, 'range');
                else if (e.metaKey || e.ctrlKey) selectAsset(asset.id, 'toggle');
                else selectAsset(asset.id, 'replace');
              }}
              onDoubleClick={(e) => openQuickLookFromStage(asset.id, e.currentTarget)}
              onContextMenu={(e) => openContextMenuFor(asset, e)}
              style={{ width: thumbW, height: 68 }}
              className={[
                'charkle-filmstrip-thumb relative shrink-0 overflow-hidden rounded-[8px] bg-[var(--bg-subtle)] cursor-pointer',
                isCurrent
                  ? 'ring-2 ring-[var(--accent)] ring-offset-2 ring-offset-[var(--bg-elevated)] opacity-100 z-10'
                  : isSelected
                    ? 'ring-2 ring-[var(--accent)]/60 opacity-95'
                    : 'opacity-72 hover:opacity-100',
                spotlightAssetID === asset.id ? 'charkle-reveal-spotlight' : '',
              ].join(' ')}
            >
              <img
                src={apiClient.thumbnailURL(asset.id, 'grid520', `${asset.updatedAt}-${cacheBust}`)}
                alt={asset.title}
                loading="lazy"
                draggable={false}
                className="w-full h-full object-cover block"
              />
              <HoverMediaPreview
                asset={asset}
                active={hoveredThumbID === asset.id}
                fit="cover"
                roundedClass="rounded-[8px]"
              />
            </button>
          );
        })}
      </div>

      {/* Right-Click Context Menu (Trigger-Origin Popover + Safe-Triangle Submenus + Animated Exit) */}
      <Popover
        open={Boolean(contextMenu)}
        onOpenChange={(open) => {
          if (!open) closeMenu();
        }}
        anchorPoint={contextMenu ? { x: contextMenu.x, y: contextMenu.y } : null}
        glass={false}
      >
        {contextMenu && (
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
                openQuickLookFromStage(contextMenu.asset.id, stageRef.current);
                closeMenu();
              }}
              className="w-full px-2.5 py-1.5 rounded-[var(--radius-popover-inner)] flex items-center gap-2 hover:bg-[var(--bg-subtle)] cursor-pointer text-left"
            >
              <Eye size={13.5} className="text-[var(--text-secondary)] shrink-0" />
              <span>沉浸预览</span>
              <span className="ml-auto text-[11px] font-mono text-[var(--text-tertiary)]">
                Space
              </span>
            </button>

            {contextMenu.asset.sourceURL && (
              <a
                href={contextMenu.asset.sourceURL}
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
              onClick={() => {
                void handleCopyAssets(contextMenu.asset);
                closeMenu();
              }}
              className="w-full px-2.5 py-1.5 rounded-[var(--radius-popover-inner)] flex items-center gap-2 hover:bg-[var(--bg-subtle)] cursor-pointer text-left"
            >
              <Copy size={13.5} className="text-[var(--text-secondary)] shrink-0" />
              <span>复制{contextCountSuffix}</span>
            </button>

            {!contextMenu.asset.isTrashed && (
              <button
                type="button"
                role="menuitem"
                onMouseEnter={(e) => requestSubmenu(null, e)}
                onClick={() => {
                  setCutAssetIDs(contextTargetIDs);
                  pushToast({
                    tone: 'info',
                    message: `已剪切 ${contextTargetIDs.length} 项素材`,
                  });
                  closeMenu();
                }}
                className="w-full px-2.5 py-1.5 rounded-[var(--radius-popover-inner)] flex items-center gap-2 hover:bg-[var(--bg-subtle)] cursor-pointer text-left"
              >
                <Scissors size={13.5} className="text-[var(--text-secondary)] shrink-0" />
                <span>剪切{contextCountSuffix}</span>
              </button>
            )}

            <a
              href={apiClient.originalMediaURL(contextMenu.asset.id, { download: true })}
              download={contextMenu.asset.fileName}
              onMouseEnter={(e) => requestSubmenu(null, e)}
              onClick={closeMenu}
              className="w-full px-2.5 py-1.5 rounded-[var(--radius-popover-inner)] flex items-center gap-2 hover:bg-[var(--bg-subtle)] cursor-pointer text-left"
            >
              <Download size={13.5} className="text-[var(--text-secondary)] shrink-0" />
              <span>下载原文件</span>
            </a>

            <div className="my-1 border-t border-[var(--border-hairline)]" />

            {!contextMenu.asset.isTrashed ? (
              <>
                <button
                  type="button"
                  role="menuitem"
                  onMouseEnter={(e) => requestSubmenu(null, e)}
                  onClick={() => {
                    void handleAddToActiveBoard(contextTargetIDs);
                    closeMenu();
                  }}
                  className="w-full px-2.5 py-1.5 rounded-[var(--radius-popover-inner)] flex items-center gap-2 hover:bg-[var(--bg-subtle)] cursor-pointer text-left"
                >
                  <LayoutGrid size={13.5} className="text-[var(--text-secondary)] shrink-0" />
                  <span>加入活跃情绪板{contextCountSuffix}</span>
                </button>

                {/* Safe-Triangle Submenu: Join Specific Moodboard */}
                <div
                  className="relative"
                  onMouseEnter={(e) => requestSubmenu('boards', e)}
                >
                  <button
                    type="button"
                    role="menuitem"
                    aria-haspopup="menu"
                    aria-expanded={activeSubmenu === 'boards'}
                    onClick={() => setActiveSubmenu((cur) => (cur === 'boards' ? null : 'boards'))}
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
                  <FilmstripSubmenuShell
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
                              try {
                                await addAssetsToBoard(board.id, contextTargetIDs);
                                pushToast({
                                  tone: 'success',
                                  message: `已加入「${board.title}」`,
                                });
                              } catch {
                                pushToast({ tone: 'error', message: '加入情绪板失败' });
                              }
                            }}
                            className="w-full px-2.5 py-1.5 rounded-[var(--radius-popover-inner)] text-left truncate hover:bg-[var(--bg-subtle)] cursor-pointer"
                          >
                            {board.title}
                          </button>
                        ))
                      )}
                    </div>
                  </FilmstripSubmenuShell>
                </div>

                {/* Safe-Triangle Submenu: Move to Folder */}
                <div
                  className="relative"
                  onMouseEnter={(e) => requestSubmenu('folders', e)}
                >
                  <button
                    type="button"
                    role="menuitem"
                    aria-haspopup="menu"
                    aria-expanded={activeSubmenu === 'folders'}
                    onClick={() =>
                      setActiveSubmenu((cur) => (cur === 'folders' ? null : 'folders'))
                    }
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
                  <FilmstripSubmenuShell
                    open={activeSubmenu === 'folders'}
                    side={submenuSide}
                    panelRef={submenuElRef}
                    onMouseEnter={cancelPendingClose}
                  >
                    <FolderHierarchyMenu
                      folders={folders}
                      includeInbox
                      selectedFolderID={
                        contextTargetIDs.length === 1 ? contextMenu.asset.folderID ?? null : null
                      }
                      highlightSelection={contextTargetIDs.length === 1}
                      parentSelfPrefix="放入"
                      submenuSide={submenuSide}
                      onSelectFolder={(folderID) => {
                        closeMenu();
                        void batchPatch(
                          createDefaultAssetBatchPatch(contextTargetIDs, {
                            folderAssignment: folderID
                              ? { type: 'folder', folderID }
                              : { type: 'inbox' },
                          }),
                        );
                        const label = folderID
                          ? folders.find((f) => f.id === folderID)?.name ?? '文件夹'
                          : '收件箱';
                        pushToast({
                          tone: 'info',
                          message: `已移动 ${contextTargetIDs.length} 项到「${label}」`,
                        });
                      }}
                    />
                  </FilmstripSubmenuShell>
                </div>

                <button
                  type="button"
                  role="menuitem"
                  onMouseEnter={(e) => requestSubmenu(null, e)}
                  onClick={() => {
                    const nextPinned = !contextMenu.asset.pinnedOffline;
                    void batchPatch(
                      createDefaultAssetBatchPatch(contextTargetIDs, {
                        pinnedOffline: nextPinned,
                      }),
                    );
                    pushToast({
                      tone: 'info',
                      message: nextPinned ? '已标记为始终保留在本地' : '已取消始终保留在本地',
                    });
                    closeMenu();
                  }}
                  className="w-full px-2.5 py-1.5 rounded-[var(--radius-popover-inner)] flex items-center gap-2 hover:bg-[var(--bg-subtle)] cursor-pointer text-left"
                >
                  <Pin size={13.5} className="text-[var(--text-secondary)] shrink-0" />
                  <span>
                    {contextMenu.asset.pinnedOffline ? '取消始终保留在本地' : '始终保留在本地'}
                  </span>
                </button>

                <button
                  type="button"
                  role="menuitem"
                  onMouseEnter={(e) => requestSubmenu(null, e)}
                  onClick={() => {
                    void handleAIAnalyze(contextTargetIDs);
                    closeMenu();
                  }}
                  className="w-full px-2.5 py-1.5 rounded-[var(--radius-popover-inner)] flex items-center gap-2 hover:bg-[var(--bg-subtle)] cursor-pointer text-left"
                >
                  <Sparkles size={13.5} className="text-[var(--text-secondary)] shrink-0" />
                  <span>AI 重新打标{contextCountSuffix}</span>
                </button>

                <div className="my-1 border-t border-[var(--border-hairline)]" />

                <button
                  type="button"
                  role="menuitem"
                  onMouseEnter={(e) => requestSubmenu(null, e)}
                  onClick={() => {
                    void trashAssets(contextTargetIDs);
                    closeMenu();
                  }}
                  className="w-full px-2.5 py-1.5 rounded-[var(--radius-popover-inner)] flex items-center gap-2 hover:bg-[var(--danger-soft)] text-[var(--danger)] cursor-pointer text-left"
                >
                  <Trash2 size={13.5} className="shrink-0" />
                  <span>移入回收站{contextCountSuffix}</span>
                </button>
              </>
            ) : (
              <>
                <button
                  type="button"
                  role="menuitem"
                  onMouseEnter={(e) => requestSubmenu(null, e)}
                  onClick={() => {
                    void restoreAssets(contextTargetIDs);
                    closeMenu();
                  }}
                  className="w-full px-2.5 py-1.5 rounded-[var(--radius-popover-inner)] flex items-center gap-2 hover:bg-[var(--bg-subtle)] cursor-pointer text-left"
                >
                  <Undo2 size={13.5} className="text-[var(--text-secondary)] shrink-0" />
                  <span>恢复素材{contextCountSuffix}</span>
                </button>

                <button
                  type="button"
                  role="menuitem"
                  onMouseEnter={(e) => requestSubmenu(null, e)}
                  onClick={() => {
                    const targetLabel =
                      contextTargetIDs.length > 1
                        ? `${contextTargetIDs.length} 项素材`
                        : `「${contextMenu.asset.title}」`;
                    const idsCopy = [...contextTargetIDs];
                    closeMenu();
                    setConfirmDelete({ ids: idsCopy, label: targetLabel });
                  }}
                  className="w-full px-2.5 py-1.5 rounded-[var(--radius-popover-inner)] flex items-center gap-2 hover:bg-[var(--danger-soft)] text-[var(--danger)] cursor-pointer text-left"
                >
                  <Trash2 size={13.5} className="shrink-0" />
                  <span>彻底删除{contextCountSuffix}</span>
                </button>
              </>
            )}
          </div>
        )}
      </Popover>

      {/* Confirmed Permanent Delete Dialog */}
      <ConfirmDialog
        open={Boolean(confirmDelete)}
        onClose={() => setConfirmDelete(null)}
        title={`彻底删除${confirmDelete?.label ?? ''}？`}
        description="删除后将永久移除文件且无法恢复。"
        confirmLabel="彻底删除"
        onConfirm={async () => {
          if (!confirmDelete) return;
          await permanentlyDeleteAssets(confirmDelete.ids);
          pushToast({ tone: 'info', message: `已彻底删除 ${confirmDelete.ids.length} 项素材` });
        }}
      />
    </div>
  );
};
