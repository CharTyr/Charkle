import React, { useLayoutEffect, useRef, useState } from 'react';

export interface SegmentedOption<T extends string> {
  id: T;
  label?: string;
  icon?: React.ReactNode;
  title?: string;
  ariaLabel?: string;
}

export interface SegmentedControlProps<T extends string> {
  options: ReadonlyArray<SegmentedOption<T>>;
  value: T;
  onChange: (next: T) => void;
  size?: 'sm' | 'md';
  fullWidth?: boolean;
  iconOnly?: boolean;
  disabled?: boolean;
  ariaLabel?: string;
  className?: string;
}

/**
 * Accessible segmented choice control (`role="radiogroup"`) with a sliding elevated indicator
 * (`--duration-move` `--ease-in-out`) for 2–5 mutually exclusive short options.
 */
export function SegmentedControl<T extends string>({
  options,
  value,
  onChange,
  size = 'sm',
  fullWidth = false,
  iconOnly = false,
  disabled = false,
  ariaLabel,
  className = '',
}: SegmentedControlProps<T>) {
  const containerRef = useRef<HTMLDivElement | null>(null);
  const btnRefs = useRef<Array<HTMLButtonElement | null>>([]);
  const [indicator, setIndicator] = useState<{ left: number; width: number } | null>(null);

  const activeIndex = options.findIndex((o) => o.id === value);
  const optionsSignature = options.map((o) => `${o.id}:${o.label ?? ''}`).join('|');

  useLayoutEffect(() => {
    const update = () => {
      const container = containerRef.current;
      const activeBtn = activeIndex >= 0 ? btnRefs.current[activeIndex] : null;
      if (!container || !activeBtn) {
        setIndicator(null);
        return;
      }
      setIndicator({
        left: activeBtn.offsetLeft,
        width: activeBtn.offsetWidth,
      });
    };

    update();
    if (typeof ResizeObserver === 'undefined' || !containerRef.current) return;
    const ro = new ResizeObserver(update);
    ro.observe(containerRef.current);
    return () => ro.disconnect();
  }, [activeIndex, optionsSignature, size, fullWidth, iconOnly]);

  const handleKeyDown = (e: React.KeyboardEvent, idx: number) => {
    if (disabled || options.length === 0) return;
    let nextIdx: number | null = null;
    if (e.key === 'ArrowRight' || e.key === 'ArrowDown') {
      nextIdx = (idx + 1) % options.length;
    } else if (e.key === 'ArrowLeft' || e.key === 'ArrowUp') {
      nextIdx = (idx - 1 + options.length) % options.length;
    } else if (e.key === 'Home') {
      nextIdx = 0;
    } else if (e.key === 'End') {
      nextIdx = options.length - 1;
    }
    if (nextIdx !== null) {
      e.preventDefault();
      onChange(options[nextIdx].id);
      btnRefs.current[nextIdx]?.focus();
    }
  };

  return (
    <div
      ref={containerRef}
      role="radiogroup"
      aria-label={ariaLabel}
      className={[
        'relative items-center p-0.5 rounded-[var(--radius-chip)] bg-[var(--bg-subtle)]/90 border border-[var(--border-hairline)] select-none',
        fullWidth ? 'flex w-full' : 'inline-flex',
        disabled ? 'opacity-55 pointer-events-none' : '',
        className,
      ].join(' ')}
    >
      {indicator && (
        <div
          aria-hidden="true"
          className="pointer-events-none absolute left-0 top-0.5 bottom-0.5 rounded-[6px] bg-[var(--bg-elevated)] shadow-[0_1px_2px_rgba(0,0,0,0.08)] border border-[var(--border-hairline)]/70 transition-transform duration-[var(--duration-move)] ease-[var(--ease-in-out)]"
          style={{
            transform: `translate3d(${indicator.left}px, 0, 0)`,
            width: indicator.width,
          }}
        />
      )}

      {options.map((opt, idx) => {
        const active = opt.id === value;
        const isIconButton = iconOnly || (!opt.label && Boolean(opt.icon));
        return (
          <button
            key={opt.id}
            ref={(el) => {
              btnRefs.current[idx] = el;
            }}
            type="button"
            role="radio"
            aria-checked={active}
            aria-label={opt.ariaLabel ?? opt.title ?? opt.label}
            title={opt.title}
            tabIndex={active || (activeIndex < 0 && idx === 0) ? 0 : -1}
            disabled={disabled}
            onClick={() => onChange(opt.id)}
            onKeyDown={(e) => handleKeyDown(e, idx)}
            className={[
              'relative z-10 inline-flex items-center justify-center gap-1.5 font-medium whitespace-nowrap rounded-[6px] cursor-pointer',
              'transition-colors duration-[var(--duration-press)] ease-[var(--ease-out)]',
              'focus-visible:outline-2 focus-visible:outline-offset-1 focus-visible:outline-[var(--accent)]',
              fullWidth ? 'flex-1' : '',
              isIconButton
                ? size === 'sm'
                  ? 'h-[24px] w-[26px] p-0'
                  : 'h-[28px] w-[30px] p-0'
                : size === 'sm'
                  ? 'min-h-[24px] px-2.5 py-0.5 text-[11.5px]'
                  : 'min-h-[28px] px-3 py-1 text-[12.5px]',
              active
                ? 'text-[var(--text-primary)]'
                : 'text-[var(--text-secondary)] hover:text-[var(--text-primary)]',
            ].join(' ')}
          >
            {opt.icon && <span className="shrink-0 inline-flex items-center">{opt.icon}</span>}
            {!iconOnly && opt.label && <span>{opt.label}</span>}
          </button>
        );
      })}
    </div>
  );
}
