import React, { useEffect, useMemo, useRef } from 'react';
import { createPortal } from 'react-dom';
import {
  ChevronLeft,
  ChevronRight,
  ExternalLink,
  FolderOpen,
  Star,
  X,
} from 'lucide-react';
import { getTransport } from '../../api/transport';
import {
  computeAmbientTintStyle,
  useResolvedIsDark,
} from '../../design-system';
import { useCoordinatorStore, useLibraryStore } from '../../stores';
import type { AssetRecord } from '../../types/domain';
import { AudioStudioViewer } from './AudioStudioViewer';
import { DocumentMarkdownViewer } from './DocumentMarkdownViewer';
import { GitHubRepoViewer } from './GitHubRepoViewer';
import { ImageStageViewer } from './ImageStageViewer';
import { Model3DViewer } from './Model3DViewer';
import { PdfDocumentViewer } from './PdfDocumentViewer';
import { SocialPostViewer } from './SocialPostViewer';

function renderStageForAsset(asset: AssetRecord): React.ReactNode {
  const transport = getTransport();

  if (asset.mediaKind === 'video') {
    return (
      <video
        key={asset.id}
        src={transport.originalUrl(asset.id)}
        poster={transport.thumbnailUrl(asset.id, 'preview1400')}
        controls
        autoPlay
        playsInline
        className="max-w-[88vw] max-h-[74vh] rounded-[var(--radius-card-outer)] shadow-2xl bg-black"
      />
    );
  }

  if (asset.mediaKind === 'audio') {
    return <AudioStudioViewer asset={asset} />;
  }

  if (asset.mediaKind === 'model3D') {
    return <Model3DViewer asset={asset} />;
  }

  if (asset.richMetadata?.githubRepo) {
    return <GitHubRepoViewer asset={asset} />;
  }

  if (asset.richMetadata?.socialPost) {
    return <SocialPostViewer asset={asset} />;
  }

  if (asset.mediaKind === 'document') {
    const isPdf =
      asset.mimeType === 'application/pdf' || /\.pdf$/i.test(asset.fileName);
    if (isPdf) {
      return <PdfDocumentViewer asset={asset} />;
    }
    return <DocumentMarkdownViewer asset={asset} />;
  }

  return <ImageStageViewer asset={asset} />;
}

/**
 * Full-media Space Quick Look overlay covering all 8 Charkle media kinds (M2-R7).
 */
export const QuickLookOverlay: React.FC = () => {
  const quickLookAssetId = useCoordinatorStore((s) => s.quickLookAssetId);
  const openQuickLook = useCoordinatorStore((s) => s.openQuickLook);
  const closeQuickLook = useCoordinatorStore((s) => s.closeQuickLook);
  const setSelection = useCoordinatorStore((s) => s.setSelection);
  const destination = useCoordinatorStore((s) => s.destination);

  const assets = useLibraryStore((s) => s.assets);
  const updateAssets = useLibraryStore((s) => s.updateAssets);
  const markAssetOpened = useLibraryStore((s) => s.markAssetOpened);

  const isDark = useResolvedIsDark();
  const stripRef = useRef<HTMLDivElement | null>(null);

  const activeIndex = useMemo(() => {
    if (!quickLookAssetId) return -1;
    return assets.findIndex((a) => a.id === quickLookAssetId);
  }, [assets, quickLookAssetId]);

  const asset = activeIndex >= 0 ? assets[activeIndex] : null;

  useEffect(() => {
    if (!asset) return;
    void markAssetOpened(asset.id);
    const strip = stripRef.current;
    if (strip) {
      const el = strip.querySelector<HTMLElement>(
        `[data-ql-thumb="${CSS.escape(asset.id)}"]`,
      );
      el?.scrollIntoView?.({ behavior: 'smooth', inline: 'center', block: 'nearest' });
    }
  }, [asset?.id, markAssetOpened]);

  useEffect(() => {
    if (!quickLookAssetId) return;
    const handleKey = (e: KeyboardEvent) => {
      if (e.key === 'Escape' || e.code === 'Space') {
        e.preventDefault();
        e.stopPropagation();
        closeQuickLook();
      } else if (e.key === 'ArrowLeft' && activeIndex > 0) {
        e.preventDefault();
        const prev = assets[activeIndex - 1];
        if (prev) {
          openQuickLook(prev.id, null);
          setSelection([prev.id], prev.id);
        }
      } else if (e.key === 'ArrowRight' && activeIndex >= 0 && activeIndex < assets.length - 1) {
        e.preventDefault();
        const next = assets[activeIndex + 1];
        if (next) {
          openQuickLook(next.id, null);
          setSelection([next.id], next.id);
        }
      }
    };
    window.addEventListener('keydown', handleKey, true);
    return () => window.removeEventListener('keydown', handleKey, true);
  }, [quickLookAssetId, activeIndex, assets, closeQuickLook, openQuickLook, setSelection]);

  if (!asset || typeof document === 'undefined') return null;

  const transport = getTransport();
  const prevAsset = activeIndex > 0 ? assets[activeIndex - 1] : null;
  const nextAsset = activeIndex < assets.length - 1 ? assets[activeIndex + 1] : null;
  const ambientStyle = computeAmbientTintStyle(
    asset.dominantColors[0]?.hex,
    isDark,
    'quicklook',
  );

  return createPortal(
    <div
      role="dialog"
      aria-modal="true"
      aria-label={`快速预览：${asset.title}`}
      data-testid="quicklook-overlay"
      className="fixed inset-0 z-[130] flex flex-col bg-[var(--bg-gallery)]/96 backdrop-blur-md"
      style={ambientStyle}
    >
      {/* Top Quiet Action Bar */}
      <header className="shrink-0 h-12 px-4 flex items-center justify-between gap-3 border-b border-[var(--border-hairline)]">
        <div className="flex items-center gap-2.5 min-w-0">
          <h2 className="text-[14px] font-semibold text-[var(--text-primary)] truncate">
            {asset.title}
          </h2>
          <span className="text-[12px] text-[var(--text-tertiary)] charkle-tabular shrink-0">
            {activeIndex + 1} / {assets.length}
          </span>
        </div>

        <div className="flex items-center gap-1.5 shrink-0">
          <div className="flex items-center gap-0.5 mr-1">
            {[1, 2, 3, 4, 5].map((star) => {
              const filled = asset.rating >= star;
              return (
                <button
                  key={star}
                  type="button"
                  aria-label={`评为 ${star} 星`}
                  onClick={() =>
                    void updateAssets(
                      { assetIDs: [asset.id], rating: asset.rating === star ? 0 : star },
                      destination,
                    )
                  }
                  className={[
                    'charkle-pressable h-7 w-7 inline-flex items-center justify-center rounded cursor-pointer',
                    filled ? 'text-amber-500' : 'text-[var(--text-tertiary)] hover:text-[var(--text-primary)]',
                  ].join(' ')}
                >
                  <Star size={14} className={filled ? 'fill-current' : ''} />
                </button>
              );
            })}
          </div>

          <button
            type="button"
            onClick={() => void transport.revealInExplorer(asset.id)}
            title="在资源管理器中显示"
            className="charkle-pressable h-8 px-2.5 inline-flex items-center gap-1.5 rounded-[var(--radius-chip)] bg-[var(--bg-subtle)] text-[12px] text-[var(--text-primary)] cursor-pointer"
          >
            <FolderOpen size={13.5} />
            <span className="hidden sm:inline">打开位置</span>
          </button>

          {asset.sourceURL && (
            <button
              type="button"
              onClick={() => void transport.openExternalUrl(asset.sourceURL!)}
              title="打开来源链接"
              className="charkle-pressable h-8 px-2.5 inline-flex items-center gap-1.5 rounded-[var(--radius-chip)] bg-[var(--bg-subtle)] text-[12px] text-[var(--text-primary)] cursor-pointer"
            >
              <ExternalLink size={13.5} />
              <span className="hidden sm:inline">原链接</span>
            </button>
          )}

          <button
            type="button"
            aria-label="关闭快速预览"
            onClick={closeQuickLook}
            className="charkle-pressable h-8 w-8 inline-flex items-center justify-center rounded-[var(--radius-chip)] bg-[var(--bg-subtle)] text-[var(--text-primary)] hover:bg-[var(--border-hairline)] cursor-pointer"
          >
            <X size={16} />
          </button>
        </div>
      </header>

      {/* Center Stage */}
      <div className="relative flex-1 min-h-0 flex items-center justify-center p-4 overflow-hidden">
        {prevAsset && (
          <button
            type="button"
            aria-label="上一项素材"
            onClick={() => {
              openQuickLook(prevAsset.id, null);
              setSelection([prevAsset.id], prevAsset.id);
            }}
            className="charkle-pressable charkle-glass absolute left-4 top-1/2 -translate-y-1/2 z-20 h-10 w-10 rounded-full inline-flex items-center justify-center text-[var(--text-primary)] cursor-pointer"
          >
            <ChevronLeft size={20} />
          </button>
        )}

        <div className="charkle-modal-panel w-full h-full flex items-center justify-center min-w-0 min-h-0">
          {renderStageForAsset(asset)}
        </div>

        {nextAsset && (
          <button
            type="button"
            aria-label="下一项素材"
            onClick={() => {
              openQuickLook(nextAsset.id, null);
              setSelection([nextAsset.id], nextAsset.id);
            }}
            className="charkle-pressable charkle-glass absolute right-4 top-1/2 -translate-y-1/2 z-20 h-10 w-10 rounded-full inline-flex items-center justify-center text-[var(--text-primary)] cursor-pointer"
          >
            <ChevronRight size={20} />
          </button>
        )}
      </div>

      {/* Bottom Filmstrip */}
      {assets.length > 1 && (
        <div
          ref={stripRef}
          className="shrink-0 h-[82px] border-t border-[var(--border-hairline)] bg-[var(--bg-sidebar)]/80 px-4 flex items-center gap-2 overflow-x-auto charkle-scroll"
        >
          {assets.map((item) => {
            const active = item.id === asset.id;
            return (
              <button
                key={item.id}
                type="button"
                data-ql-thumb={item.id}
                data-active={active ? 'true' : undefined}
                onClick={() => {
                  openQuickLook(item.id, null);
                  setSelection([item.id], item.id);
                }}
                title={item.title}
                className={[
                  'charkle-filmstrip-thumb shrink-0 h-[54px] w-[68px] rounded-[var(--radius-card-inner)] overflow-hidden cursor-pointer bg-[var(--bg-elevated)]',
                  active
                    ? 'ring-2 ring-[var(--accent)] opacity-100'
                    : 'opacity-60 hover:opacity-95 ring-1 ring-[var(--border-hairline)]',
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
      )}
    </div>,
    document.body,
  );
};
