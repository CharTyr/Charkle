import React, { useEffect, useRef, useState } from 'react';
import {
  Maximize2,
  Minimize2,
  Pause,
  Play,
  RotateCcw,
  ScrollText,
  ZoomIn,
  ZoomOut,
} from 'lucide-react';
import { getTransport } from '../../api/transport';
import { isLongStripImage } from '../../design-system';
import type { AssetRecord } from '../../types/domain';

export interface ImageStageViewerProps {
  asset: AssetRecord;
}

/**
 * Full-resolution Image / GIF Quick Look viewer (DESIGN.md §7.7 & M2-R7):
 * - Automatic Long-Strip vertical scroll mode (`height >= 1600 && h/w >= 2.2`) with Fit toggle
 * - Dynamic 1x–16x zoom with drag-to-pan
 * - Play / Pause canvas freeze toggle for Animated Images (GIF / APNG / WebP)
 */
export const ImageStageViewer: React.FC<ImageStageViewerProps> = ({ asset }) => {
  const autoLongStrip = isLongStripImage(asset);
  const [longStripMode, setLongStripMode] = useState(autoLongStrip);
  const [zoom, setZoom] = useState(1);
  const [pan, setPan] = useState({ x: 0, y: 0 });
  const [dragging, setDragging] = useState(false);
  const [pausedAnim, setPausedAnim] = useState(false);
  const [fallbackThumb, setFallbackThumb] = useState(false);

  const imgRef = useRef<HTMLImageElement | null>(null);
  const freezeCanvasRef = useRef<HTMLCanvasElement | null>(null);
  const dragStartRef = useRef({ x: 0, y: 0, panX: 0, panY: 0 });

  useEffect(() => {
    setLongStripMode(isLongStripImage(asset));
    setZoom(1);
    setPan({ x: 0, y: 0 });
    setPausedAnim(false);
    setFallbackThumb(false);
  }, [asset.id, asset.pixelWidth, asset.pixelHeight, asset.mediaKind]);

  const transport = getTransport();
  const src = fallbackThumb
    ? transport.thumbnailUrl(asset.id, 'preview1400')
    : transport.originalUrl(asset.id);

  const adjustZoom = (nextZoom: number) => {
    const clamped = Math.max(1, Math.min(16, Number(nextZoom.toFixed(2))));
    setZoom(clamped);
    if (clamped === 1) setPan({ x: 0, y: 0 });
  };

  const toggleAnimPause = () => {
    if (!pausedAnim && imgRef.current && freezeCanvasRef.current) {
      const img = imgRef.current;
      const canvas = freezeCanvasRef.current;
      canvas.width = img.naturalWidth || img.width || 600;
      canvas.height = img.naturalHeight || img.height || 400;
      const ctx = canvas.getContext('2d');
      if (ctx) {
        try {
          ctx.drawImage(img, 0, 0, canvas.width, canvas.height);
        } catch {
          // Cross-origin canvas draw guard
        }
      }
    }
    setPausedAnim((v) => !v);
  };

  return (
    <div className="relative w-full h-full flex flex-col items-center justify-center overflow-hidden">
      {longStripMode ? (
        <div
          data-testid="quicklook-long-strip-scroll"
          className="w-full h-full overflow-y-auto charkle-scroll flex justify-center py-6 px-4"
        >
          <img
            ref={imgRef}
            src={src}
            alt={asset.title}
            onError={() => setFallbackThumb(true)}
            draggable={false}
            style={{
              width: `${Math.round(Math.min(100, 68 * zoom))}%`,
              maxWidth: `${Math.round(920 * zoom)}px`,
            }}
            className="h-auto self-start rounded-[var(--radius-card-outer)] shadow-2xl"
          />
        </div>
      ) : (
        <div
          onWheel={(e) => {
            if (e.ctrlKey || Math.abs(e.deltaY) > 0) {
              e.preventDefault();
              const factor = e.deltaY < 0 ? 1.25 : 0.8;
              adjustZoom(zoom * factor);
            }
          }}
          onMouseDown={(e) => {
            if (zoom <= 1) return;
            e.preventDefault();
            setDragging(true);
            dragStartRef.current = {
              x: e.clientX,
              y: e.clientY,
              panX: pan.x,
              panY: pan.y,
            };
          }}
          onMouseMove={(e) => {
            if (!dragging) return;
            setPan({
              x: dragStartRef.current.panX + (e.clientX - dragStartRef.current.x),
              y: dragStartRef.current.panY + (e.clientY - dragStartRef.current.y),
            });
          }}
          onMouseUp={() => setDragging(false)}
          onMouseLeave={() => setDragging(false)}
          className={[
            'w-full h-full flex items-center justify-center p-6 overflow-hidden select-none',
            zoom > 1 ? (dragging ? 'cursor-grabbing' : 'cursor-grab') : 'cursor-default',
          ].join(' ')}
        >
          <div
            style={{
              transform: `translate3d(${pan.x}px, ${pan.y}px, 0) scale(${zoom})`,
              transition: dragging ? 'none' : 'transform 140ms var(--ease-out)',
            }}
            className="relative max-w-full max-h-full flex items-center justify-center"
          >
            <img
              ref={imgRef}
              src={src}
              alt={asset.title}
              onError={() => setFallbackThumb(true)}
              draggable={false}
              className={`max-w-[86vw] max-h-[72vh] object-contain rounded-[var(--radius-card-outer)] shadow-2xl ${
                pausedAnim ? 'opacity-0' : 'opacity-100'
              }`}
            />
            <canvas
              ref={freezeCanvasRef}
              aria-hidden={!pausedAnim}
              className={`absolute inset-0 w-full h-full object-contain rounded-[var(--radius-card-outer)] pointer-events-none ${
                pausedAnim ? 'opacity-100' : 'opacity-0'
              }`}
            />
          </div>
        </div>
      )}

      {/* Floating bottom-right zoom & mode controls */}
      <div className="charkle-glass-dark absolute bottom-4 right-5 z-20 rounded-full px-2.5 py-1 flex items-center gap-1 text-[12px]">
        <button
          type="button"
          aria-label="缩小"
          onClick={() => adjustZoom(zoom / 1.4)}
          className="h-7 w-7 inline-flex items-center justify-center rounded-full hover:bg-white/10 cursor-pointer"
        >
          <ZoomOut size={14} />
        </button>
        <span className="min-w-[44px] text-center charkle-tabular text-[11.5px]">
          {Math.round(zoom * 100)}%
        </span>
        <button
          type="button"
          aria-label="放大"
          onClick={() => adjustZoom(zoom * 1.4)}
          className="h-7 w-7 inline-flex items-center justify-center rounded-full hover:bg-white/10 cursor-pointer"
        >
          <ZoomIn size={14} />
        </button>
        {zoom > 1 && (
          <button
            type="button"
            aria-label="还原缩放"
            onClick={() => adjustZoom(1)}
            className="h-7 w-7 inline-flex items-center justify-center rounded-full hover:bg-white/10 cursor-pointer"
          >
            <RotateCcw size={13} />
          </button>
        )}

        {(autoLongStrip || asset.pixelHeight > asset.pixelWidth * 1.6) && (
          <button
            type="button"
            onClick={() => {
              setLongStripMode((v) => !v);
              setZoom(1);
              setPan({ x: 0, y: 0 });
            }}
            className="ml-1 h-7 px-2.5 inline-flex items-center gap-1 rounded-full bg-white/10 hover:bg-white/20 text-[11.5px] cursor-pointer"
          >
            {longStripMode ? (
              <>
                <Minimize2 size={12} />
                适应屏幕
              </>
            ) : (
              <>
                <ScrollText size={12} />
                长图阅读
              </>
            )}
          </button>
        )}

        {asset.mediaKind === 'animatedImage' && (
          <button
            type="button"
            onClick={toggleAnimPause}
            className="ml-1 h-7 px-2.5 inline-flex items-center gap-1 rounded-full bg-white/10 hover:bg-white/20 text-[11.5px] cursor-pointer"
          >
            {pausedAnim ? <Play size={12} /> : <Pause size={12} />}
            {pausedAnim ? '播放动图' : '暂停动图'}
          </button>
        )}

        {!longStripMode && zoom === 1 && (
          <button
            type="button"
            title="切换至 200% 查看细节"
            onClick={() => adjustZoom(2)}
            className="h-7 w-7 inline-flex items-center justify-center rounded-full hover:bg-white/10 cursor-pointer"
          >
            <Maximize2 size={12.5} />
          </button>
        )}
      </div>
    </div>
  );
};
