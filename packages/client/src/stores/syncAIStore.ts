import { create } from 'zustand';
import {
  activeStorageLocationSummary,
  createDefaultAIProviderConfig,
  createDefaultCacheStats,
  createDefaultCloudAIUsageSummary,
  createDefaultExternalAgentConfig,
  createDefaultSyncStatus,
  createDefaultTypeSafeExperimentalConfig,
} from '@charkle/shared';
import type {
  AIProviderConfig,
  CacheStats,
  ChatGPTAccountSession,
  ChatGPTModelInfo,
  CloudAIProviderKind,
  CloudAIUsageCategory,
  CloudAIUsageSummary,
  DriveSyncConfig,
  ExternalAgentConfig,
  RuntimeFeatures,
  RuntimeMode,
  StorageMigrationReport,
  SyncReport,
  SyncStatus,
  TypeSafeExperimentalConfig,
  TypeSafeModelInfo,
  UUID,
} from '@charkle/shared';
import { apiClient } from '../api/client';

const DEFAULT_RUNTIME_FEATURES: RuntimeFeatures = {
  localFolder: true,
  clientExportPreferred: false,
  googleDrive: true,
  webdav: true,
};

interface SyncAIState {
  sseConnected: boolean;

  runtimeMode: RuntimeMode;
  runtimeFeatures: RuntimeFeatures;
  runtimeLoaded: boolean;

  syncStatus: SyncStatus;
  syncConfig: DriveSyncConfig | null;
  hasGoogleOAuthConfig: boolean;
  hasWebDAVPassword: boolean;
  activeStorageSummary: string;
  isSyncingNow: boolean;
  lastSyncReport: SyncReport | null;

  aiConfig: AIProviderConfig;
  hasStoredAIKeys: Record<CloudAIProviderKind, boolean>;
  aiUsage: CloudAIUsageSummary;
  chatGPTSession: ChatGPTAccountSession | null;
  chatGPTModels: ChatGPTModelInfo[];
  isLoadingChatGPTModels: boolean;
  isTestingAI: boolean;
  isRebuildingVisualIndex: boolean;
  rebuildVisualIndexProgress: { completed: number; total: number } | null;

  typeSafeConfig: TypeSafeExperimentalConfig;
  hasStoredTypeSafeKey: boolean;
  typeSafeModels: TypeSafeModelInfo[];

  cacheStats: CacheStats;
  externalAgentConfig: ExternalAgentConfig;

  setSSEConnected: (connected: boolean) => void;
  setSyncStatus: (status: SyncStatus) => void;
  setSyncCompleted: (report: SyncReport, status: SyncStatus) => void;
  setAIConfigSnapshot: (config: AIProviderConfig) => void;
  loadRuntimeInfo: () => Promise<void>;

  loadSyncConfig: () => Promise<void>;
  saveSyncConfig: (config: DriveSyncConfig, webDAVPassword?: string | null) => Promise<void>;
  syncNow: () => Promise<SyncReport>;
  migrateStorage: (
    targetConfig: DriveSyncConfig,
    webDAVPassword?: string | null,
  ) => Promise<StorageMigrationReport>;

  loadAIConfig: () => Promise<void>;
  saveAIConfig: (config: AIProviderConfig, apiKey?: string | null) => Promise<void>;
  resetAIUsage: (category?: CloudAIUsageCategory | null) => Promise<void>;
  testAIConnection: (config: AIProviderConfig, apiKey?: string | null) => Promise<string>;
  connectChatGPT: (req: {
    accessToken: string;
    email?: string | null;
    name?: string | null;
  }) => Promise<void>;
  disconnectChatGPT: () => Promise<void>;
  refreshChatGPTModels: () => Promise<ChatGPTModelInfo[]>;
  rebuildLocalVisualIndex: (assetIDs: UUID[]) => Promise<number>;

  loadTypeSafeConfig: () => Promise<void>;
  saveTypeSafeConfig: (config: TypeSafeExperimentalConfig, apiKey?: string | null) => Promise<void>;
  testTypeSafeConnection: (
    config: TypeSafeExperimentalConfig,
    apiKey?: string | null,
  ) => Promise<TypeSafeModelInfo[]>;

  loadCacheStats: () => Promise<void>;
  updateCacheBudget: (budgetBytes: number) => Promise<void>;
  evictCacheNow: () => Promise<void>;

  loadExternalAgentConfig: () => Promise<void>;
  saveExternalAgentConfig: (config: ExternalAgentConfig) => Promise<void>;
}

export const useSyncAIStore = create<SyncAIState>((set, get) => ({
  sseConnected: false,

  runtimeMode: 'node',
  runtimeFeatures: DEFAULT_RUNTIME_FEATURES,
  runtimeLoaded: false,

  syncStatus: createDefaultSyncStatus(),
  syncConfig: null,
  hasGoogleOAuthConfig: false,
  hasWebDAVPassword: false,
  activeStorageSummary: '.charkle-data/library',
  isSyncingNow: false,
  lastSyncReport: null,

  aiConfig: createDefaultAIProviderConfig(),
  hasStoredAIKeys: {
    disabled: false,
    chatGPTSubscription: false,
    gemini: false,
    openAICompatible: false,
  },
  aiUsage: createDefaultCloudAIUsageSummary(),
  chatGPTSession: null,
  chatGPTModels: [],
  isLoadingChatGPTModels: false,
  isTestingAI: false,
  isRebuildingVisualIndex: false,
  rebuildVisualIndexProgress: null,

  typeSafeConfig: createDefaultTypeSafeExperimentalConfig(),
  hasStoredTypeSafeKey: false,
  typeSafeModels: [],

  cacheStats: createDefaultCacheStats(),
  externalAgentConfig: createDefaultExternalAgentConfig(),

  setSSEConnected: (connected) => set({ sseConnected: connected }),
  setSyncStatus: (status) => set({ syncStatus: status }),
  setSyncCompleted: (report, status) =>
    set({ lastSyncReport: report, syncStatus: status, isSyncingNow: false }),
  setAIConfigSnapshot: (config) => set({ aiConfig: config }),

  loadRuntimeInfo: async () => {
    try {
      const health = await apiClient.health();
      const nextMode: RuntimeMode = health.runtimeMode === 'cloudflare' ? 'cloudflare' : 'node';
      const nextFeatures: RuntimeFeatures = {
        localFolder: health.features?.localFolder ?? nextMode !== 'cloudflare',
        clientExportPreferred:
          health.features?.clientExportPreferred ?? nextMode === 'cloudflare',
        googleDrive: health.features?.googleDrive ?? true,
        webdav: health.features?.webdav ?? true,
      };
      set((state) => {
        const nextSummary = state.syncConfig
          ? activeStorageLocationSummary(state.syncConfig, nextMode)
          : nextMode === 'cloudflare'
            ? '内置云存储'
            : state.activeStorageSummary;
        return {
          runtimeMode: nextMode,
          runtimeFeatures: nextFeatures,
          runtimeLoaded: true,
          activeStorageSummary: nextSummary,
        };
      });
    } catch {
      set({ runtimeLoaded: true });
    }
  },

  loadSyncConfig: async () => {
    const res = await apiClient.getSyncConfig();
    const mode = get().runtimeMode;
    const summary =
      res.config.mode === 'localOnly' && mode === 'cloudflare'
        ? '内置云存储'
        : res.activeLocationSummary || activeStorageLocationSummary(res.config, mode);
    set({
      syncConfig: res.config,
      syncStatus: res.status,
      hasGoogleOAuthConfig: res.hasGoogleOAuthConfig,
      hasWebDAVPassword: res.hasWebDAVPassword,
      activeStorageSummary: summary,
    });
  },

  saveSyncConfig: async (config, webDAVPassword) => {
    const res = await apiClient.saveSyncConfig({ config, webDAVPassword });
    const mode = get().runtimeMode;
    const summary =
      res.config.mode === 'localOnly' && mode === 'cloudflare'
        ? '内置云存储'
        : res.activeLocationSummary || activeStorageLocationSummary(res.config, mode);
    set({
      syncConfig: res.config,
      syncStatus: res.status,
      hasGoogleOAuthConfig: res.hasGoogleOAuthConfig,
      hasWebDAVPassword: res.hasWebDAVPassword,
      activeStorageSummary: summary,
    });
  },

  syncNow: async () => {
    set({ isSyncingNow: true });
    try {
      const res = await apiClient.syncNow();
      set({
        lastSyncReport: res.report,
        syncStatus: res.status,
        isSyncingNow: false,
      });
      return res.report;
    } catch (err) {
      set({ isSyncingNow: false });
      throw err;
    }
  },

  migrateStorage: async (targetConfig, webDAVPassword) => {
    const res = await apiClient.migrateStorage({ targetConfig, webDAVPassword });
    const refreshed = await apiClient.getSyncConfig();
    const mode = get().runtimeMode;
    const summary =
      refreshed.config.mode === 'localOnly' && mode === 'cloudflare'
        ? '内置云存储'
        : refreshed.activeLocationSummary || activeStorageLocationSummary(refreshed.config, mode);
    set({
      syncConfig: refreshed.config,
      syncStatus: refreshed.status,
      hasGoogleOAuthConfig: refreshed.hasGoogleOAuthConfig,
      hasWebDAVPassword: refreshed.hasWebDAVPassword,
      activeStorageSummary: summary,
    });
    return res.report;
  },

  loadAIConfig: async () => {
    const res = await apiClient.getAIConfig();
    set({
      aiConfig: res.config,
      hasStoredAIKeys: res.hasStoredKeys,
      aiUsage: res.usage,
      chatGPTSession: res.chatGPTSession,
    });
  },

  saveAIConfig: async (config, apiKey) => {
    const res = await apiClient.saveAIConfig({ config, apiKey });
    set({
      aiConfig: res.config,
      hasStoredAIKeys: res.hasStoredKeys,
      aiUsage: res.usage,
      chatGPTSession: res.chatGPTSession,
    });
  },

  resetAIUsage: async (category = null) => {
    const res = await apiClient.resetAIUsage({ category });
    set({
      aiConfig: res.config,
      hasStoredAIKeys: res.hasStoredKeys,
      aiUsage: res.usage,
      chatGPTSession: res.chatGPTSession,
    });
  },

  testAIConnection: async (config, apiKey = null) => {
    set({ isTestingAI: true });
    try {
      const res = await apiClient.testAIConnection({ config, apiKey });
      if (res.models) {
        set({ chatGPTModels: res.models });
      }
      return res.summary;
    } finally {
      set({ isTestingAI: false });
    }
  },

  connectChatGPT: async (req) => {
    await apiClient.connectChatGPT(req);
    await get().loadAIConfig();
  },

  disconnectChatGPT: async () => {
    await apiClient.disconnectChatGPT();
    set({ chatGPTModels: [] });
    await get().loadAIConfig();
  },

  refreshChatGPTModels: async () => {
    set({ isLoadingChatGPTModels: true });
    try {
      const res = await apiClient.listChatGPTModels();
      set({ chatGPTModels: res.models });
      return res.models;
    } finally {
      set({ isLoadingChatGPTModels: false });
    }
  },

  rebuildLocalVisualIndex: async (assetIDs) => {
    const uniqueIDs = Array.from(new Set(assetIDs));
    if (uniqueIDs.length === 0) return 0;
    const chunkSize = 16;
    let processed = 0;
    set({
      isRebuildingVisualIndex: true,
      rebuildVisualIndexProgress: { completed: 0, total: uniqueIDs.length },
    });
    try {
      for (let i = 0; i < uniqueIDs.length; i += chunkSize) {
        const slice = uniqueIDs.slice(i, i + chunkSize);
        await apiClient.analyzeAssets({ ids: slice, localOnly: true });
        processed = Math.min(uniqueIDs.length, i + slice.length);
        set({
          rebuildVisualIndexProgress: { completed: processed, total: uniqueIDs.length },
        });
      }
      return processed;
    } finally {
      set({
        isRebuildingVisualIndex: false,
        rebuildVisualIndexProgress: null,
      });
    }
  },

  loadTypeSafeConfig: async () => {
    const res = await apiClient.getTypeSafeConfig();
    set({
      typeSafeConfig: res.config,
      hasStoredTypeSafeKey: res.hasStoredKey,
    });
  },

  saveTypeSafeConfig: async (config, apiKey) => {
    const res = await apiClient.saveTypeSafeConfig({ config, apiKey });
    set({
      typeSafeConfig: res.config,
      hasStoredTypeSafeKey: res.hasStoredKey,
    });
  },

  testTypeSafeConnection: async (config, apiKey) => {
    const res = await apiClient.testTypeSafeConnection({ config, apiKey });
    set({ typeSafeModels: res.models });
    return res.models;
  },

  loadCacheStats: async () => {
    const res = await apiClient.getCacheStats();
    set({ cacheStats: res.stats });
  },

  updateCacheBudget: async (budgetBytes) => {
    const res = await apiClient.updateCacheBudget(budgetBytes);
    set({ cacheStats: res.stats });
  },

  evictCacheNow: async () => {
    const res = await apiClient.evictCacheNow();
    set({ cacheStats: res.stats });
  },

  loadExternalAgentConfig: async () => {
    const res = await apiClient.getExternalAgentConfig();
    set({ externalAgentConfig: res.config });
  },

  saveExternalAgentConfig: async (config) => {
    const res = await apiClient.saveExternalAgentConfig({ config });
    set({ externalAgentConfig: res.config });
  },
}));
