import React, { useEffect, useState } from 'react';
import { Check, Copy, KeyRound } from 'lucide-react';
import { externalAgentAccessLevelSummary } from '@charkle/shared';
import type { ExternalAgentAccessLevel, ExternalAgentConfig } from '@charkle/shared';
import { useCoordinatorStore } from '../../stores/coordinatorStore';
import { useSyncAIStore } from '../../stores/syncAIStore';
import {
  InlineGuideDisclosure,
  SettingsButton,
  SettingsCardDivider,
  SettingsCodeSnippet,
  SettingsGuideStep,
  SettingsRow,
  SettingsSection,
  SettingsSegmented,
  SettingsSwitch,
} from './SettingsChrome';
import {
  EXTERNAL_AGENT_SAMPLE_PROMPTS,
  MCP_TOOL_INVENTORY,
  buildHttpMcpConfigJson,
  buildStdioMcpConfigJson,
} from './shortcuts';

const ACCESS_LEVEL_OPTIONS: ReadonlyArray<{ id: ExternalAgentAccessLevel; label: string }> = [
  { id: 'readOnly', label: '仅只读' },
  { id: 'readWriteOrganize', label: '允许整理与生板' },
];

export const ExternalAgentsSettingsPane: React.FC = () => {
  const config = useSyncAIStore((s) => s.externalAgentConfig);
  const loadConfig = useSyncAIStore((s) => s.loadExternalAgentConfig);
  const saveConfig = useSyncAIStore((s) => s.saveExternalAgentConfig);
  const setSettingsTab = useCoordinatorStore((s) => s.setSettingsTab);
  const pushToast = useCoordinatorStore((s) => s.pushToast);

  const [copiedId, setCopiedId] = useState<string | null>(null);

  useEffect(() => {
    void loadConfig();
  }, [loadConfig]);

  const origin =
    typeof window !== 'undefined' ? window.location.origin : 'http://127.0.0.1:3188';
  const httpConfigJson = buildHttpMcpConfigJson(origin);
  const stdioConfigJson = buildStdioMcpConfigJson();

  const updatePolicy = async (next: ExternalAgentConfig) => {
    try {
      await saveConfig(next);
      pushToast({ tone: 'success', message: '外部 Agent 接入策略已更新' });
    } catch (err) {
      pushToast({
        tone: 'error',
        message: err instanceof Error ? err.message : '更新外部 Agent 策略失败',
      });
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
      pushToast({ tone: 'error', message: '复制失败，请手动选中文本复制' });
    }
  };

  return (
    <div className="flex flex-col gap-[22px]">
      {/* 1. 访问与安全边界 */}
      <SettingsSection title="访问与安全边界">
        <SettingsRow
          title="允许外部 AI 工具接入"
          subtitle="开启后，Claude Desktop、Cursor 等支持 MCP 的客户端可连接你的 Charkle 素材库"
        >
          <SettingsSwitch
            ariaLabel="允许外部 AI 工具接入"
            checked={config.enabled}
            onChange={(enabled) => void updatePolicy({ ...config, enabled })}
          />
        </SettingsRow>

        <SettingsCardDivider />

        <SettingsRow
          title="权限级别"
          subtitle={externalAgentAccessLevelSummary(config.accessLevel)}
        >
          <SettingsSegmented
            ariaLabel="权限级别"
            disabled={!config.enabled}
            options={ACCESS_LEVEL_OPTIONS}
            value={config.accessLevel}
            onChange={(accessLevel) => void updatePolicy({ ...config, accessLevel })}
          />
        </SettingsRow>

        <InlineGuideDisclosure title="数据安全如何保障？">
          <SettingsGuideStep
            number={1}
            title="永不提供永久删除能力"
            detail="即便开启「允许整理与生板」，外部助手最多只能将素材移入废纸篓（trash_assets），任何素材都可随时一键还原。"
          />
          <SettingsGuideStep
            number={2}
            title="尊重已锁定的情绪板卡片"
            detail="更新情绪板时会自动跳过已锁定节点，不会覆盖你亲手排好的关键主图与版式。"
          />
          <SettingsGuideStep
            number={3}
            title="独立个人访问令牌"
            detail="HTTP MCP 通过专属个人令牌鉴权，可在「账号与安全」中按需吊销，不影响主登录会话。"
          />
        </InlineGuideDisclosure>
      </SettingsSection>

      {/* 2. 接入常用 AI 客户端 */}
      <SettingsSection title="接入常用 AI 客户端">
        <SettingsRow
          title="HTTP MCP 远程接入"
          subtitle={<span className="font-mono text-[11px]">{origin}/api/v1/mcp</span>}
        >
          <SettingsButton variant="secondary" onClick={() => setSettingsTab('accountSecurity')}>
            <KeyRound size={12} />
            前往创建令牌
          </SettingsButton>
          <SettingsButton
            variant="primary"
            onClick={() =>
              void copyText('http', httpConfigJson, '已复制 HTTP MCP JSON 配置')
            }
          >
            {copiedId === 'http' ? <Check size={12} /> : <Copy size={12} />}
            {copiedId === 'http' ? '已复制' : '复制 JSON 配置'}
          </SettingsButton>
        </SettingsRow>

        <InlineGuideDisclosure title="查看 HTTP MCP 配置片段">
          <SettingsCodeSnippet text={httpConfigJson} />
          <div className="text-[11px] text-[var(--text-secondary)]">
            将片段中的 <code className="font-mono">chk_your_personal_access_token</code>{' '}
            替换为你在「账号与安全」中生成的个人令牌即可。
          </div>
        </InlineGuideDisclosure>

        <SettingsCardDivider />

        <SettingsRow
          title="本地命令行 (stdio) 接入"
          subtitle="适用于与服务端运行在同一台设备上的桌面 AI 客户端"
        >
          <SettingsButton
            variant="secondary"
            onClick={() =>
              void copyText('stdio', stdioConfigJson, '已复制本地命令行 MCP 配置')
            }
          >
            {copiedId === 'stdio' ? <Check size={12} /> : <Copy size={12} />}
            {copiedId === 'stdio' ? '已复制' : '复制 JSON 配置'}
          </SettingsButton>
        </SettingsRow>

        <InlineGuideDisclosure title="查看本地命令行配置片段">
          <SettingsCodeSnippet text={stdioConfigJson} />
        </InlineGuideDisclosure>

        <SettingsCardDivider />

        <div className="pt-2">
          <InlineGuideDisclosure title={`查看全部 ${MCP_TOOL_INVENTORY.length} 个可用工具清单`}>
            <div className="overflow-x-auto">
              <table className="w-full text-left border-collapse text-[11.5px]">
                <thead>
                  <tr className="border-b border-[var(--settings-divider,var(--border-hairline))] text-[10.5px] text-[var(--text-tertiary)]">
                    <th className="py-1.5 pr-3 font-medium">工具名称</th>
                    <th className="py-1.5 pr-3 font-medium">权限</th>
                    <th className="py-1.5 font-medium">说明</th>
                  </tr>
                </thead>
                <tbody className="divide-y divide-[var(--settings-divider,var(--border-hairline))]">
                  {MCP_TOOL_INVENTORY.map((tool) => {
                    const enabled =
                      config.enabled &&
                      (tool.access === 'read' || config.accessLevel === 'readWriteOrganize');
                    return (
                      <tr key={tool.name} className={enabled ? '' : 'opacity-45'}>
                        <td className="py-1.5 pr-3 font-mono text-[11px] text-[var(--text-primary)] whitespace-nowrap">
                          {tool.name}
                        </td>
                        <td className="py-1.5 pr-3 whitespace-nowrap">
                          <span
                            className={[
                              'px-1.5 py-0.5 rounded-[5px] text-[10px] font-medium',
                              tool.access === 'read'
                                ? 'bg-black/[0.06] dark:bg-white/[0.08] text-[var(--text-secondary)]'
                                : 'bg-[var(--accent-soft)] text-[var(--accent)]',
                            ].join(' ')}
                          >
                            {tool.access === 'read' ? '只读' : '整理写入'}
                          </span>
                        </td>
                        <td className="py-1.5 text-[var(--text-secondary)]">{tool.summary}</td>
                      </tr>
                    );
                  })}
                </tbody>
              </table>
            </div>
          </InlineGuideDisclosure>
        </div>
      </SettingsSection>

      {/* 3. 使用指南 */}
      <SettingsSection title="使用指南">
        <div className="pt-2">
          <InlineGuideDisclosure title="不知道怎么跟 AI 开口？查看 3 条推荐对话示例">
            <div className="flex flex-col gap-2.5">
              {EXTERNAL_AGENT_SAMPLE_PROMPTS.map((item) => (
                <div
                  key={item.id}
                  className="p-2.5 rounded-[8px] bg-[var(--settings-card,var(--bg-elevated))] border border-[var(--settings-border,var(--border-hairline))] flex flex-col gap-1.5"
                >
                  <div className="flex items-center justify-between gap-2">
                    <span className="text-[12px] font-medium text-[var(--text-primary)]">
                      {item.title}
                    </span>
                    <SettingsButton
                      variant="secondary"
                      className="h-[24px] px-2 text-[11px]"
                      onClick={() =>
                        void copyText(item.id, item.prompt, `已复制示例提示词「${item.title}」`)
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
        </div>
      </SettingsSection>
    </div>
  );
};
