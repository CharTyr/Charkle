import React, { useEffect, useState } from 'react';
import {
  CheckCircle2,
  ExternalLink,
  PlugZap,
  RefreshCw,
  RotateCcw,
  Sparkles,
  XCircle,
} from 'lucide-react';
import {
  CUSTOM_AI_ENDPOINT_FORMATS,
  cloudAIProviderLocalizedLabel,
  customAIEndpointDefaultBaseURL,
  customAIEndpointDefaultChatModel,
  customAIEndpointDefaultEmbeddingModel,
  customAIEndpointLocalizedLabel,
  customAIEndpointSupportsEmbeddings,
  formatTokenCount,
  getChatGPTAccountDisplayName,
} from '@charkle/shared';
import type {
  AIProviderConfig,
  CloudAIProviderKind,
  CloudAIUsageBucket,
  CustomAIEndpointFormat,
  TypeSafeExperimentalConfig,
} from '@charkle/shared';
import { ModalShell } from '../../design-system/ModalShell';
import { useCoordinatorStore } from '../../stores/coordinatorStore';
import { useSyncAIStore } from '../../stores/syncAIStore';
import {
  ChatGPTBrandMark,
  InlineGuideDisclosure,
  SETTINGS_LINKS,
  SettingsButton,
  SettingsCardDivider,
  SettingsGuideStep,
  SettingsInput,
  SettingsRow,
  SettingsSection,
  SettingsSegmented,
  SettingsSelect,
  SettingsStatusBadge,
  SettingsSwitch,
} from './SettingsChrome';
import { formatRelativeDate } from './shortcuts';

const BUILTIN_CAPABILITIES = [
  '自动配色提取',
  '视觉相似推荐',
  '图内文字检索',
  '中文与拼音快搜',
] as const;

const PROVIDER_SEGMENT_OPTIONS: ReadonlyArray<{ id: CloudAIProviderKind; label: string }> = [
  { id: 'disabled', label: '关闭' },
  { id: 'chatGPTSubscription', label: 'ChatGPT 订阅' },
  { id: 'gemini', label: 'Google Gemini' },
  { id: 'openAICompatible', label: '自定义 API' },
];

interface CustomPreset {
  id: string;
  label: string;
  format: CustomAIEndpointFormat;
  baseURL: string;
  chatModel: string;
  embeddingModel: string;
}

const CUSTOM_API_PRESETS: readonly CustomPreset[] = [
  {
    id: 'openai',
    label: 'OpenAI',
    format: 'openAIChatCompletions',
    baseURL: 'https://api.openai.com',
    chatModel: 'gpt-4.1-mini',
    embeddingModel: 'text-embedding-3-small',
  },
  {
    id: 'claude',
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
    baseURL: 'https://openrouter.ai/api',
    chatModel: 'google/gemini-2.5-flash',
    embeddingModel: 'openai/text-embedding-3-small',
  },
  {
    id: 'deepseek',
    label: 'DeepSeek',
    format: 'openAIChatCompletions',
    baseURL: 'https://api.deepseek.com',
    chatModel: 'deepseek-chat',
    embeddingModel: '',
  },
  {
    id: 'ollama',
    label: 'Ollama 本地',
    format: 'openAIChatCompletions',
    baseURL: 'http://127.0.0.1:11434',
    chatModel: 'qwen2.5vl:7b',
    embeddingModel: 'nomic-embed-text',
  },
];

const JEV_SCENARIO_TOGGLES: ReadonlyArray<{
  key: keyof Pick<
    TypeSafeExperimentalConfig,
    | 'enableMoodboardFocusCrop'
    | 'enableAutoCleanCrop'
    | 'enableSubjectPalette'
    | 'enablePinpointAnnotations'
    | 'enableSemanticSearch'
    | 'enableInboxSmartTriage'
    | 'enableCuratorVisualRerank'
  >;
  label: string;
  desc: string;
}> = [
  { key: 'enableMoodboardFocusCrop', label: '情绪板智能聚焦裁切', desc: '按主体或描述生成非破坏性局部裁切框' },
  { key: 'enableAutoCleanCrop', label: '自动去杂边裁净', desc: '自动识别截图与扫描图多余边框并裁切主体' },
  { key: 'enableSubjectPalette', label: '按主体提取色卡', desc: '仅针对画面前景主体区域提取主色调' },
  { key: 'enablePinpointAnnotations', label: '指物精准批注', desc: '定位画面局部元素并生成连线便签' },
  { key: 'enableSemanticSearch', label: '语义搜图视觉精排', desc: '结合文本与画面内容优化自然语言搜索排序' },
  { key: 'enableInboxSmartTriage', label: '收件箱批量智能分拣', desc: '按现有目录结构自动给出归档建议' },
  { key: 'enableCuratorVisualRerank', label: '情绪板候选图评分', desc: '生成情绪板时对候选素材进行视觉评分筛选' },
];

function isLocalhostURL(raw: string): boolean {
  try {
    const parsed = new URL(raw);
    return (
      parsed.hostname === '127.0.0.1' ||
      parsed.hostname === 'localhost' ||
      parsed.hostname === '::1'
    );
  } catch {
    return false;
  }
}

export const AISettingsPane: React.FC = () => {
  const aiConfig = useSyncAIStore((s) => s.aiConfig);
  const hasStoredAIKeys = useSyncAIStore((s) => s.hasStoredAIKeys);
  const aiUsage = useSyncAIStore((s) => s.aiUsage);
  const chatGPTSession = useSyncAIStore((s) => s.chatGPTSession);
  const isTestingAI = useSyncAIStore((s) => s.isTestingAI);
  const typeSafeConfig = useSyncAIStore((s) => s.typeSafeConfig);
  const hasStoredTypeSafeKey = useSyncAIStore((s) => s.hasStoredTypeSafeKey);

  const loadAIConfig = useSyncAIStore((s) => s.loadAIConfig);
  const saveAIConfig = useSyncAIStore((s) => s.saveAIConfig);
  const testAIConnection = useSyncAIStore((s) => s.testAIConnection);
  const loadTypeSafeConfig = useSyncAIStore((s) => s.loadTypeSafeConfig);
  const saveTypeSafeConfig = useSyncAIStore((s) => s.saveTypeSafeConfig);
  const testTypeSafeConnection = useSyncAIStore((s) => s.testTypeSafeConnection);
  const pushToast = useCoordinatorStore((s) => s.pushToast);

  const [cloudModalOpen, setCloudModalOpen] = useState(false);
  const [cloudModalInitialProvider, setCloudModalInitialProvider] =
    useState<CloudAIProviderKind | null>(null);
  const [typeSafeModalOpen, setTypeSafeModalOpen] = useState(false);
  const [usageModalOpen, setUsageModalOpen] = useState(false);
  const [testingJev, setTestingJev] = useState(false);

  useEffect(() => {
    void loadAIConfig();
    void loadTypeSafeConfig();
  }, [loadAIConfig, loadTypeSafeConfig]);

  const isCloudReady =
    (aiConfig.provider === 'chatGPTSubscription' &&
      (chatGPTSession?.status === 'connected' || hasStoredAIKeys.chatGPTSubscription)) ||
    (aiConfig.provider === 'gemini' && hasStoredAIKeys.gemini) ||
    (aiConfig.provider === 'openAICompatible' &&
      (hasStoredAIKeys.openAICompatible || isLocalhostURL(aiConfig.baseURL)));

  const enabledJevCount = JEV_SCENARIO_TOGGLES.filter((sc) => typeSafeConfig[sc.key]).length;

  const openCloudConfig = (preferred?: CloudAIProviderKind) => {
    setCloudModalInitialProvider(preferred ?? null);
    setCloudModalOpen(true);
  };

  const handleQuickTestCloud = async () => {
    try {
      const summary = await testAIConnection(aiConfig, null);
      pushToast({ tone: 'success', message: summary || '云端 AI 连接测试通过' });
    } catch (err) {
      pushToast({
        tone: 'error',
        message: err instanceof Error ? err.message : '云端 AI 连接测试失败',
      });
    }
  };

  const handleToggleAIPreference = async (patch: Partial<AIProviderConfig>) => {
    try {
      await saveAIConfig({ ...aiConfig, ...patch }, null);
    } catch (err) {
      pushToast({
        tone: 'error',
        message: err instanceof Error ? err.message : '更新 AI 偏好失败',
      });
    }
  };

  const handleToggleTypeSafeMaster = async (enabled: boolean) => {
    try {
      await saveTypeSafeConfig({ ...typeSafeConfig, enabled }, null);
      pushToast({
        tone: 'info',
        message: enabled ? '已开启进阶视觉定位引擎' : '已关闭进阶视觉定位引擎',
      });
    } catch (err) {
      pushToast({
        tone: 'error',
        message: err instanceof Error ? err.message : '更新视觉定位开关失败',
      });
    }
  };

  const handleQuickTestJev = async () => {
    setTestingJev(true);
    try {
      const models = await testTypeSafeConnection(typeSafeConfig, null);
      pushToast({
        tone: 'success',
        message: `视觉定位引擎连接正常，检测到 ${models.length} 个可用模型`,
      });
    } catch (err) {
      pushToast({
        tone: 'error',
        message: err instanceof Error ? err.message : '视觉定位引擎连接测试失败',
      });
    } finally {
      setTestingJev(false);
    }
  };

  const cloudSubtitle = (() => {
    if (aiConfig.provider === 'chatGPTSubscription') {
      const acct =
        chatGPTSession?.status === 'connected'
          ? `${getChatGPTAccountDisplayName(chatGPTSession)} · `
          : '';
      return `${acct}模型：${aiConfig.chatModel || 'gpt-5-mini'}`;
    }
    return `模型：${aiConfig.chatModel || '默认'}${aiConfig.embeddingModel ? ` · 向量：${aiConfig.embeddingModel}` : ''}`;
  })();

  return (
    <div className="flex flex-col gap-[22px]">
      {/* 1. 基础离线能力 */}
      <SettingsSection title="基础离线能力" caption="免费内置 · 无需下载模型">
        <div className="px-4 py-3 flex flex-wrap items-center gap-2">
          {BUILTIN_CAPABILITIES.map((cap) => (
            <span
              key={cap}
              className="inline-flex items-center gap-1.5 px-2.5 py-1 rounded-full bg-[var(--settings-subtle,var(--bg-subtle))] border border-[var(--settings-border,var(--border-hairline))] text-[11.5px] font-medium text-[var(--text-primary)]"
            >
              <CheckCircle2 size={12} className="text-[var(--settings-positive,var(--success))] shrink-0" />
              {cap}
            </span>
          ))}
        </div>
      </SettingsSection>

      {/* 2. 云端增强智能 */}
      <SettingsSection title="云端增强智能">
        {!isCloudReady ? (
          <>
            <SettingsRow
              title={aiConfig.provider === 'disabled' ? '尚未接入云端增强模型' : '待完成连接配置'}
              subtitle="接入后可解锁自然语言搜图、导入自动识图打标与智能生成情绪板"
            >
              <SettingsButton variant="secondary" onClick={() => openCloudConfig('gemini')}>
                <Sparkles size={12} />
                Gemini / 自定义 API…
              </SettingsButton>
              <SettingsButton
                variant="primary"
                onClick={() => openCloudConfig('chatGPTSubscription')}
              >
                <ChatGPTBrandMark size={13} />
                连接 ChatGPT…
              </SettingsButton>
            </SettingsRow>

            <InlineGuideDisclosure title="各方案怎么选？如何获取 API 密钥">
              <SettingsGuideStep
                number={1}
                title="Google Gemini（上手最省心）"
                detail="前往 Google AI Studio 即可免费申请 API Key，支持识图与语义搜图，适合个人日常使用。"
              />
              <SettingsGuideStep
                number={2}
                title="ChatGPT 订阅账号"
                detail="已有 ChatGPT 账号可直接填写访问令牌并选择可用模型，无需单独管理第三方网关。"
              />
              <SettingsGuideStep
                number={3}
                title="自定义 API（OpenAI / Claude / DeepSeek / Ollama）"
                detail="内置 5 套常用服务预设；若本机运行 Ollama 多模态模型，无需填写密钥即可完全离线增强。"
              />
            </InlineGuideDisclosure>
          </>
        ) : (
          <SettingsRow
            title={
              <span className="inline-flex items-center gap-2 flex-wrap">
                {aiConfig.provider === 'chatGPTSubscription' && <ChatGPTBrandMark size={14} />}
                <span>{cloudAIProviderLocalizedLabel(aiConfig.provider)}</span>
                <SettingsStatusBadge text="已就绪" tone="positive" />
              </span>
            }
            subtitle={cloudSubtitle}
          >
            <SettingsButton
              variant="secondary"
              loading={isTestingAI}
              onClick={() => void handleQuickTestCloud()}
            >
              <PlugZap size={12} />
              测试连接
            </SettingsButton>
            <SettingsButton variant="primary" onClick={() => openCloudConfig()}>
              更改配置…
            </SettingsButton>
          </SettingsRow>
        )}

        {aiConfig.provider !== 'disabled' && (
          <>
            <SettingsCardDivider />
            <SettingsRow
              title="导入时自动分析"
              subtitle="采集新图片后后台自动生成视觉描述与建议标签（不覆盖手动标签）"
            >
              <SettingsSwitch
                ariaLabel="导入时自动分析"
                checked={aiConfig.autoAnalyzeOnImport}
                onChange={(v) => void handleToggleAIPreference({ autoAnalyzeOnImport: v })}
              />
            </SettingsRow>

            <SettingsCardDivider />
            <SettingsRow
              title="仅上传轻量化预览图"
              subtitle="仅将压缩预览图用于识图分析，不上传高分辨率原件，更省流量与隐私"
            >
              <SettingsSwitch
                ariaLabel="仅上传轻量化预览图"
                checked={aiConfig.sendThumbnailsToCloud}
                onChange={(v) => void handleToggleAIPreference({ sendThumbnailsToCloud: v })}
              />
            </SettingsRow>
          </>
        )}
      </SettingsSection>

      {/* 3. 进阶视觉定位（实验性） */}
      <SettingsSection title="进阶视觉定位（实验性）">
        <SettingsRow
          title="精准画面定位与智能分拣"
          subtitle="结合 TypeSafe 视觉定位引擎，解锁情绪板聚焦裁切、主体取色与收件箱批量分拣"
        >
          <SettingsSwitch
            ariaLabel="精准画面定位与智能分拣"
            checked={typeSafeConfig.enabled}
            onChange={(v) => void handleToggleTypeSafeMaster(v)}
          />
        </SettingsRow>

        <SettingsCardDivider />

        <SettingsRow
          title={
            <span className="inline-flex items-center gap-2 flex-wrap">
              <span>已开启 {enabledJevCount}/{JEV_SCENARIO_TOGGLES.length} 项增强场景</span>
              <SettingsStatusBadge
                text={hasStoredTypeSafeKey ? '已配置密钥' : '未配置密钥'}
                tone={hasStoredTypeSafeKey ? 'positive' : 'neutral'}
              />
            </span>
          }
          subtitle={`模型：${typeSafeConfig.model || 'jev-latest'}`}
        >
          {hasStoredTypeSafeKey && (
            <SettingsButton
              variant="secondary"
              loading={testingJev}
              onClick={() => void handleQuickTestJev()}
            >
              <PlugZap size={12} />
              测试连接
            </SettingsButton>
          )}
          <SettingsButton variant="secondary" onClick={() => setTypeSafeModalOpen(true)}>
            密钥与功能开关…
          </SettingsButton>
        </SettingsRow>

        <InlineGuideDisclosure title="这是什么？和上方云端 AI 有什么区别？">
          <SettingsGuideStep
            number={1}
            title="专注「找位置」的视觉定位模型"
            detail="上方云端 AI 负责理解画面语义、生成标签与策展方案；进阶视觉定位引擎则专注输出精确坐标框，用于主体裁切、去杂边与指物批注。"
          />
          <SettingsGuideStep
            number={2}
            title="未开启也能正常运行"
            detail="关闭或未配置密钥时，Charkle 会自动使用内置视觉分析完成常规配色与画廊检索，互不冲突。"
          />
        </InlineGuideDisclosure>
      </SettingsSection>

      {/* 4. 用量统计 */}
      <SettingsSection title="用量统计">
        <SettingsRow
          title="云端模型调用记录"
          subtitle={`今日 ${aiUsage.todayRequests} 次 · 累计 ${aiUsage.totalRequests} 次（${formatTokenCount(aiUsage.totalTokens)} tokens）`}
        >
          <SettingsButton variant="secondary" onClick={() => setUsageModalOpen(true)}>
            查看明细…
          </SettingsButton>
        </SettingsRow>
      </SettingsSection>

      {/* Sub-modals */}
      <CloudAIConfigModal
        open={cloudModalOpen}
        initialProvider={cloudModalInitialProvider}
        onClose={() => setCloudModalOpen(false)}
      />

      <TypeSafeConfigModal
        open={typeSafeModalOpen}
        onClose={() => setTypeSafeModalOpen(false)}
      />

      <UsageDetailModal open={usageModalOpen} onClose={() => setUsageModalOpen(false)} />
    </div>
  );
};

// MARK: - Cloud AI Config Modal

const CloudAIConfigModal: React.FC<{
  open: boolean;
  initialProvider: CloudAIProviderKind | null;
  onClose: () => void;
}> = ({ open, initialProvider, onClose }) => {
  const aiConfig = useSyncAIStore((s) => s.aiConfig);
  const hasStoredAIKeys = useSyncAIStore((s) => s.hasStoredAIKeys);
  const chatGPTSession = useSyncAIStore((s) => s.chatGPTSession);
  const chatGPTModels = useSyncAIStore((s) => s.chatGPTModels);
  const isLoadingChatGPTModels = useSyncAIStore((s) => s.isLoadingChatGPTModels);
  const isTestingAI = useSyncAIStore((s) => s.isTestingAI);

  const saveAIConfig = useSyncAIStore((s) => s.saveAIConfig);
  const testAIConnection = useSyncAIStore((s) => s.testAIConnection);
  const connectChatGPT = useSyncAIStore((s) => s.connectChatGPT);
  const disconnectChatGPT = useSyncAIStore((s) => s.disconnectChatGPT);
  const refreshChatGPTModels = useSyncAIStore((s) => s.refreshChatGPTModels);
  const pushToast = useCoordinatorStore((s) => s.pushToast);

  const [draft, setDraft] = useState<AIProviderConfig>(aiConfig);
  const [apiKeyInput, setApiKeyInput] = useState('');
  const [chatGPTEmail, setChatGPTEmail] = useState('');
  const [connectingChatGPT, setConnectingChatGPT] = useState(false);
  const [disconnectingChatGPT, setDisconnectingChatGPT] = useState(false);
  const [saving, setSaving] = useState(false);
  const [testResult, setTestResult] = useState<{ ok: boolean; message: string } | null>(null);

  const applyProviderDefaults = (
    prev: AIProviderConfig,
    kind: CloudAIProviderKind,
  ): AIProviderConfig => ({
    ...prev,
    provider: kind,
    baseURL:
      kind === 'gemini'
        ? 'https://generativelanguage.googleapis.com'
        : kind === 'openAICompatible'
          ? prev.provider === 'openAICompatible' && prev.baseURL
            ? prev.baseURL
            : customAIEndpointDefaultBaseURL(prev.customEndpointFormat)
          : prev.baseURL,
    chatModel:
      kind === 'gemini'
        ? prev.provider === 'gemini' && prev.chatModel
          ? prev.chatModel
          : 'gemini-2.5-flash'
        : kind === 'openAICompatible'
          ? prev.provider === 'openAICompatible' && prev.chatModel
            ? prev.chatModel
            : customAIEndpointDefaultChatModel(prev.customEndpointFormat)
          : kind === 'chatGPTSubscription'
            ? prev.provider === 'chatGPTSubscription' && prev.chatModel
              ? prev.chatModel
              : 'gpt-5-mini'
            : prev.chatModel,
    embeddingModel:
      kind === 'gemini'
        ? prev.provider === 'gemini' && prev.embeddingModel
          ? prev.embeddingModel
          : 'gemini-embedding-001'
        : kind === 'openAICompatible'
          ? prev.provider === 'openAICompatible'
            ? prev.embeddingModel
            : customAIEndpointDefaultEmbeddingModel(prev.customEndpointFormat)
          : prev.embeddingModel,
  });

  useEffect(() => {
    if (open) {
      const startConfig = initialProvider
        ? applyProviderDefaults(aiConfig, initialProvider)
        : aiConfig;
      setDraft(startConfig);
      setApiKeyInput('');
      setChatGPTEmail('');
      setTestResult(null);
    }
  }, [open, initialProvider, aiConfig]);

  const supportsEmbeddings =
    draft.provider !== 'openAICompatible' ||
    customAIEndpointSupportsEmbeddings(draft.customEndpointFormat);

  const handleTest = async () => {
    setTestResult(null);
    try {
      const summary = await testAIConnection(draft, apiKeyInput.trim() || null);
      setTestResult({ ok: true, message: summary || '连接测试通过' });
    } catch (err) {
      setTestResult({
        ok: false,
        message: err instanceof Error ? err.message : '连接测试失败',
      });
    }
  };

  const handleSave = async () => {
    setSaving(true);
    try {
      await saveAIConfig(draft, apiKeyInput.trim() || null);
      setApiKeyInput('');
      pushToast({ tone: 'success', message: '云端 AI 模型配置已保存' });
      onClose();
    } catch (err) {
      pushToast({
        tone: 'error',
        message: err instanceof Error ? err.message : '保存云端 AI 配置失败',
      });
    } finally {
      setSaving(false);
    }
  };

  const handleConnectChatGPT = async () => {
    const token = apiKeyInput.trim();
    if (!token) return;
    setConnectingChatGPT(true);
    setTestResult(null);
    try {
      await connectChatGPT({
        accessToken: token,
        email: chatGPTEmail.trim() || null,
      });
      setApiKeyInput('');
      setDraft((prev) => ({ ...prev, provider: 'chatGPTSubscription' }));
      pushToast({ tone: 'success', message: '已连接 ChatGPT 订阅账号' });
      void refreshChatGPTModels().catch(() => {});
    } catch (err) {
      pushToast({
        tone: 'error',
        message: err instanceof Error ? err.message : '连接 ChatGPT 账号失败',
      });
    } finally {
      setConnectingChatGPT(false);
    }
  };

  const handleDisconnectChatGPT = async () => {
    setDisconnectingChatGPT(true);
    try {
      await disconnectChatGPT();
      pushToast({ tone: 'info', message: '已断开 ChatGPT 订阅账号' });
    } catch (err) {
      pushToast({
        tone: 'error',
        message: err instanceof Error ? err.message : '断开 ChatGPT 账号失败',
      });
    } finally {
      setDisconnectingChatGPT(false);
    }
  };

  const handleRefreshChatGPTModels = async () => {
    try {
      const models = await refreshChatGPTModels();
      pushToast({ tone: 'success', message: `已拉取 ${models.length} 个可用模型` });
    } catch (err) {
      pushToast({
        tone: 'error',
        message: err instanceof Error ? err.message : '刷新模型列表失败',
      });
    }
  };

  return (
    <ModalShell
      open={open}
      onClose={() => {
        if (!saving) onClose();
      }}
      width="md"
      title="配置云端增强 AI"
      subtitle="按需选择服务商，密钥仅保存在服务端加密存储中"
      footer={
        <>
          {draft.provider !== 'disabled' && (
            <SettingsButton
              variant="secondary"
              loading={isTestingAI}
              disabled={saving}
              onClick={() => void handleTest()}
              className="mr-auto"
            >
              <PlugZap size={12} />
              测试连接
            </SettingsButton>
          )}
          <SettingsButton variant="secondary" disabled={saving} onClick={onClose}>
            取消
          </SettingsButton>
          <SettingsButton variant="primary" loading={saving} onClick={() => void handleSave()}>
            保存配置
          </SettingsButton>
        </>
      }
    >
      <div className="flex flex-col gap-4">
        <SettingsSegmented
          ariaLabel="云端 AI 服务商"
          options={PROVIDER_SEGMENT_OPTIONS}
          value={draft.provider}
          onChange={(kind) => {
            setTestResult(null);
            setApiKeyInput('');
            setDraft((prev) => applyProviderDefaults(prev, kind));
          }}
          className="w-full grid grid-cols-2 sm:grid-cols-4"
        />

        {draft.provider === 'disabled' && (
          <div className="p-3.5 rounded-[10px] bg-[var(--settings-subtle,var(--bg-subtle))] border border-[var(--settings-border,var(--border-hairline))] text-[12px] text-[var(--text-secondary)] leading-relaxed">
            关闭后将仅使用内置离线配色、相似图推荐、图内文字与中文拼音检索，不会向任何外部 AI 服务发送数据。
          </div>
        )}

        {/* ChatGPT Subscription */}
        {draft.provider === 'chatGPTSubscription' && (
          <div className="flex flex-col gap-3">
            <div className="p-3 rounded-[10px] bg-[var(--settings-subtle,var(--bg-subtle))] border border-[var(--settings-border,var(--border-hairline))] flex flex-col gap-2.5">
              <div className="flex items-center justify-between gap-2">
                <span className="inline-flex items-center gap-2 text-[12.5px] font-medium text-[var(--text-primary)]">
                  <ChatGPTBrandMark size={15} />
                  {chatGPTSession?.status === 'connected'
                    ? `已连接：${getChatGPTAccountDisplayName(chatGPTSession)}`
                    : '连接 ChatGPT 订阅账号'}
                </span>
                {chatGPTSession?.status === 'connected' ? (
                  <SettingsButton
                    variant="destructive"
                    loading={disconnectingChatGPT}
                    onClick={() => void handleDisconnectChatGPT()}
                  >
                    断开连接
                  </SettingsButton>
                ) : (
                  <SettingsStatusBadge text="未连接" tone="neutral" />
                )}
              </div>

              {chatGPTSession?.status !== 'connected' && (
                <div className="flex flex-col gap-2">
                  <SettingsInput
                    type="password"
                    value={apiKeyInput}
                    onChange={(e) => setApiKeyInput(e.target.value)}
                    placeholder="粘贴 ChatGPT Access Token 或 OpenAI API Key"
                    className="w-full"
                  />
                  <div className="flex items-center gap-2">
                    <SettingsInput
                      type="text"
                      value={chatGPTEmail}
                      onChange={(e) => setChatGPTEmail(e.target.value)}
                      placeholder="备注邮箱或昵称（可选）"
                      className="flex-1 min-w-0"
                    />
                    <SettingsButton
                      variant="primary"
                      loading={connectingChatGPT}
                      disabled={!apiKeyInput.trim()}
                      onClick={() => void handleConnectChatGPT()}
                    >
                      连接账号
                    </SettingsButton>
                  </div>
                </div>
              )}
            </div>

            <div className="flex flex-col gap-1">
              <div className="flex items-center justify-between">
                <label className="text-[11.5px] font-medium text-[var(--text-secondary)]">
                  默认对话与识图模型
                </label>
                <button
                  type="button"
                  disabled={isLoadingChatGPTModels}
                  onClick={() => void handleRefreshChatGPTModels()}
                  className="inline-flex items-center gap-1 text-[11px] font-medium text-[var(--accent)] hover:underline cursor-pointer disabled:opacity-50"
                >
                  <RefreshCw size={11} className={isLoadingChatGPTModels ? 'animate-spin' : ''} />
                  刷新可用模型
                </button>
              </div>
              {chatGPTModels.length > 0 ? (
                <SettingsSelect
                  value={draft.chatModel}
                  onChange={(e) => setDraft((p) => ({ ...p, chatModel: e.target.value }))}
                  className="w-full font-mono"
                >
                  {chatGPTModels.map((m) => (
                    <option key={m.slug} value={m.slug}>
                      {m.displayName} ({m.slug})
                    </option>
                  ))}
                </SettingsSelect>
              ) : (
                <SettingsInput
                  type="text"
                  value={draft.chatModel}
                  onChange={(e) => setDraft((p) => ({ ...p, chatModel: e.target.value }))}
                  placeholder="gpt-5-mini"
                  className="w-full font-mono"
                />
              )}
            </div>
          </div>
        )}

        {/* Google Gemini */}
        {draft.provider === 'gemini' && (
          <div className="flex flex-col gap-3">
            <div className="flex flex-col gap-1">
              <div className="flex items-center justify-between gap-2">
                <label className="text-[11.5px] font-medium text-[var(--text-secondary)]">
                  Gemini API Key {hasStoredAIKeys.gemini ? '（已安全保存）' : ''}
                </label>
                <a
                  href={SETTINGS_LINKS.geminiKey}
                  target="_blank"
                  rel="noopener noreferrer"
                  className="inline-flex items-center gap-1 text-[11px] font-medium text-[var(--accent)] hover:underline"
                >
                  前往 Google AI Studio 获取
                  <ExternalLink size={10} />
                </a>
              </div>
              <SettingsInput
                type="password"
                value={apiKeyInput}
                onChange={(e) => setApiKeyInput(e.target.value)}
                placeholder={
                  hasStoredAIKeys.gemini ? '••••••••（留空保持不变）' : '输入 AIza... 密钥'
                }
                className="w-full"
              />
            </div>

            <div className="rounded-[10px] border border-[var(--settings-border,var(--border-hairline))] overflow-hidden">
              <InlineGuideDisclosure title="高级选项（接口地址与模型名称）">
                <div className="flex flex-col gap-2.5">
                  <div className="flex flex-col gap-1">
                    <label className="text-[11px] font-medium text-[var(--text-secondary)]">
                      接口 Base URL
                    </label>
                    <SettingsInput
                      type="url"
                      value={draft.baseURL}
                      onChange={(e) => setDraft((p) => ({ ...p, baseURL: e.target.value }))}
                      placeholder="https://generativelanguage.googleapis.com"
                      className="w-full font-mono"
                    />
                  </div>
                  <div className="grid grid-cols-1 sm:grid-cols-2 gap-2.5">
                    <div className="flex flex-col gap-1">
                      <label className="text-[11px] font-medium text-[var(--text-secondary)]">
                        视觉与对话模型
                      </label>
                      <SettingsInput
                        type="text"
                        value={draft.chatModel}
                        onChange={(e) => setDraft((p) => ({ ...p, chatModel: e.target.value }))}
                        placeholder="gemini-2.5-flash"
                        className="w-full font-mono"
                      />
                    </div>
                    <div className="flex flex-col gap-1">
                      <label className="text-[11px] font-medium text-[var(--text-secondary)]">
                        语义向量模型
                      </label>
                      <SettingsInput
                        type="text"
                        value={draft.embeddingModel}
                        onChange={(e) =>
                          setDraft((p) => ({ ...p, embeddingModel: e.target.value }))
                        }
                        placeholder="gemini-embedding-001"
                        className="w-full font-mono"
                      />
                    </div>
                  </div>
                </div>
              </InlineGuideDisclosure>
            </div>
          </div>
        )}

        {/* Custom API with 5 One-Click Presets */}
        {draft.provider === 'openAICompatible' && (
          <div className="flex flex-col gap-3">
            <div className="flex flex-col gap-1.5">
              <span className="text-[11.5px] font-medium text-[var(--text-secondary)]">
                一键填入常用服务预设
              </span>
              <div className="flex flex-wrap gap-1.5">
                {CUSTOM_API_PRESETS.map((preset) => {
                  const active =
                    draft.baseURL.replace(/\/+$/, '') === preset.baseURL.replace(/\/+$/, '') &&
                    draft.customEndpointFormat === preset.format;
                  return (
                    <button
                      key={preset.id}
                      type="button"
                      onClick={() => {
                        setTestResult(null);
                        setDraft((prev) => ({
                          ...prev,
                          customEndpointFormat: preset.format,
                          baseURL: preset.baseURL,
                          chatModel: preset.chatModel,
                          embeddingModel: preset.embeddingModel,
                        }));
                      }}
                      className={[
                        'charkle-pressable px-2.5 py-1 rounded-full text-[11.5px] font-medium border cursor-pointer',
                        'transition-colors duration-[var(--duration-press,120ms)] ease-[var(--ease-out)]',
                        active
                          ? 'bg-[#18191D] text-white border-[#18191D] dark:bg-white dark:text-[#111215] dark:border-white'
                          : 'bg-[var(--settings-subtle,var(--bg-subtle))] text-[var(--text-primary)] border-[var(--settings-border,var(--border-hairline))] hover:border-[var(--border-strong)]',
                      ].join(' ')}
                    >
                      {preset.label}
                    </button>
                  );
                })}
              </div>
            </div>

            <div className="grid grid-cols-1 sm:grid-cols-2 gap-2.5">
              <div className="flex flex-col gap-1">
                <label className="text-[11.5px] font-medium text-[var(--text-secondary)]">
                  接口协议格式
                </label>
                <SettingsSelect
                  value={draft.customEndpointFormat}
                  onChange={(e) => {
                    const fmt = e.target.value as CustomAIEndpointFormat;
                    setDraft((prev) => ({
                      ...prev,
                      customEndpointFormat: fmt,
                      baseURL: customAIEndpointDefaultBaseURL(fmt),
                      chatModel: customAIEndpointDefaultChatModel(fmt),
                      embeddingModel: customAIEndpointDefaultEmbeddingModel(fmt),
                    }));
                  }}
                  className="w-full"
                >
                  {CUSTOM_AI_ENDPOINT_FORMATS.map((fmt) => (
                    <option key={fmt} value={fmt}>
                      {customAIEndpointLocalizedLabel(fmt)}
                    </option>
                  ))}
                </SettingsSelect>
              </div>

              <div className="flex flex-col gap-1">
                <label className="text-[11.5px] font-medium text-[var(--text-secondary)]">
                  接口 Base URL
                </label>
                <SettingsInput
                  type="url"
                  value={draft.baseURL}
                  onChange={(e) => setDraft((p) => ({ ...p, baseURL: e.target.value }))}
                  placeholder="https://api.openai.com"
                  className="w-full font-mono"
                />
              </div>

              <div className="sm:col-span-2 flex flex-col gap-1">
                <label className="text-[11.5px] font-medium text-[var(--text-secondary)]">
                  API Key {hasStoredAIKeys.openAICompatible ? '（已安全保存）' : ''}
                </label>
                <SettingsInput
                  type="password"
                  value={apiKeyInput}
                  onChange={(e) => setApiKeyInput(e.target.value)}
                  placeholder={
                    isLocalhostURL(draft.baseURL)
                      ? '本机 Ollama 服务可留空'
                      : hasStoredAIKeys.openAICompatible
                        ? '••••••••（留空保持不变）'
                        : '输入对应服务商的 API Key'
                  }
                  className="w-full"
                />
              </div>

              <div className="flex flex-col gap-1">
                <label className="text-[11.5px] font-medium text-[var(--text-secondary)]">
                  视觉 / 对话模型
                </label>
                <SettingsInput
                  type="text"
                  value={draft.chatModel}
                  onChange={(e) => setDraft((p) => ({ ...p, chatModel: e.target.value }))}
                  className="w-full font-mono"
                />
              </div>

              <div className="flex flex-col gap-1">
                <label className="text-[11.5px] font-medium text-[var(--text-secondary)]">
                  语义向量模型 {!supportsEmbeddings ? '（当前协议不支持）' : ''}
                </label>
                <SettingsInput
                  type="text"
                  disabled={!supportsEmbeddings}
                  value={draft.embeddingModel}
                  onChange={(e) => setDraft((p) => ({ ...p, embeddingModel: e.target.value }))}
                  placeholder={supportsEmbeddings ? '可选' : 'Anthropic 协议不支持向量接口'}
                  className="w-full font-mono"
                />
              </div>
            </div>
          </div>
        )}

        {/* Live Connection Test Banner */}
        {testResult && (
          <div
            className={[
              'p-2.5 rounded-[9px] text-[12px] flex items-center gap-2',
              testResult.ok
                ? 'bg-[var(--success-soft)] text-[var(--settings-positive,var(--success))]'
                : 'bg-[var(--danger-soft)] text-[var(--settings-destructive,var(--danger))]',
            ].join(' ')}
          >
            {testResult.ok ? (
              <CheckCircle2 size={14} className="shrink-0" />
            ) : (
              <XCircle size={14} className="shrink-0" />
            )}
            <span className="break-all">{testResult.message}</span>
          </div>
        )}
      </div>
    </ModalShell>
  );
};

// MARK: - TypeSafe Visual Grounding Config Modal

const TypeSafeConfigModal: React.FC<{
  open: boolean;
  onClose: () => void;
}> = ({ open, onClose }) => {
  const typeSafeConfig = useSyncAIStore((s) => s.typeSafeConfig);
  const hasStoredTypeSafeKey = useSyncAIStore((s) => s.hasStoredTypeSafeKey);
  const typeSafeModels = useSyncAIStore((s) => s.typeSafeModels);
  const saveTypeSafeConfig = useSyncAIStore((s) => s.saveTypeSafeConfig);
  const testTypeSafeConnection = useSyncAIStore((s) => s.testTypeSafeConnection);
  const pushToast = useCoordinatorStore((s) => s.pushToast);

  const [draft, setDraft] = useState<TypeSafeExperimentalConfig>(typeSafeConfig);
  const [keyInput, setKeyInput] = useState('');
  const [testing, setTesting] = useState(false);
  const [saving, setSaving] = useState(false);

  useEffect(() => {
    if (open) {
      setDraft(typeSafeConfig);
      setKeyInput('');
    }
  }, [open, typeSafeConfig]);

  const handleTest = async () => {
    setTesting(true);
    try {
      const models = await testTypeSafeConnection(draft, keyInput.trim() || null);
      pushToast({
        tone: 'success',
        message: `视觉定位引擎连接正常，获取到 ${models.length} 个可用模型`,
      });
    } catch (err) {
      pushToast({
        tone: 'error',
        message: err instanceof Error ? err.message : '视觉定位连接测试失败',
      });
    } finally {
      setTesting(false);
    }
  };

  const handleSave = async () => {
    setSaving(true);
    try {
      await saveTypeSafeConfig(draft, keyInput.trim() || null);
      setKeyInput('');
      pushToast({ tone: 'success', message: '视觉定位引擎配置已保存' });
      onClose();
    } catch (err) {
      pushToast({
        tone: 'error',
        message: err instanceof Error ? err.message : '保存视觉定位配置失败',
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
      width="md"
      title="进阶视觉定位配置"
      subtitle="配置 TypeSafe API 密钥、灵敏度与按场景启用开关"
      footer={
        <>
          <SettingsButton
            variant="secondary"
            loading={testing}
            disabled={saving}
            onClick={() => void handleTest()}
            className="mr-auto"
          >
            <PlugZap size={12} />
            测试连接
          </SettingsButton>
          <SettingsButton variant="secondary" disabled={saving} onClick={onClose}>
            取消
          </SettingsButton>
          <SettingsButton variant="primary" loading={saving} onClick={() => void handleSave()}>
            保存配置
          </SettingsButton>
        </>
      }
    >
      <div className="flex flex-col gap-4">
        <div className="grid grid-cols-1 sm:grid-cols-2 gap-2.5">
          <div className="flex flex-col gap-1">
            <label className="text-[11.5px] font-medium text-[var(--text-secondary)]">
              接口 Base URL
            </label>
            <SettingsInput
              type="url"
              value={draft.baseURL}
              onChange={(e) => setDraft((p) => ({ ...p, baseURL: e.target.value }))}
              placeholder="https://api.typesafe.ai"
              className="w-full font-mono"
            />
          </div>

          <div className="flex flex-col gap-1">
            <label className="text-[11.5px] font-medium text-[var(--text-secondary)]">
              模型名称
            </label>
            {typeSafeModels.length > 0 ? (
              <SettingsSelect
                value={draft.model}
                onChange={(e) => setDraft((p) => ({ ...p, model: e.target.value }))}
                className="w-full font-mono"
              >
                {typeSafeModels.map((m) => (
                  <option key={m.name} value={m.name}>
                    {m.name}
                  </option>
                ))}
              </SettingsSelect>
            ) : (
              <SettingsInput
                type="text"
                value={draft.model}
                onChange={(e) => setDraft((p) => ({ ...p, model: e.target.value }))}
                placeholder="jev-latest"
                className="w-full font-mono"
              />
            )}
          </div>

          <div className="sm:col-span-2 flex flex-col gap-1">
            <div className="flex items-center justify-between gap-2">
              <label className="text-[11.5px] font-medium text-[var(--text-secondary)]">
                TypeSafe API Key {hasStoredTypeSafeKey ? '（已安全保存）' : ''}
              </label>
              <a
                href={SETTINGS_LINKS.typeSafeHome}
                target="_blank"
                rel="noopener noreferrer"
                className="inline-flex items-center gap-1 text-[11px] font-medium text-[var(--accent)] hover:underline"
              >
                前往 TypeSafe 官网
                <ExternalLink size={10} />
              </a>
            </div>
            <SettingsInput
              type="password"
              value={keyInput}
              onChange={(e) => setKeyInput(e.target.value)}
              placeholder={
                hasStoredTypeSafeKey ? '••••••••（留空保持不变）' : '输入 TypeSafe API Key'
              }
              className="w-full"
            />
          </div>
        </div>

        {/* Confidence / Padding / Presence Sliders */}
        <div className="grid grid-cols-1 sm:grid-cols-3 gap-3 p-3 rounded-[10px] bg-[var(--settings-subtle,var(--bg-subtle))] border border-[var(--settings-border,var(--border-hairline))]">
          <SliderField
            label="置信度阈值"
            value={draft.minConfidence}
            min={0.3}
            max={0.9}
            step={0.05}
            display={`${Math.round(draft.minConfidence * 100)}%`}
            onChange={(v) => setDraft((p) => ({ ...p, minConfidence: v }))}
          />
          <SliderField
            label="低置信外扩留白"
            value={draft.lowConfidencePadding}
            min={0}
            max={0.15}
            step={0.01}
            display={`${Math.round(draft.lowConfidencePadding * 100)}%`}
            onChange={(v) => setDraft((p) => ({ ...p, lowConfidencePadding: v }))}
          />
          <SliderField
            label="主体判定阈值"
            value={draft.minPresenceProbability}
            min={0.2}
            max={0.85}
            step={0.05}
            display={`${Math.round(draft.minPresenceProbability * 100)}%`}
            onChange={(v) => setDraft((p) => ({ ...p, minPresenceProbability: v }))}
          />
        </div>

        {/* 7 Scenario Toggles */}
        <div className="rounded-[10px] border border-[var(--settings-border,var(--border-hairline))] divide-y divide-[var(--settings-divider,var(--border-hairline))]">
          {JEV_SCENARIO_TOGGLES.map((sc) => (
            <div key={sc.key} className="px-3.5 py-2.5 flex items-center justify-between gap-3">
              <div className="min-w-0">
                <div className="text-[12.5px] font-medium text-[var(--text-primary)]">
                  {sc.label}
                </div>
                <div className="text-[11px] text-[var(--text-secondary)]">{sc.desc}</div>
              </div>
              <SettingsSwitch
                ariaLabel={sc.label}
                checked={draft[sc.key]}
                onChange={(v) => setDraft((p) => ({ ...p, [sc.key]: v }))}
              />
            </div>
          ))}
        </div>
      </div>
    </ModalShell>
  );
};

// MARK: - Usage Detail Modal

const UsageDetailModal: React.FC<{
  open: boolean;
  onClose: () => void;
}> = ({ open, onClose }) => {
  const aiUsage = useSyncAIStore((s) => s.aiUsage);
  const resetAIUsage = useSyncAIStore((s) => s.resetAIUsage);
  const pushToast = useCoordinatorStore((s) => s.pushToast);

  const [resetting, setResetting] = useState<'all' | 'standard' | 'jev' | null>(null);

  const handleReset = async (category: 'standard' | 'jev' | null) => {
    setResetting(category ?? 'all');
    try {
      await resetAIUsage(category);
      pushToast({
        tone: 'info',
        message:
          category === 'standard'
            ? '已清零普通云端模型用量统计'
            : category === 'jev'
              ? '已清零视觉定位引擎用量统计'
              : '已清零全部云端 AI 用量统计',
      });
    } catch (err) {
      pushToast({
        tone: 'error',
        message: err instanceof Error ? err.message : '清零用量统计失败',
      });
    } finally {
      setResetting(null);
    }
  };

  return (
    <ModalShell
      open={open}
      onClose={onClose}
      width="md"
      title="云端 AI 用量明细"
      subtitle={`统计日期：${aiUsage.dayKey}`}
      footer={
        <>
          <SettingsButton
            variant="destructive"
            loading={resetting === 'all'}
            onClick={() => void handleReset(null)}
            className="mr-auto"
          >
            <RotateCcw size={12} />
            全部清零
          </SettingsButton>
          <SettingsButton variant="primary" onClick={onClose}>
            完成
          </SettingsButton>
        </>
      }
    >
      <div className="grid grid-cols-1 sm:grid-cols-2 gap-3.5">
        <UsageBucketPanel
          title="普通云端模型"
          bucket={aiUsage.standard}
          loading={resetting === 'standard'}
          onReset={() => void handleReset('standard')}
        />
        <UsageBucketPanel
          title="视觉定位引擎"
          bucket={aiUsage.jev}
          loading={resetting === 'jev'}
          onReset={() => void handleReset('jev')}
        />
      </div>
    </ModalShell>
  );
};

const UsageBucketPanel: React.FC<{
  title: string;
  bucket: CloudAIUsageBucket;
  loading: boolean;
  onReset: () => void;
}> = ({ title, bucket, loading, onReset }) => (
  <div className="rounded-[10px] bg-[var(--settings-subtle,var(--bg-subtle))] border border-[var(--settings-border,var(--border-hairline))] p-3.5 flex flex-col gap-3">
    <div className="flex items-center justify-between gap-2">
      <span className="text-[12.5px] font-semibold text-[var(--text-primary)]">{title}</span>
      <button
        type="button"
        disabled={loading}
        onClick={onReset}
        className="inline-flex items-center gap-1 text-[11px] font-medium text-[var(--text-secondary)] hover:text-[var(--text-primary)] cursor-pointer disabled:opacity-45"
      >
        <RotateCcw size={11} />
        清零
      </button>
    </div>

    <div className="grid grid-cols-2 gap-2 text-center">
      <div className="p-2.5 rounded-[8px] bg-[var(--settings-card,var(--bg-elevated))] border border-[var(--settings-border,var(--border-hairline))]">
        <div className="text-[10.5px] text-[var(--text-tertiary)]">今日 Tokens</div>
        <div className="text-[15px] font-semibold text-[var(--text-primary)] tabular-nums mt-0.5">
          {formatTokenCount(bucket.todayTotalTokens)}
        </div>
        <div className="text-[10.5px] text-[var(--text-secondary)] tabular-nums">
          {bucket.todayRequests} 次请求
        </div>
      </div>
      <div className="p-2.5 rounded-[8px] bg-[var(--settings-card,var(--bg-elevated))] border border-[var(--settings-border,var(--border-hairline))]">
        <div className="text-[10.5px] text-[var(--text-tertiary)]">累计 Tokens</div>
        <div className="text-[15px] font-semibold text-[var(--text-primary)] tabular-nums mt-0.5">
          {formatTokenCount(bucket.totalTokens)}
        </div>
        <div className="text-[10.5px] text-[var(--text-secondary)] tabular-nums">
          {bucket.totalRequests} 次请求
        </div>
      </div>
    </div>

    <div className="text-[11px] text-[var(--text-tertiary)] truncate">
      最近调用：{bucket.lastModel || '暂无'} · {formatRelativeDate(bucket.lastUsedAt)}
    </div>
  </div>
);

const SliderField: React.FC<{
  label: string;
  value: number;
  min: number;
  max: number;
  step: number;
  display: string;
  onChange: (value: number) => void;
}> = ({ label, value, min, max, step, display, onChange }) => (
  <label className="flex flex-col gap-1.5">
    <div className="flex items-center justify-between text-[11px]">
      <span className="text-[var(--text-secondary)] font-medium">{label}</span>
      <span className="font-mono text-[var(--text-primary)] tabular-nums">{display}</span>
    </div>
    <input
      type="range"
      min={min}
      max={max}
      step={step}
      value={value}
      onChange={(e) => onChange(Number(e.target.value))}
      className="w-full accent-[var(--accent)] cursor-pointer"
    />
  </label>
);
