import React from 'react';

const MASONRY_RATIOS = [1.25, 0.78, 1.0, 1.4, 0.85, 1.15, 0.72, 1.32, 0.95, 1.18, 0.82, 1.08];

/**
 * Geometry-matched Gallery Masonry Skeleton (DESIGN.md §7.6).
 */
export const GallerySkeleton: React.FC<{ columns?: number; topInset?: number }> = ({
  columns = 4,
  topInset = 16,
}) => {
  const cols = Math.max(2, Math.min(6, columns));
  return (
    <div
      aria-busy="true"
      aria-label="正在加载素材"
      className="grid gap-3 px-4 pb-6"
      style={{
        paddingTop: topInset,
        gridTemplateColumns: `repeat(${cols}, minmax(0, 1fr))`,
      }}
    >
      {Array.from({ length: cols }).map((_, colIdx) => (
        <div key={colIdx} className="flex flex-col gap-3">
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
  <div className="grid grid-cols-2 gap-2" aria-busy="true">
    {Array.from({ length: 6 }).map((_, i) => (
      <div
        key={i}
        className="charkle-skeleton rounded-[var(--radius-settings-inner)] aspect-[4/3] w-full"
      />
    ))}
  </div>
);

/**
 * Structural Moodboard canvas skeleton matching macOS `CharkleBoardLoadingSkeleton` (DESIGN.md §7.6).
 */
export const BoardLoadingSkeleton: React.FC = () => (
  <div
    aria-busy="true"
    aria-label="正在加载情绪板"
    className="flex-1 min-h-0 flex items-center justify-center p-9 bg-[var(--bg-gallery)]"
  >
    <div className="flex items-start gap-4">
      <div className="flex flex-col gap-4">
        <div className="charkle-skeleton rounded-[var(--radius-card-outer)] w-[210px] h-[250px]" />
        <div className="charkle-skeleton rounded-[var(--radius-card-outer)] w-[210px] h-[146px]" />
      </div>
      <div className="flex flex-col gap-4">
        <div className="charkle-skeleton rounded-[var(--radius-card-outer)] w-[250px] h-[164px]" />
        <div className="charkle-skeleton rounded-[var(--radius-card-outer)] w-[250px] h-[232px]" />
      </div>
      <div className="hidden md:flex flex-col gap-4">
        <div className="charkle-skeleton rounded-[var(--radius-card-outer)] w-[196px] h-[212px]" />
        <div className="charkle-skeleton rounded-[var(--radius-card-outer)] w-[196px] h-[184px]" />
      </div>
    </div>
  </div>
);
