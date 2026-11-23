import React, { useEffect, useRef, useState } from 'react';
import { createPortal } from 'react-dom';
import { X } from 'lucide-react';

export type ModalWidth = 'sm' | 'md' | 'lg' | 'xl' | 'studio';

const WIDTH_CLASS: Record<ModalWidth, string> = {
  sm: 'max-w-[420px]',
  md: 'max-w-[540px]',
  lg: 'max-w-[740px]',
  xl: 'max-w-[920px]',
  studio: 'max-w-[1040px]',
};

export interface ModalShellProps {
  open: boolean;
  onClose: () => void;
  title?: React.ReactNode;
  subtitle?: React.ReactNode;
  width?: ModalWidth;
  headerRight?: React.ReactNode;
  footer?: React.ReactNode;
  noPadding?: boolean;
  hideCloseButton?: boolean;
  closeOnBackdrop?: boolean;
  /** True for 0ms instant modals like Ctrl+J Jump Anywhere (DESIGN.md §6.1). */
  instant?: boolean;
  className?: string;
  children: React.ReactNode;
}

/**
 * Unified ModalShell implementing DESIGN.md P0-2:
 * - Soft GPU radial dimming scrim (Light 0.075->0.165, Dark 0.34->0.50, zero backdrop-blur jank)
 * - Interruptible enter/exit transition (240ms in / 170ms strong ease-out out), or 0ms for instant mode
 */
export const ModalShell: React.FC<ModalShellProps> = ({
  open,
  onClose,
  title,
  subtitle,
  width = 'md',
  headerRight,
  footer,
  noPadding = false,
  hideCloseButton = false,
  closeOnBackdrop = true,
  instant = false,
  className = '',
  children,
}) => {
  const onCloseRef = useRef(onClose);
  onCloseRef.current = onClose;

  const [rendered, setRendered] = useState(open);
  const [closing, setClosing] = useState(false);

  useEffect(() => {
    if (open) {
      setClosing(false);
      setRendered(true);
      return;
    }
    if (!rendered) return;
    if (instant) {
      setRendered(false);
      setClosing(false);
      return;
    }
    setClosing(true);
    const timer = window.setTimeout(() => {
      setRendered(false);
      setClosing(false);
    }, 175);
    return () => window.clearTimeout(timer);
  }, [open, rendered, instant]);

  useEffect(() => {
    if (!open) return;
    const handleKey = (e: KeyboardEvent) => {
      if (e.key === 'Escape') {
        e.preventDefault();
        e.stopPropagation();
        onCloseRef.current();
      }
    };
    window.addEventListener('keydown', handleKey, true);
    return () => window.removeEventListener('keydown', handleKey, true);
  }, [open]);

  if (!rendered || typeof document === 'undefined') return null;

  return createPortal(
    <div
      className="fixed inset-0 z-[100] flex items-center justify-center p-4 sm:p-6"
      role="dialog"
      aria-modal="true"
    >
      <div
        data-closing={closing ? 'true' : undefined}
        className={instant ? 'fixed inset-0' : 'charkle-modal-scrim fixed inset-0'}
        style={instant ? { background: 'var(--modal-scrim)' } : undefined}
        onClick={closeOnBackdrop ? onClose : undefined}
      />

      <div
        data-closing={closing ? 'true' : undefined}
        className={[
          instant ? '' : 'charkle-modal-panel',
          'relative z-10 w-full flex flex-col max-h-[90vh] overflow-hidden',
          'rounded-[var(--radius-dock-outer)] bg-[var(--bg-elevated)] border border-[var(--border-hairline)]',
          'shadow-[0_24px_64px_rgba(0,0,0,0.22)]',
          WIDTH_CLASS[width],
          className,
        ].join(' ')}
      >
        {(title || !hideCloseButton || headerRight) && (
          <div className="flex items-center justify-between gap-3 px-5 py-3.5 border-b border-[var(--border-hairline)] shrink-0">
            <div className="min-w-0">
              {title && (
                <h2 className="text-[15px] font-semibold tracking-[-0.01em] text-[var(--text-primary)] truncate">
                  {title}
                </h2>
              )}
              {subtitle && (
                <p className="text-[12px] text-[var(--text-secondary)] mt-0.5 truncate">
                  {subtitle}
                </p>
              )}
            </div>
            <div className="flex items-center gap-2 shrink-0">
              {headerRight}
              {!hideCloseButton && (
                <button
                  type="button"
                  onClick={onClose}
                  aria-label="关闭"
                  className="charkle-pressable h-7 w-7 inline-flex items-center justify-center rounded-[var(--radius-chip)] text-[var(--text-secondary)] hover:text-[var(--text-primary)] hover:bg-[var(--bg-subtle)] cursor-pointer"
                >
                  <X size={16} />
                </button>
              )}
            </div>
          </div>
        )}

        <div className={`flex-1 min-h-0 overflow-y-auto charkle-scroll ${noPadding ? '' : 'p-5'}`}>
          {children}
        </div>

        {footer && (
          <div className="flex items-center justify-end gap-2 px-5 py-3 border-t border-[var(--border-hairline)] bg-[var(--bg-gallery)]/50 shrink-0">
            {footer}
          </div>
        )}
      </div>
    </div>,
    document.body,
  );
};
