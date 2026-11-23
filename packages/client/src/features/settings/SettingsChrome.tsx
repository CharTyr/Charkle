import React, { useState } from 'react';
import { ChevronRight, Loader2 } from 'lucide-react';

export const SETTINGS_LINKS = {
  googleOAuthGuide:
    'https://github.com/mizorewww/gdirect/blob/main/docs/configuration/google-cloud.md',
  geminiKey: 'https://aistudio.google.com/apikey',
  typeSafeHome: 'https://typesafe.ai',
} as const;

export type SettingsTone = 'default' | 'positive' | 'warning' | 'destructive';

const TONE_TEXT_CLASS: Record<SettingsTone, string> = {
  default: 'text-[var(--text-secondary)]',
  positive: 'text-[var(--settings-positive,var(--success))]',
  warning: 'text-[var(--settings-warning,var(--warning))]',
  destructive: 'text-[var(--settings-destructive,var(--danger))]',
};

// MARK: - External Section Header + Rounded Card Container

export const SettingsSection: React.FC<{
  title: string;
  caption?: string;
  children: React.ReactNode;
}> = ({ title, caption, children }) => (
  <section className="flex flex-col gap-2">
    <div className="flex flex-wrap items-baseline gap-2 px-0.5">
      <h4 className="text-[11.5px] font-medium text-[var(--settings-label,var(--text-secondary))]">
        {title}
      </h4>
      {caption && (
        <span className="text-[11px] text-[var(--settings-label,var(--text-tertiary))] opacity-80">
          {caption}
        </span>
      )}
    </div>
    <SettingsCard>{children}</SettingsCard>
  </section>
);

export const SettingsCard: React.FC<{
  children: React.ReactNode;
  className?: string;
}> = ({ children, className = '' }) => (
  <div
    className={[
      'rounded-[12px] bg-[var(--settings-card,var(--bg-elevated))] border border-[var(--settings-border,var(--border-hairline))] overflow-hidden',
      className,
    ].join(' ')}
  >
    {children}
  </div>
);

export const SettingsCardDivider: React.FC = () => (
  <div className="mx-4 border-t border-[var(--settings-divider,var(--border-hairline))]" />
);

// MARK: - Clean Row

export const SettingsRow: React.FC<{
  title: React.ReactNode;
  subtitle?: React.ReactNode;
  subtitleTone?: SettingsTone;
  children?: React.ReactNode;
  className?: string;
}> = ({ title, subtitle, subtitleTone = 'default', children, className = '' }) => (
  <div
    className={[
      'px-4 py-3 flex flex-wrap items-center justify-between gap-3.5',
      className,
    ].join(' ')}
  >
    <div className="min-w-0 flex-1 flex flex-col gap-0.5">
      <div className="text-[13px] font-medium text-[var(--text-primary)] leading-snug">
        {title}
      </div>
      {subtitle && (
        <div className={['text-[11.5px] leading-snug', TONE_TEXT_CLASS[subtitleTone]].join(' ')}>
          {subtitle}
        </div>
      )}
    </div>
    {children && <div className="shrink-0 flex items-center gap-2">{children}</div>}
  </div>
);

// MARK: - Quiet Inline Guide Disclosure (`如何… >`)

export const InlineGuideDisclosure: React.FC<{
  title: string;
  defaultOpen?: boolean;
  children: React.ReactNode;
}> = ({ title, defaultOpen = false, children }) => {
  const [expanded, setExpanded] = useState(defaultOpen);

  return (
    <div className="flex flex-col">
      <button
        type="button"
        aria-expanded={expanded}
        onClick={() => setExpanded((v) => !v)}
        className={[
          'group inline-flex items-center gap-1.5 self-start px-4 pt-0.5 text-[11.5px] font-medium cursor-pointer',
          'transition-colors duration-[var(--duration-press,120ms)] ease-[var(--ease-out)]',
          expanded
            ? 'pb-2.5 text-[var(--text-primary)]/85'
            : 'pb-3 text-[var(--settings-label,var(--text-secondary))] hover:text-[var(--text-primary)]/85',
        ].join(' ')}
      >
        <span>{title}</span>
        <ChevronRight
          size={11}
          strokeWidth={2.3}
          className="transition-transform"
          style={{
            transitionDuration: 'var(--duration-settle, 220ms)',
            transitionTimingFunction: 'var(--ease-out-strong, cubic-bezier(0.22, 1, 0.36, 1))',
            transform: expanded ? 'rotate(90deg)' : 'rotate(0deg)',
          }}
        />
      </button>

      {expanded && (
        <div className="px-4 pb-3.5">
          <div className="p-3 rounded-[9px] bg-[var(--settings-subtle,var(--bg-subtle))] border border-[var(--settings-border,var(--border-hairline))] flex flex-col gap-2.5">
            {children}
          </div>
        </div>
      )}
    </div>
  );
};

export const SettingsGuideStep: React.FC<{
  number: string | number;
  title: React.ReactNode;
  detail?: React.ReactNode;
}> = ({ number, title, detail }) => (
  <div className="flex items-start gap-2.5">
    <span className="mt-0.5 w-[18px] h-[18px] rounded-full bg-[#18191D]/80 dark:bg-white/85 text-white dark:text-[#111215] text-[10.5px] font-semibold inline-flex items-center justify-center shrink-0 tabular-nums">
      {number}
    </span>
    <div className="min-w-0 flex-1 flex flex-col gap-0.5">
      <div className="text-[12px] font-medium text-[var(--text-primary)] leading-snug">
        {title}
      </div>
      {detail && (
        <div className="text-[11px] text-[var(--text-secondary)] leading-relaxed select-text">
          {detail}
        </div>
      )}
    </div>
  </div>
);

// MARK: - Status Badge & Code Snippet

export type SettingsBadgeTone = 'positive' | 'warning' | 'destructive' | 'neutral';

const BADGE_STYLE: Record<SettingsBadgeTone, { bg: string; text: string; dot: string }> = {
  positive: {
    bg: 'bg-[var(--success-soft)]',
    text: 'text-[var(--settings-positive,var(--success))]',
    dot: 'bg-[var(--settings-positive,var(--success))]',
  },
  warning: {
    bg: 'bg-[var(--warning-soft)]',
    text: 'text-[var(--settings-warning,var(--warning))]',
    dot: 'bg-[var(--settings-warning,var(--warning))]',
  },
  destructive: {
    bg: 'bg-[var(--danger-soft)]',
    text: 'text-[var(--settings-destructive,var(--danger))]',
    dot: 'bg-[var(--settings-destructive,var(--danger))]',
  },
  neutral: {
    bg: 'bg-[var(--settings-subtle,var(--bg-subtle))]',
    text: 'text-[var(--text-secondary)]',
    dot: 'bg-[var(--text-tertiary)]',
  },
};

export const SettingsStatusBadge: React.FC<{
  text: string;
  tone?: SettingsBadgeTone;
}> = ({ text, tone = 'neutral' }) => {
  const s = BADGE_STYLE[tone];
  return (
    <span
      className={[
        'inline-flex items-center gap-1.5 px-2 py-0.5 rounded-full text-[10.5px] font-medium shrink-0',
        s.bg,
        s.text,
      ].join(' ')}
    >
      <span className={['w-1.5 h-1.5 rounded-full shrink-0', s.dot].join(' ')} />
      {text}
    </span>
  );
};

export const SettingsCodeSnippet: React.FC<{
  text: string;
  className?: string;
}> = ({ text, className = '' }) => (
  <pre
    className={[
      'p-2.5 rounded-[7px] bg-black/[0.045] dark:bg-black/35 font-mono text-[10.5px] leading-relaxed text-[var(--text-secondary)] overflow-x-auto charkle-scroll select-all whitespace-pre-wrap break-all',
      className,
    ].join(' ')}
  >
    {text}
  </pre>
);

// MARK: - Monochrome High-Contrast Settings Buttons

export interface SettingsButtonProps extends React.ButtonHTMLAttributes<HTMLButtonElement> {
  variant?: 'primary' | 'secondary' | 'destructive';
  loading?: boolean;
}

export const SettingsButton: React.FC<SettingsButtonProps> = ({
  variant = 'secondary',
  loading = false,
  disabled,
  className = '',
  children,
  type = 'button',
  ...rest
}) => {
  const variantClass =
    variant === 'primary'
      ? 'bg-[#18191D] text-white hover:bg-[#18191D]/90 dark:bg-white dark:text-[#111215] dark:hover:bg-white/90 font-semibold'
      : variant === 'destructive'
        ? 'bg-[var(--danger-soft)] text-[var(--settings-destructive,var(--danger))] border border-[var(--settings-destructive,var(--danger))]/25 hover:bg-[var(--settings-destructive,var(--danger))]/16 font-medium'
        : 'bg-black/[0.05] dark:bg-white/[0.08] text-[var(--text-primary)]/92 border border-black/[0.10] dark:border-white/[0.12] hover:bg-black/[0.085] dark:hover:bg-white/[0.13] font-medium';

  return (
    <button
      type={type}
      disabled={disabled || loading}
      className={[
        'charkle-pressable inline-flex items-center justify-center gap-1.5 h-[30px] px-3 rounded-[8px] text-[12px] whitespace-nowrap shrink-0 cursor-pointer',
        'transition-[background-color,border-color,color,opacity] duration-[var(--duration-press,120ms)] ease-[var(--ease-out)]',
        'focus-visible:outline-2 focus-visible:outline-offset-2 focus-visible:outline-[var(--accent)]',
        'disabled:opacity-40 disabled:cursor-not-allowed',
        variantClass,
        className,
      ].join(' ')}
      {...rest}
    >
      {loading && <Loader2 size={12} className="animate-spin shrink-0" />}
      {children}
    </button>
  );
};

// MARK: - Form Controls

export const SettingsSwitch: React.FC<{
  checked: boolean;
  disabled?: boolean;
  onChange: (checked: boolean) => void;
  ariaLabel: string;
}> = ({ checked, disabled = false, onChange, ariaLabel }) => (
  <button
    type="button"
    role="switch"
    aria-checked={checked}
    aria-label={ariaLabel}
    disabled={disabled}
    onClick={() => onChange(!checked)}
    className={[
      'relative inline-flex h-5 w-9 shrink-0 items-center rounded-full transition-colors duration-[var(--duration-press,120ms)] ease-[var(--ease-out)] cursor-pointer',
      'focus-visible:outline-2 focus-visible:outline-offset-2 focus-visible:outline-[var(--accent)]',
      'disabled:opacity-40 disabled:cursor-not-allowed',
      checked ? 'bg-[var(--accent)]' : 'bg-black/20 dark:bg-white/20',
    ].join(' ')}
  >
    <span
      className="inline-block h-3.5 w-3.5 rounded-full bg-white shadow-xs transition-transform"
      style={{
        transitionDuration: 'var(--duration-overshoot, 220ms)',
        transitionTimingFunction: 'var(--ease-overshoot, cubic-bezier(0.34, 1.56, 0.64, 1))',
        transform: checked ? 'translateX(18px)' : 'translateX(3px)',
      }}
    />
  </button>
);

export const SettingsInput: React.FC<React.InputHTMLAttributes<HTMLInputElement>> = ({
  className = '',
  ...rest
}) => (
  <input
    {...rest}
    className={[
      'h-[32px] px-2.5 rounded-[8px] bg-[var(--settings-subtle,var(--bg-subtle))] border border-[var(--settings-border,var(--border-hairline))]',
      'text-[12px] text-[var(--text-primary)] placeholder:text-[var(--text-tertiary)]',
      'outline-none focus:border-[var(--accent)] disabled:opacity-45',
      'transition-colors duration-[var(--duration-press,120ms)] ease-[var(--ease-out)]',
      className,
    ].join(' ')}
  />
);

export const SettingsSelect: React.FC<React.SelectHTMLAttributes<HTMLSelectElement>> = ({
  className = '',
  ...rest
}) => (
  <select
    {...rest}
    className={[
      'h-[32px] px-2.5 rounded-[8px] bg-[var(--settings-subtle,var(--bg-subtle))] border border-[var(--settings-border,var(--border-hairline))]',
      'text-[12px] text-[var(--text-primary)] outline-none focus:border-[var(--accent)] cursor-pointer disabled:opacity-45',
      'transition-colors duration-[var(--duration-press,120ms)] ease-[var(--ease-out)]',
      className,
    ].join(' ')}
  />
);

export function SettingsSegmented<T extends string>({
  options,
  value,
  onChange,
  disabled = false,
  ariaLabel,
  className = '',
}: {
  options: ReadonlyArray<{ id: T; label: string }>;
  value: T;
  onChange: (next: T) => void;
  disabled?: boolean;
  ariaLabel?: string;
  className?: string;
}) {
  return (
    <div
      role="radiogroup"
      aria-label={ariaLabel}
      className={[
        'inline-flex p-0.5 rounded-[8px] bg-[var(--settings-subtle,var(--bg-subtle))] border border-[var(--settings-border,var(--border-hairline))]',
        className,
      ].join(' ')}
    >
      {options.map((opt) => {
        const active = opt.id === value;
        return (
          <button
            key={opt.id}
            type="button"
            role="radio"
            aria-checked={active}
            disabled={disabled}
            onClick={() => onChange(opt.id)}
            className={[
              'px-2.5 py-1 rounded-[6px] text-[11.5px] font-medium whitespace-nowrap cursor-pointer disabled:opacity-45 disabled:cursor-not-allowed',
              'transition-[background-color,color,box-shadow] duration-[var(--duration-press,120ms)] ease-[var(--ease-out)]',
              active
                ? 'bg-[var(--settings-card,var(--bg-elevated))] text-[var(--text-primary)] shadow-xs'
                : 'text-[var(--text-secondary)] hover:text-[var(--text-primary)]',
            ].join(' ')}
          >
            {opt.label}
          </button>
        );
      })}
    </div>
  );
}

// MARK: - ChatGPT Brand Mark

export const ChatGPTBrandMark: React.FC<{ size?: number; className?: string }> = ({
  size = 15,
  className = '',
}) => (
  <span
    aria-hidden="true"
    className={['inline-block shrink-0 bg-current', className].join(' ')}
    style={{
      width: size,
      height: size,
      WebkitMaskImage: 'url(/icons/chatgpt-mark.svg)',
      maskImage: 'url(/icons/chatgpt-mark.svg)',
      WebkitMaskRepeat: 'no-repeat',
      maskRepeat: 'no-repeat',
      WebkitMaskPosition: 'center',
      maskPosition: 'center',
      WebkitMaskSize: 'contain',
      maskSize: 'contain',
    }}
  />
);
