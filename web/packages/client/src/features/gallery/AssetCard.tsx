import React, { useState } from 'react';
import { ArrowDownCircle, Check, Eye, Star } from 'lucide-react';
import type { AssetRecord, UUID } from '@charkle/shared';
import { apiClient } from '../../api/client';
import { HoverMediaPreview, stopAllHoverPreviews } from '../../components/HoverMediaPreview';
import { useCoordinatorStore } from '../../stores/coordinatorStore';
import { useLibraryStore } from '../../stores/libraryStore';
import { getCardMediaBadge, isColorSwatchAsset } from './assetCardUtils';

export interface AssetCardProps {
  asset: AssetRecord;
  selected: boolean;
  isCut?: boolean;
  cacheBust: number;
  style?: React.CSSProperties;
  className?: string;
  onSelect: (id: UUID, e: React.MouseEvent) => void;
  onDoubleClick?: (asset: AssetRecord, rect: DOMRect) => void;
}

export const AssetCard: React.FC<AssetCardProps> = React.memo(
  ({ asset, selected, isCut = false, cacheBust, style, className = '', onSelect, onDoubleClick }) => {
    const [imgError, setImgError] = useState(false);
    const [hovered, setHovered] = useState(false);
    const [hoverPlaying, setHoverPlaying] = useState(false);
    const openQuickLook = useCoordinatorStore((s) => s.openQuickLook);
    const selectedAssetIDs = useLibraryStore((s) => s.selectedAssetIDs);

    const badge = getCardMediaBadge(asset);
    const isVisual =
      asset.mediaKind === 'image' ||
      asset.mediaKind === 'animatedImage' ||
      asset.mediaKind === 'video';
    const isSwatch = isColorSwatchAsset(asset);
    const primaryHex = asset.dominantColors[0]?.hex;

    const handleOpenQL = (e: React.MouseEvent) => {
      stopAllHoverPreviews();
      const cardEl = (e.currentTarget as HTMLElement).closest(
        '[data-asset-card-id]',
      ) as HTMLElement | null;
      const rect = (cardEl ?? (e.currentTarget as HTMLElement)).getBoundingClientRect();
      if (onDoubleClick) {
        onDoubleClick(asset, rect);
      } else {
        openQuickLook(asset.id, {
          left: rect.left,
          top: rect.top,
          width: rect.width,
          height: rect.height,
        });
      }
    };

    const handleDragStart = (e: React.DragEvent) => {
      stopAllHoverPreviews();
      const dragIDs =
        selected && selectedAssetIDs.size > 0 ? Array.from(selectedAssetIDs) : [asset.id];
      e.dataTransfer.setData('application/x-charkle-assets', JSON.stringify(dragIDs));
      e.dataTransfer.effectAllowed = 'copyMove';
    };

    return (
      <div
        data-asset-card-id={asset.id}
        draggable
        onMouseEnter={() => setHovered(true)}
        onMouseLeave={() => {
          setHovered(false);
          setHoverPlaying(false);
        }}
        onMouseDown={() => stopAllHoverPreviews()}
        onDragStart={handleDragStart}
        onClick={(e) => {
          e.stopPropagation();
          onSelect(asset.id, e);
        }}
        onDoubleClick={handleOpenQL}
        style={style}
        className={[
          'group relative overflow-hidden rounded-[var(--radius-card-outer)] bg-[var(--bg-subtle)] select-none cursor-pointer',
          'transition-[box-shadow,opacity] duration-[150ms] ease-[var(--ease-out)]',
          selected
            ? 'ring-[2.5px] ring-[var(--accent)] ring-offset-2 ring-offset-[var(--bg-gallery)]'
            : 'ring-1 ring-[var(--border-hairline)] hover:ring-[var(--border-strong)]',
          isCut ? 'opacity-50 outline-2 outline-dashed outline-[var(--accent)] outline-offset-1' : '',
          className,
        ].join(' ')}
      >
        {/* Artwork Surface */}
        {isSwatch && primaryHex ? (
          <div
            className="w-full h-full flex flex-col items-end justify-end p-3"
            style={{ backgroundColor: primaryHex }}
          >
            <span className="px-2 py-0.5 rounded-[var(--radius-card-inner)] bg-black/35 backdrop-blur-xs text-[11px] font-mono font-medium text-white">
              {primaryHex}
            </span>
          </div>
        ) : !imgError ? (
          <>
            <img
              src={apiClient.thumbnailURL(asset.id, 'grid520', `${asset.updatedAt}-${cacheBust}`)}
              alt={asset.title}
              loading="lazy"
              decoding="async"
              draggable={false}
              onError={() => setImgError(true)}
              className="charkle-media-zoom w-full h-full object-cover block"
            />
            <HoverMediaPreview
              asset={asset}
              active={hovered}
              fit="cover"
              roundedClass="rounded-[var(--radius-card-outer)]"
              badgePosition="top-right"
              onRevealChange={setHoverPlaying}
            />
          </>
        ) : (
          <div
            className="w-full h-full flex flex-col items-center justify-center p-4 text-center gap-2"
            style={{
              backgroundColor: primaryHex ? `${primaryHex}22` : 'var(--bg-subtle)',
            }}
          >
            {asset.mediaKind === 'audio' ? (
              <div className="flex items-end gap-[2.5px] h-10 w-full max-w-[140px] justify-center">
                {(asset.waveformPeaks.length > 0
                  ? asset.waveformPeaks.slice(0, 24)
                  : Array.from({ length: 24 }, (_, i) => 0.25 + 0.65 * Math.abs(Math.sin(i * 0.45)))
                ).map((p, idx) => (
                  <span
                    key={idx}
                    className="w-[3px] rounded-full bg-[var(--accent)]/75"
                    style={{ height: `${Math.max(18, Math.round(p * 100))}%` }}
                  />
                ))}
              </div>
            ) : (
              <span className="text-[11px] font-mono uppercase tracking-wider px-2 py-0.5 rounded bg-[var(--bg-elevated)] text-[var(--text-secondary)]">
                {badge || asset.mediaKind}
              </span>
            )}
            <span className="text-[12px] font-medium text-[var(--text-primary)] line-clamp-2">
              {asset.title}
            </span>
          </div>
        )}

        {/* Top-left Circular Checkbox (32x32 hit area, 22x22 circle) */}
        <button
          type="button"
          aria-label={selected ? '取消选中' : '选中素材'}
          onClick={(e) => {
            e.stopPropagation();
            onSelect(asset.id, { ...e, metaKey: true } as React.MouseEvent);
          }}
          className={[
            'absolute top-0.5 left-0.5 h-8 w-8 flex items-center justify-center z-10 cursor-pointer',
            'transition-opacity duration-[140ms] ease-[var(--ease-out)]',
            selected ? 'opacity-100' : 'opacity-0 group-hover:opacity-100',
          ].join(' ')}
        >
          <span
            className={[
              'h-[22px] w-[22px] rounded-full flex items-center justify-center border shadow-xs',
              selected
                ? 'bg-[var(--accent)] border-white/80 text-white charkle-micro-pop'
                : 'bg-black/38 border-white/70 text-transparent backdrop-blur-xs hover:bg-black/55',
            ].join(' ')}
          >
            <Check size={12} strokeWidth={2.75} />
          </span>
        </button>

        {/* Top-right Badges (Media pill swaps cleanly with muted hover video badge) */}
        <div
          className={[
            'absolute top-1.5 right-1.5 flex items-center gap-1 z-10 pointer-events-none transition-opacity duration-[150ms] ease-[var(--ease-out)]',
            hoverPlaying && asset.mediaKind === 'video' ? 'opacity-0' : 'opacity-100',
          ].join(' ')}
        >
          {asset.pinnedOffline && (
            <span
              title="已保留离线副本"
              className="h-5 w-5 rounded-[var(--radius-card-inner)] bg-black/52 backdrop-blur-xs text-white flex items-center justify-center"
            >
              <ArrowDownCircle size={11} />
            </span>
          )}
          {badge && (
            <span className="px-1.5 py-0.5 rounded-[var(--radius-card-inner)] bg-black/58 backdrop-blur-xs text-[10px] font-semibold tracking-wide text-white leading-none">
              {badge}
            </span>
          )}
        </div>

        {/* Hover Quick Look button + subtle bottom caption gradient */}
        <div className="pointer-events-none absolute inset-x-0 bottom-0 opacity-0 group-hover:opacity-100 transition-opacity duration-[160ms] ease-[var(--ease-out)]">
          <div
            className="flex items-end justify-between gap-2 px-2.5 pb-2 pt-5"
            style={{
              background: isVisual
                ? 'linear-gradient(180deg, rgba(0,0,0,0) 0%, rgba(0,0,0,0.66) 100%)'
                : 'linear-gradient(180deg, rgba(0,0,0,0) 0%, rgba(0,0,0,0.52) 100%)',
            }}
          >
            <div className="min-w-0 flex items-center gap-1.5">
              <span className="text-[11.5px] font-medium text-white truncate drop-shadow-xs">
                {asset.title}
              </span>
              {asset.rating > 0 && (
                <span className="inline-flex items-center gap-0.5 text-[11px] font-semibold text-[#F2C14E] shrink-0">
                  <Star size={10} className="fill-[#F2C14E] text-[#F2C14E]" />
                  {asset.rating}
                </span>
              )}
            </div>
            <button
              type="button"
              title="快速预览 (Space)"
              onClick={(e) => {
                e.stopPropagation();
                handleOpenQL(e);
              }}
              className="pointer-events-auto charkle-pressable h-6 w-6 rounded-[var(--radius-card-inner)] bg-black/52 hover:bg-black/75 text-white flex items-center justify-center shrink-0 cursor-pointer"
            >
              <Eye size={12} />
            </button>
          </div>
        </div>
      </div>
    );
  },
);

AssetCard.displayName = 'AssetCard';
