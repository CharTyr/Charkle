import React from 'react';

const MASONRY_RATIOS = [1.25, 0.78, 1.0, 1.4, 0.85, 1.15, 0.72, 1.32, 0.95, 1.18, 0.82, 1.08];

/**
 * Geometry-matched Gallery Masonry Skeleton (DESIGN.md §7.6 & P0-4).
 */
export const GallerySkeleton: React.FC<{ columns?: number }> = ({ columns = 4 }) => {
  const cols = Math.max(2, Math.min(6, columns));
  return (
    <div
      aria-busy="true"
      aria-label="正在加载素材"
      className="grid gap-3.5 p-5"
      style={{ gridTemplateColumns: `repeat(${cols}, minmax(0, 1fr))` }}
    >
      {Array.from({ length: cols }).map((_, colIdx) => (
        <div key={colIdx} className="flex flex-col gap-3.5">
          {Array.from({ length: 3 }).map((__, rowIdx) => {
            const ratio = MASONRY_RATIOS[(colIdx * 3 + rowIdx) % MASONRY_RATIOS.length];
            return (
              <div
                key={rowIdx}
                className="charkle-skeleton rounded-[var(--radius-card-outer)] w-full"
                style={{ aspectRatio: String(ratio) }}
              />
            );
          })}
        </div>
      ))}
    </div>
  );
};

/**
 * Geometry-matched Inspector Similar Grid Skeleton (DESIGN.md P0-4).
 */
export const InspectorSimilarSkeleton: React.FC = () => (
  <div className="grid grid-cols-3 gap-1.5" aria-busy="true">
    {Array.from({ length: 6 }).map((_, i) => (
      <div
        key={i}
        className="charkle-skeleton rounded-[var(--radius-card-inner)] aspect-square w-full"
      />
    ))}
  </div>
);
