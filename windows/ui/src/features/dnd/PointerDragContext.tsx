import React, { useEffect } from 'react';
import { createPortal } from 'react-dom';
import { Folder, GripVertical, Image as ImageIcon } from 'lucide-react';
import { getTransport, isTauriRuntime } from '../../api/transport';
import { useDndStore, type ActivePointerDrag, type DragDropTarget } from './dndStore';

const DRAG_THRESHOLD_PX = 6;

let lastDragEndedAt = 0;
let activeDragCleanup: (() => void) | null = null;

/** Returns true immediately after a pointer drag ends so click handlers ignore the trailing mouseup. */
export function wasRecentPointerDrag(): boolean {
  return Date.now() - lastDragEndedAt < 220;
}

export interface PointerDragCommitHandlers {
  onDropAssetsToFolder?: (folderId: string, assetIds: string[]) => void;
  onDropAssetsToInbox?: (assetIds: string[]) => void;
  onDropAssetsToTrash?: (assetIds: string[]) => void;
  onDropAssetsToBoard?: (boardId: string, assetIds: string[]) => void;
  onMoveFolder?: (
    folderId: string,
    targetFolderId: string | null,
    zone: 'before' | 'inside' | 'after' | 'root',
  ) => void;
  onReorderInspectorCard?: (sourceCardId: string, targetCardId: string) => void;
  onDropCandidateToCanvas?: (assetId: string, clientX: number, clientY: number) => void;
  onReorderEditorialNode?: (sourceNodeId: string, targetNodeId: string) => void;
}

const registeredHandlers: PointerDragCommitHandlers = {};

export function registerPointerDragHandlers(handlers: Partial<PointerDragCommitHandlers>): () => void {
  const keys = Object.keys(handlers) as Array<keyof PointerDragCommitHandlers>;
  for (const k of keys) {
    (registeredHandlers as Record<string, unknown>)[k] = handlers[k];
  }
  return () => {
    for (const k of keys) {
      if (registeredHandlers[k] === handlers[k]) {
        delete registeredHandlers[k];
      }
    }
  };
}

function hitTestPointerTarget(
  drag: ActivePointerDrag,
  clientX: number,
  clientY: number,
): DragDropTarget {
  if (typeof document === 'undefined' || !document.elementsFromPoint) return null;
  const els = document.elementsFromPoint(clientX, clientY);

  for (const rawEl of els) {
    const el = rawEl as HTMLElement;

    if (drag.kind === 'assets') {
      const folderId = el.dataset?.dropFolderId;
      if (folderId) {
        return { kind: 'folder', id: folderId, zone: 'inside', label: el.dataset?.dropLabel };
      }
      if (el.dataset?.dropInbox === 'true') return { kind: 'inbox' };
      if (el.dataset?.dropTrash === 'true') return { kind: 'trash' };
      const boardId = el.dataset?.dropBoardId;
      if (boardId) {
        return { kind: 'board', id: boardId, label: el.dataset?.dropLabel };
      }
    }

    if (drag.kind === 'folder') {
      const folderId = el.dataset?.dropFolderId;
      if (folderId && folderId !== drag.folderId) {
        const rect = el.getBoundingClientRect();
        const relY = (clientY - rect.top) / Math.max(1, rect.height);
        const zone: 'before' | 'inside' | 'after' =
          relY < 0.25 ? 'before' : relY > 0.75 ? 'after' : 'inside';
        return { kind: 'folder', id: folderId, zone, label: el.dataset?.dropLabel };
      }
      if (el.dataset?.dropFolderRoot === 'true') {
        return { kind: 'folderRoot' };
      }
    }

    if (drag.kind === 'inspectorCard') {
      const cardId = el.dataset?.inspectorCard;
      if (cardId && cardId !== drag.cardId) {
        return { kind: 'inspectorCard', cardId };
      }
    }

    if (drag.kind === 'candidate') {
      if (el.dataset?.testid === 'moodboard-canvas-stage') {
        return { kind: 'moodboardCanvas', clientX, clientY };
      }
    }

    if (drag.kind === 'editorialNode') {
      const nodeId = el.dataset?.boardNodeId;
      if (nodeId && nodeId !== drag.nodeId) {
        const orderIndex = Number(el.dataset?.editorialOrderIndex ?? '0');
        return { kind: 'editorialNode', nodeId, orderIndex };
      }
    }
  }

  return null;
}

function isNearWindowBoundary(clientX: number, clientY: number): boolean {
  const margin = 4;
  return (
    clientX <= margin ||
    clientY <= margin ||
    clientX >= window.innerWidth - margin ||
    clientY >= window.innerHeight - margin
  );
}

/**
 * Initiates a Pointer-Event managed drag gesture with a 6px movement hysteresis threshold.
 * Works 100% reliably inside Tauri v2 WebView2 (unlike HTML5 `draggable`), tracks 1:1 with
 * a Liquid Glass floating ghost, and seamlessly hands off to native Win32 OLE `DoDragDrop`
 * if an asset drag crosses outside the Charkle window bounds.
 */
export function beginPointerDrag(
  e: React.PointerEvent,
  payload: ActivePointerDrag,
  opts?: { allowOutboundOle?: boolean; forceOutboundOleOnDrag?: boolean },
): void {
  if (e.button !== 0) return;

  activeDragCleanup?.();

  const startX = e.clientX;
  const startY = e.clientY;
  let active = false;
  let oleLaunched = false;

  const cleanup = () => {
    window.removeEventListener('pointermove', onMove, true);
    window.removeEventListener('pointerup', onUp, true);
    window.removeEventListener('pointercancel', onCancel, true);
    window.removeEventListener('keydown', onKeyDown, true);
    window.removeEventListener('blur', onCancel);
    window.removeEventListener('contextmenu', onCancel, true);
    if (activeDragCleanup === cleanup) {
      activeDragCleanup = null;
    }
    useDndStore.getState().setPointerDrag(null);
  };
  activeDragCleanup = cleanup;

  const launchOleDragOut = () => {
    if (oleLaunched || payload.kind !== 'assets') return;
    oleLaunched = true;
    lastDragEndedAt = Date.now();
    cleanup();
    void getTransport()
      .startOutboundDrag(payload.assetIds)
      .catch(() => {});
  };

  const onMove = (ev: PointerEvent) => {
    const dx = ev.clientX - startX;
    const dy = ev.clientY - startY;

    if (!active) {
      if (Math.hypot(dx, dy) < DRAG_THRESHOLD_PX) return;
      active = true;
      if (opts?.forceOutboundOleOnDrag && payload.kind === 'assets') {
        launchOleDragOut();
        return;
      }
      const target = hitTestPointerTarget(payload, ev.clientX, ev.clientY);
      useDndStore.getState().setPointerDrag(payload, { x: ev.clientX, y: ev.clientY }, target);
      return;
    }

    // If dragging assets out past the window edge while LBUTTON is still held,
    // seamlessly hand off to native Win32 OLE DoDragDrop!
    if (
      opts?.allowOutboundOle !== false &&
      payload.kind === 'assets' &&
      isTauriRuntime() &&
      (ev.buttons & 1) !== 0 &&
      isNearWindowBoundary(ev.clientX, ev.clientY)
    ) {
      launchOleDragOut();
      return;
    }

    const target = hitTestPointerTarget(payload, ev.clientX, ev.clientY);
    useDndStore.getState().updatePointerDrag({ x: ev.clientX, y: ev.clientY }, target);
  };

  const onUp = (ev: PointerEvent) => {
    const wasActive = active;
    const finalTarget = wasActive ? hitTestPointerTarget(payload, ev.clientX, ev.clientY) : null;
    cleanup();
    if (!wasActive) return;

    lastDragEndedAt = Date.now();

    if (!finalTarget) return;

    if (payload.kind === 'assets') {
      if (finalTarget.kind === 'folder') {
        registeredHandlers.onDropAssetsToFolder?.(finalTarget.id, payload.assetIds);
      } else if (finalTarget.kind === 'inbox') {
        registeredHandlers.onDropAssetsToInbox?.(payload.assetIds);
      } else if (finalTarget.kind === 'trash') {
        registeredHandlers.onDropAssetsToTrash?.(payload.assetIds);
      } else if (finalTarget.kind === 'board') {
        registeredHandlers.onDropAssetsToBoard?.(finalTarget.id, payload.assetIds);
      }
    } else if (payload.kind === 'folder') {
      if (finalTarget.kind === 'folder') {
        registeredHandlers.onMoveFolder?.(payload.folderId, finalTarget.id, finalTarget.zone);
      } else if (finalTarget.kind === 'folderRoot') {
        registeredHandlers.onMoveFolder?.(payload.folderId, null, 'root');
      }
    } else if (payload.kind === 'inspectorCard' && finalTarget.kind === 'inspectorCard') {
      registeredHandlers.onReorderInspectorCard?.(payload.cardId, finalTarget.cardId);
    } else if (payload.kind === 'candidate' && finalTarget.kind === 'moodboardCanvas') {
      registeredHandlers.onDropCandidateToCanvas?.(
        payload.assetId,
        finalTarget.clientX,
        finalTarget.clientY,
      );
    } else if (payload.kind === 'editorialNode' && finalTarget.kind === 'editorialNode') {
      registeredHandlers.onReorderEditorialNode?.(payload.nodeId, finalTarget.nodeId);
    }
  };

  const onCancel = () => {
    if (active) lastDragEndedAt = Date.now();
    cleanup();
  };

  const onKeyDown = (ev: KeyboardEvent) => {
    if (ev.key === 'Escape') {
      ev.preventDefault();
      if (active) lastDragEndedAt = Date.now();
      cleanup();
    }
  };

  window.addEventListener('pointermove', onMove, true);
  window.addEventListener('pointerup', onUp, true);
  window.addEventListener('pointercancel', onCancel, true);
  window.addEventListener('keydown', onKeyDown, true);
  window.addEventListener('blur', onCancel);
  window.addEventListener('contextmenu', onCancel, true);
}

/**
 * Floating GPU-composited Liquid Glass drag preview overlay rendered at the root of the window.
 */
export const PointerDragGhostLayer: React.FC = () => {
  const drag = useDndStore((s) => s.pointerDrag);
  const pos = useDndStore((s) => s.pointerPos);
  const target = useDndStore((s) => s.pointerTarget);

  useEffect(() => {
    if (!drag) return;
    const prevUserSelect = document.body.style.userSelect;
    const prevCursor = document.body.style.cursor;
    document.body.style.userSelect = 'none';
    document.body.style.cursor = 'grabbing';
    return () => {
      document.body.style.userSelect = prevUserSelect;
      document.body.style.cursor = prevCursor;
    };
  }, [drag]);

  if (!drag || typeof document === 'undefined') return null;

  const transport = getTransport();
  const targetHint =
    target?.kind === 'folder'
      ? target.zone === 'inside'
        ? `放入「${target.label ?? '文件夹'}」`
        : target.zone === 'before'
          ? `移至「${target.label ?? '文件夹'}」上方`
          : `移至「${target.label ?? '文件夹'}」下方`
      : target?.kind === 'folderRoot'
        ? '移至顶层文件夹'
        : target?.kind === 'inbox'
          ? '移至收件箱'
          : target?.kind === 'trash'
            ? '移入回收站'
            : target?.kind === 'board'
              ? `加入情绪板「${target.label ?? '情绪板'}」`
              : target?.kind === 'moodboardCanvas'
                ? '放入画布'
                : null;

  return createPortal(
    <div
      aria-hidden="true"
      style={{
        transform: `translate3d(${Math.round(pos.x + 14)}px, ${Math.round(pos.y + 14)}px, 0)`,
      }}
      className="pointer-events-none fixed top-0 left-0 z-[260] flex flex-col items-start gap-1.5"
    >
      {drag.kind === 'assets' && (
        <div
          data-no-lens="true"
          className="charkle-glass rounded-[12px] p-1.5 flex items-center gap-2 max-w-[240px]"
        >
          <div className="relative h-10 w-10 rounded-[8px] overflow-hidden bg-[var(--bg-subtle)] shrink-0">
            <img
              src={transport.thumbnailUrl(drag.previewAssetId, 'grid520')}
              alt=""
              className="w-full h-full object-cover"
            />
            {drag.assetIds.length > 1 && (
              <span className="absolute -top-0.5 -right-0.5 min-w-[18px] h-[18px] px-1 rounded-full bg-[var(--accent)] text-white text-[10px] font-bold inline-flex items-center justify-center charkle-tabular">
                {drag.assetIds.length}
              </span>
            )}
          </div>
          <div className="min-w-0 pr-1.5">
            <div className="text-[12px] font-semibold text-[var(--text-primary)] truncate">
              {drag.assetIds.length > 1 ? `${drag.assetIds.length} 项素材` : drag.title}
            </div>
            <div className="text-[10.5px] text-[var(--text-secondary)] truncate">
              {targetHint ?? '拖至文件夹、情绪板或窗口外'}
            </div>
          </div>
        </div>
      )}

      {drag.kind === 'folder' && (
        <div
          data-no-lens="true"
          className="charkle-glass rounded-[10px] px-2.5 py-1.5 flex items-center gap-2 text-[12px] font-medium text-[var(--text-primary)]"
        >
          <Folder size={14} className="text-[var(--accent)] shrink-0" />
          <span className="truncate max-w-[160px]">{drag.name}</span>
          {targetHint && (
            <span className="text-[10.5px] text-[var(--accent)] shrink-0">· {targetHint}</span>
          )}
        </div>
      )}

      {drag.kind === 'inspectorCard' && (
        <div
          data-no-lens="true"
          className="charkle-glass rounded-[10px] px-2.5 py-1.5 flex items-center gap-1.5 text-[12px] font-medium text-[var(--text-primary)]"
        >
          <GripVertical size={13} className="text-[var(--text-tertiary)]" />
          <span>{drag.title}</span>
        </div>
      )}

      {(drag.kind === 'candidate' || drag.kind === 'editorialNode') && (
        <div
          data-no-lens="true"
          className="charkle-glass rounded-[10px] px-2.5 py-1.5 flex items-center gap-2 text-[12px] font-medium text-[var(--text-primary)]"
        >
          <ImageIcon size={14} className="text-[var(--accent)]" />
          <span className="truncate max-w-[180px]">{drag.title}</span>
          {targetHint && <span className="text-[10.5px] text-[var(--accent)]">· {targetHint}</span>}
        </div>
      )}
    </div>,
    document.body,
  );
};
