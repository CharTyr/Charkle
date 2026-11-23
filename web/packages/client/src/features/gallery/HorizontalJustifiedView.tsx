import React, { useCallback, useEffect, useLayoutEffect, useMemo, useRef, useState } from 'react';
import type { AssetRecord, UUID } from '@charkle/shared';
import { notifyLiveScrolling } from '../../components/HoverMediaPreview';
import { prefersReducedMotion } from '../../design-system';
import { useCoordinatorStore } from '../../stores/coordinatorStore';
import { useLibraryStore } from '../../stores/libraryStore';
import { AssetCard } from './AssetCard';
import { getCardEffectiveAspectRatio } from './assetCardUtils';
import { GalleryCanvasMenu } from './GalleryCanvasMenu';
import {
  anchoredScrollY,
  buildPrefixMaxBottom,
  pickSessionZoomAnchor,
  revealScrollY,
  steppedColumnWidth,
  visibleItemsBinaryRange,
} from './galleryZoomMath';
import type { LayoutRect, SessionZoomAnchor, ZoomLayoutItem } from './galleryZoomMath';
import { useGalleryNavigationAndMarquee } from './useGalleryNavigationAndMarquee';

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
const PINCH_ZOOM_IN_THRESHOLD = 1.15;
const PINCH_ZOOM_OUT_THRESHOLD = 0.87;

export const HorizontalJustifiedView: React.FC<HorizontalJustifiedViewProps> = ({
  assets,
  scrollContainerRef,
}) => {
  const targetColumnWidth = useCoordinatorStore((s) => s.targetColumnWidth);
  const setTargetColumnWidth = useCoordinatorStore((s) => s.setTargetColumnWidth);
  const pendingGalleryReveal = useCoordinatorStore((s) => s.pendingGalleryReveal);
  const clearPendingGalleryReveal = useCoordinatorStore((s) => s.clearPendingGalleryReveal);

  const selectedAssetIDs = useLibraryStore((s) => s.selectedAssetIDs);
  const cutAssetIDs = useLibraryStore((s) => s.cutAssetIDs);
  const exitingAssetIDs = useLibraryStore((s) => s.exitingAssetIDs);
  const cacheBust = useLibraryStore((s) => s.cacheBustVersion);
  const selectAsset = useLibraryStore((s) => s.selectAsset);

  const containerRef = useRef<HTMLDivElement | null>(null);
  const opticalLayerRef = useRef<HTMLDivElement | null>(null);
  const cardElsRef = useRef<Map<UUID, HTMLDivElement>>(new Map());
  const activeAnimsRef = useRef<Map<UUID, Animation>>(new Map());

  const [viewportWidth, setViewportWidth] = useState(960);
  const [scrollTop, setScrollTop] = useState(0);
  const [viewportHeight, setViewportHeight] = useState(800);
  const [spotlightAssetID, setSpotlightAssetID] = useState<UUID | null>(null);
  const [elevatedAnchorID, setElevatedAnchorID] = useState<UUID | null>(null);

  const sessionZoomAnchorRef = useRef<SessionZoomAnchor | null>(null);
  const pendingWheelCursorRef = useRef<{ clientX: number; clientY: number } | null>(null);
  const pendingOpticalRebaseRef = useRef<{
    opticalScale: number;
    anchorScreenY: number;
  } | null>(null);
  const opticalScaleRef = useRef(1);
  const opticalOriginRef = useRef({ x: 480, y: 300, screenY: 300 });
  const pinchSettleTimerRef = useRef<number | null>(null);
  const programmaticScrollUntilRef = useRef(0);
  const isLiveScrollingRef = useRef(false);
  const liveScrollTimerRef = useRef<number | null>(null);
  const anchorLiftTimerRef = useRef<number | null>(null);
  const prevZoomSnapshotRef = useRef<{
    colWidth: number;
    viewportWidth: number;
    scrollTop: number;
    containerOffsetTop: number;
    rectByID: Map<UUID, LayoutRect>;
    docItems: ZoomLayoutItem[];
  } | null>(null);

  const resetOpticalTransform = useCallback((animate = false) => {
    const layer = opticalLayerRef.current;
    opticalScaleRef.current = 1;
    if (!layer) return;
    if (animate && !prefersReducedMotion()) {
      layer.style.transition = 'transform 180ms var(--ease-spring)';
      layer.style.transform = '';
      window.setTimeout(() => {
        if (opticalLayerRef.current) opticalLayerRef.current.style.transition = '';
      }, 190);
    } else {
      layer.style.transition = '';
      layer.style.transform = '';
    }
  }, []);

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
    const syncViewport = () => {
      setScrollTop(scroller.scrollTop);
      setViewportHeight(scroller.clientHeight || 800);
    };
    const onScroll = () => {
      if (performance.now() >= programmaticScrollUntilRef.current) {
        sessionZoomAnchorRef.current = null;
        isLiveScrollingRef.current = true;
        if (liveScrollTimerRef.current !== null) window.clearTimeout(liveScrollTimerRef.current);
        liveScrollTimerRef.current = window.setTimeout(() => {
          isLiveScrollingRef.current = false;
        }, 120);
      }
      notifyLiveScrolling();
      syncViewport();
    };
    syncViewport();
    scroller.addEventListener('scroll', onScroll, { passive: true });
    window.addEventListener('resize', syncViewport);
    return () => {
      scroller.removeEventListener('scroll', onScroll);
      window.removeEventListener('resize', syncViewport);
      if (liveScrollTimerRef.current !== null) window.clearTimeout(liveScrollTimerRef.current);
      if (anchorLiftTimerRef.current !== null) window.clearTimeout(anchorLiftTimerRef.current);
      if (pinchSettleTimerRef.current !== null) window.clearTimeout(pinchSettleTimerRef.current);
    };
  }, [scrollContainerRef]);

  useEffect(() => {
    sessionZoomAnchorRef.current = null;
  }, [selectedAssetIDs]);

  // Cmd/Ctrl + Wheel & Trackpad Continuous Optical Pinch with Hysteresis & Optical Rebase
  useEffect(() => {
    const scroller = scrollContainerRef.current;
    if (!scroller) return;
    const onWheel = (e: WheelEvent) => {
      if (!e.metaKey && !e.ctrlKey) return;
      if (useCoordinatorStore.getState().isOverlayPresented()) return;
      e.preventDefault();

      pendingWheelCursorRef.current = { clientX: e.clientX, clientY: e.clientY };
      const container = containerRef.current;
      const layer = opticalLayerRef.current;
      const scrollerRect = scroller.getBoundingClientRect();
      const screenY = e.clientY - scrollerRect.top;
      const localX = container ? e.clientX - container.getBoundingClientRect().left : e.clientX;
      const localY = container ? e.clientY - container.getBoundingClientRect().top : e.clientY;
      opticalOriginRef.current = { x: localX, y: localY, screenY };

      const reduced = prefersReducedMotion();
      const clampedDelta = Math.max(-45, Math.min(45, e.deltaY));
      const mult = Math.exp(-clampedDelta * (e.deltaMode === 0 ? 0.0065 : 0.09));
      const nextOptical = Math.max(0.76, Math.min(1.34, opticalScaleRef.current * mult));
      opticalScaleRef.current = nextOptical;

      if (pinchSettleTimerRef.current !== null) {
        window.clearTimeout(pinchSettleTimerRef.current);
        pinchSettleTimerRef.current = null;
      }

      const curColWidth = useCoordinatorStore.getState().targetColumnWidth;
      const widthForStep = container?.clientWidth || viewportWidth;

      if (nextOptical >= PINCH_ZOOM_IN_THRESHOLD) {
        const nextWidth = steppedColumnWidth(widthForStep, curColWidth, -1, SPACING, HORIZONTAL_PADDING);
        if (nextWidth !== curColWidth) {
          pendingOpticalRebaseRef.current = { opticalScale: nextOptical, anchorScreenY: screenY };
          resetOpticalTransform(false);
          setTargetColumnWidth(nextWidth);
          return;
        }
      } else if (nextOptical <= PINCH_ZOOM_OUT_THRESHOLD) {
        const nextWidth = steppedColumnWidth(widthForStep, curColWidth, 1, SPACING, HORIZONTAL_PADDING);
        if (nextWidth !== curColWidth) {
          pendingOpticalRebaseRef.current = { opticalScale: nextOptical, anchorScreenY: screenY };
          resetOpticalTransform(false);
          setTargetColumnWidth(nextWidth);
          return;
        }
      }

      if (!reduced && layer) {
        layer.style.transition = '';
        layer.style.transformOrigin = `${localX}px ${localY}px`;
        layer.style.transform = `scale(${nextOptical.toFixed(4)})`;
      }

      pinchSettleTimerRef.current = window.setTimeout(() => {
        pinchSettleTimerRef.current = null;
        resetOpticalTransform(true);
      }, 150);
    };
    scroller.addEventListener('wheel', onWheel, { passive: false });
    return () => scroller.removeEventListener('wheel', onWheel);
  }, [scrollContainerRef, setTargetColumnWidth, viewportWidth, resetOpticalTransform]);

  // Horizontal Justified Row Packer + Prefix Max Bottom for O(log N + K) Visibility
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

        if (
          Math.abs(hAfter - idealRowH) < Math.abs(hBefore - idealRowH) &&
          hAfter >= idealRowH * 0.68
        ) {
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
    const prefixMaxBottom = buildPrefixMaxBottom(items);
    const navItems: ZoomLayoutItem[] = items.map((it) => ({
      id: it.asset.id,
      left: it.left,
      top: it.top,
      width: it.width,
      height: it.height,
    }));
    return { items, navItems, prefixMaxBottom, totalHeight: Math.max(240, cursorY + 96) };
  }, [assets, viewportWidth, targetColumnWidth]);

  const clearZoomAnchor = useCallback(() => {
    sessionZoomAnchorRef.current = null;
  }, []);

  const {
    marquee,
    canvasMenuPoint,
    setCanvasMenuPoint,
    handleCanvasMouseDown,
    handleCanvasContextMenu,
  } = useGalleryNavigationAndMarquee({
    layoutItems: layout.navItems,
    containerRef,
    scrollContainerRef,
    onResetZoomAnchor: clearZoomAnchor,
  });

  // Synchronous Pre-Paint Anchor-Locked Scroll + Optical Rebase + Clean WAAPI FLIP Reflow
  useLayoutEffect(() => {
    const scroller = scrollContainerRef.current;
    const container = containerRef.current;
    if (!scroller || !container) return;

    const containerOffsetTop = container.offsetTop;
    const currentRectByID = new Map<UUID, LayoutRect>();
    const currentDocItems: ZoomLayoutItem[] = layout.items.map((item) => {
      const docRect: LayoutRect = {
        left: item.left,
        top: containerOffsetTop + item.top,
        width: item.width,
        height: item.height,
      };
      currentRectByID.set(item.asset.id, docRect);
      return { id: item.asset.id, ...docRect };
    });

    const prev = prevZoomSnapshotRef.current;
    const isZoomStep = prev !== null && prev.colWidth !== targetColumnWidth && layout.items.length > 0;

    if (isZoomStep && prev) {
      const oldScrollY = scroller.scrollTop;
      const vh = scroller.clientHeight || viewportHeight;
      const topInset = prev.containerOffsetTop + 8;

      let pointerDocPoint: { x: number; y: number } | null = null;
      const pendingCursor = pendingWheelCursorRef.current;
      pendingWheelCursorRef.current = null;
      if (pendingCursor) {
        const scrollerRect = scroller.getBoundingClientRect();
        pointerDocPoint = {
          x: pendingCursor.clientX - scrollerRect.left,
          y: pendingCursor.clientY - scrollerRect.top + oldScrollY,
        };
      }

      const opticalRebase = pendingOpticalRebaseRef.current;
      pendingOpticalRebaseRef.current = null;

      const picked = pickSessionZoomAnchor({
        items: prev.docItems,
        scrollTop: oldScrollY,
        viewportHeight: vh,
        viewportWidth: prev.viewportWidth,
        topInset,
        pointerPoint: pointerDocPoint,
        selectedAssetIDs,
        existingAnchor: sessionZoomAnchorRef.current,
        forceCursorLookup: Boolean(pointerDocPoint),
      });

      if (picked) {
        sessionZoomAnchorRef.current = picked.anchor;
        const newAnchorRect = currentRectByID.get(picked.anchor.assetID);
        if (newAnchorRect) {
          const nextScrollY = anchoredScrollY({
            oldScrollY,
            oldAnchorRect: picked.item,
            newAnchorRect,
            anchorNormV: picked.anchor.normV,
            anchorScreenY: picked.anchor.screenY,
            topInset,
            totalHeight: containerOffsetTop + layout.totalHeight,
            viewportHeight: vh,
            newOpticalScale: 1,
            opticalAnchorScreenY: opticalRebase?.anchorScreenY ?? 0,
          });

          if (Math.abs(nextScrollY - oldScrollY) > 0.5) {
            programmaticScrollUntilRef.current = performance.now() + 90;
            scroller.scrollTop = nextScrollY;
            setScrollTop(nextScrollY);
          }

          const reduced = prefersReducedMotion();
          if (!reduced && !isLiveScrollingRef.current) {
            setElevatedAnchorID(picked.anchor.assetID);
            if (anchorLiftTimerRef.current !== null) {
              window.clearTimeout(anchorLiftTimerRef.current);
            }
            anchorLiftTimerRef.current = window.setTimeout(() => {
              setElevatedAnchorID(null);
            }, 260);

            const anchorID = picked.anchor.assetID;
            const prevScale = opticalRebase?.opticalScale ?? 1;
            const optOrigin = opticalOriginRef.current;

            for (const [assetID, el] of cardElsRef.current) {
              const running = activeAnimsRef.current.get(assetID);
              if (running) {
                running.cancel();
                activeAnimsRef.current.delete(assetID);
              }

              const oldRect = prev.rectByID.get(assetID);
              const newRect = currentRectByID.get(assetID);
              if (!oldRect || !newRect) continue;

              const newLocalX = newRect.left;
              const newLocalY = newRect.top - containerOffsetTop;

              const oldLocalX = oldRect.left;
              const oldLocalY = oldRect.top - prev.containerOffsetTop;
              const projOldX =
                prevScale !== 1 ? optOrigin.x + (oldLocalX - optOrigin.x) * prevScale : oldLocalX;
              const projOldY =
                prevScale !== 1 ? optOrigin.y + (oldLocalY - optOrigin.y) * prevScale : oldLocalY;
              const projOldW = oldRect.width * prevScale;
              const projOldH = oldRect.height * prevScale;

              const oldScreenY = prev.containerOffsetTop + projOldY - oldScrollY;
              const newScreenY = newRect.top - nextScrollY;
              const dx = projOldX - newRect.left;
              const dy = oldScreenY - newScreenY;

              if (
                Math.abs(dx) < 0.5 &&
                Math.abs(dy) < 0.5 &&
                Math.abs(projOldW - newRect.width) < 0.5
              ) {
                continue;
              }

              const dist = Math.hypot(dx, dy);
              let anim: Animation;
              if (assetID !== anchorID && dist > vh * 0.75) {
                anim = el.animate(
                  [
                    {
                      opacity: 0.15,
                      transform: `translate3d(${newLocalX}px, ${newLocalY}px, 0) scale(0.96)`,
                    },
                    {
                      opacity: 1,
                      transform: `translate3d(${newLocalX}px, ${newLocalY}px, 0) scale(1)`,
                    },
                  ],
                  {
                    duration: 190,
                    easing: 'cubic-bezier(0.23, 1, 0.32, 1)',
                    fill: 'none',
                  },
                );
              } else {
                const sx = projOldW / Math.max(1, newRect.width);
                const sy = projOldH / Math.max(1, newRect.height);
                el.style.transformOrigin = 'top left';
                anim = el.animate(
                  [
                    {
                      transform: `translate3d(${newLocalX + dx}px, ${newLocalY + dy}px, 0) scale(${sx}, ${sy})`,
                    },
                    {
                      transform: `translate3d(${newLocalX}px, ${newLocalY}px, 0) scale(1, 1)`,
                    },
                  ],
                  {
                    duration: 240,
                    easing: 'cubic-bezier(0.77, 0, 0.175, 1)',
                    fill: 'none',
                  },
                );
              }
              activeAnimsRef.current.set(assetID, anim);
              anim.onfinish = () => {
                if (activeAnimsRef.current.get(assetID) === anim) {
                  activeAnimsRef.current.delete(assetID);
                }
              };
            }
          }
        }
      }
    }

    prevZoomSnapshotRef.current = {
      colWidth: targetColumnWidth,
      viewportWidth,
      scrollTop: scroller.scrollTop,
      containerOffsetTop,
      rectByID: currentRectByID,
      docItems: currentDocItems,
    };
  }, [layout, targetColumnWidth, viewportWidth, viewportHeight, scrollContainerRef, selectedAssetIDs]);

  // Handle Reveal-in-Library centering + Cobalt Spotlight Pulse
  useEffect(() => {
    if (!pendingGalleryReveal) return;
    const scroller = scrollContainerRef.current;
    const container = containerRef.current;
    if (!scroller || !container) return;

    const target = layout.items.find((item) => item.asset.id === pendingGalleryReveal.assetID);
    if (!target) return;

    sessionZoomAnchorRef.current = null;
    const containerOffsetTop = container.offsetTop;
    const topInset = containerOffsetTop + 8;
    const targetScrollY = revealScrollY({
      itemRect: {
        left: target.left,
        top: containerOffsetTop + target.top,
        width: target.width,
        height: target.height,
      },
      topInset,
      bottomInset: 72,
      totalHeight: containerOffsetTop + layout.totalHeight,
      viewportHeight: scroller.clientHeight || viewportHeight,
    });

    scroller.scrollTo({
      top: targetScrollY,
      behavior: prefersReducedMotion() ? 'auto' : 'smooth',
    });
    setScrollTop(targetScrollY);
    setSpotlightAssetID(pendingGalleryReveal.assetID);
    clearPendingGalleryReveal(pendingGalleryReveal.nonce);

    const timer = window.setTimeout(() => {
      setSpotlightAssetID((cur) => (cur === pendingGalleryReveal.assetID ? null : cur));
    }, 950);
    return () => window.clearTimeout(timer);
  }, [pendingGalleryReveal, layout, scrollContainerRef, viewportHeight, clearPendingGalleryReveal]);

  // O(log N + K) binary-search virtualized visible slice
  const visibleItems = useMemo(() => {
    const offsetTop = containerRef.current?.offsetTop ?? 0;
    const localScrollTop = Math.max(0, scrollTop - offsetTop);
    const minY = localScrollTop - OVERSCAN_PX;
    const maxY = localScrollTop + viewportHeight + OVERSCAN_PX;
    return visibleItemsBinaryRange(layout.items, layout.prefixMaxBottom, minY, maxY);
  }, [layout.items, layout.prefixMaxBottom, scrollTop, viewportHeight]);

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
      data-gallery-stage="true"
      onMouseDown={handleCanvasMouseDown}
      onContextMenu={handleCanvasContextMenu}
      className="relative w-full select-none"
      style={{ height: layout.totalHeight }}
    >
      <div ref={opticalLayerRef} className="relative w-full h-full">
        {visibleItems.map((item) => {
          const isElevated = elevatedAnchorID === item.asset.id;
          return (
            <AssetCard
              key={item.asset.id}
              cardRef={(el) => {
                if (el) cardElsRef.current.set(item.asset.id, el);
                else cardElsRef.current.delete(item.asset.id);
              }}
              asset={item.asset}
              selected={selectedAssetIDs.has(item.asset.id)}
              isCut={cutAssetIDs.has(item.asset.id)}
              isExiting={exitingAssetIDs.has(item.asset.id)}
              isSpotlighted={spotlightAssetID === item.asset.id}
              cacheBust={cacheBust}
              onSelect={handleSelect}
              style={{
                position: 'absolute',
                transform: `translate3d(${item.left}px, ${item.top}px, 0)`,
                width: item.width,
                height: item.height,
                zIndex: isElevated ? 30 : undefined,
              }}
            />
          );
        })}
      </div>

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

      {/* Empty-Canvas Context Menu */}
      <GalleryCanvasMenu point={canvasMenuPoint} onClose={() => setCanvasMenuPoint(null)} />
    </div>
  );
};
