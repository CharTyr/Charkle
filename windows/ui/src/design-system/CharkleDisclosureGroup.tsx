import React, { useState } from 'react';
import { ChevronRight } from 'lucide-react';

export interface CharkleDisclosureGroupProps {
  /** Header content spanning the full clickable row. */
  label: React.ReactNode;
  /** Optional controlled expanded state. */
  expanded?: boolean;
  /** Default expanded state when uncontrolled. */
  defaultExpanded?: boolean;
  /** Called whenever the user toggles expansion. */
  onExpandedChange?: (expanded: boolean) => void;
  /** Optional trailing badge or accessory rendered inside the full-row button. */
  trailing?: React.ReactNode;
  /** Optional subtle hover highlight on header row (default true). */
  showHoverHighlight?: boolean;
  className?: string;
  headerClassName?: string;
  contentClassName?: string;
  children: React.ReactNode;
}

/**
 * Full-row clickable collapsible section matching macOS `CharkleDisclosureGroup.swift`:
 * clicking anywhere across the header row toggles expansion with a smooth chevron rotation,
 * full-row hover affordance, and `prefers-reduced-motion` safety.
 */
export const CharkleDisclosureGroup: React.FC<CharkleDisclosureGroupProps> = ({
  label,
  expanded: controlledExpanded,
  defaultExpanded = false,
  onExpandedChange,
  trailing,
  showHoverHighlight = true,
  className = '',
  headerClassName = '',
  contentClassName = '',
  children,
}) => {
  const [uncontrolledExpanded, setUncontrolledExpanded] = useState(defaultExpanded);
  const isExpanded = controlledExpanded ?? uncontrolledExpanded;

  const toggle = () => {
    const next = !isExpanded;
    if (controlledExpanded === undefined) {
      setUncontrolledExpanded(next);
    }
    onExpandedChange?.(next);
  };

  return (
    <div className={`flex flex-col ${className}`}>
      <button
        type="button"
        aria-expanded={isExpanded}
        onClick={toggle}
        className={[
          'w-full min-h-[30px] px-1.5 py-1.5 -mx-1.5 flex items-center gap-2 rounded-[var(--radius-chip)] text-left cursor-pointer select-none',
          'focus-visible:outline-2 focus-visible:outline-[var(--accent)]',
          showHoverHighlight ? 'hover:bg-black/[0.045] dark:hover:bg-white/[0.065]' : '',
          headerClassName,
        ]
          .filter(Boolean)
          .join(' ')}
      >
        <ChevronRight
          size={12}
          strokeWidth={2.2}
          className={[
            'shrink-0 transition-transform duration-[220ms] ease-[cubic-bezier(0.22,1,0.36,1)] motion-reduce:transition-none',
            isExpanded ? 'rotate-90 text-[var(--text-primary)]/80' : 'text-[var(--text-secondary)]/85',
          ].join(' ')}
        />
        <span className="flex-1 min-w-0 flex items-center gap-1.5">{label}</span>
        {trailing && <span className="shrink-0">{trailing}</span>}
      </button>

      {isExpanded && (
        <div className={`charkle-pane-fade ${contentClassName}`}>{children}</div>
      )}
    </div>
  );
};
