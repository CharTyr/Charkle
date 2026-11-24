import React, { useCallback, useEffect, useMemo, useRef, useState } from 'react';
import {
  ArrowDownCircle,
  ChevronLeft,
  ChevronRight,
  Cloud,
  Copy,
  ExternalLink,
  Eye,
  FolderInput,
  FolderOpen,
  Globe,
  LayoutGrid,
  RotateCcw,
  SlidersHorizontal,
  Sparkles,
  Trash2,
} from 'lucide-react';
import { getTransport } from '../../api/transport';
import {
  Button,
  CharkleIcon,
  CharkleSlider,
  ModalShell,
  Popover,
  useResolvedIsDark,
} from '../../design-system';
import {
  useCoordinatorStore,
  useLibraryStore,
  useMoodboardStore,
} from '../../stores';
import type { AssetRecord } from '../../types/domain';
import { FolderMoveMenu } from '../sidebar/FolderMoveMenu';
import {
  areRingParamsEqual,
  createDefaultRingParams,
  DEFAULT_RING_GALLERY_PARAMS,
  farFadeAmount,
  ringRadius,
  type RingGalleryParameters,
  type RingProjectedCard,
} from './ringGalleryMath';
import { appendCacheBust, RingGalleryWebGLEngine } from './ringGalleryWebGL';

export interface GalleryRingViewProps {
  assets: AssetRecord[];
  topInset?: number;
}

function isPlainWebBookmark(asset: AssetRecord): boolean {
  return (
    asset.mediaKind === 'webBookmark' &&
    !asset.richMetadata?.githubRepo &&
    !asset.richMetadata?.socialPost &&
    Boolean(asset.sourceURL?.trim())
  );
}

function bookmarkDomainLabel(asset: AssetRecord): string {
  if (asset.sourceDomain) return asset.sourceDomain;
  if (asset.sourceURL) {
    try {
      return new URL(asset.sourceURL).host.replace(/^www\./i, '');
    } catch {
      return asset.sourceURL;
    }
  }
  return '网页';
}

function isTypingElement(target: EventTarget | null): boolean {
  const el = target as HTMLElement | null;
  if (!el) return false;
  const tag = el.tagName;
  return tag === 'INPUT' || tag === 'TEXTAREA' || tag === 'SELECT' || el.isContentEditable;
}

function useReducedMotionFlag(): boolean {
  const [reduced, setReduced] = useState<boolean>(() =>
    typeof window !== 'undefined' && typeof window.matchMedia === 'function'
      ? window.matchMedia('(prefers-reduced-motion: reduce)').matches
      : false,
  );

  useEffect(() => {
    if (typeof window === 'undefined' || typeof window.matchMedia !== 'function') return;
    const mq = window.matchMedia('(prefers-reduced-motion: reduce)');
    const onChange = () => setReduced(mq.matches);
    onChange();
    mq.addEventListener?.('change', onChange);
    return () => mq.removeEventListener?.('change', onChange);
  }, []);

  return reduced;
}

/**
 * Interactive 3D Outside Ring Gallery (Gallery 4th View, 1:1 port of macOS `GalleryRingView.swift`).
 * Powered by demand-driven WebGL2 GLSL ES 3.00 shaders (96-column curved strip, superellipse-4 SDF,
 * hardware mipmap DoF blur, far-side ground fade, 48-slot LRU texture pool) with 0% idle GPU/CPU.
 */
export const GalleryRingView: React.FC<GalleryRingViewProps> = ({
  assets,
  topInset = 68,
}) => {
  const isDark = useResolvedIsDark();
  const reduceMotion = useReducedMotionFlag();
  const transport = getTransport();

  const destination = useCoordinatorStore((s) => s.destination);
  const selectedAssetIds = useCoordinatorStore((s) => s.selectedAssetIds);
  const setSelection = useCoordinatorStore((s) => s.setSelection);
  const clearSelection = useCoordinatorStore((s) => s.clearSelection);
  const openQuickLook = useCoordinatorStore((s) => s.openQuickLook);
  const setMoodboardGeneratorOpen = useCoordinatorStore((s) => s.setMoodboardGeneratorOpen);
  const pushToast = useCoordinatorStore((s) => s.pushToast);

  const isOverlayPresented = useCoordinatorStore(
    (s) =>
      s.quickLookAssetId !== null ||
      s.settingsOpen ||
      s.onboardingOpen ||
      s.jumpOpen ||
      s.captureOpen ||
      s.moodboardGeneratorOpen,
  );

  const folders = useLibraryStore((s) => s.folders);
  const updateAssets = useLibraryStore((s) => s.updateAssets);
  const permanentlyDeleteAssets = useLibraryStore((s) => s.permanentlyDeleteAssets);
  const boards = useMoodboardStore((s) => s.boards);
  const addAssetsToBoard = useMoodboardStore((s) => s.addAssetsToBoard);

  const containerRef = useRef<HTMLDivElement | null>(null);
  const canvasRef = useRef<HTMLCanvasElement | null>(null);
  const engineRef = useRef<RingGalleryWebGLEngine | null>(null);

  const [params, setParams] = useState<RingGalleryParameters>(() => createDefaultRingParams());
  const [tuningOpen, setTuningOpen] = useState(false);
  const [frontAsset, setFrontAsset] = useState<AssetRecord | null>(() => assets[0] ?? null);
  const [isWebGL2, setIsWebGL2] = useState(true);
  const [fallbackState, setFallbackState] = useState<{
    cards: RingProjectedCard[];
    cardScale: number;
    verticalBias: number;
  }>({ cards: [], cardScale: 1, verticalBias: 0 });

  const [contextTarget, setContextTarget] = useState<{
    asset: AssetRecord;
    point: { x: number; y: number };
    targetIds: string[];
  } | null>(null);
  const [moveSubOpen, setMoveSubOpen] = useState(false);
  const [boardSubOpen, setBoardSubOpen] = useState(false);
  const [permDeleteIds, setPermDeleteIds] = useState<string[] | null>(null);

  const pruneSelectionIds = useCallback(
    (removedIds: readonly string[]) => {
      const removedSet = new Set(removedIds);
      const remaining = useCoordinatorStore
        .getState()
        .selectedAssetIds.filter((id) => !removedSet.has(id));
      if (remaining.length === 0) {
        clearSelection();
      } else {
        setSelection(remaining, remaining[0]);
      }
    },
    [clearSelection, setSelection],
  );

  const activeAsset = useMemo(() => {
    if (frontAsset) {
      const fresh = assets.find((a) => a.id === frontAsset.id);
      if (fresh) return fresh;
    }
    if (selectedAssetIds[0]) {
      const selected = assets.find((a) => a.id === selectedAssetIds[0]);
      if (selected) return selected;
    }
    return assets[0] ?? null;
  }, [assets, frontAsset, selectedAssetIds]);

  const activeIndex = useMemo(() => {
    if (!activeAsset) return -1;
    return assets.findIndex((a) => a.id === activeAsset.id);
  }, [assets, activeAsset]);

  const handleOpenAsset = useCallback(
    (asset: AssetRecord) => {
      setSelection([asset.id], asset.id);
      if (isPlainWebBookmark(asset) && asset.sourceURL) {
        const domain = bookmarkDomainLabel(asset);
        void transport
          .openExternalUrl(asset.sourceURL)
          .then(() => {
            pushToast({ message: `已在默认浏览器中打开 ${domain}`, tone: 'info' });
          })
          .catch((err) => {
            pushToast({
              message: err instanceof Error ? err.message : '无法打开网页链接',
              tone: 'error',
            });
          });
        void transport.markAssetOpened(asset.id);
        return;
      }
      openQuickLook(asset.id, null);
    },
    [openQuickLook, pushToast, setSelection, transport],
  );

  const callbacksRef = useRef({
    onFrontAssetChanged: (asset: AssetRecord | null) => {
      setFrontAsset(asset);
      if (asset) {
        const currentSel = useCoordinatorStore.getState().selectedAssetIds;
        if (currentSel.length <= 1 && currentSel[0] !== asset.id) {
          setSelection([asset.id], asset.id);
        }
        void transport.markAssetOpened(asset.id);
      }
    },
    onOpenAsset: handleOpenAsset,
    onContextMenuRequest: (asset: AssetRecord, clientX: number, clientY: number) => {
      const latestSel = useCoordinatorStore.getState().selectedAssetIds;
      let snapshotIds: string[];
      if (latestSel.includes(asset.id) && latestSel.length > 1) {
        snapshotIds = [...latestSel];
      } else {
        setSelection([asset.id], asset.id);
        snapshotIds = [asset.id];
      }
      setMoveSubOpen(false);
      setBoardSubOpen(false);
      setContextTarget({ asset, point: { x: clientX, y: clientY }, targetIds: snapshotIds });
    },
  });

  callbacksRef.current = {
    onFrontAssetChanged: (asset: AssetRecord | null) => {
      setFrontAsset(asset);
      if (asset) {
        const currentSel = useCoordinatorStore.getState().selectedAssetIds;
        if (currentSel.length <= 1 && currentSel[0] !== asset.id) {
          setSelection([asset.id], asset.id);
        }
        void transport.markAssetOpened(asset.id);
      }
    },
    onOpenAsset: handleOpenAsset,
    onContextMenuRequest: (asset: AssetRecord, clientX: number, clientY: number) => {
      const latestSel = useCoordinatorStore.getState().selectedAssetIds;
      let snapshotIds: string[];
      if (latestSel.includes(asset.id) && latestSel.length > 1) {
        snapshotIds = [...latestSel];
      } else {
        setSelection([asset.id], asset.id);
        snapshotIds = [asset.id];
      }
      setMoveSubOpen(false);
      setBoardSubOpen(false);
      setContextTarget({ asset, point: { x: clientX, y: clientY }, targetIds: snapshotIds });
    },
  };

  // Mount / unmount WebGL2 engine + ResizeObserver
  useEffect(() => {
    const canvas = canvasRef.current;
    const container = containerRef.current;
    if (!canvas || !container) return;

    const engine = new RingGalleryWebGLEngine(canvas);
    engineRef.current = engine;
    setIsWebGL2(engine.isWebGL2);

    const measureAndResize = () => {
      const rect = container.getBoundingClientRect();
      if (rect.width > 0 && rect.height > 0) {
        engine.resize(rect.width, rect.height, window.devicePixelRatio || 1);
      } else {
        engine.resize(960, 600, 1);
      }
    };
    measureAndResize();

    const ro =
      typeof ResizeObserver !== 'undefined'
        ? new ResizeObserver(() => measureAndResize())
        : null;
    ro?.observe(container);

    return () => {
      ro?.disconnect();
      engine.dispose();
      engineRef.current = null;
    };
  }, []);

  // Push live props & geometry into the WebGL2 engine
  useEffect(() => {
    const engine = engineRef.current;
    if (!engine) return;
    engine.configure({
      assets,
      selectedAssetId: selectedAssetIds[0] ?? null,
      params,
      isDarkMode: isDark,
      reduceMotion,
      topSafeInset: topInset,
      callbacks: {
        onFrontAssetChanged: (a) => callbacksRef.current.onFrontAssetChanged(a),
        onOpenAsset: (a) => callbacksRef.current.onOpenAsset(a),
        onContextMenuRequest: (a, x, y) => callbacksRef.current.onContextMenuRequest(a, x, y),
        onFallbackProjected: (cards, cardScale, verticalBias) =>
          setFallbackState({ cards, cardScale, verticalBias }),
      },
    });
  }, [assets, selectedAssetIds, params, isDark, reduceMotion, topInset]);

  // Non-passive wheel listener (strictly suspended while modal overlays / Quick Look are open)
  useEffect(() => {
    const container = containerRef.current;
    if (!container) return;
    const onWheel = (e: WheelEvent) => {
      if (isOverlayPresented) return;
      const target = e.target as HTMLElement | null;
      if (target?.closest('[data-ring-hud="true"]')) return;
      e.preventDefault();
      engineRef.current?.handleWheel(e.deltaX, e.deltaY, e.deltaMode);
    };
    container.addEventListener('wheel', onWheel, { passive: false });
    return () => container.removeEventListener('wheel', onWheel);
  }, [isOverlayPresented]);

  // Keyboard stepping (ArrowLeft / ArrowRight) + Escape closes tuning panel — suspended when overlays present
  useEffect(() => {
    const onKeyDown = (e: KeyboardEvent) => {
      if (e.defaultPrevented || isOverlayPresented) return;

      if (e.key === 'Escape' && tuningOpen) {
        e.preventDefault();
        e.stopPropagation();
        setTuningOpen(false);
        return;
      }

      if (isTypingElement(e.target)) return;
      const hasPrimaryModifiers = e.ctrlKey || e.metaKey || e.altKey || e.shiftKey;
      if (hasPrimaryModifiers) return;

      if (e.key === 'ArrowLeft') {
        e.preventDefault();
        engineRef.current?.step(-1);
      } else if (e.key === 'ArrowRight') {
        e.preventDefault();
        engineRef.current?.step(1);
      }
    };
    window.addEventListener('keydown', onKeyDown);
    return () => window.removeEventListener('keydown', onKeyDown);
  }, [isOverlayPresented, tuningOpen]);

  // Prompt floating Liquid Glass pills to resample the clean Ring Gallery page ground on mount
  useEffect(() => {
    window.dispatchEvent(new Event('charkle:glass-resample'));
  }, []);

  const isParamsModified = !areRingParamsEqual(params, DEFAULT_RING_GALLERY_PARAMS);
  const activeIsWebLink = activeAsset ? isPlainWebBookmark(activeAsset) : false;
  const contextTargetIds = contextTarget?.targetIds ?? [];
  const contextCountSuffix =
    contextTargetIds.length > 1 ? ` (${contextTargetIds.length} 项)` : '';

  return (
    <div
      ref={containerRef}
      data-testid="gallery-ring-view"
      className="relative flex-1 min-h-0 w-full overflow-hidden bg-[var(--bg-gallery)] select-none"
    >
      {/* Full-bleed WebGL2 3D Outside Ring Canvas */}
      <canvas
        ref={canvasRef}
        data-testid="ring-gallery-canvas"
        onPointerDown={(e) => {
          if (e.button !== 0) return;
          e.currentTarget.setPointerCapture?.(e.pointerId);
          engineRef.current?.handlePointerDown(e.clientX, e.clientY);
        }}
        onPointerMove={(e) => {
          engineRef.current?.handlePointerMove(e.clientX);
        }}
        onPointerUp={(e) => {
          if (e.currentTarget.hasPointerCapture?.(e.pointerId)) {
            e.currentTarget.releasePointerCapture(e.pointerId);
          }
          engineRef.current?.handlePointerUp(e.clientX, e.clientY, e.detail || 1);
        }}
        onPointerCancel={(e) => {
          if (e.currentTarget.hasPointerCapture?.(e.pointerId)) {
            e.currentTarget.releasePointerCapture(e.pointerId);
          }
          engineRef.current?.handlePointerUp(e.clientX, e.clientY, 1);
        }}
        onContextMenu={(e) => {
          const handled = engineRef.current?.handleContextMenu(e.clientX, e.clientY);
          if (handled) {
            e.preventDefault();
            e.stopPropagation();
          }
        }}
        className="block w-full h-full cursor-grab active:cursor-grabbing touch-none"
      />

      {/* Graceful DOM Fallback when WebGL2 is unavailable (e.g., headless tests / software fallback) */}
      {!isWebGL2 && fallbackState.cards.length > 0 && (
        <div
          data-testid="ring-gallery-fallback-stage"
          className="pointer-events-none absolute inset-0 overflow-hidden"
        >
          {fallbackState.cards.map((card) => {
            const asset = assets[card.assetIndex];
            if (!asset) return null;
            const w = Math.max(24, card.maxScreenX - card.minScreenX);
            const h = Math.max(36, card.maxHalfScreenY * 2);
            const centerX = (card.minScreenX + card.maxScreenX) * 0.5;
            const farFade = farFadeAmount(card.centerZ, ringRadius(params), params.farFade);
            const opacity = Math.max(0.04, Math.min(1, card.seamAlpha * (1 - farFade)));
            return (
              <button
                key={`${card.virtualIndex}-${asset.id}`}
                type="button"
                data-asset-id={asset.id}
                onClick={() => engineRef.current?.selectVirtualIndex(card.virtualIndex)}
                onDoubleClick={() => handleOpenAsset(asset)}
                onContextMenu={(e) => {
                  e.preventDefault();
                  e.stopPropagation();
                  callbacksRef.current.onContextMenuRequest(asset, e.clientX, e.clientY);
                }}
                style={{
                  left: `calc(50% + ${centerX.toFixed(1)}px)`,
                  top: `calc(50% - ${fallbackState.verticalBias.toFixed(1)}px)`,
                  width: `${w.toFixed(1)}px`,
                  height: `${h.toFixed(1)}px`,
                  borderRadius: `${Math.round(params.cornerRadius * fallbackState.cardScale)}px`,
                  opacity,
                  transform: 'translate(-50%, -50%)',
                }}
                className="pointer-events-auto absolute overflow-hidden bg-[var(--bg-elevated)] shadow-md cursor-pointer"
              >
                {asset.fileName.toLowerCase().endsWith('.swatch') ? (
                  <div
                    className="w-full h-full flex items-end justify-center p-2"
                    style={{
                      backgroundColor: (asset.dominantColors[0]?.hex || '#2A60E0').toUpperCase(),
                    }}
                  >
                    <span className="px-1.5 py-0.5 rounded-[5px] bg-black/45 text-[10px] font-medium charkle-mono text-white">
                      {(asset.dominantColors[0]?.hex || '#2A60E0').toUpperCase()}
                    </span>
                  </div>
                ) : (
                  <img
                    src={appendCacheBust(transport.thumbnailUrl(asset.id, 'grid520'), asset.updatedAt)}
                    alt={asset.title}
                    draggable={false}
                    onError={(e) => {
                      e.currentTarget.style.display = 'none';
                    }}
                    className="w-full h-full object-cover"
                    style={{ backgroundColor: asset.dominantColors[0]?.hex || undefined }}
                  />
                )}
              </button>
            );
          })}
        </div>
      )}

      {/* Bottom HUD: Centered Navigation Capsule + Bottom-Right Collapsible Tuning Panel */}
      <div
        data-ring-hud="true"
        className="pointer-events-none absolute inset-x-[18px] bottom-[18px] z-20 flex items-end justify-center"
      >
        {activeAsset && (
          <div
            data-testid="ring-gallery-nav-pill"
            data-pill="true"
            data-adapt-glass="true"
            className="pointer-events-auto charkle-glass rounded-full px-2.5 py-1.5 inline-flex items-center gap-2 max-w-[calc(100%-120px)]"
          >
            <button
              type="button"
              aria-label="上一张"
              title="上一张 (←)"
              disabled={assets.length <= 1}
              onClick={() => engineRef.current?.step(-1)}
              className="charkle-pressable h-6 w-6 rounded-full inline-flex items-center justify-center text-[var(--text-primary)]/85 hover:bg-black/[0.06] dark:hover:bg-white/[0.12] cursor-pointer disabled:opacity-30 disabled:cursor-default shrink-0"
            >
              <ChevronLeft size={13} />
            </button>

            <div className="flex flex-col items-center min-w-0 max-w-[200px] leading-tight">
              <span className="text-[12px] font-semibold text-[var(--text-primary)] truncate w-full text-center">
                {activeAsset.title}
              </span>
              {activeIndex >= 0 && (
                <span className="text-[10px] font-medium charkle-mono charkle-tabular text-[var(--text-secondary)]">
                  {activeIndex + 1} / {assets.length}
                </span>
              )}
            </div>

            <button
              type="button"
              aria-label="下一张"
              title="下一张 (→)"
              disabled={assets.length <= 1}
              onClick={() => engineRef.current?.step(1)}
              className="charkle-pressable h-6 w-6 rounded-full inline-flex items-center justify-center text-[var(--text-primary)]/85 hover:bg-black/[0.06] dark:hover:bg-white/[0.12] cursor-pointer disabled:opacity-30 disabled:cursor-default shrink-0"
            >
              <ChevronRight size={13} />
            </button>

            <div className="h-4 w-px bg-[var(--border-hairline)] shrink-0" />

            <button
              type="button"
              data-pill="true"
              title={activeIsWebLink ? '在默认浏览器中打开 (Space)' : '全屏沉浸预览 (Space)'}
              onClick={() => handleOpenAsset(activeAsset)}
              className="charkle-pressable h-[26px] px-2.5 rounded-full inline-flex items-center gap-1.5 text-[11.5px] font-medium text-[var(--text-primary)] hover:bg-black/[0.06] dark:hover:bg-white/[0.12] cursor-pointer whitespace-nowrap shrink-0"
            >
              {activeIsWebLink ? (
                <>
                  <Globe size={12.5} className="text-[var(--accent)]" />
                  <span>浏览器打开</span>
                </>
              ) : (
                <>
                  <CharkleIcon name="quicklook" style="duotone" size={13.5} />
                  <span>沉浸预览</span>
                </>
              )}
            </button>
          </div>
        )}

        {/* Bottom-Right Collapsible Live Tuning Control */}
        <div className="pointer-events-none absolute right-0 bottom-0 flex flex-col items-end gap-2.5">
          {tuningOpen && (
            <div
              data-testid="ring-tuning-panel"
              data-no-lens="true"
              className="pointer-events-auto charkle-glass charkle-glass-panel charkle-reveal-bottom w-[276px] max-h-[calc(100vh-120px)] overflow-y-auto charkle-scroll p-3.5 rounded-[var(--radius-popover-outer)] flex flex-col gap-2.5"
            >
              <div className="flex items-center justify-between">
                <span className="text-[12px] font-semibold text-[var(--text-primary)]">
                  环形画廊参数
                </span>
                <button
                  type="button"
                  disabled={!isParamsModified}
                  onClick={() => setParams(createDefaultRingParams())}
                  className={[
                    'text-[11px] font-medium cursor-pointer disabled:cursor-default',
                    isParamsModified
                      ? 'text-[var(--accent)] hover:underline'
                      : 'text-[var(--text-tertiary)]',
                  ].join(' ')}
                >
                  重置默认
                </button>
              </div>

              <div className="h-px bg-[var(--border-hairline)]" />

              <div className="flex flex-col gap-1">
                <div className="flex items-center justify-between text-[11.5px]">
                  <span className="font-medium text-[var(--text-secondary)]">透视距离</span>
                  <span className="text-[11px] font-semibold charkle-mono charkle-tabular text-[var(--text-primary)]">
                    {Math.round(params.perspective)}px
                  </span>
                </div>
                <CharkleSlider
                  min={900}
                  max={2400}
                  step={10}
                  value={params.perspective}
                  onChange={(v) => setParams((p) => ({ ...p, perspective: v }))}
                  ariaLabel="透视距离"
                  valueText={`${Math.round(params.perspective)}px`}
                  variant="glass"
                  size="sm"
                  className="w-full"
                  data-testid="ring-slider-perspective"
                />
              </div>

              <div className="flex flex-col gap-1">
                <div className="flex items-center justify-between text-[11.5px]">
                  <span className="font-medium text-[var(--text-secondary)]">景深模糊</span>
                  <span className="text-[11px] font-semibold charkle-mono charkle-tabular text-[var(--text-primary)]">
                    {Math.round(params.depthBlur)}px
                  </span>
                </div>
                <CharkleSlider
                  min={0}
                  max={30}
                  step={1}
                  value={params.depthBlur}
                  onChange={(v) => setParams((p) => ({ ...p, depthBlur: v }))}
                  ariaLabel="景深模糊"
                  valueText={`${Math.round(params.depthBlur)}px`}
                  variant="glass"
                  size="sm"
                  className="w-full"
                  data-testid="ring-slider-depth-blur"
                />
              </div>

              <div className="flex flex-col gap-1">
                <div className="flex items-center justify-between text-[11.5px]">
                  <span className="font-medium text-[var(--text-secondary)]">远端淡出</span>
                  <span className="text-[11px] font-semibold charkle-mono charkle-tabular text-[var(--text-primary)]">
                    {Math.round(params.farFade * 100)}%
                  </span>
                </div>
                <CharkleSlider
                  min={0}
                  max={100}
                  step={1}
                  value={Math.round(params.farFade * 100)}
                  onChange={(v) => setParams((p) => ({ ...p, farFade: v / 100 }))}
                  ariaLabel="远端淡出"
                  valueText={`${Math.round(params.farFade * 100)}%`}
                  variant="glass"
                  size="sm"
                  className="w-full"
                  data-testid="ring-slider-far-fade"
                />
              </div>

              <div className="flex flex-col gap-1">
                <div className="flex items-center justify-between text-[11.5px]">
                  <span className="font-medium text-[var(--text-secondary)]">卡片圆角</span>
                  <span className="text-[11px] font-semibold charkle-mono charkle-tabular text-[var(--text-primary)]">
                    {Math.round(params.cornerRadius)}px
                  </span>
                </div>
                <CharkleSlider
                  min={0}
                  max={60}
                  step={1}
                  value={params.cornerRadius}
                  onChange={(v) => setParams((p) => ({ ...p, cornerRadius: v }))}
                  ariaLabel="卡片圆角"
                  valueText={`${Math.round(params.cornerRadius)}px`}
                  variant="glass"
                  size="sm"
                  className="w-full"
                  data-testid="ring-slider-corner-radius"
                />
              </div>
            </div>
          )}

          <button
            type="button"
            data-testid="ring-tuning-toggle"
            data-pill="true"
            data-adapt-glass="true"
            aria-expanded={tuningOpen}
            aria-label="环形画廊参数"
            title="调整环形透视、景深模糊、远端淡出与圆角参数"
            onClick={() => setTuningOpen((v) => !v)}
            className={[
              'pointer-events-auto charkle-pressable charkle-glass rounded-full h-[34px] inline-flex items-center justify-center gap-1.5 cursor-pointer shrink-0',
              tuningOpen
                ? 'px-3 text-[var(--accent)]'
                : 'w-[34px] text-[var(--text-primary)]/85',
            ].join(' ')}
          >
            <SlidersHorizontal size={13} />
            {tuningOpen && <span className="text-[11.5px] font-medium">收起</span>}
          </button>
        </div>
      </div>

      {/* Right-Click Frosted Context Menu for Any Card in the Ring */}
      <Popover
        open={contextTarget !== null}
        onOpenChange={(open) => {
          if (!open) {
            setContextTarget(null);
            setMoveSubOpen(false);
            setBoardSubOpen(false);
          }
        }}
        anchorPoint={contextTarget?.point ?? null}
        className="w-[232px] p-1.5"
      >
        {contextTarget && (
          <div className="flex flex-col gap-0.5 text-[12.5px]">
            <button
              type="button"
              onClick={() => {
                const target = contextTarget.asset;
                setContextTarget(null);
                handleOpenAsset(target);
              }}
              className="w-full flex items-center justify-between gap-2 px-2.5 py-1.5 rounded-[var(--radius-popover-inner)] text-[var(--text-primary)] cursor-pointer"
            >
              <span className="inline-flex items-center gap-2">
                {isPlainWebBookmark(contextTarget.asset) ? (
                  <>
                    <ExternalLink size={14} className="text-[var(--text-secondary)]" />
                    在默认浏览器中打开
                  </>
                ) : (
                  <>
                    <Eye size={14} className="text-[var(--text-secondary)]" />
                    沉浸预览
                  </>
                )}
              </span>
              <kbd className="text-[10.5px] text-[var(--text-tertiary)]">Space</kbd>
            </button>

            <div className="my-1 h-px bg-[var(--border-hairline)]" />

            {contextTarget.asset.isTrashed || destination.type === 'trash' ? (
              <>
                <button
                  type="button"
                  onClick={() => {
                    const ids = [...contextTargetIds];
                    setContextTarget(null);
                    pruneSelectionIds(ids);
                    void updateAssets({ assetIDs: ids, isTrashed: false }, destination).then(() =>
                      pushToast({
                        message:
                          ids.length > 1 ? `已将 ${ids.length} 项放回原处` : '已放回原处',
                        tone: 'success',
                      }),
                    );
                  }}
                  className="w-full flex items-center gap-2 px-2.5 py-1.5 rounded-[var(--radius-popover-inner)] text-[var(--text-primary)] cursor-pointer"
                >
                  <RotateCcw size={14} className="text-[var(--text-secondary)]" />
                  放回原处{contextCountSuffix}
                </button>
                <button
                  type="button"
                  onClick={() => {
                    const ids = [...contextTargetIds];
                    setContextTarget(null);
                    setPermDeleteIds(ids);
                  }}
                  className="w-full flex items-center gap-2 px-2.5 py-1.5 rounded-[var(--radius-popover-inner)] text-[var(--danger)] hover:bg-[var(--danger-soft)] cursor-pointer"
                >
                  <Trash2 size={14} />
                  彻底删除…{contextCountSuffix}
                </button>
              </>
            ) : (
              <>
                <button
                  type="button"
                  onClick={() => {
                    setBoardSubOpen((v) => !v);
                    setMoveSubOpen(false);
                  }}
                  className="w-full flex items-center justify-between px-2.5 py-1.5 rounded-[var(--radius-popover-inner)] text-[var(--text-primary)] cursor-pointer"
                >
                  <span className="inline-flex items-center gap-2">
                    <LayoutGrid size={14} className="text-[var(--text-secondary)]" />
                    加入情绪板{contextCountSuffix}
                  </span>
                  <span className="text-[11px] text-[var(--text-tertiary)]">
                    {boardSubOpen ? '▾' : '▸'}
                  </span>
                </button>

                {boardSubOpen && (
                  <div className="pl-2 pr-1 py-1 border-l border-[var(--border-hairline)] ml-2 flex flex-col gap-0.5 max-h-[180px] overflow-y-auto charkle-scroll">
                    {boards.map((board) => (
                      <button
                        key={board.id}
                        type="button"
                        onClick={() => {
                          const ids = [...contextTargetIds];
                          setContextTarget(null);
                          void addAssetsToBoard(board.id, ids).then(() =>
                            pushToast({
                              message:
                                ids.length > 1
                                  ? `已将 ${ids.length} 项加入情绪板「${board.title}」`
                                  : `已加入情绪板「${board.title}」`,
                              tone: 'success',
                            }),
                          );
                        }}
                        className="w-full text-left px-2 py-1 rounded-[var(--radius-card-inner)] text-[12px] text-[var(--text-primary)] truncate cursor-pointer"
                      >
                        {board.title}
                      </button>
                    ))}
                    <button
                      type="button"
                      onClick={() => {
                        const ids = [...contextTargetIds];
                        setContextTarget(null);
                        if (ids.length > 0) setSelection(ids, ids[0]);
                        setMoodboardGeneratorOpen(true);
                      }}
                      className="w-full flex items-center gap-1.5 px-2 py-1 rounded-[var(--radius-card-inner)] text-[12px] font-medium text-[var(--accent)] cursor-pointer"
                    >
                      <Sparkles size={12} />
                      用此素材创建新情绪板…
                    </button>
                  </div>
                )}

                <button
                  type="button"
                  onClick={() => {
                    setMoveSubOpen((v) => !v);
                    setBoardSubOpen(false);
                  }}
                  className="w-full flex items-center justify-between px-2.5 py-1.5 rounded-[var(--radius-popover-inner)] text-[var(--text-primary)] cursor-pointer"
                >
                  <span className="inline-flex items-center gap-2">
                    <FolderInput size={14} className="text-[var(--text-secondary)]" />
                    移动到文件夹{contextCountSuffix}
                  </span>
                  <span className="text-[11px] text-[var(--text-tertiary)]">
                    {moveSubOpen ? '▾' : '▸'}
                  </span>
                </button>

                {moveSubOpen && (
                  <div className="pl-2 pr-1 py-1 border-l border-[var(--border-hairline)] ml-2">
                    <FolderMoveMenu
                      folders={folders}
                      currentFolderId={
                        contextTargetIds.length === 1
                          ? (contextTarget.asset.folderID ?? null)
                          : undefined
                      }
                      onSelectFolder={(folderId) => {
                        const ids = [...contextTargetIds];
                        setContextTarget(null);
                        const assignment = folderId ? { folder: folderId } : 'inbox';
                        const targetName = folderId
                          ? folders.find((f) => f.id === folderId)?.name ?? '文件夹'
                          : '收件箱';
                        void updateAssets(
                          { assetIDs: ids, folderAssignment: assignment },
                          destination,
                        ).then(() =>
                          pushToast({
                            message:
                              ids.length > 1
                                ? `已移动 ${ids.length} 项至「${targetName}」`
                                : `已移动至「${targetName}」`,
                            tone: 'success',
                          }),
                        );
                      }}
                    />
                  </div>
                )}

                <div className="my-1 h-px bg-[var(--border-hairline)]" />

                <button
                  type="button"
                  onClick={() => {
                    const ids = [...contextTargetIds];
                    setContextTarget(null);
                    void transport.copyAssetsToClipboard(ids).then((n) =>
                      pushToast({ message: `已拷贝 ${n} 项素材到剪贴板`, tone: 'success' }),
                    );
                  }}
                  className="w-full flex items-center gap-2 px-2.5 py-1.5 rounded-[var(--radius-popover-inner)] text-[var(--text-primary)] cursor-pointer"
                >
                  <Copy size={14} className="text-[var(--text-secondary)]" />
                  拷贝素材{contextCountSuffix}
                </button>

                <button
                  type="button"
                  onClick={() => {
                    const id = contextTarget.asset.id;
                    setContextTarget(null);
                    void transport.revealInExplorer(id);
                  }}
                  className="w-full flex items-center gap-2 px-2.5 py-1.5 rounded-[var(--radius-popover-inner)] text-[var(--text-primary)] cursor-pointer"
                >
                  <FolderOpen size={14} className="text-[var(--text-secondary)]" />
                  在资源管理器中显示
                </button>

                <button
                  type="button"
                  onClick={() => {
                    const ids = [...contextTargetIds];
                    const nextPinned = !contextTarget.asset.pinnedOffline;
                    setContextTarget(null);
                    void updateAssets(
                      { assetIDs: ids, pinnedOffline: nextPinned },
                      destination,
                    ).then(() =>
                      pushToast({
                        message: nextPinned
                          ? ids.length > 1
                            ? `已将 ${ids.length} 项设为始终保留在本地`
                            : '已始终保留在本地'
                          : ids.length > 1
                            ? `已取消 ${ids.length} 项的始终保留`
                            : '已取消始终保留在本地',
                        tone: 'info',
                      }),
                    );
                  }}
                  className="w-full flex items-center gap-2 px-2.5 py-1.5 rounded-[var(--radius-popover-inner)] text-[var(--text-primary)] cursor-pointer"
                >
                  {contextTarget.asset.pinnedOffline ? (
                    <Cloud size={14} className="text-[var(--text-secondary)]" />
                  ) : (
                    <ArrowDownCircle size={14} className="text-[var(--text-secondary)]" />
                  )}
                  {contextTarget.asset.pinnedOffline
                    ? `取消始终保留在本地${contextCountSuffix}`
                    : `始终保留在本地${contextCountSuffix}`}
                </button>

                <div className="my-1 h-px bg-[var(--border-hairline)]" />

                <button
                  type="button"
                  onClick={() => {
                    const ids = [...contextTargetIds];
                    setContextTarget(null);
                    pruneSelectionIds(ids);
                    void updateAssets({ assetIDs: ids, isTrashed: true }, destination, {
                      undoMessage:
                        ids.length > 1 ? `已移至回收站 (${ids.length} 项)` : '已移至回收站',
                      undoPatch: { assetIDs: ids, isTrashed: false },
                    });
                  }}
                  className="w-full flex items-center gap-2 px-2.5 py-1.5 rounded-[var(--radius-popover-inner)] text-[var(--danger)] cursor-pointer"
                >
                  <Trash2 size={14} />
                  移至回收站{contextCountSuffix}
                </button>
              </>
            )}
          </div>
        )}
      </Popover>

      <ModalShell
        open={permDeleteIds !== null}
        onClose={() => setPermDeleteIds(null)}
        title={`彻底删除 ${permDeleteIds?.length ?? 0} 项素材？`}
        width="sm"
        footer={
          <>
            <Button variant="secondary" onClick={() => setPermDeleteIds(null)}>
              取消
            </Button>
            <Button
              variant="danger"
              onClick={async () => {
                const ids = permDeleteIds ?? [];
                setPermDeleteIds(null);
                if (ids.length > 0) {
                  pruneSelectionIds(ids);
                  await permanentlyDeleteAssets(ids, destination);
                }
              }}
            >
              彻底删除
            </Button>
          </>
        }
      >
        <p className="text-[13px] text-[var(--text-secondary)] leading-relaxed charkle-prose">
          彻底删除后将无法从回收站恢复。
        </p>
      </ModalShell>
    </div>
  );
};
