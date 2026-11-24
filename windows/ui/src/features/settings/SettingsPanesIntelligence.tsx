import React, { useEffect, useState } from 'react';
import {
  ArrowSync16Regular,
  Color16Regular,
  Copy16Regular,
  Open16Regular,
  ScanText16Regular,
  Search16Regular,
  Sparkle16Regular,
} from '@fluentui/react-icons';
import { getTransport } from '../../api/transport';
import { CharkleSlider, CustomSelect, SegmentedControl } from '../../design-system';
import { useCoordinatorStore, useSyncAIStore } from '../../stores';
import type {
  AIConnectionTestResult,
  AIProviderConfig,
  CloudAIProviderKind,
  CloudAIUsageBucket,
  CustomAIEndpointFormat,
  ExternalAgentAccessLevel,
  TypeSafeExperimentalConfig,
  TypeSafeTestResultDto,
} from '../../types/domain';
import {
  CHATGPT_USAGE_URL,
  ChatGPTBrandMark,
  formatTokenCount,
  GEMINI_KEY_URL,
  InlineGuideDisclosure,
  isValidHttpUrl,
  relativeTimeText,
  SettingsButton,
  SettingsCardDivider,
  SettingsCodeSnippet,
  SettingsDisclosureGroup,
  SettingsGuideStep,
  SettingsInput,
  SettingsRow,
  SettingsSection,
  SettingsStatusBadge,
  SettingsSubModal,
  SettingsSwitch,
  TYPESAFE_HOME_URL,
} from './SettingsChrome';

interface CustomEndpointPreset {
  id: string;
  label: string;
  format: CustomAIEndpointFormat;
  baseURL: string;
  chatModel: string;
  embeddingModel: string;
}

const CUSTOM_ENDPOINT_PRESETS: CustomEndpointPreset[] = [
  {
    id: 'openai',
    label: 'OpenAI',
    format: 'openAIChatCompletions',
    baseURL: 'https://api.openai.com/v1',
    chatModel: 'gpt-4.1-mini',
    embeddingModel: 'text-embedding-3-small',
  },
  {
    id: 'anthropic',
    label: 'Claude',
    format: 'anthropicMessages',
    baseURL: 'https://api.anthropic.com',
    chatModel: 'claude-sonnet-4-5',
    embeddingModel: '',
  },
  {
    id: 'openrouter',
    label: 'OpenRouter',
    format: 'openAIChatCompletions',
    baseURL: 'https://openrouter.ai/api/v1',
    chatModel: 'google/gemini-2.5-flash',
    embeddingModel: '',
  },
  {
    id: 'deepseek',
    label: 'DeepSeek',
    format: 'openAIChatCompletions',
    baseURL: 'https://api.deepseek.com/v1',
    chatModel: 'deepseek-chat',
    embeddingModel: '',
  },
  {
    id: 'ollama',
    label: 'Ollama 本地',
    format: 'openAIChatCompletions',
    baseURL: 'http://localhost:11434/v1',
    chatModel: 'qwen2.5vl:7b',
    embeddingModel: 'nomic-embed-text',
  },
];

const DEFAULT_AI_CONFIG: AIProviderConfig = {
  provider: 'disabled',
  customEndpointFormat: 'openAIChatCompletions',
  baseURL: 'https://generativelanguage.googleapis.com',
  chatModel: 'gemini-2.5-flash',
  embeddingModel: 'gemini-embedding-001',
  autoAnalyzeOnImport: false,
  sendThumbnailsToCloud: true,
};

const DEFAULT_TYPESAFE_CONFIG: TypeSafeExperimentalConfig = {
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
};

function endpointFormatLabel(format: CustomAIEndpointFormat): string {
  switch (format) {
    case 'openAIChatCompletions':
      return 'OpenAI Chat Completions';
    case 'anthropicMessages':
      return 'Anthropic Messages';
    case 'openAIResponses':
      return 'OpenAI Responses';
  }
}

function defaultBaseURLForFormat(format: CustomAIEndpointFormat): string {
  switch (format) {
    case 'anthropicMessages':
      return 'https://api.anthropic.com';
    case 'openAIResponses':
    case 'openAIChatCompletions':
      return 'https://api.openai.com/v1';
  }
}

function defaultChatModelForFormat(format: CustomAIEndpointFormat): string {
  switch (format) {
    case 'anthropicMessages':
      return 'claude-sonnet-4-5';
    case 'openAIResponses':
    case 'openAIChatCompletions':
      return 'gpt-4.1-mini';
  }
}

function applySmartAIDefaults(
  current: AIProviderConfig,
  provider: CloudAIProviderKind,
  format: CustomAIEndpointFormat,
): AIProviderConfig {
  const knownDefaultURLs = new Set([
    '',
    'https://generativelanguage.googleapis.com',
    'https://api.openai.com',
    'https://api.openai.com/v1',
    'https://api.anthropic.com',
  ]);
  const knownDefaultChats = new Set([
    '',
    'gemini-2.5-flash',
    'gpt-4.1-mini',
    'gpt-5.4-mini',
    'claude-sonnet-4-5',
  ]);
  const knownDefaultEmbeddings = new Set([
    '',
    'gemini-embedding-001',
    'text-embedding-3-small',
  ]);

  const next: AIProviderConfig = { ...current, provider, customEndpointFormat: format };

  if (provider === 'chatGPTSubscription') {
    next.baseURL = 'https://api.openai.com/v1';
    if (knownDefaultChats.has(next.chatModel)) next.chatModel = 'gpt-5.4-mini';
    next.embeddingModel = '';
  } else if (provider === 'gemini') {
    if (knownDefaultURLs.has(next.baseURL)) {
      next.baseURL = 'https://generativelanguage.googleapis.com';
    }
    if (knownDefaultChats.has(next.chatModel)) next.chatModel = 'gemini-2.5-flash';
    if (knownDefaultEmbeddings.has(next.embeddingModel)) {
      next.embeddingModel = 'gemini-embedding-001';
    }
  } else if (provider === 'openAICompatible') {
    if (knownDefaultURLs.has(next.baseURL)) next.baseURL = defaultBaseURLForFormat(format);
    if (knownDefaultChats.has(next.chatModel)) next.chatModel = defaultChatModelForFormat(format);
    if (knownDefaultEmbeddings.has(next.embeddingModel)) {
      next.embeddingModel = format === 'anthropicMessages' ? '' : 'text-embedding-3-small';
    }
  }

  return next;
}

// =========================================================================
// Pane 6: AI 智能 (AISettingsPane) — mirrors AISettingsPane.swift 1:1
// =========================================================================

export const AISettingsPane: React.FC = () => {
  const aiState = useSyncAIStore((s) => s.aiState);
  const testingAi = useSyncAIStore((s) => s.testingAi);
  const signingInChatgpt = useSyncAIStore((s) => s.signingInChatgpt);
  const typesafeState = useSyncAIStore((s) => s.typesafeState);
  const typesafeModels = useSyncAIStore((s) => s.typesafeModels);
  const testingTypesafe = useSyncAIStore((s) => s.testingTypesafe);
  const saveAiConfig = useSyncAIStore((s) => s.saveAiConfig);
  const testAiConnection = useSyncAIStore((s) => s.testAiConnection);
  const resetAiUsage = useSyncAIStore((s) => s.resetAiUsage);
  const signInChatgpt = useSyncAIStore((s) => s.signInChatgpt);
  const disconnectChatgpt = useSyncAIStore((s) => s.disconnectChatgpt);
  const saveTypesafeConfig = useSyncAIStore((s) => s.saveTypesafeConfig);
  const testTypesafeConnection = useSyncAIStore((s) => s.testTypesafeConnection);

  const [aiDraft, setAiDraft] = useState<AIProviderConfig>(aiState?.config ?? DEFAULT_AI_CONFIG);
  const [tsDraft, setTsDraft] = useState<TypeSafeExperimentalConfig>(
    typesafeState?.config ?? DEFAULT_TYPESAFE_CONFIG,
  );

  const [showCloudModal, setShowCloudModal] = useState(false);
  const [apiKeyInput, setApiKeyInput] = useState('');
  const [savingAi, setSavingAi] = useState(false);
  const [aiTestRes, setAiTestRes] = useState<AIConnectionTestResult | null>(null);

  const [showTypeSafeModal, setShowTypeSafeModal] = useState(false);
  const [tsKeyInput, setTsKeyInput] = useState('');
  const [savingTs, setSavingTs] = useState(false);
  const [tsTestRes, setTsTestRes] = useState<TypeSafeTestResultDto | null>(null);

  const [showUsageModal, setShowUsageModal] = useState(false);

  useEffect(() => {
    if (aiState && !showCloudModal) setAiDraft(aiState.config);
  }, [aiState, showCloudModal]);

  useEffect(() => {
    if (typesafeState && !showTypeSafeModal) setTsDraft(typesafeState.config);
  }, [typesafeState, showTypeSafeModal]);

  const closeCloudModal = () => {
    setShowCloudModal(false);
    setApiKeyInput('');
    if (aiState) setAiDraft(aiState.config);
  };

  const closeTypeSafeModal = () => {
    setShowTypeSafeModal(false);
    setTsKeyInput('');
    if (typesafeState) setTsDraft(typesafeState.config);
  };

  const trimmedAiBaseUrl = aiDraft.baseURL.trim();
  const isAiBaseUrlInvalid =
    (aiDraft.provider === 'openAICompatible' && !isValidHttpUrl(trimmedAiBaseUrl)) ||
    (aiDraft.provider === 'gemini' &&
      trimmedAiBaseUrl.length > 0 &&
      !isValidHttpUrl(trimmedAiBaseUrl));

  const trimmedTsBaseUrl = tsDraft.baseURL.trim();
  const isTsBaseUrlInvalid = trimmedTsBaseUrl.length > 0 && !isValidHttpUrl(trimmedTsBaseUrl);

  const session = aiState?.chatgptSession ?? { status: 'disconnected' as const, sharingEnabled: false };
  const hasApiKey = aiState?.hasApiKey ?? false;
  const hasTypeSafeKey = typesafeState?.hasApiKey ?? false;
  const usage = aiState?.usage;

  const isLocalOllama =
    aiDraft.provider === 'openAICompatible' &&
    (aiDraft.baseURL.toLowerCase().includes('localhost') || aiDraft.baseURL.includes('127.0.0.1'));

  const isCloudProviderReady = (() => {
    switch (aiDraft.provider) {
      case 'disabled':
        return false;
      case 'chatGPTSubscription':
        return session.status === 'connected' && session.sharingEnabled;
      case 'gemini':
        return hasApiKey;
      case 'openAICompatible':
        return aiDraft.baseURL.trim().length > 0 && (hasApiKey || isLocalOllama);
    }
  })();

  const cloudDisconnectedTitle = (() => {
    switch (aiDraft.provider) {
      case 'disabled':
        return '尚未开启云端增强智能';
      case 'chatGPTSubscription':
        return session.status === 'reauthRequired'
          ? 'ChatGPT 登录已过期'
          : 'ChatGPT 订阅尚未完成授权';
      case 'gemini':
        return 'Google Gemini 尚未配置密钥';
      case 'openAICompatible':
        return '自定义 API 尚未配置完成';
    }
  })();

  const cloudDisconnectedSubtitle = (() => {
    switch (aiDraft.provider) {
      case 'disabled':
        return '连接后可自动生成画面描述、建议标签，并大幅提升灵感词生板准确度';
      case 'chatGPTSubscription':
        return '直接登录你的 ChatGPT Plus / Pro 账号即可使用，无需手动管理 API 密钥';
      case 'gemini':
        return '前往「Gemini / 自定义 API…」粘贴 Google AI Studio 密钥并测试连接';
      case 'openAICompatible':
        return '前往「Gemini / 自定义 API…」填写服务地址、模型与密钥';
    }
  })();

  const cloudConnectedTitle = (() => {
    switch (aiDraft.provider) {
      case 'disabled':
        return '已关闭';
      case 'chatGPTSubscription':
        return 'ChatGPT 订阅账号';
      case 'gemini':
        return 'Google Gemini';
      case 'openAICompatible':
        return endpointFormatLabel(aiDraft.customEndpointFormat);
    }
  })();

  const cloudConnectedSubtitle = (() => {
    const model = aiDraft.chatModel.trim() || '默认模型';
    switch (aiDraft.provider) {
      case 'disabled':
        return '仅使用本机离线能力';
      case 'chatGPTSubscription': {
        const account = session.email ?? session.name ?? 'ChatGPT';
        return `已连接（${account}）· 当前模型：${model}`;
      }
      case 'gemini':
        return `已连接 · 当前模型：${model}`;
      case 'openAICompatible': {
        let host = aiDraft.baseURL;
        try {
          host = new URL(aiDraft.baseURL).host || aiDraft.baseURL;
        } catch {
          // keep raw baseURL
        }
        return `已连接（${host}）· 当前模型：${model}`;
      }
    }
  })();

  const enabledCapabilitiesCount = [
    tsDraft.enableMoodboardFocusCrop,
    tsDraft.enableAutoCleanCrop,
    tsDraft.enableSubjectPalette,
    tsDraft.enableSemanticSearch,
    tsDraft.enableInboxSmartTriage,
    tsDraft.enableCuratorVisualRerank,
  ].filter(Boolean).length;

  const todayTotal = (usage?.standard.todayRequests ?? 0) + (usage?.jev.todayRequests ?? 0);
  const allTotalRequests = usage?.totalRequests ?? 0;
  const allTotalTokens = (usage?.standard.totalTokens ?? 0) + (usage?.jev.totalTokens ?? 0);

  const persistAIQuiet = (next: AIProviderConfig) => {
    setAiDraft(next);
    void saveAiConfig(next, { apiKey: null, quiet: true });
  };

  const persistTSQuiet = (next: TypeSafeExperimentalConfig) => {
    setTsDraft(next);
    void saveTypesafeConfig(next, { apiKey: null, quiet: true });
  };

  return (
    <div data-testid="settings-pane-ai" className="flex flex-col gap-5">
      {/* 1. Built-in Offline Capabilities Strip */}
      <SettingsSection title="基础离线能力" caption="全部免费内置 · 无需下载 · 数据不出本机">
        <div className="px-3.5 py-3 grid grid-cols-2 sm:grid-cols-4 gap-2">
          {(
            [
              { icon: <Color16Regular className="w-3.5 h-3.5" />, label: '自动配色提取' },
              { icon: <Sparkle16Regular className="w-3.5 h-3.5" />, label: '视觉相似推荐' },
              { icon: <ScanText16Regular className="w-3.5 h-3.5" />, label: '图内文字 OCR' },
              { icon: <Search16Regular className="w-3.5 h-3.5" />, label: '中文与拼音快搜' },
            ] as const
          ).map((badge) => (
            <div
              key={badge.label}
              className="rounded-[var(--win-radius-control)] bg-[var(--settings-subtle)] border border-[var(--win-stroke-divider)] px-2.5 py-1.5 flex items-center justify-center gap-1.5 text-[12px] font-medium text-[var(--text-primary)]"
            >
              <span className="text-[var(--settings-positive)] shrink-0">{badge.icon}</span>
              <span className="truncate">{badge.label}</span>
            </div>
          ))}
        </div>
      </SettingsSection>

      {/* 2. Cloud Intelligence Section */}
      <SettingsSection title="云端增强智能">
        {!isCloudProviderReady ? (
          <>
            <SettingsRow
              title={cloudDisconnectedTitle}
              subtitle={cloudDisconnectedSubtitle}
              subtitleTone={aiDraft.provider === 'disabled' ? 'default' : 'warning'}
            >
              <SettingsButton
                variant="standard"
                onClick={() => {
                  if (aiDraft.provider === 'disabled' || aiDraft.provider === 'chatGPTSubscription') {
                    setAiDraft(applySmartAIDefaults(aiDraft, 'gemini', aiDraft.customEndpointFormat));
                  }
                  setApiKeyInput('');
                  setAiTestRes(null);
                  setShowCloudModal(true);
                }}
              >
                Gemini / 自定义 API…
              </SettingsButton>
              <SettingsButton
                variant="accent"
                loading={signingInChatgpt}
                onClick={async () => {
                  const reconsent = session.status === 'connected' && !session.sharingEnabled;
                  await signInChatgpt(reconsent, false);
                }}
              >
                <ChatGPTBrandMark size={13.5} />
                <span>{signingInChatgpt ? '等待授权…' : '使用 ChatGPT 登录'}</span>
              </SettingsButton>
            </SettingsRow>

            <InlineGuideDisclosure title="各方案怎么选？如何获取 API 密钥">
              <SettingsGuideStep
                number="1"
                title="ChatGPT 订阅账号（最省心，零密钥配置）"
                detail="已有 ChatGPT Plus / Pro 订阅时直接登录授权，无需申请或管理 API Key。"
              />
              <SettingsGuideStep
                number="2"
                title="Google Gemini（性价比高，原生支持多模态与向量检索）"
                detail="前往 Google AI Studio 免费创建 API Key，点击「Gemini / 自定义 API…」粘贴保存即可。"
              />
              <SettingsGuideStep
                number="3"
                title="自定义 API（支持 Claude / OpenRouter / DeepSeek / 本机 Ollama）"
                detail="内置常见服务商一键预设，也支持连接本机运行的 Ollama 多模态模型。"
              />
            </InlineGuideDisclosure>
          </>
        ) : (
          <SettingsRow
            title={cloudConnectedTitle}
            subtitle={cloudConnectedSubtitle}
            subtitleTone="positive"
          >
            <SettingsButton
              variant="standard"
              loading={testingAi}
              onClick={async () => {
                setAiTestRes(await testAiConnection());
              }}
            >
              <ArrowSync16Regular
                className={`w-3.5 h-3.5 shrink-0 ${testingAi ? 'animate-spin motion-reduce:animate-none' : ''}`}
              />
              {testingAi ? '测试中…' : '测试连接'}
            </SettingsButton>
            <SettingsButton
              variant="accent"
              onClick={() => {
                setApiKeyInput('');
                setAiTestRes(null);
                setShowCloudModal(true);
              }}
            >
              更改配置…
            </SettingsButton>
          </SettingsRow>
        )}

        {aiTestRes && !showCloudModal && (
          <div
            data-testid="ai-test-result"
            className={[
              'mx-4 mb-3 text-[12px] px-3 py-2 rounded-[var(--win-radius-control)] border',
              aiTestRes.ok
                ? 'bg-[var(--settings-positive)]/10 border-[var(--settings-positive)]/25 text-[var(--text-primary)]'
                : 'bg-[var(--settings-destructive)]/10 border-[var(--settings-destructive)]/25 text-[var(--settings-destructive)]',
            ].join(' ')}
          >
            {aiTestRes.providerLabel}：{aiTestRes.message}
            {aiTestRes.latencyMs > 0 ? `（${aiTestRes.latencyMs}ms）` : ''}
          </div>
        )}

        {aiDraft.provider !== 'disabled' && (
          <>
            <SettingsCardDivider />
            <SettingsRow
              title="导入时自动分析"
              subtitle="收藏新素材后自动补充画面描述与建议标签，让灵感词生板更懂你的参考库"
            >
              <SettingsSwitch
                checked={aiDraft.autoAnalyzeOnImport}
                ariaLabel="导入时自动分析"
                onChange={(autoAnalyzeOnImport) =>
                  persistAIQuiet({ ...aiDraft, autoAnalyzeOnImport })
                }
              />
            </SettingsRow>

            <SettingsCardDivider />

            <SettingsRow
              title="仅上传轻量化预览图"
              subtitle="大幅节省网络流量，避免发送原始高清大图"
            >
              <SettingsSwitch
                checked={aiDraft.sendThumbnailsToCloud}
                ariaLabel="仅上传轻量化预览图"
                onChange={(sendThumbnailsToCloud) =>
                  persistAIQuiet({ ...aiDraft, sendThumbnailsToCloud })
                }
              />
            </SettingsRow>
          </>
        )}
      </SettingsSection>

      {/* 3. Visual Enhancement Section (Human-Labeled TypeSafe) */}
      <SettingsSection title="进阶视觉定位（实验性）">
        <SettingsRow
          title="精准画面定位与智能分拣"
          subtitle="开启后支持情绪板语义局部裁切、截图自动去噪、主体色板提取与收件箱智能归类；未开启时由本机离线算法兜底"
        >
          <SettingsSwitch
            checked={tsDraft.enabled}
            ariaLabel="启用精准画面定位"
            onChange={(enabled) => persistTSQuiet({ ...tsDraft, enabled })}
          />
        </SettingsRow>

        {tsDraft.enabled && (
          <>
            <SettingsCardDivider />
            <SettingsRow
              title="TypeSafe 视觉定位引擎"
              subtitle={
                hasTypeSafeKey
                  ? `已配置密钥 · 模型 ${tsDraft.model} · 已开启 ${enabledCapabilitiesCount}/6 项增强场景`
                  : '尚未填写 TypeSafe API 密钥，填写后即可启用精准定位与看图精排'
              }
              subtitleTone={hasTypeSafeKey ? 'positive' : 'warning'}
            >
              {hasTypeSafeKey && (
                <SettingsButton
                  variant="secondary"
                  loading={testingTypesafe}
                  onClick={async () => {
                    setTsTestRes(await testTypesafeConnection());
                  }}
                >
                  {testingTypesafe ? '测试中…' : '测试连接'}
                </SettingsButton>
              )}
              <SettingsButton
                variant="secondary"
                onClick={() => {
                  setTsKeyInput('');
                  setTsTestRes(null);
                  setShowTypeSafeModal(true);
                }}
              >
                密钥与功能开关…
              </SettingsButton>
            </SettingsRow>
          </>
        )}

        <InlineGuideDisclosure title="这是什么？和上方云端 AI 有什么区别？">
          <SettingsGuideStep
            number="1"
            title="与生成式大模型互补：专注「指哪打哪」的坐标定位与视觉评分"
            detail="普通大模型擅长描述画面和起标签；视觉定位引擎专门用来在图里精准圈出主体坐标、裁掉截图外壳，或给候选素材打分。"
          />
          <SettingsGuideStep
            number="2"
            title="完全可选，不开也不影响核心体验"
            detail="未开启时，主体聚焦与视觉相似自动回退至本机离线算法，零额外费用。"
          />
        </InlineGuideDisclosure>
      </SettingsSection>

      {/* 4. Compact Usage Summary Section */}
      <SettingsSection title="用量统计">
        <SettingsRow
          title={
            allTotalRequests > 0
              ? `今日 ${todayTotal} 次 · 累计 ${allTotalRequests} 次（${formatTokenCount(allTotalTokens)} tokens）`
              : '暂无云端调用记录'
          }
          subtitle="分别统计普通云端模型与视觉定位引擎在本机的调用次数与 Token 消耗"
        >
          <SettingsButton variant="secondary" onClick={() => setShowUsageModal(true)}>
            查看明细…
          </SettingsButton>
        </SettingsRow>
      </SettingsSection>

      {/* Sheet 1: Cloud AI Configuration Modal */}
      <SettingsSubModal
        open={showCloudModal}
        onClose={closeCloudModal}
        title="配置云端 AI 服务"
        subtitle="所有 API 密钥与登录令牌均加密保存于 Windows 凭据管理器。"
        width="md"
        footer={
          <>
            <SettingsButton
              variant="secondary"
              disabled={savingAi || testingAi}
              onClick={closeCloudModal}
            >
              关闭
            </SettingsButton>
            {aiDraft.provider !== 'disabled' && (
              <SettingsButton
                variant="secondary"
                loading={testingAi}
                disabled={savingAi || isAiBaseUrlInvalid}
                onClick={async () => {
                  const trimmedKey = apiKeyInput.trim();
                  const ok = await saveAiConfig(
                    { ...aiDraft, baseURL: trimmedAiBaseUrl },
                    {
                      apiKey: trimmedKey || null,
                      quiet: true,
                    },
                  );
                  if (!ok) return;
                  if (trimmedKey) setApiKeyInput('');
                  setAiTestRes(await testAiConnection());
                }}
              >
                {testingAi ? '测试中…' : '测试连接'}
              </SettingsButton>
            )}
            <SettingsButton
              variant="primary"
              loading={savingAi}
              disabled={testingAi || isAiBaseUrlInvalid}
              onClick={async () => {
                setSavingAi(true);
                try {
                  const trimmedKey = apiKeyInput.trim();
                  const ok = await saveAiConfig(
                    { ...aiDraft, baseURL: trimmedAiBaseUrl },
                    { apiKey: trimmedKey || null },
                  );
                  if (ok) {
                    setApiKeyInput('');
                    setShowCloudModal(false);
                  }
                } finally {
                  setSavingAi(false);
                }
              }}
            >
              {savingAi ? '保存中…' : '保存配置'}
            </SettingsButton>
          </>
        }
      >
        <SegmentedControl<CloudAIProviderKind>
          value={aiDraft.provider}
          onChange={(provider) =>
            setAiDraft(applySmartAIDefaults(aiDraft, provider, aiDraft.customEndpointFormat))
          }
          ariaLabel="云端 AI 服务商"
          options={[
            { value: 'disabled', label: '关闭（仅本机）' },
            { value: 'chatGPTSubscription', label: 'ChatGPT 订阅' },
            { value: 'gemini', label: 'Google Gemini' },
            { value: 'openAICompatible', label: '自定义兼容 API' },
          ]}
        />

        {aiDraft.provider === 'disabled' && (
          <div className="rounded-[var(--win-radius-card)] bg-[var(--settings-subtle)] border border-[var(--win-stroke-divider)] p-3 text-[12px] text-[var(--text-secondary)] leading-relaxed">
            关闭云端 AI 后，Charkle 仍会使用本机离线引擎完成配色提取、OCR 文字识别、相似推荐与拼音搜索。
          </div>
        )}

        {aiDraft.provider === 'chatGPTSubscription' && (
          <div className="flex flex-col gap-3">
            {session.status === 'connected' ? (
              <>
                <div className="rounded-[var(--win-radius-card)] bg-[var(--settings-subtle)] border border-[var(--win-stroke-divider)] p-3 flex items-center justify-between gap-3">
                  <div className="flex items-center gap-3 min-w-0">
                    <span className="h-9 w-9 rounded-full bg-[var(--settings-card)] border border-[var(--win-stroke-card)] inline-flex items-center justify-center shrink-0">
                      <ChatGPTBrandMark size={18} />
                    </span>
                    <div className="min-w-0">
                      <div className="flex items-center gap-1.5">
                        <span className="text-[13px] font-semibold text-[var(--text-primary)] truncate">
                          {session.name || session.email || 'ChatGPT'}
                        </span>
                        <SettingsStatusBadge
                          text={session.sharingEnabled ? '已授权' : '需授权共享'}
                          tone={session.sharingEnabled ? 'positive' : 'warning'}
                        />
                      </div>
                      {session.email && (
                        <div className="text-[11.5px] text-[var(--text-secondary)] truncate">
                          {session.email}
                        </div>
                      )}
                    </div>
                  </div>
                  <div className="flex items-center gap-1.5 shrink-0">
                    {session.sharingEnabled ? (
                      <SettingsButton
                        variant="standard"
                        onClick={() => void getTransport().openExternalUrl(CHATGPT_USAGE_URL)}
                      >
                        管理用量
                      </SettingsButton>
                    ) : (
                      <SettingsButton
                        variant="accent"
                        loading={signingInChatgpt}
                        onClick={() => void signInChatgpt(true, false)}
                      >
                        授权额度共享
                      </SettingsButton>
                    )}
                    <SettingsButton
                      variant="danger"
                      onClick={() => void disconnectChatgpt()}
                    >
                      退出
                    </SettingsButton>
                  </div>
                </div>

                {session.sharingEnabled && (
                  <>
                    <label className="flex items-center justify-between gap-3">
                      <span className="text-[12px] font-medium text-[var(--text-primary)]">
                        理解模型
                      </span>
                      <SettingsInput
                        type="text"
                        value={aiDraft.chatModel}
                        onChange={(e) => setAiDraft({ ...aiDraft, chatModel: e.target.value })}
                        placeholder="gpt-5.4-mini"
                        className="w-[220px]"
                      />
                    </label>
                    <div className="flex justify-end">
                      <button
                        type="button"
                        disabled={signingInChatgpt}
                        onClick={() => void signInChatgpt(false, true)}
                        className="text-[12px] font-medium text-[var(--text-secondary)] hover:text-[var(--text-primary)] cursor-pointer disabled:opacity-45"
                      >
                        切换其他 ChatGPT 账号…
                      </button>
                    </div>
                  </>
                )}
              </>
            ) : (
              <div className="rounded-[var(--win-radius-card)] bg-[var(--settings-subtle)] border border-[var(--win-stroke-divider)] p-3 flex items-center justify-between gap-3">
                <div className="flex items-center gap-3 min-w-0">
                  <ChatGPTBrandMark size={20} />
                  <div className="min-w-0">
                    <div className="text-[13px] font-semibold text-[var(--text-primary)]">
                      {session.status === 'reauthRequired'
                        ? 'ChatGPT 登录已过期'
                        : '直接登录你的 ChatGPT 账号'}
                    </div>
                    <div className="text-[11.5px] text-[var(--text-secondary)] mt-0.5">
                      无需申请 API 密钥，支持 Plus / Pro 等订阅额度，凭证仅保存在本机凭据管理器。
                    </div>
                  </div>
                </div>
                <SettingsButton
                  variant="accent"
                  loading={signingInChatgpt}
                  onClick={() => void signInChatgpt(false, false)}
                >
                  {signingInChatgpt ? '等待授权…' : '前往登录'}
                </SettingsButton>
              </div>
            )}
          </div>
        )}

        {aiDraft.provider === 'gemini' && (
          <div className="flex flex-col gap-3">
            <div className="flex flex-col gap-1">
              <div className="flex items-center justify-between gap-2">
                <span className="text-[11.5px] font-medium text-[var(--text-secondary)]">
                  Gemini API 密钥
                </span>
                <button
                  type="button"
                  onClick={() => void getTransport().openExternalUrl(GEMINI_KEY_URL)}
                  className="text-[11.5px] font-medium text-[var(--accent)] hover:underline inline-flex items-center gap-0.5 cursor-pointer"
                >
                  <span>前往 Google AI Studio 获取</span>
                  <Open16Regular className="w-3 h-3 shrink-0" />
                </button>
              </div>
              <div className="flex gap-2">
                <SettingsInput
                  type="password"
                  aria-label="云端 AI API 密钥"
                  value={apiKeyInput}
                  onChange={(e) => setApiKeyInput(e.target.value)}
                  placeholder={hasApiKey ? '••••••••（已安全保存，留空不变）' : '粘贴 AIza… 密钥'}
                  className="flex-1"
                />
                {hasApiKey && (
                  <SettingsButton
                    variant="secondary"
                    onClick={() => void saveAiConfig(aiDraft, { clearApiKey: true, quiet: true })}
                  >
                    清除密钥
                  </SettingsButton>
                )}
              </div>
            </div>

            <SettingsDisclosureGroup title="高级模型与地址参数（可选）">
              <label className="flex flex-col gap-1">
                <span className="text-[11.5px] font-medium text-[var(--text-secondary)]">
                  服务地址
                </span>
                <SettingsInput
                  type="text"
                  value={aiDraft.baseURL}
                  onChange={(e) => setAiDraft({ ...aiDraft, baseURL: e.target.value })}
                  placeholder="https://generativelanguage.googleapis.com"
                />
              </label>
              <label className="flex flex-col gap-1">
                <span className="text-[11.5px] font-medium text-[var(--text-secondary)]">
                  理解模型
                </span>
                <SettingsInput
                  type="text"
                  value={aiDraft.chatModel}
                  onChange={(e) => setAiDraft({ ...aiDraft, chatModel: e.target.value })}
                  placeholder="gemini-2.5-flash"
                />
              </label>
              <label className="flex flex-col gap-1">
                <span className="text-[11.5px] font-medium text-[var(--text-secondary)]">
                  搜索向量模型
                </span>
                <SettingsInput
                  type="text"
                  value={aiDraft.embeddingModel}
                  onChange={(e) => setAiDraft({ ...aiDraft, embeddingModel: e.target.value })}
                  placeholder="gemini-embedding-001"
                />
              </label>
            </SettingsDisclosureGroup>
          </div>
        )}

        {aiDraft.provider === 'openAICompatible' && (
          <div className="flex flex-col gap-2.5">
            <div className="flex flex-col gap-1.5">
              <span className="text-[11px] font-medium text-[var(--text-secondary)]">
                一键填充常见服务商预设
              </span>
              <div className="flex flex-wrap gap-1.5">
                {CUSTOM_ENDPOINT_PRESETS.map((preset) => (
                  <SettingsButton
                    key={preset.id}
                    variant="secondary"
                    onClick={() =>
                      setAiDraft({
                        ...aiDraft,
                        customEndpointFormat: preset.format,
                        baseURL: preset.baseURL,
                        chatModel: preset.chatModel,
                        embeddingModel: preset.embeddingModel,
                      })
                    }
                  >
                    {preset.label}
                  </SettingsButton>
                ))}
              </div>
            </div>

            <div className="flex flex-col gap-1">
              <span className="text-[11.5px] font-medium text-[var(--text-secondary)]">
                端点格式
              </span>
              <CustomSelect
                value={aiDraft.customEndpointFormat}
                onChange={(val) => {
                  const fmt = val as CustomAIEndpointFormat;
                  setAiDraft(applySmartAIDefaults(aiDraft, 'openAICompatible', fmt));
                }}
                ariaLabel="自定义接口端点格式"
                options={[
                  { value: 'openAIChatCompletions', label: 'OpenAI Chat Completions' },
                  { value: 'anthropicMessages', label: 'Anthropic Messages' },
                  { value: 'openAIResponses', label: 'OpenAI Responses' },
                ]}
              />
            </div>

            <label className="flex flex-col gap-1">
              <span className="text-[11.5px] font-medium text-[var(--text-secondary)]">
                服务地址（自动补全 /v1）
              </span>
              <SettingsInput
                type="text"
                value={aiDraft.baseURL}
                onChange={(e) => setAiDraft({ ...aiDraft, baseURL: e.target.value })}
                placeholder={defaultBaseURLForFormat(aiDraft.customEndpointFormat)}
              />
              {trimmedAiBaseUrl.length > 0 && isAiBaseUrlInvalid && (
                <span className="text-[11px] text-[var(--settings-warning)]">
                  请输入以 https:// 或 http:// 开头的有效服务地址
                </span>
              )}
            </label>

            <label className="flex flex-col gap-1">
              <span className="text-[11.5px] font-medium text-[var(--text-secondary)]">
                API 密钥（Ollama 本地可留空）
              </span>
              <div className="flex gap-2">
                <SettingsInput
                  type="password"
                  aria-label="云端 AI API 密钥"
                  value={apiKeyInput}
                  onChange={(e) => setApiKeyInput(e.target.value)}
                  placeholder={hasApiKey ? '••••••••（已安全保存，留空不变）' : '粘贴 API 密钥…'}
                  className="flex-1"
                />
                {hasApiKey && (
                  <SettingsButton
                    variant="secondary"
                    onClick={() => void saveAiConfig(aiDraft, { clearApiKey: true, quiet: true })}
                  >
                    清除密钥
                  </SettingsButton>
                )}
              </div>
            </label>

            <div className="grid grid-cols-2 gap-2.5">
              <label className="flex flex-col gap-1">
                <span className="text-[11.5px] font-medium text-[var(--text-secondary)]">
                  理解模型
                </span>
                <SettingsInput
                  type="text"
                  value={aiDraft.chatModel}
                  onChange={(e) => setAiDraft({ ...aiDraft, chatModel: e.target.value })}
                  placeholder={defaultChatModelForFormat(aiDraft.customEndpointFormat)}
                />
              </label>

              {aiDraft.customEndpointFormat !== 'anthropicMessages' && (
                <label className="flex flex-col gap-1">
                  <span className="text-[11.5px] font-medium text-[var(--text-secondary)]">
                    向量模型（可选）
                  </span>
                  <SettingsInput
                    type="text"
                    value={aiDraft.embeddingModel}
                    onChange={(e) => setAiDraft({ ...aiDraft, embeddingModel: e.target.value })}
                    placeholder="text-embedding-3-small"
                  />
                </label>
              )}
            </div>
          </div>
        )}

        {aiTestRes && (
          <div
            data-testid="ai-test-result"
            className={[
              'text-[12px] px-3 py-2 rounded-[var(--win-radius-control)] border',
              aiTestRes.ok
                ? 'bg-[var(--settings-positive)]/10 border-[var(--settings-positive)]/25 text-[var(--text-primary)]'
                : 'bg-[var(--settings-destructive)]/10 border-[var(--settings-destructive)]/25 text-[var(--settings-destructive)]',
            ].join(' ')}
          >
            {aiTestRes.providerLabel}：{aiTestRes.message}
            {aiTestRes.latencyMs > 0 ? `（${aiTestRes.latencyMs}ms）` : ''}
          </div>
        )}
      </SettingsSubModal>

      {/* Sheet 2: TypeSafe Visual Enhancement Configuration Modal */}
      <SettingsSubModal
        open={showTypeSafeModal}
        onClose={closeTypeSafeModal}
        title="进阶视觉定位引擎配置"
        subtitle="配置 TypeSafe 密钥并按需勾选视觉定位场景，密钥安全保存于 Windows 凭据管理器。"
        headerRight={
          <button
            type="button"
            onClick={() => void getTransport().openExternalUrl(TYPESAFE_HOME_URL)}
            className="text-[12px] font-medium text-[var(--accent)] hover:underline inline-flex items-center gap-0.5 cursor-pointer"
          >
            <span>获取密钥</span>
            <Open16Regular className="w-3 h-3 shrink-0" />
          </button>
        }
        width="md"
        footer={
          <>
            <SettingsButton
              variant="standard"
              disabled={savingTs || testingTypesafe}
              onClick={closeTypeSafeModal}
            >
              取消
            </SettingsButton>
            <SettingsButton
              variant="standard"
              loading={testingTypesafe}
              disabled={savingTs || isTsBaseUrlInvalid}
              onClick={async () => {
                const trimmed = tsKeyInput.trim();
                const ok = await saveTypesafeConfig(
                  { ...tsDraft, baseURL: trimmedTsBaseUrl || 'https://api.typesafe.ai' },
                  { apiKey: trimmed || null, quiet: true },
                );
                if (!ok) return;
                if (trimmed) setTsKeyInput('');
                setTsTestRes(await testTypesafeConnection());
              }}
            >
              {testingTypesafe ? '测试中…' : '测试连接'}
            </SettingsButton>
            <SettingsButton
              variant="accent"
              loading={savingTs}
              disabled={testingTypesafe || isTsBaseUrlInvalid}
              onClick={async () => {
                setSavingTs(true);
                try {
                  const trimmed = tsKeyInput.trim();
                  const ok = await saveTypesafeConfig(
                    { ...tsDraft, baseURL: trimmedTsBaseUrl || 'https://api.typesafe.ai' },
                    { apiKey: trimmed || null },
                  );
                  if (ok) {
                    setTsKeyInput('');
                    setShowTypeSafeModal(false);
                  }
                } finally {
                  setSavingTs(false);
                }
              }}
            >
              {savingTs ? '保存中…' : '保存配置'}
            </SettingsButton>
          </>
        }
      >
        <div className="flex flex-col gap-1">
          <span className="text-[11.5px] font-medium text-[var(--text-secondary)]">
            TypeSafe API 密钥
          </span>
          <div className="flex gap-2">
            <SettingsInput
              type="password"
              aria-label="TypeSafe API 密钥"
              value={tsKeyInput}
              onChange={(e) => setTsKeyInput(e.target.value)}
              placeholder={hasTypeSafeKey ? '••••••••（已安全保存，留空不变）' : '粘贴 apikey_…'}
              className="flex-1"
            />
            {hasTypeSafeKey && (
              <SettingsButton
                variant="standard"
                onClick={() => void saveTypesafeConfig(tsDraft, { clearApiKey: true, quiet: true })}
              >
                清除
              </SettingsButton>
            )}
          </div>
        </div>

        <div className="grid grid-cols-2 gap-3">
          <div className="flex flex-col gap-1">
            <span className="text-[11.5px] font-medium text-[var(--text-secondary)]">
              视觉定位模型
            </span>
            <div className="flex gap-1.5">
              <SettingsInput
                type="text"
                value={tsDraft.model}
                onChange={(e) => setTsDraft({ ...tsDraft, model: e.target.value })}
                placeholder="jev-latest"
                className="flex-1 min-w-0"
              />
              {typesafeModels.length > 0 && (
                <div className="w-[120px] shrink-0">
                  <CustomSelect
                    value={tsDraft.model}
                    onChange={(model) => setTsDraft({ ...tsDraft, model })}
                    ariaLabel="选择视觉定位模型"
                    options={typesafeModels.map((m) => ({ value: m.name, label: m.name }))}
                  />
                </div>
              )}
            </div>
          </div>

          <div className="flex flex-col gap-1 justify-center">
            <div className="flex items-center justify-between text-[11.5px] font-medium text-[var(--text-secondary)]">
              <span>低置信度防切边阈值</span>
              <span className="charkle-tabular text-[var(--text-primary)]">
                {Math.round(tsDraft.minConfidence * 100)}%
              </span>
            </div>
            <CharkleSlider
              variant="standard"
              min={0.3}
              max={0.9}
              step={0.05}
              value={tsDraft.minConfidence}
              valueText={`${Math.round(tsDraft.minConfidence * 100)}%`}
              ariaLabel="低置信度防切边阈值"
              onChange={(next) => setTsDraft({ ...tsDraft, minConfidence: next })}
              className="w-full mt-0.5"
            />
          </div>
        </div>

        <div className="rounded-[var(--win-radius-card)] bg-[var(--settings-subtle)] border border-[var(--win-stroke-card)] overflow-hidden max-h-[240px] overflow-y-auto charkle-scroll">
          {(
            [
              {
                key: 'enableMoodboardFocusCrop',
                title: '情绪板语义局部裁切',
                subtitle: '右键支持「聚焦主体」与「一句话语义裁切」，非破坏性保留原图',
                checked: tsDraft.enableMoodboardFocusCrop,
                onChange: (v: boolean) => setTsDraft({ ...tsDraft, enableMoodboardFocusCrop: v }),
              },
              {
                key: 'enableAutoCleanCrop',
                title: '截图与网页自动去噪裁净',
                subtitle: '自动识别浏览器外壳、状态栏与白边并裁净核心作品',
                checked: tsDraft.enableAutoCleanCrop,
                onChange: (v: boolean) => setTsDraft({ ...tsDraft, enableAutoCleanCrop: v }),
              },
              {
                key: 'enableSubjectPalette',
                title: '主体色板提取与指物批注',
                subtitle: '过滤背景干扰色提取主体色卡，批注箭头自动指向目标物体',
                checked: tsDraft.enableSubjectPalette,
                onChange: (v: boolean) =>
                  setTsDraft({
                    ...tsDraft,
                    enableSubjectPalette: v,
                    enablePinpointAnnotations: v,
                  }),
              },
              {
                key: 'enableSemanticSearch',
                title: '自然语言看图语义搜索',
                subtitle: '在搜索栏直接按氛围与画面内容检索，未打标素材也能命中',
                checked: tsDraft.enableSemanticSearch,
                onChange: (v: boolean) => setTsDraft({ ...tsDraft, enableSemanticSearch: v }),
              },
              {
                key: 'enableInboxSmartTriage',
                title: '收件箱智能归档分拣',
                subtitle: '将待整理素材精准推荐到最匹配的已有文件夹',
                checked: tsDraft.enableInboxSmartTriage,
                onChange: (v: boolean) => setTsDraft({ ...tsDraft, enableInboxSmartTriage: v }),
              },
              {
                key: 'enableCuratorVisualRerank',
                title: '情绪板策展视觉精排',
                subtitle: '对候选池进行视觉相关度精排，并支持细节特写生板模式',
                checked: tsDraft.enableCuratorVisualRerank,
                onChange: (v: boolean) => setTsDraft({ ...tsDraft, enableCuratorVisualRerank: v }),
              },
            ] as const
          ).map((item, idx) => (
            <React.Fragment key={item.key}>
              {idx > 0 && <SettingsCardDivider />}
              <div className="px-3 py-2.5 flex items-center justify-between gap-3">
                <div className="min-w-0">
                  <div className="text-[12.5px] font-medium text-[var(--text-primary)]">
                    {item.title}
                  </div>
                  <div className="text-[11.5px] text-[var(--text-secondary)]">{item.subtitle}</div>
                </div>
                <SettingsSwitch
                  checked={item.checked}
                  ariaLabel={item.title}
                  onChange={item.onChange}
                />
              </div>
            </React.Fragment>
          ))}
        </div>

        <SettingsDisclosureGroup title="自定义服务地址（可选）">
          <label className="flex flex-col gap-1">
            <span className="text-[11.5px] font-medium text-[var(--text-secondary)]">
              自定义服务地址（默认 https://api.typesafe.ai）
            </span>
            <SettingsInput
              type="text"
              value={tsDraft.baseURL}
              onChange={(e) => setTsDraft({ ...tsDraft, baseURL: e.target.value })}
              placeholder="https://api.typesafe.ai"
            />
            {isTsBaseUrlInvalid && (
              <span className="text-[11px] text-[var(--settings-warning)]">
                请输入以 https:// 或 http:// 开头的有效服务地址
              </span>
            )}
          </label>
        </SettingsDisclosureGroup>

        {tsTestRes && (
          <div
            className={[
              'text-[12px] px-3 py-2 rounded-[var(--win-radius-control)] border',
              tsTestRes.ok
                ? 'bg-[var(--settings-positive)]/10 border-[var(--settings-positive)]/25 text-[var(--text-primary)]'
                : 'bg-[var(--settings-destructive)]/10 border-[var(--settings-destructive)]/25 text-[var(--settings-destructive)]',
            ].join(' ')}
          >
            {tsTestRes.message}
          </div>
        )}
      </SettingsSubModal>

      {/* Sheet 3: Usage Detail Modal */}
      <SettingsSubModal
        open={showUsageModal}
        onClose={() => setShowUsageModal(false)}
        title="云端 AI 用量明细"
        subtitle="记录保存于本机，分别统计普通云端模型与视觉定位引擎的调用消耗。"
        headerRight={
          allTotalRequests > 0 ? (
            <SettingsButton variant="danger" onClick={() => void resetAiUsage(null)}>
              全部清零
            </SettingsButton>
          ) : undefined
        }
        width="md"
        footer={
          <SettingsButton variant="accent" onClick={() => setShowUsageModal(false)}>
            完成
          </SettingsButton>
        }
      >
        <UsageBucketCard
          title="普通云端模型"
          subtitle="画面理解、标签建议与情绪板策展"
          bucket={usage?.standard}
          emptyHint="调用 ChatGPT / Gemini / 自定义模型后将记录在此。"
          onReset={() => void resetAiUsage('standard')}
        />
        <UsageBucketCard
          title="视觉定位引擎（TypeSafe）"
          subtitle="语义局部裁切、去噪、视觉评分与智能分拣"
          bucket={usage?.jev}
          emptyHint="开启并调用视觉定位引擎后将单独记录在此。"
          onReset={() => void resetAiUsage('jev')}
        />
      </SettingsSubModal>
    </div>
  );
};

const UsageBucketCard: React.FC<{
  title: string;
  subtitle: string;
  bucket?: CloudAIUsageBucket;
  emptyHint: string;
  onReset: () => void;
}> = ({ title, subtitle, bucket, emptyHint, onReset }) => (
  <div className="rounded-[var(--win-radius-card)] bg-[var(--settings-subtle)] border border-[var(--win-stroke-card)] p-3.5 flex flex-col gap-2.5">
    <div className="flex items-center justify-between gap-2">
      <div className="min-w-0">
        <div className="text-[13px] font-semibold text-[var(--text-primary)]">{title}</div>
        <div className="text-[11.5px] text-[var(--text-secondary)]">{subtitle}</div>
      </div>
      {(bucket?.totalRequests ?? 0) > 0 && (
        <SettingsButton variant="standard" size="xs" onClick={onReset}>
          清零
        </SettingsButton>
      )}
    </div>

    <div className="grid grid-cols-3 gap-2">
      <div className="rounded-[var(--win-radius-control)] bg-[var(--settings-card)] border border-[var(--win-stroke-divider)] p-2.5">
        <div className="text-[11px] font-medium text-[var(--text-secondary)]">今日调用</div>
        <div className="text-[14px] font-semibold text-[var(--text-primary)] charkle-tabular mt-0.5">
          {bucket?.todayRequests ?? 0} 次
        </div>
        <div className="text-[10.5px] text-[var(--text-tertiary)] charkle-tabular truncate">
          Token {formatTokenCount(bucket?.todayTotalTokens ?? 0)}
        </div>
      </div>
      <div className="rounded-[var(--win-radius-control)] bg-[var(--settings-card)] border border-[var(--win-stroke-divider)] p-2.5">
        <div className="text-[11px] font-medium text-[var(--text-secondary)]">累计调用</div>
        <div className="text-[14px] font-semibold text-[var(--text-primary)] charkle-tabular mt-0.5">
          {bucket?.totalRequests ?? 0} 次
        </div>
        <div className="text-[10.5px] text-[var(--text-tertiary)] truncate">
          {bucket?.lastModel || '尚未调用'}
        </div>
      </div>
      <div className="rounded-[var(--win-radius-control)] bg-[var(--settings-card)] border border-[var(--win-stroke-divider)] p-2.5">
        <div className="text-[11px] font-medium text-[var(--text-secondary)]">累计 Token</div>
        <div className="text-[14px] font-semibold text-[var(--text-primary)] charkle-tabular mt-0.5">
          {formatTokenCount(bucket?.totalTokens ?? 0)}
        </div>
        <div className="text-[10.5px] text-[var(--text-tertiary)] charkle-tabular truncate">
          入 {formatTokenCount(bucket?.totalInputTokens ?? 0)} / 出{' '}
          {formatTokenCount(bucket?.totalOutputTokens ?? 0)}
        </div>
      </div>
    </div>

    <div className="text-[11px] text-[var(--text-tertiary)]">
      {bucket?.lastUsedAt
        ? `最近调用：${bucket.lastProviderLabel || title}${bucket.lastModel ? ` (${bucket.lastModel})` : ''} · ${relativeTimeText(bucket.lastUsedAt)}`
        : emptyHint}
    </div>
  </div>
);

// =========================================================================
// Pane 7: 外部 Agent (ExternalAgentsSettingsPane) — mirrors ExternalAgentsSettingsPane.swift 1:1
// =========================================================================

const SAMPLE_PROMPTS: Array<{ title: string; prompt: string }> = [
  {
    title: '找参考图并建情绪板',
    prompt:
      '帮我从 Charkle 素材库里挑 10 张温暖胶片质感、偏奶油色调的咖啡馆参考图，先用联系表看图确认无重复，再生成一块名为「早秋咖啡馆视觉」的情绪板。',
  },
  {
    title: '智能整理收件箱',
    prompt:
      '帮我用联系表和文件夹推荐看看 Charkle 收件箱里未整理的素材，按画面风格建议归档到现有文件夹，并补齐统一标签。',
  },
  {
    title: '提取情绪板色板与 AI 配方',
    prompt:
      '读取我在 Charkle 里名为「品牌改版」的情绪板，导出主色板 HEX、分区批注与其中 AI 参考图的生成 Prompt，帮我整理成设计规范。',
  },
];

export const ExternalAgentsSettingsPane: React.FC = () => {
  const agentState = useSyncAIStore((s) => s.agentState);
  const runningSelfCheck = useSyncAIStore((s) => s.runningAgentSelfCheck);
  const selfCheckPassed = useSyncAIStore((s) => s.agentSelfCheckPassed);
  const selfCheckSummary = useSyncAIStore((s) => s.agentSelfCheckSummary);
  const saveExternalAgentConfig = useSyncAIStore((s) => s.saveExternalAgentConfig);
  const runExternalAgentSelfCheck = useSyncAIStore((s) => s.runExternalAgentSelfCheck);
  const setStatusFeedback = useSyncAIStore((s) => s.setStatusFeedback);
  const pushToast = useCoordinatorStore((s) => s.pushToast);

  const cfg = agentState?.config ?? {
    mcpEnabled: true,
    cliEnabled: true,
    accessLevel: 'readOnly' as ExternalAgentAccessLevel,
  };

  const helperPath = agentState?.cliBinaryPath ?? 'charkle-cli.exe';
  const libraryDir = agentState?.libraryDir ?? '';
  const totalTools = (agentState?.readToolCount ?? 12) + (agentState?.writeToolCount ?? 8);
  const resourceCount = agentState?.resourceCount ?? 6;
  const claudeCodeCmd = libraryDir
    ? `claude mcp add charkle -- "${helperPath}" --library-dir "${libraryDir}" mcp`
    : `claude mcp add charkle -- "${helperPath}" mcp`;
  const codexCmd = libraryDir
    ? `codex mcp add charkle -- "${helperPath}" --library-dir "${libraryDir}" mcp`
    : `codex mcp add charkle -- "${helperPath}" mcp`;
  const mcpJson = agentState?.mcpConfigJson ?? '';

  const updatePolicy = (patch: Partial<typeof cfg>) => {
    void saveExternalAgentConfig({ ...cfg, ...patch });
  };

  const copyText = async (text: string, toastMsg: string) => {
    try {
      await navigator.clipboard?.writeText(text);
      setStatusFeedback(toastMsg, null);
      pushToast({ message: toastMsg, tone: 'success' });
    } catch {
      const msg = '复制到剪贴板失败';
      setStatusFeedback(null, msg);
      pushToast({ message: msg, tone: 'error' });
    }
  };

  return (
    <div data-testid="settings-pane-externalAgents" className="flex flex-col gap-5">
      {/* 1. Service Switches & Safety Boundary */}
      <SettingsSection title="服务开关与安全边界">
        <SettingsRow
          title="启用 MCP 服务"
          subtitle={
            cfg.mcpEnabled
              ? `原生 MCP 助手已就绪 · ${totalTools} 项安全工具与 ${resourceCount} 项资源，零额外运行时依赖`
              : '已关闭 · 所有 MCP 客户端请求将被即时拦截（不影响终端 CLI）'
          }
          subtitleTone={cfg.mcpEnabled ? 'positive' : 'default'}
        >
          <SettingsStatusBadge
            text={cfg.mcpEnabled ? '已开启' : '已关闭'}
            tone={cfg.mcpEnabled ? 'positive' : 'neutral'}
          />
          <SettingsSwitch
            checked={cfg.mcpEnabled}
            ariaLabel="启用 MCP 服务"
            onChange={(mcpEnabled) => updatePolicy({ mcpEnabled })}
          />
        </SettingsRow>

        <SettingsCardDivider />

        <SettingsRow
          title="启用 CLI 命令行服务"
          subtitle={
            cfg.cliEnabled
              ? '已开放终端命令行 · 支持脚本查询、整理与情绪板导出'
              : '已关闭 · 终端 charkle 读写命令将被即时拦截（不影响 MCP 客户端）'
          }
          subtitleTone={cfg.cliEnabled ? 'positive' : 'default'}
        >
          <SettingsStatusBadge
            text={cfg.cliEnabled ? '已开启' : '已关闭'}
            tone={cfg.cliEnabled ? 'positive' : 'neutral'}
          />
          <SettingsSwitch
            checked={cfg.cliEnabled}
            ariaLabel="启用 CLI 命令行服务"
            onChange={(cliEnabled) => updatePolicy({ cliEnabled })}
          />
        </SettingsRow>

        {(cfg.mcpEnabled || cfg.cliEnabled) && (
          <>
            <SettingsCardDivider />

            <SettingsRow
              title="外部访问权限级别"
              subtitle={
                cfg.accessLevel === 'readWriteOrganize'
                  ? '允许归类、打标、创建文件夹与生成情绪板，仍永久禁止彻底删除文件'
                  : '仅允许查询、语义检索、看联系表与导出，禁止写入素材库'
              }
            >
              <SegmentedControl<ExternalAgentAccessLevel>
                value={cfg.accessLevel}
                onChange={(accessLevel) => updatePolicy({ accessLevel })}
                ariaLabel="外部 Agent 权限级别"
                options={[
                  { value: 'readOnly', label: '仅只读' },
                  { value: 'readWriteOrganize', label: '允许整理与生板' },
                ]}
              />
            </SettingsRow>

            <SettingsCardDivider />

            <SettingsRow
              title="原生助手与数据库连通自检"
              subtitle={
                selfCheckSummary ??
                `验证内置 charkle 助手程序、本地素材库与 ${totalTools} 项安全工具连通性`
              }
              subtitleTone={
                selfCheckPassed == null ? 'default' : selfCheckPassed ? 'positive' : 'warning'
              }
            >
              <SettingsButton
                variant="secondary"
                loading={runningSelfCheck}
                onClick={() => void runExternalAgentSelfCheck()}
              >
                {runningSelfCheck ? '自检中…' : '运行自检'}
              </SettingsButton>
            </SettingsRow>

            <InlineGuideDisclosure title="数据安全如何保障？">
              <SettingsGuideStep
                number="1"
                title="MCP 与 CLI 独立管控，关闭即刻生效"
                detail="可按需只保留其中一项服务；关闭任意开关后，对应通道的新请求会立即被拦截。"
              />
              <SettingsGuideStep
                number="2"
                title="永不开放公网或局域网端口"
                detail="所有调用均通过本机标准输入输出（stdio）或本地 CLI 与素材库通信，外部网络无法访问。"
              />
              <SettingsGuideStep
                number="3"
                title="永不允许彻底删除素材或文件夹"
                detail="即使开启「允许整理与生板」，外部 Agent 也只能将素材移入回收站，随时可恢复。"
              />
            </InlineGuideDisclosure>
          </>
        )}
      </SettingsSection>

      {/* 2. MCP Client Integration */}
      <SettingsSection
        title="接入常用 AI 客户端（MCP）"
        caption={cfg.mcpEnabled ? undefined : 'MCP 服务已关闭 · 开启上方开关后生效'}
        className={cfg.mcpEnabled ? '' : 'opacity-72'}
      >
        <SettingsRow
          title="Claude Code"
          subtitle="在终端执行一行命令即可将 Charkle 注册为原生 MCP 工具"
        >
          <SettingsButton
            variant="accent"
            onClick={() => void copyText(claudeCodeCmd, '已复制 Claude Code 接入命令')}
          >
            一键复制命令
          </SettingsButton>
        </SettingsRow>

        <InlineGuideDisclosure title="查看 Claude Code / Codex CLI 接入命令">
          <SettingsCodeSnippet text={`${claudeCodeCmd}\n${codexCmd}`} />
          <SettingsGuideStep
            number="1"
            title="在终端粘贴运行对应命令，完成后重启对话"
            detail="输入「看看我的 Charkle 素材库概览」即可验证连通。"
          />
        </InlineGuideDisclosure>

        <SettingsCardDivider />

        <SettingsRow
          title="Cursor / Antigravity / 其他 MCP 客户端"
          subtitle="复制标准 MCP JSON 配置粘贴至对应客户端的配置文件"
        >
          <SettingsButton
            variant="standard"
            onClick={() => void copyText(mcpJson, '已复制 MCP JSON 配置')}
          >
            <Copy16Regular className="w-3.5 h-3.5 shrink-0" />
            复制 JSON 配置
          </SettingsButton>
        </SettingsRow>

        <InlineGuideDisclosure title="查看 MCP JSON 配置片段" defaultExpanded>
          <SettingsCodeSnippet text={mcpJson} testId="mcp-config-json-snippet" />
        </InlineGuideDisclosure>
      </SettingsSection>

      {/* 3. Terminal CLI */}
      <SettingsSection
        title="终端命令行（charkle CLI）"
        caption={cfg.cliEnabled ? undefined : 'CLI 服务已关闭 · 开启上方开关后生效'}
        className={cfg.cliEnabled ? '' : 'opacity-72'}
      >
        <SettingsRow
          title="本机命令行程序路径"
          subtitle={<span className="charkle-mono text-[11px] break-all">{helperPath}</span>}
        >
          <SettingsButton
            variant="standard"
            onClick={() => void copyText(helperPath, '已复制 charkle 可执行文件路径')}
          >
            <Copy16Regular className="w-3.5 h-3.5 shrink-0" />
            复制路径
          </SettingsButton>
        </SettingsRow>

        <InlineGuideDisclosure title="常用命令行示例（交互终端自动排版，管道自动输出 JSON）">
          <SettingsCodeSnippet
            text={[
              'charkle-cli.exe doctor',
              'charkle-cli.exe overview',
              'charkle-cli.exe search "暖调陶艺" --subfolders --limit 20',
              'charkle-cli.exe semantic "极简陶瓷质感" --limit 12',
              'charkle-cli.exe similar <asset-uuid> --limit 8',
              'charkle-cli.exe inbox --suggest',
              'charkle-cli.exe contact-sheet --inbox --out inbox.jpg',
              'charkle-cli.exe board patch <board-id> --add-note "配色已定稿"',
              'charkle-cli.exe board export <board-id> --out board.png --dark',
            ].join('\n')}
          />
        </InlineGuideDisclosure>
      </SettingsSection>

      {/* 4. Usage Guide & Copyable Prompts */}
      <SettingsSection title="使用指南">
        <SettingsRow
          title={`已开放的外部 Agent 能力（${totalTools} 项安全工具 · ${resourceCount} 项资源）`}
          subtitle="分页多维检索 / 语义与以图找图 / 联系表看图 / 读取 EXIF 与 AI 生图 Prompt / 情绪板色板与非重叠补丁 / 实时热刷新窗口"
        />

        <InlineGuideDisclosure title="不知道怎么跟 AI 开口？查看 3 条推荐对话示例">
          <div className="flex flex-col gap-2.5">
            {SAMPLE_PROMPTS.map((item) => (
              <div key={item.title} className="flex items-start justify-between gap-2.5">
                <div className="min-w-0 flex flex-col gap-0.5">
                  <span className="text-[11.5px] font-semibold text-[var(--text-primary)]">
                    {item.title}
                  </span>
                  <span className="text-[11px] text-[var(--text-secondary)] leading-relaxed">
                    “{item.prompt}”
                  </span>
                </div>
                <SettingsButton
                  variant="secondary"
                  onClick={() => void copyText(item.prompt, '已复制示例提示词')}
                >
                  复制
                </SettingsButton>
              </div>
            ))}
          </div>
        </InlineGuideDisclosure>
      </SettingsSection>
    </div>
  );
};
