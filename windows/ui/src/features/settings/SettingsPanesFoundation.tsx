import React, { useEffect, useState } from 'react';
import {
  ArrowRightLeft,
  CheckCircle2,
  Cloud,
  FolderOpen,
  HardDrive,
  RefreshCw,
  Trash2,
} from 'lucide-react';
import { getTransport } from '../../api/transport';
import { Button, SegmentedControl, type ThemeMode } from '../../design-system';
import { useCoordinatorStore, useSyncAIStore } from '../../stores';
import type {
  DriveSyncConfig,
  DriveTransportMode,
  GalleryLayoutMode,
  StorageMigrationReport,
} from '../../types/domain';

function formatBytes(bytes: number): string {
  if (bytes <= 0) return '0 B';
  const units = ['B', 'KB', 'MB', 'GB', 'TB'];
  let val = bytes;
  let idx = 0;
  while (val >= 1024 && idx < units.length - 1) {
    val /= 1024;
    idx += 1;
  }
  return `${val.toFixed(idx === 0 ? 0 : 1)} ${units[idx]}`;
}

export const GeneralSettingsPane: React.FC = () => {
  const themeMode = useCoordinatorStore((s) => s.themeMode);
  const setThemeMode = useCoordinatorStore((s) => s.setThemeMode);
  const layoutMode = useCoordinatorStore((s) => s.layoutMode);
  const setLayoutMode = useCoordinatorStore((s) => s.setLayoutMode);
  const surfaceState = useCoordinatorStore((s) => s.surfaceState);
  const pushToast = useCoordinatorStore((s) => s.pushToast);

  const [autostart, setAutostart] = useState(false);

  useEffect(() => {
    void getTransport()
      .getDesktopIntegrationStatus()
      .then((st) => setAutostart(st.autostartEnabled))
      .catch(() => {});
  }, []);

  return (
    <div data-testid="settings-pane-general" className="flex flex-col gap-4">
      <div>
        <h2 className="text-[16px] font-semibold text-[var(--text-primary)]">通用</h2>
        <p className="text-[12px] text-[var(--text-secondary)] mt-0.5">
          调整外观主题、默认画廊排版及 Windows 登录自启动偏好。
        </p>
      </div>

      <section className="rounded-[var(--radius-settings-outer)] bg-[var(--bg-elevated)] border border-[var(--border-hairline)] p-4 flex flex-col gap-3.5">
        <div className="flex items-center justify-between gap-3">
          <div>
            <div className="text-[13px] font-medium text-[var(--text-primary)]">界面主题</div>
            <div className="text-[11.5px] text-[var(--text-tertiary)]">
              跟随 Windows 系统外观或固定浅色 / 深色画廊氛围
            </div>
          </div>
          <SegmentedControl<ThemeMode>
            value={themeMode}
            onChange={(m) => void setThemeMode(m)}
            ariaLabel="界面主题选择"
            options={[
              { value: 'system', label: '跟随系统' },
              { value: 'light', label: '浅色' },
              { value: 'dark', label: '深色' },
            ]}
          />
        </div>

        <div className="h-px bg-[var(--border-hairline)]" />

        <div className="flex items-center justify-between gap-3">
          <div>
            <div className="text-[13px] font-medium text-[var(--text-primary)]">默认画廊布局</div>
            <div className="text-[11.5px] text-[var(--text-tertiary)]">
              也可随时通过 Ctrl+1 / 2 / 3 在画廊内即时切换
            </div>
          </div>
          <SegmentedControl<GalleryLayoutMode>
            value={layoutMode}
            onChange={setLayoutMode}
            ariaLabel="默认画廊布局"
            options={[
              { value: 'verticalMasonry', label: '瀑布流' },
              { value: 'horizontalJustified', label: '等高行' },
              { value: 'galleryFilmstrip', label: '胶片带' },
            ]}
          />
        </div>

        <div className="h-px bg-[var(--border-hairline)]" />

        <label className="flex items-center justify-between gap-3 cursor-pointer">
          <div>
            <div className="text-[13px] font-medium text-[var(--text-primary)]">
              开机自动启动 Charkle
            </div>
            <div className="text-[11.5px] text-[var(--text-tertiary)]">
              登录后驻留系统托盘，保持全局快捷键与顶部悬浮窗随时待命
            </div>
          </div>
          <input
            type="checkbox"
            checked={autostart}
            onChange={async (e) => {
              const next = e.target.checked;
              const applied = await getTransport().setAutostartEnabled(next);
              setAutostart(applied);
              pushToast({
                message: applied ? '已开启开机自启动' : '已关闭开机自启动',
                tone: 'info',
              });
            }}
            className="h-4 w-4 accent-[var(--accent)]"
          />
        </label>

        <div className="h-px bg-[var(--border-hairline)]" />

        <div className="flex items-center justify-between text-[12px]">
          <span className="text-[var(--text-secondary)]">界面语言</span>
          <span className="text-[var(--text-primary)] font-medium">简体中文（Windows）</span>
        </div>

        <div className="flex items-center justify-between text-[12px]">
          <span className="text-[var(--text-secondary)]">窗口材质渲染</span>
          <span className="text-[var(--text-tertiary)]">
            {surfaceState?.backdrop === 'mica'
              ? 'Windows 11 Mica 材质已启用'
              : '中性纯色画廊底色（兼容模式 / 透明效果关闭）'}
          </span>
        </div>
      </section>
    </div>
  );
};

export const LibrarySettingsPane: React.FC = () => {
  const cacheStats = useSyncAIStore((s) => s.cacheStats);
  const diagnostics = useSyncAIStore((s) => s.diagnostics);
  const setCacheBudgetBytes = useSyncAIStore((s) => s.setCacheBudgetBytes);
  const evictCacheNow = useSyncAIStore((s) => s.evictCacheNow);

  const budgetGb = Math.max(
    2,
    Math.min(100, Math.round((cacheStats?.budgetBytes ?? 10 * 1024 ** 3) / 1024 ** 3)),
  );
  const [sliderGb, setSliderGb] = useState(budgetGb);

  useEffect(() => {
    setSliderGb(budgetGb);
  }, [budgetGb]);

  const totalUsed =
    (cacheStats?.thumbnailBytes ?? 0) + (cacheStats?.originalCacheBytes ?? 0);

  return (
    <div data-testid="settings-pane-library" className="flex flex-col gap-4">
      <div>
        <h2 className="text-[16px] font-semibold text-[var(--text-primary)]">素材库</h2>
        <p className="text-[12px] text-[var(--text-secondary)] mt-0.5">
          管理本地索引目录与按需原图 LRU 缓存预算，已标记「离线常驻」的素材与情绪板永不被自动清理。
        </p>
      </div>

      <section className="rounded-[var(--radius-settings-outer)] bg-[var(--bg-elevated)] border border-[var(--border-hairline)] p-4 flex flex-col gap-3">
        <div className="flex items-center justify-between gap-2">
          <div className="min-w-0">
            <div className="text-[12px] font-medium text-[var(--text-secondary)]">本地数据库与缓存目录</div>
            <div className="text-[12.5px] font-mono text-[var(--text-primary)] truncate mt-0.5">
              {diagnostics?.dataDir ?? '%LOCALAPPDATA%\\Charkle'}
            </div>
          </div>
          <Button
            variant="secondary"
            size="xs"
            onClick={() => void getTransport().revealInExplorer(diagnostics?.dataDir ?? '')}
          >
            <FolderOpen size={13} />
            打开目录
          </Button>
        </div>

        <div className="grid grid-cols-3 gap-2.5 pt-1">
          <div className="rounded-[var(--radius-settings-inner)] bg-[var(--bg-subtle)]/70 p-3">
            <div className="text-[11px] text-[var(--text-tertiary)]">缩略图缓存</div>
            <div className="text-[15px] font-semibold text-[var(--text-primary)] charkle-tabular mt-1">
              {formatBytes(cacheStats?.thumbnailBytes ?? 0)}
            </div>
          </div>
          <div className="rounded-[var(--radius-settings-inner)] bg-[var(--bg-subtle)]/70 p-3">
            <div className="text-[11px] text-[var(--text-tertiary)]">本地原图缓存</div>
            <div className="text-[15px] font-semibold text-[var(--text-primary)] charkle-tabular mt-1">
              {formatBytes(cacheStats?.originalCacheBytes ?? 0)}
            </div>
            <div className="text-[10.5px] text-[var(--text-tertiary)] mt-0.5">
              {cacheStats?.cachedOriginalCount ?? 0} 个文件
            </div>
          </div>
          <div className="rounded-[var(--radius-settings-inner)] bg-[var(--bg-subtle)]/70 p-3">
            <div className="text-[11px] text-[var(--text-tertiary)]">离线常驻保护</div>
            <div className="text-[15px] font-semibold text-[var(--accent)] charkle-tabular mt-1">
              {formatBytes(cacheStats?.pinnedOfflineBytes ?? 0)}
            </div>
            <div className="text-[10.5px] text-[var(--text-tertiary)] mt-0.5">
              {cacheStats?.pinnedAssetCount ?? 0} 项受保护
            </div>
          </div>
        </div>

        <div className="flex flex-col gap-1.5 pt-1">
          <div className="flex items-center justify-between text-[12.5px]">
            <span className="font-medium text-[var(--text-primary)]">本地原图 LRU 缓存上限</span>
            <span className="font-semibold text-[var(--accent)] charkle-tabular">
              {sliderGb} GB（已用 {formatBytes(totalUsed)}）
            </span>
          </div>
          <input
            type="range"
            aria-label="本地缓存预算 GB"
            min={2}
            max={100}
            step={1}
            value={sliderGb}
            onChange={(e) => setSliderGb(Number(e.target.value))}
            onMouseUp={() => void setCacheBudgetBytes(sliderGb * 1024 ** 3)}
            onKeyUp={() => void setCacheBudgetBytes(sliderGb * 1024 ** 3)}
            className="w-full accent-[var(--accent)]"
          />
          <div className="flex items-center justify-between text-[11px] text-[var(--text-tertiary)]">
            <span>2 GB</span>
            <span>100 GB</span>
          </div>
        </div>

        <div className="flex items-center justify-end gap-2 pt-1 border-t border-[var(--border-hairline)]">
          <Button variant="secondary" size="sm" onClick={() => void evictCacheNow()}>
            <Trash2 size={13.5} />
            立即按 LRU 清理未固定缓存
          </Button>
        </div>
      </section>
    </div>
  );
};

export const SyncSettingsPane: React.FC = () => {
  const syncConfig = useSyncAIStore((s) => s.syncConfig);
  const syncStatus = useSyncAIStore((s) => s.syncStatus);
  const syncing = useSyncAIStore((s) => s.syncing);
  const migrating = useSyncAIStore((s) => s.migrating);
  const diagnostics = useSyncAIStore((s) => s.diagnostics);
  const saveSyncConfig = useSyncAIStore((s) => s.saveSyncConfig);
  const runStorageMigration = useSyncAIStore((s) => s.runStorageMigration);
  const syncNow = useSyncAIStore((s) => s.syncNow);

  const [draft, setDraft] = useState<DriveSyncConfig>(
    syncConfig ?? {
      mode: 'localOnly',
      rootFolderName: 'Charkle',
      sharedFolderURLOrID: '',
      mountPath: 'G:\\',
      useGDirectIPAcceleration: true,
      webDAVServerURL: '',
      webDAVUsername: '',
      webDAVRemotePath: '/Charkle',
      localLibraryPath: '',
      autoSyncIntervalSeconds: 120,
      syncThumbnails: true,
      syncEmbeddings: true,
    },
  );
  const [webdavPassword, setWebdavPassword] = useState('');
  const [migrationReport, setMigrationReport] = useState<StorageMigrationReport | null>(null);

  useEffect(() => {
    if (syncConfig) setDraft(syncConfig);
  }, [syncConfig]);

  const modeChanged = syncConfig != null && draft.mode !== syncConfig.mode;

  return (
    <div data-testid="settings-pane-sync" className="flex flex-col gap-4">
      <div className="flex items-start justify-between gap-2">
        <div>
          <h2 className="text-[16px] font-semibold text-[var(--text-primary)]">云同步与存储迁移</h2>
          <p className="text-[12px] text-[var(--text-secondary)] mt-0.5">
            完全兼容 macOS `/.charkle/` 同步协议，支持 Google Drive、WebDAV、Windows 挂载盘与纯本地目录无损双向切换。
          </p>
        </div>
        <Button variant="secondary" size="xs" loading={syncing} onClick={() => void syncNow()}>
          <RefreshCw size={12.5} />
          立即同步
        </Button>
      </div>

      <section className="rounded-[var(--radius-settings-outer)] bg-[var(--bg-elevated)] border border-[var(--border-hairline)] p-4 flex flex-col gap-3.5">
        <div className="flex flex-col gap-1.5">
          <span className="text-[12px] font-medium text-[var(--text-secondary)]">存储与同步后端</span>
          <SegmentedControl<DriveTransportMode>
            value={draft.mode}
            onChange={(mode) => setDraft({ ...draft, mode })}
            ariaLabel="同步后端选择"
            options={[
              { value: 'directAPIWithGDirect', label: 'Google Drive' },
              { value: 'webDAV', label: 'WebDAV' },
              { value: 'gdirectMount', label: 'Windows 挂载盘' },
              { value: 'localOnly', label: '纯本地文件夹' },
            ]}
          />
        </div>

        {draft.mode === 'directAPIWithGDirect' && (
          <div className="grid grid-cols-1 gap-2.5">
            <label className="flex flex-col gap-1 text-[12px]">
              <span className="text-[var(--text-secondary)]">云端根目录名称</span>
              <input
                type="text"
                value={draft.rootFolderName}
                onChange={(e) => setDraft({ ...draft, rootFolderName: e.target.value })}
                className="h-8 px-2.5 rounded-[var(--radius-settings-inner)] bg-[var(--bg-inspector-field)] border border-[var(--border-hairline)] text-[12.5px] text-[var(--text-primary)] outline-none focus:border-[var(--accent)]"
              />
            </label>
            <label className="flex flex-col gap-1 text-[12px]">
              <span className="text-[var(--text-secondary)]">
                团队共享文件夹链接或 ID（可选，自动识别 `folders/&lt;id&gt;`）
              </span>
              <input
                type="text"
                value={draft.sharedFolderURLOrID}
                onChange={(e) => setDraft({ ...draft, sharedFolderURLOrID: e.target.value })}
                placeholder="https://drive.google.com/drive/folders/..."
                className="h-8 px-2.5 rounded-[var(--radius-settings-inner)] bg-[var(--bg-inspector-field)] border border-[var(--border-hairline)] text-[12.5px] text-[var(--text-primary)] outline-none focus:border-[var(--accent)]"
              />
            </label>
          </div>
        )}

        {draft.mode === 'webDAV' && (
          <div className="grid grid-cols-1 sm:grid-cols-2 gap-2.5">
            <label className="sm:col-span-2 flex flex-col gap-1 text-[12px]">
              <span className="text-[var(--text-secondary)]">WebDAV 服务器地址（远程须 HTTPS）</span>
              <input
                type="text"
                value={draft.webDAVServerURL}
                onChange={(e) => setDraft({ ...draft, webDAVServerURL: e.target.value })}
                placeholder="https://dav.example.com/dav/"
                className="h-8 px-2.5 rounded-[var(--radius-settings-inner)] bg-[var(--bg-inspector-field)] border border-[var(--border-hairline)] text-[12.5px] text-[var(--text-primary)] outline-none focus:border-[var(--accent)]"
              />
            </label>
            <label className="flex flex-col gap-1 text-[12px]">
              <span className="text-[var(--text-secondary)]">用户名</span>
              <input
                type="text"
                value={draft.webDAVUsername}
                onChange={(e) => setDraft({ ...draft, webDAVUsername: e.target.value })}
                className="h-8 px-2.5 rounded-[var(--radius-settings-inner)] bg-[var(--bg-inspector-field)] border border-[var(--border-hairline)] text-[12.5px] text-[var(--text-primary)] outline-none focus:border-[var(--accent)]"
              />
            </label>
            <label className="flex flex-col gap-1 text-[12px]">
              <span className="text-[var(--text-secondary)]">密码（加密存于 Windows 凭据管理器）</span>
              <input
                type="password"
                value={webdavPassword}
                onChange={(e) => setWebdavPassword(e.target.value)}
                placeholder="留空则保持已有密码不变"
                className="h-8 px-2.5 rounded-[var(--radius-settings-inner)] bg-[var(--bg-inspector-field)] border border-[var(--border-hairline)] text-[12.5px] text-[var(--text-primary)] outline-none focus:border-[var(--accent)]"
              />
            </label>
            <label className="sm:col-span-2 flex flex-col gap-1 text-[12px]">
              <span className="text-[var(--text-secondary)]">远程子目录路径</span>
              <input
                type="text"
                value={draft.webDAVRemotePath}
                onChange={(e) => setDraft({ ...draft, webDAVRemotePath: e.target.value })}
                className="h-8 px-2.5 rounded-[var(--radius-settings-inner)] bg-[var(--bg-inspector-field)] border border-[var(--border-hairline)] text-[12.5px] text-[var(--text-primary)] outline-none focus:border-[var(--accent)]"
              />
            </label>
          </div>
        )}

        {draft.mode === 'gdirectMount' && (
          <div className="flex flex-col gap-2.5">
            <label className="flex flex-col gap-1 text-[12px]">
              <span className="text-[var(--text-secondary)]">
                Windows 挂载盘符或映射目录（如 `G:\` 或 OneDrive / SMB / gdirect 路径）
              </span>
              <div className="flex gap-2">
                <input
                  type="text"
                  value={draft.mountPath}
                  onChange={(e) => setDraft({ ...draft, mountPath: e.target.value })}
                  className="flex-1 h-8 px-2.5 rounded-[var(--radius-settings-inner)] bg-[var(--bg-inspector-field)] border border-[var(--border-hairline)] text-[12.5px] text-[var(--text-primary)] outline-none focus:border-[var(--accent)]"
                />
                <Button
                  variant="secondary"
                  size="xs"
                  onClick={async () => {
                    const picked = await getTransport().pickDirectoryDialog('选择挂载根目录');
                    if (picked) setDraft({ ...draft, mountPath: picked });
                  }}
                >
                  浏览…
                </Button>
              </div>
            </label>
            <div className="rounded-[var(--radius-settings-inner)] bg-[var(--bg-subtle)]/70 p-2.5 text-[11.5px] text-[var(--text-secondary)] flex items-center justify-between">
              <span className="inline-flex items-center gap-1.5">
                <HardDrive size={13} />
                挂载探针：{diagnostics?.gdirect.isMountActive ? '卷已就绪' : '未检测到活跃挂载路径'}
              </span>
              <span className="text-[var(--text-tertiary)]">
                gdirect.exe：{diagnostics?.gdirect.cliPath ? '已检测到' : '可选未安装'}
              </span>
            </div>
          </div>
        )}

        {draft.mode === 'localOnly' && (
          <label className="flex flex-col gap-1 text-[12px]">
            <span className="text-[var(--text-secondary)]">纯本地素材库目录</span>
            <div className="flex gap-2">
              <input
                type="text"
                value={draft.localLibraryPath}
                onChange={(e) => setDraft({ ...draft, localLibraryPath: e.target.value })}
                placeholder="例如：D:\DesignAssets\Charkle"
                className="flex-1 h-8 px-2.5 rounded-[var(--radius-settings-inner)] bg-[var(--bg-inspector-field)] border border-[var(--border-hairline)] text-[12.5px] text-[var(--text-primary)] outline-none focus:border-[var(--accent)]"
              />
              <Button
                variant="secondary"
                size="xs"
                onClick={async () => {
                  const picked = await getTransport().pickDirectoryDialog('选择本地素材库目录');
                  if (picked) setDraft({ ...draft, localLibraryPath: picked });
                }}
              >
                选择目录…
              </Button>
            </div>
          </label>
        )}

        <div className="flex items-center justify-between gap-2 pt-2 border-t border-[var(--border-hairline)]">
          <div className="text-[11.5px] text-[var(--text-tertiary)] flex items-center gap-1.5">
            <Cloud size={13} />
            <span>
              待同步操作：{syncStatus?.pendingOpCount ?? 0} 条
            </span>
          </div>
          <div className="flex items-center gap-2">
            {modeChanged && (
              <Button
                variant="secondary"
                size="sm"
                loading={migrating}
                onClick={async () => {
                  const report = await runStorageMigration(draft, webdavPassword);
                  if (report) setMigrationReport(report);
                }}
              >
                <ArrowRightLeft size={13.5} />
                无损迁移现有素材至新后端
              </Button>
            )}
            <Button
              variant="primary"
              size="sm"
              onClick={() => void saveSyncConfig(draft, webdavPassword)}
            >
              保存同步配置
            </Button>
          </div>
        </div>

        {migrationReport && (
          <div
            data-testid="storage-migration-report"
            className="rounded-[var(--radius-settings-inner)] bg-[var(--accent-soft)]/60 border border-[var(--accent)]/30 p-3 text-[12px] text-[var(--text-primary)] flex items-center gap-2"
          >
            <CheckCircle2 size={15} className="text-[var(--accent)] shrink-0" />
            <span>
              已完成无损存储迁移：{migrationReport.migratedAssets} 项素材、
              {migrationReport.migratedFolders} 个文件夹、{migrationReport.migratedBoards} 块情绪板已迁移至{' '}
              {migrationReport.targetLocation}。
            </span>
          </div>
        )}
      </section>
    </div>
  );
};
