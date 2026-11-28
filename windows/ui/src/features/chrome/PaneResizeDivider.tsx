import React, { useCallback, useEffect, useRef, useState } from 'react';
import {
  COLLAPSED_SIDEBAR_DRAG_EXPAND_THRESHOLD,
  COLLAPSED_SIDEBAR_WIDTH,
  MIN_SIDEBAR_WIDTH,
} from '../../stores/sidebarResize';

export interface PaneResizeDividerProps {
  mode: 'sidebar' | 'inspector';
  currentWidth: number;
  minWidth: number;
  maxWidth: number;
  defaultWidth: number;
  isCollapsed?: boolean;
  label: string;
  testId: string;
  onResizeStart: () => void;
  onResize: (nextWidth: number) => void;
  onExpandFromCollapsed?: (initialWidth: number) => void;
  onResizeEnd: (finalWidth: number) => void;
  onReset: () => void;
}

/**
 * Invisible 9px draggable hit-target centered over a 1px hairline seam (positioned outside
 * pane clip containers so zero layout shift occurs). Supports PointerCapture drag, double-click
 * reset to default width, keyboard arrow resizing, and drag-right-to-expand from the collapsed
 * 76px Sidebar rail.
 */
export const PaneResizeDivider: React.FC<PaneResizeDividerProps> = ({
  mode,
  currentWidth,
  minWidth,
  maxWidth,
  defaultWidth,
  isCollapsed = false,
  label,
  testId,
  onResizeStart,
  onResize,
  onExpandFromCollapsed,
  onResizeEnd,
  onReset,
}) => {
  const [hovered, setHovered] = useState(false);
  const [dragging, setDragging] = useState(false);
  const dragSessionRef = useRef<{
    pointerId: number;
    startX: number;
    startWidth: number;
    startedCollapsed: boolean;
    expandedDuringDrag: boolean;
    latestWidth: number;
  } | null>(null);

  const onResizeEndRef = useRef(onResizeEnd);
  onResizeEndRef.current = onResizeEnd;

  const restoreBodyCursor = useCallback(() => {
    if (typeof document !== 'undefined') {
      document.body.style.cursor = '';
      document.body.style.userSelect = '';
    }
  }, []);

  useEffect(() => {
    return () => {
      if (dragSessionRef.current) {
        const latestWidth = dragSessionRef.current.latestWidth;
        dragSessionRef.current = null;
        restoreBodyCursor();
        onResizeEndRef.current(latestWidth);
      }
    };
  }, [restoreBodyCursor]);

  const finishDrag = useCallback(
    (el: HTMLElement | null) => {
      const session = dragSessionRef.current;
      if (!session) return;
      dragSessionRef.current = null;
      setDragging(false);
      restoreBodyCursor();
      if (el) {
        try {
          if (el.hasPointerCapture?.(session.pointerId)) {
            el.releasePointerCapture?.(session.pointerId);
          }
        } catch {
          // Ignore synthetic jsdom pointerId capture release errors
        }
      }
      onResizeEnd(session.latestWidth);
    },
    [onResizeEnd, restoreBodyCursor],
  );

  const handlePointerDown = (e: React.PointerEvent<HTMLDivElement>) => {
    if (e.button !== 0) return;
    e.preventDefault();
    e.stopPropagation();

    const el = e.currentTarget;
    try {
      el.setPointerCapture?.(e.pointerId);
    } catch {
      // Ignore jsdom unsupported pointer capture
    }

    const activeCursor = isCollapsed && mode === 'sidebar' ? 'e-resize' : 'col-resize';
    if (typeof document !== 'undefined') {
      document.body.style.cursor = activeCursor;
      document.body.style.userSelect = 'none';
    }

    dragSessionRef.current = {
      pointerId: e.pointerId,
      startX: e.clientX,
      startWidth: isCollapsed && mode === 'sidebar' ? COLLAPSED_SIDEBAR_WIDTH : currentWidth,
      startedCollapsed: isCollapsed && mode === 'sidebar',
      expandedDuringDrag: false,
      latestWidth: currentWidth,
    };
    setDragging(true);
    onResizeStart();
  };

  const handlePointerMove = (e: React.PointerEvent<HTMLDivElement>) => {
    const session = dragSessionRef.current;
    if (!session) return;
    e.preventDefault();
    const deltaX = e.clientX - session.startX;

    if (mode === 'sidebar') {
      if (session.startedCollapsed && !session.expandedDuringDrag) {
        if (deltaX >= COLLAPSED_SIDEBAR_DRAG_EXPAND_THRESHOLD) {
          const next = Math.max(MIN_SIDEBAR_WIDTH, Math.round(COLLAPSED_SIDEBAR_WIDTH + deltaX));
          session.expandedDuringDrag = true;
          session.latestWidth = next;
          if (typeof document !== 'undefined') {
            document.body.style.cursor = 'col-resize';
          }
          onExpandFromCollapsed?.(next);
        }
        return;
      }
      const next = Math.round(session.startWidth + deltaX);
      session.latestWidth = next;
      onResize(next);
      return;
    }

    // Inspector grows as the divider is dragged leftward
    const next = Math.round(session.startWidth - deltaX);
    session.latestWidth = next;
    onResize(next);
  };

  const handlePointerUp = (e: React.PointerEvent<HTMLDivElement>) => {
    if (!dragSessionRef.current) return;
    e.preventDefault();
    e.stopPropagation();
    finishDrag(e.currentTarget);
  };

  const handleDoubleClick = (e: React.MouseEvent<HTMLDivElement>) => {
    e.preventDefault();
    e.stopPropagation();
    onReset();
  };

  const handleKeyDown = (e: React.KeyboardEvent<HTMLDivElement>) => {
    if (e.key === 'Enter' || e.key === 'Home') {
      e.preventDefault();
      onReset();
      return;
    }
    if (e.key !== 'ArrowLeft' && e.key !== 'ArrowRight') return;
    e.preventDefault();
    const step = e.shiftKey ? 24 : 12;
    const sign = e.key === 'ArrowRight' ? 1 : -1;
    if (mode === 'sidebar') {
      if (isCollapsed && sign > 0) {
        onExpandFromCollapsed?.(defaultWidth);
        onResizeEnd(defaultWidth);
        return;
      }
      const next = currentWidth + sign * step;
      onResize(next);
      onResizeEnd(next);
    } else {
      const next = currentWidth - sign * step;
      onResize(next);
      onResizeEnd(next);
    }
  };

  const cursorClass = isCollapsed && mode === 'sidebar' ? 'cursor-e-resize' : 'cursor-col-resize';

  return (
    <div className="relative w-0 shrink-0 h-full z-[45] select-none">
      <div
        role="separator"
        tabIndex={0}
        aria-orientation="vertical"
        aria-label={label}
        aria-valuemin={minWidth}
        aria-valuemax={maxWidth}
        aria-valuenow={Math.round(currentWidth)}
        data-testid={testId}
        data-dragging={dragging ? 'true' : 'false'}
        title={`${label}（双击重置为 ${defaultWidth}px）`}
        onPointerEnter={() => setHovered(true)}
        onPointerLeave={() => setHovered(false)}
        onPointerDown={handlePointerDown}
        onPointerMove={handlePointerMove}
        onPointerUp={handlePointerUp}
        onPointerCancel={handlePointerUp}
        onLostPointerCapture={handlePointerUp}
        onDoubleClick={handleDoubleClick}
        onKeyDown={handleKeyDown}
        className={[
          'absolute inset-y-0 -left-[4px] w-[9px] flex items-stretch justify-center outline-none touch-none',
          'focus-visible:after:content-[""] focus-visible:ring-1 focus-visible:ring-[var(--accent)]',
          cursorClass,
        ].join(' ')}
      >
        <span
          aria-hidden="true"
          className={[
            'h-full transition-colors duration-[100ms]',
            dragging
              ? 'w-[2px] bg-[var(--accent)]'
              : hovered
                ? 'w-[1.5px] bg-[var(--accent)]/55'
                : 'w-px bg-transparent',
          ].join(' ')}
        />
      </div>
    </div>
  );
};
