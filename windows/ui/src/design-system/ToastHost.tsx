import React, { useEffect, useRef, useState } from 'react';
import { createPortal } from 'react-dom';
import {
  CheckmarkCircle20Filled,
  Dismiss16Regular,
  ErrorCircle20Filled,
  Info20Filled,
} from '@fluentui/react-icons';
import { useCoordinatorStore, type ToastItem } from '../stores/coordinatorStore';
import { AnimatePresence, m, WIN_TRANSITION_EXIT, WIN_TRANSITION_FAST } from './MotionPrimitives';

const RING_RADIUS = 6.5;
const RING_CIRCUMFERENCE = 2 * Math.PI * RING_RADIUS;

const ToastCard: React.FC<{
  toast: ToastItem;
  onDismiss: (id: string) => void;
}> = ({ toast, onDismiss }) => {
  const duration = toast.durationMs ?? (toast.actionLabel ? 4800 : 2800);
  const hasActionRing = Boolean(toast.actionLabel);
  const [hovered, setHovered] = useState(false);
  const [focused, setFocused] = useState(false);
  const paused = hovered || focused;
  const [remainingMs, setRemainingMs] = useState(duration);
  const remainingRef = useRef<number>(duration);
  const lastTickRef = useRef<number>(Date.now());
  const dismissedRef = useRef(false);

  const triggerClose = () => {
    if (dismissedRef.current) return;
    dismissedRef.current = true;
    onDismiss(toast.id);
  };

  useEffect(() => {
    if (paused || dismissedRef.current) return;
    const startedAt = Date.now();
    lastTickRef.current = startedAt;

    if (hasActionRing) {
      const interval = window.setInterval(() => {
        const now = Date.now();
        const dt = now - lastTickRef.current;
        lastTickRef.current = now;
        remainingRef.current = Math.max(0, remainingRef.current - dt);
        setRemainingMs(remainingRef.current);
        if (remainingRef.current === 0 && !dismissedRef.current) {
          dismissedRef.current = true;
          onDismiss(toast.id);
        }
      }, 50);
      return () => window.clearInterval(interval);
    }

    // Plain toast without visual countdown ring: single one-shot timer (zero 20Hz re-renders)
    const timer = window.setTimeout(() => {
      if (!dismissedRef.current) {
        dismissedRef.current = true;
        onDismiss(toast.id);
      }
    }, Math.max(0, remainingRef.current));
    return () => {
      window.clearTimeout(timer);
      const elapsed = Date.now() - startedAt;
      remainingRef.current = Math.max(0, remainingRef.current - elapsed);
    };
  }, [paused, hasActionRing, onDismiss, toast.id]);

  const progress = Math.max(0, Math.min(1, remainingMs / Math.max(1, duration)));
  const dashOffset = RING_CIRCUMFERENCE * (1 - progress);
  const showClose = hasActionRing || hovered;

  return (
    <m.div
      layout="position"
      initial={{ opacity: 0, y: -8, scale: 0.96 }}
      animate={{ opacity: 1, y: 0, scale: 1, transition: WIN_TRANSITION_FAST }}
      exit={{ opacity: 0, scale: 0.96, transition: WIN_TRANSITION_EXIT }}
      onMouseEnter={() => setHovered(true)}
      onMouseLeave={() => setHovered(false)}
      onFocus={() => setFocused(true)}
      onBlur={() => setFocused(false)}
      onKeyDown={(e) => {
        if (e.key === 'Escape') {
          e.stopPropagation();
          triggerClose();
        }
      }}
      className={[
        'win-acrylic pointer-events-auto relative overflow-hidden flex items-center gap-2.5 py-2',
        'rounded-[var(--win-radius-overlay)] text-[13px] leading-[18px] text-[var(--text-primary)]',
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
            strokeOpacity="0.16"
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
        <CheckmarkCircle20Filled className="w-[18px] h-[18px] text-[var(--success)] shrink-0" />
      ) : toast.tone === 'error' ? (
        <ErrorCircle20Filled className="w-[18px] h-[18px] text-[var(--danger)] shrink-0" />
      ) : (
        <Info20Filled className="w-[18px] h-[18px] text-[var(--accent)] shrink-0" />
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
          className="charkle-pressable px-2.5 py-1 text-[12px] font-semibold text-[var(--accent)] bg-[var(--accent-soft)] hover:brightness-95 rounded-[var(--win-radius-control)] cursor-pointer shrink-0"
        >
          {toast.actionLabel}
        </button>
      )}

      {showClose && (
        <button
          type="button"
          onClick={triggerClose}
          aria-label="关闭提示"
          className="charkle-pressable h-6 w-6 inline-flex items-center justify-center rounded-[var(--win-radius-control)] text-[var(--text-tertiary)] hover:text-[var(--text-primary)] hover:bg-[var(--win-subtle-hover)] cursor-pointer shrink-0"
        >
          <Dismiss16Regular className="w-3.5 h-3.5" />
        </button>
      )}
    </m.div>
  );
};

/**
 * Windows 11 InfoBar-inspired top-trailing Acrylic ToastHost powered by `AnimatePresence`:
 * - Click-through container; smooth 167ms entry & 135ms fast-out exit
 * - Hover & focus pause countdown; action/Undo toasts display a circular SVG countdown ring
 */
export const ToastHost: React.FC = () => {
  const toasts = useCoordinatorStore((s) => s.toasts);
  const dismissToast = useCoordinatorStore((s) => s.dismissToast);

  if (typeof document === 'undefined') return null;

  return createPortal(
    <div
      className="fixed top-[52px] right-5 z-[160] flex flex-col items-end gap-2 pointer-events-none max-w-[380px]"
      aria-live="polite"
      onMouseDown={(e) => e.stopPropagation()}
      onPointerDown={(e) => e.stopPropagation()}
      onClick={(e) => e.stopPropagation()}
    >
      <AnimatePresence initial={false}>
        {toasts.map((toast) => (
          <ToastCard key={toast.id} toast={toast} onDismiss={dismissToast} />
        ))}
      </AnimatePresence>
    </div>,
    document.body,
  );
};
