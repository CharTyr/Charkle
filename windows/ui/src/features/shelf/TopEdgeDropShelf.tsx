import React, { useCallback, useEffect, useMemo, useRef, useState } from 'react';
import {
  ArrowUpRight16Regular,
  ArrowUpload16Regular,
  Camera16Regular,
  CheckmarkCircle16Filled,
  ChevronDown16Regular,
  ChevronLeft16Regular,
  ChevronRight16Regular,
  ChevronUp16Regular,
  Clipboard16Regular,
  Copy16Regular,
  Dismiss16Regular,
  Eye16Regular,
  Grid16Regular,
  Link16Regular,
  Open16Regular,
  Pin16Filled,
  Pin16Regular,
  Search16Regular,
} from '@fluentui/react-icons';
import { getTransport, isTauriRuntime } from '../../api/transport';
import { CharkleBrandMark, CustomSelect, type SelectOption } from '../../design-system';
import {
  buildFolderTree,
  createDefaultFilterCriteria,
  flattenFolderTree,
  wireDateToMs,
  type AssetRecord,
  type ClipboardPreview,
  type FolderRecord,
  type MoodboardSummary,
  type ShelfDockEdge,
  type ShelfSettings,
  type ShelfTargetMode,
} from '../../types/domain';

const TOP_EAR_RADIUS = 12;
const BOTTOM_CORNER_RADIUS = 24;
const TOP_BAND_HEIGHT = 38;
const COMPACT_WIDTH = 668;
const COMPACT_HEIGHT = 330;
const FULL_WIDTH = 980;
const FULL_HEIGHT = 564;
const COLLAPSED_WIDTH = 228;
const COLLAPSED_HEIGHT = 36;
const SIDE_COMPACT_WIDTH = 344;
const SIDE_COMPACT_HEIGHT = 560;
const SIDE_FULL_WIDTH = 520;
const SIDE_FULL_HEIGHT = 700;
const SIDE_COLLAPSED_WIDTH = 36;
const SIDE_COLLAPSED_HEIGHT = 200;
const DRAG_OUT_THRESHOLD = 6;
const DRAG_OUT_MIN_HOLD_MS = 35;
const DRAG_OUT_FAST_THRESHOLD = 14;

function normalizeDockEdge(raw?: string | null): ShelfDockEdge {
  if (raw === 'left' || raw === 'right') return raw;
  return 'top';
}

/**
 * Exact SVG path matching macOS `NotchShellShape` for top bezel, plus mirrored concave-ear
 * bezel silhouettes for left and right screen-edge docking.
 */
function buildNotchShellPath(
  w: number,
  h: number,
  edge: ShelfDockEdge = 'top',
  earRadius = TOP_EAR_RADIUS,
  outerCorner = BOTTOM_CORNER_RADIUS,
): string {
  const k = 0.55228475;
  if (edge === 'left') {
    const ear = Math.min(earRadius, h * 0.25, w * 0.45);
    const cor = Math.min(outerCorner, Math.max(0, (h - ear * 2) * 0.5), Math.max(0, w - ear));
    return [
      `M 0 0`,
      `C 0 ${(ear * k).toFixed(2)} ${(ear * (1 - k)).toFixed(2)} ${ear.toFixed(2)} ${ear.toFixed(2)} ${ear.toFixed(2)}`,
      `L ${(w - cor).toFixed(2)} ${ear.toFixed(2)}`,
      `C ${(w - cor * (1 - k)).toFixed(2)} ${ear.toFixed(2)} ${w.toFixed(2)} ${(ear + cor * (1 - k)).toFixed(2)} ${w.toFixed(2)} ${(ear + cor).toFixed(2)}`,
      `L ${w.toFixed(2)} ${(h - ear - cor).toFixed(2)}`,
      `C ${w.toFixed(2)} ${(h - ear - cor * (1 - k)).toFixed(2)} ${(w - cor * (1 - k)).toFixed(2)} ${(h - ear).toFixed(2)} ${(w - cor).toFixed(2)} ${(h - ear).toFixed(2)}`,
      `L ${ear.toFixed(2)} ${(h - ear).toFixed(2)}`,
      `C ${(ear * (1 - k)).toFixed(2)} ${(h - ear).toFixed(2)} 0 ${(h - ear * k).toFixed(2)} 0 ${h.toFixed(2)}`,
      `Z`,
    ].join(' ');
  }

  if (edge === 'right') {
    const ear = Math.min(earRadius, h * 0.25, w * 0.45);
    const cor = Math.min(outerCorner, Math.max(0, (h - ear * 2) * 0.5), Math.max(0, w - ear));
    return [
      `M ${w.toFixed(2)} 0`,
      `C ${w.toFixed(2)} ${(ear * k).toFixed(2)} ${(w - ear * (1 - k)).toFixed(2)} ${ear.toFixed(2)} ${(w - ear).toFixed(2)} ${ear.toFixed(2)}`,
      `L ${cor.toFixed(2)} ${ear.toFixed(2)}`,
      `C ${(cor * (1 - k)).toFixed(2)} ${ear.toFixed(2)} 0 ${(ear + cor * (1 - k)).toFixed(2)} 0 ${(ear + cor).toFixed(2)}`,
      `L 0 ${(h - ear - cor).toFixed(2)}`,
      `C 0 ${(h - ear - cor * (1 - k)).toFixed(2)} ${(cor * (1 - k)).toFixed(2)} ${(h - ear).toFixed(2)} ${cor.toFixed(2)} ${(h - ear).toFixed(2)}`,
      `L ${(w - ear).toFixed(2)} ${(h - ear).toFixed(2)}`,
      `C ${(w - ear * (1 - k)).toFixed(2)} ${(h - ear).toFixed(2)} ${w.toFixed(2)} ${(h - ear * k).toFixed(2)} ${w.toFixed(2)} ${h.toFixed(2)}`,
      `Z`,
    ].join(' ');
  }

  const topR = Math.min(earRadius, w * 0.25, h * 0.45);
  const botR = Math.min(outerCorner, Math.max(0, (w - topR * 2) * 0.5), Math.max(0, h - topR));
  return [
    `M 0 0`,
    `C ${(topR * k).toFixed(2)} 0 ${topR.toFixed(2)} ${(topR * (1 - k)).toFixed(2)} ${topR.toFixed(2)} ${topR.toFixed(2)}`,
    `L ${topR.toFixed(2)} ${(h - botR).toFixed(2)}`,
    `C ${topR.toFixed(2)} ${(h - botR * (1 - k)).toFixed(2)} ${(topR + botR * (1 - k)).toFixed(2)} ${h.toFixed(2)} ${(topR + botR).toFixed(2)} ${h.toFixed(2)}`,
    `L ${(w - topR - botR).toFixed(2)} ${h.toFixed(2)}`,
    `C ${(w - topR - botR * (1 - k)).toFixed(2)} ${h.toFixed(2)} ${(w - topR).toFixed(2)} ${(h - botR * (1 - k)).toFixed(2)} ${(w - topR).toFixed(2)} ${(h - botR).toFixed(2)}`,
    `L ${(w - topR).toFixed(2)} ${topR.toFixed(2)}`,
    `C ${(w - topR).toFixed(2)} ${(topR * (1 - k)).toFixed(2)} ${(w - topR * k).toFixed(2)} 0 ${w.toFixed(2)} 0`,
    `Z`,
  ].join(' ');
}

function buildNotchRimPath(
  w: number,
  h: number,
  edge: ShelfDockEdge = 'top',
  earRadius = TOP_EAR_RADIUS,
  outerCorner = BOTTOM_CORNER_RADIUS,
): string {
  const k = 0.55228475;
  if (edge === 'left') {
    const ear = Math.min(earRadius, h * 0.25, w * 0.45);
    const cor = Math.min(outerCorner, Math.max(0, (h - ear * 2) * 0.5), Math.max(0, w - ear));
    const rw = w - 0.5;
    return [
      `M 0 0.5`,
      `C 0 ${(ear * k).toFixed(2)} ${(ear * (1 - k)).toFixed(2)} ${ear.toFixed(2)} ${ear.toFixed(2)} ${ear.toFixed(2)}`,
      `L ${(rw - cor).toFixed(2)} ${ear.toFixed(2)}`,
      `C ${(rw - cor * (1 - k)).toFixed(2)} ${ear.toFixed(2)} ${rw.toFixed(2)} ${(ear + cor * (1 - k)).toFixed(2)} ${rw.toFixed(2)} ${(ear + cor).toFixed(2)}`,
      `L ${rw.toFixed(2)} ${(h - ear - cor).toFixed(2)}`,
      `C ${rw.toFixed(2)} ${(h - ear - cor * (1 - k)).toFixed(2)} ${(rw - cor * (1 - k)).toFixed(2)} ${(h - ear).toFixed(2)} ${(rw - cor).toFixed(2)} ${(h - ear).toFixed(2)}`,
      `L ${ear.toFixed(2)} ${(h - ear).toFixed(2)}`,
      `C ${(ear * (1 - k)).toFixed(2)} ${(h - ear).toFixed(2)} 0 ${(h - ear * k).toFixed(2)} 0 ${(h - 0.5).toFixed(2)}`,
    ].join(' ');
  }

  if (edge === 'right') {
    const ear = Math.min(earRadius, h * 0.25, w * 0.45);
    const cor = Math.min(outerCorner, Math.max(0, (h - ear * 2) * 0.5), Math.max(0, w - ear));
    return [
      `M ${w.toFixed(2)} 0.5`,
      `C ${w.toFixed(2)} ${(ear * k).toFixed(2)} ${(w - ear * (1 - k)).toFixed(2)} ${ear.toFixed(2)} ${(w - ear).toFixed(2)} ${ear.toFixed(2)}`,
      `L ${(cor + 0.5).toFixed(2)} ${ear.toFixed(2)}`,
      `C ${(0.5 + cor * (1 - k)).toFixed(2)} ${ear.toFixed(2)} 0.5 ${(ear + cor * (1 - k)).toFixed(2)} 0.5 ${(ear + cor).toFixed(2)}`,
      `L 0.5 ${(h - ear - cor).toFixed(2)}`,
      `C 0.5 ${(h - ear - cor * (1 - k)).toFixed(2)} ${(0.5 + cor * (1 - k)).toFixed(2)} ${(h - ear).toFixed(2)} ${(cor + 0.5).toFixed(2)} ${(h - ear).toFixed(2)}`,
      `L ${(w - ear).toFixed(2)} ${(h - ear).toFixed(2)}`,
      `C ${(w - ear * (1 - k)).toFixed(2)} ${(h - ear).toFixed(2)} ${w.toFixed(2)} ${(h - ear * k).toFixed(2)} ${w.toFixed(2)} ${(h - 0.5).toFixed(2)}`,
    ].join(' ');
  }

  const topR = Math.min(earRadius, w * 0.25, h * 0.45);
  const botR = Math.min(outerCorner, Math.max(0, (w - topR * 2) * 0.5), Math.max(0, h - topR));
  return [
    `M 0.5 0`,
    `C ${(topR * k).toFixed(2)} 0 ${topR.toFixed(2)} ${(topR * (1 - k)).toFixed(2)} ${topR.toFixed(2)} ${topR.toFixed(2)}`,
    `L ${topR.toFixed(2)} ${(h - botR).toFixed(2)}`,
    `C ${topR.toFixed(2)} ${(h - botR * (1 - k)).toFixed(2)} ${(topR + botR * (1 - k)).toFixed(2)} ${(h - 0.5).toFixed(2)} ${(topR + botR).toFixed(2)} ${(h - 0.5).toFixed(2)}`,
    `L ${(w - topR - botR).toFixed(2)} ${(h - 0.5).toFixed(2)}`,
    `C ${(w - topR - botR * (1 - k)).toFixed(2)} ${(h - 0.5).toFixed(2)} ${(w - topR).toFixed(2)} ${(h - botR * (1 - k)).toFixed(2)} ${(w - topR).toFixed(2)} ${(h - botR).toFixed(2)}`,
    `L ${(w - topR).toFixed(2)} ${topR.toFixed(2)}`,
    `C ${(w - topR).toFixed(2)} ${(topR * (1 - k)).toFixed(2)} ${(w - topR * k).toFixed(2)} 0 ${(w - 0.5).toFixed(2)} 0`,
  ].join(' ');
}

function isPlainWebBookmark(asset: AssetRecord): boolean {
  return (
    asset.mediaKind === 'webBookmark' &&
    !asset.richMetadata?.githubRepo &&
    !asset.richMetadata?.socialPost &&
    Boolean(asset.sourceURL?.trim())
  );
}

function formatClipboardUrlPrompt(clip: ClipboardPreview): string {
  const rawUrl = (clip.url || clip.label || '').trim();
  let parsed: URL | null = null;
  try {
    parsed = new URL(rawUrl);
  } catch {
    parsed = null;
  }
  const host = parsed?.hostname.toLowerCase().replace(/^www\./, '') ?? '';
  const pathSegments = parsed
    ? parsed.pathname
        .split('/')
        .map((s) => s.trim())
        .filter(Boolean)
    : [];

  if (clip.isSocialOrGithubUrl || host === 'xiaohongshu.com' || host.endsWith('.xiaohongshu.com') || host === 'xhslink.com' || host.endsWith('.xhslink.com')) {
    if (host === 'github.com' && pathSegments.length >= 2) {
      const repo = pathSegments[1].replace(/\.git$/i, '');
      return `检测到 GitHub 仓库链接 · ${pathSegments[0]}/${repo}`;
    }
    if (
      host === 'xiaohongshu.com' ||
      host.endsWith('.xiaohongshu.com') ||
      host === 'xhslink.com' ||
      host.endsWith('.xhslink.com')
    ) {
      const compact = rawUrl.replace(/^https?:\/\/(www\.)?/i, '');
      return `检测到小红书链接 · ${compact || clip.label}`;
    }
    const compact = rawUrl.replace(/^https?:\/\/(www\.)?/i, '');
    return `检测到推文链接 · ${compact || clip.label}`;
  }

  return `检测到网页链接 · ${host || clip.label}`;
}

interface ShelfAssetThumbProps {
  asset: AssetRecord;
  rawThumbUrl: string;
  fixedHeight?: boolean;
}

const ShelfAssetThumb: React.FC<ShelfAssetThumbProps> = ({
  asset,
  rawThumbUrl,
  fixedHeight = false,
}) => {
  const thumbSrc =
    rawThumbUrl.startsWith('data:') || rawThumbUrl.startsWith('blob:')
      ? rawThumbUrl
      : `${rawThumbUrl}?v=${encodeURIComponent(String(asset.updatedAt))}`;
  const [imgFailed, setImgFailed] = useState(false);

  useEffect(() => {
    setImgFailed(false);
  }, [thumbSrc]);

  if (asset.fileName.toLowerCase().endsWith('.swatch')) {
    const hex = (asset.dominantColors[0]?.hex || '#2A60E0').toUpperCase();
    return (
      <div
        className={
          fixedHeight
            ? 'w-full h-full flex items-end p-1.5'
            : 'w-full aspect-[4/3] flex items-end p-2'
        }
        style={{ backgroundColor: hex }}
      >
        <span className="px-1.5 py-0.5 rounded-[5px] bg-black/48 text-[9.5px] font-medium charkle-mono text-white/95 truncate max-w-full">
          {hex}
        </span>
      </div>
    );
  }

  if (imgFailed) {
    return (
      <div
        className={[
          'w-full flex items-center justify-center p-2 text-center bg-white/[0.06] text-[10.5px] font-medium text-white/70',
          fixedHeight ? 'h-full' : 'aspect-[4/3]',
        ].join(' ')}
      >
        <span className="line-clamp-3 break-words">{asset.title}</span>
      </div>
    );
  }

  return (
    <img
      src={thumbSrc}
      alt={asset.title}
      draggable={false}
      onError={() => setImgFailed(true)}
      className={fixedHeight ? 'w-full h-full object-cover' : 'w-full h-auto block object-cover'}
      style={{ backgroundColor: asset.dominantColors[0]?.hex || undefined }}
    />
  );
};

export interface TopEdgeDropShelfProps {
  initialFullGallery?: boolean;
  initialExpanded?: boolean;
  initialDockEdge?: ShelfDockEdge;
}

/**
 * Pure-black Hardware Notch Drop Shelf (`shelf.html`) supporting top, left, and right screen-edge docking:
 * - Concave bezel-ear silhouette with directional rim gradient & capsule-only drop shadow
 * - Fluid `notchMorphSpring` expand/collapse from the docked screen edge & compact <-> full-waterfall morph
 * - Zero invented title bar text; exact wing controls (brand mark + Pin / Open Main / Close)
 * - Native Tauri v2 OS file/folder drop + threshold-guarded Win32 OLE `DoDragDrop` drag-out
 * - Full-Waterfall rubber-band marquee multi-select + live search
 */
export const TopEdgeDropShelf: React.FC<TopEdgeDropShelfProps> = ({
  initialFullGallery = false,
  initialExpanded,
  initialDockEdge,
}) => {
  const capsuleRef = useRef<HTMLDivElement | null>(null);
  const filmstripRef = useRef<HTMLDivElement | null>(null);
  const waterfallGridRef = useRef<HTMLDivElement | null>(null);

  const [expanded, setExpanded] = useState<boolean>(
    initialExpanded ?? !isTauriRuntime(),
  );
  const [fullGallery, setFullGallery] = useState(initialFullGallery);
  const fullGalleryRef = useRef(fullGallery);
  fullGalleryRef.current = fullGallery;
  const [dockEdge, setDockEdge] = useState<ShelfDockEdge>(normalizeDockEdge(initialDockEdge));
  const dockEdgeRef = useRef<ShelfDockEdge>(dockEdge);
  dockEdgeRef.current = dockEdge;
  const expandedRef = useRef(expanded);
  expandedRef.current = expanded;
  const [pinned, setPinned] = useState(false);
  const [minimalMode, setMinimalMode] = useState(false);
  const [targetMode, setTargetMode] = useState<ShelfTargetMode>('inbox');
  const [selectedFolderId, setSelectedFolderId] = useState<string>('');
  const [assets, setAssets] = useState<AssetRecord[]>([]);
  const [folders, setFolders] = useState<FolderRecord[]>([]);
  const [boards, setBoards] = useState<MoodboardSummary[]>([]);
  const [inboxCount, setInboxCount] = useState<number>(0);
  const [clipboard, setClipboard] = useState<ClipboardPreview | null>(null);
  const [selectedIds, setSelectedIds] = useState<string[]>([]);
  const [searchQuery, setSearchQuery] = useState('');
  const [htmlDragHovering, setHtmlDragHovering] = useState(false);
  const [nativeDragHover, setNativeDragHover] = useState<{ active: boolean; count: number }>({
    active: false,
    count: 0,
  });
  const [processingMessage, setProcessingMessage] = useState<string | null>(null);
  const [statusMessage, setStatusMessage] = useState<string | null>(null);
  const [dismissedClipboardLabel, setDismissedClipboardLabel] = useState<string | null>(null);
  const [marquee, setMarquee] = useState<{
    startX: number;
    startY: number;
    curX: number;
    curY: number;
  } | null>(null);
  const marqueeRef = useRef(marquee);
  marqueeRef.current = marquee;

  const shelfSettingsRef = useRef<ShelfSettings>({
    enabled: true,
    hoverTriggerEnabled: true,
    defaultTargetMode: 'inbox',
    defaultFolderId: null,
    minimalMode: false,
    dockEdge: normalizeDockEdge(initialDockEdge),
  });

  const isDropTargeted = htmlDragHovering || nativeDragHover.active;
  const dragItemCount = Math.max(1, nativeDragHover.count);

  const transport = getTransport();
  const bannerTimerRef = useRef<number | null>(null);
  const autoCollapseTimerRef = useRef<number | null>(null);
  const openingMainRef = useRef(false);
  const openingAssetRef = useRef(false);
  const startingCaptureRef = useRef(false);

  // Pitfall 5: Atomic timer cancellation clearing AND nulling handles across every transition
  // (hover, drag, banner, pin, hide, blur) so an unpinned shelf can NEVER wedge open.
  const clearBannerTimer = useCallback(() => {
    if (bannerTimerRef.current !== null) {
      window.clearTimeout(bannerTimerRef.current);
      bannerTimerRef.current = null;
    }
  }, []);

  const cancelAutoCollapse = useCallback(() => {
    if (autoCollapseTimerRef.current !== null) {
      window.clearTimeout(autoCollapseTimerRef.current);
      autoCollapseTimerRef.current = null;
    }
  }, []);

  const showBanner = useCallback(
    (msg: string) => {
      clearBannerTimer();
      cancelAutoCollapse();
      setStatusMessage(msg);
      bannerTimerRef.current = window.setTimeout(() => {
        setStatusMessage((prev) => (prev === msg ? null : prev));
        bannerTimerRef.current = null;
      }, 2400);
    },
    [clearBannerTimer, cancelAutoCollapse],
  );

  useEffect(() => {
    const onBlur = () => {
      cancelAutoCollapse();
    };
    window.addEventListener('blur', onBlur);
    return () => {
      window.removeEventListener('blur', onBlur);
      clearBannerTimer();
      cancelAutoCollapse();
    };
  }, [clearBannerTimer, cancelAutoCollapse]);

  const refreshData = useCallback(async () => {
    try {
      const [fetchedAssets, fetchedFolders, fetchedBoards, clip, inbox] =
        await Promise.all([
          transport.fetchAssets(createDefaultFilterCriteria({ sortBy: 'newest' })),
          transport.fetchFolders(),
          transport.fetchBoards(),
          transport.getClipboardPreview(),
          transport.inboxCount(),
        ]);
      // Match macOS `recentActivityAssets()` ranking recently saved + recently opened assets
      const ranked = [...fetchedAssets].sort((a, b) => {
        const aTime = Math.max(
          wireDateToMs(a.lastOpenedAt),
          wireDateToMs(a.createdAt),
        );
        const bTime = Math.max(
          wireDateToMs(b.lastOpenedAt),
          wireDateToMs(b.createdAt),
        );
        return bTime - aTime;
      });
      setAssets(ranked);
      setFolders(fetchedFolders);
      setBoards(fetchedBoards);
      setClipboard(clip);
      setInboxCount(inbox);
      setSelectedFolderId((prev) => {
        if (prev && fetchedFolders.some((f) => f.id === prev)) return prev;
        return fetchedFolders[0]?.id ?? '';
      });
    } catch {
      // Ignore transient background refresh errors
    }
  }, [transport]);

  const resolvedTargets = useMemo(() => {
    const folderId = targetMode === 'folder' && selectedFolderId ? selectedFolderId : null;
    const boardId = targetMode === 'activeMoodboard' ? (boards[0]?.id ?? null) : null;
    return { folderId, boardId };
  }, [targetMode, selectedFolderId, boards]);

  const resolvedTargetsRef = useRef(resolvedTargets);
  resolvedTargetsRef.current = resolvedTargets;

  const openMainWindowAndCollapse = useCallback(() => {
    if (openingMainRef.current) return;
    openingMainRef.current = true;
    cancelAutoCollapse();
    const tasks: Promise<unknown>[] = [transport.openMainWindow().catch(() => {})];
    if (isTauriRuntime()) {
      tasks.push(transport.hideShelf().catch(() => {}));
    }
    void Promise.all(tasks).finally(() => {
      window.setTimeout(() => {
        openingMainRef.current = false;
      }, 280);
    });
  }, [transport, cancelAutoCollapse]);

  const openFullGallery = useCallback(() => {
    if (minimalMode) {
      openMainWindowAndCollapse();
      return;
    }
    cancelAutoCollapse();
    setFullGallery(true);
    setPinned(true);
    void transport.setShelfPinned(true).catch(() => {});
    void transport.setShelfAllowActivate(true).catch(() => {});
  }, [transport, minimalMode, cancelAutoCollapse, openMainWindowAndCollapse]);

  const closeFullGallery = useCallback(() => {
    setSelectedIds([]);
    setSearchQuery('');
    setFullGallery(false);
    void transport.setShelfAllowActivate(false).catch(() => {});
  }, [transport]);

  const openShelfAsset = useCallback(
    (asset: AssetRecord) => {
      if (openingAssetRef.current) return;
      openingAssetRef.current = true;
      const done = () => {
        window.setTimeout(() => {
          openingAssetRef.current = false;
        }, 240);
      };
      if (isPlainWebBookmark(asset) && asset.sourceURL) {
        const tasks: Promise<unknown>[] = [
          transport.openExternalUrl(asset.sourceURL).catch(() => {}),
          transport.markAssetOpened(asset.id).catch(() => {}),
        ];
        if (isTauriRuntime()) {
          tasks.push(transport.hideShelf().catch(() => {}));
        }
        void Promise.all(tasks).finally(done);
        return;
      }
      void transport
        .openAssetInMainWindow(asset.id, true)
        .catch(() => {})
        .finally(done);
    },
    [transport],
  );

  const handleStartRegionCapture = useCallback(() => {
    if (startingCaptureRef.current) return;
    startingCaptureRef.current = true;
    const { folderId, boardId } = resolvedTargetsRef.current;
    void transport
      .startRegionCapture(folderId, boardId)
      .catch((err) => {
        showBanner(err instanceof Error && err.message ? err.message : '无法启动区域截图');
      })
      .finally(() => {
        window.setTimeout(() => {
          startingCaptureRef.current = false;
        }, 320);
      });
  }, [transport, showBanner]);

  const persistTargetSelection = useCallback(
    (nextMode: ShelfTargetMode, nextFolderId: string) => {
      const next: ShelfSettings = {
        ...shelfSettingsRef.current,
        defaultTargetMode: nextMode,
        defaultFolderId: nextFolderId || null,
        dockEdge: dockEdgeRef.current,
      };
      shelfSettingsRef.current = next;
      void transport.saveShelfSettings(next).catch(() => {});
    },
    [transport],
  );

  // Sync settled target capsule bounds (+ any open portaled folder Popover) to Win32 WM_NCHITTEST
  // so outside pixels stay click-through while dropdowns and expanded drawers remain 100% interactive.
  const reportHitRectFor = useCallback(
    (isExpanded: boolean, isFullGallery: boolean, edge: ShelfDockEdge = dockEdgeRef.current) => {
      if (!isExpanded) {
        void transport.setShelfHitRect(null).catch(() => {});
        return;
      }
      const dpr = window.devicePixelRatio || 1;
      const isSide = edge === 'left' || edge === 'right';
      const viewportW = window.innerWidth || (isSide ? 560 : 1040);
      const viewportH = window.innerHeight || (isSide ? 760 : 620);

      let logicalLeft: number;
      let logicalTop: number;
      let logicalW: number;
      let logicalH: number;

      if (isSide) {
        logicalW = Math.min(
          isFullGallery ? SIDE_FULL_WIDTH : SIDE_COMPACT_WIDTH,
          Math.max(200, viewportW - 16),
        );
        logicalH = Math.min(
          isFullGallery ? SIDE_FULL_HEIGHT : SIDE_COMPACT_HEIGHT,
          Math.max(240, viewportH - 16),
        );
        logicalTop = Math.max(0, (viewportH - logicalH) / 2);
        logicalLeft = edge === 'left' ? 0 : Math.max(0, viewportW - logicalW);
      } else {
        logicalW = Math.min(
          isFullGallery ? FULL_WIDTH : COMPACT_WIDTH,
          Math.max(200, viewportW - 16),
        );
        logicalH = Math.min(
          isFullGallery ? FULL_HEIGHT : COMPACT_HEIGHT,
          Math.max(160, viewportH - 8),
        );
        logicalLeft = Math.max(0, (viewportW - logicalW) / 2);
        logicalTop = 0;
      }

      let left = logicalLeft;
      let top = logicalTop;
      let right = logicalLeft + logicalW;
      let bottom = logicalTop + logicalH;

      // Expand hit rect cleanly around any open portaled Popover (e.g. folder selector)
      if (typeof document !== 'undefined') {
        const openPopovers = document.querySelectorAll<HTMLElement>(
          '[data-charkle-popover-open="true"]',
        );
        openPopovers.forEach((pop) => {
          const r = pop.getBoundingClientRect();
          if (r.width > 0 && r.height > 0 && r.left > -5000 && r.top > -5000) {
            left = Math.max(0, Math.min(left, r.left - 4));
            top = Math.max(0, Math.min(top, r.top - 4));
            right = Math.min(viewportW, Math.max(right, r.right + 4));
            bottom = Math.min(viewportH, Math.max(bottom, r.bottom + 4));
          }
        });
      }

      void transport
        .setShelfHitRect({
          x: Math.round(left * dpr),
          y: Math.round(top * dpr),
          width: Math.round(Math.max(1, right - left) * dpr),
          height: Math.round(Math.max(1, bottom - top) * dpr),
        })
        .catch(() => {});
    },
    [transport],
  );

  const reportHitRect = useCallback(() => {
    reportHitRectFor(expanded, fullGallery, dockEdge);
  }, [reportHitRectFor, expanded, fullGallery, dockEdge]);

  useEffect(() => {
    void refreshData();
    void transport
      .getShelfSettings()
      .then((cfg) => {
        shelfSettingsRef.current = cfg;
        setTargetMode(cfg.defaultTargetMode);
        if (cfg.defaultFolderId) setSelectedFolderId(cfg.defaultFolderId);
        if (initialDockEdge === undefined && cfg.dockEdge) {
          const nextEdge = normalizeDockEdge(cfg.dockEdge);
          dockEdgeRef.current = nextEdge;
          setDockEdge(nextEdge);
        }
      })
      .catch(() => {});

    let disposed = false;
    const syncHostVisibility = () => {
      if (initialExpanded !== undefined || !isTauriRuntime()) return;
      void transport
        .getDesktopIntegrationStatus()
        .then((status) => {
          if (disposed) return;
          setPinned(status.shelfPinned);
          if (status.shelfVisible) {
            setExpanded(true);
            reportHitRectFor(true, fullGalleryRef.current, dockEdgeRef.current);
            void refreshData();
          }
        })
        .catch(() => {});
    };

    syncHostVisibility();

    let unlisten: (() => void) | null = null;
    void transport
      .subscribeEvents({
        onLibraryChanged: () => void refreshData(),
        onBoardUpdated: () => void refreshData(),
        onClipboardChanged: (preview) => setClipboard(preview),
        onShelfSettings: (cfg) => {
          shelfSettingsRef.current = cfg;
          setTargetMode(cfg.defaultTargetMode);
          if (cfg.defaultFolderId) setSelectedFolderId(cfg.defaultFolderId);
          if (cfg.dockEdge) {
            const nextEdge = normalizeDockEdge(cfg.dockEdge);
            dockEdgeRef.current = nextEdge;
            setDockEdge(nextEdge);
            if (expandedRef.current) {
              reportHitRectFor(true, fullGalleryRef.current, nextEdge);
            }
          }
        },
        onShelfDragHover: (payload) => {
          cancelAutoCollapse();
          setNativeDragHover({ active: payload.active, count: payload.count });
        },
        onShelfDropStatus: (payload) => {
          cancelAutoCollapse();
          if (payload.phase === 'processing') {
            setProcessingMessage(payload.message);
          } else {
            setProcessingMessage(null);
            showBanner(payload.message);
            void refreshData();
          }
        },
        onShelfState: (s) => {
          cancelAutoCollapse();
          setPinned(s.pinned);
          let nextFullGallery = fullGalleryRef.current;
          let nextEdge = dockEdgeRef.current;
          if (s.dockEdge) {
            nextEdge = normalizeDockEdge(s.dockEdge);
            dockEdgeRef.current = nextEdge;
            setDockEdge(nextEdge);
          }
          if (typeof s.minimalMode === 'boolean') {
            setMinimalMode(s.minimalMode);
            if (s.minimalMode) {
              setFullGallery(false);
              nextFullGallery = false;
            }
          }
          if (s.defaultTargetMode) {
            setTargetMode(s.defaultTargetMode);
          }
          if (s.expanded) {
            // Set expanded directly (never inside requestAnimationFrame, which hidden WebView2 suspends!)
            setExpanded(true);
            reportHitRectFor(true, nextFullGallery, nextEdge);
            void refreshData();
          } else {
            clearBannerTimer();
            setExpanded(false);
            setFullGallery(false);
            setNativeDragHover({ active: false, count: 0 });
            setSelectedIds([]);
            setSearchQuery('');
            reportHitRectFor(false, false, nextEdge);
            void transport.setShelfAllowActivate(false).catch(() => {});
          }
        },
      })
      .then((fn) => {
        if (disposed) {
          fn();
          return;
        }
        unlisten = fn;
        // Re-sync after listeners are live so a `shelf:state` event emitted during async
        // startup subscription can never leave a visible shelf stuck at `expanded = false`.
        syncHostVisibility();
      })
      .catch(() => {});
    return () => {
      disposed = true;
      unlisten?.();
    };
  }, [
    transport,
    refreshData,
    showBanner,
    initialExpanded,
    initialDockEdge,
    cancelAutoCollapse,
    clearBannerTimer,
    reportHitRectFor,
  ]);

  useEffect(() => {
    reportHitRect();
    window.addEventListener('resize', reportHitRect);
    let mo: MutationObserver | null = null;
    let rafId: number | null = null;
    if (expanded && typeof document !== 'undefined' && typeof MutationObserver !== 'undefined') {
      const scheduleSync = () => {
        if (rafId !== null) cancelAnimationFrame(rafId);
        rafId = requestAnimationFrame(() => {
          rafId = null;
          reportHitRect();
        });
      };
      mo = new MutationObserver(scheduleSync);
      mo.observe(document.body, {
        childList: true,
        subtree: false,
      });
    }
    return () => {
      window.removeEventListener('resize', reportHitRect);
      mo?.disconnect();
      if (rafId !== null) cancelAnimationFrame(rafId);
    };
  }, [expanded, reportHitRect]);

  // Keyboard shortcuts inside shelf: Ctrl+V instant paste collect, Escape collapse
  const handleCollectClipboardRef = useRef<() => Promise<void>>(async () => {});
  useEffect(() => {
    const onKeyDown = (e: KeyboardEvent) => {
      const target = e.target as HTMLElement | null;
      const typing = target?.tagName === 'INPUT' || target?.tagName === 'TEXTAREA';
      if (e.key === 'Escape') {
        if (document.querySelector('[data-charkle-popover-open="true"]')) return;
        e.preventDefault();
        if (fullGallery) {
          closeFullGallery();
        } else {
          void transport.hideShelf().catch(() => {});
        }
        return;
      }
      if (!typing && (e.ctrlKey || e.metaKey) && e.key.toLowerCase() === 'v') {
        e.preventDefault();
        void handleCollectClipboardRef.current();
      }
    };
    window.addEventListener('keydown', onKeyDown);
    return () => window.removeEventListener('keydown', onKeyDown);
  }, [fullGallery, closeFullGallery, transport]);

  const handleCollectClipboard = async () => {
    const { folderId, boardId } = resolvedTargetsRef.current;
    const savedLabel = clipboard?.kind === 'url' ? clipboard.label : null;
    setProcessingMessage('正在采集剪贴板…');
    try {
      const count = await transport.collectClipboardNow(folderId, boardId);
      if (count > 0 && savedLabel) {
        setDismissedClipboardLabel(savedLabel);
      }
      showBanner(count > 0 ? `已采集 ${count} 项剪贴板内容` : '剪贴板暂无可采集内容');
      void refreshData();
    } catch (err) {
      showBanner(err instanceof Error ? err.message : '采集剪贴板失败');
    } finally {
      setProcessingMessage(null);
    }
  };
  handleCollectClipboardRef.current = handleCollectClipboard;

  // Strictly show the quick-save link banner ONLY for valid http(s) URLs (GitHub / X / generic website),
  // never for plain text, prompts, images, files, or colors.
  const activeClipboardUrlPrompt = useMemo(() => {
    if (!clipboard || clipboard.kind !== 'url' || !clipboard.url?.trim()) {
      return null;
    }
    if (clipboard.label === dismissedClipboardLabel) {
      return null;
    }
    return {
      clip: clipboard,
      label: formatClipboardUrlPrompt(clipboard),
    };
  }, [clipboard, dismissedClipboardLabel]);

  const folderOptions = useMemo<SelectOption<string>[]>(() => {
    return flattenFolderTree(buildFolderTree(folders)).map((node) => ({
      value: node.folder.id,
      label: node.folder.name,
      depth: node.depth,
    }));
  }, [folders]);

  const activeBoardTitle = boards[0]?.title ?? '未选择情绪板';
  const selectedFolderName =
    folders.find((f) => f.id === selectedFolderId)?.name ??
    folders[0]?.name ??
    '默认文件夹';

  const targetDestinationName = useMemo(() => {
    if (targetMode === 'inbox') return '收件箱';
    if (targetMode === 'folder') return selectedFolderName;
    return boards[0]?.title || '活跃情绪板';
  }, [targetMode, selectedFolderName, boards]);

  const targetDropHint = useMemo(() => {
    if (targetMode === 'inbox') return '将保存至收件箱';
    if (targetMode === 'folder') return `将保存至文件夹「${selectedFolderName}」`;
    return `将保存并加入情绪板「${activeBoardTitle}」`;
  }, [targetMode, selectedFolderName, activeBoardTitle]);

  const filteredAssets = useMemo(() => {
    const q = searchQuery.trim().toLowerCase();
    if (!q) return assets;
    return assets.filter(
      (a) =>
        a.title.toLowerCase().includes(q) ||
        a.tags.some((t) => t.toLowerCase().includes(q)) ||
        (a.sourceDomain?.toLowerCase().includes(q) ?? false),
    );
  }, [assets, searchQuery]);

  // HTML5 drag-drop handler for web URLs, text drops, color hexes, and browser/mock preview files.
  // In Tauri desktop runtime, OS file/folder drops are handled authoritatively in Rust
  // (`WindowEvent::DragDrop`) so we return early on `dataTransfer.files` to prevent duplicate imports.
  const handleHtmlDrop = async (e: React.DragEvent) => {
    e.preventDefault();
    setHtmlDragHovering(false);
    const { folderId, boardId } = resolvedTargets;

    const files = Array.from(e.dataTransfer.files);
    if (files.length > 0) {
      if (isTauriRuntime()) return;
      setProcessingMessage(`正在收藏 ${files.length} 项文件…`);
      try {
        let count = 0;
        for (const file of files) {
          const dataUrl = await new Promise<string>((resolve) => {
            const reader = new FileReader();
            reader.onload = () => resolve(String(reader.result ?? ''));
            reader.readAsDataURL(file);
          });
          const b64 = dataUrl.includes(',') ? dataUrl.split(',')[1] : dataUrl;
          if (b64) {
            await transport.ingestImageBase64(b64, file.name, null, folderId, boardId);
            count += 1;
          }
        }
        if (count > 0) {
          showBanner(`已收入「${targetDestinationName}」(${count} 项)`);
          void refreshData();
        }
      } finally {
        setProcessingMessage(null);
      }
      return;
    }

    const droppedText = (
      e.dataTransfer.getData('text/uri-list') || e.dataTransfer.getData('text/plain')
    ).trim();
    if (!droppedText) return;

    setProcessingMessage('正在解析并收藏…');
    try {
      if (/^#[0-9a-f]{6}$/i.test(droppedText)) {
        await transport.ingestSwatch(droppedText.toUpperCase(), null, folderId, boardId);
        showBanner(`已收入「${targetDestinationName}」(色卡)`);
        void refreshData();
      } else if (/^https?:\/\//i.test(droppedText)) {
        await transport.ingestUrl(droppedText, null, null, folderId, boardId);
        showBanner(`已收入「${targetDestinationName}」(链接)`);
        void refreshData();
      } else {
        const title = droppedText.split(/\r?\n/)[0]?.slice(0, 48) || '速记灵感';
        await transport.ingestText(title, droppedText, null, folderId, boardId);
        showBanner(`已收入「${targetDestinationName}」(文本)`);
        void refreshData();
      }
    } catch (err) {
      showBanner(err instanceof Error ? err.message : '导入失败');
    } finally {
      setProcessingMessage(null);
    }
  };

  // Start native Win32 OLE DoDragDrop ONLY after deliberate drag motion (distinguishing click vs drag!)
  const startCardDragOut = (e: React.PointerEvent, ids: string[], onClick?: () => void) => {
    if (e.button !== 0 || ids.length === 0) return;
    if ((e.target as HTMLElement).closest('button')) return;

    const captureTarget = e.currentTarget as HTMLElement;
    const pointerId = e.pointerId;
    try {
      captureTarget.setPointerCapture?.(pointerId);
    } catch {
      // Ignored in synthetic test events
    }

    const startX = e.clientX;
    const startY = e.clientY;
    const startedAt = performance.now();
    let launched = false;

    const releaseCapture = () => {
      try {
        if (captureTarget.hasPointerCapture?.(pointerId)) {
          captureTarget.releasePointerCapture?.(pointerId);
        }
      } catch {
        // Ignored
      }
    };

    const cleanup = () => {
      releaseCapture();
      window.removeEventListener('pointermove', onMove, true);
      window.removeEventListener('pointerup', onUp, true);
      window.removeEventListener('pointercancel', onCancel, true);
      window.removeEventListener('blur', onCancel);
      window.removeEventListener('keydown', onKeyDown, true);
    };

    const onMove = (ev: PointerEvent) => {
      if (launched) return;
      if (typeof ev.buttons === 'number' && ev.buttons !== 0 && (ev.buttons & 1) === 0) {
        cleanup();
        return;
      }
      const dist = Math.hypot(ev.clientX - startX, ev.clientY - startY);
      if (dist < DRAG_OUT_THRESHOLD) return;
      const elapsed = performance.now() - startedAt;
      if (elapsed < DRAG_OUT_MIN_HOLD_MS && dist < DRAG_OUT_FAST_THRESHOLD) return;
      launched = true;
      cleanup();
      void transport
        .startOutboundDrag(ids)
        .then((outcome) => {
          if (outcome !== 'cancelled') {
            showBanner(`已拖出 ${ids.length} 项原文件`);
          }
        })
        .catch((err) => {
          showBanner(err instanceof Error ? err.message : '原文件尚未缓存在本地');
        });
    };

    const onUp = () => {
      cleanup();
      if (!launched) onClick?.();
    };

    const onCancel = () => {
      cleanup();
    };

    const onKeyDown = (ev: KeyboardEvent) => {
      if (ev.key === 'Escape') {
        cleanup();
      }
    };

    window.addEventListener('pointermove', onMove, true);
    window.addEventListener('pointerup', onUp, true);
    window.addEventListener('pointercancel', onCancel, true);
    window.addEventListener('blur', onCancel);
    window.addEventListener('keydown', onKeyDown, true);
  };

  // Full Waterfall rubber-band marquee multi-select (ref-stabilized so listeners don't thrash per pixel)
  const marqueeActive = marquee !== null;
  useEffect(() => {
    if (!marqueeActive) return;
    const onMove = (e: MouseEvent) => {
      const container = waterfallGridRef.current;
      const current = marqueeRef.current;
      if (!container || !current) return;
      const rect = container.getBoundingClientRect();
      const curX = e.clientX - rect.left + container.scrollLeft;
      const curY = e.clientY - rect.top + container.scrollTop;
      setMarquee((prev) => (prev ? { ...prev, curX, curY } : null));

      const left = Math.min(current.startX, curX);
      const right = Math.max(current.startX, curX);
      const top = Math.min(current.startY, curY);
      const bottom = Math.max(current.startY, curY);
      if (right - left > 4 || bottom - top > 4) {
        const hit: string[] = [];
        const cards = container.querySelectorAll<HTMLElement>('[data-shelf-card-id]');
        cards.forEach((card) => {
          const cr = card.getBoundingClientRect();
          const cx = cr.left - rect.left + container.scrollLeft;
          const cy = cr.top - rect.top + container.scrollTop;
          if (cx < right && cx + cr.width > left && cy < bottom && cy + cr.height > top) {
            const id = card.dataset.shelfCardId;
            if (id) hit.push(id);
          }
        });
        setSelectedIds(hit);
      }
    };
    const onUp = () => setMarquee(null);
    const onKeyDown = (e: KeyboardEvent) => {
      if (e.key === 'Escape') {
        e.preventDefault();
        e.stopImmediatePropagation();
        setMarquee(null);
      }
    };
    window.addEventListener('mousemove', onMove);
    window.addEventListener('mouseup', onUp);
    window.addEventListener('blur', onUp);
    window.addEventListener('keydown', onKeyDown, true);
    return () => {
      window.removeEventListener('mousemove', onMove);
      window.removeEventListener('mouseup', onUp);
      window.removeEventListener('blur', onUp);
      window.removeEventListener('keydown', onKeyDown, true);
    };
  }, [marqueeActive]);

  const toggleSelect = (id: string, multi: boolean) => {
    setSelectedIds((prev) => {
      if (!multi) return prev.length === 1 && prev[0] === id ? [] : [id];
      return prev.includes(id) ? prev.filter((x) => x !== id) : [...prev, id];
    });
  };

  const isSideDock = dockEdge === 'left' || dockEdge === 'right';
  const targetW = expanded
    ? fullGallery
      ? isSideDock
        ? SIDE_FULL_WIDTH
        : FULL_WIDTH
      : isSideDock
        ? SIDE_COMPACT_WIDTH
        : COMPACT_WIDTH
    : isSideDock
      ? SIDE_COLLAPSED_WIDTH
      : COLLAPSED_WIDTH;
  const targetH = expanded
    ? fullGallery
      ? isSideDock
        ? SIDE_FULL_HEIGHT
        : FULL_HEIGHT
      : isSideDock
        ? SIDE_COMPACT_HEIGHT
        : COMPACT_HEIGHT
    : isSideDock
      ? SIDE_COLLAPSED_HEIGHT
      : COLLAPSED_HEIGHT;
  const outerCornerRadius = expanded ? BOTTOM_CORNER_RADIUS : 14;
  const shellPath = buildNotchShellPath(targetW, targetH, dockEdge, TOP_EAR_RADIUS, outerCornerRadius);
  const rimPath = buildNotchRimPath(targetW, targetH, dockEdge, TOP_EAR_RADIUS, outerCornerRadius);

  const rimGradientCoords =
    dockEdge === 'left'
      ? { x1: '0', y1: '0', x2: '1', y2: '0' }
      : dockEdge === 'right'
        ? { x1: '1', y1: '0', x2: '0', y2: '0' }
        : { x1: '0', y1: '0', x2: '0', y2: '1' };

  const collapsedTransform =
    dockEdge === 'left'
      ? 'translate3d(-16px, 0, 0) scale3d(0.92, 0.96, 1)'
      : dockEdge === 'right'
        ? 'translate3d(16px, 0, 0) scale3d(0.92, 0.96, 1)'
        : 'translate3d(0, -14px, 0) scale3d(0.96, 0.92, 1)';

  const expandedShadow =
    dockEdge === 'left'
      ? 'drop-shadow(10px 4px 24px rgba(0, 0, 0, 0.46))'
      : dockEdge === 'right'
        ? 'drop-shadow(-10px 4px 24px rgba(0, 0, 0, 0.46))'
        : 'drop-shadow(0 12px 24px rgba(0, 0, 0, 0.44))';

  const outerAlignClass =
    dockEdge === 'left'
      ? 'justify-start items-center'
      : dockEdge === 'right'
        ? 'justify-end items-center'
        : 'justify-center items-start';

  const interiorPaddingStyle = isSideDock
    ? {
        paddingTop: TOP_EAR_RADIUS + 14,
        paddingBottom: TOP_EAR_RADIUS + 14,
        paddingLeft: 14,
        paddingRight: 14,
      }
    : {
        paddingLeft: TOP_EAR_RADIUS + 16,
        paddingRight: TOP_EAR_RADIUS + 16,
        paddingBottom: 14,
      };

  const marqueeBox = marquee
    ? {
        left: Math.min(marquee.startX, marquee.curX),
        top: Math.min(marquee.startY, marquee.curY),
        width: Math.abs(marquee.curX - marquee.startX),
        height: Math.abs(marquee.curY - marquee.startY),
      }
    : null;

  const renderDropWellContent = (sideCompact: boolean) => {
    if (processingMessage) {
      return (
        <div className="flex items-center gap-2 text-[12px] font-semibold text-white">
          <span className="w-3.5 h-3.5 rounded-full border-2 border-white/30 border-t-white animate-spin shrink-0" />
          <span className="truncate">{processingMessage}</span>
        </div>
      );
    }
    if (statusMessage) {
      return (
        <div className="flex items-center gap-2 text-[12px] font-semibold text-white min-w-0">
          <CheckmarkCircle16Filled className="w-4 h-4 text-emerald-400 shrink-0" />
          <span className="truncate">{statusMessage}</span>
        </div>
      );
    }
    if (isDropTargeted) {
      return (
        <div className="flex items-center gap-2.5 min-w-0">
          <ArrowUpload16Regular className="w-4 h-4 text-[#5B8DEF] shrink-0" />
          <div className="flex flex-col leading-tight min-w-0">
            <span className="text-[12.5px] font-semibold text-white truncate">
              松开立即收藏 {dragItemCount} 项素材
            </span>
            <span className="text-[10.5px] text-white/74 truncate">{targetDropHint}</span>
          </div>
        </div>
      );
    }
    if (activeClipboardUrlPrompt) {
      return (
        <div className="w-full h-full flex items-center gap-2">
          <button
            type="button"
            aria-label={`检测到剪贴板链接 · ${activeClipboardUrlPrompt.label}`}
            onClick={() => void handleCollectClipboard()}
            className="flex-1 min-w-0 h-full flex items-center justify-between gap-2 cursor-pointer text-left"
          >
            <span className="flex items-center gap-2 min-w-0">
              <Link16Regular className="w-4 h-4 text-[#5B8DEF] shrink-0" />
              <span
                className={
                  sideCompact
                    ? 'text-[11.5px] font-medium text-white line-clamp-2 leading-snug'
                    : 'text-[12px] font-medium text-white truncate'
                }
              >
                {activeClipboardUrlPrompt.label}
              </span>
            </span>
            <span className="px-2.5 py-1 rounded-[var(--win-radius-control)] bg-[var(--accent)] text-[11px] font-semibold text-[var(--accent-text)] shrink-0">
              保存
            </span>
          </button>
          <button
            type="button"
            title="忽略剪贴板链接"
            aria-label="忽略剪贴板链接"
            onClick={() => setDismissedClipboardLabel(activeClipboardUrlPrompt.clip.label)}
            className="charkle-pressable w-6 h-6 rounded-[var(--win-radius-control)] bg-white/8 hover:bg-white/16 text-white/62 hover:text-white inline-flex items-center justify-center shrink-0 cursor-pointer"
          >
            <Dismiss16Regular className="w-3 h-3" />
          </button>
        </div>
      );
    }
    return (
      <button
        type="button"
        onClick={() => void handleCollectClipboard()}
        className="w-full h-full flex items-center gap-2.5 cursor-pointer text-left"
      >
        <ArrowUpload16Regular className="w-3.5 h-3.5 text-white/72 shrink-0" />
        <span
          className={
            sideCompact
              ? 'text-[11.5px] font-medium text-white/84 leading-snug line-clamp-2'
              : 'text-[12px] font-medium text-white/84 truncate'
          }
        >
          拖入文件、整个文件夹、网页、推文或 GitHub 链接，或按 Ctrl+V 粘贴
        </span>
      </button>
    );
  };

  return (
    <div
      className={[
        'w-screen h-screen flex bg-transparent select-none overflow-hidden',
        outerAlignClass,
      ].join(' ')}
      onDragOver={(e) => {
        e.preventDefault();
        setHtmlDragHovering(true);
      }}
      onDragLeave={(e) => {
        if (e.currentTarget === e.target) setHtmlDragHovering(false);
      }}
      onDrop={(e) => void handleHtmlDrop(e)}
    >
      {/* Pure-Black Hardware Notch Capsule with Concave Bezel Ears (0px outer DWM frame) */}
      <div
        ref={capsuleRef}
        data-testid="top-edge-drop-shelf"
        data-mode={fullGallery ? 'waterfall' : 'compact'}
        data-expanded={expanded ? 'true' : 'false'}
        data-dock-edge={dockEdge}
        style={{
          width: `min(${targetW}px, calc(100vw - 16px))`,
          height: isSideDock ? `min(${targetH}px, calc(100vh - 16px))` : `${targetH}px`,
          opacity: expanded ? 1 : 0,
          transform: expanded ? 'translate3d(0, 0, 0) scale3d(1, 1, 1)' : collapsedTransform,
          filter: expanded ? expandedShadow : 'none',
        }}
        className="charkle-shelf-shell relative flex flex-col text-white overflow-hidden"
      >
        {/* Pure-Black NotchShellShape Vector Backdrop + Directional Subtle Rim Stroke */}
        <svg
          aria-hidden="true"
          viewBox={`0 0 ${targetW} ${targetH}`}
          preserveAspectRatio="none"
          className="pointer-events-none absolute inset-0 w-full h-full"
        >
          <defs>
            <linearGradient id="charkle-notch-rim" {...rimGradientCoords}>
              <stop offset="0%" stopColor="#FFFFFF" stopOpacity="0" />
              <stop offset="26%" stopColor="#FFFFFF" stopOpacity="0.08" />
              <stop offset="100%" stopColor="#FFFFFF" stopOpacity="0.14" />
            </linearGradient>
          </defs>
          <path d={shellPath} fill="#000000" />
          <path
            d={rimPath}
            fill="none"
            stroke="url(#charkle-notch-rim)"
            strokeWidth="0.9"
            vectorEffect="non-scaling-stroke"
          />
        </svg>

        {/* Interior Content padded inside concave bezel ears */}
        <div
          style={interiorPaddingStyle}
          className="relative z-10 flex-1 min-h-0 flex flex-col"
        >
          {/* Band 1: Minimal Wing Bar (Left: Charkle mark + optional Minimal Mode pill; Right: Pin / Open / Close) */}
          <div
            style={{ height: isSideDock ? 32 : TOP_BAND_HEIGHT }}
            className="shrink-0 flex items-center justify-between"
          >
            <div className="flex items-center gap-1.5 min-w-0">
              <CharkleBrandMark size={16} variant="dark" />
              <span className="text-[12.5px] font-semibold tracking-[-0.01em] text-white/94 shrink-0 whitespace-nowrap">
                Charkle
              </span>
              {minimalMode && (
                <span className="inline-flex items-center gap-1 px-[7px] py-[2px] rounded-[var(--win-radius-control)] bg-white/11 text-[10px] font-semibold text-white/84 shrink-0 whitespace-nowrap">
                  <span className="w-[5px] h-[5px] rounded-full bg-[#34C769] shrink-0" />
                  <span>极简采集</span>
                </span>
              )}
            </div>

            <div className="flex items-center gap-1.5 shrink-0">
              <button
                type="button"
                title={pinned ? '取消固定展开' : '固定展开托盘'}
                aria-label={pinned ? '取消固定展开' : '固定展开托盘'}
                onClick={() => {
                  cancelAutoCollapse();
                  const next = !pinned;
                  setPinned(next);
                  void transport.setShelfPinned(next).catch(() => {});
                }}
                className={[
                  'charkle-pressable w-[22px] h-[22px] rounded-[var(--win-radius-control)] inline-flex items-center justify-center cursor-pointer',
                  pinned
                    ? 'bg-white/16 text-[#5B8DEF]'
                    : 'bg-white/8 text-white/68 hover:text-white hover:bg-white/14',
                ].join(' ')}
              >
                {pinned ? (
                  <Pin16Filled className="w-3 h-3" />
                ) : (
                  <Pin16Regular className="w-3 h-3" />
                )}
              </button>

              <button
                type="button"
                title="打开 Charkle 主窗口"
                aria-label="打开主窗口"
                onClick={openMainWindowAndCollapse}
                className="charkle-pressable w-[22px] h-[22px] rounded-[var(--win-radius-control)] bg-white/8 text-white/68 hover:text-white hover:bg-white/14 inline-flex items-center justify-center cursor-pointer"
              >
                <ArrowUpRight16Regular className="w-3 h-3" />
              </button>

              <button
                type="button"
                title={isSideDock ? '收起侧边托盘' : '收起顶部托盘'}
                aria-label="收起抽屉"
                onClick={() => {
                  cancelAutoCollapse();
                  void transport.hideShelf().catch(() => {});
                }}
                className="charkle-pressable w-[22px] h-[22px] rounded-[var(--win-radius-control)] bg-white/10 text-white/68 hover:text-white hover:bg-white/18 inline-flex items-center justify-center cursor-pointer"
              >
                <Dismiss16Regular className="w-3 h-3" />
              </button>
            </div>
          </div>

          {/* Body: Compact Mode vs Expanded Full-Waterfall Mode (Top Notch vs Left/Right Vertical Drawer) */}
          {!fullGallery || minimalMode ? (
            isSideDock ? (
              /* Vertical Side-Edge Compact Drawer (344 × 560) */
              <div className="pt-2 flex-1 min-h-0 flex flex-col gap-2.5 overflow-hidden">
                {/* Equal-width Quick Capture Actions */}
                <div className="grid grid-cols-3 gap-1.5 shrink-0">
                  <button
                    type="button"
                    title="区域截图 (Alt+Shift+A)"
                    aria-label="区域截图采集"
                    onClick={handleStartRegionCapture}
                    className="charkle-pressable h-[29px] px-1.5 rounded-[var(--win-radius-control)] bg-white/9 hover:bg-white/14 text-white/88 inline-flex items-center justify-center gap-1 text-[11px] font-medium cursor-pointer whitespace-nowrap"
                  >
                    <Camera16Regular className="w-3.5 h-3.5 shrink-0" />
                    <span>区域截图</span>
                  </button>

                  <button
                    type="button"
                    title="采集剪贴板 (Alt+Shift+V)"
                    aria-label="采集剪贴板"
                    onClick={() => void handleCollectClipboard()}
                    className="charkle-pressable h-[29px] px-1.5 rounded-[var(--win-radius-control)] bg-white/9 hover:bg-white/14 text-white/88 inline-flex items-center justify-center gap-1 text-[11px] font-medium cursor-pointer whitespace-nowrap"
                  >
                    <Clipboard16Regular className="w-3.5 h-3.5 shrink-0" />
                    <span>剪贴板</span>
                  </button>

                  <button
                    type="button"
                    title={minimalMode ? '退出极简模式并打开主窗' : '打开 Charkle 主窗'}
                    onClick={openMainWindowAndCollapse}
                    className="charkle-pressable h-[29px] px-1.5 rounded-[var(--win-radius-control)] bg-white/9 hover:bg-white/14 text-white/88 inline-flex items-center justify-center gap-1 text-[11px] font-medium cursor-pointer whitespace-nowrap"
                  >
                    <Grid16Regular className="w-3.5 h-3.5 shrink-0" />
                    <span>{minimalMode ? '恢复主窗' : '主窗'}</span>
                  </button>
                </div>

                {/* Stacked Target Switcher + Contextual Target Sub-row */}
                <div className="flex flex-col gap-1.5 shrink-0">
                  <div
                    role="radiogroup"
                    aria-label="采集投递目标"
                    className="grid grid-cols-3 p-[2.5px] gap-0.5 rounded-[var(--win-radius-control)] bg-white/8"
                  >
                    {(
                      [
                        { id: 'inbox', label: '收件箱' },
                        { id: 'folder', label: '文件夹' },
                        { id: 'activeMoodboard', label: '活跃情绪板' },
                      ] as const
                    ).map((opt) => {
                      const active = targetMode === opt.id;
                      return (
                        <button
                          key={opt.id}
                          type="button"
                          role="radio"
                          aria-checked={active}
                          onClick={() => {
                            const nextFolderId =
                              opt.id === 'folder'
                                ? selectedFolderId || folders[0]?.id || ''
                                : selectedFolderId;
                            if (opt.id === 'folder' && nextFolderId && !selectedFolderId) {
                              setSelectedFolderId(nextFolderId);
                            }
                            setTargetMode(opt.id);
                            persistTargetSelection(opt.id, nextFolderId);
                          }}
                          className={[
                            'charkle-pressable px-1.5 py-[4px] rounded-[var(--win-radius-control)] text-[10.5px] cursor-pointer whitespace-nowrap text-center',
                            active
                              ? 'bg-white/18 text-white font-semibold'
                              : 'text-white/62 hover:text-white/90 font-medium',
                          ].join(' ')}
                        >
                          {opt.label}
                        </button>
                      );
                    })}
                  </div>

                  {targetMode === 'inbox' && (
                    <div className="flex items-center justify-between px-2.5 py-1 rounded-[var(--win-radius-control)] bg-white/[0.05] text-[10.5px] text-white/66">
                      <span>默认收入收件箱待整理</span>
                      <span className="charkle-tabular font-semibold text-white/84">
                        {inboxCount} 项
                      </span>
                    </div>
                  )}

                  {targetMode === 'folder' &&
                    (folderOptions.length > 0 ? (
                      <CustomSelect<string>
                        value={selectedFolderId}
                        options={folderOptions}
                        onChange={(fid) => {
                          setSelectedFolderId(fid);
                          persistTargetSelection('folder', fid);
                        }}
                        ariaLabel="选择投递文件夹"
                        size="xs"
                        className="w-full h-[26px] bg-white/11 border-white/12 text-white text-[11px]"
                      />
                    ) : (
                      <div className="px-2.5 py-1 rounded-[var(--win-radius-control)] bg-white/[0.05] text-[10.5px] text-white/55">
                        暂无文件夹，将保存至收件箱
                      </div>
                    ))}

                  {targetMode === 'activeMoodboard' && (
                    <div className="flex items-center gap-1.5 px-2.5 py-1 rounded-[var(--win-radius-control)] bg-white/[0.05] text-[10.5px] text-white/86 min-w-0">
                      <span className="w-[5px] h-[5px] rounded-full bg-emerald-400 shrink-0" />
                      <span className="truncate">{activeBoardTitle}</span>
                    </div>
                  )}
                </div>

                {/* Vertical-Friendly Drop Well */}
                <div
                  className={[
                    'min-h-[64px] shrink-0 rounded-[var(--win-radius-card)] flex items-center justify-center transition-colors duration-150 py-2.5 px-3',
                    isDropTargeted
                      ? 'bg-[var(--accent)]/24 border-[1.5px] border-[var(--accent)]'
                      : 'bg-white/[0.06] border border-dashed border-white/14 hover:bg-white/[0.08]',
                  ].join(' ')}
                >
                  {renderDropWellContent(true)}
                </div>

                {/* Recent Assets 2-Column Scrollable Grid */}
                <div className="flex-1 min-h-0 flex flex-col gap-1.5">
                  <div className="flex items-center justify-between gap-2 shrink-0">
                    <span className="px-2.5 py-[3px] rounded-[var(--win-radius-control)] bg-white/14 text-[11px] font-semibold text-white shrink-0">
                      最近素材
                    </span>

                    {minimalMode ? (
                      <button
                        type="button"
                        title="退出极简模式并打开主窗口浏览全部素材"
                        aria-label="恢复主窗看全部"
                        onClick={openMainWindowAndCollapse}
                        className="charkle-pressable px-2.5 py-[3px] rounded-[var(--win-radius-control)] bg-white/9 hover:bg-white/16 text-[10.5px] font-semibold text-white/78 inline-flex items-center gap-1 cursor-pointer shrink-0 whitespace-nowrap"
                      >
                        <span>恢复主窗看全部</span>
                        <ArrowUpRight16Regular className="w-3 h-3" />
                      </button>
                    ) : (
                      <button
                        type="button"
                        title="展开全画面瀑布流浏览最近素材（支持框选多选）"
                        aria-label="展开为全瀑布流抽屉"
                        onClick={openFullGallery}
                        className="charkle-pressable px-2.5 py-[3px] rounded-[var(--win-radius-control)] bg-white/10 hover:bg-white/16 text-[11px] font-semibold text-white/84 inline-flex items-center gap-1 cursor-pointer shrink-0 charkle-tabular"
                      >
                        {dockEdge === 'right' && <ChevronLeft16Regular className="w-3 h-3" />}
                        <span>全部 ({assets.length})</span>
                        {dockEdge === 'left' && <ChevronRight16Regular className="w-3 h-3" />}
                      </button>
                    )}
                  </div>

                  {assets.length === 0 ? (
                    <div className="flex-1 flex items-center justify-center text-center px-3 text-[11.5px] text-white/45">
                      暂无最近素材，拖入文件或按 Alt+Shift+V 粘贴收藏
                    </div>
                  ) : (
                    <div className="grid grid-cols-2 gap-2 overflow-y-auto charkle-scroll pr-0.5 flex-1 min-h-0 content-start">
                      {assets.slice(0, minimalMode ? 16 : 24).map((asset) => (
                        <div key={asset.id} className="group flex flex-col gap-1 min-w-0">
                          <div
                            onPointerDown={(e) =>
                              startCardDragOut(e, [asset.id], openFullGallery)
                            }
                            className="relative w-full aspect-[4/3] rounded-[var(--win-radius-card)] overflow-hidden bg-white/8 ring-1 ring-white/12 group-hover:ring-white/38 cursor-grab active:cursor-grabbing transition-shadow duration-150"
                          >
                            <ShelfAssetThumb
                              asset={asset}
                              rawThumbUrl={transport.thumbnailUrl(asset.id, 'grid520')}
                              fixedHeight
                            />

                            <div className="absolute top-1.5 right-1.5 flex items-center gap-1 opacity-0 group-hover:opacity-100 transition-opacity duration-150">
                              <button
                                type="button"
                                title="拷贝文件到剪贴板"
                                aria-label={`拷贝 ${asset.title}`}
                                onClick={(e) => {
                                  e.stopPropagation();
                                  void transport
                                    .copyAssetsToClipboard([asset.id])
                                    .then(() => showBanner('已拷贝文件到剪贴板'))
                                    .catch((err) =>
                                      showBanner(
                                        err instanceof Error ? err.message : '无法拷贝该素材',
                                      ),
                                    );
                                }}
                                className="charkle-pressable w-[22px] h-[22px] rounded-[var(--win-radius-control)] bg-black/72 hover:bg-black/90 text-white inline-flex items-center justify-center cursor-pointer"
                              >
                                <Copy16Regular className="w-3 h-3" />
                              </button>
                              <button
                                type="button"
                                title={
                                  isPlainWebBookmark(asset)
                                    ? '在默认浏览器中打开'
                                    : '在主窗中沉浸预览'
                                }
                                aria-label={
                                  isPlainWebBookmark(asset)
                                    ? `在默认浏览器中打开 ${asset.title}`
                                    : `预览 ${asset.title}`
                                }
                                onClick={(e) => {
                                  e.stopPropagation();
                                  openShelfAsset(asset);
                                }}
                                className="charkle-pressable w-[22px] h-[22px] rounded-[var(--win-radius-control)] bg-black/72 hover:bg-black/90 text-white inline-flex items-center justify-center cursor-pointer"
                              >
                                {isPlainWebBookmark(asset) ? (
                                  <Open16Regular className="w-3 h-3" />
                                ) : (
                                  <Eye16Regular className="w-3 h-3" />
                                )}
                              </button>
                            </div>
                          </div>

                          <span className="text-[10px] font-medium text-white/68 truncate">
                            {asset.title}
                          </span>
                        </div>
                      ))}
                    </div>
                  )}
                </div>
              </div>
            ) : (
            <div className="pt-2 flex-1 min-h-0 flex flex-col gap-2.5">
              {/* Row 2: Quick Capture Actions (Pitfall 3: shrink-0 whitespace-nowrap) + Target Switcher + Truncated Detail Chip */}
              <div className="flex items-center justify-between gap-2 min-w-0">
                <div className="flex items-center gap-1.5 shrink-0">
                  <button
                    type="button"
                    title="区域截图 (Alt+Shift+A)"
                    aria-label="区域截图采集"
                    onClick={handleStartRegionCapture}
                    className="charkle-pressable shrink-0 whitespace-nowrap h-[27px] px-2.5 rounded-[var(--win-radius-control)] bg-white/9 hover:bg-white/14 text-white/88 inline-flex items-center gap-1.5 text-[11px] font-medium cursor-pointer"
                  >
                    <Camera16Regular className="w-3.5 h-3.5 shrink-0" />
                    <span>区域截图</span>
                  </button>

                  <button
                    type="button"
                    title="采集剪贴板 (Alt+Shift+V)"
                    aria-label="采集剪贴板"
                    onClick={() => void handleCollectClipboard()}
                    className="charkle-pressable shrink-0 whitespace-nowrap h-[27px] px-2.5 rounded-[var(--win-radius-control)] bg-white/9 hover:bg-white/14 text-white/88 inline-flex items-center gap-1.5 text-[11px] font-medium cursor-pointer"
                  >
                    <Clipboard16Regular className="w-3.5 h-3.5 shrink-0" />
                    <span>剪贴板</span>
                  </button>

                  <button
                    type="button"
                    title={minimalMode ? '退出极简模式并打开主窗' : '打开 Charkle 主窗'}
                    onClick={openMainWindowAndCollapse}
                    className="charkle-pressable shrink-0 whitespace-nowrap h-[27px] px-2.5 rounded-[var(--win-radius-control)] bg-white/9 hover:bg-white/14 text-white/88 inline-flex items-center gap-1.5 text-[11px] font-medium cursor-pointer"
                  >
                    <Grid16Regular className="w-3.5 h-3.5 shrink-0" />
                    <span>{minimalMode ? '恢复主窗' : '主窗'}</span>
                  </button>
                </div>

                <div className="flex items-center gap-1.5 min-w-0 overflow-hidden">
                  <div
                    role="radiogroup"
                    aria-label="采集投递目标"
                    className="inline-flex items-center p-[2.5px] gap-0.5 rounded-[var(--win-radius-control)] bg-white/8 shrink-0"
                  >
                    {(
                      [
                        { id: 'inbox', label: '收件箱' },
                        { id: 'folder', label: '文件夹' },
                        { id: 'activeMoodboard', label: '活跃情绪板' },
                      ] as const
                    ).map((opt) => {
                      const active = targetMode === opt.id;
                      return (
                        <button
                          key={opt.id}
                          type="button"
                          role="radio"
                          aria-checked={active}
                          onClick={() => {
                            const nextFolderId =
                              opt.id === 'folder'
                                ? selectedFolderId || folders[0]?.id || ''
                                : selectedFolderId;
                            if (opt.id === 'folder' && nextFolderId && !selectedFolderId) {
                              setSelectedFolderId(nextFolderId);
                            }
                            setTargetMode(opt.id);
                            persistTargetSelection(opt.id, nextFolderId);
                          }}
                          className={[
                            'charkle-pressable shrink-0 px-2 py-[3.5px] rounded-[var(--win-radius-control)] text-[10.5px] cursor-pointer whitespace-nowrap',
                            active
                              ? 'bg-white/18 text-white font-semibold'
                              : 'text-white/62 hover:text-white/90 font-medium',
                          ].join(' ')}
                        >
                          {opt.label}
                        </button>
                      );
                    })}
                  </div>

                  {targetMode === 'inbox' && (
                    <span className="px-2 py-1 rounded-[var(--win-radius-control)] bg-white/6 text-[10.5px] text-white/68 charkle-tabular shrink-0 whitespace-nowrap">
                      {inboxCount} 项
                    </span>
                  )}

                  {targetMode === 'folder' && folderOptions.length > 0 && (
                    <CustomSelect<string>
                      value={selectedFolderId}
                      options={folderOptions}
                      onChange={(fid) => {
                        setSelectedFolderId(fid);
                        persistTargetSelection('folder', fid);
                      }}
                      ariaLabel="选择投递文件夹"
                      size="xs"
                      className="h-[24px] min-w-0 max-w-[160px] bg-white/11 border-white/12 text-white text-[10.5px]"
                    />
                  )}

                  {targetMode === 'activeMoodboard' && (
                    <span className="inline-flex items-center gap-1.5 px-2 py-1 rounded-[var(--win-radius-control)] bg-white/6 text-[10.5px] text-white/86 min-w-0 max-w-[160px]">
                      <span className="w-[5px] h-[5px] rounded-full bg-emerald-400 shrink-0" />
                      <span className="truncate">{activeBoardTitle}</span>
                    </span>
                  )}
                </div>
              </div>

              {/* Row 3: Slim 52px Drop Well / Live Clipboard / Status Banner */}
              <div
                className={[
                  'h-[52px] shrink-0 rounded-[var(--win-radius-card)] flex items-center justify-center transition-colors duration-150 px-3.5',
                  isDropTargeted
                    ? 'bg-[var(--accent)]/24 border-[1.5px] border-[var(--accent)]'
                    : 'bg-white/[0.06] border border-dashed border-white/14 hover:bg-white/[0.08]',
                ].join(' ')}
              >
                {renderDropWellContent(false)}
              </div>

              {/* Row 4: Recent Assets Header + Horizontal Wheel-Scrollable Filmstrip */}
              <div className="flex-1 min-h-0 flex flex-col gap-1.5">
                <div className="flex items-center justify-between gap-2">
                  <div className="flex items-center gap-2 min-w-0">
                    <span className="px-2.5 py-[3px] rounded-[var(--win-radius-control)] bg-white/14 text-[11px] font-semibold text-white shrink-0">
                      最近素材
                    </span>
                    <span className="text-[10.5px] text-white/48 truncate">
                      最近保存与查看 · 拖动可放入其他应用、情绪板或文件夹
                    </span>
                  </div>

                  {minimalMode ? (
                    <button
                      type="button"
                      title="退出极简模式并打开主窗口浏览全部素材"
                      aria-label="恢复主窗看全部"
                      onClick={openMainWindowAndCollapse}
                      className="charkle-pressable px-2.5 py-[3px] rounded-[var(--win-radius-control)] bg-white/9 hover:bg-white/16 text-[10.5px] font-semibold text-white/78 inline-flex items-center gap-1 cursor-pointer shrink-0 whitespace-nowrap"
                    >
                      <span>恢复主窗看全部</span>
                      <ArrowUpRight16Regular className="w-3 h-3" />
                    </button>
                  ) : (
                    <button
                      type="button"
                      title="展开全画面瀑布流浏览最近素材（支持框选多选）"
                      aria-label="展开为全瀑布流抽屉"
                      onClick={openFullGallery}
                      className="charkle-pressable px-2.5 py-[3px] rounded-[var(--win-radius-control)] bg-white/10 hover:bg-white/16 text-[11px] font-semibold text-white/84 inline-flex items-center gap-1 cursor-pointer shrink-0 charkle-tabular"
                    >
                      <span>全部 ({assets.length})</span>
                      <ChevronDown16Regular className="w-3 h-3" />
                    </button>
                  )}
                </div>

                {assets.length === 0 ? (
                  <div className="flex-1 flex items-center justify-center text-[11.5px] text-white/45">
                    暂无最近素材，拖入文件或按 Alt+Shift+V 粘贴收藏
                  </div>
                ) : (
                  <div
                    ref={filmstripRef}
                    onWheel={(e) => {
                      const el = filmstripRef.current;
                      if (!el) return;
                      if (Math.abs(e.deltaY) > Math.abs(e.deltaX)) {
                        e.preventDefault();
                        el.scrollLeft += e.deltaY;
                      }
                    }}
                    className="flex items-start gap-[9px] overflow-x-auto charkle-scroll-hidden py-0.5 flex-1"
                  >
                    {assets.slice(0, minimalMode ? 16 : 24).map((asset) => (
                      <div
                        key={asset.id}
                        className="group shrink-0 w-[96px] flex flex-col gap-1"
                      >
                        <div
                          onPointerDown={(e) =>
                            startCardDragOut(e, [asset.id], openFullGallery)
                          }
                          className="relative w-[96px] h-[82px] rounded-[var(--win-radius-card)] overflow-hidden bg-white/8 ring-1 ring-white/12 group-hover:ring-white/38 cursor-grab active:cursor-grabbing transition-shadow duration-150"
                        >
                          <ShelfAssetThumb
                            asset={asset}
                            rawThumbUrl={transport.thumbnailUrl(asset.id, 'grid520')}
                            fixedHeight
                          />

                          {/* Hover Quick Actions: Copy File + Open in Main Quick Look */}
                          <div className="absolute top-1.5 right-1.5 flex items-center gap-1 opacity-0 group-hover:opacity-100 transition-opacity duration-150">
                            <button
                              type="button"
                              title="拷贝文件到剪贴板"
                              aria-label={`拷贝 ${asset.title}`}
                              onClick={(e) => {
                                e.stopPropagation();
                                void transport
                                  .copyAssetsToClipboard([asset.id])
                                  .then(() => showBanner('已拷贝文件到剪贴板'))
                                  .catch((err) =>
                                    showBanner(
                                      err instanceof Error ? err.message : '无法拷贝该素材',
                                    ),
                                  );
                              }}
                              className="charkle-pressable w-[22px] h-[22px] rounded-[var(--win-radius-control)] bg-black/72 hover:bg-black/90 text-white inline-flex items-center justify-center cursor-pointer"
                            >
                              <Copy16Regular className="w-3 h-3" />
                            </button>
                            <button
                              type="button"
                              title={
                                isPlainWebBookmark(asset)
                                  ? '在默认浏览器中打开'
                                  : '在主窗中沉浸预览'
                              }
                              aria-label={
                                isPlainWebBookmark(asset)
                                  ? `在默认浏览器中打开 ${asset.title}`
                                  : `预览 ${asset.title}`
                              }
                              onClick={(e) => {
                                e.stopPropagation();
                                openShelfAsset(asset);
                              }}
                              className="charkle-pressable w-[22px] h-[22px] rounded-[var(--win-radius-control)] bg-black/72 hover:bg-black/90 text-white inline-flex items-center justify-center cursor-pointer"
                            >
                              {isPlainWebBookmark(asset) ? (
                                <Open16Regular className="w-3 h-3" />
                              ) : (
                                <Eye16Regular className="w-3 h-3" />
                              )}
                            </button>
                          </div>
                        </div>

                        <span className="text-[10px] font-medium text-white/68 truncate">
                          {asset.title}
                        </span>
                      </div>
                    ))}
                  </div>
                )}
              </div>
            </div>
            )
          ) : (
            /* Expanded Full-Waterfall Gallery Mode (Pure-black masonry + rubber-band marquee + multi-drag) */
            <div className="pt-2 flex-1 min-h-0 flex flex-col gap-2 overflow-hidden">
              {isSideDock ? (
                /* Side Full-Waterfall 2-Row Compact Header (520 × 700) */
                <div className="flex flex-col gap-1.5 shrink-0">
                  <div className="flex items-center gap-2">
                    <span className="px-2.5 py-1 rounded-[var(--win-radius-control)] bg-white/16 text-[11.5px] font-semibold text-white shrink-0">
                      最近素材
                    </span>

                    <div className="flex-1 min-w-0 flex items-center gap-1.5 h-[28px] px-2.5 rounded-[var(--win-radius-control)] bg-white/9 border border-white/10 focus-within:border-[var(--accent)]">
                      <Search16Regular className="w-3 h-3 text-white/55 shrink-0" />
                      <input
                        type="text"
                        value={searchQuery}
                        onPointerDown={() => void transport.setShelfAllowActivate(true).catch(() => {})}
                        onFocus={() => void transport.setShelfAllowActivate(true).catch(() => {})}
                        onChange={(e) => setSearchQuery(e.target.value)}
                        placeholder="搜索最近素材…"
                        className="flex-1 min-w-0 bg-transparent text-[12px] text-white placeholder:text-white/45 outline-none"
                      />
                      {searchQuery && (
                        <button
                          type="button"
                          aria-label="清除搜索"
                          onClick={() => setSearchQuery('')}
                          className="text-white/50 hover:text-white cursor-pointer inline-flex items-center"
                        >
                          <Dismiss16Regular className="w-3 h-3" />
                        </button>
                      )}
                    </div>

                    <button
                      type="button"
                      aria-label="切换为紧凑抽屉"
                      onClick={closeFullGallery}
                      className="charkle-pressable px-2.5 py-1 rounded-[var(--win-radius-control)] bg-white/12 hover:bg-white/18 text-[11px] font-semibold text-white/88 inline-flex items-center gap-1 cursor-pointer shrink-0"
                    >
                      {dockEdge === 'left' && <ChevronLeft16Regular className="w-3 h-3" />}
                      <span>收起</span>
                      {dockEdge === 'right' && <ChevronRight16Regular className="w-3 h-3" />}
                    </button>
                  </div>

                  <div className="flex items-center justify-between gap-2 min-h-[22px]">
                    {selectedIds.length > 0 ? (
                      <div className="flex items-center gap-1.5 min-w-0 flex-wrap">
                        <span className="px-2.5 py-0.5 rounded-[var(--win-radius-control)] bg-[#5B8DEF]/20 text-[#74A0F7] text-[11px] font-semibold charkle-tabular">
                          已选 {selectedIds.length} 项 · 拖动卡片可直接拖出
                        </span>
                        <button
                          type="button"
                          onClick={() =>
                            void transport
                              .copyAssetsToClipboard(selectedIds)
                              .then(() => showBanner(`已拷贝 ${selectedIds.length} 项文件`))
                              .catch((err) =>
                                showBanner(
                                  err instanceof Error ? err.message : '无法拷贝所选素材',
                                ),
                              )
                          }
                          className="charkle-pressable px-2 py-0.5 rounded-[var(--win-radius-control)] bg-white/12 hover:bg-white/18 text-[11px] font-medium text-white/88 inline-flex items-center gap-1 cursor-pointer"
                        >
                          <Copy16Regular className="w-3 h-3" />
                          <span>拷贝</span>
                        </button>
                        <button
                          type="button"
                          onClick={() => setSelectedIds([])}
                          className="charkle-pressable px-2 py-0.5 rounded-[var(--win-radius-control)] bg-white/8 hover:bg-white/14 text-[11px] text-white/70 hover:text-white cursor-pointer"
                        >
                          取消
                        </button>
                      </div>
                    ) : (
                      <span className="text-[10.5px] text-white/48 truncate">
                        拖拽空白处框选多选 · 拖动卡片至其他应用 / 情绪板 / 文件夹
                      </span>
                    )}
                  </div>
                </div>
              ) : (
              <div className="flex items-center gap-2.5 shrink-0">
                <span className="px-2.5 py-1 rounded-[var(--win-radius-control)] bg-white/16 text-[12px] font-semibold text-white shrink-0">
                  最近素材
                </span>

                <div className="flex items-center gap-1.5 w-[210px] h-[28px] px-2.5 rounded-[var(--win-radius-control)] bg-white/9 border border-white/10 focus-within:border-[var(--accent)]">
                  <Search16Regular className="w-3 h-3 text-white/55 shrink-0" />
                  <input
                    type="text"
                    value={searchQuery}
                    onPointerDown={() => void transport.setShelfAllowActivate(true).catch(() => {})}
                    onFocus={() => void transport.setShelfAllowActivate(true).catch(() => {})}
                    onChange={(e) => setSearchQuery(e.target.value)}
                    placeholder="搜索最近素材…"
                    className="flex-1 min-w-0 bg-transparent text-[12px] text-white placeholder:text-white/45 outline-none"
                  />
                  {searchQuery && (
                    <button
                      type="button"
                      aria-label="清除搜索"
                      onClick={() => setSearchQuery('')}
                      className="text-white/50 hover:text-white cursor-pointer inline-flex items-center"
                    >
                      <Dismiss16Regular className="w-3 h-3" />
                    </button>
                  )}
                </div>

                {selectedIds.length > 0 ? (
                  <div className="flex items-center gap-1.5 shrink-0">
                    <span className="px-2.5 py-1 rounded-[var(--win-radius-control)] bg-[#5B8DEF]/20 text-[#74A0F7] text-[11px] font-semibold charkle-tabular">
                      已选 {selectedIds.length} 项 · 拖动卡片可直接拖出
                    </span>
                    <button
                      type="button"
                      onClick={() =>
                        void transport
                          .copyAssetsToClipboard(selectedIds)
                          .then(() => showBanner(`已拷贝 ${selectedIds.length} 项文件`))
                          .catch((err) =>
                            showBanner(err instanceof Error ? err.message : '无法拷贝所选素材'),
                          )
                      }
                      className="charkle-pressable px-2 py-1 rounded-[var(--win-radius-control)] bg-white/12 hover:bg-white/18 text-[11px] font-medium text-white/88 inline-flex items-center gap-1 cursor-pointer"
                    >
                      <Copy16Regular className="w-3 h-3" />
                      <span>拷贝</span>
                    </button>
                    <button
                      type="button"
                      onClick={() => setSelectedIds([])}
                      className="charkle-pressable px-2 py-1 rounded-[var(--win-radius-control)] bg-white/8 hover:bg-white/14 text-[11px] text-white/70 hover:text-white cursor-pointer"
                    >
                      取消
                    </button>
                  </div>
                ) : (
                  <span className="text-[11px] text-white/48 truncate">
                    拖拽空白处框选多选 · 拖动卡片至其他应用 / 情绪板 / 文件夹
                  </span>
                )}

                <div className="flex-1" />

                <button
                  type="button"
                  aria-label="切换为紧凑抽屉"
                  onClick={closeFullGallery}
                  className="charkle-pressable px-2.5 py-1 rounded-[var(--win-radius-control)] bg-white/12 hover:bg-white/18 text-[11px] font-semibold text-white/88 inline-flex items-center gap-1 cursor-pointer shrink-0"
                >
                  <span>收起</span>
                  <ChevronUp16Regular className="w-3 h-3" />
                </button>
              </div>
              )}

              <div
                ref={waterfallGridRef}
                onMouseDown={(e) => {
                  if (e.button !== 0) return;
                  if ((e.target as HTMLElement).closest('[data-shelf-card-id]')) return;
                  const el = waterfallGridRef.current;
                  if (!el) return;
                  const rect = el.getBoundingClientRect();
                  const x = e.clientX - rect.left + el.scrollLeft;
                  const y = e.clientY - rect.top + el.scrollTop;
                  if (!e.ctrlKey && !e.metaKey) setSelectedIds([]);
                  setMarquee({ startX: x, startY: y, curX: x, curY: y });
                }}
                className="relative flex-1 min-h-0 overflow-y-auto charkle-scroll rounded-[var(--win-radius-card)] bg-black p-1"
              >
                {filteredAssets.length === 0 ? (
                  <div className="h-full flex flex-col items-center justify-center gap-2 text-[12px] text-white/52">
                    <span>{searchQuery ? '未找到匹配的最近素材' : '暂无最近素材'}</span>
                    {searchQuery && (
                      <button
                        type="button"
                        onClick={() => setSearchQuery('')}
                        className="charkle-pressable px-3 py-1 rounded-[var(--win-radius-control)] bg-white/12 hover:bg-white/18 text-[11px] text-white/85 cursor-pointer"
                      >
                        清除搜索
                      </button>
                    )}
                  </div>
                ) : (
                <div className={isSideDock ? 'columns-3 gap-2 space-y-2' : 'columns-5 gap-2.5 space-y-2.5'}>
                  {filteredAssets.slice(0, 80).map((asset) => {
                    const selected = selectedIds.includes(asset.id);
                    const dragIds =
                      selected && selectedIds.length > 1 ? selectedIds : [asset.id];
                    return (
                      <div
                        key={asset.id}
                        data-shelf-card-id={asset.id}
                        role="button"
                        tabIndex={0}
                        onPointerDown={(e) =>
                          startCardDragOut(e, dragIds, () =>
                            toggleSelect(asset.id, e.ctrlKey || e.metaKey),
                          )
                        }
                        onDoubleClick={() => openShelfAsset(asset)}
                        className={[
                          'group relative break-inside-avoid rounded-[var(--win-radius-card)] overflow-hidden bg-white/8 cursor-grab active:cursor-grabbing',
                          selected ? 'ring-2 ring-[var(--accent)]' : 'ring-1 ring-white/10 hover:ring-white/30',
                        ].join(' ')}
                      >
                        <ShelfAssetThumb
                          asset={asset}
                          rawThumbUrl={transport.thumbnailUrl(asset.id, 'grid520')}
                        />

                        <div className="absolute top-1.5 right-1.5 flex items-center gap-1 opacity-0 group-hover:opacity-100 transition-opacity duration-150">
                          <button
                            type="button"
                            title="拷贝文件到剪贴板"
                            onClick={(e) => {
                              e.stopPropagation();
                              void transport
                                .copyAssetsToClipboard(dragIds)
                                .then(() => showBanner(`已拷贝 ${dragIds.length} 项文件`))
                                .catch((err) =>
                                  showBanner(err instanceof Error ? err.message : '无法拷贝该素材'),
                                );
                            }}
                            className="charkle-pressable w-6 h-6 rounded-[var(--win-radius-control)] bg-black/72 hover:bg-black/90 text-white inline-flex items-center justify-center cursor-pointer"
                          >
                            <Copy16Regular className="w-3 h-3" />
                          </button>
                          <button
                            type="button"
                            title={
                              isPlainWebBookmark(asset)
                                ? '在默认浏览器中打开'
                                : '在主窗中沉浸预览'
                            }
                            aria-label={
                              isPlainWebBookmark(asset)
                                ? `在默认浏览器中打开 ${asset.title}`
                                : `预览 ${asset.title}`
                            }
                            onClick={(e) => {
                              e.stopPropagation();
                              openShelfAsset(asset);
                            }}
                            className="charkle-pressable w-6 h-6 rounded-[var(--win-radius-control)] bg-black/72 hover:bg-black/90 text-white inline-flex items-center justify-center cursor-pointer"
                          >
                            {isPlainWebBookmark(asset) ? (
                              <Open16Regular className="w-3 h-3" />
                            ) : (
                              <Eye16Regular className="w-3 h-3" />
                            )}
                          </button>
                        </div>
                      </div>
                    );
                  })}
                </div>
                )}

                {marqueeBox && (marqueeBox.width > 4 || marqueeBox.height > 4) && (
                  <div
                    aria-hidden="true"
                    style={marqueeBox}
                    className="pointer-events-none absolute z-30 rounded-[var(--win-radius-control)] border border-[var(--accent)] bg-[var(--accent)]/20"
                  />
                )}

                {(isDropTargeted || processingMessage || statusMessage) && (
                  <div
                    data-testid="shelf-waterfall-drop-overlay"
                    className="pointer-events-none absolute inset-1.5 z-40 rounded-[var(--win-radius-card)] bg-black/78 backdrop-blur-md border-[1.5px] border-dashed border-[var(--accent)] flex items-center justify-center px-4"
                  >
                    {renderDropWellContent(isSideDock)}
                  </div>
                )}
              </div>
            </div>
          )}
        </div>
      </div>
    </div>
  );
};
