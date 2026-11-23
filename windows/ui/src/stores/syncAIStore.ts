import { create } from 'zustand';
import { getTransport } from '../api/transport';
import type {
  AIConnectionTestResult,
  AIProviderConfig,
  AIProviderStateDto,
  CacheStats,
  CloudAIUsageCategory,
  DriveSyncConfig,
  ExternalAgentConfig,
  ExternalAgentStateDto,
  StorageMigrationReport,
  SyncStatus,
  SystemDiagnosticsDto,
  TypeSafeExperimentalConfig,
  TypeSafeStateDto,
  TypeSafeTestResultDto,
} from '../types/domain';
import { useCoordinatorStore } from './coordinatorStore';

export interface SyncAIState {
  syncConfig: DriveSyncConfig | null;
  syncStatus: SyncStatus | null;
  cacheStats: CacheStats | null;
  syncing: boolean;
  migrating: boolean;

  aiState: AIProviderStateDto | null;
  typesafeState: TypeSafeStateDto | null;
  agentState: ExternalAgentStateDto | null;
  diagnostics: SystemDiagnosticsDto | null;

  refreshSyncAndCache: () => Promise<void>;
  refreshSettingsData: () => Promise<void>;
  saveSyncConfig: (config: DriveSyncConfig, webdavPassword?: string) => Promise<void>;
  runStorageMigration: (
    targetConfig: DriveSyncConfig,
    webdavPassword?: string,
  ) => Promise<StorageMigrationReport | null>;
  setSyncStatus: (status: SyncStatus) => void;
  syncNow: () => Promise<void>;
  setCacheBudgetBytes: (bytes: number) => Promise<void>;
  evictCacheNow: () => Promise<void>;

  saveAiConfig: (
    config: AIProviderConfig,
    opts?: { apiKey?: string | null; clearApiKey?: boolean },
  ) => Promise<void>;
  testAiConnection: () => Promise<AIConnectionTestResult>;
  resetAiUsage: (category?: CloudAIUsageCategory | null) => Promise<void>;
  disconnectChatgpt: () => Promise<void>;

  saveTypesafeConfig: (
    config: TypeSafeExperimentalConfig,
    opts?: { apiKey?: string | null; clearApiKey?: boolean },
  ) => Promise<void>;
  testTypesafeConnection: () => Promise<TypeSafeTestResultDto>;

  saveExternalAgentConfig: (config: ExternalAgentConfig) => Promise<void>;
}

export const useSyncAIStore = create<SyncAIState>((set) => ({
  syncConfig: null,
  syncStatus: null,
  cacheStats: null,
  syncing: false,
  migrating: false,

  aiState: null,
  typesafeState: null,
  agentState: null,
  diagnostics: null,

  async refreshSyncAndCache() {
    const transport = getTransport();
    const [syncConfig, syncStatus, cacheStats] = await Promise.all([
      transport.syncConfig(),
      transport.syncStatus(),
      transport.cacheStats(),
    ]);
    set({ syncConfig, syncStatus, cacheStats });
  },

  async refreshSettingsData() {
    const transport = getTransport();
    const [syncConfig, syncStatus, cacheStats, aiState, typesafeState, agentState, diagnostics] =
      await Promise.all([
        transport.syncConfig(),
        transport.syncStatus(),
        transport.cacheStats(),
        transport.getAiProviderState(),
        transport.getTypesafeState(),
        transport.getExternalAgentState(),
        transport.getSystemDiagnostics(),
      ]);
    set({
      syncConfig,
      syncStatus,
      cacheStats,
      aiState,
      typesafeState,
      agentState,
      diagnostics,
    });
  },

  async saveSyncConfig(config, webdavPassword) {
    const transport = getTransport();
    await transport.saveSyncConfig(config);
    if (webdavPassword && webdavPassword.trim()) {
      await transport.saveWebdavPassword(webdavPassword.trim());
    }
    const syncStatus = await transport.syncStatus();
    set({ syncConfig: config, syncStatus });
    useCoordinatorStore.getState().pushToast({
      message: '同步配置已保存',
      tone: 'success',
    });
  },

  async runStorageMigration(targetConfig, webdavPassword) {
    set({ migrating: true });
    try {
      const report = await getTransport().runStorageMigration(targetConfig, webdavPassword ?? null);
      const [syncConfig, syncStatus, cacheStats] = await Promise.all([
        getTransport().syncConfig(),
        getTransport().syncStatus(),
        getTransport().cacheStats(),
      ]);
      set({ syncConfig, syncStatus, cacheStats, migrating: false });
      useCoordinatorStore.getState().pushToast({
        message: `无损迁移完成（${report.migratedAssets} 项素材、${report.migratedFolders} 个文件夹、${report.migratedBoards} 块情绪板）`,
        tone: 'success',
        durationMs: 4800,
      });
      return report;
    } catch (err) {
      set({ migrating: false });
      useCoordinatorStore.getState().pushToast({
        message: `迁移失败：${err instanceof Error ? err.message : String(err)}`,
        tone: 'error',
      });
      return null;
    }
  },

  setSyncStatus(status) {
    set({ syncStatus: status });
  },

  async syncNow() {
    set({ syncing: true });
    try {
      const report = await getTransport().syncNow();
      const [syncStatus, cacheStats] = await Promise.all([
        getTransport().syncStatus(),
        getTransport().cacheStats(),
      ]);
      set({ syncStatus, cacheStats, syncing: false });
      useCoordinatorStore.getState().pushToast({
        message: `同步完成（上传 ${report.uploadedOps}，下载 ${report.downloadedOps}）`,
        tone: 'success',
      });
    } catch (err) {
      set({ syncing: false });
      useCoordinatorStore.getState().pushToast({
        message: `同步失败：${err instanceof Error ? err.message : String(err)}`,
        tone: 'error',
      });
    }
  },

  async setCacheBudgetBytes(bytes) {
    await getTransport().setCacheBudgetBytes(bytes);
    const cacheStats = await getTransport().cacheStats();
    set({ cacheStats });
  },

  async evictCacheNow() {
    const cacheStats = await getTransport().evictCacheNow();
    set({ cacheStats });
    useCoordinatorStore.getState().pushToast({
      message: '本地缓存清理完成',
      tone: 'info',
    });
  },

  async saveAiConfig(config, opts) {
    const aiState = await getTransport().saveAiProviderConfig(config, opts);
    set({ aiState });
    useCoordinatorStore.getState().pushToast({
      message: '云端 AI 配置已安全保存（密钥加密存于 Windows 凭据管理器）',
      tone: 'success',
    });
  },

  async testAiConnection() {
    const res = await getTransport().testAiProviderConnection();
    const aiState = await getTransport().getAiProviderState();
    set({ aiState });
    return res;
  },

  async resetAiUsage(category) {
    const usage = await getTransport().resetAiUsage(category ?? null);
    set((s) => (s.aiState ? { aiState: { ...s.aiState, usage } } : s));
  },

  async disconnectChatgpt() {
    const session = await getTransport().disconnectChatgptAccount();
    set((s) => (s.aiState ? { aiState: { ...s.aiState, chatgptSession: session } } : s));
  },

  async saveTypesafeConfig(config, opts) {
    const typesafeState = await getTransport().saveTypesafeConfig(config, opts);
    set({ typesafeState });
    useCoordinatorStore.getState().pushToast({
      message: 'TypeSafe System One (Jev) 配置已保存',
      tone: 'success',
    });
  },

  async testTypesafeConnection() {
    return getTransport().testTypesafeConnection();
  },

  async saveExternalAgentConfig(config) {
    const agentState = await getTransport().saveExternalAgentConfig(config);
    set({ agentState });
    useCoordinatorStore.getState().pushToast({
      message: '外部 Agent 权限策略已即时生效',
      tone: 'info',
    });
  },
}));
