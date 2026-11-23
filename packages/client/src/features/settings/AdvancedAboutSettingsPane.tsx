import React, { useState } from 'react';
import { KeyRound, RefreshCw } from 'lucide-react';
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

export const AdvancedAboutSettingsPane: React.FC = () => {
  const hasGoogleOAuthConfig = useSyncAIStore((s) => s.hasGoogleOAuthConfig);
  const isRebuildingVisualIndex = useSyncAIStore((s) => s.isRebuildingVisualIndex);
  const rebuildVisualIndexProgress = useSyncAIStore((s) => s.rebuildVisualIndexProgress);
  const rebuildLocalVisualIndex = useSyncAIStore((s) => s.rebuildLocalVisualIndex);
  const pushToast = useCoordinatorStore((s) => s.pushToast);

  const [oauthModalOpen, setOauthModalOpen] = useState(false);

  const handleRebuildIndex = async () => {
    const assetIDs = Object.keys(useLibraryStore.getState().assetsByID);
    if (assetIDs.length === 0) {
      pushToast({ tone: 'info', message: '当前素材库暂无可扫描的素材' });
      return;
    }
    try {
      const processed = await rebuildLocalVisualIndex(assetIDs);
      await useLibraryStore.getState().loadAssets();
      pushToast({
        tone: 'success',
        message: `已完成 ${processed} 项素材的本地视觉与配色索引重建`,
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
              <span>OAuth 客户端凭据</span>
              <SettingsStatusBadge
                text={hasGoogleOAuthConfig ? '已配置' : '未配置'}
                tone={hasGoogleOAuthConfig ? 'positive' : 'neutral'}
              />
            </span>
          }
          subtitle={
            hasGoogleOAuthConfig
              ? '已由服务端加密保存，用于直连个人或团队 Google Drive'
              : '直连 Google Drive 同步时需导入或填写自建 OAuth 凭据'
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
          subtitle="重新分析全部素材的主色调与相似特征，完全本地运行且不消耗云端 AI 额度"
        >
          <SettingsButton
            variant="secondary"
            loading={isRebuildingVisualIndex}
            onClick={() => void handleRebuildIndex()}
          >
            <RefreshCw size={12} className={isRebuildingVisualIndex ? 'animate-spin' : ''} />
            {isRebuildingVisualIndex ? '扫描中…' : '开始扫描'}
          </SettingsButton>
        </SettingsRow>

        {isRebuildingVisualIndex && rebuildVisualIndexProgress && (
          <div className="px-4 pb-3.5 flex flex-col gap-1.5">
            <div className="flex items-center justify-between text-[11px] text-[var(--text-secondary)] tabular-nums">
              <span>正在重建本地视觉与配色索引…</span>
              <span className="font-mono">
                已完成 {rebuildVisualIndexProgress.completed} / {rebuildVisualIndexProgress.total} (
                {progressPct}%)
              </span>
            </div>
            <div className="h-1.5 w-full rounded-full bg-[var(--settings-subtle,var(--bg-subtle))] overflow-hidden">
              <div
                className="h-full bg-[var(--accent)] rounded-full transition-[width] duration-200 ease-[var(--ease-out)]"
                style={{ width: `${progressPct}%` }}
              />
            </div>
          </div>
        )}
      </SettingsSection>

      {/* 3. 关于 Charkle */}
      <SettingsSection title="关于 Charkle">
        <div className="px-4 py-4 flex items-center gap-3.5">
          <CharkleBrandMark size={44} />
          <div className="min-w-0 flex-1 flex flex-col gap-0.5">
            <div className="flex items-baseline gap-2">
              <span className="text-[14.5px] font-semibold text-[var(--text-primary)]">
                Charkle
              </span>
              <span className="text-[11.5px] font-mono text-[var(--text-tertiary)]">v1.0.0</span>
            </div>
            <p className="text-[12px] text-[var(--text-secondary)] leading-relaxed">
              视觉素材库与情绪板工作台 · 离线配色与相似检索 + 多端云同步
            </p>
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
