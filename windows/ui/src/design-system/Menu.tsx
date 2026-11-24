import React, { useMemo } from 'react';
import { Menu as BaseMenu } from '@base-ui/react/menu';
import { ContextMenu as BaseContextMenu } from '@base-ui/react/context-menu';
import { Checkmark16Regular, ChevronRight16Regular } from '@fluentui/react-icons';

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

const stopSurfacePropagation = {
  onMouseDown: (e: React.MouseEvent) => e.stopPropagation(),
  onPointerDown: (e: React.PointerEvent) => e.stopPropagation(),
  onClick: (e: React.MouseEvent) => e.stopPropagation(),
  onDoubleClick: (e: React.MouseEvent) => e.stopPropagation(),
  onContextMenu: (e: React.MouseEvent) => e.stopPropagation(),
};

const MENU_POPUP_CLASS = [
  'win-acrylic win-flyout-popup min-w-[188px] max-w-[296px] p-1',
  'rounded-[var(--win-radius-overlay)] outline-none select-none',
  'max-h-[calc(100vh-24px)] overflow-y-auto charkle-scroll',
].join(' ');

export interface DropdownMenuProps {
  /** Declarative trigger element rendered via Base UI `render` prop. */
  trigger?: React.ReactElement;
  /** Optional imperative anchor element when `trigger` is omitted. */
  anchorEl?: HTMLElement | null;
  /** Optional imperative viewport coordinates when `trigger` is omitted. */
  anchorPoint?: { x: number; y: number } | null;
  open?: boolean;
  defaultOpen?: boolean;
  onOpenChange?: (open: boolean) => void;
  side?: 'top' | 'bottom' | 'left' | 'right';
  align?: 'start' | 'center' | 'end';
  sideOffset?: number;
  modal?: boolean;
  className?: string;
  children: React.ReactNode;
}

/**
 * Fluent 2 Dropdown Menu built on `@base-ui/react/menu`:
 * - `.win-acrylic` surface with automatic solid fallback
 * - 32px rows, leading icon slot, right-aligned shortcut, native safe-triangle submenus
 */
export const DropdownMenu: React.FC<DropdownMenuProps> = ({
  trigger,
  anchorEl,
  anchorPoint,
  open,
  defaultOpen,
  onOpenChange,
  side = 'bottom',
  align = 'start',
  sideOffset = 4,
  modal = false,
  className = '',
  children,
}) => {
  const virtualAnchor = useMemo(
    () => (anchorPoint ? createVirtualAnchor(anchorPoint) : null),
    [anchorPoint?.x, anchorPoint?.y],
  );

  const anchor = virtualAnchor ?? anchorEl ?? undefined;

  return (
    <BaseMenu.Root
      open={open}
      defaultOpen={defaultOpen}
      modal={modal}
      onOpenChange={(next, details) => {
        if (
          !next &&
          !trigger &&
          details.reason === 'outside-press' &&
          anchorEl &&
          details.event?.target instanceof Node &&
          anchorEl.contains(details.event.target)
        ) {
          details.cancel();
          return;
        }
        onOpenChange?.(next);
      }}
    >
      {trigger && <BaseMenu.Trigger render={trigger} />}
      <BaseMenu.Portal>
        <BaseMenu.Positioner
          anchor={anchor}
          side={side}
          align={align}
          sideOffset={anchorPoint ? 2 : sideOffset}
          collisionPadding={10}
          positionMethod="fixed"
          className="z-[150] outline-none"
        >
          <BaseMenu.Popup
            data-charkle-popover-open="true"
            className={`${MENU_POPUP_CLASS} ${className}`}
            {...stopSurfacePropagation}
          >
            {children}
          </BaseMenu.Popup>
        </BaseMenu.Positioner>
      </BaseMenu.Portal>
    </BaseMenu.Root>
  );
};

export interface ContextMenuProps {
  /** Declarative target element whose right-click opens the context menu. */
  trigger?: React.ReactElement;
  /** Imperative coordinates for programmatic right-click menus (e.g. canvas/cards). */
  anchorPoint?: { x: number; y: number } | null;
  open?: boolean;
  onOpenChange?: (open: boolean) => void;
  className?: string;
  children: React.ReactNode;
}

/**
 * Fluent 2 Context Menu supporting both declarative right-click triggers
 * (`@base-ui/react/context-menu`) and imperative coordinate menus (`@base-ui/react/menu`).
 */
export const ContextMenu: React.FC<ContextMenuProps> = ({
  trigger,
  anchorPoint,
  open,
  onOpenChange,
  className = '',
  children,
}) => {
  if (!trigger) {
    return (
      <DropdownMenu
        open={open}
        onOpenChange={onOpenChange}
        anchorPoint={anchorPoint}
        side="bottom"
        align="start"
        sideOffset={2}
        className={className}
      >
        {children}
      </DropdownMenu>
    );
  }

  return (
    <BaseContextMenu.Root
      open={open}
      onOpenChange={(next) => onOpenChange?.(next)}
    >
      <BaseContextMenu.Trigger render={trigger} />
      <BaseContextMenu.Portal>
        <BaseContextMenu.Positioner
          collisionPadding={10}
          positionMethod="fixed"
          className="z-[150] outline-none"
        >
          <BaseContextMenu.Popup
            data-charkle-popover-open="true"
            className={`${MENU_POPUP_CLASS} ${className}`}
            {...stopSurfacePropagation}
          >
            {children}
          </BaseContextMenu.Popup>
        </BaseContextMenu.Positioner>
      </BaseContextMenu.Portal>
    </BaseContextMenu.Root>
  );
};

export interface MenuItemProps {
  icon?: React.ReactNode;
  shortcut?: string;
  checked?: boolean;
  danger?: boolean;
  tone?: 'default' | 'danger';
  disabled?: boolean;
  closeOnClick?: boolean;
  label?: string;
  onSelect?: () => void;
  onClick?: React.MouseEventHandler<HTMLElement>;
  className?: string;
  children: React.ReactNode;
}

export const MenuItem = React.forwardRef<HTMLElement, MenuItemProps>(
  (
    {
      icon,
      shortcut,
      checked,
      danger = false,
      tone = 'default',
      disabled = false,
      closeOnClick = true,
      label,
      onSelect,
      onClick,
      className = '',
      children,
    },
    ref,
  ) => {
    const isDanger = danger || tone === 'danger';
    return (
      <BaseMenu.Item
        ref={ref}
        disabled={disabled}
        closeOnClick={closeOnClick}
        label={label}
        onClick={(e) => {
          onClick?.(e);
          if (!e.defaultPrevented) {
            onSelect?.();
          }
        }}
        className={[
          'w-full min-h-[32px] px-2.5 py-1.5 flex items-center gap-2.5 text-left text-[13px] leading-[18px]',
          'rounded-[var(--win-radius-control)] cursor-pointer outline-none select-none',
          'transition-colors duration-[83ms] ease-[var(--win-ease-out)]',
          'data-[disabled]:opacity-40 data-[disabled]:pointer-events-none',
          isDanger
            ? 'text-[var(--danger)] data-[highlighted]:bg-[var(--danger-soft)]'
            : 'text-[var(--text-primary)] data-[highlighted]:bg-[var(--win-subtle-hover)] active:bg-[var(--win-subtle-active)]',
          className,
        ]
          .filter(Boolean)
          .join(' ')}
      >
        {(icon !== undefined || checked !== undefined) && (
          <span
            className={[
              'w-4 h-4 inline-flex items-center justify-center shrink-0',
              isDanger ? 'text-[var(--danger)]' : 'text-[var(--text-secondary)]',
            ].join(' ')}
          >
            {checked ? <Checkmark16Regular className="w-4 h-4 text-[var(--accent)]" /> : icon}
          </span>
        )}
        <span className="flex-1 min-w-0 truncate">{children}</span>
        {shortcut && (
          <span className="ml-auto pl-4 text-[11px] leading-[14px] text-[var(--text-tertiary)] charkle-mono shrink-0">
            {shortcut}
          </span>
        )}
      </BaseMenu.Item>
    );
  },
);

MenuItem.displayName = 'MenuItem';

export interface MenuSeparatorProps {
  className?: string;
}

export const MenuSeparator: React.FC<MenuSeparatorProps> = ({ className = '' }) => (
  <BaseMenu.Separator
    className={`h-px my-1 mx-2 bg-[var(--win-stroke-divider)] ${className}`}
  />
);

export interface MenuLabelProps {
  className?: string;
  children: React.ReactNode;
}

export const MenuLabel: React.FC<MenuLabelProps> = ({ className = '', children }) => (
  <div
    className={`px-2.5 py-1 text-[11px] font-medium leading-[14px] text-[var(--text-tertiary)] select-none ${className}`}
  >
    {children}
  </div>
);

export interface MenuSubProps {
  label: React.ReactNode;
  icon?: React.ReactNode;
  disabled?: boolean;
  className?: string;
  popupClassName?: string;
  children: React.ReactNode;
}

/**
 * Cascading submenu with built-in safe-triangle hover intent via `@base-ui/react/menu`.
 */
export const MenuSub: React.FC<MenuSubProps> = ({
  label,
  icon,
  disabled = false,
  className = '',
  popupClassName = '',
  children,
}) => (
  <BaseMenu.SubmenuRoot>
    <BaseMenu.SubmenuTrigger
      disabled={disabled}
      className={[
        'w-full min-h-[32px] px-2.5 py-1.5 flex items-center gap-2.5 text-left text-[13px] leading-[18px]',
        'text-[var(--text-primary)] rounded-[var(--win-radius-control)] cursor-pointer outline-none select-none',
        'transition-colors duration-[83ms] ease-[var(--win-ease-out)]',
        'data-[highlighted]:bg-[var(--win-subtle-hover)] data-[popup-open]:bg-[var(--win-subtle-hover)]',
        'data-[disabled]:opacity-40 data-[disabled]:pointer-events-none',
        className,
      ]
        .filter(Boolean)
        .join(' ')}
    >
      {icon !== undefined && (
        <span className="w-4 h-4 inline-flex items-center justify-center shrink-0 text-[var(--text-secondary)]">
          {icon}
        </span>
      )}
      <span className="flex-1 min-w-0 truncate">{label}</span>
      <ChevronRight16Regular className="w-3.5 h-3.5 text-[var(--text-tertiary)] shrink-0 ml-auto" />
    </BaseMenu.SubmenuTrigger>
    <BaseMenu.Portal>
      <BaseMenu.Positioner
        side="right"
        align="start"
        sideOffset={2}
        alignOffset={-4}
        collisionPadding={10}
        positionMethod="fixed"
        className="z-[160] outline-none"
      >
        <BaseMenu.Popup
          data-charkle-popover-open="true"
          className={`${MENU_POPUP_CLASS} ${popupClassName}`}
          {...stopSurfacePropagation}
        >
          {children}
        </BaseMenu.Popup>
      </BaseMenu.Positioner>
    </BaseMenu.Portal>
  </BaseMenu.SubmenuRoot>
);
