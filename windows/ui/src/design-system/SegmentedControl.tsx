import React from 'react';

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
  ariaLabel?: string;
  className?: string;
}

/**
 * Unified Segmented Control for 2-5 short mutually-exclusive choices (DESIGN.md §7.2 & P1-4).
 */
export function SegmentedControl<T extends string>({
  value,
  options,
  onChange,
  size = 'xs',
  ariaLabel,
  className = '',
}: SegmentedControlProps<T>) {
  return (
    <div
      role="radiogroup"
      aria-label={ariaLabel}
      className={[
        'inline-flex items-center p-[3px] gap-0.5 bg-[var(--bg-subtle)] border border-[var(--border-hairline)]',
        'rounded-[var(--radius-settings-inner)] select-none',
        className,
      ].join(' ')}
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
              'charkle-pressable inline-flex items-center justify-center gap-1 whitespace-nowrap cursor-pointer font-medium',
              'rounded-[var(--radius-card-inner)] focus-visible:outline-2 focus-visible:outline-[var(--accent)]',
              size === 'xs' ? 'h-6 px-2 text-[11.5px]' : 'h-7 px-2.5 text-[12.5px]',
              selected
                ? 'bg-[var(--bg-elevated)] text-[var(--text-primary)] shadow-[0_1px_2px_rgba(0,0,0,0.08)]'
                : 'text-[var(--text-secondary)] hover:text-[var(--text-primary)]',
            ].join(' ')}
          >
            {opt.icon}
            {opt.label && <span>{opt.label}</span>}
          </button>
        );
      })}
    </div>
  );
}
