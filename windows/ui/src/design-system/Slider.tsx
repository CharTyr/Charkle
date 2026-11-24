import React from 'react';
import { Slider as BaseSlider } from '@base-ui/react/slider';

export interface CharkleSliderProps {
  min: number;
  max: number;
  step?: number;
  value: number;
  onChange: (value: number) => void;
  onChangeEnd?: (value: number) => void;
  ariaLabel: string;
  /** `'glass'` is accepted as a legacy alias and renders the canonical WinUI 3 dual-ring slider. */
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

/**
 * WinUI 3 Fluent 2 Dual-Ring Slider built on `@base-ui/react/slider`:
 * - Circular outer ring + inner accent dot (`scale(1.18)` on hover, `scale(0.86)` while dragging)
 * - Full pointer drag, keyboard arrows, Home/End, PageUp/PageDown, and WCAG ARIA semantics
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
  const clamped = Math.max(min, Math.min(max, Number.isFinite(value) ? value : min));

  const handleRootKeyDown = (e: React.KeyboardEvent<HTMLDivElement>) => {
    // Native Base UI thumb <input> handles its own keyboard events; only handle
    // synthetic keyboard events dispatched directly onto the outer root element.
    if (disabled || e.target !== e.currentTarget) return;
    let next: number | null = null;
    if (e.key === 'ArrowRight' || e.key === 'ArrowUp') {
      next = snapToStep(clamped + step, min, max, step);
    } else if (e.key === 'ArrowLeft' || e.key === 'ArrowDown') {
      next = snapToStep(clamped - step, min, max, step);
    } else if (e.key === 'PageUp') {
      next = snapToStep(clamped + step * 10, min, max, step);
    } else if (e.key === 'PageDown') {
      next = snapToStep(clamped - step * 10, min, max, step);
    } else if (e.key === 'Home') {
      next = min;
    } else if (e.key === 'End') {
      next = max;
    }
    if (next !== null) {
      e.preventDefault();
      if (next !== clamped) onChange(next);
      onChangeEnd?.(next);
    }
  };

  return (
    <BaseSlider.Root
      min={min}
      max={max}
      step={step}
      value={clamped}
      disabled={disabled}
      title={title}
      aria-valuemin={min}
      aria-valuemax={max}
      aria-valuenow={clamped}
      aria-valuetext={valueText}
      aria-disabled={disabled || undefined}
      data-testid={dataTestId}
      data-variant={variant}
      data-size={size}
      onKeyDown={handleRootKeyDown}
      onValueChange={(next) => {
        const numeric = typeof next === 'number' ? next : next[0];
        if (Number.isFinite(numeric)) onChange(numeric);
      }}
      onValueCommitted={(next) => {
        const numeric = typeof next === 'number' ? next : next[0];
        if (Number.isFinite(numeric)) onChangeEnd?.(numeric);
      }}
      className={['win-slider-root', className].filter(Boolean).join(' ')}
    >
      <BaseSlider.Control className="win-slider-control">
        <BaseSlider.Track className="win-slider-track">
          <BaseSlider.Indicator className="win-slider-indicator" />
          <BaseSlider.Thumb
            className="win-slider-thumb"
            getAriaLabel={() => ariaLabel}
            getAriaValueText={valueText ? () => valueText : undefined}
          />
        </BaseSlider.Track>
      </BaseSlider.Control>
    </BaseSlider.Root>
  );
};
