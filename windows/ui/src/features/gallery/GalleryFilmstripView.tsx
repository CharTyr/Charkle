import React, { useEffect, useMemo, useRef } from 'react';
import {
  ChevronLeft,
  ChevronRight,
  Maximize2,
} from 'lucide-react';
import { getTransport } from '../../api/transport';
import {
  Button,
  computeAmbientTintStyle,
  useResolvedIsDark,
} from '../../design-system';
import { useCoordinatorStore } from '../../stores';
import type { AssetRecord } from '../../types/domain';

export interface GalleryFilmstripViewProps {
  assets: AssetRecord[];
}

/**
 * Gallery Filmstrip mode (DESIGN.md §1 & §6.2):
 * Large centered hero stage + synchronized bottom filmstrip with focus scale `1.04`.
 */
export const GalleryFilmstripView: React.FC<GalleryFilmstripViewProps> = ({ assets }) => {
  const selectedAssetIds = useCoordinatorStore((s) => s.selectedAssetIds);
  const selectAsset = useCoordinatorStore((s) => s.selectAsset);
  const openQuickLook = useCoordinatorStore((s) => s.openQuickLook);
  const isDark = useResolvedIsDark();

  const stripRef = useRef<HTMLDivElement | null>(null);
  const stageRef = useRef<HTMLDivElement | null>(null);

  const orderedIds = useMemo(() => assets.map((a) => a.id), [assets]);
  const activeIndex = useMemo(() => {
    const cur = selectedAssetIds[0];
    if (!cur) return 0;
    const idx = assets.findIndex((a) => a.id === cur);
    return idx >= 0 ? idx : 0;
  }, [assets, selectedAssetIds]);

  const activeAsset = assets[activeIndex] ?? null;

  useEffect(() => {
    if (!activeAsset) return;
    if (selectedAssetIds.length === 0) {
      selectAsset(activeAsset.id, orderedIds);
    }
  }, [activeAsset, selectedAssetIds.length, orderedIds, selectAsset]);

  useEffect(() => {
    const strip = stripRef.current;
    if (!strip || !activeAsset) return;
    const activeEl = strip.querySelector<HTMLElement>(
      `[data-strip-id="${CSS.escape(activeAsset.id)}"]`,
    );
    activeEl?.scrollIntoView?.({ behavior: 'smooth', inline: 'center', block: 'nearest' });
  }, [activeAsset]);

  if (!activeAsset) return null;

  const transport = getTransport();
  const prevAsset = activeIndex > 0 ? assets[activeIndex - 1] : null;
  const nextAsset = activeIndex < assets.length - 1 ? assets[activeIndex + 1] : null;
  const ambientStyle = computeAmbientTintStyle(
    activeAsset.dominantColors[0]?.hex,
    isDark,
    'quicklook',
  );

  const launchQuickLook = () => {
    const rect = stageRef.current?.getBoundingClientRect();
    openQuickLook(
      activeAsset.id,
      rect
        ? { left: rect.left, top: rect.top, width: rect.width, height: rect.height }
        : null,
    );
  };

  return (
    <div
      data-testid="gallery-filmstrip-view"
      className="flex-1 min-h-0 flex flex-col overflow-hidden"
    >
      {/* Hero Stage */}
      <div
        ref={stageRef}
        style={ambientStyle}
        onDoubleClick={launchQuickLook}
        className="relative flex-1 min-h-0 flex items-center justify-center p-6 overflow-hidden select-none"
      >
        {prevAsset && (
          <button
            type="button"
            aria-label="上一项"
            onClick={() => selectAsset(prevAsset.id, orderedIds)}
            className="charkle-pressable charkle-glass absolute left-4 top-1/2 -translate-y-1/2 z-10 h-9 w-9 rounded-full inline-flex items-center justify-center text-[var(--text-primary)] cursor-pointer"
          >
            <ChevronLeft size={18} />
          </button>
        )}

        {activeAsset.mediaKind === 'video' ? (
          <video
            key={activeAsset.id}
            src={transport.originalUrl(activeAsset.id)}
            poster={transport.thumbnailUrl(activeAsset.id, 'preview1400')}
            controls
            playsInline
            className="max-w-full max-h-full rounded-[var(--radius-card-outer)] shadow-lg bg-black"
          />
        ) : activeAsset.richMetadata?.githubRepo ? (
          <div className="w-full max-w-[560px] p-6 rounded-[var(--radius-settings-outer)] bg-[var(--bg-elevated)] border border-[var(--border-hairline)] shadow-lg">
            <div className="text-[12px] text-[var(--text-tertiary)]">
              {activeAsset.richMetadata.githubRepo.owner}
            </div>
            <h2 className="text-[20px] font-semibold text-[var(--text-primary)] mt-0.5">
              {activeAsset.richMetadata.githubRepo.fullName}
            </h2>
            {activeAsset.richMetadata.githubRepo.description && (
              <p className="mt-2 text-[13.5px] text-[var(--text-secondary)] leading-relaxed">
                {activeAsset.richMetadata.githubRepo.description}
              </p>
            )}
            <div className="mt-4 flex items-center gap-4 text-[12px] text-[var(--text-tertiary)] charkle-tabular">
              <span>★ {activeAsset.richMetadata.githubRepo.stars.toLocaleString()}</span>
              <span>Forks {activeAsset.richMetadata.githubRepo.forks.toLocaleString()}</span>
              {activeAsset.richMetadata.githubRepo.language && (
                <span>{activeAsset.richMetadata.githubRepo.language}</span>
              )}
            </div>
          </div>
        ) : (
          <img
            key={activeAsset.id}
            src={transport.thumbnailUrl(activeAsset.id, 'preview1400')}
            alt={activeAsset.title}
            draggable={false}
            className="max-w-full max-h-full object-contain rounded-[var(--radius-card-outer)] shadow-[0_14px_38px_rgba(0,0,0,0.16)]"
          />
        )}

        {nextAsset && (
          <button
            type="button"
            aria-label="下一项"
            onClick={() => selectAsset(nextAsset.id, orderedIds)}
            className="charkle-pressable charkle-glass absolute right-4 top-1/2 -translate-y-1/2 z-10 h-9 w-9 rounded-full inline-flex items-center justify-center text-[var(--text-primary)] cursor-pointer"
          >
            <ChevronRight size={18} />
          </button>
        )}

        <div className="absolute bottom-3 left-1/2 -translate-x-1/2 charkle-glass rounded-full px-3 py-1 flex items-center gap-2.5 text-[12px]">
          <span className="font-medium text-[var(--text-primary)] max-w-[260px] truncate">
            {activeAsset.title}
          </span>
          <span className="text-[var(--text-tertiary)] charkle-tabular">
            {activeIndex + 1} / {assets.length}
          </span>
          <Button variant="ghost" size="xs" onClick={launchQuickLook} className="h-6 px-2">
            <Maximize2 size={12} />
            全屏预览
          </Button>
        </div>
      </div>

      {/* Synchronized bottom filmstrip */}
      <div
        ref={stripRef}
        className="shrink-0 h-[92px] border-t border-[var(--border-hairline)] bg-[var(--bg-sidebar)]/70 px-4 flex items-center gap-2 overflow-x-auto charkle-scroll"
      >
        {assets.map((item) => {
          const active = item.id === activeAsset.id;
          return (
            <button
              key={item.id}
              type="button"
              data-strip-id={item.id}
              data-active={active ? 'true' : undefined}
              onClick={() => selectAsset(item.id, orderedIds)}
              onDoubleClick={launchQuickLook}
              title={item.title}
              className={[
                'charkle-filmstrip-thumb shrink-0 h-[62px] w-[76px] rounded-[var(--radius-settings-inner)] overflow-hidden cursor-pointer bg-[var(--bg-elevated)]',
                active
                  ? 'ring-2 ring-[var(--accent)] opacity-100'
                  : 'opacity-65 hover:opacity-95 ring-1 ring-[var(--border-hairline)]',
              ].join(' ')}
            >
              <img
                src={transport.thumbnailUrl(item.id, 'grid520')}
                alt={item.title}
                loading="lazy"
                draggable={false}
                className="w-full h-full object-cover"
              />
            </button>
          );
        })}
      </div>
    </div>
  );
};
