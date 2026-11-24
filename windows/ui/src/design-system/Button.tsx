import React from 'react';
import { useDelayedFlag } from './useDelayedFlag';

export type FluentButtonVariant = 'accent' | 'standard' | 'subtle' | 'danger' | 'acrylic';

/**
 * Supports canonical Fluent 2 variants (`accent | standard | subtle | danger | acrylic`)
 * plus clean aliases (`primary -> accent`, `secondary -> standard`, `ghost -> subtle`).
 */
export type ButtonVariant = FluentButtonVariant | 'primary' | 'secondary' | 'ghost';

export type ButtonSize = 'xs' | 'sm' | 'md' | 'icon';

export interface ButtonProps extends React.ButtonHTMLAttributes<HTMLButtonElement> {
  variant?: ButtonVariant;
  size?: ButtonSize;
  active?: boolean;
  pill?: boolean;
  loading?: boolean;
}

function normalizeVariant(variant: ButtonVariant): FluentButtonVariant {
  switch (variant) {
    case 'primary':
      return 'accent';
    case 'secondary':
      return 'standard';
    case 'ghost':
      return 'subtle';
    default:
      return variant;
  }
}

const VARIANT_CLASSES: Record<FluentButtonVariant, string> = {
  accent:
    'bg-[var(--accent)] text-[var(--accent-text)] hover:bg-[var(--accent-hover)] active:bg-[var(--accent-pressed)] win-accent-elevation',
  standard:
    'bg-[var(--win-control-fill)] text-[var(--text-primary)] hover:bg-[var(--win-control-fill-hover)] active:bg-[var(--win-control-fill-pressed)] win-control-elevation',
  subtle:
    'bg-transparent text-[var(--text-secondary)] hover:text-[var(--text-primary)] hover:bg-[var(--win-subtle-hover)] active:bg-[var(--win-subtle-active)] border border-transparent',
  danger:
    'bg-[var(--danger-soft)] text-[var(--danger)] hover:bg-[var(--danger)] hover:text-white active:opacity-90 border border-transparent',
  acrylic:
    'win-acrylic text-[var(--text-primary)] hover:brightness-[0.98] dark:hover:brightness-[1.08] border border-transparent',
};

const SIZE_CLASSES: Record<ButtonSize, string> = {
  xs: 'h-[26px] px-2.5 text-[12px] leading-[16px] gap-1.5 rounded-[var(--win-radius-control)]',
  sm: 'h-8 px-3 text-[13px] leading-[18px] gap-1.5 rounded-[var(--win-radius-control)]',
  md: 'h-9 px-3.5 text-[13px] leading-[18px] gap-2 rounded-[var(--win-radius-control)]',
  icon: 'h-8 w-8 p-0 justify-center rounded-[var(--win-radius-control)]',
};

export const Button = React.forwardRef<HTMLButtonElement, ButtonProps>(
  (
    {
      variant = 'standard',
      size = 'sm',
      active = false,
      pill = false,
      loading = false,
      disabled,
      className = '',
      children,
      type = 'button',
      ...rest
    },
    ref,
  ) => {
    const showSpinner = useDelayedFlag(loading, 300, 500);
    const resolvedVariant = normalizeVariant(variant);
    const activeStyle = active
      ? 'bg-[var(--accent-soft)] text-[var(--accent)] border-[var(--accent-ring)]'
      : '';

    return (
      <button
        ref={ref}
        type={type}
        disabled={disabled || loading}
        data-variant={resolvedVariant}
        data-pill={pill ? 'true' : undefined}
        className={[
          'charkle-pressable inline-flex items-center justify-center font-medium select-none cursor-pointer whitespace-nowrap',
          'focus-visible:outline-2 focus-visible:outline-offset-1 focus-visible:outline-[var(--accent)]',
          'disabled:opacity-45 disabled:cursor-not-allowed',
          VARIANT_CLASSES[resolvedVariant],
          SIZE_CLASSES[size],
          pill ? 'rounded-full' : '',
          activeStyle,
          className,
        ]
          .filter(Boolean)
          .join(' ')}
        {...rest}
      >
        {showSpinner && (
          <span
            aria-hidden="true"
            className="h-3.5 w-3.5 rounded-full border-2 border-current border-t-transparent animate-spin shrink-0"
          />
        )}
        {children}
      </button>
    );
  },
);

Button.displayName = 'Button';
