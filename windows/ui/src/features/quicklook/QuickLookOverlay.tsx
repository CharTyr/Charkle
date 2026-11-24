import React, { useEffect, useMemo, useRef, useState } from 'react';
import { createPortal } from 'react-dom';
import {
  ArrowDownCircle,
  ChevronLeft,
  ChevronRight,
  Copy,
  ExternalLink,
  Film,
  FlipHorizontal2,
  FlipVertical2,
  FolderOpen,
  LayoutGrid,
  Minimize2,
  PanelRight,
  Pause,
  Play,
  RotateCcw,
  RotateCw,
  ScrollText,
  Star,
  Trash2,
  X,
  ZoomIn,
  ZoomOut,
} from 'lucide-react';
import { getTransport } from '../../api/transport';
import {
  Button,
  Popover,
  computeAmbientTintStyle,
  isLongStripImage,
  useResolvedIsDark,
} from '../../design-system';
import { useCoordinatorStore, useLibraryStore, useMoodboardStore } from '../../stores';
import { mediaKindLabel, type AssetRecord } from '../../types/domain';
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
        className="max-w-[440px] mx-auto p-6 rounded-[16px] bg-[var(--bg-elevated)] border border-[var(--border-hairline)] text-center flex flex-col items-center gap-3 shadow-2xl"
      >
        <Film size={28} className="text-[var(--text-tertiary)]" />
        <div className="text-[14px] font-semibold text-[var(--text-primary)]">{asset.title}</div>
        <p className="text-[12px] text-[var(--text-secondary)]">
          当前视频编码或文件暂无法内嵌播放，可在资源管理器中使用系统播放器打开。
        </p>
        <Button
          variant="primary"
          size="sm"
          onClick={() => void getTransport().revealInExplorer(asset.id)}
        >
          <FolderOpen size={13} />
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
      className="max-w-[82vw] max-h-[74vh] rounded-[16px] shadow-[0_24px_60px_rgba(0,0,0,0.48)] bg-black"
    />
  );
};

/**
 * Full-Media Spacebar Quick Look Overlay 1:1 faithful to macOS `QuickLookOverlayView.swift`:
 * - Instant, zero-sluggishness keyboard toggle (Space / Esc / Arrows / R / Shift+H/V / 0 / +/-)
 * - Soft dark neutral ambient backdrop + minimal top metadata bar
 * - Full-height 300px synchronized Right Inspector (`InspectorView`, identical cards & tabs)
 * - Floating Dark Liquid Glass bottom HUD + all 7 media viewers + webBookmark & swatch cards
 */
export const QuickLookOverlay: React.FC = () => {
  const quickLookAssetId = useCoordinatorStore((s) => s.quickLookAssetId);
  const openQuickLook = useCoordinatorStore((s) => s.openQuickLook);
  const closeQuickLook = useCoordinatorStore((s) => s.closeQuickLook);
  const setSelection = useCoordinatorStore((s) => s.setSelection);
  const destination = useCoordinatorStore((s) => s.destination);
  const inspectorOpen = useCoordinatorStore((s) => s.inspectorOpen);
  const toggleInspector = useCoordinatorStore((s) => s.toggleInspector);
  const openMoodboardGenerator = useCoordinatorStore((s) => s.openMoodboardGenerator);
  const pushToast = useCoordinatorStore((s) => s.pushToast);

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

  const activeIndex = useMemo(() => {
    if (!quickLookAssetId) return -1;
    return assets.findIndex((a) => a.id === quickLookAssetId);
  }, [assets, quickLookAssetId]);

  const asset: AssetRecord | null = useMemo(() => {
    if (!quickLookAssetId) return null;
    if (activeIndex >= 0) return assets[activeIndex];
    return allAssets.find((a) => a.id === quickLookAssetId) ?? null;
  }, [quickLookAssetId, activeIndex, assets, allAssets]);

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

  // Resign stale underlying text/button focus immediately upon entering Quick Look (Pitfall 4)
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

      // Respect active text editing inside docked Inspector; Escape blurs field first (1:1 macOS)
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

  if (!asset || typeof document === 'undefined') return null;

  const transport = getTransport();
  const canStep = assets.length > 1 && activeIndex >= 0;
  const ambientStyle = computeAmbientTintStyle(asset.dominantColors[0]?.hex, true, 'quicklook');

  const renderWebBookmarkCard = () => {
    const dotHex = asset.dominantColors[0]?.hex ?? '#5C6B73';
    const domain = formatQuickLookBookmarkDomain(asset);
    const previewUrl = withQuickLookThumbCacheBust(
      transport.thumbnailUrl(asset.id, 'preview1400'),
      asset.updatedAt,
    );
    return (
      <div
        onClick={(e) => e.stopPropagation()}
        className="w-full max-w-[680px] p-5 rounded-[18px] bg-[var(--bg-elevated)] border border-[var(--border-hairline)] shadow-[0_24px_60px_rgba(0,0,0,0.42)] flex flex-col gap-3.5"
      >
        <div className="flex items-center justify-between gap-3">
          <div className="flex items-center gap-2.5 min-w-0">
            <span
              className="w-3 h-3 rounded-full shrink-0"
              style={{ backgroundColor: dotHex }}
            />
            <span className="text-[13px] font-semibold charkle-mono text-[var(--text-secondary)] truncate">
              {asset.sourceDomain ?? domain}
            </span>
          </div>
          {asset.sourceURL && (
            <Button
              variant="primary"
              size="xs"
              onClick={() =>
                void transport
                  .openExternalUrl(asset.sourceURL!)
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
              <ExternalLink size={12} />
              在默认浏览器中打开
            </Button>
          )}
        </div>

        <div className="w-full max-h-[380px] rounded-[12px] overflow-hidden border border-[var(--border-hairline)] bg-[var(--bg-subtle)]/40 flex items-center justify-center">
          <img
            src={previewUrl}
            alt={asset.title}
            draggable={false}
            className="w-full max-h-[380px] object-contain"
          />
        </div>

        <h3 className="text-[19px] font-semibold text-[var(--text-primary)] charkle-heading">
          {asset.title}
        </h3>

        {asset.sourceURL && (
          <p className="text-[12px] charkle-mono text-[var(--text-secondary)] select-text break-all">
            {asset.sourceURL}
          </p>
        )}

        {asset.notes && (
          <>
            <div className="h-px bg-[var(--border-hairline)]" />
            <p className="text-[13px] leading-relaxed text-[var(--text-primary)] whitespace-pre-wrap select-text">
              {asset.notes}
            </p>
          </>
        )}
      </div>
    );
  };

  const renderSwatchCard = () => {
    const hex = (asset.dominantColors[0]?.hex ?? '#2A60E0').toUpperCase();
    return (
      <div
        onClick={(e) => e.stopPropagation()}
        className="w-[380px] rounded-[20px] overflow-hidden bg-[var(--bg-elevated)] border border-[var(--border-hairline)] shadow-[0_24px_60px_rgba(0,0,0,0.45)] flex flex-col"
      >
        <div className="h-[260px] w-full" style={{ backgroundColor: hex }} />
        <div className="p-5 flex items-center justify-between gap-3">
          <div className="min-w-0">
            <div className="text-[16px] font-semibold text-[var(--text-primary)] truncate">
              {asset.title}
            </div>
            <div className="text-[13px] charkle-mono text-[var(--text-secondary)] mt-0.5">
              {hex}
            </div>
          </div>
          <Button
            variant="secondary"
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
            <Copy size={12} />
            复制 HEX
          </Button>
        </div>
      </div>
    );
  };

  const renderMediaStage = () => {
    if (asset.richMetadata?.githubRepo) {
      return (
        <div
          onClick={(e) => e.stopPropagation()}
          className="w-full h-full flex items-center justify-center"
        >
          <GitHubRepoViewer asset={asset} />
        </div>
      );
    }
    if (asset.richMetadata?.socialPost) {
      return (
        <div
          onClick={(e) => e.stopPropagation()}
          className="w-full h-full flex items-center justify-center"
        >
          <SocialPostViewer asset={asset} />
        </div>
      );
    }
    if (isSwatchAsset) {
      return renderSwatchCard();
    }
    if (asset.mediaKind === 'webBookmark') {
      return renderWebBookmarkCard();
    }
    if (asset.mediaKind === 'video') {
      return (
        <QuickLookVideoStage
          key={asset.id}
          asset={asset}
          src={transport.originalUrl(asset.id)}
          poster={transport.thumbnailUrl(asset.id, 'preview1400')}
        />
      );
    }
    if (asset.mediaKind === 'audio') {
      return (
        <div onClick={(e) => e.stopPropagation()} className="w-full flex justify-center">
          <AudioStudioViewer asset={asset} />
        </div>
      );
    }
    if (asset.mediaKind === 'model3D') {
      return (
        <div
          onClick={(e) => e.stopPropagation()}
          className="w-full h-full flex items-center justify-center"
        >
          <Model3DViewer asset={asset} />
        </div>
      );
    }
    if (asset.mediaKind === 'document') {
      const isPdf = asset.mimeType === 'application/pdf' || /\.pdf$/i.test(asset.fileName);
      return (
        <div
          onClick={(e) => e.stopPropagation()}
          className="w-full h-full flex items-center justify-center"
        >
          {isPdf ? <PdfDocumentViewer asset={asset} /> : <DocumentMarkdownViewer asset={asset} />}
        </div>
      );
    }
    return (
      <ImageStageViewer
        asset={asset}
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
    <div
      role="dialog"
      aria-modal="true"
      aria-label={`快速预览：${asset.title}`}
      data-testid="quicklook-overlay"
      className="fixed inset-0 z-[130] flex overflow-hidden"
    >
      {/* Left Hero Ambient Stage */}
      <div
        onClick={closeQuickLook}
        style={{
          backgroundColor: isDark ? 'rgba(0, 0, 0, 0.80)' : 'rgba(21, 22, 25, 0.74)',
          ...ambientStyle,
        }}
        className="relative flex-1 min-w-0 h-full flex flex-col backdrop-blur-[16px]"
      >
        {/* Top Minimal Header Bar */}
        <header
          onClick={(e) => e.stopPropagation()}
          className="shrink-0 px-6 pt-4 pb-2 flex items-center justify-between gap-3 z-20"
        >
          <div className="flex items-center gap-2.5 min-w-0">
            {asset.richMetadata?.socialPost?.platform === 'xiaohongshu' && (
              <span className="px-2 py-0.5 rounded-full bg-[#FF2442] text-white text-[10.5px] font-semibold shrink-0">
                小红书
              </span>
            )}
            <h2 className="text-[13.5px] font-semibold text-white/95 truncate">{asset.title}</h2>
            <span className="text-[11px] charkle-mono text-white/62 charkle-tabular shrink-0">
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

          <div className="flex items-center gap-2 shrink-0">
            <button
              type="button"
              onClick={toggleInspector}
              aria-label={inspectorOpen ? '隐藏右侧详情栏' : '显示右侧详情栏'}
              title="显示 / 隐藏右侧详情栏 (Ctrl+I)"
              className={[
                'charkle-pressable charkle-glass-dark w-7 h-7 rounded-full inline-flex items-center justify-center cursor-pointer',
                inspectorOpen ? 'text-[#5B8DEF]' : 'text-white/85 hover:text-white',
              ].join(' ')}
            >
              <PanelRight size={13.5} />
            </button>

            <button
              type="button"
              aria-label="关闭快速预览"
              title="关闭预览 (Space / Esc)"
              onClick={closeQuickLook}
              className="charkle-pressable charkle-glass-dark w-7 h-7 rounded-full inline-flex items-center justify-center text-white/85 hover:text-white cursor-pointer"
            >
              <X size={13.5} />
            </button>
          </div>
        </header>

        {/* Center Media Stage */}
        <div
          className={[
            'relative flex-1 min-h-0 flex items-center justify-center overflow-hidden',
            inspectorOpen ? 'px-7' : 'px-12',
          ].join(' ')}
        >
          {renderMediaStage()}

          {canStep && (
            <>
              <button
                type="button"
                aria-label="上一项素材"
                onClick={(e) => {
                  e.stopPropagation();
                  stepPlaylist(-1);
                }}
                className="charkle-pressable charkle-glass-dark absolute left-4 top-1/2 -translate-y-1/2 z-20 h-9 w-9 rounded-full inline-flex items-center justify-center text-white/88 hover:text-white cursor-pointer"
              >
                <ChevronLeft size={18} />
              </button>

              <button
                type="button"
                aria-label="下一项素材"
                onClick={(e) => {
                  e.stopPropagation();
                  stepPlaylist(1);
                }}
                className="charkle-pressable charkle-glass-dark absolute right-4 top-1/2 -translate-y-1/2 z-20 h-9 w-9 rounded-full inline-flex items-center justify-center text-white/88 hover:text-white cursor-pointer"
              >
                <ChevronRight size={18} />
              </button>
            </>
          )}
        </div>

        {/* Floating Dark Liquid Glass Bottom HUD (1:1 macOS floatingBottomHUD) */}
        <div
          onClick={(e) => e.stopPropagation()}
          className="shrink-0 pb-5 pt-2 flex justify-center z-20 px-4"
        >
          <div className="charkle-glass-dark rounded-full px-3.5 py-1.5 flex items-center gap-2 flex-wrap justify-center">
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
                        'charkle-pressable h-7 px-2.5 rounded-full inline-flex items-center gap-1 text-[11px] font-semibold cursor-pointer',
                        longStripMode
                          ? 'bg-[#3B82F6]/80 text-white'
                          : 'bg-white/14 text-white/90 hover:bg-white/20',
                      ].join(' ')}
                    >
                      {longStripMode ? <ScrollText size={11.5} /> : <Minimize2 size={11.5} />}
                      <span>{longStripMode ? '长图滚动' : '适应窗口'}</span>
                    </button>
                    <span className="w-px h-4 bg-white/15" />
                  </>
                )}

                <div className="flex items-center gap-1">
                  <button
                    type="button"
                    aria-label="缩小"
                    title="缩小 (-)"
                    onClick={() => {
                      setLongStripMode(false);
                      setZoom((z) => Math.max(0.5, Number((z * 0.8).toFixed(2))));
                    }}
                    className="charkle-pressable w-7 h-7 rounded-full inline-flex items-center justify-center text-white/88 hover:bg-white/12 cursor-pointer"
                  >
                    <ZoomOut size={13.5} />
                  </button>
                  <span className="min-w-[40px] text-center text-[11px] charkle-mono font-semibold text-white/90 charkle-tabular">
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
                    className="charkle-pressable w-7 h-7 rounded-full inline-flex items-center justify-center text-white/88 hover:bg-white/12 cursor-pointer"
                  >
                    <ZoomIn size={13.5} />
                  </button>
                  <button
                    type="button"
                    aria-label="重置缩放与变换"
                    title="重置缩放与变换 (0)"
                    onClick={() => resetTransforms(true)}
                    className="charkle-pressable h-7 px-1.5 rounded-full inline-flex items-center justify-center text-[10.5px] charkle-mono text-white/78 hover:bg-white/12 cursor-pointer"
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
                    className="charkle-pressable w-7 h-7 rounded-full inline-flex items-center justify-center text-white/88 hover:bg-white/12 cursor-pointer"
                  >
                    <RotateCcw size={13.5} />
                  </button>
                  <button
                    type="button"
                    title="顺时针旋转 90° (R)"
                    aria-label="顺时针旋转"
                    onClick={() => rotateBy(90)}
                    className="charkle-pressable w-7 h-7 rounded-full inline-flex items-center justify-center text-white/88 hover:bg-white/12 cursor-pointer"
                  >
                    <RotateCw size={13.5} />
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
                      'charkle-pressable w-7 h-7 rounded-full inline-flex items-center justify-center cursor-pointer',
                      flipHorizontal
                        ? 'bg-[#3B82F6]/75 text-white'
                        : 'text-white/88 hover:bg-white/12',
                    ].join(' ')}
                  >
                    <FlipHorizontal2 size={13.5} />
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
                      'charkle-pressable w-7 h-7 rounded-full inline-flex items-center justify-center cursor-pointer',
                      flipVertical
                        ? 'bg-[#3B82F6]/75 text-white'
                        : 'text-white/88 hover:bg-white/12',
                    ].join(' ')}
                  >
                    <FlipVertical2 size={13.5} />
                  </button>
                  {hasActiveTransform && (
                    <button
                      type="button"
                      title="还原旋转与翻转"
                      onClick={() => resetTransforms(false)}
                      className="charkle-pressable ml-0.5 h-6 px-2 rounded-[7px] bg-[#3B82F6]/75 text-white text-[10.5px] charkle-mono inline-flex items-center gap-1 cursor-pointer"
                    >
                      {normalizedRot !== 0 && <span>{normalizedRot}°</span>}
                      <RotateCcw size={10} />
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
                      className="charkle-pressable h-7 px-2.5 rounded-full bg-white/12 hover:bg-white/20 text-white text-[11px] inline-flex items-center gap-1 cursor-pointer"
                    >
                      {pausedAnim ? <Play size={11.5} /> : <Pause size={11.5} />}
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
                      'charkle-pressable w-6 h-6 rounded-full inline-flex items-center justify-center cursor-pointer',
                      filled ? 'text-[#F2C14E]' : 'text-white/45 hover:text-white/85',
                      isPeak ? 'charkle-micro-pop' : '',
                    ].join(' ')}
                  >
                    <Star size={12.5} className={filled ? 'fill-current' : ''} />
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
                    void updateAssets({ assetIDs: [id], isTrashed: false }, destination).then(() =>
                      pushToast({ message: '已放回原处', tone: 'success' }),
                    );
                  }}
                  className="charkle-pressable h-7 px-2.5 rounded-full hover:bg-white/12 text-white text-[11.5px] font-medium inline-flex items-center gap-1 cursor-pointer"
                >
                  <RotateCcw size={12} />
                  放回原处
                </button>
                <button
                  type="button"
                  onClick={() => setConfirmDeleteOpen(true)}
                  className="charkle-pressable h-7 px-2.5 rounded-full hover:bg-red-500/20 text-[#FF6B6B] text-[11.5px] font-medium inline-flex items-center gap-1 cursor-pointer"
                >
                  <Trash2 size={12} />
                  彻底删除
                </button>
              </>
            ) : (
              <>
                <button
                  type="button"
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
                    'charkle-pressable w-7 h-7 rounded-full inline-flex items-center justify-center cursor-pointer',
                    asset.pinnedOffline
                      ? 'bg-[#3B82F6]/35 text-[#93C5FD]'
                      : 'text-white/85 hover:bg-white/12',
                  ].join(' ')}
                >
                  <ArrowDownCircle size={13.5} />
                </button>

                <button
                  ref={boardBtnRef}
                  type="button"
                  title="加入情绪板"
                  onClick={() => setBoardMenuOpen((v) => !v)}
                  className="charkle-pressable w-7 h-7 rounded-full inline-flex items-center justify-center text-white/85 hover:bg-white/12 cursor-pointer"
                >
                  <LayoutGrid size={13.5} />
                </button>

                <button
                  type="button"
                  title="在资源管理器中显示"
                  onClick={() =>
                    void transport.revealInExplorer(asset.id).catch(() => {
                      pushToast({ message: '无法定位本地文件', tone: 'error' });
                    })
                  }
                  className="charkle-pressable w-7 h-7 rounded-full inline-flex items-center justify-center text-white/85 hover:bg-white/12 cursor-pointer"
                >
                  <FolderOpen size={13.5} />
                </button>

                <button
                  type="button"
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
                  className="charkle-pressable w-7 h-7 rounded-full inline-flex items-center justify-center text-white/85 hover:bg-white/12 cursor-pointer"
                >
                  <Copy size={13.5} />
                </button>

                {asset.sourceURL && (
                  <button
                    type="button"
                    title="打开来源网页"
                    onClick={() =>
                      void transport.openExternalUrl(asset.sourceURL!).catch(() => {
                        pushToast({ message: '无法在默认浏览器中打开链接', tone: 'error' });
                      })
                    }
                    className="charkle-pressable w-7 h-7 rounded-full inline-flex items-center justify-center text-white/85 hover:bg-white/12 cursor-pointer"
                  >
                    <ExternalLink size={13.5} />
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
                  className="charkle-pressable w-7 h-7 rounded-full inline-flex items-center justify-center text-white/85 hover:bg-red-500/20 hover:text-[#FF6B6B] cursor-pointer"
                >
                  <Trash2 size={13.5} />
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
          className="!z-[170] w-[212px] p-1"
        >
          <div className="flex flex-col gap-0.5 text-[12px]">
            {boards.length === 0 ? (
              <div className="px-2.5 py-1.5 text-[11.5px] text-[var(--text-tertiary)]">
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
                  className="charkle-pressable w-full text-left px-2.5 py-1.5 rounded-[var(--radius-popover-inner)] text-[var(--text-primary)] hover:bg-[var(--bg-subtle)] truncate cursor-pointer"
                >
                  {b.title}
                </button>
              ))
            )}
            <div className="my-1 h-px bg-[var(--border-hairline)]" />
            <button
              type="button"
              onClick={() => {
                setBoardMenuOpen(false);
                setSelection([asset.id], asset.id);
                closeQuickLook();
                openMoodboardGenerator('seedAssets');
              }}
              className="charkle-pressable w-full text-left px-2.5 py-1.5 rounded-[var(--radius-popover-inner)] text-[var(--accent)] font-medium hover:bg-[var(--accent-soft)] cursor-pointer"
            >
              以此图快速生成新情绪板…
            </button>
          </div>
        </Popover>
      </div>

      {/* Synchronized Full-Height 300px Right Inspector (1:1 macOS QuickLookOverlayView.swift) */}
      <div
        aria-hidden={!inspectorOpen}
        style={{
          width: inspectorOpen ? 300 : 0,
          opacity: inspectorOpen ? 1 : 0,
        }}
        className={[
          'charkle-drawer-slot shrink-0 min-h-0 h-full overflow-hidden flex justify-start',
          inspectorOpen ? '' : 'pointer-events-none',
        ].join(' ')}
      >
        <InspectorView
          pinnedAsset={asset}
          isQuickLookHosted
          onRequestCloseQuickLook={closeQuickLook}
        />
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
            className="charkle-modal-scrim fixed inset-0"
            onClick={() => setConfirmDeleteOpen(false)}
          />
          <div className="charkle-modal-panel relative z-10 w-full max-w-[380px] rounded-[var(--radius-dock-outer)] bg-[var(--bg-elevated)] border border-[var(--border-hairline)] shadow-[var(--shadow-modal)] p-5 flex flex-col gap-3">
            <div className="text-[15px] font-semibold text-[var(--text-primary)]">
              彻底删除此素材？
            </div>
            <p className="text-[13px] text-[var(--text-secondary)]">彻底删除后将无法恢复。</p>
            <div className="flex items-center justify-end gap-2 pt-1">
              <Button variant="secondary" size="sm" onClick={() => setConfirmDeleteOpen(false)}>
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
    </div>,
    document.body,
  );
};
