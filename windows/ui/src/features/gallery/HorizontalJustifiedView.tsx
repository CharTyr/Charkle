import React, { useCallback, useEffect, useLayoutEffect, useMemo, useRef, useState } from 'react';
import { Clipboard } from 'lucide-react';
import { getTransport } from '../../api/transport';
import { Popover } from '../../design-system';
import { useCoordinatorStore, useLibraryStore } from '../../stores';
import type { AssetRecord } from '../../types/domain';
import { AssetCard } from './AssetCard';
import {
  anchoredScrollY,
  computeHorizontalJustified,
  revealScrollY,
  runFlipZoomAnimations,
  snappedJustifiedTargetWidth,
  steppedColumnWidth,
  visibleItemsInRange,
  type PlacedAssetFrame,
  type ZoomAnchorState,
} from './masonryLayout';

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
  topInset = 0,
  bottomInset = 0,
): { items: JustifiedPlacedItem[]; totalHeight: number } {
  const result = computeHorizontalJustified(
    assets,
    containerWidth,
    targetRowHeight,
    gap,
    topInset,
    bottomInset,
  );
  return { items: result.items, totalHeight: result.totalHeight };
}

export interface HorizontalJustifiedViewProps {
  assets: AssetRecord[];
  cardScale: number;
  topInset?: number;
  bottomInset?: number;
}

/**
 * High-FPS O(log N) virtualized Horizontal Justified layout matching macOS `VirtualizedMasonryView.swift`:
 * - Snaps density to macOS's 8 logarithmic stops so slider/wheel zoom never thrashes row line-breaks
 * - Non-passive `Ctrl+Wheel` zoom + exact-asset persistent zoom anchor + pure GPU WAAPI FLIP glide
 * - Row-1 stays flush beneath `topInset` at top; Row-2+ stays pinned under the user's eye
 * - Zero `width`/`height` CSS transitions + Moodboard Reveal centering + empty-space Paste menu
 */
export const HorizontalJustifiedView: React.FC<HorizontalJustifiedViewProps> = ({
  assets,
  cardScale,
  topInset = 0,
  bottomInset = 44,
}) => {
  const scrollRef = useRef<HTMLDivElement | null>(null);
  const contentRef = useRef<HTMLDivElement | null>(null);
  const cardElementsRef = useRef<Map<string, HTMLDivElement>>(new Map());
  const hoveredAssetIdRef = useRef<string | null>(null);
  const sessionZoomAnchorRef = useRef<ZoomAnchorState | null>(null);
  const prevSnappedStopRef = useRef<number>(0);
  const prevLayoutRef = useRef<Map<string, PlacedAssetFrame>>(new Map());
  const prevScrollTopRef = useRef<number>(0);
  const pendingFlipRef = useRef<{
    prevLayout: Map<string, PlacedAssetFrame>;
    oldScrollY: number;
    newScrollY: number;
    anchorAssetId: string | null;
    columnWidth: number;
  } | null>(null);
  const programmaticScrollRef = useRef<boolean>(false);
  const wheelAccumRef = useRef<number>(0);
  const lastWheelStepAtRef = useRef<number>(0);
  const cardScaleRef = useRef<number>(cardScale);
  cardScaleRef.current = cardScale;

  const marqueeRef = useRef<{
    startX: number;
    startY: number;
    baseSelection: string[];
  } | null>(null);
  const layoutRef = useRef<ReturnType<typeof computeHorizontalJustified> | null>(null);
  const [viewport, setViewport] = useState({ width: 1080, height: 760 });
  const [scrollTop, setScrollTop] = useState(0);
  const [marquee, setMarquee] = useState<{
    startX: number;
    startY: number;
    currentX: number;
    currentY: number;
    baseSelection: string[];
  } | null>(null);
  const [zoomAnchorId, setZoomAnchorId] = useState<string | null>(null);
  const [spotlightId, setSpotlightId] = useState<string | null>(null);
  const [emptyMenuPoint, setEmptyMenuPoint] = useState<{ x: number; y: number } | null>(null);

  const destination = useCoordinatorStore((s) => s.destination);
  const selectedAssetIds = useCoordinatorStore((s) => s.selectedAssetIds);
  const setSelection = useCoordinatorStore((s) => s.setSelection);
  const clearSelection = useCoordinatorStore((s) => s.clearSelection);
  const setCardScale = useCoordinatorStore((s) => s.setCardScale);
  const pendingGalleryReveal = useCoordinatorStore((s) => s.pendingGalleryReveal);
  const clearPendingGalleryReveal = useCoordinatorStore((s) => s.clearPendingGalleryReveal);
  const pushToast = useCoordinatorStore((s) => s.pushToast);

  const refreshAll = useLibraryStore((s) => s.refreshAll);

  const selectedSet = useMemo(() => new Set(selectedAssetIds), [selectedAssetIds]);
  const orderedIds = useMemo(() => assets.map((a) => a.id), [assets]);
  const destinationKey =
    destination.type === 'folder' ||
    destination.type === 'smartFolder' ||
    destination.type === 'moodboard'
      ? `${destination.type}:${destination.id}`
      : destination.type === 'tag'
        ? `tag:${destination.name}`
        : destination.type;
  const prevDestKeyRef = useRef<string>(destinationKey);

  const snappedStop = useMemo(() => snappedJustifiedTargetWidth(cardScale), [cardScale]);
  const targetRowHeight = useMemo(
    () => Math.max(116, Math.min(360, Math.round(snappedStop * 0.92))),
    [snappedStop],
  );

  useEffect(() => {
    sessionZoomAnchorRef.current = null;
  }, [selectedAssetIds, assets, viewport.width]);

  useEffect(() => {
    const el = scrollRef.current;
    if (!el) return;
    const measure = () => {
      const w = el.clientWidth;
      const h = el.clientHeight;
      if (w > 0 && h > 0) {
        const usableW = Math.max(260, w - 32);
        setViewport((prev) =>
          Math.abs(prev.width - usableW) >= 1 || Math.abs(prev.height - h) >= 1
            ? { width: usableW, height: h }
            : prev,
        );
      }
    };
    measure();
    if (typeof ResizeObserver === 'undefined') return;
    const obs = new ResizeObserver(measure);
    obs.observe(el);
    return () => obs.disconnect();
  }, []);

  // Non-passive Ctrl+Wheel zoom stepping by exact logarithmic stop
  useEffect(() => {
    const el = scrollRef.current;
    if (!el) return;
    const handleWheel = (e: WheelEvent) => {
      if (!e.ctrlKey && !e.metaKey) return;
      e.preventDefault();
      e.stopPropagation();

      const now = performance.now();
      const isDiscreteWheel = e.deltaMode !== 0 || Math.abs(e.deltaY) >= 40;
      const rawDelta = isDiscreteWheel ? -Math.sign(e.deltaY) : -e.deltaY / 28;
      if (Math.abs(rawDelta) < 0.005) return;

      if (isDiscreteWheel) {
        if (now - lastWheelStepAtRef.current < 120) return;
        const dir = rawDelta > 0 ? 1 : -1;
        const nextWidth = steppedColumnWidth(
          cardScaleRef.current,
          dir,
          'horizontalJustified',
          Math.max(260, el.clientWidth - 32),
          12,
        );
        lastWheelStepAtRef.current = now;
        wheelAccumRef.current = 0;
        if (Math.abs(nextWidth - cardScaleRef.current) >= 0.5) {
          setCardScale(nextWidth);
        }
        return;
      }

      if (
        (wheelAccumRef.current > 0 && rawDelta < 0) ||
        (wheelAccumRef.current < 0 && rawDelta > 0)
      ) {
        wheelAccumRef.current = 0;
      }
      wheelAccumRef.current += rawDelta;
      if (Math.abs(wheelAccumRef.current) < 0.85 || now - lastWheelStepAtRef.current < 150) {
        return;
      }
      const dir = wheelAccumRef.current > 0 ? 1 : -1;
      wheelAccumRef.current = 0;
      lastWheelStepAtRef.current = now;
      const nextWidth = steppedColumnWidth(
        cardScaleRef.current,
        dir,
        'horizontalJustified',
        Math.max(260, el.clientWidth - 32),
        12,
      );
      if (Math.abs(nextWidth - cardScaleRef.current) >= 0.5) {
        setCardScale(nextWidth);
      }
    };

    el.addEventListener('wheel', handleWheel, { passive: false });
    return () => el.removeEventListener('wheel', handleWheel);
  }, [setCardScale]);

  const layout = useMemo(
    () =>
      computeHorizontalJustified(
        assets,
        viewport.width,
        targetRowHeight,
        12,
        topInset,
        bottomInset,
      ),
    [assets, viewport.width, targetRowHeight, topInset, bottomInset],
  );
  layoutRef.current = layout;

  const layoutMap = useMemo(() => {
    const map = new Map<string, PlacedAssetFrame>();
    for (const item of layout.items) map.set(item.asset.id, item);
    return map;
  }, [layout.items]);

  const visibleItems = useMemo(() => {
    const maxScroll = Math.max(0, layout.totalHeight - viewport.height);
    const effectiveScrollTop = Math.min(scrollTop, maxScroll);
    const overscan = Math.max(520, viewport.height * 0.9);
    const minY = Math.max(0, effectiveScrollTop - overscan);
    const maxY = effectiveScrollTop + viewport.height + overscan;
    return visibleItemsInRange(layout, minY, maxY);
  }, [layout, scrollTop, viewport.height]);

  useLayoutEffect(() => {
    if (prevDestKeyRef.current === destinationKey) return;
    prevDestKeyRef.current = destinationKey;
    sessionZoomAnchorRef.current = null;
    if (useCoordinatorStore.getState().pendingGalleryReveal) return;
    const el = scrollRef.current;
    if (el && el.scrollTop !== 0) {
      programmaticScrollRef.current = true;
      el.scrollTop = 0;
      requestAnimationFrame(() => {
        programmaticScrollRef.current = false;
      });
    }
    prevScrollTopRef.current = 0;
    setScrollTop(0);
  }, [destinationKey]);

  useLayoutEffect(() => {
    const el = scrollRef.current;
    const vh = el?.clientHeight || viewport.height;
    const maxScroll = Math.max(0, layout.totalHeight - vh);
    if (scrollTop > maxScroll + 1 || (el && el.scrollTop > maxScroll + 1)) {
      programmaticScrollRef.current = true;
      if (el) el.scrollTop = maxScroll;
      prevScrollTopRef.current = maxScroll;
      setScrollTop(maxScroll);
      requestAnimationFrame(() => {
        programmaticScrollRef.current = false;
      });
    }
  }, [layout.totalHeight, viewport.height, scrollTop]);

  useLayoutEffect(() => {
    const el = scrollRef.current;
    const prevStop = prevSnappedStopRef.current;
    prevSnappedStopRef.current = snappedStop;

    if (
      el &&
      prevStop > 0 &&
      prevStop !== snappedStop &&
      prevLayoutRef.current.size > 0
    ) {
      const oldScrollY = prevScrollTopRef.current;
      const vh = el.clientHeight || viewport.height;

      let anchor = sessionZoomAnchorRef.current;
      if (!anchor || !layoutMap.has(anchor.assetId)) {
        let pick: PlacedAssetFrame | undefined;
        if (hoveredAssetIdRef.current) pick = prevLayoutRef.current.get(hoveredAssetIdRef.current);
        if (!pick) {
          const visMidX = viewport.width * 0.5;
          const visMidY = oldScrollY + vh * 0.5;
          let bestDist = Infinity;
          for (const selId of selectedAssetIds) {
            const c = prevLayoutRef.current.get(selId);
            if (c && c.y + c.height > oldScrollY && c.y < oldScrollY + vh) {
              const d = Math.hypot(c.x + c.width * 0.5 - visMidX, c.y + c.height * 0.5 - visMidY);
              if (d < bestDist) {
                bestDist = d;
                pick = c;
              }
            }
          }
        }
        if (!pick) {
          const visMidX = viewport.width * 0.5;
          const visMidY = oldScrollY + topInset + Math.max(80, vh - topInset) * 0.45;
          let bestDist = Infinity;
          for (const item of prevLayoutRef.current.values()) {
            if (item.y + item.height < oldScrollY || item.y > oldScrollY + vh) continue;
            const d = Math.hypot(
              item.x + item.width * 0.5 - visMidX,
              item.y + item.height * 0.5 - visMidY,
            );
            if (d < bestDist) {
              bestDist = d;
              pick = item;
            }
          }
        }
        if (pick) {
          anchor = {
            assetId: pick.asset.id,
            normV: 0.5,
            screenY: pick.y + pick.height * 0.5 - oldScrollY,
            oldAnchorY: pick.y,
          };
          sessionZoomAnchorRef.current = anchor;
        }
      }

      let nextScrollY = oldScrollY;
      let scrollMutated = false;
      if (anchor) {
        setZoomAnchorId(anchor.assetId);
        const nextItem = layoutMap.get(anchor.assetId);
        if (nextItem) {
          nextScrollY = anchoredScrollY({
            oldScrollY,
            oldAnchorY: anchor.oldAnchorY,
            newAnchorY: nextItem.y,
            newAnchorHeight: nextItem.height,
            anchorNormV: anchor.normV,
            anchorScreenY: anchor.screenY,
            topInset,
            totalHeight: layout.totalHeight,
            viewportHeight: vh,
          });
          if (Math.abs(nextScrollY - el.scrollTop) >= 0.5) {
            scrollMutated = true;
            programmaticScrollRef.current = true;
            el.scrollTop = nextScrollY;
            setScrollTop(nextScrollY);
            prevScrollTopRef.current = nextScrollY;
            requestAnimationFrame(() => {
              programmaticScrollRef.current = false;
            });
          }
        }
      }

      const flipPayload = {
        prevLayout: prevLayoutRef.current,
        oldScrollY,
        newScrollY: nextScrollY,
        anchorAssetId: anchor?.assetId ?? null,
        columnWidth: layout.columnWidth,
      };
      if (scrollMutated) {
        pendingFlipRef.current = flipPayload;
      } else {
        runFlipZoomAnimations({
          visibleItems,
          cardElements: cardElementsRef.current,
          ...flipPayload,
        });
      }
    } else if (pendingFlipRef.current) {
      const pending = pendingFlipRef.current;
      pendingFlipRef.current = null;
      runFlipZoomAnimations({
        visibleItems,
        cardElements: cardElementsRef.current,
        ...pending,
      });
    }

    prevLayoutRef.current = layoutMap;
  }, [
    snappedStop,
    layout.totalHeight,
    layout.columnWidth,
    layoutMap,
    selectedAssetIds,
    topInset,
    viewport.height,
    viewport.width,
    visibleItems,
  ]);

  useEffect(() => {
    if (!pendingGalleryReveal) return;
    const item = layoutMap.get(pendingGalleryReveal.assetId);
    const el = scrollRef.current;
    if (!item || !el) return;

    sessionZoomAnchorRef.current = null;
    const targetTop = revealScrollY({
      itemY: item.y,
      itemHeight: item.height,
      topInset,
      bottomInset,
      totalHeight: layout.totalHeight,
      viewportHeight: el.clientHeight || viewport.height,
    });
    programmaticScrollRef.current = true;
    if (typeof el.scrollTo === 'function') {
      el.scrollTo({ top: targetTop, behavior: 'smooth' });
    } else {
      el.scrollTop = targetTop;
    }
    setScrollTop(targetTop);
    prevScrollTopRef.current = targetTop;
    requestAnimationFrame(() => {
      programmaticScrollRef.current = false;
    });

    setSpotlightId(pendingGalleryReveal.assetId);
    clearPendingGalleryReveal();
    const timer = window.setTimeout(() => {
      setSpotlightId((prev) => (prev === pendingGalleryReveal.assetId ? null : prev));
    }, 1600);
    return () => window.clearTimeout(timer);
  }, [
    pendingGalleryReveal,
    layoutMap,
    layout.totalHeight,
    topInset,
    bottomInset,
    viewport.height,
    clearPendingGalleryReveal,
  ]);

  const handleHoverChange = useCallback((assetId: string, hovering: boolean) => {
    if (hovering) hoveredAssetIdRef.current = assetId;
    else if (hoveredAssetIdRef.current === assetId) hoveredAssetIdRef.current = null;
  }, []);

  const handleCardRef = useCallback((assetId: string, el: HTMLDivElement | null) => {
    if (el) cardElementsRef.current.set(assetId, el);
    else cardElementsRef.current.delete(assetId);
  }, []);

  const marqueeActive = marquee !== null;
  useEffect(() => {
    if (!marqueeActive) return;
    const handleMove = (e: MouseEvent) => {
      const origin = marqueeRef.current;
      const content = contentRef.current;
      const currentLayout = layoutRef.current;
      if (!origin || !content || !currentLayout) return;
      const rect = content.getBoundingClientRect();
      const cx = e.clientX - rect.left;
      const cy = e.clientY - rect.top;
      setMarquee((prev) => (prev ? { ...prev, currentX: cx, currentY: cy } : null));

      const left = Math.min(origin.startX, cx);
      const right = Math.max(origin.startX, cx);
      const top = Math.min(origin.startY, cy);
      const bottom = Math.max(origin.startY, cy);
      if (right - left > 4 || bottom - top > 4) {
        const hit = new Set<string>(origin.baseSelection);
        const candidates = visibleItemsInRange(currentLayout, top, bottom);
        for (const item of candidates) {
          if (
            item.x < right &&
            item.x + item.width > left &&
            item.y < bottom &&
            item.y + item.height > top
          ) {
            hit.add(item.asset.id);
          }
        }
        setSelection(Array.from(hit));
      }
    };
    const handleUp = () => {
      marqueeRef.current = null;
      setMarquee(null);
    };
    const handleKeyDown = (e: KeyboardEvent) => {
      if (e.key === 'Escape') {
        e.preventDefault();
        e.stopImmediatePropagation();
        handleUp();
      }
    };
    window.addEventListener('mousemove', handleMove);
    window.addEventListener('mouseup', handleUp);
    window.addEventListener('blur', handleUp);
    window.addEventListener('keydown', handleKeyDown, true);
    return () => {
      window.removeEventListener('mousemove', handleMove);
      window.removeEventListener('mouseup', handleUp);
      window.removeEventListener('blur', handleUp);
      window.removeEventListener('keydown', handleKeyDown, true);
    };
  }, [marqueeActive, setSelection]);

  const marqueeBox = marquee
    ? {
        left: Math.min(marquee.startX, marquee.currentX),
        top: Math.min(marquee.startY, marquee.currentY),
        width: Math.abs(marquee.currentX - marquee.startX),
        height: Math.abs(marquee.currentY - marquee.startY),
      }
    : null;

  return (
    <>
      <div
        ref={scrollRef}
        data-testid="gallery-justified-scroll"
        onScroll={(e) => {
          const nextTop = e.currentTarget.scrollTop;
          prevScrollTopRef.current = nextTop;
          if (!programmaticScrollRef.current) {
            sessionZoomAnchorRef.current = null;
          }
          setScrollTop(nextTop);
        }}
        onMouseDown={(e) => {
          if (e.button !== 0) return;
          if (!e.currentTarget.contains(e.target as Node)) return;
          if ((e.target as HTMLElement).closest('[data-asset-id]')) return;
          const content = contentRef.current;
          if (!content) return;
          const rect = content.getBoundingClientRect();
          const x = e.clientX - rect.left;
          const y = e.clientY - rect.top;
          const additive = e.ctrlKey || e.metaKey || e.shiftKey;
          const baseSelection = additive ? [...selectedAssetIds] : [];
          if (!additive) clearSelection();
          marqueeRef.current = { startX: x, startY: y, baseSelection };
          setMarquee({ startX: x, startY: y, currentX: x, currentY: y, baseSelection });
        }}
        onContextMenu={(e) => {
          if (!e.currentTarget.contains(e.target as Node)) return;
          if ((e.target as HTMLElement).closest('[data-asset-id]')) return;
          e.preventDefault();
          setEmptyMenuPoint({ x: e.clientX, y: e.clientY });
        }}
        className="flex-1 min-h-0 overflow-y-auto charkle-scroll px-4 relative"
      >
        <div
          ref={contentRef}
          className="relative w-full"
          style={{ height: Math.max(layout.totalHeight, 120) }}
        >
          {visibleItems.map((item) => {
            const isAnchor = zoomAnchorId === item.asset.id;
            return (
              <AssetCard
                key={item.asset.id}
                asset={item.asset}
                selected={selectedSet.has(item.asset.id)}
                spotlighted={spotlightId === item.asset.id}
                orderedIds={orderedIds}
                width={item.width}
                height={item.height}
                onHoverChange={handleHoverChange}
                cardRefCallback={handleCardRef}
                style={{
                  position: 'absolute',
                  transform: `translate3d(${Math.round(item.x)}px, ${Math.round(item.y)}px, 0)`,
                  top: 0,
                  left: 0,
                  zIndex: isAnchor ? 20 : 1,
                }}
              />
            );
          })}

          {marqueeBox && (marqueeBox.width > 4 || marqueeBox.height > 4) && (
            <div
              aria-hidden="true"
              className="pointer-events-none absolute z-30 rounded-[4px] border border-[var(--accent)] bg-[var(--accent-soft)]"
              style={marqueeBox}
            />
          )}
        </div>
      </div>

      {/* Empty-space Paste context menu matching macOS MasonryDocumentView.menu */}
      <Popover
        open={emptyMenuPoint !== null}
        onOpenChange={(open) => {
          if (!open) setEmptyMenuPoint(null);
        }}
        anchorPoint={emptyMenuPoint}
        className="w-[184px] p-1.5"
      >
        <button
          type="button"
          onClick={async () => {
            setEmptyMenuPoint(null);
            const targetFolderId = destination.type === 'folder' ? destination.id : null;
            try {
              const count = await getTransport().collectClipboardNow(targetFolderId, null);
              if (count > 0) {
                await refreshAll(destination);
                pushToast({ message: `已粘贴导入 ${count} 项素材`, tone: 'success' });
              } else {
                pushToast({ message: '剪贴板中没有可粘贴的素材', tone: 'info' });
              }
            } catch {
              pushToast({ message: '无法读取系统剪贴板', tone: 'error' });
            }
          }}
          className="w-full flex items-center justify-between gap-2 px-2.5 py-1.5 text-[12.5px] rounded-[var(--radius-popover-inner)] text-[var(--text-primary)] hover:bg-[var(--bg-subtle)] cursor-pointer"
        >
          <span className="inline-flex items-center gap-2">
            <Clipboard size={14} className="text-[var(--text-secondary)]" />
            粘贴素材
          </span>
          <kbd className="text-[10.5px] text-[var(--text-tertiary)]">Ctrl+V</kbd>
        </button>
      </Popover>
    </>
  );
};
