import React, { useState } from 'react';
import {
  ArrowLeft,
  ArrowRight,
  CheckCircle2,
  Cloud,
  Palette,
  PanelTop,
  Sparkles,
} from 'lucide-react';
import { getTransport } from '../../api/transport';
import { Button, CharkleBrandMark, SegmentedControl, type ThemeMode } from '../../design-system';
import { useCoordinatorStore, useSyncAIStore } from '../../stores';
import type { CloudAIProviderKind, DriveTransportMode } from '../../types/domain';

type OnboardingStep = 0 | 1 | 2 | 3 | 4 | 5;

const STEPS: Array<{ id: OnboardingStep; label: string }> = [
  { id: 0, label: '欢迎' },
  { id: 1, label: '素材库' },
  { id: 2, label: '采集' },
  { id: 3, label: 'AI 智能' },
  { id: 4, label: '外观' },
  { id: 5, label: '完成' },
];

/**
 * Skippable 6-step first-launch & re-runnable Onboarding Studio (M5-R3),
 * matching `Sources/CharkleApp/Views/OnboardingView.swift`.
 */
export const OnboardingStudio: React.FC = () => {
  const open = useCoordinatorStore((s) => s.onboardingOpen);
  const completeOnboarding = useCoordinatorStore((s) => s.completeOnboarding);
  const themeMode = useCoordinatorStore((s) => s.themeMode);
  const setThemeMode = useCoordinatorStore((s) => s.setThemeMode);
  const openSettings = useCoordinatorStore((s) => s.openSettings);

  const syncConfig = useSyncAIStore((s) => s.syncConfig);
  const saveSyncConfig = useSyncAIStore((s) => s.saveSyncConfig);
  const aiState = useSyncAIStore((s) => s.aiState);
  const saveAiConfig = useSyncAIStore((s) => s.saveAiConfig);

  const [step, setStep] = useState<OnboardingStep>(0);
  const [storageMode, setStorageMode] = useState<DriveTransportMode>(
    syncConfig?.mode ?? 'localOnly',
  );
  const [aiMode, setAiMode] = useState<CloudAIProviderKind>(
    aiState?.config.provider ?? 'disabled',
  );

  if (!open) return null;

  const next = () => {
    if (step < 5) setStep((step + 1) as OnboardingStep);
    else completeOnboarding();
  };

  return (
    <div
      data-testid="onboarding-studio"
      role="dialog"
      aria-modal="true"
      aria-label="Charkle 新手引导工作室"
      className="fixed inset-0 z-50 bg-black/40 backdrop-blur-[5px] flex items-center justify-center p-6"
    >
      <div className="w-full max-w-[780px] h-[min(560px,86vh)] rounded-[var(--radius-modal)] bg-[var(--bg-gallery)] border border-[var(--border-strong)] shadow-[var(--shadow-modal)] flex flex-col overflow-hidden">
        {/* Top Step Pills + Always-Available Skip Button */}
        <header className="px-6 py-3.5 border-b border-[var(--border-hairline)] flex items-center justify-between gap-3">
          <div className="flex items-center gap-2">
            <CharkleBrandMark size={20} />
            <span className="text-[13px] font-semibold text-[var(--text-primary)]">
              Charkle 初始引导
            </span>
          </div>

          <div className="flex items-center gap-1">
            {STEPS.map((s) => (
              <button
                key={s.id}
                type="button"
                onClick={() => setStep(s.id)}
                className={[
                  'px-2.5 h-6 rounded-full text-[11.5px] cursor-pointer transition-colors',
                  step === s.id
                    ? 'bg-[var(--accent)] text-white font-medium'
                    : step > s.id
                      ? 'bg-[var(--accent-soft)] text-[var(--accent)]'
                      : 'text-[var(--text-tertiary)] hover:bg-[var(--bg-subtle)]',
                ].join(' ')}
              >
                {s.label}
              </button>
            ))}
          </div>

          <button
            type="button"
            onClick={completeOnboarding}
            className="text-[12px] text-[var(--text-secondary)] hover:text-[var(--text-primary)] cursor-pointer"
          >
            跳过引导
          </button>
        </header>

        {/* Step Body */}
        <div className="flex-1 min-h-0 overflow-y-auto p-8 flex flex-col justify-center">
          {step === 0 && (
            <div className="flex flex-col items-center text-center gap-4 max-w-[540px] mx-auto">
              <CharkleBrandMark size={48} />
              <h1 className="text-[22px] font-semibold tracking-[-0.02em] text-[var(--text-primary)]">
                欢迎使用 Charkle Windows
              </h1>
              <p className="text-[13.5px] text-[var(--text-secondary)] leading-relaxed">
                为设计师打造的跨平台视觉灵感库与双模式情绪板工作室。接下来只需不到 1 分钟，即可按需完成素材库存储、顶部悬浮窗、AI 检索与外观配置——任意步骤均可跳过。
              </p>
              <div className="grid grid-cols-3 gap-3 w-full pt-2 text-left">
                {[
                  ['顶部悬浮窗', '拖向屏幕顶部即可收集，随时原生拖出到 Figma / PS'],
                  ['双模式情绪板', '自动编排与自由无限画布零跳变切换，无损导出 Figma'],
                  ['跨平台云同步', '与 macOS v1.0.1 共用 /.charkle/ 增量协议'],
                ].map(([t, d]) => (
                  <div
                    key={t}
                    className="rounded-[var(--radius-settings-inner)] bg-[var(--bg-elevated)] border border-[var(--border-hairline)] p-3"
                  >
                    <div className="text-[12.5px] font-semibold text-[var(--text-primary)]">{t}</div>
                    <div className="text-[11.5px] text-[var(--text-tertiary)] mt-1 leading-snug">
                      {d}
                    </div>
                  </div>
                ))}
              </div>
            </div>
          )}

          {step === 1 && (
            <div className="max-w-[560px] mx-auto w-full flex flex-col gap-4">
              <div className="flex items-center gap-2 text-[var(--accent)]">
                <Cloud size={18} />
                <span className="text-[12px] font-semibold">第 1 步 · 素材库存储</span>
              </div>
              <h2 className="text-[18px] font-semibold text-[var(--text-primary)]">
                选择您的素材保存与同步方式
              </h2>
              <SegmentedControl<DriveTransportMode>
                value={storageMode}
                onChange={(mode) => {
                  setStorageMode(mode);
                  if (syncConfig) {
                    void saveSyncConfig({ ...syncConfig, mode });
                  }
                }}
                ariaLabel="引导存储方式"
                options={[
                  { value: 'localOnly', label: '纯本地文件夹' },
                  { value: 'directAPIWithGDirect', label: 'Google Drive' },
                  { value: 'webDAV', label: 'WebDAV' },
                  { value: 'gdirectMount', label: 'Windows 挂载盘' },
                ]}
              />
              <p className="text-[12.5px] text-[var(--text-secondary)]">
                您随时可在「设置 → 云同步」中填写详细凭据，或使用无损存储迁移向导在任意后端之间自由切换。
              </p>
            </div>
          )}

          {step === 2 && (
            <div className="max-w-[560px] mx-auto w-full flex flex-col gap-4">
              <div className="flex items-center gap-2 text-[var(--accent)]">
                <PanelTop size={18} />
                <span className="text-[12px] font-semibold">第 2 步 · 顶部悬浮窗与截图</span>
              </div>
              <h2 className="text-[18px] font-semibold text-[var(--text-primary)]">
                全局快捷采集与无焦点顶部悬浮窗
              </h2>
              <div className="rounded-[var(--radius-settings-outer)] bg-[var(--bg-elevated)] border border-[var(--border-hairline)] p-4 flex items-center justify-between gap-3">
                <div className="text-[12.5px] text-[var(--text-secondary)] space-y-1">
                  <div>
                    <kbd className="px-1.5 py-0.5 rounded bg-[var(--bg-subtle)] font-mono text-[11px]">
                      Alt+Shift+A
                    </kbd>{' '}
                    多屏 1:1 区域截图（带 8× 放大镜）
                  </div>
                  <div>
                    <kbd className="px-1.5 py-0.5 rounded bg-[var(--bg-subtle)] font-mono text-[11px]">
                      Alt+Shift+S
                    </kbd>{' '}
                    呼出 / 隐藏顶部灵感悬浮窗
                  </div>
                  <div>
                    <kbd className="px-1.5 py-0.5 rounded bg-[var(--bg-subtle)] font-mono text-[11px]">
                      Alt+Shift+V
                    </kbd>{' '}
                    一键采集当前系统剪贴板
                  </div>
                </div>
                <Button variant="secondary" size="sm" onClick={() => void getTransport().toggleShelf()}>
                  <PanelTop size={14} />
                  试用悬浮窗
                </Button>
              </div>
            </div>
          )}

          {step === 3 && (
            <div className="max-w-[560px] mx-auto w-full flex flex-col gap-4">
              <div className="flex items-center gap-2 text-[var(--accent)]">
                <Sparkles size={18} />
                <span className="text-[12px] font-semibold">第 3 步 · 混合 AI 检索与策展</span>
              </div>
              <h2 className="text-[18px] font-semibold text-[var(--text-primary)]">
                默认本机离线可用，按需启用云端 AI 增强
              </h2>
              <SegmentedControl<CloudAIProviderKind>
                value={aiMode}
                onChange={(provider) => {
                  setAiMode(provider);
                  if (aiState) {
                    void saveAiConfig({ ...aiState.config, provider });
                  }
                }}
                ariaLabel="引导 AI 模式"
                options={[
                  { value: 'disabled', label: '纯本机离线' },
                  { value: 'gemini', label: 'Gemini' },
                  { value: 'openAICompatible', label: 'OpenAI / Claude / Ollama' },
                  { value: 'chatGPTSubscription', label: 'ChatGPT 订阅' },
                ]}
              />
              <p className="text-[12px] text-[var(--text-tertiary)]">
                密钥将加密保存于 Windows 凭据管理器，稍后可在「设置 → AI 智能」中填写密钥与配置 TypeSafe Jev 视觉定位。
              </p>
            </div>
          )}

          {step === 4 && (
            <div className="max-w-[560px] mx-auto w-full flex flex-col gap-4">
              <div className="flex items-center gap-2 text-[var(--accent)]">
                <Palette size={18} />
                <span className="text-[12px] font-semibold">第 4 步 · 画廊外观</span>
              </div>
              <h2 className="text-[18px] font-semibold text-[var(--text-primary)]">
                选择最舒适的画廊光影氛围
              </h2>
              <SegmentedControl<ThemeMode>
                value={themeMode}
                onChange={(m) => void setThemeMode(m)}
                ariaLabel="引导主题模式"
                options={[
                  { value: 'system', label: '跟随 Windows 系统' },
                  { value: 'light', label: '暖中性浅色画廊' },
                  { value: 'dark', label: '沉静深色画廊' },
                ]}
              />
            </div>
          )}

          {step === 5 && (
            <div className="flex flex-col items-center text-center gap-3.5 max-w-[460px] mx-auto">
              <CheckCircle2 size={44} className="text-[var(--accent)]" />
              <h2 className="text-[20px] font-semibold text-[var(--text-primary)]">
                一切准备就绪
              </h2>
              <p className="text-[13px] text-[var(--text-secondary)]">
                随时按 <kbd className="px-1.5 py-0.5 rounded bg-[var(--bg-subtle)] font-mono text-[11px]">Ctrl+,</kbd>{' '}
                打开 9 页设置中心微调云同步、AI 供应商或外部 Agent MCP 权限。
              </p>
              <Button
                variant="secondary"
                size="sm"
                onClick={() => {
                  completeOnboarding();
                  openSettings('sync');
                }}
              >
                前往设置中心详细配置
              </Button>
            </div>
          )}
        </div>

        {/* Footer Actions */}
        <footer className="px-6 py-3.5 border-t border-[var(--border-hairline)] flex items-center justify-between">
          <div>
            {step > 0 && (
              <Button
                variant="secondary"
                size="sm"
                onClick={() => setStep((step - 1) as OnboardingStep)}
              >
                <ArrowLeft size={14} />
                上一步
              </Button>
            )}
          </div>
          <div className="flex items-center gap-2">
            {step < 5 && (
              <Button variant="ghost" size="sm" onClick={next}>
                跳过此步
              </Button>
            )}
            <Button variant="primary" size="sm" onClick={next}>
              {step === 5 ? '开始使用 Charkle' : '下一步'}
              {step < 5 && <ArrowRight size={14} />}
            </Button>
          </div>
        </footer>
      </div>
    </div>
  );
};
