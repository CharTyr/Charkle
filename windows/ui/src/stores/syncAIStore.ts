import { create } from 'zustand';
import { getTransport } from '../api/transport';
import type {
  CacheStats,
  DriveSyncConfig,
  SyncStatus,
} from '../types/domain';
import { useCoordinatorStore } from './coordinatorStore';

export interface SyncAIState {
  syncConfig: DriveSyncConfig | null;
  syncStatus: SyncStatus | null;
  cacheStats: CacheStats | null;
  syncing: boolean;

  refreshSyncAndCache: () => Promise<void>;
  setSyncStatus: (status: SyncStatus) => void;
  syncNow: () => Promise<void>;
  setCacheBudgetBytes: (bytes: number) => Promise<void>;
  evictCacheNow: () => Promise<void>;
}

export const useSyncAIStore = create<SyncAIState>((set) => ({
  syncConfig: null,
  syncStatus: null,
  cacheStats: null,
  syncing: false,

  async refreshSyncAndCache() {
    const transport = getTransport();
    const [syncConfig, syncStatus, cacheStats] = await Promise.all([
      transport.syncConfig(),
      transport.syncStatus(),
      transport.cacheStats(),
    ]);
    set({ syncConfig, syncStatus, cacheStats });
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
}));
