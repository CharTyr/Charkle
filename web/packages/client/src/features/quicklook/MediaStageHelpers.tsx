import React, { useEffect } from 'react';
import { Copy, ExternalLink } from 'lucide-react';
import { labFromHex, parseHex } from '@charkle/shared';
import type { AssetRecord } from '@charkle/shared';
import { apiClient } from '../../api/client';
import { SkeletonBlock, useDelayedFlag } from '../../design-system';
import { useCoordinatorStore } from '../../stores/coordinatorStore';
import { getCardEffectiveAspectRatio, isColorSwatchAsset } from '../gallery/assetCardUtils';

export const LazyModel3DViewer = React.lazy(() =>
  import('./Model3DViewer').then((m) => ({ default: m.Model3DViewer })),
);

export const Delayed3DStagePlaceholder: React.FC<{ className?: string }> = ({
  className = 'w-[min(860px,88vw)] h-full max-h-[560px]',
}) => {
  const visible = useDelayedFlag(true, 300, 500);
  if (!visible) return <div className={className} />;
  return (
    <div
      className={`${className} rounded-[var(--radius-dock-outer)] bg-[#181A20] border border-white/10 flex flex-col items-center justify-center gap-3 text-white/80 text-[13px]`}
    >
      <SkeletonBlock className="h-14 w-14 rounded-2xl bg-white/10" />
      <span>正在加载 3D 模型…</span>
    </div>
  );
};

export function isTallStripDimensions(width: number, height: number): boolean {
  return width > 0 && height >= 1600 && height / width >= 2.2;
}

export function computeDynamicMaxZoom(width: number, height: number): number {
  const maxDim = Math.max(width, height);
  return Math.max(6, Math.min(16, maxDim / 550));
}

export type AssetViewerKind =
  | 'githubRepo'
  | 'socialPost'
  | 'swatch'
  | 'audio'
  | 'model3D'
  | 'document'
  | 'video'
  | 'webBookmark'
  | 'visual';

export function classifyAssetViewerKind(asset: AssetRecord): AssetViewerKind {
  if (asset.richMetadata?.githubRepo) return 'githubRepo';
  if (asset.richMetadata?.socialPost) return 'socialPost';
  if (isColorSwatchAsset(asset)) return 'swatch';
  if (asset.mediaKind === 'audio') return 'audio';
  if (asset.mediaKind === 'model3D') return 'model3D';
  if (asset.mediaKind === 'document') return 'document';
  if (asset.mediaKind === 'video') return 'video';
  if (asset.mediaKind === 'webBookmark') return 'webBookmark';
  return 'visual';
}

export function supportsVisualTransform(asset: AssetRecord): boolean {
  return (
    classifyAssetViewerKind(asset) === 'visual' &&
    (asset.mediaKind === 'image' ||
      asset.mediaKind === 'animatedImage' ||
      asset.mediaKind === 'designFile')
  );
}

export function computeWheelZoomFactor(e: WheelEvent): number {
  const clamped = Math.max(-60, Math.min(60, -e.deltaY));
  const sensitivity = e.deltaMode === 0 ? 0.0042 : 0.055;
  return Math.exp(clamped * sensitivity);
}

/**
 * Exact viewport-measured scale factor when rotated by ±90° so landscape/portrait
 * images remain cleanly fitted inside the stage without edge clipping.
 */
export function computeQuarterTurnFitScale(
  stageSize: { width: number; height: number },
  asset: AssetRecord,
  rotation: number,
  naturalSize?: { width: number; height: number } | null,
): number {
  const normalizedRot = ((rotation % 180) + 180) % 180;
  if (normalizedRot !== 90) return 1;

  const natW = naturalSize?.width || asset.pixelWidth;
  const natH = naturalSize?.height || asset.pixelHeight;
  const aspect =
    natW > 0 && natH > 0 ? natW / natH : Math.max(0.25, Math.min(4, getCardEffectiveAspectRatio(asset)));

  if (stageSize.width > 0 && stageSize.height > 0) {
    const availW = stageSize.width;
    const availH = stageSize.height;
    let fittedW: number;
    let fittedH: number;
    if (availW / availH >= aspect) {
      fittedH = availH;
      fittedW = availH * aspect;
    } else {
      fittedW = availW;
      fittedH = availW / aspect;
    }
    if (fittedW > 0 && fittedH > 0) {
      const scale = Math.min(availW / fittedH, availH / fittedW);
      return Math.max(0.25, Math.min(1, scale));
    }
  }

  if (natW > 0 && natH > 0) {
    return Math.max(0.25, Math.min(1, Math.min(natW, natH) / Math.max(natW, natH)));
  }
  return 1;
}

/**
 * Redirects vertical mouse-wheel scrolling to horizontal scrollLeft on a filmstrip container,
 * while leaving native horizontal trackpad swipes and pinch-zoom gestures untouched.
 */
export function useHorizontalWheelRedirect(
  ref: React.RefObject<HTMLElement | null>,
  enabled = true,
): void {
  useEffect(() => {
    if (!enabled) return;
    const el = ref.current;
    if (!el) return;

    const onWheel = (e: WheelEvent) => {
      if (e.metaKey || e.ctrlKey) return;
      if (Math.abs(e.deltaY) <= Math.abs(e.deltaX)) return;
      if (el.scrollWidth <= el.clientWidth) return;
      e.preventDefault();
      const multiplier = e.deltaMode === 1 ? 28 : e.deltaMode === 2 ? el.clientWidth * 0.8 : 1;
      el.scrollLeft += e.deltaY * multiplier;
    };

    el.addEventListener('wheel', onWheel, { passive: false });
    return () => el.removeEventListener('wheel', onWheel);
  }, [ref, enabled]);
}

export const ColorSwatchViewer: React.FC<{ asset: AssetRecord }> = ({ asset }) => {
  const pushToast = useCoordinatorStore((s) => s.pushToast);
  const hex = asset.dominantColors[0]?.hex || '#4E7D96';
  const rgb = parseHex(hex);
  const lab = asset.dominantColors[0] ?? labFromHex(hex);
  const rgbStr = rgb
    ? `rgb(${Math.round(rgb.r * 255)}, ${Math.round(rgb.g * 255)}, ${Math.round(rgb.b * 255)})`
    : '—';
  const labStr = `L ${lab.l.toFixed(1)} · a ${lab.a.toFixed(1)} · b ${lab.b.toFixed(1)}`;

  const copy = async (val: string) => {
    await navigator.clipboard.writeText(val).catch(() => {});
    pushToast({ tone: 'info', message: `已复制 ${val}` });
  };

  return (
    <div className="w-[min(420px,88vw)] max-h-full rounded-[var(--radius-dock-outer)] overflow-hidden bg-[var(--bg-elevated)] border border-[var(--border-hairline)] shadow-2xl flex flex-col">
      <div className="h-[220px] min-h-[140px] flex-1 w-full" style={{ backgroundColor: hex }} />
      <div className="p-5 flex flex-col gap-2.5 shrink-0">
        <div className="text-[15px] font-semibold text-[var(--text-primary)] truncate">
          {asset.title}
        </div>
        {[
          { label: 'HEX', val: hex },
          { label: 'RGB', val: rgbStr },
          { label: 'Lab', val: labStr },
        ].map((row) => (
          <button
            key={row.label}
            type="button"
            onClick={() => void copy(row.val)}
            className="charkle-pressable flex items-center justify-between px-3 py-2 rounded-[var(--radius-settings-inner)] bg-[var(--bg-gallery)] hover:bg-[var(--bg-subtle)] text-[12.5px] cursor-pointer"
          >
            <span className="text-[var(--text-tertiary)] font-semibold">{row.label}</span>
            <span className="font-mono text-[var(--text-primary)] inline-flex items-center gap-1.5">
              {row.val}
              <Copy size={12} className="opacity-60" />
            </span>
          </button>
        ))}
      </div>
    </div>
  );
};

export const WebBookmarkViewer: React.FC<{ asset: AssetRecord; cacheBust: number }> = ({
  asset,
  cacheBust,
}) => {
  const accentHex = asset.dominantColors[0]?.hex || 'var(--accent)';
  return (
    <div className="w-[min(620px,90vw)] max-h-full rounded-[var(--radius-dock-outer)] overflow-hidden bg-[var(--bg-elevated)] border border-[var(--border-hairline)] shadow-2xl flex flex-col">
      <img
        src={apiClient.thumbnailURL(asset.id, 'preview1400', `${asset.updatedAt}-${cacheBust}`)}
        alt={asset.title}
        className="w-full max-h-[320px] min-h-[140px] object-cover bg-[var(--bg-subtle)] shrink-0"
      />
      <div className="p-5 flex flex-col gap-2 overflow-y-auto charkle-scroll">
        <div className="flex items-center gap-2">
          <span
            className="h-2 w-2 rounded-full shrink-0"
            style={{ backgroundColor: accentHex }}
          />
          <span className="text-[11px] font-mono text-[var(--text-tertiary)] truncate">
            {asset.sourceDomain || '网页书签'}
          </span>
        </div>
        <h3 className="text-[16px] font-semibold text-[var(--text-primary)]">{asset.title}</h3>
        {asset.sourceURL && (
          <div className="text-[11.5px] font-mono text-[var(--text-tertiary)] truncate">
            {asset.sourceURL}
          </div>
        )}
        {asset.notes && (
          <p className="text-[13px] text-[var(--text-secondary)] leading-relaxed whitespace-pre-wrap">
            {asset.notes}
          </p>
        )}
        {asset.sourceURL && (
          <div className="pt-2">
            <a
              href={asset.sourceURL}
              target="_blank"
              rel="noreferrer"
              className="charkle-pressable h-9 px-4 inline-flex items-center gap-1.5 rounded-[var(--radius-dock-inner)] bg-[var(--accent)] hover:bg-[var(--accent-hover)] text-white text-[13px] font-medium"
            >
              <ExternalLink size={14} />
              在浏览器中打开
            </a>
          </div>
        )}
      </div>
    </div>
  );
};
