import React, { useEffect, useRef, useState } from 'react';
import {
  ArrowDownload16Regular,
  ArrowUndo16Regular,
  ArrowUpRight16Regular,
  Board16Regular,
  Chat16Regular,
  Checkmark16Regular,
  ChevronRight16Regular,
  Cloud16Regular,
  Code16Regular,
  Color16Regular,
  Copy16Regular,
  Cube16Regular,
  Delete16Regular,
  DocumentText16Regular,
  Eye16Regular,
  FolderArrowRight16Regular,
  FolderOpen16Regular,
  Image20Regular,
  Open16Regular,
  Play16Filled,
  SoundWaveCircle16Regular,
  Sparkle16Regular,
  SpeakerOff16Regular,
  Star16Filled,
} from '@fluentui/react-icons';
import { getTransport, isTauriRuntime } from '../../api/transport';
import {
  Button,
  ModalShell,
  Popover,
  formatDuration,
  getGitHubLanguageColor,
  isLightHex,
} from '../../design-system';
import {
  useCoordinatorStore,
  useLibraryStore,
  useMoodboardStore,
} from '../../stores';
import {
  formatSocialDisplayHandle,
  resolveSocialMediaUrl,
  type AssetRecord,
} from '../../types/domain';
import { useDndStore } from '../dnd/dndStore';
import { beginPointerDrag, wasRecentPointerDrag } from '../dnd/PointerDragContext';
import { FolderMoveMenu } from '../sidebar/FolderMoveMenu';

export interface AssetCardProps {
  asset: AssetRecord;
  selected: boolean;
  spotlighted?: boolean;
  orderedIds: string[];
  width: number;
  height: number;
  style?: React.CSSProperties;
  onHoverChange?: (assetId: string, hovering: boolean) => void;
  cardRefCallback?: (assetId: string, el: HTMLDivElement | null) => void;
}

function fileExtensionBadge(fileName: string): string {
  const idx = fileName.lastIndexOf('.');
  if (idx < 0 || idx === fileName.length - 1) return 'FILE';
  return fileName.slice(idx + 1).toUpperCase().slice(0, 6);
}

function resolveMediaBadgeText(asset: AssetRecord): string | null {
  switch (asset.mediaKind) {
    case 'image':
      return null;
    case 'animatedImage':
      return 'GIF';
    case 'video':
      return asset.durationSeconds ? formatDuration(asset.durationSeconds) : 'VIDEO';
    case 'audio':
      return 'AUDIO';
    case 'webBookmark':
      if (asset.richMetadata?.githubRepo) return 'GITHUB';
      if (asset.richMetadata?.socialPost) {
        if (asset.richMetadata.socialPost.platform === 'xiaohongshu') return '小红书';
        return asset.richMetadata.socialPost.platform.toUpperCase();
      }
      return 'WEB';
    case 'document':
      return asset.fileName.toLowerCase().endsWith('.swatch')
        ? null
        : fileExtensionBadge(asset.fileName);
    case 'designFile':
      return fileExtensionBadge(asset.fileName);
    case 'model3D':
      return asset.richMetadata?.model3DFormat?.toUpperCase() || '3D';
  }
}

function fallbackWaveformPeaks(seedStr: string): number[] {
  const out: number[] = [];
  for (let i = 0; i < 24; i++) {
    const code = seedStr.charCodeAt(i % Math.max(1, seedStr.length)) || 64;
    const envelope = Math.sin((i / 23) * Math.PI);
    out.push(0.2 + 0.72 * envelope * (0.45 + 0.55 * ((code % 37) / 37)));
  }
  return out;
}

/**
 * Borderless gallery-first AssetCard matching macOS `VirtualizedMasonryView.swift` & `HoverMediaPreview.swift`:
 * - Pure artwork first; zero permanent chrome below cards
 * - 140ms hover dwell debounce + cached-only muted video/GIF preview with zero black-frame flash
 * - Procedural 7-kind cards (Swatch, GitHub, Social Post, Audio waveform, Markdown/Doc, Web Bookmark, Design/3D)
 * - Pointer-Event drag to Sidebar/Moodboards + Win32 OLE outbound drag
 * - Full macOS right-click context menu with Color HEX copy & irreversible delete confirmation
 */
export const AssetCard: React.FC<AssetCardProps> = ({
  asset,
  selected,
  spotlighted = false,
  orderedIds,
  width,
  height,
  style,
  onHoverChange,
  cardRefCallback,
}) => {
  const cardRef = useRef<HTMLDivElement | null>(null);
  const hoverDwellTimerRef = useRef<number | null>(null);

  const [hovered, setHovered] = useState(false);
  const [hoverDwellReady, setHoverDwellReady] = useState(false);
  const [hoverMediaReady, setHoverMediaReady] = useState(false);
  const [hoverPreviewFailed, setHoverPreviewFailed] = useState(false);
  const [imgFailed, setImgFailed] = useState(false);
  const [menuState, setMenuState] = useState<{
    x: number;
    y: number;
    targetIds: string[];
  } | null>(null);
  const [moveSubOpen, setMoveSubOpen] = useState(false);
  const [boardSubOpen, setBoardSubOpen] = useState(false);
  const [permDeleteIds, setPermDeleteIds] = useState<string[] | null>(null);

  const destination = useCoordinatorStore((s) => s.destination);
  const selectedAssetIds = useCoordinatorStore((s) => s.selectedAssetIds);
  const selectAsset = useCoordinatorStore((s) => s.selectAsset);
  const setSelection = useCoordinatorStore((s) => s.setSelection);
  const clearSelection = useCoordinatorStore((s) => s.clearSelection);
  const openQuickLook = useCoordinatorStore((s) => s.openQuickLook);
  const activeMoodboardId = useCoordinatorStore((s) => s.activeMoodboardId);
  const setMoodboardGeneratorOpen = useCoordinatorStore((s) => s.setMoodboardGeneratorOpen);
  const pushToast = useCoordinatorStore((s) => s.pushToast);

  const folders = useLibraryStore((s) => s.folders);
  const updateAssets = useLibraryStore((s) => s.updateAssets);
  const permanentlyDeleteAssets = useLibraryStore((s) => s.permanentlyDeleteAssets);

  const boards = useMoodboardStore((s) => s.boards);
  const addAssetsToBoard = useMoodboardStore((s) => s.addAssetsToBoard);

  const pointerDrag = useDndStore((s) => s.pointerDrag);
  const isBeingDragged =
    pointerDrag?.kind === 'assets' && pointerDrag.assetIds.includes(asset.id);

  useEffect(() => {
    setImgFailed(false);
    setHoverPreviewFailed(false);
    setHoverMediaReady(false);
  }, [asset.id, asset.updatedAt]);

  useEffect(() => {
    return () => {
      if (hoverDwellTimerRef.current !== null) {
        window.clearTimeout(hoverDwellTimerRef.current);
      }
    };
  }, []);

  const clearHoverDwell = () => {
    if (hoverDwellTimerRef.current !== null) {
      window.clearTimeout(hoverDwellTimerRef.current);
      hoverDwellTimerRef.current = null;
    }
    setHoverDwellReady(false);
    setHoverMediaReady(false);
  };

  const setMergedRef = (el: HTMLDivElement | null) => {
    cardRef.current = el;
    cardRefCallback?.(asset.id, el);
  };

  const transport = getTransport();
  const rawThumbUrl = transport.thumbnailUrl(asset.id, 'grid520');
  const thumbUrl =
    asset.updatedAt &&
    !rawThumbUrl.startsWith('data:') &&
    !rawThumbUrl.startsWith('blob:')
      ? `${rawThumbUrl}${rawThumbUrl.includes('?') ? '&' : '?'}v=${encodeURIComponent(String(asset.updatedAt))}`
      : rawThumbUrl;

  const gh = asset.richMetadata?.githubRepo;
  const social = asset.richMetadata?.socialPost;
  const isXiaohongshu = social?.platform === 'xiaohongshu';
  const isSwatch = asset.fileName.toLowerCase().endsWith('.swatch');
  const isAudio = asset.mediaKind === 'audio';
  const isMarkdownDoc = asset.mediaKind === 'document' && Boolean(asset.richMetadata?.textExcerpt);
  const isPlainWebBookmark = asset.mediaKind === 'webBookmark' && !gh && !social;

  const supportsHoverPlayback =
    !gh &&
    !social &&
    asset.isLocalOriginalCached &&
    (asset.mediaKind === 'video' || asset.mediaKind === 'animatedImage');

  const canHoverLivePreview =
    hovered && hoverDwellReady && !hoverPreviewFailed && supportsHoverPlayback;

  const cachedOriginalUrl = canHoverLivePreview
    ? transport.originalUrl(asset.id, { cachedOnly: true })
    : null;

  const targetIds =
    selected && selectedAssetIds.length > 1 ? selectedAssetIds : [asset.id];
  const menuTargetIds = menuState?.targetIds ?? targetIds;
  const menuCountSuffix = menuTargetIds.length > 1 ? ` (${menuTargetIds.length} 项)` : '';

  const pruneSelectionIds = (removedIds: readonly string[]) => {
    const removedSet = new Set(removedIds);
    const remaining = useCoordinatorStore
      .getState()
      .selectedAssetIds.filter((id) => !removedSet.has(id));
    if (remaining.length === 0) {
      clearSelection();
    } else {
      setSelection(remaining, remaining[0]);
    }
  };

  const primaryHex = asset.dominantColors[0]?.hex ?? null;
  const secondaryHex = asset.dominantColors[1]?.hex ?? null;
  const cardBackdropHex = primaryHex ?? (isAudio ? '#17191D' : '');
  const paletteHexes = asset.dominantColors
    .slice(0, 3)
    .map((swatch) => swatch.hex)
    .join(',');
  const rendersProceduralHeader =
    isSwatch ||
    Boolean(gh) ||
    (Boolean(social) && (!isXiaohongshu || imgFailed)) ||
    isAudio ||
    isMarkdownDoc ||
    (imgFailed && (asset.mediaKind === 'document' || isPlainWebBookmark));
  const mediaBadge = rendersProceduralHeader ? null : resolveMediaBadgeText(asset);
  const showHoverCaption =
    !isSwatch &&
    !gh &&
    !social &&
    !isAudio &&
    !isMarkdownDoc &&
    (asset.mediaKind === 'image' ||
      asset.mediaKind === 'animatedImage' ||
      asset.mediaKind === 'video');

  const bookmarkDomain = isPlainWebBookmark
    ? (asset.sourceDomain ??
      (() => {
        try {
          return asset.sourceURL
            ? new URL(asset.sourceURL).host.replace(/^www\./i, '')
            : 'web.link';
        } catch {
          return 'web.link';
        }
      })())
    : null;

  const handleOpenQuickLook = () => {
    clearHoverDwell();
    if (isPlainWebBookmark && asset.sourceURL) {
      void transport
        .openExternalUrl(asset.sourceURL)
        .then(() => {
          pushToast({
            message: `已在默认浏览器中打开 ${bookmarkDomain ?? '网页书签'}`,
            tone: 'info',
          });
        })
        .catch((err) => {
          pushToast({
            message: err instanceof Error ? err.message : '无法打开网页链接',
            tone: 'error',
          });
        });
      void transport.markAssetOpened(asset.id);
      return;
    }
    const rect = cardRef.current?.getBoundingClientRect();
    openQuickLook(
      asset.id,
      rect
        ? { left: rect.left, top: rect.top, width: rect.width, height: rect.height }
        : null,
    );
  };

  const renderProceduralFallback = () => {
    if (asset.mediaKind === 'video') {
      return (
        <div
          className="w-full h-full flex flex-col items-center justify-center gap-2"
          style={{
            background: `linear-gradient(180deg, ${primaryHex ?? '#2B2F36'}99 0%, #17191D 100%)`,
          }}
        >
          <div className="h-9 w-9 rounded-full bg-black/45 border border-white/25 flex items-center justify-center text-white">
            <Play16Filled className="w-4 h-4 translate-x-[1px]" />
          </div>
          {asset.durationSeconds ? (
            <span className="text-[11px] font-medium charkle-mono charkle-tabular text-white/80">
              {formatDuration(asset.durationSeconds)}
            </span>
          ) : null}
        </div>
      );
    }

    if (asset.mediaKind === 'designFile' || asset.mediaKind === 'model3D') {
      const ext =
        asset.mediaKind === 'model3D'
          ? asset.richMetadata?.model3DFormat?.toUpperCase() || '3D'
          : fileExtensionBadge(asset.fileName);
      const accentHex = primaryHex ?? '#5C6B73';
      return (
        <div className="w-full h-full relative flex flex-col items-center justify-center gap-2 p-3 bg-[var(--bg-elevated)]">
          <div
            aria-hidden="true"
            className="pointer-events-none absolute inset-3 border border-dashed border-black/[0.06] dark:border-white/[0.06] rounded-[var(--radius-card-inner)]"
          />
          <span
            className="px-2.5 py-1 rounded-[var(--radius-card-inner)] text-[12px] font-bold charkle-mono"
            style={{
              backgroundColor: accentHex,
              color: isLightHex(accentHex) ? 'rgba(0,0,0,0.86)' : '#ffffff',
            }}
          >
            {ext}
          </span>
          <span className="text-[11px] font-medium text-[var(--text-secondary)] truncate max-w-full">
            {asset.title}
          </span>
        </div>
      );
    }

    if (asset.mediaKind === 'document') {
      const ext = fileExtensionBadge(asset.fileName);
      return (
        <div className="w-full h-full p-3.5 flex flex-col justify-between bg-[var(--bg-elevated)]">
          <div className="flex items-center justify-between">
            <span className="px-1.5 py-0.5 rounded-[var(--win-radius-control)] bg-[var(--bg-subtle)] text-[10px] font-bold charkle-mono text-[var(--text-primary)]">
              {ext}
            </span>
            <DocumentText16Regular className="w-3.5 h-3.5 text-[var(--text-tertiary)]" />
          </div>
          <div className="my-2 flex-1 min-h-0 flex flex-col gap-1.5">
            <div className="text-[12.5px] font-semibold text-[var(--text-primary)] line-clamp-2">
              {asset.title}
            </div>
            {asset.notes ? (
              <p className="text-[11px] text-[var(--text-secondary)] line-clamp-3 leading-relaxed">
                {asset.notes}
              </p>
            ) : (
              <div className="flex flex-col gap-1.5 pt-1">
                <div className="h-[5px] rounded-full bg-black/[0.09] dark:bg-white/[0.10] w-full" />
                <div className="h-[5px] rounded-full bg-black/[0.07] dark:bg-white/[0.08] w-4/5" />
                <div className="h-[5px] rounded-full bg-black/[0.05] dark:bg-white/[0.06] w-3/5" />
              </div>
            )}
          </div>
        </div>
      );
    }

    if (isPlainWebBookmark) {
      const domain =
        asset.sourceDomain ??
        (() => {
          try {
            return asset.sourceURL ? new URL(asset.sourceURL).host : 'web.link';
          } catch {
            return 'web.link';
          }
        })();
      const accentHex = primaryHex ?? '#5C6B73';
      return (
        <div className="w-full h-full relative flex flex-col justify-between p-3.5 bg-[var(--bg-elevated)]">
          <div
            className="absolute inset-x-0 top-0 h-[3px]"
            style={{ backgroundColor: accentHex }}
          />
          <div className="flex items-center gap-1.5 min-w-0">
            <span
              className="h-2 w-2 rounded-full shrink-0"
              style={{ backgroundColor: accentHex }}
            />
            <span className="text-[11px] font-medium charkle-mono text-[var(--text-secondary)] truncate flex-1">
              {domain}
            </span>
            <ArrowUpRight16Regular className="w-3 h-3 text-[var(--text-tertiary)] shrink-0" />
          </div>
          <div className="my-auto py-1">
            <div className="text-[13px] font-semibold text-[var(--text-primary)] line-clamp-3 leading-snug">
              {asset.title}
            </div>
            {asset.notes && (
              <p className="mt-1 text-[11px] text-[var(--text-secondary)] line-clamp-2 leading-relaxed">
                {asset.notes}
              </p>
            )}
          </div>
        </div>
      );
    }

    // Editorial dominant-color placeholder for images/GIFs without raster
    const lightBg = isLightHex(primaryHex ?? '#DCDAD4');
    return (
      <div
        className="w-full h-full flex flex-col items-center justify-center gap-2 p-3 text-center"
        style={{
          background: `linear-gradient(135deg, ${primaryHex ?? '#DCDAD4'}E0 0%, ${secondaryHex ?? '#EAE8E2'}F0 100%)`,
          color: lightBg ? 'rgba(0,0,0,0.62)' : 'rgba(255,255,255,0.82)',
        }}
      >
        <Image20Regular className="w-5 h-5 opacity-70 shrink-0" />
        <span className="text-[11px] font-medium line-clamp-2 max-w-full break-words leading-snug">
          {asset.title}
        </span>
        {asset.dominantColors.length >= 2 && (
          <div className="flex items-center gap-1">
            {asset.dominantColors.slice(0, 4).map((swatch) => (
              <span
                key={swatch.hex}
                className="h-2 w-2 rounded-full border border-white/45"
                style={{ backgroundColor: swatch.hex }}
              />
            ))}
          </div>
        )}
      </div>
    );
  };

  return (
    <>
      <div
        ref={setMergedRef}
        role="button"
        tabIndex={0}
        aria-selected={selected}
        data-asset-id={asset.id}
        data-asset-card-id={asset.id}
        data-asset-hex={cardBackdropHex}
        data-asset-colors={paletteHexes || undefined}
        onPointerDown={(e) => {
          clearHoverDwell();
          if ((e.target as HTMLElement).closest('button')) return;
          beginPointerDrag(e, {
            kind: 'assets',
            assetIds: targetIds,
            previewAssetId: asset.id,
            title: asset.title,
          });
        }}
        onMouseEnter={() => {
          setHovered(true);
          setHoverPreviewFailed(false);
          onHoverChange?.(asset.id, true);
          if (supportsHoverPlayback) {
            if (hoverDwellTimerRef.current !== null) {
              window.clearTimeout(hoverDwellTimerRef.current);
            }
            hoverDwellTimerRef.current = window.setTimeout(() => {
              hoverDwellTimerRef.current = null;
              setHoverDwellReady(true);
            }, 140);
          }
        }}
        onMouseLeave={() => {
          setHovered(false);
          clearHoverDwell();
          onHoverChange?.(asset.id, false);
        }}
        onClick={(e) => {
          e.stopPropagation();
          if (wasRecentPointerDrag()) return;
          selectAsset(asset.id, orderedIds, {
            multi: e.ctrlKey || e.metaKey,
            range: e.shiftKey,
          });
        }}
        onDoubleClick={(e) => {
          e.stopPropagation();
          selectAsset(asset.id, orderedIds);
          handleOpenQuickLook();
        }}
        onContextMenu={(e) => {
          e.preventDefault();
          e.stopPropagation();
          clearHoverDwell();
          const latestSel = useCoordinatorStore.getState().selectedAssetIds;
          let snapshotIds: string[];
          if (latestSel.includes(asset.id) && latestSel.length > 1) {
            snapshotIds = [...latestSel];
          } else {
            if (!latestSel.includes(asset.id) || latestSel.length !== 1) {
              selectAsset(asset.id, orderedIds);
            }
            snapshotIds = [asset.id];
          }
          setMoveSubOpen(false);
          setBoardSubOpen(false);
          setMenuState({ x: e.clientX, y: e.clientY, targetIds: snapshotIds });
        }}
        onKeyDown={(e) => {
          if (e.key === 'Enter') {
            e.preventDefault();
            handleOpenQuickLook();
          }
        }}
        style={{
          width,
          height,
          ...style,
        }}
        className={[
          'group relative overflow-hidden rounded-[var(--win-radius-card)] bg-[var(--bg-elevated)] select-none cursor-pointer outline-none',
          'transition-[box-shadow] duration-[167ms] ease-[var(--win-ease-out)]',
          'focus-visible:ring-2 focus-visible:ring-[var(--accent)]',
          isBeingDragged ? 'opacity-45' : '',
          spotlighted ? 'charkle-spotlight-pulse' : '',
          selected
            ? 'ring-2 ring-[var(--accent)] shadow-[0_4px_14px_rgba(0,0,0,0.16)]'
            : 'ring-1 ring-[var(--win-stroke-card)] shadow-[0_1px_3px_rgba(0,0,0,0.06)] hover:ring-[var(--border-strong)] hover:shadow-[0_6px_16px_rgba(0,0,0,0.10)]',
        ].join(' ')}
      >
        {/* Primary media stage */}
        {isSwatch ? (
          (() => {
            const hex = (primaryHex ?? '#5C6B73').toUpperCase();
            const light = isLightHex(hex);
            return (
              <div
                className="w-full h-full flex flex-col justify-end p-3"
                style={{ backgroundColor: hex }}
              >
                <div
                  className="text-[13px] font-semibold charkle-mono leading-tight"
                  style={{ color: light ? 'rgba(0,0,0,0.84)' : 'rgba(255,255,255,0.92)' }}
                >
                  {hex}
                </div>
                {asset.title.toUpperCase() !== hex && (
                  <div
                    className="text-[11px] font-medium truncate mt-0.5"
                    style={{ color: light ? 'rgba(0,0,0,0.60)' : 'rgba(255,255,255,0.72)' }}
                  >
                    {asset.title}
                  </div>
                )}
              </div>
            );
          })()
        ) : gh ? (
          <div className="w-full h-full relative p-3.5 flex flex-col justify-between bg-[var(--bg-elevated)]">
            <div
              className="absolute inset-x-0 top-0 h-[3px]"
              style={{ backgroundColor: getGitHubLanguageColor(gh.language) }}
            />
            <div className="flex items-start justify-between gap-2">
              <div className="flex items-center gap-1.5 text-[11px] font-medium text-[var(--text-secondary)] min-w-0">
                <Code16Regular className="w-3.5 h-3.5 shrink-0" />
                <span className="truncate">{gh.owner}</span>
              </div>
              {gh.language && (
                <span className="inline-flex items-center gap-1 text-[11px] text-[var(--text-secondary)] shrink-0">
                  <span
                    className="h-2 w-2 rounded-full"
                    style={{ backgroundColor: getGitHubLanguageColor(gh.language) }}
                  />
                  {gh.language}
                </span>
              )}
            </div>
            <div className="my-auto py-1">
              <div className="text-[13.5px] font-semibold text-[var(--text-primary)] truncate">
                {gh.repo}
              </div>
              {gh.description && (
                <p className="mt-1 text-[11.5px] text-[var(--text-secondary)] line-clamp-3 leading-relaxed charkle-prose">
                  {gh.description}
                </p>
              )}
            </div>
            <div className="flex items-center justify-between text-[11px] text-[var(--text-tertiary)] charkle-tabular">
              <span>★ {gh.stars.toLocaleString()}</span>
              {gh.license && <span className="truncate max-w-[110px]">{gh.license}</span>}
            </div>
          </div>
        ) : isXiaohongshu && social ? (
          imgFailed ? (
            (() => {
              const avatarSrc = resolveSocialMediaUrl(social.authorAvatarURL, isTauriRuntime());
              const displayHandle = formatSocialDisplayHandle(social);
              return (
                <div className="w-full h-full relative p-3.5 flex flex-col justify-between bg-[var(--bg-elevated)]">
                  <div className="absolute inset-x-0 top-0 h-[3px] bg-[#FF2442]" />
                  <div className="flex items-center justify-between gap-2 pt-0.5">
                    <div className="flex items-center gap-1.5 min-w-0">
                      {avatarSrc ? (
                        <img
                          src={avatarSrc}
                          alt=""
                          draggable={false}
                          className="h-5 w-5 rounded-full object-cover shrink-0 bg-[var(--bg-subtle)]"
                        />
                      ) : (
                        <span className="h-5 w-5 rounded-full bg-[#FF2442] text-white text-[10px] font-bold inline-flex items-center justify-center shrink-0">
                          {(social.authorName || '小').slice(0, 1).toUpperCase()}
                        </span>
                      )}
                      <span className="text-[12px] font-semibold text-[var(--text-primary)] truncate">
                        {social.authorName}
                      </span>
                    </div>
                  </div>
                  <div className="my-auto py-1.5 flex flex-col gap-1">
                    <div className="text-[13px] font-semibold text-[var(--text-primary)] line-clamp-3 leading-snug">
                      {social.articleTitle || social.bodyText || asset.title}
                    </div>
                    {social.articleTitle && social.bodyText.trim() && (
                      <p className="text-[11px] text-[var(--text-secondary)] line-clamp-3 leading-relaxed charkle-prose">
                        {social.bodyText}
                      </p>
                    )}
                  </div>
                  <div className="flex items-center justify-between gap-2 text-[11px] text-[var(--text-tertiary)] charkle-tabular">
                    <span className="truncate">{displayHandle ?? social.authorName}</span>
                    {social.likeCount != null && (
                      <span className="shrink-0 font-medium text-[#FF2442]/90">
                        ♥ {social.likeCount.toLocaleString()}
                      </span>
                    )}
                  </div>
                </div>
              );
            })()
          ) : (
            <div
              className="w-full h-full relative"
              style={{
                backgroundColor: primaryHex ? `${primaryHex}40` : 'var(--bg-subtle)',
              }}
            >
              <img
                src={thumbUrl}
                alt={asset.title}
                loading="lazy"
                decoding="async"
                draggable={false}
                onError={() => setImgFailed(true)}
                className="w-full h-full object-cover charkle-media-zoom"
              />
            </div>
          )
        ) : social ? (
          (() => {
            const avatarSrc = resolveSocialMediaUrl(social.authorAvatarURL, isTauriRuntime());
            const displayHandle = formatSocialDisplayHandle(social);
            return (
              <div className="w-full h-full relative p-3.5 flex flex-col justify-between bg-[var(--bg-elevated)]">
                <div
                  className="absolute inset-x-0 top-0 h-[3px]"
                  style={{ backgroundColor: primaryHex ?? 'var(--accent)' }}
                />
                <div className="flex items-center justify-between gap-2">
                  <div className="flex items-center gap-2 min-w-0">
                    {avatarSrc ? (
                      <img
                        src={avatarSrc}
                        alt=""
                        draggable={false}
                        className="h-5 w-5 rounded-full object-cover shrink-0 bg-[var(--bg-subtle)]"
                      />
                    ) : null}
                    <span className="text-[12px] font-semibold text-[var(--text-primary)] truncate">
                      {social.authorName}
                    </span>
                  </div>
                  <Chat16Regular className="w-3.5 h-3.5 text-[var(--text-tertiary)] shrink-0" />
                </div>
                <p className="text-[12px] text-[var(--text-secondary)] line-clamp-4 leading-relaxed my-auto charkle-prose">
                  {social.bodyText}
                </p>
                {displayHandle && (
                  <div className="text-[11px] text-[var(--text-tertiary)] truncate">
                    {displayHandle}
                  </div>
                )}
              </div>
            );
          })()
        ) : isAudio ? (
          <div className="w-full h-full p-3.5 flex flex-col justify-between bg-[var(--bg-elevated)]">
            <div className="flex items-center justify-between text-[11px] text-[var(--text-secondary)]">
              <SoundWaveCircle16Regular
                className="w-4 h-4 shrink-0"
                style={{ color: primaryHex ?? 'var(--accent)' }}
              />
              {asset.durationSeconds ? (
                <span className="charkle-mono charkle-tabular">
                  {formatDuration(asset.durationSeconds)}
                </span>
              ) : null}
            </div>
            <div className="flex items-center gap-[2.5px] h-11 px-0.5">
              {(asset.waveformPeaks.length > 0
                ? asset.waveformPeaks.slice(0, 28)
                : fallbackWaveformPeaks(asset.id)
              ).map((peak, i) => {
                const amp = Math.max(0.16, Math.min(1, peak));
                return (
                  <span
                    key={i}
                    className="flex-1 rounded-full"
                    style={{
                      height: `${Math.round(amp * 100)}%`,
                      backgroundColor: primaryHex ?? 'var(--accent)',
                      opacity: 0.55 + amp * 0.45,
                    }}
                  />
                );
              })}
            </div>
            <div className="text-[12px] font-medium text-[var(--text-primary)] truncate">
              {asset.title}
            </div>
          </div>
        ) : isMarkdownDoc ? (
          <div className="w-full h-full p-3.5 flex flex-col justify-between bg-[var(--bg-elevated)]">
            <div className="flex items-center justify-between text-[11px] text-[var(--text-tertiary)]">
              <span className="px-1.5 py-0.5 rounded-[var(--win-radius-control)] bg-[var(--bg-subtle)] text-[10px] font-bold charkle-mono text-[var(--text-primary)]">
                {asset.richMetadata?.isMarkdown ? 'MD' : fileExtensionBadge(asset.fileName)}
              </span>
              <DocumentText16Regular className="w-3.5 h-3.5" />
            </div>
            <div className="my-1.5 flex-1 min-h-0 overflow-hidden">
              <div className="text-[12.5px] font-semibold text-[var(--text-primary)] truncate mb-1">
                {asset.title}
              </div>
              <p className="text-[11px] text-[var(--text-secondary)] line-clamp-5 leading-relaxed whitespace-pre-wrap">
                {asset.richMetadata?.textExcerpt}
              </p>
            </div>
          </div>
        ) : imgFailed ? (
          renderProceduralFallback()
        ) : (
          <div
            className="w-full h-full relative"
            style={{
              backgroundColor: primaryHex ? `${primaryHex}40` : 'var(--bg-subtle)',
            }}
          >
            <img
              src={thumbUrl}
              alt={asset.title}
              loading="lazy"
              decoding="async"
              draggable={false}
              onError={() => setImgFailed(true)}
              className="w-full h-full object-cover charkle-media-zoom"
            />

            {/* Strictly cached-only muted hover live preview (140ms dwell debounce + zero black-frame flash) */}
            {canHoverLivePreview && cachedOriginalUrl && asset.mediaKind === 'video' && (
              <>
                <video
                  src={cachedOriginalUrl}
                  muted
                  loop
                  autoPlay
                  playsInline
                  onLoadedData={() => setHoverMediaReady(true)}
                  onCanPlay={() => setHoverMediaReady(true)}
                  onError={() => setHoverPreviewFailed(true)}
                  className={[
                    'absolute inset-0 w-full h-full object-cover transition-opacity duration-150',
                    hoverMediaReady ? 'opacity-100' : 'opacity-0',
                  ].join(' ')}
                />
                {hoverMediaReady && width >= 92 && height >= 64 && (
                  <span
                    aria-hidden="true"
                    className="pointer-events-none absolute top-1.5 right-1.5 z-10 h-5 w-5 rounded-full bg-black/55 text-white/90 inline-flex items-center justify-center"
                  >
                    <SpeakerOff16Regular className="w-3 h-3" />
                  </span>
                )}
              </>
            )}
            {canHoverLivePreview && cachedOriginalUrl && asset.mediaKind === 'animatedImage' && (
              <img
                src={cachedOriginalUrl}
                alt={asset.title}
                onLoad={() => setHoverMediaReady(true)}
                onError={() => setHoverPreviewFailed(true)}
                className={[
                  'absolute inset-0 w-full h-full object-cover transition-opacity duration-150',
                  hoverMediaReady ? 'opacity-100' : 'opacity-0',
                ].join(' ')}
              />
            )}

            {/* Plain web bookmark domain pill + external-link indicator on hover */}
            {isPlainWebBookmark && bookmarkDomain && (
              <div className="pointer-events-none absolute inset-x-2 bottom-2 flex items-center justify-between gap-1.5">
                <span className="max-w-[calc(100%-26px)] h-[20px] px-2 rounded-[var(--win-radius-control)] bg-black/78 border border-white/15 text-white/95 text-[10px] font-medium charkle-mono inline-flex items-center gap-1.5 truncate">
                  <span
                    className="h-1.5 w-1.5 rounded-full shrink-0"
                    style={{ backgroundColor: primaryHex ?? '#74A9FF' }}
                  />
                  <span className="truncate">{bookmarkDomain}</span>
                </span>
                <span
                  aria-hidden="true"
                  className="h-[20px] w-[20px] rounded-[var(--win-radius-control)] bg-black/78 border border-white/15 text-white/95 inline-flex items-center justify-center shrink-0 opacity-0 group-hover:opacity-100 transition-opacity duration-150"
                >
                  <ArrowUpRight16Regular className="w-3 h-3" />
                </span>
              </div>
            )}
          </div>
        )}

        {/* Top-left selection checkbox (22x22) */}
        <button
          type="button"
          aria-label={selected ? '取消选中' : '选中素材'}
          onClick={(e) => {
            e.stopPropagation();
            selectAsset(asset.id, orderedIds, { multi: true });
          }}
          className={[
            'charkle-pressable absolute top-1.5 left-1.5 h-[22px] w-[22px] rounded-[var(--win-radius-control)] inline-flex items-center justify-center cursor-pointer border',
            selected
              ? 'bg-[var(--accent)] border-white/45 text-[var(--accent-text)] opacity-100 charkle-micro-pop'
              : 'bg-black/42 border-white/65 text-white opacity-0 group-hover:opacity-100',
          ].join(' ')}
        >
          {selected && <Checkmark16Regular className="w-3.5 h-3.5" />}
        </button>

        {/* Top-right compact media & offline pin badges (hidden under active video muted pill) */}
        {!(canHoverLivePreview && hoverMediaReady && asset.mediaKind === 'video') && (
          <div className="pointer-events-none absolute top-1.5 right-1.5 flex items-center gap-1">
            {asset.pinnedOffline && (
              <span
                title="已始终保留在本地"
                className="h-[18px] w-[18px] rounded-[var(--win-radius-control)] bg-black/52 border border-white/20 text-white/92 inline-flex items-center justify-center"
              >
                <ArrowDownload16Regular className="w-3 h-3" />
              </span>
            )}
            {mediaBadge && (
              <span
                className={[
                  'h-5 px-1.5 rounded-[var(--win-radius-control)] text-[10px] font-semibold charkle-tabular inline-flex items-center gap-0.5',
                  isXiaohongshu
                    ? 'bg-[#FF2442] text-white shadow-[0_1px_4px_rgba(255,36,66,0.35)]'
                    : 'bg-black/56 text-white/95 charkle-mono',
                ].join(' ')}
              >
                {asset.mediaKind === 'model3D' && <Cube16Regular className="w-2.5 h-2.5" />}
                {mediaBadge}
              </span>
            )}
          </div>
        )}

        {/* Bottom calm gradient title & star caption on hover (images, GIFs, videos) */}
        {showHoverCaption && (
          <div className="pointer-events-none absolute inset-x-0 bottom-0 px-2.5 pt-5 pb-1.5 bg-gradient-to-t from-black/65 via-black/22 to-transparent opacity-0 group-hover:opacity-100 transition-opacity duration-150 flex items-end justify-between gap-2">
            <span className="text-[11px] font-medium text-white truncate">{asset.title}</span>
            {asset.rating > 0 && (
              <span className="inline-flex items-center gap-0.5 text-[10px] font-semibold text-[#F2C14E] shrink-0 charkle-tabular">
                <Star16Filled className="w-2.5 h-2.5" />
                {asset.rating}
              </span>
            )}
          </div>
        )}
      </div>

      {/* Right-click Fluent 2 Acrylic context menu */}
      <Popover
        open={menuState !== null}
        onOpenChange={(open) => {
          if (!open) {
            setMenuState(null);
            setMoveSubOpen(false);
            setBoardSubOpen(false);
          }
        }}
        anchorPoint={menuState ? { x: menuState.x, y: menuState.y } : null}
        className="w-[244px] p-1"
      >
        <div className="flex flex-col gap-0.5 text-[13px] leading-[18px]">
          <button
            type="button"
            onClick={() => {
              setMenuState(null);
              handleOpenQuickLook();
            }}
            className="w-full min-h-[32px] px-2.5 py-1.5 flex items-center gap-2.5 text-left rounded-[var(--win-radius-control)] text-[var(--text-primary)] hover:bg-[var(--win-subtle-hover)] active:bg-[var(--win-subtle-active)] transition-colors duration-[83ms] ease-[var(--win-ease-out)] cursor-pointer"
          >
            <span className="w-4 h-4 inline-flex items-center justify-center shrink-0 text-[var(--text-secondary)]">
              {isPlainWebBookmark && asset.sourceURL ? (
                <Open16Regular className="w-4 h-4" />
              ) : (
                <Eye16Regular className="w-4 h-4" />
              )}
            </span>
            <span className="flex-1 min-w-0 truncate">
              {isPlainWebBookmark && asset.sourceURL ? '在默认浏览器中打开' : '快速预览'}
            </span>
            <kbd className="ml-auto pl-3 text-[11px] leading-[14px] text-[var(--text-tertiary)] charkle-mono shrink-0">
              Space
            </kbd>
          </button>

          <button
            type="button"
            onClick={() => {
              setMenuState(null);
              void transport.revealInExplorer(asset.id);
            }}
            className="w-full min-h-[32px] px-2.5 py-1.5 flex items-center gap-2.5 text-left rounded-[var(--win-radius-control)] text-[var(--text-primary)] hover:bg-[var(--win-subtle-hover)] active:bg-[var(--win-subtle-active)] transition-colors duration-[83ms] ease-[var(--win-ease-out)] cursor-pointer"
          >
            <span className="w-4 h-4 inline-flex items-center justify-center shrink-0 text-[var(--text-secondary)]">
              <FolderOpen16Regular className="w-4 h-4" />
            </span>
            <span className="flex-1 min-w-0 truncate">在资源管理器中显示</span>
          </button>

          {asset.sourceURL && !isPlainWebBookmark && (
            <button
              type="button"
              onClick={() => {
                setMenuState(null);
                if (asset.sourceURL) void transport.openExternalUrl(asset.sourceURL);
              }}
              className="w-full min-h-[32px] px-2.5 py-1.5 flex items-center gap-2.5 text-left rounded-[var(--win-radius-control)] text-[var(--text-primary)] hover:bg-[var(--win-subtle-hover)] active:bg-[var(--win-subtle-active)] transition-colors duration-[83ms] ease-[var(--win-ease-out)] cursor-pointer"
            >
              <span className="w-4 h-4 inline-flex items-center justify-center shrink-0 text-[var(--text-secondary)]">
                <Open16Regular className="w-4 h-4" />
              </span>
              <span className="flex-1 min-w-0 truncate">打开来源网页</span>
            </button>
          )}

          {asset.isTrashed || destination.type === 'trash' ? (
            <>
              <div className="my-1 mx-2 h-px bg-[var(--win-stroke-divider)]" />
              <button
                type="button"
                onClick={() => {
                  const ids = [...menuTargetIds];
                  setMenuState(null);
                  pruneSelectionIds(ids);
                  void updateAssets({ assetIDs: ids, isTrashed: false }, destination).then(() =>
                    pushToast({
                      message: `已将 ${ids.length} 项放回原处`,
                      tone: 'success',
                    }),
                  );
                }}
                className="w-full min-h-[32px] px-2.5 py-1.5 flex items-center gap-2.5 text-left rounded-[var(--win-radius-control)] text-[var(--text-primary)] hover:bg-[var(--win-subtle-hover)] active:bg-[var(--win-subtle-active)] transition-colors duration-[83ms] ease-[var(--win-ease-out)] cursor-pointer"
              >
                <span className="w-4 h-4 inline-flex items-center justify-center shrink-0 text-[var(--text-secondary)]">
                  <ArrowUndo16Regular className="w-4 h-4" />
                </span>
                <span className="flex-1 min-w-0 truncate">放回原处{menuCountSuffix}</span>
              </button>
              <button
                type="button"
                onClick={() => {
                  const ids = [...menuTargetIds];
                  setMenuState(null);
                  setPermDeleteIds(ids);
                }}
                className="w-full min-h-[32px] px-2.5 py-1.5 flex items-center gap-2.5 text-left rounded-[var(--win-radius-control)] text-[var(--danger)] hover:bg-[var(--danger-soft)] transition-colors duration-[83ms] ease-[var(--win-ease-out)] cursor-pointer"
              >
                <span className="w-4 h-4 inline-flex items-center justify-center shrink-0 text-[var(--danger)]">
                  <Delete16Regular className="w-4 h-4" />
                </span>
                <span className="flex-1 min-w-0 truncate">彻底删除…{menuCountSuffix}</span>
              </button>
            </>
          ) : (
            <>
              <div className="my-1 mx-2 h-px bg-[var(--win-stroke-divider)]" />
              <button
                type="button"
                onClick={() => {
                  const ids = [...menuTargetIds];
                  setMenuState(null);
                  void transport
                    .copyAssetsToClipboard(ids)
                    .then((n) =>
                      pushToast({ message: `已拷贝 ${n} 项素材到剪贴板`, tone: 'success' }),
                    )
                    .catch((err) =>
                      pushToast({
                        message: err instanceof Error ? err.message : '拷贝素材失败',
                        tone: 'error',
                      }),
                    );
                }}
                className="w-full min-h-[32px] px-2.5 py-1.5 flex items-center gap-2.5 text-left rounded-[var(--win-radius-control)] text-[var(--text-primary)] hover:bg-[var(--win-subtle-hover)] active:bg-[var(--win-subtle-active)] transition-colors duration-[83ms] ease-[var(--win-ease-out)] cursor-pointer"
              >
                <span className="w-4 h-4 inline-flex items-center justify-center shrink-0 text-[var(--text-secondary)]">
                  <Copy16Regular className="w-4 h-4" />
                </span>
                <span className="flex-1 min-w-0 truncate">拷贝{menuCountSuffix}</span>
                <kbd className="ml-auto pl-3 text-[11px] leading-[14px] text-[var(--text-tertiary)] charkle-mono shrink-0">
                  Ctrl+C
                </kbd>
              </button>

              <div className="my-1 mx-2 h-px bg-[var(--win-stroke-divider)]" />

              {/* Moodboard action */}
              {boards.length > 0 ? (
                <div className="relative">
                  <button
                    type="button"
                    onClick={() => {
                      if (boards.length === 1) {
                        const ids = [...menuTargetIds];
                        setMenuState(null);
                        void addAssetsToBoard(boards[0].id, ids);
                      } else {
                        setBoardSubOpen((v) => !v);
                      }
                    }}
                    className="w-full min-h-[32px] px-2.5 py-1.5 flex items-center gap-2.5 text-left rounded-[var(--win-radius-control)] text-[var(--text-primary)] hover:bg-[var(--win-subtle-hover)] active:bg-[var(--win-subtle-active)] transition-colors duration-[83ms] ease-[var(--win-ease-out)] cursor-pointer"
                  >
                    <span className="w-4 h-4 inline-flex items-center justify-center shrink-0 text-[var(--text-secondary)]">
                      <Board16Regular className="w-4 h-4" />
                    </span>
                    <span className="flex-1 min-w-0 truncate">加入情绪板{menuCountSuffix}</span>
                    {boards.length > 1 && (
                      <ChevronRight16Regular className="w-3.5 h-3.5 text-[var(--text-tertiary)] shrink-0" />
                    )}
                  </button>
                  {boardSubOpen && boards.length > 1 && (
                    <div className="mt-1 pl-2 border-t border-[var(--win-stroke-divider)] pt-1 flex flex-col gap-0.5 max-h-[160px] overflow-y-auto charkle-scroll">
                      {boards.map((board) => (
                        <button
                          key={board.id}
                          type="button"
                          onClick={() => {
                            const ids = [...menuTargetIds];
                            setMenuState(null);
                            setBoardSubOpen(false);
                            void addAssetsToBoard(board.id, ids);
                          }}
                          className="w-full min-h-[30px] flex items-center justify-between gap-2 px-2 py-1 text-left text-[12.5px] rounded-[var(--win-radius-control)] text-[var(--text-primary)] hover:bg-[var(--win-subtle-hover)] cursor-pointer"
                        >
                          <span className="truncate">{board.title}</span>
                          {board.id === activeMoodboardId && (
                            <span className="text-[10.5px] text-[var(--accent)] shrink-0">活跃</span>
                          )}
                        </button>
                      ))}
                      <button
                        type="button"
                        onClick={() => {
                          setMenuState(null);
                          setBoardSubOpen(false);
                          setMoodboardGeneratorOpen(true);
                        }}
                        className="w-full min-h-[30px] flex items-center gap-1.5 px-2 py-1 text-left text-[12.5px] rounded-[var(--win-radius-control)] text-[var(--accent)] hover:bg-[var(--accent-soft)] cursor-pointer"
                      >
                        <Sparkle16Regular className="w-3.5 h-3.5 shrink-0" />
                        <span>快速生成新情绪板…</span>
                      </button>
                    </div>
                  )}
                </div>
              ) : (
                <button
                  type="button"
                  onClick={() => {
                    setMenuState(null);
                    setMoodboardGeneratorOpen(true);
                  }}
                  className="w-full min-h-[32px] px-2.5 py-1.5 flex items-center gap-2.5 text-left rounded-[var(--win-radius-control)] text-[var(--text-primary)] hover:bg-[var(--win-subtle-hover)] active:bg-[var(--win-subtle-active)] transition-colors duration-[83ms] ease-[var(--win-ease-out)] cursor-pointer"
                >
                  <span className="w-4 h-4 inline-flex items-center justify-center shrink-0 text-[var(--accent)]">
                    <Sparkle16Regular className="w-4 h-4" />
                  </span>
                  <span className="flex-1 min-w-0 truncate">快速生成情绪板…</span>
                </button>
              )}

              {/* Hierarchical folder move submenu */}
              <div className="relative">
                <button
                  type="button"
                  onClick={() => setMoveSubOpen((v) => !v)}
                  className="w-full min-h-[32px] px-2.5 py-1.5 flex items-center gap-2.5 text-left rounded-[var(--win-radius-control)] text-[var(--text-primary)] hover:bg-[var(--win-subtle-hover)] active:bg-[var(--win-subtle-active)] transition-colors duration-[83ms] ease-[var(--win-ease-out)] cursor-pointer"
                >
                  <span className="w-4 h-4 inline-flex items-center justify-center shrink-0 text-[var(--text-secondary)]">
                    <FolderArrowRight16Regular className="w-4 h-4" />
                  </span>
                  <span className="flex-1 min-w-0 truncate">移动到文件夹{menuCountSuffix}</span>
                  <ChevronRight16Regular className="w-3.5 h-3.5 text-[var(--text-tertiary)] shrink-0" />
                </button>
                {moveSubOpen && (
                  <div className="mt-1 pl-1 border-t border-[var(--win-stroke-divider)] pt-1">
                    <FolderMoveMenu
                      folders={folders}
                      currentFolderId={
                        menuTargetIds.length === 1 ? (asset.folderID ?? null) : undefined
                      }
                      onSelectFolder={(folderId) => {
                        const ids = [...menuTargetIds];
                        setMenuState(null);
                        setMoveSubOpen(false);
                        const folderName = folderId
                          ? folders.find((f) => f.id === folderId)?.name ?? '文件夹'
                          : '收件箱';
                        void updateAssets(
                          {
                            assetIDs: ids,
                            folderAssignment: folderId ? { folder: folderId } : 'inbox',
                          },
                          destination,
                          {
                            undoMessage: `已移动 ${ids.length} 项至「${folderName}」`,
                            undoPatch: {
                              assetIDs: ids,
                              folderAssignment: asset.folderID
                                ? { folder: asset.folderID }
                                : 'inbox',
                            },
                          },
                        );
                      }}
                    />
                  </div>
                )}
              </div>

              <button
                type="button"
                onClick={() => {
                  const ids = [...menuTargetIds];
                  setMenuState(null);
                  const nextPinned = !asset.pinnedOffline;
                  void updateAssets(
                    { assetIDs: ids, pinnedOffline: nextPinned },
                    destination,
                  ).then(() =>
                    pushToast({
                      message: nextPinned
                        ? ids.length > 1
                          ? `已将 ${ids.length} 项设为始终保留在本地`
                          : '已设为始终保留在本地'
                        : ids.length > 1
                          ? `已取消 ${ids.length} 项的始终保留`
                          : '已取消始终保留，将按需管理空间',
                      tone: 'info',
                    }),
                  );
                }}
                className="w-full min-h-[32px] px-2.5 py-1.5 flex items-center gap-2.5 text-left rounded-[var(--win-radius-control)] text-[var(--text-primary)] hover:bg-[var(--win-subtle-hover)] active:bg-[var(--win-subtle-active)] transition-colors duration-[83ms] ease-[var(--win-ease-out)] cursor-pointer"
              >
                <span className="w-4 h-4 inline-flex items-center justify-center shrink-0 text-[var(--text-secondary)]">
                  {asset.pinnedOffline ? (
                    <Cloud16Regular className="w-4 h-4" />
                  ) : (
                    <ArrowDownload16Regular className="w-4 h-4" />
                  )}
                </span>
                <span className="flex-1 min-w-0 truncate">
                  {asset.pinnedOffline
                    ? `取消始终保留在本地${menuCountSuffix}`
                    : `始终保留在本地${menuCountSuffix}`}
                </span>
              </button>

              {primaryHex && (
                <button
                  type="button"
                  onClick={() => {
                    const hexUpper = primaryHex.toUpperCase();
                    setMenuState(null);
                    void navigator.clipboard?.writeText(hexUpper);
                    pushToast({
                      message: `已复制色值 ${hexUpper}`,
                      tone: 'info',
                    });
                  }}
                  className="w-full min-h-[32px] px-2.5 py-1.5 flex items-center gap-2.5 text-left rounded-[var(--win-radius-control)] text-[var(--text-primary)] hover:bg-[var(--win-subtle-hover)] active:bg-[var(--win-subtle-active)] transition-colors duration-[83ms] ease-[var(--win-ease-out)] cursor-pointer"
                >
                  <span className="w-4 h-4 inline-flex items-center justify-center shrink-0 text-[var(--text-secondary)]">
                    <Color16Regular className="w-4 h-4" />
                  </span>
                  <span className="flex-1 min-w-0 truncate">
                    复制主色 {primaryHex.toUpperCase()}
                  </span>
                </button>
              )}

              <div className="my-1 mx-2 h-px bg-[var(--win-stroke-divider)]" />

              <button
                type="button"
                onClick={() => {
                  const ids = [...menuTargetIds];
                  setMenuState(null);
                  pruneSelectionIds(ids);
                  void updateAssets({ assetIDs: ids, isTrashed: true }, destination, {
                    undoMessage: `已移至回收站 (${ids.length} 项)`,
                    undoPatch: { assetIDs: ids, isTrashed: false },
                  });
                }}
                className="w-full min-h-[32px] px-2.5 py-1.5 flex items-center gap-2.5 text-left rounded-[var(--win-radius-control)] text-[var(--danger)] hover:bg-[var(--danger-soft)] transition-colors duration-[83ms] ease-[var(--win-ease-out)] cursor-pointer"
              >
                <span className="w-4 h-4 inline-flex items-center justify-center shrink-0 text-[var(--danger)]">
                  <Delete16Regular className="w-4 h-4" />
                </span>
                <span className="flex-1 min-w-0 truncate">移至回收站{menuCountSuffix}</span>
              </button>
            </>
          )}
        </div>
      </Popover>

      {/* Irreversible Permanent Delete Confirmation Modal (DESIGN.md §7.3) */}
      <ModalShell
        open={permDeleteIds !== null}
        onClose={() => setPermDeleteIds(null)}
        title={`彻底删除 ${permDeleteIds?.length ?? 0} 项素材？`}
        width="sm"
        footer={
          <>
            <Button variant="standard" onClick={() => setPermDeleteIds(null)}>
              取消
            </Button>
            <Button
              variant="danger"
              onClick={async () => {
                const ids = permDeleteIds ?? [];
                setPermDeleteIds(null);
                if (ids.length > 0) {
                  pruneSelectionIds(ids);
                  await permanentlyDeleteAssets(ids, destination);
                }
              }}
            >
              彻底删除
            </Button>
          </>
        }
      >
        <p className="text-[13px] text-[var(--text-secondary)] leading-relaxed charkle-prose">
          彻底删除后将无法从回收站恢复。
        </p>
      </ModalShell>
    </>
  );
};
