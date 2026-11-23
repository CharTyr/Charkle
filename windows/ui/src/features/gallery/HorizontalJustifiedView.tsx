import React, { useEffect, useMemo, useRef, useState } from 'react';
import { useCoordinatorStore } from '../../stores';
import type { AssetRecord } from '../../types/domain';
import { AssetCard } from './AssetCard';

export interface JustifiedPlacedItem {
  asset: AssetRecord;
  x: number;
  y: number;
  width: number;
  height: number;
}

export function computeJustifiedLayout(
  assets: AssetRecord[],
  containerWidth: number,
  targetRowHeight: number,
  gap = 12,
): { items: JustifiedPlacedItem[]; totalHeight: number } {
  const usableWidth = Math.max(260, containerWidth);
  const items: JustifiedPlacedItem[] = [];
  let rowBuffer: Array<{ asset: AssetRecord; ratio: number }> = [];
  let rowRatioSum = 0;
  let cursorY = 0;

  const flushRow = (justify: boolean) => {
    if (rowBuffer.length === 0) return;
    const totalGap = gap * (rowBuffer.length - 1);
    const idealHeight = justify
      ? (usableWidth - totalGap) / Math.max(0.2, rowRatioSum)
      : targetRowHeight;
    const rowHeight = Math.round(
      Math.max(targetRowHeight * 0.65, Math.min(targetRowHeight * 1.45, idealHeight)),
    );

    let cursorX = 0;
    for (let i = 0; i < rowBuffer.length; i++) {
      const entry = rowBuffer[i];
      const isLast = i === rowBuffer.length - 1;
      const w =
        justify && isLast
          ? Math.max(60, usableWidth - cursorX)
          : Math.round(rowHeight * entry.ratio);
      items.push({
        asset: entry.asset,
        x: cursorX,
        y: cursorY,
        width: w,
        height: rowHeight,
      });
      cursorX += w + gap;
    }

    cursorY += rowHeight + gap;
    rowBuffer = [];
    rowRatioSum = 0;
  };

  for (const asset of assets) {
    const rawRatio =
      asset.pixelWidth > 0 && asset.pixelHeight > 0
        ? asset.pixelWidth / asset.pixelHeight
        : asset.mediaKind === 'audio'
          ? 1.7
          : 1.25;
    const ratio = Math.max(0.55, Math.min(2.6, rawRatio));
    rowBuffer.push({ asset, ratio });
    rowRatioSum += ratio;

    const estimatedWidth = rowRatioSum * targetRowHeight + gap * (rowBuffer.length - 1);
    if (estimatedWidth >= usableWidth) {
      flushRow(true);
    }
  }

  flushRow(false);
  return { items, totalHeight: Math.max(0, cursorY) };
}

export interface HorizontalJustifiedViewProps {
  assets: AssetRecord[];
  cardScale: number;
}

/**
 * Pure O(N) virtualized Horizontal Justified layout (row-aligned aspect ratios).
 */
export const HorizontalJustifiedView: React.FC<HorizontalJustifiedViewProps> = ({
  assets,
  cardScale,
}) => {
  const scrollRef = useRef<HTMLDivElement | null>(null);
  const [viewport, setViewport] = useState({ width: 1080, height: 760 });
  const [scrollTop, setScrollTop] = useState(0);

  const selectedAssetIds = useCoordinatorStore((s) => s.selectedAssetIds);
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
        setViewport({ width: Math.max(260, w - 32), height: h });
      }
    };
    measure();
    if (typeof ResizeObserver === 'undefined') return;
    const obs = new ResizeObserver(measure);
    obs.observe(el);
    return () => obs.disconnect();
  }, []);

  const targetRowHeight = Math.round(cardScale * 0.88);
  const layout = useMemo(
    () => computeJustifiedLayout(assets, viewport.width, targetRowHeight, 12),
    [assets, viewport.width, targetRowHeight],
  );

  const visibleItems = useMemo(() => {
    const minY = Math.max(0, scrollTop - viewport.height * 1.5);
    const maxY = scrollTop + viewport.height * 2.5;
    return layout.items.filter(
      (item) => item.y + item.height >= minY && item.y <= maxY,
    );
  }, [layout.items, scrollTop, viewport.height]);

  return (
    <div
      ref={scrollRef}
      data-testid="gallery-justified-scroll"
      onScroll={(e) => setScrollTop(e.currentTarget.scrollTop)}
      onClick={(e) => {
        if (!(e.target as HTMLElement).closest('[data-asset-id]')) {
          clearSelection();
        }
      }}
      className="flex-1 min-h-0 overflow-y-auto charkle-scroll px-4 pb-20 pt-1"
    >
      <div
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
      </div>
    </div>
  );
};
