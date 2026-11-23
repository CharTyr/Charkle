import React, { useEffect, useRef } from 'react';
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
  className?: string;
  children: React.ReactNode;
}

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
  className = '',
  children,
}) => {
  const onCloseRef = useRef(onClose);
  onCloseRef.current = onClose;

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

  if (!open || typeof document === 'undefined') return null;

  return createPortal(
    <div
      className="fixed inset-0 z-[100] flex items-center justify-center p-4 sm:p-6"
      role="dialog"
      aria-modal="true"
    >
      <div
        className="charkle-modal-backdrop fixed inset-0 bg-black/42 backdrop-blur-[3px]"
        onClick={closeOnBackdrop ? onClose : undefined}
      />

      <div
        className={[
          'charkle-modal-panel relative z-10 w-full flex flex-col max-h-[90vh] overflow-hidden',
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
