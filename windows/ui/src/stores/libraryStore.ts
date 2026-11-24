import { create } from 'zustand';
import { getTransport } from '../api/transport';
import {
  createDefaultFilterCriteria,
  formatSocialDisplayHandle,
  matchesSmartFolderRule,
  type AssetBatchPatch,
  type AssetRecord,
  type FilterCriteria,
  type FolderRecord,
  type SidebarDestination,
  type SmartFolderRecord,
  type SmartFolderRule,
  type SocialMediaAttachment,
  type SocialPostMetadata,
  type TagCount,
} from '../types/domain';
import { useCoordinatorStore } from './coordinatorStore';

const RECENT_TAGS_STORAGE_KEY = 'charkle.win.recentTags.v1';
const TAG_FREQ_STORAGE_KEY = 'charkle.win.tagUsageFreq.v1';

function readStoredRecentTags(): string[] {
  if (typeof localStorage === 'undefined') return [];
  try {
    const raw = JSON.parse(localStorage.getItem(RECENT_TAGS_STORAGE_KEY) ?? 'null');
    if (Array.isArray(raw)) {
      return raw.filter((x): x is string => typeof x === 'string' && x.trim().length > 0).slice(0, 60);
    }
  } catch {
    // Ignore malformed localStorage
  }
  return [];
}

function readStoredTagFreq(): Record<string, number> {
  if (typeof localStorage === 'undefined') return {};
  try {
    const raw = JSON.parse(localStorage.getItem(TAG_FREQ_STORAGE_KEY) ?? 'null');
    if (raw && typeof raw === 'object' && !Array.isArray(raw)) {
      const out: Record<string, number> = {};
      for (const [k, v] of Object.entries(raw)) {
        if (typeof v === 'number' && Number.isFinite(v) && v > 0) {
          out[k.toLowerCase()] = v;
        }
      }
      return out;
    }
  } catch {
    // Ignore malformed localStorage
  }
  return {};
}

export function isPlainWebBookmark(asset: AssetRecord | null | undefined): boolean {
  return Boolean(
    asset &&
      asset.mediaKind === 'webBookmark' &&
      !asset.richMetadata?.githubRepo &&
      !asset.richMetadata?.socialPost &&
      asset.sourceURL &&
      asset.sourceURL.trim().length > 0,
  );
}

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
      criteria.sortBy = 'newest';
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

export function getSubtreeFolderIds(folders: FolderRecord[], rootId: string): string[] {
  const byParent = new Map<string | null, FolderRecord[]>();
  for (const f of folders) {
    const pid = f.parentID ?? null;
    const list = byParent.get(pid) ?? [];
    list.push(f);
    byParent.set(pid, list);
  }
  const result: string[] = [];
  const visited = new Set<string>();
  const visit = (id: string) => {
    if (visited.has(id)) return;
    visited.add(id);
    for (const child of byParent.get(id) ?? []) {
      visit(child.id);
    }
    result.push(id);
  };
  visit(rootId);
  return result;
}

export function getFolderSubtreeAssetCount(
  allAssets: AssetRecord[],
  folders: FolderRecord[],
  folderId: string,
): number {
  const subtree = new Set(getSubtreeFolderIds(folders, folderId));
  let count = 0;
  for (const asset of allAssets) {
    if (!asset.isTrashed && asset.folderID && subtree.has(asset.folderID)) {
      count += 1;
    }
  }
  return count;
}

export function isFolderSubtreePinnedOffline(
  allAssets: AssetRecord[],
  folders: FolderRecord[],
  folderId: string,
): boolean {
  const subtree = new Set(getSubtreeFolderIds(folders, folderId));
  let found = false;
  for (const asset of allAssets) {
    if (!asset.isTrashed && asset.folderID && subtree.has(asset.folderID)) {
      found = true;
      if (!asset.pinnedOffline) return false;
    }
  }
  return found;
}

export function getFolderBreadcrumbs(folders: FolderRecord[], folderId: string): FolderRecord[] {
  const byId = new Map(folders.map((f) => [f.id, f]));
  const chain: FolderRecord[] = [];
  const visited = new Set<string>();
  let cursor: string | null | undefined = folderId;
  while (cursor && !visited.has(cursor)) {
    visited.add(cursor);
    const folder = byId.get(cursor);
    if (!folder) break;
    chain.push(folder);
    cursor = folder.parentID;
  }
  return chain.reverse();
}

export function getFolderDisplayPath(folders: FolderRecord[], folderId: string): string {
  const crumbs = getFolderBreadcrumbs(folders, folderId);
  return crumbs.length > 0 ? crumbs.map((c) => c.name).join(' / ') : '文件夹';
}

export function getSmartFolderMatchCount(
  allAssets: AssetRecord[],
  rule: SmartFolderRule,
): number {
  let count = 0;
  for (const asset of allAssets) {
    if (matchesSmartFolderRule(asset, rule)) {
      count += 1;
    }
  }
  return count;
}

export function getTopTenSidebarTags(tagCounts: TagCount[]): TagCount[] {
  return [...tagCounts]
    .sort((a, b) => {
      if (a.count !== b.count) return b.count - a.count;
      return a.name.localeCompare(b.name, 'zh-CN');
    })
    .slice(0, 10);
}

export function getRecentFrequentSidebarTags(
  tagCounts: TagCount[],
  recentlyTouchedTags: string[],
  tagUsageFrequency: Record<string, number>,
): TagCount[] {
  const byLower = new Map(tagCounts.map((t) => [t.name.toLowerCase(), t]));
  const ranked: Array<{ item: TagCount; score: number }> = [];
  recentlyTouchedTags.forEach((name, idx) => {
    const key = name.toLowerCase();
    const item = byLower.get(key);
    if (!item) return;
    const recencyBonus = Math.max(0, 60 - idx) * 1.5;
    const freqBonus = (tagUsageFrequency[key] ?? 1) * 4.0;
    ranked.push({ item, score: recencyBonus + freqBonus });
  });
  ranked.sort((a, b) => b.score - a.score);
  const seen = new Set<string>();
  const out: TagCount[] = [];
  for (const entry of ranked) {
    const key = entry.item.name.toLowerCase();
    if (!seen.has(key)) {
      seen.add(key);
      out.push(entry.item);
      if (out.length >= 5) break;
    }
  }
  return out;
}

export function getEffectiveSocialAttachments(
  post: SocialPostMetadata | null | undefined,
): SocialMediaAttachment[] {
  if (!post) return [];
  if (post.attachments && post.attachments.length > 0) {
    return post.attachments;
  }
  const out: SocialMediaAttachment[] = [];
  if (post.videoURL) {
    out.push({
      id: 'video-0',
      kind: 'video',
      url: post.videoURL,
      thumbnailURL: post.mediaThumbnailURLs[0] ?? post.mediaURLs[0] ?? null,
    });
  }
  post.mediaURLs.forEach((url, idx) => {
    if (url === post.videoURL) return;
    out.push({
      id: `media-${idx}`,
      kind: 'photo',
      url,
      thumbnailURL: post.mediaThumbnailURLs[idx] ?? url,
    });
  });
  return out;
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
  allAssets: AssetRecord[];
  folders: FolderRecord[];
  smartFolders: SmartFolderRecord[];
  tagCounts: TagCount[];
  inboxCount: number;
  cutAssetIds: string[];
  recentlyTouchedTags: string[];
  tagUsageFrequency: Record<string, number>;
  criteria: FilterCriteria;
  semanticSearch: boolean;
  loading: boolean;
  bootstrapped: boolean;
  error: string | null;
  mediaRevision: number;
  thumbnailRevisions: Record<string, number>;

  bumpMediaRevision: () => void;
  bumpThumbnailRevisions: (assetIds: string[]) => void;
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
  cutAssets: (ids: string[]) => Promise<number>;
  pasteCutAssets: (
    targetFolderId: string | null,
    destination: SidebarDestination,
  ) => Promise<number>;
  clearCutAssets: () => void;
  recordTouchedTags: (tags: string[]) => void;
  setFoldersPinnedOffline: (
    folderIds: string[],
    pinned: boolean,
    destination: SidebarDestination,
  ) => Promise<number>;
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
  extractSocialAttachment: (
    postAsset: AssetRecord,
    attachment: SocialMediaAttachment,
    index: number,
    destination: SidebarDestination,
  ) => Promise<AssetRecord | null>;
  extractAllSocialAttachments: (
    postAsset: AssetRecord,
    destination: SidebarDestination,
  ) => Promise<AssetRecord[]>;
  refreshRichAsset: (id: string) => Promise<AssetRecord>;
  hydrateImageMetadata: (id: string) => Promise<AssetRecord | null>;
  markAssetOpened: (id: string) => Promise<void>;
  patchSingleAssetInMemory: (asset: AssetRecord) => void;
}

function computeLeavingAssetIds(
  patch: AssetBatchPatch,
  destination: SidebarDestination,
  folders: FolderRecord[],
): Set<string> {
  const ids = patch.assetIDs ?? [];
  if (ids.length === 0) return new Set();

  if (patch.isTrashed === true && destination.type !== 'trash') {
    return new Set(ids);
  }
  if (patch.isTrashed === false && destination.type === 'trash') {
    return new Set(ids);
  }
  if (patch.folderAssignment && patch.folderAssignment !== 'unchanged') {
    if (destination.type === 'inbox' && typeof patch.folderAssignment === 'object') {
      return new Set(ids);
    }
    if (destination.type === 'folder') {
      if (patch.folderAssignment === 'inbox') {
        return new Set(ids);
      }
      if (typeof patch.folderAssignment === 'object') {
        const subtree = new Set(getSubtreeFolderIds(folders, destination.id));
        if (!subtree.has(patch.folderAssignment.folder)) {
          return new Set(ids);
        }
      }
    }
  }
  return new Set();
}

function pruneSelectionAndStepQuickLook(
  previousAssets: AssetRecord[],
  leavingSet: Set<string>,
): void {
  if (leavingSet.size === 0) return;
  const coord = useCoordinatorStore.getState();

  const nextSelection = coord.selectedAssetIds.filter((id) => !leavingSet.has(id));
  if (nextSelection.length !== coord.selectedAssetIds.length) {
    const nextLast =
      coord.lastSelectedAssetId && !leavingSet.has(coord.lastSelectedAssetId)
        ? coord.lastSelectedAssetId
        : (nextSelection[nextSelection.length - 1] ?? null);
    coord.setSelection(nextSelection, nextLast);
  }

  if (coord.quickLookAssetId && leavingSet.has(coord.quickLookAssetId)) {
    const currentIdx = previousAssets.findIndex((a) => a.id === coord.quickLookAssetId);
    const remaining = previousAssets.filter((a) => !leavingSet.has(a.id));
    if (currentIdx < 0 || remaining.length === 0) {
      coord.closeQuickLook();
    } else {
      const nextAsset = remaining[Math.min(currentIdx, remaining.length - 1)] ?? remaining[0];
      if (nextAsset) {
        coord.openQuickLook(nextAsset.id, null);
        coord.setSelection([nextAsset.id], nextAsset.id);
      } else {
        coord.closeQuickLook();
      }
    }
  }
}

function pruneGhostSelectionForDestination(
  destination: SidebarDestination,
  visibleAssets: AssetRecord[],
  allAssets: AssetRecord[],
): void {
  const coord = useCoordinatorStore.getState();
  const sourcePool = allAssets.length > 0 ? allAssets : visibleAssets;
  const byId = new Map(sourcePool.map((a) => [a.id, a]));
  const inMoodboard =
    destination.type === 'moodboard' || destination.type === 'moodboardsHome';
  const expectTrashed = destination.type === 'trash';

  // Ensure Quick Look never stays stuck on a deleted/missing or wrong-trash-state ghost asset
  if (coord.quickLookAssetId && sourcePool.length > 0) {
    const qlRec = byId.get(coord.quickLookAssetId);
    if (!qlRec || (!inMoodboard && Boolean(qlRec.isTrashed) !== expectTrashed)) {
      coord.closeQuickLook();
    }
  } else if (coord.quickLookAssetId && allAssets.length === 0 && visibleAssets.length === 0) {
    coord.closeQuickLook();
  }

  if (inMoodboard || coord.selectedAssetIds.length === 0) {
    return;
  }

  const pruned = coord.selectedAssetIds.filter((id) => {
    const rec = byId.get(id);
    if (!rec) return false;
    return Boolean(rec.isTrashed) === expectTrashed;
  });

  if (pruned.length !== coord.selectedAssetIds.length) {
    const nextLast =
      coord.lastSelectedAssetId && pruned.includes(coord.lastSelectedAssetId)
        ? coord.lastSelectedAssetId
        : (pruned[pruned.length - 1] ?? null);
    coord.setSelection(pruned, nextLast);
  }
}

let fetchSeq = 0;
let sidebarMetaSeq = 0;

export const useLibraryStore = create<LibraryState>((set, get) => ({
  assets: [],
  allAssets: [],
  folders: [],
  smartFolders: [],
  tagCounts: [],
  inboxCount: 0,
  cutAssetIds: [],
  recentlyTouchedTags: readStoredRecentTags(),
  tagUsageFrequency: readStoredTagFreq(),
  criteria: createDefaultFilterCriteria(),
  semanticSearch: false,
  loading: false,
  bootstrapped: false,
  error: null,
  mediaRevision: 0,
  thumbnailRevisions: {},

  bumpMediaRevision() {
    set((s) => ({ mediaRevision: s.mediaRevision + 1 }));
  },

  bumpThumbnailRevisions(assetIds) {
    if (!assetIds || assetIds.length === 0) return;
    set((s) => {
      const next = { ...s.thumbnailRevisions };
      for (const id of assetIds) {
        next[id] = (next[id] ?? 0) + 1;
      }
      return { thumbnailRevisions: next };
    });
  },

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
    const metaSeq = ++sidebarMetaSeq;
    const transport = getTransport();
    const [folders, smartFolders, tagCounts, inboxCount] = await Promise.all([
      transport.fetchFolders(),
      transport.fetchSmartFolders(),
      transport.fetchTagCounts(),
      transport.inboxCount(),
    ]);
    if (metaSeq === sidebarMetaSeq) {
      set({ folders, smartFolders, tagCounts, inboxCount });
    }
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
        pruneGhostSelectionForDestination(destination, fetched, get().allAssets);
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
    const metaSeq = ++sidebarMetaSeq;
    const transport = getTransport();
    set({ loading: true, error: null });
    try {
      const effectiveCriteria = buildCriteriaForDestination(destination, get().criteria);
      const [folders, smartFolders, tagCounts, inboxCount, fetchedAssets, fetchedAll] =
        await Promise.all([
          transport.fetchFolders(),
          transport.fetchSmartFolders(),
          transport.fetchTagCounts(),
          transport.inboxCount(),
          transport.fetchAssets(effectiveCriteria),
          transport.fetchAssets(createDefaultFilterCriteria({ includeTrashed: true })),
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
          ...(metaSeq === sidebarMetaSeq ? { folders, smartFolders, tagCounts, inboxCount } : {}),
          assets,
          allAssets: fetchedAll,
          loading: false,
        });
        pruneGhostSelectionForDestination(destination, assets, fetchedAll);
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

  recordTouchedTags(tags) {
    const cleaned = tags
      .map((t) => t.replace(/^[#＃]+/, '').trim())
      .filter(Boolean);
    if (cleaned.length === 0) return;

    let next = [...get().recentlyTouchedTags];
    const freq = { ...get().tagUsageFrequency };
    for (const tag of [...cleaned].reverse()) {
      const key = tag.toLowerCase();
      next = next.filter((t) => t.toLowerCase() !== key);
      next.unshift(tag);
      freq[key] = (freq[key] ?? 0) + 1;
    }
    if (next.length > 60) next = next.slice(0, 60);

    set({ recentlyTouchedTags: next, tagUsageFrequency: freq });
    if (typeof localStorage !== 'undefined') {
      try {
        localStorage.setItem(RECENT_TAGS_STORAGE_KEY, JSON.stringify(next));
        localStorage.setItem(TAG_FREQ_STORAGE_KEY, JSON.stringify(freq));
      } catch {
        // Ignore quota errors
      }
    }
  },

  async updateAssets(patch, destination, opts) {
    const previous = get().assets;
    const previousAll = get().allAssets;
    const folders = get().folders;

    if (patch.addTags?.length) {
      get().recordTouchedTags(patch.addTags);
    } else if (patch.acceptSuggestedTags) {
      const idSet = new Set(patch.assetIDs);
      const accepted = previous
        .filter((a) => idSet.has(a.id))
        .flatMap((a) => a.suggestedTags);
      if (accepted.length > 0) get().recordTouchedTags(accepted);
    }

    const leavingSet = computeLeavingAssetIds(patch, destination, folders);
    const optimisticAssets = applyOptimisticPatch(previous, patch);
    const nextVisibleAssets =
      leavingSet.size > 0
        ? optimisticAssets.filter((a) => !leavingSet.has(a.id))
        : optimisticAssets;

    set({
      assets: nextVisibleAssets,
      allAssets: applyOptimisticPatch(previousAll, patch),
    });

    if (leavingSet.size > 0) {
      pruneSelectionAndStepQuickLook(previous, leavingSet);
    }

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
            void get().updateAssets(undoPatch, useCoordinatorStore.getState().destination);
          },
        });
      }

      return updated;
    } catch (err) {
      set({ assets: previous, allAssets: previousAll });
      useCoordinatorStore.getState().pushToast({
        message: `更新失败：${err instanceof Error ? err.message : String(err)}`,
        tone: 'error',
      });
      throw err;
    }
  },

  async permanentlyDeleteAssets(ids, destination) {
    if (ids.length === 0) return;
    const previousAssets = get().assets;
    const previousAll = get().allAssets;
    const delSet = new Set(ids);

    set({
      assets: previousAssets.filter((a) => !delSet.has(a.id)),
      allAssets: previousAll.filter((a) => !delSet.has(a.id)),
    });
    pruneSelectionAndStepQuickLook(previousAssets, delSet);

    const coord = useCoordinatorStore.getState();
    try {
      await getTransport().permanentlyDeleteAssets(ids);
      await get().refreshAll(destination);
      coord.pushToast({
        message: `已彻底删除 ${ids.length} 项素材`,
        tone: 'success',
      });
    } catch (err) {
      set({ assets: previousAssets, allAssets: previousAll });
      coord.pushToast({
        message: `删除失败：${err instanceof Error ? err.message : String(err)}`,
        tone: 'error',
      });
      throw err;
    }
  },

  async cutAssets(ids) {
    if (ids.length === 0) return 0;
    const unique = Array.from(new Set(ids));
    try {
      await getTransport().copyAssetsToClipboard(unique);
    } catch {
      // Clipboard file export may fail for remote-only bookmarks; internal cut move still works
    }
    set({ cutAssetIds: unique });
    return unique.length;
  },

  async pasteCutAssets(targetFolderId, destination) {
    const ids = [...get().cutAssetIds];
    if (ids.length === 0) return 0;
    set({ cutAssetIds: [] });
    await get().updateAssets(
      {
        assetIDs: ids,
        folderAssignment: targetFolderId ? { folder: targetFolderId } : 'inbox',
      },
      destination,
    );
    return ids.length;
  },

  clearCutAssets() {
    set({ cutAssetIds: [] });
  },

  async setFoldersPinnedOffline(folderIds, pinned, destination) {
    const { folders, allAssets } = get();
    const subtreeSet = new Set<string>();
    for (const fid of folderIds) {
      for (const id of getSubtreeFolderIds(folders, fid)) {
        subtreeSet.add(id);
      }
    }
    const targetAssetIDs = allAssets
      .filter((a) => !a.isTrashed && a.folderID && subtreeSet.has(a.folderID))
      .map((a) => a.id);
    if (targetAssetIDs.length === 0) return 0;

    await get().updateAssets(
      { assetIDs: targetAssetIDs, pinnedOffline: pinned },
      destination,
    );
    if (!pinned) {
      try {
        await getTransport().evictCacheNow();
      } catch {
        // Non-fatal
      }
      await get().refreshAll(destination);
    }
    return targetAssetIDs.length;
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
    if (newParentId) {
      const subtree = getSubtreeFolderIds(get().folders, id);
      if (subtree.includes(newParentId)) {
        return get().folders;
      }
    }
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
    const folderName = get().folders.find((f) => f.id === id)?.name;
    const subtreeIds = new Set(getSubtreeFolderIds(get().folders, id));
    try {
      await getTransport().deleteFolder(id, trashContents);
      const liveDest = useCoordinatorStore.getState().destination ?? destination;
      if (liveDest.type === 'folder' && subtreeIds.has(liveDest.id)) {
        useCoordinatorStore.getState().setDestination({ type: 'allItems' });
        await get().refreshAll({ type: 'allItems' });
      } else {
        await get().refreshAll(liveDest);
      }
      useCoordinatorStore.getState().pushToast({
        message: trashContents
          ? folderName
            ? `已删除「${folderName}」及其中素材（已移至回收站）`
            : '已删除文件夹及其中素材'
          : folderName
            ? `已删除「${folderName}」，素材已退回收件箱`
            : '文件夹已删除，素材已退回收件箱',
        tone: 'info',
      });
    } catch (err) {
      useCoordinatorStore.getState().pushToast({
        message: `删除文件夹失败：${err instanceof Error ? err.message : String(err)}`,
        tone: 'error',
      });
      throw err;
    }
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
    const prevFolderIds = new Set(get().folders.map((f) => f.id));
    const created = await getTransport().ingestFiles(paths, targetFolderId, null);
    const dest = destination ?? useCoordinatorStore.getState().destination;
    await get().refreshAll(dest);
    const newFolders = get().folders.filter((f) => !prevFolderIds.has(f.id));
    let message: string;
    if (newFolders.length > 0 && created.length > 0) {
      message =
        newFolders.length === 1
          ? `已建文件夹「${newFolders[0].name}」并导入 ${created.length} 项素材`
          : `已建 ${newFolders.length} 个文件夹并导入 ${created.length} 项素材`;
    } else if (newFolders.length > 0) {
      message =
        newFolders.length === 1
          ? `已建立文件夹「${newFolders[0].name}」`
          : `已建立 ${newFolders.length} 个文件夹`;
    } else {
      message = `已导入 ${created.length} 项素材`;
    }
    useCoordinatorStore.getState().pushToast({
      message,
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

  async extractSocialAttachment(postAsset, attachment, index, destination) {
    const post = postAsset.richMetadata?.socialPost;
    if (!post || !attachment.url) return null;
    const isXiaohongshu = post.platform === 'xiaohongshu';
    const platformLabel = isXiaohongshu
      ? '小红书'
      : post.platform === 'x'
        ? 'X'
        : post.platform === 'threads'
          ? 'Threads'
          : 'Bluesky';
    const postNoun = isXiaohongshu ? '笔记' : '推文';
    const kindLabel =
      attachment.kind === 'video' ? '视频' : attachment.kind === 'gif' ? '动图' : '图片';
    const displayHandle = formatSocialDisplayHandle(post);
    const authorLabel = displayHandle ?? (post.authorName?.trim() || platformLabel);
    const extractedTitle = `${authorLabel} ${kindLabel} #${index + 1}`;
    const authorLine = displayHandle
      ? `${post.authorName} (${displayHandle})`
      : post.authorName?.trim() || platformLabel;
    const attributionNotes = [
      `来源${postNoun}：${authorLine} · ${platformLabel}`,
      post.bodyText.trim(),
      `原${postNoun}链接：${post.originalURL}`,
    ]
      .filter(Boolean)
      .join('\n\n');

    try {
      const created = await getTransport().ingestUrl(
        attachment.url,
        extractedTitle,
        attributionNotes,
        postAsset.folderID ?? null,
        null,
      );
      const standalone = created[0];
      if (!standalone) return null;
      await getTransport().updateAssets({
        assetIDs: [standalone.id],
        title: extractedTitle,
        notes: attributionNotes,
        addTags: [platformLabel],
      });
      await get().refreshAll(destination);
      return standalone;
    } catch (err) {
      useCoordinatorStore.getState().pushToast({
        message: `提取${postNoun}媒体失败：${err instanceof Error ? err.message : String(err)}`,
        tone: 'error',
      });
      return null;
    }
  },

  async extractAllSocialAttachments(postAsset, destination) {
    const attachments = getEffectiveSocialAttachments(postAsset.richMetadata?.socialPost);
    const extracted: AssetRecord[] = [];
    for (let i = 0; i < attachments.length; i += 1) {
      const created = await get().extractSocialAttachment(
        postAsset,
        attachments[i],
        i,
        destination,
      );
      if (created) extracted.push(created);
    }
    return extracted;
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
      allAssets: s.allAssets.some((item) => item.id === asset.id)
        ? s.allAssets.map((item) => (item.id === asset.id ? asset : item))
        : [...s.allAssets, asset],
    }));
  },
}));
