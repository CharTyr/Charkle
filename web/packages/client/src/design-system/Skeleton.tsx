import React from 'react';
import { useDelayedFlag } from './useDelayedFlag';

export interface SkeletonBlockProps {
  className?: string;
  style?: React.CSSProperties;
}

export const SkeletonBlock: React.FC<SkeletonBlockProps> = ({ className = '', style }) => (
  <div
    aria-hidden="true"
    style={style}
    className={`charkle-skeleton rounded-[var(--radius-card-outer)] ${className}`}
  />
);

const MASONRY_COLUMNS: ReadonlyArray<readonly number[]> = [
  [210, 152, 244],
  [164, 232, 178],
  [240, 168, 206],
  [182, 218, 160],
];

export const GalleryMasonrySkeleton: React.FC<{ className?: string }> = ({ className = '' }) => (
  <div
    aria-busy="true"
    aria-label="正在载入素材"
    className={`w-full px-5 pt-2 pb-12 grid grid-cols-2 md:grid-cols-3 xl:grid-cols-4 gap-3 ${className}`}
  >
    {MASONRY_COLUMNS.map((heights, colIdx) => (
      <div
        key={colIdx}
        className={[
          'flex flex-col gap-3',
          colIdx === 2 ? 'hidden md:flex' : '',
          colIdx === 3 ? 'hidden xl:flex' : '',
        ].join(' ')}
      >
        {heights.map((h, rowIdx) => (
          <SkeletonBlock key={rowIdx} style={{ height: h }} className="w-full" />
        ))}
      </div>
    ))}
  </div>
);

export const InboxTriageSkeleton: React.FC<{ rows?: number; className?: string }> = ({
  rows = 5,
  className = '',
}) => (
  <div
    aria-busy="true"
    aria-label="正在分析收件箱素材"
    className={`flex flex-col gap-2 py-1 ${className}`}
  >
    {Array.from({ length: rows }, (_, idx) => (
      <div
        key={idx}
        className="flex items-center gap-3 p-2.5 rounded-[var(--radius-settings-inner)] bg-[var(--bg-gallery)] border border-[var(--border-hairline)]"
      >
        <SkeletonBlock className="h-5 w-5 rounded-[6px] shrink-0" />
        <SkeletonBlock className="h-12 w-12 rounded-[6px] shrink-0" />
        <div className="flex-1 min-w-0 flex flex-col gap-2">
          <div className="flex items-center gap-2">
            <SkeletonBlock className="h-3.5 w-32 rounded-full" />
            <SkeletonBlock className="h-4 w-20 rounded-full" />
          </div>
          <SkeletonBlock className="h-3 w-4/5 rounded-full" />
        </div>
        <div className="flex flex-col items-end gap-1.5 shrink-0">
          <SkeletonBlock className="h-3.5 w-9 rounded-full" />
          <SkeletonBlock className="h-2.5 w-7 rounded-full" />
        </div>
      </div>
    ))}
  </div>
);

export const CandidateGridSkeleton: React.FC<{ count?: number; className?: string }> = ({
  count = 6,
  className = '',
}) => (
  <div
    aria-busy="true"
    aria-label="正在检索候选素材"
    className={`grid grid-cols-2 gap-2 ${className}`}
  >
    {Array.from({ length: count }, (_, idx) => (
      <div key={idx} className="flex flex-col gap-1.5">
        <SkeletonBlock className="aspect-square w-full rounded-[var(--radius-settings-inner)]" />
        <SkeletonBlock className="h-2.5 w-3/4 rounded-full" />
      </div>
    ))}
  </div>
);

export const InspectorSimilarSkeleton: React.FC<{ count?: number; className?: string }> = ({
  count = 6,
  className = '',
}) => (
  <div
    aria-busy="true"
    aria-label="正在检索类似素材"
    className={`grid grid-cols-2 gap-2 ${className}`}
  >
    {Array.from({ length: count }, (_, idx) => (
      <SkeletonBlock
        key={idx}
        className="aspect-square w-full rounded-[var(--radius-settings-inner)]"
      />
    ))}
  </div>
);

export const BoardCanvasSkeleton: React.FC<{
  active?: boolean;
  delayMs?: number;
  minVisibleMs?: number;
  className?: string;
}> = ({ active = true, delayMs = 300, minVisibleMs = 500, className = '' }) => {
  const show = useDelayedFlag(active, delayMs, minVisibleMs);
  if (!show) {
    return <div className={`flex-1 w-full h-full ${className}`} aria-busy="true" />;
  }

  return (
    <div
      aria-busy="true"
      aria-label="正在载入情绪板画布"
      className={`flex-1 w-full h-full p-8 flex items-center justify-center overflow-hidden ${className}`}
    >
      <div className="w-full max-w-[920px] grid grid-cols-3 gap-5 items-start">
        <div className="flex flex-col gap-4">
          <SkeletonBlock className="h-[220px] w-full rounded-[var(--radius-card-outer)]" />
          <SkeletonBlock className="h-[116px] w-full rounded-[var(--radius-card-outer)]" />
        </div>
        <div className="flex flex-col gap-4 pt-6">
          <SkeletonBlock className="h-[150px] w-full rounded-[var(--radius-card-outer)]" />
          <SkeletonBlock className="h-[196px] w-full rounded-[var(--radius-card-outer)]" />
        </div>
        <div className="flex flex-col gap-4 pt-2">
          <SkeletonBlock className="h-[188px] w-full rounded-[var(--radius-card-outer)]" />
          <SkeletonBlock className="h-[136px] w-full rounded-[var(--radius-card-outer)]" />
        </div>
      </div>
    </div>
  );
};
