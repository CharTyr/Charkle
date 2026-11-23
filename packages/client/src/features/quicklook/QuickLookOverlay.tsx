import React, { useCallback, useEffect, useMemo, useRef, useState } from 'react';
import { createPortal } from 'react-dom';
import {
  ChevronLeft,
  ChevronRight,
  Download,
  FlipHorizontal2,
  FlipVertical2,
  Info,
  RotateCcw,
  RotateCw,
  Star,
  X,
  ZoomIn,
  ZoomOut,
} from 'lucide-react';
import {
  createDefaultAssetBatchPatch,
  getAssetDisplayTypeLabel,
} from '@charkle/shared';
import type { AssetRecord } from '@charkle/shared';
import { apiClient } from '../../api/client';
import { stopAllHoverPreviews } from '../../components/HoverMediaPreview';
import {
  computeAmbientTintStyle,
  formatBytes,
  useResolvedIsDark,
} from '../../design-system';
import { useCoordinatorStore } from '../../stores/coordinatorStore';
import { useLibraryStore } from '../../stores/libraryStore';
import { isEditableElement } from '../capture/captureUtils';
import { getCardEffectiveAspectRatio } from '../gallery/assetCardUtils';
import { AudioStudioViewer } from './AudioStudioViewer';
import { DocumentMarkdownViewer } from './DocumentMarkdownViewer';
import { GitHubRepoViewer } from './GitHubRepoViewer';
import {
  classifyAssetViewerKind,
  ColorSwatchViewer,
  computeQuarterTurnFitScale,
  computeWheelZoomFactor,
  LazyModel3DViewer,
  supportsVisualTransform,
  useHorizontalWheelRedirect,
  WebBookmarkViewer,
} from './MediaStageHelpers';
import { SocialPostViewer } from './SocialPostViewer';

export const QuickLookOverlay: React.FC = () => {
  const quickLookAssetID = useCoordinatorStore((s) => s.quickLookAssetID);
  const closeQuickLook = useCoordinatorStore((s) => s.closeQuickLook);
  const openQuickLook = useCoordinatorStore((s) => s.openQuickLook);
  const pushToast = useCoordinatorStore((s) => s.pushToast);

  const assets = useLibraryStore((s) => s.assets);
  const assetsByID = useLibraryStore((s) => s.assetsByID);
  const cacheBust = useLibraryStore((s) => s.cacheBustVersion);
  const markOpened = useLibraryStore((s) => s.markOpened);
  const batchPatch = useLibraryStore((s) => s.batchPatch);
  const selectAsset = useLibraryStore((s) => s.selectAsset);

  const isDark = useResolvedIsDark();

  const [chromeVisible, setChromeVisible] = useState(false);
  const [sidePanelOpen, setSidePanelOpen] = useState(false);
  const [zoom, setZoom] = useState(1);
  const [pan, setPan] = useState({ x: 0, y: 0 });
  const [rotation, setRotation] = useState(0);
  const [flipH, setFlipH] = useState(false);
  const [flipV, setFlipV] = useState(false);
  const [draggingPan, setDraggingPan] = useState(false);
  const [stageSize, setStageSize] = useState({ width: 0, height: 0 });
  const [naturalSize, setNaturalSize] = useState<{ width: number; height: number } | null>(null);

  const panOriginRef = useRef({ x: 0, y: 0, panX: 0, panY: 0 });
  const stageRef = useRef<HTMLDivElement | null>(null);
  const filmstripRef = useRef<HTMLDivElement | null>(null);

  const currentIndex = useMemo(() => {
    if (!quickLookAssetID) return -1;
    return assets.findIndex((a) => a.id === quickLookAssetID);
  }, [assets, quickLookAssetID]);

  const asset: AssetRecord | null = useMemo(() => {
    if (!quickLookAssetID) return null;
    if (currentIndex >= 0) return assets[currentIndex];
    return assetsByID[quickLookAssetID] ?? null;
  }, [quickLookAssetID, currentIndex, assets, assetsByID]);

  const isVisualImage = asset ? supportsVisualTransform(asset) : false;

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

  const stepTo = useCallback(
    (delta: number) => {
      if (assets.length === 0 || currentIndex < 0) return;
      const nextIdx = Math.max(0, Math.min(assets.length - 1, currentIndex + delta));
      if (nextIdx === currentIndex) return;
      const next = assets[nextIdx];
      selectAsset(next.id, 'replace');
      openQuickLook(next.id);
    },
    [assets, currentIndex, selectAsset, openQuickLook],
  );

  // Stop any hover preview, reset transforms, and run 40ms staggered HUD reveal
  useEffect(() => {
    if (!quickLookAssetID) {
      setChromeVisible(false);
      return;
    }
    stopAllHoverPreviews();
    resetTransforms();
    setNaturalSize(null);
    void markOpened(quickLookAssetID);

    const timer = window.setTimeout(() => setChromeVisible(true), 40);
    return () => window.clearTimeout(timer);
  }, [quickLookAssetID, markOpened, resetTransforms]);

  // Measure live stage dimensions for exact quarter-turn fit scaling
  useEffect(() => {
    if (!quickLookAssetID) return;
    const el = stageRef.current;
    if (!el || typeof ResizeObserver === 'undefined') return;
    const update = () => {
      setStageSize({ width: el.clientWidth, height: el.clientHeight });
    };
    update();
    const ro = new ResizeObserver(update);
    ro.observe(el);
    return () => ro.disconnect();
  }, [quickLookAssetID, sidePanelOpen]);

  // Smooth exponential wheel zoom on the visual stage
  useEffect(() => {
    if (!quickLookAssetID || !isVisualImage) return;
    const el = stageRef.current;
    if (!el) return;

    const onWheel = (e: WheelEvent) => {
      if (e.deltaY === 0) return;
      e.preventDefault();
      const factor = computeWheelZoomFactor(e);
      setZoom((z) => {
        const next = Math.max(0.5, Math.min(5, Number((z * factor).toFixed(3))));
        if (next <= 1.01) setPan({ x: 0, y: 0 });
        return next;
      });
    };

    el.addEventListener('wheel', onWheel, { passive: false });
    return () => el.removeEventListener('wheel', onWheel);
  }, [quickLookAssetID, isVisualImage]);

  // Vertical mouse wheel -> horizontal scroll on Quick Look bottom filmstrip
  useHorizontalWheelRedirect(filmstripRef, Boolean(quickLookAssetID) && assets.length > 1);

  // Keyboard shortcuts (Space/Esc, Arrows, R/⇧R, ⇧H/⇧V, +/=/-, 0)
  useEffect(() => {
    if (!quickLookAssetID) return;
    const onKeyDown = (e: KeyboardEvent) => {
      if (e.key === 'Escape' || (e.key === ' ' && !isEditableElement(e.target))) {
        e.preventDefault();
        e.stopPropagation();
        closeQuickLook();
        return;
      }
      if (isEditableElement(e.target)) return;

      if (e.key === 'ArrowRight') {
        e.preventDefault();
        stepTo(1);
        return;
      }
      if (e.key === 'ArrowLeft') {
        e.preventDefault();
        stepTo(-1);
        return;
      }

      if (!isVisualImage || e.metaKey || e.ctrlKey || e.altKey) return;

      if (e.key === 'r' || e.key === 'R') {
        e.preventDefault();
        const parity = flipH !== flipV ? -1 : 1;
        const delta = (e.shiftKey ? -90 : 90) * parity;
        setRotation((r) => (r + delta) % 360);
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
    window.addEventListener('keydown', onKeyDown, true);
    return () => window.removeEventListener('keydown', onKeyDown, true);
  }, [
    quickLookAssetID,
    isVisualImage,
    flipH,
    flipV,
    closeQuickLook,
    stepTo,
    applyZoomMultiplier,
    resetTransforms,
  ]);

  if (!quickLookAssetID || !asset || typeof document === 'undefined') return null;

  const viewerKind = classifyAssetViewerKind(asset);
  const quarterFitScale = isVisualImage
    ? computeQuarterTurnFitScale(stageSize, asset, rotation, naturalSize)
    : 1;

  const primaryHex = asset.dominantColors[0]?.hex;
  const ambientStyle = computeAmbientTintStyle(primaryHex, isDark, 'quicklook');

  return createPortal(
    <div
      className="fixed inset-0 z-[150] flex flex-col select-none"
      style={{
        backgroundColor: isDark ? 'rgba(0, 0, 0, 0.78)' : 'rgba(21, 22, 25, 0.70)',
        backdropFilter: 'blur(18px)',
        WebkitBackdropFilter: 'blur(18px)',
      }}
      onClick={(e) => {
        if (e.target === e.currentTarget) closeQuickLook();
      }}
    >
      {/* Ambient Color Tint Layer */}
      <div
        aria-hidden="true"
        className="pointer-events-none absolute inset-0"
        style={ambientStyle}
      />

      {/* Top Floating Liquid Glass HUD (40ms stagger) */}
      <div
        className="relative z-20 flex items-center justify-between gap-3 px-5 pt-4 pb-2 transition-opacity duration-[var(--duration-sm)] ease-[var(--ease-out)]"
        style={{ opacity: chromeVisible ? 1 : 0 }}
      >
        <div className="charkle-glass-dark px-3.5 py-1.5 rounded-full flex items-center gap-2.5 max-w-[52vw]">
          <span className="text-[13px] font-medium text-white truncate">{asset.title}</span>
          <span className="text-[11.5px] text-white/60 shrink-0">
            {getAssetDisplayTypeLabel(asset)}
            {asset.pixelWidth > 0 && ` · ${asset.pixelWidth}×${asset.pixelHeight}`}
          </span>
        </div>

        <div className="charkle-glass-dark p-1 rounded-full flex items-center gap-0.5">
          {isVisualImage && (
            <>
              <button
                type="button"
                title="缩小 (-)"
                onClick={() => applyZoomMultiplier(0.8)}
                className="charkle-pressable h-7.5 w-7.5 rounded-full hover:bg-white/12 text-white/85 flex items-center justify-center cursor-pointer"
              >
                <ZoomOut size={14} />
              </button>
              <button
                type="button"
                title="重置缩放与变换 (0)"
                onClick={resetTransforms}
                className="charkle-pressable text-[11px] font-mono text-white/80 hover:text-white w-11 h-7.5 rounded-full hover:bg-white/10 text-center tabular-nums cursor-pointer"
              >
                {Math.round(zoom * 100)}%
              </button>
              <button
                type="button"
                title="放大 (+)"
                onClick={() => applyZoomMultiplier(1.25)}
                className="charkle-pressable h-7.5 w-7.5 rounded-full hover:bg-white/12 text-white/85 flex items-center justify-center cursor-pointer"
              >
                <ZoomIn size={14} />
              </button>
              <button
                type="button"
                title="顺时针旋转 90° (R)"
                onClick={() => setRotation((r) => (r + (flipH !== flipV ? -90 : 90)) % 360)}
                className="charkle-pressable h-7.5 w-7.5 rounded-full hover:bg-white/12 text-white/85 flex items-center justify-center cursor-pointer"
              >
                <RotateCw size={14} />
              </button>
              <button
                type="button"
                title="水平翻转 (⇧H)"
                onClick={() => setFlipH((v) => !v)}
                className={[
                  'charkle-pressable h-7.5 w-7.5 rounded-full flex items-center justify-center cursor-pointer',
                  flipH ? 'bg-white/22 text-white' : 'hover:bg-white/12 text-white/85',
                ].join(' ')}
              >
                <FlipHorizontal2 size={14} />
              </button>
              <button
                type="button"
                title="垂直翻转 (⇧V)"
                onClick={() => setFlipV((v) => !v)}
                className={[
                  'charkle-pressable h-7.5 w-7.5 rounded-full flex items-center justify-center cursor-pointer',
                  flipV ? 'bg-white/22 text-white' : 'hover:bg-white/12 text-white/85',
                ].join(' ')}
              >
                <FlipVertical2 size={14} />
              </button>
              <button
                type="button"
                title="重置视图 (0)"
                onClick={resetTransforms}
                className="charkle-pressable h-7.5 w-7.5 rounded-full hover:bg-white/12 text-white/85 flex items-center justify-center cursor-pointer"
              >
                <RotateCcw size={13} />
              </button>
              <div className="w-px h-4 bg-white/15 mx-1" />
            </>
          )}

          <a
            href={apiClient.originalMediaURL(asset.id, { download: true })}
            download={asset.fileName}
            title="下载原文件"
            className="charkle-pressable h-7.5 w-7.5 rounded-full hover:bg-white/12 text-white/85 flex items-center justify-center"
          >
            <Download size={14} />
          </a>

          <button
            type="button"
            title="切换右侧信息面板"
            onClick={() => setSidePanelOpen((v) => !v)}
            className={[
              'charkle-pressable h-7.5 w-7.5 rounded-full flex items-center justify-center cursor-pointer',
              sidePanelOpen ? 'bg-white/22 text-white' : 'hover:bg-white/12 text-white/85',
            ].join(' ')}
          >
            <Info size={14} />
          </button>

          <button
            type="button"
            title="关闭 (Space / Esc)"
            onClick={closeQuickLook}
            className="charkle-pressable h-7.5 w-7.5 rounded-full hover:bg-white/16 text-white flex items-center justify-center cursor-pointer"
          >
            <X size={15} />
          </button>
        </div>
      </div>

      {/* Main Media Stage + Collapsible Info Rail (--ease-drawer) */}
      <div className="relative z-10 flex-1 min-h-0 flex items-center justify-center px-14 py-3 overflow-hidden">
        {/* Left/Right Navigation Chevrons */}
        {currentIndex > 0 && (
          <button
            type="button"
            onClick={() => stepTo(-1)}
            aria-label="上一项"
            style={{ opacity: chromeVisible ? 1 : 0 }}
            className="charkle-pressable charkle-glass-dark absolute left-4 top-1/2 -translate-y-1/2 z-20 h-10 w-10 rounded-full flex items-center justify-center text-white cursor-pointer transition-opacity duration-[var(--duration-sm)] ease-[var(--ease-out)]"
          >
            <ChevronLeft size={20} />
          </button>
        )}
        {currentIndex >= 0 && currentIndex < assets.length - 1 && (
          <button
            type="button"
            onClick={() => stepTo(1)}
            aria-label="下一项"
            style={{ opacity: chromeVisible ? 1 : 0 }}
            className="charkle-pressable charkle-glass-dark absolute right-4 top-1/2 -translate-y-1/2 z-20 h-10 w-10 rounded-full flex items-center justify-center text-white cursor-pointer transition-opacity duration-[var(--duration-sm)] ease-[var(--ease-out)]"
          >
            <ChevronRight size={20} />
          </button>
        )}

        {/* Dedicated 8-Media-Type Viewer Switch */}
        <div
          ref={stageRef}
          className="flex-1 min-w-0 h-full flex items-center justify-center overflow-hidden"
          onClick={(e) => {
            if (e.target === e.currentTarget) closeQuickLook();
          }}
        >
          {viewerKind === 'githubRepo' && asset.richMetadata?.githubRepo ? (
            <GitHubRepoViewer asset={asset} repo={asset.richMetadata.githubRepo} />
          ) : viewerKind === 'socialPost' && asset.richMetadata?.socialPost ? (
            <SocialPostViewer asset={asset} post={asset.richMetadata.socialPost} />
          ) : viewerKind === 'swatch' ? (
            <ColorSwatchViewer asset={asset} />
          ) : viewerKind === 'audio' ? (
            <AudioStudioViewer asset={asset} />
          ) : viewerKind === 'model3D' ? (
            <React.Suspense
              fallback={
                <div className="w-[min(960px,92vw)] h-[min(640px,76vh)] rounded-[var(--radius-dock-outer)] bg-[#181A20] flex items-center justify-center text-white text-[13px] gap-2">
                  <span className="h-4 w-4 rounded-full border-2 border-[#5B8DEF] border-t-transparent animate-spin" />
                  正在初始化 3D 预览引擎…
                </div>
              }
            >
              <LazyModel3DViewer asset={asset} />
            </React.Suspense>
          ) : viewerKind === 'document' ? (
            <DocumentMarkdownViewer asset={asset} />
          ) : viewerKind === 'video' ? (
            <video
              key={asset.id}
              src={apiClient.originalMediaURL(asset.id)}
              poster={apiClient.thumbnailURL(asset.id, 'preview1400', `${asset.updatedAt}-${cacheBust}`)}
              controls
              autoPlay
              playsInline
              className="max-w-full max-h-full rounded-[var(--radius-card-outer)] shadow-2xl"
            />
          ) : viewerKind === 'webBookmark' ? (
            <WebBookmarkViewer asset={asset} cacheBust={cacheBust} />
          ) : (
            /* Image / Animated GIF / Design File with exact flip-wraps-rotate transform order */
            <img
              key={asset.id}
              src={
                asset.mediaKind === 'animatedImage'
                  ? apiClient.originalMediaURL(asset.id)
                  : apiClient.thumbnailURL(asset.id, 'preview1400', `${asset.updatedAt}-${cacheBust}`)
              }
              alt={asset.title}
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
                transform: `translate3d(${pan.x}px, ${pan.y}px, 0) scale(${zoom * quarterFitScale}) scaleX(${flipH ? -1 : 1}) scaleY(${flipV ? -1 : 1}) rotate(${rotation}deg)`,
                transition: draggingPan
                  ? 'none'
                  : 'transform var(--duration-settle) var(--ease-out-strong)',
                cursor: zoom > 1.01 ? (draggingPan ? 'grabbing' : 'grab') : 'zoom-in',
              }}
              className="max-w-full max-h-full object-contain rounded-[var(--radius-card-outer)] shadow-2xl"
            />
          )}
        </div>

        {/* Collapsible Quick Look Info Rail (288px, --ease-drawer 300ms) */}
        <div
          aria-hidden={!sidePanelOpen}
          className={[
            'shrink-0 max-h-full overflow-hidden',
            'transition-[width,margin,opacity,transform] duration-[var(--duration-drawer)] ease-[var(--ease-drawer)]',
            sidePanelOpen
              ? 'w-[288px] ml-4 opacity-100 translate-x-0 pointer-events-auto'
              : 'w-0 ml-0 opacity-0 translate-x-3 pointer-events-none',
          ].join(' ')}
        >
          <div className="charkle-glass-dark w-[288px] max-h-full rounded-[var(--radius-dock-outer)] p-4 overflow-y-auto charkle-scroll flex flex-col gap-3">
            <div className="text-[13.5px] font-semibold text-white">{asset.title}</div>
            <div className="flex items-center gap-1">
              {[1, 2, 3, 4, 5].map((star) => (
                <button
                  key={star}
                  type="button"
                  onClick={() =>
                    void batchPatch(
                      createDefaultAssetBatchPatch([asset.id], {
                        rating: asset.rating === star ? 0 : star,
                      }),
                    )
                  }
                  className="p-0.5 cursor-pointer"
                >
                  <Star
                    size={15}
                    className={
                      asset.rating >= star
                        ? 'fill-[#F2C14E] text-[#F2C14E] charkle-micro-pop'
                        : 'text-white/30'
                    }
                  />
                </button>
              ))}
            </div>

            {asset.dominantColors.length > 0 && (
              <div className="flex gap-1.5">
                {asset.dominantColors.slice(0, 6).map((c) => (
                  <button
                    key={c.hex}
                    type="button"
                    title={c.hex}
                    onClick={async () => {
                      await navigator.clipboard.writeText(c.hex).catch(() => {});
                      pushToast({ tone: 'info', message: `已复制 ${c.hex}` });
                    }}
                    className="flex-1 h-6 rounded-[6px] border border-white/20 cursor-pointer"
                    style={{ backgroundColor: c.hex }}
                  />
                ))}
              </div>
            )}

            {asset.tags.length > 0 && (
              <div className="flex flex-wrap gap-1">
                {asset.tags.map((t) => (
                  <span key={t} className="px-2 py-0.5 rounded-full bg-white/10 text-[11px] text-white/85">
                    #{t}
                  </span>
                ))}
              </div>
            )}

            {asset.notes && (
              <p className="text-[12px] text-white/75 leading-relaxed whitespace-pre-wrap">
                {asset.notes}
              </p>
            )}

            <div className="text-[11.5px] text-white/55 flex flex-col gap-1 pt-2 border-t border-white/10 font-mono">
              <div>文件名：{asset.fileName}</div>
              <div>大小：{formatBytes(asset.fileSizeBytes)}</div>
              {asset.pixelWidth > 0 && (
                <div>
                  分辨率：{asset.pixelWidth} × {asset.pixelHeight}
                </div>
              )}
            </div>
          </div>
        </div>
      </div>

      {/* Bottom Floating Liquid Glass Filmstrip (with vertical->horizontal wheel redirect) */}
      {assets.length > 1 && (
        <div
          className="relative z-20 pb-4 px-6 flex justify-center transition-opacity duration-[var(--duration-sm)] ease-[var(--ease-out)]"
          style={{ opacity: chromeVisible ? 1 : 0 }}
        >
          <div
            ref={filmstripRef}
            className="charkle-glass-dark max-w-[min(780px,92vw)] px-2.5 py-2 rounded-[var(--radius-dock-outer)] flex items-center gap-1.5 overflow-x-auto charkle-scroll"
          >
            {assets
              .slice(Math.max(0, currentIndex - 15), Math.min(assets.length, currentIndex + 16))
              .map((item) => {
                const active = item.id === asset.id;
                const ratio = Math.max(0.65, Math.min(1.65, getCardEffectiveAspectRatio(item)));
                return (
                  <button
                    key={item.id}
                    type="button"
                    onClick={() => {
                      selectAsset(item.id, 'replace');
                      openQuickLook(item.id);
                    }}
                    style={{ width: Math.round(44 * ratio), height: 44 }}
                    className={[
                      'shrink-0 overflow-hidden rounded-[8px] cursor-pointer transition-opacity duration-[var(--duration-sm)] ease-[var(--ease-out)]',
                      active ? 'ring-2 ring-white opacity-100' : 'opacity-50 hover:opacity-85',
                    ].join(' ')}
                  >
                    <img
                      src={apiClient.thumbnailURL(item.id, 'grid520', cacheBust)}
                      alt={item.title}
                      className="w-full h-full object-cover"
                    />
                  </button>
                );
              })}
          </div>
        </div>
      )}
    </div>,
    document.body,
  );
};
