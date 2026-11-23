import React, { useId } from 'react';
import { useResolvedIsDark } from './theme';

export type EmptyStateKind =
  | 'emptyLibrary'
  | 'emptyFolder'
  | 'noFilterResults'
  | 'emptyTrash'
  | 'inboxZero'
  | 'emptyMoodboard'
  | 'emptyInspector';

export interface EmptyStateVignetteProps {
  kind: EmptyStateKind;
  compact?: boolean;
  className?: string;
}

/**
 * Miniature product-UI vector vignettes for empty states (`DESIGN.md` §5.2):
 * 160x120 (compact 132x98) subtle 45° hatched plate with 2–3 schematic interface frames
 * in calibrated Light & Dark studio tokens and at most one Studio Cobalt next-action cue.
 */
export const EmptyStateVignette: React.FC<EmptyStateVignetteProps> = ({
  kind,
  compact = false,
  className = '',
}) => {
  const isDark = useResolvedIsDark();
  const uid = useId().replace(/:/g, '');
  const hatchId = `charkle-hatch-${uid}`;
  const shadowId = `charkle-vshadow-${uid}`;

  const width = compact ? 132 : 160;
  const height = compact ? 98 : 120;

  const baseFill = isDark ? '#23252A' : '#F9F9F8';
  const hatchStroke = isDark ? 'rgba(255,255,255,0.038)' : 'rgba(15,23,42,0.048)';
  const baseBorder = isDark ? 'rgba(255,255,255,0.08)' : 'rgba(15,23,42,0.07)';
  const cardFill = isDark ? '#2F3239' : '#FFFFFF';
  const cardBackFill = isDark ? '#292C33' : '#F2F2F0';
  const cardBorder = isDark ? 'rgba(255,255,255,0.11)' : 'rgba(47,42,34,0.09)';
  const slotFill = isDark ? 'rgba(255,255,255,0.07)' : '#EFEFEF';
  const barStrong = isDark ? '#555B66' : '#CFD5DF';
  const barMuted = isDark ? '#404550' : '#E3E7EE';
  const accent = isDark ? '#5B8DEF' : '#2A60E0';
  const accentBg = isDark ? 'rgba(91,141,239,0.22)' : 'rgba(42,96,224,0.12)';
  const accentStroke = isDark ? 'rgba(91,141,239,0.45)' : 'rgba(42,96,224,0.30)';
  const positive = isDark ? '#4ADE80' : '#249A4B';
  const positiveBg = isDark ? 'rgba(74,222,128,0.20)' : 'rgba(36,154,75,0.14)';

  return (
    <svg
      width={width}
      height={height}
      viewBox="0 0 160 120"
      fill="none"
      aria-hidden="true"
      className={`shrink-0 select-none ${className}`}
    >
      <defs>
        <pattern
          id={hatchId}
          width="7"
          height="7"
          patternUnits="userSpaceOnUse"
          patternTransform="rotate(45)"
        >
          <line x1="0" y1="0" x2="0" y2="7" stroke={hatchStroke} strokeWidth="1" />
        </pattern>
        <filter id={shadowId} x="-15%" y="-15%" width="130%" height="145%">
          <feDropShadow
            dx="0"
            dy="3.5"
            stdDeviation="3.5"
            floodColor={isDark ? '#000000' : '#2F2A22'}
            floodOpacity={isDark ? '0.36' : '0.11'}
          />
        </filter>
      </defs>

      {/* Subtle 45° hatched plate */}
      <rect x="0.5" y="0.5" width="159" height="119" rx="18" fill={baseFill} />
      <rect x="0.5" y="0.5" width="159" height="119" rx="18" fill={`url(#${hatchId})`} />
      <rect x="0.5" y="0.5" width="159" height="119" rx="18" stroke={baseBorder} strokeWidth="1" />

      {kind === 'emptyLibrary' && (
        <g>
          {/* Col 1 */}
          <rect x="17" y="18" width="36" height="42" rx="8" fill={cardBackFill} stroke={cardBorder} />
          <rect
            x="17"
            y="67"
            width="36"
            height="34"
            rx="8"
            fill={cardFill}
            stroke={cardBorder}
            filter={`url(#${shadowId})`}
          />
          {/* Col 2 */}
          <rect x="60" y="18" width="40" height="36" rx="8" fill={accentBg} stroke={accentStroke} />
          <path
            d="M80 31V41M75 36H85"
            stroke={accent}
            strokeWidth="1.8"
            strokeLinecap="round"
          />
          <rect
            x="60"
            y="61"
            width="40"
            height="40"
            rx="8"
            fill={cardFill}
            stroke={cardBorder}
            filter={`url(#${shadowId})`}
          />
          {/* Col 3 */}
          <rect
            x="107"
            y="18"
            width="36"
            height="30"
            rx="8"
            fill={cardFill}
            stroke={cardBorder}
            filter={`url(#${shadowId})`}
          />
          <rect x="107" y="55" width="36" height="46" rx="8" fill={cardBackFill} stroke={cardBorder} />
        </g>
      )}

      {kind === 'emptyFolder' && (
        <g>
          {/* Folder back tab */}
          <rect x="20" y="23" width="42" height="18" rx="6" fill={cardBackFill} stroke={cardBorder} />
          {/* Main folder card */}
          <rect
            x="20"
            y="31"
            width="120"
            height="68"
            rx="11"
            fill={cardFill}
            stroke={cardBorder}
            filter={`url(#${shadowId})`}
          />
          <rect x="30" y="41" width="34" height="36" rx="6" fill={slotFill} />
          <rect x="70" y="41" width="34" height="36" rx="6" fill={slotFill} />
          <rect x="110" y="41" width="20" height="36" rx="6" fill={accentBg} stroke={accentStroke} />
          <path
            d="M120 55V63M116 59H124"
            stroke={accent}
            strokeWidth="1.6"
            strokeLinecap="round"
          />
          <rect x="30" y="85" width="44" height="4.5" rx="2.25" fill={barStrong} />
          <rect x="80" y="85" width="26" height="4.5" rx="2.25" fill={barMuted} />
        </g>
      )}

      {kind === 'noFilterResults' && (
        <g>
          {/* Mini search capsule */}
          <rect
            x="23"
            y="25"
            width="114"
            height="24"
            rx="12"
            fill={cardFill}
            stroke={cardBorder}
            filter={`url(#${shadowId})`}
          />
          <circle cx="36" cy="36.5" r="4" stroke={accent} strokeWidth="1.6" />
          <path d="M39 39.5L41.8 42.3" stroke={accent} strokeWidth="1.6" strokeLinecap="round" />
          <rect x="47" y="34.75" width="56" height="4.5" rx="2.25" fill={barStrong} />
          <circle cx="126" cy="37" r="3.5" fill={barMuted} />
          {/* Quiet dashed empty grid slots */}
          {[23, 63.5, 104].map((x) => (
            <rect
              key={x}
              x={x}
              y="59"
              width="33"
              height="36"
              rx="7"
              stroke={barStrong}
              strokeOpacity="0.65"
              strokeWidth="1.1"
              strokeDasharray="3 3"
            />
          ))}
        </g>
      )}

      {kind === 'emptyTrash' && (
        <g>
          <rect x="32" y="25" width="96" height="58" rx="10" fill={cardBackFill} stroke={cardBorder} />
          <rect
            x="28"
            y="34"
            width="104"
            height="60"
            rx="11"
            fill={cardFill}
            stroke={cardBorder}
            filter={`url(#${shadowId})`}
          />
          {/* Monochrome tray / bin outline */}
          <path
            d="M72 52H88M75 52V50C75 49.4 75.4 49 76 49H84C84.6 49 85 49.4 85 50V52M74 52L75.2 66.2C75.3 67.2 76.1 68 77.1 68H82.9C83.9 68 84.7 67.2 84.8 66.2L86 52"
            stroke={barStrong}
            strokeWidth="1.5"
            strokeLinecap="round"
            strokeLinejoin="round"
          />
          <rect x="56" y="76" width="48" height="4" rx="2" fill={barMuted} />
        </g>
      )}

      {kind === 'inboxZero' && (
        <g>
          <rect x="34" y="24" width="92" height="52" rx="10" fill={cardBackFill} stroke={cardBorder} />
          <rect
            x="23"
            y="36"
            width="114"
            height="56"
            rx="12"
            fill={cardFill}
            stroke={cardBorder}
            filter={`url(#${shadowId})`}
          />
          <rect x="35" y="48" width="32" height="32" rx="8" fill={positiveBg} />
          <path
            d="M45 64.5L49.2 68.5L57 59.5"
            stroke={positive}
            strokeWidth="2.2"
            strokeLinecap="round"
            strokeLinejoin="round"
          />
          <rect x="76" y="55" width="50" height="5" rx="2.5" fill={barStrong} />
          <rect x="76" y="66" width="34" height="4" rx="2" fill={barMuted} />
        </g>
      )}

      {kind === 'emptyMoodboard' && (
        <g>
          {/* Tall blank collage frame */}
          <rect
            x="27"
            y="25"
            width="54"
            height="64"
            rx="9"
            fill={cardFill}
            stroke={cardBorder}
            filter={`url(#${shadowId})`}
          />
          <rect x="33" y="31" width="42" height="52" rx="5" fill={slotFill} />
          {/* Top-right note frame */}
          <rect
            x="87"
            y="26"
            width="50"
            height="34"
            rx="9"
            fill={cardFill}
            stroke={cardBorder}
            filter={`url(#${shadowId})`}
          />
          <rect x="94" y="36" width="28" height="4" rx="2" fill={barStrong} />
          <rect x="94" y="45" width="20" height="3.5" rx="1.75" fill={barMuted} />
          {/* Bottom-right cobalt action node */}
          <rect x="87" y="66" width="50" height="28" rx="8" fill={accentBg} stroke={accentStroke} />
          <path
            d="M112 75.5V84.5M107.5 80H116.5"
            stroke={accent}
            strokeWidth="1.7"
            strokeLinecap="round"
          />
        </g>
      )}

      {kind === 'emptyInspector' && (
        <g>
          {/* Mini thumbnail card */}
          <rect x="20" y="29" width="44" height="62" rx="9" fill={cardBackFill} stroke={cardBorder} />
          <rect x="25" y="34" width="34" height="52" rx="5" fill={slotFill} />
          {/* Mini inspector rail */}
          <rect
            x="72"
            y="29"
            width="68"
            height="62"
            rx="10"
            fill={cardFill}
            stroke={cardBorder}
            filter={`url(#${shadowId})`}
          />
          <rect x="81" y="39" width="42" height="4.5" rx="2.25" fill={barStrong} />
          <circle cx="85" cy="52" r="4" fill={accent} fillOpacity="0.88" />
          <circle cx="97" cy="52" r="4" fill={barStrong} />
          <circle cx="109" cy="52" r="4" fill={barMuted} />
          <rect x="81" y="63" width="48" height="4" rx="2" fill={barMuted} />
          <rect x="81" y="73" width="32" height="4" rx="2" fill={barMuted} />
        </g>
      )}
    </svg>
  );
};
