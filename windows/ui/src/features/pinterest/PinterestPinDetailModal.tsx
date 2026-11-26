import React, { useEffect, useMemo } from 'react';
import {
  Add16Filled,
  ArrowDownload16Regular,
  ArrowLeft16Regular,
  Checkmark16Filled,
  CheckmarkCircle16Filled,
  Dismiss16Regular,
  Open16Regular,
  Sparkle16Regular,
  ZoomIn16Regular,
} from '@fluentui/react-icons';
import { getTransport, isTauriRuntime } from '../../api/transport';
import { Button } from '../../design-system';
import { usePinterestStore } from '../../stores/pinterestStore';
import { resolveSocialMediaUrl, type PinterestPin } from '../../types/domain';
import { pinAspectRatio, pinDisplayImageUrl, pinDisplayTitle } from './spatialLayout';

/**
 * Aspect-Adaptive Floating Pin Detail Overlay + Similar Pins Waterfall + Full-Res Lightbox.
 * Mirrors `Sources/CharkleApp/Views/Pinterest/PinterestExploreWorkspaceView.swift` (v1.4.1):
 * - Compact side-by-side hero matching exact artwork aspect ratio (zero pillarbox dead space)
 *   so the 4-column Pinterest Similar Pins waterfall is immediately visible on screen 1.
 * - Click hero artwork -> full-resolution lightbox preview (Esc / click closes).
 * - Full history back-stack (`返回上一个`) when drilling into similar pins.
 */
export const PinterestPinDetailModal: React.FC = () => {
  const pin = usePinterestStore((s) => s.activeDetailPin);
  const detailStack = usePinterestStore((s) => s.detailStack);
  const similarPins = usePinterestStore((s) => s.activeSimilarPins);
  const hasMoreSimilar = usePinterestStore((s) => s.hasMoreSimilar);
  const isLoadingDetail = usePinterestStore((s) => s.isLoadingDetail);
  const isLoadingMoreSimilar = usePinterestStore((s) => s.isLoadingMoreSimilar);
  const lightboxOpen = usePinterestStore((s) => s.lightboxOpen);
  const collectedPinIds = usePinterestStore((s) => s.collectedPinIds);
  const importedPinIds = usePinterestStore((s) => s.importedPinIds);
  const isImportingTray = usePinterestStore((s) => s.isImportingTray);

  const openPinDetail = usePinterestStore((s) => s.openPinDetail);
  const popPinDetail = usePinterestStore((s) => s.popPinDetail);
  const closePinDetail = usePinterestStore((s) => s.closePinDetail);
  const loadMoreSimilarPins = usePinterestStore((s) => s.loadMoreSimilarPins);
  const exploreSimilarInSpace = usePinterestStore((s) => s.exploreSimilarInSpace);
  const toggleTrayPin = usePinterestStore((s) => s.toggleTrayPin);
  const importSinglePinDirectly = usePinterestStore((s) => s.importSinglePinDirectly);
  const setLightboxOpen = usePinterestStore((s) => s.setLightboxOpen);

  const isTauri = isTauriRuntime();

  useEffect(() => {
    if (!pin) return;
    const handleKeyDown = (e: KeyboardEvent) => {
      if (e.key === 'Escape') {
        e.preventDefault();
        e.stopPropagation();
        if (lightboxOpen) {
          setLightboxOpen(false);
        } else {
          closePinDetail();
        }
      }
    };
    window.addEventListener('keydown', handleKeyDown, true);
    return () => window.removeEventListener('keydown', handleKeyDown, true);
  }, [pin, lightboxOpen, setLightboxOpen, closePinDetail]);

  // Distribute similar pins into 4 balanced masonry columns
  const similarColumns = useMemo(() => {
    const cols: PinterestPin[][] = [[], [], [], []];
    const heights = [0, 0, 0, 0];
    for (const item of similarPins) {
      let minIdx = 0;
      for (let i = 1; i < 4; i += 1) {
        if (heights[i] < heights[minIdx]) minIdx = i;
      }
      cols[minIdx].push(item);
      heights[minIdx] += 1 / pinAspectRatio(item);
    }
    return cols;
  }, [similarPins]);

  if (!pin) return null;

  const isCollected = Boolean(collectedPinIds[pin.id]);
  const isImported = Boolean(importedPinIds[pin.id]);
  const title = pinDisplayTitle(pin);
  const ratio = pinAspectRatio(pin);

  // Compact hero bounding box so portrait/landscape artwork stays exact-aspect with 0 pillarbox
  const maxHeroHeight = 320;
  const maxHeroWidth = 440;
  let heroWidth = Math.round(maxHeroHeight * ratio);
  let heroHeight = maxHeroHeight;
  if (heroWidth > maxHeroWidth) {
    heroWidth = maxHeroWidth;
    heroHeight = Math.round(maxHeroWidth / ratio);
  }
  heroWidth = Math.max(168, heroWidth);
  heroHeight = Math.max(160, heroHeight);

  const heroImageUrl = resolveSocialMediaUrl(
    pinDisplayImageUrl(pin, 900) ?? pin.previewURL ?? pin.thumbnailURL ?? undefined,
    isTauri,
  );
  const fullImageUrl = resolveSocialMediaUrl(
    pin.originalURL ?? pin.previewURL ?? pin.thumbnailURL ?? undefined,
    isTauri,
  );

  return (
    <div
      role="dialog"
      aria-modal="true"
      aria-label={`Pin 详情：${title}`}
      data-testid="pinterest-pin-detail-modal"
      onPointerDown={(e) => e.stopPropagation()}
      onWheel={(e) => e.stopPropagation()}
      onClick={closePinDetail}
      className="fixed inset-0 z-50 flex items-center justify-center bg-black/52 backdrop-blur-[6px] p-5"
    >
      <div
        onClick={(e) => e.stopPropagation()}
        className="w-full max-w-[980px] max-h-[88vh] flex flex-col rounded-[16px] bg-[var(--bg-elevated)] border border-[var(--win-stroke-card)] shadow-[0_24px_64px_rgba(0,0,0,0.4)] overflow-hidden"
      >
        {/* Top bar */}
        <div className="h-[46px] shrink-0 px-4 border-b border-[var(--win-stroke-divider)] flex items-center justify-between gap-3">
          <div className="flex items-center gap-2 min-w-0">
            {detailStack.length > 0 && (
              <Button
                variant="subtle"
                size="xs"
                onClick={() => void popPinDetail()}
                data-testid="pinterest-detail-back-btn"
              >
                <ArrowLeft16Regular className="w-3.5 h-3.5" />
                <span>返回上一个</span>
              </Button>
            )}
            <span className="text-[13px] font-semibold text-[var(--text-primary)] truncate">
              {title}
            </span>
          </div>
          <button
            type="button"
            aria-label="关闭详情"
            onClick={closePinDetail}
            className="w-7 h-7 rounded-[var(--win-radius-control)] inline-flex items-center justify-center text-[var(--text-secondary)] hover:text-[var(--text-primary)] hover:bg-[var(--win-subtle-hover)] cursor-pointer"
          >
            <Dismiss16Regular className="w-4 h-4" />
          </button>
        </div>

        {/* Scrollable body: compact side-by-side hero + immediate 4-column similar pins */}
        <div className="flex-1 min-h-0 overflow-y-auto px-5 py-4 flex flex-col gap-5">
          {/* Compact aspect-adaptive hero */}
          <div className="flex flex-col md:flex-row items-start gap-5">
            <button
              type="button"
              data-testid="pinterest-detail-hero-image"
              onClick={() => setLightboxOpen(true)}
              style={{
                width: heroWidth,
                height: heroHeight,
                backgroundColor: pin.dominantColorHex || 'var(--bg-subtle)',
              }}
              className="group relative shrink-0 rounded-[12px] overflow-hidden ring-1 ring-black/10 dark:ring-white/10 shadow-md cursor-zoom-in"
            >
              {heroImageUrl && (
                <img
                  src={heroImageUrl}
                  alt={title}
                  className="w-full h-full object-cover block"
                />
              )}
              <span className="pointer-events-none absolute bottom-2 right-2 inline-flex items-center gap-1 px-2 py-1 rounded-full bg-black/60 text-white text-[11px] opacity-0 group-hover:opacity-100 transition-opacity backdrop-blur-sm">
                <ZoomIn16Regular className="w-3.5 h-3.5" />
                <span>查看大图</span>
              </span>
            </button>

            <div className="flex-1 min-w-0 flex flex-col gap-3">
              <div>
                <h2 className="text-[16px] font-semibold text-[var(--text-primary)] leading-snug">
                  {title}
                </h2>
                {pin.description.trim() && pin.description.trim() !== title && (
                  <p className="mt-1.5 text-[12.5px] text-[var(--text-secondary)] leading-relaxed line-clamp-4">
                    {pin.description.trim()}
                  </p>
                )}
              </div>

              {/* Metadata chips */}
              <div className="flex flex-wrap items-center gap-1.5 text-[11.5px]">
                {pin.authorName && (
                  <span className="px-2 py-0.5 rounded-full bg-[var(--bg-subtle)] text-[var(--text-secondary)]">
                    作者：{pin.authorName}
                  </span>
                )}
                {pin.boardName && (
                  <span className="px-2 py-0.5 rounded-full bg-[var(--bg-subtle)] text-[var(--text-secondary)]">
                    画板：{pin.boardName}
                  </span>
                )}
                {pin.pixelWidth > 0 && pin.pixelHeight > 0 && (
                  <span className="px-2 py-0.5 rounded-full bg-[var(--bg-subtle)] text-[var(--text-tertiary)] charkle-tabular">
                    {pin.pixelWidth} × {pin.pixelHeight}
                  </span>
                )}
                {isImported && (
                  <span className="inline-flex items-center gap-1 px-2 py-0.5 rounded-full bg-emerald-500/15 text-emerald-600 dark:text-emerald-400 font-medium">
                    <CheckmarkCircle16Filled className="w-3 h-3" />
                    <span>已在素材库中</span>
                  </span>
                )}
              </div>

              {/* Primary action row */}
              <div className="flex flex-wrap items-center gap-2 pt-1">
                <Button
                  variant={isCollected ? 'standard' : 'accent'}
                  size="sm"
                  data-testid="pinterest-detail-toggle-tray"
                  onClick={() => toggleTrayPin(pin)}
                >
                  {isCollected ? (
                    <>
                      <Checkmark16Filled className="w-3.5 h-3.5 text-[var(--accent)]" />
                      <span>已在托盘</span>
                    </>
                  ) : (
                    <>
                      <Add16Filled className="w-3.5 h-3.5" />
                      <span>加入收藏托盘</span>
                    </>
                  )}
                </Button>

                <Button
                  variant="standard"
                  size="sm"
                  disabled={isImportingTray}
                  onClick={() => void importSinglePinDirectly(pin, null)}
                >
                  <ArrowDownload16Regular className="w-3.5 h-3.5" />
                  <span>直接入库</span>
                </Button>

                <Button
                  variant="standard"
                  size="sm"
                  onClick={() => void exploreSimilarInSpace(pin)}
                >
                  <Sparkle16Regular className="w-3.5 h-3.5" />
                  <span>在无限空间展开相似</span>
                </Button>

                <Button
                  variant="subtle"
                  size="sm"
                  onClick={() => void getTransport().openExternalUrl(pin.pinPageURL)}
                >
                  <Open16Regular className="w-3.5 h-3.5" />
                  <span>在 Pinterest 打开</span>
                </Button>
              </div>
            </div>
          </div>

          {/* 4-column Pinterest Similar Pins waterfall immediately visible below hero */}
          <div className="flex flex-col gap-3 border-t border-[var(--win-stroke-divider)] pt-4">
            <div className="flex items-center justify-between">
              <div className="flex items-center gap-2">
                <Sparkle16Regular className="w-4 h-4 text-[var(--accent)]" />
                <h3 className="text-[13.5px] font-semibold text-[var(--text-primary)]">
                  Pinterest 类似素材
                </h3>
                {similarPins.length > 0 && (
                  <span className="text-[11.5px] text-[var(--text-tertiary)] charkle-tabular">
                    {similarPins.length} 项
                  </span>
                )}
              </div>
            </div>

            {isLoadingDetail ? (
              <div className="py-10 text-center text-[12.5px] text-[var(--text-secondary)]">
                正在检索视觉与主题相似灵感…
              </div>
            ) : similarPins.length === 0 ? (
              <div className="py-8 text-center text-[12.5px] text-[var(--text-tertiary)]">
                暂无更多类似素材
              </div>
            ) : (
              <>
                <div className="grid grid-cols-2 sm:grid-cols-4 gap-3 items-start">
                  {similarColumns.map((col, colIdx) => (
                    <div key={colIdx} className="flex flex-col gap-3">
                      {col.map((sim) => {
                        const simCollected = Boolean(collectedPinIds[sim.id]);
                        const simImg = resolveSocialMediaUrl(
                          pinDisplayImageUrl(sim, 240),
                          isTauri,
                        );
                        const simTitle = pinDisplayTitle(sim);
                        return (
                          <div
                            key={sim.id}
                            role="button"
                            tabIndex={0}
                            onClick={() => void openPinDetail(sim, true)}
                            onKeyDown={(e) => {
                              if (e.key === 'Enter' || e.key === ' ') {
                                e.preventDefault();
                                void openPinDetail(sim, true);
                              }
                            }}
                            style={{
                              aspectRatio: String(pinAspectRatio(sim)),
                              backgroundColor: sim.dominantColorHex || 'var(--bg-subtle)',
                            }}
                            className={[
                              'group relative w-full rounded-[10px] overflow-hidden cursor-pointer shadow-sm hover:shadow-md transition-shadow',
                              simCollected
                                ? 'ring-2 ring-[var(--accent)]'
                                : 'ring-1 ring-black/8 dark:ring-white/10',
                            ].join(' ')}
                          >
                            {simImg && (
                              <img
                                src={simImg}
                                alt={simTitle}
                                loading="lazy"
                                decoding="async"
                                className="w-full h-full object-cover block"
                              />
                            )}
                            <button
                              type="button"
                              aria-label={simCollected ? '移出收藏托盘' : '加入收藏托盘'}
                              onClick={(e) => {
                                e.stopPropagation();
                                toggleTrayPin(sim);
                              }}
                              className={[
                                'absolute top-1.5 right-1.5 w-6 h-6 rounded-full inline-flex items-center justify-center shadow cursor-pointer transition-opacity',
                                simCollected
                                  ? 'bg-[var(--accent)] text-[var(--accent-text)] opacity-100'
                                  : 'bg-black/60 text-white opacity-0 group-hover:opacity-100 hover:bg-[var(--accent)]',
                              ].join(' ')}
                            >
                              {simCollected ? (
                                <Checkmark16Filled className="w-3.5 h-3.5" />
                              ) : (
                                <Add16Filled className="w-3.5 h-3.5" />
                              )}
                            </button>
                          </div>
                        );
                      })}
                    </div>
                  ))}
                </div>

                {hasMoreSimilar && (
                  <div className="flex justify-center pt-1">
                    <Button
                      variant="standard"
                      size="sm"
                      disabled={isLoadingMoreSimilar}
                      onClick={() => void loadMoreSimilarPins()}
                    >
                      {isLoadingMoreSimilar ? '正在加载…' : '加载更多类似素材'}
                    </Button>
                  </div>
                )}
              </>
            )}
          </div>
        </div>
      </div>

      {/* Full-resolution lightbox preview */}
      {lightboxOpen && fullImageUrl && (
        <div
          data-testid="pinterest-pin-lightbox"
          onClick={(e) => {
            e.stopPropagation();
            setLightboxOpen(false);
          }}
          className="fixed inset-0 z-[60] bg-black/88 flex items-center justify-center p-6 cursor-zoom-out"
        >
          <button
            type="button"
            aria-label="关闭大图预览"
            onClick={(e) => {
              e.stopPropagation();
              setLightboxOpen(false);
            }}
            className="absolute top-5 right-5 w-9 h-9 rounded-full bg-white/15 hover:bg-white/25 text-white inline-flex items-center justify-center cursor-pointer"
          >
            <Dismiss16Regular className="w-4 h-4" />
          </button>
          <img
            src={fullImageUrl}
            alt={title}
            onClick={(e) => e.stopPropagation()}
            className="max-w-[92vw] max-h-[90vh] object-contain rounded-[10px] shadow-2xl cursor-default"
          />
        </div>
      )}
    </div>
  );
};
