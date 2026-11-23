import { create } from 'zustand';
import { getTransport } from '../api/transport';
import {
  createDefaultFilterCriteria,
  matchesSmartFolderRule,
  type AssetBatchPatch,
  type AssetRecord,
  type FilterCriteria,
  type FolderRecord,
  type SidebarDestination,
  type SmartFolderRecord,
  type TagCount,
} from '../types/domain';
import { useCoordinatorStore } from './coordinatorStore';

export function buildCriteriaForDestination(
  destination: SidebarDestination,
  base: FilterCriteria,
): FilterCriteria {
  const criteria: FilterCriteria = {
    ...base,
    folderID: null,
    includeSubfolders: false,
    onlyInbox: false,
    onlyUntagged: false,
    onlyRecentDays: null,
    includeTrashed: false,
    onlyTrashed: false,
  };

  switch (destination.type) {
    case 'allItems':
      break;
    case 'inbox':
      criteria.onlyInbox = true;
      break;
    case 'untagged':
      criteria.onlyUntagged = true;
      break;
    case 'recent':
      criteria.onlyRecentDays = 14;
      break;
    case 'trash':
      criteria.onlyTrashed = true;
      criteria.includeTrashed = true;
      break;
    case 'folder':
      criteria.folderID = destination.id;
      criteria.includeSubfolders = true;
      break;
    case 'tag':
      criteria.tags = Array.from(new Set([...criteria.tags, destination.name]));
      break;
    case 'smartFolder':
    case 'moodboardsHome':
    case 'moodboard':
      break;
  }

  return criteria;
}

export function countActiveVisualFilters(criteria: FilterCriteria): number {
  let count = 0;
  if (criteria.searchQuery.trim()) count += 1;
  if (criteria.kinds.length > 0) count += 1;
  if (criteria.selectedColorHex) count += 1;
  if (criteria.shape) count += 1;
  if (criteria.minRating > 0) count += 1;
  if (criteria.tags.length > 0) count += 1;
  if (criteria.onlyPinnedOffline) count += 1;
  return count;
}

function applyOptimisticPatch(assets: AssetRecord[], patch: AssetBatchPatch): AssetRecord[] {
  const idSet = new Set(patch.assetIDs);
  return assets.map((a) => {
    if (!idSet.has(a.id)) return a;
    const next: AssetRecord = { ...a };
    if (patch.title != null) next.title = patch.title;
    if (patch.notes != null) next.notes = patch.notes;
    if (patch.rating != null) next.rating = patch.rating;
    if (patch.pinnedOffline != null) next.pinnedOffline = patch.pinnedOffline;
    if (patch.isTrashed != null) next.isTrashed = patch.isTrashed;
    if (patch.folderAssignment === 'inbox') {
      next.folderID = null;
    } else if (patch.folderAssignment && typeof patch.folderAssignment === 'object') {
      next.folderID = patch.folderAssignment.folder;
    }

    const tags = new Set(next.tags);
    if (patch.acceptSuggestedTags) {
      for (const s of next.suggestedTags) tags.add(s);
      next.suggestedTags = [];
    }
    if (patch.dismissSuggestedTags?.length) {
      const drop = new Set(patch.dismissSuggestedTags.map((t) => t.toLowerCase()));
      next.suggestedTags = next.suggestedTags.filter((s) => !drop.has(s.toLowerCase()));
    }
    for (const t of patch.addTags ?? []) {
      const trimmed = t.trim();
      if (trimmed) tags.add(trimmed);
    }
    for (const t of patch.removeTags ?? []) {
      tags.delete(t.trim());
    }
    next.tags = [...tags].sort();
    return next;
  });
}

export interface LibraryState {
  assets: AssetRecord[];
  folders: FolderRecord[];
  smartFolders: SmartFolderRecord[];
  tagCounts: TagCount[];
  inboxCount: number;
  criteria: FilterCriteria;
  semanticSearch: boolean;
  loading: boolean;
  bootstrapped: boolean;
  error: string | null;

  bootstrap: (destination: SidebarDestination) => Promise<void>;
  refreshAll: (destination: SidebarDestination) => Promise<void>;
  refreshAssets: (destination: SidebarDestination) => Promise<void>;
  refreshSidebarMeta: () => Promise<void>;
  setCriteria: (patch: Partial<FilterCriteria>, destination: SidebarDestination) => Promise<void>;
  clearVisualFilters: (destination: SidebarDestination) => Promise<void>;
  setSemanticSearch: (enabled: boolean) => void;
  updateAssets: (
    patch: AssetBatchPatch,
    destination: SidebarDestination,
    opts?: { undoMessage?: string; undoPatch?: AssetBatchPatch },
  ) => Promise<AssetRecord[]>;
  permanentlyDeleteAssets: (ids: string[], destination: SidebarDestination) => Promise<void>;
  createFolder: (name: string, parentId?: string | null) => Promise<FolderRecord>;
  renameFolder: (id: string, newName: string) => Promise<FolderRecord>;
  moveFolder: (
    id: string,
    newParentId: string | null,
    insertAtIndex?: number | null,
  ) => Promise<FolderRecord[]>;
  updateFolderAppearance: (
    id: string,
    colorHex: string | null,
    customSymbol: string | null,
  ) => Promise<FolderRecord>;
  deleteFolder: (
    id: string,
    trashContents: boolean,
    destination: SidebarDestination,
  ) => Promise<void>;
  saveSmartFolder: (
    folder: SmartFolderRecord,
    destination: SidebarDestination,
  ) => Promise<void>;
  deleteSmartFolder: (id: string, destination: SidebarDestination) => Promise<void>;
  ingestFiles: (
    paths: string[],
    targetFolderId?: string | null,
    destination?: SidebarDestination,
  ) => Promise<AssetRecord[]>;
  ingestUrl: (
    url: string,
    title?: string | null,
    notes?: string | null,
    targetFolderId?: string | null,
    destination?: SidebarDestination,
  ) => Promise<AssetRecord[]>;
  ingestText: (
    title: string,
    text: string,
    sourceUrl?: string | null,
    targetFolderId?: string | null,
    destination?: SidebarDestination,
  ) => Promise<AssetRecord[]>;
  ingestSwatch: (
    hex: string,
    title?: string | null,
    targetFolderId?: string | null,
    destination?: SidebarDestination,
  ) => Promise<AssetRecord[]>;
  ingestImageBase64: (
    dataBase64: string,
    suggestedName: string,
    sourceUrl?: string | null,
    targetFolderId?: string | null,
    destination?: SidebarDestination,
  ) => Promise<AssetRecord[]>;
  refreshRichAsset: (id: string) => Promise<AssetRecord>;
  hydrateImageMetadata: (id: string) => Promise<AssetRecord | null>;
  markAssetOpened: (id: string) => Promise<void>;
  patchSingleAssetInMemory: (asset: AssetRecord) => void;
}

let fetchSeq = 0;

export const useLibraryStore = create<LibraryState>((set, get) => ({
  assets: [],
  folders: [],
  smartFolders: [],
  tagCounts: [],
  inboxCount: 0,
  criteria: createDefaultFilterCriteria(),
  semanticSearch: false,
  loading: false,
  bootstrapped: false,
  error: null,

  async bootstrap(destination) {
    if (get().bootstrapped) return;
    set({ loading: true, error: null });
    try {
      await getTransport().seedSampleLibraryIfEmpty();
      await get().refreshAll(destination);
      set({ bootstrapped: true });
    } catch (err) {
      set({
        loading: false,
        bootstrapped: true,
        error: err instanceof Error ? err.message : String(err),
      });
    }
  },

  async refreshSidebarMeta() {
    const transport = getTransport();
    const [folders, smartFolders, tagCounts, inboxCount] = await Promise.all([
      transport.fetchFolders(),
      transport.fetchSmartFolders(),
      transport.fetchTagCounts(),
      transport.inboxCount(),
    ]);
    set({ folders, smartFolders, tagCounts, inboxCount });
  },

  async refreshAssets(destination) {
    const seq = ++fetchSeq;
    const transport = getTransport();
    set({ loading: true, error: null });
    try {
      const effectiveCriteria = buildCriteriaForDestination(destination, get().criteria);
      let fetched = await transport.fetchAssets(effectiveCriteria);
      if (destination.type === 'smartFolder') {
        const sf = get().smartFolders.find((item) => item.id === destination.id);
        if (sf) {
          fetched = fetched.filter((asset) => matchesSmartFolderRule(asset, sf.rule));
        }
      }
      if (seq === fetchSeq) {
        set({ assets: fetched, loading: false });
      }
    } catch (err) {
      if (seq === fetchSeq) {
        set({
          loading: false,
          error: err instanceof Error ? err.message : String(err),
        });
      }
    }
  },

  async refreshAll(destination) {
    const seq = ++fetchSeq;
    const transport = getTransport();
    set({ loading: true, error: null });
    try {
      const effectiveCriteria = buildCriteriaForDestination(destination, get().criteria);
      const [folders, smartFolders, tagCounts, inboxCount, fetchedAssets] = await Promise.all([
        transport.fetchFolders(),
        transport.fetchSmartFolders(),
        transport.fetchTagCounts(),
        transport.inboxCount(),
        transport.fetchAssets(effectiveCriteria),
      ]);

      let assets = fetchedAssets;
      if (destination.type === 'smartFolder') {
        const sf = smartFolders.find((item) => item.id === destination.id);
        if (sf) {
          assets = assets.filter((asset) => matchesSmartFolderRule(asset, sf.rule));
        }
      }

      if (seq === fetchSeq) {
        set({
          folders,
          smartFolders,
          tagCounts,
          inboxCount,
          assets,
          loading: false,
        });
      }
    } catch (err) {
      if (seq === fetchSeq) {
        set({
          loading: false,
          error: err instanceof Error ? err.message : String(err),
        });
      }
    }
  },

  async setCriteria(patch, destination) {
    set((s) => ({ criteria: { ...s.criteria, ...patch } }));
    await get().refreshAssets(destination);
  },

  async clearVisualFilters(destination) {
    set((s) => ({
      criteria: createDefaultFilterCriteria({ sortBy: s.criteria.sortBy }),
    }));
    await get().refreshAssets(destination);
  },

  setSemanticSearch(enabled) {
    set({ semanticSearch: enabled });
  },

  async updateAssets(patch, destination, opts) {
    const previous = get().assets;
    set({ assets: applyOptimisticPatch(previous, patch) });

    try {
      const updated = await getTransport().updateAssets(patch);
      await get().refreshAll(destination);

      if (opts?.undoMessage && opts.undoPatch) {
        const undoPatch = opts.undoPatch;
        useCoordinatorStore.getState().pushToast({
          message: opts.undoMessage,
          tone: 'info',
          actionLabel: '撤销',
          durationMs: 5500,
          onAction: () => {
            void get().updateAssets(undoPatch, destination);
          },
        });
      }

      return updated;
    } catch (err) {
      set({ assets: previous });
      useCoordinatorStore.getState().pushToast({
        message: `更新失败：${err instanceof Error ? err.message : String(err)}`,
        tone: 'error',
      });
      throw err;
    }
  },

  async permanentlyDeleteAssets(ids, destination) {
    await getTransport().permanentlyDeleteAssets(ids);
    const coord = useCoordinatorStore.getState();
    const delSet = new Set(ids);
    const remaining = coord.selectedAssetIds.filter((id) => !delSet.has(id));
    coord.setSelection(remaining);
    if (coord.quickLookAssetId && delSet.has(coord.quickLookAssetId)) {
      coord.closeQuickLook();
    }
    await get().refreshAll(destination);
    coord.pushToast({
      message: `已永久删除 ${ids.length} 项素材`,
      tone: 'success',
    });
  },

  async createFolder(name, parentId = null) {
    const folder = await getTransport().createFolder(name, parentId);
    await get().refreshSidebarMeta();
    return folder;
  },

  async renameFolder(id, newName) {
    const folder = await getTransport().renameFolder(id, newName);
    await get().refreshSidebarMeta();
    return folder;
  },

  async moveFolder(id, newParentId, insertAtIndex = null) {
    const folders = await getTransport().moveFolder(id, newParentId, insertAtIndex);
    set({ folders });
    return folders;
  },

  async updateFolderAppearance(id, colorHex, customSymbol) {
    const folder = await getTransport().updateFolderAppearance(id, colorHex, customSymbol);
    await get().refreshSidebarMeta();
    return folder;
  },

  async deleteFolder(id, trashContents, destination) {
    await getTransport().deleteFolder(id, trashContents);
    if (destination.type === 'folder' && destination.id === id) {
      useCoordinatorStore.getState().setDestination({ type: 'allItems' });
      await get().refreshAll({ type: 'allItems' });
    } else {
      await get().refreshAll(destination);
    }
    useCoordinatorStore.getState().pushToast({
      message: '文件夹已删除',
      tone: 'info',
    });
  },

  async saveSmartFolder(folder, destination) {
    const smartFolders = await getTransport().saveSmartFolder(folder);
    set({ smartFolders });
    if (destination.type === 'smartFolder' && destination.id === folder.id) {
      await get().refreshAssets(destination);
    }
  },

  async deleteSmartFolder(id, destination) {
    const smartFolders = await getTransport().deleteSmartFolder(id);
    set({ smartFolders });
    if (destination.type === 'smartFolder' && destination.id === id) {
      useCoordinatorStore.getState().setDestination({ type: 'allItems' });
      await get().refreshAssets({ type: 'allItems' });
    }
  },

  async ingestFiles(paths, targetFolderId = null, destination) {
    if (paths.length === 0) return [];
    const created = await getTransport().ingestFiles(paths, targetFolderId, null);
    const dest = destination ?? useCoordinatorStore.getState().destination;
    await get().refreshAll(dest);
    useCoordinatorStore.getState().pushToast({
      message: `已导入 ${created.length} 项素材`,
      tone: 'success',
    });
    return created;
  },

  async ingestUrl(url, title = null, notes = null, targetFolderId = null, destination) {
    const created = await getTransport().ingestUrl(url, title, notes, targetFolderId, null);
    const dest = destination ?? useCoordinatorStore.getState().destination;
    await get().refreshAll(dest);
    useCoordinatorStore.getState().pushToast({
      message: '已采集网页链接',
      tone: 'success',
    });
    return created;
  },

  async ingestText(title, text, sourceUrl = null, targetFolderId = null, destination) {
    const created = await getTransport().ingestText(title, text, sourceUrl, targetFolderId, null);
    const dest = destination ?? useCoordinatorStore.getState().destination;
    await get().refreshAll(dest);
    useCoordinatorStore.getState().pushToast({
      message: '已保存文本笔记',
      tone: 'success',
    });
    return created;
  },

  async ingestSwatch(hex, title = null, targetFolderId = null, destination) {
    const created = await getTransport().ingestSwatch(hex, title, targetFolderId, null);
    const dest = destination ?? useCoordinatorStore.getState().destination;
    await get().refreshAll(dest);
    useCoordinatorStore.getState().pushToast({
      message: `已保存色卡 ${hex.toUpperCase()}`,
      tone: 'success',
    });
    return created;
  },

  async ingestImageBase64(dataBase64, suggestedName, sourceUrl = null, targetFolderId = null, destination) {
    const created = await getTransport().ingestImageBase64(
      dataBase64,
      suggestedName,
      sourceUrl,
      targetFolderId,
      null,
    );
    const dest = destination ?? useCoordinatorStore.getState().destination;
    await get().refreshAll(dest);
    useCoordinatorStore.getState().pushToast({
      message: '已从剪贴板导入图片',
      tone: 'success',
    });
    return created;
  },

  async refreshRichAsset(id) {
    const updated = await getTransport().refreshRichAsset(id);
    get().patchSingleAssetInMemory(updated);
    useCoordinatorStore.getState().pushToast({
      message: '已刷新外部元数据',
      tone: 'success',
    });
    return updated;
  },

  async hydrateImageMetadata(id) {
    const updated = await getTransport().hydrateImageMetadata(id);
    if (updated) {
      get().patchSingleAssetInMemory(updated);
    }
    return updated;
  },

  async markAssetOpened(id) {
    const updated = await getTransport().markAssetOpened(id);
    if (updated) {
      get().patchSingleAssetInMemory(updated);
    }
  },

  patchSingleAssetInMemory(asset) {
    set((s) => ({
      assets: s.assets.map((item) => (item.id === asset.id ? asset : item)),
    }));
  },
}));
