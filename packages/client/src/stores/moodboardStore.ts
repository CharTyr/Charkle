import { create } from 'zustand';
import type {
  BoardNode,
  BoardPoint,
  MoodboardAgentStep,
  MoodboardCurationRequest,
  MoodboardDocument,
  MoodboardProposal,
  MoodboardSeed,
  MoodboardSummary,
  ScoredAsset,
  UUID,
} from '@charkle/shared';
import { getBoardReferencedAssetIDs } from '@charkle/shared';
import { apiClient } from '../api/client';
import { useCoordinatorStore } from './coordinatorStore';

const MAX_HISTORY = 50;

let saveDebounceTimer: number | null = null;
let curateAbortController: AbortController | null = null;

interface MoodboardState {
  boards: MoodboardSummary[];
  activeDocument: MoodboardDocument | null;
  loadingBoard: boolean;
  savingBoard: boolean;

  past: MoodboardDocument[];
  future: MoodboardDocument[];

  selectedNodeIDs: Set<UUID>;
  swappingNodeID: UUID | null;
  candidatePool: ScoredAsset[];
  loadingCandidates: boolean;

  proposal: MoodboardProposal | null;
  agentSteps: MoodboardAgentStep[];
  isCurating: boolean;
  curationError: string | null;

  setBoards: (boards: MoodboardSummary[]) => void;
  loadBoards: () => Promise<void>;
  openBoard: (id: UUID) => Promise<MoodboardDocument | null>;
  createBoard: (title: string, subtitle?: string, seedAssetIDs?: UUID[]) => Promise<MoodboardDocument>;
  deleteBoard: (id: UUID) => Promise<void>;

  mutateDocument: (
    updater: (doc: MoodboardDocument) => MoodboardDocument,
    options?: { recordHistory?: boolean; immediateSave?: boolean },
  ) => void;
  saveActiveDocumentNow: () => Promise<void>;

  undo: () => void;
  redo: () => void;

  setSelectedNodeIDs: (ids: Iterable<UUID>) => void;
  toggleSelectNode: (id: UUID, multi?: boolean) => void;
  clearNodeSelection: () => void;

  setSwappingNodeID: (nodeID: UUID | null) => void;
  loadReplacementCandidates: (assetID: UUID, limit?: number) => Promise<void>;
  swapNodeAsset: (nodeID: UUID, newAssetID: UUID) => Promise<void>;
  addAssetsToBoard: (boardID: UUID, assetIDs: UUID[], dropPoint?: BoardPoint | null) => Promise<void>;
  reextractActiveBoardPalette: () => Promise<void>;

  proposeMoodboard: (seed: MoodboardSeed, primaryCount?: number, candidateCount?: number) => Promise<MoodboardProposal>;
  curateMoodboard: (req: MoodboardCurationRequest) => Promise<MoodboardProposal | null>;
  cancelCuration: () => void;
  applyProposal: (proposal?: MoodboardProposal | null) => Promise<MoodboardDocument | null>;
  clearProposal: () => void;
  pushAgentStep: (step: MoodboardAgentStep) => void;
}

function summarizeDocument(doc: MoodboardDocument): MoodboardSummary {
  const refIDs = getBoardReferencedAssetIDs(doc);
  return {
    id: doc.id,
    title: doc.title,
    subtitle: doc.subtitle,
    mode: doc.mode,
    itemCount: doc.nodes.length,
    previewAssetIDs: refIDs.slice(0, 4),
    paletteHexes: doc.extractedPalette.slice(0, 6).map((c) => c.hex),
    pinnedOffline: doc.pinnedOffline,
    updatedAt: doc.updatedAt,
  };
}

export const useMoodboardStore = create<MoodboardState>((set, get) => ({
  boards: [],
  activeDocument: null,
  loadingBoard: false,
  savingBoard: false,

  past: [],
  future: [],

  selectedNodeIDs: new Set<UUID>(),
  swappingNodeID: null,
  candidatePool: [],
  loadingCandidates: false,

  proposal: null,
  agentSteps: [],
  isCurating: false,
  curationError: null,

  setBoards: (boards) => set({ boards }),

  loadBoards: async () => {
    const res = await apiClient.listBoards();
    set({ boards: res.boards });
  },

  openBoard: async (id) => {
    set({ loadingBoard: true });
    try {
      const res = await apiClient.getBoard(id);
      set({
        activeDocument: res.board,
        loadingBoard: false,
        past: [],
        future: [],
        selectedNodeIDs: new Set<UUID>(),
        swappingNodeID: null,
      });
      return res.board;
    } catch (err) {
      set({ loadingBoard: false });
      useCoordinatorStore.getState().pushToast({
        tone: 'error',
        message: err instanceof Error ? err.message : '加载情绪板失败',
      });
      return null;
    }
  },

  createBoard: async (title, subtitle = '', seedAssetIDs = []) => {
    const res = await apiClient.createBoard({ title, subtitle, seedAssetIDs });
    const summary = summarizeDocument(res.board);
    set((s) => ({
      boards: [summary, ...s.boards.filter((b) => b.id !== summary.id)],
      activeDocument: res.board,
      past: [],
      future: [],
      selectedNodeIDs: new Set<UUID>(),
    }));
    const coord = useCoordinatorStore.getState();
    if (!coord.activeBoardID) {
      coord.setActiveBoardID(res.board.id);
    }
    return res.board;
  },

  deleteBoard: async (id) => {
    await apiClient.deleteBoard(id);
    set((s) => ({
      boards: s.boards.filter((b) => b.id !== id),
      activeDocument: s.activeDocument?.id === id ? null : s.activeDocument,
    }));
    const coord = useCoordinatorStore.getState();
    if (coord.activeBoardID === id) {
      const remaining = get().boards;
      coord.setActiveBoardID(remaining.length > 0 ? remaining[0].id : null);
    }
    if (coord.destination.type === 'moodboard' && coord.destination.id === id) {
      coord.navigate({ type: 'moodboardsHome' });
    }
  },

  mutateDocument: (updater, options = {}) => {
    const { recordHistory = true, immediateSave = false } = options;
    const current = get().activeDocument;
    if (!current) return;

    const now = new Date().toISOString();
    const updated: MoodboardDocument = {
      ...updater(current),
      updatedAt: now,
    };

    const summary = summarizeDocument(updated);
    set((s) => ({
      activeDocument: updated,
      boards: s.boards.map((b) => (b.id === updated.id ? summary : b)),
      past: recordHistory ? [...s.past.slice(-(MAX_HISTORY - 1)), current] : s.past,
      future: recordHistory ? [] : s.future,
    }));

    if (saveDebounceTimer !== null) {
      window.clearTimeout(saveDebounceTimer);
      saveDebounceTimer = null;
    }

    if (immediateSave) {
      void get().saveActiveDocumentNow();
    } else if (typeof window !== 'undefined') {
      saveDebounceTimer = window.setTimeout(() => {
        saveDebounceTimer = null;
        void get().saveActiveDocumentNow();
      }, 450);
    }
  },

  saveActiveDocumentNow: async () => {
    const doc = get().activeDocument;
    if (!doc) return;
    set({ savingBoard: true });
    try {
      const res = await apiClient.saveBoard(doc.id, doc);
      const summary = summarizeDocument(res.board);
      set((s) => ({
        savingBoard: false,
        boards: s.boards.map((b) => (b.id === summary.id ? summary : b)),
      }));
    } catch {
      set({ savingBoard: false });
    }
  },

  undo: () => {
    const { past, activeDocument, future } = get();
    if (!activeDocument || past.length === 0) return;
    const previous = past[past.length - 1];
    set({
      activeDocument: previous,
      past: past.slice(0, -1),
      future: [activeDocument, ...future.slice(0, MAX_HISTORY - 1)],
    });
    void get().saveActiveDocumentNow();
  },

  redo: () => {
    const { past, activeDocument, future } = get();
    if (!activeDocument || future.length === 0) return;
    const next = future[0];
    set({
      activeDocument: next,
      past: [...past.slice(-(MAX_HISTORY - 1)), activeDocument],
      future: future.slice(1),
    });
    void get().saveActiveDocumentNow();
  },

  setSelectedNodeIDs: (ids) => set({ selectedNodeIDs: new Set(ids) }),

  toggleSelectNode: (id, multi = false) => {
    set((s) => {
      if (!multi) return { selectedNodeIDs: new Set([id]) };
      const next = new Set(s.selectedNodeIDs);
      if (next.has(id)) next.delete(id);
      else next.add(id);
      return { selectedNodeIDs: next };
    });
  },

  clearNodeSelection: () => set({ selectedNodeIDs: new Set<UUID>(), swappingNodeID: null }),

  setSwappingNodeID: (nodeID) => {
    set({ swappingNodeID: nodeID });
    if (nodeID) {
      const doc = get().activeDocument;
      const node = doc?.nodes.find((n) => n.id === nodeID);
      if (node && node.kind.type === 'assetRef') {
        void get().loadReplacementCandidates(node.kind.assetID);
      }
    }
  },

  loadReplacementCandidates: async (assetID, limit = 24) => {
    const doc = get().activeDocument;
    const boardContext = doc ? getBoardReferencedAssetIDs(doc) : [];
    set({ loadingCandidates: true });
    try {
      const res = await apiClient.getReplacementCandidates({
        assetID,
        excluding: boardContext,
        boardContext,
        limit,
      });
      set({ candidatePool: res.candidates, loadingCandidates: false });
    } catch {
      set({ loadingCandidates: false });
    }
  },

  swapNodeAsset: async (nodeID, newAssetID) => {
    get().mutateDocument(
      (doc) => ({
        ...doc,
        nodes: doc.nodes.map((n) => {
          if (n.id !== nodeID || n.kind.type !== 'assetRef') return n;
          return {
            ...n,
            kind: { ...n.kind, assetID: newAssetID, crop: null },
            updatedAt: new Date().toISOString(),
          };
        }),
      }),
      { recordHistory: true, immediateSave: true },
    );
    set({ swappingNodeID: null });
    void get().reextractActiveBoardPalette();
  },

  addAssetsToBoard: async (boardID, assetIDs, dropPoint = null) => {
    if (assetIDs.length === 0) return;
    const isCurrent = get().activeDocument?.id === boardID;
    const targetDoc = isCurrent ? get().activeDocument! : (await apiClient.getBoard(boardID)).board;

    const now = new Date().toISOString();
    const maxOrder = targetDoc.nodes.reduce((m, n) => Math.max(m, n.editorialOrder), -1);
    const maxZ = targetDoc.nodes.reduce((m, n) => Math.max(m, n.zIndex), 0);

    const newNodes: BoardNode[] = assetIDs.map((assetID, idx) => ({
      id: crypto.randomUUID().toUpperCase(),
      kind: {
        type: 'assetRef',
        assetID,
        crop: null,
        weight: 1,
        autoplayLoop: true,
      },
      frame: {
        x: (dropPoint?.x ?? 120) + idx * 32,
        y: (dropPoint?.y ?? 120) + idx * 32,
        width: 280,
        height: 220,
      },
      zIndex: maxZ + idx + 1,
      rotationDegrees: 0,
      flipHorizontal: false,
      flipVertical: false,
      isLocked: false,
      editorialOrder: maxOrder + idx + 1,
      updatedAt: now,
    }));

    if (isCurrent) {
      get().mutateDocument(
        (doc) => ({
          ...doc,
          nodes: [...doc.nodes, ...newNodes],
        }),
        { recordHistory: true, immediateSave: true },
      );
      void get().reextractActiveBoardPalette();
    } else {
      const updatedDoc: MoodboardDocument = {
        ...targetDoc,
        nodes: [...targetDoc.nodes, ...newNodes],
        updatedAt: now,
      };
      const saved = await apiClient.saveBoard(boardID, updatedDoc);
      const summary = summarizeDocument(saved.board);
      set((s) => ({
        boards: s.boards.map((b) => (b.id === summary.id ? summary : b)),
      }));
    }
  },

  reextractActiveBoardPalette: async () => {
    const doc = get().activeDocument;
    if (!doc) return;
    const assetIDs = getBoardReferencedAssetIDs(doc);
    if (assetIDs.length === 0) return;
    try {
      const res = await apiClient.extractBoardPalette({ assetIDs, count: 7 });
      get().mutateDocument(
        (current) => ({
          ...current,
          extractedPalette: res.colors,
          nodes: current.nodes.map((node) =>
            node.kind.type === 'paletteStrip' && node.kind.autoSyncWithBoard
              ? { ...node, kind: { ...node.kind, colors: res.colors } }
              : node,
          ),
        }),
        { recordHistory: false, immediateSave: true },
      );
    } catch {
      // Optional palette extraction
    }
  },

  proposeMoodboard: async (seed, primaryCount = 12, candidateCount = 24) => {
    set({ isCurating: true, curationError: null, agentSteps: [] });
    try {
      const res = await apiClient.proposeMoodboard({ seed, primaryCount, candidateCount });
      set({
        proposal: res.proposal,
        agentSteps: res.proposal.agentTrace ?? [],
        candidatePool: res.proposal.candidatePool ?? [],
        isCurating: false,
      });
      return res.proposal;
    } catch (err) {
      const message = err instanceof Error ? err.message : '生成情绪板提案失败';
      set({ isCurating: false, curationError: message });
      throw err;
    }
  },

  curateMoodboard: async (req) => {
    curateAbortController?.abort();
    const controller = new AbortController();
    curateAbortController = controller;

    set({ isCurating: true, curationError: null, agentSteps: [] });
    try {
      const proposal = await apiClient.curateMoodboard(
        req,
        (step) => get().pushAgentStep(step),
        controller.signal,
      );
      set({
        proposal,
        agentSteps: proposal.agentTrace.length > 0 ? proposal.agentTrace : get().agentSteps,
        candidatePool: proposal.candidatePool,
        isCurating: false,
      });
      return proposal;
    } catch (err) {
      if ((err as Error).name === 'AbortError') {
        set({ isCurating: false });
        return null;
      }
      const message = err instanceof Error ? err.message : 'AI 策展情绪板失败';
      set({ isCurating: false, curationError: message });
      return null;
    }
  },

  cancelCuration: () => {
    curateAbortController?.abort();
    curateAbortController = null;
    set({ isCurating: false });
  },

  applyProposal: async (proposalOverride) => {
    const target = proposalOverride ?? get().proposal;
    if (!target) return null;
    const draft = target.draftDocument;
    const exists = get().boards.some((b) => b.id === draft.id);
    const saved = exists
      ? (await apiClient.saveBoard(draft.id, draft)).board
      : (
          await apiClient.saveBoard(
            (await apiClient.createBoard({ title: draft.title, subtitle: draft.subtitle })).board.id,
            draft,
          )
        ).board;

    const summary = summarizeDocument(saved);
    set((s) => ({
      activeDocument: saved,
      boards: [summary, ...s.boards.filter((b) => b.id !== summary.id)],
      candidatePool: target.candidatePool,
      proposal: null,
      past: [],
      future: [],
    }));
    const coord = useCoordinatorStore.getState();
    coord.setActiveBoardID(saved.id);
    coord.openBoard(saved.id);
    coord.closeGeneratorModal();
    return saved;
  },

  clearProposal: () => set({ proposal: null, agentSteps: [], curationError: null }),

  pushAgentStep: (step) => {
    set((s) => {
      const idx = s.agentSteps.findIndex((existing) => existing.id === step.id);
      if (idx >= 0) {
        const next = [...s.agentSteps];
        next[idx] = step;
        return { agentSteps: next };
      }
      return { agentSteps: [...s.agentSteps, step] };
    });
  },
}));
