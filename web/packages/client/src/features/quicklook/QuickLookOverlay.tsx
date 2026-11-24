import React, { useCallback, useEffect, useLayoutEffect, useMemo, useRef, useState } from 'react';
import { createPortal } from 'react-dom';
import {
  ChevronLeft,
  ChevronRight,
  Download,
  FlipHorizontal2,
  FlipVertical2,
  LayoutGrid,
  Maximize2,
  PanelRight,
  Pin,
  RotateCcw,
  RotateCw,
  ScrollText,
  Star,
  Trash2,
  Undo2,
  X,
  ZoomIn,
  ZoomOut,
} from 'lucide-react';
import { createDefaultAssetBatchPatch, getAssetDisplayTypeLabel } from '@charkle/shared';
import type { AssetRecord, UUID } from '@charkle/shared';
import { apiClient } from '../../api/client';
import { stopAllHoverPreviews } from '../../components/HoverMediaPreview';
import {
  computeAmbientTintStyle,
  ConfirmDialog,
  Popover,
  prefersReducedMotion,
  useResolvedIsDark,
} from '../../design-system';
import { useCoordinatorStore } from '../../stores/coordinatorStore';
import type { SourceRect } from '../../stores/coordinatorStore';
import { useLibraryStore } from '../../stores/libraryStore';
import { useMoodboardStore } from '../../stores/moodboardStore';
import { isEditableElement } from '../capture/captureUtils';
import { getCardEffectiveAspectRatio } from '../gallery/assetCardUtils';
import { InspectorView } from '../inspector/InspectorView';
import { AudioStudioViewer } from './AudioStudioViewer';
import { DocumentMarkdownViewer } from './DocumentMarkdownViewer';
import { GitHubRepoViewer } from './GitHubRepoViewer';
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
} from './MediaStageHelpers';
import { SocialPostViewer } from './SocialPostViewer';

const HERO_ENTER_MS = 260;
const HERO_EXIT_MS = 180;
const REDUCED_FADE_MS = 150;

function findLiveCardRect(assetID: UUID): SourceRect | null {
  if (typeof document === 'undefined') return null;
  const safeId =
    typeof CSS !== 'undefined' && typeof CSS.escape === 'function'
      ? CSS.escape(assetID)
      : assetID.replace(/"/g, '\\"');
  const el =
    document.querySelector<HTMLElement>(`[data-asset-card-id="${safeId}"]`) ??
    document.querySelector<HTMLElement>(`[data-filmstrip-id="${safeId}"]`);
  if (!el) return null;
  const r = el.getBoundingClientRect();
  if (r.width <= 0 || r.height <= 0 || r.bottom <= 0 || r.top >= window.innerHeight) {
    return null;
  }
  return { left: r.left, top: r.top, width: r.width, height: r.height };
}

function computeHeroDelta(
  source: SourceRect,
  stageRect: DOMRect,
  asset: AssetRecord,
  isVisual: boolean,
): { dx: number; dy: number; scale: number } {
  let fitW = Math.min(760, stageRect.width);
  let fitH = Math.min(580, stageRect.height);

  if (isVisual && stageRect.width > 0 && stageRect.height > 0) {
    const aspect = Math.max(0.25, Math.min(4, getCardEffectiveAspectRatio(asset)));
    if (stageRect.width / stageRect.height >= aspect) {
      fitH = stageRect.height;
      fitW = fitH * aspect;
    } else {
      fitW = stageRect.width;
      fitH = fitW / aspect;
    }
  }

  const dx = source.left + source.width * 0.5 - (stageRect.left + stageRect.width * 0.5);
  const dy = source.top + source.height * 0.5 - (stageRect.top + stageRect.height * 0.5);
  const sx = source.width / Math.max(80, fitW);
  const sy = source.height / Math.max(80, fitH);
  const scale = Math.max(0.18, Math.min(1.4, (sx + sy) * 0.5));
  return { dx, dy, scale };
}

export const QuickLookOverlay: React.FC = () => {
  const quickLookAssetID = useCoordinatorStore((s) => s.quickLookAssetID);
  const quickLookSourceRect = useCoordinatorStore((s) => s.quickLookSourceRect);
  const closeQuickLook = useCoordinatorStore((s) => s.closeQuickLook);
  const openQuickLook = useCoordinatorStore((s) => s.openQuickLook);
  const setQuickLookHiddenAssetID = useCoordinatorStore((s) => s.setQuickLookHiddenAssetID);
  const inspectorOpen = useCoordinatorStore((s) => s.inspectorOpen);
  const toggleInspector = useCoordinatorStore((s) => s.toggleInspector);
  const pushToast = useCoordinatorStore((s) => s.pushToast);

  const assets = useLibraryStore((s) => s.assets);
  const assetsByID = useLibraryStore((s) => s.assetsByID);
  const cacheBust = useLibraryStore((s) => s.cacheBustVersion);
  const markOpened = useLibraryStore((s) => s.markOpened);
  const selectAsset = useLibraryStore((s) => s.selectAsset);
  const batchPatch = useLibraryStore((s) => s.batchPatch);
  const restoreAssets = useLibraryStore((s) => s.restoreAssets);
  const permanentlyDeleteAssets = useLibraryStore((s) => s.permanentlyDeleteAssets);

  const boards = useMoodboardStore((s) => s.boards);
  const addAssetsToBoard = useMoodboardStore((s) => s.addAssetsToBoard);

  const isDark = useResolvedIsDark();

  // Mounted-exit presence state for continuous hero open/close choreography
  const [renderedAssetID, setRenderedAssetID] = useState<UUID | null>(null);
  const [overlayPhase, setOverlayPhase] = useState<'entering' | 'open' | 'closing'>('closing');
  const [chromeVisible, setChromeVisible] = useState(false);

  const [zoom, setZoom] = useState(1);
  const [pan, setPan] = useState({ x: 0, y: 0 });
  const [rotation, setRotation] = useState(0);
  const [flipH, setFlipH] = useState(false);
  const [flipV, setFlipV] = useState(false);
  const [draggingPan, setDraggingPan] = useState(false);
  const [stageSize, setStageSize] = useState({ width: 0, height: 0 });
  const [naturalSize, setNaturalSize] = useState<{ width: number; height: number } | null>(null);
  const [originalLoadedID, setOriginalLoadedID] = useState<UUID | null>(null);
  const [originalFailedID, setOriginalFailedID] = useState<UUID | null>(null);
  const [isLongStripScrollMode, setIsLongStripScrollMode] = useState(false);
  const [boardMenuOpen, setBoardMenuOpen] = useState(false);
  const [confirmPermanentDelete, setConfirmPermanentDelete] = useState(false);

  const boardBtnRef = useRef<HTMLButtonElement | null>(null);
  const panOriginRef = useRef({ x: 0, y: 0, panX: 0, panY: 0 });
  const stageRef = useRef<HTMLDivElement | null>(null);
  const heroFrameRef = useRef<HTMLDivElement | null>(null);
  const filmstripRef = useRef<HTMLDivElement | null>(null);
  const longStripUserOverrideRef = useRef(false);
  const exitTimerRef = useRef<number | null>(null);
  const hudTimerRef = useRef<number | null>(null);
  const heroHideTimerRef = useRef<number | null>(null);
  const activeHeroAnimRef = useRef<Animation | null>(null);
  const lastAssetSnapshotRef = useRef<AssetRecord | null>(null);
  const initialOpenSourceRef = useRef<{ assetID: UUID; rect: SourceRect } | null>(null);
  const prevOpenIDRef = useRef<UUID | null>(null);

  const activeID = quickLookAssetID ?? renderedAssetID;

  const currentIndex = useMemo(() => {
    if (!activeID) return -1;
    return assets.findIndex((a) => a.id === activeID);
  }, [assets, activeID]);

  const resolvedAsset: AssetRecord | null = useMemo(() => {
    if (!activeID) return null;
    if (currentIndex >= 0) return assets[currentIndex];
    return assetsByID[activeID] ?? null;
  }, [activeID, currentIndex, assets, assetsByID]);

  if (resolvedAsset) {
    lastAssetSnapshotRef.current = resolvedAsset;
  }
  const asset = resolvedAsset ?? (renderedAssetID ? lastAssetSnapshotRef.current : null);

  const isVisualImage = asset ? supportsVisualTransform(asset) : false;
  const effWidth = naturalSize?.width || asset?.pixelWidth || 0;
  const effHeight = naturalSize?.height || asset?.pixelHeight || 0;

  const isTallStripImage = Boolean(
    asset &&
      !asset.richMetadata?.githubRepo &&
      !asset.richMetadata?.socialPost &&
      (asset.mediaKind === 'image' || asset.mediaKind === 'designFile') &&
      isTallStripDimensions(effWidth, effHeight),
  );

  const maxZoomLimit = useMemo(
    () => computeDynamicMaxZoom(effWidth, effHeight),
    [effWidth, effHeight],
  );

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

  // Manage mounted lifecycle & hero open/close choreography
  useEffect(() => {
    const clearPendingTimers = () => {
      if (exitTimerRef.current !== null) {
        window.clearTimeout(exitTimerRef.current);
        exitTimerRef.current = null;
      }
      if (hudTimerRef.current !== null) {
        window.clearTimeout(hudTimerRef.current);
        hudTimerRef.current = null;
      }
      if (heroHideTimerRef.current !== null) {
        window.clearTimeout(heroHideTimerRef.current);
        heroHideTimerRef.current = null;
      }
    };

    if (quickLookAssetID) {
      clearPendingTimers();
      const wasClosed = prevOpenIDRef.current === null;
      prevOpenIDRef.current = quickLookAssetID;

      if (quickLookSourceRect) {
        initialOpenSourceRef.current = { assetID: quickLookAssetID, rect: quickLookSourceRect };
      }

      stopAllHoverPreviews();
      resetTransforms();
      setNaturalSize(null);
      setOriginalLoadedID(null);
      setOriginalFailedID(null);
      setBoardMenuOpen(false);
      longStripUserOverrideRef.current = false;

      const currentAsset =
        useLibraryStore.getState().assetsByID[quickLookAssetID] ??
        useLibraryStore.getState().assets.find((a) => a.id === quickLookAssetID) ??
        null;
      const defaultTallStrip = Boolean(
        currentAsset &&
          !currentAsset.richMetadata?.githubRepo &&
          !currentAsset.richMetadata?.socialPost &&
          (currentAsset.mediaKind === 'image' || currentAsset.mediaKind === 'designFile') &&
          isTallStripDimensions(currentAsset.pixelWidth, currentAsset.pixelHeight),
      );
      setIsLongStripScrollMode(defaultTallStrip);
      void markOpened(quickLookAssetID);

      setRenderedAssetID(quickLookAssetID);

      if (wasClosed) {
        setOverlayPhase('entering');
        setChromeVisible(false);
        const raf = requestAnimationFrame(() => {
          setOverlayPhase('open');
        });
        hudTimerRef.current = window.setTimeout(() => {
          setChromeVisible(true);
        }, 40);
        return () => cancelAnimationFrame(raf);
      } else {
        setOverlayPhase('open');
        setChromeVisible(true);
      }
      return undefined;
    }

    // Closing transition: keep mounted until smooth hero collapse completes
    if (prevOpenIDRef.current !== null) {
      clearPendingTimers();
      const closingID = prevOpenIDRef.current;
      prevOpenIDRef.current = null;
      setBoardMenuOpen(false);
      setChromeVisible(false);
      setOverlayPhase('closing');

      const reduced = prefersReducedMotion();
      const exitDuration = reduced ? REDUCED_FADE_MS : HERO_EXIT_MS;
      const heroEl = heroFrameRef.current;
      const stageEl = stageRef.current;
      const closingAsset = lastAssetSnapshotRef.current;

      if (activeHeroAnimRef.current) {
        activeHeroAnimRef.current.cancel();
        activeHeroAnimRef.current = null;
      }

      const liveTargetRect =
        findLiveCardRect(closingID) ??
        (initialOpenSourceRef.current?.assetID === closingID
          ? initialOpenSourceRef.current.rect
          : null);

      if (liveTargetRect && !reduced) {
        setQuickLookHiddenAssetID(closingID);
      }

      if (heroEl && stageEl && closingAsset) {
        if (reduced) {
          activeHeroAnimRef.current = heroEl.animate(
            [{ opacity: 1 }, { opacity: 0 }],
            { duration: REDUCED_FADE_MS, easing: 'cubic-bezier(0.23, 1, 0.32, 1)', fill: 'forwards' },
          );
        } else if (liveTargetRect) {
          const { dx, dy, scale } = computeHeroDelta(
            liveTargetRect,
            stageEl.getBoundingClientRect(),
            closingAsset,
            supportsVisualTransform(closingAsset),
          );
          activeHeroAnimRef.current = heroEl.animate(
            [
              { transform: 'translate3d(0, 0, 0) scale(1)', opacity: 1 },
              {
                transform: `translate3d(${dx.toFixed(1)}px, ${dy.toFixed(1)}px, 0) scale(${scale.toFixed(4)})`,
                opacity: 0,
              },
            ],
            {
              duration: HERO_EXIT_MS,
              easing: 'cubic-bezier(0.23, 1, 0.32, 1)',
              fill: 'forwards',
            },
          );
        } else {
          activeHeroAnimRef.current = heroEl.animate(
            [
              { transform: 'scale(1)', opacity: 1 },
              { transform: 'scale(0.95)', opacity: 0 },
            ],
            {
              duration: HERO_EXIT_MS,
              easing: 'cubic-bezier(0.23, 1, 0.32, 1)',
              fill: 'forwards',
            },
          );
        }
      }

      exitTimerRef.current = window.setTimeout(() => {
        exitTimerRef.current = null;
        if (activeHeroAnimRef.current) {
          activeHeroAnimRef.current.cancel();
          activeHeroAnimRef.current = null;
        }
        setQuickLookHiddenAssetID(null);
        setRenderedAssetID(null);
        initialOpenSourceRef.current = null;
      }, exitDuration + 10);
    }

    return undefined;
  }, [
    quickLookAssetID,
    quickLookSourceRect,
    markOpened,
    resetTransforms,
    setQuickLookHiddenAssetID,
  ]);

  // Run GPU Hero Expansion animation on first open frame
  useLayoutEffect(() => {
    if (overlayPhase !== 'entering' || !renderedAssetID || !asset) return;
    const heroEl = heroFrameRef.current;
    const stageEl = stageRef.current;
    if (!heroEl || !stageEl) return;

    if (activeHeroAnimRef.current) {
      activeHeroAnimRef.current.cancel();
      activeHeroAnimRef.current = null;
    }

    const reduced = prefersReducedMotion();
    if (reduced) {
      activeHeroAnimRef.current = heroEl.animate(
        [{ opacity: 0 }, { opacity: 1 }],
        { duration: REDUCED_FADE_MS, easing: 'cubic-bezier(0.23, 1, 0.32, 1)', fill: 'none' },
      );
      return;
    }

    const sourceRect = quickLookSourceRect ?? findLiveCardRect(renderedAssetID);
    if (sourceRect) {
      setQuickLookHiddenAssetID(renderedAssetID);
      const { dx, dy, scale } = computeHeroDelta(
        sourceRect,
        stageEl.getBoundingClientRect(),
        asset,
        supportsVisualTransform(asset),
      );
      activeHeroAnimRef.current = heroEl.animate(
        [
          {
            transform: `translate3d(${dx.toFixed(1)}px, ${dy.toFixed(1)}px, 0) scale(${scale.toFixed(4)})`,
            opacity: 0.72,
          },
          { transform: 'translate3d(0, 0, 0) scale(1)', opacity: 1 },
        ],
        {
          duration: HERO_ENTER_MS,
          easing: 'cubic-bezier(0.23, 1, 0.32, 1)',
          fill: 'none',
        },
      );
      heroHideTimerRef.current = window.setTimeout(() => {
        setQuickLookHiddenAssetID(null);
      }, HERO_ENTER_MS);
    } else {
      activeHeroAnimRef.current = heroEl.animate(
        [
          { transform: 'scale(0.95)', opacity: 0 },
          { transform: 'scale(1)', opacity: 1 },
        ],
        {
          duration: HERO_ENTER_MS,
          easing: 'cubic-bezier(0.23, 1, 0.32, 1)',
          fill: 'none',
        },
      );
    }
  }, [overlayPhase, renderedAssetID, asset, quickLookSourceRect, setQuickLookHiddenAssetID]);

  // Clean up hidden card flag on unmount
  useEffect(() => {
    return () => {
      setQuickLookHiddenAssetID(null);
    };
  }, [setQuickLookHiddenAssetID]);

  // Auto-scroll active bottom filmstrip thumbnail into view
  useEffect(() => {
    if (!quickLookAssetID) return;
    const strip = filmstripRef.current;
    if (!strip) return;
    const safeId =
      typeof CSS !== 'undefined' && typeof CSS.escape === 'function'
        ? CSS.escape(quickLookAssetID)
        : quickLookAssetID.replace(/"/g, '\\"');
    const thumb = strip.querySelector<HTMLElement>(`[data-ql-thumb-id="${safeId}"]`);
    thumb?.scrollIntoView({
      behavior: prefersReducedMotion() ? 'auto' : 'smooth',
      inline: 'center',
      block: 'nearest',
    });
  }, [quickLookAssetID]);

  // If natural dimensions arrive after load and reveal a tall strip, enable long-strip unless user toggled
  useEffect(() => {
    if (isTallStripImage && !longStripUserOverrideRef.current) {
      setIsLongStripScrollMode(true);
    }
  }, [isTallStripImage]);

  // Measure live stage dimensions for exact quarter-turn fit scaling
  useEffect(() => {
    if (!renderedAssetID) return;
    const el = stageRef.current;
    if (!el || typeof ResizeObserver === 'undefined') return;
    const update = () => {
      setStageSize({ width: el.clientWidth, height: el.clientHeight });
    };
    update();
    const ro = new ResizeObserver(update);
    ro.observe(el);
    return () => ro.disconnect();
  }, [renderedAssetID, inspectorOpen, isLongStripScrollMode]);

  // Smooth exponential wheel zoom on the visual stage
  useEffect(() => {
    if (!quickLookAssetID || !isVisualImage || isLongStripScrollMode) return;
    const el = stageRef.current;
    if (!el) return;

    const onWheel = (e: WheelEvent) => {
      if (e.deltaY === 0) return;
      e.preventDefault();
      const factor = computeWheelZoomFactor(e);
      setZoom((z) => {
        const next = Math.max(0.5, Math.min(maxZoomLimit, Number((z * factor).toFixed(3))));
        if (next <= 1.01) setPan({ x: 0, y: 0 });
        return next;
      });
    };

    el.addEventListener('wheel', onWheel, { passive: false });
    return () => el.removeEventListener('wheel', onWheel);
  }, [quickLookAssetID, isVisualImage, isLongStripScrollMode, maxZoomLimit]);

  // Vertical mouse wheel -> horizontal scroll on Quick Look bottom filmstrip
  useHorizontalWheelRedirect(filmstripRef, Boolean(quickLookAssetID) && assets.length > 1);

  // Keyboard shortcuts (Space/Esc, ⌘I/⌘⌥I, Arrows, R/⇧R, ⇧H/⇧V, +/=/-, 0)
  useEffect(() => {
    if (!quickLookAssetID) return;
    const onKeyDown = (e: KeyboardEvent) => {
      if (confirmPermanentDelete) return;
      const mod = e.metaKey || e.ctrlKey;
      const keyLower = e.key.toLowerCase();
      const isUnmodified = !e.metaKey && !e.ctrlKey && !e.altKey && !e.shiftKey;

      if (mod && keyLower === 'i' && !e.shiftKey) {
        e.preventDefault();
        e.stopPropagation();
        toggleInspector();
        return;
      }

      if (isEditableElement(e.target)) {
        if (e.key === 'Escape') {
          e.preventDefault();
          e.stopPropagation();
          (e.target as HTMLElement).blur();
        }
        return;
      }

      if (e.key === 'Escape') {
        e.preventDefault();
        e.stopPropagation();
        closeQuickLook();
        return;
      }

      if (isUnmodified && (e.code === 'Space' || e.key === ' ')) {
        if (e.repeat) {
          e.preventDefault();
          e.stopPropagation();
          return;
        }
        e.preventDefault();
        e.stopPropagation();
        closeQuickLook();
        return;
      }

      if (isUnmodified && e.key === 'ArrowRight') {
        e.preventDefault();
        e.stopPropagation();
        stepTo(1);
        return;
      }
      if (isUnmodified && e.key === 'ArrowLeft') {
        e.preventDefault();
        e.stopPropagation();
        stepTo(-1);
        return;
      }

      if (!isVisualImage || e.metaKey || e.ctrlKey || e.altKey) return;

      if (keyLower === 'r') {
        e.preventDefault();
        rotateByScreenDelta(e.shiftKey ? -90 : 90);
      } else if (keyLower === 'h' && e.shiftKey) {
        e.preventDefault();
        setFlipH((v) => !v);
      } else if (keyLower === 'v' && e.shiftKey) {
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
    confirmPermanentDelete,
    isVisualImage,
    closeQuickLook,
    toggleInspector,
    stepTo,
    rotateByScreenDelta,
    applyZoomMultiplier,
    resetTransforms,
  ]);

  if (!renderedAssetID || !asset || typeof document === 'undefined') return null;

  const viewerKind = classifyAssetViewerKind(asset);
  const displayRotation = ((rotation % 360) + 360) % 360;
  const hasAnyTransformOrZoom =
    Math.abs(zoom - 1) > 0.01 ||
    Math.abs(pan.x) > 0.5 ||
    Math.abs(pan.y) > 0.5 ||
    displayRotation !== 0 ||
    flipH ||
    flipV;

  const quarterFitScale =
    isVisualImage && !isLongStripScrollMode
      ? computeQuarterTurnFitScale(stageSize, asset, rotation, naturalSize)
      : 1;

  const primaryHex = asset.dominantColors[0]?.hex;
  const ambientStyle = computeAmbientTintStyle(primaryHex, isDark, 'quicklook');

  const previewPlaceholderSrc = apiClient.thumbnailURL(
    asset.id,
    'preview1400',
    `${asset.updatedAt}-${cacheBust}`,
  );
  const useOriginalURL = originalFailedID !== asset.id;
  const activeVisualSrc = useOriginalURL ? apiClient.originalMediaURL(asset.id) : previewPlaceholderSrc;
  const isOriginalReady = !useOriginalURL || originalLoadedID === asset.id;

  const handleToggleLongStrip = () => {
    longStripUserOverrideRef.current = true;
    setIsLongStripScrollMode((prev) => {
      const next = !prev;
      if (next) resetTransforms();
      return next;
    });
  };

  const isClosing = overlayPhase === 'closing';

  return createPortal(
    <div
      data-quicklook-overlay="true"
      data-state={overlayPhase}
      className={[
        'fixed inset-0 z-[150] flex',
        isClosing ? 'pointer-events-none' : '',
      ].join(' ')}
    >
      {/* Calm Neutral Scrim Backdrop (zero full-screen blur, respects prefers-reduced-transparency) */}
      <div
        aria-hidden="true"
        data-state={overlayPhase}
        className="charkle-quicklook-scrim fixed inset-0 pointer-events-none"
      />

      {/* Left Main Media Stage Column */}
      <div
        className="relative z-10 flex-1 min-w-0 h-full flex flex-col overflow-hidden select-none"
        onClick={(e) => {
          if (e.target === e.currentTarget) closeQuickLook();
        }}
      >
        {/* Ambient Color Tint Layer */}
        <div
          aria-hidden="true"
          className="pointer-events-none absolute inset-0 transition-opacity duration-[200ms] ease-[var(--ease-out)]"
          style={{ ...ambientStyle, opacity: overlayPhase === 'open' ? 1 : 0 }}
        />

        {/* Top Floating Translucent HUD (40ms stagger) */}
        <div
          className="relative z-20 flex items-center justify-between gap-3 px-5 pt-4 pb-2 transition-opacity duration-[var(--duration-sm)] ease-[var(--ease-out)]"
          style={{ opacity: chromeVisible && !isClosing ? 1 : 0 }}
        >
          <div className="charkle-glass-dark px-3.5 py-1.5 rounded-full flex items-center gap-2.5 max-w-[44vw]">
            <span className="text-[13px] font-medium text-white truncate">{asset.title}</span>
            <span className="text-[11.5px] text-white/60 shrink-0 tabular-nums">
              {getAssetDisplayTypeLabel(asset)}
              {effWidth > 0 && ` · ${effWidth}×${effHeight}`}
            </span>
            {!asset.isTrashed && (
              <div className="hidden md:flex items-center gap-0.5 pl-1 border-l border-white/14 shrink-0">
                {[1, 2, 3, 4, 5].map((star) => {
                  const filled = asset.rating >= star;
                  return (
                    <button
                      key={star}
                      type="button"
                      aria-label={`评分 ${star} 星`}
                      onClick={() => {
                        const nextRating = asset.rating === star ? 0 : star;
                        void batchPatch(
                          createDefaultAssetBatchPatch([asset.id], { rating: nextRating }),
                        );
                      }}
                      className="charkle-pressable p-0.5 cursor-pointer"
                    >
                      <Star
                        size={12}
                        className={
                          filled
                            ? 'fill-[#F2C14E] text-[#F2C14E]'
                            : 'text-white/35 hover:text-white/75'
                        }
                      />
                    </button>
                  );
                })}
              </div>
            )}
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
                  onClick={() => {
                    setIsLongStripScrollMode(false);
                    longStripUserOverrideRef.current = true;
                    resetTransforms();
                  }}
                  className="charkle-pressable text-[11px] font-mono text-white/80 hover:text-white w-12 h-7.5 rounded-full hover:bg-white/10 text-center tabular-nums cursor-pointer"
                >
                  {isLongStripScrollMode ? '长图' : `${Math.round(zoom * 100)}%`}
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
                  title="逆时针旋转 90° (⇧R)"
                  onClick={() => rotateByScreenDelta(-90)}
                  className="charkle-pressable h-7.5 w-7.5 rounded-full hover:bg-white/12 text-white/85 flex items-center justify-center cursor-pointer"
                >
                  <RotateCcw size={14} />
                </button>
                <button
                  type="button"
                  title="顺时针旋转 90° (R)"
                  onClick={() => rotateByScreenDelta(90)}
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
                {hasAnyTransformOrZoom && (
                  <button
                    type="button"
                    title="重置全部变换 (0)"
                    onClick={resetTransforms}
                    className="charkle-pressable h-7 px-2 rounded-full bg-white/16 hover:bg-white/24 text-white text-[11px] font-medium inline-flex items-center gap-1 cursor-pointer"
                  >
                    <Undo2 size={11.5} />
                    {displayRotation !== 0 ? `${displayRotation}°` : '重置'}
                  </button>
                )}
                <div className="w-px h-4 bg-white/15 mx-1" />
              </>
            )}

            {asset.isTrashed ? (
              <>
                <button
                  type="button"
                  title="恢复素材"
                  onClick={() => {
                    void restoreAssets([asset.id]);
                    closeQuickLook();
                  }}
                  className="charkle-pressable h-7.5 px-2.5 rounded-full hover:bg-white/12 text-white/90 text-[12px] inline-flex items-center gap-1 cursor-pointer"
                >
                  <RotateCcw size={13} />
                  恢复
                </button>
                <button
                  type="button"
                  title="彻底删除"
                  onClick={() => setConfirmPermanentDelete(true)}
                  className="charkle-pressable h-7.5 px-2.5 rounded-full hover:bg-red-500/30 text-[#F87171] text-[12px] inline-flex items-center gap-1 cursor-pointer"
                >
                  <Trash2 size={13} />
                  彻底删除
                </button>
                <div className="w-px h-4 bg-white/15 mx-1" />
              </>
            ) : (
              <>
                <button
                  type="button"
                  title={asset.pinnedOffline ? '取消离线保留' : '保留离线副本'}
                  aria-pressed={asset.pinnedOffline}
                  onClick={() => {
                    const nextPinned = !asset.pinnedOffline;
                    void batchPatch(
                      createDefaultAssetBatchPatch([asset.id], { pinnedOffline: nextPinned }),
                    );
                    pushToast({
                      tone: 'info',
                      message: nextPinned ? '已保留离线副本' : '已取消离线保留',
                    });
                  }}
                  className={[
                    'charkle-pressable h-7.5 w-7.5 rounded-full flex items-center justify-center cursor-pointer',
                    asset.pinnedOffline
                      ? 'bg-[var(--accent)] text-white'
                      : 'hover:bg-white/12 text-white/85',
                  ].join(' ')}
                >
                  <Pin size={13.5} />
                </button>

                <button
                  ref={boardBtnRef}
                  type="button"
                  title="加入情绪板"
                  onClick={() => setBoardMenuOpen((v) => !v)}
                  className="charkle-pressable h-7.5 w-7.5 rounded-full hover:bg-white/12 text-white/85 flex items-center justify-center cursor-pointer"
                >
                  <LayoutGrid size={13.5} />
                </button>
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
              title="切换右侧检查器 (⌘I / ⌘⌥I)"
              aria-pressed={inspectorOpen}
              onClick={toggleInspector}
              className={[
                'charkle-pressable h-7.5 w-7.5 rounded-full flex items-center justify-center cursor-pointer',
                inspectorOpen ? 'bg-white/22 text-white' : 'hover:bg-white/12 text-white/85',
              ].join(' ')}
            >
              <PanelRight size={14} />
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

        {/* Main Media Stage */}
        <div className="relative z-10 flex-1 min-h-0 flex items-center justify-center px-14 py-3 overflow-hidden">
          {/* Left/Right Navigation Chevrons */}
          {currentIndex > 0 && (
            <button
              type="button"
              onClick={() => stepTo(-1)}
              aria-label="上一项"
              style={{ opacity: chromeVisible && !isClosing ? 1 : 0 }}
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
              style={{ opacity: chromeVisible && !isClosing ? 1 : 0 }}
              className="charkle-pressable charkle-glass-dark absolute right-4 top-1/2 -translate-y-1/2 z-20 h-10 w-10 rounded-full flex items-center justify-center text-white cursor-pointer transition-opacity duration-[var(--duration-sm)] ease-[var(--ease-out)]"
            >
              <ChevronRight size={20} />
            </button>
          )}

          {/* Hero-Animated Media Stage Container */}
          <div
            ref={stageRef}
            className="flex-1 min-w-0 h-full flex items-center justify-center overflow-hidden"
            onClick={(e) => {
              if (e.target === e.currentTarget) closeQuickLook();
            }}
          >
            <div
              ref={heroFrameRef}
              className="w-full h-full flex items-center justify-center"
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
                    <Delayed3DStagePlaceholder className="w-[min(960px,92vw)] h-[min(640px,76vh)]" />
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
                  poster={previewPlaceholderSrc}
                  controls
                  autoPlay
                  playsInline
                  className="max-w-full max-h-full rounded-[var(--radius-card-outer)] shadow-2xl"
                />
              ) : viewerKind === 'webBookmark' ? (
                <WebBookmarkViewer asset={asset} cacheBust={cacheBust} />
              ) : isLongStripScrollMode ? (
                <div
                  data-long-strip-mode="true"
                  className="w-full h-full overflow-y-auto overscroll-contain charkle-scroll flex justify-center py-4 px-2"
                  onClick={(e) => {
                    if (e.target === e.currentTarget) closeQuickLook();
                  }}
                >
                  <div className="relative w-full max-w-[min(100%,1100px)] h-fit">
                    {!isOriginalReady && (
                      <img
                        src={previewPlaceholderSrc}
                        alt=""
                        aria-hidden="true"
                        className="w-full h-auto rounded-[var(--radius-card-outer)] shadow-2xl block"
                      />
                    )}
                    <img
                      key={`strip-${asset.id}-${useOriginalURL ? 'orig' : 'thumb'}`}
                      src={activeVisualSrc}
                      alt={asset.title}
                      draggable={false}
                      onLoad={(e) => {
                        const img = e.currentTarget;
                        if (img.naturalWidth > 0 && img.naturalHeight > 0) {
                          setNaturalSize({ width: img.naturalWidth, height: img.naturalHeight });
                        }
                        setOriginalLoadedID(asset.id);
                      }}
                      onError={() => {
                        if (useOriginalURL) setOriginalFailedID(asset.id);
                      }}
                      style={{
                        transform:
                          flipH || flipV
                            ? `scaleX(${flipH ? -1 : 1}) scaleY(${flipV ? -1 : 1})`
                            : undefined,
                      }}
                      className={[
                        'w-full h-auto rounded-[var(--radius-card-outer)] shadow-2xl block',
                        isOriginalReady ? 'relative opacity-100' : 'absolute inset-0 opacity-0',
                      ].join(' ')}
                    />
                  </div>
                </div>
              ) : (
                <div className="relative w-full h-full flex items-center justify-center">
                  {!isOriginalReady && (
                    <img
                      src={previewPlaceholderSrc}
                      alt=""
                      aria-hidden="true"
                      className="max-w-full max-h-full object-contain rounded-[var(--radius-card-outer)] shadow-2xl pointer-events-none"
                    />
                  )}
                  <img
                    key={`fit-${asset.id}-${useOriginalURL ? 'orig' : 'thumb'}`}
                    src={activeVisualSrc}
                    alt={asset.title}
                    draggable={false}
                    onLoad={(e) => {
                      const img = e.currentTarget;
                      if (img.naturalWidth > 0 && img.naturalHeight > 0) {
                        setNaturalSize({ width: img.naturalWidth, height: img.naturalHeight });
                      }
                      setOriginalLoadedID(asset.id);
                    }}
                    onError={() => {
                      if (useOriginalURL) setOriginalFailedID(asset.id);
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
                      transform: `translate3d(${pan.x}px, ${pan.y}px, 0) scale(${zoom * quarterFitScale}) scaleX(${flipH ? -1 : 1}) scaleY(${flipV ? -1 : 1}) rotate(${rotation}deg)`,
                      transition: draggingPan
                        ? 'none'
                        : 'transform var(--duration-settle) var(--ease-out-strong)',
                      cursor: zoom > 1.01 ? (draggingPan ? 'grabbing' : 'grab') : 'zoom-in',
                    }}
                    className={[
                      'max-w-full max-h-full object-contain rounded-[var(--radius-card-outer)] shadow-2xl',
                      isOriginalReady ? 'opacity-100' : 'absolute opacity-0 pointer-events-none',
                    ].join(' ')}
                  />
                </div>
              )}
            </div>
          </div>
        </div>

        {/* Bottom Floating HUD: Long-Strip Mode Toggle + Filmstrip */}
        {(isTallStripImage || assets.length > 1) && (
          <div
            className="relative z-20 pb-4 px-6 flex flex-col items-center gap-2 transition-opacity duration-[var(--duration-sm)] ease-[var(--ease-out)]"
            style={{ opacity: chromeVisible && !isClosing ? 1 : 0 }}
          >
            {isTallStripImage && (
              <div className="charkle-glass-dark p-1 rounded-full flex items-center gap-1">
                <button
                  type="button"
                  onClick={handleToggleLongStrip}
                  className="charkle-pressable h-7 px-3 rounded-full bg-white/14 hover:bg-white/22 text-white text-[12px] font-medium inline-flex items-center gap-1.5 cursor-pointer"
                >
                  {isLongStripScrollMode ? (
                    <>
                      <Maximize2 size={12.5} />
                      适配全屏
                    </>
                  ) : (
                    <>
                      <ScrollText size={12.5} />
                      长图滚动
                    </>
                  )}
                </button>
              </div>
            )}

            {assets.length > 1 && (
              <div
                ref={filmstripRef}
                className="charkle-glass-dark max-w-[min(780px,92%)] px-2.5 py-2 rounded-[var(--radius-dock-outer)] flex items-center gap-1.5 overflow-x-auto charkle-scroll"
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
                        data-ql-thumb-id={item.id}
                        data-active={active ? 'true' : 'false'}
                        onClick={() => {
                          selectAsset(item.id, 'replace');
                          openQuickLook(item.id);
                        }}
                        style={{ width: Math.round(44 * ratio), height: 44 }}
                        className={[
                          'charkle-filmstrip-thumb shrink-0 overflow-hidden rounded-[8px] cursor-pointer',
                          active ? 'ring-2 ring-white opacity-100 z-10' : 'opacity-50 hover:opacity-85',
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
            )}
          </div>
        )}
      </div>

      {/* Unified Full-Height 300px Inspector Panel (1:1 synced with workspace) */}
      <div
        className={[
          'relative z-10 flex transition-opacity duration-[180ms] ease-[var(--ease-out)]',
          isClosing ? 'opacity-0' : 'opacity-100',
        ].join(' ')}
      >
        <InspectorView
          pinnedAsset={asset}
          isQuickLookHosted
          onRequestCloseQuickLook={closeQuickLook}
        />
      </div>

      {/* Add-to-Moodboard Popover */}
      <Popover
        open={boardMenuOpen && !isClosing}
        onOpenChange={setBoardMenuOpen}
        anchorEl={boardBtnRef.current}
        placement="bottom-end"
      >
        <div className="w-[210px] max-h-[260px] overflow-y-auto charkle-scroll p-1.5 flex flex-col gap-0.5 text-[12.5px]">
          {boards.length === 0 ? (
            <div className="px-2.5 py-2 text-[12px] text-[var(--text-tertiary)]">暂无情绪板</div>
          ) : (
            boards.map((board) => (
              <button
                key={board.id}
                type="button"
                onClick={async () => {
                  setBoardMenuOpen(false);
                  await addAssetsToBoard(board.id, [asset.id]);
                  pushToast({ tone: 'success', message: `已加入「${board.title}」` });
                }}
                className="charkle-pressable w-full px-2.5 py-1.5 rounded-[var(--radius-popover-inner)] text-left truncate text-[var(--text-primary)] hover:bg-[var(--bg-subtle)] cursor-pointer"
              >
                {board.title}
              </button>
            ))
          )}
        </div>
      </Popover>

      {/* Confirmed Permanent Delete Dialog */}
      <ConfirmDialog
        open={confirmPermanentDelete}
        onClose={() => setConfirmPermanentDelete(false)}
        title={`彻底删除「${asset.title}」？`}
        description="删除后将永久移除文件且无法恢复。"
        confirmLabel="彻底删除"
        onConfirm={async () => {
          await permanentlyDeleteAssets([asset.id]);
          closeQuickLook();
          pushToast({ tone: 'info', message: '已彻底删除素材' });
        }}
      />
    </div>,
    document.body,
  );
};
