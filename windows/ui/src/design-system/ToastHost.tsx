import React, { useEffect, useRef, useState } from 'react';
import { createPortal } from 'react-dom';
import { AlertCircle, CheckCircle2, Info, X } from 'lucide-react';
import { useCoordinatorStore, type ToastItem } from '../stores/coordinatorStore';

const ToastCard: React.FC<{
  toast: ToastItem;
  onDismiss: (id: string) => void;
}> = ({ toast, onDismiss }) => {
  const duration = toast.durationMs ?? (toast.actionLabel ? 5500 : 3500);
  const [paused, setPaused] = useState(false);
  const [closing, setClosing] = useState(false);
  const [remainingMs, setRemainingMs] = useState(duration);
  const lastTickRef = useRef<number>(Date.now());

  const triggerClose = () => {
    if (closing) return;
    setClosing(true);
    window.setTimeout(() => onDismiss(toast.id), 135);
  };

  useEffect(() => {
    if (paused || closing) return;
    lastTickRef.current = Date.now();
    const interval = window.setInterval(() => {
      const now = Date.now();
      const dt = now - lastTickRef.current;
      lastTickRef.current = now;
      setRemainingMs((prev) => {
        const next = Math.max(0, prev - dt);
        if (next === 0) {
          setClosing(true);
          window.setTimeout(() => onDismiss(toast.id), 135);
        }
        return next;
      });
    }, 60);
    return () => window.clearInterval(interval);
  }, [paused, closing, onDismiss, toast.id]);

  const progress = Math.max(0, Math.min(1, remainingMs / Math.max(1, duration)));

  return (
    <div
      data-closing={closing ? 'true' : undefined}
      onMouseEnter={() => setPaused(true)}
      onMouseLeave={() => setPaused(false)}
      onFocus={() => setPaused(true)}
      onBlur={() => setPaused(false)}
      className="charkle-toast-item charkle-glass pointer-events-auto relative overflow-hidden flex items-center gap-2.5 pl-3.5 pr-2.5 py-2.5 rounded-[var(--radius-popover-outer)] text-[13px] text-[var(--text-primary)]"
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

      <span className="leading-snug flex-1 min-w-0 charkle-wrap-safe">{toast.message}</span>

      {toast.actionLabel && toast.onAction && (
        <button
          type="button"
          onClick={() => {
            toast.onAction?.();
            triggerClose();
          }}
          className="charkle-pressable px-2 py-1 text-[12px] font-semibold text-[var(--accent)] hover:bg-[var(--accent-soft)] rounded-[var(--radius-chip)] cursor-pointer shrink-0"
        >
          {toast.actionLabel}
        </button>
      )}

      <button
        type="button"
        onClick={triggerClose}
        aria-label="关闭提示"
        className="charkle-pressable h-6 w-6 inline-flex items-center justify-center rounded-[var(--radius-chip)] text-[var(--text-tertiary)] hover:text-[var(--text-primary)] hover:bg-[var(--bg-subtle)] cursor-pointer shrink-0"
      >
        <X size={13} />
      </button>

      {toast.actionLabel && (
        <div
          aria-hidden="true"
          className="absolute bottom-0 left-0 right-0 h-[2px] bg-[var(--accent)]/45 origin-left"
          style={{ transform: `scaleX(${progress})` }}
        />
      )}
    </div>
  );
};

/**
 * Interruptible ToastHost implementing DESIGN.md P0-1:
 * - `@starting-style` enter (`180ms`) & `[data-closing]` exit (`130ms` strong ease-out)
 * - Hover & focus pause countdown; Undo toasts stay >= 5s with live countdown bar
 */
export const ToastHost: React.FC = () => {
  const toasts = useCoordinatorStore((s) => s.toasts);
  const dismissToast = useCoordinatorStore((s) => s.dismissToast);

  if (typeof document === 'undefined' || toasts.length === 0) return null;

  return createPortal(
    <div
      className="fixed bottom-5 right-5 z-[160] flex flex-col items-end gap-2 pointer-events-none max-w-[380px]"
      aria-live="polite"
    >
      {toasts.map((toast) => (
        <ToastCard key={toast.id} toast={toast} onDismiss={dismissToast} />
      ))}
    </div>,
    document.body,
  );
};
