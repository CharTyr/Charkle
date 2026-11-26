import React, { useCallback, useEffect, useMemo, useRef, useState } from 'react';
import {
  Add16Filled,
  Checkmark16Filled,
  CheckmarkCircle16Filled,
  Eye16Regular,
  VideoClip16Filled,
} from '@fluentui/react-icons';
import { isTauriRuntime } from '../../api/transport';
import { usePinterestStore } from '../../stores/pinterestStore';
import { resolveSocialMediaUrl, type PinterestPin } from '../../types/domain';
import {
  SPATIAL_CAMERA_DEFAULT_SCALE,
  SPATIAL_CAMERA_MAX_SCALE,
  SPATIAL_CAMERA_MIN_SCALE,
  cameraVisibleWorldRect,
  cameraZoomAt,
  createCenteredCamera,
  pinDisplayImageUrl,
  pinDisplayTitle,
  type InfiniteSpatialCamera,
  type PinterestSpatialCard,
  type SpatialSize,
} from './spatialLayout';

interface PinterestInfiniteCanvasProps {
  onCameraScaleChange?: (scale: number) => void;
  zoomCommandRef?: React.MutableRefObject<{
    zoomBy: (factor: number) => void;
    resetCenter: () => void;
  } | null>;
}

const CARD_BORDER_RADIUS = 12;

export const PinterestInfiniteCanvas: React.FC<PinterestInfiniteCanvasProps> = ({
  onCameraScaleChange,
  zoomCommandRef,
}) => {
  const cards = usePinterestStore((s) => s.cards);
  const layoutRevision = usePinterestStore((s) => s.layoutRevision);
  const cameraResetNonce = usePinterestStore((s) => s.cameraResetNonce);
  const collectedPinIds = usePinterestStore((s) => s.collectedPinIds);
  const importedPinIds = usePinterestStore((s) => s.importedPinIds);
  const isQuickCollectMode = usePinterestStore((s) => s.isQuickCollectMode);
  const isLoadingMore = usePinterestStore((s) => s.isLoadingMore);
  const getSpatialLayout = usePinterestStore((s) => s.getSpatialLayout);
  const loadMoreIfNeeded = usePinterestStore((s) => s.loadMoreIfNeeded);
  const prefetchAhead = usePinterestStore((s) => s.prefetchAhead);
  const toggleTrayPin = usePinterestStore((s) => s.toggleTrayPin);
  const openPinDetail = usePinterestStore((s) => s.openPinDetail);

  const containerRef = useRef<HTMLDivElement | null>(null);
  const [viewport, setViewport] = useState<SpatialSize>({ width: 1200, height: 760 });
  const [camera, setCamera] = useState<InfiniteSpatialCamera>(() =>
    createCenteredCamera({ width: 1200, height: 760 }, SPATIAL_CAMERA_DEFAULT_SCALE),
  );
  const [isDragging, setIsDragging] = useState(false);

  const cameraRef = useRef(camera);
  cameraRef.current = camera;
  const viewportRef = useRef(viewport);
  viewportRef.current = viewport;

  const isTauri = isTauriRuntime();

  // Drag + inertia state stored in refs for 120Hz zero-allocation panning
  const dragRef = useRef<{
    active: boolean;
    pointerId: number;
    startX: number;
    startY: number;
    lastX: number;
    lastY: number;
    lastTime: number;
    vx: number;
    vy: number;
    moved: boolean;
  }>({
    active: false,
    pointerId: -1,
    startX: 0,
    startY: 0,
    lastX: 0,
    lastY: 0,
    lastTime: 0,
    vx: 0,
    vy: 0,
    moved: false,
  });
  const suppressClickRef = useRef(false);
  const inertiaRafRef = useRef<number | null>(null);
  const lastPrefetchTimeRef = useRef(0);

  const stopInertia = useCallback(() => {
    if (inertiaRafRef.current != null) {
      cancelAnimationFrame(inertiaRafRef.current);
      inertiaRafRef.current = null;
    }
  }, []);

  const notifyPrefetchAndEdge = useCallback(
    (cam: InfiniteSpatialCamera, vxScreen = 0, vyScreen = 0) => {
      const now = performance.now();
      if (now - lastPrefetchTimeRef.current < 140) return;
      lastPrefetchTimeRef.current = now;

      const vp = viewportRef.current;
      if (vp.width <= 0 || vp.height <= 0) return;
      const worldRect = cameraVisibleWorldRect(cam, vp);
      void loadMoreIfNeeded(worldRect);

      const safeScale = Math.max(0.15, cam.scale);
      const lookahead: SpatialSize = {
        width: Math.max(-720, Math.min(720, (-vxScreen * 0.45) / safeScale)),
        height: Math.max(-720, Math.min(720, (-vyScreen * 0.45) / safeScale)),
      };
      const renderedCardWidth = getSpatialLayout().cardWidth * cam.scale;
      prefetchAhead(worldRect, lookahead, renderedCardWidth);
    },
    [getSpatialLayout, loadMoreIfNeeded, prefetchAhead],
  );

  // Track container dimensions cleanly via ResizeObserver
  useEffect(() => {
    const el = containerRef.current;
    if (!el) return;
    let initialized = false;

    const updateSize = () => {
      const rect = el.getBoundingClientRect();
      if (rect.width > 0 && rect.height > 0) {
        const nextSize = { width: rect.width, height: rect.height };
        setViewport(nextSize);
        if (!initialized) {
          initialized = true;
          const centered = createCenteredCamera(nextSize, SPATIAL_CAMERA_DEFAULT_SCALE);
          setCamera(centered);
          onCameraScaleChange?.(centered.scale);
        }
      }
    };

    updateSize();
    if (typeof ResizeObserver !== 'undefined') {
      const obs = new ResizeObserver(updateSize);
      obs.observe(el);
      return () => obs.disconnect();
    }
    window.addEventListener('resize', updateSize);
    return () => window.removeEventListener('resize', updateSize);
  }, [onCameraScaleChange]);

  // Reset camera on explicit center request or source swap
  useEffect(() => {
    if (cameraResetNonce === 0) return;
    stopInertia();
    const centered = createCenteredCamera(viewportRef.current, SPATIAL_CAMERA_DEFAULT_SCALE);
    setCamera(centered);
    onCameraScaleChange?.(centered.scale);
  }, [cameraResetNonce, onCameraScaleChange, stopInertia]);

  // Expose imperative zoom & reset commands to top floating toolbar
  useEffect(() => {
    if (!zoomCommandRef) return;
    zoomCommandRef.current = {
      zoomBy: (factor: number) => {
        stopInertia();
        const vp = viewportRef.current;
        const center = { x: vp.width * 0.5, y: vp.height * 0.5 };
        setCamera((prev) => {
          const next = cameraZoomAt(prev, prev.scale * factor, center);
          onCameraScaleChange?.(next.scale);
          notifyPrefetchAndEdge(next);
          return next;
        });
      },
      resetCenter: () => {
        stopInertia();
        const centered = createCenteredCamera(viewportRef.current, SPATIAL_CAMERA_DEFAULT_SCALE);
        setCamera(centered);
        onCameraScaleChange?.(centered.scale);
        notifyPrefetchAndEdge(centered);
      },
    };
    return () => {
      zoomCommandRef.current = null;
    };
  }, [notifyPrefetchAndEdge, onCameraScaleChange, stopInertia, zoomCommandRef]);

  // Non-passive wheel listener for cursor-anchored zoom (Ctrl/Meta/Alt + wheel) & 2D trackpad pan
  useEffect(() => {
    const el = containerRef.current;
    if (!el) return;

    const handleWheel = (e: WheelEvent) => {
      e.preventDefault();
      stopInertia();
      const rect = el.getBoundingClientRect();
      const anchor = {
        x: e.clientX - rect.left,
        y: e.clientY - rect.top,
      };

      if (e.ctrlKey || e.metaKey || e.altKey) {
        const zoomFactor = Math.exp(-e.deltaY * 0.0024);
        setCamera((prev) => {
          const nextScale = Math.min(
            SPATIAL_CAMERA_MAX_SCALE,
            Math.max(SPATIAL_CAMERA_MIN_SCALE, prev.scale * zoomFactor),
          );
          const next = cameraZoomAt(prev, nextScale, anchor);
          onCameraScaleChange?.(next.scale);
          notifyPrefetchAndEdge(next);
          return next;
        });
        return;
      }

      const dx = e.shiftKey && Math.abs(e.deltaX) < 1 ? -e.deltaY : -e.deltaX;
      const dy = e.shiftKey && Math.abs(e.deltaX) < 1 ? 0 : -e.deltaY;
      setCamera((prev) => {
        const next: InfiniteSpatialCamera = {
          scale: prev.scale,
          offset: {
            x: prev.offset.x + dx,
            y: prev.offset.y + dy,
          },
        };
        notifyPrefetchAndEdge(next, dx * 18, dy * 18);
        return next;
      });
    };

    el.addEventListener('wheel', handleWheel, { passive: false });
    return () => el.removeEventListener('wheel', handleWheel);
  }, [notifyPrefetchAndEdge, onCameraScaleChange, stopInertia]);

  useEffect(() => () => stopInertia(), [stopInertia]);

  const handlePointerDown = (e: React.PointerEvent<HTMLDivElement>) => {
    if (e.button !== 0 && e.button !== 1) return;
    stopInertia();
    suppressClickRef.current = false;
    dragRef.current = {
      active: true,
      pointerId: e.pointerId,
      startX: e.clientX,
      startY: e.clientY,
      lastX: e.clientX,
      lastY: e.clientY,
      lastTime: performance.now(),
      vx: 0,
      vy: 0,
      moved: false,
    };
  };

  const handlePointerMove = (e: React.PointerEvent<HTMLDivElement>) => {
    const drag = dragRef.current;
    if (!drag.active || drag.pointerId !== e.pointerId) return;

    const totalDist = Math.hypot(e.clientX - drag.startX, e.clientY - drag.startY);
    if (!drag.moved && totalDist > 4) {
      drag.moved = true;
      suppressClickRef.current = true;
      setIsDragging(true);
      try {
        e.currentTarget.setPointerCapture(e.pointerId);
      } catch {
        // Ignore capture failures in jsdom
      }
    }
    if (!drag.moved) return;

    const now = performance.now();
    const dt = Math.max(4, now - drag.lastTime);
    const dx = e.clientX - drag.lastX;
    const dy = e.clientY - drag.lastY;
    drag.vx = drag.vx * 0.55 + ((dx / dt) * 1000) * 0.45;
    drag.vy = drag.vy * 0.55 + ((dy / dt) * 1000) * 0.45;
    drag.lastX = e.clientX;
    drag.lastY = e.clientY;
    drag.lastTime = now;

    setCamera((prev) => {
      const next: InfiniteSpatialCamera = {
        scale: prev.scale,
        offset: {
          x: prev.offset.x + dx,
          y: prev.offset.y + dy,
        },
      };
      notifyPrefetchAndEdge(next, drag.vx, drag.vy);
      return next;
    });
  };

  const finishDrag = (e: React.PointerEvent<HTMLDivElement>) => {
    const drag = dragRef.current;
    if (!drag.active || drag.pointerId !== e.pointerId) return;
    drag.active = false;
    setIsDragging(false);
    try {
      if (e.currentTarget.hasPointerCapture?.(e.pointerId)) {
        e.currentTarget.releasePointerCapture(e.pointerId);
      }
    } catch {
      // Ignore
    }

    if (!drag.moved) return;

    // Launch smooth 60/120Hz inertial glide if velocity is meaningful
    let vx = drag.vx;
    let vy = drag.vy;
    const speed = Math.hypot(vx, vy);
    if (speed < 90) {
      notifyPrefetchAndEdge(cameraRef.current);
      return;
    }

    let prevTime = performance.now();
    const step = (now: number) => {
      const dtSec = Math.min(0.032, Math.max(0.001, (now - prevTime) / 1000));
      prevTime = now;
      const decay = Math.exp(-5.4 * dtSec);
      vx *= decay;
      vy *= decay;

      const dx = vx * dtSec;
      const dy = vy * dtSec;
      setCamera((prev) => {
        const next: InfiniteSpatialCamera = {
          scale: prev.scale,
          offset: {
            x: prev.offset.x + dx,
            y: prev.offset.y + dy,
          },
        };
        notifyPrefetchAndEdge(next, vx, vy);
        return next;
      });

      if (Math.hypot(vx, vy) > 28) {
        inertiaRafRef.current = requestAnimationFrame(step);
      } else {
        inertiaRafRef.current = null;
      }
    };
    inertiaRafRef.current = requestAnimationFrame(step);
  };

  const handleCardPrimaryClick = useCallback(
    (pin: PinterestPin) => {
      if (suppressClickRef.current) {
        suppressClickRef.current = false;
        return;
      }
      if (isQuickCollectMode) {
        toggleTrayPin(pin);
      } else {
        void openPinDetail(pin, true);
      }
    },
    [isQuickCollectMode, openPinDetail, toggleTrayPin],
  );

  // Viewport culling: render only cards inside visible world rect + overscan
  const visibleCards = useMemo<PinterestSpatialCard[]>(() => {
    void layoutRevision;
    const layout = getSpatialLayout();
    const worldRect = cameraVisibleWorldRect(camera, viewport);
    const overscan = Math.max(260, 320 / Math.max(0.35, camera.scale));
    return layout.visibleCards(worldRect, overscan);
  }, [camera, viewport, layoutRevision, getSpatialLayout]);

  const renderedCardWidth = getSpatialLayout().cardWidth * camera.scale;

  return (
    <div
      ref={containerRef}
      data-testid="pinterest-infinite-canvas"
      onPointerDown={handlePointerDown}
      onPointerMove={handlePointerMove}
      onPointerUp={finishDrag}
      onPointerCancel={finishDrag}
      onDoubleClick={(e) => {
        if ((e.target as HTMLElement).closest('[data-pin-card="true"]')) return;
        stopInertia();
        const centered = createCenteredCamera(viewportRef.current, SPATIAL_CAMERA_DEFAULT_SCALE);
        setCamera(centered);
        onCameraScaleChange?.(centered.scale);
      }}
      className={[
        'relative w-full h-full overflow-hidden select-none touch-none',
        isDragging ? 'cursor-grabbing' : isQuickCollectMode ? 'cursor-crosshair' : 'cursor-grab',
      ].join(' ')}
      style={{
        backgroundImage:
          'radial-gradient(circle, var(--win-stroke-divider) 1px, transparent 1px)',
        backgroundSize: `${Math.max(18, Math.round(28 * camera.scale))}px ${Math.max(18, Math.round(28 * camera.scale))}px`,
        backgroundPosition: `${Math.round(camera.offset.x)}px ${Math.round(camera.offset.y)}px`,
      }}
    >
      {/* Hardware-accelerated transformed world layer */}
      <div
        className="absolute top-0 left-0 origin-top-left will-change-transform"
        style={{
          transform: `translate3d(${camera.offset.x}px, ${camera.offset.y}px, 0) scale(${camera.scale})`,
        }}
      >
        {visibleCards.map((card) => {
          const pin = card.pin;
          const isCollected = Boolean(collectedPinIds[pin.id]);
          const isImported = Boolean(importedPinIds[pin.id]);
          const rawImg = pinDisplayImageUrl(pin, renderedCardWidth);
          const resolvedImg = resolveSocialMediaUrl(rawImg, isTauri);
          const title = pinDisplayTitle(pin);

          return (
            <div
              key={card.id}
              data-pin-card="true"
              data-pin-id={pin.id}
              role="button"
              tabIndex={0}
              aria-label={title}
              onClick={() => handleCardPrimaryClick(pin)}
              onKeyDown={(e) => {
                if (e.key === 'Enter' || e.key === ' ') {
                  e.preventDefault();
                  handleCardPrimaryClick(pin);
                }
              }}
              style={{
                transform: `translate3d(${card.frame.x}px, ${card.frame.y}px, 0)`,
                width: card.frame.width,
                height: card.frame.height,
                borderRadius: CARD_BORDER_RADIUS,
                backgroundColor: pin.dominantColorHex || 'var(--bg-subtle)',
              }}
              className={[
                'group absolute top-0 left-0 overflow-hidden shadow-[0_6px_22px_rgba(0,0,0,0.12)] transition-shadow duration-150',
                'hover:shadow-[0_12px_30px_rgba(0,0,0,0.22)] focus-visible:outline-2 focus-visible:outline-[var(--accent)]',
                isCollected
                  ? 'ring-[2.5px] ring-[var(--accent)] ring-offset-2 ring-offset-[var(--bg-gallery)]'
                  : 'ring-1 ring-black/8 dark:ring-white/10',
              ].join(' ')}
            >
              {resolvedImg ? (
                <img
                  src={resolvedImg}
                  alt={title}
                  loading="lazy"
                  decoding="async"
                  draggable={false}
                  className="w-full h-full object-cover block pointer-events-none select-none"
                />
              ) : (
                <div className="w-full h-full flex items-center justify-center p-3 text-center text-[12px] text-white/80">
                  {title}
                </div>
              )}

              {/* Subtle bottom caption gradient on hover */}
              <div className="pointer-events-none absolute inset-x-0 bottom-0 px-2.5 pt-8 pb-2 bg-gradient-to-t from-black/72 via-black/32 to-transparent opacity-0 group-hover:opacity-100 transition-opacity duration-150">
                <div className="text-[12px] font-medium text-white leading-tight line-clamp-2 drop-shadow">
                  {title}
                </div>
                {(pin.authorName || pin.boardName) && (
                  <div className="text-[10.5px] text-white/75 truncate mt-0.5">
                    {pin.authorName || pin.boardName}
                  </div>
                )}
              </div>

              {/* Video indicator badge (top-left) */}
              {pin.videoURL && (
                <span className="pointer-events-none absolute top-2 left-2 inline-flex items-center gap-1 px-1.5 py-0.5 rounded-full bg-black/60 text-white text-[10px] font-medium backdrop-blur-sm">
                  <VideoClip16Filled className="w-3 h-3" />
                  <span>视频</span>
                </span>
              )}

              {/* Already-imported indicator (bottom-right when not hovered) */}
              {isImported && !isCollected && (
                <span
                  title="已在 Charkle 素材库中"
                  className="pointer-events-none absolute top-2 left-2 inline-flex items-center gap-1 px-1.5 py-0.5 rounded-full bg-emerald-600/90 text-white text-[10px] font-medium shadow-sm"
                >
                  <CheckmarkCircle16Filled className="w-3 h-3" />
                  <span>已入库</span>
                </span>
              )}

              {/* Top-right Badge:
                  - Browse mode: HIDE `+`, show ONLY `✓` when already collected in tray.
                  - Fast-Pick mode: SHOW `+` on uncollected cards & `✓` on collected cards + quick inspect icon. */}
              {isCollected ? (
                <button
                  type="button"
                  data-testid={`pin-badge-collected-${pin.id}`}
                  aria-label="移出收藏托盘"
                  onPointerDown={(e) => e.stopPropagation()}
                  onClick={(e) => {
                    e.stopPropagation();
                    toggleTrayPin(pin);
                  }}
                  className="absolute top-2 right-2 w-7 h-7 rounded-full bg-[var(--accent)] text-[var(--accent-text)] inline-flex items-center justify-center shadow-md hover:brightness-110 cursor-pointer"
                >
                  <Checkmark16Filled className="w-4 h-4" />
                </button>
              ) : isQuickCollectMode ? (
                <div className="absolute top-2 right-2 flex items-center gap-1">
                  <button
                    type="button"
                    aria-label="查看素材详情"
                    onPointerDown={(e) => e.stopPropagation()}
                    onClick={(e) => {
                      e.stopPropagation();
                      void openPinDetail(pin, true);
                    }}
                    className="w-7 h-7 rounded-full bg-black/55 text-white inline-flex items-center justify-center opacity-0 group-hover:opacity-100 hover:bg-black/75 transition-opacity cursor-pointer backdrop-blur-sm"
                  >
                    <Eye16Regular className="w-3.5 h-3.5" />
                  </button>
                  <button
                    type="button"
                    data-testid={`pin-badge-add-${pin.id}`}
                    aria-label="加入收藏托盘"
                    onPointerDown={(e) => e.stopPropagation()}
                    onClick={(e) => {
                      e.stopPropagation();
                      toggleTrayPin(pin);
                    }}
                    className="w-7 h-7 rounded-full bg-black/62 text-white inline-flex items-center justify-center shadow-md hover:bg-[var(--accent)] hover:text-[var(--accent-text)] transition-colors cursor-pointer backdrop-blur-sm"
                  >
                    <Add16Filled className="w-4 h-4" />
                  </button>
                </div>
              ) : null}
            </div>
          );
        })}
      </div>

      {/* Subtle outer-ring loading indicator */}
      {isLoadingMore && cards.length > 0 && (
        <div
          onPointerDown={(e) => e.stopPropagation()}
          className="pointer-events-none absolute bottom-5 left-1/2 -translate-x-1/2 px-3 py-1.5 rounded-full bg-[var(--bg-elevated)]/90 border border-[var(--win-stroke-card)] shadow-md text-[12px] text-[var(--text-secondary)] backdrop-blur-md"
        >
          正在向外延展更多灵感…
        </div>
      )}
    </div>
  );
};
