import React, { useEffect, useRef, useState } from 'react';
import { createPortal } from 'react-dom';
import { AlertCircle, CheckCircle2, Info, X } from 'lucide-react';
import { useCoordinatorStore, type ToastItem } from '../stores/coordinatorStore';

const RING_RADIUS = 6.5;
const RING_CIRCUMFERENCE = 2 * Math.PI * RING_RADIUS;

const ToastCard: React.FC<{
  toast: ToastItem;
  onDismiss: (id: string) => void;
}> = ({ toast, onDismiss }) => {
  const duration = toast.durationMs ?? (toast.actionLabel ? 4800 : 2800);
  const [paused, setPaused] = useState(false);
  const [hovered, setHovered] = useState(false);
  const [closing, setClosing] = useState(false);
  const [remainingMs, setRemainingMs] = useState(duration);
  const lastTickRef = useRef<number>(Date.now());
  const closingRef = useRef(false);

  const triggerClose = () => {
    if (closingRef.current) return;
    closingRef.current = true;
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
      setRemainingMs((prev) => Math.max(0, prev - dt));
    }, 50);
    return () => window.clearInterval(interval);
  }, [paused, closing]);

  useEffect(() => {
    if (remainingMs === 0 && !closingRef.current) {
      closingRef.current = true;
      setClosing(true);
      const timer = window.setTimeout(() => onDismiss(toast.id), 135);
      return () => window.clearTimeout(timer);
    }
    return undefined;
  }, [remainingMs, onDismiss, toast.id]);

  const progress = Math.max(0, Math.min(1, remainingMs / Math.max(1, duration)));
  const dashOffset = RING_CIRCUMFERENCE * (1 - progress);
  const showClose = Boolean(toast.actionLabel) || hovered;

  return (
    <div
      data-closing={closing ? 'true' : undefined}
      data-no-lens="true"
      onMouseEnter={() => {
        setHovered(true);
        setPaused(true);
      }}
      onMouseLeave={() => {
        setHovered(false);
        setPaused(false);
      }}
      onFocus={() => setPaused(true)}
      onBlur={() => setPaused(false)}
      onKeyDown={(e) => {
        if (e.key === 'Escape') {
          e.stopPropagation();
          triggerClose();
        }
      }}
      className={[
        'charkle-toast-item charkle-glass charkle-toast-glass pointer-events-auto relative overflow-hidden flex items-center gap-2 py-2 rounded-[var(--radius-popover-outer)] text-[12.5px] text-[var(--text-primary)]',
        showClose ? 'pl-3.5 pr-2' : 'px-3.5',
      ].join(' ')}
    >
      {toast.actionLabel ? (
        <svg
          width="16"
          height="16"
          viewBox="0 0 16 16"
          aria-hidden="true"
          className="shrink-0 -rotate-90"
        >
          <circle
            cx="8"
            cy="8"
            r={RING_RADIUS}
            fill="none"
            stroke="currentColor"
            strokeOpacity="0.14"
            strokeWidth="2"
          />
          <circle
            cx="8"
            cy="8"
            r={RING_RADIUS}
            fill="none"
            stroke="var(--accent)"
            strokeWidth="2"
            strokeLinecap="round"
            strokeDasharray={RING_CIRCUMFERENCE}
            strokeDashoffset={dashOffset}
          />
        </svg>
      ) : toast.tone === 'success' ? (
        <CheckCircle2 size={15} className="text-[var(--success)] shrink-0" />
      ) : toast.tone === 'error' ? (
        <AlertCircle size={15} className="text-[var(--danger)] shrink-0" />
      ) : (
        <Info size={15} className="text-[var(--accent)] shrink-0" />
      )}

      <span className="leading-snug flex-1 min-w-0 font-medium charkle-wrap-safe">
        {toast.message}
      </span>

      {toast.actionLabel && toast.onAction && (
        <button
          type="button"
          onClick={() => {
            toast.onAction?.();
            triggerClose();
          }}
          className="charkle-pressable px-2.5 py-1 text-[12px] font-semibold text-[var(--accent)] bg-[var(--accent-soft)] hover:brightness-95 rounded-[var(--radius-popover-inner)] cursor-pointer shrink-0"
        >
          {toast.actionLabel}
        </button>
      )}

      {showClose && (
        <button
          type="button"
          onClick={triggerClose}
          aria-label="关闭提示"
          className="charkle-pressable h-6 w-6 inline-flex items-center justify-center rounded-[var(--radius-popover-inner)] text-[var(--text-tertiary)] hover:text-[var(--text-primary)] hover:bg-[var(--bg-subtle)] cursor-pointer shrink-0"
        >
          <X size={12.5} />
        </button>
      )}
    </div>
  );
};

/**
 * Interactive top-trailing Liquid Glass ToastHost matching macOS `CharkleToastOverlay.swift`:
 * - Click-through outside pills; smooth `@starting-style` enter (`180ms`) & `[data-closing]` exit (`130ms`)
 * - Hover & focus pause countdown; action/Undo toasts display a live circular SVG countdown ring
 */
export const ToastHost: React.FC = () => {
  const toasts = useCoordinatorStore((s) => s.toasts);
  const dismissToast = useCoordinatorStore((s) => s.dismissToast);

  if (typeof document === 'undefined' || toasts.length === 0) return null;

  return createPortal(
    <div
      className="fixed top-[52px] right-5 z-[160] flex flex-col items-end gap-2 pointer-events-none max-w-[380px]"
      aria-live="polite"
      onMouseDown={(e) => e.stopPropagation()}
      onPointerDown={(e) => e.stopPropagation()}
      onClick={(e) => e.stopPropagation()}
    >
      {toasts.map((toast) => (
        <ToastCard key={toast.id} toast={toast} onDismiss={dismissToast} />
      ))}
    </div>,
    document.body,
  );
};
