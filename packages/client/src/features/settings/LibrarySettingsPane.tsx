import React, { useEffect, useState } from 'react';
import {
  AlertTriangle,
  ArrowRight,
  CheckCircle2,
  HardDrive,
  RefreshCw,
  Trash2,
} from 'lucide-react';
import {
  activeStorageLocationSummary,
  createDefaultDriveSyncConfig,
} from '@charkle/shared';
import type {
  DriveSyncConfig,
  DriveTransportMode,
  RuntimeMode,
  StorageMigrationReport,
} from '@charkle/shared';
import { ModalShell } from '../../design-system/ModalShell';
import { useCoordinatorStore } from '../../stores/coordinatorStore';
import { useSyncAIStore } from '../../stores/syncAIStore';
import {
  InlineGuideDisclosure,
  SettingsButton,
  SettingsCardDivider,
  SettingsGuideStep,
  SettingsInput,
  SettingsRow,
  SettingsSection,
  SettingsSegmented,
} from './SettingsChrome';
import { formatBytes } from './shortcuts';

type TargetStorageOption = 'directAPIWithGDirect' | 'webDAV' | 'localOnly';
type TransferActionMode = 'migrate' | 'switchOnly';

const TRANSFER_ACTION_OPTIONS: ReadonlyArray<{ id: TransferActionMode; label: string }> = [
  { id: 'migrate', label: '完整无损迁移（推荐）' },
  { id: 'switchOnly', label: '仅切换指向位置' },
];

function storageHeadline(mode: DriveTransportMode, isBuiltInCloud: boolean): string {
  if (mode === 'localOnly') return isBuiltInCloud ? '内置云存储' : '本地文件夹';
  if (mode === 'webDAV') return 'WebDAV 云盘';
  return 'Google Drive 云端直连';
}

function normalizeTargetOption(mode: DriveTransportMode): TargetStorageOption {
  if (mode === 'localOnly') return 'localOnly';
  if (mode === 'webDAV') return 'webDAV';
  return 'directAPIWithGDirect';
}

export const LibrarySettingsPane: React.FC = () => {
  const runtimeMode = useSyncAIStore((s) => s.runtimeMode);
  const runtimeFeatures = useSyncAIStore((s) => s.runtimeFeatures);
  const syncConfig = useSyncAIStore((s) => s.syncConfig);
  const activeStorageSummary = useSyncAIStore((s) => s.activeStorageSummary);
  const isSyncingNow = useSyncAIStore((s) => s.isSyncingNow);
  const cacheStats = useSyncAIStore((s) => s.cacheStats);

  const isBuiltInCloud = runtimeMode === 'cloudflare' || !runtimeFeatures.localFolder;

  const loadSyncConfig = useSyncAIStore((s) => s.loadSyncConfig);
  const saveSyncConfig = useSyncAIStore((s) => s.saveSyncConfig);
  const migrateStorage = useSyncAIStore((s) => s.migrateStorage);
  const syncNow = useSyncAIStore((s) => s.syncNow);
  const loadCacheStats = useSyncAIStore((s) => s.loadCacheStats);
  const updateCacheBudget = useSyncAIStore((s) => s.updateCacheBudget);
  const evictCacheNow = useSyncAIStore((s) => s.evictCacheNow);

  const setSettingsTab = useCoordinatorStore((s) => s.setSettingsTab);
  const pushToast = useCoordinatorStore((s) => s.pushToast);

  const [wizardOpen, setWizardOpen] = useState(false);
  const [budgetGB, setBudgetGB] = useState(10);
  const [evicting, setEvicting] = useState(false);

  useEffect(() => {
    void loadSyncConfig();
    void loadCacheStats();
  }, [loadSyncConfig, loadCacheStats]);

  useEffect(() => {
    const gb = Math.round(cacheStats.budgetBytes / (1024 * 1024 * 1024));
    if (gb >= 2 && gb <= 100) setBudgetGB(gb);
  }, [cacheStats.budgetBytes]);

  const currentConfig = syncConfig ?? createDefaultDriveSyncConfig();
  const isCloudMode = currentConfig.mode !== 'localOnly';

  const totalUsed =
    cacheStats.thumbnailBytes + cacheStats.originalCacheBytes + cacheStats.pinnedOfflineBytes;
  const denom = Math.max(cacheStats.budgetBytes, totalUsed, 1);
  const thumbPct = Math.min(100, (cacheStats.thumbnailBytes / denom) * 100);
  const origPct = Math.min(100 - thumbPct, (cacheStats.originalCacheBytes / denom) * 100);
  const pinnedPct = Math.min(
    100 - thumbPct - origPct,
    (cacheStats.pinnedOfflineBytes / denom) * 100,
  );

  const handleScanLocal = async () => {
    try {
      const report = await syncNow();
      pushToast({
        tone: 'success',
        message:
          report.discoveredRemoteAssets > 0
            ? `本地扫描完成，新发现 ${report.discoveredRemoteAssets} 项素材`
            : '本地目录检查完成，素材索引已是最新',
      });
    } catch (err) {
      pushToast({
        tone: 'error',
        message: err instanceof Error ? err.message : '扫描本地目录失败',
      });
    }
  };

  const handleCommitBudget = async (nextGB: number) => {
    try {
      await updateCacheBudget(nextGB * 1024 * 1024 * 1024);
      pushToast({ tone: 'success', message: `缓存空间上限已更新为 ${nextGB} GB` });
    } catch (err) {
      pushToast({
        tone: 'error',
        message: err instanceof Error ? err.message : '更新缓存空间上限失败',
      });
    }
  };

  const handleEvictCache = async () => {
    setEvicting(true);
    try {
      await evictCacheNow();
      pushToast({ tone: 'success', message: '已清理临时原件缓存（常驻离线素材不受影响）' });
    } catch (err) {
      pushToast({
        tone: 'error',
        message: err instanceof Error ? err.message : '清理临时缓存失败',
      });
    } finally {
      setEvicting(false);
    }
  };

  return (
    <div className="flex flex-col gap-[22px]">
      {/* 当前存储位置 */}
      <SettingsSection title="当前存储位置">
        <SettingsRow
          title={storageHeadline(currentConfig.mode, isBuiltInCloud)}
          subtitle={
            !isCloudMode && isBuiltInCloud ? (
              '素材与索引直接保存在当前云端实例中，也可随时开启 Google Drive 或 WebDAV 同步到桌面端。'
            ) : (
              <span className="font-mono text-[11px] break-all">{activeStorageSummary}</span>
            )
          }
        >
          {isCloudMode && (
            <SettingsButton variant="secondary" onClick={() => setSettingsTab('sync')}>
              同步设置
            </SettingsButton>
          )}
          <SettingsButton variant="primary" onClick={() => setWizardOpen(true)}>
            更改或转移…
          </SettingsButton>
        </SettingsRow>

        {!isCloudMode && !isBuiltInCloud && (
          <>
            <SettingsCardDivider />
            <SettingsRow
              title="本地目录同步检查"
              subtitle="扫描当前素材库目录中手动新增的文件并更新画廊索引"
            >
              <SettingsButton
                variant="secondary"
                loading={isSyncingNow}
                onClick={() => void handleScanLocal()}
              >
                <RefreshCw size={12} className={isSyncingNow ? 'animate-spin' : ''} />
                立即扫描
              </SettingsButton>
            </SettingsRow>
          </>
        )}

        <InlineGuideDisclosure title="切换存储方式会丢失素材吗？怎么安全搬家">
          <SettingsGuideStep
            number={1}
            title="完整无损迁移（推荐）"
            detail="会自动拉取尚未缓存的云端原件，将全部原文件、文件夹结构、标签、色板与情绪板完整复制到新位置，原位置的旧数据绝不会被删除。"
          />
          <SettingsGuideStep
            number={2}
            title="仅切换指向位置"
            detail="只修改当前绑定的存储目录或云盘路径，不搬运现有文件，适合切换到另一台设备已经同步好的素材库。"
          />
          <SettingsGuideStep
            number={3}
            title="多端兼容格式"
            detail="所有存储方式均使用统一的 /.charkle/ 目录结构，可在桌面端与网页版之间无缝双向同步。"
          />
        </InlineGuideDisclosure>
      </SettingsSection>

      {/* 缓存空间 */}
      <SettingsSection
        title="缓存空间"
        caption={`${formatBytes(totalUsed)} / ${formatBytes(cacheStats.budgetBytes)}`}
      >
        <div className="px-4 py-3.5 flex flex-col gap-3">
          {/* 3-segment visual bar */}
          <div className="h-2.5 w-full rounded-full bg-[var(--settings-subtle,var(--bg-subtle))] overflow-hidden flex">
            <div
              style={{ width: `${thumbPct}%`, backgroundColor: '#4E7D96' }}
              className="h-full transition-[width] duration-300 ease-[var(--ease-out)]"
              title={`画廊预览图：${formatBytes(cacheStats.thumbnailBytes)}`}
            />
            <div
              style={{ width: `${origPct}%`, backgroundColor: '#D4A373' }}
              className="h-full transition-[width] duration-300 ease-[var(--ease-out)]"
              title={`临时原件：${formatBytes(cacheStats.originalCacheBytes)}`}
            />
            <div
              style={{ width: `${pinnedPct}%`, backgroundColor: '#6B8E76' }}
              className="h-full transition-[width] duration-300 ease-[var(--ease-out)]"
              title={`常驻离线：${formatBytes(cacheStats.pinnedOfflineBytes)}`}
            />
          </div>

          <div className="grid grid-cols-3 gap-2.5">
            {[
              {
                color: '#4E7D96',
                label: '画廊预览图',
                bytes: cacheStats.thumbnailBytes,
                sub: '加速瀑布流加载',
              },
              {
                color: '#D4A373',
                label: '临时原件',
                bytes: cacheStats.originalCacheBytes,
                sub: `${cacheStats.cachedOriginalCount} 项 · 超限自动释放`,
              },
              {
                color: '#6B8E76',
                label: '常驻离线',
                bytes: cacheStats.pinnedOfflineBytes,
                sub: `${cacheStats.pinnedAssetCount} 项 · 永不自动清理`,
              },
            ].map((seg) => (
              <div
                key={seg.label}
                className="p-2.5 rounded-[9px] bg-[var(--settings-subtle,var(--bg-subtle))] border border-[var(--settings-border,var(--border-hairline))]"
              >
                <div className="flex items-center gap-1.5 text-[11.5px] font-medium text-[var(--text-primary)]">
                  <span
                    className="w-2 h-2 rounded-[3px] shrink-0"
                    style={{ backgroundColor: seg.color }}
                  />
                  {seg.label}
                </div>
                <div className="text-[14px] font-semibold font-mono text-[var(--text-primary)] mt-1 tabular-nums">
                  {formatBytes(seg.bytes)}
                </div>
                <div className="text-[10.5px] text-[var(--text-tertiary)] mt-0.5 truncate">
                  {seg.sub}
                </div>
              </div>
            ))}
          </div>
        </div>

        <SettingsCardDivider />

        {/* 2–100 GB Budget Slider */}
        <div className="px-4 py-3 flex flex-col gap-2">
          <div className="flex items-center justify-between text-[12.5px]">
            <span className="font-medium text-[var(--text-primary)] inline-flex items-center gap-1.5">
              <HardDrive size={13} className="text-[var(--text-secondary)]" />
              {isBuiltInCloud ? '缓存空间上限' : '本地缓存空间上限'}
            </span>
            <span className="font-mono text-[12px] font-semibold text-[var(--text-primary)] tabular-nums">
              {budgetGB} GB
            </span>
          </div>
          <input
            type="range"
            aria-label={isBuiltInCloud ? '缓存空间上限' : '本地缓存空间上限'}
            min={2}
            max={100}
            step={2}
            value={budgetGB}
            onChange={(e) => setBudgetGB(Number(e.target.value))}
            onMouseUp={() => void handleCommitBudget(budgetGB)}
            onTouchEnd={() => void handleCommitBudget(budgetGB)}
            onKeyUp={() => void handleCommitBudget(budgetGB)}
            className="w-full accent-[var(--accent)] cursor-pointer"
          />
          <div className="flex justify-between text-[10.5px] text-[var(--text-tertiary)] font-mono">
            <span>2 GB</span>
            <span>25 GB</span>
            <span>50 GB</span>
            <span>100 GB</span>
          </div>
        </div>

        <SettingsCardDivider />

        <SettingsRow
          title="清理临时原件缓存"
          subtitle="仅清理临时下载的原件副本，已固定「常驻离线」的素材与情绪板不受影响"
        >
          <SettingsButton
            variant="secondary"
            loading={evicting}
            onClick={() => void handleEvictCache()}
          >
            <Trash2 size={12} />
            立即清理
          </SettingsButton>
        </SettingsRow>
      </SettingsSection>

      {/* Unified Location Migration / Switch Wizard */}
      <LocationTransferWizardModal
        open={wizardOpen}
        onClose={() => setWizardOpen(false)}
        currentConfig={currentConfig}
        runtimeMode={runtimeMode}
        isBuiltInCloud={isBuiltInCloud}
        onMigrate={migrateStorage}
        onSwitchOnly={saveSyncConfig}
      />
    </div>
  );
};

// MARK: - Unified Location Migration / Switch Wizard Modal

interface LocationTransferWizardModalProps {
  open: boolean;
  onClose: () => void;
  currentConfig: DriveSyncConfig;
  runtimeMode: RuntimeMode;
  isBuiltInCloud: boolean;
  onMigrate: (
    targetConfig: DriveSyncConfig,
    webDAVPassword?: string | null,
  ) => Promise<StorageMigrationReport>;
  onSwitchOnly: (
    targetConfig: DriveSyncConfig,
    webDAVPassword?: string | null,
  ) => Promise<void>;
}

const LocationTransferWizardModal: React.FC<LocationTransferWizardModalProps> = ({
  open,
  onClose,
  currentConfig,
  runtimeMode,
  isBuiltInCloud,
  onMigrate,
  onSwitchOnly,
}) => {
  const pushToast = useCoordinatorStore((s) => s.pushToast);

  const targetStorageOptions: ReadonlyArray<{ id: TargetStorageOption; label: string }> = [
    { id: 'directAPIWithGDirect', label: 'Google Drive' },
    { id: 'webDAV', label: 'WebDAV 云盘' },
    { id: 'localOnly', label: isBuiltInCloud ? '内置云存储' : '本地文件夹' },
  ];

  const [actionMode, setActionMode] = useState<TransferActionMode>('migrate');
  const [draft, setDraft] = useState<DriveSyncConfig>(currentConfig);
  const [webDAVPassword, setWebDAVPassword] = useState('');
  const [working, setWorking] = useState(false);
  const [report, setReport] = useState<StorageMigrationReport | null>(null);
  const [error, setError] = useState<string | null>(null);

  useEffect(() => {
    if (open) {
      setActionMode('migrate');
      const normalized = createDefaultDriveSyncConfig({
        ...currentConfig,
        mode: normalizeTargetOption(currentConfig.mode),
      });
      setDraft(normalized);
      setWebDAVPassword('');
      setReport(null);
      setError(null);
    }
  }, [open, currentConfig]);

  const activeTarget = normalizeTargetOption(draft.mode);

  const handleExecute = async () => {
    setWorking(true);
    setError(null);
    try {
      if (actionMode === 'migrate') {
        const res = await onMigrate(draft, webDAVPassword || null);
        setReport(res);
        pushToast({
          tone: 'success',
          message: `已完成无损迁移：${res.migratedAssets} 项素材、${res.migratedBoards} 块情绪板`,
        });
      } else {
        await onSwitchOnly(draft, webDAVPassword || null);
        pushToast({ tone: 'success', message: '已切换素材库指向位置' });
        onClose();
      }
    } catch (err) {
      setError(
        err instanceof Error
          ? err.message
          : actionMode === 'migrate'
            ? '素材库无损迁移失败'
            : '切换存储位置失败',
      );
    } finally {
      setWorking(false);
    }
  };

  return (
    <ModalShell
      open={open}
      onClose={() => {
        if (!working) onClose();
      }}
      width="md"
      title="更改或转移素材库位置"
      subtitle={
        isBuiltInCloud
          ? '在内置云存储、Google Drive 与 WebDAV 云盘之间安全切换或无损搬家'
          : '在本地文件夹、Google Drive 与 WebDAV 云盘之间安全切换或无损搬家'
      }
      footer={
        report ? (
          <SettingsButton variant="primary" onClick={onClose}>
            完成
          </SettingsButton>
        ) : (
          <>
            <SettingsButton variant="secondary" disabled={working} onClick={onClose}>
              取消
            </SettingsButton>
            <SettingsButton variant="primary" loading={working} onClick={() => void handleExecute()}>
              {actionMode === 'migrate' ? '开始无损迁移' : '确认切换位置'}
            </SettingsButton>
          </>
        )
      }
    >
      <div className="flex flex-col gap-4">
        {!report && (
          <div className="flex flex-col gap-2">
            <SettingsSegmented
              ariaLabel="操作方式"
              options={TRANSFER_ACTION_OPTIONS}
              value={actionMode}
              onChange={setActionMode}
              className="self-start"
            />
            <p className="text-[11.5px] text-[var(--text-secondary)] leading-relaxed">
              {actionMode === 'migrate'
                ? '完整无损迁移会先拉取尚未缓存的原件，再将全部原文件、目录结构、标签与情绪板复制到新位置，原位置文件不会被删除。'
                : isBuiltInCloud
                  ? '仅切换指向位置不会复制现有文件，适合直接连接到另一个已有的云端素材库目录。'
                  : '仅切换指向位置不会复制现有文件，适合直接连接到另一个已有的本地或云端素材库目录。'}
            </p>
          </div>
        )}

        {/* Source -> Target preview */}
        <div className="rounded-[10px] bg-[var(--settings-subtle,var(--bg-subtle))] border border-[var(--settings-border,var(--border-hairline))] p-3 flex items-center justify-between gap-3 text-[12px]">
          <div className="min-w-0 flex-1">
            <div className="text-[10.5px] text-[var(--text-tertiary)]">当前位置</div>
            <div className="font-medium text-[var(--text-primary)] truncate mt-0.5">
              {activeStorageLocationSummary(currentConfig, runtimeMode)}
            </div>
          </div>
          <ArrowRight size={15} className="text-[var(--text-tertiary)] shrink-0" />
          <div className="min-w-0 flex-1 text-right">
            <div className="text-[10.5px] text-[var(--text-tertiary)]">目标位置</div>
            <div className="font-medium text-[var(--accent)] truncate mt-0.5">
              {activeStorageLocationSummary(draft, runtimeMode)}
            </div>
          </div>
        </div>

        {error && (
          <div className="p-3 rounded-[9px] bg-[var(--danger-soft)] text-[var(--settings-destructive,var(--danger))] text-[12px] flex items-center gap-2">
            <AlertTriangle size={14} className="shrink-0" />
            <span>{error}</span>
          </div>
        )}

        {report ? (
          <div className="rounded-[10px] bg-[var(--success-soft)] border border-[var(--settings-positive,var(--success))]/25 p-4 flex flex-col gap-3">
            <div className="flex items-center gap-2 text-[13px] font-semibold text-[var(--settings-positive,var(--success))]">
              <CheckCircle2 size={15} />
              素材库无损迁移完成（耗时 {report.durationSeconds.toFixed(1)}s）
            </div>
            <div className="grid grid-cols-4 gap-2 text-center">
              {[
                { label: '迁移素材', value: report.migratedAssets },
                { label: '拉取原图', value: report.downloadedOriginals },
                { label: '文件夹', value: report.migratedFolders },
                { label: '情绪板', value: report.migratedBoards },
              ].map((item) => (
                <div
                  key={item.label}
                  className="rounded-[8px] bg-[var(--settings-card,var(--bg-elevated))] py-2 px-1 border border-[var(--settings-border,var(--border-hairline))]"
                >
                  <div className="text-[15px] font-semibold text-[var(--text-primary)] tabular-nums">
                    {item.value}
                  </div>
                  <div className="text-[10.5px] text-[var(--text-secondary)]">{item.label}</div>
                </div>
              ))}
            </div>
            <div className="text-[11px] text-[var(--text-secondary)] break-all">
              新存储路径：<span className="font-mono">{report.targetLocation}</span>
            </div>
          </div>
        ) : (
          <div className="flex flex-col gap-3.5">
            <div className="flex flex-col gap-1.5">
              <label className="text-[11.5px] font-medium text-[var(--text-secondary)]">
                目标存储方式
              </label>
              <SettingsSegmented
                ariaLabel="目标存储方式"
                options={targetStorageOptions}
                value={activeTarget}
                onChange={(m) => setDraft((d) => ({ ...d, mode: m }))}
                className="w-full grid grid-cols-3"
              />
            </div>

            {activeTarget === 'directAPIWithGDirect' && (
              <div className="flex flex-col gap-2.5">
                <div className="flex flex-col gap-1">
                  <label className="text-[11.5px] font-medium text-[var(--text-secondary)]">
                    Google Drive 根目录名
                  </label>
                  <SettingsInput
                    type="text"
                    value={draft.rootFolderName}
                    onChange={(e) => setDraft((d) => ({ ...d, rootFolderName: e.target.value }))}
                    placeholder="Charkle"
                    className="w-full"
                  />
                </div>
                <div className="flex flex-col gap-1">
                  <label className="text-[11.5px] font-medium text-[var(--text-secondary)]">
                    团队共享文件夹链接或 ID（可选）
                  </label>
                  <SettingsInput
                    type="text"
                    value={draft.sharedFolderURLOrID}
                    onChange={(e) =>
                      setDraft((d) => ({ ...d, sharedFolderURLOrID: e.target.value }))
                    }
                    placeholder="留空则使用我的云端硬盘根目录"
                    className="w-full"
                  />
                </div>
              </div>
            )}

            {activeTarget === 'webDAV' && (
              <div className="flex flex-col gap-2.5">
                <div className="flex flex-col gap-1">
                  <label className="text-[11.5px] font-medium text-[var(--text-secondary)]">
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
                <div className="grid grid-cols-2 gap-2.5">
                  <div className="flex flex-col gap-1">
                    <label className="text-[11.5px] font-medium text-[var(--text-secondary)]">
                      用户名
                    </label>
                    <SettingsInput
                      type="text"
                      value={draft.webDAVUsername}
                      onChange={(e) => setDraft((d) => ({ ...d, webDAVUsername: e.target.value }))}
                      className="w-full"
                    />
                  </div>
                  <div className="flex flex-col gap-1">
                    <label className="text-[11.5px] font-medium text-[var(--text-secondary)]">
                      密码 / 应用专用密码
                    </label>
                    <SettingsInput
                      type="password"
                      value={webDAVPassword}
                      onChange={(e) => setWebDAVPassword(e.target.value)}
                      placeholder="留空则沿用已保存密码"
                      className="w-full"
                    />
                  </div>
                </div>
                <div className="flex flex-col gap-1">
                  <label className="text-[11.5px] font-medium text-[var(--text-secondary)]">
                    远程目录路径
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
            )}

            {activeTarget === 'localOnly' &&
              (isBuiltInCloud ? (
                <div className="rounded-[9px] bg-[var(--settings-subtle,var(--bg-subtle))] border border-[var(--settings-border,var(--border-hairline))] p-3 text-[12px] text-[var(--text-secondary)] leading-relaxed">
                  素材与索引直接保存在当前云端实例中，也可随时开启 Google Drive 或 WebDAV 同步到桌面端。
                </div>
              ) : (
                <div className="flex flex-col gap-1">
                  <label className="text-[11.5px] font-medium text-[var(--text-secondary)]">
                    本地素材库目录路径（服务端文件系统路径）
                  </label>
                  <SettingsInput
                    type="text"
                    value={draft.localLibraryPath}
                    onChange={(e) => setDraft((d) => ({ ...d, localLibraryPath: e.target.value }))}
                    placeholder=".charkle-data/library"
                    className="w-full font-mono"
                  />
                </div>
              ))}
          </div>
        )}
      </div>
    </ModalShell>
  );
};
