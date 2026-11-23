import React, { useCallback, useEffect, useMemo, useRef, useState } from 'react';
import { createPortal } from 'react-dom';
import {
  ArrowLeft,
  ArrowRight,
  Check,
  ChevronDown,
  ChevronRight,
  Copy,
  Download,
  Folder,
  Inbox,
  KeyRound,
  LayoutGrid,
  Monitor,
  Moon,
  Plus,
  Sun,
  Upload,
  X,
} from 'lucide-react';
import {
  createDefaultAIProviderConfig,
  createDefaultDriveSyncConfig,
} from '@charkle/shared';
import type {
  AIProviderConfig,
  CloudAIProviderKind,
  CustomAIEndpointFormat,
  DriveSyncConfig,
  DriveTransportMode,
  GalleryLayoutMode,
} from '@charkle/shared';
import { apiClient } from '../../api/client';
import {
  Button,
  CharkleBrandMark,
  CharkleIcon,
  type ThemeMode,
} from '../../design-system';
import type { CaptureTarget, SettingsTabID } from '../../stores/coordinatorStore';
import { useCoordinatorStore } from '../../stores/coordinatorStore';
import { useLibraryStore } from '../../stores/libraryStore';
import { useMoodboardStore } from '../../stores/moodboardStore';
import { useSyncAIStore } from '../../stores/syncAIStore';

type StepID = 'welcome' | 'storage' | 'capture' | 'intelligence' | 'workspace' | 'ready';

const STEPS: ReadonlyArray<{ id: StepID; label: string }> = [
  { id: 'welcome', label: '欢迎' },
  { id: 'storage', label: '素材库' },
  { id: 'capture', label: '采集' },
  { id: 'intelligence', label: 'AI 智能' },
  { id: 'workspace', label: '外观' },
  { id: 'ready', label: '完成' },
];

interface QuickAIPreset {
  id: string;
  label: string;
  provider: CloudAIProviderKind;
  format: CustomAIEndpointFormat;
  baseURL: string;
  chatModel: string;
  embeddingModel: string;
}

const AI_PRESETS: readonly QuickAIPreset[] = [
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
    id: 'deepseek',
    label: 'DeepSeek',
    provider: 'openAICompatible',
    format: 'openAIChatCompletions',
    baseURL: 'https://api.deepseek.com/v1',
    chatModel: 'deepseek-chat',
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

const GalleryWireframePreview: React.FC<{ mode: GalleryLayoutMode }> = ({ mode }) => {
  return (
    <div className="w-full rounded-[12px] bg-[var(--settings-card)] border border-[var(--settings-border)] p-2.5 shadow-xs">
      {mode === 'verticalMasonry' ? (
        <div className="grid grid-cols-3 gap-1.5 h-[82px]">
          <div className="flex flex-col gap-1.5">
            <div className="h-[46px] rounded-[5px] bg-[var(--settings-subtle)] border border-[var(--settings-border)]" />
            <div className="flex-1 rounded-[5px] bg-[var(--accent-soft)] border border-[var(--accent-ring)]" />
          </div>
          <div className="flex flex-col gap-1.5">
            <div className="h-[28px] rounded-[5px] bg-[var(--settings-subtle)] border border-[var(--settings-border)]" />
            <div className="flex-1 rounded-[5px] bg-[var(--settings-subtle)] border border-[var(--settings-border)]" />
          </div>
          <div className="flex flex-col gap-1.5">
            <div className="h-[38px] rounded-[5px] bg-[var(--settings-subtle)] border border-[var(--settings-border)]" />
            <div className="flex-1 rounded-[5px] bg-[var(--settings-subtle)] border border-[var(--settings-border)]" />
          </div>
        </div>
      ) : mode === 'horizontalJustified' ? (
        <div className="flex flex-col gap-1.5 h-[82px]">
          <div className="flex gap-1.5 flex-1">
            <div className="flex-[1.3] rounded-[5px] bg-[var(--accent-soft)] border border-[var(--accent-ring)]" />
            <div className="flex-[0.8] rounded-[5px] bg-[var(--settings-subtle)] border border-[var(--settings-border)]" />
            <div className="flex-[1.1] rounded-[5px] bg-[var(--settings-subtle)] border border-[var(--settings-border)]" />
          </div>
          <div className="flex gap-1.5 flex-1">
            <div className="flex-[0.9] rounded-[5px] bg-[var(--settings-subtle)] border border-[var(--settings-border)]" />
            <div className="flex-[1.5] rounded-[5px] bg-[var(--settings-subtle)] border border-[var(--settings-border)]" />
            <div className="flex-[0.7] rounded-[5px] bg-[var(--settings-subtle)] border border-[var(--settings-border)]" />
          </div>
        </div>
      ) : (
        <div className="flex flex-col gap-1.5 h-[82px]">
          <div className="flex-1 rounded-[6px] bg-[var(--accent-soft)] border border-[var(--accent-ring)]" />
          <div className="grid grid-cols-5 gap-1 h-[18px]">
            {[0, 1, 2, 3, 4].map((idx) => (
              <div
                key={idx}
                className={[
                  'rounded-[4px] border',
                  idx === 2
                    ? 'bg-[var(--accent)]/30 border-[var(--accent)]'
                    : 'bg-[var(--settings-subtle)] border-[var(--settings-border)]',
                ].join(' ')}
              />
            ))}
          </div>
        </div>
      )}
    </div>
  );
};

interface InlineOAuthModalProps {
  open: boolean;
  onClose: () => void;
  onSaved: (autoSignInStarted: boolean) => void;
}

const InlineGoogleOAuthModal: React.FC<InlineOAuthModalProps> = ({ open, onClose, onSaved }) => {
  const [clientID, setClientID] = useState('');
  const [clientSecret, setClientSecret] = useState('');
  const [saving, setSaving] = useState(false);
  const [errorMsg, setErrorMsg] = useState<string | null>(null);
  const fileInputRef = useRef<HTMLInputElement | null>(null);

  useEffect(() => {
    if (!open) return;
    setErrorMsg(null);
  }, [open]);

  if (!open) return null;

  const handleImportJSON = async (file: File) => {
    try {
      const text = await file.text();
      const parsed = JSON.parse(text) as {
        installed?: { client_id?: string; client_secret?: string };
        web?: { client_id?: string; client_secret?: string };
        client_id?: string;
        client_secret?: string;
      };
      const block = parsed.installed ?? parsed.web ?? parsed;
      if (!block.client_id) {
        setErrorMsg('文件中未找到有效的 client_id 字段');
        return;
      }
      setClientID(block.client_id);
      if (block.client_secret) setClientSecret(block.client_secret);
      setErrorMsg(null);
    } catch {
      setErrorMsg('无法解析 JSON 文件，请确认选择的是 Google OAuth 凭据文件');
    }
  };

  const handleSave = async (startOAuth: boolean) => {
    const id = clientID.trim();
    if (!id) {
      setErrorMsg('请填写 Client ID 或导入 client_secret.json');
      return;
    }
    setSaving(true);
    setErrorMsg(null);
    try {
      await apiClient.saveGoogleOAuthConfig({
        clientID: id,
        clientSecret: clientSecret.trim(),
      });
      await useSyncAIStore.getState().loadSyncConfig();
      if (startOAuth) {
        const res = await apiClient.startGoogleOAuth();
        window.open(res.authURL, '_blank', 'noopener,noreferrer');
      }
      onSaved(startOAuth);
      onClose();
    } catch (err) {
      setErrorMsg(err instanceof Error ? err.message : '保存 OAuth 凭据失败');
    } finally {
      setSaving(false);
    }
  };

  return (
    <div
      className="fixed inset-0 z-[135] flex items-center justify-center p-4 bg-black/40 backdrop-blur-[2px]"
      onMouseDown={(e) => {
        if (e.target === e.currentTarget) onClose();
      }}
    >
      <div className="charkle-modal-panel w-full max-w-[440px] rounded-[16px] bg-[var(--settings-card)] border border-[var(--settings-border)] shadow-2xl overflow-hidden flex flex-col">
        <div className="px-5 py-3.5 border-b border-[var(--settings-divider)] flex items-center justify-between">
          <h3 className="text-[14px] font-semibold text-[var(--text-primary)]">
            配置 Google OAuth 凭据
          </h3>
          <button
            type="button"
            aria-label="关闭"
            onClick={onClose}
            className="charkle-pressable h-7 w-7 rounded-full hover:bg-[var(--settings-subtle)] text-[var(--text-secondary)] flex items-center justify-center cursor-pointer"
          >
            <X size={15} />
          </button>
        </div>

        <div className="p-5 flex flex-col gap-3.5">
          <input
            ref={fileInputRef}
            type="file"
            accept=".json,application/json"
            className="hidden"
            onChange={(e) => {
              const f = e.target.files?.[0];
              if (f) void handleImportJSON(f);
              e.target.value = '';
            }}
          />

          <button
            type="button"
            onClick={() => fileInputRef.current?.click()}
            className="charkle-pressable w-full px-3.5 py-2.5 rounded-[10px] border border-dashed border-[var(--border-strong)] bg-[var(--settings-content)] hover:border-[var(--accent)] text-[12.5px] font-medium text-[var(--text-primary)] flex items-center justify-center gap-2 cursor-pointer"
          >
            <Upload size={14} className="text-[var(--accent)]" />
            导入 client_secret.json 自动填写
          </button>

          <div className="flex flex-col gap-1">
            <label className="text-[11.5px] font-medium text-[var(--text-secondary)]">
              Client ID
            </label>
            <input
              type="text"
              value={clientID}
              onChange={(e) => setClientID(e.target.value)}
              placeholder="xxxx.apps.googleusercontent.com"
              className="h-9 px-3 text-[12.5px] font-mono rounded-[8px] bg-[var(--settings-content)] border border-[var(--settings-border)] text-[var(--text-primary)] focus:outline-none focus:border-[var(--accent)]"
            />
          </div>

          <div className="flex flex-col gap-1">
            <label className="text-[11.5px] font-medium text-[var(--text-secondary)]">
              Client Secret
            </label>
            <input
              type="password"
              value={clientSecret}
              onChange={(e) => setClientSecret(e.target.value)}
              placeholder="GOCSPX-..."
              className="h-9 px-3 text-[12.5px] font-mono rounded-[8px] bg-[var(--settings-content)] border border-[var(--settings-border)] text-[var(--text-primary)] focus:outline-none focus:border-[var(--accent)]"
            />
          </div>

          {errorMsg && (
            <div className="px-3 py-2 rounded-[8px] bg-[var(--danger-soft)] text-[var(--danger)] text-[12px]">
              {errorMsg}
            </div>
          )}

          <div className="flex items-center justify-end gap-2 pt-1">
            <Button variant="ghost" size="sm" onClick={onClose}>
              取消
            </Button>
            <Button
              variant="secondary"
              size="sm"
              loading={saving}
              onClick={() => void handleSave(false)}
            >
              仅保存
            </Button>
            <Button
              variant="skeuoPrimary"
              size="sm"
              loading={saving}
              onClick={() => void handleSave(true)}
            >
              保存并登录
            </Button>
          </div>
        </div>
      </div>
    </div>
  );
};

export const OnboardingModal: React.FC = () => {
  const onboardingOpen = useCoordinatorStore((s) => s.onboardingOpen);
  const onboardingRunID = useCoordinatorStore((s) => s.onboardingRunID);
  const completeOnboarding = useCoordinatorStore((s) => s.completeOnboarding);
  const openSettings = useCoordinatorStore((s) => s.openSettings);
  const openQuickCapture = useCoordinatorStore((s) => s.openQuickCapture);
  const pushToast = useCoordinatorStore((s) => s.pushToast);

  const themeMode = useCoordinatorStore((s) => s.themeMode);
  const setThemeMode = useCoordinatorStore((s) => s.setThemeMode);
  const brandIconVariant = useCoordinatorStore((s) => s.brandIconVariant);
  const setBrandIconVariant = useCoordinatorStore((s) => s.setBrandIconVariant);
  const layoutMode = useCoordinatorStore((s) => s.layoutMode);
  const setLayoutMode = useCoordinatorStore((s) => s.setLayoutMode);
  const sidebarCollapsed = useCoordinatorStore((s) => s.sidebarCollapsed);
  const setSidebarCollapsed = useCoordinatorStore((s) => s.setSidebarCollapsed);
  const captureTarget = useCoordinatorStore((s) => s.captureTarget);
  const setCaptureTarget = useCoordinatorStore((s) => s.setCaptureTarget);
  const activeBoardID = useCoordinatorStore((s) => s.activeBoardID);

  const folders = useLibraryStore((s) => s.folders);
  const boards = useMoodboardStore((s) => s.boards);

  const syncConfig = useSyncAIStore((s) => s.syncConfig);
  const syncStatus = useSyncAIStore((s) => s.syncStatus);
  const hasGoogleOAuthConfig = useSyncAIStore((s) => s.hasGoogleOAuthConfig);
  const hasWebDAVPassword = useSyncAIStore((s) => s.hasWebDAVPassword);
  const activeStorageSummary = useSyncAIStore((s) => s.activeStorageSummary);
  const loadSyncConfig = useSyncAIStore((s) => s.loadSyncConfig);
  const saveSyncConfig = useSyncAIStore((s) => s.saveSyncConfig);

  const aiConfig = useSyncAIStore((s) => s.aiConfig);
  const hasStoredAIKeys = useSyncAIStore((s) => s.hasStoredAIKeys);
  const chatGPTSession = useSyncAIStore((s) => s.chatGPTSession);
  const isTestingAI = useSyncAIStore((s) => s.isTestingAI);
  const loadAIConfig = useSyncAIStore((s) => s.loadAIConfig);
  const saveAIConfig = useSyncAIStore((s) => s.saveAIConfig);
  const testAIConnection = useSyncAIStore((s) => s.testAIConnection);
  const connectChatGPT = useSyncAIStore((s) => s.connectChatGPT);

  const [stepIdx, setStepIdx] = useState(0);
  const [stepDirection, setStepDirection] = useState<'forward' | 'backward'>('forward');
  const [skippedSteps, setSkippedSteps] = useState<Set<StepID>>(() => new Set());
  const [showOAuthModal, setShowOAuthModal] = useState(false);

  // Storage drafts
  const [draftSync, setDraftSync] = useState<DriveSyncConfig>(() => createDefaultDriveSyncConfig());
  const [webDAVPassword, setWebDAVPassword] = useState('');
  const [savingStorage, setSavingStorage] = useState(false);

  // Capture extension token draft
  const [generatedExtToken, setGeneratedExtToken] = useState<string | null>(null);
  const [creatingExtToken, setCreatingExtToken] = useState(false);
  const [showExtGuide, setShowExtGuide] = useState(false);

  // AI drafts
  const [draftAI, setDraftAI] = useState<AIProviderConfig>(() => createDefaultAIProviderConfig());
  const [aiKeyDraft, setAIKeyDraft] = useState('');
  const [chatGPTTokenDraft, setChatGPTTokenDraft] = useState('');
  const [savingAI, setSavingAI] = useState(false);
  const [selectedPresetID, setSelectedPresetID] = useState<string>('gemini');

  // Inline feedback banner per step
  const [actionHint, setActionHint] = useState<{ text: string; isError: boolean } | null>(null);

  const currentStep = STEPS[stepIdx] ?? STEPS[0];
  const activeBoard = useMemo(
    () => boards.find((b) => b.id === activeBoardID) ?? boards[0] ?? null,
    [boards, activeBoardID],
  );

  // Initialize fresh onboarding session when opened
  useEffect(() => {
    if (!onboardingOpen) return;
    setStepIdx(0);
    setStepDirection('forward');
    setSkippedSteps(new Set());
    setActionHint(null);
    setGeneratedExtToken(null);
    setWebDAVPassword('');
    setAIKeyDraft('');
    setChatGPTTokenDraft('');

    void loadSyncConfig().catch(() => {});
    void loadAIConfig().catch(() => {});
  }, [onboardingOpen, onboardingRunID, loadSyncConfig, loadAIConfig]);

  useEffect(() => {
    if (syncConfig) setDraftSync(syncConfig);
  }, [syncConfig]);

  useEffect(() => {
    setDraftAI(aiConfig);
    if (aiConfig.provider === 'gemini') {
      setSelectedPresetID('gemini');
    } else if (aiConfig.provider === 'openAICompatible') {
      const url = (aiConfig.baseURL || '').toLowerCase();
      if (aiConfig.customEndpointFormat === 'anthropicMessages' || url.includes('anthropic')) {
        setSelectedPresetID('claude');
      } else if (url.includes('deepseek')) {
        setSelectedPresetID('deepseek');
      } else if (url.includes('localhost') || url.includes('127.0.0.1') || url.includes('11434')) {
        setSelectedPresetID('ollama');
      } else {
        setSelectedPresetID('openai');
      }
    }
  }, [aiConfig]);

  // Escape closes onboarding unless sub-modal is open
  useEffect(() => {
    if (!onboardingOpen) return;
    const onKeyDown = (e: KeyboardEvent) => {
      if (e.key === 'Escape' && !showOAuthModal) {
        e.preventDefault();
        e.stopPropagation();
        completeOnboarding();
      }
    };
    window.addEventListener('keydown', onKeyDown, true);
    return () => window.removeEventListener('keydown', onKeyDown, true);
  }, [onboardingOpen, showOAuthModal, completeOnboarding]);

  const goToStep = useCallback(
    (targetIdx: number, markCurrentSkipped = false) => {
      const clamped = Math.max(0, Math.min(STEPS.length - 1, targetIdx));
      if (markCurrentSkipped) {
        const curID = STEPS[stepIdx]?.id;
        if (curID && curID !== 'welcome' && curID !== 'ready') {
          setSkippedSteps((prev) => new Set(prev).add(curID));
        }
      } else {
        const curID = STEPS[stepIdx]?.id;
        if (curID) {
          setSkippedSteps((prev) => {
            if (!prev.has(curID)) return prev;
            const next = new Set(prev);
            next.delete(curID);
            return next;
          });
        }
      }
      setStepDirection(clamped >= stepIdx ? 'forward' : 'backward');
      setActionHint(null);
      setStepIdx(clamped);
    },
    [stepIdx],
  );

  const jumpToStepID = (id: StepID) => {
    const idx = STEPS.findIndex((s) => s.id === id);
    if (idx >= 0) goToStep(idx, false);
  };

  const finishAndOpenSettings = (tab: SettingsTabID) => {
    completeOnboarding();
    openSettings(tab);
  };

  if (!onboardingOpen || typeof document === 'undefined') return null;

  // Derived storage state
  const activeStorageMode: DriveTransportMode =
    draftSync.mode === 'gdirectMount' ? 'directAPIWithGDirect' : draftSync.mode;
  const isLocal = activeStorageMode === 'localOnly';
  const isGoogle = activeStorageMode === 'directAPIWithGDirect';
  const isWebDAV = activeStorageMode === 'webDAV';
  const googleAccount =
    syncStatus.account &&
    syncStatus.account.source !== 'WebDAV' &&
    syncStatus.account.source !== '本地文件夹'
      ? syncStatus.account
      : null;

  const handleSelectStorageMode = async (mode: DriveTransportMode) => {
    const next = { ...draftSync, mode };
    setDraftSync(next);
    setActionHint(null);
    if (mode === 'localOnly') {
      try {
        await saveSyncConfig(next);
      } catch {
        // Keep draft editable
      }
    }
  };

  const handleSaveLocalPath = async () => {
    setSavingStorage(true);
    setActionHint(null);
    try {
      await saveSyncConfig({ ...draftSync, mode: 'localOnly' });
      setActionHint({ text: '本地目录路径已保存', isError: false });
    } catch (err) {
      setActionHint({
        text: err instanceof Error ? err.message : '保存路径失败',
        isError: true,
      });
    } finally {
      setSavingStorage(false);
    }
  };

  const handleStartGoogleLogin = async () => {
    setSavingStorage(true);
    setActionHint(null);
    try {
      await saveSyncConfig({ ...draftSync, mode: 'directAPIWithGDirect' });
      const res = await apiClient.startGoogleOAuth();
      window.open(res.authURL, '_blank', 'noopener,noreferrer');
      setActionHint({ text: '已打开 Google 登录页面，授权完成后返回即可', isError: false });
    } catch (err) {
      setActionHint({
        text: err instanceof Error ? err.message : '启动 Google 登录失败',
        isError: true,
      });
    } finally {
      setSavingStorage(false);
    }
  };

  const handleTestAndSaveWebDAV = async () => {
    if (!draftSync.webDAVServerURL.trim()) {
      setActionHint({ text: '请先填写 WebDAV 服务器地址', isError: true });
      return;
    }
    setSavingStorage(true);
    setActionHint(null);
    try {
      const nextConfig: DriveSyncConfig = {
        ...draftSync,
        mode: 'webDAV',
        webDAVServerURL: draftSync.webDAVServerURL.trim(),
        webDAVUsername: draftSync.webDAVUsername.trim(),
        webDAVRemotePath: draftSync.webDAVRemotePath.trim() || '/Charkle',
      };
      await apiClient.testWebDAV({
        config: nextConfig,
        password: webDAVPassword || null,
      });
      await saveSyncConfig(nextConfig, webDAVPassword || null);
      setWebDAVPassword('');
      setActionHint({ text: 'WebDAV 测试通过并已保存', isError: false });
    } catch (err) {
      setActionHint({
        text: err instanceof Error ? err.message : 'WebDAV 连接失败',
        isError: true,
      });
    } finally {
      setSavingStorage(false);
    }
  };

  const handleGenerateExtensionToken = async () => {
    setCreatingExtToken(true);
    setActionHint(null);
    try {
      const res = await apiClient.createApiToken({
        name: 'Charkle 浏览器扩展',
        scopes: ['read', 'write'],
      });
      setGeneratedExtToken(res.token);
      setActionHint({ text: '已生成扩展专用访问令牌，请复制保存', isError: false });
    } catch (err) {
      setActionHint({
        text: err instanceof Error ? err.message : '生成令牌失败',
        isError: true,
      });
    } finally {
      setCreatingExtToken(false);
    }
  };

  const handleSelectAIMode = async (mode: 'disabled' | 'chatGPTSubscription' | 'api') => {
    setActionHint(null);
    if (mode === 'disabled') {
      const next: AIProviderConfig = { ...draftAI, provider: 'disabled' };
      setDraftAI(next);
      try {
        await saveAIConfig(next);
      } catch {
        // Ignore
      }
      return;
    }
    if (mode === 'chatGPTSubscription') {
      setDraftAI((prev) => ({ ...prev, provider: 'chatGPTSubscription' }));
      return;
    }
    const preset = AI_PRESETS.find((p) => p.id === selectedPresetID) ?? AI_PRESETS[0];
    setDraftAI((prev) => ({
      ...prev,
      provider: preset.provider,
      customEndpointFormat: preset.format,
      baseURL: prev.provider === preset.provider && prev.baseURL ? prev.baseURL : preset.baseURL,
      chatModel:
        prev.provider === preset.provider && prev.chatModel ? prev.chatModel : preset.chatModel,
      embeddingModel:
        prev.provider === preset.provider && prev.embeddingModel
          ? prev.embeddingModel
          : preset.embeddingModel,
    }));
  };

  const handleApplyAIPreset = (preset: QuickAIPreset) => {
    setSelectedPresetID(preset.id);
    setActionHint(null);
    setDraftAI((prev) => ({
      ...prev,
      provider: preset.provider,
      customEndpointFormat: preset.format,
      baseURL: preset.baseURL,
      chatModel: preset.chatModel,
      embeddingModel: preset.embeddingModel,
    }));
  };

  const handleConnectChatGPT = async () => {
    if (!chatGPTTokenDraft.trim()) {
      setActionHint({ text: '请先输入 ChatGPT 访问凭据', isError: true });
      return;
    }
    setSavingAI(true);
    setActionHint(null);
    try {
      await connectChatGPT({ accessToken: chatGPTTokenDraft.trim() });
      setChatGPTTokenDraft('');
      setActionHint({ text: 'ChatGPT 订阅账号已连接', isError: false });
    } catch (err) {
      setActionHint({
        text: err instanceof Error ? err.message : '连接 ChatGPT 失败',
        isError: true,
      });
    } finally {
      setSavingAI(false);
    }
  };

  const handleTestAI = async () => {
    setActionHint(null);
    try {
      const summary = await testAIConnection(draftAI, aiKeyDraft.trim() || null);
      setActionHint({ text: summary, isError: false });
    } catch (err) {
      setActionHint({
        text: err instanceof Error ? err.message : '连接测试失败',
        isError: true,
      });
    }
  };

  const handleSaveAI = async () => {
    setSavingAI(true);
    setActionHint(null);
    try {
      await saveAIConfig(draftAI, aiKeyDraft.trim() || null);
      setAIKeyDraft('');
      setActionHint({ text: 'AI 模型配置已保存', isError: false });
    } catch (err) {
      setActionHint({
        text: err instanceof Error ? err.message : '保存配置失败',
        isError: true,
      });
    } finally {
      setSavingAI(false);
    }
  };

  const handleSelectCaptureTargetType = (type: CaptureTarget['type']) => {
    if (type === 'inbox') {
      setCaptureTarget({ type: 'inbox' });
    } else if (type === 'folder') {
      const firstID =
        captureTarget.type === 'folder' ? captureTarget.folderID : folders[0]?.id;
      if (firstID) setCaptureTarget({ type: 'folder', folderID: firstID });
      else pushToast({ tone: 'info', message: '创建文件夹后可将其设为默认采集目录' });
    } else if (type === 'activeMoodboard') {
      if (activeBoard) setCaptureTarget({ type: 'activeMoodboard' });
      else pushToast({ tone: 'info', message: '创建情绪板后可将其设为默认接收目标' });
    }
  };

  const serviceOrigin = typeof window !== 'undefined' ? window.location.origin : '';

  const summaryStorageText = isLocal
    ? `本地目录（${activeStorageSummary || '默认目录'}）`
    : isGoogle
      ? googleAccount
        ? `Google Drive · ${googleAccount.email}`
        : 'Google Drive（待登录）'
      : draftSync.webDAVServerURL
        ? `WebDAV · ${draftSync.webDAVServerURL}`
        : 'WebDAV（待填写）';

  const summaryCaptureText =
    captureTarget.type === 'folder'
      ? `默认存入「${folders.find((f) => f.id === captureTarget.folderID)?.name ?? '指定文件夹'}」`
      : captureTarget.type === 'activeMoodboard' && activeBoard
        ? `默认加入「${activeBoard.title}」`
        : '默认存入收件箱 · 支持扩展与 ⌘V';

  const summaryAIText =
    aiConfig.provider === 'disabled'
      ? '内置离线配色与相似检索'
      : aiConfig.provider === 'chatGPTSubscription'
        ? chatGPTSession?.status === 'connected'
          ? `ChatGPT 订阅（${aiConfig.chatModel || '已连接'}）`
          : 'ChatGPT 订阅（待连接）'
        : aiConfig.provider === 'gemini'
          ? `Gemini · ${aiConfig.chatModel || 'gemini-2.5-flash'}`
          : `${aiConfig.chatModel || '自定义模型'}`;

  const summaryWorkspaceText = `${
    themeMode === 'light' ? '浅色' : themeMode === 'dark' ? '深色' : '跟随系统'
  } · ${
    layoutMode === 'verticalMasonry'
      ? '纵向瀑布流'
      : layoutMode === 'horizontalJustified'
        ? '横向等高行'
        : '画廊视图'
  }`;

  const stepAnimClass =
    stepDirection === 'forward' ? 'charkle-step-from-right' : 'charkle-step-from-left';

  return createPortal(
    <div
      role="dialog"
      aria-modal="true"
      aria-label="欢迎使用 Charkle"
      className="charkle-modal-backdrop fixed inset-0 z-[120] flex items-center justify-center p-4 sm:p-6 bg-black/35 dark:bg-black/55 backdrop-blur-[3px] select-none"
    >
      <div className="charkle-modal-panel w-[min(840px,calc(100vw-48px))] h-[min(636px,calc(100vh-48px))] rounded-[20px] bg-[var(--settings-content)] border border-[var(--settings-border)] shadow-[0_24px_64px_rgba(0,0,0,0.24),0_4px_12px_rgba(0,0,0,0.08)] flex flex-col overflow-hidden">
        {/* Header Bar */}
        <div className="px-5 pt-3.5 pb-3 border-b border-[var(--settings-border)] flex items-center justify-between gap-3 shrink-0">
          <div className="w-[108px] flex items-center gap-2 shrink-0">
            <CharkleBrandMark size={22} />
            <span className="text-[14px] font-semibold tracking-[-0.015em] text-[var(--text-primary)]">
              Charkle
            </span>
          </div>

          {/* Interactive 6-Step Pill Rail */}
          <div className="flex items-center gap-0.5 p-[3px] rounded-full bg-[var(--settings-subtle)] overflow-x-auto">
            {STEPS.map((step, idx) => {
              const isActive = idx === stepIdx;
              const isPast = idx < stepIdx;
              const wasSkipped = skippedSteps.has(step.id);
              return (
                <button
                  key={step.id}
                  type="button"
                  onClick={() => goToStep(idx, false)}
                  className={[
                    'px-2.5 py-1 rounded-full text-[11.5px] inline-flex items-center gap-1.5 cursor-pointer shrink-0',
                    'transition-[background-color,color,box-shadow] duration-[var(--duration-move)] ease-[var(--ease-in-out)]',
                    isActive
                      ? 'bg-[var(--settings-card)] text-[var(--text-primary)] font-semibold border border-[var(--settings-border)] shadow-xs'
                      : 'text-[var(--text-secondary)] hover:text-[var(--text-primary)] font-medium border border-transparent',
                  ].join(' ')}
                >
                  {isPast && !wasSkipped ? (
                    <Check size={10} strokeWidth={2.8} className="text-[var(--settings-positive)]" />
                  ) : isPast && wasSkipped ? (
                    <span className="h-1.5 w-1.5 rounded-full border border-[var(--text-tertiary)]" />
                  ) : (
                    <span
                      className={[
                        'h-1.5 w-1.5 rounded-full',
                        isActive ? 'bg-[var(--text-primary)]' : 'bg-[var(--text-tertiary)]/50',
                      ].join(' ')}
                    />
                  )}
                  <span>{step.label}</span>
                </button>
              );
            })}
          </div>

          <div className="w-[108px] flex justify-end shrink-0">
            {currentStep.id !== 'ready' && (
              <button
                type="button"
                onClick={completeOnboarding}
                title="跳过引导 (Esc)"
                className="charkle-pressable px-2.5 py-1 rounded-full text-[11.5px] font-medium text-[var(--text-secondary)] hover:text-[var(--text-primary)] hover:bg-[var(--settings-subtle)] inline-flex items-center gap-1 cursor-pointer"
              >
                跳过引导
                <X size={12} />
              </button>
            )}
          </div>
        </div>

        {/* Step Body */}
        <div className="flex-1 min-h-0 overflow-hidden relative">
          <div
            key={currentStep.id}
            className={`w-full h-full overflow-y-auto charkle-scroll ${stepAnimClass}`}
          >
            {/* STEP 0: WELCOME */}
            {currentStep.id === 'welcome' && (
              <div className="h-full flex flex-col items-center justify-center px-7 py-6 gap-6">
                <div className="flex flex-col items-center text-center gap-2.5">
                  <div className="relative h-[88px] w-[88px] flex items-center justify-center">
                    <div
                      aria-hidden="true"
                      className="absolute inset-0 rounded-full"
                      style={{
                        background:
                          'radial-gradient(circle, rgba(59, 116, 232, 0.14) 0%, transparent 70%)',
                      }}
                    />
                    <CharkleBrandMark size={60} className="relative shadow-lg" />
                  </div>
                  <h2 className="text-[25px] font-bold tracking-[-0.025em] text-[var(--text-primary)]">
                    欢迎使用 Charkle
                  </h2>
                  <p className="text-[13px] text-[var(--text-secondary)] max-w-[440px]">
                    花 1 分钟按需选几项偏好，或直接跳过立即开始。
                  </p>
                </div>

                <div className="w-full grid grid-cols-2 sm:grid-cols-4 gap-3">
                  {[
                    {
                      icon: 'inbox',
                      accent: '#3B74E8',
                      title: '浏览器与剪贴板随手收',
                      desc: '右键收藏网页图文、全局粘贴或直接拖入窗口',
                      target: 'capture' as StepID,
                    },
                    {
                      icon: 'library',
                      accent: '#D96B43',
                      title: '本地与云盘灵活切换',
                      desc: '支持本地目录、Google Drive 与 WebDAV 同步',
                      target: 'storage' as StepID,
                    },
                    {
                      icon: 'ai-spark',
                      accent: '#2A8F9D',
                      title: '基础识图 + 可选云 AI',
                      desc: '免费内置配色与相似推荐，按需接入云端模型',
                      target: 'intelligence' as StepID,
                    },
                    {
                      icon: 'moodboard',
                      accent: '#3D9970',
                      title: '自由画布与 Figma 导出',
                      desc: '自由拼板整理灵感，导出可编辑 Figma 文件',
                      target: 'workspace' as StepID,
                    },
                  ].map((card, i) => (
                    <button
                      key={card.title}
                      type="button"
                      onClick={() => jumpToStepID(card.target)}
                      style={{ animationDelay: `${i * 45}ms` }}
                      className="charkle-pressable text-left p-3.5 rounded-[14px] bg-[var(--settings-card)] border border-[var(--settings-border)] hover:border-[var(--border-strong)] shadow-xs flex flex-col gap-2.5 cursor-pointer"
                    >
                      <div
                        className="h-[48px] w-[48px] rounded-[11px] flex items-center justify-center"
                        style={{ backgroundColor: `${card.accent}18` }}
                      >
                        <CharkleIcon name={card.icon} style="layered" size={34} />
                      </div>
                      <div className="flex flex-col gap-1">
                        <div className="text-[12.5px] font-semibold text-[var(--text-primary)] leading-snug">
                          {card.title}
                        </div>
                        <div className="text-[11.5px] text-[var(--text-secondary)] leading-relaxed">
                          {card.desc}
                        </div>
                      </div>
                    </button>
                  ))}
                </div>
              </div>
            )}

            {/* STEP 1: STORAGE */}
            {currentStep.id === 'storage' && (
              <div className="min-h-full grid grid-cols-1 md:grid-cols-[234px_1fr]">
                {/* Left Pedestal */}
                <div className="bg-[var(--settings-rail)] border-b md:border-b-0 md:border-r border-[var(--settings-border)] p-6 flex flex-col items-center justify-center text-center gap-3.5">
                  <div
                    className="h-[84px] w-[84px] rounded-[22px] flex items-center justify-center"
                    style={{
                      backgroundColor: isLocal ? 'rgba(217,107,67,0.12)' : 'rgba(59,116,232,0.12)',
                    }}
                  >
                    <CharkleIcon name={isLocal ? 'folder' : 'drive'} style="layered" size={56} />
                  </div>
                  <span className="px-2.5 py-0.5 rounded-full text-[11px] font-medium bg-[var(--settings-card)] border border-[var(--settings-border)] text-[var(--text-secondary)]">
                    {isLocal ? '本地目录保存' : googleAccount ? '已连接云端' : '多设备自动同步'}
                  </span>
                  <p className="text-[12px] text-[var(--text-secondary)] leading-relaxed">
                    {isLocal
                      ? '素材原件与索引直接留在服务端本地目录，开箱即用。'
                      : '文件夹、素材与情绪板增量同步，随时可在设置中无损迁移。'}
                  </p>
                </div>

                {/* Right Controls */}
                <div className="p-6 flex flex-col gap-3.5">
                  <div className="flex items-start justify-between gap-2">
                    <div>
                      <h3 className="text-[17px] font-semibold text-[var(--text-primary)]">
                        素材库保存在哪里？
                      </h3>
                      <p className="text-[12px] text-[var(--text-secondary)] mt-0.5">
                        默认使用本地目录，也可现在或稍后再接入云盘。
                      </p>
                    </div>
                    <span className="px-2 py-0.5 rounded-full text-[10.5px] bg-[var(--settings-subtle)] text-[var(--text-tertiary)] shrink-0">
                      可选 · 可跳过
                    </span>
                  </div>

                  {/* Option 1: Local Folder */}
                  <div
                    onClick={() => void handleSelectStorageMode('localOnly')}
                    className={[
                      'p-3.5 rounded-[12px] bg-[var(--settings-card)] border cursor-pointer flex flex-col gap-2.5',
                      isLocal
                        ? 'border-[var(--text-primary)]/45 ring-1 ring-[var(--text-primary)]/10'
                        : 'border-[var(--settings-border)] hover:border-[var(--border-strong)]',
                    ].join(' ')}
                  >
                    <div className="flex items-center justify-between gap-2">
                      <div className="flex items-center gap-2">
                        <CharkleIcon name="library" size={16} isActive={isLocal} />
                        <span className="text-[13px] font-semibold text-[var(--text-primary)]">
                          本地文件夹
                        </span>
                        <span className="px-1.5 py-0.5 rounded-full text-[10px] font-medium bg-[var(--success-soft)] text-[var(--settings-positive)]">
                          默认推荐
                        </span>
                      </div>
                      <span
                        className={[
                          'h-4 w-4 rounded-full border flex items-center justify-center',
                          isLocal
                            ? 'border-[var(--accent)] bg-[var(--accent)] text-white'
                            : 'border-[var(--border-strong)]',
                        ].join(' ')}
                      >
                        {isLocal && <Check size={10} strokeWidth={3} />}
                      </span>
                    </div>
                    {isLocal && (
                      <div
                        className="flex items-center gap-2 pt-1"
                        onClick={(e) => e.stopPropagation()}
                      >
                        <input
                          type="text"
                          value={draftSync.localLibraryPath}
                          onChange={(e) =>
                            setDraftSync((prev) => ({ ...prev, localLibraryPath: e.target.value }))
                          }
                          placeholder={activeStorageSummary || '.charkle-data/library'}
                          className="flex-1 min-w-0 h-8 px-2.5 text-[12px] font-mono rounded-[8px] bg-[var(--settings-content)] border border-[var(--settings-border)] text-[var(--text-primary)] focus:outline-none focus:border-[var(--accent)]"
                        />
                        <Button
                          variant="secondary"
                          size="xs"
                          loading={savingStorage}
                          onClick={() => void handleSaveLocalPath()}
                        >
                          保存路径
                        </Button>
                      </div>
                    )}
                  </div>

                  {/* Option 2: Google Drive */}
                  <div
                    onClick={() => void handleSelectStorageMode('directAPIWithGDirect')}
                    className={[
                      'p-3.5 rounded-[12px] bg-[var(--settings-card)] border cursor-pointer flex flex-col gap-2.5',
                      isGoogle
                        ? 'border-[var(--text-primary)]/45 ring-1 ring-[var(--text-primary)]/10'
                        : 'border-[var(--settings-border)] hover:border-[var(--border-strong)]',
                    ].join(' ')}
                  >
                    <div className="flex items-center justify-between gap-2">
                      <div className="flex items-center gap-2">
                        <CharkleIcon name="drive-sync" size={16} isActive={isGoogle} />
                        <span className="text-[13px] font-semibold text-[var(--text-primary)]">
                          Google Drive 云端直连
                        </span>
                        {googleAccount && (
                          <span className="px-1.5 py-0.5 rounded-full text-[10px] font-medium bg-[var(--success-soft)] text-[var(--settings-positive)]">
                            已连接
                          </span>
                        )}
                      </div>
                      <span
                        className={[
                          'h-4 w-4 rounded-full border flex items-center justify-center',
                          isGoogle
                            ? 'border-[var(--accent)] bg-[var(--accent)] text-white'
                            : 'border-[var(--border-strong)]',
                        ].join(' ')}
                      >
                        {isGoogle && <Check size={10} strokeWidth={3} />}
                      </span>
                    </div>
                    {isGoogle && (
                      <div
                        className="flex items-center justify-between gap-2 pt-1"
                        onClick={(e) => e.stopPropagation()}
                      >
                        {googleAccount ? (
                          <span className="text-[12px] text-[var(--settings-positive)] font-medium truncate">
                            {googleAccount.email}
                          </span>
                        ) : hasGoogleOAuthConfig ? (
                          <>
                            <span className="text-[11.5px] text-[var(--text-secondary)]">
                              凭据已就绪，点击前往 Google 授权
                            </span>
                            <Button
                              variant="primary"
                              size="xs"
                              loading={savingStorage}
                              onClick={() => void handleStartGoogleLogin()}
                            >
                              使用 Google 登录
                            </Button>
                          </>
                        ) : (
                          <>
                            <span className="text-[11.5px] text-[var(--text-secondary)]">
                              导入 client_secret.json 或填写 OAuth 凭据
                            </span>
                            <Button
                              variant="primary"
                              size="xs"
                              onClick={() => setShowOAuthModal(true)}
                            >
                              配置凭据并登录…
                            </Button>
                          </>
                        )}
                      </div>
                    )}
                  </div>

                  {/* Option 3: WebDAV / NAS */}
                  <div
                    onClick={() => void handleSelectStorageMode('webDAV')}
                    className={[
                      'p-3.5 rounded-[12px] bg-[var(--settings-card)] border cursor-pointer flex flex-col gap-2.5',
                      isWebDAV
                        ? 'border-[var(--text-primary)]/45 ring-1 ring-[var(--text-primary)]/10'
                        : 'border-[var(--settings-border)] hover:border-[var(--border-strong)]',
                    ].join(' ')}
                  >
                    <div className="flex items-center justify-between gap-2">
                      <div className="flex items-center gap-2">
                        <CharkleIcon name="drive-sync" size={16} isActive={isWebDAV} />
                        <span className="text-[13px] font-semibold text-[var(--text-primary)]">
                          WebDAV 云盘 / NAS
                        </span>
                        {isWebDAV && draftSync.webDAVServerURL && hasWebDAVPassword && (
                          <span className="px-1.5 py-0.5 rounded-full text-[10px] font-medium bg-[var(--success-soft)] text-[var(--settings-positive)]">
                            已保存
                          </span>
                        )}
                      </div>
                      <span
                        className={[
                          'h-4 w-4 rounded-full border flex items-center justify-center',
                          isWebDAV
                            ? 'border-[var(--accent)] bg-[var(--accent)] text-white'
                            : 'border-[var(--border-strong)]',
                        ].join(' ')}
                      >
                        {isWebDAV && <Check size={10} strokeWidth={3} />}
                      </span>
                    </div>

                    {isWebDAV && (
                      <div
                        className="flex flex-col gap-2 pt-1"
                        onClick={(e) => e.stopPropagation()}
                      >
                        <input
                          type="url"
                          value={draftSync.webDAVServerURL}
                          onChange={(e) =>
                            setDraftSync((prev) => ({ ...prev, webDAVServerURL: e.target.value }))
                          }
                          placeholder="服务器地址（如 https://dav.jianguoyun.com/dav/）"
                          className="h-8 px-2.5 text-[12px] rounded-[8px] bg-[var(--settings-content)] border border-[var(--settings-border)] text-[var(--text-primary)] focus:outline-none focus:border-[var(--accent)]"
                        />
                        <div className="grid grid-cols-2 gap-2">
                          <input
                            type="text"
                            value={draftSync.webDAVUsername}
                            onChange={(e) =>
                              setDraftSync((prev) => ({ ...prev, webDAVUsername: e.target.value }))
                            }
                            placeholder="用户名"
                            className="h-8 px-2.5 text-[12px] rounded-[8px] bg-[var(--settings-content)] border border-[var(--settings-border)] text-[var(--text-primary)] focus:outline-none focus:border-[var(--accent)]"
                          />
                          <input
                            type="password"
                            value={webDAVPassword}
                            onChange={(e) => setWebDAVPassword(e.target.value)}
                            placeholder={hasWebDAVPassword ? '已保存（留空不变）' : '应用密码'}
                            className="h-8 px-2.5 text-[12px] rounded-[8px] bg-[var(--settings-content)] border border-[var(--settings-border)] text-[var(--text-primary)] focus:outline-none focus:border-[var(--accent)]"
                          />
                        </div>
                        <div className="flex justify-end">
                          <Button
                            variant="primary"
                            size="xs"
                            loading={savingStorage}
                            onClick={() => void handleTestAndSaveWebDAV()}
                          >
                            测试并保存
                          </Button>
                        </div>
                      </div>
                    )}
                  </div>

                  {actionHint && (
                    <div
                      className={[
                        'px-3 py-2 rounded-[8px] text-[12px]',
                        actionHint.isError
                          ? 'bg-[var(--danger-soft)] text-[var(--danger)]'
                          : 'bg-[var(--success-soft)] text-[var(--settings-positive)]',
                      ].join(' ')}
                    >
                      {actionHint.text}
                    </div>
                  )}
                </div>
              </div>
            )}

            {/* STEP 2: CAPTURE (WEB-NATIVE) */}
            {currentStep.id === 'capture' && (
              <div className="min-h-full grid grid-cols-1 md:grid-cols-[234px_1fr]">
                {/* Left Pedestal */}
                <div className="bg-[var(--settings-rail)] border-b md:border-b-0 md:border-r border-[var(--settings-border)] p-6 flex flex-col items-center justify-center text-center gap-3.5">
                  <div className="h-[84px] w-[84px] rounded-[22px] bg-[#3B74E8]/12 flex items-center justify-center">
                    <CharkleIcon name="inbox" style="layered" size={56} />
                  </div>
                  <span className="px-2.5 py-0.5 rounded-full text-[11px] font-medium bg-[var(--settings-card)] border border-[var(--settings-border)] text-[var(--text-secondary)]">
                    跨网页随手收集
                  </span>
                  <p className="text-[12px] text-[var(--text-secondary)] leading-relaxed">
                    搭配浏览器扩展右键收藏任意网页素材，或在应用内直接拖入文件、按 ⌘V 粘贴。
                  </p>
                  <Button
                    variant="secondary"
                    size="xs"
                    onClick={() => {
                      completeOnboarding();
                      openQuickCapture();
                    }}
                  >
                    <Plus size={12.5} />
                    打开快速采集 (⇧⌘N)
                  </Button>
                </div>

                {/* Right Content */}
                <div className="p-6 flex flex-col gap-3.5">
                  <div className="flex items-start justify-between gap-2">
                    <div>
                      <h3 className="text-[17px] font-semibold text-[var(--text-primary)]">
                        设置常用采集方式
                      </h3>
                      <p className="text-[12px] text-[var(--text-secondary)] mt-0.5">
                        下载浏览器扩展以便跨网站一键收藏，并指定默认收纳位置。
                      </p>
                    </div>
                    <span className="px-2 py-0.5 rounded-full text-[10.5px] bg-[var(--settings-subtle)] text-[var(--text-tertiary)] shrink-0">
                      可选 · 可跳过
                    </span>
                  </div>

                  {/* Card 1: Browser Clipper Extension */}
                  <div className="p-4 rounded-[12px] bg-[var(--settings-card)] border border-[var(--settings-border)] flex flex-col gap-3">
                    <div className="flex items-center justify-between gap-2">
                      <div>
                        <div className="text-[13px] font-semibold text-[var(--text-primary)]">
                          浏览器采集扩展
                        </div>
                        <div className="text-[11.5px] text-[var(--text-secondary)] mt-0.5">
                          适用于 Chrome / Edge / Arc / Brave，支持右键收藏、批量抓图与截屏
                        </div>
                      </div>
                    </div>

                    <div className="flex flex-wrap items-center gap-2">
                      <a
                        href={apiClient.extensionDownloadURL()}
                        download="charkle-web-clipper-extension.zip"
                        className="charkle-pressable h-7.5 px-3 rounded-[8px] bg-[var(--accent)] hover:bg-[var(--accent-hover)] text-white text-[12px] font-medium inline-flex items-center gap-1.5"
                      >
                        <Download size={12.5} />
                        下载扩展 (.zip)
                      </a>
                      <Button
                        variant="secondary"
                        size="xs"
                        loading={creatingExtToken}
                        onClick={() => void handleGenerateExtensionToken()}
                      >
                        <KeyRound size={12.5} />
                        生成扩展令牌
                      </Button>
                      <Button
                        variant="ghost"
                        size="xs"
                        onClick={async () => {
                          await navigator.clipboard.writeText(serviceOrigin).catch(() => {});
                          pushToast({ tone: 'info', message: `已复制服务地址 ${serviceOrigin}` });
                        }}
                      >
                        <Copy size={12} />
                        复制服务地址
                      </Button>
                    </div>

                    {generatedExtToken && (
                      <div className="p-2.5 rounded-[8px] bg-[var(--settings-content)] border border-[var(--settings-border)] flex flex-col gap-1.5">
                        <div className="text-[11px] text-[var(--settings-warning)] font-medium">
                          请立即复制保存，关闭后不再完整展示
                        </div>
                        <div className="flex items-center gap-2">
                          <code className="flex-1 min-w-0 text-[11.5px] font-mono text-[var(--text-primary)] truncate select-all">
                            {generatedExtToken}
                          </code>
                          <Button
                            variant="secondary"
                            size="xs"
                            onClick={async () => {
                              await navigator.clipboard.writeText(generatedExtToken).catch(() => {});
                              pushToast({ tone: 'success', message: '已复制扩展访问令牌' });
                            }}
                          >
                            <Copy size={11.5} />
                            复制
                          </Button>
                        </div>
                        <div className="text-[11px] font-mono text-[var(--text-tertiary)] truncate">
                          服务地址：{serviceOrigin}
                        </div>
                      </div>
                    )}

                    <div>
                      <button
                        type="button"
                        onClick={() => setShowExtGuide((v) => !v)}
                        className="inline-flex items-center gap-1 text-[11.5px] font-medium text-[var(--text-secondary)] hover:text-[var(--text-primary)] cursor-pointer"
                      >
                        {showExtGuide ? <ChevronDown size={13} /> : <ChevronRight size={13} />}
                        如何安装（3 步）
                      </button>
                      {showExtGuide && (
                        <ol className="mt-2 p-2.5 rounded-[8px] bg-[var(--settings-subtle)] text-[11.5px] text-[var(--text-secondary)] flex flex-col gap-1 list-decimal list-inside">
                          <li>下载并解压扩展压缩包到本地文件夹</li>
                          <li>打开浏览器扩展管理页，开启「开发者模式」并加载已解压文件夹</li>
                          <li>在扩展设置中填入上方服务地址与访问令牌即可开始收藏</li>
                        </ol>
                      )}
                    </div>
                  </div>

                  {/* Card 2: Default Capture Target */}
                  <div className="p-4 rounded-[12px] bg-[var(--settings-card)] border border-[var(--settings-border)] flex flex-col gap-2.5">
                    <div className="text-[13px] font-semibold text-[var(--text-primary)]">
                      默认采集去向
                    </div>
                    <div className="flex flex-wrap items-center gap-1.5">
                      <button
                        type="button"
                        onClick={() => handleSelectCaptureTargetType('inbox')}
                        className={[
                          'charkle-pressable h-7.5 px-2.5 rounded-[8px] text-[12px] inline-flex items-center gap-1.5 border cursor-pointer',
                          captureTarget.type === 'inbox'
                            ? 'bg-[var(--accent-soft)] border-[var(--accent-ring)] text-[var(--accent)] font-medium'
                            : 'bg-[var(--settings-subtle)] border-transparent text-[var(--text-secondary)] hover:text-[var(--text-primary)]',
                        ].join(' ')}
                      >
                        <Inbox size={12.5} />
                        收件箱
                      </button>

                      <button
                        type="button"
                        onClick={() => handleSelectCaptureTargetType('folder')}
                        className={[
                          'charkle-pressable h-7.5 px-2.5 rounded-[8px] text-[12px] inline-flex items-center gap-1.5 border cursor-pointer',
                          captureTarget.type === 'folder'
                            ? 'bg-[var(--accent-soft)] border-[var(--accent-ring)] text-[var(--accent)] font-medium'
                            : 'bg-[var(--settings-subtle)] border-transparent text-[var(--text-secondary)] hover:text-[var(--text-primary)]',
                        ].join(' ')}
                      >
                        <Folder size={12.5} />
                        指定文件夹
                      </button>

                      {captureTarget.type === 'folder' && folders.length > 0 && (
                        <select
                          aria-label="选择默认文件夹"
                          value={captureTarget.folderID}
                          onChange={(e) =>
                            setCaptureTarget({ type: 'folder', folderID: e.target.value })
                          }
                          className="h-7.5 px-2 text-[12px] rounded-[8px] bg-[var(--settings-content)] border border-[var(--settings-border)] text-[var(--text-primary)] focus:outline-none focus:border-[var(--accent)] max-w-[160px]"
                        >
                          {folders.map((f) => (
                            <option key={f.id} value={f.id}>
                              {f.name}
                            </option>
                          ))}
                        </select>
                      )}

                      <button
                        type="button"
                        disabled={!activeBoard}
                        onClick={() => handleSelectCaptureTargetType('activeMoodboard')}
                        className={[
                          'charkle-pressable h-7.5 px-2.5 rounded-[8px] text-[12px] inline-flex items-center gap-1.5 border cursor-pointer disabled:opacity-45',
                          captureTarget.type === 'activeMoodboard'
                            ? 'bg-[var(--accent-soft)] border-[var(--accent-ring)] text-[var(--accent)] font-medium'
                            : 'bg-[var(--settings-subtle)] border-transparent text-[var(--text-secondary)] hover:text-[var(--text-primary)]',
                        ].join(' ')}
                      >
                        <LayoutGrid size={12.5} />
                        {activeBoard ? `情绪板 · ${activeBoard.title}` : '当前活跃情绪板'}
                      </button>
                    </div>
                    <p className="text-[11.5px] text-[var(--text-tertiary)]">
                      全窗口拖入文件或按 ⌘V 粘贴剪贴板图片、链接与色值时将自动存入此位置。
                    </p>
                  </div>

                  {actionHint && (
                    <div
                      className={[
                        'px-3 py-2 rounded-[8px] text-[12px]',
                        actionHint.isError
                          ? 'bg-[var(--danger-soft)] text-[var(--danger)]'
                          : 'bg-[var(--success-soft)] text-[var(--settings-positive)]',
                      ].join(' ')}
                    >
                      {actionHint.text}
                    </div>
                  )}
                </div>
              </div>
            )}

            {/* STEP 3: AI INTELLIGENCE */}
            {currentStep.id === 'intelligence' && (
              <div className="min-h-full grid grid-cols-1 md:grid-cols-[234px_1fr]">
                {/* Left Pedestal */}
                <div className="bg-[var(--settings-rail)] border-b md:border-b-0 md:border-r border-[var(--settings-border)] p-6 flex flex-col items-center justify-center gap-3.5">
                  <div className="h-[84px] w-[84px] rounded-[22px] bg-[#2A8F9D]/12 flex items-center justify-center">
                    <CharkleIcon name="ai-spark" style="layered" size={56} />
                  </div>
                  <span className="px-2.5 py-0.5 rounded-full text-[11px] font-medium bg-[var(--settings-card)] border border-[var(--settings-border)] text-[var(--text-secondary)]">
                    基础离线能力免费内置
                  </span>
                  <div className="w-full flex flex-col gap-1.5 text-left pt-1">
                    {[
                      '自动提取主色调配色',
                      '视觉相似素材推荐',
                      '图内文字与标签检索',
                      '中文与拼音首字母快搜',
                    ].map((item) => (
                      <div
                        key={item}
                        className="flex items-center gap-1.5 text-[11.5px] text-[var(--text-secondary)]"
                      >
                        <Check
                          size={12}
                          strokeWidth={2.5}
                          className="text-[var(--settings-positive)] shrink-0"
                        />
                        <span>{item}</span>
                      </div>
                    ))}
                  </div>
                </div>

                {/* Right Controls */}
                <div className="p-6 flex flex-col gap-3">
                  <div className="flex items-start justify-between gap-2">
                    <div>
                      <h3 className="text-[17px] font-semibold text-[var(--text-primary)]">
                        需要接入云端 AI 吗？
                      </h3>
                      <p className="text-[12px] text-[var(--text-secondary)] mt-0.5">
                        不配置也能使用全部离线功能；接入后可开启自然语言搜图与智能拼板。
                      </p>
                    </div>
                    <span className="px-2 py-0.5 rounded-full text-[10.5px] bg-[var(--settings-subtle)] text-[var(--text-tertiary)] shrink-0">
                      可选 · 可跳过
                    </span>
                  </div>

                  {/* Option 1: Built-in only */}
                  <div
                    onClick={() => void handleSelectAIMode('disabled')}
                    className={[
                      'p-3 rounded-[12px] bg-[var(--settings-card)] border cursor-pointer flex items-center justify-between gap-2',
                      draftAI.provider === 'disabled'
                        ? 'border-[var(--text-primary)]/45 ring-1 ring-[var(--text-primary)]/10'
                        : 'border-[var(--settings-border)] hover:border-[var(--border-strong)]',
                    ].join(' ')}
                  >
                    <div className="flex items-center gap-2">
                      <span className="text-[13px] font-semibold text-[var(--text-primary)]">
                        仅使用内置能力
                      </span>
                      <span className="px-1.5 py-0.5 rounded-full text-[10px] font-medium bg-[var(--success-soft)] text-[var(--settings-positive)]">
                        默认
                      </span>
                    </div>
                    <span
                      className={[
                        'h-4 w-4 rounded-full border flex items-center justify-center',
                        draftAI.provider === 'disabled'
                          ? 'border-[var(--accent)] bg-[var(--accent)] text-white'
                          : 'border-[var(--border-strong)]',
                      ].join(' ')}
                    >
                      {draftAI.provider === 'disabled' && <Check size={10} strokeWidth={3} />}
                    </span>
                  </div>

                  {/* Option 2: ChatGPT Subscription */}
                  <div
                    onClick={() => void handleSelectAIMode('chatGPTSubscription')}
                    className={[
                      'p-3 rounded-[12px] bg-[var(--settings-card)] border cursor-pointer flex flex-col gap-2.5',
                      draftAI.provider === 'chatGPTSubscription'
                        ? 'border-[var(--text-primary)]/45 ring-1 ring-[var(--text-primary)]/10'
                        : 'border-[var(--settings-border)] hover:border-[var(--border-strong)]',
                    ].join(' ')}
                  >
                    <div className="flex items-center justify-between gap-2">
                      <div className="flex items-center gap-2">
                        <img
                          src="/icons/chatgpt-mark.svg"
                          alt=""
                          className="h-4 w-4 dark:invert shrink-0"
                        />
                        <span className="text-[13px] font-semibold text-[var(--text-primary)]">
                          连接 ChatGPT 订阅账号
                        </span>
                        {chatGPTSession?.status === 'connected' && (
                          <span className="px-1.5 py-0.5 rounded-full text-[10px] font-medium bg-[var(--success-soft)] text-[var(--settings-positive)]">
                            已连接
                          </span>
                        )}
                      </div>
                      <span
                        className={[
                          'h-4 w-4 rounded-full border flex items-center justify-center',
                          draftAI.provider === 'chatGPTSubscription'
                            ? 'border-[var(--accent)] bg-[var(--accent)] text-white'
                            : 'border-[var(--border-strong)]',
                        ].join(' ')}
                      >
                        {draftAI.provider === 'chatGPTSubscription' && (
                          <Check size={10} strokeWidth={3} />
                        )}
                      </span>
                    </div>

                    {draftAI.provider === 'chatGPTSubscription' && (
                      <div
                        className="flex items-center gap-2 pt-0.5"
                        onClick={(e) => e.stopPropagation()}
                      >
                        {chatGPTSession?.status === 'connected' ? (
                          <span className="text-[12px] text-[var(--settings-positive)]">
                            已登录：{chatGPTSession.email || chatGPTSession.name || 'ChatGPT 账号'}
                          </span>
                        ) : (
                          <>
                            <input
                              type="password"
                              value={chatGPTTokenDraft}
                              onChange={(e) => setChatGPTTokenDraft(e.target.value)}
                              placeholder="粘贴 ChatGPT 访问凭据…"
                              className="flex-1 min-w-0 h-8 px-2.5 text-[12px] rounded-[8px] bg-[var(--settings-content)] border border-[var(--settings-border)] text-[var(--text-primary)] focus:outline-none focus:border-[var(--accent)]"
                            />
                            <Button
                              variant="primary"
                              size="xs"
                              loading={savingAI}
                              onClick={() => void handleConnectChatGPT()}
                            >
                              连接
                            </Button>
                          </>
                        )}
                      </div>
                    )}
                  </div>

                  {/* Option 3: Gemini or Custom API */}
                  <div
                    onClick={() => void handleSelectAIMode('api')}
                    className={[
                      'p-3 rounded-[12px] bg-[var(--settings-card)] border cursor-pointer flex flex-col gap-2.5',
                      draftAI.provider === 'gemini' || draftAI.provider === 'openAICompatible'
                        ? 'border-[var(--text-primary)]/45 ring-1 ring-[var(--text-primary)]/10'
                        : 'border-[var(--settings-border)] hover:border-[var(--border-strong)]',
                    ].join(' ')}
                  >
                    <div className="flex items-center justify-between gap-2">
                      <span className="text-[13px] font-semibold text-[var(--text-primary)]">
                        Google Gemini 或自定义接口
                      </span>
                      <span
                        className={[
                          'h-4 w-4 rounded-full border flex items-center justify-center',
                          draftAI.provider === 'gemini' || draftAI.provider === 'openAICompatible'
                            ? 'border-[var(--accent)] bg-[var(--accent)] text-white'
                            : 'border-[var(--border-strong)]',
                        ].join(' ')}
                      >
                        {(draftAI.provider === 'gemini' ||
                          draftAI.provider === 'openAICompatible') && (
                          <Check size={10} strokeWidth={3} />
                        )}
                      </span>
                    </div>

                    {(draftAI.provider === 'gemini' || draftAI.provider === 'openAICompatible') && (
                      <div
                        className="flex flex-col gap-2 pt-0.5"
                        onClick={(e) => e.stopPropagation()}
                      >
                        <div className="flex flex-wrap gap-1">
                          {AI_PRESETS.map((preset) => {
                            const active = selectedPresetID === preset.id;
                            return (
                              <button
                                key={preset.id}
                                type="button"
                                onClick={() => handleApplyAIPreset(preset)}
                                className={[
                                  'charkle-pressable px-2 py-0.5 rounded-full text-[11px] font-medium border cursor-pointer',
                                  active
                                    ? 'bg-[var(--accent-soft)] border-[var(--accent-ring)] text-[var(--accent)]'
                                    : 'bg-[var(--settings-subtle)] border-transparent text-[var(--text-secondary)] hover:text-[var(--text-primary)]',
                                ].join(' ')}
                              >
                                {preset.label}
                              </button>
                            );
                          })}
                        </div>

                        <div className="grid grid-cols-2 gap-2">
                          <input
                            type="text"
                            value={draftAI.chatModel}
                            onChange={(e) =>
                              setDraftAI((prev) => ({ ...prev, chatModel: e.target.value }))
                            }
                            placeholder="模型名称"
                            className="h-8 px-2.5 text-[12px] font-mono rounded-[8px] bg-[var(--settings-content)] border border-[var(--settings-border)] text-[var(--text-primary)] focus:outline-none focus:border-[var(--accent)]"
                          />
                          <input
                            type="password"
                            value={aiKeyDraft}
                            onChange={(e) => setAIKeyDraft(e.target.value)}
                            placeholder={
                              hasStoredAIKeys[draftAI.provider]
                                ? '密钥已保存（留空不变）'
                                : selectedPresetID === 'ollama'
                                  ? '本地 Ollama 可留空'
                                  : 'API 密钥'
                            }
                            className="h-8 px-2.5 text-[12px] font-mono rounded-[8px] bg-[var(--settings-content)] border border-[var(--settings-border)] text-[var(--text-primary)] focus:outline-none focus:border-[var(--accent)]"
                          />
                        </div>

                        {draftAI.provider === 'openAICompatible' && (
                          <input
                            type="url"
                            value={draftAI.baseURL}
                            onChange={(e) =>
                              setDraftAI((prev) => ({ ...prev, baseURL: e.target.value }))
                            }
                            placeholder="服务地址（Base URL）"
                            className="h-8 px-2.5 text-[12px] font-mono rounded-[8px] bg-[var(--settings-content)] border border-[var(--settings-border)] text-[var(--text-primary)] focus:outline-none focus:border-[var(--accent)]"
                          />
                        )}

                        <div className="flex items-center justify-end gap-1.5">
                          <Button
                            variant="secondary"
                            size="xs"
                            loading={isTestingAI}
                            onClick={() => void handleTestAI()}
                          >
                            测试连接
                          </Button>
                          <Button
                            variant="primary"
                            size="xs"
                            loading={savingAI}
                            onClick={() => void handleSaveAI()}
                          >
                            保存
                          </Button>
                        </div>
                      </div>
                    )}
                  </div>

                  {actionHint && (
                    <div
                      className={[
                        'px-3 py-2 rounded-[8px] text-[12px]',
                        actionHint.isError
                          ? 'bg-[var(--danger-soft)] text-[var(--danger)]'
                          : 'bg-[var(--success-soft)] text-[var(--settings-positive)]',
                      ].join(' ')}
                    >
                      {actionHint.text}
                    </div>
                  )}
                </div>
              </div>
            )}

            {/* STEP 4: WORKSPACE / APPEARANCE */}
            {currentStep.id === 'workspace' && (
              <div className="min-h-full grid grid-cols-1 md:grid-cols-[234px_1fr]">
                {/* Left Pedestal + Live Wireframe Preview */}
                <div className="bg-[var(--settings-rail)] border-b md:border-b-0 md:border-r border-[var(--settings-border)] p-6 flex flex-col items-center justify-center text-center gap-3.5">
                  <div className="h-[74px] w-[74px] rounded-[20px] bg-[#3D9970]/12 flex items-center justify-center">
                    <CharkleIcon name="gallery" style="layered" size={48} />
                  </div>
                  <GalleryWireframePreview mode={layoutMode} />
                  <p className="text-[11.5px] text-[var(--text-secondary)]">
                    右侧选项均即时生效，随时可在设置或工具栏切换。
                  </p>
                </div>

                {/* Right Instant-Apply Preferences */}
                <div className="p-6 flex flex-col gap-4">
                  <div className="flex items-start justify-between gap-2">
                    <div>
                      <h3 className="text-[17px] font-semibold text-[var(--text-primary)]">
                        选择你喜欢的外观与排布
                      </h3>
                    </div>
                    <span className="px-2 py-0.5 rounded-full text-[10.5px] bg-[var(--settings-subtle)] text-[var(--text-tertiary)] shrink-0">
                      即时生效
                    </span>
                  </div>

                  {/* Theme Mode */}
                  <div className="flex flex-col gap-1.5">
                    <label className="text-[11.5px] font-medium text-[var(--settings-label)]">
                      主题模式
                    </label>
                    <div className="grid grid-cols-3 gap-2">
                      {(
                        [
                          { id: 'light', label: '浅色', icon: Sun },
                          { id: 'dark', label: '深色', icon: Moon },
                          { id: 'system', label: '跟随系统', icon: Monitor },
                        ] as ReadonlyArray<{ id: ThemeMode; label: string; icon: React.FC<{ size?: number }> }>
                      ).map((opt) => {
                        const Icon = opt.icon;
                        const active = themeMode === opt.id;
                        return (
                          <button
                            key={opt.id}
                            type="button"
                            onClick={() => setThemeMode(opt.id)}
                            className={[
                              'charkle-pressable py-2.5 px-3 rounded-[10px] border text-[12.5px] font-medium flex items-center justify-center gap-1.5 cursor-pointer',
                              active
                                ? 'bg-[var(--settings-card)] border-[var(--text-primary)]/45 text-[var(--text-primary)] shadow-xs'
                                : 'bg-[var(--settings-card)]/60 border-[var(--settings-border)] text-[var(--text-secondary)] hover:text-[var(--text-primary)]',
                            ].join(' ')}
                          >
                            <Icon size={14} />
                            {opt.label}
                          </button>
                        );
                      })}
                    </div>
                  </div>

                  {/* App Icon Style */}
                  <div className="flex flex-col gap-1.5">
                    <label className="text-[11.5px] font-medium text-[var(--settings-label)]">
                      应用图标风格
                    </label>
                    <div className="grid grid-cols-3 gap-2">
                      {(
                        [
                          { id: 'auto', label: '跟随主题' },
                          { id: 'light', label: '浅色' },
                          { id: 'dark', label: '深色' },
                        ] as const
                      ).map((opt) => {
                        const active = brandIconVariant === opt.id;
                        return (
                          <button
                            key={opt.id}
                            type="button"
                            onClick={() => setBrandIconVariant(opt.id)}
                            className={[
                              'charkle-pressable py-2 px-3 rounded-[10px] border text-[12px] font-medium flex items-center justify-center gap-2 cursor-pointer',
                              active
                                ? 'bg-[var(--settings-card)] border-[var(--text-primary)]/45 text-[var(--text-primary)] shadow-xs'
                                : 'bg-[var(--settings-card)]/60 border-[var(--settings-border)] text-[var(--text-secondary)] hover:text-[var(--text-primary)]',
                            ].join(' ')}
                          >
                            <CharkleBrandMark size={18} variant={opt.id} />
                            {opt.label}
                          </button>
                        );
                      })}
                    </div>
                  </div>

                  {/* Default Gallery Layout */}
                  <div className="flex flex-col gap-1.5">
                    <label className="text-[11.5px] font-medium text-[var(--settings-label)]">
                      画廊默认排布
                    </label>
                    <div className="grid grid-cols-3 gap-2">
                      {(
                        [
                          { id: 'verticalMasonry', label: '纵向瀑布流' },
                          { id: 'horizontalJustified', label: '横向等高行' },
                          { id: 'galleryFilmstrip', label: '画廊视图' },
                        ] as ReadonlyArray<{ id: GalleryLayoutMode; label: string }>
                      ).map((opt) => {
                        const active = layoutMode === opt.id;
                        return (
                          <button
                            key={opt.id}
                            type="button"
                            onClick={() => setLayoutMode(opt.id)}
                            className={[
                              'charkle-pressable py-2 px-2.5 rounded-[10px] border text-[12px] font-medium cursor-pointer',
                              active
                                ? 'bg-[var(--settings-card)] border-[var(--text-primary)]/45 text-[var(--text-primary)] shadow-xs'
                                : 'bg-[var(--settings-card)]/60 border-[var(--settings-border)] text-[var(--text-secondary)] hover:text-[var(--text-primary)]',
                            ].join(' ')}
                          >
                            {opt.label}
                          </button>
                        );
                      })}
                    </div>
                  </div>

                  {/* Compact Sidebar Toggle */}
                  <label className="p-3 rounded-[10px] bg-[var(--settings-card)] border border-[var(--settings-border)] flex items-center justify-between gap-3 cursor-pointer">
                    <div>
                      <div className="text-[12.5px] font-medium text-[var(--text-primary)]">
                        默认收起侧边栏为精简图标栏
                      </div>
                      <div className="text-[11px] text-[var(--text-tertiary)]">
                        随时可用 ⌘\ 展开或收起
                      </div>
                    </div>
                    <input
                      type="checkbox"
                      checked={sidebarCollapsed}
                      onChange={(e) => setSidebarCollapsed(e.target.checked)}
                      className="h-4 w-4 accent-[var(--accent)] cursor-pointer"
                    />
                  </label>
                </div>
              </div>
            )}

            {/* STEP 5: READY (SHOCKWAVE SEAL + 2×2 SUMMARY) */}
            {currentStep.id === 'ready' && (
              <div className="h-full flex flex-col items-center justify-center px-8 py-6 gap-6">
                <div className="flex flex-col items-center text-center gap-3">
                  <div className="relative h-[88px] w-[88px] flex items-center justify-center">
                    <span
                      aria-hidden="true"
                      className="charkle-shockwave-primary pointer-events-none absolute inset-1 rounded-full border-2 border-[var(--settings-positive)]/50"
                    />
                    <span
                      aria-hidden="true"
                      className="charkle-shockwave-secondary pointer-events-none absolute inset-1 rounded-full border border-[var(--accent)]/40"
                    />
                    <CharkleIcon name="ready" style="layered" size={64} className="relative z-10" />
                  </div>

                  <h2 className="text-[24px] font-bold tracking-[-0.02em] text-[var(--text-primary)]">
                    一切准备就绪
                  </h2>
                  <p className="text-[12.5px] text-[var(--text-secondary)]">
                    点击下方任意卡片可返回微调，或直接进入素材库开始整理。
                  </p>
                </div>

                <div className="w-full max-w-[600px] grid grid-cols-1 sm:grid-cols-2 gap-3">
                  {[
                    {
                      step: 'storage' as StepID,
                      title: '素材库与云同步',
                      value: summaryStorageText,
                    },
                    {
                      step: 'capture' as StepID,
                      title: '采集与扩展',
                      value: summaryCaptureText,
                    },
                    {
                      step: 'intelligence' as StepID,
                      title: 'AI 智能',
                      value: summaryAIText,
                    },
                    {
                      step: 'workspace' as StepID,
                      title: '外观与画廊排布',
                      value: summaryWorkspaceText,
                    },
                  ].map((item) => {
                    const skipped = skippedSteps.has(item.step);
                    return (
                      <button
                        key={item.step}
                        type="button"
                        onClick={() => jumpToStepID(item.step)}
                        className="charkle-pressable text-left p-3.5 rounded-[12px] bg-[var(--settings-card)] border border-[var(--settings-border)] hover:border-[var(--border-strong)] flex flex-col gap-1 cursor-pointer"
                      >
                        <div className="flex items-center justify-between gap-2">
                          <span className="text-[12px] font-semibold text-[var(--text-primary)]">
                            {item.title}
                          </span>
                          {skipped && (
                            <span className="px-1.5 py-0.5 rounded-full text-[10px] bg-[var(--settings-subtle)] text-[var(--text-tertiary)]">
                              已跳过
                            </span>
                          )}
                        </div>
                        <div className="text-[11.5px] text-[var(--text-secondary)] truncate">
                          {item.value}
                        </div>
                      </button>
                    );
                  })}
                </div>
              </div>
            )}
          </div>
        </div>

        {/* Footer Bar */}
        <div className="px-5 py-3.5 border-t border-[var(--settings-border)] flex items-center justify-between gap-3 shrink-0">
          <div>
            {stepIdx > 0 ? (
              <Button variant="secondary" size="sm" onClick={() => goToStep(stepIdx - 1, false)}>
                <ArrowLeft size={13} />
                上一步
              </Button>
            ) : (
              <span className="text-[11.5px] text-[var(--text-tertiary)] hidden sm:inline">
                每一步都可跳过 · 随时可在「设置 (⌘,) → 通用」重新查看
              </span>
            )}
          </div>

          <div className="flex items-center gap-2.5">
            <span className="text-[11.5px] font-mono tabular-nums text-[var(--text-tertiary)] mr-1">
              {stepIdx + 1} / {STEPS.length}
            </span>

            {currentStep.id === 'welcome' ? (
              <>
                <Button variant="secondary" size="sm" onClick={completeOnboarding}>
                  跳过，直接使用
                </Button>
                <Button
                  variant="skeuoPrimary"
                  size="md"
                  onClick={() => goToStep(1, false)}
                >
                  开始快速配置
                  <ArrowRight size={13.5} />
                </Button>
              </>
            ) : currentStep.id === 'ready' ? (
              <>
                <Button
                  variant="secondary"
                  size="sm"
                  onClick={() => finishAndOpenSettings('general')}
                >
                  打开完整设置 (⌘,)
                </Button>
                <Button
                  variant="skeuoPrimary"
                  size="md"
                  onClick={completeOnboarding}
                >
                  进入 Charkle 工作台
                  <ArrowRight size={13.5} />
                </Button>
              </>
            ) : (
              <>
                <Button variant="secondary" size="sm" onClick={() => goToStep(stepIdx + 1, true)}>
                  跳过此步
                </Button>
                <Button
                  variant="skeuoPrimary"
                  size="md"
                  onClick={() => goToStep(stepIdx + 1, false)}
                >
                  {currentStep.id === 'workspace' ? '查看配置摘要' : '下一步'}
                  <ArrowRight size={13.5} />
                </Button>
              </>
            )}
          </div>
        </div>
      </div>

      {/* Inline Google OAuth Credential Modal (zero coupling to features/settings) */}
      <InlineGoogleOAuthModal
        open={showOAuthModal}
        onClose={() => setShowOAuthModal(false)}
        onSaved={(started) => {
          setActionHint({
            text: started ? '凭据已保存，请在打开的页面完成 Google 登录' : 'Google OAuth 凭据已保存',
            isError: false,
          });
        }}
      />
    </div>,
    document.body,
  );
};
