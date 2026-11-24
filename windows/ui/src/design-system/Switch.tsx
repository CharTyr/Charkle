import React from 'react';
import { Switch as BaseSwitch } from '@base-ui/react/switch';

export interface SwitchProps {
  checked: boolean;
  onCheckedChange?: (checked: boolean) => void;
  /** Convenience alias for `onCheckedChange`. */
  onChange?: (checked: boolean) => void;
  disabled?: boolean;
  readOnly?: boolean;
  id?: string;
  name?: string;
  size?: 'sm' | 'md';
  ariaLabel?: string;
  'aria-label'?: string;
  'aria-labelledby'?: string;
  className?: string;
  'data-testid'?: string;
}

/**
 * WinUI 3 Fluent 2 `ToggleSwitch` built on `@base-ui/react/switch`:
 * - 40x20px default geometry (34x18px `sm`)
 * - Outlined transparent off-state -> accent-filled on-state
 * - Tactile horizontal thumb stretch on active press
 */
export const Switch = React.forwardRef<HTMLElement, SwitchProps>(
  (
    {
      checked,
      onCheckedChange,
      onChange,
      disabled = false,
      readOnly = false,
      id,
      name,
      size = 'md',
      ariaLabel,
      'aria-label': ariaLabelAttr,
      'aria-labelledby': ariaLabelledBy,
      className = '',
      'data-testid': dataTestId,
    },
    ref,
  ) => (
    <BaseSwitch.Root
      ref={ref}
      render={<button type="button" />}
      nativeButton={true}
      id={id}
      name={name}
      checked={checked}
      disabled={disabled}
      readOnly={readOnly}
      aria-label={ariaLabelAttr ?? ariaLabel}
      aria-labelledby={ariaLabelledBy}
      data-size={size}
      data-testid={dataTestId}
      onCheckedChange={(next) => {
        onCheckedChange?.(next);
        onChange?.(next);
      }}
      className={[
        'win-switch focus-visible:outline-2 focus-visible:outline-offset-2 focus-visible:outline-[var(--accent)]',
        className,
      ]
        .filter(Boolean)
        .join(' ')}
    >
      <BaseSwitch.Thumb className="win-switch-thumb" />
    </BaseSwitch.Root>
  ),
);

Switch.displayName = 'Switch';

export const ToggleSwitch = Switch;
