import { useCallback, useEffect, useState } from 'react';
import type React from 'react';
import type { UUID } from '@charkle/shared';
import { prefersReducedMotion } from '../../design-system';
import { useCoordinatorStore } from '../../stores/coordinatorStore';
import { useLibraryStore } from '../../stores/libraryStore';
import { isEditableElement } from '../capture/captureUtils';
import { findSpatialArrowTarget } from './galleryZoomMath';
import type { ArrowDirection, ZoomLayoutItem } from './galleryZoomMath';

export interface MarqueeRect {
  startX: number;
  startY: number;
  currentX: number;
  currentY: number;
}

export interface UseGalleryNavigationAndMarqueeParams {
  layoutItems: readonly ZoomLayoutItem[];
  containerRef: React.RefObject<HTMLDivElement | null>;
  scrollContainerRef: React.RefObject<HTMLDivElement | null>;
  onResetZoomAnchor?: () => void;
}

/**
 * Shared gallery interaction controller for Vertical Masonry and Horizontal Justified views:
 * - Spatial 2D keyboard arrow navigation (`↑↓←→` + `Shift` range selection + scroll into view)
 * - Marquee box drag selection
 * - Empty-canvas right-click point tracking (for Paste / Quick Capture menu)
 */
export function useGalleryNavigationAndMarquee({
  layoutItems,
  containerRef,
  scrollContainerRef,
  onResetZoomAnchor,
}: UseGalleryNavigationAndMarqueeParams) {
  const selectAsset = useLibraryStore((s) => s.selectAsset);
  const selectAssetIDs = useLibraryStore((s) => s.selectAssetIDs);
  const clearSelection = useLibraryStore((s) => s.clearSelection);

  const [marquee, setMarquee] = useState<MarqueeRect | null>(null);
  const [canvasMenuPoint, setCanvasMenuPoint] = useState<{ x: number; y: number } | null>(null);

  // Spatial 2D keyboard arrow navigation (`↑↓←→` + `Shift+Arrow`)
  useEffect(() => {
    const onKeyDown = (e: KeyboardEvent) => {
      if (
        e.key !== 'ArrowUp' &&
        e.key !== 'ArrowDown' &&
        e.key !== 'ArrowLeft' &&
        e.key !== 'ArrowRight'
      ) {
        return;
      }
      if (e.metaKey || e.ctrlKey || e.altKey) return;
      if (isEditableElement(e.target)) return;

      const coord = useCoordinatorStore.getState();
      if (coord.isOverlayPresented()) return;
      if (
        document.querySelector('[role="dialog"][aria-modal="true"]') ||
        document.querySelector('[role="menu"]')
      ) {
        return;
      }
      if (layoutItems.length === 0) return;

      const lib = useLibraryStore.getState();
      const currentID =
        lib.lastSelectedAssetID ??
        Array.from(lib.selectedAssetIDs)[0] ??
        null;

      const targetID = findSpatialArrowTarget(layoutItems, currentID, e.key as ArrowDirection);
      if (!targetID) return;

      e.preventDefault();
      e.stopPropagation();

      onResetZoomAnchor?.();
      selectAsset(targetID, e.shiftKey ? 'range' : 'replace');

      // Scroll newly focused card cleanly into the usable viewport
      const scroller = scrollContainerRef.current;
      const container = containerRef.current;
      const targetItem = layoutItems.find((it) => it.id === targetID);
      if (scroller && container && targetItem) {
        const containerTop = container.offsetTop;
        const itemTop = containerTop + targetItem.top;
        const itemBottom = itemTop + targetItem.height;
        const topMargin = containerTop + 16;
        const bottomMargin = 28;
        const curScroll = scroller.scrollTop;
        const vh = scroller.clientHeight || 800;

        let nextScroll: number | null = null;
        if (itemTop < curScroll + topMargin) {
          nextScroll = Math.max(0, itemTop - topMargin);
        } else if (itemBottom > curScroll + vh - bottomMargin) {
          nextScroll = Math.max(0, itemBottom - vh + bottomMargin);
        }

        if (nextScroll !== null) {
          scroller.scrollTo({
            top: nextScroll,
            behavior: prefersReducedMotion() ? 'auto' : 'smooth',
          });
        }
      }
    };

    window.addEventListener('keydown', onKeyDown);
    return () => window.removeEventListener('keydown', onKeyDown);
  }, [layoutItems, containerRef, scrollContainerRef, selectAsset, onResetZoomAnchor]);

  // Marquee drag box selection
  const handleCanvasMouseDown = useCallback(
    (e: React.MouseEvent<HTMLDivElement>) => {
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
        for (const item of layoutItems) {
          const overlaps =
            item.left < x2 &&
            item.left + item.width > x1 &&
            item.top < y2 &&
            item.top + item.height > y1;
          if (overlaps) hit.push(item.id);
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
    },
    [containerRef, clearSelection, layoutItems, selectAssetIDs],
  );

  // Empty-canvas context menu
  const handleCanvasContextMenu = useCallback((e: React.MouseEvent<HTMLDivElement>) => {
    if ((e.target as HTMLElement).closest('[data-asset-card-id]')) return;
    e.preventDefault();
    setCanvasMenuPoint({ x: e.clientX, y: e.clientY });
  }, []);

  return {
    marquee,
    canvasMenuPoint,
    setCanvasMenuPoint,
    handleCanvasMouseDown,
    handleCanvasContextMenu,
  };
}
