import React, { useMemo } from 'react';
import type { InkStroke, InkStrokePoint, UUID } from '@charkle/shared';
import { SegmentedControl } from '../../design-system';
import { GlassSurface } from '../../design-system/GlassSurface';
import { buildInkStrokePath } from './geometry';
import { CALM_INK_SWATCHES, INK_STROKE_WIDTHS } from './palettes';

export interface InkLayerProps {
  strokes: readonly InkStroke[];
  activeStrokePoints: readonly InkStrokePoint[];
  activeColorHex: string;
  activeLineWidth: number;
  activeOpacity: number;
  eraserActive: boolean;
  erasedStrokeIDs?: ReadonlySet<UUID>;
  onEraseStroke?: (id: UUID) => void;
}

export const InkLayer: React.FC<InkLayerProps> = ({
  strokes,
  activeStrokePoints,
  activeColorHex,
  activeLineWidth,
  activeOpacity,
  erasedStrokeIDs,
}) => {
  return (
    <svg
      className="absolute inset-0 overflow-visible pointer-events-none"
      width="1"
      height="1"
    >
      {strokes.map((stroke) => {
        const d = buildInkStrokePath(stroke.points);
        if (!d) return null;
        const isErased = erasedStrokeIDs?.has(stroke.id) ?? false;
        return (
          <path
            key={stroke.id}
            d={d}
            fill="none"
            stroke={stroke.colorHex}
            strokeWidth={stroke.lineWidth}
            strokeOpacity={isErased ? 0 : stroke.opacity}
            strokeLinecap="round"
            strokeLinejoin="round"
            style={{
              transition: 'stroke-opacity var(--duration-popover-out, 110ms) var(--ease-out)',
            }}
          />
        );
      })}

      {activeStrokePoints.length > 0 && (
        <path
          d={buildInkStrokePath(activeStrokePoints)}
          fill="none"
          stroke={activeColorHex}
          strokeWidth={activeLineWidth}
          strokeOpacity={activeOpacity}
          strokeLinecap="round"
          strokeLinejoin="round"
        />
      )}
    </svg>
  );
};

// MARK: - Floating Pen Options Pill (shown above dock when Pen tool is active)

export interface InkPenControlsPillProps {
  colorHex: string;
  lineWidth: number;
  opacity: number;
  onChangeColor: (hex: string) => void;
  onChangeWidth: (width: number) => void;
  onChangeOpacity: (opacity: number) => void;
}

export const InkPenControlsPill: React.FC<InkPenControlsPillProps> = ({
  colorHex,
  lineWidth,
  opacity,
  onChangeColor,
  onChangeWidth,
  onChangeOpacity,
}) => {
  const widthOptions = useMemo(
    () =>
      INK_STROKE_WIDTHS.map((w) => ({
        id: String(w.value),
        label: w.label,
        icon: (
          <span
            className="rounded-full bg-current"
            style={{ width: Math.max(4, w.value * 1.3), height: Math.max(4, w.value * 1.3) }}
          />
        ),
      })),
    [],
  );

  const selectedWidthID = useMemo(() => {
    const matched = INK_STROKE_WIDTHS.find((w) => Math.abs(lineWidth - w.value) < 0.2);
    return String(matched?.value ?? INK_STROKE_WIDTHS[1].value);
  }, [lineWidth]);

  return (
    <GlassSurface
      variant="regular"
      radius="pill"
      className="inline-flex items-center gap-3 px-3.5 py-1.5"
    >
      {/* 6 Calm Ink Swatches */}
      <div className="flex items-center gap-1.5">
        {CALM_INK_SWATCHES.map((s) => {
          const active = colorHex.toUpperCase() === s.hex.toUpperCase();
          return (
            <button
              key={s.hex}
              type="button"
              title={s.name}
              aria-label={`画笔颜色 ${s.name}`}
              onClick={() => onChangeColor(s.hex)}
              className="charkle-pressable w-4.5 h-4.5 rounded-full cursor-pointer"
              style={{
                backgroundColor: s.hex,
                boxShadow: active
                  ? '0 0 0 2px var(--bg-elevated), 0 0 0 3.5px var(--accent)'
                  : 'inset 0 0 0 1px rgba(128,128,128,0.35)',
              }}
            />
          );
        })}
      </div>

      <span className="w-px h-4 bg-[var(--border-hairline)]" />

      {/* 3 Stroke Widths */}
      <SegmentedControl
        ariaLabel="画笔粗细"
        size="sm"
        options={widthOptions}
        value={selectedWidthID}
        onChange={(next) => onChangeWidth(Number(next))}
      />

      <span className="w-px h-4 bg-[var(--border-hairline)]" />

      {/* Opacity Slider */}
      <label className="inline-flex items-center gap-1.5 text-[11px] text-[var(--text-secondary)]">
        <span>不透明度</span>
        <input
          type="range"
          min={0.25}
          max={1}
          step={0.05}
          value={opacity}
          onChange={(e) => onChangeOpacity(Number(e.target.value))}
          className="w-16 accent-[var(--accent)] cursor-pointer"
        />
        <span className="w-7 text-right font-mono tabular-nums">{Math.round(opacity * 100)}%</span>
      </label>
    </GlassSurface>
  );
};
