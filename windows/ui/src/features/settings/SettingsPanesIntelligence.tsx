import React, { useEffect, useState } from 'react';
import {
  CheckCircle2,
  Copy,
  KeyRound,
  RefreshCw,
  ShieldCheck,
  Sparkles,
  Terminal,
  Trash2,
  Zap,
} from 'lucide-react';
import { Button, SegmentedControl } from '../../design-system';
import { useCoordinatorStore, useSyncAIStore } from '../../stores';
import type {
  AIConnectionTestResult,
  AIProviderConfig,
  CloudAIProviderKind,
  CustomAIEndpointFormat,
  ExternalAgentAccessLevel,
  TypeSafeExperimentalConfig,
  TypeSafeTestResultDto,
} from '../../types/domain';

const QUICK_AI_PRESETS: Array<{
  id: string;
  label: string;
  provider: CloudAIProviderKind;
  format: CustomAIEndpointFormat;
  baseURL: string;
  chatModel: string;
  embeddingModel: string;
}> = [
  {
    id: 'gemini',
    label: 'Gemini',
    provider: 'gemini',
    format: 'openAIChatCompletions',
    baseURL: 'https://generativelanguage.googleapis.com',
    chatModel: 'gemini-2.5-flash',
    embeddingModel: 'gemini-embedding-001',
  },
  {
    id: 'openai',
    label: 'OpenAI',
    provider: 'openAICompatible',
    format: 'openAIChatCompletions',
    baseURL: 'https://api.openai.com/v1',
    chatModel: 'gpt-4.1-mini',
    embeddingModel: 'text-embedding-3-small',
  },
  {
    id: 'claude',
    label: 'Claude',
    provider: 'openAICompatible',
    format: 'anthropicMessages',
    baseURL: 'https://api.anthropic.com',
    chatModel: 'claude-sonnet-4-5',
    embeddingModel: '',
  },
  {
    id: 'ollama',
    label: 'Ollama 本地',
    provider: 'openAICompatible',
    format: 'openAIChatCompletions',
    baseURL: 'http://localhost:11434/v1',
    chatModel: 'qwen2.5vl:7b',
    embeddingModel: 'nomic-embed-text',
  },
];

export const AISettingsPane: React.FC = () => {
  const aiState = useSyncAIStore((s) => s.aiState);
  const typesafeState = useSyncAIStore((s) => s.typesafeState);
  const diagnostics = useSyncAIStore((s) => s.diagnostics);
  const saveAiConfig = useSyncAIStore((s) => s.saveAiConfig);
  const testAiConnection = useSyncAIStore((s) => s.testAiConnection);
  const resetAiUsage = useSyncAIStore((s) => s.resetAiUsage);
  const disconnectChatgpt = useSyncAIStore((s) => s.disconnectChatgpt);
  const saveTypesafeConfig = useSyncAIStore((s) => s.saveTypesafeConfig);
  const testTypesafeConnection = useSyncAIStore((s) => s.testTypesafeConnection);

  const [aiDraft, setAiDraft] = useState<AIProviderConfig>(
    aiState?.config ?? {
      provider: 'disabled',
      customEndpointFormat: 'openAIChatCompletions',
      baseURL: 'https://generativelanguage.googleapis.com',
      chatModel: 'gemini-2.5-flash',
      embeddingModel: 'gemini-embedding-001',
      autoAnalyzeOnImport: false,
      sendThumbnailsToCloud: true,
    },
  );
  const [apiKeyDraft, setApiKeyDraft] = useState('');
  const [testingAi, setTestingAi] = useState(false);
  const [aiTestRes, setAiTestRes] = useState<AIConnectionTestResult | null>(null);

  const [tsDraft, setTsDraft] = useState<TypeSafeExperimentalConfig>(
    typesafeState?.config ?? {
      enabled: false,
      baseURL: 'https://api.typesafe.ai',
      model: 'jev-latest',
      minConfidence: 0.6,
      lowConfidencePadding: 0.05,
      minPresenceProbability: 0.45,
      enableMoodboardFocusCrop: true,
      enableAutoCleanCrop: true,
      enableSubjectPalette: true,
      enablePinpointAnnotations: true,
      enableSemanticSearch: true,
      enableInboxSmartTriage: true,
      enableCuratorVisualRerank: true,
    },
  );
  const [tsKeyDraft, setTsKeyDraft] = useState('');
  const [testingTs, setTestingTs] = useState(false);
  const [tsTestRes, setTsTestRes] = useState<TypeSafeTestResultDto | null>(null);

  useEffect(() => {
    if (aiState) setAiDraft(aiState.config);
  }, [aiState]);

  useEffect(() => {
    if (typesafeState) setTsDraft(typesafeState.config);
  }, [typesafeState]);

  const usage = aiState?.usage;

  return (
    <div data-testid="settings-pane-ai" className="flex flex-col gap-4">
      <div>
        <h2 className="text-[16px] font-semibold text-[var(--text-primary)]">AI 智能与视觉定位</h2>
        <p className="text-[12px] text-[var(--text-secondary)] mt-0.5">
          所有 API 密钥与 OAuth 令牌均仅加密存储于 Windows DPAPI 凭据管理器，绝不以明文落盘。
        </p>
      </div>

      {/* 1. Hybrid Cloud AI Provider Card */}
      <section className="rounded-[var(--radius-settings-outer)] bg-[var(--bg-elevated)] border border-[var(--border-hairline)] p-4 flex flex-col gap-3">
        <div className="flex items-center justify-between">
          <span className="text-[13px] font-semibold text-[var(--text-primary)] inline-flex items-center gap-1.5">
            <Sparkles size={14} className="text-[var(--accent)]" />
            云端 AI 增强模式
          </span>
          <div className="flex items-center gap-1">
            {QUICK_AI_PRESETS.map((p) => (
              <button
                key={p.id}
                type="button"
                onClick={() =>
                  setAiDraft({
                    ...aiDraft,
                    provider: p.provider,
                    customEndpointFormat: p.format,
                    baseURL: p.baseURL,
                    chatModel: p.chatModel,
                    embeddingModel: p.embeddingModel,
                  })
                }
                className="charkle-pressable px-2 h-6 rounded-full bg-[var(--bg-subtle)] hover:bg-[var(--accent-soft)] hover:text-[var(--accent)] text-[11px] text-[var(--text-secondary)] cursor-pointer"
              >
                {p.label}
              </button>
            ))}
          </div>
        </div>

        <SegmentedControl<CloudAIProviderKind>
          value={aiDraft.provider}
          onChange={(provider) => setAiDraft({ ...aiDraft, provider })}
          ariaLabel="云端 AI 模式"
          options={[
            { value: 'disabled', label: '纯本机离线' },
            { value: 'chatGPTSubscription', label: 'ChatGPT 订阅' },
            { value: 'gemini', label: 'Google Gemini' },
            { value: 'openAICompatible', label: '自定义接口' },
          ]}
        />

        {aiDraft.provider === 'openAICompatible' && (
          <div className="flex items-center justify-between gap-2">
            <span className="text-[12px] text-[var(--text-secondary)]">协议格式</span>
            <SegmentedControl<CustomAIEndpointFormat>
              value={aiDraft.customEndpointFormat}
              onChange={(customEndpointFormat) => setAiDraft({ ...aiDraft, customEndpointFormat })}
              ariaLabel="自定义接口协议"
              options={[
                { value: 'openAIChatCompletions', label: 'OpenAI Chat' },
                { value: 'anthropicMessages', label: 'Anthropic Messages' },
                { value: 'openAIResponses', label: 'OpenAI Responses' },
              ]}
            />
          </div>
        )}

        {aiDraft.provider === 'chatGPTSubscription' && (
          <div className="rounded-[var(--radius-settings-inner)] bg-[var(--bg-subtle)]/70 p-3 flex items-center justify-between gap-2 text-[12px]">
            <div>
              <div className="font-medium text-[var(--text-primary)]">
                ChatGPT OAuth PKCE 会话：
                {aiState?.chatgptSession.status === 'connected'
                  ? `已连接（${aiState.chatgptSession.email ?? 'ChatGPT 账号'}）`
                  : '未登录'}
              </div>
              <div className="text-[11px] text-[var(--text-tertiary)] mt-0.5">
                使用 RFC 8252 本机环回回调 + PKCE S256 授权，刷新令牌加密存储于 Windows 凭据管理器。
              </div>
            </div>
            {aiState?.chatgptSession.status === 'connected' && (
              <Button variant="secondary" size="xs" onClick={() => void disconnectChatgpt()}>
                断开账号
              </Button>
            )}
          </div>
        )}

        {(aiDraft.provider === 'gemini' || aiDraft.provider === 'openAICompatible') && (
          <div className="grid grid-cols-1 sm:grid-cols-2 gap-2.5">
            <label className="sm:col-span-2 flex flex-col gap-1 text-[11.5px]">
              <span className="text-[var(--text-secondary)]">接口 Base URL</span>
              <input
                type="text"
                value={aiDraft.baseURL}
                onChange={(e) => setAiDraft({ ...aiDraft, baseURL: e.target.value })}
                className="h-8 px-2.5 rounded-[var(--radius-settings-inner)] bg-[var(--bg-inspector-field)] border border-[var(--border-hairline)] text-[12px] text-[var(--text-primary)] outline-none focus:border-[var(--accent)]"
              />
            </label>
            <label className="flex flex-col gap-1 text-[11.5px]">
              <span className="text-[var(--text-secondary)]">对话 / 视觉模型</span>
              <input
                type="text"
                value={aiDraft.chatModel}
                onChange={(e) => setAiDraft({ ...aiDraft, chatModel: e.target.value })}
                className="h-8 px-2.5 rounded-[var(--radius-settings-inner)] bg-[var(--bg-inspector-field)] border border-[var(--border-hairline)] text-[12px] text-[var(--text-primary)] outline-none focus:border-[var(--accent)]"
              />
            </label>
            <label className="flex flex-col gap-1 text-[11.5px]">
              <span className="text-[var(--text-secondary)]">向量 Embedding 模型（可选）</span>
              <input
                type="text"
                value={aiDraft.embeddingModel}
                onChange={(e) => setAiDraft({ ...aiDraft, embeddingModel: e.target.value })}
                className="h-8 px-2.5 rounded-[var(--radius-settings-inner)] bg-[var(--bg-inspector-field)] border border-[var(--border-hairline)] text-[12px] text-[var(--text-primary)] outline-none focus:border-[var(--accent)]"
              />
            </label>
            <label className="sm:col-span-2 flex flex-col gap-1 text-[11.5px]">
              <span className="text-[var(--text-secondary)] inline-flex items-center justify-between">
                <span className="inline-flex items-center gap-1">
                  <KeyRound size={12} />
                  API 密钥（仅写入 DPAPI 凭据库）
                </span>
                <span className="text-[var(--accent)]">
                  {aiState?.hasApiKey ? '已安全保存密钥' : '未配置密钥'}
                </span>
              </span>
              <div className="flex gap-2">
                <input
                  type="password"
                  aria-label="云端 AI API 密钥"
                  value={apiKeyDraft}
                  onChange={(e) => setApiKeyDraft(e.target.value)}
                  placeholder={aiState?.hasApiKey ? '••••••••••••••••（输入新密钥可覆盖）' : '输入 API Key…'}
                  className="flex-1 h-8 px-2.5 rounded-[var(--radius-settings-inner)] bg-[var(--bg-inspector-field)] border border-[var(--border-hairline)] text-[12px] text-[var(--text-primary)] outline-none focus:border-[var(--accent)]"
                />
                {aiState?.hasApiKey && (
                  <Button
                    variant="secondary"
                    size="xs"
                    onClick={() => void saveAiConfig(aiDraft, { clearApiKey: true })}
                  >
                    清除密钥
                  </Button>
                )}
              </div>
            </label>
          </div>
        )}

        <div className="flex flex-col gap-2 pt-1 text-[12px]">
          <label className="flex items-center justify-between cursor-pointer">
            <span className="text-[var(--text-primary)]">允许发送低分辨率缩略图以增强画面理解（隐私开关）</span>
            <input
              type="checkbox"
              checked={aiDraft.sendThumbnailsToCloud}
              onChange={(e) =>
                setAiDraft({ ...aiDraft, sendThumbnailsToCloud: e.target.checked })
              }
              className="h-4 w-4 accent-[var(--accent)]"
            />
          </label>
          <label className="flex items-center justify-between cursor-pointer">
            <span className="text-[var(--text-primary)]">新素材入库后自动后台补充语义标签</span>
            <input
              type="checkbox"
              checked={aiDraft.autoAnalyzeOnImport}
              onChange={(e) =>
                setAiDraft({ ...aiDraft, autoAnalyzeOnImport: e.target.checked })
              }
              className="h-4 w-4 accent-[var(--accent)]"
            />
          </label>
        </div>

        <div className="flex items-center justify-between pt-2 border-t border-[var(--border-hairline)]">
          <Button
            variant="secondary"
            size="xs"
            loading={testingAi}
            onClick={async () => {
              setTestingAi(true);
              try {
                await saveAiConfig(aiDraft, { apiKey: apiKeyDraft || null });
                setApiKeyDraft('');
                setAiTestRes(await testAiConnection());
              } finally {
                setTestingAi(false);
              }
            }}
          >
            <RefreshCw size={12.5} />
            测试连接
          </Button>
          <Button
            variant="primary"
            size="xs"
            onClick={async () => {
              await saveAiConfig(aiDraft, { apiKey: apiKeyDraft || null });
              setApiKeyDraft('');
            }}
          >
            保存 AI 配置
          </Button>
        </div>

        {aiTestRes && (
          <div
            data-testid="ai-test-result"
            className={`text-[11.5px] px-2.5 py-2 rounded-[var(--radius-settings-inner)] ${
              aiTestRes.ok
                ? 'bg-[var(--accent-soft)]/60 text-[var(--text-primary)]'
                : 'bg-[var(--danger-soft)] text-[var(--danger)]'
            }`}
          >
            {aiTestRes.providerLabel}：{aiTestRes.message}（{aiTestRes.latencyMs}ms）
          </div>
        )}
      </section>

      {/* 2. Separate Cloud AI vs Jev Usage Telemetry + WinRT OCR Card */}
      <section className="rounded-[var(--radius-settings-outer)] bg-[var(--bg-elevated)] border border-[var(--border-hairline)] p-4 flex flex-col gap-3">
        <div className="flex items-center justify-between">
          <span className="text-[12.5px] font-semibold text-[var(--text-primary)]">
            本地 AI 用量统计与离线 WinRT OCR
          </span>
          <Button variant="ghost" size="xs" onClick={() => void resetAiUsage(null)}>
            <Trash2 size={12} />
            清空计数
          </Button>
        </div>

        <div className="grid grid-cols-2 gap-2.5 text-[11.5px]">
          <div className="rounded-[var(--radius-settings-inner)] bg-[var(--bg-subtle)]/70 p-2.5">
            <div className="text-[var(--text-tertiary)]">常规云端 AI（今日 / 累计）</div>
            <div className="text-[14px] font-semibold text-[var(--text-primary)] charkle-tabular mt-1">
              {usage?.standard.todayRequests ?? 0} / {usage?.standard.totalRequests ?? 0} 次
            </div>
            <div className="text-[11px] text-[var(--text-tertiary)] charkle-tabular">
              {usage?.standard.todayTotalTokens ?? 0} / {usage?.standard.totalTokens ?? 0} tokens
            </div>
          </div>
          <div className="rounded-[var(--radius-settings-inner)] bg-[var(--bg-subtle)]/70 p-2.5">
            <div className="text-[var(--text-tertiary)]">TypeSafe Jev 视觉判断（今日 / 累计）</div>
            <div className="text-[14px] font-semibold text-[var(--text-primary)] charkle-tabular mt-1">
              {usage?.jev.todayRequests ?? 0} / {usage?.jev.totalRequests ?? 0} 次
            </div>
            <div className="text-[11px] text-[var(--text-tertiary)] charkle-tabular">
              {usage?.jev.todayTotalTokens ?? 0} / {usage?.jev.totalTokens ?? 0} tokens
            </div>
          </div>
        </div>

        <div className="text-[11.5px] text-[var(--text-secondary)] flex items-center justify-between bg-[var(--bg-subtle)]/50 px-2.5 py-2 rounded-[var(--radius-settings-inner)]">
          <span>
            离线 WinRT OCR 语言包：
            {(diagnostics?.ocr.availableLanguages ?? []).join('、') || '未检测到'}
          </span>
          <span className="text-[var(--accent)]">
            优先 {diagnostics?.ocr.selectedLanguage ?? '默认'}
          </span>
        </div>
      </section>

      {/* 3. Experimental TypeSafe System One (Jev) Card */}
      <section className="rounded-[var(--radius-settings-outer)] bg-[var(--bg-elevated)] border border-[var(--border-hairline)] p-4 flex flex-col gap-3">
        <label className="flex items-center justify-between cursor-pointer">
          <div>
            <div className="text-[13px] font-semibold text-[var(--text-primary)] inline-flex items-center gap-1.5">
              <Zap size={14} className="text-[var(--accent)]" />
              实验性：TypeSafe System One（Jev 视觉定位引擎）
            </div>
            <div className="text-[11.5px] text-[var(--text-tertiary)]">
              关闭或离线时自动回退至本机显著性分析，零功能阻断
            </div>
          </div>
          <input
            type="checkbox"
            aria-label="启用 TypeSafe Jev"
            checked={tsDraft.enabled}
            onChange={(e) => setTsDraft({ ...tsDraft, enabled: e.target.checked })}
            className="h-4 w-4 accent-[var(--accent)]"
          />
        </label>

        <div className="grid grid-cols-1 sm:grid-cols-2 gap-2 text-[11.5px]">
          <input
            type="text"
            value={tsDraft.baseURL}
            onChange={(e) => setTsDraft({ ...tsDraft, baseURL: e.target.value })}
            placeholder="https://api.typesafe.ai"
            className="h-8 px-2.5 rounded-[var(--radius-settings-inner)] bg-[var(--bg-inspector-field)] border border-[var(--border-hairline)] text-[12px] text-[var(--text-primary)] outline-none focus:border-[var(--accent)]"
          />
          <input
            type="text"
            value={tsDraft.model}
            onChange={(e) => setTsDraft({ ...tsDraft, model: e.target.value })}
            placeholder="jev-latest"
            className="h-8 px-2.5 rounded-[var(--radius-settings-inner)] bg-[var(--bg-inspector-field)] border border-[var(--border-hairline)] text-[12px] text-[var(--text-primary)] outline-none focus:border-[var(--accent)]"
          />
          <input
            type="password"
            aria-label="TypeSafe API 密钥"
            value={tsKeyDraft}
            onChange={(e) => setTsKeyDraft(e.target.value)}
            placeholder={
              typesafeState?.hasApiKey ? '已安全保存 TypeSafe 密钥（可覆盖）' : 'TypeSafe API Key…'
            }
            className="sm:col-span-2 h-8 px-2.5 rounded-[var(--radius-settings-inner)] bg-[var(--bg-inspector-field)] border border-[var(--border-hairline)] text-[12px] text-[var(--text-primary)] outline-none focus:border-[var(--accent)]"
          />
        </div>

        <div className="grid grid-cols-2 gap-x-4 gap-y-1.5 text-[11.5px] text-[var(--text-secondary)]">
          {(
            [
              ['enableMoodboardFocusCrop', '情绪板焦点主体裁切'],
              ['enableAutoCleanCrop', '截图边缘去噪纯净裁切'],
              ['enableSubjectPalette', '主体感知 CIELAB 取色'],
              ['enablePinpointAnnotations', '画面细节精准连线定位'],
              ['enableSemanticSearch', '混合语义视觉重排'],
              ['enableInboxSmartTriage', '收件箱批量智能归类'],
              ['enableCuratorVisualRerank', '策展候选视觉重排'],
            ] as const
          ).map(([key, label]) => (
            <label key={key} className="flex items-center justify-between gap-2 cursor-pointer">
              <span>{label}</span>
              <input
                type="checkbox"
                checked={tsDraft[key]}
                onChange={(e) => setTsDraft({ ...tsDraft, [key]: e.target.checked })}
                className="accent-[var(--accent)]"
              />
            </label>
          ))}
        </div>

        <div className="flex items-center justify-between pt-2 border-t border-[var(--border-hairline)]">
          <Button
            variant="secondary"
            size="xs"
            loading={testingTs}
            onClick={async () => {
              setTestingTs(true);
              try {
                await saveTypesafeConfig(tsDraft, { apiKey: tsKeyDraft || null });
                setTsKeyDraft('');
                setTsTestRes(await testTypesafeConnection());
              } finally {
                setTestingTs(false);
              }
            }}
          >
            校验 Jev 模型列表
          </Button>
          <Button
            variant="primary"
            size="xs"
            onClick={async () => {
              await saveTypesafeConfig(tsDraft, { apiKey: tsKeyDraft || null });
              setTsKeyDraft('');
            }}
          >
            保存 Jev 配置
          </Button>
        </div>

        {tsTestRes && (
          <div className="text-[11.5px] text-[var(--text-secondary)]">
            {tsTestRes.message}
          </div>
        )}
      </section>
    </div>
  );
};

export const ExternalAgentsSettingsPane: React.FC = () => {
  const agentState = useSyncAIStore((s) => s.agentState);
  const saveExternalAgentConfig = useSyncAIStore((s) => s.saveExternalAgentConfig);
  const pushToast = useCoordinatorStore((s) => s.pushToast);

  const cfg = agentState?.config ?? {
    mcpEnabled: true,
    cliEnabled: true,
    accessLevel: 'readOnly' as ExternalAgentAccessLevel,
  };

  const updatePolicy = (patch: Partial<typeof cfg>) => {
    void saveExternalAgentConfig({ ...cfg, ...patch });
  };

  const copySnippet = async (text: string, label: string) => {
    await navigator.clipboard?.writeText(text).catch(() => {});
    pushToast({ message: `已复制 ${label}`, tone: 'success' });
  };

  return (
    <div data-testid="settings-pane-externalAgents" className="flex flex-col gap-4">
      <div>
        <h2 className="text-[16px] font-semibold text-[var(--text-primary)]">外部 Agent（MCP & CLI）</h2>
        <p className="text-[12px] text-[var(--text-secondary)] mt-0.5">
          允许 Claude Desktop、Cursor、Codex 或终端脚本直接连接本机 Charkle 素材库（
          {agentState?.readToolCount ?? 8} 个读取工具 + {agentState?.writeToolCount ?? 6} 个整理写入工具 +{' '}
          {agentState?.resourceCount ?? 2} 个 MCP 资源）。
        </p>
      </div>

      <section className="rounded-[var(--radius-settings-outer)] bg-[var(--bg-elevated)] border border-[var(--border-hairline)] p-4 flex flex-col gap-3.5">
        <label className="flex items-center justify-between gap-3 cursor-pointer">
          <div>
            <div className="text-[13px] font-medium text-[var(--text-primary)]">启用 MCP 服务</div>
            <div className="text-[11.5px] text-[var(--text-tertiary)]">
              允许外部 AI 客户端通过 `charkle-cli.exe mcp`（JSON-RPC 2.0 stdio）接入
            </div>
          </div>
          <input
            type="checkbox"
            aria-label="启用 MCP 服务"
            checked={cfg.mcpEnabled}
            onChange={(e) => updatePolicy({ mcpEnabled: e.target.checked })}
            className="h-4 w-4 accent-[var(--accent)]"
          />
        </label>

        <div className="h-px bg-[var(--border-hairline)]" />

        <label className="flex items-center justify-between gap-3 cursor-pointer">
          <div>
            <div className="text-[13px] font-medium text-[var(--text-primary)]">
              启用 CLI 命令行服务
            </div>
            <div className="text-[11.5px] text-[var(--text-tertiary)]">
              允许终端与自动化脚本调用 `charkle-cli.exe status / search / inbox / organize / compose-board`
            </div>
          </div>
          <input
            type="checkbox"
            aria-label="启用 CLI 命令行服务"
            checked={cfg.cliEnabled}
            onChange={(e) => updatePolicy({ cliEnabled: e.target.checked })}
            className="h-4 w-4 accent-[var(--accent)]"
          />
        </label>

        <div className="h-px bg-[var(--border-hairline)]" />

        <div className="flex flex-col gap-2">
          <div className="flex items-center justify-between gap-3">
            <span className="text-[13px] font-medium text-[var(--text-primary)]">访问权限级别</span>
            <SegmentedControl<ExternalAgentAccessLevel>
              value={cfg.accessLevel}
              onChange={(accessLevel) => updatePolicy({ accessLevel })}
              ariaLabel="外部 Agent 权限级别"
              options={[
                { value: 'readOnly', label: '仅只读检索与导出' },
                { value: 'readWriteOrganize', label: '允许整理与生成情绪板' },
              ]}
            />
          </div>
          <div className="rounded-[var(--radius-settings-inner)] bg-[var(--bg-subtle)]/70 p-2.5 text-[11.5px] text-[var(--text-secondary)] flex items-start gap-2">
            <ShieldCheck size={15} className="text-[var(--accent)] shrink-0 mt-0.5" />
            <span>
              安全不变量：即便授予「允许整理与生成情绪板」，外部 Agent 也永远无法彻底删除您的文件（仅允许软移入回收站），所有写入会通过 Windows 命名事件即时刷新桌面界面。
            </span>
          </div>
        </div>
      </section>

      <section className="rounded-[var(--radius-settings-outer)] bg-[var(--bg-elevated)] border border-[var(--border-hairline)] p-4 flex flex-col gap-2.5">
        <div className="flex items-center justify-between">
          <span className="text-[12.5px] font-semibold text-[var(--text-primary)] inline-flex items-center gap-1.5">
            <Terminal size={14} />
            CLI 路径与 MCP JSON 配置片段
          </span>
          <div className="flex items-center gap-1.5">
            <Button
              variant="secondary"
              size="xs"
              onClick={() =>
                void copySnippet(agentState?.cliBinaryPath ?? 'charkle-cli.exe', 'CLI 路径')
              }
            >
              <Copy size={12} />
              复制 CLI 路径
            </Button>
            <Button
              variant="primary"
              size="xs"
              onClick={() =>
                void copySnippet(agentState?.mcpConfigJson ?? '{}', 'MCP 配置 JSON')
              }
            >
              <CheckCircle2 size={12} />
              复制 MCP JSON
            </Button>
          </div>
        </div>

        <div className="text-[11px] font-mono text-[var(--text-secondary)] truncate bg-[var(--bg-subtle)]/60 px-2.5 py-1.5 rounded-[var(--radius-card-inner)]">
          {agentState?.cliBinaryPath ?? 'charkle-cli.exe'}
        </div>

        <pre
          data-testid="mcp-config-json-snippet"
          className="text-[11px] font-mono text-[var(--text-primary)] bg-[var(--bg-subtle)]/70 border border-[var(--border-hairline)] rounded-[var(--radius-settings-inner)] p-2.5 overflow-x-auto leading-relaxed"
        >
          {agentState?.mcpConfigJson ?? ''}
        </pre>
      </section>
    </div>
  );
};
