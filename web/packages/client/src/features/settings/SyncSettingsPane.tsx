import React, { useEffect, useState } from 'react';
import {
  Cloud,
  ExternalLink,
  FolderSearch,
  KeyRound,
  Loader2,
  RefreshCw,
  Server,
} from 'lucide-react';
import {
  createDefaultDriveSyncConfig,
  extractGoogleDriveFolderID,
  isSyncStatusActive,
  syncStatusLocalizedPhaseTitle,
} from '@charkle/shared';
import type { DriveSyncConfig, RemoteDriveFile } from '@charkle/shared';
import { apiClient } from '../../api/client';
import { ModalShell } from '../../design-system/ModalShell';
import { useCoordinatorStore } from '../../stores/coordinatorStore';
import { useSyncAIStore } from '../../stores/syncAIStore';
import { GoogleOAuthSetupModal } from './GoogleOAuthSetupModal';
import {
  SettingsButton,
  SettingsCardDivider,
  SettingsInput,
  SettingsRow,
  SettingsSection,
  SettingsSegmented,
  SettingsStatusBadge,
  SettingsSwitch,
} from './SettingsChrome';
import { formatBytes, formatRelativeDate } from './shortcuts';

const AUTO_SYNC_INTERVAL_OPTIONS: ReadonlyArray<{
  id: '60' | '120' | '300' | '900' | '0';
  label: string;
}> = [
  { id: '60', label: '1 分钟' },
  { id: '120', label: '2 分钟' },
  { id: '300', label: '5 分钟' },
  { id: '900', label: '15 分钟' },
  { id: '0', label: '仅手动' },
];

export const SyncSettingsPane: React.FC = () => {
  const runtimeMode = useSyncAIStore((s) => s.runtimeMode);
  const runtimeFeatures = useSyncAIStore((s) => s.runtimeFeatures);
  const syncConfig = useSyncAIStore((s) => s.syncConfig);
  const syncStatus = useSyncAIStore((s) => s.syncStatus);
  const hasGoogleOAuthConfig = useSyncAIStore((s) => s.hasGoogleOAuthConfig);
  const hasWebDAVPassword = useSyncAIStore((s) => s.hasWebDAVPassword);
  const activeStorageSummary = useSyncAIStore((s) => s.activeStorageSummary);
  const isSyncingNow = useSyncAIStore((s) => s.isSyncingNow);
  const lastSyncReport = useSyncAIStore((s) => s.lastSyncReport);

  const isBuiltInCloud = runtimeMode === 'cloudflare' || !runtimeFeatures.localFolder;

  const loadSyncConfig = useSyncAIStore((s) => s.loadSyncConfig);
  const saveSyncConfig = useSyncAIStore((s) => s.saveSyncConfig);
  const syncNow = useSyncAIStore((s) => s.syncNow);

  const setSettingsTab = useCoordinatorStore((s) => s.setSettingsTab);
  const pushToast = useCoordinatorStore((s) => s.pushToast);

  const [draft, setDraft] = useState<DriveSyncConfig>(createDefaultDriveSyncConfig());
  const [saving, setSaving] = useState(false);
  const [testingWebDAV, setTestingWebDAV] = useState(false);

  const [oauthModalOpen, setOauthModalOpen] = useState(false);
  const [oauthAutoSignIn, setOauthAutoSignIn] = useState(true);
  const [webDAVModalOpen, setWebDAVModalOpen] = useState(false);
  const [sharedPickerOpen, setSharedPickerOpen] = useState(false);
  const [sharedFolders, setSharedFolders] = useState<RemoteDriveFile[]>([]);
  const [loadingShared, setLoadingShared] = useState(false);

  useEffect(() => {
    void loadSyncConfig();
  }, [loadSyncConfig]);

  useEffect(() => {
    if (syncConfig) {
      setDraft(syncConfig);
    }
  }, [syncConfig]);

  const persistedConfig = syncConfig ?? createDefaultDriveSyncConfig();
  const isLocalOnly = persistedConfig.mode === 'localOnly';
  const isWebDAV = persistedConfig.mode === 'webDAV';
  const isGoogle = !isLocalOnly && !isWebDAV;

  const syncing = isSyncingNow || isSyncStatusActive(syncStatus);
  const progressPct =
    syncStatus.progressFraction != null
      ? Math.round(Math.max(0, Math.min(1, syncStatus.progressFraction)) * 100)
      : null;

  const rootDirty = draft.rootFolderName.trim() !== persistedConfig.rootFolderName.trim();
  const sharedDirty =
    draft.sharedFolderURLOrID.trim() !== persistedConfig.sharedFolderURLOrID.trim();
  const parsedSharedID = extractGoogleDriveFolderID(draft.sharedFolderURLOrID);

  const commitConfig = async (
    nextConfig: DriveSyncConfig,
    webDAVPassword?: string | null,
    successMsg = '云同步设置已保存',
  ) => {
    setSaving(true);
    try {
      await saveSyncConfig(nextConfig, webDAVPassword);
      pushToast({ tone: 'success', message: successMsg });
    } catch (err) {
      pushToast({
        tone: 'error',
        message: err instanceof Error ? err.message : '保存云同步设置失败',
      });
    } finally {
      setSaving(false);
    }
  };

  const handleEnableGoogleSync = async () => {
    const next: DriveSyncConfig = { ...draft, mode: 'directAPIWithGDirect' };
    setDraft(next);
    await commitConfig(next, null, '已切换至 Google Drive 云端直连');
    if (!hasGoogleOAuthConfig) {
      setOauthAutoSignIn(true);
      setOauthModalOpen(true);
    }
  };

  const handleStartGoogleOAuth = async () => {
    try {
      const { authURL } = await apiClient.startGoogleOAuth();
      window.open(authURL, '_blank', 'noopener,noreferrer');
      pushToast({ tone: 'info', message: '已打开 Google 登录授权页，授权完成后将自动刷新状态' });
    } catch (err) {
      pushToast({
        tone: 'error',
        message: err instanceof Error ? err.message : '发起 Google 登录失败，请先配置凭据',
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

  const handleSyncNow = async () => {
    try {
      const report = await syncNow();
      pushToast({
        tone: 'success',
        message: `同步完成：上传 ${report.uploadedOps} 条，拉取 ${report.downloadedOps} 条，新发现 ${report.discoveredRemoteAssets} 项`,
      });
    } catch (err) {
      pushToast({
        tone: 'error',
        message: err instanceof Error ? err.message : '立即同步失败',
      });
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

  const handleQuickTestWebDAV = async () => {
    setTestingWebDAV(true);
    try {
      const res = await apiClient.testWebDAV({ config: persistedConfig, password: null });
      pushToast({
        tone: 'success',
        message: `WebDAV 连接正常（${res.account.email || persistedConfig.webDAVUsername || '已验证'}）`,
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

  const quotaUsed = syncStatus.account?.storageUsedBytes ?? null;
  const quotaLimit = syncStatus.account?.storageLimitBytes ?? null;
  const quotaPct =
    quotaUsed != null && quotaLimit != null && quotaLimit > 0
      ? Math.min(100, Math.round((quotaUsed / quotaLimit) * 100))
      : null;

  return (
    <div className="flex flex-col gap-[22px]">
      {isLocalOnly ? (
        /* Built-in cloud or local-only onboarding state */
        <SettingsSection title="云端同步服务">
          <SettingsRow
            title={isBuiltInCloud ? '当前使用内置云存储' : '当前使用本地文件夹存储'}
            subtitle={
              isBuiltInCloud ? (
                '默认保存在云端'
              ) : (
                <span className="font-mono text-[11px] charkle-wrap-anywhere">{activeStorageSummary}</span>
              )
            }
          >
            <SettingsButton variant="secondary" onClick={() => setSettingsTab('library')}>
              管理素材库位置
            </SettingsButton>
          </SettingsRow>

          <SettingsCardDivider />

          <SettingsRow
            title="Google Drive 云端直连"
            subtitle="与桌面端自动同步"
          >
            <SettingsButton
              variant="primary"
              loading={saving}
              onClick={() => void handleEnableGoogleSync()}
            >
              启用 Google 同步
            </SettingsButton>
          </SettingsRow>

          <SettingsCardDivider />

          <SettingsRow
            title="WebDAV 云盘"
            subtitle="坚果云、Nextcloud、群晖 NAS"
          >
            <SettingsButton variant="secondary" onClick={() => setWebDAVModalOpen(true)}>
              配置 WebDAV…
            </SettingsButton>
          </SettingsRow>
        </SettingsSection>
      ) : (
        <>
          {/* 1. Sync Status */}
          <SettingsSection title="同步状态">
            <SettingsRow
              title={
                <span className="inline-flex items-center gap-2">
                  {syncing ? (
                    <Loader2 size={13} className="animate-spin text-[var(--accent)] shrink-0" />
                  ) : (
                    <span
                      className={[
                        'w-2 h-2 rounded-full shrink-0',
                        syncStatus.phase.type === 'error'
                          ? 'bg-[var(--settings-destructive,var(--danger))]'
                          : 'bg-[var(--settings-positive,var(--success))]',
                      ].join(' ')}
                    />
                  )}
                  <span>{syncStatusLocalizedPhaseTitle(syncStatus)}</span>
                  {syncing && progressPct !== null && (
                    <span className="text-[11.5px] font-mono text-[var(--text-secondary)] tabular-nums">
                      {progressPct}%
                    </span>
                  )}
                </span>
              }
              subtitle={
                syncStatus.lastError
                  ? syncStatus.lastError
                  : `上次同步 ${formatRelativeDate(syncStatus.lastSyncedAt)} · 待上传 ${syncStatus.pendingOpCount} 条`
              }
              subtitleTone={syncStatus.lastError ? 'destructive' : 'default'}
            >
              <SettingsButton
                variant="primary"
                loading={syncing}
                onClick={() => void handleSyncNow()}
              >
                <RefreshCw size={12} className={syncing ? 'animate-spin' : ''} />
                立即同步
              </SettingsButton>
            </SettingsRow>

            {(syncing || progressPct !== null || syncStatus.currentDetail || lastSyncReport) && (
              <div className="px-4 pb-3.5 flex flex-col gap-2">
                {(syncing || progressPct !== null) && (
                  <div className="h-1.5 w-full rounded-full bg-[var(--settings-subtle,var(--bg-subtle))] overflow-hidden">
                    <div
                      className="h-full w-full bg-[var(--accent)] origin-left transition-transform duration-200 ease-[var(--ease-out)]"
                      style={{
                        transform: `scaleX(${Math.max(0.05, Math.min(1, (progressPct ?? 35) / 100))})`,
                      }}
                    />
                  </div>
                )}
                {syncStatus.currentDetail && (
                  <div className="text-[11px] text-[var(--text-secondary)]">
                    {syncStatus.currentDetail}
                  </div>
                )}
                {lastSyncReport && (
                  <div className="flex flex-wrap items-center gap-3 text-[11px] text-[var(--text-secondary)] font-mono tabular-nums">
                    <span>↑ {lastSyncReport.uploadedOps} 上传</span>
                    <span>↓ {lastSyncReport.downloadedOps} 拉取</span>
                    <span>+{lastSyncReport.discoveredRemoteAssets} 新发现</span>
                    {lastSyncReport.updatedBoards > 0 && (
                      <span>{lastSyncReport.updatedBoards} 情绪板更新</span>
                    )}
                  </div>
                )}
              </div>
            )}
          </SettingsSection>

          {/* 2A. Google Drive Account & Shared Folder */}
          {isGoogle && (
            <>
              <SettingsSection title="Google Drive 账号">
                <SettingsRow
                  title={
                    <span className="inline-flex items-center gap-2 flex-wrap">
                      <span className="w-6 h-6 rounded-full bg-[var(--settings-subtle,var(--bg-subtle))] border border-[var(--settings-border,var(--border-hairline))] inline-flex items-center justify-center text-[11px] font-semibold text-[var(--text-primary)] shrink-0">
                        {syncStatus.account?.email
                          ? syncStatus.account.email.slice(0, 1).toUpperCase()
                          : <Cloud size={12} />}
                      </span>
                      <span className="truncate">
                        {syncStatus.account
                          ? syncStatus.account.displayName || syncStatus.account.email
                          : '尚未登录 Google Drive'}
                      </span>
                      {syncStatus.account && (
                        <SettingsStatusBadge text="已直连" tone="positive" />
                      )}
                    </span>
                  }
                  subtitle={
                    syncStatus.account
                      ? syncStatus.account.email
                      : hasGoogleOAuthConfig
                        ? '已配置凭据，点击登录'
                        : '首次使用需配置登录凭据'
                  }
                >
                  {syncStatus.account ? (
                    <>
                      <SettingsButton
                        variant="secondary"
                        onClick={() => void handleStartGoogleOAuth()}
                      >
                        切换账号
                      </SettingsButton>
                      <SettingsButton
                        variant="destructive"
                        onClick={() => void handleSignOutGoogle()}
                      >
                        退出
                      </SettingsButton>
                    </>
                  ) : hasGoogleOAuthConfig ? (
                    <>
                      <SettingsButton
                        variant="secondary"
                        onClick={() => {
                          setOauthAutoSignIn(false);
                          setOauthModalOpen(true);
                        }}
                      >
                        <KeyRound size={12} />
                        修改凭据
                      </SettingsButton>
                      <SettingsButton
                        variant="primary"
                        onClick={() => void handleStartGoogleOAuth()}
                      >
                        <ExternalLink size={12} />
                        使用 Google 登录
                      </SettingsButton>
                    </>
                  ) : (
                    <SettingsButton
                      variant="primary"
                      onClick={() => {
                        setOauthAutoSignIn(true);
                        setOauthModalOpen(true);
                      }}
                    >
                      <KeyRound size={12} />
                      配置凭据并登录
                    </SettingsButton>
                  )}
                </SettingsRow>

                {quotaPct !== null && quotaUsed !== null && quotaLimit !== null && (
                  <div className="px-4 pb-3 flex flex-col gap-1.5">
                    <div className="flex items-center justify-between text-[11px] text-[var(--text-secondary)] tabular-nums">
                      <span>Google Drive 云盘空间</span>
                      <span className="font-mono">
                        {formatBytes(quotaUsed)} / {formatBytes(quotaLimit)} ({quotaPct}%)
                      </span>
                    </div>
                    <div className="h-1.5 w-full rounded-full bg-[var(--settings-subtle,var(--bg-subtle))] overflow-hidden">
                      <div
                        className="h-full w-full bg-[var(--accent)] rounded-full origin-left transition-transform duration-300 ease-[var(--ease-out)]"
                        style={{
                          transform: `scaleX(${Math.max(0, Math.min(1, quotaPct / 100))})`,
                        }}
                      />
                    </div>
                  </div>
                )}

                <SettingsCardDivider />

                <SettingsRow title="云端保存路径">
                  <SettingsInput
                    type="text"
                    aria-label="云端保存路径"
                    value={draft.rootFolderName}
                    onChange={(e) => setDraft((d) => ({ ...d, rootFolderName: e.target.value }))}
                    placeholder="Charkle"
                    className="w-[150px]"
                  />
                  {rootDirty && (
                    <SettingsButton
                      variant="primary"
                      loading={saving}
                      onClick={() => void commitConfig(draft, null, '已更新云端根目录名')}
                    >
                      保存
                    </SettingsButton>
                  )}
                </SettingsRow>
              </SettingsSection>

              <SettingsSection title="团队共享协作（可选）">
                <div className="px-4 py-3 flex flex-col gap-2">
                  <div className="flex flex-wrap items-center justify-between gap-2">
                    <div className="text-[13px] font-medium text-[var(--text-primary)]">
                      共享文件夹链接或 ID
                    </div>
                    <div className="flex items-center gap-1.5">
                      <SettingsButton
                        variant="secondary"
                        disabled={!syncStatus.account}
                        onClick={() => void handleLoadSharedFolders()}
                      >
                        <FolderSearch size={12} />
                        选择与我共享
                      </SettingsButton>
                      {draft.sharedFolderURLOrID.trim() && (
                        <SettingsButton
                          variant="secondary"
                          disabled={saving}
                          onClick={() => {
                            const next = { ...draft, sharedFolderURLOrID: '' };
                            setDraft(next);
                            void commitConfig(next, null, '已清除共享文件夹设置');
                          }}
                        >
                          清除
                        </SettingsButton>
                      )}
                    </div>
                  </div>

                  <div className="flex items-center gap-2">
                    <SettingsInput
                      type="text"
                      value={draft.sharedFolderURLOrID}
                      onChange={(e) =>
                        setDraft((d) => ({ ...d, sharedFolderURLOrID: e.target.value }))
                      }
                      placeholder="粘贴 Google Drive 共享文件夹链接或 ID（留空使用个人目录）"
                      className="flex-1 min-w-0"
                    />
                    {sharedDirty && (
                      <SettingsButton
                        variant="primary"
                        loading={saving}
                        onClick={() => void commitConfig(draft, null, '已更新共享文件夹配置')}
                      >
                        保存
                      </SettingsButton>
                    )}
                  </div>

                  {draft.sharedFolderURLOrID.trim() && (
                    <div className="text-[11px]">
                      {parsedSharedID ? (
                        <span className="text-[var(--settings-positive,var(--success))]">
                          已识别目录 ID：{parsedSharedID}
                        </span>
                      ) : (
                        <span className="text-[var(--settings-warning,var(--warning))]">
                          无法解析目录 ID，请粘贴完整的 Google Drive 文件夹分享链接
                        </span>
                      )}
                    </div>
                  )}
                </div>
              </SettingsSection>
            </>
          )}

          {/* 2B. WebDAV Service */}
          {isWebDAV && (
            <SettingsSection title="WebDAV 服务">
              <SettingsRow
                title={activeStorageSummary}
                subtitle={
                  persistedConfig.webDAVUsername
                    ? `账号：${persistedConfig.webDAVUsername}${hasWebDAVPassword ? ' · 密码已安全保存' : ' · 尚未保存密码'}`
                    : '尚未配置 WebDAV 服务器信息'
                }
              >
                <SettingsButton
                  variant="secondary"
                  loading={testingWebDAV}
                  onClick={() => void handleQuickTestWebDAV()}
                >
                  <Server size={12} />
                  测试连接
                </SettingsButton>
                <SettingsButton variant="primary" onClick={() => setWebDAVModalOpen(true)}>
                  编辑配置…
                </SettingsButton>
              </SettingsRow>
            </SettingsSection>
          )}

          {/* 3. Sync Preferences */}
          <SettingsSection title="同步偏好">
            <SettingsRow title="自动同步周期">
              <SettingsSegmented
                ariaLabel="自动同步周期"
                options={AUTO_SYNC_INTERVAL_OPTIONS}
                value={
                  (['60', '120', '300', '900', '0'].includes(
                    String(draft.autoSyncIntervalSeconds),
                  )
                    ? String(draft.autoSyncIntervalSeconds)
                    : '300') as '60' | '120' | '300' | '900' | '0'
                }
                onChange={(val) => {
                  const next = { ...draft, autoSyncIntervalSeconds: Number(val) };
                  setDraft(next);
                  void commitConfig(next, null, '已更新自动同步周期');
                }}
              />
            </SettingsRow>

            <SettingsCardDivider />

            <SettingsRow
              title="同步轻量化预览图"
              subtitle="切换设备时更快加载预览"
            >
              <SettingsSwitch
                ariaLabel="同步轻量化预览图"
                checked={draft.syncThumbnails}
                onChange={(v) => {
                  const next = { ...draft, syncThumbnails: v };
                  setDraft(next);
                  void commitConfig(next, null, '已更新预览图同步偏好');
                }}
              />
            </SettingsRow>

            <SettingsCardDivider />

            <SettingsRow
              title="同步智能搜索索引"
              subtitle="多设备共享智能搜索结果"
            >
              <SettingsSwitch
                ariaLabel="同步智能搜索索引"
                checked={draft.syncEmbeddings}
                onChange={(v) => {
                  const next = { ...draft, syncEmbeddings: v };
                  setDraft(next);
                  void commitConfig(next, null, '已更新智能搜索索引同步偏好');
                }}
              />
            </SettingsRow>
          </SettingsSection>
        </>
      )}

      {/* Google OAuth Setup Modal */}
      <GoogleOAuthSetupModal
        open={oauthModalOpen}
        onClose={() => setOauthModalOpen(false)}
        autoSignInAfterSave={oauthAutoSignIn}
      />

      {/* WebDAV Editor Modal */}
      <WebDAVConfigModal
        open={webDAVModalOpen}
        onClose={() => setWebDAVModalOpen(false)}
        initialConfig={draft}
        hasStoredPassword={hasWebDAVPassword}
        onSaved={(saved) => setDraft(saved)}
      />

      {/* Shared Folder Picker Modal */}
      <ModalShell
        open={sharedPickerOpen}
        onClose={() => setSharedPickerOpen(false)}
        width="md"
        title="选择 Google Drive 共享目录"
      >
        {loadingShared ? (
          <div className="py-10 text-center text-[12.5px] text-[var(--text-secondary)]">
            正在读取 Google Drive 共享目录…
          </div>
        ) : sharedFolders.length === 0 ? (
          <div className="py-10 text-center text-[12.5px] text-[var(--text-secondary)]">
            未找到可访问的共享目录，也可直接在设置页粘贴目录链接或 ID
          </div>
        ) : (
          <div className="flex flex-col divide-y divide-[var(--settings-divider,var(--border-hairline))]">
            {sharedFolders.map((folder) => (
              <button
                key={folder.id}
                type="button"
                onClick={() => {
                  const next = { ...draft, sharedFolderURLOrID: folder.id };
                  setDraft(next);
                  setSharedPickerOpen(false);
                  void commitConfig(next, null, `已选择共享目录「${folder.name}」`);
                }}
                className="py-2.5 px-2.5 flex items-center justify-between gap-3 text-left hover:bg-[var(--settings-subtle,var(--bg-subtle))] rounded-[8px] cursor-pointer transition-colors duration-[var(--duration-press,120ms)] ease-[var(--ease-out)]"
              >
                <div className="min-w-0">
                  <div className="text-[13px] font-medium text-[var(--text-primary)] truncate">
                    {folder.name}
                  </div>
                  <div className="text-[11px] font-mono text-[var(--text-tertiary)] truncate">
                    {folder.id}
                  </div>
                </div>
                <span className="text-[11.5px] text-[var(--accent)] font-medium shrink-0">
                  选用
                </span>
              </button>
            ))}
          </div>
        )}
      </ModalShell>
    </div>
  );
};

// MARK: - WebDAV Config Modal

const WebDAVConfigModal: React.FC<{
  open: boolean;
  onClose: () => void;
  initialConfig: DriveSyncConfig;
  hasStoredPassword: boolean;
  onSaved: (config: DriveSyncConfig) => void;
}> = ({ open, onClose, initialConfig, hasStoredPassword, onSaved }) => {
  const saveSyncConfig = useSyncAIStore((s) => s.saveSyncConfig);
  const pushToast = useCoordinatorStore((s) => s.pushToast);

  const [serverURL, setServerURL] = useState('');
  const [username, setUsername] = useState('');
  const [password, setPassword] = useState('');
  const [remotePath, setRemotePath] = useState('/Charkle');
  const [testing, setTesting] = useState(false);
  const [saving, setSaving] = useState(false);

  useEffect(() => {
    if (open) {
      setServerURL(initialConfig.webDAVServerURL);
      setUsername(initialConfig.webDAVUsername);
      setPassword('');
      setRemotePath(initialConfig.webDAVRemotePath || '/Charkle');
    }
  }, [open, initialConfig]);

  const buildNextConfig = (): DriveSyncConfig => ({
    ...initialConfig,
    mode: 'webDAV',
    webDAVServerURL: serverURL.trim(),
    webDAVUsername: username.trim(),
    webDAVRemotePath: remotePath.trim() || '/Charkle',
  });

  const handleTest = async () => {
    setTesting(true);
    try {
      const res = await apiClient.testWebDAV({
        config: buildNextConfig(),
        password: password || null,
      });
      pushToast({
        tone: 'success',
        message: `WebDAV 连接正常（${res.account.email || username || '已验证'}）`,
      });
    } catch (err) {
      pushToast({
        tone: 'error',
        message: err instanceof Error ? err.message : 'WebDAV 连接测试失败',
      });
    } finally {
      setTesting(false);
    }
  };

  const handleSave = async (e: React.FormEvent) => {
    e.preventDefault();
    const next = buildNextConfig();
    setSaving(true);
    try {
      await saveSyncConfig(next, password || null);
      onSaved(next);
      pushToast({ tone: 'success', message: 'WebDAV 云同步配置已保存' });
      onClose();
    } catch (err) {
      pushToast({
        tone: 'error',
        message: err instanceof Error ? err.message : '保存 WebDAV 配置失败',
      });
    } finally {
      setSaving(false);
    }
  };

  return (
    <ModalShell
      open={open}
      onClose={() => {
        if (!saving) onClose();
      }}
      width="sm"
      title="配置 WebDAV 云盘"
      footer={
        <>
          <SettingsButton
            variant="secondary"
            loading={testing}
            disabled={!serverURL.trim() || saving}
            onClick={() => void handleTest()}
          >
            测试连接
          </SettingsButton>
          <SettingsButton variant="secondary" disabled={saving} onClick={onClose}>
            取消
          </SettingsButton>
          <SettingsButton
            variant="primary"
            loading={saving}
            disabled={!serverURL.trim()}
            onClick={(e) => void handleSave(e)}
          >
            保存并启用
          </SettingsButton>
        </>
      }
    >
      <form onSubmit={(e) => void handleSave(e)} className="flex flex-col gap-3">
        <div className="flex flex-col gap-1">
          <label className="text-[11.5px] font-medium text-[var(--text-secondary)]">
            服务器地址
          </label>
          <SettingsInput
            type="url"
            required
            value={serverURL}
            onChange={(e) => setServerURL(e.target.value)}
            placeholder="https://dav.jianguoyun.com/dav/"
            className="w-full"
          />
        </div>

        <div className="flex flex-col gap-1">
          <label className="text-[11.5px] font-medium text-[var(--text-secondary)]">用户名</label>
          <SettingsInput
            type="text"
            value={username}
            onChange={(e) => setUsername(e.target.value)}
            placeholder="账号或邮箱"
            className="w-full"
          />
        </div>

        <div className="flex flex-col gap-1">
          <label className="text-[11.5px] font-medium text-[var(--text-secondary)]">
            密码 / 应用专用密码 {hasStoredPassword ? '（已保存）' : ''}
          </label>
          <SettingsInput
            type="password"
            value={password}
            onChange={(e) => setPassword(e.target.value)}
            placeholder={hasStoredPassword ? '••••••••（留空保持不变）' : '输入密码'}
            className="w-full"
          />
        </div>

        <div className="flex flex-col gap-1">
          <label className="text-[11.5px] font-medium text-[var(--text-secondary)]">
            远程目录路径
          </label>
          <SettingsInput
            type="text"
            value={remotePath}
            onChange={(e) => setRemotePath(e.target.value)}
            placeholder="/Charkle"
            className="w-full"
          />
        </div>
      </form>
    </ModalShell>
  );
};
