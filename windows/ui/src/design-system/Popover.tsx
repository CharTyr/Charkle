import React, { useCallback, useEffect, useLayoutEffect, useRef, useState } from 'react';
import { createPortal } from 'react-dom';

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
  anchorEl?: HTMLElement | null;
  anchorPoint?: { x: number; y: number } | null;
  placement?: PopoverPlacement;
  offset?: number;
  glass?: boolean;
  className?: string;
  children: React.ReactNode;
}

interface ComputedPosition {
  top: number;
  left: number;
  transformOrigin: string;
}

/**
 * Origin-aware interruptible Popover (DESIGN.md §6.2 & §6.3):
 * - Binds `transform-origin` to trigger edge and auto-flips when near viewport edge
 * - Uses CSS transition (`@starting-style` + `[data-closing="true"]`) with `160ms` in / `110ms` out
 */
export const Popover: React.FC<PopoverProps> = ({
  open,
  onOpenChange,
  anchorEl,
  anchorPoint,
  placement = 'bottom-start',
  offset = 8,
  glass = true,
  className = '',
  children,
}) => {
  const panelRef = useRef<HTMLDivElement | null>(null);
  const [rendered, setRendered] = useState(open);
  const [closing, setClosing] = useState(false);
  const [pos, setPos] = useState<ComputedPosition | null>(null);

  useEffect(() => {
    if (open) {
      setClosing(false);
      setRendered(true);
      return;
    }
    if (!rendered) return;
    setClosing(true);
    const timer = window.setTimeout(() => {
      setRendered(false);
      setClosing(false);
    }, 115);
    return () => window.clearTimeout(timer);
  }, [open, rendered]);

  const computePosition = useCallback(() => {
    const panel = panelRef.current;
    if (!panel) return;
    const vw = window.innerWidth;
    const vh = window.innerHeight;
    const margin = 10;
    const panelRect = panel.getBoundingClientRect();
    const pw = panelRect.width || 220;
    const ph = panelRect.height || 140;

    if (anchorPoint) {
      let left = anchorPoint.x;
      let top = anchorPoint.y;
      let originX = 'left';
      let originY = 'top';
      if (left + pw > vw - margin) {
        left = anchorPoint.x - pw;
        originX = 'right';
      }
      if (top + ph > vh - margin) {
        top = anchorPoint.y - ph;
        originY = 'bottom';
      }
      const clampedLeft = Math.max(margin, Math.min(Math.max(margin, vw - pw - margin), left));
      const clampedTop = Math.max(margin, Math.min(Math.max(margin, vh - ph - margin), top));
      setPos({ top: clampedTop, left: clampedLeft, transformOrigin: `${originY} ${originX}` });
      return;
    }

    if (!anchorEl) return;
    const rect = anchorEl.getBoundingClientRect();
    const [sideRaw, align = 'start'] = placement.split('-') as [
      'top' | 'bottom' | 'left' | 'right',
      'start' | 'center' | 'end',
    ];
    let side = sideRaw;
    if (side === 'bottom' && rect.bottom + offset + ph > vh - margin && rect.top - offset - ph >= margin) {
      side = 'top';
    } else if (side === 'top' && rect.top - offset - ph < margin && rect.bottom + offset + ph <= vh - margin) {
      side = 'bottom';
    } else if (side === 'right' && rect.right + offset + pw > vw - margin && rect.left - offset - pw >= margin) {
      side = 'left';
    } else if (side === 'left' && rect.left - offset - pw < margin && rect.right + offset + pw <= vw - margin) {
      side = 'right';
    }

    let top = 0;
    let left = 0;
    let originX = 'left';
    let originY = 'top';

    if (side === 'bottom' || side === 'top') {
      top = side === 'bottom' ? rect.bottom + offset : rect.top - offset - ph;
      originY = side === 'bottom' ? 'top' : 'bottom';
      if (align === 'start') {
        left = rect.left;
        originX = 'left';
      } else if (align === 'center') {
        left = rect.left + rect.width / 2 - pw / 2;
        originX = 'center';
      } else {
        left = rect.right - pw;
        originX = 'right';
      }
    } else {
      left = side === 'right' ? rect.right + offset : rect.left - offset - pw;
      originX = side === 'right' ? 'left' : 'right';
      top = rect.top;
      originY = 'top';
    }

    setPos({
      top: Math.max(margin, Math.min(Math.max(margin, vh - ph - margin), top)),
      left: Math.max(margin, Math.min(Math.max(margin, vw - pw - margin), left)),
      transformOrigin: `${originY} ${originX}`,
    });
  }, [anchorEl, anchorPoint, placement, offset]);

  useLayoutEffect(() => {
    if (!rendered) {
      setPos(null);
      return;
    }
    computePosition();
    const raf = requestAnimationFrame(computePosition);
    let ro: ResizeObserver | null = null;
    if (panelRef.current && typeof ResizeObserver !== 'undefined') {
      ro = new ResizeObserver(computePosition);
      ro.observe(panelRef.current);
    }
    window.addEventListener('resize', computePosition);
    window.addEventListener('scroll', computePosition, true);
    return () => {
      cancelAnimationFrame(raf);
      ro?.disconnect();
      window.removeEventListener('resize', computePosition);
      window.removeEventListener('scroll', computePosition, true);
    };
  }, [rendered, computePosition]);

  useEffect(() => {
    if (!open) return;
    const handlePointerDown = (e: MouseEvent) => {
      const target = e.target as Node | null;
      if (!target) return;
      if (panelRef.current?.contains(target)) return;
      if (anchorEl?.contains(target)) return;
      onOpenChange(false);
    };
    const handleKeyDown = (e: KeyboardEvent) => {
      if (e.key === 'Escape' && !e.defaultPrevented) {
        e.preventDefault();
        e.stopPropagation();
        e.stopImmediatePropagation();
        onOpenChange(false);
      }
    };
    document.addEventListener('mousedown', handlePointerDown);
    window.addEventListener('keydown', handleKeyDown, true);
    return () => {
      document.removeEventListener('mousedown', handlePointerDown);
      window.removeEventListener('keydown', handleKeyDown, true);
    };
  }, [open, anchorEl, onOpenChange]);

  if (!rendered || typeof document === 'undefined') return null;

  return createPortal(
    <div
      ref={panelRef}
      role="dialog"
      data-charkle-popover-open={open ? 'true' : undefined}
      data-closing={closing ? 'true' : undefined}
      data-no-lens="true"
      onMouseDown={(e) => e.stopPropagation()}
      onPointerDown={(e) => e.stopPropagation()}
      onClick={(e) => e.stopPropagation()}
      onDoubleClick={(e) => e.stopPropagation()}
      onContextMenu={(e) => e.stopPropagation()}
      className={[
        'fixed z-[120] rounded-[var(--radius-popover-outer)] charkle-popover-panel charkle-scroll overflow-y-auto',
        glass
          ? 'charkle-glass'
          : 'bg-[var(--bg-elevated)] border border-[var(--border-hairline)] shadow-xl',
        className,
      ].join(' ')}
      style={{
        top: pos ? pos.top : -9999,
        left: pos ? pos.left : -9999,
        maxHeight: 'calc(100vh - 20px)',
        visibility: pos ? 'visible' : 'hidden',
        transformOrigin: pos?.transformOrigin ?? 'top left',
      }}
    >
      {children}
    </div>,
    document.body,
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
 * In-place Popconfirm for single irreversible actions (DESIGN.md §7.3).
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
    className="w-[248px] p-3"
  >
    <div className="text-[13px] font-semibold text-[var(--text-primary)] charkle-heading">
      {title}
    </div>
    {description && (
      <p className="mt-1 text-[12px] text-[var(--text-secondary)] leading-relaxed charkle-prose">
        {description}
      </p>
    )}
    <div className="mt-3 flex items-center justify-end gap-1.5">
      <button
        type="button"
        onClick={() => onOpenChange(false)}
        className="charkle-pressable h-7 px-2.5 text-[12px] font-medium rounded-[var(--radius-chip)] bg-[var(--bg-subtle)] text-[var(--text-primary)] cursor-pointer"
      >
        取消
      </button>
      <button
        type="button"
        onClick={() => {
          onOpenChange(false);
          onConfirm();
        }}
        className="charkle-pressable h-7 px-2.5 text-[12px] font-medium rounded-[var(--radius-chip)] bg-[var(--danger)] text-white cursor-pointer"
      >
        {confirmLabel}
      </button>
    </div>
  </Popover>
);
