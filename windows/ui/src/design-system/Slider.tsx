import React, { useCallback, useEffect, useRef, useState } from 'react';

export interface CharkleSliderProps {
  min: number;
  max: number;
  step?: number;
  value: number;
  onChange: (value: number) => void;
  onChangeEnd?: (value: number) => void;
  ariaLabel: string;
  variant?: 'glass' | 'standard';
  size?: 'sm' | 'md';
  disabled?: boolean;
  className?: string;
  title?: string;
  valueText?: string;
  'data-testid'?: string;
}

function snapToStep(raw: number, min: number, max: number, step: number): number {
  const clamped = Math.max(min, Math.min(max, raw));
  if (!(step > 0)) return clamped;
  const steps = Math.round((clamped - min) / step);
  const snapped = min + steps * step;
  const decimals = (String(step).split('.')[1] ?? '').length;
  const fixed = decimals > 0 ? Number(snapped.toFixed(decimals)) : Math.round(snapped);
  return Math.max(min, Math.min(max, fixed));
}

function rubberband(overshoot: number, dimension = 24, constant = 0.35): number {
  if (overshoot === 0) return 0;
  return (overshoot * dimension * constant) / (dimension + constant * Math.abs(overshoot));
}

/**
 * Tactile precision slider replacing browser-default range inputs.
 * Supports `glass` (calm graphite fill + elongated pure-white pill thumb with
 * translucent glass-expand on active press) and `standard` (studio cobalt fill +
 * precision circular white thumb), 1:1 pointer-capture dragging preserving grab
 * offset on thumb grabs, subtle edge rubber-banding, and full keyboard control.
 */
export const CharkleSlider: React.FC<CharkleSliderProps> = ({
  min,
  max,
  step = 1,
  value,
  onChange,
  onChangeEnd,
  ariaLabel,
  variant = 'standard',
  size = 'sm',
  disabled = false,
  className = '',
  title,
  valueText,
  'data-testid': dataTestId,
}) => {
  const rootRef = useRef<HTMLDivElement | null>(null);
  const draggingRef = useRef(false);
  const grabOffsetRef = useRef(0);
  const latestValueRef = useRef(value);
  const [dragging, setDragging] = useState(false);
  const [edgeOffsetPx, setEdgeOffsetPx] = useState(0);

  const span = max > min ? max - min : 1;
  const clamped = Math.max(min, Math.min(max, Number.isFinite(value) ? value : min));
  const ratio = Math.max(0, Math.min(1, (clamped - min) / span));
  latestValueRef.current = clamped;

  const thumbHalf = variant === 'glass' ? (size === 'md' ? 10 : 9) : size === 'md' ? 8 : 7;

  const evalClientX = useCallback(
    (clientX: number, grabOffset: number): { value: number; edgePx: number } => {
      const el = rootRef.current;
      if (!el) return { value: latestValueRef.current, edgePx: 0 };
      const rect = el.getBoundingClientRect();
      if (rect.width <= 0) return { value: latestValueRef.current, edgePx: 0 };
      const usable = Math.max(1, rect.width - thumbHalf * 2);
      const localX = clientX - grabOffset - rect.left - thumbHalf;
      let edgePx = 0;
      if (localX < 0) {
        edgePx = Math.max(-3.5, rubberband(localX, 24, 0.32));
      } else if (localX > usable) {
        edgePx = Math.min(3.5, rubberband(localX - usable, 24, 0.32));
      }
      const t = Math.max(0, Math.min(1, localX / usable));
      return {
        value: snapToStep(min + t * (max - min), min, max, step),
        edgePx,
      };
    },
    [min, max, step, thumbHalf],
  );

  const commit = useCallback(
    (next: number, isEnd = false) => {
      if (next !== latestValueRef.current) {
        latestValueRef.current = next;
        onChange(next);
      }
      if (isEnd) {
        onChangeEnd?.(next);
      }
    },
    [onChange, onChangeEnd],
  );

  const handlePointerDown = (e: React.PointerEvent<HTMLDivElement>) => {
    if (disabled || e.button !== 0) return;
    e.preventDefault();
    e.stopPropagation();
    const el = rootRef.current;
    el?.focus({ preventScroll: true });
    el?.setPointerCapture?.(e.pointerId);
    draggingRef.current = true;
    setDragging(true);

    // Respect grab offset when grabbing directly on the thumb so it never snaps under the cursor
    let grabOffset = 0;
    if (el) {
      const rect = el.getBoundingClientRect();
      const usable = Math.max(1, rect.width - thumbHalf * 2);
      const currentThumbCenterX = rect.left + thumbHalf + ratio * usable;
      const dist = e.clientX - currentThumbCenterX;
      if (Math.abs(dist) <= thumbHalf + 4) {
        grabOffset = dist;
      }
    }
    grabOffsetRef.current = grabOffset;

    const { value: next, edgePx } = evalClientX(e.clientX, grabOffset);
    setEdgeOffsetPx(edgePx);
    commit(next, false);
  };

  const handlePointerMove = (e: React.PointerEvent<HTMLDivElement>) => {
    if (!draggingRef.current || disabled) return;
    const { value: next, edgePx } = evalClientX(e.clientX, grabOffsetRef.current);
    setEdgeOffsetPx(edgePx);
    commit(next, false);
  };

  const resetDrag = useCallback(
    (pointerId?: number) => {
      if (!draggingRef.current) return;
      draggingRef.current = false;
      grabOffsetRef.current = 0;
      setDragging(false);
      setEdgeOffsetPx(0);
      if (pointerId !== undefined && rootRef.current?.hasPointerCapture?.(pointerId)) {
        try {
          rootRef.current.releasePointerCapture(pointerId);
        } catch {
          // Capture may already have been released by the host
        }
      }
      onChangeEnd?.(latestValueRef.current);
    },
    [onChangeEnd],
  );

  const finishDrag = (e: React.PointerEvent<HTMLDivElement>) => {
    resetDrag(e.pointerId);
  };

  useEffect(() => {
    if (!dragging) return;
    const onWindowBlur = () => resetDrag();
    window.addEventListener('blur', onWindowBlur);
    return () => window.removeEventListener('blur', onWindowBlur);
  }, [dragging, resetDrag]);

  const handleKeyDown = (e: React.KeyboardEvent<HTMLDivElement>) => {
    if (disabled) return;
    let delta: number | null = null;
    if (e.key === 'ArrowRight' || e.key === 'ArrowUp') delta = step;
    else if (e.key === 'ArrowLeft' || e.key === 'ArrowDown') delta = -step;
    else if (e.key === 'PageUp') delta = step * 10;
    else if (e.key === 'PageDown') delta = -step * 10;
    else if (e.key === 'Home') {
      e.preventDefault();
      commit(min, true);
      return;
    } else if (e.key === 'End') {
      e.preventDefault();
      commit(max, true);
      return;
    }
    if (delta !== null) {
      e.preventDefault();
      const next = snapToStep(clamped + delta, min, max, step);
      commit(next, true);
    }
  };

  return (
    <div
      ref={rootRef}
      role="slider"
      tabIndex={disabled ? -1 : 0}
      aria-label={ariaLabel}
      aria-valuemin={min}
      aria-valuemax={max}
      aria-valuenow={clamped}
      aria-valuetext={valueText}
      aria-disabled={disabled || undefined}
      title={title}
      data-testid={dataTestId}
      data-variant={variant}
      data-size={size}
      data-dragging={dragging ? 'true' : undefined}
      onPointerDown={handlePointerDown}
      onPointerMove={handlePointerMove}
      onPointerUp={finishDrag}
      onPointerCancel={finishDrag}
      onLostPointerCapture={finishDrag}
      onKeyDown={handleKeyDown}
      style={
        {
          '--slider-ratio': String(ratio),
          '--slider-edge-x': `${edgeOffsetPx.toFixed(2)}px`,
        } as React.CSSProperties
      }
      className={[
        'charkle-slider',
        disabled ? 'opacity-45 pointer-events-none' : 'cursor-pointer',
        className,
      ]
        .filter(Boolean)
        .join(' ')}
    >
      <div className="charkle-slider-track" aria-hidden="true">
        <div className="charkle-slider-fill" />
      </div>
      <div className="charkle-slider-thumb" aria-hidden="true" />
    </div>
  );
};
