import React, { useEffect, useMemo, useRef, useState } from 'react';
import { FolderOpen, ImageOff } from 'lucide-react';
import { getTransport } from '../../api/transport';
import { Button } from '../../design-system';
import type { AssetRecord } from '../../types/domain';

export interface ImageStageViewerProps {
  asset: AssetRecord;
  zoom: number;
  onZoomChange: (nextZoom: number) => void;
  maxZoomLimit: number;
  rotationDegrees: number;
  flipHorizontal: boolean;
  flipVertical: boolean;
  longStripMode: boolean;
  pausedAnim: boolean;
  onToggleAnimPauseReady?: (freezeFn: () => void) => void;
}

/**
 * Full-resolution Image / GIF Quick Look stage (1:1 macOS `QuickLookOverlayView.swift`):
 * - Automatic Long-Strip vertical scroll mode (`height >= 1600 && h/w >= 2.2`)
 * - Smooth dynamic 0.5x–16x zoom, non-passive wheel zoom, double-click 1x/2x toggle, pointer-capture pan
 * - Screen-space rotation & H/V flip with exact macOS `quarterTurnFitScale`
 * - Animated GIF freeze-frame canvas support & dual-tier error fallback
 */
export const ImageStageViewer: React.FC<ImageStageViewerProps> = ({
  asset,
  zoom,
  onZoomChange,
  maxZoomLimit,
  rotationDegrees,
  flipHorizontal,
  flipVertical,
  longStripMode,
  pausedAnim,
  onToggleAnimPauseReady,
}) => {
  const [pan, setPan] = useState({ x: 0, y: 0 });
  const [dragging, setDragging] = useState(false);
  const [fallbackThumb, setFallbackThumb] = useState(false);
  const [loadFailed, setLoadFailed] = useState(false);
  const [stageSize, setStageSize] = useState({ width: 960, height: 640 });
  const [naturalSize, setNaturalSize] = useState<{ w: number; h: number }>({
    w: asset.pixelWidth || 0,
    h: asset.pixelHeight || 0,
  });

  const stageRef = useRef<HTMLDivElement | null>(null);
  const imgRef = useRef<HTMLImageElement | null>(null);
  const freezeCanvasRef = useRef<HTMLCanvasElement | null>(null);
  const dragStartRef = useRef({ pointerId: -1, x: 0, y: 0, panX: 0, panY: 0 });
  const zoomRef = useRef(zoom);
  zoomRef.current = zoom;
  const maxZoomRef = useRef(maxZoomLimit);
  maxZoomRef.current = maxZoomLimit;
  const onZoomChangeRef = useRef(onZoomChange);
  onZoomChangeRef.current = onZoomChange;

  useEffect(() => {
    setPan({ x: 0, y: 0 });
    setDragging(false);
    setFallbackThumb(false);
    setLoadFailed(false);
    setNaturalSize({ w: asset.pixelWidth || 0, h: asset.pixelHeight || 0 });
  }, [asset.id, asset.pixelWidth, asset.pixelHeight]);

  useEffect(() => {
    if (zoom <= 1.01) {
      setPan({ x: 0, y: 0 });
    }
  }, [zoom]);

  const normalizedRot = ((Math.round(rotationDegrees) % 360) + 360) % 360;
  const hasTransform = normalizedRot !== 0 || flipHorizontal || flipVertical;
  const showLongStrip = longStripMode && !hasTransform && zoom <= 1.01;

  // Measure stage bounds for exact macOS quarterTurnFitScale
  useEffect(() => {
    const el = stageRef.current;
    if (!el) return;
    const sync = () => {
      const rect = el.getBoundingClientRect();
      if (rect.width > 80 && rect.height > 80) {
        setStageSize({ width: Math.floor(rect.width), height: Math.floor(rect.height) });
      }
    };
    sync();
    if (typeof ResizeObserver === 'undefined') return;
    const obs = new ResizeObserver(sync);
    obs.observe(el);
    return () => obs.disconnect();
  }, [asset.id, showLongStrip]);

  // Native non-passive wheel listener so preventDefault never triggers passive listener warnings
  useEffect(() => {
    const el = stageRef.current;
    if (!el) return;
    const handleWheel = (e: WheelEvent) => {
      if (Math.abs(e.deltaY) === 0) return;
      e.preventDefault();
      const factor = e.deltaY < 0 ? 1.18 : 0.85;
      const next = Math.max(
        0.5,
        Math.min(maxZoomRef.current, Number((zoomRef.current * factor).toFixed(2))),
      );
      onZoomChangeRef.current(next);
    };
    el.addEventListener('wheel', handleWheel, { passive: false });
    return () => el.removeEventListener('wheel', handleWheel);
  }, [asset.id, showLongStrip]);

  useEffect(() => {
    onToggleAnimPauseReady?.(() => {
      if (imgRef.current && freezeCanvasRef.current) {
        const img = imgRef.current;
        const canvas = freezeCanvasRef.current;
        canvas.width = img.naturalWidth || img.width || 600;
        canvas.height = img.naturalHeight || img.height || 400;
        const ctx = canvas.getContext('2d');
        if (ctx) {
          try {
            ctx.drawImage(img, 0, 0, canvas.width, canvas.height);
          } catch {
            // Cross-origin guard
          }
        }
      }
    });
  }, [onToggleAnimPauseReady]);

  const quarterTurnFitScale = useMemo(() => {
    if (normalizedRot !== 90 && normalizedRot !== 270) return 1;
    const availW = Math.max(120, stageSize.width - 32);
    const availH = Math.max(120, stageSize.height - 32);
    const ratio =
      naturalSize.w > 0 && naturalSize.h > 0
        ? naturalSize.w / naturalSize.h
        : Math.max(0.2, asset.pixelHeight > 0 ? asset.pixelWidth / asset.pixelHeight : 1);
    let fittedW: number;
    let fittedH: number;
    if (availW / availH > ratio) {
      fittedH = availH;
      fittedW = fittedH * ratio;
    } else {
      fittedW = availW;
      fittedH = fittedW / ratio;
    }
    const scale = Math.min(availW / Math.max(1, fittedH), availH / Math.max(1, fittedW));
    return Math.max(0.25, Math.min(1, scale));
  }, [normalizedRot, stageSize.width, stageSize.height, naturalSize.w, naturalSize.h, asset.pixelWidth, asset.pixelHeight]);

  const transport = getTransport();
  const src = fallbackThumb
    ? transport.thumbnailUrl(asset.id, 'preview1400')
    : transport.originalUrl(asset.id);

  const handleImgError = () => {
    if (!fallbackThumb) {
      setFallbackThumb(true);
    } else {
      setLoadFailed(true);
    }
  };

  if (loadFailed) {
    return (
      <div
        onClick={(e) => e.stopPropagation()}
        className="max-w-[420px] mx-auto p-6 rounded-[16px] bg-[var(--bg-elevated)] border border-[var(--border-hairline)] text-center flex flex-col items-center gap-3 shadow-2xl"
      >
        <ImageOff size={28} className="text-[var(--text-tertiary)]" />
        <div className="text-[14px] font-semibold text-[var(--text-primary)]">{asset.title}</div>
        <p className="text-[12px] text-[var(--text-secondary)]">
          暂时无法加载该图像的原文件或预览图，可在资源管理器中检查文件。
        </p>
        <Button
          variant="primary"
          size="sm"
          onClick={() => void transport.revealInExplorer(asset.id)}
        >
          <FolderOpen size={13} />
          在资源管理器中显示
        </Button>
      </div>
    );
  }

  if (showLongStrip) {
    return (
      <div
        data-testid="quicklook-long-strip-scroll"
        onClick={(e) => e.stopPropagation()}
        className="w-full h-full overflow-y-auto charkle-scroll flex justify-center py-4 px-6"
      >
        <img
          ref={imgRef}
          src={src}
          alt={asset.title}
          onError={handleImgError}
          draggable={false}
          style={{ width: 'min(1040px, 84%)' }}
          className="h-auto self-start rounded-[14px] shadow-[0_18px_48px_rgba(0,0,0,0.45)] ring-1 ring-white/10"
        />
      </div>
    );
  }

  return (
    <div
      ref={stageRef}
      onClick={(e) => e.stopPropagation()}
      onDoubleClick={(e) => {
        e.stopPropagation();
        if (zoom > 1.1) {
          onZoomChange(1);
          setPan({ x: 0, y: 0 });
        } else {
          onZoomChange(2);
        }
      }}
      onPointerDown={(e) => {
        if (e.button !== 0 || zoom <= 1.01) return;
        e.preventDefault();
        try {
          e.currentTarget.setPointerCapture?.(e.pointerId);
        } catch {
          // Ignore synthetic events
        }
        setDragging(true);
        dragStartRef.current = {
          pointerId: e.pointerId,
          x: e.clientX,
          y: e.clientY,
          panX: pan.x,
          panY: pan.y,
        };
      }}
      onPointerMove={(e) => {
        if (!dragging || e.pointerId !== dragStartRef.current.pointerId) return;
        setPan({
          x: dragStartRef.current.panX + (e.clientX - dragStartRef.current.x),
          y: dragStartRef.current.panY + (e.clientY - dragStartRef.current.y),
        });
      }}
      onPointerUp={(e) => {
        if (e.pointerId !== dragStartRef.current.pointerId) return;
        setDragging(false);
      }}
      onPointerCancel={() => setDragging(false)}
      className={[
        'w-full h-full flex items-center justify-center p-4 overflow-hidden select-none',
        zoom > 1.01 ? (dragging ? 'cursor-grabbing' : 'cursor-grab') : 'cursor-default',
      ].join(' ')}
    >
      <div
        style={{
          transform: `translate3d(${pan.x}px, ${pan.y}px, 0) scale(${(
            zoom * quarterTurnFitScale
          ).toFixed(4)}) scaleX(${flipHorizontal ? -1 : 1}) scaleY(${
            flipVertical ? -1 : 1
          }) rotate(${rotationDegrees}deg)`,
          transition: dragging ? 'none' : 'transform 220ms var(--ease-out-strong)',
        }}
        className="relative max-w-full max-h-full flex items-center justify-center"
      >
        <img
          ref={imgRef}
          src={src}
          alt={asset.title}
          onLoad={(e) => {
            const img = e.currentTarget;
            if (img.naturalWidth > 0 && img.naturalHeight > 0) {
              setNaturalSize({ w: img.naturalWidth, h: img.naturalHeight });
            }
          }}
          onError={handleImgError}
          draggable={false}
          className={`max-w-full max-h-[76vh] object-contain rounded-[14px] shadow-[0_20px_54px_rgba(0,0,0,0.44)] ${
            pausedAnim ? 'opacity-0' : 'opacity-100'
          }`}
        />
        <canvas
          ref={freezeCanvasRef}
          aria-hidden={!pausedAnim}
          className={`absolute inset-0 w-full h-full object-contain rounded-[14px] pointer-events-none ${
            pausedAnim ? 'opacity-100' : 'opacity-0'
          }`}
        />
      </div>
    </div>
  );
};
