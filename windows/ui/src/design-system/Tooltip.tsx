import React from 'react';
import { Tooltip as BaseTooltip } from '@base-ui/react/tooltip';

export interface TooltipProviderProps {
  /** Initial hover delay in ms (Win11 default: 500ms). */
  delay?: number;
  /** Delay before closing after pointer leaves in ms. */
  closeDelay?: number;
  /** Window in ms during which adjacent tooltips open instantaneously (0ms). */
  timeout?: number;
  children: React.ReactNode;
}

export const TooltipProvider: React.FC<TooltipProviderProps> = ({
  delay = 500,
  closeDelay = 0,
  timeout = 400,
  children,
}) => (
  <BaseTooltip.Provider delay={delay} closeDelay={closeDelay} timeout={timeout}>
    {children}
  </BaseTooltip.Provider>
);

export interface TooltipProps {
  content: React.ReactNode;
  shortcut?: string;
  side?: 'top' | 'bottom' | 'left' | 'right';
  align?: 'start' | 'center' | 'end';
  sideOffset?: number;
  delay?: number;
  disabled?: boolean;
  className?: string;
  children: React.ReactElement;
}

/**
 * Fluent 2 Desktop Tooltip built on `@base-ui/react/tooltip`:
 * - 4px control radius, elevated opaque surface, 1px flyout border
 * - Optional keyboard shortcut badge
 * - Grouped instant switching via `TooltipProvider`
 */
export const Tooltip: React.FC<TooltipProps> = ({
  content,
  shortcut,
  side = 'bottom',
  align = 'center',
  sideOffset = 6,
  delay,
  disabled = false,
  className = '',
  children,
}) => {
  if (disabled || content === null || content === undefined || content === '') {
    return children;
  }

  return (
    <BaseTooltip.Root>
      <BaseTooltip.Trigger delay={delay} render={children} />
      <BaseTooltip.Portal>
        <BaseTooltip.Positioner
          side={side}
          align={align}
          sideOffset={sideOffset}
          collisionPadding={8}
          positionMethod="fixed"
          className="z-[220] pointer-events-none"
        >
          <BaseTooltip.Popup
            className={[
              'win-tooltip-popup inline-flex items-center gap-2 px-2.5 py-1 max-w-[280px]',
              'rounded-[var(--win-radius-control)] bg-[var(--bg-elevated)] text-[var(--text-primary)]',
              'border border-[var(--win-stroke-flyout)] shadow-[0_4px_14px_rgba(0,0,0,0.16)]',
              'text-[12px] leading-[16px] font-normal select-none',
              className,
            ]
              .filter(Boolean)
              .join(' ')}
          >
            <span className="truncate">{content}</span>
            {shortcut && (
              <kbd className="px-1 py-[1px] rounded-[3px] bg-[var(--bg-subtle)] text-[10.5px] leading-[14px] text-[var(--text-tertiary)] charkle-mono shrink-0">
                {shortcut}
              </kbd>
            )}
          </BaseTooltip.Popup>
        </BaseTooltip.Positioner>
      </BaseTooltip.Portal>
    </BaseTooltip.Root>
  );
};
