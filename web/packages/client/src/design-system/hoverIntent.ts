import { useCallback, useEffect, useRef, useState } from 'react';
import type React from 'react';

export interface PointerPoint {
  x: number;
  y: number;
}

export function pointInTriangle(
  p: PointerPoint,
  a: PointerPoint,
  b: PointerPoint,
  c: PointerPoint,
): boolean {
  const sign = (p1: PointerPoint, p2: PointerPoint, p3: PointerPoint) =>
    (p1.x - p3.x) * (p2.y - p3.y) - (p2.x - p3.x) * (p1.y - p3.y);
  const d1 = sign(p, a, b);
  const d2 = sign(p, b, c);
  const d3 = sign(p, c, a);
  const hasNeg = d1 < 0 || d2 < 0 || d3 < 0;
  const hasPos = d1 > 0 || d2 > 0 || d3 > 0;
  return !(hasNeg && hasPos);
}

/**
 * Shared safe-triangle hover-intent controller for cascading context menus & submenus.
 * Keeps an open submenu alive while the pointer travels diagonally across sibling rows
 * toward the submenu bounds, and cleanly switches or closes when the pointer moves elsewhere.
 */
export function useSafeTriangleSubmenu<T extends string>(
  submenuSide: 'right' | 'left' = 'right',
  delayMs = 145,
) {
  const [openKey, setOpenKey] = useState<T | null>(null);
  const submenuElRef = useRef<HTMLDivElement | null>(null);
  const pointerHistoryRef = useRef<PointerPoint[]>([]);
  const switchTimerRef = useRef<number | null>(null);

  const clearTimer = useCallback(() => {
    if (switchTimerRef.current !== null) {
      window.clearTimeout(switchTimerRef.current);
      switchTimerRef.current = null;
    }
  }, []);

  useEffect(() => clearTimer, [clearTimer]);

  const recordPointer = useCallback((e: React.MouseEvent) => {
    const hist = pointerHistoryRef.current;
    hist.push({ x: e.clientX, y: e.clientY });
    if (hist.length > 4) hist.shift();
  }, []);

  const isMovingTowardSubmenu = useCallback(
    (currentPoint: PointerPoint): boolean => {
      const sub = submenuElRef.current;
      const hist = pointerHistoryRef.current;
      if (!sub || hist.length < 2) return false;
      const prev = hist[0];
      const rect = sub.getBoundingClientRect();
      if (rect.width <= 0 || rect.height <= 0) return false;
      const edgeX = submenuSide === 'left' ? rect.right : rect.left;
      const pad = 18;
      const topCorner: PointerPoint = { x: edgeX, y: rect.top - pad };
      const bottomCorner: PointerPoint = { x: edgeX, y: rect.bottom + pad };
      return pointInTriangle(currentPoint, prev, topCorner, bottomCorner);
    },
    [submenuSide],
  );

  const requestOpen = useCallback(
    (nextKey: T | null, e: React.MouseEvent) => {
      recordPointer(e);
      clearTimer();

      if (openKey === nextKey) return;

      if (openKey !== null && isMovingTowardSubmenu({ x: e.clientX, y: e.clientY })) {
        switchTimerRef.current = window.setTimeout(() => {
          switchTimerRef.current = null;
          setOpenKey(nextKey);
        }, delayMs);
        return;
      }

      setOpenKey(nextKey);
    },
    [clearTimer, delayMs, isMovingTowardSubmenu, openKey, recordPointer],
  );

  const cancelPendingClose = useCallback(() => {
    clearTimer();
  }, [clearTimer]);

  const closeImmediately = useCallback(() => {
    clearTimer();
    setOpenKey(null);
  }, [clearTimer]);

  return {
    openKey,
    setOpenKey,
    submenuElRef,
    recordPointer,
    requestOpen,
    cancelPendingClose,
    closeImmediately,
  };
}
