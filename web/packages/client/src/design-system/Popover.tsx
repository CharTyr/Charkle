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
 * Trigger-origin aware Popover strictly implementing Kubai Popover Origin Note:
 * scales `0.96 -> 1.0` with `opacity: 0 -> 1` from the exact trigger edge (and flips
 * transform-origin automatically if the popover flips above or shifts to fit viewport).
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
  const [pos, setPos] = useState<ComputedPosition | null>(null);

  const computePosition = useCallback(() => {
    const panel = panelRef.current;
    if (!panel) return;

    const vw = window.innerWidth;
    const vh = window.innerHeight;
    const margin = 10;
    const panelRect = panel.getBoundingClientRect();
    const pw = panelRect.width || 240;
    const ph = panelRect.height || 160;

    if (anchorPoint) {
      let left = anchorPoint.x;
      let top = anchorPoint.y;
      let originX = 'left';
      let originY = 'top';

      if (left + pw > vw - margin) {
        left = Math.max(margin, anchorPoint.x - pw);
        originX = 'right';
      }
      if (top + ph > vh - margin) {
        top = Math.max(margin, anchorPoint.y - ph);
        originY = 'bottom';
      }
      setPos({ top, left, transformOrigin: `${originY} ${originX}` });
      return;
    }

    if (!anchorEl) return;
    const rect = anchorEl.getBoundingClientRect();

    const [sideRaw, align = 'start'] = placement.split('-') as [
      'top' | 'bottom' | 'left' | 'right',
      'start' | 'center' | 'end',
    ];
    let side = sideRaw;

    // Auto-flip vertical placement if overflowing viewport
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

    // Clamp to viewport
    const clampedLeft = Math.max(margin, Math.min(vw - pw - margin, left));
    const clampedTop = Math.max(margin, Math.min(vh - ph - margin, top));

    setPos({
      top: clampedTop,
      left: clampedLeft,
      transformOrigin: `${originY} ${originX}`,
    });
  }, [anchorEl, anchorPoint, placement, offset]);

  useLayoutEffect(() => {
    if (!open) {
      setPos(null);
      return;
    }
    computePosition();
    const raf = requestAnimationFrame(computePosition);
    window.addEventListener('resize', computePosition);
    window.addEventListener('scroll', computePosition, true);
    return () => {
      cancelAnimationFrame(raf);
      window.removeEventListener('resize', computePosition);
      window.removeEventListener('scroll', computePosition, true);
    };
  }, [open, computePosition]);

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
      if (e.key === 'Escape') {
        e.stopPropagation();
        onOpenChange(false);
      }
    };

    document.addEventListener('mousedown', handlePointerDown);
    document.addEventListener('keydown', handleKeyDown);
    return () => {
      document.removeEventListener('mousedown', handlePointerDown);
      document.removeEventListener('keydown', handleKeyDown);
    };
  }, [open, anchorEl, onOpenChange]);

  if (!open || typeof document === 'undefined') return null;

  return createPortal(
    <div
      ref={panelRef}
      role="dialog"
      className={[
        'fixed z-[120] rounded-[var(--radius-popover-outer)] charkle-popover-enter',
        glass
          ? 'charkle-glass'
          : 'bg-[var(--bg-elevated)] border border-[var(--border-hairline)] shadow-xl',
        className,
      ].join(' ')}
      style={{
        top: pos ? pos.top : -9999,
        left: pos ? pos.left : -9999,
        visibility: pos ? 'visible' : 'hidden',
        transformOrigin: pos?.transformOrigin ?? 'top left',
      }}
    >
      {children}
    </div>,
    document.body,
  );
};
