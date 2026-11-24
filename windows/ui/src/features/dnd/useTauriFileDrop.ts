import { useEffect, useRef } from 'react';
import { getCurrentWebview } from '@tauri-apps/api/webview';
import { isTauriRuntime } from '../../api/transport';
import { useDndStore, type DragDropTarget } from './dndStore';

export function hitTestOsDropTarget(clientX: number, clientY: number): DragDropTarget {
  if (typeof document === 'undefined' || !document.elementsFromPoint) return { kind: 'gallery' };
  const els = document.elementsFromPoint(clientX, clientY);
  for (const el of els) {
    const htmlEl = el as HTMLElement;
    const folderId = htmlEl.dataset?.dropFolderId;
    if (folderId) {
      return {
        kind: 'folder',
        id: folderId,
        zone: 'inside',
        label: htmlEl.dataset?.dropLabel,
      };
    }
    if (htmlEl.dataset?.dropInbox === 'true') {
      return { kind: 'inbox' };
    }
    if (htmlEl.dataset?.dropFolderRoot === 'true') {
      return { kind: 'folderRoot' };
    }
    const boardId = htmlEl.dataset?.dropBoardId;
    if (boardId) {
      return {
        kind: 'board',
        id: boardId,
        label: htmlEl.dataset?.dropLabel,
      };
    }
    if (htmlEl.dataset?.testid === 'moodboard-canvas-stage') {
      return { kind: 'moodboardCanvas', clientX, clientY };
    }
    if (htmlEl.dataset?.testid === 'top-edge-drop-shelf') {
      return { kind: 'shelf' };
    }
  }
  return { kind: 'gallery' };
}

export interface UseTauriFileDropOptions {
  onDropFiles: (
    paths: string[],
    target: DragDropTarget,
    position: { clientX: number; clientY: number },
  ) => void | Promise<void>;
}

/**
 * Window-level Tauri v2 native OS drag-and-drop bridge (`onDragDropEvent`).
 * Required on Windows WebView2 because Tauri intercepts Win32 OLE `IDropTarget`
 * and routes Explorer file/folder drags through `tauri://drag-*` events rather than HTML5 `onDrop`.
 */
export function useTauriFileDrop({ onDropFiles }: UseTauriFileDropOptions): void {
  const onDropRef = useRef(onDropFiles);
  onDropRef.current = onDropFiles;

  useEffect(() => {
    if (!isTauriRuntime()) return;
    let unlisten: (() => void) | null = null;
    let disposed = false;

    const toCssCoords = (pos?: { x: number; y: number }) => {
      const dpr = window.devicePixelRatio || 1;
      return {
        clientX: pos ? pos.x / dpr : 0,
        clientY: pos ? pos.y / dpr : 0,
      };
    };

    void getCurrentWebview()
      .onDragDropEvent((event) => {
        if (disposed) return;
        const payload = event.payload;
        const store = useDndStore.getState();

        if (payload.type === 'enter') {
          const { clientX, clientY } = toCssCoords(payload.position);
          const target = hitTestOsDropTarget(clientX, clientY);
          store.setOsFileDrop({
            active: true,
            paths: payload.paths ?? [],
            clientX,
            clientY,
            target,
          });
        } else if (payload.type === 'over') {
          const { clientX, clientY } = toCssCoords(payload.position);
          const target = hitTestOsDropTarget(clientX, clientY);
          store.setOsFileDrop({
            active: true,
            paths: store.osFileDrop.paths,
            clientX,
            clientY,
            target,
          });
        } else if (payload.type === 'leave') {
          store.clearOsFileDrop();
        } else if (payload.type === 'drop') {
          const { clientX, clientY } = toCssCoords(payload.position);
          const target = hitTestOsDropTarget(clientX, clientY);
          const paths = payload.paths ?? [];
          store.clearOsFileDrop();
          if (paths.length > 0) {
            void onDropRef.current(paths, target, { clientX, clientY });
          }
        }
      })
      .then((fn) => {
        if (disposed) fn();
        else unlisten = fn;
      })
      .catch(() => {});

    const onVisibilityChange = () => {
      if (document.hidden) {
        useDndStore.getState().clearOsFileDrop();
      }
    };
    const onKeyDown = (e: KeyboardEvent) => {
      if (e.key === 'Escape' && useDndStore.getState().osFileDrop.active) {
        useDndStore.getState().clearOsFileDrop();
      }
    };
    document.addEventListener('visibilitychange', onVisibilityChange);
    window.addEventListener('keydown', onKeyDown);

    return () => {
      disposed = true;
      unlisten?.();
      document.removeEventListener('visibilitychange', onVisibilityChange);
      window.removeEventListener('keydown', onKeyDown);
      useDndStore.getState().clearOsFileDrop();
    };
  }, []);
}
