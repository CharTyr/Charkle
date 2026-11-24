import React, { useEffect, useRef, useState } from 'react';
import {
  AlertTriangle,
  ArrowRight,
  Check,
  CheckCircle2,
  ChevronLeft,
  ChevronRight,
  Image as ImageIcon,
  Monitor,
  Moon,
  Sun,
  X,
} from 'lucide-react';
import { getTransport } from '../../api/transport';
import {
  CharkleBrandMark,
  CharkleIcon,
  CustomSelect,
  SegmentedControl,
  type ThemeMode,
} from '../../design-system';
import { useCoordinatorStore, useLibraryStore, useSyncAIStore } from '../../stores';
import type {
  AIProviderConfig,
  CloudAIProviderKind,
  CustomAIEndpointFormat,
  DriveSyncConfig,
  DriveTransportMode,
  GalleryLayoutMode,
  HotkeyConfig,
  ShelfSettings,
} from '../../types/domain';
import {
  CharkleSkeuoButton,
  ChatGPTBrandMark,
  isValidHttpUrl,
  SettingsButton,
  SettingsCardDivider,
  SettingsInput,
  SettingsStatusBadge,
  SettingsSwitch,
} from '../settings/SettingsChrome';
import { GoogleOAuthSetupModal } from '../settings/SettingsPanesFoundation';

type OnboardingStep = 0 | 1 | 2 | 3 | 4 | 5;

const STEPS: Array<{ id: OnboardingStep; label: string }> = [
  { id: 0, label: '欢迎' },
  { id: 1, label: '素材库' },
  { id: 2, label: '采集' },
  { id: 3, label: 'AI 智能' },
  { id: 4, label: '外观' },
  { id: 5, label: '完成' },
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

const AI_PRESETS: QuickAIPreset[] = [
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

function layoutModeLabel(mode: GalleryLayoutMode): string {
  switch (mode) {
    case 'verticalMasonry':
      return '纵向瀑布流';
    case 'horizontalJustified':
      return '横向等高行';
    case 'galleryFilmstrip':
      return '画廊视图';
    case 'ringGallery':
      return '环形画廊';
  }
}

function themeLabel(mode: ThemeMode): string {
  switch (mode) {
    case 'system':
      return '跟随系统';
    case 'light':
      return '浅色画廊';
    case 'dark':
      return '深色画廊';
  }
}

function targetModeLabel(mode: ShelfSettings['defaultTargetMode']): string {
  switch (mode) {
    case 'inbox':
      return '收件箱';
    case 'folder':
      return '指定文件夹';
    case 'activeMoodboard':
      return '活跃情绪板';
  }
}

const RadioIndicator: React.FC<{ selected: boolean }> = ({ selected }) => (
  <span
    aria-hidden="true"
    className={[
      'inline-flex h-[17px] w-[17px] shrink-0 items-center justify-center rounded-full transition-colors duration-150 motion-reduce:transition-none',
      selected
        ? 'border-2 border-[var(--text-primary)]'
        : 'border-[1.25px] border-[var(--text-primary)]/25',
    ].join(' ')}
  >
    {selected && (
      <span className="h-[7.5px] w-[7.5px] rounded-full bg-[var(--text-primary)] charkle-micro-pop" />
    )}
  </span>
);

interface RadioChoiceCardProps {
  title: string;
  badge?: string | null;
  subtitle: string;
  icon: React.ReactNode;
  selected: boolean;
  onSelect: () => void;
  detail?: React.ReactNode;
}

const RadioChoiceCard: React.FC<RadioChoiceCardProps> = ({
  title,
  badge,
  subtitle,
  icon,
  selected,
  onSelect,
  detail,
}) => (
  <div
    className={[
      'rounded-[12px] p-[13px] transition-colors duration-150 motion-reduce:transition-none',
      selected
        ? 'bg-[var(--text-primary)]/[0.045] dark:bg-white/[0.075] border-[1.35px] border-[var(--text-primary)]/45 dark:border-white/50'
        : 'bg-[var(--settings-card)] border border-[var(--settings-border)]',
    ].join(' ')}
  >
    <button
      type="button"
      onClick={onSelect}
      className="w-full flex items-center gap-3 text-left cursor-pointer"
    >
      <span className="h-[34px] w-[34px] rounded-[9px] bg-[var(--settings-subtle)] inline-flex items-center justify-center shrink-0 text-[var(--text-primary)]">
        {icon}
      </span>
      <div className="min-w-0 flex-1 flex flex-col gap-0.5">
        <div className="flex items-center gap-1.5">
          <span className="text-[13px] font-semibold text-[var(--text-primary)]">{title}</span>
          {badge && <SettingsStatusBadge text={badge} tone="positive" />}
        </div>
        <span className="text-[11.5px] text-[var(--text-secondary)] leading-snug">{subtitle}</span>
      </div>
      <RadioIndicator selected={selected} />
    </button>
    {selected && detail && <div className="mt-2.5 pl-[46px] charkle-reveal-top">{detail}</div>}
  </div>
);

const StepHeading: React.FC<{
  title: string;
  subtitle: string;
  optionalTag?: string;
}> = ({ title, subtitle, optionalTag = '可选 · 可跳过' }) => (
  <div className="flex flex-col gap-1">
    <div className="flex items-center gap-2">
      <h2 className="text-[19px] font-bold tracking-[-0.02em] text-[var(--text-primary)]">
        {title}
      </h2>
      {optionalTag && (
        <span className="px-2 py-[2px] rounded-full bg-[var(--settings-subtle)] text-[10.5px] font-medium text-[var(--settings-label)]">
          {optionalTag}
        </span>
      )}
    </div>
    <p className="text-[12.5px] text-[var(--text-secondary)] leading-relaxed">{subtitle}</p>
  </div>
);

const StepHeroIconDisc: React.FC<{ iconName: string; accentHex: string }> = ({
  iconName,
  accentHex,
}) => (
  <div className="relative h-[102px] w-[102px] flex items-center justify-center">
    <div
      aria-hidden="true"
      style={{
        background: `radial-gradient(circle, ${accentHex}2E 0%, transparent 72%)`,
      }}
      className="absolute inset-0 rounded-full"
    />
    <div className="relative z-10 flex items-center justify-center">
      <CharkleIcon name={iconName} style="layered" size={66} />
    </div>
  </div>
);

const StepHeroPedestal: React.FC<{
  iconName: string;
  accentHex: string;
  badgeText: string;
  caption: string;
}> = ({ iconName, accentHex, badgeText, caption }) => (
  <div className="h-full rounded-[14px] bg-[var(--settings-rail)] border border-[var(--settings-border)] p-[18px] flex flex-col items-center justify-center text-center gap-4">
    <StepHeroIconDisc iconName={iconName} accentHex={accentHex} />
    <span
      style={{
        color: accentHex,
        backgroundColor: `${accentHex}1C`,
      }}
      className="px-2.5 py-1 rounded-full text-[11px] font-semibold"
    >
      {badgeText}
    </span>
    <p className="text-[12px] text-[var(--text-secondary)] leading-relaxed">{caption}</p>
  </div>
);

const GalleryLayoutMiniPreview: React.FC<{ mode: GalleryLayoutMode }> = ({ mode }) => (
  <div className="w-full rounded-[11px] bg-[var(--settings-card)] border border-[var(--settings-border)] p-3 flex flex-col gap-2">
    <span className="text-[10.5px] font-semibold text-[var(--text-secondary)]">
      视图预览 · {layoutModeLabel(mode)}
    </span>
    <div className="h-[82px]">
      {mode === 'verticalMasonry' && (
        <div className="grid grid-cols-3 gap-1.5 h-full">
          <div className="flex flex-col gap-1.5">
            <div className="h-[46px] rounded-[5px] bg-[#D96B43]/45" />
            <div className="flex-1 rounded-[5px] bg-[var(--text-primary)]/10" />
          </div>
          <div className="flex flex-col gap-1.5">
            <div className="h-[28px] rounded-[5px] bg-[var(--text-primary)]/10" />
            <div className="flex-1 rounded-[5px] bg-[var(--text-primary)]/10" />
          </div>
          <div className="flex flex-col gap-1.5">
            <div className="h-[38px] rounded-[5px] bg-[var(--text-primary)]/10" />
            <div className="flex-1 rounded-[5px] bg-[#D96B43]/30" />
          </div>
        </div>
      )}
      {mode === 'horizontalJustified' && (
        <div className="flex flex-col gap-1.5 h-full">
          <div className="flex gap-1.5 h-[37px]">
            <div className="w-[42%] rounded-[5px] bg-[#D96B43]/45" />
            <div className="flex-1 rounded-[5px] bg-[var(--text-primary)]/10" />
            <div className="w-[22%] rounded-[5px] bg-[var(--text-primary)]/10" />
          </div>
          <div className="flex gap-1.5 h-[37px]">
            <div className="w-[26%] rounded-[5px] bg-[var(--text-primary)]/10" />
            <div className="flex-1 rounded-[5px] bg-[#D96B43]/30" />
            <div className="w-[34%] rounded-[5px] bg-[var(--text-primary)]/10" />
          </div>
        </div>
      )}
      {mode === 'galleryFilmstrip' && (
        <div className="flex flex-col gap-1.5 h-full">
          <div className="h-[58px] rounded-[6px] bg-[#D96B43]/40" />
          <div className="grid grid-cols-5 gap-1 h-[16px]">
            {[0, 1, 2, 3, 4].map((i) => (
              <div
                key={i}
                className={[
                  'rounded-[3.5px]',
                  i === 2 ? 'bg-[#D96B43]' : 'bg-[var(--text-primary)]/10',
                ].join(' ')}
              />
            ))}
          </div>
        </div>
      )}
      {mode === 'ringGallery' && (
        <div className="h-full flex items-center justify-center gap-1.5 px-1">
          <div className="w-[14%] h-[46px] rounded-[6px] bg-[var(--text-primary)]/8 opacity-55" />
          <div className="w-[20%] h-[62px] rounded-[7px] bg-[var(--text-primary)]/12 opacity-80" />
          <div className="w-[30%] h-[76px] rounded-[8px] bg-[#D96B43]/45 border border-[#D96B43]/30 shadow-xs" />
          <div className="w-[20%] h-[62px] rounded-[7px] bg-[var(--text-primary)]/12 opacity-80" />
          <div className="w-[14%] h-[46px] rounded-[6px] bg-[var(--text-primary)]/8 opacity-55" />
        </div>
      )}
    </div>
  </div>
);

/**
 * 1:1 Windows parity port of macOS `Sources/CharkleApp/Views/OnboardingView.swift`:
 * - Bound to `coordinatorStore.onboardingStep` so opening Settings mid-flow returns to the EXACT step
 * - Non-destructive `openSettingsFromOnboarding('sync' | 'ai')` (never marks onboarding complete mid-flow)
 * - Inline `GoogleOAuthSetupModal` + live WebDAV connection test + live global hotkeys toggle
 * - Bespoke macOS layered & duotone `CharkleIcon`s + 5-layer tactile `CharkleSkeuoButton` primary CTA
 * - Every individual step and the entire onboarding flow are explicitly skippable at any time
 */
export const OnboardingStudio: React.FC = () => {
  const open = useCoordinatorStore((s) => s.onboardingOpen);
  const onboardingStep = useCoordinatorStore((s) => s.onboardingStep);
  const onboardingRunId = useCoordinatorStore((s) => s.onboardingRunId);
  const setOnboardingStep = useCoordinatorStore((s) => s.setOnboardingStep);
  const openSettingsFromOnboarding = useCoordinatorStore((s) => s.openSettingsFromOnboarding);
  const completeOnboarding = useCoordinatorStore((s) => s.completeOnboarding);
  const openSettings = useCoordinatorStore((s) => s.openSettings);
  const themeMode = useCoordinatorStore((s) => s.themeMode);
  const setThemeMode = useCoordinatorStore((s) => s.setThemeMode);
  const layoutMode = useCoordinatorStore((s) => s.layoutMode);
  const setLayoutMode = useCoordinatorStore((s) => s.setLayoutMode);
  const sidebarCollapsed = useCoordinatorStore((s) => s.sidebarCollapsed);
  const setSidebarCollapsed = useCoordinatorStore((s) => s.setSidebarCollapsed);
  const pushToast = useCoordinatorStore((s) => s.pushToast);

  const folders = useLibraryStore((s) => s.folders);

  const syncConfig = useSyncAIStore((s) => s.syncConfig);
  const syncStatus = useSyncAIStore((s) => s.syncStatus);
  const diagnostics = useSyncAIStore((s) => s.diagnostics);
  const hasGoogleOAuthClient = useSyncAIStore((s) => s.hasGoogleOAuthClient);
  const hasWebdavPassword = useSyncAIStore((s) => s.hasWebdavPassword);
  const signingInGoogle = useSyncAIStore((s) => s.signingInGoogle);
  const testingWebdav = useSyncAIStore((s) => s.testingWebdav);
  const saveSyncConfig = useSyncAIStore((s) => s.saveSyncConfig);
  const testWebdavConnection = useSyncAIStore((s) => s.testWebdavConnection);
  const signInGoogleDrive = useSyncAIStore((s) => s.signInGoogleDrive);
  const aiState = useSyncAIStore((s) => s.aiState);
  const signingInChatgpt = useSyncAIStore((s) => s.signingInChatgpt);
  const signInChatgpt = useSyncAIStore((s) => s.signInChatgpt);
  const saveAiConfig = useSyncAIStore((s) => s.saveAiConfig);
  const refreshSettingsData = useSyncAIStore((s) => s.refreshSettingsData);

  const step = Math.max(0, Math.min(5, onboardingStep)) as OnboardingStep;

  const [rendered, setRendered] = useState(open);
  const [closing, setClosing] = useState(false);
  const [direction, setDirection] = useState<'fwd' | 'back'>('fwd');
  const [skippedSteps, setSkippedSteps] = useState<Set<OnboardingStep>>(() => new Set());
  const [showOAuthModal, setShowOAuthModal] = useState(false);
  const lastRunIdRef = useRef(onboardingRunId);

  // Live animated mini-notch preview state on Step 2
  const [demoNotchExpanded, setDemoNotchExpanded] = useState(false);
  const [demoCardDropped, setDemoCardDropped] = useState(false);
  const [demoConfirmed, setDemoConfirmed] = useState(false);

  const [draftSync, setDraftSync] = useState<DriveSyncConfig>(
    syncConfig ?? {
      mode: 'localOnly',
      rootFolderName: 'Charkle',
      sharedFolderURLOrID: '',
      mountPath: 'G:\\',
      selectedGDirectAccount: null,
      useGDirectIPAcceleration: true,
      webDAVServerURL: '',
      webDAVUsername: '',
      webDAVRemotePath: '/Charkle',
      localLibraryPath: '',
      autoSyncIntervalSeconds: 180,
      syncThumbnails: true,
      syncEmbeddings: true,
    },
  );
  const [webdavPasswordDraft, setWebdavPasswordDraft] = useState('');

  const [draftAI, setDraftAI] = useState<AIProviderConfig>(
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
  const [aiKeyDraft, setAiKeyDraft] = useState('');
  const [savingAiDraft, setSavingAiDraft] = useState(false);

  const [shelfSettings, setShelfSettings] = useState<ShelfSettings>({
    enabled: true,
    hoverTriggerEnabled: true,
    defaultTargetMode: 'inbox',
    defaultFolderId: null,
  });

  const [hotkeys, setHotkeys] = useState<HotkeyConfig>({
    enabled: true,
    captureArea: 'Alt+Shift+A',
    toggleShelf: 'Alt+Shift+S',
    collectClipboard: 'Alt+Shift+V',
  });

  const [actionHint, setActionHint] = useState<{ text: string; isError: boolean } | null>(null);

  // Reset skippedSteps ONLY on a fresh onboarding run (never when resuming from Settings!)
  useEffect(() => {
    if (onboardingRunId !== lastRunIdRef.current) {
      lastRunIdRef.current = onboardingRunId;
      setSkippedSteps(new Set());
      setDirection('fwd');
      setActionHint(null);
      setShowOAuthModal(false);
    }
  }, [onboardingRunId]);

  useEffect(() => {
    if (open) {
      setClosing(false);
      setRendered(true);
      return;
    }
    if (!rendered) return;
    setClosing(true);
    const timer = window.setTimeout(() => {
      setRendered(false);
      setClosing(false);
    }, 175);
    return () => window.clearTimeout(timer);
  }, [open, rendered]);

  useEffect(() => {
    if (!open) return;
    setActionHint(null);
    void refreshSettingsData();
    void getTransport()
      .getShelfSettings()
      .then(setShelfSettings)
      .catch(() => {});
    void getTransport()
      .getDesktopIntegrationStatus()
      .then((st) => setHotkeys(st.hotkeys))
      .catch(() => {});
  }, [open, refreshSettingsData]);

  useEffect(() => {
    if (syncConfig) setDraftSync(syncConfig);
  }, [syncConfig]);

  useEffect(() => {
    if (aiState) setDraftAI(aiState.config);
  }, [aiState]);

  // Escape key skips onboarding cleanly ONLY when no sub-modal or popover is open
  useEffect(() => {
    if (!open || showOAuthModal) return;
    const onKeyDown = (e: KeyboardEvent) => {
      if (e.key === 'Escape' && !e.defaultPrevented) {
        if (document.querySelector('[data-charkle-popover-open="true"]')) return;
        e.preventDefault();
        completeOnboarding();
        pushToast({
          message: '已跳过首次引导 · 随时可在「设置 → 通用」重新查看',
          tone: 'info',
        });
      }
    };
    window.addEventListener('keydown', onKeyDown);
    return () => window.removeEventListener('keydown', onKeyDown);
  }, [open, showOAuthModal, completeOnboarding, pushToast]);

  // Auto-looping mini-notch animation on Step 2 (reduced-motion safe)
  useEffect(() => {
    if (!open || step !== 2) return;
    const reduced =
      typeof window !== 'undefined' &&
      window.matchMedia?.('(prefers-reduced-motion: reduce)').matches;
    if (reduced) {
      setDemoNotchExpanded(true);
      setDemoCardDropped(false);
      setDemoConfirmed(true);
      return;
    }

    let cancelled = false;
    const timers: number[] = [];
    const runCycle = () => {
      if (cancelled) return;
      setDemoNotchExpanded(false);
      setDemoCardDropped(false);
      setDemoConfirmed(false);

      timers.push(
        window.setTimeout(() => {
          if (!cancelled) setDemoNotchExpanded(true);
        }, 550),
      );
      timers.push(
        window.setTimeout(() => {
          if (!cancelled) setDemoCardDropped(true);
        }, 1000),
      );
      timers.push(
        window.setTimeout(() => {
          if (!cancelled) setDemoConfirmed(true);
        }, 1520),
      );
      timers.push(
        window.setTimeout(() => {
          if (!cancelled) runCycle();
        }, 3050),
      );
    };
    runCycle();
    return () => {
      cancelled = true;
      timers.forEach((id) => window.clearTimeout(id));
    };
  }, [open, step]);

  if (!rendered) return null;

  const navigate = (target: OnboardingStep) => {
    if (target === step) return;
    setActionHint(null);
    setDirection(target > step ? 'fwd' : 'back');
    setOnboardingStep(target);
  };

  const goNext = (skipped: boolean) => {
    setSkippedSteps((prev) => {
      const nextSet = new Set(prev);
      if (skipped) nextSet.add(step);
      else nextSet.delete(step);
      return nextSet;
    });
    if (step < 5) {
      navigate((step + 1) as OnboardingStep);
    } else {
      completeOnboarding();
    }
  };

  const skipEntireOnboarding = () => {
    completeOnboarding();
    pushToast({
      message: '已跳过首次引导 · 随时可在「设置 → 通用」重新查看',
      tone: 'info',
    });
  };

  const selectStorageMode = (mode: DriveTransportMode) => {
    setSkippedSteps((prev) => {
      const nextSet = new Set(prev);
      nextSet.delete(1);
      return nextSet;
    });
    const nextCfg = { ...draftSync, mode };
    setDraftSync(nextCfg);
    void saveSyncConfig(nextCfg, undefined, { quiet: true });
  };

  const persistShelf = async (patch: Partial<ShelfSettings>) => {
    setSkippedSteps((prev) => {
      const nextSet = new Set(prev);
      nextSet.delete(2);
      return nextSet;
    });
    const prev = shelfSettings;
    const next = { ...shelfSettings, ...patch };
    setShelfSettings(next);
    try {
      const saved = await getTransport().saveShelfSettings(next);
      setShelfSettings(saved);
    } catch (err) {
      setShelfSettings(prev);
      setActionHint({
        text: err instanceof Error ? err.message : '保存顶部浮窗设置失败',
        isError: true,
      });
    }
  };

  const toggleHotkeysEnabled = async (enabled: boolean) => {
    setSkippedSteps((prev) => {
      const nextSet = new Set(prev);
      nextSet.delete(2);
      return nextSet;
    });
    const prev = hotkeys;
    const next = { ...hotkeys, enabled };
    setHotkeys(next);
    try {
      const saved = await getTransport().updateHotkeys(next);
      setHotkeys(saved);
    } catch (err) {
      setHotkeys(prev);
      setActionHint({
        text: err instanceof Error ? err.message : '切换系统全局快捷键失败',
        isError: true,
      });
    }
  };

  const selectAIProvider = (provider: CloudAIProviderKind) => {
    setSkippedSteps((prev) => {
      const nextSet = new Set(prev);
      nextSet.delete(3);
      return nextSet;
    });
    const next: AIProviderConfig = {
      ...draftAI,
      provider,
      chatModel: provider === 'gemini' && !draftAI.chatModel ? 'gemini-2.5-flash' : draftAI.chatModel,
      baseURL:
        provider === 'gemini' && !draftAI.baseURL
          ? 'https://generativelanguage.googleapis.com'
          : draftAI.baseURL,
    };
    setDraftAI(next);
    void saveAiConfig(next, { apiKey: null, quiet: true });
  };

  const applyAIPreset = (preset: QuickAIPreset) => {
    setSkippedSteps((prev) => {
      const nextSet = new Set(prev);
      nextSet.delete(3);
      return nextSet;
    });
    const next: AIProviderConfig = {
      ...draftAI,
      provider: preset.provider,
      customEndpointFormat: preset.format,
      baseURL: preset.baseURL,
      chatModel: preset.chatModel,
      embeddingModel: preset.embeddingModel,
    };
    setDraftAI(next);
    void saveAiConfig(next, { apiKey: null, quiet: true });
  };

  const isPresetActive = (preset: QuickAIPreset) => {
    if (preset.provider === 'gemini') return draftAI.provider === 'gemini';
    try {
      const host = new URL(preset.baseURL).host.toLowerCase();
      return (
        draftAI.provider === 'openAICompatible' && draftAI.baseURL.toLowerCase().includes(host)
      );
    } catch {
      return draftAI.provider === 'openAICompatible' && draftAI.baseURL === preset.baseURL;
    }
  };

  const activeStorageMode: DriveTransportMode =
    draftSync.mode === 'gdirectMount' ? 'directAPIWithGDirect' : draftSync.mode;
  const isLocalStorage = activeStorageMode === 'localOnly';
  const isGoogleStorage = activeStorageMode === 'directAPIWithGDirect';
  const isWebDAVStorage = activeStorageMode === 'webDAV';

  const directAccount =
    syncStatus?.account &&
    syncStatus.account.source !== 'WebDAV' &&
    syncStatus.account.source !== '本地文件夹'
      ? syncStatus.account
      : null;

  const isLocalAI = draftAI.provider === 'disabled';
  const isChatGPTAI = draftAI.provider === 'chatGPTSubscription';
  const isAPIAI = draftAI.provider === 'gemini' || draftAI.provider === 'openAICompatible';
  const isLocalOllama =
    draftAI.provider === 'openAICompatible' &&
    (draftAI.baseURL.toLowerCase().includes('localhost') ||
      draftAI.baseURL.includes('127.0.0.1'));

  const storageSummary =
    draftSync.mode === 'localOnly'
      ? '纯本地文件夹'
      : draftSync.mode === 'webDAV'
        ? draftSync.webDAVServerURL.trim()
          ? 'WebDAV 云盘'
          : 'WebDAV（待填写）'
        : directAccount?.email ?? 'Google Drive（待登录）';

  const captureSummary = `${
    shelfSettings.enabled
      ? `浮窗 → ${targetModeLabel(shelfSettings.defaultTargetMode)}`
      : '浮窗已关闭'
  } · ${hotkeys.enabled ? '热键已开启' : '热键已关闭'}`;

  const aiSummary =
    draftAI.provider === 'disabled'
      ? '内置离线视觉引擎'
      : draftAI.provider === 'chatGPTSubscription'
        ? aiState?.chatgptSession.status === 'connected'
          ? 'ChatGPT 已连接'
          : 'ChatGPT（待登录）'
        : draftAI.provider === 'gemini'
          ? aiState?.hasApiKey
            ? 'Google Gemini 已就绪'
            : 'Gemini（待填密钥）'
          : aiState?.hasApiKey || isLocalOllama
            ? `${draftAI.chatModel || '自定义 API'} 已就绪`
            : '自定义 API（待填密钥）';

  const workspaceSummary = `${themeLabel(themeMode)} · ${layoutModeLabel(layoutMode)}`;

  const renderInlineFeedback = () => {
    if (!actionHint) return null;
    const toneVar = actionHint.isError ? 'var(--settings-warning)' : 'var(--settings-positive)';
    return (
      <div
        role="status"
        style={{
          backgroundColor: `color-mix(in srgb, ${toneVar} 12%, transparent)`,
          borderColor: `color-mix(in srgb, ${toneVar} 24%, transparent)`,
        }}
        className="charkle-reveal-top rounded-[9px] border px-3 py-2 text-[11.5px] font-medium text-[var(--text-primary)] flex items-center gap-2"
      >
        {actionHint.isError ? (
          <AlertTriangle size={13} style={{ color: toneVar }} className="shrink-0" />
        ) : (
          <CheckCircle2 size={13} style={{ color: toneVar }} className="shrink-0" />
        )}
        <span className="truncate">{actionHint.text}</span>
      </div>
    );
  };

  return (
    <div
      data-testid="onboarding-studio"
      role="dialog"
      aria-modal="true"
      aria-label="Charkle 快速上手引导"
      className="fixed inset-0 z-50 flex items-center justify-center p-6"
    >
      <div
        data-closing={closing ? 'true' : undefined}
        className="charkle-modal-scrim fixed inset-0"
      />

      <div
        data-closing={closing ? 'true' : undefined}
        className="charkle-modal-panel relative z-10 w-[min(840px,calc(100vw-48px))] h-[min(636px,calc(100vh-48px))] rounded-[20px] bg-[var(--settings-content)] border border-[var(--settings-border)] shadow-[var(--shadow-modal)] flex flex-col overflow-hidden"
      >
        {/* Header Bar with Interactive Travelling Step Rail */}
        <header className="px-[22px] pt-[15px] pb-[13px] border-b border-[var(--settings-border)] flex items-center justify-between gap-3 shrink-0 select-none">
          <div className="flex items-center gap-2.5 w-[112px] shrink-0">
            <CharkleBrandMark size={22} />
            <span className="text-[14px] font-semibold text-[var(--text-primary)]">Charkle</span>
          </div>

          <div
            role="tablist"
            aria-label="引导步骤"
            className="flex items-center gap-0.5 p-[3px] rounded-full bg-[var(--settings-subtle)]"
          >
            {STEPS.map((s) => {
              const isActive = step === s.id;
              const isPast = s.id < step;
              const wasSkipped = skippedSteps.has(s.id);
              return (
                <button
                  key={s.id}
                  type="button"
                  role="tab"
                  aria-selected={isActive}
                  onClick={() => navigate(s.id)}
                  className={[
                    'px-2.5 py-[5px] rounded-full text-[11.5px] flex items-center gap-1.5 cursor-pointer transition-colors duration-150 motion-reduce:transition-none',
                    isActive
                      ? 'bg-[var(--settings-card)] border border-[var(--settings-border)] shadow-[0_1px_3px_rgba(0,0,0,0.08)] text-[var(--text-primary)] font-semibold'
                      : 'border border-transparent text-[var(--text-secondary)] hover:text-[var(--text-primary)] font-medium',
                  ].join(' ')}
                >
                  {isPast && !wasSkipped ? (
                    <Check size={10} strokeWidth={2.75} className="text-[var(--settings-positive)]" />
                  ) : isPast && wasSkipped ? (
                    <span className="h-[6px] w-[6px] rounded-full border border-[var(--text-primary)]/30" />
                  ) : (
                    <span
                      className={[
                        'h-[5.5px] w-[5.5px] rounded-full',
                        isActive ? 'bg-[var(--text-primary)]' : 'bg-[var(--text-primary)]/22',
                      ].join(' ')}
                    />
                  )}
                  <span>{s.label}</span>
                </button>
              );
            })}
          </div>

          <div className="w-[112px] flex justify-end shrink-0">
            {step !== 5 && (
              <button
                type="button"
                onClick={skipEntireOnboarding}
                title="直接跳过全部引导 (Esc)，随时可在「设置 → 通用」重新查看"
                className="px-2.5 py-[5px] rounded-full text-[11.5px] font-medium text-[var(--text-secondary)] hover:text-[var(--text-primary)] hover:bg-[var(--settings-subtle)] inline-flex items-center gap-1 cursor-pointer transition-colors duration-150 motion-reduce:transition-none"
              >
                <span>跳过引导</span>
                <X size={11} strokeWidth={2.2} />
              </button>
            )}
          </div>
        </header>

        {/* Step Body */}
        <div className="flex-1 min-h-0 overflow-hidden">
          <div
            key={step}
            className={[
              'h-full w-full',
              direction === 'fwd' ? 'charkle-step-fwd' : 'charkle-step-back',
            ].join(' ')}
          >
            {/* Step 0: Welcome */}
            {step === 0 && (
              <div className="h-full overflow-y-auto charkle-scroll px-[26px] py-5">
                <div className="min-h-full flex flex-col items-center justify-center gap-6">
                  <div className="flex flex-col items-center text-center gap-3">
                    <div className="relative h-[108px] w-[108px] flex items-center justify-center">
                      <div
                        aria-hidden="true"
                        style={{
                          background:
                            'radial-gradient(circle, rgba(59, 116, 232, 0.20) 0%, transparent 72%)',
                        }}
                        className="absolute inset-0 rounded-full"
                      />
                      <div className="relative z-10 drop-shadow-[0_10px_18px_rgba(0,0,0,0.16)]">
                        <CharkleBrandMark size={62} />
                      </div>
                    </div>
                    <div className="flex flex-col gap-1.5">
                      <h1 className="text-[27px] font-bold tracking-[-0.025em] text-[var(--text-primary)]">
                        欢迎使用 Charkle
                      </h1>
                      <p className="text-[13px] text-[var(--text-secondary)] max-w-[540px] leading-relaxed">
                        专为视觉创作者打造的灵感收集与情绪板工作台。花 1 分钟按需选几项偏好，或直接跳过立即开始。
                      </p>
                    </div>
                  </div>

                  <div className="grid grid-cols-2 md:grid-cols-4 gap-3 w-full">
                  {(
                    [
                      {
                        iconName: 'notch',
                        accent: '#3B74E8',
                        title: '顶部浮窗随手拖',
                        subtitle: '跨应用拖起即收纳，不抢窗口焦点，支持反向拖出复用',
                        target: 2 as OnboardingStep,
                      },
                      {
                        iconName: 'library',
                        accent: '#D96B43',
                        title: '本地与云端无损互迁',
                        subtitle: '支持纯本地、Google Drive 与 WebDAV，随时一键安全搬家',
                        target: 1 as OnboardingStep,
                      },
                      {
                        iconName: 'ai-spark',
                        accent: '#2A8F9D',
                        title: '离线视觉 + 可选云 AI',
                        subtitle: '免费内置配色提取、OCR 与相似检索，按需接入云端策展',
                        target: 3 as OnboardingStep,
                      },
                      {
                        iconName: 'moodboard',
                        accent: '#3D9970',
                        title: '自由画布与 Figma 桥接',
                        subtitle: '10 秒拼板推演灵感，原生支持导出高分辨率可编辑 Figma 包',
                        target: 4 as OnboardingStep,
                      },
                    ] as const
                  ).map((card) => (
                    <button
                      key={card.title}
                      type="button"
                      onClick={() => navigate(card.target)}
                      className="charkle-pressable group rounded-[14px] bg-[var(--settings-card)] border border-[var(--settings-border)] hover:border-[var(--text-primary)]/40 p-3.5 min-h-[164px] flex flex-col items-start text-left gap-2.5 shadow-[0_2px_6px_rgba(0,0,0,0.03)] hover:shadow-[0_6px_16px_rgba(0,0,0,0.08)] cursor-pointer transition-[border-color,box-shadow] duration-150 motion-reduce:transition-none"
                    >
                      <span
                        style={{ backgroundColor: `${card.accent}18` }}
                        className="h-[52px] w-[52px] rounded-[12px] inline-flex items-center justify-center transition-transform duration-150 group-hover:-translate-y-0.5 motion-reduce:transition-none motion-reduce:group-hover:translate-y-0"
                      >
                        <CharkleIcon name={card.iconName} style="layered" size={38} />
                      </span>
                      <div className="flex flex-col gap-1">
                        <span className="text-[13px] font-semibold text-[var(--text-primary)]">
                          {card.title}
                        </span>
                        <span className="text-[11.5px] text-[var(--text-secondary)] leading-relaxed">
                          {card.subtitle}
                        </span>
                      </div>
                    </button>
                  ))}
                  </div>
                </div>
              </div>
            )}

            {/* Step 1: Library Storage & Cloud Sync */}
            {step === 1 && (
              <div className="h-full p-[22px] flex gap-[22px]">
                <div className="w-[234px] shrink-0">
                  <StepHeroPedestal
                    iconName={isLocalStorage ? 'folder' : 'drive'}
                    accentHex={isLocalStorage ? '#D96B43' : '#3B74E8'}
                    badgeText={
                      isLocalStorage
                        ? '本机隐私优先'
                        : directAccount
                          ? '已连接云端'
                          : '多机自动同步'
                    }
                    caption={
                      isLocalStorage
                        ? '所有素材原件与索引直接留在你指定的本机目录，零账号即可开箱使用。'
                        : '文件夹、原图与情绪板自动增量同步；随时可在「设置 → 素材库」一键无损互迁。'
                    }
                  />
                </div>

                <div className="flex-1 min-w-0 overflow-y-auto charkle-scroll-hidden pr-0.5 flex flex-col gap-3">
                  <StepHeading
                    title="素材库保存在哪里？"
                    subtitle="默认使用纯本地目录，也可现在或以后再接入云盘。跳过此步将保留当前存储设置。"
                  />

                  <div className="flex flex-col gap-2.5">
                    <RadioChoiceCard
                      title="纯本地文件夹"
                      badge="默认推荐"
                      subtitle="零配置立即可用，文件完整留在你的本地文件夹"
                      icon={<CharkleIcon name="library" style="duotone" size={17} isActive={isLocalStorage} />}
                      selected={isLocalStorage}
                      onSelect={() => selectStorageMode('localOnly')}
                      detail={
                        <div className="flex items-center justify-between gap-2">
                          <span className="text-[11px] font-mono text-[var(--text-secondary)] truncate">
                            {draftSync.localLibraryPath || diagnostics?.dataDir || '默认本机素材库目录'}
                          </span>
                          <SettingsButton
                            variant="secondary"
                            onClick={async () => {
                              const picked = await getTransport().pickDirectoryDialog(
                                '选择本地素材库目录',
                              );
                              if (picked) {
                                const next: DriveSyncConfig = {
                                  ...draftSync,
                                  mode: 'localOnly',
                                  localLibraryPath: picked,
                                };
                                setDraftSync(next);
                                const ok = await saveSyncConfig(next, undefined, { quiet: true });
                                setActionHint({
                                  text: ok
                                    ? `已将本地存储目录设为：${picked}`
                                    : '保存本地目录失败，请重试',
                                  isError: !ok,
                                });
                              }
                            }}
                          >
                            选择文件夹…
                          </SettingsButton>
                        </div>
                      }
                    />

                    <RadioChoiceCard
                      title="Google Drive 云端直连"
                      badge={directAccount ? '已连接' : hasGoogleOAuthClient ? '凭据已就绪' : null}
                      subtitle="直连你自己的 Google Drive，不经第三方中转，支持多机同步与共享协作"
                      icon={<CharkleIcon name="drive-sync" style="duotone" size={17} isActive={isGoogleStorage} />}
                      selected={isGoogleStorage}
                      onSelect={() => selectStorageMode('directAPIWithGDirect')}
                      detail={
                        <div className="flex flex-wrap items-center justify-between gap-2">
                          {directAccount ? (
                            <>
                              <SettingsStatusBadge text={directAccount.email} tone="positive" />
                              <SettingsButton
                                variant="secondary"
                                onClick={() => openSettingsFromOnboarding('sync')}
                              >
                                管理云同步设置
                              </SettingsButton>
                            </>
                          ) : hasGoogleOAuthClient ? (
                            <>
                              <span className="text-[11px] text-[var(--text-secondary)]">
                                点击后在浏览器中安全完成 Google 登录
                              </span>
                              <div className="flex items-center gap-1.5">
                                <SettingsButton
                                  variant="primary"
                                  loading={signingInGoogle}
                                  onClick={async () => {
                                    const ok = await signInGoogleDrive();
                                    setActionHint({
                                      text: ok
                                        ? 'Google 账号登录成功，同步已就绪'
                                        : '登录未完成，可稍后在「设置 → 云同步」重试',
                                      isError: !ok,
                                    });
                                  }}
                                >
                                  {signingInGoogle ? '登录中…' : '使用 Google 登录'}
                                </SettingsButton>
                                <SettingsButton
                                  variant="secondary"
                                  onClick={() => openSettingsFromOnboarding('sync')}
                                >
                                  前往配置云同步
                                </SettingsButton>
                              </div>
                            </>
                          ) : (
                            <>
                              <span className="text-[11px] text-[var(--text-secondary)]">
                                首次直连需准备个人桌面端凭据，配置后可随时返回继续引导
                              </span>
                              <div className="flex items-center gap-1.5">
                                <SettingsButton
                                  variant="primary"
                                  onClick={() => setShowOAuthModal(true)}
                                >
                                  配置凭据并登录…
                                </SettingsButton>
                                <SettingsButton
                                  variant="secondary"
                                  onClick={() => openSettingsFromOnboarding('sync')}
                                >
                                  前往配置云同步
                                </SettingsButton>
                              </div>
                            </>
                          )}
                        </div>
                      }
                    />

                    <RadioChoiceCard
                      title="WebDAV 云盘 / 自建 NAS"
                      badge={
                        isWebDAVStorage && draftSync.webDAVServerURL.trim() && hasWebdavPassword
                          ? '已保存'
                          : null
                      }
                      subtitle="兼容坚果云、Nextcloud、群晖 NAS、Alist 等任意标准 WebDAV 服务"
                      icon={<CharkleIcon name="drive-sync" style="duotone" size={17} isActive={isWebDAVStorage} />}
                      selected={isWebDAVStorage}
                      onSelect={() => selectStorageMode('webDAV')}
                      detail={
                        <div className="flex flex-col gap-2">
                          <SettingsInput
                            type="text"
                            value={draftSync.webDAVServerURL}
                            onChange={(e) =>
                              setDraftSync({ ...draftSync, webDAVServerURL: e.target.value })
                            }
                            placeholder="服务器地址（如 https://dav.jianguoyun.com/dav/）"
                          />
                          {draftSync.webDAVServerURL.trim().length > 0 &&
                            !isValidHttpUrl(draftSync.webDAVServerURL) && (
                              <span className="text-[11px] text-[var(--settings-warning)]">
                                请输入以 https:// 或 http:// 开头的有效服务器地址
                              </span>
                            )}
                          <div className="flex gap-2">
                            <SettingsInput
                              type="text"
                              value={draftSync.webDAVUsername}
                              onChange={(e) =>
                                setDraftSync({ ...draftSync, webDAVUsername: e.target.value })
                              }
                              placeholder="用户名"
                              className="flex-1"
                            />
                            <SettingsInput
                              type="password"
                              value={webdavPasswordDraft}
                              onChange={(e) => setWebdavPasswordDraft(e.target.value)}
                              placeholder={hasWebdavPassword ? '已保存密码（留空保持）' : '应用专用密码'}
                              className="flex-1"
                            />
                            <SettingsButton
                              variant="primary"
                              loading={testingWebdav}
                              disabled={!isValidHttpUrl(draftSync.webDAVServerURL)}
                              onClick={async () => {
                                const res = await testWebdavConnection(
                                  {
                                    ...draftSync,
                                    webDAVServerURL: draftSync.webDAVServerURL.trim(),
                                    webDAVUsername: draftSync.webDAVUsername.trim(),
                                  },
                                  webdavPasswordDraft || null,
                                );
                                if (res.ok) setWebdavPasswordDraft('');
                                setActionHint({
                                  text: res.ok
                                    ? 'WebDAV 连接验证通过并已保存'
                                    : res.message || '连接失败，请核对地址或应用密码',
                                  isError: !res.ok,
                                });
                              }}
                            >
                              {testingWebdav ? '验证中…' : '测试并保存'}
                            </SettingsButton>
                          </div>
                        </div>
                      }
                    />
                  </div>

                  {/* Live non-blocking status bar so user always sees clear forward path */}
                  <div className="rounded-[9px] bg-[var(--settings-subtle)] border border-[var(--settings-border)] px-3 py-2 flex items-center justify-between gap-2 text-[11.5px]">
                    <span className="text-[var(--text-secondary)] truncate">
                      当前所选：<strong className="text-[var(--text-primary)]">{storageSummary}</strong>
                    </span>
                    <button
                      type="button"
                      onClick={() => goNext(false)}
                      className="text-[11.5px] font-semibold text-[var(--accent)] hover:underline inline-flex items-center gap-1 cursor-pointer shrink-0"
                    >
                      <span>继续下一步</span>
                      <ArrowRight size={11.5} />
                    </button>
                  </div>

                  {renderInlineFeedback()}
                </div>
              </div>
            )}

            {/* Step 2: Top-Edge Drop Shelf & Shortcuts */}
            {step === 2 && (
              <div className="h-full p-[22px] flex gap-[22px]">
                {/* Left Pedestal with Live Auto-Looping Mini-Notch Demo */}
                <div className="w-[234px] shrink-0 rounded-[14px] bg-[var(--settings-rail)] border border-[var(--settings-border)] p-4 flex flex-col justify-between gap-3.5">
                  <div className="flex flex-col gap-2.5">
                    <div className="relative h-[146px] rounded-[11px] bg-gradient-to-br from-[#E7EAEF] to-[#F3F4F6] dark:from-[#242730] dark:to-[#181A20] border border-[var(--settings-border)] overflow-hidden flex justify-center">
                      {/* Animated Pure-Black Mini Notch */}
                      <div
                        style={{
                          width: demoNotchExpanded ? 162 : 64,
                          height: demoNotchExpanded ? 64 : 16,
                          borderBottomLeftRadius: demoNotchExpanded ? 14 : 7,
                          borderBottomRightRadius: demoNotchExpanded ? 14 : 7,
                          transition:
                            'width 380ms var(--ease-notch-spring), height 380ms var(--ease-notch-spring), border-radius 380ms var(--ease-notch-spring)',
                        }}
                        className="bg-black shadow-[0_6px_14px_rgba(0,0,0,0.3)] flex flex-col items-center overflow-hidden motion-reduce:transition-none"
                      >
                        <div className="mt-[5px] w-[26px] h-[3.5px] rounded-full bg-white/22 shrink-0" />
                        {demoNotchExpanded && (
                          <div
                            className={[
                              'mt-2 px-2.5 py-1 rounded-[7px] flex items-center gap-1.5 text-[10px] font-semibold text-white/92 transition-colors duration-150 motion-reduce:transition-none',
                              demoConfirmed ? 'bg-[#3D9970]/25' : 'bg-[#3B82F6]/25',
                            ].join(' ')}
                          >
                            <CheckCircle2
                              size={11}
                              className={demoConfirmed ? 'text-[#4ADE80]' : 'text-[#60A5FA]'}
                            />
                            <span className="whitespace-nowrap">
                              {demoConfirmed
                                ? `已收入${targetModeLabel(shelfSettings.defaultTargetMode)}`
                                : '松手即存'}
                            </span>
                          </div>
                        )}
                      </div>

                      {/* Animated Dragged Media Card Flying into Notch */}
                      <div
                        style={{
                          transform: `translate3d(0, ${demoCardDropped ? 28 : 96}px, 0) scale(${demoConfirmed ? 0.65 : demoCardDropped ? 0.92 : 1})`,
                          opacity: demoConfirmed ? 0 : 1,
                          transition:
                            'transform 340ms var(--ease-out-strong), opacity 220ms var(--ease-out)',
                        }}
                        className="absolute top-0 h-[24px] w-[34px] rounded-[6px] bg-gradient-to-br from-[#3B74E8] to-[#2A8F9D] shadow-[0_4px_10px_rgba(0,0,0,0.2)] flex items-center justify-center motion-reduce:transition-none"
                      >
                        <ImageIcon size={11} className="text-white/95" />
                      </div>
                    </div>

                    <div className="flex items-start gap-2">
                      <CharkleIcon name="notch" style="layered" size={30} />
                      <p className="text-[11.5px] text-[var(--text-secondary)] leading-relaxed">
                        拖起素材靠近屏幕顶边即展，不抢焦点、不切桌面。
                      </p>
                    </div>
                  </div>

                  <SettingsButton
                    variant="secondary"
                    disabled={!shelfSettings.enabled}
                    onClick={() =>
                      void getTransport()
                        .toggleShelf()
                        .catch((err) => {
                          pushToast({
                            message: err instanceof Error ? err.message : '预览顶部浮窗失败',
                            tone: 'error',
                          });
                        })
                    }
                    className="w-full"
                  >
                    <CharkleIcon name="notch" style="duotone" size={14} />
                    <span>预览顶部浮窗 ({hotkeys.toggleShelf})</span>
                  </SettingsButton>
                </div>

                {/* Right Live Switches */}
                <div className="flex-1 min-w-0 overflow-y-auto charkle-scroll-hidden pr-0.5 flex flex-col gap-3">
                  <StepHeading
                    title="顶部浮窗与快捷采集"
                    subtitle="在任意应用中拖拽靠近屏幕顶部即可收纳灵感，以下开关即时生效，不需要的项目可留空跳过。"
                  />

                  <div className="rounded-[12px] bg-[var(--settings-card)] border border-[var(--settings-border)] overflow-hidden">
                    <div className="px-3.5 py-2.5 flex items-center justify-between gap-3">
                      <div className="min-w-0">
                        <div className="text-[13px] font-medium text-[var(--text-primary)]">
                          启用屏幕顶部灵感浮窗
                        </div>
                        <div className="text-[11.5px] text-[var(--text-secondary)] mt-0.5">
                          拖起图片、链接或文件靠近顶边时自动滑出收纳区
                        </div>
                      </div>
                      <SettingsSwitch
                        checked={shelfSettings.enabled}
                        ariaLabel="引导启用顶部灵感浮窗"
                        onChange={(enabled) => void persistShelf({ enabled })}
                      />
                    </div>

                    <SettingsCardDivider />

                    <div
                      className={[
                        'px-3.5 py-2.5 flex items-center justify-between gap-3',
                        !shelfSettings.enabled ? 'opacity-55' : '',
                      ].join(' ')}
                    >
                      <div className="min-w-0">
                        <div className="text-[13px] font-medium text-[var(--text-primary)]">
                          悬停顶部中央自动展开
                        </div>
                        <div className="text-[11.5px] text-[var(--text-secondary)] mt-0.5">
                          鼠标停留在屏幕顶边中央片刻即可浏览最近素材或反向拖出
                        </div>
                      </div>
                      <SettingsSwitch
                        checked={shelfSettings.hoverTriggerEnabled}
                        disabled={!shelfSettings.enabled}
                        ariaLabel="引导悬停顶部自动展开"
                        onChange={(hoverTriggerEnabled) =>
                          void persistShelf({ hoverTriggerEnabled })
                        }
                      />
                    </div>

                    <SettingsCardDivider />

                    <div
                      className={[
                        'px-3.5 py-2.5 flex items-center justify-between gap-3',
                        !shelfSettings.enabled ? 'opacity-55' : '',
                      ].join(' ')}
                    >
                      <div className="min-w-0">
                        <div className="text-[13px] font-medium text-[var(--text-primary)]">
                          默认收纳目标
                        </div>
                        <div className="text-[11.5px] text-[var(--text-secondary)] mt-0.5">
                          拖入浮窗或快捷键采集的新灵感默认落入位置
                        </div>
                      </div>
                      <SegmentedControl<'inbox' | 'folder' | 'activeMoodboard'>
                        value={shelfSettings.defaultTargetMode}
                        onChange={(defaultTargetMode) =>
                          void persistShelf({
                            defaultTargetMode,
                            defaultFolderId:
                              defaultTargetMode === 'folder'
                                ? (shelfSettings.defaultFolderId ?? folders[0]?.id ?? null)
                                : shelfSettings.defaultFolderId,
                          })
                        }
                        ariaLabel="引导默认收纳目标"
                        options={[
                          { value: 'inbox', label: '收件箱' },
                          { value: 'folder', label: '文件夹' },
                          { value: 'activeMoodboard', label: '情绪板' },
                        ]}
                      />
                    </div>

                    {shelfSettings.enabled && shelfSettings.defaultTargetMode === 'folder' && (
                      <>
                        <SettingsCardDivider />
                        <div className="px-3.5 py-2.5 flex items-center justify-between gap-3">
                          <span className="text-[12.5px] font-medium text-[var(--text-primary)]">
                            指定默认文件夹
                          </span>
                          <div className="w-[180px]">
                            <CustomSelect
                              value={shelfSettings.defaultFolderId ?? ''}
                              onChange={(val) => void persistShelf({ defaultFolderId: val || null })}
                              ariaLabel="引导指定默认文件夹"
                              options={[
                                { value: '', label: '未选择（回落至收件箱）' },
                                ...folders.map((f) => ({ value: f.id, label: f.name })),
                              ]}
                            />
                          </div>
                        </div>
                      </>
                    )}

                    <SettingsCardDivider />

                    <div className="px-3.5 py-2.5 flex items-center justify-between gap-3">
                      <div className="min-w-0">
                        <div className="text-[13px] font-medium text-[var(--text-primary)]">
                          启用系统全局快捷键
                        </div>
                        <div className="text-[11.5px] text-[var(--text-secondary)] mt-0.5">
                          任意应用中随时按 {hotkeys.captureArea} 截图、{hotkeys.collectClipboard}{' '}
                          收藏剪贴板与推文、{hotkeys.toggleShelf} 呼出浮窗
                        </div>
                      </div>
                      <SettingsSwitch
                        checked={hotkeys.enabled}
                        ariaLabel="引导启用系统全局快捷键"
                        onChange={(enabled) => void toggleHotkeysEnabled(enabled)}
                      />
                    </div>
                  </div>

                  {/* Quick Hotkey Reference Strip */}
                  <div className="rounded-[12px] bg-[var(--settings-card)] border border-[var(--settings-border)] px-3.5 py-2.5 flex flex-col gap-2">
                    <div className="flex items-center justify-between">
                      <span className="text-[12px] font-medium text-[var(--text-primary)]">
                        全局采集快捷键
                      </span>
                      <SettingsStatusBadge
                        text={hotkeys.enabled ? '已就绪' : '已暂停'}
                        tone={hotkeys.enabled ? 'positive' : 'neutral'}
                      />
                    </div>
                    <div className="grid grid-cols-3 gap-2 text-[11px] text-[var(--text-secondary)]">
                      <div className="rounded-[8px] bg-[var(--settings-subtle)] px-2.5 py-1.5">
                        <kbd className="font-mono font-semibold text-[var(--text-primary)]">
                          {hotkeys.captureArea}
                        </kbd>
                        <div className="mt-0.5">区域截图</div>
                      </div>
                      <div className="rounded-[8px] bg-[var(--settings-subtle)] px-2.5 py-1.5">
                        <kbd className="font-mono font-semibold text-[var(--text-primary)]">
                          {hotkeys.toggleShelf}
                        </kbd>
                        <div className="mt-0.5">呼出 / 隐藏浮窗</div>
                      </div>
                      <div className="rounded-[8px] bg-[var(--settings-subtle)] px-2.5 py-1.5">
                        <kbd className="font-mono font-semibold text-[var(--text-primary)]">
                          {hotkeys.collectClipboard}
                        </kbd>
                        <div className="mt-0.5">一键收藏剪贴板</div>
                      </div>
                    </div>
                  </div>
                </div>
              </div>
            )}

            {/* Step 3: Local Vision + Optional Cloud AI */}
            {step === 3 && (
              <div className="h-full p-[22px] flex gap-[22px]">
                <div className="w-[234px] shrink-0 rounded-[14px] bg-[var(--settings-rail)] border border-[var(--settings-border)] p-4 flex flex-col items-center justify-center gap-4">
                  <StepHeroIconDisc iconName="ai-spark" accentHex="#2A8F9D" />

                  <div className="w-full rounded-[11px] bg-[var(--settings-card)] border border-[var(--settings-border)] p-3 flex flex-col gap-1.5">
                    <div className="text-[12px] font-semibold text-[var(--text-primary)]">
                      基础离线能力免费内置
                    </div>
                    <div className="text-[10.5px] text-[var(--text-secondary)] mb-1">
                      无需下载模型 · 数据不出本机
                    </div>
                    {[
                      '自动配色提取',
                      '视觉相似推荐（本机离线）',
                      '图内文字 OCR 识别',
                      '中文与拼音首字母快搜',
                    ].map((item) => (
                      <div
                        key={item}
                        className="flex items-center gap-1.5 text-[11px] text-[var(--text-secondary)]"
                      >
                        <CheckCircle2
                          size={11}
                          className="text-[var(--settings-positive)] shrink-0"
                        />
                        <span>{item}</span>
                      </div>
                    ))}
                  </div>
                </div>

                <div className="flex-1 min-w-0 overflow-y-auto charkle-scroll-hidden pr-0.5 flex flex-col gap-3">
                  <StepHeading
                    title="需要云端 AI 自动打标与生板吗？"
                    subtitle="纯属可选增强项。跳过将保持仅使用本机离线能力，日后可在「设置 → AI 智能」随时接入。"
                  />

                  <div className="flex flex-col gap-2.5">
                    <RadioChoiceCard
                      title="仅使用内置离线能力"
                      badge="默认"
                      subtitle="零费用、零账号、完全离线；配色、OCR、相似图与快搜全部立即可用"
                      icon={<CharkleIcon name="similar" style="duotone" size={17} isActive={isLocalAI} />}
                      selected={isLocalAI}
                      onSelect={() => selectAIProvider('disabled')}
                    />

                    <RadioChoiceCard
                      title="连接 ChatGPT 订阅账号"
                      badge={aiState?.chatgptSession.status === 'connected' ? '已连接' : null}
                      subtitle="使用你的 ChatGPT Plus / Pro 订阅，无需额外购买 API Key"
                      icon={<ChatGPTBrandMark size={17} />}
                      selected={isChatGPTAI}
                      onSelect={() => selectAIProvider('chatGPTSubscription')}
                      detail={
                        <div className="flex flex-wrap items-center justify-between gap-2 text-[11px] text-[var(--text-secondary)]">
                          {aiState?.chatgptSession.status === 'connected' ? (
                            <>
                              <SettingsStatusBadge
                                text={aiState.chatgptSession.email ?? aiState.chatgptSession.name ?? 'ChatGPT'}
                                tone="positive"
                              />
                              <SettingsButton
                                variant="secondary"
                                onClick={() => openSettingsFromOnboarding('ai')}
                              >
                                前往 AI 设置
                              </SettingsButton>
                            </>
                          ) : (
                            <>
                              <span>通过官方登录授权，凭据仅安全保存在本机</span>
                              <div className="flex items-center gap-1.5">
                                <SettingsButton
                                  variant="primary"
                                  loading={signingInChatgpt}
                                  onClick={async () => {
                                    const ok = await signInChatgpt(false, false);
                                    setActionHint({
                                      text: ok
                                        ? '已连接 ChatGPT 账号，云端打标与策展已就绪'
                                        : '连接未完成，可稍后在「设置 → AI 智能」重试',
                                      isError: !ok,
                                    });
                                  }}
                                >
                                  {signingInChatgpt ? '等待授权…' : '登录 ChatGPT'}
                                </SettingsButton>
                                <SettingsButton
                                  variant="secondary"
                                  onClick={() => openSettingsFromOnboarding('ai')}
                                >
                                  前往 AI 设置
                                </SettingsButton>
                              </div>
                            </>
                          )}
                        </div>
                      }
                    />

                    <RadioChoiceCard
                      title="Google Gemini 或自定义 API"
                      badge={isAPIAI && (aiState?.hasApiKey || isLocalOllama) ? '已配置' : null}
                      subtitle="一键预设 Gemini、OpenAI、Claude、DeepSeek 或本机 Ollama"
                      icon={<CharkleIcon name="sparkle-board" style="duotone" size={17} isActive={isAPIAI} />}
                      selected={isAPIAI}
                      onSelect={() => {
                        if (!isAPIAI) applyAIPreset(AI_PRESETS[0]);
                      }}
                      detail={
                        <div className="flex flex-col gap-2">
                          <div className="flex flex-wrap gap-1.5">
                            {AI_PRESETS.map((preset) => {
                              const active = isPresetActive(preset);
                              return (
                                <button
                                  key={preset.id}
                                  type="button"
                                  onClick={() => applyAIPreset(preset)}
                                  className={[
                                    'charkle-pressable px-2.5 py-[3px] rounded-full text-[11px] cursor-pointer transition-colors duration-150 motion-reduce:transition-none',
                                    active
                                      ? 'bg-[#18191D] text-white dark:bg-white dark:text-[#111215] font-semibold'
                                      : 'bg-[var(--settings-subtle)] text-[var(--text-secondary)] hover:text-[var(--text-primary)] font-medium',
                                  ].join(' ')}
                                >
                                  {preset.label}
                                </button>
                              );
                            })}
                          </div>

                          <div className="flex gap-2">
                            <SettingsInput
                              type="text"
                              value={draftAI.chatModel}
                              onChange={(e) =>
                                setDraftAI({ ...draftAI, chatModel: e.target.value })
                              }
                              placeholder="模型名（如 gemini-2.5-flash）"
                              className="flex-1"
                            />
                            {draftAI.provider === 'openAICompatible' && (
                              <SettingsInput
                                type="text"
                                value={draftAI.baseURL}
                                onChange={(e) =>
                                  setDraftAI({ ...draftAI, baseURL: e.target.value })
                                }
                                placeholder="接口地址"
                                className="flex-1"
                              />
                            )}
                          </div>

                          {draftAI.provider === 'openAICompatible' &&
                            draftAI.baseURL.trim().length > 0 &&
                            !isValidHttpUrl(draftAI.baseURL) && (
                              <span className="text-[11px] text-[var(--settings-warning)]">
                                请输入以 https:// 或 http:// 开头的有效服务地址
                              </span>
                            )}

                          <div className="flex gap-2">
                            <SettingsInput
                              type="password"
                              value={aiKeyDraft}
                              onChange={(e) => setAiKeyDraft(e.target.value)}
                              placeholder={
                                isLocalOllama
                                  ? '本机 Ollama 无需 API Key（可直接保存）'
                                  : aiState?.hasApiKey
                                    ? '已存有密钥（留空保持）'
                                    : '粘贴 API Key（仅加密存本机）'
                              }
                              className="flex-1"
                            />
                            <SettingsButton
                              variant="primary"
                              loading={savingAiDraft}
                              disabled={
                                draftAI.provider === 'openAICompatible' &&
                                !isValidHttpUrl(draftAI.baseURL)
                              }
                              onClick={async () => {
                                setSavingAiDraft(true);
                                try {
                                  const ok = await saveAiConfig(
                                    { ...draftAI, baseURL: draftAI.baseURL.trim() },
                                    {
                                      apiKey: aiKeyDraft.trim() || null,
                                      quiet: true,
                                    },
                                  );
                                  if (ok) {
                                    setAiKeyDraft('');
                                    setActionHint({
                                      text: 'AI 配置已安全保存至 Windows 凭据管理器',
                                      isError: false,
                                    });
                                  } else {
                                    setActionHint({
                                      text: '保存 AI 配置失败，请检查地址与密钥后重试',
                                      isError: true,
                                    });
                                  }
                                } finally {
                                  setSavingAiDraft(false);
                                }
                              }}
                            >
                              {savingAiDraft ? '保存中…' : '保存'}
                            </SettingsButton>
                          </div>
                        </div>
                      }
                    />
                  </div>

                  <div className="flex items-center justify-between gap-2 text-[11px] text-[var(--text-tertiary)]">
                    <span>进阶视觉定位与外部 AI Agent (MCP) 可随时在「设置 → 生态与智能」中按需开启。</span>
                    <button
                      type="button"
                      onClick={() => openSettingsFromOnboarding('ai')}
                      className="text-[11px] font-medium text-[var(--accent)] hover:underline cursor-pointer shrink-0"
                    >
                      更多 AI 设置
                    </button>
                  </div>

                  {renderInlineFeedback()}
                </div>
              </div>
            )}

            {/* Step 4: Appearance & Default Gallery Layout */}
            {step === 4 && (
              <div className="h-full p-[22px] flex gap-[22px]">
                <div className="w-[234px] shrink-0 rounded-[14px] bg-[var(--settings-rail)] border border-[var(--settings-border)] p-4 flex flex-col items-center justify-center gap-4">
                  <StepHeroIconDisc iconName="gallery" accentHex="#D96B43" />
                  <GalleryLayoutMiniPreview mode={layoutMode} />
                </div>

                <div className="flex-1 min-w-0 overflow-y-auto charkle-scroll-hidden pr-0.5 flex flex-col gap-3.5">
                  <StepHeading
                    title="挑选顺眼的主题与画廊排布"
                    subtitle="点选立即生效，外观主题与主画布默认排布会实时同步。保持默认可直接跳过。"
                  />

                  {/* Theme Cards */}
                  <div className="flex flex-col gap-1.5">
                    <span className="text-[11.5px] font-medium text-[var(--settings-label)]">
                      外观主题
                    </span>
                    <div className="grid grid-cols-3 gap-2.5">
                      {(
                        [
                          { id: 'system', title: '跟随系统', sub: '自动同步浅/深色', icon: Monitor },
                          { id: 'light', title: '浅色画廊', sub: '柔和暖白画布', icon: Sun },
                          { id: 'dark', title: '深色画廊', sub: '静谧聚焦影像', icon: Moon },
                        ] as const
                      ).map((opt) => {
                        const selected = themeMode === opt.id;
                        const Icon = opt.icon;
                        return (
                          <button
                            key={opt.id}
                            type="button"
                            onClick={() => void setThemeMode(opt.id)}
                            className={[
                              'charkle-pressable rounded-[12px] p-3 text-left flex flex-col gap-1.5 cursor-pointer transition-colors duration-150 motion-reduce:transition-none',
                              selected
                                ? 'bg-[var(--text-primary)]/[0.045] dark:bg-white/[0.075] border-[1.35px] border-[var(--text-primary)]/45 dark:border-white/50'
                                : 'bg-[var(--settings-card)] border border-[var(--settings-border)]',
                            ].join(' ')}
                          >
                            <div className="flex items-center justify-between">
                              <Icon size={15} className="text-[var(--text-primary)]" />
                              <RadioIndicator selected={selected} />
                            </div>
                            <div className="text-[12.5px] font-semibold text-[var(--text-primary)]">
                              {opt.title}
                            </div>
                            <div className="text-[10.5px] text-[var(--text-secondary)]">
                              {opt.sub}
                            </div>
                          </button>
                        );
                      })}
                    </div>
                  </div>

                  {/* Gallery Layout Cards */}
                  <div className="flex flex-col gap-1.5">
                    <span className="text-[11.5px] font-medium text-[var(--settings-label)]">
                      画廊默认排布
                    </span>
                    <div className="grid grid-cols-2 gap-2.5">
                      {(
                        [
                          {
                            mode: 'verticalMasonry' as GalleryLayoutMode,
                            title: '纵向瀑布流',
                            sub: '保留原比例，高密度扫图',
                            iconName: 'masonry-vertical',
                          },
                          {
                            mode: 'horizontalJustified' as GalleryLayoutMode,
                            title: '横向等高行',
                            sub: '行高齐平，节奏工整',
                            iconName: 'masonry-horizontal',
                          },
                          {
                            mode: 'galleryFilmstrip' as GalleryLayoutMode,
                            title: '画廊视图',
                            sub: '大图直览 + 翻转缩放',
                            iconName: 'quicklook',
                          },
                          {
                            mode: 'ringGallery' as GalleryLayoutMode,
                            title: '环形画廊',
                            sub: '立体弧形环，沉浸漫游',
                            iconName: 'gallery-ring',
                          },
                        ] as const
                      ).map((opt) => {
                        const selected = layoutMode === opt.mode;
                        return (
                          <button
                            key={opt.mode}
                            type="button"
                            onClick={() => setLayoutMode(opt.mode)}
                            className={[
                              'charkle-pressable rounded-[12px] p-3 text-left flex flex-col gap-1.5 cursor-pointer transition-colors duration-150 motion-reduce:transition-none',
                              selected
                                ? 'bg-[var(--text-primary)]/[0.045] dark:bg-white/[0.075] border-[1.35px] border-[var(--text-primary)]/45 dark:border-white/50'
                                : 'bg-[var(--settings-card)] border border-[var(--settings-border)]',
                            ].join(' ')}
                          >
                            <div className="flex items-center justify-between">
                              <CharkleIcon
                                name={opt.iconName}
                                style="duotone"
                                size={17}
                                isActive={selected}
                              />
                              <RadioIndicator selected={selected} />
                            </div>
                            <div className="text-[12.5px] font-semibold text-[var(--text-primary)]">
                              {opt.title}
                            </div>
                            <div className="text-[10.5px] text-[var(--text-secondary)] leading-snug">
                              {opt.sub}
                            </div>
                          </button>
                        );
                      })}
                    </div>
                  </div>

                  {/* Compact Sidebar Toggle */}
                  <div className="rounded-[12px] bg-[var(--settings-card)] border border-[var(--settings-border)] px-3.5 py-3 flex items-center justify-between gap-3">
                    <div className="min-w-0">
                      <div className="text-[12.5px] font-medium text-[var(--text-primary)]">
                        启动时默认收起侧边栏为精简图标栏
                      </div>
                      <div className="text-[11px] text-[var(--text-secondary)] mt-0.5">
                        随时可用 Ctrl+\ 一键展开或收起，左侧底部齿轮按钮可随时打开设置
                      </div>
                    </div>
                    <SettingsSwitch
                      checked={sidebarCollapsed}
                      ariaLabel="启动时默认收起侧边栏为精简图标栏"
                      onChange={setSidebarCollapsed}
                    />
                  </div>
                </div>
              </div>
            )}

            {/* Step 5: Ready Summary & Completion Shockwave Seal */}
            {step === 5 && (
              <div className="h-full overflow-y-auto charkle-scroll px-[36px] py-5">
                <div className="min-h-full flex flex-col items-center justify-center gap-5">
                  <div className="relative h-[88px] w-[88px] flex items-center justify-center">
                  <span
                    aria-hidden="true"
                    className="charkle-shockwave absolute inset-[5px] rounded-full border-[2.5px] border-[#3D9970]/60"
                  />
                  <span
                    aria-hidden="true"
                    style={{ animationDelay: '80ms' }}
                    className="charkle-shockwave absolute inset-[5px] rounded-full border-[1.5px] border-[#3B74E8]/40"
                  />
                  <div className="h-[88px] w-[88px] rounded-full bg-[#3D9970]/12 flex items-center justify-center">
                    <CharkleIcon name="ready" style="layered" size={64} />
                  </div>
                </div>

                <div className="flex flex-col items-center text-center gap-1.5">
                  <h2 className="text-[25px] font-bold tracking-[-0.02em] text-[var(--text-primary)]">
                    一切准备就绪
                  </h2>
                  <p className="text-[13px] text-[var(--text-secondary)]">
                    点击任意卡片可回头微调，或随时按 Ctrl+, 打开设置页继续深度定制。
                  </p>
                </div>

                <div className="grid grid-cols-2 gap-3 w-full">
                  {(
                    [
                      {
                        iconName: 'library',
                        title: '素材库与云同步',
                        value: storageSummary,
                        skipped: skippedSteps.has(1),
                        target: 1 as OnboardingStep,
                      },
                      {
                        iconName: 'notch',
                        title: '顶部浮窗与采集',
                        value: captureSummary,
                        skipped: skippedSteps.has(2),
                        target: 2 as OnboardingStep,
                      },
                      {
                        iconName: 'ai-spark',
                        title: 'AI 智能',
                        value: aiSummary,
                        skipped: skippedSteps.has(3),
                        target: 3 as OnboardingStep,
                      },
                      {
                        iconName: 'gallery',
                        title: '外观与画廊排布',
                        value: workspaceSummary,
                        skipped: skippedSteps.has(4),
                        target: 4 as OnboardingStep,
                      },
                    ] as const
                  ).map((item) => (
                    <button
                      key={item.title}
                      type="button"
                      onClick={() => navigate(item.target)}
                      className="charkle-pressable rounded-[12px] bg-[var(--settings-card)] border border-[var(--settings-border)] hover:border-[var(--text-primary)]/35 p-3 flex items-center gap-3 text-left cursor-pointer transition-colors duration-150 motion-reduce:transition-none"
                    >
                      <span className="h-9 w-9 rounded-[9px] bg-[var(--settings-subtle)] inline-flex items-center justify-center shrink-0">
                        <CharkleIcon
                          name={item.iconName}
                          style="duotone"
                          size={19}
                          isActive={!item.skipped}
                        />
                      </span>
                      <div className="min-w-0 flex-1">
                        <div className="flex items-center gap-1.5">
                          <span className="text-[11px] font-medium text-[var(--text-secondary)]">
                            {item.title}
                          </span>
                          {item.skipped && (
                            <span className="px-1.5 py-[1px] rounded-full bg-[var(--settings-subtle)] text-[9.5px] text-[var(--text-tertiary)]">
                              已跳过
                            </span>
                          )}
                        </div>
                        <div className="text-[12.5px] font-semibold text-[var(--text-primary)] truncate mt-0.5">
                          {item.value}
                        </div>
                      </div>
                      <ChevronRight size={13} className="text-[var(--text-tertiary)] shrink-0" />
                    </button>
                  ))}
                  </div>
                </div>
              </div>
            )}
          </div>
        </div>

        {/* Footer Navigation Bar */}
        <footer className="px-[22px] py-[14px] border-t border-[var(--settings-border)] flex items-center justify-between gap-3 shrink-0 select-none">
          <div className="min-w-0">
            {step > 0 ? (
              <SettingsButton
                variant="secondary"
                onClick={() => navigate((step - 1) as OnboardingStep)}
              >
                <ChevronLeft size={13} />
                上一步
              </SettingsButton>
            ) : (
              <span className="text-[11.5px] text-[var(--text-secondary)]">
                每一步都可跳过 · 随时可在「设置 (Ctrl+,) → 通用」重新查看
              </span>
            )}
          </div>

          <div className="flex items-center gap-2 shrink-0">
            <span className="text-[11.5px] font-medium font-mono charkle-tabular text-[var(--text-tertiary)] mr-1">
              {step + 1} / {STEPS.length}
            </span>

            {step === 0 && (
              <>
                <SettingsButton variant="secondary" onClick={skipEntireOnboarding}>
                  跳过，直接使用
                </SettingsButton>
                <CharkleSkeuoButton onClick={() => goNext(false)}>
                  <span>开始快速配置</span>
                  <ArrowRight size={13} />
                </CharkleSkeuoButton>
              </>
            )}

            {step >= 1 && step <= 4 && (
              <>
                <SettingsButton
                  variant="secondary"
                  title="保持当前默认设置，稍后再在「设置」中按需配置"
                  onClick={() => goNext(true)}
                >
                  跳过此步
                </SettingsButton>
                <CharkleSkeuoButton onClick={() => goNext(false)}>
                  <span>{step === 4 ? '查看配置摘要' : '下一步'}</span>
                  <ArrowRight size={13} />
                </CharkleSkeuoButton>
              </>
            )}

            {step === 5 && (
              <>
                <SettingsButton
                  variant="secondary"
                  onClick={() => {
                    completeOnboarding();
                    openSettings('general');
                  }}
                >
                  打开完整设置 (Ctrl+,)
                </SettingsButton>
                <CharkleSkeuoButton onClick={completeOnboarding}>
                  <span>进入 Charkle 工作台</span>
                  <ArrowRight size={13} />
                </CharkleSkeuoButton>
              </>
            )}
          </div>
        </footer>
      </div>

      <GoogleOAuthSetupModal
        open={showOAuthModal}
        onClose={() => setShowOAuthModal(false)}
        autoSignInAfterSave
        onCompleted={() =>
          setActionHint({
            text: '凭据已导入，正在前往浏览器完成 Google 登录',
            isError: false,
          })
        }
      />
    </div>
  );
};
