import React from 'react';
import { createPortal } from 'react-dom';
import { AlertCircle, CheckCircle2, Info, X } from 'lucide-react';
import { useCoordinatorStore } from '../stores/coordinatorStore';
import type { ToastItem } from '../stores/coordinatorStore';

export const ToastHost: React.FC = () => {
  const toasts = useCoordinatorStore((s) => s.toasts);
  const dismissToast = useCoordinatorStore((s) => s.dismissToast);

  if (typeof document === 'undefined' || toasts.length === 0) return null;

  return createPortal(
    <div
      className="fixed bottom-5 right-5 z-[160] flex flex-col items-end gap-2 pointer-events-none max-w-[380px]"
      aria-live="polite"
    >
      {toasts.map((toast: ToastItem) => (
        <div
          key={toast.id}
          className="charkle-glass pointer-events-auto flex items-center gap-2.5 pl-3.5 pr-2.5 py-2.5 rounded-[var(--radius-popover-outer)] text-[13px] text-[var(--text-primary)] transition-[opacity,transform] duration-[var(--duration-sm)] ease-[var(--ease-out)]"
        >
          {toast.tone === 'success' && (
            <CheckCircle2 size={16} className="text-[var(--success)] shrink-0" />
          )}
          {toast.tone === 'error' && (
            <AlertCircle size={16} className="text-[var(--danger)] shrink-0" />
          )}
          {(!toast.tone || toast.tone === 'info') && (
            <Info size={16} className="text-[var(--accent)] shrink-0" />
          )}

          <span className="leading-snug flex-1 min-w-0 break-words">{toast.message}</span>

          {toast.actionLabel && toast.onAction && (
            <button
              type="button"
              onClick={() => {
                toast.onAction?.();
                dismissToast(toast.id);
              }}
              className="charkle-pressable px-2 py-1 text-[12px] font-semibold text-[var(--accent)] hover:bg-[var(--accent-soft)] rounded-[var(--radius-chip)] cursor-pointer shrink-0"
            >
              {toast.actionLabel}
            </button>
          )}

          <button
            type="button"
            onClick={() => dismissToast(toast.id)}
            aria-label="关闭提示"
            className="charkle-pressable h-6 w-6 inline-flex items-center justify-center rounded-[var(--radius-chip)] text-[var(--text-tertiary)] hover:text-[var(--text-primary)] hover:bg-[var(--bg-subtle)] cursor-pointer shrink-0"
          >
            <X size={13} />
          </button>
        </div>
      ))}
    </div>,
    document.body,
  );
};
