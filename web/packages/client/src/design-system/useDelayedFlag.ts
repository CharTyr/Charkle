import { useEffect, useRef, useState } from 'react';

/**
 * Anti-flicker delayed visibility hook (`DESIGN.md` §7.6):
 * - Suppresses loading UI for fast responses (`< delayMs`, default 300ms).
 * - Once visible, keeps the loading UI mounted for at least `minVisibleMs` (default 500ms)
 *   to avoid abrupt 1-frame flashes when responses arrive just past the delay threshold.
 */
export function useDelayedFlag(
  active: boolean,
  delayMs = 300,
  minVisibleMs = 500,
): boolean {
  const [visible, setVisible] = useState(false);
  const shownAtRef = useRef<number | null>(null);
  const showTimerRef = useRef<number | null>(null);
  const hideTimerRef = useRef<number | null>(null);

  useEffect(() => {
    if (showTimerRef.current !== null) {
      window.clearTimeout(showTimerRef.current);
      showTimerRef.current = null;
    }
    if (hideTimerRef.current !== null) {
      window.clearTimeout(hideTimerRef.current);
      hideTimerRef.current = null;
    }

    if (active) {
      if (visible) return;
      if (delayMs <= 0) {
        shownAtRef.current = Date.now();
        setVisible(true);
        return;
      }
      showTimerRef.current = window.setTimeout(() => {
        showTimerRef.current = null;
        shownAtRef.current = Date.now();
        setVisible(true);
      }, delayMs);
    } else if (visible) {
      const elapsed = shownAtRef.current !== null ? Date.now() - shownAtRef.current : minVisibleMs;
      const remaining = Math.max(0, minVisibleMs - elapsed);
      if (remaining === 0) {
        shownAtRef.current = null;
        setVisible(false);
      } else {
        hideTimerRef.current = window.setTimeout(() => {
          hideTimerRef.current = null;
          shownAtRef.current = null;
          setVisible(false);
        }, remaining);
      }
    }

    return () => {
      if (showTimerRef.current !== null) {
        window.clearTimeout(showTimerRef.current);
        showTimerRef.current = null;
      }
      if (hideTimerRef.current !== null) {
        window.clearTimeout(hideTimerRef.current);
        hideTimerRef.current = null;
      }
    };
  }, [active, delayMs, minVisibleMs, visible]);

  return visible;
}
