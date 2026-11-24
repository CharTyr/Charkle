import { create } from 'zustand';
import { getTransport } from '../api/transport';
import {
  extractBoardPaletteFromAssets,
  freezeIntoFreeform,
  normalizeDegrees,
  tidyNodesInFreeform,
} from '../features/moodboard/editorial';
import {
  isAutoEditorialMode,
  msToCocoaSeconds,
  type AssetRecord,
  type AutoLayoutConfig,
  type BoardConnector,
  type BoardLayoutMode,
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
import { useLibraryStore } from './libraryStore';

const MAX_UNDO_HISTORY = 45;

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

function finiteOr(value: unknown, fallback: number): number {
  return typeof value === 'number' && Number.isFinite(value) ? value : fallback;
}

function normalizeNode(raw: BoardNode): BoardNode {
  const frame = raw.frame ?? { x: 40, y: 40, width: 240, height: 180 };
  const safeFrame = {
    x: finiteOr(frame.x, 40),
    y: finiteOr(frame.y, 40),
    width: Math.max(24, finiteOr(frame.width, 240)),
    height: Math.max(24, finiteOr(frame.height, 180)),
  };

  let safeKind = raw.kind;
  if (safeKind && 'paletteStrip' in safeKind) {
    safeKind = {
      paletteStrip: {
        colors: Array.isArray(safeKind.paletteStrip.colors)
          ? safeKind.paletteStrip.colors
          : [],
        autoSyncWithBoard: Boolean(safeKind.paletteStrip.autoSyncWithBoard),
      },
    };
  } else if (safeKind && 'note' in safeKind) {
    safeKind = {
      note: {
        title: safeKind.note.title ?? null,
        text: typeof safeKind.note.text === 'string' ? safeKind.note.text : '',
        style: safeKind.note.style ?? 'paper',
        fontSize: Math.max(10, Math.min(36, finiteOr(safeKind.note.fontSize, 14))),
      },
    };
  } else if (safeKind && 'groupFrame' in safeKind) {
    safeKind = {
      groupFrame: {
        title: typeof safeKind.groupFrame.title === 'string' ? safeKind.groupFrame.title : '',
        tint: safeKind.groupFrame.tint ?? 'neutral',
      },
    };
  } else if (safeKind && 'assetRef' in safeKind) {
    safeKind = {
      assetRef: {
        assetID: safeKind.assetRef.assetID,
        crop: safeKind.assetRef.crop ?? null,
        weight: Math.max(1, finiteOr(safeKind.assetRef.weight, 1)),
        autoplayLoop: Boolean(safeKind.assetRef.autoplayLoop),
      },
    };
  }

  return {
    ...raw,
    kind: safeKind,
    frame: safeFrame,
    zIndex: finiteOr(raw.zIndex, 0),
    rotationDegrees: normalizeDegrees(finiteOr(raw.rotationDegrees, 0)),
    flipHorizontal: Boolean(raw.flipHorizontal),
    flipVertical: Boolean(raw.flipVertical),
    isLocked: Boolean(raw.isLocked),
    editorialOrder: finiteOr(raw.editorialOrder, 0),
  };
}

export function normalizeMoodboardDocument(doc: MoodboardDocument): MoodboardDocument {
  const safeMode: BoardLayoutMode =
    doc.mode && ('freeform' in doc.mode || 'autoEditorial' in doc.mode)
      ? doc.mode
      : { freeform: {} };
  const rawCenter = doc.viewportCenter ?? { x: 0, y: 0 };
  const safeZoom = Math.max(0.2, Math.min(3.0, finiteOr(doc.viewportZoom, 1) || 1));

  const nodes = Array.isArray(doc.nodes)
    ? doc.nodes.filter((n): n is BoardNode => Boolean(n && n.id && n.kind)).map(normalizeNode)
    : [];
  const connectors = Array.isArray(doc.connectors)
    ? doc.connectors.filter((c): c is BoardConnector => Boolean(c && c.id))
    : [];
  const inkStrokes = Array.isArray(doc.inkStrokes)
    ? doc.inkStrokes
        .filter((s): s is InkStroke => Boolean(s && s.id && Array.isArray(s.points)))
        .map((s) => ({
          ...s,
          colorHex: s.colorHex || '#D95D48',
          lineWidth: Math.max(1, finiteOr(s.lineWidth, 3.5)),
          opacity: Math.max(0.1, Math.min(1, finiteOr(s.opacity, 0.92))),
        }))
    : [];
  const extractedPalette = Array.isArray(doc.extractedPalette)
    ? doc.extractedPalette.filter((c) => Boolean(c && typeof c.hex === 'string'))
    : [];
  const candidateAssetIDs = Array.isArray(doc.candidateAssetIDs)
    ? doc.candidateAssetIDs.filter((id): id is string => typeof id === 'string')
    : [];

  return {
    ...doc,
    title: typeof doc.title === 'string' ? doc.title : '未命名情绪板',
    subtitle: typeof doc.subtitle === 'string' ? doc.subtitle : '',
    mode: safeMode,
    nodes,
    connectors,
    inkStrokes,
    extractedPalette,
    candidateAssetIDs,
    pinnedOffline: Boolean(doc.pinnedOffline),
    viewportCenter: {
      x: finiteOr(rawCenter.x, 0),
      y: finiteOr(rawCenter.y, 0),
    },
    viewportZoom: safeZoom,
  };
}

export function normalizeMoodboardSummary(summary: MoodboardSummary): MoodboardSummary {
  return {
    ...summary,
    title: typeof summary.title === 'string' ? summary.title : '未命名情绪板',
    subtitle: typeof summary.subtitle === 'string' ? summary.subtitle : '',
    itemCount: finiteOr(summary.itemCount, 0),
    previewAssetIDs: Array.isArray(summary.previewAssetIDs) ? summary.previewAssetIDs : [],
    paletteHexes: Array.isArray(summary.paletteHexes) ? summary.paletteHexes : [],
    pinnedOffline: Boolean(summary.pinnedOffline),
  };
}

let saveTimer: number | null = null;
let pendingSaveDoc: MoodboardDocument | null = null;
let viewportSaveTimer: number | null = null;
let viewportDirty = false;
let latestViewportOverride: { boardId: string; center: BoardPoint; zoom: number } | null = null;
let inFlightSavePromise: Promise<void> | null = null;
let openBoardRequestSeq = 0;
let lifecycleFlushHooksInstalled = false;

function resolveBoardCenter(doc: MoodboardDocument): BoardPoint {
  if (latestViewportOverride && latestViewportOverride.boardId === doc.id) {
    return latestViewportOverride.center;
  }
  if (doc.viewportCenter.x !== 0 || doc.viewportCenter.y !== 0) {
    return doc.viewportCenter;
  }
  return { x: 520, y: 340 };
}

/**
 * Pick a top-left origin centered on `desiredCenter` that cascades cleanly (+28px, +24px)
 * whenever an existing node already occupies the same spot (prevents invisible pixel-for-pixel stacking).
 */
function findNonOverlappingOrigin(
  nodes: BoardNode[],
  desiredCenter: BoardPoint,
  width: number,
  height: number,
): BoardPoint {
  const baseX = Math.round(desiredCenter.x - width * 0.5);
  const baseY = Math.round(desiredCenter.y - height * 0.5);
  let x = baseX;
  let y = baseY;
  for (let step = 0; step < 24; step += 1) {
    const occupied = nodes.some(
      (n) => Math.abs(n.frame.x - x) < 22 && Math.abs(n.frame.y - y) < 22,
    );
    if (!occupied) {
      return { x, y };
    }
    const row = Math.floor((step + 1) / 8);
    const col = (step + 1) % 8;
    x = baseX + col * 28 + row * 18;
    y = baseY + col * 24 - row * 12;
  }
  return { x, y };
}

function reportBoardError(prefix: string, err: unknown) {
  const message = err instanceof Error ? err.message : String(err);
  useCoordinatorStore.getState().pushToast({
    message: `${prefix}：${message}`,
    tone: 'error',
  });
}

function buildSummaryFromDocument(doc: MoodboardDocument): MoodboardSummary {
  const previewAssetIDs: string[] = [];
  const seen = new Set<string>();
  const ordered = [...doc.nodes].sort((a, b) => a.editorialOrder - b.editorialOrder);
  for (const node of ordered) {
    if ('assetRef' in node.kind && node.kind.assetRef.assetID) {
      const aid = node.kind.assetRef.assetID;
      if (!seen.has(aid)) {
        seen.add(aid);
        previewAssetIDs.push(aid);
        if (previewAssetIDs.length >= 4) break;
      }
    }
  }
  return {
    id: doc.id,
    title: doc.title,
    subtitle: doc.subtitle,
    mode: doc.mode,
    itemCount: doc.nodes.length,
    previewAssetIDs,
    paletteHexes: doc.extractedPalette.slice(0, 6).map((c) => c.hex),
    pinnedOffline: doc.pinnedOffline,
    updatedAt: doc.updatedAt,
  };
}

function upsertBoardSummary(
  boards: MoodboardSummary[],
  doc: MoodboardDocument,
): MoodboardSummary[] {
  const nextSummary = buildSummaryFromDocument(doc);
  if (boards.some((b) => b.id === doc.id)) {
    return boards.map((b) => (b.id === doc.id ? nextSummary : b));
  }
  return [nextSummary, ...boards];
}

function resolveAssetsMap(
  provided?: Map<string, AssetRecord>,
  extraAsset?: AssetRecord | null,
): Map<string, AssetRecord> {
  if (provided && provided.size > 0) {
    if (extraAsset && !provided.has(extraAsset.id)) {
      const merged = new Map(provided);
      merged.set(extraAsset.id, extraAsset);
      return merged;
    }
    return provided;
  }
  const lib = useLibraryStore.getState();
  const source = lib.allAssets.length > 0 ? lib.allAssets : lib.assets;
  const map = new Map<string, AssetRecord>();
  for (const a of source) {
    map.set(a.id, a);
  }
  if (extraAsset) {
    map.set(extraAsset.id, extraAsset);
  }
  return map;
}

function applySyncedPaletteToDoc(
  doc: MoodboardDocument,
  assetsById: Map<string, AssetRecord>,
): MoodboardDocument {
  let assetRefCount = 0;
  const refAssets: AssetRecord[] = [];
  for (const node of doc.nodes) {
    if ('assetRef' in node.kind) {
      assetRefCount += 1;
      const asset = assetsById.get(node.kind.assetRef.assetID);
      if (asset) refAssets.push(asset);
    }
  }

  // If no assetRef nodes remain (or library is loaded and none match), clear stale palette cleanly
  if (assetRefCount === 0 || (refAssets.length === 0 && assetsById.size > 0)) {
    return {
      ...doc,
      extractedPalette: [],
      nodes: doc.nodes.map((n) =>
        'paletteStrip' in n.kind && n.kind.paletteStrip.autoSyncWithBoard
          ? {
              ...n,
              kind: {
                paletteStrip: {
                  colors: [],
                  autoSyncWithBoard: true,
                },
              },
            }
          : n,
      ),
    };
  }

  // Library not hydrated yet while assetRefs still exist -> keep current palette untouched
  if (refAssets.length === 0) return doc;

  const palette = extractBoardPaletteFromAssets(refAssets, 6);
  return {
    ...doc,
    extractedPalette: palette,
    nodes: doc.nodes.map((n) =>
      'paletteStrip' in n.kind && n.kind.paletteStrip.autoSyncWithBoard
        ? {
            ...n,
            kind: {
              paletteStrip: {
                colors: palette,
                autoSyncWithBoard: true,
              },
            },
          }
        : n,
    ),
  };
}

function enqueueBoardSave(
  doc: MoodboardDocument,
  refreshSummaries: boolean,
  silentError = false,
): Promise<void> {
  const execute = () =>
    getTransport()
      .saveBoard(doc)
      .then(async () => {
        if (refreshSummaries) {
          await useMoodboardStore.getState().fetchBoards();
        }
      })
      .catch((err) => {
        if (!silentError) {
          reportBoardError('保存情绪板失败', err);
        }
      });

  // Start immediately on this tick when idle so synchronous callers & tests observe saveBoard right away,
  // while still serializing any overlapping saves to prevent out-of-order writes!
  const prev = inFlightSavePromise;
  const run = prev ? prev.then(execute, execute) : execute();

  const tracked = run.finally(() => {
    if (inFlightSavePromise === tracked) {
      inFlightSavePromise = null;
    }
  });
  inFlightSavePromise = tracked;
  return tracked;
}

function persistBoardImmediately(
  doc: MoodboardDocument,
  refreshSummaries = true,
): Promise<void> {
  if (saveTimer !== null && typeof window !== 'undefined') {
    window.clearTimeout(saveTimer);
    saveTimer = null;
  }

  let orphanDoc: MoodboardDocument | null = null;
  if (pendingSaveDoc) {
    if (pendingSaveDoc.id !== doc.id) {
      orphanDoc = pendingSaveDoc;
    }
    pendingSaveDoc = null;
  }

  if (viewportSaveTimer !== null && typeof window !== 'undefined') {
    if (!latestViewportOverride || latestViewportOverride.boardId === doc.id) {
      window.clearTimeout(viewportSaveTimer);
      viewportSaveTimer = null;
    }
  }

  if (latestViewportOverride && latestViewportOverride.boardId === doc.id) {
    viewportDirty = false;
  }

  if (orphanDoc) {
    void enqueueBoardSave(orphanDoc, false);
  }
  return enqueueBoardSave(doc, refreshSummaries);
}

function schedulePersistBoard(doc: MoodboardDocument) {
  if (pendingSaveDoc && pendingSaveDoc.id !== doc.id) {
    const prevDoc = pendingSaveDoc;
    pendingSaveDoc = null;
    if (saveTimer !== null && typeof window !== 'undefined') {
      window.clearTimeout(saveTimer);
      saveTimer = null;
    }
    void enqueueBoardSave(prevDoc, false);
  }
  pendingSaveDoc = doc;
  if (typeof window === 'undefined') {
    void persistBoardImmediately(doc, true);
    return;
  }
  if (saveTimer !== null) window.clearTimeout(saveTimer);
  saveTimer = window.setTimeout(() => {
    saveTimer = null;
    const toSave = pendingSaveDoc ?? doc;
    pendingSaveDoc = null;
    void persistBoardImmediately(toSave, true);
  }, 220);
}

async function flushPendingBoardSaves(): Promise<void> {
  if (saveTimer !== null && typeof window !== 'undefined') {
    window.clearTimeout(saveTimer);
    saveTimer = null;
  }
  if (viewportSaveTimer !== null && typeof window !== 'undefined') {
    window.clearTimeout(viewportSaveTimer);
    viewportSaveTimer = null;
  }
  if (pendingSaveDoc) {
    let doc = pendingSaveDoc;
    pendingSaveDoc = null;
    if (latestViewportOverride && latestViewportOverride.boardId === doc.id) {
      doc = {
        ...doc,
        viewportCenter: latestViewportOverride.center,
        viewportZoom: latestViewportOverride.zoom,
      };
      viewportDirty = false;
    }
    await persistBoardImmediately(doc, false);
    return;
  }
  if (viewportDirty) {
    viewportDirty = false;
    const latest = useMoodboardStore.getState().activeBoard;
    if (latest && latestViewportOverride && latestViewportOverride.boardId === latest.id) {
      const snapshot: MoodboardDocument = {
        ...latest,
        viewportCenter: latestViewportOverride.center,
        viewportZoom: latestViewportOverride.zoom,
      };
      await enqueueBoardSave(snapshot, false, true);
      return;
    }
  }
  if (inFlightSavePromise) {
    await inFlightSavePromise;
  }
}

function ensureLifecycleFlushHooks() {
  if (lifecycleFlushHooksInstalled || typeof window === 'undefined') return;
  lifecycleFlushHooksInstalled = true;
  window.addEventListener('beforeunload', () => {
    void flushPendingBoardSaves();
  });
  if (typeof document !== 'undefined') {
    document.addEventListener('visibilitychange', () => {
      if (document.visibilityState === 'hidden') {
        void flushPendingBoardSaves();
      }
    });
  }
}

export interface MoodboardState {
  boards: MoodboardSummary[];
  activeBoard: MoodboardDocument | null;
  historyPast: MoodboardDocument[];
  historyFuture: MoodboardDocument[];
  selectedNodeIds: string[];
  swappingNodeId: string | null;
  candidatePool: ScoredAsset[];
  agentTrace: MoodboardAgentStep[];
  activeBoardAgentTrace: MoodboardAgentStep[];
  activeBoardLastSummary: string | null;
  curating: boolean;
  isRefiningActiveBoard: boolean;
  lastProposal: MoodboardProposal | null;
  loading: boolean;
  openBoardFailedId: string | null;
  lastError: string | null;
  clipboardAssetIds: string[];
  clipboardIsCut: boolean;

  fetchBoards: () => Promise<MoodboardSummary[]>;
  flushPendingSaves: () => Promise<void>;
  openBoard: (id: string) => Promise<MoodboardDocument | null>;
  createBoard: (
    title: string,
    subtitle?: string,
    mode?: 'autoEditorial' | 'freeform',
  ) => Promise<MoodboardDocument>;
  renameBoard: (id: string, title: string, subtitle?: string) => Promise<void>;
  deleteBoard: (id: string) => Promise<void>;
  setBoardPinnedOffline: (id: string, pinned: boolean) => Promise<void>;
  addAssetsToBoard: (boardId: string, assetIds: string[]) => Promise<void>;

  // Studio editing, Undo/Redo, Curation, Palette & Swap
  setSelectedNodeIds: (ids: string[]) => void;
  setSwappingNodeId: (nodeId: string | null) => void;
  setBoardClipboard: (assetIds: string[], isCut: boolean) => void;
  pushAgentStep: (step: MoodboardAgentStep) => void;
  curateMoodboard: (request: MoodboardCurationRequest) => Promise<MoodboardProposal>;
  refineActiveBoard: (
    instruction: string,
    assetsById?: Map<string, AssetRecord>,
  ) => Promise<MoodboardProposal | null>;
  mutateActiveBoard: (
    updater: (doc: MoodboardDocument) => MoodboardDocument,
    opts?: { recordUndo?: boolean; immediateSave?: boolean },
  ) => void;
  persistViewportQuietly: (center: BoardPoint, zoom: number) => void;
  undo: () => void;
  redo: () => void;
  swapNodeAsset: (
    nodeId: string,
    replacementAssetId: string,
    assetsById?: Map<string, AssetRecord>,
  ) => void;
  syncBoardPalette: (assetsById?: Map<string, AssetRecord>) => void;
  addAssetNodeAt: (
    assetId: string,
    point?: BoardPoint,
    asset?: AssetRecord | null,
    assetsById?: Map<string, AssetRecord>,
  ) => void;
  addNoteNode: (style?: NoteStyle, point?: BoardPoint) => void;
  addGroupFrameNode: (tint?: GroupTint, point?: BoardPoint) => void;
  addPaletteStripNode: (point?: BoardPoint) => void;
  addConnector: (conn: Omit<BoardConnector, 'id' | 'updatedAt'>) => void;
  updateConnectorLabel: (connectorId: string, label: string | null) => void;
  removeConnector: (connectorId: string) => void;
  addInkStroke: (stroke: Omit<InkStroke, 'id' | 'createdAt'>) => void;
  eraseInkAndConnectors: (strokeIds: string[], connectorIds: string[]) => void;
  removeNodes: (
    nodeIds: string[],
    opts?: { assetsById?: Map<string, AssetRecord>; showUndoToast?: boolean },
  ) => number;
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
  swappingNodeId: null,
  candidatePool: [],
  agentTrace: [],
  activeBoardAgentTrace: [],
  activeBoardLastSummary: null,
  curating: false,
  isRefiningActiveBoard: false,
  lastProposal: null,
  loading: false,
  openBoardFailedId: null,
  lastError: null,
  clipboardAssetIds: [],
  clipboardIsCut: false,

  async fetchBoards() {
    set({ loading: true });
    try {
      const rawBoards = await getTransport().fetchBoards();
      const boards = Array.isArray(rawBoards) ? rawBoards.map(normalizeMoodboardSummary) : [];
      set({ boards, loading: false });
      const coord = useCoordinatorStore.getState();
      if (!coord.activeMoodboardId && boards[0]) {
        coord.setActiveMoodboardId(boards[0].id);
      }
      return boards;
    } catch (err) {
      set({
        loading: false,
        lastError: err instanceof Error ? err.message : String(err),
      });
      return get().boards;
    }
  },

  async flushPendingSaves() {
    await flushPendingBoardSaves();
  },

  async openBoard(id) {
    ensureLifecycleFlushHooks();
    const reqSeq = ++openBoardRequestSeq;
    await flushPendingBoardSaves();
    if (reqSeq !== openBoardRequestSeq) return null;
    latestViewportOverride = null;
    viewportDirty = false;
    set({ openBoardFailedId: null, lastError: null });
    try {
      const raw = await getTransport().fetchBoard(id);
      if (reqSeq !== openBoardRequestSeq) return null;
      if (!raw) {
        set({
          activeBoard: null,
          openBoardFailedId: id,
          swappingNodeId: null,
          selectedNodeIds: [],
        });
        return null;
      }
      const doc = normalizeMoodboardDocument(raw);
      set({
        activeBoard: doc,
        historyPast: [],
        historyFuture: [],
        selectedNodeIds: [],
        swappingNodeId: null,
        activeBoardAgentTrace: [],
        activeBoardLastSummary: null,
        openBoardFailedId: null,
      });
      useCoordinatorStore.getState().setActiveMoodboardId(id);
      return doc;
    } catch (err) {
      if (reqSeq !== openBoardRequestSeq) return null;
      const msg = err instanceof Error ? err.message : String(err);
      set({ openBoardFailedId: id, lastError: msg });
      reportBoardError('打开情绪板失败', err);
      return null;
    }
  },

  async createBoard(title, subtitle = '', mode = 'freeform') {
    ensureLifecycleFlushHooks();
    await flushPendingBoardSaves();
    openBoardRequestSeq += 1;
    latestViewportOverride = null;
    viewportDirty = false;
    const now = msToCocoaSeconds(Date.now());
    const doc: MoodboardDocument = {
      id: makeUuid(),
      title: title.trim() || '未命名情绪板',
      subtitle: subtitle.trim(),
      mode:
        mode === 'autoEditorial'
          ? {
              autoEditorial: {
                _0: { columns: 4, spacing: 16, style: 'balanced', showPaletteStrip: true },
              },
            }
          : { freeform: {} },
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
    try {
      const saved = normalizeMoodboardDocument(await getTransport().saveBoard(doc));
      await get().fetchBoards();
      set({
        activeBoard: saved,
        historyPast: [],
        historyFuture: [],
        selectedNodeIds: [],
        swappingNodeId: null,
        activeBoardAgentTrace: [],
        activeBoardLastSummary: null,
        openBoardFailedId: null,
      });
      useCoordinatorStore.getState().setActiveMoodboardId(saved.id);
      useCoordinatorStore.getState().pushToast({
        message: `已创建情绪板「${saved.title}」`,
        tone: 'success',
      });
      return saved;
    } catch (err) {
      reportBoardError('创建情绪板失败', err);
      throw err;
    }
  },

  async renameBoard(id, title, subtitle) {
    ensureLifecycleFlushHooks();
    await flushPendingBoardSaves();
    const trimmedTitle = title.trim();
    const trimmedSubtitle = subtitle !== undefined ? subtitle.trim() : undefined;
    const active = get().activeBoard;
    if (active && active.id === id) {
      const nextTitle = trimmedTitle || active.title || '未命名情绪板';
      const nextSubtitle = trimmedSubtitle !== undefined ? trimmedSubtitle : active.subtitle;
      if (nextTitle === active.title && nextSubtitle === active.subtitle) return;
      get().mutateActiveBoard(
        (doc) => ({ ...doc, title: nextTitle, subtitle: nextSubtitle }),
        { recordUndo: true, immediateSave: true },
      );
      await flushPendingBoardSaves();
      useCoordinatorStore.getState().pushToast({
        message: `已重命名情绪板「${nextTitle}」`,
        tone: 'success',
        durationMs: 2200,
      });
      return;
    }
    try {
      const raw = await getTransport().fetchBoard(id);
      if (!raw) {
        reportBoardError('重命名情绪板失败', new Error('未找到该情绪板'));
        return;
      }
      const doc = normalizeMoodboardDocument(raw);
      const nextTitle = trimmedTitle || doc.title || '未命名情绪板';
      const nextSubtitle = trimmedSubtitle !== undefined ? trimmedSubtitle : doc.subtitle;
      if (nextTitle === doc.title && nextSubtitle === doc.subtitle) return;
      const updatedDoc: MoodboardDocument = {
        ...doc,
        title: nextTitle,
        subtitle: nextSubtitle,
        updatedAt: msToCocoaSeconds(Date.now()),
        updatedHLC: Date.now(),
      };
      const saved = normalizeMoodboardDocument(await getTransport().saveBoard(updatedDoc));
      set((s) => ({
        boards: upsertBoardSummary(s.boards, saved),
      }));
      await get().fetchBoards();
      useCoordinatorStore.getState().pushToast({
        message: `已重命名情绪板「${saved.title}」`,
        tone: 'success',
        durationMs: 2200,
      });
    } catch (err) {
      reportBoardError('重命名情绪板失败', err);
    }
  },

  async deleteBoard(id) {
    if (pendingSaveDoc?.id === id) {
      pendingSaveDoc = null;
      if (saveTimer !== null && typeof window !== 'undefined') {
        window.clearTimeout(saveTimer);
        saveTimer = null;
      }
    }
    if (latestViewportOverride?.boardId === id) {
      latestViewportOverride = null;
      viewportDirty = false;
      if (viewportSaveTimer !== null && typeof window !== 'undefined') {
        window.clearTimeout(viewportSaveTimer);
        viewportSaveTimer = null;
      }
    }
    if (get().activeBoard?.id === id || get().openBoardFailedId === id) {
      openBoardRequestSeq += 1;
    }
    try {
      await getTransport().deleteBoard(id);
      const boards = await get().fetchBoards();
      const coord = useCoordinatorStore.getState();
      if (get().activeBoard?.id === id) {
        set({
          activeBoard: null,
          historyPast: [],
          historyFuture: [],
          selectedNodeIds: [],
          swappingNodeId: null,
          activeBoardAgentTrace: [],
          activeBoardLastSummary: null,
        });
      }
      if (coord.activeMoodboardId === id) {
        coord.setActiveMoodboardId(boards[0]?.id ?? null);
      }
      if (coord.destination.type === 'moodboard' && coord.destination.id === id) {
        coord.setDestination({ type: 'moodboardsHome' });
      }
      coord.pushToast({ message: '情绪板已删除', tone: 'info' });
    } catch (err) {
      reportBoardError('删除情绪板失败', err);
    }
  },

  async setBoardPinnedOffline(id, pinned) {
    await flushPendingBoardSaves();
    try {
      const updated = normalizeMoodboardDocument(
        await getTransport().setBoardPinnedOffline(id, pinned),
      );
      await get().fetchBoards();
      if (get().activeBoard?.id === id) {
        set({ activeBoard: updated });
      }
      useCoordinatorStore.getState().pushToast({
        message: pinned ? '整板素材将始终保留在本地' : '已取消整板始终保留在本地',
        tone: 'info',
      });
    } catch (err) {
      reportBoardError('更新离线保留状态失败', err);
    }
  },

  async addAssetsToBoard(boardId, assetIds) {
    if (assetIds.length === 0) return;
    await flushPendingBoardSaves();
    try {
      const raw = await getTransport().fetchBoard(boardId);
      if (!raw) return;
      const doc = normalizeMoodboardDocument(raw);
      const resolvedAssets = resolveAssetsMap();
      const now = msToCocoaSeconds(Date.now());
      const nextNodes: BoardNode[] = [...doc.nodes];
      const maxOrder = nextNodes.reduce((m, n) => Math.max(m, n.editorialOrder), -1);
      const maxZ = nextNodes.reduce((m, n) => Math.max(m, n.zIndex), 0);
      const baseCenter = resolveBoardCenter(doc);

      assetIds.forEach((assetId, idx) => {
        const asset = resolvedAssets.get(assetId) ?? null;
        const ratio =
          asset && asset.pixelWidth > 0 && asset.pixelHeight > 0
            ? Math.max(0.65, Math.min(1.85, asset.pixelWidth / asset.pixelHeight))
            : 1.25;
        const width = 240;
        const height = Math.round(width / ratio);
        const origin = findNonOverlappingOrigin(nextNodes, baseCenter, width, height);
        nextNodes.push({
          id: makeUuid(),
          kind: {
            assetRef: {
              assetID: assetId,
              crop: null,
              weight: 1,
              autoplayLoop: asset
                ? asset.mediaKind === 'animatedImage' || asset.mediaKind === 'video'
                : true,
            },
          },
          frame: { x: origin.x, y: origin.y, width, height },
          zIndex: maxZ + idx + 1,
          rotationDegrees: 0,
          flipHorizontal: false,
          flipVertical: false,
          isLocked: false,
          editorialOrder: maxOrder + idx + 1,
          updatedAt: now,
        });
      });

      const updatedDoc = applySyncedPaletteToDoc(
        {
          ...doc,
          nodes: nextNodes,
          updatedAt: now,
          updatedHLC: Date.now(),
        },
        resolvedAssets,
      );
      const saved = normalizeMoodboardDocument(await getTransport().saveBoard(updatedDoc));
      set((s) => ({
        boards: upsertBoardSummary(s.boards, saved),
        ...(s.activeBoard?.id === saved.id ? { activeBoard: saved } : {}),
      }));
      await get().fetchBoards();
      useCoordinatorStore.getState().pushToast({
        message: `已添加 ${assetIds.length} 项到情绪板「${saved.title}」`,
        tone: 'success',
      });
    } catch (err) {
      reportBoardError('添加到情绪板失败', err);
    }
  },

  setSelectedNodeIds(ids) {
    set({ selectedNodeIds: Array.from(new Set(ids)) });
  },

  setSwappingNodeId(nodeId) {
    set({ swappingNodeId: nodeId });
  },

  setBoardClipboard(assetIds, isCut) {
    set({ clipboardAssetIds: Array.from(new Set(assetIds)), clipboardIsCut: isCut });
  },

  pushAgentStep(step) {
    set((s) => {
      const mergeStep = (list: MoodboardAgentStep[]) => {
        const byId = list.findIndex((x) => x.id === step.id);
        if (byId >= 0) {
          const copy = [...list];
          copy[byId] = step;
          return copy;
        }
        return [...list, step];
      };
      return {
        agentTrace: mergeStep(s.agentTrace),
        activeBoardAgentTrace: s.isRefiningActiveBoard
          ? mergeStep(s.activeBoardAgentTrace)
          : s.activeBoardAgentTrace,
      };
    });
  },

  async curateMoodboard(request) {
    ensureLifecycleFlushHooks();
    await flushPendingBoardSaves();
    openBoardRequestSeq += 1;
    set({ curating: true, agentTrace: [], lastError: null });
    try {
      const proposal = await getTransport().curateMoodboard(request);
      const normalizedDraft = normalizeMoodboardDocument(proposal.draftDocument);
      const saved = normalizeMoodboardDocument(await getTransport().saveBoard(normalizedDraft));
      latestViewportOverride = null;
      viewportDirty = false;
      await get().fetchBoards();
      set({
        curating: false,
        lastProposal: { ...proposal, draftDocument: saved },
        activeBoard: saved,
        candidatePool: Array.isArray(proposal.candidatePool) ? proposal.candidatePool : [],
        agentTrace: Array.isArray(proposal.agentTrace) ? proposal.agentTrace : [],
        activeBoardLastSummary: proposal.curatedSummary || null,
        historyPast: [],
        historyFuture: [],
        selectedNodeIds: [],
        swappingNodeId: null,
      });
      useCoordinatorStore.getState().setActiveMoodboardId(saved.id);
      useCoordinatorStore.getState().setDestination({ type: 'moodboard', id: saved.id });
      useCoordinatorStore.getState().pushToast({
        message: proposal.curatedSummary || `已创建情绪板「${saved.title}」`,
        tone: 'success',
      });
      return { ...proposal, draftDocument: saved };
    } catch (err) {
      const msg = err instanceof Error ? err.message : String(err);
      set({ curating: false, lastError: msg });
      useCoordinatorStore.getState().pushToast({
        message: `智能策展失败：${msg}`,
        tone: 'error',
      });
      throw err;
    }
  },

  async refineActiveBoard(instruction, assetsById) {
    const currentBoard = get().activeBoard;
    const trimmed = instruction.trim();
    if (!currentBoard || !trimmed || get().isRefiningActiveBoard) return null;

    set({
      isRefiningActiveBoard: true,
      curating: true,
      activeBoardAgentTrace: [],
      lastError: null,
    });

    const lockedAssetIDs = currentBoard.nodes
      .filter((n) => n.isLocked && 'assetRef' in n.kind)
      .map((n) => ('assetRef' in n.kind ? n.kind.assetRef.assetID : ''))
      .filter(Boolean);

    const refAssetCount = currentBoard.nodes.filter((n) => 'assetRef' in n.kind).length;
    const layoutStyle = isAutoEditorialMode(currentBoard.mode)
      ? currentBoard.mode.autoEditorial._0.style
      : 'magazine';

    const request: MoodboardCurationRequest = {
      prompt: currentBoard.subtitle
        ? `${currentBoard.title}：${currentBoard.subtitle}`
        : currentBoard.title,
      seedAssetIDs: [],
      scopeFolderIDs: [],
      requiredTags: [],
      targetPalette: currentBoard.extractedPalette,
      colorTolerance: 28,
      preferredCount: Math.max(8, Math.min(20, Math.max(12, refAssetCount + 4))),
      candidateCount: 28,
      layoutStyle,
      useFreeformLayout: !isAutoEditorialMode(currentBoard.mode),
      includeCuratorNotes: true,
      excludedAssetIDs: [],
      lockedAssetIDs,
      existingBoard: currentBoard,
      refinementInstruction: trimmed,
      autoFocusDetailCrop: false,
    };

    try {
      const proposal = await getTransport().curateMoodboard(request);
      const nextDraft = normalizeMoodboardDocument({
        ...proposal.draftDocument,
        id: currentBoard.id,
        pinnedOffline: currentBoard.pinnedOffline,
      });

      const trace = Array.isArray(proposal.agentTrace) ? proposal.agentTrace : [];
      const pool = Array.isArray(proposal.candidatePool) ? proposal.candidatePool : [];

      set({
        isRefiningActiveBoard: false,
        curating: false,
        activeBoardAgentTrace: trace,
        activeBoardLastSummary: proposal.curatedSummary || null,
        candidatePool: pool,
        lastProposal: proposal,
      });

      if (nextDraft.nodes.length > 0) {
        get().mutateActiveBoard(() => nextDraft, { recordUndo: true, immediateSave: true });
        if (assetsById && nextDraft.extractedPalette.length === 0) {
          get().syncBoardPalette(assetsById);
        }
        useCoordinatorStore.getState().pushToast({
          message: `已完成策展微调（${proposal.primaryMatches.length} 张），可按 Ctrl+Z 撤销`,
          tone: 'success',
        });
      } else {
        useCoordinatorStore.getState().pushToast({
          message: '未找到符合该条件的素材，已保持当前画布',
          tone: 'info',
        });
      }
      return proposal;
    } catch (err) {
      const msg = err instanceof Error ? err.message : String(err);
      set({ isRefiningActiveBoard: false, curating: false, lastError: msg });
      useCoordinatorStore.getState().pushToast({
        message: `策展调整未完成：${msg}`,
        tone: 'error',
      });
      return null;
    }
  },

  mutateActiveBoard(updater, opts = {}) {
    ensureLifecycleFlushHooks();
    const current = get().activeBoard;
    if (!current) return;
    if (viewportSaveTimer !== null && typeof window !== 'undefined') {
      window.clearTimeout(viewportSaveTimer);
      viewportSaveTimer = null;
    }
    const recordUndo = opts.recordUndo ?? true;
    const rawUpdated = updater(current);
    const updated = normalizeMoodboardDocument(rawUpdated);

    let viewportCenter = updated.viewportCenter;
    let viewportZoom = updated.viewportZoom;
    if (
      latestViewportOverride &&
      latestViewportOverride.boardId === updated.id &&
      updated.viewportCenter.x === current.viewportCenter.x &&
      updated.viewportCenter.y === current.viewportCenter.y &&
      updated.viewportZoom === current.viewportZoom
    ) {
      viewportCenter = latestViewportOverride.center;
      viewportZoom = latestViewportOverride.zoom;
    } else {
      latestViewportOverride = {
        boardId: updated.id,
        center: viewportCenter,
        zoom: viewportZoom,
      };
    }

    const stamped: MoodboardDocument = {
      ...updated,
      viewportCenter,
      viewportZoom,
      updatedAt: msToCocoaSeconds(Date.now()),
      updatedHLC: Date.now(),
    };

    set((s) => ({
      activeBoard: stamped,
      boards: upsertBoardSummary(s.boards, stamped),
      historyPast: recordUndo
        ? [...s.historyPast.slice(-(MAX_UNDO_HISTORY - 1)), current]
        : s.historyPast,
      historyFuture: recordUndo ? [] : s.historyFuture,
    }));

    if (opts.immediateSave) {
      void persistBoardImmediately(stamped, true);
    } else {
      schedulePersistBoard(stamped);
    }
  },

  persistViewportQuietly(center, zoom) {
    ensureLifecycleFlushHooks();
    const current = get().activeBoard;
    if (!current) return;
    const safeCenter: BoardPoint = {
      x: finiteOr(center.x, current.viewportCenter.x),
      y: finiteOr(center.y, current.viewportCenter.y),
    };
    const safeZoom = Math.max(0.2, Math.min(3.0, finiteOr(zoom, current.viewportZoom)));
    const boardId = current.id;
    latestViewportOverride = { boardId, center: safeCenter, zoom: safeZoom };
    viewportDirty = true;

    if (typeof window === 'undefined') return;
    if (viewportSaveTimer !== null) window.clearTimeout(viewportSaveTimer);
    viewportSaveTimer = window.setTimeout(() => {
      viewportSaveTimer = null;
      if (!viewportDirty) return;
      if (pendingSaveDoc && pendingSaveDoc.id === boardId) {
        pendingSaveDoc = {
          ...pendingSaveDoc,
          viewportCenter: safeCenter,
          viewportZoom: safeZoom,
        };
        return;
      }
      const latest = get().activeBoard;
      if (!latest || latest.id !== boardId) return;
      viewportDirty = false;
      const snapshot: MoodboardDocument = {
        ...latest,
        viewportCenter: safeCenter,
        viewportZoom: safeZoom,
      };
      void enqueueBoardSave(snapshot, false, true);
    }, 480);
  },

  undo() {
    const { historyPast, activeBoard, historyFuture, selectedNodeIds, swappingNodeId } = get();
    if (!activeBoard || historyPast.length === 0) return;
    const prevBase = historyPast[historyPast.length - 1];
    const preserveVp =
      latestViewportOverride && latestViewportOverride.boardId === prevBase.id
        ? {
            viewportCenter: latestViewportOverride.center,
            viewportZoom: latestViewportOverride.zoom,
          }
        : {};
    const prev: MoodboardDocument = {
      ...prevBase,
      ...preserveVp,
      updatedAt: msToCocoaSeconds(Date.now()),
      updatedHLC: Date.now(),
    };
    const validIds = new Set(prev.nodes.map((n) => n.id));
    set((s) => ({
      activeBoard: prev,
      boards: upsertBoardSummary(s.boards, prev),
      historyPast: historyPast.slice(0, -1),
      historyFuture: [activeBoard, ...historyFuture].slice(0, MAX_UNDO_HISTORY),
      selectedNodeIds: selectedNodeIds.filter((id) => validIds.has(id)),
      swappingNodeId: swappingNodeId && validIds.has(swappingNodeId) ? swappingNodeId : null,
    }));
    void persistBoardImmediately(prev, true);
  },

  redo() {
    const { historyPast, activeBoard, historyFuture, selectedNodeIds, swappingNodeId } = get();
    if (!activeBoard || historyFuture.length === 0) return;
    const nextBase = historyFuture[0];
    const preserveVp =
      latestViewportOverride && latestViewportOverride.boardId === nextBase.id
        ? {
            viewportCenter: latestViewportOverride.center,
            viewportZoom: latestViewportOverride.zoom,
          }
        : {};
    const next: MoodboardDocument = {
      ...nextBase,
      ...preserveVp,
      updatedAt: msToCocoaSeconds(Date.now()),
      updatedHLC: Date.now(),
    };
    const validIds = new Set(next.nodes.map((n) => n.id));
    set((s) => ({
      activeBoard: next,
      boards: upsertBoardSummary(s.boards, next),
      historyPast: [...historyPast, activeBoard].slice(-MAX_UNDO_HISTORY),
      historyFuture: historyFuture.slice(1),
      selectedNodeIds: selectedNodeIds.filter((id) => validIds.has(id)),
      swappingNodeId: swappingNodeId && validIds.has(swappingNodeId) ? swappingNodeId : null,
    }));
    void persistBoardImmediately(next, true);
  },

  swapNodeAsset(nodeId, replacementAssetId, assetsById) {
    const prevAssetId = (() => {
      const node = get().activeBoard?.nodes.find((n) => n.id === nodeId);
      return node && 'assetRef' in node.kind ? node.kind.assetRef.assetID : null;
    })();
    const resolvedAssets = resolveAssetsMap(assetsById);

    get().mutateActiveBoard(
      (doc) => {
        const nextDoc: MoodboardDocument = {
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
        };
        return applySyncedPaletteToDoc(nextDoc, resolvedAssets);
      },
      { recordUndo: true, immediateSave: true },
    );

    set({ swappingNodeId: null });

    const replacementTitle = resolvedAssets.get(replacementAssetId)?.title;
    useCoordinatorStore.getState().pushToast({
      message: replacementTitle
        ? `已原地替换为「${replacementTitle}」`
        : '已原地替换素材',
      tone: 'success',
      durationMs: 2200,
    });
  },

  syncBoardPalette(assetsById) {
    const current = get().activeBoard;
    if (!current) return;
    const resolvedAssets = resolveAssetsMap(assetsById);

    get().mutateActiveBoard(
      (doc) => applySyncedPaletteToDoc(doc, resolvedAssets),
      { recordUndo: false, immediateSave: true },
    );
  },

  addAssetNodeAt(assetId, point, asset, assetsById) {
    const now = msToCocoaSeconds(Date.now());
    const resolvedAssets = resolveAssetsMap(assetsById, asset);
    const effectiveAsset = asset ?? resolvedAssets.get(assetId) ?? null;
    const ratio =
      effectiveAsset && effectiveAsset.pixelWidth > 0 && effectiveAsset.pixelHeight > 0
        ? Math.max(0.65, Math.min(1.85, effectiveAsset.pixelWidth / effectiveAsset.pixelHeight))
        : 1.25;
    const width = 240;
    const height = Math.round(width / ratio);

    get().mutateActiveBoard(
      (doc) => {
        const maxOrder = doc.nodes.reduce((m, n) => Math.max(m, n.editorialOrder), -1);
        const maxZ = doc.nodes.reduce((m, n) => Math.max(m, n.zIndex), 0);
        const center = point ?? resolveBoardCenter(doc);
        const origin = findNonOverlappingOrigin(doc.nodes, center, width, height);
        const node: BoardNode = {
          id: makeUuid(),
          kind: {
            assetRef: {
              assetID: assetId,
              crop: null,
              weight: 1,
              autoplayLoop: effectiveAsset
                ? effectiveAsset.mediaKind === 'animatedImage' ||
                  effectiveAsset.mediaKind === 'video'
                : true,
            },
          },
          frame: { x: origin.x, y: origin.y, width, height },
          zIndex: maxZ + 1,
          rotationDegrees: 0,
          flipHorizontal: false,
          flipVertical: false,
          isLocked: false,
          editorialOrder: maxOrder + 1,
          updatedAt: now,
        };
        return applySyncedPaletteToDoc(
          {
            ...doc,
            nodes: [...doc.nodes, node],
          },
          resolvedAssets,
        );
      },
      { recordUndo: true, immediateSave: true },
    );
  },

  addNoteNode(style = 'warm', point) {
    const now = msToCocoaSeconds(Date.now());
    const id = makeUuid();
    get().mutateActiveBoard(
      (doc) => {
        const maxOrder = doc.nodes.reduce((m, n) => Math.max(m, n.editorialOrder), -1);
        const maxZ = doc.nodes.reduce((m, n) => Math.max(m, n.zIndex), 0);
        const center = point ?? resolveBoardCenter(doc);
        const origin = findNonOverlappingOrigin(doc.nodes, center, 260, 180);
        const node: BoardNode = {
          id,
          kind: {
            note: {
              title: '灵感便签',
              text: '记录构图、材质、光影或排版思路…',
              style,
              fontSize: 14,
            },
          },
          frame: { x: origin.x, y: origin.y, width: 260, height: 180 },
          zIndex: maxZ + 1,
          rotationDegrees: 0,
          flipHorizontal: false,
          flipVertical: false,
          isLocked: false,
          editorialOrder: maxOrder + 1,
          updatedAt: now,
        };
        return { ...doc, nodes: [...doc.nodes, node] };
      },
      { recordUndo: true, immediateSave: true },
    );
    set({ selectedNodeIds: [id] });
  },

  addGroupFrameNode(tint = 'sand', point) {
    const now = msToCocoaSeconds(Date.now());
    const id = makeUuid();
    get().mutateActiveBoard(
      (doc) => {
        const maxOrder = doc.nodes.reduce((m, n) => Math.max(m, n.editorialOrder), -1);
        const minZ = doc.nodes.reduce((m, n) => Math.min(m, n.zIndex), 0);
        const center = point ?? resolveBoardCenter(doc);
        const origin = findNonOverlappingOrigin(doc.nodes, center, 440, 320);
        const node: BoardNode = {
          id,
          kind: { groupFrame: { title: '构图参考区', tint } },
          frame: { x: origin.x, y: origin.y, width: 440, height: 320 },
          zIndex: Math.min(-10, minZ - 1),
          rotationDegrees: 0,
          flipHorizontal: false,
          flipVertical: false,
          isLocked: false,
          editorialOrder: maxOrder + 1,
          updatedAt: now,
        };
        return { ...doc, nodes: [node, ...doc.nodes] };
      },
      { recordUndo: true, immediateSave: true },
    );
    set({ selectedNodeIds: [id] });
  },

  addPaletteStripNode(point) {
    const now = msToCocoaSeconds(Date.now());
    const id = makeUuid();
    get().mutateActiveBoard(
      (doc) => {
        const maxOrder = doc.nodes.reduce((m, n) => Math.max(m, n.editorialOrder), -1);
        const maxZ = doc.nodes.reduce((m, n) => Math.max(m, n.zIndex), 0);
        const fallbackPalette = [
          { hex: '#C8B8A6', l: 75, a: 4, b: 12, proportion: 0.25 },
          { hex: '#5C6B73', l: 44, a: -4, b: -6, proportion: 0.25 },
          { hex: '#253237', l: 20, a: -4, b: -5, proportion: 0.25 },
          { hex: '#E0D6CC', l: 86, a: 2, b: 6, proportion: 0.25 },
        ];
        const colors = doc.extractedPalette.length > 0 ? doc.extractedPalette : fallbackPalette;
        const center = point ?? resolveBoardCenter(doc);
        const origin = findNonOverlappingOrigin(doc.nodes, center, 420, 84);
        const node: BoardNode = {
          id,
          kind: {
            paletteStrip: {
              colors,
              autoSyncWithBoard: true,
            },
          },
          frame: { x: origin.x, y: origin.y, width: 420, height: 84 },
          zIndex: maxZ + 1,
          rotationDegrees: 0,
          flipHorizontal: false,
          flipVertical: false,
          isLocked: false,
          editorialOrder: maxOrder + 1,
          updatedAt: now,
        };
        return { ...doc, nodes: [...doc.nodes, node] };
      },
      { recordUndo: true, immediateSave: true },
    );
    set({ selectedNodeIds: [id] });
  },

  addConnector(conn) {
    const now = msToCocoaSeconds(Date.now());
    get().mutateActiveBoard(
      (doc) => ({
        ...doc,
        connectors: [...doc.connectors, { ...conn, id: makeUuid(), updatedAt: now }],
      }),
      { recordUndo: true, immediateSave: true },
    );
  },

  updateConnectorLabel(connectorId, label) {
    const trimmed = label?.trim() ?? '';
    get().mutateActiveBoard(
      (doc) => ({
        ...doc,
        connectors: doc.connectors.map((c) =>
          c.id === connectorId
            ? { ...c, label: trimmed ? trimmed : null, updatedAt: msToCocoaSeconds(Date.now()) }
            : c,
        ),
      }),
      { recordUndo: true, immediateSave: true },
    );
  },

  removeConnector(connectorId) {
    get().mutateActiveBoard(
      (doc) => ({
        ...doc,
        connectors: doc.connectors.filter((c) => c.id !== connectorId),
      }),
      { recordUndo: true, immediateSave: true },
    );
  },

  addInkStroke(stroke) {
    const now = msToCocoaSeconds(Date.now());
    get().mutateActiveBoard(
      (doc) => ({
        ...doc,
        inkStrokes: [
          ...doc.inkStrokes,
          {
            ...stroke,
            id: makeUuid(),
            zIndex: stroke.zIndex ?? 1000 + doc.inkStrokes.length,
            createdAt: now,
          },
        ],
      }),
      { recordUndo: true, immediateSave: true },
    );
  },

  eraseInkAndConnectors(strokeIds, connectorIds) {
    if (strokeIds.length === 0 && connectorIds.length === 0) return;
    const dropStrokes = new Set(strokeIds);
    const dropConns = new Set(connectorIds);
    get().mutateActiveBoard(
      (doc) => ({
        ...doc,
        inkStrokes: doc.inkStrokes.filter((s) => !dropStrokes.has(s.id)),
        connectors: doc.connectors.filter((c) => !dropConns.has(c.id)),
      }),
      { recordUndo: true, immediateSave: true },
    );
  },

  removeNodes(nodeIds, opts = {}) {
    const current = get().activeBoard;
    if (!current || nodeIds.length === 0) return 0;
    const drop = new Set(nodeIds);
    const removedCount = current.nodes.filter((n) => drop.has(n.id)).length;
    if (removedCount === 0) return 0;

    const resolvedAssets = resolveAssetsMap(opts.assetsById);
    get().mutateActiveBoard(
      (doc) => {
        const filteredDoc: MoodboardDocument = {
          ...doc,
          nodes: doc.nodes.filter((n) => !drop.has(n.id)),
          connectors: doc.connectors.filter(
            (c) => !drop.has(c.fromNodeID) && !drop.has(c.toNodeID),
          ),
        };
        return applySyncedPaletteToDoc(filteredDoc, resolvedAssets);
      },
      { recordUndo: true, immediateSave: true },
    );
    set((s) => ({
      selectedNodeIds: s.selectedNodeIds.filter((id) => !drop.has(id)),
      swappingNodeId: s.swappingNodeId && drop.has(s.swappingNodeId) ? null : s.swappingNodeId,
    }));

    if (opts.showUndoToast) {
      useCoordinatorStore.getState().pushToast({
        message: `已从情绪板移除 ${removedCount} 项`,
        tone: 'info',
        actionLabel: '撤销',
        durationMs: 4500,
        onAction: () => useMoodboardStore.getState().undo(),
      });
    }
    return removedCount;
  },

  switchBoardMode(nextMode, containerWidth, assetsById, autoConfig) {
    const current = get().activeBoard;
    if (!current) return;
    if (nextMode === 'freeform' && !isAutoEditorialMode(current.mode)) {
      return;
    }
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
