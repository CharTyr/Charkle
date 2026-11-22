import React, { useEffect, useState } from 'react';
import {
  ArrowLeftRight,
  CheckCircle2,
  Cloud,
  ExternalLink,
  FolderSearch,
  Key,
  RefreshCw,
  Server,
} from 'lucide-react';
import {
  createDefaultDriveSyncConfig,
  driveTransportModeLocalizedLabel,
  extractGoogleDriveFolderID,
  isSyncStatusActive,
  syncStatusLocalizedPhaseTitle,
} from '@charkle/shared';
import type { DriveSyncConfig, DriveTransportMode, RemoteDriveFile } from '@charkle/shared';
import { apiClient } from '../../api/client';
import { Button } from '../../design-system/Button';
import { ModalShell } from '../../design-system/ModalShell';
import { useCoordinatorStore } from '../../stores/coordinatorStore';
import { useSyncAIStore } from '../../stores/syncAIStore';
import {
  SettingsCard,
  SettingsDivider,
  SettingsHeader,
  SettingsInput,
  SettingsRow,
  SettingsSwitch,
} from './SettingsPrimitives';
import { StorageMigrationModal } from './StorageMigrationModal';
import { formatRelativeDate } from './shortcuts';

const PRIMARY_MODES: ReadonlyArray<DriveTransportMode> = [
  'directAPIWithGDirect',
  'webDAV',
  'localOnly',
];

export const CloudSyncTab: React.FC = () => {
  const syncConfig = useSyncAIStore((s) => s.syncConfig);
  const syncStatus = useSyncAIStore((s) => s.syncStatus);
  const hasGoogleOAuthConfig = useSyncAIStore((s) => s.hasGoogleOAuthConfig);
  const hasWebDAVPassword = useSyncAIStore((s) => s.hasWebDAVPassword);
  const activeStorageSummary = useSyncAIStore((s) => s.activeStorageSummary);
  const isSyncingNow = useSyncAIStore((s) => s.isSyncingNow);

  const loadSyncConfig = useSyncAIStore((s) => s.loadSyncConfig);
  const saveSyncConfig = useSyncAIStore((s) => s.saveSyncConfig);
  const syncNow = useSyncAIStore((s) => s.syncNow);
  const pushToast = useCoordinatorStore((s) => s.pushToast);

  const [draft, setDraft] = useState<DriveSyncConfig>(createDefaultDriveSyncConfig());
  const [webDAVPassword, setWebDAVPassword] = useState('');
  const [saving, setSaving] = useState(false);
  const [testingWebDAV, setTestingWebDAV] = useState(false);

  // Google Drive OAuth & Shared Folder Picker modals
  const [oauthSheetOpen, setOauthSheetOpen] = useState(false);
  const [oauthClientID, setOauthClientID] = useState('');
  const [oauthClientSecret, setOauthClientSecret] = useState('');
  const [savingOAuth, setSavingOAuth] = useState(false);

  const [sharedPickerOpen, setSharedPickerOpen] = useState(false);
  const [sharedFolders, setSharedFolders] = useState<RemoteDriveFile[]>([]);
  const [loadingShared, setLoadingShared] = useState(false);

  const [migrationOpen, setMigrationOpen] = useState(false);

  useEffect(() => {
    void loadSyncConfig();
  }, [loadSyncConfig]);

  useEffect(() => {
    if (syncConfig) {
      setDraft(syncConfig);
    }
  }, [syncConfig]);

  const parsedSharedID = extractGoogleDriveFolderID(draft.sharedFolderURLOrID);

  const handleSave = async (nextConfig: DriveSyncConfig = draft) => {
    setSaving(true);
    try {
      await saveSyncConfig(nextConfig, webDAVPassword || null);
      setWebDAVPassword('');
      pushToast({ tone: 'success', message: '存储与同步配置已保存' });
    } catch (err) {
      pushToast({
        tone: 'error',
        message: err instanceof Error ? err.message : '保存同步配置失败',
      });
    } finally {
      setSaving(false);
    }
  };

  const handleSyncNow = async () => {
    try {
      const report = await syncNow();
      pushToast({
        tone: 'success',
        message: `同步完成：上传 ${report.uploadedOps} 条，拉取 ${report.downloadedOps} 条，发现 ${report.discoveredRemoteAssets} 项远端素材`,
      });
    } catch (err) {
      pushToast({
        tone: 'error',
        message: err instanceof Error ? err.message : '立即同步失败',
      });
    }
  };

  const handleStartGoogleOAuth = async () => {
    try {
      const { authURL } = await apiClient.startGoogleOAuth();
      window.open(authURL, '_blank', 'noopener,noreferrer');
      pushToast({ tone: 'info', message: '已打开 Google 授权页，授权完成后请刷新同步状态' });
    } catch (err) {
      pushToast({
        tone: 'error',
        message: err instanceof Error ? err.message : '请先配置 Google OAuth Client ID 与 Secret',
      });
    }
  };

  const handleSignOutGoogle = async () => {
    try {
      await apiClient.signOutGoogleDrive();
      await loadSyncConfig();
      pushToast({ tone: 'info', message: '已退出 Google Drive 账号' });
    } catch (err) {
      pushToast({
        tone: 'error',
        message: err instanceof Error ? err.message : '退出 Google 账号失败',
      });
    }
  };

  const handleSaveOAuthCreds = async (e: React.FormEvent) => {
    e.preventDefault();
    if (!oauthClientID.trim() || !oauthClientSecret.trim()) return;
    setSavingOAuth(true);
    try {
      await apiClient.saveGoogleOAuthConfig({
        clientID: oauthClientID.trim(),
        clientSecret: oauthClientSecret.trim(),
      });
      await loadSyncConfig();
      setOauthSheetOpen(false);
      setOauthClientID('');
      setOauthClientSecret('');
      pushToast({ tone: 'success', message: 'Google OAuth 凭据已安全保存至加密密钥库' });
    } catch (err) {
      pushToast({
        tone: 'error',
        message: err instanceof Error ? err.message : '保存 OAuth 凭据失败',
      });
    } finally {
      setSavingOAuth(false);
    }
  };

  const handleLoadSharedFolders = async () => {
    setSharedPickerOpen(true);
    setLoadingShared(true);
    try {
      const res = await apiClient.listGoogleSharedFolders();
      setSharedFolders(res.folders);
    } catch (err) {
      pushToast({
        tone: 'error',
        message: err instanceof Error ? err.message : '读取共享文件夹列表失败',
      });
    } finally {
      setLoadingShared(false);
    }
  };

  const handleTestWebDAV = async () => {
    setTestingWebDAV(true);
    try {
      const res = await apiClient.testWebDAV({
        config: draft,
        password: webDAVPassword || null,
      });
      pushToast({
        tone: 'success',
        message: `WebDAV 连接正常（账号：${res.account.email || draft.webDAVUsername || '已验证'}）`,
      });
    } catch (err) {
      pushToast({
        tone: 'error',
        message: err instanceof Error ? err.message : 'WebDAV 连接测试失败',
      });
    } finally {
      setTestingWebDAV(false);
    }
  };

  const activeModeForSegment: DriveTransportMode =
    draft.mode === 'gdirectMount' ? 'directAPIWithGDirect' : draft.mode;
  const syncing = isSyncingNow || isSyncStatusActive(syncStatus);
  const progressPct =
    syncStatus.progressFraction != null
      ? Math.round(Math.max(0, Math.min(1, syncStatus.progressFraction)) * 100)
      : null;

  return (
    <div className="flex flex-col gap-5">
      <SettingsHeader
        title="存储与同步"
        subtitle="自由选择 Google Drive、WebDAV 云盘或纯本地文件夹保存素材库，使用标准 /.charkle/ 协议与 macOS 版 Charkle 双向无损互通。"
      />

      {/* Backend Mode Selector */}
      <SettingsCard>
        <SettingsRow
          title="素材库存储方式"
          subtitle={`当前生效路径：${activeStorageSummary}`}
        >
          <div className="inline-flex p-0.5 rounded-[var(--radius-settings-inner)] bg-[var(--bg-subtle)] border border-[var(--border-hairline)]">
            {PRIMARY_MODES.map((m) => (
              <button
                key={m}
                type="button"
                onClick={() => {
                  const next = { ...draft, mode: m };
                  setDraft(next);
                  void handleSave(next);
                }}
                className={[
                  'px-2.5 py-1 rounded-[6px] text-[11.5px] font-medium cursor-pointer',
                  activeModeForSegment === m
                    ? 'bg-[var(--bg-elevated)] text-[var(--text-primary)] shadow-xs'
                    : 'text-[var(--text-secondary)] hover:text-[var(--text-primary)]',
                ].join(' ')}
              >
                {driveTransportModeLocalizedLabel(m)}
              </button>
            ))}
          </div>
        </SettingsRow>

        <SettingsDivider />

        {/* Mode-specific configuration */}
        {activeModeForSegment === 'directAPIWithGDirect' && (
          <div className="flex flex-col gap-3.5">
            <div className="flex flex-wrap items-center justify-between gap-3">
              <div className="flex items-center gap-2.5">
                <Cloud size={16} className="text-[var(--accent)]" />
                <div>
                  <div className="text-[12.5px] font-medium text-[var(--text-primary)]">
                    {syncStatus.account
                      ? `已登录：${syncStatus.account.email}`
                      : 'Google Drive 账号未连接'}
                  </div>
                  <div className="text-[11px] text-[var(--text-secondary)]">
                    {hasGoogleOAuthConfig
                      ? '已配置 OAuth Client ID / Secret'
                      : '首次使用请先填入自建 Google Cloud OAuth 凭据'}
                  </div>
                </div>
              </div>
              <div className="flex items-center gap-2">
                <Button variant="secondary" size="xs" onClick={() => setOauthSheetOpen(true)}>
                  <Key size={12} />
                  {hasGoogleOAuthConfig ? '修改 OAuth 凭据' : '配置 OAuth 凭据'}
                </Button>
                {syncStatus.account ? (
                  <Button variant="ghost" size="xs" onClick={() => void handleSignOutGoogle()}>
                    退出账号
                  </Button>
                ) : (
                  <Button
                    variant="primary"
                    size="xs"
                    disabled={!hasGoogleOAuthConfig}
                    onClick={() => void handleStartGoogleOAuth()}
                  >
                    <ExternalLink size={12} />
                    授权登录 Google Drive
                  </Button>
                )}
              </div>
            </div>

            <div className="grid grid-cols-1 sm:grid-cols-2 gap-3">
              <div>
                <label className="block text-[11.5px] font-medium text-[var(--text-secondary)] mb-1">
                  云端根目录名称
                </label>
                <SettingsInput
                  type="text"
                  value={draft.rootFolderName}
                  onChange={(e) => setDraft((d) => ({ ...d, rootFolderName: e.target.value }))}
                  placeholder="Charkle"
                  className="w-full"
                />
              </div>
              <div>
                <label className="block text-[11.5px] font-medium text-[var(--text-secondary)] mb-1">
                  共享文件夹 URL 或 ID（可选）
                </label>
                <div className="flex items-center gap-1.5">
                  <SettingsInput
                    type="text"
                    value={draft.sharedFolderURLOrID}
                    onChange={(e) =>
                      setDraft((d) => ({ ...d, sharedFolderURLOrID: e.target.value }))
                    }
                    placeholder="https://drive.google.com/drive/folders/..."
                    className="flex-1 min-w-0"
                  />
                  <Button
                    variant="secondary"
                    size="xs"
                    disabled={!syncStatus.account}
                    onClick={() => void handleLoadSharedFolders()}
                    title="从「与我共享」目录中选取"
                  >
                    <FolderSearch size={13} />
                    选择
                  </Button>
                </div>
                {draft.sharedFolderURLOrID.trim() && (
                  <div className="text-[11px] mt-1">
                    {parsedSharedID ? (
                      <span className="text-[var(--success)]">
                        已识别 Folder ID：{parsedSharedID}
                      </span>
                    ) : (
                      <span className="text-[var(--warning)]">
                        无法解析文件夹 ID，请粘贴完整 Google Drive 共享链接
                      </span>
                    )}
                  </div>
                )}
              </div>
            </div>

            {/* gdirect macOS Interoperability Info Card */}
            <div className="p-3 rounded-[var(--radius-settings-inner)] bg-[var(--bg-gallery)] border border-[var(--border-hairline)] text-[11.5px] text-[var(--text-secondary)] leading-relaxed">
              <strong className="text-[var(--text-primary)]">macOS `gdirect` 互通说明：</strong>
              Web 服务端通过 Google Drive API v3 直接读写与 macOS 版 Charkle（含 `gdirect` 加速模式）完全一致的{' '}
              <code className="font-mono text-[11px]">/.charkle/</code> 目录（Cocoa 纪元时间戳、大写 UUID、ops JSONL 与情绪板 JSON），双端实时无损同步。
            </div>
          </div>
        )}

        {activeModeForSegment === 'webDAV' && (
          <div className="flex flex-col gap-3">
            <div className="grid grid-cols-1 sm:grid-cols-2 gap-3">
              <div className="sm:col-span-2">
                <label className="block text-[11.5px] font-medium text-[var(--text-secondary)] mb-1">
                  WebDAV 服务器地址
                </label>
                <SettingsInput
                  type="url"
                  value={draft.webDAVServerURL}
                  onChange={(e) => setDraft((d) => ({ ...d, webDAVServerURL: e.target.value }))}
                  placeholder="https://dav.jianguoyun.com/dav/"
                  className="w-full"
                />
              </div>
              <div>
                <label className="block text-[11.5px] font-medium text-[var(--text-secondary)] mb-1">
                  用户名
                </label>
                <SettingsInput
                  type="text"
                  value={draft.webDAVUsername}
                  onChange={(e) => setDraft((d) => ({ ...d, webDAVUsername: e.target.value }))}
                  className="w-full"
                />
              </div>
              <div>
                <label className="block text-[11.5px] font-medium text-[var(--text-secondary)] mb-1">
                  密码 / 应用专用密码 {hasWebDAVPassword ? '（已保存）' : ''}
                </label>
                <SettingsInput
                  type="password"
                  value={webDAVPassword}
                  onChange={(e) => setWebDAVPassword(e.target.value)}
                  placeholder={hasWebDAVPassword ? '••••••••（留空保持不变）' : '输入密码'}
                  className="w-full"
                />
              </div>
              <div className="sm:col-span-2">
                <label className="block text-[11.5px] font-medium text-[var(--text-secondary)] mb-1">
                  远程路径
                </label>
                <SettingsInput
                  type="text"
                  value={draft.webDAVRemotePath}
                  onChange={(e) => setDraft((d) => ({ ...d, webDAVRemotePath: e.target.value }))}
                  placeholder="/Charkle"
                  className="w-full"
                />
              </div>
            </div>

            <div className="flex items-center justify-end gap-2">
              <Button
                variant="secondary"
                size="xs"
                loading={testingWebDAV}
                onClick={() => void handleTestWebDAV()}
              >
                <Server size={12} />
                测试连接
              </Button>
            </div>
          </div>
        )}

        {activeModeForSegment === 'localOnly' && (
          <div className="flex flex-col gap-2">
            <label className="block text-[11.5px] font-medium text-[var(--text-secondary)]">
              本地素材库目录路径
            </label>
            <SettingsInput
              type="text"
              value={draft.localLibraryPath}
              onChange={(e) => setDraft((d) => ({ ...d, localLibraryPath: e.target.value }))}
              placeholder=".charkle-data/library"
              className="w-full font-mono text-[12px]"
            />
            <p className="text-[11.5px] text-[var(--text-tertiary)]">
              纯本地模式将所有原文件与 `/.charkle/` 索引保存在服务器指定目录，无需外部云盘凭据。
            </p>
          </div>
        )}

        <div className="flex justify-end pt-1">
          <Button variant="primary" size="sm" loading={saving} onClick={() => void handleSave()}>
            保存存储配置
          </Button>
        </div>
      </SettingsCard>

      {/* Live Sync Progress Card */}
      <SettingsCard
        title="实时同步状态"
        badge={
          <Button
            variant="secondary"
            size="xs"
            loading={syncing}
            onClick={() => void handleSyncNow()}
          >
            <RefreshCw size={12} className={syncing ? 'animate-spin' : ''} />
            立即同步
          </Button>
        }
      >
        <div className="flex flex-col gap-2.5">
          <div className="flex items-center justify-between text-[12.5px]">
            <span className="font-medium text-[var(--text-primary)] inline-flex items-center gap-2">
              <CheckCircle2
                size={14}
                className={
                  syncStatus.phase.type === 'error'
                    ? 'text-[var(--danger)]'
                    : syncing
                      ? 'text-[var(--accent)]'
                      : 'text-[var(--success)]'
                }
              />
              {syncStatusLocalizedPhaseTitle(syncStatus)}
            </span>
            <span className="text-[11.5px] text-[var(--text-tertiary)] tabular-nums">
              待上传 {syncStatus.pendingOpCount} 条 · 上次同步 {formatRelativeDate(syncStatus.lastSyncedAt)}
            </span>
          </div>

          {(syncing || progressPct !== null) && (
            <div className="h-1.5 w-full rounded-full bg-[var(--bg-subtle)] overflow-hidden">
              <div
                className="h-full bg-[var(--accent)] transition-[width] duration-200"
                style={{ width: `${progressPct ?? 35}%` }}
              />
            </div>
          )}

          {syncStatus.currentDetail && (
            <div className="text-[11.5px] text-[var(--text-secondary)]">
              {syncStatus.currentDetail}
            </div>
          )}

          {syncStatus.lastError && (
            <div className="text-[11.5px] text-[var(--danger)]">{syncStatus.lastError}</div>
          )}
        </div>

        <SettingsDivider />

        <SettingsRow
          title="自动同步周期"
          subtitle="后台自动拉取与合并其他设备变更的间隔秒数"
        >
          <select
            aria-label="自动同步周期"
            value={draft.autoSyncIntervalSeconds}
            onChange={(e) => {
              const next = { ...draft, autoSyncIntervalSeconds: Number(e.target.value) };
              setDraft(next);
              void handleSave(next);
            }}
            className="h-8 px-2.5 rounded-[var(--radius-settings-inner)] bg-[var(--bg-subtle)] border border-[var(--border-hairline)] text-[12px] text-[var(--text-primary)] outline-none cursor-pointer"
          >
            <option value={60}>每 1 分钟</option>
            <option value={120}>每 2 分钟</option>
            <option value={300}>每 5 分钟</option>
            <option value={900}>每 15 分钟</option>
            <option value={0}>仅手动同步</option>
          </select>
        </SettingsRow>

        <SettingsDivider />

        <SettingsRow
          title="同步轻量化预览缩略图"
          subtitle="跨设备打开画廊时立即呈现全部瀑布流缩略图，无需等待原文件下载"
        >
          <SettingsSwitch
            ariaLabel="同步轻量化预览缩略图"
            checked={draft.syncThumbnails}
            onChange={(v) => {
              const next = { ...draft, syncThumbnails: v };
              setDraft(next);
              void handleSave(next);
            }}
          />
        </SettingsRow>

        <SettingsDivider />

        <SettingsRow
          title="同步智能搜索向量索引"
          subtitle="多设备共享视觉特征与语义向量，保持一致的相似图检索与情绪板推荐体验"
        >
          <SettingsSwitch
            ariaLabel="同步智能搜索向量索引"
            checked={draft.syncEmbeddings}
            onChange={(v) => {
              const next = { ...draft, syncEmbeddings: v };
              setDraft(next);
              void handleSave(next);
            }}
          />
        </SettingsRow>
      </SettingsCard>

      {/* Lossless Storage Migration Card */}
      <SettingsCard>
        <SettingsRow
          title="无损迁移素材库存储位置"
          subtitle="将全部原文件、文件夹结构、标签与情绪板从纯本地无损迁移至云盘，或从云盘完整迁回本地。"
        >
          <Button variant="secondary" size="sm" onClick={() => setMigrationOpen(true)}>
            <ArrowLeftRight size={13} />
            启动迁移向导…
          </Button>
        </SettingsRow>
      </SettingsCard>

      {/* Google OAuth Credentials Sheet */}
      <ModalShell
        open={oauthSheetOpen}
        onClose={() => setOauthSheetOpen(false)}
        width="sm"
        title="配置 Google Drive OAuth 凭据"
        subtitle="凭据将使用加密密钥库保存在服务端，不会明文回传给浏览器"
        footer={
          <>
            <Button variant="secondary" size="sm" onClick={() => setOauthSheetOpen(false)}>
              取消
            </Button>
            <Button
              variant="primary"
              size="sm"
              loading={savingOAuth}
              disabled={!oauthClientID.trim() || !oauthClientSecret.trim()}
              onClick={(e) => void handleSaveOAuthCreds(e)}
            >
              保存凭据
            </Button>
          </>
        }
      >
        <form onSubmit={handleSaveOAuthCreds} className="flex flex-col gap-3">
          <div>
            <label className="block text-[12px] font-medium text-[var(--text-primary)] mb-1">
              OAuth Client ID
            </label>
            <SettingsInput
              type="text"
              required
              value={oauthClientID}
              onChange={(e) => setOauthClientID(e.target.value)}
              placeholder="1234567890-xxxx.apps.googleusercontent.com"
              className="w-full"
            />
          </div>
          <div>
            <label className="block text-[12px] font-medium text-[var(--text-primary)] mb-1">
              OAuth Client Secret
            </label>
            <SettingsInput
              type="password"
              required
              value={oauthClientSecret}
              onChange={(e) => setOauthClientSecret(e.target.value)}
              placeholder="GOCSPX-..."
              className="w-full"
            />
          </div>
        </form>
      </ModalShell>

      {/* Google Drive Shared Folder Picker Modal */}
      <ModalShell
        open={sharedPickerOpen}
        onClose={() => setSharedPickerOpen(false)}
        width="md"
        title="选择 Google Drive 共享目录"
        subtitle="从「与我共享」中选择目标目录作为团队共享素材库"
      >
        {loadingShared ? (
          <div className="py-10 text-center text-[12.5px] text-[var(--text-secondary)]">
            正在拉取 Google Drive 共享目录列表…
          </div>
        ) : sharedFolders.length === 0 ? (
          <div className="py-10 text-center text-[12.5px] text-[var(--text-secondary)]">
            未找到可访问的共享目录，也可直接粘贴目录链接或 ID
          </div>
        ) : (
          <div className="flex flex-col divide-y divide-[var(--border-hairline)]">
            {sharedFolders.map((folder) => (
              <button
                key={folder.id}
                type="button"
                onClick={() => {
                  const next = { ...draft, sharedFolderURLOrID: folder.id };
                  setDraft(next);
                  setSharedPickerOpen(false);
                  void handleSave(next);
                }}
                className="py-2.5 px-2 flex items-center justify-between gap-3 text-left hover:bg-[var(--bg-subtle)] rounded-[8px] cursor-pointer"
              >
                <div>
                  <div className="text-[13px] font-medium text-[var(--text-primary)]">
                    {folder.name}
                  </div>
                  <div className="text-[11px] font-mono text-[var(--text-tertiary)]">
                    {folder.id}
                  </div>
                </div>
                <span className="text-[11.5px] text-[var(--accent)] font-medium">选用</span>
              </button>
            ))}
          </div>
        )}
      </ModalShell>

      {/* Lossless Migration Modal */}
      <StorageMigrationModal
        open={migrationOpen}
        onClose={() => setMigrationOpen(false)}
        currentConfig={draft}
      />
    </div>
  );
};
