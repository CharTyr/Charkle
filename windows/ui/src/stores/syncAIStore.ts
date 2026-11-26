import { create } from 'zustand';
import { getTransport } from '../api/transport';
import {
  resolveBackends,
  synchronizePrimaryFields,
  type AIConnectionTestResult,
  type AIProviderConfig,
  type AIProviderStateDto,
  type BackendTestResultDto,
  type CacheStats,
  type CloudAIUsageCategory,
  type DriveSyncConfig,
  type ExternalAgentConfig,
  type ExternalAgentSelfCheckDto,
  type ExternalAgentStateDto,
  type GDirectInstallProgress,
  type GDirectInstallResult,
  type ICloudDriveAvailability,
  type StorageMigrationReport,
  type SyncBackendProfile,
  type SyncReport,
  type SyncStatus,
  type SystemDiagnosticsDto,
  type TypeSafeExperimentalConfig,
  type TypeSafeModelInfo,
  type TypeSafeStateDto,
  type TypeSafeTestResultDto,
  type WebdavTestResultDto,
} from '../types/domain';
import { useCoordinatorStore } from './coordinatorStore';

function accessLevelTitle(level: ExternalAgentConfig['accessLevel']): string {
  return level === 'readWriteOrganize' ? '允许整理与生板' : '仅只读';
}

export interface SyncAIState {
  syncConfig: DriveSyncConfig | null;
  syncStatus: SyncStatus | null;
  iCloudAvailability: ICloudDriveAvailability | null;
  lastSyncReport: SyncReport | null;
  lastMigrationReport: StorageMigrationReport | null;
  cacheStats: CacheStats | null;
  syncing: boolean;
  syncingBackendId: string | null;
  migrating: boolean;
  testingWebdav: boolean;
  testingBackend: boolean;
  signingInGoogle: boolean;
  hasGoogleOAuthClient: boolean;
  hasWebdavPassword: boolean;

  aiState: AIProviderStateDto | null;
  testingAi: boolean;
  signingInChatgpt: boolean;
  typesafeState: TypeSafeStateDto | null;
  typesafeModels: TypeSafeModelInfo[];
  testingTypesafe: boolean;
  agentState: ExternalAgentStateDto | null;
  runningAgentSelfCheck: boolean;
  agentSelfCheckPassed: boolean | null;
  agentSelfCheckSummary: string | null;
  rebuildingVisualIndex: boolean;
  rebuildVisualIndexProgress: { completed: number; total: number } | null;
  installingGDirect: boolean;
  gdirectInstallProgress: GDirectInstallProgress | null;
  diagnostics: SystemDiagnosticsDto | null;

  statusMessage: string | null;
  errorMessage: string | null;

  clearStatusMessage: () => void;
  clearErrorMessage: () => void;
  setStatusFeedback: (status: string | null, error?: string | null) => void;

  refreshSyncAndCache: () => Promise<void>;
  refreshSettingsData: () => Promise<void>;
  saveSyncConfig: (
    config: DriveSyncConfig,
    webdavPassword?: string,
    opts?: { quiet?: boolean },
  ) => Promise<boolean>;
  upsertBackend: (
    profile: SyncBackendProfile,
    webdavPassword?: string | null,
  ) => Promise<boolean>;
  removeBackend: (backendId: string) => Promise<boolean>;
  setBackendEnabled: (backendId: string, enabled: boolean) => Promise<boolean>;
  setPrimaryBackend: (backendId: string) => Promise<boolean>;
  testBackendConnection: (
    profile: SyncBackendProfile,
    webdavPassword?: string | null,
  ) => Promise<BackendTestResultDto>;
  syncBackend: (backendId: string) => Promise<SyncReport | null>;
  testWebdavConnection: (
    config: DriveSyncConfig,
    password?: string | null,
  ) => Promise<WebdavTestResultDto>;
  saveGoogleOAuthClient: (clientId: string, clientSecret: string) => Promise<boolean>;
  importGoogleOAuthSecretFile: () => Promise<boolean>;
  signInGoogleDrive: () => Promise<boolean>;
  signOutGoogleDrive: () => Promise<void>;
  runStorageMigration: (
    targetConfig: DriveSyncConfig,
    webdavPassword?: string,
  ) => Promise<StorageMigrationReport | null>;
  setSyncStatus: (status: SyncStatus) => void;
  syncNow: () => Promise<SyncReport | null>;
  setCacheBudgetBytes: (bytes: number) => Promise<void>;
  evictCacheNow: () => Promise<void>;

  saveAiConfig: (
    config: AIProviderConfig,
    opts?: { apiKey?: string | null; clearApiKey?: boolean; quiet?: boolean },
  ) => Promise<boolean>;
  testAiConnection: () => Promise<AIConnectionTestResult>;
  resetAiUsage: (category?: CloudAIUsageCategory | null) => Promise<void>;
  signInChatgpt: (reconsent?: boolean, switchAccount?: boolean) => Promise<boolean>;
  disconnectChatgpt: () => Promise<void>;

  saveTypesafeConfig: (
    config: TypeSafeExperimentalConfig,
    opts?: { apiKey?: string | null; clearApiKey?: boolean; quiet?: boolean },
  ) => Promise<boolean>;
  testTypesafeConnection: () => Promise<TypeSafeTestResultDto>;

  saveExternalAgentConfig: (
    config: ExternalAgentConfig,
    opts?: { quiet?: boolean },
  ) => Promise<void>;
  runExternalAgentSelfCheck: () => Promise<ExternalAgentSelfCheckDto>;
  rebuildLocalVisualIndex: (assetIds?: string[]) => Promise<number>;
  setGDirectInstallProgress: (progress: GDirectInstallProgress | null) => void;
  installGDirectCli: () => Promise<GDirectInstallResult | null>;
  openDirectoryInExplorer: (path: string) => Promise<void>;
}

export const useSyncAIStore = create<SyncAIState>((set, get) => ({
  syncConfig: null,
  syncStatus: null,
  iCloudAvailability: null,
  lastSyncReport: null,
  lastMigrationReport: null,
  cacheStats: null,
  syncing: false,
  syncingBackendId: null,
  migrating: false,
  testingWebdav: false,
  testingBackend: false,
  signingInGoogle: false,
  hasGoogleOAuthClient: false,
  hasWebdavPassword: false,

  aiState: null,
  testingAi: false,
  signingInChatgpt: false,
  typesafeState: null,
  typesafeModels: [],
  testingTypesafe: false,
  agentState: null,
  runningAgentSelfCheck: false,
  agentSelfCheckPassed: null,
  agentSelfCheckSummary: null,
  rebuildingVisualIndex: false,
  rebuildVisualIndexProgress: null,
  installingGDirect: false,
  gdirectInstallProgress: null,
  diagnostics: null,

  statusMessage: null,
  errorMessage: null,

  clearStatusMessage() {
    set({ statusMessage: null });
  },

  clearErrorMessage() {
    set({ errorMessage: null });
  },

  setStatusFeedback(status, error = null) {
    set({ statusMessage: status, errorMessage: error });
  },

  async refreshSyncAndCache() {
    const transport = getTransport();
    const [syncConfigRes, syncStatusRes, cacheStatsRes, authStateRes, icloudRes] =
      await Promise.allSettled([
        transport.syncConfig(),
        transport.syncStatus(),
        transport.cacheStats(),
        transport.getSyncAuthState(),
        transport.probeICloudDriveAvailability(),
      ]);
    set((s) => ({
      syncConfig: syncConfigRes.status === 'fulfilled' ? syncConfigRes.value : s.syncConfig,
      syncStatus: syncStatusRes.status === 'fulfilled' ? syncStatusRes.value : s.syncStatus,
      cacheStats: cacheStatsRes.status === 'fulfilled' ? cacheStatsRes.value : s.cacheStats,
      iCloudAvailability:
        icloudRes.status === 'fulfilled' ? icloudRes.value : s.iCloudAvailability,
      hasGoogleOAuthClient:
        authStateRes.status === 'fulfilled'
          ? authStateRes.value.hasGoogleOAuthClient
          : s.hasGoogleOAuthClient,
      hasWebdavPassword:
        authStateRes.status === 'fulfilled'
          ? authStateRes.value.hasWebdavPassword
          : s.hasWebdavPassword,
    }));
  },

  async refreshSettingsData() {
    const transport = getTransport();
    const [
      syncConfigRes,
      syncStatusRes,
      cacheStatsRes,
      aiStateRes,
      typesafeStateRes,
      agentStateRes,
      diagnosticsRes,
      authStateRes,
      icloudRes,
    ] = await Promise.allSettled([
      transport.syncConfig(),
      transport.syncStatus(),
      transport.cacheStats(),
      transport.getAiProviderState(),
      transport.getTypesafeState(),
      transport.getExternalAgentState(),
      transport.getSystemDiagnostics(),
      transport.getSyncAuthState(),
      transport.probeICloudDriveAvailability(),
    ]);
    set((s) => ({
      syncConfig: syncConfigRes.status === 'fulfilled' ? syncConfigRes.value : s.syncConfig,
      syncStatus: syncStatusRes.status === 'fulfilled' ? syncStatusRes.value : s.syncStatus,
      cacheStats: cacheStatsRes.status === 'fulfilled' ? cacheStatsRes.value : s.cacheStats,
      iCloudAvailability:
        icloudRes.status === 'fulfilled' ? icloudRes.value : s.iCloudAvailability,
      aiState: aiStateRes.status === 'fulfilled' ? aiStateRes.value : s.aiState,
      typesafeState:
        typesafeStateRes.status === 'fulfilled' ? typesafeStateRes.value : s.typesafeState,
      agentState: agentStateRes.status === 'fulfilled' ? agentStateRes.value : s.agentState,
      diagnostics: diagnosticsRes.status === 'fulfilled' ? diagnosticsRes.value : s.diagnostics,
      hasGoogleOAuthClient:
        authStateRes.status === 'fulfilled'
          ? authStateRes.value.hasGoogleOAuthClient
          : s.hasGoogleOAuthClient,
      hasWebdavPassword:
        authStateRes.status === 'fulfilled'
          ? authStateRes.value.hasWebdavPassword
          : s.hasWebdavPassword,
    }));
  },

  async saveSyncConfig(config, webdavPassword, opts) {
    const transport = getTransport();
    set({ errorMessage: null });
    try {
      const normalized = synchronizePrimaryFields(config);
      await transport.saveSyncConfig(normalized);
      let savedPwd = get().hasWebdavPassword;
      if (webdavPassword && webdavPassword.trim()) {
        await transport.saveWebdavPassword(webdavPassword.trim());
        savedPwd = true;
      }
      const syncStatus = await transport.syncStatus();
      set({
        syncConfig: normalized,
        syncStatus,
        hasWebdavPassword: savedPwd,
        statusMessage: opts?.quiet ? get().statusMessage : '已更新云同步设置',
      });
      if (!opts?.quiet) {
        useCoordinatorStore.getState().pushToast({
          message: '同步配置已保存',
          tone: 'success',
        });
      }
      return true;
    } catch (err) {
      const msg = err instanceof Error ? err.message : String(err);
      set({ errorMessage: msg });
      useCoordinatorStore.getState().pushToast({
        message: `保存同步配置失败：${msg}`,
        tone: 'error',
      });
      return false;
    }
  },

  async upsertBackend(profile, webdavPassword) {
    const transport = getTransport();
    set({ errorMessage: null });
    try {
      const base: DriveSyncConfig = get().syncConfig ?? (await transport.syncConfig());
      const existing = resolveBackends(base);
      const idx = existing.findIndex((b) => b.id === profile.id);
      let updated: SyncBackendProfile[];
      if (idx >= 0) {
        updated = existing.map((b, i) => (i === idx ? { ...profile } : b));
      } else {
        updated = [...existing, { ...profile }];
      }
      if (profile.isPrimary) {
        updated = updated.map((b) => ({ ...b, isPrimary: b.id === profile.id }));
      }
      const nextCfg = synchronizePrimaryFields({ ...base, backends: updated });
      await transport.saveSyncConfig(nextCfg);
      if (profile.mode === 'webDAV' && webdavPassword && webdavPassword.trim()) {
        await transport.saveBackendWebdavPassword(profile.id, webdavPassword.trim());
      }
      const [syncStatus, authState] = await Promise.all([
        transport.syncStatus(),
        transport.getSyncAuthState().catch(() => null),
      ]);
      set((s) => ({
        syncConfig: nextCfg,
        syncStatus,
        hasWebdavPassword: authState?.hasWebdavPassword ?? s.hasWebdavPassword,
        statusMessage: `已保存同步后端「${profile.name || profile.mode}」`,
      }));
      useCoordinatorStore.getState().pushToast({
        message: `已保存同步后端「${profile.name || profile.mode}」`,
        tone: 'success',
      });
      return true;
    } catch (err) {
      const msg = err instanceof Error ? err.message : String(err);
      set({ errorMessage: msg });
      useCoordinatorStore.getState().pushToast({
        message: `保存同步后端失败：${msg}`,
        tone: 'error',
      });
      return false;
    }
  },

  async removeBackend(backendId) {
    const transport = getTransport();
    set({ errorMessage: null });
    try {
      const base: DriveSyncConfig = get().syncConfig ?? (await transport.syncConfig());
      const existing = resolveBackends(base);
      const remaining = existing.filter((b) => b.id !== backendId);
      if (remaining.length === 0) {
        const msg = '至少保留一个存储后端。';
        set({ errorMessage: msg });
        return false;
      }
      if (!remaining.some((b) => b.isPrimary)) {
        remaining[0] = { ...remaining[0], isPrimary: true, isEnabled: true };
      }
      const nextCfg = synchronizePrimaryFields({ ...base, backends: remaining });
      await transport.saveSyncConfig(nextCfg);
      const syncStatus = await transport.syncStatus();
      set({
        syncConfig: nextCfg,
        syncStatus,
        statusMessage: '已移除同步后端',
      });
      return true;
    } catch (err) {
      const msg = err instanceof Error ? err.message : String(err);
      set({ errorMessage: msg });
      return false;
    }
  },

  async setBackendEnabled(backendId, enabled) {
    const transport = getTransport();
    set({ errorMessage: null });
    try {
      const base: DriveSyncConfig = get().syncConfig ?? (await transport.syncConfig());
      const existing = resolveBackends(base).map((b) =>
        b.id === backendId ? { ...b, isEnabled: enabled } : b,
      );
      const nextCfg = synchronizePrimaryFields({ ...base, backends: existing });
      await transport.saveSyncConfig(nextCfg);
      const syncStatus = await transport.syncStatus();
      set({ syncConfig: nextCfg, syncStatus });
      return true;
    } catch (err) {
      set({ errorMessage: err instanceof Error ? err.message : String(err) });
      return false;
    }
  },

  async setPrimaryBackend(backendId) {
    const transport = getTransport();
    set({ errorMessage: null });
    try {
      const base: DriveSyncConfig = get().syncConfig ?? (await transport.syncConfig());
      const existing = resolveBackends(base).map((b) =>
        b.id === backendId ? { ...b, isPrimary: true, isEnabled: true } : { ...b, isPrimary: false },
      );
      const nextCfg = synchronizePrimaryFields({ ...base, backends: existing });
      await transport.saveSyncConfig(nextCfg);
      const syncStatus = await transport.syncStatus();
      set({
        syncConfig: nextCfg,
        syncStatus,
        statusMessage: '已切换主同步后端',
      });
      return true;
    } catch (err) {
      set({ errorMessage: err instanceof Error ? err.message : String(err) });
      return false;
    }
  },

  async testBackendConnection(profile, webdavPassword) {
    const transport = getTransport();
    set({ testingBackend: true, errorMessage: null });
    try {
      const trimmedPwd = webdavPassword?.trim() ? webdavPassword.trim() : null;
      const res = await transport.testBackendConnection(profile, trimmedPwd);
      set({
        testingBackend: false,
        statusMessage: res.ok ? res.message : null,
        errorMessage: res.ok ? null : res.message,
      });
      return res;
    } catch (err) {
      const message = err instanceof Error ? err.message : String(err);
      set({ testingBackend: false, errorMessage: message });
      return { ok: false, message, account: null };
    }
  },

  async syncBackend(backendId) {
    const transport = getTransport();
    set({ syncing: true, syncingBackendId: backendId, errorMessage: null });
    try {
      const report = await transport.syncBackend(backendId);
      const [syncStatus, cacheStats] = await Promise.all([
        transport.syncStatus(),
        transport.cacheStats(),
      ]);
      const msg = `单后端同步完成 · 上传 ${report.uploadedOps} / 拉取 ${report.downloadedOps} / 新发现 ${report.discoveredRemoteAssets} 项`;
      set({
        syncStatus,
        cacheStats,
        lastSyncReport: report,
        syncing: false,
        syncingBackendId: null,
        statusMessage: msg,
      });
      useCoordinatorStore.getState().pushToast({
        message: msg,
        tone: 'success',
      });
      return report;
    } catch (err) {
      const msg = err instanceof Error ? err.message : String(err);
      const syncStatus = await transport.syncStatus().catch(() => get().syncStatus);
      set({
        syncing: false,
        syncingBackendId: null,
        syncStatus,
        errorMessage: `同步失败：${msg}`,
      });
      useCoordinatorStore.getState().pushToast({
        message: `同步失败：${msg}`,
        tone: 'error',
      });
      return null;
    }
  },

  async testWebdavConnection(config, password) {
    const transport = getTransport();
    set({ testingWebdav: true, errorMessage: null });
    try {
      const trimmedPwd = password?.trim() ? password.trim() : null;
      const res = await transport.testWebdavConnection(config, trimmedPwd);
      const [syncConfig, syncStatus, authState] = await Promise.all([
        transport.syncConfig(),
        transport.syncStatus(),
        transport.getSyncAuthState().catch(() => null),
      ]);
      set((s) => ({
        testingWebdav: false,
        syncConfig,
        syncStatus,
        hasWebdavPassword:
          authState?.hasWebdavPassword ?? (trimmedPwd ? true : s.hasWebdavPassword),
        statusMessage: res.ok ? res.message : null,
        errorMessage: res.ok ? null : res.message,
      }));
      return res;
    } catch (err) {
      const message = err instanceof Error ? err.message : String(err);
      set({ testingWebdav: false, errorMessage: message });
      return { ok: false, message };
    }
  },

  async saveGoogleOAuthClient(clientId, clientSecret) {
    const transport = getTransport();
    set({ errorMessage: null });
    const cid = clientId.trim();
    const secret = clientSecret.trim();
    if (!cid) {
      set({ errorMessage: '请输入有效的 Google Client ID。' });
      return false;
    }
    try {
      const ok = await transport.saveGoogleOAuthClient(cid, secret);
      set({
        hasGoogleOAuthClient: ok,
        statusMessage: ok ? '已保存 Google 登录凭据' : null,
      });
      return ok;
    } catch (err) {
      set({ errorMessage: err instanceof Error ? err.message : String(err) });
      return false;
    }
  },

  async importGoogleOAuthSecretFile() {
    const transport = getTransport();
    set({ errorMessage: null });
    try {
      const filePath = await transport.pickJsonFileDialog('选择 Google 登录凭据文件 (.json)');
      if (!filePath) return false;
      const ok = await transport.importGoogleOAuthSecretFile(filePath);
      set({
        hasGoogleOAuthClient: ok,
        statusMessage: ok ? '已导入 Google 登录凭据文件' : null,
      });
      return ok;
    } catch (err) {
      set({ errorMessage: err instanceof Error ? err.message : String(err) });
      return false;
    }
  },

  async signInGoogleDrive() {
    const transport = getTransport();
    set({ signingInGoogle: true, errorMessage: null });
    try {
      const syncStatus = await transport.signInGoogleDrive();
      const syncConfig = await transport.syncConfig();
      set({
        signingInGoogle: false,
        syncConfig,
        syncStatus,
        statusMessage: syncStatus.account?.email
          ? `已登录 Google 账号：${syncStatus.account.email}`
          : 'Google 账号登录成功，同步已就绪',
      });
      return true;
    } catch (err) {
      set({
        signingInGoogle: false,
        errorMessage: err instanceof Error ? err.message : String(err),
      });
      return false;
    }
  },

  async signOutGoogleDrive() {
    const transport = getTransport();
    set({ signingInGoogle: true, errorMessage: null });
    try {
      const syncStatus = await transport.signOutGoogleDrive();
      set({
        signingInGoogle: false,
        syncStatus,
        statusMessage: '已退出 Google 账号',
      });
    } catch (err) {
      set({
        signingInGoogle: false,
        errorMessage: err instanceof Error ? err.message : String(err),
      });
    }
  },

  async runStorageMigration(targetConfig, webdavPassword) {
    set({ migrating: true, errorMessage: null });
    try {
      const report = await getTransport().runStorageMigration(targetConfig, webdavPassword ?? null);
      const [syncConfig, syncStatus, cacheStats, authState] = await Promise.all([
        getTransport().syncConfig(),
        getTransport().syncStatus(),
        getTransport().cacheStats(),
        getTransport().getSyncAuthState().catch(() => null),
      ]);
      const summary = `素材库已迁移至「${report.targetLocation}」· 共 ${report.migratedAssets} 项素材、${report.migratedFolders} 个文件夹、${report.migratedBoards} 块情绪板`;
      set((s) => ({
        syncConfig,
        syncStatus,
        cacheStats,
        lastMigrationReport: report,
        hasWebdavPassword:
          authState?.hasWebdavPassword ?? (webdavPassword?.trim() ? true : s.hasWebdavPassword),
        migrating: false,
        statusMessage: summary,
      }));
      useCoordinatorStore.getState().pushToast({
        message: summary,
        tone: 'success',
        durationMs: 4800,
      });
      return report;
    } catch (err) {
      const msg = err instanceof Error ? err.message : String(err);
      set({ migrating: false, errorMessage: `迁移失败：${msg}` });
      useCoordinatorStore.getState().pushToast({
        message: `迁移失败：${msg}`,
        tone: 'error',
      });
      return null;
    }
  },

  setSyncStatus(status) {
    set({ syncStatus: status });
  },

  async syncNow() {
    set({ syncing: true, errorMessage: null });
    try {
      const report = await getTransport().syncNow();
      const [syncStatus, cacheStats] = await Promise.all([
        getTransport().syncStatus(),
        getTransport().cacheStats(),
      ]);
      const msg = `同步完成 · 上传 ${report.uploadedOps} / 拉取 ${report.downloadedOps} / 新发现 ${report.discoveredRemoteAssets} 项`;
      set({
        syncStatus,
        cacheStats,
        lastSyncReport: report,
        syncing: false,
        statusMessage: msg,
      });
      useCoordinatorStore.getState().pushToast({
        message: msg,
        tone: 'success',
      });
      return report;
    } catch (err) {
      const msg = err instanceof Error ? err.message : String(err);
      const syncStatus = await getTransport().syncStatus().catch(() => get().syncStatus);
      set({ syncing: false, syncStatus, errorMessage: `同步失败：${msg}` });
      useCoordinatorStore.getState().pushToast({
        message: `同步失败：${msg}`,
        tone: 'error',
      });
      return null;
    }
  },

  async setCacheBudgetBytes(bytes) {
    const minBytes = 2 * 1024 ** 3;
    const maxBytes = 100 * 1024 ** 3;
    const clamped = Math.max(minBytes, Math.min(maxBytes, Math.round(bytes)));
    set({ errorMessage: null });
    try {
      await getTransport().setCacheBudgetBytes(clamped);
      const cacheStats = await getTransport().cacheStats();
      set({ cacheStats });
    } catch (err) {
      const msg = err instanceof Error ? err.message : String(err);
      set({ errorMessage: `更新缓存上限失败：${msg}` });
      useCoordinatorStore.getState().pushToast({
        message: `更新缓存上限失败：${msg}`,
        tone: 'error',
      });
    }
  },

  async evictCacheNow() {
    set({ errorMessage: null });
    try {
      const cacheStats = await getTransport().evictCacheNow();
      const msg = '已释放临时本地缓存（已保留在本地的内容未受影响）';
      set({ cacheStats, statusMessage: msg });
      useCoordinatorStore.getState().pushToast({
        message: msg,
        tone: 'info',
      });
    } catch (err) {
      const msg = err instanceof Error ? err.message : String(err);
      set({ errorMessage: msg });
      useCoordinatorStore.getState().pushToast({
        message: `清理缓存失败：${msg}`,
        tone: 'error',
      });
    }
  },

  async saveAiConfig(config, opts) {
    set({ errorMessage: null });
    try {
      const aiState = await getTransport().saveAiProviderConfig(config, opts);
      set({
        aiState,
        statusMessage: opts?.quiet
          ? get().statusMessage
          : '已保存 AI 配置（密钥仅存于 Windows 凭据管理器）',
      });
      if (!opts?.quiet) {
        useCoordinatorStore.getState().pushToast({
          message: '已保存 AI 配置（密钥仅存于 Windows 凭据管理器）',
          tone: 'success',
        });
      }
      return true;
    } catch (err) {
      const msg = err instanceof Error ? err.message : String(err);
      set({ errorMessage: msg });
      useCoordinatorStore.getState().pushToast({
        message: `保存 AI 配置失败：${msg}`,
        tone: 'error',
      });
      return false;
    }
  },

  async testAiConnection() {
    set({ testingAi: true, errorMessage: null });
    try {
      const res = await getTransport().testAiProviderConnection();
      const aiState = await getTransport().getAiProviderState();
      set({
        aiState,
        testingAi: false,
        statusMessage: res.ok ? `${res.providerLabel}：${res.message}` : null,
        errorMessage: res.ok ? null : `${res.providerLabel}：${res.message}`,
      });
      return res;
    } catch (err) {
      const message = err instanceof Error ? err.message : String(err);
      set({ testingAi: false, errorMessage: message });
      return {
        ok: false,
        providerLabel: '云端 AI',
        model: get().aiState?.config.chatModel ?? '',
        message,
        latencyMs: 0,
      };
    }
  },

  async resetAiUsage(category) {
    set({ errorMessage: null });
    try {
      const usage = await getTransport().resetAiUsage(category ?? null);
      const statusMessage =
        category === 'standard'
          ? '已清零普通云端模型用量统计'
          : category === 'jev'
            ? '已清零视觉定位引擎用量统计'
            : '已清零全部云端模型用量统计';
      set((s) => ({
        aiState: s.aiState ? { ...s.aiState, usage } : s.aiState,
        statusMessage,
      }));
    } catch (err) {
      const msg = err instanceof Error ? err.message : String(err);
      set({ errorMessage: `清零用量统计失败：${msg}` });
      useCoordinatorStore.getState().pushToast({
        message: `清零用量统计失败：${msg}`,
        tone: 'error',
      });
    }
  },

  async signInChatgpt(reconsent = false, switchAccount = false) {
    set({ signingInChatgpt: true, errorMessage: null });
    try {
      const aiState = await getTransport().signInWithChatgpt(reconsent, switchAccount);
      set({
        aiState,
        signingInChatgpt: false,
        statusMessage: aiState.chatgptSession.sharingEnabled
          ? `已连接 ChatGPT 订阅账号：${aiState.chatgptSession.name ?? aiState.chatgptSession.email ?? 'ChatGPT'}`
          : '已登录 ChatGPT，如需使用订阅额度请重新授权额度共享',
      });
      return true;
    } catch (err) {
      set({
        signingInChatgpt: false,
        errorMessage: err instanceof Error ? err.message : String(err),
      });
      return false;
    }
  },

  async disconnectChatgpt() {
    set({ errorMessage: null });
    try {
      const session = await getTransport().disconnectChatgptAccount();
      set((s) => ({
        aiState: s.aiState ? { ...s.aiState, chatgptSession: session } : s.aiState,
        statusMessage: '已退出 ChatGPT 账号连接',
      }));
    } catch (err) {
      const msg = err instanceof Error ? err.message : String(err);
      set({ errorMessage: `退出 ChatGPT 账号失败：${msg}` });
      useCoordinatorStore.getState().pushToast({
        message: `退出 ChatGPT 账号失败：${msg}`,
        tone: 'error',
      });
    }
  },

  async saveTypesafeConfig(config, opts) {
    set({ errorMessage: null });
    try {
      const typesafeState = await getTransport().saveTypesafeConfig(config, opts);
      set({
        typesafeState,
        statusMessage: opts?.quiet
          ? get().statusMessage
          : '已保存进阶视觉定位配置（密钥仅存于 Windows 凭据管理器）',
      });
      if (!opts?.quiet) {
        useCoordinatorStore.getState().pushToast({
          message: '已保存进阶视觉定位配置',
          tone: 'success',
        });
      }
      return true;
    } catch (err) {
      const msg = err instanceof Error ? err.message : String(err);
      set({ errorMessage: msg });
      useCoordinatorStore.getState().pushToast({
        message: `保存视觉定位配置失败：${msg}`,
        tone: 'error',
      });
      return false;
    }
  },

  async testTypesafeConnection() {
    set({ testingTypesafe: true, errorMessage: null });
    try {
      const res = await getTransport().testTypesafeConnection();
      set({
        testingTypesafe: false,
        typesafeModels: res.models ?? [],
        statusMessage: res.ok ? res.message : null,
        errorMessage: res.ok ? null : res.message,
      });
      return res;
    } catch (err) {
      const message = err instanceof Error ? err.message : String(err);
      set({ testingTypesafe: false, errorMessage: message });
      return { ok: false, message, models: [] };
    }
  },

  async saveExternalAgentConfig(config, opts) {
    set({ errorMessage: null });
    try {
      const agentState = await getTransport().saveExternalAgentConfig(config);
      const levelLabel = accessLevelTitle(config.accessLevel);
      const statusMessage =
        config.mcpEnabled && config.cliEnabled
          ? `MCP 与 CLI 服务均已开启 · 权限：${levelLabel}`
          : config.mcpEnabled
            ? `已开启 MCP 服务（CLI 已关闭）· 权限：${levelLabel}`
            : config.cliEnabled
              ? `已开启 CLI 命令行服务（MCP 已关闭）· 权限：${levelLabel}`
              : '已关闭 MCP 与 CLI 外部接入服务';

      set({
        agentState,
        statusMessage: opts?.quiet ? get().statusMessage : statusMessage,
      });
      if (!opts?.quiet) {
        useCoordinatorStore.getState().pushToast({
          message: statusMessage,
          tone: 'info',
        });
      }
    } catch (err) {
      set({ errorMessage: err instanceof Error ? err.message : String(err) });
    }
  },

  async runExternalAgentSelfCheck() {
    if (get().runningAgentSelfCheck) {
      return {
        ok: Boolean(get().agentSelfCheckPassed),
        summary: get().agentSelfCheckSummary ?? '自检进行中…',
      };
    }
    set({ runningAgentSelfCheck: true, errorMessage: null });
    try {
      const res = await getTransport().runExternalAgentSelfCheck();
      set({
        runningAgentSelfCheck: false,
        agentSelfCheckPassed: res.ok,
        agentSelfCheckSummary: res.summary,
        statusMessage: res.ok ? res.summary : null,
        errorMessage: res.ok ? null : res.summary,
      });
      return res;
    } catch (err) {
      const summary = `自检失败：${err instanceof Error ? err.message : String(err)}`;
      set({
        runningAgentSelfCheck: false,
        agentSelfCheckPassed: false,
        agentSelfCheckSummary: summary,
        errorMessage: summary,
      });
      return { ok: false, summary };
    }
  },

  async rebuildLocalVisualIndex(assetIds = []) {
    if (get().rebuildingVisualIndex) return 0;
    const total = Math.max(1, assetIds.length);
    set({
      rebuildingVisualIndex: true,
      rebuildVisualIndexProgress: { completed: 0, total },
      errorMessage: null,
    });
    try {
      const res = await getTransport().rebuildLocalVisualIndex();
      const msg = `已完成本机视觉与文字索引扫描（共更新 ${res.processed} / ${res.total} 项素材）`;
      set({
        rebuildingVisualIndex: false,
        rebuildVisualIndexProgress: null,
        statusMessage: msg,
      });
      return res.processed;
    } catch (err) {
      const msg = `重建视觉索引失败：${err instanceof Error ? err.message : String(err)}`;
      set({
        rebuildingVisualIndex: false,
        rebuildVisualIndexProgress: null,
        errorMessage: msg,
      });
      return 0;
    }
  },

  setGDirectInstallProgress(progress) {
    set({ gdirectInstallProgress: progress });
  },

  async installGDirectCli() {
    if (get().installingGDirect) return null;
    set({
      installingGDirect: true,
      gdirectInstallProgress: {
        phase: 'checking',
        message: '正在查询 gdirect 最新 Windows 版本…',
        downloadedBytes: 0,
        totalBytes: 0,
        fraction: 0.05,
      },
      errorMessage: null,
    });
    try {
      const result = await getTransport().installGDirectCli();
      await get().refreshSettingsData();
      const msg = `已安装 gdirect v${result.version}（已通过 SHA-256 校验）`;
      set({
        installingGDirect: false,
        gdirectInstallProgress: null,
        statusMessage: msg,
      });
      useCoordinatorStore.getState().pushToast({
        message: msg,
        tone: 'success',
      });
      return result;
    } catch (err) {
      const detail =
        err && typeof err === 'object' && 'message' in err && typeof (err as { message?: unknown }).message === 'string'
          ? (err as { message: string }).message
          : err instanceof Error
            ? err.message
            : String(err);
      const msg = `安装 gdirect 失败：${detail}`;
      set({
        installingGDirect: false,
        gdirectInstallProgress: null,
        errorMessage: msg,
      });
      useCoordinatorStore.getState().pushToast({
        message: msg,
        tone: 'error',
      });
      return null;
    }
  },

  async openDirectoryInExplorer(path) {
    const trimmed = path.trim();
    if (!trimmed) return;
    try {
      await getTransport().openDirectoryInExplorer(trimmed);
    } catch (err) {
      useCoordinatorStore.getState().pushToast({
        message: `无法打开目录：${err instanceof Error ? err.message : String(err)}`,
        tone: 'error',
      });
    }
  },
}));
