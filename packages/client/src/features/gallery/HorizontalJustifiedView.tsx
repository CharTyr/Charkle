import React, { useCallback, useEffect, useMemo, useRef, useState } from 'react';
import type { AssetRecord, UUID } from '@charkle/shared';
import { useCoordinatorStore } from '../../stores/coordinatorStore';
import { useLibraryStore } from '../../stores/libraryStore';
import { AssetCard } from './AssetCard';
import { getCardEffectiveAspectRatio } from './assetCardUtils';

interface JustifiedItem {
  asset: AssetRecord;
  left: number;
  top: number;
  width: number;
  height: number;
}

export interface HorizontalJustifiedViewProps {
  assets: AssetRecord[];
  scrollContainerRef: React.RefObject<HTMLDivElement | null>;
}

const SPACING = 12;
const HORIZONTAL_PADDING = 20;
const OVERSCAN_PX = 520;

export const HorizontalJustifiedView: React.FC<HorizontalJustifiedViewProps> = ({
  assets,
  scrollContainerRef,
}) => {
  const targetColumnWidth = useCoordinatorStore((s) => s.targetColumnWidth);
  const selectedAssetIDs = useLibraryStore((s) => s.selectedAssetIDs);
  const cutAssetIDs = useLibraryStore((s) => s.cutAssetIDs);
  const cacheBust = useLibraryStore((s) => s.cacheBustVersion);
  const selectAsset = useLibraryStore((s) => s.selectAsset);
  const clearSelection = useLibraryStore((s) => s.clearSelection);

  const containerRef = useRef<HTMLDivElement | null>(null);
  const [viewportWidth, setViewportWidth] = useState(960);
  const [scrollTop, setScrollTop] = useState(0);
  const [viewportHeight, setViewportHeight] = useState(800);

  useEffect(() => {
    const el = containerRef.current;
    if (!el) return;
    const ro = new ResizeObserver((entries) => {
      for (const entry of entries) {
        if (entry.contentRect.width > 0) setViewportWidth(entry.contentRect.width);
      }
    });
    ro.observe(el);
    setViewportWidth(el.clientWidth || 960);
    return () => ro.disconnect();
  }, []);

  useEffect(() => {
    const scroller = scrollContainerRef.current;
    if (!scroller) return;
    const onScroll = () => {
      setScrollTop(scroller.scrollTop);
      setViewportHeight(scroller.clientHeight || 800);
    };
    onScroll();
    scroller.addEventListener('scroll', onScroll, { passive: true });
    window.addEventListener('resize', onScroll);
    return () => {
      scroller.removeEventListener('scroll', onScroll);
      window.removeEventListener('resize', onScroll);
    };
  }, [scrollContainerRef]);

  // Exact Horizontal Justified Row Packer (`PARITY_SPEC.md` §5.1)
  const layout = useMemo(() => {
    const usableWidth = Math.max(240, viewportWidth - HORIZONTAL_PADDING * 2);
    const idealRowH = Math.max(116, Math.min(360, targetColumnWidth * 0.92));

    const items: JustifiedItem[] = [];
    let currentRow: Array<{ asset: AssetRecord; ratio: number }> = [];
    let sumRatios = 0;
    let cursorY = 8;

    const flushRow = (row: Array<{ asset: AssetRecord; ratio: number }>, isLast: boolean) => {
      if (row.length === 0) return;
      const gaps = SPACING * (row.length - 1);
      const rowRatioSum = row.reduce((acc, r) => acc + r.ratio, 0);
      const naturalW = rowRatioSum * idealRowH + gaps;
      let rowH = idealRowH;
      if (!isLast || naturalW >= usableWidth * 0.68) {
        const computed = (usableWidth - gaps) / Math.max(0.1, rowRatioSum);
        rowH = Math.max(84, Math.min(idealRowH * 1.48, computed));
      }

      let cursorX = HORIZONTAL_PADDING;
      for (const entry of row) {
        const w = Math.round(entry.ratio * rowH);
        const h = Math.round(rowH);
        items.push({ asset: entry.asset, left: cursorX, top: cursorY, width: w, height: h });
        cursorX += w + SPACING;
      }
      cursorY += Math.round(rowH) + SPACING;
    };

    for (const asset of assets) {
      const ratio = Math.max(0.48, Math.min(2.35, getCardEffectiveAspectRatio(asset)));
      if (currentRow.length === 0) {
        currentRow = [{ asset, ratio }];
        sumRatios = ratio;
        continue;
      }

      const gapsAfter = SPACING * currentRow.length;
      const naturalAfter = (sumRatios + ratio) * idealRowH + gapsAfter;

      if (naturalAfter >= usableWidth) {
        const gapsBefore = SPACING * (currentRow.length - 1);
        const hBefore = (usableWidth - gapsBefore) / Math.max(0.1, sumRatios);
        const hAfter = (usableWidth - gapsAfter) / Math.max(0.1, sumRatios + ratio);

        if (Math.abs(hAfter - idealRowH) < Math.abs(hBefore - idealRowH) && hAfter >= idealRowH * 0.68) {
          currentRow.push({ asset, ratio });
          flushRow(currentRow, false);
          currentRow = [];
          sumRatios = 0;
        } else {
          flushRow(currentRow, false);
          currentRow = [{ asset, ratio }];
          sumRatios = ratio;
        }
      } else {
        currentRow.push({ asset, ratio });
        sumRatios += ratio;
      }
    }

    flushRow(currentRow, true);
    return { items, totalHeight: Math.max(240, cursorY + 96) };
  }, [assets, viewportWidth, targetColumnWidth]);

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

  return (
    <div
      ref={containerRef}
      onClick={(e) => {
        if (!(e.target as HTMLElement).closest('[data-asset-card-id]')) {
          clearSelection();
        }
      }}
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
    </div>
  );
};
