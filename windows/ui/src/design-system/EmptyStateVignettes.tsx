import React from 'react';

export type EmptyVignetteKind =
  | 'emptyLibrary'
  | 'inboxZero'
  | 'noResults'
  | 'emptyFolder'
  | 'emptyMoodboards';

export interface EmptyStateVignetteProps {
  kind: EmptyVignetteKind;
  className?: string;
}

/**
 * Self-contained Miniature UI Vignettes strictly following DESIGN.md §5.2 & P2-1:
 * - `viewBox="0 0 160 120"` with subtle 45-deg hatch backing
 * - 2-3 restrained miniature UI elements, zero text/emoji/illustrations
 * - At most 1 accent focal point when a clear next action exists
 * - Automatically adapts to Light & Dark themes via CSS custom properties
 */
export const EmptyStateVignette: React.FC<EmptyStateVignetteProps> = ({ kind, className = '' }) => {
  const patternId = `charkle-hatch-${kind}`;
  return (
    <svg
      viewBox="0 0 160 120"
      width={160}
      height={120}
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
    </svg>
  );
};
