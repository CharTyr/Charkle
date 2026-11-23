import { create } from 'zustand';
import { getTransport } from '../api/transport';
import {
  freezeIntoFreeform,
  tidyNodesInFreeform,
} from '../features/moodboard/editorial';
import {
  isAutoEditorialMode,
  msToCocoaSeconds,
  type AssetRecord,
  type AutoLayoutConfig,
  type BoardConnector,
  type BoardNode,
  type BoardPoint,
  type GroupTint,
  type InkStroke,
  type MoodboardAgentStep,
  type MoodboardCurationRequest,
  type MoodboardDocument,
  type MoodboardProposal,
  type MoodboardSummary,
  type NoteStyle,
  type ScoredAsset,
} from '../types/domain';
import { useCoordinatorStore } from './coordinatorStore';

const MAX_UNDO_HISTORY = 40;

function makeUuid(): string {
  if (typeof crypto !== 'undefined' && typeof crypto.randomUUID === 'function') {
    return crypto.randomUUID().toUpperCase();
  }
  return 'XXXXXXXX-XXXX-4XXX-8XXX-XXXXXXXXXXXX'.replace(/X/g, () =>
    Math.floor(Math.random() * 16)
      .toString(16)
      .toUpperCase(),
  );
}

let saveTimer: number | null = null;

function schedulePersistBoard(doc: MoodboardDocument) {
  if (typeof window === 'undefined') {
    void getTransport().saveBoard(doc);
    return;
  }
  if (saveTimer !== null) window.clearTimeout(saveTimer);
  saveTimer = window.setTimeout(() => {
    saveTimer = null;
    void getTransport().saveBoard(doc);
  }, 180);
}

export interface MoodboardState {
  boards: MoodboardSummary[];
  activeBoard: MoodboardDocument | null;
  historyPast: MoodboardDocument[];
  historyFuture: MoodboardDocument[];
  selectedNodeIds: string[];
  candidatePool: ScoredAsset[];
  agentTrace: MoodboardAgentStep[];
  curating: boolean;
  lastProposal: MoodboardProposal | null;
  loading: boolean;

  fetchBoards: () => Promise<MoodboardSummary[]>;
  openBoard: (id: string) => Promise<MoodboardDocument | null>;
  createBoard: (
    title: string,
    subtitle?: string,
    mode?: 'autoEditorial' | 'freeform',
  ) => Promise<MoodboardDocument>;
  deleteBoard: (id: string) => Promise<void>;
  setBoardPinnedOffline: (id: string, pinned: boolean) => Promise<void>;
  addAssetsToBoard: (boardId: string, assetIds: string[]) => Promise<void>;

  // M4 Studio editing, Undo/Redo, Curation & Swap
  setSelectedNodeIds: (ids: string[]) => void;
  pushAgentStep: (step: MoodboardAgentStep) => void;
  curateMoodboard: (request: MoodboardCurationRequest) => Promise<MoodboardProposal>;
  mutateActiveBoard: (
    updater: (doc: MoodboardDocument) => MoodboardDocument,
    opts?: { recordUndo?: boolean; immediateSave?: boolean },
  ) => void;
  undo: () => void;
  redo: () => void;
  swapNodeAsset: (nodeId: string, replacementAssetId: string) => void;
  addAssetNodeAt: (assetId: string, point?: BoardPoint) => void;
  addNoteNode: (style?: NoteStyle, point?: BoardPoint) => void;
  addGroupFrameNode: (tint?: GroupTint, point?: BoardPoint) => void;
  addPaletteStripNode: (point?: BoardPoint) => void;
  addConnector: (conn: Omit<BoardConnector, 'id' | 'updatedAt'>) => void;
  addInkStroke: (stroke: Omit<InkStroke, 'id' | 'createdAt'>) => void;
  removeNodes: (nodeIds: string[]) => void;
  switchBoardMode: (
    nextMode: 'autoEditorial' | 'freeform',
    containerWidth: number,
    assetsById: Map<string, AssetRecord>,
    autoConfig?: Partial<AutoLayoutConfig>,
  ) => void;
  tidyActiveBoard: (assetsById: Map<string, AssetRecord>) => void;
}

export const useMoodboardStore = create<MoodboardState>((set, get) => ({
  boards: [],
  activeBoard: null,
  historyPast: [],
  historyFuture: [],
  selectedNodeIds: [],
  candidatePool: [],
  agentTrace: [],
  curating: false,
  lastProposal: null,
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
    set({
      activeBoard: doc,
      historyPast: [],
      historyFuture: [],
      selectedNodeIds: [],
    });
    useCoordinatorStore.getState().setActiveMoodboardId(id);
    return doc;
  },

  async createBoard(title, subtitle = '', mode = 'autoEditorial') {
    const now = msToCocoaSeconds(Date.now());
    const doc: MoodboardDocument = {
      id: makeUuid(),
      title: title.trim() || '未命名情绪板',
      subtitle: subtitle.trim(),
      mode:
        mode === 'freeform'
          ? { freeform: {} }
          : {
              autoEditorial: {
                _0: { columns: 4, spacing: 16, style: 'balanced', showPaletteStrip: true },
              },
            },
      nodes: [],
      connectors: [],
      inkStrokes: [],
      extractedPalette: [],
      candidateAssetIDs: [],
      pinnedOffline: false,
      viewportCenter: { x: 520, y: 340 },
      viewportZoom: 1,
      createdAt: now,
      updatedAt: now,
      updatedHLC: Date.now(),
    };
    const saved = await getTransport().saveBoard(doc);
    await get().fetchBoards();
    set({ activeBoard: saved, historyPast: [], historyFuture: [], selectedNodeIds: [] });
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
      set({ activeBoard: null, historyPast: [], historyFuture: [], selectedNodeIds: [] });
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
    const nextNodes: BoardNode[] = [...doc.nodes];
    const maxOrder = nextNodes.reduce((m, n) => Math.max(m, n.editorialOrder), -1);
    const maxZ = nextNodes.reduce((m, n) => Math.max(m, n.zIndex), 0);

    assetIds.forEach((assetId, idx) => {
      const col = (nextNodes.length + idx) % 4;
      const row = Math.floor((nextNodes.length + idx) / 4);
      nextNodes.push({
        id: makeUuid(),
        kind: {
          assetRef: {
            assetID: assetId,
            crop: null,
            weight: 1,
            autoplayLoop: true,
          },
        },
        frame: { x: 64 + col * 290, y: 64 + row * 240, width: 260, height: 210 },
        zIndex: maxZ + idx + 1,
        rotationDegrees: 0,
        flipHorizontal: false,
        flipVertical: false,
        isLocked: false,
        editorialOrder: maxOrder + idx + 1,
        updatedAt: now,
      });
    });

    const updatedDoc: MoodboardDocument = {
      ...doc,
      nodes: nextNodes,
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

  setSelectedNodeIds(ids) {
    set({ selectedNodeIds: Array.from(new Set(ids)) });
  },

  pushAgentStep(step) {
    set((s) => ({
      agentTrace: [...s.agentTrace.filter((x) => x.id !== step.id), step],
    }));
  },

  async curateMoodboard(request) {
    set({ curating: true, agentTrace: [] });
    try {
      const proposal = await getTransport().curateMoodboard(request);
      const saved = await getTransport().saveBoard(proposal.draftDocument);
      await get().fetchBoards();
      set({
        curating: false,
        lastProposal: proposal,
        activeBoard: saved,
        candidatePool: proposal.candidatePool,
        agentTrace: proposal.agentTrace,
        historyPast: [],
        historyFuture: [],
        selectedNodeIds: [],
      });
      useCoordinatorStore.getState().setActiveMoodboardId(saved.id);
      useCoordinatorStore.getState().setDestination({ type: 'moodboard', id: saved.id });
      useCoordinatorStore.getState().pushToast({
        message: proposal.curatedSummary,
        tone: 'success',
      });
      return proposal;
    } catch (err) {
      set({ curating: false });
      useCoordinatorStore.getState().pushToast({
        message: `智能生成失败：${err instanceof Error ? err.message : String(err)}`,
        tone: 'error',
      });
      throw err;
    }
  },

  mutateActiveBoard(updater, opts = {}) {
    const current = get().activeBoard;
    if (!current) return;
    const recordUndo = opts.recordUndo ?? true;
    const updated = updater(current);
    const stamped: MoodboardDocument = {
      ...updated,
      updatedAt: msToCocoaSeconds(Date.now()),
      updatedHLC: Date.now(),
    };

    set((s) => ({
      activeBoard: stamped,
      historyPast: recordUndo
        ? [...s.historyPast.slice(-(MAX_UNDO_HISTORY - 1)), current]
        : s.historyPast,
      historyFuture: recordUndo ? [] : s.historyFuture,
    }));

    if (opts.immediateSave) {
      void getTransport()
        .saveBoard(stamped)
        .then(() => get().fetchBoards());
    } else {
      schedulePersistBoard(stamped);
    }
  },

  undo() {
    const { historyPast, activeBoard, historyFuture } = get();
    if (!activeBoard || historyPast.length === 0) return;
    const prev = historyPast[historyPast.length - 1];
    set({
      activeBoard: prev,
      historyPast: historyPast.slice(0, -1),
      historyFuture: [activeBoard, ...historyFuture].slice(0, MAX_UNDO_HISTORY),
    });
    schedulePersistBoard(prev);
  },

  redo() {
    const { historyPast, activeBoard, historyFuture } = get();
    if (!activeBoard || historyFuture.length === 0) return;
    const next = historyFuture[0];
    set({
      activeBoard: next,
      historyPast: [...historyPast, activeBoard].slice(-MAX_UNDO_HISTORY),
      historyFuture: historyFuture.slice(1),
    });
    schedulePersistBoard(next);
  },

  swapNodeAsset(nodeId, replacementAssetId) {
    const prevAssetId = (() => {
      const node = get().activeBoard?.nodes.find((n) => n.id === nodeId);
      return node && 'assetRef' in node.kind ? node.kind.assetRef.assetID : null;
    })();

    get().mutateActiveBoard((doc) => ({
      ...doc,
      nodes: doc.nodes.map((n) => {
        if (n.id !== nodeId || !('assetRef' in n.kind)) return n;
        return {
          ...n,
          kind: {
            assetRef: {
              ...n.kind.assetRef,
              assetID: replacementAssetId,
              crop: null,
            },
          },
          updatedAt: msToCocoaSeconds(Date.now()),
        };
      }),
      candidateAssetIDs: Array.from(
        new Set([
          ...(prevAssetId ? [prevAssetId] : []),
          ...doc.candidateAssetIDs.filter((id) => id !== replacementAssetId),
        ]),
      ),
    }));

    useCoordinatorStore.getState().pushToast({
      message: '已原地替换素材（保留当前构图槽位）',
      tone: 'success',
      durationMs: 2200,
    });
  },

  addAssetNodeAt(assetId, point) {
    const now = msToCocoaSeconds(Date.now());
    get().mutateActiveBoard((doc) => {
      const maxOrder = doc.nodes.reduce((m, n) => Math.max(m, n.editorialOrder), -1);
      const maxZ = doc.nodes.reduce((m, n) => Math.max(m, n.zIndex), 0);
      const node: BoardNode = {
        id: makeUuid(),
        kind: {
          assetRef: { assetID: assetId, crop: null, weight: 1, autoplayLoop: true },
        },
        frame: {
          x: point?.x ?? 100 + (doc.nodes.length % 4) * 260,
          y: point?.y ?? 100 + Math.floor(doc.nodes.length / 4) * 220,
          width: 280,
          height: 220,
        },
        zIndex: maxZ + 1,
        rotationDegrees: 0,
        flipHorizontal: false,
        flipVertical: false,
        isLocked: false,
        editorialOrder: maxOrder + 1,
        updatedAt: now,
      };
      return {
        ...doc,
        nodes: [...doc.nodes, node],
      };
    });
  },

  addNoteNode(style = 'warm', point) {
    const now = msToCocoaSeconds(Date.now());
    get().mutateActiveBoard((doc) => {
      const maxOrder = doc.nodes.reduce((m, n) => Math.max(m, n.editorialOrder), -1);
      const maxZ = doc.nodes.reduce((m, n) => Math.max(m, n.zIndex), 0);
      const node: BoardNode = {
        id: makeUuid(),
        kind: {
          note: {
            title: '灵感便签',
            text: '记录色彩、材质或构图思路…',
            style,
            fontSize: 14,
          },
        },
        frame: { x: point?.x ?? 120, y: point?.y ?? 120, width: 250, height: 168 },
        zIndex: maxZ + 1,
        rotationDegrees: 0,
        flipHorizontal: false,
        flipVertical: false,
        isLocked: false,
        editorialOrder: maxOrder + 1,
        updatedAt: now,
      };
      return { ...doc, nodes: [...doc.nodes, node] };
    });
  },

  addGroupFrameNode(tint = 'sand', point) {
    const now = msToCocoaSeconds(Date.now());
    get().mutateActiveBoard((doc) => {
      const maxOrder = doc.nodes.reduce((m, n) => Math.max(m, n.editorialOrder), -1);
      const minZ = doc.nodes.reduce((m, n) => Math.min(m, n.zIndex), 0);
      const node: BoardNode = {
        id: makeUuid(),
        kind: { groupFrame: { title: '视觉分组区域', tint } },
        frame: { x: point?.x ?? 60, y: point?.y ?? 60, width: 580, height: 380 },
        zIndex: minZ - 1,
        rotationDegrees: 0,
        flipHorizontal: false,
        flipVertical: false,
        isLocked: false,
        editorialOrder: maxOrder + 1,
        updatedAt: now,
      };
      return { ...doc, nodes: [node, ...doc.nodes] };
    });
  },

  addPaletteStripNode(point) {
    const now = msToCocoaSeconds(Date.now());
    get().mutateActiveBoard((doc) => {
      const maxOrder = doc.nodes.reduce((m, n) => Math.max(m, n.editorialOrder), -1);
      const maxZ = doc.nodes.reduce((m, n) => Math.max(m, n.zIndex), 0);
      const node: BoardNode = {
        id: makeUuid(),
        kind: {
          paletteStrip: {
            colors: doc.extractedPalette,
            autoSyncWithBoard: true,
          },
        },
        frame: { x: point?.x ?? 80, y: point?.y ?? 40, width: 460, height: 74 },
        zIndex: maxZ + 1,
        rotationDegrees: 0,
        flipHorizontal: false,
        flipVertical: false,
        isLocked: false,
        editorialOrder: maxOrder + 1,
        updatedAt: now,
      };
      return { ...doc, nodes: [...doc.nodes, node] };
    });
  },

  addConnector(conn) {
    const now = msToCocoaSeconds(Date.now());
    get().mutateActiveBoard((doc) => ({
      ...doc,
      connectors: [...doc.connectors, { ...conn, id: makeUuid(), updatedAt: now }],
    }));
  },

  addInkStroke(stroke) {
    const now = msToCocoaSeconds(Date.now());
    get().mutateActiveBoard((doc) => ({
      ...doc,
      inkStrokes: [...doc.inkStrokes, { ...stroke, id: makeUuid(), createdAt: now }],
    }));
  },

  removeNodes(nodeIds) {
    if (nodeIds.length === 0) return;
    const drop = new Set(nodeIds);
    get().mutateActiveBoard((doc) => ({
      ...doc,
      nodes: doc.nodes.filter((n) => !drop.has(n.id)),
      connectors: doc.connectors.filter(
        (c) => !drop.has(c.fromNodeID) && !drop.has(c.toNodeID),
      ),
    }));
    set((s) => ({
      selectedNodeIds: s.selectedNodeIds.filter((id) => !drop.has(id)),
    }));
  },

  switchBoardMode(nextMode, containerWidth, assetsById, autoConfig) {
    get().mutateActiveBoard(
      (doc) => {
        if (nextMode === 'freeform') {
          return freezeIntoFreeform(doc, containerWidth, assetsById);
        }
        const prevCfg: AutoLayoutConfig = isAutoEditorialMode(doc.mode)
          ? doc.mode.autoEditorial._0
          : { columns: 4, spacing: 16, style: 'balanced', showPaletteStrip: true };
        return {
          ...doc,
          mode: {
            autoEditorial: {
              _0: { ...prevCfg, ...autoConfig },
            },
          },
        };
      },
      { recordUndo: true, immediateSave: true },
    );
  },

  tidyActiveBoard(assetsById) {
    const selected = new Set(get().selectedNodeIds);
    get().mutateActiveBoard((doc) => tidyNodesInFreeform(doc, selected, assetsById));
  },
}));
