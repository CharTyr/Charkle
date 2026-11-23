import { create } from 'zustand';
import {
  clearVisualFilters,
  createDefaultAssetBatchPatch,
  createDefaultFilterCriteria,
} from '@charkle/shared';
import type {
  AssetBatchPatch,
  AssetRecord,
  CaptureInput,
  FilterCriteria,
  FolderRecord,
  FolderSuggestion,
  InboxTriageRecommendation,
  SaveSmartFolderRequest,
  SemanticSearchReport,
  SidebarDestination,
  SmartFolderRecord,
  TagCount,
  UUID,
} from '@charkle/shared';
import { apiClient } from '../api/client';
import { useCoordinatorStore } from './coordinatorStore';
import { useMoodboardStore } from './moodboardStore';
import { useSyncAIStore } from './syncAIStore';

export interface LibraryCounts {
  inbox: number;
  total: number;
  untagged: number;
  trash: number;
}

interface LibraryState {
  assets: AssetRecord[];
  totalAssets: number;
  assetsByID: Record<UUID, AssetRecord>;
  recentActivityAssets: AssetRecord[];

  folders: FolderRecord[];
  smartFolders: SmartFolderRecord[];
  tags: TagCount[];
  counts: LibraryCounts;

  criteria: FilterCriteria;
  showVisualFilterBar: boolean;

  semanticSearchEnabled: boolean;
  semanticReport: SemanticSearchReport | null;
  isSemanticSearching: boolean;

  selectedAssetIDs: Set<UUID>;
  lastSelectedAssetID: UUID | null;
  cutAssetIDs: Set<UUID>;

  loading: boolean;
  bootstrapped: boolean;
  cacheBustVersion: number;

  inboxSuggestion: FolderSuggestion | null;
  triageRecommendations: InboxTriageRecommendation[];
  isTriaging: boolean;
  triageModalOpen: boolean;

  bootstrap: () => Promise<void>;
  refreshSidebarMetadata: () => Promise<void>;
  loadAssets: (destination?: SidebarDestination) => Promise<void>;
  loadRecentActivity: (limit?: number) => Promise<void>;

  setCriteria: (patch: Partial<FilterCriteria>, reload?: boolean) => void;
  resetVisualFilters: () => void;
  setShowVisualFilterBar: (show: boolean) => void;

  setSemanticSearchEnabled: (enabled: boolean) => void;
  runSemanticSearch: (query?: string) => Promise<void>;
  clearSemanticSearch: () => void;

  selectAsset: (id: UUID, mode?: 'replace' | 'toggle' | 'range') => void;
  selectAssetIDs: (ids: Iterable<UUID>) => void;
  selectAllVisible: () => void;
  clearSelection: () => void;
  setCutAssetIDs: (ids: Iterable<UUID>) => void;

  ingestInputs: (
    inputs: CaptureInput[],
    opts?: { targetFolderID?: UUID | null; targetBoardID?: UUID | null },
  ) => Promise<AssetRecord[]>;
  uploadFiles: (
    files: File[],
    opts?: { targetFolderID?: UUID | null; targetBoardID?: UUID | null },
  ) => Promise<AssetRecord[]>;

  batchPatch: (patch: AssetBatchPatch) => Promise<AssetRecord[]>;
  trashAssets: (ids: UUID[]) => Promise<void>;
  restoreAssets: (ids: UUID[]) => Promise<void>;
  permanentlyDeleteAssets: (ids: UUID[]) => Promise<void>;
  emptyTrash: () => Promise<void>;
  restoreAllTrash: () => Promise<void>;
  markOpened: (id: UUID) => Promise<void>;
  refreshRichAsset: (id: UUID) => Promise<AssetRecord>;
  extractSocialMedia: (id: UUID, attachmentIndex?: number | null) => Promise<AssetRecord[]>;

  createFolder: (name: string, parentID?: UUID | null) => Promise<FolderRecord>;
  renameFolder: (id: UUID, name: string) => Promise<FolderRecord>;
  moveFolder: (id: UUID, newParentID: UUID | null, insertAtIndex?: number | null) => Promise<void>;
  updateFolderAppearance: (id: UUID, colorHex: string | null, customSymbol: string | null) => Promise<void>;
  deleteFolder: (id: UUID, trashContents?: boolean) => Promise<void>;
  pinFolderOffline: (id: UUID, pinned: boolean) => Promise<void>;

  saveSmartFolder: (req: SaveSmartFolderRequest) => Promise<void>;
  deleteSmartFolder: (id: UUID) => Promise<void>;

  loadInboxSuggestion: (assetID: UUID) => Promise<void>;
  runBatchInboxTriage: (assetIDs?: UUID[], maxCount?: number) => Promise<void>;
  setTriageModalOpen: (open: boolean) => void;

  seedDemoLibrary: () => Promise<boolean>;
  upsertAssets: (incoming: AssetRecord[]) => void;
  bumpCacheBust: () => void;
}

function buildEffectiveQuery(
  destination: SidebarDestination,
  baseCriteria: FilterCriteria,
): { criteria: Partial<FilterCriteria>; smartFolderID?: UUID | null } {
  const c: FilterCriteria = {
    ...baseCriteria,
    folderID: null,
    onlyInbox: false,
    onlyUntagged: false,
    onlyRecentDays: null,
    includeTrashed: false,
    onlyTrashed: false,
  };

  switch (destination.type) {
    case 'allItems':
      return { criteria: c };
    case 'inbox':
      c.onlyInbox = true;
      return { criteria: c };
    case 'untagged':
      c.onlyUntagged = true;
      return { criteria: c };
    case 'recent':
      c.onlyRecentDays = 7;
      return { criteria: c };
    case 'trash':
      c.includeTrashed = true;
      c.onlyTrashed = true;
      return { criteria: c };
    case 'folder':
      c.folderID = destination.id;
      return { criteria: c };
    case 'tag':
      c.tags = Array.from(new Set([...c.tags, destination.name]));
      return { criteria: c };
    case 'smartFolder':
      return { criteria: c, smartFolderID: destination.id };
    case 'moodboardsHome':
    case 'moodboard':
      return { criteria: c };
  }
}

function indexByID(prev: Record<UUID, AssetRecord>, list: AssetRecord[]): Record<UUID, AssetRecord> {
  const next = { ...prev };
  for (const item of list) {
    next[item.id] = item;
  }
  return next;
}

export const useLibraryStore = create<LibraryState>((set, get) => ({
  assets: [],
  totalAssets: 0,
  assetsByID: {},
  recentActivityAssets: [],

  folders: [],
  smartFolders: [],
  tags: [],
  counts: { inbox: 0, total: 0, untagged: 0, trash: 0 },

  criteria: createDefaultFilterCriteria(),
  showVisualFilterBar: false,

  semanticSearchEnabled: false,
  semanticReport: null,
  isSemanticSearching: false,

  selectedAssetIDs: new Set<UUID>(),
  lastSelectedAssetID: null,
  cutAssetIDs: new Set<UUID>(),

  loading: false,
  bootstrapped: false,
  cacheBustVersion: 1,

  inboxSuggestion: null,
  triageRecommendations: [],
  isTriaging: false,
  triageModalOpen: false,

  bootstrap: async () => {
    set({ loading: true });
    try {
      const boot = await apiClient.getLibraryBootstrap();
      set({
        folders: boot.folders,
        smartFolders: boot.smartFolders,
        tags: boot.tags,
        counts: {
          inbox: boot.inboxCount,
          total: boot.totalAssetCount,
          untagged: boot.untaggedCount,
          trash: boot.trashCount,
        },
        bootstrapped: true,
      });

      useMoodboardStore.getState().setBoards(boot.boards);
      useSyncAIStore.getState().setSyncStatus(boot.syncStatus);
      useSyncAIStore.getState().setAIConfigSnapshot(boot.aiConfig);

      // Default activeBoardID to the first board if none is stored yet
      const coord = useCoordinatorStore.getState();
      if (!coord.activeBoardID && boot.boards.length > 0) {
        coord.setActiveBoardID(boot.boards[0].id);
      }

      await Promise.all([get().loadAssets(), get().loadRecentActivity(24)]);
    } finally {
      set({ loading: false });
    }
  },

  refreshSidebarMetadata: async () => {
    try {
      const boot = await apiClient.getLibraryBootstrap();
      set({
        folders: boot.folders,
        smartFolders: boot.smartFolders,
        tags: boot.tags,
        counts: {
          inbox: boot.inboxCount,
          total: boot.totalAssetCount,
          untagged: boot.untaggedCount,
          trash: boot.trashCount,
        },
      });
      useMoodboardStore.getState().setBoards(boot.boards);
      useSyncAIStore.getState().setSyncStatus(boot.syncStatus);
    } catch {
      // Non-fatal background refresh error
    }
  },

  loadAssets: async (destinationOverride) => {
    const destination = destinationOverride ?? useCoordinatorStore.getState().destination;
    if (destination.type === 'moodboardsHome' || destination.type === 'moodboard') {
      return;
    }
    const { criteria, semanticReport } = get();
    if (semanticReport) {
      set({
        assets: semanticReport.hits.map((h) => h.asset),
        totalAssets: semanticReport.hits.length,
        assetsByID: indexByID(get().assetsByID, semanticReport.hits.map((h) => h.asset)),
      });
      return;
    }

    set({ loading: true });
    try {
      const query = buildEffectiveQuery(destination, criteria);
      const res = await apiClient.queryAssets({
        criteria: query.criteria,
        smartFolderID: query.smartFolderID,
        limit: 1000,
      });
      set((s) => ({
        assets: res.assets,
        totalAssets: res.total,
        assetsByID: indexByID(s.assetsByID, res.assets),
        loading: false,
      }));
    } catch {
      set({ loading: false });
    }
  },

  loadRecentActivity: async (limit = 24) => {
    try {
      const res = await apiClient.getRecentActivityAssets(limit);
      set((s) => ({
        recentActivityAssets: res.assets,
        assetsByID: indexByID(s.assetsByID, res.assets),
      }));
    } catch {
      // Ignore if endpoint temporarily unavailable
    }
  },

  setCriteria: (patch, reload = true) => {
    set((s) => ({
      criteria: { ...s.criteria, ...patch },
      semanticReport: patch.searchQuery !== undefined ? null : s.semanticReport,
    }));
    if (reload) {
      void get().loadAssets();
    }
  },

  resetVisualFilters: () => {
    set((s) => ({
      criteria: clearVisualFilters(s.criteria),
      semanticReport: null,
    }));
    void get().loadAssets();
  },

  setShowVisualFilterBar: (show) => set({ showVisualFilterBar: show }),

  setSemanticSearchEnabled: (enabled) => {
    set({ semanticSearchEnabled: enabled });
    if (!enabled && get().semanticReport) {
      get().clearSemanticSearch();
    }
  },

  runSemanticSearch: async (queryOverride) => {
    const query = (queryOverride ?? get().criteria.searchQuery).trim();
    if (!query) {
      get().clearSemanticSearch();
      return;
    }
    set({ isSemanticSearching: true });
    try {
      const destination = useCoordinatorStore.getState().destination;
      const effective = buildEffectiveQuery(destination, get().criteria);
      const res = await apiClient.semanticSearch({
        query,
        criteria: effective.criteria,
        limit: 80,
      });
      const hitAssets = res.report.hits.map((h) => h.asset);
      set((s) => ({
        semanticReport: res.report,
        assets: hitAssets,
        totalAssets: hitAssets.length,
        assetsByID: indexByID(s.assetsByID, hitAssets),
        isSemanticSearching: false,
      }));
    } catch (err) {
      set({ isSemanticSearching: false });
      useCoordinatorStore.getState().pushToast({
        tone: 'error',
        message: err instanceof Error ? err.message : '混合语义检索失败',
      });
    }
  },

  clearSemanticSearch: () => {
    set({ semanticReport: null });
    void get().loadAssets();
  },

  selectAsset: (id, mode = 'replace') => {
    const { assets, selectedAssetIDs, lastSelectedAssetID } = get();
    if (mode === 'replace') {
      set({ selectedAssetIDs: new Set([id]), lastSelectedAssetID: id });
      return;
    }
    if (mode === 'toggle') {
      const next = new Set(selectedAssetIDs);
      if (next.has(id)) {
        next.delete(id);
      } else {
        next.add(id);
      }
      set({ selectedAssetIDs: next, lastSelectedAssetID: id });
      return;
    }
    // Range selection
    const anchor = lastSelectedAssetID;
    if (!anchor) {
      set({ selectedAssetIDs: new Set([id]), lastSelectedAssetID: id });
      return;
    }
    const idxA = assets.findIndex((a) => a.id === anchor);
    const idxB = assets.findIndex((a) => a.id === id);
    if (idxA < 0 || idxB < 0) {
      set({ selectedAssetIDs: new Set([id]), lastSelectedAssetID: id });
      return;
    }
    const [start, end] = idxA < idxB ? [idxA, idxB] : [idxB, idxA];
    const next = new Set(selectedAssetIDs);
    for (let i = start; i <= end; i++) {
      next.add(assets[i].id);
    }
    set({ selectedAssetIDs: next, lastSelectedAssetID: id });
  },

  selectAssetIDs: (ids) => {
    const list = Array.from(ids);
    set({
      selectedAssetIDs: new Set(list),
      lastSelectedAssetID: list.length > 0 ? list[list.length - 1] : null,
    });
  },

  selectAllVisible: () => {
    const all = get().assets.map((a) => a.id);
    set({
      selectedAssetIDs: new Set(all),
      lastSelectedAssetID: all.length > 0 ? all[all.length - 1] : null,
    });
  },

  clearSelection: () => set({ selectedAssetIDs: new Set<UUID>(), lastSelectedAssetID: null }),

  setCutAssetIDs: (ids) => set({ cutAssetIDs: new Set(ids) }),

  ingestInputs: async (inputs, opts) => {
    const res = await apiClient.ingestAssets({
      inputs,
      targetFolderID: opts?.targetFolderID ?? null,
      targetBoardID: opts?.targetBoardID ?? null,
    });
    get().upsertAssets(res.assets);
    await Promise.all([get().refreshSidebarMetadata(), get().loadAssets(), get().loadRecentActivity()]);
    if (opts?.targetBoardID) {
      void useMoodboardStore.getState().openBoard(opts.targetBoardID);
    }
    return res.assets;
  },

  uploadFiles: async (files, opts) => {
    const res = await apiClient.uploadFiles(files, opts);
    get().upsertAssets(res.assets);
    await Promise.all([get().refreshSidebarMetadata(), get().loadAssets(), get().loadRecentActivity()]);
    if (opts?.targetBoardID) {
      void useMoodboardStore.getState().openBoard(opts.targetBoardID);
    }
    return res.assets;
  },

  batchPatch: async (patch) => {
    const res = await apiClient.batchPatchAssets(patch);
    get().upsertAssets(res.assets);
    await Promise.all([get().refreshSidebarMetadata(), get().loadAssets()]);
    return res.assets;
  },

  trashAssets: async (ids) => {
    if (ids.length === 0) return;
    await get().batchPatch(createDefaultAssetBatchPatch(ids, { isTrashed: true }));
    get().clearSelection();
    useCoordinatorStore.getState().pushToast({
      tone: 'info',
      message: `已将 ${ids.length} 项素材移入回收站`,
      actionLabel: '撤销',
      onAction: () => {
        void get().restoreAssets(ids);
      },
    });
  },

  restoreAssets: async (ids) => {
    if (ids.length === 0) return;
    await get().batchPatch(createDefaultAssetBatchPatch(ids, { isTrashed: false }));
    useCoordinatorStore.getState().pushToast({
      tone: 'success',
      message: `已恢复 ${ids.length} 项素材`,
    });
  },

  permanentlyDeleteAssets: async (ids) => {
    if (ids.length === 0) return;
    await apiClient.permanentlyDeleteAssets(ids);
    set((s) => {
      const removed = new Set(ids);
      const nextByID = { ...s.assetsByID };
      for (const id of ids) delete nextByID[id];
      return {
        assets: s.assets.filter((a) => !removed.has(a.id)),
        assetsByID: nextByID,
        selectedAssetIDs: new Set<UUID>(),
      };
    });
    await get().refreshSidebarMetadata();
  },

  emptyTrash: async () => {
    await apiClient.emptyTrash();
    set({ assets: [], totalAssets: 0, selectedAssetIDs: new Set<UUID>() });
    await get().refreshSidebarMetadata();
    useCoordinatorStore.getState().pushToast({ tone: 'success', message: '回收站已清空' });
  },

  restoreAllTrash: async () => {
    await apiClient.restoreAllTrash();
    await Promise.all([get().refreshSidebarMetadata(), get().loadAssets()]);
    useCoordinatorStore.getState().pushToast({ tone: 'success', message: '已恢复回收站中的全部素材' });
  },

  markOpened: async (id) => {
    try {
      await apiClient.markAssetOpened(id);
      const now = new Date().toISOString();
      set((s) => {
        const existing = s.assetsByID[id];
        if (!existing) return s;
        const updated = { ...existing, lastOpenedAt: now };
        return {
          assetsByID: { ...s.assetsByID, [id]: updated },
          assets: s.assets.map((a) => (a.id === id ? updated : a)),
        };
      });
    } catch {
      // Non-critical activity update
    }
  },

  refreshRichAsset: async (id) => {
    const res = await apiClient.refreshRichAsset(id);
    get().upsertAssets([res.asset]);
    get().bumpCacheBust();
    return res.asset;
  },

  extractSocialMedia: async (id, attachmentIndex = null) => {
    const res = await apiClient.extractSocialMedia(id, { attachmentIndex });
    get().upsertAssets(res.assets);
    await Promise.all([get().refreshSidebarMetadata(), get().loadAssets()]);
    useCoordinatorStore.getState().pushToast({
      tone: 'success',
      message: `已提取 ${res.assets.length} 项独立媒体至素材库`,
    });
    return res.assets;
  },

  createFolder: async (name, parentID = null) => {
    const res = await apiClient.createFolder({ name, parentID });
    await get().refreshSidebarMetadata();
    return res.folder;
  },

  renameFolder: async (id, name) => {
    const res = await apiClient.renameFolder(id, { name });
    set((s) => ({
      folders: s.folders.map((f) => (f.id === id ? res.folder : f)),
    }));
    return res.folder;
  },

  moveFolder: async (id, newParentID, insertAtIndex = null) => {
    const res = await apiClient.moveFolder(id, { newParentID, insertAtIndex });
    set({ folders: res.folders });
  },

  updateFolderAppearance: async (id, colorHex, customSymbol) => {
    const res = await apiClient.updateFolderAppearance(id, { colorHex, customSymbol });
    set((s) => ({
      folders: s.folders.map((f) => (f.id === id ? res.folder : f)),
    }));
  },

  deleteFolder: async (id, trashContents = false) => {
    await apiClient.deleteFolder(id, { trashContents });
    const coord = useCoordinatorStore.getState();
    if (coord.destination.type === 'folder' && coord.destination.id === id) {
      coord.navigate({ type: 'allItems' });
    }
    await Promise.all([get().refreshSidebarMetadata(), get().loadAssets()]);
  },

  pinFolderOffline: async (id, pinned) => {
    await apiClient.pinFolderOffline(id, pinned);
    await Promise.all([get().refreshSidebarMetadata(), get().loadAssets()]);
    useCoordinatorStore.getState().pushToast({
      tone: 'success',
      message: pinned ? '已为该文件夹保留离线副本' : '已取消文件夹离线保留',
    });
  },

  saveSmartFolder: async (req) => {
    const res = await apiClient.saveSmartFolder(req);
    set({ smartFolders: res.smartFolders });
    const dest = useCoordinatorStore.getState().destination;
    if (dest.type === 'smartFolder') {
      await get().loadAssets();
    }
  },

  deleteSmartFolder: async (id) => {
    const res = await apiClient.deleteSmartFolder(id);
    set({ smartFolders: res.smartFolders });
    const coord = useCoordinatorStore.getState();
    if (coord.destination.type === 'smartFolder' && coord.destination.id === id) {
      coord.navigate({ type: 'allItems' });
    }
  },

  loadInboxSuggestion: async (assetID) => {
    try {
      const res = await apiClient.suggestFolderForAsset(assetID);
      set({ inboxSuggestion: res.suggestion });
    } catch {
      set({ inboxSuggestion: null });
    }
  },

  runBatchInboxTriage: async (assetIDs, maxCount = 24) => {
    set({ isTriaging: true, triageModalOpen: true });
    try {
      const res = await apiClient.batchTriageInbox({ assetIDs, maxCount });
      set({ triageRecommendations: res.recommendations, isTriaging: false });
    } catch (err) {
      set({ isTriaging: false });
      useCoordinatorStore.getState().pushToast({
        tone: 'error',
        message: err instanceof Error ? err.message : '收件箱智能分拣失败',
      });
    }
  },

  setTriageModalOpen: (open) => set({ triageModalOpen: open }),

  seedDemoLibrary: async () => {
    const res = await apiClient.seedDemoLibrary();
    await get().bootstrap();
    return res.seeded;
  },

  upsertAssets: (incoming) => {
    if (incoming.length === 0) return;
    set((s) => {
      const map = new Map(incoming.map((a) => [a.id, a]));
      return {
        assetsByID: indexByID(s.assetsByID, incoming),
        assets: s.assets.map((a) => map.get(a.id) ?? a),
        recentActivityAssets: s.recentActivityAssets.map((a) => map.get(a.id) ?? a),
      };
    });
  },

  bumpCacheBust: () => set((s) => ({ cacheBustVersion: s.cacheBustVersion + 1 })),
}));
