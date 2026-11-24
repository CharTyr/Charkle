import React from 'react';
import { Collapsible as BaseCollapsible } from '@base-ui/react/collapsible';
import { ChevronRight16Regular } from '@fluentui/react-icons';

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
 * Full-row clickable Fluent 2 Collapsible section built on `@base-ui/react/collapsible`:
 * - Full-row clickable trigger (never chevron-only)
 * - Smooth height & opacity reveal with reduced-motion fallback
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
}) => (
  <BaseCollapsible.Root
    open={controlledExpanded}
    defaultOpen={defaultExpanded}
    onOpenChange={(next) => onExpandedChange?.(next)}
    className={`flex flex-col ${className}`}
  >
    <BaseCollapsible.Trigger
      className={[
        'group w-full min-h-[32px] px-1.5 py-1.5 -mx-1.5 flex items-center gap-2',
        'rounded-[var(--win-radius-control)] text-left cursor-pointer select-none',
        'transition-colors duration-[83ms] ease-[var(--win-ease-out)]',
        'focus-visible:outline-2 focus-visible:outline-[var(--accent)]',
        showHoverHighlight
          ? 'hover:bg-[var(--win-subtle-hover)] active:bg-[var(--win-subtle-active)]'
          : '',
        headerClassName,
      ]
        .filter(Boolean)
        .join(' ')}
    >
      <ChevronRight16Regular
        className={[
          'w-3.5 h-3.5 shrink-0 text-[var(--text-secondary)]',
          'transition-transform duration-[167ms] ease-[var(--win-ease-out)] motion-reduce:transition-none',
          'group-data-[panel-open]:rotate-90 group-data-[panel-open]:text-[var(--text-primary)]',
        ].join(' ')}
      />
      <span className="flex-1 min-w-0 flex items-center gap-1.5">{label}</span>
      {trailing && <span className="shrink-0">{trailing}</span>}
    </BaseCollapsible.Trigger>

    <BaseCollapsible.Panel className={`win-collapsible-panel ${contentClassName}`}>
      {children}
    </BaseCollapsible.Panel>
  </BaseCollapsible.Root>
);
