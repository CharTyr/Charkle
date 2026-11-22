import { create } from 'zustand';
import {
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
  CloudAIProviderKind,
  CloudAIUsageCategory,
  CloudAIUsageSummary,
  DriveSyncConfig,
  ExternalAgentConfig,
  StorageMigrationReport,
  SyncReport,
  SyncStatus,
  TypeSafeExperimentalConfig,
  TypeSafeModelInfo,
} from '@charkle/shared';
import { apiClient } from '../api/client';

interface SyncAIState {
  sseConnected: boolean;

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

  typeSafeConfig: TypeSafeExperimentalConfig;
  hasStoredTypeSafeKey: boolean;
  typeSafeModels: TypeSafeModelInfo[];

  cacheStats: CacheStats;
  externalAgentConfig: ExternalAgentConfig;

  setSSEConnected: (connected: boolean) => void;
  setSyncStatus: (status: SyncStatus) => void;
  setSyncCompleted: (report: SyncReport, status: SyncStatus) => void;
  setAIConfigSnapshot: (config: AIProviderConfig) => void;

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

export const useSyncAIStore = create<SyncAIState>((set) => ({
  sseConnected: false,

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

  loadSyncConfig: async () => {
    const res = await apiClient.getSyncConfig();
    set({
      syncConfig: res.config,
      syncStatus: res.status,
      hasGoogleOAuthConfig: res.hasGoogleOAuthConfig,
      hasWebDAVPassword: res.hasWebDAVPassword,
      activeStorageSummary: res.activeLocationSummary,
    });
  },

  saveSyncConfig: async (config, webDAVPassword) => {
    const res = await apiClient.saveSyncConfig({ config, webDAVPassword });
    set({
      syncConfig: res.config,
      syncStatus: res.status,
      hasGoogleOAuthConfig: res.hasGoogleOAuthConfig,
      hasWebDAVPassword: res.hasWebDAVPassword,
      activeStorageSummary: res.activeLocationSummary,
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
    set({
      syncConfig: refreshed.config,
      syncStatus: refreshed.status,
      hasGoogleOAuthConfig: refreshed.hasGoogleOAuthConfig,
      hasWebDAVPassword: refreshed.hasWebDAVPassword,
      activeStorageSummary: refreshed.activeLocationSummary,
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
