import { useEffect, useRef, useState } from 'react';

export type PresenceState = 'entering' | 'open' | 'closing';

export function prefersReducedMotion(): boolean {
  if (typeof window === 'undefined' || !window.matchMedia) return false;
  return window.matchMedia('(prefers-reduced-motion: reduce)').matches;
}

/**
 * Mounted-exit presence state machine for interruptible CSS transitions:
 * - Opening mounts immediately in `'entering'`, then promotes to `'open'` on the next paint frame.
 * - Closing switches to `'closing'` and keeps the DOM mounted for `exitDurationMs` so exit
 *   transitions finish smoothly without 0ms hard-unmount snaps.
 * - Rapidly re-opening mid-exit cancels the unmount timer and transitions cleanly back to `'open'`.
 */
export function usePresence(
  open: boolean,
  exitDurationMs = 130,
): { rendered: boolean; state: PresenceState } {
  const [rendered, setRendered] = useState(open);
  const [state, setState] = useState<PresenceState>(open ? 'open' : 'closing');
  const exitTimerRef = useRef<number | null>(null);

  useEffect(() => {
    if (exitTimerRef.current !== null) {
      window.clearTimeout(exitTimerRef.current);
      exitTimerRef.current = null;
    }

    if (open) {
      setRendered(true);
      setState('entering');
      let raf2 = 0;
      const raf1 = requestAnimationFrame(() => {
        raf2 = requestAnimationFrame(() => {
          setState('open');
        });
      });
      return () => {
        cancelAnimationFrame(raf1);
        cancelAnimationFrame(raf2);
      };
    }

    if (rendered) {
      setState('closing');
      const effectiveExitMs = prefersReducedMotion() ? Math.min(exitDurationMs, 150) : exitDurationMs;
      exitTimerRef.current = window.setTimeout(() => {
        exitTimerRef.current = null;
        setRendered(false);
      }, effectiveExitMs);
      return () => {
        if (exitTimerRef.current !== null) {
          window.clearTimeout(exitTimerRef.current);
          exitTimerRef.current = null;
        }
      };
    }

    return undefined;
  }, [open, rendered, exitDurationMs]);

  return { rendered, state };
}
