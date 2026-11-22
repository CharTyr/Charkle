import React from 'react';

export type ButtonVariant = 'primary' | 'secondary' | 'ghost' | 'danger' | 'glass';
export type ButtonSize = 'xs' | 'sm' | 'md' | 'icon';

export interface ButtonProps extends React.ButtonHTMLAttributes<HTMLButtonElement> {
  variant?: ButtonVariant;
  size?: ButtonSize;
  active?: boolean;
  pill?: boolean;
  loading?: boolean;
}

const VARIANT_CLASSES: Record<ButtonVariant, string> = {
  primary:
    'bg-[var(--accent)] text-white hover:bg-[var(--accent-hover)] border border-transparent shadow-xs',
  secondary:
    'bg-[var(--bg-subtle)] text-[var(--text-primary)] hover:bg-[var(--border-hairline)] border border-[var(--border-hairline)]',
  ghost:
    'bg-transparent text-[var(--text-secondary)] hover:text-[var(--text-primary)] hover:bg-[var(--bg-subtle)] border border-transparent',
  danger:
    'bg-[var(--danger-soft)] text-[var(--danger)] hover:bg-[var(--danger)] hover:text-white border border-transparent',
  glass:
    'charkle-glass text-[var(--text-primary)] hover:bg-[var(--glass-bg-hover)] border border-transparent',
};

const SIZE_CLASSES: Record<ButtonSize, string> = {
  xs: 'h-7 px-2.5 text-[12px] gap-1.5 rounded-[var(--radius-chip)]',
  sm: 'h-8 px-3 text-[12.5px] gap-1.5 rounded-[var(--radius-settings-inner)]',
  md: 'h-9 px-3.5 text-[13px] gap-2 rounded-[var(--radius-dock-inner)]',
  icon: 'h-8 w-8 p-0 justify-center rounded-[var(--radius-chip)]',
};

export const Button = React.forwardRef<HTMLButtonElement, ButtonProps>(
  (
    {
      variant = 'secondary',
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
    const activeStyle = active
      ? 'bg-[var(--accent-soft)] text-[var(--accent)] border-[var(--accent-ring)]'
      : '';

    return (
      <button
        ref={ref}
        type={type}
        disabled={disabled || loading}
        data-pill={pill ? 'true' : undefined}
        className={[
          'charkle-pressable inline-flex items-center font-medium select-none cursor-pointer whitespace-nowrap',
          'focus-visible:outline-2 focus-visible:outline-offset-1 focus-visible:outline-[var(--accent)]',
          'disabled:opacity-45 disabled:cursor-not-allowed',
          VARIANT_CLASSES[variant],
          SIZE_CLASSES[size],
          pill ? 'rounded-full' : '',
          activeStyle,
          className,
        ]
          .filter(Boolean)
          .join(' ')}
        {...rest}
      >
        {loading && (
          <span className="h-3.5 w-3.5 rounded-full border-2 border-current border-t-transparent animate-spin" />
        )}
        {children}
      </button>
    );
  },
);

Button.displayName = 'Button';
