import React, { useId } from 'react';
import { ChevronRight } from 'lucide-react';

export interface DisclosureGroupProps {
  open: boolean;
  onOpenChange: (open: boolean) => void;
  label: React.ReactNode;
  children: React.ReactNode;
  className?: string;
  headerClassName?: string;
}

/**
 * Full-row clickable disclosure control matching macOS `CharkleDisclosureGroup`:
 * clicking anywhere across the full-width header (chevron, title, gap, or trailing badge)
 * toggles expansion with subtle hover feedback and rotated 90° chevron.
 */
export const DisclosureGroup: React.FC<DisclosureGroupProps> = ({
  open,
  onOpenChange,
  label,
  children,
  className = '',
  headerClassName = '',
}) => {
  const contentId = useId();

  return (
    <div className={`flex flex-col ${className}`}>
      <button
        type="button"
        aria-expanded={open}
        aria-controls={contentId}
        onClick={() => onOpenChange(!open)}
        className={[
          'group w-full min-h-[30px] px-2 py-1.5 rounded-[var(--radius-chip)]',
          'flex items-center gap-2 text-left cursor-pointer select-none',
          'hover:bg-black/[0.04] dark:hover:bg-white/[0.055]',
          'transition-colors duration-[var(--duration-press)] ease-[var(--ease-out)]',
          'focus-visible:outline-2 focus-visible:outline-offset-1 focus-visible:outline-[var(--accent)]',
          headerClassName,
        ].join(' ')}
      >
        <ChevronRight
          size={13}
          strokeWidth={2.25}
          aria-hidden="true"
          className={[
            'shrink-0 transition-transform duration-[var(--duration-sm)] ease-[var(--ease-out-strong)]',
            open
              ? 'rotate-90 text-[var(--text-primary)]/80'
              : 'rotate-0 text-[var(--text-tertiary)] group-hover:text-[var(--text-primary)]/75',
          ].join(' ')}
        />
        <div className="flex-1 min-w-0 flex items-center justify-between gap-2">{label}</div>
      </button>

      {open && (
        <div id={contentId} className="pt-1.5">
          {children}
        </div>
      )}
    </div>
  );
};
