import React, { useRef, useState } from 'react';
import { Check, ChevronDown, Loader2 } from 'lucide-react';
import { DisclosureGroup, Popover, SegmentedControl } from '../../design-system';

export const SETTINGS_LINKS = {
  googleOAuthGuide:
    'https://developers.google.com/workspace/guides/create-credentials',
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

// MARK: - Full-Row Clickable Inline Guide Disclosure

export const InlineGuideDisclosure: React.FC<{
  title: string;
  defaultOpen?: boolean;
  children: React.ReactNode;
}> = ({ title, defaultOpen = false, children }) => {
  const [expanded, setExpanded] = useState(defaultOpen);

  return (
    <div className="px-2 pb-2 pt-0.5">
      <DisclosureGroup
        open={expanded}
        onOpenChange={setExpanded}
        headerClassName="min-h-[28px] px-2.5 py-1.5"
        label={
          <span
            className={[
              'text-[11.5px] font-medium transition-colors duration-[var(--duration-press,120ms)] ease-[var(--ease-out)]',
              expanded
                ? 'text-[var(--text-primary)]/90'
                : 'text-[var(--settings-label,var(--text-secondary))] group-hover:text-[var(--text-primary)]/90',
            ].join(' ')}
          >
            {title}
          </span>
        }
      >
        <div className="px-2 pb-1.5">
          <div className="p-3 rounded-[var(--radius-settings-inner)] bg-[var(--settings-subtle,var(--bg-subtle))] border border-[var(--settings-border,var(--border-hairline))] flex flex-col gap-2.5">
            {children}
          </div>
        </div>
      </DisclosureGroup>
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
      'p-2.5 rounded-[var(--radius-settings-inner)] bg-black/[0.045] dark:bg-black/35 font-mono text-[10.5px] leading-relaxed text-[var(--text-secondary)] overflow-x-auto charkle-scroll select-all whitespace-pre-wrap charkle-wrap-anywhere',
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

export interface SettingsMenuOption {
  value: string;
  label: string;
  hint?: string;
}

export const SettingsMenuPicker: React.FC<{
  options: ReadonlyArray<SettingsMenuOption>;
  value: string;
  onChange: (next: string) => void;
  placeholder?: string;
  ariaLabel?: string;
  disabled?: boolean;
  mono?: boolean;
  className?: string;
}> = ({
  options,
  value,
  onChange,
  placeholder = '请选择',
  ariaLabel,
  disabled = false,
  mono = false,
  className = '',
}) => {
  const [open, setOpen] = useState(false);
  const triggerRef = useRef<HTMLButtonElement | null>(null);
  const activeOption = options.find((opt) => opt.value === value);

  return (
    <>
      <button
        ref={triggerRef}
        type="button"
        aria-label={ariaLabel}
        aria-haspopup="listbox"
        aria-expanded={open}
        disabled={disabled}
        onClick={() => setOpen((v) => !v)}
        className={[
          'charkle-pressable h-[32px] px-2.5 rounded-[8px] bg-[var(--settings-subtle,var(--bg-subtle))] border border-[var(--settings-border,var(--border-hairline))]',
          'inline-flex items-center justify-between gap-2 text-[12px] text-[var(--text-primary)] cursor-pointer disabled:opacity-45 disabled:cursor-not-allowed',
          'hover:border-[var(--border-strong)] focus-visible:outline-2 focus-visible:outline-offset-1 focus-visible:outline-[var(--accent)]',
          'transition-colors duration-[var(--duration-press,120ms)] ease-[var(--ease-out)]',
          mono ? 'font-mono' : '',
          className,
        ].join(' ')}
      >
        <span className="truncate">{activeOption?.label || value || placeholder}</span>
        <ChevronDown
          size={13}
          className={[
            'text-[var(--text-tertiary)] shrink-0 transition-transform duration-[var(--duration-press,120ms)] ease-[var(--ease-out)]',
            open ? 'rotate-180' : '',
          ].join(' ')}
        />
      </button>

      <Popover
        open={open}
        onOpenChange={setOpen}
        anchorEl={triggerRef.current}
        placement="bottom-start"
        className="min-w-[220px] max-w-[360px] p-1.5"
      >
        <div
          role="listbox"
          aria-label={ariaLabel}
          className="max-h-[260px] overflow-y-auto charkle-scroll flex flex-col gap-0.5"
        >
          {options.map((opt) => {
            const selected = opt.value === value;
            return (
              <button
                key={opt.value}
                type="button"
                role="option"
                aria-selected={selected}
                onClick={() => {
                  onChange(opt.value);
                  setOpen(false);
                }}
                className={[
                  'charkle-pressable w-full px-2.5 py-1.5 rounded-[var(--radius-popover-inner)] flex items-center justify-between gap-2 text-left text-[12px] cursor-pointer',
                  selected
                    ? 'bg-[var(--accent-soft)]/60 text-[var(--accent)] font-medium'
                    : 'text-[var(--text-primary)] hover:bg-[var(--bg-subtle)]',
                ].join(' ')}
              >
                <div className="min-w-0 flex-1">
                  <div className={['truncate', mono ? 'font-mono text-[11.5px]' : ''].join(' ')}>
                    {opt.label}
                  </div>
                  {opt.hint && (
                    <div className="text-[10.5px] font-mono text-[var(--text-tertiary)] truncate">
                      {opt.hint}
                    </div>
                  )}
                </div>
                {selected && <Check size={13} className="shrink-0 text-[var(--accent)]" />}
              </button>
            );
          })}
        </div>
      </Popover>
    </>
  );
};

export function SettingsSegmented<T extends string>({
  options,
  value,
  onChange,
  fullWidth = false,
  disabled = false,
  ariaLabel,
  className = '',
}: {
  options: ReadonlyArray<{ id: T; label: string; icon?: React.ReactNode }>;
  value: T;
  onChange: (next: T) => void;
  fullWidth?: boolean;
  disabled?: boolean;
  ariaLabel?: string;
  className?: string;
}) {
  return (
    <SegmentedControl
      options={options}
      value={value}
      onChange={onChange}
      size="sm"
      fullWidth={fullWidth}
      disabled={disabled}
      ariaLabel={ariaLabel}
      className={className}
    />
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
