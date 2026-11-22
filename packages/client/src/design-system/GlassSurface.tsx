import React from 'react';

export type GlassVariant = 'regular' | 'dark' | 'elevated' | 'subtle';
export type GlassRadius = 'dock' | 'popover' | 'card' | 'settings' | 'chip' | 'pill';

const RADIUS_CLASS_MAP: Record<GlassRadius, string> = {
  dock: 'rounded-[var(--radius-dock-outer)]',
  popover: 'rounded-[var(--radius-popover-outer)]',
  card: 'rounded-[var(--radius-card-outer)]',
  settings: 'rounded-[var(--radius-settings-outer)]',
  chip: 'rounded-[var(--radius-chip)]',
  pill: 'rounded-full',
};

export interface GlassSurfaceProps extends React.HTMLAttributes<HTMLDivElement> {
  variant?: GlassVariant;
  radius?: GlassRadius;
}

export const GlassSurface = React.forwardRef<HTMLDivElement, GlassSurfaceProps>(
  ({ variant = 'regular', radius = 'dock', className = '', children, ...rest }, ref) => {
    const surfaceClass =
      variant === 'regular'
        ? 'charkle-glass'
        : variant === 'dark'
          ? 'charkle-glass-dark'
          : variant === 'elevated'
            ? 'bg-[var(--bg-elevated)] border border-[var(--border-hairline)] shadow-sm'
            : 'bg-[var(--bg-subtle)] border border-[var(--border-hairline)]';

    return (
      <div
        ref={ref}
        data-pill={radius === 'pill' ? 'true' : undefined}
        className={`${surfaceClass} ${RADIUS_CLASS_MAP[radius]} ${className}`}
        {...rest}
      >
        {children}
      </div>
    );
  },
);

GlassSurface.displayName = 'GlassSurface';
