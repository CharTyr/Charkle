import React, { useState } from 'react';
import { KeyRound, RefreshCw } from 'lucide-react';
import type { UUID } from '@charkle/shared';
import { apiClient } from '../../api/client';
import { CharkleBrandMark } from '../../design-system/CharkleIcon';
import { useCoordinatorStore } from '../../stores/coordinatorStore';
import { useLibraryStore } from '../../stores/libraryStore';
import { useSyncAIStore } from '../../stores/syncAIStore';
import { GoogleOAuthSetupModal } from './GoogleOAuthSetupModal';
import {
  SettingsButton,
  SettingsRow,
  SettingsSection,
  SettingsStatusBadge,
} from './SettingsChrome';

async function fetchAllNonTrashedAssetIDs(): Promise<UUID[]> {
  const pageSize = 1000;
  const collected: UUID[] = [];
  const seen = new Set<UUID>();
  let offset = 0;

  while (true) {
    const res = await apiClient.queryAssets({
      criteria: {
        includeTrashed: false,
        onlyTrashed: false,
      },
      limit: pageSize,
      offset,
    });
    for (const asset of res.assets) {
      if (!asset.isTrashed && !seen.has(asset.id)) {
        seen.add(asset.id);
        collected.push(asset.id);
      }
    }
    offset += res.assets.length;
    if (res.assets.length < pageSize || offset >= res.total) {
      break;
    }
  }

  return collected;
}

export const AdvancedAboutSettingsPane: React.FC = () => {
  const hasGoogleOAuthConfig = useSyncAIStore((s) => s.hasGoogleOAuthConfig);
  const isRebuildingVisualIndex = useSyncAIStore((s) => s.isRebuildingVisualIndex);
  const rebuildVisualIndexProgress = useSyncAIStore((s) => s.rebuildVisualIndexProgress);
  const rebuildLocalVisualIndex = useSyncAIStore((s) => s.rebuildLocalVisualIndex);
  const pushToast = useCoordinatorStore((s) => s.pushToast);

  const [oauthModalOpen, setOauthModalOpen] = useState(false);
  const [fetchingLibraryIDs, setFetchingLibraryIDs] = useState(false);

  const busyRebuilding = fetchingLibraryIDs || isRebuildingVisualIndex;

  const handleRebuildIndex = async () => {
    if (busyRebuilding) return;
    setFetchingLibraryIDs(true);
    let assetIDs: UUID[] = [];
    try {
      assetIDs = await fetchAllNonTrashedAssetIDs();
    } catch (err) {
      setFetchingLibraryIDs(false);
      pushToast({
        tone: 'error',
        message: err instanceof Error ? err.message : '读取素材列表失败',
      });
      return;
    } finally {
      setFetchingLibraryIDs(false);
    }

    if (assetIDs.length === 0) {
      pushToast({ tone: 'info', message: '当前素材库暂无可扫描的素材' });
      return;
    }

    try {
      const processed = await rebuildLocalVisualIndex(assetIDs);
      await useLibraryStore.getState().loadAssets();
      pushToast({
        tone: 'success',
        message: `已完成 ${processed} 项素材的配色与相似图索引重建`,
      });
    } catch (err) {
      pushToast({
        tone: 'error',
        message: err instanceof Error ? err.message : '重建本地视觉索引失败',
      });
    }
  };

  const progressPct =
    rebuildVisualIndexProgress && rebuildVisualIndexProgress.total > 0
      ? Math.round(
          (rebuildVisualIndexProgress.completed / rebuildVisualIndexProgress.total) * 100,
        )
      : 0;

  return (
    <div className="flex flex-col gap-[22px]">
      {/* 1. Google Drive 凭据 */}
      <SettingsSection title="Google Drive 凭据">
        <SettingsRow
          title={
            <span className="inline-flex items-center gap-2">
              <span>登录凭据</span>
              <SettingsStatusBadge
                text={hasGoogleOAuthConfig ? '已配置' : '未配置'}
                tone={hasGoogleOAuthConfig ? 'positive' : 'neutral'}
              />
            </span>
          }
        >
          <SettingsButton variant="secondary" onClick={() => setOauthModalOpen(true)}>
            <KeyRound size={12} />
            {hasGoogleOAuthConfig ? '管理凭据…' : '配置凭据…'}
          </SettingsButton>
        </SettingsRow>
      </SettingsSection>

      {/* 2. 索引与数据维护 */}
      <SettingsSection title="索引与数据维护">
        <SettingsRow
          title="重建本地视觉与配色索引"
          subtitle="重新计算配色与相似图索引"
        >
          <SettingsButton
            variant="secondary"
            loading={busyRebuilding}
            onClick={() => void handleRebuildIndex()}
          >
            <RefreshCw size={12} className={busyRebuilding ? 'animate-spin' : ''} />
            {busyRebuilding ? '扫描中…' : '开始扫描'}
          </SettingsButton>
        </SettingsRow>

        {isRebuildingVisualIndex && rebuildVisualIndexProgress && (
          <div className="px-4 pb-3.5 flex flex-col gap-1.5">
            <div className="flex items-center justify-between text-[11px] text-[var(--text-secondary)] tabular-nums">
              <span>正在重建配色与相似图索引…</span>
              <span className="font-mono">
                已完成 {rebuildVisualIndexProgress.completed} / {rebuildVisualIndexProgress.total} (
                {progressPct}%)
              </span>
            </div>
            <div className="h-1.5 w-full rounded-full bg-[var(--settings-subtle,var(--bg-subtle))] overflow-hidden">
              <div
                className="h-full w-full bg-[var(--accent)] rounded-full origin-left transition-transform duration-200 ease-[var(--ease-out)]"
                style={{ transform: `scaleX(${Math.max(0, Math.min(1, progressPct / 100))})` }}
              />
            </div>
          </div>
        )}
      </SettingsSection>

      {/* 3. 关于 Charkle */}
      <SettingsSection title="关于 Charkle">
        <div className="px-4 py-4 flex items-center gap-3.5">
          <CharkleBrandMark size={44} />
          <div className="min-w-0 flex-1 flex items-baseline gap-2">
            <span className="text-[14.5px] font-semibold text-[var(--text-primary)]">
              Charkle
            </span>
            <span className="text-[11.5px] font-mono text-[var(--text-tertiary)]">v1.0.0</span>
          </div>
        </div>
      </SettingsSection>

      <GoogleOAuthSetupModal
        open={oauthModalOpen}
        onClose={() => setOauthModalOpen(false)}
        autoSignInAfterSave={false}
      />
    </div>
  );
};
