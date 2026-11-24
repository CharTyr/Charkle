import { create } from 'zustand';

export type DragDropTarget =
  | { kind: 'folder'; id: string; zone: 'before' | 'inside' | 'after'; label?: string }
  | { kind: 'folderRoot' }
  | { kind: 'inbox' }
  | { kind: 'trash' }
  | { kind: 'board'; id: string; label?: string }
  | { kind: 'moodboardCanvas'; clientX: number; clientY: number }
  | { kind: 'inspectorCard'; cardId: string }
  | { kind: 'editorialNode'; nodeId: string; orderIndex: number }
  | { kind: 'gallery' }
  | { kind: 'shelf' }
  | null;

export type ActivePointerDrag =
  | {
      kind: 'assets';
      assetIds: string[];
      previewAssetId: string;
      title: string;
    }
  | {
      kind: 'folder';
      folderId: string;
      name: string;
    }
  | {
      kind: 'inspectorCard';
      cardId: string;
      title: string;
    }
  | {
      kind: 'candidate';
      assetId: string;
      title: string;
    }
  | {
      kind: 'editorialNode';
      nodeId: string;
      title: string;
    };

export interface OsFileDropState {
  active: boolean;
  paths: string[];
  clientX: number;
  clientY: number;
  target: DragDropTarget;
}

interface DndStoreState {
  pointerDrag: ActivePointerDrag | null;
  pointerPos: { x: number; y: number };
  pointerTarget: DragDropTarget;
  osFileDrop: OsFileDropState;

  setPointerDrag: (
    drag: ActivePointerDrag | null,
    pos?: { x: number; y: number },
    target?: DragDropTarget,
  ) => void;
  updatePointerDrag: (pos: { x: number; y: number }, target: DragDropTarget) => void;
  setOsFileDrop: (next: OsFileDropState) => void;
  clearOsFileDrop: () => void;
}

const EMPTY_OS_DROP: OsFileDropState = {
  active: false,
  paths: [],
  clientX: 0,
  clientY: 0,
  target: null,
};

export const useDndStore = create<DndStoreState>((set) => ({
  pointerDrag: null,
  pointerPos: { x: 0, y: 0 },
  pointerTarget: null,
  osFileDrop: EMPTY_OS_DROP,

  setPointerDrag(drag, pos, target = null) {
    set({
      pointerDrag: drag,
      pointerPos: pos ?? { x: 0, y: 0 },
      pointerTarget: drag ? target : null,
    });
  },

  updatePointerDrag(pos, target) {
    set({ pointerPos: pos, pointerTarget: target });
  },

  setOsFileDrop(next) {
    set({ osFileDrop: next });
  },

  clearOsFileDrop() {
    set({ osFileDrop: EMPTY_OS_DROP });
  },
}));
