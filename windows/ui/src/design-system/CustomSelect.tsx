import React, { useEffect, useMemo, useRef, useState } from 'react';
import { Check, ChevronDown, Search } from 'lucide-react';
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
  variant?: 'default' | 'glassPill';
  adaptGlass?: boolean;
  leadingIcon?: React.ReactNode;
  hideChevron?: boolean;
  className?: string;
}

/**
 * Custom styled Select / Combobox replacing native `<select>` (DESIGN.md §7.2).
 * Uses checkmarks inside option rows (never radio dots) and auto-enables search when >= 15 options.
 */
export function CustomSelect<T extends string>({
  value,
  options,
  onChange,
  placeholder = '请选择',
  searchableThreshold = 15,
  ariaLabel,
  size = 'sm',
  variant = 'default',
  adaptGlass = false,
  leadingIcon,
  hideChevron = false,
  className = '',
}: CustomSelectProps<T>) {
  const triggerRef = useRef<HTMLButtonElement | null>(null);
  const listboxRef = useRef<HTMLDivElement | null>(null);
  const [open, setOpen] = useState(false);
  const [query, setQuery] = useState('');
  const [highlightedIndex, setHighlightedIndex] = useState(-1);

  const selectedOption = useMemo(
    () => options.find((o) => o.value === value) ?? null,
    [options, value],
  );

  const showSearch = options.length >= searchableThreshold;
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
    if (!showSearch) {
      requestAnimationFrame(() => listboxRef.current?.focus({ preventScroll: true }));
    }
  }, [open, filtered, value, showSearch]);

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

  const isGlassPill = variant === 'glassPill';

  return (
    <>
      <button
        ref={triggerRef}
        type="button"
        aria-label={ariaLabel}
        aria-haspopup="listbox"
        aria-expanded={open}
        data-pill={isGlassPill ? 'true' : undefined}
        data-adapt-glass={isGlassPill && adaptGlass ? 'true' : undefined}
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
        className={[
          'charkle-pressable inline-flex items-center justify-between gap-1.5 min-w-0 cursor-pointer select-none whitespace-nowrap',
          'focus-visible:outline-2 focus-visible:outline-[var(--accent)]',
          isGlassPill
            ? 'charkle-glass rounded-full h-[34px] px-3 text-[12px] font-medium text-[var(--text-primary)]'
            : [
                'bg-[var(--bg-inspector-field)] border border-[var(--border-hairline)] hover:border-[var(--border-strong)]',
                'text-[var(--text-primary)] rounded-[var(--radius-settings-inner)]',
                size === 'xs' ? 'h-7 px-2.5 text-[12px]' : 'h-8 px-3 text-[12.5px]',
              ].join(' '),
          className,
        ].join(' ')}
      >
        <span className="inline-flex items-center gap-1.5 min-w-0 truncate">
          {leadingIcon}
          {selectedOption?.icon}
          <span className="truncate">{selectedOption ? selectedOption.label : placeholder}</span>
        </span>
        {!hideChevron && <ChevronDown size={13} className="text-[var(--text-tertiary)] shrink-0" />}
      </button>

      <Popover
        open={open}
        onOpenChange={setOpen}
        anchorEl={triggerRef.current}
        placement="bottom-start"
        className="min-w-[200px] max-w-[300px] p-1.5"
      >
        {showSearch && (
          <div className="flex items-center gap-1.5 px-2 py-1 mb-1 rounded-[var(--radius-popover-inner)] bg-[var(--bg-subtle)]">
            <Search size={13} className="text-[var(--text-tertiary)] shrink-0" />
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
        )}
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
                  style={opt.depth ? { paddingLeft: 10 + opt.depth * 14 } : undefined}
                  className={[
                    'charkle-pressable w-full flex items-center gap-2 px-2.5 py-1.5 text-left text-[12.5px] cursor-pointer',
                    'rounded-[var(--radius-popover-inner)]',
                    active
                      ? 'bg-[var(--accent-soft)] text-[var(--accent)] font-medium'
                      : highlighted
                        ? 'bg-[var(--bg-subtle)] text-[var(--text-primary)]'
                        : 'text-[var(--text-primary)] hover:bg-[var(--bg-subtle)]',
                  ].join(' ')}
                >
                  <span className="w-3.5 shrink-0 inline-flex items-center justify-center">
                    {active && <Check size={13} />}
                  </span>
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
