import React from 'react';

export const SettingsHeader: React.FC<{ title: string; subtitle: string }> = ({
  title,
  subtitle,
}) => (
  <div className="mb-1">
    <h3 className="text-[16px] font-semibold tracking-[-0.015em] text-[var(--text-primary)]">
      {title}
    </h3>
    <p className="text-[12px] text-[var(--text-secondary)] mt-0.5 leading-relaxed">{subtitle}</p>
  </div>
);

export const SettingsCard: React.FC<{
  title?: string;
  badge?: React.ReactNode;
  children: React.ReactNode;
  className?: string;
}> = ({ title, badge, children, className = '' }) => (
  <section
    className={[
      'rounded-[var(--radius-settings-outer)] bg-[var(--bg-elevated)] border border-[var(--border-hairline)] overflow-hidden',
      className,
    ].join(' ')}
  >
    {(title || badge) && (
      <div className="px-4 py-2.5 border-b border-[var(--border-hairline)] flex items-center justify-between gap-2 bg-[var(--bg-gallery)]/45">
        {title && (
          <h4 className="text-[12.5px] font-semibold text-[var(--text-primary)]">{title}</h4>
        )}
        {badge}
      </div>
    )}
    <div className="p-4 flex flex-col gap-3.5">{children}</div>
  </section>
);

export const SettingsRow: React.FC<{
  title: string;
  subtitle?: string;
  children: React.ReactNode;
}> = ({ title, subtitle, children }) => (
  <div className="flex flex-wrap items-center justify-between gap-3">
    <div className="min-w-0 flex-1">
      <div className="text-[13px] font-medium text-[var(--text-primary)]">{title}</div>
      {subtitle && (
        <div className="text-[11.5px] text-[var(--text-secondary)] mt-0.5 leading-snug">
          {subtitle}
        </div>
      )}
    </div>
    <div className="shrink-0 flex items-center gap-2">{children}</div>
  </div>
);

export const SettingsDivider: React.FC = () => (
  <div className="border-t border-[var(--border-hairline)]" />
);

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
      'relative inline-flex h-5 w-9 shrink-0 items-center rounded-full transition-colors duration-150 cursor-pointer',
      'focus-visible:outline-2 focus-visible:outline-offset-2 focus-visible:outline-[var(--accent)]',
      'disabled:opacity-45 disabled:cursor-not-allowed',
      checked ? 'bg-[var(--accent)]' : 'bg-[var(--border-strong)]',
    ].join(' ')}
  >
    <span
      className="inline-block h-3.5 w-3.5 rounded-full bg-white shadow-xs transition-transform duration-200"
      style={{
        transitionTimingFunction: 'var(--ease-overshoot)',
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
      'h-8.5 px-3 rounded-[var(--radius-settings-inner)] bg-[var(--bg-subtle)] border border-[var(--border-hairline)]',
      'text-[12.5px] text-[var(--text-primary)] placeholder:text-[var(--text-tertiary)]',
      'outline-none focus:border-[var(--accent)] disabled:opacity-50',
      className,
    ].join(' ')}
  />
);
