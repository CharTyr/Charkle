import React, { useEffect, useMemo, useRef, useState } from 'react';
import { Select as BaseSelect } from '@base-ui/react/select';
import { ChevronDown16Regular, Search16Regular } from '@fluentui/react-icons';
import { Popover } from './Popover';

export interface SelectOption<T extends string> {
  value: T;
  label: string;
  subtitle?: string;
  depth?: number;
  icon?: React.ReactNode;
}

export interface CustomSelectProps<T extends string> {
  value: T;
  options: ReadonlyArray<SelectOption<T>>;
  onChange: (value: T) => void;
  placeholder?: string;
  searchableThreshold?: number;
  ariaLabel?: string;
  size?: 'xs' | 'sm';
  /** `'glassPill'` is retained only as a deprecated alias mapped to Fluent `'default'`. */
  variant?: 'default' | 'glassPill';
  /** Deprecated legacy prop retained for backwards compatibility during migration. */
  adaptGlass?: boolean;
  leadingIcon?: React.ReactNode;
  hideChevron?: boolean;
  disabled?: boolean;
  className?: string;
}

/**
 * Fluent 2 Desktop ComboBox / Select:
 * - Standard mode (< searchableThreshold): powered by `@base-ui/react/select`
 * - Searchable mode (>= 15 options by default): inline Fluent search input inside Acrylic Popover
 * - Selected row carries the WinUI 3 signature 3px left accent pill indicator
 */
export function CustomSelect<T extends string>({
  value,
  options,
  onChange,
  placeholder = '请选择',
  searchableThreshold = 15,
  ariaLabel,
  size = 'sm',
  leadingIcon,
  hideChevron = false,
  disabled = false,
  className = '',
}: CustomSelectProps<T>) {
  const selectedOption = useMemo(
    () => options.find((o) => o.value === value) ?? null,
    [options, value],
  );

  const showSearch = options.length >= searchableThreshold;

  const triggerClass = [
    'charkle-pressable win-control-elevation inline-flex items-center justify-between gap-1.5 min-w-0 cursor-pointer select-none whitespace-nowrap',
    'bg-[var(--win-control-fill)] hover:bg-[var(--win-control-fill-hover)] active:bg-[var(--win-control-fill-pressed)]',
    'text-[var(--text-primary)] rounded-[var(--win-radius-control)]',
    'focus-visible:outline-2 focus-visible:outline-offset-1 focus-visible:outline-[var(--accent)]',
    'disabled:opacity-45 disabled:cursor-not-allowed',
    size === 'xs' ? 'h-[26px] px-2.5 text-[12px] leading-[16px]' : 'h-8 px-3 text-[13px] leading-[18px]',
    className,
  ]
    .filter(Boolean)
    .join(' ');

  if (!showSearch) {
    return (
      <BaseSelect.Root<T>
        value={value}
        disabled={disabled}
        modal={false}
        onValueChange={(next) => {
          if (next !== null) onChange(next);
        }}
      >
        <BaseSelect.Trigger aria-label={ariaLabel} className={triggerClass}>
          <span className="inline-flex items-center gap-1.5 min-w-0 truncate">
            {leadingIcon}
            {selectedOption?.icon}
            <span className="truncate">{selectedOption ? selectedOption.label : placeholder}</span>
          </span>
          {!hideChevron && (
            <ChevronDown16Regular className="w-3.5 h-3.5 text-[var(--text-tertiary)] shrink-0" />
          )}
        </BaseSelect.Trigger>

        <BaseSelect.Portal>
          <BaseSelect.Positioner
            side="bottom"
            align="start"
            sideOffset={4}
            alignItemWithTrigger={false}
            collisionPadding={10}
            positionMethod="fixed"
            className="z-[140] outline-none"
          >
            <BaseSelect.Popup
              data-charkle-popover-open="true"
              onMouseDown={(e) => e.stopPropagation()}
              onPointerDown={(e) => e.stopPropagation()}
              onClick={(e) => e.stopPropagation()}
              className="win-acrylic win-flyout-popup min-w-[200px] max-w-[300px] p-1 rounded-[var(--win-radius-overlay)] outline-none select-none"
            >
              <BaseSelect.List className="max-h-[260px] overflow-y-auto charkle-scroll flex flex-col gap-0.5 outline-none">
                {options.map((opt) => {
                  const active = opt.value === value;
                  return (
                    <BaseSelect.Item
                      key={opt.value}
                      value={opt.value}
                      style={opt.depth ? { paddingLeft: 12 + opt.depth * 14 } : undefined}
                      className={[
                        'relative w-full min-h-[32px] flex items-center gap-2 pl-3 pr-2.5 py-1.5 text-left text-[13px] leading-[18px] cursor-pointer outline-none',
                        'rounded-[var(--win-radius-control)] transition-colors duration-[83ms] ease-[var(--win-ease-out)]',
                        active
                          ? 'bg-[var(--win-subtle-active)] text-[var(--text-primary)] font-medium'
                          : 'text-[var(--text-primary)] data-[highlighted]:bg-[var(--win-subtle-hover)]',
                      ].join(' ')}
                    >
                      <span
                        aria-hidden="true"
                        className={[
                          'absolute left-[2px] top-1/2 -translate-y-1/2 w-[3px] h-4 rounded-full bg-[var(--accent)] transition-opacity duration-[83ms]',
                          active ? 'opacity-100' : 'opacity-0',
                        ].join(' ')}
                      />
                      {opt.icon}
                      <BaseSelect.ItemText className="truncate flex-1 min-w-0">
                        {opt.label}
                      </BaseSelect.ItemText>
                      {opt.subtitle && (
                        <span className="text-[11px] text-[var(--text-tertiary)] shrink-0 charkle-tabular">
                          {opt.subtitle}
                        </span>
                      )}
                    </BaseSelect.Item>
                  );
                })}
              </BaseSelect.List>
            </BaseSelect.Popup>
          </BaseSelect.Positioner>
        </BaseSelect.Portal>
      </BaseSelect.Root>
    );
  }

  return (
    <SearchableFluentSelect
      value={value}
      options={options}
      selectedOption={selectedOption}
      onChange={onChange}
      placeholder={placeholder}
      ariaLabel={ariaLabel}
      leadingIcon={leadingIcon}
      hideChevron={hideChevron}
      disabled={disabled}
      triggerClass={triggerClass}
    />
  );
}

interface SearchableFluentSelectProps<T extends string> {
  value: T;
  options: ReadonlyArray<SelectOption<T>>;
  selectedOption: SelectOption<T> | null;
  onChange: (value: T) => void;
  placeholder: string;
  ariaLabel?: string;
  leadingIcon?: React.ReactNode;
  hideChevron: boolean;
  disabled: boolean;
  triggerClass: string;
}

function SearchableFluentSelect<T extends string>({
  value,
  options,
  selectedOption,
  onChange,
  placeholder,
  ariaLabel,
  leadingIcon,
  hideChevron,
  disabled,
  triggerClass,
}: SearchableFluentSelectProps<T>) {
  const triggerRef = useRef<HTMLButtonElement | null>(null);
  const listboxRef = useRef<HTMLDivElement | null>(null);
  const [open, setOpen] = useState(false);
  const [query, setQuery] = useState('');
  const [highlightedIndex, setHighlightedIndex] = useState(-1);

  const filtered = useMemo(() => {
    const q = query.trim().toLowerCase();
    if (!q) return options;
    return options.filter(
      (o) =>
        o.label.toLowerCase().includes(q) ||
        (o.subtitle && o.subtitle.toLowerCase().includes(q)),
    );
  }, [options, query]);

  useEffect(() => {
    if (!open) {
      setHighlightedIndex(-1);
      return;
    }
    const activeIdx = filtered.findIndex((o) => o.value === value);
    setHighlightedIndex(activeIdx >= 0 ? activeIdx : filtered.length > 0 ? 0 : -1);
  }, [open, filtered, value]);

  useEffect(() => {
    if (!open || highlightedIndex < 0) return;
    const container = listboxRef.current;
    const el = container?.querySelector<HTMLElement>(`[data-option-index="${highlightedIndex}"]`);
    el?.scrollIntoView?.({ block: 'nearest' });
  }, [open, highlightedIndex]);

  const commitOption = (optValue: T) => {
    onChange(optValue);
    setOpen(false);
    requestAnimationFrame(() => triggerRef.current?.focus({ preventScroll: true }));
  };

  const handleListKeyDown = (e: React.KeyboardEvent) => {
    if (filtered.length === 0) return;
    if (e.key === 'ArrowDown') {
      e.preventDefault();
      e.stopPropagation();
      setHighlightedIndex((i) => (i + 1) % filtered.length);
    } else if (e.key === 'ArrowUp') {
      e.preventDefault();
      e.stopPropagation();
      setHighlightedIndex((i) => (i <= 0 ? filtered.length - 1 : i - 1));
    } else if (e.key === 'Home') {
      e.preventDefault();
      e.stopPropagation();
      setHighlightedIndex(0);
    } else if (e.key === 'End') {
      e.preventDefault();
      e.stopPropagation();
      setHighlightedIndex(filtered.length - 1);
    } else if (e.key === 'Enter' && highlightedIndex >= 0 && highlightedIndex < filtered.length) {
      e.preventDefault();
      e.stopPropagation();
      commitOption(filtered[highlightedIndex].value);
    }
  };

  return (
    <>
      <button
        ref={triggerRef}
        type="button"
        disabled={disabled}
        aria-label={ariaLabel}
        aria-haspopup="listbox"
        aria-expanded={open}
        onClick={() => {
          setQuery('');
          setOpen((v) => !v);
        }}
        onKeyDown={(e) => {
          if (!open && (e.key === 'ArrowDown' || e.key === 'ArrowUp')) {
            e.preventDefault();
            setQuery('');
            setOpen(true);
          }
        }}
        className={triggerClass}
      >
        <span className="inline-flex items-center gap-1.5 min-w-0 truncate">
          {leadingIcon}
          {selectedOption?.icon}
          <span className="truncate">{selectedOption ? selectedOption.label : placeholder}</span>
        </span>
        {!hideChevron && (
          <ChevronDown16Regular className="w-3.5 h-3.5 text-[var(--text-tertiary)] shrink-0" />
        )}
      </button>

      <Popover
        open={open}
        onOpenChange={setOpen}
        anchorEl={triggerRef.current}
        placement="bottom-start"
        offset={4}
        className="min-w-[216px] max-w-[308px] p-1"
      >
        <div className="win-input-elevation flex items-center gap-1.5 h-8 px-2 mb-1 rounded-[var(--win-radius-control)]">
          <Search16Regular className="w-3.5 h-3.5 text-[var(--text-tertiary)] shrink-0" />
          <input
            type="text"
            value={query}
            onChange={(e) => setQuery(e.target.value)}
            onKeyDown={handleListKeyDown}
            placeholder="筛选选项…"
            autoFocus
            className="w-full bg-transparent text-[12.5px] text-[var(--text-primary)] placeholder:text-[var(--text-tertiary)] outline-none"
          />
        </div>
        <div
          ref={listboxRef}
          role="listbox"
          tabIndex={-1}
          onKeyDown={handleListKeyDown}
          className="max-h-[260px] overflow-y-auto charkle-scroll flex flex-col gap-0.5 outline-none"
        >
          {filtered.length === 0 ? (
            <div className="px-2.5 py-2 text-[12px] text-[var(--text-tertiary)] text-center">
              无匹配项
            </div>
          ) : (
            filtered.map((opt, idx) => {
              const active = opt.value === value;
              const highlighted = idx === highlightedIndex;
              return (
                <button
                  key={opt.value}
                  type="button"
                  role="option"
                  data-option-index={idx}
                  aria-selected={active}
                  onMouseEnter={() => setHighlightedIndex(idx)}
                  onClick={() => commitOption(opt.value)}
                  style={opt.depth ? { paddingLeft: 12 + opt.depth * 14 } : undefined}
                  className={[
                    'relative w-full min-h-[32px] flex items-center gap-2 pl-3 pr-2.5 py-1.5 text-left text-[13px] leading-[18px] cursor-pointer',
                    'rounded-[var(--win-radius-control)] transition-colors duration-[83ms] ease-[var(--win-ease-out)]',
                    active
                      ? 'bg-[var(--win-subtle-active)] text-[var(--text-primary)] font-medium'
                      : highlighted
                        ? 'bg-[var(--win-subtle-hover)] text-[var(--text-primary)]'
                        : 'text-[var(--text-primary)] hover:bg-[var(--win-subtle-hover)]',
                  ].join(' ')}
                >
                  <span
                    aria-hidden="true"
                    className={[
                      'absolute left-[2px] top-1/2 -translate-y-1/2 w-[3px] h-4 rounded-full bg-[var(--accent)] transition-opacity duration-[83ms]',
                      active ? 'opacity-100' : 'opacity-0',
                    ].join(' ')}
                  />
                  {opt.icon}
                  <span className="truncate flex-1 min-w-0">{opt.label}</span>
                  {opt.subtitle && (
                    <span className="text-[11px] text-[var(--text-tertiary)] shrink-0 charkle-tabular">
                      {opt.subtitle}
                    </span>
                  )}
                </button>
              );
            })
          )}
        </div>
      </Popover>
    </>
  );
}
