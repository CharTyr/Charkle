import { create } from 'zustand';
import { getTransport } from '../api/transport';
import {
  msToCocoaSeconds,
  type MoodboardDocument,
  type MoodboardSummary,
} from '../types/domain';
import { useCoordinatorStore } from './coordinatorStore';

function makeBoardId(): string {
  if (typeof crypto !== 'undefined' && typeof crypto.randomUUID === 'function') {
    return crypto.randomUUID().toUpperCase();
  }
  return 'XXXXXXXX-XXXX-4XXX-8XXX-XXXXXXXXXXXX'.replace(/X/g, () =>
    Math.floor(Math.random() * 16)
      .toString(16)
      .toUpperCase(),
  );
}

export interface MoodboardState {
  boards: MoodboardSummary[];
  activeBoard: MoodboardDocument | null;
  loading: boolean;

  fetchBoards: () => Promise<MoodboardSummary[]>;
  openBoard: (id: string) => Promise<MoodboardDocument | null>;
  createBoard: (title: string, subtitle?: string) => Promise<MoodboardDocument>;
  deleteBoard: (id: string) => Promise<void>;
  setBoardPinnedOffline: (id: string, pinned: boolean) => Promise<void>;
  addAssetsToBoard: (boardId: string, assetIds: string[]) => Promise<void>;
}

export const useMoodboardStore = create<MoodboardState>((set, get) => ({
  boards: [],
  activeBoard: null,
  loading: false,

  async fetchBoards() {
    set({ loading: true });
    try {
      const boards = await getTransport().fetchBoards();
      set({ boards, loading: false });
      const coord = useCoordinatorStore.getState();
      if (!coord.activeMoodboardId && boards[0]) {
        coord.setActiveMoodboardId(boards[0].id);
      }
      return boards;
    } catch {
      set({ loading: false });
      return get().boards;
    }
  },

  async openBoard(id) {
    const doc = await getTransport().fetchBoard(id);
    set({ activeBoard: doc });
    useCoordinatorStore.getState().setActiveMoodboardId(id);
    return doc;
  },

  async createBoard(title, subtitle = '') {
    const now = msToCocoaSeconds(Date.now());
    const doc: MoodboardDocument = {
      id: makeBoardId(),
      title: title.trim() || '未命名情绪板',
      subtitle: subtitle.trim(),
      mode: { freeform: {} },
      nodes: [],
      connectors: [],
      inkStrokes: [],
      extractedPalette: [],
      candidateAssetIDs: [],
      pinnedOffline: false,
      viewportCenter: { x: 480, y: 320 },
      viewportZoom: 1,
      createdAt: now,
      updatedAt: now,
      updatedHLC: Date.now(),
    };
    const saved = await getTransport().saveBoard(doc);
    await get().fetchBoards();
    set({ activeBoard: saved });
    useCoordinatorStore.getState().setActiveMoodboardId(saved.id);
    useCoordinatorStore.getState().pushToast({
      message: `已创建情绪板「${saved.title}」`,
      tone: 'success',
    });
    return saved;
  },

  async deleteBoard(id) {
    await getTransport().deleteBoard(id);
    const boards = await get().fetchBoards();
    const coord = useCoordinatorStore.getState();
    if (get().activeBoard?.id === id) {
      set({ activeBoard: null });
    }
    if (coord.activeMoodboardId === id) {
      coord.setActiveMoodboardId(boards[0]?.id ?? null);
    }
    if (coord.destination.type === 'moodboard' && coord.destination.id === id) {
      coord.setDestination({ type: 'moodboardsHome' });
    }
    coord.pushToast({ message: '情绪板已删除', tone: 'info' });
  },

  async setBoardPinnedOffline(id, pinned) {
    const updated = await getTransport().setBoardPinnedOffline(id, pinned);
    await get().fetchBoards();
    if (get().activeBoard?.id === id) {
      set({ activeBoard: updated });
    }
    useCoordinatorStore.getState().pushToast({
      message: pinned ? '已设为离线常驻' : '已取消离线常驻',
      tone: 'info',
    });
  },

  async addAssetsToBoard(boardId, assetIds) {
    if (assetIds.length === 0) return;
    const doc = await getTransport().fetchBoard(boardId);
    if (!doc) return;
    const now = msToCocoaSeconds(Date.now());
    const existingCandidates = new Set(doc.candidateAssetIDs);
    const addedIds = assetIds.filter((id) => !existingCandidates.has(id));
    const nextNodes = [...doc.nodes];

    addedIds.forEach((assetId, idx) => {
      const col = (nextNodes.length + idx) % 4;
      const row = Math.floor((nextNodes.length + idx) / 4);
      nextNodes.push({
        id: makeBoardId(),
        kind: { asset: { assetID: assetId, caption: null, cropRect: null } },
        frame: { x: 80 + col * 260, y: 80 + row * 240, width: 220, height: 200 },
        zIndex: nextNodes.length + idx + 1,
        rotationDegrees: 0,
        flipHorizontal: false,
        flipVertical: false,
        isLocked: false,
        editorialOrder: nextNodes.length + idx,
        updatedAt: now,
      });
    });

    const updatedDoc: MoodboardDocument = {
      ...doc,
      nodes: nextNodes,
      candidateAssetIDs: Array.from(new Set([...doc.candidateAssetIDs, ...assetIds])),
      updatedAt: now,
      updatedHLC: Date.now(),
    };
    const saved = await getTransport().saveBoard(updatedDoc);
    if (get().activeBoard?.id === saved.id) {
      set({ activeBoard: saved });
    }
    await get().fetchBoards();
    useCoordinatorStore.getState().pushToast({
      message: `已添加 ${assetIds.length} 项到情绪板「${saved.title}」`,
      tone: 'success',
    });
  },
}));
