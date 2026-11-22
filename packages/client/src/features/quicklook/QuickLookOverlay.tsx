import React, { useEffect, useMemo, useRef, useState } from 'react';
import { createPortal } from 'react-dom';
import {
  ChevronLeft,
  ChevronRight,
  Copy,
  Download,
  ExternalLink,
  FlipHorizontal2,
  FlipVertical2,
  Info,
  RotateCcw,
  RotateCw,
  Star,
  X,
  ZoomIn,
  ZoomOut,
} from 'lucide-react';
import {
  createDefaultAssetBatchPatch,
  getAssetDisplayTypeLabel,
  labFromHex,
  parseHex,
} from '@charkle/shared';
import type { AssetRecord } from '@charkle/shared';
import { apiClient } from '../../api/client';
import {
  computeAmbientTintStyle,
  formatBytes,
  useResolvedIsDark,
} from '../../design-system';
import { useCoordinatorStore } from '../../stores/coordinatorStore';
import { useLibraryStore } from '../../stores/libraryStore';
import { getCardEffectiveAspectRatio, isColorSwatchAsset } from '../gallery/assetCardUtils';
import { AudioStudioViewer } from './AudioStudioViewer';
import { DocumentMarkdownViewer } from './DocumentMarkdownViewer';
import { GitHubRepoViewer } from './GitHubRepoViewer';
import { SocialPostViewer } from './SocialPostViewer';

const LazyModel3DViewer = React.lazy(() =>
  import('./Model3DViewer').then((m) => ({ default: m.Model3DViewer })),
);

function ColorSwatchViewer({ asset }: { asset: AssetRecord }) {
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
    <div className="w-[min(420px,88vw)] rounded-[var(--radius-dock-outer)] overflow-hidden bg-[var(--bg-elevated)] border border-[var(--border-hairline)] shadow-2xl">
      <div className="h-[240px] w-full" style={{ backgroundColor: hex }} />
      <div className="p-5 flex flex-col gap-2.5">
        <div className="text-[15px] font-semibold text-[var(--text-primary)]">{asset.title}</div>
        {[
          { label: 'HEX', val: hex },
          { label: 'RGB', val: rgbStr },
          { label: 'CIELAB', val: labStr },
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
}

export const QuickLookOverlay: React.FC = () => {
  const quickLookAssetID = useCoordinatorStore((s) => s.quickLookAssetID);
  const closeQuickLook = useCoordinatorStore((s) => s.closeQuickLook);
  const openQuickLook = useCoordinatorStore((s) => s.openQuickLook);
  const pushToast = useCoordinatorStore((s) => s.pushToast);

  const assets = useLibraryStore((s) => s.assets);
  const assetsByID = useLibraryStore((s) => s.assetsByID);
  const cacheBust = useLibraryStore((s) => s.cacheBustVersion);
  const markOpened = useLibraryStore((s) => s.markOpened);
  const batchPatch = useLibraryStore((s) => s.batchPatch);
  const selectAsset = useLibraryStore((s) => s.selectAsset);

  const isDark = useResolvedIsDark();

  const [chromeVisible, setChromeVisible] = useState(false);
  const [sidePanelOpen, setSidePanelOpen] = useState(false);
  const [zoom, setZoom] = useState(1);
  const [pan, setPan] = useState({ x: 0, y: 0 });
  const [rotation, setRotation] = useState(0);
  const [flipH, setFlipH] = useState(false);
  const [flipV, setFlipV] = useState(false);
  const [draggingPan, setDraggingPan] = useState(false);
  const panOriginRef = useRef({ x: 0, y: 0, panX: 0, panY: 0 });

  const currentIndex = useMemo(() => {
    if (!quickLookAssetID) return -1;
    return assets.findIndex((a) => a.id === quickLookAssetID);
  }, [assets, quickLookAssetID]);

  const asset: AssetRecord | null = useMemo(() => {
    if (!quickLookAssetID) return null;
    if (currentIndex >= 0) return assets[currentIndex];
    return assetsByID[quickLookAssetID] ?? null;
  }, [quickLookAssetID, currentIndex, assets, assetsByID]);

  // Reset transform + 110ms staggered HUD choreography (`PARITY_SPEC.md` §7.1)
  useEffect(() => {
    if (!quickLookAssetID) {
      setChromeVisible(false);
      return;
    }
    setZoom(1);
    setPan({ x: 0, y: 0 });
    setRotation(0);
    setFlipH(false);
    setFlipV(false);
    void markOpened(quickLookAssetID);

    const timer = window.setTimeout(() => setChromeVisible(true), 110);
    return () => window.clearTimeout(timer);
  }, [quickLookAssetID, markOpened]);

  const stepTo = (delta: number) => {
    if (assets.length === 0 || currentIndex < 0) return;
    const nextIdx = Math.max(0, Math.min(assets.length - 1, currentIndex + delta));
    if (nextIdx === currentIndex) return;
    const next = assets[nextIdx];
    selectAsset(next.id, 'replace');
    openQuickLook(next.id);
  };

  const resetTransforms = () => {
    setZoom(1);
    setPan({ x: 0, y: 0 });
    setRotation(0);
    setFlipH(false);
    setFlipV(false);
  };

  // Keyboard shortcuts (`PARITY_SPEC.md` §7.1)
  useEffect(() => {
    if (!quickLookAssetID) return;
    const onKeyDown = (e: KeyboardEvent) => {
      if (e.key === 'Escape' || e.key === ' ') {
        e.preventDefault();
        e.stopPropagation();
        closeQuickLook();
        return;
      }
      if (e.key === 'ArrowRight') {
        e.preventDefault();
        stepTo(1);
      } else if (e.key === 'ArrowLeft') {
        e.preventDefault();
        stepTo(-1);
      } else if (e.key === 'r' || e.key === 'R') {
        e.preventDefault();
        const parity = flipH !== flipV ? -1 : 1;
        const delta = (e.shiftKey ? -90 : 90) * parity;
        setRotation((r) => (r + delta) % 360);
      } else if ((e.key === 'h' || e.key === 'H') && e.shiftKey) {
        e.preventDefault();
        setFlipH((v) => !v);
      } else if ((e.key === 'v' || e.key === 'V') && e.shiftKey) {
        e.preventDefault();
        setFlipV((v) => !v);
      } else if (e.key === '0') {
        e.preventDefault();
        resetTransforms();
      }
    };
    window.addEventListener('keydown', onKeyDown, true);
    return () => window.removeEventListener('keydown', onKeyDown, true);
  }, [quickLookAssetID, currentIndex, assets, flipH, flipV, closeQuickLook]);

  if (!quickLookAssetID || !asset || typeof document === 'undefined') return null;

  const isVisualImage =
    asset.mediaKind === 'image' ||
    asset.mediaKind === 'animatedImage' ||
    asset.mediaKind === 'designFile';
  const isVideo = asset.mediaKind === 'video';
  const isAudio = asset.mediaKind === 'audio';
  const isModel3D = asset.mediaKind === 'model3D';
  const githubRepo = asset.richMetadata?.githubRepo ?? null;
  const socialPost = asset.richMetadata?.socialPost ?? null;
  const isSwatch = isColorSwatchAsset(asset);
  const isWebBookmark = asset.mediaKind === 'webBookmark' && !githubRepo && !socialPost;
  const isDocument = asset.mediaKind === 'document' && !isSwatch;

  const quarterTurn = Math.abs(rotation % 180) === 90;
  const quarterFitScale =
    quarterTurn && asset.pixelWidth > 0 && asset.pixelHeight > 0
      ? Math.min(1, Math.min(asset.pixelWidth, asset.pixelHeight) / Math.max(asset.pixelWidth, asset.pixelHeight))
      : 1;

  const primaryHex = asset.dominantColors[0]?.hex;
  const ambientStyle = computeAmbientTintStyle(primaryHex, isDark, 'quicklook');

  return createPortal(
    <div
      className="fixed inset-0 z-[150] flex flex-col select-none"
      style={{
        backgroundColor: isDark ? 'rgba(0, 0, 0, 0.78)' : 'rgba(21, 22, 25, 0.70)',
        backdropFilter: 'blur(18px)',
        WebkitBackdropFilter: 'blur(18px)',
      }}
      onClick={(e) => {
        if (e.target === e.currentTarget) closeQuickLook();
      }}
    >
      {/* Ambient Color Tint Layer */}
      <div
        aria-hidden="true"
        className="pointer-events-none absolute inset-0"
        style={ambientStyle}
      />

      {/* Top Floating Liquid Glass HUD (staggered 110ms) */}
      <div
        className="relative z-20 flex items-center justify-between gap-3 px-5 pt-4 pb-2 transition-opacity duration-[180ms] ease-[var(--ease-out)]"
        style={{ opacity: chromeVisible ? 1 : 0 }}
      >
        <div className="charkle-glass-dark px-3.5 py-1.5 rounded-full flex items-center gap-2.5 max-w-[52vw]">
          <span className="text-[13px] font-medium text-white truncate">{asset.title}</span>
          <span className="text-[11.5px] text-white/60 shrink-0">
            {getAssetDisplayTypeLabel(asset)}
            {asset.pixelWidth > 0 && ` · ${asset.pixelWidth}×${asset.pixelHeight}`}
          </span>
        </div>

        <div className="charkle-glass-dark p-1 rounded-full flex items-center gap-0.5">
          {isVisualImage && (
            <>
              <button
                type="button"
                title="缩小"
                onClick={() => setZoom((z) => Math.max(0.5, Number((z * 0.8).toFixed(2))))}
                className="charkle-pressable h-7.5 w-7.5 rounded-full hover:bg-white/12 text-white/85 flex items-center justify-center cursor-pointer"
              >
                <ZoomOut size={14} />
              </button>
              <span className="text-[11px] font-mono text-white/75 w-10 text-center tabular-nums">
                {Math.round(zoom * 100)}%
              </span>
              <button
                type="button"
                title="放大"
                onClick={() => setZoom((z) => Math.min(5, Number((z * 1.25).toFixed(2))))}
                className="charkle-pressable h-7.5 w-7.5 rounded-full hover:bg-white/12 text-white/85 flex items-center justify-center cursor-pointer"
              >
                <ZoomIn size={14} />
              </button>
              <button
                type="button"
                title="顺时针旋转 90° (R)"
                onClick={() => setRotation((r) => (r + (flipH !== flipV ? -90 : 90)) % 360)}
                className="charkle-pressable h-7.5 w-7.5 rounded-full hover:bg-white/12 text-white/85 flex items-center justify-center cursor-pointer"
              >
                <RotateCw size={14} />
              </button>
              <button
                type="button"
                title="水平翻转 (⇧H)"
                onClick={() => setFlipH((v) => !v)}
                className="charkle-pressable h-7.5 w-7.5 rounded-full hover:bg-white/12 text-white/85 flex items-center justify-center cursor-pointer"
              >
                <FlipHorizontal2 size={14} />
              </button>
              <button
                type="button"
                title="垂直翻转 (⇧V)"
                onClick={() => setFlipV((v) => !v)}
                className="charkle-pressable h-7.5 w-7.5 rounded-full hover:bg-white/12 text-white/85 flex items-center justify-center cursor-pointer"
              >
                <FlipVertical2 size={14} />
              </button>
              <button
                type="button"
                title="重置视图 (0)"
                onClick={resetTransforms}
                className="charkle-pressable h-7.5 w-7.5 rounded-full hover:bg-white/12 text-white/85 flex items-center justify-center cursor-pointer"
              >
                <RotateCcw size={13} />
              </button>
              <div className="w-px h-4 bg-white/15 mx-1" />
            </>
          )}

          <a
            href={apiClient.originalMediaURL(asset.id, true)}
            download={asset.fileName}
            title="下载原文件"
            className="charkle-pressable h-7.5 w-7.5 rounded-full hover:bg-white/12 text-white/85 flex items-center justify-center"
          >
            <Download size={14} />
          </a>

          <button
            type="button"
            title="切换右侧信息面板"
            onClick={() => setSidePanelOpen((v) => !v)}
            className={[
              'charkle-pressable h-7.5 w-7.5 rounded-full flex items-center justify-center cursor-pointer',
              sidePanelOpen ? 'bg-white/22 text-white' : 'hover:bg-white/12 text-white/85',
            ].join(' ')}
          >
            <Info size={14} />
          </button>

          <button
            type="button"
            title="关闭 (Space / Esc)"
            onClick={closeQuickLook}
            className="charkle-pressable h-7.5 w-7.5 rounded-full hover:bg-white/16 text-white flex items-center justify-center cursor-pointer"
          >
            <X size={15} />
          </button>
        </div>
      </div>

      {/* Main Media Stage + Optional Side Panel */}
      <div className="relative z-10 flex-1 min-h-0 flex items-center justify-center px-14 py-3 gap-4 overflow-hidden">
        {/* Left/Right Navigation Chevrons */}
        {currentIndex > 0 && (
          <button
            type="button"
            onClick={() => stepTo(-1)}
            aria-label="上一项"
            style={{ opacity: chromeVisible ? 1 : 0 }}
            className="charkle-pressable charkle-glass-dark absolute left-4 top-1/2 -translate-y-1/2 z-20 h-10 w-10 rounded-full flex items-center justify-center text-white cursor-pointer transition-opacity duration-[180ms]"
          >
            <ChevronLeft size={20} />
          </button>
        )}
        {currentIndex >= 0 && currentIndex < assets.length - 1 && (
          <button
            type="button"
            onClick={() => stepTo(1)}
            aria-label="下一项"
            style={{ opacity: chromeVisible ? 1 : 0 }}
            className="charkle-pressable charkle-glass-dark absolute right-4 top-1/2 -translate-y-1/2 z-20 h-10 w-10 rounded-full flex items-center justify-center text-white cursor-pointer transition-opacity duration-[180ms]"
          >
            <ChevronRight size={20} />
          </button>
        )}

        {/* Dedicated 8-Media-Type Viewer Switch */}
        <div
          className="flex-1 min-w-0 h-full flex items-center justify-center overflow-hidden"
          onWheel={
            isVisualImage
              ? (e) => {
                  e.preventDefault();
                  const factor = e.deltaY < 0 ? 1.12 : 0.9;
                  setZoom((z) => {
                    const next = Math.max(0.5, Math.min(5, Number((z * factor).toFixed(2))));
                    if (next <= 1.01) setPan({ x: 0, y: 0 });
                    return next;
                  });
                }
              : undefined
          }
          onClick={(e) => {
            if (e.target === e.currentTarget) closeQuickLook();
          }}
        >
          {githubRepo ? (
            <GitHubRepoViewer asset={asset} repo={githubRepo} />
          ) : socialPost ? (
            <SocialPostViewer asset={asset} post={socialPost} />
          ) : isSwatch ? (
            <ColorSwatchViewer asset={asset} />
          ) : isAudio ? (
            <AudioStudioViewer asset={asset} />
          ) : isModel3D ? (
            <React.Suspense
              fallback={
                <div className="w-[min(960px,92vw)] h-[min(640px,76vh)] rounded-[var(--radius-dock-outer)] bg-[#181A20] flex items-center justify-center text-white text-[13px] gap-2">
                  <span className="h-4 w-4 rounded-full border-2 border-[#5B8DEF] border-t-transparent animate-spin" />
                  正在初始化 3D 预览引擎…
                </div>
              }
            >
              <LazyModel3DViewer asset={asset} />
            </React.Suspense>
          ) : isDocument ? (
            <DocumentMarkdownViewer asset={asset} />
          ) : isVideo ? (
            <video
              key={asset.id}
              src={apiClient.originalMediaURL(asset.id)}
              poster={apiClient.thumbnailURL(asset.id, 'preview1400', cacheBust)}
              controls
              autoPlay
              playsInline
              className="max-w-full max-h-full rounded-[var(--radius-card-outer)] shadow-2xl"
            />
          ) : isWebBookmark ? (
            <div className="w-[min(620px,90vw)] rounded-[var(--radius-dock-outer)] overflow-hidden bg-[var(--bg-elevated)] border border-[var(--border-hairline)] shadow-2xl flex flex-col">
              <img
                src={apiClient.thumbnailURL(asset.id, 'preview1400', cacheBust)}
                alt={asset.title}
                className="w-full max-h-[360px] object-cover bg-[var(--bg-subtle)]"
              />
              <div className="p-5 flex flex-col gap-2">
                <span className="text-[11px] font-mono text-[var(--text-tertiary)]">
                  {asset.sourceDomain || 'WEB BOOKMARK'}
                </span>
                <h3 className="text-[16px] font-semibold text-[var(--text-primary)]">
                  {asset.title}
                </h3>
                {asset.notes && (
                  <p className="text-[13px] text-[var(--text-secondary)] leading-relaxed">
                    {asset.notes}
                  </p>
                )}
                {asset.sourceURL && (
                  <div className="pt-2">
                    <a
                      href={asset.sourceURL}
                      target="_blank"
                      rel="noreferrer"
                      className="charkle-pressable h-9 px-4 inline-flex items-center gap-1.5 rounded-[var(--radius-dock-inner)] bg-[var(--accent)] text-white text-[13px] font-medium"
                    >
                      <ExternalLink size={14} />
                      在浏览器打开
                    </a>
                  </div>
                )}
              </div>
            </div>
          ) : (
            /* Image / Animated GIF / Design File with smooth zoom, pan, rotate & flip */
            <img
              key={asset.id}
              src={
                asset.mediaKind === 'animatedImage'
                  ? apiClient.originalMediaURL(asset.id)
                  : apiClient.thumbnailURL(asset.id, 'preview1400', `${asset.updatedAt}-${cacheBust}`)
              }
              alt={asset.title}
              draggable={false}
              onDoubleClick={() => {
                setZoom((z) => {
                  const next = z > 1.1 ? 1 : 2;
                  if (next === 1) setPan({ x: 0, y: 0 });
                  return next;
                });
              }}
              onMouseDown={(e) => {
                if (zoom <= 1.01) return;
                e.preventDefault();
                setDraggingPan(true);
                panOriginRef.current = { x: e.clientX, y: e.clientY, panX: pan.x, panY: pan.y };
                const onMove = (ev: MouseEvent) => {
                  setPan({
                    x: panOriginRef.current.panX + (ev.clientX - panOriginRef.current.x),
                    y: panOriginRef.current.panY + (ev.clientY - panOriginRef.current.y),
                  });
                };
                const onUp = () => {
                  setDraggingPan(false);
                  window.removeEventListener('mousemove', onMove);
                  window.removeEventListener('mouseup', onUp);
                };
                window.addEventListener('mousemove', onMove);
                window.addEventListener('mouseup', onUp);
              }}
              style={{
                transform: `translate3d(${pan.x}px, ${pan.y}px, 0) scale(${zoom * quarterFitScale}) rotate(${rotation}deg) scaleX(${flipH ? -1 : 1}) scaleY(${flipV ? -1 : 1})`,
                transition: draggingPan
                  ? 'none'
                  : 'transform 220ms var(--ease-out-strong)',
                cursor: zoom > 1.01 ? (draggingPan ? 'grabbing' : 'grab') : 'zoom-in',
              }}
              className="max-w-full max-h-full object-contain rounded-[var(--radius-card-outer)] shadow-2xl"
            />
          )}
        </div>

        {/* Collapsible Quick Look Info Rail (292px) */}
        {sidePanelOpen && (
          <div className="charkle-glass-dark w-[288px] max-h-full rounded-[var(--radius-dock-outer)] p-4 overflow-y-auto charkle-scroll flex flex-col gap-3 shrink-0">
            <div className="text-[13.5px] font-semibold text-white">{asset.title}</div>
            <div className="flex items-center gap-1">
              {[1, 2, 3, 4, 5].map((star) => (
                <button
                  key={star}
                  type="button"
                  onClick={() =>
                    void batchPatch(
                      createDefaultAssetBatchPatch([asset.id], {
                        rating: asset.rating === star ? 0 : star,
                      }),
                    )
                  }
                  className="p-0.5 cursor-pointer"
                >
                  <Star
                    size={15}
                    className={
                      asset.rating >= star ? 'fill-[#F2C14E] text-[#F2C14E]' : 'text-white/30'
                    }
                  />
                </button>
              ))}
            </div>

            {asset.dominantColors.length > 0 && (
              <div className="flex gap-1.5">
                {asset.dominantColors.slice(0, 6).map((c) => (
                  <button
                    key={c.hex}
                    type="button"
                    title={c.hex}
                    onClick={async () => {
                      await navigator.clipboard.writeText(c.hex).catch(() => {});
                      pushToast({ tone: 'info', message: `已复制 ${c.hex}` });
                    }}
                    className="flex-1 h-6 rounded-[6px] border border-white/20 cursor-pointer"
                    style={{ backgroundColor: c.hex }}
                  />
                ))}
              </div>
            )}

            {asset.tags.length > 0 && (
              <div className="flex flex-wrap gap-1">
                {asset.tags.map((t) => (
                  <span key={t} className="px-2 py-0.5 rounded-full bg-white/10 text-[11px] text-white/85">
                    #{t}
                  </span>
                ))}
              </div>
            )}

            {asset.notes && (
              <p className="text-[12px] text-white/75 leading-relaxed whitespace-pre-wrap">
                {asset.notes}
              </p>
            )}

            <div className="text-[11.5px] text-white/55 flex flex-col gap-1 pt-2 border-t border-white/10 font-mono">
              <div>文件名：{asset.fileName}</div>
              <div>大小：{formatBytes(asset.fileSizeBytes)}</div>
              {asset.pixelWidth > 0 && (
                <div>
                  分辨率：{asset.pixelWidth} × {asset.pixelHeight}
                </div>
              )}
            </div>
          </div>
        )}
      </div>

      {/* Bottom Floating Liquid Glass Filmstrip */}
      {assets.length > 1 && (
        <div
          className="relative z-20 pb-4 px-6 flex justify-center transition-opacity duration-[180ms] ease-[var(--ease-out)]"
          style={{ opacity: chromeVisible ? 1 : 0 }}
        >
          <div className="charkle-glass-dark max-w-[min(780px,92vw)] px-2.5 py-2 rounded-[var(--radius-dock-outer)] flex items-center gap-1.5 overflow-x-auto charkle-scroll">
            {assets.slice(Math.max(0, currentIndex - 15), Math.min(assets.length, currentIndex + 16)).map((item) => {
              const active = item.id === asset.id;
              const ratio = Math.max(0.65, Math.min(1.65, getCardEffectiveAspectRatio(item)));
              return (
                <button
                  key={item.id}
                  type="button"
                  onClick={() => {
                    selectAsset(item.id, 'replace');
                    openQuickLook(item.id);
                  }}
                  style={{ width: Math.round(44 * ratio), height: 44 }}
                  className={[
                    'shrink-0 overflow-hidden rounded-[8px] cursor-pointer transition-opacity',
                    active ? 'ring-2 ring-white opacity-100' : 'opacity-50 hover:opacity-85',
                  ].join(' ')}
                >
                  <img
                    src={apiClient.thumbnailURL(item.id, 'grid520', cacheBust)}
                    alt={item.title}
                    className="w-full h-full object-cover"
                  />
                </button>
              );
            })}
          </div>
        </div>
      )}
    </div>,
    document.body,
  );
};
