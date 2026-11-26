import { create } from 'zustand';
import { getTransport } from '../api/transport';
import type {
  AppReleaseUpdate,
  AppUpdateState,
  UpdateDownloadProgress,
  UpdatePreferencesDto,
} from '../types/domain';

export const AUTOMATIC_CHECK_INTERVAL_MS = 6 * 60 * 60 * 1000;
export const DEFAULT_RELEASES_PAGE_URL = 'https://github.com/CharTyr/Charkle/releases';

function extractErrorInfo(err: unknown): { code?: string; message: string } {
  if (err && typeof err === 'object') {
    const rec = err as { code?: unknown; message?: unknown };
    const code = typeof rec.code === 'string' ? rec.code : undefined;
    const message =
      typeof rec.message === 'string' && rec.message.trim().length > 0
        ? rec.message.trim()
        : err instanceof Error
          ? err.message
          : String(err);
    return { code, message };
  }
  return { message: typeof err === 'string' ? err : '发生未知错误' };
}

export function formatByteCount(bytes: number): string {
  if (!Number.isFinite(bytes) || bytes <= 0) return '0 B';
  const units = ['B', 'KB', 'MB', 'GB'];
  let value = bytes;
  let idx = 0;
  while (value >= 1024 && idx < units.length - 1) {
    value /= 1024;
    idx += 1;
  }
  return idx === 0 ? `${Math.round(value)} B` : `${value.toFixed(value >= 100 ? 0 : 1)} ${units[idx]}`;
}

export function formatRelativeCheckTime(timestampMs: number | null | undefined, nowMs = Date.now()): string {
  if (!timestampMs || !Number.isFinite(timestampMs)) return '尚未检查';
  const diffSec = Math.max(0, Math.floor((nowMs - timestampMs) / 1000));
  if (diffSec < 45) return '刚刚';
  if (diffSec < 3600) return `${Math.max(1, Math.floor(diffSec / 60))} 分钟前`;
  if (diffSec < 86400) return `${Math.floor(diffSec / 3600)} 小时前`;
  return new Date(timestampMs).toLocaleDateString('zh-CN', {
    month: 'numeric',
    day: 'numeric',
    hour: '2-digit',
    minute: '2-digit',
  });
}

export interface AppUpdateStoreState {
  state: AppUpdateState;
  currentVersion: string;
  autoCheckUpdates: boolean;
  lastUpdateCheckAtMs: number | null;
  skippedVersion: string | null;
  releasesPageUrl: string;
  sheetOpen: boolean;
  hasScheduledLaunchCheck: boolean;

  loadPreferences: () => Promise<UpdatePreferencesDto | null>;
  setAutoCheckUpdates: (enabled: boolean) => Promise<void>;
  clearSkippedVersion: () => Promise<void>;
  skipCurrentUpdate: () => Promise<void>;
  openSheet: () => void;
  closeSheet: () => void;

  scheduleDeferredLaunchCheck: (
    onDiscovered?: (update: AppReleaseUpdate) => void,
    delayMs?: number,
  ) => () => void;
  checkForUpdatesManually: (opts?: { presentSheet?: boolean }) => Promise<void>;
  startDownload: () => Promise<void>;
  cancelDownload: () => Promise<void>;
  installAndRelaunch: () => Promise<void>;
  openDownloadedInstaller: () => Promise<void>;
  revealDownloadedInstaller: () => Promise<void>;
  openReleasePage: () => Promise<void>;

  handleProgressEvent: (progress: UpdateDownloadProgress) => void;
  handlePhaseEvent: (phase: string) => void;
  resetForTests: () => void;
}

const INITIAL_STATE = {
  state: { status: 'idle' } as AppUpdateState,
  currentVersion: '1.4.1',
  autoCheckUpdates: true,
  lastUpdateCheckAtMs: null as number | null,
  skippedVersion: null as string | null,
  releasesPageUrl: DEFAULT_RELEASES_PAGE_URL,
  sheetOpen: false,
  hasScheduledLaunchCheck: false,
};

function applyPreferences(prefs: UpdatePreferencesDto) {
  return {
    currentVersion: prefs.currentVersion || '1.4.1',
    autoCheckUpdates: prefs.autoCheckUpdates,
    lastUpdateCheckAtMs: prefs.lastUpdateCheckAtMs ?? null,
    skippedVersion: prefs.skippedVersion ?? null,
    releasesPageUrl: prefs.releasesPageUrl || DEFAULT_RELEASES_PAGE_URL,
  };
}

export const useAppUpdateStore = create<AppUpdateStoreState>((set, get) => ({
  ...INITIAL_STATE,

  loadPreferences: async () => {
    try {
      const prefs = await getTransport().getUpdatePreferences();
      set(applyPreferences(prefs));
      return prefs;
    } catch {
      return null;
    }
  },

  setAutoCheckUpdates: async (enabled) => {
    set({ autoCheckUpdates: enabled });
    try {
      const prefs = await getTransport().setAutoCheckUpdates(enabled);
      set(applyPreferences(prefs));
    } catch {
      // Keep optimistic value if IPC temporarily fails
    }
  },

  clearSkippedVersion: async () => {
    set({ skippedVersion: null });
    try {
      const prefs = await getTransport().clearSkippedUpdateVersion();
      set(applyPreferences(prefs));
    } catch {
      // Ignore transient errors
    }
  },

  skipCurrentUpdate: async () => {
    const current = get().state;
    const version =
      current.status === 'available' || current.status === 'failed'
        ? current.update?.version
        : undefined;
    if (!version) {
      set({ sheetOpen: false });
      return;
    }
    try {
      const prefs = await getTransport().skipUpdateVersion(version);
      set({
        ...applyPreferences(prefs),
        state: { status: 'idle' },
        sheetOpen: false,
      });
    } catch {
      set({ skippedVersion: version, state: { status: 'idle' }, sheetOpen: false });
    }
  },

  openSheet: () => set({ sheetOpen: true }),
  closeSheet: () => set({ sheetOpen: false }),

  scheduleDeferredLaunchCheck: (onDiscovered, delayMs = 4000) => {
    if (get().hasScheduledLaunchCheck) {
      return () => {};
    }
    set({ hasScheduledLaunchCheck: true });

    let cancelled = false;
    const timer = window.setTimeout(async () => {
      if (cancelled) return;
      const prefs = await get().loadPreferences();
      if (cancelled || !prefs || !prefs.autoCheckUpdates) return;

      const now = Date.now();
      const last = prefs.lastUpdateCheckAtMs ?? null;
      if (last !== null && now - last < AUTOMATIC_CHECK_INTERVAL_MS) {
        return;
      }

      // Avoid interrupting a manual check or download already started by the user.
      const st = get().state.status;
      if (st !== 'idle' && st !== 'upToDate') {
        return;
      }

      try {
        const res = await getTransport().checkForUpdates(false);
        if (cancelled) return;
        set(applyPreferences(res.preferences));

        if (res.outcome.kind === 'updateAvailable') {
          if (res.shouldNotify) {
            set({ state: { status: 'available', update: res.outcome.update } });
            onDiscovered?.(res.outcome.update);
          }
        } else {
          set({
            state: {
              status: 'upToDate',
              checkedAtMs: res.checkedAtMs,
              latestVersion: res.outcome.latestVersion,
            },
          });
        }
      } catch {
        // Automatic launch check stays completely silent when offline or rate-limited.
      }
    }, Math.max(0, delayMs));

    return () => {
      cancelled = true;
      window.clearTimeout(timer);
    };
  },

  checkForUpdatesManually: async (opts) => {
    const presentSheet = opts?.presentSheet ?? true;
    const current = get().state;

    // If a download, verification, or verified installer is already active, surface the sheet
    // directly instead of resetting active work.
    if (
      current.status === 'downloading' ||
      current.status === 'verifying' ||
      current.status === 'readyToInstall' ||
      current.status === 'installing' ||
      current.status === 'manualInstallRequired'
    ) {
      set({ sheetOpen: true });
      return;
    }

    if (current.status === 'checking') {
      if (presentSheet) set({ sheetOpen: true });
      return;
    }

    set({
      state: { status: 'checking' },
      ...(presentSheet ? { sheetOpen: true } : {}),
    });

    try {
      const res = await getTransport().checkForUpdates(true);
      set(applyPreferences(res.preferences));

      if (res.outcome.kind === 'updateAvailable') {
        set({
          state: { status: 'available', update: res.outcome.update },
          sheetOpen: true,
        });
      } else {
        set({
          state: {
            status: 'upToDate',
            checkedAtMs: res.checkedAtMs,
            latestVersion: res.outcome.latestVersion,
          },
          ...(presentSheet ? { sheetOpen: true } : {}),
        });
      }
    } catch (err) {
      const { message } = extractErrorInfo(err);
      set({
        state: { status: 'failed', message, update: null },
        ...(presentSheet ? { sheetOpen: true } : {}),
      });
    }
  },

  startDownload: async () => {
    const current = get().state;
    const update =
      current.status === 'available' || current.status === 'failed'
        ? current.update
        : null;
    if (!update) return;

    set({
      sheetOpen: true,
      state: {
        status: 'downloading',
        update,
        progress: {
          tagName: update.tagName,
          downloadedBytes: 0,
          totalBytes: update.assetSizeBytes,
          fraction: 0,
        },
      },
    });

    try {
      const installer = await getTransport().downloadAndVerifyUpdate(update);
      set({
        state: { status: 'readyToInstall', update, installer },
      });
    } catch (err) {
      const { code, message } = extractErrorInfo(err);
      if (code === 'CANCELLED') {
        set({ state: { status: 'available', update } });
        return;
      }
      set({
        state: { status: 'failed', message, update },
      });
    }
  },

  cancelDownload: async () => {
    const current = get().state;
    try {
      await getTransport().cancelUpdateDownload();
    } catch {
      // Ignore cancel errors
    }
    if (current.status === 'downloading') {
      set({ state: { status: 'available', update: current.update } });
    }
  },

  installAndRelaunch: async () => {
    const current = get().state;
    if (current.status !== 'readyToInstall' && current.status !== 'manualInstallRequired') {
      return;
    }
    const { update, installer } = current;
    set({ state: { status: 'installing', update, installer } });

    try {
      await getTransport().installAndRelaunchUpdate(installer.installerPath);
    } catch (err) {
      const { message } = extractErrorInfo(err);
      set({
        state: {
          status: 'manualInstallRequired',
          update,
          installer,
          reason: message || '自动启动安装程序失败，请手动运行已校验的安装包。',
        },
      });
    }
  },

  openDownloadedInstaller: async () => {
    const current = get().state;
    if (
      current.status !== 'readyToInstall' &&
      current.status !== 'manualInstallRequired' &&
      current.status !== 'installing'
    ) {
      return;
    }
    await getTransport().openUpdateInstaller(current.installer.installerPath);
  },

  revealDownloadedInstaller: async () => {
    const current = get().state;
    if (
      current.status !== 'readyToInstall' &&
      current.status !== 'manualInstallRequired' &&
      current.status !== 'installing'
    ) {
      return;
    }
    await getTransport().revealUpdateInstaller(current.installer.installerPath);
  },

  openReleasePage: async () => {
    const current = get().state;
    let url = get().releasesPageUrl || DEFAULT_RELEASES_PAGE_URL;
    if (
      current.status === 'available' ||
      current.status === 'downloading' ||
      current.status === 'verifying' ||
      current.status === 'readyToInstall' ||
      current.status === 'installing' ||
      current.status === 'manualInstallRequired'
    ) {
      url = current.update.htmlUrl || url;
    } else if (current.status === 'failed' && current.update?.htmlUrl) {
      url = current.update.htmlUrl;
    }
    await getTransport().openExternalUrl(url);
  },

  handleProgressEvent: (progress) => {
    const current = get().state;
    if (current.status !== 'downloading') return;
    if (progress.tagName && progress.tagName !== current.update.tagName) return;
    set({
      state: {
        status: 'downloading',
        update: current.update,
        progress,
      },
    });
  },

  handlePhaseEvent: (phase) => {
    const current = get().state;
    if (phase === 'verifying' && current.status === 'downloading') {
      set({
        state: {
          status: 'verifying',
          update: current.update,
        },
      });
    }
  },

  resetForTests: () => set({ ...INITIAL_STATE }),
}));
