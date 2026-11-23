import React, { useEffect, useState } from 'react';
import { createPortal } from 'react-dom';
import { AlertCircle, AlertTriangle, CheckCircle2, Info, X } from 'lucide-react';
import { useCoordinatorStore } from '../stores/coordinatorStore';
import type { ToastItem } from '../stores/coordinatorStore';

const RING_RADIUS = 6;
const RING_CIRCUMFERENCE = Number((2 * Math.PI * RING_RADIUS).toFixed(3));

/**
 * Pure CSS `@keyframes` countdown ring (`stroke-dashoffset`) with zero JS frame loops
 * and zero per-frame React re-renders. Pauses cleanly via `animation-play-state: paused`
 * when the user hovers or focuses the toast.
 */
const ToastCountdownRing: React.FC<{
  durationMs: number;
  paused: boolean;
}> = ({ durationMs, paused }) => {
  const safeDuration = Math.max(100, durationMs);
  return (
    <svg
      width={16}
      height={16}
      viewBox="0 0 16 16"
      aria-hidden="true"
      className="shrink-0 -rotate-90"
    >
      <circle
        cx={8}
        cy={8}
        r={RING_RADIUS}
        fill="none"
        stroke="currentColor"
        strokeOpacity={0.14}
        strokeWidth={2}
      />
      <circle
        cx={8}
        cy={8}
        r={RING_RADIUS}
        fill="none"
        stroke="var(--accent)"
        strokeWidth={2}
        strokeLinecap="round"
        strokeDasharray={RING_CIRCUMFERENCE}
        className="charkle-toast-countdown"
        style={{
          ['--ring-circumference' as string]: `${RING_CIRCUMFERENCE}`,
          animationDuration: `${safeDuration}ms`,
          animationPlayState: paused ? 'paused' : 'running',
        }}
      />
    </svg>
  );
};

const ToastRow: React.FC<{
  toast: ToastItem;
  onPause: (id: string) => void;
  onResume: (id: string) => void;
  onAction: (id: string) => void;
  onDismiss: (id: string) => void;
}> = ({ toast, onPause, onResume, onAction, onDismiss }) => {
  const [entered, setEntered] = useState(false);

  useEffect(() => {
    let raf2 = 0;
    const raf1 = requestAnimationFrame(() => {
      raf2 = requestAnimationFrame(() => setEntered(true));
    });
    return () => {
      cancelAnimationFrame(raf1);
      cancelAnimationFrame(raf2);
    };
  }, []);

  const hasAction = Boolean(toast.actionLabel && toast.onAction);
  const showRing = hasAction || (toast.durationMs ?? 0) >= 4800;
  const state = toast.exiting ? 'closing' : entered ? 'open' : 'entering';

  return (
    <div
      data-state={state}
      tabIndex={0}
      role={toast.tone === 'error' ? 'alert' : 'status'}
      onMouseEnter={() => onPause(toast.id)}
      onMouseLeave={() => onResume(toast.id)}
      onFocus={() => onPause(toast.id)}
      onBlur={(e) => {
        if (!e.currentTarget.contains(e.relatedTarget as Node | null)) {
          onResume(toast.id);
        }
      }}
      onKeyDown={(e) => {
        if (e.key === 'Escape') {
          e.preventDefault();
          e.stopPropagation();
          onDismiss(toast.id);
        }
      }}
      className={[
        'charkle-glass charkle-toast-item pointer-events-auto flex items-center gap-2',
        'pl-3 pr-2 py-2 rounded-[var(--radius-popover-outer)] text-[12.5px] text-[var(--text-primary)]',
        'max-w-[380px] focus-visible:outline-2 focus-visible:outline-offset-2 focus-visible:outline-[var(--accent)]',
      ].join(' ')}
    >
      {showRing ? (
        <ToastCountdownRing
          durationMs={toast.durationMs ?? 5200}
          paused={Boolean(toast.paused)}
        />
      ) : toast.tone === 'success' ? (
        <CheckCircle2 size={15} className="text-[var(--success)] shrink-0" />
      ) : toast.tone === 'warning' ? (
        <AlertTriangle size={15} className="text-[var(--warning)] shrink-0" />
      ) : toast.tone === 'error' ? (
        <AlertCircle size={15} className="text-[var(--danger)] shrink-0" />
      ) : (
        <Info size={15} className="text-[var(--accent)] shrink-0" />
      )}

      <span className="leading-snug flex-1 min-w-0 font-medium charkle-wrap-anywhere">
        {toast.message}
      </span>

      {hasAction && (
        <button
          type="button"
          onClick={() => onAction(toast.id)}
          className="charkle-pressable px-2.5 py-1 text-[12px] font-semibold text-[var(--accent)] bg-[var(--accent-soft)] hover:bg-[var(--accent)]/18 rounded-[var(--radius-popover-inner)] cursor-pointer shrink-0 focus-visible:outline-2 focus-visible:outline-offset-1 focus-visible:outline-[var(--accent)]"
        >
          {toast.actionLabel}
        </button>
      )}

      <button
        type="button"
        onClick={() => onDismiss(toast.id)}
        aria-label="关闭提示"
        className="charkle-pressable h-6 w-6 inline-flex items-center justify-center rounded-[var(--radius-popover-inner)] text-[var(--text-tertiary)] hover:text-[var(--text-primary)] hover:bg-[var(--bg-subtle)] cursor-pointer shrink-0 focus-visible:outline-2 focus-visible:outline-offset-1 focus-visible:outline-[var(--accent)]"
      >
        <X size={12.5} />
      </button>
    </div>
  );
};

export const ToastHost: React.FC = () => {
  const toasts = useCoordinatorStore((s) => s.toasts);
  const pauseToast = useCoordinatorStore((s) => s.pauseToast);
  const resumeToast = useCoordinatorStore((s) => s.resumeToast);
  const triggerToastAction = useCoordinatorStore((s) => s.triggerToastAction);
  const dismissToast = useCoordinatorStore((s) => s.dismissToast);

  if (typeof document === 'undefined' || toasts.length === 0) return null;

  return createPortal(
    <div
      className="fixed top-4 right-5 z-[160] flex flex-col items-end gap-2 pointer-events-none max-w-[380px]"
      aria-live="polite"
    >
      {toasts.map((toast) => (
        <ToastRow
          key={toast.id}
          toast={toast}
          onPause={pauseToast}
          onResume={resumeToast}
          onAction={triggerToastAction}
          onDismiss={dismissToast}
        />
      ))}
    </div>,
    document.body,
  );
};
