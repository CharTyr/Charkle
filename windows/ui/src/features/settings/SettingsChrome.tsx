import React, { useState } from 'react';
import { AlertCircle, CheckCircle2, ChevronRight, Sparkles, X } from 'lucide-react';
import { ModalShell, type ModalWidth } from '../../design-system';
import type { DriveSyncConfig, DriveTransportMode, WireDate } from '../../types/domain';
import { wireDateToMs } from '../../types/domain';

/**
 * Calibrated Settings UI Chrome mirroring macOS `Sources/CharkleApp/Views/Settings/SettingsChrome.swift` 1:1:
 * - External quiet section labels above crisp 12px-radius hairline cards
 * - Clean `SettingsRow` + inset `SettingsCardDivider`
 * - Smooth pill `SettingsSwitch` (never raw HTML checkboxes, full reduced-motion safety)
 * - Monochrome high-contrast primary / subtle secondary / soft destructive buttons
 * - 5-layer tactile `CharkleSkeuoButton` mirroring `CharkleSkeuoButtonStyle`
 * - Full-row `InlineGuideDisclosure` & `SettingsDisclosureGroup` + numbered `SettingsGuideStep`
 * - `SettingsCodeSnippet`, `SettingsFeedbackBanner`, `ChatGPTBrandMark`, and `SettingsSubModal`
 */

export const GDIRECT_TUTORIAL_URL =
  'https://github.com/mizorewww/gdirect/blob/main/docs/configuration/google-cloud.md';
export const GEMINI_KEY_URL = 'https://aistudio.google.com/apikey';
export const TYPESAFE_HOME_URL = 'https://typesafe.ai';
export const CHATGPT_USAGE_URL = 'https://chatgpt.com/settings/usage';

export function formatBytes(bytes: number): string {
  if (!Number.isFinite(bytes) || bytes <= 0) return '0 B';
  const units = ['B', 'KB', 'MB', 'GB', 'TB'];
  let val = bytes;
  let idx = 0;
  while (val >= 1024 && idx < units.length - 1) {
    val /= 1024;
    idx += 1;
  }
  return `${val.toFixed(idx === 0 ? 0 : 1)} ${units[idx]}`;
}

export function formatTokenCount(count: number): string {
  if (!Number.isFinite(count) || count <= 0) return '0';
  if (count >= 1_000_000) return `${(count / 1_000_000).toFixed(2)}M`;
  if (count >= 1_000) return `${(count / 1_000).toFixed(1)}K`;
  return String(Math.round(count));
}

export function relativeTimeText(value: WireDate | null | undefined): string {
  const ms = wireDateToMs(value);
  if (!ms) return '刚刚';
  const elapsedSec = Math.max(0, (Date.now() - ms) / 1000);
  if (elapsedSec < 15) return '刚刚';
  if (elapsedSec < 60) return `${Math.floor(elapsedSec)} 秒前`;
  if (elapsedSec < 3600) return `${Math.floor(elapsedSec / 60)} 分钟前`;
  if (elapsedSec < 86400) return `${Math.floor(elapsedSec / 3600)} 小时前`;
  const d = new Date(ms);
  const pad = (n: number) => String(n).padStart(2, '0');
  return `${pad(d.getMonth() + 1)}-${pad(d.getDate())} ${pad(d.getHours())}:${pad(d.getMinutes())}`;
}

export function isValidHttpUrl(raw: string | null | undefined): boolean {
  const trimmed = (raw ?? '').trim();
  if (!trimmed) return false;
  try {
    const parsed = new URL(trimmed);
    return (parsed.protocol === 'http:' || parsed.protocol === 'https:') && parsed.hostname.length > 0;
  } catch {
    return false;
  }
}

export function resolveSharedFolderID(raw: string | null | undefined): string | null {
  const trimmed = (raw ?? '').trim();
  if (!trimmed) return null;
  const folderMatch = trimmed.match(/\/folders\/([a-zA-Z0-9_-]{10,})/);
  if (folderMatch) return folderMatch[1];
  const idParamMatch = trimmed.match(/[?&]id=([a-zA-Z0-9_-]{10,})/);
  if (idParamMatch) return idParamMatch[1];
  if (/^[a-zA-Z0-9_-]{15,}$/.test(trimmed)) return trimmed;
  return null;
}

export function storageModeHeadline(mode: DriveTransportMode): string {
  switch (mode) {
    case 'localOnly':
      return '纯本地文件夹';
    case 'directAPIWithGDirect':
      return 'Google Drive 云端直连';
    case 'gdirectMount':
      return 'Google Drive（本地挂载盘）';
    case 'webDAV':
      return 'WebDAV 云盘';
  }
}

export function activeStorageLocationSummary(
  cfg: DriveSyncConfig | null | undefined,
  fallbackDataDir?: string | null,
): string {
  if (!cfg) return fallbackDataDir || '默认本机素材库目录';
  switch (cfg.mode) {
    case 'localOnly':
      return cfg.localLibraryPath.trim() || fallbackDataDir || '默认本机素材库目录';
    case 'webDAV': {
      const urlStr = cfg.webDAVServerURL.trim();
      let host = urlStr;
      try {
        host = new URL(urlStr).host || urlStr;
      } catch {
        // keep raw host
      }
      const remote = cfg.webDAVRemotePath.trim() || '/Charkle';
      return host ? `${host}${remote.startsWith('/') ? remote : `/${remote}`}` : '尚未配置 WebDAV 服务器';
    }
    case 'gdirectMount':
      return cfg.mountPath.trim() || 'G:\\';
    case 'directAPIWithGDirect': {
      const sharedId = resolveSharedFolderID(cfg.sharedFolderURLOrID);
      if (sharedId) {
        return `Google Drive 共享目录（${sharedId.slice(0, 12)}…）`;
      }
      const root = cfg.rootFolderName.trim() || 'Charkle';
      return `Google Drive / ${root}`;
    }
  }
}

export const SettingsSection: React.FC<{
  title: string;
  caption?: string;
  action?: React.ReactNode;
  className?: string;
  children: React.ReactNode;
}> = ({ title, caption, action, className = '', children }) => (
  <section className={`flex flex-col gap-2 ${className}`}>
    <div className="px-0.5 flex items-baseline justify-between gap-2">
      <div className="flex items-baseline gap-2 min-w-0">
        <h3 className="text-[11.5px] font-medium text-[var(--settings-label)]">{title}</h3>
        {caption && (
          <span className="text-[11px] text-[var(--settings-label)]/80 truncate">{caption}</span>
        )}
      </div>
      {action && <div className="shrink-0">{action}</div>}
    </div>
    <div className="rounded-[12px] bg-[var(--settings-card)] border border-[var(--settings-border)] overflow-hidden">
      {children}
    </div>
  </section>
);

export const SettingsCardDivider: React.FC = () => (
  <div className="mx-4 h-px bg-[var(--settings-divider)]" />
);

export const SettingsRow: React.FC<{
  title: React.ReactNode;
  subtitle?: React.ReactNode;
  subtitleTone?: 'default' | 'positive' | 'warning' | 'destructive';
  disabled?: boolean;
  children?: React.ReactNode;
}> = ({ title, subtitle, subtitleTone = 'default', disabled = false, children }) => {
  const subColor =
    subtitleTone === 'positive'
      ? 'text-[var(--settings-positive)]'
      : subtitleTone === 'warning'
        ? 'text-[var(--settings-warning)]'
        : subtitleTone === 'destructive'
          ? 'text-[var(--settings-destructive)]'
          : 'text-[var(--text-secondary)]';

  return (
    <div
      className={[
        'px-4 py-[13px] flex items-center justify-between gap-3.5',
        disabled ? 'opacity-55' : '',
      ].join(' ')}
    >
      <div className="min-w-0 flex-1 flex flex-col gap-0.5">
        <div className="text-[13px] font-medium text-[var(--text-primary)] leading-snug">
          {title}
        </div>
        {subtitle && (
          <div className={`text-[11.5px] leading-relaxed ${subColor}`}>{subtitle}</div>
        )}
      </div>
      {children != null && <div className="shrink-0 flex items-center gap-2">{children}</div>}
    </div>
  );
};

export const SettingsSwitch: React.FC<{
  checked: boolean;
  onChange: (checked: boolean) => void;
  ariaLabel: string;
  disabled?: boolean;
}> = ({ checked, onChange, ariaLabel, disabled = false }) => (
  <button
    type="button"
    role="switch"
    aria-checked={checked}
    aria-label={ariaLabel}
    disabled={disabled}
    onClick={() => {
      if (!disabled) onChange(!checked);
    }}
    className={[
      'relative inline-flex h-[20px] w-[36px] shrink-0 items-center rounded-full p-[2px] cursor-pointer transition-colors duration-150 motion-reduce:transition-none',
      checked ? 'bg-[var(--accent)]' : 'bg-black/15 dark:bg-white/18',
      disabled ? 'opacity-45 cursor-not-allowed' : '',
    ].join(' ')}
  >
    <span
      style={{
        transform: checked ? 'translate3d(16px, 0, 0)' : 'translate3d(0, 0, 0)',
        transition: 'transform 180ms var(--ease-out-strong)',
      }}
      className="block h-[16px] w-[16px] rounded-full bg-white shadow-[0_1px_3px_rgba(0,0,0,0.28)] motion-reduce:transition-none"
    />
  </button>
);

export const SettingsButton: React.FC<{
  variant?: 'primary' | 'secondary' | 'destructive';
  disabled?: boolean;
  loading?: boolean;
  onClick?: () => void;
  type?: 'button' | 'submit';
  title?: string;
  className?: string;
  'data-testid'?: string;
  children: React.ReactNode;
}> = ({
  variant = 'secondary',
  disabled = false,
  loading = false,
  onClick,
  type = 'button',
  title,
  className = '',
  'data-testid': dataTestId,
  children,
}) => {
  const styles =
    variant === 'primary'
      ? 'bg-[#18191D] text-white hover:bg-[#2B2D33] dark:bg-white dark:text-[#111215] dark:hover:bg-white/90 font-semibold'
      : variant === 'destructive'
        ? 'bg-[var(--settings-destructive)]/10 text-[var(--settings-destructive)] border border-[var(--settings-destructive)]/25 hover:bg-[var(--settings-destructive)]/16 font-medium'
        : 'bg-black/[0.045] hover:bg-black/[0.08] dark:bg-white/[0.075] dark:hover:bg-white/[0.12] text-[var(--text-primary)] border border-[var(--settings-border)] font-medium';

  return (
    <button
      type={type}
      disabled={disabled || loading}
      onClick={onClick}
      title={title}
      data-testid={dataTestId}
      className={[
        'charkle-pressable h-[30px] px-3 rounded-[8px] text-[12px] inline-flex items-center justify-center gap-1.5 cursor-pointer whitespace-nowrap disabled:opacity-40 disabled:cursor-not-allowed transition-colors duration-150 motion-reduce:transition-none',
        styles,
        className,
      ].join(' ')}
    >
      {children}
    </button>
  );
};

/**
 * 1:1 port of macOS `CharkleSkeuoButtonStyle`:
 * Calm top-lit 5-layer tactile keycap primary CTA used for Onboarding primary actions.
 */
export const CharkleSkeuoButton: React.FC<{
  disabled?: boolean;
  onClick?: () => void;
  title?: string;
  className?: string;
  children: React.ReactNode;
}> = ({ disabled = false, onClick, title, className = '', children }) => (
  <button
    type="button"
    disabled={disabled}
    onClick={onClick}
    title={title}
    className={[
      'relative h-[36px] px-4 rounded-[10px] text-[13px] font-semibold text-white inline-flex items-center justify-center gap-1.5 whitespace-nowrap cursor-pointer select-none',
      'bg-gradient-to-b from-[#404859] to-[#273042] hover:from-[#4A5366] hover:to-[#2F394D]',
      'dark:from-[#414B60] dark:to-[#283144] dark:hover:from-[#4D5870] dark:hover:to-[#313A4D]',
      'border border-[#12161F] dark:border-[#151923]',
      'shadow-[inset_0_1px_0_rgba(255,255,255,0.20),inset_0_-1px_0_rgba(0,0,0,0.28),0_3px_8px_rgba(18,22,31,0.26),0_1px_2px_rgba(0,0,0,0.18)]',
      'active:translate-y-[1px] active:shadow-[inset_0_1px_2px_rgba(0,0,0,0.34),0_1px_2px_rgba(0,0,0,0.18)]',
      'disabled:opacity-45 disabled:cursor-not-allowed',
      'transition-[transform,opacity,box-shadow,background-color] duration-150 ease-[var(--ease-out)] motion-reduce:transition-none motion-reduce:active:translate-y-0',
      className,
    ].join(' ')}
  >
    {children}
  </button>
);

export const SettingsStatusBadge: React.FC<{
  text: string;
  tone?: 'positive' | 'warning' | 'destructive' | 'neutral';
}> = ({ text, tone = 'neutral' }) => {
  const colorVar =
    tone === 'positive'
      ? 'var(--settings-positive)'
      : tone === 'warning'
        ? 'var(--settings-warning)'
        : tone === 'destructive'
          ? 'var(--settings-destructive)'
          : 'var(--text-secondary)';
  return (
    <span
      style={{
        color: colorVar,
        backgroundColor: `color-mix(in srgb, ${colorVar} 12%, transparent)`,
      }}
      className="inline-flex items-center gap-1.5 px-2 py-[2px] rounded-full text-[10.5px] font-medium shrink-0"
    >
      <span
        style={{ backgroundColor: colorVar }}
        className="w-1.5 h-1.5 rounded-full shrink-0"
      />
      <span>{text}</span>
    </span>
  );
};

export const InlineGuideDisclosure: React.FC<{
  title: string;
  defaultExpanded?: boolean;
  children: React.ReactNode;
}> = ({ title, defaultExpanded = false, children }) => {
  const [expanded, setExpanded] = useState(defaultExpanded);
  return (
    <div className="px-1.5 pb-2">
      <button
        type="button"
        onClick={() => setExpanded((v) => !v)}
        aria-expanded={expanded}
        className="w-full min-h-[28px] px-2.5 py-1.5 rounded-[8px] flex items-center gap-1.5 text-[11.5px] font-medium text-[var(--settings-label)] hover:text-[var(--text-primary)] hover:bg-[var(--settings-subtle)] cursor-pointer text-left transition-colors duration-150 motion-reduce:transition-none"
      >
        <span>{title}</span>
        <ChevronRight
          size={12}
          style={{
            transform: expanded ? 'rotate(90deg)' : 'rotate(0deg)',
            transition: 'transform 180ms var(--ease-out-strong)',
          }}
          className="shrink-0 motion-reduce:transition-none"
        />
      </button>
      {expanded && (
        <div className="charkle-reveal-top mx-2.5 mt-1 mb-1.5 p-3 rounded-[9px] bg-[var(--settings-subtle)] border border-[var(--settings-border)] flex flex-col gap-2">
          {children}
        </div>
      )}
    </div>
  );
};

/**
 * Full-row clickable disclosure mirroring macOS `CharkleDisclosureGroup` (never tiny chevron-only hit targets).
 */
export const SettingsDisclosureGroup: React.FC<{
  title: string;
  defaultExpanded?: boolean;
  children: React.ReactNode;
}> = ({ title, defaultExpanded = false, children }) => {
  const [expanded, setExpanded] = useState(defaultExpanded);
  return (
    <div className="flex flex-col">
      <button
        type="button"
        onClick={() => setExpanded((v) => !v)}
        aria-expanded={expanded}
        className="w-full min-h-[30px] px-2 py-1.5 -mx-2 rounded-[8px] flex items-center justify-between gap-2 text-[11.5px] font-medium text-[var(--text-secondary)] hover:text-[var(--text-primary)] hover:bg-[var(--settings-subtle)] cursor-pointer text-left transition-colors duration-150 motion-reduce:transition-none"
      >
        <span>{title}</span>
        <ChevronRight
          size={12}
          style={{
            transform: expanded ? 'rotate(90deg)' : 'rotate(0deg)',
            transition: 'transform 180ms var(--ease-out-strong)',
          }}
          className="shrink-0 motion-reduce:transition-none"
        />
      </button>
      {expanded && <div className="charkle-reveal-top pt-2 flex flex-col gap-2.5">{children}</div>}
    </div>
  );
};

export const SettingsGuideStep: React.FC<{
  number: string;
  title: string;
  detail?: string;
}> = ({ number, title, detail }) => (
  <div className="flex items-start gap-2.5">
    <span className="mt-0.5 h-[18px] w-[18px] rounded-full bg-black/80 text-white dark:bg-white/86 dark:text-black text-[10.5px] font-semibold inline-flex items-center justify-center shrink-0 charkle-tabular">
      {number}
    </span>
    <div className="min-w-0 flex flex-col gap-0.5">
      <div className="text-[12px] font-medium text-[var(--text-primary)]">{title}</div>
      {detail && (
        <div className="text-[11px] text-[var(--text-secondary)] leading-relaxed select-text">
          {detail}
        </div>
      )}
    </div>
  </div>
);

export const SettingsCodeSnippet: React.FC<{
  text: string;
  testId?: string;
}> = ({ text, testId }) => (
  <pre
    data-testid={testId}
    className="text-[10.5px] font-mono text-[var(--text-secondary)] select-text bg-black/[0.045] dark:bg-black/32 rounded-[7px] p-2.5 overflow-x-auto leading-relaxed whitespace-pre-wrap break-all"
  >
    {text}
  </pre>
);

export const SettingsInput: React.FC<React.InputHTMLAttributes<HTMLInputElement>> = ({
  className = '',
  ...props
}) => (
  <input
    {...props}
    className={[
      'h-[30px] px-2.5 rounded-[8px] bg-[var(--bg-inspector-field)] border border-[var(--settings-border)] text-[12px] text-[var(--text-primary)] placeholder:text-[var(--text-tertiary)] outline-none focus:border-[var(--accent)] disabled:opacity-50 transition-colors duration-150 motion-reduce:transition-none',
      className,
    ].join(' ')}
  />
);

export const SettingsFeedbackBanner: React.FC<{
  text: string;
  isError: boolean;
  onDismiss: () => void;
}> = ({ text, isError, onDismiss }) => {
  const toneVar = isError ? 'var(--settings-destructive)' : 'var(--settings-positive)';
  return (
    <div
      role="status"
      style={{
        backgroundColor: `color-mix(in srgb, ${toneVar} 11%, transparent)`,
        borderColor: `color-mix(in srgb, ${toneVar} 22%, transparent)`,
      }}
      className="charkle-reveal-top rounded-[9px] border px-3 py-2.5 flex items-center gap-2 text-[12px] font-medium text-[var(--text-primary)]"
    >
      {isError ? (
        <AlertCircle size={14} style={{ color: toneVar }} className="shrink-0" />
      ) : (
        <CheckCircle2 size={14} style={{ color: toneVar }} className="shrink-0" />
      )}
      <span className="flex-1 min-w-0 leading-snug">{text}</span>
      <button
        type="button"
        aria-label="关闭提示"
        onClick={onDismiss}
        className="h-5 w-5 rounded-full inline-flex items-center justify-center text-[var(--text-secondary)] hover:text-[var(--text-primary)] cursor-pointer shrink-0"
      >
        <X size={11} />
      </button>
    </div>
  );
};

export const ChatGPTBrandMark: React.FC<{ size?: number; className?: string }> = ({
  size = 16,
  className = '',
}) => {
  const [failed, setFailed] = useState(false);
  if (failed) {
    return <Sparkles size={Math.round(size * 0.85)} className={`shrink-0 ${className}`} />;
  }
  return (
    <span
      aria-hidden="true"
      className={`inline-block shrink-0 ${className}`}
      style={{
        width: size,
        height: size,
        backgroundColor: 'currentColor',
        WebkitMaskImage: "url('/icons/chatgpt-mark.svg')",
        maskImage: "url('/icons/chatgpt-mark.svg')",
        WebkitMaskRepeat: 'no-repeat',
        maskRepeat: 'no-repeat',
        WebkitMaskPosition: 'center',
        maskPosition: 'center',
        WebkitMaskSize: 'contain',
        maskSize: 'contain',
      }}
    >
      <img
        src="/icons/chatgpt-mark.svg"
        alt=""
        className="sr-only"
        onError={() => setFailed(true)}
      />
    </span>
  );
};

export const SettingsSubModal: React.FC<{
  open: boolean;
  onClose: () => void;
  title: React.ReactNode;
  subtitle?: React.ReactNode;
  headerRight?: React.ReactNode;
  footer?: React.ReactNode;
  width?: ModalWidth;
  children: React.ReactNode;
}> = ({ open, onClose, title, subtitle, headerRight, footer, width = 'md', children }) => (
  <ModalShell
    open={open}
    onClose={onClose}
    title={title}
    subtitle={subtitle}
    headerRight={headerRight}
    footer={footer}
    width={width}
    className="bg-[var(--settings-content)] border-[var(--settings-border)]"
  >
    <div className="flex flex-col gap-3.5">{children}</div>
  </ModalShell>
);
