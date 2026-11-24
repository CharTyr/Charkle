import React, { useEffect, useRef, useState } from 'react';
import {
  ArrowCircleUp16Regular,
  ArrowSwap16Regular,
  ArrowSync16Regular,
  BookOpen16Regular,
  CheckmarkCircle16Filled,
  Clock16Regular,
  Color20Regular,
  Desktop16Regular,
  DocumentCode16Regular,
  FolderOpen16Regular,
  Info16Regular,
  Key16Regular,
  Open16Regular,
  PersonAvailable16Regular,
  PersonCircle16Regular,
  WeatherMoon16Regular,
  WeatherSunny16Regular,
} from '@fluentui/react-icons';
import { getTransport } from '../../api/transport';
import {
  CharkleSlider,
  SegmentedControl,
  Switch,
  useResolvedIsDark,
  type ThemeMode,
} from '../../design-system';
import { useCoordinatorStore, useSyncAIStore } from '../../stores';
import {
  isDirectGoogleDriveAccount,
  type DriveSyncConfig,
  type DriveTransportMode,
  type GalleryLayoutMode,
  type StorageMigrationReport,
  type SyncStatus,
} from '../../types/domain';
import {
  activeStorageLocationSummary,
  formatBytes,
  GDIRECT_TUTORIAL_URL,
  InlineGuideDisclosure,
  isValidHttpUrl,
  relativeTimeText,
  resolveSharedFolderID,
  SettingsButton,
  SettingsCardDivider,
  SettingsGuideStep,
  SettingsInput,
  SettingsRow,
  SettingsSection,
  SettingsStatusBadge,
  SettingsSubModal,
  SettingsSwitch,
  storageModeHeadline,
} from './SettingsChrome';

const DEFAULT_SYNC_CONFIG: DriveSyncConfig = {
  mode: 'localOnly',
  rootFolderName: 'Charkle',
  sharedFolderURLOrID: '',
  mountPath: 'G:\\',
  selectedGDirectAccount: null,
  useGDirectIPAcceleration: true,
  webDAVServerURL: '',
  webDAVUsername: '',
  webDAVRemotePath: '/Charkle',
  localLibraryPath: '',
  autoSyncIntervalSeconds: 120,
  syncThumbnails: true,
  syncEmbeddings: true,
};

function isSyncPhaseBusy(status: SyncStatus | null): boolean {
  if (!status) return false;
  if (typeof status.phase === 'string') {
    return status.phase === 'scanning' || status.phase === 'merging';
  }
  return 'uploading' in status.phase || 'downloading' in status.phase;
}

function localizedSyncPhaseTitle(status: SyncStatus | null): string {
  if (!status) return '同步中…';
  const p = status.phase;
  if (typeof p === 'string') {
    if (p === 'scanning') return '正在扫描目录变更…';
    if (p === 'merging') return '正在合并增量索引…';
    return '同步中…';
  }
  if ('uploading' in p) {
    return `正在上传素材（${p.uploading.completed}/${p.uploading.total}）…`;
  }
  if ('downloading' in p) {
    return `正在下载云端素材（${p.downloading.completed}/${p.downloading.total}）…`;
  }
  return '上次同步遇到异常';
}

function syncIdleHeadline(status: SyncStatus | null): string {
  if (!status) return '等待首次同步';
  if (typeof status.phase === 'object' && 'error' in status.phase) {
    return '上次同步遇到异常';
  }
  if (status.pendingOpCount > 0) {
    return `有 ${status.pendingOpCount} 项本地变更待同步`;
  }
  return status.lastSyncedAt ? '已与云端保持同步' : '等待首次同步';
}

function syncIndicatorColor(status: SyncStatus | null): string {
  if (!status) return 'var(--text-tertiary)';
  if (typeof status.phase === 'object' && 'error' in status.phase) {
    return 'var(--settings-destructive)';
  }
  if (isSyncPhaseBusy(status) || status.pendingOpCount > 0) {
    return 'var(--settings-warning)';
  }
  return status.lastSyncedAt ? 'var(--settings-positive)' : 'var(--text-tertiary)';
}

// =========================================================================
// Shared Sheet 1: Google OAuth Credential Setup (mirrors GoogleOAuthSetupSheet.swift)
// =========================================================================

export const GoogleOAuthSetupModal: React.FC<{
  open: boolean;
  onClose: () => void;
  autoSignInAfterSave?: boolean;
  onCompleted?: () => void;
}> = ({ open, onClose, autoSignInAfterSave = true, onCompleted }) => {
  const saveGoogleOAuthClient = useSyncAIStore((s) => s.saveGoogleOAuthClient);
  const importGoogleOAuthSecretFile = useSyncAIStore((s) => s.importGoogleOAuthSecretFile);
  const signInGoogleDrive = useSyncAIStore((s) => s.signInGoogleDrive);
  const signingInGoogle = useSyncAIStore((s) => s.signingInGoogle);

  const [clientId, setClientId] = useState('');
  const [clientSecret, setClientSecret] = useState('');
  const [saving, setSaving] = useState(false);

  useEffect(() => {
    if (open) {
      setClientId('');
      setClientSecret('');
    }
  }, [open]);

  const busy = saving || signingInGoogle;

  const handleImportJson = async () => {
    setSaving(true);
    try {
      const ok = await importGoogleOAuthSecretFile();
      if (ok) {
        onClose();
        onCompleted?.();
        if (autoSignInAfterSave) {
          void signInGoogleDrive();
        }
      }
    } finally {
      setSaving(false);
    }
  };

  const handleManualSave = async () => {
    const cid = clientId.trim();
    if (!cid) return;
    setSaving(true);
    try {
      const ok = await saveGoogleOAuthClient(cid, clientSecret.trim());
      if (ok) {
        onClose();
        onCompleted?.();
        if (autoSignInAfterSave) {
          void signInGoogleDrive();
        }
      }
    } finally {
      setSaving(false);
    }
  };

  return (
    <SettingsSubModal
      open={open}
      onClose={onClose}
      title={
        <span className="inline-flex items-center gap-2">
          <Key16Regular className="w-4 h-4 shrink-0" />
          <span>配置 Google Drive 登录凭据</span>
        </span>
      }
      subtitle="Charkle 直连你自己的 Google Drive，仅首次需要配置一次桌面端凭据，密钥安全保存于 Windows 凭据管理器。"
      width="md"
      footer={
        <>
          <SettingsButton variant="standard" disabled={busy} onClick={onClose}>
            取消
          </SettingsButton>
          <SettingsButton
            variant="accent"
            loading={busy}
            disabled={!clientId.trim()}
            onClick={() => void handleManualSave()}
          >
            {autoSignInAfterSave ? '保存并前往 Google 登录' : '保存凭据'}
          </SettingsButton>
        </>
      }
    >
      <div className="rounded-[var(--win-radius-card)] bg-[var(--settings-subtle)] border border-[var(--win-stroke-card)] p-3 flex flex-col gap-2.5">
        <button
          type="button"
          onClick={() => void getTransport().openExternalUrl(GDIRECT_TUTORIAL_URL)}
          className="inline-flex items-center gap-1.5 text-[12px] font-medium text-[var(--accent)] hover:underline cursor-pointer self-start focus-visible:outline-2 focus-visible:outline-[var(--accent)] rounded-[var(--win-radius-control)]"
        >
          <BookOpen16Regular className="w-3.5 h-3.5 shrink-0" />
          <span>查看 Google Cloud 桌面端凭据 3 分钟图文教程</span>
          <Open16Regular className="w-3 h-3 shrink-0" />
        </button>

        <div className="flex flex-wrap items-center gap-2">
          <SettingsButton
            variant="standard"
            loading={busy}
            onClick={() => void handleImportJson()}
          >
            <DocumentCode16Regular className="w-3.5 h-3.5 shrink-0" />
            导入 client_secret.json…
          </SettingsButton>
        </div>
      </div>

      <div className="flex flex-col gap-2.5">
        <span className="text-[11.5px] font-medium text-[var(--text-secondary)]">
          或手动粘贴创建的桌面端凭据
        </span>

        <label className="flex flex-col gap-1">
          <span className="text-[11.5px] font-medium text-[var(--text-secondary)]">Client ID</span>
          <SettingsInput
            type="text"
            value={clientId}
            onChange={(e) => setClientId(e.target.value)}
            placeholder="例如：1234567890-xxxx.apps.googleusercontent.com"
          />
        </label>

        <label className="flex flex-col gap-1">
          <span className="text-[11.5px] font-medium text-[var(--text-secondary)]">
            Client Secret
          </span>
          <SettingsInput
            type="password"
            value={clientSecret}
            onChange={(e) => setClientSecret(e.target.value)}
            placeholder="例如：GOCSPX-xxxxxxxx"
          />
        </label>
      </div>
    </SettingsSubModal>
  );
};

// =========================================================================
// Shared Sheet 2: WebDAV Editor Modal (mirrors SyncSettingsPane.webDAVEditorSheet)
// =========================================================================

export const WebDAVEditorModal: React.FC<{
  open: boolean;
  onClose: () => void;
  initialConfig: DriveSyncConfig;
  onSaved?: () => void;
}> = ({ open, onClose, initialConfig, onSaved }) => {
  const hasWebdavPassword = useSyncAIStore((s) => s.hasWebdavPassword);
  const testingWebdav = useSyncAIStore((s) => s.testingWebdav);
  const testWebdavConnection = useSyncAIStore((s) => s.testWebdavConnection);
  const saveSyncConfig = useSyncAIStore((s) => s.saveSyncConfig);

  const [url, setUrl] = useState(initialConfig.webDAVServerURL);
  const [username, setUsername] = useState(initialConfig.webDAVUsername);
  const [remotePath, setRemotePath] = useState(initialConfig.webDAVRemotePath || '/Charkle');
  const [password, setPassword] = useState('');
  const [saving, setSaving] = useState(false);
  const [inlineMsg, setInlineMsg] = useState<{ ok: boolean; text: string } | null>(null);
  const wasOpenRef = useRef(false);

  useEffect(() => {
    if (open && !wasOpenRef.current) {
      setUrl(initialConfig.webDAVServerURL);
      setUsername(initialConfig.webDAVUsername);
      setRemotePath(initialConfig.webDAVRemotePath || '/Charkle');
      setPassword('');
      setInlineMsg(null);
    }
    wasOpenRef.current = open;
  }, [open, initialConfig]);

  const trimmedUrl = url.trim();
  const isUrlValid = isValidHttpUrl(trimmedUrl);
  const showUrlError = trimmedUrl.length > 0 && !isUrlValid;
  const buildDraft = (): DriveSyncConfig => ({
    ...initialConfig,
    mode: 'webDAV',
    webDAVServerURL: trimmedUrl,
    webDAVUsername: username.trim(),
    webDAVRemotePath: remotePath.trim() || '/Charkle',
  });

  const handleTest = async () => {
    if (!isUrlValid) {
      setInlineMsg({ ok: false, text: '请输入以 https:// 或 http:// 开头的有效 WebDAV 服务器地址' });
      return;
    }
    const res = await testWebdavConnection(buildDraft(), password || null);
    setInlineMsg({ ok: res.ok, text: res.message });
    if (res.ok) setPassword('');
  };

  const handleSave = async () => {
    if (!isUrlValid) {
      setInlineMsg({ ok: false, text: '请输入以 https:// 或 http:// 开头的有效 WebDAV 服务器地址' });
      return;
    }
    setSaving(true);
    try {
      const ok = await saveSyncConfig(buildDraft(), password || undefined);
      if (ok) {
        setPassword('');
        onSaved?.();
        onClose();
      }
    } finally {
      setSaving(false);
    }
  };

  return (
    <SettingsSubModal
      open={open}
      onClose={onClose}
      title="配置 WebDAV 云盘"
      subtitle="兼容坚果云、Nextcloud、群晖 NAS、Alist 等任意标准 WebDAV 服务"
      width="md"
      footer={
        <>
          <SettingsButton variant="standard" disabled={saving || testingWebdav} onClick={onClose}>
            取消
          </SettingsButton>
          <SettingsButton
            variant="standard"
            loading={testingWebdav}
            disabled={!isUrlValid || saving}
            onClick={() => void handleTest()}
          >
            {testingWebdav ? '测试中…' : '测试连接'}
          </SettingsButton>
          <SettingsButton
            variant="accent"
            loading={saving}
            disabled={!isUrlValid || testingWebdav}
            onClick={() => void handleSave()}
          >
            保存配置
          </SettingsButton>
        </>
      }
    >
      <div className="flex flex-col gap-2.5">
        <label className="flex flex-col gap-1">
          <span className="text-[11.5px] font-medium text-[var(--text-secondary)]">服务器地址</span>
          <SettingsInput
            type="text"
            value={url}
            onChange={(e) => setUrl(e.target.value)}
            placeholder="https://dav.jianguoyun.com/dav/"
          />
          {showUrlError && (
            <span className="text-[11px] text-[var(--settings-warning)]">
              请输入以 https:// 或 http:// 开头的有效服务器地址
            </span>
          )}
        </label>

        <label className="flex flex-col gap-1">
          <span className="text-[11.5px] font-medium text-[var(--text-secondary)]">
            账号 / 用户名
          </span>
          <SettingsInput
            type="text"
            value={username}
            onChange={(e) => setUsername(e.target.value)}
            placeholder="邮箱或用户名"
          />
        </label>

        <label className="flex flex-col gap-1">
          <span className="text-[11.5px] font-medium text-[var(--text-secondary)]">
            应用密码（保存至 Windows 凭据管理器）
          </span>
          <SettingsInput
            type="password"
            value={password}
            onChange={(e) => setPassword(e.target.value)}
            placeholder={hasWebdavPassword ? '••••••••（留空保持不变）' : '输入密码或应用授权码'}
          />
        </label>

        <label className="flex flex-col gap-1">
          <span className="text-[11.5px] font-medium text-[var(--text-secondary)]">
            云端保存路径
          </span>
          <SettingsInput
            type="text"
            value={remotePath}
            onChange={(e) => setRemotePath(e.target.value)}
            placeholder="/Charkle"
          />
        </label>
      </div>

      {inlineMsg && (
        <div
          className={[
            'rounded-[var(--win-radius-control)] px-3 py-2 text-[12px] border',
            inlineMsg.ok
              ? 'bg-[var(--settings-positive)]/10 border-[var(--settings-positive)]/25 text-[var(--text-primary)]'
              : 'bg-[var(--settings-destructive)]/10 border-[var(--settings-destructive)]/25 text-[var(--settings-destructive)]',
          ].join(' ')}
        >
          {inlineMsg.text}
        </div>
      )}
    </SettingsSubModal>
  );
};

// =========================================================================
// Shared Sheet 3: Unified Storage Location Migration / Switch Wizard
// (mirrors LibrarySettingsPane.storageLocationWizardSheet)
// =========================================================================

type LocationWizardAction = 'migrate' | 'switchOnly';

export const StorageLocationWizardModal: React.FC<{
  open: boolean;
  onClose: () => void;
  initialMode?: DriveTransportMode;
  onMigrated?: (report: StorageMigrationReport) => void;
}> = ({ open, onClose, initialMode, onMigrated }) => {
  const setSettingsTab = useCoordinatorStore((s) => s.setSettingsTab);
  const syncConfig = useSyncAIStore((s) => s.syncConfig);
  const syncStatus = useSyncAIStore((s) => s.syncStatus);
  const diagnostics = useSyncAIStore((s) => s.diagnostics);
  const hasWebdavPassword = useSyncAIStore((s) => s.hasWebdavPassword);
  const migrating = useSyncAIStore((s) => s.migrating);
  const runStorageMigration = useSyncAIStore((s) => s.runStorageMigration);
  const saveSyncConfig = useSyncAIStore((s) => s.saveSyncConfig);

  const [action, setAction] = useState<LocationWizardAction>('migrate');
  const [draft, setDraft] = useState<DriveSyncConfig>(syncConfig ?? DEFAULT_SYNC_CONFIG);
  const [webdavPassword, setWebdavPassword] = useState('');
  const [savingSwitch, setSavingSwitch] = useState(false);
  const wasOpenRef = useRef(false);

  useEffect(() => {
    if (open && !wasOpenRef.current) {
      const base = syncConfig ?? DEFAULT_SYNC_CONFIG;
      const mode: DriveTransportMode =
        initialMode ?? (base.mode === 'gdirectMount' ? 'directAPIWithGDirect' : base.mode);
      setDraft({ ...base, mode });
      setAction('migrate');
      setWebdavPassword('');
    }
    wasOpenRef.current = open;
  }, [open, syncConfig, initialMode]);

  const targetMode: DriveTransportMode =
    draft.mode === 'gdirectMount' ? 'directAPIWithGDirect' : draft.mode;

  const hasReadyGoogleAccount =
    isDirectGoogleDriveAccount(syncStatus?.account) ||
    Boolean(diagnostics?.gdirect.defaultAccount) ||
    (diagnostics?.gdirect.accounts.length ?? 0) > 0;

  const trimmedWebdavUrl = draft.webDAVServerURL.trim();
  const isWebdavUrlValid = isValidHttpUrl(trimmedWebdavUrl);
  const showWebdavUrlError =
    targetMode === 'webDAV' && trimmedWebdavUrl.length > 0 && !isWebdavUrlValid;

  const canConfirm =
    targetMode === 'localOnly'
      ? draft.localLibraryPath.trim().length > 0
      : targetMode === 'webDAV'
        ? isWebdavUrlValid
        : draft.rootFolderName.trim().length > 0;

  const busy = migrating || savingSwitch;

  const handleConfirm = async () => {
    if (!canConfirm || busy) return;
    const target: DriveSyncConfig = {
      ...draft,
      mode: targetMode,
      webDAVServerURL: trimmedWebdavUrl,
      webDAVUsername: draft.webDAVUsername.trim(),
      webDAVRemotePath: draft.webDAVRemotePath.trim() || '/Charkle',
      localLibraryPath: draft.localLibraryPath.trim(),
      rootFolderName: draft.rootFolderName.trim() || 'Charkle',
    };
    const pwd = webdavPassword.trim() || undefined;
    if (action === 'migrate') {
      const report = await runStorageMigration(target, pwd);
      if (report) {
        onMigrated?.(report);
        onClose();
      }
    } else {
      setSavingSwitch(true);
      try {
        const ok = await saveSyncConfig(target, pwd);
        if (ok) onClose();
      } finally {
        setSavingSwitch(false);
      }
    }
  };

  return (
    <SettingsSubModal
      open={open}
      onClose={onClose}
      title={
        <span className="inline-flex items-center gap-2">
          <ArrowSwap16Regular className="w-4 h-4 shrink-0" />
          <span>更改或转移素材库位置</span>
        </span>
      }
      subtitle={`当前位置：${activeStorageLocationSummary(syncConfig, diagnostics?.dataDir)}`}
      width="md"
      footer={
        <>
          <SettingsButton variant="standard" disabled={busy} onClick={onClose}>
            取消
          </SettingsButton>
          <SettingsButton
            variant="accent"
            loading={busy}
            disabled={!canConfirm}
            onClick={() => void handleConfirm()}
          >
            {action === 'migrate'
              ? migrating
                ? '正在迁移素材库…'
                : '开始无损迁移'
              : savingSwitch
                ? '正在保存…'
                : '切换至该位置'}
          </SettingsButton>
        </>
      }
    >
      <div className="flex flex-col gap-1.5">
        <span className="text-[11.5px] font-medium text-[var(--text-secondary)]">操作方式</span>
        <SegmentedControl<LocationWizardAction>
          value={action}
          onChange={setAction}
          ariaLabel="素材库迁移方式"
          options={[
            { value: 'migrate', label: '完整无损迁移（推荐）' },
            { value: 'switchOnly', label: '仅切换指向位置' },
          ]}
        />
      </div>

      <div className="flex flex-col gap-1.5">
        <span className="text-[11.5px] font-medium text-[var(--text-secondary)]">目标存储方式</span>
        <SegmentedControl<DriveTransportMode>
          value={targetMode}
          onChange={(mode) => setDraft({ ...draft, mode })}
          ariaLabel="目标存储方式"
          options={[
            { value: 'directAPIWithGDirect', label: 'Google Drive' },
            { value: 'webDAV', label: 'WebDAV 云盘' },
            { value: 'localOnly', label: '纯本地文件夹' },
          ]}
        />
      </div>

      {targetMode === 'directAPIWithGDirect' && (
        <div className="flex flex-col gap-2.5">
          <label className="flex flex-col gap-1">
            <span className="text-[11.5px] font-medium text-[var(--text-secondary)]">
              目标 Google Drive 路径
            </span>
            <SettingsInput
              type="text"
              value={draft.rootFolderName}
              onChange={(e) => setDraft({ ...draft, rootFolderName: e.target.value })}
              placeholder="Charkle 或 Design/Charkle"
            />
          </label>
          {!hasReadyGoogleAccount && (
            <div className="rounded-[var(--win-radius-control)] bg-[var(--settings-warning)]/10 border border-[var(--settings-warning)]/25 px-3 py-2 flex items-center justify-between gap-2 text-[12px]">
              <span className="inline-flex items-center gap-1.5 text-[var(--text-secondary)]">
                <Info16Regular className="w-3.5 h-3.5 text-[var(--settings-warning)] shrink-0" />
                迁移到 Google Drive 前请先在「云同步」完成账号登录。
              </span>
              <SettingsButton
                variant="standard"
                size="xs"
                onClick={() => {
                  onClose();
                  setSettingsTab('sync');
                }}
              >
                前往云同步
              </SettingsButton>
            </div>
          )}
        </div>
      )}

      {targetMode === 'webDAV' && (
        <div className="flex flex-col gap-2">
          <SettingsInput
            type="text"
            value={draft.webDAVServerURL}
            onChange={(e) => setDraft({ ...draft, webDAVServerURL: e.target.value })}
            placeholder="服务器地址（如 https://dav.jianguoyun.com/dav/）"
          />
          {showWebdavUrlError && (
            <span className="text-[11px] text-[var(--settings-warning)]">
              请输入以 https:// 或 http:// 开头的有效服务器地址
            </span>
          )}
          <div className="grid grid-cols-2 gap-2">
            <SettingsInput
              type="text"
              value={draft.webDAVUsername}
              onChange={(e) => setDraft({ ...draft, webDAVUsername: e.target.value })}
              placeholder="用户名"
            />
            <SettingsInput
              type="password"
              value={webdavPassword}
              onChange={(e) => setWebdavPassword(e.target.value)}
              placeholder={hasWebdavPassword ? '应用密码（留空沿用已存）' : '应用密码'}
            />
          </div>
          <SettingsInput
            type="text"
            value={draft.webDAVRemotePath}
            onChange={(e) => setDraft({ ...draft, webDAVRemotePath: e.target.value })}
            placeholder="远端保存路径（如 /Charkle）"
          />
        </div>
      )}

      {targetMode === 'localOnly' && (
        <div className="flex flex-col gap-1">
          <span className="text-[11.5px] font-medium text-[var(--text-secondary)]">
            目标本机文件夹路径
          </span>
          <div className="flex gap-2">
            <SettingsInput
              type="text"
              value={draft.localLibraryPath}
              onChange={(e) => setDraft({ ...draft, localLibraryPath: e.target.value })}
              placeholder="例如：D:\Pictures\Charkle"
              className="flex-1"
            />
            <SettingsButton
              variant="standard"
              onClick={async () => {
                const picked = await getTransport().pickDirectoryDialog('选择素材库保存文件夹');
                if (picked) setDraft({ ...draft, localLibraryPath: picked });
              }}
            >
              选择文件夹…
            </SettingsButton>
          </div>
        </div>
      )}

      <div className="rounded-[var(--win-radius-card)] bg-[var(--settings-subtle)] border border-[var(--win-stroke-divider)] p-3 flex flex-col gap-1">
        <span className="text-[12px] font-semibold text-[var(--text-primary)]">
          {action === 'migrate' ? '无损迁移流程' : '仅切换说明'}
        </span>
        <p className="text-[11.5px] text-[var(--text-secondary)] leading-relaxed whitespace-pre-line">
          {action === 'migrate'
            ? '1. 验证目标位置连通与可写性，避免中断损坏原库；\n2. 自动补全拉取尚未缓存在本机的云端原件；\n3. 将全部文件夹、素材原件与情绪板完整写入新位置并切换为默认存储。'
            : '仅将 Charkle 指向新位置并保存配置，不搬运原位置的现有文件；适合接入已有云端或本地素材库。'}
        </p>
      </div>
    </SettingsSubModal>
  );
};

// =========================================================================
// Pane 1: 通用 (GeneralSettingsPane)
// =========================================================================

const THEME_CARDS: Array<{
  mode: ThemeMode;
  title: string;
  subtitle: string;
  icon: React.ReactNode;
}> = [
  {
    mode: 'system',
    title: '跟随系统',
    subtitle: '自动同步浅色与深色',
    icon: <Desktop16Regular className="w-4 h-4" />,
  },
  {
    mode: 'light',
    title: '浅色画廊',
    subtitle: '柔和暖白画布底色',
    icon: <WeatherSunny16Regular className="w-4 h-4" />,
  },
  {
    mode: 'dark',
    title: '深色画廊',
    subtitle: '低眩光专注看图',
    icon: <WeatherMoon16Regular className="w-4 h-4" />,
  },
];

export const GeneralSettingsPane: React.FC = () => {
  const themeMode = useCoordinatorStore((s) => s.themeMode);
  const setThemeMode = useCoordinatorStore((s) => s.setThemeMode);
  const accentSource = useCoordinatorStore((s) => s.accentSource);
  const setAccentSource = useCoordinatorStore((s) => s.setAccentSource);
  const surfaceState = useCoordinatorStore((s) => s.surfaceState);
  const layoutMode = useCoordinatorStore((s) => s.layoutMode);
  const setLayoutMode = useCoordinatorStore((s) => s.setLayoutMode);
  const sidebarCollapsed = useCoordinatorStore((s) => s.sidebarCollapsed);
  const setSidebarCollapsed = useCoordinatorStore((s) => s.setSidebarCollapsed);
  const openOnboarding = useCoordinatorStore((s) => s.openOnboarding);
  const pushToast = useCoordinatorStore((s) => s.pushToast);
  const setStatusFeedback = useSyncAIStore((s) => s.setStatusFeedback);
  const isDark = useResolvedIsDark(themeMode);

  const [autostart, setAutostart] = useState(false);

  const followWindowsAccent = accentSource === 'windows';
  const defaultStudioHex = isDark ? '#5B8DEF' : '#2A60E0';
  const systemAccentHex = surfaceState?.systemAccentHex?.trim() || null;
  const activeAccentHex =
    followWindowsAccent && systemAccentHex ? systemAccentHex.toUpperCase() : defaultStudioHex;

  useEffect(() => {
    void getTransport()
      .getDesktopIntegrationStatus()
      .then((st) => setAutostart(st.autostartEnabled))
      .catch(() => {});
  }, []);

  return (
    <div data-testid="settings-pane-general" className="flex flex-col gap-5">
      <SettingsSection title="外观与画廊">
        <div className="p-4 flex flex-col gap-3">
          <div className="flex flex-col gap-0.5">
            <div className="text-[13px] leading-[18px] font-medium text-[var(--text-primary)]">
              界面主题
            </div>
            <div className="text-[12px] leading-[16px] text-[var(--text-secondary)]">
              切换 Charkle 的画廊外观主题，点击立即生效。
            </div>
          </div>

          <div className="grid grid-cols-3 gap-2.5" role="radiogroup" aria-label="界面主题选择">
            {THEME_CARDS.map((card) => {
              const selected = themeMode === card.mode;
              return (
                <button
                  key={card.mode}
                  type="button"
                  role="radio"
                  aria-checked={selected}
                  onClick={() => {
                    void setThemeMode(card.mode);
                    setStatusFeedback(`已切换界面主题为「${card.title}」`, null);
                  }}
                  className={[
                    'charkle-pressable relative p-3 rounded-[var(--win-radius-card)] text-left cursor-pointer flex flex-col gap-1.5',
                    'focus-visible:outline-2 focus-visible:outline-offset-1 focus-visible:outline-[var(--accent)]',
                    selected
                      ? 'bg-[var(--accent-soft)] border border-[var(--accent)]'
                      : 'bg-[var(--settings-subtle)] border border-[var(--win-stroke-card)] hover:bg-[var(--win-subtle-hover)]',
                  ].join(' ')}
                >
                  <div className="flex items-center justify-between">
                    <span
                      className={
                        selected ? 'text-[var(--accent)]' : 'text-[var(--text-secondary)]'
                      }
                    >
                      {card.icon}
                    </span>
                    {selected && (
                      <CheckmarkCircle16Filled className="w-4 h-4 text-[var(--accent)] shrink-0" />
                    )}
                  </div>
                  <div className="text-[13px] leading-[18px] font-semibold text-[var(--text-primary)]">
                    {card.title}
                  </div>
                  <div className="text-[11.5px] leading-[16px] text-[var(--text-secondary)]">
                    {card.subtitle}
                  </div>
                </button>
              );
            })}
          </div>
        </div>

        {surfaceState?.backdrop === 'mica' && surfaceState.transparencyEnabled === false && (
          <>
            <SettingsCardDivider />
            <div data-testid="settings-transparency-prompt">
              <SettingsRow
                title="系统透明效果未开启"
                subtitle="开启 Windows 透明效果后，窗口标题栏与侧边栏将呈现柔和的桌面透色"
              >
                <SettingsButton
                  variant="standard"
                  onClick={() => {
                    void getTransport()
                      .openExternalUrl('ms-settings:colors')
                      .catch((err) => {
                        pushToast({
                          message:
                            err instanceof Error ? err.message : '无法打开 Windows 个性化设置',
                          tone: 'error',
                        });
                      });
                  }}
                >
                  打开系统设置
                  <Open16Regular className="w-3.5 h-3.5 shrink-0" />
                </SettingsButton>
              </SettingsRow>
            </div>
          </>
        )}

        <SettingsCardDivider />

        <SettingsRow
          title="画廊默认排布"
          subtitle="打开全部素材或文件夹时默认采用的浏览视图（Ctrl+1 / 2 / 3 / 4）"
        >
          <SegmentedControl<GalleryLayoutMode>
            value={layoutMode}
            onChange={setLayoutMode}
            ariaLabel="默认画廊布局"
            options={[
              { value: 'verticalMasonry', label: '纵向瀑布流' },
              { value: 'horizontalJustified', label: '横向等高行' },
              { value: 'galleryFilmstrip', label: '画廊视图' },
              { value: 'ringGallery', label: '环形画廊' },
            ]}
          />
        </SettingsRow>

        <SettingsCardDivider />

        <SettingsRow
          title="启动时收起侧边栏为精简图标栏"
          subtitle="随时按 Ctrl+\ 一键展开或收起，左下角齿轮按钮可随时打开设置"
        >
          <SettingsSwitch
            checked={sidebarCollapsed}
            onChange={setSidebarCollapsed}
            ariaLabel="收起侧边栏为精简图标栏"
          />
        </SettingsRow>
      </SettingsSection>

      <SettingsSection title="强调色" data-testid="settings-accent-controls">
        <SettingsRow
          icon={<Color20Regular className="w-[18px] h-[18px]" />}
          title="跟随 Windows 系统强调色"
          subtitle={
            followWindowsAccent
              ? systemAccentHex
                ? '已同步 Windows 个性化强调色，并自动完成浅/深色对比度校准'
                : '已开启系统强调色跟随；未读取到系统强调色时将保持工作室钴蓝'
              : '默认使用工作室钴蓝（#2A60E0 / #5B8DEF）；开启后同步 Windows 个性化强调色'
          }
        >
          <span
            data-testid="settings-accent-swatch"
            className="inline-flex items-center gap-1.5 h-7 px-2 rounded-[var(--win-radius-control)] bg-[var(--settings-subtle)] border border-[var(--win-stroke-card)] text-[11.5px] font-medium charkle-mono text-[var(--text-primary)] shrink-0"
          >
            <span
              aria-hidden="true"
              style={{ backgroundColor: activeAccentHex }}
              className="w-3 h-3 rounded-[3px] border border-black/15 dark:border-white/20 shrink-0"
            />
            <span>{activeAccentHex}</span>
          </span>
          <Switch
            checked={followWindowsAccent}
            ariaLabel="跟随 Windows 系统强调色"
            onCheckedChange={(checked) => {
              setAccentSource(checked ? 'windows' : 'studio');
              setStatusFeedback(
                checked ? '已开启跟随 Windows 系统强调色' : '已恢复默认工作室钴蓝强调色',
                null,
              );
            }}
          />
        </SettingsRow>
      </SettingsSection>

      <SettingsSection title="系统集成">
        <SettingsRow
          title="开机自动启动 Charkle"
          subtitle="登录 Windows 后驻留系统托盘，保持全局快捷键与顶部浮窗随时待命"
        >
          <SettingsSwitch
            checked={autostart}
            ariaLabel="开机自动启动 Charkle"
            onChange={async (next) => {
              try {
                const applied = await getTransport().setAutostartEnabled(next);
                setAutostart(applied);
                pushToast({
                  message: applied ? '已开启开机自启动' : '已关闭开机自启动',
                  tone: 'info',
                });
              } catch (err) {
                pushToast({
                  message: err instanceof Error ? err.message : '切换开机自启动失败',
                  tone: 'error',
                });
              }
            }}
          />
        </SettingsRow>
      </SettingsSection>

      <SettingsSection title="入门与帮助">
        <SettingsRow
          title="快速上手引导"
          subtitle="重新配置素材库存储、顶部浮窗、AI 智能与外观偏好（每步均可跳过）"
        >
          <SettingsButton variant="accent" onClick={openOnboarding}>
            重新查看
          </SettingsButton>
        </SettingsRow>
      </SettingsSection>
    </div>
  );
};

// =========================================================================
// Pane 2: 素材库 (LibrarySettingsPane) — mirrors LibrarySettingsPane.swift 1:1
// =========================================================================

export const LibrarySettingsPane: React.FC = () => {
  const setSettingsTab = useCoordinatorStore((s) => s.setSettingsTab);
  const syncConfig = useSyncAIStore((s) => s.syncConfig);
  const cacheStats = useSyncAIStore((s) => s.cacheStats);
  const diagnostics = useSyncAIStore((s) => s.diagnostics);
  const syncing = useSyncAIStore((s) => s.syncing);
  const migrating = useSyncAIStore((s) => s.migrating);
  const lastMigrationReport = useSyncAIStore((s) => s.lastMigrationReport);
  const setCacheBudgetBytes = useSyncAIStore((s) => s.setCacheBudgetBytes);
  const evictCacheNow = useSyncAIStore((s) => s.evictCacheNow);
  const syncNow = useSyncAIStore((s) => s.syncNow);
  const openDirectoryInExplorer = useSyncAIStore((s) => s.openDirectoryInExplorer);

  const cfg = syncConfig ?? DEFAULT_SYNC_CONFIG;
  const budgetGb = Math.max(
    2,
    Math.min(100, Math.round((cacheStats?.budgetBytes ?? 10 * 1024 ** 3) / 1024 ** 3)),
  );
  const [sliderGb, setSliderGb] = useState(budgetGb);
  const [showWizard, setShowWizard] = useState(false);
  const [evicting, setEvicting] = useState(false);

  useEffect(() => {
    setSliderGb(budgetGb);
  }, [budgetGb]);

  const thumbBytes = cacheStats?.thumbnailBytes ?? 0;
  const origBytes = cacheStats?.originalCacheBytes ?? 0;
  const pinnedBytes = cacheStats?.pinnedOfflineBytes ?? 0;
  const totalUsed = thumbBytes + origBytes + pinnedBytes;
  const barScale = Math.max(1, totalUsed, cacheStats?.budgetBytes ?? 1);

  const thumbPct = thumbBytes > 0 ? Math.min(45, Math.max(2, (thumbBytes / barScale) * 100)) : 0;
  const origPct = origBytes > 0 ? Math.min(45, Math.max(2, (origBytes / barScale) * 100)) : 0;
  const pinPct = pinnedBytes > 0 ? Math.min(45, Math.max(2, (pinnedBytes / barScale) * 100)) : 0;

  return (
    <div data-testid="settings-pane-library" className="flex flex-col gap-5">
      <SettingsSection title="当前存储位置">
        <SettingsRow
          title={storageModeHeadline(cfg.mode)}
          subtitle={activeStorageLocationSummary(cfg, diagnostics?.dataDir)}
          subtitleTone={cfg.mode === 'localOnly' ? 'default' : 'positive'}
        >
          {cfg.mode === 'localOnly' ? (
            <SettingsButton
              variant="standard"
              onClick={() =>
                void openDirectoryInExplorer(cfg.localLibraryPath || diagnostics?.dataDir || '')
              }
            >
              <FolderOpen16Regular className="w-3.5 h-3.5 shrink-0" />
              打开文件夹
            </SettingsButton>
          ) : (
            <SettingsButton variant="standard" onClick={() => setSettingsTab('sync')}>
              同步设置
            </SettingsButton>
          )}

          <SettingsButton
            variant="accent"
            disabled={syncing || migrating}
            onClick={() => setShowWizard(true)}
          >
            更改或转移…
          </SettingsButton>
        </SettingsRow>

        {cfg.mode === 'localOnly' && (
          <>
            <SettingsCardDivider />
            <SettingsRow
              title="本机目录同步检查"
              subtitle="手动扫描当前本机文件夹内新增的文件并补齐索引"
            >
              <SettingsButton
                variant="standard"
                loading={syncing}
                onClick={() => void syncNow()}
              >
                <ArrowSync16Regular
                  className={`w-3.5 h-3.5 shrink-0 ${syncing ? 'animate-spin motion-reduce:animate-none' : ''}`}
                />
                立即扫描
              </SettingsButton>
            </SettingsRow>
          </>
        )}

        {lastMigrationReport && (
          <div
            data-testid="storage-migration-report"
            className="mx-4 mb-3 rounded-[var(--win-radius-control)] bg-[var(--settings-positive)]/10 border border-[var(--settings-positive)]/25 p-3 text-[12px] text-[var(--text-primary)] flex items-center gap-2"
          >
            <CheckmarkCircle16Filled className="w-4 h-4 text-[var(--settings-positive)] shrink-0" />
            <span>
              素材库已迁移至「{lastMigrationReport.targetLocation}」：
              {lastMigrationReport.migratedAssets} 项素材、{lastMigrationReport.migratedFolders}{' '}
              个文件夹、{lastMigrationReport.migratedBoards} 块情绪板。
            </span>
          </div>
        )}

        <InlineGuideDisclosure title="切换存储方式会丢失素材吗？怎么安全搬家">
          <SettingsGuideStep
            number="1"
            title="选择「完整无损迁移（推荐）」不会丢失任何内容"
            detail="Charkle 会先验证新位置可写、自动拉取尚未缓存在本机的云端原件，再把全部文件夹、原图与情绪板写入新位置。"
          />
          <SettingsGuideStep
            number="2"
            title="「仅切换指向位置」适合接入已有素材库"
            detail="如果你在另一台电脑或云盘已有现成的 Charkle 目录，仅切换指向即可直接连接，不搬运本机现有文件。"
          />
          <SettingsGuideStep
            number="3"
            title="随时可在 Google Drive、WebDAV 与纯本地之间互迁"
            detail="原始文件均按可读文件夹保存，不锁定专有格式，在文件资源管理器或网盘网页端都能直接查看。"
          />
        </InlineGuideDisclosure>
      </SettingsSection>

      <SettingsSection title="本机缓存空间">
        <div className="px-4 py-3.5 flex flex-col gap-3">
          <div className="flex items-baseline justify-between gap-2">
            <span className="text-[13px] font-medium text-[var(--text-primary)]">
              已使用本机缓存
            </span>
            <span className="text-[12px] font-medium text-[var(--text-secondary)] charkle-tabular">
              {formatBytes(totalUsed)} / {sliderGb} GB 上限
            </span>
          </div>

          {/* 3-segment proportional stacked bar */}
          <div className="h-[16px] w-full rounded-[var(--win-radius-control)] bg-[var(--settings-subtle)] p-[3px] flex items-center gap-[2px] overflow-hidden">
            {thumbPct > 0 && (
              <div
                style={{ width: `${thumbPct}%`, backgroundColor: '#4E7D96' }}
                className="h-full rounded-[2px]"
              />
            )}
            {origPct > 0 && (
              <div
                style={{ width: `${origPct}%`, backgroundColor: '#D4A373' }}
                className="h-full rounded-[2px]"
              />
            )}
            {pinPct > 0 && (
              <div
                style={{ width: `${pinPct}%`, backgroundColor: '#6B8E76' }}
                className="h-full rounded-[2px]"
              />
            )}
          </div>

          <div className="grid grid-cols-3 gap-3">
            <div className="flex items-center gap-2">
              <span className="h-2 w-2 rounded-full shrink-0" style={{ backgroundColor: '#4E7D96' }} />
              <div className="min-w-0">
                <div className="text-[11px] text-[var(--text-secondary)] truncate">画廊预览图</div>
                <div className="text-[12px] font-semibold text-[var(--text-primary)] charkle-tabular">
                  {formatBytes(thumbBytes)}
                </div>
              </div>
            </div>
            <div className="flex items-center gap-2">
              <span className="h-2 w-2 rounded-full shrink-0" style={{ backgroundColor: '#D4A373' }} />
              <div className="min-w-0">
                <div className="text-[11px] text-[var(--text-secondary)] truncate">
                  临时原件（{cacheStats?.cachedOriginalCount ?? 0} 项）
                </div>
                <div className="text-[12px] font-semibold text-[var(--text-primary)] charkle-tabular">
                  {formatBytes(origBytes)}
                </div>
              </div>
            </div>
            <div className="flex items-center gap-2">
              <span className="h-2 w-2 rounded-full shrink-0" style={{ backgroundColor: '#6B8E76' }} />
              <div className="min-w-0">
                <div className="text-[11px] text-[var(--text-secondary)] truncate">
                  常驻离线（{cacheStats?.pinnedAssetCount ?? 0} 项）
                </div>
                <div className="text-[12px] font-semibold text-[var(--text-primary)] charkle-tabular">
                  {formatBytes(pinnedBytes)}
                </div>
              </div>
            </div>
          </div>
        </div>

        <SettingsCardDivider />

        <div className="px-4 py-3.5 flex flex-col gap-2">
          <div className="flex items-start justify-between gap-3">
            <div className="min-w-0">
              <div className="text-[13px] font-medium text-[var(--text-primary)]">
                临时原件缓存上限
              </div>
              <div className="text-[12px] text-[var(--text-secondary)] mt-0.5">
                超出上限时按最久未用自动回收，常驻离线素材与预览图不受影响
              </div>
            </div>
            <span className="text-[12.5px] font-semibold text-[var(--text-primary)] charkle-tabular shrink-0">
              {sliderGb} GB
            </span>
          </div>
          <CharkleSlider
            variant="standard"
            min={2}
            max={100}
            step={1}
            value={sliderGb}
            valueText={`${sliderGb} GB`}
            ariaLabel="本地缓存预算 GB"
            onChange={setSliderGb}
            onChangeEnd={(nextGb) => void setCacheBudgetBytes(nextGb * 1024 ** 3)}
            className="w-full"
          />
          <div className="flex items-center justify-between text-[11px] text-[var(--text-tertiary)] charkle-tabular">
            <span>2 GB</span>
            <span>100 GB</span>
          </div>
        </div>

        <SettingsCardDivider />

        <SettingsRow
          title="清理临时原件缓存"
          subtitle="立即释放未设为「始终保留在本地」的临时原件，云端与本地原件安全保留"
        >
          <SettingsButton
            variant="standard"
            loading={evicting}
            disabled={syncing || migrating}
            onClick={async () => {
              setEvicting(true);
              try {
                await evictCacheNow();
              } finally {
                setEvicting(false);
              }
            }}
          >
            {evicting ? '清理中…' : '立即清理'}
          </SettingsButton>
        </SettingsRow>
      </SettingsSection>

      <StorageLocationWizardModal open={showWizard} onClose={() => setShowWizard(false)} />
    </div>
  );
};

// =========================================================================
// Pane 3: 云同步 (SyncSettingsPane) — mirrors SyncSettingsPane.swift 1:1
// =========================================================================

export const SyncSettingsPane: React.FC = () => {
  const setSettingsTab = useCoordinatorStore((s) => s.setSettingsTab);
  const syncConfig = useSyncAIStore((s) => s.syncConfig);
  const syncStatus = useSyncAIStore((s) => s.syncStatus);
  const lastSyncReport = useSyncAIStore((s) => s.lastSyncReport);
  const lastMigrationReport = useSyncAIStore((s) => s.lastMigrationReport);
  const diagnostics = useSyncAIStore((s) => s.diagnostics);
  const syncing = useSyncAIStore((s) => s.syncing);
  const signingInGoogle = useSyncAIStore((s) => s.signingInGoogle);
  const testingWebdav = useSyncAIStore((s) => s.testingWebdav);
  const hasGoogleOAuthClient = useSyncAIStore((s) => s.hasGoogleOAuthClient);
  const saveSyncConfig = useSyncAIStore((s) => s.saveSyncConfig);
  const testWebdavConnection = useSyncAIStore((s) => s.testWebdavConnection);
  const signInGoogleDrive = useSyncAIStore((s) => s.signInGoogleDrive);
  const signOutGoogleDrive = useSyncAIStore((s) => s.signOutGoogleDrive);
  const syncNow = useSyncAIStore((s) => s.syncNow);

  const [draft, setDraft] = useState<DriveSyncConfig>(syncConfig ?? DEFAULT_SYNC_CONFIG);
  const [showOAuthModal, setShowOAuthModal] = useState(false);
  const [showWebDAVModal, setShowWebDAVModal] = useState(false);
  const [showWizard, setShowWizard] = useState(false);

  useEffect(() => {
    if (syncConfig && !showWebDAVModal && !showWizard) setDraft(syncConfig);
  }, [syncConfig, showWebDAVModal, showWizard]);

  const persistQuiet = (next: DriveSyncConfig) => {
    setDraft(next);
    void saveSyncConfig(next, undefined, { quiet: true });
  };

  const isBusy = syncing || signingInGoogle || testingWebdav || isSyncPhaseBusy(syncStatus);
  const isSyncingNow = syncing || isSyncPhaseBusy(syncStatus);
  const hasGDirect = Boolean(diagnostics?.gdirect.cliPath);

  const directAccount = isDirectGoogleDriveAccount(syncStatus?.account)
    ? syncStatus.account
    : null;

  const gdirectEmail =
    draft.selectedGDirectAccount ??
    diagnostics?.gdirect.defaultAccount ??
    diagnostics?.gdirect.accounts[0] ??
    null;

  const activeGoogleAccount =
    draft.mode === 'gdirectMount'
      ? gdirectEmail
        ? { email: gdirectEmail, displayName: null, source: 'gdirect mount', storageUsedBytes: null, storageLimitBytes: null }
        : null
      : directAccount ??
        (gdirectEmail
          ? { email: gdirectEmail, displayName: null, source: 'gdirect', storageUsedBytes: null, storageLimitBytes: null }
          : null);

  const isUsingGDirectFallback =
    draft.mode === 'directAPIWithGDirect' && !directAccount && activeGoogleAccount != null;

  const triggerGoogleSignIn = () => {
    if (hasGoogleOAuthClient) {
      void signInGoogleDrive();
    } else {
      setShowOAuthModal(true);
    }
  };

  // State A: Local-only guidance
  if (draft.mode === 'localOnly') {
    return (
      <div data-testid="settings-pane-sync" className="flex flex-col gap-5">
        <SettingsSection title="云端同步服务">
          <SettingsRow
            title="当前素材库仅保存在本机"
            subtitle={`路径：${activeStorageLocationSummary(draft, diagnostics?.dataDir)} · 启用云同步可在多台设备间自动同步并支持团队共享`}
          >
            <SettingsButton variant="standard" onClick={() => setSettingsTab('library')}>
              管理素材库位置
            </SettingsButton>
          </SettingsRow>

          <SettingsCardDivider />

          <SettingsRow
            title="Google Drive 云端直连"
            subtitle="推荐 · 原始文件按可读目录保存在你的 Google Drive，支持共享协作与网页端直接拖入新素材"
          >
            <SettingsButton
              variant="accent"
              onClick={() => persistQuiet({ ...draft, mode: 'directAPIWithGDirect' })}
            >
              启用 Google 同步
            </SettingsButton>
          </SettingsRow>

          <InlineGuideDisclosure title="开始前需要准备什么？（仅首次需 3 分钟配置凭据）">
            <SettingsGuideStep
              number="1"
              title="直连你自己的 Google Drive，不经任何第三方中转服务器"
              detail="因此首次登录前需要准备一份个人桌面端 OAuth 凭据（client_secret.json）。"
            />
            <SettingsGuideStep
              number="2"
              title="随时可在「设置 → 云同步」导入凭据或手动粘贴 Client ID"
              detail="启用 Google 同步后，可一键导入从 Google Cloud 下载的凭据文件并完成登录。"
            />
            <SettingsGuideStep
              number="3"
              title="想把已有本地素材一并迁上云盘？"
              detail="点击下方「更改或转移…」选择完整无损迁移，自动搬运全部文件夹、原图与情绪板。"
            />
          </InlineGuideDisclosure>

          <SettingsCardDivider />

          <SettingsRow
            title="WebDAV 云盘"
            subtitle="兼容坚果云、Nextcloud、群晖 NAS、Alist 等任意标准 WebDAV 服务"
          >
            <SettingsButton variant="standard" onClick={() => setShowWebDAVModal(true)}>
              配置 WebDAV…
            </SettingsButton>
          </SettingsRow>

          <SettingsCardDivider />

          <SettingsRow
            title="无损迁移现有素材至云盘"
            subtitle="将当前本机素材、文件夹与情绪板完整搬迁至 Google Drive 或 WebDAV"
          >
            <SettingsButton variant="standard" onClick={() => setShowWizard(true)}>
              <ArrowSwap16Regular className="w-3.5 h-3.5 shrink-0" />
              更改或转移…
            </SettingsButton>
          </SettingsRow>
        </SettingsSection>

        <WebDAVEditorModal
          open={showWebDAVModal}
          onClose={() => setShowWebDAVModal(false)}
          initialConfig={draft}
        />
        <StorageLocationWizardModal open={showWizard} onClose={() => setShowWizard(false)} />
      </div>
    );
  }

  // State B: Active Cloud Sync (Google Drive / gdirectMount / WebDAV)
  const sharedID = resolveSharedFolderID(draft.sharedFolderURLOrID);
  const trimmedShared = draft.sharedFolderURLOrID.trim();
  const isWebDAVConnected = syncStatus?.account?.source === 'WebDAV';
  let webdavHost = draft.webDAVServerURL.trim();
  try {
    webdavHost = new URL(draft.webDAVServerURL).host || webdavHost;
  } catch {
    // keep raw url
  }

  return (
    <div data-testid="settings-pane-sync" className="flex flex-col gap-5">
      {/* 1. Live Sync Status Section */}
      <SettingsSection title="同步状态">
        <div className="px-4 py-3.5 flex flex-col gap-2.5">
          <div className="flex items-center justify-between gap-3">
            <div className="flex items-center gap-3 min-w-0">
              {isSyncingNow ? (
                <ArrowSync16Regular className="w-4 h-4 text-[var(--accent)] animate-spin motion-reduce:animate-none shrink-0" />
              ) : (
                <span
                  style={{ backgroundColor: syncIndicatorColor(syncStatus) }}
                  className="h-2 w-2 rounded-full shrink-0"
                />
              )}

              <div className="min-w-0 flex flex-col gap-0.5">
                <div className="flex items-center gap-2">
                  <span className="text-[13px] font-medium text-[var(--text-primary)] truncate">
                    {isSyncingNow
                      ? localizedSyncPhaseTitle(syncStatus)
                      : syncIdleHeadline(syncStatus)}
                  </span>
                  {isSyncingNow && syncStatus?.progressFraction != null && (
                    <span className="text-[11px] charkle-mono font-semibold text-[var(--text-secondary)] charkle-tabular">
                      {Math.round(syncStatus.progressFraction * 100)}%
                    </span>
                  )}
                </div>
                <span
                  className={[
                    'text-[12px] leading-snug line-clamp-2',
                    syncStatus?.lastError && !isSyncingNow
                      ? 'text-[var(--settings-destructive)]'
                      : 'text-[var(--text-secondary)]',
                  ].join(' ')}
                >
                  {isSyncingNow
                    ? syncStatus?.currentDetail ||
                      `正在与 ${activeStorageLocationSummary(draft, diagnostics?.dataDir)} 同步…`
                    : syncStatus?.lastError ||
                      `目标：${activeStorageLocationSummary(draft, diagnostics?.dataDir)}`}
                </span>
              </div>
            </div>

            <SettingsButton
              variant="accent"
              loading={isSyncingNow}
              onClick={() => void syncNow()}
            >
              {isSyncingNow ? '同步中…' : '立即同步'}
            </SettingsButton>
          </div>

          {isSyncingNow && (
            <div className="h-1.5 w-full rounded-full bg-[var(--settings-subtle)] overflow-hidden">
              <div
                style={{
                  transform: `scaleX(${Math.max(0.12, Math.min(1, syncStatus?.progressFraction ?? 0.35))})`,
                }}
                className="h-full w-full origin-left rounded-full bg-[var(--accent)] transition-transform duration-200 motion-reduce:transition-none"
              />
            </div>
          )}

          <div className="flex flex-wrap items-center justify-between gap-2 text-[11.5px] text-[var(--text-secondary)]">
            <div className="flex items-center gap-3">
              <span className="inline-flex items-center gap-1">
                <Clock16Regular className="w-3 h-3 shrink-0" />
                {syncStatus?.lastSyncedAt
                  ? `上次同步：${relativeTimeText(syncStatus.lastSyncedAt)}`
                  : '尚未完成首次同步'}
              </span>
              {(syncStatus?.pendingOpCount ?? 0) > 0 && (
                <span className="inline-flex items-center gap-1 font-medium text-[var(--settings-warning)] charkle-tabular">
                  <ArrowCircleUp16Regular className="w-3 h-3 shrink-0" />
                  待上传 {syncStatus?.pendingOpCount} 项
                </span>
              )}
            </div>

            {lastSyncReport && (
              <span className="text-[11px] charkle-mono text-[var(--text-tertiary)] charkle-tabular">
                ↑ {lastSyncReport.uploadedOps}  ↓ {lastSyncReport.downloadedOps}  +
                {lastSyncReport.discoveredRemoteAssets} 新发现
              </span>
            )}
          </div>
        </div>
      </SettingsSection>

      {/* 2A. Google Drive Account & Shared Collaboration */}
      {(draft.mode === 'directAPIWithGDirect' || draft.mode === 'gdirectMount') && (
        <>
          <SettingsSection title="Google Drive 账号">
            {draft.mode === 'gdirectMount' ? (
              <SettingsRow
                title={gdirectEmail ?? '当前处于本地挂载盘模式'}
                subtitle={
                  diagnostics?.gdirect.isMountActive
                    ? `已挂载至 ${draft.mountPath}（如需切回免挂载高速直连，可随时切换）`
                    : '当前挂载路径未就绪，可在「高级与关于」检查挂载目录或切回标准直连'
                }
                subtitleTone={diagnostics?.gdirect.isMountActive ? 'positive' : 'warning'}
              >
                <SettingsButton
                  variant="standard"
                  onClick={() => persistQuiet({ ...draft, mode: 'directAPIWithGDirect' })}
                >
                  切回标准直连
                </SettingsButton>
                <SettingsButton
                  variant="standard"
                  onClick={() => setSettingsTab('advancedAbout')}
                >
                  挂载管理
                </SettingsButton>
              </SettingsRow>
            ) : (
              <div>
                <div className="px-4 py-3.5 flex items-center justify-between gap-3">
                  <div className="flex items-center gap-3 min-w-0">
                    <span className="h-[38px] w-[38px] rounded-full bg-[var(--settings-subtle)] inline-flex items-center justify-center shrink-0">
                      {activeGoogleAccount ? (
                        <PersonAvailable16Regular className="w-5 h-5 text-[var(--settings-positive)]" />
                      ) : (
                        <PersonCircle16Regular className="w-5 h-5 text-[var(--text-secondary)]" />
                      )}
                    </span>

                    <div className="min-w-0 flex flex-col gap-0.5">
                      <div className="flex items-center gap-1.5">
                        <span className="text-[13px] font-semibold text-[var(--text-primary)] truncate">
                          {activeGoogleAccount?.displayName ||
                            activeGoogleAccount?.email ||
                            '未登录 Google 账号'}
                        </span>
                        {directAccount && <SettingsStatusBadge text="已直连" tone="positive" />}
                        {isUsingGDirectFallback && (
                          <SettingsStatusBadge text="gdirect 兜底" tone="warning" />
                        )}
                      </div>

                      <span className="text-[12px] text-[var(--text-secondary)] leading-snug">
                        {activeGoogleAccount?.displayName
                          ? activeGoogleAccount.email
                          : isUsingGDirectFallback
                            ? '当前暂用本机 gdirect 兜底，独立登录 Google 账号后可启用免挂载高速直连'
                            : !hasGoogleOAuthClient
                              ? hasGDirect
                                ? '检测到本机 gdirect，配置桌面端凭据后即可开启免挂载高速直连'
                                : '首次登录需配置一次 Google 桌面端凭据，完成后自动开启直连同步'
                              : '登录 Google 账号后，素材与情绪板将自动直连同步'}
                      </span>
                    </div>
                  </div>

                  <div className="flex items-center gap-2 shrink-0">
                    {directAccount ? (
                      <>
                        <SettingsButton
                          variant="standard"
                          disabled={isBusy}
                          onClick={triggerGoogleSignIn}
                        >
                          切换账号
                        </SettingsButton>
                        <SettingsButton
                          variant="danger"
                          disabled={isBusy}
                          onClick={() => void signOutGoogleDrive()}
                        >
                          退出
                        </SettingsButton>
                      </>
                    ) : (
                      <>
                        {hasGoogleOAuthClient && (
                          <SettingsButton
                            variant="standard"
                            disabled={isBusy}
                            onClick={() => setShowOAuthModal(true)}
                          >
                            管理凭据…
                          </SettingsButton>
                        )}
                        <SettingsButton
                          variant="standard"
                          loading={signingInGoogle}
                          onClick={triggerGoogleSignIn}
                        >
                          {hasGoogleOAuthClient ? '使用 Google 登录' : '配置凭据并登录'}
                        </SettingsButton>
                      </>
                    )}
                  </div>
                </div>

                {activeGoogleAccount?.storageUsedBytes != null &&
                  activeGoogleAccount?.storageLimitBytes != null &&
                  activeGoogleAccount.storageLimitBytes > 0 && (
                    <div className="px-4 pb-3 flex flex-col gap-1">
                      <div className="flex items-center justify-between text-[11.5px] text-[var(--text-secondary)] charkle-tabular">
                        <span>Google Drive 云端空间</span>
                        <span>
                          {formatBytes(activeGoogleAccount.storageUsedBytes)} /{' '}
                          {formatBytes(activeGoogleAccount.storageLimitBytes)}
                        </span>
                      </div>
                      <div className="h-1.5 w-full rounded-full bg-[var(--settings-subtle)] overflow-hidden">
                        <div
                          style={{
                            transform: `scaleX(${Math.max(0, Math.min(1, activeGoogleAccount.storageUsedBytes / activeGoogleAccount.storageLimitBytes))})`,
                          }}
                          className="h-full w-full origin-left rounded-full bg-[var(--accent)] transition-transform duration-200 motion-reduce:transition-none"
                        />
                      </div>
                    </div>
                  )}

                {!hasGoogleOAuthClient && !directAccount && (
                  <InlineGuideDisclosure title="为什么首次登录需要配置一次凭据？">
                    <SettingsGuideStep
                      number="1"
                      title="你的素材直连个人 Google Drive，零中转"
                      detail="Charkle 不经过云端代理服务器，所有原图和情绪板直接读写你自己的网盘。"
                    />
                    <SettingsGuideStep
                      number="2"
                      title="按教程 3 分钟创建一次桌面端 Client ID 即可长期使用"
                      detail="点击「配置凭据并登录」即可打开教程链接，支持直接导入下载的 client_secret.json。"
                    />
                  </InlineGuideDisclosure>
                )}
              </div>
            )}

            <SettingsCardDivider />

            <SettingsRow
              title="云端保存路径"
              subtitle={
                sharedID
                  ? '当前已绑定下方共享协作目录；清除后将恢复使用此路径'
                  : '支持单级目录（Charkle）或多级路径（Design/Charkle）'
              }
            >
              <SettingsInput
                type="text"
                value={draft.rootFolderName}
                disabled={Boolean(sharedID)}
                onChange={(e) => setDraft({ ...draft, rootFolderName: e.target.value })}
                onBlur={() => persistQuiet(draft)}
                onKeyDown={(e) => {
                  if (e.key === 'Enter') persistQuiet(draft);
                }}
                placeholder="Charkle"
                className="w-[210px]"
              />
            </SettingsRow>
          </SettingsSection>

          <SettingsSection title="团队共享协作（可选）">
            <div className="px-4 py-3.5 flex flex-col gap-2.5">
              <div className="flex flex-col gap-0.5">
                <span className="text-[13px] font-medium text-[var(--text-primary)]">
                  共享协作目录
                </span>
                {sharedID ? (
                  <span className="text-[12px] text-[var(--settings-positive)]">
                    已启用协作模式（目录 ID：{sharedID.slice(0, 12)}…）
                  </span>
                ) : trimmedShared ? (
                  <span className="text-[12px] text-[var(--settings-warning)]">
                    链接或 ID 格式无效，请检查是否包含 /folders/…
                  </span>
                ) : (
                  <span className="text-[12px] text-[var(--text-secondary)]">
                    粘贴 Google Drive「与我共享」目录链接或 ID，多人可共同整理与浏览
                  </span>
                )}
              </div>

              <div className="flex items-center gap-2">
                <SettingsInput
                  type="text"
                  value={draft.sharedFolderURLOrID}
                  onChange={(e) => setDraft({ ...draft, sharedFolderURLOrID: e.target.value })}
                  onBlur={() => persistQuiet(draft)}
                  onKeyDown={(e) => {
                    if (e.key === 'Enter') persistQuiet(draft);
                  }}
                  placeholder="https://drive.google.com/drive/folders/… 或目录 ID"
                  className="flex-1"
                />
                {trimmedShared && (
                  <SettingsButton
                    variant="standard"
                    onClick={() => persistQuiet({ ...draft, sharedFolderURLOrID: '' })}
                  >
                    清除
                  </SettingsButton>
                )}
              </div>
            </div>

            <InlineGuideDisclosure title="如何与团队成员共享同一个素材库">
              <SettingsGuideStep
                number="1"
                title="在 Google Drive 网页端将 Charkle 文件夹共享给协作者（编辑者权限）"
              />
              <SettingsGuideStep
                number="2"
                title="协作者登录 Charkle 后，直接粘贴共享目录链接或 ID"
                detail="所有成员对标签、文件夹与情绪板的编辑都会通过增量日志安全合并，互不覆盖。"
              />
            </InlineGuideDisclosure>
          </SettingsSection>
        </>
      )}

      {/* 2B. WebDAV Account Section */}
      {draft.mode === 'webDAV' && (
        <SettingsSection title="WebDAV 服务">
          <SettingsRow
            title={webdavHost || '尚未配置 WebDAV 服务器'}
            subtitle={
              webdavHost
                ? `账号：${draft.webDAVUsername || '未填写'} · 路径：${draft.webDAVRemotePath || '/Charkle'}`
                : '支持坚果云、Nextcloud、群晖 NAS、Alist 等标准 WebDAV 服务'
            }
            subtitleTone={isWebDAVConnected ? 'positive' : 'default'}
          >
            <SettingsButton
              variant="standard"
              loading={testingWebdav}
              disabled={!draft.webDAVServerURL.trim() || isBusy}
              onClick={() => void testWebdavConnection(draft, null)}
            >
              测试连接
            </SettingsButton>
            <SettingsButton variant="standard" onClick={() => setShowWebDAVModal(true)}>
              编辑配置…
            </SettingsButton>
          </SettingsRow>

          <InlineGuideDisclosure title="坚果云 / 群晖 NAS 如何获取应用密码">
            <SettingsGuideStep
              number="1"
              title="坚果云用户请使用「第三方应用管理」生成的专用密码"
              detail="服务器地址一般为 https://dav.jianguoyun.com/dav/，不要直接使用网页登录密码。"
            />
            <SettingsGuideStep
              number="2"
              title="密码仅加密保存于 Windows 凭据管理器"
              detail="不会明文写入任何配置文件。"
            />
          </InlineGuideDisclosure>
        </SettingsSection>
      )}

      {/* 3. Sync Preferences */}
      <SettingsSection title="同步偏好">
        <SettingsRow
          title="同步轻量化预览图"
          subtitle="切换其他电脑时秒看完整画廊，无需等待下载原始大文件"
        >
          <SettingsSwitch
            checked={draft.syncThumbnails}
            ariaLabel="同步轻量化预览图"
            onChange={(syncThumbnails) => persistQuiet({ ...draft, syncThumbnails })}
          />
        </SettingsRow>

        <SettingsCardDivider />

        <SettingsRow
          title="同步智能搜索索引"
          subtitle="在多台设备间共享搜索索引，保持一致的搜图与情绪板推荐体验"
        >
          <SettingsSwitch
            checked={draft.syncEmbeddings}
            ariaLabel="同步智能搜索索引"
            onChange={(syncEmbeddings) => persistQuiet({ ...draft, syncEmbeddings })}
          />
        </SettingsRow>

        <SettingsCardDivider />

        <SettingsRow
          title="切换或无损迁移存储位置"
          subtitle="随时在 Google Drive、WebDAV 与纯本地文件夹之间安全搬家"
        >
          <SettingsButton variant="standard" onClick={() => setShowWizard(true)}>
            <ArrowSwap16Regular className="w-3.5 h-3.5 shrink-0" />
            更改或转移…
          </SettingsButton>
        </SettingsRow>
      </SettingsSection>

      {lastMigrationReport && (
        <div
          data-testid="storage-migration-report"
          className="rounded-[var(--win-radius-card)] bg-[var(--settings-positive)]/10 border border-[var(--settings-positive)]/25 p-3 text-[12px] text-[var(--text-primary)] flex items-center gap-2"
        >
          <CheckmarkCircle16Filled className="w-4 h-4 text-[var(--settings-positive)] shrink-0" />
          <span>
            已完成无损存储迁移：{lastMigrationReport.migratedAssets} 项素材、
            {lastMigrationReport.migratedFolders} 个文件夹、{lastMigrationReport.migratedBoards}{' '}
            块情绪板已迁移至 {lastMigrationReport.targetLocation}。
          </span>
        </div>
      )}

      <GoogleOAuthSetupModal
        open={showOAuthModal}
        onClose={() => setShowOAuthModal(false)}
        autoSignInAfterSave
      />
      <WebDAVEditorModal
        open={showWebDAVModal}
        onClose={() => setShowWebDAVModal(false)}
        initialConfig={draft}
      />
      <StorageLocationWizardModal open={showWizard} onClose={() => setShowWizard(false)} />
    </div>
  );
};
