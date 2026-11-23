import { useEffect, useRef, useState } from 'react';

/**
 * Anti-flicker loading threshold hook (DESIGN.md §7.6 & P0-4):
 * - Delays showing skeletons/spinners for `delayMs` (default 300ms) so fast local reads never flash.
 * - Once visible, keeps the indicator on screen for at least `minVisibleMs` (default 500ms).
 */
export function useDelayedFlag(
  active: boolean,
  delayMs = 300,
  minVisibleMs = 500,
): boolean {
  const [visible, setVisible] = useState(false);
  const shownAtRef = useRef<number | null>(null);

  useEffect(() => {
    if (active) {
      if (visible) return;
      const timer = window.setTimeout(() => {
        shownAtRef.current = Date.now();
        setVisible(true);
      }, delayMs);
      return () => window.clearTimeout(timer);
    }

    if (!visible) return;
    const elapsed = shownAtRef.current ? Date.now() - shownAtRef.current : minVisibleMs;
    const remaining = Math.max(0, minVisibleMs - elapsed);
    if (remaining === 0) {
      shownAtRef.current = null;
      setVisible(false);
      return;
    }
    const timer = window.setTimeout(() => {
      shownAtRef.current = null;
      setVisible(false);
    }, remaining);
    return () => window.clearTimeout(timer);
  }, [active, visible, delayMs, minVisibleMs]);

  return visible;
}
