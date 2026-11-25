import React from 'react';
import { getTransport, type WindowResizeDirection } from '../../api/transport';
import { useCoordinatorStore } from '../../stores';

interface EdgeSpec {
  direction: WindowResizeDirection;
  className: string;
}

const RESIZE_EDGES: readonly EdgeSpec[] = [
  // 4 perimeter edges (5px L/R/B, 4px T)
  {
    direction: 'West',
    className: 'fixed left-0 top-[6px] bottom-[8px] w-[5px] z-[9990] cursor-ew-resize',
  },
  {
    direction: 'East',
    className: 'fixed right-0 top-[6px] bottom-[8px] w-[5px] z-[9990] cursor-ew-resize',
  },
  {
    direction: 'North',
    className: 'fixed top-0 left-[6px] right-[6px] h-[4px] z-[9990] cursor-ns-resize',
  },
  {
    direction: 'South',
    className: 'fixed bottom-0 left-[8px] right-[8px] h-[5px] z-[9990] cursor-ns-resize',
  },
  // 4 corners (top-right kept compact 5x5px so the 46x40px Close button stays unobstructed)
  {
    direction: 'NorthWest',
    className: 'fixed top-0 left-0 w-[6px] h-[6px] z-[9991] cursor-nwse-resize',
  },
  {
    direction: 'NorthEast',
    className: 'fixed top-0 right-0 w-[5px] h-[5px] z-[9991] cursor-nesw-resize',
  },
  {
    direction: 'SouthWest',
    className: 'fixed bottom-0 left-0 w-[8px] h-[8px] z-[9991] cursor-nesw-resize',
  },
  {
    direction: 'SouthEast',
    className: 'fixed bottom-0 right-0 w-[8px] h-[8px] z-[9991] cursor-nwse-resize',
  },
];

/**
 * Transparent 8-direction native resize perimeter for restored (non-maximized) borderless
 * Mica Alt windows. Because `WM_NCCALCSIZE` returns `0` (`client_rect == window_rect`, zero
 * unfocused gray frame bleed), WebView2 covers 100% of the client area and shadows parent
 * Win32 `WM_NCHITTEST` on left/right edges; forwarding `pointerdown` to Tauri's native
 * `start_resize_dragging` restores full OS-native horizontal, vertical, and corner resizing.
 */
export const WindowResizeEdges: React.FC = () => {
  const windowMaximized = useCoordinatorStore((s) => s.windowMaximized);

  if (windowMaximized) {
    return null;
  }

  return (
    <>
      {RESIZE_EDGES.map(({ direction, className }) => (
        <div
          key={direction}
          aria-hidden="true"
          data-testid={`window-resize-${direction}`}
          data-tauri-drag-region="false"
          onPointerDown={(e) => {
            if (e.button !== 0) return;
            e.preventDefault();
            e.stopPropagation();
            void getTransport()
              .windowStartResize(direction)
              .catch(() => {});
          }}
          className={`${className} bg-transparent select-none touch-none`}
        />
      ))}
    </>
  );
};
