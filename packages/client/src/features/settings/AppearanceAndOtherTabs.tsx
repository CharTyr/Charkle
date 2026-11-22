import React, { useEffect, useState } from 'react';
import {
  Check,
  Copy,
  HardDrive,
  Laptop,
  Moon,
  ShieldAlert,
  Sparkles,
  Sun,
  Terminal,
  Trash2,
} from 'lucide-react';
import {
  EXTERNAL_AGENT_ACCESS_LEVELS,
  externalAgentAccessLevelSummary,
  externalAgentAccessLevelTitle,
} from '@charkle/shared';
import type { ExternalAgentConfig } from '@charkle/shared';
import { Button } from '../../design-system/Button';
import { CharkleBrandMark, CharkleIcon } from '../../design-system/CharkleIcon';
import type { ThemeMode } from '../../design-system/theme';
import { useCoordinatorStore } from '../../stores/coordinatorStore';
import { useLibraryStore } from '../../stores/libraryStore';
import { useSyncAIStore } from '../../stores/syncAIStore';
import {
  SettingsCard,
  SettingsDivider,
  SettingsHeader,
  SettingsRow,
  SettingsSwitch,
} from './SettingsPrimitives';
import {
  KEYBOARD_SHORTCUTS,
  MCP_TOOL_INVENTORY,
  buildHttpMcpConfigJson,
  buildStdioMcpConfigJson,
  formatBytes,
} from './shortcuts';

// MARK: - Tab 4: 外观与图标 (Appearance)

const DUOTONE_SHOWCASE = [
  'library',
  'inbox',
  'moodboard',
  'sparkle-board',
  'folder',
  'smart-folder',
  'palette',
  'connector',
  'ink-pen',
  'drive-sync',
  'notch',
  'export',
] as const;

const LAYERED_SHOWCASE = [
  { name: 'library', label: '素材库' },
  { name: 'inbox', label: '收件箱' },
  { name: 'moodboard', label: '情绪板' },
  { name: 'sparkle-board', label: 'AI 策展' },
  { name: 'drive', label: '云盘同步' },
] as const;

export const AppearanceTab: React.FC = () => {
  const themeMode = useCoordinatorStore((s) => s.themeMode);
  const setThemeMode = useCoordinatorStore((s) => s.setThemeMode);
  const brandIconVariant = useCoordinatorStore((s) => s.brandIconVariant);
  const setBrandIconVariant = useCoordinatorStore((s) => s.setBrandIconVariant);

  const [reduceMotion, setReduceMotion] = useState(false);
  const [reduceTransparency, setReduceTransparency] = useState(false);

  useEffect(() => {
    if (typeof window === 'undefined' || !window.matchMedia) return;
    const mqMotion = window.matchMedia('(prefers-reduced-motion: reduce)');
    const mqTrans = window.matchMedia('(prefers-reduced-transparency: reduce)');
    const sync = () => {
      setReduceMotion(mqMotion.matches);
      setReduceTransparency(mqTrans.matches);
    };
    sync();
    mqMotion.addEventListener('change', sync);
    mqTrans.addEventListener('change', sync);
    return () => {
      mqMotion.removeEventListener('change', sync);
      mqTrans.removeEventListener('change', sync);
    };
  }, []);

  const themeOptions: ReadonlyArray<{
    id: ThemeMode;
    label: string;
    desc: string;
    icon: React.ReactNode;
    previewBg: string;
    previewCard: string;
  }> = [
    {
      id: 'light',
      label: '浅色画廊',
      desc: '#F6F6F5 中性温润画布',
      icon: <Sun size={15} />,
      previewBg: '#F6F6F5',
      previewCard: '#FFFFFF',
    },
    {
      id: 'dark',
      label: '深色暗房',
      desc: '#141517 沉静低对比底色',
      icon: <Moon size={15} />,
      previewBg: '#141517',
      previewCard: '#1E2025',
    },
    {
      id: 'system',
      label: '跟随系统',
      desc: '自动同步操作系统外观',
      icon: <Laptop size={15} />,
      previewBg: 'linear-gradient(135deg, #F6F6F5 50%, #141517 50%)',
      previewCard: '#FFFFFF',
    },
  ];

  return (
    <div className="flex flex-col gap-5">
      <SettingsHeader
        title="外观与图标"
        subtitle="Gallery-First 低饱和中性表面与克制 Apple Liquid Glass 浮层，确保视觉素材本身始终是画面唯一主角。"
      />

      {/* Light / Dark / System Mode Cards */}
      <SettingsCard title="主题模式">
        <div className="grid grid-cols-3 gap-3">
          {themeOptions.map((opt) => {
            const active = themeMode === opt.id;
            return (
              <button
                key={opt.id}
                type="button"
                onClick={() => setThemeMode(opt.id)}
                className={[
                  'charkle-pressable flex flex-col gap-2.5 p-2.5 rounded-[var(--radius-settings-inner)] border text-left cursor-pointer',
                  active
                    ? 'border-[var(--accent)] bg-[var(--accent-soft)]'
                    : 'border-[var(--border-hairline)] bg-[var(--bg-gallery)] hover:border-[var(--border-strong)]',
                ].join(' ')}
              >
                <div
                  className="h-14 w-full rounded-[6px] border border-black/10 p-2 flex items-end justify-between"
                  style={{ background: opt.previewBg }}
                >
                  <span
                    className="w-8 h-5 rounded-[4px] border border-black/10 shadow-xs"
                    style={{ background: opt.previewCard }}
                  />
                  <span
                    className="w-5 h-5 rounded-full inline-flex items-center justify-center"
                    style={{
                      background: active ? 'var(--accent)' : 'rgba(128,128,128,0.22)',
                      color: active ? '#FFFFFF' : '#71717A',
                    }}
                  >
                    {opt.icon}
                  </span>
                </div>
                <div>
                  <div className="text-[12.5px] font-semibold text-[var(--text-primary)]">
                    {opt.label}
                  </div>
                  <div className="text-[10.5px] text-[var(--text-secondary)]">{opt.desc}</div>
                </div>
              </button>
            );
          })}
        </div>
      </SettingsCard>

      {/* Brand Icon & Kubai Duotone/Layered Showcase */}
      <SettingsCard title="品牌图标与 Kubai 图标体系">
        <SettingsRow
          title="标签页与品牌图标风格"
          subtitle="可跟随当前明暗主题自动切换，或固定使用浅色 / 深色 Charkle 图标"
        >
          <div className="inline-flex p-0.5 rounded-[var(--radius-settings-inner)] bg-[var(--bg-subtle)] border border-[var(--border-hairline)]">
            {(
              [
                { id: 'auto', label: '跟随主题' },
                { id: 'light', label: '浅色款' },
                { id: 'dark', label: '深色款' },
              ] as const
            ).map((opt) => (
              <button
                key={opt.id}
                type="button"
                onClick={() => setBrandIconVariant(opt.id)}
                className={[
                  'px-2.5 py-1 rounded-[6px] text-[11.5px] font-medium cursor-pointer',
                  brandIconVariant === opt.id
                    ? 'bg-[var(--bg-elevated)] text-[var(--text-primary)] shadow-xs'
                    : 'text-[var(--text-secondary)]',
                ].join(' ')}
              >
                {opt.label}
              </button>
            ))}
          </div>
        </SettingsRow>

        <div className="grid grid-cols-2 gap-3 pt-1">
          <div className="p-3 rounded-[var(--radius-settings-inner)] bg-[#F6F6F5] border border-black/8 flex items-center gap-3">
            <CharkleBrandMark size={40} variant="light" />
            <div>
              <div className="text-[12.5px] font-semibold text-[#18191C]">Charkle Light</div>
              <div className="text-[11px] text-[#5C6069]">浅色画廊标牌</div>
            </div>
          </div>
          <div className="p-3 rounded-[var(--radius-settings-inner)] bg-[#141517] border border-white/10 flex items-center gap-3">
            <CharkleBrandMark size={40} variant="dark" />
            <div>
              <div className="text-[12.5px] font-semibold text-[#F2F3F5]">Charkle Dark</div>
              <div className="text-[11px] text-[#A1A6B0]">暗房工作室标牌</div>
            </div>
          </div>
        </div>

        <SettingsDivider />

        {/* Duotone & Layered Showcase */}
        <div className="flex flex-col gap-3">
          <div>
            <div className="text-[11.5px] font-medium text-[var(--text-secondary)] mb-2">
              Kubai 16-Grid 双色面性功能图标（支持文件夹自定义主色实时推导）
            </div>
            <div className="flex flex-wrap items-center gap-2">
              {DUOTONE_SHOWCASE.map((name) => (
                <span
                  key={name}
                  title={name}
                  className="w-8 h-8 rounded-[8px] bg-[var(--bg-gallery)] border border-[var(--border-hairline)] inline-flex items-center justify-center"
                >
                  <CharkleIcon name={name} style="duotone" size={18} />
                </span>
              ))}
            </div>
          </div>

          <div>
            <div className="text-[11.5px] font-medium text-[var(--text-secondary)] mb-2">
              分层立体主图标 (Layered)
            </div>
            <div className="grid grid-cols-5 gap-2">
              {LAYERED_SHOWCASE.map((item) => (
                <div
                  key={item.name}
                  className="p-2.5 rounded-[var(--radius-settings-inner)] bg-[var(--bg-gallery)] border border-[var(--border-hairline)] flex flex-col items-center gap-1.5"
                >
                  <CharkleIcon name={item.name} style="layered" size={28} />
                  <span className="text-[10.5px] text-[var(--text-secondary)]">{item.label}</span>
                </div>
              ))}
            </div>
          </div>
        </div>
      </SettingsCard>

      {/* Accessibility Status Indicators */}
      <SettingsCard title="辅助功能与动效适配状态">
        <div className="grid grid-cols-1 sm:grid-cols-2 gap-3 text-[12px]">
          <div className="p-3 rounded-[var(--radius-settings-inner)] bg-[var(--bg-gallery)] border border-[var(--border-hairline)] flex items-center justify-between">
            <div>
              <div className="font-medium text-[var(--text-primary)]">减弱动态效果</div>
              <div className="text-[11px] text-[var(--text-tertiary)]">
                prefers-reduced-motion
              </div>
            </div>
            <span
              className={[
                'px-2 py-0.5 rounded-full text-[11px] font-medium',
                reduceMotion
                  ? 'bg-[var(--accent-soft)] text-[var(--accent)]'
                  : 'bg-[var(--bg-subtle)] text-[var(--text-secondary)]',
              ].join(' ')}
            >
              {reduceMotion ? '已启用（150ms 淡入）' : '标准物理曲线'}
            </span>
          </div>

          <div className="p-3 rounded-[var(--radius-settings-inner)] bg-[var(--bg-gallery)] border border-[var(--border-hairline)] flex items-center justify-between">
            <div>
              <div className="font-medium text-[var(--text-primary)]">降低透明度</div>
              <div className="text-[11px] text-[var(--text-tertiary)]">
                prefers-reduced-transparency
              </div>
            </div>
            <span
              className={[
                'px-2 py-0.5 rounded-full text-[11px] font-medium',
                reduceTransparency
                  ? 'bg-[var(--accent-soft)] text-[var(--accent)]'
                  : 'bg-[var(--bg-subtle)] text-[var(--text-secondary)]',
              ].join(' ')}
            >
              {reduceTransparency ? '高对比实色表面' : '克制 Liquid Glass'}
            </span>
          </div>
        </div>
      </SettingsCard>
    </div>
  );
};

// MARK: - Tab 5: 外部 Agent 与 MCP (External Agent)

export const ExternalAgentTab: React.FC = () => {
  const config = useSyncAIStore((s) => s.externalAgentConfig);
  const loadConfig = useSyncAIStore((s) => s.loadExternalAgentConfig);
  const saveConfig = useSyncAIStore((s) => s.saveExternalAgentConfig);
  const setSettingsTab = useCoordinatorStore((s) => s.setSettingsTab);
  const pushToast = useCoordinatorStore((s) => s.pushToast);

  const [copiedKey, setCopiedKey] = useState<'http' | 'stdio' | null>(null);

  useEffect(() => {
    void loadConfig();
  }, [loadConfig]);

  const origin = typeof window !== 'undefined' ? window.location.origin : 'http://127.0.0.1:3417';
  const httpConfigJson = buildHttpMcpConfigJson(origin);
  const stdioConfigJson = buildStdioMcpConfigJson();

  const updatePolicy = async (next: ExternalAgentConfig) => {
    try {
      await saveConfig(next);
      pushToast({ tone: 'success', message: '外部 Agent 与 MCP 策略已更新' });
    } catch (err) {
      pushToast({
        tone: 'error',
        message: err instanceof Error ? err.message : '更新 MCP 策略失败',
      });
    }
  };

  const handleCopy = (key: 'http' | 'stdio', text: string) => {
    void navigator.clipboard?.writeText(text);
    setCopiedKey(key);
    pushToast({ tone: 'success', message: '已复制 MCP 配置 JSON' });
    window.setTimeout(() => setCopiedKey(null), 1600);
  };

  return (
    <div className="flex flex-col gap-5">
      <SettingsHeader
        title="外部 Agent 与 MCP"
        subtitle="让 Claude Desktop、Cursor、Antigravity 等外部 AI 助手通过标准 JSON-RPC 2.0 MCP 协议直接检索素材、审片并编排情绪板。"
      />

      {/* Policy Card */}
      <SettingsCard>
        <SettingsRow
          title="启用外部 MCP 服务"
          subtitle="同时控制 HTTP 端点 POST /api/v1/mcp 与本机 stdio CLI 入口"
        >
          <SettingsSwitch
            ariaLabel="启用外部 MCP 服务"
            checked={config.enabled}
            onChange={(enabled) => void updatePolicy({ ...config, enabled })}
          />
        </SettingsRow>

        <SettingsDivider />

        <div className="flex flex-col gap-2">
          <div className="text-[12.5px] font-medium text-[var(--text-primary)]">权限级别</div>
          <div className="grid grid-cols-1 sm:grid-cols-2 gap-2.5">
            {EXTERNAL_AGENT_ACCESS_LEVELS.map((level) => {
              const active = config.accessLevel === level;
              return (
                <button
                  key={level}
                  type="button"
                  disabled={!config.enabled}
                  onClick={() => void updatePolicy({ ...config, accessLevel: level })}
                  className={[
                    'charkle-pressable p-3 rounded-[var(--radius-settings-inner)] border text-left cursor-pointer disabled:opacity-45',
                    active
                      ? 'bg-[var(--accent-soft)] border-[var(--accent-ring)]'
                      : 'bg-[var(--bg-gallery)] border-[var(--border-hairline)] hover:border-[var(--border-strong)]',
                  ].join(' ')}
                >
                  <div className="text-[12.5px] font-semibold text-[var(--text-primary)]">
                    {externalAgentAccessLevelTitle(level)}
                  </div>
                  <p className="text-[11px] text-[var(--text-secondary)] mt-1 leading-relaxed">
                    {externalAgentAccessLevelSummary(level)}
                  </p>
                </button>
              );
            })}
          </div>
        </div>

        {/* Safety Callout */}
        <div className="p-3 rounded-[var(--radius-settings-inner)] bg-[var(--warning-soft)] border border-[var(--warning)]/25 flex items-start gap-2.5 text-[11.5px] text-[var(--text-primary)]">
          <ShieldAlert size={15} className="text-[var(--warning)] shrink-0 mt-0.5" />
          <span>
            <strong>安全护栏：</strong>
            外部 Agent <strong>永远无法永久删除素材</strong>。即使开启写入整理权限，
            <code className="font-mono mx-1">trash_assets</code> 也仅执行软删除移入回收站，且不会修改锁定情绪板节点。
          </span>
        </div>
      </SettingsCard>

      {/* HTTP MCP Config JSON */}
      <SettingsCard
        title="HTTP MCP 配置（适用于远程访问 / Claude Desktop / Cursor / Antigravity）"
        badge={
          <div className="flex items-center gap-1.5">
            <Button
              variant="ghost"
              size="xs"
              onClick={() => setSettingsTab('accountSecurity')}
            >
              前往签发 Bearer 令牌
            </Button>
            <Button
              variant="secondary"
              size="xs"
              onClick={() => handleCopy('http', httpConfigJson)}
            >
              {copiedKey === 'http' ? <Check size={12} /> : <Copy size={12} />}
              {copiedKey === 'http' ? '已复制' : '复制 JSON'}
            </Button>
          </div>
        }
      >
        <div className="text-[11.5px] text-[var(--text-secondary)]">
          端点地址：<code className="font-mono text-[var(--text-primary)]">{origin}/api/v1/mcp</code>
        </div>
        <pre className="p-3 rounded-[var(--radius-settings-inner)] bg-[var(--bg-gallery)] border border-[var(--border-hairline)] font-mono text-[11px] text-[var(--text-primary)] overflow-x-auto charkle-scroll">
          {httpConfigJson}
        </pre>
      </SettingsCard>

      {/* stdio CLI Config JSON */}
      <SettingsCard
        title="本机 stdio CLI 配置（无需 Token，直连服务端 SQLite）"
        badge={
          <Button
            variant="secondary"
            size="xs"
            onClick={() => handleCopy('stdio', stdioConfigJson)}
          >
            {copiedKey === 'stdio' ? <Check size={12} /> : <Copy size={12} />}
            {copiedKey === 'stdio' ? '已复制' : '复制 JSON'}
          </Button>
        }
      >
        <pre className="p-3 rounded-[var(--radius-settings-inner)] bg-[var(--bg-gallery)] border border-[var(--border-hairline)] font-mono text-[11px] text-[var(--text-primary)] overflow-x-auto charkle-scroll">
          {stdioConfigJson}
        </pre>
      </SettingsCard>

      {/* 14-Tool Inventory Table */}
      <SettingsCard title={`全部 ${MCP_TOOL_INVENTORY.length} 个 MCP 工具清单`}>
        <div className="overflow-x-auto">
          <table className="w-full text-left border-collapse text-[12px]">
            <thead>
              <tr className="border-b border-[var(--border-hairline)] text-[11px] text-[var(--text-tertiary)]">
                <th className="py-1.5 pr-3 font-medium">工具名称</th>
                <th className="py-1.5 pr-3 font-medium">权限</th>
                <th className="py-1.5 font-medium">能力说明</th>
              </tr>
            </thead>
            <tbody className="divide-y divide-[var(--border-hairline)]">
              {MCP_TOOL_INVENTORY.map((tool) => {
                const enabledForTool =
                  config.enabled &&
                  (tool.access === 'read' || config.accessLevel === 'readWriteOrganize');
                return (
                  <tr
                    key={tool.name}
                    className={enabledForTool ? '' : 'opacity-45'}
                  >
                    <td className="py-2 pr-3 font-mono text-[11.5px] text-[var(--text-primary)] whitespace-nowrap">
                      {tool.name}
                    </td>
                    <td className="py-2 pr-3 whitespace-nowrap">
                      <span
                        className={[
                          'px-1.5 py-0.5 rounded-[5px] text-[10px] font-semibold',
                          tool.access === 'read'
                            ? 'bg-[var(--bg-subtle)] text-[var(--text-secondary)]'
                            : 'bg-[var(--accent-soft)] text-[var(--accent)]',
                        ].join(' ')}
                      >
                        {tool.access === 'read' ? '只读' : '整理写入'}
                      </span>
                    </td>
                    <td className="py-2 text-[11.5px] text-[var(--text-secondary)]">
                      {tool.summary}
                    </td>
                  </tr>
                );
              })}
            </tbody>
          </table>
        </div>
      </SettingsCard>
    </div>
  );
};

// MARK: - Tab 6: 缓存空间 (Storage Cache)

export const StorageCacheTab: React.FC = () => {
  const stats = useSyncAIStore((s) => s.cacheStats);
  const loadCacheStats = useSyncAIStore((s) => s.loadCacheStats);
  const updateCacheBudget = useSyncAIStore((s) => s.updateCacheBudget);
  const evictCacheNow = useSyncAIStore((s) => s.evictCacheNow);
  const pushToast = useCoordinatorStore((s) => s.pushToast);

  const [budgetGB, setBudgetGB] = useState(10);
  const [evicting, setEvicting] = useState(false);

  useEffect(() => {
    void loadCacheStats();
  }, [loadCacheStats]);

  useEffect(() => {
    const gb = Math.round(stats.budgetBytes / (1024 * 1024 * 1024));
    if (gb >= 2 && gb <= 100) setBudgetGB(gb);
  }, [stats.budgetBytes]);

  const totalUsed = stats.thumbnailBytes + stats.originalCacheBytes + stats.pinnedOfflineBytes;
  const denom = Math.max(stats.budgetBytes, totalUsed, 1);
  const thumbPct = Math.min(100, (stats.thumbnailBytes / denom) * 100);
  const origPct = Math.min(100 - thumbPct, (stats.originalCacheBytes / denom) * 100);
  const pinnedPct = Math.min(100 - thumbPct - origPct, (stats.pinnedOfflineBytes / denom) * 100);

  const handleCommitBudget = async (nextGB: number) => {
    try {
      await updateCacheBudget(nextGB * 1024 * 1024 * 1024);
      pushToast({ tone: 'success', message: `缓存上限已更新为 ${nextGB} GB` });
    } catch (err) {
      pushToast({
        tone: 'error',
        message: err instanceof Error ? err.message : '更新缓存上限失败',
      });
    }
  };

  const handleEvict = async () => {
    setEvicting(true);
    try {
      await evictCacheNow();
      pushToast({ tone: 'success', message: '已按 LRU 策略清理临时缓存（所有离线保留文件不受影响）' });
    } catch (err) {
      pushToast({
        tone: 'error',
        message: err instanceof Error ? err.message : '清理缓存失败',
      });
    } finally {
      setEvicting(false);
    }
  };

  return (
    <div className="flex flex-col gap-5">
      <SettingsHeader
        title="缓存空间"
        subtitle="智能管理缩略图、按需下载的临时原件与永久离线保留原件占用；超出上限时自动按 LRU 淘汰最久未访问的临时原件。"
      />

      <SettingsCard
        title="空间占用总览"
        badge={
          <span className="text-[12px] font-mono text-[var(--text-secondary)] tabular-nums">
            {formatBytes(totalUsed)} / {formatBytes(stats.budgetBytes)}
          </span>
        }
      >
        {/* 3-Segment Storage Breakdown Bar */}
        <div className="h-3 w-full rounded-full bg-[var(--bg-subtle)] overflow-hidden flex">
          <div
            style={{ width: `${thumbPct}%`, backgroundColor: '#4E7D96' }}
            className="h-full transition-[width] duration-300"
            title={`缩略图：${formatBytes(stats.thumbnailBytes)}`}
          />
          <div
            style={{ width: `${origPct}%`, backgroundColor: '#D4A373' }}
            className="h-full transition-[width] duration-300"
            title={`临时原件缓存：${formatBytes(stats.originalCacheBytes)}`}
          />
          <div
            style={{ width: `${pinnedPct}%`, backgroundColor: '#6B8E76' }}
            className="h-full transition-[width] duration-300"
            title={`离线保留原件：${formatBytes(stats.pinnedOfflineBytes)}`}
          />
        </div>

        <div className="grid grid-cols-1 sm:grid-cols-3 gap-3 pt-1">
          {[
            {
              color: '#4E7D96',
              label: '画廊缩略图',
              bytes: stats.thumbnailBytes,
              sub: '520px / 1400px 轻量预览',
            },
            {
              color: '#D4A373',
              label: '临时原件缓存',
              bytes: stats.originalCacheBytes,
              sub: `${stats.cachedOriginalCount} 项（可 LRU 自动释放）`,
            },
            {
              color: '#6B8E76',
              label: '离线保留原件',
              bytes: stats.pinnedOfflineBytes,
              sub: `${stats.pinnedAssetCount} 项（永不自动清除）`,
            },
          ].map((seg) => (
            <div
              key={seg.label}
              className="p-3 rounded-[var(--radius-settings-inner)] bg-[var(--bg-gallery)] border border-[var(--border-hairline)]"
            >
              <div className="flex items-center gap-2 text-[12px] font-medium text-[var(--text-primary)]">
                <span className="w-2.5 h-2.5 rounded-[3px] shrink-0" style={{ backgroundColor: seg.color }} />
                {seg.label}
              </div>
              <div className="text-[15px] font-semibold font-mono text-[var(--text-primary)] mt-1 tabular-nums">
                {formatBytes(seg.bytes)}
              </div>
              <div className="text-[11px] text-[var(--text-tertiary)] mt-0.5">{seg.sub}</div>
            </div>
          ))}
        </div>

        <SettingsDivider />

        {/* 2–100 GB Budget Slider */}
        <div className="flex flex-col gap-2">
          <div className="flex items-center justify-between text-[12.5px]">
            <span className="font-medium text-[var(--text-primary)] inline-flex items-center gap-2">
              <HardDrive size={14} className="text-[var(--text-secondary)]" />
              本地缓存空间上限
            </span>
            <span className="font-mono font-semibold text-[var(--accent)] tabular-nums">
              {budgetGB} GB
            </span>
          </div>
          <input
            type="range"
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

        <SettingsDivider />

        <SettingsRow
          title="手动执行 LRU 缓存回收"
          subtitle="立即清理超额的临时原件缓存；已勾选「离线保留」的素材与情绪板将受到保护"
        >
          <Button variant="secondary" size="sm" loading={evicting} onClick={() => void handleEvict()}>
            <Trash2 size={13} />
            立即按 LRU 清理
          </Button>
        </SettingsRow>
      </SettingsCard>
    </div>
  );
};

// MARK: - Tab 7: 采集与快捷键 (Capture & Shortcuts)

export const CaptureShortcutsTab: React.FC = () => {
  const shelfEnabled = useCoordinatorStore((s) => s.quickDropShelfEnabled);
  const setShelfEnabled = useCoordinatorStore((s) => s.setQuickDropShelfEnabled);
  const setShelfOpen = useCoordinatorStore((s) => s.setQuickDropShelfOpen);
  const quickDropTarget = useCoordinatorStore((s) => s.quickDropTarget);
  const setQuickDropTarget = useCoordinatorStore((s) => s.setQuickDropTarget);
  const closeSettings = useCoordinatorStore((s) => s.closeSettings);

  const folders = useLibraryStore((s) => s.folders);

  return (
    <div className="flex flex-col gap-5">
      <SettingsHeader
        title="采集与快捷键"
        subtitle="配置顶部快速采集浮窗 (Web Quick Drop Shelf) 行为，以及全部高频键盘快捷键速查表。"
      />

      <SettingsCard title="顶部快速采集浮窗 (Quick Drop Shelf)">
        <SettingsRow
          title="启用顶部快速采集浮窗与全局 ⌘V 粘贴"
          subtitle="拖入文件或 URL 至窗口顶部自动展开，非输入状态下按 ⌘V 自动识别图片、推文、GitHub 与色卡"
        >
          <SettingsSwitch
            ariaLabel="启用顶部快速采集浮窗"
            checked={shelfEnabled}
            onChange={setShelfEnabled}
          />
        </SettingsRow>

        <SettingsDivider />

        <SettingsRow
          title="默认采集去向"
          subtitle="通过拖拽、剪贴板或屏幕截屏采集新素材时的默认保存目标"
        >
          <select
            aria-label="默认采集去向"
            value={quickDropTarget.type}
            onChange={(e) => {
              const val = e.target.value;
              if (val === 'inbox') setQuickDropTarget({ type: 'inbox' });
              else if (val === 'activeMoodboard') setQuickDropTarget({ type: 'activeMoodboard' });
              else if (val === 'folder' && folders[0]) {
                setQuickDropTarget({ type: 'folder', folderID: folders[0].id });
              }
            }}
            className="h-8 px-2.5 rounded-[var(--radius-settings-inner)] bg-[var(--bg-subtle)] border border-[var(--border-hairline)] text-[12px] text-[var(--text-primary)] outline-none cursor-pointer"
          >
            <option value="inbox">收件箱 (Inbox)</option>
            {folders.length > 0 && <option value="folder">指定文件夹</option>}
            <option value="activeMoodboard">当前活跃情绪板</option>
          </select>
        </SettingsRow>

        <SettingsDivider />

        <SettingsRow
          title="立即预览顶部快速采集托盘"
          subtitle="关闭设置并展开顶部深色毛玻璃采集托盘"
        >
          <Button
            variant="secondary"
            size="sm"
            disabled={!shelfEnabled}
            onClick={() => {
              closeSettings();
              setShelfOpen(true);
            }}
          >
            <Sparkles size={13} />
            展开快速采集浮窗
          </Button>
        </SettingsRow>
      </SettingsCard>

      {/* Complete Keyboard Shortcut Cheat Sheet */}
      <SettingsCard title="键盘快捷键速查表">
        <div className="flex flex-col divide-y divide-[var(--border-hairline)]">
          {KEYBOARD_SHORTCUTS.map((sc) => (
            <div
              key={sc.title}
              className="py-2.5 first:pt-0 last:pb-0 flex items-center justify-between gap-4"
            >
              <div className="min-w-0">
                <div className="flex items-center gap-2">
                  <span className="text-[12.5px] font-medium text-[var(--text-primary)]">
                    {sc.title}
                  </span>
                  <span className="px-1.5 py-0.5 rounded-[5px] bg-[var(--bg-subtle)] text-[10px] text-[var(--text-tertiary)]">
                    {sc.scope}
                  </span>
                </div>
                <div className="text-[11px] text-[var(--text-secondary)] mt-0.5">
                  {sc.description}
                </div>
              </div>
              <div className="flex items-center gap-1 shrink-0">
                {sc.keys.map((k, idx) => (
                  <kbd
                    key={`${sc.title}-${idx}`}
                    className="min-w-[24px] h-6 px-1.5 rounded-[6px] bg-[var(--bg-gallery)] border border-[var(--border-strong)] shadow-[0_1px_0_var(--border-hairline)] inline-flex items-center justify-center font-mono text-[11px] font-medium text-[var(--text-primary)]"
                  >
                    {k}
                  </kbd>
                ))}
              </div>
            </div>
          ))}
        </div>
      </SettingsCard>

      {/* Hint footer */}
      <div className="flex items-center gap-2 text-[11.5px] text-[var(--text-tertiary)] px-1">
        <Terminal size={13} />
        <span>在 Windows / Linux 上可使用 Ctrl 替代 ⌘ (Command)。</span>
      </div>
    </div>
  );
};
