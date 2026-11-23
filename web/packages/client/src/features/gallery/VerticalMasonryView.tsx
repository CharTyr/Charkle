import React, { useCallback, useEffect, useMemo, useRef, useState } from 'react';
import type { AssetRecord, UUID } from '@charkle/shared';
import { notifyLiveScrolling } from '../../components/HoverMediaPreview';
import { useCoordinatorStore } from '../../stores/coordinatorStore';
import { useLibraryStore } from '../../stores/libraryStore';
import { AssetCard } from './AssetCard';
import { getCardEffectiveAspectRatio } from './assetCardUtils';

interface PlacedItem {
  asset: AssetRecord;
  left: number;
  top: number;
  width: number;
  height: number;
}

interface MarqueeRect {
  startX: number;
  startY: number;
  currentX: number;
  currentY: number;
}

export interface VerticalMasonryViewProps {
  assets: AssetRecord[];
  scrollContainerRef: React.RefObject<HTMLDivElement | null>;
}

const SPACING = 12;
const HORIZONTAL_PADDING = 20;
const OVERSCAN_PX = 520;

export const VerticalMasonryView: React.FC<VerticalMasonryViewProps> = ({
  assets,
  scrollContainerRef,
}) => {
  const targetColumnWidth = useCoordinatorStore((s) => s.targetColumnWidth);
  const setTargetColumnWidth = useCoordinatorStore((s) => s.setTargetColumnWidth);
  const selectedAssetIDs = useLibraryStore((s) => s.selectedAssetIDs);
  const cutAssetIDs = useLibraryStore((s) => s.cutAssetIDs);
  const cacheBust = useLibraryStore((s) => s.cacheBustVersion);
  const selectAsset = useLibraryStore((s) => s.selectAsset);
  const selectAssetIDs = useLibraryStore((s) => s.selectAssetIDs);
  const clearSelection = useLibraryStore((s) => s.clearSelection);

  const containerRef = useRef<HTMLDivElement | null>(null);
  const [viewportWidth, setViewportWidth] = useState(960);
  const [scrollTop, setScrollTop] = useState(0);
  const [viewportHeight, setViewportHeight] = useState(800);
  const [marquee, setMarquee] = useState<MarqueeRect | null>(null);

  useEffect(() => {
    const el = containerRef.current;
    if (!el) return;
    const ro = new ResizeObserver((entries) => {
      for (const entry of entries) {
        if (entry.contentRect.width > 0) {
          setViewportWidth(entry.contentRect.width);
        }
      }
    });
    ro.observe(el);
    setViewportWidth(el.clientWidth || 960);
    return () => ro.disconnect();
  }, []);

  useEffect(() => {
    const scroller = scrollContainerRef.current;
    if (!scroller) return;
    const syncViewport = () => {
      setScrollTop(scroller.scrollTop);
      setViewportHeight(scroller.clientHeight || 800);
    };
    const onScroll = () => {
      notifyLiveScrolling();
      syncViewport();
    };
    syncViewport();
    scroller.addEventListener('scroll', onScroll, { passive: true });
    window.addEventListener('resize', syncViewport);
    return () => {
      scroller.removeEventListener('scroll', onScroll);
      window.removeEventListener('resize', syncViewport);
    };
  }, [scrollContainerRef]);

  // Cmd/Ctrl + Wheel zoom density
  useEffect(() => {
    const scroller = scrollContainerRef.current;
    if (!scroller) return;
    const onWheel = (e: WheelEvent) => {
      if (!e.metaKey && !e.ctrlKey) return;
      e.preventDefault();
      const delta = e.deltaY < 0 ? 16 : -16;
      setTargetColumnWidth(useCoordinatorStore.getState().targetColumnWidth + delta);
    };
    scroller.addEventListener('wheel', onWheel, { passive: false });
    return () => scroller.removeEventListener('wheel', onWheel);
  }, [scrollContainerRef, setTargetColumnWidth]);

  // Exact macOS Masonry Solver (`PARITY_SPEC.md` §5.1)
  const layout = useMemo(() => {
    const usableWidth = Math.max(240, viewportWidth - HORIZONTAL_PADDING * 2);
    const cols = Math.max(
      2,
      Math.min(10, Math.floor((usableWidth + SPACING) / Math.max(120, targetColumnWidth + SPACING))),
    );
    const cardWidth = (usableWidth - (cols - 1) * SPACING) / cols;
    const colHeights = new Array<number>(cols).fill(8);
    const items: PlacedItem[] = new Array(assets.length);

    for (let i = 0; i < assets.length; i++) {
      const asset = assets[i];
      let bestCol = 0;
      let bestH = colHeights[0];
      for (let c = 1; c < cols; c++) {
        if (colHeights[c] < bestH - 0.5) {
          bestH = colHeights[c];
          bestCol = c;
        }
      }
      const rawAspect = getCardEffectiveAspectRatio(asset);
      const clampedAspect = Math.max(0.55, Math.min(2.15, rawAspect));
      const height = Math.round(cardWidth / clampedAspect);
      const left = HORIZONTAL_PADDING + bestCol * (cardWidth + SPACING);
      const top = colHeights[bestCol];

      items[i] = { asset, left, top, width: cardWidth, height };
      colHeights[bestCol] = top + height + SPACING;
    }

    const totalHeight = Math.max(240, Math.max(...colHeights, 0) + 96);
    return { items, totalHeight };
  }, [assets, viewportWidth, targetColumnWidth]);

  // Virtualized visible slice
  const visibleItems = useMemo(() => {
    const minY = scrollTop - OVERSCAN_PX;
    const maxY = scrollTop + viewportHeight + OVERSCAN_PX;
    return layout.items.filter((item) => item.top + item.height >= minY && item.top <= maxY);
  }, [layout.items, scrollTop, viewportHeight]);

  const handleSelect = useCallback(
    (id: UUID, e: React.MouseEvent) => {
      if (e.shiftKey) selectAsset(id, 'range');
      else if (e.metaKey || e.ctrlKey) selectAsset(id, 'toggle');
      else selectAsset(id, 'replace');
    },
    [selectAsset],
  );

  const handleCanvasMouseDown = (e: React.MouseEvent<HTMLDivElement>) => {
    if (e.button !== 0) return;
    if ((e.target as HTMLElement).closest('[data-asset-card-id]')) return;
    const host = containerRef.current;
    if (!host) return;
    const rect = host.getBoundingClientRect();
    const startX = e.clientX - rect.left;
    const startY = e.clientY - rect.top;

    if (!e.metaKey && !e.ctrlKey && !e.shiftKey) {
      clearSelection();
    }

    setMarquee({ startX, startY, currentX: startX, currentY: startY });

    const onMove = (ev: MouseEvent) => {
      const r = host.getBoundingClientRect();
      const curX = ev.clientX - r.left;
      const curY = ev.clientY - r.top;
      setMarquee({ startX, startY, currentX: curX, currentY: curY });

      const x1 = Math.min(startX, curX);
      const y1 = Math.min(startY, curY);
      const x2 = Math.max(startX, curX);
      const y2 = Math.max(startY, curY);
      if (x2 - x1 < 6 && y2 - y1 < 6) return;

      const hit: UUID[] = [];
      for (const item of layout.items) {
        const overlaps =
          item.left < x2 &&
          item.left + item.width > x1 &&
          item.top < y2 &&
          item.top + item.height > y1;
        if (overlaps) hit.push(item.asset.id);
      }
      selectAssetIDs(hit);
    };

    const onUp = () => {
      setMarquee(null);
      window.removeEventListener('mousemove', onMove);
      window.removeEventListener('mouseup', onUp);
    };

    window.addEventListener('mousemove', onMove);
    window.addEventListener('mouseup', onUp);
  };

  return (
    <div
      ref={containerRef}
      onMouseDown={handleCanvasMouseDown}
      className="relative w-full select-none"
      style={{ height: layout.totalHeight }}
    >
      {visibleItems.map((item) => (
        <AssetCard
          key={item.asset.id}
          asset={item.asset}
          selected={selectedAssetIDs.has(item.asset.id)}
          isCut={cutAssetIDs.has(item.asset.id)}
          cacheBust={cacheBust}
          onSelect={handleSelect}
          style={{
            position: 'absolute',
            transform: `translate3d(${item.left}px, ${item.top}px, 0)`,
            width: item.width,
            height: item.height,
          }}
        />
      ))}

      {/* Marquee Drag Box */}
      {marquee && (
        <div
          className="pointer-events-none absolute z-30 rounded-[4px] border border-[var(--accent)] bg-[var(--accent-soft)]"
          style={{
            left: Math.min(marquee.startX, marquee.currentX),
            top: Math.min(marquee.startY, marquee.currentY),
            width: Math.abs(marquee.currentX - marquee.startX),
            height: Math.abs(marquee.currentY - marquee.startY),
          }}
        />
      )}
    </div>
  );
};
