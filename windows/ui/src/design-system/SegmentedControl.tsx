import React, { useId } from 'react';
import { m, WIN_SPRING_SNAPPY } from './MotionPrimitives';

export interface SegmentedOption<T extends string> {
  value: T;
  label: string;
  icon?: React.ReactNode;
  title?: string;
}

export interface SegmentedControlProps<T extends string> {
  value: T;
  options: ReadonlyArray<SegmentedOption<T>>;
  onChange: (value: T) => void;
  size?: 'xs' | 'sm';
  /** Stretch control to 100% width with equal-width centered segments. */
  fullWidth?: boolean;
  ariaLabel?: string;
  /** Optional explicit Motion `layoutId` for shared-pill transitions. */
  layoutId?: string;
  className?: string;
}

/**
 * Fluent 2 Segmented Control for 2-5 short mutually-exclusive choices:
 * - 4px control radius container with subtle border
 * - Smooth `motion` `layoutId` sliding highlight pill using `WIN_SPRING_SNAPPY`
 */
export function SegmentedControl<T extends string>({
  value,
  options,
  onChange,
  size = 'xs',
  fullWidth = false,
  ariaLabel,
  layoutId,
  className = '',
}: SegmentedControlProps<T>) {
  const autoId = useId();
  const pillLayoutId = layoutId ?? `win-segmented-pill-${autoId}`;
  const hasGridClass = /\b(?:inline-)?grid\b/.test(className);
  const isFullWidth = fullWidth || /\bw-full\b/.test(className);
  const containerDisplay = hasGridClass
    ? 'items-center'
    : isFullWidth
      ? 'flex w-full items-center'
      : 'inline-flex items-center';

  return (
    <div
      role="radiogroup"
      aria-label={ariaLabel}
      className={[
        containerDisplay,
        'p-[2px] gap-0.5 bg-[var(--bg-subtle)] border border-[var(--win-stroke-control)]',
        'rounded-[var(--win-radius-control)] select-none',
        className,
      ]
        .filter(Boolean)
        .join(' ')}
    >
      {options.map((opt) => {
        const selected = opt.value === value;
        return (
          <button
            key={opt.value}
            type="button"
            role="radio"
            aria-checked={selected}
            title={opt.title ?? opt.label}
            onClick={() => onChange(opt.value)}
            className={[
              'relative inline-flex items-center justify-center gap-1 whitespace-nowrap cursor-pointer font-medium',
              hasGridClass ? 'w-full min-w-0' : isFullWidth ? 'flex-1 min-w-0' : '',
              'rounded-[3px] transition-colors duration-[83ms] ease-[var(--win-ease-out)]',
              'focus-visible:outline-2 focus-visible:outline-[var(--accent)]',
              size === 'xs' ? 'h-6 px-2 text-[12px] leading-[16px]' : 'h-7 px-2.5 text-[13px] leading-[18px]',
              selected
                ? 'text-[var(--text-primary)]'
                : 'text-[var(--text-secondary)] hover:text-[var(--text-primary)]',
            ]
              .filter(Boolean)
              .join(' ')}
          >
            {selected && (
              <m.span
                layoutId={pillLayoutId}
                transition={WIN_SPRING_SNAPPY}
                aria-hidden="true"
                className="absolute inset-0 rounded-[3px] bg-[var(--bg-elevated)] win-control-elevation shadow-[0_1px_2px_rgba(0,0,0,0.08)]"
              />
            )}
            <span className="relative z-[1] inline-flex items-center justify-center gap-1">
              {opt.icon}
              {opt.label && <span>{opt.label}</span>}
            </span>
          </button>
        );
      })}
    </div>
  );
}
