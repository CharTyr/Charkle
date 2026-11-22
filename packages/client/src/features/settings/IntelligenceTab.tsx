import React, { useEffect, useState } from 'react';
import {
  CheckCircle2,
  FlaskConical,
  PlugZap,
  RotateCcw,
} from 'lucide-react';
import {
  CLOUD_AI_PROVIDER_KINDS,
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
  CloudAIUsageBucket,
  TypeSafeExperimentalConfig,
} from '@charkle/shared';
import { Button } from '../../design-system/Button';
import { useCoordinatorStore } from '../../stores/coordinatorStore';
import { useSyncAIStore } from '../../stores/syncAIStore';
import {
  SettingsCard,
  SettingsDivider,
  SettingsHeader,
  SettingsInput,
  SettingsRow,
  SettingsSwitch,
} from './SettingsPrimitives';
import { formatRelativeDate } from './shortcuts';

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
  { key: 'enableMoodboardFocusCrop', label: '情绪板智能聚焦裁切', desc: '按主体或一句描述写入非破坏性裁切框' },
  { key: 'enableAutoCleanCrop', label: '自动去杂边裁净', desc: '识别截图/扫描图周围杂边并精准裁切核心画面' },
  { key: 'enableSubjectPalette', label: '按主体重提取色卡', desc: '仅针对前景主体像素聚类 CIELAB 调色板' },
  { key: 'enablePinpointAnnotations', label: '指物精准批注 (Pinpoint)', desc: '定位画面中指定部件并生成带瞄准点的连线便签' },
  { key: 'enableSemanticSearch', label: '混合语义搜图视觉精排', desc: '结合 FTS5 + 向量 + Jev Score 三路融合排序' },
  { key: 'enableInboxSmartTriage', label: '收件箱批量智能分拣', desc: '闭集目录分类 + 匹配度校验（尊重不归档拒判）' },
  { key: 'enableCuratorVisualRerank', label: '情绪板策展视觉精排', desc: 'Agent Harness Stage 2.5 对候选素材视觉打分' },
];

export const IntelligenceTab: React.FC = () => {
  const aiConfig = useSyncAIStore((s) => s.aiConfig);
  const hasStoredAIKeys = useSyncAIStore((s) => s.hasStoredAIKeys);
  const aiUsage = useSyncAIStore((s) => s.aiUsage);
  const chatGPTSession = useSyncAIStore((s) => s.chatGPTSession);
  const typeSafeConfig = useSyncAIStore((s) => s.typeSafeConfig);
  const hasStoredTypeSafeKey = useSyncAIStore((s) => s.hasStoredTypeSafeKey);
  const typeSafeModels = useSyncAIStore((s) => s.typeSafeModels);

  const loadAIConfig = useSyncAIStore((s) => s.loadAIConfig);
  const saveAIConfig = useSyncAIStore((s) => s.saveAIConfig);
  const resetAIUsage = useSyncAIStore((s) => s.resetAIUsage);
  const loadTypeSafeConfig = useSyncAIStore((s) => s.loadTypeSafeConfig);
  const saveTypeSafeConfig = useSyncAIStore((s) => s.saveTypeSafeConfig);
  const testTypeSafeConnection = useSyncAIStore((s) => s.testTypeSafeConnection);
  const pushToast = useCoordinatorStore((s) => s.pushToast);

  const [draftAI, setDraftAI] = useState<AIProviderConfig>(aiConfig);
  const [apiKeyInput, setApiKeyInput] = useState('');
  const [savingAI, setSavingAI] = useState(false);

  const [draftJev, setDraftJev] = useState<TypeSafeExperimentalConfig>(typeSafeConfig);
  const [jevKeyInput, setJevKeyInput] = useState('');
  const [savingJev, setSavingJev] = useState(false);
  const [testingJev, setTestingJev] = useState(false);

  useEffect(() => {
    void loadAIConfig();
    void loadTypeSafeConfig();
  }, [loadAIConfig, loadTypeSafeConfig]);

  useEffect(() => {
    setDraftAI(aiConfig);
  }, [aiConfig]);

  useEffect(() => {
    setDraftJev(typeSafeConfig);
  }, [typeSafeConfig]);

  const handleSaveAI = async () => {
    setSavingAI(true);
    try {
      await saveAIConfig(draftAI, apiKeyInput.trim() || null);
      setApiKeyInput('');
      pushToast({ tone: 'success', message: '云端 AI 模型配置已保存' });
    } catch (err) {
      pushToast({
        tone: 'error',
        message: err instanceof Error ? err.message : '保存云端 AI 配置失败',
      });
    } finally {
      setSavingAI(false);
    }
  };

  const handleSaveJev = async () => {
    setSavingJev(true);
    try {
      await saveTypeSafeConfig(draftJev, jevKeyInput.trim() || null);
      setJevKeyInput('');
      pushToast({ tone: 'success', message: 'TypeSafe System One (Jev) 配置已保存' });
    } catch (err) {
      pushToast({
        tone: 'error',
        message: err instanceof Error ? err.message : '保存 TypeSafe 配置失败',
      });
    } finally {
      setSavingJev(false);
    }
  };

  const handleTestJev = async () => {
    setTestingJev(true);
    try {
      const models = await testTypeSafeConnection(draftJev, jevKeyInput.trim() || null);
      pushToast({
        tone: 'success',
        message: `TypeSafe 连接正常，已拉取 ${models.length} 个可用视觉定位模型`,
      });
    } catch (err) {
      pushToast({
        tone: 'error',
        message: err instanceof Error ? err.message : 'TypeSafe 连接测试失败',
      });
    } finally {
      setTestingJev(false);
    }
  };

  const supportsEmbeddings =
    draftAI.provider !== 'openAICompatible' ||
    customAIEndpointSupportsEmbeddings(draftAI.customEndpointFormat);

  return (
    <div className="flex flex-col gap-5">
      <SettingsHeader
        title="智能与搜索"
        subtitle="所有 CIELAB 色彩检索、拼音全文搜索、感知相似图与离线策展均在本机免费运行；可按需开启云端视觉模型与实验性 TypeSafe System One (Jev)。"
      />

      {/* 4 Offline Capability Tiles */}
      <div className="grid grid-cols-2 sm:grid-cols-4 gap-2.5">
        {[
          { title: 'CIELAB 色彩聚类', sub: '零成本本机 ΔE 搜色' },
          { title: 'FTS5 + 中文拼音', sub: '支持首字母与全文检索' },
          { title: '视觉感知指纹', sub: '64 维局部特征相似匹配' },
          { title: '离线情绪板策展', sub: 'MMR 多样性均衡排布' },
        ].map((tile) => (
          <div
            key={tile.title}
            className="p-3 rounded-[var(--radius-settings-outer)] bg-[var(--bg-elevated)] border border-[var(--border-hairline)]"
          >
            <div className="flex items-center gap-1.5 text-[12px] font-semibold text-[var(--text-primary)]">
              <CheckCircle2 size={12} className="text-[var(--success)] shrink-0" />
              <span className="truncate">{tile.title}</span>
            </div>
            <div className="text-[11px] text-[var(--text-tertiary)] mt-1">{tile.sub}</div>
          </div>
        ))}
      </div>

      {/* Cloud AI Provider Card */}
      <SettingsCard title="云端多模态视觉与策展模型">
        <div className="grid grid-cols-2 sm:grid-cols-4 gap-1.5 p-1 rounded-[var(--radius-settings-inner)] bg-[var(--bg-subtle)] border border-[var(--border-hairline)]">
          {CLOUD_AI_PROVIDER_KINDS.map((kind) => (
            <button
              key={kind}
              type="button"
              onClick={() => {
                setDraftAI((prev) => ({
                  ...prev,
                  provider: kind,
                  baseURL:
                    kind === 'gemini'
                      ? 'https://generativelanguage.googleapis.com'
                      : kind === 'openAICompatible'
                        ? customAIEndpointDefaultBaseURL(prev.customEndpointFormat)
                        : prev.baseURL,
                  chatModel:
                    kind === 'gemini'
                      ? 'gemini-2.5-flash'
                      : kind === 'openAICompatible'
                        ? customAIEndpointDefaultChatModel(prev.customEndpointFormat)
                        : kind === 'chatGPTSubscription'
                          ? 'gpt-5-mini'
                          : prev.chatModel,
                  embeddingModel:
                    kind === 'gemini'
                      ? 'gemini-embedding-001'
                      : kind === 'openAICompatible'
                        ? customAIEndpointDefaultEmbeddingModel(prev.customEndpointFormat)
                        : prev.embeddingModel,
                }));
              }}
              className={[
                'px-2 py-1.5 rounded-[6px] text-[11.5px] font-medium cursor-pointer',
                draftAI.provider === kind
                  ? 'bg-[var(--bg-elevated)] text-[var(--text-primary)] shadow-xs'
                  : 'text-[var(--text-secondary)] hover:text-[var(--text-primary)]',
              ].join(' ')}
            >
              {cloudAIProviderLocalizedLabel(kind)}
            </button>
          ))}
        </div>

        {draftAI.provider === 'chatGPTSubscription' && (
          <div className="p-3 rounded-[var(--radius-settings-inner)] bg-[var(--bg-gallery)] border border-[var(--border-hairline)] flex flex-col gap-2">
            <div className="flex items-center justify-between text-[12px]">
              <span className="font-medium text-[var(--text-primary)]">
                {chatGPTSession?.status === 'connected'
                  ? `已连接：${getChatGPTAccountDisplayName(chatGPTSession)}`
                  : '使用 ChatGPT 订阅账号或 Access Token'}
              </span>
              <span className="text-[11px] text-[var(--text-tertiary)]">
                {hasStoredAIKeys.chatGPTSubscription ? '已保存会话令牌' : '未配置令牌'}
              </span>
            </div>
            <SettingsInput
              type="password"
              value={apiKeyInput}
              onChange={(e) => setApiKeyInput(e.target.value)}
              placeholder={
                hasStoredAIKeys.chatGPTSubscription
                  ? '••••••••（留空保持已保存令牌）'
                  : '粘贴 ChatGPT Access Token / OpenAI Key'
              }
              className="w-full"
            />
          </div>
        )}

        {draftAI.provider === 'openAICompatible' && (
          <div className="flex flex-col gap-2.5">
            <SettingsRow title="自定义接口协议格式" subtitle="支持 OpenAI Chat Completions、Anthropic Messages 与 OpenAI Responses">
              <select
                aria-label="自定义接口协议格式"
                value={draftAI.customEndpointFormat}
                onChange={(e) => {
                  const fmt = e.target.value as AIProviderConfig['customEndpointFormat'];
                  setDraftAI((prev) => ({
                    ...prev,
                    customEndpointFormat: fmt,
                    baseURL: customAIEndpointDefaultBaseURL(fmt),
                    chatModel: customAIEndpointDefaultChatModel(fmt),
                    embeddingModel: customAIEndpointDefaultEmbeddingModel(fmt),
                  }));
                }}
                className="h-8 px-2.5 rounded-[var(--radius-settings-inner)] bg-[var(--bg-subtle)] border border-[var(--border-hairline)] text-[12px] text-[var(--text-primary)] outline-none cursor-pointer"
              >
                {CUSTOM_AI_ENDPOINT_FORMATS.map((fmt) => (
                  <option key={fmt} value={fmt}>
                    {customAIEndpointLocalizedLabel(fmt)}
                  </option>
                ))}
              </select>
            </SettingsRow>
            <div>
              <label className="block text-[11.5px] font-medium text-[var(--text-secondary)] mb-1">
                接口 Base URL
              </label>
              <SettingsInput
                type="url"
                value={draftAI.baseURL}
                onChange={(e) => setDraftAI((p) => ({ ...p, baseURL: e.target.value }))}
                placeholder="https://api.openai.com"
                className="w-full"
              />
            </div>
          </div>
        )}

        {draftAI.provider !== 'disabled' && (
          <div className="grid grid-cols-1 sm:grid-cols-2 gap-3">
            {draftAI.provider !== 'chatGPTSubscription' && (
              <div className="sm:col-span-2">
                <label className="block text-[11.5px] font-medium text-[var(--text-secondary)] mb-1">
                  API Key {hasStoredAIKeys[draftAI.provider] ? '（已安全存储）' : ''}
                </label>
                <SettingsInput
                  type="password"
                  value={apiKeyInput}
                  onChange={(e) => setApiKeyInput(e.target.value)}
                  placeholder={
                    hasStoredAIKeys[draftAI.provider]
                      ? '••••••••（留空保持不变）'
                      : '输入对应服务商的 API Key'
                  }
                  className="w-full"
                />
              </div>
            )}

            <div>
              <label className="block text-[11.5px] font-medium text-[var(--text-secondary)] mb-1">
                视觉 / 对话模型
              </label>
              <SettingsInput
                type="text"
                value={draftAI.chatModel}
                onChange={(e) => setDraftAI((p) => ({ ...p, chatModel: e.target.value }))}
                className="w-full font-mono text-[12px]"
              />
            </div>

            <div>
              <label className="block text-[11.5px] font-medium text-[var(--text-secondary)] mb-1">
                语义向量模型 {!supportsEmbeddings ? '（当前协议不支持）' : ''}
              </label>
              <SettingsInput
                type="text"
                disabled={!supportsEmbeddings}
                value={draftAI.embeddingModel}
                onChange={(e) => setDraftAI((p) => ({ ...p, embeddingModel: e.target.value }))}
                placeholder={supportsEmbeddings ? '可选' : 'Anthropic Messages 不支持向量接口'}
                className="w-full font-mono text-[12px]"
              />
            </div>
          </div>
        )}

        <SettingsDivider />

        <SettingsRow
          title="入库时自动 AI 识图打标"
          subtitle="采集新图片后后台自动生成视觉描述与建议标签（不覆盖手动标签）"
        >
          <SettingsSwitch
            ariaLabel="入库时自动 AI 识图打标"
            checked={draftAI.autoAnalyzeOnImport}
            onChange={(v) => setDraftAI((p) => ({ ...p, autoAnalyzeOnImport: v }))}
          />
        </SettingsRow>

        <SettingsDivider />

        <SettingsRow
          title="仅发送压缩缩略图至云端（隐私保护）"
          subtitle="仅上传轻量预览图进行视觉审片，绝不发送高分辨率原件"
        >
          <SettingsSwitch
            ariaLabel="仅发送压缩缩略图至云端"
            checked={draftAI.sendThumbnailsToCloud}
            onChange={(v) => setDraftAI((p) => ({ ...p, sendThumbnailsToCloud: v }))}
          />
        </SettingsRow>

        <div className="flex justify-end">
          <Button variant="primary" size="sm" loading={savingAI} onClick={() => void handleSaveAI()}>
            保存 AI 配置
          </Button>
        </div>
      </SettingsCard>

      {/* Separated Standard vs Jev Cloud AI Usage Stats */}
      <div className="grid grid-cols-1 sm:grid-cols-2 gap-3.5">
        <UsageBucketCard
          title="标准云端模型用量 (Standard)"
          bucket={aiUsage.standard}
          onReset={async () => {
            await resetAIUsage('standard');
            pushToast({ tone: 'info', message: '已重置标准云端模型用量统计' });
          }}
        />
        <UsageBucketCard
          title="TypeSafe Jev 视觉定位用量 (Jev)"
          bucket={aiUsage.jev}
          onReset={async () => {
            await resetAIUsage('jev');
            pushToast({ tone: 'info', message: '已重置 TypeSafe Jev 用量统计' });
          }}
        />
      </div>

      {/* Experimental TypeSafe System One (Jev) Card */}
      <SettingsCard
        title="实验性 TypeSafe System One (Jev) 视觉定位引擎"
        badge={
          <span className="inline-flex items-center gap-1 px-2 py-0.5 rounded-full bg-[var(--warning-soft)] text-[var(--warning)] text-[10.5px] font-semibold">
            <FlaskConical size={11} />
            Experimental
          </span>
        }
      >
        <SettingsRow
          title="启用 TypeSafe System One (Jev)"
          subtitle="解锁语义局部裁切、自动去杂边、主体色卡重提、指物批注、三路语义搜索与批量收件箱分拣"
        >
          <SettingsSwitch
            ariaLabel="启用 TypeSafe System One"
            checked={draftJev.enabled}
            onChange={(v) => setDraftJev((p) => ({ ...p, enabled: v }))}
          />
        </SettingsRow>

        <SettingsDivider />

        <div className="grid grid-cols-1 sm:grid-cols-2 gap-3">
          <div>
            <label className="block text-[11.5px] font-medium text-[var(--text-secondary)] mb-1">
              Base URL
            </label>
            <SettingsInput
              type="url"
              value={draftJev.baseURL}
              onChange={(e) => setDraftJev((p) => ({ ...p, baseURL: e.target.value }))}
              placeholder="https://api.typesafe.ai"
              className="w-full"
            />
          </div>

          <div>
            <label className="block text-[11.5px] font-medium text-[var(--text-secondary)] mb-1">
              模型名称
            </label>
            {typeSafeModels.length > 0 ? (
              <select
                value={draftJev.model}
                onChange={(e) => setDraftJev((p) => ({ ...p, model: e.target.value }))}
                className="w-full h-8.5 px-2.5 rounded-[var(--radius-settings-inner)] bg-[var(--bg-subtle)] border border-[var(--border-hairline)] font-mono text-[12px] text-[var(--text-primary)] outline-none"
              >
                {typeSafeModels.map((m) => (
                  <option key={m.name} value={m.name}>
                    {m.name}
                  </option>
                ))}
              </select>
            ) : (
              <SettingsInput
                type="text"
                value={draftJev.model}
                onChange={(e) => setDraftJev((p) => ({ ...p, model: e.target.value }))}
                placeholder="jev-latest"
                className="w-full font-mono text-[12px]"
              />
            )}
          </div>

          <div className="sm:col-span-2">
            <label className="block text-[11.5px] font-medium text-[var(--text-secondary)] mb-1">
              TypeSafe API Key {hasStoredTypeSafeKey ? '（已安全存储）' : ''}
            </label>
            <div className="flex items-center gap-2">
              <SettingsInput
                type="password"
                value={jevKeyInput}
                onChange={(e) => setJevKeyInput(e.target.value)}
                placeholder={
                  hasStoredTypeSafeKey ? '••••••••（留空保持不变）' : '输入 TypeSafe API Key'
                }
                className="flex-1"
              />
              <Button
                variant="secondary"
                size="sm"
                loading={testingJev}
                onClick={() => void handleTestJev()}
              >
                <PlugZap size={13} />
                测试连接
              </Button>
            </div>
          </div>
        </div>

        {/* Confidence / Padding / Presence Sliders */}
        <div className="grid grid-cols-1 sm:grid-cols-3 gap-3 p-3 rounded-[var(--radius-settings-inner)] bg-[var(--bg-gallery)] border border-[var(--border-hairline)]">
          <SliderField
            label="置信度阈值"
            value={draftJev.minConfidence}
            min={0.3}
            max={0.9}
            step={0.05}
            display={`${Math.round(draftJev.minConfidence * 100)}%`}
            onChange={(v) => setDraftJev((p) => ({ ...p, minConfidence: v }))}
          />
          <SliderField
            label="低置信外扩留白"
            value={draftJev.lowConfidencePadding}
            min={0}
            max={0.15}
            step={0.01}
            display={`${Math.round(draftJev.lowConfidencePadding * 100)}%`}
            onChange={(v) => setDraftJev((p) => ({ ...p, lowConfidencePadding: v }))}
          />
          <SliderField
            label="存在性门限 (Noul)"
            value={draftJev.minPresenceProbability}
            min={0.2}
            max={0.85}
            step={0.05}
            display={`${Math.round(draftJev.minPresenceProbability * 100)}%`}
            onChange={(v) => setDraftJev((p) => ({ ...p, minPresenceProbability: v }))}
          />
        </div>

        {/* All 7 Scenario Toggles */}
        <div className="flex flex-col divide-y divide-[var(--border-hairline)]">
          {JEV_SCENARIO_TOGGLES.map((sc) => (
            <div key={sc.key} className="py-2 first:pt-0 last:pb-0 flex items-center justify-between gap-3">
              <div>
                <div className="text-[12.5px] font-medium text-[var(--text-primary)]">{sc.label}</div>
                <div className="text-[11px] text-[var(--text-tertiary)]">{sc.desc}</div>
              </div>
              <SettingsSwitch
                ariaLabel={sc.label}
                checked={draftJev[sc.key]}
                onChange={(v) => setDraftJev((p) => ({ ...p, [sc.key]: v }))}
              />
            </div>
          ))}
        </div>

        <div className="flex justify-end">
          <Button variant="primary" size="sm" loading={savingJev} onClick={() => void handleSaveJev()}>
            保存 TypeSafe 配置
          </Button>
        </div>
      </SettingsCard>
    </div>
  );
};

const UsageBucketCard: React.FC<{
  title: string;
  bucket: CloudAIUsageBucket;
  onReset: () => void;
}> = ({ title, bucket, onReset }) => (
  <SettingsCard
    title={title}
    badge={
      <button
        type="button"
        onClick={onReset}
        title="清零该统计桶"
        className="charkle-pressable inline-flex items-center gap-1 px-2 py-0.5 rounded-[6px] text-[11px] text-[var(--text-secondary)] hover:text-[var(--text-primary)] hover:bg-[var(--bg-subtle)] cursor-pointer"
      >
        <RotateCcw size={11} />
        重置
      </button>
    }
  >
    <div className="grid grid-cols-2 gap-2.5 text-center">
      <div className="p-2.5 rounded-[var(--radius-settings-inner)] bg-[var(--bg-gallery)] border border-[var(--border-hairline)]">
        <div className="text-[10.5px] text-[var(--text-tertiary)]">今日 Tokens / 请求</div>
        <div className="text-[15px] font-semibold text-[var(--text-primary)] tabular-nums mt-0.5">
          {formatTokenCount(bucket.todayTotalTokens)}
        </div>
        <div className="text-[10.5px] text-[var(--text-secondary)] tabular-nums">
          {bucket.todayRequests} 次请求
        </div>
      </div>
      <div className="p-2.5 rounded-[var(--radius-settings-inner)] bg-[var(--bg-gallery)] border border-[var(--border-hairline)]">
        <div className="text-[10.5px] text-[var(--text-tertiary)]">累计 Tokens / 请求</div>
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
  </SettingsCard>
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
    <div className="flex items-center justify-between text-[11.5px]">
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
