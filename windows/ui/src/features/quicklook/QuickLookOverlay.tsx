import React, { useEffect, useMemo, useRef, useState } from 'react';
import { createPortal } from 'react-dom';
import {
  ArrowClockwise16Regular,
  ArrowCounterclockwise16Regular,
  ArrowDownload16Regular,
  ArrowUndo16Regular,
  Board16Regular,
  ChevronLeft20Regular,
  ChevronRight20Regular,
  Copy16Regular,
  Delete16Regular,
  Dismiss16Regular,
  DocumentBulletList16Regular,
  FlipHorizontal16Regular,
  FlipVertical16Regular,
  FolderOpen16Regular,
  Open16Regular,
  PanelRight16Filled,
  PanelRight16Regular,
  Pause16Regular,
  Play16Filled,
  ScaleFit16Regular,
  Star16Filled,
  Star16Regular,
  VideoClip24Regular,
  ZoomIn16Regular,
  ZoomOut16Regular,
} from '@fluentui/react-icons';
import { getTransport } from '../../api/transport';
import {
  AnimatePresence,
  Button,
  Popover,
  Tooltip,
  WIN_EASE_OUT,
  WIN_SPRING_SNAPPY,
  WIN_TRANSITION_EXIT,
  WIN_TRANSITION_FAST,
  WIN_TRANSITION_NORMAL,
  computeAmbientTintStyle,
  isLongStripImage,
  m,
  useResolvedIsDark,
} from '../../design-system';
import {
  DEFAULT_INSPECTOR_WIDTH,
  MAX_INSPECTOR_WIDTH,
  MIN_INSPECTOR_WIDTH,
  clampInspectorWidth,
  useCoordinatorStore,
  useLibraryStore,
  useMoodboardStore,
  type QuickLookOriginRect,
} from '../../stores';
import { mediaKindLabel, type AssetRecord } from '../../types/domain';
import { PaneResizeDivider } from '../chrome/PaneResizeDivider';
import { InspectorView } from '../inspector/InspectorView';
import { AudioStudioViewer } from './AudioStudioViewer';
import { DocumentMarkdownViewer } from './DocumentMarkdownViewer';
import { GitHubRepoViewer } from './GitHubRepoViewer';
import { ImageStageViewer } from './ImageStageViewer';
import { Model3DViewer } from './Model3DViewer';
import { PdfDocumentViewer } from './PdfDocumentViewer';
import { SocialPostViewer } from './SocialPostViewer';

function isTypingInsideQuickLook(target: EventTarget | null): boolean {
  const el = target as HTMLElement | null;
  if (!el) return false;
  const tag = el.tagName;
  return tag === 'INPUT' || tag === 'TEXTAREA' || tag === 'SELECT' || el.isContentEditable;
}

function withQuickLookThumbCacheBust(url: string, version?: string | number | null): string {
  if (version == null || version === '' || url.startsWith('data:') || url.startsWith('blob:')) {
    return url;
  }
  const sep = url.includes('?') ? '&' : '?';
  return `${url}${sep}v=${encodeURIComponent(String(version))}`;
}

function formatQuickLookBookmarkDomain(
  asset: Pick<AssetRecord, 'sourceDomain' | 'sourceURL'>,
): string {
  if (asset.sourceDomain?.trim()) {
    return asset.sourceDomain.trim().replace(/^www\./i, '');
  }
  if (asset.sourceURL) {
    try {
      return new URL(asset.sourceURL).host.toLowerCase().replace(/^www\./, '');
    } catch {
      // Fallback below
    }
  }
  return '网页';
}

function isMotionReducedNow(): boolean {
  if (typeof document !== 'undefined' && document.documentElement.dataset.animations === 'disabled') {
    return true;
  }
  if (typeof window !== 'undefined' && typeof window.matchMedia === 'function') {
    return window.matchMedia('(prefers-reduced-motion: reduce)').matches;
  }
  return false;
}

function isValidRect(rect: QuickLookOriginRect | null | undefined): rect is QuickLookOriginRect {
  return Boolean(
    rect &&
      Number.isFinite(rect.left) &&
      Number.isFinite(rect.top) &&
      Number.isFinite(rect.width) &&
      Number.isFinite(rect.height) &&
      rect.width > 4 &&
      rect.height > 4,
  );
}

function queryVisibleCardRect(assetId: string): QuickLookOriginRect | null {
  if (typeof document === 'undefined' || typeof window === 'undefined') return null;
  const escaped =
    typeof CSS !== 'undefined' && typeof CSS.escape === 'function'
      ? CSS.escape(assetId)
      : assetId.replace(/["\\]/g, '\\$&');
  const el = document.querySelector<HTMLElement>(`[data-asset-card-id="${escaped}"]`);
  if (!el) return null;
  const rect = el.getBoundingClientRect();
  if (!isValidRect(rect)) return null;
  const vw = window.innerWidth || 1280;
  const vh = window.innerHeight || 800;
  const isVisible = rect.right > 0 && rect.left < vw && rect.bottom > 0 && rect.top < vh;
  if (!isVisible) return null;
  return {
    left: rect.left,
    top: rect.top,
    width: rect.width,
    height: rect.height,
  };
}

interface FlipDelta {
  x: number;
  y: number;
  scaleX: number;
  scaleY: number;
}

function computeConnectedFlipDelta(
  cardRect: QuickLookOriginRect | null | undefined,
  asset: Pick<AssetRecord, 'pixelWidth' | 'pixelHeight'>,
  inspectorOpen: boolean,
  inspectorWidth = DEFAULT_INSPECTOR_WIDTH,
): FlipDelta | null {
  if (!isValidRect(cardRect) || typeof window === 'undefined') return null;
  const vw = window.innerWidth || 1280;
  const vh = window.innerHeight || 800;
  const stageW = inspectorOpen ? Math.max(320, vw - inspectorWidth) : vw;
  const padX = inspectorOpen ? 56 : 96;
  const headerH = 56;
  const hudH = 72;
  const availW = Math.max(160, stageW - padX);
  const availH = Math.max(160, vh - headerH - hudH - 24);

  const stageCenterX = stageW * 0.5;
  const stageCenterY = headerH + (vh - headerH - hudH) * 0.5;

  let targetW = Math.min(680, availW);
  let targetH = Math.min(480, availH);
  if (asset.pixelWidth > 0 && asset.pixelHeight > 0) {
    const ratio = asset.pixelWidth / asset.pixelHeight;
    if (availW / availH > ratio) {
      targetH = Math.min(availH, vh * 0.76);
      targetW = targetH * ratio;
    } else {
      targetW = availW;
      targetH = targetW / ratio;
    }
  } else if (cardRect.width > 0 && cardRect.height > 0) {
    const ratio = cardRect.width / cardRect.height;
    if (availW / availH > ratio) {
      targetH = availH * 0.72;
      targetW = targetH * ratio;
    } else {
      targetW = availW * 0.72;
      targetH = targetW / ratio;
    }
  }

  const srcCenterX = cardRect.left + cardRect.width * 0.5;
  const srcCenterY = cardRect.top + cardRect.height * 0.5;

  return {
    x: Math.round(srcCenterX - stageCenterX),
    y: Math.round(srcCenterY - stageCenterY),
    scaleX: Number(Math.max(0.12, Math.min(1.4, cardRect.width / Math.max(60, targetW))).toFixed(4)),
    scaleY: Number(Math.max(0.12, Math.min(1.4, cardRect.height / Math.max(60, targetH))).toFixed(4)),
  };
}

const QuickLookVideoStage: React.FC<{
  asset: AssetRecord;
  src: string;
  poster: string;
}> = ({ asset, src, poster }) => {
  const videoRef = useRef<HTMLVideoElement | null>(null);
  const [failed, setFailed] = useState(false);

  useEffect(() => {
    setFailed(false);
  }, [asset.id, src]);

  useEffect(() => {
    const el = videoRef.current;
    return () => {
      if (el) {
        el.pause();
        el.removeAttribute('src');
        try {
          el.load();
        } catch {
          // Ignore in jsdom
        }
      }
    };
  }, [asset.id, src, failed]);

  if (failed) {
    return (
      <div
        onClick={(e) => e.stopPropagation()}
        className="max-w-[440px] mx-auto p-6 rounded-[var(--win-radius-dialog)] bg-[var(--bg-elevated)] border border-[var(--win-stroke-flyout)] text-center flex flex-col items-center gap-3 shadow-2xl"
      >
        <VideoClip24Regular className="w-7 h-7 text-[var(--text-tertiary)]" />
        <div className="text-[14px] font-semibold text-[var(--text-primary)]">{asset.title}</div>
        <p className="text-[12.5px] text-[var(--text-secondary)]">
          当前视频编码或文件暂无法内嵌播放，可在资源管理器中使用系统播放器打开。
        </p>
        <Button
          variant="accent"
          size="sm"
          onClick={() => void getTransport().revealInExplorer(asset.id)}
        >
          <FolderOpen16Regular className="w-4 h-4" />
          在资源管理器中显示
        </Button>
      </div>
    );
  }

  return (
    <video
      ref={videoRef}
      src={src}
      poster={poster}
      controls
      autoPlay
      playsInline
      onError={() => setFailed(true)}
      onClick={(e) => e.stopPropagation()}
      className="max-w-[82vw] max-h-[74vh] rounded-[var(--win-radius-card)] shadow-[0_24px_60px_rgba(0,0,0,0.48)] bg-black"
    />
  );
};

/**
 * Full-Media Spacebar Quick Look Overlay with Fluent 2 Connected Animation (FLIP):
 * - Opens smoothly from `quickLookOriginRect` via `WIN_SPRING_SNAPPY` (`m.div`) while fading in
 *   `.win-smoke-scrim` + subtle radial ambient tint (`computeAmbientTintStyle`)
 * - Closes back toward live `[data-asset-card-id]` when visible in viewport, or soft scale-down (0.96) + fade out
 * - Instant 0ms keyboard stepping (Space / Esc / Arrows / R / Shift+H/V / 0 / +/-)
 * - Full-height 300px synchronized Right Inspector (`InspectorView`) & `.win-acrylic-dark` HUD
 */
export const QuickLookOverlay: React.FC = () => {
  const quickLookAssetId = useCoordinatorStore((s) => s.quickLookAssetId);
  const quickLookOriginRect = useCoordinatorStore((s) => s.quickLookOriginRect);
  const openQuickLook = useCoordinatorStore((s) => s.openQuickLook);
  const closeQuickLook = useCoordinatorStore((s) => s.closeQuickLook);
  const setSelection = useCoordinatorStore((s) => s.setSelection);
  const destination = useCoordinatorStore((s) => s.destination);
  const inspectorOpen = useCoordinatorStore((s) => s.inspectorOpen);
  const inspectorWidth = useCoordinatorStore((s) => s.inspectorWidth);
  const setInspectorWidth = useCoordinatorStore((s) => s.setInspectorWidth);
  const commitInspectorWidth = useCoordinatorStore((s) => s.commitInspectorWidth);
  const resetInspectorWidth = useCoordinatorStore((s) => s.resetInspectorWidth);
  const isResizingPane = useCoordinatorStore((s) => s.isResizingPane);
  const setResizingPane = useCoordinatorStore((s) => s.setResizingPane);
  const toggleInspector = useCoordinatorStore((s) => s.toggleInspector);
  const openMoodboardGenerator = useCoordinatorStore((s) => s.openMoodboardGenerator);
  const pushToast = useCoordinatorStore((s) => s.pushToast);

  const [windowWidth, setWindowWidth] = useState<number>(() =>
    typeof window !== 'undefined' && window.innerWidth > 0 ? window.innerWidth : 1360,
  );
  useEffect(() => {
    if (typeof window === 'undefined') return;
    const onResize = () => {
      if (window.innerWidth > 0) setWindowWidth(window.innerWidth);
    };
    window.addEventListener('resize', onResize);
    return () => window.removeEventListener('resize', onResize);
  }, []);

  const effectiveInspectorWidth = clampInspectorWidth(inspectorWidth, windowWidth, 0);

  const assets = useLibraryStore((s) => s.assets);
  const allAssets = useLibraryStore((s) => s.allAssets);
  const bootstrapped = useLibraryStore((s) => s.bootstrapped);
  const updateAssets = useLibraryStore((s) => s.updateAssets);
  const permanentlyDeleteAssets = useLibraryStore((s) => s.permanentlyDeleteAssets);
  const markAssetOpened = useLibraryStore((s) => s.markAssetOpened);

  const boards = useMoodboardStore((s) => s.boards);
  const addAssetsToBoard = useMoodboardStore((s) => s.addAssetsToBoard);

  const isDark = useResolvedIsDark();

  const [zoom, setZoom] = useState(1);
  const [rotationDegrees, setRotationDegrees] = useState(0);
  const [flipHorizontal, setFlipHorizontal] = useState(false);
  const [flipVertical, setFlipVertical] = useState(false);
  const [longStripMode, setLongStripMode] = useState(false);
  const [pausedAnim, setPausedAnim] = useState(false);
  const [boardMenuOpen, setBoardMenuOpen] = useState(false);
  const [confirmDeleteOpen, setConfirmDeleteOpen] = useState(false);

  const boardBtnRef = useRef<HTMLButtonElement | null>(null);
  const freezeAnimRef = useRef<(() => void) | null>(null);
  const lastActiveAssetRef = useRef<AssetRecord | null>(null);

  const activeIndex = useMemo(() => {
    if (!quickLookAssetId) return -1;
    return assets.findIndex((a) => a.id === quickLookAssetId);
  }, [assets, quickLookAssetId]);

  const asset: AssetRecord | null = useMemo(() => {
    if (!quickLookAssetId) return null;
    if (activeIndex >= 0) return assets[activeIndex];
    return allAssets.find((a) => a.id === quickLookAssetId) ?? null;
  }, [quickLookAssetId, activeIndex, assets, allAssets]);

  if (asset) {
    lastActiveAssetRef.current = asset;
  }

  const isSwatchAsset = Boolean(asset && asset.fileName.toLowerCase().endsWith('.swatch'));
  const isTallStrip = asset ? isLongStripImage(asset) : false;
  const supportsVisualTransform = Boolean(
    asset &&
      !isSwatchAsset &&
      !asset.richMetadata?.githubRepo &&
      !asset.richMetadata?.socialPost &&
      (asset.mediaKind === 'image' ||
        asset.mediaKind === 'designFile' ||
        asset.mediaKind === 'animatedImage'),
  );
  const maxZoomLimit = asset
    ? Math.max(6, Math.min(16, Math.max(asset.pixelWidth, asset.pixelHeight) / 550))
    : 8;

  const normalizedRot = ((Math.round(rotationDegrees) % 360) + 360) % 360;
  const hasActiveTransform = normalizedRot !== 0 || flipHorizontal || flipVertical;

  // Auto-close ghost Quick Look if the referenced asset no longer exists after bootstrap/sync/delete
  useEffect(() => {
    if (quickLookAssetId && bootstrapped && !asset) {
      closeQuickLook();
    }
  }, [quickLookAssetId, bootstrapped, asset, closeQuickLook]);

  // Resign stale underlying text/button focus immediately upon entering Quick Look
  useEffect(() => {
    if (!quickLookAssetId) return;
    (document.activeElement as HTMLElement | null)?.blur?.();
  }, [quickLookAssetId]);

  useEffect(() => {
    if (!asset) return;
    setZoom(1);
    setRotationDegrees(0);
    setFlipHorizontal(false);
    setFlipVertical(false);
    setLongStripMode(isLongStripImage(asset));
    setPausedAnim(false);
    setBoardMenuOpen(false);
    setConfirmDeleteOpen(false);
    void markAssetOpened(asset.id);
  }, [asset?.id, markAssetOpened]);

  const rotateBy = (screenDelta: number) => {
    if (!supportsVisualTransform) return;
    setLongStripMode(false);
    const parity = flipHorizontal !== flipVertical ? -1 : 1;
    setRotationDegrees((r) => r + screenDelta * parity);
  };

  const resetTransforms = (resetZoomToo = true) => {
    if (resetZoomToo) setZoom(1);
    setRotationDegrees(0);
    setFlipHorizontal(false);
    setFlipVertical(false);
  };

  const stepPlaylist = (delta: number) => {
    if (assets.length <= 1 || activeIndex < 0) return;
    const nextIdx = (activeIndex + delta + assets.length) % assets.length;
    const target = assets[nextIdx];
    if (target) {
      openQuickLook(target.id, null);
      setSelection([target.id], target.id);
    }
  };

  useEffect(() => {
    if (!quickLookAssetId) return;
    const handleKey = (e: KeyboardEvent) => {
      if (e.defaultPrevented) return;
      const coordState = useCoordinatorStore.getState();
      if (
        coordState.jumpOpen ||
        coordState.captureOpen ||
        coordState.settingsOpen ||
        coordState.onboardingOpen ||
        coordState.moodboardGeneratorOpen
      ) {
        return;
      }

      if (confirmDeleteOpen) {
        if (e.key === 'Escape') {
          e.preventDefault();
          e.stopPropagation();
          e.stopImmediatePropagation();
          setConfirmDeleteOpen(false);
        }
        return;
      }

      // Let open Popovers or Inspector confirmation modals handle Escape first
      if (
        e.key === 'Escape' &&
        document.querySelector(
          '[data-charkle-popover-open="true"], [data-inspector-delete-open="true"]',
        )
      ) {
        return;
      }

      const mod = e.ctrlKey || e.metaKey;
      const hasPrimaryModifiers = mod || e.altKey || e.shiftKey;

      // Respect active text editing inside docked Inspector; Escape blurs field first
      if (isTypingInsideQuickLook(e.target)) {
        if (e.key === 'Escape' && !hasPrimaryModifiers && !e.isComposing && e.keyCode !== 229) {
          e.preventDefault();
          e.stopPropagation();
          e.stopImmediatePropagation();
          (e.target as HTMLElement).blur();
        }
        return;
      }

      if (
        (e.key === 'Escape' && !hasPrimaryModifiers) ||
        (e.code === 'Space' && !hasPrimaryModifiers)
      ) {
        if (e.repeat) {
          e.preventDefault();
          e.stopPropagation();
          e.stopImmediatePropagation();
          return;
        }
        e.preventDefault();
        e.stopPropagation();
        e.stopImmediatePropagation();
        closeQuickLook();
        return;
      }

      if (!hasPrimaryModifiers && e.key === 'ArrowLeft') {
        if (assets.length > 1 && activeIndex >= 0) {
          e.preventDefault();
          e.stopPropagation();
          e.stopImmediatePropagation();
          stepPlaylist(-1);
        }
        return;
      }

      if (!hasPrimaryModifiers && e.key === 'ArrowRight') {
        if (assets.length > 1 && activeIndex >= 0) {
          e.preventDefault();
          e.stopPropagation();
          e.stopImmediatePropagation();
          stepPlaylist(1);
        }
        return;
      }

      if (!hasPrimaryModifiers && (e.key === 'Delete' || e.key === 'Backspace') && asset) {
        e.preventDefault();
        e.stopPropagation();
        e.stopImmediatePropagation();
        if (asset.isTrashed) {
          setConfirmDeleteOpen(true);
        } else {
          const id = asset.id;
          void updateAssets({ assetIDs: [id], isTrashed: true }, destination, {
            undoMessage: '已移至回收站',
            undoPatch: { assetIDs: [id], isTrashed: false },
          });
        }
        return;
      }

      if (!mod && !e.altKey && supportsVisualTransform) {
        const lower = e.key.toLowerCase();
        if (lower === 'r' && !e.shiftKey) {
          e.preventDefault();
          e.stopImmediatePropagation();
          rotateBy(90);
        } else if (lower === 'r' && e.shiftKey) {
          e.preventDefault();
          e.stopImmediatePropagation();
          rotateBy(-90);
        } else if (lower === 'h' && e.shiftKey) {
          e.preventDefault();
          e.stopImmediatePropagation();
          setLongStripMode(false);
          setFlipHorizontal((v) => !v);
        } else if (lower === 'v' && e.shiftKey) {
          e.preventDefault();
          e.stopImmediatePropagation();
          setLongStripMode(false);
          setFlipVertical((v) => !v);
        } else if (e.key === '0' && !e.shiftKey) {
          e.preventDefault();
          e.stopImmediatePropagation();
          resetTransforms(true);
        } else if (e.key === '+' || e.key === '=') {
          e.preventDefault();
          e.stopImmediatePropagation();
          setLongStripMode(false);
          setZoom((z) => Math.min(maxZoomLimit, Number((z * 1.25).toFixed(2))));
        } else if (e.key === '-' && !e.shiftKey) {
          e.preventDefault();
          e.stopImmediatePropagation();
          setLongStripMode(false);
          setZoom((z) => Math.max(0.5, Number((z * 0.8).toFixed(2))));
        }
      }
    };
    window.addEventListener('keydown', handleKey, true);
    return () => window.removeEventListener('keydown', handleKey, true);
  }, [
    quickLookAssetId,
    confirmDeleteOpen,
    activeIndex,
    assets,
    supportsVisualTransform,
    maxZoomLimit,
    flipHorizontal,
    flipVertical,
    closeQuickLook,
    openQuickLook,
    setSelection,
    asset,
    destination,
    updateAssets,
  ]);

  const openFlipDelta = useMemo(() => {
    if (!asset || isMotionReducedNow()) return null;
    return computeConnectedFlipDelta(
      quickLookOriginRect,
      asset,
      inspectorOpen,
      effectiveInspectorWidth,
    );
  }, [asset?.id, quickLookOriginRect, inspectorOpen, effectiveInspectorWidth]);

  if (typeof document === 'undefined') return null;

  const transport = getTransport();
  const canStep = assets.length > 1 && activeIndex >= 0;

  const stageVariants = {
    enter: () => {
      if (isMotionReducedNow()) {
        return { opacity: 0, x: 0, y: 0, scaleX: 1, scaleY: 1 };
      }
      if (openFlipDelta) {
        return {
          x: openFlipDelta.x,
          y: openFlipDelta.y,
          scaleX: openFlipDelta.scaleX,
          scaleY: openFlipDelta.scaleY,
          opacity: 0.72,
        };
      }
      return { x: 0, y: 0, scaleX: 0.96, scaleY: 0.96, opacity: 0 };
    },
    center: {
      x: 0,
      y: 0,
      scaleX: 1,
      scaleY: 1,
      opacity: 1,
      transition: isMotionReducedNow()
        ? { duration: 0.14, ease: WIN_EASE_OUT }
        : openFlipDelta
          ? WIN_SPRING_SNAPPY
          : WIN_TRANSITION_NORMAL,
    },
    exit: () => {
      if (isMotionReducedNow()) {
        return { opacity: 0, transition: WIN_TRANSITION_EXIT };
      }
      const closingAsset = lastActiveAssetRef.current;
      if (closingAsset) {
        const liveCardRect = queryVisibleCardRect(closingAsset.id);
        const exitDelta = computeConnectedFlipDelta(liveCardRect, closingAsset, inspectorOpen);
        if (exitDelta) {
          return {
            x: exitDelta.x,
            y: exitDelta.y,
            scaleX: exitDelta.scaleX,
            scaleY: exitDelta.scaleY,
            opacity: 0,
            transition: { duration: 0.167, ease: WIN_EASE_OUT },
          };
        }
      }
      return {
        x: 0,
        y: 0,
        scaleX: 0.96,
        scaleY: 0.96,
        opacity: 0,
        transition: WIN_TRANSITION_EXIT,
      };
    },
  };

  const renderWebBookmarkCard = (active: AssetRecord) => {
    const dotHex = active.dominantColors[0]?.hex ?? '#5C6B73';
    const domain = formatQuickLookBookmarkDomain(active);
    const previewUrl = withQuickLookThumbCacheBust(
      transport.thumbnailUrl(active.id, 'preview1400'),
      active.updatedAt,
    );
    return (
      <div
        onClick={(e) => e.stopPropagation()}
        className="w-full max-w-[680px] p-5 rounded-[var(--win-radius-dialog)] bg-[var(--bg-elevated)] border border-[var(--win-stroke-flyout)] shadow-[0_24px_60px_rgba(0,0,0,0.42)] flex flex-col gap-3.5"
      >
        <div className="flex items-center justify-between gap-3">
          <div className="flex items-center gap-2.5 min-w-0">
            <span
              className="w-3 h-3 rounded-full shrink-0"
              style={{ backgroundColor: dotHex }}
            />
            <span className="text-[13px] font-semibold charkle-mono text-[var(--text-secondary)] truncate">
              {active.sourceDomain ?? domain}
            </span>
          </div>
          {active.sourceURL && (
            <Button
              variant="accent"
              size="xs"
              onClick={() =>
                void transport
                  .openExternalUrl(active.sourceURL!)
                  .then(() => {
                    pushToast({
                      message: `已在默认浏览器中打开 ${domain}`,
                      tone: 'info',
                    });
                  })
                  .catch(() => {
                    pushToast({ message: '无法在默认浏览器中打开链接', tone: 'error' });
                  })
              }
            >
              <Open16Regular className="w-3.5 h-3.5" />
              在默认浏览器中打开
            </Button>
          )}
        </div>

        <div className="w-full max-h-[380px] rounded-[var(--win-radius-card)] overflow-hidden border border-[var(--win-stroke-card)] bg-[var(--bg-subtle)]/40 flex items-center justify-center">
          <img
            src={previewUrl}
            alt={active.title}
            draggable={false}
            className="w-full max-h-[380px] object-contain"
          />
        </div>

        <h3 className="text-[18px] font-semibold text-[var(--text-primary)] charkle-heading">
          {active.title}
        </h3>

        {active.sourceURL && (
          <p className="text-[12px] charkle-mono text-[var(--text-secondary)] select-text break-all">
            {active.sourceURL}
          </p>
        )}

        {active.notes && (
          <>
            <div className="h-px bg-[var(--win-stroke-divider)]" />
            <p className="text-[13px] leading-relaxed text-[var(--text-primary)] whitespace-pre-wrap select-text">
              {active.notes}
            </p>
          </>
        )}
      </div>
    );
  };

  const renderSwatchCard = (active: AssetRecord) => {
    const hex = (active.dominantColors[0]?.hex ?? '#2A60E0').toUpperCase();
    return (
      <div
        onClick={(e) => e.stopPropagation()}
        className="w-[380px] rounded-[var(--win-radius-dialog)] overflow-hidden bg-[var(--bg-elevated)] border border-[var(--win-stroke-flyout)] shadow-[0_24px_60px_rgba(0,0,0,0.45)] flex flex-col"
      >
        <div className="h-[260px] w-full" style={{ backgroundColor: hex }} />
        <div className="p-5 flex items-center justify-between gap-3">
          <div className="min-w-0">
            <div className="text-[16px] font-semibold text-[var(--text-primary)] truncate">
              {active.title}
            </div>
            <div className="text-[13px] charkle-mono text-[var(--text-secondary)] mt-0.5">
              {hex}
            </div>
          </div>
          <Button
            variant="standard"
            size="xs"
            onClick={() => {
              if (!navigator.clipboard?.writeText) {
                pushToast({ message: '无法写入系统剪贴板', tone: 'error' });
                return;
              }
              void navigator.clipboard
                .writeText(hex)
                .then(() => {
                  pushToast({ message: `已复制色值 ${hex}`, tone: 'success' });
                })
                .catch(() => {
                  pushToast({ message: '无法写入系统剪贴板', tone: 'error' });
                });
            }}
          >
            <Copy16Regular className="w-3.5 h-3.5" />
            复制 HEX
          </Button>
        </div>
      </div>
    );
  };

  const renderMediaStage = (active: AssetRecord) => {
    if (active.richMetadata?.githubRepo) {
      return (
        <div
          onClick={(e) => e.stopPropagation()}
          className="w-full h-full flex items-center justify-center"
        >
          <GitHubRepoViewer asset={active} />
        </div>
      );
    }
    if (active.richMetadata?.socialPost) {
      return (
        <div
          onClick={(e) => e.stopPropagation()}
          className="w-full h-full flex items-center justify-center"
        >
          <SocialPostViewer asset={active} />
        </div>
      );
    }
    if (isSwatchAsset) {
      return renderSwatchCard(active);
    }
    if (active.mediaKind === 'webBookmark') {
      return renderWebBookmarkCard(active);
    }
    if (active.mediaKind === 'video') {
      return (
        <QuickLookVideoStage
          key={active.id}
          asset={active}
          src={transport.originalUrl(active.id)}
          poster={transport.thumbnailUrl(active.id, 'preview1400')}
        />
      );
    }
    if (active.mediaKind === 'audio') {
      return (
        <div onClick={(e) => e.stopPropagation()} className="w-full flex justify-center">
          <AudioStudioViewer asset={active} />
        </div>
      );
    }
    if (active.mediaKind === 'model3D') {
      return (
        <div
          onClick={(e) => e.stopPropagation()}
          className="w-full h-full flex items-center justify-center"
        >
          <Model3DViewer asset={active} />
        </div>
      );
    }
    if (active.mediaKind === 'document') {
      const isPdf = active.mimeType === 'application/pdf' || /\.pdf$/i.test(active.fileName);
      return (
        <div
          onClick={(e) => e.stopPropagation()}
          className="w-full h-full flex items-center justify-center"
        >
          {isPdf ? <PdfDocumentViewer asset={active} /> : <DocumentMarkdownViewer asset={active} />}
        </div>
      );
    }
    return (
      <ImageStageViewer
        asset={active}
        zoom={zoom}
        onZoomChange={(next) => {
          setLongStripMode(false);
          setZoom(next);
        }}
        maxZoomLimit={maxZoomLimit}
        rotationDegrees={rotationDegrees}
        flipHorizontal={flipHorizontal}
        flipVertical={flipVertical}
        longStripMode={longStripMode}
        pausedAnim={pausedAnim}
        onToggleAnimPauseReady={(fn) => {
          freezeAnimRef.current = fn;
        }}
      />
    );
  };

  return createPortal(
    <AnimatePresence>
      {asset && (
        <m.div
          key="quicklook-session"
          role="dialog"
          aria-modal="true"
          aria-label={`快速预览：${asset.title}`}
          data-testid="quicklook-overlay"
          initial={{ opacity: 0 }}
          animate={{ opacity: 1, transition: WIN_TRANSITION_FAST }}
          exit={{ opacity: 0, transition: WIN_TRANSITION_EXIT }}
          className="fixed inset-0 z-[130] flex overflow-hidden"
        >
          {/* Left Hero Ambient Stage (Smoke scrim + subtle radial ambient tint, pure composited layer) */}
          <div
            onClick={closeQuickLook}
            style={{
              backgroundColor: isDark ? 'rgba(10, 11, 14, 0.86)' : 'rgba(18, 20, 24, 0.78)',
              ...computeAmbientTintStyle(asset.dominantColors[0]?.hex, true, 'quicklook'),
            }}
            className="win-smoke-scrim relative flex-1 min-w-0 h-full flex flex-col"
          >
            {/* Top Minimal Header Bar */}
            <header
              onClick={(e) => e.stopPropagation()}
              className="shrink-0 px-6 pt-4 pb-2 flex items-center justify-between gap-3 z-20"
            >
              <div className="flex items-center gap-2.5 min-w-0">
                {asset.richMetadata?.socialPost?.platform === 'xiaohongshu' && (
                  <span className="px-2 py-0.5 rounded-[var(--win-radius-control)] bg-[#FF2442] text-white text-[10.5px] font-semibold shrink-0">
                    小红书
                  </span>
                )}
                <h2 className="text-[14px] font-semibold text-white/95 truncate">{asset.title}</h2>
                <span className="text-[11.5px] charkle-mono text-white/62 charkle-tabular shrink-0">
                  {asset.pixelWidth > 0 && asset.pixelHeight > 0
                    ? `${asset.pixelWidth} × ${asset.pixelHeight} · `
                    : ''}
                  {asset.richMetadata?.socialPost?.platform === 'xiaohongshu'
                    ? '小红书笔记'
                    : asset.richMetadata?.githubRepo
                      ? 'GitHub 仓库'
                      : mediaKindLabel(asset.mediaKind)}
                  {canStep ? ` · ${activeIndex + 1} / ${assets.length}` : ''}
                </span>
              </div>

              <div className="flex items-center gap-1.5 shrink-0">
                <Tooltip content="显示 / 隐藏右侧详情栏" shortcut="Ctrl+I">
                  <button
                    type="button"
                    onClick={toggleInspector}
                    aria-label={inspectorOpen ? '隐藏右侧详情栏' : '显示右侧详情栏'}
                    className={[
                      'charkle-pressable win-acrylic-dark w-8 h-8 rounded-[var(--win-radius-control)] inline-flex items-center justify-center cursor-pointer',
                      inspectorOpen ? 'text-[var(--accent)]' : 'text-white/85 hover:text-white',
                    ].join(' ')}
                  >
                    {inspectorOpen ? (
                      <PanelRight16Filled className="w-4 h-4" />
                    ) : (
                      <PanelRight16Regular className="w-4 h-4" />
                    )}
                  </button>
                </Tooltip>

                <Tooltip content="关闭预览" shortcut="Space / Esc">
                  <button
                    type="button"
                    aria-label="关闭快速预览"
                    onClick={closeQuickLook}
                    className="charkle-pressable win-acrylic-dark w-8 h-8 rounded-[var(--win-radius-control)] inline-flex items-center justify-center text-white/85 hover:text-white cursor-pointer"
                  >
                    <Dismiss16Regular className="w-4 h-4" />
                  </button>
                </Tooltip>
              </div>
            </header>

            {/* Center Media Stage with Shared-Element FLIP Connected Animation */}
            <div
              className={[
                'relative flex-1 min-h-0 flex items-center justify-center overflow-hidden',
                inspectorOpen ? 'px-7' : 'px-12',
              ].join(' ')}
            >
              <m.div
                data-testid="quicklook-flip-stage"
                variants={stageVariants}
                initial="enter"
                animate="center"
                exit="exit"
                className="w-full h-full flex items-center justify-center will-change-transform"
              >
                {renderMediaStage(asset)}
              </m.div>

              {canStep && (
                <>
                  <Tooltip content="上一项素材" shortcut="←">
                    <button
                      type="button"
                      aria-label="上一项素材"
                      onClick={(e) => {
                        e.stopPropagation();
                        stepPlaylist(-1);
                      }}
                      className="charkle-pressable win-acrylic-dark absolute left-4 top-1/2 -translate-y-1/2 z-20 h-9 w-9 rounded-[var(--win-radius-overlay)] inline-flex items-center justify-center text-white/88 hover:text-white cursor-pointer"
                    >
                      <ChevronLeft20Regular className="w-5 h-5" />
                    </button>
                  </Tooltip>

                  <Tooltip content="下一项素材" shortcut="→">
                    <button
                      type="button"
                      aria-label="下一项素材"
                      onClick={(e) => {
                        e.stopPropagation();
                        stepPlaylist(1);
                      }}
                      className="charkle-pressable win-acrylic-dark absolute right-4 top-1/2 -translate-y-1/2 z-20 h-9 w-9 rounded-[var(--win-radius-overlay)] inline-flex items-center justify-center text-white/88 hover:text-white cursor-pointer"
                    >
                      <ChevronRight20Regular className="w-5 h-5" />
                    </button>
                  </Tooltip>
                </>
              )}
            </div>

            {/* Floating Fluent 2 Dark Acrylic Bottom HUD */}
            <div
              onClick={(e) => e.stopPropagation()}
              className="shrink-0 pb-5 pt-2 flex justify-center z-20 px-4"
            >
              <div className="win-acrylic-dark rounded-[var(--win-radius-overlay)] px-2.5 py-1.5 flex items-center gap-1.5 flex-wrap justify-center">
                {supportsVisualTransform && (
                  <>
                    {isTallStrip && (
                      <>
                        <button
                          type="button"
                          onClick={() => {
                            setLongStripMode((v) => !v);
                            setZoom(1);
                          }}
                          title="切换长图按宽滚动阅读 / 适应窗口缩放查看"
                          className={[
                            'charkle-pressable h-7 px-2.5 rounded-[var(--win-radius-control)] inline-flex items-center gap-1.5 text-[11.5px] font-medium cursor-pointer',
                            longStripMode
                              ? 'bg-[var(--accent)] text-[var(--accent-text)]'
                              : 'bg-white/10 text-white/90 hover:bg-white/16',
                          ].join(' ')}
                        >
                          {longStripMode ? (
                            <DocumentBulletList16Regular className="w-3.5 h-3.5" />
                          ) : (
                            <ScaleFit16Regular className="w-3.5 h-3.5" />
                          )}
                          <span>{longStripMode ? '长图滚动' : '适应窗口'}</span>
                        </button>
                        <span className="w-px h-4 bg-white/15" />
                      </>
                    )}

                    <div className="flex items-center gap-0.5">
                      <button
                        type="button"
                        aria-label="缩小"
                        title="缩小 (-)"
                        onClick={() => {
                          setLongStripMode(false);
                          setZoom((z) => Math.max(0.5, Number((z * 0.8).toFixed(2))));
                        }}
                        className="charkle-pressable w-7 h-7 rounded-[var(--win-radius-control)] inline-flex items-center justify-center text-white/88 hover:bg-white/12 cursor-pointer"
                      >
                        <ZoomOut16Regular className="w-4 h-4" />
                      </button>
                      <span className="min-w-[42px] text-center text-[11.5px] charkle-mono font-semibold text-white/90 charkle-tabular">
                        {Math.round(zoom * 100)}%
                      </span>
                      <button
                        type="button"
                        aria-label="放大"
                        title="放大 (+)"
                        onClick={() => {
                          setLongStripMode(false);
                          setZoom((z) => Math.min(maxZoomLimit, Number((z * 1.25).toFixed(2))));
                        }}
                        className="charkle-pressable w-7 h-7 rounded-[var(--win-radius-control)] inline-flex items-center justify-center text-white/88 hover:bg-white/12 cursor-pointer"
                      >
                        <ZoomIn16Regular className="w-4 h-4" />
                      </button>
                      <button
                        type="button"
                        aria-label="重置缩放与变换"
                        title="重置缩放与变换 (0)"
                        onClick={() => resetTransforms(true)}
                        className="charkle-pressable h-7 px-1.5 rounded-[var(--win-radius-control)] inline-flex items-center justify-center text-[11px] charkle-mono text-white/80 hover:bg-white/12 cursor-pointer"
                      >
                        1:1
                      </button>
                    </div>

                    <span className="w-px h-4 bg-white/15" />

                    <div className="flex items-center gap-0.5">
                      <button
                        type="button"
                        title="逆时针旋转 90° (Shift+R)"
                        aria-label="逆时针旋转"
                        onClick={() => rotateBy(-90)}
                        className="charkle-pressable w-7 h-7 rounded-[var(--win-radius-control)] inline-flex items-center justify-center text-white/88 hover:bg-white/12 cursor-pointer"
                      >
                        <ArrowCounterclockwise16Regular className="w-4 h-4" />
                      </button>
                      <button
                        type="button"
                        title="顺时针旋转 90° (R)"
                        aria-label="顺时针旋转"
                        onClick={() => rotateBy(90)}
                        className="charkle-pressable w-7 h-7 rounded-[var(--win-radius-control)] inline-flex items-center justify-center text-white/88 hover:bg-white/12 cursor-pointer"
                      >
                        <ArrowClockwise16Regular className="w-4 h-4" />
                      </button>
                      <button
                        type="button"
                        title="水平翻转 (Shift+H)"
                        aria-label="水平翻转"
                        onClick={() => {
                          setLongStripMode(false);
                          setFlipHorizontal((v) => !v);
                        }}
                        className={[
                          'charkle-pressable w-7 h-7 rounded-[var(--win-radius-control)] inline-flex items-center justify-center cursor-pointer',
                          flipHorizontal
                            ? 'bg-[var(--accent)] text-[var(--accent-text)]'
                            : 'text-white/88 hover:bg-white/12',
                        ].join(' ')}
                      >
                        <FlipHorizontal16Regular className="w-4 h-4" />
                      </button>
                      <button
                        type="button"
                        title="上下翻转 (Shift+V)"
                        aria-label="上下翻转"
                        onClick={() => {
                          setLongStripMode(false);
                          setFlipVertical((v) => !v);
                        }}
                        className={[
                          'charkle-pressable w-7 h-7 rounded-[var(--win-radius-control)] inline-flex items-center justify-center cursor-pointer',
                          flipVertical
                            ? 'bg-[var(--accent)] text-[var(--accent-text)]'
                            : 'text-white/88 hover:bg-white/12',
                        ].join(' ')}
                      >
                        <FlipVertical16Regular className="w-4 h-4" />
                      </button>
                      {hasActiveTransform && (
                        <button
                          type="button"
                          title="还原旋转与翻转"
                          onClick={() => resetTransforms(false)}
                          className="charkle-pressable ml-0.5 h-6 px-2 rounded-[var(--win-radius-control)] bg-[var(--accent)] text-[var(--accent-text)] text-[11px] charkle-mono inline-flex items-center gap-1 cursor-pointer"
                        >
                          {normalizedRot !== 0 && <span>{normalizedRot}°</span>}
                          <ArrowCounterclockwise16Regular className="w-3 h-3" />
                        </button>
                      )}
                    </div>

                    {asset.mediaKind === 'animatedImage' && (
                      <>
                        <span className="w-px h-4 bg-white/15" />
                        <button
                          type="button"
                          onClick={() => {
                            if (!pausedAnim) freezeAnimRef.current?.();
                            setPausedAnim((v) => !v);
                          }}
                          className="charkle-pressable h-7 px-2.5 rounded-[var(--win-radius-control)] bg-white/10 hover:bg-white/18 text-white text-[11.5px] inline-flex items-center gap-1 cursor-pointer"
                        >
                          {pausedAnim ? (
                            <Play16Filled className="w-3.5 h-3.5" />
                          ) : (
                            <Pause16Regular className="w-3.5 h-3.5" />
                          )}
                          <span>{pausedAnim ? '播放' : '暂停'}</span>
                        </button>
                      </>
                    )}

                    <span className="w-px h-4 bg-white/15" />
                  </>
                )}

                {/* Rating Stars */}
                <div className="flex items-center gap-0.5">
                  {[1, 2, 3, 4, 5].map((star) => {
                    const filled = asset.rating >= star;
                    const isPeak = asset.rating === star;
                    return (
                      <button
                        key={star}
                        type="button"
                        aria-label={`评为 ${star} 星`}
                        onClick={() =>
                          void updateAssets(
                            { assetIDs: [asset.id], rating: asset.rating === star ? 0 : star },
                            destination,
                          )
                        }
                        className={[
                          'charkle-pressable w-6 h-6 rounded-[var(--win-radius-control)] inline-flex items-center justify-center hover:bg-white/10 cursor-pointer',
                          filled ? 'text-[#F2C14E]' : 'text-white/45 hover:text-white/85',
                          isPeak ? 'charkle-micro-pop' : '',
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

                <span className="w-px h-4 bg-white/15" />

                {asset.isTrashed ? (
                  <>
                    <button
                      type="button"
                      onClick={() => {
                        const id = asset.id;
                        void updateAssets({ assetIDs: [id], isTrashed: false }, destination).then(
                          () => pushToast({ message: '已放回原处', tone: 'success' }),
                        );
                      }}
                      className="charkle-pressable h-7 px-2.5 rounded-[var(--win-radius-control)] hover:bg-white/12 text-white text-[12px] font-medium inline-flex items-center gap-1.5 cursor-pointer"
                    >
                      <ArrowUndo16Regular className="w-3.5 h-3.5" />
                      放回原处
                    </button>
                    <button
                      type="button"
                      onClick={() => setConfirmDeleteOpen(true)}
                      className="charkle-pressable h-7 px-2.5 rounded-[var(--win-radius-control)] hover:bg-red-500/20 text-[#FF6B6B] text-[12px] font-medium inline-flex items-center gap-1.5 cursor-pointer"
                    >
                      <Delete16Regular className="w-3.5 h-3.5" />
                      彻底删除
                    </button>
                  </>
                ) : (
                  <>
                    <button
                      type="button"
                      aria-label={asset.pinnedOffline ? '取消始终保留在本地' : '始终保留在本地'}
                      title={asset.pinnedOffline ? '取消始终保留在本地' : '始终保留在本地'}
                      onClick={() => {
                        const nextPinned = !asset.pinnedOffline;
                        void updateAssets(
                          { assetIDs: [asset.id], pinnedOffline: nextPinned },
                          destination,
                        ).then(() =>
                          pushToast({
                            message: nextPinned ? '已设为始终保留在本地' : '已取消始终保留在本地',
                            tone: 'info',
                          }),
                        );
                      }}
                      className={[
                        'charkle-pressable w-7 h-7 rounded-[var(--win-radius-control)] inline-flex items-center justify-center cursor-pointer',
                        asset.pinnedOffline
                          ? 'bg-[var(--accent-soft)] text-[var(--accent)]'
                          : 'text-white/85 hover:bg-white/12',
                      ].join(' ')}
                    >
                      <ArrowDownload16Regular className="w-4 h-4" />
                    </button>

                    <button
                      ref={boardBtnRef}
                      type="button"
                      aria-label="加入情绪板"
                      title="加入情绪板"
                      onClick={() => setBoardMenuOpen((v) => !v)}
                      className="charkle-pressable w-7 h-7 rounded-[var(--win-radius-control)] inline-flex items-center justify-center text-white/85 hover:bg-white/12 cursor-pointer"
                    >
                      <Board16Regular className="w-4 h-4" />
                    </button>

                    <button
                      type="button"
                      aria-label="在资源管理器中显示"
                      title="在资源管理器中显示"
                      onClick={() =>
                        void transport.revealInExplorer(asset.id).catch(() => {
                          pushToast({ message: '无法定位本地文件', tone: 'error' });
                        })
                      }
                      className="charkle-pressable w-7 h-7 rounded-[var(--win-radius-control)] inline-flex items-center justify-center text-white/85 hover:bg-white/12 cursor-pointer"
                    >
                      <FolderOpen16Regular className="w-4 h-4" />
                    </button>

                    <button
                      type="button"
                      aria-label="拷贝文件"
                      title="拷贝文件"
                      onClick={() =>
                        void transport
                          .copyAssetsToClipboard([asset.id])
                          .then(() => pushToast({ message: '已拷贝到剪贴板', tone: 'success' }))
                          .catch((err) =>
                            pushToast({
                              message: err instanceof Error ? err.message : '无法拷贝文件',
                              tone: 'error',
                            }),
                          )
                      }
                      className="charkle-pressable w-7 h-7 rounded-[var(--win-radius-control)] inline-flex items-center justify-center text-white/85 hover:bg-white/12 cursor-pointer"
                    >
                      <Copy16Regular className="w-4 h-4" />
                    </button>

                    {asset.sourceURL && (
                      <button
                        type="button"
                        aria-label="打开来源网页"
                        title="打开来源网页"
                        onClick={() =>
                          void transport.openExternalUrl(asset.sourceURL!).catch(() => {
                            pushToast({ message: '无法在默认浏览器中打开链接', tone: 'error' });
                          })
                        }
                        className="charkle-pressable w-7 h-7 rounded-[var(--win-radius-control)] inline-flex items-center justify-center text-white/85 hover:bg-white/12 cursor-pointer"
                      >
                        <Open16Regular className="w-4 h-4" />
                      </button>
                    )}

                    <button
                      type="button"
                      title="移至回收站"
                      aria-label="移至回收站"
                      onClick={() => {
                        const id = asset.id;
                        void updateAssets({ assetIDs: [id], isTrashed: true }, destination, {
                          undoMessage: '已移至回收站',
                          undoPatch: { assetIDs: [id], isTrashed: false },
                        });
                      }}
                      className="charkle-pressable w-7 h-7 rounded-[var(--win-radius-control)] inline-flex items-center justify-center text-white/85 hover:bg-red-500/20 hover:text-[#FF6B6B] cursor-pointer"
                    >
                      <Delete16Regular className="w-4 h-4" />
                    </button>
                  </>
                )}
              </div>
            </div>

            {/* Add to Moodboard Popover (z-[170] above Quick Look z-[130]) */}
            <Popover
              open={boardMenuOpen}
              onOpenChange={setBoardMenuOpen}
              anchorEl={boardBtnRef.current}
              placement="top-center"
              className="!z-[170] w-[220px] p-1"
            >
              <div className="flex flex-col gap-0.5 text-[13px] leading-[18px]">
                {boards.length === 0 ? (
                  <div className="px-2.5 py-1.5 text-[12px] text-[var(--text-tertiary)]">
                    暂无情绪板
                  </div>
                ) : (
                  boards.map((b) => (
                    <button
                      key={b.id}
                      type="button"
                      onClick={() => {
                        setBoardMenuOpen(false);
                        void addAssetsToBoard(b.id, [asset.id]);
                      }}
                      className="charkle-pressable w-full min-h-[32px] text-left px-2.5 py-1.5 rounded-[var(--win-radius-control)] text-[var(--text-primary)] hover:bg-[var(--win-subtle-hover)] truncate cursor-pointer"
                    >
                      {b.title}
                    </button>
                  ))
                )}
                <div className="my-1 mx-2 h-px bg-[var(--win-stroke-divider)]" />
                <button
                  type="button"
                  onClick={() => {
                    setBoardMenuOpen(false);
                    setSelection([asset.id], asset.id);
                    closeQuickLook();
                    openMoodboardGenerator('seedAssets');
                  }}
                  className="charkle-pressable w-full min-h-[32px] text-left px-2.5 py-1.5 rounded-[var(--win-radius-control)] text-[var(--accent)] font-medium hover:bg-[var(--accent-soft)] cursor-pointer"
                >
                  以此图快速生成新情绪板…
                </button>
              </div>
            </Popover>
          </div>

          {/* Synchronized Full-Height Draggable Right Inspector (1:1 synced with Main Workspace) */}
          {inspectorOpen && (
            <PaneResizeDivider
              mode="inspector"
              currentWidth={effectiveInspectorWidth}
              minWidth={MIN_INSPECTOR_WIDTH}
              maxWidth={MAX_INSPECTOR_WIDTH}
              defaultWidth={DEFAULT_INSPECTOR_WIDTH}
              label="调整预览检查器宽度"
              testId="quicklook-inspector-resize-divider"
              onResizeStart={() => setResizingPane('inspector')}
              onResize={(next) => {
                setInspectorWidth(clampInspectorWidth(next, windowWidth, 0));
              }}
              onResizeEnd={(finalWidth) => {
                setResizingPane(null);
                commitInspectorWidth(clampInspectorWidth(finalWidth, windowWidth, 0));
              }}
              onReset={resetInspectorWidth}
            />
          )}

          <div
            aria-hidden={!inspectorOpen}
            data-testid="quicklook-inspector-slot"
            style={{ width: inspectorOpen ? effectiveInspectorWidth : 0 }}
            className={[
              'charkle-drawer-slot shrink-0 min-h-0 h-full overflow-hidden flex justify-start',
              inspectorOpen ? '' : 'pointer-events-none',
            ].join(' ')}
          >
            <div
              className="win-drawer-content h-full shrink-0"
              style={{
                width: effectiveInspectorWidth,
                opacity: inspectorOpen ? 1 : 0,
                transform: inspectorOpen ? 'translateX(0)' : 'translateX(16px)',
                transition: isResizingPane === 'inspector' ? 'none' : undefined,
              }}
            >
              <InspectorView
                pinnedAsset={asset}
                isQuickLookHosted
                onRequestCloseQuickLook={closeQuickLook}
              />
            </div>
          </div>

          {/* Permanent Delete Confirm Dialog at z-[180] (above Quick Look z-[130]) */}
          {confirmDeleteOpen && (
            <div
              role="dialog"
              aria-modal="true"
              aria-label="彻底删除此素材"
              data-quicklook-delete-open="true"
              onMouseDown={(e) => e.stopPropagation()}
              onPointerDown={(e) => e.stopPropagation()}
              onClick={(e) => e.stopPropagation()}
              className="fixed inset-0 z-[180] flex items-center justify-center p-4"
            >
              <div
                className="win-smoke-scrim fixed inset-0"
                onClick={() => setConfirmDeleteOpen(false)}
              />
              <div className="win-dialog-popup relative z-10 w-full max-w-[380px] rounded-[var(--win-radius-dialog)] bg-[var(--bg-elevated)] border border-[var(--win-stroke-flyout)] shadow-[var(--shadow-modal)] overflow-hidden flex flex-col">
                <div className="p-5 flex flex-col gap-2">
                  <div className="text-[16px] font-semibold text-[var(--text-primary)]">
                    彻底删除此素材？
                  </div>
                  <p className="text-[13px] text-[var(--text-secondary)]">彻底删除后将无法恢复。</p>
                </div>
                <div className="px-5 py-3.5 bg-[var(--bg-subtle)]/55 border-t border-[var(--win-stroke-divider)] flex items-center justify-end gap-2">
                  <Button
                    variant="standard"
                    size="sm"
                    onClick={() => setConfirmDeleteOpen(false)}
                  >
                    取消
                  </Button>
                  <Button
                    variant="danger"
                    size="sm"
                    onClick={async () => {
                      const id = asset.id;
                      setConfirmDeleteOpen(false);
                      await permanentlyDeleteAssets([id], destination);
                    }}
                  >
                    彻底删除
                  </Button>
                </div>
              </div>
            </div>
          )}
        </m.div>
      )}
    </AnimatePresence>,
    document.body,
  );
};
