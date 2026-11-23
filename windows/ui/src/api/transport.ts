//! Pluggable `CharkleTransport` seam with `TauriTransport` (Windows desktop IPC +
//! zero-copy `charkle-media://` URLs) and `InMemoryMockTransport` (Vitest / browser preview).

import { invoke } from '@tauri-apps/api/core';
import { listen, type UnlistenFn } from '@tauri-apps/api/event';
import { open as openDialog } from '@tauri-apps/plugin-dialog';
import {
  matchesSmartFolderRule,
  msToCocoaSeconds,
  wireDateToMs,
  type AssetBatchPatch,
  type AssetRecord,
  type CacheStats,
  type ClientRect,
  type DriveSyncConfig,
  type FilterCriteria,
  type FolderRecord,
  type FolderSuggestion,
  type MoodboardDocument,
  type MoodboardSummary,
  type QuickJumpMatch,
  type ScoredAsset,
  type SmartFolderRecord,
  type SyncReport,
  type SyncStatus,
  type TagCount,
  type ThumbnailTier,
  type WindowSurfaceState,
} from '../types/domain';

export interface CharkleEventHandlers {
  onLibraryChanged?: () => void;
  onSyncStatus?: (status: SyncStatus) => void;
  onAssetEnriched?: (assetId: string) => void;
  onBoardUpdated?: (boardId: string) => void;
}

export interface CharkleTransport {
  readonly kind: 'tauri' | 'mock';

  // Media zero-copy URL builders
  thumbnailUrl(assetId: string, tier?: ThumbnailTier): string;
  originalUrl(assetId: string, opts?: { cachedOnly?: boolean }): string;

  // Assets
  fetchAssets(criteria: FilterCriteria): Promise<AssetRecord[]>;
  fetchAsset(id: string): Promise<AssetRecord | null>;
  ingestFiles(paths: string[], targetFolderId?: string | null, targetBoardId?: string | null): Promise<AssetRecord[]>;
  ingestUrl(url: string, title?: string | null, notes?: string | null, targetFolderId?: string | null, targetBoardId?: string | null): Promise<AssetRecord[]>;
  ingestText(title: string, text: string, sourceUrl?: string | null, targetFolderId?: string | null, targetBoardId?: string | null): Promise<AssetRecord[]>;
  ingestSwatch(hex: string, title?: string | null, targetFolderId?: string | null, targetBoardId?: string | null): Promise<AssetRecord[]>;
  ingestImageBase64(dataBase64: string, suggestedName: string, sourceUrl?: string | null, targetFolderId?: string | null, targetBoardId?: string | null): Promise<AssetRecord[]>;
  updateAssets(patch: AssetBatchPatch): Promise<AssetRecord[]>;
  permanentlyDeleteAssets(ids: string[]): Promise<void>;
  markAssetOpened(id: string): Promise<AssetRecord | null>;
  similarAssets(assetId: string, limit?: number): Promise<ScoredAsset[]>;
  suggestFolder(assetId: string): Promise<FolderSuggestion | null>;
  hydrateImageMetadata(id: string): Promise<AssetRecord | null>;
  refreshRichAsset(id: string): Promise<AssetRecord>;

  // Folders, Smart Folders & Tags
  fetchFolders(): Promise<FolderRecord[]>;
  createFolder(name: string, parentId?: string | null): Promise<FolderRecord>;
  renameFolder(id: string, newName: string): Promise<FolderRecord>;
  moveFolder(id: string, newParentId: string | null, insertAtIndex?: number | null): Promise<FolderRecord[]>;
  updateFolderAppearance(id: string, colorHex: string | null, customSymbol: string | null): Promise<FolderRecord>;
  deleteFolder(id: string, trashContents?: boolean): Promise<void>;
  fetchSmartFolders(): Promise<SmartFolderRecord[]>;
  saveSmartFolder(folder: SmartFolderRecord): Promise<SmartFolderRecord[]>;
  deleteSmartFolder(id: string): Promise<SmartFolderRecord[]>;
  fetchTagCounts(): Promise<TagCount[]>;
  inboxCount(): Promise<number>;

  // Query, Boards & Seeding
  quickJump(query: string, limit?: number): Promise<QuickJumpMatch[]>;
  fetchBoards(): Promise<MoodboardSummary[]>;
  fetchBoard(id: string): Promise<MoodboardDocument | null>;
  saveBoard(doc: MoodboardDocument): Promise<MoodboardDocument>;
  deleteBoard(id: string): Promise<void>;
  setBoardPinnedOffline(id: string, pinned: boolean): Promise<MoodboardDocument>;
  seedSampleLibraryIfEmpty(): Promise<boolean>;

  // Media Cache & System Actions
  cacheStats(): Promise<CacheStats>;
  setCacheBudgetBytes(bytes: number): Promise<number>;
  evictCacheNow(): Promise<CacheStats>;
  readAssetTextContent(id: string): Promise<string | null>;
  revealInExplorer(id: string): Promise<void>;
  openExternalUrl(url: string): Promise<void>;
  pickFilesDialog(): Promise<string[]>;

  // Sync
  syncConfig(): Promise<DriveSyncConfig>;
  saveSyncConfig(config: DriveSyncConfig): Promise<void>;
  syncStatus(): Promise<SyncStatus>;
  syncNow(): Promise<SyncReport>;

  // Window Chrome & Snap Layouts
  setWindowTheme(isDark: boolean): Promise<WindowSurfaceState>;
  setMaximizeButtonRect(rect: ClientRect | null): Promise<void>;
  windowMinimize(): Promise<void>;
  windowToggleMaximize(): Promise<boolean>;
  windowClose(): Promise<void>;
  windowIsMaximized(): Promise<boolean>;

  // Live Events
  subscribeEvents(handlers: CharkleEventHandlers): Promise<() => void>;
}

export function isTauriRuntime(): boolean {
  return typeof window !== 'undefined' && '__TAURI_INTERNALS__' in window;
}

export class TauriTransport implements CharkleTransport {
  readonly kind = 'tauri' as const;

  thumbnailUrl(assetId: string, tier: ThumbnailTier = 'grid520'): string {
    return `http://charkle-media.localhost/thumb/${encodeURIComponent(assetId)}/${tier}`;
  }

  originalUrl(assetId: string, opts?: { cachedOnly?: boolean }): string {
    const suffix = opts?.cachedOnly ? '?cachedOnly=1' : '';
    return `http://charkle-media.localhost/original/${encodeURIComponent(assetId)}${suffix}`;
  }

  fetchAssets(criteria: FilterCriteria): Promise<AssetRecord[]> {
    return invoke('fetch_assets', { criteria });
  }

  fetchAsset(id: string): Promise<AssetRecord | null> {
    return invoke('fetch_asset', { id });
  }

  ingestFiles(paths: string[], targetFolderId?: string | null, targetBoardId?: string | null): Promise<AssetRecord[]> {
    return invoke('ingest_files', { paths, targetFolderId: targetFolderId ?? null, targetBoardId: targetBoardId ?? null });
  }

  ingestUrl(url: string, title?: string | null, notes?: string | null, targetFolderId?: string | null, targetBoardId?: string | null): Promise<AssetRecord[]> {
    return invoke('ingest_url', { url, title: title ?? null, notes: notes ?? null, targetFolderId: targetFolderId ?? null, targetBoardId: targetBoardId ?? null });
  }

  ingestText(title: string, text: string, sourceUrl?: string | null, targetFolderId?: string | null, targetBoardId?: string | null): Promise<AssetRecord[]> {
    return invoke('ingest_text', { title, text, sourceUrl: sourceUrl ?? null, targetFolderId: targetFolderId ?? null, targetBoardId: targetBoardId ?? null });
  }

  ingestSwatch(hex: string, title?: string | null, targetFolderId?: string | null, targetBoardId?: string | null): Promise<AssetRecord[]> {
    return invoke('ingest_swatch', { hex, title: title ?? null, targetFolderId: targetFolderId ?? null, targetBoardId: targetBoardId ?? null });
  }

  ingestImageBase64(dataBase64: string, suggestedName: string, sourceUrl?: string | null, targetFolderId?: string | null, targetBoardId?: string | null): Promise<AssetRecord[]> {
    return invoke('ingest_image_base64', { dataBase64, suggestedName, sourceUrl: sourceUrl ?? null, targetFolderId: targetFolderId ?? null, targetBoardId: targetBoardId ?? null });
  }

  updateAssets(patch: AssetBatchPatch): Promise<AssetRecord[]> {
    return invoke('update_assets', { patch });
  }

  permanentlyDeleteAssets(ids: string[]): Promise<void> {
    return invoke('permanently_delete_assets', { ids });
  }

  markAssetOpened(id: string): Promise<AssetRecord | null> {
    return invoke('mark_asset_opened', { id });
  }

  similarAssets(assetId: string, limit = 12): Promise<ScoredAsset[]> {
    return invoke('similar_assets', { assetId, limit });
  }

  suggestFolder(assetId: string): Promise<FolderSuggestion | null> {
    return invoke('suggest_folder', { assetId });
  }

  hydrateImageMetadata(id: string): Promise<AssetRecord | null> {
    return invoke('hydrate_image_metadata', { id });
  }

  refreshRichAsset(id: string): Promise<AssetRecord> {
    return invoke('refresh_rich_asset', { id });
  }

  fetchFolders(): Promise<FolderRecord[]> {
    return invoke('fetch_folders');
  }

  createFolder(name: string, parentId?: string | null): Promise<FolderRecord> {
    return invoke('create_folder', { name, parentId: parentId ?? null });
  }

  renameFolder(id: string, newName: string): Promise<FolderRecord> {
    return invoke('rename_folder', { id, newName });
  }

  moveFolder(id: string, newParentId: string | null, insertAtIndex?: number | null): Promise<FolderRecord[]> {
    return invoke('move_folder', { id, newParentId, insertAtIndex: insertAtIndex ?? null });
  }

  updateFolderAppearance(id: string, colorHex: string | null, customSymbol: string | null): Promise<FolderRecord> {
    return invoke('update_folder_appearance', { id, colorHex, customSymbol });
  }

  deleteFolder(id: string, trashContents = false): Promise<void> {
    return invoke('delete_folder', { id, trashContents });
  }

  fetchSmartFolders(): Promise<SmartFolderRecord[]> {
    return invoke('fetch_smart_folders');
  }

  saveSmartFolder(folder: SmartFolderRecord): Promise<SmartFolderRecord[]> {
    return invoke('save_smart_folder', { folder });
  }

  deleteSmartFolder(id: string): Promise<SmartFolderRecord[]> {
    return invoke('delete_smart_folder', { id });
  }

  fetchTagCounts(): Promise<TagCount[]> {
    return invoke('fetch_tag_counts');
  }

  inboxCount(): Promise<number> {
    return invoke('inbox_count');
  }

  quickJump(query: string, limit = 24): Promise<QuickJumpMatch[]> {
    return invoke('quick_jump', { query, limit });
  }

  fetchBoards(): Promise<MoodboardSummary[]> {
    return invoke('fetch_boards');
  }

  fetchBoard(id: string): Promise<MoodboardDocument | null> {
    return invoke('fetch_board', { id });
  }

  saveBoard(document: MoodboardDocument): Promise<MoodboardDocument> {
    return invoke('save_board', { document });
  }

  deleteBoard(id: string): Promise<void> {
    return invoke('delete_board', { id });
  }

  setBoardPinnedOffline(id: string, pinned: boolean): Promise<MoodboardDocument> {
    return invoke('set_board_pinned_offline', { id, pinned });
  }

  seedSampleLibraryIfEmpty(): Promise<boolean> {
    return invoke('seed_sample_library_if_empty');
  }

  cacheStats(): Promise<CacheStats> {
    return invoke('cache_stats');
  }

  setCacheBudgetBytes(bytes: number): Promise<number> {
    return invoke('set_cache_budget_bytes', { bytes });
  }

  evictCacheNow(): Promise<CacheStats> {
    return invoke('evict_cache_now');
  }

  readAssetTextContent(id: string): Promise<string | null> {
    return invoke('read_asset_text_content', { id });
  }

  revealInExplorer(id: string): Promise<void> {
    return invoke('reveal_in_explorer', { id });
  }

  openExternalUrl(url: string): Promise<void> {
    return invoke('open_external_url', { url });
  }

  async pickFilesDialog(): Promise<string[]> {
    const selected = await openDialog({ multiple: true, directory: false });
    if (!selected) return [];
    return Array.isArray(selected) ? selected : [selected];
  }

  syncConfig(): Promise<DriveSyncConfig> {
    return invoke('sync_config');
  }

  saveSyncConfig(config: DriveSyncConfig): Promise<void> {
    return invoke('save_sync_config', { config });
  }

  syncStatus(): Promise<SyncStatus> {
    return invoke('sync_status');
  }

  syncNow(): Promise<SyncReport> {
    return invoke('sync_now');
  }

  setWindowTheme(isDark: boolean): Promise<WindowSurfaceState> {
    return invoke('set_window_theme', { isDark });
  }

  setMaximizeButtonRect(rect: ClientRect | null): Promise<void> {
    return invoke('set_maximize_button_rect', { rect });
  }

  windowMinimize(): Promise<void> {
    return invoke('window_minimize');
  }

  windowToggleMaximize(): Promise<boolean> {
    return invoke('window_toggle_maximize');
  }

  windowClose(): Promise<void> {
    return invoke('window_close');
  }

  windowIsMaximized(): Promise<boolean> {
    return invoke('window_is_maximized');
  }

  async subscribeEvents(handlers: CharkleEventHandlers): Promise<() => void> {
    const unsubs: UnlistenFn[] = [];
    if (handlers.onLibraryChanged) {
      unsubs.push(await listen('library:changed', () => handlers.onLibraryChanged?.()));
    }
    if (handlers.onSyncStatus) {
      unsubs.push(await listen<SyncStatus>('sync:status', (e) => handlers.onSyncStatus?.(e.payload)));
    }
    if (handlers.onAssetEnriched) {
      unsubs.push(await listen<string>('asset:enriched', (e) => handlers.onAssetEnriched?.(e.payload)));
    }
    if (handlers.onBoardUpdated) {
      unsubs.push(await listen<string>('board:updated', (e) => handlers.onBoardUpdated?.(e.payload)));
    }
    return () => {
      for (const u of unsubs) u();
    };
  }
}

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

function makeSvgDataUrl(bg: string, accent: string, title: string, w = 480, h = 360): string {
  const svg = `<svg xmlns="http://www.w3.org/2000/svg" width="${w}" height="${h}"><rect width="100%" height="100%" fill="${bg}"/><circle cx="${Math.round(w * 0.65)}" cy="${Math.round(h * 0.38)}" r="${Math.round(Math.min(w, h) * 0.25)}" fill="${accent}" opacity="0.85"/><text x="24" y="${h - 28}" fill="#ffffff" font-family="sans-serif" font-size="16" opacity="0.72">${title.replace(/[<>&]/g, '')}</text></svg>`;
  return `data:image/svg+xml;charset=utf-8,${encodeURIComponent(svg)}`;
}

/**
 * Full in-memory mock transport for Vitest suites and standalone Vite browser previews.
 */
export class InMemoryMockTransport implements CharkleTransport {
  readonly kind = 'mock' as const;
  private assets: AssetRecord[] = [];
  private folders: FolderRecord[] = [];
  private smartFolders: SmartFolderRecord[] = [];
  private boards: MoodboardDocument[] = [];
  private textContent = new Map<string, string>();
  private thumbs = new Map<string, string>();
  private maximized = false;
  private syncCfg: DriveSyncConfig = {
    mode: 'localOnly',
    rootFolderName: 'Charkle',
    sharedFolderURLOrID: '',
    mountPath: 'G:\\',
    useGDirectIPAcceleration: true,
    webDAVServerURL: '',
    webDAVUsername: '',
    webDAVRemotePath: '/Charkle',
    localLibraryPath: 'Pictures\\Charkle',
    autoSyncIntervalSeconds: 120,
    syncThumbnails: true,
    syncEmbeddings: true,
  };

  constructor(seed = true) {
    if (seed) {
      this.seedSync();
    }
  }

  private seedSync() {
    const now = msToCocoaSeconds(Date.now());
    const fUi: FolderRecord = {
      id: '10000000-0000-4000-8000-000000000001',
      name: 'UI Inspiration',
      parentID: null,
      sortOrder: 0,
      assetCount: 2,
      colorHex: '#2A60E0',
      customSymbol: 'sf:paintbrush.fill',
      createdAt: now,
      updatedAt: now,
    };
    const fTypo: FolderRecord = {
      id: '10000000-0000-4000-8000-000000000002',
      name: 'Typography',
      parentID: fUi.id,
      sortOrder: 0,
      assetCount: 1,
      colorHex: '#E04F44',
      customSymbol: null,
      createdAt: now,
      updatedAt: now,
    };
    this.folders = [fUi, fTypo];

    const a1: AssetRecord = {
      id: '20000000-0000-4000-8000-000000000001',
      contentHash: 'hash1',
      folderID: null,
      mediaKind: 'image',
      mimeType: 'image/png',
      title: '暖调建筑海报参考',
      fileName: 'warm-poster.png',
      notes: '低角度自然光阴影与瑞士排版节奏',
      tags: ['海报', '暖色调', '建筑'],
      suggestedTags: ['editorial'],
      rating: 5,
      pixelWidth: 1200,
      pixelHeight: 1600,
      fileSizeBytes: 245_000,
      dominantColors: [
        { hex: '#BA6B55', l: 55, a: 28, b: 22, proportion: 0.55 },
        { hex: '#F2ECE3', l: 93, a: 1, b: 5, proportion: 0.45 },
      ],
      waveformPeaks: [],
      richMetadata: {
        photoExif: {
          cameraMake: 'Fujifilm',
          cameraModel: 'X-T5',
          lensModel: 'XF35mmF1.4 R',
          exposureTime: '1/250s',
          fNumber: 2.0,
          iso: 160,
          focalLengthMM: 35,
        },
        aiGeneration: {
          generator: 'ComfyUI',
          prompt: 'warm limestone courtyard, morning shadow, minimalist architecture',
          negativePrompt: 'blurry, oversaturated',
          modelName: 'flux1-dev',
          sampler: 'euler',
          steps: 24,
          cfgScale: 6.5,
          seed: '424242',
          loras: ['arch_light_v2'],
          extraParameters: {},
        },
      },
      pinnedOffline: true,
      isLocalOriginalCached: true,
      isTrashed: false,
      createdAt: now - 3600,
      updatedAt: now - 3600,
      updatedHLC: 1,
    };
    const a2: AssetRecord = {
      id: '20000000-0000-4000-8000-000000000002',
      contentHash: 'hash2',
      folderID: fUi.id,
      mediaKind: 'webBookmark',
      mimeType: 'text/uri-list',
      title: 'tauri-apps/tauri',
      fileName: 'tauri-apps-tauri.url',
      notes: 'Build smaller, faster, and more secure desktop applications',
      tags: ['GitHub', 'Rust'],
      suggestedTags: [],
      rating: 4,
      pixelWidth: 1280,
      pixelHeight: 640,
      fileSizeBytes: 120,
      dominantColors: [{ hex: '#2A60E0', l: 44, a: 18, b: -58, proportion: 1.0 }],
      waveformPeaks: [],
      sourceURL: 'https://github.com/tauri-apps/tauri',
      sourceDomain: 'github.com',
      richMetadata: {
        githubRepo: {
          owner: 'tauri-apps',
          repo: 'tauri',
          fullName: 'tauri-apps/tauri',
          description: 'Build smaller, faster, and more secure desktop applications.',
          language: 'Rust',
          stars: 92000,
          forks: 2800,
          openIssues: 420,
          license: 'MIT / Apache-2.0',
          topics: ['rust', 'webview', 'desktop'],
          readmeMarkdown: '# Tauri\n\nBuild native Windows desktop applications with Rust + WebView2.',
        },
      },
      pinnedOffline: false,
      isLocalOriginalCached: true,
      isTrashed: false,
      createdAt: now - 1800,
      updatedAt: now - 1800,
      updatedHLC: 2,
    };
    const a3: AssetRecord = {
      id: '20000000-0000-4000-8000-000000000003',
      contentHash: 'hash3',
      folderID: fTypo.id,
      mediaKind: 'document',
      mimeType: 'text/markdown',
      title: '设计系统笔记',
      fileName: 'design-notes.md',
      notes: '中英文排版与中性画布原则',
      tags: ['排版'],
      suggestedTags: [],
      rating: 4,
      pixelWidth: 800,
      pixelHeight: 1000,
      fileSizeBytes: 1024,
      dominantColors: [{ hex: '#1E2024', l: 13, a: 0, b: -2, proportion: 1.0 }],
      waveformPeaks: [],
      richMetadata: {
        isMarkdown: true,
        textExcerpt: '# Charkle\n\n90–95% 中性画布，作品绝对主角。',
      },
      pinnedOffline: false,
      isLocalOriginalCached: true,
      isTrashed: false,
      createdAt: now - 900,
      updatedAt: now - 900,
      updatedHLC: 3,
    };
    const a4: AssetRecord = {
      id: '20000000-0000-4000-8000-000000000004',
      contentHash: 'hash4',
      folderID: fUi.id,
      mediaKind: 'image',
      mimeType: 'image/png',
      title: '超长信息图预览',
      fileName: 'long-strip-ui.png',
      notes: '长条形网页落地页截图',
      tags: ['landing-page'],
      suggestedTags: [],
      rating: 5,
      pixelWidth: 800,
      pixelHeight: 2800,
      fileSizeBytes: 620_000,
      dominantColors: [{ hex: '#3D5A80', l: 38, a: -2, b: -24, proportion: 1.0 }],
      waveformPeaks: [],
      pinnedOffline: false,
      isLocalOriginalCached: true,
      isTrashed: false,
      createdAt: now - 300,
      updatedAt: now - 300,
      updatedHLC: 4,
    };

    this.assets = [a1, a2, a3, a4];
    this.textContent.set(a3.id, '# Charkle 设计系统笔记\n\n- 90–95% 中性画布\n- 严禁紫罗兰渐变\n- 4pt 网格与同心圆角');
    this.thumbs.set(a1.id, makeSvgDataUrl('#BA6B55', '#F2ECE3', a1.title, 400, 533));
    this.thumbs.set(a2.id, makeSvgDataUrl('#141824', '#2A60E0', a2.title, 520, 260));
    this.thumbs.set(a3.id, makeSvgDataUrl('#1E2024', '#5B8DEF', a3.title, 400, 500));
    this.thumbs.set(a4.id, makeSvgDataUrl('#192438', '#4E7D96', a4.title, 400, 1400));

    this.smartFolders = [
      {
        id: '30000000-0000-4000-8000-000000000001',
        name: '高分精选',
        colorHex: '#2A60E0',
        rule: {
          matchMode: 'all',
          tags: [],
          descriptionQuery: '',
          colorHexes: [],
          colorTolerance: 24,
          mediaKinds: [],
          minRating: 5,
        },
        sortOrder: 0,
        createdAt: now,
        updatedAt: now,
      },
    ];

    this.boards = [
      {
        id: '40000000-0000-4000-8000-000000000001',
        title: '光、纸与泥 · Light, Paper & Clay',
        subtitle: '材质与构图参考',
        mode: { freeform: {} },
        nodes: [],
        connectors: [],
        inkStrokes: [],
        extractedPalette: a1.dominantColors,
        candidateAssetIDs: [a1.id],
        pinnedOffline: false,
        viewportCenter: { x: 480, y: 320 },
        viewportZoom: 1,
        createdAt: now,
        updatedAt: now,
        updatedHLC: 1,
      },
    ];
  }

  thumbnailUrl(assetId: string): string {
    return this.thumbs.get(assetId) ?? makeSvgDataUrl('#24272C', '#5B8DEF', 'Charkle');
  }

  originalUrl(assetId: string): string {
    return this.thumbnailUrl(assetId);
  }

  async fetchAssets(criteria: FilterCriteria): Promise<AssetRecord[]> {
    let list = [...this.assets];
    if (criteria.onlyTrashed) {
      list = list.filter((a) => a.isTrashed);
    } else if (!criteria.includeTrashed) {
      list = list.filter((a) => !a.isTrashed);
    }
    if (criteria.onlyInbox) {
      list = list.filter((a) => !a.folderID);
    } else if (criteria.folderID) {
      const ids = new Set<string>([criteria.folderID]);
      if (criteria.includeSubfolders) {
        let added = true;
        while (added) {
          added = false;
          for (const f of this.folders) {
            if (f.parentID && ids.has(f.parentID) && !ids.has(f.id)) {
              ids.add(f.id);
              added = true;
            }
          }
        }
      }
      list = list.filter((a) => a.folderID && ids.has(a.folderID));
    }
    if (criteria.onlyUntagged) list = list.filter((a) => a.tags.length === 0);
    if (criteria.onlyPinnedOffline) list = list.filter((a) => a.pinnedOffline);
    if (criteria.kinds.length > 0) list = list.filter((a) => criteria.kinds.includes(a.mediaKind));
    if (criteria.minRating > 0) list = list.filter((a) => a.rating >= criteria.minRating);
    if (criteria.tags.length > 0) {
      list = list.filter((a) =>
        criteria.tags.every((t) => a.tags.some((at) => at.toLowerCase() === t.toLowerCase())),
      );
    }
    if (criteria.searchQuery.trim()) {
      const q = criteria.searchQuery.trim().toLowerCase();
      list = list.filter((a) =>
        [a.title, a.fileName, a.notes, a.tags.join(' '), a.richMetadata?.githubRepo?.readmeMarkdown ?? '']
          .join(' ')
          .toLowerCase()
          .includes(q),
      );
    }
    if (criteria.sortBy === 'oldest') {
      list.sort((a, b) => wireDateToMs(a.createdAt) - wireDateToMs(b.createdAt));
    } else if (criteria.sortBy === 'nameAsc') {
      list.sort((a, b) => a.title.localeCompare(b.title));
    } else if (criteria.sortBy === 'ratingDesc') {
      list.sort((a, b) => b.rating - a.rating);
    } else if (criteria.sortBy === 'fileSizeDesc') {
      list.sort((a, b) => b.fileSizeBytes - a.fileSizeBytes);
    } else {
      list.sort((a, b) => wireDateToMs(b.createdAt) - wireDateToMs(a.createdAt));
    }
    return list;
  }

  async fetchAsset(id: string): Promise<AssetRecord | null> {
    return this.assets.find((a) => a.id === id) ?? null;
  }

  async ingestFiles(paths: string[], targetFolderId?: string | null): Promise<AssetRecord[]> {
    const now = msToCocoaSeconds(Date.now());
    const created = paths.map((p) => {
      const name = p.split(/[\\/]/).pop() ?? 'Untitled.png';
      const id = makeUuid();
      const asset: AssetRecord = {
        id,
        contentHash: id,
        folderID: targetFolderId ?? null,
        mediaKind: 'image',
        mimeType: 'image/png',
        title: name.replace(/\.[^.]+$/, ''),
        fileName: name,
        notes: '',
        tags: [],
        suggestedTags: [],
        rating: 0,
        pixelWidth: 800,
        pixelHeight: 600,
        fileSizeBytes: 12000,
        dominantColors: [{ hex: '#2A60E0', l: 44, a: 18, b: -58, proportion: 1 }],
        waveformPeaks: [],
        pinnedOffline: false,
        isLocalOriginalCached: true,
        isTrashed: false,
        createdAt: now,
        updatedAt: now,
        updatedHLC: 10,
      };
      this.thumbs.set(id, makeSvgDataUrl('#24272C', '#2A60E0', asset.title));
      return asset;
    });
    this.assets = [...created, ...this.assets];
    return created;
  }

  async ingestUrl(url: string, title?: string | null, notes?: string | null, targetFolderId?: string | null): Promise<AssetRecord[]> {
    const now = msToCocoaSeconds(Date.now());
    const id = makeUuid();
    const asset: AssetRecord = {
      id,
      contentHash: id,
      folderID: targetFolderId ?? null,
      mediaKind: 'webBookmark',
      mimeType: 'text/uri-list',
      title: title || url,
      fileName: 'bookmark.url',
      notes: notes ?? '',
      tags: [],
      suggestedTags: [],
      rating: 0,
      pixelWidth: 1200,
      pixelHeight: 630,
      fileSizeBytes: 256,
      dominantColors: [],
      waveformPeaks: [],
      sourceURL: url,
      sourceDomain: url.replace(/^https?:\/\//, '').split('/')[0] ?? '',
      pinnedOffline: false,
      isLocalOriginalCached: true,
      isTrashed: false,
      createdAt: now,
      updatedAt: now,
      updatedHLC: 11,
    };
    this.thumbs.set(id, makeSvgDataUrl('#1E2025', '#5B8DEF', asset.title));
    this.assets = [asset, ...this.assets];
    return [asset];
  }

  async ingestText(title: string, text: string, _sourceUrl?: string | null, targetFolderId?: string | null): Promise<AssetRecord[]> {
    const now = msToCocoaSeconds(Date.now());
    const id = makeUuid();
    const asset: AssetRecord = {
      id,
      contentHash: id,
      folderID: targetFolderId ?? null,
      mediaKind: 'document',
      mimeType: 'text/markdown',
      title: title || '文本笔记',
      fileName: `${title || 'note'}.md`,
      notes: '',
      tags: [],
      suggestedTags: [],
      rating: 0,
      pixelWidth: 640,
      pixelHeight: 800,
      fileSizeBytes: text.length,
      dominantColors: [],
      waveformPeaks: [],
      richMetadata: { isMarkdown: true, textExcerpt: text.slice(0, 400) },
      pinnedOffline: false,
      isLocalOriginalCached: true,
      isTrashed: false,
      createdAt: now,
      updatedAt: now,
      updatedHLC: 12,
    };
    this.textContent.set(id, text);
    this.thumbs.set(id, makeSvgDataUrl('#1E2025', '#6B8E76', asset.title));
    this.assets = [asset, ...this.assets];
    return [asset];
  }

  async ingestSwatch(hex: string, title?: string | null, targetFolderId?: string | null): Promise<AssetRecord[]> {
    const now = msToCocoaSeconds(Date.now());
    const id = makeUuid();
    const clean = hex.startsWith('#') ? hex.toUpperCase() : `#${hex.toUpperCase()}`;
    const asset: AssetRecord = {
      id,
      contentHash: id,
      folderID: targetFolderId ?? null,
      mediaKind: 'image',
      mimeType: 'image/png',
      title: title || clean,
      fileName: `${clean}.png`,
      notes: '',
      tags: [],
      suggestedTags: [],
      rating: 0,
      pixelWidth: 600,
      pixelHeight: 600,
      fileSizeBytes: 2048,
      dominantColors: [{ hex: clean, l: 50, a: 0, b: 0, proportion: 1 }],
      waveformPeaks: [],
      pinnedOffline: false,
      isLocalOriginalCached: true,
      isTrashed: false,
      createdAt: now,
      updatedAt: now,
      updatedHLC: 13,
    };
    this.thumbs.set(id, makeSvgDataUrl(clean, '#ffffff', asset.title, 400, 400));
    this.assets = [asset, ...this.assets];
    return [asset];
  }

  async ingestImageBase64(_dataBase64: string, suggestedName: string, _sourceUrl?: string | null, targetFolderId?: string | null): Promise<AssetRecord[]> {
    return this.ingestFiles([suggestedName], targetFolderId);
  }

  async updateAssets(patch: AssetBatchPatch): Promise<AssetRecord[]> {
    const changed: AssetRecord[] = [];
    this.assets = this.assets.map((a) => {
      if (!patch.assetIDs.includes(a.id)) return a;
      const next: AssetRecord = { ...a };
      if (patch.title) next.title = patch.title;
      if (patch.notes != null) next.notes = patch.notes;
      if (patch.rating != null) next.rating = patch.rating;
      if (patch.pinnedOffline != null) next.pinnedOffline = patch.pinnedOffline;
      if (patch.isTrashed != null) next.isTrashed = patch.isTrashed;
      if (patch.folderAssignment === 'inbox') next.folderID = null;
      else if (patch.folderAssignment && typeof patch.folderAssignment === 'object') {
        next.folderID = patch.folderAssignment.folder;
      }
      const tags = new Set(next.tags);
      if (patch.acceptSuggestedTags) {
        for (const s of next.suggestedTags) tags.add(s);
        next.suggestedTags = [];
      }
      for (const t of patch.addTags ?? []) tags.add(t.trim());
      for (const t of patch.removeTags ?? []) tags.delete(t.trim());
      next.tags = [...tags].filter(Boolean).sort();
      changed.push(next);
      return next;
    });
    return changed;
  }

  async permanentlyDeleteAssets(ids: string[]): Promise<void> {
    const del = new Set(ids);
    this.assets = this.assets.filter((a) => !del.has(a.id));
  }

  async markAssetOpened(id: string): Promise<AssetRecord | null> {
    const asset = this.assets.find((a) => a.id === id);
    if (asset) asset.lastOpenedAt = msToCocoaSeconds(Date.now());
    return asset ?? null;
  }

  async similarAssets(assetId: string, limit = 12): Promise<ScoredAsset[]> {
    return this.assets
      .filter((a) => a.id !== assetId && !a.isTrashed)
      .slice(0, limit)
      .map((asset, i) => ({ asset, score: Math.max(0.4, 0.9 - i * 0.1), matchReasons: ['相近色板'] }));
  }

  async suggestFolder(assetId: string): Promise<FolderSuggestion | null> {
    const asset = this.assets.find((a) => a.id === assetId);
    const first = this.folders[0];
    if (!asset || !first) return null;
    return {
      folderID: first.id,
      folderName: first.name,
      confidence: 0.78,
      reason: '与该目录素材风格相近',
    };
  }

  async hydrateImageMetadata(id: string): Promise<AssetRecord | null> {
    return this.fetchAsset(id);
  }

  async refreshRichAsset(id: string): Promise<AssetRecord> {
    const found = this.assets.find((a) => a.id === id);
    if (!found) throw new Error('Asset not found');
    return found;
  }

  async fetchFolders(): Promise<FolderRecord[]> {
    return this.folders.map((f) => ({
      ...f,
      assetCount: this.assets.filter((a) => !a.isTrashed && a.folderID === f.id).length,
    }));
  }

  async createFolder(name: string, parentId?: string | null): Promise<FolderRecord> {
    const now = msToCocoaSeconds(Date.now());
    const f: FolderRecord = {
      id: makeUuid(),
      name,
      parentID: parentId ?? null,
      sortOrder: this.folders.length,
      assetCount: 0,
      createdAt: now,
      updatedAt: now,
    };
    this.folders = [...this.folders, f];
    return f;
  }

  async renameFolder(id: string, newName: string): Promise<FolderRecord> {
    const found = this.folders.find((f) => f.id === id);
    if (!found) throw new Error('Folder not found');
    found.name = newName;
    return { ...found };
  }

  async moveFolder(id: string, newParentId: string | null): Promise<FolderRecord[]> {
    this.folders = this.folders.map((f) => (f.id === id ? { ...f, parentID: newParentId } : f));
    return this.fetchFolders();
  }

  async updateFolderAppearance(id: string, colorHex: string | null, customSymbol: string | null): Promise<FolderRecord> {
    const found = this.folders.find((f) => f.id === id);
    if (!found) throw new Error('Folder not found');
    found.colorHex = colorHex;
    found.customSymbol = customSymbol;
    return { ...found };
  }

  async deleteFolder(id: string, trashContents = false): Promise<void> {
    this.folders = this.folders.filter((f) => f.id !== id);
    this.assets = this.assets.map((a) =>
      a.folderID === id ? { ...a, folderID: null, isTrashed: trashContents ? true : a.isTrashed } : a,
    );
  }

  async fetchSmartFolders(): Promise<SmartFolderRecord[]> {
    return [...this.smartFolders];
  }

  async saveSmartFolder(folder: SmartFolderRecord): Promise<SmartFolderRecord[]> {
    const exists = this.smartFolders.some((s) => s.id === folder.id);
    this.smartFolders = exists
      ? this.smartFolders.map((s) => (s.id === folder.id ? folder : s))
      : [...this.smartFolders, folder];
    return [...this.smartFolders];
  }

  async deleteSmartFolder(id: string): Promise<SmartFolderRecord[]> {
    this.smartFolders = this.smartFolders.filter((s) => s.id !== id);
    return [...this.smartFolders];
  }

  async fetchTagCounts(): Promise<TagCount[]> {
    const counts = new Map<string, number>();
    for (const a of this.assets) {
      if (a.isTrashed) continue;
      for (const t of a.tags) counts.set(t, (counts.get(t) ?? 0) + 1);
    }
    return [...counts.entries()]
      .map(([name, count]) => ({ name, count }))
      .sort((a, b) => b.count - a.count || a.name.localeCompare(b.name));
  }

  async inboxCount(): Promise<number> {
    return this.assets.filter((a) => !a.isTrashed && !a.folderID).length;
  }

  async quickJump(query: string, limit = 24): Promise<QuickJumpMatch[]> {
    const q = query.trim().toLowerCase();
    const out: QuickJumpMatch[] = [];
    for (const f of this.folders) {
      if (!q || f.name.toLowerCase().includes(q)) {
        out.push({ id: `folder-${f.id}`, kind: 'folder', title: f.name, subtitle: '文件夹', targetUUID: f.id, score: 0.9 });
      }
    }
    for (const b of this.boards) {
      if (!q || b.title.toLowerCase().includes(q)) {
        out.push({ id: `moodboard-${b.id}`, kind: 'moodboard', title: b.title, subtitle: `情绪板 · ${b.nodes.length} 项`, targetUUID: b.id, score: 0.85 });
      }
    }
    for (const t of await this.fetchTagCounts()) {
      if (!q || t.name.toLowerCase().includes(q)) {
        out.push({ id: `tag-${t.name}`, kind: 'tag', title: t.name, subtitle: `标签 · ${t.count} 项`, tagName: t.name, score: 0.8 });
      }
    }
    for (const a of this.assets.filter((x) => !x.isTrashed)) {
      if (!q || a.title.toLowerCase().includes(q) || a.notes.toLowerCase().includes(q)) {
        out.push({ id: `asset-${a.id}`, kind: 'asset', title: a.title, subtitle: a.fileName, targetUUID: a.id, score: 0.75 });
      }
    }
    return out.slice(0, limit);
  }

  async fetchBoards(): Promise<MoodboardSummary[]> {
    return this.boards.map((b) => ({
      id: b.id,
      title: b.title,
      subtitle: b.subtitle,
      itemCount: b.nodes.length,
      previewAssetIDs: b.candidateAssetIDs.slice(0, 4),
      paletteHexes: b.extractedPalette.map((c) => c.hex),
      pinnedOffline: b.pinnedOffline,
      updatedAt: b.updatedAt,
    }));
  }

  async fetchBoard(id: string): Promise<MoodboardDocument | null> {
    return this.boards.find((b) => b.id === id) ?? null;
  }

  async saveBoard(doc: MoodboardDocument): Promise<MoodboardDocument> {
    const idx = this.boards.findIndex((b) => b.id === doc.id);
    if (idx >= 0) this.boards[idx] = doc;
    else this.boards.push(doc);
    return doc;
  }

  async deleteBoard(id: string): Promise<void> {
    this.boards = this.boards.filter((b) => b.id !== id);
  }

  async setBoardPinnedOffline(id: string, pinned: boolean): Promise<MoodboardDocument> {
    const b = this.boards.find((x) => x.id === id);
    if (!b) throw new Error('Board not found');
    b.pinnedOffline = pinned;
    return { ...b };
  }

  async seedSampleLibraryIfEmpty(): Promise<boolean> {
    return false;
  }

  async cacheStats(): Promise<CacheStats> {
    return {
      thumbnailBytes: 1_200_000,
      originalCacheBytes: 12_400_000,
      pinnedOfflineBytes: 245_000,
      budgetBytes: 10 * 1024 * 1024 * 1024,
      cachedOriginalCount: this.assets.length,
      pinnedAssetCount: this.assets.filter((a) => a.pinnedOffline).length,
    };
  }

  async setCacheBudgetBytes(bytes: number): Promise<number> {
    return bytes;
  }

  async evictCacheNow(): Promise<CacheStats> {
    return this.cacheStats();
  }

  async readAssetTextContent(id: string): Promise<string | null> {
    return this.textContent.get(id) ?? null;
  }

  async revealInExplorer(): Promise<void> {}
  async openExternalUrl(): Promise<void> {}
  async pickFilesDialog(): Promise<string[]> {
    return [];
  }

  async syncConfig(): Promise<DriveSyncConfig> {
    return { ...this.syncCfg };
  }

  async saveSyncConfig(config: DriveSyncConfig): Promise<void> {
    this.syncCfg = { ...config };
  }

  async syncStatus(): Promise<SyncStatus> {
    return { phase: 'idle', pendingOpCount: 0, activeMode: this.syncCfg.mode };
  }

  async syncNow(): Promise<SyncReport> {
    return {
      uploadedOps: 0,
      downloadedOps: 0,
      discoveredRemoteAssets: 0,
      discoveredAssetIDs: [],
      updatedBoards: 0,
      reconciledRenames: 0,
      durationSeconds: 0.01,
    };
  }

  async setWindowTheme(isDark: boolean): Promise<WindowSurfaceState> {
    return {
      buildNumber: 22631,
      backdrop: 'mica',
      isDark,
      transparencyEnabled: true,
      animationsEnabled: true,
      snapLayoutsSupported: true,
    };
  }

  async setMaximizeButtonRect(): Promise<void> {}
  async windowMinimize(): Promise<void> {}
  async windowToggleMaximize(): Promise<boolean> {
    this.maximized = !this.maximized;
    return this.maximized;
  }
  async windowClose(): Promise<void> {}
  async windowIsMaximized(): Promise<boolean> {
    return this.maximized;
  }

  async subscribeEvents(): Promise<() => void> {
    return () => {};
  }

  /** Helper for tests inspecting smart folder evaluation. */
  filterBySmartFolder(rule: SmartFolderRecord['rule']): AssetRecord[] {
    return this.assets.filter((a) => matchesSmartFolderRule(a, rule));
  }
}

let activeTransport: CharkleTransport = isTauriRuntime()
  ? new TauriTransport()
  : new InMemoryMockTransport(true);

export function getTransport(): CharkleTransport {
  return activeTransport;
}

export function setTransport(transport: CharkleTransport): void {
  activeTransport = transport;
}
