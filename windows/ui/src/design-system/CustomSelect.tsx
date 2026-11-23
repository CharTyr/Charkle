import React, { useMemo, useRef, useState } from 'react';
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
  className?: string;
}

/**
 * Custom styled Select / Combobox replacing native `<select>` (DESIGN.md §7.2 & P1-4).
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
  className = '',
}: CustomSelectProps<T>) {
  const triggerRef = useRef<HTMLButtonElement | null>(null);
  const [open, setOpen] = useState(false);
  const [query, setQuery] = useState('');

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

  return (
    <>
      <button
        ref={triggerRef}
        type="button"
        aria-label={ariaLabel}
        aria-haspopup="listbox"
        aria-expanded={open}
        onClick={() => {
          setQuery('');
          setOpen((v) => !v);
        }}
        className={[
          'charkle-pressable inline-flex items-center justify-between gap-2 min-w-0 cursor-pointer select-none',
          'bg-[var(--bg-inspector-field)] border border-[var(--border-hairline)] hover:border-[var(--border-strong)]',
          'text-[var(--text-primary)] rounded-[var(--radius-settings-inner)]',
          'focus-visible:outline-2 focus-visible:outline-[var(--accent)]',
          size === 'xs' ? 'h-7 px-2.5 text-[12px]' : 'h-8 px-3 text-[12.5px]',
          className,
        ].join(' ')}
      >
        <span className="inline-flex items-center gap-1.5 min-w-0 truncate">
          {selectedOption?.icon}
          <span className="truncate">{selectedOption ? selectedOption.label : placeholder}</span>
        </span>
        <ChevronDown size={13} className="text-[var(--text-tertiary)] shrink-0" />
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
              placeholder="筛选选项…"
              autoFocus
              className="w-full bg-transparent text-[12.5px] text-[var(--text-primary)] placeholder:text-[var(--text-tertiary)] outline-none"
            />
          </div>
        )}
        <div role="listbox" className="max-h-[260px] overflow-y-auto charkle-scroll flex flex-col gap-0.5">
          {filtered.length === 0 ? (
            <div className="px-2.5 py-2 text-[12px] text-[var(--text-tertiary)] text-center">
              无匹配项
            </div>
          ) : (
            filtered.map((opt) => {
              const active = opt.value === value;
              return (
                <button
                  key={opt.value}
                  type="button"
                  role="option"
                  aria-selected={active}
                  onClick={() => {
                    onChange(opt.value);
                    setOpen(false);
                  }}
                  style={opt.depth ? { paddingLeft: 10 + opt.depth * 14 } : undefined}
                  className={[
                    'charkle-pressable w-full flex items-center gap-2 px-2.5 py-1.5 text-left text-[12.5px] cursor-pointer',
                    'rounded-[var(--radius-popover-inner)]',
                    active
                      ? 'bg-[var(--accent-soft)] text-[var(--accent)] font-medium'
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
