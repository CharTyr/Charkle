import React, { useCallback, useEffect, useMemo, useRef, useState } from 'react';
import {
  ArrowClockwise16Regular,
  ArrowCounterclockwise16Regular,
  ArrowDownload16Regular,
  ArrowUndo16Regular,
  Board16Regular,
  ChevronLeft20Regular,
  ChevronRight16Regular,
  ChevronRight20Regular,
  Cloud16Regular,
  Copy16Regular,
  Delete16Regular,
  Eye16Regular,
  FlipHorizontal16Regular,
  FlipVertical16Regular,
  FolderArrowRight16Regular,
  FolderOpen16Regular,
  Open16Regular,
  Star16Filled,
  Star16Regular,
  ZoomIn16Regular,
  ZoomOut16Regular,
} from '@fluentui/react-icons';
import { getTransport } from '../../api/transport';
import {
  Button,
  CharkleIcon,
  ModalShell,
  Popover,
  computeAmbientTintStyle,
  isLightHex,
  useResolvedIsDark,
} from '../../design-system';
import {
  useCoordinatorStore,
  useLibraryStore,
  useMoodboardStore,
} from '../../stores';
import type { AssetRecord } from '../../types/domain';
import { beginPointerDrag, wasRecentPointerDrag } from '../dnd/PointerDragContext';
import { AudioStudioViewer } from '../quicklook/AudioStudioViewer';
import { DocumentMarkdownViewer } from '../quicklook/DocumentMarkdownViewer';
import { GitHubRepoViewer } from '../quicklook/GitHubRepoViewer';
import { Model3DViewer } from '../quicklook/Model3DViewer';
import { PdfDocumentViewer } from '../quicklook/PdfDocumentViewer';
import { SocialPostViewer } from '../quicklook/SocialPostViewer';
import { FolderMoveMenu } from '../sidebar/FolderMoveMenu';

export interface GalleryFilmstripViewProps {
  assets: AssetRecord[];
  topInset?: number;
}

/**
 * Gallery Filmstrip View with 1:1 macOS `GalleryFilmstripView.swift` parity:
 * - Full rich multi-format preview stage (Images, GIF, Video, Audio, PDF, 3D, Markdown, GitHub, Social Posts, Swatches, Bookmarks)
 * - Direct wheel zoom, drag-to-pan when zoomed, double-click 100% <-> 200%, ±90° rotate (quarter-turn fit), H/V flip
 * - Floating `.win-acrylic` preview controls bar + metadata & interactive 1–5 star strip
 * - Proportional bottom filmstrip thumbnails with vertical-wheel-to-horizontal scroll & full right-click context menu
 */
const FilmstripThumbVisual: React.FC<{ item: AssetRecord; src: string }> = ({ item, src }) => {
  const [failed, setFailed] = useState(false);

  if (item.fileName.toLowerCase().endsWith('.swatch')) {
    const hex = item.dominantColors[0]?.hex ?? '#4E7D96';
    const light = isLightHex(hex);
    return (
      <div
        className="w-full h-full flex items-end justify-center p-1"
        style={{ backgroundColor: hex }}
      >
        <span
          className={[
            'text-[8.5px] font-mono font-semibold leading-none tracking-tight',
            light ? 'text-black/75' : 'text-white/90',
          ].join(' ')}
        >
          {hex.toUpperCase()}
        </span>
      </div>
    );
  }

  if (failed) {
    const platform = item.richMetadata?.socialPost?.platform;
    const isXhs = platform === 'xiaohongshu';
    const isDouyin = platform === 'douyin';
    const bg = isXhs ? '#FF2442' : isDouyin ? '#161823' : (item.dominantColors[0]?.hex ?? '#2B2F36');
    const light = isXhs || isDouyin ? false : isLightHex(bg);
    return (
      <div
        className="w-full h-full flex items-center justify-center px-1 text-center"
        style={{ backgroundColor: bg }}
      >
        <span
          className={[
            'text-[9px] font-medium line-clamp-2 leading-tight',
            light ? 'text-black/80' : 'text-white/90',
          ].join(' ')}
        >
          {isXhs ? '小红书' : isDouyin ? '抖音' : item.title}
        </span>
      </div>
    );
  }

  return (
    <img
      src={src}
      alt={item.title}
      loading="lazy"
      draggable={false}
      onError={() => setFailed(true)}
      className="w-full h-full object-cover"
    />
  );
};

function isPlainWebBookmarkAsset(item: AssetRecord): boolean {
  return (
    item.mediaKind === 'webBookmark' &&
    !item.richMetadata?.githubRepo &&
    !item.richMetadata?.socialPost
  );
}

function cacheBustedUrl(url: string, updatedAt: string | number | null | undefined): string {
  if (!updatedAt || url.startsWith('data:') || url.startsWith('blob:')) return url;
  const sep = url.includes('?') ? '&' : '?';
  return `${url}${sep}v=${encodeURIComponent(String(updatedAt))}`;
}

function webBookmarkDomain(item: AssetRecord): string {
  if (item.sourceDomain) return item.sourceDomain;
  if (item.sourceURL) {
    try {
      return new URL(item.sourceURL).host.replace(/^www\./i, '');
    } catch {
      return '网页书签';
    }
  }
  return '网页书签';
}

export const GalleryFilmstripView: React.FC<GalleryFilmstripViewProps> = ({
  assets,
  topInset = 68,
}) => {
  const destination = useCoordinatorStore((s) => s.destination);
  const selectedAssetIds = useCoordinatorStore((s) => s.selectedAssetIds);
  const selectAsset = useCoordinatorStore((s) => s.selectAsset);
  const setSelection = useCoordinatorStore((s) => s.setSelection);
  const clearSelection = useCoordinatorStore((s) => s.clearSelection);
  const openQuickLook = useCoordinatorStore((s) => s.openQuickLook);
  const activeMoodboardId = useCoordinatorStore((s) => s.activeMoodboardId);
  const setMoodboardGeneratorOpen = useCoordinatorStore((s) => s.setMoodboardGeneratorOpen);
  const pushToast = useCoordinatorStore((s) => s.pushToast);

  const folders = useLibraryStore((s) => s.folders);
  const thumbnailRevisions = useLibraryStore((s) => s.thumbnailRevisions);
  const updateAssets = useLibraryStore((s) => s.updateAssets);
  const permanentlyDeleteAssets = useLibraryStore((s) => s.permanentlyDeleteAssets);
  const markAssetOpened = useLibraryStore((s) => s.markAssetOpened);

  const boards = useMoodboardStore((s) => s.boards);
  const addAssetsToBoard = useMoodboardStore((s) => s.addAssetsToBoard);

  const isDark = useResolvedIsDark();

  const stripRef = useRef<HTMLDivElement | null>(null);
  const stageRef = useRef<HTMLDivElement | null>(null);
  const panDragRef = useRef<{ startX: number; startY: number; baseX: number; baseY: number } | null>(
    null,
  );

  const [zoomScale, setZoomScale] = useState(1);
  const [panOffset, setPanOffset] = useState({ x: 0, y: 0 });
  const [isPanning, setIsPanning] = useState(false);
  const [rotationDegrees, setRotationDegrees] = useState(0);
  const [flipHorizontal, setFlipHorizontal] = useState(false);
  const [flipVertical, setFlipVertical] = useState(false);
  const [fallbackThumb, setFallbackThumb] = useState(false);
  const [stageSize, setStageSize] = useState({ width: 900, height: 520 });

  const [contextTarget, setContextTarget] = useState<{
    asset: AssetRecord;
    point: { x: number; y: number };
    targetIds: string[];
  } | null>(null);
  const [moveSubOpen, setMoveSubOpen] = useState(false);
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

  const orderedIds = useMemo(() => assets.map((a) => a.id), [assets]);
  const selectedSet = useMemo(() => new Set(selectedAssetIds), [selectedAssetIds]);

  const activeIndex = useMemo(() => {
    const cur = selectedAssetIds[0];
    if (!cur) return 0;
    const idx = assets.findIndex((a) => a.id === cur);
    return idx >= 0 ? idx : 0;
  }, [assets, selectedAssetIds]);

  const activeAsset = assets[activeIndex] ?? null;

  const supportsVisualTransform = useMemo(() => {
    if (!activeAsset) return false;
    return (
      !activeAsset.richMetadata?.githubRepo &&
      !activeAsset.richMetadata?.socialPost &&
      (activeAsset.mediaKind === 'image' ||
        activeAsset.mediaKind === 'designFile' ||
        activeAsset.mediaKind === 'animatedImage')
    );
  }, [activeAsset]);

  const maxZoomLimit = useMemo(() => {
    if (!activeAsset) return 6;
    const longest = Math.max(activeAsset.pixelWidth, activeAsset.pixelHeight);
    return Math.max(6, Math.min(16, longest / 550));
  }, [activeAsset]);

  const displayRotationDegrees = useMemo(() => {
    const raw = Math.round(rotationDegrees) % 360;
    return raw < 0 ? raw + 360 : raw;
  }, [rotationDegrees]);

  const hasActiveVisualTransform =
    displayRotationDegrees !== 0 || flipHorizontal || flipVertical;
  const hasAnyTransformOrZoom =
    hasActiveVisualTransform ||
    Math.abs(zoomScale - 1) > 0.01 ||
    panOffset.x !== 0 ||
    panOffset.y !== 0;

  // Keeps ±90° rotated landscape/portrait media cleanly fitted inside the preview stage
  const quarterTurnFitScale = useMemo(() => {
    if (
      !activeAsset ||
      (displayRotationDegrees !== 90 && displayRotationDegrees !== 270)
    ) {
      return 1;
    }
    const availW = Math.max(120, stageSize.width - 88);
    const availH = Math.max(120, stageSize.height - 20);
    const naturalRatio =
      activeAsset.pixelWidth > 0 && activeAsset.pixelHeight > 0
        ? Math.max(0.2, activeAsset.pixelWidth / activeAsset.pixelHeight)
        : 1.25;
    let fittedW: number;
    let fittedH: number;
    if (availW / availH > naturalRatio) {
      fittedH = availH;
      fittedW = fittedH * naturalRatio;
    } else {
      fittedW = availW;
      fittedH = fittedW / naturalRatio;
    }
    const scale = Math.min(availW / Math.max(1, fittedH), availH / Math.max(1, fittedW));
    return Math.max(0.25, Math.min(1, scale));
  }, [activeAsset, displayRotationDegrees, stageSize.height, stageSize.width]);

  const resetViewTransform = useCallback(() => {
    setZoomScale(1);
    setPanOffset({ x: 0, y: 0 });
    setRotationDegrees(0);
    setFlipHorizontal(false);
    setFlipVertical(false);
  }, []);

  const stepZoom = useCallback(
    (factor: number) => {
      if (!supportsVisualTransform) return;
      setZoomScale((prev) => {
        const next = Math.max(0.5, Math.min(maxZoomLimit, Number((prev * factor).toFixed(3))));
        if (next <= 1.01) {
          setPanOffset({ x: 0, y: 0 });
        }
        return next;
      });
    },
    [maxZoomLimit, supportsVisualTransform],
  );

  const rotatePreview = useCallback(
    (screenDelta: number) => {
      if (!supportsVisualTransform) return;
      const parity = flipHorizontal !== flipVertical ? -1 : 1;
      setRotationDegrees((prev) => prev + screenDelta * parity);
    },
    [flipHorizontal, flipVertical, supportsVisualTransform],
  );

  useEffect(() => {
    if (!activeAsset) return;
    if (selectedAssetIds.length === 0) {
      selectAsset(activeAsset.id, orderedIds);
    }
  }, [activeAsset, selectedAssetIds.length, orderedIds, selectAsset]);

  // Reset transform & mark opened whenever active asset switches
  useEffect(() => {
    if (!activeAsset) return;
    resetViewTransform();
    setFallbackThumb(false);
    void markAssetOpened(activeAsset.id);
  }, [activeAsset?.id, markAssetOpened, resetViewTransform]);

  // Recover from a previously failed thumbnail after refreshAssetThumbnail bumps updatedAt
  useEffect(() => {
    setFallbackThumb(false);
  }, [activeAsset?.id, activeAsset?.updatedAt]);

  // Measure preview stage size for quarter-turn fit
  useEffect(() => {
    const el = stageRef.current;
    if (!el) return;
    const measure = () => {
      const w = el.clientWidth;
      const h = el.clientHeight;
      if (w > 80 && h > 80) {
        setStageSize((prev) =>
          Math.abs(prev.width - w) >= 2 || Math.abs(prev.height - h) >= 2
            ? { width: w, height: h }
            : prev,
        );
      }
    };
    measure();
    if (typeof ResizeObserver === 'undefined') return;
    const obs = new ResizeObserver(measure);
    obs.observe(el);
    return () => obs.disconnect();
  }, []);

  // Center active thumbnail in bottom filmstrip
  useEffect(() => {
    const strip = stripRef.current;
    if (!strip || !activeAsset) return;
    const activeEl = strip.querySelector<HTMLElement>(
      `[data-strip-id="${CSS.escape(activeAsset.id)}"]`,
    );
    activeEl?.scrollIntoView?.({ behavior: 'smooth', inline: 'center', block: 'nearest' });
  }, [activeAsset]);

  // Non-passive wheel zoom on visual stage
  useEffect(() => {
    const el = stageRef.current;
    if (!el || !supportsVisualTransform) return;
    const onWheel = (e: WheelEvent) => {
      if (Math.abs(e.deltaY) < 1) return;
      e.preventDefault();
      const factor = e.deltaY < 0 ? 1.14 : 0.88;
      stepZoom(factor);
    };
    el.addEventListener('wheel', onWheel, { passive: false });
    return () => el.removeEventListener('wheel', onWheel);
  }, [supportsVisualTransform, stepZoom]);

  // Normal vertical scroll wheel scrolls bottom filmstrip horizontally (no Shift required)
  useEffect(() => {
    const strip = stripRef.current;
    if (!strip) return;
    const onWheel = (e: WheelEvent) => {
      if (Math.abs(e.deltaY) > Math.abs(e.deltaX) && Math.abs(e.deltaY) > 0) {
        e.preventDefault();
        strip.scrollLeft += e.deltaY;
      }
    };
    strip.addEventListener('wheel', onWheel, { passive: false });
    return () => strip.removeEventListener('wheel', onWheel);
  }, []);

  // Keyboard navigation & transform shortcuts matching macOS GalleryFilmstripView.swift
  useEffect(() => {
    const onKeyDown = (e: KeyboardEvent) => {
      const target = e.target as HTMLElement | null;
      if (
        target?.tagName === 'INPUT' ||
        target?.tagName === 'TEXTAREA' ||
        target?.isContentEditable
      ) {
        return;
      }
      const coord = useCoordinatorStore.getState();
      if (
        coord.quickLookAssetId ||
        coord.jumpOpen ||
        coord.captureOpen ||
        coord.settingsOpen ||
        coord.onboardingOpen ||
        coord.moodboardGeneratorOpen
      ) {
        return;
      }
      if (e.ctrlKey || e.metaKey || e.altKey) return;

      const isUnmodified = !e.shiftKey;
      const isShiftOnly = e.shiftKey;
      const key = e.key.toLowerCase();

      if (isUnmodified && e.key === 'ArrowLeft' && activeIndex > 0) {
        e.preventDefault();
        selectAsset(assets[activeIndex - 1].id, orderedIds);
        return;
      }
      if (isUnmodified && e.key === 'ArrowRight' && activeIndex < assets.length - 1) {
        e.preventDefault();
        selectAsset(assets[activeIndex + 1].id, orderedIds);
        return;
      }
      if (!supportsVisualTransform) return;

      if (isUnmodified && key === 'r') {
        e.preventDefault();
        rotatePreview(90);
      } else if (isShiftOnly && key === 'r') {
        e.preventDefault();
        rotatePreview(-90);
      } else if (isShiftOnly && key === 'h') {
        e.preventDefault();
        setFlipHorizontal((v) => !v);
      } else if (isShiftOnly && key === 'v') {
        e.preventDefault();
        setFlipVertical((v) => !v);
      } else if (isUnmodified && key === '0') {
        e.preventDefault();
        resetViewTransform();
      } else if (e.key === '+' || e.key === '=') {
        e.preventDefault();
        stepZoom(1.25);
      } else if (isUnmodified && e.key === '-') {
        e.preventDefault();
        stepZoom(0.8);
      }
    };
    window.addEventListener('keydown', onKeyDown);
    return () => window.removeEventListener('keydown', onKeyDown);
  }, [
    activeIndex,
    assets,
    orderedIds,
    resetViewTransform,
    rotatePreview,
    selectAsset,
    stepZoom,
    supportsVisualTransform,
  ]);

  if (!activeAsset) return null;

  const transport = getTransport();
  const prevAsset = activeIndex > 0 ? assets[activeIndex - 1] : null;
  const nextAsset = activeIndex < assets.length - 1 ? assets[activeIndex + 1] : null;
  const ambientStyle = computeAmbientTintStyle(
    activeAsset.dominantColors[0]?.hex,
    isDark,
    'quicklook',
  );

  const openExternalBookmark = (item: AssetRecord) => {
    if (!item.sourceURL) return;
    const domain = webBookmarkDomain(item);
    void transport
      .openExternalUrl(item.sourceURL)
      .then(() => {
        pushToast({
          message: `已在默认浏览器中打开 ${domain}`,
          tone: 'info',
        });
      })
      .catch((err) => {
        pushToast({
          message: err instanceof Error ? err.message : '无法打开网页链接',
          tone: 'error',
        });
      });
    void transport.markAssetOpened(item.id);
  };

  const launchQuickLook = (target: AssetRecord = activeAsset) => {
    if (wasRecentPointerDrag()) return;
    if (isPlainWebBookmarkAsset(target) && target.sourceURL) {
      openExternalBookmark(target);
      return;
    }
    const rect = stageRef.current?.getBoundingClientRect();
    openQuickLook(
      target.id,
      rect
        ? { left: rect.left, top: rect.top, width: rect.width, height: rect.height }
        : null,
    );
  };

  const stageAssetHex = activeAsset.dominantColors[0]?.hex || undefined;
  const stageAssetColors =
    activeAsset.dominantColors
      .slice(0, 3)
      .map((c) => c.hex)
      .join(',') || undefined;

  const renderStageMedia = () => {
    if (activeAsset.richMetadata?.githubRepo) {
      return (
        <div className="w-full h-full flex items-center justify-center overflow-hidden py-1">
          <GitHubRepoViewer asset={activeAsset} />
        </div>
      );
    }
    if (activeAsset.richMetadata?.socialPost) {
      return (
        <div className="w-full h-full flex items-center justify-center overflow-hidden py-1">
          <SocialPostViewer asset={activeAsset} />
        </div>
      );
    }

    switch (activeAsset.mediaKind) {
      case 'video': {
        const posterRev = thumbnailRevisions[activeAsset.id] ?? 0;
        const posterVer =
          posterRev > 0 ? `${String(activeAsset.updatedAt ?? 0)}-${posterRev}` : activeAsset.updatedAt;
        return (
          <video
            key={activeAsset.id}
            src={transport.originalUrl(activeAsset.id)}
            poster={cacheBustedUrl(
              transport.thumbnailUrl(activeAsset.id, 'preview1400'),
              posterVer,
            )}
            controls
            autoPlay
            playsInline
            data-asset-hex={stageAssetHex}
            data-asset-colors={stageAssetColors}
            className="max-w-full max-h-full rounded-[var(--radius-settings-outer)] shadow-[0_14px_38px_rgba(0,0,0,0.22)] bg-black"
          />
        );
      }
      case 'audio':
        return <AudioStudioViewer asset={activeAsset} />;
      case 'model3D':
        return <Model3DViewer asset={activeAsset} />;
      case 'document': {
        const lowerName = activeAsset.fileName.toLowerCase();
        if (lowerName.endsWith('.pdf')) {
          return <PdfDocumentViewer asset={activeAsset} />;
        }
        if (lowerName.endsWith('.swatch')) {
          const hex = (activeAsset.dominantColors[0]?.hex ?? '#5C6B73').toUpperCase();
          const light = isLightHex(hex);
          return (
            <div
              data-asset-hex={hex}
              className="w-[340px] h-[340px] rounded-[18px] shadow-[0_16px_40px_rgba(0,0,0,0.18)] flex flex-col justify-end p-6"
              style={{ backgroundColor: hex }}
            >
              <div
                className="text-[22px] font-semibold charkle-mono"
                style={{ color: light ? 'rgba(0,0,0,0.84)' : 'rgba(255,255,255,0.92)' }}
              >
                {hex}
              </div>
              {activeAsset.title.toUpperCase() !== hex && (
                <div
                  className="text-[13px] font-medium mt-1"
                  style={{ color: light ? 'rgba(0,0,0,0.62)' : 'rgba(255,255,255,0.74)' }}
                >
                  {activeAsset.title}
                </div>
              )}
            </div>
          );
        }
        return <DocumentMarkdownViewer asset={activeAsset} />;
      }
      case 'webBookmark': {
        const accentHex = activeAsset.dominantColors[0]?.hex ?? '#5C6B73';
        const domain = webBookmarkDomain(activeAsset);
        const webThumbRev = thumbnailRevisions[activeAsset.id] ?? 0;
        const webThumbVer =
          webThumbRev > 0
            ? `${String(activeAsset.updatedAt ?? 0)}-${webThumbRev}`
            : activeAsset.updatedAt;
        if (!fallbackThumb) {
          return (
            <div className="w-full h-full flex flex-col items-center justify-center gap-3 py-1">
              <div
                onDoubleClick={() => openExternalBookmark(activeAsset)}
                title={activeAsset.sourceURL ? '双击在默认浏览器中打开' : activeAsset.title}
                className="relative flex-1 min-h-0 max-w-full flex items-center justify-center cursor-pointer"
              >
                <img
                  key={`${activeAsset.id}:${webThumbVer}`}
                  src={cacheBustedUrl(
                    transport.thumbnailUrl(activeAsset.id, 'preview1400'),
                    webThumbVer,
                  )}
                  alt={activeAsset.title}
                  draggable={false}
                  onError={() => setFallbackThumb(true)}
                  data-asset-hex={stageAssetHex}
                  data-asset-colors={stageAssetColors}
                  className="max-w-full max-h-full object-contain rounded-[var(--radius-card-outer)] shadow-[0_14px_38px_rgba(0,0,0,0.16)]"
                />
              </div>
              {activeAsset.sourceURL && (
                <button
                  type="button"
                  onClick={() => openExternalBookmark(activeAsset)}
                  className="charkle-pressable win-acrylic shrink-0 max-w-[min(560px,90%)] rounded-[var(--win-radius-overlay)] px-3.5 py-1.5 inline-flex items-center gap-2 text-[12px] text-[var(--text-primary)] cursor-pointer"
                >
                  <span
                    className="h-2 w-2 rounded-full shrink-0"
                    style={{ backgroundColor: accentHex }}
                  />
                  <span className="font-semibold charkle-mono truncate">{domain}</span>
                  <span className="h-3 w-px bg-[var(--win-stroke-divider)] shrink-0" />
                  <span className="inline-flex items-center gap-1 font-medium text-[var(--accent)] shrink-0">
                    <Open16Regular className="w-3.5 h-3.5" />
                    在默认浏览器中打开
                  </span>
                </button>
              )}
            </div>
          );
        }
        return (
          <div
            onDoubleClick={() => openExternalBookmark(activeAsset)}
            className="w-full max-w-[600px] p-6 rounded-[var(--win-radius-dialog)] bg-[var(--bg-elevated)] border border-[var(--win-stroke-card)] shadow-[0_14px_36px_rgba(0,0,0,0.14)] flex flex-col gap-3.5 select-text"
          >
            <div className="flex items-center justify-between gap-3">
              <div className="flex items-center gap-2 min-w-0">
                <span
                  className="h-2.5 w-2.5 rounded-full shrink-0"
                  style={{ backgroundColor: accentHex }}
                />
                <span className="text-[12.5px] font-semibold charkle-mono text-[var(--text-secondary)] truncate">
                  {domain}
                </span>
              </div>
              {activeAsset.sourceURL && (
                <Button
                  variant="accent"
                  size="xs"
                  onClick={() => openExternalBookmark(activeAsset)}
                >
                  <Open16Regular className="w-3.5 h-3.5" />
                  在默认浏览器中打开
                </Button>
              )}
            </div>
            <h2 className="text-[19px] font-semibold text-[var(--text-primary)] charkle-heading">
              {activeAsset.title}
            </h2>
            {activeAsset.sourceURL && (
              <div className="text-[11.5px] charkle-mono text-[var(--text-secondary)] charkle-wrap-safe">
                {activeAsset.sourceURL}
              </div>
            )}
            {activeAsset.notes && (
              <>
                <div className="h-px bg-[var(--border-hairline)]" />
                <p className="text-[13px] text-[var(--text-secondary)] leading-relaxed whitespace-pre-wrap charkle-prose">
                  {activeAsset.notes}
                </p>
              </>
            )}
          </div>
        );
      }
      default: {
        const imgSrc = fallbackThumb
          ? transport.thumbnailUrl(activeAsset.id, 'preview1400')
          : transport.originalUrl(activeAsset.id);
        const totalScale = zoomScale * quarterTurnFitScale;
        return (
          <div
            onDoubleClick={(e) => {
              e.stopPropagation();
              if (zoomScale > 1.1) {
                setZoomScale(1);
                setPanOffset({ x: 0, y: 0 });
              } else {
                setZoomScale(2);
              }
            }}
            onPointerDown={(e) => {
              if (e.button !== 0) return;
              if (zoomScale > 1.01) {
                e.currentTarget.setPointerCapture?.(e.pointerId);
                setIsPanning(true);
                panDragRef.current = {
                  startX: e.clientX,
                  startY: e.clientY,
                  baseX: panOffset.x,
                  baseY: panOffset.y,
                };
              } else {
                const dragIds =
                  selectedSet.has(activeAsset.id) && selectedAssetIds.length > 1
                    ? [...selectedAssetIds]
                    : [activeAsset.id];
                beginPointerDrag(e, {
                  kind: 'assets',
                  assetIds: dragIds,
                  previewAssetId: activeAsset.id,
                  title: activeAsset.title,
                });
              }
            }}
            onPointerMove={(e) => {
              if (!panDragRef.current) return;
              setPanOffset({
                x: panDragRef.current.baseX + (e.clientX - panDragRef.current.startX),
                y: panDragRef.current.baseY + (e.clientY - panDragRef.current.startY),
              });
            }}
            onPointerUp={() => {
              panDragRef.current = null;
              setIsPanning(false);
            }}
            onPointerCancel={() => {
              panDragRef.current = null;
              setIsPanning(false);
            }}
            className={[
              'w-full h-full flex items-center justify-center',
              zoomScale > 1.01
                ? isPanning
                  ? 'cursor-grabbing'
                  : 'cursor-grab'
                : 'cursor-grab active:cursor-grabbing',
            ].join(' ')}
          >
            <img
              key={activeAsset.id}
              src={imgSrc}
              alt={activeAsset.title}
              draggable={false}
              onError={() => setFallbackThumb(true)}
              data-asset-hex={stageAssetHex}
              data-asset-colors={stageAssetColors}
              style={{
                transform: `translate3d(${panOffset.x}px, ${panOffset.y}px, 0) scale(${totalScale}) scaleX(${flipHorizontal ? -1 : 1}) scaleY(${flipVertical ? -1 : 1}) rotate(${rotationDegrees}deg)`,
                transition: isPanning
                  ? 'none'
                  : 'transform var(--duration-settle) var(--ease-out-strong)',
              }}
              className="max-w-full max-h-full object-contain rounded-[var(--radius-card-outer)] shadow-[0_14px_38px_rgba(0,0,0,0.16)]"
            />
          </div>
        );
      }
    }
  };

  const contextTargetIds = contextTarget?.targetIds ?? [];
  const contextCountSuffix =
    contextTargetIds.length > 1 ? ` (${contextTargetIds.length} 项)` : '';

  return (
    <div
      data-testid="gallery-filmstrip-view"
      className="flex-1 min-h-0 flex flex-col overflow-hidden bg-[var(--bg-gallery)]"
    >
      {/* Full-Height Interactive Preview Stage (artwork glides cleanly behind floating top glass pills to y = 0) */}
      <div
        style={ambientStyle}
        className="relative flex-1 min-h-0 flex flex-col overflow-hidden select-none"
      >
        <div
          ref={stageRef}
          data-asset-card-id={activeAsset.id}
          style={{ paddingTop: topInset + 8 }}
          onContextMenu={(e) => {
            e.preventDefault();
            const latestSel = useCoordinatorStore.getState().selectedAssetIds;
            const snapshotIds =
              latestSel.includes(activeAsset.id) && latestSel.length > 1
                ? [...latestSel]
                : [activeAsset.id];
            setMoveSubOpen(false);
            setContextTarget({
              asset: activeAsset,
              point: { x: e.clientX, y: e.clientY },
              targetIds: snapshotIds,
            });
          }}
          className="relative flex-1 min-h-0 flex items-center justify-center px-12 pb-1 overflow-visible"
        >
          {renderStageMedia()}
        </div>

        {/* Left / Right Fluent Acrylic Stepping Chevrons */}
        {assets.length > 1 && (
          <>
            <button
              type="button"
              aria-label="上一项"
              disabled={!prevAsset}
              onClick={() => prevAsset && selectAsset(prevAsset.id, orderedIds)}
              className="charkle-pressable win-acrylic absolute left-3.5 top-1/2 -translate-y-1/2 z-10 h-9 w-9 rounded-[var(--win-radius-overlay)] inline-flex items-center justify-center text-[var(--text-primary)] cursor-pointer disabled:opacity-25 disabled:cursor-default"
            >
              <ChevronLeft20Regular className="w-5 h-5" />
            </button>

            <button
              type="button"
              aria-label="下一项"
              disabled={!nextAsset}
              onClick={() => nextAsset && selectAsset(nextAsset.id, orderedIds)}
              className="charkle-pressable win-acrylic absolute right-3.5 top-1/2 -translate-y-1/2 z-10 h-9 w-9 rounded-[var(--win-radius-overlay)] inline-flex items-center justify-center text-[var(--text-primary)] cursor-pointer disabled:opacity-25 disabled:cursor-default"
            >
              <ChevronRight20Regular className="w-5 h-5" />
            </button>
          </>
        )}

        {/* Preview Controls Bar + Compact Metadata & Star Rating Strip */}
        <div className="relative z-20 shrink-0 flex flex-col items-center gap-1.5 px-4 pb-2.5 pt-1">
          {supportsVisualTransform && (
            <div className="win-acrylic rounded-[var(--win-radius-overlay)] px-2 py-1 flex items-center gap-1.5 text-[12px]">
              {/* Zoom controls */}
              <div className="flex items-center gap-0.5">
                <button
                  type="button"
                  title="缩小 (-)"
                  aria-label="缩小"
                  onClick={() => stepZoom(0.8)}
                  className="charkle-pressable h-7 w-7 rounded-[var(--win-radius-control)] inline-flex items-center justify-center text-[var(--text-primary)] hover:bg-[var(--win-subtle-hover)] cursor-pointer"
                >
                  <ZoomOut16Regular className="w-4 h-4" />
                </button>
                <button
                  type="button"
                  title="点击复位到 100% (0)"
                  onClick={resetViewTransform}
                  className="px-1.5 min-w-[42px] text-center text-[11.5px] font-semibold charkle-mono charkle-tabular text-[var(--text-primary)] cursor-pointer"
                >
                  {Math.round(zoomScale * 100)}%
                </button>
                <button
                  type="button"
                  title="放大 (+)"
                  aria-label="放大"
                  onClick={() => stepZoom(1.25)}
                  className="charkle-pressable h-7 w-7 rounded-[var(--win-radius-control)] inline-flex items-center justify-center text-[var(--text-primary)] hover:bg-[var(--win-subtle-hover)] cursor-pointer"
                >
                  <ZoomIn16Regular className="w-4 h-4" />
                </button>
              </div>

              <div className="h-4 w-px bg-[var(--win-stroke-divider)]" />

              {/* Rotate & Flip controls */}
              <div className="flex items-center gap-0.5">
                <button
                  type="button"
                  title="逆时针旋转 90° (Shift+R)"
                  aria-label="逆时针旋转 90°"
                  onClick={() => rotatePreview(-90)}
                  className="charkle-pressable h-7 w-7 rounded-[var(--win-radius-control)] inline-flex items-center justify-center text-[var(--text-primary)] hover:bg-[var(--win-subtle-hover)] cursor-pointer"
                >
                  <ArrowCounterclockwise16Regular className="w-4 h-4" />
                </button>
                <button
                  type="button"
                  title="顺时针旋转 90° (R)"
                  aria-label="顺时针旋转 90°"
                  onClick={() => rotatePreview(90)}
                  className="charkle-pressable h-7 w-7 rounded-[var(--win-radius-control)] inline-flex items-center justify-center text-[var(--text-primary)] hover:bg-[var(--win-subtle-hover)] cursor-pointer"
                >
                  <ArrowClockwise16Regular className="w-4 h-4" />
                </button>
                <button
                  type="button"
                  title="水平翻转 (Shift+H)"
                  aria-label="水平翻转"
                  aria-pressed={flipHorizontal}
                  onClick={() => setFlipHorizontal((v) => !v)}
                  className={[
                    'charkle-pressable h-7 w-7 rounded-[var(--win-radius-control)] inline-flex items-center justify-center cursor-pointer',
                    flipHorizontal
                      ? 'bg-[var(--accent)] text-[var(--accent-text)]'
                      : 'text-[var(--text-primary)] hover:bg-[var(--win-subtle-hover)]',
                  ].join(' ')}
                >
                  <FlipHorizontal16Regular className="w-4 h-4" />
                </button>
                <button
                  type="button"
                  title="上下翻转 (Shift+V)"
                  aria-label="上下翻转"
                  aria-pressed={flipVertical}
                  onClick={() => setFlipVertical((v) => !v)}
                  className={[
                    'charkle-pressable h-7 w-7 rounded-[var(--win-radius-control)] inline-flex items-center justify-center cursor-pointer',
                    flipVertical
                      ? 'bg-[var(--accent)] text-[var(--accent-text)]'
                      : 'text-[var(--text-primary)] hover:bg-[var(--win-subtle-hover)]',
                  ].join(' ')}
                >
                  <FlipVertical16Regular className="w-4 h-4" />
                </button>

                {hasAnyTransformOrZoom && (
                  <button
                    type="button"
                    title="还原全部视图变换 (0)"
                    onClick={resetViewTransform}
                    className="charkle-pressable ml-0.5 h-6 px-2 rounded-[var(--win-radius-control)] bg-[var(--accent)] text-[var(--accent-text)] inline-flex items-center gap-1 text-[11px] font-semibold charkle-mono cursor-pointer"
                  >
                    {displayRotationDegrees !== 0 && <span>{displayRotationDegrees}°</span>}
                    <ArrowCounterclockwise16Regular className="w-3 h-3" />
                  </button>
                )}
              </div>

              <div className="h-4 w-px bg-[var(--win-stroke-divider)]" />

              <button
                type="button"
                title="全屏沉浸预览 (Space)"
                onClick={() => launchQuickLook()}
                className="charkle-pressable h-7 px-2.5 rounded-[var(--win-radius-control)] inline-flex items-center gap-1.5 text-[12px] font-medium text-[var(--text-primary)] hover:bg-[var(--win-subtle-hover)] cursor-pointer"
              >
                <CharkleIcon name="quicklook" style="duotone" size={14} />
                <span>沉浸预览</span>
              </button>
            </div>
          )}

          {/* Compact Metadata & Quick 1-5 Star Rating Strip */}
          <div className="flex items-center justify-center gap-3 flex-wrap text-[12px]">
            {activeAsset.richMetadata?.socialPost?.platform === 'xiaohongshu' && (
              <span className="px-2 py-0.5 rounded-[var(--win-radius-control)] bg-[#FF2442] text-white text-[10.5px] font-semibold shrink-0">
                小红书
              </span>
            )}
            {activeAsset.richMetadata?.socialPost?.platform === 'douyin' && (
              <span className="px-2 py-0.5 rounded-[var(--win-radius-control)] bg-[#161823] border border-white/15 text-white text-[10.5px] font-semibold shrink-0">
                抖音
              </span>
            )}
            <span className="font-semibold text-[var(--text-primary)] max-w-[260px] truncate">
              {activeAsset.title}
            </span>

            {activeAsset.pixelWidth > 0 && activeAsset.pixelHeight > 0 && (
              <span className="text-[11px] charkle-mono charkle-tabular text-[var(--text-secondary)]">
                {activeAsset.pixelWidth} × {activeAsset.pixelHeight}
              </span>
            )}

            <span className="px-2 py-0.5 rounded-[var(--win-radius-control)] bg-[var(--win-subtle-hover)] text-[11px] font-medium charkle-tabular text-[var(--text-secondary)]">
              {activeIndex + 1} / {assets.length}
            </span>

            <div className="flex items-center gap-0.5">
              {[1, 2, 3, 4, 5].map((star) => {
                const filled = star <= activeAsset.rating;
                return (
                  <button
                    key={star}
                    type="button"
                    aria-label={`评为 ${star} 星`}
                    onClick={() => {
                      const next = activeAsset.rating === star ? 0 : star;
                      void updateAssets({ assetIDs: [activeAsset.id], rating: next }, destination);
                    }}
                    className={[
                      'charkle-pressable cursor-pointer p-0.5 rounded-[var(--win-radius-control)] hover:bg-[var(--win-subtle-hover)]',
                      filled ? 'text-[#E5B243] charkle-micro-pop' : 'text-[var(--text-tertiary)]/55',
                    ].join(' ')}
                  >
                    {filled ? (
                      <Star16Filled className="w-3.5 h-3.5" />
                    ) : (
                      <Star16Regular className="w-3.5 h-3.5" />
                    )}
                  </button>
                );
              })}
            </div>

            {!supportsVisualTransform && !isPlainWebBookmarkAsset(activeAsset) && (
              <Button variant="standard" size="xs" onClick={() => launchQuickLook()}>
                <CharkleIcon name="quicklook" style="duotone" size={14} />
                <span>沉浸预览</span>
              </Button>
            )}
          </div>
        </div>
      </div>

      {/* Synchronized Bottom Filmstrip Scrubber (proportional widths + wheel-to-horizontal scroll) */}
      <div
        ref={stripRef}
        className="relative z-20 shrink-0 h-[96px] border-t border-[var(--win-stroke-divider)] bg-[var(--bg-elevated)]/85 px-4 flex items-center gap-2 overflow-x-auto charkle-scroll-hidden"
      >
        {assets.map((item) => {
          const isFocused = item.id === activeAsset.id;
          const isSelected = selectedSet.has(item.id);
          const ratio =
            item.pixelWidth > 0 && item.pixelHeight > 0
              ? item.pixelWidth / item.pixelHeight
              : 1.25;
          const thumbWidth = Math.max(
            46,
            Math.min(116, Math.round(68 * Math.max(0.6, Math.min(1.75, ratio)))),
          );

          return (
            <button
              key={item.id}
              type="button"
              data-strip-id={item.id}
              data-active={isFocused ? 'true' : undefined}
              style={{ width: thumbWidth, height: 68 }}
              onPointerDown={(e) => {
                if (e.button !== 0) return;
                const dragIds = selectedSet.has(item.id) ? selectedAssetIds : [item.id];
                beginPointerDrag(e, {
                  kind: 'assets',
                  assetIds: dragIds,
                  previewAssetId: item.id,
                  title: item.title,
                });
              }}
              onClick={(e) => {
                if (wasRecentPointerDrag()) return;
                selectAsset(item.id, orderedIds, {
                  multi: e.ctrlKey || e.metaKey,
                  range: e.shiftKey,
                });
              }}
              onDoubleClick={() => launchQuickLook(item)}
              onContextMenu={(e) => {
                e.preventDefault();
                e.stopPropagation();
                const latestSel = useCoordinatorStore.getState().selectedAssetIds;
                let snapshotIds: string[];
                if (latestSel.includes(item.id) && latestSel.length > 1) {
                  snapshotIds = [...latestSel];
                } else {
                  if (!latestSel.includes(item.id)) {
                    selectAsset(item.id, orderedIds);
                  }
                  snapshotIds = [item.id];
                }
                setMoveSubOpen(false);
                setContextTarget({
                  asset: item,
                  point: { x: e.clientX, y: e.clientY },
                  targetIds: snapshotIds,
                });
              }}
              title={item.title}
              className={[
                'charkle-filmstrip-thumb shrink-0 rounded-[var(--win-radius-control)] overflow-hidden cursor-pointer bg-[var(--bg-subtle)]',
                isFocused
                  ? 'ring-2 ring-[var(--accent)] opacity-100'
                  : isSelected
                    ? 'ring-[1.5px] ring-[var(--accent)]/65 opacity-95'
                    : 'opacity-70 hover:opacity-100 ring-1 ring-[var(--win-stroke-card)]',
              ].join(' ')}
            >
              <FilmstripThumbVisual
                item={item}
                src={cacheBustedUrl(
                  transport.thumbnailUrl(item.id, 'grid520'),
                  (thumbnailRevisions[item.id] ?? 0) > 0
                    ? `${String(item.updatedAt ?? 0)}-${thumbnailRevisions[item.id]}`
                    : item.updatedAt,
                )}
              />
            </button>
          );
        })}
      </div>

      {/* Stage & Filmstrip Shared Fluent Acrylic Right-Click Context Menu */}
      <Popover
        open={contextTarget !== null}
        onOpenChange={(open) => {
          if (!open) {
            setContextTarget(null);
            setMoveSubOpen(false);
          }
        }}
        anchorPoint={contextTarget?.point ?? null}
        className="w-[236px] p-1"
      >
        {contextTarget && (
          <div className="flex flex-col gap-0.5 text-[13px] leading-[18px]">
            <button
              type="button"
              onClick={() => {
                const target = contextTarget.asset;
                setContextTarget(null);
                if (isPlainWebBookmarkAsset(target) && target.sourceURL) {
                  openExternalBookmark(target);
                } else {
                  openQuickLook(target.id, null);
                }
              }}
              className="w-full min-h-[32px] flex items-center gap-2.5 px-2.5 py-1.5 rounded-[var(--win-radius-control)] text-[var(--text-primary)] hover:bg-[var(--win-subtle-hover)] cursor-pointer"
            >
              <span className="w-4 h-4 inline-flex items-center justify-center shrink-0 text-[var(--text-secondary)]">
                {isPlainWebBookmarkAsset(contextTarget.asset) && contextTarget.asset.sourceURL ? (
                  <Open16Regular className="w-4 h-4" />
                ) : (
                  <Eye16Regular className="w-4 h-4" />
                )}
              </span>
              <span className="flex-1 text-left truncate">
                {isPlainWebBookmarkAsset(contextTarget.asset) && contextTarget.asset.sourceURL
                  ? '在默认浏览器中打开'
                  : '沉浸预览'}
              </span>
            </button>

            {contextTarget.asset.sourceURL && !isPlainWebBookmarkAsset(contextTarget.asset) && (
              <button
                type="button"
                onClick={() => {
                  const url = contextTarget.asset.sourceURL;
                  setContextTarget(null);
                  if (url) void transport.openExternalUrl(url);
                }}
                className="w-full min-h-[32px] flex items-center gap-2.5 px-2.5 py-1.5 rounded-[var(--win-radius-control)] text-[var(--text-primary)] hover:bg-[var(--win-subtle-hover)] cursor-pointer"
              >
                <Open16Regular className="w-4 h-4 text-[var(--text-secondary)] shrink-0" />
                <span className="flex-1 text-left truncate">打开来源网页</span>
              </button>
            )}

            <div className="my-1 mx-2 h-px bg-[var(--win-stroke-divider)]" />

            <button
              type="button"
              onClick={() => {
                const ids = [...contextTargetIds];
                setContextTarget(null);
                void transport.copyAssetsToClipboard(ids).then((n) =>
                  pushToast({ message: `已拷贝 ${n} 项素材到剪贴板`, tone: 'success' }),
                );
              }}
              className="w-full min-h-[32px] flex items-center gap-2.5 px-2.5 py-1.5 rounded-[var(--win-radius-control)] text-[var(--text-primary)] hover:bg-[var(--win-subtle-hover)] cursor-pointer"
            >
              <Copy16Regular className="w-4 h-4 text-[var(--text-secondary)] shrink-0" />
              <span className="flex-1 text-left truncate">拷贝{contextCountSuffix}</span>
            </button>

            <button
              type="button"
              onClick={() => {
                const id = contextTarget.asset.id;
                setContextTarget(null);
                void transport.revealInExplorer(id);
              }}
              className="w-full min-h-[32px] flex items-center gap-2.5 px-2.5 py-1.5 rounded-[var(--win-radius-control)] text-[var(--text-primary)] hover:bg-[var(--win-subtle-hover)] cursor-pointer"
            >
              <FolderOpen16Regular className="w-4 h-4 text-[var(--text-secondary)] shrink-0" />
              <span className="flex-1 text-left truncate">在资源管理器中显示</span>
            </button>

            <div className="my-1 mx-2 h-px bg-[var(--win-stroke-divider)]" />

            {!(contextTarget.asset.isTrashed || destination.type === 'trash') ? (
              <>
                <button
                  type="button"
                  onClick={() => {
                    const ids = [...contextTargetIds];
                    setContextTarget(null);
                    const boardId = activeMoodboardId ?? boards[0]?.id;
                    if (boardId) {
                      void addAssetsToBoard(boardId, ids);
                    } else {
                      setMoodboardGeneratorOpen(true);
                    }
                  }}
                  className="w-full min-h-[32px] flex items-center gap-2.5 px-2.5 py-1.5 rounded-[var(--win-radius-control)] text-[var(--text-primary)] hover:bg-[var(--win-subtle-hover)] cursor-pointer"
                >
                  <Board16Regular className="w-4 h-4 text-[var(--text-secondary)] shrink-0" />
                  <span className="flex-1 text-left truncate">
                    加入活跃情绪板{contextCountSuffix}
                  </span>
                </button>

                <div className="relative">
                  <button
                    type="button"
                    onClick={() => setMoveSubOpen((v) => !v)}
                    className="w-full min-h-[32px] flex items-center gap-2.5 px-2.5 py-1.5 rounded-[var(--win-radius-control)] text-[var(--text-primary)] hover:bg-[var(--win-subtle-hover)] cursor-pointer"
                  >
                    <FolderArrowRight16Regular className="w-4 h-4 text-[var(--text-secondary)] shrink-0" />
                    <span className="flex-1 text-left truncate">
                      移动到文件夹{contextCountSuffix}
                    </span>
                    <ChevronRight16Regular className="w-3.5 h-3.5 text-[var(--text-tertiary)] shrink-0" />
                  </button>
                  {moveSubOpen && (
                    <div className="mt-1 pl-1 border-t border-[var(--win-stroke-divider)] pt-1">
                      <FolderMoveMenu
                        folders={folders}
                        currentFolderId={
                          contextTargetIds.length === 1
                            ? (contextTarget.asset.folderID ?? null)
                            : undefined
                        }
                        onSelectFolder={(folderId) => {
                          const ids = [...contextTargetIds];
                          const prevFolder = contextTarget.asset.folderID;
                          setContextTarget(null);
                          setMoveSubOpen(false);
                          const destName = folderId
                            ? folders.find((f) => f.id === folderId)?.name ?? '文件夹'
                            : '收件箱';
                          void updateAssets(
                            {
                              assetIDs: ids,
                              folderAssignment: folderId ? { folder: folderId } : 'inbox',
                            },
                            destination,
                            {
                              undoMessage: `已移动 ${ids.length} 项至「${destName}」`,
                              undoPatch: {
                                assetIDs: ids,
                                folderAssignment: prevFolder ? { folder: prevFolder } : 'inbox',
                              },
                            },
                          );
                        }}
                      />
                    </div>
                  )}
                </div>

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
                          ? '已设为始终保留在本地'
                          : '已取消始终保留，将按需管理空间',
                        tone: 'info',
                      }),
                    );
                  }}
                  className="w-full min-h-[32px] flex items-center gap-2.5 px-2.5 py-1.5 rounded-[var(--win-radius-control)] text-[var(--text-primary)] hover:bg-[var(--win-subtle-hover)] cursor-pointer"
                >
                  <span className="w-4 h-4 inline-flex items-center justify-center shrink-0 text-[var(--text-secondary)]">
                    {contextTarget.asset.pinnedOffline ? (
                      <Cloud16Regular className="w-4 h-4" />
                    ) : (
                      <ArrowDownload16Regular className="w-4 h-4" />
                    )}
                  </span>
                  <span className="flex-1 text-left truncate">
                    {contextTarget.asset.pinnedOffline
                      ? `取消始终保留在本地${contextCountSuffix}`
                      : `始终保留在本地${contextCountSuffix}`}
                  </span>
                </button>

                <div className="my-1 mx-2 h-px bg-[var(--win-stroke-divider)]" />

                <button
                  type="button"
                  onClick={() => {
                    const ids = [...contextTargetIds];
                    setContextTarget(null);
                    pruneSelectionIds(ids);
                    void updateAssets({ assetIDs: ids, isTrashed: true }, destination, {
                      undoMessage: `已移至回收站 (${ids.length} 项)`,
                      undoPatch: { assetIDs: ids, isTrashed: false },
                    });
                  }}
                  className="w-full min-h-[32px] flex items-center gap-2.5 px-2.5 py-1.5 rounded-[var(--win-radius-control)] text-[var(--danger)] hover:bg-[var(--danger-soft)] cursor-pointer"
                >
                  <Delete16Regular className="w-4 h-4 shrink-0" />
                  <span className="flex-1 text-left truncate">移至回收站{contextCountSuffix}</span>
                </button>
              </>
            ) : (
              <>
                <button
                  type="button"
                  onClick={() => {
                    const ids = [...contextTargetIds];
                    setContextTarget(null);
                    pruneSelectionIds(ids);
                    void updateAssets({ assetIDs: ids, isTrashed: false }, destination).then(() =>
                      pushToast({ message: `已将 ${ids.length} 项放回原处`, tone: 'success' }),
                    );
                  }}
                  className="w-full min-h-[32px] flex items-center gap-2.5 px-2.5 py-1.5 rounded-[var(--win-radius-control)] text-[var(--text-primary)] hover:bg-[var(--win-subtle-hover)] cursor-pointer"
                >
                  <ArrowUndo16Regular className="w-4 h-4 text-[var(--text-secondary)] shrink-0" />
                  <span className="flex-1 text-left truncate">放回原处{contextCountSuffix}</span>
                </button>
                <button
                  type="button"
                  onClick={() => {
                    const ids = [...contextTargetIds];
                    setContextTarget(null);
                    setPermDeleteIds(ids);
                  }}
                  className="w-full min-h-[32px] flex items-center gap-2.5 px-2.5 py-1.5 rounded-[var(--win-radius-control)] text-[var(--danger)] hover:bg-[var(--danger-soft)] cursor-pointer"
                >
                  <Delete16Regular className="w-4 h-4 shrink-0" />
                  <span className="flex-1 text-left truncate">彻底删除{contextCountSuffix}</span>
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
            <Button variant="standard" onClick={() => setPermDeleteIds(null)}>
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
