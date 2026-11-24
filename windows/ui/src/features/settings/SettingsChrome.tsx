import React, { useEffect, useState } from 'react';
import {
  CheckmarkCircle16Filled,
  Dismiss16Regular,
  ErrorCircle16Filled,
  Sparkle16Regular,
} from '@fluentui/react-icons';
import {
  Button,
  CharkleDisclosureGroup,
  ModalShell,
  Switch,
  type ButtonSize,
  type FluentButtonVariant,
  type ModalWidth,
} from '../../design-system';
import type { DriveSyncConfig, DriveTransportMode, WireDate } from '../../types/domain';
import { wireDateToMs } from '../../types/domain';

/**
 * Fluent 2 Desktop Settings Chrome (fluent2-design-system.md §4 & §5):
 * - Crisp `SettingsCard` (`8px` radius, `--win-stroke-card`) & `SettingsSection`
 * - `SettingsRow` with optional leading Fluent icon slot + `SettingsCardDivider`
 * - `SettingsExpander`, `InlineGuideDisclosure`, & `SettingsDisclosureGroup` backed by
 *   `CharkleDisclosureGroup` (`@base-ui/react/collapsible` full-row hit target)
 * - Unified WinUI 3 `Switch` (`SettingsSwitch`) & Fluent `Button` (`SettingsButton`)
 * - `.win-input-elevation` (`SettingsInput`), InfoBar `SettingsFeedbackBanner`, & `SettingsSubModal`
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
    return (
      (parsed.protocol === 'http:' || parsed.protocol === 'https:') &&
      parsed.hostname.length > 0
    );
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
      return host
        ? `${host}${remote.startsWith('/') ? remote : `/${remote}`}`
        : '尚未配置 WebDAV 服务器';
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

export const SettingsCard: React.FC<{
  className?: string;
  'data-testid'?: string;
  children: React.ReactNode;
}> = ({ className = '', 'data-testid': dataTestId, children }) => (
  <div
    data-testid={dataTestId}
    className={[
      'rounded-[var(--win-radius-card)] bg-[var(--settings-card)] border border-[var(--win-stroke-card)] overflow-hidden',
      className,
    ]
      .filter(Boolean)
      .join(' ')}
  >
    {children}
  </div>
);

export const SettingsSection: React.FC<{
  title: string;
  caption?: string;
  action?: React.ReactNode;
  className?: string;
  'data-testid'?: string;
  children: React.ReactNode;
}> = ({ title, caption, action, className = '', 'data-testid': dataTestId, children }) => (
  <section data-testid={dataTestId} className={`flex flex-col gap-2 ${className}`}>
    <div className="px-0.5 flex items-baseline justify-between gap-2">
      <div className="flex items-baseline gap-2 min-w-0">
        <h3 className="text-[13px] leading-[18px] font-semibold text-[var(--text-primary)] charkle-heading">
          {title}
        </h3>
        {caption && (
          <span className="text-[12px] leading-[16px] text-[var(--text-tertiary)] truncate">
            {caption}
          </span>
        )}
      </div>
      {action && <div className="shrink-0">{action}</div>}
    </div>
    <SettingsCard>{children}</SettingsCard>
  </section>
);

export const SettingsCardDivider: React.FC = () => (
  <div className="mx-4 h-px bg-[var(--win-stroke-divider)]" />
);

export const SettingsRow: React.FC<{
  icon?: React.ReactNode;
  title: React.ReactNode;
  subtitle?: React.ReactNode;
  subtitleTone?: 'default' | 'positive' | 'warning' | 'destructive';
  disabled?: boolean;
  'data-testid'?: string;
  children?: React.ReactNode;
}> = ({
  icon,
  title,
  subtitle,
  subtitleTone = 'default',
  disabled = false,
  'data-testid': dataTestId,
  children,
}) => {
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
      data-testid={dataTestId}
      className={[
        'px-4 py-3.5 flex items-center justify-between gap-4',
        disabled ? 'opacity-55' : '',
      ].join(' ')}
    >
      <div className="min-w-0 flex-1 flex items-center gap-3">
        {icon && (
          <span className="shrink-0 w-5 h-5 inline-flex items-center justify-center text-[var(--text-secondary)]">
            {icon}
          </span>
        )}
        <div className="min-w-0 flex-1 flex flex-col gap-0.5">
          <div className="text-[13px] leading-[18px] font-medium text-[var(--text-primary)]">
            {title}
          </div>
          {subtitle && (
            <div className={`text-[12px] leading-[16px] ${subColor}`}>{subtitle}</div>
          )}
        </div>
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
  id?: string;
  'data-testid'?: string;
}> = ({ checked, onChange, ariaLabel, disabled = false, id, 'data-testid': dataTestId }) => (
  <Switch
    id={id}
    checked={checked}
    onCheckedChange={onChange}
    ariaLabel={ariaLabel}
    disabled={disabled}
    data-testid={dataTestId}
  />
);

export type SettingsButtonVariant =
  | FluentButtonVariant
  | 'primary'
  | 'secondary'
  | 'destructive';

function resolveSettingsButtonVariant(variant: SettingsButtonVariant): FluentButtonVariant {
  switch (variant) {
    case 'primary':
      return 'accent';
    case 'secondary':
      return 'standard';
    case 'destructive':
      return 'danger';
    default:
      return variant;
  }
}

export const SettingsButton: React.FC<{
  variant?: SettingsButtonVariant;
  size?: ButtonSize;
  disabled?: boolean;
  loading?: boolean;
  onClick?: () => void;
  type?: 'button' | 'submit';
  title?: string;
  className?: string;
  'data-testid'?: string;
  children: React.ReactNode;
}> = ({
  variant = 'standard',
  size = 'sm',
  disabled = false,
  loading = false,
  onClick,
  type = 'button',
  title,
  className = '',
  'data-testid': dataTestId,
  children,
}) => (
  <Button
    variant={resolveSettingsButtonVariant(variant)}
    size={size}
    type={type}
    disabled={disabled}
    loading={loading}
    onClick={onClick}
    title={title}
    data-testid={dataTestId}
    className={className}
  >
    {children}
  </Button>
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
      className="inline-flex items-center gap-1.5 px-2 py-[2px] rounded-full text-[11px] leading-[14px] font-medium shrink-0"
    >
      <span
        style={{ backgroundColor: colorVar }}
        className="w-1.5 h-1.5 rounded-full shrink-0"
      />
      <span>{text}</span>
    </span>
  );
};

/**
 * Fluent 2 `SettingsExpander` built on `CharkleDisclosureGroup` (`@base-ui/react/collapsible`)
 * with full-row clickable hit target and smooth height/opacity reveal.
 */
export const SettingsExpander: React.FC<{
  title: React.ReactNode;
  subtitle?: React.ReactNode;
  icon?: React.ReactNode;
  trailing?: React.ReactNode;
  defaultExpanded?: boolean;
  standalone?: boolean;
  className?: string;
  children: React.ReactNode;
}> = ({
  title,
  subtitle,
  icon,
  trailing,
  defaultExpanded = false,
  standalone = false,
  className = '',
  children,
}) => {
  const body = (
    <CharkleDisclosureGroup
      defaultExpanded={defaultExpanded}
      trailing={trailing}
      className={standalone ? '' : 'px-4 py-1.5'}
      headerClassName={
        standalone
          ? 'mx-0 px-4 py-3 min-h-[44px] rounded-none'
          : 'mx-0 px-1 py-1.5 min-h-[34px] text-[12px] font-medium text-[var(--text-secondary)] hover:text-[var(--text-primary)]'
      }
      contentClassName={
        standalone
          ? 'border-t border-[var(--win-stroke-divider)]'
          : ''
      }
      label={
        <span className="flex items-center gap-2.5 min-w-0">
          {icon && (
            <span className="shrink-0 w-4 h-4 inline-flex items-center justify-center text-[var(--text-secondary)]">
              {icon}
            </span>
          )}
          <span className="min-w-0 flex flex-col">
            <span className="text-[12.5px] leading-[18px] font-medium text-[var(--text-primary)] truncate">
              {title}
            </span>
            {subtitle && (
              <span className="text-[12px] leading-[16px] text-[var(--text-secondary)] truncate">
                {subtitle}
              </span>
            )}
          </span>
        </span>
      }
    >
      <div
        className={
          standalone
            ? 'px-4 py-3 flex flex-col gap-2.5 bg-[var(--settings-subtle)]'
            : 'pt-1.5 pb-2.5 flex flex-col gap-2.5'
        }
      >
        {children}
      </div>
    </CharkleDisclosureGroup>
  );

  if (standalone) {
    return <SettingsCard className={className}>{body}</SettingsCard>;
  }
  return <div className={className}>{body}</div>;
};

export const InlineGuideDisclosure: React.FC<{
  title: string;
  defaultExpanded?: boolean;
  children: React.ReactNode;
}> = ({ title, defaultExpanded = false, children }) => (
  <div className="px-2 pb-2">
    <CharkleDisclosureGroup
      defaultExpanded={defaultExpanded}
      headerClassName="mx-0 px-2.5 py-1.5 min-h-[32px] text-[12px] leading-[16px] font-medium text-[var(--text-secondary)] hover:text-[var(--text-primary)]"
      label={<span className="truncate">{title}</span>}
    >
      <div className="mx-2 mt-1 mb-1 p-3 rounded-[var(--win-radius-control)] bg-[var(--settings-subtle)] border border-[var(--win-stroke-divider)] flex flex-col gap-2.5">
        {children}
      </div>
    </CharkleDisclosureGroup>
  </div>
);

/**
 * Full-row clickable disclosure backed by `CharkleDisclosureGroup` (`@base-ui/react/collapsible`).
 */
export const SettingsDisclosureGroup: React.FC<{
  title: string;
  defaultExpanded?: boolean;
  children: React.ReactNode;
}> = ({ title, defaultExpanded = false, children }) => (
  <CharkleDisclosureGroup
    defaultExpanded={defaultExpanded}
    headerClassName="mx-0 px-2 py-1.5 min-h-[32px] text-[12px] leading-[16px] font-medium text-[var(--text-secondary)] hover:text-[var(--text-primary)]"
    label={<span className="truncate">{title}</span>}
  >
    <div className="pt-2 flex flex-col gap-2.5">{children}</div>
  </CharkleDisclosureGroup>
);

export const SettingsGuideStep: React.FC<{
  number: string;
  title: string;
  detail?: string;
}> = ({ number, title, detail }) => (
  <div className="flex items-start gap-2.5">
    <span className="mt-0.5 h-[18px] w-[18px] rounded-full bg-[var(--accent-soft)] text-[var(--accent)] text-[11px] font-semibold inline-flex items-center justify-center shrink-0 charkle-tabular">
      {number}
    </span>
    <div className="min-w-0 flex flex-col gap-0.5">
      <div className="text-[12.5px] leading-[18px] font-medium text-[var(--text-primary)]">
        {title}
      </div>
      {detail && (
        <div className="text-[12px] leading-[16px] text-[var(--text-secondary)] select-text">
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
    className="text-[11px] leading-relaxed charkle-mono text-[var(--text-secondary)] select-text bg-[var(--bg-subtle)]/80 border border-[var(--win-stroke-divider)] rounded-[var(--win-radius-control)] p-2.5 overflow-x-auto whitespace-pre-wrap break-all"
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
      'win-input-elevation h-8 px-2.5 rounded-[var(--win-radius-control)] text-[13px] leading-[18px] text-[var(--text-primary)] placeholder:text-[var(--text-tertiary)] outline-none disabled:opacity-50',
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
        backgroundColor: `color-mix(in srgb, ${toneVar} 10%, transparent)`,
        borderColor: `color-mix(in srgb, ${toneVar} 24%, transparent)`,
      }}
      className="charkle-reveal-top rounded-[var(--win-radius-card)] border px-3.5 py-2.5 flex items-center gap-2.5 text-[12.5px] leading-[18px] font-medium text-[var(--text-primary)]"
    >
      {isError ? (
        <ErrorCircle16Filled style={{ color: toneVar }} className="w-4 h-4 shrink-0" />
      ) : (
        <CheckmarkCircle16Filled style={{ color: toneVar }} className="w-4 h-4 shrink-0" />
      )}
      <span className="flex-1 min-w-0 leading-snug">{text}</span>
      <button
        type="button"
        aria-label="关闭提示"
        onClick={onDismiss}
        className="charkle-pressable h-6 w-6 rounded-[var(--win-radius-control)] inline-flex items-center justify-center text-[var(--text-secondary)] hover:text-[var(--text-primary)] hover:bg-[var(--win-subtle-hover)] cursor-pointer shrink-0 focus-visible:outline-2 focus-visible:outline-[var(--accent)]"
      >
        <Dismiss16Regular className="w-3.5 h-3.5" />
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
    return (
      <Sparkle16Regular
        style={{ width: Math.round(size * 0.9), height: Math.round(size * 0.9) }}
        className={`shrink-0 ${className}`}
      />
    );
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
}> = ({ open, onClose, title, subtitle, headerRight, footer, width = 'md', children }) => {
  // Ensure synthetic `window` Escape events (in addition to Base UI's `document` handler)
  // close ONLY the top-most sub-modal cleanly without closing the parent Settings overlay.
  useEffect(() => {
    if (!open) return;
    const onKeyDown = (e: KeyboardEvent) => {
      if (e.key === 'Escape' && !e.defaultPrevented) {
        if (document.querySelector('[data-charkle-popover-open="true"]')) return;
        e.preventDefault();
        e.stopPropagation();
        onClose();
      }
    };
    window.addEventListener('keydown', onKeyDown, true);
    return () => window.removeEventListener('keydown', onKeyDown, true);
  }, [open, onClose]);

  return (
    <ModalShell
      open={open}
      onClose={onClose}
      title={title}
      subtitle={subtitle}
      headerRight={headerRight}
      footer={footer}
      width={width}
      className="bg-[var(--settings-content)] border-[var(--win-stroke-flyout)]"
    >
      <div data-settings-submodal-open="true" className="flex flex-col gap-3.5">
        {children}
      </div>
    </ModalShell>
  );
};
