import React, { useCallback, useEffect, useMemo, useRef, useState } from 'react';
import { createPortal } from 'react-dom';
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
  Inbox,
  LayoutGrid,
  Pin,
  RotateCcw,
  RotateCw,
  Scissors,
  Sparkles,
  Star,
  Trash2,
  Undo2,
  ZoomIn,
  ZoomOut,
} from 'lucide-react';
import {
  createDefaultAssetBatchPatch,
  getAssetDisplayTypeLabel,
} from '@charkle/shared';
import type { AssetRecord, UUID } from '@charkle/shared';
import { apiClient } from '../../api/client';
import {
  HoverMediaPreview,
  notifyLiveScrolling,
  stopAllHoverPreviews,
} from '../../components/HoverMediaPreview';
import { Button, formatBytes } from '../../design-system';
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
  computeQuarterTurnFitScale,
  computeWheelZoomFactor,
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

  const boards = useMoodboardStore((s) => s.boards);
  const addAssetsToBoard = useMoodboardStore((s) => s.addAssetsToBoard);

  const stripRef = useRef<HTMLDivElement | null>(null);
  const stageRef = useRef<HTMLDivElement | null>(null);
  const menuRef = useRef<HTMLDivElement | null>(null);

  const [zoom, setZoom] = useState(1);
  const [pan, setPan] = useState({ x: 0, y: 0 });
  const [rotation, setRotation] = useState(0);
  const [flipH, setFlipH] = useState(false);
  const [flipV, setFlipV] = useState(false);
  const [draggingPan, setDraggingPan] = useState(false);
  const [stageSize, setStageSize] = useState({ width: 0, height: 0 });
  const [naturalSize, setNaturalSize] = useState<{ width: number; height: number } | null>(null);
  const [hoveredThumbID, setHoveredThumbID] = useState<UUID | null>(null);
  const [poppedStar, setPoppedStar] = useState<{ assetID: UUID; star: number; seq: number } | null>(
    null,
  );
  const [contextMenu, setContextMenu] = useState<ContextMenuState | null>(null);
  const [activeSubmenu, setActiveSubmenu] = useState<'boards' | 'folders' | null>(null);

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

  const resetTransforms = useCallback(() => {
    setZoom(1);
    setPan({ x: 0, y: 0 });
    setRotation(0);
    setFlipH(false);
    setFlipV(false);
  }, []);

  const applyZoomMultiplier = useCallback((factor: number) => {
    setZoom((z) => {
      const next = Math.max(0.5, Math.min(5, Number((z * factor).toFixed(3))));
      if (next <= 1.01) {
        setPan({ x: 0, y: 0 });
      }
      return next;
    });
  }, []);

  const rotateByScreenDelta = useCallback(
    (screenDelta: number) => {
      const parity = flipH !== flipV ? -1 : 1;
      setRotation((r) => (r + screenDelta * parity) % 360);
    },
    [flipH, flipV],
  );

  // Auto-reset transforms & scroll active thumbnail into view when active asset changes
  useEffect(() => {
    resetTransforms();
    setNaturalSize(null);
    if (!activeAssetID) return;
    void markOpened(activeAssetID);
    const thumbEl = stripRef.current?.querySelector<HTMLElement>(
      `[data-filmstrip-id="${activeAssetID}"]`,
    );
    thumbEl?.scrollIntoView({ behavior: 'smooth', inline: 'center', block: 'nearest' });
  }, [activeAssetID, markOpened, resetTransforms]);

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

  // Direct non-passive wheel zoom on the visual stage
  useEffect(() => {
    const el = stageRef.current;
    if (!el || !isTransformable) return;

    const onWheel = (e: WheelEvent) => {
      if (useCoordinatorStore.getState().quickLookAssetID !== null) return;
      if (document.querySelector('[role="dialog"][aria-modal="true"]')) return;
      if (e.deltaY === 0) return;
      e.preventDefault();
      const factor = computeWheelZoomFactor(e);
      setZoom((z) => {
        const next = Math.max(0.5, Math.min(5, Number((z * factor).toFixed(3))));
        if (next <= 1.01) {
          setPan({ x: 0, y: 0 });
        }
        return next;
      });
    };

    el.addEventListener('wheel', onWheel, { passive: false });
    return () => el.removeEventListener('wheel', onWheel);
  }, [isTransformable, activeAssetID]);

  // Vertical mouse wheel -> horizontal scroll on bottom filmstrip
  useHorizontalWheelRedirect(stripRef, assets.length > 0);

  // Stage keyboard shortcuts (ArrowLeft/Right, R/⇧R, ⇧H/⇧V, +/=/-, 0)
  useEffect(() => {
    const onKeyDown = (e: KeyboardEvent) => {
      if (isEditableElement(e.target)) return;
      if (useCoordinatorStore.getState().quickLookAssetID !== null) return;
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

  // Dismiss right-click context menu on outside interaction, Escape, scroll, or blur
  useEffect(() => {
    if (!contextMenu) return;
    const onPointerDown = (e: MouseEvent) => {
      if (menuRef.current && menuRef.current.contains(e.target as Node)) return;
      setContextMenu(null);
      setActiveSubmenu(null);
    };
    const onKeyDown = (e: KeyboardEvent) => {
      if (e.key === 'Escape') {
        setContextMenu(null);
        setActiveSubmenu(null);
      }
    };
    const close = () => {
      setContextMenu(null);
      setActiveSubmenu(null);
    };
    window.addEventListener('mousedown', onPointerDown, true);
    window.addEventListener('keydown', onKeyDown);
    window.addEventListener('blur', close);
    return () => {
      window.removeEventListener('mousedown', onPointerDown, true);
      window.removeEventListener('keydown', onKeyDown);
      window.removeEventListener('blur', close);
    };
  }, [contextMenu]);

  if (!activeAsset) return null;

  const stepBy = (delta: number) => {
    const nextIdx = Math.max(0, Math.min(assets.length - 1, activeIndex + delta));
    selectAsset(assets[nextIdx].id, 'replace');
  };

  const openContextMenuFor = (asset: AssetRecord, e: React.MouseEvent) => {
    e.preventDefault();
    e.stopPropagation();
    stopAllHoverPreviews();
    setActiveSubmenu(null);
    setContextMenu({ asset, x: e.clientX, y: e.clientY });
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

  // Context menu action target calculation
  const contextTargetIDs: UUID[] = contextMenu
    ? selectedAssetIDs.has(contextMenu.asset.id) && selectedAssetIDs.size > 0
      ? Array.from(selectedAssetIDs)
      : [contextMenu.asset.id]
    : [];
  const contextCountSuffix = contextTargetIDs.length > 1 ? ` (${contextTargetIDs.length} 项)` : '';

  const clampedMenuPos = contextMenu
    ? {
        left: Math.min(
          contextMenu.x,
          typeof window !== 'undefined' ? Math.max(12, window.innerWidth - 236) : contextMenu.x,
        ),
        top: Math.min(
          contextMenu.y,
          typeof window !== 'undefined' ? Math.max(12, window.innerHeight - 380) : contextMenu.y,
        ),
      }
    : null;

  const submenuFlipLeft =
    clampedMenuPos && typeof window !== 'undefined'
      ? clampedMenuPos.left + 440 > window.innerWidth
      : false;

  const handleCopyAssets = async (targetAsset: AssetRecord) => {
    const text = targetAsset.sourceURL || targetAsset.title || targetAsset.fileName;
    try {
      await navigator.clipboard.writeText(text);
      pushToast({ tone: 'info', message: `已拷贝「${targetAsset.title}」` });
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
    pushToast({ tone: 'info', message: `正在对 ${ids.length} 项素材进行 AI 重新打标…` });
    try {
      const res = await apiClient.analyzeAssets({ ids });
      if (res.assets?.length) {
        upsertAssets(res.assets);
      }
      pushToast({ tone: 'success', message: `AI 重新打标完成（${ids.length} 项）` });
    } catch (err) {
      pushToast({
        tone: 'error',
        message: err instanceof Error ? err.message : 'AI 重新打标失败',
      });
    }
  };

  return (
    <div className="flex-1 min-h-0 flex flex-col px-5 pb-4 gap-3">
      {/* Main Hero Preview Stage (Full 8-Media-Type Quick Look Parity) */}
      <div
        ref={stageRef}
        onContextMenu={(e) => openContextMenuFor(activeAsset, e)}
        className="relative flex-1 min-h-[300px] rounded-[var(--radius-dock-outer)] bg-[var(--bg-elevated)] border border-[var(--border-hairline)] overflow-hidden flex items-center justify-center p-4"
      >
        <div
          className={[
            'w-full h-full flex items-center justify-center overflow-hidden',
            isTransformable ? 'pb-11' : '[&>*]:max-h-full [&>*]:max-w-full',
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
            <React.Suspense
              fallback={
                <div className="w-[min(860px,88vw)] h-full max-h-[560px] rounded-[var(--radius-dock-outer)] bg-[#181A20] flex items-center justify-center text-white text-[13px] gap-2">
                  <span className="h-4 w-4 rounded-full border-2 border-[#5B8DEF] border-t-transparent animate-spin" />
                  正在初始化 3D 预览引擎…
                </div>
              }
            >
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
          ) : (
            <img
              key={activeAsset.id}
              src={
                activeAsset.mediaKind === 'animatedImage'
                  ? apiClient.originalMediaURL(activeAsset.id)
                  : apiClient.thumbnailURL(
                      activeAsset.id,
                      'preview1400',
                      `${activeAsset.updatedAt}-${cacheBust}`,
                    )
              }
              alt={activeAsset.title}
              draggable={false}
              onLoad={(e) => {
                const img = e.currentTarget;
                if (img.naturalWidth > 0 && img.naturalHeight > 0) {
                  setNaturalSize({ width: img.naturalWidth, height: img.naturalHeight });
                }
              }}
              onDoubleClick={() => {
                setZoom((z) => {
                  const next = z > 1.1 ? 1 : 2;
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

        {/* Always-Visible Floating Liquid Glass Controls Pill (Visual Stage) */}
        {isTransformable && (
          <div className="charkle-glass absolute bottom-3 left-1/2 -translate-x-1/2 z-20 px-1.5 py-1 rounded-full flex items-center gap-0.5 max-w-[calc(100%-24px)] overflow-x-auto">
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
              onClick={() => openQuickLook(activeAsset.id)}
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
            <Button variant="secondary" size="xs" onClick={() => openQuickLook(activeAsset.id)}>
              <Eye size={13} />
              沉浸预览
            </Button>
          )}
        </div>
      </div>

      {/* Bottom 92px Filmstrip (Wheel-redirect + Hover Media Preview + Focus Scale) */}
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
              onDoubleClick={() => openQuickLook(asset.id)}
              onContextMenu={(e) => openContextMenuFor(asset, e)}
              style={{ width: thumbW, height: 68 }}
              className={[
                'charkle-filmstrip-thumb relative shrink-0 overflow-hidden rounded-[8px] bg-[var(--bg-subtle)] cursor-pointer',
                isCurrent
                  ? 'ring-2 ring-[var(--accent)] ring-offset-2 ring-offset-[var(--bg-elevated)] opacity-100 z-10'
                  : isSelected
                    ? 'ring-2 ring-[var(--accent)]/60 opacity-95'
                    : 'opacity-72 hover:opacity-100',
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

      {/* Right-Click Context Menu Portal */}
      {contextMenu &&
        clampedMenuPos &&
        typeof document !== 'undefined' &&
        createPortal(
          <div
            ref={menuRef}
            role="menu"
            style={{ left: clampedMenuPos.left, top: clampedMenuPos.top }}
            className="charkle-popover-enter fixed z-[140] w-[224px] py-1.5 rounded-[var(--radius-popover-outer)] bg-[var(--bg-elevated)] border border-[var(--border-strong)] shadow-xl text-[12.5px] text-[var(--text-primary)] select-none"
          >
            <button
              type="button"
              role="menuitem"
              onClick={() => {
                openQuickLook(contextMenu.asset.id);
                setContextMenu(null);
              }}
              className="w-full px-3 py-1.5 flex items-center gap-2 hover:bg-[var(--bg-subtle)] cursor-pointer text-left"
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
                rel="noreferrer"
                onClick={() => setContextMenu(null)}
                className="w-full px-3 py-1.5 flex items-center gap-2 hover:bg-[var(--bg-subtle)] cursor-pointer text-left"
              >
                <ExternalLink size={13.5} className="text-[var(--text-secondary)] shrink-0" />
                <span>打开来源网页</span>
              </a>
            )}

            <div className="my-1 border-t border-[var(--border-hairline)]" />

            <button
              type="button"
              role="menuitem"
              onClick={() => {
                void handleCopyAssets(contextMenu.asset);
                setContextMenu(null);
              }}
              className="w-full px-3 py-1.5 flex items-center gap-2 hover:bg-[var(--bg-subtle)] cursor-pointer text-left"
            >
              <Copy size={13.5} className="text-[var(--text-secondary)] shrink-0" />
              <span>拷贝{contextCountSuffix}</span>
            </button>

            {!contextMenu.asset.isTrashed && (
              <button
                type="button"
                role="menuitem"
                onClick={() => {
                  setCutAssetIDs(contextTargetIDs);
                  pushToast({
                    tone: 'info',
                    message: `已剪切 ${contextTargetIDs.length} 项素材，选择目标文件夹后按 ⌘V 移动`,
                  });
                  setContextMenu(null);
                }}
                className="w-full px-3 py-1.5 flex items-center gap-2 hover:bg-[var(--bg-subtle)] cursor-pointer text-left"
              >
                <Scissors size={13.5} className="text-[var(--text-secondary)] shrink-0" />
                <span>剪切{contextCountSuffix}</span>
              </button>
            )}

            <a
              href={apiClient.originalMediaURL(contextMenu.asset.id, { download: true })}
              download={contextMenu.asset.fileName}
              onClick={() => setContextMenu(null)}
              className="w-full px-3 py-1.5 flex items-center gap-2 hover:bg-[var(--bg-subtle)] cursor-pointer text-left"
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
                  onClick={() => {
                    void handleAddToActiveBoard(contextTargetIDs);
                    setContextMenu(null);
                  }}
                  className="w-full px-3 py-1.5 flex items-center gap-2 hover:bg-[var(--bg-subtle)] cursor-pointer text-left"
                >
                  <LayoutGrid size={13.5} className="text-[var(--text-secondary)] shrink-0" />
                  <span>加入活跃情绪板{contextCountSuffix}</span>
                </button>

                {/* Submenu: Join Specific Moodboard */}
                <div
                  className="relative"
                  onMouseEnter={() => setActiveSubmenu('boards')}
                  onMouseLeave={() => setActiveSubmenu((cur) => (cur === 'boards' ? null : cur))}
                >
                  <button
                    type="button"
                    role="menuitem"
                    onClick={() => setActiveSubmenu((cur) => (cur === 'boards' ? null : 'boards'))}
                    className="w-full px-3 py-1.5 flex items-center gap-2 hover:bg-[var(--bg-subtle)] cursor-pointer text-left"
                  >
                    <LayoutGrid size={13.5} className="text-[var(--text-secondary)] shrink-0" />
                    <span className="flex-1 truncate">加入指定情绪板</span>
                    <ChevronRight size={13} className="text-[var(--text-tertiary)] shrink-0" />
                  </button>
                  {activeSubmenu === 'boards' && (
                    <div
                      className={[
                        'absolute top-0 w-[200px] max-h-[240px] overflow-y-auto charkle-scroll py-1.5 rounded-[var(--radius-popover-outer)] bg-[var(--bg-elevated)] border border-[var(--border-strong)] shadow-xl',
                        submenuFlipLeft ? 'right-full mr-1' : 'left-full ml-1',
                      ].join(' ')}
                    >
                      {boards.length === 0 ? (
                        <div className="px-3 py-2 text-[12px] text-[var(--text-tertiary)]">
                          暂无情绪板
                        </div>
                      ) : (
                        boards.map((board) => (
                          <button
                            key={board.id}
                            type="button"
                            onClick={async () => {
                              setContextMenu(null);
                              setActiveSubmenu(null);
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
                            className="w-full px-3 py-1.5 text-left truncate hover:bg-[var(--bg-subtle)] cursor-pointer"
                          >
                            {board.title}
                          </button>
                        ))
                      )}
                    </div>
                  )}
                </div>

                {/* Submenu: Move to Folder */}
                <div
                  className="relative"
                  onMouseEnter={() => setActiveSubmenu('folders')}
                  onMouseLeave={() => setActiveSubmenu((cur) => (cur === 'folders' ? null : cur))}
                >
                  <button
                    type="button"
                    role="menuitem"
                    onClick={() =>
                      setActiveSubmenu((cur) => (cur === 'folders' ? null : 'folders'))
                    }
                    className="w-full px-3 py-1.5 flex items-center gap-2 hover:bg-[var(--bg-subtle)] cursor-pointer text-left"
                  >
                    <FolderInput size={13.5} className="text-[var(--text-secondary)] shrink-0" />
                    <span className="flex-1 truncate">移动到文件夹</span>
                    <ChevronRight size={13} className="text-[var(--text-tertiary)] shrink-0" />
                  </button>
                  {activeSubmenu === 'folders' && (
                    <div
                      className={[
                        'absolute top-0 w-[200px] max-h-[240px] overflow-y-auto charkle-scroll py-1.5 rounded-[var(--radius-popover-outer)] bg-[var(--bg-elevated)] border border-[var(--border-strong)] shadow-xl',
                        submenuFlipLeft ? 'right-full mr-1' : 'left-full ml-1',
                      ].join(' ')}
                    >
                      <button
                        type="button"
                        onClick={() => {
                          setContextMenu(null);
                          setActiveSubmenu(null);
                          void batchPatch(
                            createDefaultAssetBatchPatch(contextTargetIDs, {
                              folderAssignment: { type: 'inbox' },
                            }),
                          );
                          pushToast({
                            tone: 'info',
                            message: `已移动 ${contextTargetIDs.length} 项到收件箱`,
                          });
                        }}
                        className="w-full px-3 py-1.5 flex items-center gap-2 hover:bg-[var(--bg-subtle)] cursor-pointer text-left"
                      >
                        <Inbox size={13} className="text-[var(--text-tertiary)] shrink-0" />
                        <span className="truncate">收件箱</span>
                      </button>
                      {folders.map((folder) => (
                        <button
                          key={folder.id}
                          type="button"
                          onClick={() => {
                            setContextMenu(null);
                            setActiveSubmenu(null);
                            void batchPatch(
                              createDefaultAssetBatchPatch(contextTargetIDs, {
                                folderAssignment: { type: 'folder', folderID: folder.id },
                              }),
                            );
                            pushToast({
                              tone: 'info',
                              message: `已移动 ${contextTargetIDs.length} 项到「${folder.name}」`,
                            });
                          }}
                          className="w-full px-3 py-1.5 text-left truncate hover:bg-[var(--bg-subtle)] cursor-pointer"
                        >
                          {folder.name}
                        </button>
                      ))}
                    </div>
                  )}
                </div>

                <button
                  type="button"
                  role="menuitem"
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
                    setContextMenu(null);
                  }}
                  className="w-full px-3 py-1.5 flex items-center gap-2 hover:bg-[var(--bg-subtle)] cursor-pointer text-left"
                >
                  <Pin size={13.5} className="text-[var(--text-secondary)] shrink-0" />
                  <span>
                    {contextMenu.asset.pinnedOffline ? '取消始终保留在本地' : '始终保留在本地'}
                  </span>
                </button>

                <button
                  type="button"
                  role="menuitem"
                  onClick={() => {
                    void handleAIAnalyze(contextTargetIDs);
                    setContextMenu(null);
                  }}
                  className="w-full px-3 py-1.5 flex items-center gap-2 hover:bg-[var(--bg-subtle)] cursor-pointer text-left"
                >
                  <Sparkles size={13.5} className="text-[var(--text-secondary)] shrink-0" />
                  <span>AI 重新打标{contextCountSuffix}</span>
                </button>

                <div className="my-1 border-t border-[var(--border-hairline)]" />

                <button
                  type="button"
                  role="menuitem"
                  onClick={() => {
                    void trashAssets(contextTargetIDs);
                    setContextMenu(null);
                  }}
                  className="w-full px-3 py-1.5 flex items-center gap-2 hover:bg-[var(--danger-soft)] text-[var(--danger)] cursor-pointer text-left"
                >
                  <Trash2 size={13.5} className="shrink-0" />
                  <span>移至废纸篓{contextCountSuffix}</span>
                </button>
              </>
            ) : (
              <>
                <button
                  type="button"
                  role="menuitem"
                  onClick={() => {
                    void restoreAssets(contextTargetIDs);
                    setContextMenu(null);
                  }}
                  className="w-full px-3 py-1.5 flex items-center gap-2 hover:bg-[var(--bg-subtle)] cursor-pointer text-left"
                >
                  <Undo2 size={13.5} className="text-[var(--text-secondary)] shrink-0" />
                  <span>放回原处{contextCountSuffix}</span>
                </button>

                <button
                  type="button"
                  role="menuitem"
                  onClick={() => {
                    void permanentlyDeleteAssets(contextTargetIDs);
                    setContextMenu(null);
                  }}
                  className="w-full px-3 py-1.5 flex items-center gap-2 hover:bg-[var(--danger-soft)] text-[var(--danger)] cursor-pointer text-left"
                >
                  <Trash2 size={13.5} className="shrink-0" />
                  <span>彻底删除{contextCountSuffix}</span>
                </button>
              </>
            )}
          </div>,
          document.body,
        )}
    </div>
  );
};
