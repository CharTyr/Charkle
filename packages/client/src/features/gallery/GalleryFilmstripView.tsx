import React, { useEffect, useMemo, useRef } from 'react';
import { ChevronLeft, ChevronRight, Eye, Star } from 'lucide-react';
import {
  createDefaultAssetBatchPatch,
  getAssetDisplayTypeLabel,
} from '@charkle/shared';
import type { AssetRecord } from '@charkle/shared';
import { apiClient } from '../../api/client';
import { Button, formatBytes } from '../../design-system';
import { useCoordinatorStore } from '../../stores/coordinatorStore';
import { useLibraryStore } from '../../stores/libraryStore';
import { getCardEffectiveAspectRatio } from './assetCardUtils';

export interface GalleryFilmstripViewProps {
  assets: AssetRecord[];
}

export const GalleryFilmstripView: React.FC<GalleryFilmstripViewProps> = ({ assets }) => {
  const selectedAssetIDs = useLibraryStore((s) => s.selectedAssetIDs);
  const selectAsset = useLibraryStore((s) => s.selectAsset);
  const batchPatch = useLibraryStore((s) => s.batchPatch);
  const markOpened = useLibraryStore((s) => s.markOpened);
  const cacheBust = useLibraryStore((s) => s.cacheBustVersion);

  const openQuickLook = useCoordinatorStore((s) => s.openQuickLook);
  const stripRef = useRef<HTMLDivElement | null>(null);

  const activeIndex = useMemo(() => {
    if (assets.length === 0) return -1;
    for (const id of selectedAssetIDs) {
      const idx = assets.findIndex((a) => a.id === id);
      if (idx >= 0) return idx;
    }
    return 0;
  }, [assets, selectedAssetIDs]);

  const activeAsset = activeIndex >= 0 ? assets[activeIndex] : null;

  useEffect(() => {
    if (!activeAsset) return;
    void markOpened(activeAsset.id);
    const thumbEl = stripRef.current?.querySelector<HTMLElement>(
      `[data-filmstrip-id="${activeAsset.id}"]`,
    );
    thumbEl?.scrollIntoView({ behavior: 'smooth', inline: 'center', block: 'nearest' });
  }, [activeAsset, markOpened]);

  useEffect(() => {
    const onKeyDown = (e: KeyboardEvent) => {
      const tag = (e.target as HTMLElement | null)?.tagName;
      if (tag === 'INPUT' || tag === 'TEXTAREA' || tag === 'SELECT') return;
      if (useCoordinatorStore.getState().quickLookAssetID) return;
      if (assets.length === 0) return;

      if (e.key === 'ArrowRight') {
        e.preventDefault();
        const next = Math.min(assets.length - 1, activeIndex + 1);
        selectAsset(assets[next].id, 'replace');
      } else if (e.key === 'ArrowLeft') {
        e.preventDefault();
        const prev = Math.max(0, activeIndex - 1);
        selectAsset(assets[prev].id, 'replace');
      }
    };
    window.addEventListener('keydown', onKeyDown);
    return () => window.removeEventListener('keydown', onKeyDown);
  }, [assets, activeIndex, selectAsset]);

  if (!activeAsset) return null;

  const stepBy = (delta: number) => {
    const nextIdx = Math.max(0, Math.min(assets.length - 1, activeIndex + delta));
    selectAsset(assets[nextIdx].id, 'replace');
  };

  return (
    <div className="flex-1 min-h-0 flex flex-col px-5 pb-4 gap-3">
      {/* Main Hero Preview Stage */}
      <div className="relative flex-1 min-h-[280px] rounded-[var(--radius-dock-outer)] bg-[var(--bg-elevated)] border border-[var(--border-hairline)] overflow-hidden flex items-center justify-center p-4">
        {activeAsset.mediaKind === 'video' ? (
          <video
            key={activeAsset.id}
            src={apiClient.originalMediaURL(activeAsset.id)}
            poster={apiClient.thumbnailURL(activeAsset.id, 'preview1400', cacheBust)}
            controls
            playsInline
            className="max-w-full max-h-full rounded-[var(--radius-card-outer)] object-contain"
          />
        ) : activeAsset.mediaKind === 'audio' ? (
          <div className="w-full max-w-[460px] flex flex-col items-center gap-4 p-6 rounded-[var(--radius-settings-outer)] bg-[var(--bg-gallery)] border border-[var(--border-hairline)]">
            <div className="flex items-end gap-[3px] h-16 w-full justify-center">
              {(activeAsset.waveformPeaks.length > 0
                ? activeAsset.waveformPeaks.slice(0, 48)
                : Array.from({ length: 48 }, (_, i) => 0.25 + 0.65 * Math.abs(Math.sin(i * 0.35)))
              ).map((p, idx) => (
                <span
                  key={idx}
                  className="flex-1 max-w-[5px] rounded-full bg-[var(--accent)]/80"
                  style={{ height: `${Math.max(14, Math.round(p * 100))}%` }}
                />
              ))}
            </div>
            <audio
              key={activeAsset.id}
              controls
              src={apiClient.originalMediaURL(activeAsset.id)}
              className="w-full"
            />
          </div>
        ) : (
          <img
            key={activeAsset.id}
            src={
              activeAsset.mediaKind === 'animatedImage'
                ? apiClient.originalMediaURL(activeAsset.id)
                : apiClient.thumbnailURL(activeAsset.id, 'preview1400', `${activeAsset.updatedAt}-${cacheBust}`)
            }
            alt={activeAsset.title}
            onDoubleClick={() => openQuickLook(activeAsset.id)}
            className="max-w-full max-h-full object-contain rounded-[var(--radius-card-outer)] cursor-zoom-in select-none"
          />
        )}

        {/* Left / Right Chevrons */}
        <button
          type="button"
          disabled={activeIndex <= 0}
          onClick={() => stepBy(-1)}
          aria-label="上一项"
          className="charkle-pressable charkle-glass absolute left-3 top-1/2 -translate-y-1/2 h-9 w-9 rounded-full flex items-center justify-center text-[var(--text-primary)] disabled:opacity-25 cursor-pointer"
        >
          <ChevronLeft size={18} />
        </button>
        <button
          type="button"
          disabled={activeIndex >= assets.length - 1}
          onClick={() => stepBy(1)}
          aria-label="下一项"
          className="charkle-pressable charkle-glass absolute right-3 top-1/2 -translate-y-1/2 h-9 w-9 rounded-full flex items-center justify-center text-[var(--text-primary)] disabled:opacity-25 cursor-pointer"
        >
          <ChevronRight size={18} />
        </button>
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
            {[1, 2, 3, 4, 5].map((star) => (
              <button
                key={star}
                type="button"
                onClick={() =>
                  void batchPatch(
                    createDefaultAssetBatchPatch([activeAsset.id], {
                      rating: activeAsset.rating === star ? 0 : star,
                    }),
                  )
                }
                className="charkle-pressable p-0.5 cursor-pointer"
              >
                <Star
                  size={14}
                  className={
                    activeAsset.rating >= star
                      ? 'fill-[#F2C14E] text-[#F2C14E]'
                      : 'text-[var(--text-tertiary)]'
                  }
                />
              </button>
            ))}
          </div>

          <span className="text-[12px] tabular-nums text-[var(--text-tertiary)]">
            {activeIndex + 1} / {assets.length}
          </span>

          <Button variant="secondary" size="xs" onClick={() => openQuickLook(activeAsset.id)}>
            <Eye size={13} />
            快速预览
          </Button>
        </div>
      </div>

      {/* Bottom 96px Filmstrip */}
      <div
        ref={stripRef}
        className="h-[92px] shrink-0 flex items-center gap-2 overflow-x-auto charkle-scroll px-2 py-2 rounded-[var(--radius-settings-outer)] bg-[var(--bg-elevated)]/70 border border-[var(--border-hairline)]"
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
              onClick={(e) => {
                if (e.shiftKey) selectAsset(asset.id, 'range');
                else if (e.metaKey || e.ctrlKey) selectAsset(asset.id, 'toggle');
                else selectAsset(asset.id, 'replace');
              }}
              onDoubleClick={() => openQuickLook(asset.id)}
              style={{ width: thumbW, height: 68 }}
              className={[
                'charkle-pressable shrink-0 overflow-hidden rounded-[8px] bg-[var(--bg-subtle)] cursor-pointer',
                isCurrent
                  ? 'ring-2 ring-[var(--accent)] ring-offset-2 ring-offset-[var(--bg-elevated)]'
                  : isSelected
                    ? 'ring-2 ring-[var(--accent)]/60'
                    : 'opacity-72 hover:opacity-100',
              ].join(' ')}
            >
              <img
                src={apiClient.thumbnailURL(asset.id, 'grid520', `${asset.updatedAt}-${cacheBust}`)}
                alt={asset.title}
                loading="lazy"
                draggable={false}
                className="w-full h-full object-cover"
              />
            </button>
          );
        })}
      </div>
    </div>
  );
};
