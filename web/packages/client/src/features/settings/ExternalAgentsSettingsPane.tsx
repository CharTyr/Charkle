import React, { useEffect, useState } from 'react';
import {
  Activity,
  Check,
  CheckCircle2,
  Copy,
  KeyRound,
  XCircle,
} from 'lucide-react';
import { externalAgentAccessLevelSummary } from '@charkle/shared';
import type {
  ExternalAgentAccessLevel,
  ExternalAgentConfig,
  ExternalAgentDiagnosticsResponse,
} from '@charkle/shared';
import { useCoordinatorStore } from '../../stores/coordinatorStore';
import { useSyncAIStore } from '../../stores/syncAIStore';
import {
  InlineGuideDisclosure,
  SettingsButton,
  SettingsCardDivider,
  SettingsCodeSnippet,
  SettingsRow,
  SettingsSection,
  SettingsSegmented,
  SettingsStatusBadge,
  SettingsSwitch,
} from './SettingsChrome';
import {
  EXTERNAL_AGENT_SAMPLE_PROMPTS,
  buildClaudeCodeHttpCommand,
  buildCodexHttpSnippet,
  buildHttpMcpConfigJson,
  buildHttpMcpEndpoint,
} from './shortcuts';

const ACCESS_LEVEL_OPTIONS: ReadonlyArray<{ id: ExternalAgentAccessLevel; label: string }> = [
  { id: 'readOnly', label: '仅只读' },
  { id: 'readWriteOrganize', label: '允许整理与生板' },
];

function formatDiagnosticsSummary(report: ExternalAgentDiagnosticsResponse): string {
  if (!report.ok) {
    return report.error ? `连接异常：${report.error}` : '连接检测未通过';
  }
  return '服务正常';
}

export const ExternalAgentsSettingsPane: React.FC = () => {
  const runtimeMode = useSyncAIStore((s) => s.runtimeMode);
  const config = useSyncAIStore((s) => s.externalAgentConfig);
  const diagnostics = useSyncAIStore((s) => s.externalAgentDiagnostics);
  const isRunningDiagnostics = useSyncAIStore((s) => s.isRunningAgentDiagnostics);
  const loadConfig = useSyncAIStore((s) => s.loadExternalAgentConfig);
  const saveConfig = useSyncAIStore((s) => s.saveExternalAgentConfig);
  const runDiagnostics = useSyncAIStore((s) => s.runExternalAgentDiagnostics);
  const setSettingsTab = useCoordinatorStore((s) => s.setSettingsTab);
  const pushToast = useCoordinatorStore((s) => s.pushToast);

  const [copiedId, setCopiedId] = useState<string | null>(null);
  const [diagnosticsError, setDiagnosticsError] = useState<string | null>(null);

  useEffect(() => {
    void loadConfig();
  }, [loadConfig]);

  const isCloudflare = runtimeMode === 'cloudflare';
  const anyChannelEnabled = config.mcpEnabled || (!isCloudflare && config.cliEnabled);

  const origin =
    typeof window !== 'undefined' ? window.location.origin : 'http://127.0.0.1:3188';
  const httpEndpoint = buildHttpMcpEndpoint(origin);
  const claudeCodeCmd = buildClaudeCodeHttpCommand(origin);
  const codexSnippet = buildCodexHttpSnippet(origin);
  const httpConfigJson = buildHttpMcpConfigJson(origin);

  const updatePolicy = async (patch: Partial<ExternalAgentConfig>) => {
    const nextMcp = patch.mcpEnabled ?? config.mcpEnabled;
    const nextCli = patch.cliEnabled ?? config.cliEnabled;
    const next: ExternalAgentConfig = {
      ...config,
      ...patch,
      mcpEnabled: nextMcp,
      cliEnabled: nextCli,
      enabled: nextMcp || nextCli,
    };
    try {
      await saveConfig(next);
      pushToast({ tone: 'success', message: '外部助手设置已更新' });
    } catch (err) {
      pushToast({
        tone: 'error',
        message: err instanceof Error ? err.message : '更新设置失败',
      });
    }
  };

  const handleRunDiagnostics = async () => {
    setDiagnosticsError(null);
    try {
      const report = await runDiagnostics();
      pushToast({
        tone: report.ok ? 'success' : 'warning',
        message: report.ok ? '连接正常' : report.error || '连接检测未通过',
      });
    } catch (err) {
      const msg = err instanceof Error ? err.message : '连接检测失败';
      setDiagnosticsError(msg);
      pushToast({ tone: 'error', message: msg });
    }
  };

  const copyText = async (id: string, text: string, toastMessage: string) => {
    try {
      await navigator.clipboard.writeText(text);
      setCopiedId(id);
      pushToast({ tone: 'success', message: toastMessage });
      window.setTimeout(() => {
        setCopiedId((cur) => (cur === id ? null : cur));
      }, 1800);
    } catch {
      pushToast({ tone: 'error', message: '复制失败，请手动选中复制' });
    }
  };

  return (
    <div className="flex flex-col gap-[22px]">
      {/* 1. 服务开关与权限 */}
      <SettingsSection title="服务开关与权限">
        <SettingsRow
          title={
            <span className="inline-flex items-center gap-2 flex-wrap">
              <span>启用 MCP 服务</span>
              <SettingsStatusBadge
                text={config.mcpEnabled ? '已开启' : '已关闭'}
                tone={config.mcpEnabled ? 'positive' : 'neutral'}
              />
            </span>
          }
        >
          <SettingsSwitch
            ariaLabel="启用 MCP 服务"
            checked={config.mcpEnabled}
            onChange={(mcpEnabled) => void updatePolicy({ mcpEnabled })}
          />
        </SettingsRow>

        {!isCloudflare && (
          <>
            <SettingsCardDivider />
            <SettingsRow
              title={
                <span className="inline-flex items-center gap-2 flex-wrap">
                  <span>启用本地命令行接入</span>
                  <SettingsStatusBadge
                    text={config.cliEnabled ? '已开启' : '已关闭'}
                    tone={config.cliEnabled ? 'positive' : 'neutral'}
                  />
                </span>
              }
            >
              <SettingsSwitch
                ariaLabel="启用本地命令行接入"
                checked={config.cliEnabled}
                onChange={(cliEnabled) => void updatePolicy({ cliEnabled })}
              />
            </SettingsRow>
          </>
        )}

        <SettingsCardDivider />

        <SettingsRow
          title="权限级别"
          subtitle={externalAgentAccessLevelSummary(config.accessLevel)}
        >
          <SettingsSegmented
            ariaLabel="权限级别"
            disabled={!anyChannelEnabled}
            options={ACCESS_LEVEL_OPTIONS}
            value={config.accessLevel}
            onChange={(accessLevel) => void updatePolicy({ accessLevel })}
          />
        </SettingsRow>

        <SettingsCardDivider />

        <SettingsRow
          title="连接检测"
          subtitle={
            diagnosticsError
              ? diagnosticsError
              : diagnostics
                ? (
                    <span className="inline-flex items-center gap-1.5">
                      {diagnostics.ok ? (
                        <CheckCircle2 size={12.5} className="shrink-0" />
                      ) : (
                        <XCircle size={12.5} className="shrink-0" />
                      )}
                      <span>{formatDiagnosticsSummary(diagnostics)}</span>
                    </span>
                  )
                : undefined
          }
          subtitleTone={
            diagnosticsError
              ? 'destructive'
              : diagnostics
                ? diagnostics.ok
                  ? 'positive'
                  : 'warning'
                : 'default'
          }
        >
          <SettingsButton
            variant="secondary"
            loading={isRunningDiagnostics}
            onClick={() => void handleRunDiagnostics()}
          >
            <Activity size={12} />
            {isRunningDiagnostics ? '检测中…' : '检测连接'}
          </SettingsButton>
        </SettingsRow>
      </SettingsSection>

      {/* 2. 接入常用 AI 客户端 */}
      <SettingsSection
        title="接入 AI 客户端"
        caption={config.mcpEnabled ? undefined : '开启上方 MCP 服务后生效'}
      >
        <div className={config.mcpEnabled ? '' : 'opacity-70'}>
          <SettingsRow title="Claude Code" subtitle="复制命令在终端中运行">
            <SettingsButton variant="secondary" onClick={() => setSettingsTab('accountSecurity')}>
              <KeyRound size={12} />
              创建令牌
            </SettingsButton>
            <SettingsButton
              variant="primary"
              onClick={() =>
                void copyText('claude-http', claudeCodeCmd, '已复制 Claude Code 命令')
              }
            >
              {copiedId === 'claude-http' ? <Check size={12} /> : <Copy size={12} />}
              {copiedId === 'claude-http' ? '已复制' : '复制命令'}
            </SettingsButton>
          </SettingsRow>

          <SettingsCardDivider />

          <SettingsRow title="Codex CLI" subtitle="复制配置到 Codex">
            <SettingsButton
              variant="secondary"
              onClick={() => void copyText('codex-http', codexSnippet, '已复制 Codex 配置')}
            >
              {copiedId === 'codex-http' ? <Check size={12} /> : <Copy size={12} />}
              {copiedId === 'codex-http' ? '已复制' : '复制配置'}
            </SettingsButton>
          </SettingsRow>

          <InlineGuideDisclosure title="查看 Claude Code / Codex 配置片段">
            <div className="text-[11px] font-medium text-[var(--text-primary)]">Claude Code</div>
            <SettingsCodeSnippet text={claudeCodeCmd} />
            <div className="text-[11px] font-medium text-[var(--text-primary)] pt-1">Codex CLI</div>
            <SettingsCodeSnippet text={codexSnippet} />
            <div className="text-[11px] text-[var(--text-secondary)] leading-relaxed">
              将片段中的 <code className="font-mono">YOUR_ACCESS_TOKEN</code> 替换为「账号与安全」中创建的访问令牌。
            </div>
          </InlineGuideDisclosure>

          <SettingsCardDivider />

          <SettingsRow
            title="通用 MCP JSON 配置"
            subtitle={
              <span className="font-mono text-[11px] charkle-wrap-anywhere">{httpEndpoint}</span>
            }
          >
            <SettingsButton
              variant="secondary"
              onClick={() => void copyText('http', httpConfigJson, '已复制 JSON 配置')}
            >
              {copiedId === 'http' ? <Check size={12} /> : <Copy size={12} />}
              {copiedId === 'http' ? '已复制' : '复制 JSON'}
            </SettingsButton>
          </SettingsRow>

          <InlineGuideDisclosure title="查看 JSON 配置片段">
            <SettingsCodeSnippet text={httpConfigJson} />
          </InlineGuideDisclosure>
        </div>
      </SettingsSection>

      {/* 3. 常用对话示例 */}
      <SettingsSection title="使用示例">
        <InlineGuideDisclosure title="常用对话示例">
          <div className="flex flex-col gap-2.5">
            {EXTERNAL_AGENT_SAMPLE_PROMPTS.map((item) => (
              <div
                key={item.id}
                className="p-2.5 rounded-[var(--radius-settings-inner)] bg-[var(--settings-card,var(--bg-elevated))] border border-[var(--settings-border,var(--border-hairline))] flex flex-col gap-1.5"
              >
                <div className="flex items-center justify-between gap-2">
                  <span className="text-[12px] font-medium text-[var(--text-primary)]">
                    {item.title}
                  </span>
                  <SettingsButton
                    variant="secondary"
                    className="h-[24px] px-2 text-[11px]"
                    onClick={() =>
                      void copyText(item.id, item.prompt, `已复制示例「${item.title}」`)
                    }
                  >
                    {copiedId === item.id ? <Check size={11} /> : <Copy size={11} />}
                    {copiedId === item.id ? '已复制' : '复制'}
                  </SettingsButton>
                </div>
                <p className="text-[11.5px] text-[var(--text-secondary)] leading-relaxed select-text">
                  {item.prompt}
                </p>
              </div>
            ))}
          </div>
        </InlineGuideDisclosure>
      </SettingsSection>
    </div>
  );
};
