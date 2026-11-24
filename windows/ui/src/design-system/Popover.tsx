import React, { useEffect, useMemo, useRef } from 'react';
import { Popover as BasePopover } from '@base-ui/react/popover';
import { Button } from './Button';

export type PopoverPlacement =
  | 'bottom-start'
  | 'bottom-center'
  | 'bottom-end'
  | 'top-start'
  | 'top-center'
  | 'top-end'
  | 'right-start'
  | 'left-start';

export interface PopoverProps {
  open: boolean;
  onOpenChange: (open: boolean) => void;
  /** Optional declarative trigger element rendered via Base UI `render`. */
  trigger?: React.ReactElement;
  anchorEl?: HTMLElement | null;
  anchorPoint?: { x: number; y: number } | null;
  placement?: PopoverPlacement;
  offset?: number;
  glass?: boolean;
  className?: string;
  children: React.ReactNode;
}

function parsePlacement(placement: PopoverPlacement): {
  side: 'top' | 'bottom' | 'left' | 'right';
  align: 'start' | 'center' | 'end';
} {
  const [side, align = 'start'] = placement.split('-') as [
    'top' | 'bottom' | 'left' | 'right',
    'start' | 'center' | 'end',
  ];
  return { side, align };
}

function createVirtualAnchor(point: { x: number; y: number }) {
  const { x, y } = point;
  return {
    getBoundingClientRect: () => ({
      width: 0,
      height: 0,
      x,
      y,
      top: y,
      left: x,
      right: x,
      bottom: y,
      toJSON: () => ({}),
    }),
  };
}

const stopPopoverPropagation = {
  onMouseDown: (e: React.MouseEvent) => e.stopPropagation(),
  onPointerDown: (e: React.PointerEvent) => e.stopPropagation(),
  onClick: (e: React.MouseEvent) => e.stopPropagation(),
  onDoubleClick: (e: React.MouseEvent) => e.stopPropagation(),
  onContextMenu: (e: React.MouseEvent) => e.stopPropagation(),
};

/**
 * Fluent 2 Flyout Popover built on `@base-ui/react/popover`:
 * - Viewport collision flipping and shift positioning via Floating UI
 * - Supports declarative `trigger`, imperative `anchorEl`, and virtual `anchorPoint`
 * - `.win-acrylic` surface with strict solid fallback under reduced transparency
 */
export const Popover: React.FC<PopoverProps> = ({
  open,
  onOpenChange,
  trigger,
  anchorEl,
  anchorPoint,
  placement = 'bottom-start',
  offset = 6,
  glass = true,
  className = '',
  children,
}) => {
  const { side, align } = parsePlacement(placement);

  const virtualAnchor = useMemo(
    () => (anchorPoint ? createVirtualAnchor(anchorPoint) : null),
    [anchorPoint?.x, anchorPoint?.y],
  );

  const lastRectRef = useRef<DOMRect | null>(null);
  useEffect(() => {
    if (!open) {
      lastRectRef.current = null;
    }
  }, [open]);

  const resilientAnchor = useMemo(() => {
    if (!anchorEl) return null;
    const initial = anchorEl.getBoundingClientRect();
    if (initial.width > 0 || initial.height > 0) {
      lastRectRef.current = initial;
    }
    return {
      contextElement: anchorEl,
      getBoundingClientRect: () => {
        const rect = anchorEl.getBoundingClientRect();
        if (rect.width > 0 || rect.height > 0) {
          lastRectRef.current = rect;
          return rect;
        }
        return lastRectRef.current ?? rect;
      },
    };
  }, [anchorEl]);

  const anchor = virtualAnchor ?? resilientAnchor ?? undefined;

  return (
    <BasePopover.Root
      open={open}
      modal={false}
      onOpenChange={(nextOpen, details) => {
        if (
          !nextOpen &&
          !trigger &&
          details.reason === 'outside-press' &&
          anchorEl &&
          details.event?.target instanceof Node &&
          anchorEl.contains(details.event.target)
        ) {
          details.cancel();
          return;
        }
        onOpenChange(nextOpen);
      }}
    >
      {trigger && <BasePopover.Trigger render={trigger} />}
      <BasePopover.Portal>
        <BasePopover.Positioner
          anchor={anchor}
          side={side}
          align={align}
          sideOffset={anchorPoint ? 2 : offset}
          collisionPadding={10}
          sticky
          positionMethod="fixed"
          className="z-[120] outline-none"
        >
          <BasePopover.Popup
            role="dialog"
            data-charkle-popover-open={open ? 'true' : undefined}
            className={[
              'win-flyout-popup rounded-[var(--win-radius-overlay)] charkle-scroll overflow-y-auto outline-none',
              'max-h-[calc(100vh-20px)]',
              glass
                ? 'win-acrylic'
                : 'bg-[var(--bg-elevated)] border border-[var(--win-stroke-flyout)] shadow-[0_8px_24px_rgba(0,0,0,0.16)]',
              className,
            ]
              .filter(Boolean)
              .join(' ')}
            {...stopPopoverPropagation}
          >
            {children}
          </BasePopover.Popup>
        </BasePopover.Positioner>
      </BasePopover.Portal>
    </BasePopover.Root>
  );
};

export interface PopconfirmProps {
  open: boolean;
  onOpenChange: (open: boolean) => void;
  anchorEl: HTMLElement | null;
  title: string;
  description?: string;
  confirmLabel: string;
  onConfirm: () => void;
}

/**
 * In-place Fluent 2 Popconfirm for single irreversible actions.
 */
export const Popconfirm: React.FC<PopconfirmProps> = ({
  open,
  onOpenChange,
  anchorEl,
  title,
  description,
  confirmLabel,
  onConfirm,
}) => (
  <Popover
    open={open}
    onOpenChange={onOpenChange}
    anchorEl={anchorEl}
    placement="bottom-end"
    className="w-[256px] p-3.5"
  >
    <div className="text-[13px] leading-[18px] font-semibold text-[var(--text-primary)] charkle-heading">
      {title}
    </div>
    {description && (
      <p className="mt-1 text-[12px] leading-[16px] text-[var(--text-secondary)] charkle-prose">
        {description}
      </p>
    )}
    <div className="mt-3 flex items-center justify-end gap-1.5">
      <Button variant="standard" size="xs" onClick={() => onOpenChange(false)}>
        取消
      </Button>
      <Button
        variant="danger"
        size="xs"
        onClick={() => {
          onOpenChange(false);
          onConfirm();
        }}
      >
        {confirmLabel}
      </Button>
    </div>
  </Popover>
);
