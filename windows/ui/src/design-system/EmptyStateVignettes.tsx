import React from 'react';

export type EmptyVignetteKind =
  | 'emptyLibrary'
  | 'inboxZero'
  | 'noResults'
  | 'emptyFolder'
  | 'emptyMoodboards'
  | 'emptyTrash'
  | 'emptyInspector';

export interface EmptyStateVignetteProps {
  kind: EmptyVignetteKind;
  compact?: boolean;
  className?: string;
}

/**
 * Self-contained Miniature UI Vignettes strictly following DESIGN.md §5.2 & P2-1:
 * - `viewBox="0 0 160 120"` with subtle 45-deg hatch backing
 * - 2-3 restrained miniature UI elements, zero text/emoji/illustrations
 * - At most 1 accent focal point when a clear next action exists
 * - Automatically adapts to Light & Dark themes via CSS custom properties
 */
export const EmptyStateVignette: React.FC<EmptyStateVignetteProps> = ({
  kind,
  compact = false,
  className = '',
}) => {
  const patternId = `charkle-hatch-${kind}-${compact ? 'sm' : 'md'}`;
  return (
    <svg
      viewBox="0 0 160 120"
      width={compact ? 132 : 160}
      height={compact ? 98 : 120}
      aria-hidden="true"
      className={`select-none shrink-0 ${className}`}
    >
      <defs>
        <pattern
          id={patternId}
          width="8"
          height="8"
          patternUnits="userSpaceOnUse"
          patternTransform="rotate(45)"
        >
          <line x1="0" y1="0" x2="0" y2="8" stroke="var(--vignette-hatch)" strokeWidth="1" />
        </pattern>
      </defs>

      <rect
        x="4"
        y="4"
        width="152"
        height="112"
        rx="18"
        fill="var(--vignette-bg)"
        stroke="var(--vignette-stroke)"
        strokeWidth="1"
      />
      <rect x="4" y="4" width="152" height="112" rx="18" fill={`url(#${patternId})`} />

      {kind === 'emptyLibrary' && (
        <g>
          <rect
            x="24"
            y="24"
            width="48"
            height="68"
            rx="8"
            fill="var(--vignette-card)"
            stroke="var(--vignette-stroke)"
            strokeWidth="1"
          />
          <rect x="30" y="30" width="36" height="42" rx="4" fill="var(--vignette-muted)" />
          <rect
            x="80"
            y="24"
            width="56"
            height="34"
            rx="8"
            fill="var(--vignette-card)"
            stroke="var(--vignette-stroke)"
            strokeWidth="1"
          />
          <rect
            x="80"
            y="64"
            width="56"
            height="28"
            rx="8"
            fill="var(--vignette-card)"
            stroke="var(--accent)"
            strokeWidth="1.25"
            strokeDasharray="3 3"
          />
          <path
            d="M108 73v10M103 78h10"
            stroke="var(--accent)"
            strokeWidth="1.6"
            strokeLinecap="round"
          />
        </g>
      )}

      {kind === 'inboxZero' && (
        <g>
          <rect
            x="32"
            y="30"
            width="96"
            height="62"
            rx="10"
            fill="var(--vignette-card)"
            stroke="var(--vignette-stroke)"
            strokeWidth="1"
          />
          <path
            d="M32 64h28l6 10h28l6-10h28"
            fill="none"
            stroke="var(--vignette-stroke)"
            strokeWidth="1"
          />
          <g className="charkle-micro-pop" style={{ transformOrigin: '80px 48px' }}>
            <circle cx="80" cy="48" r="11" fill="var(--success-soft)" />
            <path
              d="M75.5 48.2l3.1 3.1 6.2-6.4"
              fill="none"
              stroke="var(--success)"
              strokeWidth="1.8"
              strokeLinecap="round"
              strokeLinejoin="round"
            />
          </g>
        </g>
      )}

      {kind === 'noResults' && (
        <g>
          <rect
            x="28"
            y="24"
            width="104"
            height="20"
            rx="10"
            fill="var(--vignette-card)"
            stroke="var(--vignette-stroke)"
            strokeWidth="1"
          />
          <circle cx="40" cy="34" r="4" fill="none" stroke="var(--text-tertiary)" strokeWidth="1.3" />
          <line x1="43" y1="37" x2="46" y2="40" stroke="var(--text-tertiary)" strokeWidth="1.3" strokeLinecap="round" />
          <rect x="52" y="32" width="44" height="4" rx="2" fill="var(--vignette-muted)" />
          <rect x="28" y="54" width="30" height="40" rx="6" fill="var(--vignette-card)" stroke="var(--vignette-stroke)" strokeWidth="1" strokeDasharray="3 3" />
          <rect x="65" y="54" width="30" height="40" rx="6" fill="var(--vignette-card)" stroke="var(--vignette-stroke)" strokeWidth="1" strokeDasharray="3 3" />
          <rect x="102" y="54" width="30" height="40" rx="6" fill="var(--vignette-card)" stroke="var(--vignette-stroke)" strokeWidth="1" strokeDasharray="3 3" />
        </g>
      )}

      {kind === 'emptyFolder' && (
        <g>
          <path
            d="M32 38a8 8 0 018-8h24l8 8h48a8 8 0 018 8v40a8 8 0 01-8 8H40a8 8 0 01-8-8V38z"
            fill="var(--vignette-card)"
            stroke="var(--vignette-stroke)"
            strokeWidth="1"
          />
          <rect
            x="48"
            y="50"
            width="64"
            height="30"
            rx="6"
            fill="var(--vignette-bg)"
            stroke="var(--accent)"
            strokeWidth="1.15"
            strokeDasharray="3 3"
          />
          <path
            d="M80 60v10M75 65h10"
            stroke="var(--accent)"
            strokeWidth="1.5"
            strokeLinecap="round"
          />
        </g>
      )}

      {kind === 'emptyMoodboards' && (
        <g>
          <rect x="26" y="26" width="44" height="50" rx="7" fill="var(--vignette-card)" stroke="var(--vignette-stroke)" strokeWidth="1" />
          <rect x="78" y="22" width="54" height="36" rx="7" fill="var(--vignette-card)" stroke="var(--vignette-stroke)" strokeWidth="1" />
          <path
            d="M70 48c8 0 8-8 16-8"
            fill="none"
            stroke="var(--accent)"
            strokeWidth="1.4"
            strokeDasharray="2.5 2.5"
          />
          <rect x="78" y="66" width="54" height="28" rx="7" fill="var(--vignette-card)" stroke="var(--accent)" strokeWidth="1.2" />
          <circle cx="91" cy="80" r="4" fill="var(--accent)" />
          <rect x="101" y="78" width="22" height="4" rx="2" fill="var(--vignette-muted)" />
        </g>
      )}

      {kind === 'emptyTrash' && (
        <g>
          <rect x="34" y="28" width="92" height="54" rx="10" fill="var(--vignette-muted)" stroke="var(--vignette-stroke)" strokeWidth="1" />
          <rect x="28" y="34" width="104" height="58" rx="11" fill="var(--vignette-card)" stroke="var(--vignette-stroke)" strokeWidth="1" />
          <path d="M71 53h18M76 53v-3h8v3M74 56l1 14h10l1-14" fill="none" stroke="var(--text-tertiary)" strokeWidth="1.5" strokeLinecap="round" strokeLinejoin="round" />
          <rect x="56" y="77" width="48" height="4" rx="2" fill="var(--vignette-muted)" />
        </g>
      )}

      {kind === 'emptyInspector' && (
        <g>
          <rect x="26" y="28" width="44" height="64" rx="9" fill="var(--vignette-muted)" stroke="var(--vignette-stroke)" strokeWidth="1" />
          <rect x="31" y="33" width="34" height="54" rx="5" fill="var(--vignette-bg)" />
          <rect x="78" y="28" width="56" height="64" rx="10" fill="var(--vignette-card)" stroke="var(--vignette-stroke)" strokeWidth="1" />
          <rect x="86" y="37" width="34" height="4.5" rx="2.2" fill="var(--vignette-stroke)" />
          <circle cx="90" cy="50" r="4" fill="var(--accent)" />
          <circle cx="101" cy="50" r="4" fill="var(--vignette-stroke)" />
          <circle cx="112" cy="50" r="4" fill="var(--vignette-muted)" />
          <rect x="86" y="61" width="40" height="4" rx="2" fill="var(--vignette-muted)" />
          <rect x="86" y="70" width="28" height="4" rx="2" fill="var(--vignette-muted)" />
        </g>
      )}
    </svg>
  );
};
