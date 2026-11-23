import React, { useEffect, useMemo, useRef, useState } from 'react';
import { useCoordinatorStore } from '../../stores';
import type { AssetRecord } from '../../types/domain';
import { AssetCard } from './AssetCard';

export interface MasonryPlacedItem {
  asset: AssetRecord;
  x: number;
  y: number;
  width: number;
  height: number;
}

export function computeMasonryLayout(
  assets: AssetRecord[],
  containerWidth: number,
  targetCardWidth: number,
  gap = 12,
): { items: MasonryPlacedItem[]; totalHeight: number } {
  const usableWidth = Math.max(240, containerWidth);
  const cols = Math.max(1, Math.floor((usableWidth + gap) / (targetCardWidth + gap)));
  const colWidth = (usableWidth - gap * (cols - 1)) / cols;
  const colHeights = new Array<number>(cols).fill(0);
  const items: MasonryPlacedItem[] = new Array(assets.length);

  for (let i = 0; i < assets.length; i++) {
    const asset = assets[i];
    let shortestCol = 0;
    for (let c = 1; c < cols; c++) {
      if (colHeights[c] < colHeights[shortestCol]) shortestCol = c;
    }

    const rawRatio =
      asset.pixelWidth > 0 && asset.pixelHeight > 0
        ? asset.pixelHeight / asset.pixelWidth
        : asset.mediaKind === 'audio'
          ? 0.56
          : 0.78;
    const clampedRatio = Math.max(0.45, Math.min(2.15, rawRatio));
    const cardHeight = Math.round(colWidth * clampedRatio);
    const x = shortestCol * (colWidth + gap);
    const y = colHeights[shortestCol];

    items[i] = {
      asset,
      x,
      y,
      width: colWidth,
      height: cardHeight,
    };
    colHeights[shortestCol] = y + cardHeight + gap;
  }

  const totalHeight = Math.max(0, ...colHeights);
  return { items, totalHeight };
}

export interface VerticalMasonryViewProps {
  assets: AssetRecord[];
  cardScale: number;
}

interface MarqueeRect {
  startX: number;
  startY: number;
  currentX: number;
  currentY: number;
}

/**
 * Pure O(N) virtualized Vertical Masonry layout (supports 10,000+ assets smoothly)
 * with drag marquee box-selection.
 */
export const VerticalMasonryView: React.FC<VerticalMasonryViewProps> = ({
  assets,
  cardScale,
}) => {
  const scrollRef = useRef<HTMLDivElement | null>(null);
  const contentRef = useRef<HTMLDivElement | null>(null);
  const [viewport, setViewport] = useState({ width: 1080, height: 760 });
  const [scrollTop, setScrollTop] = useState(0);
  const [marquee, setMarquee] = useState<MarqueeRect | null>(null);

  const selectedAssetIds = useCoordinatorStore((s) => s.selectedAssetIds);
  const setSelection = useCoordinatorStore((s) => s.setSelection);
  const clearSelection = useCoordinatorStore((s) => s.clearSelection);

  const selectedSet = useMemo(() => new Set(selectedAssetIds), [selectedAssetIds]);
  const orderedIds = useMemo(() => assets.map((a) => a.id), [assets]);

  useEffect(() => {
    const el = scrollRef.current;
    if (!el) return;
    const measure = () => {
      const w = el.clientWidth;
      const h = el.clientHeight;
      if (w > 0 && h > 0) {
        setViewport({ width: Math.max(240, w - 32), height: h });
      }
    };
    measure();
    if (typeof ResizeObserver === 'undefined') return;
    const obs = new ResizeObserver(measure);
    obs.observe(el);
    return () => obs.disconnect();
  }, []);

  const layout = useMemo(
    () => computeMasonryLayout(assets, viewport.width, cardScale, 12),
    [assets, viewport.width, cardScale],
  );

  // Viewport windowing: only render items inside [scrollTop - 1.5*vh, scrollTop + 2.5*vh]
  const visibleItems = useMemo(() => {
    const minY = Math.max(0, scrollTop - viewport.height * 1.5);
    const maxY = scrollTop + viewport.height * 2.5;
    return layout.items.filter(
      (item) => item.y + item.height >= minY && item.y <= maxY,
    );
  }, [layout.items, scrollTop, viewport.height]);

  const handlePointerDown = (e: React.MouseEvent) => {
    if (e.button !== 0) return;
    if ((e.target as HTMLElement).closest('[data-asset-id]')) return;
    const content = contentRef.current;
    if (!content) return;
    const rect = content.getBoundingClientRect();
    const x = e.clientX - rect.left;
    const y = e.clientY - rect.top;
    if (!e.ctrlKey && !e.metaKey) {
      clearSelection();
    }
    setMarquee({ startX: x, startY: y, currentX: x, currentY: y });
  };

  useEffect(() => {
    if (!marquee) return;
    const handleMove = (e: MouseEvent) => {
      const content = contentRef.current;
      if (!content) return;
      const rect = content.getBoundingClientRect();
      const cx = e.clientX - rect.left;
      const cy = e.clientY - rect.top;
      setMarquee((prev) => (prev ? { ...prev, currentX: cx, currentY: cy } : null));

      const left = Math.min(marquee.startX, cx);
      const right = Math.max(marquee.startX, cx);
      const top = Math.min(marquee.startY, cy);
      const bottom = Math.max(marquee.startY, cy);
      if (right - left > 4 || bottom - top > 4) {
        const hit: string[] = [];
        for (const item of layout.items) {
          if (
            item.x < right &&
            item.x + item.width > left &&
            item.y < bottom &&
            item.y + item.height > top
          ) {
            hit.push(item.asset.id);
          }
        }
        setSelection(hit);
      }
    };
    const handleUp = () => setMarquee(null);
    window.addEventListener('mousemove', handleMove);
    window.addEventListener('mouseup', handleUp);
    return () => {
      window.removeEventListener('mousemove', handleMove);
      window.removeEventListener('mouseup', handleUp);
    };
  }, [marquee, layout.items, setSelection]);

  const marqueeBox = marquee
    ? {
        left: Math.min(marquee.startX, marquee.currentX),
        top: Math.min(marquee.startY, marquee.currentY),
        width: Math.abs(marquee.currentX - marquee.startX),
        height: Math.abs(marquee.currentY - marquee.startY),
      }
    : null;

  return (
    <div
      ref={scrollRef}
      data-testid="gallery-masonry-scroll"
      onScroll={(e) => setScrollTop(e.currentTarget.scrollTop)}
      onMouseDown={handlePointerDown}
      className="flex-1 min-h-0 overflow-y-auto charkle-scroll px-4 pb-20 pt-1 relative"
    >
      <div
        ref={contentRef}
        className="relative w-full"
        style={{ height: Math.max(layout.totalHeight, 120) }}
      >
        {visibleItems.map((item) => (
          <AssetCard
            key={item.asset.id}
            asset={item.asset}
            selected={selectedSet.has(item.asset.id)}
            orderedIds={orderedIds}
            width={item.width}
            height={item.height}
            style={{
              position: 'absolute',
              transform: `translate3d(${Math.round(item.x)}px, ${Math.round(item.y)}px, 0)`,
              top: 0,
              left: 0,
            }}
          />
        ))}

        {marqueeBox && (marqueeBox.width > 4 || marqueeBox.height > 4) && (
          <div
            aria-hidden="true"
            className="pointer-events-none absolute z-30 rounded-[4px] border border-[var(--accent)] bg-[var(--accent-soft)]"
            style={marqueeBox}
          />
        )}
      </div>
    </div>
  );
};
